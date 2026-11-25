# 平台角色定义与平台 SOP 解耦

状态：已确认，按阶段落地
创建：2026-11-25

## 1. 背景

平台侧三块内容本应彼此解耦：

| 层 | 负责 | 权威存储 |
|---|---|---|
| 平台角色定义 | Agent 自身：prompt、规则、技能、产物契约、门禁、hook、loop、模型 | `agents`（`projectId=''`） |
| 平台能力资产 | 规则、技能、产物模板、MCP、沙箱 | `rules` / `skills` / `artifact_templates` / `mcp_servers` / `sandboxes`（`projectId=''`） |
| 平台 SOP | 只做编排：节点、边、返工目标、人工闸口、沙箱 | `generic_templates.payload.Workflow` |

项目侧从平台复制一份副本，两套数据解耦演进。

实际实现里，角色这层被内联进了 SOP：

```82:87:internal/repo/generic_workflows.go
// GenericTemplate bundles a project-independent SOP with the roles it needs.
type GenericTemplate struct {
	Workflow domain.WorkflowDefinition
	Agents   []domain.AgentDefinition
```

由此产生三个后果：

1. **角色定义有两份**。`payload.Agents` 是完整副本，与 `agents` 表各自演化，且 `payload` 那份明显滞后（见 §3）。
2. **复制源取错了位置**。`cloneGenericTemplateAgents` 读 `GenericTemplateByWorkflow`，即 `payload`，因此在角色定义页改平台角色对复制结果毫无影响。
3. **设计器成了角色的第二编辑入口**。`PUT /api/workflows/:id/agents` 写的是 `payload.Agents`，角色定义页反而成了摆设。

而运行时从第一天起就是引用模型：`repo.Agent(agentID)` 只查 `agents` 表，adopt 必须把角色复制成项目角色才能跑。**行为模型是引用 + 复制，只有存储和编辑器被改成了内联。**

这也和官方文档一致：

> Agent 节点只引用角色定义，任务说明写在角色的 `prompt` 上。
> 源 SOP 是通用模板时，复制会同时把模板**引用的**角色创建到项目。

## 2. 目标模型与不变式

```
平台角色库 (agents, projectId='')
  ↑ 引用
平台 SOP (generic_templates.payload = { Workflow, AgentRefs })
  ↓ 复制
项目副本 (agents/rules/skills projectId=<pid>, workflows 物理行)
```

实施后必须成立的五条不变式，同时作为验收口径：

1. 角色的定义只有一份权威副本，在 `agents` 表；`generic_templates.payload` 不存角色定义。
2. 平台 SOP 的每个 agent 节点通过 `AgentRefs` 引用平台角色；保存时引用的角色不存在则失败。
3. adopt 只做「按引用取定义 → 复制成项目副本 → 重写节点绑定」，取不到就报错，不回退。
4. 项目内已存在的同名角色一律复用，不覆盖（沿用 `genericAssetIDCandidates`）。
5. 角色保存后，引用它的平台 SOP 能查到影响面。

## 3. 现状体检

2026-11-25 对现网库执行（脚本见附录 A）：

**A. 节点引用能否在平台角色库解析**

| 模板 | 节点角色 | 状态 |
|---|---|---|
| `generic-backend-delivery` | 7 个 | 全部 OK（`042` 已提升） |
| `generic-frontend-delivery` | 7 个 | 全部 MISSING_ROLE |
| `generic-harness-delivery` | clarify/design/readiness/implement/review/test（6 个） | 全部 MISSING_ROLE |
| `generic-harness-delivery` | mr / deliver（2 个） | OK（复用 backend 平台角色） |
| `generic-product-delivery` | 4 个 | 全部 MISSING_ROLE |
| `issue-fix-production` | 7 个 | 全部 MISSING_ROLE |

结论：`payload.Agents` 目前是 4 个内置模板角色的**唯一**数据源，必须先回填到 `agents` 表再改代码。

**B. payload 内联版与平台版的冲突面**

同 id 冲突只出现在 backend 与 harness 的 `mr`/`deliver`：

| 角色 | 内联 version | 平台 version | 差异 |
|---|---|---|---|
| `generic-backend-delivery-clarify` | 2 | 3 | rules 不同，平台版更新 |
| `generic-backend-delivery-review` | 2 | 1 | 平台版是重写过的 |
| `generic-backend-delivery-deliver` | 1 | 1 | rules：`public-engineering` vs `public-engineering-welcome` |
| `generic-backend-delivery-mr` | 1 | 1 | 同上；门禁两边完全一致（`mr-opened`、`mr-pushed`） |

