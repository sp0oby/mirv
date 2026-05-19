import { Annotation } from "@langchain/langgraph";

// ─── Chain names ──────────────────────────────────────────────────────────────
export type Chain = "ethereum" | "base" | "bnb";
export type Pair  = "ETH/USDC" | "USDC/USDT";

// ─── Monitor output ───────────────────────────────────────────────────────────
export interface MonitorResult {
  chain:               Chain;
  pair:                Pair;
  timestamp:           number;
  localDepthUsd:       number;
  sisterDepths:        Record<Chain, number>;
  imbalancePct:        number;
  priceDriftPct:       number;
  currentTickLow:      number;
  currentTickHigh:     number;
  currentFeeTier:      number;
  actionNeeded:        boolean;
  summary:             string;
  // 8.5.2 — canonical-pool awareness. Read the no-hook canonical pool on the
  // same chain so the agents can see how competitive mirv's pool is. If we're
  // at <10% of canonical depth, no router will quote us and rebalancing tiny
  // amounts doesn't matter — flag for seed-depth attention instead.
  canonicalDepthUsd?:   number;
  competitivenessPct?:  number; // (localDepthUsd / canonicalDepthUsd) × 100
}

// ─── Rebalance proposal ───────────────────────────────────────────────────────
export interface RebalanceProposal {
  action:               "rebalance" | "none";
  fromChain?:           Chain;
  toChains?:            Chain[];
  deltaToken0?:         string; // stringified bigint (token0 units)
  deltaToken1?:         string;
  newFee?:              number; // e.g. 0.0003 → 3000 bps
  newTickLower?:        number;
  newTickUpper?:        number;
  expectedExtraYieldUsd?: number;
  reasoning:            string;
  riskLevel?:           "low" | "medium" | "high";
}

// ─── Coordinator decision ─────────────────────────────────────────────────────
export interface CoordinatorDecision {
  approved:         boolean;
  finalAction?:     RebalanceProposal;
  modifications?:   Partial<RebalanceProposal>;
  hyperlanePayload?: `0x${string}`;
  reasoning:        string;
  executeNow:       boolean;
}

// ─── Risk assessment ──────────────────────────────────────────────────────────
export interface RiskAssessment {
  status:              "green" | "yellow" | "red";
  veto:                boolean;
  vetoReason?:         string;
  globalRiskScore:     number; // 0.0 – 1.0
  recommendedAction:   "continue" | "pause_all" | "emergency_withdraw";
}

// ─── Execution result ─────────────────────────────────────────────────────────
export interface ExecutionResult {
  txHash?:    string;
  success:    boolean;
  error?:     string;
  timestamp:  number;
}

// ─── Historical record ────────────────────────────────────────────────────────
export interface CycleRecord {
  cycle:        number;
  timestamp:    number;
  imbalancePct: number;
  actionTaken:  boolean;
  extraYieldUsd?: number;
  gasCostUsd?:    number;
}

// ─── LangGraph state annotation ───────────────────────────────────────────────
export const MirrorStateAnnotation = Annotation.Root({
  cycle:               Annotation<number>,
  timestamp:           Annotation<number>,
  monitorResults:      Annotation<Record<string, MonitorResult>>({
    reducer: (a, b) => ({ ...a, ...b }),
    default: () => ({})
  }),
  rebalanceProposal:   Annotation<RebalanceProposal | null>,
  coordinatorDecision: Annotation<CoordinatorDecision | null>,
  riskAssessment:      Annotation<RiskAssessment | null>,
  executionResult:     Annotation<ExecutionResult | null>,
  errors:              Annotation<string[]>({
    reducer: (a, b) => [...a, ...b],
    default: () => []
  })
});

export type MirrorState = typeof MirrorStateAnnotation.State;
