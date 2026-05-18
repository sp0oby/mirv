// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";
import {IMessageRecipient} from "./interfaces/IHyperlane.sol";

/// @title Relayer
/// @notice Receives Hyperlane messages from sister MirrorHooks and executes
///         liquidity position adjustments on the local V4 pool.
/// @dev One Relayer deployed per non-primary chain (Ethereum + BNB).
///      Holds LP positions as position owner. Funded by MirrorVault at deposit time.
///      Immutable — replace by deploying new Relayer and updating Vault config.
contract Relayer is IMessageRecipient, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ─── Errors ─────────────────────────────────────────────────────────────
    error NotMailbox();
    error NotAuthorizedSender();
    error ZeroAddress();
    error InvalidPayload();
    error InsufficientFunds();
    error PoolNotRegistered();
    error TimelockNotReady();
    error NoPendingMailbox();

    // ─── Events ─────────────────────────────────────────────────────────────
    event MessageReceived(uint32 indexed origin, bytes32 indexed sender, bytes32 messageId);
    event RebalanceExecuted(bytes32 indexed pairId, int128 deltaToken0, int128 deltaToken1);
    event PoolRegistered(bytes32 indexed pairId, PoolId poolId);
    event AuthorizedSenderUpdated(bytes32 indexed sender, bool authorized);
    event MailboxProposed(address indexed newMailbox, uint256 effectiveAt);
    event MailboxCancelled(address indexed cancelled);
    event MailboxUpdated(address indexed oldMailbox, address indexed newMailbox);

    // ─── Constants ───────────────────────────────────────────────────────────
    /// @notice Minimum delay between proposing a mailbox rotation and executing
    ///         it. The mailbox is the only authority `handle()` accepts; flipping
    ///         it instantly would let a compromised owner key spoof every future
    ///         message. 24h gives a watching multisig time to `cancelPendingMailbox`.
    uint256 public constant MAILBOX_TIMELOCK_DELAY = 24 hours;

    // ─── Types ───────────────────────────────────────────────────────────────
    /// @dev Must stay byte-for-byte identical with MirrorHook.RebalanceMessage.
    ///      `currentDepth` is carried for cross-chain depth notifications but
    ///      is unused by the Relayer's execution path (it only consumes deltas
    ///      and tick range). Adding/removing fields here requires a coordinated
    ///      redeploy of both Hook and Relayer.
    struct RebalanceMessage {
        bytes32 pairId; // keccak256(abi.encode(token0, token1))
        int128 deltaToken0; // positive = add, negative = remove
        int128 deltaToken1;
        uint24 newFee;
        int24 tickLower;
        int24 tickUpper;
        uint256 minExpectedYield;
        uint256 currentDepth;
    }

    // ─── State ───────────────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    address public mailbox;

    /// @dev 32-byte sender addresses that are allowed to dispatch to this Relayer
    mapping(bytes32 => bool) public authorizedSenders;

    // ─── Mailbox timelock state (R-5) ────────────────────────────────────────
    /// @notice Address proposed as the next mailbox. Zero when no proposal is pending.
    address public pendingMailbox;
    /// @notice Earliest timestamp at which `executeMailbox` may consume the proposal.
    uint256 public pendingMailboxEffectiveAt;

    /// @dev pairId => PoolKey registered on this chain
    mapping(bytes32 => PoolKey) private _poolKeys;
    mapping(bytes32 => bool) private _registered;

    // ─── Constructor ─────────────────────────────────────────────────────────
    /// @param _poolManager V4 PoolManager on this chain
    /// @param _mailbox     Hyperlane Mailbox on this chain
    /// @param _owner       Owner (multisig recommended)
    constructor(address _poolManager, address _mailbox, address _owner) Ownable(_owner) {
        if (_poolManager == address(0) || _mailbox == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);
        mailbox = _mailbox;
    }

    // ─── IMessageRecipient ───────────────────────────────────────────────────

    /// @notice Entry point for Hyperlane-delivered messages
    function handle(uint32 origin, bytes32 sender, bytes calldata message)
        external
        payable
        override
        whenNotPaused
        nonReentrant
    {
        if (msg.sender != mailbox) revert NotMailbox();
        if (!authorizedSenders[sender]) revert NotAuthorizedSender();
        if (message.length == 0) revert InvalidPayload();

        // abi.decode reverts cleanly on malformed payloads — no need for hardcoded size check
        RebalanceMessage memory rm = abi.decode(message, (RebalanceMessage));
        if (!_registered[rm.pairId]) revert PoolNotRegistered();

        bytes32 messageId = keccak256(abi.encodePacked(origin, sender, message));
        emit MessageReceived(origin, sender, messageId);

        _executeRebalance(rm);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _executeRebalance(RebalanceMessage memory rm) internal {
        PoolKey memory key = _poolKeys[rm.pairId];

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: rm.tickLower,
            tickUpper: rm.tickUpper,
            liquidityDelta: _liquidityFromDeltas(key, rm.deltaToken0, rm.deltaToken1, rm.tickLower, rm.tickUpper),
            salt: bytes32(0)
        });

        // No pre-approval needed: CurrencySettler.settle() inside the unlock
        // callback uses `sync` + direct `transfer` from this contract, not the
        // ERC-20 approval pattern.
        poolManager.unlock(abi.encode(key, params));

        emit RebalanceExecuted(rm.pairId, rm.deltaToken0, rm.deltaToken1);
    }

    /// @dev Called back by PoolManager.unlock() — executes the actual modify
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotMailbox();

        (PoolKey memory key, ModifyLiquidityParams memory params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        _settleDeltas(key, delta);

        return "";
    }

    /// @dev V4 sign convention (confirmed against PoolModifyLiquidityTest reference):
    ///        - negative delta  ⇨  caller owes the pool   ⇨  settle (transfer in)
    ///        - positive delta  ⇨  pool   owes the caller ⇨  take    (transfer out)
    ///      The pre-v5 implementation had this inverted (commented as
    ///      "PoolManager owes us" on the negative branch) AND used a bare
    ///      `currency.transfer` instead of the sync + transfer + settle
    ///      sequence the PoolManager requires for ERC-20s. CurrencySettler
    ///      (OZ's uniswap-hooks helper) handles both correctly, including the
    ///      native-ETH path.
    function _settleDeltas(PoolKey memory key, BalanceDelta delta) internal {
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 < 0) {
            CurrencySettler.settle(key.currency0, poolManager, address(this), uint128(-d0), false);
        } else if (d0 > 0) {
            CurrencySettler.take(key.currency0, poolManager, address(this), uint128(d0), false);
        }

        if (d1 < 0) {
            CurrencySettler.settle(key.currency1, poolManager, address(this), uint128(-d1), false);
        } else if (d1 > 0) {
            CurrencySettler.take(key.currency1, poolManager, address(this), uint128(d1), false);
        }
    }

    /// @dev Convert agent-supplied (token0, token1) deltas into V4's liquidityDelta
    ///      using the canonical TickMath + LiquidityAmounts math. Replaces the
    ///      placeholder that returned `int256(d0)` (which had the right sign but
    ///      wildly wrong magnitude — token units instead of liquidity units).
    /// @param key         PoolKey for the pool being modified (needed to read sqrtPrice).
    /// @param d0          Signed token0 delta (positive = add liquidity, negative = remove).
    /// @param d1          Signed token1 delta. Must agree in sign with d0 for normal moves.
    /// @param tickLower   Lower bound of the position's tick range.
    /// @param tickUpper   Upper bound of the position's tick range.
    /// @return liquidityDelta  Signed liquidity units to pass to `modifyLiquidity`.
    ///
    /// Math: liquidity = LiquidityAmounts.getLiquidityForAmounts(
    ///         sqrtPriceX96, sqrtA, sqrtB, |d0|, |d1|
    ///       ); sign carried from d0/d1 (whichever is non-zero).
    function _liquidityFromDeltas(PoolKey memory key, int128 d0, int128 d1, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (int256)
    {
        // Sign: prefer d0's sign, fall back to d1 when d0 == 0 (single-sided add at edge of range).
        bool isAdd = d0 > 0 || (d0 == 0 && d1 > 0);

        // Take absolute values for the (positive-only) LiquidityAmounts API.
        uint256 absD0 = uint256(int256(d0 < 0 ? -int256(d0) : int256(d0)));
        uint256 absD1 = uint256(int256(d1 < 0 ? -int256(d1) : int256(d1)));

        // Read current sqrtPrice from PoolManager state. StateLibrary handles
        // the extsload + slot decoding so we don't depend on a separate StateView
        // contract being deployed.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, absD0, absD1);

        // V4 sign convention: positive = add, negative = remove. Cast uint128 → int256.
        return isAdd ? int256(uint256(liquidity)) : -int256(uint256(liquidity));
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Register a pool pair that this Relayer is allowed to manage
    function registerPool(bytes32 pairId, PoolKey calldata key) external onlyOwner {
        _poolKeys[pairId] = key;
        _registered[pairId] = true;
        emit PoolRegistered(pairId, key.toId());
    }

    /// @notice Authorize or revoke a 32-byte sender address (sister MirrorHook)
    function setAuthorizedSender(bytes32 sender, bool authorized) external onlyOwner {
        authorizedSenders[sender] = authorized;
        emit AuthorizedSenderUpdated(sender, authorized);
    }

    /// @notice Step 1 of the timelocked mailbox rotation (R-5). Records the
    ///         intended new mailbox and the earliest activation timestamp.
    ///         Overwriting an existing proposal resets the timer.
    function proposeMailbox(address newMailbox) external onlyOwner {
        if (newMailbox == address(0)) revert ZeroAddress();
        pendingMailbox = newMailbox;
        pendingMailboxEffectiveAt = block.timestamp + MAILBOX_TIMELOCK_DELAY;
        emit MailboxProposed(newMailbox, pendingMailboxEffectiveAt);
    }

    /// @notice Step 2 of the timelocked mailbox rotation. Anyone may execute
    ///         after the timer elapses; same owner-friendly pattern as Vault.
    function executeMailbox() external {
        address pending = pendingMailbox;
        if (pending == address(0)) revert NoPendingMailbox();
        if (block.timestamp < pendingMailboxEffectiveAt) revert TimelockNotReady();
        emit MailboxUpdated(mailbox, pending);
        mailbox = pending;
        delete pendingMailbox;
        delete pendingMailboxEffectiveAt;
    }

    /// @notice Cancel a pending mailbox rotation before it activates.
    function cancelPendingMailbox() external onlyOwner {
        address cancelled = pendingMailbox;
        if (cancelled == address(0)) revert NoPendingMailbox();
        delete pendingMailbox;
        delete pendingMailboxEffectiveAt;
        emit MailboxCancelled(cancelled);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue any tokens mistakenly sent here (no user funds are held here normally)
    function rescueToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    receive() external payable {}
}
