#!/usr/bin/env bash
# Full v4 testnet deploy: fresh contracts on Base Sepolia + ETH Sepolia,
# wired up with canonical pairId + Vault chain registry + handle() inbound path
# + CCTP-ready Vault. Replaces the v3 deployments which lacked these features.
#
# Sequence:
#   1. Mine hook salts (including canonicalPairId in init code)
#   2. Drain old v3 hooks (best-effort; skips if revert known on Base Sepolia)
#   3. Deploy on Base Sepolia (DeployBase) — Treasury + Hook + Vault + Factory
#       + registerCanonicalPair + registerLocalPair (Base) + addChain (Base self)
#   4. Deploy on ETH Sepolia (DeployEthereum, --slow for EIP-7702) — Hook + Relayer
#   5. Verify contracts (auto in deploy)
#   6. Configure cross-chain:
#       - Factory.registerLocalPair (Ethereum side) on Base
#       - Vault.addChain (Ethereum) on Base
#       - Vault.setAllocations [Base 60%, Ethereum 40%]
#       - Hook.addSisterDomain on Base (→ ETH Relayer)
#       - Hook.addSisterDomain on Ethereum (→ Base Hook)
#       - Hook.setAuthorizedSender (Base accepts inbound from ETH hook)
#       - Relayer.setAuthorizedSender (ETH accepts dispatches from Base hook)
#       - Initialize V4 pools on both chains with new hooks
#       - Relayer.registerPool (canonicalPairId → ETH PoolKey with hook)
#   7. Fund hooks (~0.01 ETH each for Hyperlane dispatch fees)
#   8. Update .env with all new addresses
#   9. Print summary + Hyperlane explorer URLs

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

[[ -f .env ]] && { set -a; source .env; set +a; }

: "${ALCHEMY_BASE_SEPOLIA_URL:?ALCHEMY_BASE_SEPOLIA_URL not set}"
: "${ALCHEMY_ETH_SEPOLIA_URL:?ALCHEMY_ETH_SEPOLIA_URL not set}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"
: "${CCTP_TOKEN_MESSENGER_BASE_SEPOLIA:?CCTP_TOKEN_MESSENGER_BASE_SEPOLIA not set}"
: "${CCTP_TOKEN_MESSENGER_ETH_SEPOLIA:?CCTP_TOKEN_MESSENGER_ETH_SEPOLIA not set}"

# Canonical pair id for ETH/USDC V1 (must match Deploy.s.sol's CANONICAL_PAIR_ID_ETH_USDC)
CANONICAL_PAIR_ID=$(cast keccak "$(cast abi-encode --packed 'f(string,uint24,int24)' 'ETH-USDC-V1' 3000 60)")
PYTH_ETH_USD="0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"

PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")

echo "═══════════════════════════════════════════════════════════════════"
echo " mirv v4 testnet deploy"
echo "═══════════════════════════════════════════════════════════════════"
echo " Deployer:         ${DEPLOYER}"
echo " Canonical pairId: ${CANONICAL_PAIR_ID}"
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 1: Mine hook salts
# ─────────────────────────────────────────────────────────────────────
cd packages/contracts

