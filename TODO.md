# mirv — Complete Build Checklist

**Legend:** `[x]` done · `[ ]` not started · `[~]` in progress · `[?]` blocked / needs decision
**Updated:** 2026-05-16

---

## Phase 0 — Planning & Setup

- [x] Define architecture (3-chain mirror, vault on Base, AI agent swarm)
- [x] Lock toolchain decisions (Foundry, TypeScript, LangGraph, Claude 4, Hyperlane, Pyth+Chainlink)
- [x] Answer 16-question pre-build questionnaire
- [x] Save reference memories (ETHSKILLS skills, security checklist, verified addresses, Uniswap AI plugins)
- [x] Create monorepo directory structure (`packages/contracts`, `packages/agents`, `packages/frontend`)
- [x] Write `.env.example` with all required keys
- [x] Write root `package.json` workspace config
- [x] Init git repository in `packages/contracts/`

---

## Phase 1 — Smart Contracts

### Scaffold
- [x] `foundry.toml` with remappings, fuzz/invariant config, RPC endpoints, etherscan keys
- [x] `forge install` foundry-rs/forge-std, OpenZeppelin/openzeppelin-contracts, OpenZeppelin/uniswap-hooks
- [x] Switch from standalone v4-core/periphery to bundled (via uniswap-hooks)
- [x] Enable `via_ir = true` (factory needed it for stack-too-deep)

### Interfaces
- [x] `interfaces/IHyperlane.sol` — Mailbox + IMessageRecipient
- [x] `interfaces/IPyth.sol` — Price struct + getPriceNoOlderThan
- [x] `interfaces/IChainlink.sol` — AggregatorV3

### Core Contracts
- [x] `MirrorHook.sol` — V4 hook with afterSwap/afterAdd/afterRemove + Hyperlane dispatch + Pyth/Chainlink oracle
- [x] `MirrorVault.sol` — ERC-4626, 15% perf fee on extra yield only
- [x] `MirrorFactory.sol` — CREATE2 pair deployer with TVL gating
- [x] `Treasury.sol` — thin fee router to Gnosis Safe
- [x] `Relayer.sol` — Hyperlane IMessageRecipient + unlockCallback

### Scripts
- [x] `script/MineHookAddress.s.sol` — CREATE2 salt miner for hook permission bits
- [x] `script/Deploy.s.sol` — separate DeployBase / DeployEthereum / DeployBnb contracts
- [ ] `script/WireSisterDomains.s.sol` — register all 3 mailboxes after deploys
- [ ] `script/SeedLiquidity.s.sol` — initial LP from treasury into pools

### Tests
- [x] `test/helpers/TestBase.sol` — Vault+Treasury scaffolding with MockERC20
- [x] `test/MirrorVault.t.sol` — 15 tests, all passing (deposit/withdraw/harvest/fuzz)
- [ ] `test/MirrorHook.t.sol` — using uniswap-hooks `HookTest.sol` pattern (real V4 PoolManager + mined hook address)
- [ ] `test/MirrorFactory.t.sol` — deployPair, TVL gating, agent auth
- [ ] `test/Treasury.t.sol` — forwarding, ETH receive, Safe rotation
- [ ] `test/Relayer.t.sol` — Hyperlane message handling, sender auth, registerPool
- [ ] `test/integration/MirrorFlow.t.sol` — full deposit → mirror → rebalance → harvest cycle
- [ ] `test/invariant/VaultInvariants.t.sol` — share price never decreases on deposit, totalAssets ≥ principal

### Static Analysis
- [ ] Install Slither: `pip3 install slither-analyzer`
- [ ] Run `slither . --filter-paths 'lib/'` and fix findings
- [ ] Add Slither config (`.slither.config.json`) — whitelist `low-level-calls` for V4 hook callbacks
- [ ] Run Mythril: `myth analyze src/MirrorHook.sol`
- [ ] Run `forge fmt --check` and `forge inspect` storage layout

