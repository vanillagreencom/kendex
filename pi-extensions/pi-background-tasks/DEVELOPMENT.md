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
- `notifyMode` — `always` (default), `transition`, `first-match-only`
- `dedupeKey` — coalesce matching wakes into one transition hash bucket
- `timeoutSeconds` — `0` disables
- `title`

`notifyMode: "transition"` wakes only when the new output tail hash changes — polling loops can print state each pass without waking the agent on identical snapshots. `notifyMode: "first-match-only"` wakes once for `notifyPattern` then suppresses later output wakes.

## Wake-event schema

Every exit and output wake carries `eventAt`, `deliveredAt`, `taskStatusAtEmit`, and a per-task monotonic `sequence` in the task snapshot. Output wakes scheduled before `stop` or `clear` are marked voided; if a queued callback still runs, the extension suppresses the send and writes a structured `voided-wake-fired` diagnostic to stderr so stale Pi-core delivery can be distinguished from an extension bug.

`clearTaskTimers` records a `cleared-on-task-exit` diagnostic for any pending output wakes it cancels.

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

## Tests

```
cd pi-extensions/pi-background-tasks && bun test
```

Coverage: lifecycle (normal/abnormal exit, partial output), wake-events (metadata, voided, dedupe, transition, first-match-only), activity broker mapping, orphan watcher (alive PID, mid-poll PID-reuse, comm drift, pre-1.2.2 fallback), persistence round-trip.
