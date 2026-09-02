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
`packages/` or `npm/node_modules/` segment. Finding neither, it falls back to
`PI_CODING_AGENT_DIR` (or `~/.pi/agent`), but only when that directory already
exists, so installing one of these packages on a machine without Pi writes
nothing. A package installed outside any Pi-managed tree, a legacy npm
global-prefix install, therefore has its block written to the user-global
`APPEND_SYSTEM.md`. That is where the package's own `postinstall` put it, so
it is also the only place the manager can remove it from. All three branches
are pinned in `test/actions.test.ts`: the `packages/` layout, the
`npm/node_modules/` layout, and the fallback.

The script is best-effort for npm's sake: given `install` or `remove` it exits
0 on every failure and reports only on stderr. (Any other argv exits 1, which
the manager never produces.) `append-system.ts` therefore reads a stderr line
beginning `append-system.mjs:` as the failure, not any stderr at all, since
`runCommand` inherits the environment and node's own warnings would otherwise
read as one. It warns with the action, package dir and the script's own lines,
and returns false; every caller folds that into what the user sees. The spawn
carries a bounded timeout and `SIGKILL`, because a package-supplied script runs
on Pi's TUI thread.

The npm uninstall path runs the removal before `npm uninstall`, because npm 7+
does not reliably run a removed package's own `preuninstall` and the script is
deleted with the tree. Two consequences the messages have to carry: a removal
that failed is permanent once npm deletes the tree, so the success message
names the file to edit by hand; and if npm itself fails the package is still
installed, so the block is rewritten, unless it was a disabled package that had
no block to begin with.

Test spawns go through `useSandboxedSpawn`, which pins the child's `HOME` and
`PI_CODING_AGENT_DIR`. `spawnSync` snapshots the environment the process
started with, so a child left to inherit it resolves the developer's real
`~/.pi/agent` and writes into their live `APPEND_SYSTEM.md`.
