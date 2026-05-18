# mirv — Complete Build Checklist

**Legend:** `[x]` done & tested · `[ ]` not started · `[~]` in progress · `[?]` blocked / needs decision
**Updated:** 2026-05-18 (post-soak-audit pass)

**Current build status:** ✅ `forge build` green · ✅ `forge test` **85/85** passing (73 unit/invariant + 12 fork) · ✅ `tsc` zero errors · ✅ v5 testnet live on Base Sepolia + ETH Sepolia, all 6 contracts verified · ✅ CI green on `main` · ✅ Phase A (canonical pairId dispatch) + Phase D (CCTP deposit) validated end-to-end on v5 · 🟡 Phase 5.B agent soak: 6-bug audit + deterministic cast verification landed (commit `342a8aa`); confirming live-agent run deferred until system is free.

**v5 testnet addresses** (deployed 2026-05-17, see README §16 for explorer links):
- Base Sepolia: Treasury `0x24FAb487…ea2b` · Hook `0x6184B71D…0540` · Vault `0x6C2288CB…7934` · Factory `0x0C7a7cdD…74c2`
- ETH Sepolia:  Hook `0x3F6F9870…8540` · Relayer `0xC36062cf…6B58`
- Canonical pairId (ETH-USDC-V1): `0x7a00c543…085b04`

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
- [x] `MirrorHook.sol` — V4 hook with afterSwap/afterAdd/afterRemove + Hyperlane dispatch + Pyth/Chainlink oracle. v5 hardening: `IMessageRecipient.handle()` for inbound depth notifications, `authorizedSenders` mapping, canonical pairId immutable, `_dispatchToAllSisters` DOS-safe via `_dispatchOne` try/catch, Pyth confidence ≤ 1% check, `_updateLocalDepth` tracking, unified `_eventUsdValue` helper.
- [x] `MirrorVault.sol` — ERC-4626, 15% perf fee on extra yield only. v5: chain registry (`addChain`/`removeChain`/`setAllocations`), CCTP integration in `_splitAndBridge` (try/catch per route — DOS-safe), async withdrawal queue (`requestWithdraw`/`fulfillWithdraw`/`cancelWithdraw`), `ChainConfig` packed 5→3 storage slots.
- [x] `MirrorFactory.sol` — Canonical pair registry (pure registry, deployments via standalone scripts to stay under 24KB). `registerCanonicalPair(name, fee, tickSpacing)` issues chain-independent pair ids; `registerLocalPair` records per-chain token+hook addresses.
- [x] `Treasury.sol` — thin fee router to Gnosis Safe
- [x] `Relayer.sol` — Hyperlane IMessageRecipient + unlockCallback. v5: `RebalanceMessage` struct synced with Hook (`currentDepth` field added for cross-chain depth notifications).
- [x] **Architectural milestones (Phase A/B/C)**: canonical pairId across chains ✓ · Vault chain registry for extensibility ✓ · CCTP for USDC bridging ✓ · async withdrawal queue ✓ · symmetric `handle()` notification path ✓ · all v5 hardening landed (DOS-safe, Pyth conf, struct packing) ✓

### Scripts
- [x] `script/MineHookAddress.s.sol` — CREATE2 salt miner for hook permission bits (compiles)
- [x] `script/Deploy.s.sol` — separate DeployBase / DeployEthereum / DeployBnb contracts (compiles)
- [x] `script/WireSisterDomains.s.sol` — WireBase + WireMainnet + WireBnb (compiles)
- [x] `script/SeedLiquidity.s.sol` — SeedBase + FundHookEthereum + FundHookBnb (compiles)
- [ ] **Note:** scripts not yet executed against any RPC — needs env vars + testnet ETH

### Tests (85/85 passing as of v5 hardening)
- [x] `test/helpers/TestBase.sol` — Vault+Treasury scaffolding with MockERC20 + MockTokenMessenger
- [x] `test/MirrorVault.t.sol` — deposit/withdraw/harvest/fuzz + **chain registry tests** (addChain / removeChain / setAllocations sum enforcement / previewSplit) + **withdrawal queue tests** (requestWithdraw custody / fulfillWithdraw burn-and-pay / cancelWithdraw after 24h / sync-revert on InsufficientLocalBalance)
- [x] `test/MirrorFactory.t.sol` — canonical pair registry (registerCanonicalPair / duplicate revert / registerLocalPair / token ordering / agent auth)
- [x] `test/Treasury.t.sol` — forwarding, ETH receive, Safe rotation, fuzz
- [x] `test/Relayer.t.sol` — Hyperlane message handling, sender auth, registerPool, pause (RebalanceMessage struct synced with Hook)
- [x] `test/integration/HookCallback.t.sol` — **11/11 passing** on Base fork. Covers V4 callbacks + canonical pairId dispatch pipeline + `handle()` inbound regression tests (test_handleAcceptsAuthorizedSister / test_handleRevertsIfNotMailbox / test_handleRevertsIfUnauthorizedSender / test_handleSkipsZeroDepthSoAgentDispatchDoesNotClobber / test_imbalanceFromLpEventFiresDispatch / test_afterAddLiquidityUpdatesLocalDepth / test_afterRemoveLiquidityShrinksLocalDepth).
- [x] `test/integration/MirrorFlow.t.sol` — **1/1 passing** full lifecycle: pool init → 2-user deposit → real V4 swap → cross-chain yield report → harvest → partial redeem, all on Base fork
- [x] `test/invariant/VaultInvariants.t.sol` — **4/4 passing** invariants via VaultHandler fuzzer: nonNegativeState, sharesBackedByAssets, totalAssetsContainsLocalBalance, treasurySharesMonotonic
- [x] `src/mocks/MockTokenMessenger.sol` — CCTP test mock (depositForBurn pulls + "burns")
- [x] `src/mocks/MockHyperlaneMailbox.sol` — Hyperlane test mock with try/catch deliver

