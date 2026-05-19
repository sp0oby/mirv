"use client";

import Link from "next/link";
import { Mascot } from "./Mascot";
import { HeaderWalletButton } from "./HeaderWalletButton";

const NAV = [
  { href: "/",          label: "home" },
  { href: "/dashboard", label: "dashboard" },
  { href: "/deposit",   label: "deposit" },
  { href: "/positions", label: "positions" },
  { href: "/activity",  label: "activity" },
];

export function ShellHeader() {
  return (
    <header className="mx-auto max-w-[1200px] px-8 pt-8 pb-6">
      <div className="flex items-center justify-between gap-6">
        <Link href="/" className="flex items-center gap-3 group">
          <Mascot size={56} />
          <span className="display-title text-[42px] tracking-tight leading-none">mirv</span>
          <span
            className="pixel text-ink-soft text-[12px] select-none"
            style={{ transform: "rotate(-7deg) translateY(-10px)" }}
          >
            testnet
          </span>
        </Link>

        <nav className="hidden md:flex items-center gap-7">
          {NAV.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="font-maru text-[15px] text-ink hover:text-pink-hot transition-colors"
            >
              {item.label}
            </Link>
          ))}
        </nav>

        <HeaderWalletButton />
      </div>

      <div className="mt-4 flex items-center gap-3 text-[13px] text-ink-soft">
        <span className="inline-flex items-center gap-1.5">
          <span className="w-2 h-2 rounded-full bg-mint-deep animate-heartbeat" />
          live
        </span>
        <span className="text-ink-faint">·</span>
        <span>base + ethereum testnet</span>
        <span className="text-ink-faint">·</span>
        <span>reads refresh every 30s</span>
      </div>
    </header>
  );
}
