# GitHub Copilot

Copilot is four products sharing filenames. kendex treats **Copilot CLI plus
repository files** as the harness and ignores the rest. Copilot reads more
configuration than kendex owns.

Facts below are verified against docs.github.com and code.visualstudio.com.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.copilot` | `COPILOT_HOME` (relocates the whole config root) |
| Project | `<project>/.github` | — |

Project markers: `.github/copilot-instructions.md`, or a `.github/agents`,
`.github/skills` or `.github/hooks` directory. `.github/` on its own is not a
marker. Owner:
`crates/core/src/harness/copilot/mod.rs`.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.copilot/agents/*.agent.md` | `.github/agents/*.agent.md` | managed, both |
| skill | `~/.copilot/skills/<name>/SKILL.md` | `.github/skills/<name>/SKILL.md` | managed, both |
| hook | `~/.copilot/hooks/*.json` (each file a document), plus `~/.copilot/settings.json` → `hooks` | `.github/hooks/*.json`, plus `.github/copilot/settings.json` and `settings.local.json` → `hooks` | managed, both, **enforced** |
| mcp-server | `~/.copilot/mcp-config.json` | `.github/mcp.json` | managed, both |
| plugin | `~/.copilot/settings.json` → `enabledPlugins` | `.github/copilot/settings.json` + `settings.local.json` → `enabledPlugins` | observe + toggle, both |
| command | — | — | unsupported |
| pi-extension | — | — | unsupported |

**Commands are unsupported.** Prompt files `.github/prompts/*.prompt.md`
are IDE-only and read by neither the CLI nor github.com.

**Hooks are read from two places and written to one.** Every `*.json` under
the hooks directory is a whole `{version, hooks}` document of its own, and the
settings file carries a `hooks` key of the same entries. Both are observed;
only the files are written.

**Plugin install and remove are parked** with the Claude marketplace work;
only the `enabledPlugins` toggle ships.

## Format facts

- **Name rule:** `LowerKebab { max_len: None }`. Namespace separator `-`,
  not `__`.
- **MCP transports:** stdio, streamable HTTP, SSE. A command server is typed
  `local`; a url server keeps whatever transport it declares, named by `type`
  (`server`, `crates/core/src/engine/copilot.rs`).
- **Agent file:** `<name>.agent.md` (double extension required). YAML
  frontmatter + markdown body. kendex writes `name`, `description`, `model?`
  and `tools`. Skills and hooks are not frontmatter fields; both travel as
  prose (`crates/core/src/render/agent/copilot.rs`).
- **Model dialect:** every tier resolves to `auto`, and `inherit` omits the
  key entirely. An explicit user-set id passes through unchanged as free
  text, never validated against an enum.
- **Tool vocabulary:** `read`, `grep`, `glob`, `bash`, `edit`, `multiedit`,
  `write`, `webfetch`, `websearch`, `todowrite`, `agent`, `notebookread`,
  `notebookedit`. A name Copilot does not document is left alone.
- **Agent scoping:** none — only `agents = "all"` custom hooks are enforced
  here.

## Permissions

`tools:` is a real allowlist: an `AllowOnly` intent renders natively. A
`DenyExtra` intent cannot be expressed; the rendering warns, names the tools
the agent keeps, and installs.

## Hooks

Enforced: Copilot runs the command and honors the exit code.

| Fleet event | Copilot event |
|---|---|
| `PreToolUse` | `preToolUse` |
| `PostToolUse` | `postToolUse` |
| `PermissionRequest` | `permissionRequest` |
| `UserPromptSubmit` | `userPromptSubmitted` |
| `SessionStart` / `SessionEnd` | `sessionStart` / `sessionEnd` |
| `PreCompact` | `preCompact` |
| `Notification` | `notification` |
| `Stop` | `agentStop` |
| `SubagentStop` | `subagentStop` |

kendex registers the camelCase spelling. Copilot's remaining events —
`postToolUseFailure`, `userPromptTransformed`, `subagentStart`,
`errorOccurred` — have no fleet counterpart and stay unmapped, with a note.

**Timeouts are seconds** (`timeoutSec`), written as the source wrote them.
Each hook gets a file of its own — `<name>.json` beside `<name>.sh`. The
document shape is
`{"version": 1, "hooks": {"<event>": [{"type": "command", "bash": …,
"matcher": …, "timeoutSec": …}]}}`; a file left holding no hooks keeps its
version line (`crates/core/src/configedit/copilot.rs`).

At project scope the command resolves through
`$(git rev-parse --show-toplevel)`.

## Effective state — when an install is inert

- **`disableAllHooks`** switches off every Copilot hook, all or nothing.
  kendex reads the whole layer stack, lowest first, and reports which file
  threw the switch: legacy `~/.copilot/config.json` → `~/.copilot/settings.json`
  → `.claude/settings.json` → `.claude/settings.local.json` →
  `.github/copilot/settings.json` → `.github/copilot/settings.local.json`.
  Later wins.
- **`disabledSkills` / `disabledMcpServers` in a personal file.** These
  merge as a union: a repository may *add* a name to a disabled list but can
  never take one off. kendex never writes a project-scope enable over a
  user-scope disable — it reports the hold per item, naming the file and the
  key to edit.
- **`.github/allowed_models.txt`** restricts model ids with `*` globs (a
  `fallback:` line names what to use when nothing matches and is not itself a
  pattern). An agent naming a model outside the list warns; `auto` is exempt.

All three are reads of files on disk; the wording says how things are
configured and never claims what a run will do
(`crates/core/src/engine/copilot.rs`,
`crates/core/src/harness/copilot/settings.rs`).

## Migration and old-shape tolerance

Legacy `~/.copilot/config.json` is read and never written. A global scope
holding `config.json` with no `settings.json` refuses settings-backed writes,
with that reason.

## Cross-reads — Copilot reads other tools' files

Copilot CLI discovers skills from `.claude/skills` and `.agents/skills`, VS
Code discovers agents from `.claude/agents`, and the CLI reads
`.claude/settings.json` and `.claude/settings.local.json` for
`companyAnnouncements`, `disableAllHooks`, `enabledPlugins`,
`extraKnownMarketplaces` and `hooks`.

The adapter claims none of them. A repo-root `.mcp.json` is likewise kept
out of the surface list — it is Claude Code's file. The reach is reported as
a note on the plan for skills, and as the `disableAllHooks` layer stack
above.

## Shipped behavior

- The capability table does not carry the repository-scope `disabledSkills`
  asymmetry as a column; the external hold is reported per item, where it is
  read.
- Hooks toggle by renaming the *script* to `.disabled` while reversing the
  registration inside the JSON document — the same mechanism every other
  harness uses.
- Every tier maps to `auto`; the key is omitted for `inherit`.
- `user-invocable` and `disable-model-invocation` are documented agent
  fields, not skill fields. kendex writes neither on either.
