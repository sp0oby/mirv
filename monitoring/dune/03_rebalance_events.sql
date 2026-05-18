-- mirv — Rebalance events feed
--
-- Every RebalanceDispatched from MirrorHook with destination domain,
-- canonical pairId, and the resulting messageId. Joined against
-- RebalanceExecuted on the destination chain so operators can spot
-- in-flight messages that never landed.
--
-- Two-leg query: source side on Base; destination side on Ethereum.
-- Both feed the dashboard "Operations → Rebalance feed" panel.
--
-- Tag: rc5.

WITH dispatches AS (
    SELECT
        block_time AS source_time,
        tx_hash AS source_tx,
        topic1 AS message_id,                          -- bytes32
        bytea2numeric(SUBSTRING(data, 1, 32)) AS destination_domain,
        topic2 AS pair_id                              -- bytes32 (canonical)
    FROM base.logs
    WHERE contract_address = LOWER('{{ MIRROR_HOOK_BASE }}')
      AND topic0 = 0xACTUAL_TOPIC0_HASH_FOR_RebalanceDispatched
      AND block_time >= NOW() - INTERVAL '30 days'
),

executions AS (
    -- RebalanceExecuted(bytes32 indexed pairId, int128 deltaToken0, int128 deltaToken1)
    -- on ETH mainnet (the destination Relayer)
    SELECT
        block_time AS exec_time,
        tx_hash AS exec_tx,
        topic1 AS pair_id,
        bytea2numeric(SUBSTRING(data, 1, 32)) AS delta_token0,
        bytea2numeric(SUBSTRING(data, 33, 32)) AS delta_token1
    FROM ethereum.logs
    WHERE contract_address = LOWER('{{ RELAYER_MAINNET }}')
      AND topic0 = 0xACTUAL_TOPIC0_HASH_FOR_RebalanceExecuted
      AND block_time >= NOW() - INTERVAL '30 days'
)

SELECT
    d.source_time,
    d.source_tx,
    d.destination_domain,
    d.pair_id,
    d.message_id,
    e.exec_time,
    e.exec_tx,
    e.delta_token0,
    e.delta_token1,
    EXTRACT(EPOCH FROM (e.exec_time - d.source_time)) AS delivery_seconds,
    CASE WHEN e.exec_tx IS NULL THEN 'pending_or_failed' ELSE 'delivered' END AS status
FROM dispatches d
LEFT JOIN executions e ON d.pair_id = e.pair_id
    AND e.exec_time BETWEEN d.source_time AND d.source_time + INTERVAL '15 minutes'
ORDER BY d.source_time DESC;
