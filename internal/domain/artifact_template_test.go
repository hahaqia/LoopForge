package domain

import "testing"

func TestParseArtifactTemplateHeadings(t *testing.T) {
	content := `# 需求定型
## 目标
一句话说明。
## 背景与现状

<!-- optional -->
## 非功能需求
### 性能
## 验收标准
`
	headings := ParseArtifactTemplateHeadings(content)
	if len(headings) != 4 {
		t.Fatalf("headings = %+v", headings)
	}
	if headings[0].Title != "目标" || headings[0].Optional {
		t.Fatalf("first heading = %+v", headings[0])
	}
	if headings[2].Title != "非功能需求" || !headings[2].Optional {
		t.Fatalf("optional marker not applied: %+v", headings[2])
	}
	required := RequiredArtifactTemplateHeadings(content)
	if len(required) != 3 || required[2] != "验收标准" {
		t.Fatalf("required = %v", required)
	}
}

func TestParseArtifactTemplateHeadingsKeepsHashInTitle(t *testing.T) {
	headings := ParseArtifactTemplateHeadings("## 支持 C# 客户端\n")
	if len(headings) != 1 || headings[0].Title != "支持 C# 客户端" {
		t.Fatalf("title mangled: %+v", headings)
	}
}
