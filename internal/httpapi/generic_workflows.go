package httpapi

import (
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"agentflow/internal/domain"
	"agentflow/internal/repo"
)

// adoptGenericWorkflow clones a built-in generic template into a project: the
// workflow becomes an editable draft and every role it references is cloned
// into the same project with remapped ids, so the copy is immediately runnable
// instead of failing on "agent not found".
func (h *catalogHandlers) adoptGenericWorkflow(template domain.WorkflowDefinition, id, name, owner, projectID string) (domain.WorkflowDefinition, error) {
	projectID = strings.TrimSpace(projectID)
	if projectID == "" {
		return domain.WorkflowDefinition{}, errors.New("通用模板必须复制到具体项目后才能使用")
	}
	if _, found := h.repo.Project(projectID); !found {
		return domain.WorkflowDefinition{}, errors.New("目标项目不存在，请刷新后重新选择")
	}
	if template.SandboxProfileID == "" {
		return domain.WorkflowDefinition{}, errors.New("当前项目没有可用沙箱，请先在「沙箱管理」创建或共享一个沙箱")
	}
	if err := ensureDefaultProjectMCPs(h.repo, projectID); err != nil {
		return domain.WorkflowDefinition{}, fmt.Errorf("安装默认 MCP: %w", err)
	}
	h.configureSync(h.repo.SyncConfig())
	agents, err := h.cloneGenericTemplateAgents(template.ID, projectID)
	if err != nil {
		return domain.WorkflowDefinition{}, err
	}
	adopted := template
	// Copy the slices so remapping node bindings can never leak back into the
	// shared built-in catalog.
	adopted.Nodes = append([]domain.WorkflowNode(nil), template.Nodes...)
	adopted.Edges = append([]domain.WorkflowEdge(nil), template.Edges...)
	adopted.Tags = append(append([]string(nil), template.Tags...), "generic-source:"+template.ID)
	adopted.Requirements = append([]domain.WorkflowRequirement(nil), template.Requirements...)
	adopted.ID, adopted.Name, adopted.Owner = id, name, owner
	adopted.ProjectID = projectID
	adopted.Shared = false
	adopted.Status = "draft"
	adopted.Version = 1
	adopted.Revision = 0
	adopted.Generic = false
	if strings.TrimSpace(adopted.SOPLane) == "" {
		adopted.SOPLane = domain.InferSOPLane(template)
	}
	adopted.CreatedAt, adopted.UpdatedAt = time.Time{}, time.Time{}
	for index := range adopted.Nodes {
		if target, ok := agents[adopted.Nodes[index].AgentID]; ok {
			adopted.Nodes[index].AgentID = target
		}
	}
	if err := h.repo.PutWorkflow(adopted); err != nil {
		// Deliberately no compensation deletes here. The cloned roles, rules
		// and skills may already be referenced by a concurrent adoption that
		// succeeded (or is still running), and deleting them would break that
		// SOP. They are idempotently reused on the next attempt, so a failed
		// adopt just leaves pre-created assets behind — self-healing on retry
		// and manually removable in the catalog if never retried.
		return domain.WorkflowDefinition{}, err
	}
	stored, _ := h.repo.Workflow(id)
	return stored, nil
}

// resolveTemplateAgents returns the platform roles a template orchestrates, in
// node order. Roles live only in the platform catalog: a node binding an id the
// catalog does not resolve to a platform role is a broken template.
func (h *catalogHandlers) resolveTemplateAgents(template repo.GenericTemplate) ([]domain.AgentDefinition, error) {
	ids := orderedTemplateAgentIDs(template.Workflow)
	if len(ids) == 0 {
		return nil, nil
	}
	pinned := make(map[string]int, len(template.AgentRefs))
	for _, ref := range template.AgentRefs {
		pinned[ref.ID] = ref.Version
	}
	out := make([]domain.AgentDefinition, 0, len(ids))
	for _, id := range ids {
		role, ok := h.repo.Agent(id)
		if !ok || role.ProjectID != "" {
			return nil, fmt.Errorf("平台 SOP 引用的角色 %q 不在平台角色库中，请先在「角色定义」创建该角色", id)
		}
		role = h.pinAgentVersion(role, pinned[id])
		role.SourceTemplateIDs = h.repo.TemplatesReferencingAgent(id)
		out = append(out, role)
	}
	return out, nil
}

