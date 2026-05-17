// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMailbox} from "./interfaces/IHyperlane.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {AggregatorV3Interface} from "./interfaces/IChainlink.sol";

/// @title MirrorHook
/// @notice Uniswap V4 hook attached to every sister pool in the mirv protocol.
///         After significant swaps or LP changes, it dispatches a Hyperlane message to
///         sister chains, triggering coordinated rebalancing by the Relayer contracts.
///
/// @dev HOOK ADDRESS MUST BE MINED via MineHookAddress.s.sol so that the lower bits
///      of the deployed address encode exactly the permissions returned by
///      getHookPermissions(). Deploy with CREATE2. See script/MineHookAddress.s.sol.
///
/// @dev Immutable — no proxy. Circuit breaker via Pausable. RiskAgent calls pause().
contract MirrorHook is BaseHook, Ownable, Pausable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ─── Errors ─────────────────────────────────────────────────────────────
    error NotAuthorizedAgent();
    error ZeroAddress();
    error InsufficientEthForDispatch();
    error StaleOraclePrice();
    error InvalidThreshold();
    error SisterDomainAlreadyRegistered();
    error SisterDomainNotFound();

    // ─── Events ─────────────────────────────────────────────────────────────
    event ImbalanceDetected(bytes32 indexed pairId, uint256 imbalanceBps, uint256 driftBps);
    event RebalanceDispatched(bytes32 indexed messageId, uint32 destinationDomain, bytes32 pairId);
    event AgentAuthorizationUpdated(address indexed agent, bool authorized);
    event SisterDomainAdded(uint32 domain, bytes32 recipient);
    event SisterDomainRemoved(uint32 domain);
    event ThresholdUpdated(uint256 imbalanceBps, uint256 driftBps);
    event SisterDepthReported(uint32 indexed domain, bytes32 pairId, uint256 depthUsd);

    // ─── Types ───────────────────────────────────────────────────────────────
    struct RebalanceMessage {
        bytes32 pairId;
        int128 deltaToken0;
        int128 deltaToken1;
        uint24 newFee;
        int24 tickLower;
        int24 tickUpper;
        uint256 minExpectedYield;
    }

    struct SisterDomain {
        uint32 domainId;
        bytes32 recipientAddress; // Relayer address as bytes32
    }

    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant MAX_BPS = 10_000;
    uint32 public constant CHAINLINK_STALENESS = 3600; // 1 hour max price age
    uint256 public constant PYTH_STALENESS = 60; // 60s max Pyth price age

    // Hyperlane domain IDs
    uint32 public constant DOMAIN_ETHEREUM = 1;
    uint32 public constant DOMAIN_BASE = 8453;
    uint32 public constant DOMAIN_BNB = 56;

    // ─── State ───────────────────────────────────────────────────────────────
    IMailbox public immutable mailbox;
    IPyth public immutable pyth;
    AggregatorV3Interface public immutable chainlinkFeed; // e.g. ETH/USD

    bytes32 public immutable pythPriceFeedId; // e.g. ETH/USD feed id on Pyth

    /// @dev Authorized AI agent addresses (CoordinatorAgent hot wallet)
    mapping(address => bool) public authorizedAgents;

    /// @dev Registered sister chain domains
    SisterDomain[] public sisterDomains;

    /// @dev Last reported depth (USD, 18 decimals) per sister domain per pair
    mapping(uint32 => mapping(bytes32 => uint256)) public sisterDepths;

    /// @dev Local depth per pool (updated after each event)
    mapping(PoolId => uint256) public localDepthUsd;

    /// @dev Unix timestamp of last rebalance dispatch per pool (for cooldown)
    mapping(PoolId => uint256) public lastDispatchTime;

    /// @dev Minimum seconds between dispatches per pool
    uint256 public dispatchCooldown = 60;

    /// @dev Imbalance threshold in basis points (default 300 = 3%)
    uint256 public imbalanceThresholdBps = 300;

    /// @dev Price drift threshold in basis points (default 200 = 2%)
    uint256 public driftThresholdBps = 200;

    /// @dev Max single-move size as % of TVL in BPS (default 200 = 2%)
    uint256 public maxMoveBps = 200;

    // ─── Constructor ─────────────────────────────────────────────────────────
    /// @param _poolManager      V4 PoolManager on this chain
    /// @param _mailbox          Hyperlane Mailbox on this chain
    /// @param _pyth             Pyth oracle on this chain
    /// @param _chainlinkFeed    Chainlink ETH/USD feed on this chain
    /// @param _pythFeedId       Pyth price feed ID (e.g. ETH/USD)
    /// @param _owner            Owner (multisig recommended)
    constructor(
        IPoolManager _poolManager,
        address _mailbox,
        address _pyth,
        address _chainlinkFeed,
        bytes32 _pythFeedId,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        if (_mailbox == address(0) || _pyth == address(0) || _chainlinkFeed == address(0)) {
            revert ZeroAddress();
        }
        mailbox = IMailbox(_mailbox);
        pyth = IPyth(_pyth);
        chainlinkFeed = AggregatorV3Interface(_chainlinkFeed);
        pythPriceFeedId = _pythFeedId;
    }

    // ─── BaseHook — hook permissions ─────────────────────────────────────────

    /// @notice Encode which V4 callbacks this hook intercepts.
    ///         The deployed address MUST have matching permission bits.
    ///         Mine the address with script/MineHookAddress.s.sol.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── V4 Hook callback overrides ───────────────────────────────────────────

    /// @dev Fires after every swap. Detects large price impact and dispatches
    ///      a Hyperlane imbalance notification if the swap is significant.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        whenNotPaused
        returns (bytes4, int128)
    {
        _handleEvent(key, delta.amount0(), delta.amount1(), params.zeroForOne);
        return (this.afterSwap.selector, 0);
    }

    /// @dev Fires after liquidity is added. Notifies sister chains of depth change.
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override whenNotPaused returns (bytes4, BalanceDelta) {
        _handleEvent(key, delta.amount0(), delta.amount1(), false);
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @dev Fires after liquidity is removed. Notifies sister chains.
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override whenNotPaused returns (bytes4, BalanceDelta) {
        _handleEvent(key, delta.amount0(), delta.amount1(), false);
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ─── Agent-callable ───────────────────────────────────────────────────────

    /// @notice Authorized CoordinatorAgent calls this to trigger an explicit
    ///         cross-chain rebalance dispatch.
    function dispatchRebalance(
        bytes32 pairId,
        int128 deltaToken0,
        int128 deltaToken1,
        uint24 newFee,
        int24 tickLower,
        int24 tickUpper
    ) external payable nonReentrant whenNotPaused {
        if (!authorizedAgents[msg.sender]) revert NotAuthorizedAgent();

        RebalanceMessage memory rm = RebalanceMessage({
            pairId: pairId,
            deltaToken0: deltaToken0,
            deltaToken1: deltaToken1,
            newFee: newFee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            minExpectedYield: 0
        });

        _dispatchToAllSisters(rm);
    }

    /// @notice Agents report sister pool depths here so the hook can make
    ///         local imbalance decisions without oracle reads.
    function reportSisterDepth(uint32 domain, bytes32 pairId, uint256 depthUsd) external {
        if (!authorizedAgents[msg.sender]) revert NotAuthorizedAgent();
        sisterDepths[domain][pairId] = depthUsd;
        emit SisterDepthReported(domain, pairId, depthUsd);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _handleEvent(PoolKey calldata key, int128 amount0, int128 amount1, bool zeroForOne) internal {
        PoolId pid = key.toId();
        bytes32 pairId = keccak256(abi.encode(key.currency0, key.currency1));

        uint256 price = _getOraclePrice();
        uint256 absAmt = zeroForOne
            ? uint256(uint128(amount0 < 0 ? -amount0 : amount0))
            : uint256(uint128(amount1 < 0 ? -amount1 : amount1));
        uint256 usdValue = (absAmt * price) / 1e18;

        // Skip tiny events below 0.1% of current depth (saves gas + Hyperlane fees)
        uint256 depth = localDepthUsd[pid];
        if (depth > 0 && usdValue * MAX_BPS < depth * 10) return;

        // Cooldown guard
        if (block.timestamp - lastDispatchTime[pid] < dispatchCooldown) return;

        if (!_imbalanceExceeded(pairId, depth)) return;

        emit ImbalanceDetected(pairId, imbalanceThresholdBps, driftThresholdBps);

        RebalanceMessage memory rm = RebalanceMessage({
            pairId: pairId,
            deltaToken0: 0,
            deltaToken1: 0,
            newFee: key.fee,
            tickLower: 0,
            tickUpper: 0,
            minExpectedYield: 0
        });

        // CEI: update state BEFORE the external dispatch call so a malicious mailbox
        // cannot reenter and re-trigger dispatch within the same block.
        lastDispatchTime[pid] = block.timestamp;
        _dispatchToAllSisters(rm);
    }

    function _dispatchToAllSisters(RebalanceMessage memory rm) internal {
        bytes memory payload = abi.encode(rm);
        uint256 len = sisterDomains.length;

        for (uint256 i; i < len; ++i) {
            SisterDomain memory sd = sisterDomains[i];
            uint256 fee = mailbox.quoteDispatch(sd.domainId, sd.recipientAddress, payload);
            if (address(this).balance < fee) continue;
            bytes32 msgId = mailbox.dispatch{value: fee}(sd.domainId, sd.recipientAddress, payload);
            emit RebalanceDispatched(msgId, sd.domainId, rm.pairId);
        }
    }

    function _imbalanceExceeded(bytes32 pairId, uint256 localDepth) internal view returns (bool) {
        if (localDepth == 0) return false;
        uint256 len = sisterDomains.length;
        for (uint256 i; i < len; ++i) {
            uint256 sisterDepth = sisterDepths[sisterDomains[i].domainId][pairId];
            if (sisterDepth == 0) continue;

            uint256 diff = localDepth > sisterDepth ? localDepth - sisterDepth : sisterDepth - localDepth;

            uint256 avg = (localDepth + sisterDepth) / 2;
            if (diff * MAX_BPS / avg >= imbalanceThresholdBps) return true;
        }
        return false;
    }

    /// @dev Returns price in USD with 18 decimals.
    ///      Tries Pyth first; falls back to Chainlink if Pyth is stale.
    function _getOraclePrice() internal view returns (uint256) {
        try pyth.getPriceNoOlderThan(pythPriceFeedId, PYTH_STALENESS) returns (IPyth.Price memory p) {
            if (p.price > 0) {
                int256 scaledPrice = int256(uint256(uint64(p.price)));
                uint256 priceUsd;
                if (p.expo >= 0) {
                    priceUsd = uint256(scaledPrice) * 10 ** uint32(p.expo) * 1e18;
                } else {
                    priceUsd = uint256(scaledPrice) * 1e18 / 10 ** uint32(-p.expo);
                }
                return priceUsd;
            }
        } catch {}

        (, int256 answer,, uint256 updatedAt,) = chainlinkFeed.latestRoundData();
        if (block.timestamp - updatedAt > CHAINLINK_STALENESS) revert StaleOraclePrice();
        if (answer <= 0) revert StaleOraclePrice();

        uint8 feedDecimals = chainlinkFeed.decimals();
        return uint256(answer) * 10 ** (18 - feedDecimals);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function addSisterDomain(uint32 domainId, bytes32 recipient) external onlyOwner {
        if (recipient == bytes32(0)) revert ZeroAddress();
        uint256 len = sisterDomains.length;
        for (uint256 i; i < len; ++i) {
            if (sisterDomains[i].domainId == domainId) revert SisterDomainAlreadyRegistered();
        }
        sisterDomains.push(SisterDomain(domainId, recipient));
        emit SisterDomainAdded(domainId, recipient);
    }

    function removeSisterDomain(uint32 domainId) external onlyOwner {
        uint256 len = sisterDomains.length;
        for (uint256 i; i < len; ++i) {
            if (sisterDomains[i].domainId == domainId) {
                sisterDomains[i] = sisterDomains[len - 1];
                sisterDomains.pop();
                emit SisterDomainRemoved(domainId);
                return;
            }
        }
        revert SisterDomainNotFound();
    }

    function setAgentAuthorization(address agent, bool authorized) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        authorizedAgents[agent] = authorized;
        emit AgentAuthorizationUpdated(agent, authorized);
    }

    function setThresholds(uint256 newImbalanceBps, uint256 newDriftBps) external onlyOwner {
        if (newImbalanceBps > MAX_BPS || newDriftBps > MAX_BPS) revert InvalidThreshold();
        imbalanceThresholdBps = newImbalanceBps;
        driftThresholdBps = newDriftBps;
        emit ThresholdUpdated(newImbalanceBps, newDriftBps);
    }

    function setDispatchCooldown(uint256 seconds_) external onlyOwner {
        dispatchCooldown = seconds_;
    }

    function setMaxMoveBps(uint256 bps) external onlyOwner {
        if (bps > MAX_BPS) revert InvalidThreshold();
        maxMoveBps = bps;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function fund() external payable {}

    function withdrawEth(uint256 amount) external onlyOwner nonReentrant {
        (bool ok,) = owner().call{value: amount}("");
        if (!ok) revert InsufficientEthForDispatch();
    }

    receive() external payable {}
}
