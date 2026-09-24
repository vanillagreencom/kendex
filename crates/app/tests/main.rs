//! The one harness kendex-app's integration tests build as: every file
//! beside this one is a module of it, so the crate and its dependencies link
//! once rather than once per file. Cargo's autodiscovery is off in
//! Cargo.toml, so a new file under `tests/` is a `mod` line here;
//! `tools/test-roster` holds that roster.

#[path = "../../test_util.rs"]
mod test_util;

mod apply_migration;
mod audit_scope_error;
mod bindings;
mod cask_symlink_launch;
mod icons;
mod marketplace_pending_reads;
mod marketplace_rows_absent_manifest;
mod marketplace_rows_records;
mod marketplace_rows_resolved_path;
mod optional_dependencies;
mod package_pending_reads;
mod package_setup;
mod recovery;
mod replace_unmanaged;
mod repo_effects;
mod repo_effects_escaping;
mod sources_refresh_absent_manifest;
mod tauri_config;
mod updates_scope_error;
