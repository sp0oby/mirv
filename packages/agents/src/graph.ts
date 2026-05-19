import { StateGraph, END } from "@langchain/langgraph";
import { MirrorStateAnnotation, type MirrorState } from "./state.js";
import { runMonitorAgent } from "./agents/monitor.js";
import { runRebalanceAgent } from "./agents/rebalance.js";
import { runCoordinatorAgent } from "./agents/coordinator.js";
import { runRiskAgent } from "./agents/risk.js";
import { appendCycleHistory } from "./tools/redis.js";
import { recordHeartbeat } from "./heartbeat.js";

// ─── Node wrappers ────────────────────────────────────────────────────────────

async function monitorAll(state: MirrorState): Promise<Partial<MirrorState>> {
  console.log(`\n[Cycle ${state.cycle}] Running monitors...`);
  // BNB deferred from mainnet launch — see BRIDGE-DESIGN.md §10 (CCTP doesn't yet
  // support BNB, V4 not on BNB Testnet). The BNB MonitorAgent will be re-enabled
  // once Vault.addChain is called for BNB post-launch (no contract redeploy needed
  // — single admin tx). Until then, the swarm runs 2 chain monitors instead of 3.
  const monitors: Array<"ethereum" | "base" | "bnb"> = ["base", "ethereum"];
  if (process.env.ENABLE_BNB_MONITOR === "true") monitors.push("bnb");

  const results = await Promise.allSettled(
    monitors.map((chain) => runMonitorAgent(chain, state))
  );

  const merged: Partial<MirrorState> = { monitorResults: {} };
  for (const result of results) {
    if (result.status === "fulfilled") {
      Object.assign(merged.monitorResults!, result.value.monitorResults ?? {});
    }
  }
  return merged;
}

async function rebalanceNode(state: MirrorState): Promise<Partial<MirrorState>> {
  console.log(`[Cycle ${state.cycle}] Running RebalanceAgent...`);
  return runRebalanceAgent(state);
}

async function riskNode(state: MirrorState): Promise<Partial<MirrorState>> {
  console.log(`[Cycle ${state.cycle}] Running RiskAgent...`);
  return runRiskAgent(state);
}

async function coordinatorNode(state: MirrorState): Promise<Partial<MirrorState>> {
  console.log(`[Cycle ${state.cycle}] Running CoordinatorAgent...`);
  return runCoordinatorAgent(state);
}

async function recordCycle(state: MirrorState): Promise<Partial<MirrorState>> {
  const monitors = Object.values(state.monitorResults);
  const maxImbalance = Math.max(...monitors.map((m) => m.imbalancePct), 0);

  await appendCycleHistory({
    cycle:        state.cycle,
    timestamp:    Date.now(),
    imbalancePct: maxImbalance,
    actionTaken:  state.executionResult?.success ?? false,
    extraYieldUsd: state.rebalanceProposal?.expectedExtraYieldUsd,
  }).catch(() => {});

  recordHeartbeat({
    cycle:           state.cycle,
    maxImbalancePct: maxImbalance,
    actionTaken:     state.executionResult?.success ?? false,
    extraYieldUsd:   state.rebalanceProposal?.expectedExtraYieldUsd,
    lastTxHash:      state.executionResult?.txHash,
    errors:          state.errors?.length ?? 0,
  });

  console.log(`[Cycle ${state.cycle}] Done. maxImbalance=${maxImbalance.toFixed(2)}%`);
  return {};
}

// ─── Conditional routing ──────────────────────────────────────────────────────

function shouldRebalance(state: MirrorState): "rebalance" | "record" {
  const needsAction = Object.values(state.monitorResults).some((m) => m.actionNeeded);
  return needsAction ? "rebalance" : "record";
}

function shouldExecute(state: MirrorState): "risk" | "record" {
  const proposal = state.rebalanceProposal;
  if (!proposal || proposal.action === "none") return "record";
  return "risk";
}

function afterRisk(state: MirrorState): "coordinator" | "record" {
  const risk = state.riskAssessment;
  if (!risk || risk.veto || risk.status === "red") {
    console.warn(`[Risk] VETO — ${risk?.vetoReason ?? "red status"}`);
    return "record";
  }
  return "coordinator";
}

// ─── Graph definition ─────────────────────────────────────────────────────────

export function buildGraph() {
  const graph = new StateGraph(MirrorStateAnnotation)
    .addNode("monitor",     monitorAll)
    .addNode("rebalance",   rebalanceNode)
    .addNode("risk",        riskNode)
    .addNode("coordinator", coordinatorNode)
    .addNode("record",      recordCycle)

    .addEdge("__start__", "monitor")
    .addConditionalEdges("monitor",   shouldRebalance, { rebalance: "rebalance", record: "record" })
    .addConditionalEdges("rebalance", shouldExecute,   { risk: "risk", record: "record" })
    .addConditionalEdges("risk",      afterRisk,       { coordinator: "coordinator", record: "record" })
    .addEdge("coordinator", "record")
    .addEdge("record",      END);

  return graph.compile();
}

export type MirrorGraph = ReturnType<typeof buildGraph>;
