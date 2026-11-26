-- 056_merge_duplicate_harness_roles.sql
--
-- 清理项目 ai-devop-agent 里重复的 Harness 角色，并保留手工调过的模型配置。
--
-- 背景（脏数据成因）：
--   2026-11-25 08:53–08:57 手工建了一套 Harness 角色（id 形如 agent-mwvw3i…），
--   其中 4 条显式配了模型。09:38 从平台复制「Harness 融合交付 SOP」时，复制逻辑
--   按确定性 id <平台角色ID>-<项目ID> 新建了第二套角色，两套 SOP 的节点全部指向
--   新套，旧套从此零引用，但两条同名记录同时出现在「项目配置 → Agent 角色」列表里。
--
--   5 组同名角色的结构字段（loop / verification / hooks / artifactOutputs /
--   prompt / skills）完全一致，差异只在执行配置：
--
--     名称        孤儿 executor/model            在用 executor/model
--     需求定型    codebuddy  deepseek-v4.1-flash         codebuddy  NULL
--     测试验证    codebuddy  deepseek-v4.1-flash         codebuddy  NULL
--     方案设计    claude     deepseek-v4.1-flash-1017    codebuddy  NULL
--     开发实现    claude     deepseek-v4.1-flash-1017    codebuddy  NULL
--     独立评审    codebuddy  NULL                        codebuddy  NULL
--
-- 做法：
--   1. 只把孤儿角色的 model 搬到在用角色上（在用 model 非空则跳过，不覆盖）。
--      不搬 executorId：孤儿里 claude + deepseek-v4.1-flash-1017 是跨执行器的
--      无效组合（deepseek-v4.1-flash 系列在 CodeBuddy 模型白名单里，见
--      internal/httpapi/assistant_effort.go），在用角色本来就是 codebuddy，
--      只补 model 恰好把它修成合法组合。
--   2. 删除 5 条孤儿角色，带 NOT EXISTS 保护：任何情况下只要还有 workflow
--      节点引用该 id，就不删。
--   3. 顺带清掉这些孤儿 id 的历史快照，避免留下悬空的 definition_revisions。
--      节点历史 run 保存的是运行快照，不受影响。
--
-- 不改 version：这些是在用角色（被项目 workflow 节点直接引用），不参与
-- generic_templates.AgentRefs 的 pinAgentVersion 解析，version 保持连续即可。
--
-- 可重复执行：第 1 步要求在用 model 为空，第 2 步角色已删则无匹配，
-- 第 3 步绑定了角色存在性检查。重复执行不会二次改动。
--
-- 执行时机：独立修复，无前置依赖；与 052/053/054/055 无冲突。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   mysqldump -h <host> -u <user> -p <database> agents definition_revisions > backup_before_056.sql
--   mysql -h <host> -u <user> -p <database> < migrations/056_merge_duplicate_harness_roles.sql
--
-- 回滚：用上面的备份还原 agents / definition_revisions 两张表即可。

SET NAMES utf8mb4;
SET SESSION group_concat_max_len = 1000000;

-- ============================================================
-- 0) 预检：5 组同名角色的现状
-- ============================================================
SELECT 'BEFORE' AS stage, a.id AS agent_id, a.name,
       JSON_EXTRACT(a.payload, '$.executorId') AS executor_id,
       JSON_EXTRACT(a.payload, '$.model') AS model,
       (SELECT COUNT(*)
          FROM workflows w,
               JSON_TABLE(w.payload, '$.nodes[*]'
                          COLUMNS(agent_id VARCHAR(128) PATH '$.agentId')) n
         WHERE n.agent_id = a.id COLLATE utf8mb4_unicode_ci) AS node_refs
  FROM agents a
 WHERE a.id IN (
   'agent-mwvw3i7i-bbc9', 'agent-mwvw3i8b-h4pi', 'agent-mwvw3i8q-5yb7',
   'agent-mwvw3i93-hst1', 'agent-mwvw3i9e-8jxm',
   'generic-harness-delivery-clarify-ai-devop-agent',
   'generic-harness-delivery-review-ai-devop-agent',
   'generic-harness-delivery-test-ai-devop-agent',
   'generic-harness-delivery-design-ai-devop-agent',
   'generic-harness-delivery-implement-ai-devop-agent')
 ORDER BY a.name, a.id;

-- 预检：确认孤儿确实零引用（有输出即表示还能删，为空说明它们其实在用，需人工确认后再执行）
SELECT 'ORPHAN_IN_USE' AS stage, a.id AS agent_id, a.name
  FROM agents a
 WHERE a.id IN (
   'agent-mwvw3i7i-bbc9', 'agent-mwvw3i8b-h4pi', 'agent-mwvw3i8q-5yb7',
   'agent-mwvw3i93-hst1', 'agent-mwvw3i9e-8jxm')
   AND EXISTS (
     SELECT 1
       FROM workflows w,
            JSON_TABLE(w.payload, '$.nodes[*]'
                       COLUMNS(agent_id VARCHAR(128) PATH '$.agentId')) n
      WHERE n.agent_id = a.id COLLATE utf8mb4_unicode_ci);

