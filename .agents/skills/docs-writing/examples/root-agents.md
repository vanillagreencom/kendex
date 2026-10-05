# lumen

A Wayland desktop shell in QML and Python: a bar, a launcher and a notification centre, each a plugin over a small core. This repository is also the shell's default plugin catalog.

## Commands

- `scripts/dev`: runs the shell nested in a window against this checkout, while the installed shell keeps running.
- `scripts/check-plugin-boundary.py`: the core-boundary check the pre-commit chain runs; read it for what the boundary refuses.
- `uv run pytest -m slow`: the compositor tests, left out of the default run.

## Conventions

- A new surface or service is a plugin, never a core module.
- Shell state lives under `~/.local/state/lumen/`; nothing under `config/` is written at run time.
- A user-facing string goes through `t()`; a literal string in QML fails the `strings` lint lane.

## Read when

- Before writing a plugin: `docs/architecture/plugins.md`.
- Before drawing a screen, control or state: `docs/architecture/design-system.md`.
- When working under `shell/plugins/`: `shell/plugins/AGENTS.md`.
- When working under `ui/components/`: `ui/components/AGENTS.md`.

---

## Not this

> ## Layout
>
> - `shell/core/process.py`: starts the shell process and holds the lock.
> - `shell/core/compositor.py`: the Wayland link; see `connect()` and `on_output()`.
> - `shell/hosts/bar.py`: gives each bar plugin a slot; calls `tick()` every second.
> - `shell/plugins/clock/`: the clock, rewritten in September after the timer bug.

A file-by-file inventory is what `ls` and the code already show; it costs context at every session start and is stale at the next rename, and the history line tells an agent nothing it can act on.
