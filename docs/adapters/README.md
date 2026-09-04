# Adapter reference

One page per harness, holding the on-disk facts an adapter maintainer needs: roots and project markers, the surface for each kind and its shape, the format the harness loads, and what kendex may do there. The boundaries and invariants shared by every adapter are [../architecture/harnesses.md](../architecture/harnesses.md); a page here states facts, and the code it names is where each fact is enforced.

| Harness | Page | Owner | Global root | Project root |
|---|---|---|---|---|
| Claude Code | [claude.md](claude.md) | `crates/core/src/harness/claude.rs` | `~/.claude` | `.claude/` |
| Codex | [codex.md](codex.md) | `crates/core/src/harness/codex.rs` | `~/.codex` (`CODEX_HOME`) | `.codex/`, `.agents/` |
| OpenCode | [opencode.md](opencode.md) | `crates/core/src/harness/opencode.rs` | `~/.config/opencode` (`OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`) | `.opencode/` |
| Cursor | [cursor.md](cursor.md) | `crates/core/src/harness/cursor.rs` | `~/.cursor` | `.cursor/` |
| Pi | [pi.md](pi.md) | `crates/core/src/harness/pi.rs` | `~/.pi/agent` (`PI_CODING_AGENT_DIR`) | `.pi/`, `.agents/` |
| Gemini CLI | [gemini.md](gemini.md) | `crates/core/src/harness/gemini/mod.rs` | `~/.gemini` | `.gemini/` |
| GitHub Copilot | [copilot.md](copilot.md) | `crates/core/src/harness/copilot/mod.rs` | `~/.copilot` (`COPILOT_HOME`) | `.github/` |

The Gemini and Copilot pages rest on [gemini-copilot-matrix.md](gemini-copilot-matrix.md), the observation record the code cites as `matrix §N`; it is kept as written.

## The capability table

What kendex may do on a harness is one table, `crates/core/src/harness/caps.rs`, read by core and the UI; a page's Caps column is a reading of it, never a second source.

- `capabilities(harness, kind)` gives `observe`, `adopt`, `install`, `toggle`, `remove` and `refresh`, each as project and global booleans, built from `managed`, `observe_only` and `unsupported`; a row may carry `installs_as`, the kind the harness stores the item as.
- `format_caps(harness)` gives the name rule the loader enforces (`Any`, or `LowerKebab` with an optional length) and the MCP transports the harness speaks; no harness caps a SKILL.md body.
- `enforcement` is carried by Hook rows alone: `Enforced` where the tool runs the registered command and honours its result, `Advisory` where the hook installs as text.
- A hold a harness's own configuration places on an item (Copilot's `disabledSkills`) is not a column; the switch kendex owns works both ways because it is a rename, and the hold is reported per item where it is read.

## Surface shapes

A surface is one of four shapes, declared per kind and scope by each adapter (`Surface`, `crates/core/src/harness/mod.rs`):

- `FileDir`: one item per `<dir>/<name>.<ext>`, one folder level of namespacing, `.disabled` suffix for a disabled item.
- `SubdirPerItem`: one item per subdirectory holding a marker file, almost always `SKILL.md`.
- `Structured`: items are entries inside one structured file; a `Reader` names the on-disk format.
- `StructuredDir`: every `*.<ext>` in a directory is a document holding entries; a document holding none reports none.

Every harness but Claude Code reads a project's `.agents/skills`, so one rendered tree serves them all and a per-harness directory stays on the surface list for what is already there and for a copy delivery. Claude's own `.claude/skills/<name>` collapses onto the shared tree through a relative link when the bytes match. An adapter claims only its own namespace; a cross-read is reported as an input to effective state, never as a second installation.

## Names

A namespaced `<plugin>/<item>` name is the identity in the manifest, the lock and the UI. On disk the two halves are joined by `__`, or by `-` where the name rule is lower-kebab; `namespace_separator` in `crates/core/src/harness/caps.rs` derives it from the rule. The shared tree always uses `__`.

## Instruction shims

Beside every tracked `AGENTS.md`, kendex writes a `CLAUDE.md` holding `@AGENTS.md`, and for the gemini harness it names `AGENTS.md` in `context.fileName` of `.gemini/settings.json`; both are committed files, and a missing, stale or symlinked shim is drift (`crates/core/src/engine/instruction_shims.rs`).
