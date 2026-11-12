# Skills, plugins, and project instructions

## Skills

Marlin supports [Agent Skills](https://agentskills.io/specification): a directory
containing `SKILL.md` with YAML `name` and `description`, Markdown instructions,
and optional `scripts/`, `references/`, and `assets/`. For example:

```text
.agents/skills/code-review/SKILL.md
```

```markdown
---
name: code-review
description: Review code changes for correctness and missing tests.
---
Read the diff and check the affected callers.
See references/checklist.md for the review checklist.
```

Skills are discovered in this order (the first matching name wins):

1. `<cwd>/.marlin/skills/`
2. `<cwd>/.agents/skills/`
3. The configured `[skills].directories`, which default to
   `~/.config/marlin/skills/` (or `$XDG_CONFIG_HOME/marlin/skills/`) and
   `~/.agents/skills/`.

Project skills are refreshed for each native turn and slash invocation,
including after `/cwd` changes; discovery is relative to the exact session cwd,
not its ancestors. User skills are indexed at daemon startup; `/mcp reload`
refreshes them. Custom `[skills].directories` replace the user defaults.
Symlinked skill directories work. Legacy flat `.md` skills directly in a
skills root remain supported. Bundled reference documents are not indexed as
separate skills. Invalid files and shadowed names are reported in daemon logs.

Native agents see only the catalog until they call the `skill` tool. Activation
provides instructions, metadata, and the absolute resource directory; resources
are read or executed through the regular tools as needed. YAML supports quoted,
literal and folded strings and nested metadata. Optional `license`,
`compatibility`, `metadata`, and `allowed-tools` fields are preserved;
`allowed-tools` is advisory and does not change Marlin's permission checks.

For explicit invocation, type `/skill-name` or `/skill-name <arguments>`. Marlin
sends the full instructions to the agent, substituting `$ARGUMENTS`,
`$ARGUMENTS[N]`, and `$N`. Positional arguments are zero-based and support
quoting; arguments are appended when there are no placeholders. Unknown skills
return an error. The transcript shows your slash command, while the rendered
instructions remain in model context. Marlin commands take precedence when
names overlap. Guest agents receive explicitly invoked Marlin skills through
the same path; automatic discovery and activation during guest turns are
handled by the guest harness. Client-specific frontmatter execution settings
and dynamic shell templates are not implemented by Marlin.

## Plugins

Claude Code plugin marketplaces can also be installed directly. Plugins may
carry skills and MCP servers (see docs/CONFIGURATION.md); hooks, agents, and
commands are refused:

```text
/plugin marketplace add miradorlabs/agent-plugins
/plugin install mirador@miradorlabs
/mirador:submit-pr <optional PR title>
```

Use `/plugin list`, `/plugin marketplace update miradorlabs`, and
`/plugin uninstall mirador@miradorlabs` to manage installations. Uninstall a
marketplace's plugins before `/plugin marketplace remove miradorlabs`. The same
commands work from the terminal as `marlin plugin ...`. GitHub `owner/repo`,
HTTPS/SSH Git URLs, and local Git repositories are accepted; private repositories
use your existing Git credentials. For local paths containing spaces, use the
terminal command with a quoted argument.

Type `/` or a prefix such as `/mirador:` to see installed skills and their
descriptions. Use arrow keys to select and Tab to complete, then add arguments
and press Enter. Completion refreshes after plugin changes and `/cwd` changes.

This first version supports plugins with `.claude-plugin/plugin.json` and the
standard `skills/` directory, sourced by a relative path inside the marketplace
repository. Hooks, MCP/LSP servers, agents, legacy commands, custom component
paths, and external plugin sources are rejected explicitly. Skill instructions
still use the current harness's tools and permissions; importing a plugin does
not implement Claude-specific execution features.

Installations are Marlin-specific and take effect on the next native turn or
explicit skill invocation, without `/mcp reload`. Installed skills use
`plugin-name:skill-name`; installing the same plugin name from two marketplaces
is rejected. Updates validate installed plugins before atomically switching
snapshots. Existing turns keep their previous instructions and resource paths.
Snapshots are stored under the Marlin config directory's `plugins/` folder and
are retained after update/uninstall so those paths remain usable; automatic
cache cleanup is not yet implemented.

## Project instructions

Native agents automatically read project instructions before the first turn
and again on each subsequent turn, including after `/cwd` changes. Marlin uses
the first nonempty readable file in the session cwd in this order:
`MARLIN.md`, `AGENTS.md`, `AGENT.md`.
