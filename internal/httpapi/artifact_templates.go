package httpapi

import (
	"net/http"
	"strings"

	"agentflow/internal/domain"

	"github.com/gin-gonic/gin"
)

// artifactTemplates serves the catalog of deliverable skeletons. A role's
// artifact contract points at one by id; the skeleton content lives here only.
func (h *catalogHandlers) artifactTemplates(c *gin.Context) {
	if c.Request.Method == http.MethodGet {
		items := h.repo.ArtifactTemplates()
		if projectID := strings.TrimSpace(c.Query("projectId")); projectID != "" {
			items = filterOwnedByProject(items, projectID, func(item domain.ArtifactTemplate) string { return item.ProjectID })
		}
		c.JSON(http.StatusOK, items)
		return
	}
	switch c.Request.Method {
	case http.MethodDelete:
		h.deleteCatalogAsset(c, "产物模板", "artifact template not found", func(id string) (bool, bool) {
			item, ok := h.repo.ArtifactTemplate(id)
			return item.Shared, ok
		}, h.agentNamesReferencingTemplate, "角色", h.repo.DeleteArtifactTemplate)
		return
	case http.MethodPut:
	default:
		c.JSON(http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	var v domain.ArtifactTemplate
	if !decode(c, &v) {
		return
	}
	v.ID, v.ProjectID = strings.TrimSpace(v.ID), strings.TrimSpace(v.ProjectID)
	v.Name, v.MediaType = strings.TrimSpace(v.Name), strings.TrimSpace(v.MediaType)
	if v.ID == "" || v.Name == "" || v.ProjectID == "" {
		c.JSON(http.StatusBadRequest, map[string]string{"error": "id, name and projectId are required"})
		return
	}
	if strings.TrimSpace(v.Content) == "" {
		c.JSON(http.StatusBadRequest, map[string]string{"error": "模板内容不能为空"})
		return
	}
	if len(domain.RequiredArtifactTemplateHeadings(v.Content)) == 0 {
		c.JSON(http.StatusBadRequest, map[string]string{"error": "模板至少需要一个 ## 二级标题，否则无法校验结构"})
		return
	}
	if v.MediaType == "" {
		v.MediaType = "text/markdown"
	}
	if _, ok := h.repo.Project(v.ProjectID); !ok {
		c.JSON(http.StatusNotFound, map[string]string{"error": "project not found"})
		return
	}
	if existing, ok := h.repo.ArtifactTemplate(v.ID); ok {
		if existing.ProjectID != "" && existing.ProjectID != v.ProjectID {
			c.JSON(http.StatusConflict, map[string]string{"error": "artifact template id is already used by another project"})
			return
		}
		if existing.Shared && !v.Shared && len(h.agentNamesReferencingTemplate(v.ID)) > 0 {
			c.JSON(http.StatusConflict, map[string]string{"error": "该模板仍被共享角色引用，不能取消共享"})
			return
		}
		if v.Version <= existing.Version {
			v.Version = existing.Version + 1
		}
	} else {
		v.Version = 1
	}
	respond(c, h.repo.PutArtifactTemplate(v))
}

func (h *catalogHandlers) agentNamesReferencingTemplate(id string) []string {
	var names []string
	for _, agent := range h.repo.Agents() {
		for _, contract := range agent.ArtifactOutputs {
			if strings.TrimSpace(contract.TemplateID) == id {
				names = append(names, agent.Name)
				break
			}
		}
	}
	return names
}
