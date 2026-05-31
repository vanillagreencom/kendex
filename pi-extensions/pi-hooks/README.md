# @vanillagreen/pi-hooks

![pi-hooks settings panel](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-hooks/assets/hooks-settings.png)

First-class Pi port of the vstack safety hooks. Each hook is independently toggleable.

## Hooks

| Hook | Pi event | Behavior |
| --- | --- | --- |
| Block bare `cd` | `tool_call` (bash) | Blocks bare `cd /path` commands with no subshell or chaining. Use `(cd /path && command)` instead. |
| Pre-commit fmt + clippy | `tool_call` (bash) | When `git commit` targets the active project repo, runs `cargo fmt --check` then `cargo clippy` in async child processes so Pi stays responsive. Blocks on failure. Skips commits targeting other repos and only fires when `.rs` files are staged or modified. |
| Post-edit clippy | `tool_result` (edit/write of `.rs`) | Runs workspace clippy after `.rs` edits and appends issues mentioning the edited file. Advisory only — doesn't undo the edit. |
| End-of-turn clippy | `turn_end` | If `.rs` files were touched during the turn, runs workspace clippy and surfaces errors via UI notification. Advisory only. |

These mirror the bash hooks in `vstack/hooks/`. Any change to a hook script must land alongside the matching change in `pi-hooks` — see [AGENTS.md](../../AGENTS.md).

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

| Setting | What it does |
| --- | --- |
| Enable hooks | Master toggle. Disable to make the extension inert without uninstalling. |
| Block bare cd | Toggle the bare-cd block hook. |
| Pre-commit fmt + clippy | Toggle the pre-commit hook. |
| Post-edit clippy | Toggle the post-edit advisory hook. |
| End-of-turn clippy | Toggle the end-of-turn advisory hook. |
| Clippy timeout | Max ms per clippy invocation before the check is abandoned. Pre-commit checks run asynchronously, so long checks may delay the commit gate without freezing the Pi TUI or bridge. |
