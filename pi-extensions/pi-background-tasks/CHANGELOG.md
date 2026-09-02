# Changelog

## Consumer-impacting changes

### Unreleased

- The extension uses `PI_CODING_AGENT_DIR` only when root-anchored — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`. The install helper is unchanged.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-background-tasks"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-background-tasks"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.background-tasks.installed`, `kendex.pi.activity`, `kendex.pi.mini-dashboard-stack`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.6.3

- Documentation only, no runtime change. This version ships what landed on main after 1.6.2 was published: the packaged README trimmed to the consumer contract — what the extension does, its tools, settings, and setup — with contributor-facing internals moved to the unpublished `DEVELOPMENT.md` (#1473). Published so the npm and pi.dev gallery pages carry the current copy; `extensions/` and `scripts/` are byte-identical to 1.6.2.

### 1.6.2

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
