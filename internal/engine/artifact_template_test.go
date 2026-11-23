package engine

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"agentflow/internal/domain"
)

func TestArtifactStructureGateCoversRequiredHeadingOnly(t *testing.T) {
	template := domain.ArtifactTemplate{
		ID:      "requirement",
		Content: "# 需求定型\n## 目标\n## 验收标准\n<!-- optional -->\n## 非功能需求\n",
	}
	contract := domain.ArtifactContract{Path: "requirement.md", TemplateID: "requirement", Required: true}
	gate, ok := artifactStructureGate(template, contract)
	if !ok {
		t.Fatal("gate not generated")
	}
	if gate.ID != "artifact-structure-requirement" || gate.Mode != "command" || !gate.Required || gate.ExecutionScope != "run" {
		t.Fatalf("gate shape = %+v", gate)
	}
	if len(gate.Commands) != 1 {
		t.Fatalf("commands = %v", gate.Commands)
	}
	command := gate.Commands[0]
	for _, want := range []string{"'目标'", "'验收标准'", "requirement.md", "缺少必需章节"} {
		if !strings.Contains(command, want) {
			t.Fatalf("command missing %q: %s", want, command)
		}
	}
	if strings.Contains(command, "非功能需求") {
		t.Fatalf("optional heading must not be enforced: %s", command)
	}
}

func TestArtifactStructureGateSkipsWithoutTemplate(t *testing.T) {
	contract := domain.ArtifactContract{Path: "requirement.md"}
	if _, ok := artifactStructureGate(domain.ArtifactTemplate{ID: "empty"}, contract); ok {
		t.Fatal("template without headings must not produce a gate")
	}
}

// 门禁命令必须真的能跑起来，并且把缺的章节名字说清楚。
func TestArtifactStructureGateCommandReportsMissingHeading(t *testing.T) {
	template := domain.ArtifactTemplate{ID: "demo-req", Content: "## 目标\n## 范围\n## 回滚方案\n"}
	gate, ok := artifactStructureGate(template, domain.ArtifactContract{Path: "requirement.md", TemplateID: "demo-req"})
	if !ok {
		t.Fatal("gate not generated")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "requirement.md"), []byte("# 需求\n\n## 目标\n做点什么\n\n## 范围\n全量\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run := func() (string, error) {
		cmd := exec.Command("sh", "-c", gate.Commands[0])
		cmd.Dir = dir
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	out, err := run()
	if err == nil {
		t.Fatalf("gate should fail when a mandatory heading is missing: %s", out)
	}
	if !strings.Contains(out, "缺少必需章节") || !strings.Contains(out, "回滚方案") {
		t.Fatalf("failure message should name the missing heading: %q", out)
	}
	if err := os.WriteFile(filepath.Join(dir, "requirement.md"), []byte("## 目标\n## 范围\n## 回滚方案\n回滚到上一版镜像\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := run(); err != nil {
		t.Fatalf("gate should pass once headings exist: %s %v", out, err)
	}
}