门禁一致，只有规则引用不同，因此**统一以平台版为准，不做内容合并**。

**C. 内联规则 / 技能的回填缺口**

| kind | 资产 | 状态 |
|---|---|---|
| rule | `public-engineering` | EXISTS |
| rule | `public-product-documents` | MISSING |
| rule | `harness-separation` / `harness-evidence` / `harness-minimal-diff` / `harness-no-side-effect` | MISSING |
| skill | `readiness-review` | MISSING |

## 4. 数据结构变更

```go
// GenericAgentRef pins one platform role used by the SOP.
// Version 0 means "follow the latest definition of the role".
type GenericAgentRef struct {
	ID      string `json:"id"`
	Version int    `json:"version,omitempty"`
}

type GenericTemplate struct {
	Workflow  domain.WorkflowDefinition
	AgentRefs []GenericAgentRef

	// Deprecated: legacy bundled copies. Kept only so stored blobs still decode
	// and so migration 052 can read them; never used as an adoption source.
	Agents []domain.AgentDefinition `json:"Agents,omitempty"`
	Rules  []domain.RuleDefinition  `json:"Rules,omitempty"`
	Skills []domain.SkillDefinition `json:"Skills,omitempty"`

	VerdictGateSeedVersion int
	PlaybookSeedVersion    int
}
```

`AgentDefinition` 增加一个**只读、不落库**的计算字段：

```go
// SourceTemplateIDs lists the platform SOPs referencing this role.
SourceTemplateIDs []string `json:"sourceTemplateIds,omitempty"`
```

由 `CatalogRepo.Agents()` 读取时反查 `generic_templates`，避免引用关系变成第二个存储。

## 5. 后端改动

### 5.1 repo 层（`internal/repo/`）

| 改动 | 文件 | 说明 |
|---|---|---|
| `GenericAgentRef` + `AgentRefs` | `generic_workflows.go` | 见 §4 |
| `AgentAtRevision(id, version)` | `catalog.go` | 从 `definition_revisions` 取 `kind='agent'` 的历史快照 |
| `PlatformAgents()` | `catalog.go` | `Agents()` 过滤 `ProjectID == ""` |
| `TemplatesReferencingAgent(id)` | `generic_store.go` | 遍历模板返回引用者，供不变式 5 |
| 填充 `SourceTemplateIDs` | `catalog.go` `Agents()` | 读取时计算 |
| 删除 `UpdateGenericAgent` | `generic_store.go` | 不再有模板私有角色 |

`PutAgent` 已有版本快照能力，无需改动：

```104:108:internal/repo/catalog.go
	if old, ok := r.Agent(v.ID); ok {
		v.ProjectID = domain.KeepCatalogProjectID(v.ProjectID, old.ProjectID)
		if err := r.snapshotRevision("agent", old.ID, old.Name, old.Version, 0, old); err != nil {
```

### 5.2 handler 层（`internal/httpapi/generic_workflows.go`）

新增统一解析入口：

```go
// resolveTemplateAgents returns the platform roles a template orchestrates.
// Priority: AgentRefs -> node bindings. Legacy payload.Agents is no longer read.
func (h *catalogHandlers) resolveTemplateAgents(t repo.GenericTemplate) ([]domain.AgentDefinition, error)
```

规则：

- 按 `Workflow.Nodes` 出现顺序去重，跳过 `domain.IsPreviewBuildAgent`。
- `repo.Agent(id)` 取不到，或 `ProjectID != ""` → 返回错误，adopt 中止，不写半成品。
- `AgentRefs` 中 `Version > 0` 且与当前 version 不同 → 用 `AgentAtRevision` 取快照；快照已被裁剪（`maxRevisionsPerEntity = 20`）则用最新版并在响应里带 drift 提示。

`cloneGenericTemplateAgents` 的复制/复用/remap 逻辑保留，只换数据源：

```33:36:internal/httpapi/generic_workflows.go
	agents, err := h.cloneGenericTemplateAgents(template.ID, projectID)
```

