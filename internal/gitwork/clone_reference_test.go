package gitwork

import (
	"os"
	"path/filepath"
	"testing"
)

// 只有本机真实存在、且确实是 Git 仓库的目录才能当 clone 的对象缓存；
// 其余情况返回空串，调用方退回网络下载而不是报错。
func TestCloneReferencePathRequiresAnExistingGitCheckout(t *testing.T) {
	if got := CloneReferencePath(""); got != "" {
		t.Fatalf("空路径不应作为缓存，得到 %q", got)
	}

	relative := filepath.Join("relative", "checkout")
	if err := os.MkdirAll(filepath.Join(relative, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll("relative") })
	if got := CloneReferencePath(relative); got != "" {
		t.Fatalf("相对路径不应作为缓存，得到 %q", got)
	}

	plain := t.TempDir()
	if got := CloneReferencePath(plain); got != "" {
		t.Fatalf("非 Git 目录不应作为缓存，得到 %q", got)
	}

	checkout := filepath.Join(t.TempDir(), "checkout")
	if err := os.MkdirAll(filepath.Join(checkout, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := CloneReferencePath(" " + checkout + " "); got != checkout {
		t.Fatalf("缓存路径 = %q，期望 %q", got, checkout)
	}

	missing := filepath.Join(t.TempDir(), "missing")
	if got := CloneReferencePath(missing); got != "" {
		t.Fatalf("不存在的路径不应作为缓存，得到 %q", got)
	}
}
