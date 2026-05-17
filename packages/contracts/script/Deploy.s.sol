// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {MirrorVault} from "../src/MirrorVault.sol";
import {MirrorFactory} from "../src/MirrorFactory.sol";
import {Treasury} from "../src/Treasury.sol";
import {Relayer} from "../src/Relayer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMailbox} from "../src/interfaces/IHyperlane.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

// Deploy — Foundry deployment scripts for mirv contracts.
// All chain-specific addresses are read from .env so that MineHookAddress.s.sol
// and these deploys use byte-for-byte identical constructor args (otherwise the
// CREATE2 bytecode hashes differ and the mined salt is invalid).
//
// Run order:
//   forge script script/Deploy.s.sol:DeployBase     --rpc-url $RPC --broadcast
//   forge script script/Deploy.s.sol:DeployEthereum --rpc-url $RPC --broadcast
//   forge script script/Deploy.s.sol:DeployBnb      --rpc-url $RPC --broadcast

bytes32 constant PYTH_ETH_USD_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

// Canonical pair id for the initial ETH/USDC V1 pair — computed identically on
// every chain so MirrorHooks for the same logical pair share their canonical id.
// Matches MirrorFactory.registerCanonicalPair("ETH-USDC-V1", 3000, 60).
bytes32 constant CANONICAL_PAIR_ID_ETH_USDC =
    keccak256(abi.encodePacked("ETH-USDC-V1", uint24(3000), int24(60)));

// ─── Base deployment ──────────────────────────────────────────────────────────
contract DeployBase is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address safe = vm.envAddress("TREASURY_SAFE");
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX_BASE");
        address poolMgr = vm.envAddress("POOL_MANAGER_BASE");
        address pyth = vm.envAddress("PYTH_ADDRESS_BASE");
        address chainlink = vm.envAddress("CHAINLINK_ETH_USD_BASE");
        address vaultAsset = vm.envAddress("VAULT_ASSET_BASE");
        address cctpMessenger = vm.envAddress("CCTP_TOKEN_MESSENGER_BASE");
        bytes32 hookSalt = bytes32(vm.envUint("HOOK_SALT_BASE"));

        vm.startBroadcast(deployerKey);

        Treasury treasury = new Treasury(safe, deployer);
        console2.log("Treasury:", address(treasury));

        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(poolMgr), mailbox, pyth, chainlink, PYTH_ETH_USD_ID, CANONICAL_PAIR_ID_ETH_USDC, deployer
        );
        console2.log("MirrorHook (Base):", address(hook));

        MirrorVault vault = new MirrorVault(
            IERC20(vaultAsset), cctpMessenger, address(treasury), deployer, "mirv ETH/USDC Vault", "mirvETH-USDC"
        );
        console2.log("MirrorVault (Base):", address(vault));

        MirrorFactory factory = new MirrorFactory(deployer);
        console2.log("MirrorFactory:", address(factory));

        // Register the canonical pair so subsequent registerLocalPair calls work
        factory.registerCanonicalPair("ETH-USDC-V1", uint24(3000), int24(60));

        // Register this chain's local pair under the canonical id. token0 must be < token1.
        address token0 = vaultAsset < vm.envAddress("WETH_BASE") ? vaultAsset : vm.envAddress("WETH_BASE");
        address token1 = vaultAsset < vm.envAddress("WETH_BASE") ? vm.envAddress("WETH_BASE") : vaultAsset;
        uint32 localDomain = IMailbox(mailbox).localDomain();
        factory.registerLocalPair(CANONICAL_PAIR_ID_ETH_USDC, localDomain, token0, token1, address(hook));

        // Seed the chain registry with the local chain at 100% allocation. After the
        // sister chains deploy, owner calls Vault.addChain + setAllocations to rebalance
        // (e.g. 60% Base / 40% Ethereum at mainnet launch).
        vault.addChain(localDomain, 0, bytes32(0), address(0), bytes32(0), uint16(10_000));

        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);
        vault.setAgentAuthorization(agentWallet, true);
        factory.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Add to .env ===");
        console2.log("MIRROR_HOOK_BASE=", address(hook));
        console2.log("MIRROR_VAULT_BASE=", address(vault));
        console2.log("MIRROR_FACTORY_BASE=", address(factory));
        console2.log("TREASURY_BASE=", address(treasury));
    }
}

