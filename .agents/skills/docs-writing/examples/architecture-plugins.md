# Everything outside the core is a plugin

Read before adding a surface, a service or a core module to the shell.

## The approach

Every visible surface and every background service is a plugin under `shell/plugins/` or the user's plugin directory. The core is what has to exist before any plugin can run and keep running when one breaks: the process, the lock, the compositor link, the theme tokens, the hosts, the registry, the plugin manager and IPC. The core names no plugin; `config/shell.json` names the default bar.

## Why

A core that holds features lets a change to one surface break another, and grows past what one agent can hold in context. A small privileged core changes rarely, and a plugin change cannot reach another plugin, so the review scope of a change is the plugin.

## Rules

- Do put a new surface or service in a plugin, with its own directory, manifest and tests.
- Do reach the core through a host: a plugin asks a host for a slot, a token or an IPC channel, and never imports a core module.
- Do declare every host a plugin needs in its manifest; an undeclared host is absent at run time.
- Never name a plugin id in the core. `scripts/check-plugin-boundary.py` refuses a plugin id literal or a plugin import in a core file, and the pre-commit chain runs it.
- Never let one plugin import another. Shared code is a host or a core service.
- The plugin manager's mechanism is core, because it must run before any plugin and keep running when one breaks; its user interface is a plugin.

## The canonical example

`shell/plugins/clock/` is the smallest complete plugin: a manifest that declares its kind and the one host it needs, a surface drawn into the slot that host gives it, and a service reached only over IPC. Copy it.

## Revisit when

A feature needs a surface no host can give and the host cannot be added without a core rewrite, or the core grows past what one agent holds in context.

## Not governed

What a plugin does inside its slot, and the design of a host's own API; the first is the plugin's tests, the second is `shell/hosts/AGENTS.md`.

---

## Not this

```markdown
`shell/plugins/clock/service.py::publish` is called by `shell/hosts/bar.py::tick` every second (`BAR_TICK_MS = 1000`, set in LUM-412 on 2026-09-21, after the 1.4 refactor moved `tick` out of `main.py`); `tests/test_clock.py::test_publishes_every_tick` enforces the interval and `test_manifest_loads` covers the manifest. The earlier timer in `main.py` is gone.
```

It narrates call order, a test row, a date and task history: an agent reads it and learns no rule it could break, while every name in it goes stale at the next rename.

### Dense safety text

> Unload calls `revoke_routes`, then `stop_service`, then `release_slot`. The manager must revoke a plugin's host access before its code can run again. It must not follow a plugin symlink outside the plugin root or remove a user's plugin directory. `stop_service` waits on the worker before closing its socket. Set `sandbox = "strict"` in every manifest.

Keep the boundaries in the architecture doc:

> Only the plugin manager grants host access. Revoke that access before unloading plugin code. Never write outside the canonical plugin root or remove a user's plugin directory. Review holds these boundaries.

Inspect `shell/plugins/manifest.schema.json` before cutting the sandbox sentence. The declaration owns the allowed value; user setup belongs in the plugin README. Inspect the unload implementation before cutting the wait and socket order. A local reason the code cannot show goes in a comment there. Delete the function sequence after those checks. Moving the whole paragraph to a reference would keep the implementation account.

### Operating sequence

> To test a local plugin, run `plugins validate`, start the shell with `--plugin-dir`, then run `plugins reload` after each edit. The manager scans manifests, resolves hosts and starts each service.

Move the commands, in that order, to `DEVELOPMENT.md` § Test a local plugin after inspecting that section. Delete the manager's call sequence. Keep the architecture rule that a plugin declares each required host before it can use it. The operating steps and the access boundary have different readers.
