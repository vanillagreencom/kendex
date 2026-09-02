# Pi

The only harness with an extension kind kendex installs end to end, and the
only one whose tool surface is deny-only over an open-ended vocabulary — an
allowlist is refused.

## Roots

| Scope | Path | Relocated by |
|---|---|---|
| Global | `~/.pi/agent` | `PI_CODING_AGENT_DIR` |
| Project | `<project>/.pi`, plus the shared `<project>/.agents` | — |

kendex trims `PI_CODING_AGENT_DIR`, expands `~` against the configured home,
and uses an override only when it is anchored to a named root: a drive or a
UNC share on Windows, a leading `/` on POSIX. Empty, whitespace-only, relative
and driveless-rooted values use `~/.pi/agent`. `pi_root_is_absolute_for` in
`crates/core/src/harness/pi.rs` is the rule, and every standalone Pi package's
runtime readers apply their own copy of it, held against the Rust source case
for case by the pi-hooks suite. So no value makes a package's user scope follow
the session's directory implicitly — naming that directory outright still
points it there, which is the person's own choice. The `scripts/append-system.mjs`
install helpers are outside that: they resolve the variable as given, at
install time, and only into a directory that already exists.

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
start). An event outside that map installs nothing on Pi, said as a note.

The registry is the carrier's list, and `tool_call` is the only key it
reads: a hook kendex maps onto `tool_result`, `turn_end` or `session_start`
is registered and labelled enforced and does not fire. On a `tool_call` it
runs every registration whose `matcher` covers the tool, in the order the
file names them — so a catalog guard and a `[[custom-hooks]]` command of the
person's own both fire, and the carrier knows no hook's name in advance. A
custom hook has no file at all (`HookBody::Command` is registered verbatim),
so the registry is the only place it exists; a carrier spelling out script
names reported it enforced and ran nothing (KEN-941). Absent, empty and `*`
matchers cover every tool; anything else is a whole-string regex over the
tool said in Claude Code's words (`vocab.ts`, held by a test to
`render::vocab::claude_tool_name`).

Exit 2 is the refusal, and its stderr is what the agent reads. Every other
nonzero status blocks as well, under a reason the carrier writes itself: a
hook exiting 1, a spawn that failed, a run past its budget, a registry that
exists and could not be read, and a rendered hook the registry names whose
script no scope holds are all a guard that reached no verdict, and a guard
that did not run does not stand aside. Only an absent registry allows,
because that is kendex having installed nothing here. Only exit 0 reaches
the next registration, and stderr written beside it is an advisory for the
person rather than the agent.

A hook kendex rendered is spawned at `<root>/kendex/hooks/<name>.sh` under
the root whose registry named it, not through the command that names it, so
the rendered guards run the same bytes under Claude, Codex and Pi. Any other
command is the person's own and is run through a shell as written. The
carrier resolves the project with `discover.rs::project_root_from`,
not this adapter's two-marker row above: the lock file wherever it stands, home
included, else the nearest ancestor carrying one of the seven `MARKER_DIRS`,
and home itself is never a project otherwise. That is what kendex asks before
it renders, so the carrier reads from where the renderer wrote, and `.git/` is
in neither list so a vendored checkout does not stop the walk.

The project's registry is read only where Pi reports the workspace trusted,
since running what it names executes what the project ships; Pi saves that
decision for the folder or any parent, so a session in a subdirectory gets
the same hooks as one at the root. Untrusted or outside any project, the
project scope contributes nothing and the global root still answers, because
it holds the person's own files. A registry naming nothing for a call is a
hook this project has not installed, and nothing runs.

**The reserved names.** Pi warns on two directory names directly beside a
root it loads and halts an interactive start until a keypress: `hooks/` on
the name alone, and `tools/` when it holds entries beyond Pi's own `fd`/`rg`
binaries and dotfiles. kendex keeps both scripts and registry one level
down, under `kendex/` (`harness::pi::HOOK_HOME`), and writes nothing to
`tools/` at either scope — an extension's `bin` entries link into the
scope's `bin/`.

Beside the root, kendex does nothing at all. `engine::targets::pi_hook`
names only `<root>/kendex/hooks.json`, `engine::owned::hook_owned` derives
only `<root>/kendex/hooks/<name>.sh`, and `harness::pi::hook_surfaces`
lists only the first — so a `hooks.json` or `hooks/` an older kendex left
beside the root is read by nothing, written by nothing, scanned by
nothing, listed by nothing and removed by nothing, `kendex remove`
included. A refresh renders the hook under `kendex/` and stops there, and
what is beside the root stays exactly where it is. It does not go on
running: the carrier reads `<root>/kendex/hooks.json` and nowhere else, so
an installation left only in the older layout is named by no registry it
reads — the call is allowed. An install whose scripts sit only beside the root is
therefore unenforced until the item is installed fresh under `kendex/`.
What becomes of the leftovers is the person's, by hand: `<root>/hooks.json`
and the `<root>/hooks/` directory both. Nothing in this build reads there,
so nothing here can say which of them an older kendex wrote and which are
the person's own. Look at them, and move aside what is no longer wanted;
the directory is the one Pi warns about on the name alone.

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
delegation was declared; everything but a `role: planner` agent denies
`question`, and a `role: reviewer` agent also denies `tasks_write`.

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
