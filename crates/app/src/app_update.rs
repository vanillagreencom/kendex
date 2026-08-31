use std::path::{Path, PathBuf};

use kendex_core::app_update::AppUpdateStatus;
use kendex_core::command_update::{
    CommandBeside, CommandHalf, CommandNotice, bring_command_across, command_beside_app,
    command_candidates, recorded_command,
};
use kendex_core::env::Env;
use kendex_core::install_channel::{AppInstall, Host, InstallChannel};
use kendex_core::registry::{Fetch, ReleaseFeedFetch};
use kendex_core::release_digests::{ReleaseDigests, release_digests_url};
use kendex_core::update_channel::manifest_url_for;
use kendex_core::update_feed::{UPDATER_PUBLIC_KEY, signature_url};
use tauri_plugin_updater::UpdaterExt;

/// Core picks the channel off the running version, override rule included,
/// so the app and `kendex update` cannot end up reading different feeds.
fn feed_url() -> String {
    kendex_core::update_channel::feed_url(env!("CARGO_PKG_VERSION"))
}

fn check(refresh: bool) -> Result<AppUpdateStatus, String> {
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
            muted_version: settings.muted_app_notice.as_deref(),
        },
    )
    .map_err(|error| error.to_string())
}

/// Read the remembered app release status, refreshing it when requested or
/// when the six-hour automatic interval has elapsed.
#[tauri::command(async)]
#[specta::specta]
pub fn app_update_check(refresh: bool) -> Result<AppUpdateStatus, String> {
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

/// What the card has to say about the `kendex` command beside this app:
/// the channel that owns it where another installer does, the one command
/// that moves it where it is kendex's own but sits where this app cannot
/// write, and nothing where there is none or where Update now carries it
/// across itself.
///
/// Without this the app replaces itself, restarts, and clears its card
/// while the terminal command stays on the old release with nothing on
/// screen having said so — the silent divergence this issue was written
/// about, arrived at from the other side.
#[tauri::command(async)]
#[specta::specta]
pub fn app_update_command_channel() -> Result<Option<CommandNotice>, String> {
    let env = Env::detect().map_err(|error| error.to_string())?;
    let beside = command_beside(&env, &app_install()?, std::env::var_os("PATH").as_deref());
    Ok(CommandNotice::for_card(&beside))
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

/// Whatever will write the downloaded bytes over this install. The plugin
/// does that behind a method of its own, so this is the only side of the
/// handoff a test can watch — and the one thing every install has to pass
/// through on its way there is below.
trait Installer {
    fn place(&self, bytes: Vec<u8>) -> Result<(), String>;
}

impl Installer for tauri_plugin_updater::Update {
    fn place(&self, bytes: Vec<u8>) -> Result<(), String> {
        self.install(bytes).map_err(|error| error.to_string())
    }
}

/// Write `bytes` only once this release's own document names them as the
/// download it published for this target. The plugin has already checked
/// the signature the manifest carried over them, which says they are a
/// kendex release's and not which one; this is what says they are the
/// release being installed. Bytes that fail it never reach `installer`.
fn install_published(
    digests: &ReleaseDigests,
    bytes: Vec<u8>,
    installer: &impl Installer,
) -> Result<(), String> {
    digests
        .verify_app(&bytes)
        .map_err(|error| error.to_string())?;
    installer.place(bytes)
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

/// The `kendex` command this app would carry across with it, if there is
/// one. `install.sh` puts the two side by side, so an app that moved alone
/// would leave every terminal on the old release; a dmg or msi that
/// installed no command has nothing to carry, which is an answer rather
/// than a failure.
fn command_beside(
    env: &Env,
    install: &AppInstall,
    path_var: Option<&std::ffi::OsStr>,
) -> CommandBeside {
    command_beside_app(
        &Host,
        &command_candidates(&env.home, path_var),
        &not_the_command(install, std::env::current_exe().ok()),
        recorded_command(env).as_ref(),
    )
}

/// What this process is, and what it is about to replace. Neither is ever
/// the command it carries across, and neither stands in for the other: an
/// AppImage's executable lives inside a mount that is not the image the
/// updater judged, and the Windows installer judges no path at all while
/// the desktop executable is `kendex.exe`, the name the command carries
/// too. Excluded only by the updater's path, a Windows install whose
/// directory is on `PATH` would take its own executable for the command.
fn not_the_command(install: &AppInstall, running: Option<PathBuf>) -> Vec<PathBuf> {
    running
        .into_iter()
        .chain(install.judged_path().map(Path::to_owned))
        .collect()
}

/// Run the command half off the async runtime: it downloads a release
/// binary over the network, which is not work to hold a runtime worker on.
///
/// Answers what the card would say about the command this run found, so
/// the caller can hold it against what the card said when it was drawn.
/// The lookup runs again here, so the two can disagree: a card is on
/// screen for as long as a person leaves it there, and what is at a path
/// in that time is not this app's to control.
async fn move_the_command(
    install: AppInstall,
    release: String,
) -> Result<(CommandHalf, Option<CommandNotice>), String> {
    let feed = feed_url();
    tauri::async_runtime::spawn_blocking(move || {
        let env = Env::detect().map_err(|error| error.to_string())?;
        let beside = command_beside(&env, &install, std::env::var_os("PATH").as_deref());
        let half = bring_command_across(
            &beside,
            &feed,
            &release,
            env!("KENDEX_TARGET"),
            UPDATER_PUBLIC_KEY,
        )?;
        Ok((half, CommandNotice::for_card(&beside)))
    })
    .await
    .map_err(|error| format!("the kendex command half did not run: {error}"))?
}

/// What to say when the app half would not land. A command already across
/// leaves the machine split, but the app's own version is unchanged, so
/// the card still offers the release and pressing it again repeats both
/// halves rather than stopping at already-current.
fn app_half_failed(release: &str, half: CommandHalf, error: &str) -> String {
    match half {
        CommandHalf::Moved => format!(
            "the kendex command is on {release} and the desktop app is not: {error}; press Update now again to bring the app across"
        ),
        CommandHalf::Untouched => format!("the desktop app could not be replaced: {error}"),
    }
}

/// Replace this install with the latest release and relaunch into it,
/// carrying across a `kendex` command that is kendex's to replace. One
/// another installer owns stays where it is, named on the card before this
/// runs; `shown` is what that card said, so a command that changed since is
/// reported rather than acted on in silence — see
/// [`CommandNotice::not_as_shown`]. The manifest names a download and the
/// signature over it, the release's own digests document names what this
/// release published for this target, and the app's bytes are held to both.
/// The discovery feed never supplies an install URL, and the command's
/// bytes are held to the key the CLI holds them to. A failure leaves the
/// running app untouched and usable, and is the `Err` half alone: the
/// report is `Ok(Some(_))`, answered after both halves have landed and in
/// place of the restart, so a card carrying it is not calling a finished
/// update a failure. `Ok(None)` is the restart, which no caller lives to
/// read.
///
/// The command moves first. What this flow's notice card reads is the
/// app's own baked version, so the app is the state marker here and is
/// written last — the mirror of `kendex update`, where the command's baked
/// version is the marker and the command is written last. A command that
/// will not move therefore leaves both halves where they were and the card
/// still offering the release, where an app already replaced and relaunched
/// would report itself current and never come back for the command.
#[tauri::command]
#[specta::specta]
pub async fn app_update_install(
    app: tauri::AppHandle,
    shown: Option<CommandNotice>,
) -> Result<Option<String>, String> {
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
    let (half, found) = move_the_command(install, update.version.clone()).await?;
    // Downloaded, then judged, then installed: the plugin's own check runs
    // on the way down, and what this release published for this target says
    // those bytes are the version being installed. The read is blocking, so
    // it runs off the async runtime. Every failure from here names the
    // command half too — it has moved by now, and a bare app error would
    // report no update while the terminal answers the new version.
    let bytes = update
        .download(|_chunk, _total| {}, || {})
        .await
        .map_err(|error| app_half_failed(&update.version, half, &error.to_string()))?;
    let offered = update.version.clone();
    let read = tauri::async_runtime::spawn_blocking(move || published_for_this_target(&offered))
        .await
        .map_err(|error| format!("kendex could not read what this release published: {error}"))
        .and_then(|published| published);
    let digests = read.map_err(|error| app_half_failed(&update.version, half, &error))?;
    install_published(&digests, bytes, &update)
        .map_err(|error| app_half_failed(&update.version, half, &error))?;
    // Both halves have landed. The restart is what takes the card away, so
    // anything still owed about the command is owed before it — and the
    // card is left standing to carry it rather than restarting into a
    // version with nowhere left to say it.
    if let Some(unsaid) =
        CommandNotice::not_as_shown(&update.version, half, found.as_ref(), shown.as_ref())
    {
        return Ok(Some(unsaid));
    }
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
