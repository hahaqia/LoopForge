# 智研工坊 Hermes plugin

This native Hermes Agent plugin adds `/zhiyan` controls for a project that
already has the 智研工坊 Hermes Skill installed:

```text
/zhiyan start <request>
/zhiyan status [slug]
/zhiyan result [slug]
/zhiyan approve [REQUIREMENT|DESIGN|REVIEW|TEST]
```

The plugin calls the project's `.hermes/skills/devflow/scripts/workflow_state.py`
contract. It stores state under `artifacts/<slug>/` and does not read or modify
`~/.hermes/config.yaml`, profile credentials, or the profile skill directory.

## Local installation

From a 智研工坊 checkout, validate the plugin first:

```bash
hermes plugins doctor ./local/hermes-plugin
```

For a local Hermes profile, copy the directory to the profile's plugin folder
and restart Hermes. The copy is intentionally explicit so an existing plugin
directory is never overwritten by 智研工坊:

```bash
plugin_dir="${HERMES_HOME:-$HOME/.hermes}/plugins/zhiyan"
if [ -e "$plugin_dir" ]; then
  echo "Refusing to overwrite existing Hermes plugin: $plugin_dir" >&2
  exit 1
fi
mkdir -p "$(dirname "$plugin_dir")"
cp -a ./local/hermes-plugin "$plugin_dir"
```

When this repository is published, install the same directory through Hermes'
normal Git plugin flow (`hermes plugins install <owner>/<repo>`), then enable it
with `hermes plugins enable zhiyan`.

To update a published installation, use `hermes plugins update zhiyan`. To
disable it without deleting files, use `hermes plugins disable zhiyan`; to
remove it, disable it first and then run `hermes plugins remove zhiyan`.
For a local copied installation, remove only the exact directory you copied
after disabling the plugin.

Run Hermes from the project root after installing the Skill and trust it:

```bash
zhiyan skills install hermes
hermes skills trust .
hermes
```

The plugin is optional. `/devflow` remains the canonical workflow entrypoint.
