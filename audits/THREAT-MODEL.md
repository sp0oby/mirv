# mirv — Threat Model

**Tag:** `v1.0.0-rc3` (R-1, R-2, R-3, R-5, R-10, R-12 landed; see status table for R-1..R-13 disposition).

This document enumerates the actors that can interact with the in-scope contracts (`audits/SCOPE.md`), their attack surfaces, and the mitigations in place. Severity uses the rubric in `SCOPE.md`.

For property-level claims and test coverage, see `audits/INVARIANTS.md`.

---

## Trust model summary

| Trust class      | Identity                                                  | What they can do                                               | Failure mode                                                |
|------------------|-----------------------------------------------------------|----------------------------------------------------------------|-------------------------------------------------------------|
| **Owner**        | Gnosis Safe (post-launch); EOA pre-mainnet                | All `onlyOwner` admin: chain registry, allocations, sender auth, pause, treasury setter, ETH withdraw | Misconfiguration → degraded operation. Key compromise → critical (see § Owner Multisig). |
| **Authorized agent** | Single EOA hot wallet (`AGENT_PRIVATE_KEY`)            | `dispatchRebalance`, `reportSisterDepth`, `harvest`, `updateCrossChainAssets`, `updateBaselineApy`, `recordRebalance`, `fulfillWithdraw` | Key compromise → high-severity share-price manipulation (see § Agent EOA). |
| **User**         | Anyone with the asset                                     | Deposit, withdraw, requestWithdraw, cancelWithdraw (after 24h)  | None — users have no privileged surface.                    |
| **Hyperlane**    | Mailbox + ISM operator                                    | Deliver `handle()` messages with attested (origin, sender, body) | Compromised ISM → high (see § Hyperlane).                  |
| **Circle CCTP**  | TokenMessenger + MessageTransmitter + Circle attester     | Burn USDC on source, mint on destination                       | Compromised attester → high.                                |
| **Pyth + Chainlink** | Off-chain oracle networks                             | Provide price feeds                                            | Bad price → bounded impact (see § Oracle).                  |
| **Sister hook**  | Authorized peer `MirrorHook` on another chain             | Push `currentDepth` into our `sisterDepths` via `handle()`     | Compromised → grief or false imbalance signal.              |
| **V4 PoolManager** | Uniswap V4 (immutable)                                  | Invoke hook callbacks + `unlockCallback` on Relayer            | Out of scope — protocol-level trust.                        |

---

## Actor 1 — User (depositor / withdrawer)

### Surface
`MirrorVault.deposit`, `MirrorVault.mint`, `MirrorVault.withdraw`, `MirrorVault.redeem`, `MirrorVault.requestWithdraw`, `MirrorVault.cancelWithdraw`, `MirrorHook.fund` (anyone can top up dispatch ETH), `Treasury.forwardToken/forwardEth/receiveAndForward`.

### What they can attempt
1. **Inflation / share-price manipulation via deposit timing**
   - Attack: front-run `updateCrossChainAssets` to deposit at a stale (low) `totalAssets`, then redeem after the update.
   - Mitigation: ERC-4626 virtual offset (OZ v5) blunts donation/inflation. `updateCrossChainAssets` is agent-controlled; the agent should write within the same tx as a price-sensitive operation or use a TWAP. Not currently enforced on-chain.
   - **Severity:** Medium — depends on agent cadence. Audit should consider whether `updateCrossChainAssets` should require a same-block guard or stricter freshness.

2. **Withdrawal-queue griefing**
   - Attack: spam `requestWithdraw` with tiny amounts to flood the request mapping.
   - Mitigation: each request transfers shares into custody — no free DOS vector; the attacker pays gas + locks their own shares for 24h.
   - **Severity:** Low.

