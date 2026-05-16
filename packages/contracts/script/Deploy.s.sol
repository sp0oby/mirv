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
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

/// @title Deploy
/// @notice Foundry deployment script for mirv contracts.
///
/// Step 1 (Base — primary chain):
///   forge script script/Deploy.s.sol:DeployBase --rpc-url $ALCHEMY_BASE_URL \
///     --broadcast --verify -vvvv
///
/// Step 2 (Ethereum mainnet):
///   forge script script/Deploy.s.sol:DeployEthereum --rpc-url $ALCHEMY_MAINNET_URL \
///     --broadcast --verify -vvvv
///
/// Step 3 (BNB Chain):
///   forge script script/Deploy.s.sol:DeployBnb --rpc-url $ALCHEMY_BNB_URL \
///     --broadcast --verify -vvvv
///
/// After each deployment: record addresses in .env and wire sister domains.

// ─── Base deployment ──────────────────────────────────────────────────────────
contract DeployBase is Script {
    // Verified addresses (Base)
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant USDC         = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6 decimals
    address constant WETH         = 0x4200000000000000000000000000000000000006;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Pyth ETH/USD feed ID (same across chains)
    bytes32 constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    address constant PYTH_BASE    = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

    // TODO: Set HYPERLANE_MAILBOX_BASE in .env before running
    // address constant MAILBOX_BASE = 0x...; // fetch from https://docs.hyperlane.xyz

    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address safe        = vm.envAddress("TREASURY_SAFE");
        address mailbox     = vm.envAddress("HYPERLANE_MAILBOX_BASE");
        bytes32 hookSalt    = bytes32(vm.envUint("HOOK_SALT_BASE")); // from MineHookAddress

        vm.startBroadcast(deployerKey);

        // 1. Treasury
        Treasury treasury = new Treasury(safe, deployer);
        console2.log("Treasury:", address(treasury));

        // 2. MirrorHook (CREATE2 with mined salt)
        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(POOL_MANAGER),
            mailbox,
            PYTH_BASE,
            CHAINLINK_ETH_USD,
            PYTH_ETH_USD,
            deployer
        );
        console2.log("MirrorHook (Base):", address(hook));

        // 3. MirrorVault (USDC as primary asset on Base)
        MirrorVault vault = new MirrorVault(
            IERC20(USDC),
            address(treasury),
            deployer,
            "mirv ETH/USDC Vault",
            "mirvETH-USDC"
        );
        console2.log("MirrorVault (Base):", address(vault));

        // 4. MirrorFactory
        MirrorFactory factory = new MirrorFactory(
            POOL_MANAGER, mailbox, PYTH_BASE, address(treasury), deployer
        );
        console2.log("MirrorFactory:", address(factory));

        // 5. Authorize agent
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
    address constant POOL_MANAGER       = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant CHAINLINK_ETH_USD  = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    bytes32 constant PYTH_ETH_USD       = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    address constant PYTH_MAINNET       = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address safe        = vm.envAddress("TREASURY_SAFE");
        address mailbox     = vm.envAddress("HYPERLANE_MAILBOX_MAINNET");
        bytes32 hookSalt    = bytes32(vm.envUint("HOOK_SALT_MAINNET"));

        vm.startBroadcast(deployerKey);

        // Hook only — Vault + Factory live on Base
        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(POOL_MANAGER),
            mailbox,
            PYTH_MAINNET,
            CHAINLINK_ETH_USD,
            PYTH_ETH_USD,
            deployer
        );
        console2.log("MirrorHook (Ethereum):", address(hook));

        // Relayer — executes LP adjustments triggered by Base hook
        Relayer relayer = new Relayer(POOL_MANAGER, mailbox, deployer);
        console2.log("Relayer (Ethereum):", address(relayer));

        address agentWallet = vm.envAddress("AGENT_WALLET");
        hook.setAgentAuthorization(agentWallet, true);

        vm.stopBroadcast();

        console2.log("\n=== Add to .env ===");
        console2.log("MIRROR_HOOK_MAINNET=", address(hook));
        console2.log("RELAYER_MAINNET=", address(relayer));
    }
}

// ─── BNB Chain deployment ─────────────────────────────────────────────────────
contract DeployBnb is Script {
    // TODO: verify all BNB addresses on bscscan before running
    address constant POOL_MANAGER = address(0);          // TODO: verify
    address constant CHAINLINK_ETH_USD = address(0);     // TODO: verify
    address constant PYTH_BNB     = 0xD7aC7B0B955A14680DE28F1e25329B7B8a291a1E;
    bytes32 constant PYTH_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    function run() external {
        require(POOL_MANAGER != address(0), "Deploy: BNB Pool Manager not verified yet");

        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address mailbox     = vm.envAddress("HYPERLANE_MAILBOX_BNB");
        bytes32 hookSalt    = bytes32(vm.envUint("HOOK_SALT_BNB"));

        vm.startBroadcast(deployerKey);

        MirrorHook hook = new MirrorHook{salt: hookSalt}(
            IPoolManager(POOL_MANAGER),
            mailbox,
            PYTH_BNB,
            CHAINLINK_ETH_USD,
            PYTH_ETH_USD,
            deployer
        );
        console2.log("MirrorHook (BNB):", address(hook));

        Relayer relayer = new Relayer(POOL_MANAGER, mailbox, deployer);
        console2.log("Relayer (BNB):", address(relayer));

        vm.stopBroadcast();
    }
}
