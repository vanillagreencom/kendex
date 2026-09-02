# @vanillagreen/pi-hooks

The carrier that makes kendex's `PreToolUse` hooks run under Pi. Each of the guards kendex renders is independently toggleable.

## Hooks

Pi has no per-hook runner, so kendex registers every hook it installs for Pi in `kendex/hooks.json`, keyed by the listener Pi fires, and this extension is what dispatches that registry on a tool call. Whatever the `tool_call` key names for the tool being called runs, in the order it names them, and the first refusal is the answer — a guard from kendex's catalog and a `[[custom-hooks]]` command of your own alike. A custom hook has no file of its own, so the registry is the only place it exists.

**Only `PreToolUse` hooks run.** kendex also maps `PostToolUse`, `Stop`, `TaskCompleted` and `SessionStart` onto Pi's `tool_result`, `turn_end` and `session_start` listeners and registers them in the same file, and this carrier does not dispatch those keys, so a hook declared for one of those events does not fire.

Each registration is handed a payload in the shape Claude Code sends a `PreToolUse` hook — `{tool_name, tool_input}` — and its exit status is read: `2` refuses the tool call with the hook's stderr as the reason, `0` allows it, and anything else refuses too, because a guard that did not run does not stand aside. A hook writing to stderr and still exiting `0` is an advisory, shown to the person through the UI and never to the agent. A registry kendex wrote that cannot be read — a merge left conflict markers in the project's copy, a `sudo kendex apply -g` left the global one root-owned — refuses on the same rule; only an absent registry allows, because that is kendex having installed nothing here. So does a hook kendex registered whose rendered `.sh` no scope holds, under a reason naming the missing render.

A registration's `matcher` decides which tool calls it judges, as a whole-string regex over the tool named the way kendex's own vocabulary table writes it (`crates/core/src/render/vocab/mod.rs`, mirrored in `vocab.ts` and held to it by a test): Pi's `bash` is `Bash` and its `find` is `Glob`, while its `powershell` has no Claude Code name and is spelled `powershell`. Absent, empty and `*` cover every tool, and a matcher that will not compile judges the call rather than skipping it — kendex labels these hooks enforced, and the alternative is a guard silently off for every tool.

The input keying is this carrier's own, and it is one rename: the `path` a `read`, `write` or `edit` call carries reaches the hook as `file_path`. Nothing else is reshaped, so an `edit` call arrives with Pi's own `edits` array rather than Claude Code's `old_string`/`new_string` pair, and a guard authored against Claude Code's `Edit` payload will not find what it expects.

The registries are `<project>/.pi/kendex/hooks.json`, then `<global>/kendex/hooks.json`. A hook kendex rendered is spawned at the path the registry it came from anchors — `<root>/kendex/hooks/<name>.sh` — rather than through the command that names it, because the command spells a project path as `$(git rev-parse --show-toplevel)/…` and git's answer is not always kendex's: a vendored checkout inside a project is its own git root, and a project with no git has no answer at all. A command that is not one of kendex's own is run through a shell exactly as written. The project is resolved the way `kendex` itself resolves it before rendering (`crates/core/src/discover.rs`): a `.kendex-lock.json` file wherever it stands, your home directory included, otherwise the nearest ancestor carrying one of the harness marker directories kendex knows (`.claude/`, `.codex/`, `.opencode/`, `.cursor/`, `.pi/`, `.agents/`, `.gemini/`), and home itself is not a project however else it is marked. A `.git/` is not one of them, so a vendored checkout does not stop the walk short of the project the guards were rendered into. So a session started in a subdirectory gets the same hooks as one started at the repository root, and it gets them in whichever project `kendex apply` rendered them into. The global root is `~/.pi/agent` unless `PI_CODING_AGENT_DIR` names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX; empty, whitespace-only, relative and driveless-rooted values use the default, and `~` expands to your home directory.

