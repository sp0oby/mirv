// Shared on-chain helpers for the read-only pages (/dashboard, /activity,
// /analytics). Uses viem direct-RPC reads, NOT wagmi — these pages don't
// need a connected wallet, and bypassing wagmi keeps the bundle light.
//
// All reads are server-side by default (these helpers are called from
// async server components). Next's fetch cache + the `revalidate` option
// on each page handle freshness — a single user load triggers one RPC,
// subsequent loads within the revalidate window serve cached HTML.

import { createPublicClient, http, parseAbi, type Address } from "viem";
import { baseSepolia, sepolia } from "viem/chains";
import { keccak256, encodeAbiParameters, parseAbiParameters } from "viem";

// ─── rc6 testnet addresses (verified on chain) ────────────────────────────
export const ADDR = {
  base: {
    chain:    baseSepolia,
    rpc:      "https://sepolia.base.org",
    hook:     "0xA059C8544E046F29C5c2A9f0dE6314964926c540" as Address,
    vault:    "0x062b9E547689D53D9c5b059215ED967a9ceAf37b" as Address,
    factory:  "0xC3e117CD904db351F919134adCee7237F3ebC2A7" as Address,
    treasury: "0x00288400B0202Fa7c236d52685fFd725B4780392" as Address,
    usdc:     "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as Address,
    weth:     "0x4200000000000000000000000000000000000006" as Address,
    stateView:    "0x571291b572ed32ce6751a2cb2486ebee8defb9b4" as Address,
    poolManager:  "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408" as Address,
  },
  eth: {
    chain:   sepolia,
    rpc:     "https://ethereum-sepolia.publicnode.com",
    hook:    "0xc3233eb9c427cc1aca5cf2d5c5e89c668f148540" as Address,
    relayer: "0x5D7BA93B47f93eaa359ca6063F39Eaeb4743b727" as Address,
    usdc:    "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as Address,
    weth:    "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14" as Address,
    stateView:   "0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c" as Address,
    poolManager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543" as Address,
  },
};

export const CANONICAL_PAIR_ID =
  "0x7a00c543412ae44415418950dc1ea26ae8977c50cbcec8035a5d99a911085b04" as `0x${string}`;

// ─── Public clients (one per chain) ───────────────────────────────────────
// No explicit PublicClient annotation — viem's generic default doesn't
// accept chain-specific transaction unions (baseSepolia / sepolia carry
// OP-stack + eth tx types). Let TS infer the precise client type.
export const baseClient = createPublicClient({
  chain: baseSepolia,
  transport: http(ADDR.base.rpc),
});
export const ethClient = createPublicClient({
  chain: sepolia,
  transport: http(ADDR.eth.rpc),
});

// ─── ABI fragments (just what we read) ────────────────────────────────────
const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function principalTracked() view returns (uint256)",
  "function crossChainAssetsReported() view returns (uint256)",
  "function lastCrossChainAssetsUpdate() view returns (uint256)",
  "function lastHarvestAt() view returns (uint256)",
  "function paused() view returns (bool)",
  "function maxCrossChainAssetsDeltaBps() view returns (uint256)",
  "function crossChainAssetsMaxStaleness() view returns (uint256)",
  "function getChainConfig(uint32 domain) view returns (bytes32 cctpRecipient, bytes32 warpRecipient, address warpRouter, uint32 cctpDomain, uint16 allocationBps, bool enabled)",
  "function enabledDomainsCount() view returns (uint256)",
]);
const hookAbi = parseAbi([
  "function localDepthUsd(bytes32 poolId) view returns (uint256)",
  "function paused() view returns (bool)",
  "function guardian() view returns (address)",
  "function oracleDeviationToleranceBps() view returns (uint256)",
  "function maxSisterDepthMultiple() view returns (uint256)",
  "function dispatchCooldown() view returns (uint256)",
  "function lastDispatchTime(bytes32 poolId) view returns (uint256)",
]);
const stateViewAbi = parseAbi([
  "function getLiquidity(bytes32 poolId) view returns (uint128)",
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
]);
const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
]);

// ─── Pool IDs (canonical V4 keccak of (currency0,currency1,fee,tickSpacing,hook)) ──
function poolIdFor(chain: "base" | "eth"): `0x${string}` {
  const t0 = chain === "base" ? ADDR.base.usdc : ADDR.eth.usdc;
  const t1 = chain === "base" ? ADDR.base.weth : ADDR.eth.weth;
  const hook = chain === "base" ? ADDR.base.hook : ADDR.eth.hook;
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters("address, address, uint24, int24, address"),
      [t0, t1, 3000, 60, hook]
    )
  );
}
export const POOL_ID = {
  base: poolIdFor("base"),
  eth:  poolIdFor("eth"),
};

