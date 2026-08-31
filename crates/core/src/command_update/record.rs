//! What an installer left behind so the desktop app can tell the `kendex`
//! command it installed from any other executable carrying that name.
//!
//! `install.sh` writes it, `kendex update` refreshes it for the binary it
//! is running as, and every run records the command an older install never
//! recorded. A replacement made by a privileged run writes no record at
//! all — see [`acting_as_root`]. Read by
//! `command_update::command_beside_app`, which will not replace a file no
//! record vouches for.

use std::path::{Path, PathBuf};

use crate::env::Env;

/// What an installer recorded about the `kendex` command it installed:
/// where it put it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledCommand {
    /// Absolute, as the installer wrote it; resolved where it is used.
    pub path: PathBuf,
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
/// So a run acting as root writes no record. The person's own next
/// unprivileged run — any verb, `--version` included — writes one into the
/// file their own account owns.
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

/// What a run is asking to record. The two entries below differ only in
/// this value, so [`acting_as_root`] is read in one place: a wrapper that
/// read it for itself would be a second place to get wrong, and only that
/// wrapper's own test would ever notice.
pub(super) enum Write<'a> {
    /// The path a replacement landed at.
    Command(&'a Path),
    /// The file this process is running from.
    FirstRun(&'a Path),
}

/// Make the write, unless this process is one that may not make it.
fn record(env: &Env, write: Write<'_>) -> Result<(), String> {
    record_as(env, write, acting_as_root())
}

/// The same, told who is making it, so a suite drives either arm whatever
/// uid it is running under. Every caller outside a test comes through
/// [`record`], which asks the process.
///
/// Guarded here and nowhere below, ahead of every `create_dir_all`: a root
/// run does nothing at all, rather than part of it into a tree the invoking
/// account named.
pub(super) fn record_as(env: &Env, write: Write<'_>, root: bool) -> Result<(), String> {
    if root {
        return Ok(());
    }
    match write {
        Write::Command(path) => write_the_command(env, path),
        Write::FirstRun(running) => write_the_first_run(env, running),
    }
}

/// The `kendex` command an installer recorded.
///
/// Absent where nothing has been recorded — an install older than this
/// record, or one made some other way — and absent for anything that is
/// not one absolute path, because a record this build cannot read is not a
/// record it should act on.
pub fn recorded_command(env: &Env) -> Option<InstalledCommand> {
    let recorded = std::fs::read_to_string(env.installed_command_file()).ok()?;
    let path = PathBuf::from(recorded.lines().next()?.trim());
    path.is_absolute().then_some(InstalledCommand { path })
}

/// Record `path` as the `kendex` command this install owns, so the desktop
/// app can carry it across. Written by whatever put the command there —
/// `install.sh` at install, `kendex update` for the binary it is running
/// as — and it repoints a record already here, which is the difference
/// from [`record_first_run`].
///
/// A run acting as root writes nothing and says so with success — see
/// [`record_as`].
pub fn record_command(env: &Env, path: &Path) -> Result<(), String> {
    record(env, Write::Command(path))
}

/// The write itself. Reached only through [`record_as`], which has already
/// established this process may make it.
fn write_the_command(env: &Env, path: &Path) -> Result<(), String> {
    let file = env.installed_command_file();
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("{} could not be created: {error}", parent.display()))?;
    }
    std::fs::write(&file, format!("{}\n", path.display()))
        .map_err(|error| format!("{} could not be written: {error}", file.display()))
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
/// function's: a record already here is repointed by `kendex update`, which
/// records the file it is running from, and by no other verb. A second
/// kendex on the machine would otherwise take the record off the one a
/// person installed merely by being run once, and the app would then carry
/// the copy nobody uses and leave the one they do.
///
/// A record already present but unreadable stays as it is. `recorded_command`
/// reads it as no record and the app refuses the command, which is the safe
/// direction; `kendex update` rewrites it, because that run records the
/// file it is running from.
///
/// A run acting as root writes nothing here either — see [`record_as`].
pub fn record_first_run(env: &Env, running: &Path) -> Result<(), String> {
    record(env, Write::FirstRun(running))
}

/// The bootstrap itself. Reached only through [`record_as`], which refuses
/// a root run ahead of the `create_dir_all` below: that call is already
/// root writing into a tree the invoking account named.
///
/// Created rather than written, so first is decided by the filesystem and
/// not by a read that answered "nothing here yet": `create_new` fails on a
/// name that is taken, which is the whole test. Two copies starting
/// together cannot both believe they are the first and leave the record
/// naming whichever finished last, and anything already at that name —
/// another install's record, a link somebody else chose, a pipe — is left
/// exactly as it is rather than opened.
///
/// The one taken name that is nobody's record is an empty one, and it is
/// this function that can leave it: the name is published before the bytes
/// are in it. Every later run would find that name taken too, so nothing
/// would ever repair it and the app would refuse a command it does own
/// until `kendex update` rewrote the record. So a write that fails takes
/// the name back with it, and a claim found empty is taken back here.
fn write_the_first_run(env: &Env, running: &Path) -> Result<(), String> {
    let file = env.installed_command_file();
    let Some(parent) = file.parent() else {
        return Err(format!("{} names no directory", file.display()));
    };
    std::fs::create_dir_all(parent)
        .map_err(|error| format!("{} could not be created: {error}", parent.display()))?;
    match claim_the_record(&file, running) {
        // Taken, which is the ordinary answer: every run after the first
        // gets it.
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        answered => return answered.map_err(|error| written(&file, &error)),
    }
    // Somebody's record, and this run is not the first. Judged by one
    // `symlink_metadata`, which is the whole read the steady state pays:
    // a name with bytes in it is left alone — an unreadable one included,
    // which `kendex update` rewrites — and a link or a fifo is not a
    // regular file however long it is, so neither is followed or opened.
    if !an_unfilled_claim(&file) {
        return Ok(());
    }
    // The empty name goes back and is claimed again. A removal that will
    // not happen, or a name taken again behind this one, leaves the record
    // as it was found: this run recorded nothing, and the next one makes
    // the same repair.
    if std::fs::remove_file(&file).is_err() {
        return Ok(());
    }
    match claim_the_record(&file, running) {
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        answered => answered.map_err(|error| written(&file, &error)),
    }
}

/// Take the name and fill it, or leave nothing at it.
///
/// `create_new` is what makes the claim, and it publishes the name before
/// the bytes are written. A write that fails would strand that name, so it
/// is given back here and the caller answers the write's own error.
fn claim_the_record(file: &Path, running: &Path) -> std::io::Result<()> {
    use std::io::Write as _;
    let mut handle = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(file)?;
    handle
        .write_all(format!("{}\n", running.display()).as_bytes())
        .inspect_err(|_| {
            let _ = std::fs::remove_file(file);
        })
}

/// Whether that name is a claim nothing ever filled in: a regular file
/// with nothing in it. Read as the name itself rather than as whatever it
/// leads to, and never opened — a fifo would hold a run that opened it.
fn an_unfilled_claim(file: &Path) -> bool {
    std::fs::symlink_metadata(file).is_ok_and(|entry| entry.is_file() && entry.len() == 0)
}

/// The one sentence for a record that would not be written.
fn written(file: &Path, error: &std::io::Error) -> String {
    format!("{} could not be written: {error}", file.display())
}

#[cfg(test)]
mod tests;
