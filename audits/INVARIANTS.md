# mirv — Invariants

**Tag:** `v1.0.0-rc3` (R-1, R-2, R-3, R-5, R-10, R-12 landed; see I-15..I-18 below).

Properties that must hold across every reachable post-transaction state. Each entry: the invariant statement, where it's enforced, why a violation matters, and how it's tested today.

The Foundry invariant suite (`test/invariant/VaultInvariants.t.sol`) covers the four Vault-level invariants today (4/4 passing via `VaultHandler` fuzzer). Hook + Relayer + Factory + cross-chain invariants are auditor-verifiable from source + tests but not yet asserted by an invariant runner — flagged below as **\[runner-gap\]**.

---

## I-1. Vault solvency on local-USDC paths

> `IERC20(asset()).balanceOf(vault) ≥ ∑ assets owed for fulfillable redemptions at current share price.`

**Why:** A `_withdraw` or `fulfillWithdraw` that bumps into `InsufficientLocalBalance` is the correct revert path; silent under-payment would mean someone got fewer assets than their shares are worth.

**Enforced by:** `MirrorVault._withdraw` (l. 216) + `MirrorVault.fulfillWithdraw` (l. 312) — both pre-check `balanceOf(this) ≥ assetsOwed` and revert `InsufficientLocalBalance` if not.

**Tested by:**
- `test/MirrorVault.t.sol` — `test_withdrawRevertsOnInsufficientLocalBalance`
- `test/invariant/VaultInvariants.t.sol::invariant_totalAssetsContainsLocalBalance`

---

## I-2. `totalAssets` decomposition

> `totalAssets() == IERC20(asset()).balanceOf(vault) + crossChainAssetsReported`

**Why:** The share price `convertToAssets` depends on this sum. If `totalAssets()` ever drifts from this definition (e.g. an off-by-one cached version), the share price is wrong and the next deposit/redeem mis-mints.

**Enforced by:** `MirrorVault.totalAssets()` (l. 192) — single expression.

**Tested by:** `invariant_totalAssetsContainsLocalBalance` (returns `localBalance ≤ totalAssets` for the trivial direction; equality follows from the function body, but a stronger invariant `totalAssets == localBalance + crossChainReported` could be added).

---

## I-3. Performance-fee accounting

> After `harvest()` succeeds, `principalTracked` increases by exactly the asset value of the fee shares minted to the treasury, AND `extraYield` was computed as `totalAssets() − principalTracked − baselineYieldAccrued` at fee-time.

**Why:** Performance fees are only owed on yield ABOVE the single-chain baseline. If `extraYield` is computed against stale `baselineYieldAccrued` (e.g. `_accrueBaseline` skipped), users effectively pay fee on baseline yield.

**Enforced by:** `MirrorVault.harvest` (l. 229) — calls `_accrueBaseline()` BEFORE computing `extraYield`; `feeAssets = extraYield * 1500 / 10000`; then `principalTracked += feeAssets`.

**Tested by:** `test/MirrorVault.t.sol` — `test_harvestExtraYield` + `test_harvestRevertsBeforeInterval` + `test_harvestRevertsNoExtraYield`.

---

## I-4. Share-supply consistency under withdrawal queue

> `totalSupply == sum(externally-held shares) + sum(custodial shares for unfulfilled requests)`. No share is ever burned without an offsetting asset payout, and no share is ever transferred to vault custody without a recorded `WithdrawRequest`.

**Why:** `requestWithdraw` parks shares in vault custody (not burned). `fulfillWithdraw` burns them and pays out. `cancelWithdraw` transfers them back. Any divergence means either share inflation (someone got a free share) or share leak (custodial supply > recorded requests).