`cloneGenericTemplateRules` / `cloneGenericTemplateSkills` 同样改为按角色引用的 id 去平台 `rules`/`skills` 取，不再读 `payload.Rules/Skills`。

### 5.3 `promoteWorkflow` 语义反转

现在是「把项目角色打包进模板」，改为「把项目角色登记为平台角色，模板只记引用」：

1. 遍历 agent 节点，`repo.Agent(id)` 取角色；
2. `ProjectID != ""` → 写一份 `projectId=''`, `shared=true` 的平台角色，id 沿用；若 id 已被平台角色占用且内容不同 → `409` 并列出差异，不静默覆盖；
3. 校验引用的规则 / 技能在平台库存在，缺失则 `400`；
4. 模板只写 `Workflow + AgentRefs`。

与 `migrations/046_skillhub_promote_platform.sql`（项目技能 → 平台技能）语义一致。

### 5.4 端点调整

| 端点 | 调整 |
|---|---|
| `GET /api/workflows/:id/agents` | 返回 `resolveTemplateAgents` 结果，前端零改动 |
| `PUT /api/workflows/:id/agents` | **退役**，返回 `409`，提示去「设置 › 角色定义」修改 |
| `GET /api/agents` | 响应带 `sourceTemplateIds` |
| `PUT /api/agents` | 保存被引用的平台角色时，响应带 `affectedTemplates` |
| `createGenericWorkflow` | 校验节点角色都在平台库 |
| `PublishGenericWorkflow` | 冻结 `AgentRefs[].Version` 为当前版本 |

`PUT /api/workflows/:id/agents` 选择退役而非代理转发，是因为代理会让人以为「在改这个 SOP 的角色」，实际影响面是全平台的，必须显式暴露。

## 6. 前端改动

| 文件 | 位置 | 改动 |
|---|---|---|
| `web/app/agents.js` | `persistAgentRequest` 的 `catalogGeneric` 分支 | 改走 `PUT /api/agents`，`projectId=''`；提交前确认「此角色被 N 个平台 SOP 引用」 |
| `web/app/agents.js` | `isKnownAgentId` | generic 分支下沉，角色已在 `state.data.agents`，保留兜底 |
| `web/app.js` | `workflowAgents` / `hydrateGenericWorkflowRoles` | 不改，后端语义已变 |
| 设计器属性面板 | `renderProperties` | 角色区只读摘要（名称、版本、规则数、门禁数）+「打开角色定义」 |
| 角色定义页 | `renderAgents` | 新增「被 N 个平台 SOP 引用」列 |
| 节点角色选择器 | 平台 SOP 设计器 | 只列 `projectId==''` 的平台角色 |

## 7. 迁移方案

沿用仓库约定：**手动执行，不随部署自动运行**（见 `AGENTS.md`「迁移与 seed」）。

### 7.1 `migrations/052_platform_sop_agent_refs.sql`

通用回填，不写死 id，可重复执行：

1. 遍历所有 `generic_templates.payload.Agents[*]`：
   - `agents` 表无该 id → `INSERT`，`projectId=''`, `shared=TRUE`
   - 已存在 → **跳过**并输出到冲突报告（不覆盖，平台版为准）
2. `payload.Rules[*]` / `payload.Skills[*]` 同样写入 `rules` / `skills`，已存在跳过
3. 生成 `payload.AgentRefs`：取 `Workflow.nodes[].agentId` 去重，`version` 先写 `0`
4. `JSON_REMOVE(payload, '$.Agents', '$.Rules', '$.Skills')`
5. 末尾输出核对结果：回填角色数、冲突清单、每个模板的 `agentRefs` 数量

风格对齐 `046`（存储过程 + 游标）。

### 7.2 `migrations/051_harness_delivery_sop.sql` 改造

`051` 只在本地跑过，直接改成最终形态：角色先 `INSERT` 到 `agents`，payload 只留 `{Workflow, AgentRefs}`。新环境一次到位，存量环境跑 `052`，两条路径收敛到同一状态。

### 7.3 备份与回滚

```bash
mysqldump -h <host> -u <user> -p <db> \
  generic_templates agents rules skills definition_revisions \
  > backup_before_052.sql
```

`052` 不动 schema，回滚 = 代码回退 + 恢复上述 5 张表。

## 8. 兼容与过渡

`resolveTemplateAgents` 实施期按三级取源，每级都能独立验收：

