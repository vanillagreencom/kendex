# pi-extension-manager — development notes

Implementation details for contributors. End-user commands, settings, and behavior live in [`README.md`](./README.md).

## External config resolvers

The settings editor owns exactly one config channel: `kendex.extensionManager.config[<packageName>]` in project and user `settings.json`. An extension that also reads its own file (a legacy config path, a host-owned file) resolves values the manager cannot see, so the manifest default it renders can be the opposite of the effective value.

Such an extension publishes a resolver on `globalThis` under `Symbol.for("kendex.pi.extension-config-resolver")`, in a record keyed by package name — the same id `getConfigValue`/`setConfigValue` key manager config by:

```ts
type ExternalConfigResolver = (key: string, cwd: string) => { explicit: boolean; value: unknown; source?: string } | undefined;

const registry = (globalThis as any)[Symbol.for("kendex.pi.extension-config-resolver")] ??= {};
registry["@scope/my-extension"] = (key, cwd) => ({ explicit: true, value: resolved, source: "~/.pi/agent/my-extension.json" });
```

Contract:

- `key` is a manifest settings key from `kendex.extensionManager.settings`. Return `undefined` (or `explicit: false`) for keys the extension does not own or has no value for.
- Report **only** the channels the manager does not own. Manager config outranks them, and `getConfigValue` consults the resolver only after both manager scopes miss, so folding manager config back in would just be redundant work.
- `value` must be what the extension's own loader produces for that key — same normalization, same precedence between its files. A resolver that reports a raw value its loader would reject re-creates the divergence this mechanism exists to close.
- `source` is the concrete file behind the value, home-relative for display. The UI names it, so the user knows what to edit.
- Register before any early return in the extension's entry point. A value that disables the extension is exactly the case where the modal has to explain itself.
- No unregister: the registry lives for the process.

`getConfigValue` returns `{ explicit: true, scope: "external", value, source }` for a resolved external value. A resolver that throws is treated as "nothing set" and the row falls back to the schema default — a broken resolver must never take the modal down. Results are memoized per `Inventory`, so a resolver is called once per key per popup open rather than once per rendered row.

The editor treats an external value as read-only for its own reset paths: `delete` names the source file instead of running a reset that `resetConfigKeys` (which only deletes from `settings.json`) cannot perform, and the extension-wide reset counts only `project`/`user` rows. Writing the row is still allowed — that is the documented way to override the file, because manager config wins.

## APPEND_SYSTEM.md blocks

Enable, disable and uninstall run the package's own vendored
`scripts/append-system.mjs`, the same artifact npm runs at `postinstall` and
`preuninstall`. The manager holds no second copy of the upsert.

The script resolves its own scope by walking up from its package dir to a
`packages/` or `npm/node_modules/` segment, and **falls back to
`PI_CODING_AGENT_DIR` (or `~/.pi/agent`) when it finds neither**. So a package
installed outside any Pi-managed tree, a legacy npm global-prefix install, has
its block written to the user-global `APPEND_SYSTEM.md`. That is where the
package's own `postinstall` put it, so it is also the only place the manager
can remove it from. `test/actions.test.ts` pins where a block lands for the
`packages/` layout, and `test/inventory.test.ts` for `npm/node_modules/`.

The script is best-effort for npm's sake: it exits 0 on every failure and
reports only on stderr. `append-system.ts` therefore treats non-empty stderr
as a failure alongside a non-zero exit, warns with the action, package dir and
captured stderr, and returns false so the toggle notice and the uninstall
message can say the block was not written.

The npm uninstall path runs the removal **before** `npm uninstall`, because
npm 7+ does not reliably run a removed package's own `preuninstall` and the
script is deleted with the tree. If npm then fails, the package is still
installed and enabled, so the block is rewritten and the failure message says
so when the rewrite itself fails.

