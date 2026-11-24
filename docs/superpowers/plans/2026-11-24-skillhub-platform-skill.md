# SkillHub 安装落到平台技能库 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** SkillHub 安装改为落到平台技能库（`projectId=""`），项目侧只保留“从平台技能复制”和自建技能。

**架构：** 复用 `POST /api/skillhub/install`，`projectId` 改为可选：为空表示安装平台技能，需平台管理员；非空保留旧行为。平台共享页删除即卸载。前端市场页签仅平台管理员可见，安装成功切到「平台共享」。存量数据用一条可重复执行的手动 SQL 提升为平台技能。

**技术栈：** Go + Gin + MySQL（JSON payload 列）、原生 JS 前端（编进二进制）、`migrations/*.sql` 手动迁移。

规格：`docs/superpowers/specs/2026-11-24-skillhub-platform-skill-design.md`

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `internal/httpapi/skillhub_market.go` | install/update 的平台分支与权限 | 修改 |
| `internal/httpapi/catalog.go` | `DELETE /api/skills?id=` 平台技能权限预检 | 修改 |
| `internal/httpapi/skillhub_market_test.go` | 平台安装、重复安装、权限用例 | 修改 |
| `web/app/skillhub.js` | 市场门禁、已安装判定、平台文案、安装请求 | 修改 |
| `web/app/assets.js` | 市场/平台共享描述文案 | 修改 |
| `migrations/046_skillhub_promote_platform.sql` | 存量项目市场技能提升为平台技能 | 创建 |

---

## 任务 1：后端允许安装平台技能

**文件：**
- 修改：`internal/httpapi/skillhub_market.go:398-509`
- 测试：`internal/httpapi/skillhub_market_test.go:487-553`

- [ ] **步骤 1：编写失败的测试**

在 `internal/httpapi/skillhub_market_test.go` 的 `TestSkillhubInstallSnapshotsLatestAndHistoricalVersions` 之前插入：

```go
func TestSkillhubInstallPlatformSkill(t *testing.T) {
	f, s, h := newSkillhubTestServer(t, "")
	f.publish("team", "pdf-tools", "1.3.0", map[string]string{"SKILL.md": "# pdf"})

	rec := installSkillhub(t, h, map[string]any{"slug": "pdf-tools", "namespace": "team"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("platform install %d: %s", rec.Code, rec.Body.String())
	}
	skill := decodeSkillResponse(t, rec)
	if skill.ProjectID != "" || !skill.Shared {
		t.Fatalf("platform skill must have empty projectId and shared=true: %+v", skill)
	}
	if skill.Source == nil || skill.Source.Provider != "skillhub" || skill.Source.Version != "1.3.0" {
		t.Fatalf("platform skill source: %+v", skill.Source)
	}
	if _, ok := s.SkillFileContent("pdf-tools", "SKILL.md"); !ok {
		t.Fatal("platform skill files not stored")
	}

	if rec := installSkillhub(t, h, map[string]any{"slug": "pdf-tools", "namespace": "team", "id": "pdf-second"}); rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "平台已安装该技能") {
		t.Fatalf("duplicate platform install: %d %s", rec.Code, rec.Body.String())
	}
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`go test ./internal/httpapi/ -run 'TestSkillhubInstallPlatformSkill' -v`
预期：FAIL，输出包含 `platform install 400: {"error":"请先选择项目"}`

- [ ] **步骤 3：修改 install 的项目校验**

`internal/httpapi/skillhub_market.go` 中把：

```go
	projectID := strings.TrimSpace(input.ProjectID)
	if projectID == "" {
		c.JSON(http.StatusBadRequest, map[string]string{"error": "请先选择项目"})
		return
	}
	if _, exists := h.repo.Project(projectID); !exists {
		c.JSON(http.StatusNotFound, map[string]string{"error": "项目不存在"})
		return
	}
