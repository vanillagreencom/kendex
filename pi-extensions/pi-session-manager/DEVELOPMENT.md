# pi-session-manager development

For maintainers. What it does for a consumer is [README.md](README.md).

## Invariants

- Deleting a session deletes the shared per-session kendex tree with it, `<Pi root>/kendex/sessions/<session id>/`, which every kendex extension that keeps per-session state writes under its own package folder (`pi-prompt-stash`, `pi-caveman`, `pi-qol`, `pi-agents-tmux`, `pi-output-policy`). A package that stores per-session data anywhere else is not cleaned up here. `extensions/actions.ts::removeExtensionSessionData`.
- A delete is refused while a running Pi owns the session: a claim record names the session file or the session id, the id because the per-session kendex tree is keyed by it. Each extension runtime writes one record, `<Pi root>/kendex/pi-session-manager/live/<pid>-<uuid>.json`, at `session_start`, through a rename, and removes it at `session_shutdown`, except a `reload` shutdown: that one leaves the record in a process-global slot, and the runtime the reload builds next takes its path and rewrites it, so the session stays claimed across the reload. The owner check runs again after a `trash` that fails, before the unlink fallback, since another Pi may have resumed the session while `trash` ran. A record whose pid no longer answers a signal is removed at the next owner check; a reused pid keeps the session, the safe side. The records are per process, not per lane, so `lane-retention.ts` does not prune them. An unreadable record or claim directory fails the delete. `extensions/live-sessions.ts`, held by `tests/actions.test.ts` and `tests/live-sessions.test.ts`.
- A delete is `trash` first when `deleteUsesTrash` is on, and a permanent unlink only when that command is unavailable or refuses; a session path beginning with `-` is passed after `--`. A `trash` past its 5 s deadline is killed with its process group; if the session file is still in place the delete fails and keeps it, never falling through to unlink. `extensions/actions.ts::runTrash`, held by `tests/actions.test.ts`.
- Search is debounced, a newer filter cancels it, it matches sessions in batches of eight and yields to the keyboard once a slice of batches has run 12 ms, and it builds a preview only for the selected row; `extensions/overlay.ts::scanSessions`. Between yields the thread is held: one batch costs its transcript reads plus its match time. A `re:` pattern runs under a 250 ms vm timeout, the one way to interrupt a running RegExp: over the whole batch first, then, when the batch runs past it, over each session on its own, so a batch can hold the thread for the deadline plus one deadline per session. A `re:` preview holds it for at most one deadline. `extensions/search.ts::matchSessions`, held by `tests/search.test.ts`.
- Resume, rename, delete and delete-all are refused while a filter is armed or scanning, so no session action reads a list that does not match the search box; `extensions/overlay.ts::refuseWhileSearching`, held by `tests/overlay.test.ts`.
- The prompt-text cache, `sessionUserMessagesCache`, lives only while the browser is open; the overlay's `dispose` clears it. A delete still running at close starts no scan, stops a delete-all run after the current session, and reports through `ctx.ui.notify`; held by `tests/overlay.test.ts`.
- Session files are never read whole. Listing and search go through `extensions/session-lines.ts::forEachSessionJsonlLine` and stop at the lines they need; the reader scans each chunk once, so a record spanning many chunks costs its length. `tests/session-lines.test.ts` holds the reader across chunk boundaries.
- A resume from a command context is queued through the editor as `/sessions:resume-pending <id>` and runs when Pi's session-switch API is present on the context; `extensions/session-manager.ts`.
- Resume preserves the session's saved model unless the person chose to keep the current one; `extensions/model.ts::pinSessionModel`.
- The threaded sort ranks a root by the latest activity anywhere in its subtree; `extensions/tree.ts`, held by `tests/tree.test.ts`.
- The overlay takes the shared modal lock, `Symbol.for("kendex.pi.modal-lock")`, so it never opens over another kendex popup.

## Tests

```bash
bun test ./tests
```
