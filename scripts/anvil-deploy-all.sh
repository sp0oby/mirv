#!/usr/bin/env bash
# Deploy mirv contracts across all 3 chains on local Anvil forks.
# Assumes anvil-all.sh has been run first (or runs it for you).
#
# 1. Ensures all 3 Anvil forks are running (mainnet, base, bnb)
# 2. Funds deployer wallet with 100 ETH on each chain
# 3. Mines hook salt for each chain
# 4. Deploys: Base (full stack: Treasury + Hook + Vault + Factory)
# 5. Deploys: Mainnet (Hook + Relayer)
# 6. Deploys: BNB (Hook + Relayer)
# 7. Reports all addresses
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"

# Normalize 0x prefix
PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")

# Override placeholder values for local testing
EFFECTIVE_TREASURY="${TREASURY_SAFE:-${DEPLOYER}}"
[[ "${EFFECTIVE_TREASURY}" == "0x..."* || ${#EFFECTIVE_TREASURY} -ne 42 ]] && EFFECTIVE_TREASURY="${DEPLOYER}"
EFFECTIVE_AGENT="${AGENT_WALLET:-${DEPLOYER}}"
[[ "${EFFECTIVE_AGENT}" == "0x..."* || ${#EFFECTIVE_AGENT} -ne 42 ]] && EFFECTIVE_AGENT="${DEPLOYER}"

PYTH_ETH_USD="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

# ── Ensure forks are running ──────────────────────────────────────────────────
echo "→ Checking Anvil forks..."
for chain_port in "mainnet:8545" "base:8546" "bnb:8547"; do
  chain="${chain_port%:*}"
  port="${chain_port#*:}"
  if ! cast block-number --rpc-url "http://localhost:${port}" >/dev/null 2>&1; then
    echo "  ${chain} not running, starting all forks..."
    "${ROOT}/scripts/anvil-all.sh"
    break
  fi
done
echo "✓ All forks ready"

# ── Fund deployer on each chain ───────────────────────────────────────────────
echo "→ Funding deployer ${DEPLOYER} with 100 ETH on each chain..."
for port in 8545 8546 8547; do
  cast rpc anvil_setBalance "${DEPLOYER}" 0x56BC75E2D63100000 --rpc-url "http://localhost:${port}" >/dev/null
done
echo "✓ Funded"

# ── Mine hook salts ───────────────────────────────────────────────────────────
mine_salt() {
  local chain_port="$1"
  local chain_name="$2"
  local pool_manager="$3"
  local mailbox="$4"
  local pyth="$5"
  local chainlink="$6"
  cd "${ROOT}/packages/contracts"
  local mine_out
  mine_out=$(forge script script/MineHookAddress.s.sol \
    --sig "run(address,address,address,address,bytes32)" \
    "${pool_manager}" "${mailbox}" "${pyth}" "${chainlink}" "${PYTH_ETH_USD}" \
    --rpc-url "http://localhost:${chain_port}" 2>&1)
  local salt
  salt=$(echo "${mine_out}" | grep "Salt (decimal):" | awk '{print $NF}')
  if [[ -z "${salt}" ]]; then
    echo "✗ Hook mining failed for ${chain_name}" >&2
    echo "${mine_out}" | tail -10 >&2
    exit 1
  fi
  echo "${salt}"
}

echo "→ Mining hook salts (uses verified addresses from .env)..."
SALT_BASE=$(mine_salt 8546 Base \
  "${POOL_MANAGER_BASE}" "${HYPERLANE_MAILBOX_BASE}" "${PYTH_ADDRESS_BASE}" "${CHAINLINK_ETH_USD_BASE}")
echo "  Base:    ${SALT_BASE}"
SALT_MAINNET=$(mine_salt 8545 Mainnet \
  "${POOL_MANAGER_MAINNET}" "${HYPERLANE_MAILBOX_MAINNET}" "${PYTH_ADDRESS_MAINNET}" "${CHAINLINK_ETH_USD_MAINNET}")
echo "  Mainnet: ${SALT_MAINNET}"
SALT_BNB=$(mine_salt 8547 BNB \
  "${POOL_MANAGER_BNB}" "${HYPERLANE_MAILBOX_BNB}" "${PYTH_ADDRESS_BNB}" "${CHAINLINK_ETH_USD_BNB}")
echo "  BNB:     ${SALT_BNB}"

# ── Deploy on each chain ──────────────────────────────────────────────────────
cd "${ROOT}/packages/contracts"

deploy_chain() {
  local script_target="$1"
  local rpc="$2"
  local salt_var="$3"
  local salt="$4"
  echo ""
  echo "→ Deploying ${script_target} on ${rpc}..."
  HOOK_SALT_BASE="${SALT_BASE}" \
  HOOK_SALT_MAINNET="${SALT_MAINNET}" \
  HOOK_SALT_BNB="${SALT_BNB}" \
  TREASURY_SAFE="${EFFECTIVE_TREASURY}" \
  AGENT_WALLET="${EFFECTIVE_AGENT}" \
  forge script "script/Deploy.s.sol:${script_target}" \
    --rpc-url "${rpc}" \
    --broadcast \
    --skip-simulation \
    -vv 2>&1 | grep -E "Mirror|Treasury:|Relayer|EXECUTION|Error" | head -10
}

deploy_chain "DeployBase"     "http://localhost:8546" "HOOK_SALT_BASE"    "${SALT_BASE}"
deploy_chain "DeployEthereum" "http://localhost:8545" "HOOK_SALT_MAINNET" "${SALT_MAINNET}"
deploy_chain "DeployBnb"      "http://localhost:8547" "HOOK_SALT_BNB"     "${SALT_BNB}"

# ── Summarize ─────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Multi-chain Anvil deployment complete"
echo "═══════════════════════════════════════════════════════════════════"
echo " Mainnet RPC: http://localhost:8545 (chain 1)"
echo " Base RPC:    http://localhost:8546 (chain 8453)"
echo " BNB RPC:     http://localhost:8547 (chain 56)"
echo ""
echo " Salts:"
echo "   HOOK_SALT_BASE=${SALT_BASE}"
echo "   HOOK_SALT_MAINNET=${SALT_MAINNET}"
echo "   HOOK_SALT_BNB=${SALT_BNB}"
echo ""
echo " Next step: ./scripts/wire-sister-domains.sh"
echo " Stop all:  ./scripts/anvil-stop.sh"
