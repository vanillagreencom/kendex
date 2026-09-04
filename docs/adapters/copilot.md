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
| skill | `~/.copilot/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md`, or `.github/skills/<name>/SKILL.md` for a copy delivery | managed, both |
| hook | `~/.copilot/hooks/*.json`, each file a document, plus `~/.copilot/settings.json` → `hooks` | `.github/hooks/*.json`, plus `.github/copilot/settings.json` and `settings.local.json` → `hooks` | managed, both, enforced |
| mcp-server | `~/.copilot/mcp-config.json` | `.github/mcp.json` | managed, both |
| plugin | `~/.copilot/settings.json` → `enabledPlugins` | `.github/copilot/settings.json` and `settings.local.json` → `enabledPlugins` | observe and toggle, both |
| command | — | — | unsupported |
| pi-extension | — | — | unsupported |

Commands are unsupported because prompt files (`.github/prompts/*.prompt.md`) are IDE-only, read by neither the CLI nor github.com. Hooks are read from two places and written to one: every `*.json` under the hooks directory is a whole `{version, hooks}` document, the settings file carries a `hooks` key of the same entries, and only the files are written. Only the plugin `enabledPlugins` flip is written.

## Format

- Name rule `LowerKebab` with no documented length; namespace separator `-`.
- MCP transports: stdio, streamable HTTP, SSE. A command server is typed `local`; a url server keeps the transport it declares, named by `type` (`server`, `crates/core/src/engine/copilot.rs`).
- Agent file: `<name>.agent.md`, the double extension required, YAML frontmatter and a markdown body. Fields written: `name`, `description`, `model`, `tools`; skills and hooks are not frontmatter fields and travel as prose (`crates/core/src/render/agent/copilot.rs`).
- Model dialect: every tier resolves to `auto`; `inherit` omits the key; an explicit id passes through as free text (`crates/core/src/harness/models.rs`).
- Tool vocabulary: `read`, `grep`, `glob`, `bash`, `edit`, `multiedit`, `write`, `webfetch`, `websearch`, `todowrite`, `agent`, `notebookread`, `notebookedit`; a name Copilot does not document is left alone (`copilot_tool_name`, `crates/core/src/render/vocab/mod.rs`).
- Permissions: `tools:` is a real allowlist, so an `AllowOnly` intent renders natively; a `DenyExtra` intent cannot be expressed, so the rendering warns, names the tools the agent keeps, and installs.

## Hooks

Enforced: Copilot runs the command and honours the exit code. Events map to Copilot's camelCase names (`event`, `crates/core/src/harness/copilot/mod.rs`):

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

Copilot's other events (`postToolUseFailure`, `userPromptTransformed`, `subagentStart`, `errorOccurred`) have no fleet counterpart and stay unmapped, with a note. Each hook gets a file of its own, `<name>.json` beside `<name>.sh`, in the shape `{"version": 1, "hooks": {"<event>": [{"type": "command", "bash": …, "matcher": …, "timeoutSec": …}]}}`; timeouts are seconds under `timeoutSec`, and a file left holding no hooks keeps its version line (`crates/core/src/configedit/copilot.rs`). At project scope the command resolves through `$(git rev-parse --show-toplevel)`. Disabling renames the script to `.disabled` and reverses the entry in the document.

Agent scoping: none; only `agents = "all"` custom hooks are enforced.

## Effective state

Three reads decide whether an install is live, each a read of a file on disk that says how things are configured and never what a run will do (`crates/core/src/engine/copilot.rs`, `crates/core/src/harness/copilot/settings.rs`):

- `disableAllHooks` switches off every Copilot hook. kendex reads the whole layer stack, lowest first, and names the file that threw the switch: legacy `~/.copilot/config.json`, `~/.copilot/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, `.github/copilot/settings.json`, `.github/copilot/settings.local.json`; later wins.
- `disabledSkills` and `disabledMcpServers` merge as a union: a repository may add a name to a disabled list and never take one off. kendex never writes a project-scope enable over a user-scope disable; it reports the hold per item, naming the file and the key.
- `.github/allowed_models.txt` restricts model ids with `*` globs; a `fallback:` line is not a pattern. An agent naming a model outside the list warns; `auto` is exempt.

Legacy `~/.copilot/config.json` is read and never written; a global scope holding it with no `settings.json` refuses settings-backed writes, with that reason.

## Cross-reads

Copilot CLI discovers skills from `.claude/skills` and `.agents/skills`; the second is where kendex installs a project skill for it, so that one is claimed. VS Code discovers agents from `.claude/agents`, and the CLI reads the `.claude/settings*.json` subset listed above. The adapter claims none of those, and a repo-root `.mcp.json` stays off its surface list as Claude Code's file; the reach is a note on the plan for skills and the layer stack above for hooks.
