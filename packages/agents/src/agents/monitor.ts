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

// V4 StateView lens contracts — checksums verified via `cast to-check-sum-address`
const STATE_VIEWS: Record<string, Address> = {
  ethereum: "0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227",
  base:     "0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71",
  bnb:      "0xd13Dd3D6E93f276FAfc9Db9E6BB47C1180aeE0c4",
};

const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
]);

const chainlinkAbi = parseAbi([
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
  "function decimals() view returns (uint8)",
]);

const erc20Abi = parseAbi([
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

// ─── V4 TVL math (universal — works on any chain with a V4 PoolManager) ─────
//
// V4 pool state gives us (sqrtPriceX96, liquidity at current tick). For a
// concentrated liquidity AMM, the active token amounts at the current price are:
//
//   amount0 ≈ L / sqrtPrice    (in raw token0 units)
//   amount1 ≈ L * sqrtPrice    (in raw token1 units)
//
// where sqrtPrice = sqrtPriceX96 / 2^96 (in token1/token0 ratio).
// Convert to USD via Chainlink prices for each token.
const Q96 = 2 ** 96;
function estimatePoolTvl(opts: {
  sqrtPriceX96:   bigint;
  liquidity:      bigint;
  token0Decimals: number;
  token1Decimals: number;
  token0PriceUsd: number;
  token1PriceUsd: number;
}): { tvlUsd: number; amount0: number; amount1: number } {
  if (opts.liquidity === 0n) return { tvlUsd: 0, amount0: 0, amount1: 0 };

  // sqrtPrice as Number — fine for estimates (concrete trades read raw integers on-chain)
  const sqrtPrice = Number(opts.sqrtPriceX96) / Q96;
  const L         = Number(opts.liquidity);

  const amount0Raw = L / sqrtPrice;
  const amount1Raw = L * sqrtPrice;

  const amount0 = amount0Raw / 10 ** opts.token0Decimals;
  const amount1 = amount1Raw / 10 ** opts.token1Decimals;

  const tvlUsd = amount0 * opts.token0PriceUsd + amount1 * opts.token1PriceUsd;
  return { tvlUsd, amount0, amount1 };
}

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
      // Read pool state + both token decimals + ETH/USD price in parallel.
      // Assume token1 is a stablecoin (USDC) at $1 — robust enough for ETH/USDC.
      // Future: read both prices from Chainlink for non-stable pairs.
      const chainlinkFeed = chain === "bnb"
        ? (process.env.CHAINLINK_ETH_USD_BNB ?? "")
        : (process.env[`CHAINLINK_ETH_USD_${chain === "ethereum" ? "MAINNET" : "BASE"}`] ?? "");

      const [slot0, liquidity, dec0, dec1, clRound, clDecimals] = await Promise.all([
        client.readContract({ address: stateView, abi: stateViewAbi, functionName: "getSlot0",     args: [poolId] }),
        client.readContract({ address: stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [poolId] }),
        client.readContract({ address: token0 as Address, abi: erc20Abi, functionName: "decimals" }),
        client.readContract({ address: token1 as Address, abi: erc20Abi, functionName: "decimals" }),
        client.readContract({ address: chainlinkFeed as Address, abi: chainlinkAbi, functionName: "latestRoundData" }),
        client.readContract({ address: chainlinkFeed as Address, abi: chainlinkAbi, functionName: "decimals" }),
      ]);

      const ethUsd = Number(clRound[1]) / 10 ** Number(clDecimals);
      const tvl = estimatePoolTvl({
        sqrtPriceX96:   slot0[0],
        liquidity:      liquidity,
        token0Decimals: Number(dec0),
        token1Decimals: Number(dec1),
        token0PriceUsd: ethUsd,  // assumes token0 = WETH-like
        token1PriceUsd: 1,       // assumes token1 = USDC-like
      });

      const result = {
        chain,
        poolId,
        sqrtPriceX96: slot0[0].toString(),
        tick:         slot0[1],
        fee:          slot0[3],
        liquidity:    liquidity.toString(),
        token0:       { decimals: Number(dec0), priceUsd: ethUsd },
        token1:       { decimals: Number(dec1), priceUsd: 1 },
        depthUsd:     Math.round(tvl.tvlUsd),
        amount0:      tvl.amount0,
        amount1:      tvl.amount1,
      };
      console.log(`  [tool:getPoolState:${chain}] liquidity=${liquidity} tvl=$${result.depthUsd}`);
      return result;
    } catch (err) {
      const msg = err instanceof Error ? err.message : "?";
      console.log(`  [tool:getPoolState:${chain}] FAILED — ${msg.slice(0, 120)}`);
      return {
        chain, poolId,
        sqrtPriceX96: "0", tick: 0, fee: feeTier, liquidity: "0",
        depthUsd: 0,
        note: `Pool read failed: ${msg.slice(0, 100)}`,
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

  // Chain-appropriate token addresses (currency0 must be < currency1 for V4).
  // All three chains use the canonical ETH + USDC pair for the mirv protocol.
  // Toggled by NETWORK env var: "mainnet" (default) | "sepolia"
  const MAINNET_TOKENS: Record<Chain, { token0: string; token1: string; }> = {
    ethereum: { token0: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", token1: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" }, // USDC < WETH on mainnet
    base:     { token0: "0x4200000000000000000000000000000000000006", token1: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" }, // WETH < USDC on Base
    bnb:      { token0: "0x2170Ed0880ac9A755fd29B2688956BD959F933F8", token1: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d" }, // ETH-bep < USDC-bep on BNB
  };
  const SEPOLIA_TOKENS: Record<Chain, { token0: string; token1: string; }> = {
    ethereum: { token0: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", token1: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14" }, // USDC < WETH on Sepolia
    base:     { token0: "0x4200000000000000000000000000000000000006", token1: "0x036CbD53842c5426634e7929541eC2318f3dCF7e" }, // WETH < USDC on Base Sepolia
    bnb:      { token0: "0x0000000000000000000000000000000000000000", token1: "0x0000000000000000000000000000000000000000" }, // V4 not on BNB testnet
  };
  const tokens = process.env.NETWORK === "sepolia" ? SEPOLIA_TOKENS : MAINNET_TOKENS;

  const t = tokens[chain];
  const prompt = `Monitor the ETH/USDC pool on ${chain}.

Pool parameters:
- token0: ${t.token0}
- token1: ${t.token1}
- fee:    3000 (0.3%)
- tickSpacing: 60
- hook:   ${hookAddress}

CALL getPoolState({chain: "${chain}", token0: "${t.token0}", token1: "${t.token1}", feeTier: 3000, tickSpacing: 60, hookAddress: "${hookAddress}"})
The tool returns depthUsd (already computed via V4 TVL math). Use this directly — DO NOT recompute.

If depthUsd is non-zero, treat this chain as having real liquidity.
If depthUsd is 0 (pool not initialized or no liquidity), report localDepthUsd: 0 and treat as needing attention if other chains have depth.

Compare with previously reported sister depths (0 if unknown). Flag actionNeeded=true if any of:
- imbalance > 3% (max sister depth differs from min by >3%)
- price drift > 2%
- This chain has depth but a sister has 0 (or vice versa)

Output ONLY a MonitorResult JSON, no other text.`;

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
    console.log(`  [monitor:${chain}] depth=$${parsed.localDepthUsd?.toFixed(0) ?? 'NaN'} imbalance=${parsed.imbalancePct?.toFixed(2) ?? 'NaN'}% action=${parsed.actionNeeded}`);
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
