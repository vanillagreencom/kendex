//! Bringing an installed kendex binary to a release: the download, the
//! signature check, the write, and the command half of a family update.
//!
//! Both shells drive one release across the desktop app and a `kendex`
//! command that is kendex's to replace, and both write the half that is
//! their own state marker last. For `kendex update` that is the command,
//! whose baked version the next run reads to decide whether it is done;
//! for the app it is the app, whose baked version the sidebar card reads.
//!
//! A command another installer owns is not carried, and that is not a
//! failure — those bytes are that installer's to move. It is never left
//! in silence either: `kendex update` names the owning command and stops,
//! and the app's card names it before Update now is pressed, because
//! afterwards the app has restarted and there is no card to say it on.
//!
//! Neither shell moves the two halves atomically, and neither claims to.
//! A failure before the marker leaves both where they were. A failure
//! while writing the marker leaves the pair split, one half across and
//! one not, and every caller here reports that rather than hiding it —
//! `app_half_failed` in the app, `command_failure` in the CLI.
//!
//! What the ordering buys is which half is left behind. The marker is the
//! one still reading old, so the next attempt reads a release newer than
//! itself and moves both halves again, instead of stopping at
//! already-current with the other half stranded on the old version.

use std::cmp::Ordering;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use semver::Version;

use crate::install_channel::{HostProbe, InstallChannel, for_cli};
use crate::process::Hardened;
use crate::update_feed::{ReleaseFeed, signature_url, verify_signature};

/// What `install.sh` installs the command as. Windows has no command
/// beside the app — the installer carries the app alone — so the name
/// there only ever fails to exist.
#[cfg(windows)]
const COMMAND_NAME: &str = "kendex.exe";
#[cfg(not(windows))]
const COMMAND_NAME: &str = "kendex";

/// The command binary a running desktop app would bring across with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandBeside {
    /// A `kendex` command whose bytes this install may replace.
    Ours(PathBuf),
    /// A `kendex` command another installer owns, carrying the channel
    /// that names who. Those bytes are that installer's to move, so the
    /// app updates itself alone — and has to say so, because an app that
    /// moves while the command stays put is the divergence this whole
    /// path exists to prevent.
    NotOurs(InstallChannel),
    /// No `kendex` command beside the app — a dmg or msi install, where
    /// the app is the whole install. An answer, not a failure.
    Absent,
}

/// Whether the command half of a family update moved, which is the whole
/// difference between the two sentences a failed app half gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandHalf {
    Moved,
    Untouched,
}

/// The two directories `install.sh` chooses its `bindir` between: the
/// first already on `PATH`, or the first of the pair when neither is.
///
/// The script is the source of that choice and this is its only spelling
/// in Rust. `crates/cli/tests/install_script.rs` reads the list out of the
/// script itself and fails when the two drift, so a change of destination
/// there cannot quietly leave app-driven updates unable to find the
/// command on a machine whose launcher `PATH` omits it.
const INSTALLER_HOME_BIN: &str = ".local/bin";
const INSTALLER_SYSTEM_BIN: &str = "/usr/local/bin";

/// Where the `kendex` command may be, in the order a shell resolves it:
/// everything on `PATH` first, then the two directories `install.sh`
/// chooses between. Reading `PATH` first is what makes the command a
/// family update replaces the one `kendex --version` answers from; the
/// two additions cover a desktop launcher whose `PATH` never picked up
/// `~/.local/bin`.
pub fn command_candidates(home: &Path, path_var: Option<&OsStr>) -> Vec<PathBuf> {
    let on_path = path_var
        .into_iter()
        .flat_map(std::env::split_paths)
        .map(|dir| dir.join(COMMAND_NAME));
    let install_sh = [
        home.join(INSTALLER_HOME_BIN).join(COMMAND_NAME),
        Path::new(INSTALLER_SYSTEM_BIN).join(COMMAND_NAME),
    ];
    let mut candidates: Vec<PathBuf> = Vec::new();
    for candidate in on_path.chain(install_sh) {
        if !candidates.contains(&candidate) {
            candidates.push(candidate);
        }
    }
    candidates
}

