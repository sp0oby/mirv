// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// Initialize the USDC/WETH V4 pool on Base Sepolia with our hook, then drive
// the full V4-event → cross-chain dispatch pipeline:
//   1. Bootstrap LP add → seeds localDepthUsd
//   2. Report sister depth (creates imbalance)
//   3. Second LP add → ImbalanceDetected + RebalanceDispatched fires from afterAddLiquidity
//
// NOTE: On Base Sepolia, USDC < WETH so USDC = currency0, WETH = currency1
// (reversed from Base mainnet). _updateLocalDepth still uses oracle math assuming
// token0 = ETH, so values are unit-skewed on testnet — mechanism validates,
// magnitudes won't match mainnet semantics. Fix is per-pair oracle config.
contract TriggerV4DispatchBaseSepolia is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address poolManagerAddr = vm.envAddress("POOL_MANAGER_BASE_SEPOLIA");
        address hookAddr = vm.envAddress("MIRROR_HOOK_BASE");
        address usdc = vm.envAddress("USDC_BASE_SEPOLIA");
        address weth = vm.envAddress("WETH_BASE_SEPOLIA");

        require(usdc < weth, "Expected USDC < WETH on Base Sepolia (token0/1 ordering)");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        MirrorHook hook = MirrorHook(payable(hookAddr));

        vm.startBroadcast(deployerKey);

        // Wrap ETH → WETH so we have token1 to seed the pool
        uint256 wethBal = IWETH9(weth).balanceOf(deployer);
        if (wethBal < 0.002 ether) {
            IWETH9(weth).deposit{value: 0.002 ether}();
            console2.log("Wrapped 0.002 ETH -> WETH");
        }

        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(poolManager);
        console2.log("LP router:", address(lpRouter));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(weth),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // ETH ≈ $2186 (Chainlink), USDC = $1. Token1 (WETH wei) per token0 (USDC raw):
        //   1 USDC raw = $1e-6 → in WETH wei = 1e18/2186/1e6 ≈ 4.575e8
        //   tick ≈ ln(4.575e8) / ln(1.0001) ≈ 199,800
        // Use a wide range to ensure in-range LP regardless of oracle drift.
        int24 currentTick = 199800;
        int24 tickLower = ((currentTick - 4200) / 60) * 60;
        int24 tickUpper = ((currentTick + 4200) / 60) * 60;

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        try poolManager.initialize(key, sqrtPriceX96) {
            console2.log("Pool initialized at tick", currentTick);
        } catch {
            console2.log("Pool already initialized");
        }

        // Approve tokens to the LP router
        IERC20(usdc).approve(address(lpRouter), type(uint256).max);
        IERC20(weth).approve(address(lpRouter), type(uint256).max);

        // ── Bootstrap LP add ──────────────────────────────────────────────
        // Small L so we don't burn through the deployer's 20 USDC.
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e9, salt: bytes32(0)});
        BalanceDelta delta1 = lpRouter.modifyLiquidity(key, params, "");
        console2.log("Bootstrap LP delta0 (USDC):", int256(delta1.amount0()));
        console2.log("Bootstrap LP delta1 (WETH):", int256(delta1.amount1()));

        uint256 localDepth = hook.localDepthUsd(key.toId());
        console2.log("localDepthUsd after bootstrap:", localDepth);
        require(localDepth > 0, "bootstrap should have seeded depth");

        // ── Report sister depth at 50% of local (creates imbalance > 3%) ──
        // Deployer is already authorized as agent from the Phase A smoke test.
        // Canonical pairId is bound to the hook by constructor; reportSisterDepth
        // no longer takes a pairId arg.
        hook.reportSisterDepth(11155111, localDepth / 2);
        console2.log("Reported sister depth (ETH Sepolia, domain 11155111):", localDepth / 2);

        // ── Second LP add — should fire RebalanceDispatched ───────────────
        BalanceDelta delta2 = lpRouter.modifyLiquidity(key, params, "");
        console2.log("Second LP delta0 (USDC):", int256(delta2.amount0()));
        console2.log("Second LP delta1 (WETH):", int256(delta2.amount1()));
        console2.log("localDepthUsd after second add:", hook.localDepthUsd(key.toId()));

        vm.stopBroadcast();
    }
}