**Enforced by:** `MirrorVault.requestWithdraw` (l. 284 — `_transfer(msg.sender, address(this), shares)`) + `MirrorVault.fulfillWithdraw` (l. 315 — `_burn(address(this), req.shares)`) + `MirrorVault.cancelWithdraw` (l. 341 — `_transfer(address(this), req.requester, req.shares)`). Status flags on `WithdrawRequest` (`fulfilled`, `cancelled`) prevent double-spend of any single request.

**Tested by:**
- `test/MirrorVault.t.sol` — `test_requestWithdraw_custody`, `test_fulfillWithdraw_burnsAndPays`, `test_cancelWithdraw_after24h`, `test_fulfillRevertsAfterCancel`, `test_cancelRevertsAfterFulfill`.
- `invariant_sharesBackedByAssets` (looser version asserts `totalSupply * sharePrice ≤ totalAssets`).

---

## I-5. Allocation sum

> `∑(chainConfigs[d].allocationBps for d in enabledDomains) == 10_000`, at all times after the first successful `setAllocations` call.

**Why:** Allocations drive deposit splitting. If they don't sum to 10000, a deposit either leaves USDC stranded in the vault (sum < 10000 — accounting OK but the protocol's mirroring intent fails) or attempts to bridge more than the deposit amount (sum > 10000 — `forceApprove(alloc)` succeeds but `depositForBurn` reverts on insufficient balance partway through, leaving partial bridges + dangling approval).

**Enforced by:** `MirrorVault.setAllocations` (l. 410-415) — explicit sum check after writes.

**\[runner-gap\]** — `addChain` and `removeChain` mutate the enabled set without re-validating the sum. Caller must follow with `setAllocations`. The invariant only holds **between** admin batches. Audit should confirm that no other path can leave the sum != 10000.

**Tested by:** `test/MirrorVault.t.sol` — `test_setAllocations_revertsOnMismatch`, `test_addChain_allowsZeroAlloc`, `test_removeChain_revertsIfAllocNonZero`.

---

## I-6. Canonical pair identity (cross-chain)

> For any logical pair P, every chain's deployed `MirrorHook.canonicalPairId()` returns the same `bytes32` as `MirrorFactory.canonicalIdByName[name(P)]`.

**Why:** Cross-chain `handle()` messages tag themselves with `pairId`. The receiving hook compares `rm.pairId == canonicalPairId` (l. 290) and silently drops mismatches. Without this invariant, sister depth tracking decouples — sister A reports for pair X, sister B's hook is keyed against pair Y, and their depths never reconcile.

**Enforced by:**
- `MirrorHook` constructor sets `canonicalPairId` immutable from a deploy-time argument.
- `MirrorFactory.registerCanonicalPair` is the source-of-truth issuer.
- `MineHookAddress.s.sol` bakes the canonical id into the CREATE2 init code so the mined hook address is bound to that pair.

**Defensive check:** `MirrorHook.handle` line 290 — wrong-pair messages are emitted-and-returned (not reverted) so a malicious sister can't grief the mailbox queue.

**\[runner-gap\]** No on-chain assertion that `MirrorFactory.registerLocalPair(canonicalId, domain, ..., hook)` actually deployed `hook` with that same `canonicalId`. This is a deploy-script discipline invariant, not a contract invariant. Audit should confirm the deploy sequence enforces it (it does, via the salt-mining step).

**Tested by:** `test/MirrorFactory.t.sol` — `test_registerCanonicalPair`, `test_registerLocalPair_revertsOnUnknownCanonical`.

---

## I-7. Dispatch cooldown monotonicity

> For any pool P, `lastDispatchTime[P]` is monotonically non-decreasing across all transactions.

**Why:** A regression in `lastDispatchTime` would re-open the cooldown gate and allow a dispatch flood. The cooldown is the only on-chain rate limit on Hyperlane fees the hook spends.

