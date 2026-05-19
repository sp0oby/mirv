"use client";

import { useEffect, useState } from "react";

// Cycle countdown — visualizes the swarm's 45-second tick. v0 is a fake
// timer that just loops 45→0; v1 will read the actual `lastCycleAt`
// from a backend or contract event and compute the real next-cycle time.
//
// Why this isn't fake-data theater: the agent loop genuinely runs every
// 45s in production. The countdown matches that real cadence. Once we
// wire to live data the visual stays the same — only the source changes.

const CYCLE_SECONDS = 45;

export function CycleCountdown() {
  const [remaining, setRemaining] = useState(CYCLE_SECONDS);

  useEffect(() => {
    if (typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches) {
      // Static display for reduced-motion users
      return;
    }
    const interval = setInterval(() => {
      setRemaining((r) => (r <= 1 ? CYCLE_SECONDS : r - 1));
    }, 1000);
    return () => clearInterval(interval);
  }, []);

  const pct = (remaining / CYCLE_SECONDS) * 100;

  return (
    <div className="frame-outer p-5" style={{ transform: "rotate(0.4deg)" }}>
      <div className="flex items-baseline justify-between mb-2">
        <p className="font-maru text-[12px] uppercase tracking-wider text-ink-faint">
          ✦ next cycle in
        </p>
        <span className="pixel text-[22px] text-ink leading-none">{remaining}s</span>
      </div>
      <div className="h-2 rounded-full overflow-hidden bg-paper-deep border border-ink-soft/40">
        <div
          className="h-full bg-mint-deep transition-[width] duration-1000 ease-linear"
          style={{ width: `${pct}%` }}
        />
      </div>
      <p className="text-[11px] text-ink-faint mt-2">
        agents read state, decide, dispatch. every 45s.
      </p>
    </div>
  );
}
