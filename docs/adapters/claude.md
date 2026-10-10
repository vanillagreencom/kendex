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
- Model dialect: classes project to native family aliases through `crates/core/src/harness/models.rs`. Consumer [native class bindings](../authoring/README.md#agent-models) apply only to Codex and Copilot. Fast projects to `sonnet` under [D021](../decisions/D021-runtime-model-classes.md) without claiming runtime availability. Core retains the source request. `inherit` remains literal. Exact ids follow D021's compatibility and Haiku substitution rules. `effort` is written as given: `low`, `medium`, `high`, `xhigh` or `max`, and an absent key inherits the session's level. The orch skill's Claude mod, `scripts/claude-model-classes`, runs only in a session that loads it with `--plugin-dir` or `CLAUDE_CODE_PLUGIN_DIRS`; managed launches do not load it yet. Claude supplies no model list, so with no `KENDEX_MODEL_CONTEXT` core does not select: the child keeps its model and the session prints core's warning once. A supplied `KENDEX_MODEL_CONTEXT` can make core select a child's model. Once loaded, the mod denies every subagent spawn when `kendex` v1.7.0 or later, which accepts `--runtime-context-json`, is missing from PATH or fails. The one warning needs the first kendex release after 1.11.0, the first to send core's warning line; kendex 1.11.0 or older gets one fixed line that asks for an upgrade. Before a declared subagent starts, the mod asks `kendex tier-model` about it and acts on the answer's tag:
  - `selected`: the child runs on core's selector in place of its own model.
  - `harness-default`, `inherit` and `unmanaged`: the spawn goes on unchanged, so Claude applies the Agent call's own `model`, or else the child's definition.
  - `refused`, and any core failure: the spawn is denied with core's text: its exit status, the first line of its stderr and the response's warning line.
- Root model request: the mod resolves the main session's model before each model call only when `KENDEX_MODEL_REQUEST` is set. A `selected` answer runs the call on core's selector, a kept default on the session's model, and a refusal or core failure shows core's text in place of the call. A person or a later launcher sets these variables before starting Claude. The first two serve the root request alone; a subagent spawn reads the last two as well:
  - `KENDEX_MODEL_REQUEST`: a class, native family, exact id or `inherit`. The mod clears it when core reports that the session's model changed natively.
  - `KENDEX_MODEL_SELECTED_SELECTOR`: the selector the session started on, which core compares with the current model to detect that change.
  - `KENDEX_MODEL_CONTEXT`: a `model-resolution-v1` runtime context as JSON, in place of the mod's own context of unknown access. A value that is not a JSON object stops every spawn, and every root model call while `KENDEX_MODEL_REQUEST` is set, with `invalid=KENDEX_MODEL_CONTEXT`.
  - `KENDEX_MODEL_WARNING_EMITTED`: `1` once the session printed its warning. The mod sets it; a launcher that printed the warning first sets it too.
- Tool vocabulary: Claude's PascalCase names are the fleet's authoring vocabulary; bodies pass through unrewritten, and manifest tool names are case-normalized by `claude_tool_name` (`crates/core/src/render/vocab/mod.rs`).
- Rendered agents are refused before the plan is shown when the frontmatter is missing or names another agent (`crates/core/src/render/validate/agent.rs`).

## Hooks

Enforced: Claude runs the registered command and gates the tool call on its exit status. The script lands at `<root>/hooks/<name>.sh` and the registration goes into that scope's `settings.json` under `hooks.<event>` in the nested matcher-plus-handlers shape; the command uses `$CLAUDE_PROJECT_DIR` at project scope and an absolute path at global scope, and a command that runs an installed script opens with a test that exits 0 in a Copilot CLI hook process (§ Cross-reads). Event names pass through unmapped and timeouts travel in seconds as declared. Disabling renames the script to `<name>.sh.disabled` and reverses the registration (`crates/core/src/engine/targets.rs`, `crates/core/src/engine/desired_kinds.rs`).

Agent scoping: a custom hook scoped to an agent lives in that agent's own `hooks:` block and is enforced there; an every-agent custom hook registers in `settings.json` and covers the main session too. Claude is the only harness with scoped enforcement (`crates/core/src/hook/delivery.rs`).

## Cross-reads

Copilot CLI reads `.claude/settings.json` and `.claude/settings.local.json` for `companyAnnouncements`, `disableAllHooks`, `enabledPlugins`, `extraKnownMarketplaces` and `hooks`, and discovers skills from `.claude/skills`; VS Code discovers agents from `.claude/agents`. The Copilot adapter claims none of these paths; a write kendex makes here that Copilot will read is reported as a note on the plan (`cross_read_note`, `crates/core/src/engine/desired_skill.rs`).

Copilot CLI runs each command in those `hooks` beside its own hooks, so a hook installed for both harnesses would run twice per Copilot event, and a hook whose `harnesses:` line leaves Copilot out would run on Copilot anyway. The command kendex registers here for each hook script it installs therefore opens with `[ -z "${COPILOT_PROJECT_DIR-}" ] || exit 0;`. Copilot sets `COPILOT_PROJECT_DIR` for every hook it starts and not for its tool calls, and Claude Code never sets it. A Copilot session runs only its native `.github/hooks` copy of such a hook, and a Claude Code session started from a Copilot tool call still runs its hooks. Copilot does not document the variable; it is measured on Copilot CLI 1.0.88 (`CLAUDE_OUTSIDE_COPILOT`, `crates/core/src/engine/targets.rs`). On each run of `tools/harness-smoke`, the Copilot `helper:env` row fails where a Copilot tool call carries the variable, and the `mixed-hook` rows check that Copilot runs its own copy and skips the `.claude/hooks` copies while Claude Code runs both; the nested-session behaviour is as measured on 1.0.88, and no row re-checks it. A custom hook declared as a command is registered as written, without the test, and Copilot CLI still runs it.

## Instruction shim

kendex writes no `CLAUDE.md`. It leaves former shims with the project under the [shared rule](README.md#instruction-shims), and retires the old `.claude/CLAUDE.md` link to the root `AGENTS.md` independently of the root instruction file (`crates/core/src/engine/instruction_shims.rs`).

[Claude Code reads `AGENTS.md` natively](https://code.claude.com/docs/en/memory#agents-md) from v2.1.277. Bedrock and telemetry-off sessions need v2.1.281. By default, a `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` in the working directory or above prevents native loading. A nested `AGENTS.md` loads when Claude reads a file there, unless that directory has one of those Claude files. Files under `.agents/` do not load.

`InstructionsLoaded` hooks do not fire for native `AGENTS.md` loading. Directories added with `--add-dir` do not load their `AGENTS.md`. A person who needs an older session, a disabled native plugin or Project instructions set to `claude-md` keeps their own `CLAUDE.md` with an `@AGENTS.md` import. The output-style route writes neither instruction file.

## Output styles

| Scope | Route | Drift and lock |
|---|---|---|
| Global | `~/.claude/output-styles/<name>.md` plus absent-only `outputStyle` in `~/.claude/settings.json` | Whole style file and owned selection recorded separately |
| Project | `.claude/output-styles/<name>.md` plus absent-only `outputStyle` in `.claude/settings.json`; no repository `AGENTS.md` block | Whole style file and owned selection recorded separately |

`settings.local.json` is read, never written. A selection there prevents seeding `settings.json`. A pre-existing selection stays user-owned. Enabling a style may acquire an absent selection. Replacing a style composes removal of its owned selection before insertion of the new one. A removed or changed selection kendex inserted is drift, not permission to restore it. Linked settings files are refused. The style keeps the built-in coding instructions through `keep-coding-instructions: true` ([native reference](https://code.claude.com/docs/en/output-styles)). `crates/core/tests/output_styles.rs` holds both scopes, reapply and hand edits.
