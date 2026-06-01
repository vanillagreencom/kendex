# pi-background-tasks — development notes

Implementation surface for contributors and AI callers. End-user setup, commands, and settings live in [`README.md`](./README.md).

## `bg_task` tool

```json
// spawn
{ "action": "spawn", "command": "sleep 20; echo done", "notifyOnExit": true }
```

Actions: `spawn`, `list`, `log`, `stop`, `clear`.

Spawn options:

- `notifyOnExit` (default `true`)
- `notifyOnOutput` (default `false`)
- `notifyPattern` — substring or `/regex/flags`
- `notifyMode` — `always`, `transition`, `first-match-only`. When omitted, `resolveNotifyMode()` picks `first-match-only` if `notifyPattern` is set, `transition` otherwise (vstack#210). Pass `"always"` explicitly to opt into every-output wakes.
- `dedupeKey` — coalesce matching wakes into one transition hash bucket
- `timeoutSeconds` — `0` disables
- `title`

`notifyMode: "transition"` wakes only when the new output tail hash changes — polling loops can print state each pass without waking the agent on identical snapshots. `notifyMode: "first-match-only"` wakes once for `notifyPattern` then suppresses later output wakes.

## Resource controls (vstack#300)

Resource controls are opt-in through extension-manager settings. `resourceControlEnabled=false` preserves the old spawn path exactly: `getShellConfig()` plus the original command as a single shell argument, detached process group on POSIX, same stdout/stderr pipes, same timeout/stop/orphan handling.

When enabled, `planResourceControlledSpawn()` chooses a wrapper per task:

- `systemd-run --user --scope --wait --collect` on Linux when user systemd scopes are usable. The task snapshot stores `resourceControl.unitName`, and stop/timeout/session-shutdown paths call `systemctl --user stop|kill <unit>` before falling back to the tracked wrapper process group. Restore/orphan polling checks the unit first so a live transient scope is not falsely finalized because the wrapper pid changed.
- `nice`/`ionice` fallback when configured or when `auto` cannot use systemd. This still execs the configured shell with the original command as one argv element, so shell metacharacters, heredocs, and quoting semantics stay owned by the user's shell.
- No-op fallback with at most one warning/diagnostic when helpers are unavailable and `resourceControlWarnOnFallback=true`.

Controls can be applied independently to explicit `bg_task`/`/bg:run` spawns and auto-backgrounded bash via `resourceControlApplyToBgTask` and `resourceControlApplyToAutoBackground`.

## Wake-event schema

Every exit and output wake carries `eventAt`, `deliveredAt`, `taskStatusAtEmit`, and a per-task monotonic `sequence` in the task snapshot. Output wakes scheduled before `stop` or `clear` are marked voided; if a queued callback still runs, the extension suppresses the send and writes a structured `voided-wake-fired` diagnostic via `logBackgroundDiagnostic()` so stale Pi-core delivery can be distinguished from an extension bug. Diagnostics are env-gated (`PI_BG_TASK_DEBUG`, `PI_BG_TASK_DIAGNOSTICS`, or `PI_BG_TASK_DIAGNOSTIC_LOG=/path`) and write to a log file (default `$TMPDIR/vstack-pi-bg/diagnostics.log`); they never go to stdout/stderr or the active TUI.

`clearTaskTimers` records a `cleared-on-task-exit` diagnostic for any pending output wakes it cancels.

### Transcript-budget-safe wake payload (vstack#210)

Wake messages reach the transcript through `pi.sendMessage(...)` and skip `pi-output-policy`'s truncation, so payload size is governed entirely here. Output wakes and budget notices ship as `{ deliverAs: "steer", triggerTurn: true }`; exit wakes ship as `{ deliverAs: "followUp", triggerTurn: true }` so the agent's next turn sees the terminal status in the same delivery slot as a tool result.

- `details` carries a single bounded `outputTail` (default cap `outputAlertMaxChars = 2000`) plus a compact task manifest (`compactBackgroundTaskSnapshot`) which truncates `command`, `title`, `cwd`, `notifyPattern`, `dedupeKey`, and `logFile` to `WAKE_MANIFEST_FIELD_MAX_CHARS` (192) and drops internal-only arrays (`wakeEvents`, `pendingWakes`, `voidedWakeSequences`, `lastOutputDedupeByKey`, `procIdent`). The wake's `content` headline carries a similarly bounded command preview (`WAKE_CONTENT_COMMAND_MAX_CHARS`, 160) so a 100KB heredoc command cannot leak into the transcript via the wake summary. Worst-case wake payload (every long field at max) stays under 4 KB. The same compact manifest is also used by `bg_task` / `bg_status` `spawn`, `log`, and `stop` tool-result details, so a chatty `bg_task log` cycle cannot grow the transcript through `details.task`.
- The legacy `newOutputTail` field was removed in vstack#210; for output wakes the wake-time `outputTail` IS the new unseen excerpt, and for exit wakes it is the trailing portion of full output.
- A `details.outputTailTruncated` boolean tells the renderer whether the inline tail was clipped so it can point at `task.logFile`.
- A per-task budget guard (`outputWakeBudgetMaxWakes`, default 20; `outputWakeBudgetMaxBytes`, default 20000) caps cumulative output-wake noise. When the guard trips, `shouldEmitOutputWake` returns the `wake-budget-exhausted` drop reason, `sendOutputWakeBudgetExhaustedNotice` emits one concise notice keyed by `customType` = `BG_MESSAGE_TYPE` with `details.eventType = "output-budget-exhausted"`, and further output wakes are suppressed for the lifetime of the task. The budget persists across session restart via the snapshot's `outputWakeBudget` field (sanitized through the shared `normalizeOutputWakeBudget()` helper so snapshot / restore / live-state paths stay in sync). Exit wakes ignore the budget.
- Unset `notifyMode` resolves to `first-match-only` when `notifyPattern` is set, otherwise `transition`. Pass `notifyMode: "always"` to opt back into every-output wakes.

## Activity broker publication

When `pi-session-bridge` has installed `globalThis[Symbol.for("vstack.pi.activity")]`, task lifecycle code publishes best-effort broker events in addition to existing wake messages. `start` maps to `bg_task.started`; output match wake points map to `bg_task.output_matched`; terminal statuses map to `bg_task.completed`, `bg_task.failed`, `bg_task.timed_out`, or `bg_task.stopped`. Payload refs use `bg_task_id`; details include truncated command, output byte count, exit code, matched pattern/output tail when present, status, and wake `sequence`.

Broker publication must never affect task control flow. Keep it isolated behind `publishBackgroundTaskActivity` / `publishBackgroundTaskStarted`, catch publisher errors, and preserve exit wake durability independently of broker success.

## Durable exit + orphan watcher

Exit wakeups survive session restart. Each task carries an `exitNotified` flag in its persisted snapshot; if a task hits a terminal state without ever firing its `notifyOnExit` event (session shutdown, mid-session restore that coerced `running` → `stopped`), the next `session_start` replays the missed `exit` wakeup so the agent never silently stalls on a finished background task.

Orphan-running tasks (Pi died while the detached child kept running) are detected on restore via an identity probe combining `kill -0 <pid>` with the process start time (`/proc/<pid>/stat` field 22 on Linux, `ps -o lstart=` elsewhere). The kernel comm name is captured at spawn and persisted alongside as a diagnostic but is NOT part of identity equality, because `bash -c "exec sleep N"`-style workloads rotate `/proc/<pid>/comm` from `bash` to `sleep` via `execve(2)` without changing the pid or start time.

Orphans rehydrate as `running` rather than synthetically `stopped`, and a periodic liveness watcher (default 30s) polls until the (pid + startToken) tuple disappears or stops matching, then finalizes the task and fires the canonical exit wake. This protects against both the kill -9 / OOM scenario (Pi gone, orphan still alive) and PID reuse: if the kernel hands the same PID to an unrelated process after the original orphan exits, the start-time mismatch is treated as `pid-reused` and the canonical exit wake fires anyway.

## Bounded session-state snapshots (vstack#177)

`createPersistence().persistSnapshots()` is the only writer of the `vstack-background-tasks:state` JSONL entry. It enforces two guards before calling `pi.appendEntry`:

1. **Fingerprint dedup.** A stable hash of `{ tasks }` (excluding the outer `updatedAt`) per Pi session id. Identical successive task lists short-circuit and never touch the session file, so a steady-state queue does not append one entry per lifecycle event.
2. **Size cap.** Default 64 KiB (`BG_TASKS_SNAPSHOT_MAX_BYTES`, override per `createPersistence` call via `maxEntryBytes` in tests). Oversized payloads — e.g. dozens of completed tasks with multi-KB heredoc `command` strings — are downgraded to a `version: 2, fullSnapshot: false` manifest carrying only `byteSize`, `fingerprint`, `counts.tasks`, and `updatedAt`. The full task list still lands in the sidecar at `sidecarStatePath(ctx)`; restore reads the sidecar first and `restoreSnapshots()` skips manifest entries (does not call `tasks.clear()` for them) so dashboard state survives `/resume`.

`persistSnapshots()` returns `{ appendEntry, sidecar, appendReason: "appended" | "unchanged" | "manifest" | "no-active-context" | "error" }` so callers/tests can distinguish a deliberate skip from a failure.

## Bounded tool-result details (vstack#187)

`bg_task list` and `bg_status list` also write their `details.tasks` into Pi's tool-result JSONL path, separate from custom session entries. `bgToolResultTasks()` keeps small lists as full snapshots for legacy restore fallback, but once the list exceeds the task-count threshold or 64 KiB serialized size it emits a `version: 2, fullSnapshot: false` manifest with counts and a small id sample. `restoreSnapshots()` treats that manifest as a sidecar barrier, re-applying sidecar state if it was loaded so an older full tool-result snapshot earlier in the branch cannot regress resumed state.

## Tests

```
cd pi-extensions/pi-background-tasks && bun test
```

Coverage: lifecycle (normal/abnormal exit, partial output), wake-events (metadata, voided, dedupe, transition, first-match-only), activity broker mapping, orphan watcher (alive PID, mid-poll PID-reuse, comm drift, pre-1.2.2 fallback), persistence round-trip.
