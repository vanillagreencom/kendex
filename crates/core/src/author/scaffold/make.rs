//! Making the folder: the one place a create touches the disk, and the
//! questions asked before it does — is this a path a folder can be made
//! at, is anything already there, and does the registry take the row.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::process::Hardened;

use super::MineRow;
use super::{CreateRequest, plan};

/// Create the folder, write the plan, initialise git, register under Mine.
/// A folder kendex just made is kendex's to initialise; nothing is
/// committed. Refuses a folder that already exists — creating never merges.
///
/// Everything that can refuse is asked first (the shape of the path, the
/// destination, the registry file). A failure after that removes the
/// folder where it can, and says so in the error where it cannot.
pub fn create(env: &Env, request: &CreateRequest) -> Result<MineRow> {
    let files = plan(request)?;
    let dir = creatable(&request.dir)?;
    crate::author::registry::can_register(env, &dir)?;
    if let Err(error) = build_in(&dir, &files).and_then(|()| {
        // The folder was wholly created by this call — a registry that
        // refused after all takes it back with it.
        crate::author::registry::register(env, &dir)
    }) {
        return Err(unmade(&dir, error));
    }
    crate::author::status::status(&dir)
}

/// Take back the folder this call made, and say so when it cannot: the
/// half-built folder stands, and the next attempt would meet the "already
/// exists" refusal with nothing said about where it came from.
fn unmade(dir: &Path, error: CoreError) -> CoreError {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => error,
        Err(gone) if gone.kind() == std::io::ErrorKind::NotFound => error,
        Err(_) => CoreError::Authoring {
            message: format!(
                "{error}. {} was left behind — delete it before trying again",
                dir.display()
            ),
        },
    }
}

/// The folder this request creates, proven to be one a create may make.
///
/// The destination is derived first and every question is then asked of
/// it: the parent's real place joined with the folder's own name. Asking
/// the caller's spelling instead answers for whatever that spelling
/// reaches, and the spellings differ — a trailing separator or a `.` sends
/// the kernel through a link that `made` on its own would have stopped at,
/// so a guard on the input passes while the build and the removal work on
/// the derived path. That spelling need not name a folder at all
/// (`nope/..` has no last component), and handing it to the failure path's
/// `remove_dir_all` would take the directory the command was run in.
///
/// Presence is asked of the name itself, never of what it reaches: a link
/// whose target is gone answers `exists` with false, and the failure
/// path's `remove_dir_all` would then delete somebody's link.
fn creatable(dir: &Path) -> Result<PathBuf> {
    let (Some(parent), Some(leaf)) = (dir.parent(), dir.file_name()) else {
        return Err(CoreError::Authoring {
            message: format!("{} is not a creatable folder path", dir.display()),
        });
    };
    // A bare name has an empty parent, which is the working directory.
    let parent = match parent.as_os_str().is_empty() {
        true => Path::new("."),
        false => parent,
    };
    let real = parent.canonicalize().map_err(|error| match error.kind() {
        // Absent is the everyday one and gets the sentence that says what
        // to do. Anything else — a component nothing may traverse, a link
        // that loops — is the parent said honestly, the way the
        // `symlink_metadata` arm below says its own failures.
        std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory => CoreError::Authoring {
            message: format!(
                "{} is not a folder that exists — make it first, or create the marketplace somewhere else",
                parent.display()
            ),
        },
        _ => CoreError::io(parent, error),
    })?;
    let dir = real.join(leaf);
    match dir.symlink_metadata() {
        Ok(_) => Err(CoreError::Authoring {
            message: format!(
                "{} already exists — use \"an existing folder\" to register it instead",
                dir.display()
            ),
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(dir),
        // Something is there that this cannot even look at. Creating over
        // it is not on, and calling it absent would put it on the failure
        // path's removal list.
        Err(error) => Err(CoreError::io(&dir, error)),
    }
}

fn build_in(dir: &Path, files: &[(String, String)]) -> Result<()> {
    std::fs::create_dir_all(dir).map_err(|e| CoreError::io(dir, e))?;
    for (rel, bytes) in files {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
        }
        crate::fs::atomic_write(&path, bytes)?;
    }
    // git init failing (no git on the machine) costs the init, not the
    // folder: the row reports repository:false and the person decides.
    let _ = Hardened::git_in(dir, &["init", "--quiet"])
        .timeout(std::time::Duration::from_secs(10))
        .run();
    Ok(())
}

#[cfg(test)]
mod tests;
