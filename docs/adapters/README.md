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
| Antigravity | [antigravity.md](antigravity.md) | `crates/core/src/harness/antigravity.rs` | `~/.gemini/config` | `.agents/` |

The Gemini and Copilot pages rest on [gemini-copilot-matrix.md](gemini-copilot-matrix.md), the observation record the code cites as `matrix §N`; it is kept as written.

## The capability table

What kendex may do on a harness is one table, `crates/core/src/harness/caps.rs`, read by core and the UI; a page's Caps column is a reading of it, never a second source.

- `capabilities(harness, kind)` gives `observe`, `adopt`, `install`, `toggle`, `remove` and `refresh`, each as project and global booleans, built from `managed`, `observe_only` and `unsupported`; a row may carry `installs_as`, the kind the harness stores the item as.
- `format_caps(harness)` gives the name rule the loader enforces (`Any`, or `LowerKebab` with an optional length) and the MCP transports the harness speaks; no harness caps a SKILL.md body.
- `enforcement` is carried by Hook rows alone: `Enforced` where the tool runs the registered command and honours its result, `Advisory` where the hook installs as text.
- A hold a harness's own configuration places on an item (Copilot's `disabledSkills`) is not a column; the switch kendex owns works both ways because it is a rename, and the hold is reported per item where it is read.

## Model and effort

An agent's `model` and `effort` reach each harness under that harness's own key and vocabulary. `crates/core/src/harness/models.rs` owns classes, aliases and native shapes under [D021](../decisions/D021-runtime-model-classes.md). Render validation (`crates/core/src/render/validate/agent.rs`) refuses a value the loader cannot use. Manifest validation (`crates/core/src/manifest/validate.rs`) refuses an `[agent-frontmatter.<harness>.<agent>]` key the harness never renders.

| Harness | Model shape | Effort key | Effort levels | Absent effort |
|---|---|---|---|---|
| Claude Code | classes project to native family aliases; bare `claude-*` id or literal `inherit` | `effort` | `low`, `medium`, `high`, `xhigh`, `max` | the session's level |
| Codex | bare id; classes and `inherit` omit the key for managed-session inheritance | `model_reasoning_effort` | `minimal`, `low`, `medium`, `high`, `xhigh` | the model's default |
| OpenCode | `provider/model`; classes and `inherit` omit the key | `options.reasoningEffort` | `minimal`, `low`, `medium`, `high`, `xhigh` | the provider's default |
| Pi | canonical class, `provider/model` or `provider/family`, optionally `:level`; `inherit` omits the key | `effort` | `minimal`, `low`, `medium`, `high`, `xhigh`, `max` | Pi's `defaultThinkingLevel` |
| Gemini CLI | bare `gemini-*` id; classes and `inherit` omit the key | none | none | none |
| GitHub Copilot | bare id from Copilot's own list; classes and `inherit` omit the key under [D008](../decisions/D008-copilot-agent-model.md) | `reasoningEffort`, never written | none | not yet measured |
| Cursor | none | none | none | none |
| Antigravity | native `flash` or `pro`; classes and `inherit` omit the key | none | none | none |

Class overrides do not turn a class render into an exact pin. Static native files do not resolve account availability. Pi retains the class for its child dispatcher. Codex and Copilot class files inherit the managed session. The class table, the resolver and each harness's runtime path are [D021](../decisions/D021-runtime-model-classes.md); a native loader that gains a documented runtime class or model callback is its revisit trigger.

An input class alias requests a class, not an exact pin. `inherit` follows the session. Readback refuses a provider-qualified native field where the loader needs a bare selector. Pi and OpenCode require a provider on native model selectors. Both provider and model must be nonempty. The model part can contain `/`, as in `openrouter/anthropic/claude-sonnet-4`. Pi also accepts a `:level` from its effort vocabulary.

## Surface shapes

A surface is one of four shapes, declared per kind and scope by each adapter (`Surface`, `crates/core/src/harness/mod.rs`):