### Static Analysis
- [x] Install Slither (`pip3 install --user slither-analyzer` → 0.11.5)
- [x] **Slither v5 hardening pass (2026-05-17)**: 158 → 152 findings. P0/P1 resolved in source:
  - **Fixed:** CEI ordering in `MirrorHook._handleEvent` (lastDispatchTime set BEFORE external dispatch)
  - **Fixed:** `PerformanceFeePaid` event now indexes `treasury` address
  - **Fixed v5:** `MirrorHook._dispatchToAllSisters` wraps each sister in try/catch via external `_dispatchOne` (DOS-safe; emits `DispatchFailed` on per-route failure)
  - **Fixed v5:** `Vault._splitAndBridge` wraps each CCTP `depositForBurn` in try/catch (deposits succeed even with paused CCTP route; emits `CctpBridgeSkipped`)
  - **Fixed v5:** `MirrorHook._getOraclePrice` validates Pyth confidence ≤ 1% of price (PYTH_MAX_CONF_BPS = 100) — falls through to Chainlink on noisy Pyth feeds
  - **Fixed v5:** `setDispatchCooldown` emits `DispatchCooldownUpdated(old, new)`; `setAllocations` explicit `total = 0` + cached `enabledDomains.length`
  - **Gas v5:** `ChainConfig` struct packed 5 slots → 3 (~40k gas/Vault.addChain)
  - Won't-fix (triaged): `low-level-calls` (V4 hook callbacks + Treasury ETH forward — guarded by onlyOwner/nonReentrant), `naming-convention`, `timestamp` (minute-scale cooldowns — miner manipulation infeasible), `solc-version` (lib/), `assembly` (lib/), `too-many-digits` (lib/), `arbitrary-send-eth` (Treasury → configured Safe), reentrancy-events (under nonReentrant + CEI), mock contracts
- [x] Add Slither config (`.slither.config.json`) with filter_paths + exclude_optimization + detector exclusions for our patterns
- [x] **Mythril** ran on MirrorHook runtime bytecode (2026-05-17). 34 SWC-101 (Integer Arithmetic) findings — **all false positives under Solidity 0.8+ compiler-inserted overflow checks**. No reentrancy, no unprotected calls, no assertion violations, no TOD issues. Documented in `feedback_mythril_swc101_on_solidity_0_8.md`. For deeper analysis on 0.8+ codebases consider Echidna / halmos / certora.
- [ ] Run `aeon-vuln-scanner` (Bankr skill) — needs Bankr account; defer to Phase 6
- [x] **Workflow rule established 2026-05-17**: run `forge build --sizes` + `slither .` BEFORE every testnet deploy, not after. See `feedback_run_slither_before_deploy.md` — mirv ate 5 testnet deploy iterations because we ran static analysis AFTER each one instead of catching issues up-front (e.g. 24KB Factory size limit).
- [x] `forge fmt --check` clean
- [x] `forge inspect` storage layout captured to `packages/contracts/snapshots/` (Hook, Vault, Factory, Treasury, Relayer) — used for upgrade-safety diffs in Phase 6

### Security Checklist (from `memory/ref_security_checklist.md`)
- [x] All token decimal handling dynamic — audited 2026-05-17, no hardcoded 1e18 for token decimals. ERC-4626 handles internally. Agent reads decimals() dynamically. BNB Binance-Peg tokens are 18 decimals (documented in .env.example).
- [x] CEI + ReentrancyGuard on all external-calling functions
- [x] SafeERC20 used everywhere
- [x] Oracle has staleness check (Chainlink 1h max, Pyth 60s)
- [x] ERC-4626 virtual offset (OZ v5 default)
- [x] No infinite approvals — `forceApprove(exactAmount)` only
- [x] Explicit access control on every state-changing function
- [x] Custom errors instead of require strings
- [x] Events emitted on every state change
- [x] MEV / sandwich vectors — known ERC-4626 design constraint with external yield reports. Mitigations available (withdrawal lockup OR RiskAgent pattern detection), deferred to Phase 6 audit decision.
- [x] Fee-on-transfer token safety — N/A for current asset set (USDC + Binance-Peg USDT/USDC are all standard ERC-20, no transfer fees). Recommendation: MirrorFactory should reject FoT tokens in future non-stablecoin pairs.
- [x] EIP-712 replay safety — N/A (no signed operations in mirv; agent ops use direct EOA tx)
- [x] Source verified on block explorer after deploy (pending)

