# pi-output-policy development

What it does for a consumer is [README.md](README.md). The policy ships from one module, `extensions/output-policy.ts`, whose named exports are the seams the tests use: `resolvePolicyMode`, `isSanitizeExceptTool`, `createModelOutputGuardState`, `inspectModelOutputDelta`, `processContent`, `sanitizeDetails`, `minimizeShellOutput`, and `__resetSessionCountersForTests`. The settings reader, `recordProjectTrust` and `clearPackageConfigCache` come from the vendored `extensions/package-config.ts`, which the tests use as a seam too.

## Invariants

- Two budgets, one policy. The UI budget (line width, line count, block size) is what the TUI can render; the transcript budget (spill threshold, inline tail) is what each tool result adds to the request body resent on every turn. A change to one mode's numbers in `MODE_DEFAULTS` must keep both: `balanced` is sized so a single non-read, non-mutation result cannot push more than its `maxTextBlockKb` into the transcript, and the tests pin that bound.
- One budget per result.
  - `processContent` reads every text part of a result as one text joined by newlines and keeps its head or tail lines within one byte and line allowance.
  - The notice is inside that allowance, bytes and lines both: it is sized from worst-case figures before the preview is cut.
  - `appendNotice` is the one place a notice joins text after a blank line, and `noticeLines` the one place that counts the lines it adds.
  - `MIN_LINE_LIMIT`, the floor of `maxLineCount` and `inlineTailLines`, is the tallest notice plus one preview line.
  - A minimized notice counts toward the line cap too.
  - A part left with no line is dropped.
- No whole-output copy on Pi's thread.
  - The line scanners walk newline positions: `eachLine` forward, the tail selection backward.
  - The truncation preview slices only the lines it keeps.
  - The shell minimizer is the exception: it slices every line of its input to test it and copies the lines it keeps, for input up to `shellMinimizer.maxCaptureBytes`.
  - The artifact write is asynchronous, at most `ARTIFACT_WRITE_SLOTS` at once, and encodes through one small fixed buffer.
- A knob explicitly set wins over the mode; an unset knob follows `resolvePolicyMode`. A mode value nobody recognises resolves to `balanced`.
- The full text is never lost.
  - A result above a limit is written under `artifactDir` (the Pi user directory's kendex session folder, falling back to the OS temp directory) before the inline copy is cut, all text parts in one file, and the truncation notice names the artifact path.
  - When both writes fail, no path is named: an `artifact-error` notice follows the truncation notice with both errors, and `artifactError` carries them.
  - A write that fails part way removes its partial file.
- The guard watches for decoding collapse only.
  - Blank lines and recognised syntax-only lines (tool or XML tags, code fences, Markdown separators) neither reset nor extend a repetition streak; other short content resets it; every character counts toward the hard cap, thinking and tool-call argument deltas included.
  - The abort fires once per assistant message, a notification failure cannot prevent it, and each lifecycle reset re-arms it.
  - Settings are snapshotted once per assistant message.
- Sanitization skips state-bearing tools.
  - `DEFAULT_SANITIZE_EXCEPT_TOOLS` names the tools whose `details` a sidecar restore reads back (task panel, background tasks, subagents); capping those corrupts restore.
  - A configured `sanitizeDetails.exceptTools` replaces that list, and matching includes dotted suffixes so namespaced tools pass.
  - Sanitized details carry a `kendexOutputPolicySanitized` marker and a sentinel string in any capped array or object.
  - One traversal shares a value budget and a string byte budget across the whole tree; the string the byte budget cuts ends with the `detail-byte-budget` notice and spends the rest of the budget, and a branch no cap touches is returned by reference, so an in-budget tree is never copied.
- Custom messages sent through `pi.sendMessage` are not policed here. An extension that emits large custom messages bounds them itself.

## Tests

```bash
bun test ./tests
```

