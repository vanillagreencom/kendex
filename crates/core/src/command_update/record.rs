//! What an installer left behind so the desktop app can tell the `kendex`
//! command it installed from any other executable carrying that name.
//!
//! `install.sh` writes it, `kendex update` refreshes it for the binary it
//! is running as, and every replacement rewrites it for the bytes that
//! landed. A replacement made by a privileged run writes no record at all
//! — see [`acting_as_root`] — so the next run from the recorded path moves
//! this one to the bytes it finds there. Read by
//! `command_update::command_beside_app`, which will not replace a file no
//! record vouches for.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::install_channel::{Host, HostProbe};

/// What an installer recorded about the `kendex` command it installed:
/// where it put it, and what it put there.
///
/// Both halves have to match before those bytes are replaced. The path
/// alone was the whole record once, and a path is only a name: the file
/// behind it can be removed and another put in its place, and the wrapper
/// this record exists to protect is exactly the kind of thing that turns
/// up at a name kendex used to answer to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledCommand {
    /// Absolute, as the installer wrote it; resolved where it is used.
    pub path: PathBuf,
    /// Plain SHA-256 of the recorded bytes, hex — what `sha256sum` prints,
    /// so `install.sh` and this build compute the same value.
    pub digest: String,
}

/// Whether this process is acting as root.
///
/// Every path written below is resolved from the environment this process
/// was handed — `HOME` and `XDG_DATA_HOME` decide where [`Env`] puts the
/// record — and a privileged run was handed that environment by whoever
/// invoked it. `sudo` resets it on most machines, but a `sudoers` carrying
/// `env_keep HOME` does not, and then a root process opens a file every
/// component of whose name belongs to the invoking account: a link there
/// is followed, and root writes wherever it points.
///
/// So a run acting as root writes no record. Nothing is lost by that:
/// [`refresh_the_replaced_bytes`] moves the digest on any later run from
/// the recorded path, so the person's own next unprivileged run — any
/// verb, `--version` included — records the bytes the privileged run put
/// there, into the file their own account owns.
///
/// The effective uid and nothing else. `sudo`, `su`, `doas` and a root
/// login are one case here and none of them is distinguishable by a
/// variable: `SUDO_USER` and its neighbours are set by whoever invoked the
/// command, so a check reading one would be a check the invoker decides.
#[cfg(unix)]
fn acting_as_root() -> bool {
    rustix::process::geteuid().is_root()
}

/// Windows has no uid to answer with, and none of the elevation this
/// guards for — a command re-run under another account against the first
/// account's environment — is reachable there.
#[cfg(not(unix))]
fn acting_as_root() -> bool {
    false
}

/// What a run is asking to record. The three entries below differ only in
/// this value, so [`acting_as_root`] is read in one place: a wrapper that
/// read it for itself would be a second place to get wrong, and only that
/// wrapper's own test would ever notice.
pub(super) enum Write<'a> {
    /// The path a replacement landed at, and the bytes now there.
    Command(&'a Path, &'a [u8]),
    /// The file this process is running from.
    FirstRun(&'a Path),
    /// A path whose bytes are still on disk to be read.
    Installed(&'a Path),
}

/// Make the write, unless this process is one that may not make it.
fn record(env: &Env, write: Write<'_>) -> Result<(), String> {
    record_as(env, write, acting_as_root())
}

/// The same, told who is making it, so a suite drives either arm whatever
/// uid it is running under. Every caller outside a test comes through
/// [`record`], which asks the process.
///
/// Guarded here and nowhere below, ahead of every read and every
/// `create_dir_all`: a root run does nothing at all, rather than part of it
/// into a tree the invoking account named.
pub(super) fn record_as(env: &Env, write: Write<'_>, root: bool) -> Result<(), String> {
    if root {
        return Ok(());
    }
    match write {
        Write::Command(path, bytes) => write_the_command(env, path, bytes),
        Write::FirstRun(running) => write_the_first_run(env, running),
        Write::Installed(path) => {
            let bytes = std::fs::read(path)
                .map_err(|error| format!("{} could not be read: {error}", path.display()))?;
            write_the_command(env, path, &bytes)
        }
    }
}

/// The `kendex` command an installer recorded.
///
/// Absent where nothing has been recorded — an install older than this
/// record, or one made some other way — and absent for anything that is
/// not one absolute path and one SHA-256, because a record this build
/// cannot read is not a record it should act on.
pub fn recorded_command(env: &Env) -> Option<InstalledCommand> {
    let recorded = std::fs::read_to_string(env.installed_command_file()).ok()?;
    let mut lines = recorded.lines();
    let path = PathBuf::from(lines.next()?.trim());
    let digest = lines.next()?.trim().to_owned();
    let sha256 = digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit());
    (path.is_absolute() && sha256).then_some(InstalledCommand { path, digest })
}

/// Record `path`, holding `bytes`, as the `kendex` command this install
/// owns, so the desktop app can carry it across. Written by whatever put
/// the command there, and rewritten by whatever replaces it: a record left
/// naming bytes that are gone is a record that stops matching, which
/// refuses a command kendex does own rather than replacing one it does not.
///
/// A run acting as root writes nothing and says so with success — see
/// [`record_as`].
pub fn record_command(env: &Env, path: &Path, bytes: &[u8]) -> Result<(), String> {
    record(env, Write::Command(path, bytes))
}