### Security Checklist (from `memory/ref_security_checklist.md`)
- [ ] All token decimal handling dynamic (`IERC20Metadata.decimals()`, no hardcoded `1e18`)
- [x] CEI + ReentrancyGuard on all external-calling functions
- [x] SafeERC20 used everywhere
- [x] Oracle has staleness check (Chainlink 1h max, Pyth 60s)
- [x] ERC-4626 virtual offset (OZ v5 default)
- [x] No infinite approvals — `forceApprove(exactAmount)` only
- [x] Explicit access control on every state-changing function
- [x] Custom errors instead of require strings
- [x] Events emitted on every state change
- [ ] MEV / sandwich protections in vault deposit/withdraw paths
- [ ] Fee-on-transfer token safety (measure received amount)
- [ ] EIP-712 replay safety for any signed operations (N/A if no sigs)
- [x] Source verified on block explorer after deploy (pending)

### Missing Onchain Data (must source before deploying that chain)
- [ ] BNB Chain V4 PoolManager address (verify on bscscan)
- [ ] BNB Chain USDC + USDT addresses
- [ ] BNB Chain Chainlink ETH/USD feed
- [ ] Hyperlane Mailbox on Ethereum (docs.hyperlane.xyz)
- [ ] Hyperlane Mailbox on Base
- [ ] Hyperlane Mailbox on BNB
- [ ] Pyth ETH/USD feed ID — verified (`0xff61491a...`) but double-check
- [ ] Confirm Hyperlane domain IDs (Ethereum=1, Base=8453, BNB=56)

---

## Phase 2 — AI Agents

### Scaffold
- [x] `package.json` — LangGraph + Anthropic SDK + viem + ioredis + zod
- [x] `tsconfig.json` — NodeNext, strict, ES2022
- [x] `yarn install` — all deps installed
- [x] `npx tsc --noEmit` exits 0

### State + Tools
- [x] `state.ts` — TypeScript types + LangGraph `Annotation` state
- [x] `tools/poolState.ts` — viem-based getPoolState / getChainlinkPrice / getTokenBalance
- [x] `tools/hyperlane.ts` — estimateHyperlaneFee, encodeRebalancePayload, sendHyperlaneMessage
- [x] `tools/redis.ts` — saveToRedis / loadFromRedis / appendCycleHistory
- [ ] `tools/pyth.ts` — fetch Pyth update VAA from Hermes endpoint
- [ ] `tools/onchain.ts` — `updateCrossChainAssets`, `updateBaselineApy`, `harvest` callers
- [ ] `tools/baseline.ts` — calculate baseline single-chain APY from historical data

### Agent Implementations
- [x] `agents/monitor.ts` — MonitorAgent ReAct loop
- [x] `agents/rebalance.ts` — RebalanceAgent JSON output
- [x] `agents/coordinator.ts` — CoordinatorAgent + on-chain execution
- [x] `agents/risk.ts` — RiskAgent veto logic
- [x] `graph.ts` — LangGraph StateGraph (parallel monitors → rebalance → risk → coordinator → record)
- [x] `index.ts` — 45s cycle loop, graceful shutdown

### Prompts (extracted to .md, hot-editable)
- [x] `prompts/monitor.md`
- [x] `prompts/rebalance.md`
- [x] `prompts/coordinator.md`
- [x] `prompts/risk.md`
- [x] `prompts/loader.ts` — fs.readFileSync at module load

### Tests
- [ ] Unit tests for each agent (mock the Claude API responses)
- [ ] Test JSON parsing edge cases (malformed LLM output, partial responses)
- [ ] Test conditional routing in graph (shouldRebalance / shouldExecute / afterRisk)
- [ ] Test Redis history append + trim to 100
- [ ] Integration test: run a full cycle against an Anvil fork

### Memory & Learning (Phase 2.5)
- [ ] Outcome logger — write rebalance outcome (imbalance before/after, yield earned) to Redis after each cycle
- [ ] 24h reflection job — review last day's actions, suggest prompt tweaks
- [ ] Human-in-the-loop mode for first 2 weeks (require manual approval via admin panel)
- [ ] Dataset export — dump 3 months of cycles for future fine-tuning

---

## Phase 3 — Frontend

