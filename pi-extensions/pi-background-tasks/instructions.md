## pi-background-tasks — `bg_task` and `bg_status`

`bg_task` runs shell commands without blocking the conversation; `bg_status` inspects/stops them. Use these instead of `nohup`, `&`, `disown`, or foreground polling loops.

Use `bg_task action: "spawn"` for long-running processes that should outlive the turn: dev servers, watchers, log tails, build daemons, agent panes — anything you'd otherwise background with `&`. Foreground monitor loops (`while true; do …; sleep N; done`) auto-divert into a background task; continue the turn and inspect later, do not wait on the foreground bash.

`bg_status` actions: `list`, `log` (by pid/id), `stop` (SIGTERM to process group). `bg_task` adds `clear` to drop finished entries.

Spawn parameters worth knowing:
- `notifyOnExit` (default true) wakes you when the task exits.
- `notifyOnOutput` + `notifyPattern` wake on substring or `/regex/flags` matches in new output.
- `notifyMode` controls output wake frequency: `always` (default) wakes on each output update, `transition` wakes only when the new output tail hash changes, and `first-match-only` wakes once for `notifyPattern` then suppresses later output wakes.
- `dedupeKey` lets multiple matching output wakes share one transition hash bucket, useful for pollers that print the same state line repeatedly.
- `timeoutSeconds` defaults to 0 (disabled); set only when you actually want a timeout.

Rules:
- Never spawn a task and then wait on its output in foreground — that defeats the point.
- Stop tasks you started for a turn-scoped purpose before finishing the turn.
- Prefer `notifyMode: "transition"` over hand-rolled `prev=...; if changed; echo ...` poller guards when you only need wakes for state changes.

Durability (vstack#15):
- `notifyOnExit` is durable. If a task hits a terminal state without emitting its exit wake (Pi session restart, mid-session reload that coerced `running → stopped`, or kill -9 / OOM with a dead child), the next `session_start` replays the missed `exit` event so the agent never silently stalls on a finished task.
- Replay is gated by a persisted `exitNotified` flag (per task) and the snapshot's `sessionId`, so it does not double-fire and never leaks across sessions.
- Wake events carry persisted diagnostics: `eventAt`, `deliveredAt`, `taskStatusAtEmit`, and per-task `sequence`. Output wakes queued before stop/clear are marked voided; if one still fires, the extension logs a structured `voided-wake-fired` diagnostic.
- If the recorded child pid is still alive at restore time AND its process start time matches the value captured at spawn, the task is rehydrated as `running` (not stopped) and no fake exit is fired — use `bg_task log <id>` to inspect; the child is an orphaned process group that the spawning Pi can no longer signal directly. The kernel comm name is captured for diagnostics but NOT part of identity equality (so `bash -c "exec ..."` workloads do not get false-finalized after the exec). A background liveness watcher (default 30s poll) keeps watching that pid; when it disappears OR the kernel recycles the pid for an unrelated process (start-time mismatch), the canonical exit event fires so the agent still gets a turn.
