import { describe, it, expect } from "vitest";
import type { MirrorState, MonitorResult, RebalanceProposal, RiskAssessment } from "../src/state.js";

// graph.ts isn't directly importable for routing functions (they're not
// exported), but the conditional-routing logic is small + lifted into pure
// helpers here so we can assert against it directly. Mirror of graph.ts:64-84.

function shouldRebalance(state: Partial<MirrorState>): "rebalance" | "record" {
  const monitorResults = state.monitorResults ?? {};
  const needsAction = Object.values(monitorResults).some((m) => m.actionNeeded);
  return needsAction ? "rebalance" : "record";
}

function shouldExecute(state: Partial<MirrorState>): "risk" | "record" {
  const proposal = state.rebalanceProposal;
  if (!proposal || proposal.action === "none") return "record";
  return "risk";
}

function afterRisk(state: Partial<MirrorState>): "coordinator" | "record" {
  const risk = state.riskAssessment;
  if (!risk || risk.veto || risk.status === "red") return "record";
  return "coordinator";
}

const m = (overrides: Partial<MonitorResult> = {}): MonitorResult => ({
  chain: "base",
  pair: "ETH/USDC",
  timestamp: 0,
  localDepthUsd: 0,
  sisterDepths: { ethereum: 0, base: 0, bnb: 0 },
  imbalancePct: 0,
  priceDriftPct: 0,
  currentTickLow: -60,
  currentTickHigh: 60,
  currentFeeTier: 3000,
  actionNeeded: false,
  summary: "",
  ...overrides,
});

describe("graph routing: shouldRebalance", () => {
  it("routes to record when no monitors report action needed", () => {
    expect(shouldRebalance({ monitorResults: { base: m({ actionNeeded: false }) } })).toBe("record");
  });

  it("routes to rebalance when any monitor flags action needed", () => {
    expect(shouldRebalance({
      monitorResults: { base: m({ actionNeeded: false }), ethereum: m({ chain: "ethereum", actionNeeded: true }) },
    })).toBe("rebalance");
  });

  it("treats empty monitor results as record (nothing to act on)", () => {
    expect(shouldRebalance({ monitorResults: {} })).toBe("record");
  });

  it("treats missing monitorResults as record (defensive)", () => {
    expect(shouldRebalance({})).toBe("record");
  });
});

describe("graph routing: shouldExecute", () => {
  it("routes to record when proposal is missing", () => {
    expect(shouldExecute({ rebalanceProposal: null })).toBe("record");
  });

  it("routes to record when proposal action is none", () => {
    const proposal: RebalanceProposal = { action: "none", reasoning: "no-op cycle" };
    expect(shouldExecute({ rebalanceProposal: proposal })).toBe("record");
  });

  it("routes to risk on a rebalance proposal", () => {
    const proposal: RebalanceProposal = { action: "rebalance", reasoning: "shift" };
    expect(shouldExecute({ rebalanceProposal: proposal })).toBe("risk");
  });

  it("routes to risk on a recenter proposal (new 8.5.3 action)", () => {
    const proposal: RebalanceProposal = { action: "recenter", reasoning: "drift", recenterChain: "base" };
    expect(shouldExecute({ rebalanceProposal: proposal })).toBe("risk");
  });
});

describe("graph routing: afterRisk", () => {
  it("routes to record when risk vetos", () => {
    const risk: RiskAssessment = {
      status: "yellow", veto: true, vetoReason: "too soon",
      globalRiskScore: 0.7, recommendedAction: "continue",
    };
    expect(afterRisk({ riskAssessment: risk })).toBe("record");
  });

  it("routes to record when risk status is red", () => {
    const risk: RiskAssessment = {
      status: "red", veto: false,
      globalRiskScore: 0.95, recommendedAction: "pause_all",
    };
    expect(afterRisk({ riskAssessment: risk })).toBe("record");
  });

  it("routes to coordinator when status is green and no veto", () => {
    const risk: RiskAssessment = {
      status: "green", veto: false,
      globalRiskScore: 0.1, recommendedAction: "continue",
    };
    expect(afterRisk({ riskAssessment: risk })).toBe("coordinator");
  });

  it("routes to coordinator when status is yellow but no veto", () => {
    const risk: RiskAssessment = {
      status: "yellow", veto: false,
      globalRiskScore: 0.4, recommendedAction: "continue",
    };
    expect(afterRisk({ riskAssessment: risk })).toBe("coordinator");
  });

  it("routes to record on missing risk assessment (defensive)", () => {
    expect(afterRisk({})).toBe("record");
  });
});
