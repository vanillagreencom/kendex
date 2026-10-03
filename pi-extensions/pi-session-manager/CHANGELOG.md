# Changelog

## Consumer-impacting changes

### 2.0.4

- Delete refuses a session that another running Pi has open, by its session file or its session id, and names that Pi's working directory and process id; the session file and its per-session kendex data are kept. Each Pi running this package records the session it has open under `~/.pi/agent/kendex/pi-session-manager/live/` and removes the record when the session ends, keeping it across `/reload`; a record left by a Pi that was killed is removed at the next delete.

### 2.0.3

- Search runs after a 120 ms typing pause and in slices that yield to the keyboard; a new keystroke cancels the search in progress. A match preview is built only for the selected row.
- Resume, rename, delete and delete-all wait for the search to match the search box; pressed earlier, they show "Search still running" and do nothing.
- A `re:` search stops with an error when the pattern runs past 250 ms on the prompts of one session.
- Delete runs `trash` without blocking the browser. After 5 seconds it stops `trash` and any helper `trash` started. If the session file is still in place, the delete fails and keeps it; it never falls back to a permanent unlink.
- The prompt text the search reads is released when the browser closes. A delete still running at close reports its outcome as a Pi notification, and a delete-all run stops after the session in progress.

### 2.0.2

- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 2.0.1

- Deleting a session removes `~/.pi/agent/kendex/sessions/<id>/` only. The older per-package directories `~/.pi/agent/kendex/{pi-agents-tmux,prompt-stash,pi-output-policy}/sessions/<id>/` are no longer removed with it, and the older `session-manager` status entry is no longer cleared at session start, on resume or on rename.
- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-session-manager"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-session-manager"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-session-manager.installed`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.5.3

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
