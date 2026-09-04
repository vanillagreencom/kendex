# pi-hooks development

For maintainers of the carrier. What it does for a consumer is [README.md](README.md); the mechanics live as doc comments on the functions named below, and this file holds only the invariants that span them.

## Invariants

- A guard that did not run does not stand aside. Every path that fails to reach a verdict refuses: a missing render, a timeout (read before the exit code, because a killed process still has one), a non-zero exit other than 2, a registry that exists and cannot be parsed, a matcher that will not compile. Only an absent registry allows, because that is kendex having installed nothing. `extensions/hooks.ts::runRegisteredHook` and `extensions/registry.ts::readRegistry`; `tests/hooks.test.ts` and `tests/registry.test.ts` hold each case.
- The registry is the render, not a model of it. What runs is the command kendex wrote; nothing in the carrier knows a hook's name in advance, which is what lets a custom hook run at all. A hook kendex rendered is spawned at `<registry root>/hooks/<name>.sh` rather than through its command, because the command spells a project path through `git rev-parse` and git's root is not always kendex's. `extensions/registry.ts::renderedName` decides which commands are kendex's.
- The listener key, the tool vocabulary and the project-root rule are copies of kendex's own and are held to it by tests: `TOOL_CALL_LISTENER` to `crates/core/src/harness/caps.rs::pi_listener`, `extensions/vocab.ts` to `crates/core/src/render/vocab/mod.rs`, `extensions/config.ts::PROJECT_MARKER_DIRS` and `PROJECT_LOCK_FILE` to `crates/core/src/discover.rs`. A drift on either side is a registry written under one key and read under another, which is every hook silently off.
- The project scope is read only when Pi reports the workspace trusted, for both the registry and `.pi/settings.json`; the global scope is trusted without asking because it holds the person's own files. That is why `PI_CODING_AGENT_DIR` counts only when root-anchored (`extensions/config.ts::rootAnchored`, matching `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`): a relative override would make an untrusted clone the global root.
- Input keying is one rename, `path` to `file_path` for `Read`, `Write` and `Edit`; nothing else is reshaped. A guard authored against Claude Code's `Edit` payload does not see `old_string` and `new_string` under Pi.
- Refusals name the hook's label, never a custom command's text: that text is the person's and can hold a credential, and a reason is read by the model.
- Per-guard settings are a `Map` keyed by script name, and an unrecognised name runs under the master switch alone.
- `turn_end` reports through `pi.sendMessage` with `triggerTurn: true`, because Pi discards the handler's return and a non-steering message is never read by a headless run that is ending. Every failing turn reports; the bound is that a turn writing no `.rs` file runs no clippy.

## Tests

```bash
bun test ./tests
```

`tests/harness.ts` builds a project with rendered registries in both scopes and a fake extension API. A new refusal path ships with the control that plants the failure it refuses, and a new copy of a kendex-side rule ships with the test that holds the two together.
