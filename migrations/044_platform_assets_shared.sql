-- 平台资产（projectId 为空）的运行时可见性依赖 shared=true：
-- 引擎用 `ProjectID != projectID && !Shared` 判断是否跳过，shared 为 false 的平台资产
-- 只有自己项目可见，等于"建好了但别的项目用不上"。
-- 本次统一补齐规则、技能、产物模板三类平台资产的 shared 标记。
-- 桌面「项目资产共享」语义不受影响：带 projectId 的行不改。
-- 手动执行：mysql < migrations/044_platform_assets_shared.sql

UPDATE rules
SET payload = JSON_SET(payload, '$.shared', TRUE)
WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '') = ''
  AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.shared')), 'false') <> 'true';

UPDATE skills
SET payload = JSON_SET(payload, '$.shared', TRUE)
WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '') = ''
  AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.shared')), 'false') <> 'true';

UPDATE artifact_templates
SET payload = JSON_SET(payload, '$.shared', TRUE)
WHERE COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.projectId')), '') = ''
  AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.shared')), 'false') <> 'true';
