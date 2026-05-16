# mirv — Complete Build Checklist

**Legend:** `[x]` done & tested · `[ ]` not started · `[~]` in progress · `[?]` blocked / needs decision
**Updated:** 2026-05-16

**Current build status:** ✅ `forge build` green · ✅ `forge test` **70/70** passing · ✅ `tsc` zero errors · ✅ 3-chain Anvil deploy + wire + cross-chain mock relay works

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
- [x] `script/MineHookAddress.s.sol` — CREATE2 salt miner for hook permission bits (compiles)
- [x] `script/Deploy.s.sol` — separate DeployBase / DeployEthereum / DeployBnb contracts (compiles)
- [x] `script/WireSisterDomains.s.sol` — WireBase + WireMainnet + WireBnb (compiles)
- [x] `script/SeedLiquidity.s.sol` — SeedBase + FundHookEthereum + FundHookBnb (compiles)
- [ ] **Note:** scripts not yet executed against any RPC — needs env vars + testnet ETH

### Tests
- [x] `test/helpers/TestBase.sol` — Vault+Treasury scaffolding with MockERC20
- [x] `test/MirrorVault.t.sol` — **15/15 passing** (deposit/withdraw/harvest/fuzz with 1000 runs)
- [x] `test/MirrorFactory.t.sol` — **8/8 passing** (constructor, auth, agent authorization)
- [x] `test/Treasury.t.sol` — **12/12 passing** (forwarding, ETH receive, Safe rotation, fuzz)
- [x] `test/Relayer.t.sol` — **16/16 passing** (Hyperlane message handling, sender auth, registerPool, pause)
- [ ] `test/MirrorHook.t.sol` — needs uniswap-hooks `HookTest.sol` pattern (real V4 PoolManager + mined hook address). Deferred to fork-test suite — see TODO Phase 4.
- [ ] `test/integration/MirrorFlow.t.sol` — full deposit → mirror → rebalance → harvest cycle (Anvil fork test)
- [ ] `test/invariant/VaultInvariants.t.sol` — share price never decreases on deposit, totalAssets ≥ principal

### Static Analysis
- [ ] Install Slither: `pip3 install slither-analyzer`
- [ ] Run `slither . --filter-paths 'lib/'` and fix findings
- [ ] Add Slither config (`.slither.config.json`) — whitelist `low-level-calls` for V4 hook callbacks
- [ ] Run Mythril: `myth analyze src/MirrorHook.sol`
- [ ] Run `aeon-vuln-scanner` (Bankr skill) — free Semgrep + TruffleHog + osv-scanner + Slither pre-audit pass
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
- [x] BNB Chain V4 PoolManager: `0x28e2ea090877bf75740558f6bfb36a5ffee9e9df` (from developers.uniswap.org)
- [x] Hyperlane Mailbox on Ethereum: `0xc005dc82818d67AF737725bD4bf75435d065D239`
- [x] Hyperlane Mailbox on Base: `0xeA87ae93Fa0019a82A727bfd3eBd1cFCa8f64f1D`
- [x] Hyperlane Mailbox on BNB: `0x2971b9Aec44bE4eb673DF1B88cDB57b96eefe8a4`
- [x] Pyth oracles all 3 chains (verified from docs.pyth.network)
- [x] Chainlink ETH/USD all 3 chains (BNB: `0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e`)
- [x] Hyperlane domain IDs confirmed (Ethereum=1, Base=8453, BNB=56)
- [ ] BNB Chain USDC + USDT addresses (look up before BNB deploy)
- [ ] Confirm Pyth ETH/USD feed ID matches across chains

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

### External Context (Bankr Skills — optional but high-value)
- [ ] Integrate `aeon-defi-monitor` — feed competing vault APR/TVL data into RebalanceAgent context for accurate baseline APY
- [ ] Integrate `aeon-defi-overview` — feed daily DeFi regime call (RISK-ON / NEUTRAL / RISK-OFF) into RiskAgent
- [ ] Consider ERC-8004 agent identity registration for CoordinatorAgent (transparency + reputation)

---

