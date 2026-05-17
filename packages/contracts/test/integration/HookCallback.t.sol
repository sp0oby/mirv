// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {MirrorHook} from "../../src/MirrorHook.sol";
import {Treasury} from "../../src/Treasury.sol";

/// @notice Validates the full V4 hook callback chain on a real Base mainnet fork:
///   add liquidity → afterAddLiquidity fires
///   swap            → afterSwap fires
///   agent dispatch  → RebalanceDispatched event emits
///
/// Mocks the Hyperlane mailbox calls via vm.mockCall (so we don't need to fund
/// the hook with ETH for real dispatch fees).
///
/// Run: `source .env && forge test --match-contract HookCallbackTest -vv`
contract HookCallbackTest is Test {
    using PoolIdLibrary for PoolKey;

    // Base mainnet verified addresses
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant HYPERLANE_MAILBOX = 0xeA87ae93Fa0019a82A727bfd3eBd1cFCa8f64f1D;
    address constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    bytes32 constant PYTH_ETH_USD_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    // Currency ordering on Base: WETH < USDC, so WETH = currency0
    Currency internal currency0 = Currency.wrap(WETH);
    Currency internal currency1 = Currency.wrap(USDC);

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal safe = makeAddr("safe");

    MirrorHook internal hook;
    Treasury internal treasury;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    PoolKey internal poolKey;
    PoolId internal poolId;

    // Events we expect to assert against
    event ImbalanceDetected(bytes32 indexed pairId, uint256 imbalanceBps, uint256 driftBps);
    event RebalanceDispatched(bytes32 indexed messageId, uint32 destinationDomain, bytes32 pairId);

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

        // 1. Treasury
        treasury = new Treasury(safe, owner);

        // 2. Mock Hyperlane mailbox calls so the hook can "dispatch" without real ETH
        vm.mockCall(
            HYPERLANE_MAILBOX, abi.encodeWithSignature("quoteDispatch(uint32,bytes32,bytes)"), abi.encode(uint256(0))
        );
        vm.mockCall(
            HYPERLANE_MAILBOX,
            abi.encodeWithSignature("dispatch(uint32,bytes32,bytes)"),
            abi.encode(bytes32(uint256(0xdeadbeef)))
        );

        // 3. Mine hook address (test contract is the CREATE2 deployer)
        uint160 flags =
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        bytes memory constructorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), HYPERLANE_MAILBOX, PYTH, CHAINLINK_ETH_USD, PYTH_ETH_USD_ID, owner);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MirrorHook).creationCode, constructorArgs);

        // 4. Deploy hook at the mined address
        hook = new MirrorHook{salt: salt}(
            IPoolManager(POOL_MANAGER), HYPERLANE_MAILBOX, PYTH, CHAINLINK_ETH_USD, PYTH_ETH_USD_ID, owner
        );
        assertEq(address(hook), predicted);

        // 5. Authorize agent
        vm.prank(owner);
        hook.setAgentAuthorization(agent, true);

        // 6. Deploy V4 test routers against the real Base PoolManager
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));

        // 7. Initialize a brand-new pool with our hook
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // sqrtPriceX96 for ~$3000/ETH:
        //   price = USDC / WETH = 3000 / 1, but with decimals: 3000e6 / 1e18 = 3e-9 (USDC per wei of WETH)
        //   sqrt(3e-9) * 2^96 ≈ 4339505179874779488639720
        uint160 sqrtPriceX96 = 4339505179874779488639720;
        IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);

        // 8. Fund alice with tokens
        deal(WETH, alice, 100 ether);
        deal(USDC, alice, 1_000_000e6);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(lpRouter), type(uint256).max);
        IERC20(USDC).approve(address(lpRouter), type(uint256).max);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ─── afterAddLiquidity callback ───────────────────────────────────────────

    function test_addLiquidityFiresAfterAddLiquidity() public {
        // Add ±10% range liquidity. The current tick at sqrtPriceX96 corresponds
        // to roughly tick = -207000. Use a wide ±1200 tick range (~12.7%).
        int24 currentTick = -207000;
        int24 tickLower = ((currentTick - 1200) / 60) * 60;
        int24 tickUpper = ((currentTick + 1200) / 60) * 60;

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e15, salt: bytes32(0)});

        // Just assert it doesn't revert — afterAddLiquidity returns this.afterAddLiquidity.selector
        // If the hook didn't fire correctly, the PoolManager would revert with InvalidHookResponse.
        vm.prank(alice);
        lpRouter.modifyLiquidity{value: 0}(poolKey, params, "");
    }

    // ─── afterSwap callback ──────────────────────────────────────────────────

    function test_swapFiresAfterSwap() public {
        // First add liquidity so there's something to swap against
        int24 currentTick = -207000;
        ModifyLiquidityParams memory lpParams = ModifyLiquidityParams({
            tickLower: ((currentTick - 1200) / 60) * 60,
            tickUpper: ((currentTick + 1200) / 60) * 60,
            liquidityDelta: 1e16,
            salt: bytes32(0)
        });
        vm.prank(alice);
        lpRouter.modifyLiquidity(poolKey, lpParams, "");

        // Now swap 0.01 WETH → USDC
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true, // WETH → USDC
            amountSpecified: -int256(0.01 ether), // exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap should succeed → proves afterSwap returned the correct selector
        vm.prank(alice);
        swapRouter.swap(poolKey, swapParams, settings, "");
    }

    // ─── Agent dispatch path ──────────────────────────────────────────────────

    function test_agentCanDispatchRebalance() public {
        bytes32 pairId = keccak256(abi.encode(currency0, currency1));

        // Agent reports sister depth (creates an imbalance scenario)
        vm.prank(agent);
        hook.reportSisterDepth(1, pairId, 5_000_000e18); // $5M on Ethereum

        // Agent triggers dispatchRebalance — mocked mailbox accepts the call
        // No sister domains registered yet, so dispatch is a no-op (returns immediately)
        // To exercise the actual dispatch path, add a sister domain first.
        vm.prank(owner);
        hook.addSisterDomain(1, bytes32(uint256(uint160(makeAddr("relayer-eth")))));

        // Record logs to assert RebalanceDispatched fires
        vm.recordLogs();

        vm.prank(agent);
        hook.dispatchRebalance(pairId, 100e6, 0.1 ether, 3000, -60, 60);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundDispatchEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("RebalanceDispatched(bytes32,uint32,bytes32)")) {
                foundDispatchEvent = true;
                break;
            }
        }
        assertTrue(foundDispatchEvent, "RebalanceDispatched event must fire");
    }

    function test_unauthorizedDispatchReverts() public {
        bytes32 pairId = keccak256(abi.encode(currency0, currency1));
        vm.expectRevert(MirrorHook.NotAuthorizedAgent.selector);
        vm.prank(alice);
        hook.dispatchRebalance(pairId, 0, 0, 3000, -60, 60);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
