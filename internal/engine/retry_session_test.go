package engine

import (
	"strings"
	"testing"
	"time"

	"agentflow/internal/domain"
)

// 节点停在“等待人工确认”时，操作员的回答要接上原来那一轮对话，
// 否则 Agent 已经问过的问题会被丢弃，clarify 只能从头再来一遍。
func TestRetryWaitingApprovalKeepsAgentSession(t *testing.T) {
	t.Parallel()
	e, s := newRecoveryEngine(t)
	e.ConfigureExecution("test", "test", time.Second, false)
	wf := domain.WorkflowDefinition{ID: "retry-session", Name: "retry session", Nodes: []domain.WorkflowNode{
		{ID: "clarify", Name: "clarify", Type: "agent"},
		{ID: "script", Name: "script", Type: "script", Script: "echo rerun"},
	}, Edges: []domain.WorkflowEdge{{ID: "clarify-script", Source: "clarify", Target: "script", When: "success"}}}
	run := domain.Run{ID: "run-retry-session", WorkflowID: wf.ID, WorkflowSnapshot: wf, Status: "waiting", Nodes: map[string]*domain.NodeRun{
		"clarify": {NodeID: "clarify", Status: "waiting_approval", Activity: "等待人工确认", Attempt: 1, SessionID: "session-clarify"},
		"script":  {NodeID: "script", Status: "waiting_approval", Attempt: 1, SessionID: "session-script"},
	}}
	if err := s.PutRun(run); err != nil {
		t.Fatal(err)
	}
	if err := e.Retry(run.ID, "clarify", "人工确认后继续", "目标是按状态快捷排序"); err != nil {
		t.Fatal(err)
	}
	got, ok := s.Run(run.ID)
	if !ok {
		t.Fatal("run missing after retry")
	}
	if got.Nodes["clarify"].ResumeSessionID != "session-clarify" {
		t.Fatalf("waiting agent lost its session: %+v", got.Nodes["clarify"])
	}
	if !strings.Contains(got.Nodes["clarify"].Feedback, "按状态快捷排序") {
		t.Fatalf("operator note missing from feedback: %q", got.Nodes["clarify"].Feedback)
	}
	if got.Nodes["script"].Status != "pending" || got.Nodes["script"].ResumeSessionID != "" {
		t.Fatalf("script node must restart without an Agent session: %+v", got.Nodes["script"])
	}
}

// 门禁失败转人工后重试必须开新会话，带上产物模板与失败反馈；恢复旧会话
// 会让 Agent 原样重交上一轮被驳回的文档。
func TestRetryGateFailureUsesFreshSessionWithFeedback(t *testing.T) {
	t.Parallel()
	e, s := newRecoveryEngine(t)
	e.ConfigureExecution("test", "test", time.Second, false)
	wf := domain.WorkflowDefinition{ID: "retry-gate-fresh", Name: "retry gate fresh", Nodes: []domain.WorkflowNode{
		{ID: "clarify", Name: "clarify", Type: "agent"},
	}}
	run := domain.Run{ID: "run-retry-gate-fresh", WorkflowID: wf.ID, WorkflowSnapshot: wf, Status: "waiting", Nodes: map[string]*domain.NodeRun{
		"clarify": {NodeID: "clarify", Status: "waiting_approval", Attempt: 2, SessionID: "session-stale", Error: "verification requirement.md 章节完整: 缺少必需章节: 目标 背景与现状"},
	}}
	if err := s.PutRun(run); err != nil {
		t.Fatal(err)
	}
	if err := e.Retry(run.ID, "clarify", "人工确认重试本节点", "请按需求文档骨架重写"); err != nil {
		t.Fatal(err)
	}
	got, ok := s.Run(run.ID)
	if !ok {
		t.Fatal("run missing after retry")
	}
	nr := got.Nodes["clarify"]
	if nr.ResumeSessionID != "" {
		t.Fatalf("gate failure retry must start fresh, got resume session %q", nr.ResumeSessionID)
	}
	if !strings.Contains(nr.Feedback, "缺少必需章节") {
		t.Fatalf("failure detail missing from feedback: %q", nr.Feedback)
	}
	if !strings.Contains(nr.Feedback, "请按需求文档骨架重写") {
		t.Fatalf("operator note missing from feedback: %q", nr.Feedback)
	}
}

