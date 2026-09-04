# OpenCode

Lower-kebab names its loader will not coerce, tools gated by permission key rather than tool name, and no native hook surface, so a hook here is advisory prose. Owner: `crates/core/src/harness/opencode.rs`.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.config/opencode` | `OPENCODE_CONFIG` (the file; its parent becomes the root), else `OPENCODE_CONFIG_DIR` |
| Project | `<project>/.opencode`, with the config file at the repo root | nothing |

The config file for a scope is `opencode.jsonc` when it exists, else `opencode.json`; at project scope `opencode.json` wins unless only the `.jsonc` variant exists. Project markers: `.opencode/`, `opencode.json`, `opencode.jsonc`.

## Surfaces

`<base>` is `~/.config/opencode` at global scope and `<project>/.opencode` at project scope; the layout is the same under each.

| Kind | Path | Caps |
|---|---|---|
| agent | `<base>/agents/*.md` | managed, both |
| skill | `.agents/skills/<name>/SKILL.md` in a project; `<base>/skills/<name>/SKILL.md` globally and for a copy delivery | managed, both |
| hook | `<base>/instructions/kendex-hook-<name>.md` | managed, both, advisory |
| command | `<base>/commands/*.md` and the legacy singular `<base>/command/*.md` | observe only, both |
| mcp-server | config `mcp` key, jsonc tolerated, per-entry `enabled` | observe only, both |
| plugin | `<base>/plugins/*.{js,ts,mjs,cjs}`, plus the config `plugin` array of npm refs | observe only, both |
| pi-extension | — | unsupported |

The hook surface reads only files whose name starts `kendex-hook-` (`HOOK_INSTRUCTION_MARKER`, `crates/core/src/harness/opencode.rs`).

## Format

- Name rule `LowerKebab`, at most 64 characters; capitals and underscores make an item unloadable. Namespace separator `-`.
- MCP transports: stdio and streamable HTTP; servers are `local` (command) or `remote` (url), never SSE.
- Agent file: YAML frontmatter and a markdown system prompt. Fields written: `description`, `mode`, `model`, `color` (hex only), `options.reasoningEffort` and its companions, and a `permission:` map of denies (`crates/core/src/render/agent/opencode.rs`). `mode` is `primary`, `subagent` or `all`; kendex writes `subagent` by default and spells a source's `all` as `subagent` too.
- Model dialect: every tier resolves to `openai/gpt-5.6-sol`; a bare vendor id gains the `openai/` prefix because the loader requires `provider/model`; an omitted key means inherit (`crates/core/src/harness/models.rs`).
- Permissions: tools are gated by permission key, every entry translated first (`opencode_permission`, `crates/core/src/render/vocab/mod.rs`); the keys the loader knows are `read`, `edit`, `glob`, `grep`, `bash`, `task`, `skill`, `lsp`, `question`, `webfetch`. An allowlist is expressed by denying everything else over exactly that set, `skill` stays allowed, and an entry that maps to no known permission warns. Subagents always deny `task`, and every agent but a `role: planner` denies `question`.
- Rendered agents are re-read through OpenCode's own rules in plan preview: the frontmatter must parse, `mode` must be one of the three, every permission value must be `allow`, `ask` or `deny`; a model naming no provider is advisory (`crates/core/src/render/validate/agent.rs`).

## Hooks

Advisory: a hook installs as an instruction file stating the constraint plus a reference in the config's `instructions[]` array, and a `PreToolUse` hook matching `Bash` additionally sets `permission.bash = {"*": "ask"}`. The plan preview, the report and the tool's card carry the advisory notice (`advisory_notice`, `crates/core/src/engine/targets.rs`). Disabling renames the instruction file to `.disabled` and removes the config reference. A refresh cuts marker-named rows nothing renders anymore and touches no other row, a person's own file in the instructions directory included (`stale_instruction_rows`, `crates/core/src/engine/stale.rs`).
