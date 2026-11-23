package engine

import (
	"fmt"
	"strings"

	"agentflow/internal/domain"
)

// artifactStructureGate derives a command gate from the template's mandatory
// headings. The outline therefore lives only in the template: editing it
// updates the check automatically, with no second copy to drift.
func artifactStructureGate(template domain.ArtifactTemplate, contract domain.ArtifactContract) (domain.VerificationGate, bool) {
	path := strings.TrimSpace(contract.Path)
	titles := domain.RequiredArtifactTemplateHeadings(template.Content)
	if path == "" || len(titles) == 0 {
		return domain.VerificationGate{}, false
	}
	quoted := make([]string, 0, len(titles))
	for _, title := range titles {
		quoted = append(quoted, shellQuote(title))
	}
	command := fmt.Sprintf(`missing=""
for h in %s; do
  grep -qF -- "## $h" %s || missing="$missing $h"
done
[ -z "$missing" ] || { echo "缺少必需章节:$missing"; exit 1; }`,
		strings.Join(quoted, " "), shellQuote(path))
	return domain.VerificationGate{
		ID:             "artifact-structure-" + template.ID,
		Name:           path + " 章节完整",
		Mode:           "command",
		Commands:       []string{command},
		Required:       true,
		ExecutionScope: "run",
	}, true
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