| 级别 | 数据源 | 生效期 |
|---|---|---|
| 1 | `AgentRefs` → `agents` | 目标态 |
| 2 | `Workflow.Nodes[].agentId` → `agents` | 过渡期（老模板无 refs） |
| 3 | `payload.Agents` | 仅 `052` 执行前的环境 |

代码先上「1→2→3」，`052` 跑完并观察一周后删除第 3 级。代码可以先发、数据后迁，不必停机。

## 9. 测试计划

单元测试（`internal/httpapi/generic_promote_test.go` 扩写）：

1. `TestAdoptResolvesRefsFromPlatformCatalog` — refs 解析、副本生成、节点重写
2. `TestAdoptRejectsMissingPlatformRole` — 缺角色返回 400 且不写半成品
3. `TestAdoptIsIdempotent` — 复制两次不重复、项目内手改不被覆盖
4. `TestAdoptPinnedVersion` — 角色升到 v3、模板 pin v2，复制出 v2
5. `TestPromoteRegistersPlatformRole` — 项目私有角色提升后 `projectId=''`，payload 无 `Agents`
6. `TestSavePlatformAgentReportsAffectedTemplates` — 响应带 `affectedTemplates`
7. `TestWorkflowAgentsEndpointIsReadOnly` — `PUT /api/workflows/:id/agents` 返回 409

端到端手测：

- 新项目 A：复制 `generic-backend-delivery`，运行节点成功
- 新项目 B：复制 `generic-harness-delivery`，6 个角色出现在项目角色定义，就绪评审节点 hook 生效
- 改平台「独立评审 · Harness」prompt → 重新发布模板 → 复制到项目 C 拿到新定义；已复制的 B 不受影响

## 10. 分期实施

| 期 | 内容 | 可独立验收 |
|---|---|---|
| P1 | §7.1 迁移 + `resolveTemplateAgents`（三级回退）+ `GET /:id/agents` 改读平台库 | 5 个模板的角色都在角色定义页可见，adopt 可用 |
| P2 | `PUT /:id/agents` 退役 + 前端改走 `PUT /api/agents` + 影响面提示 + 设计器角色区只读 | 角色只有一处可改 |
| P3 | `promoteWorkflow` 反转 + `createGenericWorkflow` 校验 + publish 冻结 refs | 提升不再产生打包快照 |
| P4 | 删第 3 级回退、清理 legacy 字段 | 代码里不再有双源 |

每一期都可停，不留不一致状态。

## 11. 决策记录

| # | 决策 | 结论与理由 |
|---|---|---|
| 1 | `mr`/`deliver` 冲突以哪份为准 | **平台版为准**。实测两边门禁完全一致，仅 rules 引用不同，无需合并 |
| 2 | `PUT /api/workflows/:id/agents` | **退役返回 409**。代理转发会掩盖全平台影响面 |
| 3 | 第一期是否启用版本 pin | **只记录 version，P3 再解析**。降低 adopt 复杂度 |
| 4 | `payload.Agents` 是否留只读快照 | **清空**。`definition_revisions` 已提供快照能力，两处存即两份事实 |
| 5 | `promote` 遇到项目私有角色 | **自动登记为平台角色**，id 冲突返回 409 |

## 附录 A：体检脚本

```sql
-- 节点引用的角色能否在平台角色库解析
SELECT g.id AS template_id, n.agent_id,
       CASE WHEN a.id IS NULL THEN 'MISSING_ROLE'
            WHEN COALESCE(JSON_UNQUOTE(JSON_EXTRACT(a.payload,'$.projectId')),'') <> '' THEN 'NOT_PLATFORM'
            ELSE 'OK' END AS role_state
FROM generic_templates g
JOIN JSON_TABLE(g.payload,'$.Workflow.nodes[*]'
     COLUMNS(agent_id VARCHAR(128) PATH '$.agentId', node_type VARCHAR(16) PATH '$.type')) n
LEFT JOIN agents a ON a.id = n.agent_id COLLATE utf8mb4_unicode_ci
WHERE n.node_type='agent' AND n.agent_id<>''
ORDER BY template_id, agent_id;
```

注意 `JSON_TABLE` 产出列的排序规则是 `utf8mb4_0900_ai_ci`，与业务表的 `utf8mb4_unicode_ci` 不同，join 时必须显式 `COLLATE`，否则报 `ERROR 1267`。