```

替换为：

```go
	// projectId 为空表示安装到平台技能库（内部 SkillHub），只有平台管理员可写；
	// 非空保留旧行为，供历史调用方按项目安装。
	projectID := strings.TrimSpace(input.ProjectID)
	if projectID == "" {
		if !h.requirePlatformAdmin(c) {
			return
		}
	} else if _, exists := h.repo.Project(projectID); !exists {
		c.JSON(http.StatusNotFound, map[string]string{"error": "项目不存在"})
		return
	}
```

- [ ] **步骤 4：修改 skill 落库标记**

同文件，把：

```go
	skill := domain.SkillDefinition{
		ID: id, Name: name, ProjectID: projectID,
```

替换为：

```go
	skill := domain.SkillDefinition{
		ID: id, Name: name, ProjectID: projectID, Shared: projectID == "",
```

- [ ] **步骤 5：修改冲突文案**

同文件 `installConflict`，整个函数体替换为：

```go
func (h *skillhubHandlers) installConflict(projectID, namespace, slug, id string) error {
	if existing, found := skillhubInstalled(h.repo.Skills(), projectID, namespace, slug); found {
		scope := "本项目"
		if projectID == "" {
			scope = "平台"
		}
		return HTTPError{Status: http.StatusConflict, Message: fmt.Sprintf("%s已安装该技能（标识 %s），如需新版本请使用更新", scope, existing.ID)}
	}
	if existing, found := h.repo.Skill(id); found {
		owner := "其他项目"
		switch {
		case strings.TrimSpace(existing.ProjectID) == "":
			owner = "平台"
		case existing.ProjectID == projectID:
			owner = "本项目"
		default:
			if p, ok := h.repo.Project(existing.ProjectID); ok && strings.TrimSpace(p.Name) != "" {
				owner = "项目「" + p.Name + "」"
			}
		}
		return HTTPError{Status: http.StatusConflict, Message: fmt.Sprintf("技能标识「%s」已被%s使用，请换一个", id, owner)}
	}
	return nil
}
```

- [ ] **步骤 6：运行新测试验证通过**

运行：`go test ./internal/httpapi/ -run 'TestSkillhubInstallPlatformSkill' -v`
预期：PASS

- [ ] **步骤 7：更新旧的冲突测试**

`internal/httpapi/skillhub_market_test.go` 的 `TestSkillhubInstallConflicts` 里，空 projectId 不再报 400。把：

```go
	for _, body := range []map[string]any{
		{"slug": "pdf-tools", "projectId": ""},
		{"slug": "../x", "projectId": "platform"},
```

改为：

```go
	for _, body := range []map[string]any{
		{"slug": "../x", "projectId": "platform"},
```

- [ ] **步骤 8：运行全部 SkillHub 测试**

运行：`go test ./internal/httpapi/ -run 'TestSkillhub' -v`
预期：全部 PASS

- [ ] **步骤 9：Commit**

```bash
git add internal/httpapi/skillhub_market.go internal/httpapi/skillhub_market_test.go
git commit -m "feat(skillhub): 安装接口支持落到平台技能库"
```

---

## 任务 2：平台技能的更新与删除要求平台管理员

**文件：**
- 修改：`internal/httpapi/skillhub_market.go:511-530`
- 修改：`internal/httpapi/catalog.go:748-757`
- 测试：`internal/httpapi/skillhub_market_test.go`

- [ ] **步骤 1：编写失败的测试**

在 `internal/httpapi/skillhub_market_test.go` 末尾追加：

```go
func TestSkillhubPlatformSkillWritesRequireAdmin(t *testing.T) {
	t.Setenv("AGENTFLOW_SCHEDULER_ENABLED", "false")
	f, s, h := newSkillhubTestServer(t, "")
	t.Setenv("AGENTFLOW_AUTH_REQUIRED", "true")
	f.publish("team", "pdf-tools", "1.3.0", map[string]string{"SKILL.md": "# pdf"})
	if err := s.PutProject(domain.Project{ID: "any", Key: "ANY", Name: "任意项目"}); err != nil {
		t.Fatal(err)
	}

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
	send := func(cookie *http.Cookie, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://localhost"+path, bytes.NewBufferString(body))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Origin", "http://localhost")
		r.AddCookie(cookie)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	boss, member := session("platform-boss"), session("plain-member")
	installBody := `{"slug":"pdf-tools","namespace":"team"}`

	if rec := send(member, "POST", "/api/skillhub/install", installBody); rec.Code != http.StatusForbidden {
		t.Fatalf("member install platform skill: %d %s", rec.Code, rec.Body.String())
	}
	rec := send(boss, "POST", "/api/skillhub/install", installBody)
	if rec.Code != http.StatusCreated {
		t.Fatalf("admin install platform skill: %d %s", rec.Code, rec.Body.String())
	}
	skill := decodeSkillResponse(t, rec)
	if skill.ProjectID != "" {
		t.Fatalf("platform skill project: %q", skill.ProjectID)
	}
	if rec := send(member, "POST", "/api/skillhub/update", `{"skillId":"`+skill.ID+`"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("member update platform skill: %d %s", rec.Code, rec.Body.String())
	}
	if rec := send(member, "DELETE", "/api/skills?id="+skill.ID, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("member delete platform skill: %d %s", rec.Code, rec.Body.String())
	}
	if rec := send(boss, "DELETE", "/api/skills?id="+skill.ID, ""); rec.Code != http.StatusNoContent {
		t.Fatalf("admin delete platform skill: %d %s", rec.Code, rec.Body.String())
	}
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`go test ./internal/httpapi/ -run 'TestSkillhubPlatformSkillWritesRequireAdmin' -v`
预期：FAIL，第一条断言为 `member install platform skill: 201`（普通成员被放行）

- [ ] **步骤 3：给 update 加平台管理员校验**

`internal/httpapi/skillhub_market.go` 的 `update` 中，把：

```go
	skillID := strings.TrimSpace(input.SkillID)
	skill, found := h.repo.Skill(skillID)
	if !found {
		c.JSON(http.StatusNotFound, map[string]string{"error": "skill not found"})
		return
	}
	if skill.Source == nil || skill.Source.Provider != domain.SkillSourceSkillHub {
```

替换为：

```go
	skillID := strings.TrimSpace(input.SkillID)
	skill, found := h.repo.Skill(skillID)
	if !found {
		c.JSON(http.StatusNotFound, map[string]string{"error": "skill not found"})
		return
	}
	// 平台技能（projectId 为空）由平台管理员维护，与平台共享资产的写权限一致。
	if strings.TrimSpace(skill.ProjectID) == "" && !h.requirePlatformAdmin(c) {
		return
	}
	if skill.Source == nil || skill.Source.Provider != domain.SkillSourceSkillHub {
```

- [ ] **步骤 4：给平台技能删除加管理员校验**

`internal/httpapi/catalog.go` 的 `skills` 方法中，把：

```go
	if c.Request.Method == http.MethodDelete {
		h.deleteCatalogAsset(c, "技能", "skill not found", func(id string) (bool, bool) {
```

替换为：

```go
	if c.Request.Method == http.MethodDelete {
		// 平台技能由平台管理员维护；项目技能沿用项目写权限。
		if item, ok := h.repo.Skill(strings.TrimSpace(c.Query("id"))); ok && strings.TrimSpace(item.ProjectID) == "" && !h.requirePlatformAdmin(c) {
			return
		}
		h.deleteCatalogAsset(c, "技能", "skill not found", func(id string) (bool, bool) {
```

- [ ] **步骤 5：运行测试验证通过**

运行：`go test ./internal/httpapi/ -run 'TestSkillhubPlatformSkillWritesRequireAdmin' -v`
预期：PASS

- [ ] **步骤 6：运行相关回归**

运行：`go test ./internal/httpapi/ -run 'TestSkillhub|TestProjectContentWritesRequireMembership' -v`
预期：全部 PASS

- [ ] **步骤 7：Commit**

```bash
git add internal/httpapi/skillhub_market.go internal/httpapi/catalog.go internal/httpapi/skillhub_market_test.go
git commit -m "feat(skillhub): 平台技能的更新与删除限平台管理员"
```

---

## 任务 3：前端市场入口与平台语义

**文件：**
- 修改：`web/app/skillhub.js:39-42`、`:80`、`:83-86`、`:133`、`:330-331`、`:391`、`:401`、`:437`、`:449`、`:455-456`、`:502`、`:510`
- 修改：`web/app/assets.js:35`、`:128`

- [ ] **步骤 1：已安装判定改为平台技能**

`web/app/skillhub.js` 中把：

```js
// Only skills owned by the current project count as installed; an empty
// namespace on either side matches, the same rule the server enforces.
function skillhubInstalledSkill(item,skills=state.data?.skills){
  if(!item?.slug)return null;
  return (skills||[]).find(s=>{const src=skillhubSourceOf(s);return !!src&&catalogOwned(s.projectId)&&src.slug===item.slug&&(!src.namespace||!item.namespace||src.namespace===item.namespace)})||null;
}
```

替换为：

```js
// 市场只出现在平台侧：平台已安装 = projectId 为空且来源是 skillhub。
// namespace 任一侧为空都视为匹配，与服务端 skillhubInstalled 规则一致。
function skillhubInstalledSkill(item,skills=state.data?.skills){
  if(!item?.slug)return null;
  return (skills||[]).find(s=>{const src=skillhubSourceOf(s);return !!src&&!String(s.projectId||'')&&src.slug===item.slug&&(!src.namespace||!item.namespace||src.namespace===item.namespace)})||null;
}
```

- [ ] **步骤 2：市场门禁改为平台管理员**

同文件 `skillhubSyncChrome`，把：

```js
  // SkillHub 只在平台侧（能力资产页）保留入口；项目侧技能只能新建或从平台技能复制，
  // 避免项目直接挂载市场技能、让平台技能与项目技能两套口径混在一起。
  const allowMarket=skills&&!state.assetHosted;
```

替换为：

```js
  // SkillHub 只在平台侧（能力资产页）对平台管理员开放：安装产物是平台技能，
  // 项目侧只能新建或从平台技能复制，避免两套口径混在一起。
  const allowMarket=skills&&!state.assetHosted&&isPlatformAdmin();
```

- [ ] **步骤 3：卡片状态徽标与安装按钮**

同文件 `skillhubCardHTML`，把：

```js
  const status=st.state==='installed'?skillhubBadge('success',`已安装 v${st.version}`,huiIcon('check'))
```

替换为：

```js
  const status=st.state==='installed'?skillhubBadge('success',`平台已安装 v${st.version}`,huiIcon('check'))
```

再把：

```js
  const noProject=!state.projectFilter;
  const action=st.state==='update'?`<button type="button" class="button small hui-btn-soft" data-skillhub-update="${index}">${huiIcon('refresh')}更新</button>`
    :st.state==='installed'?`<span class="asset-card-go">详情${huiIcon('chevron-right')}</span>`
    :`<button type="button" class="button small hui-btn-soft" data-skillhub-install="${index}"${noProject?' disabled title="请先选择项目"':''}>${huiIcon('plus')}安装</button>`;
```

替换为：

```js
  const noPermission=!isPlatformAdmin();
  const action=st.state==='update'?`<button type="button" class="button small hui-btn-soft" data-skillhub-update="${index}">${huiIcon('refresh')}更新</button>`
    :st.state==='installed'?`<span class="asset-card-go">详情${huiIcon('chevron-right')}</span>`
    :`<button type="button" class="button small hui-btn-soft" data-skillhub-install="${index}"${noPermission?' disabled title="只有平台管理员可以安装技能"':''}>${huiIcon('plus')}安装到平台</button>`;
```

- [ ] **步骤 4：抽屉按钮与徽标**

同文件 `skillhubDrawerActionHTML`，把：

```js
  if(st.state==='none'){
    const noProject=!state.projectFilter;
    return `<button type="button" class="button primary" data-skillhub-drawer-install${noProject?' disabled title="请先选择项目"':''}>${huiIcon('plus')}安装到本项目</button>`;
  }
```

替换为：

```js
  if(st.state==='none'){
    const noPermission=!isPlatformAdmin();
    return `<button type="button" class="button primary" data-skillhub-drawer-install${noPermission?' disabled title="只有平台管理员可以安装技能"':''}>${huiIcon('plus')}安装到平台</button>`;
  }
```

同文件版本行，把：

```js
const marks=(v.version===installedVersion?skillhubBadge('muted','本项目已安装'):'')
```

替换为：

```js
const marks=(v.version===installedVersion?skillhubBadge('muted','平台已安装'):'')
```

同文件抽屉徽标，把：

```js
  const installedBadge=st.state==='none'?'':st.state==='installed'?skillhubBadge('success','本项目已安装',huiIcon('check')):skillhubBadge('accent',`本项目 v${st.version}`);
```

替换为：

```js
  const installedBadge=st.state==='none'?'':st.state==='installed'?skillhubBadge('success','平台已安装',huiIcon('check')):skillhubBadge('accent',`平台 v${st.version}`);
```

- [ ] **步骤 5：安装入口拦截改为管理员判定**

同文件 `openSkillhubInstall`，把：

```js
  if(!state.projectFilter)return toast('请先选择项目','warn');
```

替换为：

```js
  if(!isPlatformAdmin())return toast('只有平台管理员可以安装技能','warn');
```

- [ ] **步骤 6：更新校验放行平台技能**

同文件 `openSkillhubUpdate`，把：

```js
  if(!catalogOwned(skill.projectId))return toast('只能更新本项目的技能','warn');
```

替换为：

```js
  if(String(skill.projectId||'')!==''&&!catalogOwned(skill.projectId))return toast('只能更新本项目或平台的技能','warn');
```

- [ ] **步骤 7：id 冲突提示支持平台**

同文件 `validateSkillhubModal`，把：

```js
  if(hit)return `技能标识「${v}」已被${catalogOwned(hit.projectId)?'本项目':`项目「${skillhubProjectName(hit.projectId)}」`}使用，请换一个`;
```

替换为：

```js
  if(hit)return `技能标识「${v}」已被${!String(hit.projectId||'')?'平台':`项目「${skillhubProjectName(hit.projectId)}」`}使用，请换一个`;
```

- [ ] **步骤 8：安装弹窗文案改为平台**

同文件 `renderSkillhubModal`：先运行 `grep -n "skillhubProjectName(state.projectFilter)" web/app/skillhub.js`，确认只有弹窗这一处，然后删除：

```js
  const project=skillhubProjectName(state.projectFilter);
```

再把：

```js
<h3 id="skillhubModalTitle">${m.mode==='install'?`安装「${escapeHTML(name)}」到本项目`:`更新「${escapeHTML(name)}」`}</h3><p class="skillhub-msub">${m.mode==='install'?`保存所选版本的快照到「${escapeHTML(project)}」，安装后可在「角色定义」里绑定。`:`当前已安装 v${escapeHTML(m.installed||'?')}，选择要更新到的版本。`}</p>
```

替换为：

```js
<h3 id="skillhubModalTitle">${m.mode==='install'?`安装「${escapeHTML(name)}」到平台`:`更新「${escapeHTML(name)}」`}</h3><p class="skillhub-msub">${m.mode==='install'?`保存所选版本的快照到平台技能库，项目在配置中按需复制使用。`:`当前平台已安装 v${escapeHTML(m.installed||'?')}，选择要更新到的版本。`}</p>
```

- [ ] **步骤 9：安装请求不带项目，成功后切到平台共享**

同文件 `submitSkillhubModal`，把：

```js
      saved=await api('/api/skillhub/install',{method:'POST',body:JSON.stringify({slug:m.slug,namespace:m.namespace,version:m.version,projectId:state.projectFilter,id:String(m.id).trim(),name:String(m.name||'').trim()})});
```

替换为：

```js
      saved=await api('/api/skillhub/install',{method:'POST',body:JSON.stringify({slug:m.slug,namespace:m.namespace,version:m.version,id:String(m.id).trim(),name:String(m.name||'').trim()})});
```

同函数成功分支，把：

```js
    if(m.mode==='install')toast(`已安装「${saved.name||saved.id}」，可在「本项目」中查看并绑定到角色`,'ok',4200);
```

替换为：

```js
    if(m.mode==='install'){state.skillScope='shared';toast(`已安装「${saved.name||saved.id}」到平台，项目配置中可复制使用`,'ok',4200);}
```

- [ ] **步骤 10：改市场与平台共享描述**

`web/app/assets.js:128` 把：

```js
  if($('#assetPageDescription'))$('#assetPageDescription').textContent=scope==='skillhub'?'从 SkillHub 搜索公开技能，查看质量评测与安全认证后安装到本项目。':scope==='shared'?assetSharedDescription():copy.desc;
```

替换为：

```js
  if($('#assetPageDescription'))$('#assetPageDescription').textContent=scope==='skillhub'?'从 SkillHub 安装技能到平台技能库；项目在配置中按需复制使用。':scope==='shared'?assetSharedDescription():copy.desc;
```

`web/app/assets.js:35` 把 skills 分支：

```js
type==='skills'?'平台技能由平台管理员集中维护，但不会自动对项目生效；项目需先把技能复制到本项目，才能绑定给角色。'
```

替换为：

```js
type==='skills'?'平台技能（含 SkillHub 安装来源）由平台管理员集中维护，不会自动对项目生效；项目需先把技能复制到本项目，才能绑定给角色。'
```

- [ ] **步骤 11：语法检查**

运行：`node --check web/app/skillhub.js && node --check web/app/assets.js`
预期：无输出、退出码 0

- [ ] **步骤 12：Commit**

```bash
git add web/app/skillhub.js web/app/assets.js
git commit -m "feat(skillhub): 市场入口限平台管理员并改为平台语义"
```

---

## 任务 4：存量项目市场技能提升为平台技能

**文件：**
- 创建：`migrations/046_skillhub_promote_platform.sql`

- [ ] **步骤 1：编写迁移脚本**

```sql
-- 把项目里从 SkillHub 安装的技能提升为平台技能（内部 SkillHub）。
--
-- 背景：改造前安装必须带 projectId，市场技能落在项目里；改造后安装产物是
-- projectId 为空的平台技能，项目侧只能复制快照。本脚本为存量项目技能补一份
-- 平台技能，并把项目行清掉 source，让它变成自足副本（id、角色绑定都不变）。
--
-- 可重复执行：平台行按 "<slug>"（被项目行占用时用 "<slug>-platform"）命名，
-- 已存在时跳过插入；项目行 source 清掉后不再被游标选中。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   docker exec -i zhiyan-mysql-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot zhiyan' \
--     < migrations/046_skillhub_promote_platform.sql

DROP PROCEDURE IF EXISTS migrate_skillhub_promote_platform;

DELIMITER $$

CREATE PROCEDURE migrate_skillhub_promote_platform()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_skill VARCHAR(64);
  DECLARE v_slug VARCHAR(128);
  DECLARE v_platform_id VARCHAR(64);
  DECLARE v_taken INT DEFAULT 0;

  DECLARE skill_cur CURSOR FOR
    SELECT s.id, json_unquote(json_extract(s.payload, '$.source.slug'))
      FROM skills s
     WHERE coalesce(json_unquote(json_extract(s.payload, '$.projectId')), '') <> ''
       AND json_unquote(json_extract(s.payload, '$.source.provider')) = 'skillhub'
       AND coalesce(json_unquote(json_extract(s.payload, '$.source.slug')), '') <> '';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  OPEN skill_cur;
  skill_loop: LOOP
    FETCH skill_cur INTO v_skill, v_slug;
    IF done THEN
      LEAVE skill_loop;
    END IF;

    -- 平台 id 上限 64 字符，超长时用摘要后缀避免截断碰撞。
    SET v_platform_id = v_slug;
    IF char_length(v_platform_id) > 64 THEN
      SET v_platform_id = concat(left(v_platform_id, 43), '-', substring(md5(v_platform_id), 1, 20));
    END IF;

    -- 同 id 被某个项目行占用时，平台行换后缀。
    SELECT count(*) INTO v_taken
      FROM skills
     WHERE id = v_platform_id
       AND coalesce(json_unquote(json_extract(payload, '$.projectId')), '') <> '';
    IF v_taken > 0 THEN
      SET v_platform_id = concat(left(v_slug, 48), '-platform');
      IF char_length(v_platform_id) > 64 THEN
        SET v_platform_id = concat(left(v_slug, 43), '-', substring(md5(v_slug), 1, 20));
      END IF;
    END IF;

    INSERT INTO skills (id, name, payload, updated_at)
    SELECT v_platform_id,
           s.name,
           json_set(s.payload, '$.id', v_platform_id, '$.projectId', '', '$.shared', true),
           now(3)
      FROM skills s
     WHERE s.id = v_skill
    ON DUPLICATE KEY UPDATE id = id;

    INSERT INTO skill_files (skill_id, path, content, size, sha256, unix_mode, updated_at)
    SELECT v_platform_id, f.path, f.content, f.size, f.sha256, f.unix_mode, now(3)
      FROM skill_files f
     WHERE f.skill_id = v_skill
    ON DUPLICATE KEY UPDATE skill_id = skill_id;

    UPDATE skills
       SET payload = json_remove(payload, '$.source'), updated_at = now(3)
     WHERE id = v_skill;
  END LOOP;
  CLOSE skill_cur;
END$$

DELIMITER ;

CALL migrate_skillhub_promote_platform();
DROP PROCEDURE migrate_skillhub_promote_platform;
```

- [ ] **步骤 2：在本地库执行**

```bash
docker exec -i zhiyan-mysql-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot zhiyan' < migrations/046_skillhub_promote_platform.sql
```

预期：无输出、退出码 0

- [ ] **步骤 3：校验迁移结果**

```bash
docker exec zhiyan-mysql-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -N -uroot zhiyan -e "SELECT id, json_unquote(json_extract(payload,\"\$.projectId\")) pid, json_unquote(json_extract(payload,\"\$.source.provider\")) prov FROM skills ORDER BY pid, id; SELECT skill_id, count(*) FROM skill_files GROUP BY skill_id ORDER BY skill_id;"'
```

预期（改造前是 4 条技能，其中 3 条属于 `ai-devop-agent`）：

- 平台行：3 个市场 slug，`pid` 为空、`prov=skillhub`
- 原平台手工技能：`pid` 为空、`prov` 为 `NULL`
- 项目行：`ai-devop-agent` 下同样的 3 个 id，`prov` 为 `NULL`
- 每个平台 id 在 `skill_files` 的文件数与源行一致

- [ ] **步骤 4：重跑验证幂等**

重复步骤 2 与步骤 3。
预期：`skills` 行数与 `skill_files` 文件数不变

- [ ] **步骤 5：Commit**

```bash
git add migrations/046_skillhub_promote_platform.sql
git commit -m "chore(migrations): 存量项目市场技能提升为平台技能"
```

---

## 任务 5：端到端验证

**文件：** 无代码改动，只验证。

- [ ] **步骤 1：编译与全量测试**

```bash
gofmt -l internal/ && go build ./... && go test ./internal/... 2>&1 | tail -20
```

预期：`gofmt -l` 无输出；build 与 test 全部 PASS

- [ ] **步骤 2：确认平台技能仍不参与运行时注入**

运行：`go test ./internal/engine/ -run 'Assets|Skill' -v`
预期：PASS（`projectId` 为空仍被跳过，本改造不改变这一点）

- [ ] **步骤 3：重编译 dev 运行**

```bash
./start.sh dev 2>&1 | tail -3
```

预期：构建成功。前端资源编进二进制，只重启容器不会生效。

- [ ] **步骤 4：手工验证清单（浏览器，`http://localhost:8090`）**

用平台管理员登录，逐条确认：

1. `AGENT 能力 → 能力资产 → 技能`：页签为「本项目 / 平台共享 / SkillHub 市场」，市场页签可见。
2. 市场页签描述为「从 SkillHub 安装技能到平台技能库；项目在配置中按需复制使用。」
3. 任选一个技能点「安装到平台」，弹窗标题含「到平台」，成功后自动切到「平台共享」，列表出现该技能且带来源徽标。
4. 返回市场页签，该技能卡片显示「平台已安装 v…」，按钮变为「详情」。
5. 「平台共享」里点该技能的「检查更新」，可正常请求（不提示“只能更新本项目的技能”）。
6. 进入任一项目 → 配置 → 技能：没有「SkillHub 市场」页签；「平台共享」页有「从平台技能复制」按钮。
7. 复制后项目「本项目」页出现副本，打开详情无市场来源卡片。
8. 平台共享页删除该技能：成功；回到项目，副本仍存在、内容不变。

非管理员账号登录后重复第 1 条：
预期：市场页签不可见；直接访问 `#skills?scope=skillhub` 会被切回「本项目」。

- [ ] **步骤 5：权限接口抽查**

在浏览器 devtools 里用非管理员账号执行：

```js
fetch('/api/skillhub/install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({slug:'pdf-tools',namespace:'team'})}).then(r=>r.status)
```

预期：`403`

- [ ] **步骤 6：确认工作区状态**

```bash
git status --short && git log --oneline -5
```

预期：本次改动都已提交，提交信息依次为任务 1-4 的 4 个 commit

---

## 自检结果

**规格覆盖度：**

| 规格条目 | 对应任务 |
|---|---|
| 平台技能 `projectId=""`、`shared=true` | 任务 1 步骤 3-4 |
| 安装仅平台管理员 | 任务 1 步骤 3、任务 2 步骤 1 |
| 项目侧无市场入口 | 任务 3 步骤 2 |
| 副本一次性快照（不变） | 无需改动，现有 `/api/skills/:id/copy` 已如此 |
| 平台分享页删除 = 卸载，限管理员 | 任务 2 步骤 4 |
| 平台技能更新限管理员 | 任务 2 步骤 3 |
| 市场已安装判定按平台 | 任务 3 步骤 1 |
| 安装成功切到平台共享 | 任务 3 步骤 9 |
| 文案平台化 | 任务 3 步骤 3-4、8、10 |
| 存量迁移 046 | 任务 4 |
| 验证 | 任务 5 |

**类型一致性：** `installConflict` 的签名与调用点一致（`projectID, namespace, slug, id`）；`skillhubInstalled` 在 `projectID == ""` 时严格匹配平台行，无需改；前端 `isPlatformAdmin()`、`catalogOwned()`、`state.skillScope` 均为既有定义。

**已知边界：** 迁移脚本按 slug 建平台行，若平台已存在同 slug 但来源不同的技能，以已存在行为准、不覆盖；`projectId` 非空的安装路径保留，历史调用方不受影响。