// pinAgentVersion returns the definition a published template was pinned to.
// Snapshots rotate out after maxRevisionsPerEntity revisions; when the pinned
// one is gone the current definition is used so adoption still succeeds.
func (h *catalogHandlers) pinAgentVersion(role domain.AgentDefinition, version int) domain.AgentDefinition {
	if version <= 0 || version == role.Version {
		return role
	}
	if pinned, ok := h.repo.AgentRevision(role.ID, version); ok {
		return pinned
	}
	return role
}

// orderedTemplateAgentIDs lists the agent ids bound by workflow nodes, in node
// order and without duplicates. Preview-build nodes never reach the catalog.
func orderedTemplateAgentIDs(workflow domain.WorkflowDefinition) []string {
	seen := make(map[string]bool, len(workflow.Nodes))
	ids := make([]string, 0, len(workflow.Nodes))
	for _, node := range workflow.Nodes {
		if node.Type != "agent" {
			continue
		}
		id := strings.TrimSpace(node.AgentID)
		if id == "" || domain.IsPreviewBuildAgent(id) || seen[id] {
			continue
		}
		seen[id] = true
		ids = append(ids, id)
	}
	return ids
}

// collectTemplateAssets resolves the platform rules and skills bound by the
// given roles, in binding order and without duplicates. An id the catalog does
// not resolve to a platform asset is a broken entry: adoption fails instead of
// cloning a role whose bindings cannot resolve at runtime.
func (h *catalogHandlers) collectTemplateAssets(agents []domain.AgentDefinition) ([]domain.RuleDefinition, []domain.SkillDefinition, error) {
	seenRule := make(map[string]bool)
	seenSkill := make(map[string]bool)
	rules := make([]domain.RuleDefinition, 0, len(agents))
	skills := make([]domain.SkillDefinition, 0, len(agents))
	for _, agent := range agents {
		for _, id := range agent.Rules {
			if seenRule[id] {
				continue
			}
			seenRule[id] = true
			if rule, ok := h.repo.Rule(id); ok && rule.ProjectID == "" {
				rules = append(rules, rule)
				continue
			}
			return nil, nil, fmt.Errorf("角色 %q 引用的规则 %q 不在平台资产库中", agent.Name, id)
		}
		for _, id := range agent.Skills {
			if seenSkill[id] {
				continue
			}
			seenSkill[id] = true
			if skill, ok := h.repo.Skill(id); ok && skill.ProjectID == "" {
				skills = append(skills, skill)
				continue
			}
			return nil, nil, fmt.Errorf("角色 %q 引用的技能 %q 不在平台资产库中", agent.Name, id)
		}
	}
	return rules, skills, nil
}

// cloneGenericTemplateAgents copies the roles a platform SOP orchestrates into
// the project and returns the source-id -> project-id mapping used to rewrite
// node bindings. Roles come from the platform catalog, never from the template
// payload, so editing a platform role changes what the next adoption copies.
// A role that already exists in the project is reused, so adopting the
// template twice never overwrites local edits.
func (h *catalogHandlers) cloneGenericTemplateAgents(workflowID, projectID string) (map[string]string, error) {
	template, ok := h.repo.GenericTemplateByWorkflow(workflowID)
	if !ok {
		return nil, fmt.Errorf("generic template %q not found", workflowID)
	}
	sources, err := h.resolveTemplateAgents(template)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	// The rule and skill bindings live in the platform catalog as well: clone
	// them into the project first so role bindings can be remapped onto real
	// project assets.
	ruleSources, skillSources, err := h.collectTemplateAssets(sources)
	if err != nil {
		return nil, err
	}
	ruleRemap, err := h.cloneGenericTemplateRules(ruleSources, projectID, now)
	if err != nil {
		return nil, err
	}
	skillRemap, err := h.cloneGenericTemplateSkills(skillSources, projectID, now)
	if err != nil {
		return nil, err
	}
	remap := make(map[string]string, len(sources))
	for _, source := range sources {
		// Projects that did not get the plain template id (a sibling project
		// owns it) hold a deterministic <id>-<project> clone instead; reuse it
		// so re-adopting the template never duplicates the roles.
		if existing, found := findGenericProjectClone(source.ID, projectID, h.repo.Agent, func(a domain.AgentDefinition) string { return a.ProjectID }); found {
			h.upgradeGenericTemplateAgent(&existing, source, projectID, now)
			remap[source.ID] = existing.ID
			continue
		}
		agent := source
		agent.ID = h.availableGenericAgentID(source.ID, projectID)
		agent.ProjectID = projectID
		agent.Shared = false
		agent.Version = 1
		agent.UpdatedAt = now
		agent.MCPServers = h.resolveGenericTemplateMCP(agent.MCPServers, projectID)
		agent.Rules = remapAssetIDs(agent.Rules, ruleRemap)
		agent.Skills = remapAssetIDs(agent.Skills, skillRemap)
		if err := h.repo.PutAgent(agent); err != nil {
			return nil, err
		}
		remap[source.ID] = agent.ID
	}
	return remap, nil
}

