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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

// Initializes the WETH/USDC V4 pool with our hook on Base, then adds liquidity.
// Lets the MonitorAgent read non-zero getPoolState() output.
contract InitPoolWithLiquidityBase is Script {
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address hookAddr = vm.envAddress("MIRROR_HOOK_BASE");

        vm.startBroadcast(deployerKey);

        // Deploy a PoolModifyLiquidityTest router to handle the LP add
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        console2.log("PoolModifyLiquidityTest:", address(lp));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // sqrtPriceX96 ≈ $3000/ETH (WETH=token0, USDC=token1)
        uint160 sqrtPriceX96 = 4339505179874779488639720;
        // Try to initialize — if already done, ignore the revert and proceed to add liquidity
        try IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96) {
            console2.log("Pool initialized");
        } catch {
            console2.log("Pool already initialized - proceeding to add liquidity");
        }

        // Approve LP router to spend our tokens
        IERC20(WETH).approve(address(lp), type(uint256).max);
        IERC20(USDC).approve(address(lp), type(uint256).max);

        // Narrow range straddling the current tick (~$3000/ETH -> tick -196257).
        // Range -200040 to -192180 = ~4% width. tickSpacing 60. Multiples of 60.
        //
        // L=1e12 is small enough that token0+token1 amounts fit comfortably
        // within the 100 WETH + 1M USDC the script funds.
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -200040, tickUpper: -192180, liquidityDelta: 1e12, salt: bytes32(0)});
        BalanceDelta delta = lp.modifyLiquidity(key, params, "");
        console2.log("LP add delta amount0:", int256(delta.amount0()));
        console2.log("LP add delta amount1:", int256(delta.amount1()));

        vm.stopBroadcast();
    }
}
