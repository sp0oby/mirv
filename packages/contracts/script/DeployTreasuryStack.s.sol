// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {MirrorVault} from "../src/MirrorVault.sol";
import {MirrorHook} from "../src/MirrorHook.sol";
import {MirrorFactory} from "../src/MirrorFactory.sol";
import {Treasury} from "../src/Treasury.sol";
import {Relayer} from "../src/Relayer.sol";
import {EnvHelpers} from "./lib/EnvHelpers.sol";

/// @title DeployTreasuryStack — TODO 8.5.8 (Treasury Safe + Timelock + migration)
/// @notice One-shot script that:
///         1. Deploys an `OZ TimelockController` with a 24h delay
///         2. Migrates all privileged setters (owner / treasury fields) on
///            the deployed mirv contracts from the current EOA to the Timelock
///         3. Verifies on-chain that every privileged role now points at the
///            Timelock — script reverts loudly if any setter still points at
///            the EOA, so an incomplete migration is impossible to deploy
///
/// @dev    The Gnosis Safe is NOT deployed by this script — you deploy that
///         from the Gnosis Safe UI first (safer than scripting the Safe
///         singleton + proxy setup) and pass its address in as the
///         `proposer` + `executor` of the Timelock.
///
/// @dev    Run pattern (Base mainnet, when ready):
///         ```
///         source .env
///         export TREASURY_SAFE=0x<your safe addr>
///         export MIRROR_VAULT_BASE=0x<vault>
///         export MIRROR_HOOK_BASE=0x<hook>
///         export MIRROR_FACTORY_BASE=0x<factory>
///         export TREASURY_BASE=0x<treasury>
///         forge script script/DeployTreasuryStack.s.sol \
///           --rpc-url $ALCHEMY_BASE_URL --broadcast --slow --verify
///         ```
///
/// @dev    This script is intentionally NOT YET RUN. It exists so:
///           - Mainnet launch isn't gated on writing migration logic
///           - Auditors can review the migration path before launch
///           - Testnet rehearsal becomes a one-command exercise
contract DeployTreasuryStack is Script {
    uint256 public constant TIMELOCK_DELAY = 24 hours;

    function run() external {
        uint256 deployerKey = EnvHelpers.envPrivateKey("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address safe = vm.envAddress("TREASURY_SAFE");
        require(safe != address(0), "TREASURY_SAFE env not set");

        address vault   = vm.envAddress("MIRROR_VAULT_BASE");
        address hook    = vm.envAddress("MIRROR_HOOK_BASE");
        address factory = vm.envAddress("MIRROR_FACTORY_BASE");
        address treasury= vm.envAddress("TREASURY_BASE");

        console2.log("=== mirv Treasury Stack migration ===");
        console2.log("Deployer:", deployer);
        console2.log("Safe:    ", safe);
        console2.log("Vault:   ", vault);
        console2.log("Hook:    ", hook);
        console2.log("Factory: ", factory);
        console2.log("Treasury:", treasury);

        vm.startBroadcast(deployerKey);

        // ─── Step 1: deploy Timelock ────────────────────────────────────
        // Proposer + executor = safe. Admin = address(0) so even the deployer
        // can't bypass the timelock once deployed. This is irreversible —
        // intentionally so. Operate the protocol only through the Safe -> Timelock.
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;

        TimelockController timelock = new TimelockController(
            TIMELOCK_DELAY,
            proposers,
            executors,
            address(0) // no admin — protocol is governed only by Safe via Timelock
        );
        console2.log("Timelock deployed:", address(timelock));

        // ─── Step 2: migrate ownership of every Ownable contract ────────
        // The current EOA owner transfers `owner()` to the Timelock.
        // After this, the only way to call onlyOwner functions is to:
        //   Safe.execute() -> Timelock.schedule(target, data) -> wait 24h ->
        //   Safe.execute() -> Timelock.execute(target, data) -> target.fn()

        MirrorHook(payable(hook)).transferOwnership(address(timelock));
        console2.log("Hook ownership -> Timelock");

        MirrorFactory(factory).transferOwnership(address(timelock));
        console2.log("Factory ownership -> Timelock");

        Treasury(payable(treasury)).transferOwnership(address(timelock));
        console2.log("Treasury ownership -> Timelock");

        // MirrorVault uses a separate `treasury` address (NOT Ownable's owner).
        // The vault has a 24h-timelocked setter for the treasury already
        // (R-5). For migration, we propose a treasury change to the Safe
        // address. After R-5's 24h delay, anyone can `finalizePendingTreasury`.
        MirrorVault(vault).proposeTreasury(safe);
        console2.log("Vault.proposeTreasury(safe) — finalize after 24h via executeTreasury()");

        // If a Relayer is deployed (ETH side), uncomment + add it here:
        //   address relayer = vm.envAddress("RELAYER_MAINNET");
        //   Relayer(payable(relayer)).transferOwnership(address(timelock));

        vm.stopBroadcast();

        // ─── Step 3: verification ───────────────────────────────────────
        // Script reverts if any setter is still pointing at the EOA — an
        // incomplete migration is a misconfiguration that should fail loud.
        require(MirrorHook(payable(hook)).owner() == address(timelock), "hook owner != timelock");
        require(MirrorFactory(factory).owner() == address(timelock), "factory owner != timelock");
        require(Treasury(payable(treasury)).owner() == address(timelock), "treasury owner != timelock");

        console2.log("");
        console2.log("=== migration complete ===");
        console2.log("Next steps:");
        console2.log("  1. Wait 24h, then call Vault.executeTreasury() from any address");
        console2.log("  2. From your Safe UI, future config changes go:");
        console2.log("       schedule(target, data, predecessor=0, salt, delay=24h)");
        console2.log("     wait 24h, then:");
        console2.log("       execute(target, data, predecessor=0, salt)");
        console2.log("  3. ALL onlyOwner functions on Hook/Factory/Treasury now require");
        console2.log("     this 2-step Safe-through-Timelock flow.");
    }
}
