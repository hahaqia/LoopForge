-- 059_clarify_selfcheck_artifact_template.sql
--
-- 给需求定型 · Harness 角色补一条自检门禁：章节完整（动态读产物模板）。
--
-- 背景：平台会从 artifact_templates 自动派生一条「requirement.md 章节完整」
-- 门禁，但 agent 任务书里的「完成条件与门禁证据」只列角色 verification 里的
-- 门禁，所以 agent 看不到骨架要求，容易自认为 pass 后被平台驳回。本脚本把
-- 同一口径的自检命令放进角色 verification，让 agent 生成文档时就能对照。
--
-- 命令口径与 internal/domain/assets.go 的 ParseArtifactTemplateHeadings 一致：
-- 只取二级标题；optional 标记只作用于紧邻的下一节。模板改了无需改角色。
--
-- 幂等：已存在 id=requirement-template-headings 时不追加。
-- 回滚：从 agents.payload.verification 删除该 id 的门禁即可。
--
-- 注意：payload 是 JSON 列，客户端连接字符集必须是 utf8mb4，否则中文会
-- 二次编码成乱码。执行前请确认连接使用 --default-character-set=utf8mb4。
-- 下面的中文一律用十六进制 UNHEX + CONVERT 写入，不依赖连接字符集。

SET @name = CONVERT(UNHEX('E7ABA0E88A82E5AE8CE695B4EFBC9AE68C89E99C80E6B182E69687E6A1A3E9AAA8E69EB6E887AAE6A380') USING utf8mb4);
SET @cmd = CONVERT(UNHEX('74656d706c6174653d222e6167656e74666c6f772f74656d706c617465732f726571756972656d656e742e6d64220a5b202d6620222474656d706c61746522205d207c7c207b206563686f2022e7bcbae5b091e6a8a1e69dbfe69687e4bbb63a202474656d706c617465223b206578697420313b207d0a6d697373696e673d22220a666f72206820696e20242861776b20272f5e2323202f7b743d7375627374722824302c34293b20696628216f70742026262074213d222229207072696e7420743b206f70743d303b206e6578747d20696e6465782824302c223c212d2d206f7074696f6e616c202d2d3e22297b6f70743d313b206e6578747d204e463d3d307b6e6578747d207b6f70743d307d2720222474656d706c61746522293b20646f0a202067726570202d7146202d2d202223232024682220726571756972656d656e742e6d64207c7c206d697373696e673d22246d697373696e67202468220a646f6e650a5b202d7a2022246d697373696e6722205d207c7c207b206563686f2022e7bcbae5b091e5bf85e99c80e7aba0e88a823a246d697373696e67223b206578697420313b207d') USING utf8mb4);

UPDATE agents
   SET payload = JSON_ARRAY_APPEND(payload, '$.verification', JSON_OBJECT(
         'id', 'requirement-template-headings',
         'mode', 'command',
         'name', @name,
         'stage', 'after_execution',
         'commands', JSON_ARRAY(@cmd),
         'required', TRUE,
         'onFailure', 'loop',
         'executionScope', 'run'
       )),
       updated_at = UTC_TIMESTAMP(6)
 WHERE id IN ('generic-harness-delivery-clarify', 'generic-harness-delivery-clarify-ai-devop-agent')
   AND JSON_SEARCH(JSON_EXTRACT(payload, '$.verification'), 'one', 'requirement-template-headings') IS NULL;
