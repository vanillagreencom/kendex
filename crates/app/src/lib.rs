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
mod marketplaces;
mod mine;
mod native;
mod packages;
mod paths;
pub mod recovery;
mod sources;
mod unsubscribe;
mod whole_file;
mod window;

use tauri_specta::{Builder, collect_commands};

pub fn specta_builder() -> Builder<tauri::Wry> {
    // The zoom range is a constant rather than a command: the slider needs
    // the same floor, ceiling, and step the settings file is held to, and
    // two copies of three numbers is two places for them to drift.
    Builder::<tauri::Wry>::new()
        .constant("ZOOM", kendex_core::settings::ZOOM)
        // The kinds a single package can be brought current on its own.
        // The app refuses the rest, so the surfaces that offer Update read
        // the same list rather than keeping their own.
        .constant(
            "PER_PACKAGE_UPDATE_KINDS",
            kendex_core::engine::PER_PACKAGE_UPDATE_KINDS,
        )
        .commands(collect_commands![
            commands::app_version,
            app_update::app_update_check,
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
            editor::update_manifest,
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
            packages::package_versions,
            packages::package_update,
            packages::updates_overview,
            packages::updates_refresh,
            packages::update_set_ignored,
            packages::package_set_rev,
            packages::package_diff,
            packages::package_fork,
            packages::package_fork_beside,
            packages::fork_rename,
            packages::apply_discard_edits,
            packages::package_files,
            packages::package_file,
            packages::package_readme,
            packages::package_meta,
            window::window_set_zoom,
            window::window_zoom_state,
            window::window_minimize,
            window::window_toggle_maximize,
            window::window_close,
        ])
}

/// Everything that must settle before the window opens: the old-name dirs
/// move first so recovery — and everything after it — reads the new ones.
/// A failed move is fatal to the launch, same as in the CLI: opening
/// anyway would write fresh state beside the stranded old files, and the
/// next launch would find both generations of the global scope and refuse
/// it forever.
pub fn prepare_launch(
    env: &kendex_core::env::Env,
) -> Result<Vec<String>, kendex_core::error::CoreError> {
    let moved = kendex_core::rename::migrate_global_dirs(env)?;
    let mut messages = moved.leftovers;
    messages.extend(recovery::recover_on_launch(env));
    Ok(messages)
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
            match prepare_launch(&env) {
                Ok(messages) => {
                    for message in messages {
                        let _ = writeln!(stderr, "launch: {message}");
                    }
                }
                // Opening with the move half-done would fork the library in
                // two, so the launch stops loudly instead of showing an app
                // whose state is about to become unrecoverable.
                Err(error) => panic!(
                    "kendex cannot start: moving your data from vstack2 to kendex failed ({error}). \
                     Starting anyway would split your library between the old and new locations. \
                     Fix the reported problem and launch again."
                ),
            }
            // Read after the migration, so the zoom comes from the settings
            // file the app is about to use rather than the one it replaced.
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
