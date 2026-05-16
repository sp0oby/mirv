#!/usr/bin/env bash
# Spin up a BNB Chain Anvil fork on port 8547.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ALCHEMY_BNB_URL:?ALCHEMY_BNB_URL not set in .env}"

PORT="${ANVIL_BNB_PORT:-8547}"
CHAIN_ID=56

echo "Starting Anvil BNB Chain fork on http://localhost:${PORT} (chain ID ${CHAIN_ID})"

ANVIL_ARGS=(
  --fork-url "${ALCHEMY_BNB_URL}"
  --port "${PORT}"
  --chain-id "${CHAIN_ID}"
  --gas-limit 100000000
  --block-time 2
)

if [[ "${1:-}" == "--background" ]]; then
  LOG="/tmp/mirv-anvil-bnb.log"
  nohup anvil "${ANVIL_ARGS[@]}" > "${LOG}" 2>&1 &
  PID=$!
  echo "Anvil started (PID ${PID}). Logs: ${LOG}"
  echo "${PID}" > /tmp/mirv-anvil-bnb.pid
else
  exec anvil "${ANVIL_ARGS[@]}"
fi
