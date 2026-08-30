mod account;
mod app_settings;
mod app_update;
pub mod audit;
mod commands;
mod community;
mod editor;
// Nothing outside Linux reaches this: the fixes it decides are for GTK
// and for how the Linux app is packaged.
#[cfg(target_os = "linux")]
mod launch_env;
pub mod marketplaces;
mod mine;
mod native;
mod packages;
mod paths;
pub mod recovery;
pub mod repo_effects;
pub mod sources;
mod unsubscribe;
mod update_check;
mod whole_file;
mod window;

use tauri_specta::{Builder, collect_commands};

/// Values the UI reads instead of keeping a second copy of.
fn constants(builder: Builder<tauri::Wry>) -> Builder<tauri::Wry> {
    // The zoom range is a constant rather than a command: the slider needs
    // the same floor, ceiling, and step the settings file is held to, and
    // two copies of three numbers is two places for them to drift.
    builder.constant("ZOOM", kendex_core::settings::ZOOM)
}

pub fn specta_builder() -> Builder<tauri::Wry> {
    constants(Builder::<tauri::Wry>::new()).commands(collect_commands![
        commands::app_version,
        app_update::app_update_check,
        app_update::app_update_channel,
        app_update::app_update_command_channel,
        app_update::app_update_install,
        commands::scan_machine,
        app_settings::get_settings,
        app_settings::update_settings,
        app_settings::save_zoom,
        app_settings::register_project,
        app_settings::unregister_project,
        app_settings::project_offers,
        commands::install_drift_hook,
        app_settings::discover_projects,
        commands::capability_table,
        commands::report_route,
        audit::audit_all,
        audit::apply_plan,
        audit::adopt_item,
        audit::replace_unmanaged_item,
        audit::toggle_item,
        audit::remove_item,
        editor::get_manifest,
        editor::get_scope_settings,
        editor::save_customize,
        editor::editor_inventory,
        editor::custom_hook_deliveries,
        editor::item_source,
        native::pick_folder,
        native::reveal_path,
        native::open_in_editor,
        native::open_url,
        sources::sources_overview,
        sources::source_add,
        sources::source_remove,
        sources::source_toggle,
        sources::sources_refresh,
        sources::bundles_overview,
        sources::bundle_install,
        marketplaces::marketplaces_overview,
        marketplaces::marketplace_packages,
        marketplaces::marketplace_summary,
        marketplaces::marketplace_bundle,
        marketplaces::marketplace_package_preview,
        marketplaces::marketplace_package_file,
        marketplaces::install::marketplace_install,
        marketplaces::install::install_targets,
        repo_effects::repo_effects_apply,
        marketplaces::marketplace_subscribe,
        unsubscribe::marketplace_unsubscribe_preview,
        unsubscribe::marketplace_unsubscribe,
        community::community_directory,
        community::community_skillssh_search,
        community::community_skillssh_leaderboard,
        community::community_skillssh_available,
        marketplaces::marketplace_about,
        marketplaces::library_provenance,
        mine::mine_list,
        mine::mine_use_existing,
        mine::mine_create,
        mine::mine_forget,
        mine::mine_import_inventory,
        mine::mine_import_apply,
        mine::mine_offer_manifest,
        mine::mine_offer_workflow,
        mine::mine_accept_manifest,
        mine::mine_accept_workflow,
        mine::mine_authoring_doc,
        account::account_status,
        account::account_login_start,
        account::account_login_poll,
        account::account_logout,
        account::mine_submit_preflight,
        account::mine_submit,
        account::mine_submissions,
        account::mine_submission_states,
        packages::package_versions,
        packages::update::package_update,
        packages::update::package_update_many,
        packages::update::package_set_rev,
        packages::package_diff,
        packages::package_fork,
        packages::package_fork_beside,
        packages::fork_rename,
        packages::apply_discard_edits,
        packages::package_files,
        packages::package_file,
        packages::package_readme,
        packages::package_meta,
        update_check::updates_overview,
        update_check::updates_refresh,
        update_check::update_set_ignored,
        window::window_set_zoom,
        window::window_zoom_state,
        window::window_minimize,
        window::window_toggle_maximize,
        window::window_close,
    ])
}

/// Everything that must settle before the window opens: an apply the last
/// run left half-done is rolled back, and what that took is said out loud.
pub fn prepare_launch(env: &kendex_core::env::Env) -> Vec<String> {
    recovery::recover_on_launch(env)
}

trait StartupCoordinator {
    type Error;

    fn show_window(&self) -> Result<(), Self::Error>;
    fn schedule_update_check(&self);
}

fn complete_startup<C: StartupCoordinator>(coordinator: &C) -> Result<(), C::Error> {
    coordinator.show_window()?;
    coordinator.schedule_update_check();
    Ok(())
}

struct AppStartup<Show, Schedule> {
    show_window: Show,
    schedule_update_check: Schedule,
}

impl<Show, Schedule, Error> StartupCoordinator for AppStartup<Show, Schedule>
where
    Show: Fn() -> Result<(), Error>,
    Schedule: Fn(),
{
    type Error = Error;

    fn show_window(&self) -> Result<(), Self::Error> {
        (self.show_window)()
    }

    fn schedule_update_check(&self) {
        (self.schedule_update_check)();
    }
}

pub fn run() -> tauri::Result<()> {
    #[cfg(target_os = "linux")]
    launch_env::apply();
    use std::io::Write;
    let mut stderr = std::io::stderr();
    let mut zoom = kendex_core::settings::ZOOM.default;
    match kendex_core::env::Env::detect() {
        Ok(env) => {
            for message in prepare_launch(&env) {
                let _ = writeln!(stderr, "launch: {message}");
            }
            match kendex_core::settings::load(&env) {
                Ok(settings) => zoom = settings.zoom,
                Err(error) => {
                    let _ = writeln!(stderr, "settings unreadable, opening at full size: {error}");
                }
            }
        }
        Err(error) => {
            let _ = writeln!(stderr, "recovery skipped: {error}");
        }
    }
    let builder = specta_builder();
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(builder.invoke_handler())
        // The window is configured hidden, so this line is the only thing
        // that ever shows it. What it does to the window — the saved size
        // first, then the reveal — is asserted in `window`; that it is
        // wired up here is not, because tauri's mock runtime answers for a
        // window it never draws. Deleting the line leaves `zoom` with no
        // reader, which fails `clippy -D warnings`.
        .setup(move |app| {
            complete_startup(&AppStartup {
                show_window: || window::show_at_zoom(app, zoom),
                schedule_update_check: app_update::schedule_startup_check,
            })
        })
        .run(tauri::generate_context!())
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    #[test]
    fn real_startup_adapter_schedules_once_only_after_the_window_is_ready() {
        let scheduled = Cell::new(0);
        let ready = AppStartup {
            show_window: || Ok::<(), &'static str>(()),
            schedule_update_check: || scheduled.set(scheduled.get() + 1),
        };
        complete_startup(&ready).unwrap();
        assert_eq!(scheduled.get(), 1);

        let failed_scheduled = Cell::new(0);
        let failed = AppStartup {
            show_window: || Err::<(), _>("window failed"),
            schedule_update_check: || failed_scheduled.set(failed_scheduled.get() + 1),
        };
        assert_eq!(complete_startup(&failed), Err("window failed"));
        assert_eq!(failed_scheduled.get(), 0);
    }
}
