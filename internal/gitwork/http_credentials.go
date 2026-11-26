package gitwork

import (
	"context"
	"net/url"
	"os"
	"strings"
)

// HTTPCredential authenticates exactly one HTTPS host. The map containing it
// belongs to a live execution; it is never written to a checkout or git config.
type HTTPCredential struct {
	Username string
	Token    string
}

type httpCredentialsKey struct{}
type httpRemoteKey struct{}

// WithHTTPCredentials binds the only HTTPS credentials this execution may use.
// Empty and nil maps deliberately provide no credentials.
func WithHTTPCredentials(ctx context.Context, credentials map[string]HTTPCredential) context.Context {
	return context.WithValue(ctx, httpCredentialsKey{}, credentials)
}

// WithHTTPRemote identifies the repository for commands such as fetch origin,
// whose arguments do not contain its URL. Explicit URL arguments take priority.
func WithHTTPRemote(ctx context.Context, remote string) context.Context {
	return context.WithValue(ctx, httpRemoteKey{}, remote)
}

// mirroredInnerURL 取出下载镜像形式里的原始地址：
// https://gh-proxy.com/https://github.com/owner/repo.git 返回内层的
// https://github.com/owner/repo.git。镜像只换了实际连接的机器，凭据仍然
// 属于原始仓库，所以查凭据要用内层 host，而 helper 匹配的是镜像 host。
func mirroredInnerURL(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || !strings.EqualFold(u.Scheme, "https") {
		return "", false
	}
	inner := strings.TrimPrefix(u.Path, "/")
	if !strings.HasPrefix(inner, "https://") {
		return "", false
	}
	if innerURL, err := url.Parse(inner); err != nil || innerURL.Host == "" {
		return "", false
	}
	return inner, true
}

func httpCredentialForCommand(ctx context.Context, args []string) (credential HTTPCredential, host, urlHost string) {
	credentials, _ := ctx.Value(httpCredentialsKey{}).(map[string]HTTPCredential)
	if len(credentials) == 0 {
		return HTTPCredential{}, "", ""
	}
	remote, _ := ctx.Value(httpRemoteKey{}).(string)
	for _, arg := range args {
		if strings.HasPrefix(arg, "https://") || strings.HasPrefix(arg, "http://") || IsSSHReference(arg) {
			remote = arg
			break
		}
	}
	u, err := url.Parse(remote)
	if err != nil || u.Scheme != "https" {
		return HTTPCredential{}, "", ""
	}
	connection := "https://" + u.Host
	if inner, ok := mirroredInnerURL(remote); ok {
		remote = inner
	}
	credentialURL, err := url.Parse(remote)
	if err != nil || credentialURL.Scheme != "https" {
		return HTTPCredential{}, "", ""
	}
	host, err = HTTPSHostScope(connection)
	if err != nil {
		return HTTPCredential{}, "", ""
	}
	credentialHost, err := HTTPSHostScope("https://" + credentialURL.Host)
	if err != nil {
		return HTTPCredential{}, "", ""
	}
	credential = credentials[credentialHost]
	if credential.Username == "" {
		credential.Username = "x-access-token"
	}
	// Git can pass either the URL's original spelling or the normalized IPv6
	// authority from its HTTP transport to the credential helper.
	return credential, host, strings.TrimSuffix(strings.ToLower(u.Host), ":443")
}

const (
	gitHTTPHostEnv    = "AGENTFLOW_GIT_HTTP_HOST"
	gitHTTPURLHostEnv = "AGENTFLOW_GIT_HTTP_URL_HOST"
)

// scopedCredentialHelper accepts Git's protocol, rather than returning a
// password to every host a redirect, submodule or checkout might request.
func scopedCredentialHelper() string {
	return `!f() {
		test "$1" = get || exit 0
		protocol= host=
		while IFS= read -r line && test -n "$line"; do
			case "$line" in
				protocol=*) protocol=${line#protocol=} ;;
				host=*) host=${line#host=} ;;
			esac
		done
		test "$protocol" = https || exit 0
		host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
		case "${host%:443}" in
			"$` + gitHTTPHostEnv + `"|"$` + gitHTTPURLHostEnv + `")
				printf 'username=%s\npassword=%s\n' "$` + gitHTTPUserEnv + `" "$` + gitHTTPPassEnv + `" ;;
		esac
	}; f`
}

func scopedHTTPAuthArgs(credential HTTPCredential) []string {
	args := []string{"-c", "credential.helper="}
	if credential.Token != "" {
		args = append(args, "-c", "credential.helper="+scopedCredentialHelper())
	}
	return args
}

func privateHTTPHome(ctx context.Context) (string, func(), error) {
	if UsesSSH(ctx) {
		return "", func() {}, nil
	}
	home, err := os.MkdirTemp("", "zhiyan-git-home-")
	return home, func() { _ = os.RemoveAll(home) }, err
}

func redactContextGitSecrets(ctx context.Context, text string) string {
	credentials, _ := ctx.Value(httpCredentialsKey{}).(map[string]HTTPCredential)
	for _, credential := range credentials {
		text = Redact(text, credential.Token)
	}
	return text
}
