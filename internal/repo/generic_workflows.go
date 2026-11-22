package repo

import "agentflow/internal/domain"

// GenericBackendDeliveryWorkflowID is the stable identifier of the platform
// backend delivery SOP stored in generic_templates.
const GenericBackendDeliveryWorkflowID = "generic-backend-delivery"

// Platform docker assets the generic backend SOP binds to. They are catalog
// rows (not part of the template blob), seeded by
// migrations/seed/111_generic_docker.sql so new projects run in a container
// instead of the host-local driver.
const (
	GenericBackendDockerfileID = "generic-backend"
	GenericDockerSandboxID     = "generic-docker"
)

// Role identifiers used by the stored 智研工坊 backend template. Cloning a
// generic template copies these roles into the target project.
const (
	GenericAgentRequirement = "zhiyan-requirement"
	GenericAgentDesign      = "zhiyan-design"
	GenericAgentImplement   = "zhiyan-implement"
	GenericAgentReview      = "zhiyan-review"
	GenericAgentTest        = "zhiyan-test"
	GenericAgentMR          = "zhiyan-mr"
	GenericAgentSummary     = "zhiyan-summary"
)

// Requirement keys a generic template may declare. Studio maps them onto live
// checks (personal credentials, project MCP installs) so users learn about the
// dependency before the first run.
const (
	RequirementGongfengGitToken = "gongfeng-git-token"
	RequirementGongfengMCP      = "gongfeng-mcp"
	RequirementTAPDMCP          = "tapd-mcp"
)

// Product and frontend harness templates share the same generic_templates
// table as the 智研工坊 backend SOP.
const (
	GenericProductDeliveryWorkflowID  = "generic-product-delivery"
	GenericFrontendDeliveryWorkflowID = "generic-frontend-delivery"
)

const (
	GenericAgentProductPRD        = "product-prd"
	GenericAgentProductDemo       = "product-demo"
	GenericAgentProductHandoff    = "product-handoff"
	GenericAgentProductAcceptance = "product-acceptance"
	GenericAgentProductTAPD       = "product-tapd"
	GenericAgentProductSummary    = "product-summary"

	GenericAgentFrontendShape   = "frontend-shape"
	GenericAgentFrontendDesign  = "frontend-design"
	GenericAgentFrontendBuild   = "frontend-build"
	GenericAgentFrontendReview  = "frontend-review"
	GenericAgentFrontendVerify  = "frontend-verify"
	GenericAgentFrontendMR      = "frontend-mr"
	GenericAgentFrontendArchive = "frontend-archive"
)

// Template-owned rule ids. These are cloned into the adopting project and
// referenced by the template roles.
const (
	GenericRuleCore           = "zhiyan-core"
	GenericRuleBackendProfile = "zhiyan-backend-profile"
)

// Template-owned skill ids, one per 智研工坊 stage capability.
const (
	GenericSkillClarifyRequirements = "zhiyan-clarify-requirements"
	GenericSkillBrainstorming       = "zhiyan-brainstorming"
	GenericSkillTechDesign          = "zhiyan-tech-design"
	GenericSkillWritingPlans        = "zhiyan-writing-plans"
	GenericSkillKnowledgeDistill    = "zhiyan-knowledge-distillation"
)

// GenericTemplate bundles a project-independent SOP with the roles it needs.
// Rows live in generic_templates; the engine resolves them through the same
// Workflow/Agent catalog lookups as a custom SOP. The Generic flag on the
// workflow payload is only a marker for listing and clone/edit policy.
type GenericTemplate struct {
	Workflow domain.WorkflowDefinition
	Agents   []domain.AgentDefinition
	Rules    []domain.RuleDefinition
	Skills   []domain.SkillDefinition
	// VerdictGateSeedVersion is retained so stored blobs keep decoding.
	VerdictGateSeedVersion int
	// PlaybookSeedVersion is retained so stored blobs keep decoding.
	PlaybookSeedVersion int
}