3. **`cancelWithdraw` race with `fulfillWithdraw`**
   - Attack: user calls `cancelWithdraw` while agent simultaneously calls `fulfillWithdraw`.
   - Mitigation: `cancelWithdraw` reverts if `req.fulfilled` (and vice versa). The first-to-land wins; the loser reverts cleanly. No partial-state outcome.
   - **Severity:** None — designed-in race that resolves correctly.

4. **Bridging USDC to a non-existent recipient**
   - N/A — users don't control bridge destination; `chainConfigs[domain].cctpRecipient` is owner-set.

5. **Direct `Treasury.forwardEth/Token`** call to drain the contract.
   - By design — anyone can sweep Treasury balance, but it always goes to `safe`, not the caller. Not an attack.
   - **Severity:** None.

### Out-of-scope user concerns
- Front-running on the Hyperlane dispatch (MEV on cross-chain rebalance) — known design constraint per TODO line 96. Mitigation deferred to Phase 6 audit decision (RiskAgent pattern detection or withdrawal-side lockup).

---

## Actor 2 — Authorized Agent EOA

### Surface
- **Hook:** `dispatchRebalance`, `reportSisterDepth`.
- **Vault:** `harvest`, `updateCrossChainAssets`, `updateBaselineApy`, `recordRebalance`, `fulfillWithdraw`.
- **Factory:** `setAgentAuthorization` (reserved; unused in v1).

### Threat: single-key compromise
A compromised agent EOA is the **largest concentrated risk** in the protocol. With it, an attacker can:

| Action                                          | Impact                                                                                                                                 | Severity        |
|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|-----------------|
| `updateCrossChainAssets(MAX_UINT256)`           | Inflates `totalAssets()`. Attacker deposits 1 USDC, receives shares at the natural price; legit users now hold a fraction of what they thought. Then `updateCrossChainAssets(0)` brings reality back AFTER the attacker has fled. | **Critical**    |
| `harvest()` with manipulated cross-chain assets | Mints fee shares to treasury based on fake yield. Indirectly drains via the multisig. Only succeeds if `block.timestamp - lastHarvestAt ≥ 1 day`. | **High**        |
| `dispatchRebalance(maxFee)` repeatedly           | Drains hook ETH (Hyperlane fees). Bounded by hook ETH balance. Each dispatch is gated by `dispatchCooldown` per pool.                  | **Medium**      |
| `fulfillWithdraw(req)` to a colluding recipient | N/A — `fulfillWithdraw` pays the `receiver` field, which was set at `requestWithdraw` time by the real requester. Agent cannot redirect. | None (design)   |
| `updateBaselineApy(0)`                          | Lowers the bar for `harvest()` to succeed → more fee shares minted on every harvest.                                                   | **Medium**      |
| `reportSisterDepth(arbitrary)`                  | Triggers `_imbalanceExceeded` to fire on legit LP events → wastes dispatch fees. Tracked via `sisterDepths[domain][pair]`. Path now mostly superseded by `handle()` from sister hooks. | **Low**         |

### Mitigations in place

1. **Pausable on Vault + Hook** — owner multisig can freeze deposit/withdraw + LP dispatch in a single tx if an anomaly is detected. RiskAgent has a heuristic to trigger this.
2. **Authorized-agent set is owner-controlled** — `setAgentAuthorization` is `onlyOwner`. Compromise of the agent doesn't escalate to owner privileges.
3. **`harvest()` 1-day cooldown** — bounds rate of fee-share inflation under compromise.
4. **`fulfillWithdraw` recipient is fixed at request time** — agent cannot redirect payouts.
5. **`crossChainAssetsReported` has no upper bound** — flagged as the highest-leverage agent action. See § Recommendations.

### Recommendations

