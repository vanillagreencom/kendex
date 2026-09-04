# pi-skills-manager development

For maintainers. What it does for a consumer is [README.md](README.md).

## Invariants

- Hiding the startup `[Skills]` block patches `InteractiveMode.prototype.showLoadedResources` once per process, guarded by `Symbol.for("kendex.pi-skills-manager.startup-patch")`, and the patch defers to the original whenever the setting is off or Pi's shape differs from what it expects. `extensions/skills-manager/startup.ts::patchInteractiveModeStartupSkillsBlock`. A Pi upgrade that renames that method silently restores the block; there is no other failure mode.
- A toggle writes Pi's own package filter patterns through Pi's settings manager, replacing any earlier pattern for the same skill path; `extensions/skills-manager/toggle.ts::setSkillEnabled`. Project-scope writes need the workspace trusted.
- Skill generation goes through `extensions/skills-manager/pi-ai-compat.ts`, which prefers Pi's root `complete` export and falls back to the compat entrypoint, with Pi's transient retries when the host offers them; a provider or validation failure warns and saves the deterministic template from `extensions/skills-manager/creation-fallback.ts`. `tests/creation-retry.test.ts` and `tests/pi-ai-compat.test.ts`.
- Overlay geometry is computed in `extensions/skills-manager/layout.ts` and always yields a finite row count of at least one, however small the terminal; `tests/layout.test.ts` holds each bound.
- With the feature disabled, only the recovery commands `/skill` and `/skill:enable` are registered, so the person can turn it back on without editing settings by hand; `extensions/skills-manager.ts`.
- The overlay takes the shared modal lock, `Symbol.for("kendex.pi.modal-lock")`.

## Tests

```bash
bun test ./tests
```