// upgradeGenericTemplateAgent refreshes an existing clone on re-adoption. The
// only thing it ever touches is the MCP binding, and only when the role has
// none: a clone adopted before the project installed the template MCP stays
// unbound, and re-adopting is the documented way to pick the install up. A
// role with any binding may hold deliberate local edits and is left alone.
func (h *catalogHandlers) upgradeGenericTemplateAgent(existing *domain.AgentDefinition, source domain.AgentDefinition, projectID string, now time.Time) {
	if len(existing.MCPServers) > 0 || len(source.MCPServers) == 0 {
		return
	}
	resolved := h.resolveGenericTemplateMCP(source.MCPServers, projectID)
	if len(resolved) == 0 {
		return
	}
	existing.MCPServers = resolved
	existing.UpdatedAt = now
	_ = h.repo.PutAgent(*existing)
}

func (h *catalogHandlers) cloneGenericTemplateRules(sources []domain.RuleDefinition, projectID string, now time.Time) (map[string]string, error) {
	remap := make(map[string]string, len(sources))
	for _, source := range sources {
		if existing, found := findGenericProjectClone(source.ID, projectID, h.repo.Rule, func(v domain.RuleDefinition) string { return v.ProjectID }); found {
			remap[source.ID] = existing.ID
			continue
		}
		rule := source
		rule.ID = h.availableGenericRuleID(source.ID, projectID)
		rule.ProjectID = projectID
		rule.Shared = false
		rule.UpdatedAt = now
		if err := h.repo.PutRule(rule); err != nil {
			return nil, err
		}
		remap[source.ID] = rule.ID
	}
	return remap, nil
}

func (h *catalogHandlers) cloneGenericTemplateSkills(sources []domain.SkillDefinition, projectID string, now time.Time) (map[string]string, error) {
	remap := make(map[string]string, len(sources))
	for _, source := range sources {
		if existing, found := findGenericProjectClone(source.ID, projectID, h.repo.Skill, func(v domain.SkillDefinition) string { return v.ProjectID }); found {
			remap[source.ID] = existing.ID
			continue
		}
		skill := source
		skill.ID = h.availableGenericSkillID(source.ID, projectID)
		skill.ProjectID = projectID
		skill.Shared = false
		skill.UpdatedAt = now
		if err := h.repo.PutSkill(skill); err != nil {
			return nil, err
		}
		remap[source.ID] = skill.ID
	}
	return remap, nil
}

// remapAssetIDs rewrites template asset references onto the cloned project ids,
// keeping order and platform-wide ids (which resolve globally) untouched.
func remapAssetIDs(ids []string, remap map[string]string) []string {
	if len(ids) == 0 || len(remap) == 0 {
		return ids
	}
	out := make([]string, len(ids))
	for index, id := range ids {
		if mapped, ok := remap[id]; ok {
			out[index] = mapped
			continue
		}
		out[index] = id
	}
	return out
}

// genericAssetIDCandidates lists the deterministic ids tried for a cloned
// template asset, in order: the template id itself, then the id suffixed with
// the owning project. The suffix keeps the clone predictable and reusable, so
// re-adopting the template in the same project never piles up duplicates.
func genericAssetIDCandidates(sourceID, projectID string) []string {
	return []string{sourceID, sourceID + "-" + projectID}
}

