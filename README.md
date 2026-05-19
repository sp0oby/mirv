# mirv — Mirrored Vault Protocol

> One deposit. Liquidity working on Ethereum + Base simultaneously (BNB enabled post-launch).
> Run by an AI agent swarm. Powered by Uniswap V4 hooks + Hyperlane + Circle CCTP.

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

### Deposit Flow

1. Visit the mirv site, connect wallet (RainbowKit — supports Phantom, MetaMask, WalletConnect, etc.)
2. Select pair (ETH/USDC default)
3. Enter deposit amount → see real-time preview of mirrored allocation + projected extra APY
4. Approve token + deposit on Base
5. Receive `mirvETH-USDC` receipt tokens

### Dashboard

- Live mirrored depth visualization (three bars showing per-chain balance)
- "Extra Yield Earned" counter (proof of value-add)
- Agent activity log (transparent feed of every rebalance)
- Performance chart: mirrored APY vs single-chain baseline

### Withdraw

- One click on Base
- Cross-chain unwind handled automatically in ~2–5 minutes if needed

### Marketing Lines
- "Set it once. Earn on three chains."
- "The smartest liquidity in DeFi — run by AI agents."
- "Deeper liquidity. Higher yields. Zero effort."

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
| 1 — Contracts | **80%** 🟡 | 5 contracts shipped on Base Sepolia + ETH Sepolia at v4 iteration, 73 unit + 12 fork = 85 tests pass. Canonical pairId + chain registry + async withdrawal + CCTP integration + `handle()` symmetric notification all live. Slither/Mythril clean run pending. |
| 2 — Agents | **60%** 🟡 | Core works (4 agents calling Claude, V4 TVL math proven). MonitorAgent count now N (2 at launch via env flag), 12 polish items remain (unit tests, memory/learning layer, optional Bankr) |
| 3 — Frontend | **0%** ⚪ | Deferred until after testnet end-to-end validation |
| 4 — Anvil Demo | **90%** ✅ | 3-chain orchestration + MockHyperlane works |
| **5 — Testnet** | **80%** 🟢 | **Live on Base Sepolia + ETH Sepolia.** Canonical pairId, chain registry, CCTP-ready deposit, async withdrawal queue, bidirectional `handle()`. Agent loop + soak test pending. See addresses in §16. |
| 6 — Audit | 0% ⚪ | Cantina + Slither + Mythril + bug bounty. Re-run static analysis on v4 bytecode. `BRIDGE-DESIGN.md` complete for review. |
| 7 — Grant | **33%** 🟡 | `GRANT-APPLICATION.md` ready, submission pending |
| 8 — Infra | 0% ⚪ | Alchemy / Anthropic / Railway / Gnosis Safes / x402 proxy |
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
- **Cross-chain:** MockHyperlaneMailbox delivers messages between Anvil forks; production swap to real Hyperlane mailboxes is a single env-var change.
- **Vault lifecycle:** USDC deposit → cross-chain yield report → 15% performance fee harvest → fee shares minted to treasury. All math verified.

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
- **Pyth Network** — https://docs.pyth.network
- **Chainlink Price Feeds** — https://docs.chain.link/data-feeds
- **LangGraph** — https://langchain-ai.github.io/langgraphjs/
- **Anthropic Claude API** — https://docs.anthropic.com
- **viem + wagmi** — https://viem.sh / https://wagmi.sh
- **ETHSKILLS** — https://ethskills.com (Solidity security, V4 building blocks, Foundry testing skill modules)

### Project Memory
All locked decisions, security checklists, verified addresses, and reference materials live in
`/Users/brandonmccall/.claude/projects/-Users-brandonmccall-Desktop-mirrorAgents/memory/`.
Re-read `MEMORY.md` for the index.

---

**License:** MIT (see [LICENSE](./LICENSE))
**Repo:** https://github.com/sp0oby/mirv
**Contact:** brandonsmccall@gmail.com
