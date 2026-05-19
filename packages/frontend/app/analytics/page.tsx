// Analytics — protocol metrics + transparency.
// v0 is text-and-table-only; v1 will add Recharts/Visx for the timeseries
// once we have enough history to plot. Charts on Day 1 with two data
// points read embarrassing — better to ship the truth than a fake graph.

const KPIS = [
  { label: "performance fee rate",  value: "15%",            note: "on extra-yield only" },
  { label: "harvest min interval",  value: "1 day",          note: "MIN_HARVEST_INTERVAL" },
  { label: "withdraw cancel delay", value: "24h",            note: "user escalation path" },
  { label: "treasury timelock",     value: "24h",            note: "R-5 rotation delay" },
  { label: "oracle deviation cap",  value: "5%",             note: "R-11 Pyth vs Chainlink" },
  { label: "sister depth cap",      value: "10× prior",      note: "R-13 noise bound" },
  { label: "max delta per update",  value: "25%",            note: "R-1 agent compromise gate" },
  { label: "cross-chain staleness", value: "1h",             note: "R-3 harvest freshness" },
];

const HISTORY = [
  { date: "2026-05-18", event: "rc6 zero-delta short-circuit live + new relayer deployed" },
  { date: "2026-05-18", event: "rc5 testnet redeployed with R-1..R-13 hardening" },
  { date: "2026-05-18", event: "live cross-chain pipeline validated end-to-end" },
  { date: "2026-05-17", event: "v5 contracts deployed on base sepolia + eth sepolia" },
  { date: "2026-05-17", event: "slither/mythril triage, 152→7 in-scope findings" },
];

export default function AnalyticsPage() {
  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          analytics
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          protocol parameters, hardening posture, and recent milestones.
          charts will land once we have more than two data points to plot —
          shipping fake graphs is worse than shipping none.
        </p>
      </header>

      {/* ─── KPIs / parameters ─────────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ❀ live parameters (on-chain at rc6)
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {KPIS.map((k, i) => (
            <div
              key={k.label}
              className="frame-outer p-4"
              style={{ transform: `rotate(${[0.6, -0.4, 0.3, -0.7][i % 4]}deg)` }}
            >
              <p className="font-maru text-[11px] text-ink-faint uppercase tracking-wider mb-1.5">
                {k.label}
              </p>
              <p className="pixel text-[22px] text-ink leading-none mb-1.5">{k.value}</p>
              <p className="text-[11px] text-ink-soft leading-tight">{k.note}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ─── Audit posture box ─────────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✿ audit posture
        </h2>
        <div className="frame-outer p-6 bg-paper-warm">
          <ul className="text-[14px] text-ink-soft space-y-2 leading-snug">
            <li><strong className="text-ink">forge test:</strong> 135/135 passing (105 unit/invariant + 30 fork)</li>
            <li><strong className="text-ink">slither:</strong> 7 high/medium in-scope findings, all pre-existing won't-fix patterns from v5 hardening</li>
            <li><strong className="text-ink">mythril:</strong> 34 SWC-101 false positives on Solidity 0.8+ (compiler-inserted overflow checks)</li>
            <li><strong className="text-ink">recommendations landed:</strong> R-1, R-2, R-3, R-5, R-7, R-10, R-11, R-12, R-13</li>
            <li><strong className="text-ink">documented (not coded):</strong> R-4, R-6, R-9 in <code className="font-mono text-[12px]">audits/OPERATIONS.md</code></li>
            <li><strong className="text-ink">deferred by design:</strong> R-8 (mitigated by R-5 timelock)</li>
            <li><strong className="text-ink">tag:</strong> <code className="font-mono text-[12px]">v1.0.0-rc6</code> — audit candidate, mainnet gated on external review</li>
          </ul>
        </div>
      </section>

      {/* ─── Recent milestones ─────────────────────────────────────────── */}
      <section>
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✦ recent
        </h2>
        <ol className="space-y-2 text-[14px]">
          {HISTORY.map((h, i) => (
            <li key={i} className="flex gap-4">
              <time className="font-mono text-ink-faint shrink-0 w-[100px]">{h.date}</time>
              <span className="text-ink-soft">{h.event}</span>
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}
