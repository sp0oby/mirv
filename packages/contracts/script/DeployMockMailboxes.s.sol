// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockHyperlaneMailbox} from "../src/mocks/MockHyperlaneMailbox.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

// Deploy MockHyperlaneMailbox on a chain (run once per Anvil fork).
// Hyperlane domain IDs: Ethereum=1, Base=8453, BNB=56

contract DeployMockMailboxMainnet is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockHyperlaneMailbox m = new MockHyperlaneMailbox(1);
        console2.log("MockHyperlaneMailbox (Mainnet, domain 1):", address(m));
        vm.stopBroadcast();
    }
}

contract DeployMockMailboxBase is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockHyperlaneMailbox m = new MockHyperlaneMailbox(8453);
        console2.log("MockHyperlaneMailbox (Base, domain 8453):", address(m));
        vm.stopBroadcast();
    }
}

contract DeployMockMailboxBnb is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        MockHyperlaneMailbox m = new MockHyperlaneMailbox(56);
        console2.log("MockHyperlaneMailbox (BNB, domain 56):", address(m));
        vm.stopBroadcast();
    }
}
