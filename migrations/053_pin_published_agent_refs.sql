-- 053: pin the agent versions a published SOP actually ships with.
--
-- 052 moved template roles into the agents table but left every ref at
-- version 0, which means "follow the newest platform role". A published SOP
-- must not drift when someone edits a role later, so this pins each ref to the
-- platform role version that exists now. New publishes do this in code
-- (CatalogRepo.PublishGenericWorkflow); this script only backfills the SOPs
-- that were published before that change.
--
-- Idempotent: re-running pins to whatever the role version is at that moment.
-- Drafts are untouched on purpose: they should track the newest role.

SET NAMES utf8mb4;
SET SESSION group_concat_max_len = 1000000;
START TRANSACTION;

UPDATE generic_templates g
JOIN (
  SELECT x.tpl_id,
         CAST(CONCAT('[', GROUP_CONCAT(
           JSON_OBJECT('id', x.agent_id, 'version', x.agent_version)
           ORDER BY x.seq SEPARATOR ','
         ), ']') AS JSON) AS refs
  FROM (
    SELECT g2.id AS tpl_id,
           r.seq,
           r.agent_id,
           COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.version')) AS UNSIGNED), 0) AS agent_version
    FROM generic_templates g2,
         JSON_TABLE(g2.payload, '$.AgentRefs[*]' COLUMNS(
           seq FOR ORDINALITY,
           agent_id VARCHAR(128) PATH '$.id'
         )) r
    LEFT JOIN agents a ON a.id = r.agent_id COLLATE utf8mb4_unicode_ci
    WHERE JSON_UNQUOTE(JSON_EXTRACT(g2.payload, '$.Workflow.status')) = 'published'
  ) x
  GROUP BY x.tpl_id
) pinned ON pinned.tpl_id = g.id
SET g.payload = JSON_SET(g.payload, '$.AgentRefs', pinned.refs);

COMMIT;

-- Verify: this returns no rows once every published ref carries the current
-- platform role version.
SELECT g.id AS template_id,
       r.agent_id,
       r.version AS pinned,
       COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.version')) AS UNSIGNED), 0) AS current
FROM generic_templates g,
     JSON_TABLE(g.payload, '$.AgentRefs[*]' COLUMNS(
       agent_id VARCHAR(128) PATH '$.id',
       version INT PATH '$.version'
     )) r
LEFT JOIN agents a ON a.id = r.agent_id COLLATE utf8mb4_unicode_ci
WHERE JSON_UNQUOTE(JSON_EXTRACT(g.payload, '$.Workflow.status')) = 'published'
  AND COALESCE(r.version, 0) <> COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.version')) AS UNSIGNED), 0);
