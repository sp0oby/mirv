// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MirrorVault} from "../src/MirrorVault.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SeedLiquidity
/// @notice Funds hooks with ETH for Hyperlane dispatch fees and makes an initial
///         deposit into MirrorVault. Run AFTER WireSisterDomains.
///
/// Required env vars:
///   - DEPLOYER_PRIVATE_KEY
///   - MIRROR_HOOK_BASE / _MAINNET / _BNB
///   - MIRROR_VAULT_BASE
///   - AGENT_WALLET (will be authorized on each contract)
///
/// Usage:
///   forge script script/SeedLiquidity.s.sol:SeedAll --rpc-url $ALCHEMY_BASE_URL --broadcast
contract SeedBase is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        MirrorHook  hook   = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_BASE")));
        MirrorVault vault  = MirrorVault(vm.envAddress("MIRROR_VAULT_BASE"));
        IERC20      asset  = IERC20(vault.asset());
        uint256     seed   = vm.envOr("SEED_AMOUNT_USDC", uint256(10_000e6)); // default 10k USDC

        vm.startBroadcast(deployerKey);

        // 1. Fund hook with ETH (Hyperlane dispatch fees)
        (bool ok,) = address(hook).call{value: 0.05 ether}("");
        require(ok, "hook ETH fund failed");

        // 2. Initial vault deposit
        uint256 bal = asset.balanceOf(deployer);
        require(bal >= seed, "Insufficient USDC balance for seed");
        asset.approve(address(vault), seed);
        vault.deposit(seed, deployer);

        vm.stopBroadcast();

        console2.log("Base seeded:");
        console2.log("  Hook ETH:    0.05 ether");
        console2.log("  Vault USDC:  ", seed);
        console2.log("  Vault shares:", vault.balanceOf(deployer));
    }
}

contract FundHookEthereum is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        MirrorHook hook = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_MAINNET")));

        vm.startBroadcast(deployerKey);
        (bool ok,) = address(hook).call{value: 0.05 ether}("");
        require(ok, "hook ETH fund failed");
        vm.stopBroadcast();

        console2.log("Ethereum hook funded with 0.05 ETH");
    }
}

contract FundHookBnb is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        MirrorHook hook = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_BNB")));

        vm.startBroadcast(deployerKey);
        (bool ok,) = address(hook).call{value: 0.05 ether}("");
        require(ok, "hook BNB fund failed");
        vm.stopBroadcast();

        console2.log("BNB hook funded with 0.05 BNB");
    }
}
