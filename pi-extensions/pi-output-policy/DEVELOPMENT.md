# pi-output-policy development

For maintainers. What it does for a consumer is [README.md](README.md). Everything ships from one module, `extensions/output-policy.ts`, whose named exports are the seams the tests use: `resolvePolicyMode`, `isSanitizeExceptTool`, `createModelOutputGuardState`, `inspectModelOutputDelta`, `processContent`, `sanitizeDetails`, `minimizeShellOutput`, `recordProjectTrust`, and `__resetSessionCountersForTests`.

## Invariants

- Two budgets, one policy. The UI budget (line width, line count, block size) is what the TUI can render; the transcript budget (spill threshold, inline tail) is what each tool result adds to the request body resent on every turn. A change to one mode's numbers in `MODE_DEFAULTS` must keep both: `balanced` is sized so a single non-read, non-mutation result cannot push more than its `maxTextBlockKb` into the transcript, and the tests pin that bound.
- One budget per result. `processContent` reads every text part of a result as one text joined by newlines and keeps its head or tail lines within one byte and line allowance. The notice is inside that allowance, bytes and lines both: it is sized from worst-case figures before the preview is cut. `appendNotice` is the one place a notice joins text after a blank line, and `noticeLines` the one place that counts the lines it adds. `MIN_LINE_LIMIT`, the floor of `maxLineCount` and `inlineTailLines`, is the tallest notice plus one preview line. A minimized notice counts toward the line cap too. A part left with no line is dropped.
- No whole-output copy on Pi's thread. The line scanners walk newline positions: `eachLine` forward, the tail selection backward. The truncation preview slices only the lines it keeps. The shell minimizer is the exception: it slices every line of its input to test it and copies the lines it keeps, for input up to `shellMinimizer.maxCaptureBytes`. The artifact write is asynchronous, at most `ARTIFACT_WRITE_SLOTS` at once, and encodes through one small fixed buffer.
- A knob explicitly set wins over the mode; an unset knob follows `resolvePolicyMode`. A mode value nobody recognises resolves to `balanced`.
- The full text is never lost. A result above a limit is written under `artifactDir` (the Pi user directory's kendex session folder, falling back to the OS temp directory) before the inline copy is cut, all text parts in one file, and the truncation notice names the artifact path. When both writes fail, no path is named: an `artifact-error` notice follows the truncation notice with both errors, and `artifactError` carries them. A write that fails part way removes its partial file.
- The guard watches for decoding collapse only. Blank lines and recognised syntax-only lines (tool or XML tags, code fences, Markdown separators) neither reset nor extend a repetition streak; other short content resets it; every character counts toward the hard cap, thinking and tool-call argument deltas included. The abort fires once per assistant message, a notification failure cannot prevent it, and each lifecycle reset re-arms it. Settings are snapshotted once per assistant message.
- Sanitization skips state-bearing tools. `DEFAULT_SANITIZE_EXCEPT_TOOLS` names the tools whose `details` a sidecar restore reads back (task panel, background tasks, subagents); capping those corrupts restore. A configured `sanitizeDetails.exceptTools` replaces that list, and matching includes dotted suffixes so namespaced tools pass. Sanitized details carry a `kendexOutputPolicySanitized` marker and a sentinel string in any capped array or object. One traversal shares a value budget and a string byte budget across the whole tree; the string the byte budget cuts ends with the `detail-byte-budget` notice and spends the rest of the budget, and a branch no cap touches is returned by reference, so an in-budget tree is never copied.
- Custom messages sent through `pi.sendMessage` are not policed here. An extension that emits large custom messages bounds them itself.
- Project settings are read only after Pi reports the workspace trusted (`recordProjectTrust`), the same rule every kendex Pi extension follows.

## Tests

```bash
bun test ./tests
```

| Test file | Contract |
|---|---|
| [model-output-detector.test.ts](tests/model-output-detector.test.ts) | Stream input shapes and exact repetition and character thresholds |
| [model-output-handler.test.ts](tests/model-output-handler.test.ts) | Abort notices, settings snapshots, and message lifecycle resets |
| [policy-config.test.ts](tests/policy-config.test.ts) | Policy modes and detail exemptions |
| [process-content.test.ts](tests/process-content.test.ts) | Text budgets, the shared per-result budget, artifacts and their write errors and write slots, explicit overrides, and minimizer interaction |
| [shell-minimizer.test.ts](tests/shell-minimizer.test.ts) | Retained shell lines, CRLF line ends, and minimizer configuration |
| [sanitize-details.test.ts](tests/sanitize-details.test.ts) | Detail limits, traversal and byte budgets, unchanged branches by reference, and truncation identifiers |
| [saved-bytes.test.ts](tests/saved-bytes.test.ts) | Saved-byte accumulation and turn and session resets |
| [tool-result.test.ts](tests/tool-result.test.ts) | Tool-result sanitization and truncation metadata |

A threshold change ships with the case that fires exactly at the new boundary.