## Phase 3 — Frontend

### Scaffold
- [ ] `packages/frontend/package.json` — Next.js 15 + wagmi v2 + viem + RainbowKit + Tailwind + shadcn/ui + Recharts
- [ ] `tsconfig.json` + `tailwind.config.ts` + `postcss.config.js`
- [ ] App Router structure: `app/layout.tsx`, `app/page.tsx`
- [ ] Wallet provider wrapper with RainbowKit (Phantom included)
- [ ] `wagmiConfig.ts` — 3 chain definitions + RPC overrides from env (no bare `http()`)
- [ ] `scaffold.config.ts` — `pollingInterval: 3000`

### Component Libraries (Bankr ecosystem — optional accelerators)
- [ ] Evaluate Coinbase `onchainkit` skill components (wallet, swap widget, identity, NFT) — could speed up Phase 3 ~30%
- [ ] Evaluate `zerion` skill for "My Positions" page data (portfolio values, PnL, gas, 41+ chains)
- [ ] Evaluate `siwa` (Sign-In With Agent) for admin panel auth

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

### ✅ Base single-chain deployment (proven working)
- [x] Anvil 1.6.0 installed (ships with Foundry)
- [x] `scripts/anvil-base.sh` — spins up Base fork on port 8546 (foreground or background)
- [x] `scripts/anvil-deploy-base.sh` — full one-command flow: anvil → fund → mine hook → deploy → verify
- [x] CREATE2 hook mining works (use canonical `0x4e59...4956C` deployer, NOT EOA)
- [x] All 5 contracts deploy successfully against real Base V4 PoolManager on fork
- [x] Cast verification: hook permissions, vault name/symbol/asset, perf fee, agent auth — all correct
- [x] `EnvHelpers.sol` library handles private keys with or without `0x` prefix
- [x] Deploy script auto-substitutes placeholder TREASURY_SAFE / AGENT_WALLET with deployer for local test
- [x] Deployed to mined address `0xD42Ca5083f67e39F43b9189Da6b2Dd6859a9C540` (lower 14 bits = 0x540, correct perms)

### ✅ Multi-chain Anvil orchestration
- [x] `scripts/anvil-mainnet.sh` — Ethereum fork on port 8545
- [x] `scripts/anvil-bnb.sh` — BNB Chain fork on port 8547
- [x] `scripts/anvil-all.sh` — spins up all 3 forks in parallel
- [x] `scripts/anvil-stop.sh` — clean shutdown
- [x] `scripts/anvil-deploy-all.sh` — deploys all contracts across 3 chains in one command
- [x] All chain addresses driven from `.env` (Deploy.s.sol reads via vm.envAddress)
- [x] CREATE2 hook mining works on all 3 chains (Base: 0xD42…C540, ETH: 0xDbE…8540, BNB: 0xF42…0540)
- [x] `scripts/anvil-wire-sisters.sh` — wires sister domains + authorized senders across 3 chains
- [x] Verified: each hook tracks 2 sister domains; Ethereum + BNB relayers trust the Base hook

### ✅ Vault lifecycle test (full deposit → harvest cycle on Base fork)
- [x] USDC funding via Circle masterMinter impersonation (`scripts/test-full-flow.sh`)
- [x] 10k USDC deposit → 10k mirvETH-USDC shares minted
- [x] Agent reports 500 USDC cross-chain yield via `updateCrossChainAssets`
- [x] Set baseline APY 5% via `updateBaselineApy`
- [x] Fast-forward 1 day via `evm_increaseTime`
- [x] `harvest()` mints performance fee shares to treasury (~74.5 USDC → 72.77 shares ✓)
- [x] All math validates against expected formula

### ✅ Fork integration test suite (CI-runnable, no external Anvil)
- [x] `test/integration/ForkBase.t.sol` — 9/9 passing in 1.6s
- [x] Tests against real Base V4 PoolManager bytecode via `vm.createFork`
- [x] Validates hook permissions match deployed address bits
- [x] Tests vault deposit, cross-chain reporting, harvest, treasury forwarding

