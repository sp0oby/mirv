# mirv — Operations Runbook

**Audience:** mirv operators (treasury multisig signers, on-call engineers, monitoring services).
**Scope:** off-chain procedures that complement the in-scope contracts. Closes recommendations **R-4**, **R-6**, **R-9** from `THREAT-MODEL.md`.
**Tag:** maintained alongside `v1.0.0-rc3+` contract releases.

---

## 1. Address inventory

Every operator should know these addresses cold:

| Role                          | Production identity                                    | Recovery path on compromise                            |
|-------------------------------|--------------------------------------------------------|--------------------------------------------------------|
| **Owner multisig**            | Gnosis Safe — `TREASURY_BASE` at mainnet              | Multisig signer quorum rotates lost signer            |
| **Guardian** (R-7)            | Single fast-response EOA on hardware wallet            | Multisig clears via `setGuardian(address(0))`         |
| **Agent EOA**                 | Hot wallet held only by the agent host                 | Owner calls `setAgentAuthorization(oldAgent, false)` + authorizes new EOA |
| **Treasury Safe**             | Separate Gnosis Safe — destination of perf-fee shares  | Owner calls `proposeTreasury(newTreasury)` → 24h wait → `executeTreasury()` |
| **Hyperlane mailbox**         | Hyperlane's deployed mailbox per chain — immutable on `MirrorHook`, timelocked on `Relayer` | Relayer redeploy if mailbox is ever rotated by Hyperlane |
| **Sister `MirrorHook` peers** | One per non-primary chain — registered via `setAuthorizedSender` | Owner toggles allowlist on every chain                |

Operator action: maintain a single source-of-truth doc (encrypted, multi-region backup) with every deployed address, its role, and the signing/recovery procedure. Re-verify quarterly.

---

## 2. Agent key rotation (R-4)

The agent EOA is the highest-leverage credential below the owner multisig. Treat it as compromisable at all times.

### Default policy
- **Rotation cadence:** every 90 days, or immediately on any of the triggers below.
- **Generation:** in a clean offline environment. Stored only in the agent host's secrets manager (no copy on a human's machine, no copy in version control).
- **Custody:** the agent host (Railway container at mainnet) is the only holder. Operators do NOT have a copy.

### Triggers for immediate rotation
1. CI logs leak — any indication the key value appeared in build output, error trace, or third-party log aggregator.
2. Agent host compromise — even suspected. Treat the key as known.
3. Departure of any engineer with read access to the agent host's secrets.
4. Unexplained on-chain activity from the agent EOA (unscheduled `dispatchRebalance`, `harvest`, `updateCrossChainAssets`).
5. Anomalous `CrossChainAssetsUpdated` event with `oldValue → newValue` outside expected daily-yield range — even if R-1's delta gate caught it, the value MAY have been the attacker's first probe.

### Rotation procedure
1. **Pre-stage** the new agent EOA in the agent host (do not start it yet).
2. **Multisig call** `MirrorVault.setAgentAuthorization(newAgent, true)` and equivalent on `MirrorHook`. Both must be authorized BEFORE the old one is revoked so the agent doesn't go offline mid-rotation.
3. **Restart** the agent host with the new key.
4. **Verify** one normal cycle: confirm `CrossChainAssetsUpdated` events are signed by the new key.
5. **Revoke** the old key: multisig `setAgentAuthorization(oldAgent, false)` on both contracts.
6. **Document** the rotation in the operator log (who, when, why, new key derivation source).

### What NOT to do
- Don't share the new key over Slack/email/DMs before it's in the secrets manager.
- Don't reuse a previously-rotated key, even a year later.
- Don't authorize two agent EOAs simultaneously for longer than the rotation window — the goal is single-active-agent semantics.

---

## 3. Multisig signing policy (R-6)

The owner multisig is the trust root. A compromised multisig means a compromised protocol. Policy below is the minimum bar; raise it if your threat model is hotter than the default.

### Quorum
- **Recommendation:** 3-of-5 at launch; consider 4-of-7 at mainnet TVL > $5M.
- **Composition:** geographically distributed; mix of hardware wallets and air-gapped signers; no two signers should share an employer or jurisdiction if avoidable.
- **No single point of recovery.** If the seed phrases live in one location, the quorum is one.

### Signer roles
- **Core engineer (1-2):** drafts proposals.
- **Security lead (1):** signs only after independent review.
- **Operations / on-call (1):** can sign in incident windows.
- **External signer (1+):** independent party with no protocol equity exposure where possible; signs only well-formed proposals.