- **R-1 (high):** Bound `updateCrossChainAssets` to a max % delta vs. prior value within a per-block / per-N-block window. A legitimate agent reports incremental changes; a 10× jump is always suspicious. Alternative: require a 2-of-N multisig of agent EOAs.
- **R-2 (medium):** Emit + index `updateCrossChainAssets` with the previous value so off-chain monitors (Tenderly) can alert on large deltas.
- **R-3 (medium):** Consider gating `harvest` on `crossChainAssetsReported` being updated **no more than N blocks ago** — prevents a stale inflated value being exploited via a single tx.
- **R-4 (low):** Rotate `AGENT_PRIVATE_KEY` on a schedule. Key only held in the agent host (Railway), not in any human's wallet.

---

## Actor 3 — Owner Multisig

### Surface
All `onlyOwner` functions across all 5 contracts. Notable:
- `MirrorVault`: `addChain`, `removeChain`, `setAllocations`, `setTreasury`, `setAgentAuthorization`, `pause/unpause`.
- `MirrorHook`: `addSisterDomain`, `removeSisterDomain`, `setAgentAuthorization`, `setAuthorizedSender`, `setThresholds`, `setDispatchCooldown`, `setMaxMoveBps`, `pause/unpause`, `withdrawEth`.
- `MirrorFactory`: `registerCanonicalPair`, `registerLocalPair`, `setAgentAuthorization`.
- `Relayer`: `registerPool`, `setAuthorizedSender`, `setMailbox`, `pause/unpause`, **`rescueToken`** (drain any ERC-20 to owner).
- `Treasury`: `setSafe`.

### Threat: multisig compromise
A compromised multisig can:
1. Set `treasury` to attacker → next `harvest` mints fee shares to attacker.
2. Set arbitrary `authorizedAgents` and call `updateCrossChainAssets` themselves (combined Owner+Agent powers).
3. `rescueToken` from Relayer — drain canonical WETH inventory + any in-flight USDC custody.
4. Set `mailbox` on Relayer → spoof every future `handle()` call.

**Severity:** Critical. This is the trust root.

### Mitigations
- Owner is a Gnosis Safe at mainnet (Phase 9 deployment item — not yet enforced at testnet, where the EOA deployer is owner for ops convenience).
- No on-chain timelock on `setTreasury` or `setMailbox`. Audit should consider whether a 24-72h timelock on these specific setters is warranted (recommendation **R-5**).
- `setSafe` on Treasury is irreversible only forward — old `safe` is overwritten. Audit should consider event indexing for `safe` rotations.

### Recommendations
- **R-5 (high):** Timelock on `setTreasury` (Vault), `setMailbox` (Relayer), `setSafe` (Treasury). 24-48h minimum.
- **R-6 (medium):** Document the owner-multisig signing policy as part of the mainnet runbook — quorum, signer rotation, address segregation.
- **R-7 (low):** Consider a separate "guardian" role for `pause()` only, so emergency response can happen with a smaller quorum than treasury-changing actions.

---

## Actor 4 — Hyperlane (mailbox + ISM)

### Surface
- Hyperlane mailbox calls `handle()` on `MirrorHook` and `Relayer` after delivering attested messages.
- Hyperlane mailbox is called by `MirrorHook._dispatchOne` to dispatch outbound messages.

### Threat: compromised ISM
If a malicious or compromised Interchain Security Module forges a `handle()` call from an arbitrary origin/sender, mirv's authentication is:

1. `msg.sender == mailbox` ✓ — mailbox is immutable on `MirrorHook` (`mailbox` field, l. 90). For `Relayer`, it's mutable via `setMailbox` (owner-only, see § Owner).
2. `authorizedSenders[sender] == true` — only sister-hook addresses on the protocol's deploy plan should be in this set.

