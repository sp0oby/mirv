#!/usr/bin/env bash
# Spin up all 3 Anvil forks in parallel (Ethereum mainnet + Base + BNB Chain).
#
# Ports:
#   - Ethereum: 8545
#   - Base:     8546
#   - BNB:      8547
#
# Stop all with: ./scripts/anvil-stop.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

echo "Starting all 3 Anvil forks in background..."

"${ROOT}/scripts/anvil-mainnet.sh" --background
"${ROOT}/scripts/anvil-base.sh"    --background
"${ROOT}/scripts/anvil-bnb.sh"     --background

sleep 4

echo ""
echo "Status:"
for chain in mainnet base bnb; do
  case $chain in
    mainnet) port=8545 ;;
    base)    port=8546 ;;
    bnb)     port=8547 ;;
  esac
  if cast block-number --rpc-url "http://localhost:${port}" >/dev/null 2>&1; then
    BLOCK=$(cast block-number --rpc-url "http://localhost:${port}")
    CHAIN_ID=$(cast chain-id --rpc-url "http://localhost:${port}")
    PID=$(cat "/tmp/mirv-anvil-${chain}.pid" 2>/dev/null)
    echo "  ✓ ${chain}: http://localhost:${port} (block ${BLOCK}, chain ${CHAIN_ID}, PID ${PID})"
  else
    echo "  ✗ ${chain}: not responding on port ${port} — check /tmp/mirv-anvil-${chain}.log"
  fi
done

echo ""
echo "Stop all: ./scripts/anvil-stop.sh"
