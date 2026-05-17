# mirv — Mirrored Vault Protocol

> One deposit. Liquidity working on Ethereum, Base, and BNB simultaneously.
> Run by an AI agent swarm. Powered by Uniswap V4 hooks + Hyperlane.

**mirv** (short for **mir**rored **v**ault) is a fully autonomous cross-chain liquidity protocol built on Uniswap V4. A public ERC-4626 vault on Base accepts a single deposit; the protocol then mirrors the position across sister pools on Ethereum and BNB Chain, keeping them synchronized in near-real-time through a swarm of LLM-powered agents.

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
16. [References](#16-references)

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
                                       Hyperlane     │
                                                     │
┌─── User ───┐                                       │
│   ETH      │                                       │
│   USDC     │  ┌─── Base (primary) ─────────────────┴─────┐
└─────┬──────┘  │                                          │
      │         │   MirrorVault (ERC-4626)                 │
      └────────►│   ↓                                      │
                │   MirrorHook + V4 Pool                   │
                │   ↑                                      │
                │   Treasury → Gnosis Safe                 │
                │                                          │
                │   MirrorFactory (deploys new pairs)      │
                └──────────────────┬───────────────────────┘
                                   │
                              Hyperlane
                                   │
                          ┌────────▼─────────┐
                          │  BNB Chain       │
                          │  V4 Pool         │
                          │  + MirrorHook    │
                          │  + Relayer       │
                          └──────────────────┘

                          ┌─────────────────────────────┐
                          │  Agent Swarm (LangGraph)    │
                          │  ┌──────────────────────┐   │
                          │  │ MonitorAgent × 3     │   │
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
2. **Vault distributes** the deposit. It keeps a portion local and bridges proportional amounts to Ethereum and BNB through Hyperlane warp routes. Each chain's `Relayer.sol` adds LP positions to the local V4 pool.
3. **Hooks watch every event.** `MirrorHook.sol` is attached to each sister pool. On every swap, add-liquidity, or remove-liquidity event, it:
   - Reads local oracle price (Pyth primary, Chainlink fallback)
   - Checks recorded sister-chain depths
   - If imbalance > 3%, dispatches a Hyperlane notification to sister chains
4. **MonitorAgents poll independently.** Every 45 seconds, three MonitorAgents (one per chain) read pool state via viem and produce structured JSON reports.
5. **RebalanceAgent reasons.** Given the three monitor reports, it calculates optimal deltas, new fee tier, and tick range — but only proposes action if expected yield > gas + Hyperlane fee.
6. **CoordinatorAgent validates.** It checks for conflicts, enforces 2% TVL move cap, encodes the Hyperlane payload, and calls `MirrorHook.dispatchRebalance()` on Base.
7. **RiskAgent vetoes anything sketchy.** Big move, oracle anomaly, dead monitor — it raises status to red and pauses execution.
8. **Hyperlane delivers** the message. `Relayer.sol` on the destination chain receives it, validates the sender, and calls `PoolManager.unlock()` → `modifyLiquidity()` to adjust the position.
9. **Periodically, the vault harvests.** Once per day, an authorized agent calls `MirrorVault.harvest()`. The vault calculates extra yield over baseline, mints 15% of that as vault shares to the Treasury, and forwards them to the Gnosis Safe.

The whole loop runs 24/7 with no human in the loop after launch.

## 5. The Four Agents

| Agent | Role | Vetos? | LLM |
|---|---|---|---|
| **MonitorAgent** (×3) | Polls one chain's pool state every 45s, reports depths + prices in JSON | — | Claude Sonnet 4.6 |
| **RebalanceAgent** | Reads all three monitor reports, proposes a concrete rebalance plan | — | Claude Sonnet 4.6 |
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
| **MirrorHook.sol** | All 3 chains | V4 hook intercepting `afterSwap` / `afterAddLiquidity` / `afterRemoveLiquidity`. Dispatches Hyperlane messages on significant events. |
| **MirrorVault.sol** | Base only | ERC-4626 vault. Holds user deposits, mints `mirvETH-USDC` shares, charges 15% performance fee on extra yield only. |
| **MirrorFactory.sol** | Base only | Permissionless factory for new mirrored pairs (requires ≥$500k TVL & ≥$100k daily volume on all 3 chains). |
| **Treasury.sol** | All 3 chains | Thin fee-routing contract. Forwards collected fees directly to a Gnosis Safe. |
| **Relayer.sol** | Ethereum + BNB | Receives Hyperlane messages, executes liquidity adjustments via `PoolManager.unlock()`. |

All contracts are **immutable** — no proxy. Circuit breakers via `Pausable`. RiskAgent can call `pause()` to halt the system instantly.

Hook addresses are mined with CREATE2 (`script/MineHookAddress.s.sol`) so the lower bits of the deployed address encode the exact `Hooks.Permissions` returned by `getHookPermissions()`.

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

| Phase | Status | Description |
|---|---|---|
| 0 | ✅ Done | Planning, architecture, all decisions locked |
| 1 | ✅ Done | 5 contracts shipped, 70 tests passing, full Anvil deploy verified |
| 2 | ✅ Done | 4 agents calling Claude Sonnet 4.6, universal V4 TVL math, conditional routing proven |
| 3 | ⚪ Not Started | Frontend (Next.js scaffold + 6 pages) |
| 4 | ✅ Done | 3-chain Anvil orchestration, MockHyperlane delivers cross-chain, vault lifecycle proven |
| 5 | 🟡 **Next** | Testnet deployment (Base Sepolia → ETH Sepolia → BNB Testnet) |
| 6 | ⚪ Not Started | Audit (Cantina) + Slither + Mythril + bug bounty |
| 7 | 🟡 Pitch ready | `GRANT-APPLICATION.md` polished; submission pending |
| 8 | ⚪ Not Started | Infra: Alchemy, Anthropic, Railway, Redis, Gnosis Safes, x402 proxy |
| 9 | ⚪ Not Started | Mainnet launch (Base → Ethereum → BNB) |
| 10 | ⚪ Not Started | Public launch + DefiLlama + Zapper + Bankr Skill |
| 11 | ⚪ Future | $MIRROR token (governance + veTokenomics) |

### What's already proven
- **Solidity:** all 5 contracts deploy on real Base V4 PoolManager (fork) with correct CREATE2-mined hook addresses. afterSwap / afterAddLiquidity / afterRemoveLiquidity callbacks all fire on real V4 swaps via fork tests.
- **Agents:** Claude API integration via raw `@anthropic-ai/sdk` (bypasses a langchain default-args bug). Multi-round tool calling works. 3 parallel monitors per cycle.
- **TVL math:** verified against the actual Ethereum mainnet ETH/USDC V4 pool (read $72k TVL) — same formula works on any chain.
- **Cross-chain:** MockHyperlaneMailbox delivers messages between Anvil forks; production swap to real Hyperlane mailboxes is a single env-var change.
- **Vault lifecycle:** USDC deposit → cross-chain yield report → 15% performance fee harvest → fee shares minted to treasury. All math verified.

## 16. References

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
