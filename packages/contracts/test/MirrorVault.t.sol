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

        // R-3: refresh cross-chain report so it's not stale by the time harvest runs.
        vm.prank(agent);
        vault.updateCrossChainAssets(extraYield);

        uint256 treasurySharesBefore = vault.balanceOf(address(treasury));
        vm.prank(agent);
        vault.harvest();

        uint256 treasurySharesAfter = vault.balanceOf(address(treasury));
        assertGt(treasurySharesAfter, treasurySharesBefore, "treasury should have fee shares");
    }

    // ─── Harvest staleness gate (R-3) ─────────────────────────────────────────

    function test_harvestRevertsOnStaleCrossChainReport() public {
        uint256 depositAmt = 1_000_000e6;
        _approveVault(alice, depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        // Agent reports yield, then goes silent for longer than the staleness window.
        vm.prank(agent);
        vault.updateCrossChainAssets(50_000e6);

        // Warp past both the harvest interval AND the staleness window.
        vm.warp(block.timestamp + 1 days + 1);
        // staleness window is 1 hour by default; we're well past it.

        vm.expectRevert(MirrorVault.CrossChainAssetsStale.selector);
        vm.prank(agent);
        vault.harvest();
    }

    function test_harvestPassesWhenReportFresh() public {
        uint256 depositAmt = 1_000_000e6;
        _approveVault(alice, depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vm.prank(agent);
        vault.updateCrossChainAssets(50_000e6);

        // Wait past harvest interval, then refresh just before harvesting.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(agent);
        vault.updateCrossChainAssets(50_000e6);

        vm.prank(agent);
        vault.harvest(); // must succeed
        assertGt(vault.balanceOf(address(treasury)), 0, "treasury minted fee shares");
    }

    function test_harvestStalenessSkippedIfNeverReported() public {
        // Edge case: a vault that has never received a cross-chain report
        // (e.g. pre-launch, before any chain is enabled) should NOT be blocked
        // by R-3. The gate only applies once `lastCrossChainAssetsUpdate != 0`.
        uint256 depositAmt = 1_000e6;
        _approveVault(alice, depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vm.warp(block.timestamp + 1 days + 1);

        // No update was ever sent → R-3 skips → harvest reverts with NoExtraYield,
        // not CrossChainAssetsStale.
        vm.expectRevert(MirrorVault.NoExtraYield.selector);
        vm.prank(agent);
        vault.harvest();
    }

    function test_setCrossChainAssetsMaxStaleness() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setCrossChainAssetsMaxStaleness(2 hours);

        vm.prank(owner);
        vault.setCrossChainAssetsMaxStaleness(2 hours);
        assertEq(vault.crossChainAssetsMaxStaleness(), 2 hours);
    }

    function test_harvestPassesWhenOwnerWidensStaleness() public {
        // Owner widens the gate; harvest then succeeds even after a long quiet period.
        uint256 depositAmt = 1_000_000e6;
        _approveVault(alice, depositAmt);
        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vm.prank(agent);
        vault.updateCrossChainAssets(50_000e6);

        vm.warp(block.timestamp + 1 days + 1); // > 1 hour stale

        vm.prank(owner);
        vault.setCrossChainAssetsMaxStaleness(2 days);

        vm.prank(agent);
        vault.harvest(); // staleness now permitted
        assertGt(vault.balanceOf(address(treasury)), 0);
    }

    // ─── addChain CCTP recipient check (R-10) ─────────────────────────────────

    function test_addChainRevertsOnZeroCctpRecipientWithActiveDomain() public {
        // CCTP route requested (cctpDomain != 0) but recipient is bytes32(0) —
        // would send USDC into a black hole on the first split. Must revert.
        vm.expectRevert(MirrorVault.CctpRecipientRequired.selector);
        vm.prank(owner);
        vault.addChain(
            11155111, /* hyperlaneDomain */
            5, /* cctpDomain ≠ 0 means USDC bridging is requested */
            bytes32(0), /* zero recipient — illegal */
            address(0),
            bytes32(0),
            0
        );
    }

    function test_addChainAllowsZeroCctpRecipientWhenDomainIsZero() public {
        // cctpDomain == 0 means "no CCTP route, keep funds local"; a zero recipient
        // is then meaningless and acceptable.
        vm.prank(owner);
        vault.addChain(
            11155111,
            0, /* cctpDomain == 0 */
            bytes32(0), /* zero recipient OK because no CCTP route */
            address(0),
            bytes32(0),
            0
        );
        assertTrue(vault.getChainConfig(11155111).enabled);
    }

    // ─── Guardian pause role (R-7) ────────────────────────────────────────────

    function test_setGuardianOwnerOnly() public {
        address fastResponder = makeAddr("fastResponder");
        vm.expectRevert();
        vm.prank(alice);
        vault.setGuardian(fastResponder);

        vm.prank(owner);
        vault.setGuardian(fastResponder);
        assertEq(vault.guardian(), fastResponder);
    }

    function test_guardianCanPauseButNotUnpause() public {
        address fastResponder = makeAddr("fastResponder");
        vm.prank(owner);
        vault.setGuardian(fastResponder);

        // Guardian pauses.
        vm.prank(fastResponder);
        vault.pause();
        assertTrue(vault.paused());

        // Guardian cannot unpause (unpause stays owner-only).
        vm.expectRevert();
        vm.prank(fastResponder);
        vault.unpause();

        // Owner can unpause.
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_pauseRevertsWhenNeitherOwnerNorGuardian() public {
        // No guardian configured; alice has neither role.
        vm.expectRevert(MirrorVault.NotGuardianOrOwner.selector);
        vm.prank(alice);
        vault.pause();
    }

    function test_ownerCanStillPauseWithGuardianUnset() public {
        // guardian == address(0), owner pauses anyway — pre-R-7 behavior preserved.
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
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

    // ─── Local LP Relayer forwarding (8.5.9 home-chain auto-LP) ──────────────

    function test_setLocalLpRelayer_ownerOnly() public {
        address fakeRelayer = makeAddr("lp-relayer");

        // Non-owner reverts
        vm.prank(alice);
        vm.expectRevert();
        vault.setLocalLpRelayer(fakeRelayer);

        // Owner can update + state persists
        vm.prank(owner);
        vault.setLocalLpRelayer(fakeRelayer);
        assertEq(vault.localLpRelayer(), fakeRelayer, "setter must persist");

        // Owner can clear to zero
        vm.prank(owner);
        vault.setLocalLpRelayer(address(0));
        assertEq(vault.localLpRelayer(), address(0), "owner can clear to zero");
    }

    function test_depositDoesNotForwardWhenLocalLpRelayerUnset() public {
        // Default state: localLpRelayer is zero, so deposits should NOT auto-forward.
        _approveVault(alice, 1000e6);
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        // No chains configured, so the full deposit stays in the vault.
        assertEq(token0.balanceOf(address(vault)), 1000e6, "vault holds full deposit");
    }

    function test_depositForwardsLocalShareWhenLocalLpRelayerSet() public {
        // Configure: one sister chain at 40%, local share is the remaining 60%.
        address lpRelayer = makeAddr("base-lp-relayer");
        bytes32 sisterRecipient = bytes32(uint256(uint160(makeAddr("eth-relayer"))));

        vm.startPrank(owner);
        vault.addChain(uint32(11155111), uint32(0), sisterRecipient, address(0), bytes32(0), uint16(4_000));
        vault.setLocalLpRelayer(lpRelayer);
        vm.stopPrank();

        _approveVault(alice, 1000e6);

        uint256 lpRelayerBefore = token0.balanceOf(lpRelayer);

        vm.prank(alice);
        vault.deposit(1000e6, alice);

        // 40% of 1000e6 = 400e6 was sent to the sister via CCTP (mock messenger
        // pulls the tokens; they leave the vault).
        // Remaining 60% = 600e6 should be forwarded to the local LP relayer.
        uint256 lpRelayerAfter = token0.balanceOf(lpRelayer);
        assertEq(lpRelayerAfter - lpRelayerBefore, 600e6, "local share must be forwarded to lp relayer");

        // Vault should now hold no local USDC (everything either bridged or forwarded).
        assertEq(token0.balanceOf(address(vault)), 0, "vault retains no idle USDC after deposit");
    }

    function test_depositForwardsAllWhenNoChainsConfigured() public {
        // Edge case: no sister chains enabled, localLpRelayer is set.
        // Whole deposit should forward to the LP relayer.
        address lpRelayer = makeAddr("base-lp-relayer-2");
        vm.prank(owner);
        vault.setLocalLpRelayer(lpRelayer);

        _approveVault(alice, 500e6);
        vm.prank(alice);
        vault.deposit(500e6, alice);

        assertEq(token0.balanceOf(lpRelayer), 500e6, "no sisters configured -> full deposit forwarded");
        assertEq(token0.balanceOf(address(vault)), 0, "vault has no idle USDC");
    }
}
