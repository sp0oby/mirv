# mirv — Environment & Account Setup Guide

Step-by-step walkthrough of every external account you need and where to plug each value into `.env`.

> ⚠️ **Never commit `.env`.** It's gitignored. Only `.env.example` (placeholders) goes to GitHub.

---

## Quick start

```bash
cp .env.example .env
# Fill in each section below as you create accounts.
```

---

## 1. Alchemy (RPC endpoints) — ~5 min

**What it is:** Dedicated RPC nodes for reading + writing to Ethereum, Base, and BNB. The free tier limits us; for production agent polling (3 chains × 60s × 24h) we'll need a paid plan eventually, but free works for dev.

**Steps:**
1. Sign up at https://www.alchemy.com
2. Dashboard → "Create new app"
3. Create **one app per chain** (Ethereum Mainnet, Base Mainnet, BSC Mainnet, Base Sepolia, Ethereum Sepolia, BNB Testnet — 6 apps total) — Alchemy supports BSC on Pro+ plans
4. For each app, click "API key" and copy the HTTPS URL

**Plug into `.env`:**
```
ALCHEMY_MAINNET_URL=https://eth-mainnet.g.alchemy.com/v2/<your-key>
ALCHEMY_BASE_URL=https://base-mainnet.g.alchemy.com/v2/<your-key>
ALCHEMY_BNB_URL=https://bnb-mainnet.g.alchemy.com/v2/<your-key>
ALCHEMY_BASE_SEPOLIA_URL=https://base-sepolia.g.alchemy.com/v2/<your-key>
ALCHEMY_ETH_SEPOLIA_URL=https://eth-sepolia.g.alchemy.com/v2/<your-key>
ALCHEMY_BNB_TESTNET_URL=https://bnb-testnet.g.alchemy.com/v2/<your-key>
```

> 💡 The path after `v2/` is the same key across apps if you're on a single-key plan. The URL structure differs per chain.

---

## 2. Anthropic Console (LLM for agents) — ~3 min

**What it is:** Claude 4 API access. Powers all four agents.

**Steps:**
1. Sign up at https://console.anthropic.com
2. Top-up balance ($20 to start is plenty for testnet experimentation)
3. Workbench → API Keys → "Create Key"

**Plug into `.env`:**
```
ANTHROPIC_API_KEY=sk-ant-api03-...
```

> 💡 Estimated cost: ~$0.50–$2 per day in testnet mode (one cycle every 45s, ~3K input tokens, ~500 output tokens per cycle).

---

## 3. Block Explorer API Keys (contract verification) — ~5 min each

**What it is:** API keys used by `forge verify-contract` to auto-verify deployed contracts on the public explorer.

**Steps (repeat per explorer):**
1. **Etherscan:** https://etherscan.io/myapikey → register → "Add"
2. **BaseScan:** https://basescan.org/myapikey → same
3. **BSCScan:** https://bscscan.com/myapikey → same

**Plug into `.env`:**
```
ETHERSCAN_API_KEY=...
BASESCAN_API_KEY=...
BSCSCAN_API_KEY=...
```

> 💡 As of 2024+ Etherscan supports a single multichain API key — one key works across all three. Check your account.

---

## 4. Deployer + Agent Private Keys (new wallets) — ~5 min

**What it is:** Two **fresh** EOA wallets used for transactions. Never your main wallet.

- **Deployer wallet:** Funded with ~0.1 ETH per chain. Deploys contracts once, then ownership transfers to the Gnosis Safe.
- **Agent wallet:** Funded with ~0.05 ETH per chain. Used by CoordinatorAgent to sign `dispatchRebalance` transactions every cycle. This is a HOT wallet — keep its balance low.

**Steps:**
1. Open Foundry CLI: `cast wallet new`
2. Copy the address and private key for each wallet
3. Fund the addresses on each chain (small amounts initially)

```bash
# Example
$ cast wallet new
Successfully created new keypair.
Address:     0xAbC...
Private key: 0x1234...
```

**Plug into `.env`:**
```
DEPLOYER_PRIVATE_KEY=0x...
AGENT_PRIVATE_KEY=0x...
AGENT_WALLET=0x...           # Public address of the agent (for setAgentAuthorization)
```

> ⚠️ **NEVER** paste a real private key into `.env.example`. Only the gitignored `.env` file.

---

## 5. Gnosis Safe (treasury multisig) — ~10 min per chain

