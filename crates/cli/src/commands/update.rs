use std::path::{Path, PathBuf};
use std::time::Duration;

use kendex_core::env::Env;
use kendex_core::install_channel::{Host, HostProbe, InstallChannel, for_cli};
use kendex_core::names::shown;
use kendex_core::process::Hardened;
use kendex_core::update_feed::{
    RELEASE_FEED_URL, ReleaseFeed, VersionRelation, app_image_url, release_notes_url,
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
    if let InstallChannel::Managed { command } = &channel {
        out("a package manager owns this install; update it with:");
        out(&format!("  {command}"));
        return Ok(());
    }
    // Managed answered above with the one thing it has to say and an exit
    // code of zero. What is left here is Direct, which passes, or Unknown,
    // whose refusal core words for both shells.
    channel.allow_replacement()?;
    let feed_bytes = fetch(&feed_url())?;
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
    if let Err(error) = replace_executable(&current_exe, &binary) {
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
    let Some(url) = app_image_url(latest, target_triple())? else {
        return Ok(false);
    };
    let path = env.app_image_file();
    if !Host.exists(&path) {
        out("no kendex desktop app here; the kendex command is the whole install");
        return Ok(false);
    }
    if !Host.replaceable(&path) {
        return Err(format!(
            "the desktop app at {} cannot be replaced, because that directory refuses writes; nothing was updated, so kendex update will try both halves again",
            path.display()
        )
        .into());
    }
    say(&format!(
        "updating the desktop app at {}",
        shown(&path.display().to_string())
    ));
    let image = fetch(&url)?;
    replace_executable(&path, &image)?;
    out(&format!("updated the desktop app to {latest}"));
    Ok(true)
}

/// Write `bytes` over an executable that may be running: the replacement
/// lands beside it whole and takes its place by rename, which every target
/// OS allows on a running file.
fn replace_executable(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let staged = staged_path(path);
    std::fs::write(&staged, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&staged, path)
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

fn staged_path(current: &std::path::Path) -> PathBuf {
    let mut name = current
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "kendex".to_owned());
    name.push_str(".update");
    current.with_file_name(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fetched_urls_are_always_positional_arguments() {
        assert_eq!(
            curl_args("--output=/tmp/owned"),
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
                "--output=/tmp/owned",
            ]
        );
    }

    /// The one skew this order can still leave is an app already across
    /// and a command that would not move. It is not a dead end — the
    /// command's version is unchanged, so the next run reads newer and
    /// repeats both halves — and the message has to say so rather than
    /// leave a bare io error to be read as total failure.
    #[test]
    fn a_command_that_would_not_move_says_whether_the_app_went_without_it() {
        let error = || std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        let split = command_failure("5.1.0", true, &error());
        assert!(split.contains("the desktop app is on 5.1.0"), "{split}");
        assert!(split.contains("run kendex update again"), "{split}");

        let neither = command_failure("5.1.0", false, &error());
        assert!(!neither.contains("desktop app"), "{neither}");
    }

    #[test]
    fn missing_asset_message_never_calls_current_or_older_available() {
        let current =
            missing_asset_message(VersionRelation::Current, "5.0.1", "5.0.1", "x").unwrap();
        let older = missing_asset_message(VersionRelation::Older, "5.0.0", "5.0.1", "x").unwrap();
        let newer = missing_asset_message(VersionRelation::Newer, "5.1.0", "5.0.1", "x").unwrap();
        assert!(current.contains("unchanged") && !current.contains("is available"));
        assert!(older.contains("is newer") && !older.contains("is available"));
        assert!(newer.contains("is available"));
    }
}