**The project's registry is read only in a workspace Pi reports trusted.** Running what it names is executing code the project ships, so a clone nobody has trusted gets its hooks skipped rather than run; the global registry still answers, because those hooks are the person's own. Pi saves that decision for the folder or any parent, so it is the answer for the whole tree. A registry naming nothing for this call is kendex having installed no hook here, and the command passes.

That is the whole of it: no second implementation. Claude Code, Codex and Pi run the same bytes, so a change to a hook reaches all three at once.

These three ship with kendex and have a toggle each below. Anything else the registry names — a custom hook above all — has no toggle of its own and rides the master switch.

| Hook | Pi event | Runs |
| --- | --- | --- |
| Block bare `cd` | `tool_call` (`Bash`) | `hooks/block-bare-cd.sh` |
| Block repo copy into scratch | `tool_call` (`Bash`) | `hooks/block-repo-copy.sh` |
| Pre-commit gate | `tool_call` (`Bash`) | `hooks/pre-commit-check.sh` |

`block-unsafe-rm` has no Pi port; it declares `harnesses:` without `pi`, so kendex reports Pi as `unsupported` for it rather than claiming enforcement that does not exist.

Two more are native listeners, because Pi's events have no bash equivalent to spawn.

| Hook | Pi event | Behavior |
| --- | --- | --- |
| End-of-turn clippy | `turn_end` | If `.rs` files were touched during the turn, runs workspace clippy once. The summary steers the run, so the agent reads it in the turn that follows in every mode, headless included; an interactive session also gets a UI notification. Every failing turn reports, including one whose errors are unchanged: an agent stuck on an error hears the same advisory each turn, and a turn touching no Rust runs no clippy and reports nothing. A run that established nothing — no workspace root, a timeout, a clippy failure printing no error line — says so rather than passing as clean. Advisory only. |
| Session-start drift report | `session_start` | On a fresh start (startup, new, fork — not resume or reload) runs `kendex check --quiet` in the background and hands the agent the drift report: outdated items (`kendex refresh`), items removed upstream (`kendex remove <name>`, `-g` in a global section), unreachable sources, and packages not yet evaluated against their sources (a background refresh settles them). Silent when the install is current; one line when no `kendex` binary is on `PATH`, the session directory is unreadable, or the check fails unexpectedly. Never blocks startup. Informational only — never installs or removes anything and never touches the project's git; the check never waits on the network (its only writes are kendex's own cache bookkeeping under `~/.kendex/cache`), and a source cache there older than its TTL is refreshed by a detached background process nobody waits on. |

## Install

```bash
kendex add --pi-extension pi-hooks
```

Or as part of `kendex add --all`. Refresh with `kendex refresh`.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-hooks):

```bash
pi install npm:@vanillagreen/pi-hooks
```

The npm package ships the carrier, not the hooks. Nothing runs until kendex has rendered a registry for this project or your global Pi root, so install the guards with `kendex add --hook block-bare-cd --hook block-repo-copy --hook pre-commit-check` (or `kendex add --all`).

## Settings

Open `/extensions:settings`; settings appear under the **Hooks** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, kendex Pi extensions read user/global settings only.

| Setting | What it does |
| --- | --- |
| Enable hooks | Master toggle. Disable to make the extension inert without uninstalling. |
| Block bare cd | Toggle the bare-cd block hook. |
| Block repo copy into scratch | Toggle the recursive-copy-into-scratch block. |
| Pre-commit gate | Toggle the pre-commit gate. |
| End-of-turn clippy | Toggle the end-of-turn advisory hook. |
| Session-start drift report | Toggle the session-start `kendex check` report. |
| Hook timeout ceiling | Max ms one registered hook may run on a tool call. A registration asking for less runs to what it asks for; one asking for more is cut to this. |
| Drift check timeout | Max ms the session-start `kendex check` may run before it is abandoned. |
| Clippy timeout | Max ms for the whole end-of-turn check: the workspace lookup takes up to a quarter, clippy the rest. |
