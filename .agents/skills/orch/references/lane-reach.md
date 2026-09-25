# Lane reach

Load from [oversee.md § Talking to a lane](../workflows/oversee.md#talking-to-a-lane) when a wake is refused or a lane shows a harness dialog. Reaching a lane at the pane is the Pane paste paragraph there.

## Wake refusals

The rows are the wake's refusal reasons, plus the different silence `lanes state` reports under the same word. A Pi wake goes to the live session through pi-bridge and is never put to the judge, so no row refuses one.

| Reason | What the judge read | How the lane is reached |
|--------|---------------------|-------------------------|
| `working` | A turn in flight, or a pane that cannot be read as anything else: a frame scrolled up its own history reads `working` while it stays there, and so does a lane streaming its last message. | Send, and a lane still taking tool calls reads it at the next one, and a turn in flight reads it at its end. For a lane already idle, scroll the pane back to the bottom and read the state again. |
| `asking` | A dialog is waiting on an answer. | Answer it by the harness column of [§ Per harness](#per-harness), not by mail. |
| `walled` | The account is spent and the turn is over. | Reads no mail. Reach it at the pane, or relaunch after the reset its banner names. |
| `exited` | Nothing is running under the pane. | Reads no mail. Relaunch it. |
| `unjudged` from a wake | The process read gave no positive idle: a live Codex process, a harness process another user owns, a host with no `/proc` carrying a process named for that harness, or a limit-banner scan that failed. | The turn may already have ended, so the lane reads nothing until its next turn starts. |
| `unjudged` from `lanes state` | No process is read at all. The pane settled nothing: no pane on this server carries the name, because the window closed or two windows share it, or the pane's screen carries no marker. | A closed window is relaunched under [oversee.md § Recovery relaunch](../workflows/oversee.md#recovery-relaunch). For a shared name, find the lane's own window before touching either: `tmux list-panes -a -F '#{window_name} #{pane_id} #{pane_current_path}'` prints both with their working directories, and the lane's is the one sitting in its worktree. Rename the other, with `tmux rename-window`. Renaming the lane's own leaves the name on no pane, which the next watch pass reads as `window-gone` and relaunches the item beside its live session, so make the check first. A markerless screen is read at the pane. |

## Per harness

What stays per harness is launching, resuming and the harness's own dialogs; the Pi commands are the pi-session-bridge CLI, documented in its [README](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-session-bridge/README.md) and `pi-bridge --help`, and every Pi call selects the lane by `--name` or `--cwd`.

| Harness | Launch | Read state | Answer a harness dialog |
|---------|--------|------------|-------------------------|
| Claude Code | `open-terminal` into a tmux pane ([oversee.md § 3](../workflows/oversee.md#3-launch)). In a tmux pane, a first launch in a folder the wrapper has not trusted shows a trust prompt with "No, exit" selected: `Down`, `Enter`, then relaunch. | Follow [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads). | Move the dialog with the arrow keys and press `Enter` in the lane's pane; the recorded choice line confirms it. The rm-safety prompt ("Dangerous rm operation on possibly-empty variable path") fires even under bypass: read the command, and `Enter` on Yes when it stays inside the lane's own worktree. |
| Codex | `open-terminal` into a tmux pane ([oversee.md § 3](../workflows/oversee.md#3-launch)). | Follow [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads). | Type the number the dialog shows into the lane's pane, at the idle prompt. |
| Pi | `open-terminal` into a tmux pane ([oversee.md § 3](../workflows/oversee.md#3-launch)). | Follow [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads). Use `pi-bridge state` only when the event carries no pane payload; never use `history` or `stream`. `pi-bridge questions` lists a pending dialog with its request id. | `pi-bridge answer` on the selected lane with that request id and the option label, never the pane: a typed number lands on the default option. |
| App or other | The session or thread launcher the harness or an app-specific skill exposes ([oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface)). | Use its API or tooling to read only the bounded state that explains the event. | The API or tooling that surface exposes; a pane at its idle prompt only when nothing else exists. |
