# pi-background-tasks

![Spawning background tasks](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/spawn-tasks.png)
![Task summary](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/task-summary.png)
![Inline mini-dashboard](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/inline-dashboard.png)
![Full dashboard](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-background-tasks/assets/dashboard.png)

Run shell commands in the background without blocking the conversation.

## Highlights

- `bg_task` tool spawns, lists, tails, stops, and clears tracked tasks.
- `/bg` dashboard for browsing and controlling tasks interactively.
- Arm-next-bash shortcut runs the next bash command in the background.
- Long-running monitors (`watch`, `tail -f`, `journalctl -f`, polling loops) are auto-backgrounded.
- Wakeups when a task exits, with optional wakeups on matching output.
- When `pi-session-bridge` is loaded, task start/output/terminal transitions also publish structured `bg_task.*` activity broker events without adding chat messages (`bg_task.started`, `bg_task.output_matched`, `bg_task.completed`, `bg_task.failed`, `bg_task.timed_out`, `bg_task.stopped`).
- Inline mini-dashboard above the editor; full dashboard popup for browsing details. Manual hide stays hidden across task output, exit, restore, and retention updates until toggled back in.
- Inline mini-dashboard participates in vstack's stable stack order: Flightdeck → Tasks → Agents → BG tasks.
- Persistent log files keep full output even when tool output is truncated.
- Per-session sidecar state keeps `/bg` task history resumable for both tool-spawned and slash-command-spawned tasks.
- The `/bg` dashboard wraps multi-line commands and strips terminal control sequences from preview rows so task details stay inside the popup frame; the popup documents its own keys in the footer.

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

## Auto-background

Bash commands matching obvious monitor patterns are intercepted before they start and run as a background task instead. The foreground bash tool returns a short acknowledgement with the task id, PID, and log path so the agent turn keeps moving.

Built-in matches: `watch ...`, `tail -f`, `journalctl -f`, Pi-bridge/tmux polling loops, and shell loops with `sleep` that monitor session state.

Use the arm-next-bash shortcut or `/bg:next` to force the next bash command into the background even if it doesn't match the built-in patterns. Only applies to commands not yet started.

## Settings

Open `/extensions:settings`; settings appear under the **Background Tasks** tab.

### Execution

| Setting | What it does |
| --- | --- |
| Enable background tasks | Master toggle for `bg_task`, auto-backgrounding, and the widget. |
| Default timeout | Spawn timeout. `0` disables. |
| Auto-background blocking bash monitors | Auto-divert long-running bash commands into `bg_task`. |
| Extra auto-background patterns | Newline-separated regexes for project-specific monitors. |
| Shortcut arming window | Seconds the arm-next-bash shortcut / `/bg:next` stays armed. |
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
| Show task widget | Compact background-task widget. Manual hide wins over task lifecycle refreshes until you toggle it back in. |
| Widget placement | Above or below the editor. |
| Tool output style | `compact` one-liner or `stacked` rows with expandable details. |
| Expanded tool log lines | Maximum lines shown when expanding log output. |
| Dashboard output line cap | Maximum lines in the interactive dashboard viewport. |
| Mini-dashboard default mode | `compact`, `expanded`, or `hidden` at session start; runtime hide/show is user-controlled for the rest of the session. |
| Mini-dashboard finished retention | Seconds finished tasks stay visible in the inline widget. |
| Background next bash shortcut | Configurable. |
| Mini-dashboard toggle shortcut | Configurable show/hide toggle; toggling back in restores the last visible mode. |
| Dashboard shortcut | Configurable. |

### Storage

| Setting | What it does |
| --- | --- |
| Task log directory | Override log file location. `PI_BG_TASK_DIR` env var still wins. |

### Diagnostics

Routine wake/persistence diagnostics are written only when `PI_BG_TASK_DEBUG=1`, `PI_BG_TASK_DIAGNOSTICS=1`, or `PI_BG_TASK_DIAGNOSTIC_LOG=/path/to/log` is set. They go to a log file (default: `$TMPDIR/vstack-pi-bg/diagnostics.log`) instead of stdout/stderr so active TUI widgets cannot be corrupted by raw terminal output.

## Notes

Tasks are scoped to the current Pi runtime and stopped on session shutdown. Shells start in their own process group so `/bg:stop` and shutdown terminate children. Tasks inherit Pi's environment and working directory.

Exit wakeups are durable across session restarts and PID reuse — if a task ends while Pi is gone, the next session replays the missed wake. Output wakes scheduled before `stop` / `clear` are voided.

Activity broker publication is best-effort and requires `pi-session-bridge` in the same Pi runtime. Broker events are side-channel `vstack_activity` stream rows, not chat messages; Flightdeck consumes them into its activity JSONL sidecar when enabled.

See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for the `bg_task` tool surface, wake-metadata schema, activity broker mapping, and orphan/PID-reuse identity probe.

## Attribution

Locally owned by vstack, based on the MIT-licensed `@ifi/pi-background-tasks` from `ifiokjr/oh-pi`. See `THIRD_PARTY_NOTICES.md`.
