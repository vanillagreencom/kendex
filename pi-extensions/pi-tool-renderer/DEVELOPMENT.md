# pi-tool-renderer development

For maintainers of the renderer. What it does for a consumer is [README.md](README.md); each module's doc comments hold its own mechanics, and this file holds what spans them.

## Invariants

- Rendering only. Every replacement tool registered in `extensions/tool-renderer/tools.ts` executes through the built-in tool it replaces (`getBuiltInTool`) and draws the result; `tool_batch` in `extensions/tool-renderer/batch.ts` is the one tool with execution of its own, and it only fans out to those same built-ins. A change that alters what a tool does belongs in a different package.
- Install order in `extensions/tool-renderer.ts` is fixed: the stack events, the tool-execution renderer patch and live-settings refresh go in before chrome and message renderers, and tool renderers go in last, after the host agent module is imported. A patch that reads a symbol another patch installs depends on that order.
- Every patch on a host component is guarded by a `Symbol.for("kendex.pi-tool-renderer.*")` marker so a reload does not stack a second copy. A new patch gets its own marker; a change to a patch's shape gets a new marker name, the way `installToolExecutionRendererPatch` carries `.v2`.
- Text reaches a line count, a preview or a clip only through `extensions/tool-renderer/text.ts::normalizeTerminalText`, which defers to `@earendil-works/pi-tui`'s `normalizeTerminalOutput` when the host exports it. A count taken from raw text disagrees with what Pi draws.
- Glyph resolution is one function, `extensions/tool-renderer/glyphs.ts::glyphStyle`: the global override wins, then the local `glyphStyle`, then the legacy `treeStyle`. The other kendex extensions read the override from this package's config id, so its key name is a cross-package contract.
- Project settings are read only after `recordProjectTrust` has seen Pi report the workspace trusted; `extensions/tool-renderer/settings.ts::readPackageConfig` reads the user file alone until then. `PI_CODING_AGENT_DIR` counts only when root-anchored, matching `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`.
- A diff is built only from input under `extensions/tool-renderer/diff.ts::MAX_DIFF_INPUT_BYTES`; above it `readTextForDiff` yields nothing, so the edit or write renders without a structured diff rather than stalling the UI.
- `tool_batch` is one tool result, so it caps the combined child output to fit Pi's tool-result budget, head and tail preserved, after each built-in tool has applied its own truncation. A child past `batchCallTimeoutMs` is reported as timed out, never dropped.
- Images in `read` results are hidden while a floating overlay is up (`extensions/tool-renderer/overlay.ts`, through the shared modal-lock symbol) but keep their reserved rows, so the layout does not jump when the overlay closes.

## Tests

The suites under `extensions/__tests__/` run on `bun:test` and import the host packages, which are optional peers and are not installed in the tree:

```bash
cd pi-extensions/pi-tool-renderer
npm install --no-save --no-package-lock --ignore-scripts --no-audit --no-fund @earendil-works/pi-agent-core@0.84.1 @earendil-works/pi-ai@0.84.1 @earendil-works/pi-coding-agent@0.84.1 @earendil-works/pi-tui@0.84.1
npm test
```

The pinned version is the Pi release the extensions are audited against; `.github/workflows/skill-tests.yml` runs the same install. A renderer change ships with a case in the suite that draws it, and a change to a normalisation or width rule with one that measures it.