**Compromise paths:**

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| Hyperlane ISM forges a message from an authorized sender | Sister depth tracking lies (`MirrorHook.handle`); LP position adjusted on wrong inputs (`Relayer.handle`) | Authorized-sender allowlist (owner-set) is the second gate. Bad ISM alone is not enough. |
| Hyperlane ISM forges from an unauthorized sender | Reverts on `NotAuthorizedSender` | ✓ |
| Hyperlane mailbox is upgraded under us (Hyperlane governance) | New mailbox might accept ISMs with different security assumptions | Mailbox is immutable on Hook; on Relayer it's owner-mutable. Audit should confirm upgrade procedure is signaled by Hyperlane governance and that ops respond. |
| Hyperlane dispatch is censored | Cross-chain messages stop arriving; sister depths go stale → no imbalance signal → reduced rebalancing | Acceptable degradation. Pause + manual intervention. |
| Hyperlane mailbox reverts in `quoteDispatch` / `dispatch` | `_dispatchOne` reverts → caught by outer try/catch → `DispatchFailed` event → LP-add tx still succeeds | DOS-safe wrap (v5 hardening) closes this. |

### Cross-pair message poisoning
A sister `MirrorHook` for a different canonical pair (or a malicious sister deployed in the future) could send a `handle()` payload with a foreign `pairId`. The defensive check at `MirrorHook.handle` l. 290 silently drops it — emits an event but doesn't revert. This prevents griefing the mailbox queue (a revert would cause the message to be retried indefinitely on some Hyperlane configurations).

**Severity assessment:** Authentication-by-allowlist is sound assuming `setAuthorizedSender` is administered correctly. The mutability of Relayer's mailbox is a minor centralization vector — flagged as **R-8** below.

### Recommendations
- **R-8 (medium):** Consider making `Relayer.mailbox` immutable like `MirrorHook.mailbox`. The flexibility costs trust; if Hyperlane upgrades its mailbox the Relayer can be redeployed.
- **R-9 (low):** Document the `setAuthorizedSender` procedure: every new sister deploy must (a) deploy the hook with the right canonical pair id, (b) be added to authorizedSenders on every reachable peer, (c) be added to Vault's chain registry.

---

## Actor 5 — Circle CCTP (TokenMessenger + attester)

### Surface
- `MirrorVault._splitAndBridge` → `cctpMessenger.depositForBurn(amount, cctpDomain, cctpRecipient, USDC)`.
- Destination side (out of scope for this audit) → MessageTransmitter mints to `cctpRecipient`.

### Threat: compromised Circle attester
If Circle's attester signs a forged message, USDC can be minted on destination chains to attacker-controlled addresses. This is a Circle-protocol-level concern — **out of scope**.

### Threats relevant to in-scope code
1. **Approval residue (I-11).** If `depositForBurn` ever fails to consume the full approval, residual allowance sits in the vault. Mitigation: `forceApprove(exact)` before each call + explicit `forceApprove(0)` in try/catch revert path.
2. **Wrong `cctpRecipient`.** Owner-set in `addChain` / `setAllocations`. Misconfiguration sends USDC to a black hole.
   - **Severity:** High (operator error). Mitigation: deploy-script verification + post-deploy `cast call` against `chainConfigs[domain].cctpRecipient`.
3. **`bytes32(address)` left-padding (memory record).** The codebase narrowly avoided silently right-padding CCTP `mintRecipient` values via `cast --to-bytes32`. The deploy script uses manual left-pad. Verified at testnet (Phase D smoke).
4. **CCTP route paused on destination.** Wrapped in try/catch (l. 448-454) — emits `CctpBridgeSkipped`, USDC stays in vault, agent reconciles.

### Recommendations
- **R-10 (low):** Add a `cctpRecipient != bytes32(0)` check in `addChain` to fail-fast on missing recipient.

---

## Actor 6 — Oracle (Pyth + Chainlink)

### Surface
`MirrorHook._getOraclePrice` (l. 426) — Pyth first, Chainlink fallback.

### Threats
1. **Pyth feed manipulated / wide confidence interval.**
   - Mitigation: `PYTH_MAX_CONF_BPS = 100` (1%) gate. Wide-conf prices fall through to Chainlink.
   - **Severity:** Low (mitigated).
