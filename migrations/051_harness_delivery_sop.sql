-- ⚠ 已被 052 取代，勿重跑。
-- 本段用 INSERT ... ON DUPLICATE KEY UPDATE 整份覆盖 payload，是这四支里
-- 唯一写 generic_templates 的地方。052 之后重跑会写回内联 {Agents, Rules,
-- Skills}、抹掉 AgentRefs，并把 version/status/publishedRevision 重置为初始值。
-- 正确顺序：seed/001 → 048 → 049 → 050 → 051 → 052 → 053。
-- 误跑后：重跑 052 恢复引用结构，再重跑 053 重新 pin 角色版本；
-- version/status 需按实际发布记录人工校正。
--
-- Harness 融合交付 SOP · 第 4 段：9 节点 8 边 + 组装写入
-- 依赖 048(@rules @skill_readiness)、049(@a_clarify @a_design @a_ready)、050(@agents)
SET NAMES utf8mb4;

SET @nodes := JSON_ARRAY(
  JSON_OBJECT('id','clarify','name','需求定型','type','agent','agentId','generic-harness-delivery-clarify','maxAttempts',2,'position',JSON_OBJECT('x',100,'y',160)),
  JSON_OBJECT('id','design','name','方案设计','type','agent','agentId','generic-harness-delivery-design','maxAttempts',2,'rejectTo','clarify','position',JSON_OBJECT('x',320,'y',160)),
  JSON_OBJECT('id','readiness','name','就绪评审','type','agent','agentId','generic-harness-delivery-readiness','maxAttempts',1,'rejectTo','design','position',JSON_OBJECT('x',540,'y',160)),
  JSON_OBJECT('id','implement','name','开发实现','type','agent','agentId','generic-harness-delivery-implement','maxAttempts',3,'rejectTo','readiness','position',JSON_OBJECT('x',760,'y',160)),
  JSON_OBJECT('id','review','name','独立评审','type','agent','agentId','generic-harness-delivery-review','maxAttempts',2,'rejectTo','implement','position',JSON_OBJECT('x',980,'y',160)),
  JSON_OBJECT('id','test','name','测试验证','type','agent','agentId','generic-harness-delivery-test','maxAttempts',2,'rejectTo','implement','position',JSON_OBJECT('x',1200,'y',160)),
  JSON_OBJECT('id','accept','name','人工验收','type','approval','maxAttempts',1,'rejectTo','test','position',JSON_OBJECT('x',1420,'y',160)),
  JSON_OBJECT('id','mr','name','发起 MR','type','agent','agentId','generic-backend-delivery-mr','maxAttempts',2,'position',JSON_OBJECT('x',1640,'y',160)),
  JSON_OBJECT('id','deliver','name','交付汇总','type','agent','agentId','generic-backend-delivery-deliver','maxAttempts',1,'position',JSON_OBJECT('x',1860,'y',160))
);

SET @edges := JSON_ARRAY(
  JSON_OBJECT('id','e1','source','clarify','target','design','when','success'),
  JSON_OBJECT('id','e2','source','design','target','readiness','when','success'),
  JSON_OBJECT('id','e3','source','readiness','target','implement','when','success'),
  JSON_OBJECT('id','e4','source','implement','target','review','when','success'),
  JSON_OBJECT('id','e5','source','review','target','test','when','success'),
  JSON_OBJECT('id','e6','source','test','target','accept','when','success'),
  JSON_OBJECT('id','e7','source','accept','target','mr','when','success'),
  JSON_OBJECT('id','e8','source','mr','target','deliver','when','success')
);

SET @wf := JSON_OBJECT(
  'id','generic-harness-delivery',
  'name','Harness 融合交付 SOP',
  'version',1,'revision',0,'publishedRevision',0,'status','published',
  'generic',TRUE,'projectId','','shared',TRUE,
  'owner','智研工坊',
  'description','需求定型 → 方案设计 → 就绪评审 → 开发实现 → 独立评审 → 测试验证 → 人工验收 → MR → 交付。就绪评审不过则打回方案或需求。',
  'sandboxProfileId','generic-docker',
  'metricCategory','需求开发','sopLane','后端',
  'tags',JSON_ARRAY('public','harness'),
  'updatedAt','2026-11-24T00:00:00Z',
  'nodes',CAST(@nodes AS JSON),'edges',CAST(@edges AS JSON)
);

-- 变量缺失（分段执行丢变量）时不写入半成品
INSERT INTO `generic_templates` (`id`, `name`, `payload`, `updated_at`)
SELECT 'generic-harness-delivery', 'Harness 融合交付 SOP',
       JSON_OBJECT('Workflow', CAST(@wf AS JSON),
                   'Agents', CAST(@agents AS JSON),
                   'Rules', CAST(@rules AS JSON),
                   'Skills', JSON_ARRAY(CAST(@skill_readiness AS JSON))),
       UTC_TIMESTAMP()
  FROM DUAL
 WHERE @agents IS NOT NULL AND @rules IS NOT NULL AND @skill_readiness IS NOT NULL
ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `payload` = VALUES(`payload`);

SELECT IF(@agents IS NULL OR @rules IS NULL OR @skill_readiness IS NULL,
          'ERROR: 变量丢失，请在同一会话内依次 source 048/049/050 后重跑 051',
          'OK: 变量齐全') AS var_check;

-- ============================================================
-- 核对：必须看到 nodes=9 edges=8 agents=8 rules=4 skills=1
-- ============================================================
SELECT `id`,
       JSON_LENGTH(JSON_EXTRACT(`payload`,'$.Workflow.nodes'))  AS nodes,
       JSON_LENGTH(JSON_EXTRACT(`payload`,'$.Workflow.edges'))  AS edges,
       JSON_LENGTH(JSON_EXTRACT(`payload`,'$.Agents'))          AS agents,
       JSON_LENGTH(JSON_EXTRACT(`payload`,'$.Rules'))           AS rules,
       JSON_LENGTH(JSON_EXTRACT(`payload`,'$.Skills'))          AS skills
  FROM `generic_templates` WHERE `id` = 'generic-harness-delivery';

SELECT JSON_UNQUOTE(JSON_EXTRACT(`payload`, CONCAT('$.Agents[', n.idx - 1, '].id')))        AS agent_id,
       JSON_LENGTH(JSON_EXTRACT(`payload`, CONCAT('$.Agents[', n.idx - 1, '].verification'))) AS gates,
       JSON_LENGTH(JSON_EXTRACT(`payload`, CONCAT('$.Agents[', n.idx - 1, '].hooks')))         AS hooks,
       JSON_UNQUOTE(JSON_EXTRACT(`payload`, CONCAT('$.Agents[', n.idx - 1, '].skills')))       AS skills
  FROM `generic_templates` g
  JOIN JSON_TABLE(g.`payload`, '$.Agents[*]' COLUMNS(idx FOR ORDINALITY)) n
 WHERE g.`id` = 'generic-harness-delivery';
