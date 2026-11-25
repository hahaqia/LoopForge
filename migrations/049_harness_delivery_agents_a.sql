-- ⚠ 已被 052 取代，勿重跑。
-- 本段只构造 @a_* 变量，不写库；真正落库在 051（按旧模型内联 Agents）。
-- 052 之后 051 已禁止重跑，本段单独执行也没有意义。
-- 正确顺序：seed/001 → 048 → 049 → 050 → 051 → 052 → 053。
--
-- Harness 融合交付 SOP · 第 2 段：需求定型 / 方案设计 / 就绪评审
-- 依赖 048 中定义的 @rules 与 @skill_readiness。
SET NAMES utf8mb4;

-- ============================================================
-- Hook 脚本（两条，均 executionScope=run）
-- ============================================================
SET @hook_ro_ready := 'import sys, json\ntry: d = json.load(sys.stdin)\nexcept Exception: sys.exit(0)\np = (d.get("tool_input") or {}).get("file_path") or ""\nif not p or p.endswith("readiness-review.md") or p.startswith(".agentflow/"): sys.exit(0)\nprint(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "就绪评审只读：仅可写 readiness-review.md"}}))\n';

SET @hook_tmpl := 'echo "本轮产物必须沿用模板骨架的章节标题，不得自拟、改名或删减；未写到的章节保留标题并在其下写明未覆盖原因。"\n';

SET @hook_ready := JSON_ARRAY(
  JSON_OBJECT('id','harness-ready-readonly','name','评审拦截写代码','event','PreToolUse',
    'matcher','Write|Edit|MultiEdit|NotebookEdit','language','python','script',@hook_ro_ready,
    'timeoutSec',10,'executionScope','run'),
  JSON_OBJECT('id','harness-ready-skeleton','name','强制沿用骨架标题','event','SessionStart',
    'language','shell','script',@hook_tmpl,'timeoutSec',5,'executionScope','run')
);

-- ============================================================
-- 角色 1/6：需求定型
-- ============================================================
SET @p_clarify := '工作领域：把模糊需求变成可执行的需求文档。\n\n只写 requirement.md，不写代码、不做技术方案、不拆任务。\n\n## 必须做到的\n1. 功能需求按 FR-1、FR-2 连续编号，每条都能对应到验收动作。\n2. 每条功能需求写明：输入、行为、输出、边界条件。\n3. 单独一节列出本次不做什么，用于防止范围蔓延。\n4. 验收标准节逐条对应 FR 编号，写清怎么验证（命令、请求、观察点）。\n5. 有歧义时列出待确认问题，写明默认假设，不要自己拍板业务决策。\n\n## 禁止\n- 不出现类名、表结构、接口注解等实现细节，这些属于方案设计。\n- 不承诺技术选型与工期。\n';

