"use client";

import { useEffect, useState } from "react";

interface Status {
  status: "active" | "calm" | "idle" | "paused" | "offline";
  ageSeconds: number | null;
  cycle: number | null;
}

const COLORS: Record<Status["status"], { dot: string; label: string; pulse: boolean }> = {
  active: { dot: "bg-mint-deep",  label: "swarm active", pulse: true  },
  calm:   { dot: "bg-mint-deep",  label: "swarm calm",   pulse: false },
  idle:   { dot: "bg-marigold",   label: "swarm idle",   pulse: false },
  paused: { dot: "bg-pink-hot",   label: "swarm paused", pulse: false },
  offline:{ dot: "bg-ink-faint",  label: "swarm offline",pulse: false },
};

function formatAge(secs: number | null): string | null {
  if (secs == null || !Number.isFinite(secs)) return null;
  if (secs < 60)    return `${secs}s ago`;
  if (secs < 3600)  return `${Math.floor(secs / 60)}m ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`;
  return `${Math.floor(secs / 86400)}d ago`;
}

export function SwarmStatus() {
  const [s, setS] = useState<Status>({ status: "calm", ageSeconds: null, cycle: null });

  useEffect(() => {
    let active = true;
    const fetchStatus = async () => {
      try {
        const r = await fetch("/api/swarm-status", { cache: "no-store" });
        if (!r.ok) return;
        const j = await r.json();
        if (active) setS({ status: j.status, ageSeconds: j.ageSeconds, cycle: j.cycle });
      } catch {
        if (active) setS({ status: "offline", ageSeconds: null, cycle: null });
      }
    };
    fetchStatus();
    const id = setInterval(fetchStatus, 15_000);
    return () => { active = false; clearInterval(id); };
  }, []);

  const c   = COLORS[s.status];
  const age = formatAge(s.ageSeconds);

  return (
    <div className="mt-4 flex items-center gap-3 text-[13px] text-ink-soft">
      <span className="inline-flex items-center gap-1.5">
        <span className={`w-2 h-2 rounded-full ${c.dot} ${c.pulse ? "animate-heartbeat" : ""}`} />
        {c.label}
      </span>
      {age && (
        <>
          <span className="text-ink-faint">·</span>
          <span>last check-in {age}</span>
        </>
      )}
      <span className="text-ink-faint">·</span>
      <span>reads refresh every 30s</span>
    </div>
  );
}
