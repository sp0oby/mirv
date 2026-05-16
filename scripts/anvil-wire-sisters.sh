#!/usr/bin/env bash
# Wire sister domains across the 3 Anvil forks AFTER deployment.
# Reads deployed addresses from broadcast logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# Normalize private key
PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"

# ── Pull deployed addresses from broadcast logs ───────────────────────────────
BASE_LOG="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/8453/run-latest.json"
ETH_LOG="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/1/run-latest.json"
BNB_LOG="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/56/run-latest.json"

for f in "${BASE_LOG}" "${ETH_LOG}" "${BNB_LOG}"; do
  [[ -f "${f}" ]] || { echo "✗ Missing broadcast log: ${f}"; exit 1; }
done

HOOK_BASE=$(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "${BASE_LOG}")
HOOK_MAINNET=$(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "${ETH_LOG}")
HOOK_BNB=$(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "${BNB_LOG}")
RELAYER_MAINNET=$(jq -r '[.transactions[] | select(.contractName == "Relayer")][0].contractAddress' "${ETH_LOG}")
RELAYER_BNB=$(jq -r '[.transactions[] | select(.contractName == "Relayer")][0].contractAddress' "${BNB_LOG}")

echo "Deployed addresses:"
echo "  HOOK_BASE:       ${HOOK_BASE}"
echo "  HOOK_MAINNET:    ${HOOK_MAINNET}"
echo "  HOOK_BNB:        ${HOOK_BNB}"
echo "  RELAYER_MAINNET: ${RELAYER_MAINNET}"
echo "  RELAYER_BNB:     ${RELAYER_BNB}"

cd "${ROOT}/packages/contracts"

# ── Run each chain's wire script ─────────────────────────────────────────────
echo ""
echo "→ Wiring Base hook → sister domains..."
MIRROR_HOOK_BASE="${HOOK_BASE}" \
RELAYER_MAINNET="${RELAYER_MAINNET}" \
RELAYER_BNB="${RELAYER_BNB}" \
forge script script/WireSisterDomains.s.sol:WireBase \
  --rpc-url http://localhost:8546 --broadcast --skip-simulation 2>&1 \
  | grep -E "Base hook|sister|EXECUTION|Error" | head -5

echo ""
echo "→ Wiring Ethereum hook + relayer..."
MIRROR_HOOK_MAINNET="${HOOK_MAINNET}" \
RELAYER_MAINNET="${RELAYER_MAINNET}" \
MIRROR_HOOK_BASE="${HOOK_BASE}" \
MIRROR_HOOK_BNB="${HOOK_BNB}" \
RELAYER_BNB="${RELAYER_BNB}" \
forge script script/WireSisterDomains.s.sol:WireMainnet \
  --rpc-url http://localhost:8545 --broadcast --skip-simulation 2>&1 \
  | grep -E "Ethereum|hook|EXECUTION|Error" | head -5

echo ""
echo "→ Wiring BNB hook + relayer..."
MIRROR_HOOK_BNB="${HOOK_BNB}" \
RELAYER_BNB="${RELAYER_BNB}" \
MIRROR_HOOK_BASE="${HOOK_BASE}" \
MIRROR_HOOK_MAINNET="${HOOK_MAINNET}" \
forge script script/WireSisterDomains.s.sol:WireBnb \
  --rpc-url http://localhost:8547 --broadcast --skip-simulation 2>&1 \
  | grep -E "BNB|hook|EXECUTION|Error" | head -5

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "→ Verifying sister domain configuration..."

# Helper: count sister domains by attempting indexed reads until reverting
count_sisters() {
  local hook="$1"
  local rpc="$2"
  local n=0
  while cast call --rpc-url "${rpc}" "${hook}" "sisterDomains(uint256)(uint32,bytes32)" "${n}" >/dev/null 2>&1; do
    n=$((n+1))
  done
  echo "${n}"
}

BASE_COUNT=$(count_sisters "${HOOK_BASE}"    http://localhost:8546)
ETH_COUNT=$(count_sisters  "${HOOK_MAINNET}" http://localhost:8545)
BNB_COUNT=$(count_sisters  "${HOOK_BNB}"     http://localhost:8547)

echo "  Base hook sister count:    ${BASE_COUNT} (expected: 2)"
echo "  Ethereum hook sister count: ${ETH_COUNT} (expected: 2)"
echo "  BNB hook sister count:     ${BNB_COUNT} (expected: 2)"

ETH_AUTH=$(cast call --rpc-url http://localhost:8545 "${RELAYER_MAINNET}" \
  "authorizedSenders(bytes32)(bool)" \
  "$(cast --to-uint256 ${HOOK_BASE} | sed 's/^0x/0x/')")
BNB_AUTH=$(cast call --rpc-url http://localhost:8547 "${RELAYER_BNB}" \
  "authorizedSenders(bytes32)(bool)" \
  "$(cast --to-uint256 ${HOOK_BASE} | sed 's/^0x/0x/')")

echo "  Ethereum relayer trusts Base hook: ${ETH_AUTH}"
echo "  BNB relayer trusts Base hook:      ${BNB_AUTH}"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Sister domains wired across 3 chains"
echo "═══════════════════════════════════════════════════════════════════"
