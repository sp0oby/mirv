// In-progress cross-chain withdrawal unwind tracker.
//
// When the withdrawal-fulfiller hits a request that needs cross-chain unwind
// (vault has < assetsOwed), it initiates a two-step on-chain sequence on a
// sister chain:
//   1. Relayer.provideLiquidity(-deltas) — removes LP, releases USDC + WETH
//   2. Relayer.bridgeUsdcHome(amount)    — CCTP-burns USDC to the vault
//
// Step 2 takes ~20 min on testnet (CCTP attestation), and the vault doesn't
// receive the minted USDC until that completes. Without state tracking, the
// fulfiller would re-initiate the same unwind every 45s cycle — burning gas +
// LP fees + double-spending the inventory.
//
// This module records in-progress unwinds + lets the fulfiller skip a request
// while its CCTP message is in flight. Restart-impact: in-memory only, so an
// agent restart loses the tracker and could re-initiate. Mitigation: the
// timeout is short (30 min) and the chain itself enforces idempotency at the
// finishing step (vault.fulfillWithdraw checks the `fulfilled` flag).

import type { Chain } from "./state.js";

export interface InProgressUnwind {
  requestId: string;
  chain: Chain;
  amountUsdc: bigint;
  initiatedAtMs: number;
  expectedFulfillByMs: number;
}

/// CCTP testnet attestation takes ~20 min. Add a 10-min buffer to allow for
/// network congestion / failed delivery retries. After this window we
/// re-attempt the unwind (assume the previous one was lost).
export const UNWIND_TIMEOUT_MS = 30 * 60 * 1000;

const _inProgress: Map<string, InProgressUnwind> = new Map();

/// Mark a withdrawal request as in-progress for cross-chain unwind.
export function recordUnwindInitiated(
  requestId: string,
  chain: Chain,
  amountUsdc: bigint,
  atMs: number = Date.now()
): void {
  _inProgress.set(requestId, {
    requestId,
    chain,
    amountUsdc,
    initiatedAtMs: atMs,
    expectedFulfillByMs: atMs + UNWIND_TIMEOUT_MS,
  });
}

/// Returns the in-progress record for a request, if any. Auto-evicts stale
/// records past the timeout window — callers see `undefined` and re-initiate.
export function getInProgressUnwind(
  requestId: string,
  nowMs: number = Date.now()
): InProgressUnwind | undefined {
  const rec = _inProgress.get(requestId);
  if (!rec) return undefined;
  if (nowMs > rec.expectedFulfillByMs) {
    _inProgress.delete(requestId);
    return undefined;
  }
  return rec;
}

/// Called by the fulfiller after a successful vault.fulfillWithdraw, to
/// release the tracking slot.
export function clearUnwind(requestId: string): void {
  _inProgress.delete(requestId);
}

/// Number of in-progress unwinds (for diagnostics / heartbeat reporting).
export function inProgressCount(): number {
  return _inProgress.size;
}

/// Test-only: reset all state.
export function _resetForTests(): void {
  _inProgress.clear();
}
