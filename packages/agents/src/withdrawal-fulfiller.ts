// Async withdrawal fulfillment sweep.
//
// When a user calls `vault.requestWithdraw(shares, receiver)`, the vault
// custody-holds the shares + emits `WithdrawRequested(requestId, ...)`.
// The shares stay queued until either:
//   (a) the agent calls `vault.fulfillWithdraw(requestId)` once enough
//       local USDC exists in the vault, OR
//   (b) 24h elapses and the user calls `vault.cancelWithdraw(requestId)`
//       to reclaim their shares.
//
// Without an agent fulfillment loop, every async withdrawal sits unanswered
// until the user manually cancels. This sweep closes that gap.
//
// Pattern: each cycle, read the last N hours of `WithdrawRequested` events,
// dedupe against on-chain state, and fulfill any that have enough vault USDC
// to cover. Requests requiring cross-chain unwind are logged + left for a
// follow-up extended path (see TODO 8.5.10 sub-task).
//
// Authorization: vault.fulfillWithdraw is gated by `authorizedAgents[msg.sender]`,
// so the agent's hot wallet must be authorized on the vault (same key already
// used for updateCrossChainAssets / harvest / dispatchRebalance paths).

import { createPublicClient, createWalletClient, http, parseAbi, parseAbiItem, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chainFor } from "./chains.js";

const vaultAbi = parseAbi([
  "function fulfillWithdraw(uint256 requestId) external",
  "function withdrawRequests(uint256) view returns (address requester, address receiver, uint256 shares, uint256 expectedAssets, uint256 createdAt, bool fulfilled, bool cancelled)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
]);

const usdcAbi = parseAbi(["function balanceOf(address) view returns (uint256)"]);

// Vault event signature. Captured by the monitor's getLogs sweep.
const withdrawRequestedEvent = parseAbiItem(
  "event WithdrawRequested(uint256 indexed requestId, address indexed requester, address indexed receiver, uint256 shares, uint256 expectedAssets)"
);

export interface FulfilledRecord {
  requestId: string;
  txHash: string;
  receiver: string;
  assetsPaid: string;
}

export interface PendingRecord {
  requestId: string;
  reason: string;
}

export interface FulfillmentReport {
  fulfilled: FulfilledRecord[];
  pending: PendingRecord[];
  errors: string[];
}

function normalizePrivateKey(pk: string | undefined): `0x${string}` {
  if (!pk) throw new Error("AGENT_PRIVATE_KEY not set");
  return (pk.startsWith("0x") ? pk : `0x${pk}`) as `0x${string}`;
}

// Pure decision function — extracted for unit testing.
export type FulfillmentDecision =
  | "fulfill"
  | "skip-already-fulfilled"
  | "skip-cancelled"
  | "skip-zero-shares"
  | "needs-cross-chain-unwind";

export function decideFulfillment(
  req: { shares: bigint; fulfilled: boolean; cancelled: boolean },
  vaultUsdcBalance: bigint,
  assetsOwed: bigint,
): FulfillmentDecision {
  if (req.fulfilled) return "skip-already-fulfilled";
  if (req.cancelled) return "skip-cancelled";
  if (req.shares === 0n) return "skip-zero-shares";
  if (vaultUsdcBalance < assetsOwed) return "needs-cross-chain-unwind";
  return "fulfill";
}

