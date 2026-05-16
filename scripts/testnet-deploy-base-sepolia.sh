#!/usr/bin/env bash
# Deploy mirv contracts to Base Sepolia testnet.
#
# Prerequisites:
#   - ALCHEMY_BASE_SEPOLIA_URL set in .env
#   - DEPLOYER_PRIVATE_KEY set + wallet funded with Base Sepolia ETH
#     (faucet: https://www.alchemy.com/faucets/base-sepolia)
#   - POOL_MANAGER_BASE_SEPOLIA + HYPERLANE_MAILBOX_BASE_SEPOLIA + PYTH_ADDRESS_BASE_SEPOLIA
#     + CHAINLINK_ETH_USD_BASE_SEPOLIA set in .env
#
# Base Sepolia V4 PoolManager (verified):
#   PoolManager:     0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408
#   Universal Router: 0x492E6456D9528771018DeB9E87ef7750EF184104
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ALCHEMY_BASE_SEPOLIA_URL:?ALCHEMY_BASE_SEPOLIA_URL not set in .env}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set in .env}"

RPC="${ALCHEMY_BASE_SEPOLIA_URL}"

# Normalize private key
PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")

echo "→ Base Sepolia testnet deploy"
echo "  Deployer: ${DEPLOYER}"
echo "  RPC:      (Base Sepolia via Alchemy)"
echo ""

# ── Pre-flight: check balance ────────────────────────────────────────────────
BALANCE=$(cast balance --rpc-url "${RPC}" "${DEPLOYER}")
echo "  Deployer balance: ${BALANCE} wei"
if [[ "${BALANCE}" == "0" ]]; then
  echo ""
  echo "✗ Deployer has 0 Base Sepolia ETH."
  echo "  Get testnet ETH from: https://www.alchemy.com/faucets/base-sepolia"
  echo "  Deployer address: ${DEPLOYER}"
  exit 1
fi

# Override placeholder values
EFFECTIVE_TREASURY="${TREASURY_SAFE:-${DEPLOYER}}"
[[ "${EFFECTIVE_TREASURY}" == "0x..."* || ${#EFFECTIVE_TREASURY} -ne 42 ]] && EFFECTIVE_TREASURY="${DEPLOYER}"
EFFECTIVE_AGENT="${AGENT_WALLET:-${DEPLOYER}}"
[[ "${EFFECTIVE_AGENT}" == "0x..."* || ${#EFFECTIVE_AGENT} -ne 42 ]] && EFFECTIVE_AGENT="${DEPLOYER}"

PYTH_ETH_USD="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

# ── Mine hook salt ────────────────────────────────────────────────────────────
cd packages/contracts
echo "→ Mining hook salt..."
SALT=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  "${POOL_MANAGER_BASE_SEPOLIA:-0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408}" \
  "${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
  "${PYTH_ADDRESS_BASE_SEPOLIA}" \
  "${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
  "${PYTH_ETH_USD}" \
  --rpc-url "${RPC}" 2>&1 | grep "Salt (decimal):" | awk '{print $NF}')

if [[ -z "${SALT}" ]]; then
  echo "✗ Hook mining failed"
  exit 1
fi
echo "  Salt: ${SALT}"

# ── Deploy ───────────────────────────────────────────────────────────────────
echo "→ Deploying to Base Sepolia (this will cost real testnet ETH)..."
HOOK_SALT_BASE="${SALT}" \
TREASURY_SAFE="${EFFECTIVE_TREASURY}" \
AGENT_WALLET="${EFFECTIVE_AGENT}" \
POOL_MANAGER_BASE="${POOL_MANAGER_BASE_SEPOLIA:-0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408}" \
HYPERLANE_MAILBOX_BASE="${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
PYTH_ADDRESS_BASE="${PYTH_ADDRESS_BASE_SEPOLIA}" \
CHAINLINK_ETH_USD_BASE="${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url "${RPC}" \
  --broadcast \
  --verify --etherscan-api-key "${BASESCAN_API_KEY}" \
  -vv 2>&1 | tail -30
