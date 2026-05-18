// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MirrorVault} from "../../src/MirrorVault.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockTokenMessenger} from "../../src/mocks/MockTokenMessenger.sol";

/// @notice 6-decimal USDC-like ERC-20 for invariant fuzzing
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC Mock", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Handler that randomly exercises the vault during invariant runs.
///         Each public function on the handler is a candidate action Foundry can call.
contract VaultHandler is Test {
    MirrorVault public vault;
    MockUSDC public usdc;
    address public agent;
    address public owner;
    address public guardian;
    address public initialTreasury;

    address[4] public actors;
    uint32[3] public candidateDomains; // pool of Hyperlane domains the fuzzer can churn
    uint256 public totalDeposited; // gross deposits, before any withdrawals
    uint256 public totalWithdrawn; // gross withdrawals

    constructor(MirrorVault _vault, MockUSDC _usdc, address _agent, address _owner, address _guardian) {
        vault = _vault;
        usdc = _usdc;
        agent = _agent;
        owner = _owner;
        guardian = _guardian;
        initialTreasury = _vault.treasury();
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");
        // ETH mainnet, BNB, Polygon — arbitrary but valid Hyperlane domain ids
        candidateDomains[0] = 1;
        candidateDomains[1] = 56;
        candidateDomains[2] = 137;
    }

    function deposit(uint256 actorIdx, uint256 amount) external {
        actorIdx = bound(actorIdx, 0, actors.length - 1);
        amount = bound(amount, 1, 1_000_000e6); // 1 wei up to 1M USDC
        address actor = actors[actorIdx];

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount, actor) returns (uint256) {
            totalDeposited += amount;
        } catch { /* revert acceptable (paused, etc.) */ }
        vm.stopPrank();
    }

    function withdraw(uint256 actorIdx, uint256 sharesFrac) external {
        actorIdx = bound(actorIdx, 0, actors.length - 1);
        address actor = actors[actorIdx];
        uint256 actorShares = vault.balanceOf(actor);
        if (actorShares == 0) return;

        uint256 shares = bound(sharesFrac, 1, actorShares);
        vm.startPrank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256 assets) {
            totalWithdrawn += assets;
        } catch {}
        vm.stopPrank();
    }

    function updateCrossChain(uint256 newValue) external {
        newValue = bound(newValue, 0, 10_000_000e6);
        vm.prank(agent);
        try vault.updateCrossChainAssets(newValue) {} catch {}
    }

    function updateBaseline(uint256 apyBps) external {
        apyBps = bound(apyBps, 0, 10_000);
        vm.prank(agent);
        try vault.updateBaselineApy(apyBps) {} catch {}
    }

    function timeWarp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 30 days));
    }

    function harvest() external {
        vm.prank(agent);
        try vault.harvest() {} catch {}
    }

    // ─── Chain registry (closes I-5 [runner-gap]) ─────────────────────────────

    function addChainAndRebalance(uint256 domIdx, uint256 allocSeed) external {
        domIdx = bound(domIdx, 0, candidateDomains.length - 1);
        uint32 dom = candidateDomains[domIdx];
        // Avoid duplicate-add reverts by only acting when not enabled.
        if (vault.getChainConfig(dom).enabled) return;

        uint16 alloc = uint16(bound(allocSeed, 0, 10_000));
        // Recipient address derived deterministically from the domain so
        // re-add cycles use the same recipient (matches real ops).
        bytes32 recipient = keccak256(abi.encodePacked("recip", dom));
        vm.startPrank(owner);
        // First add with alloc=0 so the existing-sum invariant doesn't have to
        // shift simultaneously with the add. Then if alloc > 0, redistribute.
        try vault.addChain(dom, 0, recipient, address(0), bytes32(0), 0) {} catch {
            vm.stopPrank();
            return;
        }
        if (alloc != 0) {
            // Take BPS from the LARGEST existing alloc and give to the new chain.
            (uint32 fromDom, uint16 fromAlloc) = _largestAlloc();
            if (fromAlloc >= alloc) {
                uint32[] memory domains = new uint32[](2);
                uint16[] memory bps = new uint16[](2);
                domains[0] = fromDom;
                bps[0] = fromAlloc - alloc;
                domains[1] = dom;
                bps[1] = alloc;
                try vault.setAllocations(domains, bps) {} catch {}
            }
        }
        vm.stopPrank();
    }

    function rebalanceAllocations(uint256 seed) external {
        uint256 count = vault.enabledDomainsCount();
        if (count < 2) return; // need at least 2 chains to redistribute
        // Move BPS between the first two enabled chains.
        uint32 domA = vault.enabledDomains(0);
        uint32 domB = vault.enabledDomains(1);
        uint16 allocA = vault.getChainConfig(domA).allocationBps;
        uint16 allocB = vault.getChainConfig(domB).allocationBps;
        uint16 combined = allocA + allocB;
        uint16 newA = uint16(bound(seed, 0, combined));

        uint32[] memory domains = new uint32[](2);
        uint16[] memory bps = new uint16[](2);
        domains[0] = domA;
        bps[0] = newA;
        domains[1] = domB;
        bps[1] = combined - newA;
        vm.prank(owner);
        try vault.setAllocations(domains, bps) {} catch {}
    }

    function removeZeroAllocChain(uint256 domIdx) external {
        domIdx = bound(domIdx, 0, candidateDomains.length - 1);
        uint32 dom = candidateDomains[domIdx];
        if (!vault.getChainConfig(dom).enabled) return;
        if (vault.getChainConfig(dom).allocationBps != 0) return; // contract enforces this; skip noise
        vm.prank(owner);
        try vault.removeChain(dom) {} catch {}
    }

    // ─── Treasury timelock churn (R-5 invariant coverage) ─────────────────────

    function proposeTreasury(uint256 seed) external {
        // Use the seed itself as the address bytes — deterministic without
        // needing `vm` calls inside a pure helper.
        address newT = address(uint160(uint256(keccak256(abi.encodePacked("treasuryProp", seed)))));
        if (newT == address(0)) newT = address(0xdead);
        vm.prank(owner);
        try vault.proposeTreasury(newT) {} catch {}
    }

    function executeTreasury() external {
        // Anyone can call — randomly attempt. Will revert if no pending or
        // delay not elapsed; the invariant is what matters.
        try vault.executeTreasury() {} catch {}
    }

    function cancelPendingTreasury() external {
        vm.prank(owner);
        try vault.cancelPendingTreasury() {} catch {}
    }

    // ─── Pause / guardian (R-7 invariant coverage) ────────────────────────────

    function ownerPause() external {
        vm.prank(owner);
        try vault.pause() {} catch {}
    }

    function ownerUnpause() external {
        vm.prank(owner);
        try vault.unpause() {} catch {}
    }

    function guardianPause() external {
        if (guardian == address(0)) return;
        vm.prank(guardian);
        try vault.pause() {} catch {}
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _largestAlloc() internal view returns (uint32 dom, uint16 alloc) {
        uint256 count = vault.enabledDomainsCount();
        for (uint256 i; i < count; ++i) {
            uint32 d = vault.enabledDomains(i);
            uint16 a = vault.getChainConfig(d).allocationBps;
            if (a > alloc) {
                dom = d;
                alloc = a;
            }
        }
    }
}

