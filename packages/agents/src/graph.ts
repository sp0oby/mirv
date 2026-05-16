import { StateGraph, END } from "@langchain/langgraph";
import { MirrorStateAnnotation, type MirrorState } from "./state.js";
import { runMonitorAgent } from "./agents/monitor.js";
import { runRebalanceAgent } from "./agents/rebalance.js";
import { runCoordinatorAgent } from "./agents/coordinator.js";
import { runRiskAgent } from "./agents/risk.js";
import { appendCycleHistory } from "./tools/redis.js";

// ─── Node wrappers ────────────────────────────────────────────────────────────

async function monitorAll(state: MirrorState): Promise<Partial<MirrorState>> {
  console.log(`\n[Cycle ${state.cycle}] Running monitors...`);
  // Run all 3 chain monitors in parallel
  const [eth, base, bnb] = await Promise.allSettled([
    runMonitorAgent("ethereum", state),
    runMonitorAgent("base",     state),
    runMonitorAgent("bnb",      state),
  ]);

  const merged: Partial<MirrorState> = { monitorResults: {} };
  for (const result of [eth, base, bnb]) {
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