echo "→ [1/9] Mining hook salt for Base Sepolia..."
SALT_BASE=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32,bytes32)" \
  "${POOL_MANAGER_BASE_SEPOLIA}" \
  "${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
  "${PYTH_ADDRESS_BASE_SEPOLIA}" \
  "${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
  "${PYTH_ETH_USD}" \
  "${CANONICAL_PAIR_ID}" \
  --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" 2>&1 | grep "Salt (decimal):" | awk '{print $NF}')
echo "  Base salt: ${SALT_BASE}"
[[ -z "${SALT_BASE}" ]] && { echo "✗ Hook mining failed (Base)"; exit 1; }

echo "→ [1b/9] Mining hook salt for ETH Sepolia..."
SALT_ETH=$(forge script script/MineHookAddress.s.sol \
  --sig "run(address,address,address,address,bytes32,bytes32)" \
  "${POOL_MANAGER_ETH_SEPOLIA}" \
  "${HYPERLANE_MAILBOX_ETH_SEPOLIA}" \
  "${PYTH_ADDRESS_ETH_SEPOLIA}" \
  "${CHAINLINK_ETH_USD_ETH_SEPOLIA}" \
  "${PYTH_ETH_USD}" \
  "${CANONICAL_PAIR_ID}" \
  --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" 2>&1 | grep "Salt (decimal):" | awk '{print $NF}')
echo "  ETH salt: ${SALT_ETH}"
[[ -z "${SALT_ETH}" ]] && { echo "✗ Hook mining failed (ETH)"; exit 1; }
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 2: Drain old v3 hooks (best-effort)
# ─────────────────────────────────────────────────────────────────────
cd "${ROOT}"
echo "→ [2/9] Draining old v3 hooks (best-effort)..."
if [[ -n "${MIRROR_HOOK_BASE:-}" && "${MIRROR_HOOK_BASE}" != "0x..." ]]; then
  BAL=$(cast balance --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" "${MIRROR_HOOK_BASE}" 2>/dev/null || echo 0)
  if [[ "${BAL}" != "0" && "${BAL}" != "" ]]; then
    cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
      "${MIRROR_HOOK_BASE}" "withdrawEth(uint256)" "${BAL}" 2>&1 | grep -E "status|Error" | head -1 || true
  fi
fi
if [[ -n "${MIRROR_HOOK_MAINNET:-}" && "${MIRROR_HOOK_MAINNET}" != "0x..." ]]; then
  BAL=$(cast balance --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" "${MIRROR_HOOK_MAINNET}" 2>/dev/null || echo 0)
  if [[ "${BAL}" != "0" && "${BAL}" != "" ]]; then
    cast send --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" --private-key "${PK}" \
      "${MIRROR_HOOK_MAINNET}" "withdrawEth(uint256)" "${BAL}" 2>&1 | grep -E "status|Error" | head -1 || true
  fi
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 3: Deploy on Base Sepolia
# ─────────────────────────────────────────────────────────────────────
cd packages/contracts
echo "→ [3/9] Deploying on Base Sepolia (Treasury + Hook + Vault + Factory)..."

VERIFY_BASE=""
[[ -n "${BASESCAN_API_KEY:-}" ]] && VERIFY_BASE="--verify --etherscan-api-key ${BASESCAN_API_KEY}"

HOOK_SALT_BASE="${SALT_BASE}" \
TREASURY_SAFE="${DEPLOYER}" \
AGENT_WALLET="${AGENT_WALLET:-${DEPLOYER}}" \
POOL_MANAGER_BASE="${POOL_MANAGER_BASE_SEPOLIA}" \
HYPERLANE_MAILBOX_BASE="${HYPERLANE_MAILBOX_BASE_SEPOLIA}" \
PYTH_ADDRESS_BASE="${PYTH_ADDRESS_BASE_SEPOLIA}" \
CHAINLINK_ETH_USD_BASE="${CHAINLINK_ETH_USD_BASE_SEPOLIA}" \
VAULT_ASSET_BASE="${USDC_BASE_SEPOLIA}" \
WETH_BASE="${WETH_BASE_SEPOLIA}" \
CCTP_TOKEN_MESSENGER_BASE="${CCTP_TOKEN_MESSENGER_BASE_SEPOLIA}" \
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" \
  --broadcast \
  ${VERIFY_BASE} \
  -vv 2>&1 | tail -10

# Extract addresses
BB="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/84532/run-latest.json"
TREASURY_NEW=$(cast to-check-sum-address $(jq -r '[.transactions[] | select(.contractName == "Treasury")][0].contractAddress' "$BB"))
HOOK_BASE_NEW=$(cast to-check-sum-address $(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "$BB"))
VAULT_NEW=$(cast to-check-sum-address $(jq -r '[.transactions[] | select(.contractName == "MirrorVault")][0].contractAddress' "$BB"))
FACTORY_NEW=$(cast to-check-sum-address $(jq -r '[.transactions[] | select(.contractName == "MirrorFactory")][0].contractAddress' "$BB"))

echo "  Treasury:      ${TREASURY_NEW}"
echo "  MirrorHook:    ${HOOK_BASE_NEW}  (must end 0x540)"
echo "  MirrorVault:   ${VAULT_NEW}"
echo "  MirrorFactory: ${FACTORY_NEW}"
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 4: Deploy on ETH Sepolia
# ─────────────────────────────────────────────────────────────────────
echo "→ [4/9] Deploying on ETH Sepolia (Hook + Relayer) with --slow for EIP-7702..."
VERIFY_ETH=""
[[ -n "${ETHERSCAN_API_KEY:-}" ]] && VERIFY_ETH="--verify --etherscan-api-key ${ETHERSCAN_API_KEY}"

HOOK_SALT_MAINNET="${SALT_ETH}" \
AGENT_WALLET="${AGENT_WALLET:-${DEPLOYER}}" \
POOL_MANAGER_MAINNET="${POOL_MANAGER_ETH_SEPOLIA}" \
HYPERLANE_MAILBOX_MAINNET="${HYPERLANE_MAILBOX_ETH_SEPOLIA}" \
PYTH_ADDRESS_MAINNET="${PYTH_ADDRESS_ETH_SEPOLIA}" \
CHAINLINK_ETH_USD_MAINNET="${CHAINLINK_ETH_USD_ETH_SEPOLIA}" \
forge script script/Deploy.s.sol:DeployEthereum \
  --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" \
  --broadcast --slow \
  ${VERIFY_ETH} \
  -vv 2>&1 | tail -10

EB="${ROOT}/packages/contracts/broadcast/Deploy.s.sol/11155111/run-latest.json"
HOOK_ETH_NEW=$(cast to-check-sum-address $(jq -r '[.transactions[] | select(.contractName == "MirrorHook")][0].contractAddress' "$EB"))
RELAYER_NEW=$(cast to-check-sum-address $(jq -r '[.transactions[] | select(.contractName == "Relayer")][0].contractAddress' "$EB"))

echo "  MirrorHook (ETH): ${HOOK_ETH_NEW}  (must end 0x540)"
echo "  Relayer (ETH):    ${RELAYER_NEW}"
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 5: Update .env
# ─────────────────────────────────────────────────────────────────────
cd "${ROOT}"
echo "→ [5/9] Updating .env with new addresses..."
cp .env ".env.bak.before-v4.$(date +%Y%m%d-%H%M%S)"
sed -i '' "s|^TREASURY_BASE=.*|TREASURY_BASE=${TREASURY_NEW}|"               .env
sed -i '' "s|^MIRROR_HOOK_BASE=.*|MIRROR_HOOK_BASE=${HOOK_BASE_NEW}|"        .env
sed -i '' "s|^MIRROR_VAULT_BASE=.*|MIRROR_VAULT_BASE=${VAULT_NEW}|"          .env
sed -i '' "s|^MIRROR_FACTORY_BASE=.*|MIRROR_FACTORY_BASE=${FACTORY_NEW}|"    .env
sed -i '' "s|^MIRROR_HOOK_MAINNET=.*|MIRROR_HOOK_MAINNET=${HOOK_ETH_NEW}|"   .env
sed -i '' "s|^RELAYER_MAINNET=.*|RELAYER_MAINNET=${RELAYER_NEW}|"            .env
sed -i '' "s|^HOOK_SALT_BASE=.*|HOOK_SALT_BASE=${SALT_BASE}|"                .env
sed -i '' "s|^HOOK_SALT_MAINNET=.*|HOOK_SALT_MAINNET=${SALT_ETH}|"           .env

# re-source for the rest of the script
set -a; source .env; set +a
echo "  .env updated."
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 6: Configure cross-chain
# ─────────────────────────────────────────────────────────────────────
echo "→ [6/9] Configuring cross-chain wiring..."

ETH_HOOK_B32="0x000000000000000000000000${HOOK_ETH_NEW:2}"
ETH_HOOK_B32=$(echo "$ETH_HOOK_B32" | tr '[:upper:]' '[:lower:]')
BASE_HOOK_B32="0x000000000000000000000000${HOOK_BASE_NEW:2}"
BASE_HOOK_B32=$(echo "$BASE_HOOK_B32" | tr '[:upper:]' '[:lower:]')
ETH_RELAYER_B32="0x000000000000000000000000${RELAYER_NEW:2}"
ETH_RELAYER_B32=$(echo "$ETH_RELAYER_B32" | tr '[:upper:]' '[:lower:]')

echo "  [6a] Factory.registerLocalPair (Ethereum side) on Base..."
cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
  "${MIRROR_FACTORY_BASE}" \
  "registerLocalPair(bytes32,uint32,address,address,address)" \
  "${CANONICAL_PAIR_ID}" 11155111 "${USDC_ETH_SEPOLIA}" "${WETH_ETH_SEPOLIA}" "${HOOK_ETH_NEW}" \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6b] Vault.addChain (ETH Sepolia, CCTP domain 0)..."
cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
  "${MIRROR_VAULT_BASE}" \
  "addChain(uint32,uint32,bytes32,address,bytes32,uint16)" \
  11155111 0 "${ETH_RELAYER_B32}" 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000000 4000 \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6c] Vault.setAllocations [Base 60%, Ethereum 40%]..."
cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
  "${MIRROR_VAULT_BASE}" \
  "setAllocations(uint32[],uint16[])" \
  "[84532,11155111]" "[6000,4000]" \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6d] Base hook.addSisterDomain (→ ETH Relayer for executable dispatch)..."
cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
  "${MIRROR_HOOK_BASE}" \
  "addSisterDomain(uint32,bytes32)" 11155111 "${ETH_RELAYER_B32}" \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6e] Base hook.setAuthorizedSender (accepts inbound from ETH hook for handle())..."
cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
  "${MIRROR_HOOK_BASE}" \
  "setAuthorizedSender(bytes32,bool)" "${ETH_HOOK_B32}" true \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6f] ETH hook.addSisterDomain (→ Base Hook for inbound notification)..."
cast send --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" --private-key "${PK}" \
  "${MIRROR_HOOK_MAINNET}" \
  "addSisterDomain(uint32,bytes32)" 84532 "${BASE_HOOK_B32}" \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6g] ETH Relayer.setAuthorizedSender (accepts dispatches from Base hook)..."
cast send --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" --private-key "${PK}" \
  "${RELAYER_MAINNET}" \
  "setAuthorizedSender(bytes32,bool)" "${BASE_HOOK_B32}" true \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6h] Initialize V4 pool on Base Sepolia..."
SQRT_PRICE_X96=1726889473953440971666681678004224  # tick 199800
cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
  "${POOL_MANAGER_BASE_SEPOLIA}" \
  "initialize((address,address,uint24,int24,address),uint160)" \
  "(${USDC_BASE_SEPOLIA},${WETH_BASE_SEPOLIA},3000,60,${MIRROR_HOOK_BASE})" \
  "${SQRT_PRICE_X96}" \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6i] Initialize V4 pool on ETH Sepolia..."
cast send --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" --private-key "${PK}" \
  "${POOL_MANAGER_ETH_SEPOLIA}" \
  "initialize((address,address,uint24,int24,address),uint160)" \
  "(${USDC_ETH_SEPOLIA},${WETH_ETH_SEPOLIA},3000,60,${MIRROR_HOOK_MAINNET})" \
  "${SQRT_PRICE_X96}" \
  2>&1 | grep -E "status|Error" | head -1

