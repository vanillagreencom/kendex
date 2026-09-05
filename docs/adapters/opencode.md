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
| command | `<base>/commands/*.md`, plus the legacy singular `<base>/command/*.md` for what is already there | managed, both |
| mcp-server | config `mcp` key, jsonc tolerated on read, per-entry `enabled` | managed, both |
| plugin | `<base>/plugins/*.{js,ts,mjs,cjs}`, plus the config `plugin` array of npm refs | observe only, both |
| pi-extension | — | unsupported |

The hook surface reads only files whose name starts `kendex-hook-` (`HOOK_INSTRUCTION_MARKER`, `crates/core/src/harness/opencode.rs`).

## Format

- Name rule `LowerKebab`, at most 64 characters, for agents and skills; capitals and underscores make one unloadable. Namespace separator `-`.
- MCP transports: stdio and streamable HTTP; servers are `local` (command) or `remote` (url), never SSE, and an SSE declaration is refused for this harness with that reason. A command server is written as `{"type": "local", "command": [command, args…], "environment": env, "enabled": true}` and a url server as `{"type": "remote", "url": url, "enabled": true}` under `mcp.<name>` in the scope's config file, an `env` value's `$NAME` or `${NAME}` reference spelled `{env:NAME}`, the form OpenCode substitutes (`server`, `crates/core/src/engine/opencode.rs`). OpenCode merges its config files field by field, so `enabled` is always written: switching one off writes `enabled: false` and on writes `enabled: true`, and the declaration stays either way. Other keys in the file are untouched, a file kendex creates carries the `$schema` line, and a config holding comments is not edited: the registration reports the conflict instead. Servers are read once at startup.
- Command file: the author's markdown installed byte for byte as `commands/<name>.md`, the filename being the `/name` typed. OpenCode reads `description`, `agent`, `model`, `variant` and `subtask` from the frontmatter and drops any other key, the body is the template, and `$ARGUMENTS`, `$1`, ``!`command` `` and `@file` expand as they do on Claude Code. Only `.md` loads, so the `.disabled` rename toggle is safe. The command loader keys on the filename alone with no case or character rule, so the lower-kebab rule above binds agents and skills and not commands. Commands are read once at startup.
- Agent file: YAML frontmatter and a markdown system prompt. Fields written: `description`, `mode`, `model`, `color` (hex only), `options.reasoningEffort` and its companions, and a `permission:` map of denies (`crates/core/src/render/agent/opencode.rs`). `mode` is `primary`, `subagent` or `all`; kendex writes `subagent` by default and spells a source's `all` as `subagent` too.
- Model dialect: every tier resolves to `openai/gpt-6-astra`; an explicit id must be `provider/model` and a bare id is refused at render, since kendex names no provider on the author's behalf; an omitted key means inherit (`crates/core/src/harness/models.rs`, `crates/core/src/render/validate/agent.rs`).
- Permissions: tools are gated by permission key, every entry translated first (`opencode_permission`, `crates/core/src/render/vocab/mod.rs`); the keys the loader knows are `read`, `edit`, `glob`, `grep`, `bash`, `task`, `skill`, `lsp`, `question`, `webfetch`. An allowlist is expressed by denying everything else over exactly that set, `skill` stays allowed, and an entry that maps to no known permission warns. Subagents always deny `task`, and every agent but a `role: planner` denies `question`.
- Rendered agents are re-read through OpenCode's own rules in plan preview: the frontmatter must parse, `mode` must be one of the three, every permission value must be `allow`, `ask` or `deny`; a model naming no provider is advisory (`crates/core/src/render/validate/agent.rs`).

## Hooks

Advisory: a hook installs as an instruction file stating the constraint plus a reference in the config's `instructions[]` array, and a `PreToolUse` hook matching `Bash` additionally sets `permission.bash = {"*": "ask"}`. The plan preview, the report and the tool's card carry the advisory notice (`advisory_notice`, `crates/core/src/engine/targets.rs`). Disabling renames the instruction file to `.disabled` and removes the config reference. A refresh cuts marker-named rows nothing renders anymore and touches no other row, a person's own file in the instructions directory included (`stale_instruction_rows`, `crates/core/src/engine/stale.rs`).
