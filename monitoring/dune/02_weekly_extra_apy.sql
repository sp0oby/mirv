-- mirv — Weekly extra APY (vs. single-chain baseline)
--
-- Performance signal: every PerformanceFeePaid event implies a positive
-- extraYield. Sum extraYield per week, divide by average TVL, annualize.
-- This is what marketing will quote; treat its values as audit-traceable.
--
-- Schema: base.logs. Tag: rc5.
--
-- PerformanceFeePaid(uint256 extraYield, uint256 feeShares, address indexed treasury)
-- topic0 = keccak256("PerformanceFeePaid(uint256,uint256,address)")

WITH harvests AS (
    SELECT
        DATE_TRUNC('week', block_time) AS week,
        SUM(bytea2numeric(SUBSTRING(data, 1, 32))) / 1e6 AS extra_yield_usdc
    FROM base.logs
    WHERE contract_address = LOWER('{{ MIRROR_VAULT_BASE }}')
      AND topic0 = 0xACTUAL_TOPIC0_HASH_FOR_PerformanceFeePaid
      AND block_time >= NOW() - INTERVAL '90 days'
    GROUP BY 1
),

avg_tvl_per_week AS (
    -- Pulls from query #01 if uploaded as a Dune dataset; placeholder here.
    -- Replace with:  SELECT week, AVG(total_mirrored_usdc) AS avg_tvl FROM dune.{{ TEAM }}.query_01 GROUP BY 1
    SELECT
        DATE_TRUNC('week', NOW()) AS week,
        1e6::numeric AS avg_tvl  -- placeholder: 1M USDC reference
)

SELECT
    h.week,
    h.extra_yield_usdc,
    t.avg_tvl,
    (h.extra_yield_usdc / NULLIF(t.avg_tvl, 0)) * 52 * 100 AS annualized_extra_apy_pct
FROM harvests h
LEFT JOIN avg_tvl_per_week t USING (week)
ORDER BY h.week DESC;