2. **Chainlink feed stale > 1h.**
   - Mitigation: explicit staleness check at l. 460. Reverts `StaleOraclePrice` — Hook's `_handleEvent` propagates the revert, blocking dispatch.
   - **Severity:** Acceptable — failing closed is safer than dispatching on stale price.
3. **Chainlink feed returns `answer ≤ 0`.**
   - Mitigation: explicit check at l. 461.
4. **Decimal mismatch between Pyth and Chainlink.**
   - Pyth: `expo` field handles arbitrary exponents (l. 438-441).
   - Chainlink: `decimals()` queried at runtime; scaled to 18 (l. 463-464).
5. **Oracle compromise on a single chain.**
   - Same-pair sister chains still report their own depths. Imbalance triggers on chain-specific oracle errors are bounded by `imbalanceThresholdBps` (default 3%) — small drift won't cascade.

### Recommendations
- **R-11 (low):** Add an explicit max-price-deviation check between Pyth and Chainlink (when both are fresh). Currently the code picks Pyth and skips Chainlink without comparing. Cross-oracle sanity check is a cheap robustness boost.
- **R-12 (informational):** The `chainlinkFeed.decimals()` call is in the hot path. Cache it as immutable in the constructor (also slightly reduces gas).

---

## Actor 7 — Sister `MirrorHook` (authorized peer)

### Surface
- `MirrorHook.handle` — receives `(origin, sender, body)` from Hyperlane mailbox; sender must be in `authorizedSenders`.

### Threat: compromised sister hook (key on another chain)
If a sister chain's owner key is compromised, the attacker can:
1. Call `dispatchRebalance` on the sister to dispatch arbitrary `RebalanceMessage`s into our `handle()`.
   - Defensive check at l. 290: if `rm.pairId != canonicalPairId`, silently drop. So they can only push values for **our** canonical pair.
   - For our pair: they can write `sisterDepths[origin][canonicalPairId] = arbitraryValue` (l. 298). This triggers `_imbalanceExceeded` on local LP events.
   - Impact: false imbalance signal → unnecessary cross-chain dispatches. Bounded by `dispatchCooldown` (default 60s) and outgoing hook ETH balance.
   - **Severity:** Medium. They cannot move funds; they can waste them.
