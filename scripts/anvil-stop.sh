#!/usr/bin/env bash
# Stop all background Anvil forks started by this project.
set -euo pipefail

for chain in mainnet base bnb; do
  PID_FILE="/tmp/mirv-anvil-${chain}.pid"
  if [[ -f "${PID_FILE}" ]]; then
    PID=$(cat "${PID_FILE}")
    if kill "${PID}" 2>/dev/null; then
      echo "Stopped ${chain} (PID ${PID})"
    else
      echo "Could not stop ${chain} (PID ${PID} — may have exited already)"
    fi
    rm "${PID_FILE}"
  fi
done
