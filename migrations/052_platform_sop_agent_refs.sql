-- 052_platform_sop_agent_refs.sql
--
-- 把 generic_templates.payload 里内联的角色 / 规则 / 技能回填到平台资产库，
-- 生成 AgentRefs，并清掉内联的三个键。
--
-- 背景：payload 曾经内联 Agent/Rules/Skills 的完整副本，导致平台角色定义与
-- 平台 SOP 耦合（详见 docs/proposals/platform-sop-agent-refs.md）。改造后
-- 角色只在 agents 表维护，SOP 只记引用。
--
-- 可重复执行：
--   * 资产回填按 id 判重，已存在则跳过，不覆盖平台版；
--   * AgentRefs 由节点 agentId 重新推导，重复执行结果一致；
--   * 内联键被删除后 JSON_REMOVE 为幂等空操作。
--
-- 执行时机：必须在 048 → 049 → 050 → 051 全部执行完之后运行。
--   052 之后 048~051 即作废，重跑会把内联 Agents/Rules/Skills 写回 payload、
--   抹掉 AgentRefs，并把模板的 version/status/publishedRevision 重置为初始值。
--   已发布模板的角色版本固定另见 053。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   mysqldump ... generic_templates agents rules skills definition_revisions \
--     > backup_before_052.sql
--   mysql -h <host> -u <user> -p <database> < migrations/052_platform_sop_agent_refs.sql

SET NAMES utf8mb4;

-- ============================================================
-- 0) 冲突预检：内联角色 id 已存在于平台角色库，将跳过（以平台版为准）
-- ============================================================
SELECT 'CONFLICT' AS stage,
       g.id AS template_id,
       JSON_UNQUOTE(JSON_EXTRACT(a, '$.id'))                    AS agent_id,
       JSON_UNQUOTE(JSON_EXTRACT(a, '$.version'))               AS inline_ver,
       JSON_UNQUOTE(JSON_EXTRACT(p.payload, '$.version'))       AS platform_ver,
       JSON_UNQUOTE(JSON_EXTRACT(a, '$.rules'))                 AS inline_rules,
       JSON_UNQUOTE(JSON_EXTRACT(p.payload, '$.rules'))         AS platform_rules
  FROM generic_templates g,
       JSON_TABLE(g.payload, '$.Agents[*]' COLUMNS(a JSON PATH '$')) t
  JOIN agents p ON p.id = JSON_UNQUOTE(JSON_EXTRACT(a, '$.id')) COLLATE utf8mb4_unicode_ci
 ORDER BY template_id, agent_id;

