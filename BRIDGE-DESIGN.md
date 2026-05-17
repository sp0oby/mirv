# mirv Bridge Design — Vault → Sister Relayer Funding

**Status:** Design draft. Awaiting sign-off before contract changes.
**Owner:** mirv core
**Last updated:** 2026-05-17

This document pins how user deposits on the **MirrorVault** (Base) get bridged
to sister chain **Relayer** contracts so they can add LP positions on local V4
pools. It also pins how withdrawals unwind. Without this, the on-chain
rebalance path from Phase B / inbound `handle()` validation (both proven
2026-05-17) can only ever execute zero-delta "wake-up" messages — non-zero
rebalances require the destination Relayer to actually own tokens.

---

## 1. Scope

In:
- USDC and WETH bridging between Base ↔ Ethereum and Base ↔ BNB
- Deposit flow (user USDC on Base → split across 3 chains)
- Withdrawal flow (unwind LP → bridge USDC back to vault → release to user)
- Failure modes (stuck/reverted bridge, partial bridge, in-flight on withdraw)

Out (for v1):
- Withdrawal queueing or batching across multiple users
- Non-USDC vault assets (DAI, USDT)
- Non-ETH/USDC pairs (handled by `MirrorFactory` post-launch)

## 2. Why this needs a deliberate design

Two distinct bridge primitives, each with different failure modes:

- **USDC**: native on every target chain (Circle issues real USDC on Base,
  Ethereum, BNB). The right primitive is **Circle CCTP** (Cross-Chain
  Transfer Protocol) — burns USDC on source, mints native USDC on destination.
  No synthetic-collateral pool to bootstrap. No bridge-hack risk on the
  collateral side.

- **WETH**: not natively bridgeable. ETH is the gas token everywhere but the
  ERC-20 "Wrapped Ether" representation is a chain-local contract. To get
  WETH on Ethereum from WETH on Base, we either bridge **ETH** (the native
  gas token) and re-wrap on destination, or use a Hyperlane warp route to
  move a synthetic WETH representation.

Mixing these two primitives in a single deposit flow means understanding
both, including the asymmetry: CCTP attestations are off-chain Circle-signed
attestations that an authorized receiver submits on destination; Hyperlane
warp routes settle via the same validator+relayer infra mirv already uses
for control-plane messaging.

## 3. Token-level decisions

### 3.1 USDC — Circle CCTP

**Decision: use Circle CCTP, not a Hyperlane warp route.**

Rationale:
- CCTP yields **native USDC** on destination. Hyperlane warp routes yield a
  synthetic ERC-20 backed by collateral on the source chain. Synthetic USDC
  isn't useful as V4 pool liquidity — V4 pools on each chain reference the
  *real* USDC contract (e.g. `0x833589fC…` on Base, `0xA0b86991…` on
  Ethereum, `0x8AC76a51…` on BNB). A synthetic wouldn't be accepted.
- No collateral bootstrap. Hyperlane synthetic warp routes require a pool of
  collateral on the source chain on day one. CCTP has no liquidity gate.
- Circle attestation security model is well-understood. The attestation is a
  signed message from Circle's attester set; receiving requires submitting
  the message + attestation to the destination CCTP MessageTransmitter.

CCTP integration:
- On Base: `TokenMessenger.depositForBurn(amount, destinationDomain, mintRecipient, burnToken)`
  burns the source USDC and emits `MessageSent` for the off-chain attester.
- Off-chain: Circle's attester signs the message (~30–60s on mainnet).
- On destination: anyone (typically a relayer service) calls
  `MessageTransmitter.receiveMessage(message, attestation)` which mints USDC
  to `mintRecipient`. For mirv, `mintRecipient` is the destination Relayer.

