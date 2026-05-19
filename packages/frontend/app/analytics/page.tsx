export const metadata = {
  title: "analytics",
  description: "the rules that govern the mirror, the safety set, and recent milestones.",
};

const PARAMS = [
  { label: "performance fee",       value: "15%",       note: "taken only from extra yield earned" },
  { label: "earnings collected",    value: "once a day", note: "rolled into share price" },
  { label: "withdrawal escape hatch", value: "24h",     note: "always be able to leave" },
  { label: "treasury change delay", value: "24h",       note: "fee destination can't change instantly" },
  { label: "price safety check",    value: "5%",        note: "two independent price feeds must agree" },
  { label: "noise filter",          value: "10× prior", note: "blocks impossible jumps from other chain" },
  { label: "max move per rebalance",value: "25%",       note: "limits damage if the swarm misbehaves" },
  { label: "stale data cutoff",     value: "1h",        note: "ignores updates older than this" },
];

const HISTORY = [
  { date: "2026-05-18", event: "added a small-drift shortcut so the swarm doesn't waste gas on tiny moves" },
  { date: "2026-05-18", event: "redeployed both chains with the full safety set turned on" },
  { date: "2026-05-18", event: "first real cross-chain rebalance landed end-to-end on testnet" },
  { date: "2026-05-17", event: "contracts deployed on Base and Ethereum testnets" },
  { date: "2026-05-17", event: "passed all internal safety reviews" },
];

export default function AnalyticsPage() {
  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          analytics
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          the rules that govern the mirror, and what's been happening lately.
          charts will land once there's enough history to plot — fake graphs
          are worse than no graphs.
        </p>
      </header>

      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ❀ the rules
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {PARAMS.map((k, i) => (
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

      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✿ safety
        </h2>
        <div className="frame-outer p-6 bg-paper-warm">
          <ul className="text-[14px] text-ink-soft space-y-2 leading-snug">
            <li>every move the swarm makes is bounded — it can't drain the vault, even if it's compromised.</li>
            <li>two independent price feeds have to agree before anything moves, within 5% of each other.</li>
            <li>updates from the other chain that look impossible (10× any prior reading) get ignored.</li>
            <li>any change to where fees go is delayed 24 hours, so you have time to leave first.</li>
            <li>you can always start a withdrawal — there is no admin override.</li>
            <li>the full test suite passes (105 unit tests + 30 fork tests on live state).</li>
            <li>not yet audited by an external firm. mainnet is gated on that.</li>
          </ul>
        </div>
      </section>

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
