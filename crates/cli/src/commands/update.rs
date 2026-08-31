use std::path::{Path, PathBuf};

use kendex_core::command_update::{fetch, record_command, replace_executable};
use kendex_core::env::Env;
use kendex_core::install_channel::{Host, HostProbe, InstallChannel, for_cli};
use kendex_core::release_digests::{ReleaseDigests, release_digests_url};
use kendex_core::update_feed::{
    ReleaseFeed, UPDATER_PUBLIC_KEY, VersionRelation, app_image_signature_url, app_image_url,
    release_notes_url, signature_url, verify_signature,
};

use super::{CliResult, out, say};

/// The release feed is parsed by core so the CLI and app accept one schema,
/// and core picks which feed off the running version so both shells follow
/// one channel — the override rule included.
fn feed_url() -> String {
    kendex_core::update_channel::feed_url(env!("CARGO_PKG_VERSION"))
}

/// The feed keys its assets by the build target, one per lane in
/// `.github/workflows/release.yml`; `build.rs` bakes it in from Cargo.
fn target_triple() -> &'static str {
    env!("KENDEX_TARGET")
}

pub fn run(env: &Env, force: bool) -> CliResult {
    // One resolve for the whole run: the path that decides which channel
    // this is has to be the path that gets written, or a command reached
    // through a link is judged by its target and replaced at the link.
    let current_exe = Host.resolve(&std::env::current_exe()?);
    let channel = for_cli(&current_exe, &Host);
    run_on(
        env,
        force,
        &feed_url(),
        &current_exe,
        &channel,
        UPDATER_PUBLIC_KEY,
        target_triple(),
    )
}

/// The update with everything it reads off this process handed to it: the
/// feed to ask, the command's own path, who owns that path, the key every
/// download is held to, and the target this build was made for. Which arm
/// a person lands on is the channel, and a package-managed one is the arm
/// no test can reach by running: `for_cli` judges the real `current_exe`,
/// which nothing here can place under `/usr` or a brew prefix. The key and
/// the target are arguments for the same reason core's key is — a test
/// holds a release it signed itself, for a target it names.
fn run_on(
    env: &Env,
    force: bool,
    feed_url: &str,
    current_exe: &Path,
    channel: &InstallChannel,
    public_key: &str,
    target: &str,
) -> CliResult {
    if let InstallChannel::Managed { manager, command } = channel {
        out(&format!(
            "this install came from {manager}; update it with:"
        ));
        out(&format!("  {command}"));
        return Ok(());
    }
    // Managed answered above with the one thing it has to say and an exit
    // code of zero. What is left here is Direct, which passes, or Unknown,
    // whose refusal core words for both shells.
    channel.allow_replacement()?;
    // The running command is at this path and is one of ours, which is the
    // one thing no lookup by name can establish. Recorded before anything
    // is fetched, so a machine that installed before this record existed
    // gains it from any run — including one that finds nothing to do — and
    // the desktop app can carry the command across from then on.
    if let Err(why) = record_command(env, current_exe) {
        say(&format!(
            "the desktop app will not update this command until it can be recorded: {why}"
        ));
    }
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
    let Some(asset) = feed.asset_for(target) else {
        out(&missing_asset_message(relation, latest, current, target)?);
        return Ok(());
    };

    say(&format!("updating {} → {}", current, latest));
    // The command's own baked version is the state marker for the whole
    // install, so it is the last thing written. Any failure before it
    // leaves the old command in place, the next run still reads the feed
    // as newer, and both halves are tried again instead of stopping at
    // already-up-to-date.
    //
    // What is settled before any download: where the app half stands, so a
    // machine that cannot take it stops here rather than after paying for
    // the bytes, and what this release published, so both halves are held
    // to it. The feed is the one input nothing signs — the version, the
    // target's asset URL and the host serving it are all whoever wrote it
    // to choose. The digests document is what makes that harmless: it is
    // the release's own statement, signed under a key baked into this
    // build, and it names the release, the target and the hash of each
    // download. A signature that is genuine over some other release's
    // artifact is refused here rather than written over the running
    // command.
    let app_half = app_half(env, latest, target, channel)?;
    let digests = release_digests(feed_url, target, latest, public_key)?;
    let binary = fetch(asset)?;
    let signature = fetch(&signature_url(asset))?;
    let app_replaced = match &app_half {
        Some(half) => {
            replace_app(half, latest, &digests, public_key)?;
            true
        }
        None => false,
    };
    let installed = install_verified(current_exe, &binary, &signature, public_key, |bytes| {
        digests.verify_command(bytes)
    });
    if let Err(error) = installed {
        return Err(command_failure(latest, app_replaced, &error).into());
    }
    out(&format!("updated to {latest}"));
    Ok(())
}