START TRANSACTION;

-- ============================================================
-- 1) 把孤儿的 model 搬到在用角色（在用 model 非空则不覆盖）
-- ============================================================
UPDATE agents tgt
  JOIN (
    SELECT 'agent-mwvw3i7i-bbc9' AS orphan_id, 'generic-harness-delivery-clarify-ai-devop-agent'   AS target_id
    UNION ALL SELECT 'agent-mwvw3i8b-h4pi', 'generic-harness-delivery-review-ai-devop-agent'
    UNION ALL SELECT 'agent-mwvw3i8q-5yb7', 'generic-harness-delivery-test-ai-devop-agent'
    UNION ALL SELECT 'agent-mwvw3i93-hst1', 'generic-harness-delivery-design-ai-devop-agent'
    UNION ALL SELECT 'agent-mwvw3i9e-8jxm', 'generic-harness-delivery-implement-ai-devop-agent'
  ) m ON m.target_id = tgt.id
  JOIN agents src ON src.id = m.orphan_id
   SET tgt.payload = JSON_SET(tgt.payload, '$.model', JSON_EXTRACT(src.payload, '$.model')),
       tgt.updated_at = UTC_TIMESTAMP()
 WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(src.payload, '$.model')), '') <> ''
   AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(tgt.payload, '$.model')), '') = '';

SELECT 'STEP1' AS stage, 'models moved to in-use roles' AS note, ROW_COUNT() AS updated;

-- ============================================================
-- 2) 删除零引用的孤儿角色
-- ============================================================
DELETE a FROM agents a
 WHERE a.id IN (
   'agent-mwvw3i7i-bbc9', 'agent-mwvw3i8b-h4pi', 'agent-mwvw3i8q-5yb7',
   'agent-mwvw3i93-hst1', 'agent-mwvw3i9e-8jxm')
   AND NOT EXISTS (
     SELECT 1
       FROM workflows w,
            JSON_TABLE(w.payload, '$.nodes[*]'
                       COLUMNS(agent_id VARCHAR(128) PATH '$.agentId')) n
      WHERE n.agent_id = a.id COLLATE utf8mb4_unicode_ci);

SELECT 'STEP2' AS stage, 'orphan roles deleted' AS note, ROW_COUNT() AS deleted;

-- ============================================================
-- 3) 清掉孤儿角色的历史快照（仅在角色已删除时执行）
-- ============================================================
DELETE r FROM definition_revisions r
 WHERE r.entity_id IN (
   'agent-mwvw3i7i-bbc9', 'agent-mwvw3i8b-h4pi', 'agent-mwvw3i8q-5yb7',
   'agent-mwvw3i93-hst1', 'agent-mwvw3i9e-8jxm')
   AND NOT EXISTS (SELECT 1 FROM agents a WHERE a.id = r.entity_id);

SELECT 'STEP3' AS stage, 'orphan revisions deleted' AS note, ROW_COUNT() AS deleted;

COMMIT;

-- ============================================================
-- 4) 核对
-- ============================================================
-- 4.1 项目内不应再有同名角色（有输出说明还有残留）
SELECT 'DUPLICATE' AS stage, t.project_id, t.name, COUNT(*) AS n
  FROM (
    SELECT COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '(platform)') AS project_id,
           JSON_UNQUOTE(JSON_EXTRACT(payload, '$.name')) AS name
      FROM agents
  ) t
 GROUP BY t.project_id, t.name
HAVING COUNT(*) > 1
 ORDER BY t.project_id, t.name;

-- 4.2 在用角色的最终执行配置
SELECT 'AFTER' AS stage, id, name,
       JSON_EXTRACT(payload, '$.executorId') AS executor_id,
       JSON_EXTRACT(payload, '$.model') AS model,
       JSON_EXTRACT(payload, '$.version') AS version
  FROM agents
 WHERE id IN (
   'generic-harness-delivery-clarify-ai-devop-agent',
   'generic-harness-delivery-review-ai-devop-agent',
   'generic-harness-delivery-test-ai-devop-agent',
   'generic-harness-delivery-design-ai-devop-agent',
   'generic-harness-delivery-implement-ai-devop-agent')
 ORDER BY id;

-- 4.3 workflow 节点引用的角色必须全部存在（有输出说明删错了）
SELECT 'DANGLING' AS stage, w.id AS workflow_id, n.node_id, n.agent_id
  FROM workflows w,
       JSON_TABLE(w.payload, '$.nodes[*]'
                  COLUMNS(node_id VARCHAR(64) PATH '$.id',
                          agent_id VARCHAR(128) PATH '$.agentId')) n
 WHERE n.agent_id IS NOT NULL AND n.agent_id <> ''
   AND NOT EXISTS (SELECT 1 FROM agents a WHERE a.id = n.agent_id COLLATE utf8mb4_unicode_ci);
