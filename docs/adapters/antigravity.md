# Antigravity

Google's Antigravity CLI (`agy`). One customization layout under a root per scope, an agent file with the loader's own two tiers, and one hook registry per scope keyed by hook name. Owner: `crates/core/src/harness/antigravity.rs`.

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
| hook | `~/.gemini/config/hooks.json`, scripts under `~/.gemini/config/hooks/` | `.agents/hooks.json`, scripts under `.agents/hooks/` | managed, both, enforced |
| mcp-server | `~/.gemini/config/mcp_config.json` | `.agents/mcp_config.json` | managed, both |
| plugin | `~/.gemini/config/plugins/<name>/plugin.json` | `.agents/plugins/<name>/plugin.json` | observe only, both |
| pi-extension | — | — | unsupported |

## Format

- Name rule `Any`; namespace separator `__`.
- MCP transports: stdio (`command`, `args`, `env`) and, under one `serverUrl` key, SSE and streamable HTTP; the docs refuse `url` and `httpUrl`, so a url server is rewritten to `serverUrl` with no `type` beside it (`server`, `crates/core/src/engine/antigravity.rs`). Switching a server off writes `disabled: true` on the entry and switching it on takes the key away, so the declaration stays until removal, and the scan reads that key back as the switch; other entries stay. A file the strict JSON edit cannot parse, comments, trailing commas or a byte-order mark the loader itself tolerates, is not edited, the registration reports the conflict instead. Antigravity documents no substitution for an `env` value, so a server declaring one is refused for this harness with the reason. The `agy mcp` subcommands write only the user-level file.
- Agent file: YAML frontmatter and a markdown body, `<name>.md`. Fields written: `name`, `description`, `model` (only when a tier was asked for), `subagent: true`, `tools` (allowlist) (`crates/core/src/render/agent/antigravity.rs`). Skills travel as prose: the frontmatter's `skills:` list names paths under the customization root, and kendex does not yet write it. An agent may also be a directory, `agents/<name>/agent.md`; kendex writes the file form and reads the directory form as the item `<name>/agent`.
- Model dialect: `inherit` omits the key; `fable` and `opus` are `pro`, `sonnet` and `haiku` are `flash`; any other value is refused at render, since the loader reads no ids (`crates/core/src/harness/models.rs`, `crates/core/src/render/validate/agent.rs`). The file has no effort key, so an effort setting renders nothing; the session's `--effort` (`low`, `medium`, `high`) and the model's own `-high`/`-medium`/`-low` id suffix decide reasoning.
- Permissions: an allowlist renders as `tools:` in Antigravity's own names; a name it has no word for is left out with a warning, since its documentation says an unknown name in the list can hang the subagent; a deny list cannot be expressed and warns.
- Tool vocabulary: Antigravity's own names, the lowercased step types (`view_file`, `grep_search`, `run_command`, `replace_file_content`, `write_to_file`, `find_by_name`, `list_dir`, `read_url_content`, `search_web`, `invoke_subagent`, `ask_question`); prose and hook matchers are restated in them (`crates/core/src/render/vocab/mod.rs`).

## Hooks

Antigravity runs `hooks.json` from the customization root at either scope, one named hook per top-level key: `{"<name>": {"enabled": true, "PreToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "...", "timeout": 30}]}], "Stop": [{"command": "..."}]}}` (the CLI's embedded hooks guide, <https://antigravity.google/docs/hooks>). `PreToolUse` and `PostToolUse` group handlers under a matcher regex over its tool names; `PreInvocation`, `PostInvocation` and `Stop` hold handlers directly. `timeout` is seconds. A command runs through `sh -c` with the registry's directory as its working directory and JSON on stdin; a `PreToolUse` command answers with `{"decision": "allow" | "deny" | "ask" | "force_ask"}` on stdout, a `Stop` command with `{"decision": "continue"}` to keep the loop running, the rest with `{}`. An exit of 2 with the reason on stderr is honoured as a denial too (probed on 1.1.27). What differs is the payload: the command arrives as `toolCall.args.CommandLine`, not `tool_input.command`, so a hook written for the other tools reads no command here. A catalog or custom hook therefore reaches Antigravity only by naming `antigravity` in its `harnesses` line (`HarnessId::hooks_by_name_only`, `HookSpec::applies_to`); an unnamed hook installs nothing on Antigravity and the plan says so in a note.

Event map (`crates/core/src/harness/antigravity.rs`): `PreToolUse`, `PostToolUse` and `Stop` by name; `PreInvocation` and `PostInvocation` have no fleet counterpart and stay unmapped, with a note. Each hook registers under its own name, `<name>.<event>`, with the script at `hooks/<name>.sh` beside the registry; at project scope the command resolves through `$(git rev-parse --show-toplevel)`. Disabling renames the script to `.disabled` and takes the entry out; the last entry out takes the name with it (`crates/core/src/configedit/antigravity.rs`). The scan reads a name's `enabled: false` as every handler under it off.

Agent scoping: none; only `agents = "all"` custom hooks are enforced.

## Not supported

Commands (a skill is the slash command; workflows under `.agents/workflows/` still run but retire on 2026-11-01), Pi extensions, writing plugins, and the `skills:` frontmatter list.
