// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./helpers/TestBase.sol";
import {MirrorVault} from "../src/MirrorVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MirrorVaultTest is TestBase {
    // ─── Deposit / Withdraw ───────────────────────────────────────────────────

    function test_depositMintsShares() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        assertGt(shares, 0, "shares must be > 0");
        assertEq(vault.balanceOf(alice), shares);
        assertEq(token0.balanceOf(address(vault)), amount);
    }

    function test_withdrawBurnsShares() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(token0.balanceOf(alice), 1_000_000e6); // full refund (no yield yet)
    }

    function test_depositPauseReverts() public {
        vm.prank(owner);
        vault.pause();

        _approveVault(alice, 1000e6);
        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(1000e6, alice);
    }

    // ─── Cross-chain assets ───────────────────────────────────────────────────

    function test_totalAssetsIncludesCrossChain() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        vault.deposit(amount, alice);

        assertEq(vault.totalAssets(), amount);

        vm.prank(agent);
        vault.updateCrossChainAssets(500e6);
        assertEq(vault.totalAssets(), 1500e6);
    }

    function test_updateCrossChainAssetsUnauthorized() public {
        vm.expectRevert(MirrorVault.NotAuthorizedAgent.selector);
        vm.prank(alice);
        vault.updateCrossChainAssets(100e6);
    }

    // ─── Baseline APY ─────────────────────────────────────────────────────────

    function test_updateBaselineApyUnauthorized() public {
        vm.expectRevert(MirrorVault.NotAuthorizedAgent.selector);
        vm.prank(alice);
        vault.updateBaselineApy(800);
    }

    function test_updateBaselineApy() public {
        vm.prank(agent);
        vault.updateBaselineApy(800);
        assertEq(vault.baselineApyBps(), 800);
    }

    // ─── Performance fee harvest ──────────────────────────────────────────────

    function test_harvestRevertsWithNoExtraYield() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        vault.deposit(amount, alice);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(MirrorVault.NoExtraYield.selector);
        vm.prank(agent);
        vault.harvest();
    }

    function test_harvestRevertsIfTooSoon() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        vault.deposit(amount, alice);

        // Simulate yield via cross-chain asset report
        vm.prank(agent);
        vault.updateCrossChainAssets(200e6); // "extra" $200 from other chains

        vm.expectRevert(MirrorVault.HarvestTooSoon.selector);
        vm.prank(agent);
        vault.harvest(); // too soon (< 1 day)
    }

    function test_harvestUnauthorized() public {
        vm.expectRevert(MirrorVault.NotAuthorizedAgent.selector);
        vm.prank(alice);
        vault.harvest();
    }

    function test_harvestMintsFeeShares() public {
        uint256 depositAmt = 1_000_000e6;
        _approveVault(alice, depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        // Simulate cross-chain mirroring yielding extra 50k USDC (5% extra)
        uint256 extraYield = 50_000e6;
        vm.prank(agent);
        vault.updateCrossChainAssets(extraYield);

        // Warp past harvest interval
        vm.warp(block.timestamp + 1 days + 1);

        uint256 treasurySharesBefore = vault.balanceOf(address(treasury));
        vm.prank(agent);
        vault.harvest();

        uint256 treasurySharesAfter = vault.balanceOf(address(treasury));
        assertGt(treasurySharesAfter, treasurySharesBefore, "treasury should have fee shares");
    }

    // ─── Share price invariant ────────────────────────────────────────────────

    /// @dev After a deposit, share price should be >= 1 (no deflation)
    function testFuzz_sharePriceNeverDeflates(uint256 depositAmt) public {
        depositAmt = bound(depositAmt, 1e6, 10_000_000e6);
        _dealTokens(alice, depositAmt);
        _approveVault(alice, depositAmt);

        uint256 priceBefore = vault.convertToAssets(1e18);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);
        uint256 priceAfter = vault.convertToAssets(1e18);

        assertGe(priceAfter, priceBefore, "share price must not deflate on deposit");
    }

    // ─── Principal tracking ───────────────────────────────────────────────────

    function test_principalTrackedCorrectly() public {
        uint256 amt1 = 500e6;
        uint256 amt2 = 300e6;

        _approveVault(alice, amt1);
        vm.prank(alice);
        vault.deposit(amt1, alice);
        assertEq(vault.principalTracked(), amt1);

        _approveVault(bob, amt2);
        vm.prank(bob);
        vault.deposit(amt2, bob);
        assertEq(vault.principalTracked(), amt1 + amt2);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertApproxEqAbs(vault.principalTracked(), amt2, 1);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    // ─── Treasury timelock (R-5) ──────────────────────────────────────────────

    function test_proposeAndExecuteTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        address oldTreasury = vault.treasury();

        vm.prank(owner);
        vault.proposeTreasury(newTreasury);
        assertEq(vault.pendingTreasury(), newTreasury);
        assertEq(vault.pendingTreasuryEffectiveAt(), block.timestamp + vault.TREASURY_TIMELOCK_DELAY());
        // Treasury not yet rotated
        assertEq(vault.treasury(), oldTreasury);

        // Premature execution must revert
        vm.expectRevert(MirrorVault.TimelockNotReady.selector);
        vault.executeTreasury();

        // After the delay anyone may execute
        vm.warp(block.timestamp + vault.TREASURY_TIMELOCK_DELAY());
        vault.executeTreasury();

        assertEq(vault.treasury(), newTreasury);
        assertEq(vault.pendingTreasury(), address(0));
        assertEq(vault.pendingTreasuryEffectiveAt(), 0);
    }

    function test_proposeTreasuryZeroAddressReverts() public {
        vm.expectRevert(MirrorVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.proposeTreasury(address(0));
    }

    function test_proposeTreasuryOnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.proposeTreasury(makeAddr("newTreasury"));
    }

    function test_executeTreasuryRevertsIfNoPending() public {
        vm.expectRevert(MirrorVault.NoPendingTreasury.selector);
        vault.executeTreasury();
    }

    function test_cancelPendingTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        vault.proposeTreasury(newTreasury);

        vm.prank(owner);
        vault.cancelPendingTreasury();
        assertEq(vault.pendingTreasury(), address(0));
        assertEq(vault.pendingTreasuryEffectiveAt(), 0);

        // Now executing without a fresh proposal must revert
        vm.warp(block.timestamp + vault.TREASURY_TIMELOCK_DELAY());
        vm.expectRevert(MirrorVault.NoPendingTreasury.selector);
        vault.executeTreasury();
    }

    function test_cancelPendingTreasuryRevertsIfNothingPending() public {
        vm.expectRevert(MirrorVault.NoPendingTreasury.selector);
        vm.prank(owner);
        vault.cancelPendingTreasury();
    }

    function test_proposeTreasuryOverwritesPriorProposal() public {
        address a = makeAddr("treasuryA");
        address b = makeAddr("treasuryB");

        vm.startPrank(owner);
        vault.proposeTreasury(a);
        // Advance partway, then overwrite — timer should reset to a full delay
        vm.warp(block.timestamp + 12 hours);
        vault.proposeTreasury(b);
        vm.stopPrank();

        assertEq(vault.pendingTreasury(), b);
        assertEq(vault.pendingTreasuryEffectiveAt(), block.timestamp + vault.TREASURY_TIMELOCK_DELAY());

        // Executing exactly at the original effective-time of `a` must still revert —
        // the overwrite to `b` reset the timer.
        vm.warp(block.timestamp + 12 hours);
        vm.expectRevert(MirrorVault.TimelockNotReady.selector);
        vault.executeTreasury();
    }

    // ─── updateCrossChainAssets bound (R-1) ───────────────────────────────────

    function test_updateCrossChainAssetsBypassWhenPriorZero() public {
        // Initial bootstrapping: prior == 0, any value should be accepted.
        vm.prank(agent);
        vault.updateCrossChainAssets(1_000_000e6);
        assertEq(vault.crossChainAssetsReported(), 1_000_000e6);
    }

    function test_updateCrossChainAssetsEnforcesMaxDelta() public {
        // Bootstrap a non-zero prior so the bound becomes active.
        vm.prank(agent);
        vault.updateCrossChainAssets(1000e6);

        // Default cap is 2500 BPS = 25%. A jump of >25% must revert.
        vm.prank(agent);
        vm.expectRevert(MirrorVault.CrossChainAssetsDeltaTooLarge.selector);
        vault.updateCrossChainAssets(1500e6); // 50% jump — rejected

        // A jump within the cap is accepted.
        vm.prank(agent);
        vault.updateCrossChainAssets(1200e6); // 20% jump — fine
        assertEq(vault.crossChainAssetsReported(), 1200e6);

        // Symmetric: large DOWN moves are also rejected.
        vm.prank(agent);
        vm.expectRevert(MirrorVault.CrossChainAssetsDeltaTooLarge.selector);
        vault.updateCrossChainAssets(800e6); // 33% drop — rejected
    }

    function test_setMaxCrossChainAssetsDeltaBpsOwnerOnly() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setMaxCrossChainAssetsDeltaBps(5000);

        vm.prank(owner);
        vault.setMaxCrossChainAssetsDeltaBps(5000);
        assertEq(vault.maxCrossChainAssetsDeltaBps(), 5000);
    }

    function test_setMaxCrossChainAssetsDeltaBpsBounded() public {
        vm.expectRevert(MirrorVault.ZeroAmount.selector);
        vm.prank(owner);
        vault.setMaxCrossChainAssetsDeltaBps(10_001);
    }

    function test_setMaxCrossChainAssetsDeltaBpsTo10000Disables() public {
        vm.prank(agent);
        vault.updateCrossChainAssets(1000e6);

        // Owner widens to MAX_BPS (100%) — effectively disables the gate.
        vm.prank(owner);
        vault.setMaxCrossChainAssetsDeltaBps(10_000);

        // A 100% jump now passes. (Anything strictly >100% still reverts; that's by design.)
        vm.prank(agent);
        vault.updateCrossChainAssets(2000e6);
        assertEq(vault.crossChainAssetsReported(), 2000e6);
    }

    // ─── Chain registry (Phase A extensibility) ───────────────────────────────

    function test_addChain() public {
        vm.prank(owner);
        vault.addChain(11155111, 0, bytes32(uint256(uint160(makeAddr("ethRelayer")))), address(0), bytes32(0), 4000);

        assertEq(vault.enabledDomainsCount(), 1);
        MirrorVault.ChainConfig memory cfg = vault.getChainConfig(11155111);
        assertTrue(cfg.enabled);
        assertEq(cfg.allocationBps, 4000);
    }

    function test_addChainTwiceReverts() public {
        bytes32 recip = bytes32(uint256(uint160(makeAddr("ethRelayer"))));
        vm.prank(owner);
        vault.addChain(11155111, 0, recip, address(0), bytes32(0), 4000);
        vm.prank(owner);
        vm.expectRevert(MirrorVault.ChainAlreadyEnabled.selector);
        vault.addChain(11155111, 0, recip, address(0), bytes32(0), 4000);
    }

    function test_setAllocationsEnforcesSum() public {
        vm.startPrank(owner);
        vault.addChain(11155111, 0, bytes32(uint256(uint160(makeAddr("a")))), address(0), bytes32(0), 6000);
        vault.addChain(56, 0, bytes32(uint256(uint160(makeAddr("b")))), address(0), bytes32(0), 4000);

        uint32[] memory domains = new uint32[](2);
        uint16[] memory bps = new uint16[](2);
        domains[0] = 11155111;
        bps[0] = 5000;
        domains[1] = 56;
        bps[1] = 5000;
        vault.setAllocations(domains, bps);
        assertEq(vault.getChainConfig(11155111).allocationBps, 5000);

        bps[0] = 3000;
        bps[1] = 3000;
        vm.expectRevert(MirrorVault.AllocationsMustSum10000.selector);
        vault.setAllocations(domains, bps);
        vm.stopPrank();
    }

    function test_removeChainRequiresZeroAllocation() public {
        vm.startPrank(owner);
        vault.addChain(11155111, 0, bytes32(uint256(uint160(makeAddr("a")))), address(0), bytes32(0), 4000);
        vm.expectRevert(MirrorVault.ChainHasInFlightFunds.selector);
        vault.removeChain(11155111);

        // Rebalance: take 11155111 to 0, add another chain at 10000
        vault.addChain(56, 0, bytes32(uint256(uint160(makeAddr("b")))), address(0), bytes32(0), 6000);
        uint32[] memory d = new uint32[](2);
        uint16[] memory b = new uint16[](2);
        d[0] = 11155111;
        b[0] = 0;
        d[1] = 56;
        b[1] = 10000;
        vault.setAllocations(d, b);

        vault.removeChain(11155111);
        assertEq(vault.enabledDomainsCount(), 1);
        vm.stopPrank();
    }

    function test_previewSplit() public {
        vm.startPrank(owner);
        vault.addChain(11155111, 0, bytes32(uint256(uint160(makeAddr("a")))), address(0), bytes32(0), 6000);
        vault.addChain(56, 0, bytes32(uint256(uint160(makeAddr("b")))), address(0), bytes32(0), 4000);
        vm.stopPrank();

        (uint32[] memory ds, uint256[] memory amts) = vault.previewSplit(10_000e6);
        assertEq(ds.length, 2);
        assertEq(amts[0], 6_000e6);
        assertEq(amts[1], 4_000e6);
    }

    // ─── Async withdrawal queue (Phase C) ─────────────────────────────────────

    function test_requestWithdrawTransfersCustody() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        vm.prank(alice);
        uint256 requestId = vault.requestWithdraw(shares, alice);

        assertEq(vault.balanceOf(alice), 0, "alice's shares moved to vault custody");
        assertEq(vault.balanceOf(address(vault)), shares, "vault holds shares");
        assertEq(requestId, 0);
    }

    function test_fulfillWithdrawBurnsAndPays() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        vm.prank(alice);
        uint256 requestId = vault.requestWithdraw(shares, alice);

        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(agent);
        vault.fulfillWithdraw(requestId);

        assertEq(vault.balanceOf(address(vault)), 0, "custody shares burned");
        assertEq(token0.balanceOf(alice) - aliceBefore, amount, "alice paid out");
    }

    function test_fulfillWithdrawByNonAgentReverts() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);
        vm.prank(alice);
        uint256 requestId = vault.requestWithdraw(shares, alice);

        vm.expectRevert(MirrorVault.NotAuthorizedAgent.selector);
        vm.prank(alice);
        vault.fulfillWithdraw(requestId);
    }

    function test_cancelWithdrawAfterDelay() public {
        uint256 amount = 1000e6;
        _approveVault(alice, amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);
        vm.prank(alice);
        uint256 requestId = vault.requestWithdraw(shares, alice);

        vm.prank(alice);
        vm.expectRevert(MirrorVault.TooEarlyToCancel.selector);
        vault.cancelWithdraw(requestId);

        vm.warp(block.timestamp + vault.WITHDRAW_CANCEL_DELAY() + 1);
        vm.prank(alice);
        vault.cancelWithdraw(requestId);

        assertEq(vault.balanceOf(alice), shares, "shares returned to alice");
    }

    function test_syncWithdrawReverts_whenLocalBalanceShort() public {
        _approveVault(alice, 1000e6);
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        // Simulate the vault sending its USDC away (e.g. bridged to a sister Relayer)
        // and the agent reports those assets as cross-chain (so share value is preserved
        // even though local balance is 0).
        vm.prank(address(vault));
        token0.transfer(makeAddr("decoy"), 1000e6);
        vm.prank(agent);
        vault.updateCrossChainAssets(1000e6);

        // Now alice's shares still convert to 1000e6 assets, but vault has 0 local USDC.
        // Sync redeem must revert with InsufficientLocalBalance.
        uint256 aliceShares = vault.balanceOf(alice); // pre-read so vm.expectRevert targets only redeem
        vm.expectRevert(MirrorVault.InsufficientLocalBalance.selector);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
    }
}