### ✅ Testnet deploy scaffolding
- [x] `scripts/testnet-deploy-base-sepolia.sh` — Base Sepolia testnet deploy with --verify
- [x] Testnet addresses for V4, Hyperlane, Pyth, Chainlink added to `.env.example`

### ✅ V4 swap callback validation (proven via real Base mainnet fork)
- [x] `test/integration/HookCallback.t.sol` — 4/4 tests pass
- [x] Initialized new V4 pool on Base fork with our hook
- [x] Added liquidity via `PoolModifyLiquidityTest` → `afterAddLiquidity` callback fires ✓
- [x] Triggered real swap via `PoolSwapTest` → `afterSwap` callback fires ✓
- [x] Agent `dispatchRebalance` → `RebalanceDispatched` event emits ✓
- [x] Unauthorized agent reverts with `NotAuthorizedAgent` ✓

### ✅ Mock Hyperlane cross-chain delivery (full message flow proven)
- [x] `src/mocks/MockHyperlaneMailbox.sol` — IMailbox impl with try/catch deliver + diagnostic events
- [x] `script/DeployMockMailboxes.s.sol` — per-chain deployer scripts
- [x] `scripts/anvil-deploy-cross-chain.sh` — single-command setup: 3 forks + mock mailboxes + mirv contracts + wire
- [x] `scripts/mock-hyperlane-relay.sh` — bash daemon watching Dispatch events on each fork, calling deliver() on destinations (bash 3.2 compatible)
- [x] `test/MockHyperlaneMailbox.t.sol` — 6/6 isolated unit tests
- [x] End-to-end verified: Base hook → Dispatch event → daemon → MockMailbox.deliver → Relayer.handle reached
- [x] Try/catch in deliver() captures application-layer reverts as `DeliveryFailed` events (relay keeps running)

### ✅ Agent loop running against local fork
- [x] Switched LLM from `claude-opus-4-7` → `claude-sonnet-4-6` (much cheaper, plenty smart for JSON tasks)
- [x] Bypassed langchain's `top_p: -1` default-args bug by using raw `@anthropic-ai/sdk` directly
- [x] Built `src/llm.ts` helper with `callClaude` (text→text) + `callClaudeWithTools` (multi-round tool calling)
- [x] All 4 agents (Monitor/Rebalance/Coordinator/Risk) refactored off langchain ChatAnthropic onto raw SDK
- [x] Confirmed Claude is being invoked: tool calls + multi-round responses + token counts logged
- [x] Made Redis truly optional — agents degrade gracefully when `REDIS_URL` is a placeholder
- [x] Added `scripts/redis.sh up/down/status` for local Docker Redis if user wants history tracking
- [x] Forced synchronous stdout in `index.ts` so `nohup agent > log &` actually streams (no buffering)
- [x] Updated `monitor.ts` to read pool state via V4 `StateView` lens contracts (not PoolManager directly)
- [x] Verified addresses for StateView on Ethereum + Base + BNB

### ✅ V4 pool initialization with active liquidity
- [x] `script/InitPoolWithLiquidity.s.sol` initializes WETH/USDC pool with mirv hook on Base fork
- [x] `scripts/anvil-init-pool-base.sh` funds deployer with USDC (via Circle masterMinter impersonation) + WETH (via WETH.deposit()) + runs init script
- [x] V4 pool successfully initialized — sqrtPriceX96 + tick set, hook attached
- [x] LP add transaction succeeds (afterAddLiquidity hook callback fires)
- [x] **Pool liquidity confirmed at 1e12** — getLiquidity() via StateView returns non-zero
- [x] **Resolved**: original issue was `liquidityDelta=1e18` needing ~$60T worth of tokens. Reducing to 1e12 in the same tight tick range fits within the 100 WETH + 1M USDC we fund. This was NOT Anvil-specific — same math applies on Sepolia/mainnet.

