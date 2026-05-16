#!/usr/bin/env bash
# Full Phase 4 smoke test against a local Base Anvil fork.
#
# 1. Starts Anvil (Base fork) on port 8546 in the background if not running
# 2. Funds the deployer wallet with 100 ETH via anvil_setBalance
# 3. Mines a hook CREATE2 salt using MineHookAddress.s.sol
# 4. Deploys all contracts via Deploy.s.sol:DeployBase
# 5. Verifies deployment with cast calls
# 6. Leaves Anvil running so you can interact (cast / agents / frontend)
#
# Stop Anvil with: kill $(cat /tmp/mirv-anvil-base.pid)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# Load env
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ALCHEMY_BASE_URL:?ALCHEMY_BASE_URL not set in .env}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set in .env}"
: "${HYPERLANE_MAILBOX_BASE:?HYPERLANE_MAILBOX_BASE not set in .env}"
: "${POOL_MANAGER_BASE:?POOL_MANAGER_BASE not set in .env}"
: "${PYTH_ADDRESS_BASE:?PYTH_ADDRESS_BASE not set in .env}"
: "${CHAINLINK_ETH_USD_BASE:?CHAINLINK_ETH_USD_BASE not set in .env}"

PORT="${ANVIL_BASE_PORT:-8546}"
RPC="http://localhost:${PORT}"

# Add 0x prefix if missing (cast wallet address needs it)
PK_PREFIXED="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK_PREFIXED}" != 0x* ]] && PK_PREFIXED="0x${PK_PREFIXED}"
DEPLOYER_ADDR=$(cast wallet address --private-key "${PK_PREFIXED}")

# Pyth ETH/USD feed ID (same across chains)
PYTH_ETH_USD_ID="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

# ── 1. Start Anvil if not already running ─────────────────────────────────────
if cast block-number --rpc-url "${RPC}" >/dev/null 2>&1; then
  echo "→ Anvil already running on ${RPC} (block $(cast block-number --rpc-url ${RPC}))"
else
  echo "→ Starting Anvil (Base fork)..."
  "${ROOT}/scripts/anvil-base.sh" --background
  sleep 4
  if ! cast block-number --rpc-url "${RPC}" >/dev/null 2>&1; then
    echo "✗ Anvil failed to start. Check /tmp/mirv-anvil-base.log"
    exit 1
  fi
fi
echo "✓ Anvil ready"

# ── 2. Fund deployer with 100 ETH ─────────────────────────────────────────────
echo "→ Funding deployer ${DEPLOYER_ADDR} with 100 ETH..."
cast rpc anvil_setBalance "${DEPLOYER_ADDR}" 0x56BC75E2D63100000 --rpc-url "${RPC}" >/dev/null
echo "✓ Deployer balance: $(cast balance --rpc-url ${RPC} ${DEPLOYER_ADDR}) wei"

# ── 3. Mine hook address ──────────────────────────────────────────────────────
echo "→ Mining MirrorHook CREATE2 salt..."
cd packages/contracts
MINE_OUT=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32)" \
  "${POOL_MANAGER_BASE}" \
  "${HYPERLANE_MAILBOX_BASE}" \
  "${PYTH_ADDRESS_BASE}" \
  "${CHAINLINK_ETH_USD_BASE}" \
  "${PYTH_ETH_USD_ID}" \
  --rpc-url "${RPC}" 2>&1)
SALT=$(echo "${MINE_OUT}" | grep "Salt (decimal):" | awk '{print $NF}')
if [[ -z "${SALT}" ]]; then
  echo "✗ Hook mining failed:"
  echo "${MINE_OUT}" | tail -15
  exit 1
fi
echo "✓ Hook salt: ${SALT}"

# ── 4. Deploy ─────────────────────────────────────────────────────────────────
echo "→ Deploying contracts on Base fork..."

# Override placeholder env values for local testing. Placeholders are unset for forge.
EFFECTIVE_TREASURY="${TREASURY_SAFE}"
EFFECTIVE_AGENT="${AGENT_WALLET}"
# Treat values starting with "0x..." or shorter than a valid address as placeholders
if [[ "${EFFECTIVE_TREASURY}" == "0x..."* || ${#EFFECTIVE_TREASURY} -ne 42 ]]; then
  EFFECTIVE_TREASURY="${DEPLOYER_ADDR}"
  echo "  (using deployer as TREASURY_SAFE for local test)"
fi
if [[ "${EFFECTIVE_AGENT}" == "0x..."* || ${#EFFECTIVE_AGENT} -ne 42 ]]; then
  EFFECTIVE_AGENT="${DEPLOYER_ADDR}"
  echo "  (using deployer as AGENT_WALLET for local test)"
fi

HOOK_SALT_BASE="${SALT}" \
TREASURY_SAFE="${EFFECTIVE_TREASURY}" \
AGENT_WALLET="${EFFECTIVE_AGENT}" \
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url "${RPC}" \
  --broadcast \
  --skip-simulation \
  -vv 2>&1 | grep -E "Treasury:|MirrorHook|MirrorVault|MirrorFactory|EXECUTION|Error" | head -15

# ── 5. Verify deployment ──────────────────────────────────────────────────────
echo ""
echo "→ Verifying deployed contracts..."

# Get the most recent broadcast log
RUN_LATEST="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/8453/run-latest.json"
if [[ ! -f "${RUN_LATEST}" ]]; then
  echo "✗ Broadcast log not found"
  exit 1
fi

HOOK=$(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "${RUN_LATEST}")
VAULT=$(jq -r '[.transactions[] | select(.contractName == "MirrorVault")][0].contractAddress' "${RUN_LATEST}")
TREASURY=$(jq -r '[.transactions[] | select(.contractName == "Treasury")][0].contractAddress' "${RUN_LATEST}")
FACTORY=$(jq -r '[.transactions[] | select(.contractName == "MirrorFactory")][0].contractAddress' "${RUN_LATEST}")

echo "  Treasury:      ${TREASURY}"
echo "  MirrorHook:    ${HOOK}"
echo "  MirrorVault:   ${VAULT}"
echo "  MirrorFactory: ${FACTORY}"

PERF_FEE=$(cast call --rpc-url "${RPC}" "${VAULT}" "PERFORMANCE_FEE_BPS()(uint256)")
HOOK_AUTH=$(cast call --rpc-url "${RPC}" "${HOOK}" "authorizedAgents(address)(bool)" "${DEPLOYER_ADDR}")
VAULT_NAME=$(cast call --rpc-url "${RPC}" "${VAULT}" "name()(string)")

echo ""
echo "✓ Vault name:       ${VAULT_NAME}"
echo "✓ Performance fee:  ${PERF_FEE} bps"
echo "✓ Agent authorized: ${HOOK_AUTH}"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " Phase 4 Anvil deployment complete"
echo "═══════════════════════════════════════════════════════════════════"
echo " RPC:            ${RPC}"
echo " Anvil PID:      $(cat /tmp/mirv-anvil-base.pid 2>/dev/null || echo 'unknown')"
echo " Stop Anvil:     kill \$(cat /tmp/mirv-anvil-base.pid)"
echo ""
echo " Next steps:"
echo "   - cast call/send against the deployed contracts at ${RPC}"
echo "   - Run agents pointed at ${RPC}: ALCHEMY_BASE_URL=${RPC} yarn agents"
echo "   - Add the deployed addresses to .env for the agent to find them"
