# SkillHub 安装落到平台技能库（两级技能模型）

日期：2026-11-24
状态：待实现

## 背景

当前 SkillHub 市场安装强制要求 `projectId` 非空，安装结果是一条项目私有技能：

```422:426:internal/httpapi/skillhub_market.go
	projectID := strings.TrimSpace(input.ProjectID)
	if projectID == "" {
		c.JSON(http.StatusBadRequest, map[string]string{"error": "请先选择项目"})
```

这导致平台侧「能力资产 → 技能 → SkillHub 市场」里的安装，实际写进了顶部项目筛选选中的项目，平台共享页看不到；同时项目侧也保留了市场入口，用户无法判断“到底该在哪里装技能”。

## 目标

把技能分成两层，职责解耦：

| 层 | 数据形态 | 谁能写 | 来源 |
|---|---|---|---|
| 平台技能（内部技能库） | `projectId == ""`，`shared=true` | 平台管理员 | SkillHub 安装（`source.provider=skillhub`）或手工新建/上传 |
| 项目技能 | `projectId == "<项目>"` | 项目成员 | 从平台技能复制的一次性快照（`source=nil`）或项目自建/上传 |

规则：

1. 从 skillhub.cn 安装只发生在平台侧，产物是平台技能。
2. 项目侧不提供市场浏览；项目用户只能“从平台技能复制”或“新建/上传团队技能”。
3. 项目副本是快照，与平台技能彻底脱钩：平台更新、删除都不影响副本。
4. 在平台共享页删除市场技能 = 卸载该技能（物理删除 `skills` + `skill_files`）。

## 非目标

- 不做引用式项目技能（项目只存平台技能 id，运行时读平台），保持快照语义。
- 不改变平台技能在运行时被跳过的现状（`internal/engine/assets.go` 对 `ProjectID == ""` 直接 `continue`，generic 模板技能除外）。
- 不恢复项目侧市场 tab。

## 实现方案

采用方案 1：复用 `POST /api/skillhub/install`，`projectId` 改为可选，缺省即平台技能。不新增端点，不引入 `scope` 字段。

### 后端

`internal/httpapi/skillhub_market.go`

1. `install`
   - 删除 `projectId == ""` 的 400 分支。
   - `projectId == ""`：调用 `h.requirePlatformAdmin(c)`（`skillhubHandlers` 嵌入 `*deps`，方法定义在 `internal/httpapi/project_write_access.go:130`），拒绝时直接返回；落库 `domain.SkillDefinition{ProjectID: "", Shared: true, Source: &domain.SkillSource{Provider: skillhub, ...}}`。
   - `projectId != ""`：保留现有 `Project` 存在性校验，行为不变（前端不再调用）。
   - 冲突检查仍走 `installConflict(projectID, namespace, slug, id)`；`skillhubInstalled` 用 `s.ProjectID != projectID` 严格比较，传 `""` 时只匹配平台技能，无需改。
2. `installConflict` 文案
   - 平台重复安装：409「平台已安装该技能（标识 X），如需新版本请使用更新」。
   - id 冲突归属描述增加“平台”分支。
3. `update`
   - `skill.ProjectID == ""` 时要求平台管理员（当前该端点完全无权限校验）。
   - 项目技能分支保持原行为。
4. 卸载
   - 复用 `DELETE /api/skills?id=`，`internal/httpapi/catalog.go` 删除分支在目标是平台技能（`ProjectID == ""`）时补 `requirePlatformAdmin`。
   - 平台技能不受 `shared` 阻断的豁免逻辑已存在（`catalog.go:152-153`），不改。

`internal/repo` 无需改动：`PutSkillSnapshot` 不校验 `projectId`，`skill_files` 按 skill id 归属，平台技能天然支持。

### 前端

`web/app/skillhub.js`

1. `skillhubSyncChrome`：`allowMarket = skills && !state.assetHosted && isPlatformAdmin()`。
2. 删除 4 处 `if (!state.projectFilter)` 拦截（列表安装按钮 `:83`、抽屉安装按钮 `:330`、`openSkillhubInstall` `:429`、弹窗项目名 `:449`），改为管理员判定。
3. `submitSkillhubModal` 安装请求不再传 `projectId`。
4. 文案统一为平台语义：
   - 弹窗标题「安装「X」到平台」
   - 说明「保存所选版本的快照到平台技能库，项目在配置中按需复制使用」
   - 徽标「平台已安装」
   - 成功提示「已安装到「平台共享」，可在项目配置中复制使用」
5. 安装成功后 `state.skillScope = 'shared'` 再 `renderAssets()`，让用户立即看到结果。

`web/app/assets.js`

- 市场页描述：「从 SkillHub 安装到平台技能库；项目在配置中按需复制」。
- 平台共享页描述：「平台技能库：含 SkillHub 安装与手工上传，项目复制后独立维护」。
- 「从平台技能复制」逻辑不变（`submitSkillCopy` / `POST /api/skills/:id/copy`，副本 `source=nil`）。

### 存量迁移

新增 `migrations/046_skillhub_promote_platform.sql`，沿用 `045_project_skill_scopes.sql` 的存储过程风格，可重复执行，需手动执行。

逻辑：

1. 游标遍历 `projectId <> ''` 且 `source.provider = 'skillhub'` 的技能。
2. 平台 id：取 `slug`；若该 id 已被其他行占用则用 `slug-platform`；超过 64 字符用 `left(…,43)-md5(…,20)`。同一 slug 被多个项目安装时只建一个平台行，后续复用。
3. 插入平台行：`json_set(payload, '$.id', 平台id, '$.projectId', '', '$.shared', true)`；`skill_files` 按 id 全量复制。
4. 原项目行：`json_remove(payload, '$.source')`，保留 id、`projectId`、角色绑定。
5. 幂等：`ON DUPLICATE KEY UPDATE id = id`；原行 source 清除后不再被游标选中。

当前库预期：3 条 `ai-devop-agent` 的市场技能各生成 1 条平台技能，项目内 3 条转为副本。

## 验证

1. `go test ./internal/...` 通过。
2. 本地库手动执行 046，校验 `skills` 行数 +3、每个平台技能有对应 `skill_files`、原项目行 `source` 为空且 `agents.payload.skills` 引用未变。
3. 无头 Chrome（dev 环境）：
   - 平台管理员进入能力资产 → 技能：市场 tab 可见；项目配置 → 技能：无市场 tab，有「从平台技能复制」。
   - 平台共享页能看到市场来源技能，来源徽标与「检查更新」正常。
   - 安装成功后面板切到平台共享并出现新行。
4. 权限：普通用户 `POST /api/skillhub/install` → 403；`DELETE` 平台技能 → 403；`POST /api/skillhub/update` 更新平台技能 → 403。
5. 卸载：删除平台技能后项目副本仍存在且内容不变。

## 风险

- SkillHub 外网连通性受限时无法做真实安装验证，成功分支以单测覆盖下载/解包层，网络只验错误路径。
- 迁移脚本对 id 冲突的处理是“跳过插入并复用已有平台行”，若已有同 id 的平台行来源不同，以已存在的为准，不覆盖。
