-- 054_merge_platform_delivery_roles.sql
--
-- 收敛「设置 › 角色定义」里重复的平台角色：把通用前端交付、通用产品方案、
-- 通用缺陷修复三套 SOP 各自维护的一份角色副本，改绑到通用后端交付那套，
-- 再删掉副本，平台角色库回到「一个语义角色只有一条记录」。
--
-- 背景（脏数据成因）：
--   平台预置 5 套 SOP 模板，历史上每套模板入库时都按 `<模板id>-<节点>` 生成了
--   自己的一套角色。其中 2026-10-15 那批（frontend/product/issue-fix 共 13 条）
--   payload 里连 artifactOutputs / verification / loop 都没有，是早期精简版；
--   2026-11-16 又单独补了 2 条 MR 角色。结果是「交付汇总」「方案设计」
--   「独立评审」各出现 5 条，「开发实现」「测试验证」「发起 MR」各 4 条。
--   052 之后角色已统一到 agents 表，SOP 只记引用，具备合并条件；
--   generic-harness-delivery 当年就已经直接复用 backend 的 mr/deliver，
--   本脚本把这套做法补齐到其余三套模板。
--
-- 做法：
--   1. payload 里把 `generic-frontend-delivery-` / `generic-product-delivery-` /
--      `issue-fix-production-` 前缀整体替换成 `generic-backend-delivery-`。
--      替换串带尾横线，模板自身的 Workflow.id 不受影响（仍显式回写一次兜底）。
--   2. 按节点 agentId 重新推导 AgentRefs，并把 version pin 到角色当前版本
--      （沿用 053 的语义：已发布 SOP 不跟随角色后续改动漂移）。
--   3. 删除 18 条已无任何模板引用的冗余角色；仍被引用的会被 NOT EXISTS 挡住。
--
-- 可重复执行：
--   * 前缀替换第二次已无匹配，JSON 结果不变；
--   * AgentRefs 由节点重新推导，重复执行结果一致；
--   * DELETE 带引用检查，已删除的行自然不命中。
--
-- 执行时机：必须在 052 / 053 之后执行（052 建立 AgentRefs，053 定义 pin 语义）。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   mysqldump -h <host> -u <user> -p <database> \
--     agents generic_templates definition_revisions > backup_before_054.sql
--   mysql -h <host> -u <user> -p <database> < migrations/054_merge_platform_delivery_roles.sql
--
-- 回滚：本脚本只改 generic_templates.payload 与删除 agents 行，用上面的备份还原即可。

SET NAMES utf8mb4;
SET SESSION group_concat_max_len = 1000000;

-- ============================================================
-- 0) 预检：确认待改绑的节点与待删除的角色
-- ============================================================
SELECT 'BEFORE' AS stage, g.id AS template_id, n.agent_id
  FROM generic_templates g,
       JSON_TABLE(g.payload, '$.Workflow.nodes[*]'
         COLUMNS(agent_id VARCHAR(128) PATH '$.agentId')) n
 WHERE n.agent_id LIKE 'generic-frontend-delivery-%'
    OR n.agent_id LIKE 'generic-product-delivery-%'
    OR n.agent_id LIKE 'issue-fix-production-%'
 ORDER BY template_id, n.agent_id;

SELECT 'BEFORE' AS stage, id, name,
       JSON_EXTRACT(payload, '$.updatedAt') AS seeded_at,
       JSON_LENGTH(JSON_EXTRACT(payload, '$.artifactOutputs')) AS artifacts,
       JSON_LENGTH(JSON_EXTRACT(payload, '$.verification'))    AS gates
  FROM agents
 WHERE id LIKE 'generic-frontend-delivery-%'
    OR id LIKE 'generic-product-delivery-%'
    OR id LIKE 'issue-fix-production-%'
 ORDER BY id;

-- 这些角色不应出现在 run 侧引用里；有输出就必须先停下来人工确认
SELECT 'BLOCKER' AS stage, 'run 侧仍引用待删角色' AS reason, COUNT(*) AS rows_hit
  FROM run_nodes
 WHERE CAST(payload AS CHAR) LIKE '%generic-frontend-delivery-%'
    OR CAST(payload AS CHAR) LIKE '%generic-product-delivery-%'
    OR CAST(payload AS CHAR) LIKE '%issue-fix-production-%';

START TRANSACTION;

-- ============================================================
-- 1) 三套模板的节点与 AgentRefs 改绑到 backend 那套
-- ============================================================
UPDATE generic_templates
   SET payload = JSON_SET(
         CAST(REPLACE(CAST(payload AS CHAR),
                      'generic-frontend-delivery-', 'generic-backend-delivery-') AS JSON),
         '$.Workflow.id', id)
 WHERE id = 'generic-frontend-delivery';

UPDATE generic_templates
   SET payload = JSON_SET(
         CAST(REPLACE(CAST(payload AS CHAR),
                      'generic-product-delivery-', 'generic-backend-delivery-') AS JSON),
         '$.Workflow.id', id)
 WHERE id = 'generic-product-delivery';

UPDATE generic_templates
   SET payload = JSON_SET(
         CAST(REPLACE(CAST(payload AS CHAR),
                      'issue-fix-production-', 'generic-backend-delivery-') AS JSON),
         '$.Workflow.id', id)
 WHERE id = 'issue-fix-production';

