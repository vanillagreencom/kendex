# Pi

The only harness with an extension kind kendex installs end to end, and the
only one whose tool surface is deny-only over an open-ended vocabulary — an
allowlist is refused.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.pi/agent` | `PI_CODING_AGENT_DIR` |
| Project | `<project>/.pi`, plus the shared `<project>/.agents` | — |

Project markers: a `.pi/` or `.agents/` directory. Owner:
`crates/core/src/harness/pi.rs`.

## Surfaces

| Kind | Global | Project | Caps |
|---|---|---|---|
| agent | `~/.pi/agent/agents/*.md` | `.pi/agents/*.md` | managed, both |
| skill | `~/.pi/agent/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md` — **shared with Codex** | managed, both |
| command | `~/.pi/agent/prompts/*.md` | `.pi/prompts/*.md` | observe only, both |
| hook | `~/.pi/agent/kendex/hooks/<name>.sh` + `kendex/hooks.json` | `.pi/kendex/hooks/<name>.sh` + `.pi/kendex/hooks.json` | managed, both — enforced while the `pi-hooks` carrier is registered |
| mcp-server | — | — | unsupported |
| plugin | — | — | unsupported |
| pi-extension | `~/.pi/agent/settings.json` `packages[]`, and `~/.pi/agent/extensions/*.{ts,js}` | `.pi/settings.json` `packages[]`, and `.pi/extensions/*.{ts,js}` | managed, both |

Pi executes nothing per hook itself: the `pi-hooks` carrier extension runs
them, and hook content rides in the registry kendex renders beside it —
`kendex/hooks/<name>.sh` plus `kendex/hooks.json`, keyed by Pi's own
listener names (`pi_listener`: tool call, tool result, turn end, session
start). An event outside that map installs nothing on Pi, said as a note. On
a bash tool call the carrier spawns the rendered `block-bare-cd`,
`block-repo-copy` and `pre-commit-check` scripts in that order with the
payload Claude Code sends a `PreToolUse` hook, and stops at the first
nonzero status. Exit 2 is the refusal, and its stderr is what the agent
reads. Every other nonzero status blocks as well, under a reason the carrier
writes itself: a script exiting 1, a spawn that failed, and a run past the
60s budget are all a guard that reached no verdict, and a guard that did not
run does not stand aside. Only exit 0 reaches the next script, and stderr
written beside it is an advisory for the person rather than the agent. So
the three run the same bytes under Claude, Codex and Pi. It resolves the
project the way the rest of the adapter does, from the nearest ancestor
carrying a marker, and the global root from `PI_CODING_AGENT_DIR`; a project
script runs only where Pi reports the workspace trusted, since spawning it
executes what the project ships. The global root is exempt from that question
because it holds the person's own files, so the carrier uses it only where it
is one: the variable unset or absolute, and in an untrusted workspace falling
outside that workspace. Empty or relative it names whichever directory the
session sits in, which would put a checkout's own script behind the exemption.
A script the carrier finds at neither scope is a hook this project has not
installed, and nothing runs.

**The reserved names.** Pi warns on two directory names directly beside a
root it loads and halts an interactive start until a keypress: `hooks/` on
the name alone, and `tools/` when it holds entries beyond Pi's own `fd`/`rg`
binaries and dotfiles. kendex keeps both scripts and registry one level
down, under `kendex/` (`harness::pi::HOOK_HOME`), and writes nothing to
`tools/` at either scope — an extension's `bin` entries link into the
scope's `bin/`. Anything a prior kendex left under a reserved name is moved
off on the next plan, the directory with it (`engine::pi_hooks_move`):

- kendex takes a file under the reserved name only when this scope's lock
  names it and its bytes hash to what apply last wrote; from the legacy
  registry it takes only entries the lock accounts for that are really in
  the file, trashing the registry only when that leaves it empty.
- A hook nothing declares any more is retired outright; a hook this pass
  rendered is retired against that rendering; a still-declared hook whose
  replacement this pass did not put in place (source unresolved, script or
  registration unwritten) waits. Bundle members are not orphans.
- A copy kendex cannot prove it wrote holds the whole installation: its old
  registration stays live and no fresh rendering takes over. A registration
  kendex cannot remove holds the script it names. Removability is proven by
  taking the entry out and reading the document back, never by the edit
  reporting success (a handler directly under its event is a shape the edit
  reaches past).
- A registry that is a link, unreadable, or holds an entry kendex must
  remove in a shape its editor cannot rewrite blocks every hook; an entry
  kendex cannot pick out of an otherwise editable document blocks that hook
  alone. A hook on record as finished blocks nothing.
- A registration is identified by its command plus, where the record kept
  them, its event and matcher — read from the keyed parts of the document,
  never from the one display line. An unset matcher and an empty matcher
  are the same matcher. Two entries with the same command and no recorded
  event or matcher are one unresolved puzzle, and a puzzle holds.
- At the new path the record keeps the event and matcher the hook was
  installed under, whatever the catalog renders today. Under the reserved
  name a script-backed hook is named by its command alone.
- A registration moved by hand to the new path, or written in a shape
  kendex's edits step over, is detected by applying this pass and reading
  the file back: a refresh never doubles it and a removal never takes the
  script out from under it. Naming the hook for removal writes nothing and
  removes the command wherever it was moved.
- A link where the registry goes is not read through; that is a scope
  question, not a hook question, and is asked wherever the old layout is.
- Once a hook has finished moving, nothing under the reserved name is
  kendex's — not the script, not an entry spelling the command kendex
  registered, not the empty directory. The lock records this
  (`left_pi_reserved_name`); the move reads it back instead of recomputing.
  It is written only when the move is proven over: new copy in place,
  nothing of the hook's registered under the reserved name, and the new path
  running what the record asks (for a hook installed disabled, nothing). A
  first-time install is over before it starts. A lock without the record
  falls back to reading; the first pass finding nothing under the reserved
  name writes the record. The record is what moved the install record's
  version to 5; an older kendex refuses the file.
- Discarding edits finishes the move in the same pass — old copy to the
  trash, one registration left. Discarding covers bytes only: every gate
  that lets a deletion through asks for a plain file first; a directory or
  link where the script was is held and named, never trashed. Everything
  held back gets a line saying which file and why; `refresh` prints them,
  and the conflict row carries the same cause.
- While any installation of kendex's remains under the reserved name, the
  registry beside it is a scan surface: `kendex list`, the app and the
  safety scan carry the copy that is firing. Once nothing of kendex's is
  left there, that registry goes unread.

Enforcement is read live (`pi_ext::carrier::enforcement`): with the carrier
registered in either scope's settings the hook is enforced; with no carrier
anywhere Pi loads, the install downgrades to advisory, said per item. Pi
reads no MCP servers, so its transport list is empty.

## Format facts

- **Name rule:** `Any`. Namespace separator `__`.
- **MCP transports:** none.
- **Agent file:** YAML frontmatter + markdown body, `<name>.md`. kendex
  writes `name`, `description`, `deny-tools?`, `allowed-subagents?`,
  `model?`, `color?` and `pane?` (`crates/core/src/render/agent/pi.rs`).
- **Model dialect:** `fable` and `opus` omit the key (inherit); other tiers
  resolve to `openai-codex/gpt-5.6-sol`. A bare id with no `/` passes
  through with a warning. An effort setting rides along as a `:<effort>`
  suffix on the model id.
- **Frontmatter schema:** none enforced; the validator checks the name rule
  only.
- **Agent scoping:** none — only `agents = "all"` custom hooks are enforced
  (carrier permitting); scoped ones render as advisory prose in the agent
  files.

## Permissions

Deny-only. `allowed-subagents` and `deny-tools` have to agree, so they are
resolved together: engineers delegate to `scout` by default and every other
role is a leaf. `subagent`, `get_subagent_result`, `steer_subagent` and
`stop_subagent` are always denied; `delegate_subagent` is denied too unless
delegation was declared; everything but the planner denies `question`, and a
reviewer also denies `tasks_write`.

An `AllowOnly` intent is a hard refusal for this harness: nothing is
rendered and the reason names both fixes — set an explicit `deny-tools`
override for Pi, or drop Pi from the agent's harnesses.

## Pi extensions

An extension is an npm-shaped package. A source ships
`pi-extensions/<name>/`; kendex copies it into the scope's `packages/`
directory, resolves its production dependencies with npm
(`--omit=dev --package-lock=false --legacy-peer-deps --no-audit --no-fund`),
links its `bin` entries into the scope's `bin/`, registers it in the scope's
`settings.json`, and mirrors its `pi.appendSystem` file into the scope's
`APPEND_SYSTEM.md` as a marker block (`crates/core/src/pi_ext/`).

**Cross-scope duplicate guard.** The same package under two names, or at
two scopes, registers twice and crashes Pi at startup; kendex checks for the
duplicate before writing
(`duplicate_elsewhere`, `crates/core/src/pi_ext/renames.rs`).

## Migration and old-shape tolerance

Catalog packages live under the `@vanillagreen/` npm scope; older installs
and locks carry unscoped names, and a few older names still (`pi-subagents`,
`prompt-stash`). The rename table maps each current name to every name it
has had, so an old install is recognized rather than reinstalled beside
itself (`RENAMES`, `crates/core/src/pi_ext/renames.rs`).
