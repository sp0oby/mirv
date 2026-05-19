# mirv — Mirrored Vault Protocol

> One deposit. Liquidity working on Ethereum + Base simultaneously (BNB enabled post-launch).
> Run by an AI agent swarm. Powered by Uniswap V4 hooks + Hyperlane + Circle CCTP.

---

## TL;DR — what is this?

**You:** deposit USDC on Base. Get shares (`mirvUSDC`). Withdraw whenever.

**The protocol:** automatically splits your USDC across Base and Ethereum,
parks it as liquidity in two Uniswap V4 pools (one per chain), and an AI
swarm shifts the balance between them in real time to chase whichever side
is paying more in fees. You keep 85% of the extra yield; the protocol takes 15%.

**What's different:** instead of you bridging manually and managing two LP
positions on two chains, you make one tx on one chain and a hook-coordinated
swarm handles the cross-chain dance. The hook exposes cross-chain liquidity
depth as a first-class on-chain primitive — `localDepthUsd(poolId)` is
callable by any contract on either chain, not just mirv.

**What it isn't:**
- Not a yield aggregator (we don't pool into Aave/Morpho — we run our own LP)
- Not a bridge (we use Circle CCTP for the USDC movement)
- Not a yield farm (you're earning swap fees, not an emissions token)
- Not audited yet — testnet only; mainnet is gated on external review

**Do we use existing Uniswap pools?** No. In Uniswap V4, a pool is identified
by `(currency0, currency1, fee, tickSpacing, hooks)` — so different hook
means different pool. We deploy our own USDC/WETH pool on each chain with
the `MirrorHook` attached. On testnet these pools have minimal bootstrap LP
(the mechanism validates, the magnitudes are tiny). On mainnet we seed
real depth ourselves at launch, then user deposits grow the pool.

**Live now:**
- Contracts on Base Sepolia + Ethereum Sepolia (rc6 candidate)
- Frontend on Vercel (`mirv-frontend.vercel.app`)
- Cross-chain dispatch + Hyperlane delivery + V4 modify-liquidity all working end-to-end

**Coming next:**
- External audit
- `/docs` page for builders
- x402-funded LLM payments so the swarm is fully autonomous (no centralized API key holder)
- Mainnet launch on Base + Ethereum

---

## How do users actually make money?

Short answer: **swap fees on the V4 pools, not arbitrage between pools.**

The flow:
1. You deposit USDC on Base. The vault splits it: ~60% goes into the
   Base USDC/WETH V4 pool as LP, ~40% (via CCTP) goes into the Ethereum
   USDC/WETH V4 pool as LP.
2. Every trader who swaps through either pool pays a 0.30% fee. Your share
   of those fees scales with your share of the in-range liquidity.
3. You redeem your shares whenever. The share price has gone up because
   `totalAssets` grew (fees accrued, LP value grew). You get back more USDC
   than you put in.

mirv is **never the taker**. We don't arbitrage between pools, we don't run
MEV. We're just an LP that happens to live on two chains at once.

### Where the "extra" comes from

A passive cross-chain LP has to pick allocations upfront — say 50/50 — and
live with it. If Base has 80% of the trading volume that week, the passive
LP loses ~30% of potential fees because too much capital sits idle on
Ethereum.

mirv's agent swarm rebalances every 45 seconds. If Base's pool is paying
more fees per dollar of liquidity, USDC shifts from Ethereum to Base via
CCTP. Your LP is always concentrated where the volume is.

Illustrative math at $1M TVL, $10M weekly cross-chain volume:

| Strategy | Fee capture | Annual yield |
|---|---|---|
| Passive 50/50 split | ~60% of theoretical max | ~6.0% APY |
| mirv rebalance | ~90%+ | ~9.0% APY |
| Extra yield (mirv – passive) | — | **+3.0% APY** |
| User keeps 85% of extra | — | **+2.55% APY on top of baseline** |

(Real ratios depend on actual pool depth and volume distribution. Numbers
above are illustrative.)

### What "extra yield (7d)" measures on the dashboard

The `MirrorVault.harvest()` function compares `totalAssets` against
`principalTracked + baselineYieldAccrued`. The excess is extra yield earned
above what a passive LP would have made. 15% mints to the treasury as fee
shares; 85% stays in the share price (i.e. you keep it).

---

## Honest framing — what actually has to happen for this to be useful

### Who can add LP to mirv's pools?

Anyone. V4 pools are permissionless. Anyone with USDC + WETH can call
`PoolManager.modifyLiquidity` against our pool — the vault isn't a gatekeeper,
just one (large, automated) LP among potentially many.

Practically though, **nobody will add LP to our pool over the canonical Uniswap
pool unless they specifically want exposure to the swarm's cross-chain
coordination**. Same tokens, same fee tier, less depth at launch. So today
the pool's liquidity ≈ what the vault has deposited via CCTP + Relayer.

### What the swarm actually does today

It manages the vault's own positions across the two chains:
- A new deposit lands → swarm rebalances allocation
- External swaps hit our pool → swarm shifts USDC toward the chain earning more fees
- Price drifts outside the LP's tick range → swarm re-centers (planned)

**Two of those three only happen when there's external swap volume hitting our pools.**
On testnet, with no external traders, the swarm cycles every 45s and almost
always concludes "no action needed." It's not broken — there's just nothing to
optimize until users + traders show up. The mechanism is validated; the volume
isn't.

### What makes external volume happen

This is the actual go-to-market problem, and it's bigger than the contract layer:

1. **Seed real depth at launch.** Routers (Uniswap Universal Router, 1inch,
   Matcha, CowSwap) only quote pools that are deep enough to be competitive.
   With $20 in our pool, nobody routes through us. With $500k–$1M of treasury-
   seeded depth at mainnet launch, we show up in quotes.

2. **Get into router + aggregator allowlists.** The Uniswap Universal Router
   already supports V4, but only pools the router knows about. Aggregators
   index pools by hook address; we'd need to be in their hook allowlists. This
   is outreach work, not contract work.

3. **The cross-chain depth pitch.** Our actual edge for a router or aggregator
   is: *"if you're quoting a swap on Base and a deeper version of the pair
   exists on Ethereum, mirv's hook exposes that. You can route through us for
   better effective execution because we coordinate depth across chains."*
   This is the V4 hook primitive we built, and it's the thing that makes
   mirv ≠ "just another LP."

4. **Direct integration partners.** Cross-chain swap UIs (Across, deBridge,
   LI.FI) want deep, multi-chain liquidity. We can be a backend for them.

### The swarm is also missing some intelligence

Today the agents only see the inside of our own pools. Before mainnet they
need to also see:

- **Canonical pool depth on each chain.** If our pool has 1/10th the depth of
  the canonical Uniswap pool, the swarm should recognize it and either widen
  the tick range, lower the fee tier, or signal that we need more seed depth —
  not just rebalance the small amount of capital we have.
- **Where the canonical pool is trading.** If price drifts outside our tick
  range, our LP earns nothing until rebalanced. Right now we wait for the
  imbalance signal; smarter agents would tighten the range proactively based
  on canonical pool price.

Both are pure agent-code additions (no contract changes). 1–2 days each.

### TL;DR of the honest framing

mirv is not magic. It's:
- A hook that exposes cross-chain liquidity depth as an on-chain primitive
- A vault that lets users deposit once and get LP exposure across chains
- A swarm that keeps the vault's positions efficient as conditions change

For depositors to earn extra yield, our pools need real swap volume. That
needs router integration and meaningful seed depth — both work that happens
*before* mainnet. The roadmap below lists what's still to build.

---

## Longer version

**mirv** (short for **mir**rored **v**ault) is a fully autonomous cross-chain liquidity protocol built on Uniswap V4. A public ERC-4626 vault on Base accepts a single USDC deposit; the protocol then bridges proportional amounts to sister chains via Circle CCTP and adds mirrored LP positions on each chain's V4 pool, keeping them synchronized in near-real-time through a swarm of LLM-powered agents.

**Launch chains: Base (primary) + Ethereum.** BNB is designed-in but deferred to post-launch enablement via a single admin tx — both Circle CCTP support for BNB and Uniswap V4 on BNB Testnet are pending as of 2026-Q2.

LPs earn meaningfully higher yield than any single-chain LP position because the protocol captures arb convergence, tighter effective spreads, and optimized fee tiers — all without users needing to touch three different chains.

---

## Table of Contents

1. [The Problem](#1-the-problem)
2. [What mirv Does](#2-what-mirv-does)
3. [Architecture at a Glance](#3-architecture-at-a-glance)
4. [How It Actually Works](#4-how-it-actually-works)
5. [The Four Agents](#5-the-four-agents)
6. [The Five Contracts](#6-the-five-contracts)
7. [User Experience](#7-user-experience)
8. [Tech Stack](#8-tech-stack)
9. [Project Structure](#9-project-structure)
10. [Quick Start (Dev)](#10-quick-start-dev)
11. [Phase 5 — Testnet Deployment](#11-phase-5--testnet-deployment-next-milestone)
12. [Deployment Sequence (Mainnet)](#12-deployment-sequence-mainnet)
13. [Security](#13-security)
14. [Tokenomics & Fees](#14-tokenomics--fees)
15. [Roadmap](#15-roadmap)
16. [Live Testnet Deployment (v4)](#16-live-testnet-deployment-v4)
17. [Design Documents](#17-design-documents)
18. [References](#18-references)

---

## 1. The Problem

Today's DeFi liquidity is fragmented. The same trading pair — say ETH/USDC — exists on Ethereum, Base, and BNB Chain at three independent depths and three slightly different prices. Each fragment:

- Bleeds value to arbitrage bots
- Gives traders worse pricing than the ecosystem's combined liquidity could provide
- Forces LPs to manage three positions (or settle for one chain's lower yield)

No protocol coordinates these pools. They drift, get arbed, drift again — every minute, every day.

## 2. What mirv Does

mirv treats three sister pools as one *organism*. The protocol:

1. **Watches** every pool every 30–60 seconds via AI agents
2. **Detects** depth imbalances (>3%) and price drift (>2%) across chains
3. **Coordinates** rebalancing through Uniswap V4 hooks and Hyperlane messaging
4. **Executes** position adjustments on all three chains automatically
5. **Captures** the value that would otherwise leak to arbitrageurs and routes it back to LPs

The LP-facing product is a single ERC-4626 vault on Base. Deposit once; everything else happens behind the scenes.

## 3. Architecture at a Glance

```
                                            ┌──── Ethereum ────┐
                                            │  V4 Pool         │
                                            │  + MirrorHook    │
                                            │  + Relayer       │
                                            └────────▲─────────┘
                                                     │
                                  Hyperlane (control)│
                                  Circle CCTP (USDC) │
                                                     │
┌─── User ───┐                                       │
│   USDC     │  ┌─── Base (primary) ─────────────────┴─────┐
└─────┬──────┘  │                                          │
      │         │   MirrorVault (ERC-4626)                 │
      └────────►│   ↓ split by chain registry              │
                │   ├→ X% local (Base LP)                  │
                │   └→ Y% bridge via CCTP → Ethereum       │
                │                                          │
                │   MirrorHook + V4 Pool (Base side)       │
                │   ↑                                      │
                │   Treasury → Gnosis Safe                 │
                │                                          │
                │   MirrorFactory (canonical pair registry)│
                └──────────────────────────────────────────┘

                          ┌─────────────────────────────┐
                          │  BNB Chain (post-launch)    │
                          │  Pending: CCTP-BNB + V4-BNB │
                          │  Enables via Vault.addChain │
                          │  No protocol redeploy needed│
                          └─────────────────────────────┘

                          ┌─────────────────────────────┐
                          │  Agent Swarm (LangGraph)    │
                          │  ┌──────────────────────┐   │
                          │  │ MonitorAgent × 2     │   │
                          │  │   (Base + Ethereum;  │   │
                          │  │    +BNB post-launch) │   │
                          │  │ RebalanceAgent       │   │
                          │  │ CoordinatorAgent     │   │
                          │  │ RiskAgent (veto)     │   │
                          │  └──────────────────────┘   │
                          │  Hosted on Railway          │
                          │  State in Redis             │
                          └─────────────────────────────┘
```

## 4. How It Actually Works

**Step-by-step, end-to-end:**

1. **User deposits** USDC into the mirv Vault on Base. They receive `mirvETH-USDC` tokens (vault shares).
2. **Vault auto-splits the deposit** per chain allocation registry. At launch the split is **60% Base / 40% Ethereum**. The Ethereum portion is burned via Circle CCTP `depositForBurn` and natively minted to the ETH Relayer on the destination side (no synthetic tokens — real USDC on each chain). The Base portion stays in the vault for the local Base hook's LP path. WETH-side inventory is treasury-seeded on each Relayer at launch; replenished from accumulated fees.
3. **Hooks watch every event.** `MirrorHook.sol` is attached to each sister pool. On every swap, add-liquidity, or remove-liquidity event, it:
   - Reads local oracle price (Pyth primary, Chainlink fallback)
   - Updates `localDepthUsd` for this chain's view of the pool
   - Checks recorded sister-chain depths
   - If imbalance > 3%, dispatches a Hyperlane notification carrying its `localDepthUsd` to the sister chain's receiver (Base hook for ETH/BNB notifications; ETH Relayer for executable Base-initiated rebalances)
4. **Cross-chain notification arrives via Hyperlane.** Source-side dispatches reach `Relayer.handle()` (executable path) or `MirrorHook.handle()` (informational depth-report path). Hook receivers update their `sisterDepths` mapping using the **canonical pair id** so cross-chain identity matches regardless of local token addresses.
5. **MonitorAgents poll independently.** Every 45 seconds, MonitorAgents read pool state via viem from each chain (2 monitors at launch — Base + Ethereum) and produce structured JSON reports.
6. **RebalanceAgent reasons.** Given the monitor reports, it calculates optimal deltas, new fee tier, and tick range — but only proposes action if expected yield > gas + Hyperlane fee.
7. **CoordinatorAgent validates.** It checks for conflicts, enforces 2% TVL move cap, encodes the Hyperlane payload, and calls `MirrorHook.dispatchRebalance()` on Base.
8. **RiskAgent vetoes anything sketchy.** Big move, oracle anomaly, dead monitor — it raises status to red and pauses execution.
9. **Hyperlane delivers** the rebalance message. `Relayer.sol` on the destination chain receives it, validates the canonical pair id is registered, and calls `PoolManager.unlock()` → `modifyLiquidity()` to adjust the position.
10. **Periodically, the vault harvests.** Once per day, an authorized agent calls `MirrorVault.harvest()`. The vault calculates extra yield over baseline, mints 15% of that as vault shares to the Treasury, and forwards them to the Gnosis Safe.

**User withdrawals** flow through the same vault. Sync path: if Base-local USDC covers the redemption, ERC-4626 `redeem` returns USDC immediately. Async path: `requestWithdraw(shares, receiver)` queues the request; agent unwinds sister-chain LP, CCTP-bridges USDC back to Base, calls `fulfillWithdraw(requestId)`. ~2–5 min latency. If the agent fails to fulfill within 24h, the requester can call `cancelWithdraw` to reclaim their shares.

The whole loop runs 24/7 with no human in the loop after launch.

**BNB enablement (post-launch).** Once Circle CCTP supports BNB and Uniswap V4 ships on BNB, enabling BNB is a sequence of admin txs — no protocol redeploy:
1. Deploy `Relayer` on BNB (one tx per chain, one-time)
2. Deploy `MirrorHook` on BNB with the same canonical pair id (CREATE2 with mined salt)
3. Initialize V4 pool on BNB with the new hook
4. `Factory.registerLocalPair(canonicalPairId, BNB_DOMAIN, USDC_BNB, WETH_BNB, hookBnb)` (Base)
5. `Vault.addChain(BNB_DOMAIN, CCTP_DOMAIN_BNB, b32(BnbRelayer), …, allocBps)` (Base)
6. `Vault.setAllocations([Base, ETH, BNB], [...])` to rebalance allocations
7. Wire sister domains; flip `ENABLE_BNB_MONITOR=true` on agent process

Everything generalizes — adding any new chain follows the same pattern.

## 5. The Four Agents

| Agent | Role | Vetos? | LLM |
|---|---|---|---|
| **MonitorAgent** (×N, N=2 at launch) | Polls one chain's pool state every 45s, reports depths + prices in JSON. One per enabled chain — 2 at launch (Base + Ethereum), 3 when BNB enables post-launch (`ENABLE_BNB_MONITOR=true`) | — | Claude Sonnet 4.6 |
| **RebalanceAgent** | Reads monitor reports across all enabled chains, proposes a concrete rebalance plan | — | Claude Sonnet 4.6 |
| **CoordinatorAgent** | Validates the proposal, encodes Hyperlane payload, calls `dispatchRebalance` onchain | — | Claude Sonnet 4.6 |
| **RiskAgent** | Reviews everything, can veto on flash-loan risk / oracle anomalies / dead monitors | Yes | Claude Sonnet 4.6 |

All four prompts live as editable Markdown files in `packages/agents/src/prompts/`. Edit a `.md` file → restart the agent process → new prompt is live. No TypeScript changes needed.

**Decision flow (LangGraph):**

```
MonitorAgent×3 (parallel)
        ↓
   RebalanceAgent
        ↓
    [needs action?] ──no──→ end cycle
        ↓ yes
    RiskAgent
        ↓
    [veto?] ──yes──→ end cycle (logged)
        ↓ no
   CoordinatorAgent
        ↓
  Execute on-chain
        ↓
   Record outcome → Redis
```

## 6. The Five Contracts

| Contract | Deployed On | Purpose |
|---|---|---|
| **MirrorHook.sol** | Every enabled chain | V4 hook intercepting `afterSwap` / `afterAddLiquidity` / `afterRemoveLiquidity`. Tracks `localDepthUsd` per pool. Dispatches Hyperlane messages on imbalance > 3%. Also implements `IMessageRecipient.handle()` to receive depth notifications from sister hooks — the inbound path uses the **canonical pair id** (set at construction) so cross-chain identity matches regardless of token addresses. |
| **MirrorVault.sol** | Base only | ERC-4626 vault. Holds user deposits, mints `mirv<PAIR>` shares, charges 15% performance fee on extra yield. **Chain registry**: `addChain`/`removeChain`/`setAllocations` admin functions slot in new chains via single tx. **Auto-bridges deposits via Circle CCTP** per allocation. **Async withdrawal queue**: `requestWithdraw` → `fulfillWithdraw` handles cross-chain unwinds. |
| **MirrorFactory.sol** | Base only | Pure cross-chain pair registry. `registerCanonicalPair(name, fee, tickSpacing)` issues a chain-independent `bytes32` identity used by every chain's hook. `registerLocalPair(canonicalId, hyperlaneDomain, token0, token1, hook)` records per-chain token+hook addresses. Pair deployment happens via standalone scripts (not the factory) — keeps Factory under the EVM 24KB contract size limit. |
| **Treasury.sol** | Every chain with a Relayer/Vault | Thin fee-routing contract. Forwards collected fees directly to a Gnosis Safe. |
| **Relayer.sol** | Sister chains (Ethereum at launch; BNB post-launch) | Implements `IMessageRecipient.handle()` for executable rebalance dispatches from the Base hook. Receives CCTP-bridged USDC natively; treasury-seeded WETH inventory for the LP side. Executes `modifyLiquidity` via `PoolManager.unlock()`. |

All contracts are **immutable** — no proxy. Circuit breakers via `Pausable`. RiskAgent can call `pause()` to halt the system instantly.

Hook addresses are mined with CREATE2 (`script/MineHookAddress.s.sol`) so the lower 14 bits of the deployed address encode the exact `Hooks.Permissions` flags. The miner takes the **canonical pair id** as input so the hook's `immutable canonicalPairId` is baked into the bytecode at the predicted address.

## 7. User Experience

The frontend is a Next.js 15 / React 19 / wagmi 2 / RainbowKit 2 app deployed
on Vercel, with a kawaiicore design system (cream substrate, warm-mauve ink,
Win95 chrome, framer-motion idle animations, a custom mascot named `miri`).
Eight pages cover deposit / positions / withdraw / dashboard / activity /
analytics / admin / home. Read-only pages use viem direct-RPC reads on
server components with 30s revalidation; wallet-gated pages use wagmi hooks
client-side.

### Deposit Flow

1. Visit the mirv site, connect wallet via the header button (MetaMask, Rabby,
   Coinbase Wallet, or any injected wallet)
2. Switch to Base Sepolia / Base if prompted
3. Enter USDC amount → form previews allocation across Base + Ethereum
4. Approve USDC → deposit
5. Receive `mirvUSDC` shares; vault splits and CCTP-bridges the cross-chain
   portion automatically

### Dashboard

- Total mirrored (live `totalAssets`)
- Share price (live `totalAssets / totalSupply`)
- Per-chain USDC allocation bars (local Base balance vs reported cross-chain)
- System health strip — relayer gas balances, pause state, cooldown
- Recent rebalances pulled from the last hour of `RebalanceDispatched` events

### Activity Feed

- Last hour of cross-chain events: rebalance started / delivered / no-change /
  depth update / depth-update capped
- Each row links to the source tx on basescan / etherscan
- Refreshes every 30s, server-rendered (no per-user RPC spam)

### Withdraw

- Two modes: synchronous redeem if vault has enough local USDC, async
  `requestWithdraw` queue if cross-chain unwind is needed
- Async queue is cancellable after 24h if the agent fails to fulfill (R-5 escalation path)

## 8. Tech Stack

| Layer | Technology |
|---|---|
| **Smart contracts** | Solidity 0.8.26, Foundry, OpenZeppelin contracts, OpenZeppelin uniswap-hooks (bundles V4 core + periphery) |
| **Cross-chain messaging** | Hyperlane (primary), LayerZero v2 (fallback, future) |
| **Oracles** | Pyth Network (primary, ~60s freshness) + Chainlink (fallback with 1h staleness check) |
| **AI agents** | LangGraph (TypeScript), Claude 4 via Anthropic API |
| **EVM clients** | viem + wagmi v2 |
| **State store** | Redis (Railway managed) |
| **Agent hosting** | Railway |
| **Frontend** | Next.js 15 (App Router), Tailwind, shadcn/ui, Recharts, RainbowKit |
| **Indexing / Analytics** | Dune + The Graph + DefiLlama |
| **Monitoring** | Tenderly alerts, Telegram bot for heartbeats |
| **Security** | Slither + Mythril CI, target audit firm: Cantina (deferred) |

## 9. Project Structure

```
mirrorAgents/
├── README.md                    ← you are here
├── TODO.md                      ← full build checklist (Phase 0–11)
├── SETUP.md                     ← env var sourcing guide
├── GRANT-APPLICATION.md         ← Uniswap Hook Incubator pitch
├── LICENSE                      ← MIT
├── .env.example                 ← all required env vars (incl. testnet addresses)
├── package.json                 ← monorepo root
│
├── packages/contracts/          ← Foundry project, Solidity 0.8.26
│   ├── foundry.toml             (via_ir + 1000-run fuzz + invariant config)
│   ├── src/
│   │   ├── MirrorHook.sol       ← V4 hook (afterSwap / afterAdd / afterRemove)
│   │   ├── MirrorVault.sol      ← ERC-4626, 15% perf fee on extra yield only
│   │   ├── MirrorFactory.sol    ← CREATE2 pair deployer
│   │   ├── Treasury.sol         ← fee router → Gnosis Safe
│   │   ├── Relayer.sol          ← Hyperlane IMessageRecipient + unlockCallback
│   │   ├── interfaces/
│   │   │   ├── IHyperlane.sol
│   │   │   ├── IPyth.sol
│   │   │   └── IChainlink.sol
│   │   └── mocks/
│   │       └── MockHyperlaneMailbox.sol   ← cross-chain test infra
│   ├── script/
│   │   ├── Deploy.s.sol                   (DeployBase / DeployEthereum / DeployBnb)
│   │   ├── DeployMockMailboxes.s.sol
│   │   ├── MineHookAddress.s.sol          ← CREATE2 salt miner
│   │   ├── WireSisterDomains.s.sol        (WireBase / WireMainnet / WireBnb)
│   │   ├── SeedLiquidity.s.sol
│   │   ├── InitPoolWithLiquidity.s.sol    ← create V4 pool + add LP
│   │   └── lib/EnvHelpers.sol             ← 0x-prefix tolerant private-key parser
│   └── test/                              ← 70 tests passing
│       ├── helpers/TestBase.sol
│       ├── MirrorVault.t.sol              (15 tests)
│       ├── MirrorFactory.t.sol            (8 tests)
│       ├── Relayer.t.sol                  (16 tests)
│       ├── Treasury.t.sol                 (12 tests)
│       ├── MockHyperlaneMailbox.t.sol     (6 tests)
│       └── integration/
│           ├── ForkBase.t.sol             (9 fork tests against real Base V4)
│           └── HookCallback.t.sol         (4 tests: real swap → hook callback)
│
├── packages/agents/             ← LangGraph TypeScript, Claude Sonnet 4.6
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       ├── index.ts             ← 45s cycle loop, sync stdout
│       ├── graph.ts             ← LangGraph StateGraph wiring all 4 agents
│       ├── state.ts             ← types + Annotation
│       ├── llm.ts               ← raw @anthropic-ai/sdk helpers (bypasses langchain top_p bug)
│       ├── agents/
│       │   ├── monitor.ts       ← per-chain pool state via tools, returns JSON
│       │   ├── rebalance.ts     ← proposes deltas
│       │   ├── coordinator.ts   ← validates + executes dispatchRebalance on-chain
│       │   └── risk.ts          ← veto authority
│       ├── tools/
│       │   ├── poolState.ts     ← viem reads via V4 StateView lens
│       │   ├── hyperlane.ts     ← estimateFee / encodePayload / sendMessage
│       │   └── redis.ts         ← optional history (graceful degradation)
│       └── prompts/             ← hot-editable .md prompts
│           ├── monitor.md
│           ├── rebalance.md
│           ├── coordinator.md
│           ├── risk.md
│           └── loader.ts
│
├── packages/frontend/           ← Next.js 15 (Phase 3 — not started)
│
└── scripts/                     ← end-to-end orchestration shell scripts
    ├── anvil-mainnet.sh         ← single-chain Anvil fork (Ethereum)
    ├── anvil-base.sh            ← single-chain Anvil fork (Base)
    ├── anvil-bnb.sh             ← single-chain Anvil fork (BNB)
    ├── anvil-all.sh             ← starts all 3 forks in parallel
    ├── anvil-stop.sh            ← clean shutdown
    ├── anvil-deploy-base.sh     ← deploy on Base fork only
    ├── anvil-deploy-all.sh      ← deploy all 5 contracts × 3 chains
    ├── anvil-deploy-cross-chain.sh   ← all 3 chains + MockHyperlaneMailbox
    ├── anvil-wire-sisters.sh    ← register sister domains across chains
    ├── anvil-init-pool-base.sh  ← fund tokens + initialize a V4 pool
    ├── mock-hyperlane-relay.sh  ← bash daemon: watches dispatches, calls deliver
    ├── test-full-flow.sh        ← deposit → cross-chain yield → harvest demo
    ├── testnet-deploy-base-sepolia.sh  ← Phase 5 testnet deploy (Base Sepolia)
    └── redis.sh                 ← docker container helper (optional)
```

## 10. Quick Start (Dev)

### Prerequisites
- Node.js ≥22
- Foundry (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- Yarn 1.x

### Clone & install

```bash
git clone https://github.com/sp0oby/mirv.git
cd mirv
cp .env.example .env
# Fill in ANTHROPIC_API_KEY, ALCHEMY_*_URL, etc. See SETUP.md for the full guide.

# Contracts
cd packages/contracts
forge install     # installs forge-std, OpenZeppelin, uniswap-hooks
forge build
forge test        # 70/70 tests across 7 suites

# Agents
cd ../agents
yarn install
npx tsc --noEmit  # zero TS errors
```

### Full local 3-chain demo

```bash
# From repo root:
./scripts/anvil-deploy-cross-chain.sh    # spins up 3 Anvil forks + deploys mirv + MockMailbox + wires sisters
./scripts/anvil-init-pool-base.sh         # fund tokens + create a V4 pool with our hook + add liquidity
./scripts/mock-hyperlane-relay.sh --background    # start the cross-chain relay daemon

# Now run the agents against the local forks:
cd packages/agents
ALCHEMY_MAINNET_URL=http://localhost:8545 \
ALCHEMY_BASE_URL=http://localhost:8546 \
ALCHEMY_BNB_URL=http://localhost:8547 \
./node_modules/.bin/tsx src/index.ts
# Watch agents poll each chain, call Claude, route through the StateGraph.

# Stop everything:
./scripts/anvil-stop.sh
```

### Run the full vault lifecycle (deposit → harvest)
```bash
./scripts/anvil-deploy-cross-chain.sh   # if not already running
./scripts/test-full-flow.sh             # mints USDC, deposits, reports yield, harvests
```

## 11. Phase 5 — Testnet Deployment (next milestone)

The local Anvil demo is proven. Phase 5 takes it to real testnets so we have a public
contract address LPs can deposit against and the agents can run against real (testnet)
Hyperlane relayers + Pyth + Chainlink — no mocks.

### Order
1. **Base Sepolia** first — primary chain, full vault stack
2. **Ethereum Sepolia** — hook + relayer only
3. **BNB Testnet** — hook + relayer only (verify V4 is deployed first)

### Prerequisites
| Need | Where |
|---|---|
| Sepolia ETH | https://www.alchemy.com/faucets/ethereum-sepolia or https://sepoliafaucet.com |
| Base Sepolia ETH | https://www.alchemy.com/faucets/base-sepolia or Coinbase faucet |
| BSC Testnet BNB | https://faucet.bnbchain.org |
| Testnet USDC | Circle USDC testnet contracts (addresses in `.env.example`) |
| Block explorer API keys | Etherscan / BaseScan / BSCScan (free tier OK) |

### Run
```bash
# 1. Get testnet ETH on all 3 chains for your deployer wallet
# 2. Add ALCHEMY_BASE_SEPOLIA_URL + BASESCAN_API_KEY to .env (testnet addrs already pre-filled)
./scripts/testnet-deploy-base-sepolia.sh           # exists today
# 3. (Phase 5 work) write similar scripts for ETH Sepolia + BNB Testnet
```

See `TODO.md` Phase 5 for the full punch list.

---

## 12. Deployment Sequence (Mainnet)

### 1. Mine hook addresses (per chain)
```bash
forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  $POOL_MANAGER $HYPERLANE_MAILBOX $PYTH $CHAINLINK $PYTH_FEED_ID
# → outputs the salt to use in Deploy.s.sol
```

### 2. Deploy Base (primary)
```bash
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url $ALCHEMY_BASE_URL --broadcast --verify -vvvv
```

### 3. Deploy Ethereum mainnet
```bash
forge script script/Deploy.s.sol:DeployEthereum \
  --rpc-url $ALCHEMY_MAINNET_URL --broadcast --verify -vvvv
```

### 4. Deploy BNB Chain
```bash
forge script script/Deploy.s.sol:DeployBnb \
  --rpc-url $ALCHEMY_BNB_URL --broadcast --verify -vvvv
```

### 5. Wire sister domains
- On each chain's MirrorHook, call `addSisterDomain(domainId, sisterRelayer)` for each other chain
- On each Relayer, call `setAuthorizedSender(bytes32(uint160(sisterHook)), true)`
- Fund each hook with ~0.05 ETH for Hyperlane dispatch fees

### 6. Authorize agent wallet
- On Base: `MirrorHook.setAgentAuthorization(AGENT_WALLET, true)`, `MirrorVault.setAgentAuthorization(...)`, `MirrorFactory.setAgentAuthorization(...)`
- On Ethereum + BNB: same for the local MirrorHook

### 7. Transfer ownership to multisig
- `transferOwnership(GNOSIS_SAFE)` on every contract

### 8. Start agents
- Deploy `packages/agents` to Railway
- Verify Redis is connected
- Watch first 24h closely

## 13. Security

### Approach
- All contracts **immutable** (no upgrade risk)
- `Pausable` circuit breaker on Hook, Vault, Relayer — controlled by RiskAgent + owner multisig
- ReentrancyGuard + CEI pattern throughout
- SafeERC20 on every token interaction (handles non-standard USDT)
- Custom errors (cheaper + clearer than require strings)
- ERC-4626 virtual offset (OZ v5 default) prevents first-depositor inflation
- Oracle staleness check: Pyth 60s, Chainlink 1h

### Pre-deploy checklist
The full 23-item Solidity security checklist (from `ethskills.com/security/SKILL.md`) lives in `memory/ref_security_checklist.md`. Every item is reviewed before mainnet.

### Audit plan
- Cantina is the leading candidate (Uniswap ecosystem partner, integrates with their bug bounty)
- Decision deferred until pre-audit milestone — see `TODO.md` Phase 6
- Bug bounty live at mainnet launch via Cantina marketplace

### Static analysis
- Slither in CI (whitelisting `low-level-calls` — V4 hook callbacks require them)
- Mythril for symbolic execution on the hook + vault
- Foundry fuzz (1000 runs) + invariants (256 runs) before each PR merges

## 14. Tokenomics & Fees

### Vault performance fee
- **15% of EXTRA yield only** — never on principal, never on normal LP returns
- Extra yield = `totalAssetsNow - principalTracked - (baselineApy × principal × time)`
- Paid by minting new vault shares to the Treasury (which dilutes existing holders proportionally to extra yield generated)
- Treasury immediately forwards to a Gnosis Safe

### Protocol revenue split (TBD, post-launch)
- Agent compute costs (Claude API + Railway + Redis): paid by treasury
- Dev + ops: remainder
- Future: $MIRROR token holders (Phase 2)

### $MIRROR governance token (Phase 2)
- Deferred until mainnet TVL is proven
- Will include veTokenomics for fee discounts to long-term stakers
- Early users earn points (offchain) redeemable for $MIRROR at launch

## 15. Roadmap

See `TODO.md` for the full step-by-step build checklist. High-level milestones:

Percentages are real completion counts from `TODO.md` checkboxes.

| Phase | Status | Description |
|---|---|---|
| 0 — Planning | **100%** ✅ | All decisions locked, memory + skills saved |
| 1 — Contracts | **95%** 🟢 | 5 contracts at rc6 on Base Sepolia + ETH Sepolia. 135 tests pass (105 unit/invariant + 30 fork). Canonical pairId, chain registry, async withdrawal, CCTP integration, bidirectional `handle()`, R-1..R-13 hardening, zero-delta short-circuit. Slither: 7 high/medium in-scope findings, all pre-existing v5 patterns. Mythril SWC-101 noise on Solidity 0.8+ triaged as false positives. |
| 2 — Agents | **65%** 🟡 | Four-agent swarm (2 monitor + strategist + risk + coordinator) running on Claude via raw `@anthropic-ai/sdk`. Cross-chain dispatch via `dispatchRebalance` agent-callable path. Polish remaining: unit tests, persistent memory layer, x402 LLM payments. |
| **3 — Frontend** | **80%** 🟢 | **Live on Vercel.** 8 pages (home / dashboard / deposit / positions / withdraw / activity / analytics / admin), wagmi 2 + RainbowKit 2 wallet pages, viem direct-RPC server reads for read-only pages with 30s revalidate. Kawaiicore design system, custom mascot, framer-motion idle. Remaining: `/docs` page for technical layer, `/about` long-form. |
| 4 — Anvil Demo | **90%** ✅ | 3-chain orchestration + MockHyperlane works (kept for offline dev; testnet is now primary) |
| **5 — Testnet** | **95%** 🟢 | Live + end-to-end validated on Base Sepolia + ETH Sepolia. rc6 cross-chain pipeline: dispatch → Hyperlane delivery → relayer execute with V4 `ModifyLiquidity` → `RebalanceExecuted`. Frontend reads real on-chain state. See addresses + tx receipts in §16. |
| 6 — Audit | 0% ⚪ | External firm engagement gated on grant funding. Internal pass complete (135 tests, slither, mythril). `BRIDGE-DESIGN.md` + `audits/OPERATIONS.md` ready for review. |
| 7 — Grant | **33%** 🟡 | `GRANT-APPLICATION.md` ready, submission pending |
| 8 — Infra | **20%** 🟡 | Alchemy (live) / Anthropic (live, single key for now) / Vercel (live, frontend) / Treasury Safe (planned). x402 LLM payment integration is the next big infra item (see roadmap below). |
| 9 — Mainnet | 0% ⚪ | After audit. Launch: Base + Ethereum. BNB enables post-launch via single admin tx once CCTP-BNB + V4-BNB ship. |
| 10 — Public | 0% ⚪ | After mainnet + DefiLlama + Zapper + Bankr Skill |
| 11 — $MIRROR | **29%** ⚪ | Planning done, build deferred until TVL proven |

**Status legend:** ✅ = production-ready · 🟡 = core works, polish pending · ⚪ = not started

### What's blocking what
- **Testnet (Phase 5) is NOT blocked** by Phase 1/2 incomplete items. The 70 contract tests + the agent infrastructure are battle-tested enough to deploy on Sepolia.
- **Mainnet (Phase 9) IS blocked** by Phase 1 Slither/Mythril + Phase 6 audit + Phase 2 unit tests.
- **Public launch (Phase 10) IS blocked** by Phase 3 frontend.

### What's already proven
- **Solidity:** all 5 contracts deploy on real Base V4 PoolManager (fork) with correct CREATE2-mined hook addresses. afterSwap / afterAddLiquidity / afterRemoveLiquidity callbacks all fire on real V4 swaps via fork tests.
- **Agents:** Claude API integration via raw `@anthropic-ai/sdk` (bypasses a langchain default-args bug). Multi-round tool calling works. 3 parallel monitors per cycle.
- **TVL math:** verified against the actual Ethereum mainnet ETH/USDC V4 pool (read $72k TVL) — same formula works on any chain.
- **Cross-chain:** rc6 pipeline validated end-to-end on Sepolia testnet — Base hook `dispatchRebalance` → Hyperlane delivery → ETH Relayer execute with V4 `ModifyLiquidity` → `RebalanceExecuted` event.
- **Vault lifecycle:** USDC deposit → CCTP-burn proportional cross-chain → mirvUSDC shares minted → 15% performance fee harvest math verified.
- **Frontend ↔ chain:** dashboard + activity feed read real rc6 contract state on every render (cached 30s).

### Forward roadmap

#### Pre-mainnet must-haves (the protocol must be usable + profitable on day one)

These are the work items that have to ship before mainnet, because without
them mirv is "two empty pools on two chains" and depositors won't earn
anything. Roughly ordered by what unblocks what.

**1. Treasury seed-depth strategy at mainnet launch.** Treasury holds USDC
and matches it with WETH to seed the Base + Ethereum pools with enough
depth that routers consider us. Target: $500k–$1M per chain at launch,
funded from grant + initial team capital. Ramps up as deposits come in.
Without this, no router quotes us, no swap volume, no fees, no extra yield.
~1 week of prep + the actual mainnet-day funding.

**2. Canonical-pool monitoring in the agent.** Today the agents only read
our own pool's depth. They need to also read the canonical Uniswap pool
on each chain (no-hook poolId) so they can detect when our pool is
non-competitive and either tighten the tick range, lower the fee tier,
or signal "we need more seed depth here." 1–2 days, no contract changes.

**3. Cross-pool tick alignment.** The strategist agent should observe where
the canonical pool is trading and keep our LP's tick range bracketing that
price. If price drifts outside our range, our LP stops earning until
rebalanced. Currently we wait for the imbalance signal; smarter agents
would tighten proactively. 2–3 days, agent-only.

**4. Hook quoter interface for routers.** Add an external view function on
`MirrorHook` — `quoteEffectivePrice(amountIn, isCrossChain)` — that returns
mirv's effective execution price including cross-chain depth coordination.
This is what routers and aggregators would call to decide whether to route
through us. Contract change + tests. ~3 days.

**5. Router + aggregator outreach.** Get mirv's hook into:
   - Uniswap's Universal Router quoter (whoever maintains the V4 quoter logic)
   - 1inch's pool allowlist
   - Matcha's V4 indexer
   - CowSwap's solver pool set
   This is outreach work, not code, but it's gated on (4) above.

**6. Direct integration partner pilots.** Reach out to:
   - Across / deBridge / LI.FI as a backend for their cross-chain swap routing
   - Cross-chain wallets (Trust Wallet, Rabby) for direct integration
   The pitch: mirv's hook is the only place that exposes cross-chain depth
   as a callable primitive.

**7. External audit.** Cantina or Spearbit, ~$30–50k engagement. Already
listed as Phase 6 but worth re-emphasizing here: mainnet launch is gated
on this.

**8. Treasury multisig + governance.** Replace the current single-EOA
treasury with a Gnosis Safe (2-of-3 or 3-of-5). Wire up the 24h
`TREASURY_TIMELOCK_DELAY` to a real timelock contract. ~1 week.

#### Nice-to-haves that don't gate mainnet

**x402 LLM payments from the vault** — instead of paying for the swarm's Claude API
calls from a centralized API key, the agent coordinator will pay per-call via
the [x402 protocol](https://x402.org) (HTTP 402 micropayments). The vault funds
a small allowance into an x402-paymaster that the agent process draws against
to pay Anthropic. This makes mirv genuinely autonomous: there is no key-holder
who can pull the plug on the swarm by revoking an API key, and the cost of
running the agents is on-chain visible. Estimated effort: ~2 weeks once
x402 production endpoints stabilize.

**Persistent agent memory layer** — currently the agent state is per-cycle.
A small Postgres or Durable Object layer behind the agent would let it
remember prior rebalance reasoning, build up a model of which cycles produced
the most extra yield, and avoid repeating mistakes. Optional Redis as a hot
cache. ~1 week.

**`/about` long-form** — protocol explanation that didn't fit on the landing.
The kind of page someone shares to convince a friend to deposit. ~2 days.

**Multi-pair support** — currently mirv is single-pair (USDC/WETH on Base
and Ethereum). The architecture is pair-agnostic: `MirrorFactory` deploys
a fresh `{vault, hook, relayer}` triple per pair, the hook's
`canonicalPairId = keccak256(currency0, currency1, fee, tickSpacing)`
works for any V4 pool, and the swarm's rebalance logic doesn't care what's
underneath the LP.

What changes per pair:

| Component | USDC/WETH (today) | USDC/cbBTC (example) | USDT/WETH (example) |
|---|---|---|---|
| Vault asset | USDC | USDC | USDT |
| Bridge | Circle CCTP | Circle CCTP | Hyperlane warp route |
| Oracle | ETH/USD (Pyth + Chainlink) | BTC/USD (Pyth + Chainlink) | ETH/USD (Pyth + Chainlink) |
| Per-pair deploy | — | 1 factory call + wire-sisters | 1 factory call + warp wiring + wire-sisters |

USDC is uniquely easy because Circle ships canonical CCTP — burn on chain A,
mint on chain B with attestation. For non-USDC assets we'd use Hyperlane
warp routes (the chain registry already has `warpRecipient` + `warpRouter`
slots prepared, just not wired). Volatile pairs additionally need the price
feed to exist on both chains (Pyth + Chainlink for the dual-oracle deviation
check). Major assets are well-covered; long-tail assets would need TWAP
fallbacks or wider safety bands.

**Same pair across more chains** (e.g. USDC/WETH on Arbitrum) is much
easier — just deploy the hook + relayer on the new chain and add the chain
to the vault's registry. Single admin tx after deployment.

**BNB enablement** — designed-in but waiting on CCTP-BNB + V4-BNB to ship.
Single admin tx flips the chain registry when both are live.

## 16. Live Testnet Deployment (rc5 / rc6)

Redeployed 2026-05-18 against `v1.0.0-rc6`. All contracts verified on block
explorers. Ships canonical pairId, chain registry with CCTP integration,
async withdrawal queue, bidirectional `handle()`, the full v5 hardening
pass (DOS-resistant dispatch loops, Pyth confidence check, struct packing),
**all R-1 through R-13 audit recommendations** (bounded `updateCrossChainAssets`,
harvest staleness gate, 24h timelock on trust-root setters, guardian role,
Pyth↔Chainlink cross-oracle check, CCTP recipient validation, sister-depth
cap, cached Chainlink decimals), the **rc5 Relayer math + V4-correct settle**
fix, and the **rc6 zero-delta short-circuit** on `Relayer._executeRebalance`.

**Canonical pair id (ETH-USDC-V1)**: `0x7a00c543412ae44415418950dc1ea26ae8977c50cbcec8035a5d99a911085b04`

| Contract | Chain | Address |
|---|---|---|
| Treasury | Base Sepolia | [`0x00288400B0202Fa7c236d52685fFd725B4780392`](https://sepolia.basescan.org/address/0x00288400B0202Fa7c236d52685fFd725B4780392#code) |
| MirrorHook | Base Sepolia | [`0xA059C8544E046F29C5c2A9f0dE6314964926c540`](https://sepolia.basescan.org/address/0xA059C8544E046F29C5c2A9f0dE6314964926c540#code) |
| MirrorVault | Base Sepolia | [`0x062b9E547689D53D9c5b059215ED967a9ceAf37b`](https://sepolia.basescan.org/address/0x062b9E547689D53D9c5b059215ED967a9ceAf37b#code) |
| MirrorFactory | Base Sepolia | [`0xC3e117CD904db351F919134adCee7237F3ebC2A7`](https://sepolia.basescan.org/address/0xC3e117CD904db351F919134adCee7237F3ebC2A7#code) |
| MirrorHook | Ethereum Sepolia | [`0xc3233eb9C427Cc1ACA5cF2d5c5e89c668F148540`](https://sepolia.etherscan.io/address/0xc3233eb9C427Cc1ACA5cF2d5c5e89c668F148540#code) |
| Relayer (rc6) | Ethereum Sepolia | [`0x5D7BA93B47f93eaa359ca6063F39Eaeb4743b727`](https://sepolia.etherscan.io/address/0x5D7BA93B47f93eaa359ca6063F39Eaeb4743b727#code) |

Wiring state:
- Vault chain registry: 2 enabled domains — Base (84532, alloc 60%), Ethereum (11155111, alloc 40%, CCTP domain 0, recipient = current rc6 Relayer, left-padded)
- Hook canonical pair id matches across both chains
- Base hook → rc6 Relayer (executable rebalance path) + `authorizedSenders[ETH hook] = true` (inbound `handle()` path)
- ETH hook → Base hook (depth notification) + Relayer `authorizedSenders[Base hook] = true` (executable receipt path)
- Both hooks funded with 0.01 ETH for Hyperlane dispatch fees
- Both V4 pools initialized at tick 199799 with mirv hooks attached and bootstrap LP added (each at L = 2,000,000,000)
- rc6 Relayer pre-seeded with 10 USDC + 0.001 WETH as the inventory floor for cross-chain LP execution

Hardening defaults active on chain (cast-verified):

| Layer | Knob | Value |
|---|---|---|
| R-1 | `MirrorVault.maxCrossChainAssetsDeltaBps` | `2500` (25%) |
| R-3 | `MirrorVault.crossChainAssetsMaxStaleness` | `3600` sec (1 hour) |
| R-5 | `MirrorVault.TREASURY_TIMELOCK_DELAY` | `86400` sec (24 hours) |
| R-11 | `MirrorHook.oracleDeviationToleranceBps` | `500` (5%) |
| R-13 | `MirrorHook.maxSisterDepthMultiple` | `10` × prior depth |

End-to-end pipeline validation (live txs):

| Path | Source tx | Destination tx |
|---|---|---|
| Base → ETH agent dispatch (LP execute) | `0x8a8841d1…000f` (Base) | `0x6e3bb567…7381` (ETH) — `RebalanceExecuted` + V4 modify + token transfers |
| ETH → Base V4-callback notification | (Hyperlane delivered ETH→Base) | `0x49cb5e21…6e54` (Base) — `SisterDepthReported` + `SisterNotificationReceived` |
| Base → ETH zero-delta short-circuit (rc6) | `0x64a22b1c…4762` (Base) | `0xeee761e9…5f13` (ETH) — `RebalanceSkippedZeroDelta`, no V4 modify, 154k gas |
| First real user-deposit (20 USDC seed) | `0x4006ec38…428eb` (Base) — `Deposit` + `CctpBridgeSent` (8 USDC) | (CCTP attestation ~20 min) |
| Agent reports cross-chain in-flight | `0xc33eb2fe…6120` (Base) — `CrossChainAssetsUpdated(0 → 8 USDC)` | — |
| Demo seeding rebalance (Base→ETH) | `0xca54e2df…6ef5` (Base) — `RebalanceDispatched` | `0x8a050336…959a` (ETH) — `RebalanceExecuted` |
| Demo seeding rebalance (ETH→Base) | `0x18e86521…2963` (ETH) — `RebalanceDispatched` | (Hyperlane delivery in flight) |

### Frontend deployment

Live at `mirv-frontend.vercel.app` (pulled from this repo's `main`). Built on every push.
Read-only pages talk to the public RPCs (`sepolia.base.org`,
`ethereum-sepolia.publicnode.com`) — no env vars required, no API key in
client bundle. Wallet pages use wagmi 2 + a custom Win95-styled RainbowKit
button.

Earlier iterations (v1–v4, v5 with rc1-era contracts, and the abandoned rc5
Relayer at `0x72e2538a…0155`) are stranded on testnet; their final balances
stay there as part of the cost of iterating. See git log + the `v1.0.0-rcN`
tags for the full version history.

## 17. Design Documents

- [`BRIDGE-DESIGN.md`](./BRIDGE-DESIGN.md) — Token bridge architecture (CCTP for USDC, treasury-seeded WETH), Vault chain registry, async withdrawal flow, BNB enablement runbook
- [`TODO.md`](./TODO.md) — Full build checklist with phase status and known gaps

## 18. References

- **Uniswap V4** — https://docs.uniswap.org/contracts/v4/overview
- **OpenZeppelin uniswap-hooks** — https://github.com/OpenZeppelin/uniswap-hooks
- **Hyperlane** — https://docs.hyperlane.xyz
- **Circle CCTP** — https://developers.circle.com/stablecoins/cctp
- **Pyth Network** — https://docs.pyth.network
- **Chainlink Price Feeds** — https://docs.chain.link/data-feeds
- **LangGraph** — https://langchain-ai.github.io/langgraphjs/
- **Anthropic Claude API** — https://docs.anthropic.com
- **x402 (HTTP 402 micropayments)** — https://x402.org · used for the planned vault-funded LLM payment path
- **viem + wagmi** — https://viem.sh / https://wagmi.sh
- **RainbowKit** — https://rainbowkit.com
- **Next.js** — https://nextjs.org
- **Vercel** — https://vercel.com · frontend deployment
- **ETHSKILLS** — https://ethskills.com (Solidity security, V4 building blocks, Foundry testing skill modules)

### Project Memory
All locked decisions, security checklists, verified addresses, and reference materials live in
`/Users/brandonmccall/.claude/projects/-Users-brandonmccall-Desktop-mirrorAgents/memory/`.
Re-read `MEMORY.md` for the index.

---

**License:** MIT (see [LICENSE](./LICENSE))
**Repo:** https://github.com/sp0oby/mirv
**Contact:** brandonsmccall@gmail.com
