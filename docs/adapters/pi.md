# Pi

The only harness with an extension kind kendex installs end to end, and the
only one whose tool surface is deny-only over an open-ended vocabulary — an
allowlist there cannot be expressed and cannot be complemented without
widening, so it is refused rather than approximated.

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

Pi executes nothing per hook itself: the `pi-hooks` carrier extension hosts
native listeners, and hook content rides in the registry kendex renders
beside them — `kendex/hooks/<name>.sh` plus `kendex/hooks.json`, keyed by Pi's own
listener names (`pi_listener`: tool call, tool result, turn end, session
start). An event outside that map installs nothing on Pi, said as a note.

**The reserved names.** Pi warns about two directory names sitting
directly beside a root it loads, and halts an interactive start until a
keypress: `hooks/` on the name alone, whatever the directory holds, and
`tools/` only when it holds entries beyond Pi's own `fd`/`rg` binaries and
dotfiles. The
migration it names, into `extensions/`, is one kendex's hooks cannot
take: Pi extensions are TypeScript registered in `settings.json`, these
are shell scripts a carrier runs. So both the scripts and the registry
sit one level down, under `kendex/`, where Pi does not look
(`harness::pi::HOOK_HOME`) — the same segment kendex's Pi extensions
already keep per-session state in. kendex writes nothing to `tools/` at
either scope either — an extension's `bin` entries link into the scope's
`bin/`, which is where Pi's own migration moved `tools/`. What an earlier kendex left in the
reserved name comes off disk on the next plan, the directory with it
(`engine::pi_hooks_move`). Two questions stay apart there. *May kendex
take this file*: only one this scope's lock names, whose bytes hash to
what apply last wrote — and the legacy registry gives up only entries
that lock accounts for and that are really in the file, trashed only when
that leaves nothing at all. *Is a replacement coming*: a hook nothing
asks for any more is retired outright (leaving it would keep a removed
hook firing), a hook this pass rendered is retired against that
rendering, and a still-declared hook waits whenever this pass did not put
its replacement in place — the source did not resolve, or the script or
the registration could not be written. "Nothing asks for it" is the
question the orphan sweep asks, so a bundle member, which the manifest
never keys, is not mistaken for an install nobody wants. A copy kendex
cannot prove it wrote holds the whole installation, not just the file:
its old registration stays live and no fresh rendering takes over. A
registration kendex cannot take out holds the script it names, so neither
half is ever left without the other — and whether it can is answered by
taking the entry out and reading the document back, never by the edit
reporting that it ran: a handler standing directly under its event is a
shape the edit reaches past, and the script would go while what runs it
stayed — and what it holds is as wide as the
evidence. A registry that is a link, that cannot be read, or that holds an
entry kendex has to take out in a shape its editor cannot rewrite is in
every hook's way; an entry kendex cannot pick out of an otherwise editable
document is in that one hook's way alone, and a sibling whose own entry is
exactly where its record says still moves. A hook on record as finished is
in nobody's way at all: what wears its old command now is the person's.
The record settles the reserved name and nothing else, so a registration
moved by hand at the new path holds the hook whether the move is over or
not. A registration is named by the command it
runs and, where the record kept them, the event and matcher it fires
under — read from the parts a document keys, never from the one line a
scan displays them on, since the character joining that line is legal
inside a matcher and inside a command alike — and by uniqueness either
way: a command carried twice in a document is one
kendex cannot tell its own copy of, so it holds. At the new path the record keeps
the event and matcher a hook went in under, whatever the catalog renders
today: a catalog is free to move a hook to another event, and reading
where the entry should be off the current rendering called that the
person's doing. Under the reserved name a script-backed hook is still
named by its command alone — its record describes the entry at the new
path, and what an older kendex wrote under the old name is not knowable
from it. What this
pass renders names the entry at the new path only, so a registration
somebody moved there by hand is never doubled by a second one beside it —
asked wherever the old layout has got to, since "nothing of kendex's is
under the reserved name" answers a different question from "this
installation is in good order", and only the first is about that
directory.
Once a hook has finished moving, neither half under the reserved name is
kendex's any more — not the script, and not an entry spelling the command
kendex used to register. That is a fact about the past, so the lock keeps
it (`left_pi_reserved_name`) and the move reads it back instead of
working it out again from bytes and registrations that have every right
to change afterwards. It is written only where the move is proven over —
the new copy in place, nothing of the hook's still registered under the
reserved name, and what runs it at the new path being what the record
asks for, which for a hook installed disabled is nothing at all. A hook
installed for the first time is over before it starts, whoever else's
files happen to be in that directory. A lock written before the record falls back to the
reading, and the first pass that finds nothing under the reserved name
writes the record down. The record is what moved the install record's
version to 5: an older kendex would load the file, ignore the field and
drop it on its next write, and then read a finished move as unfinished —
so it refuses the file instead. Discarding edits finishes the move
in that same pass — the old copy goes to the trash and one registration
is left. Discarding covers bytes, and only bytes: every gate that lets a
deletion through asks for a plain file first, so a directory or a link
left where the script was is held and named, never trashed. Everything held back gets a line saying which
file and why, and `refresh` prints them; the conflict row carries the
same cause, so a hold discarding edits cannot release never asks for a
discard. A held hook is also still
observed where it runs from: while any installation of kendex's remains
under the reserved name, the registry beside it is a scan surface of its
own, so `kendex list`, the app and the safety scan carry the copy that is
firing. Once nothing of kendex's is left there, that registry goes unread.
Enforcement is read live (`pi_ext::carrier::enforcement`): with the carrier
registered in either scope's settings the hook is enforced; with no carrier
anywhere Pi loads, the install downgrades to advisory, said per item. Pi
reads no MCP servers at all, which is why its transport list is empty.

