import { ChatAnthropic } from "@langchain/anthropic";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import { REBALANCE_PROMPT } from "../prompts/loader.js";
import type { MirrorState, RebalanceProposal } from "../state.js";

const llm = new ChatAnthropic({
  model: "claude-opus-4-7",
  apiKey: process.env.ANTHROPIC_API_KEY,
  temperature: 0,
  maxTokens: 1024,
});

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
Output the RebalanceProposal JSON.`;

  const response = await llm.invoke([
    new SystemMessage(REBALANCE_PROMPT),
    new HumanMessage(prompt),
  ]);

  const content = typeof response.content === "string"
    ? response.content
    : JSON.stringify(response.content);

  let parsed: RebalanceProposal;
  try {
    const match = content.match(/\{[\s\S]*\}/);
    parsed = JSON.parse(match?.[0] ?? content) as RebalanceProposal;
  } catch {
    parsed = { action: "none", reasoning: `Parse error in rebalance response: ${content.slice(0, 200)}` };
  }

  return { rebalanceProposal: parsed };
}
