# Adapter reference

One page per harness, holding the durable facts about that tool's on-disk
surfaces: where things live, what format they take, which operations kendex
supports there, and why. These are reference docs — when a capability
changes, the code and the page beside it change together.

| Harness | Doc | Global root | Project root |
|---|---|---|---|
| Claude Code | [claude.md](claude.md) | `~/.claude` | `.claude/` |
| Codex | [codex.md](codex.md) | `~/.codex` (`CODEX_HOME`) | `.codex/`, `.agents/` |
| OpenCode | [opencode.md](opencode.md) | `~/.config/opencode` (`OPENCODE_CONFIG_DIR`) | `.opencode/` |
| Cursor | [cursor.md](cursor.md) | `~/.cursor` | `.cursor/` |
| Pi | [pi.md](pi.md) | `~/.pi/agent` (`PI_CODING_AGENT_DIR`) | `.pi/`, `.agents/` |
| Gemini CLI | [gemini.md](gemini.md) | `~/.gemini` | `.gemini/` |
| GitHub Copilot | [copilot.md](copilot.md) | `~/.copilot` (`COPILOT_HOME`) | `.github/` |

The Gemini and Copilot pages rest on
[gemini-copilot-matrix.md](gemini-copilot-matrix.md) — the observation
matrix, discrepancy log, and risk notes the code cites as `matrix §N`.

## The capability model

Everything a page says about *what kendex may do* comes from one table,
`crates/core/src/harness/caps.rs`, read by core and by the UI. It has four
axes.

**The op table** — `capabilities(harness, kind) -> KindCaps` gives
`observe · adopt · install · toggle · remove · refresh`, each as a pair of
booleans for project and global scope. Three constructors cover almost every
row: `managed(scopes)` (all six), `observe_only(scopes)` (read, never write),
`unsupported()` (the harness has no such surface, and kendex never shims one
in). A row may also carry `installs_as`, naming the kind the harness actually
stores the item as — the only one today is a Codex command, stored as a
skill, because the vendor itself retired its prompts directory.

Two tests keep the table honest: the `observe` column must equal what the
adapters declare as surfaces, and no mutation column may exceed the
observation of whatever the mutation writes.

**Format facts** — `format_caps(harness) -> FormatCaps` owns the name rule
the harness's loader enforces (`Any` or `LowerKebab { max_len }`) and the
MCP transports it speaks. No harness caps a SKILL.md body. These
live beside the op table rather than as literals inside renderers, so the
renderers, the validators and the surface model all read one source.

**Enforcement** — only Hook rows carry anything but `NotApplicable`.
`Enforced` means the tool runs the registered command and honors its result;
`Advisory` means the constraint installs as text the model may ignore.
`managed` never implied enforcement, so an advisory install says so in the
plan preview, the report and the tool's card.

**Toggle direction** — where a harness's own configuration holds an item down
from a layer this scope cannot answer (Copilot's `disabledSkills`, which a
repository may add to but never take from), the table still says kendex's own
switch works both ways, because it does: the switch is a rename kendex can
undo. The external hold is reported per item where it is read.

## The surface model

A surface is one of four shapes, declared by each adapter per kind and per
scope (`Surface` in `crates/core/src/harness/mod.rs`):

- `FileDir` — one item per file, `<dir>/<name>.<ext>`, with one folder level
  of namespacing. A `.disabled` suffix marks a disabled item.
- `SubdirPerItem` — one item per subdirectory holding a marker file, almost
  always `SKILL.md`.
- `Structured` — items are entries inside one structured file; a `Reader`
  variant names the exact on-disk format.
- `StructuredDir` — every `*.<ext>` in a directory is a document of its own
  holding entries. Copilot's hook files work this way, so a document holding
  no entries reports no items rather than reading as a live installation.

Several tools read the same physical directory. Codex and Pi both consume
`.agents/skills` in a project; Gemini and Copilot read skill trees other
tools own. Harnesses whose skill directory resolves to the same path form a
**surface group** carrying exactly one rendered variant, validated against
every member's loader. A variant whose bytes match the shared tree collapses
onto it through a link; a divergent one gets its own tree, and the move runs
both ways. A refusal
is per surface, not per tool.

A cross-read is never a second installation. An adapter claims only its own
namespace — Copilot claims `.github/**` and `~/.copilot/**` and leaves
`.claude/` and `.agents/` to the harnesses they are named for — and the
reach is reported as an input to effective state.

## Names

A namespaced `<plugin>/<item>` name is the identity in the manifest, the lock
and the UI. The `/` never reaches disk: the plugin and item halves are joined
with `__` by default, or `-` where the name rule is lower-kebab and an
underscore would make the item unloadable. The separator is derived from the
name rule, in the same file
(`namespace_separator`, `crates/core/src/harness/caps.rs`).
