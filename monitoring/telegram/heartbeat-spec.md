# mirv — Telegram heartbeat spec

**Status:** spec only; implementation is a Phase 8 deliverable for the agent host.

## Goal

Confirm the agent loop is alive — silence is indistinguishable from "agent host died" without an active heartbeat. Without this, the on-chain hardening can't tell us about an agent that simply stopped reporting.

## Behaviour

- Every Nth cycle (default `HEARTBEAT_INTERVAL_CYCLES = 60` → roughly every 45 minutes at 45s cycles), the agent POSTs to a Telegram bot.
- Message body is one line:
  ```
  mirv heartbeat | cycle=<N> | tvl=$<X> | maxImbalance=<Y>% | lastReport=<ts>
  ```
  Fields are read from the latest LangGraph state on disk (`state.ts`) so we don't pay an RPC roundtrip every heartbeat.
- A "loud" heartbeat fires on EVERY cycle when:
  - `actionNeeded = true` from any MonitorAgent
  - A `dispatchRebalance` was sent in this cycle
  - A `harvest` was called
  - Any of the new R-1/R-3/R-11/R-13 reverts were caught upstream (the agent sees the revert reason)

## Failure handling

- If a heartbeat POST fails, agent retries 3 times with exponential backoff.
- If 3 consecutive heartbeats fail, the agent writes an error to its own log AND
  proceeds with the next cycle. **Do not block the cycle on monitoring infra.**
- A *missing* heartbeat (no message in N+30 minutes from the Telegram side) is
  itself the alert. Add a Tenderly-equivalent "watchdog" job that pages on-call
  if no heartbeat in the expected window.

## Env

```
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
HEARTBEAT_INTERVAL_CYCLES=60
```

The bot token is held only by the agent host. Sharing it with a human is a
heartbeat-system compromise but NOT a protocol compromise (worst case is
silenced or spoofed heartbeats — the on-chain guards continue to enforce).

## Implementation hooks in the existing codebase

- Add a `tools/telegram.ts` helper alongside `tools/redis.ts`.
- Wire into the graph's `recordCycle` node (the existing cycle terminator) so it
  fires at a known, post-state-update point in the LangGraph flow.
- Keep `TELEGRAM_BOT_TOKEN` optional — if unset, the helper short-circuits with
  a log line (same pattern as Redis degradation).