/// Sweep recent WithdrawRequested events + try to fulfill each that has
/// enough vault USDC to cover. Safe to call every cycle; idempotent — the
/// vault's `fulfilled` flag prevents double-fulfillment.
///
/// @param lookbackBlocks Number of blocks back to scan for events. ~2000
///        ≈ 1 hour on Base at 2s blocks. Lower bound is "we already swept
///        this; nothing should be older than our cycle interval".
export async function runWithdrawalFulfiller(opts?: {
  lookbackBlocks?: bigint;
}): Promise<FulfillmentReport> {
  const report: FulfillmentReport = { fulfilled: [], pending: [], errors: [] };

  const vaultAddress = process.env.MIRROR_VAULT_BASE as Address;
  const usdcAddress  = process.env.USDC_BASE_SEPOLIA as Address ?? process.env.VAULT_ASSET_BASE as Address;
  if (!vaultAddress) {
    report.errors.push("MIRROR_VAULT_BASE not set");
    return report;
  }

  const account      = privateKeyToAccount(normalizePrivateKey(process.env.AGENT_PRIVATE_KEY));
  const baseChain    = chainFor("base");
  const publicClient = createPublicClient({ chain: baseChain, transport: http(process.env.ALCHEMY_BASE_URL) });
  const walletClient = createWalletClient({ chain: baseChain, account, transport: http(process.env.ALCHEMY_BASE_URL) });

  // Scan recent WithdrawRequested events
  let logs;
  try {
    const latest = await publicClient.getBlockNumber();
    const lookback = opts?.lookbackBlocks ?? 2_000n;
    const fromBlock = latest > lookback ? latest - lookback : 0n;
    logs = await publicClient.getLogs({
      address: vaultAddress,
      event:   withdrawRequestedEvent,
      fromBlock,
      toBlock: latest,
    });
  } catch (err) {
    report.errors.push(`getLogs failed: ${err instanceof Error ? err.message : String(err)}`);
    return report;
  }

  if (logs.length === 0) return report;

  console.log(`  [withdrawal-fulfiller] scanning ${logs.length} recent WithdrawRequested event(s)`);

  for (const log of logs) {
    const requestId = log.args.requestId;
    if (requestId === undefined) continue;
    const idStr = requestId.toString();

    // Re-read on-chain state — events are an index, not the truth.
    let req: readonly [Address, Address, bigint, bigint, bigint, boolean, boolean];
    try {
      req = await publicClient.readContract({
        address:      vaultAddress,
        abi:          vaultAbi,
        functionName: "withdrawRequests",
        args:         [requestId],
      });
    } catch (err) {
      report.errors.push(`read request ${idStr} failed: ${err instanceof Error ? err.message : String(err)}`);
      continue;
    }

    const [, receiver, shares, , createdAt, fulfilled, cancelled] = req;

    // Compute payout in asset units (USDC raw) + check vault has the balance.
    let assetsOwed: bigint;
    let vaultUsdcBalance: bigint;
    try {
      [assetsOwed, vaultUsdcBalance] = await Promise.all([
        publicClient.readContract({
          address: vaultAddress, abi: vaultAbi, functionName: "convertToAssets", args: [shares],
        }),
        publicClient.readContract({
          address: usdcAddress, abi: usdcAbi, functionName: "balanceOf", args: [vaultAddress],
        }),
      ]);
    } catch (err) {
      report.errors.push(`read sizing for ${idStr} failed: ${err instanceof Error ? err.message : String(err)}`);
      continue;
    }

    const decision = decideFulfillment(
      { shares, fulfilled, cancelled },
      vaultUsdcBalance,
      assetsOwed,
    );

    if (decision === "skip-already-fulfilled" || decision === "skip-cancelled" || decision === "skip-zero-shares") {
      continue;
    }

    if (decision === "needs-cross-chain-unwind") {
      report.pending.push({
        requestId: idStr,
        reason: `vault has ${vaultUsdcBalance} USDC; needs ${assetsOwed} — requires cross-chain unwind (TODO)`,
      });
      const ageSeconds = Math.floor(Date.now() / 1000) - Number(createdAt);
      console.log(`  [withdrawal-fulfiller] request ${idStr} needs cross-chain unwind (${ageSeconds}s old)`);
      continue;
    }

    // decision === "fulfill" — vault has enough local USDC; fulfill directly.
    try {
      const { request } = await publicClient.simulateContract({
        account,
        address:      vaultAddress,
        abi:          vaultAbi,
        functionName: "fulfillWithdraw",
        args:         [requestId],
      });
      const txHash = await walletClient.writeContract(request);
      console.log(`  [withdrawal-fulfiller] fulfilled request ${idStr} -> tx ${txHash}`);
      report.fulfilled.push({
        requestId: idStr,
        txHash,
        receiver:  receiver,
        assetsPaid: assetsOwed.toString(),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      report.errors.push(`fulfill ${idStr}: ${msg.slice(0, 200)}`);
      console.log(`  [withdrawal-fulfiller] fulfill ${idStr} failed: ${msg.slice(0, 120)}`);
    }
  }

  return report;
}
