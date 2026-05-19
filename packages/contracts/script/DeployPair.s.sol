// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {MirrorVault} from "../src/MirrorVault.sol";
import {MirrorFactory} from "../src/MirrorFactory.sol";
import {Relayer} from "../src/Relayer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMailbox} from "../src/interfaces/IHyperlane.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

/// @title DeployPair — generic per-pair deployment for mirv
/// @notice Parameterized version of Deploy.s.sol. Takes pair-specific config
///         (name, fee, tickSpacing, oracle feeds, vault asset, hook salt) from
///         env vars so we don't have to fork the deploy script per pair.
///
/// @dev    The factory is ALREADY pair-agnostic. This script just chains the
///         per-chain deploy steps for a NEW pair onto the EXISTING factory.
///
/// @dev    Required env per pair (set before running):
///           MIRROR_PAIR_NAME       — e.g. "BTC-USDC-V1"
///           MIRROR_PAIR_FEE        — e.g. 3000
///           MIRROR_PAIR_TICK_SPACING — e.g. 60
///           MIRROR_PAIR_VAULT_ASSET — e.g. USDC address on this chain
///           MIRROR_PAIR_OTHER_TOKEN — e.g. cbBTC address on this chain
///           MIRROR_PAIR_PYTH_FEED_ID — Pyth feed for the volatile token's USD price
///           MIRROR_PAIR_CHAINLINK_FEED — Chainlink aggregator on this chain
///           MIRROR_PAIR_VAULT_NAME — ERC-4626 share name e.g. "mirv BTC/USDC Vault"
///           MIRROR_PAIR_VAULT_SYMBOL — ERC-4626 symbol e.g. "mirvBTC-USDC"
///           MIRROR_PAIR_HOOK_SALT  — pre-mined CREATE2 salt from MineHookAddress.s.sol
///           MIRROR_FACTORY_BASE    — existing factory address
///           TREASURY_BASE          — existing treasury address (fees aggregate)
///
/// @dev    Run order (per new pair):
///           1. forge script script/MineHookAddress.s.sol  (mines hook salt)
///           2. forge script script/DeployPair.s.sol:DeployPairBase
///           3. forge script script/DeployPair.s.sol:DeployPairSister
///           4. forge script script/WireSisterDomains.s.sol
///           5. forge script script/InitPoolWithLiquidity.s.sol
///         See MULTI-PAIR.md for the full runbook.

abstract contract DeployPairCommon is Script {
    function _canonicalPairId(string memory name, uint24 fee, int24 tickSpacing) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(name, fee, tickSpacing));
    }
}

// ─── Base side: hook + vault + factory registration ─────────────────────────
contract DeployPairBase is DeployPairCommon {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Pair-specific config
        string memory pairName = vm.envString("MIRROR_PAIR_NAME");
        uint24 fee = uint24(vm.envUint("MIRROR_PAIR_FEE"));
        int24 tickSpacing = int24(vm.envInt("MIRROR_PAIR_TICK_SPACING"));
        address vaultAsset = vm.envAddress("MIRROR_PAIR_VAULT_ASSET");
        address otherToken = vm.envAddress("MIRROR_PAIR_OTHER_TOKEN");
        bytes32 pythFeed = vm.envBytes32("MIRROR_PAIR_PYTH_FEED_ID");
        address chainlink = vm.envAddress("MIRROR_PAIR_CHAINLINK_FEED");
        string memory vaultName = vm.envString("MIRROR_PAIR_VAULT_NAME");
        string memory vaultSymbol = vm.envString("MIRROR_PAIR_VAULT_SYMBOL");
        bytes32 hookSalt = vm.envBytes32("MIRROR_PAIR_HOOK_SALT");

        // Chain-specific infra (already deployed)
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX_BASE");
        address poolMgr = vm.envAddress("POOL_MANAGER_BASE");
        address cctpMessenger = vm.envAddress("CCTP_TOKEN_MESSENGER_BASE");
        address factoryAddr = vm.envAddress("MIRROR_FACTORY_BASE");
        address treasury = vm.envAddress("TREASURY_BASE");

        bytes32 canonicalId = _canonicalPairId(pairName, fee, tickSpacing);

        console2.log("=== DeployPairBase for", pairName, "===");
        console2.log("Canonical ID:", uint256(canonicalId));
        console2.log("Hook salt:", uint256(hookSalt));

        vm.startBroadcast(deployerKey);

        // 1. Hook for this pair on this chain
        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(poolMgr), mailbox, chainlink, chainlink, pythFeed, canonicalId, deployer
        );
        console2.log("MirrorHook:", address(hook));

        // 2. Vault — ERC-4626 over the pair's deposit asset
        MirrorVault vault = new MirrorVault(
            IERC20(vaultAsset), cctpMessenger, treasury, deployer, vaultName, vaultSymbol
        );
        console2.log("MirrorVault:", address(vault));

        // 3. Register pair on the existing factory
        MirrorFactory factory = MirrorFactory(factoryAddr);
        if (factory.canonicalIdByName(pairName) == bytes32(0)) {
            factory.registerCanonicalPair(pairName, fee, tickSpacing);
            console2.log("Canonical pair registered");
        }
        address token0 = vaultAsset < otherToken ? vaultAsset : otherToken;
        address token1 = vaultAsset < otherToken ? otherToken : vaultAsset;
        uint32 localDomain = IMailbox(mailbox).localDomain();
        factory.registerLocalPair(canonicalId, localDomain, token0, token1, address(hook));

        // 4. Seed registry with local chain at 100% (rebalance allocations later)
        vault.addChain(localDomain, 0, bytes32(0), address(0), bytes32(0), uint16(10_000));

        // 5. Authorize the agent
        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);
        vault.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Add to .env ===");
        console2.log("MIRROR_HOOK_<PAIR>_BASE=", address(hook));
        console2.log("MIRROR_VAULT_<PAIR>_BASE=", address(vault));
    }
}

// ─── Sister chain side: hook + relayer ──────────────────────────────────────
contract DeployPairSister is DeployPairCommon {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        string memory pairName = vm.envString("MIRROR_PAIR_NAME");
        uint24 fee = uint24(vm.envUint("MIRROR_PAIR_FEE"));
        int24 tickSpacing = int24(vm.envInt("MIRROR_PAIR_TICK_SPACING"));
        bytes32 pythFeed = vm.envBytes32("MIRROR_PAIR_PYTH_FEED_ID");
        address chainlink = vm.envAddress("MIRROR_PAIR_CHAINLINK_FEED");
        bytes32 hookSalt = vm.envBytes32("MIRROR_PAIR_HOOK_SALT_SISTER");

        // Sister chain infra is read from per-chain env. Defaults to MAINNET prefix
        // (matches Deploy.s.sol convention for the canonical ETH sister); override
        // via MIRROR_PAIR_SISTER_PREFIX="ETH_SEPOLIA" etc. at run time.
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX_MAINNET");
        address poolMgr = vm.envAddress("POOL_MANAGER_MAINNET");

        bytes32 canonicalId = _canonicalPairId(pairName, fee, tickSpacing);

        vm.startBroadcast(deployerKey);

        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(poolMgr), mailbox, chainlink, chainlink, pythFeed, canonicalId, deployer
        );
        console2.log("MirrorHook (sister):", address(hook));

        Relayer relayer = new Relayer(poolMgr, mailbox, deployer);
        console2.log("Relayer (sister):", address(relayer));

        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Add to .env ===");
        console2.log("MIRROR_HOOK_<PAIR>_SISTER=", address(hook));
        console2.log("RELAYER_<PAIR>_SISTER=", address(relayer));
    }
}