// ─── Aggregated dashboard read ─────────────────────────────────────────────
export async function readDashboardState() {
  const [
    totalAssets, totalSupply, paused, principal, crossChain, lastUpdate, lastHarvest,
    baseDepth, ethDepth,
    baseLiquidity, ethLiquidity,
    baseCfg, ethCfg,
    baseHookEth, ethHookEth,
    baseHookPaused, ethHookPaused,
    baseDispatchCooldown,
  ] = await Promise.all([
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "totalAssets" }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "totalSupply" }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "paused" }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "principalTracked" }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "crossChainAssetsReported" }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "lastCrossChainAssetsUpdate" }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "lastHarvestAt" }),
    baseClient.readContract({ address: ADDR.base.hook, abi: hookAbi, functionName: "localDepthUsd", args: [POOL_ID.base] }),
    ethClient.readContract({ address: ADDR.eth.hook, abi: hookAbi, functionName: "localDepthUsd", args: [POOL_ID.eth] }),
    baseClient.readContract({ address: ADDR.base.stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [POOL_ID.base] }),
    ethClient.readContract({ address: ADDR.eth.stateView, abi: stateViewAbi, functionName: "getLiquidity", args: [POOL_ID.eth] }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "getChainConfig", args: [84532] }),
    baseClient.readContract({ address: ADDR.base.vault, abi: vaultAbi, functionName: "getChainConfig", args: [11155111] }),
    baseClient.getBalance({ address: ADDR.base.hook }),
    ethClient.getBalance({ address: ADDR.eth.hook }),
    baseClient.readContract({ address: ADDR.base.hook, abi: hookAbi, functionName: "paused" }),
    ethClient.readContract({ address: ADDR.eth.hook, abi: hookAbi, functionName: "paused" }),
    baseClient.readContract({ address: ADDR.base.hook, abi: hookAbi, functionName: "dispatchCooldown" }),
  ]);

  return {
    totalAssets, totalSupply, paused, principal, crossChain, lastUpdate, lastHarvest,
    baseDepth, ethDepth,
    baseLiquidity, ethLiquidity,
    baseAllocBps: baseCfg[4],
    ethAllocBps: ethCfg[4],
    baseHookEth, ethHookEth,
    baseHookPaused, ethHookPaused,
    baseDispatchCooldown,
  };
}

// ─── Recent event logs ─────────────────────────────────────────────────────
const REBALANCE_DISPATCHED_SIG  = "0x77217c310b3d5c6d5861952af2ead823c253688a96e3d3be429595cbb8f2dfd4" as const;
const MESSAGE_RECEIVED_SIG      = "0xeba43e9ea0ac3a020eb8fd764362e091697bf130253b5c673b2dd971ffe57e92" as const;
const REBALANCE_EXECUTED_SIG    = "0xa5baee8606e271828289b2d073b254ad9ab4ae343b08a2035ad0a15e064b74dc" as const;
const REBALANCE_SKIPPED_ZERO_SIG= "0x18970bcead282a09ca6c99f4e3e976948b43fd1d23e374f4e0e842e9ba7df906" as const;
const SISTER_NOTIFICATION_SIG   = "0x36e6dff5fc9b03c6d8007b446d5e4745b5b72fa7090c43b5fccfdc147ccbbd30" as const;
const SISTER_DEPTH_CAPPED_SIG   = "0x57154ac65695edd9395f780e10dc1894b86edf1aa999e23fa3682d6d9cb22866" as const;

export type ActivityEvent = {
  id: string;
  kind: "dispatch" | "execute" | "skip" | "notify" | "cap";
  chain: "base" | "eth";
  tx: `0x${string}`;
  block: bigint;
  topic0: `0x${string}`;
  msgId?: `0x${string}`;
  destDomain?: number;
};

const RECENT_BLOCKS_BASE = 2_000n; // ~1 hour at 2s blocks
const RECENT_BLOCKS_ETH  = 300n;   // ~1 hour at 12s blocks

