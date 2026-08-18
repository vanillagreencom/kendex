# pi-output-policy — development notes

Internals, design, and maintenance for the pi-output-policy Pi extension. Consumer docs live in [`README.md`](./README.md); consumer-visible changes live in [`CHANGELOG.md`](./CHANGELOG.md).

## Two budgets, one policy

Output policy enforces two related but distinct budgets:

- **Compact renderer UI** — how big a tool block can be without breaking Pi's TUI. Caps line width, hard line count, and absolute block size.
- **Model transcript / session JSONL** — how much each tool result adds to the request body that gets resent on every turn. Long runs with many individually "fine" 50–200 KB results can exceed provider request-buffer limits even when no single block is UI-pathological.

The default `balanced` policy mode constrains both budgets while leaving the full text on disk via per-session artifacts.

## Model output guard

The guard targets model decoding collapse such as thousands of identical planning sentences or malformed tool tags. Blank lines and recognized syntax-only lines (tool/XML tags, code fences, and Markdown separators) do not reset or trigger repetition streaks; other short content resets the streak. All lines still count toward the hard response-size cap.

Guard state and delta inspection are exported for integrations and tests: `createModelOutputGuardState()` and `inspectModelOutputDelta()`.

## Sanitization and audit shape

When `details` are sanitized, the result carries a `vstackOutputPolicySanitized` marker (and capped arrays/objects include a sentinel string) so consumers can detect the truncation.

## Custom messages

Extension-produced custom messages (`pi.sendMessage`) are not policed by this extension; add per-package caps in extensions that emit large custom messages.

## Source layout

Everything ships from one module, `extensions/output-policy.ts`. Its named exports are the seams other code and the tests use:

| Export | Surface |
| --- | --- |
| `resolvePolicyMode()` | Effective `balanced`/`compact`/`compat` mode for a cwd. |
| `isSanitizeExceptTool()` | Allowlist membership for details sanitization. |
| `createModelOutputGuardState()`, `inspectModelOutputDelta()` | Streaming model-output guard. |
| `processText()` | Minimization, truncation, spill, and the truncation notice. |
| `sanitizeDetails()` | Bounded nested tool-result `details`. |
| `minimizeShellOutput()` | Shell output minimizer. |
| `recordProjectTrust()` | Project-trust bookkeeping for `.pi/settings.json` reads. |
| `__resetSessionCountersForTests()` | Per-session byte-counter reset for tests. |

## Tests

Regression coverage lives in `tests/output-policy.test.ts` and runs on `bun:test`:

```bash
cd pi-extensions/pi-output-policy && bun test ./tests
```
