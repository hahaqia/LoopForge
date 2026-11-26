-- 060_all_sop_agents_template_selfcheck.sql
--
-- 给所有绑定产物模板的 Agent 角色补一条自检门禁：按产物模板核对章节完整。
-- 这是 059 的通用版：059 只覆盖需求定型 Harness 的两个角色，本脚本覆盖
-- 所有 artifactOutputs[0].templateId 非空的角色，包括 generic-backend 和
-- generic-harness 的 clarify/design/implement/readiness/review/test。
--
-- 背景同 059：平台会从模板自动派生结构门禁，但 agent 任务书只列角色
-- verification 里的门禁。角色缺少这条时，agent 会自认为 pass 后被平台驳回。
--
-- 命令口径与 internal/domain/assets.go 的 ParseArtifactTemplateHeadings 一致：
-- 只取二级标题；optional 标记只作用于紧邻的下一节。产物路径与模板 id 从
-- 角色自己的 artifactOutputs[0] 读取，模板改了无需改角色。
--
-- 幂等：已存在 id=artifact-template-headings 的角色不追加。
-- 059 加的 requirement-template-headings 视为等价，存在时跳过（避免重复检查）。
-- 注意：中文一律用十六进制 UNHEX + CONVERT 写入，不依赖连接字符集；
--       执行时仍建议 --default-character-set=utf8mb4 以便输出可读。

SET @gate_id = 'artifact-template-headings';
SET @name = CONVERT(UNHEX('e7aba0e88a82e5ae8ce695b4efbc9ae68c89e4baa7e789a9e6a8a1e69dbfe9aaa8e69eb6e887aae6a380') USING utf8mb4);
SET @missing_tpl = CONVERT(UNHEX('e7bcbae5b091e6a8a1e69dbfe69687e4bbb63a20') USING utf8mb4);
SET @missing_sec = CONVERT(UNHEX('e7bcbae5b091e5bf85e99c80e7aba0e88a823a20') USING utf8mb4);

UPDATE agents
   SET payload = JSON_ARRAY_APPEND(payload, '$.verification', JSON_OBJECT(
         'id', @gate_id,
         'mode', 'command',
         'name', @name,
         'stage', 'after_execution',
         'commands', JSON_ARRAY(CONCAT(
           'artifact="', JSON_UNQUOTE(JSON_EXTRACT(payload, '$.artifactOutputs[0].path')), '"\n',
           'template=".agentflow/templates/', JSON_UNQUOTE(JSON_EXTRACT(payload, '$.artifactOutputs[0].templateId')), '.md"\n',
           '[ -f "$template" ] || { echo "', @missing_tpl, '$template"; exit 1; }\n',
           'missing=""\n',
           'for h in $(awk \'/^## /{t=substr($0,4); if(!opt && t!="") print t; opt=0; next} index($0,"<!-- optional -->"){opt=1; next} NF==0{next} {opt=0}\' "$template"); do\n',
           '  grep -qF -- "## $h" "$artifact" || missing="$missing $h"\n',
           'done\n',
           '[ -z "$missing" ] || { echo "', @missing_sec, '$missing"; exit 1; }'
         )),
         'required', TRUE,
         'onFailure', 'loop',
         'executionScope', 'run'
       )),
       updated_at = UTC_TIMESTAMP(6)
 WHERE JSON_UNQUOTE(JSON_EXTRACT(payload, '$.artifactOutputs[0].templateId')) <> ''
   AND JSON_SEARCH(JSON_EXTRACT(payload, '$.verification'), 'one', @gate_id) IS NULL
   AND JSON_SEARCH(JSON_EXTRACT(payload, '$.verification'), 'one', 'requirement-template-headings') IS NULL;
