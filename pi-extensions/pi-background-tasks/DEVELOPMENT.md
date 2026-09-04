# pi-background-tasks development

For maintainers. What it does for a consumer is [README.md](README.md); the agent-facing contract (`bg_task` parameters, notify modes, durability promises) is `instructions.md`, and the mechanics live as comments on the modules named below. This file holds the invariants that span them.

## Invariants

- A wake never depends on `pi-output-policy`. Wakes go out through `pi.sendMessage`, which that policy does not see, so every byte a wake adds to the transcript is bounded here: one inline tail capped by `outputAlertMaxChars`, a task manifest whose long fields are cut at `WAKE_MANIFEST_FIELD_MAX_CHARS`, a headline command preview cut at `WAKE_CONTENT_COMMAND_MAX_CHARS`, and a per-task output-wake budget after which one exhaustion notice is sent and further output wakes are dropped. `extensions/wake-events.ts::compactBackgroundTaskSnapshot`, `shouldEmitOutputWake`, `sendOutputWakeBudgetExhaustedNotice`. The same compact manifest is what `bg_task` and `bg_status` return in `details`, so a log-polling loop cannot grow the transcript through tool results either.
- Exit wakes are durable and fire exactly once. A task's snapshot carries `exitNotified`; a terminal task that never fired its exit wake is replayed on the next `session_start`. Exit wakes ignore the output-wake budget. `extensions/lifecycle.ts::finalizeTaskLifecycle` is the one place a task reaches a terminal state and emits that wake; every path (normal exit, timeout, stop, orphan death, restore) routes through it.
- The orphan watcher observes and never signals. A task whose child outlived Pi rehydrates as `running` and `extensions/orphan-watcher.ts` polls an identity probe (pid plus process start time; the kernel comm name is recorded but is not part of identity, because `exec` rotates it) until the process is gone or the pid was reused, then finalizes through the lifecycle. Adding a `kill` there resurrects a failure where a snapshot flicker terminates a live workload.
- Resource controls change nothing when off. With `resourceControlEnabled=false` the spawn is `getShellConfig` plus the command as one argument in a detached process group; `extensions/resource-control.ts::planResourceControlledSpawn` wraps it only when enabled, and a `systemd-run` task persists its unit name so stop, timeout and shutdown stop the unit rather than the wrapper. A failed unit stop leaves the task running rather than reporting it stopped.
- Session-state writes are bounded. `extensions/persistence.ts::createPersistence` is the only writer of the `kendex-background-tasks:state` entry: identical task lists are deduplicated by fingerprint, and a payload over `BG_TASKS_SNAPSHOT_MAX_BYTES` degrades to a manifest while the sidecar at `sidecarStatePath` stays canonical and is read first on restore. `extensions/tool-result-details.ts::bgToolResultTasks` bounds `details.tasks` the same way, and `restoreSnapshots` treats a manifest as a barrier so an older full snapshot cannot regress restored state.
- Broker publication is best-effort and outside control flow. `extensions/activity.ts::publishBackgroundTaskActivity` and `publishBackgroundTaskStarted` publish `bg_task.*` events to `pi-session-bridge`'s broker when present, catch every publisher error, and are never awaited by task control.
- Diagnostics never touch the terminal. `extensions/diagnostics.ts::logBackgroundDiagnostic` writes to a log file only when `PI_BG_TASK_DEBUG`, `PI_BG_TASK_DIAGNOSTICS` or `PI_BG_TASK_DIAGNOSTIC_LOG` is set; stdout and stderr would corrupt the TUI widgets.

## Mechanics worth knowing

- Auto-backgrounding covers the agent's `bash` tool, interactive `!` commands, and bash issued over RPC; an RPC caller gets the acknowledgement text in place of the output. The built-in patterns and the `sleep`-loop heuristic are `extensions/auto-background.ts::autoBackgroundDecision`; user patterns are `/regex/flags` or a case-insensitive plain regex per line.
- `notifyMode` unset resolves to `first-match-only` when `notifyPattern` is set and to `transition` otherwise (`extensions/wake-events.ts::resolveNotifyMode`); `transition` wakes only when the tail hash changes, and `dedupeKey` shares one hash bucket across tasks.
- An output wake scheduled before a `stop` or `clear` is voided; a queued callback that still fires is suppressed and logged as a `voided-wake-fired` diagnostic, which separates stale Pi-core delivery from an extension bug.
- The `f5` shortcut always opens the dashboard alongside the configured `dashboardShortcut`; shortcuts register at load, so a changed key needs a restart.

## Tests

```bash
bun test ./tests ./extensions/__tests__
```

Lifecycle, wake budgets, orphan identity (including a live probe of exec drift), resource-control planning and stop semantics, bounded snapshots and tool-result details each have a suite under `tests/`. A change to a bound above ships with the control that overruns it.