### Proposal hygiene
Every multisig transaction is reviewed against a checklist before signing:
1. **Calldata** matches the human-readable description. (Use Safe's "Decoded" view + a separate Foundry simulation.)
2. **Target address** matches the deployed contract for this chain. Compare to `audits/SCOPE.md` and the address inventory doc.
3. **Privilege scope** matches the smallest action that achieves the goal. Don't call `setTreasury` when `setAgentAuthorization` would do.
4. **Timelocked setters** (`proposeTreasury`, `proposeMailbox`, `proposeSafe`) are reviewed twice: once at propose-time, once before `execute*`. The 24h delay is for catching mistakes, not just attacks.
5. **Off-hours / urgency** proposals require an extra signer above the normal quorum (e.g. 4-of-5 not 3-of-5). Adversaries push under time pressure.

### Signer rotation
- On any signer's departure or device replacement: add new signer first, then remove old.
- Quarterly: every signer verifies they can still produce a signed transaction from their device (drill).
- Annually: refresh signer composition (rotate at least one signer if no natural rotation has happened).

### Emergency: signer key compromised
1. Healthy signers immediately `removeOwner(compromised)` via Safe.
2. If the compromise is suspected (not confirmed), still remove — false positive is cheap.
3. If the compromised signer's last action was within the last 24h, audit every multisig tx in that window for unexpected proposals. Use the timelock cancel path on anything suspicious:
   - `MirrorVault.cancelPendingTreasury`
   - `Relayer.cancelPendingMailbox`
   - `Treasury.cancelPendingSafe`

---

## 4. Authorized-sender administration (R-9)

`setAuthorizedSender` on `MirrorHook` and `Relayer` controls who can deliver cross-chain messages. Misadministration is a high-impact bug.

### Adding a new sister chain (e.g. enabling BNB post-launch)
1. **Deploy** the new chain's `MirrorHook` (and `Relayer` if it's a non-primary chain), with the SAME `canonicalPairId` as the existing peers. Use `MineHookAddress.s.sol` so address bits encode the right permissions.
2. **Register** the local pair on `MirrorFactory`: `registerLocalPair(canonicalId, newDomain, token0, token1, hook)`.
3. **Update Vault chain registry**: `Vault.addChain(newDomain, cctpDomain, cctpRecipient, warpRouter, warpRecipient, 0 /* alloc */)` then `setAllocations([oldDomain, newDomain, ...], [...])` such that the sum stays at 10_000.
4. **Authorize senders BOTH directions:**
   - On every EXISTING chain: `MirrorHook.setAuthorizedSender(bytes32(uint256(uint160(newChainHook))), true)`.
   - On the NEW chain: `MirrorHook.setAuthorizedSender(bytes32(uint256(uint160(oldChainHook))), true)` for every existing peer; and `setAuthorizedSender` for Relayer addresses where applicable.
5. **Add sister domain** on every chain: `MirrorHook.addSisterDomain(newDomain, bytes32(uint256(uint160(newChainHook))))`.
6. **Fund** the new chain's hook with ETH for Hyperlane dispatch fees (~0.05 ETH at mainnet).
7. **Verify**:
   - Cast-call `authorizedSenders` from every chain to every other chain — must be true.
   - Cast-call `canonicalPairId` on the new hook — must equal the canonical id.
   - Send a no-op `dispatchRebalance(0, 0, 3000, 0, 0)` from the new chain and confirm sister hooks receive `SisterNotificationReceived` with the right `(origin, sender, pairId)`.

### Removing a sister (chain decommission)
1. `Vault.setAllocations` to zero out the dying chain's allocation. Confirm sum stays 10_000 across remaining chains.
2. Wait for all in-flight CCTP USDC to settle on the dying chain. **Cannot enforce on-chain — operator discipline.**
3. Drain the dying chain's Relayer USDC inventory back to the Vault via the agent's manual unwind path.
4. `Vault.removeChain(dyingDomain)`.
5. On every chain that knows about the dying chain: `MirrorHook.removeSisterDomain(dyingDomain)` and `setAuthorizedSender(bytes32(dyingHook), false)`.
6. The dying chain's hook can stay deployed (immutable; no harm done) or have its ETH withdrawn via `withdrawEth(amount)` if the operator wants the funds back.

### Common mistakes
- **Forgetting one direction of the allowlist.** Auth must be symmetric — A trusts B and B trusts A. The dispatch-side test (step 7 above) catches asymmetry.
- **Wrong `bytes32(address)` padding.** Use the **left-padded** form `0x000…000<address>`, not `cast --to-bytes32` which right-pads and silently corrupts. (Memory: this bit us once.)
- **Adding a new sister without updating Vault's chain registry.** The hook side works but the Vault won't bridge USDC. Confirm `Vault.enabledDomainsCount()` increments after adding.

