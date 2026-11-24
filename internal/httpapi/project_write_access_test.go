package httpapi

import (
	"agentflow/internal/domain"
	"agentflow/internal/engine"
	"agentflow/internal/repo"
	"agentflow/internal/runtime"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestProjectContentWritesRequireMembership(t *testing.T) {
	t.Setenv("AGENTFLOW_AUTH_REQUIRED", "true")
	t.Setenv("AGENTFLOW_SCHEDULER_ENABLED", "false")
	s, err := repo.OpenTest()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	h := New(s, engine.New(s, runtime.NewManager(t.TempDir())), nil, "", "")
	session := func(login string) *http.Cookie {
		r := httptest.NewRequest("POST", "http://localhost/api/auth/register", bytes.NewBufferString(`{"login":"`+login+`","password":"secret1"}`))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", "http://localhost")
		r.RemoteAddr = "192.0.2.10:1234"
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 200 || len(w.Result().Cookies()) != 1 {
			t.Fatalf("register %s: %d %s", login, w.Code, w.Body.String())
		}
		return w.Result().Cookies()[0]
	}
	request := func(cookie *http.Cookie, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://localhost"+path, bytes.NewBufferString(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", "http://localhost")
		r.AddCookie(cookie)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	call := func(cookie *http.Cookie, method, path, body string) int {
		return request(cookie, method, path, body).Code
	}
	admin := session("admin")
	owner, member, viewer, other := session("owner"), session("member"), session("viewer"), session("other")
	ownerUser, _ := s.UserByLoginName("owner")
	memberUser, _ := s.UserByLoginName("member")
	viewerUser, _ := s.UserByLoginName("viewer")
	if err := s.PutProject(domain.Project{ID: "p1", Name: "P1", OwnerID: ownerUser.ID, Members: []domain.ProjectMember{
		{UserID: memberUser.ID, Role: "member"}, {UserID: viewerUser.ID, Role: "viewer"},
	}}); err != nil {
		t.Fatal(err)
	}
	if err := s.PutProject(domain.Project{ID: "shared", Name: "Shared"}); err != nil {
		t.Fatal(err)
	}

	issue := fmt.Sprintf(`{"id":"i1","projectId":"p1","title":"Fix login","assigneeUserId":%d}`, ownerUser.ID)
	if code := call(other, "POST", "/api/issues", issue); code != 403 {
		t.Fatalf("non-member create issue: %d", code)
	}
	if code := call(viewer, "POST", "/api/issues", issue); code != 403 {
		t.Fatalf("viewer create issue: %d", code)
	}
	if code := call(member, "POST", "/api/issues", issue); code != 200 {
		t.Fatalf("member create issue: %d", code)
	}
	t.Run("clarification catalog uses the responsible account", func(t *testing.T) {
		const path = "/api/issues/i1/clarify-models"
		models := []domain.CLIModel{{ID: "owner-model"}}
		const key = "owner-test-key"
		if _, err := s.UpdateUserCredentials(ownerUser.ID, repo.UserCredentialUpdate{CodexAPIKey: key, CodexModels: &models}); err != nil {
			t.Fatal(err)
		}
		for _, cookie := range []*http.Cookie{other, viewer} {
			if code := call(cookie, "GET", path, ""); code != 403 {
				t.Fatalf("clarification catalog requires project write access: %d", code)
			}
		}
		w := request(member, "GET", path, "")
		if w.Code != 200 || bytes.Contains(w.Body.Bytes(), []byte(key)) {
			t.Fatalf("invalid clarification catalog response: %d", w.Code)
		}
		var catalog assistantModelCatalog
		if err := json.Unmarshal(w.Body.Bytes(), &catalog); err != nil {
			t.Fatal(err)
		}
		if len(catalog.Models) != 1 || catalog.Models[0].ID != "codex:owner-model" {
			t.Fatalf("want the project owner's model: %+v", catalog.Models)
		}
	})
	if code := call(other, "PUT", "/api/issues", `{"id":"i1","projectId":"p1","title":"Hijacked"}`); code != 403 {
		t.Fatalf("non-member edit issue: %d", code)
	}
	if code := call(other, "POST", "/api/issues/i1/close", `{}`); code != 403 {
		t.Fatalf("non-member close issue: %d", code)
	}
	if saved, _ := s.Issue("i1"); saved.Title != "Fix login" || saved.Status == "closed" {
		t.Fatalf("issue changed by a non-member: %+v", saved)
	}
	if code := call(other, "POST", "/api/issues", `{"projectId":"shared","title":"Shared idea"}`); code != 200 {
		t.Fatalf("ownerless projects stay shared: %d", code)
	}

	submission := `{"projectId":"p1","title":"Runbook","content":"restart the worker"}`
	if code := call(other, "POST", "/api/knowledge/submissions", submission); code != 403 {
		t.Fatalf("non-member submits knowledge to p1: %d", code)
	}
	if code := call(viewer, "POST", "/api/knowledge/submissions", submission); code != 403 {
		t.Fatalf("viewer submits knowledge to p1: %d", code)
	}
	if code := call(member, "POST", "/api/knowledge/submissions", submission); code == 403 {
		t.Fatal("members may submit knowledge to their project")
	}
	if code := call(other, "POST", "/api/knowledge/submissions", `{"title":"Note","content":"no project"}`); code == 403 {
		t.Fatal("project-less submissions are not project content")
	}

	agent := `{"id":"a1","projectId":"p1","name":"Dev","instructions":"build"}`
	if code := call(other, "PUT", "/api/agents", agent); code != 403 {
		t.Fatalf("non-member write agent: %d", code)
	}
	if code := call(owner, "PUT", "/api/agents", agent); code != 200 {
		t.Fatalf("owner write agent: %d", code)
	}
	if code := call(other, "DELETE", "/api/agents/a1", ""); code != 403 {
		t.Fatalf("non-member delete agent: %d", code)
	}
	if code := call(other, "POST", "/api/agents/a1/clone", `{"id":"a1","name":"Mine","projectId":"shared"}`); code != 403 {
		t.Fatalf("clone must not overwrite another project's agent: %d", code)
	}
	if saved, _ := s.Agent("a1"); saved.ProjectID != "p1" || saved.Name != "Dev" {
		t.Fatalf("agent changed by a non-member: %+v", saved)
	}
	// 平台共享角色（projectId 为空）对所有项目可用，只有平台管理员能维护。
	platformAgent := `{"id":"pa-global","name":"Global","projectId":""}`
	if code := call(other, "PUT", "/api/agents", platformAgent); code != 403 {
		t.Fatalf("non-admin writes platform agent: %d", code)
	}
	if code := call(admin, "PUT", "/api/agents", platformAgent); code != 200 {
		t.Fatalf("admin writes platform agent: %d", code)
	}
	if code := call(admin, "DELETE", "/api/agents/pa-global", ""); code != 204 {
		t.Fatalf("admin deletes platform agent: %d", code)
	}
	// 平台共享规则同理：普通项目成员不能写，平台管理员可以。
	platformRule := `{"id":"pa-global-rule","name":"Global rule","projectId":""}`
	if code := call(other, "PUT", "/api/rules", platformRule); code != 403 {
		t.Fatalf("non-admin writes platform rule: %d", code)
	}
	if code := call(admin, "PUT", "/api/rules", platformRule); code != 200 {
		t.Fatalf("admin writes platform rule: %d", code)
	}
	if code := call(admin, "DELETE", "/api/rules?id=pa-global-rule", ""); code != 204 {
		t.Fatalf("admin deletes platform rule: %d", code)
	}
	// 平台规则按 shared=true 落库（运行时跨项目可见依赖它），但不再因此拒绝删除。
	sharedPlatformRule := `{"id":"pa-shared-rule","name":"Shared platform rule","projectId":"","shared":true}`
	if code := call(admin, "PUT", "/api/rules", sharedPlatformRule); code != 200 {
		t.Fatalf("admin writes shared platform rule: %d", code)
	}
	if saved, ok := s.Rule("pa-shared-rule"); !ok || !saved.Shared || saved.ProjectID != "" {
		t.Fatalf("platform rule must persist shared=true: %+v", saved)
	}
	if code := call(other, "DELETE", "/api/rules?id=pa-shared-rule", ""); code != 403 {
		t.Fatalf("non-admin deletes shared platform rule: %d", code)
	}
	if code := call(admin, "DELETE", "/api/rules?id=pa-shared-rule", ""); code != 204 {
		t.Fatalf("admin deletes shared platform rule: %d", code)
	}
	// 不带 shared 的平台规则也会被归一为共享。
	if code := call(admin, "PUT", "/api/rules", `{"id":"pa-normalized","name":"Normalized","projectId":""}`); code != 200 {
		t.Fatalf("admin writes normalized platform rule: %d", code)
	}
	if saved, ok := s.Rule("pa-normalized"); !ok || !saved.Shared {
		t.Fatalf("platform rule shared must be normalized to true: %+v", saved)
	}
	if code := call(admin, "DELETE", "/api/rules?id=pa-normalized", ""); code != 204 {
		t.Fatalf("admin deletes normalized platform rule: %d", code)
	}
	// 平台技能：shared 归一后仍可删除。
	if code := call(admin, "PUT", "/api/skills", `{"id":"pa-skill","name":"Platform skill","projectId":"","shared":true}`); code != 200 {
		t.Fatalf("admin writes shared platform skill: %d", code)
	}
	if saved, ok := s.Skill("pa-skill"); !ok || !saved.Shared || saved.ProjectID != "" {
		t.Fatalf("platform skill must persist shared=true: %+v", saved)
	}
	if code := call(other, "DELETE", "/api/skills?id=pa-skill", ""); code != 403 {
		t.Fatalf("non-admin deletes shared platform skill: %d", code)
	}
	if code := call(admin, "DELETE", "/api/skills?id=pa-skill", ""); code != 204 {
		t.Fatalf("admin deletes shared platform skill: %d", code)
	}
	// 平台产物模板同理。
	if code := call(admin, "PUT", "/api/artifact-templates", `{"id":"pa-template","name":"Platform template","projectId":"","content":"## 目标\n说明"}`); code != 200 {
		t.Fatalf("admin writes shared platform template: %d", code)
	}
	if saved, ok := s.ArtifactTemplate("pa-template"); !ok || !saved.Shared || saved.ProjectID != "" {
		t.Fatalf("platform template must persist shared=true: %+v", saved)
	}
	if code := call(other, "DELETE", "/api/artifact-templates?id=pa-template", ""); code != 403 {
		t.Fatalf("non-admin deletes shared platform template: %d", code)
	}
	if code := call(admin, "DELETE", "/api/artifact-templates?id=pa-template", ""); code != 204 {
		t.Fatalf("admin deletes shared platform template: %d", code)
	}
	// 技能按项目隔离：平台技能不会自动生效，项目角色必须先复制一份到本项目。
	source := domain.SkillDefinition{ID: "pa-copy-src", Name: "Platform skill", ProjectID: ""}
	if err := s.PutSkillSnapshot(source, []repo.SkillFileInput{{Path: "SKILL.md", Content: []byte("# 平台技能"), Mode: 0o644}}, true); err != nil {
		t.Fatal(err)
	}
	if code := call(owner, "POST", "/api/skills/pa-copy-src/copy", `{"projectId":"p1"}`); code != 201 {
		t.Fatalf("owner copies platform skill into project: %d", code)
	}
	copied, ok := s.Skill("pa-copy-src-copy")
	if !ok || copied.ProjectID != "p1" || copied.Shared || copied.Name != "Platform skill" {
		t.Fatalf("copied skill = %+v (ok=%v)", copied, ok)
	}
	if content, found := s.SkillFileContent("pa-copy-src-copy", "SKILL.md"); !found || string(content) != "# 平台技能" {
		t.Fatalf("copied skill files = %q (found=%v)", content, found)
	}
	if code := call(other, "POST", "/api/skills/pa-copy-src/copy", `{"projectId":"p1"}`); code != 403 {
		t.Fatalf("non-member copies platform skill: %d", code)
	}
	if code := call(owner, "POST", "/api/skills/pa-copy-src/copy", `{"projectId":"missing"}`); code != 404 {
		t.Fatalf("copy into missing project: %d", code)
	}

	if err := s.PutRun(domain.Run{ID: "r1", Status: "succeeded", ExecutionContext: domain.TelemetryContext{ProjectID: "p1"}, Nodes: map[string]*domain.NodeRun{}}); err != nil {
		t.Fatal(err)
	}
	if code := call(other, "POST", "/api/runs/r1/cancel", `{}`); code != 403 {
		t.Fatalf("non-member cancel run: %d", code)
	}
	if code := call(other, "POST", "/api/runs/r1/workspace/terminal", `{"command":"id"}`); code != 403 {
		t.Fatalf("non-member terminal: %d", code)
	}
	if code := call(other, "DELETE", "/api/runs/r1", ""); code != 403 {
		t.Fatalf("non-member delete run: %d", code)
	}
	if code := call(member, "DELETE", "/api/runs/r1", ""); code != 200 {
		t.Fatalf("member delete run: %d", code)
	}

	rule := `{"id":"rule1","projectId":"p1","name":"Style","content":"gofmt"}`
	if code := call(other, "PUT", "/api/rules", rule); code != 403 {
		t.Fatalf("non-member write rule: %d", code)
	}
	if code := call(owner, "PUT", "/api/rules", rule); code != 200 {
		t.Fatalf("owner write rule: %d", code)
	}
	if code := call(other, "DELETE", "/api/rules?id=rule1", ""); code != 403 {
		t.Fatalf("non-member delete rule: %d", code)
	}
	if code := call(owner, "PUT", "/api/rules", `{"id":"rule1-shared","projectId":"p1","name":"Shared","shared":true}`); code != 200 {
		t.Fatalf("owner writes shared project rule: %d", code)
	}
	if code := call(owner, "DELETE", "/api/rules?id=rule1-shared", ""); code != 409 {
		t.Fatalf("shared project rule must stay undeletable: %d", code)
	}
	// 平台规则被角色引用时同样要拦住。
	if code := call(admin, "PUT", "/api/rules", `{"id":"pa-referenced","name":"Referenced","projectId":""}`); code != 200 {
		t.Fatalf("admin writes referenced platform rule: %d", code)
	}
	if code := call(owner, "PUT", "/api/agents", `{"id":"a-ref","projectId":"p1","name":"Dev","instructions":"x","rules":["pa-referenced"]}`); code != 200 {
		t.Fatalf("owner binds platform rule: %d", code)
	}
	if code := call(admin, "DELETE", "/api/rules?id=pa-referenced", ""); code != 409 {
		t.Fatalf("referenced platform rule must stay undeletable: %d", code)
	}
	if err := s.PutDockerfile(domain.DockerfileDefinition{ID: "df-global", Name: "Base", Content: "FROM alpine"}); err != nil {
		t.Fatal(err)
	}
	if code := call(owner, "PUT", "/api/dockerfiles", `{"id":"df-global","name":"Base","content":"FROM evil"}`); code != 403 {
		t.Fatalf("non-admin edit platform dockerfile: %d", code)
	}
	if code := call(other, "PUT", "/api/sync/config", `{}`); code != 403 {
		t.Fatalf("non-admin sync config: %d", code)
	}
	if code := call(other, "POST", "/api/mcp-servers/custom", `{"scope":"project","projectId":"p1","server":{"id":"m1","name":"M","transport":"http","url":"https://example.com/mcp"}}`); code != 403 {
		t.Fatalf("non-member install project MCP: %d", code)
	}
}
