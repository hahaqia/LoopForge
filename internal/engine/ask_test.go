package engine

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"agentflow/internal/runtime"
)

// ask_human 落盘后要能被转成一次 human 终态：节点停在等待确认，
// 操作员看到的是问题清单，回答后 retry 续会话继续。
func TestReadAskResultMapsQuestionsToHumanGate(t *testing.T) {
	workspace := t.TempDir()
	rel := ".agentflow/gate-results/clarify/attempt-1.questions.json"
	full := filepath.Join(workspace, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	payload := `{"summary":"需要确认验收口径","questions":[{"id":"q1","question":"状态排序按哪种口径？","options":["全部状态","仅未完成"]},{"id":"q2","question":"还有别的约束吗？","freeText":true}]}`
	if err := os.WriteFile(full, []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
	got, questions, err := readAskResultFrom(workspaceOutputs(workspace), rel)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Decision != "human" {
		t.Fatalf("ask was not mapped to a human gate: %+v", got)
	}
	if got.Reason != "需要确认验收口径" {
		t.Fatalf("summary lost: %q", got.Reason)
	}
	for _, want := range []string{"状态排序按哪种口径", "全部状态 / 仅未完成", "还有别的约束吗", "请填写"} {
		if !strings.Contains(got.ActionRequired, want) {
			t.Fatalf("actionRequired missing %q: %q", want, got.ActionRequired)
		}
	}
	if len(questions) != 2 || questions[0].Options[0] != "全部状态" || !questions[1].FreeText {
		t.Fatalf("structured questions lost: %+v", questions)
	}
	missing, missingQuestions, err := readAskResultFrom(workspaceOutputs(workspace), ".agentflow/gate-results/clarify/attempt-2.questions.json")
	if err != nil || missing != nil || len(missingQuestions) != 0 {
		t.Fatalf("missing ask file should be ignored: %+v %+v %v", missing, missingQuestions, err)
	}
}

func TestGateAskPathStaysNextToGateResult(t *testing.T) {
	gate := gateResultPath("clarify", 3)
	ask := runtime.GateAskPath(gate)
	if ask != ".agentflow/gate-results/clarify/attempt-3.questions.json" {
		t.Fatalf("ask path = %q", ask)
	}
	if runtime.GateAskPath("") != "" {
		t.Fatal("empty gate path must not produce an ask path")
	}
}