**Enforced by:** `MirrorHook._handleEvent` (l. 344) — `lastDispatchTime[pid] = block.timestamp` is the only write. `block.timestamp` is itself monotonic (modulo testnet reorgs, which we don't optimize for).

**CEI ordering:** The write happens BEFORE `_dispatchToAllSisters` (l. 345) so even a malicious mailbox reentry can't observe a pre-update value. This was the Slither finding fixed in v5 hardening (`94fbdaa`).

**\[runner-gap\]** No fuzz test asserts monotonicity across arbitrary call sequences. Auditor verification by inspection should suffice given the single write site.

---

## I-8. Hook permission bits match deployed address

> `getHookPermissions()` returned struct, when encoded as the V4 permission bitmap, equals the low-order bits of `address(this)`.

**Why:** V4 PoolManager checks the hook address bits at every callback. A mismatch means callbacks silently aren't invoked — the hook would be deployed but inert.

**Enforced by:** `MineHookAddress.s.sol` mines the salt; `Deploy.s.sol` deploys via CREATE2 with that salt. No on-chain runtime check (V4 enforces this implicitly by skipping callbacks).

**Tested by:**
- `test/integration/HookCallback.t.sol::test_afterAddLiquidity_fires_on_real_pool` etc. — if the address bits are wrong, V4 wouldn't invoke `_afterAddLiquidity` and the test asserting on the emitted event would fail.
- Phase 4 cast verification on Anvil: hook permission bits cross-checked against deployed addresses (`0xD42…C540`, `0xDbE…8540`, `0xF42…0540`).

---

## I-9. Sister-message authentication

> `MirrorHook.handle` and `Relayer.handle` only progress past sender checks if `msg.sender == mailbox && authorizedSenders[sender] == true`.

**Why:** Either guard alone is insufficient. `msg.sender == mailbox` ensures Hyperlane attestation; `authorizedSenders[sender]` ensures the originating contract is a known sister. Without the second guard, ANY contract on a registered Hyperlane domain could submit messages and (in Vault's case) trigger pool LP changes via Relayer's `unlockCallback`.

**Enforced by:**
- `MirrorHook.handle` l. 281-282
- `Relayer.handle` l. 91-92
- `setAuthorizedSender` is `onlyOwner` on both contracts.

**Tested by:**
- `test/MirrorHook.t.sol::test_handleRevertsIfNotMailbox`, `test_handleRevertsIfUnauthorizedSender`
- `test/Relayer.t.sol::test_handleRevertsIfNotMailbox`, `test_handleRevertsIfUnauthorizedSender`

---

## I-10. ETH custody on hooks

> A hook's ETH balance only decreases via `mailbox.dispatch(value: fee)` or `withdrawEth(amount)`. No path lets external callers drain hook ETH directly.

**Why:** Hooks hold ETH for Hyperlane fees. If an external caller could trigger an arbitrary-target `.call{value:}` from the hook, the operator loses both their dispatch budget AND any imbalance signal that ETH was supposed to fund.

**Enforced by:**
- `_dispatchOne` (l. 372) — `mailbox.dispatch{value: fee}` is the only `.call{value}` site reachable via swap/LP callbacks. `mailbox` is immutable.
- `withdrawEth` (l. 534) — `onlyOwner` + `nonReentrant`. Destination is `owner()` (current Ownable owner), not arbitrary.
- `fund` (l. 531) + `receive()` (l. 538) — payable inbound only.

**\[runner-gap\]** No invariant asserts "no `.call{value}` to a non-mailbox / non-owner address from the hook." Single-pass source review confirms it.

**Known open question:** `withdrawEth` reverts on Base Sepolia under some conditions (Phase 5.F line 408 in TODO). Must be characterized before mainnet — could indicate a missing case in this invariant.

---

## I-11. CCTP approval residue

> `IERC20(USDC).allowance(vault, cctpMessenger) == 0` at the end of every `_splitAndBridge` invocation.

**Why:** `forceApprove(alloc)` sets the allowance to exactly `alloc`. The happy path consumes it inside `depositForBurn`. The failure path explicitly revokes via `forceApprove(0)`. If we ever drift to leaving a non-zero residual, a later malicious / compromised `cctpMessenger` could drain the residual on a subsequent call.

**Enforced by:** `_splitAndBridge` (l. 442 / l. 452) — exact approve before each call, explicit revoke on catch.

**\[runner-gap\]** Foundry invariant runner doesn't check ERC-20 allowances. Auditor verification by code-path enumeration. Trust assumption: Circle CCTP doesn't leave residuals after a successful `depositForBurn` (it doesn't — it transfers `amount` exactly).

---

## I-12. No infinite approvals

> All ERC-20 `approve` / `forceApprove` calls in the in-scope contracts use exact, bounded amounts.

**Enforced by:**
- `MirrorVault._splitAndBridge` — `forceApprove(messenger, alloc)`.
- `Relayer._approveIfNeeded` — `forceApprove(spender, amount)` only when `current < amount`.
- No other approval sites.

**Tested by:** Source-level grep — no `type(uint256).max` literals near `approve`. (Security checklist item ✓ in TODO line 92.)

---

## I-13. CEI on all external dispatches

> Every external call from in-scope contracts is preceded by all state updates that the caller's post-conditions depend on.

**Enforced by:**
- `MirrorHook._handleEvent` — `lastDispatchTime` set BEFORE `_dispatchToAllSisters` (l. 344-345).
- `MirrorVault._deposit` — `super._deposit` (mints shares) BEFORE `_splitAndBridge` (l. 203, 206).
- `MirrorVault.harvest` — fee shares minted + `principalTracked` updated BEFORE no further external calls.
- `MirrorVault.fulfillWithdraw` — `_burn` + `principalTracked` + accrual updated BEFORE `safeTransfer` (which itself is CEI-safe in OZ's `SafeERC20`).

**Tested by:** Slither's `reentrancy-eth` and `reentrancy-no-eth` detectors — closed in v5 hardening pass (`94fbdaa`).

---

## I-14. Hyperlane fee solvency

> Before every `_dispatchOne` call, `address(this).balance ≥ mailbox.quoteDispatch(...)`. Otherwise the function reverts `InsufficientEthForDispatch` (and the outer `_dispatchToAllSisters` catches it via try/catch).

**Why:** A revert at dispatch time WITHOUT the outer try/catch would have DOS'd the entire LP-add tx. The try/catch + per-route error is what the v5 hardening pass closed.

**Enforced by:** `MirrorHook._dispatchOne` l. 371; outer protection l. 358-361.

**Tested by:** `test/MirrorHook.t.sol` covers the dispatch happy path; the DOS-safe wrap is testable by setting hook balance to 0 and confirming `DispatchFailed` event + no revert at the call site. (Audit may want an explicit test added here.)

---

## I-15. `updateCrossChainAssets` bounded delta (R-1)

> After the first non-zero report, every subsequent `updateCrossChainAssets` call satisfies `|newValue - prior| * MAX_BPS ≤ prior * maxCrossChainAssetsDeltaBps`.

**Why:** Closes the highest-leverage agent-EOA-compromise path. A compromised agent can no longer inflate `totalAssets` by more than `maxCrossChainAssetsDeltaBps` (default 25%) in a single tx.

**Enforced by:** `MirrorVault.updateCrossChainAssets` (l. 280-292) — explicit delta check, reverts `CrossChainAssetsDeltaTooLarge`.

**Boundary conditions:**
- `prior == 0` (initial bootstrapping) is allowed unbounded so the operator can set the first value at deploy.
- Owner can adjust `maxCrossChainAssetsDeltaBps` up to `MAX_BPS` (100%) via `setMaxCrossChainAssetsDeltaBps` if a planned migration requires a one-off large change.

**Tested by:** `MirrorVault.t.sol` — `test_updateCrossChainAssetsBypassWhenPriorZero`, `test_updateCrossChainAssetsEnforcesMaxDelta`, `test_setMaxCrossChainAssetsDeltaBpsOwnerOnly`, `test_setMaxCrossChainAssetsDeltaBpsBounded`, `test_setMaxCrossChainAssetsDeltaBpsTo10000Disables`.

---

## I-17. `harvest` requires fresh cross-chain report (R-3)

> Every successful `harvest()` call satisfies either (a) `lastCrossChainAssetsUpdate == 0` (no report has ever happened — pre-launch state), OR (b) `block.timestamp - lastCrossChainAssetsUpdate ≤ crossChainAssetsMaxStaleness`.

**Why:** Closes the "agent reports inflated value once, then goes silent, attacker waits a day, then calls harvest on the stale inflated number" path. Pairs with I-15 — together they bound a compromised agent to a small inflation factor AND require continuous reporting for any harvest to land.

**Enforced by:** `MirrorVault.harvest` (l. 265-268) — explicit staleness check, reverts `CrossChainAssetsStale`. `MirrorVault.updateCrossChainAssets` writes `lastCrossChainAssetsUpdate = block.timestamp` on every successful update (l. 296).

**Boundary conditions:**
- `lastCrossChainAssetsUpdate == 0` (never reported) bypasses the gate so vaults that haven't enabled any cross-chain routes can still harvest baseline-only yield (or, more commonly, revert with `NoExtraYield` because there's nothing to harvest).
- Owner can adjust `crossChainAssetsMaxStaleness` via `setCrossChainAssetsMaxStaleness`. Default 1 hour.

**Tested by:** `MirrorVault.t.sol` — `test_harvestRevertsOnStaleCrossChainReport`, `test_harvestPassesWhenReportFresh`, `test_harvestStalenessSkippedIfNeverReported`, `test_setCrossChainAssetsMaxStaleness`, `test_harvestPassesWhenOwnerWidensStaleness`.

---

## I-18. CCTP recipient required on active route (R-10)

> Every enabled chain config with `cctpDomain != 0` has `cctpRecipient != bytes32(0)`.

**Why:** `cctpDomain == 0` is the "stay local, no CCTP" sentinel; in that case `cctpRecipient` is ignored. But if `cctpDomain != 0` and `cctpRecipient == bytes32(0)`, the first `_splitAndBridge` call would send USDC to address(0) on the destination chain — a black-hole burn that the operator couldn't recover.

**Enforced by:** `MirrorVault.addChain` (l. 412-414) — reverts `CctpRecipientRequired` on the dangerous combination.

**\[runner-gap\]** No on-chain enforcement on `setAllocations` — if an operator zeros a recipient via a different admin path in the future, this invariant could be violated. Today no such path exists; the invariant is composition-safe by the current admin surface.

**Tested by:** `MirrorVault.t.sol` — `test_addChainRevertsOnZeroCctpRecipientWithActiveDomain`, `test_addChainAllowsZeroCctpRecipientWhenDomainIsZero`.

---

## I-16. Timelocked rotation of trust-root addresses (R-5)

> `treasury` (Vault), `mailbox` (Relayer), and `safe` (Treasury) cannot change without (a) an owner-issued `propose*` call, AND (b) at least `*_TIMELOCK_DELAY` (24h) of wall-clock time, AND (c) the absence of an intervening `cancelPending*` call by the owner.

**Why:** A compromised owner key can no longer instantly redirect performance fees, spoof message authentication, or change the fee destination. The 24h window gives the watching multisig + off-chain monitor time to call `cancelPending*` and `pause`.

**Enforced by:**
- `MirrorVault.proposeTreasury` / `executeTreasury` / `cancelPendingTreasury` (l. 350-385).
- `Relayer.proposeMailbox` / `executeMailbox` / `cancelPendingMailbox` (l. 207-235).
- `Treasury.proposeSafe` / `executeSafe` / `cancelPendingSafe` (l. 86-114).

**Execute-permissionless design:** `execute*` is callable by anyone after the delay (not `onlyOwner`). The propose-step already costs an owner multisig tx, so requiring a second owner tx to execute is friction without security gain. The cancel-step IS `onlyOwner`. Overwriting a pending proposal resets the timer (tested via `test_proposeTreasuryOverwritesPriorProposal`).

**Tested by:**
- `MirrorVault.t.sol`: `test_proposeAndExecuteTreasury`, `test_proposeTreasuryZeroAddressReverts`, `test_proposeTreasuryOnlyOwner`, `test_executeTreasuryRevertsIfNoPending`, `test_cancelPendingTreasury`, `test_cancelPendingTreasuryRevertsIfNothingPending`, `test_proposeTreasuryOverwritesPriorProposal`.
- `Relayer.t.sol`: parallel suite (`test_proposeAndExecuteMailbox`, etc.).
- `Treasury.t.sol`: parallel suite (`test_proposeAndExecuteSafe`, etc.).

---

## Properties out of scope as on-chain invariants (operator-side)

These hold by procedure, not code. Auditor should flag if any could be promoted to an on-chain check:

- **A.** Allocation matches deployed inventory — i.e. `crossChainAssetsReported` reflects real cross-chain LP positions. Trusted to the agent EOA + RiskAgent oversight.
- **B.** `removeChain` is only called after all in-flight USDC for that domain has settled. Off-chain check.
- **C.** Pyth + Chainlink feeds are configured for the same underlying asset (ETH/USD) on each deployment. Deploy-script verification.
- **D.** Treasury's `safe` address points to an actual multisig at mainnet. Deploy-script + post-deploy verification.
- **E.** Authorized agent EOA private key is segregated from any owner / multisig signer. Operational discipline.

---

## Invariant test coverage matrix (current)

| Invariant | Status | Foundry test |
|-----------|--------|--------------|
| I-1 solvency on local USDC paths | ✅ | `MirrorVault.t.sol`, `invariant_totalAssetsContainsLocalBalance` |
| I-2 totalAssets decomposition | ✅ | `invariant_totalAssetsContainsLocalBalance` |
| I-3 performance-fee accounting | ✅ | `MirrorVault.t.sol::test_harvestExtraYield` |
| I-4 share-supply consistency | ✅ | withdrawal-queue suite + `invariant_sharesBackedByAssets` |
| I-5 allocation sum | ✅ between admin batches | `MirrorVault.t.sol::test_setAllocations_*` |
| I-6 canonical pair identity | partial | `MirrorFactory.t.sol`; cross-chain proven at deploy time |
| I-7 cooldown monotonicity | partial — no fuzz | inspection |
| I-8 hook permission bits | ✅ | Implicit via `HookCallback.t.sol` |
| I-9 sister-message auth | ✅ | `MirrorHook.t.sol`, `Relayer.t.sol` |
| I-10 ETH custody | partial — no fuzz | inspection + `withdrawEth` open question |
| I-11 CCTP approval residue | inspection | Verified by code path |
| I-12 no infinite approvals | ✅ | Source-level invariant |
| I-13 CEI on dispatches | ✅ | Slither closed |
| I-14 Hyperlane fee solvency | partial | inspection — DOS-safe wrap could use explicit test |
| I-15 updateCrossChainAssets bounded delta (R-1) | ✅ | `MirrorVault.t.sol` — 5 unit tests |
| I-16 Timelocked trust-root rotation (R-5) | ✅ | Vault/Relayer/Treasury — 7+5+5 unit tests |
| I-17 harvest requires fresh cross-chain report (R-3) | ✅ | `MirrorVault.t.sol` — 5 unit tests |
| I-18 CCTP recipient required on active route (R-10) | ✅ | `MirrorVault.t.sol` — 2 unit tests |

Items marked **partial** or **inspection** are the highest-value places to add new invariant fuzz tests during audit prep.
