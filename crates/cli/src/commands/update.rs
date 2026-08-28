use std::path::{Path, PathBuf};
use std::time::Duration;

use kendex_core::env::Env;
use kendex_core::install_channel::{Host, HostProbe, InstallChannel, for_cli};
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

    say(&format!("updating {current} → {latest}"));
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
    say(&format!("updating the desktop app at {}", path.display()));
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

    /// A throwaway minisign keypair signing `SIGNED_IMAGE`, so the admitted
    /// arm runs the real check rather than a stub standing in for it.
    const TEST_KEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDk0QUI0NzI3RTVDMTVCODEKUldTQlc4SGxKMGVybEhxeFovbTJ3U1phMng4aE9VTXByV09pUVRFVFNKbFZ5aWxtUTAvVGgyWEwK";
    const TEST_SIGNATURE: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHJzaWduIHNlY3JldCBrZXkKUlVTQlc4SGxKMGVybElTMUxrbkMyQ0tBWGlnejY1S0xLekovK0tBYllNdkdJTVU0bitTSjRBSCt1RlpwWnZkRHNKcWFTSHVoeStIQkpyVDlOaVRIMmROWVVSb21mMVBVRmd3PQp0cnVzdGVkIGNvbW1lbnQ6IGtlbmRleCB0ZXN0CnpKSnpYYnBtODZYRW40eHgxSTVkeG5YdktxT0k5ZXdmSkEyMkdtZXpreGgwbUNJZysybkJ2cGowUXZ6N2c3RHA4TEZBVXVBQUVMRExuUzFuaVpsaUF3PT0K";
    const SIGNED_IMAGE: &[u8] = b"kendex AppImage bytes";

    /// A path with something already installed at it, so every arm can say
    /// whether the bytes there moved.
    fn installed_app(dir: &tempfile::TempDir) -> PathBuf {
        let path = dir.path().join("kendex.AppImage");
        std::fs::write(&path, b"the app already here").unwrap();
        path
    }

    /// The admitted arm: a signature that checks out puts the download in
    /// place and leaves no staged file behind.
    #[test]
    fn an_app_image_whose_signature_checks_out_is_written() {
        let dir = tempfile::tempdir().unwrap();
        let installed = installed_app(&dir);

        install_app_image(
            &installed,
            SIGNED_IMAGE,
            TEST_SIGNATURE.as_bytes(),
            TEST_KEY,
        )
        .unwrap();

        assert_eq!(std::fs::read(&installed).unwrap(), SIGNED_IMAGE);
        assert!(!staged_path(&installed).exists());
    }

    /// The refused arm, driven by both shapes a bad download takes: bytes
    /// the signature does not cover, and a body that is no signature at
    /// all. Either way the installed app is exactly as it was.
    #[test]
    fn an_app_image_that_fails_verification_is_never_written() {
        let dir = tempfile::tempdir().unwrap();
        let installed = installed_app(&dir);

        let tampered =
            install_app_image(&installed, b"tampered", TEST_SIGNATURE.as_bytes(), TEST_KEY)
                .unwrap_err();
        assert!(
            tampered.contains("signature verification failed"),
            "{tampered}"
        );

        let malformed =
            install_app_image(&installed, SIGNED_IMAGE, b"not a signature", TEST_KEY).unwrap_err();
        assert!(malformed.contains("not base64"), "{malformed}");

        assert_eq!(std::fs::read(&installed).unwrap(), b"the app already here");
        assert!(!staged_path(&installed).exists());
    }

    /// Two runs sharing one staged path would each rename the other's bytes
    /// into place, so the name carries the process id. It stays a sibling
    /// of the target, since a rename cannot cross filesystems.
    #[test]
    fn the_staged_file_is_a_sibling_named_for_this_process() {
        let target = Path::new("/opt/kendex/kendex.AppImage");
        let staged = staged_path(target);
        assert_eq!(staged.parent(), target.parent());
        let suffix = format!(".update.{}", std::process::id());
        assert!(
            staged.to_string_lossy().ends_with(&suffix),
            "{}",
            staged.display()
        );
    }

    /// A run whose rename cannot land takes its own staged file away, or
    /// the directory collects one per process id that ever tried.
    #[test]
    fn a_replacement_that_cannot_land_leaves_no_staged_file() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("kendex.AppImage");
        std::fs::create_dir(&target).unwrap();

        assert!(replace_executable(&target, b"bytes").is_err());
        assert!(!staged_path(&target).exists());
    }

    /// Both app-half refusals promise the same thing, so the sentence is
    /// asserted where it is written rather than at each caller.
    #[test]
    fn a_refused_app_half_names_the_release_the_reason_and_the_retry() {
        let said = app_refused("5.1.0", "the directory holding /opt/kendex refuses writes");
        assert!(said.contains("5.1.0"), "{said}");
        assert!(said.contains("refuses writes"), "{said}");
        assert!(said.contains("nothing was updated"), "{said}");
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