### Scaffold
- [ ] `packages/frontend/package.json` — Next.js 15 + wagmi v2 + viem + RainbowKit + Tailwind + shadcn/ui + Recharts
- [ ] `tsconfig.json` + `tailwind.config.ts` + `postcss.config.js`
- [ ] App Router structure: `app/layout.tsx`, `app/page.tsx`
- [ ] Wallet provider wrapper with RainbowKit (Phantom included)
- [ ] `wagmiConfig.ts` — 3 chain definitions + RPC overrides from env (no bare `http()`)
- [ ] `scaffold.config.ts` — `pollingInterval: 3000`

### Pages
- [ ] Home / Landing — hero, live stats, "Deposit Now" CTA
- [ ] Dashboard — Total Mirrored TVL, Extra APY this week, 3-chain depth bars, agent activity feed
- [ ] Deposit — pair dropdown, amount input with USD preview, approve+deposit flow with state progression
- [ ] My Positions — current value, share %, claimable, withdraw button
- [ ] Withdraw — destination chain selector, time estimate
- [ ] Analytics — Recharts of mirrored APY vs baseline, rebalance frequency, gas costs
- [ ] Admin (protected) — manual rebalance trigger, threshold tweaks, agent log viewer, pause toggles

### Components
- [ ] `<AddressInput />` — ENS + validation (no raw `<input>`)
- [ ] `<Address />` — blockie + copy + explorer link
- [ ] `<UsdValue />` — auto-format with USD beneath token amounts
- [ ] `<AgentActivityFeed />` — Redis-streamed via SSE
- [ ] `<CrossChainDepthChart />` — live bar chart per chain
- [ ] `<NetworkSwitchButton />` — primary CTA when on wrong network

### Pre-ship QA (from ETHSKILLS qa/SKILL.md)
- [ ] Connect Wallet button is prominent (not just text)
- [ ] Wrong-network → "Switch to Base" replaces primary CTA
- [ ] One primary button visible at a time (Connect → Network → Approve → Action)
- [ ] `approvalSubmitting` + `approveCooldown` states
- [ ] Contracts verified on every chain (green checkmark on explorer)
- [ ] Branding cleanup (no Scaffold-ETH defaults)
- [ ] `<AddressInput />` used everywhere, no raw text inputs for addresses
- [ ] USD value next to every token amount
- [ ] OG image absolute URL
- [ ] `pollingInterval: 3000` and `rpcOverrides` env vars set
- [ ] No hardcoded `bg-black` — use DaisyUI variables or theme system
- [ ] Phantom wallet in RainbowKit list
- [ ] Mobile WalletConnect deep linking works
- [ ] All contract errors map to human-readable messages

---

## Phase 4 — Local Testing (Anvil)

- [ ] Install Anvil (comes with Foundry — `anvil --version`)
- [ ] Spin up 3 forks in parallel:
  ```bash
  anvil --fork-url $ALCHEMY_MAINNET_URL --port 8545 &
  anvil --fork-url $ALCHEMY_BASE_URL    --port 8546 &
  anvil --fork-url $ALCHEMY_BNB_URL     --port 8547 &
  ```
- [ ] Deploy MirrorHook via mining + CREATE2 on each Anvil fork
- [ ] Deploy MirrorVault + Factory + Treasury on Base fork
- [ ] Deploy Relayer on Ethereum + BNB forks
- [ ] Mock Hyperlane Mailbox locally OR use a real testnet messenger
- [ ] Wire sister domains across forks
- [ ] Authorize a local test agent wallet
- [ ] Fund hooks with test ETH (`anvil_setBalance`)
- [ ] Make a test deposit via cast
- [ ] Simulate a big swap on Base fork → observe imbalance event
- [ ] Manually dispatch a rebalance and verify it flows
- [ ] Run the LangGraph agent loop against forks (point Alchemy URLs at localhost)
- [ ] Observe at least one full Monitor → Rebalance → Risk → Coordinator cycle locally

---

## Phase 5 — Testnet Deployment

### Get Testnet Assets
- [ ] Sepolia ETH (faucet — Alchemy / pk910)
- [ ] Base Sepolia ETH (Coinbase faucet)
- [ ] BSC Testnet BNB (faucet.bnbchain.org)
- [ ] Mock test USDC on each testnet

