# @vanillagreen/pi-background-tasks

Runs shell commands in the background of a Pi session without blocking the conversation, and wakes the agent when they finish or print something that matters. For anyone whose agent runs dev servers, watchers, log tails or long builds.

![Spawning background tasks](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-background-tasks/assets/spawn-tasks.png) ![Inline mini-dashboard](https://raw.githubusercontent.com/vanillagreencom/kendex/main/pi-extensions/pi-background-tasks/assets/inline-dashboard.png)

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-background-tasks"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-background-tasks):

```bash
pi install npm:@vanillagreen/pi-background-tasks
```

Restart Pi after installation.

## What it does

- Gives the agent a `bg_task` tool that spawns, lists, tails, stops and clears background commands, and a read-only `bg_status` tool for inspecting and stopping them.
- Diverts blocking monitors (`watch`, `tail -f`, `journalctl -f`, polling loops with `sleep`) into a background task before they freeze the turn; `/bg:next` or a shortcut forces the next bash command into the background.
- Wakes the agent on exit, and optionally on new output or on output matching a pattern, with a bounded inline tail and the path of the full log.
- Keeps the full log on disk for every task, and restores task history across reloads and resumes.
- Replays a missed exit wake after a restart, and keeps watching a task that outlived Pi until it really ends.
- Shows a mini-dashboard beside the editor and a full `/bg` dashboard with logs, details and controls.
- Optionally runs tasks at lower CPU and I/O priority through `systemd-run` or `nice` and `ionice`.
- Publishes task lifecycle events to `pi-session-bridge` clients when that package is loaded, without adding chat messages.

`/bg` opens the dashboard; `/bg:run`, `/bg:list`, `/bg:stop`, `/bg:clear` and `/bg:next` do one thing each, and `/bg log <id>` and `/bg watch <id>` take a task id or pid with autocomplete. Tasks inherit Pi's environment and working directory and are stopped when the session shuts down.

## How it works

A spawned command runs in its own process group with stdout and stderr captured to a log file. The extension keeps a bounded in-memory tail per task, debounces output, and delivers wakes to the agent as custom messages that steer the current turn or follow it up. Task snapshots persist in the session file and in a sidecar, so a resumed session sees the same tasks. The agent-facing rules ship in `instructions.md`, appended to the system prompt at install.

## Customise

Open `/extensions:settings`; settings appear under the **Background Tasks** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle; `glyphStyle` picks Unicode or ASCII chrome, and `pi-tool-renderer`'s global override wins when set.
- Auto-backgrounding: `autoBackgroundBash`, `autoBackgroundPatterns`, `forcedBackgroundWindowSeconds`, `forcedBackgroundNotifyOnOutput`.
- Execution: `defaultTimeoutSeconds`, `forceKillGraceMs`, and the `resourceControl*` group (`resourceControlEnabled` turns it on, `resourceControlMode` picks the mechanism, the rest set weights, niceness and where controls apply).
- Wakes and output: `outputSettleMs`, `outputAlertMaxChars`, `outputWakeBudgetMaxWakes`, `outputWakeBudgetMaxBytes`, `outputBufferMaxChars`, `logTailMaxChars`.
- UI: `showWidget`, `widgetPlacement`, `widgetDefaultMode`, `widgetFinishedRetentionSeconds`, `toolRenderMode`, `toolExpandedLogLines`, `dashboardOutputMaxLines`.
- Shortcuts: `backgroundBashShortcut`, `widgetToggleShortcut`, `dashboardShortcut`; `none` disables one, and a change takes effect on restart.
- Storage: `taskDir`; the `PI_BG_TASK_DIR` environment variable overrides it.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md). The package is kendex's own, based on the MIT-licensed `@ifi/pi-background-tasks`; see `THIRD_PARTY_NOTICES.md`.
