# pi-extension-manager development

For maintainers of the manager and for authors of a package that reads a config file of its own. What the manager does for a Pi user is [README.md](README.md).

## External config resolvers

The settings editor owns one config channel, `kendex.extensionManager.config[<packageName>]` in project and user `settings.json`. A package that also reads its own file resolves values the manager cannot see, so the schema default it would render can be the opposite of the effective value. Such a package publishes a resolver on `globalThis` under `Symbol.for("kendex.pi.extension-config-resolver")` (`extensions/manager/types.ts::EXTERNAL_CONFIG_RESOLVER_SYMBOL`), in a record keyed by package name, the same id the manager keys config by:

```ts
type ExternalConfigResolver = (key: string, cwd: string) => { explicit: boolean; value: unknown; source?: string } | undefined;

const registry = (globalThis as any)[Symbol.for("kendex.pi.extension-config-resolver")] ??= {};
registry["@scope/my-extension"] = (key, cwd) => ({ explicit: true, value: resolved, source: "~/.pi/agent/my-extension.json" });
```

Contract:

- `key` is a settings key from the package's `kendex.extensionManager.settings`. Return `undefined` or `explicit: false` for a key the package does not own or has no value for.
- Report only the channels the manager does not own. Manager config outranks them: `extensions/manager/settings.ts::getConfigValue` consults the resolver only after both manager scopes miss.
- `value` is what the package's own loader produces for that key, same normalization and same precedence between its files. A raw value the loader would reject re-creates the divergence this exists to close.
- `source` is the concrete file behind the value, home-relative; the UI names it so the user knows what to edit.
- Register before any early return in the package's entry point. A value that disables the package is exactly the case the editor has to explain.
- No unregister; the registry lives for the process.

`getConfigValue` returns `{ explicit: true, scope: "external", value, source }` for a resolved value. A resolver that throws is treated as nothing set and the row falls back to the schema default; a broken resolver must never take the editor down. Results are memoized per `Inventory`, one call per key per popup open. The editor treats an external value as read-only for its reset paths: `delete` names the source file, since `resetConfigKeys` deletes only from `settings.json`, and the extension-wide reset counts only project and user rows. Writing the row stays allowed; that is the documented override. `test/settings.test.ts` holds every clause.

## Invariants

- Project scope is read only when Pi reports the workspace trusted, for packages and settings alike (`test/inventory.test.ts`).
- Package roots are Pi's own: npm actions run in the scope-local npm directory, and a git entry is inspected only under Pi's managed clone root; an entry with an unsafe host or path component is shown as broken rather than read from outside that root.
- The manager holds no second copy of the `APPEND_SYSTEM.md` upsert. Enable, disable and orphan uninstall run the package's own vendored `scripts/append-system.mjs`, the artifact npm runs at `postinstall` and `preuninstall` (`extensions/manager/append-system.ts`), under a bounded timeout with `SIGKILL`, because a package-supplied script runs on Pi's TUI thread. The npm uninstall path runs the removal before `npm uninstall`, since npm does not reliably run a removed package's `preuninstall` and the script goes with the tree.
- Paths are root-anchored as `crates/core/src/harness/pi.rs::pi_root_is_absolute_for` means it (`extensions/manager/paths.ts`), because Node's `isAbsolute` accepts a driveless `\root` the renderer does not, which would put the two on different roots.
- The inventory spawns npm only when the cheap package roots miss, and memoizes the root across packages; `test/popup-perf.test.ts` holds the popup's wall-clock bound.

## Tests

```bash
bun test ./test
```

A test that spawns a child goes through `test/actions.test.ts::useSandboxedSpawn`, which pins the child's `HOME` and `PI_CODING_AGENT_DIR`; `spawnSync` snapshots the environment the process started with, so a child left to inherit it writes into the developer's live `APPEND_SYSTEM.md`.