SET @a_clarify := JSON_OBJECT(
  'id','generic-harness-delivery-clarify','name','需求定型 · Harness','version',1,'shared',TRUE,
  'description','把需求转成可验证的 FR 与验收标准',
  'executorId','codebuddy','prompt',@p_clarify,
  'rules',JSON_ARRAY('harness-separation','harness-evidence'),
  'skills',JSON_ARRAY(),'mcpServers',JSON_ARRAY(),'knowledgeBase',TRUE,
  'hooks',JSON_ARRAY(JSON_OBJECT('id','harness-clarify-skeleton','name','强制沿用骨架标题','event','SessionStart',
    'language','shell','script',@hook_tmpl,'timeoutSec',5,'executionScope','run')),
  'loop',JSON_OBJECT('enabled',TRUE,'maxIterations',3,'exitCondition','all_gates_pass','onExhausted','human',
    'feedbackPrompt','读 {{feedback}}，只补被指出的章节，不要重写整篇。'),
  'artifactOutputs',JSON_ARRAY(JSON_OBJECT('name','clarify','path','requirement.md','mediaType','text/markdown','required',TRUE,'templateId','requirement')),
  'verification',JSON_ARRAY(
    JSON_OBJECT('id','requirement-pure','name','需求纯净度：不含实现细节','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        'grep -q "^## 功能需求" requirement.md',
        '! grep -Eq "(class |interface |CREATE TABLE|@RestController|@Service|SELECT .+ FROM)" requirement.md')),
    JSON_OBJECT('id','fr-trace','name','编号对账：每个 FR 都有验收','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        'test -z "$(grep -o "FR-[0-9]*" requirement.md | sort -u | while read id; do awk "/^## 验收标准/{f=1} f" requirement.md | grep -q "$id" || echo "$id"; done)"')))
);

-- ============================================================
-- 角色 2/6：方案设计
-- ============================================================
SET @p_design := '工作领域：把需求转成可落地的技术方案。\n\n只写 design.md，不改代码、不动需求文档。\n\n## 必须做到的\n1. 每个 FR 在方案里都要有落点，标注对应的文件与函数级改动位置。\n2. 至少对比两个候选方案，写清取舍依据；只有唯一解时说明为什么。\n3. 数据与接口变更要写兼容性与回滚路径。\n4. 写出本次改动涉及的文件清单，便于后续核对范围。\n5. 明确验证方式：怎么证明方案实现后需求成立。\n\n## 禁止\n- 不得凭空新增需求或扩展范围，新增点必须能追溯到某个 FR。\n- 不写实现代码，只写方案与位置。\n';

SET @a_design := JSON_OBJECT(
  'id','generic-harness-delivery-design','name','方案设计 · Harness','version',1,'shared',TRUE,
  'description','FR 到文件级改动的技术方案',
  'executorId','codebuddy','prompt',@p_design,
  'rules',JSON_ARRAY('harness-separation','harness-evidence'),
  'skills',JSON_ARRAY(),'mcpServers',JSON_ARRAY(),'knowledgeBase',TRUE,
  'hooks',JSON_ARRAY(JSON_OBJECT('id','harness-design-skeleton','name','强制沿用骨架标题','event','SessionStart',
    'language','shell','script',@hook_tmpl,'timeoutSec',5,'executionScope','run')),
  'loop',JSON_OBJECT('enabled',TRUE,'maxIterations',3,'exitCondition','all_gates_pass','onExhausted','human',
    'feedbackPrompt','读 {{feedback}}，只补被指出的章节。'),
  'artifactOutputs',JSON_ARRAY(JSON_OBJECT('name','design','path','design.md','mediaType','text/markdown','required',TRUE,'templateId','design')),
  'verification',JSON_ARRAY(
    JSON_OBJECT('id','fr-closure','name','编号闭合：不得凭空新增需求','mode','command','stage','after_execution','required',TRUE,'onFailure','reject','executionScope','run',
      'commands',JSON_ARRAY(
        'grep -q "^## 详细设计" design.md',
        'test -z "$(grep -o "FR-[0-9]*" design.md | sort -u | while read id; do grep -q "$id" requirement.md || echo "$id"; done)"')),
    JSON_OBJECT('id','design-locatable','name','改动可定位：落到文件级','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        'awk "/^## 详细设计/{f=1;next} /^## /{f=0} f" design.md | grep -Eq "[.](go|java|ts|tsx|py|sql|yaml|yml|vue|js)"')))
);

-- ============================================================
-- 角色 3/6：就绪评审（本方案的关卡）
-- ============================================================
SET @p_ready := '工作领域：在写代码前判定需求与方案是否可以开工。\n\n只写 readiness-review.md，不修改 requirement.md 与 design.md，不写代码。\n\n## 必须做到的\n1. 严格按模板的 A1-A7 逐条判定，每项写判定 + 依据 + 补齐要求。\n2. B 类只判命中项，未命中写未命中。\n3. 任一项不通过，结论就是 REJECT，并在必须补齐项写清哪一节缺什么、该由谁补。\n4. 根因归属写清楚：需求缺 → 打回需求定型，方案缺 → 打回方案设计。\n\n## 纪律\n- 只判定不改写，发现问题只写建议。\n- 只依据本次文档，不引用历史结论。\n- 拿不准判 REJECT。\n\n## 自检\n提交前跑一遍 scripts/check.sh。\n';

SET @a_ready := JSON_OBJECT(
  'id','generic-harness-delivery-readiness','name','就绪评审','version',1,'shared',TRUE,
  'description','开工前 A/B 类判定，输出 PASS 或 REJECT',
  'executorId','codebuddy','prompt',@p_ready,
  'rules',JSON_ARRAY('harness-separation','harness-evidence','harness-no-side-effect'),
  'skills',JSON_ARRAY('readiness-review'),'mcpServers',JSON_ARRAY(),
  'hooks',CAST(@hook_ready AS JSON),
  'loop',JSON_OBJECT('enabled',TRUE,'maxIterations',2,'exitCondition','all_gates_pass','onExhausted','fail','feedbackPrompt','读 {{feedback}}，只补漏勾的判定项和缺失的章节，不要重写整篇。'),
  'artifactOutputs',JSON_ARRAY(JSON_OBJECT('name','readiness-review','path','readiness-review.md','mediaType','text/markdown','required',TRUE,'templateId','readiness-review')),
  'verification',JSON_ARRAY(
    JSON_OBJECT('id','readiness-check','name','结论闭合与 A 类齐全','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        'sh "$(ls -d .agentflow/skills/readiness-review*/scripts/check.sh 2>/dev/null | head -1)"')))
);

SELECT JSON_UNQUOTE(JSON_EXTRACT(@a_ready,'$.id')) AS agent_3,
       JSON_LENGTH(JSON_EXTRACT(@a_ready,'$.hooks')) AS hooks,
       JSON_LENGTH(JSON_EXTRACT(@a_ready,'$.verification')) AS gates;
