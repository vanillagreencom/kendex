# pi-task-panel development

For maintainers. What the package does for a consumer is [README.md](README.md); the rules the agent follows are `instructions.md`.

## Invariants

- Visibility has two hide states that must not be confused: an auto-hide because every task is done, and a hide the person asked for. Only the second latches, and it blocks every automatic reopen until an explicit show or toggle-in; `autoShowOnFirstTask` fires once per session and never over a latched hide. `extensions/visibility.ts` is the whole state machine and `tests/visibility.test.ts` holds each transition, including that a toggle from compact reopens compact and one from expanded reopens expanded.
- The sidecar is canonical for resume. `tasks_write` and every slash command write the sidecar first; the session custom entry (`extensions/task-panel.ts::STATE_TYPE`) carries the full state only while it fits `TASK_PANEL_SNAPSHOT_MAX_BYTES`, and a larger state is recorded as a manifest that says the sidecar wins. A manifest seen during restore re-applies the sidecar state at that barrier, so an older full entry later in the iteration cannot replace it. When the sidecar write fails, Pi warns and the session entry keeps the full state as the fallback; `tests/extension-sidecar-fallback.test.ts` holds both directions.
- `tasks_write` tool-result details are bounded the same way (`extensions/tool-result-details.ts::taskPanelToolResultState`, `TASK_PANEL_TOOL_RESULT_MAX_STATE_BYTES`, `TASK_PANEL_TOOL_RESULT_MAX_TASKS`): an oversized state stores counts and id samples, a small one keeps the full state so older sessions still restore from it; `tests/tool-result-details.test.ts`.
- The rendered widget caps its line count so an expanded panel cannot push the chat above the terminal viewport, because pi-tui falls back to a full-screen clear whenever the first changed line sits above the previous viewport top. Overflow is dropped with a hint that the manager modal shows the full list.
- The widget registers into the shared mini-dashboard stack at `extensions/stacked-widget.ts::MINI_DASHBOARD_RANK.TASKS`; the rank table is the stack order every kendex widget package shares and changes in all of them together.
- The `ctrl+t` takeover is opt-in (`takeoverCtrlT`) because Pi binds it to thinking visibility; the alternate shortcut is always registered.

## Tests

```bash
bun test ./tests
```
