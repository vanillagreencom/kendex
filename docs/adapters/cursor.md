# Cursor

A narrow adapter, managed in projects only: an agent installs as a rule file, a project skill goes to the shared `.agents/skills` tree, and nothing about a rule is enforced. Owner: `crates/core/src/harness/cursor.rs`.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.cursor` | nothing |
| Project | `<project>/.cursor` | nothing |

Project marker: a `.cursor/` directory.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | — | `.cursor/rules/*.mdc` | managed, project only |
| skill | — | `.agents/skills/<name>/SKILL.md`, with `.cursor/skills/<name>/SKILL.md` for a copy delivery | managed, project only |
| hook | `~/.cursor/hooks.json` | `.cursor/hooks.json` | observe both; install, toggle, remove, refresh project only; advisory |
| command | `~/.cursor/commands/*.md` | `.cursor/commands/*.md` | observe only, both |
| mcp-server | `~/.cursor/mcp.json` | `.cursor/mcp.json` | observe only, both |
| plugin | `~/.cursor/plugins/{local,cache}` with `.cursor-plugin/plugin.json` | — | observe only, global |
| pi-extension | — | — | unsupported |

Cursor has no global rules directory and no documented global skills path, so both stay unsupported at global scope while the global command, MCP and plugin surfaces are scanned. `hooks.json` is observed at both scopes and never written.

## Format

- Name rule `Any`; namespace separator `__`.
- MCP transports: stdio, streamable HTTP, SSE.
- Rule file: `<name>.mdc`, YAML frontmatter and markdown. Fields written: `description` (the agent's name and description joined) and `alwaysApply: false`; a rule carries no model, tool, skill or hook field, so only the prompt survives (`crates/core/src/render/agent/cursor.rs`).
- Model dialect: every tier resolves to nothing and the field is dropped (`crates/core/src/harness/models.rs`).
- Frontmatter keys Cursor honours: `description`, `globs`, `alwaysApply`; anything else is an advisory finding (`CURSOR_KEYS`, `crates/core/src/render/validate/agent.rs`).
- Permissions: a rule grants no tools and enforces none; any intent other than `Unspecified` warns that the restriction is advisory text, and dropping Cursor from the agent's harnesses is the way to make it hold.

## Hooks

Advisory, and the artifact is a rule, not a registration: a Cursor hook is `.cursor/rules/safety-<name>.mdc` carrying the hook's description and safety prose with `alwaysApply: true` (`HookTarget::Rule`, `crates/core/src/engine/targets.rs`). The global scope has no hook target, so a hook declared for Cursor at global scope installs nothing. Disabling renames the rule file to `.disabled`.

## Not supported

Writing commands: Cursor has deprecated slash commands in favour of skills (every commands page redirects to the skills migration, and `/migrate-to-skills` converts them), so `.cursor/commands` is read and never written, and a skill with `disable-model-invocation: true` is the successor.
