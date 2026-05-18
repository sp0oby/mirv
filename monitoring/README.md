# mirv — Monitoring

This directory holds **stubs and runnable definitions** for the off-chain alerts and dashboards described in `audits/OPERATIONS.md §7 "Monitoring requirements"`. Without these, the on-chain hardening (R-1 / R-5 / R-7) is just a slower path to the same compromise.

**Status:** stubs intended to be uploaded / imported during mainnet bring-up. Not wired live yet.

## Files

| Path                                          | Purpose                                                                                       |
|-----------------------------------------------|-----------------------------------------------------------------------------------------------|
| `tenderly/alerts.yml`                         | YAML-style spec for every alert rule. Translate into Tenderly's web-UI config or API at setup. |
| `tenderly/abi.json`                           | Event signatures used by the alert filters (extracted from the audit-tag artifacts).          |
| `dune/01_total_mirrored_tvl.sql`              | Top-line: deposits − withdrawals + cross-chain reports, on Base only.                         |
| `dune/02_weekly_extra_apy.sql`                | Performance signal: extra yield vs baseline, weekly granularity.                              |
| `dune/03_rebalance_events.sql`                | Operations signal: every `RebalanceDispatched` from `MirrorHook` + outcome.                   |
| `dune/04_treasury_fee_share_flow.sql`         | Performance-fee tracking: shares minted to treasury at each harvest.                          |
| `dune/05_pause_state_changes.sql`             | Incident-response tracking: every Paused/Unpaused event with who triggered it.                |
| `telegram/heartbeat-spec.md`                  | Spec for the agent → Telegram heartbeat job (Phase 8 implementation).                          |

## Conventions

- **Addresses left as placeholders** (`{{ MIRROR_HOOK_BASE }}`, etc.) — populated from `.env` at the time we wire these to real Tenderly / Dune workspaces. Don't commit real mainnet addresses here until the deploy is finalized.
- **Chains:** Base + ETH Sepolia for now (mirroring the v5 testnet); add mainnet entries when Phase 9 deploys land.
- **Alert thresholds:** taken straight from OPERATIONS.md §7 — change them THERE first, then sync here.
- **Dune queries:** assume the `ethereum.logs` and `base.logs` schemas. Translate to the right namespace if Dune renames things again.

## What this is NOT

- Not an auto-deploy script. We're not ready to point this at production Tenderly / Dune accounts.
- Not exhaustive — see OPERATIONS.md §7 for the full alert list; some (like Hook ETH balance < 0.01) are RPC poll jobs, not on-chain event filters, and live elsewhere.
