import { callClaude } from "../llm.js";
import { REBALANCE_PROMPT } from "../prompts/loader.js";
import type { MirrorState, RebalanceProposal } from "../state.js";

export async function runRebalanceAgent(state: MirrorState): Promise<Partial<MirrorState>> {
  const monitors = Object.values(state.monitorResults);
  if (monitors.length === 0 || monitors.every((m) => !m.actionNeeded)) {
    return {
      rebalanceProposal: { action: "none", reasoning: "No monitors flagged action needed" },
    };
  }

  const totalTvl = monitors.reduce((sum, m) => sum + m.localDepthUsd, 0);
  const prompt = `Monitor results from this cycle:
${JSON.stringify(monitors, null, 2)}

Total mirrored TVL: $${totalTvl.toLocaleString()}
Max single move: 2% = $${(totalTvl * 0.02).toLocaleString()}

Calculate the optimal rebalance. Consider all three chains.
Estimate amounts in token units (USDC has 6 decimals, WETH has 18 decimals).
Output the RebalanceProposal JSON only — no other text.`;

  let parsed: RebalanceProposal;
  try {
    const response = await callClaude({
      system:     REBALANCE_PROMPT,
      user:       prompt,
      maxTokens:  1024,
      agentLabel: "rebalance",
    });
    const match = response.match(/\{[\s\S]*\}/);
    parsed = JSON.parse(match?.[0] ?? response) as RebalanceProposal;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    parsed = { action: "none", reasoning: `Rebalance error: ${msg.slice(0, 150)}` };
  }

  return { rebalanceProposal: parsed };
}
