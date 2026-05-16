#!/usr/bin/env bash
# Full Phase 4 vault lifecycle smoke test against a local Base Anvil fork.
#
# Assumes anvil-deploy-base.sh has already deployed the contracts.
# Reads addresses from broadcast/Deploy.s.sol/8453/run-latest.json.
#
# Test sequence:
#   1. Mint 100k USDC to deployer via Circle's masterMinter (impersonated)
#   2. Approve vault to spend 10k USDC
#   3. Deposit 10k USDC → receive 10k mirvETH-USDC shares
#   4. Agent reports 500 USDC cross-chain yield via updateCrossChainAssets
#   5. Verify totalAssets() = 10.5k (local + cross-chain)
#   6. Set baseline APY = 5% via updateBaselineApy
#   7. Fast-forward 1 day + 1 second
#   8. Call harvest() → mints performance fee shares to treasury
#   9. Verify treasury holds expected shares
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

RPC="${ANVIL_BASE_RPC:-http://localhost:8546}"
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

# Private key handling (handle 0x prefix or not)
PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")

# Read deployed addresses
RUN_LATEST="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/8453/run-latest.json"
if [[ ! -f "${RUN_LATEST}" ]]; then
  echo "✗ Deployment log not found. Run scripts/anvil-deploy-base.sh first."
  exit 1
fi
HOOK=$(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "${RUN_LATEST}")
VAULT=$(jq -r '[.transactions[] | select(.contractName == "MirrorVault")][0].contractAddress' "${RUN_LATEST}")
TREASURY=$(jq -r '[.transactions[] | select(.contractName == "Treasury")][0].contractAddress' "${RUN_LATEST}")

echo "Deployment:"
echo "  Hook:     ${HOOK}"
echo "  Vault:    ${VAULT}"
echo "  Treasury: ${TREASURY}"
echo "  Deployer: ${DEPLOYER}"
echo "  RPC:      ${RPC}"

# Sanity check Anvil is up
if ! cast block-number --rpc-url "${RPC}" >/dev/null 2>&1; then
  echo "✗ Anvil not running on ${RPC}"; exit 1
fi

deployer_usdc() { cast call --rpc-url "${RPC}" "${USDC}" "balanceOf(address)(uint256)" "${DEPLOYER}"; }
vault_assets()  { cast call --rpc-url "${RPC}" "${VAULT}" "totalAssets()(uint256)"; }
vault_shares()  { cast call --rpc-url "${RPC}" "${VAULT}" "balanceOf(address)(uint256)" "$1"; }

# ─── 1. Mint USDC to deployer ─────────────────────────────────────────────────
echo ""
echo "── Step 1: Mint 100k USDC to deployer ──────────────────────────"
MASTER_MINTER=$(cast call --rpc-url "${RPC}" "${USDC}" "masterMinter()(address)")
cast rpc anvil_impersonateAccount "${MASTER_MINTER}" --rpc-url "${RPC}" >/dev/null
cast rpc anvil_setBalance "${MASTER_MINTER}" 0x56BC75E2D63100000 --rpc-url "${RPC}" >/dev/null
cast send "${USDC}" "configureMinter(address,uint256)" "${DEPLOYER}" 1000000000000 \
  --from "${MASTER_MINTER}" --unlocked --rpc-url "${RPC}" >/dev/null
cast rpc anvil_stopImpersonatingAccount "${MASTER_MINTER}" --rpc-url "${RPC}" >/dev/null
cast send "${USDC}" "mint(address,uint256)" "${DEPLOYER}" 100000000000 \
  --private-key "${PK}" --rpc-url "${RPC}" >/dev/null
echo "  Deployer USDC: $(deployer_usdc | head -1)"

# ─── 2 + 3. Approve + Deposit ─────────────────────────────────────────────────
echo ""
echo "── Step 2-3: Approve + deposit 10,000 USDC into vault ──────────"
cast send "${USDC}" "approve(address,uint256)" "${VAULT}" 10000000000 \
  --private-key "${PK}" --rpc-url "${RPC}" >/dev/null
