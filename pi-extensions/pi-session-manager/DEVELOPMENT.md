# pi-session-manager development

For maintainers. What it does for a consumer is [README.md](README.md).

## Invariants

- Deleting a session deletes the shared per-session kendex tree with it, `<Pi root>/kendex/sessions/<session id>/`, which every kendex extension that keeps per-session state writes under its own package folder (`pi-prompt-stash`, `pi-caveman`, `pi-qol`, `pi-agents-tmux`, `pi-output-policy`). A package that stores per-session data anywhere else is not cleaned up here. `extensions/actions.ts::removeExtensionSessionData`.
- A delete is `trash` first when `deleteUsesTrash` is on, and a permanent unlink only when that command is unavailable or refuses; a session path beginning with `-` is passed after `--`. A `trash` past its 5 s deadline is killed and the delete fails, never falling through to unlink; `tests/actions.test.ts`. `extensions/actions.ts`.
- Search never blocks the keyboard: it is debounced, scans in time slices that a newer filter cancels, and builds a preview only for the selected row; `extensions/overlay.ts::scanSessions`. A `re:` pattern runs under a vm timeout, the one way to interrupt a running RegExp; `extensions/search.ts`, held by `tests/search.test.ts`.
- The prompt-text cache, `sessionUserMessagesCache`, lives only while the browser is open; the overlay's `dispose` clears it.
- Session files are never read whole. Listing and search go through `extensions/session-lines.ts::forEachSessionJsonlLine` and stop at the lines they need; the reader scans each chunk once, so a record spanning many chunks costs its length. `tests/session-lines.test.ts` holds the reader across chunk boundaries.
- A resume from a command context is queued through the editor as `/sessions:resume-pending <id>` and runs when Pi's session-switch API is present on the context; `extensions/session-manager.ts`.
- Resume preserves the session's saved model unless the person chose to keep the current one; `extensions/model.ts::pinSessionModel`.
- The threaded sort ranks a root by the latest activity anywhere in its subtree; `extensions/tree.ts`, held by `tests/tree.test.ts`.
- The overlay takes the shared modal lock, `Symbol.for("kendex.pi.modal-lock")`, so it never opens over another kendex popup.

## Tests

```bash
bun test ./tests
```
