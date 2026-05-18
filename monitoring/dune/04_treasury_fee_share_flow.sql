-- mirv — Treasury fee-share flow
--
-- Tracks every PerformanceFeePaid event and the resulting share-mint to
-- the treasury. Forms the "fee revenue → safe" pipeline for the
-- transparency dashboard.
--
-- Tag: rc5.

WITH fee_events AS (
    SELECT
        block_time,
        tx_hash,
        bytea2numeric(SUBSTRING(data, 1, 32)) / 1e6 AS extra_yield_usdc,
        bytea2numeric(SUBSTRING(data, 33, 32)) / 1e18 AS fee_shares,
        topic1 AS treasury_address
    FROM base.logs
    WHERE contract_address = LOWER('{{ MIRROR_VAULT_BASE }}')
      AND topic0 = 0xACTUAL_TOPIC0_HASH_FOR_PerformanceFeePaid
      AND block_time >= NOW() - INTERVAL '180 days'
),

fee_forwarded AS (
    -- FeeForwarded(address indexed token, address indexed to, uint256 amount)
    -- on Base Treasury — when the safe sweep actually happens.
    SELECT
        block_time AS forward_time,
        tx_hash AS forward_tx,
        topic1 AS token,
        topic2 AS to_safe,
        bytea2numeric(data) / 1e6 AS amount_usdc
    FROM base.logs
    WHERE contract_address = LOWER('{{ TREASURY_BASE }}')
      AND topic0 = 0xACTUAL_TOPIC0_HASH_FOR_FeeForwarded
      AND block_time >= NOW() - INTERVAL '180 days'
)

SELECT
    f.block_time AS harvest_time,
    f.tx_hash AS harvest_tx,
    f.extra_yield_usdc,
    f.fee_shares,
    f.treasury_address,
    ff.forward_time,
    ff.amount_usdc AS amount_forwarded_to_safe,
    CASE
        WHEN ff.forward_tx IS NULL THEN 'shares_minted_not_forwarded'
        ELSE 'forwarded_to_safe'
    END AS status
FROM fee_events f
LEFT JOIN fee_forwarded ff
    ON ff.forward_time BETWEEN f.block_time AND f.block_time + INTERVAL '7 days'
ORDER BY f.block_time DESC;
