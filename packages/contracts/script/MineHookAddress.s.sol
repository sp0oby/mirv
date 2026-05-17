// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

/// @title MineHookAddress
/// @notice Brute-force mines a CREATE2 salt so that the deployed MirrorHook address
///         has lower bits matching the required Hooks.Permissions flags.
///
/// Usage:
///   forge script script/MineHookAddress.s.sol \
///     --sig "run(address,address,address,address,bytes32,bytes32)" \
///     <poolManager> <mailbox> <pyth> <chainlinkFeed> <pythFeedId> <canonicalPairId>
///
/// canonicalPairId for the initial ETH/USDC V1 pair:
///   keccak256(abi.encodePacked("ETH-USDC-V1", uint24(3000), int24(60)))
///
/// Output: the salt to use in Deploy.s.sol
contract MineHookAddress is Script {
    function run(
        address poolManager,
        address mailbox,
        address pyth,
        address chainlinkFeed,
        bytes32 pythFeedId,
        bytes32 canonicalPairId
    ) external view {
        // The hook permissions we need encoded in the address lower bits
        // afterSwap=true, afterAddLiquidity=true, afterRemoveLiquidity=true
        uint160 requiredFlags =
            uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

        // Owner is the deployer EOA (used in constructor args, must match Deploy.s.sol)
        address owner = vm.addr(EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY"));

        // CREATE2 deployer: Foundry routes `new X{salt}()` through this canonical address
        // when broadcasting. Must match for the mined salt → predicted address to be correct.
        address deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        // Compute the creation bytecode hash — must match Deploy.s.sol constructor args exactly
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            mailbox,
            pyth,
            chainlinkFeed,
            pythFeedId,
            canonicalPairId,
            owner
        );
        bytes32 bytecodeHash = keccak256(abi.encodePacked(type(MirrorHook).creationCode, constructorArgs));

        uint256 found;
        for (uint256 i; i < 160_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = _computeCreate2Address(deployer, salt, bytecodeHash);

            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == requiredFlags) {
                console2.log("=== Hook address found ===");
                console2.log("Salt (decimal):", i);
                console2.logBytes32(salt);
                console2.log("Predicted address:", predicted);
                found = i;
                break;
            }
        }

        if (found == 0) {
            console2.log("Not found in 160k iterations - increase loop bound");
        }
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 bytecodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, bytecodeHash)))));
    }
}
