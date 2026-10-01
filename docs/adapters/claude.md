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

MCP servers are written to `~/.claude.json` at global scope and to the repository's `.mcp.json` at project scope (`mcp_registry`, `crates/core/src/engine/targets.rs`). `settings.local.json` is observed and never written. The plugin enable flip and output-style selection are settings writes.

Claude Code reads no shared skills tree at either scope, so its own directory holds a link onto one. A project skill lives in the shared `.agents/skills/<name>` tree, and `.claude/skills/<name>` is a relative link onto it (`../../.agents/skills/<name>`) when the bytes match, committed once and resolving in every clone; an absolute link from an older install is drift and is rewritten on the next apply. A global skill lives in `~/.agents/skills/<name>` and `~/.claude/skills/<name>` is an absolute link onto it (`global_skills_dir`, `crates/core/src/env.rs`).

## Format

- Name rule `Any`; namespace separator `__`.
- MCP transports: stdio, streamable HTTP, SSE.
- Agent file: YAML frontmatter and a markdown body, `<name>.md`. Fields written: `name`, `description`, `model`, `effort`, `background`, `isolation`, `memory`, `tools` (allowlist, comma-joined), `disallowedTools` always, `color`, `skills`, and a nested `hooks:` block for per-agent custom hooks (`crates/core/src/render/agent/claude.rs`).
- Model dialect: every tier pins its own alias (`fable`, `opus`, `sonnet`, `haiku`); `inherit` is the literal `inherit`; explicit vendor ids pass through (`crates/core/src/harness/models.rs`). `effort` is written as given: `low`, `medium`, `high`, `xhigh` or `max`, and an absent key inherits the session's level.
- Tool vocabulary: Claude's PascalCase names are the fleet's authoring vocabulary; bodies pass through unrewritten, and manifest tool names are case-normalized by `claude_tool_name` (`crates/core/src/render/vocab/mod.rs`).
- Rendered agents are refused before the plan is shown when the frontmatter is missing or names another agent (`crates/core/src/render/validate/agent.rs`).

## Hooks

Enforced: Claude runs the registered command and gates the tool call on its exit status. The script lands at `<root>/hooks/<name>.sh` and the registration goes into that scope's `settings.json` under `hooks.<event>` in the nested matcher-plus-handlers shape; the command uses `$CLAUDE_PROJECT_DIR` at project scope and an absolute path at global scope, and a command that runs an installed script opens with a test that exits 0 in a Copilot CLI hook process (§ Cross-reads). Event names pass through unmapped and timeouts travel in seconds as declared. Disabling renames the script to `<name>.sh.disabled` and reverses the registration (`crates/core/src/engine/targets.rs`, `crates/core/src/engine/desired_kinds.rs`).

Agent scoping: a custom hook scoped to an agent lives in that agent's own `hooks:` block and is enforced there; an every-agent custom hook registers in `settings.json` and covers the main session too. Claude is the only harness with scoped enforcement (`crates/core/src/hook/delivery.rs`).

## Cross-reads

Copilot CLI reads `.claude/settings.json` and `.claude/settings.local.json` for `companyAnnouncements`, `disableAllHooks`, `enabledPlugins`, `extraKnownMarketplaces` and `hooks`, and discovers skills from `.claude/skills`; VS Code discovers agents from `.claude/agents`. The Copilot adapter claims none of these paths; a write kendex makes here that Copilot will read is reported as a note on the plan (`cross_read_note`, `crates/core/src/engine/desired_skill.rs`).

Copilot CLI runs each command in those `hooks` beside its own hooks, so a hook installed for both harnesses would run twice per Copilot event, and a hook whose `harnesses:` line leaves Copilot out would run on Copilot anyway. The command kendex registers here for each hook script it installs therefore opens with `[ -z "${COPILOT_PROJECT_DIR-}" ] || exit 0;`. Copilot sets `COPILOT_PROJECT_DIR` for every hook it starts and not for its tool calls, and Claude Code never sets it. A Copilot session runs only its native `.github/hooks` copy of such a hook, and a Claude Code session started from a Copilot tool call still runs its hooks. Copilot does not document the variable; it is measured on Copilot CLI 1.0.88 (`CLAUDE_OUTSIDE_COPILOT`, `crates/core/src/engine/targets.rs`). On each run of `tools/harness-smoke`, the Copilot `helper:env` row fails where a Copilot tool call carries the variable, and the `mixed-hook` rows check that Copilot runs its own copy and skips the `.claude/hooks` copies while Claude Code runs both; the nested-session behaviour is as measured on 1.0.88, and no row re-checks it. A custom hook declared as a command is registered as written, without the test, and Copilot CLI still runs it.

## Instruction shim

kendex writes a `CLAUDE.md` holding `@AGENTS.md` beside every tracked `AGENTS.md` (`crates/core/src/engine/instruction_shims.rs`). Claude Code also reads `AGENTS.md` natively from v2.1.277 where no `CLAUDE.md` exists. The output-style route writes neither instruction file.

## Output styles

| Scope | Route | Drift and lock |
|---|---|---|
| Global | `~/.claude/output-styles/<name>.md` plus absent-only `outputStyle` in `~/.claude/settings.json` | Whole style file and owned selection recorded separately |
| Project | `.claude/output-styles/<name>.md` plus absent-only `outputStyle` in `.claude/settings.json`; no repository `AGENTS.md` block | Whole style file and owned selection recorded separately |

`settings.local.json` is read, never written. A selection there prevents seeding `settings.json`. A pre-existing selection stays user-owned. Enabling a style may acquire an absent selection. Replacing a style composes removal of its owned selection before insertion of the new one. A removed or changed selection kendex inserted is drift, not permission to restore it. Linked settings files are refused. The style keeps the built-in coding instructions through `keep-coding-instructions: true` ([native reference](https://code.claude.com/docs/en/output-styles)). `crates/core/tests/output_styles.rs` holds both scopes, reapply and hand edits.
