# GitHub Copilot

Copilot is four products sharing filenames; kendex treats Copilot CLI plus repository files as the harness and ignores the rest. Copilot reads more configuration than kendex owns, so a page of what makes an install inert matters here. Owner: `crates/core/src/harness/copilot/mod.rs`. Facts are checked against docs.github.com and code.visualstudio.com; the record is [gemini-copilot-matrix.md](gemini-copilot-matrix.md).

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.copilot` | `COPILOT_HOME`, which moves the whole config root |
| Project | `<project>/.github` | nothing |

Project markers: `.github/copilot-instructions.md`, or a `.github/agents`, `.github/skills` or `.github/hooks` directory. `.github/` on its own is not a marker.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.copilot/agents/*.agent.md` | `.github/agents/*.agent.md` | managed, both |
| skill | `~/.agents/skills/<name>/SKILL.md`, or `~/.copilot/skills/<name>/SKILL.md` for a copy delivery | `.agents/skills/<name>/SKILL.md`, or `.github/skills/<name>/SKILL.md` for a copy delivery | managed, both |
| hook | `~/.copilot/hooks/*.json`, each file a document, plus `~/.copilot/settings.json` → `hooks` | `.github/hooks/*.json`, plus `.github/copilot/settings.json` and `settings.local.json` → `hooks` | managed, both, enforced; an empty or absent matcher is written without the `matcher` key, which Copilot reads as every tool |
| mcp-server | `~/.copilot/mcp-config.json` | `.github/mcp.json` | managed, both |
| built-in mcp-server | `~/.copilot/settings.json` → `disabledMcpServers` | `.github/copilot/settings.json` → `disabledMcpServers` | list and toggle, both |
| plugin | `~/.copilot/settings.json` → `enabledPlugins` | `.github/copilot/settings.json` and `settings.local.json` → `enabledPlugins` | observe and toggle, both |
| command | — | — | unsupported |
| pi-extension | — | — | unsupported |

Commands are unsupported because Copilot CLI reads no command surface of its own: prompt files (`.github/prompts/*.prompt.md`) are IDE-only, read by neither the CLI nor github.com, and the one command directory the CLI does read, top-level `.claude/commands/*.md` as "commands (alternative skill format)", is Claude Code's, which the Claude adapter owns. Hooks are read from two places and written to one: every `*.json` under the hooks directory is a whole `{version, hooks}` document, the settings file carries a `hooks` key of the same entries, and only the files are written. Only the plugin `enabledPlugins` flip and built-in MCP `disabledMcpServers` membership are written into settings.

## Format

- Name rule `LowerKebab` with no documented length; namespace separator `-`.
- MCP transports: stdio, streamable HTTP, SSE. A command server is typed `local`; a url server keeps the transport it declares, named by `type` (`server`, `crates/core/src/engine/copilot.rs`).
- Agent file: `<name>.agent.md`, the double extension required, YAML frontmatter and a markdown body. Fields written: `name`, `description`, `include-custom-instructions: true`, `model`, `tools`; skills and hooks are not frontmatter fields and travel as prose (`crates/core/src/render/agent/copilot.rs`). A custom agent Copilot starts as a subagent reads no AGENTS.md or CLAUDE.md unless `include-custom-instructions` is true, so every agent carries it ([CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference), which also lists `reasoningEffort`).
- Agent reload: Copilot CLI reads agent files once, when a session starts, and the task tool's agent list stays fixed for that session. The CLI has no command that reloads agents; `/skills reload` covers skills only. A session started before kendex adds or renames an agent must restart the CLI to see it ([Creating custom agents for Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-custom-agents-for-cli): "Restart the CLI to load your new custom agent"; [github/copilot-cli#3106](https://github.com/github/copilot-cli/issues/3106) is the open request). `/restart` restarts the CLI and keeps the session ([changelog](https://github.com/github/copilot-cli/blob/main/changelog.md) 1.0.3); not measured here.
- Model dialect: classes and `inherit` omit the model field under [D008](../decisions/D008-copilot-agent-model.md) and [D021](../decisions/D021-runtime-model-classes.md). Exact ids remain free text with one compatibility warning (`crates/core/src/harness/models.rs`). The agent file's model outranks the `--model` a launch passes ([CLI programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference); not measured here), so a class file cannot independently select a child class. No `reasoningEffort` is written, so no agent names an effort of its own; whether a subagent with none runs at the session's effort or at Copilot's default is not measured, and the `agent:effort` row of `tools/harness-smoke --only copilot` reads skipped for that reason.
- Tool vocabulary: `read`, `grep`, `glob`, `bash`, `edit`, `multiedit`, `write`, `webfetch`, `websearch`, `todowrite`, `agent`, `notebookread`, `notebookedit`; a name Copilot does not document is left alone (`copilot_tool_name`, `crates/core/src/render/vocab/mod.rs`).
- Permissions: `tools:` is a real allowlist, so an `AllowOnly` intent renders natively; a `DenyExtra` intent cannot be expressed, so the rendering warns, names the tools the agent keeps, and installs.

