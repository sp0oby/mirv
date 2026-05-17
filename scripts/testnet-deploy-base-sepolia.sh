#!/usr/bin/env bash
# Deploy mirv contracts to Base Sepolia testnet.
#
# Prerequisites:
#   - ALCHEMY_BASE_SEPOLIA_URL set in .env
#   - DEPLOYER_PRIVATE_KEY set + wallet funded with Base Sepolia ETH
#     (faucet: https://www.alchemy.com/faucets/base-sepolia)
#   - BASESCAN_API_KEY set in .env (for contract verification)
#
# Reads all chain-specific addresses from .env (testnet variants):
#   POOL_MANAGER_BASE_SEPOLIA, HYPERLANE_MAILBOX_BASE_SEPOLIA, PYTH_ADDRESS_BASE_SEPOLIA,
#   CHAINLINK_ETH_USD_BASE_SEPOLIA, USDC_BASE_SEPOLIA
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

: "${ALCHEMY_BASE_SEPOLIA_URL:?ALCHEMY_BASE_SEPOLIA_URL not set in .env}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set in .env}"
: "${POOL_MANAGER_BASE_SEPOLIA:?POOL_MANAGER_BASE_SEPOLIA not set}"
: "${HYPERLANE_MAILBOX_BASE_SEPOLIA:?HYPERLANE_MAILBOX_BASE_SEPOLIA not set}"
: "${PYTH_ADDRESS_BASE_SEPOLIA:?PYTH_ADDRESS_BASE_SEPOLIA not set}"
: "${CHAINLINK_ETH_USD_BASE_SEPOLIA:?CHAINLINK_ETH_USD_BASE_SEPOLIA not set}"
: "${USDC_BASE_SEPOLIA:?USDC_BASE_SEPOLIA not set}"

RPC="${ALCHEMY_BASE_SEPOLIA_URL}"
PYTH_ETH_USD="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")

echo "→ Base Sepolia deploy"
echo "  Deployer: ${DEPLOYER}"
echo "  V4:       ${POOL_MANAGER_BASE_SEPOLIA}"
echo "  USDC:     ${USDC_BASE_SEPOLIA}"
echo ""

# Pre-flight: check balance (need ~0.05 ETH for deploys)
BALANCE_WEI=$(cast balance --rpc-url "${RPC}" "${DEPLOYER}")
BALANCE_ETH=$(cast to-unit "${BALANCE_WEI}" ether)
echo "  Balance: ${BALANCE_ETH} ETH"
if [[ "${BALANCE_WEI}" == "0" ]]; then
  echo ""
  echo "✗ Deployer has 0 Base Sepolia ETH."
  echo "  Faucet: https://www.alchemy.com/faucets/base-sepolia"
  echo "  Address: ${DEPLOYER}"
  exit 1
fi

# Sensible defaults for placeholders
EFFECTIVE_TREASURY="${TREASURY_SAFE:-${DEPLOYER}}"
[[ "${EFFECTIVE_TREASURY}" == "0x..."* || ${#EFFECTIVE_TREASURY} -ne 42 ]] && EFFECTIVE_TREASURY="${DEPLOYER}"
EFFECTIVE_AGENT="${AGENT_WALLET:-${DEPLOYER}}"
[[ "${EFFECTIVE_AGENT}" == "0x..."* || ${#EFFECTIVE_AGENT} -ne 42 ]] && EFFECTIVE_AGENT="${DEPLOYER}"

# ── Mine hook salt ────────────────────────────────────────────────────────────
cd packages/contracts
echo "→ Mining hook CREATE2 salt for Base Sepolia..."
SALT=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  "${POOL_MANAGER_BASE_SEPOLIA}" \
  "${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
  "${PYTH_ADDRESS_BASE_SEPOLIA}" \
  "${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
  "${PYTH_ETH_USD}" \
  --rpc-url "${RPC}" 2>&1 | grep "Salt (decimal):" | awk '{print $NF}')

if [[ -z "${SALT}" ]]; then
  echo "✗ Hook mining failed — re-run with --tc MineHookAddress -vvv for trace"
  exit 1
fi
echo "  Salt: ${SALT}"
echo ""

# ── Deploy (real testnet tx — costs Base Sepolia ETH) ─────────────────────────
echo "→ Deploying contracts to Base Sepolia..."
VERIFY_FLAGS=""
if [[ -n "${BASESCAN_API_KEY:-}" ]]; then
  VERIFY_FLAGS="--verify --etherscan-api-key ${BASESCAN_API_KEY}"
fi

HOOK_SALT_BASE="${SALT}" \
TREASURY_SAFE="${EFFECTIVE_TREASURY}" \
AGENT_WALLET="${EFFECTIVE_AGENT}" \
POOL_MANAGER_BASE="${POOL_MANAGER_BASE_SEPOLIA}" \
HYPERLANE_MAILBOX_BASE="${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
PYTH_ADDRESS_BASE="${PYTH_ADDRESS_BASE_SEPOLIA}" \
CHAINLINK_ETH_USD_BASE="${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
VAULT_ASSET_BASE="${USDC_BASE_SEPOLIA}" \
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url "${RPC}" \
  --broadcast \
  ${VERIFY_FLAGS} \
  -vv 2>&1 | tail -30

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Base Sepolia deploy complete"
echo "═══════════════════════════════════════════════════════════════════"
echo " View on BaseScan: https://sepolia.basescan.org/address/${DEPLOYER}"
echo " Next: ./scripts/testnet-deploy-eth-sepolia.sh"