### Missing Onchain Data (must source before deploying that chain)
- [x] BNB Chain V4 PoolManager: `0x28e2ea090877bf75740558f6bfb36a5ffee9e9df` (from developers.uniswap.org)
- [x] Hyperlane Mailbox on Ethereum: `0xc005dc82818d67AF737725bD4bf75435d065D239`
- [x] Hyperlane Mailbox on Base: `0xeA87ae93Fa0019a82A727bfd3eBd1cFCa8f64f1D`
- [x] Hyperlane Mailbox on BNB: `0x2971b9Aec44bE4eb673DF1B88cDB57b96eefe8a4`
- [x] Pyth oracles all 3 chains (verified from docs.pyth.network)
- [x] Chainlink ETH/USD all 3 chains (BNB: `0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e`)
- [x] Hyperlane domain IDs confirmed (Ethereum=1, Base=8453, BNB=56)
- [x] **BNB Chain USDC + USDT + ETH addresses** (added to `.env.example`):
  - USDC-bep: `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` (**18 decimals**, not 6)
  - USDT-bep: `0x55d398326f99059fF775485246999027B3197955` (**18 decimals**)
  - ETH-bep:  `0x2170Ed0880ac9A755fd29B2688956BD959F933F8` (18 decimals)
- [x] **Pyth ETH/USD feed ID matches across chains** — confirmed. Pyth IDs are cryptographic asset identifiers, NOT chain-specific. Same `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` works on Ethereum mainnet, Base, BNB, Arbitrum, etc. Verified by reading docs.pyth.network plus inspecting Pyth's price-feed-id repository.

---

## Phase 2 — AI Agents

### Scaffold
- [x] `package.json` — LangGraph + Anthropic SDK + viem + ioredis + zod
- [x] `tsconfig.json` — NodeNext, strict, ES2022
- [x] `yarn install` — all deps installed
- [x] `npx tsc --noEmit` exits 0

### State + Tools
- [x] `state.ts` — TypeScript types + LangGraph `Annotation` state
- [x] ~~`tools/poolState.ts`~~ — removed 2026-05-18 (dead code, no importers). getPoolState + getChainlinkPrice live inline in `agents/monitor.ts` toolHandlers; the standalone file was a leftover from an early refactor.
- [x] `tools/hyperlane.ts` — estimateHyperlaneFee, encodeRebalancePayload, sendHyperlaneMessage. Uses `chains.ts` for testnet/mainnet viem chain resolution.
- [x] `tools/redis.ts` — saveToRedis / loadFromRedis / appendCycleHistory
- [x] `bootstrap.ts` + `chains.ts` (added 2026-05-18) — env loader that runs before any static import reads `process.env`, and centralized viem chain object resolution for testnet/mainnet.
- [ ] `tools/pyth.ts` — fetch Pyth update VAA from Hermes endpoint
- [ ] `tools/onchain.ts` — `updateCrossChainAssets`, `updateBaselineApy`, `harvest` callers
- [ ] `tools/baseline.ts` — calculate baseline single-chain APY from historical data

### Agent Implementations
- [x] `agents/monitor.ts` — MonitorAgent ReAct loop
- [x] `agents/rebalance.ts` — RebalanceAgent JSON output
- [x] `agents/coordinator.ts` — CoordinatorAgent + on-chain execution
- [x] `agents/risk.ts` — RiskAgent veto logic
- [x] `graph.ts` — LangGraph StateGraph. **Updated 2026-05-17 for v5 launch: 2 MonitorAgents at launch (Base + Ethereum)** — BNB monitor behind `ENABLE_BNB_MONITOR=true` env flag for post-launch enablement once CCTP-BNB + V4-BNB ship. parallel monitors → rebalance → risk → coordinator → record.
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
- [ ] **Live test against v5 testnet** (pending Claude credit top-up — see Phase 5.B agent soak item)

### Memory & Learning (Phase 2.5)
- [ ] Outcome logger — write rebalance outcome (imbalance before/after, yield earned) to Redis after each cycle
- [ ] 24h reflection job — review last day's actions, suggest prompt tweaks
- [ ] Human-in-the-loop mode for first 2 weeks (require manual approval via admin panel)
- [ ] Dataset export — dump 3 months of cycles for future fine-tuning

### External Context (Bankr Skills — optional but high-value)
- [ ] Integrate `aeon-defi-monitor` — feed competing vault APR/TVL data into RebalanceAgent context for accurate baseline APY
- [ ] Integrate `aeon-defi-overview` — feed daily DeFi regime call (RISK-ON / NEUTRAL / RISK-OFF) into RiskAgent
- [ ] Consider ERC-8004 agent identity registration for CoordinatorAgent (transparency + reputation)

