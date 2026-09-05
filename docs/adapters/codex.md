# Codex

TOML agents, a 1024-character bound on a skill's description, and no command directory: a command installs as a skill and the lock records what was written. Owner: `crates/core/src/harness/codex.rs`.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.codex` | `CODEX_HOME` |
| Project | `<project>/.codex`, plus the shared `<project>/.agents` | nothing |

Project markers: a `.codex/` or `.agents/` directory.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.codex/agents/*.toml` | `.codex/agents/*.toml` | managed, both |
| skill | `~/.codex/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md`, shared with Pi | managed, both |
| command | `~/.codex/prompts/*.md`, observed and never written | — | observe global; install, toggle, remove, refresh both; `installs_as: skill` |
| hook | `~/.codex/hooks.json` | `.codex/hooks.json` | managed, both, enforced |
| mcp-server | `~/.codex/config.toml` `[mcp_servers.<name>]` | `.codex/config.toml` | observe only, both |
| plugin | `~/.codex/plugins/` cache tree with `.codex-plugin/plugin.json`, toggles in `config.toml` `[plugins]` | — | observe only, global |
| pi-extension | — | — | unsupported |

The prompts directory is scanned because Codex still loads it, and never written or adopted.

## Format

- Skill description at most 1024 characters; a longer one is refused for this harness alone, naming the skill (`crates/core/src/render/validate/skill.rs`). No body cap.
- Name rule `Any`; namespace separator `__`.
- MCP transports: stdio and streamable HTTP, never SSE.
- Agent file: TOML, `<name>.toml`. Fields written: `name`, `nickname_candidates`, `description`, `model`, `model_reasoning_effort`, `sandbox_mode`, and `developer_instructions` as a triple-quoted string carrying the whole prompt (`crates/core/src/render/agent/codex.rs`).
- Model dialect: every tier resolves to `gpt-6-astra`; an omitted key is Codex's spelling of inherit (`crates/core/src/harness/models.rs`). `model_reasoning_effort` is written as given (`minimal`, `low`, `medium`, `high`, `xhigh`); an absent key takes the model's own default.
- Permissions: Codex has no tool allowlist. A read-only allowlist caps `sandbox_mode` at `read-only`, any other allowlist at `workspace-write`, and only an explicit Engineer role with no allowlist earns `danger-full-access`; an allowlist always warns that the list itself is not enforced.
- Tool vocabulary: prose is rewritten to phrases, `Read` to "open the file", `Bash` to "run a shell command" (`crates/core/src/render/vocab/mod.rs`).

## Hooks

Enforced for the events Codex understands, mapped by identity: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `PermissionRequest`, `Stop` (`codex_event`, `crates/core/src/hook.rs`). Any other event renders as advisory prose inside the agent files.

The script lands at `<root>/hooks/<name>.sh`; the registration goes into `hooks.json` in the nested matcher-plus-handlers shape, timeout in seconds as authored, the command resolved through `$(git rev-parse --show-toplevel)` at project scope. Installing a hook also merges `[features] hooks = true` into `config.toml` as a text-level edit that keeps comments and ordering.

Agent scoping: none. Only `agents = "all"` custom hooks are enforced; scoped ones render as advisory prose in the agent files.

## Commands stored as skills

A declared command becomes a one-file skill tree: a generated `SKILL.md` carrying the command's prose, the loader frontmatter and the generated-file banner, recorded in the lock as an emitted skill artifact (`crates/core/src/engine/desired_command.rs`, `crates/core/src/render/command.rs`). Names resolve in one pass over every declared command in name order: a real skill keeps its name, a clashing command takes `<name>__command`, then `<name>__cmd`, each with a warning naming what to type, and when all three are taken nothing is written. At project scope the tree lands in `.agents/skills`, which Pi reads too; that the command appears in Pi's skill list is emitted as a warning.
