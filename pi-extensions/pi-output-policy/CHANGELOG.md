# Changelog

## Consumer-impacting changes

### 2.1.0

- One tool result now has one inline budget. All its text blocks share `maxTextBlockKb` and the line cap, or `inlineTailKb` and `inlineTailLines` for tail-truncated tools, and the truncation notice counts inside both the byte and the line allowance. A result of many small blocks no longer passes several times the budget to the model. Blocks past the budget are dropped from the preview, and one artifact holds the full text of every block. `details.kendexOutputPolicy` carries one entry per result.
- The tail allowance (`inlineTailKb`, `inlineTailLines`) no longer exceeds `maxTextBlockKb` or `maxLineCount`.
- `maxLineCount` and `inlineTailLines` values under 7 read as 7, so the truncation notice, up to 6 lines with a write-error notice, leaves at least one line of output. A preview the byte budget leaves with no line reports its `shownRange` as `none`.
- Artifacts are written off Pi's main thread, at most two at a time. When no artifact can be written, a separate `[output-policy:artifact-error=...]` notice follows the truncation notice and names the error; before, the error was one clause inside the truncation notice. A partly written artifact is removed.
- Large tool output is no longer split into whole-output line arrays. The truncation preview copies only the lines it keeps; the shell minimizer still copies the lines it keeps, for output up to `shellMinimizer.maxCaptureBytes`, and settings are read once per tool result instead of once per setting.
- Detail sanitizing shares one budget of 2,000 values and 64 KiB of string text across a result's whole `details` tree, beside the per-array, per-object and per-string caps. A string the byte budget cuts ends with an `[output-policy:detail-byte-budget=65536]` notice, and a container the budget stops ends with that notice or `[output-policy:detail-node-budget=2000]`. Details within every limit pass through unchanged, not copied.
- A tool result within every limit now passes through unchanged. Before, its CRLF line ends were rewritten to LF.
- Settings reads come from memory. A read is answered for one second without touching disk, then the settings files are read again. A change made in the extension manager, or a new session, applies at once; a hand edit to `settings.json` applies within one second. Before, every read went to disk.

### 2.0.2

- Truncation, minimization and detail-sanitizing notices now open with an `[output-policy:<key>=<value>]` line followed by the explanation, replacing the single bracketed sentence.
- The model-output stop warning carries its reason and that reason's count the same way.

### 2.0.1

- Artifacts are no longer moved from the older locations `~/.pi/agent/kendex/pi-output-policy/sessions/<id>/artifacts` and `<project>/.pi/artifacts/output-policy` at session start or on the first write. Artifacts left there stay there; new artifacts land in the per-session directory only.
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
