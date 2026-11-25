-- ⚠ 已被 052 取代，勿重跑。
-- 本段只构造 @a_* 与 @agents 变量，不写库；真正落库在 051（按旧模型内联 Agents）。
-- 052 之后 051 已禁止重跑，本段单独执行也没有意义。
-- 正确顺序：seed/001 → 048 → 049 → 050 → 051 → 052 → 053。
--
-- Harness 融合交付 SOP · 第 3 段：开发实现 / 独立评审 / 测试验证 + 角色打包
-- 依赖 048 的 @rules，049 的 @a_clarify / @a_design / @a_ready。
SET NAMES utf8mb4;

SET @hook_ro_review := 'import sys, json\ntry: d = json.load(sys.stdin)\nexcept Exception: sys.exit(0)\np = (d.get("tool_input") or {}).get("file_path") or ""\nif not p or p.endswith("review.md") or p.startswith(".agentflow/"): sys.exit(0)\nprint(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "评审角色只读：仅可写 review.md，禁止修改被审代码"}}))\n';

-- ============================================================
-- 角色 4/6：开发实现
-- ============================================================
SET @p_impl := '工作领域：按方案实现代码。\n\n改代码 + 只写 implementation.md。不改需求与方案文档：方案有问题时在实现说明里写清卡点，不要自行改设计。\n\n## 必须做到的\n1. 严格按 design.md 的文件清单改动，不做未授权重构、不顺手修无关问题。\n2. 每完成一块就构建一次，不要攒到最后。\n3. implementation.md 写：改了哪些文件、关键决策、与方案的偏差（无偏差写无）、未完成项。\n4. 所有验证都写真实执行结果，没跑写未执行。\n\n## 禁止\n- 不提交、不推送、不创建 MR。\n- 不留占位实现、不留 TODO_ONLY、不用空函数骗过编译。\n';

SET @a_impl := JSON_OBJECT(
  'id','generic-harness-delivery-implement','name','开发实现 · Harness','version',1,'shared',TRUE,
  'description','按方案最小改动实现，并记录偏差',
  'executorId','codebuddy','prompt',@p_impl,
  'rules',JSON_ARRAY('harness-separation','harness-evidence','harness-minimal-diff'),
  'skills',JSON_ARRAY(),'mcpServers',JSON_ARRAY(),
  'loop',JSON_OBJECT('enabled',TRUE,'maxIterations',3,'exitCondition','all_gates_pass','onExhausted','human',
    'feedbackPrompt','读 {{feedback}}，只修失败项，不要重做已通过的部分。'),
  'artifactOutputs',JSON_ARRAY(JSON_OBJECT('name','implementation','path','implementation.md','mediaType','text/markdown','required',TRUE,'templateId','implementation')),
  'verification',JSON_ARRAY(
    JSON_OBJECT('id','build-pass','name','构建通过','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','repositories',
      'commands',JSON_ARRAY('go build ./...')),
    JSON_OBJECT('id','no-placeholder','name','无占位残留','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        '! grep -q "【待填充】" implementation.md',
        '! grep -q "TODO_ONLY" implementation.md')))
);

-- ============================================================
-- 角色 5/6：独立评审
-- ============================================================
SET @p_review := '工作领域：独立评审本次改动。\n\n只写 review.md，绝不修改被审代码。发现的问题写位置与建议，由实现角色修改。\n\n## 必须做到的\n1. 先核对改动范围是否与 design.md 的文件清单一致，越界要单列。\n2. 按严重度分级：阻断项 / 建议项，阻断项必须写清位置与修复方向。\n3. 结论只有两种：PASS（无阻断项）或 REJECT（存在阻断项）。\n4. 每一条判断都要能指向具体文件与行或具体段落。\n\n## 禁止\n- 不改代码、不补测试、不顺手重构。\n- 不给没有依据的通过结论；没看就说没看。\n';

SET @a_review := JSON_OBJECT(
  'id','generic-harness-delivery-review','name','独立评审 · Harness','version',1,'shared',TRUE,
  'description','只读评审，输出阻断项与结论',
  'executorId','codebuddy','prompt',@p_review,
  'rules',JSON_ARRAY('harness-separation','harness-evidence','harness-no-side-effect'),
  'skills',JSON_ARRAY(),'mcpServers',JSON_ARRAY(),
  'hooks',JSON_ARRAY(JSON_OBJECT('id','harness-review-readonly','name','评审拦截写代码','event','PreToolUse',
    'matcher','Write|Edit|MultiEdit|NotebookEdit','language','python','script',@hook_ro_review,
    'timeoutSec',10,'executionScope','run')),
  'loop',JSON_OBJECT('enabled',TRUE,'maxIterations',3,'exitCondition','all_gates_pass','onExhausted','human',
    'feedbackPrompt','读 {{feedback}}，只修 review.md 的结构问题，不要改动被审代码。'),
  'artifactOutputs',JSON_ARRAY(JSON_OBJECT('name','review','path','review.md','mediaType','text/markdown','required',TRUE,'templateId','review')),
  'verification',JSON_ARRAY(
    JSON_OBJECT('id','no-code-change','name','未修改被审代码','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','repositories',
      'commands',JSON_ARRAY(
        'test -z "$(git status --porcelain -- . ":!review.md" ":!.agentflow")"')),
    JSON_OBJECT('id','verdict-consistent','name','结论与阻断项自洽','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        'grep -q "^## 结论" review.md',
        'c=$(awk "/^## 结论/{f=1;next} /^## /{f=0} f" review.md | grep -oiE "PASS|REJECT" | head -1); b=$(awk "/^## 阻断项/{f=1;next} /^## /{f=0} f" review.md | grep -cE "^([-*]|[0-9]+[.]) " || true); [ "$c" != "PASS" ] || [ "${b:-0}" -eq 0 ]')))
);

