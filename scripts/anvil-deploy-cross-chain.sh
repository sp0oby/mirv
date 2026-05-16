#!/usr/bin/env bash
# Full multi-chain cross-chain demo deployment using MockHyperlaneMailbox.
#
# 1. Ensures 3 Anvil forks are running
# 2. Deploys MockHyperlaneMailbox on each chain
# 3. Stores mailbox addresses in /tmp/mirv-mock-mailboxes
# 4. Re-deploys mirv contracts with the mock mailboxes (overriding HYPERLANE_MAILBOX_*)
# 5. Wires sister domains
# 6. Reports next steps for the cross-chain demo
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
DEPLOYER=$(cast wallet address --private-key "${PK}")

EFFECTIVE_TREASURY="${TREASURY_SAFE:-${DEPLOYER}}"
[[ "${EFFECTIVE_TREASURY}" == "0x..."* || ${#EFFECTIVE_TREASURY} -ne 42 ]] && EFFECTIVE_TREASURY="${DEPLOYER}"
EFFECTIVE_AGENT="${AGENT_WALLET:-${DEPLOYER}}"
[[ "${EFFECTIVE_AGENT}" == "0x..."* || ${#EFFECTIVE_AGENT} -ne 42 ]] && EFFECTIVE_AGENT="${DEPLOYER}"

# ── Ensure forks are running ──────────────────────────────────────────────────
echo "→ Checking Anvil forks..."
for chain_port in "mainnet:8545" "base:8546" "bnb:8547"; do
  chain="${chain_port%:*}"
  port="${chain_port#*:}"
  if ! cast block-number --rpc-url "http://localhost:${port}" >/dev/null 2>&1; then
    echo "  ${chain} not running — starting all forks..."
    "${ROOT}/scripts/anvil-all.sh"
    sleep 2
    break
  fi
done

# ── Fund deployer on each chain ───────────────────────────────────────────────
echo "→ Funding deployer on each chain..."
for port in 8545 8546 8547; do
  cast rpc anvil_setBalance "${DEPLOYER}" 0x56BC75E2D63100000 --rpc-url "http://localhost:${port}" >/dev/null
done

# ── Deploy MockHyperlaneMailbox on each chain ────────────────────────────────
cd "${ROOT}/packages/contracts"

deploy_mock_mailbox() {
  local script_target="$1"
  local rpc="$2"
  forge script "script/DeployMockMailboxes.s.sol:${script_target}" \
    --rpc-url "${rpc}" --broadcast --skip-simulation 2>&1 \
    | grep "MockHyperlaneMailbox" | awk -F: '{print $NF}' | tr -d ' '
}

echo "→ Deploying MockHyperlaneMailbox on each chain..."
MAILBOX_MAINNET=$(deploy_mock_mailbox DeployMockMailboxMainnet http://localhost:8545)
echo "  Mainnet: ${MAILBOX_MAINNET}"
MAILBOX_BASE=$(deploy_mock_mailbox DeployMockMailboxBase http://localhost:8546)
echo "  Base:    ${MAILBOX_BASE}"
MAILBOX_BNB=$(deploy_mock_mailbox DeployMockMailboxBnb http://localhost:8547)
echo "  BNB:     ${MAILBOX_BNB}"

# Save for the relay daemon
cat > /tmp/mirv-mock-mailboxes <<EOF
MAILBOX_MAINNET=${MAILBOX_MAINNET}
MAILBOX_BASE=${MAILBOX_BASE}
MAILBOX_BNB=${MAILBOX_BNB}
EOF
echo "  Saved to /tmp/mirv-mock-mailboxes"

# ── Mine + Deploy mirv with mock mailboxes ────────────────────────────────────
mine_salt() {
  local rpc="$1"
  local mailbox="$2"
  local poolMgr="$3"
  local pyth="$4"
  local chainlink="$5"
  local out
  out=$(HYPERLANE_MAILBOX_BASE="${mailbox}" \
    HYPERLANE_MAILBOX_MAINNET="${mailbox}" \
    HYPERLANE_MAILBOX_BNB="${mailbox}" \
    forge script script/MineHookAddress.s.sol \
    --sig "run(address,address,address,address,bytes32)" \
    "${poolMgr}" "${mailbox}" "${pyth}" "${chainlink}" \
    "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace" \
    --rpc-url "${rpc}" 2>&1)
  echo "${out}" | grep "Salt (decimal):" | awk '{print $NF}'
}

echo "→ Mining hook salts (with mock mailbox addresses)..."
SALT_BASE=$(mine_salt http://localhost:8546 "${MAILBOX_BASE}" \
  "${POOL_MANAGER_BASE}" "${PYTH_ADDRESS_BASE}" "${CHAINLINK_ETH_USD_BASE}")
echo "  Base:    ${SALT_BASE}"
SALT_MAINNET=$(mine_salt http://localhost:8545 "${MAILBOX_MAINNET}" \
  "${POOL_MANAGER_MAINNET}" "${PYTH_ADDRESS_MAINNET}" "${CHAINLINK_ETH_USD_MAINNET}")
echo "  Mainnet: ${SALT_MAINNET}"
SALT_BNB=$(mine_salt http://localhost:8547 "${MAILBOX_BNB}" \
  "${POOL_MANAGER_BNB}" "${PYTH_ADDRESS_BNB}" "${CHAINLINK_ETH_USD_BNB}")
echo "  BNB:     ${SALT_BNB}"

deploy_chain() {
  local script_target="$1"
  local rpc="$2"
  local mailbox="$3"
  HOOK_SALT_BASE="${SALT_BASE}" \
  HOOK_SALT_MAINNET="${SALT_MAINNET}" \
  HOOK_SALT_BNB="${SALT_BNB}" \
  TREASURY_SAFE="${EFFECTIVE_TREASURY}" \
  AGENT_WALLET="${EFFECTIVE_AGENT}" \
  HYPERLANE_MAILBOX_BASE="${mailbox}" \
  HYPERLANE_MAILBOX_MAINNET="${mailbox}" \
  HYPERLANE_MAILBOX_BNB="${mailbox}" \
  forge script "script/Deploy.s.sol:${script_target}" \
    --rpc-url "${rpc}" --broadcast --skip-simulation 2>&1 \
    | grep -E "Mirror|Treasury:|Relayer|EXECUTION|Error" | head -10
}

echo ""
echo "→ Deploying mirv contracts (using mock mailboxes)..."
deploy_chain "DeployBase"     "http://localhost:8546" "${MAILBOX_BASE}"
deploy_chain "DeployEthereum" "http://localhost:8545" "${MAILBOX_MAINNET}"
deploy_chain "DeployBnb"      "http://localhost:8547" "${MAILBOX_BNB}"

# ── Wire sister domains ───────────────────────────────────────────────────────
echo ""
echo "→ Wiring sister domains..."
"${ROOT}/scripts/anvil-wire-sisters.sh" 2>&1 | tail -10

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Cross-chain demo environment ready"
echo "═══════════════════════════════════════════════════════════════════"
echo " Mock mailboxes:"
echo "   Mainnet: ${MAILBOX_MAINNET}"
echo "   Base:    ${MAILBOX_BASE}"
echo "   BNB:     ${MAILBOX_BNB}"
echo ""
echo " Next steps:"
echo "   1. Start the relay daemon:    ./scripts/mock-hyperlane-relay.sh --background"
echo "   2. Trigger a rebalance:        cast send <hook> 'dispatchRebalance(...)' ..."
echo "   3. Watch /tmp/mirv-mock-relay.log for delivery confirmation"
echo "   4. Stop everything:            ./scripts/anvil-stop.sh && kill \$(cat /tmp/mirv-mock-relay.pid)"
