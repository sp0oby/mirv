"use client";

import Link from "next/link";
import { Mascot } from "./Mascot";

// Footer is where the author-trace lives — kawaiicore-design §Positive
// signals: "site by ... ★ last updated ..." line, friends row of 88x31
// buttons, credits. The mascot appears here a second time (mascot must
// appear in >=3 places per kawaiicore §Mascot Integration — header, footer,
// 404, loading. Header + footer covers two.)
//
// Voice in the footer is intentionally low-stakes — "u" not "you",
// kaomoji at the end, run-on sentences. One sentence in author voice
// does more for human-feel than 30 stickers (kawaiicore §Voice Grammar).

const FRIENDS: Array<{ href: string; label: string; alt: string; bg: string }> = [
  // 88x31 buttons - placeholder labels until we wire real friend protocols
  { href: "https://uniswap.org",  label: "uniswap v4",   alt: "uniswap v4 hook",      bg: "#ffd1dc" },
  { href: "https://hyperlane.xyz", label: "hyperlane",   alt: "hyperlane interop",    bg: "#bde0fe" },
  { href: "https://circle.com",    label: "circle cctp", alt: "circle cctp bridging", bg: "#aaf0d1" },
  { href: "https://pyth.network",  label: "pyth",        alt: "pyth oracle",          bg: "#ffd206" },
  { href: "https://chain.link",    label: "chainlink",   alt: "chainlink oracle",     bg: "#ffb280" },
];

export function ShellFooter() {
  return (
    <footer className="mx-auto max-w-[1080px] px-6 pt-12 pb-16 mt-16 border-t border-ink-soft/30">
      <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
        {/* Author trace column */}
        <div>
          <div className="flex items-center gap-2 mb-3">
            <Mascot size={36} />
            <span className="display-title text-[20px]">mirv</span>
          </div>
          <p className="text-[12px] text-ink-soft leading-relaxed">
            cross-chain liquidity mirror on uniswap v4 + hyperlane. deposit once on base,
            the swarm mirrors your LP across ethereum + base for the imbalance yield.
            ur shares stay redeemable; protocol takes 15% of <em>extra</em>.
          </p>
          <p className="text-[11px] text-ink-faint mt-4 leading-relaxed">
            site by <a href="https://github.com/sp0oby" className="underline text-pink-hot">sp0oby</a>
            <span className="mx-1">★</span>
            last updated <time>2026-05-18</time>
            <span className="mx-1">★</span>
            best viewed in firefox lol
          </p>
        </div>

        {/* Friends row */}
        <div>
          <h4 className="font-maru text-[13px] font-semibold text-ink mb-3">
            ✿ friends &amp; dependencies
          </h4>
          <div className="flex flex-wrap gap-1.5">
            {FRIENDS.map((f) => (
              <a
                key={f.href}
                href={f.href}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center justify-center w-[88px] h-[31px] text-[10px] font-maru font-semibold text-ink border border-ink"
                style={{
                  backgroundColor: f.bg,
                  imageRendering: "pixelated",
                  textShadow: "1px 1px 0 rgba(255,255,255,0.4)",
                }}
                title={f.alt}
              >
                {f.label}
              </a>
            ))}
          </div>
          <p className="text-[10px] text-ink-faint mt-3">
            (88×31 buttons, web-revival canon. tysm for the protocols ♡)
          </p>
        </div>

        {/* Currently widget — kawaiicore §Implementation Priority #5 */}
        <div>
          <h4 className="font-maru text-[13px] font-semibold text-ink mb-3">
            ❀ currently
          </h4>
          <ul className="space-y-1 text-[12px] text-ink-soft leading-relaxed">
            <li><span className="text-ink-faint">obsessed with</span> &nbsp;cross-chain MEV</li>
            <li><span className="text-ink-faint">listening to</span> &nbsp;agent dispatch logs</li>
            <li><span className="text-ink-faint">reading</span> &nbsp;v4 hook docs (again)</li>
            <li><span className="text-ink-faint">building</span> &nbsp;towards mainnet</li>
            <li><span className="text-ink-faint">mood</span> &nbsp;cautiously optimistic <span className="ml-0.5">(◕‿◕✿)</span></li>
          </ul>
        </div>
      </div>

      <div className="mt-10 pt-6 border-t border-dotted border-ink-soft/40 text-[11px] text-ink-faint flex flex-wrap justify-between gap-2">
        <span>(づ｡◕‿‿◕｡)づ tysm for visiting</span>
        <span>mit licensed · audit candidate v1.0.0-rc6 · no warranty, no guarantees, dyor</span>
      </div>
    </footer>
  );
}
