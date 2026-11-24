package web

import (
	"os"
	"strings"
	"testing"
)

func TestIconRailCollapseToggle(t *testing.T) {
	htmlRaw, err := os.ReadFile("index.html")
	if err != nil {
		t.Fatal(err)
	}
	html := string(htmlRaw)
	head := strings.Index(html, `class="rail-head"`)
	toggle := strings.Index(html, `id="railCollapseToggle"`)
	nav := strings.Index(html, `class="rail-nav"`)
	if head < 0 || toggle < 0 || nav < 0 || toggle < head || nav < toggle {
		t.Fatal("rail must expose a collapse toggle above the nav items")
	}
	for _, want := range []string{`aria-controls="platformRail"`, `data-tooltip="收起一级栏"`} {
		if !strings.Contains(html, want) {
			t.Fatalf("rail collapse toggle needs %s", want)
		}
	}
	bottom := strings.Index(html, `class="rail-bottom"`)
	settings := strings.Index(html, `id="railSettingsEntry"`)
	if bottom < 0 || settings < bottom {
		t.Fatal("settings entry must stay in the icon rail")
	}
	// 运行记录已提升为一级工作入口；流程模板、定时任务仍留在设置导航。
	for _, moved := range []string{"流程模板", "定时任务"} {
		if strings.Contains(html, `<span class="rail-label">`+moved+`</span>`) {
			t.Fatalf("%s moved into the settings sidebar and must not stay on the rail", moved)
		}
	}
	if !strings.Contains(html, `<span class="rail-label">运行记录</span>`) {
		t.Fatal("运行记录 is a first-class work entry and must sit on the icon rail")
	}

	app, err := os.ReadFile("app.js")
	if err != nil {
		t.Fatal(err)
	}
	src := string(app)
	for _, want := range []string{"setRailCollapsed", "syncRailCollapseToggle", "agentflow.railCollapsed"} {
		if !strings.Contains(src, want) {
			t.Fatalf("app.js must wire the rail collapse toggle (%s)", want)
		}
	}

	boot, err := os.ReadFile("boot-theme.js")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(boot), "rail-collapsed") {
		t.Fatal("boot-theme.js must restore the collapsed rail before first paint")
	}

	css, err := os.ReadFile("product-v4.css")
	if err != nil {
		t.Fatal(err)
	}
	sheet := string(css)
	if strings.Contains(sheet, "platform-rail-expanded") || strings.Contains(sheet, "--rail-w: 240px") {
		t.Fatal("rail only switches between the label width and the icon width")
	}
	// 展开 160px 常显中文名；收起与窄屏回退 56px 纯图标。
	if !strings.Contains(sheet, "--rail-w: 160px") || !strings.Contains(sheet, "--rail-w-icon: 56px") {
		t.Fatal("rail must be 160px wide with labels and fall back to the 56px icon width")
	}
	labelIdx := strings.Index(sheet, "\n.platform-rail .rail-label {")
	if labelIdx < 0 || !strings.Contains(sheet[labelIdx:labelIdx+260], "display: block") {
		t.Fatal("rail labels must be visible beside the icons when expanded")
	}
	collapsedIdx := strings.Index(sheet, "\nhtml.rail-collapsed {")
	if collapsedIdx < 0 || !strings.Contains(sheet[collapsedIdx:collapsedIdx+120], "--rail-w: var(--rail-w-icon)") {
		t.Fatal("collapsed rail must fall back to the icon width")
	}
	if !strings.Contains(sheet, "html.rail-collapsed .platform-rail .rail-label") {
		t.Fatal("collapsed rail must hide the Chinese labels")
	}
}