## Built-in MCP servers

| Native name | Default | Source |
|---|---|---|
| `github-mcp-server` | on | Copilot CLI `--help`, `--disable-builtin-mcps` |
| `githubiq` | on | Copilot CLI `--help`, `--disable-builtin-mcps` |

An ordinary `[mcp-servers.<name>]` declaration with `source = "builtin"` and `harnesses = ["copilot"]` controls the native switch. Disable adds the name to this scope's `disabledMcpServers`; enable or removal takes it out. Without a declaration, apply writes no native switch. The CLI and app create a declaration for disable, or for an enable of a built-in already off in native settings. Native MCP reads, edits and removal use the app's configured Copilot root, or the environment-derived root when no override is set. Project edits stay in the shared repository settings. Reads accept comments and trailing commas; edits refuse them and preserve the original file. Lock and verify use the ordinary MCP registration paths. An app toggle on a built-in refuses a name already declared from another source, instead of changing that package. `crates/core/tests/copilot_builtin.rs` checks the native switch, hand-edit detection, settings preservation and removal.

## Hooks

Enforced: Copilot runs the command and honours the exit code. Copilot hands the model only `hook exited with code 2` for a preToolUse denial and never the hook's stderr, so the command kendex registers for a hook with a script, every catalog hook, captures the script's output. A run that exits 2 with stderr and nothing but whitespace on stdout gets that stderr written back as `{"permissionDecision":"deny","permissionDecisionReason":…}`, which Copilot shows the model as `Denied by preToolUse hook: <reason>`. Any other run's stdout passes unchanged where it holds a non-space character, a hook's own answer included, and is dropped where it is only whitespace; the exit status is always the script's (`copilot_answer`, `crates/core/src/engine/targets.rs`; [D011](../decisions/D011-copilot-refusal-answer.md)). The reason reaches the model for a preToolUse refusal only. A `[[custom-hooks]]` command is registered as written, unwrapped, so its refusal still reads `hook exited with code 2`, and at `permissionRequest` Copilot takes the model-visible denial from `behavior` and `message`, never `permissionDecisionReason`. Events map to Copilot's camelCase names (`event`, `crates/core/src/harness/copilot/mod.rs`):

| Fleet event | Copilot event |
|---|---|
| `PreToolUse` | `preToolUse` |
| `PostToolUse` | `postToolUse` |
| `PermissionRequest` | `permissionRequest` |
| `UserPromptSubmit` | `userPromptSubmitted` |
| `SessionStart`, `SessionEnd` | `sessionStart`, `sessionEnd` |
| `PreCompact` | `preCompact` |
| `Notification` | `notification` |
| `Stop` | `agentStop` |
| `SubagentStop` | `subagentStop` |

One mapping fires wider than its fleet event: `agentStop` also fires at a custom subagent's end (Copilot CLI 1.0.91), and a turn-end hook tells the two stops apart with `lane-mail-check.sh caller`, as `hooks/AGENTS.md` states. Copilot has no turn-failure event, so `StopFailure` stays unmapped: `errorOccurred` fires once per recoverable model-call retry, six times for one failed turn on Copilot CLI 1.0.91, where Claude Code fires StopFailure once (`tools/harness-smoke`'s `event:errorOccurred` row). Copilot's other events (`postToolUseFailure`, `userPromptTransformed`, `subagentStart`, `errorOccurred`) have no fleet counterpart and stay unmapped, with a note. Each hook gets a file of its own, `<name>.json` beside `<name>.sh`, in the shape `{"version": 1, "hooks": {"<event>": [{"type": "command", "bash": …, "matcher": …, "timeoutSec": …}]}}`; timeouts are seconds under `timeoutSec`, an empty or absent matcher is written without the `matcher` key because Copilot skips an entry whose matcher is the empty string and reads the absent key as every tool, and a file left holding no hooks goes to the trash at project scope and keeps its version line at global scope (`crates/core/src/configedit/copilot.rs`). At project scope the command finds the project root when it runs ([Hook commands](README.md#hook-commands)). Disabling renames the script to `.disabled` and reverses the entry in the document.

