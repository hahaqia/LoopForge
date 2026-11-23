-- 产物模板：把交付物的章节骨架变成可复用的目录资产。
-- 角色通过 artifactOutputs[].templateId 引用；引擎运行时把骨架铺到
-- .agentflow/templates/<id>.md，并按必填章节生成结构门禁。
-- 手动执行：mysql < migrations/041_artifact_templates.sql

CREATE TABLE IF NOT EXISTS artifact_templates (
  id VARCHAR(64) NOT NULL PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  payload JSON NOT NULL,
  updated_at DATETIME(6) NULL,
  KEY idx_artifact_templates_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO artifact_templates (id, name, payload, updated_at) VALUES
('requirement', '需求文档骨架', JSON_OBJECT(
  'id', 'requirement',
  'name', '需求文档骨架',
  'projectId', '',
  'shared', TRUE,
  'description', '需求定型产出的需求文档结构：目标、现状、范围、功能需求、验收标准',
  'mediaType', 'text/markdown',
  'content', '# 需求定型 · {{需求标题}}

## 目标
一句话说明要解决什么问题、给谁解决。

## 背景与现状
已核对的代码或数据证据，写清当前行为，不要写推测。

## 术语与对象界定
本次涉及的关键名词，避免后续歧义。

## 用户与场景
谁在什么情况下使用，主流程与异常路径分别是什么。

## 范围
### 范围内
本次必须交付的内容。
### 范围外
明确不做、留给后续的内容。

## 功能需求
逐条编号（FR-1、FR-2…），每条写清触发条件、行为、可见结果。

<!-- optional -->
## 非功能需求
性能、兼容、可观测性等非功能约束。

## 验收标准
每条都必须可执行验证：命令、期望结果、对应需求编号。
',
  'version', 1
), UTC_TIMESTAMP(6)),
('design', '方案设计骨架', JSON_OBJECT(
  'id', 'design',
  'name', '方案设计骨架',
  'projectId', '',
  'shared', TRUE,
  'description', '方案设计产出的设计文档结构：结论、约束、对比、改动点、验证计划',
  'mediaType', 'text/markdown',
  'content', '# 方案设计 · {{需求标题}}

## 结论先行
选定的方案，以及一句话说明为什么。

## 现状与约束
已核对的代码事实、不能改动的边界。

## 方案对比
至少两个候选方案，写清取舍与被否决的原因。

## 详细设计
改动点逐条列出：文件、类或函数、行为变化。

## 接口与数据影响
对外接口、数据结构、迁移要求、兼容性说明。

## 风险与回滚
失败模式、影响面、回滚方式。

## 验证计划
分层验证：单测、接口验收、回归门禁。
',
  'version', 1
), UTC_TIMESTAMP(6)),
('implementation', '实现说明骨架', JSON_OBJECT(
  'id', 'implementation',
  'name', '实现说明骨架',
  'projectId', '',
  'shared', TRUE,
  'description', '开发实现产出的实现说明结构：改动、文件、验证证据、已知限制',
  'mediaType', 'text/markdown',
  'content', '# 实现说明 · {{需求标题}}

## 改动摘要
改了什么、为什么这么改。

## 变更文件
| 文件 | 改动 |
| --- | --- |

## 关键实现
核心逻辑、边界处理、以及与设计不一致的地方。

## 验证证据
真实执行的命令与输出，不要只写「通过」。

## 已知限制
未覆盖的边界、遗留问题、需要后续跟进的点。
',
  'version', 1
), UTC_TIMESTAMP(6)),
('review', '评审报告骨架', JSON_OBJECT(
  'id', 'review',
  'name', '评审报告骨架',
  'projectId', '',
  'shared', TRUE,
  'description', '独立评审产出的报告结构：结论、阻断项、建议项、证据',
  'mediaType', 'text/markdown',
  'content', '# 评审报告 · {{需求标题}}

## 结论
PASS 或 REJECT，一句话说明理由。

## 阻断项
每条写清位置、影响、修复建议；没有则写「无」。

## 建议项
不阻断但值得改的问题。

## 证据
引用的命令输出、文件行号、运行记录编号。
',
  'version', 1
), UTC_TIMESTAMP(6)),
('test-report', '测试报告骨架', JSON_OBJECT(
  'id', 'test-report',
  'name', '测试报告骨架',
  'projectId', '',
  'shared', TRUE,
  'description', '测试验证产出的报告结构：覆盖范围、执行结果、失败归因',
  'mediaType', 'text/markdown',
  'content', '# 测试报告 · {{需求标题}}

## 覆盖范围
测了什么、明确没测什么。

## 执行结果
| 用例 | 命令 | 结果 |
| --- | --- | --- |

## 失败归因
失败是本次引入，还是在基线版本上同样存在的既有问题。

## 结论
是否满足验收标准，未满足的部分差在哪里。
',
  'version', 1
), UTC_TIMESTAMP(6))
ON DUPLICATE KEY UPDATE name = VALUES(name);

-- 回填：让需求定型、方案设计两个角色默认产出带骨架的文档。
-- 节点只声明 name/path，templateId 由角色提供（merge 时不会被子节点覆盖）。
UPDATE agents
SET payload = JSON_SET(
      payload,
      '$.artifactOutputs', JSON_ARRAY(JSON_OBJECT(
        'name', 'clarify', 'path', 'requirement.md', 'mediaType', 'text/markdown',
        'required', TRUE, 'templateId', 'requirement')),
      '$.version', COALESCE(JSON_EXTRACT(payload, '$.version'), 0) + 1
    )
WHERE id IN ('generic-backend-delivery-clarify', 'generic-backend-delivery-clarify-ai-devop-agent', 'backend-delivery-clarify', 'backend-delivery-clarify-ai-devop-agent');

UPDATE agents
SET payload = JSON_SET(
      payload,
      '$.artifactOutputs', JSON_ARRAY(JSON_OBJECT(
        'name', 'design', 'path', 'design.md', 'mediaType', 'text/markdown',
        'required', TRUE, 'templateId', 'design')),
      '$.version', COALESCE(JSON_EXTRACT(payload, '$.version'), 0) + 1
    )
WHERE id IN ('generic-backend-delivery-design', 'generic-backend-delivery-design-ai-devop-agent', 'backend-delivery-design', 'backend-delivery-design-ai-devop-agent');
