import Link from "next/link";
import { CycleCountdown } from "@/components/CycleCountdown";

// Dashboard — read-only view of protocol state. No wallet needed.
// v0 uses sample data; v1 wires viem direct-RPC reads to
// MirrorVault.totalAssets / .principalTracked / .crossChainAssetsReported
// and MirrorHook.localDepthUsd on each chain. Public RPC endpoints from
// Alchemy testnet are fine since these are pure view calls.

// ─── Sample data — wire when ready ──────────────────────────────────────
const TVL_USD       = 8256;
const SHARE_PRICE   = 1.000000;
const EXTRA_APY_7D  = null;   // null = no harvest yet

const PER_CHAIN = [
  { chain: "Base Sepolia",     domain: 84532,    depthUsd: 8256, allocTarget: 60, allocActual: 60.0, color: "#ffd1dc" },
  { chain: "Ethereum Sepolia", domain: 11155111, depthUsd: 8256, allocTarget: 40, allocActual: 40.0, color: "#bde0fe" },
];

const RECENT_DISPATCHES = [
  { tx: "0x6e3bb567…7381", chain: "→ ETH",  pair: "ETH-USDC-V1", type: "rebalance",         time: "23m ago" },
  { tx: "0x49cb5e21…6e54", chain: "← Base", pair: "ETH-USDC-V1", type: "depth notify",      time: "26m ago" },
  { tx: "0xeee761e9…5f13", chain: "→ ETH",  pair: "ETH-USDC-V1", type: "skip (zero-delta)", time: "31m ago" },
];

const RECENT_HARVESTS: Array<{ tx: string; extraYieldUsd: number; feeSharesUsd: number; time: string }> = [
  // Empty for now — no harvests have run yet. Wire when MirrorVault.harvest fires.
];

const HEALTH = [
  { label: "hook ETH balance",     value: "0.0099 ETH",   status: "ok" as const, note: "enough for ~650 dispatches" },
  { label: "agent EOA balance",    value: "0.4 ETH base", status: "ok" as const, note: "1.5 ETH on ETH Sepolia"     },
  { label: "chainlink fresh (ETH)",value: "2m ago",       status: "ok" as const, note: "well under 1h threshold"    },
  { label: "pyth fresh (BASE)",    value: "8s ago",       status: "ok" as const, note: "conf within 1%"              },
  { label: "last cycle",           value: "2m ago",       status: "ok" as const, note: "swarm calm"                  },
  { label: "vault paused",         value: "no",           status: "ok" as const, note: "operational"                 },
];

