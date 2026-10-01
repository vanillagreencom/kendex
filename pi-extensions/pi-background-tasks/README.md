# @vanillagreen/pi-background-tasks

A Pi extension for shell commands that run while the conversation continues. It supports builds, development servers and log monitors.

![Spawning background tasks](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-background-tasks/assets/spawn-tasks.png) ![Inline mini-dashboard](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-background-tasks/assets/inline-dashboard.png)

## Install

- npm: `pi install npm:@vanillagreen/pi-background-tasks`.
- kendex: add the declaration below to the project's `kendex.toml`, or to `~/.config/kendex/kendex.toml` for user scope. Run `kendex update-pi`.

```toml
[pi-extensions."@vanillagreen/pi-background-tasks"]
source = "kendex"
```

Restart Pi after installation. Use `kendex update-pi --check` to preview the installation.

## Features

- Start, inspect and stop background commands.
- Move configured blocking commands into background tasks.
- Notify the agent when a task exits or produces selected output.
- Read recent output and task history in the dashboard. Open the task's Log file for full output.
- Optionally reduce task CPU and disk priority.

## How it works

The agent starts a command with the background task tool. The extension runs the command separately and saves its output to a log. It shows task status beside the editor. When the command exits or matches a notification rule, it sends the agent a message with recent output and the log path.

## Memory and disk use

- The dashboard reads a log tail asynchronously and keeps it for each task until the log changes. `logTailMaxChars` limits the decoded tail by JavaScript string length, with a default of 10,000. The disk read is bounded to three bytes per character plus one byte. Command layouts stay cached until the command, pane width or theme changes; closing the dashboard releases them. Task tails stay cached while finished history retains the task. Clear, finished-task eviction or session replacement makes them eligible for release; session shutdown clears the reader.
- A notification regex has a 25 ms execution deadline. A pattern that exceeds it is disabled for that task. The agent receives one bounded failure notice, including in headless sessions. Exit notifications still work.
- A finished task's output is read from its log file; the process handle and the in-memory output are released once the task has exited and its last log write has finished. A task whose last log write failed or stalled keeps its in-memory output instead.
- Exit notifications, the dashboard and log tools share a limit of four disk reads at once. Tasks waiting for exit delivery stay outside the 50-task finished-history limit. After delivery or suppression settles, the oldest excess finished task is removed with its log. `clear` also deletes the logs of the tasks it removes. A forked session removes the tasks it copied from the original session but keeps their logs, which the original session still reads.
- Logs live in one directory per session in the `lanes/` folder of the task directory (`taskDir`, default the system temporary directory's `kendex-pi-bg`). A session's directory is deleted once its working directory is gone (a merged worktree), and any log older than 5 days is deleted. Pi applies both rules when a session starts, to `lanes/` only, and only to directories the package made there.
- A log written before 2.1.0 stays directly in the task directory. The prune, `clear` and the 50-task bound do not delete it; a task restored with such a log is removed from the list without its log.

## Settings

The settings editor writes project values to `.pi/settings.json`. The default user file is `~/.pi/agent/settings.json`. `PI_CODING_AGENT_DIR` changes the user directory. Package values are stored under `kendex.extensionManager.config["@vanillagreen/pi-background-tasks"]`.

Open `/extensions:settings`; settings appear under the **Background Tasks** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: package toggle; `glyphStyle` picks Unicode or ASCII symbols, and `pi-tool-renderer`'s global override wins when set.
- Auto-backgrounding: `autoBackgroundBash`, `autoBackgroundPatterns`, `forcedBackgroundWindowSeconds`, `forcedBackgroundNotifyOnOutput`.
- Execution: `defaultTimeoutSeconds`, `forceKillGraceMs`, and the `resourceControl*` group (`resourceControlEnabled` turns it on, `resourceControlMode` picks the mechanism, the rest set weights, niceness and where controls apply).
- Wakes and output: `outputSettleMs`, `outputAlertMaxChars`, `outputWakeBudgetMaxWakes`, `outputWakeBudgetMaxBytes`, `outputBufferMaxChars`, `logTailMaxChars`.
- UI: `showWidget`, `widgetPlacement`, `widgetDefaultMode`, `widgetFinishedRetentionSeconds`, `toolRenderMode`, `toolExpandedLogLines`, `dashboardOutputMaxLines`.
- Shortcuts: `backgroundBashShortcut`, `widgetToggleShortcut`, `dashboardShortcut`; `none` disables one, and a change takes effect on restart.
- Storage: `taskDir`; the `PI_BG_TASK_DIR` environment variable overrides it.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md). The package is kendex's own, based on the MIT-licensed `@ifi/pi-background-tasks`; see `THIRD_PARTY_NOTICES.md`.
