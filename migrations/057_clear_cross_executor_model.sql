-- 057_clear_cross_executor_model.sql
--
-- 清掉「Claude Code 执行器 + DeepSeek 模型」的跨执行器模型绑定，让这些角色
-- 回落到执行器自身的默认模型。
--
-- 背景（脏数据成因）：
--   deepseek-v4.1-flash / deepseek-v4.1-flash-1017 是 CodeBuddy 的赞助模型
--   （internal/repo/codebuddy_sponsor.go、internal/httpapi/assistant_effort.go
--   的模型白名单）。但库里有 5 条角色的 executorId 是 claude（Claude Code
--   CLI，Kind=claude-code），model 却指向这个 DeepSeek 模型：
--
--     generic-backend-delivery-clarify                (平台)       claude
--     generic-backend-delivery-clarify-ai-devop-agent (项目副本)   claude
--     generic-harness-delivery-design                 (平台)       claude
--     generic-harness-delivery-implement              (平台)       claude
--     generic-harness-delivery-readiness              (平台)       claude
--
--   前两条是「后端交付 SOP」复制链：平台模板带坏组合，复制到项目时被继承。
--   后三条是「Harness 融合交付 SOP」的平台模板；它的项目副本在 2026-11-25
--   09:38 复制时 executor 已被改成 codebuddy，所以只有平台侧还留着坏值。
--
--   后果：resolveNodeExecutor 会用角色 model 直接覆盖执行器 model
--   （internal/engine/node_execute.go:217），runtime/provider.go:83 再把它
--   拼成 `--model deepseek-v4.1-flash-1017` 交给 Claude Code CLI，该 CLI
--   不认这个模型号，节点会在启动阶段失败。
--
-- 做法：
--   删除这些角色的 payload.model 键，使 resolveNodeExecutor 不再覆盖，
--   执行器回落到 Claude Code 自己的默认模型。executorId 保持不变——换执行器
--   属于团队选型，不由本脚本代劳。
--
--   平台模板一并清理：只在项目副本上改，下次从平台复制仍会带回坏值。
--
-- 不改 version：这些平台角色被 generic_templates.AgentRefs pin 住，复制时
-- pinAgentVersion 命中「version 相同 → 取当前 payload」，bump version 反而
-- 会让它回退到含坏 model 的历史快照（与 055 同一坑）。version 保持不动。
--
-- 可重复执行：条件要求 payload.model 仍以 deepseek- 开头，第二次执行已无
-- 匹配行。清理后即便有人再给 claude 执行器手填 DeepSeek 模型，重跑本脚本
-- 仍会再次清掉——这正是不匹配组合应得的处理。
--
-- 执行时机：独立修复，无前置依赖；与 052–056 无冲突。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   mysqldump -h <host> -u <user> -p <database> agents > backup_before_057.sql
--   mysql -h <host> -u <user> -p <database> < migrations/057_clear_cross_executor_model.sql
--
-- 回滚：用上面的备份还原 agents 表。若只想恢复某一条，把备份里该行的
--       payload.model 用 JSON_SET 写回即可。

SET NAMES utf8mb4;

-- ============================================================
-- 0) 预检：将被清理的行
-- ============================================================
SELECT 'TARGET' AS stage,
       COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '(platform)') AS project_id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.name')) AS name,
       id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.executorId')) AS executor_id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.model')) AS model
  FROM agents
 WHERE JSON_UNQUOTE(JSON_EXTRACT(payload, '$.executorId')) = 'claude'
   AND JSON_UNQUOTE(JSON_EXTRACT(payload, '$.model')) LIKE 'deepseek-%'
 ORDER BY project_id, name, id;

START TRANSACTION;

-- ============================================================
-- 1) 删除跨执行器的 model 绑定
-- ============================================================
UPDATE agents
   SET payload = JSON_REMOVE(payload, '$.model'),
       updated_at = UTC_TIMESTAMP()
 WHERE JSON_UNQUOTE(JSON_EXTRACT(payload, '$.executorId')) = 'claude'
   AND JSON_UNQUOTE(JSON_EXTRACT(payload, '$.model')) LIKE 'deepseek-%';

SELECT 'STEP1' AS stage, 'cross-executor model cleared' AS note, ROW_COUNT() AS updated;

COMMIT;

-- ============================================================
-- 2) 核对
-- ============================================================
-- 2.1 不应再有 claude 执行器绑定 deepseek 模型（有输出说明没清全）
SELECT 'LEFTOVER' AS stage, id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.executorId')) AS executor_id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.model')) AS model
  FROM agents
 WHERE JSON_UNQUOTE(JSON_EXTRACT(payload, '$.executorId')) = 'claude'
   AND JSON_UNQUOTE(JSON_EXTRACT(payload, '$.model')) LIKE 'deepseek-%';

-- 2.2 受影响角色的最终执行配置（model 应为 NULL，即继承执行器默认）
SELECT 'AFTER' AS stage,
       COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '(platform)') AS project_id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.name')) AS name,
       id,
       JSON_EXTRACT(payload, '$.executorId') AS executor_id,
       JSON_EXTRACT(payload, '$.model') AS model,
       JSON_EXTRACT(payload, '$.version') AS version
  FROM agents
 WHERE id IN (
   'generic-backend-delivery-clarify',
   'generic-backend-delivery-clarify-ai-devop-agent',
   'generic-harness-delivery-design',
   'generic-harness-delivery-implement',
   'generic-harness-delivery-readiness')
 ORDER BY id;

-- 2.3 全库 model 与 executor 的配对总览（人工扫一眼是否还有别的错配）
SELECT 'PAIRS' AS stage,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.executorId')) AS executor_id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.model')) AS model,
       COUNT(*) AS n
  FROM agents
 WHERE JSON_EXTRACT(payload, '$.model') IS NOT NULL
 GROUP BY executor_id, model
 ORDER BY executor_id, model;
