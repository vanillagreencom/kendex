//! The one harness kendex-cli's integration tests build as: every file
//! beside this one is a module of it, so the crate and its dependencies link
//! once rather than once per file. Cargo's autodiscovery is off in
//! Cargo.toml, so a new file under `tests/` is a `mod` line here;
//! `tools/test-roster` holds that roster.
//!
//! A file that stays its own `[[test]]` target says why beside its
//! declaration in Cargo.toml.

#[path = "../../test_util.rs"]
mod test_util;

// The support modules under `tests/support/`, each declared once.
#[path = "support/installer_message.rs"]
mod installer_message;
#[path = "support/pty.rs"]
mod pty;
#[path = "support/width.rs"]
mod width;

mod add_kinds;
mod add_picker_terminal;
mod add_setting;
mod apply_locked;
mod bookmark_cli;
mod bot_instructions_render;
mod bundles_cli;
mod catalog_check;
mod cli;
mod collection_cli;
mod command_inside_the_app;
mod command_record;
mod commit_offer_cli;
mod commit_offer_terminal;
mod compat;
mod deps_cli;
mod dev_sandbox;
mod fixture_git;
mod fixture_global_root;
mod guard_hooks;
mod haiku_model;
mod in_place_verbs;
mod index_cli;
mod install_registers_project;
mod install_script;
mod install_ux;
mod installer;
mod instruction_shims_cli;
mod lane_refresh;
mod lock_record;
mod marketplace_author;
mod marketplace_cli;
mod missing_remedy;
mod output_styles;
mod packaging_recipes;
mod pi_append_fallback;
mod pi_declared_both_scopes;
mod pi_extension_only_lock;
mod pi_shadow_package;
mod pi_staleness;
mod presentation;
mod project_path_target;
mod refresh_agent_cleanup;
mod refresh_fresh_clone;
mod refresh_ledger;
mod refresh_locked;
mod refresh_retired;
mod release_workflow;
mod remote_e2e;
mod remove_declared;
mod remove_locked;
mod safety_print;
mod skipped_on_conflict;
mod template_cli;
mod terms_first_run;
mod tier_model;
mod toggle;
mod toggle_locked;
mod trash_cli;
mod unmanaged;
mod unmanaged_copy_check;
mod unmanaged_exits;
mod unmanaged_names;
mod update_pi;
mod verify_adopted_workflows;
mod verify_at_record;
mod verify_base_owned;
mod verify_excluded_members;
mod verify_hook_pins;
mod verify_hook_switch;
mod verify_records;
mod verify_tracked_outputs;
