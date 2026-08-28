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

/// Somewhere to put the path kendex approved, on whatever will perform the
/// replacement. The plugin keeps what it was handed private, so this side
/// of the handoff is the only side a test can watch.
trait ReplacementTarget: Sized {
    fn replace_at(self, path: &std::path::Path) -> Self;
}

impl ReplacementTarget for tauri_plugin_updater::UpdaterBuilder {
    fn replace_at(self, path: &std::path::Path) -> Self {
        self.executable_path(path)
    }
}

/// Hand over the path [`kendex_core::install_channel::for_app`] judged, so
/// the path that decides and the path that acts are one file. An install
/// carrying no path leaves the target on its own fallback.
fn aim_at_install<T: ReplacementTarget>(target: T, install: &AppInstall) -> T {
    match install.judged_path() {
        Some(path) => target.replace_at(path),
        None => target,
    }
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
    let install = app_install()?;
    kendex_core::install_channel::for_app(&install, &Host).allow_replacement()?;
    let update = aim_at_install(app.updater_builder(), &install)
        .build()
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

    /// Stands in for the updater builder, which keeps what it was handed
    /// private. What reaches it is what the plugin would have been given.
    #[derive(Default)]
    struct Recorder(Option<std::path::PathBuf>);

    impl ReplacementTarget for Recorder {
        fn replace_at(self, path: &std::path::Path) -> Self {
            Self(Some(path.to_owned()))
        }
    }

    /// The handoff itself. Everything else about this change can be right
    /// while the approved path never leaves `app_update_install`, and the
    /// plugin then falls back to rebuilding its own from the launch
    /// environment, which is the whole defect.
    #[test]
    fn the_approved_path_reaches_whatever_will_replace_it() {
        for install in [
            AppInstall::AppImage(Some("/home/pat/Apps/kendex.AppImage".into())),
            AppInstall::MacBundle("/Applications/kendex.app/Contents/MacOS/kendex".into()),
        ] {
            assert_eq!(
                aim_at_install(Recorder::default(), &install).0.as_deref(),
                install.judged_path(),
                "{install:?}"
            );
        }

        // Nothing to hand over, so the target keeps its own fallback.
        for install in [AppInstall::WindowsInstaller, AppInstall::AppImage(None)] {
            assert_eq!(
                aim_at_install(Recorder::default(), &install).0,
                None,
                "{install:?}"
            );
        }
    }

    /// Only the bundle is writable, so `for_app` can approve nothing else.
    struct OnlyWritable(&'static str);

    impl kendex_core::install_channel::HostProbe for OnlyWritable {
        fn replaceable(&self, path: &std::path::Path) -> bool {
            path == std::path::Path::new(self.0)
        }

        fn exists(&self, _: &std::path::Path) -> bool {
            false
        }

        fn resolve(&self, path: &std::path::Path) -> std::path::PathBuf {
            path.to_owned()
        }

        fn on_path(&self, _: &str) -> bool {
            false
        }

        fn os_release(&self) -> Option<String> {
            None
        }
    }

    /// The plugin decides for itself what to replace, deriving it from the
    /// path it is handed, so nothing kendex asserts about that path proves
    /// the two agree. This asks the plugin.
    ///
    /// Getting it wrong is not a failed update. The derived path is what the
    /// macOS installer removes before moving the new bundle in, escalating a
    /// permission error to a shell `rm -rf` under `with administrator
    /// privileges`. Hand over the bundle instead of the executable inside it
    /// and the plugin climbs one level further, to the directory holding
    /// every other app on the machine. The dependency is a caret range, so a
    /// minor bump can move this derivation under an unchanged kendex.
    #[test]
    fn the_plugin_derives_the_unit_for_app_approved() {
        let exe = "/Applications/kendex.app/Contents/MacOS/kendex";
        let bundle = "/Applications/kendex.app";
        let probe = OnlyWritable(bundle);
        let install = AppInstall::mac_bundle(&probe, std::path::Path::new(exe));
        assert_eq!(
            kendex_core::install_channel::for_app(&install, &probe),
            InstallChannel::Direct
        );

        let handed = install.judged_path().expect("a mac bundle carries a path");
        let derived = tauri_plugin_updater::extract_path_from_executable(handed)
            .expect("the plugin derives a path from an executable inside a bundle");
        // True on every platform the function compiles for, and the property
        // that matters: what the plugin acts on never escapes what kendex
        // approved.
        assert!(
            derived.starts_with(bundle),
            "plugin derived {} from {handed}, outside the approved {bundle}",
            derived.display(),
            handed = handed.display()
        );
        // Where the derivation runs for real it lands on the bundle exactly.
        #[cfg(target_os = "macos")]
        assert_eq!(derived, std::path::Path::new(bundle));
    }
}
