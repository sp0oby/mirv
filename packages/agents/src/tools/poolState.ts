import { createPublicClient, http, parseAbi, type Address } from "viem";
import { mainnet, base, bsc } from "viem/chains";
import { tool } from "@langchain/core/tools";
import { z } from "zod";

// ─── Chain clients ────────────────────────────────────────────────────────────
const clients = {
  ethereum: createPublicClient({ chain: mainnet, transport: http(process.env.ALCHEMY_MAINNET_URL) }),
  base:     createPublicClient({ chain: base,    transport: http(process.env.ALCHEMY_BASE_URL) }),
  bnb:      createPublicClient({ chain: bsc,     transport: http(process.env.ALCHEMY_BNB_URL) }),
} as const;

const POOL_MANAGERS: Record<string, Address> = {
  ethereum: "0x000000000004444c5dc75cB358380D2e3dE08A90",
  base:     "0x498581ff718922c3f8e6a244956af099b2652b2b",
  bnb:      (process.env.POOL_MANAGER_BNB ?? "0x0000000000000000000000000000000000000000") as Address,
};

const poolManagerAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
]);

const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);

const chainlinkAbi = parseAbi([
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
  "function decimals() view returns (uint8)",
]);

// ─── Tool: getPoolState ───────────────────────────────────────────────────────
export const getPoolStateTool = tool(
  async ({ chain, token0, token1, feeTier, tickSpacing, hookAddress }) => {
    const client = clients[chain as keyof typeof clients];
    const pm     = POOL_MANAGERS[chain];

    // Compute V4 poolId = keccak256(abi.encode(PoolKey))
    const { keccak256, encodeAbiParameters, parseAbiParameters } = await import("viem");
    const poolId = keccak256(encodeAbiParameters(
      parseAbiParameters("address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks"),
      [token0 as Address, token1 as Address, feeTier, tickSpacing, hookAddress as Address]
    ));

    const [slot0, liquidity] = await Promise.all([
      client.readContract({ address: pm, abi: poolManagerAbi, functionName: "getSlot0", args: [poolId] }),
      client.readContract({ address: pm, abi: poolManagerAbi, functionName: "getLiquidity", args: [poolId] }),
    ]);

    return {
      chain,
      poolId,
      sqrtPriceX96: slot0[0].toString(),
      tick:          slot0[1],
      fee:           slot0[3],
      liquidity:     liquidity.toString(),
    };
  },
  {
    name: "getPoolState",
    description: "Read current V4 pool state (price, tick, liquidity) for a pair on a specific chain",
    schema: z.object({
      chain:       z.enum(["ethereum", "base", "bnb"]),
      token0:      z.string().describe("token0 address (must be < token1)"),
      token1:      z.string().describe("token1 address"),
      feeTier:     z.number().describe("V4 fee tier e.g. 3000"),
      tickSpacing: z.number().describe("tick spacing e.g. 60"),
      hookAddress: z.string().describe("MirrorHook address on this chain"),
    }),
  }
);

// ─── Tool: getChainlinkPrice ──────────────────────────────────────────────────
export const getChainlinkPriceTool = tool(
  async ({ chain, feedAddress }) => {
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
  {
    name: "getChainlinkPrice",
    description: "Read Chainlink price feed with staleness validation",
    schema: z.object({
      chain:       z.enum(["ethereum", "base", "bnb"]),
      feedAddress: z.string().describe("Chainlink AggregatorV3 feed address"),
    }),
  }
);

// ─── Tool: getTokenBalance ────────────────────────────────────────────────────
export const getTokenBalanceTool = tool(
  async ({ chain, token, account }) => {
    const client = clients[chain as keyof typeof clients];
    const [balance, decimals] = await Promise.all([
      client.readContract({ address: token as Address, abi: erc20Abi, functionName: "balanceOf", args: [account as Address] }),
      client.readContract({ address: token as Address, abi: erc20Abi, functionName: "decimals" }),
    ]);
    return {
      chain,
      token,
      account,
      raw:     balance.toString(),
      formatted: Number(balance) / 10 ** decimals,
    };
  },
  {
    name: "getTokenBalance",
    description: "Get ERC-20 token balance for an account on a chain",
    schema: z.object({
      chain:   z.enum(["ethereum", "base", "bnb"]),
      token:   z.string(),
      account: z.string(),
    }),
  }
);

export const poolStateTools = [getPoolStateTool, getChainlinkPriceTool, getTokenBalanceTool];
