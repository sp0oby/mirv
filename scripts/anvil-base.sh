#!/usr/bin/env bash
# Spin up a Base mainnet Anvil fork on port 8546.
# All Base-chain mainnet contracts (V4 PoolManager, Hyperlane Mailbox, USDC, etc.) are reachable.
# State is in-memory — restarts wipe deployments.
#
# Usage:
#   ./scripts/anvil-base.sh                     # foreground (Ctrl-C to stop)
#   ./scripts/anvil-base.sh --background        # fork-and-detach, returns PID
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Load env
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ALCHEMY_BASE_URL:?ALCHEMY_BASE_URL not set in .env}"

PORT="${ANVIL_BASE_PORT:-8546}"
CHAIN_ID=8453

echo "Starting Anvil with Base fork on http://localhost:${PORT} (chain ID ${CHAIN_ID})"
echo "Fork from: \${ALCHEMY_BASE_URL}"
echo ""

ANVIL_ARGS=(
  --fork-url "${ALCHEMY_BASE_URL}"
  --port "${PORT}"
  --chain-id "${CHAIN_ID}"
  --gas-limit 100000000
  --block-time 2
)

if [[ "${1:-}" == "--background" ]]; then
  LOG="/tmp/mirv-anvil-base.log"
  nohup anvil "${ANVIL_ARGS[@]}" > "${LOG}" 2>&1 &
  PID=$!
  echo "Anvil started in background (PID ${PID}). Logs: ${LOG}"
  echo "Stop with: kill ${PID}"
  echo "${PID}" > /tmp/mirv-anvil-base.pid
else
  exec anvil "${ANVIL_ARGS[@]}"
fi
