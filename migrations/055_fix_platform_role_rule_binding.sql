-- 055_fix_platform_role_rule_binding.sql
--
-- 修复「通用后端交付 SOP」从平台复制到项目时报错：
--   角色 "方案设计" 引用的规则 "public-engineering-welcome" 不在平台资产库中
--
-- 背景（脏数据成因）：
--   通用后端交付的 6 个平台角色（clarify/design/implement/review/test/deliver/mr
--   中的 6 条，clarify 除外）在 payload.rules 里引用了 public-engineering-welcome。
--   这条规则属于 welcome 项目（projectId=welcome, shared=false），不是平台资产。
--   「从平台 SOP 复制」走 collectTemplateAssets，要求角色绑定的每条规则都必须
--   projectId 为空，于是整条复制链路被这个引用挡住。
--
--   内容差异：public-engineering-welcome 的 content 是平台 public-engineering
--   后面追加了一句「仓库绑定是可选的…」。角色 prompt 里没有任何等价表述，
--   所以直接改绑会丢掉这条约束，本脚本先把这句并回平台规则，再改绑。
--
-- 做法：
--   1. 平台规则 public-engineering 追加「仓库绑定可选」说明（仅当内容仍是
--      旧版时生效，运维手改过的内容不会被覆盖）。
--   2. 平台角色 payload.rules 里的 "public-engineering-welcome" 换成
--      "public-engineering"。
--
-- 不改 version：generic_templates.AgentRefs 已 pin 到这些角色的当前 version，
-- bump version 会让 pinAgentVersion 取到历史快照（clarify v1 快照里仍是坏引用），
-- 复制反而继续失败。保持 version 不变，pin 命中当前 payload，修复才生效。
--
-- 可重复执行：第 1 步带旧内容精确匹配，第二次无命中；第 2 步前缀已替换，无匹配。
--
-- 执行时机：独立修复，无前置依赖；与 052/053/054 无冲突。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   mysqldump -h <host> -u <user> -p <database> agents rules > backup_before_055.sql
--   mysql -h <host> -u <user> -p <database> < migrations/055_fix_platform_role_rule_binding.sql
--
-- 回滚：用上面的备份还原 agents / rules 两张表即可。

SET NAMES utf8mb4;
SET SESSION group_concat_max_len = 1000000;

-- ============================================================
-- 0) 预检：平台角色引用了哪些非平台资产
-- ============================================================
SELECT 'BROKEN' AS stage, a.id AS agent_id, a.name, jt.rule_id
  FROM agents a,
       JSON_TABLE(a.payload, '$.rules[*]' COLUMNS(rule_id VARCHAR(128) PATH '$')) jt
 WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.projectId')), '') = ''
   AND NOT EXISTS (
     SELECT 1 FROM rules r
      WHERE r.id = jt.rule_id COLLATE utf8mb4_unicode_ci
        AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(r.payload, '$.projectId')), '') = ''
   )
 ORDER BY a.id;

SELECT 'BEFORE' AS stage, id, name, CHARACTER_LENGTH(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.content'))) AS content_len
  FROM rules
 WHERE id IN ('public-engineering', 'public-engineering-welcome');

START TRANSACTION;

-- ============================================================
-- 1) 把「仓库绑定可选」说明并回平台规则
-- ============================================================
UPDATE rules
   SET payload = JSON_SET(payload, '$.content',
         CONCAT(
           JSON_UNQUOTE(JSON_EXTRACT(payload, '$.content')),
           '仓库绑定是可选的：未绑定时在任务工作区创建新项目并交付源码、报告；已有系统的修改或缺陷修复必须取得相关代码，缺少时明确阻塞并请求补充。没有目标仓库和凭据时不执行推送或创建 PR。'
         )),
       updated_at = UTC_TIMESTAMP()
 WHERE id = 'public-engineering'
   AND JSON_UNQUOTE(JSON_EXTRACT(payload, '$.content')) =
       '先阅读仓库约束并明确范围；只修改任务所需文件。不得泄露凭据，不得伪造测试或交付证据。使用项目现有构建与测试命令，报告真实结果与限制。发布 PR 前检查 diff；未经任务授权不得合并主分支。';

SELECT 'STEP1' AS stage, 'public-engineering content merged' AS note, ROW_COUNT() AS updated;

-- ============================================================
-- 2) 平台角色改绑到平台规则
-- ============================================================
UPDATE agents
   SET payload = JSON_SET(payload, '$.rules',
         CAST(REPLACE(CAST(JSON_EXTRACT(payload, '$.rules') AS CHAR),
                      '"public-engineering-welcome"', '"public-engineering"') AS JSON)),
       updated_at = UTC_TIMESTAMP()
 WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '') = ''
   AND CAST(JSON_EXTRACT(payload, '$.rules') AS CHAR) LIKE '%public-engineering-welcome%';

SELECT 'STEP2' AS stage, 'platform agents rebound' AS note, ROW_COUNT() AS updated;

COMMIT;

-- ============================================================
-- 3) 核对
-- ============================================================
-- 3.1 平台角色不应再有非平台规则引用（有输出说明没修全）
SELECT 'LEFTOVER' AS stage, a.id AS agent_id, a.name, jt.rule_id
  FROM agents a,
       JSON_TABLE(a.payload, '$.rules[*]' COLUMNS(rule_id VARCHAR(128) PATH '$')) jt
 WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(a.payload, '$.projectId')), '') = ''
   AND NOT EXISTS (
     SELECT 1 FROM rules r
      WHERE r.id = jt.rule_id COLLATE utf8mb4_unicode_ci
        AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(r.payload, '$.projectId')), '') = ''
   );

-- 3.2 平台规则内容与项目副本应对齐
SELECT 'CONTENT' AS stage, id,
       CHARACTER_LENGTH(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.content'))) AS content_len,
       MD5(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.content'))) AS content_md5
  FROM rules
 WHERE id LIKE 'public-engineering%'
 ORDER BY id;

-- 3.3 6 条通用后端交付平台的 rules 现状
SELECT 'ROLES' AS stage, id, name, JSON_EXTRACT(payload, '$.rules') AS rules
  FROM agents
 WHERE id LIKE 'generic-backend-delivery-%'
   AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '') = ''
 ORDER BY id;