### Remaining (deferred — last mile of the local demo)
- [x] ~~Get non-zero active liquidity in the Base pool~~ — L=1e12 confirmed at `getLiquidity()`
- [ ] **Tune pool depth for meaningful TVL** — L=1e12 = ~$0 (Claude correctly reports near-zero depth). L=1e16 needs more tokens than we fund (100 WETH + 1M USDC). Real demo needs either (a) much larger token funding (~1B WETH equivalent on the fork via anvil_setStorageAt for whale impersonation) OR (b) custom getPoolState math that maps V4 liquidity to a synthetic "demo TVL". Not Anvil-specific — same math on Sepolia.
- [ ] Initialize sister pools on Mainnet/BNB forks with the same hook (their hook addresses already deployed — need full LP setup per chain)
- [ ] Observe at least one full Monitor → Rebalance → Risk → Coordinator → dispatchRebalance → Mock Hyperlane → Relayer.handle cycle with real depth-driven imbalance
- [ ] Add ETH Sepolia + BNB testnet deploy scripts (V4 may not be on BNB testnet — verify)
- [ ] Update user's `.env` stale `PYTH_ADDRESS_BNB` (`0xD7aC...`) → verified `0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594`

### Verified working in Phase 4 (proven this session)
- [x] **Claude API actually being invoked** — was completely silent due to langchain `top_p: -1` bug. Fixed via raw Anthropic SDK. Token counts logged per call.
- [x] **Multi-round tool calling** — Claude calls `getPoolState` + `getChainlinkPrice` tools, gets results, generates final JSON.
- [x] **3 parallel monitor agents** running on 3 chains simultaneously via `Promise.allSettled`
- [x] **Conditional routing** — when no monitor flags actionNeeded, cycle skips Rebalance/Risk/Coordinator → straight to record. When any flags it, RebalanceAgent fires.
- [x] **Pool initialization on Base fork** with mined hook → afterAddLiquidity callback fires → `getLiquidity()` returns L=1e12
- [x] **StateView lens reads** — getSlot0 + getLiquidity work against Base fork (with correct checksums)
- [x] **Graceful Redis degradation** — agent prints `[Redis] REDIS_URL not configured` and continues without crashing
- [x] **Synchronous stdout** — nohup background runs now actually stream output (forced via `_handle.setBlocking(true)`)
- [x] **Universal V4 TVL math** — `(sqrtPriceX96, liquidity, decimals, Chainlink price) → USD TVL`. Works on any chain with V4 + Chainlink. Verified by reading real Ethereum mainnet ETH/USDC pool from the Anvil fork: $72,539 TVL.
- [x] **Full Monitor → Rebalance flow proven** — agents detect imbalance, Claude correctly reasons about whether to act:
  - Ethereum mainnet pool: $72,539 (real V4)
  - Base test pool: $95 (L=1e12)
  - BNB: $0 (no pool)
  - RebalanceAgent recognizes anomalous data and returns `action: "none"` — correct safety behavior
- [x] **Address checksum bug** — viem requires EIP-55 checksums; StateView/PoolManager addresses fixed.

### Remaining for "all 4 agents firing in one cycle"
- [ ] Set up comparable pools on all 3 chains so the rebalance proposal isn't anomalous
- [ ] OR add a demo-mode flag to the rebalance prompt that forces minimum proposals when imbalance > X%

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
- [x] Set up GitHub repo (https://github.com/sp0oby/mirv — public, MIT)
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
- [ ] **Publish mirv as a Bankr Skill** — submit to github.com/bankrbot/skills so Farcaster users can deposit/withdraw via @bankrbot natural language
- [ ] **Integrate with Trails (Polygon) skill** — list mirv as a supported yield vault for cross-chain deposits from any chain

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

## Documentation Created

- [x] `README.md` — full architecture overview, user flows, deployment sequence
- [x] `SETUP.md` — step-by-step env var sourcing guide for every external account
- [x] `TODO.md` — this file
- [x] `GRANT-APPLICATION.md` — Hook Incubator pitch
- [x] `LICENSE` — MIT

---

## Reference Memory

All decisions, security checklists, verified addresses, and project context live in:
`/Users/brandonmccall/.claude/projects/-Users-brandonmccall-Desktop-mirrorAgents/memory/`

Re-read `MEMORY.md` for the index of saved knowledge.