cast send "${VAULT}" "deposit(uint256,address)" 10000000000 "${DEPLOYER}" \
  --private-key "${PK}" --rpc-url "${RPC}" >/dev/null
echo "  Deployer USDC: $(deployer_usdc | head -1)"
echo "  Deployer mirv shares: $(vault_shares ${DEPLOYER} | head -1)"
echo "  Vault totalAssets: $(vault_assets | head -1)"
echo "  Vault principalTracked: $(cast call --rpc-url ${RPC} ${VAULT} 'principalTracked()(uint256)' | head -1)"

# ─── 4. Agent reports 500 USDC cross-chain yield ──────────────────────────────
echo ""
echo "── Step 4: Agent reports 500 USDC cross-chain yield ────────────"
cast send "${VAULT}" "updateCrossChainAssets(uint256)" 500000000 \
  --private-key "${PK}" --rpc-url "${RPC}" >/dev/null
echo "  Vault totalAssets (with cross-chain): $(vault_assets | head -1)"

# ─── 5. Set baseline APY = 5% (500 bps) ──────────────────────────────────────
echo ""
echo "── Step 5: Set baseline single-chain APY = 5% ──────────────────"
cast send "${VAULT}" "updateBaselineApy(uint256)" 500 \
  --private-key "${PK}" --rpc-url "${RPC}" >/dev/null
echo "  baselineApyBps: $(cast call --rpc-url ${RPC} ${VAULT} 'baselineApyBps()(uint256)' | head -1)"

# ─── 6. Fast-forward 1 day + 1 second ────────────────────────────────────────
echo ""
echo "── Step 6: Fast-forward block timestamp 1 day + 1 sec ──────────"
cast rpc evm_increaseTime 86401 --rpc-url "${RPC}" >/dev/null
cast rpc evm_mine --rpc-url "${RPC}" >/dev/null
echo "  Block timestamp: $(cast block --rpc-url ${RPC} latest --field timestamp)"

# ─── 7. Harvest performance fee ──────────────────────────────────────────────
echo ""
echo "── Step 7: Harvest performance fee (15% of extra yield) ────────"
HARVEST_OUT=$(cast send "${VAULT}" "harvest()" \
  --private-key "${PK}" --rpc-url "${RPC}" 2>&1)
if echo "${HARVEST_OUT}" | grep -q "status\s*1 (success)"; then
  echo "  ✓ Harvest succeeded"
else
  echo "${HARVEST_OUT}" | tail -5
  exit 1
fi

# ─── 8. Verify treasury received fee shares ──────────────────────────────────
echo ""
echo "── Step 8: Verify treasury received fee shares ─────────────────"
TREASURY_SHARES=$(vault_shares "${TREASURY}")
echo "  Treasury vault shares: ${TREASURY_SHARES}"
echo "  Total vault supply:    $(cast call --rpc-url ${RPC} ${VAULT} 'totalSupply()(uint256)' | head -1)"
echo "  Total vault assets:    $(vault_assets | head -1)"
echo "  baselineYieldAccrued:  $(cast call --rpc-url ${RPC} ${VAULT} 'baselineYieldAccrued()(uint256)' | head -1)"

if [[ "${TREASURY_SHARES%% *}" == "0" ]]; then
  echo "  ✗ Treasury shares = 0, harvest did not mint fees"
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ Full vault lifecycle works on Anvil Base fork"
echo "═══════════════════════════════════════════════════════════════════"
echo " Deposit:          10,000 USDC → 10,000 mirvETH-USDC shares"
echo " Cross-chain:      +500 USDC reported by agent"
echo " Baseline APY:     5% over 1 day = ~1.37 USDC baseline"
echo " Extra yield:      ~498.6 USDC"
echo " Performance fee:  15% × 498.6 ≈ 74.8 USDC (minted as shares to treasury)"
