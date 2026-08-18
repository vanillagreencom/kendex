# pi-tool-renderer — development notes

Internals, design, and maintenance for the pi-tool-renderer Pi extension. Consumer docs live in [`README.md`](./README.md); consumer-visible changes live in [`CHANGELOG.md`](./CHANGELOG.md).

## Install order

`extensions/tool-renderer.ts` is the entry point. It guards against double installation with a `Symbol.for("vstack.pi-tool-renderer.installed")` marker, returns early when the `enabled` setting is off, records project trust on `session_start`, and then installs in a fixed order: stack events, the tool-execution renderer patch, live-settings refresh, tool chrome, the working indicator and loader alignment, markdown code blocks, and the compaction-summary renderer. Message renderers and tool renderers are registered afterwards, once the host agent module is imported.

`edit`/`write` renderers are registered only when `renderMutationTools` is on; `tool_batch` only when `registerBatchTool` is on.

## Module layout

| Module | Responsibility |
| --- | --- |
| `extensions/tool-renderer.ts` | Entry point and registration order. |
| `extensions/tool-renderer/tools.ts` | `read`, `bash`, `edit`, `write`, `grep`, `find`, `ls` renderers; execution delegates to Pi's built-in tools. |
| `extensions/tool-renderer/batch.ts` | `registerToolBatch()` — the `tool_batch` composite tool. |
| `extensions/tool-renderer/stack.ts` | Legacy stacking of consecutive native tool calls. |
| `extensions/tool-renderer/chrome.ts` | Tool chrome rules, tool-execution renderer patch, working indicator, loader alignment. |
| `extensions/tool-renderer/messages.ts` | User, assistant, compaction-summary, and skill-invocation renderers; custom-message spacing; markdown code blocks. |
| `extensions/tool-renderer/diff.ts` | Structured diff model, hunk numbering, Shiki highlighting, diff background theme capture, `MAX_DIFF_INPUT_BYTES`. |
| `extensions/tool-renderer/generic.ts` | OpenAI-style, MCP, and unknown-tool renderers plus `apply_patch` call/result previews. |
| `extensions/tool-renderer/images.ts` | Overlay-aware image rendering for `read` results. |
| `extensions/tool-renderer/overlay.ts` | Floating-overlay detection through the shared vstack modal-lock symbol. |
| `extensions/tool-renderer/settings.ts` | `CONFIG_ID`, vstack config reads, typed setting accessors, project-trust gating. |
| `extensions/tool-renderer/live-settings.ts` | Re-renders tracked tool-execution components on `vstack:extension-settings-changed`. |
| `extensions/tool-renderer/glyphs.ts` | Unicode/ASCII glyph sets and `globalGlyphStyleOverride` resolution. |
| `extensions/tool-renderer/theme.ts` | Theme token lookups with fallbacks, tree connectors, tool labels. |
| `extensions/tool-renderer/text.ts` | Terminal normalization, line counting, previews, line clipping. |
| `extensions/tool-renderer/ansi.ts` | ANSI/OSC helpers and visible-width math. |

## Terminal normalization

`normalizeTerminalText()` collapses CRLF and lone CR to `\n`, then delegates to the host's `normalizeTerminalOutput` when `@earendil-works/pi-tui` exposes it, so rendered text matches Pi's own normalization. Without that export it falls back to expanding tabs to three spaces. Line counting, splitting, and previews all route through it.

## Tests

Regression coverage lives in `extensions/__tests__/` and runs on `bun:test` — batch timeouts, code blocks, diff borders, file hyperlinks, glyphs, line counting, OSC 133 prompt-zone markers, stale message context, read images, terminal normalization, theme tokens, and tool chrome.

The suites import the host packages, which are optional peer dependencies, so install them before running:

```bash
cd pi-extensions/pi-tool-renderer
npm install --no-save --no-package-lock --ignore-scripts --no-audit --no-fund @earendil-works/pi-coding-agent@0.84.1 @earendil-works/pi-tui@0.84.1
bun test ./extensions/__tests__
```
