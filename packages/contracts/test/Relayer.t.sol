// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Relayer} from "../src/Relayer.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Relayer access-control + message-validation tests.
///         Full V4 modifyLiquidity execution tested via fork tests (TODO).
contract RelayerTest is Test {
    Relayer internal relayer;

    address internal owner = makeAddr("owner");
    address internal mailbox = makeAddr("mailbox");
    address internal poolManager = makeAddr("poolManager");
    address internal alice = makeAddr("alice");
    bytes32 internal sisterHook = bytes32(uint256(uint160(makeAddr("sisterHook"))));
    uint32 internal sisterDomain = 8453; // Base

    function setUp() public {
        relayer = new Relayer(poolManager, mailbox, owner);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructorStoresArgs() public view {
        assertEq(address(relayer.poolManager()), poolManager);
        assertEq(relayer.mailbox(), mailbox);
        assertEq(relayer.owner(), owner);
    }

    function test_constructorRevertsOnZeroPoolManager() public {
        vm.expectRevert(Relayer.ZeroAddress.selector);
        new Relayer(address(0), mailbox, owner);
    }

    function test_constructorRevertsOnZeroMailbox() public {
        vm.expectRevert(Relayer.ZeroAddress.selector);
        new Relayer(poolManager, address(0), owner);
    }

    // ─── Authorization ────────────────────────────────────────────────────────

    function test_setAuthorizedSenderByOwner() public {
        assertFalse(relayer.authorizedSenders(sisterHook));
        vm.prank(owner);
        relayer.setAuthorizedSender(sisterHook, true);
        assertTrue(relayer.authorizedSenders(sisterHook));
    }

    function test_setAuthorizedSenderByNonOwnerReverts() public {
        vm.expectRevert();
        vm.prank(alice);
        relayer.setAuthorizedSender(sisterHook, true);
    }

    // ─── Mailbox timelock (R-5) ───────────────────────────────────────────────

    function test_proposeAndExecuteMailbox() public {
        address newMb = makeAddr("newMailbox");
        address oldMb = relayer.mailbox();

        vm.prank(owner);
        relayer.proposeMailbox(newMb);
        assertEq(relayer.pendingMailbox(), newMb);
        assertEq(relayer.pendingMailboxEffectiveAt(), block.timestamp + relayer.MAILBOX_TIMELOCK_DELAY());
        assertEq(relayer.mailbox(), oldMb);

        vm.expectRevert(Relayer.TimelockNotReady.selector);
        relayer.executeMailbox();

        vm.warp(block.timestamp + relayer.MAILBOX_TIMELOCK_DELAY());
        relayer.executeMailbox();

        assertEq(relayer.mailbox(), newMb);
        assertEq(relayer.pendingMailbox(), address(0));
    }

    function test_proposeMailboxZeroReverts() public {
        vm.expectRevert(Relayer.ZeroAddress.selector);
        vm.prank(owner);
        relayer.proposeMailbox(address(0));
    }

    function test_proposeMailboxOnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        relayer.proposeMailbox(makeAddr("newMailbox"));
    }

    function test_executeMailboxRevertsIfNoPending() public {
        vm.expectRevert(Relayer.NoPendingMailbox.selector);
        relayer.executeMailbox();
    }

    function test_cancelPendingMailbox() public {
        address newMb = makeAddr("newMailbox");
        vm.prank(owner);
        relayer.proposeMailbox(newMb);

        vm.prank(owner);
        relayer.cancelPendingMailbox();
        assertEq(relayer.pendingMailbox(), address(0));

        vm.warp(block.timestamp + relayer.MAILBOX_TIMELOCK_DELAY());
        vm.expectRevert(Relayer.NoPendingMailbox.selector);
        relayer.executeMailbox();
    }

    function test_cancelPendingMailboxRevertsIfNothingPending() public {
        vm.expectRevert(Relayer.NoPendingMailbox.selector);
        vm.prank(owner);
        relayer.cancelPendingMailbox();
    }

    // ─── handle() reverts ─────────────────────────────────────────────────────

    function test_handleRevertsIfNotMailbox() public {
        vm.expectRevert(Relayer.NotMailbox.selector);
        vm.prank(alice);
        relayer.handle(sisterDomain, sisterHook, "");
    }

    function test_handleRevertsIfSenderNotAuthorized() public {
        vm.expectRevert(Relayer.NotAuthorizedSender.selector);
        vm.prank(mailbox);
        relayer.handle(sisterDomain, sisterHook, "");
    }

    function test_handleRevertsIfPayloadEmpty() public {
        vm.prank(owner);
        relayer.setAuthorizedSender(sisterHook, true);

        vm.expectRevert(Relayer.InvalidPayload.selector);
        vm.prank(mailbox);
        relayer.handle(sisterDomain, sisterHook, "");
    }

    function test_handleRevertsOnMalformedPayload() public {
        vm.prank(owner);
        relayer.setAuthorizedSender(sisterHook, true);

        // 4-byte payload is too short to decode — abi.decode reverts (no custom error)
        vm.expectRevert();
        vm.prank(mailbox);
        relayer.handle(sisterDomain, sisterHook, hex"deadbeef");
    }

    function test_handleRevertsIfPoolNotRegistered() public {
        vm.prank(owner);
        relayer.setAuthorizedSender(sisterHook, true);

        bytes memory payload = abi.encode(
            Relayer.RebalanceMessage({
                pairId: keccak256("unregistered"),
                deltaToken0: 0,
                deltaToken1: 0,
                newFee: 3000,
                tickLower: -60,
                tickUpper: 60,
                minExpectedYield: 0,
                currentDepth: 0
            })
        );

        vm.expectRevert(Relayer.PoolNotRegistered.selector);
        vm.prank(mailbox);
        relayer.handle(sisterDomain, sisterHook, payload);
    }

    function test_handleRevertsWhenPaused() public {
        vm.prank(owner);
        relayer.setAuthorizedSender(sisterHook, true);

        vm.prank(owner);
        relayer.pause();

        vm.expectRevert();
        vm.prank(mailbox);
        relayer.handle(sisterDomain, sisterHook, "");
    }

    // ─── registerPool ─────────────────────────────────────────────────────────

    function test_registerPoolByOwner() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(makeAddr("hook"))
        });
        bytes32 pairId = keccak256("test-pair");

        vm.prank(owner);
        relayer.registerPool(pairId, key);
        // After registering, handle's "PoolNotRegistered" path is bypassed for this pairId
        // (will fail later at the V4 modifyLiquidity step in a real fork test)
    }

    // ─── Zero-delta short-circuit (depth-only notification) ──────────────────
    /// @dev When handle() receives a Hyperlane message with both deltas == 0
    ///      (a depth notification originating from a source hook's _handleEvent
    ///      V4 callback), the Relayer should emit RebalanceSkippedZeroDelta
    ///      and return without touching the PoolManager. Pre-fix this would
    ///      have reverted at V4's "zero liquidity" check, pinning the
    ///      Hyperlane message in the pending queue forever.
    function test_handleSkipsZeroDeltaMessage() public {
        bytes32 pairId = keccak256("zero-delta-pair");

        // Register the pool so PoolNotRegistered isn't the revert path.
        vm.startPrank(owner);
        relayer.setAuthorizedSender(sisterHook, true);
        relayer.registerPool(
            pairId,
            PoolKey({
                currency0: Currency.wrap(makeAddr("token0")),
                currency1: Currency.wrap(makeAddr("token1")),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(makeAddr("hook"))
            })
        );
        vm.stopPrank();

        // Depth-only notification: zero deltas, zero ticks.
        bytes memory payload = abi.encode(
            Relayer.RebalanceMessage({
                pairId: pairId,
                deltaToken0: 0,
                deltaToken1: 0,
                newFee: 3000,
                tickLower: 0,
                tickUpper: 0,
                minExpectedYield: 0,
                currentDepth: 999e6
            })
        );

        // Expect the skip event, NOT a RebalanceExecuted or V4 revert.
        vm.recordLogs();
        vm.prank(mailbox);
        relayer.handle(sisterDomain, sisterHook, payload);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundSkip;
        bool foundExecuted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("RebalanceSkippedZeroDelta(bytes32)")) foundSkip = true;
            if (logs[i].topics[0] == keccak256("RebalanceExecuted(bytes32,int128,int128)")) foundExecuted = true;
        }
        assertTrue(foundSkip, "RebalanceSkippedZeroDelta must fire on zero-delta payload");
        assertFalse(foundExecuted, "RebalanceExecuted must NOT fire on zero-delta payload");
    }

    function test_registerPoolByNonOwnerReverts() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(makeAddr("hook"))
        });
        vm.expectRevert();
        vm.prank(alice);
        relayer.registerPool(keccak256("p"), key);
    }

    // ─── unlockCallback access control ────────────────────────────────────────

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(Relayer.NotMailbox.selector);
        vm.prank(alice);
        relayer.unlockCallback("");
    }
}
