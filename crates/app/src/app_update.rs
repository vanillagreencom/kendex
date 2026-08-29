use kendex_core::app_update::AppUpdateView;
use kendex_core::env::Env;
use kendex_core::install_channel::{AppInstall, Host, InstallChannel};
use kendex_core::registry::{Fetch, ReleaseFeedFetch};
use kendex_core::release_digests::{ReleaseDigests, release_digests_url};
use kendex_core::update_channel::manifest_url_for;
use kendex_core::update_feed::{UPDATER_PUBLIC_KEY, signature_url};
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
        (true, None) | (false, _) => {
            kendex_core::update_channel::feed_url_for(env!("CARGO_PKG_VERSION")).to_owned()
        }
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

/// Where this build installs from, as the plugin wants it. `tauri.conf.json`
/// names the release channel so the plugin has a configured default, and a
/// test holds that entry to the same constant; handing the choice over on
/// every install is what keeps a release candidate on the channel core
/// already put its notice card on, instead of two files that agree only
/// while nobody edits one.
fn manifest_endpoint() -> Result<tauri::Url, String> {
    let url = manifest_url_for(env!("CARGO_PKG_VERSION"));
    tauri::Url::parse(url)
        .map_err(|error| format!("the update manifest URL {url} is unusable: {error}"))
}

/// The release's own statement about what it published for this target,
/// read from beside the manifest this build installs from and held to the
/// release the manifest offered.
///
/// The plugin verifies the signature the manifest carries over the bytes
/// it downloads, which proves they are a kendex release's and not which
/// one: nothing signs the manifest, so one that can be served or altered
/// can name a genuine older download, or another platform's, and that
/// signature checks out. The document names the release, the target and
/// the hash of each download, and is signed under the key this build
/// pins, so a download this release did not publish is refused.
fn published_for_this_target(version: &str) -> Result<ReleaseDigests, String> {
    read_published(UPDATER_PUBLIC_KEY, env!("KENDEX_TARGET"), version, |url| {
        let response = ReleaseFeedFetch
            .get(url, None)
            .map_err(|error| error.to_string())?;
        match response.status {
            200 => Ok(response.body),
            status => Err(format!("reading {url} answered {status}")),
        }
    })
}

/// The read itself. The key, the target and the transport are arguments
/// for the reason core's key is: a test holds a release it signed itself,
/// for a target it names, without reaching the network.
fn read_published(
    public_key: &str,
    target: &str,
    version: &str,
    read: impl Fn(&str) -> Result<Vec<u8>, String>,
) -> Result<ReleaseDigests, String> {
    let manifest = manifest_url_for(env!("CARGO_PKG_VERSION"));
    let url = release_digests_url(manifest, target).map_err(|error| error.to_string())?;
    let document = read(&url)?;
    let signature = read(&signature_url(&url))?;
    ReleaseDigests::for_release(public_key, &document, &signature, version, target)
        .map_err(|error| error.to_string())
}

/// Replace this install with the latest release and relaunch into it. The
/// manifest names a download and the signature over it; the release's own
/// digests document names which download this release published for this
/// target, and the bytes are held to both before anything is installed.
/// The discovery feed never supplies an install URL. A failure leaves the
/// running app untouched and usable.
#[tauri::command]
#[specta::specta]
pub async fn app_update_install(app: tauri::AppHandle) -> Result<(), String> {
    // The notice offers this on no other channel; the command asks anyway,
    // so nothing a caller gets wrong can overwrite a package manager's files.
    let install = app_install()?;
    kendex_core::install_channel::for_app(&install, &Host).allow_replacement()?;
    let update = aim_at_install(app.updater_builder(), &install)
        .endpoints(vec![manifest_endpoint()?])
        .map_err(|error| error.to_string())?
        // What is left here after the cask fix is the app failing to place
        // itself. The plugin's own text for that is a bare io error, which
        // names no doer and no stage.
        .build()
        .map_err(|error| format!("kendex could not start an update for this install: {error}"))?
        .check()
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "this build is already the latest release".to_owned())?;
    // Downloaded, then judged, then installed: the plugin's own check runs
    // on the way down, and what this release published for this target is
    // what says those bytes are the ones the version being installed
    // names. The read is blocking, so it runs off the async runtime.
    let bytes = update
        .download(|_chunk, _total| {}, || {})
        .await
        .map_err(|error| error.to_string())?;
    let offered = update.version.clone();
    let digests = tauri::async_runtime::spawn_blocking(move || published_for_this_target(&offered))
        .await
        .map_err(|error| format!("kendex could not read what this release published: {error}"))??;
    digests
        .verify_app(&bytes)
        .map_err(|error| error.to_string())?;
    update.install(bytes).map_err(|error| error.to_string())?;
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
mod tests;
