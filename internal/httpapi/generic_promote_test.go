package httpapi

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"agentflow/internal/domain"
	"agentflow/internal/engine"
	"agentflow/internal/repo"
	"agentflow/internal/runtime"
	"agentflow/internal/tracker"
)

// promoteFixture 准备一个项目、一个平台管理员和一台带引擎的服务实例。
func promoteFixture(t *testing.T) (http.Handler, domain.User, domain.User, *repo.Store) {
	t.Helper()
	t.Setenv("AGENTFLOW_SESSION_SECRET", "promote-test-session-secret")
	st, err := repo.OpenTest()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(st.Close)
	if err := st.PutUser(domain.User{LoginName: "promote-owner"}); err != nil {
		t.Fatal(err)
	}
	owner, _ := st.UserByLoginName("promote-owner")
	if err := st.PutProject(domain.Project{ID: "promote-proj", Name: "Promote", OwnerID: owner.ID}); err != nil {
		t.Fatal(err)
	}
	if err := st.PutUser(domain.User{LoginName: "promote-admin"}); err != nil {
		t.Fatal(err)
	}
	admin, _ := st.UserByLoginName("promote-admin")
	if _, err := st.GrantPlatformAdmin(admin.LoginName); err != nil {
		t.Fatal(err)
	}
	api := New(st, engine.New(st, runtime.NewManager(filepath.Join(t.TempDir(), "workspaces"))), tracker.NewService(), "", "")
	return api, owner, admin, st
}

func seedPromotableSOP(t *testing.T, st *repo.Store) {
	t.Helper()
	if err := st.PutSandbox(domain.SandboxProfile{ID: "shared-sb", Name: "共享沙箱", Shared: true, Driver: "local"}); err != nil {
		t.Fatal(err)
	}
	if err := st.PutAgent(domain.AgentDefinition{ID: "role-a", Name: "实现角色", ProjectID: "promote-proj"}); err != nil {
		t.Fatal(err)
	}
	if err := st.PutWorkflow(domain.WorkflowDefinition{
		ID: "sop-a", Name: "项目 SOP", ProjectID: "promote-proj", SandboxProfileID: "shared-sb", Status: "active",
		Nodes: []domain.WorkflowNode{{ID: "n1", Type: "agent", AgentID: "role-a"}},
	}); err != nil {
		t.Fatal(err)
	}
}

func TestPromoteSOPToPlatformBundlesRoles(t *testing.T) {
	api, _, admin, st := promoteFixture(t)
	seedPromotableSOP(t, st)

	req := httptest.NewRequest(http.MethodPost, "/api/workflows/sop-a/promote", strings.NewReader(`{"id":"generic-promoted","name":"平台版 SOP","owner":"平台"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	api.ServeHTTP(rec, authedRequest(t, req, admin))
	if rec.Code != http.StatusCreated {
		t.Fatalf("promote: %d %s", rec.Code, rec.Body.String())
	}

	template, ok := st.GenericTemplateByWorkflow("generic-promoted")
	if !ok {
		t.Fatal("promoted template is missing from the platform catalog")
	}
	if len(template.Agents) != 1 || template.Agents[0].ID != "role-a" || template.Agents[0].ProjectID != "" {
		t.Fatalf("roles were not bundled into the template: %+v", template.Agents)
	}
	if template.Workflow.ProjectID != "" || !template.Workflow.Generic {
		t.Fatalf("promoted workflow must be platform scoped: %+v", template.Workflow)
	}
	if _, ok := st.Workflow("sop-a"); !ok {
		t.Fatal("the project SOP must be kept after promotion")
	}
}

func TestPromoteSOPRequiresPlatformAdmin(t *testing.T) {
	api, owner, _, st := promoteFixture(t)
	seedPromotableSOP(t, st)

	req := httptest.NewRequest(http.MethodPost, "/api/workflows/sop-a/promote", strings.NewReader(`{"id":"generic-promoted","name":"平台版 SOP"}`))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	api.ServeHTTP(rec, authedRequest(t, req, owner))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin promote: %d %s", rec.Code, rec.Body.String())
	}
	if _, ok := st.GenericTemplateByWorkflow("generic-promoted"); ok {
		t.Fatal("a non-admin promote must not create a template")
	}
}

func TestCreatePlatformSOPRequiresAdmin(t *testing.T) {
	api, owner, admin, st := promoteFixture(t)
	if err := st.PutSandbox(domain.SandboxProfile{ID: "shared-sb", Name: "共享沙箱", Shared: true, Driver: "local"}); err != nil {
		t.Fatal(err)
	}
	body := `{"id":"generic-new","name":"新平台 SOP","generic":true,"sandboxProfileId":"shared-sb","nodes":[],"edges":[]}`

	req := httptest.NewRequest(http.MethodPut, "/api/workflows", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	api.ServeHTTP(rec, authedRequest(t, req, owner))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("non-admin create: %d %s", rec.Code, rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodPut, "/api/workflows", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec = httptest.NewRecorder()
	api.ServeHTTP(rec, authedRequest(t, req, admin))
	if rec.Code != http.StatusCreated {
		t.Fatalf("admin create: %d %s", rec.Code, rec.Body.String())
	}
	if _, ok := st.GenericTemplateByWorkflow("generic-new"); !ok {
		t.Fatal("the platform SOP was not written to generic_templates")
	}
	var physical int64
	if err := st.DB.Table("workflows").Where("id = ?", "generic-new").Count(&physical).Error; err != nil {
		t.Fatal(err)
	}
	if physical != 0 {
		t.Fatal("a platform SOP must not land in the project workflows table")
	}
}