echo "  [6j] Relayer.registerPool (canonicalPairId → ETH PoolKey with hook)..."
cast send --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" --private-key "${PK}" \
  "${RELAYER_MAINNET}" \
  "registerPool(bytes32,(address,address,uint24,int24,address))" \
  "${CANONICAL_PAIR_ID}" \
  "(${USDC_ETH_SEPOLIA},${WETH_ETH_SEPOLIA},3000,60,${MIRROR_HOOK_MAINNET})" \
  2>&1 | grep -E "status|Error" | head -1
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 7: Fund hooks
# ─────────────────────────────────────────────────────────────────────
echo "→ [7/9] Funding hooks with 0.01 ETH each..."
cast send --rpc-url "${ALCHEMY_BASE_SEPOLIA_URL}" --private-key "${PK}" \
  --value 0.01ether "${MIRROR_HOOK_BASE}" 2>&1 | grep -E "status" | head -1
cast send --rpc-url "${ALCHEMY_ETH_SEPOLIA_URL}" --private-key "${PK}" \
  --value 0.01ether "${MIRROR_HOOK_MAINNET}" 2>&1 | grep -E "status" | head -1
echo ""

# ─────────────────────────────────────────────────────────────────────
# Step 8: Final on-chain verification
# ─────────────────────────────────────────────────────────────────────
echo "→ [8/9] On-chain verification..."
echo "  Base hook balance:           $(cast to-unit $(cast balance --rpc-url ${ALCHEMY_BASE_SEPOLIA_URL} ${MIRROR_HOOK_BASE}) ether) ETH"
echo "  ETH hook balance:            $(cast to-unit $(cast balance --rpc-url ${ALCHEMY_ETH_SEPOLIA_URL} ${MIRROR_HOOK_MAINNET}) ether) ETH"
echo "  Vault enabled domains:       $(cast call --rpc-url ${ALCHEMY_BASE_SEPOLIA_URL} ${MIRROR_VAULT_BASE} 'enabledDomainsCount()(uint256)')"
echo "  Base hook canonicalPairId:   $(cast call --rpc-url ${ALCHEMY_BASE_SEPOLIA_URL} ${MIRROR_HOOK_BASE} 'canonicalPairId()(bytes32)')"
echo "  ETH hook canonicalPairId:    $(cast call --rpc-url ${ALCHEMY_ETH_SEPOLIA_URL} ${MIRROR_HOOK_MAINNET} 'canonicalPairId()(bytes32)')"
echo ""

echo "═══════════════════════════════════════════════════════════════════"
echo " ✓ mirv v4 testnet deploy complete"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo " Base Sepolia:"
echo "   Treasury:    https://sepolia.basescan.org/address/${TREASURY_NEW}"
echo "   MirrorHook:  https://sepolia.basescan.org/address/${MIRROR_HOOK_BASE}"
echo "   MirrorVault: https://sepolia.basescan.org/address/${MIRROR_VAULT_BASE}"
echo "   Factory:     https://sepolia.basescan.org/address/${MIRROR_FACTORY_BASE}"
echo ""
echo " ETH Sepolia:"
echo "   MirrorHook:  https://sepolia.etherscan.io/address/${MIRROR_HOOK_MAINNET}"
echo "   Relayer:     https://sepolia.etherscan.io/address/${RELAYER_MAINNET}"
echo ""
echo " Next: validate end-to-end via existing TriggerV4DispatchBaseSepolia / EthSepolia scripts."
