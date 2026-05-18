import "dotenv/config";

// Force unbuffered stdout/stderr — critical for `nohup agent > log &` workflows
// (otherwise Node block-buffers writes to a pipe/file and the log appears empty)
if ((process.stdout as any)._handle?.setBlocking) (process.stdout as any)._handle.setBlocking(true);
if ((process.stderr as any)._handle?.setBlocking) (process.stderr as any)._handle.setBlocking(true);

import { buildGraph }      from "./graph.js";
import { disconnectRedis } from "./tools/redis.js";
import type { MirrorState } from "./state.js";

const CYCLE_INTERVAL_MS = 45_000; // 45 seconds between cycles

// Optional cap: useful for controlled soak tests / CI smoke runs to keep Claude
// credit spend bounded. Set MAX_CYCLES=N to exit cleanly after N completed cycles.
// Unset or 0 = run indefinitely (production behavior).
const MAX_CYCLES = Number(process.env.MAX_CYCLES ?? "0");

async function main() {
  console.log("=== mirv agent swarm starting ===");
  console.log(`Cycle interval: ${CYCLE_INTERVAL_MS / 1000}s`);
  if (MAX_CYCLES > 0) console.log(`Cycle cap:      ${MAX_CYCLES} (will exit after)`);

  const graph  = buildGraph();
  let   cycle  = 0;

  // Graceful shutdown
  process.on("SIGINT",  () => { console.log("\nShutting down..."); disconnectRedis().then(() => process.exit(0)); });
  process.on("SIGTERM", () => { disconnectRedis().then(() => process.exit(0)); });

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
