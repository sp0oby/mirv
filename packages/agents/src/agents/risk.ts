import { callClaude } from "../llm.js";
import { RISK_PROMPT } from "../prompts/loader.js";
import { extractJson } from "../utils/parseJson.js";
import type { MirrorState, RiskAssessment } from "../state.js";
import { loadCycleHistory } from "../tools/redis.js";

export async function runRiskAgent(state: MirrorState): Promise<Partial<MirrorState>> {
  const history = await loadCycleHistory().catch(() => []);
  const recentHistory = history.slice(0, 5);

  const monitors = Object.values(state.monitorResults);
  const totalTvl = monitors.reduce((s, m) => s + m.localDepthUsd, 0);
  const failedMonitors = monitors.filter((m) => m.localDepthUsd === 0).length;

  const prompt = `Current state for risk assessment:
Cycle: ${state.cycle}
Total TVL: $${totalTvl.toLocaleString()}
Monitor results: ${JSON.stringify(monitors, null, 2)}
Rebalance proposal: ${JSON.stringify(state.rebalanceProposal, null, 2)}
Coordinator decision: ${JSON.stringify(state.coordinatorDecision, null, 2)}
Failed monitors: ${failedMonitors}
Recent 5 cycles: ${JSON.stringify(recentHistory, null, 2)}

Assess all veto conditions. Calculate risk score. Output RiskAssessment JSON only — no other text.`;

  let assessment: RiskAssessment;
  try {
    const response = await callClaude({
      system:     RISK_PROMPT,
      user:       prompt,
      maxTokens:  512,
      agentLabel: "risk",
    });
    assessment = extractJson<RiskAssessment>(response);
    console.log(`  [risk] status=${assessment.status} veto=${assessment.veto} reason="${(assessment.vetoReason ?? '').slice(0, 80)}"`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    assessment = {
      status: "red",
      veto: true,
      vetoReason: `RiskAgent failed: ${msg.slice(0, 120)}`,
      globalRiskScore: 1.0,
      recommendedAction: "pause_all",
    };
  }

  // Hard-coded override: if 2+ monitors are down, always veto
  if (failedMonitors >= 2) {
    assessment.veto = true;
    assessment.status = "red";
    assessment.vetoReason = `${failedMonitors} monitors offline — cannot safely rebalance`;
    assessment.recommendedAction = "pause_all";
    assessment.globalRiskScore = Math.max(assessment.globalRiskScore, 0.9);
  }

  console.log(`[Risk] status=${assessment.status} veto=${assessment.veto} score=${assessment.globalRiskScore}`);
  return { riskAssessment: assessment };
}