**📝 Note on Bankr accounts:** A single **developer/protocol** Bankr account is enough — there is NEVER a per-agent Bankr account in this design.
- `aeon-vuln-scanner` (Phase 6): your dev account, run once before audit
- `aeon-defi-monitor` / `aeon-defi-overview` (Phase 2.5): one protocol account, all 4 agents consume the data through shared API calls
- Bankr Skill publishing (Phase 10): one team account, owns the public skill listing
- x402 proxy for Claude credits (Phase 8): protocol treasury, one service for all agents
The mirv agents use a shared **Anthropic** API key + a single shared `AGENT_PRIVATE_KEY` for on-chain signing. They don't have individual Bankr identities until/unless Phase 11 stretch adds ERC-8004 agent identities.

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

### Remaining (deferred — local demo)
**Most of these were superseded by Phase 5 going live on real testnets.** Anvil demos are still useful for fast iteration but no longer the critical path.
- [x] ~~Get non-zero active liquidity in the Base pool~~ — L=1e12 confirmed; tested on real Base Sepolia v5 pool now.
- [x] ETH Sepolia testnet deploy script written + executed (`testnet-deploy-v4.sh`, deployed v5 successfully).
- [x] Stale `PYTH_ADDRESS_BNB` fixed in `.env.example`.
- [ ] **Tune pool depth for meaningful TVL on Anvil forks** — low priority; testnet is the primary demo surface now.
- [ ] BNB testnet deploy script — N/A until V4 ships on BNB testnet.

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
**Now relevant for testnet (Phase 5.B agent soak)** rather than Anvil. Estimated ~$5-20 in Claude credits for a meaningful soak. **Pending user credit top-up.**

- [x] Trigger artificial imbalance via `reportSisterDepth()` — proven on testnet (Phase A validation used this exact pattern).
- [ ] **Run agent loop against v5 testnet for 1-2 hrs** — observe Claude calls + decision flow + agent's `dispatchRebalance` to v5 contracts. Validates the full Monitor (×2 chains) → Rebalance → Risk → Coordinator → dispatchRebalance → Hyperlane → Relayer.handle pipeline against live contracts.
- [ ] **Watch the full chain** fire end-to-end on testnet:
  - MonitorAgent (×2 chains, Base + Ethereum) → real depth reported
  - RebalanceAgent → proposes a moveable rebalance
  - RiskAgent → green/yellow assessment
  - CoordinatorAgent → encodes + dispatchRebalance via hook
  - MockHyperlane relay daemon → delivers to destination
  - Relayer.handle → executes (will revert on `modifyLiquidity` without LP funding, expected)

**When to do this:** when you want to demo the full visible loop. Each demo run = ~$1-3 in API credits depending on duration. Use sparingly.

---

## Phase 5 — Testnet Deployment ✅ LIVE

**Status:** v5 testnet deployed 2026-05-17 on Base Sepolia + ETH Sepolia. All 6 contracts verified on block explorers. Phase A (canonical pairId dispatch) + Phase D (CCTP deposit) validated end-to-end. BNB deferred to post-launch enablement (single admin tx, no protocol redeploy).

**Live addresses** see README §16. Canonical pairId (ETH-USDC-V1): `0x7a00c543…085b04` — matches on both chains ✓

### A. Prerequisites ✅ DONE
- [x] Sepolia ETH on deployer wallet (Base + ETH Sepolia)
- [x] Block explorer API keys (BaseScan + Etherscan) — both in `.env`
- [x] Testnet addresses for V4 PoolManager / Hyperlane Mailbox / Pyth / Chainlink / USDC / WETH on both chains, all in `.env.example` + `.env`
- [x] Circle CCTP testnet TokenMessenger addresses (Base Sepolia + ETH Sepolia, both `0x9f3B…0aa5`) — in `.env`
- [x] BNB testnet decision: SKIP. V4 not deployed there; CCTP doesn't yet support BNB. Architecture supports adding BNB via `Vault.addChain(...)` admin tx post-launch when both ship.

### B. Pre-deploy code work ✅ DONE
- [x] All testnet deploy scripts written (`testnet-deploy-v4.sh` — full end-to-end pipeline)
- [x] `Deploy.s.sol` parameterized for testnet (reads VAULT_ASSET_BASE / WETH_BASE / CCTP_TOKEN_MESSENGER_BASE from `.env`)
- [x] `MineHookAddress.s.sol` updated to include `canonicalPairId` in CREATE2 init code
- [x] `monitor.ts` has `NETWORK=mainnet|sepolia` env flag for token address swap
- [x] `testnet-wire-sisters.sh` env-driven, handles 2-chain testnet (BNB skipped via skip-zero pattern in WireMainnet)
- [x] `forge build --sizes` discipline established (caught the 24KB Factory size limit before v5 deploy)

### C. v5 deployment ✅ DONE 2026-05-17
- [x] **Base Sepolia**: mined hook salt 10704, deployed Treasury + Hook + Vault + Factory, verified all 4 on BaseScan
- [x] **ETH Sepolia**: mined hook salt 15859, deployed Hook + Relayer, verified both on Etherscan (Relayer verified automatic, Hook needed retry due to Etherscan timing)
- [x] Factory `registerCanonicalPair("ETH-USDC-V1", 3000, 60)` + `registerLocalPair` for both chains
- [x] Vault chain registry: Base (84532, 6000 BPS) + ETH (11155111, 4000 BPS, CCTP recipient left-padded ✓)
- [x] Sister wiring: Base hook ↔ ETH Relayer (executable) + Base hook ← ETH hook (handle() inbound) + both auth senders set
- [x] V4 pools initialized at tick 199800 on both chains with mirv hooks attached
- [x] Relayer registerPool for canonical pairId on ETH Sepolia
- [x] Both hooks funded 0.01 ETH each for Hyperlane dispatch fees

