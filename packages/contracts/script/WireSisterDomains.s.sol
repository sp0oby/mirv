// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {Relayer} from "../src/Relayer.sol";

// WireSisterDomains
// Run AFTER all 3 chains have been deployed. Registers each chain's hooks as
// authorized senders for the sister relayers, and tells each hook about its
// sister relayer recipients on the other two chains.
//
// Usage per chain (run 3 times, once per chain):
//   forge script script/WireSisterDomains.s.sol:WireBase    --rpc-url $ALCHEMY_BASE_URL    --broadcast
//   forge script script/WireSisterDomains.s.sol:WireMainnet --rpc-url $ALCHEMY_MAINNET_URL --broadcast
//   forge script script/WireSisterDomains.s.sol:WireBnb     --rpc-url $ALCHEMY_BNB_URL     --broadcast

uint32 constant DOMAIN_ETHEREUM = 1;
uint32 constant DOMAIN_BASE     = 8453;
uint32 constant DOMAIN_BNB      = 56;

// ─── Base ─────────────────────────────────────────────────────────────────────
contract WireBase is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        MirrorHook hook = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_BASE")));
        bytes32 relayerEth = bytes32(uint256(uint160(vm.envAddress("RELAYER_MAINNET"))));
        bytes32 relayerBnb = bytes32(uint256(uint160(vm.envAddress("RELAYER_BNB"))));

        vm.startBroadcast(ownerKey);
        hook.addSisterDomain(DOMAIN_ETHEREUM, relayerEth);
        hook.addSisterDomain(DOMAIN_BNB,      relayerBnb);
        vm.stopBroadcast();

        console2.log("Base hook sister domains wired:");
        console2.log("  -> Ethereum relayer:", vm.envAddress("RELAYER_MAINNET"));
        console2.log("  -> BNB relayer:     ", vm.envAddress("RELAYER_BNB"));
    }
}

// ─── Ethereum mainnet ─────────────────────────────────────────────────────────
contract WireMainnet is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        MirrorHook hook    = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_MAINNET")));
        Relayer    relayer = Relayer(payable(vm.envAddress("RELAYER_MAINNET")));

        bytes32 hookBase = bytes32(uint256(uint160(vm.envAddress("MIRROR_HOOK_BASE"))));
        bytes32 hookBnb  = bytes32(uint256(uint160(vm.envAddress("MIRROR_HOOK_BNB"))));
        bytes32 relayerBase = bytes32(uint256(uint160(0))); // Base has no relayer (vault on Base)
        bytes32 relayerBnb  = bytes32(uint256(uint160(vm.envAddress("RELAYER_BNB"))));

        vm.startBroadcast(ownerKey);

        // Hook on mainnet should know about Base + BNB sisters (so it can dispatch back)
        hook.addSisterDomain(DOMAIN_BASE, hookBase);
        hook.addSisterDomain(DOMAIN_BNB,  hookBnb);

        // Relayer on mainnet should accept messages FROM Base hook + BNB hook
        relayer.setAuthorizedSender(hookBase, true);
        relayer.setAuthorizedSender(hookBnb,  true);

        vm.stopBroadcast();

        console2.log("Ethereum hook + relayer wired");
        relayerBase; // silence unused-var warning
    }
}

// ─── BNB Chain ────────────────────────────────────────────────────────────────
contract WireBnb is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        MirrorHook hook    = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_BNB")));
        Relayer    relayer = Relayer(payable(vm.envAddress("RELAYER_BNB")));

        bytes32 hookBase = bytes32(uint256(uint160(vm.envAddress("MIRROR_HOOK_BASE"))));
        bytes32 hookEth  = bytes32(uint256(uint160(vm.envAddress("MIRROR_HOOK_MAINNET"))));

        vm.startBroadcast(ownerKey);

        hook.addSisterDomain(DOMAIN_BASE,     hookBase);
        hook.addSisterDomain(DOMAIN_ETHEREUM, hookEth);

        relayer.setAuthorizedSender(hookBase, true);
        relayer.setAuthorizedSender(hookEth,  true);

        vm.stopBroadcast();

        console2.log("BNB hook + relayer wired");
    }
}
