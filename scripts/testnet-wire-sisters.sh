#!/usr/bin/env bash
# Wire sister domains between Base Sepolia and Ethereum Sepolia AFTER both are deployed.
# Reads deployed addresses from broadcast logs (per-chain run-latest.json).
#
# Note: BNB testnet has no V4, so this is a 2-chain demo at testnet stage.
# At mainnet (Phase 9) we'll wire all 3 chains.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

: "${ALCHEMY_BASE_SEPOLIA_URL:?ALCHEMY_BASE_SEPOLIA_URL not set}"
: "${ALCHEMY_ETH_SEPOLIA_URL:?ALCHEMY_ETH_SEPOLIA_URL not set}"

PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"

# Base Sepolia is chain 84532; ETH Sepolia is 11155111
BASE_LOG="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/84532/run-latest.json"
ETH_LOG="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/11155111/run-latest.json"

for f in "${BASE_LOG}" "${ETH_LOG}"; do
  [[ -f "${f}" ]] || { echo "✗ Missing broadcast log: ${f}"; echo "  Run testnet-deploy-*-sepolia.sh first"; exit 1; }
done

HOOK_BASE=$(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "${BASE_LOG}")
HOOK_ETH=$(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "${ETH_LOG}")
RELAYER_ETH=$(jq -r '[.transactions[] | select(.contractName == "Relayer")][0].contractAddress' "${ETH_LOG}")

# After a redeploy that touches only MirrorHook, broadcast logs won't contain
# Relayer — fall back to .env. Same for Hook addresses if log somehow missed them.
[[ "${HOOK_BASE}" == "null" || -z "${HOOK_BASE}" ]] && HOOK_BASE="${MIRROR_HOOK_BASE:-}"
[[ "${HOOK_ETH}"  == "null" || -z "${HOOK_ETH}"  ]] && HOOK_ETH="${MIRROR_HOOK_MAINNET:-}"
[[ "${RELAYER_ETH}" == "null" || -z "${RELAYER_ETH}" ]] && RELAYER_ETH="${RELAYER_MAINNET:-}"

for v in HOOK_BASE HOOK_ETH RELAYER_ETH; do
  [[ -z "${!v}" ]] && { echo "✗ ${v} not set in broadcast log or .env"; exit 1; }
done

echo "Testnet deployment:"
echo "  HOOK_BASE (Base Sepolia):     ${HOOK_BASE}"
echo "  HOOK_ETH  (ETH Sepolia):      ${HOOK_ETH}"
echo "  RELAYER_ETH (ETH Sepolia):    ${RELAYER_ETH}"
echo ""

cd "${ROOT}/packages/contracts"

# Hyperlane testnet domain IDs match chain IDs:
#   Base Sepolia    = 84532
#   Ethereum Sepolia = 11155111
# (BNB is skipped at testnet — no V4 there.) WireSisterDomains.s.sol reads these
# from env with mainnet defaults, so we override here.

# ── Wire Base hook → Ethereum sister ──────────────────────────────────────────
echo "→ Wiring Base Sepolia hook to know about Ethereum Sepolia relayer..."
MIRROR_HOOK_BASE="${HOOK_BASE}" \
RELAYER_MAINNET="${RELAYER_ETH}" \
DOMAIN_ETHEREUM=11155111 \
DOMAIN_BASE=84532 \
forge script script/WireSisterDomains.s.sol:WireBase \
  --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --broadcast 2>&1 \
  | grep -E "Base hook|sister|Skipping|EXECUTION|Error" | head -5

echo ""
echo "→ Wiring Ethereum Sepolia hook + relayer (sister = Base, BNB skipped)..."
MIRROR_HOOK_MAINNET="${HOOK_ETH}" \
RELAYER_MAINNET="${RELAYER_ETH}" \
MIRROR_HOOK_BASE="${HOOK_BASE}" \
DOMAIN_ETHEREUM=11155111 \
DOMAIN_BASE=84532 \
forge script script/WireSisterDomains.s.sol:WireMainnet \
  --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" --broadcast --slow 2>&1 \
  | grep -E "Ethereum|hook|Skipping|EXECUTION|Error" | head -5

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Sister domains wired across Base Sepolia + Ethereum Sepolia"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo " Next:"
echo "   1. Fund each hook with ~0.01 testnet ETH for Hyperlane dispatch:"
echo "      cast send ${HOOK_BASE} --value 0.01ether --rpc-url \$ALCHEMY_BASE_SEPOLIA_URL --private-key \$DEPLOYER_PRIVATE_KEY"
echo "      cast send ${HOOK_ETH}  --value 0.01ether --rpc-url \$ALCHEMY_ETH_SEPOLIA_URL --private-key \$DEPLOYER_PRIVATE_KEY"
echo ""
echo "   2. Run the agents pointing at testnet RPCs:"
echo "      cd packages/agents"
echo "      NETWORK=sepolia \\"
echo "      ALCHEMY_MAINNET_URL=\$ALCHEMY_ETH_SEPOLIA_URL \\"
echo "      ALCHEMY_BASE_URL=\$ALCHEMY_BASE_SEPOLIA_URL \\"
echo "      MIRROR_HOOK_BASE=${HOOK_BASE} \\"
echo "      MIRROR_HOOK_MAINNET=${HOOK_ETH} \\"
echo "      ./node_modules/.bin/tsx src/index.ts"