### D. Smoke tests on testnet ✅ DONE
- [x] **Phase A (canonical pairId dispatch)** validated on v5 (2026-05-17): Base→ETH dispatch msg `0xd6d2…750a` + ETH→Base dispatch msg `0xb2aa…858c`, both carry canonical pairId `0x7a00c543…b04` matching `canonicalPairId()` on both hooks
- [x] **Phase D (CCTP deposit)** validated on v5: 1 USDC deposit → 0.6 USDC local + 0.4 USDC burned via CCTP → Circle attestation → MessageTransmitter.receiveMessage on ETH Sepolia → 0.4 USDC native USDC minted to Relayer (tx `0xc184bcc4…13cf`)
- [x] Vault accounting correct: deployer shares minted 1:1, vault local balance == 60% of deposit, deployer USDC balance decreased exactly by deposit amount
- [x] `CctpBridgeSent` event fires with correct left-padded `mintRecipient` (the bytes32 padding bug from manual remediation cannot recur — script uses correct format)
- [~] **B: Agent loop ran against v5 testnet** (2026-05-18, 3-cycle controlled soak, ~$0.10 Claude credits). 9 Claude Sonnet 4.6 invocations across the loop (2 monitors + 1 rebalance per cycle), multi-round tool calling worked, conditional routing skipped Risk/Coordinator on `action=none`. **However:** post-soak audit revealed the agent had been reading the *wrong pool* — see resolution log entry below. Added `MAX_CYCLES` env cap to `index.ts` for controlled runs.
- [x] **Source V4 StateView lens addresses for Base Sepolia + ETH Sepolia** — done (commit `342a8aa`). Both StateView env keys (`STATE_VIEW_BASE_SEPOLIA`, `STATE_VIEW_ETH_SEPOLIA`) populated in `.env.example`; `STATE_VIEWS` map in `monitor.ts` branches on `IS_SEPOLIA`. Same pattern applied to `POOL_MANAGERS`.
- [x] **6-bug monitor.ts audit pass + fixes landed** (2026-05-18, commit `342a8aa`):
  1. Hardcoded mainnet PoolManager/StateView → testnet branch added.
  2. Second mainnet-only Chainlink feed lookup nested in `getPoolState` → mirrors outer NETWORK branch.
  3. Sister-chain `getPoolState` calls with wrong token addresses → system + user prompts rewritten to constrain monitor to its assigned chain.
  4. TVL math priced WETH as USD when token0=USDC on Sepolia → decimals-aware stablecoin detection.
  5. Base Sepolia token order was inverted (USDC < WETH on Sepolia, not WETH < USDC like mainnet Base) → fixed.
  6. **HOOK_ENV_KEY mapping bug** — monitor.ts looked up `MIRROR_HOOK_ETHEREUM` but env keys are `_MAINNET`/`_BASE`/`_BNB`. The wrong key meant hookAddress fell back to `0x0`, so the agent computed the *no-hook* USDC/WETH poolId (with random testnet liquidity L≈1e18) instead of mirv's poolId (L=2e9). This is why the original "validated" soak silently read the wrong pool.
  Additional infra fixes in same commit: `bootstrap.ts` so env loads before any static import reads `process.env`; `chains.ts` so viem signs with the right chainId; surfaced silent `catch` in `runMonitorAgent`.
- [x] **Deterministic cast verification of the fix** (2026-05-18) — computed canonical poolId on both chains using env-driven hook addresses, called `StateView.getLiquidity(poolId)` directly:
  - Base Sepolia: hook `0x6184…C540` → poolId `0x689c…7dcd` → **L = 2,000,000,000** ✓
  - ETH Sepolia: hook `0x3F6F…8540` → poolId `0x89d9…755d` → **L = 2,000,000,000** ✓
  This is enough to prove the agent (when it next runs) will compute the same poolId and read the actual mirv pool, not the no-hook ghost pool.
- [ ] **B follow-up: live agent soak confirming L=2e9 reads** (~$0.05, `MAX_CYCLES=2`) — deferred because tsx cold start exceeded 4 min under current system load (avg 3-4, 5.5GB swap). Not blocked on code; run when system is free.
- [ ] **B follow-up: longer soak (1-2 hrs)** once the short validation soak above passes — let Claude actually decide on rebalances over time. Estimated ~$5-20 depending on cycle count and whether the agent triggers any `dispatchRebalance` calls.
- [ ] Verify Hyperlane testnet delivers messages → Base hook `handle()` updates sisterDepths and ETH Relayer's modifyLiquidity executes. Testnet relayer latency varies; not always actionable on our end.
- [ ] Test `harvest()` after simulated yield report — verify treasury receives fee shares (works on Anvil; redo on testnet)
- [ ] Test `pause()` from RiskAgent — verify hook stops dispatching

