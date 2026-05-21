// Per-chain recenter cooldown tracker.
//
// The swarm proposes "recenter" actions when the canonical pool's tick drifts
// outside our LP range. Without a cooldown, the strategist could propose
// recenter on every cycle as the canonical tick wobbles around our new range —
// burning gas + bridge fees + LP fees for diminishing benefit.
//
// This module records each successful recenter execution by chain, and lets
// the risk agent veto subsequent recenter proposals that arrive within the
// cooldown window. In-memory only — restarts clear history. Cooldowns are
// short enough (5 min default) that restart-impact is minimal.
//
// Used by:
//   - coordinator.ts — calls `recordRecenter(chain)` after a successful tx
//   - risk.ts — calls `wasRecentRecenter(chain, cooldownSec)` and vetoes when true

import type { Chain } from "./state.js";

/** Wall-clock ms timestamps of last recenter execution per chain. */
const _lastRecenterAt: Partial<Record<Chain, number>> = {};

/** Default cooldown window in seconds. */
export const RECENTER_COOLDOWN_SECONDS = 300; // 5 minutes

export function recordRecenter(chain: Chain, atMs: number = Date.now()): void {
  _lastRecenterAt[chain] = atMs;
}

export function lastRecenterAt(chain: Chain): number | undefined {
  return _lastRecenterAt[chain];
}

export function wasRecentRecenter(
  chain: Chain,
  cooldownSeconds: number = RECENTER_COOLDOWN_SECONDS,
  nowMs: number = Date.now()
): boolean {
  const last = _lastRecenterAt[chain];
  if (last === undefined) return false;
  const ageSeconds = (nowMs - last) / 1000;
  return ageSeconds < cooldownSeconds;
}

/** Test-only: reset all state. */
export function _resetForTests(): void {
  for (const k of Object.keys(_lastRecenterAt) as Chain[]) {
    delete _lastRecenterAt[k];
  }
}
