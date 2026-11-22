## pi-task-panel — `tasks_write` tool

Keep the task panel current throughout non-trivial multi-step work, including before the final reply.

Use:

- Before any non-trivial multi-step work, `action: "replace"` with a full `tasks: [...]` list.
- The moment you start an item, `action: "start_task"`.
- The moment you finish one, `action: "mark_done"` (auto-advances to the next pending task).
- When scope changes mid-turn, `action: "add_task"` for new follow-ups.
- When scope changes mid-turn, `action: "drop_task"` for items that no longer apply.

Rules:

- `replace` takes `tasks: [{ content, phase?, status? }]`; the single-task actions (`add_task`, `start_task`, `mark_done`, `drop_task`, `remove_task`, `append_note`) take a top-level `task` (text or id), never a `tasks` array.
- Never end a turn with a stale `in_progress` task.
- If work has moved on, `start_task` the right one or `drop_task` it before replying.
- Do not narrate task transitions in prose ("now I'll start X") — just call the tool.
- For one-shot trivial requests, do not create a task panel at all.
- If the user hides the panel, `tasks_write` updates keep state current but do not auto-reopen the widget. Only explicit `/tasks show`, `/tasks show-all`, or toggle-in reveals it again.
