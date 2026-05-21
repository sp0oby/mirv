# RC7 migration runbook — activating Phase 8.5 contract changes

The contract changes shipped in commits `6c8ecee`, `e961feb`, `00b2dab`, plus
earlier work in `cc48852` and `cae7e41`, add new functions and state that the
deployed rc6 bytecode does NOT have. To activate them on testnet (Base Sepolia
+ Ethereum Sepolia), follow this migration sequence.

## What's changed since rc6

| Contract | Change | Activation requires |
|---|---|---|
| `MirrorHook` | `quoteCrossChainPool` (8.5.4), `lastSisterReportAt` tracking + staleness flag in quoter, `setSisterDepthStaleness` | Re-mine + redeploy (hook address mining locks bytecode) |
| `Relayer` | `provideLiquidity` agent-callable path (8.5.9), `recenter` execution (8.5.3), `authorizedAgents` mapping, `setAgentAuthorization`, errors `NotAuthorizedAgent`/`InvalidLiquidity`/`InvalidTickRange` | Redeploy on both chains + register pool + transfer inventory |
| `MirrorVault` | `localLpRelayer` + setter + forwarding in `_splitAndBridge` | Storage layout extension — can deploy fresh, or shadow-deploy and migrate |
| `MirrorFactory` | No change | — |
| `Treasury` | No change | — |

## Migration sequence (testnet, ETH Sepolia first, then Base Sepolia)

### Phase 1 — ETH Sepolia: redeploy Relayer with new functions

```bash
source .env
forge script script/Deploy.s.sol:DeployEthereum \
  --rpc-url $ALCHEMY_ETH_SEPOLIA_URL \
  --broadcast --slow
# Captures: MIRROR_HOOK_ETH (re-mined) + RELAYER_MAINNET (new)
```

Then transfer inventory from old Relayer:
```bash
# Rescue inventory from old Relayer (rc6)
cast send $OLD_RELAYER_MAINNET "rescueToken(address,uint256)" \
  $USDC_ETH_SEPOLIA <oldUsdcBalance> --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $ALCHEMY_ETH_SEPOLIA_URL --slow
# Repeat for WETH
# Then transfer the rescued tokens to the new Relayer
```

Re-wire on ETH Sepolia:
```bash
# Register the canonical pool on the new Relayer
cast send $RELAYER_MAINNET "registerPool(bytes32,(...))" \
  $CANONICAL_PAIR_ID "($USDC,$WETH,3000,60,$HOOK_MAINNET)" \
  --private-key $DEPLOYER_PRIVATE_KEY ...

# Authorize the agent on the new Relayer
cast send $RELAYER_MAINNET "setAgentAuthorization(address,bool)" \
  $AGENT_WALLET true --private-key $DEPLOYER_PRIVATE_KEY ...

# Authorize the new ETH Hook as a sender (for inbound Hyperlane delivery)
cast send $RELAYER_MAINNET "setAuthorizedSender(bytes32,bool)" \
  <bytes32(HOOK_MAINNET)> true --private-key $DEPLOYER_PRIVATE_KEY ...
```

### Phase 2 — Base Sepolia: deploy Base-side Relayer (new! doesn't exist on rc6)

```bash
# New deployment — Base Sepolia has no Relayer in rc6
forge script script/DeployBaseRelayer.s.sol \
  --rpc-url $ALCHEMY_BASE_SEPOLIA_URL --broadcast
# Captures: RELAYER_BASE
```

Then register pool + authorize agent (same pattern as Phase 1):
```bash
cast send $RELAYER_BASE "registerPool(...)" ...
cast send $RELAYER_BASE "setAgentAuthorization(address,bool)" $AGENT_WALLET true ...
```

Pre-fund the new Base Relayer with WETH inventory (small amount for tests):
```bash
cast send $WETH_BASE_SEPOLIA "deposit()" --value 0.005ether \
  --private-key $DEPLOYER_PRIVATE_KEY ...
cast send $WETH_BASE_SEPOLIA "transfer(address,uint256)" \
  $RELAYER_BASE 5000000000000000 \
  --private-key $DEPLOYER_PRIVATE_KEY ...
```

### Phase 3 — Vault: opt in to local-LP forwarding

```bash
# Optionally redeploy vault (if storage layout matters). For tests, can
# extend the existing vault since localLpRelayer is appended state.
cast send $MIRROR_VAULT_BASE "setLocalLpRelayer(address)" \
  $RELAYER_BASE --private-key $DEPLOYER_PRIVATE_KEY \
  --rpc-url $ALCHEMY_BASE_SEPOLIA_URL
```

After this, every user deposit's local-share USDC auto-flows to the new Base
Relayer, and the agent's monitor cycle picks it up as idle capital.

### Phase 4 — Re-mine + redeploy MirrorHook with quoter

```bash
# Re-mine the hook salt for the new bytecode
forge script script/MineHookAddress.s.sol --sig "run(...)" ...
# Update HOOK_SALT_BASE / HOOK_SALT_MAINNET in .env

# Redeploy hooks on both chains
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url $ALCHEMY_BASE_SEPOLIA_URL --broadcast
forge script script/Deploy.s.sol:DeployEthereum \
  --rpc-url $ALCHEMY_ETH_SEPOLIA_URL --broadcast --slow
```

Then re-init the pool with the new hook (V4 pool identity includes the hook
address, so new hook = new pool). Bootstrap LP needs to be re-added.

### Phase 5 — Env + agent restart

Update `.env` and Railway / Vercel env vars with all new addresses:
- `MIRROR_HOOK_BASE` (re-mined)
- `MIRROR_HOOK_MAINNET` (re-mined)
- `RELAYER_BASE` (NEW)
- `RELAYER_MAINNET` (replaces old)

Restart the agent on Railway. Verify in logs:
- monitor cycles read non-zero `canonical` + `tick` (if canonical pool exists)
- monitor cycles read non-zero `idle` once a deposit lands
- coordinator broadcasts via the right path (Relayer.provideLiquidity on Base,
  hook.dispatchRebalance on ETH)

## Cost estimate (testnet → Sepolia gas free)

| Step | Tx count | Approx gas |
|---|---|---|
| Phase 1 (ETH Sepolia Relayer + wire) | 5 txs | ~6M total |
| Phase 2 (Base Relayer + wire) | 5 txs | ~6M total |
| Phase 3 (vault opt-in) | 1 tx | ~50k |
| Phase 4 (re-mine + redeploy hooks) | 4 txs + mining | ~10M total |
| Phase 5 (re-init pools + bootstrap LP) | 4 txs | ~3M total |

Sepolia gas is free; mainnet equivalent would be ~$200–400 at 30 gwei.

## Rollback

If anything breaks during migration, the rc6 contracts are still live and
the old `.env` values point at them. Revert env on Railway/Vercel; the
protocol continues operating at the rc6 surface (no quoter, no recenter,
no local-LP forwarding) while you debug.