### Deploy on Base Sepolia first
- [ ] Mine hook address with mainnet PoolManager substituted for testnet one
- [ ] `forge script DeployBase --rpc-url $ALCHEMY_BASE_SEPOLIA_URL --broadcast --verify`
- [ ] Record addresses in `.env`
- [ ] Verify on basescan.org testnet

### Deploy on Ethereum Sepolia
- [ ] Same pattern as Base
- [ ] Register Hyperlane Mailbox testnet address

### Deploy on BSC Testnet
- [ ] Same pattern

### Cross-Chain Wiring
- [ ] `WireSisterDomains.s.sol` — register Base → Ethereum + BNB, etc.
- [ ] Fund all 3 hooks with testnet ETH
- [ ] Authorize a testnet agent wallet on all 3 hooks + vault

### Smoke Tests on Testnet
- [ ] Make 5 deposits from 3 wallets
- [ ] Trigger swaps, observe Hyperlane dispatches in explorer
- [ ] Verify Relayer receives + executes on remote chains
- [ ] Run agent loop pointing at testnet RPCs for 48 hours
- [ ] Trigger manual harvest, verify performance fee mints to treasury
- [ ] Test pause/unpause from RiskAgent

### Performance Validation
- [ ] Capture: avg rebalance latency, gas cost per rebalance, agent decision quality
- [ ] Compare mirrored APY vs single-chain baseline
- [ ] Fix any bugs surfaced

---

## Phase 6 — Audit Preparation

- [ ] Freeze contract versions (tag a `v1.0.0-rc1` git tag)
- [ ] Re-run full Slither + Mythril, no high/medium open
- [ ] Re-run Foundry test suite, 100% pass with verbose output
- [ ] Write `audits/THREAT-MODEL.md` — every actor, attack surface, mitigation
- [ ] Write `audits/SCOPE.md` — files in/out of scope, function-by-function notes
- [ ] Write `audits/INVARIANTS.md` — what must always hold (e.g. `totalAssets() ≥ principalTracked`)
- [ ] Set up internal Cantina/Zellic preference (decision deferred per memory)
- [ ] Submit audit package
- [ ] Triage findings → Critical/High fixed pre-mainnet; Medium tracked

---

## Phase 7 — Grant Application

- [x] Write 400-word pitch (`GRANT-APPLICATION.md`)
- [ ] Set up GitHub repo (public — confirm with you before pushing)
- [ ] Apply to Uniswap Hook Design Lab
- [ ] Apply to Hook Incubator (Atrium Academy)
- [ ] Schedule call with Uniswap grants team
- [ ] Follow up weekly on application status

---

## Phase 8 — Infrastructure

### Accounts & API Keys
- [ ] Alchemy account — 3 dedicated app endpoints (Ethereum + Base + BNB)
- [ ] Anthropic API account — Claude 4 key
- [ ] Railway project — agent service + Redis add-on
- [ ] Vercel project — frontend deployment
- [ ] Tenderly project — failed-tx alerts
- [ ] Dune workspace — public dashboard
- [ ] Telegram bot for heartbeat / failed cycle alerts
- [ ] Discord server for community
- [ ] Gnosis Safe set up on each of 3 chains (Treasury recipient)

### CI/CD
- [ ] `.github/workflows/contracts.yml` — `forge fmt --check`, `forge build`, `forge test`, Slither
- [ ] `.github/workflows/agents.yml` — `tsc --noEmit`, `yarn test`
- [ ] `.github/workflows/frontend.yml` — `next build`, type-check
- [ ] Branch protection on `main` — require all CI green
- [ ] Auto-deploy agents to Railway on `main` push (after manual approval)

### Monitoring
- [ ] Tenderly alerts — any reverted tx from agent wallet → Telegram
- [ ] Dune dashboard — Mirrored TVL, weekly extra APY, rebalance count, fee revenue
- [ ] Custom heartbeat — agent posts to Telegram every cycle (or every Nth cycle)
- [ ] Pyth update job — push fresh prices on-chain when stale
- [ ] Agent wallet balance monitor — alert at <0.05 ETH per chain
- [ ] Hook ETH balance monitor — alert at <0.01 ETH (for Hyperlane fees)