-- ============================================================
-- 2) 由节点 agentId 重新推导 AgentRefs，并 pin 到角色当前 version
-- ============================================================
UPDATE generic_templates g
JOIN (
  SELECT tpl,
         CAST(CONCAT('[', GROUP_CONCAT(
           JSON_OBJECT('id', aid, 'version', ver) ORDER BY seq SEPARATOR ','
         ), ']') AS JSON) AS refs
    FROM (
      SELECT DISTINCT g2.id AS tpl,
             n.seq,
             n.agent_id AS aid,
             COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.version')) AS UNSIGNED), 0) AS ver
        FROM generic_templates g2,
             JSON_TABLE(g2.payload, '$.Workflow.nodes[*]'
               COLUMNS(seq       FOR ORDINALITY,
                       agent_id  VARCHAR(128) PATH '$.agentId')) n
        LEFT JOIN agents a ON a.id = n.agent_id COLLATE utf8mb4_unicode_ci
       WHERE n.agent_id IS NOT NULL AND n.agent_id <> ''
    ) x
   GROUP BY x.tpl
) r ON r.tpl = g.id
SET g.payload = JSON_SET(g.payload, '$.AgentRefs', r.refs);

-- ============================================================
-- 3) 删除已无引用的 18 条冗余角色
--    仍被任何模板节点引用的不会被删除（NOT EXISTS 兜底）
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_drop_agents;
CREATE TEMPORARY TABLE tmp_drop_agents (
  id VARCHAR(64) NOT NULL,
  PRIMARY KEY (id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT INTO tmp_drop_agents (id) VALUES
  ('generic-frontend-delivery-clarify'),
  ('generic-frontend-delivery-design'),
  ('generic-frontend-delivery-implement'),
  ('generic-frontend-delivery-review'),
  ('generic-frontend-delivery-test'),
  ('generic-frontend-delivery-deliver'),
  ('generic-frontend-delivery-mr'),
  ('generic-product-delivery-clarify'),
  ('generic-product-delivery-design'),
  ('generic-product-delivery-review'),
  ('generic-product-delivery-deliver'),
  ('issue-fix-production-clarify'),
  ('issue-fix-production-design'),
  ('issue-fix-production-implement'),
  ('issue-fix-production-review'),
  ('issue-fix-production-test'),
  ('issue-fix-production-deliver'),
  ('issue-fix-production-mr');

DELETE a FROM agents a
  JOIN tmp_drop_agents d ON d.id = a.id
 WHERE NOT EXISTS (
   SELECT 1
     FROM generic_templates g,
          JSON_TABLE(g.payload, '$.Workflow.nodes[*]'
            COLUMNS(agent_id VARCHAR(128) PATH '$.agentId')) n
    WHERE n.agent_id COLLATE utf8mb4_unicode_ci = a.id
 );

SELECT 'DELETE' AS stage, 'agents' AS kind, ROW_COUNT() AS deleted;

COMMIT;

-- ============================================================
-- 4) 核对
-- ============================================================
-- 4.1 每个模板引用的角色数与 Workflow.id 是否完好
SELECT g.id AS template_id,
       JSON_UNQUOTE(JSON_EXTRACT(g.payload, '$.Workflow.id')) AS wf_id,
       JSON_LENGTH(JSON_EXTRACT(g.payload, '$.AgentRefs'))    AS agent_refs
  FROM generic_templates g
 ORDER BY template_id;

-- 4.2 不应再有残留的前缀（有输出说明改绑没做全）
SELECT 'LEFTOVER' AS stage, g.id AS template_id, n.agent_id
  FROM generic_templates g,
       JSON_TABLE(g.payload, '$.Workflow.nodes[*]'
         COLUMNS(agent_id VARCHAR(128) PATH '$.agentId')) n
 WHERE n.agent_id LIKE 'generic-frontend-delivery-%'
    OR n.agent_id LIKE 'generic-product-delivery-%'
    OR n.agent_id LIKE 'issue-fix-production-%';

-- 4.3 引用完整性：不应有指向缺失角色或 version 未 pin 的 ref
SELECT 'BROKEN_REF' AS stage, g.id AS template_id, r.agent_id,
       r.version AS pinned,
       COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.version')) AS UNSIGNED), 0) AS current
  FROM generic_templates g,
       JSON_TABLE(g.payload, '$.AgentRefs[*]'
         COLUMNS(agent_id VARCHAR(128) PATH '$.id',
                 version  INT          PATH '$.version')) r
  LEFT JOIN agents a ON a.id = r.agent_id COLLATE utf8mb4_unicode_ci
 WHERE a.id IS NULL
    OR COALESCE(r.version, 0) <> COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.version')) AS UNSIGNED), 0);

-- 4.4 平台角色库当前每个名字剩几条（正常应全部为 1，Harness 变体与项目副本除外）
SELECT name, COUNT(*) AS cnt, GROUP_CONCAT(id ORDER BY id SEPARATOR ' | ') AS ids
  FROM agents
 WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '') = ''
 GROUP BY name
 ORDER BY cnt DESC, name;
