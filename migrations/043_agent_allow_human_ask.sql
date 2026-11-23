-- 只让“需求定型 / 方案设计”两个角色在节点执行中途向人提问。
--
-- 机制：角色开 allowHumanAsk 后，引擎才会给 gate MCP 注入 AGENTFLOW_ASK_PATH，
-- Agent 才能调用 ask_human；其余角色连工具都看不到，避免实现/测试节点用提问
-- 代替判断。单个节点最多 3 次（engine.maxAskQuestions）。
--
-- 手动执行：mysql < migrations/043_agent_allow_human_ask.sql

-- 1) agents 表：项目 SOP 解析角色时读这里。
UPDATE agents
SET payload = JSON_SET(payload, '$.allowHumanAsk', TRUE)
WHERE id LIKE '%-clarify%' OR id LIKE '%-design%';

-- 2) generic_templates：通用 SOP 的角色来自模板打包的 Agents，不走 agents 表。
--    注意 JSON_ARRAYAGG 的结果是字符串，必须 CAST(... AS JSON)，否则会写成
--    双重编码的字符串数组，引擎解析角色时会全部失败。
SET @agents := (
  SELECT JSON_EXTRACT(payload, '$.Agents')
  FROM generic_templates
  WHERE id = 'generic-backend-delivery'
);

SET @patched := (
  SELECT JSON_ARRAYAGG(
    CASE
      WHEN JSON_UNQUOTE(JSON_EXTRACT(item.a, '$.id')) IN (
        'generic-backend-delivery-clarify',
        'generic-backend-delivery-design'
      )
      THEN JSON_SET(item.a, '$.allowHumanAsk', TRUE)
      ELSE item.a
    END
  )
  FROM JSON_TABLE(@agents, '$[*]' COLUMNS (a JSON PATH '$')) AS item
);

UPDATE generic_templates
SET payload = JSON_SET(payload, '$.Agents', CAST(@patched AS JSON))
WHERE id = 'generic-backend-delivery';
