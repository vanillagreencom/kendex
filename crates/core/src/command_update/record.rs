//! What an installer left behind so the desktop app can tell the `kendex`
//! command it installed from any other executable carrying that name.
//!
//! `install.sh` writes it, `kendex update` refreshes it for the binary it
//! is running as, and every replacement rewrites it for the bytes that
//! landed. Read by `command_update::command_beside_app`, which will not
//! replace a file no record vouches for.

use std::path::{Path, PathBuf};

use crate::env::Env;

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
pub fn record_command(env: &Env, path: &Path, bytes: &[u8]) -> Result<(), String> {
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
/// A record already present but unreadable stays as it is. `recorded_command`
/// reads it as no record and the app refuses the command, which is the safe
/// direction; `kendex update` rewrites it, because that is the run replacing
/// the bytes.
pub fn record_first_run(env: &Env, running: &Path) -> Result<(), String> {
    let file = env.installed_command_file();
    let Some(parent) = file.parent() else {
        return Err(format!("{} names no directory", file.display()));
    };
    // Asked before anything is read. Every run reaches here, `--version`
    // and `--help` included, and the answer after the first is always the
    // same one — so the steady state costs a look at one name rather than
    // a read and a hash of the whole executable and a staging file made
    // and unmade beside it. `symlink_metadata`, so a link occupying the
    // name counts as occupying it.
    //
    // Not the arbiter, only the cheap answer. Two runs can both see
    // nothing here; the link below is what decides which of them was
    // first.
    if std::fs::symlink_metadata(&file).is_ok() {
        return Ok(());
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

/// The same record, taken from a file already on disk — the running
/// command identifying itself, where the bytes are not in hand.
pub fn record_installed(env: &Env, path: &Path) -> Result<(), String> {
    let bytes = std::fs::read(path)
        .map_err(|error| format!("{} could not be read: {error}", path.display()))?;
    record_command(env, path, &bytes)
}

#[cfg(test)]
mod tests;
