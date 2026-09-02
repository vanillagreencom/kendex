# Changelog

## Consumer-impacting changes

### Unreleased

- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-output-policy"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-output-policy"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-output-policy.installed`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.2.0

- Added a default-on streaming model-output guard. It aborts assistant responses after 24 consecutive repeated substantial lines / 1,536 repeated characters, or after 96,000 total streamed characters, preventing degenerate provider output from overwhelming Pi's TUI and session.
- Added live `modelOutputGuard.*` settings for master enablement, independent repetition/character-cap enablement, and all thresholds. Settings are snapshotted once per assistant message, so changes apply to the next message without adding synchronous file reads to each streamed delta.
- Repetition streaks now survive only blank and recognized syntax-only lines, including CommonMark backtick and tilde fences with spaced info strings; distinct short semantic content resets them, preventing repeated report headings or separators from becoming false positives.
- Exported `createModelOutputGuardState()` and `inspectModelOutputDelta()` for integrations and tests.

### 1.1.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