// findGenericProjectClone returns the first genericAssetIDCandidates entry that
// already exists and belongs to projectID, so re-adopting a template reuses the
// project's clone instead of creating a duplicate.
func findGenericProjectClone[T any](sourceID, projectID string, lookup func(string) (T, bool), ownerOf func(T) string) (T, bool) {
	for _, id := range genericAssetIDCandidates(sourceID, projectID) {
		if existing, found := lookup(id); found && ownerOf(existing) == projectID {
			return existing, true
		}
	}
	var zero T
	return zero, false
}

func (h *catalogHandlers) availableGenericRuleID(sourceID, projectID string) string {
	return h.pickAvailableID(genericAssetIDCandidates(sourceID, projectID), func(id string) bool {
		_, taken := h.repo.Rule(id)
		return taken
	})
}

func (h *catalogHandlers) availableGenericSkillID(sourceID, projectID string) string {
	return h.pickAvailableID(genericAssetIDCandidates(sourceID, projectID), func(id string) bool {
		_, taken := h.repo.Skill(id)
		return taken
	})
}

func (h *catalogHandlers) availableGenericAgentID(sourceID, projectID string) string {
	return h.pickAvailableID(genericAssetIDCandidates(sourceID, projectID), func(id string) bool {
		_, taken := h.repo.Agent(id)
		return taken
	})
}

// pickAvailableID returns the first candidate that is not taken, falling back
// to random suffixes when every deterministic candidate is owned by something
// else.
func (h *catalogHandlers) pickAvailableID(candidates []string, taken func(string) bool) string {
	for _, candidate := range candidates {
		if !taken(candidate) {
			return candidate
		}
	}
	sourceID := candidates[0]
	for attempt := 0; attempt < 20; attempt++ {
		candidate := fmt.Sprintf("%s-%s", sourceID, randomID()[:6])
		if !taken(candidate) {
			return candidate
		}
	}
	return fmt.Sprintf("%s-%d", sourceID, time.Now().UnixNano())
}

// resolveGenericTemplateMCP maps a template MCP reference onto an asset that is
// actually usable by the project. The template declares market aliases (for
// example "gongfeng"), while a run can only bind a project-scoped install of
// that market item. Adopt installs the platform defaults first, so the common
// Gongfeng/TAPD aliases resolve without a market click. Other missing installs
// are still dropped so the node can degrade.
func (h *catalogHandlers) resolveGenericTemplateMCP(ids []string, projectID string) []string {
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if _, found := h.repo.MCPServer(id); found {
			out = append(out, id)
			continue
		}
		item, found := marketItem(id)
		if !found {
			for _, server := range h.repo.MCPServers() {
				if server.ProjectID == projectID && server.Scope == "project" && (strings.EqualFold(server.Name, id) || strings.HasPrefix(strings.ToLower(server.Name), strings.ToLower(id)+" ")) {
					out = append(out, server.ID)
					break
				}
			}
			continue
		}
		for _, server := range h.repo.MCPServers() {
			if server.Scope != "project" || server.ProjectID != projectID || server.MarketID == "" {
				continue
			}
			if sameMarketItem(server.MarketID, item.ID) {
				out = append(out, server.ID)
				break
			}
		}
	}
	return out
}

// genericTemplateSandbox prefers the template sandbox and falls back to a
// sandbox the project can actually run, so a deployment without the built-in
// "local" profile still adopts the template.
func (h *catalogHandlers) genericTemplateSandbox(preferred, projectID string) string {
	if profile, found := h.repo.Sandbox(preferred); found && (profile.ProjectID == projectID || profile.ProjectID == "" || profile.Shared) {
		return profile.ID
	}
	for _, profile := range h.repo.Sandboxes() {
		if profile.ProjectID == projectID {
			return profile.ID
		}
	}
	for _, profile := range h.repo.Sandboxes() {
		if profile.Shared || profile.ProjectID == "" {
			return profile.ID
		}
	}
	return ""
}

