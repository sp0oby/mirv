import Link from "next/link";

// Dashboard — read-only view of protocol state. No wallet needed.
// v0 uses sample data inline; v1 will wire viem direct-RPC reads to
// MirrorVault.totalAssets / .principalTracked / .crossChainAssetsReported
// and MirrorHook.localDepthUsd on each chain. Public RPC endpoints from
// Alchemy testnet are fine since these are pure view calls.

const SAMPLE_PER_CHAIN = [
  { chain: "Base Sepolia",     domain: 84532,    depthUsd: 8256, alloc: 60, color: "#ffd1dc" },
  { chain: "Ethereum Sepolia", domain: 11155111, depthUsd: 8256, alloc: 40, color: "#bde0fe" },
];

const SAMPLE_DISPATCHES = [
  { tx: "0x6e3bb567…7381", chain: "→ ETH",  pair: "ETH-USDC-V1", type: "rebalance", time: "23m ago" },
  { tx: "0x49cb5e21…6e54", chain: "← Base", pair: "ETH-USDC-V1", type: "depth notify", time: "26m ago" },
  { tx: "0xeee761e9…5f13", chain: "→ ETH",  pair: "ETH-USDC-V1", type: "skip (zero-delta)", time: "31m ago" },
];

export default function DashboardPage() {
  const totalDepth = SAMPLE_PER_CHAIN.reduce((s, c) => s + c.depthUsd, 0);

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          dashboard
        </h1>
        <p className="text-[16px] text-ink-soft">
          live state from base sepolia + ethereum sepolia. v0 displays the sample numbers from
          our most recent end-to-end pipeline test (
          <Link href="/activity" className="underline text-pink-hot">activity feed</Link>{" "}
          has the receipts).
        </p>
      </header>

      {/* ─── Top row — headline stats ──────────────────────────────────── */}
      <section className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-12">
        <div className="frame-outer p-6" style={{ transform: "rotate(-0.5deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✿ total mirrored
          </p>
          <p className="pixel text-[44px] text-ink leading-tight">${totalDepth.toLocaleString()}</p>
          <p className="text-[13px] text-ink-soft mt-1">
            usdc across 2 chains
          </p>
        </div>

        <div className="frame-outer p-6 bg-paper-warm" style={{ transform: "rotate(0.6deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ❀ extra apy (7d)
          </p>
          <p className="pixel text-[44px] text-ink leading-tight">—</p>
          <p className="text-[13px] text-ink-soft mt-1">no harvest yet</p>
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

      {/* ─── Per-chain depth bars ──────────────────────────────────────── */}
      <section className="mb-12">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">
          ❀ per-chain depth
        </h2>
        <div className="space-y-3">
          {SAMPLE_PER_CHAIN.map((c) => (
            <div key={c.domain} className="frame-outer p-5">
              <div className="flex items-center justify-between mb-2">
                <span className="font-maru text-[16px] text-ink font-semibold">{c.chain}</span>
                <span className="font-mono text-[13px] text-ink-soft">
                  {c.alloc}% target · depth ${c.depthUsd.toLocaleString()}
                </span>
              </div>
              <div className="h-3 rounded-full overflow-hidden bg-paper-deep border border-ink-soft/40">
                <div
                  className="h-full"
                  style={{
                    width: `${(c.depthUsd / Math.max(...SAMPLE_PER_CHAIN.map((x) => x.depthUsd))) * 100}%`,
                    background: c.color,
                  }}
                />
              </div>
            </div>
          ))}
        </div>
        <p className="text-[12px] text-ink-faint mt-3">
          imbalance = |left − right| / avg. dispatch fires above 3%.
        </p>
      </section>

      {/* ─── Recent agent activity ─────────────────────────────────────── */}
      <section className="mb-8">
        <div className="flex items-baseline justify-between mb-5">
          <h2 className="font-maru text-[20px] font-semibold text-ink">
            ✦ recent dispatches
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
              {SAMPLE_DISPATCHES.map((d) => (
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
        v0 shows sample data. v1 wires viem RPC reads of `MirrorVault.totalAssets`,
        `MirrorHook.localDepthUsd`, and `RebalanceDispatched` event logs against
        the rc6 testnet deployment.
      </p>
    </div>
  );
}
