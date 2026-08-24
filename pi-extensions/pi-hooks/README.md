# @vanillagreen/pi-hooks

![pi-hooks settings panel](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-hooks/assets/hooks-settings.png)

First-class Pi port of the kendex safety hooks listed below. Each hook is independently toggleable.

## Hooks

| Hook | Pi event | Behavior |
| --- | --- | --- |
| Block bare `cd` | `tool_call` (bash) | Blocks bare `cd /path` commands with no subshell or chaining. Use `(cd /path && command)` instead. |
| Block repo copy into scratch | `tool_call` (bash) | Refuses a recursive copy (`cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a local path, `tar` create-to-extract pipe) when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root. Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. |
| Pre-commit fmt + clippy | `tool_call` (bash) | Pi's own listener, not the `pre-commit-check` script: it parses the bash command to prove `git commit` targets the active project repo — a target built from shell expansion (`$(…)`, backticks, `cd "$dir"`) is refused rather than guessed — then runs `cargo fmt --check` and `cargo clippy` in async child processes so Pi stays responsive. Blocks on failure. No biome lane and no deference to an armed git pre-commit hook (KEN-554 tracks aligning it with the script). Skips commits targeting other repos and only fires when `.rs` files are staged or modified; if the bash command contains `git add`, untracked `.rs` files are treated conservatively as possibly staged by that command. |
| Post-edit clippy | `tool_result` (edit/write of `.rs`) | Runs workspace clippy after `.rs` edits and appends issues mentioning the edited file. Advisory only — doesn't undo the edit. |
| End-of-turn clippy | `turn_end` | If `.rs` files were touched during the turn, runs workspace clippy and surfaces errors via UI notification. Advisory only. |
| Session-start drift report | `session_start` | On a fresh start (startup, new, fork — not resume or reload) runs `kendex check --quiet` in the background and hands the agent the drift report: outdated items (`kendex refresh`), items removed upstream (`kendex remove <name>`, `-g` in a global section), unreachable sources, and — alongside drift — items available in the source but not installed (`kendex add --<kind> <name>`, pending your approval). Silent when the install is current; one line when no `kendex` binary is on `PATH`, the session directory is unreadable, or the check fails unexpectedly. Never blocks startup. Informational only — never installs or removes anything and never touches the project's git; the check never waits on the network (its only writes are kendex's own cache bookkeeping under `~/.kendex/cache`), and a source cache there older than its TTL is refreshed by a detached background process nobody waits on. |

`block-unsafe-rm` has no Pi port; it declares `harnesses:` without `pi`, so kendex reports Pi as `unsupported` for it rather than claiming enforcement that does not exist.

These implement the same safety goals as their matching bash hooks in `kendex/hooks/`, with Pi-specific mechanics where the in-process event loop needs different handling. The pre-commit listener differs in contract, not only mechanics: the bash `pre-commit-check` defers to the repository's own git pre-commit hook, while this listener still parses the command to prove the commit targets the active project repo (so unrelated fixture commits do not freeze the session) and runs its cargo checks in async child processes.

## Install

```bash
kendex add --pi-extension pi-hooks
```

Or as part of `kendex add --all`. Refresh with `kendex refresh`.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-hooks):

```bash
pi install npm:@vanillagreen/pi-hooks
```

## Settings

Open `/extensions:settings`; settings appear under the **Hooks** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, kendex Pi extensions read user/global settings only.

| Setting | What it does |
| --- | --- |
| Enable hooks | Master toggle. Disable to make the extension inert without uninstalling. |
| Block bare cd | Toggle the bare-cd block hook. |
| Block repo copy into scratch | Toggle the recursive-copy-into-scratch block. |
| Pre-commit fmt + clippy | Toggle the pre-commit hook. |
| Post-edit clippy | Toggle the post-edit advisory hook. |
| End-of-turn clippy | Toggle the end-of-turn advisory hook. |
| Session-start drift report | Toggle the session-start `kendex check` report. |
| Include available-but-not-installed items | Include not-yet-installed suggestions in the drift report; off passes `--no-available`. |
| Drift check timeout | Max ms the session-start `kendex check` may run before it is abandoned. |
| Clippy timeout | Max ms per clippy invocation. Advisory post-edit/end-of-turn clippy timeouts are abandoned so work can continue; blocking pre-commit fmt/clippy timeouts block the commit with a timeout reason. Pre-commit checks run asynchronously, so long checks may delay the commit gate without freezing the Pi TUI or bridge. |