export default function DashboardPage() {
  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          dashboard
        </h1>
        <p className="text-[16px] text-ink-soft">
          live state from base sepolia + ethereum sepolia.
        </p>
      </header>

      {/* ─── Headline stats ─────────────────────────────────────────────── */}
      <section className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-12">
        <div className="frame-outer p-6" style={{ transform: "rotate(-0.5deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✿ total mirrored
          </p>
          <p className="pixel text-[44px] text-ink leading-tight">
            ${TVL_USD.toLocaleString()}
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            usdc across 2 chains
          </p>
        </div>

        <div className="frame-outer p-6 bg-paper-warm" style={{ transform: "rotate(0.6deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ❀ extra apy (7d)
          </p>
          <p className="pixel text-[44px] text-ink leading-tight">
            {EXTRA_APY_7D ?? "—"}
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            {EXTRA_APY_7D ? "vs single-chain baseline" : "no harvest yet"}
          </p>
        </div>

        <div className="frame-outer p-6" style={{ transform: "rotate(-0.4deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✦ swarm
          </p>
          <p className="pixel text-[44px] text-ink leading-tight inline-flex items-center gap-2">
            calm
            <span className="w-3 h-3 rounded-full bg-mint-deep animate-heartbeat inline-block" />
          </p>
          <p className="text-[13px] text-ink-soft mt-1">last cycle 2m ago</p>
        </div>
      </section>

      {/* ─── Share price + cycle countdown ─────────────────────────────── */}
      <section className="grid grid-cols-1 md:grid-cols-[1fr_1fr] gap-6 mb-12">
        <div className="frame-outer p-6 bg-paper-warm" style={{ transform: "rotate(-0.3deg)" }}>
          <p className="font-maru text-[12px] uppercase tracking-wider text-ink-faint mb-1">
            ✿ share price
          </p>
          <p className="pixel text-[40px] text-ink leading-tight">
            {SHARE_PRICE.toFixed(6)}
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            1 mirvUSDC = ${SHARE_PRICE.toFixed(6)} usdc
          </p>
          <p className="text-[11px] text-ink-faint mt-2">
            derived from <code className="font-mono text-[11px]">totalAssets() / totalSupply()</code>.
            moves with cross-chain LP performance.
          </p>
        </div>

        <CycleCountdown />
      </section>

      {/* ─── Per-chain depth + allocation drift ────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ❀ per-chain depth + allocation
        </h2>
        <div className="space-y-3">
          {PER_CHAIN.map((c) => {
            const drift = c.allocActual - c.allocTarget;
            return (
              <div key={c.domain} className="frame-outer p-5">
                <div className="flex items-center justify-between mb-2">
                  <span className="font-maru text-[16px] text-ink font-semibold">{c.chain}</span>
                  <span className="font-mono text-[13px] text-ink-soft">
                    target {c.allocTarget}% · actual {c.allocActual.toFixed(1)}% ·
                    drift{" "}
                    <span
                      className={
                        Math.abs(drift) < 1
                          ? "text-mint-deep"
                          : Math.abs(drift) < 3
                          ? "text-ink"
                          : "text-pink-hot"
                      }
                    >
                      {drift > 0 ? "+" : ""}
                      {drift.toFixed(1)}%
                    </span>
                  </span>
                </div>
                <div className="h-3 rounded-full overflow-hidden bg-paper-deep border border-ink-soft/40">
                  <div
                    className="h-full"
                    style={{
                      width: `${(c.depthUsd / Math.max(...PER_CHAIN.map((x) => x.depthUsd))) * 100}%`,
                      background: c.color,
                    }}
                  />
                </div>
                <p className="text-[12px] text-ink-faint mt-1.5">
                  ${c.depthUsd.toLocaleString()} usdc
                </p>
              </div>
            );
          })}
        </div>
        <p className="text-[12px] text-ink-faint mt-3">
          imbalance = |left − right| / avg. dispatch fires above 3%.
        </p>
      </section>

      {/* ─── Health strip ──────────────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✦ health
        </h2>
        <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
          {HEALTH.map((h, i) => (
            <div
              key={h.label}
              className="frame-outer p-4"
              style={{ transform: `rotate(${[0.4, -0.3, 0.5, -0.4, 0.2, -0.5][i % 6]}deg)` }}
            >
              <div className="flex items-baseline gap-2 mb-1">
                <span
                  className={
                    h.status === "ok"
                      ? "w-2 h-2 rounded-full bg-mint-deep"
                      : "w-2 h-2 rounded-full bg-pink-hot"
                  }
                  aria-hidden
                />
                <p className="font-maru text-[11px] uppercase tracking-wider text-ink-faint">
                  {h.label}
                </p>
              </div>
              <p className="font-mono text-[14px] text-ink leading-tight">{h.value}</p>
              <p className="text-[11px] text-ink-soft mt-0.5 leading-tight">{h.note}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ─── Recent harvests ───────────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ✿ recent harvests
        </h2>
        {RECENT_HARVESTS.length === 0 ? (
          <div className="frame-outer p-5">
            <p className="text-[14px] text-ink-soft">
              no harvests yet — the vault has been live for less than the 1-day
              minimum interval and needs cross-chain yield to accrue first.
            </p>
            <p className="text-[12px] text-ink-faint mt-2">
              when a harvest fires it'll show extra-yield captured + fee
              shares minted to treasury here.
            </p>
          </div>
        ) : (
          <div className="frame-outer p-2">
            <table className="w-full text-[14px]">
              <thead className="text-ink-faint text-[12px] uppercase tracking-wider">
                <tr>
                  <th className="text-left px-4 py-2 font-maru font-normal">tx</th>
                  <th className="text-right px-4 py-2 font-maru font-normal">extra yield</th>
                  <th className="text-right px-4 py-2 font-maru font-normal">fee → treasury</th>
                  <th className="text-right px-4 py-2 font-maru font-normal">when</th>
                </tr>
              </thead>
              <tbody>
                {RECENT_HARVESTS.map((h) => (
                  <tr key={h.tx} className="border-t border-dotted border-ink-soft/30">
                    <td className="px-4 py-3 font-mono text-ink">{h.tx}</td>
                    <td className="px-4 py-3 text-right font-mono text-ink">${h.extraYieldUsd.toFixed(2)}</td>
                    <td className="px-4 py-3 text-right font-mono text-ink-soft">${h.feeSharesUsd.toFixed(2)}</td>
                    <td className="px-4 py-3 text-right text-ink-faint">{h.time}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* ─── Recent agent activity (compact) ───────────────────────────── */}
      <section className="mb-10">
        <div className="flex items-baseline justify-between mb-5">
          <h2 className="font-maru text-[20px] font-semibold text-ink">
            ❀ recent dispatches
          </h2>
          <Link href="/activity" className="text-[14px] text-pink-hot underline">
            full feed →
          </Link>
        </div>
        <div className="frame-outer p-2">
          <table className="w-full text-[14px]">
            <thead className="text-ink-faint text-[12px] uppercase tracking-wider">
              <tr>
                <th className="text-left px-4 py-2 font-maru font-normal">tx</th>
                <th className="text-left px-4 py-2 font-maru font-normal">direction</th>
                <th className="text-left px-4 py-2 font-maru font-normal">type</th>
                <th className="text-right px-4 py-2 font-maru font-normal">when</th>
              </tr>
            </thead>
            <tbody>
              {RECENT_DISPATCHES.map((d) => (
                <tr key={d.tx} className="border-t border-dotted border-ink-soft/30">
                  <td className="px-4 py-3 font-mono text-ink">{d.tx}</td>
                  <td className="px-4 py-3 text-ink-soft">{d.chain}</td>
                  <td className="px-4 py-3 text-ink-soft">{d.type}</td>
                  <td className="px-4 py-3 text-right text-ink-faint">{d.time}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <p className="text-[12px] text-ink-faint">
        sample numbers shown where live data isn't wired yet. live reads land in v1.
      </p>
    </div>
  );
}
