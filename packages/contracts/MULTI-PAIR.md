# Adding a new pair to mirv

The protocol is pair-agnostic by design — `MirrorFactory` is a registry that
issues canonical pair IDs (`registerCanonicalPair`) and links them to per-chain
deployments (`registerLocalPair`). To launch a new pair (e.g. USDC/cbBTC, USDT/WETH),
no contract changes are needed; just a new deploy sequence.

## What changes per new pair

| Component | Reusable? | Notes |
|---|---|---|
| `MirrorFactory` | yes | Existing factory registers any new canonical pair |
| `MirrorVault` | new instance | One per (asset, pair) combo; ERC-4626 over the deposit asset |
| `MirrorHook` (one per chain) | new instance | Bakes in `canonicalPairId` + oracle config at construction |
| `Relayer` (one per non-vault chain) | new instance | Holds inventory + executes LP modifies for this pair |
| `Treasury` | reused | Single treasury aggregates fees across all pairs |
| Hyperlane mailboxes | reused | Cross-chain transport is pair-agnostic |
| CCTP token messenger | reused if asset = USDC | Else: Hyperlane warp route |
| Oracle feeds (Pyth + Chainlink) | depends | Need feeds for both pair tokens on every chain |

## Per-pair preconditions

Before deploying, verify these are true on every target chain:

1. **Bridge route exists**
   - USDC pairs: Circle CCTP supports the chain (today: Ethereum, Base, Arbitrum, OP, Avax, Polygon)
   - Non-USDC pairs: Hyperlane warp route deployed + verified for the asset
2. **Oracle coverage**
   - Pyth feed ID for the volatile token (e.g. BTC/USD `0xe62df...`, ETH/USD `0xff614...`)
   - Chainlink aggregator for the same asset on this chain — must be a stable, well-monitored feed
3. **V4 pool doesn't exist yet** for `(token0, token1, fee, tickSpacing, mirvHook)` — if it does, you'd be re-using a different protocol's hook
4. **Token decimals are sane** — the hook's TVL math assumes (6, 18) for USDC-style + WETH-style. Custom-decimal pairs need oracle-driven pricing for BOTH tokens (no shortcut)

## Per-pair deploy steps

```bash
# 0. Decide canonical pair id parameters
PAIR_NAME="BTC-USDC-V1"
FEE_TIER=3000        # 0.30% — most pairs use this; some long-tail use 10000 / 0.5%
TICK_SPACING=60      # matches fee tier (Uniswap convention)

# 1. Register the canonical pair on the existing factory
forge script script/RegisterCanonicalPair.s.sol \
  --rpc-url $ALCHEMY_BASE_URL --broadcast \
  --sig "run(string,uint24,int24)" "$PAIR_NAME" $FEE_TIER $TICK_SPACING

# 2. Mine a hook CREATE2 address with the V4 flag bits set
forge script script/MineHookAddress.s.sol \
  --sig "run(bytes32,address,address,address,address,address,address)" \
    $CANONICAL_PAIR_ID \
    $POOL_MANAGER_BASE \
    $HYPERLANE_MAILBOX_BASE \
    $PYTH_ADDRESS_BASE \
    $CHAINLINK_ASSET_USD_BASE \
    $DEPLOYER \
    $GUARDIAN

# 3. Deploy hook + (on Base) vault on the home chain
HOOK_SALT_BASE=<from step 2> \
  forge script script/DeployPair.s.sol:DeployPairBase \
  --rpc-url $ALCHEMY_BASE_URL --broadcast

# 4. Deploy hook + relayer on each sister chain (repeat per chain)
forge script script/DeployPair.s.sol:DeployPairEthereum \
  --rpc-url $ALCHEMY_MAINNET_URL --broadcast --slow

# 5. Wire sister domains (each hook learns about every sister)
forge script script/WireSisterDomains.s.sol \
  --rpc-url $ALCHEMY_BASE_URL --broadcast

# 6. Initialize V4 pool with bootstrap LP on each chain
forge script script/InitPoolWithLiquidity.s.sol \
  --rpc-url $ALCHEMY_BASE_URL --broadcast

# 7. Register the local-pair on the factory (one tx per chain)
forge script script/RegisterLocalPair.s.sol --rpc-url ...

# 8. Authorize the agent on the new hook + vault
forge script script/AuthorizeAgent.s.sol --rpc-url ...

# 9. Fund the hook with ETH for Hyperlane dispatch fees
cast send $NEW_HOOK_ADDRESS --value 0.01ether --rpc-url ... --private-key $DEPLOYER_PRIVATE_KEY
```

## Existing helper scripts you'd extend

- `Deploy.s.sol` → split into `DeployBase` / `DeployEthereum` / `DeployBnb` per chain. **For multi-pair**: parameterize by pair env vars (`MIRROR_PAIR_NAME`, `CANONICAL_PAIR_ID`, `VAULT_ASSET`, `PYTH_FEED_ID`) instead of the hardcoded ETH-USDC-V1 constants. A small refactor of the existing script. Tracked in TODO 8.5 multi-pair section.
- `MineHookAddress.s.sol` → reusable as-is; it just needs the right constructor args
- `WireSisterDomains.s.sol` → reusable; takes hook + sister hook addresses
- `InitPoolWithLiquidity.s.sol` → reusable; takes pool key + initial LP params

## Cost of adding a new pair (mainnet estimate)

| Step | Approx gas | $ at 30 gwei + $2000 ETH |
|---|---|---|
| Hook deploy (Base) | ~3.5M | ~$210 |
| Vault deploy (Base) | ~3.0M | ~$180 |
| Hook deploy (Ethereum) | ~3.5M | ~$210 |
| Relayer deploy (Ethereum) | ~2.5M | ~$150 |
| Wire-sisters + init + register | ~1.5M total | ~$90 |
| **Total** | **~14M** | **~$840** |

Cheaper on L2-only multi-pair (Base + Arbitrum + OP) — most cost is the Ethereum L1 deploys.

## Seed depth per pair

Same logic as the base USDC/WETH pair (Phase 8.5.1). Without router-competitive
seed depth on each chain, the swarm has nothing to coordinate. Don't deploy a
new pair until you have funding for its launch position.