// ─── Ethereum mainnet deployment ──────────────────────────────────────────────
contract DeployEthereum is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX_MAINNET");
        address poolMgr = vm.envAddress("POOL_MANAGER_MAINNET");
        address pyth = vm.envAddress("PYTH_ADDRESS_MAINNET");
        address chainlink = vm.envAddress("CHAINLINK_ETH_USD_MAINNET");
        bytes32 hookSalt = bytes32(vm.envUint("HOOK_SALT_MAINNET"));

        vm.startBroadcast(deployerKey);

        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(poolMgr), mailbox, pyth, chainlink, PYTH_ETH_USD_ID, CANONICAL_PAIR_ID_ETH_USDC, deployer
        );
        console2.log("MirrorHook (Ethereum):", address(hook));

        Relayer relayer = new Relayer(poolMgr, mailbox, deployer);
        console2.log("Relayer (Ethereum):", address(relayer));

        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Add to .env ===");
        console2.log("MIRROR_HOOK_MAINNET=", address(hook));
        console2.log("RELAYER_MAINNET=", address(relayer));
    }
}

// ─── Redeploy only the Hook (+ Factory on Base) when hook bytecode changes ──
// Use when a Hook bug-fix patch ships and the existing Treasury/Vault/Relayer
// can be reused. Re-mine the salt first via MineHookAddress.s.sol.
contract RedeployHookBase is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX_BASE");
        address poolMgr = vm.envAddress("POOL_MANAGER_BASE");
        address pyth = vm.envAddress("PYTH_ADDRESS_BASE");
        address chainlink = vm.envAddress("CHAINLINK_ETH_USD_BASE");
        address treasuryAddr = vm.envAddress("TREASURY_BASE");
        address cctpMessenger = vm.envAddress("CCTP_TOKEN_MESSENGER_BASE");
        bytes32 hookSalt = bytes32(vm.envUint("HOOK_SALT_BASE"));

        vm.startBroadcast(deployerKey);

        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(poolMgr), mailbox, pyth, chainlink, PYTH_ETH_USD_ID, CANONICAL_PAIR_ID_ETH_USDC, deployer
        );
        console2.log("MirrorHook (Base, redeployed):", address(hook));

        MirrorFactory factory = new MirrorFactory(deployer);
        console2.log("MirrorFactory (Base, redeployed):", address(factory));

        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);
        factory.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Update .env ===");
        console2.log("MIRROR_HOOK_BASE=", address(hook));
        console2.log("MIRROR_FACTORY_BASE=", address(factory));
    }
}

contract RedeployHookEthereum is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX_MAINNET");
        address poolMgr = vm.envAddress("POOL_MANAGER_MAINNET");
        address pyth = vm.envAddress("PYTH_ADDRESS_MAINNET");
        address chainlink = vm.envAddress("CHAINLINK_ETH_USD_MAINNET");
        bytes32 hookSalt = bytes32(vm.envUint("HOOK_SALT_MAINNET"));

        vm.startBroadcast(deployerKey);

        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(poolMgr), mailbox, pyth, chainlink, PYTH_ETH_USD_ID, CANONICAL_PAIR_ID_ETH_USDC, deployer
        );
        console2.log("MirrorHook (Ethereum, redeployed):", address(hook));

        // Relayer must redeploy whenever RebalanceMessage struct changes — the abi.decode
        // in handle() and our internal callbacks needs byte-identical struct layout.
        Relayer relayer = new Relayer(poolMgr, mailbox, deployer);
        console2.log("Relayer (Ethereum, redeployed):", address(relayer));

        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Update .env ===");
        console2.log("MIRROR_HOOK_MAINNET=", address(hook));
        console2.log("RELAYER_MAINNET=", address(relayer));
    }
}

// ─── BNB Chain deployment ─────────────────────────────────────────────────────
contract DeployBnb is Script {
    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address mailbox = vm.envAddress("HYPERLANE_MAILBOX_BNB");
        address poolMgr = vm.envAddress("POOL_MANAGER_BNB");
        address pyth = vm.envAddress("PYTH_ADDRESS_BNB");
        address chainlink = vm.envAddress("CHAINLINK_ETH_USD_BNB");
        bytes32 hookSalt = bytes32(vm.envUint("HOOK_SALT_BNB"));

        vm.startBroadcast(deployerKey);

        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(poolMgr), mailbox, pyth, chainlink, PYTH_ETH_USD_ID, CANONICAL_PAIR_ID_ETH_USDC, deployer
        );
        console2.log("MirrorHook (BNB):", address(hook));

        Relayer relayer = new Relayer(poolMgr, mailbox, deployer);
        console2.log("Relayer (BNB):", address(relayer));

        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Add to .env ===");
        console2.log("MIRROR_HOOK_BNB=", address(hook));
        console2.log("RELAYER_BNB=", address(relayer));
    }
}
