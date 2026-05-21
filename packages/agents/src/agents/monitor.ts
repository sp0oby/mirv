import {
  createPublicClient, http, parseAbi, type Address,
  encodeAbiParameters, parseAbiParameters, keccak256,
} from "viem";
import type Anthropic from "@anthropic-ai/sdk";
import { callClaudeWithTools } from "../llm.js";
import { MONITOR_PROMPT } from "../prompts/loader.js";
import type { MirrorState, MonitorResult, Chain } from "../state.js";
import { chainFor } from "../chains.js";

// ─── Chain clients ────────────────────────────────────────────────────────────
// chainFor() resolves the right viem chain object based on NETWORK env so
// chainId matches the RPC. Critical for multicall3 routing + tx signing.
const clients = {
  ethereum: createPublicClient({ chain: chainFor("ethereum"), transport: http(process.env.ALCHEMY_MAINNET_URL) }),
  base:     createPublicClient({ chain: chainFor("base"),     transport: http(process.env.ALCHEMY_BASE_URL) }),
  bnb:      createPublicClient({ chain: chainFor("bnb"),      transport: http(process.env.ALCHEMY_BNB_URL) }),
} as const;

// V4 PoolManager + StateView lens addresses, network-aware.
// On NETWORK=sepolia we use the Sepolia equivalents; otherwise canonical mainnet.
// Env overrides take precedence so per-deploy variations stay configurable.
const NETWORK = process.env.NETWORK ?? "mainnet";
const IS_SEPOLIA = NETWORK === "sepolia";

const POOL_MANAGERS: Record<string, Address> = {
  ethereum: (IS_SEPOLIA
    ? (process.env.POOL_MANAGER_ETH_SEPOLIA ?? "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543")
    : (process.env.POOL_MANAGER_MAINNET    ?? "0x000000000004444c5dc75cB358380D2e3dE08A90")) as Address,
  base:     (IS_SEPOLIA
    ? (process.env.POOL_MANAGER_BASE_SEPOLIA ?? "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408")
    : (process.env.POOL_MANAGER_BASE         ?? "0x498581fF718922c3f8e6A244956aF099B2652b2b")) as Address,
  bnb:      (process.env.POOL_MANAGER_BNB ?? "0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF") as Address,
};

