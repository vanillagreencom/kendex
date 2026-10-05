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

`shell/plugins/clock/` is the smallest complete plugin: `manifest.json` names its kind and the bar host, `Clock.qml` draws into the slot the host gives it, `service.py` publishes the time over IPC, and `tests/` proves the manifest loads and the service answers. Copy it.

## Revisit when

A feature needs a surface no host can give and the host cannot be added without a core rewrite, or the core grows past what one agent holds in context.

---

## Not this

> `shell/plugins/clock/service.py::publish` is called by `shell/hosts/bar.py::tick` every second (`BAR_TICK_MS = 1000`, set in LUM-412 on 2026-09-21, after the 1.4 refactor moved `tick` out of `main.py`); `tests/test_clock.py::test_publishes_every_tick` enforces the interval and `test_manifest_loads` covers the manifest. The earlier timer in `main.py` is gone.

It narrates call order, a test row, a date and task history: an agent reads it and learns no rule it could break, while every name in it goes stale at the next rename.
