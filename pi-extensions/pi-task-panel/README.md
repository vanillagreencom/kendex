# @vanillagreen/pi-task-panel

A persistent task panel above the Pi editor. The agent keeps it current through the `tasks_write` tool and you edit it through `/tasks`, so the plan for a multi-step turn is visible while the turn runs.

## Install

Declare the package in the scope's kendex manifest, then let `kendex update-pi` install it and register it in Pi's `settings.json`. For a project, in its `kendex.toml`:

```toml
[pi-extensions."@vanillagreen/pi-task-panel"]
source = "kendex"
```

```bash
kendex update-pi
```

The same declaration in `~/.config/kendex/kendex.toml` installs it for every project. `kendex update-pi --check` prints the plan and changes nothing.

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-task-panel):

```bash
pi install npm:@vanillagreen/pi-task-panel
```

Restart Pi after installation.

## What it does

- A compact panel shows the active and pending tasks; the expanded panel groups them by phase and shows the active task's notes.
- The `tasks_write` tool replaces the list, adds a phase or task, starts, completes, drops or removes a task, appends a note, or sets the panel state. Completing or dropping the active task advances to the next pending one.
- `/tasks` opens an interactive manager; `/tasks:add`, `/tasks:start`, `/tasks:done`, `/tasks:remove`, `/tasks:edit`, `/tasks:clear-completed`, `/tasks:export` and `/tasks:import` edit the list from the command line, with `Phase :: task` naming a phase and a markdown file as the import and export format.
- The panel shows itself for the first non-empty task state of a session and hides itself when every task is done. A panel you hid stays hidden until you show it again, whatever the agent writes.
- The toggle shortcut restores the last visible mode, or cycles hidden, compact and expanded when `toggleBehavior` is `cycle`.
- Hidden reminders prompt the agent to reconcile the panel before replying and when a turn ends with incomplete tasks.
- Task state survives a resume: it is written to a per-session sidecar file, with the session history as a fallback when the sidecar cannot be written.

## How it works

The panel is a widget in kendex's shared mini-dashboard stack, ranked between the orchestration and agents widgets. Every mutation writes the state to a sidecar under the Pi user directory's `kendex/sessions` runtime and records it in the session as a custom entry, small enough not to grow the session file; a resume reads the sidecar first. The tool result the agent sees is one status line unless you expand it.

## Customise

Open `/extensions:settings`; settings appear under the **Task Panel** tab. Project settings in `.pi/settings.json` apply only after Pi marks the workspace trusted.

- `enabled`: master toggle.
- `panelDefaultState`, `maxCompactTasks`, `showNotesInExpanded`, `autoShowOnFirstTask`, `glyphStyle`: what the panel shows and when it appears.
- `alternateShortcut`, `managerShortcut`, `toggleBehavior`, `takeoverCtrlT`: the shortcuts and what the toggle does; Pi's own thinking-visibility binding is left alone unless you opt in.
- `compactToolOutput`: whether `tasks_write` results render as one line.
- `showWorkflowReminder`, `showIncompleteReminder`: the hidden reminders to the agent.

Maintainer notes are in [DEVELOPMENT.md](DEVELOPMENT.md).
