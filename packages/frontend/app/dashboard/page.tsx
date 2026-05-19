import Link from "next/link";
import { CycleCountdown } from "@/components/CycleCountdown";
import { readDashboardState, readRecentActivity, formatUsdc, timeAgo, shortTx, ADDR } from "@/lib/contracts";

// Dashboard — server component, all reads happen on the build server / on the
// Vercel edge runtime. Each user request triggers a single batch of RPC reads
// (via Promise.all in readDashboardState), then the rendered HTML is cached
// for `revalidate` seconds. Cheap and live-ish.
export const revalidate = 30;

export default async function DashboardPage() {
  let state: Awaited<ReturnType<typeof readDashboardState>> | null = null;
  let activity: Awaited<ReturnType<typeof readRecentActivity>> = [];
  let readError: string | null = null;

  try {
    [state, activity] = await Promise.all([readDashboardState(), readRecentActivity()]);
  } catch (err) {
    readError = err instanceof Error ? err.message : String(err);
  }

  const tvlUsd       = state ? Number(formatUsdc(state.totalAssets).replace(/,/g, "")) : 0;
  const sharePrice   = state && state.totalSupply > 0n ? Number(state.totalAssets) / Number(state.totalSupply) : 1;
  const baseDepthUsdc = state ? Number(state.baseDepth) / 1e18 : 0;
  const ethDepthUsdc  = state ? Number(state.ethDepth)  / 1e18 : 0;
  const baseAlloc    = state ? Number(state.baseAllocBps) / 100 : 0;
  const ethAlloc     = state ? Number(state.ethAllocBps)  / 100 : 0;
  const dispatches   = activity.filter((e) => e.kind === "dispatch" || e.kind === "execute" || e.kind === "skip").slice(0, 5);

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          dashboard
        </h1>
        <p className="text-[16px] text-ink-soft">
          live state from base sepolia + ethereum sepolia rc6 contracts. refreshes every 30s.
        </p>
      </header>

      {readError && (
        <section className="frame-outer p-5 mb-8 bg-paper-warm">
          <p className="text-[14px] text-ink">
            ⚠ couldn't reach a public rpc endpoint just now. retry in 30s, or check the contracts directly on{" "}
            <a className="underline text-pink-hot" href={`https://sepolia.basescan.org/address/${ADDR.base.vault}`}>basescan</a>.
          </p>
          <pre className="text-[11px] text-ink-faint mt-2 break-all">{readError}</pre>
        </section>
      )}

      {/* ─── Headline stats ─────────────────────────────────────────────── */}
      <section className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-12">
        <div className="frame-outer p-6" style={{ transform: "rotate(-0.5deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✿ total mirrored
          </p>
          <p className="pixel text-[44px] text-ink leading-tight">
            ${tvlUsd.toLocaleString(undefined, { maximumFractionDigits: 2 })}
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            vault.totalAssets() · usdc
          </p>
        </div>

        <div className="frame-outer p-6 bg-paper-warm" style={{ transform: "rotate(0.6deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ❀ extra apy (7d)
          </p>
          <p className="pixel text-[44px] text-ink leading-tight">—</p>
          <p className="text-[13px] text-ink-soft mt-1">
            {state && state.lastHarvest === 0n ? "no harvest yet" : `last harvest ${state ? timeAgo(state.lastHarvest) : "—"}`}
          </p>
        </div>

        <div className="frame-outer p-6" style={{ transform: "rotate(-0.4deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✦ swarm
          </p>
          <p className="pixel text-[44px] text-ink leading-tight inline-flex items-center gap-2">
            {state?.paused ? "paused" : "calm"}
            <span className={state?.paused ? "w-3 h-3 rounded-full bg-pink-hot inline-block" : "w-3 h-3 rounded-full bg-mint-deep animate-heartbeat inline-block"} />
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            {state && state.lastUpdate > 0n ? `last update ${timeAgo(state.lastUpdate)}` : "no agent reports yet"}
          </p>
        </div>
      </section>

      {/* ─── Share price + cycle countdown ─────────────────────────────── */}
      <section className="grid grid-cols-1 md:grid-cols-[1fr_1fr] gap-6 mb-12">
        <div className="frame-outer p-6 bg-paper-warm" style={{ transform: "rotate(-0.3deg)" }}>
          <p className="font-maru text-[12px] uppercase tracking-wider text-ink-faint mb-1">
            ✿ share price
          </p>
          <p className="pixel text-[40px] text-ink leading-tight">
            {sharePrice.toFixed(6)}
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            1 mirvUSDC = ${sharePrice.toFixed(6)} usdc
          </p>
          <p className="text-[11px] text-ink-faint mt-2">
            totalAssets / totalSupply. {state?.totalSupply === 0n && "(no shares minted yet)"}
          </p>
        </div>

        <CycleCountdown />
      </section>

      {/* ─── Per-chain depth ───────────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ❀ per-chain depth + allocation
        </h2>
        <div className="space-y-3">
          {[
            { chain: "Base Sepolia",     depth: baseDepthUsdc, alloc: baseAlloc, color: "#ffd1dc", liquidity: state?.baseLiquidity },
            { chain: "Ethereum Sepolia", depth: ethDepthUsdc,  alloc: ethAlloc,  color: "#bde0fe", liquidity: state?.ethLiquidity },
          ].map((c) => (
            <div key={c.chain} className="frame-outer p-5">
              <div className="flex items-center justify-between mb-2">
                <span className="font-maru text-[16px] text-ink font-semibold">{c.chain}</span>
                <span className="font-mono text-[13px] text-ink-soft">
                  target {c.alloc.toFixed(0)}% · localDepthUsd ${c.depth.toLocaleString(undefined, { maximumFractionDigits: 0 })}
                </span>
              </div>
              <div className="h-3 rounded-full overflow-hidden bg-paper-deep border border-ink-soft/40">
                <div
                  className="h-full"
                  style={{
                    width: `${Math.min(100, (c.depth / Math.max(baseDepthUsdc, ethDepthUsdc, 1)) * 100)}%`,
                    background: c.color,
                  }}
                />
              </div>
              <p className="text-[12px] text-ink-faint mt-1.5">
                v4 pool liquidity: <span className="font-mono">{c.liquidity?.toString() ?? "—"}</span>
              </p>
            </div>
          ))}
        </div>
        <p className="text-[12px] text-ink-faint mt-3">
          imbalance fires above 3%. localDepthUsd is unit-skewed on testnet
          because token-order differs from mainnet — mechanism works,
          magnitudes won't match mainnet semantics until per-pair oracle config.
        </p>
      </section>

      {/* ─── Health strip ──────────────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✦ health
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
          {state && [
            { label: "base hook ETH", value: `${(Number(state.baseHookEth) / 1e18).toFixed(4)} ETH`, ok: state.baseHookEth > 5_000_000_000_000_000n },
            { label: "eth hook ETH",  value: `${(Number(state.ethHookEth)  / 1e18).toFixed(4)} ETH`, ok: state.ethHookEth  > 5_000_000_000_000_000n },
            { label: "vault paused",  value: state.paused ? "yes ✗" : "no ✓", ok: !state.paused },
            { label: "base hook paused",  value: state.baseHookPaused ? "yes ✗" : "no ✓", ok: !state.baseHookPaused },
            { label: "eth hook paused",   value: state.ethHookPaused  ? "yes ✗" : "no ✓", ok: !state.ethHookPaused },
            { label: "dispatch cooldown", value: `${Number(state.baseDispatchCooldown)}s`, ok: true },
          ].map((h, i) => (
            <div
              key={h.label}
              className="frame-outer p-4"
              style={{ transform: `rotate(${[0.4, -0.3, 0.5, -0.4, 0.2, -0.5][i % 6]}deg)` }}
            >
              <div className="flex items-baseline gap-2 mb-1">
                <span className={h.ok ? "w-2 h-2 rounded-full bg-mint-deep" : "w-2 h-2 rounded-full bg-pink-hot"} aria-hidden />
                <p className="font-maru text-[11px] uppercase tracking-wider text-ink-faint">
                  {h.label}
                </p>
              </div>
              <p className="font-mono text-[14px] text-ink leading-tight">{h.value}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ─── Recent dispatches ─────────────────────────────────────────── */}
      <section className="mb-10">
        <div className="flex items-baseline justify-between mb-5">
          <h2 className="font-maru text-[20px] font-semibold text-ink">
            ❀ recent dispatches
          </h2>
          <Link href="/activity" className="text-[14px] text-pink-hot underline">
            full feed →
          </Link>
        </div>
        {dispatches.length === 0 ? (
          <div className="frame-outer p-5">
            <p className="text-[14px] text-ink-soft">
              no dispatches in the last hour. the swarm fires when imbalance
              between chains exceeds 3%.
            </p>
          </div>
        ) : (
          <div className="frame-outer p-2">
            <table className="w-full text-[14px]">
              <thead className="text-ink-faint text-[12px] uppercase tracking-wider">
                <tr>
                  <th className="text-left px-4 py-2 font-maru font-normal">tx</th>
                  <th className="text-left px-4 py-2 font-maru font-normal">chain</th>
                  <th className="text-left px-4 py-2 font-maru font-normal">kind</th>
                  <th className="text-right px-4 py-2 font-maru font-normal">block</th>
                </tr>
              </thead>
              <tbody>
                {dispatches.map((d) => {
                  const scanHost = d.chain === "base" ? "sepolia.basescan.org" : "sepolia.etherscan.io";
                  return (
                    <tr key={d.id} className="border-t border-dotted border-ink-soft/30">
                      <td className="px-4 py-3 font-mono text-ink">
                        <a className="underline" href={`https://${scanHost}/tx/${d.tx}`} target="_blank" rel="noopener noreferrer">
                          {shortTx(d.tx)}
                        </a>
                      </td>
                      <td className="px-4 py-3 text-ink-soft">{d.chain}</td>
                      <td className="px-4 py-3 text-ink-soft">{d.kind}</td>
                      <td className="px-4 py-3 text-right text-ink-faint">{d.block.toString()}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <p className="text-[12px] text-ink-faint">
        all numbers above are live reads of the rc6 testnet contracts via public RPC. 30s cache.
      </p>
    </div>
  );
}
