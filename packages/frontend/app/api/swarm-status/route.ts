import { NextResponse } from "next/server";
import { baseClient, ADDR } from "@/lib/contracts";
import { parseAbi } from "viem";

// Server-side endpoint the header polls every ~15s for live swarm status.
//
// Two information sources, fused:
//   1. AGENT_HEARTBEAT_URL — if set, agent process is running on Railway/Fly
//      and we get rich data (cycle number, last tx hash) directly from it.
//   2. On-chain `vault.lastCrossChainAssetsUpdate` — the timestamp the agent
//      writes every time it reports cross-chain balances. Lags by one cycle
//      but is the authoritative on-chain record. Always available.
//
// Returned status:
//   active  → cycle landed within 60s (green pulse)
//   calm    → cycle within 10 min (green, no pulse)
//   idle    → last cycle > 10 min ago (yellow)
//   paused  → vault.paused == true (pink)
//   offline → can't reach RPC (gray)

export const revalidate = 0; // always fresh

const vaultAbi = parseAbi([
  "function lastCrossChainAssetsUpdate() view returns (uint256)",
  "function paused() view returns (bool)",
]);

interface AgentHeartbeat {
  lastCycle?: { cycle: number; timestamp: number; lastTxHash?: string };
  ageMs?: number | null;
}

export async function GET() {
  const heartbeatUrl = process.env.AGENT_HEARTBEAT_URL;

  // 1. Hit the agent's heartbeat if configured (richer data)
  let heartbeat: AgentHeartbeat | null = null;
  if (heartbeatUrl) {
    try {
      const r = await fetch(heartbeatUrl + "/health", {
        signal: AbortSignal.timeout(2500),
        cache: "no-store",
      });
      if (r.ok) heartbeat = await r.json();
    } catch {
      // agent unreachable — fall through to on-chain
    }
  }

  // 2. On-chain truth — always read this so we can detect paused state.
  let lastUpdate = 0;
  let paused = false;
  try {
    const [lu, p] = await Promise.all([
      baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "lastCrossChainAssetsUpdate" }),
      baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "paused" }),
    ]);
    lastUpdate = Number(lu);
    paused = p as boolean;
  } catch {
    return NextResponse.json(
      { status: "offline", reason: "rpc unreachable" },
      { headers: { "Cache-Control": "no-store" } }
    );
  }

  if (paused) {
    return NextResponse.json(
      { status: "paused", lastUpdate, heartbeat },
      { headers: { "Cache-Control": "no-store" } }
    );
  }

  // Prefer agent heartbeat freshness if we have it (more accurate than on-chain
  // because the agent reports cross-chain every Nth cycle, not every cycle).
  const ageSeconds = heartbeat?.ageMs != null
    ? Math.floor(heartbeat.ageMs / 1000)
    : lastUpdate === 0
      ? Infinity
      : Math.floor(Date.now() / 1000) - lastUpdate;

  let status: "active" | "calm" | "idle";
  if (ageSeconds < 60) status = "active";
  else if (ageSeconds < 600) status = "calm";
  else status = "idle";

  return NextResponse.json(
    {
      status,
      ageSeconds: Number.isFinite(ageSeconds) ? ageSeconds : null,
      lastUpdate,
      cycle: heartbeat?.lastCycle?.cycle ?? null,
    },
    { headers: { "Cache-Control": "no-store" } }
  );
}
