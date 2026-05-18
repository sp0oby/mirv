// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MirrorHook} from "../../src/MirrorHook.sol";
import {MirrorVault} from "../../src/MirrorVault.sol";
import {MirrorFactory} from "../../src/MirrorFactory.sol";
import {Treasury} from "../../src/Treasury.sol";
import {MockTokenMessenger} from "../../src/mocks/MockTokenMessenger.sol";

/// @notice In-process fork integration test against real Base mainnet contracts.
///         Validates the full deployment pipeline + vault lifecycle without
///         needing an external Anvil process.
///
/// Run: `source .env && forge test --match-contract ForkBaseTest -vv`
contract ForkBaseTest is Test {
    // Base mainnet verified addresses
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant HYPERLANE_MAILBOX = 0xeA87ae93Fa0019a82A727bfd3eBd1cFCa8f64f1D;
    address constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    bytes32 constant PYTH_ETH_USD_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal safe = makeAddr("safe");

    MirrorHook internal hook;
    MirrorVault internal vault;
    Treasury internal treasury;
    MirrorFactory internal factory;

    function setUp() public {
        // Skip if no Base RPC available
        string memory rpcUrl;
        try vm.rpcUrl("base") returns (string memory u) {
            rpcUrl = u;
        } catch {
            vm.skip(true);
            return;
        }
        if (bytes(rpcUrl).length == 0 || _equals(rpcUrl, "${ALCHEMY_BASE_URL}")) {
            vm.skip(true);
            return;
        }

        uint256 fork = vm.createFork(rpcUrl);
        vm.selectFork(fork);

        // 1. Deploy Treasury
        treasury = new Treasury(safe, owner);

        // 2. Mine hook address using HookMiner (uses address(this) as the CREATE2 deployer)
        uint160 flags =
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

        bytes32 canonicalPairId = keccak256(abi.encodePacked("ETH-USDC-V1", uint24(3000), int24(60)));

        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER), HYPERLANE_MAILBOX, PYTH, CHAINLINK_ETH_USD, PYTH_ETH_USD_ID, canonicalPairId, owner
        );

        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MirrorHook).creationCode, constructorArgs);

        // 3. Deploy hook via CREATE2 at the mined address
        hook = new MirrorHook{salt: salt}(
            IPoolManager(POOL_MANAGER), HYPERLANE_MAILBOX, PYTH, CHAINLINK_ETH_USD, PYTH_ETH_USD_ID, canonicalPairId, owner
        );
        assertEq(address(hook), predicted, "Hook deployed at wrong address");

        // 4. Deploy Vault + mock CCTP messenger
        MockTokenMessenger cctp = new MockTokenMessenger();
        vault = new MirrorVault(
            IERC20(USDC), address(cctp), address(treasury), owner, "mirv ETH/USDC Vault", "mirvETH-USDC"
        );

        // 5. Deploy Factory
        factory =
            new MirrorFactory(owner);

        // 6. Authorize agent
        vm.startPrank(owner);
        hook.setAgentAuthorization(agent, true);
        vault.setAgentAuthorization(agent, true);
        factory.setAgentAuthorization(agent, true);
        vm.stopPrank();
    }

    // ─── Deployment correctness ───────────────────────────────────────────────

    function test_hookPermissionsMatchAddress() public view {
        // Lower 14 bits of hook address must encode the permissions
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.afterSwap);
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeSwap);

        uint160 expectedFlags =
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, expectedFlags, "Hook address bits don't match perms");
    }

    function test_hookConnectedToBaseV4PoolManager() public view {
        assertEq(address(hook.poolManager()), POOL_MANAGER);
    }

    function test_vaultMetadata() public view {
        assertEq(vault.name(), "mirv ETH/USDC Vault");
        assertEq(vault.symbol(), "mirvETH-USDC");
        assertEq(vault.asset(), USDC);
        assertEq(vault.PERFORMANCE_FEE_BPS(), 1500);
    }

    function test_agentsAuthorized() public view {
        assertTrue(hook.authorizedAgents(agent));
        assertTrue(vault.authorizedAgents(agent));
        assertTrue(factory.authorizedAgents(agent));
    }

    // ─── Vault deposit flow with real Base USDC ───────────────────────────────

    function test_aliceCanDeposit() public {
        uint256 amount = 10_000e6; // 10k USDC
        deal(USDC, alice, amount);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(shares, amount, "First depositor gets 1:1 shares");
        assertEq(vault.balanceOf(alice), shares);
        assertEq(IERC20(USDC).balanceOf(address(vault)), amount);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.principalTracked(), amount);
    }

    function test_agentReportsCrossChainAssets() public {
        // Deposit first
        uint256 amount = 10_000e6;
        deal(USDC, alice, amount);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        // Agent reports yield from sister chains
        vm.prank(agent);
        vault.updateCrossChainAssets(500e6);

        assertEq(vault.totalAssets(), amount + 500e6, "totalAssets includes cross-chain");
    }

    function test_harvestMintsPerformanceFee() public {
        uint256 amount = 100_000e6;
        deal(USDC, alice, amount);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        // Simulate 5,000 USDC of cross-chain yield (5% extra)
        vm.prank(agent);
        vault.updateCrossChainAssets(5_000e6);

        // Set baseline APY 5% — over 1 day, baseline = ~13.7 USDC on 100k
        vm.prank(agent);
        vault.updateBaselineApy(500);

        vm.warp(block.timestamp + 1 days + 1);

        // R-3: refresh cross-chain report so it's fresh at harvest time.
        vm.prank(agent);
        vault.updateCrossChainAssets(5_000e6);

        uint256 treasurySharesBefore = vault.balanceOf(address(treasury));

        vm.prank(agent);
        vault.harvest();

        uint256 treasurySharesAfter = vault.balanceOf(address(treasury));
        assertGt(treasurySharesAfter, treasurySharesBefore, "Treasury must receive fee shares");

        // Fee should be roughly 15% of (5000 - 13.7) ≈ 747 USDC worth of shares
        // Allow ±5% tolerance for share-price math
        uint256 feeShares = treasurySharesAfter - treasurySharesBefore;
        uint256 expectedFee = (5_000e6 - 14e6) * 1500 / 10_000; // ≈ 747.9 USDC
        assertApproxEqRel(feeShares, expectedFee, 0.05e18, "fee within 5% of expected");
    }

    // ─── Factory access control ───────────────────────────────────────────────
    // Factory v4 is pure registry (no poolManager/mailbox/pyth/treasury state) —
    // owner/agent auth + canonical registry covered in test/MirrorFactory.t.sol.

    // ─── Treasury fee forwarding ──────────────────────────────────────────────

    function test_treasuryForwardsUsdcToSafe() public {
        deal(USDC, address(treasury), 1000e6);
        treasury.forwardToken(USDC);
        assertEq(IERC20(USDC).balanceOf(safe), 1000e6);
        assertEq(IERC20(USDC).balanceOf(address(treasury)), 0);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
