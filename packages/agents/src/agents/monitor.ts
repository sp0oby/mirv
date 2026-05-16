import {
  createPublicClient, http, parseAbi, type Address,
  encodeAbiParameters, parseAbiParameters, keccak256,
} from "viem";
import { mainnet, base, bsc } from "viem/chains";
import type Anthropic from "@anthropic-ai/sdk";
import { callClaudeWithTools } from "../llm.js";
import { MONITOR_PROMPT } from "../prompts/loader.js";
import type { MirrorState, MonitorResult, Chain } from "../state.js";

// ─── Chain clients ────────────────────────────────────────────────────────────
const clients = {
  ethereum: createPublicClient({ chain: mainnet, transport: http(process.env.ALCHEMY_MAINNET_URL) }),
  base:     createPublicClient({ chain: base,    transport: http(process.env.ALCHEMY_BASE_URL) }),
  bnb:      createPublicClient({ chain: bsc,     transport: http(process.env.ALCHEMY_BNB_URL) }),
} as const;

// V4 PoolManager (canonical per-chain addresses)
const POOL_MANAGERS: Record<string, Address> = {
  ethereum: "0x000000000004444c5dc75cB358380D2e3dE08A90",
  base:     "0x498581fF718922c3f8e6A244956aF099B2652b2b",
  bnb:      "0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF",
};

// V4 StateView lens contracts — getSlot0/getLiquidity are external view here, not on PoolManager
const STATE_VIEWS: Record<string, Address> = {
  ethereum: "0x7ffE42C4a5DEeA5b0feC41C94C136Cf115597227",
  base:     "0xa3c0C9B65baD0b08107Aa264b0f3dB444b867A71",
  bnb:      "0xD13Dd3D6E93f276FAfc9Db9E6BB47C1180aee0c4",
};

const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
]);

const chainlinkAbi = parseAbi([
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
  "function decimals() view returns (uint8)",
]);

// ─── Anthropic tool schemas ───────────────────────────────────────────────────
const tools: Anthropic.Messages.Tool[] = [
  {
    name: "getPoolState",
    description: "Read current V4 pool state (sqrtPrice, tick, liquidity) for a pair on a specific chain",
    input_schema: {
      type: "object",
      properties: {
        chain:       { type: "string", enum: ["ethereum", "base", "bnb"] },
        token0:      { type: "string", description: "token0 address (must be < token1)" },
        token1:      { type: "string", description: "token1 address" },
        feeTier:     { type: "number", description: "V4 fee tier e.g. 3000" },
        tickSpacing: { type: "number", description: "tick spacing e.g. 60" },
        hookAddress: { type: "string", description: "MirrorHook address on this chain" },
      },
      required: ["chain", "token0", "token1", "feeTier", "tickSpacing", "hookAddress"],
    },
  },
  {
    name: "getChainlinkPrice",
    description: "Read Chainlink price feed with staleness validation",
    input_schema: {
      type: "object",
      properties: {
        chain:       { type: "string", enum: ["ethereum", "base", "bnb"] },
        feedAddress: { type: "string" },
      },
      required: ["chain", "feedAddress"],
    },
  },
];

// ─── Tool handlers ────────────────────────────────────────────────────────────
const toolHandlers: Record<string, (input: any) => Promise<unknown>> = {
  async getPoolState({ chain, token0, token1, feeTier, tickSpacing, hookAddress }) {
    const client    = clients[chain as keyof typeof clients];
    const stateView = STATE_VIEWS[chain];

    const poolId = keccak256(encodeAbiParameters(
      parseAbiParameters("address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks"),
      [token0 as Address, token1 as Address, feeTier, tickSpacing, hookAddress as Address]
    ));

    try {
      const [slot0, liquidity] = await Promise.all([
        client.readContract({ address: stateView, abi: stateViewAbi, functionName: "getSlot0",     args: [poolId] }),
        client.readContract({ address: stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [poolId] }),
      ]);
      return {
        chain,
        poolId,
        sqrtPriceX96: slot0[0].toString(),
        tick:         slot0[1],
        fee:          slot0[3],
        liquidity:    liquidity.toString(),
      };
    } catch (err) {
      // Pool likely not initialized on this chain — return zeros so the agent reports depth=0
      return {
        chain, poolId,
        sqrtPriceX96: "0", tick: 0, fee: feeTier, liquidity: "0",
        note: "Pool not initialized on this chain (getSlot0 reverted)",
      };
    }
  },

  async getChainlinkPrice({ chain, feedAddress }) {
    const client = clients[chain as keyof typeof clients];
    const feed   = feedAddress as Address;

    const [, answer, , updatedAt] = await client.readContract({
      address: feed, abi: chainlinkAbi, functionName: "latestRoundData",
    });
    const decimals = await client.readContract({ address: feed, abi: chainlinkAbi, functionName: "decimals" });

    const ageSeconds = Math.floor(Date.now() / 1000) - Number(updatedAt);
    if (ageSeconds > 3600) throw new Error(`Chainlink price stale: ${ageSeconds}s old`);
    if (answer <= 0n) throw new Error("Chainlink price is 0 or negative");

    const price = Number(answer) / 10 ** decimals;
    return { chain, feed: feedAddress, price, updatedAt: Number(updatedAt), ageSeconds };
  },
};

export async function runMonitorAgent(
  chain: Chain,
  _state: MirrorState
): Promise<Partial<MirrorState>> {
  const hookAddress = process.env[`MIRROR_HOOK_${chain.toUpperCase()}`] ?? "0x0000000000000000000000000000000000000000";
  const chainlinkFeed = chain === "bnb"
    ? (process.env.CHAINLINK_ETH_USD_BNB ?? "")
    : (process.env[`CHAINLINK_ETH_USD_${chain === "ethereum" ? "MAINNET" : "BASE"}`] ?? "");

  const prompt = `Monitor the ETH/USDC pool on ${chain}.
Hook address: ${hookAddress}
Chainlink ETH/USD feed: ${chainlinkFeed}
V4 fee tier: 3000, tick spacing: 60
Tokens: ETH = 0x4200000000000000000000000000000000000006 (Base) or 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 (Ethereum mainnet) — use the chain-appropriate WETH
USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (Base) or 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (Ethereum mainnet)

Read the pool state via getPoolState. Read the current price via getChainlinkPrice.
Estimate depth in USD (liquidity × price-per-unit). If pool returns 0 liquidity, depth = 0.
Compare with previously reported sister depths (0 if unknown).
Output the MonitorResult JSON only — no other text.`;

  let parsed: MonitorResult;
  try {
    const response = await callClaudeWithTools({
      system:       MONITOR_PROMPT,
      user:         prompt,
      tools,
      toolHandlers,
      maxTokens:    1024,
      maxRounds:    4,
      agentLabel:   `monitor:${chain}`,
    });

    const match = response.match(/\{[\s\S]*\}/);
    parsed = JSON.parse(match?.[0] ?? response) as MonitorResult;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
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
      summary: `Error on ${chain}: ${msg.slice(0, 120)}`,
    };
  }

  return { monitorResults: { [chain]: parsed } };
}
