# Changelog

## Consumer-impacting changes

### Unreleased

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
