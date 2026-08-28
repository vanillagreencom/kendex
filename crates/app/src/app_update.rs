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
        Ok(AppInstall::AppImage(
            std::env::var_os("APPIMAGE").map(std::path::PathBuf::from),
        ))
    }
    #[cfg(target_os = "macos")]
    {
        std::env::current_exe()
            .map(AppInstall::MacBundle)
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

/// Replacing files in place is only ever ours to do on a direct install.
/// The notice already offers this on no other channel; the command refuses
/// on its own so nothing a caller gets wrong can overwrite a package
/// manager's files.
fn allow_replacement(channel: InstallChannel) -> Result<(), String> {
    match channel {
        InstallChannel::Direct => Ok(()),
        InstallChannel::Managed { command } => Err(format!(
            "a package manager owns this install; update it with: {command}"
        )),
        InstallChannel::Unknown => Err(
            "kendex cannot tell how this copy was installed, so it will not replace it".to_owned(),
        ),
    }
}

/// Replace this install with the latest release and relaunch into it. The
/// separately signed updater manifest is the delivery path and verifies
/// itself; the discovery feed never supplies an install URL. A failure
/// leaves the running app untouched and usable.
#[tauri::command]
#[specta::specta]
pub async fn app_update_install(app: tauri::AppHandle) -> Result<(), String> {
    allow_replacement(kendex_core::install_channel::for_app(
        &app_install()?,
        &Host,
    ))?;
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

    /// The one action that writes over an install refuses every channel
    /// but the one kendex owns, and says what to run instead.
    #[test]
    fn in_place_replacement_is_refused_off_a_direct_install() {
        assert_eq!(allow_replacement(InstallChannel::Direct), Ok(()));
        let managed = allow_replacement(InstallChannel::Managed {
            command: "paru -S kendex-bin".to_owned(),
        });
        assert_eq!(
            managed,
            Err(
                "a package manager owns this install; update it with: paru -S kendex-bin"
                    .to_owned()
            )
        );
        assert!(allow_replacement(InstallChannel::Unknown).is_err());
    }

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
