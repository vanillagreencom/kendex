# Changelog

## Consumer-impacting changes

### Unreleased

- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-qol"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-qol"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-agents-tmux.statusline`, `kendex.pi-qol.installed`, `kendex.pi-qol.notification-service`, `kendex.pi-qol.pending-queue.theme-patch`, `kendex.pi-qol.session-search.pending-context`, `kendex.pi-qol.status-text-alignment-patch`, `kendex.pi-qol.thinking-timer.patch`, `kendex.pi-qol.thinking-timer.store`, `kendex.pi-questions.service`, `kendex.pi.caveman`, `kendex.pi.extension-manager.open-quick-settings`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.8.0

- Pi 0.84.0 parity: session auto-rename now forwards `null` provider headers unchanged. `ModelRegistry.getApiKeyAndHeaders()` returns `ProviderHeaders` (`Record<string, string | null>`) where `null` is a header-deletion marker pi-ai acts on; `headerRecord()` dropped those entries, silently re-sending headers Pi asked to remove. `headerRecord()` is now exported and preserves `null` while still dropping empty and non-string values.

### 1.7.5

- Long-session budget guard now gives Pi's built-in post-response compaction first chance, avoiding duplicate `Already compacted` failures.
- Successful compaction suppresses repeat attempts at the same threshold until usage falls below the guard or advances to a new threshold; unrelated failures still surface and retry normally.
- Minimum supported Pi version is now 0.80.4 for long-session budget guard support.
- Active budget-guard compaction now finishes before terminal settlement or one-shot pane shutdown can overtake it. Delayed activity from a replaced session is ignored instead of changing the current session's guard state.

### 1.7.4

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