## Format facts

- **Byte cap:** none.
- **Name rule:** `Any`. Namespace separator `__`.
- **MCP transports:** none.
- **Agent file:** YAML frontmatter + markdown body, `<name>.md`. kendex
  writes `name`, `description`, `deny-tools?`, `allowed-subagents?`,
  `model?`, `color?` and `pane?` (`crates/core/src/render/agent/pi.rs`).
- **Model dialect:** `fable` and `opus` omit the key so the child inherits
  the parent session; other tiers resolve to `openai-codex/gpt-5.6-sol`. A
  bare id with no `/` passes through with a warning — Pi has no default
  provider to supply one. An effort setting rides along as a `:<effort>`
  suffix on the model id.
- **Frontmatter schema:** Pi reads plain markdown and enforces none, so the
  name rule is the whole of what the validator can check.
- **Agent scoping:** none — a listener cannot tell which agent triggered
  it, so only `agents = "all"` custom hooks are enforced (carrier
  permitting); scoped ones stay advisory prose in the agent files.

## Permissions

Deny-only. `allowed-subagents` and `deny-tools` have to agree, so they are
resolved together: engineers delegate to `scout` by default and every other
role is a leaf. `subagent`, `get_subagent_result`, `steer_subagent` and
`stop_subagent` are always denied; `delegate_subagent` is denied too unless
delegation was declared; everything but the planner denies `question`, and a
reviewer also denies `tasks_write`.

An `AllowOnly` intent is a hard refusal for this harness. Completing the
allowlist into a deny list would widen access the moment Pi grows a built-in
it never named, so nothing is rendered and the reason names both fixes: set
an explicit `deny-tools` override for Pi, or drop Pi from the agent's
harnesses.

## Pi extensions

An extension is an npm-shaped package. A source ships
`pi-extensions/<name>/`; kendex copies it into the scope's `packages/`
directory, resolves its production dependencies with npm
(`--omit=dev --package-lock=false --legacy-peer-deps --no-audit --no-fund`),
links its `bin` entries into the scope's `bin/`, registers it in the scope's
`settings.json`, and mirrors its `pi.appendSystem` file into the scope's
`APPEND_SYSTEM.md` as a marker block (`crates/core/src/pi_ext/`).

**Cross-scope duplicate guard.** Pi loads the global and project scopes
together and de-duplicates packages by identity, not by the resources they
register. The same package under two names, or at two scopes, registers twice
and crashes Pi at startup — so kendex checks for the duplicate before writing
(`duplicate_elsewhere`, `crates/core/src/pi_ext/renames.rs`).

## Migration and old-shape tolerance

The 1.0.0 release moved every catalog package under the `@vanillagreen/` npm
scope. Installs and locks predating that move still carry the old unscoped
names, and a few carry older names still (`pi-subagents`,
`prompt-stash`). The rename table maps each current name to every name it has
had, so an old install is recognized rather than reinstalled beside itself
(`RENAMES`, `crates/core/src/pi_ext/renames.rs`).