// 失败重试是从头再来：旧 session 可能已经跑偏或被丢，不能盲目 --resume。
func TestRetryFailedAgentDoesNotResumeStaleSession(t *testing.T) {
	t.Parallel()
	e, s := newRecoveryEngine(t)
	e.ConfigureExecution("test", "test", time.Second, false)
	wf := domain.WorkflowDefinition{ID: "retry-failed", Name: "retry failed", Nodes: []domain.WorkflowNode{
		{ID: "implement", Name: "implement", Type: "agent"},
	}}
	run := domain.Run{ID: "run-retry-failed", WorkflowID: wf.ID, WorkflowSnapshot: wf, Status: "failed", Nodes: map[string]*domain.NodeRun{
		"implement": {NodeID: "implement", Status: "failed", Attempt: 1, SessionID: "session-old", Error: "boom"},
	}}
	if err := s.PutRun(run); err != nil {
		t.Fatal(err)
	}
	if err := e.Retry(run.ID, "implement", "修复后重跑", ""); err != nil {
		t.Fatal(err)
	}
	got, ok := s.Run(run.ID)
	if !ok {
		t.Fatal("run missing after retry")
	}
	if got.Nodes["implement"].ResumeSessionID != "" {
		t.Fatalf("failed retry must start a fresh conversation: %+v", got.Nodes["implement"])
	}
}

// 回答后继续要保留已用的提问配额；人工点“从头重跑”则重新给满。
func TestRetryKeepsAskQuotaOnlyWhenWaitingForAnswer(t *testing.T) {
	t.Parallel()
	e, s := newRecoveryEngine(t)
	e.ConfigureExecution("test", "test", time.Second, false)
	wf := domain.WorkflowDefinition{ID: "ask-quota", Name: "ask quota", Nodes: []domain.WorkflowNode{
		{ID: "clarify", Name: "clarify", Type: "agent"},
	}}
	waiting := domain.Run{ID: "run-ask-waiting", WorkflowID: wf.ID, WorkflowSnapshot: wf, Status: "waiting", Nodes: map[string]*domain.NodeRun{
		"clarify": {NodeID: "clarify", Status: "waiting_approval", Attempt: 1, SessionID: "s1", AskCount: 2},
	}}
	failed := domain.Run{ID: "run-ask-failed", WorkflowID: wf.ID, WorkflowSnapshot: wf, Status: "failed", Nodes: map[string]*domain.NodeRun{
		"clarify": {NodeID: "clarify", Status: "failed", Attempt: 1, SessionID: "s2", AskCount: 2},
	}}
	if err := s.PutRun(waiting); err != nil {
		t.Fatal(err)
	}
	if err := s.PutRun(failed); err != nil {
		t.Fatal(err)
	}
	if err := e.Retry(waiting.ID, "clarify", "回答后继续", "选了 A"); err != nil {
		t.Fatal(err)
	}
	if err := e.Retry(failed.ID, "clarify", "修复后重跑", ""); err != nil {
		t.Fatal(err)
	}
	gotWaiting, _ := s.Run(waiting.ID)
	if gotWaiting.Nodes["clarify"].AskCount != 2 {
		t.Fatalf("waiting retry must keep the ask quota: %+v", gotWaiting.Nodes["clarify"])
	}
	gotFailed, _ := s.Run(failed.ID)
	if gotFailed.Nodes["clarify"].AskCount != 0 {
		t.Fatalf("fresh retry must reset the ask quota: %+v", gotFailed.Nodes["clarify"])
	}
}
