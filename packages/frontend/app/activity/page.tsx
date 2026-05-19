import { readRecentActivity, shortTx, type ActivityEvent } from "@/lib/contracts";

export const revalidate = 30;

const KIND_COLORS: Record<ActivityEvent["kind"], string> = {
  dispatch: "#ef48aa",
  execute:  "#aaf0d1",
  skip:     "#8b7a8b",
  notify:   "#a2d2ff",
  cap:      "#ffd206",
};

const KIND_TITLES: Record<ActivityEvent["kind"], string> = {
  dispatch: "rebalance started",
  execute:  "rebalance delivered",
  skip:     "no change needed",
  notify:   "depth update received",
  cap:      "depth update capped (safety)",
};

function scanLink(chain: "base" | "eth", tx: string): string {
  const host = chain === "base" ? "sepolia.basescan.org" : "sepolia.etherscan.io";
  return `https://${host}/tx/${tx}`;
}

function chainArrow(kind: ActivityEvent["kind"], chain: "base" | "eth"): string {
  if (kind === "dispatch" && chain === "base") return "Base → Ethereum";
  if (kind === "dispatch" && chain === "eth")  return "Ethereum → Base";
  if (kind === "execute") return "delivered on Ethereum";
  if (kind === "skip")    return "drift too small to act on";
  if (kind === "notify" && chain === "base") return "got an update from Ethereum";
  if (kind === "notify" && chain === "eth")  return "got an update from Base";
  if (kind === "cap" && chain === "base")    return "safety cap on Base";
  return chain;
}

export default async function ActivityPage() {
  let events: ActivityEvent[] = [];
  let err: string | null = null;
  try {
    events = await readRecentActivity();
  } catch (e) {
    err = e instanceof Error ? e.message : String(e);
  }

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          activity
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          everything the swarm has done in the last hour. every rebalance,
          every cross-chain update, every safety cap — in plain order.
        </p>
      </header>

      {err && (
        <section className="frame-outer p-5 mb-8 bg-paper-warm">
          <p className="text-[14px] text-ink">couldn't reach the network just now. give it 30s and it'll come back.</p>
        </section>
      )}

      {!err && events.length === 0 && (
        <section className="frame-outer p-6 mb-8 text-center">
          <p className="text-[15px] text-ink-soft mb-2">
            quiet hour — nothing's happened in the last 60 minutes.
          </p>
          <p className="text-[12px] text-ink-faint">
            the swarm only acts when the chains drift more than 3% apart, so calm stretches are the norm.
          </p>
        </section>
      )}

      <section className="space-y-3 mb-10">
        {events.map((e, i) => (
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
                    {KIND_TITLES[e.kind]}
                  </span>
                </div>
                <p className="text-[13px] text-ink-soft leading-snug mb-2">
                  {chainArrow(e.kind, e.chain)}
                </p>
                <div className="flex flex-wrap items-center gap-2 text-[11px] font-mono text-ink-faint">
                  <a className="underline text-pink-hot" href={scanLink(e.chain, e.tx)} target="_blank" rel="noopener noreferrer">
                    view receipt {shortTx(e.tx)}
                  </a>
                </div>
              </div>
            </div>
          </article>
        ))}
      </section>

      <p className="text-[12px] text-ink-faint">
        live · last hour · refreshes every 30s
      </p>
    </div>
  );
}
