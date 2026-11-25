package repo

import (
	"strings"
	"testing"

	"agentflow/internal/domain"
)

func testStoreWithGenericTemplates(t *testing.T) *Store {
	t.Helper()
	s, err := OpenTest()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if err := SeedTestGenericTemplates(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestGenericTemplatesLiveInDedicatedTable(t *testing.T) {
	s := testStoreWithGenericTemplates(t)
	want := []string{GenericBackendDeliveryWorkflowID, GenericProductDeliveryWorkflowID, GenericFrontendDeliveryWorkflowID}
	for _, id := range want {
		if _, stored := payloadOne[domain.WorkflowDefinition](s.DB, "workflows", id); stored {
			t.Fatalf("generic template %q must not occupy the workflows table", id)
		}
		template, ok := s.GenericTemplateByWorkflow(id)
		if !ok || !template.Workflow.Generic || template.Workflow.ID != id {
			t.Fatalf("generic template %q missing from generic_templates: %+v", id, template)
		}
		if wf, ok := s.Workflow(id); !ok || !wf.Generic {
			t.Fatalf("store Workflow(%q) missed the generic_templates row", id)
		}
	}
	listed := s.Workflows()
	seen := 0
	for _, workflow := range listed {
		if workflow.Generic {
			seen++
		}
	}
	if seen < 3 {
		t.Fatalf("store listed %d generic workflows, want at least 3", seen)
	}
}

func TestUpdateGenericWorkflowGuardsStaleWritesAndKeepsHistory(t *testing.T) {
	s := testStoreWithGenericTemplates(t)
	before, ok := s.GenericWorkflowByID(GenericBackendDeliveryWorkflowID)
	if !ok {
		t.Fatal("backend template missing")
	}
	first := before
	first.Description = "admin A"
	saved, err := s.UpdateGenericWorkflow(first)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Revision != before.Revision+1 {
		t.Fatalf("revision = %d, want %d", saved.Revision, before.Revision+1)
	}
	stale := before
	stale.Description = "admin B"
	if _, err := s.UpdateGenericWorkflow(stale); err == nil || !strings.Contains(err.Error(), "revision conflict") {
		t.Fatalf("stale write error = %v, want revision conflict", err)
	}
	current, _ := s.GenericWorkflowByID(GenericBackendDeliveryWorkflowID)
	if current.Description != "admin A" {
		t.Fatalf("stale write overwrote the saved edit: %q", current.Description)
	}
	revisions := s.Revisions("workflow", GenericBackendDeliveryWorkflowID)
	if len(revisions) == 0 {
		t.Fatal("admin edit left no revision history to roll back to")
	}
}

func TestGenericTemplateRolesLiveInPlatformCatalog(t *testing.T) {
	s := testStoreWithGenericTemplates(t)
	template, ok := s.GenericTemplateByWorkflow(GenericBackendDeliveryWorkflowID)
	if !ok {
		t.Fatal("backend template missing")
	}
	if len(template.AgentRefs) == 0 {
		t.Fatal("template must reference the platform roles it orchestrates")
	}
	for _, ref := range template.AgentRefs {
		role, ok := s.Agent(ref.ID)
		if !ok {
			t.Fatalf("referenced role %q missing from the platform catalog", ref.ID)
		}
		if role.ProjectID != "" {
			t.Fatalf("referenced role %q is not a platform role: %+v", ref.ID, role)
		}
	}
}

func TestAgentRevisionReplaysAPinnedRole(t *testing.T) {
	s := testStoreWithGenericTemplates(t)
	base, ok := s.Agent(GenericAgentReview)
	if !ok {
		t.Fatal("review role missing")
	}
	current := base
	current.Prompt = "v2 prompt"
	current.Version = base.Version + 1
	if err := s.PutAgent(current); err != nil {
		t.Fatal(err)
	}
	pinned, ok := s.AgentRevision(GenericAgentReview, base.Version)
	if !ok {
		t.Fatal("archived revision missing")
	}
	if pinned.Prompt == "v2 prompt" {
		t.Fatalf("pinned revision returned the current definition: %+v", pinned)
	}
}

func TestPublishGenericWorkflow(t *testing.T) {
	s := testStoreWithGenericTemplates(t)
	before, _ := s.GenericWorkflowByID(GenericBackendDeliveryWorkflowID)
	before.Description += " updated"
	if _, err := s.UpdateGenericWorkflow(before); err != nil {
		t.Fatal(err)
	}
	published, err := s.PublishGenericWorkflow(GenericBackendDeliveryWorkflowID)
	if err != nil {
		t.Fatal(err)
	}
	if published.Status != "published" || published.Version != before.Version+1 {
		t.Fatalf("publish = %+v", published)
	}
}

func TestPublishFreezesReferencedRoleVersion(t *testing.T) {
	s := testStoreWithGenericTemplates(t)
	// The fixture ships as published; touch the workflow so publish has work.
	before, _ := s.GenericWorkflowByID(GenericBackendDeliveryWorkflowID)
	before.Description += " freeze"
	if _, err := s.UpdateGenericWorkflow(before); err != nil {
		t.Fatal(err)
	}
	role, ok := s.Agent(GenericAgentReview)
	if !ok {
		t.Fatal("review role missing")
	}
	template, ok := s.GenericTemplateByWorkflow(GenericBackendDeliveryWorkflowID)
	if !ok || len(template.AgentRefs) == 0 {
		t.Fatalf("template does not reference any role: %+v", template.AgentRefs)
	}
	if _, err := s.PublishGenericWorkflow(GenericBackendDeliveryWorkflowID); err != nil {
		t.Fatal(err)
	}
	published, _ := s.GenericTemplateByWorkflow(GenericBackendDeliveryWorkflowID)
	pin := 0
	for _, ref := range published.AgentRefs {
		if ref.ID == GenericAgentReview {
			pin = ref.Version
		}
	}
	if pin != role.Version {
		t.Fatalf("publish must pin the shipped role version: pin=%d role=%d", pin, role.Version)
	}

	// A later role edit must not move the pin of an already published SOP.
	role.Prompt = "post-release prompt"
	role.Version++
	if err := s.PutAgent(role); err != nil {
		t.Fatal(err)
	}
	after, _ := s.GenericTemplateByWorkflow(GenericBackendDeliveryWorkflowID)
	for _, ref := range after.AgentRefs {
		if ref.ID == GenericAgentReview && ref.Version != pin {
			t.Fatalf("published pin followed the role edit: got %d want %d", ref.Version, pin)
		}
	}
}
