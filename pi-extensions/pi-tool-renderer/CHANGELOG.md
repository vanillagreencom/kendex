# Changelog

## Consumer-impacting changes

### Unreleased

- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-tool-renderer"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-tool-renderer"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-tool-renderer.assistant-message-patch`, `kendex.pi-tool-renderer.compaction-summary-renderer-patch`, `kendex.pi-tool-renderer.custom-message-spacing-patch`, `kendex.pi-tool-renderer.installed`, `kendex.pi-tool-renderer.markdown-code-block-patch`, `kendex.pi-tool-renderer.overlay-check`, `kendex.pi-tool-renderer.skill-invocation-renderer-patch`, `kendex.pi-tool-renderer.tool-chrome-patch`, `kendex.pi-tool-renderer.tool-chrome-theme`, `kendex.pi-tool-renderer.tool-execution-renderer-patch.v2`, `kendex.pi-tool-renderer.user-message-box-state`, `kendex.pi-tool-renderer.user-message-patch`, `kendex.pi-tool-renderer.working-loader-alignment-patch`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.7.2

- Documentation only, no runtime change. This version ships what landed on main after 1.7.1 was published: the packaged README trimmed to the consumer contract — what the extension does, its settings, and setup — with contributor-facing internals moved to the unpublished `DEVELOPMENT.md` (#1473), and a `test` script in the manifest, `bun test ./extensions/__tests__`, which the repo's CI and `tools/validate-changed` now run (#1474). Published so the npm and pi.dev gallery pages carry the current copy; `extensions/` is byte-identical to 1.7.1.

### 1.7.1

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
