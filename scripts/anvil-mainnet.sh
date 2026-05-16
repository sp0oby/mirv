#!/usr/bin/env bash
# Spin up an Ethereum mainnet Anvil fork on port 8545.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ALCHEMY_MAINNET_URL:?ALCHEMY_MAINNET_URL not set in .env}"

PORT="${ANVIL_MAINNET_PORT:-8545}"
CHAIN_ID=1

echo "Starting Anvil Ethereum mainnet fork on http://localhost:${PORT} (chain ID ${CHAIN_ID})"

ANVIL_ARGS=(
  --fork-url "${ALCHEMY_MAINNET_URL}"
  --port "${PORT}"
  --chain-id "${CHAIN_ID}"
  --gas-limit 100000000
  --block-time 2
)

if [[ "${1:-}" == "--background" ]]; then
  LOG="/tmp/mirv-anvil-mainnet.log"
  nohup anvil "${ANVIL_ARGS[@]}" > "${LOG}" 2>&1 &
  PID=$!
  echo "Anvil started (PID ${PID}). Logs: ${LOG}"
  echo "${PID}" > /tmp/mirv-anvil-mainnet.pid
else
  exec anvil "${ANVIL_ARGS[@]}"
fi
