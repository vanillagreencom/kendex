# Refresh

Covers: crates/cli/src/commands/refresh.rs, crates/core/src/engine/removal.rs, crates/cli/src/commands/update_pi.rs, crates/core/src/engine/mod.rs, crates/core/src/engine/planned.rs, crates/core/src/engine/report_types.rs, crates/core/src/engine/scope_writes.rs

## Scope cleanup

Refresh uses `engine::removal::orphans` to retire recorded agents the refreshed scope no longer declares. Its existing unfiltered sweep removes their renders and lock entries in one apply and reports each removal through the installed-set preview. Edited renders stay as conflicts until `--discard-edits` permits removal. Unrecorded files and other scopes stay untouched. Enforced by `crates/cli/tests/refresh_agent_cleanup.rs::a_project_refresh_retires_dropped_agents_and_verify_passes`.

## Locked refresh

`refresh --locked` plans with `PlanOptions::locked`, the hold naming no package. Every declaration with no revision of its own reads at the commit its lock entries agree on, and a declaration the lock cannot place resolves at the source's tip. The Pi settle reads each package through `engine::held_declarations` under the same options, both to install it and to record the install, so it settles and records at the commit the plan reads. The record's source entries follow the plan's own reads only. The record keeps each source's commit where the plan read nothing at the source's own revision, so a project-side re-render changes no catalog commit in `.kendex-lock.json`. A source the plan did read there, for a declaration the lock cannot place, records what it read, and a source now declared at another repository or revision than its entry was written for is read afresh. The Pi settle reads outside the plan: a Pi package the lock cannot place installs and records its own entry at the source's tip, and its source's entry keeps the commit the record held. Without the flag, refresh plans with no hold and brings every catalog current. Enforced by `crates/cli/tests/refresh_locked.rs`.

## Tool caches

A render's on-disk identity (`hash::RenderedIdentity::from_path`) leaves out `__pycache__` and `.pytest_cache` at every depth (`source_read::TOOL_CACHES`), the caches a skill's source also leaves out and a skill's own Python script writes back into its render on every run. So refresh, verify and every automatic removal read a cached render as the bytes kendex wrote: refresh writes a newer upstream over it and an orphan cleanup takes it. The source also leaves out `.git`, `node_modules` and `.venv`, but inside a render those are a person's: they keep the edit hold, so a refresh never replaces a render holding a `.git`, and an orphan cleanup leaves a render holding a dangling `.venv` link in place. Enforced by `crates/core/tests/edits_and_forks/tool_caches.rs`.