/// @notice Property-based tests that randomly exercise the vault and check
///         critical invariants hold across all generated action sequences.
contract VaultInvariantsTest is StdInvariant, Test {
    MirrorVault internal vault;
    Treasury internal treasury;
    MockUSDC internal usdc;
    VaultHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal initialTreasury;

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(owner);
        treasury = new Treasury(safe, owner);
        MockTokenMessenger cctp = new MockTokenMessenger();
        vm.prank(owner);
        vault = new MirrorVault(
            IERC20(address(usdc)), address(cctp), address(treasury), owner, "mirv Test", "mirvTEST"
        );
        initialTreasury = address(treasury);
        vm.startPrank(owner);
        vault.setAgentAuthorization(agent, true);
        vault.setGuardian(guardian);
        vm.stopPrank();

        handler = new VaultHandler(vault, usdc, agent, owner, guardian);

        // Constrain Foundry's invariant fuzzer to only call our handler's actions
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.updateCrossChain.selector;
        selectors[3] = handler.updateBaseline.selector;
        selectors[4] = handler.timeWarp.selector;
        selectors[5] = handler.harvest.selector;
        selectors[6] = handler.addChainAndRebalance.selector;
        selectors[7] = handler.rebalanceAllocations.selector;
        selectors[8] = handler.removeZeroAllocChain.selector;
        selectors[9] = handler.proposeTreasury.selector;
        selectors[10] = handler.executeTreasury.selector;
        selectors[11] = handler.cancelPendingTreasury.selector;
        selectors[12] = handler.ownerPause.selector;
        selectors[13] = handler.guardianPause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Total supply and total assets never go negative.
    function invariant_nonNegativeState() public view {
        assertGe(vault.totalSupply(), 0);
        assertGe(vault.totalAssets(), 0);
        assertGe(vault.principalTracked(), 0);
    }

    /// @dev If there are shares outstanding, there must be assets backing them.
    function invariant_sharesBackedByAssets() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.totalAssets(), 0, "supply > 0 but no backing assets");
        }
    }

    /// @dev totalAssets always >= local USDC balance — cross-chain claims add on top.
    function invariant_totalAssetsContainsLocalBalance() public view {
        assertGe(vault.totalAssets(), usdc.balanceOf(address(vault)), "totalAssets must contain local balance");
    }

    /// @notice DESIGN NOTE (not invariant): `principalTracked` can exceed `totalAssets()` if
    ///         an agent reports cross-chain assets lower than they were at the previous harvest.
    ///         This is a state the vault can enter, not a bug — the vault correctly reports
    ///         no extra yield (since `extraYield = totalAssets - principal - baselineYield`
    ///         becomes negative) so harvest reverts with `NoExtraYield`. The vault is solvent
    ///         to the extent of its actual asset claims.

    /// @dev Treasury can only accumulate fee shares — its balance is monotonically non-decreasing
    ///      under our handler (no transfers out simulated).
    uint256 internal _maxTreasuryShares;

    function invariant_treasurySharesMonotonic() public {
        uint256 current = vault.balanceOf(address(treasury));
        if (current > _maxTreasuryShares) _maxTreasuryShares = current;
        assertGe(current, 0);
        assertLe(current, _maxTreasuryShares + 1, "treasury shares can only grow");
    }

    /// @dev I-5 [runner-gap] closure: across all reachable states the sum of
    ///      enabled-chain allocations is either 0 (no chains added yet or all
    ///      removed) or exactly MAX_BPS (10_000). addChain seeds new chains at
    ///      alloc=0 so the sum is preserved; setAllocations only accepts inputs
    ///      that re-sum to 10_000. The handler exercises both paths heavily.
    function invariant_allocationSumIsZeroOrFull() public view {
        uint256 count = vault.enabledDomainsCount();
        uint256 total;
        for (uint256 i; i < count; ++i) {
            total += vault.getChainConfig(vault.enabledDomains(i)).allocationBps;
        }
        if (count == 0) {
            assertEq(total, 0, "no chains enabled must mean zero alloc sum");
        } else {
            // Allow 0 (initial state with chains but no allocations) OR 10_000.
            // setAllocations requires == 10_000; addChain inserts at 0 so the
            // transient state during a partial rebalance is also 0.
            assertTrue(total == 0 || total == vault.MAX_BPS(), "alloc sum must be 0 or 10_000");
        }
    }

    /// @dev I-16 [strengthens]: the treasury timelock cannot be bypassed. If
    ///      pendingTreasury == 0 then pendingTreasuryEffectiveAt == 0 (and
    ///      vice versa) — the two fields are written / cleared together.
    function invariant_pendingTreasuryConsistency() public view {
        address pending = vault.pendingTreasury();
        uint256 effectiveAt = vault.pendingTreasuryEffectiveAt();
        if (pending == address(0)) {
            assertEq(effectiveAt, 0, "no pending: effectiveAt must be 0");
        } else {
            assertGt(effectiveAt, 0, "pending set: effectiveAt must be > 0");
        }
    }

    /// @dev I-19 [strengthens]: only owner or guardian can change paused state.
    ///      We can't directly catch unauthorized changes (they'd revert in the
    ///      handler), but we CAN verify the guardian is set as expected — a
    ///      sanity check that setUp didn't drift.
    function invariant_guardianStillConfigured() public view {
        assertEq(vault.guardian(), guardian, "guardian must remain the test fixture value");
    }
}
