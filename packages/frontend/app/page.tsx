import Link from "next/link";
import { Mascot } from "@/components/Mascot";
import { readDashboardState, formatUsdc, timeAgo } from "@/lib/contracts";

export const revalidate = 30;

export default async function LandingPage() {
  let state: Awaited<ReturnType<typeof readDashboardState>> | null = null;
  try { state = await readDashboardState(); } catch { /* fall back to dashes */ }

  const tvlUsd = state ? Number(formatUsdc(state.totalAssets).replace(/,/g, "")) : null;
  const cycleAgo = state && state.lastUpdate > 0n ? timeAgo(state.lastUpdate) : null;

  return (
    <div className="pt-4">
      {/* ─── Hero ──────────────────────────────────────────────────────── */}
      <section className="relative grid grid-cols-1 md:grid-cols-[1.5fr_1fr] gap-12 items-center min-h-[68vh] pt-8">
        <div>
          <p className="font-maru text-[18px] text-pink-hot mb-6 tracking-wide">
            ✿ deposit once, mirror everywhere
          </p>
          <h1
            className="display-title text-[88px] md:text-[128px] leading-[0.92] mb-7"
            style={{ letterSpacing: "-0.025em" }}
          >
            cross-chain
            <br />
            <span style={{ color: "#ef48aa" }}>liquidity</span>
            <br />
            mirror.
          </h1>
          <p className="text-[20px] text-ink-soft max-w-[44ch] leading-snug mb-9">
            deposit usdc on base. agents move your money where it earns more,
            across base + ethereum. you keep most of the extra.
          </p>

          <div className="flex flex-wrap gap-4">
            <Link href="/deposit" className="btn-win95 btn-win95-primary text-[16px] px-7 py-3.5">
              deposit
            </Link>
            <Link href="/dashboard" className="btn-win95 text-[16px] px-7 py-3.5">
              see live state
            </Link>
          </div>
        </div>

        <div className="relative mx-auto md:mx-0 md:ml-auto">
          <div
            className="frame-outer p-4 inline-block bg-paper-warm"
            style={{ transform: "rotate(3deg)" }}
          >
            <div className="bg-paper-deep p-6 rounded-stamp">
              <Mascot size={260} />
            </div>
            <div className="pt-3 pb-1 px-1 text-center">
              <p className="font-display text-[20px] text-ink">miri</p>
            </div>
          </div>
          <div
            className="stamp absolute -top-4 -left-6 text-[14px] px-3 py-1.5"
            style={{ transform: "rotate(-7deg)", color: "#d63b5e" }}
          >
            live on testnet
          </div>
        </div>
      </section>

      {/* ─── Live stat strip — same 3 cards as dashboard's headline row ── */}
      <section className="mt-12 grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="frame-outer p-6" style={{ transform: "rotate(-0.5deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✿ total mirrored
          </p>
          <p className="pixel text-[40px] text-ink leading-tight">
            {tvlUsd === null ? "—" : `$${tvlUsd.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
          </p>
          <p className="text-[13px] text-ink-soft mt-1">usdc across 2 chains</p>
        </div>

        <div className="frame-outer p-6 bg-paper-warm" style={{ transform: "rotate(0.6deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ❀ extra yield (7d)
          </p>
          <p className="pixel text-[40px] text-ink leading-tight">0.0%</p>
          <p className="text-[13px] text-ink-soft mt-1">testnet · earns from real volume on mainnet</p>
        </div>

        <div className="frame-outer p-6" style={{ transform: "rotate(-0.4deg)" }}>
          <p className="font-maru text-[13px] text-ink-faint uppercase tracking-wider mb-1">
            ✦ swarm
          </p>
          <p className="pixel text-[40px] text-ink leading-tight inline-flex items-center gap-2">
            {state?.paused ? "paused" : "calm"}
            <span className={state?.paused ? "w-3 h-3 rounded-full bg-pink-hot inline-block" : "w-3 h-3 rounded-full bg-mint-deep animate-heartbeat inline-block"} />
          </p>
          <p className="text-[13px] text-ink-soft mt-1">
            {cycleAgo ? `last check-in ${cycleAgo}` : "waiting for first check-in"}
          </p>
        </div>
      </section>

      {/* ─── 3-step quiet explainer ────────────────────────────────────── */}
      <section className="mt-24">
        <h2 className="font-maru text-[22px] font-semibold text-ink mb-8">
          ❀ &nbsp;how
        </h2>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          {[
            { n: "1", title: "deposit on base", body: "your usdc goes into one vault. it's split across both chains for you.", bg: "#ffd1dc", tilt: -1 },
            { n: "2", title: "swarm rebalances", body: "agents move money to whichever chain is paying more, every 45 seconds.", bg: "#bde0fe", tilt: 0.8 },
            { n: "3", title: "you earn", body: "you keep 85% of the extra. the protocol takes 15% to stay alive.", bg: "#aaf0d1", tilt: -0.5 },
          ].map((c) => (
            <article
              key={c.n}
              className="frame-outer p-6"
              style={{ transform: `rotate(${c.tilt}deg)`, background: c.bg }}
            >
              <div className="flex items-baseline gap-3 mb-2">
                <span className="font-display text-[40px] text-ink leading-none">{c.n}</span>
                <h3 className="font-maru text-[18px] font-semibold text-ink">{c.title}</h3>
              </div>
              <p className="text-[15px] text-ink leading-snug">{c.body}</p>
            </article>
          ))}
        </div>
      </section>

      {/* ─── The swarm ─────────────────────────────────────────────────── */}
      <section className="mt-24">
        <h2 className="font-maru text-[22px] font-semibold text-ink mb-2">
          ✦ &nbsp;the swarm
        </h2>
        <p className="text-[15px] text-ink-soft mb-8 max-w-[60ch]">
          four agents work the chains 24/7. every 45 seconds they check what
          each side looks like, decide if there's a move worth making, and act.
        </p>

        <div className="grid grid-cols-1 md:grid-cols-4 gap-5">
          {[
            {
              tag: "monitor",
              count: "×2",
              title: "the readers",
              body:
                "one on each chain. they watch what's there and how much it's earning, and report back.",
              bg: "#ffd1dc",
              tilt: -1.2,
            },
            {
              tag: "rebalance",
              count: "×1",
              title: "the strategist",
              body:
                "compares the two chains. if one's clearly paying more, plans how much to move.",
              bg: "#bde0fe",
              tilt: 0.8,
            },
            {
              tag: "risk",
              count: "×1",
              title: "the veto",
              body:
                "double-checks every plan. blocks moves that are too big, badly priced, or too frequent.",
              bg: "#ffd206",
              tilt: -0.6,
            },
            {
              tag: "coordinator",
              count: "×1",
              title: "the hand",
              body:
                "the only one that signs transactions. moves the money once everyone else agrees.",
              bg: "#aaf0d1",
              tilt: 1.1,
            },
          ].map((a) => (
            <article
              key={a.tag}
              className="frame-outer p-5"
              style={{ transform: `rotate(${a.tilt}deg)`, background: a.bg }}
            >
              <div className="flex items-baseline justify-between mb-1.5">
                <p className="pixel text-[11px] text-ink-faint uppercase tracking-wider">
                  {a.tag}
                </p>
                <span className="font-display text-[14px] text-ink-soft">{a.count}</span>
              </div>
              <h3 className="font-maru text-[17px] font-semibold text-ink mb-2">{a.title}</h3>
              <p className="text-[13.5px] text-ink leading-snug">{a.body}</p>
            </article>
          ))}
        </div>

        <p className="text-[14px] text-ink-soft mt-6 max-w-[60ch]">
          every decision they make is public. see them on the{" "}
          <Link href="/activity" className="underline text-pink-hot">activity feed →</Link>
        </p>
      </section>

      {/* ─── Status strip ──────────────────────────────────────────────── */}
      <section className="mt-20 text-center">
        <p className="text-[14px] text-ink-faint">
          running on testnet · not audited yet · open source on{" "}
          <a href="https://github.com/sp0oby/mirv" className="underline text-pink-hot">
            github
          </a>
        </p>
      </section>
    </div>
  );
}