-- ============================================================
-- 角色 6/6：测试验证
-- ============================================================
SET @p_test := '工作领域：用真实执行验证需求是否成立。\n\n只写 test-report.md，不改代码（发现缺陷写归因，交回实现）。\n\n## 必须做到的\n1. 按 requirement.md 的验收标准逐条设计用例，每条标注对应 FR 编号。\n2. 每条用例都必须真实执行，记录命令、退出码、结果。\n3. 失败用例必须写归因：实现缺陷 / 需求不清 / 环境问题。\n4. 未覆盖的范围明确写出来，不要默认通过。\n\n## 禁止\n- 不编造执行结果，没跑写未执行。\n- 不修改代码来让用例通过。\n';

SET @a_test := JSON_OBJECT(
  'id','generic-harness-delivery-test','name','测试验证 · Harness','version',1,'shared',TRUE,
  'description','按验收标准真实执行并记录证据',
  'executorId','codebuddy','prompt',@p_test,
  'rules',JSON_ARRAY('harness-separation','harness-evidence'),
  'skills',JSON_ARRAY(),'mcpServers',JSON_ARRAY(),
  'loop',JSON_OBJECT('enabled',TRUE,'maxIterations',3,'exitCondition','all_gates_pass','onExhausted','human',
    'feedbackPrompt','读 {{feedback}}，只补未通过的用例证据。'),
  'artifactOutputs',JSON_ARRAY(JSON_OBJECT('name','test-report','path','test-report.md','mediaType','text/markdown','required',TRUE,'templateId','test-report')),
  'verification',JSON_ARRAY(
    JSON_OBJECT('id','evidence-rows','name','执行结果表三列齐全','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        'grep -q "^## 执行结果" test-report.md')),
    JSON_OBJECT('id','failure-attributed','name','有失败必须写归因','mode','command','stage','after_execution','required',TRUE,'onFailure','loop','executionScope','run',
      'commands',JSON_ARRAY(
        'f=$(awk "/^## 执行结果/{f=1;next} /^## /{f=0} f" test-report.md | grep -ciE "[|] *(失败|FAIL)" || true); a=$(awk "/^## 失败归因/{f=1;next} /^## /{f=0} f" test-report.md | grep -c "[^[:space:]]" || true); [ "${f:-0}" -eq 0 ] || [ "${a:-0}" -gt 0 ]')))
);

-- ============================================================
-- 复用旧模板的 mr / deliver 角色（按 id 从 payload.Agents 取原定义）
-- 不改 id：同一项目里两条 SOP 共用这两个角色，改一处两边都生效。
-- ============================================================
SET @old := (SELECT `payload` FROM `generic_templates` WHERE `id` = 'generic-backend-delivery');
SET @mr_idx := (SELECT t.idx FROM JSON_TABLE(@old, '$.Agents[*]'
                COLUMNS(idx FOR ORDINALITY, aid VARCHAR(191) PATH '$.id')) t
                WHERE t.aid = 'generic-backend-delivery-mr');
SET @del_idx := (SELECT t.idx FROM JSON_TABLE(@old, '$.Agents[*]'
                 COLUMNS(idx FOR ORDINALITY, aid VARCHAR(191) PATH '$.id')) t
                 WHERE t.aid = 'generic-backend-delivery-deliver');
SET @a_mr := IF(@mr_idx IS NULL, NULL, JSON_EXTRACT(@old, CONCAT('$.Agents[', @mr_idx - 1, ']')));
SET @a_deliver := IF(@del_idx IS NULL, NULL, JSON_EXTRACT(@old, CONCAT('$.Agents[', @del_idx - 1, ']')));

SELECT @mr_idx AS mr_index, @del_idx AS deliver_index,
       JSON_UNQUOTE(JSON_EXTRACT(@a_mr, '$.id')) AS mr_id;

-- ============================================================
-- 8 个角色打包
-- ============================================================
SET @agents := JSON_ARRAY(
  CAST(@a_clarify AS JSON), CAST(@a_design AS JSON), CAST(@a_ready AS JSON),
  CAST(@a_impl AS JSON), CAST(@a_review AS JSON), CAST(@a_test AS JSON),
  CAST(@a_mr AS JSON), CAST(@a_deliver AS JSON));

SELECT JSON_LENGTH(@agents) AS agent_count,
       JSON_LENGTH(JSON_EXTRACT(@a_impl, '$.verification')) AS impl_gates;
