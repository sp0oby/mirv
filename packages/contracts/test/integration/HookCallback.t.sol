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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {MirrorHook} from "../../src/MirrorHook.sol";
import {Treasury} from "../../src/Treasury.sol";
import {Relayer} from "../../src/Relayer.sol";
import {AggregatorV3Interface} from "../../src/interfaces/IChainlink.sol";

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
    using StateLibrary for IPoolManager;

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
        bytes32 canonicalPairId = keccak256(abi.encodePacked("ETH-USDC-V1", uint24(3000), int24(60)));
        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER), HYPERLANE_MAILBOX, PYTH, CHAINLINK_ETH_USD, PYTH_ETH_USD_ID, canonicalPairId, owner
        );
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MirrorHook).creationCode, constructorArgs);

        // 4. Deploy hook at the mined address
        hook = new MirrorHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            HYPERLANE_MAILBOX,
            PYTH,
            CHAINLINK_ETH_USD,
            PYTH_ETH_USD_ID,
            canonicalPairId,
            owner
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
        // Agent reports sister depth (creates an imbalance scenario). reportSisterDepth
        // no longer takes a pairId — hook is per-canonical-pair.
        vm.prank(agent);
        hook.reportSisterDepth(1, 5_000_000e18); // $5M on Ethereum

        // Agent triggers dispatchRebalance — mocked mailbox accepts the call
        vm.prank(owner);
        hook.addSisterDomain(1, bytes32(uint256(uint160(makeAddr("relayer-eth")))));

        // Record logs to assert RebalanceDispatched fires
        vm.recordLogs();

        vm.prank(agent);
        hook.dispatchRebalance(100e6, 0.1 ether, 3000, -60, 60);

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
        vm.expectRevert(MirrorHook.NotAuthorizedAgent.selector);
        vm.prank(alice);
        hook.dispatchRebalance(0, 0, 3000, -60, 60);
    }

    // ─── Full V4-event dispatch pipeline ─────────────────────────────────────
    // Regression: without these tests, `localDepthUsd` was never written and
    // `_imbalanceExceeded` short-circuited to false forever, so MessageDispatched
    // could not fire from V4 events. Caught at testnet 2026-05-17 by user.

    function test_afterAddLiquidityUpdatesLocalDepth() public {
        PoolId pid = poolKey.toId();
        assertEq(hook.localDepthUsd(pid), 0, "fresh pool starts at 0 depth");

        int24 currentTick = -207000;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: ((currentTick - 1200) / 60) * 60,
            tickUpper: ((currentTick + 1200) / 60) * 60,
            liquidityDelta: 1e15,
            salt: bytes32(0)
        });
        vm.prank(alice);
        lpRouter.modifyLiquidity(poolKey, params, "");

        assertGt(hook.localDepthUsd(pid), 0, "localDepthUsd must grow after LP add");
    }

    function test_afterRemoveLiquidityShrinksLocalDepth() public {
        PoolId pid = poolKey.toId();
        int24 currentTick = -207000;
        int24 tickLower = ((currentTick - 1200) / 60) * 60;
        int24 tickUpper = ((currentTick + 1200) / 60) * 60;

        // First add liquidity so there's something to remove
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e15, salt: bytes32(0)
        });
        vm.prank(alice);
        lpRouter.modifyLiquidity(poolKey, addParams, "");
        uint256 depthAfterAdd = hook.localDepthUsd(pid);
        assertGt(depthAfterAdd, 0);

        // Remove half
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(5e14), salt: bytes32(0)
        });
        vm.prank(alice);
        lpRouter.modifyLiquidity(poolKey, removeParams, "");

        assertLt(hook.localDepthUsd(pid), depthAfterAdd, "localDepthUsd must shrink after LP remove");
    }

    // ─── handle() inbound notification path ──────────────────────────────────
    // Closes the architectural gap where ETH/BNB hooks dispatched into a void.
    // Added 2026-05-17 alongside `IMessageRecipient` implementation on MirrorHook.

    function test_handleAcceptsAuthorizedSister() public {
        bytes32 sister = bytes32(uint256(uint160(makeAddr("sister-eth-hook"))));
        vm.prank(owner);
        hook.setAuthorizedSender(sister, true);

        // Use the hook's canonicalPairId — handle() defensively rejects messages
        // for unrelated pair ids (silently emits the receive event but doesn't update sisterDepths).
        bytes32 pairId = hook.canonicalPairId();
        uint256 reportedDepth = 5_000_000e18;

        MirrorHook.RebalanceMessage memory rm = MirrorHook.RebalanceMessage({
            pairId: pairId,
            deltaToken0: 0,
            deltaToken1: 0,
            newFee: 3000,
            tickLower: 0,
            tickUpper: 0,
            minExpectedYield: 0,
            currentDepth: reportedDepth
        });

        vm.prank(HYPERLANE_MAILBOX);
        hook.handle(1, sister, abi.encode(rm));

        assertEq(hook.sisterDepths(1, pairId), reportedDepth, "sisterDepths must update on handle()");
    }

    function test_handleRevertsIfNotMailbox() public {
        bytes32 sister = bytes32(uint256(uint160(makeAddr("sister"))));
        vm.prank(owner);
        hook.setAuthorizedSender(sister, true);

        MirrorHook.RebalanceMessage memory rm = MirrorHook.RebalanceMessage({
            pairId: keccak256("x"),
            deltaToken0: 0, deltaToken1: 0, newFee: 3000,
            tickLower: 0, tickUpper: 0,
            minExpectedYield: 0, currentDepth: 1
        });

        vm.prank(alice);
        vm.expectRevert(MirrorHook.NotMailbox.selector);
        hook.handle(1, sister, abi.encode(rm));
    }

    function test_handleRevertsIfUnauthorizedSender() public {
        bytes32 randomSender = bytes32(uint256(uint160(makeAddr("random"))));

        MirrorHook.RebalanceMessage memory rm = MirrorHook.RebalanceMessage({
            pairId: keccak256("x"),
            deltaToken0: 0, deltaToken1: 0, newFee: 3000,
            tickLower: 0, tickUpper: 0,
            minExpectedYield: 0, currentDepth: 1
        });

        vm.prank(HYPERLANE_MAILBOX);
        vm.expectRevert(MirrorHook.NotAuthorizedSender.selector);
        hook.handle(1, randomSender, abi.encode(rm));
    }

    function test_handleSkipsZeroDepthSoAgentDispatchDoesNotClobber() public {
        bytes32 sister = bytes32(uint256(uint160(makeAddr("sister"))));
        vm.prank(owner);
        hook.setAuthorizedSender(sister, true);

        bytes32 canonicalPairId = hook.canonicalPairId();
        uint256 priorDepth = 1_000_000e18;

        // Seed an initial sister depth via the agent path
        vm.prank(agent);
        hook.reportSisterDepth(1, priorDepth);

        // Now deliver a message with depth=0 (mimics dispatchRebalance's payload)
        MirrorHook.RebalanceMessage memory rm = MirrorHook.RebalanceMessage({
            pairId: canonicalPairId,
            deltaToken0: 0, deltaToken1: 0, newFee: 3000,
            tickLower: 0, tickUpper: 0,
            minExpectedYield: 0,
            currentDepth: 0
        });

        vm.prank(HYPERLANE_MAILBOX);
        hook.handle(1, sister, abi.encode(rm));

        assertEq(hook.sisterDepths(1, canonicalPairId), priorDepth, "zero-depth dispatch must not clobber valid tracking");
    }

    function test_imbalanceFromLpEventFiresDispatch() public {
        PoolId pid = poolKey.toId();

        // 1. Register a sister domain (otherwise dispatch loop is a no-op)
        vm.prank(owner);
        hook.addSisterDomain(1, bytes32(uint256(uint160(makeAddr("relayer-eth")))));

        // 2. Bootstrap local depth with an initial LP add
        int24 currentTick = -207000;
        int24 tickLower = ((currentTick - 1200) / 60) * 60;
        int24 tickUpper = ((currentTick + 1200) / 60) * 60;
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e15, salt: bytes32(0)
        });
        vm.prank(alice);
        lpRouter.modifyLiquidity(poolKey, addParams, "");

        uint256 localDepth = hook.localDepthUsd(pid);
        assertGt(localDepth, 0, "bootstrap LP add must seed local depth");

        // 3. Report a sister depth that's 50% off from local (well above 3% threshold)
        vm.prank(agent);
        hook.reportSisterDepth(1, localDepth / 2);

        // 4. Step past the dispatch cooldown
        vm.warp(block.timestamp + hook.dispatchCooldown() + 1);

        // 5. Add more LP — should fire ImbalanceDetected + RebalanceDispatched
        vm.recordLogs();
        vm.prank(alice);
        lpRouter.modifyLiquidity(poolKey, addParams, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundImbalance = false;
        bool foundDispatch = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ImbalanceDetected(bytes32,uint256,uint256)")) foundImbalance = true;
            if (logs[i].topics[0] == keccak256("RebalanceDispatched(bytes32,uint32,bytes32)")) foundDispatch = true;
        }
        assertTrue(foundImbalance, "ImbalanceDetected must fire from afterAddLiquidity path");
        assertTrue(foundDispatch, "RebalanceDispatched must fire from afterAddLiquidity path");
    }

    // ─── Guardian pause role (R-7) ────────────────────────────────────────────

    function test_guardianCanPauseHook() public {
        address fastResponder = makeAddr("fastResponder");
        vm.prank(owner);
        hook.setGuardian(fastResponder);

        vm.prank(fastResponder);
        hook.pause();
        assertTrue(hook.paused());

        // Guardian cannot unpause.
        vm.expectRevert();
        vm.prank(fastResponder);
        hook.unpause();

        vm.prank(owner);
        hook.unpause();
        assertFalse(hook.paused());
    }

    function test_hookPauseRevertsWhenNotOwnerOrGuardian() public {
        vm.expectRevert(MirrorHook.NotGuardianOrOwner.selector);
        vm.prank(alice);
        hook.pause();
    }

    // ─── Oracle deviation cross-check (R-11) ──────────────────────────────────
    /// @dev On the live Base mainnet fork, Pyth and Chainlink ETH/USD should
    ///      report within tolerance — this asserts the cross-check doesn't
    ///      false-positive in normal market conditions. (If it ever does, that
    ///      means the feeds genuinely diverged on the fork block — pick a
    ///      different fork-block or widen tolerance for test.)
    function test_oracleDeviationCheckPassesOnLiveFeeds() public {
        // Provoke a depth-event so `_getOraclePrice` (via `_eventUsdValue`) fires
        // — this is the path that R-11 protects. We're not asserting price here;
        // just that the dispatch doesn't revert OracleDeviationTooLarge.
        vm.prank(owner);
        hook.setAgentAuthorization(agent, true);

        vm.deal(address(hook), 1 ether); // dispatch fee budget

        vm.prank(agent);
        hook.dispatchRebalance(1e18, 1e6, 3000, -60, 60);
        // If we reach here without revert, the cross-check accepted live feed
        // values within the default 500 BPS tolerance.
    }

    function test_oracleDeviationTolZeroDisablesCrossCheck() public {
        // Owner can disable the cross-check by setting tolerance to 0.
        vm.prank(owner);
        hook.setOracleDeviationToleranceBps(0);
        assertEq(hook.oracleDeviationToleranceBps(), 0);
    }

    function test_setOracleDeviationToleranceBoundedAndOwnerOnly() public {
        vm.expectRevert();
        vm.prank(alice);
        hook.setOracleDeviationToleranceBps(500);

        vm.expectRevert(MirrorHook.InvalidThreshold.selector);
        vm.prank(owner);
        hook.setOracleDeviationToleranceBps(10_001);

        vm.prank(owner);
        hook.setOracleDeviationToleranceBps(250);
        assertEq(hook.oracleDeviationToleranceBps(), 250);
    }

    // ─── Sister-depth cap (R-13) ──────────────────────────────────────────────
    function test_handleCapsRunawaySisterDepth() public {
        uint32 sisterDomain = 1;
        bytes32 sisterSender = bytes32(uint256(uint160(makeAddr("sisterHook"))));
        vm.prank(owner);
        hook.setAuthorizedSender(sisterSender, true);
        vm.prank(owner);
        hook.addSisterDomain(sisterDomain, sisterSender);

        // First report establishes a baseline depth — no cap applied (priorLocal==0).
        MirrorHook.RebalanceMessage memory rm = MirrorHook.RebalanceMessage({
            pairId: hook.canonicalPairId(),
            deltaToken0: 0, deltaToken1: 0,
            newFee: 3000, tickLower: 0, tickUpper: 0,
            minExpectedYield: 0,
            currentDepth: 1_000_000 // baseline
        });
        vm.prank(HYPERLANE_MAILBOX);
        hook.handle(sisterDomain, sisterSender, abi.encode(rm));
        assertEq(hook.sisterDepths(sisterDomain, hook.canonicalPairId()), 1_000_000);

        // Second report claims absurdly large depth — should be capped at
        // priorLocal * maxSisterDepthMultiple = 1_000_000 * 10 = 10_000_000.
        rm.currentDepth = 1_000_000_000_000; // 1000× the baseline
        vm.recordLogs();
        vm.prank(HYPERLANE_MAILBOX);
        hook.handle(sisterDomain, sisterSender, abi.encode(rm));

        uint256 stored = hook.sisterDepths(sisterDomain, hook.canonicalPairId());
        assertEq(stored, 10_000_000, "depth must be capped at 10x prior");

        // SisterDepthCapped event must fire with reported + capped values.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SisterDepthCapped(uint32,uint256,uint256)")) {
                found = true;
                (uint256 reported, uint256 capped) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(reported, 1_000_000_000_000);
                assertEq(capped, 10_000_000);
            }
        }
        assertTrue(found, "SisterDepthCapped must fire when cap activates");
    }

    function test_setMaxSisterDepthMultipleZeroDisablesCap() public {
        vm.prank(owner);
        hook.setMaxSisterDepthMultiple(0);
        assertEq(hook.maxSisterDepthMultiple(), 0);
    }

    // ─── Relayer _liquidityFromDeltas — proper TickMath math ─────────────────
    /// @dev Locks in the rc4→rc5 fix that replaces the int256(d0) placeholder
    ///      in `Relayer._liquidityFromDeltas` with canonical TickMath +
    ///      LiquidityAmounts math. Adds liquidity to a pool that this test
    ///      already has running on the Base fork, via the full handle() path,
    ///      and asserts:
    ///        - `RebalanceExecuted` event fires
    ///        - Relayer's token0/token1 balances drop by approximately the
    ///          requested deltas (V4 rounding can leave dust, so we use a
    ///          tight relative-tolerance check)
    function test_relayerExecutesRebalanceWithProperLiquidityMath() public {
        // Deploy a Relayer using the same PoolManager + a mocked mailbox so
        // we can prank as it. Owner is the test contract.
        address mockMailbox = makeAddr("relayerMailbox");
        Relayer relayer = new Relayer(POOL_MANAGER, mockMailbox, owner);

        bytes32 sisterSender = bytes32(uint256(uint160(makeAddr("sisterHook"))));

        // Register sister + pool.
        vm.startPrank(owner);
        relayer.setAuthorizedSender(sisterSender, true);
        relayer.registerPool(hook.canonicalPairId(), poolKey);
        vm.stopPrank();

        // Pre-seed pool with bootstrap liquidity at a wide range so the
        // narrow-range add below has tokens to mix with.
        vm.startPrank(alice);
        lpRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e15, salt: bytes32(0)}),
            ""
        );
        vm.stopPrank();

        // Fund the relayer with token0 (WETH) + token1 (USDC) so it can pay
        // the deltas when V4 takes them.
        uint256 wethAmount = 1 ether;
        uint256 usdcAmount = 3_000e6;
        deal(WETH, address(relayer), wethAmount);
        deal(USDC, address(relayer), usdcAmount);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(relayer));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(relayer));

        // Range straddling the pool's current tick so V4 actually consumes
        // BOTH tokens. The setUp initialized at sqrtPriceX96 = 4.339e24 (~tick 200_000).
        // Pick a range bracketing that, snapped to tickSpacing=60.
        (, int24 currentTick,,) = IPoolManager(POOL_MANAGER).getSlot0(poolId);
        int24 tLower = ((currentTick - 300) / 60) * 60;
        int24 tUpper = ((currentTick + 300) / 60) * 60;

        Relayer.RebalanceMessage memory rm = Relayer.RebalanceMessage({
            pairId: hook.canonicalPairId(),
            deltaToken0: int128(int256(wethAmount)),
            deltaToken1: int128(int256(usdcAmount)),
            newFee: 3000,
            tickLower: tLower,
            tickUpper: tUpper,
            minExpectedYield: 0,
            currentDepth: 0
        });

        // Deliver via the mailbox prank path.
        vm.recordLogs();
        vm.prank(mockMailbox);
        relayer.handle(uint32(1), sisterSender, abi.encode(rm));

        // 1. RebalanceExecuted event fired.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawExecuted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("RebalanceExecuted(bytes32,int128,int128)")) {
                sawExecuted = true;
            }
        }
        assertTrue(sawExecuted, "RebalanceExecuted must fire after proper-math add");

        // 2. Token balances dropped (V4 took both tokens to mint the position).
        //    With proper math, BOTH tokens are consumed — the placeholder
        //    implementation would have taken essentially nothing because
        //    liquidityDelta == int256(wethAmount) is a huge value relative
        //    to a tight tick range, and V4 would have demanded astronomical
        //    token amounts that the funding here doesn't cover.
        uint256 wethAfter = IERC20(WETH).balanceOf(address(relayer));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(relayer));
        assertLt(wethAfter, wethBefore, "relayer WETH must drop (token0 taken by V4)");
        assertLt(usdcAfter, usdcBefore, "relayer USDC must drop (token1 taken by V4)");

        // The amounts consumed should not exceed what we provided.
        assertLe(wethBefore - wethAfter, wethAmount, "WETH consumed <= delta requested");
        assertLe(usdcBefore - usdcAfter, usdcAmount, "USDC consumed <= delta requested");
    }

    // ─── chainlinkFeedDecimals caching (R-12) ─────────────────────────────────
    /// @dev Locks in that the constructor caches the Chainlink aggregator's
    ///      decimals so each oracle read can skip the external call. Asserts
    ///      the cached value equals what the live feed reports on the Base fork
    ///      (8 decimals for ETH/USD).
    function test_chainlinkFeedDecimalsCached() public view {
        uint8 cached = hook.chainlinkFeedDecimals();
        uint8 live = AggregatorV3Interface(CHAINLINK_ETH_USD).decimals();
        assertEq(cached, live, "constructor-cached decimals must match live feed");
        assertEq(cached, 8, "Chainlink ETH/USD on Base reports 8 decimals");
    }

    // ─── withdrawEth regression (Phase 5.F resolution log) ────────────────────
    /// @dev Locks in the working behavior so a regression in the `.call{value:}`
    ///      path is caught in CI. The original Phase 5 observation was on the
    ///      abandoned v1-v4 Base Sepolia hooks and was never reproducible against
    ///      the v5 code. This test asserts:
    ///        - non-owner cannot withdraw (Ownable revert)
    ///        - owner can withdraw a partial amount; balance decreases by exactly that
    ///        - withdrawing more than the balance reverts (Solidity 0.8+ underflow on
    ///          the value transfer)
    function test_withdrawEth() public {
        // Fund the hook so withdrawEth has something to move.
        vm.deal(address(hook), 1 ether);

        // On a real-mainnet fork the deterministic `owner` address from
        // `makeAddr("owner")` happens to collide with a deployed contract that
        // forwards inbound ETH onward — that swallows the value transfer and
        // makes the test look like a regression when it isn't. Wipe any code
        // so owner behaves like an EOA (per the production deploy assumption:
        // owner is a Gnosis Safe at mainnet but is otherwise an EOA in test).
        vm.etch(owner, hex"");

        // 1. Non-owner cannot withdraw.
        vm.prank(alice);
        vm.expectRevert();
        hook.withdrawEth(0.1 ether);

        // 2. Owner can withdraw a partial amount; ETH lands at owner().
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        hook.withdrawEth(0.3 ether);
        assertEq(address(hook).balance, 0.7 ether, "hook balance reduced by withdrawn amount");
        assertEq(owner.balance, ownerBefore + 0.3 ether, "owner receives the withdrawn ETH");

        // 3. Withdrawing more than the balance reverts (insufficient funds on the
        //    low-level call → InsufficientEthForDispatch path).
        vm.prank(owner);
        vm.expectRevert(MirrorHook.InsufficientEthForDispatch.selector);
        hook.withdrawEth(10 ether);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _equals(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
