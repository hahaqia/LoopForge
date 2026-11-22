# 智研工坊 Local

> **旧版（Legacy）。** 已发布的 `zhiyan-cli` 版本仍可安装。平台项目和 SOP 可通过 [智研工坊 MCP](https://github.com/zhiyan/zhiyan/blob/main/docs/local/usage.zh-CN.md#通过-mcp-连接-zhiyan) 接入。
>
> **Legacy.** Previously published versions of `zhiyan-cli` remain available. To work with platform projects and SOPs, [connect to 智研工坊 over MCP](https://github.com/zhiyan/zhiyan/blob/main/docs/local/usage.md#connect-to-zhiyan-with-mcp).

智研工坊 的本地工作流组件，在 CodeBuddy、Codex、Cursor、Claude Code、Pi、DeepSeek Harness 或 Hermes Agent 中使用，无需启动平台。

Local workflows for 智研工坊, running inside an existing coding assistant without the platform server.

Requires **Node.js 20+ and Python 3.8+**, plus a supported coding assistant. This npm package installs Local workflows, not the Docker platform.

需要 **Node.js 20+、Python 3.8+** 和受支持的编程助手。此 npm 包安装本地工作流，不安装 Docker 平台。

Classic workflows configure agent execution permissions and hooks. Review the generated configuration before use; only install into projects you trust and back up existing settings. See the [security policy](https://github.com/zhiyan/zhiyan/blob/main/SECURITY.md).

Classic 工作流会配置 Agent 执行权限与 Hook。使用前请检查安装配置，仅安装到可信项目，并备份已有设置；权限边界见[安全政策](https://github.com/zhiyan/zhiyan/blob/main/SECURITY.zh-CN.md)。

```bash
# Run in the project where you want to install the workflow.
# 在需要使用工作流的目标项目中运行。
# Replace X.Y.Z with the published version for your setup.
# 将 X.Y.Z 替换为与你的环境匹配的已发布版本。
npx -y zhiyan-cli@X.Y.Z install claude
npx -y zhiyan-cli@X.Y.Z status claude
```

Start with `/start-devflow "<request>"` in Claude Code. Replace `claude` with `codebuddy`, `codex`, or `cursor` when installing for another host; use `skills install pi`, `skills install dsh`, or `skills install hermes` for Portable hosts. DSH uses `/devflow "<request>"` after installing the Skill, and the optional DSH plugin adds `/zhiyan` task controls. Hermes loads the project skill after `hermes skills trust .`; its optional native plugin adds the same `/zhiyan` controls.

在 Claude Code 中通过 `/start-devflow "<需求>"` 启动。其他宿主的安装命令、入口及 Portable 用法见统一文档。

- [使用指南](https://github.com/zhiyan/zhiyan/blob/main/docs/local/usage.zh-CN.md) · [Usage guide](https://github.com/zhiyan/zhiyan/blob/main/docs/local/usage.md)
- [Classic / Portable](https://github.com/zhiyan/zhiyan/blob/main/docs/local/editions.md)
- [项目首页 / Project](https://github.com/zhiyan/zhiyan) · [贡献 / Contributing](https://github.com/zhiyan/zhiyan/blob/main/CONTRIBUTING.md)

已有包名 `zhiyan-cli`、`devflow-workflow` 和 `zhiyan` 命令保持兼容。

Existing package names and commands remain compatible.

Third-party notices are maintained at the repository root. Packaging generates a local notice and includes it with `LICENSE` in npm, Python and release archives. Project policies and release history are shared at the repository root.
