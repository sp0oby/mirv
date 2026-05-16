import { ChatAnthropic } from "@langchain/anthropic";
import { createReactAgent } from "@langchain/langgraph/prebuilt";
import { poolStateTools } from "../tools/poolState.js";
import { MONITOR_PROMPT } from "../prompts/loader.js";
import type { MirrorState, MonitorResult, Chain } from "../state.js";

const llm = new ChatAnthropic({
  model: "claude-opus-4-7",
  apiKey: process.env.ANTHROPIC_API_KEY,
  temperature: 0,
});

const agent = createReactAgent({ llm, tools: poolStateTools });

export async function runMonitorAgent(
  chain: Chain,
  _state: MirrorState
): Promise<Partial<MirrorState>> {
  const hookAddress = process.env[`MIRROR_HOOK_${chain.toUpperCase()}`] ?? "0x0";
  const chainlinkFeed = chain === "bnb"
    ? ""
    : process.env[`CHAINLINK_ETH_USD_${chain === "ethereum" ? "MAINNET" : "BASE"}`] ?? "";

  const prompt = `Monitor the ETH/USDC pool on ${chain}.
Hook address: ${hookAddress}
Chainlink ETH/USD feed: ${chainlinkFeed}
V4 fee tier: 3000, tick spacing: 60

Read the pool state, get the current price, estimate depth in USD (liquidity * pricePerUnit).
Compare with previously reported sister depths (from last cycle or 0 if unknown).
Output the MonitorResult JSON.`;

  const result = await agent.invoke({
    messages: [
      { role: "system", content: MONITOR_PROMPT },
      { role: "user",   content: prompt },
    ],
  });

  const lastMsg = result.messages[result.messages.length - 1];
  let parsed: MonitorResult;
  try {
    const content = typeof lastMsg.content === "string"
      ? lastMsg.content
      : JSON.stringify(lastMsg.content);
    // Extract JSON block from agent response
    const match = content.match(/\{[\s\S]*\}/);
    parsed = JSON.parse(match?.[0] ?? content) as MonitorResult;
  } catch {
    parsed = {
      chain,
      pair: "ETH/USDC",
      timestamp: Date.now(),
      localDepthUsd: 0,
      sisterDepths: { ethereum: 0, base: 0, bnb: 0 },
      imbalancePct: 0,
      priceDriftPct: 0,
      currentTickLow: -60,
      currentTickHigh: 60,
      currentFeeTier: 3000,
      actionNeeded: false,
      summary: `Parse error on ${chain} monitor response`,
    };
  }

  return {
    monitorResults: { [chain]: parsed },
  };
}
