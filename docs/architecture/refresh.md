# Refresh

Covers: crates/cli/src/commands/refresh.rs, crates/core/src/engine/removal.rs

## Scope cleanup

Refresh uses `engine::removal::orphans` to retire recorded agents the refreshed scope no longer declares. Its existing unfiltered sweep removes their renders and lock entries in one apply and reports each removal through the installed-set preview. Edited renders stay as conflicts until `--discard-edits` permits removal. Unrecorded files and other scopes stay untouched. Enforced by `crates/cli/tests/refresh_agent_cleanup.rs::a_project_refresh_retires_dropped_agents_and_verify_passes`.