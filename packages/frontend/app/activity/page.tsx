import { readRecentActivity, shortTx, type ActivityEvent } from "@/lib/contracts";

// Activity feed — live event stream from rc6 testnet. Each render queries
// the last hour of blocks on Base + Ethereum and merges the events into a
// unified feed. Server component, no wallet needed.
export const revalidate = 30;

const KIND_COLORS: Record<ActivityEvent["kind"], string> = {
  dispatch: "#ef48aa",
  execute:  "#aaf0d1",
  skip:     "#8b7a8b",
  notify:   "#a2d2ff",
  cap:      "#ffd206",
};

const KIND_TITLES: Record<ActivityEvent["kind"], string> = {
  dispatch: "rebalance dispatched",
  execute:  "rebalance executed",
  skip:     "skipped (zero-delta)",
  notify:   "sister notification received",
  cap:      "sister depth capped",
};

function scanLink(chain: "base" | "eth", tx: string): string {
  const host = chain === "base" ? "sepolia.basescan.org" : "sepolia.etherscan.io";
  return `https://${host}/tx/${tx}`;
}

function chainArrow(kind: ActivityEvent["kind"], chain: "base" | "eth"): string {
  if (kind === "dispatch" && chain === "base") return "Base → Ethereum";
  if (kind === "dispatch" && chain === "eth")  return "Ethereum → Base";
  if (kind === "execute") return "Ethereum (relayer)";
  if (kind === "skip")    return "Ethereum (no-op)";
  if (kind === "notify" && chain === "base") return "← from Ethereum hook";
  if (kind === "notify" && chain === "eth")  return "← from Base hook";
  if (kind === "cap" && chain === "base")    return "Base hook (sister cap)";
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
          everything the swarm + the contracts have done in the last hour.
          dispatches from each MirrorHook, deliveries on the Relayer, and
          inbound depth notifications on each hook's handle().
        </p>
      </header>

      {err && (
        <section className="frame-outer p-5 mb-8 bg-paper-warm">
          <p className="text-[14px] text-ink">⚠ public rpc was unreachable. retry in 30s.</p>
          <pre className="text-[11px] text-ink-faint mt-2 break-all">{err}</pre>
        </section>
      )}

      {!err && events.length === 0 && (
        <section className="frame-outer p-6 mb-8 text-center">
          <p className="text-[15px] text-ink-soft mb-2">
            no on-chain activity in the last hour.
          </p>
          <p className="text-[12px] text-ink-faint">
            this is normal — the swarm only dispatches when imbalance exceeds
            3% between chains, and testnet activity is sparse.
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
                  <span className="text-[12px] text-ink-faint font-mono">
                    block {e.block.toString()}
                  </span>
                </div>
                <p className="text-[13px] text-ink-soft leading-snug mb-2">
                  {chainArrow(e.kind, e.chain)}
                </p>
                <div className="flex flex-wrap items-center gap-2 text-[11px] font-mono text-ink-faint">
                  <a className="underline text-pink-hot" href={scanLink(e.chain, e.tx)} target="_blank" rel="noopener noreferrer">
                    {shortTx(e.tx)}
                  </a>
                  {e.msgId && (
                    <>
                      <span>·</span>
                      <span>msg {shortTx(e.msgId)}</span>
                    </>
                  )}
                </div>
              </div>
            </div>
          </article>
        ))}
      </section>

      <p className="text-[12px] text-ink-faint">
        feed scans the last ~1h of blocks on each chain via public RPC. 30s page cache.
      </p>
    </div>
  );
}
