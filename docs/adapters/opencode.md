# OpenCode

Lower-kebab names its loader will not coerce, tools gated by permission key
rather than tool name, and no native hook surface — a hook here is advisory
prose.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.config/opencode` | `OPENCODE_CONFIG` (the file — its parent becomes the root), else `OPENCODE_CONFIG_DIR` |
| Project | `<project>/.opencode`, with the config file at the repo root | — |

The one config file for a scope is `opencode.jsonc` when it exists, else
`opencode.json`; at project scope `opencode.json` wins unless it is absent and
the `.jsonc` variant exists. Detection accepts either the directory or the
config file. Project markers: `.opencode/`, `opencode.json`, `opencode.jsonc`.
Owner: `crates/core/src/harness/opencode.rs`.

## Surfaces

`<base>` is `~/.config/opencode` at global scope and `<project>/.opencode` at
project scope; the layout is identical under each. Skills are the exception:
opencode's own search covers `.agents/skills` too, so a project skill is
installed to the shared tree and `<base>/skills` stays on the surface list
for what is already there and for a copy delivery.

| Kind | Path | Caps |
|---|---|---|
| agent | `<base>/agents/*.md` | managed, both |
| skill | `.agents/skills/<name>/SKILL.md` in a project (`<base>/skills/<name>/SKILL.md` globally, and for a copy delivery) | managed, both |
| hook | `<base>/instructions/kendex-hook-<name>.md` | managed, both, **advisory** |
| command | `<base>/commands/*.md` and `<base>/command/*.md` (legacy singular) | observe only, both |
| mcp-server | config `mcp` key — jsonc tolerated, per-entry `enabled` | observe only, both |
| plugin | `<base>/plugins/*.{js,ts,mjs,cjs}`, plus the config `plugin` array of npm refs | observe only, both |
| pi-extension | — | unsupported |

The hook surface is restricted by filename prefix: only files starting
`kendex-hook-` are read.

## Format facts

- **Name rule:** `LowerKebab { max_len: 64 }` — capitals and underscores
  make the item unloadable. Namespace separator `-`, not `__`.
- **MCP transports:** stdio and streamable HTTP. Its servers are `local`
  (command) or `remote` (url); there is no SSE
  ([opencode.ai/docs/mcp-servers](https://opencode.ai/docs/mcp-servers)).
- **Agent file:** YAML frontmatter + markdown system prompt. kendex writes
  `description`, `mode`, `model?`, `color?` (hex only),
  `options.reasoningEffort` and friends, and a `permission:` map of denies
  (`crates/core/src/render/agent/opencode.rs`).
- **Model dialect:** every tier resolves to `openai/gpt-5.6-sol`. A bare
  vendor id gains the `openai/` prefix (the loader requires
  `provider/model`). Omitting the key means inherit; never write
  `openai/inherit`.
- **Mode:** `primary`, `subagent` or `all`; kendex's default is `subagent`,
  and `all` from a source is spelled `subagent` too.
- **Agent scoping:** not applicable — hooks are advisory here, whoever
  they are scoped to.

## Permissions

Tools are gated by permission key, not tool name; every entry is
translated first (`opencode_permission`,
`crates/core/src/render/vocab/mod.rs`). The ten keys OpenCode's loader knows
are `read`, `edit`, `glob`, `grep`, `bash`, `task`, `skill`, `lsp`,
`question`, `webfetch`.

An allowlist is expressed by denying everything else over exactly that set.
`skill` stays allowed, and an entry that maps to no known permission warns. Subagents always
deny `task`, and everything but a `role: planner` agent denies `question`.

## Hooks

**Advisory.** A hook installs as an instruction file stating the
constraint, plus a reference added to the config's `instructions[]` array.
A `PreToolUse` hook matching `Bash` additionally sets
`permission.bash = {"*": "ask"}`.

The plan preview, the report and the tool's card all carry an advisory
notice (`advisory_notice`, `crates/core/src/engine/targets.rs`). Disabling renames
the instruction file to `.disabled` and removes the config reference. The
rows named with the `kendex-hook-` marker are the current render set, no
more: a refresh cuts marker-named rows that nothing renders anymore, and
never touches any other row — a person's own file in the instructions
directory included (`stale_instruction_rows`,
`crates/core/src/engine/stale.rs`). Rows a pre-rename tool wrote carry
another marker and are removed by hand once.

## Validation

Rendered agents are re-read through OpenCode's own rules inside plan preview:
frontmatter must parse, `mode` must be one of the three it knows, and every
permission value must be `allow`, `ask` or `deny` — each a refusal. A model
that does not name its provider is advisory
(`crates/core/src/render/validate/agent.rs`).