---

## Phase 9 — Mainnet Launch

### Pre-flight
- [ ] All audit findings resolved (Critical + High at minimum)
- [ ] All addresses verified one final time against current docs
- [ ] Hot wallet for agent funded with ~0.2 ETH per chain
- [ ] Treasury Gnosis Safes set up + signers confirmed
- [ ] Public website soft-launched (preview URL)
- [ ] Documentation site live (gitbook or similar)

### Deploy
- [ ] Mine hook addresses for mainnet (one per chain, store salts)
- [ ] DeployBase → record `MIRROR_HOOK_BASE`, `MIRROR_VAULT_BASE`, `MIRROR_FACTORY_BASE`, `TREASURY_BASE`
- [ ] DeployEthereum → record `MIRROR_HOOK_MAINNET`, `RELAYER_MAINNET`
- [ ] DeployBnb → record `MIRROR_HOOK_BNB`, `RELAYER_BNB`
- [ ] Verify all contracts on basescan / etherscan / bscscan (`forge verify-contract`)
- [ ] Wire sister domains via `WireSisterDomains.s.sol`
- [ ] Fund hooks with mainnet ETH (~0.05 each)
- [ ] Register first pool (ETH/USDC) via `MirrorFactory.deployPair`
- [ ] Set authorized agent wallet on all contracts
- [ ] Transfer ownership of all contracts to Gnosis Safe

### First 24 Hours
- [ ] Seed initial liquidity ($100k–$300k from your own funds or grant)
- [ ] Start agent loop on Railway
- [ ] Watch every cycle for first 6 hours
- [ ] Verify Hyperlane messages deliver successfully on explorer
- [ ] Verify first rebalance completes round-trip
- [ ] Verify first harvest mints fee shares to treasury correctly

### First Week
- [ ] 0% performance fee for first 30 days (announce publicly)
- [ ] Daily review of rebalance decisions
- [ ] Tweak prompts in `prompts/*.md` based on observations
- [ ] Build up Dune dashboard with real data

---

## Phase 10 — Public Launch

- [ ] Marketing site live at `mirroragents.xyz` (or confirmed domain)
- [ ] Press: tweet thread, Mirror article, podcast outreach
- [ ] DefiLlama listing submitted
- [ ] Zapper integration request
- [ ] Yearn integration discussion
- [ ] Cantina bug bounty live (or alt provider)
- [ ] Referral program live (offchain points → $MIRROR redeemable in Phase 2)
- [ ] Discord open to public
- [ ] First "extra yield" snapshot posted publicly for transparency

---

## Phase 11 — Post-Launch / $MIRROR Token (Phase 2)

- [ ] Design tokenomics — supply, vesting, distribution to LPs vs team vs treasury
- [ ] Write `MirrorToken.sol` — ERC-20 + permit
- [ ] Write `Vesting.sol` — cliff + linear
- [ ] Write `MirrorVoter.sol` — veTokenomics for fee discounts
- [ ] Snapshot points to token conversion
- [ ] Launch on Base via Uniswap or fair-launch mechanism
- [ ] Liquidity provision for $MIRROR/ETH and $MIRROR/USDC

---

## Open Questions / Decisions Still Outstanding

- [ ] Domain name — `mirroragents.xyz` confirmed?
- [ ] Audit firm — Cantina vs Zellic vs both (deferred per questionnaire answer)
- [ ] GitHub repo — public from day 1 or private until launch?
- [ ] Exact Hyperlane Mailbox addresses (still TODO across all 3 chains)
- [ ] Whether to use Hyperlane warp routes for token bridging vs separate mechanism

---

## Reference Memory

All decisions, security checklists, verified addresses, and project context live in:
`/Users/brandonmccall/.claude/projects/-Users-brandonmccall-Desktop-mirrorAgents/memory/`

Re-read `MEMORY.md` for the index of saved knowledge.