/// The command a desktop app's family update would replace: the first
/// candidate this machine would actually run, resolved to the file behind
/// any link, judged by the rule `kendex update` judges its own bytes by.
///
/// A candidate has to be a command, not merely a path that is there. A
/// directory or a data file named `kendex` sitting in a writable directory
/// answers every other question the same way a command does — it exists,
/// and its parent takes a rename — so accepting presence alone would stop
/// the search on something a shell would have passed over, and write a
/// release binary onto whatever it was.
///
/// Past that, the search stops at the first one, rather than hunting for a
/// replaceable one further down: the command a person runs is the one
/// their `PATH` resolves first, and passing over a package-owned
/// `/usr/bin/kendex` to replace a second copy would move the half nobody
/// runs and leave the half they do.
///
/// `running` is this process and whatever it is about to replace, and
/// neither is ever the command. Both have to be named, because neither
/// covers the other: on Linux the AppImage the updater judged is not the
/// executable inside it, and on Windows the updater judges no path at all
/// while the desktop executable is `kendex.exe` — the same name the
/// command carries. Written over, the command binary lands on the app and
/// the app is then written back over it, leaving no command at all.
pub fn command_beside_app(
    probe: &dyn HostProbe,
    candidates: &[PathBuf],
    running: &[PathBuf],
) -> CommandBeside {
    let running: Vec<PathBuf> = running.iter().map(|path| probe.resolve(path)).collect();
    for candidate in candidates {
        if !probe.is_command(candidate) {
            continue;
        }
        let resolved = probe.resolve(candidate);
        if running.contains(&resolved) {
            continue;
        }
        return match for_cli(&resolved, probe) {
            InstallChannel::Direct => CommandBeside::Ours(resolved),
            owned => CommandBeside::NotOurs(owned),
        };
    }
    CommandBeside::Absent
}

/// Bring the `kendex` command beside a desktop app to `release`, before
/// the app itself moves.
///
/// The two halves have to name one release, or the pair ends up split by
/// version rather than by failure: a feed offering anything but the
/// release the app is installing stops the run with nothing written, and
/// the app's own version is then still behind, so the card still offers
/// the release and pressing it again repeats both halves.
///
/// A release with no command for this target stops the run for the same
/// reason. There is a command installed here — that is what `Ours` means —
/// and a release that cannot move it can only leave it behind.
pub fn bring_command_across(
    beside: &CommandBeside,
    feed_url: &str,
    release: &str,
    target: &str,
    public_key: &str,
) -> Result<CommandHalf, String> {
    let CommandBeside::Ours(path) = beside else {
        return Ok(CommandHalf::Untouched);
    };
    let feed = ReleaseFeed::parse(&fetch(feed_url)?).map_err(|error| error.to_string())?;
    if !one_release(&feed.version, release) {
        return Err(format!(
            "the desktop app installs {release} and the release feed offers the kendex command at {}; nothing was updated",
            feed.version
        ));
    }
    let Some(asset) = feed.asset_for(target) else {
        return Err(format!(
            "release {release} publishes no kendex command for {target}, so the command installed here would be left behind; nothing was updated"
        ));
    };
    // Named as the command half. Read off a card that has just been
    // pressed, a bare fetch or signature error says nothing about which of
    // the two halves it came from.
    download(asset)
        .and_then(|command| command.install_at(path, public_key))
        .map_err(|why| {
            format!("the kendex command could not be updated: {why}; nothing was updated")
        })?;
    Ok(CommandHalf::Moved)
}

/// One release under SemVer precedence, so build metadata cannot split a
/// pair the release job published together. Versions this build cannot
/// parse have to match exactly, which is the answer that can only refuse.
fn one_release(feed: &str, offered: &str) -> bool {
    match (Version::parse(feed), Version::parse(offered)) {
        (Ok(feed), Ok(offered)) => feed.cmp_precedence(&offered) == Ordering::Equal,
        _ => feed == offered,
    }
}

/// A release artifact and the minisign signature published beside it,
/// both in hand before either lands. Holding them is what lets a caller
/// order its writes: a download that was never going to arrive costs
/// nothing that is already on disk.
pub struct SignedArtifact {
    pub bytes: Vec<u8>,
    pub signature: Vec<u8>,
}

/// Fetch what `url` serves together with the `.sig` published beside it.
///
/// The feed is the one input nothing signs, so the URL here is a host
/// whoever can alter the feed chooses. The signature is what makes that
/// harmless: it comes from wherever the bytes came from and still has to
/// check out under a key baked into this build.
pub fn download(url: &str) -> Result<SignedArtifact, String> {
    Ok(SignedArtifact {
        bytes: fetch(url)?,
        signature: fetch(&signature_url(url))?,
    })
}

impl SignedArtifact {
    /// Write these bytes over `path`, and only once the signature checks
    /// out under `public_key`, so a download that fails verification never
    /// reaches an installed path. Every half of every update lands through
    /// here, so none of them is the half nothing checks.
    pub fn install_at(&self, path: &Path, public_key: &str) -> Result<(), String> {
        verify_signature(public_key, &self.bytes, &self.signature)
            .map_err(|error| error.to_string())?;
        replace_executable(path, &self.bytes).map_err(|error| error.to_string())
    }
}

pub fn fetch(url: &str) -> Result<Vec<u8>, String> {
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

/// Write `bytes` over an executable that may be running: the replacement
/// lands beside it whole and takes its place by rename, which every target
/// OS allows on a running file.
pub fn replace_executable(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
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

/// The process id keeps two concurrent runs off one staged file. Without
/// it they share a name, and what the rename installs is whatever the other
/// run last wrote there rather than the bytes this one verified.
pub fn staged_path(current: &Path) -> PathBuf {
    let mut name = current
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "kendex".to_owned());
    name.push_str(&format!(".update.{}", std::process::id()));
    current.with_file_name(name)
}

#[cfg(test)]
mod tests;
