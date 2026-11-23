package repo

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"agentflow/internal/domain"
)

// templateRow 只投影 id/payload：这张表没有业务意义上的创建时间，
// 把 created_at/updated_at 一起扫会依赖驱动的 parseTime 配置。
type templateRow struct {
	ID      string `gorm:"column:id"`
	Payload []byte `gorm:"column:payload"`
}

func (r *CatalogRepo) artifactTemplateRows(query string, args ...any) []templateRow {
	// 用 Raw+Scan 直接取两列：这张表只存 id 和 payload，走 gorm 的模型推断
	// 会连带生成 created_at/updated_at 的扫描，列缺失时整条查询静默失败。
	sql := "select id, payload from artifact_templates"
	if query != "" {
		sql += " where " + query
	}
	var rows []templateRow
	if r.DB.Raw(sql, args...).Scan(&rows).Error != nil {
		return nil
	}
	return rows
}

func decodeArtifactTemplates(rows []templateRow) []domain.ArtifactTemplate {
	out := make([]domain.ArtifactTemplate, 0, len(rows))
	for _, row := range rows {
		var item domain.ArtifactTemplate
		if json.Unmarshal(row.Payload, &item) == nil {
			out = append(out, item)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// ArtifactTemplates lists every template skeleton. They are catalog assets, so
// they live with rules/skills rather than with a run.
func (r *CatalogRepo) ArtifactTemplates() []domain.ArtifactTemplate {
	return decodeArtifactTemplates(r.artifactTemplateRows(""))
}

func (r *CatalogRepo) ArtifactTemplate(id string) (domain.ArtifactTemplate, bool) {
	rows := r.artifactTemplateRows("id = ?", id)
	if len(rows) == 0 {
		return domain.ArtifactTemplate{}, false
	}
	var item domain.ArtifactTemplate
	if json.Unmarshal(rows[0].Payload, &item) != nil {
		return domain.ArtifactTemplate{}, false
	}
	return item, true
}

func (r *CatalogRepo) PutArtifactTemplate(v domain.ArtifactTemplate) error {
	v.UpdatedAt = time.Now().UTC()
	return upsert(r.DB, "artifact_templates", map[string]any{
		"id": v.ID, "name": v.Name, "payload": mustJSON(v), "updated_at": timePtr(v.UpdatedAt),
	})
}

func (r *CatalogRepo) DeleteArtifactTemplate(id string) error {
	if _, ok := r.ArtifactTemplate(id); !ok {
		return fmt.Errorf("artifact template not found")
	}
	return r.DB.Table("artifact_templates").Where("id = ?", id).Delete(nil).Error
}
