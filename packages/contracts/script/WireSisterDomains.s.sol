// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {Relayer} from "../src/Relayer.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

// WireSisterDomains
// Run AFTER all 3 chains have been deployed. Registers each chain's hooks as
// authorized senders for the sister relayers, and tells each hook about its
// sister relayer recipients on the other two chains.
//
// Usage per chain (run 3 times, once per chain):
//   forge script script/WireSisterDomains.s.sol:WireBase    --rpc-url $ALCHEMY_BASE_URL    --broadcast
//   forge script script/WireSisterDomains.s.sol:WireMainnet --rpc-url $ALCHEMY_MAINNET_URL --broadcast
//   forge script script/WireSisterDomains.s.sol:WireBnb     --rpc-url $ALCHEMY_BNB_URL     --broadcast

// Domain IDs default to Hyperlane mainnet domains, override via env for testnets
// (e.g. Sepolia: DOMAIN_ETHEREUM=11155111, DOMAIN_BASE=84532)
abstract contract WireHelpers is Script {
    function _domain(string memory key, uint32 fallback_) internal view returns (uint32) {
        try vm.envUint(key) returns (uint256 v) {
            return uint32(v);
        } catch {
            return fallback_;
        }
    }

    function _addrOrZero(string memory key) internal view returns (address) {
        try vm.envAddress(key) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}

// ─── Base ─────────────────────────────────────────────────────────────────────
contract WireBase is WireHelpers {
    function run() external {
        uint256 ownerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");

        MirrorHook hook = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_BASE")));

        uint32 domainEth = _domain("DOMAIN_ETHEREUM", 1);
        uint32 domainBnb = _domain("DOMAIN_BNB", 56);

        address relayerEth = _addrOrZero("RELAYER_MAINNET");
        address relayerBnb = _addrOrZero("RELAYER_BNB");

        vm.startBroadcast(ownerKey);
        if (relayerEth != address(0)) {
            hook.addSisterDomain(domainEth, _b32(relayerEth));
            console2.log("  Base hook -> Ethereum relayer:", relayerEth);
        } else {
            console2.log("  Skipping Ethereum sister (RELAYER_MAINNET unset)");
        }
        if (relayerBnb != address(0)) {
            hook.addSisterDomain(domainBnb, _b32(relayerBnb));
            console2.log("  Base hook -> BNB relayer:", relayerBnb);
        } else {
            console2.log("  Skipping BNB sister (RELAYER_BNB unset)");
        }
        vm.stopBroadcast();
    }
}

// ─── Ethereum mainnet ─────────────────────────────────────────────────────────
contract WireMainnet is WireHelpers {
    function run() external {
        uint256 ownerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");

        MirrorHook hook = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_MAINNET")));
        Relayer relayer = Relayer(payable(vm.envAddress("RELAYER_MAINNET")));

        uint32 domainBase = _domain("DOMAIN_BASE", 8453);
        uint32 domainBnb = _domain("DOMAIN_BNB", 56);

        address hookBase = _addrOrZero("MIRROR_HOOK_BASE");
        address hookBnb = _addrOrZero("MIRROR_HOOK_BNB");

        vm.startBroadcast(ownerKey);
        if (hookBase != address(0)) {
            hook.addSisterDomain(domainBase, _b32(hookBase));
            relayer.setAuthorizedSender(_b32(hookBase), true);
            console2.log("  Ethereum hook + relayer <- Base hook:", hookBase);
        } else {
            console2.log("  Skipping Base wiring (MIRROR_HOOK_BASE unset)");
        }
        if (hookBnb != address(0)) {
            hook.addSisterDomain(domainBnb, _b32(hookBnb));
            relayer.setAuthorizedSender(_b32(hookBnb), true);
            console2.log("  Ethereum hook + relayer <- BNB hook:", hookBnb);
        } else {
            console2.log("  Skipping BNB wiring (MIRROR_HOOK_BNB unset)");
        }
        vm.stopBroadcast();
    }
}

// ─── BNB Chain ────────────────────────────────────────────────────────────────
contract WireBnb is WireHelpers {
    function run() external {
        uint256 ownerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");

        MirrorHook hook = MirrorHook(payable(vm.envAddress("MIRROR_HOOK_BNB")));
        Relayer relayer = Relayer(payable(vm.envAddress("RELAYER_BNB")));

        uint32 domainBase = _domain("DOMAIN_BASE", 8453);
        uint32 domainEth = _domain("DOMAIN_ETHEREUM", 1);

        address hookBase = _addrOrZero("MIRROR_HOOK_BASE");
        address hookEth = _addrOrZero("MIRROR_HOOK_MAINNET");

        vm.startBroadcast(ownerKey);
        if (hookBase != address(0)) {
            hook.addSisterDomain(domainBase, _b32(hookBase));
            relayer.setAuthorizedSender(_b32(hookBase), true);
            console2.log("  BNB hook + relayer <- Base hook:", hookBase);
        }
        if (hookEth != address(0)) {
            hook.addSisterDomain(domainEth, _b32(hookEth));
            relayer.setAuthorizedSender(_b32(hookEth), true);
            console2.log("  BNB hook + relayer <- Ethereum hook:", hookEth);
        }
        vm.stopBroadcast();
    }
}