- `FileDir`: one item per `<dir>/<name>.<ext>`, one folder level of namespacing, `.disabled` suffix for a disabled item.
- `SubdirPerItem`: one item per subdirectory holding a marker file, almost always `SKILL.md`.
- `Structured`: items are entries inside one structured file; a `Reader` names the on-disk format.
- `StructuredDir`: every `*.<ext>` in a directory is a document holding entries; a document holding none reports none.

The shared skills tree is `.agents/skills` under the scope's own root: the project's, or the home directory. Every harness but Claude Code reads the project's, and every one but Claude Code and Antigravity reads `~/.agents/skills`, so one rendered tree serves them all at either scope and a per-harness directory stays on the surface list for what is already there and for a copy delivery. A harness that does not read the shared tree gets a link in its own directory onto it when the bytes match — relative in a project, absolute globally. An adapter claims only its own namespace; a cross-read is reported as an input to effective state, never as a second installation.

## Hook commands

A hook registered at project scope names its script relative to the project root and finds that file when it runs, so the text is the same on every machine and a repository can commit the registry holding it (`project_command`, `crates/core/src/engine/targets.rs`). Claude Code is the exception: it publishes `$CLAUDE_PROJECT_DIR`, and its command is written against that. Its command for an installed script also opens with a test that exits 0 in a Copilot CLI hook process, because Copilot runs the hooks in `.claude/settings.json` too ([claude.md § Cross-reads](claude.md#cross-reads)). A global command names its script outright, absolute; nothing commits a global registry.

On Copilot either command's run of the script is wrapped so a preToolUse refusal's stderr reaches the model as the denial reason ([copilot.md § Hooks](copilot.md#hooks)).

A `[hooks.<name>]` declaration's `env` table sets variables for that hook's script. The command first resolves `bash` into `b` under the launching environment, then assigns each entry, its value quoted for the shell, directly before `"$b"`, so a declared `PATH` reaches the script and never hides the interpreter. Where the launching environment has no `bash`, `b` holds the bare word and the declared environment finds it. A command that names its script outright binds the path to `h` first, so the script stays the first path the command names (`direct_command`, `crates/core/src/engine/targets.rs`). The Pi carrier reads whether a registered command carries assignments and runs such a command as written, at project scope and global scope alike, so the declared environment reaches the script. It spawns the script directly only for a command that assigns nothing (`registry.ts` and `dispatch.ts`, `pi-extensions/pi-hooks/extensions`).

No other harness publishes a project-directory variable, so the command walks up from the directory the harness runs the hook in until a directory holds the script. That is the directory the harness found this registry from, having walked up from it for its own config, so the project the registration came from is an ancestor and the one holding the file. The walk refuses a start that is not absolute, which is what a shell answers from a directory removed under it, and when nothing from the start up holds the script it exits 1 naming the start and the file rather than letting bash report a missing file.

`$(git rev-parse --show-toplevel)` was the same text everywhere and the wrong answer instead: kendex installs into a project that is no git repository, where it substitutes nothing, and into one below the git top level, where it substitutes the enclosing tree's root. A project marker would be the wrong answer another way: a nested `.claude/` stops a marker walk short of the project, and a Copilot-only project has no marker directory at all.

## Names

A namespaced `<plugin>/<item>` name is the identity in the manifest, the lock and the UI. On disk the two halves are joined by `__`, or by `-` where the name rule is lower-kebab; `namespace_separator` in `crates/core/src/harness/caps.rs` derives it from the rule. The shared tree always uses `__`.

## Instruction shims

Claude Code reads `AGENTS.md` itself; [its adapter reference](claude.md#instruction-shim) gives the version floors and personal-import fallback. kendex retires a former `CLAUDE.md` shim only when the inventory lists it and its bytes are exactly `@AGENTS.md` followed by a newline. Other content, symlinks and unlisted imports stay untouched. For Gemini, kendex names `AGENTS.md` in `context.fileName` of `.gemini/settings.json`; a missing or stale setting is drift (`crates/core/src/engine/instruction_shims.rs`).
