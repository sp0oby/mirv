import { ChatAnthropic } from "@langchain/anthropic";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { RISK_PROMPT } from "../prompts/loader.js";
import type { MirrorState, RiskAssessment } from "../state.js";
import { loadCycleHistory } from "../tools/redis.js";

const llm = new ChatAnthropic({
  model: "claude-opus-4-7",
  apiKey: process.env.ANTHROPIC_API_KEY,
  temperature: 0,
  maxTokens: 512,
});

export async function runRiskAgent(state: MirrorState): Promise<Partial<MirrorState>> {
  const history = await loadCycleHistory().catch(() => []);
  const recentHistory = history.slice(0, 5); // last 5 cycles

  const monitors  = Object.values(state.monitorResults);
  const totalTvl  = monitors.reduce((s, m) => s + m.localDepthUsd, 0);
  const failedMonitors = monitors.filter((m) => m.localDepthUsd === 0).length;

  const prompt = `Current state for risk assessment:
Cycle: ${state.cycle}
Total TVL: $${totalTvl.toLocaleString()}
Monitor results: ${JSON.stringify(monitors, null, 2)}
Rebalance proposal: ${JSON.stringify(state.rebalanceProposal, null, 2)}
Coordinator decision: ${JSON.stringify(state.coordinatorDecision, null, 2)}
Failed monitors: ${failedMonitors}
Recent 5 cycles: ${JSON.stringify(recentHistory, null, 2)}

Assess all veto conditions. Calculate risk score. Output RiskAssessment JSON.`;

  const response = await llm.invoke([
    new SystemMessage(RISK_PROMPT),
    new HumanMessage(prompt),
  ]);

  const content = typeof response.content === "string"
    ? response.content
    : JSON.stringify(response.content);

  let assessment: RiskAssessment;
  try {
    const match = content.match(/\{[\s\S]*\}/);
    assessment = JSON.parse(match?.[0] ?? content) as RiskAssessment;
  } catch {
    // Parse failure → veto as a safety default
    assessment = {
      status: "red",
      veto: true,
      vetoReason: `RiskAgent parse failure: ${content.slice(0, 100)}`,
      globalRiskScore: 1.0,
      recommendedAction: "pause_all",
    };
  }

  // Hard-coded override: if any monitor is completely down, always veto
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
