# mirv — Uniswap meeting brief

**A V4 hook that exposes cross-chain liquidity depth as a callable primitive.**

---

## What it is

Users deposit USDC on Base. The protocol auto-splits it across Base + Ethereum,
parks it as LP in two V4 pools (one per chain), and an AI agent swarm
shifts allocation toward whichever chain is paying more in swap fees.

The interesting part isn't the rebalancing. It's that the `MirrorHook` exposes
a primitive nothing else in V4 has:

```solidity
function localDepthUsd(bytes32 poolId) external view returns (uint256);
function sisterDepths(uint32 domain, bytes32 pairId) external view returns (uint256);
```

Any contract on either chain — a swap router, an aggregator, another hook —
can read the protocol's depth distribution across chains in a single static call.
Cross-chain liquidity becomes addressable on-chain, not a thing you have to
index off-chain.

---

## What's live right now (rc6 candidate)

| | status |
|---|---|
| Contracts on Base Sepolia + Ethereum Sepolia | ✅ deployed, verified |
| 135 tests passing (105 unit/invariant + 30 fork) | ✅ |
| Slither, Mythril, Foundry fork-tests triaged | ✅ |
| Cross-chain dispatch → Hyperlane delivery → V4 `ModifyLiquidity` on destination | ✅ proven end-to-end |
| Frontend on Vercel (8 pages, custom kawaiicore design) | ✅ `mirv.vercel.app` |
| Agent swarm running on Railway, heartbeat endpoint | ✅ as of today |
| R-1..R-13 safety set (oracle deviation, harvest staleness, 24h treasury timelock, etc.) | ✅ on-chain |
| External audit | ⚪ gated on funding |

---

## What's NOT yet

We're being candid about this — Uniswap will ask:

- Our pools have minimal seed liquidity on testnet; no router quotes us today.
- Agents currently monitor only our own pools. They don't read canonical Uniswap
  pools to detect competitiveness.
- No tokenomics. No $MIRROR token. Deliberate — token launches as bootstrap
  fuel produce mercenary capital, not real depth.
- Not externally audited yet.

Mainnet is gated on **integration + audit + seed depth**, in that order.

---

## What unlocks production

Three things would change this from "interesting V4 hook" to "real protocol":

### 1. Router-aware hook routing in V4 Universal Router

Currently the V4 Universal Router quotes pools by `(currency0, currency1, fee,
tickSpacing)`. Different hooks = different pools. mirv's pool gets considered
only if the router knows to call `MirrorHook.localDepthUsd()` and factor
cross-chain depth into the quote.

**Ask:** is there an established path to add hook-aware quoting to the
V4 Universal Router? Could mirv be the first cross-chain primitive that
proves out that pattern?

### 2. Uniswap Grants funding

The next 3 milestones — external audit ($30–50k), seed-depth launch position
($100–500k), additional hook quoter interface — are concretely fundable.

**Ask:** introduce us to the Uniswap Grants team or co-author a proposal.
`GRANT-APPLICATION.md` is ready.

### 3. Ecosystem intros

We need partner pilots — cross-chain swap UIs (Across, deBridge, LI.FI) and
aggregator allowlists (1inch, Matcha, CowSwap). Uniswap's network here is
deeper than ours.

**Ask:** point us at the right people, ideally with a warm intro.

---

## Where to look

- **Live:** https://mirv.vercel.app
- **Docs (plain-English):** https://mirv.vercel.app/docs
- **Source:** https://github.com/sp0oby/mirv
- **Contracts:**
  - MirrorVault (Base Sepolia): [`0x062b9E54…f37b`](https://sepolia.basescan.org/address/0x062b9E547689D53D9c5b059215ED967a9ceAf37b#code)
  - MirrorHook (Base Sepolia): [`0xA059C854…c540`](https://sepolia.basescan.org/address/0xA059C8544E046F29C5c2A9f0dE6314964926c540#code)
  - MirrorHook (Ethereum Sepolia): [`0xc3233eb9…8540`](https://sepolia.etherscan.io/address/0xc3233eb9C427Cc1ACA5cF2d5c5e89c668F148540#code)
  - Relayer (Ethereum Sepolia): [`0x5D7BA93B…b727`](https://sepolia.etherscan.io/address/0x5D7BA93B47f93eaa359ca6063F39Eaeb4743b727#code)
- **Roadmap (Phase 8.5):** [`TODO.md`](./TODO.md) covers the 8 must-haves before mainnet

---

**Contact:** brandonsmccall@gmail.com
