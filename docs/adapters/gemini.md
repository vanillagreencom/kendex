# Gemini CLI

Both scopes hold the same layout under their own root. Two complications: a system settings layer that outranks project scope, and one machine-wide file recording whether each MCP server is on. Owner: `crates/core/src/harness/gemini/mod.rs`. Facts are checked against Gemini CLI's own docs; the record is [gemini-copilot-matrix.md](gemini-copilot-matrix.md).

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.gemini` | nothing |
| Project | `<project>/.gemini` | nothing |

Project markers: a `.gemini/` directory, or a `GEMINI.md` file at the repo root. `gemini-extension.json` is not a marker.

Global detection: `~/.gemini/settings.json`, the file the CLI writes on its first run. The directory alone is not the marker, because Antigravity keeps its own root under it and both tools write the shared Google auth files there (`detect` in `crates/core/src/harness/gemini/mod.rs`). A Gemini CLI that has never written its settings file is listed in `[install] harnesses` by hand.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.gemini/agents/*.md` | `.gemini/agents/*.md` | managed, both |
| skill | `~/.gemini/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md`, or `.gemini/skills/<name>/SKILL.md` for a copy delivery | managed, both |
| command | `~/.gemini/commands/**/*.toml` | `.gemini/commands/**/*.toml` | managed, both |
| hook | `~/.gemini/settings.json` → `hooks` | `.gemini/settings.json` → `hooks` | managed, both, enforced |
| mcp-server | `~/.gemini/settings.json` → `mcpServers` | `.gemini/settings.json` → `mcpServers` | install, remove, refresh both; toggle global only |
| plugin (extension) | `~/.gemini/extensions/<name>/gemini-extension.json` | — | observe only, global |
| pi-extension | — | — | unsupported |

An MCP server is declared per scope but its on/off state lives in one global file, so the toggle exists at global scope only; a project-scope disable is declined with a note saying to remove the declaration instead. Extension enablement lives in `extension-enablement.json` and is never written.

## Format

- Name rule `Any`; namespace separator `__`.
- MCP transports: stdio, streamable HTTP, SSE. A command server keeps `command`, a streamable-HTTP endpoint is `httpUrl`, an SSE one is plain `url`, and no `type` sits beside either; one the source wrote is stripped (`server`, `crates/core/src/engine/gemini.rs`).
- Agent file: YAML frontmatter and a markdown body holding the system prompt. Fields written: `name`, `description`, `kind: local`, `model`, `tools`; skills and per-agent hooks travel as prose inside the prompt (`crates/core/src/render/agent/gemini.rs`). A `kind: remote` agent is observed like any other file and never written.
- Model dialect: `fable` and `opus` resolve to `gemini-3-pro-preview`, `sonnet` and `haiku` to `gemini-3-flash-preview`; `inherit` is spelled literally and only on an explicit request; a model that is neither `gemini-*` nor `inherit` is an advisory finding (`crates/core/src/harness/models.rs`).
- Command file: a TOML table with `description` and `prompt`, the generated-file banner outside the prompt as a `#` comment. Only `.toml` loads from the commands directory, so the `.disabled` rename toggle is safe there (`crates/core/src/render/command.rs`).
- Tool vocabulary: `read_file`, `grep_search`, `glob`, `list_directory`, `run_shell_command`, `replace`, `write_file`, `web_fetch`, `google_web_search`, `write_todos`, `ask_user`; an unmapped name passes through (`gemini_tool_name`, `crates/core/src/render/vocab/mod.rs`).
- Permissions: `tools:` is a real allowlist, so an `AllowOnly` intent renders natively; a `DenyExtra` intent cannot be expressed, so the rendering warns, names the tools the agent keeps, and installs.

## Hooks

Enforced: regex matchers over tool names, exit codes honoured. Events map to Gemini's names (`event`, `crates/core/src/harness/gemini/mod.rs`):

| Fleet event | Gemini event |
|---|---|
| `PreToolUse`, `BeforeTool` | `BeforeTool` |
| `PostToolUse`, `AfterTool` | `AfterTool` |
| `PreCompact`, `PreCompress` | `PreCompress` |
| `SessionStart`, `SessionEnd`, `Notification` | same |
| `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `BeforeAgent`, `AfterAgent` | same |

An event with no counterpart registers nothing, with a note. Timeouts are milliseconds: the source declares seconds and the registration multiplies by 1000. The script lands at `<root>/hooks/<name>.sh`, and at project scope the command finds the project root when it runs ([Hook commands](README.md#hook-commands)). A matcher carrying regex syntax around a tool name is registered as authored and reported.

Agent scoping: none; only `agents = "all"` custom hooks are enforced, and scoped ones render as advisory prose in the agent files.

## Effective state

Four reads decide whether an install is live, each a read of a file on disk that says how things are configured and never what a run will do (`crates/core/src/engine/gemini.rs`, `crates/core/src/harness/gemini/settings.rs`):

- `experimental.enableAgents: false` leaves agents installed and inert; absent means on.
- The system settings layer outranks project scope. Precedence, later wins: defaults, system defaults, `~/.gemini/settings.json`, `<project>/.gemini/settings.json`, system settings, environment, flags. The system file is `/etc/gemini-cli/settings.json`, `/Library/Application Support/GeminiCli/settings.json` on macOS or `C:\ProgramData\gemini-cli\settings.json` on Windows, relocated by `GEMINI_CLI_SYSTEM_SETTINGS_PATH` (and that variable alone). When it defines a key kendex is about to write (`agents`, `hooks`, `mcpServers`), the plan warns that the write can be overridden.
- `mcp-server-enablement.json` is one global file whatever scope declared the server; a server switched off there is declared for the project and inert.
- `mcp.excluded` and `mcp.allowed`: a server named in `excluded`, or absent from a non-empty `allowed`, is kept out of what Gemini loads; this scope's settings and the user's are both asked.

A `settings.json` holding none of the 25 known top-level categories is the legacy flat schema, and every settings-backed write is refused with a reason naming the flat keys; an absent, empty or unparseable file counts as current, and the structured-edit path reports a parse failure against its own path.

## Cross-reads

Gemini reads `.agents/skills`, so at project scope that shared tree is where its skills go and the adapter claims it, alongside `.gemini/skills` for what is already there and for a copy delivery. A skill installed for another tool is already visible through the same tree; the reach is a note (`cross_read_note`, `crates/core/src/engine/desired_skill.rs`), never a second installation.

## Instruction shim

Gemini loads whichever files `context.fileName` names, so kendex names `AGENTS.md` there in the project's `.gemini/settings.json` beside Gemini's own default (`crates/core/src/engine/instruction_shims.rs`).