2. Compromised sister Relayer (if peers' relayers are added to `authorizedSenders`): same — they could submit `handle()` payloads to our hook with arbitrary `currentDepth`.

### Mitigations
- Allowlist is per-sender on each chain. A compromise on chain X requires the chain X key — doesn't escalate.
- Pause-on-anomaly: RiskAgent + multisig can pause both Hook and Vault to halt response to bad sister inputs.
- `sisterDepths` are inputs to a heuristic, not to fund movements directly. The actual LP-modifying call (`Relayer.handle` → `unlockCallback`) requires its own attestation chain.

### Recommendation
- **R-13 (low):** Cap the maximum `currentDepth` value a sister can write — e.g. 10× the local depth — to bound the imbalance signal noise from a compromised sister.

---

## Actor 8 — V4 PoolManager

Out of scope. The protocol relies on V4's standard semantics: callback ordering, `unlock` access control, `take/settle` correctness. Audited by Uniswap and OZ uniswap-hooks helper.

The one interaction worth noting:
- `Relayer.unlockCallback` accepts any caller that satisfies `msg.sender == poolManager`. The PoolManager is `immutable` on `Relayer` (l. 61), so this is safe.

---

## Composition risks (multi-actor scenarios)

| Scenario                                                | Severity | Notes                                                                                                                              |
|---------------------------------------------------------|----------|------------------------------------------------------------------------------------------------------------------------------------|
| Agent EOA compromise + owner offline                    | Critical | Compromised agent can inflate `crossChainAssetsReported` and harvest within 1 day. Owner can't pause if offline. Mitigation: 24/7 on-call. |
| Hyperlane ISM compromise + sister-hook key compromise   | High     | Attacker controls both ends of `handle()`. Can write arbitrary `sisterDepths`. Bounded by `dispatchCooldown` and pause.            |
| CCTP attester compromise                                | Critical | USDC stolen on destination. Out-of-scope but worth a contingency runbook (e.g. pause Vault deposits immediately on Circle alert). |
| Oracle compromise (both Pyth + Chainlink for same asset)| High     | Bad price → bad TVL → bad imbalance signal → wasted dispatches. Bounded by `dispatchCooldown` + per-event cooldown. No fund movement. |
| Multisig + agent both compromised                       | Critical | Full protocol control. Treat as catastrophic; design assumes these are independent.                                                |

---

## Audit recommendations summary

### Status at rc2

| Rec  | Title                                                      | Status      | Notes                                                                                       |
|------|------------------------------------------------------------|-------------|---------------------------------------------------------------------------------------------|
| R-1  | Bound `updateCrossChainAssets` delta                       | **LANDED**  | `maxCrossChainAssetsDeltaBps` default 2500 (25%). Owner-tunable. First non-zero set bypasses the gate so deploy-time bootstrapping is unconstrained. |
| R-2  | Emit prior-value in `CrossChainAssetsUpdated`              | **LANDED**  | Event signature now `(uint256 oldValue, uint256 newValue)`.                                |
| R-3  | Gate `harvest` on freshness of `crossChainAssetsReported`  | **LANDED**  | `lastCrossChainAssetsUpdate` written on every update; `harvest()` reverts `CrossChainAssetsStale` if older than `crossChainAssetsMaxStaleness` (default 1 hour, owner-tunable). Skipped when no update has ever happened (pre-launch vaults). |
| R-4  | Agent key rotation policy                                  | open / ops  | Runbook item, not on-chain.                                                                 |
| R-5  | Timelock on `setTreasury` / `setMailbox` / `setSafe`       | **LANDED**  | `propose`/`execute`/`cancel` triplet on each. 24h delay. Anyone may execute after delay; only owner may propose / cancel. |
| R-6  | Document multisig signing policy                           | open / ops  | Mainnet runbook item.                                                                       |
| R-7  | Separate guardian role for pause-only                      | open        | Audit-decision; default Ownable kept for simplicity.                                       |
| R-8  | Make `Relayer.mailbox` immutable                           | mitigated   | R-5 timelock closes the immediate-flip risk; immutability still cleaner but not blocking. |
| R-9  | Document `setAuthorizedSender` admin sequence              | open / ops  |                                                                                             |
| R-10 | `cctpRecipient != 0` check in `addChain`                   | **LANDED**  | `addChain` reverts `CctpRecipientRequired` when `cctpDomain != 0` but `cctpRecipient == bytes32(0)`. Zero recipient still allowed when `cctpDomain == 0` (the "stay local" pattern). |
| R-11 | Cross-oracle sanity check (Pyth vs Chainlink deviation)    | open        | Audit-decision; current fallback semantics may be sufficient.                              |
| R-12 | Cache `chainlinkFeed.decimals()` in constructor            | **LANDED**  | New `chainlinkFeedDecimals` immutable set in `MirrorHook` constructor. Saves one external call per `_getOraclePrice()` invocation. Asserted equal to the live feed value on Base mainnet fork (`test_chainlinkFeedDecimalsCached`). |
| R-13 | Cap sister-reported `currentDepth` value                   | open        | Audit-decision; current bound is on the consumer side (cooldown + threshold).               |

### Known open items (carried forward)
- `Relayer._liquidityFromDeltas` is a placeholder; production should use TickMath + LiquidityAmounts (SCOPE.md note).
- `withdrawEth` on Base Sepolia v1-v4 — investigated 2026-05-18: v5 simulates cleanly on both chains (`cast estimate` succeeds; new fork-test `test_withdrawEth` locks in working behavior). The original observation was on the abandoned v1-v4 hooks and could not be reproduced. Phase 5.F line 408 resolved.
