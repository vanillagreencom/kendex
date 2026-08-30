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

/// The same record, taken from a file already on disk — the running
/// command identifying itself, where the bytes are not in hand.
pub fn record_installed(env: &Env, path: &Path) -> Result<(), String> {
    let bytes = std::fs::read(path)
        .map_err(|error| format!("{} could not be read: {error}", path.display()))?;
    record_command(env, path, &bytes)
}

#[cfg(test)]
mod tests;
