#!/usr/bin/env bash
# Mock Hyperlane relay daemon: watches Dispatch events on each Anvil fork's
# MockHyperlaneMailbox and forwards messages to the destination chain's mailbox
# via .deliver() — simulating Hyperlane's permissionless relay layer.
#
# Reads mailbox addresses from /tmp/mirv-mock-mailboxes (written by anvil-deploy-cross-chain.sh).
#
# Portable bash 3.2 compatible (no associative arrays).
#
# Usage:
#   ./scripts/mock-hyperlane-relay.sh                  # foreground (Ctrl-C to stop)
#   ./scripts/mock-hyperlane-relay.sh --background     # daemon mode
#   ./scripts/mock-hyperlane-relay.sh --once           # one-shot (catch up + exit)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"

ADDR_FILE="/tmp/mirv-mock-mailboxes"
if [[ ! -f "${ADDR_FILE}" ]]; then
  echo "✗ ${ADDR_FILE} not found — run scripts/anvil-deploy-cross-chain.sh first"
  exit 1
fi
# shellcheck disable=SC1090
source "${ADDR_FILE}"

DISPATCH_SIG=$(cast sig-event "Dispatch(uint256,uint32,bytes32,bytes32,bytes)")

# Helpers — function-based lookups (bash 3.2 has no associative arrays)
rpc_for() {
  case "$1" in
    1)    echo "http://localhost:8545" ;;
    8453) echo "http://localhost:8546" ;;
    56)   echo "http://localhost:8547" ;;
    *)    echo "" ;;
  esac
}
mailbox_for() {
  case "$1" in
    1)    echo "${MAILBOX_MAINNET}" ;;
    8453) echo "${MAILBOX_BASE}" ;;
    56)   echo "${MAILBOX_BNB}" ;;
    *)    echo "" ;;
  esac
}

# Track last processed block per domain via files.
# --once mode replays from block 0 to catch historical events.
LAST_DIR=$(mktemp -d)
if [[ "${1:-}" == "--once" ]]; then
  for domain in 1 8453 56; do echo "0" > "${LAST_DIR}/${domain}"; done
else
  for domain in 1 8453 56; do
    block=$(cast block-number --rpc-url "$(rpc_for ${domain})")
    echo "${block}" > "${LAST_DIR}/${domain}"
  done
fi

scan_and_relay() {
  for src_domain in 1 8453 56; do
    src_rpc=$(rpc_for "${src_domain}")
    src_mb=$(mailbox_for "${src_domain}")
    from=$(cat "${LAST_DIR}/${src_domain}")
    to=$(cast block-number --rpc-url "${src_rpc}")
    if [[ "${to}" -le "${from}" ]]; then continue; fi

    logs=$(cast logs --rpc-url "${src_rpc}" --address "${src_mb}" \
      "${DISPATCH_SIG}" --from-block "$((from + 1))" --to-block "${to}" --json 2>/dev/null || echo "[]")
    count=$(echo "${logs}" | jq 'length' 2>/dev/null)
    [[ -z "${count}" || "${count}" == "0" ]] && { echo "${to}" > "${LAST_DIR}/${src_domain}"; continue; }

    echo "[domain ${src_domain}] ${count} new Dispatch event(s) in blocks $((from+1))..${to}"

    for i in $(seq 0 $((count - 1))); do
      # Event layout:
      #   topics[0] = Dispatch signature
      #   topics[1] = messageIndex (indexed uint256)
      #   topics[2] = recipient    (indexed bytes32)
      #   topics[3] = sender       (indexed bytes32)
      #   data      = abi.encode(uint32 destinationDomain, bytes message)
      recipient=$(echo "${logs}" | jq -r ".[${i}].topics[2]")
      sender=$(echo "${logs}" | jq -r ".[${i}].topics[3]")
      data=$(echo "${logs}" | jq -r ".[${i}].data")

      # data layout (after 0x):
      #   [0:64]    destinationDomain (uint32 padded to 32 bytes)
      #   [64:128]  offset to bytes (always 0x40 = 64)
      #   [128:192] length of bytes
      #   [192:...] bytes data (padded to 32-byte multiple)
      dst_hex="${data:2:64}"
      dst_domain=$(cast --to-dec "0x${dst_hex}")
      msg_len_hex="${data:130:64}"
      msg_len=$(cast --to-dec "0x${msg_len_hex}")
      msg_hex="0x${data:194:$((msg_len * 2))}"

      dst_rpc=$(rpc_for "${dst_domain}")
      dst_mb=$(mailbox_for "${dst_domain}")
      if [[ -z "${dst_rpc}" || -z "${dst_mb}" ]]; then
        echo "  → unknown destination domain ${dst_domain}, skipping"
        continue
      fi

      echo "  → relaying domain ${src_domain} → ${dst_domain} (msg ${msg_len} bytes)"
      if cast send "${dst_mb}" \
        "deliver(uint32,bytes32,bytes32,bytes)" \
        "${src_domain}" "${sender}" "${recipient}" "${msg_hex}" \
        --private-key "${PK}" --rpc-url "${dst_rpc}" >/dev/null 2>&1; then
        echo "  ✓ delivered"
      else
        # Try once more with verbose error
        ERR=$(cast send "${dst_mb}" \
          "deliver(uint32,bytes32,bytes32,bytes)" \
          "${src_domain}" "${sender}" "${recipient}" "${msg_hex}" \
          --private-key "${PK}" --rpc-url "${dst_rpc}" 2>&1 || true)
        echo "  ✗ delivery failed: $(echo "${ERR}" | tail -2 | head -1)"
      fi
    done
    echo "${to}" > "${LAST_DIR}/${src_domain}"
  done
}

if [[ "${1:-}" == "--once" ]]; then
  scan_and_relay
  exit 0
fi

run_loop() {
  echo "→ Mock Hyperlane relay running. Watching 3 forks every 2s..."
  while true; do
    scan_and_relay
    sleep 2
  done
}

if [[ "${1:-}" == "--background" ]]; then
  LOG="/tmp/mirv-mock-relay.log"
  nohup bash "$0" > "${LOG}" 2>&1 &
  echo "Relay running in background (PID $!). Logs: ${LOG}"
  echo "$!" > /tmp/mirv-mock-relay.pid
else
  run_loop
fi
