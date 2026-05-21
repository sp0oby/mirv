// MUST be the first import — loads env before any other module reads process.env
// at its top level. See bootstrap.ts for the why.
import "./bootstrap.js";

// Force unbuffered stdout/stderr — critical for `nohup agent > log &` workflows
// (otherwise Node block-buffers writes to a pipe/file and the log appears empty)
if ((process.stdout as any)._handle?.setBlocking) (process.stdout as any)._handle.setBlocking(true);
if ((process.stderr as any)._handle?.setBlocking) (process.stderr as any)._handle.setBlocking(true);

import { buildGraph }      from "./graph.js";
import { disconnectRedis } from "./tools/redis.js";
import { startHeartbeatServer } from "./heartbeat.js";
import { runWithdrawalFulfiller } from "./withdrawal-fulfiller.js";
import type { MirrorState } from "./state.js";

const CYCLE_INTERVAL_MS = 45_000; // 45 seconds between cycles

// Optional cap: useful for controlled soak tests / CI smoke runs to keep Claude
// credit spend bounded. Set MAX_CYCLES=N to exit cleanly after N completed cycles.
// Unset or 0 = run indefinitely (production behavior).
const MAX_CYCLES = Number(process.env.MAX_CYCLES ?? "0");

// HTTP heartbeat — Railway / Fly inject $PORT; default 8080 for local runs.
// /health returns 503 if no cycle has landed in 3 minutes. External monitors
// (Better Stack, UptimeRobot) page on that.
const HEARTBEAT_PORT = Number(process.env.PORT ?? "8080");

async function main() {
  console.log("=== mirv agent swarm starting ===");
  console.log(`Cycle interval: ${CYCLE_INTERVAL_MS / 1000}s`);
  if (MAX_CYCLES > 0) console.log(`Cycle cap:      ${MAX_CYCLES} (will exit after)`);

  const heartbeatServer = startHeartbeatServer(HEARTBEAT_PORT);
  const graph  = buildGraph();
  let   cycle  = 0;

  // Graceful shutdown — close heartbeat server first so Railway sees clean exit
  const shutdown = async () => {
    console.log("\nShutting down...");
    heartbeatServer.close();
    await disconnectRedis();
    process.exit(0);
  };
  process.on("SIGINT",  shutdown);
  process.on("SIGTERM", shutdown);

  while (true) {
    cycle++;
    const initialState: Partial<MirrorState> = {
      cycle,
      timestamp:           Date.now(),
      monitorResults:      {},
      rebalanceProposal:   null,
      coordinatorDecision: null,
      riskAssessment:      null,
      executionResult:     null,
      errors:              [],
    };

    try {
      await graph.invoke(initialState);
    } catch (err) {
      console.error(`[Cycle ${cycle}] Unhandled error:`, err instanceof Error ? err.message : err);
    }

    // 8.5.10 — sweep pending async withdrawals each cycle. Independent of the
    // rebalance graph; idempotent (vault's `fulfilled` flag guards against
    // double-pay). Failures are logged + don't crash the cycle loop.
    try {
      const report = await runWithdrawalFulfiller();
      if (report.fulfilled.length > 0) {
        console.log(`[Cycle ${cycle}] withdrawals fulfilled: ${report.fulfilled.length}`);
      }
      if (report.pending.length > 0) {
        console.log(`[Cycle ${cycle}] withdrawals needing cross-chain unwind: ${report.pending.length}`);
      }
      if (report.errors.length > 0) {
        console.warn(`[Cycle ${cycle}] withdrawal-fulfiller errors:`, report.errors);
      }
    } catch (err) {
      console.error(`[Cycle ${cycle}] withdrawal-fulfiller crashed:`, err instanceof Error ? err.message : err);
    }

    if (MAX_CYCLES > 0 && cycle >= MAX_CYCLES) {
      console.log(`\n=== Reached MAX_CYCLES=${MAX_CYCLES}, shutting down ===`);
      await disconnectRedis();
      return;
    }

    await sleep(CYCLE_INTERVAL_MS);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
