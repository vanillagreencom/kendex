use std::path::{Path, PathBuf};
use std::time::Duration;

use kendex_core::env::Env;
use kendex_core::install_channel::{Host, HostProbe, InstallChannel, for_cli};
use kendex_core::names::shown;
use kendex_core::process::Hardened;
use kendex_core::update_feed::{
    RELEASE_FEED_URL, ReleaseFeed, UPDATER_PUBLIC_KEY, VersionRelation, app_image_signature_url,
    app_image_url, release_notes_url, verify_signature,
};

use super::{CliResult, out, say};

/// The release feed is parsed by core so the CLI and app accept one schema.
/// `KENDEX_UPDATE_FEED` overrides the URL so compat tests run against a
/// local fixture instead of the network.
fn feed_url() -> String {
    std::env::var("KENDEX_UPDATE_FEED").unwrap_or_else(|_| RELEASE_FEED_URL.to_owned())
}

/// The feed keys its assets by the build target, one per lane in
/// `.github/workflows/release.yml`; `build.rs` bakes it in from Cargo.
fn target_triple() -> &'static str {
    env!("KENDEX_TARGET")
}

fn fetch(url: &str) -> Result<Vec<u8>, String> {
    // This fetches release binaries as well as the small feed, so it needs
    // room for a slow download.
    let output = Hardened::curl(&curl_args(url))
        .timeout(Duration::from_secs(600))
        .run()
        .map_err(|e| format!("curl unavailable: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "fetching {url} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(output.stdout)
}

fn curl_args(url: &str) -> [&str; 10] {
    [
        "-fsS",
        "--location",
        "--max-redirs",
        "3",
        "--proto",
        "=https,file",
        "--proto-redir",
        "=https",
        "--",
        url,
    ]
}

pub fn run(env: &Env, force: bool) -> CliResult {
    // One resolve for the whole run: the path that decides which channel
    // this is has to be the path that gets written, or a command reached
    // through a link is judged by its target and replaced at the link.
    let current_exe = Host.resolve(&std::env::current_exe()?);
    let channel = for_cli(&current_exe, &Host);
    run_on(env, force, &feed_url(), &current_exe, &channel)
}

/// The update with everything it reads off this process handed to it: the
/// feed to ask, the command's own path, and who owns that path. Which arm a
/// person lands on is the channel, and a package-managed one is the arm no
/// test can reach by running: `for_cli` judges the real `current_exe`, which
/// nothing here can place under `/usr` or a brew prefix.
fn run_on(
    env: &Env,
    force: bool,
    feed_url: &str,
    current_exe: &Path,
    channel: &InstallChannel,
) -> CliResult {
    if let InstallChannel::Managed { command } = channel {
        out("a package manager owns this install; update it with:");
        out(&format!("  {command}"));
        return Ok(());
    }
    // Managed answered above with the one thing it has to say and an exit
    // code of zero. What is left here is Direct, which passes, or Unknown,
    // whose refusal core words for both shells.
    channel.allow_replacement()?;
    let feed_bytes = fetch(feed_url)?;
    let feed = ReleaseFeed::parse(&feed_bytes)?;
    let latest = feed.version.as_str();
    let current = env!("CARGO_PKG_VERSION");
    let relation = feed.relation_to(current)?;
    match relation {
        VersionRelation::Current if !force => {
            out(&format!("already up to date ({current})"));
            return Ok(());
        }
        VersionRelation::Older if !force => {
            return Err(format!(
                "release feed offers {latest}, older than installed {current}; use --force to downgrade"
            )
            .into());
        }
        VersionRelation::Older | VersionRelation::Current | VersionRelation::Newer => {}
    }
    let target = target_triple();
    let Some(asset) = feed.asset_for(target) else {
        out(&missing_asset_message(relation, latest, current, target)?);
        return Ok(());
    };

    say(&format!("updating {} → {}", shown(current), shown(latest)));
    // The command's own baked version is the state marker for the whole
    // install, so it is the last thing written. Any failure before it
    // leaves the old command in place, the next run still reads the feed
    // as newer, and both halves are tried again instead of stopping at
    // already-up-to-date. Its bytes are fetched first so a lost download
    // costs nothing that is already on disk.
    let binary = fetch(asset)?;
    let app_replaced = match channel {
        InstallChannel::Direct => update_app(env, latest)?,
        // Nothing here is ours to replace beyond the command itself.
        InstallChannel::Managed { .. } | InstallChannel::Unknown => false,
    };
    if let Err(error) = replace_executable(current_exe, &binary) {
        return Err(command_failure(latest, app_replaced, &error).into());
    }
    out(&format!("updated to {latest}"));
    Ok(())
}

/// What to say when the command itself could not be replaced. An app
/// already on the new release does leave the machine split, but the
/// command still reads older than the feed, so running it again repeats
/// both halves rather than stopping at already-up-to-date.
fn command_failure(latest: &str, app_replaced: bool, error: &std::io::Error) -> String {
    match app_replaced {
        true => format!(
            "the desktop app is on {latest} and the kendex command is not: {error}; run kendex update again to bring the command across"
        ),
        false => format!("the kendex command could not be replaced: {error}"),
    }
}

/// Bring the desktop app on this machine to the same release, answering
/// whether it replaced one. The URL is built from the version the feed was
/// validated at, never from feed text. A machine with no app of ours is
/// the whole install already; a machine whose app cannot be replaced stops
/// the run before the command moves, so neither half has.
fn update_app(env: &Env, latest: &str) -> Result<bool, Box<dyn std::error::Error>> {
    // Only the Linux AppImage is an install this command made. Every other
    // platform's app arrives and updates by its own route, and the CLI says
    // nothing about one it did not put there.
    let target = target_triple();
    let (Some(url), Some(signature_url)) = (
        app_image_url(latest, target)?,
        app_image_signature_url(latest, target)?,
    ) else {
        return Ok(false);
    };
    let path = env.app_image_file();
    if !Host.exists(&path) {
        out("no kendex desktop app here; the kendex command is the whole install");
        return Ok(false);
    }
    if !Host.replaceable(&path) {
        return Err(app_refused(
            latest,
            &format!("the directory holding {} refuses writes", path.display()),
        )
        .into());
    }
    say(&format!(
        "updating the desktop app at {}",
        shown(&path.display().to_string())
    ));
    let image = fetch(&url)?;
    // The release job publishes each AppImage beside a minisign signature
    // over exactly those bytes. One that arrives without a signature, or
    // with one that does not check out, is refused rather than installed.
    let signature = fetch(&signature_url).map_err(|why| app_refused(latest, &why))?;
    install_app_image(&path, &image, &signature, UPDATER_PUBLIC_KEY)
        .map_err(|why| app_refused(latest, &why))?;
    out(&format!("updated the desktop app to {latest}"));
    Ok(true)
}

/// Write the app only once `signature` checks out under `public_key`, so a
/// download that fails verification never reaches the installed path.
fn install_app_image(
    path: &Path,
    image: &[u8],
    signature: &[u8],
    public_key: &str,
) -> Result<(), String> {
    verify_signature(public_key, image, signature).map_err(|error| error.to_string())?;
    replace_executable(path, image).map_err(|error| error.to_string())
}

/// The one sentence both app-half refusals say: the reason, then what the
/// next run does with it.
fn app_refused(latest: &str, why: &str) -> String {
    format!(
        "the desktop app was not brought to {latest}: {why}; nothing was updated, so kendex update will try both halves again"
    )
}

/// Write `bytes` over an executable that may be running: the replacement
/// lands beside it whole and takes its place by rename, which every target
/// OS allows on a running file.
fn replace_executable(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let staged = staged_path(path);
    match stage(&staged, bytes).and_then(|()| std::fs::rename(&staged, path)) {
        Ok(()) => Ok(()),
        Err(error) => {
            // Nobody else writes a file named for this process, so a run
            // that failed takes its own away instead of leaving one behind
            // per process id.
            let _ = std::fs::remove_file(&staged);
            Err(error)
        }
    }
}

fn stage(staged: &Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(staged, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(staged, std::fs::Permissions::from_mode(0o755))?;
    }
    Ok(())
}

fn missing_asset_message(
    relation: VersionRelation,
    latest: &str,
    current: &str,
    target: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let notes = release_notes_url(latest)?;
    Ok(match relation {
        VersionRelation::Newer => {
            format!(
                "release {latest} is available with no asset for {target}; release notes: {notes}"
            )
        }
        VersionRelation::Current => format!(
            "release {latest} has no asset for {target}; installed version is unchanged; release notes: {notes}"
        ),
        VersionRelation::Older => format!(
            "release {latest} has no asset for {target}; installed {current} is newer; release notes: {notes}"
        ),
    })
}

/// The process id keeps two concurrent runs off one staged file. Without
/// it they share a name, and what the rename installs is whatever the other
/// run last wrote there rather than the bytes this one verified.
fn staged_path(current: &std::path::Path) -> PathBuf {
    let mut name = current
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "kendex".to_owned());
    name.push_str(&format!(".update.{}", std::process::id()));
    current.with_file_name(name)
}

#[cfg(test)]
mod tests;
