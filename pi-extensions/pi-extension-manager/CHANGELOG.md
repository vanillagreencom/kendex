# Changelog

## Consumer-impacting changes

### Unreleased

- `PI_CODING_AGENT_DIR` is used only when it names a root-anchored path — a drive or UNC share on Windows, a leading `/` on POSIX. Anything else uses `~/.pi/agent`.

### 2.0.0

- **Breaking**: the settings namespace is renamed from `vstack` to `kendex`, with no compatibility fallback. Configuration previously read from `vstack.extensionManager.config["@vanillagreen/pi-extension-manager"]` in `.pi/settings.json` is now read from `kendex.extensionManager.config["@vanillagreen/pi-extension-manager"]`; settings still stored under the old key are ignored and this package silently falls back to its defaults until the key is renamed. The `package.json` block that declares these settings is renamed from `"vstack"` to `"kendex"` to match.
- **Breaking**: cross-extension interop symbols move from the `vstack.*` to the `kendex.*` `Symbol.for` registry (`kendex.pi-extension-manager.installed`, `kendex.pi.extension-config-resolver`, `kendex.pi.extension-manager.open-quick-settings`, `kendex.pi.modal-lock`, `kendex.pi.project-trust`). Symbol identity is the interop contract, so a package on the old namespace cannot see one on the new namespace — upgrade every installed `@vanillagreen` Pi extension together rather than one at a time.
- Project-root detection recognizes `.kendex-lock.json` instead of `.vstack-lock.json`.
- Repository, homepage, issue-tracker, and README asset URLs now point at `vanillagreencom/kendex`.

### 1.4.0

- The settings editor shows the value an extension actually resolves when that value comes from a config file the manager does not own. A row backed by such a file names the file under the setting; editing the row writes Pi settings, which override the file; `delete` reports the file instead of resetting, because the value is not stored in Pi settings. Manager config still outranks an extension's own files, so the external lookup runs only when neither manager scope holds the key.
- New integration point: an extension that reads settings from channels beyond manager config registers an `ExternalConfigResolver` under `Symbol.for("kendex.pi.extension-config-resolver")`, keyed by package name. A missing, malformed, or throwing resolver is treated as "nothing external is set" — the modal never fails to render because of one. Resolutions are cached per `(extension, key)` per inventory, so the popup's per-keystroke re-read does not repeat filesystem work; the inventory is rebuilt on each open, so external-file edits still surface.
- For repos vendoring this extension's source: `extensions/manager/types.ts` adds `EXTERNAL_CONFIG_RESOLVER_SYMBOL`, `ExternalConfigResolution`, `ExternalConfigResolver`, and `ExternalConfigResolverRegistry`; `ConfigValue.scope` widens to `Scope | "default" | "external"` and gains an optional `source` display path; `Inventory` gains a required `cwd`. These are internal modules, not a package API — the manifest declares no `main`, `exports`, or `types`, Pi loads the extension through `pi.extensions`, and nothing outside this package imports them — so the required `cwd` and the widened union break no consumer and the bump stays minor. A vendored copy carrying local edits to these modules needs those three shapes updated.

### 1.3.2

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
