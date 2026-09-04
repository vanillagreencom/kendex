# Gemini CLI

Both scopes hold the same layout under their own root. Two complications: a system settings layer that outranks project scope, and one machine-wide file recording whether each MCP server is on.

Facts below are verified against Gemini CLI's own docs on `main`.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.gemini` | nothing |
| Project | `<project>/.gemini` | — |

Project markers: a `.gemini/` directory, or a `GEMINI.md` file at the repo root. `gemini-extension.json` is *not* a marker. Owner: `crates/core/src/harness/gemini/mod.rs`.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.gemini/agents/*.md` | `.gemini/agents/*.md` | managed, both |
| skill | `~/.gemini/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md`, or `.gemini/skills/<name>/SKILL.md` for a copy delivery | managed, both |
| command | `~/.gemini/commands/**/*.toml` | `.gemini/commands/**/*.toml` | managed, both |
| hook | `~/.gemini/settings.json` → `hooks` | `.gemini/settings.json` → `hooks` | managed, both, **enforced** |
| mcp-server | `~/.gemini/settings.json` → `mcpServers` | `.gemini/settings.json` → `mcpServers` | install/remove/refresh both, **toggle global only** |
| plugin (extension) | `~/.gemini/extensions/<name>/gemini-extension.json` | — | observe only, global |
| pi-extension | — | — | unsupported |

Extension enablement lives in `extension-enablement.json` (`!` prefix to disable, trailing `*` to include subdirectories); kendex never writes it.

An MCP server is *declared* per scope but its on/off state is recorded in a single global file. The toggle exists only at global scope; a project-scope disable is declined with a note saying to remove the declaration instead.

## Format facts

- **Name rule:** `Any`. Namespace separator `__`.
- **MCP transports:** stdio, streamable HTTP, SSE. Keys: a command server keeps `command`; a streamable-HTTP endpoint is `httpUrl`; an SSE one is plain `url`; no `type` beside either — kendex strips one if the source wrote it (`server`, `crates/core/src/engine/gemini.rs`).
- **Agent file:** YAML frontmatter + markdown body (the system prompt). kendex writes `name`, `description`, `kind: local`, `model` and `tools`. Skills and per-agent hooks are not frontmatter fields; both travel as prose inside the system prompt (`crates/core/src/render/agent/gemini.rs`).
- **Model dialect:** `fable` and `opus` resolve to `gemini-3-pro-preview`, `sonnet` and `haiku` to `gemini-3-flash-preview`; `inherit` is spelled literally, in agent frontmatter only. A model that is neither `gemini-*` nor `inherit` is an advisory finding.
- **Command file:** a TOML table with `description` and `prompt`, written through the TOML serializer. The generated-file banner sits outside the prompt as a `#` comment. Only `.toml` loads from the commands directory, so the `.disabled` rename toggle is safe there (`crates/core/src/render/command.rs`).
- **Tool vocabulary:** `read_file`, `grep_search`, `glob`, `list_directory`, `run_shell_command`, `replace`, `write_file`, `web_fetch`, `google_web_search`, `write_todos`, `ask_user`. An unmapped name passes through unchanged (`crates/core/src/render/vocab/mod.rs`).
- **Agent scoping:** none — only `agents = "all"` custom hooks are enforced; scoped ones render as advisory prose in the agent files.

## Permissions

`tools:` is a real allowlist: an `AllowOnly` intent renders natively. A `DenyExtra` intent cannot be expressed; the rendering warns, names the tools the agent keeps, and installs.

## Hooks

Enforced: 11 events, regex matchers over tool names, exit codes honored.

| Fleet event | Gemini event |
|---|---|
| `PreToolUse`, `BeforeTool` | `BeforeTool` |
| `PostToolUse`, `AfterTool` | `AfterTool` |
| `PreCompact`, `PreCompress` | `PreCompress` |
| `SessionStart` / `SessionEnd` / `Notification` | same |
| `BeforeModel` / `AfterModel` / `BeforeToolSelection` / `BeforeAgent` / `AfterAgent` | same |

An event with no counterpart is left unmapped and nothing is registered, with a note.

**Timeouts are milliseconds.** The source declares seconds; the registration multiplies by 1000 (Gemini's own default is 60000). The script lands at `<root>/hooks/<name>.sh`. At project scope the command resolves through `$(git rev-parse --show-toplevel)`.

A matcher carrying regex syntax around a tool name is registered exactly as authored and reported.

## Effective state — when an install is inert

- **`experimental.enableAgents: false`** — agents install and stay inert. Absent means on.
- **The system settings layer outranks project scope.** Precedence, later wins: defaults → system defaults → `~/.gemini/settings.json` → `<project>/.gemini/settings.json` → **system settings** → environment → flags. The system file lives at `/etc/gemini-cli/settings.json`, `/Library/Application Support/GeminiCli/settings.json` on macOS, or `C:\ProgramData\gemini-cli\settings.json` on Windows, relocatable by `GEMINI_CLI_SYSTEM_SETTINGS_PATH`. When it defines a key kendex is about to write (`agents`, `hooks`, `mcpServers`), the plan warns that what kendex writes can be overridden.
- **`mcp-server-enablement.json`** — one global file, whatever scope declared the server. A server switched off there is declared for the project and inert; a project cannot turn it back on.
- **`mcp.excluded` / `mcp.allowed`** — a server named in `excluded`, or absent from a non-empty `allowed`, is kept out of the list Gemini loads. Both this scope's settings and the user's are asked.

All four are reads of files on disk; the wording says how things are configured and never claims what a run will do (`crates/core/src/engine/gemini.rs`, `crates/core/src/harness/gemini/settings.rs`).

## Migration and old-shape tolerance

A `settings.json` holding none of the 25 known top-level categories is treated as legacy (flat pre-v0.3.0 schema) and every settings-backed write is refused with a reason naming the flat keys. An absent or empty file counts as current — a write creates it in the current schema. A file that will not parse also reads as current; the structured-edit path reports the parse failure against its own path.

## Cross-reads

Gemini reads `.agents/skills`, so at project scope that shared tree is where its skills are installed — the adapter claims it, alongside `.gemini/skills`, which stays on the surface list so an older install there is still seen and so a copy delivery has a per-tool place to write. A skill installed for another tool is already visible to Gemini through the same tree; the reach is reported as a note (`cross_read_note`, `crates/core/src/engine/desired_skill.rs`), never counted as a second installation.

## Shipped behavior

- Only `GEMINI_CLI_SYSTEM_SETTINGS_PATH` is read; `GEMINI_CLI_SYSTEM_DEFAULTS_PATH` is not.
- Tiers are pinned; `inherit` is written only on an explicit request.
- Gemini's documented subagent frontmatter also accepts `mcpServers`, `temperature`, `max_turns` and `timeout_mins`. kendex writes none of them.
- `kind: remote` subagents are observed like any other file. kendex always writes `kind: local` and never installs a remote one, but the scanner does not filter remote agents out of what it reports.
