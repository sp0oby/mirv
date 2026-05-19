import Link from "next/link";
import { CycleCountdown } from "@/components/CycleCountdown";
import { readDashboardState, readRecentActivity, formatUsdc, timeAgo, shortTx, ADDR, deriveSwarmStatus } from "@/lib/contracts";

export const revalidate = 30;

export const metadata = {
  title: "dashboard",
  description: "live state of the mirv vault — total mirrored, share price, per-chain allocation, agent activity. refreshes every 30s.",
};

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
  const baseAllocUsd = state ? Number(state.totalAssets - state.crossChain) / 1e6 : 0;
  const ethAllocUsd  = state ? Number(state.crossChain) / 1e6 : 0;
  const baseAlloc    = state ? Number(state.baseAllocBps) / 100 : 0;
  const ethAlloc     = state ? Number(state.ethAllocBps)  / 100 : 0;
  const dispatches   = activity.filter((e) => e.kind === "dispatch" || e.kind === "execute" || e.kind === "skip").slice(0, 5);
  const swarm        = deriveSwarmStatus({
    paused: state?.paused,
    lastUpdate: state?.lastUpdate,
    rpcReachable: state != null,
  });

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          dashboard
        </h1>
        <p className="text-[16px] text-ink-soft">
          what the mirror is doing right now.
        </p>
      </header>

      {readError && (
        <section className="frame-outer p-5 mb-8 bg-paper-warm">
          <p className="text-[14px] text-ink">
            couldn't reach the network just now. give it 30s and it'll come back. you can always check the vault directly on{" "}
            <a className="underline text-pink-hot" href={`https://sepolia.basescan.org/address/${ADDR.base.vault}`}>basescan</a>.
          </p>
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
            usdc held across both chains
          </p>
        </div>

        <div className="frame-outer p-6 bg-paper-warm" style={{ transform: "rotate(0.6deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ❀ extra yield (7d)
          </p>
          <p className="pixel text-[44px] text-ink leading-tight">0.0%</p>
          <p className="text-[13px] text-ink-soft mt-1">
            {state && state.lastHarvest === 0n ? "no swap fees on testnet yet — mainnet will earn from real volume" : `last earnings collected ${state ? timeAgo(state.lastHarvest) : "—"}`}
          </p>
        </div>

        <div className="frame-outer p-6" style={{ transform: "rotate(-0.4deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✦ swarm
          </p>
          <p className="pixel text-[44px] text-ink leading-tight inline-flex items-center gap-2">
            {swarm.status}
            <span className={
              swarm.status === "paused"  ? "w-3 h-3 rounded-full bg-pink-hot inline-block" :
              swarm.status === "idle"    ? "w-3 h-3 rounded-full bg-marigold inline-block" :
              swarm.status === "offline" ? "w-3 h-3 rounded-full bg-ink-faint inline-block" :
              swarm.status === "active"  ? "w-3 h-3 rounded-full bg-mint-deep animate-heartbeat inline-block" :
                                           "w-3 h-3 rounded-full bg-mint-deep inline-block"
            } />
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            {state && state.lastUpdate > 0n ? `last check-in ${timeAgo(state.lastUpdate)}` : "waiting for first check-in"}
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
            ${sharePrice.toFixed(4)}
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            each share redeems for ${sharePrice.toFixed(4)} usdc
          </p>
          {state?.totalSupply === 0n && (
            <p className="text-[11px] text-ink-faint mt-2">
              no one's deposited yet · share price starts at $1.00
            </p>
          )}
        </div>

        <CycleCountdown />
      </section>

      {/* ─── Per-chain allocation ──────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ❀ how much usdc is on each chain
        </h2>
        <div className="space-y-3">
          {[
            { chain: "Base",     amount: baseAllocUsd, target: baseAlloc, color: "#ffd1dc" },
            { chain: "Ethereum", amount: ethAllocUsd,  target: ethAlloc,  color: "#bde0fe" },
          ].map((c) => (
            <div key={c.chain} className="frame-outer p-5">
              <div className="flex items-center justify-between mb-2">
                <span className="font-maru text-[16px] text-ink font-semibold">{c.chain}</span>
                <span className="font-mono text-[13px] text-ink-soft">
                  target {c.target.toFixed(0)}% · ${c.amount.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                </span>
              </div>
              <div className="h-3 rounded-full overflow-hidden bg-paper-deep border border-ink-soft/40">
                <div
                  className="h-full"
                  style={{
                    width: `${Math.min(100, (c.amount / Math.max(baseAllocUsd, ethAllocUsd, 1)) * 100)}%`,
                    background: c.color,
                  }}
                />
              </div>
            </div>
          ))}
        </div>
        <p className="text-[12px] text-ink-faint mt-3">
          the swarm shifts usdc between chains when one side drifts more than 3% off target. testnet liquidity is small — mechanism validates, mainnet seeding will land actual depth.
        </p>
      </section>

      {/* ─── Competitiveness vs canonical pool ─────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✦ how competitive are we against the canonical pool
        </h2>
        <p className="text-[13px] text-ink-soft mb-4 max-w-[64ch]">
          our pool vs the canonical (no-hook) Uniswap USDC/WETH pool on the same chain. routers only quote pools deep enough to be competitive — if we're at &lt; 10% we need more seed depth, not more rebalancing.
        </p>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          {state && [
            { chain: "Base",     pct: state.baseCompetitivenessPct, ourL: state.baseLiquidity, theirL: state.baseCanonicalLiquidity },
            { chain: "Ethereum", pct: state.ethCompetitivenessPct,  ourL: state.ethLiquidity,  theirL: state.ethCanonicalLiquidity  },
          ].map((c) => {
            const noReference = c.pct === null;
            const ok = !noReference && c.pct! >= 10;
            return (
              <div key={c.chain} className="frame-outer p-5">
                <div className="flex items-center justify-between mb-2">
                  <span className="font-maru text-[15px] text-ink font-semibold">{c.chain}</span>
                  <span className={`font-mono text-[13px] ${noReference ? "text-ink-faint" : ok ? "text-mint-deep" : "text-pink-hot"}`}>
                    {noReference
                      ? "no reference"
                      : c.pct! < 0.01
                        ? "< 0.01%"
                        : `${c.pct!.toFixed(c.pct! < 1 ? 4 : 2)}%`}
                  </span>
                </div>
                <div className="h-2 rounded-full overflow-hidden bg-paper-deep border border-ink-soft/40 mb-2">
                  <div className="h-full" style={{
                    width: noReference ? "100%" : `${Math.min(100, c.pct!)}%`,
                    background: noReference ? "#c9c1c9" : ok ? "#aaf0d1" : "#ef48aa",
                  }} />
                </div>
                <p className="text-[11px] text-ink-faint font-mono">
                  our L: {c.ourL.toString()} · canonical L: {c.theirL.toString()}
                </p>
              </div>
            );
          })}
        </div>
        <p className="text-[12px] text-ink-faint mt-3">
          the swarm reads this every cycle. if competitiveness on any chain is below 10%, it flags "seed depth needed" rather than rebalancing dust. on testnet, the canonical Uniswap pool is often empty too (no one seeds testnet pools at scale) — comparison is meaningful at mainnet.
        </p>
      </section>

      {/* ─── Health strip ──────────────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✦ system health
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
          {state && [
            { label: "base relayer gas", value: `${(Number(state.baseHookEth) / 1e18).toFixed(4)} ETH`, ok: state.baseHookEth > 5_000_000_000_000_000n },
            { label: "ethereum relayer gas",  value: `${(Number(state.ethHookEth)  / 1e18).toFixed(4)} ETH`, ok: state.ethHookEth  > 5_000_000_000_000_000n },
            { label: "deposits + withdrawals",  value: state.paused ? "frozen" : "open", ok: !state.paused },
            { label: "base mirror",  value: state.baseHookPaused ? "paused" : "live", ok: !state.baseHookPaused },
            { label: "ethereum mirror",   value: state.ethHookPaused  ? "paused" : "live", ok: !state.ethHookPaused },
            { label: "min time between rebalances", value: `${Number(state.baseDispatchCooldown)}s`, ok: true },
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

      {/* ─── Recent rebalances ─────────────────────────────────────────── */}
      <section className="mb-10">
        <div className="flex items-baseline justify-between mb-5">
          <h2 className="font-maru text-[20px] font-semibold text-ink">
            ❀ recent rebalances
          </h2>
          <Link href="/activity" className="text-[14px] text-pink-hot underline">
            see everything →
          </Link>
        </div>
        {dispatches.length === 0 ? (
          <div className="frame-outer p-5">
            <p className="text-[14px] text-ink-soft">
              the chains are in sync. nothing to do in the last hour.
            </p>
          </div>
        ) : (
          <div className="frame-outer p-2">
            <table className="w-full text-[14px]">
              <thead className="text-ink-faint text-[12px] uppercase tracking-wider">
                <tr>
                  <th className="text-left px-4 py-2 font-maru font-normal">receipt</th>
                  <th className="text-left px-4 py-2 font-maru font-normal">on</th>
                  <th className="text-left px-4 py-2 font-maru font-normal">what happened</th>
                </tr>
              </thead>
              <tbody>
                {dispatches.map((d) => {
                  const scanHost = d.chain === "base" ? "sepolia.basescan.org" : "sepolia.etherscan.io";
                  const chainName = d.chain === "base" ? "Base" : "Ethereum";
                  const kindLabel = d.kind === "dispatch" ? "rebalance started" : d.kind === "execute" ? "rebalance delivered" : "no change needed";
                  return (
                    <tr key={d.id} className="border-t border-dotted border-ink-soft/30">
                      <td className="px-4 py-3 font-mono text-ink">
                        <a className="underline" href={`https://${scanHost}/tx/${d.tx}`} target="_blank" rel="noopener noreferrer">
                          {shortTx(d.tx)}
                        </a>
                      </td>
                      <td className="px-4 py-3 text-ink-soft">{chainName}</td>
                      <td className="px-4 py-3 text-ink-soft">{kindLabel}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <p className="text-[12px] text-ink-faint">
        live · refreshes every 30s · running on testnet
      </p>
    </div>
  );
}
