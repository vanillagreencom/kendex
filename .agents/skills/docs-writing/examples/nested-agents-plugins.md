# shell/plugins/

One directory per plugin, each with `manifest.json`, its QML or Python entry and `tests/`. Before changing a plugin, read `docs/architecture/plugins.md`.

- Run one plugin's tests with `uv run pytest shell/plugins/<name>`.

---

## Not this

> ## Why plugins
>
> The plugin model came out of the 0.3 redesign, when the bar and the launcher shared one process and a crash in either took the desktop down. We considered a supervisor per surface and rejected it because ...

The principle doc owns its design rules and rationale. Local instructions give the reading trigger and local commands; repeated rules can drift.
