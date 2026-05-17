#!/usr/bin/env bash
# Deploy mirv contracts (MirrorHook + Relayer) to Ethereum Sepolia testnet.
#
# Prerequisites:
#   - ALCHEMY_ETH_SEPOLIA_URL set in .env
#   - DEPLOYER_PRIVATE_KEY set + wallet funded with Sepolia ETH
#     (faucet: https://www.alchemy.com/faucets/ethereum-sepolia)
#   - ETHERSCAN_API_KEY set in .env (verification)
#
# Run AFTER testnet-deploy-base-sepolia.sh (need Base deployed first for sister-domain wiring).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

: "${ALCHEMY_ETH_SEPOLIA_URL:?ALCHEMY_ETH_SEPOLIA_URL not set in .env}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set in .env}"
: "${POOL_MANAGER_ETH_SEPOLIA:?POOL_MANAGER_ETH_SEPOLIA not set}"
: "${HYPERLANE_MAILBOX_ETH_SEPOLIA:?HYPERLANE_MAILBOX_ETH_SEPOLIA not set}"
: "${PYTH_ADDRESS_ETH_SEPOLIA:?PYTH_ADDRESS_ETH_SEPOLIA not set}"
: "${CHAINLINK_ETH_USD_ETH_SEPOLIA:?CHAINLINK_ETH_USD_ETH_SEPOLIA not set}"

RPC="${ALCHEMY_ETH_SEPOLIA_URL}"
PYTH_ETH_USD="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")

echo "→ Ethereum Sepolia deploy (Hook + Relayer)"
echo "  Deployer: ${DEPLOYER}"
echo "  V4:       ${POOL_MANAGER_ETH_SEPOLIA}"
echo ""

BALANCE_WEI=$(cast balance --rpc-url "${RPC}" "${DEPLOYER}")
BALANCE_ETH=$(cast to-unit "${BALANCE_WEI}" ether)
echo "  Balance: ${BALANCE_ETH} ETH"
if [[ "${BALANCE_WEI}" == "0" ]]; then
  echo ""
  echo "✗ Deployer has 0 Sepolia ETH."
  echo "  Faucet: https://www.alchemy.com/faucets/ethereum-sepolia"
  echo "  Address: ${DEPLOYER}"
  exit 1
fi

EFFECTIVE_AGENT="${AGENT_WALLET:-${DEPLOYER}}"
[[ "${EFFECTIVE_AGENT}" == "0x..."* || ${#EFFECTIVE_AGENT} -ne 42 ]] && EFFECTIVE_AGENT="${DEPLOYER}"

cd packages/contracts
echo "→ Mining hook CREATE2 salt for Ethereum Sepolia..."
SALT=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  "${POOL_MANAGER_ETH_SEPOLIA}" \
  "${HYPERLANE_MAILBOX_ETH_SEPOLIA}" \
  "${PYTH_ADDRESS_ETH_SEPOLIA}" \
  "${CHAINLINK_ETH_USD_ETH_SEPOLIA}" \
  "${PYTH_ETH_USD}" \
  --rpc-url "${RPC}" 2>&1 | grep "Salt (decimal):" | awk '{print $NF}')

if [[ -z "${SALT}" ]]; then
  echo "✗ Hook mining failed"
  exit 1
fi
echo "  Salt: ${SALT}"
echo ""

echo "→ Deploying to Ethereum Sepolia..."
VERIFY_FLAGS=""
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  VERIFY_FLAGS="--verify --etherscan-api-key ${ETHERSCAN_API_KEY}"
fi

HOOK_SALT_MAINNET="${SALT}" \
AGENT_WALLET="${EFFECTIVE_AGENT}" \
POOL_MANAGER_MAINNET="${POOL_MANAGER_ETH_SEPOLIA}" \
HYPERLANE_MAILBOX_MAINNET="${HYPERLANE_MAILBOX_ETH_SEPOLIA}" \
PYTH_ADDRESS_MAINNET="${PYTH_ADDRESS_ETH_SEPOLIA}" \
CHAINLINK_ETH_USD_MAINNET="${CHAINLINK_ETH_USD_ETH_SEPOLIA}" \
forge script script/Deploy.s.sol:DeployEthereum \
  --rpc-url "${RPC}" \
  --broadcast \
  ${VERIFY_FLAGS} \
  -vv 2>&1 | tail -25

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Ethereum Sepolia deploy complete"
echo "═══════════════════════════════════════════════════════════════════"
echo " View: https://sepolia.etherscan.io/address/${DEPLOYER}"
echo " Next: ./scripts/testnet-wire-sisters.sh"