---

## 5. Incident response: pause / unpause

The guardian role (R-7) exists so pause happens in minutes, not multisig-coordination hours. Use the procedure below at the FIRST credible signal — false positives are cheap.

### Pause triggers
1. **Tenderly alert** on agent EOA: any tx outside the agent's expected call set (`updateCrossChainAssets`, `dispatchRebalance`, `harvest`, `fulfillWithdraw`, `recordRebalance`, `updateBaselineApy`).
2. **`CrossChainAssetsDeltaTooLarge` revert** observed in the agent's logs more than 3× in 15 minutes — agent is being driven by an attacker probing the bound.
3. **Oracle deviation revert** (`OracleDeviationTooLarge`) — Pyth and Chainlink disagree by > 5%. Real market events occasionally trip this; investigate before unpause but pause first.
4. **`SisterDepthCapped` event** on `MirrorHook` — a sister reported an absurd depth that R-13 caught. Compromised sister or buggy peer.
5. **Hyperlane delivery anomaly** — unexpected `handle()` reverts at high rate.
6. **External signal** — incident report from Hyperlane, Circle, Pyth, or Chainlink that affects mirv's trust assumptions.

### Pause procedure
1. **Guardian** calls `MirrorVault.pause()` and `MirrorHook.pause()` (in that order; vault first stops new deposits). For non-primary chains, also `Relayer.pause()` via multisig (Relayer has no guardian role yet — flagged for future hardening).
2. **Announce** internally — operator channel, on-call rotation.
3. **Multisig** convenes within the hour. Senior on-call drafts the incident summary.

### Unpause procedure
Only the **owner multisig** can unpause. The guardian's role ends at pause. Procedure:
1. Root-cause analysis complete. Document filed.
2. Mitigation applied (key rotated, contracts patched, sister allowlist tightened, etc.).
3. Multisig quorum signs `unpause()` on each paused contract.
4. Resume monitoring with heightened alert thresholds for 7 days.

### What NOT to do
- Don't unpause to "test if the issue is fixed." Use a fork.
- Don't share the incident on public channels before the multisig has authorized disclosure.
- Don't blame the agent EOA before checking the agent host for compromise — the credential is downstream of the host.

---

## 6. Routine operator drills

Quarterly. Calendar these.

| Drill                              | What you're rehearsing                                                   |
|------------------------------------|--------------------------------------------------------------------------|
| Multisig quorum exercise           | Every signer signs a no-op multisig tx (e.g. `setAgentAuthorization` toggling a dummy address) within 4 hours. |
| Guardian pause                     | Guardian pauses on testnet, multisig unpauses, full timeline logged.    |
| Agent key rotation                 | Full rotation on testnet, including authorization handover and verification. |
| Timelock cancel                    | Propose a treasury change, then cancel it before the 24h window. Time how long the cancel took. |
| Address inventory verification     | Every operator independently reproduces the address inventory doc from on-chain reads. |

---

## 7. Monitoring requirements

These are the off-chain alerts that make the on-chain hardening matter. Without them, R-1 / R-5 / R-7 are just slower paths to the same compromise.

| Alert                                                              | Threshold                            | Action                                 |
|--------------------------------------------------------------------|--------------------------------------|----------------------------------------|
| `CrossChainAssetsUpdated` with `newValue/oldValue > 1.2`           | per event                            | Page on-call; review agent host        |
| `CrossChainAssetsDeltaTooLarge` revert seen ≥ 3× in 15 min         | rate                                 | Guardian pause immediately             |
| `TreasuryProposed` / `MailboxProposed` / `SafeProposed` event      | per event                            | Page on-call; verify proposal is expected; cancel if not |
| Agent EOA tx outside expected call set                             | per event                            | Page on-call; consider pause           |
| `DispatchFailed` event on `MirrorHook`                             | rate                                 | Investigate sister-side issue          |
| `OracleDeviationTooLarge` revert                                   | per event                            | Investigate feed disagreement; pause if persistent |
| `SisterDepthCapped` event                                          | per event                            | Investigate sister; possibly revoke from allowlist |
| Hook ETH balance < 0.01 ETH                                        | absolute                             | Top up via `fund()`                    |
| Vault paused state                                                 | toggle                               | Page on-call; alert team               |

Set these up before mainnet launch. They are not optional.
