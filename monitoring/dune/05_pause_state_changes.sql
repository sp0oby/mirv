-- mirv — Pause / unpause state changes (incident response trail)
--
-- Captures every Paused/Unpaused on the Vault, Hook, and (when added)
-- Relayer. Joined with caller address so post-incident review can
-- correlate with the guardian vs owner pattern.
--
-- This query backs the OPERATIONS.md §5 "Pause procedure" review step.
-- Tag: rc5.

WITH pause_events AS (
    SELECT 'vault' AS contract_role, block_time, tx_hash, topic0,
           '0x' || SUBSTRING(SUBSTRING(data, 13, 32)::varchar, 27, 40) AS triggered_by
    FROM base.logs
    WHERE contract_address = LOWER('{{ MIRROR_VAULT_BASE }}')
      AND topic0 IN (
          0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258, -- Paused(address)
          0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa  -- Unpaused(address)
      )
      AND block_time >= NOW() - INTERVAL '180 days'

    UNION ALL

    SELECT 'hook' AS contract_role, block_time, tx_hash, topic0,
           '0x' || SUBSTRING(SUBSTRING(data, 13, 32)::varchar, 27, 40) AS triggered_by
    FROM base.logs
    WHERE contract_address = LOWER('{{ MIRROR_HOOK_BASE }}')
      AND topic0 IN (
          0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258,
          0x5db9ee0a495bf2e6ff9c91a7834c1ba4fdd244a5e8aa4e537bd38aeae4b073aa
      )
      AND block_time >= NOW() - INTERVAL '180 days'
)

SELECT
    block_time,
    contract_role,
    tx_hash,
    CASE
        WHEN topic0 = 0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258 THEN 'PAUSED'
        ELSE 'UNPAUSED'
    END AS state_change,
    triggered_by,
    CASE
        WHEN triggered_by = LOWER('{{ OWNER_MULTISIG_BASE }}') THEN 'owner'
        WHEN triggered_by = LOWER('{{ GUARDIAN_BASE }}') THEN 'guardian'
        ELSE 'OTHER_INVESTIGATE'
    END AS caller_role
FROM pause_events
ORDER BY block_time DESC;
