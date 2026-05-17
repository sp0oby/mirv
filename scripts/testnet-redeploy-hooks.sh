#!/usr/bin/env bash
# Re-deploy only MirrorHook (+ Factory on Base) on Base Sepolia + Ethereum Sepolia
# when the hook bytecode changes. Preserves the existing Treasury, Vault, and
# Relayer contracts.
#
# Flow:
#   1. Mine fresh hook salts on both chains
#   2. Deploy new MirrorHook + MirrorFactory on Base Sepolia
#   3. Deploy new MirrorHook on ETH Sepolia
#   4. Verify on block explorers
#   5. Update .env with new addresses
#   6. Re-wire sister domains for the new hooks
#   7. Re-fund new hooks
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

: "${ALCHEMY_BASE_SEPOLIA_URL:?ALCHEMY_BASE_SEPOLIA_URL not set}"
: "${ALCHEMY_ETH_SEPOLIA_URL:?ALCHEMY_ETH_SEPOLIA_URL not set}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"
: "${TREASURY_BASE:?TREASURY_BASE not set (deploy fresh chain first via testnet-deploy-base-sepolia.sh)}"

PYTH_ETH_USD="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")

echo "→ Hook redeploy (Base Sepolia + ETH Sepolia)"
echo "  Deployer: ${DEPLOYER}"
echo ""

cd packages/contracts

# ── Mine new salts ────────────────────────────────────────────────────────────
echo "→ Mining new hook salt for Base Sepolia..."
SALT_BASE=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  "${POOL_MANAGER_BASE_SEPOLIA}" \
  "${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
  "${PYTH_ADDRESS_BASE_SEPOLIA}" \
  "${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
  "${PYTH_ETH_USD}" \
  --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" 2>&1 | grep "Salt (decimal):" | awk '{print $NF}')
echo "  Base salt: ${SALT_BASE}"

echo "→ Mining new hook salt for ETH Sepolia..."
SALT_ETH=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  "${POOL_MANAGER_ETH_SEPOLIA}" \
  "${HYPERLANE_MAILBOX_ETH_SEPOLIA}" \
  "${PYTH_ADDRESS_ETH_SEPOLIA}" \
  "${CHAINLINK_ETH_USD_ETH_SEPOLIA}" \
  "${PYTH_ETH_USD}" \
  --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" 2>&1 | grep "Salt (decimal):" | awk '{print $NF}')
echo "  ETH salt:  ${SALT_ETH}"
echo ""

[[ -z "${SALT_BASE}" || -z "${SALT_ETH}" ]] && { echo "✗ Salt mining failed"; exit 1; }

# ── Redeploy on Base Sepolia ──────────────────────────────────────────────────
echo "→ Redeploying Hook + Factory on Base Sepolia..."
VERIFY_BASE=""
[[ -n "${BASESCAN_API_KEY:-}" ]] && VERIFY_BASE="--verify --etherscan-api-key ${BASESCAN_API_KEY}"

HOOK_SALT_BASE="${SALT_BASE}" \
TREASURY_BASE="${TREASURY_BASE}" \
AGENT_WALLET="${AGENT_WALLET}" \
POOL_MANAGER_BASE="${POOL_MANAGER_BASE_SEPOLIA}" \
HYPERLANE_MAILBOX_BASE="${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
PYTH_ADDRESS_BASE="${PYTH_ADDRESS_BASE_SEPOLIA}" \
CHAINLINK_ETH_USD_BASE="${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
forge script script/Deploy.s.sol:RedeployHookBase \
  --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" \
  --broadcast \
  ${VERIFY_BASE} \
  -vv 2>&1 | tail -25

echo ""

# ── Redeploy on ETH Sepolia ──────────────────────────────────────────────────
echo "→ Redeploying Hook on ETH Sepolia (with --slow for EIP-7702 delegated EOA)..."
VERIFY_ETH=""
[[ -n "${ETHERSCAN_API_KEY:-}" ]] && VERIFY_ETH="--verify --etherscan-api-key ${ETHERSCAN_API_KEY}"

HOOK_SALT_MAINNET="${SALT_ETH}" \
AGENT_WALLET="${AGENT_WALLET}" \
POOL_MANAGER_MAINNET="${POOL_MANAGER_ETH_SEPOLIA}" \
HYPERLANE_MAILBOX_MAINNET="${HYPERLANE_MAILBOX_ETH_SEPOLIA}" \
PYTH_ADDRESS_MAINNET="${PYTH_ADDRESS_ETH_SEPOLIA}" \
CHAINLINK_ETH_USD_MAINNET="${CHAINLINK_ETH_USD_ETH_SEPOLIA}" \
forge script script/Deploy.s.sol:RedeployHookEthereum \
  --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" \
  --broadcast \
  --slow \
  ${VERIFY_ETH} \
  -vv 2>&1 | tail -25

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Hook redeploy complete on both chains"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo " Next:"
echo "   1. Update .env (the script below will help):"
echo "      ./scripts/testnet-sync-env-after-redeploy.sh"
echo "   2. Re-wire sisters: ./scripts/testnet-wire-sisters.sh"
echo "   3. Re-fund: cast send \$MIRROR_HOOK_BASE --value 0.01ether ..."
