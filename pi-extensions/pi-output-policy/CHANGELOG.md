# Changelog

## Consumer-impacting changes

### 1.2.0

- Added a default-on streaming model-output guard. It aborts assistant responses after 24 consecutive repeated substantial lines / 1,536 repeated characters, or after 96,000 total streamed characters, preventing degenerate provider output from overwhelming Pi's TUI and session.
- Added live `modelOutputGuard.*` settings for master enablement, independent repetition/character-cap enablement, and all thresholds. Settings are snapshotted once per assistant message, so changes apply to the next message without adding synchronous file reads to each streamed delta.
- Repetition streaks now survive only blank and recognized syntax-only lines, including CommonMark backtick and tilde fences with spaced info strings; distinct short semantic content resets them, preventing repeated report headings or separators from becoming false positives.
- Exported `createModelOutputGuardState()` and `inspectModelOutputDelta()` for integrations and tests.

### 1.1.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
