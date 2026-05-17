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

// Validates the INBOUND notification path: an LP event on ETH Sepolia fires the
// local hook's _handleEvent, which dispatches a Hyperlane message to the Base
// hook's `handle()`. When delivered, the Base hook's `sisterDepths[84532][pairId]`
// must update to reflect ETH's reported localDepthUsd.
//
// Mirrors TriggerV4DispatchBaseSepolia structure. ETH Sepolia uses the same
// token ordering as Base Sepolia (USDC < WETH), so token0/token1 layout matches.
contract TriggerV4DispatchEthSepolia is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address poolManagerAddr = vm.envAddress("POOL_MANAGER_ETH_SEPOLIA");
        address hookAddr = vm.envAddress("MIRROR_HOOK_MAINNET");
        address usdc = vm.envAddress("USDC_ETH_SEPOLIA");
        address weth = vm.envAddress("WETH_ETH_SEPOLIA");

        require(usdc < weth, "Expected USDC < WETH on ETH Sepolia (token0/1 ordering)");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        MirrorHook hook = MirrorHook(payable(hookAddr));

        vm.startBroadcast(deployerKey);

        // Wrap ETH → WETH for the LP-side
        uint256 wethBal = IWETH9(weth).balanceOf(deployer);
        if (wethBal < 0.002 ether) {
            IWETH9(weth).deposit{value: 0.002 ether}();
            console2.log("Wrapped 0.002 ETH -> WETH");
        }

        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(poolManager);
        console2.log("LP router (ETH Sepolia):", address(lpRouter));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(weth),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // Pool was already initialized in the earlier redeploy + init step at tick 199800.
        // Skipping initialize() — forge --broadcast extracts each external call as its
        // own tx and won't honor try/catch around a known-reverting call.
        int24 currentTick = 199800;

        IERC20(usdc).approve(address(lpRouter), type(uint256).max);
        IERC20(weth).approve(address(lpRouter), type(uint256).max);

        int24 tickLower = ((currentTick - 4200) / 60) * 60;
        int24 tickUpper = ((currentTick + 4200) / 60) * 60;

        // Bootstrap LP add — seeds localDepthUsd on ETH hook, no dispatch yet
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e9, salt: bytes32(0)});
        BalanceDelta delta1 = lpRouter.modifyLiquidity(key, params, "");
        console2.log("Bootstrap LP delta0 (USDC):", int256(delta1.amount0()));
        console2.log("Bootstrap LP delta1 (WETH):", int256(delta1.amount1()));

        uint256 localDepth = hook.localDepthUsd(key.toId());
        console2.log("localDepthUsd (ETH) after bootstrap:", localDepth);
        require(localDepth > 0, "bootstrap must seed depth");

        // Report sister depth at 50% of local on ETH hook so the next event triggers
        // imbalance detection → _dispatchToAllSisters → Hyperlane → Base hook.handle()
        // Canonical pairId is bound to the hook; reportSisterDepth no longer takes it.
        hook.reportSisterDepth(84532, localDepth / 2);
        console2.log("Reported sister depth on ETH hook (domain 84532):", localDepth / 2);

        // Second LP add — should fire RebalanceDispatched from ETH hook back to Base hook
        BalanceDelta delta2 = lpRouter.modifyLiquidity(key, params, "");
        console2.log("Second LP delta0 (USDC):", int256(delta2.amount0()));
        console2.log("Second LP delta1 (WETH):", int256(delta2.amount1()));
        console2.log("localDepthUsd (ETH) after second add:", hook.localDepthUsd(key.toId()));

        vm.stopBroadcast();
    }
}
