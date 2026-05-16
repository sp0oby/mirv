import "dotenv/config";
import { buildGraph }      from "./graph.js";
import { disconnectRedis } from "./tools/redis.js";
import type { MirrorState } from "./state.js";

const CYCLE_INTERVAL_MS = 45_000; // 45 seconds between cycles

async function main() {
  console.log("=== mirv agent swarm starting ===");
  console.log(`Cycle interval: ${CYCLE_INTERVAL_MS / 1000}s`);

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
