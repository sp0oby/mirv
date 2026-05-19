// Tiny HTTP server that exposes the agent's last-cycle state so external
// monitors (Better Stack, UptimeRobot, Tenderly alerts, the frontend itself)
// can tell whether the swarm is alive without scraping logs.
//
// /         → JSON snapshot of the last cycle
// /health   → 200 if last cycle was recent, 503 if stale or never run
//
// Runs alongside the main cycle loop in index.ts. Stateless — module-level
// `lastCycle` is updated from graph.ts after each cycle's record node.

import { createServer, type Server } from "node:http";

export interface CycleSnapshot {
  cycle:             number;
  timestamp:         number; // ms since epoch
  maxImbalancePct:   number;
  actionTaken:       boolean;
  extraYieldUsd?:    number;
  lastTxHash?:       string;
  errors:            number;
}

// 3 minutes is comfortably > 1 cycle (45s) without false-positive on a slow
// LLM round. Anything longer than this and something's wrong.
const STALENESS_MS = 3 * 60_000;

let lastCycle: CycleSnapshot = {
  cycle:           0,
  timestamp:       0,
  maxImbalancePct: 0,
  actionTaken:     false,
  errors:          0,
};
let bootedAt = Date.now();

export function recordHeartbeat(snapshot: Partial<CycleSnapshot>): void {
  lastCycle = { ...lastCycle, ...snapshot, timestamp: Date.now() };
}

export function startHeartbeatServer(port: number): Server {
  const server = createServer((req, res) => {
    const ageMs = lastCycle.timestamp === 0 ? null : Date.now() - lastCycle.timestamp;

    if (req.url === "/health") {
      // booting — be generous; uptime check should pass for the first ~2 min
      if (lastCycle.timestamp === 0) {
        const bootAge = Date.now() - bootedAt;
        const ok = bootAge < 2 * 60_000;
        res.writeHead(ok ? 200 : 503, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ status: ok ? "booting" : "no-cycles", bootAgeMs: bootAge }));
        return;
      }
      const stale = (ageMs ?? Infinity) > STALENESS_MS;
      res.writeHead(stale ? 503 : 200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        status: stale ? "stale" : "ok",
        ageMs,
        lastCycle,
      }));
      return;
    }

    if (req.url === "/" || req.url === "/status") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({
        service: "mirv agent swarm",
        bootedAt,
        uptimeMs: Date.now() - bootedAt,
        ageMs,
        lastCycle,
      }, null, 2));
      return;
    }

    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found\n");
  });

  server.listen(port, () => {
    console.log(`[heartbeat] HTTP server listening on port ${port}`);
  });
  return server;
}
