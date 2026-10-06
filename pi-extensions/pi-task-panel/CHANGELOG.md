# Changelog

## Consumer-impacting changes

### Unreleased

- Lists over 64 KiB saved beside the session are kept up to 32 MiB per session instead of the newest 20, so a list that changes often no longer pushes older `/tree` points out after 20 changes. A save also removes a temporary file a failed write left there. The session's task files now follow lane retention: when a Pi session starts, the files of every session whose working directory is gone are deleted, and any file older than 5 days is deleted. Files from sessions that never save again after this update are not pruned.
- Task reminders leave the system prompt unchanged. Task context stays in request history, and a new hidden snapshot is added only when the task context changes. This preserves earlier request text for prompt caching across task changes and task completion.

### 3.0.5

- A restore after `/tree` navigation, a fork or a resume shows the list saved at that point of the session. Before, an older tree point showed the newest saved list, and a point with no saved list showed it too. A list over 64 KiB is now also saved as `states/<fingerprint>.json` beside the sidecar `state.json`, and the newest 20 such files are kept. Where the list a manifest or bounded `tasks_write` details stand for is in neither file, as in a fork, the panel keeps the last full list the session holds and warns with a `persistence_failure=branch-state-missing` line. The first task change after a restore always saves, so a change at an older point that recreates the newer list is kept.

### 3.0.4

- Task panels reuse sorted task order and layout during redraws. Bulk replacement and import normalize the completed list once, preserving an explicitly active task after earlier pending tasks.

### 3.0.3

- A task change that leaves the task list as it was no longer writes the sidecar `state.json` or adds a session entry. A real change writes the sidecar in the background, off Pi's main thread, and replaces the file whole, so a crash during the write leaves the previous state readable. The sidecar is now compact JSON instead of indented JSON.
- `tasks_write`, the `/tasks` commands, the shortcuts and the manager return after their sidecar write lands, and session shutdown waits for any write still queued.
- A session entry that Pi refuses to append is reported with a `persistence_failure=session-entry` warning instead of failing the call, or `persistence_failure=session-entry-no-sidecar` when the sidecar write failed too. Either warning says a session restart can bring back the older state until the next successful save. After a failed sidecar write or session entry, the next task change saves the state again, even when it leaves the task list as it was.
- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 3.0.2

- The persistence-failure warning opens with a `persistence_failure=<where>` line followed by the explanation.
- The npm install and uninstall helper reports each refusal as an `append-system: <key>=<value>` line followed by the explanation, and an appendSystem source that cannot be read is reported and skipped instead of throwing.

### 3.0.1

- The extension uses `PI_CODING_AGENT_DIR` only when root-anchored — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`. The install helper is unchanged.

### 3.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-task-panel"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-task-panel"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-task-panel.installed`, `kendex.pi.mini-dashboard-stack`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 2.0.0

- The panel toggle (`alternateShortcut`, `takeoverCtrlT`, `/tasks toggle`) now hides the panel and restores the last visible mode when toggling back in: a compact panel reopens compact instead of expanded. Previously the toggle stepped compact → expanded → hidden, so a hidden compact panel always reopened expanded. (#1152)
- New `toggleBehavior` setting (enum `toggle`/`cycle`, default `toggle`): `cycle` steps hidden → compact → expanded → hidden for users who want the shortcut to reach every state.
- **Breaking** (hence the major bump): the `extensions/visibility.ts` export `cycleTaskPanelVisibility(state)` is renamed to `toggleTaskPanelVisibility(state, behavior)` with no compatibility alias — this repo ships clean breaks with changelog notes, never shims. Also added: `PanelToggleBehavior`, `normalizePanelToggleBehavior`.

### 1.3.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
