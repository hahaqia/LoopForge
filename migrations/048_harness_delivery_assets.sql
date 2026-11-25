-- ⚠ 已被 052 取代，勿重跑。
-- 本脚本按 payload 内联 {Workflow, Agents, Rules, Skills} 的旧模型编写。
-- 052 已把内联资产搬进平台资产库（agents/rules/skills）并改写为 AgentRefs；
-- 在已执行 052 的环境重跑会覆盖 artifact_templates、写回内联键，
-- 并把 SOP 的 version/status/publishedRevision 重置为初始值。
-- 正确顺序：seed/001 → 048 → 049 → 050 → 051 → 052 → 053。
-- 误跑后：重跑 052 恢复引用结构，再重跑 053 重新 pin 角色版本；
-- version/status 需按实际发布记录人工校正。
--
-- Harness 融合交付 SOP · 第 1 段：产物模板 + 自建技能 + 四条规则
-- 一次性执行：048 → 049 → 050 → 051，不要单独重跑其中任何一段。
-- payload 结构固定为 {Workflow, Agents, Rules, Skills}，
-- 见 internal/repo/generic_workflows.go 的 GenericTemplate。
-- 规则一律走 payload.Rules + 角色显式引用，不用 global + workflowIds：
-- adopt 时 cloneGenericTemplateRules 不重写 workflowIds，global 规则必然失配。
SET NAMES utf8mb4;

-- ============================================================
-- 1) 就绪评审产物模板
-- ============================================================
INSERT INTO `artifact_templates` (`id`, `name`, `payload`, `updated_at`) VALUES
('readiness-review', '就绪评审骨架', JSON_OBJECT(
  'id', 'readiness-review', 'name', '就绪评审骨架', 'projectId', '', 'shared', TRUE,
  'description', '开工前判定：A 类必判 7 项，B 类命中才验',
  'mediaType', 'text/markdown',
  'content', '# 就绪评审\n\n## 评审输入\n\n- 需求文档：requirement.md\n- 设计方案：design.md\n\n## A 类必判项\n\n- [ ] A1 目标与验收口径：每个 FR 都能对应到可执行的验收动作\n- [ ] A2 范围边界：明确写出本次不做什么\n- [ ] A3 依赖与前置条件：外部服务、数据、权限、环境是否就绪\n- [ ] A4 数据与兼容性：表结构、接口、配置改动是否向前兼容，回滚路径是否存在\n- [ ] A5 安全与权限：鉴权、越权、敏感信息落盘是否有处理\n- [ ] A6 可观测与失败处理：异常路径、重试、日志是否有交代\n- [ ] A7 验证方式：每条验收标准都有对应的验证手段\n\n## B 类条件项（命中才验，未命中写未命中）\n\n- [ ] B1 并发或事务\n- [ ] B2 资金或计费\n- [ ] B3 历史数据迁移\n- [ ] B4 对外接口契约变更\n- [ ] B5 性能敏感路径\n- [ ] B6 多租户或数据隔离\n\n## 必须补齐项\n\n（结论为 REJECT 时必填，逐条写清位置与补齐要求）\n\n## 结论\n\nPASS 或 REJECT，加一句话理由\n\n## 根因归属\n\n需求 / 方案 / 环境（REJECT 时必填，决定打回哪个节点）\n',
  'version', 1
), UTC_TIMESTAMP(6))
ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `payload` = VALUES(`payload`);

-- ============================================================
-- 2) readiness-review 技能：Content 是 SKILL.md，Files 落到技能目录
-- ============================================================
SET @md := '# 就绪评审\n\n目标：在写第一行代码前，判定需求与方案是否可以开工。\n\n## 做法\n\n1. 只读 requirement.md 与 design.md，不要读实现代码反推需求。\n2. 逐条判定 A1-A7，每项写：判定、依据（引用文档具体段落）、不通过时的补齐要求。\n3. A 类必须全部有结论，不允许空着或用「基本没问题」带过。\n4. B 类只判命中项，未命中写「未命中」。\n5. 任一项不通过，结论就是 REJECT，并在必须补齐项写清哪一节缺什么。\n\n## 纪律\n\n- 只判定，不修改 requirement.md 或 design.md，也不优化措辞。\n- 只依据本次文档，不引用历史需求或他人结论。\n- 拿不准判 REJECT，并写明需要谁补什么。\n\n## 自检\n\nscripts/check.sh 校验：结论小节存在、含 PASS 或 REJECT、REJECT 时必须补齐项非空、A 类勾选不少于 7。提交前自己跑一遍。\n';

