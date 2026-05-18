-- mirv — Total Mirrored TVL (Base chain)
--
-- Headline number for the dashboard: USDC on the vault + cross-chain
-- assets reported by the agent. Mirrors `MirrorVault.totalAssets()`
-- semantically but trended over time rather than the latest value.
--
-- Schema: dune `base.logs`. Replace addresses + topic hashes when wiring.
-- Tag: events compatible with v1.0.0-rc5.

-- ─── Latest cross-chain assets value, per block ────────────────────────────
WITH cross_chain_reports AS (
    SELECT
        block_time,
        block_number,
        -- CrossChainAssetsUpdated(uint256 oldValue, uint256 newValue)
        -- topic0 = keccak256("CrossChainAssetsUpdated(uint256,uint256)")
        bytea2numeric(SUBSTRING(data, 33, 32)) AS new_value
    FROM base.logs
    WHERE contract_address = LOWER('{{ MIRROR_VAULT_BASE }}')
      AND topic0 = 0xACTUAL_TOPIC0_HASH_FOR_CrossChainAssetsUpdated_OldNew
      AND block_time >= NOW() - INTERVAL '30 days'
),

-- ─── Vault USDC balance per block via ERC-20 Transfer ──────────────────────
-- Approximation: sum of all transfers in/out of the vault address.
-- For a more accurate moving balance, join against base.tokens.erc20 balances.
vault_usdc AS (
    SELECT
        DATE_TRUNC('hour', block_time) AS hour,
        SUM(
            CASE
                WHEN LOWER('0x' || SUBSTRING(topic2::varchar, 27, 40)) = LOWER('{{ MIRROR_VAULT_BASE }}') THEN bytea2numeric(data)
                WHEN LOWER('0x' || SUBSTRING(topic1::varchar, 27, 40)) = LOWER('{{ MIRROR_VAULT_BASE }}') THEN -bytea2numeric(data)
                ELSE 0
            END
        ) / 1e6 AS net_usdc_in
    FROM base.logs
    WHERE contract_address = LOWER('{{ USDC_BASE }}')
      AND topic0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef  -- Transfer
      AND (
          LOWER('0x' || SUBSTRING(topic1::varchar, 27, 40)) = LOWER('{{ MIRROR_VAULT_BASE }}')
          OR LOWER('0x' || SUBSTRING(topic2::varchar, 27, 40)) = LOWER('{{ MIRROR_VAULT_BASE }}')
      )
    GROUP BY 1
),

local_balance AS (
    SELECT
        hour,
        SUM(net_usdc_in) OVER (ORDER BY hour) AS local_usdc
    FROM vault_usdc
)

SELECT
    lb.hour,
    lb.local_usdc AS local_usdc,
    COALESCE(LAST_VALUE(ccr.new_value) OVER (
        ORDER BY lb.hour ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 0) / 1e6 AS cross_chain_usdc,
    lb.local_usdc + COALESCE(LAST_VALUE(ccr.new_value) OVER (
        ORDER BY lb.hour ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 0) / 1e6 AS total_mirrored_usdc
FROM local_balance lb
LEFT JOIN cross_chain_reports ccr
    ON DATE_TRUNC('hour', ccr.block_time) = lb.hour
ORDER BY lb.hour DESC;