/// The release's own statement about what it published for this target,
/// read from beside the manifest the channel served and held to the
/// release the feed offered. Nothing names this document but the channel
/// and the running build, so a feed cannot point the check that judges it
/// somewhere else.
fn release_digests(
    feed_url: &str,
    target: &str,
    latest: &str,
    public_key: &str,
) -> Result<ReleaseDigests, String> {
    let url = release_digests_url(feed_url, target).map_err(|error| error.to_string())?;
    let document = fetch(&url)?;
    let signature = fetch(&signature_url(&url))?;
    ReleaseDigests::for_release(public_key, &document, &signature, latest, target)
        .map_err(|error| error.to_string())
}

/// What to say when the command itself could not be replaced. An app
/// already on the new release does leave the machine split, but the
/// command still reads older than the feed, so running it again repeats
/// both halves rather than stopping at already-up-to-date.
fn command_failure(latest: &str, app_replaced: bool, error: &str) -> String {
    match app_replaced {
        true => format!(
            "the desktop app is on {latest} and the kendex command is not: {error}; run kendex update again to bring the command across"
        ),
        false => format!("the kendex command could not be replaced: {error}"),
    }
}

/// The desktop app half of this update: where it sits and where its
/// download is published. Both URLs are built from the version the feed
/// was validated at, never from feed text.
struct AppHalf {
    path: PathBuf,
    url: String,
    signature_url: String,
}

/// Whether this machine has an app of ours to bring across, decided before
/// anything is downloaded. A machine with no app of ours is the whole
/// install already; a machine whose app cannot be replaced stops the run
/// here, with the old command still on disk, so neither half has moved.
fn app_half(
    env: &Env,
    latest: &str,
    target: &str,
    channel: &InstallChannel,
) -> Result<Option<AppHalf>, String> {
    // Nothing outside a direct install is ours to replace beyond the
    // command itself. Only the Linux AppImage is an install this command
    // made; every other platform's app arrives and updates by its own
    // route, and the CLI says nothing about one it did not put there.
    let InstallChannel::Direct = channel else {
        return Ok(None);
    };
    let to_url = |result: kendex_core::error::Result<Option<String>>| {
        result.map_err(|error| error.to_string())
    };
    let (Some(url), Some(signature_url)) = (
        to_url(app_image_url(latest, target))?,
        to_url(app_image_signature_url(latest, target))?,
    ) else {
        return Ok(None);
    };
    let path = env.app_image_file();
    if !Host.exists(&path) {
        out("no kendex desktop app here; the kendex command is the whole install");
        return Ok(None);
    }
    if !Host.replaceable(&path) {
        return Err(app_refused(
            latest,
            &format!("the directory holding {} refuses writes", path.display()),
        ));
    }
    Ok(Some(AppHalf {
        path,
        url,
        signature_url,
    }))
}

/// Bring the desktop app on this machine to the same release.
fn replace_app(
    half: &AppHalf,
    latest: &str,
    digests: &ReleaseDigests,
    public_key: &str,
) -> Result<(), String> {
    say(&format!(
        "updating the desktop app at {}",
        half.path.display()
    ));
    let image = fetch(&half.url)?;
    // The release job publishes each AppImage beside a minisign signature
    // over exactly those bytes. One that arrives without a signature, or
    // with one that does not check out, or that is not the download this
    // release published for this target, is refused rather than installed.
    let signature = fetch(&half.signature_url).map_err(|why| app_refused(latest, &why))?;
    install_verified(&half.path, &image, &signature, public_key, |bytes| {
        digests.verify_app(bytes)
    })
    .map_err(|why| app_refused(latest, &why))?;
    out(&format!("updated the desktop app to {latest}"));
    Ok(())
}

/// Write `bytes` over `path` only once `signature` checks out under
/// `public_key` and `published` recognizes them as the artifact this
/// release named — the signature makes them the release key's, and
/// `published` makes them this release's, for this target and this half.
/// Both halves of an update land through here — the desktop app and the
/// command itself — so neither is the half nothing checks.
fn install_verified(
    path: &Path,
    bytes: &[u8],
    signature: &[u8],
    public_key: &str,
    published: impl Fn(&[u8]) -> kendex_core::error::Result<()>,
) -> Result<(), String> {
    verify_signature(public_key, bytes, signature).map_err(|error| error.to_string())?;
    published(bytes).map_err(|error| error.to_string())?;
    replace_executable(path, bytes).map_err(|error| error.to_string())
}

/// The one sentence both app-half refusals say: the reason, then what the
/// next run does with it.
fn app_refused(latest: &str, why: &str) -> String {
    format!(
        "the desktop app was not brought to {latest}: {why}; nothing was updated, so kendex update will try both halves again"
    )
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

#[cfg(test)]
mod tests;
