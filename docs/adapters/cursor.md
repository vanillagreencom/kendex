# Cursor

A narrow adapter. Cursor has rules and the shared skills tree: an agent
installs as a rule file, a project skill goes to `.agents/skills` like every
other tool that reads it, and nothing about a rule is enforced.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.cursor` | nothing |
| Project | `<project>/.cursor` | — |

Project marker: a `.cursor/` directory. Owner:
`crates/core/src/harness/cursor.rs`.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | — no global rules dir | `.cursor/rules/*.mdc` | managed, project only |
| skill | — no documented global skills dir | `.agents/skills/<name>/SKILL.md` | managed, project only |
| hook | `~/.cursor/hooks.json` | `.cursor/hooks.json` | observe both; install/toggle/remove/refresh project only; **advisory** |
| command | `~/.cursor/commands/*.md` | `.cursor/commands/*.md` | observe only, both |
| mcp-server | `~/.cursor/mcp.json` | `.cursor/mcp.json` | observe only, both |
| plugin | `~/.cursor/plugins/{local,cache}` with `.cursor-plugin/plugin.json` | — | observe only, global |
| pi-extension | — | — | unsupported |

**Skills go in the shared tree.** Cursor's own project directory cannot
tell a skill from a rule, so kendex never writes one there; it writes the
`.agents/skills` tree Cursor reads along with Codex, Pi, OpenCode, Gemini
and Copilot. There is no documented global skills path, so global stays
unsupported.

**Cursor is managed project-only.** The global agent surface is empty; the
global command, MCP and plugin surfaces are scanned.

## Format facts

- **Name rule:** `Any`. Namespace separator `__`.
- **MCP transports:** stdio, streamable HTTP, SSE — a command, an SSE url or
  a streamable-HTTP url ([cursor.com/docs/context/mcp](https://cursor.com/docs/context/mcp)).
- **Rule file:** `<name>.mdc`, YAML frontmatter + markdown. kendex writes
  exactly `description` (the agent's name and description joined) and
  `alwaysApply: false`. Rules carry no model, tool, skill or hook fields;
  only the prompt survives (`crates/core/src/render/agent/cursor.rs`).
- **Model dialect:** every tier resolves to nothing — the renderer drops the
  field.
- **Frontmatter keys Cursor honors:** `description`, `globs`, `alwaysApply`.
  Anything else the validator reports as advisory
  (`CURSOR_KEYS`, `crates/core/src/render/validate/agent.rs`).
- **Agent scoping:** not applicable — hooks are advisory here, whoever
  they are scoped to.

## Permissions

A rule grants no tools and enforces none. Any intent other than
`Unspecified` produces a warning that the restriction is advisory text only;
drop Cursor from that agent's harnesses if the restriction must hold.

## Hooks

**Advisory, and the artifact is a rule, not a registration.** A Cursor hook
is a `.mdc` file at `.cursor/rules/safety-<name>.mdc` carrying the hook's
description and its safety prose with `alwaysApply: true`, and there is no
registration behind it (`HookTarget::Rule`,
`crates/core/src/engine/targets.rs`).

`hooks.json` is observed at both scopes and never written; what kendex
writes is a rule in the rules directory. The global scope has no hook
target — a hook declared for Cursor at global scope installs nothing.

Disabling renames the rule file to `.disabled`.