CCTP domain IDs (verify against https://developers.circle.com/cctp before deploy):
- Ethereum: 0
- Base: 6
- BNB: not yet supported by CCTP (as of 2026-01 cutoff) — **possible blocker
  for BNB at Phase 9 launch**. Investigate alternative: Hyperlane synthetic
  USDC warp route specifically for BNB, OR delay BNB inclusion until CCTP-BNB
  ships, OR use Stargate's USDC variant.

### 3.2 WETH — treasury-seeded inventory (simplified — revised 2026-05-17)

**Revised decision: skip the Hyperlane warp route entirely. Seed canonical
WETH directly on each Relayer from the Treasury at launch; replenish from
collected fees as needed.**

Why the simpler model wins for mirv's actual flow:
- Users deposit USDC (the value-bearing asset). USDC flows dynamically via
  CCTP every deposit.
- WETH on each chain is just LP inventory the Relayer holds. It doesn't
  need to move per-deposit — the Relayer's WETH balance gets *replenished*
  from fees over time, not topped up per user action.
- Warp-route + synthetic + canonical-adapter is 5+ new contracts and a
  bootstrap-liquidity gate that fails closed. Treasury seeding is two
  `cast send` operations at launch (Treasury → each Relayer).

What's required operationally at mainnet launch:
- Treasury allocates ~$50k of WETH per chain (sized for expected first-week
  LP positions). Sends canonical WETH to each Relayer.
- Relayer holds the WETH as a passive balance. Standard ERC-20 ownership;
  no special accounting.
- When CoordinatorAgent decides to add LP on a sister, Relayer uses local
  USDC (CCTP-bridged) + local WETH (from treasury float) to add the position.

How replenishment works long-term:
- LP positions earn fees in both tokens. As fees accumulate, the Relayer's
  WETH balance grows organically without any cross-chain flow.
- If a chain's WETH float runs low (e.g. heavy rebalancing away from it),
  Treasury can top up with another `cast send`. Slack volume should be
  minimal once positions are operating in a steady state.
- RiskAgent monitors per-chain WETH float and alerts ops if it falls below
  a configurable threshold (e.g. 10% of expected next-cycle LP add).

What about the WETH float being a single point of failure?
- It's not. If a chain's WETH runs out, only LP adds *to that chain* halt.
  Existing LP positions keep earning fees. Withdrawals from that chain
  (which remove LP, returning both tokens) replenish the float.
- The Treasury multisig holds the WETH reserves on Base — same security
  surface as the rest of the protocol's treasury operations.

**No new contracts needed.** Treasury and Relayer surfaces are already
sufficient. Compare to the warp-route path (which would have needed
HypERC20Collateral, HypERC20, SyntheticToCanonicalAdapter, plus the
bootstrap WETH pool on each chain).

When WOULD warp routes be worth it?
- If we add a non-USDC vault asset that needs to be bridged every deposit
  (e.g. ETH-denominated vault on the Lido side).
- If the protocol scales to a TVL where treasury-seeded WETH would tie up
  too much capital relative to dynamic flow.
- Neither applies at Phase 9 launch.

## 4. Vault contract changes

The current `MirrorVault.deposit(assets, receiver)` accepts USDC and credits
shares. It does not bridge anything. Changes:

### 4.1 New state

```solidity
ITokenMessenger public immutable cctpMessenger;          // Circle CCTP on Base
IHypTokenRouter public immutable wethWarpRouter;         // mirv's WETH warp router on Base
IERC20 public immutable weth;                            // canonical WETH on Base
uint16 public allocationBaseBps   = 4000;  // 40% of deposit stays on Base
uint16 public allocationEthBps    = 4000;  // 40% to Ethereum
uint16 public allocationBnbBps    = 2000;  // 20% to BNB (until BNB CCTP, possibly 0)
address public ethereumRelayer;   // bytes32(uint160(addr)) for CCTP/warp recipient
address public bnbRelayer;
uint32  public constant CCTP_DOMAIN_ETHEREUM = 0;
uint32  public constant CCTP_DOMAIN_BASE     = 6;
```

Allocations are admin-tunable via `setAllocations(uint16,uint16,uint16)` with
the requirement that `base + eth + bnb == 10_000`. Initial values are
deliberately not 1/3-1/3-1/3 — we'd start more Base-heavy to validate before
allocating more cross-chain.

### 4.2 Modified deposit flow

```solidity
function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
    shares = super.deposit(assets, receiver);  // pulls USDC, mints shares

    uint256 baseAmt = assets * allocationBaseBps / 10_000;
    uint256 ethAmt  = assets * allocationEthBps  / 10_000;
    uint256 bnbAmt  = assets - baseAmt - ethAmt;  // BNB gets the remainder

    // Base portion stays in the vault for the Base hook's LP path
    // (Coordinator agent dispatches a local LP add via the Base hook)

    if (ethAmt > 0) _bridgeUsdc(ethAmt, CCTP_DOMAIN_ETHEREUM, ethereumRelayer);
    if (bnbAmt > 0) _bridgeUsdcOrSkip(bnbAmt);  // skips if BNB CCTP not ready

    // WETH side is bridged separately via the Coordinator agent based on
    // observed pool requirements — we don't pre-bridge WETH at deposit
    // because the LP add amount depends on current pool tick + range.

    emit Deposited(receiver, assets, shares, baseAmt, ethAmt, bnbAmt);
}

function _bridgeUsdc(uint256 amount, uint32 cctpDomain, address recipient) internal {
    IERC20(asset()).forceApprove(address(cctpMessenger), amount);
    cctpMessenger.depositForBurn(
        amount,
        cctpDomain,
        bytes32(uint256(uint160(recipient))),
        asset()
    );
    emit CctpBridgeSent(cctpDomain, recipient, amount);
}
```

The vault never holds bridged USDC — once CCTP burns, it's accounted for as
"in-flight" on a separate ledger. Vault's `totalAssets()` already supports a
cross-chain assets accumulator (`updateCrossChainAssets` is called by the
agent); we extend it to track in-flight bridge legs.

### 4.3 WETH bridging — separate flow, not at deposit time

WETH bridging happens when the Coordinator agent decides to add LP on a
sister chain. The agent calls `vault.bridgeWeth(uint32 destChain, uint256 amount)`
(new function, agent-only) which transfers WETH from the vault's WETH balance
into the warp router and sends to the destination Relayer. The vault's WETH
balance is seeded by an admin-only `seedWeth` function during launch (the
treasury deposits initial WETH to support cross-chain LP adds).

This decoupling matters: USDC bridges at deposit time because it's the
user's asset and ratios are deterministic. WETH bridges when needed for an
LP add because the amount depends on the pool's current tick and range.

## 5. Relayer contract changes

The Relayer needs to accept incoming USDC (from CCTP mint) and WETH (from
warp route delivery), and call `swap` if synthetic-WETH was received that
must become canonical-WETH before LP.

### 5.1 USDC arrival (CCTP)

CCTP mints USDC directly to `mintRecipient` (the Relayer) via Circle's
`MessageTransmitter.receiveMessage`. No mirv code runs. The USDC just shows
up in the Relayer's balance. The Coordinator agent observes this via
the standard ERC-20 `Transfer` event and includes the new balance in its
next rebalance plan.

No Relayer changes needed for CCTP.

### 5.2 WETH arrival (Hyperlane warp route)

The warp route's `HypERC20` mints synthetic WETH to its `recipient` argument
on `transferRemote`. We set `recipient = Relayer`. Synthetic WETH lands in
the Relayer's balance.

If we chose option (b) above (synthetic in pool), no further action. We
chose option (a), so the Relayer needs to swap synthetic→canonical before
LP. New function:

```solidity
function swapSyntheticToCanonicalWeth(uint256 amount) external onlyAgent {
    syntheticWeth.approve(address(swapAdapter), amount);
    swapAdapter.swap(syntheticWeth, canonicalWeth, amount);
}
```

The `swapAdapter` is a thin wrapper around the mirv-treasury-funded
backing pool (synthetic-WETH / canonical-WETH). At launch the treasury
deposits canonical WETH equal to expected first-week bridge volume; over
time, this pool is replenished as the protocol earns fees. **This swap
pool is mirv's bridge-side liquidity gate** — if it runs dry, cross-chain
LP adds halt. Monitor its depth in the RiskAgent.

## 6. Withdrawal flow

User calls `vault.withdraw(shares, receiver, owner)`. The vault needs USDC
on Base to release to the receiver. If the share value > Base local USDC
balance, the vault must wait for cross-chain unwinds.

### 6.1 Synchronous case (sufficient Base-local USDC)

```
Base vault has X USDC liquid, user redeems for ≤X — execute immediately.
```

### 6.2 Asynchronous case (cross-chain unwind needed)

```solidity
function requestWithdraw(uint256 shares, address receiver) external returns (uint256 requestId) {
    // Burn shares immediately, queue the redemption with a pending payout amount
    requestId = _enqueueWithdraw(msg.sender, shares, receiver);
    emit WithdrawRequested(requestId, msg.sender, shares);
    // Off-chain CoordinatorAgent observes WithdrawRequested events, computes
    // optimal unwind (which chain has surplus relative to allocation targets),
    // dispatches Relayer.removeLiquidity → bridges USDC back via CCTP →
    // vault.fulfillWithdraw(requestId) releases USDC to receiver.
}

function fulfillWithdraw(uint256 requestId) external onlyAgent {
    // Called once CCTP attestation is on the destination, USDC is liquid in vault
    ...
}
```

This is async (~2–5 min for CCTP attestation). Users see "pending → fulfilled"
in the UI. The 2–5 min latency is acceptable for a vault, but it's worth
showing the expected fulfillment time at request time so the UX isn't
opaque.

### 6.3 Withdrawal gas budget

Withdrawals don't pay the user-side gas across chains — the protocol covers
the cross-chain gas via IGP fees from the vault's collected fee reserves.
This is a real ongoing cost that should be factored into the 15% performance
fee economics (currently assumed to cover Anthropic + Railway + Redis only).

## 7. New contract surface summary

| Contract | Chain | Status | Purpose |
|---|---|---|---|
| `TokenMessenger` (CCTP) | Base, Ethereum | ✅ exists (Circle) | USDC burn on source |
| `MessageTransmitter` (CCTP) | Base, Ethereum | ✅ exists (Circle) | USDC mint on destination |
| `HypERC20Collateral` (WETH) | Base | 🆕 deploy | Locks canonical WETH on bridge |
| `HypERC20` (WETH synthetic) | Ethereum, BNB | 🆕 deploy | Mints synthetic WETH on receive |
| `SyntheticToCanonicalAdapter` | Ethereum, BNB | 🆕 deploy | Swap synthetic→canonical WETH backing pool |
| `MirrorVault` (modified) | Base | 🔄 redeploy | Adds CCTP integration + allocation logic |
| `Relayer` (modified) | Ethereum, BNB | 🔄 redeploy | Adds synthetic-WETH swap logic |
| `WithdrawalQueue` (optional) | Base | 🆕 maybe | Pluggable queue if v1 inlines, v2 extracts |

## 8. Failure modes

### 8.1 CCTP attester downtime

USDC bridge stalls. Users can't deposit cross-chain portions for ~hours
(rare; Circle's SLA is robust). Mitigation: vault still accepts deposits
locally, just doesn't bridge until CCTP recovers. RiskAgent flags
"CCTP_DOWN" status on extended outages.

### 8.2 Warp route relayer stuck

Hyperlane testnet sees this; mainnet is reliable. Backup: run own relayer
(see `project_hyperlane_relayer_model.md` memory).

### 8.3 Synthetic→canonical adapter pool runs dry

Cross-chain LP adds halt until refilled. RiskAgent pauses cross-chain
dispatches and alerts ops. Treasury can top up. This is a known constraint
of the synthetic-WETH choice; option (b) (synthetic-in-pool) would avoid
it but at the cost of pool composability.

### 8.4 Withdrawal in-flight when bridge stalls

User's request is queued. Funds are accounted but unfulfilled. UI shows
"delayed". This is acceptable for a vault product as long as the user is
informed. Hard-limit: if a request is pending > 24 hours, RiskAgent
escalates to manual intervention.

## 9. Implementation phases

1. **Phase 5.5 (now, before deeper testnet integration)**:
   - Land this design doc, get sign-off
   - Verify CCTP testnet addresses + BNB CCTP roadmap with Circle
   - Verify Hyperlane warp route deployment on Sepolia/Base-Sepolia/BNB-Testnet

2. **Phase 5.6 (contract impl)**:
   - Modify `MirrorVault.sol` for CCTP + allocation logic
   - Modify `Relayer.sol` for synthetic-WETH swap path
   - Deploy `HypERC20Collateral` + `HypERC20` on testnets
   - Deploy `SyntheticToCanonicalAdapter` + bootstrap WETH pool
   - Redeploy Vault + Relayer (v4 testnet iteration)
   - Re-wire everything

3. **Phase 5.7 (testnet validation)**:
   - End-to-end deposit on Base Sepolia → bridge to ETH Sepolia → Relayer holds USDC
   - End-to-end withdraw with cross-chain unwind
   - Soak test 24h with real cross-chain flow

4. **Phase 6 (audit prep)**:
   - This bridge surface is a new attack surface — fund flow + auth model both
     need fresh audit pass
   - Particular attention: replay protection on CCTP receive, slippage
     bounds on synthetic→canonical swap, queue auth on withdrawal fulfillment

## 10. Decisions locked (signed off 2026-05-17)

- [x] **Default allocation: 60/40 Base/Ethereum at mainnet launch (BNB at 0%).**
      40/40/20 was sized for 3 chains; with BNB out at launch the 20% would
      sit idle. Base-heavier because the vault sits there and operational
      signal is strongest. When BNB is enabled later (via admin
      `Vault.addChain(...)` tx, see §12), allocation rebalances toward the
      target 3-chain split.
- [x] **Canonical-WETH-in-pool (option a).** V4 pools reference canonical
      WETH on each chain; destination Relayer holds a synthetic→canonical
      swap adapter funded by treasury. Pools stay composable with the
      broader DEX ecosystem (Uniswap routers, aggregators) — synthetic-only
      pools would be a closed garden.
- [x] **Withdrawal: sync when Base-local USDC suffices, async with 2-5 min
      "fulfilling" state for cross-chain unwinds.** Matches README §7:
      "Cross-chain unwind handled automatically in ~2–5 minutes if needed."
      UI surfaces pending state explicitly so the UX isn't opaque. Hard
      timeout: requests pending > 24 hours escalate to RiskAgent.
- [x] **Protocol covers cross-chain withdrawal gas.** Consistent with README's
      "set it once" UX promise — user can't see cross-chain gas. Funded from
      the 15% performance-fee revenue. Adds an ongoing cost line item that
      should be tracked in tokenomics planning (Phase 11 $MIRROR work).
- [x] **Ship without BNB at mainnet launch (Phase 9).** CCTP doesn't support
      BNB as of cutoff; V4 isn't on BNB Testnet either. Build the Vault's
      chain registry (§12) so BNB can be added via a single admin tx once
      either: (a) CCTP-BNB ships, or (b) a Hyperlane synthetic USDC warp
      route for BNB is deemed acceptable risk. No protocol redeploy needed.

## 11. What's been built so far that supports this

- **MirrorVault** has `updateCrossChainAssets(uint256)` already wired — the
  agent already pushes cross-chain state in. Extending to track in-flight
  bridge legs is additive, not breaking.
- **Relayer** has `_settleDeltas` + `unlockCallback` — the modifyLiquidity
  side works. Just needs the token-arrival side (synthetic-WETH swap)
  built on top.
- **Cross-chain dispatch path** (hook → mailbox → Relayer.handle) is
  proven on testnet (Phase B + inbound trigger 2026-05-17). The control
  plane is independent of the bridge value plane.

Bridge is the missing value-plane piece. With it, mirv's deposit-to-LP
loop becomes fully autonomous.

---

## 12. Multi-chain & multi-pair extensibility

**Design constraint:** add new chains and new pairs post-launch with admin
transactions only — never redeploy Vault, Treasury, or Factory.

### 12.1 Why this matters

Without this, every new chain (BNB after CCTP-BNB, Arbitrum, Optimism, etc.)
or new pair (USDT/WETH, USDC/BTC) requires a fresh full deploy. Users on
existing vaults would have to migrate, breaking the "set it once" promise.

With this, the protocol can ship Base+Ethereum at mainnet launch and grow
to N chains and M pairs without disrupting deposits.

### 12.2 Chain registry on Vault

Replace hardcoded `allocationBaseBps / EthBps / BnbBps` + per-chain bridge
addresses with a single registry:

```solidity
struct ChainConfig {
    uint32  cctpDomain;          // Circle CCTP domain ID (0 if N/A)
    bytes32 cctpRecipient;       // bytes32(uint160(sisterRelayer))
    address warpRouter;          // Hyperlane HypERC20Collateral router on Base for THIS dest
    bytes32 warpRecipient;       // bytes32(uint160(sisterRelayer))
    uint16  allocationBps;       // 0–10000
    bool    enabled;
}
mapping(uint32 hyperlaneDomain => ChainConfig) public chainConfigs;
uint32[] public enabledDomains;  // iteration helper

function addChain(
    uint32 hyperlaneDomain,
    uint32 cctpDomain,
    bytes32 cctpRecipient,
    address warpRouter,
    bytes32 warpRecipient,
    uint16 allocationBps
) external onlyOwner {
    require(!chainConfigs[hyperlaneDomain].enabled, "ChainAlreadyEnabled");
    chainConfigs[hyperlaneDomain] = ChainConfig({...});
    enabledDomains.push(hyperlaneDomain);
    _validateAllocationsSum();  // require sum across all enabled chains == 10000
    emit ChainAdded(hyperlaneDomain, allocationBps);
}

function removeChain(uint32 hyperlaneDomain) external onlyOwner {
    require(chainConfigs[hyperlaneDomain].enabled, "ChainNotEnabled");
    require(_inFlightBalance(hyperlaneDomain) == 0, "ChainHasInFlightFunds");
    chainConfigs[hyperlaneDomain].enabled = false;
    // remove from enabledDomains array
    emit ChainRemoved(hyperlaneDomain);
}

function setAllocations(uint32[] calldata domains, uint16[] calldata bps) external onlyOwner {
    require(domains.length == bps.length);
    uint256 total;
    for (uint i; i < domains.length; ++i) {
        require(chainConfigs[domains[i]].enabled, "ChainNotEnabled");
        chainConfigs[domains[i]].allocationBps = bps[i];
        total += bps[i];
    }
    require(total == 10_000, "AllocationsMustSumTo10000");
}
```

Deposit flow iterates `enabledDomains` and bridges per-config — no hardcoded
chain references in the body of `deposit()`.

### 12.3 Canonical pairId issued by Factory

**Problem (surfaced during 2026-05-17 testnet validation):** Today, `pairId =
keccak256(abi.encode(currency0, currency1))`. The same logical pair
(USDC/WETH) produces different pairIds on different chains because token
addresses differ. Cross-chain depth notifications can't be routed correctly
because Base's pairId ≠ Ethereum's pairId for "the same pool."

**Fix:** Factory issues a `bytes32 canonicalPairId` at pair registration;
every chain's Hook for the same logical pair uses the SAME canonical id.

```solidity
// MirrorFactory (Base) — registers canonical pair identities
mapping(string => bytes32) public canonicalIdByName;  // "ETH-USDC-V1" => bytes32
mapping(bytes32 => PairMetadata) public pairs;

struct PairMetadata {
    string  name;               // human-readable, e.g. "ETH-USDC-V1"
    uint24  fee;
    int24   tickSpacing;
    address vault;              // on Base
    mapping(uint32 => ChainPairLocal) localOnChain;  // per-chain token addresses
}

struct ChainPairLocal {
    address currency0;          // local token0 on this chain
    address currency1;          // local token1 on this chain
    address hook;               // local MirrorHook on this chain
    address pool;               // V4 PoolId materialized as address (key components)
}

function registerCanonicalPair(string calldata name, uint24 fee, int24 tickSpacing)
    external onlyOwner returns (bytes32 canonicalId)
{
    canonicalId = keccak256(abi.encodePacked(name, fee, tickSpacing));
    require(canonicalIdByName[name] == bytes32(0), "AlreadyRegistered");
    canonicalIdByName[name] = canonicalId;
    // ... initialize struct fields
}

function registerLocalPair(
    bytes32 canonicalId,
    uint32 hyperlaneDomain,
    address currency0,
    address currency1,
    address hook
) external onlyOwner {
    pairs[canonicalId].localOnChain[hyperlaneDomain] = ChainPairLocal({...});
}
```

Hook is constructed with its `canonicalPairId`:

```solidity
// MirrorHook constructor — adds canonicalPairId
constructor(..., bytes32 _canonicalPairId) {
    canonicalPairId = _canonicalPairId;
    ...
}

// _handleEvent uses canonicalPairId, NOT keccak256(currency0, currency1):
bytes32 pairId = canonicalPairId;
```

When ETH hook dispatches to Base hook, the message carries the canonical
pairId. Base hook's `handle()` looks up `sisterDepths[origin][canonicalPairId]`,
which is the SAME canonicalPairId Base's own events use. Loop closes correctly.

### 12.4 Adding a new chain post-launch — the operations runbook

Once §12.2 and §12.3 are deployed, adding a chain (e.g. Arbitrum) is:

1. **Deploy infrastructure on Arbitrum** (one-time per chain, off-protocol):
   - HypERC20 synthetic WETH router
   - SyntheticToCanonicalAdapter + bootstrap WETH liquidity (treasury-funded)
2. **Deploy mirv Relayer on Arbitrum** (one tx via existing `DeployArb` script).
3. **For each existing canonical pair** (e.g. ETH-USDC-V1):
   - Mine hook address for Arbitrum with correct permission bits
   - Factory.deployPair(...) on Arbitrum → deploys Hook attached to that pair
   - Initialize V4 pool on Arbitrum with the new hook
   - Wire sister domains (existing scripts work — they iterate sisterDomains)
   - Authorize sender on Relayer (existing `setAuthorizedSender`)
4. **Admin tx on each existing Vault** (one per pair):
   - `Vault.addChain(arbHyperlaneDomain, arbCctpDomain, arbRelayerB32, arbWarpRouter, arbWarpRecipientB32, allocationBps)`
   - `Vault.setAllocations(...)` to rebalance across all chains
5. **Admin tx on Factory** to register local pair on Arbitrum:
   - `Factory.registerLocalPair(canonicalId, arbHyperlaneDomain, usdcArb, wethArb, arbHook)`

**Zero redeploys of Vault, Treasury, Factory.** Adding a chain is ~5
operational steps, each a single tx.

### 12.5 Adding a new pair post-launch

Once §12.3 is deployed, adding a pair (e.g. WBTC-USDC) is:

1. **Admin tx on Factory**: `registerCanonicalPair("WBTC-USDC-V1", fee, tickSpacing)` → emits canonicalId.
2. **For each enabled chain**:
   - Mine hook address for the new pair
   - `Factory.deployPair(canonicalId, hookSalt, ...)` → deploys Hook + Vault for the new pair
   - Initialize V4 pool on that chain with the new hook
   - Wire sister domains for the new pair's hooks
   - `Factory.registerLocalPair(canonicalId, hyperlaneDomain, wbtc, usdc, hook)`
3. **Users can deposit into the new vault.**

**Zero redeploys of Vault, Treasury, Factory.** Each pair gets its own
Hook + Vault but they all share the same Factory + chain registry.

### 12.6 What changes vs §4-§5 above

The vault/relayer changes in §4-§5 stand, with these updates:

- **Vault § 4.1 state**: replace 3 hardcoded `allocation*Bps` and per-chain
  bridge addresses with the `chainConfigs` mapping from §12.2. Storage layout
  is more compact (single mapping) but reads cost slightly more (iterate
  enabled domains). Net positive given the flexibility.
- **Vault § 4.2 deposit flow**: replace per-chain explicit calls with a
  loop over `enabledDomains` that reads each chain's config and dispatches
  CCTP (if `cctpDomain != 0`) or warp route (always).
- **MirrorHook**: add `bytes32 immutable canonicalPairId` constructor arg.
  Strip the runtime keccak256 from `_handleEvent` — use `canonicalPairId`
  directly. Updates to existing tests required.
- **MirrorFactory**: add canonical pair registry and `registerCanonicalPair` /
  `registerLocalPair` admin functions. Modify `deployPair` to accept
  `canonicalPairId` instead of computing one.

These are additive — the existing v3 testnet contracts still work, but
won't have the canonical-pairId fix. A v4 redeploy is required to land
extensibility. That's the next iteration after this design lands.

### 12.7 Storage migration concerns

For Vault: the existing v3 testnet Vault uses `_decimalsOffset = 0` (OZ
v5 default) and ERC-4626 share accounting. Adding `chainConfigs` is purely
additive to storage; no migration needed for existing share-holders (zero
on testnet at the moment). For mainnet launch we deploy this Vault layout
fresh — no in-place upgrade.

For Hook: adding `canonicalPairId` to the constructor changes the bytecode,
which changes the CREATE2 address. Re-mining required. Sister wiring is
mutable so no permanent state loss — just a redeploy cycle.

Slither + invariant tests must re-run against the v4 layout before
considering it ready for the next testnet iteration.

### 12.8 BNB enablement (post-launch)

When CCTP-BNB or an acceptable USDC warp route ships:
1. Deploy Relayer on BNB
2. Factory.registerLocalPair(ETH_USDC_canonicalId, bnbDomain, usdcBnb, wethBnb, bnbHook)
3. Vault.addChain(bnbDomain, ..., 1500)  // 15% allocation
4. Vault.setAllocations([base, eth, bnb], [5000, 3500, 1500])  // rebalance

Total cost: ~3 admin txs + the one-time Relayer + Hook deploys per chain.
No user-facing disruption.

---

## 11. What's been built so far that supports this

- **MirrorVault** has `updateCrossChainAssets(uint256)` already wired — the
  agent already pushes cross-chain state in. Extending to track in-flight
  bridge legs is additive, not breaking.
- **Relayer** has `_settleDeltas` + `unlockCallback` — the modifyLiquidity
  side works. Just needs the token-arrival side (synthetic-WETH swap)
  built on top.
- **Cross-chain dispatch path** (hook → mailbox → Relayer.handle) is
  proven on testnet (Phase B + inbound trigger 2026-05-17). The control
  plane is independent of the bridge value plane.

Bridge is the missing value-plane piece. With it, mirv's deposit-to-LP
loop becomes fully autonomous.