SET @sh := '#!/bin/sh\nf=readiness-review.md\n[ -f "$f" ] || { echo "missing $f"; exit 1; }\ngrep -q "^## 结论" "$f" || { echo "missing 结论"; exit 1; }\ngrep -q "^## 必须补齐项" "$f" || { echo "missing 必须补齐项"; exit 1; }\nconcl=$(awk "/^## 结论/{f=1;next} /^## /{f=0} f" "$f" | grep -oiE "PASS|REJECT" | head -1)\n[ -n "$concl" ] || { echo "no PASS/REJECT"; exit 1; }\nitems=$(awk "/^## 必须补齐项/{f=1;next} /^## /{f=0} f" "$f" | grep -cE "^([-*]|[0-9]+[.]) " || true)\nchecked=$(grep -cF -- "- [x]" "$f" || true)\nitems=${items:-0}\nchecked=${checked:-0}\nif [ "$concl" = "REJECT" ] && [ "$items" -eq 0 ]; then echo "REJECT without 必须补齐项"; exit 1; fi\n[ "$checked" -ge 7 ] || { echo "A 类勾选 $checked/7 不足"; exit 1; }\necho "readiness ok: $concl items=$items checked=$checked"\n';

SET @skill_readiness := JSON_OBJECT(
  'id', 'readiness-review', 'name', '就绪评审',
  'description', '开工前 A/B 类判定，输出 PASS 或 REJECT 并列出补齐项',
  'content', @md,
  'files', JSON_OBJECT('scripts/check.sh', @sh),
  'updatedAt', '2026-11-24T00:00:00Z');

-- ============================================================
-- 3) 四条规则
-- ============================================================
SET @r_sep := '评判与执行必须是两个角色：产出结论的角色不得修改被评判的对象，实现者不得给自己出判定结论。发现问题的角色写清位置与修复建议，由实现角色修改；编排角色只汇总，不替其他角色下结论。';
SET @r_evidence := '任何“已验证”“已通过”“已修复”的表述都必须附本次执行的命令与结果；没跑就写“未执行”，不得引用历史记录、他人结论或推测。证据缺失视为未通过。';
SET @r_noside := '本角色只做判定：不修改被评审的文档与代码，不顺手重构、不优化措辞、不补测试。发现问题只写位置与建议，改动交给实现角色。仅可写本节点约定的产物文件。';
SET @r_minimal := '只改需求与方案要求的内容：不做未授权的重构、不顺手修无关问题、不改公共接口签名、不调整目录结构。确需越界时先说明理由并记录取舍。';

SET @rules := JSON_ARRAY(
  JSON_OBJECT('id','harness-separation','name','裁判与执行分离','projectId','','shared',TRUE,'global',FALSE,'priority',200,'content',@r_sep,'version',1,'updatedAt','2026-11-24T00:00:00Z'),
  JSON_OBJECT('id','harness-evidence','name','证据必须来自本次执行','projectId','','shared',TRUE,'global',FALSE,'priority',200,'content',@r_evidence,'version',1,'updatedAt','2026-11-24T00:00:00Z'),
  JSON_OBJECT('id','harness-no-side-effect','name','只判定不改写','projectId','','shared',TRUE,'global',FALSE,'priority',200,'content',@r_noside,'version',1,'updatedAt','2026-11-24T00:00:00Z'),
  JSON_OBJECT('id','harness-minimal-diff','name','最小改动','projectId','','shared',TRUE,'global',FALSE,'priority',200,'content',@r_minimal,'version',1,'updatedAt','2026-11-24T00:00:00Z')
);

-- 变量 @rules / @skill_readiness / @md 供 049、050 使用；
-- 若分多次会话执行，请一次性 source 本文件再执行后续段落。
SELECT JSON_LENGTH(@rules) AS rules,
       JSON_UNQUOTE(JSON_EXTRACT(@skill_readiness, '$.id')) AS skill,
       CHAR_LENGTH(@sh) AS check_sh_len;
