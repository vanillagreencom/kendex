# shell/plugins/

One directory per plugin, each with `manifest.json`, its QML or Python entry and `tests/`. The principle behind these rules is `docs/architecture/plugins.md`.

- Run one plugin's tests with `uv run pytest shell/plugins/<name>`.
- A plugin imports from `shell/hosts/` and its own directory only; `scripts/check-plugin-boundary.py` refuses an import of another plugin or of the core.
- Declare every host the plugin needs in `manifest.json`; an undeclared host is absent at run time.
- Never read the compositor directly; the `compositor` host owns that link.

---

## Not this

> ## Why plugins
>
> The plugin model came out of the 0.3 redesign, when the bar and the launcher shared one process and a crash in either took the desktop down. We considered a supervisor per surface and rejected it because ...

Rationale and history belong to the principle doc the folder points at; a second copy here drifts from the first, and an agent working in the folder wanted the rules, not the story.