-- ============================================================
-- 1) 内联角色去重后落到临时表
--    JSON_TABLE 产出列的排序规则是 utf8mb4_0900_ai_ci，与业务表不同，
--    临时表统一指定 utf8mb4_unicode_ci，避免后续 join 报 ERROR 1267。
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_inline_agents;
CREATE TEMPORARY TABLE tmp_inline_agents (
  agent_id      VARCHAR(64)  NOT NULL,
  agent_name    VARCHAR(255) NULL,
  agent_payload JSON         NULL,
  PRIMARY KEY (agent_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT INTO tmp_inline_agents (agent_id, agent_name, agent_payload)
SELECT agent_id,
       MAX(agent_name),
       MAX(agent_payload)
  FROM (
        SELECT JSON_UNQUOTE(JSON_EXTRACT(a, '$.id'))   AS agent_id,
               JSON_UNQUOTE(JSON_EXTRACT(a, '$.name')) AS agent_name,
               JSON_SET(a, '$.projectId', '', '$.shared', TRUE) AS agent_payload
          FROM generic_templates g,
               JSON_TABLE(g.payload, '$.Agents[*]' COLUMNS(a JSON PATH '$')) t
       ) x
 WHERE agent_id IS NOT NULL AND agent_id <> ''
 GROUP BY agent_id;

INSERT INTO agents (id, name, payload, updated_at)
SELECT t.agent_id, t.agent_name, t.agent_payload, UTC_TIMESTAMP(6)
  FROM tmp_inline_agents t
  LEFT JOIN agents x ON x.id = t.agent_id
 WHERE x.id IS NULL;

SELECT 'BACKFILL' AS stage, 'agents' AS kind, ROW_COUNT() AS inserted;

-- ============================================================
-- 2) 内联规则回填
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_inline_rules;
CREATE TEMPORARY TABLE tmp_inline_rules (
  rule_id      VARCHAR(64)  NOT NULL,
  rule_name    VARCHAR(255) NULL,
  rule_payload JSON         NULL,
  PRIMARY KEY (rule_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT INTO tmp_inline_rules (rule_id, rule_name, rule_payload)
SELECT rule_id, MAX(rule_name), MAX(rule_payload)
  FROM (
        SELECT JSON_UNQUOTE(JSON_EXTRACT(r, '$.id'))   AS rule_id,
               JSON_UNQUOTE(JSON_EXTRACT(r, '$.name')) AS rule_name,
               JSON_SET(r, '$.projectId', '', '$.shared', TRUE) AS rule_payload
          FROM generic_templates g,
               JSON_TABLE(g.payload, '$.Rules[*]' COLUMNS(r JSON PATH '$')) t
       ) x
 WHERE rule_id IS NOT NULL AND rule_id <> ''
 GROUP BY rule_id;

INSERT INTO rules (id, name, payload, updated_at)
SELECT t.rule_id, t.rule_name, t.rule_payload, UTC_TIMESTAMP(6)
  FROM tmp_inline_rules t
  LEFT JOIN rules x ON x.id = t.rule_id
 WHERE x.id IS NULL;

SELECT 'BACKFILL' AS stage, 'rules' AS kind, ROW_COUNT() AS inserted;

-- ============================================================
-- 3) 内联技能回填
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_inline_skills;
CREATE TEMPORARY TABLE tmp_inline_skills (
  skill_id      VARCHAR(64)  NOT NULL,
  skill_name    VARCHAR(255) NULL,
  skill_payload JSON         NULL,
  PRIMARY KEY (skill_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT INTO tmp_inline_skills (skill_id, skill_name, skill_payload)
SELECT skill_id, MAX(skill_name), MAX(skill_payload)
  FROM (
        SELECT JSON_UNQUOTE(JSON_EXTRACT(s, '$.id'))   AS skill_id,
               JSON_UNQUOTE(JSON_EXTRACT(s, '$.name')) AS skill_name,
               JSON_SET(s, '$.projectId', '', '$.shared', TRUE) AS skill_payload
          FROM generic_templates g,
               JSON_TABLE(g.payload, '$.Skills[*]' COLUMNS(s JSON PATH '$')) t
       ) x
 WHERE skill_id IS NOT NULL AND skill_id <> ''
 GROUP BY skill_id;

INSERT INTO skills (id, name, payload, updated_at)
SELECT t.skill_id, t.skill_name, t.skill_payload, UTC_TIMESTAMP(6)
  FROM tmp_inline_skills t
  LEFT JOIN skills x ON x.id = t.skill_id
 WHERE x.id IS NULL;

SELECT 'BACKFILL' AS stage, 'skills' AS kind, ROW_COUNT() AS inserted;

-- ============================================================
-- 4) 由节点 agentId 推导 AgentRefs
-- ============================================================
DROP TEMPORARY TABLE IF EXISTS tmp_tpl_refs;
CREATE TEMPORARY TABLE tmp_tpl_refs (
  template_id VARCHAR(64) NOT NULL,
  agent_id    VARCHAR(64) NOT NULL,
  PRIMARY KEY (template_id, agent_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT IGNORE INTO tmp_tpl_refs (template_id, agent_id)
SELECT g.id, n.agent_id
  FROM generic_templates g,
       JSON_TABLE(g.payload, '$.Workflow.nodes[*]'
         COLUMNS(agent_id VARCHAR(128) PATH '$.agentId',
                 node_type VARCHAR(16) PATH '$.type')) n
 WHERE n.node_type = 'agent' AND n.agent_id <> '';

DROP TEMPORARY TABLE IF EXISTS tmp_tpl_refs_json;
CREATE TEMPORARY TABLE tmp_tpl_refs_json (
  template_id VARCHAR(64) NOT NULL,
  refs        JSON        NULL,
  PRIMARY KEY (template_id)
) DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

INSERT INTO tmp_tpl_refs_json (template_id, refs)
SELECT template_id, JSON_ARRAYAGG(JSON_OBJECT('id', agent_id))
  FROM tmp_tpl_refs
 GROUP BY template_id;

UPDATE generic_templates g
  JOIN tmp_tpl_refs_json r ON r.template_id = g.id
   SET g.payload = JSON_SET(g.payload, '$.AgentRefs', r.refs);

-- ============================================================
-- 5) 清掉内联副本（definition_revisions 已提供角色版本快照）
-- ============================================================
UPDATE generic_templates
   SET payload = JSON_REMOVE(payload, '$.Agents', '$.Rules', '$.Skills');

-- ============================================================
-- 6) 核对：每个模板的引用数、内联键是否已清空
-- ============================================================
SELECT g.id                                   AS template_id,
       JSON_LENGTH(JSON_EXTRACT(g.payload, '$.AgentRefs'))                       AS agent_refs,
       JSON_CONTAINS_PATH(g.payload, 'one', '$.Agents')                          AS has_inline_agents,
       JSON_CONTAINS_PATH(g.payload, 'one', '$.Rules')                           AS has_inline_rules,
       JSON_CONTAINS_PATH(g.payload, 'one', '$.Skills')                          AS has_inline_skills
  FROM generic_templates g
 ORDER BY template_id;

-- 任何一行输出都意味着迁移后模板仍引用不存在的角色，需要先补角色再放流量
SELECT r.template_id, r.agent_id
  FROM tmp_tpl_refs r
  LEFT JOIN agents a ON a.id = r.agent_id
 WHERE a.id IS NULL;
