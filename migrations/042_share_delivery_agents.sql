-- 把通用后端交付 SOP 的 7 个角色提升为共享角色：
-- 之前它们挂在某个具体项目下（projectId 非空、shared 为空），其他项目在
-- 「角色定义」里看不到，只能各自重建。提升为共享后，各项目可以「复制到本项目」
-- 再改，SOP 节点绑定的项目后缀角色（*-ai-devop-agent）不受影响。
-- 手动执行：mysql < migrations/042_share_delivery_agents.sql

UPDATE agents
SET payload = JSON_SET(payload, '$.projectId', '', '$.shared', TRUE)
WHERE id IN (
  'generic-backend-delivery-clarify',
  'generic-backend-delivery-design',
  'generic-backend-delivery-implement',
  'generic-backend-delivery-review',
  'generic-backend-delivery-test',
  'generic-backend-delivery-deliver',
  'generic-backend-delivery-mr'
);
