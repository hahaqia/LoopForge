# 智研工坊 Local usage

English | [简体中文](usage.zh-CN.md)

> **Legacy.** 智研工坊 Local runs built-in Classic and Portable workflows inside your coding assistant without a 智研工坊 server. You can keep using a published version for existing projects.

## Connect to 智研工坊 with MCP

Use CodeBuddy with a running 智研工坊 instance to access projects, SOPs, and runs on that instance. If you need an instance, see the [deployment guide](../deployment.md).

1. Sign in to 智研工坊 and open **Access** (接入方式). Create a personal access token and select **CodeBuddy** for its MCP setup instructions.
2. Apply the user-level configuration in CodeBuddy and confirm that the `agentflow` server is connected in the MCP settings. Ask CodeBuddy to list your 智研工坊 projects to verify access.

See the [MCP API reference](../api/README.md#公共能力发现与-mcp) for the endpoint and available operations.

## Quick start

Requires Node.js 20+ and Python 3.8+. Replace `X.Y.Z` in the commands below with the published version you use for your agent and edition. You can list published versions with `npm view zhiyan-cli versions --json`. Host support depends on the version you install.

| Agent | Install | Start a workflow |
| --- | --- | --- |
| CodeBuddy | `npx -y zhiyan-cli@X.Y.Z install codebuddy` | `/start-devflow "<request>"` |
| Codex | `npx -y zhiyan-cli@X.Y.Z install codex` | `$devflow-codex "<request>"` |
| Cursor | `npx -y zhiyan-cli@X.Y.Z install cursor` | `/start-devflow "<request>"` |
| Claude Code | `npx -y zhiyan-cli@X.Y.Z install claude` | `/start-devflow "<request>"` |
| DeepSeek Harness | `npx -y zhiyan-cli@X.Y.Z skills install dsh` | `/devflow "<request>"` |
| Hermes Agent | `npx -y zhiyan-cli@X.Y.Z skills install hermes` then `hermes skills trust .` | `/devflow "<request>"` |

For example, with Claude Code:

```bash
npx -y zhiyan-cli@X.Y.Z install claude
npx -y zhiyan-cli@X.Y.Z status claude
```

```text
/start-devflow "add status filtering to the order list and cover the API with tests"
```

Check any installation with `npx -y zhiyan-cli@X.Y.Z status <agent>`. If installation or execution fails, diagnose the environment:

```bash
npx -y zhiyan-cli@X.Y.Z doctor
```

Pi, DeepSeek Harness and Hermes Agent are supported through the [Portable Edition](#portable-edition). DSH has an optional [plugin](../../local/dsh-plugin/README.md) for task controls, status, artifacts and approval gates. Hermes uses its project-local Agent Skills discovery and `delegate_task` tool; it does not modify `~/.hermes/config.yaml`. Hermes users can optionally install the native [Hermes plugin](../../local/hermes-plugin/README.md) for the same `/zhiyan status`, `/zhiyan result` and `/zhiyan approve` controls.

## How it works

1. **Understand the problem first**: the agent inspects the project and clarifies the goal, scope, and acceptance criteria instead of immediately writing code.
2. **Confirm the boundaries before implementation**: medium and large tasks move into design and implementation only after you confirm the goal, scope, exclusions, key decisions, and acceptance criteria.
3. **Separate responsibilities**: design, implementation, review, and testing are handled stage by stage by roles with independent responsibilities, which reduces self-review bias in a single context.
4. **Show evidence, not just a diff**: requirements, plans, changes, review findings, and test results are saved for inspection, handoff, and retrospectives.
5. **Continue after interruption**: workflow state is persisted so the next session can resume at the unfinished stage instead of starting over.

智研工坊 picks the path by task complexity. Small changes take a streamlined single-role path; the full role-based workflow is reserved for medium and large tasks that benefit from it.

```text
Your request
   │
   ├─ Small change ───────> Understand → implement → verify → deliver
   │
   └─ Medium/large task ──> Clarify and confirm → design → implement
                                                   → independent review → test → deliver
                              │
                              └── State and artifacts are saved throughout
```

## Supported agents

| Agent | Classic Edition (default) | Portable Edition |
| --- | --- | --- |
| CodeBuddy | ✓ | ✓ |
| Codex | ✓ | ✓ |
| Cursor | ✓ | ✓ |
| Claude Code | ✓ | ✓ |
| Pi | — | ✓ |
| DeepSeek Harness | — | ✓ |
| Hermes Agent | — | ✓ |

智研工坊 enables only one edition per coding agent in each project. See [Edition selection](editions.md) for the differences and directory layout.

## What you get

At the end of a task, you get the code changes together with the confirmed requirement, technical design, independent review findings, test results, and delivery summary. 智研工坊 saves this history under `artifacts/{task_slug}/` by default for inspection, handoff, and retrospectives.

<details>
<summary>View the default artifact layout</summary>

Some directory names differ between editions.

```text
01-requirement/   Confirmed goals, scope, and acceptance criteria
02-design/        Technical design and execution plan
03-code/          Code changes and independent review report
04-e2e/           Test results
05-knowledge/     Reusable project knowledge
workflow-summary.md
```

</details>

Resume an interrupted Classic workflow with `/resume-devflow {task_slug}` on CodeBuddy, Cursor, or Claude Code, and with `$devflow-codex resume {task_slug}` on Codex. Each installed host bundle documents its status, abort, and individual-stage commands.

## See how agents work

The Classic Edition for CodeBuddy includes a local observability dashboard. It turns the workflow evidence into a view of session activity, Token and cost trends, Skill/Rule usage, role dispatch, and Devflow stage attribution—useful for finding expensive runs, checking whether automation is actually being used, and reviewing how work moved between roles.

![智研工坊 local agent observability dashboard with demonstration data](assets/agent-observability-dashboard.png)

_Dashboard example using synthetic demonstration data._

The dashboard is generated and served locally; it does not require an external telemetry service. Runtime logs can contain tool arguments and output excerpts, so 智研工坊 excludes them from Git by default and they should not be shared without review.

<details>
<summary>Open the local dashboard</summary>

After running at least one CodeBuddy session from the project root:

```bash
python3 .codebuddy/skills/agent-observability/scripts/build_dashboard_data.py --project-root .
python3 -m http.server 8765 --directory .codebuddy/skills/agent-observability/scripts/dashboard
```

Open `http://localhost:8765`. See the [observability quickstart](../../local/.codebuddy/skills/agent-observability/references/quickstart.md) for data sources, custom pricing, and troubleshooting.

</details>

## When 智研工坊 is useful

智研工坊 is especially useful when:

- the request is still ambiguous and the goal or boundaries need clarification;
- a change crosses multiple modules and should be designed before implementation;
- implementation, review, and testing should be performed by separate roles;
- work may span multiple sessions and needs resumable state;
- the team wants an inspectable delivery record for handoff or retrospectives.

For one-off code completion or a tiny, fully specified edit, using a coding agent directly is often enough. Simple tasks that do enter 智研工坊 use its streamlined path.

## Portable Edition

Use the Portable Edition for the portable Agent Skills workflow. To prevent one coding agent from loading two workflows and mixing their state or artifacts, 智研工坊 enables only one edition per coding agent in each project. To switch editions, run the new install command with `--force`.

| Agent | Install | Start a workflow |
| --- | --- | --- |
| CodeBuddy | `npx -y zhiyan-cli@X.Y.Z skills install codebuddy` | `/devflow "<request>"` |
| Codex | `npx -y zhiyan-cli@X.Y.Z skills install codex` | `$devflow "<request>"` |
| Cursor | `npx -y zhiyan-cli@X.Y.Z skills install cursor` | `/devflow "<request>"` |
| Claude Code | `npx -y zhiyan-cli@X.Y.Z skills install claude` | `/devflow "<request>"` |
| Pi | `npx -y zhiyan-cli@X.Y.Z skills install pi`, then `pi install npm:pi-subagents` | `/skill:devflow "<request>"` |
| DeepSeek Harness | `npx -y zhiyan-cli@X.Y.Z skills install dsh` | `/devflow "<request>"` |
| Hermes Agent | `npx -y zhiyan-cli@X.Y.Z skills install hermes`, then `hermes skills trust .` | `/devflow "<request>"` (optional plugin: `/zhiyan`) |

See [Edition selection](editions.md) for the complete boundaries and directory layout.

## Update and uninstall

Before switching to platform MCP or uninstalling Local, back up your project's `artifacts/`, `.devflow/`, and any customized skills and agent configuration. Keep these files as the record of your Local runs. Use the same Local version to finish or resume any runs still in progress.

To manage an existing Local installation, you can install the same CLI version globally.

```bash
npm install --global zhiyan-cli@X.Y.Z
```

Then maintain an installation with the same agent names as above (`codebuddy`, `codex`, `cursor`, `claude`, `pi`, `dsh`, and `hermes` for the Portable Edition):

```bash
# Classic Edition
zhiyan update <agent>
zhiyan status <agent>
zhiyan uninstall <agent>

# Portable Edition
zhiyan skills update <agent>
zhiyan skills status <agent>
zhiyan skills uninstall <agent>
```

Installation state is stored in `.devflow/install-state.json`. An update stops instead of overwriting user-modified or conflicting files. Use `--force` only when you intend to replace conflicts or switch editions, preferably after inspecting `zhiyan plan`.

To install from the source of a published release, check out its tag and run the following from the repository root.

```bash
pipx install ./local
```

## Optional tools

`tools/tcmcp` is a Tencent Cloud read-only MCP Initializr (Redis, CDB, TDSQL-C, TKE, CLS, COS). It is not part of `zhiyan install` or the npm CLI package. From a clone:

```bash
cd local/tools/tcmcp
```

Then follow [`tools/tcmcp/README.md`](../../local/tools/tcmcp/README.md). Cloud API keys are not written into generated zips or the container image; they stay on the machine that lists resources or installs the MCP client. 智研工坊 Local `local-vX.Y.Z` releases publish `ghcr.io/tencent/zhiyan-tcmcp:<version>`.

## Permissions and security

Some Classic host configurations enable automatic execution or high-permission agent modes. Use 智研工坊 only in trusted projects. Before installation, inspect planned files with `zhiyan plan codebuddy`, `zhiyan plan codex`, `zhiyan plan cursor`, or `zhiyan plan claude`. Do not put credentials, private endpoints, or production operations configuration in workflow templates.

See [Security policy](../../SECURITY.md) and report vulnerabilities privately through GitHub Security Advisories.
