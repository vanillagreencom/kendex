# Refresh

Covers: crates/cli/src/commands/refresh.rs, crates/core/src/engine/removal.rs, crates/cli/src/commands/update_pi.rs

## Scope cleanup

Refresh uses `engine::removal::orphans` to retire recorded agents the refreshed scope no longer declares. Its existing unfiltered sweep removes their renders and lock entries in one apply and reports each removal through the installed-set preview. Edited renders stay as conflicts until `--discard-edits` permits removal. Unrecorded files and other scopes stay untouched. Enforced by `crates/cli/tests/refresh_agent_cleanup.rs::a_project_refresh_retires_dropped_agents_and_verify_passes`.

## Locked refresh

`refresh --locked` plans with `PlanOptions::locked`, the hold naming no package. Every declaration with no revision of its own reads at the commit its lock entries agree on, and a declaration the lock cannot place resolves at the source's tip. The Pi settle reads each package through `engine::held_declarations` under the same options, so it settles at the commit the plan reads. The record keeps each source's commit where the pass read nothing at the source's own revision, so a project-side re-render changes no catalog commit in `.kendex-lock.json`. Without the flag, refresh plans with no hold and brings every catalog current. Enforced by `crates/cli/tests/refresh_locked.rs::a_locked_refresh_renders_a_project_change_at_the_recorded_catalog`.