### E. Documentation
- [x] README §16 updated with v5 testnet addresses + explorer links
- [x] BRIDGE-DESIGN.md written (CCTP for USDC, treasury-seeded WETH inventory, async withdrawal flow, BNB enablement runbook)
- [ ] Capture Hyperlane explorer screenshots showing the dispatched cross-chain messages for the grant pitch

### F. Phase 5 known gaps — resolution log
- [x] **Agent silently read the wrong pool on Sepolia** (uncovered 2026-05-18, fixed commit `342a8aa`). The Phase 5.B "validated" soak was misleading: `HOOK_ENV_KEY` looked up `MIRROR_HOOK_ETHEREUM` while env keys are `_MAINNET`/`_BASE`/`_BNB`; the fallback `0x0` hook address produced a poolId for the no-hook USDC/WETH pool on each Sepolia (random testnet liquidity L≈1e18) instead of mirv's pool (L=2e9). Five additional bugs in the same audit (hardcoded mainnet StateView/PoolManager, nested mainnet-only Chainlink feed, sister-chain getPoolState calls, decimals-blind TVL math, inverted Base Sepolia token order) compounded the wrong result. All fixed; deterministic `cast` re-verification confirms the agent now resolves to the actual mirv poolId on both chains. Live re-run deferred only on system-load grounds.
- [x] **Bug: `localDepthUsd` never written + unit-math mismatch in `_handleEvent`** — fixed in v2 (`_updateLocalDepth` + unified `_eventUsdValue` helper). Regression test `test_imbalanceFromLpEventFiresDispatch` covers the full pipeline.
- [x] **ETH/BNB hooks dispatch into a void (architectural gap)** — fixed in v3 (`IMessageRecipient.handle()` on MirrorHook + `authorizedSenders` mapping + admin setter; `RebalanceMessage.currentDepth` field).
- [x] **Cross-chain pair-identity mismatch** — fixed in v4 (canonical pairId via Factory; Hook immutable; defensive check in handle()).
- [x] **Phase A (Foundation)** — Vault chain registry + Factory registerLocalPair for multi-chain extensibility without redeploys.
- [x] **Phase B (Bridge value plane)** — CCTP for USDC in Vault `_splitAndBridge`. WETH simplified to treasury-seeded inventory per BRIDGE-DESIGN.md §3.2.
- [x] **Phase C (Async withdrawal queue)** — `requestWithdraw`/`fulfillWithdraw`/`cancelWithdraw` + sync revert on `InsufficientLocalBalance`.
- [x] **Phase C (Slither + Mythril hardening)** — v5 pass: 158→152 Slither findings, P0/P1 resolved (DOS-safe dispatch + Vault bridge, Pyth confidence check, event coverage, struct packing). Mythril: 34 SWC-101 false positives documented.
- [x] **v5 testnet redeploy** — done 2026-05-17. v1-v4 contracts abandoned on testnet (small stranded balances acceptable).
- [x] **Token-order assumption in `_updateLocalDepth` + `_eventUsdValue`** — *mainnet impact: none if pool is always WETH/USDC with WETH < USDC ordering (matches Base mainnet).* On testnet the ordering is reversed (USDC < WETH), so stored USD values are unit-skewed. Dispatch mechanism still triggers correctly. Generalization (per-pair oracle config) deferred — not blocking mainnet for the initial ETH/USDC pair on Base.
- [ ] **Pool registration / initialization / funding on destination Relayer for executable deliveries** — pool IS registered + initialized on ETH Sepolia for canonical pairId. Relayer USDC inventory grows naturally from CCTP deliveries (now has 0.4 USDC from the Phase D smoke). Relayer WETH inventory needs treasury seeding before non-zero-delta dispatches succeed — that's a launch-day op step per BRIDGE-DESIGN.md §3.2, not a contract change.
- [ ] **Investigate `withdrawEth` revert on Base Sepolia** (low-priority pre-mainnet hygiene). The function reverts at `(bool ok,) = owner().call{value: amount}("")` on Base Sepolia even when all preconditions hold. Works fine on ETH Sepolia. Orphaned ~0.04 ETH across the v1-v4 abandoned hooks on Base Sepolia. Needs `cast trace` or Foundry replay before mainnet to understand the failure mode.
- [ ] **Hyperlane testnet delivery latency** — testnet relayers are best-effort (1–5 min to never). Mainnet is reliable; not blocking.

---

## Phase 6 — Audit Preparation

