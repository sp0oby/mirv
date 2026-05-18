# mirv — Audit Scope

**Tag:** `v1.0.0-rc4` (R-1, R-2, R-3, R-5, R-7, R-10, R-11, R-12, R-13 landed on top of rc1; R-4, R-6, R-9 in `audits/OPERATIONS.md`; only R-8 deferred by design)
**Pragma:** `solidity 0.8.26`
**Compiler:** `solc 0.8.26`, `via_ir = true`, `optimizer_runs = 200`
**Test state at tag:** `forge test` **130/130** (101 unit/invariant + 29 fork) · Slither 7 high/medium in-scope under repo config (all pre-existing won't-fix patterns), no new findings from rc3→rc4 · Mythril 34 SWC-101 all false-positive on 0.8+ (documented)

---

## In scope

All paths relative to repo root.

| File                                  | LOC | Role                                                                              |
|---------------------------------------|-----|-----------------------------------------------------------------------------------|
| `packages/contracts/src/MirrorHook.sol`    | 539 | V4 hook + Hyperlane dispatcher + oracle reader + `IMessageRecipient.handle`      |
| `packages/contracts/src/MirrorVault.sol`   | 512 | ERC-4626 + CCTP deposit splitter + async withdrawal queue + performance fee     |
| `packages/contracts/src/MirrorFactory.sol` | 130 | Cross-chain canonical pair registry                                              |
| `packages/contracts/src/Relayer.sol`       | 211 | Destination-chain Hyperlane recipient + V4 `unlockCallback` LP executor          |
| `packages/contracts/src/Treasury.sol`      |  80 | Fee router from Vault to Gnosis Safe                                             |
| **Total**                             | **1,472** | |

Interfaces (thin, no logic — bundled for completeness, not audit billable):

| File                                              | Purpose                                              |
|---------------------------------------------------|------------------------------------------------------|
| `packages/contracts/src/interfaces/IHyperlane.sol`   | `IMailbox` + `IMessageRecipient`                    |
| `packages/contracts/src/interfaces/IPyth.sol`        | `IPyth.Price` + `getPriceNoOlderThan`               |
| `packages/contracts/src/interfaces/IChainlink.sol`   | `AggregatorV3Interface`                              |

---

## Explicitly out of scope

| Area                                              | Why                                                                 |
|---------------------------------------------------|---------------------------------------------------------------------|
| `packages/contracts/lib/openzeppelin-contracts/*`  | OZ v5 — independently audited                                       |
| `packages/contracts/lib/v4-core/*` and `v4-periphery/*` | Uniswap V4 — independently audited                              |
| `packages/contracts/lib/uniswap-hooks/*`           | OZ Uniswap-hooks helper — independently audited                     |
| External `IMailbox` implementation (Hyperlane)    | Trusted dep; audited separately by Hyperlane                        |
| External `ITokenMessenger` (Circle CCTP)          | Trusted dep; audited by Circle                                      |
| External `IPyth` / Pyth pull-oracle attestation logic | Trusted dep; audited by Pyth                                    |
| External Chainlink aggregator + heartbeat logic   | Trusted dep; audited by Chainlink                                   |
| `packages/contracts/src/mocks/*`                   | Test-only `MockHyperlaneMailbox` + `MockTokenMessenger`             |
| `packages/contracts/script/*`                      | Deploy / wiring scripts (forge scripts, not deployed bytecode)      |
| `packages/contracts/test/*`                        | Foundry test suite                                                  |
| `packages/agents/*`                                | Off-chain TypeScript agent swarm (LangGraph + Anthropic)            |
| `packages/frontend/*`                              | Not yet implemented                                                 |

---

## Function-by-function notes

### MirrorHook.sol

The hook attached to every sister V4 pool. Holds ETH for Hyperlane dispatch fees. Receives V4 callbacks → checks imbalance → dispatches cross-chain. Also receives `handle()` notifications from sister hooks to update `sisterDepths`.

| Function                              | Mutability         | Auth                                                | Notes                                                                                                                                                                                                  |
|---------------------------------------|--------------------|-----------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `constructor`                         | nonpayable         | n/a                                                 | Validates non-zero mailbox/pyth/chainlink/canonicalPairId. Sets immutables.                                                                                                                            |
| `_afterSwap` (override)               | nonpayable         | only V4 PoolManager (BaseHook)                      | `whenNotPaused`. Calls `_handleEvent`. Always returns selector + 0 delta.                                                                                                                              |
| `_afterAddLiquidity` (override)       | nonpayable         | only V4 PoolManager                                 | `whenNotPaused`. `_updateLocalDepth(isAdd=true)` → `_handleEvent`.                                                                                                                                     |
| `_afterRemoveLiquidity` (override)    | nonpayable         | only V4 PoolManager                                 | `whenNotPaused`. `_updateLocalDepth(isAdd=false)` → `_handleEvent`.                                                                                                                                    |
| `dispatchRebalance`                   | payable            | `authorizedAgents[msg.sender]`                      | `nonReentrant whenNotPaused`. Agent-initiated rebalance. `currentDepth=0` so `handle()` won't clobber sister depth tracking.                                                                          |
| `reportSisterDepth`                   | nonpayable         | `authorizedAgents[msg.sender]`                      | Off-chain depth oracle path (now obsoleted by `handle()` but retained for emergency).                                                                                                                  |
| `handle` (IMessageRecipient)          | payable            | `msg.sender == mailbox` + `authorizedSenders[sender]`| `whenNotPaused nonReentrant`. Decodes RebalanceMessage. Silently skips messages for unrelated pairIds (no revert — prevents mailbox queue grief). Skips `currentDepth==0` so agent dispatches don't clobber. |
| `_handleEvent` (internal)             | nonpayable         | n/a                                                 | Skip-tiny-event guard (< 0.1% of depth) · cooldown guard · imbalance check · CEI: `lastDispatchTime` written BEFORE `_dispatchToAllSisters`.                                                          |
| `_dispatchToAllSisters` (internal)    | nonpayable         | n/a                                                 | Iterates `sisterDomains`, wraps each in try/catch via external self-call to `_dispatchOne`. DOS-safe: one bad sister cannot revert the LP-add tx.                                                     |
| `_dispatchOne` (external)             | nonpayable         | `msg.sender == address(this)`                       | Self-call wrapper so try/catch works. Quotes fee → reverts on insufficient ETH → mailbox.dispatch.                                                                                                     |
| `_imbalanceExceeded` (internal view)  | view               | n/a                                                 | Iterates sisters. Returns true if any sister depth differs from local by ≥ `imbalanceThresholdBps`.                                                                                                     |
| `_updateLocalDepth` (internal)        | nonpayable         | n/a                                                 | Assumes token0 = 18 dec / token1 = 6 dec (USDC). On testnet ordering is inverted; documented as known limitation.                                                                                       |
| `_eventUsdValue` (internal view)      | view               | n/a                                                 | Same token0/token1 assumption as `_updateLocalDepth`.                                                                                                                                                  |
| `_getOraclePrice` (internal view)     | view               | n/a                                                 | Pyth-first with conf ≤ 1% gate; Chainlink fallback with 1h staleness. Reverts `StaleOraclePrice` if both unavailable.                                                                                  |
| `addSisterDomain` / `removeSisterDomain` | nonpayable      | `onlyOwner`                                         | Reverts on duplicate / not-found.                                                                                                                                                                      |
| `setAgentAuthorization`               | nonpayable         | `onlyOwner`                                         | Reverts on zero address.                                                                                                                                                                               |
| `setAuthorizedSender`                 | nonpayable         | `onlyOwner`                                         | Reverts on zero sender.                                                                                                                                                                                |
| `setThresholds`                       | nonpayable         | `onlyOwner`                                         | Bounded ≤ MAX_BPS.                                                                                                                                                                                     |
| `setDispatchCooldown`                 | nonpayable         | `onlyOwner`                                         | No upper bound — owner trust assumption.                                                                                                                                                                |
| `setMaxMoveBps`                       | nonpayable         | `onlyOwner`                                         | Bounded ≤ MAX_BPS. (Note: read but not currently enforced inside `_handleEvent`.)                                                                                                                       |
| `pause` / `unpause`                   | nonpayable         | `onlyOwner`                                         | RiskAgent's circuit-breaker entry point (RiskAgent is an authorized owner-delegated EOA in practice).                                                                                                  |
| `fund`                                | payable            | open                                                | Any address can top up ETH for Hyperlane dispatch fees.                                                                                                                                                |
| `withdrawEth`                         | nonpayable         | `onlyOwner`                                         | `nonReentrant`. Open issue: reverts on Base Sepolia under unclear conditions (Phase 5.F line 408) — must be characterized before mainnet.                                                              |
| `receive()`                           | payable            | open                                                | Same as `fund` semantically.                                                                                                                                                                            |

### MirrorVault.sol

ERC-4626 vault on Base. Asset = USDC. Splits deposits per `chainConfigs` allocation and CCTP-burns to sister Relayers. Tracks `principalTracked` + `baselineYieldAccrued` and pays 15% of extra yield to treasury via share-mint on `harvest()`.

| Function                          | Mutability   | Auth                              | Notes                                                                                                                                                                                                                                                                                                                                                          |
|-----------------------------------|--------------|-----------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `constructor`                     | nonpayable   | n/a                               | Reverts on zero treasury / cctp messenger.                                                                                                                                                                                                                                                                                                                     |
| `totalAssets` (override)          | view         | n/a                               | `localUsdcBalance + crossChainAssetsReported`. The agent-reported value is the only mutable input to share price — see Threat Model § "Agent EOA".                                                                                                                                                                                                            |
| `_deposit` (override)             | nonpayable   | ERC-4626 entry path               | `whenNotPaused`. Pulls USDC, mints shares, increments `principalTracked`, accrues baseline, then `_splitAndBridge`.                                                                                                                                                                                                                                            |
| `_withdraw` (override)            | nonpayable   | ERC-4626 entry path               | `whenNotPaused`. Reverts `InsufficientLocalBalance` if local USDC < assets (callers should use `requestWithdraw` for cross-chain unwinds). Decrements `principalTracked` with floor at 0.                                                                                                                                                                      |
| `harvest`                         | nonpayable   | `authorizedAgents`                | `nonReentrant`. Min 1-day interval. Reverts `NoExtraYield` if `totalAssets ≤ principalTracked + baselineYieldAccrued`. Mints fee shares to treasury at current share price.                                                                                                                                                                                  |
| `updateCrossChainAssets`          | nonpayable   | `authorizedAgents`                | **Trust anchor.** Agent reports the off-chain LP+in-flight value. Capped by no bound; a compromised agent can inflate share price arbitrarily. Mitigations: pausability, multisig owner, RiskAgent oversight. See Threat Model § "Agent EOA".                                                                                                                  |
| `updateBaselineApy`               | nonpayable   | `authorizedAgents`                | Bounded ≤ MAX_BPS. Accrues prior baseline before updating.                                                                                                                                                                                                                                                                                                     |
| `recordRebalance`                 | nonpayable   | `authorizedAgents`                | Event-only; no state mutation.                                                                                                                                                                                                                                                                                                                                  |
| `requestWithdraw`                 | nonpayable   | open (receiver must be non-zero)  | `whenNotPaused`. Transfers caller's shares into vault custody (not burned). Records expectedAssets snapshot for UX. Returns auto-incrementing `requestId`.                                                                                                                                                                                                     |
| `fulfillWithdraw`                 | nonpayable   | `authorizedAgents`                | `nonReentrant whenNotPaused`. Pays out at **current** share price (not snapshot). Reverts if local USDC insufficient. Burns custodial shares + decrements `principalTracked`.                                                                                                                                                                                  |
| `cancelWithdraw`                  | nonpayable   | `msg.sender == requester`         | Only after `WITHDRAW_CANCEL_DELAY` (24h). Returns custodial shares to requester. Marks `cancelled`.                                                                                                                                                                                                                                                            |
| `addChain`                        | nonpayable   | `onlyOwner`                       | Reverts on duplicate. Does not re-validate the sum-to-10000 invariant — caller must follow with `setAllocations`.                                                                                                                                                                                                                                              |
| `removeChain`                     | nonpayable   | `onlyOwner`                       | Reverts if `allocationBps != 0` (operator must zero out first). Does not enforce zero in-flight USDC on-chain.                                                                                                                                                                                                                                                 |
| `setAllocations`                  | nonpayable   | `onlyOwner`                       | Validates sum == MAX_BPS across all enabled chains (including those not in input arrays).                                                                                                                                                                                                                                                                      |
| `_splitAndBridge` (internal)      | nonpayable   | n/a                               | Per-chain allocation → `forceApprove(exact)` → `cctpMessenger.depositForBurn` wrapped in try/catch. On failure: revokes approval + emits `CctpBridgeSkipped`. Failed-route USDC stays in vault (totalAssets accounting consistent).                                                                                                                              |
| `_accrueBaseline` (internal)      | nonpayable   | n/a                               | Idempotent within a block. `principalTracked * baselineApyBps * elapsed / (MAX_BPS * 365 days)`.                                                                                                                                                                                                                                                                |
| Views                             | view         | n/a                               | `enabledDomainsCount`, `getChainConfig`, `previewSplit`.                                                                                                                                                                                                                                                                                                        |
| `setTreasury`                     | nonpayable   | `onlyOwner`                       | Reverts on zero. Note: existing accrued fee shares are NOT migrated.                                                                                                                                                                                                                                                                                            |
| `setAgentAuthorization`           | nonpayable   | `onlyOwner`                       |                                                                                                                                                                                                                                                                                                                                                                |
| `pause` / `unpause`               | nonpayable   | `onlyOwner`                       | RiskAgent / multisig circuit breaker.                                                                                                                                                                                                                                                                                                                          |

### MirrorFactory.sol

Pure registry — no funds, no token transfers. Owner-only mutators. Read by deploy scripts and Vault/Hook deploys to keep chain-independent pair identity.

| Function                          | Mutability   | Auth        | Notes                                                                                              |
|-----------------------------------|--------------|-------------|----------------------------------------------------------------------------------------------------|
| `constructor`                     | nonpayable   | n/a         | Owner only.                                                                                        |
| `registerCanonicalPair`           | nonpayable   | `onlyOwner` | `keccak256(abi.encodePacked(name, fee, tickSpacing))`. Reverts on duplicate name or empty name.    |
| `registerLocalPair`               | nonpayable   | `onlyOwner` | Validates token ordering (`token0 < token1`), non-zero token0/hook, canonical pair must exist.    |
| `canonicalPairCount`              | view         | n/a         |                                                                                                    |
| `getLocalPair`                    | view         | n/a         |                                                                                                    |
| `setAgentAuthorization`           | nonpayable   | `onlyOwner` | Field is exposed for future permissionless qualification flow; not consumed in v1.                 |

### Relayer.sol

One per non-primary chain. Holds LP positions and any pre-seeded inventory (WETH at launch per BRIDGE-DESIGN.md §3.2). Custodies USDC delivered via CCTP from Vault.

| Function                          | Mutability       | Auth                                                          | Notes                                                                                                                                                                                                  |
|-----------------------------------|------------------|---------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `constructor`                     | nonpayable       | n/a                                                           | Reverts on zero poolManager/mailbox.                                                                                                                                                                   |
| `handle` (IMessageRecipient)      | payable          | `msg.sender == mailbox` + `authorizedSenders[sender]`         | `whenNotPaused nonReentrant`. Decodes RebalanceMessage. Reverts `PoolNotRegistered` if pairId not pre-registered.                                                                                       |
| `_executeRebalance` (internal)    | nonpayable       | n/a                                                           | Computes `liquidityDelta` from deltas (placeholder; see line 171 `_liquidityFromDeltas` — flagged in INVARIANTS as needing TickMath upgrade pre-mainnet). Approves tokens. Calls `poolManager.unlock`. |
| `unlockCallback` (external)       | nonpayable       | `msg.sender == poolManager`                                   | Decodes `(PoolKey, ModifyLiquidityParams)`. Calls `poolManager.modifyLiquidity` then `_settleDeltas`.                                                                                                  |
| `_settleDeltas` (internal)        | nonpayable       | n/a                                                           | For each currency: `take()` if PoolManager owes us, else `transfer + settle()`.                                                                                                                        |
| `_approveIfNeeded` (internal)     | nonpayable       | n/a                                                           | Force-approves to exactly `amount` if current allowance < amount.                                                                                                                                       |
| `registerPool`                    | nonpayable       | `onlyOwner`                                                   |                                                                                                                                                                                                        |
| `setAuthorizedSender`             | nonpayable       | `onlyOwner`                                                   |                                                                                                                                                                                                        |
| `setMailbox`                      | nonpayable       | `onlyOwner`                                                   | Reverts on zero.                                                                                                                                                                                       |
| `pause` / `unpause`               | nonpayable       | `onlyOwner`                                                   |                                                                                                                                                                                                        |
| `rescueToken`                     | nonpayable       | `onlyOwner`                                                   | **Privileged** — owner can drain any ERC-20 in the Relayer. Mitigation: owner is multisig at mainnet.                                                                                                  |
| `receive()`                       | payable          | open                                                          |                                                                                                                                                                                                        |

### Treasury.sol

Thin pass-through.

| Function                          | Mutability   | Auth        | Notes                                                                                       |
|-----------------------------------|--------------|-------------|---------------------------------------------------------------------------------------------|
| `constructor`                     | nonpayable   | n/a         | Reverts on zero safe.                                                                       |
| `forwardToken`                    | nonpayable   | open        | `nonReentrant`. Anyone can sweep any ERC-20 balance to the Safe (intended — keeps fees moving). |
| `receiveAndForward`               | nonpayable   | open (pulls from caller) | `nonReentrant`. Caller pre-approves. Routes through Safe directly.                          |
| `forwardEth`                      | nonpayable   | open        | `nonReentrant`. Sends entire ETH balance to Safe via `.call`.                              |
| `setSafe`                         | nonpayable   | `onlyOwner` | Reverts on zero.                                                                            |
| `receive()`                       | payable      | open        |                                                                                             |

---

## External-protocol assumptions (trust roots)

These are not in scope, but the audit should verify the contracts use them **correctly**, not whether they themselves are safe:

1. **Uniswap V4 PoolManager** — `unlock` callback semantics, `modifyLiquidity` returns, `take/settle` ordering.
2. **Hyperlane Mailbox** — `dispatch` succeeds-or-reverts atomically with fee payment; `handle` is called with verified `(origin, sender, body)`. We trust Hyperlane's ISM at the receiving end.
3. **Circle CCTP TokenMessenger** — `depositForBurn` burns exactly `amount` USDC; destination mint happens via Circle's MessageTransmitter (off path for us).
4. **Pyth `getPriceNoOlderThan`** — reverts on stale; `Price.conf` is a confidence interval in the same units as `price`.
5. **Chainlink AggregatorV3** — `latestRoundData` returns answer + `updatedAt`; per-feed `decimals()`.
6. **OpenZeppelin v5** — ERC-4626 virtual offset, `Ownable` two-step not used (single-step accepted), `Pausable`, `ReentrancyGuard`, `SafeERC20.forceApprove`.

---

## Severity classification rubric

Map findings as:
- **Critical** — direct loss-of-funds path with no operator action required, or share-price manipulation by a single party.
- **High** — loss-of-funds path conditional on operator/agent compromise or specific external trigger; protocol-wide DOS.
- **Medium** — local DOS, accounting drift not exceeding fees, recoverable by admin tx.
- **Low** — gas waste, missing event, minor centralization, code clarity.
- **Informational** — style, gas-only optimization, suggestion.

See `audits/INVARIANTS.md` for the property-level invariants and `audits/THREAT-MODEL.md` for actor-level attack surfaces.
