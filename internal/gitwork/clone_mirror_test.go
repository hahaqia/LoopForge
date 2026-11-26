package gitwork

import (
	"context"
	"strings"
	"testing"
)

func TestCloneMirrorURLOnlyPrefixesWhenConfigured(t *testing.T) {
	t.Setenv(CloneMirrorEnv, "")
	if got := CloneMirrorURL("https://github.com/owner/repo.git"); got != "" {
		t.Fatalf("未配置镜像时不应拼出地址，得到 %q", got)
	}
	t.Setenv(CloneMirrorEnv, "  https://gh-proxy.example/  ")
	if got := CloneMirrorURL("https://github.com/owner/repo.git"); got != "https://gh-proxy.example/https://github.com/owner/repo.git" {
		t.Fatalf("镜像地址 = %q", got)
	}
	if got := CloneMirrorURL(""); got != "" {
		t.Fatalf("空仓库地址不应拼出镜像地址，得到 %q", got)
	}
}

func TestMirroredCloneAuthenticatesTheMirrorWithTheRepositoryCredential(t *testing.T) {
	const mirrored = "https://gh-proxy.example/https://github.com/owner/repo.git"
	ctx := WithHTTPRemote(WithHTTPCredentials(context.Background(), map[string]HTTPCredential{
		"github.com": {Username: "x-access-token", Token: "fake-mirror-token"},
	}), mirrored)

	cmd := command(ctx, t.TempDir(), nil, []string{"credential", "fill"})
	cmd.Stdin = strings.NewReader("protocol=https\nhost=gh-proxy.example\n\n")
	out, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(out), "password=fake-mirror-token") {
		t.Fatalf("镜像入口没有拿到仓库凭据：%v %s", err, out)
	}

	// 凭据只能交给镜像入口，不能因为配置了镜像就扩散到别的主机。
	cmd = command(ctx, t.TempDir(), nil, []string{"credential", "fill"})
	cmd.Stdin = strings.NewReader("protocol=https\nhost=other.example\n\n")
	if out, err := cmd.CombinedOutput(); err == nil && strings.Contains(string(out), "password=") {
		t.Fatalf("镜像凭据泄漏给了其他主机：%s", out)
	}

	credential, host, urlHost := httpCredentialForCommand(ctx, []string{"clone", "--progress", "--", mirrored, "."})
	if host != "gh-proxy.example" || urlHost != "gh-proxy.example" || credential.Token != "fake-mirror-token" {
		t.Fatalf("镜像命令解析成 host=%q urlHost=%q token=%q", host, urlHost, credential.Token)
	}
	if strings.Contains(strings.Join(cmd.Args, " "), "fake-mirror-token") {
		t.Fatal("token 被写进了 argv")
	}
}

func TestMirroredInnerURLRejectsPlainRemotes(t *testing.T) {
	for _, raw := range []string{
		"https://github.com/owner/repo.git",
		"https://gh-proxy.example/owner/repo.git",
		"https://gh-proxy.example/http://github.com/owner/repo.git",
		"git@github.com:owner/repo.git",
	} {
		if inner, ok := mirroredInnerURL(raw); ok {
			t.Fatalf("%s 不该被当成镜像地址，得到 %q", raw, inner)
		}
	}
	inner, ok := mirroredInnerURL("https://gh-proxy.example/https://github.com/owner/repo.git")
	if !ok || inner != "https://github.com/owner/repo.git" {
		t.Fatalf("内层地址 = %q ok=%v", inner, ok)
	}
}