export async function readRecentActivity(): Promise<ActivityEvent[]> {
  const [latestBase, latestEth] = await Promise.all([
    baseClient.getBlockNumber(),
    ethClient.getBlockNumber(),
  ]);
  const baseFromBlock = latestBase > RECENT_BLOCKS_BASE ? latestBase - RECENT_BLOCKS_BASE : 0n;
  const ethFromBlock  = latestEth  > RECENT_BLOCKS_ETH  ? latestEth  - RECENT_BLOCKS_ETH  : 0n;

  // Event ABIs as viem AbiEvent objects. `indexed: true` on indexed
  // params lets viem hydrate the topics correctly.
  const dispatchedEvent = { type: "event", name: "RebalanceDispatched", inputs: [
    { type: "bytes32", indexed: true,  name: "messageId" },
    { type: "uint32",                  name: "destinationDomain" },
    { type: "bytes32",                 name: "pairId" },
  ]} as const;
  const messageReceivedEvent = { type: "event", name: "MessageReceived", inputs: [
    { type: "uint32",  indexed: true, name: "origin" },
    { type: "bytes32", indexed: true, name: "sender" },
    { type: "bytes32",                name: "messageId" },
  ]} as const;
  const executedEvent = { type: "event", name: "RebalanceExecuted", inputs: [
    { type: "bytes32", indexed: true, name: "pairId" },
    { type: "int128",                 name: "deltaToken0" },
    { type: "int128",                 name: "deltaToken1" },
  ]} as const;
  const skippedEvent = { type: "event", name: "RebalanceSkippedZeroDelta", inputs: [
    { type: "bytes32", indexed: true, name: "pairId" },
  ]} as const;
  const sisterNotificationEvent = { type: "event", name: "SisterNotificationReceived", inputs: [
    { type: "uint32",  indexed: true, name: "origin" },
    { type: "bytes32", indexed: true, name: "sender" },
    { type: "bytes32",                name: "pairId" },
    { type: "uint256",                name: "reportedDepth" },
  ]} as const;
  const sisterCappedEvent = { type: "event", name: "SisterDepthCapped", inputs: [
    { type: "uint32",  indexed: true, name: "origin" },
    { type: "uint256",                name: "reported" },
    { type: "uint256",                name: "capped" },
  ]} as const;

  // Base side: hook dispatches + inbound handle() events. No Relayer on Base.
  // ETH side: relayer execution path + hook handle() inbound.
  const [
    baseDispatches, baseSisterNotifs, baseSisterCaps,
    ethRelayMsgs, ethExecutes, ethSkipped, ethSisterNotifs,
  ] = await Promise.all([
    baseClient.getLogs({ address: ADDR.base.hook,    event: dispatchedEvent,         fromBlock: baseFromBlock, toBlock: latestBase }),
    baseClient.getLogs({ address: ADDR.base.hook,    event: sisterNotificationEvent, fromBlock: baseFromBlock, toBlock: latestBase }),
    baseClient.getLogs({ address: ADDR.base.hook,    event: sisterCappedEvent,       fromBlock: baseFromBlock, toBlock: latestBase }),
    ethClient.getLogs({  address: ADDR.eth.relayer,  event: messageReceivedEvent,    fromBlock: ethFromBlock,  toBlock: latestEth  }),
    ethClient.getLogs({  address: ADDR.eth.relayer,  event: executedEvent,           fromBlock: ethFromBlock,  toBlock: latestEth  }),
    ethClient.getLogs({  address: ADDR.eth.relayer,  event: skippedEvent,            fromBlock: ethFromBlock,  toBlock: latestEth  }),
    ethClient.getLogs({  address: ADDR.eth.hook,     event: sisterNotificationEvent, fromBlock: ethFromBlock,  toBlock: latestEth  }),
  ]);

  const events: ActivityEvent[] = [];
  for (const l of baseDispatches)   events.push({ id: `${l.transactionHash}-${l.logIndex}`, kind: "dispatch", chain: "base", tx: l.transactionHash!, block: l.blockNumber!, topic0: l.topics[0]!, msgId: l.topics[1] as `0x${string}` });
  for (const l of baseSisterNotifs) events.push({ id: `${l.transactionHash}-${l.logIndex}`, kind: "notify",   chain: "base", tx: l.transactionHash!, block: l.blockNumber!, topic0: l.topics[0]! });
  for (const l of baseSisterCaps)   events.push({ id: `${l.transactionHash}-${l.logIndex}`, kind: "cap",      chain: "base", tx: l.transactionHash!, block: l.blockNumber!, topic0: l.topics[0]! });
  for (const l of ethRelayMsgs)     events.push({ id: `${l.transactionHash}-${l.logIndex}`, kind: "dispatch", chain: "eth",  tx: l.transactionHash!, block: l.blockNumber!, topic0: l.topics[0]! });
  for (const l of ethExecutes)      events.push({ id: `${l.transactionHash}-${l.logIndex}`, kind: "execute",  chain: "eth",  tx: l.transactionHash!, block: l.blockNumber!, topic0: l.topics[0]! });
  for (const l of ethSkipped)       events.push({ id: `${l.transactionHash}-${l.logIndex}`, kind: "skip",     chain: "eth",  tx: l.transactionHash!, block: l.blockNumber!, topic0: l.topics[0]! });
  for (const l of ethSisterNotifs)  events.push({ id: `${l.transactionHash}-${l.logIndex}`, kind: "notify",   chain: "eth",  tx: l.transactionHash!, block: l.blockNumber!, topic0: l.topics[0]! });

  events.sort((a, b) => Number(b.block - a.block));
  return events.slice(0, 30);
}

// helpers used by view code
export function shortTx(h: `0x${string}` | string): string {
  if (!h || !h.startsWith("0x") || h.length < 12) return h;
  return `${h.slice(0, 8)}…${h.slice(-4)}`;
}
export function formatUsdc(n: bigint): string {
  return (Number(n) / 1e6).toLocaleString(undefined, { maximumFractionDigits: 2 });
}
export function timeAgo(secondsTimestamp: bigint | number): string {
  const ts = typeof secondsTimestamp === "bigint" ? Number(secondsTimestamp) : secondsTimestamp;
  if (ts === 0) return "never";
  const ago = Math.floor(Date.now() / 1000) - ts;
  if (ago < 60) return `${ago}s ago`;
  if (ago < 3600) return `${Math.floor(ago / 60)}m ago`;
  if (ago < 86400) return `${Math.floor(ago / 3600)}h ago`;
  return `${Math.floor(ago / 86400)}d ago`;
}
