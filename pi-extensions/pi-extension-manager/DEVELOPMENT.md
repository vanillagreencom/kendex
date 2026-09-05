# pi-extension-manager development

User-facing commands and settings are in [README.md](README.md).

## Host boundary

`extensions/manager/host.ts::HostAdapter` owns host selection, paths, settings codecs, native inventory, toggle state and action capabilities. The factory selects it from the running coding-agent module's exports. OMP resolves legacy Pi imports through its compatibility shim; the presence of an OMP installation or directory is not host identity. OMP's utils and discovery exports resolve user configuration, plugin storage and the asynchronous project plugin anchor. `prepare(cwd)` refreshes that anchor before an inventory opens; rendering consumes normalized items without host-name branches.

OMP's plugin roots are separate from its settings directories. Native inventory reads dependency names plus lock records, retaining disabled plugins and linked packages. Enabled project plugins shadow enabled user plugins; disabled project records do not hide a usable user installation. Native enable writes the owning lock record, not a synthetic settings `packages` array or manager `disabledItems` entry. Project plugin suppression is visible but refuses an enable that would remain ineffective. Module-level writes are unsupported because host basename IDs can address modules in several packages. These contracts are exercised by `test/host.test.ts`.

The OMP inventory covers native npm/link installations and persisted configured extension paths. It is not a snapshot of foreign-provider, CLI or runtime overlays, marketplace inventory, or optional plugin feature selection. It shows declared base entrypoints, not a proof that each module has executed. Package enable controls all native plugin contributions; restarting applies the change without relying on discovery caches being invalidated by an external writer.

OMP settings edits are restricted to this manager's namespace. A different kendex extension's Pi JSON reader does not start reading YAML because this manager can write it. Update, uninstall and append-system execution remain Pi-only. Unsupported actions refuse before invoking a process or writing a Pi filter. Existing YAML filenames and unknown fields survive writes; comments and formatting do not. Invalid documents or malformed manager/native state refuse rather than being replaced with defaults. This is a synchronous local read-modify-write boundary, not a concurrent-writer locking protocol.

OMP global settings prefer `config.yml`, then `config.yaml`. Native project settings layer `settings.json` before `config.yml`; edits target the last matching raw layer, never a merged document. The project settings directory is cwd-local, while the project plugin anchor can be an ancestor. Pi retains its root-anchored override policy when its runtime resolver returns a relative directory (`extensions/manager/paths.ts::rootAnchored`).

## External config resolvers

On Pi, the settings editor owns `kendex.extensionManager.config[<packageName>]` in user and project settings. A package that also reads its own config file publishes an external resolver under `Symbol.for("kendex.pi.extension-config-resolver")`, in a record keyed by package name:

```ts
type ExternalConfigResolver = (key: string, cwd: string) => { explicit: boolean; value: unknown; source?: string } | undefined;
```

- `key` comes from the package's `kendex.extensionManager.settings` schema. Return `undefined` or `explicit: false` for an unset or unowned key.
- Report only external channels. Manager config takes precedence in `extensions/manager/settings.ts::getConfigValue`.
- Return the value the package's loader resolves, with its own normalization and file precedence. `source` names the concrete file, optionally home-relative.
- Register before an early return that disables the package. The registry lives for the process and has no unregister operation.
- A throwing resolver behaves like an unset value. The editor memoizes results per inventory so keystrokes do not reread external files.

`getConfigValue` returns scope `external` for a resolved external value. Reset names the source file because no manager override exists to delete. Editing remains allowed on Pi and writes a manager override. `test/settings.test.ts` exercises this contract.

## Pi invariants

- Project settings and package declarations are read only when the host reports the workspace trusted (`test/inventory.test.ts`).
- npm actions use the scope-local npm directory. Git entries are inspected only under Pi's managed clone root; unsafe host or path components produce broken inventory items.
- The manager delegates append-system changes to the package's vendored `scripts/append-system.mjs`, with a bounded timeout and `SIGKILL`. Uninstall removes the block before npm deletes that script (`test/actions.test.ts`).
- Inventory spawns npm only when cheap package roots miss and memoizes the root across packages. `test/popup-perf.test.ts` enforces the existing popup budget.
- Bootstrap reads the manager's global enable setting, so recovery writes that same global layer even when project settings exist.

## Tests

```bash
bun test ./test
```

From the repository root, also run `node --test pi-extensions/package-policy.test.mjs`.

The native disabled-package regression in `test/host.test.ts` has no settings JSON and no YAML package list. Replacing native inventory with Pi's package-settings loop must fail that fixture even if the OMP directory and YAML codec remain correct.

A test that invokes package scripts uses `test/actions.test.ts::useSandboxedSpawn`, which pins child `HOME` and `PI_CODING_AGENT_DIR`. A spawned child otherwise inherits the process's original environment rather than later test mutations.

OMP's compiled 18.1.11 host supports the imported utils/discovery exports and the existing custom-overlay UI. An isolated-home PTY smoke can open the manager, toggle a disabled native plugin and open settings without sending an agent prompt. Keep credentials out of that environment and disable startup setup/update checks. Recheck these runtime exports and plugin persistence contracts when raising the tested OMP baseline.
