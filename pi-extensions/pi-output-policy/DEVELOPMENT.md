# pi-output-policy development

For maintainers. What it does for a consumer is [README.md](README.md). Everything ships from one module, `extensions/output-policy.ts`, whose named exports are the seams the tests use: `resolvePolicyMode`, `isSanitizeExceptTool`, `createModelOutputGuardState`, `inspectModelOutputDelta`, `processText`, `sanitizeDetails`, `minimizeShellOutput`, `recordProjectTrust`, and `__resetSessionCountersForTests`.

## Invariants

- Two budgets, one policy. The UI budget (line width, line count, block size) is what the TUI can render; the transcript budget (spill threshold, inline tail) is what each tool result adds to the request body resent on every turn. A change to one mode's numbers in `MODE_DEFAULTS` must keep both: `balanced` is sized so a single non-read, non-mutation result cannot push more than its `maxTextBlockKb` into the transcript, and the tests pin that bound.
- A knob explicitly set wins over the mode; an unset knob follows `resolvePolicyMode`. A mode value nobody recognises resolves to `balanced`.
- The full text is never lost. A result above the spill threshold is written under `artifactDir` (the Pi user directory's kendex session folder, falling back to the OS temp directory) before the inline copy is cut, and the truncation notice names the artifact path; when the write fails the notice carries `artifactError` instead of pretending.
- The guard watches for decoding collapse only. Blank lines and recognised syntax-only lines (tool or XML tags, code fences, Markdown separators) neither reset nor extend a repetition streak; other short content resets it; every character counts toward the hard cap, thinking and tool-call argument deltas included. The abort fires once per assistant message, a notification failure cannot prevent it, and each lifecycle reset re-arms it. Settings are snapshotted once per assistant message.
- Sanitization skips state-bearing tools. `DEFAULT_SANITIZE_EXCEPT_TOOLS` names the tools whose `details` a sidecar restore reads back (task panel, background tasks, subagents); capping those corrupts restore. A configured `sanitizeDetails.exceptTools` replaces that list, and matching includes dotted suffixes so namespaced tools pass. Sanitized details carry a `kendexOutputPolicySanitized` marker and a sentinel string in any capped array or object.
- Custom messages sent through `pi.sendMessage` are not policed here. An extension that emits large custom messages bounds them itself.
- Project settings are read only after Pi reports the workspace trusted (`recordProjectTrust`), the same rule every kendex Pi extension follows.

## Tests

```bash
bun test ./tests
```

`tests/output-policy.test.ts` covers the guard boundaries (exact repetition and character thresholds, disable switches, lifecycle resets), each mode's caps and the knob override, the minimizer alone and with truncation, sanitization shapes and the allowlist, and the per-turn and per-session counters. A threshold change ships with the case that fires exactly at the new boundary.