A matcher is restated in the runtime tool names Copilot tests it against, which are not the agent allowlist's, one authored name standing for every runtime tool the [hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference)'s Claude tool-name table gives it: `Bash` is `bash` and `powershell`, `Write` is `create`, `Edit` and `MultiEdit` are `edit`, `str_replace_editor` and `apply_patch`, `Read` is `view`, `Grep` is `grep` and `rg`, `Glob` is `glob`, `Agent` is `task`, `WebFetch` is `web_fetch`, `WebSearch` is `web_search`, `AskUserQuestion` is `ask_user`, `TodoWrite` is `update_todo` and `Skill` is `skill`, each runtime tool said once; a name with no runtime tool is left as authored (`copilot_hook_tools` and `hook_matcher`, `crates/core/src/render/vocab/mod.rs`). The reference lists every name but `skill`, which is the `toolName` Copilot CLI 1.0.88 sent for a skill load. A hook matching a widened name reads each tool's own `toolArgs`: `skill-load-check`'s Copilot route reads `apply_patch`'s target files off its patch.

On Copilot, `skill-load-check` judges an agent's calls against the skill loads the `skill-load-record` hook writes down under the payload's `sessionId`; `hooks/tests/skill-load-check-copilot.test.sh` tests that route, and the two skill-load rows of `tools/harness-smoke --only copilot` check it live on a host where Copilot is logged in. `skill-load-record` requires `skill-load-check`, and the `workflow` bundle lists both. A Copilot call that reaches the Claude Code copy through `.claude/settings.json` passes there under `skill-load-check: harness=copilot`.

Agent scoping: none; only `agents = "all"` custom hooks are enforced.

`tools/harness-smoke --only copilot --copilot-interactive` measures hook answers through the CLI's exported transcript and recorded hook payloads. On Copilot CLI 1.0.91, `additionalContext` reaches the model at `sessionStart` and `userPromptSubmitted`, including an interactive prompt, while silent-hook controls carry no token. The prompt result differs from the hooks reference's statement that config-file output is dropped. An exit-0 `decision: block` at `agentStop` or `subagentStop` continues the session and carries its reason to the model. Manual `/compact` fires `preCompact` with `trigger: manual`. `session-drift-check` packages its complete notice as one `additionalContext` object on Copilot and keeps plain text on other harnesses; `hooks/tests/session-drift-check.test.sh` checks this format.

## Effective state

Three reads decide whether an install is live, each a read of a file on disk that says how things are configured and never what a run will do (`crates/core/src/engine/copilot.rs`, `crates/core/src/harness/copilot/settings.rs`):

- `disableAllHooks` switches off every Copilot hook. kendex reads the whole layer stack, lowest first, and names the file that threw the switch: legacy `~/.copilot/config.json`, `~/.copilot/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, `.github/copilot/settings.json`, `.github/copilot/settings.local.json`; later wins.
- `disabledSkills` and `disabledMcpServers` merge as a union: a repository may add a name to a disabled list and never take one off. An enable removes this scope's own built-in MCP override, but a user-level or project-local disable still holds it off. kendex reports that hold per item, naming the file and the key. MCP lists come from the legacy and current user files and the shared and local Copilot repository files, not Claude's settings subset.
- `.github/allowed_models.txt` restricts model ids with `*` globs; a `fallback:` line is not a pattern. An agent naming a model outside the list warns; `auto` is exempt.

Legacy `~/.copilot/config.json` is read and never written; a global scope holding it with no `settings.json` refuses settings-backed writes, with that reason.

## Cross-reads

Copilot CLI discovers skills from `.claude/skills` and `.agents/skills`; the second is where kendex installs a project skill for it, so that one is claimed. It also reads top-level `.claude/commands/*.md` as single-file skills, so a command kendex installs for Claude Code at project scope is offered by Copilot too. VS Code discovers agents from `.claude/agents`, and the CLI reads the `.claude/settings*.json` subset listed above. The adapter claims none of those, and a repo-root `.mcp.json` stays off its surface list as Claude Code's file; the reach is a note on the plan for skills and the layer stack above for hooks. The commands kendex registers in `.claude/settings.json` for the hook scripts it installs there exit before their script in a Copilot hook process, so a Copilot session runs only its own copy of those hooks; a custom hook declared as a command is registered as written, and Copilot runs it ([claude.md § Cross-reads](claude.md#cross-reads)).

## Output styles

| Scope | Route | Drift and lock |
|---|---|---|
| Global | Unsupported; reported, no style file or block | No installation row |
| Project | Unsupported; reported, no style file or block | No installation row |

A project declaring Claude Code receives its native style only. kendex writes no style block into repository `AGENTS.md`. Claude Code reads that file itself, so a style block would load the same style twice. The no-block case is in `crates/core/tests/output_styles.rs`.

`.github/copilot-instructions.md` remains the bot-instructions package's file.
