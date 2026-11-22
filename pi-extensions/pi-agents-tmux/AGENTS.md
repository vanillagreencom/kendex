# pi-agents-tmux agent notes

- Keep broker emission fail-open: subagent dispatch, steering, completion, and result retrieval must not depend on activity publish success.
- The `bg|pane` lane badge renders from `SingleResult.kind`, stamped at dispatch.
  - Never re-derive the lane from `taskId`/`paneId`: `taskId` records whether a task was queued, so a pane dispatch refused before queueing carries none and would mislabel as `bg`.
  - Every new `SingleResult` construction site sets `kind`.
  - Pre-dispatch refusals also set `refused: true` so the row reads `refused` instead of claiming a run failed.
- `delegate_subagent` is intentionally narrow: single-mode only, authorized via `PI_SUBAGENT_CHILD_AGENT`, allowlist comes from the caller agent's `allowed-subagents:` frontmatter, pane targets rejected.
  - Do not silently grow its schema or short-circuit the allowlist.
  - Keep bridge env vars and tmux pane-title/inbox behavior pane-only unless tested against `pi-session-bridge`.
- Preserve the environment-switch case in `tests/own-tmux-server.test.ts` when changing title serialization; a pending request must keep its original tmux target.
