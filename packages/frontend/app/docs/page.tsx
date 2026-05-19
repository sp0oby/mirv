import Link from "next/link";

export const metadata = {
  title: "mirv — docs",
  description: "how mirv works, in plain language.",
};

export default function DocsPage() {
  return (
    <div className="pt-4">
      <header className="mb-12">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          docs
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[64ch]">
          everything you'd ask about how mirv works, in plain language. for the
          really technical bits — contract source, audits, hook internals — links at the bottom.
        </p>
      </header>

      {/* ─── How you earn ─────────────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ✿ how you make money
        </h2>
        <div className="frame-outer p-6 bg-paper-warm">
          <p className="text-[15px] text-ink leading-relaxed mb-4">
            <strong>You earn from swap fees on Uniswap V4 pools.</strong> Not from
            arbitrage, not from yield farming, not from any token emissions.
          </p>
          <p className="text-[15px] text-ink leading-relaxed mb-4">
            When you deposit USDC, the protocol parks it as liquidity in our V4
            pools — one on Base, one on Ethereum. Every trader who swaps through
            those pools pays a 0.30% fee. Your share of those fees scales with
            your share of the in-range liquidity at the moment of each swap.
          </p>
          <p className="text-[15px] text-ink leading-relaxed mb-4">
            When you withdraw, your shares are worth more than what you put in,
            because the pools have collected fees while you were in.
          </p>
          <p className="text-[14px] text-ink-soft leading-relaxed">
            mirv is <em>never the taker</em> — we don't arbitrage between pools or
            run MEV. We're just a liquidity provider that happens to live on
            two chains at once.
          </p>
        </div>
      </section>

      {/* ─── Where the extra comes from ──────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ❀ where the "extra" comes from
        </h2>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-4 max-w-[70ch]">
          A passive cross-chain LP has to pick allocations upfront — say 50/50 —
          and live with it. If Base has 80% of the trading volume that week, a
          passive LP loses ~30% of potential fees because too much capital sits
          idle on the wrong chain.
        </p>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-6 max-w-[70ch]">
          mirv's agent swarm rebalances every 45 seconds. If Base's pool is
          paying more fees per dollar of liquidity, USDC shifts from Ethereum
          to Base via Circle CCTP. Your LP is always concentrated where the
          volume is.
        </p>
        <div className="frame-outer p-5">
          <p className="font-maru text-[14px] text-ink-faint uppercase tracking-wider mb-3">
            illustrative math at $1M TVL, $10M weekly cross-chain volume
          </p>
          <table className="w-full text-[14px]">
            <thead className="text-ink-faint text-[12px] uppercase tracking-wider">
              <tr>
                <th className="text-left px-2 py-2 font-maru font-normal">strategy</th>
                <th className="text-left px-2 py-2 font-maru font-normal">fee capture</th>
                <th className="text-right px-2 py-2 font-maru font-normal">annual yield</th>
              </tr>
            </thead>
            <tbody>
              <tr className="border-t border-dotted border-ink-soft/30">
                <td className="px-2 py-2 text-ink-soft">passive 50/50 split</td>
                <td className="px-2 py-2 text-ink-soft">~60% of theoretical max</td>
                <td className="px-2 py-2 text-right font-mono text-ink-soft">~6.0% APY</td>
              </tr>
              <tr className="border-t border-dotted border-ink-soft/30">
                <td className="px-2 py-2 text-ink-soft">mirv rebalance</td>
                <td className="px-2 py-2 text-ink-soft">~90%+</td>
                <td className="px-2 py-2 text-right font-mono text-ink-soft">~9.0% APY</td>
              </tr>
              <tr className="border-t border-dotted border-ink-soft/30">
                <td className="px-2 py-2 text-ink font-semibold">extra yield (mirv – passive)</td>
                <td className="px-2 py-2 text-ink-soft">—</td>
                <td className="px-2 py-2 text-right font-mono text-ink font-semibold">+3.0% APY</td>
              </tr>
              <tr className="border-t border-dotted border-ink-soft/30">
                <td className="px-2 py-2 text-ink">you keep 85% of the extra</td>
                <td className="px-2 py-2 text-ink-soft">—</td>
                <td className="px-2 py-2 text-right font-mono text-pink-hot font-semibold">+2.55% APY on top</td>
              </tr>
            </tbody>
          </table>
          <p className="text-[11px] text-ink-faint mt-3">
            real ratios depend on actual pool depth and volume distribution. numbers above are illustrative.
          </p>
        </div>
      </section>

      {/* ─── Deposit ────────────────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ✦ what happens when you deposit
        </h2>
        <ol className="space-y-3 text-[15px] text-ink-soft leading-relaxed max-w-[70ch]">
          <li><strong className="text-ink">1.</strong> You approve USDC to the vault, then call deposit on Base.</li>
          <li><strong className="text-ink">2.</strong> The vault mints you <span className="font-mono">mirvUSDC</span> shares. Initially 1 share = 1 USDC.</li>
          <li><strong className="text-ink">3.</strong> The vault splits your USDC by the chain registry. Today: 60% stays on Base, 40% gets bridged to Ethereum via Circle's CCTP burn-and-mint.</li>
          <li><strong className="text-ink">4.</strong> Within ~20 minutes, the bridged USDC arrives on Ethereum and lands at the Relayer contract.</li>
          <li><strong className="text-ink">5.</strong> The agent reports the cross-chain balance, so the vault's <code className="font-mono text-[13px]">totalAssets</code> reflects the full amount.</li>
          <li><strong className="text-ink">6.</strong> The agent (or a triggered hook callback) adds the USDC as LP into each chain's V4 pool, paired with WETH.</li>
        </ol>
        <p className="text-[13px] text-ink-faint mt-4 max-w-[70ch]">
          Between steps 3 and 5 your share price will briefly look lower than $1 because the
          cross-chain portion isn't yet accounted for. This settles within one agent cycle (~45s)
          once the agent reports.
        </p>
      </section>

      {/* ─── Withdraw ────────────────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ✿ how you withdraw
        </h2>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
          <div className="frame-outer p-5">
            <p className="font-maru text-[14px] text-ink font-semibold mb-2">if there's enough USDC on Base</p>
            <p className="text-[14px] text-ink-soft leading-relaxed">
              You redeem your shares and get USDC in the same transaction. Synchronous, no waiting.
            </p>
          </div>
          <div className="frame-outer p-5 bg-paper-warm">
            <p className="font-maru text-[14px] text-ink font-semibold mb-2">if cross-chain unwind is needed</p>
            <p className="text-[14px] text-ink-soft leading-relaxed">
              Your withdrawal goes into a queue. The agent pulls liquidity on Ethereum, CCTP-bridges
              the USDC back, and fulfills your request. Usually a few minutes. If the agent fails to
              fulfill within 24h, you can cancel and get your shares back.
            </p>
          </div>
        </div>
      </section>

      {/* ─── The swarm ────────────────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ✦ the agent swarm
        </h2>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-6 max-w-[70ch]">
          Four agents, all powered by Claude, cooperate to decide when and how
          to rebalance. They run on a 45-second cycle.
        </p>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
          {[
            { title: "the readers (×2)", body: "One per chain. They read pool depth, recent volume, fee accrual, and oracle prices. They report back what each side looks like." },
            { title: "the strategist", body: "Compares both chains. If one is clearly paying more per dollar of liquidity, plans a move — how much USDC to shift, what tick range to add into." },
            { title: "the veto", body: "Double-checks every plan against the safety rules. Blocks moves that are too big, badly priced, or fire too often. Has the final say." },
            { title: "the hand", body: "The only one that signs transactions. Executes the plan once the veto agent clears it, paying the bridge fee." },
          ].map((a, i) => (
            <div key={i} className="frame-outer p-5" style={{ transform: `rotate(${[-0.3, 0.4, -0.5, 0.3][i]}deg)` }}>
              <p className="font-maru text-[15px] text-ink font-semibold mb-2">{a.title}</p>
              <p className="text-[13.5px] text-ink-soft leading-snug">{a.body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ─── Safety ────────────────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ❀ what bounds the swarm
        </h2>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-4 max-w-[70ch]">
          The agents are LLMs and could be wrong. The protocol assumes they will be wrong sometimes
          and bounds the damage in code:
        </p>
        <ul className="space-y-2.5 text-[14px] text-ink-soft leading-relaxed max-w-[72ch]">
          <li><strong className="text-ink">No move can shift more than 25%</strong> of total assets in a single cycle. Even a compromised agent can't drain the vault.</li>
          <li><strong className="text-ink">Two independent price feeds</strong> (Pyth + Chainlink) must agree within 5% before anything moves.</li>
          <li><strong className="text-ink">Depth updates from the other chain are capped at 10× any prior reading.</strong> Stops impossible-looking spikes from triggering bad moves.</li>
          <li><strong className="text-ink">There's a 60-second cooldown between rebalances.</strong> The agents can't fire-hose dispatches.</li>
          <li><strong className="text-ink">Treasury changes are delayed 24 hours.</strong> If the owner changes where fees go, you have a full day to leave first.</li>
          <li><strong className="text-ink">Cross-chain reports older than 1 hour are rejected.</strong> If the agent goes silent, the vault won't act on stale data.</li>
          <li><strong className="text-ink">You can always start a withdrawal.</strong> No admin override on the user exit path.</li>
        </ul>
        <p className="text-[13px] text-ink-faint mt-4 max-w-[70ch]">
          Internal test suite is at 135 passing tests. Slither, Mythril and Foundry fork-tests
          have been run against the rc6 bytecode. <strong>Not yet externally audited</strong> —
          mainnet is gated on that.
        </p>
      </section>

      {/* ─── Honest framing ────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ❀ what has to be true for this to actually be useful
        </h2>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-4 max-w-[72ch]">
          We're being honest here, because Uniswap and other smart people will
          ask. mirv's pools are permissionless — anyone with USDC + WETH can
          add LP to them. But on day one, nobody will, because there's no
          incentive to use our pool over the canonical Uniswap one if they're
          shallower.
        </p>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-4 max-w-[72ch]">
          That means today the swarm is mostly managing the vault's own
          positions across two chains. It's a real protocol with real
          cross-chain mechanics — but to earn fees for depositors, our pools
          need <em>external</em> swap volume, and that requires:
        </p>
        <ul className="space-y-2.5 text-[14px] text-ink-soft leading-relaxed max-w-[72ch] mb-4">
          <li><strong className="text-ink">Seed depth at mainnet launch</strong> — treasury seeds $500k–$1M per chain so routers consider us competitive.</li>
          <li><strong className="text-ink">Router + aggregator integration</strong> — Uniswap Universal Router, 1inch, Matcha need to know our pool exists and route through it. We're working toward this.</li>
          <li><strong className="text-ink">The hook's cross-chain primitive being adopted</strong> — our actual edge is that routers can read cross-chain depth from a single contract call. That's what makes mirv ≠ "just another LP."</li>
          <li><strong className="text-ink">Smarter agents</strong> — the swarm needs to also monitor canonical pools (not just our own) to detect when our pool is non-competitive and adjust.</li>
        </ul>
        <p className="text-[14px] text-ink-soft leading-relaxed max-w-[72ch]">
          The contracts are validated end-to-end. The mechanism works. The
          go-to-market — getting volume to flow through — is the next phase.
          See the README's "Pre-mainnet must-haves" section for the work plan.
        </p>
      </section>

      {/* ─── For technical readers ────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ✿ the V4 hook (for technical readers)
        </h2>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-3 max-w-[70ch]">
          mirv's interesting trick is that depth isn't a per-chain phenomenon
          anymore. The <code className="font-mono text-[13.5px]">MirrorHook</code> exposes
          a cross-chain depth primitive that any contract on either chain can read:
        </p>
        <pre className="font-mono text-[12.5px] bg-paper-deep text-ink-soft p-4 rounded mb-3 overflow-x-auto border border-ink-soft/30">
{`function localDepthUsd(bytes32 poolId) external view returns (uint256);
function sisterDepths(uint32 domain, bytes32 pairId) external view returns (uint256);`}
        </pre>
        <p className="text-[15px] text-ink-soft leading-relaxed mb-3 max-w-[70ch]">
          So a swap router building a multi-chain quote, or a different hook
          on a third pool, can read what depth is available <em>across</em>
          mirv's pools without running a custom indexer. Cross-chain liquidity
          becomes a callable thing.
        </p>
        <p className="text-[15px] text-ink-soft leading-relaxed max-w-[70ch]">
          V4 pool identity is{" "}
          <code className="font-mono text-[13px]">(currency0, currency1, fee, tickSpacing, hooks)</code> —
          attaching a different hook means it's a different pool. So mirv runs its own
          USDC/WETH pool on each chain, separate from the canonical Uniswap pool. We don't
          compete with that pool; we add a hook-coordinated lane next to it.
        </p>
      </section>

      {/* ─── Contracts ────────────────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ✦ contract addresses
        </h2>
        <p className="text-[13px] text-ink-faint mb-4">rc6 candidate, live on testnet. all verified on the explorers.</p>
        <div className="frame-outer p-4">
          <table className="w-full text-[13px]">
            <thead className="text-ink-faint text-[11px] uppercase tracking-wider">
              <tr>
                <th className="text-left px-3 py-2 font-maru font-normal">contract</th>
                <th className="text-left px-3 py-2 font-maru font-normal">chain</th>
                <th className="text-left px-3 py-2 font-maru font-normal">address</th>
              </tr>
            </thead>
            <tbody className="font-mono">
              {[
                { name: "MirrorVault", chain: "Base Sepolia", addr: "0x062b9E547689D53D9c5b059215ED967a9ceAf37b", explorer: "sepolia.basescan.org" },
                { name: "MirrorHook", chain: "Base Sepolia", addr: "0xA059C8544E046F29C5c2A9f0dE6314964926c540", explorer: "sepolia.basescan.org" },
                { name: "MirrorFactory", chain: "Base Sepolia", addr: "0xC3e117CD904db351F919134adCee7237F3ebC2A7", explorer: "sepolia.basescan.org" },
                { name: "Treasury", chain: "Base Sepolia", addr: "0x00288400B0202Fa7c236d52685fFd725B4780392", explorer: "sepolia.basescan.org" },
                { name: "MirrorHook", chain: "Ethereum Sepolia", addr: "0xc3233eb9C427Cc1ACA5cF2d5c5e89c668F148540", explorer: "sepolia.etherscan.io" },
                { name: "Relayer", chain: "Ethereum Sepolia", addr: "0x5D7BA93B47f93eaa359ca6063F39Eaeb4743b727", explorer: "sepolia.etherscan.io" },
              ].map((c) => (
                <tr key={c.addr} className="border-t border-dotted border-ink-soft/30">
                  <td className="px-3 py-2 text-ink not-italic">{c.name}</td>
                  <td className="px-3 py-2 text-ink-soft">{c.chain}</td>
                  <td className="px-3 py-2">
                    <a
                      className="underline text-pink-hot"
                      href={`https://${c.explorer}/address/${c.addr}#code`}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      {`${c.addr.slice(0, 10)}…${c.addr.slice(-6)}`}
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {/* ─── FAQ ────────────────────────────────────────────────── */}
      <section className="mb-14">
        <h2 className="font-maru text-[24px] font-semibold text-ink mb-4">
          ❀ frequent questions
        </h2>
        <div className="space-y-5">
          {[
            { q: "is this audited?", a: "not yet by an external firm. mainnet launch is gated on that. internally we run 135 tests + slither + mythril + foundry fork tests, and have a recommendations matrix (R-1..R-13) that's all landed in the rc6 bytecode." },
            { q: "can it work for pairs other than USDC/WETH?", a: "yes — the architecture is pair-agnostic. the factory deploys a fresh vault/hook/relayer for any pair, and the hook's canonicalPairId works for any V4 pool. USDC pairs are easiest today because Circle CCTP gives us canonical USDC bridging out of the box. for non-USDC assets (e.g. USDT/WETH) we'd use Hyperlane warp routes — the chain registry has slots prepared, just not wired yet. volatile pairs also need Pyth + Chainlink coverage on both chains for the dual-oracle safety check." },
            { q: "what if the agent goes rogue?", a: "the worst it can do per cycle is shift 25% of total assets, with a 60-second cooldown, and only between chains the registry already enabled. it can't drain the vault, can't add new chains, can't change fee destination. user withdrawal path has no agent dependency." },
            { q: "what if anthropic blocks the api key?", a: "currently the swarm would stop until we rotate keys. the next big infra item is x402-funded LLM payments — the vault pays per-call via http 402 micropayments, so no single key-holder can unilaterally turn off the swarm. it's a planned upgrade, not live yet." },
            { q: "do my deposits sit on the destination chain forever?", a: "no. withdrawals can pull from either chain. if there's enough on base you withdraw synchronously. if not, the agent unwinds the position on ethereum and bridges back via cctp." },
            { q: "what's the fee?", a: "15% performance fee on the EXTRA yield above what a passive lp would have earned. you keep 85% of the alpha. no fee on principal, no fee on baseline lp earnings — only on the part mirv's rebalancing produces." },
            { q: "what's the slippage / impermanent loss story?", a: "you have all the normal impermanent loss exposure of being a usdc/weth lp on each chain. cross-chain rebalancing doesn't add new IL beyond what a single-chain lp would have. the swarm doesn't take impulsive directional bets; it moves capital toward the chain with more volume." },
            { q: "can i use this on mainnet today?", a: "no — testnet only. mainnet launch is gated on external audit and a treasury multisig setup. follow the github for updates." },
          ].map((f, i) => (
            <div key={i} className="frame-outer p-5">
              <p className="font-maru text-[15px] text-ink font-semibold mb-2">{f.q}</p>
              <p className="text-[14px] text-ink-soft leading-relaxed">{f.a}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ─── Footer ────────────────────────────────────────────────── */}
      <section className="mb-10 text-center text-[13px] text-ink-faint">
        <p className="mb-2">
          want the full architecture? <Link href="/analytics" className="underline text-pink-hot">parameters + safety set</Link> · {" "}
          <a className="underline text-pink-hot" href="https://github.com/sp0oby/mirv" target="_blank" rel="noopener noreferrer">source on github</a>
        </p>
        <p>mit licensed · not audited yet · no warranty</p>
      </section>
    </div>
  );
}