/// The write itself. Reached only through [`record_as`], which has already
/// established this process may make it.
fn write_the_command(env: &Env, path: &Path, bytes: &[u8]) -> Result<(), String> {
    let file = env.installed_command_file();
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("{} could not be created: {error}", parent.display()))?;
    }
    let digest = crate::hash::sha256_hex(bytes);
    std::fs::write(&file, format!("{}\n{digest}\n", path.display()))
        .map_err(|error| format!("{} could not be written: {error}", file.display()))
}

/// How many names a staging write will try before giving up. Reaching the
/// end means every name this process could offer was taken, which is a
/// directory full of leftovers rather than a race worth waiting out.
const STAGING_ATTEMPTS: usize = 64;

/// Write `contents` to a name `name` supplies that nothing holds yet.
///
/// Created rather than written: a name left behind by a run that died
/// between the link and the unlink is a second name for the record itself,
/// so writing to it truncates the record and fills it in with another
/// command's path. Refusing a name already taken is what keeps this a
/// staging write and not a blind one, and the caller's `name` hands over
/// another on each call.
fn stage(
    contents: &str,
    name: impl Fn() -> std::path::PathBuf,
) -> Result<std::path::PathBuf, String> {
    use std::io::Write;
    let mut last = String::new();
    for _ in 0..STAGING_ATTEMPTS {
        let path = name();
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(mut handle) => {
                return handle
                    .write_all(contents.as_bytes())
                    .map(|()| path.clone())
                    .map_err(|error| format!("{} could not be written: {error}", path.display()));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                last = path.display().to_string();
            }
            Err(error) => {
                return Err(format!("{} could not be written: {error}", path.display()));
            }
        }
    }
    Err(format!(
        "no name was free to stage the record under, {STAGING_ATTEMPTS} tried, the last {last}"
    ))
}

/// Record the running command where nothing has been recorded yet.
///
/// What no lookup by name can establish is that a file is kendex's; a
/// process running from that file establishes it by being there. `kendex
/// update` has recorded itself since this record existed, but the installs
/// this is for were made before there was a record to write, and their
/// owners have no reason to run update rather than any other verb. So every
/// verb writes the first one.
///
/// Only the first, and first is the filesystem's answer rather than this
/// function's: a record already here is repointed by the run that replaces
/// the bytes it names and by nothing else. A second kendex on the machine
/// would otherwise take the record off the one a person installed merely by
/// being run once, and the app would then carry the copy nobody uses and
/// leave the one they do.
///
/// A record already here goes to [`refresh_the_replaced_bytes`], which
/// holds that rule and moves the digest alone.
///
/// A record already present but unreadable stays as it is. `recorded_command`
/// reads it as no record and the app refuses the command, which is the safe
/// direction; `kendex update` rewrites it, because that is the run replacing
/// the bytes.
///
/// A run acting as root writes nothing here either — see [`record_as`].
pub fn record_first_run(env: &Env, running: &Path) -> Result<(), String> {
    record(env, Write::FirstRun(running))
}

