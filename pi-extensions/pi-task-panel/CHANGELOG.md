# Changelog

## Consumer-impacting changes

### 2.0.0

- The panel toggle (`alternateShortcut`, `takeoverCtrlT`, `/tasks toggle`) now hides the panel and restores the last visible mode when toggling back in: a compact panel reopens compact instead of expanded. Previously the toggle stepped compact → expanded → hidden, so a hidden compact panel always reopened expanded. (#1152)
- New `toggleBehavior` setting (enum `toggle`/`cycle`, default `toggle`): `cycle` steps hidden → compact → expanded → hidden for users who want the shortcut to reach every state.
- **Breaking** (hence the major bump): the `extensions/visibility.ts` export `cycleTaskPanelVisibility(state)` is renamed to `toggleTaskPanelVisibility(state, behavior)` with no compatibility alias — this repo ships clean breaks with changelog notes, never shims. Also added: `PanelToggleBehavior`, `normalizePanelToggleBehavior`.

### 1.3.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
