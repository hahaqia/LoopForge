package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentflow/internal/domain"
)

func TestApplyGateResultDistinguishesTerminalDecisions(t *testing.T) {
	t.Parallel()
	tests := []struct {
		decision     string
		rejectTarget string
		action       string
		rework       bool
		hasError     bool
	}{
		{decision: "pass"},
		{decision: "rework", rejectTarget: "implement", action: "reject", rework: true, hasError: true},
		{decision: "fail", action: "fail", hasError: true},
		{decision: "human", action: "human", hasError: true},
	}
	for _, tt := range tests {
		t.Run(tt.decision, func(t *testing.T) {
			err, action, rework := applyGateResult(&domain.GateResult{Decision: tt.decision, Reason: "reason"}, tt.rejectTarget)
			if (err != nil) != tt.hasError || action != tt.action || rework != tt.rework {
				t.Fatalf("err=%v action=%q rework=%v", err, action, rework)
			}
		})
	}
}

func TestApplyGateResultDegradesReworkWithoutTarget(t *testing.T) {
	t.Parallel()
	err, action, rework := applyGateResult(&domain.GateResult{Decision: "rework", Reason: "upstream must fix inputs"}, "")
	if err == nil || action != "fail" || rework {
		t.Fatalf("rework without rejectTo must degrade to fail: err=%v action=%q rework=%v", err, action, rework)
	}
	if !strings.Contains(err.Error(), "no rework target") || !strings.Contains(err.Error(), "upstream must fix inputs") {
		t.Fatalf("degraded error should explain the missing target and keep the agent reason: %v", err)
	}
}

func TestSubmitGateInstructionExplainsReworkAvailability(t *testing.T) {
	t.Parallel()
	withTarget := appendSubmitGateInstruction("task", "implement", false, false)
	for _, want := range []string{"pass", "rework", "fail", "human", "implement"} {
		if !strings.Contains(withTarget, want) {
			t.Fatalf("instruction missing %q:\n%s", want, withTarget)
		}
	}
	withoutTarget := appendSubmitGateInstruction("task", "", false, false)
	if !strings.Contains(withoutTarget, "rework：本节点没有配置返工目标，不可选择") {
		t.Fatalf("missing no-target warning:\n%s", withoutTarget)
	}
}

// 角色没开中途提问时，任务书里不能出现 ask_human，否则模型会去调一个不存在的工具。
func TestSubmitGateInstructionOnlyMentionsAskWhenAllowed(t *testing.T) {
	t.Parallel()
	withAsk := appendSubmitGateInstruction("task", "implement", true, false)
	if !strings.Contains(withAsk, "ask_human") || !strings.Contains(withAsk, "可以先向人确认") {
		t.Fatalf("ask section missing when allowed:\n%s", withAsk)
	}
	withoutAsk := appendSubmitGateInstruction("task", "implement", false, false)
	if strings.Contains(withoutAsk, "ask_human") {
		t.Fatalf("ask section leaked when disabled:\n%s", withoutAsk)
	}
	if !strings.Contains(withoutAsk, "submit_gate_result") {
		t.Fatalf("gate instruction must stay:\n%s", withoutAsk)
	}
}

func TestReadGateResultRequiresHumanAction(t *testing.T) {
	t.Parallel()
	workspace := t.TempDir()
	path := ".agentflow/gate-results/human/attempt-1.json"
	target := filepath.Join(workspace, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte(`{"decision":"human","reason":"evidence is ambiguous"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readGateResult(workspace, path); err == nil || !strings.Contains(err.Error(), "actionRequired") {
		t.Fatalf("human result without requested action must fail validation: %v", err)
	}
	if err := os.WriteFile(target, []byte(`{"decision":"human","reason":"evidence is ambiguous","actionRequired":"confirm whether the exception is acceptable"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := readGateResult(workspace, path)
	if err != nil || result.ActionRequired == "" {
		t.Fatalf("valid human result=%+v err=%v", result, err)
	}
}
