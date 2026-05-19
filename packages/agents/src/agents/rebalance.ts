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
  const minCompetitiveness = Math.min(...monitors.map((m) => m.competitivenessPct ?? 0));
  const outOfRangeChains = monitors.filter((m) => m.outOfRange === true);

  const prompt = `Monitor results from this cycle:
${JSON.stringify(monitors, null, 2)}

Total mirrored TVL: $${totalTvl.toLocaleString()}
Max single move: 2% = $${(totalTvl * 0.02).toLocaleString()}
Min competitiveness across chains: ${minCompetitiveness.toFixed(2)}%
Chains with LP out of range: ${outOfRangeChains.length === 0 ? "none" : outOfRangeChains.map((m) => m.chain).join(", ")}

ACTION SELECTION (in order of priority):

1. COMPETITIVENESS GUARD: If any chain has competitivenessPct < 10%, set
   action="none". Reasoning should flag "non-competitive on chain X — seed
   depth needed before rebalancing matters." Don't waste gas + bridge fees
   on dust.

2. RECENTER TICKS (8.5.3): If a chain has outOfRange=true AND competitiveness
   is ≥ 10%, set action="recenter" with:
     - recenterChain = the out-of-range chain
     - newTickLower / newTickUpper = a range that brackets the chain's
       canonicalTick (e.g. tickLower = floor((canonicalTick - 4200) / 60) * 60,
       tickUpper = floor((canonicalTick + 4200) / 60) * 60)
   This shifts our LP back into range so we earn fees again. No cross-chain
   USDC movement, just a local LP re-add.

3. CROSS-CHAIN REBALANCE: If no recenter needed and depth is competitive,
   calculate the optimal cross-chain rebalance based on relative imbalance.

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
    console.log(`  [rebalance] action=${parsed.action} reasoning="${(parsed.reasoning ?? '').slice(0, 100)}"`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    parsed = { action: "none", reasoning: `Rebalance error: ${msg.slice(0, 150)}` };
  }

  return { rebalanceProposal: parsed };
}
