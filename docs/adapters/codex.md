# Codex

TOML agents, a 1024-character bound on a skill's description, and no command
directory: a command installs as a skill and the lock records what was written.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.codex` | `CODEX_HOME` |
| Project | `<project>/.codex`, plus the shared `<project>/.agents` | — |

Project markers: a `.codex/` or `.agents/` directory. Owner:
`crates/core/src/harness/codex.rs`.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.codex/agents/*.toml` | `.codex/agents/*.toml` | managed, both |
| skill | `~/.codex/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md` — **shared with Pi** | managed, both |
| command | `~/.codex/prompts/*.md` — deprecated, observed, never written | — | observe global; install/toggle/remove/refresh both, `installs_as: skill` |
| hook | `~/.codex/hooks.json` | `.codex/hooks.json` | managed, both, **enforced** |
| mcp-server | `~/.codex/config.toml` `[mcp_servers.<name>]` | `.codex/config.toml` | observe only, both |
| plugin | `~/.codex/plugins/` cache tree with `.codex-plugin/plugin.json`, toggles in `config.toml` `[plugins]` | — | observe only, global |
| pi-extension | — | — | unsupported |

Adopt stays off for commands: the prompts directory is scanned, never written.

## Format facts

- **Body cap:** none. Codex loads the whole SKILL.md; its documented limit
  is the frontmatter `description`, at most 1024 characters. A longer one is
  refused for this harness (`render/validate/skill.rs`), naming the skill.
- **Name rule:** `Any`. Namespace separator `__`.
- **MCP transports:** stdio and streamable HTTP. Codex never speaks SSE.
- **Agent file:** TOML, `<name>.toml`. kendex writes `name`,
  `nickname_candidates`, `description`, `model?`, `model_reasoning_effort?`,
  `sandbox_mode`, and `developer_instructions` as a triple-quoted string
  carrying the whole prompt (`crates/core/src/render/agent/codex.rs`).
- **Model dialect:** every tier resolves to `gpt-5.6-sol`; omitting the key
  is Codex's dialect for inherit.
- **Permissions:** Codex has no tool allowlist. A read-only allowlist caps
  `sandbox_mode` at `read-only`, any other allowlist at `workspace-write`,
  and only an explicit Engineer role with no allowlist earns
  `danger-full-access`. An allowlist always warns that the list itself is
  not enforced.
- **Tool vocabulary:** prose is rewritten to phrases — `Read` becomes "open
  the file", `Bash` becomes "run a shell command"
  (`crates/core/src/render/vocab/mod.rs`).
- **Agent scoping:** none — only `agents = "all"` custom hooks are enforced;
  scoped ones render as advisory prose in the agent files.

## Hooks

Enforced for the events Codex understands: `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`,
`PermissionRequest`, `Stop` — mapped by identity. Anything outside that map
renders as advisory prose inside the agent files instead
(`codex_event`, `crates/core/src/hook.rs`).

The script lands at `<root>/hooks/<name>.sh`; the registration goes into
`hooks.json` in the nested matcher-plus-handlers shape, with the timeout in
seconds as authored. At project scope the command resolves through
`$(git rev-parse --show-toplevel)`. Installing a hook also merges
`[features] hooks = true` into `config.toml` as a text-level edit that
preserves comments and ordering.

## Commands stored as skills

A declared command becomes a one-file skill tree: a generated `SKILL.md` carrying the command's prose,
the loader frontmatter and the generated-file banner, written into the skill
directory and recorded in the lock as an emitted skill artifact
(`crates/core/src/engine/desired_command.rs`,
`crates/core/src/render/command.rs`).

Names are resolved in one pass over every declared command, in name order.
A real skill always keeps its name;
a command that clashes takes `<name>__command`, then `<name>__cmd`, each with
a warning naming what to type. When all three are taken, nothing is written.

At project scope this tree lands in `.agents/skills`, which Pi also reads;
the command appears in Pi's skill list too — emitted as a warning.

## Migration and old-shape tolerance

`~/.codex/prompts` is scanned; it is never written and never adopted.
