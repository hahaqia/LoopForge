-- 061_enable_human_ask_for_spec_roles.sql
--
-- 给需求定型、方案设计角色开启中途提问（ask_human），并让角色 prompt 明确
-- 要求：遇到必须由人决定的歧义先提问，不要用默认假设代替用户决策。
--
-- 背景：平台默认关闭 ask_human（避免实现/测试节点用提问代替判断），但需求
-- 定型/方案设计在原始需求只有一句话时必须能问人。本次 run 的 agent 因为
-- 没有该工具，只能自己列 Q1~Q6 默认假设继续，导致产物偏离用户真实意图。
--
-- 影响角色（通用版 + 项目覆盖版）：
--   generic-harness-delivery-clarify[-ai-devop-agent]
--   generic-harness-delivery-design[-ai-devop-agent]
--
-- 幂等：按 id + 旧 prompt 片段精确替换，重跑无副作用。
-- 回滚：删除 allowHumanAsk 字段；把 prompt 里的新条款换回旧条款。
-- 中文一律 hex UNHEX + CONVERT 写入，不依赖连接字符集。

SET @clarify_old = CONVERT(UNHEX('352e20e69c89e6ada7e4b989e697b6e58897e587bae5be85e7a1aee8aea4e997aee9a298efbc8ce58699e6988ee9bb98e8aea4e58187e8aebeefbc8ce4b88de8a681e887aae5b7b1e68b8de69dbfe4b89ae58aa1e586b3e7ad96e38082') USING utf8mb4);
SET @clarify_new = CONVERT(UNHEX('352e20e98187e588b0e5bf85e9a1bbe794b1e4babae586b3e5ae9ae79a84e6ada7e4b989efbc88e79baee6a087e794a8e688b7e38081e9a1b5e99da2e585a5e58fa3e38081e9aa8ce694b6e58fa3e5be84e38081e4b89ae58aa1e58f96e8888de38081e88c83e59bb4e8beb9e7958cefbc89e697b6efbc8ce58588e8b083e794a8204d435020e5b7a5e585b72061736b5f68756d616e20e68f90e4baa4e585b7e4bd93e997aee9a298efbc88e5b8a6e98089e9a1b9e6b8b2e69f93e4b8bae98089e68ba9e9a298efbc89efbc8ce69a82e5819ce7ad89e794a8e688b7e59b9ee7ad94e5908ee5868de7bba7e7bbadefbc8ce4b88de5be97e887aae5b7b1e68b8de69dbfe68896e794a8e9bb98e8aea4e58187e8aebee4bba3e69bbfe794a8e688b7e586b3e7ad96efbc9be58fafe4bba5e887aae8a18ce69fa5e8af81e79a84e4ba8be5ae9ee4b88de8a681e997aee38082') USING utf8mb4);
SET @design_old = CONVERT(UNHEX('352e20e6988ee7a1aee9aa8ce8af81e696b9e5bc8fefbc9ae6808ee4b988e8af81e6988ee696b9e6a188e5ae9ee78eb0e5908ee99c80e6b182e68890e7ab8be38082') USING utf8mb4);
SET @design_new = CONVERT(UNHEX('352e20e6988ee7a1aee9aa8ce8af81e696b9e5bc8fefbc9ae6808ee4b988e8af81e6988ee696b9e6a188e5ae9ee78eb0e5908ee99c80e6b182e68890e7ab8be380820a362e20e98187e588b0e5bf85e9a1bbe794b1e4babae586b3e5ae9ae79a84e68a80e69cafe58f96e8888defbc88e696b9e6a188e98089e59e8be38081e585bce5aeb9e680a7e8beb9e7958ce38081e695b0e68daee8bf81e7a7bbe7ad96e795a5efbc89e697b6efbc8ce58588e8b083e794a8204d435020e5b7a5e585b72061736b5f68756d616e20e68f90e4baa4e585b7e4bd93e997aee9a298efbc8ce69a82e5819ce7ad89e794a8e688b7e59b9ee7ad94e5908ee5868de7bba7e7bbadefbc8ce4b88de5be97e887aae8a18ce58187e8aebee38082') USING utf8mb4);

UPDATE agents
   SET payload = JSON_SET(
         payload,
         '$.allowHumanAsk', TRUE,
         '$.prompt', REPLACE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.prompt')), @clarify_old, @clarify_new)
       ),
       updated_at = UTC_TIMESTAMP(6)
 WHERE id IN ('generic-harness-delivery-clarify', 'generic-harness-delivery-clarify-ai-devop-agent')
   AND JSON_EXTRACT(payload, '$.prompt') LIKE CONCAT('%', @clarify_old, '%');

UPDATE agents
   SET payload = JSON_SET(
         payload,
         '$.allowHumanAsk', TRUE,
         '$.prompt', REPLACE(JSON_UNQUOTE(JSON_EXTRACT(payload, '$.prompt')), @design_old, @design_new)
       ),
       updated_at = UTC_TIMESTAMP(6)
 WHERE id IN ('generic-harness-delivery-design', 'generic-harness-delivery-design-ai-devop-agent')
   AND JSON_EXTRACT(payload, '$.prompt') LIKE CONCAT('%', @design_old, '%')
   AND JSON_EXTRACT(payload, '$.prompt') NOT LIKE CONCAT('%', @design_new, '%');
