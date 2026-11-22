## pi-background-tasks — `bg_task` and `bg_status`

`bg_task` runs shell commands without blocking the conversation; `bg_status` inspects/stops them.

- Use these instead of `nohup`, `&`, `disown`, or foreground polling loops.
- Use `bg_task action: "spawn"` for long-running processes that should outlive the turn: dev servers, watchers, log tails, build daemons, agent panes — anything you'd otherwise background with `&`.
- Foreground monitor loops (`while true; do …; sleep N; done`) auto-divert into a background task.
  - Continue the turn and inspect later.
  - Do not wait on the foreground bash.

Resource controls are on by default: background tasks run at lower CPU and IO priority on Linux (`nice` and `ionice`), at lower CPU priority only on macOS (`nice`), and unchanged on Windows.

Rules:

- Never spawn a task and then wait on its output in foreground — that defeats the point.
- Stop tasks you started for a turn-scoped purpose before finishing the turn.
- Prefer `notifyMode: "transition"` over hand-rolled `prev=...; if changed; echo ...` poller guards when you only need wakes for state changes.
- Output wakes are transcript-budget-safe by default:
  - Each wake carries one inline tail capped at `outputAlertMaxChars` (default 2 KB).
  - A per-task wake budget (default 10 wakes / 20 KB cumulative) suppresses further wakes once exhausted.
  - When the budget trips you'll receive a single "wake budget exhausted; inspect log" notice with the log file path.
  - Then fetch the full log with `bg_task action: "log"` instead of expecting more inline updates.

Durability:

- `notifyOnExit` is durable: if a task hits a terminal state without emitting its exit wake (session restart, reload, kill -9 / OOM), the next session replays the missed `exit` event exactly once — the agent never silently stalls on a finished task.
- If the recorded child pid is still alive at restore time (same process start time), the task rehydrates as `running` and no fake exit is fired.
  - Use `bg_task log <id>` to inspect it.
  - A background liveness watcher keeps polling.
  - When the process disappears or the kernel recycles the pid, the canonical exit event fires so the agent still gets a turn.