- [x] Slither + Mythril triage done as part of v5 hardening (2026-05-17). Slither P0/P1 resolved; Mythril SWC-101 noise on 0.8+ documented.
- [x] Foundry test suite: **85/85 passing** (73 unit + invariant + 12 fork). Re-runs cleanly on every commit via CI.
- [x] BRIDGE-DESIGN.md documents value-plane architecture (CCTP for USDC, treasury-seeded WETH inventory, async withdrawal, BNB enablement runbook).
- [x] Freeze contract versions — annotated tag `v1.0.0-rc1` at `7f937e2` pushed to origin 2026-05-18. Contracts byte-identical to v5 hardening (`94fbdaa`); tag note enumerates audit scope, test/Slither/Mythril state, and known open items. Auditors should reference `git checkout v1.0.0-rc1`.
- [x] `audits/THREAT-MODEL.md` (2026-05-18) — 8 actors enumerated (user, agent EOA, owner multisig, Hyperlane, Circle CCTP, oracle, sister hook, V4 PoolManager) + composition risks + 13 numbered recommendations (R-1..R-13) graded high/medium/low for audit triage.
- [x] `audits/SCOPE.md` (2026-05-18) — in/out scope, function-by-function notes per contract, external-protocol trust roots, severity rubric. Anchored at `v1.0.0-rc1`.
- [x] `audits/INVARIANTS.md` (2026-05-18) — 14 invariants (I-1..I-14) covering vault solvency, totalAssets decomposition, performance-fee accounting, share-supply consistency, allocation sum, canonical pair identity, cooldown monotonicity, hook permission bits, sister-message auth, ETH custody, CCTP approval residue, no infinite approvals, CEI, dispatch fee solvency. Each entry: statement, enforcement site, Foundry test coverage. Items marked **\[runner-gap\]** are highest-value places to add fuzz tests during audit prep.
- [ ] `aeon-vuln-scanner` pass (Bankr skill) — needs Bankr account.
- [ ] Investigate `withdrawEth` revert on Base Sepolia (carried from Phase 5) — must understand the failure mode before mainnet.
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
- [x] Alchemy account — Ethereum + Base endpoints + Sepolia testnet endpoints, all in `.env`. BNB endpoint pending post-launch enablement.
- [x] Anthropic API account — Claude Sonnet 4.6 key in `.env`. **Top-up pending for Phase 5.B agent soak test.**
- [x] Block explorer API keys: Etherscan + BaseScan in `.env`. BSCScan pending post-launch.
- [ ] Railway project — agent service + Redis add-on
- [ ] Vercel project — frontend deployment
- [ ] Tenderly project — failed-tx alerts
- [ ] Dune workspace — public dashboard
- [ ] Telegram bot for heartbeat / failed cycle alerts
- [ ] Discord server for community
- [ ] Gnosis Safe set up on each launch chain (Treasury recipient) — Base + Ethereum at launch; BNB post-launch

### CI/CD
- [x] `.github/workflows/contracts.yml` — `forge fmt --check`, `forge build --sizes`, `forge test` (skips fork tests in CI since no RPC), storage layout snapshot, Slither (separate job). **Green on every commit since `b0e1e82` (fix used `forge install --no-git` after `git submodule update --init` ran into the nested `.gitmodules` quirk).**
- [x] `.github/workflows/agents.yml` — `tsc --noEmit` on agent changes. Green.
- [ ] `.github/workflows/frontend.yml` — `next build`, type-check (Phase 3 will add this)
- [ ] Branch protection on `main` — require all CI green
- [ ] Auto-deploy agents to Railway on `main` push (after manual approval)

### Monitoring
- [ ] Tenderly alerts — any reverted tx from agent wallet → Telegram
- [ ] Dune dashboard — Mirrored TVL, weekly extra APY, rebalance count, fee revenue
- [ ] Custom heartbeat — agent posts to Telegram every cycle (or every Nth cycle)
- [ ] Pyth update job — push fresh prices on-chain when stale
- [ ] Agent wallet balance monitor — alert at <0.05 ETH per chain
- [ ] Hook ETH balance monitor — alert at <0.01 ETH (for Hyperlane fees)

### Agent operating cost auto-replenishment (x402 proxy)
**Goal:** Agents call Claude paying USDC per request, treasury auto-tops-up agent wallet from performance fees. No human ever buys API credits manually.

Pattern:
```
mirv agent → x402 proxy (claude-proxy.mirv.xyz) → Anthropic API
                  ↑
        USDC on Base, paid per-call
                  ↓
        proxy holds CC-funded Anthropic key + Coinbase Commerce off-ramp
                  ↑
        Treasury → AGENT_WALLET top-up cron (when balance < threshold)
```

- [ ] Set up Cloudflare Worker / Vercel Function at `claude-proxy.<domain>` that:
  - Holds an Anthropic API key (funded via Coinbase Commerce → credit card auto-reload)
  - Implements x402 HTTP 402 challenge/response (USDC on Base)
  - Forwards paid requests to `api.anthropic.com`
  - Refs: https://x402.org, https://github.com/coinbase/x402
- [ ] Update `src/llm.ts` to add `X-PAYMENT` header with USDC tx hash (~5 LOC, optional flag)
- [ ] Top-up cron: when `AGENT_WALLET` balance on Base < $50, transfer $200 from Treasury Gnosis Safe
- [ ] Alternative: explore Bankr's `bankr-x402-sdk-dev` to skip building the proxy (they may add Claude support per request)
- [ ] Phase 11 stretch: when Anthropic + OpenAI ship native crypto billing, remove the proxy entirely

