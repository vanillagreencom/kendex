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
pub mod recovery;
pub mod repo_effects;
mod scopes;
pub mod sources;
pub mod unsubscribe;
pub mod update_check;
mod whole_file;
mod window;

// Declared once for the whole lib test tree. Two `#[cfg(test)]` modules used
// to `#[path]`-include the file separately, which is one module compiled twice
// under two names; every `use` of it now names this one.
#[cfg(test)]
#[path = "../../test_util.rs"]
mod test_util;

use tauri_specta::{Builder, collect_commands};

/// Values the UI reads instead of keeping a second copy of.
fn constants(builder: Builder<tauri::Wry>) -> Builder<tauri::Wry> {
    // The zoom range is a constant rather than a command: the slider needs
    // the same floor, ceiling, and step the settings file is held to, and
    // two copies of three numbers is two places for them to drift.
    let builder = builder.constant("ZOOM", kendex_core::settings::ZOOM);
    // The schema the editor mints into a draft for a scope with no
    // manifest yet. `save::check` validates that draft before the plan's
    // `manifest::save` would stamp anything, so a second copy of this
    // number in the UI is a first save refused by its own validator.
    builder.constant("MANIFEST_SCHEMA", kendex_core::manifest::MANIFEST_SCHEMA)
}

/// The runtime the generated bindings call every `Result`-returning command
/// through, replacing the one tauri-specta ships. That one rethrows an
/// `Error`, which is what `__TAURI_INVOKE` rejects with when the transport
/// fails rather than when the command refuses — so a caller that fires its
/// write and forgets it dropped the rejection: the busy flag fell, nothing
/// was said, and the click read as having done nothing. Folded here, a
/// transport failure lands in the shape every caller already reads a
/// refusal in.
///
/// A command returning a plain value gets no wrapper, tauri-specta emitting
/// one only where there is a refusal type to name: `app_version`,
/// `capability_table`, `mine_authoring_doc` and `window_zoom_state` reject
/// to their callers as before, so a fire-and-forget read of one still drops
/// its rejection. Nothing in `specta_builder` can reach them.
///
/// `E | string` in the signature is what holds a reader honest: the fold
/// puts a bare message in the `E` slot, and declaring that widening is what
/// makes `tsc` name every reader branching on a discriminant the runtime no
/// longer guarantees. Read the refusal through `ui/src/lib/refusal.ts`
/// rather than off its fields — `refusalKind` still branches on the kind,
/// it just answers `null` where a shape never arrived. The words a
/// rejection with nothing to say falls back to are `NO_REASON_GIVEN` in
/// `ui/src/lib/settled.ts`, which folds the same failure for work that is
/// not a command; `ui/src/bindings.test.ts` holds this copy to those words.
const TYPED_ERROR_IMPL: &str = r#"async function typedError<T, E>(result: Promise<T>): Promise<{ status: "ok"; data: T } | { status: "error"; error: E | string }> {
    try {
        return { status: "ok", data: await result };
    } catch (e) {
        if (e instanceof Error) {
            const message = e.message === "" ? "Something went wrong, but no reason was given" : e.message;
            return { status: "error", error: message as any };
        }
        return { status: "error", error: e as any };
    }
}"#;

pub fn specta_builder() -> Builder<tauri::Wry> {
    let builder = constants(Builder::<tauri::Wry>::new()).commands(collect_commands![
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
        native::pick_folder,
        native::reveal_path,
        native::open_in_editor,
        native::open_url,
        sources::source_toggle,
        sources::sources_refresh,
        marketplaces::marketplaces_overview,
        marketplaces::marketplace_packages,
        marketplaces::marketplace_summary,
        marketplaces::marketplace_bundle,
        marketplaces::marketplace_bundles,
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
        packages::update::package_update,
        packages::update::package_update_many,
        packages::update::package_set_rev,
        packages::package_diff,
        packages::package_fork,
        packages::package_fork_beside,
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
    ]);
    builder.typed_error_impl(TYPED_ERROR_IMPL)
}

/// Everything that must settle before the window opens: an apply the last
/// run left half-done is rolled back, and what that took is said out loud.
pub fn prepare_launch(env: &kendex_core::env::Env) -> Vec<String> {
    recovery::recover_on_launch(env)
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
        // window it never draws. The release check waits on the `?`: a
        // window that never opened has nowhere to put a notice.
        .setup(move |app| {
            window::show_at_zoom(app, zoom)?;
            app_update::schedule_startup_check();
            Ok(())
        })
        .run(tauri::generate_context!())
}