// V4 StateView lens — separate contract per chain, exposes typed getters over
// PoolManager's extsload. Verified on-chain 2026-05-18 for Sepolia.
const STATE_VIEWS: Record<string, Address> = {
  ethereum: (IS_SEPOLIA
    ? (process.env.STATE_VIEW_ETH_SEPOLIA ?? "0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c")
    : (process.env.STATE_VIEW_MAINNET    ?? "0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227")) as Address,
  base:     (IS_SEPOLIA
    ? (process.env.STATE_VIEW_BASE_SEPOLIA ?? "0x571291b572ed32ce6751a2cb2486ebee8defb9b4")
    : (process.env.STATE_VIEW_BASE         ?? "0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71")) as Address,
  bnb:      (process.env.STATE_VIEW_BNB ?? "0xd13Dd3D6E93f276FAfc9Db9E6BB47C1180aeE0c4") as Address,
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
  "function balanceOf(address) view returns (uint256)",
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
      // NETWORK switch: on Sepolia, use the testnet Chainlink feed (env keys
      // _ETH_SEPOLIA / _BASE_SEPOLIA). Was hardcoded to mainnet feed addresses
      // pre-fix and silently returned 0x on Sepolia → Promise.all rejected → tool failed.
      const chainlinkFeed = chain === "bnb"
        ? (process.env.CHAINLINK_ETH_USD_BNB ?? "")
        : IS_SEPOLIA
          ? (process.env[`CHAINLINK_ETH_USD_${chain === "ethereum" ? "ETH_SEPOLIA" : "BASE_SEPOLIA"}`] ?? "")
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

      // Detect which token is the stablecoin via decimals heuristic.
      // 6-decimal token → USDC-style stable. 18-decimal token → WETH-style.
      // Works across Base mainnet (WETH=token0 6 < USDC=token1 12) AND testnets
      // (USDC=token0 6 < WETH=token1 18 since 0x036C < 0x4200 on Base Sepolia,
      //  0x1c7D < 0xfFf9 on ETH Sepolia). Without this branch the TVL math
      //  reported $2 quadrillion on ETH Sepolia (priced the WETH amount as USDC).
      const dec0n = Number(dec0);
      const dec1n = Number(dec1);
      const token0IsStable = dec0n === 6 && dec1n === 18;
      const token0PriceUsd = token0IsStable ? 1     : ethUsd;
      const token1PriceUsd = token0IsStable ? ethUsd : 1;

      const tvl = estimatePoolTvl({
        sqrtPriceX96:   slot0[0],
        liquidity:      liquidity,
        token0Decimals: dec0n,
        token1Decimals: dec1n,
        token0PriceUsd,
        token1PriceUsd,
      });

      const result = {
        chain,
        poolId,
        sqrtPriceX96: slot0[0].toString(),
        tick:         slot0[1],
        fee:          slot0[3],
        liquidity:    liquidity.toString(),
        token0:       { decimals: dec0n, priceUsd: token0PriceUsd },
        token1:       { decimals: dec1n, priceUsd: token1PriceUsd },
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

// Auto-LP — direct read of idle USDC + WETH balances at the LP-provider for
// a chain. On the home chain (Base) that's the vault; on sister chains it's
// the Relayer. We call this server-side so the strategist sees idle capital
// per cycle and can propose a provide-liquidity action.
//
// Returns USD-denominated values so the LLM can reason about magnitude
// without knowing per-token decimals.
async function readIdleCapital(
  chain: Chain,
  lpProviderAddress: string,
  token0: string,
  token1: string,
  ethUsd: number
): Promise<{ idleUsdc: number; idleWeth: number; idleUsdcUsd: number; idleWethUsd: number }> {
  try {
    const client = clients[chain as keyof typeof clients];
    const [bal0, bal1, dec0, dec1] = await Promise.all([
      client.readContract({ address: token0 as Address, abi: erc20Abi, functionName: "balanceOf", args: [lpProviderAddress as Address] }),
      client.readContract({ address: token1 as Address, abi: erc20Abi, functionName: "balanceOf", args: [lpProviderAddress as Address] }),
      client.readContract({ address: token0 as Address, abi: erc20Abi, functionName: "decimals" }),
      client.readContract({ address: token1 as Address, abi: erc20Abi, functionName: "decimals" }),
    ]);
    // Token0 is the stablecoin if decimals=6, else volatile (WETH 18).
    const dec0n = Number(dec0);
    const dec1n = Number(dec1);
    const token0IsStable = dec0n === 6 && dec1n === 18;
    const usdcRaw = token0IsStable ? bal0 : bal1;
    const wethRaw = token0IsStable ? bal1 : bal0;
    const idleUsdcUsd = Number(usdcRaw) / 1e6;
    const idleWethUsd = (Number(wethRaw) / 1e18) * ethUsd;
    return {
      idleUsdc: Number(usdcRaw),
      idleWeth: Number(wethRaw),
      idleUsdcUsd,
      idleWethUsd,
    };
  } catch {
    return { idleUsdc: 0, idleWeth: 0, idleUsdcUsd: 0, idleWethUsd: 0 };
  }
}

// 8.5.2 + 8.5.3 — direct (non-LLM) read of the canonical no-hook USDC/WETH
// pool on the same chain. Returns BOTH depth (for competitiveness) and the
// canonical tick (for tick-alignment drift detection). One read, two uses.
async function readCanonicalState(
  chain: Chain, token0: string, token1: string, feeTier: number, tickSpacing: number
): Promise<{ depthUsd: number; tick: number | null }> {
  try {
    const client    = clients[chain as keyof typeof clients];
    const stateView = STATE_VIEWS[chain];
    const ZERO_HOOK = "0x0000000000000000000000000000000000000000" as Address;
    const poolId = keccak256(encodeAbiParameters(
      parseAbiParameters("address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks"),
      [token0 as Address, token1 as Address, feeTier, tickSpacing, ZERO_HOOK]
    ));
    const chainlinkFeed = chain === "bnb"
      ? (process.env.CHAINLINK_ETH_USD_BNB ?? "")
      : IS_SEPOLIA
        ? (process.env[`CHAINLINK_ETH_USD_${chain === "ethereum" ? "ETH_SEPOLIA" : "BASE_SEPOLIA"}`] ?? "")
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
    const dec0n = Number(dec0);
    const dec1n = Number(dec1);
    const token0IsStable = dec0n === 6 && dec1n === 18;
    const tvl = estimatePoolTvl({
      sqrtPriceX96:   slot0[0],
      liquidity:      liquidity,
      token0Decimals: dec0n,
      token1Decimals: dec1n,
      token0PriceUsd: token0IsStable ? 1 : ethUsd,
      token1PriceUsd: token0IsStable ? ethUsd : 1,
    });
    return { depthUsd: Math.round(tvl.tvlUsd), tick: Number(slot0[1]) };
  } catch {
    return { depthUsd: 0, tick: null };
  }
}

export async function runMonitorAgent(
  chain: Chain,
  _state: MirrorState
): Promise<Partial<MirrorState>> {
  // Env-key naming mismatch: our env uses MIRROR_HOOK_MAINNET / _BASE / _BNB
  // (matching the Deploy.s.sol convention) but `chain` is "ethereum" not "mainnet".
  // Without this translation, MIRROR_HOOK_ETHEREUM is unset → hookAddress=0x0 →
  // poolId computes for a no-hook USDC/WETH pool that exists on Sepolia with random
  // testnet liquidity (we saw L=1e18 from someone else's deposit, vs our L=2e9).
  const HOOK_ENV_KEY: Record<Chain, string> = {
    ethereum: "MIRROR_HOOK_MAINNET",
    base:     "MIRROR_HOOK_BASE",
    bnb:      "MIRROR_HOOK_BNB",
  };
  const hookAddress = process.env[HOOK_ENV_KEY[chain]] ?? "0x0000000000000000000000000000000000000000";
  // Chainlink ETH/USD feed: testnet env keys differ from mainnet, branch on NETWORK.
  const chainlinkFeed = chain === "bnb"
    ? (process.env.CHAINLINK_ETH_USD_BNB ?? "")
    : IS_SEPOLIA
      ? (process.env[`CHAINLINK_ETH_USD_${chain === "ethereum" ? "ETH_SEPOLIA" : "BASE_SEPOLIA"}`] ?? "")
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
    // Bug fix 2026-05-18: USDC (0x036C…) < WETH (0x4200…) on Base Sepolia so USDC IS token0.
    // The prior comment ("WETH < USDC on Base Sepolia") AND the field order were both wrong;
    // it matched Base mainnet's ordering, not Sepolia's. The wrong order computed a poolId for
    // a pool that doesn't exist on Sepolia → StateView reads returned 0x → agents thought
    // depth was zero on Base Sepolia for the whole 3-cycle soak. Verified against on-chain
    // poolId 0x689ccc80…7dcd.
    base:     { token0: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", token1: "0x4200000000000000000000000000000000000006" }, // USDC < WETH on Base Sepolia
    bnb:      { token0: "0x0000000000000000000000000000000000000000", token1: "0x0000000000000000000000000000000000000000" }, // V4 not on BNB testnet
  };
  const tokens = process.env.NETWORK === "sepolia" ? SEPOLIA_TOKENS : MAINNET_TOKENS;

  const t = tokens[chain];

  // 8.5.2 + 8.5.3 — read the canonical (no-hook) pool's depth AND current tick.
  // Depth -> competitiveness ratio. Tick -> drift detection for LP re-centering.
  const canonical = await readCanonicalState(chain, t.token0, t.token1, 3000, 60);
  const canonicalDepthUsd = canonical.depthUsd;
  const canonicalTick = canonical.tick;
  console.log(`  [monitor:${chain}] canonical depth=$${canonicalDepthUsd} tick=${canonicalTick ?? "n/a"}`);

  // Auto-LP — find this chain's LP provider (Vault on Base home chain, Relayer
  // on sister chains) and read its idle USDC + WETH balances. The strategist
  // uses these to propose provide-liquidity when deposits land but haven't yet
  // been turned into LP.
  // 8.5.9 — Base now has its own Relayer too (deployed via the same Relayer
  // contract, just on the home chain). The vault auto-forwards local share
  // to it on each deposit. Falls back to reading the vault directly if
  // RELAYER_BASE isn't configured (early-launch state where the relayer
  // hasn't been deployed yet).
  const LP_PROVIDER_ENV_KEY: Record<Chain, string | undefined> = {
    base:     process.env.RELAYER_BASE ? "RELAYER_BASE" : "MIRROR_VAULT_BASE",
    ethereum: "RELAYER_MAINNET",
    bnb:      "RELAYER_BNB",
  };
  const lpProviderEnv = LP_PROVIDER_ENV_KEY[chain];
  const lpProvider = lpProviderEnv ? (process.env[lpProviderEnv] ?? "") : "";
  // Use Chainlink's price for USD-denomination of WETH. Pull from canonical
  // read indirectly via env (we don't want to re-call Chainlink here).
  // Approximate: get the ETH/USD price from the canonical pool's TVL math
  // by assuming token0 stable + comparing depths. Simpler: hardcode a
  // reasonable ETH price when canonical read failed.
  const ethUsdApprox = canonicalDepthUsd > 0 && canonicalTick !== null
    ? 2000   // we'll let the agent figure exact; strategist gets the price elsewhere
    : 2000;
  const idle = lpProvider
    ? await readIdleCapital(chain, lpProvider, t.token0, t.token1, ethUsdApprox)
    : { idleUsdc: 0, idleWeth: 0, idleUsdcUsd: 0, idleWethUsd: 0 };
  console.log(`  [monitor:${chain}] idle@${lpProvider ? lpProvider.slice(0, 10) : "n/a"}: $${idle.idleUsdcUsd.toFixed(2)} USDC + $${idle.idleWethUsd.toFixed(2)} WETH`);

  const prompt = `Monitor the ETH/USDC pool on ${chain}. You are responsible for ONE chain only: ${chain}.

Pool parameters:
- token0: ${t.token0}
- token1: ${t.token1}
- fee:    3000 (0.3%)
- tickSpacing: 60
- hook:   ${hookAddress}

Known canonical-pool state on this chain (no-hook USDC/WETH at fee=3000, tickSpacing=60):
  depth: $${canonicalDepthUsd}
  current tick: ${canonicalTick ?? "unavailable"}
This was read server-side; do NOT call getPoolState a second time for the canonical pool. Use these numbers directly.

Idle capital sitting at this chain's LP provider (vault on Base, Relayer on sisters), read server-side:
  idle USDC: $${idle.idleUsdcUsd.toFixed(2)} ($${idle.idleUsdc} raw token units)
  idle WETH: $${idle.idleWethUsd.toFixed(2)} (${idle.idleWeth} wei)
If both are > $10 in USD value, this chain has deposits/inventory ready to be turned into LP. Flag it so the strategist proposes a provide-liquidity action.

INSTRUCTIONS — at most two tool calls, in this order:
1. CALL getPoolState({chain: "${chain}", token0: "${t.token0}", token1: "${t.token1}", feeTier: 3000, tickSpacing: 60, hookAddress: "${hookAddress}"}) — reads OUR hooked pool depth.
2. (Optional) CALL getChainlinkPrice({chain: "${chain}", feedAddress: "${chainlinkFeed}"}) — only if you need to verify the ETH/USD price the pool TVL math used.

DO NOT call getPoolState for any chain other than ${chain}. Sister-chain depths come from parallel monitor agents via the shared state.

Compute:
- competitivenessPct = (localDepthUsd / max(canonicalDepthUsd, 1)) × 100
- outOfRange = canonical tick is OUTSIDE [currentTickLow, currentTickHigh] of OUR pool
  (canonicalTick=${canonicalTick ?? "null"}; if null, set outOfRange=false)

Set actionNeeded=true if ANY of:
- THIS chain's depth changed meaningfully vs the prior cycle, OR
- this chain reports 0 unexpectedly, OR
- competitivenessPct < 10 — we're not competitive enough for routers to quote us, OR
- outOfRange === true — our LP range no longer brackets the canonical price; tick recenter is needed.

In your output JSON include:
- canonicalDepthUsd: ${canonicalDepthUsd}
- canonicalTick: ${canonicalTick ?? "null"}
- competitivenessPct (computed)
- outOfRange (computed)
- ourTick: read from the getPoolState tool result's "tick" field

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
    // Guarantee canonical + tick fields are set even if Claude omits them.
    if (parsed.canonicalDepthUsd === undefined) parsed.canonicalDepthUsd = canonicalDepthUsd;
    if (parsed.canonicalTick === undefined && canonicalTick !== null) {
      parsed.canonicalTick = canonicalTick;
    }
    if (parsed.competitivenessPct === undefined) {
      parsed.competitivenessPct = canonicalDepthUsd > 0
        ? Math.round((parsed.localDepthUsd / canonicalDepthUsd) * 100 * 100) / 100
        : 0;
    }
    // Server-side compute outOfRange as a sanity check on Claude's compute.
    if (canonicalTick !== null && parsed.currentTickLow !== undefined && parsed.currentTickHigh !== undefined) {
      const isOut = canonicalTick < parsed.currentTickLow || canonicalTick > parsed.currentTickHigh;
      parsed.outOfRange = isOut;
    }
    // Always inject server-read idle balances; Claude's view of them is just the prompt context.
    parsed.idleUsdc    = idle.idleUsdc;
    parsed.idleWeth    = idle.idleWeth;
    parsed.idleUsdcUsd = idle.idleUsdcUsd;
    parsed.idleWethUsd = idle.idleWethUsd;
    // Surface "ready to LP" in the action flag too, so the strategist can pick up
    // the signal without re-reading idle fields.
    const idleCapital = idle.idleUsdcUsd + idle.idleWethUsd;
    if (idleCapital > 10) parsed.actionNeeded = true;
    console.log(`  [monitor:${chain}] depth=$${parsed.localDepthUsd?.toFixed(0) ?? 'NaN'} canonical=$${canonicalDepthUsd} tick=${canonicalTick ?? "n/a"} outOfRange=${parsed.outOfRange ?? "?"} competitiveness=${parsed.competitivenessPct?.toFixed(2)}% idle=$${idleCapital.toFixed(2)} action=${parsed.actionNeeded}`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.log(`  [monitor:${chain}] CAUGHT — ${msg.slice(0, 200)}`);
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
      canonicalDepthUsd,
      competitivenessPct: 0,
      canonicalTick: canonicalTick ?? undefined,
      outOfRange: false,
      idleUsdc: idle.idleUsdc,
      idleWeth: idle.idleWeth,
      idleUsdcUsd: idle.idleUsdcUsd,
      idleWethUsd: idle.idleWethUsd,
    };
  }

  return { monitorResults: { [chain]: parsed } };
}