**Cost analysis (today):**
- Sonnet 4.6 per cycle: ~$0.005 (4 Claude calls @ ~1.2K input + 0.3K output)
- 45s cycle → 1920 cycles/day → ~$9.60/day → ~$290/month
- Treasury 15% performance fee on $100k extra annual yield = $15k/year = $1250/month
- Margin: ~$960/month after agent ops (using Sonnet)
- Opus 4.7 (5× cost): ~$1450/month ops — only marginally profitable until TVL scales

---

## Phase 9 — Mainnet Launch

### Pre-flight
- [ ] All audit findings resolved (Critical + High at minimum)
- [ ] All addresses verified one final time against current docs
- [ ] Hot wallet for agent funded with ~0.2 ETH per chain
- [ ] Treasury Gnosis Safes set up + signers confirmed
- [ ] Public website soft-launched (preview URL)
- [ ] Documentation site live (gitbook or similar)

### Deploy (Base + Ethereum at launch; BNB post-launch via admin tx)
- [ ] Run `forge build --sizes` + `slither .` one final time → confirm sizes < 24KB + no new high/medium findings
- [ ] Mine hook addresses for mainnet via `MineHookAddress.s.sol` (canonical pairId baked into init code; salt per chain)
- [ ] DeployBase → record `MIRROR_HOOK_BASE`, `MIRROR_VAULT_BASE`, `MIRROR_FACTORY_BASE`, `TREASURY_BASE`. DeployBase calls `registerCanonicalPair("ETH-USDC-V1", 3000, 60)` + `registerLocalPair` + `Vault.addChain(Base, 0, 0, ..., 10_000)` automatically.
- [ ] DeployEthereum → record `MIRROR_HOOK_MAINNET`, `RELAYER_MAINNET`
- [ ] Verify all contracts on BaseScan + Etherscan (`forge verify-contract`)
- [ ] `Factory.registerLocalPair(canonicalId, ETH_MAINNET_DOMAIN=1, USDC_MAINNET, WETH_MAINNET, HOOK_ETH)` on Base
- [ ] `Vault.addChain(1, CCTP_DOMAIN_ETHEREUM=0, b32(EthRelayer), ..., 4000)` + `setAllocations([Base, ETH], [6000, 4000])`
- [ ] Wire sister domains: Base hook → ETH Relayer (executable) + Base hook ← ETH hook (handle()), with auth senders
- [ ] Initialize V4 pool on both chains with mirv hook attached, pre-seeded with bootstrap liquidity
- [ ] `Relayer.registerPool(canonicalId, PoolKey{USDC, WETH, fee=3000, ts=60, hook=HOOK_ETH})` on ETH mainnet
- [ ] **Treasury seeds canonical WETH on the ETH Relayer** (~$50k worth at launch per BRIDGE-DESIGN.md §3.2)
- [ ] Fund hooks with mainnet ETH (~0.05 each for Hyperlane dispatch fees)
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
- [x] GitHub repo public from day 1 — confirmed, https://github.com/sp0oby/mirv MIT licensed.
- [x] Hyperlane Mailbox addresses — sourced for ETH mainnet + Base mainnet + BNB mainnet + Base Sepolia + ETH Sepolia. All in `.env.example`.
- [x] Token bridging decision — locked in `BRIDGE-DESIGN.md §3`: Circle CCTP for USDC (native mint/burn, no synthetic), treasury-seeded canonical WETH inventory on each Relayer at launch. No Hyperlane warp routes needed at launch.
- [x] BNB at launch — locked: ship without BNB. CCTP doesn't support BNB yet, V4 not on BNB testnet. Architecture supports adding via single `Vault.addChain(...)` admin tx post-launch; no protocol redeploy.
- [x] Default allocation — locked: 60% Base / 40% Ethereum at launch. Rebalances toward 3-chain when BNB enables.
- [x] WETH-in-pool — locked: canonical (composable with other DEX infra) rather than synthetic-only (closed-garden).
- [x] Withdrawal UX — locked: sync when Base-local USDC suffices, async 2-5 min for cross-chain unwinds (matches README §7).
- [x] Cross-chain withdrawal gas — locked: protocol pays from collected performance-fee revenue.

---

## Documentation Created

- [x] `README.md` — full architecture overview (rewritten for v5 incl. CCTP, canonical pairId, chain registry, async withdrawal), user flows, deployment sequence, live v5 testnet addresses (§16), design docs pointer (§17)
- [x] `SETUP.md` — step-by-step env var sourcing guide for every external account
- [x] `TODO.md` — this file (refreshed 2026-05-18 for v5)
- [x] `BRIDGE-DESIGN.md` — token bridge architecture (CCTP for USDC + treasury-seeded WETH), Vault chain registry, async withdrawal flow, BNB enablement runbook, multi-chain & multi-pair extensibility plan
- [x] `GRANT-APPLICATION.md` — Hook Incubator pitch
- [x] `LICENSE` — MIT

---

## Reference Memory

All decisions, security checklists, verified addresses, and project context live in:
`/Users/brandonmccall/.claude/projects/-Users-brandonmccall-Desktop-mirrorAgents/memory/`

Re-read `MEMORY.md` for the index of saved knowledge.
