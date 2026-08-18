# Changelog

## Consumer-impacting changes

### 1.4.0

- The settings editor shows the value an extension actually resolves when that value comes from a config file the manager does not own. A row backed by such a file names the file under the setting; editing the row writes Pi settings, which override the file; `delete` reports the file instead of resetting, because the value is not stored in Pi settings. Manager config still outranks an extension's own files, so the external lookup runs only when neither manager scope holds the key.
- New integration point: an extension that reads settings from channels beyond manager config registers an `ExternalConfigResolver` under `Symbol.for("vstack.pi.extension-config-resolver")`, keyed by package name. A missing, malformed, or throwing resolver is treated as "nothing external is set" — the modal never fails to render because of one. Resolutions are cached per `(extension, key)` per inventory, so the popup's per-keystroke re-read does not repeat filesystem work; the inventory is rebuilt on each open, so external-file edits still surface.
- For repos vendoring this extension's source: `extensions/manager/types.ts` adds `EXTERNAL_CONFIG_RESOLVER_SYMBOL`, `ExternalConfigResolution`, `ExternalConfigResolver`, and `ExternalConfigResolverRegistry`; `ConfigValue.scope` widens to `Scope | "default" | "external"` and gains an optional `source` display path; `Inventory` gains a required `cwd`. These are internal modules, not a package API — the manifest declares no `main`, `exports`, or `types`, Pi loads the extension through `pi.extensions`, and nothing outside this package imports them — so the required `cwd` and the widened union break no consumer and the bump stays minor. A vendored copy carrying local edits to these modules needs those three shapes updated.

### 1.3.2

- Baseline: changelog introduced at this version. Consumer-impacting changes — behavior deltas, new/renamed/removed exports, settings and config changes, protocol/audit-shape changes — are recorded here from this version forward.
