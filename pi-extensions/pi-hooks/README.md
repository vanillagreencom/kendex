# @vanillagreen/pi-hooks

The carrier that makes kendex's safety hooks run under Pi. Each hook is independently toggleable.

## Hooks

Three of them are the rendered bash hooks themselves. Pi has no per-hook runner, so this extension spawns the script with the payload Claude Code sends a `PreToolUse` hook and reads the exit status: `2` refuses the tool call with the script's stderr as the reason, `0` allows it, and anything else refuses too, because a guard that did not run does not stand aside. A script writing to stderr and still exiting `0` is an advisory, shown to the person through the UI and never to the agent.

It looks for `<project>/.pi/kendex/hooks/<name>.sh`, then `<global>/kendex/hooks/<name>.sh`, where `<global>` is `PI_CODING_AGENT_DIR` if set and `~/.pi/agent` otherwise. The project is resolved the way `kendex` resolves it: a `.kendex-lock.json` wherever it stands, otherwise the nearest ancestor of the session's directory holding one of the harness marker directories kendex knows (`.claude/`, `.codex/`, `.opencode/`, `.cursor/`, `.pi/`, `.agents/`, `.gemini/`), and never your home directory. So a session started in a subdirectory gets the same hooks as one started at the repository root, and it gets them in whichever project `kendex apply` rendered them into.

**A project-scope script only runs in a workspace Pi reports trusted.** Spawning it is executing code the project ships, so a clone nobody has trusted gets its guards skipped rather than its scripts run; the global root still answers, because those scripts are the person's own. That last part is only true while `PI_CODING_AGENT_DIR` names a directory of its own, so the global root is used only when the variable is unset or absolute, and in an untrusted workspace only when it falls outside that workspace. Empty or relative, it would be whichever directory the session happens to sit in, and a checkout's script would be reached through the branch that skips the trust gate. A name neither root holds is a hook kendex has not installed here, and the command passes.

That is the whole of it: no second implementation. Claude Code, Codex and Pi run the same bytes, so a change to a hook reaches all three at once.

| Hook | Pi event | Runs |
| --- | --- | --- |
| Block bare `cd` | `tool_call` (bash) | `hooks/block-bare-cd.sh` |
| Block repo copy into scratch | `tool_call` (bash) | `hooks/block-repo-copy.sh` |
| Pre-commit gate | `tool_call` (bash) | `hooks/pre-commit-check.sh` |

The guards run in that order and stop at the first refusal.

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

The npm package ships the carrier, not the hook scripts. The three bash guards run only where kendex has rendered them, so install them with `kendex add --hook block-bare-cd --hook block-repo-copy --hook pre-commit-check` (or `kendex add --all`).

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
| Drift check timeout | Max ms the session-start `kendex check` may run before it is abandoned. |
| Clippy timeout | Max ms for the whole end-of-turn check: the workspace lookup takes up to a quarter, clippy the rest. |
