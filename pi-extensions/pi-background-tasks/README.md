# pi-background-tasks

![Spawning background tasks](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/spawn-tasks.png)
![Task summary](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/task-summary.png)
![Inline mini-dashboard](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/inline-dashboard.png)
![Full dashboard](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/dashboard.png)

Run shell commands in the background without blocking the conversation.

## Highlights

- `bg_task` tool spawns, lists, tails, stops, and clears tracked tasks.
- `/bg` dashboard for browsing and controlling tasks interactively.
- `Alt+.` arms the next bash command to run in the background.
- Long-running monitors (`watch`, `tail -f`, `journalctl -f`, polling loops) are auto-backgrounded.
- Wakeups when a task exits, with optional wakeups on matching output.
- Inline mini-dashboard above the editor; full dashboard on `Alt+Shift+H` or `F5`.
- Inline mini-dashboard participates in vstack's stable stack order: Flightdeck → Tasks → Agents → BG tasks.
- Persistent log files keep full output even when tool output is truncated.
- Per-session sidecar state keeps `/bg` task history resumable for both tool-spawned and slash-command-spawned tasks.
- The `/bg` dashboard wraps multi-line commands and strips terminal control sequences from preview rows so task details stay inside the popup frame; focus the right pane to scroll details with `↑/↓` or `-/=`, and press `x` to expand/collapse a truncated command.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-background-tasks):

```bash
pi install npm:@vanillagreen/pi-background-tasks
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-background-tasks --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/bg` | Open the dashboard. |
| `/bg:next` | Arm the next bash command for backgrounding. |
| `/bg:run <command>` | Spawn a background shell task. |
| `/bg:list` | Show tracked tasks. |
| `/bg log <id\|pid>` | Show a task log tail. |
| `/bg watch <id\|pid>` | Open the dashboard focused on a task. |
| `/bg:stop <id\|pid>` | Terminate a running task. |
| `/bg:clear` | Remove finished tasks. |

Arguments support autocomplete, including task IDs.

## Tool

```json
{ "action": "spawn", "command": "sleep 20; echo done", "notifyOnExit": true }
```

Useful spawn options: `notifyOnExit` (default true), `notifyOnOutput`, `notifyPattern` (substring or `/regex/flags`), `notifyMode` (`always`, `transition`, `first-match-only`), `dedupeKey`, `timeoutSeconds`, `title`.

`notifyMode: "transition"` wakes only when the new output tail hash changes, so polling loops can print state each pass without waking the agent on identical snapshots. `notifyMode: "first-match-only"` wakes once for a matching `notifyPattern` and then suppresses later output wakes. `dedupeKey` lets related matching wakes share a transition hash bucket.

## Closes parts of #27

This release closes the pi-background-tasks portions of vstack issue #27: #7 output-wake suppression after stop on the output path, #9 wake metadata (`eventAt`, `deliveredAt`, `taskStatusAtEmit`, `sequence`), partial #8 extension-side voided-wake tracking, and #11 `notifyMode` / `dedupeKey` output coalescing.

## Auto-background

Bash commands matching obvious monitor patterns are intercepted before they start and run as a background task instead. The foreground bash tool returns a short acknowledgement with the task id, PID, and log path so the agent turn keeps moving.

Built-in matches: `watch ...`, `tail -f`, `journalctl -f`, Pi-bridge/tmux polling loops, and shell loops with `sleep` that monitor session state.

Use `Alt+.` or `/bg:next` to force the next bash command into the background even if it doesn't match the built-in patterns. The shortcut applies only to commands not yet started.

## Settings

All settings live in the extension manager under **Background Tasks**.

### Execution

| Setting | What it does |
| --- | --- |
| Enable background tasks | Master toggle for `bg_task`, auto-backgrounding, and the widget. |
| Default timeout | Spawn timeout. `0` disables. |
| Auto-background blocking bash monitors | Auto-divert long-running bash commands into `bg_task`. |
| Extra auto-background patterns | Newline-separated regexes for project-specific monitors. |
| Shortcut arming window | Seconds `Alt+.`/`/bg:next` stays armed. |
| Force-kill grace | Milliseconds between SIGTERM and SIGKILL. |

### Wakeups

| Setting | What it does |
| --- | --- |
| Shortcut output wakeups | Wake the agent on new output from shortcut-forced tasks. |
| Output settle delay | Debounce before output wakeups fire. |

### Output

| Setting | What it does |
| --- | --- |
| In-memory output buffer | Per-task in-memory cap. Logs always keep full output. |
| Wakeup output tail | Characters included in output/exit wakeup messages. |
| Dashboard/log tail | Characters shown in dashboard and log actions. |

### UI

| Setting | What it does |
| --- | --- |
| Show task widget | Compact background-task widget. |
| Widget placement | Above or below the editor. |
| Tool output style | `compact` one-liner or `stacked` rows with Ctrl+O details. |
| Expanded tool log lines | Maximum lines shown when expanding log output. |
| Dashboard output line cap | Maximum lines in the interactive dashboard viewport. |
| Mini-dashboard default mode | `compact`, `expanded`, or `hidden`. |
| Mini-dashboard finished retention | Seconds finished tasks stay visible in the inline widget. |
| Background next bash shortcut | Default `alt+.`. |
| Mini-dashboard toggle shortcut | Default `alt+h`. |
| Dashboard shortcut | Default `alt+shift+h` (F5 also works). |

### Storage

| Setting | What it does |
| --- | --- |
| Task log directory | Override log file location. `PI_BG_TASK_DIR` env var still wins. |

## Notes

Tasks are scoped to the current Pi runtime and stopped on session shutdown. Shells start in their own process group so `/bg:stop` and shutdown terminate children. Tasks inherit Pi's environment and working directory.

Exit wakeups are durable across session restarts. Each task carries an `exitNotified` flag in its persisted snapshot; if a task hits a terminal state without ever firing its `notifyOnExit` event (session shutdown, mid-session restore that coerced `running` → `stopped`), the next `session_start` replays the missed `exit` wakeup so the agent never silently stalls on a finished background task.

Every exit and output wake stores `eventAt`, `deliveredAt`, `taskStatusAtEmit`, and a per-task monotonic `sequence` in the task snapshot. Output wakes scheduled before `stop` or `clear` are marked voided; if a queued callback still runs, the extension suppresses the send and writes a structured `voided-wake-fired` diagnostic to stderr so stale Pi-core delivery can be distinguished from an extension bug.

Orphan-running tasks (Pi died while the detached child kept running) are detected on restore via an identity probe combining `kill -0 <pid>` with the process start time (`/proc/<pid>/stat` field 22 on Linux, `ps -o lstart=` elsewhere). The kernel comm name is captured at spawn and persisted alongside as a diagnostic but is NOT part of identity equality, because `bash -c "exec sleep N"`-style workloads rotate `/proc/<pid>/comm` from `bash` to `sleep` via `execve(2)` without changing the pid or start time. Orphans are rehydrated as `running` rather than synthetically stopped, and a periodic liveness watcher (default 30s) polls until the (pid + startToken) tuple disappears or stops matching, then finalizes the task and fires the canonical exit wake. This protects against both the kill -9 / OOM scenario (Pi gone, orphan still alive) and PID reuse: if the kernel hands the same PID to an unrelated process after the original orphan exits, the start-time mismatch is treated as `pid-reused` and the canonical exit wake fires anyway.

## Attribution

Locally owned by vstack, based on the MIT-licensed `@ifi/pi-background-tasks` from `ifiokjr/oh-pi`. See `THIRD_PARTY_NOTICES.md`.