// createGenericWorkflow writes a brand-new platform SOP into generic_templates.
// Project SOPs never land here: the id must not collide with any stored SOP.
func (h *catalogHandlers) createGenericWorkflow(v domain.WorkflowDefinition) (domain.WorkflowDefinition, int, error) {
	if _, taken := h.repo.GenericTemplateByWorkflow(v.ID); taken {
		return domain.WorkflowDefinition{}, http.StatusConflict, fmt.Errorf("平台 SOP %s 已存在", v.ID)
	}
	if _, taken := h.repo.Workflow(v.ID); taken {
		return domain.WorkflowDefinition{}, http.StatusConflict, fmt.Errorf("ID %s 已被占用，请换一个", v.ID)
	}
	profile, ok := h.repo.Sandbox(v.SandboxProfileID)
	if !ok {
		return domain.WorkflowDefinition{}, http.StatusBadRequest, errors.New("平台 SOP 需要选择一个运行沙箱")
	}
	if profile.ProjectID != "" && !profile.Shared {
		return domain.WorkflowDefinition{}, http.StatusBadRequest, fmt.Errorf("平台 SOP 必须使用平台共享沙箱：%s", profile.Name)
	}
	v.Generic, v.ProjectID, v.Shared = true, "", false
	v.Revision, v.PublishedRevision = 0, 0
	if v.Version == 0 {
		v.Version = 1
	}
	if strings.TrimSpace(v.Status) == "" {
		v.Status = "draft"
	}
	if strings.TrimSpace(v.SOPLane) == "" {
		v.SOPLane = domain.InferSOPLane(v)
	}
	attached, err := domain.AttachPreviewBuild(v)
	if err != nil {
		return domain.WorkflowDefinition{}, http.StatusBadRequest, err
	}
	refs, status, err := h.collectPlatformRoleRefs(attached)
	if err != nil {
		return domain.WorkflowDefinition{}, status, err
	}
	if err := h.repo.PutGenericTemplate(repo.GenericTemplate{Workflow: attached, AgentRefs: refs}); err != nil {
		return domain.WorkflowDefinition{}, http.StatusBadRequest, err
	}
	return attached, http.StatusCreated, nil
}

// collectPlatformRoleRefs validates that every role bound by a platform SOP is
// already in the platform catalog and returns the references to store. Creating
// a template never promotes project roles: that would take them away from the
// project that owns them.
func (h *catalogHandlers) collectPlatformRoleRefs(v domain.WorkflowDefinition) ([]repo.GenericAgentRef, int, error) {
	seen := make(map[string]bool, len(v.Nodes))
	refs := make([]repo.GenericAgentRef, 0, len(v.Nodes))
	for _, node := range v.Nodes {
		if node.Type != "agent" {
			continue
		}
		agentID := strings.TrimSpace(node.AgentID)
		if agentID == "" || domain.IsPreviewBuildAgent(agentID) || seen[agentID] {
			continue
		}
		seen[agentID] = true
		role, ok := h.repo.Agent(agentID)
		if !ok || role.ProjectID != "" {
			return nil, http.StatusBadRequest, fmt.Errorf("节点「%s」绑定的角色 %q 不在平台角色库中，请先在「设置 › 角色定义」创建", node.Name, agentID)
		}
		refs = append(refs, repo.GenericAgentRef{ID: role.ID})
	}
	return refs, 0, nil
}

