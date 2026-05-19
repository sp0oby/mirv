import Link from "next/link";
import { Mascot } from "@/components/Mascot";

// Landing v2 — tighter, bigger, less explanatory. The original draft tried
// to explain the whole protocol on the splash; this one lets the design
// carry the personality and reserves the long-form explanation for /about.
// Hero is the dominant block (68vh+), three-card explainer is small and
// quiet, no "what mirv is NOT" wall.

export default function LandingPage() {
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
            deposit usdc on base. agents rebalance ur LP across ethereum + base.
            u keep the extra yield.
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
            audit candidate
          </div>
          <div
            className="stamp absolute bottom-8 -right-5 text-[14px] px-3 py-1.5"
            style={{ transform: "rotate(11deg)", color: "#3a2c3a" }}
          >
            rc6
          </div>
        </div>
      </section>

      {/* ─── 3-step quiet explainer ────────────────────────────────────── */}
      <section className="mt-24">
        <h2 className="font-maru text-[22px] font-semibold text-ink mb-8">
          ❀ &nbsp;how
        </h2>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          {[
            { n: "1", title: "deposit on base", body: "shares mint 1:1. vault splits via cctp.", bg: "#ffd1dc", tilt: -1 },
            { n: "2", title: "swarm rebalances", body: "agents move LP across chains on imbalance.", bg: "#bde0fe", tilt: 0.8 },
            { n: "3", title: "harvest extra", body: "you keep 85%, treasury takes 15% of the alpha.", bg: "#aaf0d1", tilt: -0.5 },
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

      {/* ─── Status strip ──────────────────────────────────────────────── */}
      <section className="mt-20 text-center">
        <p className="text-[14px] text-ink-faint">
          live on base sepolia + eth sepolia · audit candidate v1.0.0-rc6 ·{" "}
          <a href="https://github.com/sp0oby/mirv" className="underline text-pink-hot">
            source on github
          </a>
        </p>
      </section>
    </div>
  );
}
