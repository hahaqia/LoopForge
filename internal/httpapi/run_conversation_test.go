package httpapi

import (
	"agentflow/internal/domain"
	"strings"
	"testing"
)

func TestExpandedConversationPreservesToolAndArtifactIdentity(t *testing.T) {
	tool := domain.TelemetryEvent{Category: "tool", Tool: &domain.ToolObservation{Name: "Read", CallID: "call-1"}, Attributes: map[string]any{
		"private": "hidden",
		"input":   map[string]any{"command": "curl -H 'Authorization: Bearer sk-live-secret' https://example.test", "path": "a.go"},
	}}
	got := expandedTelemetryEvent(tool)
	if got.Tool == nil || got.Tool.Name != "Read" {
		t.Fatalf("tool identity lost: %#v", got)
	}
	if _, exposed := got.Attributes["private"]; exposed {
		t.Fatalf("raw attributes exposed: %#v", got.Attributes)
	}
	input, ok := got.Attributes["input"].(map[string]any)
	if !ok {
		t.Fatalf("tool input lost: %#v", got.Attributes)
	}
	if path, _ := input["path"].(string); path != "a.go" {
		t.Fatalf("whitelisted path lost: %#v", input)
	}
	command, _ := input["command"].(string)
	if strings.Contains(command, "sk-live-secret") || !strings.Contains(command, "***") {
		t.Fatalf("credential not redacted: %q", command)
	}
	artifact := domain.TelemetryEvent{Category: "artifact", Name: "artifact.published", Attributes: map[string]any{"artifactId": "file-1", "path": "result.md", "size": 42, "private": "hidden"}}
	got = expandedTelemetryEvent(artifact)
	if got.Attributes["artifactId"] != "file-1" || got.Attributes["path"] != "result.md" || len(got.Attributes) != 3 {
		t.Fatalf("artifact linkage lost or extra attributes exposed: %#v", got.Attributes)
	}
	if slimTelemetryEvent(tool).Tool != nil || slimTelemetryEvent(tool).Attributes != nil || slimTelemetryEvent(artifact).Attributes != nil {
		t.Fatal("compact telemetry contract changed")
	}
}
