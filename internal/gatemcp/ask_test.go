package gatemcp

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runAsk(t *testing.T, askPath string, calls ...string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	gatePath := filepath.Join(dir, "attempt-1.json")
	input := strings.Join(append([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,
	}, calls...), "\n")
	var out bytes.Buffer
	if err := RunWithAsk(strings.NewReader(input+"\n"), &out, gatePath, askPath); err != nil {
		t.Fatalf("run gate mcp: %v", err)
	}
	return out.String(), gatePath
}

func TestAskHumanIsOnlyExposedWhenPathIsConfigured(t *testing.T) {
	withAsk, _ := runAsk(t, "/tmp/unused-questions.json", `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	if !strings.Contains(withAsk, "ask_human") || !strings.Contains(withAsk, "submit_gate_result") {
		t.Fatalf("both tools expected: %s", withAsk)
	}
	withoutAsk, _ := runAsk(t, "", `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	if strings.Contains(withoutAsk, "ask_human") {
		t.Fatalf("ask_human leaked without a path: %s", withoutAsk)
	}
}

func TestAskHumanWritesQuestionsOnce(t *testing.T) {
	dir := t.TempDir()
	askPath := filepath.Join(dir, "attempt-1.questions.json")
	call := `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_human","arguments":{"summary":"需要确认验收口径","questions":[{"question":"状态排序按哪种口径？","options":["全部状态","仅未完成"]},{"question":"还有别的约束吗？"}]}}}`
	out, _ := runAsk(t, askPath, call)
	if !strings.Contains(out, "Questions submitted") {
		t.Fatalf("tool result missing: %s", out)
	}
	raw, err := os.ReadFile(askPath)
	if err != nil {
		t.Fatalf("questions file missing: %v", err)
	}
	var ask askRequest
	if err := json.Unmarshal(raw, &ask); err != nil {
		t.Fatalf("questions payload invalid: %v", err)
	}
	if len(ask.Questions) != 2 || ask.Questions[0].Options[0] != "全部状态" {
		t.Fatalf("questions lost: %+v", ask)
	}
	if !ask.Questions[1].FreeText || len(ask.Questions[1].Options) != 0 {
		t.Fatalf("open question should be free text: %+v", ask.Questions[1])
	}
	if ask.Questions[0].ID == "" || ask.Questions[1].ID == "" {
		t.Fatalf("question ids were not defaulted: %+v", ask)
	}
	// 第二次调用不能覆盖已经提交的问题（否则服务端等待的回答会对不上）。
	again := `{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ask_human","arguments":{"questions":[{"question":"再问一次"}]}}}`
	out, _ = runAsk(t, askPath, again)
	if !strings.Contains(out, "already submitted") {
		t.Fatalf("second submit should be rejected: %s", out)
	}
}

func TestAskHumanRejectsAmbiguousChoice(t *testing.T) {
	askPath := filepath.Join(t.TempDir(), "q.json")
	out, _ := runAsk(t, askPath, `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_human","arguments":{"questions":[{"question":"选一个","options":["只有一个"]}]}}}`)
	if !strings.Contains(out, "at least two different options") {
		t.Fatalf("single-option choice accepted: %s", out)
	}
	if _, err := os.Stat(askPath); !os.IsNotExist(err) {
		t.Fatal("invalid ask must not write a file")
	}
}

func TestAskHumanRespectsNodeLimit(t *testing.T) {
	dir := t.TempDir()
	askPath := filepath.Join(dir, "attempt-1.questions.json")
	gatePath := filepath.Join(dir, "attempt-1.json")
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_human","arguments":{"questions":[{"question":"第一个问题"}]}}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ask_human","arguments":{"questions":[{"question":"第二个问题"}]}}}`,
	}, "\n") + "\n"
	var out bytes.Buffer
	if err := RunWithLimits(strings.NewReader(input), &out, gatePath, askPath, 1); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	if !strings.Contains(text, "Questions submitted") {
		t.Fatalf("first ask rejected: %s", text)
	}
	if !strings.Contains(text, "次数已用尽") {
		t.Fatalf("second ask should hit the limit: %s", text)
	}
}
