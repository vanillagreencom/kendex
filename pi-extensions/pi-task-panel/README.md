# pi-task-panel

![Expanded task panel with phase grouping](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-task-panel/assets/panel-expanded.png)
![Tasks manager overlay](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-task-panel/assets/manager.png)

Persistent task panel above the Pi status line. Tasks are managed by the agent through the `tasks_write` tool or by you through `/tasks`.

## Highlights

- Compact panel above the editor shows active and pending tasks at a glance.
- Expanded mode groups by phase and shows notes for the active task.
- Auto-advance moves to the next pending task when the active one is completed or dropped.
- Auto-hide when all tasks are done; auto-show happens only for the first non-empty task state each session and never overrides a panel you hid.
- Bulk-edit, import, and export tasks as plain markdown.
- Workflow reminders nudge the agent to keep the panel in sync.
- Participates in vstack's stable mini-dashboard stack order: Flightdeck → Tasks → Agents → BG tasks.
- Per-session sidecar state keeps slash-command edits and pending tasks resumable before the next model turn writes tool-result history.
- Large task panels keep tool-result history compact; oversized `tasks_write` details store only counts and id samples while sidecar state remains canonical for resume. If sidecar writes fail, Pi warns and keeps a full session-history fallback; `tasks_write` also keeps full tool-result details for that write.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-task-panel):

```bash
pi install npm:@vanillagreen/pi-task-panel
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-task-panel --harness pi -y
```

Restart Pi after installation.

## Commands

| Command | Action |
| --- | --- |
| `/tasks` or `/tasks:manage` | Open the interactive manager. |
| `/tasks:add <task>` | Add a task. Use `Phase :: task` to assign a phase. |
| `/tasks:edit` | Bulk-edit tasks as plain text. |
| `/tasks:start <task>` | Set a task active. |
| `/tasks:done <task>` | Mark a task completed. |
| `/tasks drop <task>` | Mark a task abandoned. |
| `/tasks:remove <task>` | Remove a task. |
| `/tasks hide` | Hide the panel. |
| `/tasks show` | Show the compact panel. |
| `/tasks show-all` | Show the expanded panel. |
| `/tasks:clear-completed` | Remove completed tasks. |
| `/tasks:export <path>` | Write tasks to a markdown file. |
| `/tasks:import <path>` | Load tasks from a markdown file. |

Arguments support autocomplete, including task names.

## Manager keys

`↑/↓` selects. `enter`/`s` starts, `d` marks done, `x` drops, `r` removes, `c` clears completed, `e` opens bulk edit.

Bulk edit format:

```
- Phase A :: First task (active)
- Phase A :: Second task (done)
- Phase B :: Third task
```

Status suffixes: `(active)`, `(done)`, `(dropped)`.

## Visibility cycle

The panel toggle cycles visible modes and hides the panel; toggling back in restores the last visible mode. After `/tasks hide` or a hide shortcut, task mutations stay hidden until `/tasks show`, `/tasks show-all`, or an explicit toggle-in. The manager popup opens with its own shortcut and documents its keys in the footer. All bindings are configurable via `/extensions:settings`; Pi's thinking-visibility binding is preserved unless you opt in to taking it over.

## Settings

Open `/extensions:settings`; settings appear under the **Task Panel** tab.

Glyph style: each package exposes `glyphStyle` (`unicode` default, `ascii` for terminal-safe chrome). `@vanillagreen/pi-tool-renderer.globalGlyphStyleOverride=ascii` forces ASCII chrome across vstack Pi extensions while leaving tool/model/user content unchanged.

### Panel

| Setting | What it does |
| --- | --- |
| Enable task panel | Master toggle for `tasks_write`, panel rendering, shortcuts, and reminders. |
| Default panel state | `hidden`, `compact`, or `expanded` when tasks first appear; later settings changes do not override a user-hidden panel in the current session. |
| Compact task count | Max tasks shown in compact mode. |
| Show active notes | Show notes for the active task in expanded mode. |
| Auto-show on first task | Reveal the panel automatically only for the first non-empty task state in a session; user-hidden panels stay hidden until explicit show/toggle. |

### Keyboard

| Setting | What it does |
| --- | --- |
| Take over thinking-visibility binding | Repurpose Pi's thinking-visibility binding for the task-panel toggle. |
| Alternate shortcut | Always-available toggle. Configurable. |
| Manager popup shortcut | Configurable. |

### Tool output

| Setting | What it does |
| --- | --- |
| Compact tasks_write output | Render `tasks_write` results as a single inline status row. |

### Reminders

| Setting | What it does |
| --- | --- |
| Task workflow reminders | Inject hidden task context so the agent reconciles state before replying. |
| Incomplete-task reminders | Subtle reminder when a turn ends with incomplete tasks. |