/// The bootstrap itself. Reached only through [`record_as`], which refuses
/// a root run ahead of the `create_dir_all` below: that call is already
/// root writing into a tree the invoking account named.
fn write_the_first_run(env: &Env, running: &Path) -> Result<(), String> {
    let file = env.installed_command_file();
    let Some(parent) = file.parent() else {
        return Err(format!("{} names no directory", file.display()));
    };
    // Asked before anything is read. Every run reaches here, `--version`
    // and `--help` included, and the answer after the first is always the
    // same one — so the steady state costs a look at one name rather than
    // a staging file made and unmade beside it, and the arm below buys the
    // read and the hash of the whole executable out of it too.
    // `symlink_metadata`, so a link occupying the name counts as occupying
    // it.
    //
    // Only a plain file is read on. Anything else at that name is where
    // this function has always stopped, and it has to stay that way: a
    // pipe there blocks the read below and holds every run of every verb
    // before its arguments are parsed, and a link there is a name someone
    // else chose for a write kendex would then aim at whatever it points
    // at. Neither is a record, and the app reads no record until the run
    // that replaces the command writes one.
    //
    // Not the arbiter, only the cheap answer. Two runs can both see
    // nothing here; the link below is what decides which of them was
    // first.
    if let Ok(here) = std::fs::symlink_metadata(&file) {
        return match here.is_file() {
            true => refresh_the_replaced_bytes(env, running, &here),
            false => Ok(()),
        };
    }
    std::fs::create_dir_all(parent)
        .map_err(|error| format!("{} could not be created: {error}", parent.display()))?;
    let bytes = std::fs::read(running)
        .map_err(|error| format!("{} could not be read: {error}", running.display()))?;
    // Named for this writer and no other. The process id alone is not one:
    // two threads of one process share it, and the pair would then stage
    // over each other and link a file the other was still writing.
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let contents = format!(
        "{}\n{}\n",
        running.display(),
        crate::hash::sha256_hex(&bytes)
    );
    let staged = stage(&contents, || {
        parent.join(format!(
            "installed-command.{}.{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ))
    })?;
    // Linked rather than written in place, so first is decided by the
    // filesystem and not by two reads that both answered "nothing here
    // yet". `link` fails when the name is taken, which is the whole test:
    // two copies starting together cannot both believe they are the first
    // and leave the record naming whichever finished last. The staged file
    // carries its whole content before the name exists, so no reader ever
    // sees a record half written.
    let first = std::fs::hard_link(&staged, &file);
    let _ = std::fs::remove_file(&staged);
    match first {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(format!("{} could not be written: {error}", file.display())),
    }
}

/// Move the digest of a record that names the file this process is running
/// from, where the bytes at that file are no longer the ones it names.
///
/// An update run with the privilege the desktop app lacks writes no record
/// at all — see [`acting_as_root`] — so the record here keeps naming the
/// bytes that run replaced. `command_beside_app` then stops matching a
/// command kendex does own, and the card that offered the one command out
/// of that state falls to the arm that names nobody. The person is left
/// with a current command the app will never offer to move again.
///
/// What licenses the write is what licenses a first run, and it is the same
/// file: a process running from the recorded path is the recorded command,
/// whatever bytes it now holds, and executing them is the proof no lookup
/// by name can offer. So the digest moves and the path does not. A record
/// naming any other file is left alone — repointing a record by path is
/// what `record_first_run` refuses, and it still refuses it.
///
/// Nothing here is privileged and nothing crosses an account. The process
/// is the person's own, the file is the one their own [`Env`] names, and
/// the bytes hashed are the ones this process was loaded from.
///
/// The record's modified time is read here as which version of the command
/// it describes, and left saying that on the way out. `record_file` is the
/// caller's `symlink_metadata`, which has already established this is a
/// plain file rather than a link or a pipe.
fn refresh_the_replaced_bytes(
    env: &Env,
    running: &Path,
    record_file: &std::fs::Metadata,
) -> Result<(), String> {
    let file = env.installed_command_file();
    let Some(record) = recorded_command(env) else {
        return Ok(());
    };
    if Host.resolve(&record.path) != Host.resolve(running) {
        return Ok(());
    }
    // The record's own timestamp says which version of the file it
    // describes, so bytes no newer than that are bytes it already names.
    // Every run of every verb reaches here, and that comparison is what
    // keeps the steady state off a read and a hash of the whole
    // executable. Where either timestamp cannot be read the record stays
    // as it is, which is this function's answer to everything it cannot
    // establish; a replacement landing on the same timestamp or an older
    // one is missed the same way, and the record then stays exactly where
    // it was before this arm existed.
    let (Ok(recorded_at), Ok(written_at)) = (
        record_file.modified(),
        std::fs::metadata(running).and_then(|bytes| bytes.modified()),
    ) else {
        return Ok(());
    };
    if written_at <= recorded_at {
        return Ok(());
    }
    let bytes = std::fs::read(running)
        .map_err(|error| format!("{} could not be read: {error}", running.display()))?;
    // A record already naming these bytes is left as it is rather than
    // rewritten with what it already holds. No reader can tell the two
    // apart afterwards, and that is the point: `record_command` truncates
    // before it writes, so rewriting would open a window where a reader
    // sees half a record where there was a whole one.
    if crate::hash::sha256_hex(&bytes) != record.digest {
        // Written back under the path the record already spells, not the
        // resolved one: the two name the same file, and a record rewritten
        // as a link's target stops describing the name a later release
        // replaces.
        record_command(env, &record.path, &bytes)?;
    }
    // Read before the bytes were, and stamped whether or not the digest
    // moved. Both halves matter.
    //
    // Stamped even where nothing was written, or a replacement installing
    // the same bytes again leaves the file newer than a record that
    // already names it and every later run pays the read and the hash for
    // nothing.
    //
    // Stamped with the file's own time rather than this moment, so the
    // record never claims to describe bytes this run did not read. A
    // replacement landing between that read and this write is then still
    // newer than the record, and the next run repairs it. Taking the clock
    // instead would leave the record naming bytes that are gone with a
    // timestamp that says otherwise, which is this defect made permanent.
    stamp(&file, written_at)
}

/// Say which version of a file a record describes, by giving the record
/// that file's own modified time.
fn stamp(file: &Path, written_at: std::time::SystemTime) -> Result<(), String> {
    std::fs::File::options()
        .write(true)
        .open(file)
        .and_then(|handle| handle.set_modified(written_at))
        .map_err(|error| format!("{} could not be stamped: {error}", file.display()))
}

/// The same record, taken from a file already on disk — the running
/// command identifying itself, where the bytes are not in hand.
///
/// A run acting as root writes nothing here either, and does not read the
/// file to find that out — see [`record_as`].
pub fn record_installed(env: &Env, path: &Path) -> Result<(), String> {
    record(env, Write::Installed(path))
}

#[cfg(test)]
mod tests;
