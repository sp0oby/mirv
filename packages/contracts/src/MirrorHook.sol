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
import {IMailbox, IMessageRecipient} from "./interfaces/IHyperlane.sol";
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
contract MirrorHook is BaseHook, Ownable, Pausable, ReentrancyGuard, IMessageRecipient {
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
    error NotMailbox();
    error NotAuthorizedSender();
    error InvalidPayload();

    // ─── Events ─────────────────────────────────────────────────────────────
    event ImbalanceDetected(bytes32 indexed pairId, uint256 imbalanceBps, uint256 driftBps);
    event RebalanceDispatched(bytes32 indexed messageId, uint32 destinationDomain, bytes32 pairId);
    event AgentAuthorizationUpdated(address indexed agent, bool authorized);
    event SisterDomainAdded(uint32 domain, bytes32 recipient);
    event SisterDomainRemoved(uint32 domain);
    event ThresholdUpdated(uint256 imbalanceBps, uint256 driftBps);
    event SisterDepthReported(uint32 indexed domain, bytes32 pairId, uint256 depthUsd);
    event SisterNotificationReceived(uint32 indexed origin, bytes32 indexed sender, bytes32 pairId, uint256 reportedDepth);
    event AuthorizedSenderUpdated(bytes32 indexed sender, bool authorized);
    event DispatchCooldownUpdated(uint256 oldSeconds, uint256 newSeconds);
    event DispatchFailed(uint32 indexed destinationDomain, bytes32 pairId, bytes reason);

    // ─── Types ───────────────────────────────────────────────────────────────
    /// @dev `currentDepth` carries the sender chain's `localDepthUsd` at dispatch time
    ///      so cross-chain notifications update `sisterDepths` on receipt without
    ///      needing an off-chain agent round-trip. Struct must stay byte-for-byte
    ///      identical with the Relayer's RebalanceMessage definition.
    struct RebalanceMessage {
        bytes32 pairId;
        int128 deltaToken0;
        int128 deltaToken1;
        uint24 newFee;
        int24 tickLower;
        int24 tickUpper;
        uint256 minExpectedYield;
        uint256 currentDepth;
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
    /// @dev Cached `chainlinkFeed.decimals()` to skip an external call per oracle
    ///      read (R-12). Chainlink aggregators expose a constant `decimals()`
    ///      for the lifetime of the proxy, so caching at construction is safe.
    uint8 public immutable chainlinkFeedDecimals;

    bytes32 public immutable pythPriceFeedId; // e.g. ETH/USD feed id on Pyth

    /// @dev Chain-independent pair identity issued by MirrorFactory.
    ///      Same value across all chains for the same logical pair so cross-chain
    ///      sisterDepths lookups align. Replaces the per-chain
    ///      keccak256(currency0, currency1) pairId which varied across chains.
    bytes32 public immutable canonicalPairId;

    /// @dev Authorized AI agent addresses (CoordinatorAgent hot wallet)
    mapping(address => bool) public authorizedAgents;

    /// @dev 32-byte sender addresses (sister MirrorHooks) authorized to dispatch
    ///      incoming Hyperlane messages to this hook's `handle()`.
    mapping(bytes32 => bool) public authorizedSenders;

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
        bytes32 _canonicalPairId,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        if (_mailbox == address(0) || _pyth == address(0) || _chainlinkFeed == address(0)) {
            revert ZeroAddress();
        }
        if (_canonicalPairId == bytes32(0)) revert ZeroAddress();
        mailbox = IMailbox(_mailbox);
        pyth = IPyth(_pyth);
        chainlinkFeed = AggregatorV3Interface(_chainlinkFeed);
        chainlinkFeedDecimals = AggregatorV3Interface(_chainlinkFeed).decimals();
        pythPriceFeedId = _pythFeedId;
        canonicalPairId = _canonicalPairId;
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
        _updateLocalDepth(key, delta.amount0(), delta.amount1(), true);
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
        _updateLocalDepth(key, delta.amount0(), delta.amount1(), false);
        _handleEvent(key, delta.amount0(), delta.amount1(), false);
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ─── Agent-callable ───────────────────────────────────────────────────────

    /// @notice Authorized CoordinatorAgent calls this to trigger an explicit
    ///         cross-chain rebalance dispatch. Uses this hook's canonicalPairId.
    function dispatchRebalance(
        int128 deltaToken0,
        int128 deltaToken1,
        uint24 newFee,
        int24 tickLower,
        int24 tickUpper
    ) external payable nonReentrant whenNotPaused {
        if (!authorizedAgents[msg.sender]) revert NotAuthorizedAgent();

        // currentDepth = 0 here because dispatchRebalance is agent-initiated with
        // intended deltas, not an event-driven depth report. handle() skips
        // sisterDepths updates when currentDepth == 0, so this won't clobber tracking.
        RebalanceMessage memory rm = RebalanceMessage({
            pairId: canonicalPairId,
            deltaToken0: deltaToken0,
            deltaToken1: deltaToken1,
            newFee: newFee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            minExpectedYield: 0,
            currentDepth: 0
        });

        _dispatchToAllSisters(rm);
    }

    /// @notice Agents report sister pool depths here so the hook can make
    ///         local imbalance decisions without oracle reads. Reports are
    ///         stored against this hook's canonicalPairId.
    function reportSisterDepth(uint32 domain, uint256 depthUsd) external {
        if (!authorizedAgents[msg.sender]) revert NotAuthorizedAgent();
        sisterDepths[domain][canonicalPairId] = depthUsd;
        emit SisterDepthReported(domain, canonicalPairId, depthUsd);
    }

    // ─── IMessageRecipient — receive cross-chain notifications from sister hooks ──

    /// @notice Entry point for Hyperlane-delivered messages from sister hooks.
    ///         Updates this hook's `sisterDepths` tracking based on the reported
    ///         depth in the message, so subsequent local events can detect
    ///         imbalance without waiting for an off-chain agent's poll cycle.
    /// @dev    Auth model mirrors Relayer: only mailbox can call, only registered
    ///         sister addresses are accepted. Pausable so RiskAgent can halt
    ///         cross-chain reads if oracle anomalies are detected upstream.
    function handle(uint32 origin, bytes32 sender, bytes calldata message)
        external
        payable
        override
        whenNotPaused
        nonReentrant
    {
        if (msg.sender != address(mailbox)) revert NotMailbox();
        if (!authorizedSenders[sender]) revert NotAuthorizedSender();
        if (message.length == 0) revert InvalidPayload();

        RebalanceMessage memory rm = abi.decode(message, (RebalanceMessage));

        // Defensive: only accept messages for THIS hook's canonical pair. Stray
        // messages for unrelated pairs are silently ignored (no revert so a
        // single broken sister can't grief the mailbox delivery queue).
        if (rm.pairId != canonicalPairId) {
            emit SisterNotificationReceived(origin, sender, rm.pairId, 0);
            return;
        }

        // Treat currentDepth==0 as "no depth reported" (agent-initiated dispatchRebalance
        // sends 0) so we don't clobber valid tracking with a zero.
        if (rm.currentDepth != 0) {
            sisterDepths[origin][canonicalPairId] = rm.currentDepth;
            emit SisterDepthReported(origin, canonicalPairId, rm.currentDepth);
        }

        emit SisterNotificationReceived(origin, sender, canonicalPairId, rm.currentDepth);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _handleEvent(PoolKey calldata key, int128 amount0, int128 amount1, bool /*zeroForOne*/ ) internal {
        PoolId pid = key.toId();
        // Use the canonical (chain-independent) pair id so cross-chain sister
        // depth lookups align. Pre-canonical builds used keccak256(currency0,currency1)
        // which differed per chain because token addresses differ.
        bytes32 pairId = canonicalPairId;

        // USD value of the event using the same decimal handling as
        // `_updateLocalDepth` so the tiny-event guard below compares apples to
        // apples. Assumes token0 is priced by `_getOraclePrice()` (18 decimals)
        // and token1 is USDC-style (6 decimals).
        uint256 usdValue = _eventUsdValue(amount0, amount1);

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
            minExpectedYield: 0,
            currentDepth: depth
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
            // Bound each sister's dispatch in try/catch so one bad sister (paused mailbox,
            // missing IGP route, etc) cannot revert the entire V4 LP-add tx. Without this,
            // a single mis-wired sister DOSs every add/remove on every pool that shares
            // this hook. We use external-self-call so try/catch works on the internal flow.
            try this._dispatchOne(sd, payload, rm.pairId) {}
            catch (bytes memory reason) {
                emit DispatchFailed(sd.domainId, rm.pairId, reason);
            }
        }
    }

    /// @dev External-callable wrapper so the loop above can try/catch it. Restricted
    ///      to self-calls so it remains effectively internal. Doing this internally
    ///      isn't supported by Solidity's try/catch (only external calls).
    function _dispatchOne(SisterDomain calldata sd, bytes calldata payload, bytes32 pairId) external {
        if (msg.sender != address(this)) revert NotAuthorizedAgent();
        uint256 fee = mailbox.quoteDispatch(sd.domainId, sd.recipientAddress, payload);
        if (address(this).balance < fee) revert InsufficientEthForDispatch();
        bytes32 msgId = mailbox.dispatch{value: fee}(sd.domainId, sd.recipientAddress, payload);
        emit RebalanceDispatched(msgId, sd.domainId, pairId);
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

    /// @dev Updates local pool depth tracking on add/remove liquidity. Without this
    ///      the imbalance check in `_handleEvent` short-circuits to false forever
    ///      and `MessageDispatched` never fires from V4 events. Assumes token0
    ///      uses 18 decimals priced by `_getOraclePrice()` (e.g. WETH/USD) and
    ///      token1 is USDC-style 6 decimals — matches mirv's only pair today.
    function _updateLocalDepth(PoolKey calldata key, int128 amount0, int128 amount1, bool isAdd) internal {
        PoolId pid = key.toId();
        uint256 valueUsd = _eventUsdValue(amount0, amount1);

        if (isAdd) {
            localDepthUsd[pid] += valueUsd;
        } else {
            uint256 current = localDepthUsd[pid];
            localDepthUsd[pid] = current > valueUsd ? current - valueUsd : 0;
        }
    }

    /// @dev USD value of a V4 event (1e18-scaled). Sums token0 (oracle-priced,
    ///      18 dec) and token1 (USDC, 6 dec) contributions.
    function _eventUsdValue(int128 amount0, int128 amount1) internal view returns (uint256) {
        uint256 price = _getOraclePrice();
        uint256 abs0 = uint256(uint128(amount0 < 0 ? -amount0 : amount0));
        uint256 abs1 = uint256(uint128(amount1 < 0 ? -amount1 : amount1));
        return (abs0 * price) / 1e18 + abs1 * 1e12;
    }

    /// @dev Max acceptable confidence-to-price ratio for Pyth (1% = 100 BPS).
    ///      If Pyth's confidence interval exceeds this, we treat the price as
    ///      unreliable and fall back to Chainlink. Hardens against the agent
    ///      reacting to noisy / wide-uncertainty price data.
    uint256 public constant PYTH_MAX_CONF_BPS = 100;

    /// @dev Returns price in USD with 18 decimals.
    ///      Tries Pyth first; falls back to Chainlink if Pyth is stale OR if Pyth's
    ///      confidence interval is > 1% of price (low-quality feed).
    function _getOraclePrice() internal view returns (uint256) {
        try pyth.getPriceNoOlderThan(pythPriceFeedId, PYTH_STALENESS) returns (IPyth.Price memory p) {
            // Validate price > 0 AND confidence/price ratio is within tolerance.
            // p.conf is a uint64 absolute confidence interval in the same units as p.price.
            if (p.price > 0 && p.conf > 0) {
                uint256 priceAbs = uint256(uint64(p.price));
                // conf * MAX_BPS / price <= PYTH_MAX_CONF_BPS  ⇨  conf * MAX_BPS <= price * PYTH_MAX_CONF_BPS
                if (uint256(p.conf) * MAX_BPS > priceAbs * PYTH_MAX_CONF_BPS) {
                    // Pyth too uncertain — skip and try Chainlink below.
                } else {
                    int256 scaledPrice = int256(priceAbs);
                    uint256 priceUsd;
                    if (p.expo >= 0) {
                        priceUsd = uint256(scaledPrice) * 10 ** uint32(p.expo) * 1e18;
                    } else {
                        priceUsd = uint256(scaledPrice) * 1e18 / 10 ** uint32(-p.expo);
                    }
                    return priceUsd;
                }
            } else if (p.price > 0) {
                // conf == 0 — Pyth gives a deterministic price (unusual but valid for
                // some feeds). Accept it.
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

        // R-12: use cached `chainlinkFeedDecimals` (set at construction) instead
        // of an external `decimals()` call per oracle read.
        return uint256(answer) * 10 ** (18 - chainlinkFeedDecimals);
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

    /// @notice Authorize (or revoke) a 32-byte sender — a sister MirrorHook address —
    ///         to call `handle()` via the mailbox.
    function setAuthorizedSender(bytes32 sender, bool authorized) external onlyOwner {
        if (sender == bytes32(0)) revert ZeroAddress();
        authorizedSenders[sender] = authorized;
        emit AuthorizedSenderUpdated(sender, authorized);
    }

    function setThresholds(uint256 newImbalanceBps, uint256 newDriftBps) external onlyOwner {
        if (newImbalanceBps > MAX_BPS || newDriftBps > MAX_BPS) revert InvalidThreshold();
        imbalanceThresholdBps = newImbalanceBps;
        driftThresholdBps = newDriftBps;
        emit ThresholdUpdated(newImbalanceBps, newDriftBps);
    }

    function setDispatchCooldown(uint256 seconds_) external onlyOwner {
        emit DispatchCooldownUpdated(dispatchCooldown, seconds_);
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
