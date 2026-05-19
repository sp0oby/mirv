// Activity feed — the agent + cross-chain dispatch event stream.
// This is the page where the dark-chibi "predator pause → sharp dispatch"
// motion register earns its keep — long calm intervals, then a row drops in
// with a small accent on the type column. Not implemented as motion yet
// (v0 just lists), but the data shape is sized for that.

const SAMPLE_EVENTS = [
  {
    id: 1,
    kind: "dispatch",
    src: "Base Sepolia",
    dst: "Ethereum Sepolia",
    pair: "ETH-USDC-V1",
    msgId: "0x6e3bb567…7381",
    detail: "agent rebalance: +1e6 USDC / +1e6 WETH wei, tickRange [199740, 199860]",
    delivered: true,
    deltaKind: "execute",
    when: "23m ago",
  },
  {
    id: 2,
    kind: "skip",
    src: "Base Sepolia",
    dst: "Ethereum Sepolia",
    pair: "ETH-USDC-V1",
    msgId: "0xeee761e9…5f13",
    detail: "zero-delta depth notification — rc6 short-circuit fired",
    delivered: true,
    deltaKind: "skipped",
    when: "31m ago",
  },
  {
    id: 3,
    kind: "notify",
    src: "Ethereum Sepolia",
    dst: "Base Sepolia",
    pair: "ETH-USDC-V1",
    msgId: "0x49cb5e21…6e54",
    detail: "sister depth update: $8,256 → stored",
    delivered: true,
    deltaKind: "inbound",
    when: "26m ago",
  },
  {
    id: 4,
    kind: "lp-add",
    src: "Base Sepolia",
    dst: "—",
    pair: "ETH-USDC-V1",
    msgId: "—",
    detail: "bootstrap LP seeded at liquidity 2,000,000,000",
    delivered: true,
    deltaKind: "bootstrap",
    when: "42m ago",
  },
];

const KIND_COLORS: Record<string, string> = {
  dispatch: "#ef48aa",
  skip: "#8b7a8b",
  notify: "#a2d2ff",
  "lp-add": "#aaf0d1",
};

export default function ActivityPage() {
  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          activity
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          everything the swarm + the contracts have done. dispatch events
          from each MirrorHook, delivery confirmations from each Relayer /
          handle(), and the rc6 zero-delta short-circuits.
        </p>
      </header>

      <section className="space-y-3 mb-10">
        {SAMPLE_EVENTS.map((e, i) => (
          <article
            key={e.id}
            className="frame-outer p-5"
            style={{ transform: `rotate(${i % 2 === 0 ? -0.3 : 0.3}deg)` }}
          >
            <div className="flex items-start gap-4">
              <div
                className="shrink-0 w-3 h-3 rounded-full mt-2"
                style={{ background: KIND_COLORS[e.kind] }}
                aria-hidden
              />
              <div className="flex-1">
                <div className="flex items-baseline justify-between gap-3 mb-1">
                  <span className="font-maru text-[15px] font-semibold text-ink">
                    {e.src} <span className="text-ink-faint mx-1">→</span> {e.dst}
                  </span>
                  <span className="text-[12px] text-ink-faint">{e.when}</span>
                </div>
                <p className="text-[14px] text-ink-soft leading-snug mb-2">
                  {e.detail}
                </p>
                <div className="flex flex-wrap items-center gap-2 text-[11px] font-mono text-ink-faint">
                  <span>msg {e.msgId}</span>
                  <span>·</span>
                  <span>{e.pair}</span>
                  {e.delivered && (
                    <>
                      <span>·</span>
                      <span className="text-mint-deep">delivered ✓</span>
                    </>
                  )}
                </div>
              </div>
            </div>
          </article>
        ))}
      </section>

      <p className="text-[12px] text-ink-faint">
        v0 shows sample data drawn from the actual live txs in the rc6
        validation. v1 streams `RebalanceDispatched` / `MessageReceived` /
        `RebalanceExecuted` / `RebalanceSkippedZeroDelta` event logs in real
        time via `viem.watchContractEvent`.
      </p>
    </div>
  );
}
