#!/usr/bin/env bash
# Initialize the WETH/USDC V4 pool with our MirrorHook on the Base Anvil fork.
# Funds the deployer with WETH (via deposit) + USDC (via Circle masterMinter)
# and adds liquidity so MonitorAgent reads non-zero pool state.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi
[[ -f /tmp/mirv-agent-env ]] && { set -a; source /tmp/mirv-agent-env; set +a; }

: "${MIRROR_HOOK_BASE:?MIRROR_HOOK_BASE not set — run anvil-deploy-cross-chain.sh first}"

PK="${DEPLOYER_PRIVATE_KEY}"
[[ "${PK}" != 0x* ]] && PK="0x${PK}"
DEPLOYER=$(cast wallet address --private-key "${PK}")
RPC="http://localhost:8546"

USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006

echo "→ Deployer: ${DEPLOYER}"
echo "→ Hook:     ${MIRROR_HOOK_BASE}"
echo ""

# ── Step 1: Fund deployer with USDC via Circle's masterMinter ─────────────────
echo "→ Minting 1M USDC to deployer..."
MASTER_MINTER=$(cast call --rpc-url "${RPC}" "${USDC}" "masterMinter()(address)")
cast rpc anvil_setBalance "${MASTER_MINTER}" 0x56BC75E2D63100000 --rpc-url "${RPC}" >/dev/null
cast rpc anvil_impersonateAccount "${MASTER_MINTER}" --rpc-url "${RPC}" >/dev/null
cast send "${USDC}" "configureMinter(address,uint256)" "${DEPLOYER}" 10000000000000 \
  --from "${MASTER_MINTER}" --unlocked --rpc-url "${RPC}" >/dev/null
cast rpc anvil_stopImpersonatingAccount "${MASTER_MINTER}" --rpc-url "${RPC}" >/dev/null
cast send "${USDC}" "mint(address,uint256)" "${DEPLOYER}" 1000000000000 \
  --private-key "${PK}" --rpc-url "${RPC}" >/dev/null
echo "  USDC balance: $(cast call --rpc-url ${RPC} ${USDC} 'balanceOf(address)(uint256)' ${DEPLOYER} | head -1)"

# ── Step 2: Fund deployer with WETH via deposit() ────────────────────────────
echo "→ Wrapping 100 ETH → WETH..."
cast send "${WETH}" "deposit()" --value 100ether \
  --private-key "${PK}" --rpc-url "${RPC}" >/dev/null
echo "  WETH balance: $(cast call --rpc-url ${RPC} ${WETH} 'balanceOf(address)(uint256)' ${DEPLOYER} | head -1)"

# ── Step 3: Initialize pool + add liquidity via Forge script ─────────────────
echo ""
echo "→ Initializing V4 pool + adding liquidity..."
cd packages/contracts
forge script script/InitPoolWithLiquidity.s.sol:InitPoolWithLiquidityBase \
  --rpc-url "${RPC}" --broadcast --skip-simulation 2>&1 \
  | grep -E "PoolModifyLiquidityTest:|Pool initialized|Liquidity added|EXECUTION|Error" | head -10

# ── Step 4: Verify ──────────────────────────────────────────────────────────
PAIR_ID=$(cast keccak "$(cast abi-encode 'f(address,address)' ${WETH} ${USDC})")
POOL_ID=$(cast keccak "$(cast abi-encode 'f(address,address,uint24,int24,address)' ${WETH} ${USDC} 3000 60 ${MIRROR_HOOK_BASE})")
echo ""
echo "→ Verifying pool state..."
LIQUIDITY=$(cast call --rpc-url "${RPC}" 0x498581fF718922c3f8e6A244956aF099B2652b2b \
  "getLiquidity(bytes32)(uint128)" "${POOL_ID}" | awk '{print $1}')
echo "  Pool liquidity:   ${LIQUIDITY}"

SQRT_RES=$(cast call --rpc-url "${RPC}" 0x498581fF718922c3f8e6A244956aF099B2652b2b \
  "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "${POOL_ID}")
SQRT=$(echo "${SQRT_RES}" | head -1)
TICK=$(echo "${SQRT_RES}" | sed -n '2p')
echo "  sqrtPriceX96:     ${SQRT}"
echo "  Current tick:     ${TICK}"

if [[ "${LIQUIDITY}" != "0" ]]; then
  echo ""
  echo "✓ Pool live with real liquidity. MonitorAgent will now see non-zero depth on Base."
else
  echo ""
  echo "✗ Liquidity is 0 — something went wrong"
  exit 1
fi
