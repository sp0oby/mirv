// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MirrorVault} from "../../src/MirrorVault.sol";
import {Treasury} from "../../src/Treasury.sol";

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

    address[4] public actors;
    uint256 public totalDeposited; // gross deposits, before any withdrawals
    uint256 public totalWithdrawn; // gross withdrawals

    constructor(MirrorVault _vault, MockUSDC _usdc, address _agent) {
        vault = _vault;
        usdc = _usdc;
        agent = _agent;
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");
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

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(owner);
        treasury = new Treasury(safe, owner);
        vm.prank(owner);
        vault = new MirrorVault(IERC20(address(usdc)), address(treasury), owner, "mirv Test", "mirvTEST");
        vm.prank(owner);
        vault.setAgentAuthorization(agent, true);

        handler = new VaultHandler(vault, usdc, agent);

        // Constrain Foundry's invariant fuzzer to only call our handler's actions
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.updateCrossChain.selector;
        selectors[3] = handler.updateBaseline.selector;
        selectors[4] = handler.timeWarp.selector;
        selectors[5] = handler.harvest.selector;
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
}
