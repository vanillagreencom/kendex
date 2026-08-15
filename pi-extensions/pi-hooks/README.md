# @vanillagreen/pi-hooks

![pi-hooks settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-hooks/assets/hooks-settings.png)

First-class Pi port of the vstack safety hooks. Each hook is independently toggleable.

## Hooks

| Hook | Pi event | Behavior |
| --- | --- | --- |
| Block bare `cd` | `tool_call` (bash) | Blocks bare `cd /path` commands with no subshell or chaining. Use `(cd /path && command)` instead. |
| Block repo copy into scratch | `tool_call` (bash) | Refuses a recursive copy (`cp -r`/`-R`/`-a`, recursive or archive `rsync`, `git clone` of a local path, `tar` create-to-extract pipe) when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root. Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. |
| Pre-commit fmt + clippy | `tool_call` (bash) | When `git commit` targets the active project repo, runs `cargo fmt --check` then `cargo clippy` in async child processes so Pi stays responsive. Blocks on failure. Skips commits targeting other repos and only fires when `.rs` files are staged or modified; if the bash command contains `git add`, untracked `.rs` files are treated conservatively as possibly staged by that command. |
| Post-edit clippy | `tool_result` (edit/write of `.rs`) | Runs workspace clippy after `.rs` edits and appends issues mentioning the edited file. Advisory only — doesn't undo the edit. |
| End-of-turn clippy | `turn_end` | If `.rs` files were touched during the turn, runs workspace clippy and surfaces errors via UI notification. Advisory only. |
| Session-start drift report | `session_start` | Runs `vstack check --quiet` and hands the agent the drift report: outdated items (`vstack refresh`), items removed upstream (`vstack remove <name>`), and items available in the source but not installed (`vstack add --<kind> <name>`, pending your approval). Silent when the install is current, when no `vstack` binary is on `PATH`, and on extension reload. Informational only — never installs, removes, or touches git. |

These implement the same safety goals as the bash hooks in `vstack/hooks/`, with Pi-specific mechanics where the in-process event loop needs different handling: the pre-commit hook runs cargo checks via async child processes and first proves the commit targets the active project repo, so unrelated fixture commits do not freeze the session.

## Install

```bash
vstack add --pi-extension pi-hooks
```

Or as part of `vstack add --all`. Refresh with `vstack refresh`.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-hooks):

```bash
pi install npm:@vanillagreen/pi-hooks
```

## Settings

Open `/extensions:settings`; settings appear under the **Hooks** tab.

Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted; before trust, vstack Pi extensions read user/global settings only.

| Setting | What it does |
| --- | --- |
| Enable hooks | Master toggle. Disable to make the extension inert without uninstalling. |
| Block bare cd | Toggle the bare-cd block hook. |
| Block repo copy into scratch | Toggle the recursive-copy-into-scratch block. |
| Pre-commit fmt + clippy | Toggle the pre-commit hook. |
| Post-edit clippy | Toggle the post-edit advisory hook. |
| End-of-turn clippy | Toggle the end-of-turn advisory hook. |
| Session-start drift report | Toggle the session-start `vstack check` report. |
| Include available-but-not-installed items | Include not-yet-installed suggestions in the drift report; off passes `--no-available`. |
| Drift check timeout | Max ms the session-start `vstack check` may run before it is abandoned. |
| Clippy timeout | Max ms per clippy invocation. Advisory post-edit/end-of-turn clippy timeouts are abandoned so work can continue; blocking pre-commit fmt/clippy timeouts block the commit with a timeout reason. Pre-commit checks run asynchronously, so long checks may delay the commit gate without freezing the Pi TUI or bridge. |
