# Claude Code

The first-class harness: every kind but Pi extensions has a native surface, and agent bodies and hook matchers across the fleet are authored in Claude's own vocabulary. Owner: `crates/core/src/harness/claude.rs`.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.claude` | nothing |
| Project | `<project>/.claude` | nothing |

Project markers: a `.claude/` directory, or a `.mcp.json` file at the repo root.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.claude/agents/*.md` | `.claude/agents/*.md` | managed, both |
| skill | `~/.claude/skills/<name>/SKILL.md` | `.claude/skills/<name>/SKILL.md` | managed, both |
| command | `~/.claude/commands/*.md` | `.claude/commands/*.md` | managed, both |
| hook | `~/.claude/settings.json` → `hooks` | `.claude/settings.json` and `.claude/settings.local.json` → `hooks` | managed, both, enforced |
| mcp-server | `~/.claude.json` top-level `mcpServers` | `.mcp.json`, plus `~/.claude.json` `projects.<root>.mcpServers` | managed, both |
| plugin | `~/.claude/plugins/installed_plugins.json` joined with settings `enabledPlugins` | `.claude/settings.json` and `.claude/settings.local.json` `enabledPlugins` | observe and toggle, both |
| pi-extension | — | — | unsupported |

MCP servers are written to `~/.claude.json` at global scope and to the repository's `.mcp.json` at project scope (`mcp_registry`, `crates/core/src/engine/targets.rs`). `settings.local.json` is observed and never written. Only the plugin enable flip is written.

A project skill lives in the shared `.agents/skills/<name>` tree, and `.claude/skills/<name>` is a relative link onto it (`../../.agents/skills/<name>`) when the bytes match, committed once and resolving in every clone; an absolute link from an older install is drift and is rewritten on the next apply. Global variants live under the app data directory (`rendered_skills_dir`, `crates/core/src/env.rs`).

## Format

- Name rule `Any`; namespace separator `__`.
- MCP transports: stdio, streamable HTTP, SSE.
- Agent file: YAML frontmatter and a markdown body, `<name>.md`. Fields written: `name`, `description`, `model`, `effort`, `background`, `isolation`, `memory`, `tools` (allowlist, comma-joined), `disallowedTools` always, `color`, `skills`, and a nested `hooks:` block for per-agent custom hooks (`crates/core/src/render/agent/claude.rs`).
- Model dialect: every tier pins its own alias (`fable`, `opus`, `sonnet`, `haiku`); `inherit` is the literal `inherit`; explicit vendor ids pass through (`crates/core/src/harness/models.rs`). `effort` is written as given: `low`, `medium`, `high`, `xhigh` or `max`, and an absent key inherits the session's level.
- Tool vocabulary: Claude's PascalCase names are the fleet's authoring vocabulary; bodies pass through unrewritten, and manifest tool names are case-normalized by `claude_tool_name` (`crates/core/src/render/vocab/mod.rs`).
- Rendered agents are refused before the plan is shown when the frontmatter is missing or names another agent (`crates/core/src/render/validate/agent.rs`).

## Hooks

Enforced: Claude runs the registered command and gates the tool call on its exit status. The script lands at `<root>/hooks/<name>.sh` and the registration goes into that scope's `settings.json` under `hooks.<event>` in the nested matcher-plus-handlers shape; the command uses `$CLAUDE_PROJECT_DIR` at project scope and an absolute path at global scope. Event names pass through unmapped and timeouts travel in seconds as declared. Disabling renames the script to `<name>.sh.disabled` and reverses the registration (`crates/core/src/engine/targets.rs`, `crates/core/src/engine/desired_kinds.rs`).

Agent scoping: a custom hook scoped to an agent lives in that agent's own `hooks:` block and is enforced there; an every-agent custom hook registers in `settings.json` and covers the main session too. Claude is the only harness with scoped enforcement (`crates/core/src/hook/delivery.rs`).

## Cross-reads

Copilot CLI reads `.claude/settings.json` and `.claude/settings.local.json` for `companyAnnouncements`, `disableAllHooks`, `enabledPlugins`, `extraKnownMarketplaces` and `hooks`, and discovers skills from `.claude/skills`; VS Code discovers agents from `.claude/agents`. The Copilot adapter claims none of these paths; a write kendex makes here that Copilot will read is reported as a note on the plan (`cross_read_note`, `crates/core/src/engine/desired_skill.rs`).

## Instruction shim

Claude reads `CLAUDE.md` only, at the root and lazily in subdirectories, so kendex writes a `CLAUDE.md` holding `@AGENTS.md` beside every tracked `AGENTS.md` (`crates/core/src/engine/instruction_shims.rs`).
