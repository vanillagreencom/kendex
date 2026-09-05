# Antigravity

Google's Antigravity CLI (`agy`). One customization layout under a root per scope, an agent file with the loader's own two tiers, and a hook registry kendex does not yet read or write. Owner: `crates/core/src/harness/antigravity.rs`.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.gemini/config` | nothing |
| Project | `<project>/.agents` (the loader also accepts `.agent/`, `_agents/`, `_agent/`; kendex writes `.agents/`) | nothing |

Settings (`settings.json`, `keybindings.json`) sit apart under `~/.gemini/antigravity-cli/`.

Project markers: `.agents/agents/`, `.agents/rules/`, `.agents/hooks.json`, `.agents/mcp_config.json`. A bare `.agents/skills` is the shared tree Codex and Pi read too, so it marks nothing on its own.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.gemini/config/agents/*.md` | `.agents/agents/*.md` | managed, both |
| skill | `~/.gemini/config/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md`, shared with Codex and Pi | managed, both |
| command | — | — | unsupported: a skill is the slash command |
| hook | `~/.gemini/config/hooks.json` | `.agents/hooks.json` | unsupported until kendex reads and writes the registry |
| mcp-server | `~/.gemini/config/mcp_config.json` | `.agents/mcp_config.json` | observe only, both |
| plugin | `~/.gemini/config/plugins/<name>/plugin.json` | `.agents/plugins/<name>/plugin.json` | observe only, both |
| pi-extension | — | — | unsupported |

## Format

- Name rule `Any`; namespace separator `__`.
- MCP transports: stdio (`command`) and SSE (`serverUrl`); the file is read, never written.
- Agent file: YAML frontmatter and a markdown body, `<name>.md`. Fields written: `name`, `description`, `model` (only when a tier was asked for), `subagent: true`, `tools` (allowlist) (`crates/core/src/render/agent/antigravity.rs`). Skills travel as prose: the frontmatter's `skills:` list names paths under the customization root, and kendex does not yet write it. An agent may also be a directory, `agents/<name>/agent.md`; kendex writes the file form and reads the directory form as the item `<name>/agent`.
- Model dialect: `inherit` omits the key; `fable` and `opus` are `pro`, `sonnet` and `haiku` are `flash`; any other value is refused at render, since the loader reads no ids (`crates/core/src/harness/models.rs`, `crates/core/src/render/validate/agent.rs`). The file has no effort key, so an effort setting renders nothing; the session's `--effort` (`low`, `medium`, `high`) and the model's own `-high`/`-medium`/`-low` id suffix decide reasoning.
- Permissions: an allowlist renders as `tools:` in Antigravity's own names; a name it has no word for is left out with a warning, since its documentation says an unknown name in the list can hang the subagent; a deny list cannot be expressed and warns.
- Tool vocabulary: Antigravity's own names, the lowercased step types (`view_file`, `grep_search`, `run_command`, `replace_file_content`, `write_to_file`, `find_by_name`, `list_dir`, `read_url_content`, `search_web`, `invoke_subagent`, `ask_question`); prose is restated in them (`crates/core/src/render/vocab/mod.rs`).

## Hooks

Antigravity fires `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation` and `Stop` from `hooks.json`, a map of hook names to event lists in the matcher-plus-handlers shape, with JSON on stdin and a `decision` on stdout (<https://antigravity.google/docs/hooks>). kendex does not yet read or write that registry, so the capability table says hooks are unsupported here. Reading and writing it natively is the open follow-up; `PreToolUse`, `PostToolUse` and `Stop` map to the fleet events by name.

## Not supported

Commands (a skill is the slash command), hooks, Pi extensions, writing MCP servers or plugins, and the `skills:` frontmatter list.