**What it is:** A multi-sig wallet that owns the contracts post-deploy and receives performance fees. Create one per chain.

**Steps:**
1. Visit https://app.safe.global
2. Connect your main wallet
3. "Create new Safe" on Base first (we deploy Base first)
4. Choose 2-of-3 or 3-of-5 signers (your hardware wallet + a backup + maybe a co-founder)
5. Repeat for Ethereum mainnet and BNB Chain
6. Copy each Safe address

**Plug into `.env`:**
```
TREASURY_SAFE=0x...    # Use one Safe per chain — vary the env var per deploy
```

> 💡 For testnet, you can skip Safe and use a regular EOA. For mainnet, **always use a Safe.**

---

## 6. Railway (agent hosting + Redis) — ~10 min

**What it is:** Where the agent loop runs 24/7 + Redis state store.

**Steps:**
1. Sign up at https://railway.com
2. "New project" → "Empty project"
3. Inside: "+ New" → "Database" → "Add Redis"
4. Click Redis service → "Variables" tab → copy `REDIS_URL`
5. (Later when ready to deploy agents:) "+ New" → "GitHub repo" → connect `sp0oby/mirv` → root directory `packages/agents` → set env vars

**Plug into `.env`:**
```
REDIS_URL=redis://default:<password>@<host>.railway.internal:6379
```

> 💡 For local dev you can run Redis with Docker: `docker run -p 6379:6379 -d redis` and set `REDIS_URL=redis://localhost:6379`.

---

## 7. Hook Salts (CREATE2 mining) — ~5 min

**What it is:** Pre-mined CREATE2 salts that deploy `MirrorHook` to addresses whose lower bits encode the right hook permissions.

**Steps (run once per chain after the rest of `.env` is filled):**
```bash
cd packages/contracts
forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  $POOL_MANAGER_BASE $HYPERLANE_MAILBOX_BASE $PYTH_ADDRESS_BASE \
  $CHAINLINK_ETH_USD_BASE \
  0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
# → outputs `Salt (decimal): N`
```

Repeat for Ethereum mainnet and BNB. Save each number.

**Plug into `.env`:**
```
HOOK_SALT_BASE=12345
HOOK_SALT_MAINNET=67890
HOOK_SALT_BNB=24680
```

---

## Pre-populated values (no action needed)

These were sourced from official docs and are already filled into `.env.example` — copy them into `.env` as-is:

| Service | Verified Source |
|---|---|
| Hyperlane Mailboxes (Ethereum + Base + BNB) | https://docs.hyperlane.xyz/docs/reference/addresses/deployments/mailbox |
| Pyth oracles (Ethereum + Base + BNB) | https://docs.pyth.network/price-feeds/contract-addresses/evm |
| Chainlink ETH/USD feeds (Ethereum + Base + BNB) | https://data.chain.link |
| V4 PoolManager (Ethereum + Base + BNB) | https://developers.uniswap.org/contracts/v4/deployments |
| Universal Router (V4) | same |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` (deterministic across all chains) |

---

## Checklist — Account Creation Tracker

- [ ] Alchemy account + 6 RPC URLs
- [ ] Anthropic API key (+ $20 balance)
- [ ] Etherscan API key
- [ ] BaseScan API key
- [ ] BSCScan API key
- [ ] Deployer wallet (`cast wallet new`)
- [ ] Agent wallet (`cast wallet new`)
- [ ] Gnosis Safe on Base mainnet
- [ ] Gnosis Safe on Ethereum mainnet
- [ ] Gnosis Safe on BNB Chain
- [ ] Railway project + Redis add-on
- [ ] Hook salts mined (after other vars are filled)

---

## After all variables are set

```bash
# Test that nothing's missing
cd packages/contracts
forge script script/Deploy.s.sol:DeployBase --rpc-url $ALCHEMY_BASE_SEPOLIA_URL  # dry-run
```

If that succeeds, you're ready for Phase 4 (Anvil local testing) and Phase 5 (testnet deploy).

---

## Total cost to get to testnet-ready

| Item | Cost |
|---|---|
| Alchemy free tier | $0 (paid plan later) |
| Anthropic balance | $20 |
| Block explorer API keys | $0 |
| Testnet ETH (faucets) | $0 |
| Railway free tier | $0 (~$5/mo when running) |
| Gnosis Safe | $0 (testnet) / ~$20 each on mainnet |
| **Total to testnet-ready** | **~$20** |
