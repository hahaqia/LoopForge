package runner

import (
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agentflow/internal/domain"
)

func TestEventBatcherStallDetection(t *testing.T) {
	b := &eventBatcher{}
	timeout := 30 * time.Second

	if b.stalled(timeout) {
		t.Fatal("zero timestamp must not be treated as a stall")
	}
	b.lastProgress.Store(time.Now().Add(-time.Minute).UnixNano())
	if !b.stalled(timeout) {
		t.Fatal("silent progress older than the timeout must be stalled")
	}
	if b.stalled(0) {
		t.Fatal("timeout zero must disable the watchdog")
	}

	b.lastProgress.Store(time.Now().UnixNano())
	if b.stalled(timeout) {
		t.Fatal("fresh progress must not be stalled")
	}
	// Runner-originated system lines must not keep the watchdog alive.
	b.lastProgress.Store(time.Now().Add(-time.Minute).UnixNano())
	b.add("system", "cancel requested by platform")
	if !b.stalled(timeout) {
		t.Fatal("system lines should not reset progress")
	}
	b.add("stdout", "real CLI output")
	if b.stalled(timeout) {
		t.Fatal("CLI output must reset the watchdog")
	}
}

func TestNewAgentStallTimeoutFromEnv(t *testing.T) {
	newDaemon := func() *Daemon {
		d, err := New(Config{
			ServerURL:      "http://127.0.0.1:1",
			BootstrapToken: "token",
			StatePath:      filepath.Join(t.TempDir(), "state.json"),
		})
		if err != nil {
			t.Fatal(err)
		}
		return d
	}

	t.Setenv(AgentStallTimeoutEnv, "42s")
	if got := newDaemon().cfg.AgentStallTimeout; got != 42*time.Second {
		t.Fatalf("env timeout = %s, want 42s", got)
	}
	t.Setenv(AgentStallTimeoutEnv, "0")
	if got := newDaemon().cfg.AgentStallTimeout; got != 0 {
		t.Fatalf("env timeout 0 should disable the watchdog, got %s", got)
	}
	t.Setenv(AgentStallTimeoutEnv, "not-a-duration")
	if got := newDaemon().cfg.AgentStallTimeout; got != defaultAgentStallTimeout {
		t.Fatalf("malformed env timeout = %s, want %s", got, defaultAgentStallTimeout)
	}
}

func TestExecuteProcessStallInterruptsSilentAgent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	}))
	defer server.Close()

	daemon := &Daemon{
		cfg: Config{
			AgentStallTimeout: 400 * time.Millisecond,
		},
		client:   NewClient(server.URL),
		controls: map[string]chan string{},
	}
	task := domain.RunnerTask{
		ID:        "stall-task",
		Workspace: t.TempDir(),
		Invocation: &domain.RunnerInvocation{},
	}
	result := daemon.executeProcess(context.Background(), task, []string{"sh", "-c", "echo started; sleep 30"})
	if result.status != domain.RunnerTaskFailed {
		t.Fatalf("status = %s, want failed (result=%+v)", result.status, result)
	}
	if !strings.Contains(result.errMsg, "agent stall") {
		t.Fatalf("error = %q, want agent stall", result.errMsg)
	}
	if !strings.Contains(result.result, "started") {
		t.Fatalf("result should keep the output before the stall: %q", result.result)
	}
}
