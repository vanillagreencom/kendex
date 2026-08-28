use kendex_core::app_update::AppUpdateView;
use kendex_core::env::Env;
use kendex_core::install_channel::{AppInstall, Host, InstallChannel};
use kendex_core::registry::ReleaseFeedFetch;
use tauri_plugin_updater::UpdaterExt;

fn feed_url() -> String {
    #[cfg(debug_assertions)]
    {
        selected_feed(std::env::var("KENDEX_UPDATE_FEED").ok(), true)
    }
    #[cfg(not(debug_assertions))]
    {
        selected_feed(None, false)
    }
}

fn selected_feed(override_url: Option<String>, debug_build: bool) -> String {
    match (debug_build, override_url) {
        (true, Some(url)) => url,
        (true, None) | (false, _) => kendex_core::update_feed::RELEASE_FEED_URL.to_owned(),
    }
}

fn check(refresh: bool) -> Result<AppUpdateView, String> {
    let env = Env::detect().map_err(|error| error.to_string())?;
    let settings = kendex_core::settings::load(&env).map_err(|error| error.to_string())?;
    kendex_core::app_update::check(
        &env,
        &ReleaseFeedFetch,
        kendex_core::app_update::CheckRequest {
            current_version: env!("CARGO_PKG_VERSION"),
            target: env!("KENDEX_TARGET"),
            feed_url: &feed_url(),
            refresh,
            automatic_check_enabled: settings.auto_update_check,
            muted_version: settings.muted_app_notice.as_deref(),
        },
    )
    .map_err(|error| error.to_string())
}

/// Read the remembered app release status, refreshing it when requested or
/// when the six-hour automatic interval has elapsed.
#[tauri::command(async)]
#[specta::specta]
pub fn app_update_check(refresh: bool) -> Result<AppUpdateView, String> {
    check(refresh)
}

/// What the running build is, in the terms its platform's rules read. This
/// is the one place the app decides which platform it is on; core holds the
/// rules for all three.
fn app_install() -> Result<AppInstall, String> {
    #[cfg(target_os = "linux")]
    {
        // Both variables are inherited by everything an AppImage-launched
        // terminal starts, so core places this executable rather than
        // taking either at its word.
        let exe = std::env::current_exe().ok();
        Ok(AppInstall::from_appimage_env(
            &Host,
            std::env::var_os("APPIMAGE").as_deref(),
            std::env::var_os("APPDIR").as_deref(),
            exe.as_deref(),
        ))
    }
    #[cfg(target_os = "macos")]
    {
        std::env::current_exe()
            .map(|exe| AppInstall::mac_bundle(&Host, &exe))
            .map_err(|error| format!("the running app's own path is unreadable: {error}"))
    }
    #[cfg(target_os = "windows")]
    {
        Ok(AppInstall::WindowsInstaller)
    }
}

/// Who owns the running bytes, so the notice offers the one action that can
/// work on this machine.
#[tauri::command(async)]
#[specta::specta]
pub fn app_update_channel() -> Result<InstallChannel, String> {
    Ok(kendex_core::install_channel::for_app(
        &app_install()?,
        &Host,
    ))
}

/// Replace this install with the latest release and relaunch into it. The
/// separately signed updater manifest is the delivery path and verifies
/// itself; the discovery feed never supplies an install URL. A failure
/// leaves the running app untouched and usable.
#[tauri::command]
#[specta::specta]
pub async fn app_update_install(app: tauri::AppHandle) -> Result<(), String> {
    // The notice offers this on no other channel; the command asks anyway,
    // so nothing a caller gets wrong can overwrite a package manager's files.
    kendex_core::install_channel::for_app(&app_install()?, &Host).allow_replacement()?;
    let update = app
        .updater()
        .map_err(|error| error.to_string())?
        .check()
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "this build is already the latest release".to_owned())?;
    update
        .download_and_install(|_chunk, _total| {}, || {})
        .await
        .map_err(|error| error.to_string())?;
    app.restart()
}

/// The launch does not wait for network or cache I/O. The first command call
/// reuses the generation this task writes instead of starting another fetch.
pub fn schedule_startup_check() {
    tauri::async_runtime::spawn_blocking(|| {
        if let Err(error) = check(false) {
            use std::io::Write;
            let _ = writeln!(std::io::stderr(), "app update check failed: {error}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_debug_builds_accept_a_feed_override() {
        let fixture = "file:///fixtures/feed.json".to_owned();
        assert_eq!(selected_feed(Some(fixture.clone()), true), fixture);
        assert_eq!(
            selected_feed(Some(fixture), false),
            kendex_core::update_feed::RELEASE_FEED_URL
        );
    }
}
