# pi-skills-manager development

For maintainers. What it does for a consumer is [README.md](README.md).

## Invariants

- Hiding the startup `[Skills]` block patches `InteractiveMode.prototype.showLoadedResources` once per process, guarded by `Symbol.for("kendex.pi-skills-manager.startup-patch")`, and the patch defers to the original whenever the setting is off or Pi's shape differs from what it expects. `extensions/skills-manager/startup.ts::patchInteractiveModeStartupSkillsBlock`. A Pi upgrade that renames that method silently restores the block; there is no other failure mode.
- A toggle writes Pi's own package filter patterns through Pi's settings manager, replacing any earlier pattern for the same skill path; `extensions/skills-manager/toggle.ts::setSkillEnabled`. Project-scope writes need the workspace trusted.
- Skill generation goes through `extensions/skills-manager/pi-ai-compat.ts`, which prefers Pi's root `complete` export and falls back to the compat entrypoint, with Pi's transient retries when the host offers them; a provider or validation failure warns and saves the deterministic template from `extensions/skills-manager/creation-fallback.ts`. `tests/creation-retry.test.ts`, `tests/creation-fallback.test.ts`, and `tests/pi-ai-compat.test.ts`.
- Overlay geometry is computed in `extensions/skills-manager/layout.ts` and always yields a finite row count of at least one, however small the terminal; `tests/layout.test.ts` holds each bound.
- With the feature disabled, only the recovery commands `/skill` and `/skill:enable` are registered, so the person can turn it back on without editing settings by hand; `extensions/skills-manager.ts`.
- The overlay takes the shared modal lock, `Symbol.for("kendex.pi.modal-lock")`.
- Deleting a skill awaits `rm` from `node:fs/promises`, so Pi keeps rendering between filesystem batches; on Node, `rm` settles unlinks in bursts, so a directory of thousands of files can still pause Pi briefly. The dialog's `deleting` mode takes no input until the removal settles, and every outcome leaves it. Every removal, a failed one included, reloads the list, because a recursive `rm` can stop part-way: a skill the reloaded list still shows returns to where the delete began, one it no longer shows goes to the list, as does every skill when the reload fails, and a removal or reload that fails is reported as an error. `extensions/skills-manager/registry.ts::deleteSkill`, `tests/delete.test.ts`.

## Tests

```bash
bun test ./tests
```