// registerPromotedRoles publishes the roles bound by a promoted SOP into the
// platform catalog and returns the references to store. A project-owned role is
// promoted in place, matching migrations/046's semantics for skills; a role
// owned by a different project is a hard conflict instead of a silent takeover.
func (h *catalogHandlers) registerPromotedRoles(src domain.WorkflowDefinition) ([]repo.GenericAgentRef, int, error) {
	seen := make(map[string]bool, len(src.Nodes))
	refs := make([]repo.GenericAgentRef, 0, len(src.Nodes))
	for _, node := range src.Nodes {
		if node.Type != "agent" {
			continue
		}
		agentID := strings.TrimSpace(node.AgentID)
		if agentID == "" || domain.IsPreviewBuildAgent(agentID) || seen[agentID] {
			continue
		}
		seen[agentID] = true
		role, ok := h.repo.Agent(agentID)
		if !ok {
			return nil, http.StatusBadRequest, fmt.Errorf("角色 %q 不存在，请先补齐后再提升", agentID)
		}
		if role.ProjectID != "" {
			if role.ProjectID != src.ProjectID {
				return nil, http.StatusConflict, fmt.Errorf("角色 %q 属于项目 %s，不能提升为平台角色；请先改用本项目的角色标识", agentID, role.ProjectID)
			}
			promoted, err := h.repo.PromoteAgent(role.ID, src.ProjectID)
			if err != nil {
				return nil, http.StatusBadRequest, err
			}
			role = promoted
		}
		for _, ruleID := range role.Rules {
			if rule, ok := h.repo.Rule(ruleID); !ok || rule.ProjectID != "" {
				return nil, http.StatusBadRequest, fmt.Errorf("角色 %q 引用的规则 %q 不在平台资产库中，请先提升该规则", role.Name, ruleID)
			}
		}
		for _, skillID := range role.Skills {
			if skill, ok := h.repo.Skill(skillID); !ok || skill.ProjectID != "" {
				return nil, http.StatusBadRequest, fmt.Errorf("角色 %q 引用的技能 %q 不在平台资产库中，请先提升该技能", role.Name, skillID)
			}
		}
		// Version stays 0 until publish freezes it, so a draft SOP tracks the
		// newest platform role.
		refs = append(refs, repo.GenericAgentRef{ID: role.ID})
	}
	return refs, 0, nil
}

func (h *catalogHandlers) promoteWorkflow(src domain.WorkflowDefinition, id, name, owner string) (domain.WorkflowDefinition, int, error) {
	id, name = strings.TrimSpace(id), strings.TrimSpace(name)
	if id == "" || name == "" {
		return domain.WorkflowDefinition{}, http.StatusBadRequest, errors.New("平台 SOP 需要 id 和名称")
	}
	if src.Generic {
		return domain.WorkflowDefinition{}, http.StatusConflict, errors.New("平台 SOP 无需提升")
	}
	if _, taken := h.repo.GenericTemplateByWorkflow(id); taken {
		return domain.WorkflowDefinition{}, http.StatusConflict, fmt.Errorf("平台 SOP %s 已存在", id)
	}
	if _, taken := h.repo.Workflow(id); taken {
		return domain.WorkflowDefinition{}, http.StatusConflict, fmt.Errorf("ID %s 已被占用，请换一个", id)
	}
	if profile, ok := h.repo.Sandbox(src.SandboxProfileID); !ok || (profile.ProjectID != "" && !profile.Shared) {
		return domain.WorkflowDefinition{}, http.StatusBadRequest, errors.New("提升为平台 SOP 前，请先把该 SOP 的运行沙箱换成平台共享沙箱")
	}
	// Promoting records the roles in the platform catalog and keeps only the
	// references in the template, so later role edits reach this SOP without a
	// second copy of the definition drifting in payload.
	refs, status, err := h.registerPromotedRoles(src)
	if err != nil {
		return domain.WorkflowDefinition{}, status, err
	}
	promoted := src
	promoted.Nodes = append([]domain.WorkflowNode(nil), src.Nodes...)
	promoted.Edges = append([]domain.WorkflowEdge(nil), src.Edges...)
	promoted.Requirements = append([]domain.WorkflowRequirement(nil), src.Requirements...)
	promoted.Tags = make([]string, 0, len(src.Tags))
	for _, tag := range src.Tags {
		if strings.HasPrefix(tag, "generic-source:") {
			continue
		}
		promoted.Tags = append(promoted.Tags, tag)
	}
	promoted.ID, promoted.Name, promoted.Owner = id, name, owner
	promoted.Generic, promoted.ProjectID, promoted.Shared = true, "", false
	promoted.Status, promoted.Version, promoted.Revision = "draft", 1, 0
	promoted.PublishedRevision = 0
	promoted.CreatedAt, promoted.UpdatedAt = time.Time{}, time.Time{}
	if strings.TrimSpace(promoted.SOPLane) == "" {
		promoted.SOPLane = domain.InferSOPLane(src)
	}
	template := repo.GenericTemplate{Workflow: promoted, AgentRefs: refs}
	if err := h.repo.PutGenericTemplate(template); err != nil {
		return domain.WorkflowDefinition{}, http.StatusBadRequest, err
	}
	stored, _ := h.repo.Workflow(id)
	return stored, http.StatusCreated, nil
}
