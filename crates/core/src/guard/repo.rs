//! The repository a guard verb is standing in.
//!
//! Small on purpose, and smaller than it was. kendex arms hooks through the
//! growth-guards package and no longer reasons about them: it needs to know
//! which repository it is in and where the package's scripts should be run
//! from. Where the hook files sit, and what "armed" means, belong to the
//! package.

use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::process::Hardened;

use super::guard_err;

/// git's own wording for the one failure that means "no repository here".
/// Matched as a phrase rather than by exit status: 128 is git's catch-all,
/// and a dubious-ownership refusal or a broken config carries it too.
///
/// Which is why the children below are run under `LC_ALL=C`. git translates
/// its diagnostics, so under another locale these phrases match nothing and
/// every "there is no repository here" becomes "could not tell" — a report
/// nobody can act on, in every scope, for anyone not working in English.
const NOT_A_REPOSITORY: [&str; 2] = ["not a git repository", "not a working tree"];

/// One repository, resolved: the worktree that invoked us and the common
/// dir every linked worktree shares. Both canonical, because paths are
/// compared as text — one worktree reached through a symlink must never
/// read as two, or as none.
pub struct Repo {
    pub worktree: PathBuf,
    pub common_dir: PathBuf,
    /// Where the verb was invoked, canonical. A kendex project can sit
    /// below the git top level, and the package renders under *its* root —
    /// so finding the render means starting where the caller stood, not
    /// where git's repository begins.
    pub started_at: PathBuf,
}

/// A git child whose stderr this module reads as English.
///
/// Only these: the guard verbs relay the package's own words untouched, and
/// a person running them in their own locale should get their own locale
/// back. What must not vary is a phrase kendex itself matches on.
fn english(hardened: Hardened) -> Hardened {
    hardened.env("LC_ALL", "C")
}

/// One path out of git, as the bytes git wrote.
///
/// Asked one path at a time, and read as bytes rather than text. Both halves
/// matter and both were wrong here.
///
/// Two paths in one `rev-parse` came back as two lines, so a checkout whose
/// name contains a newline — legal on Unix, and a name a person can create —
/// shifted the second answer onto part of the first. And `from_utf8_lossy`
/// turns any byte that is not UTF-8 into U+FFFD, which is not a filename: the
/// canonicalize below then fails for a repository that is perfectly fine, on
/// every verb, with a diagnostic naming a path nobody has.
///
/// git terminates the answer with exactly one newline, which is the only
/// byte removed.
fn one_path(dir: &Path, flag: &str) -> Result<Option<PathBuf>> {
    let output = english(Hardened::git(&["rev-parse", flag], Some(dir))).run()?;
    if !output.status.success() {
        return Ok(None);
    }
    let mut bytes = output.stdout;
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.is_empty() {
        return Ok(None);
    }
    path_from(bytes, flag).map(Some)
}

/// The bytes git wrote, as a path.
///
/// On unix a filename is bytes and travels as bytes. Elsewhere it has to be
/// text, and bytes that are not are an error rather than a lossy conversion:
/// `from_utf8_lossy` turns any byte that is not UTF-8 into U+FFFD, which is
/// not a filename, so every verb would then name a path nobody has for a
/// repository that is perfectly fine.
fn path_from(bytes: Vec<u8>, what: &str) -> Result<PathBuf> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStringExt;
        let _ = what;
        Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes)))
    }
    #[cfg(not(unix))]
    {
        let text = String::from_utf8(bytes).map_err(|_| {
            guard_err(
                "hooks",
                format!("git answered {what} with bytes that are not text"),
            )
        })?;
        Ok(PathBuf::from(text))
    }
}

impl Repo {
    pub fn at(dir: &Path) -> Result<Repo> {
        let no_work_tree = || {
            guard_err(
                "hooks",
                format!(
                    "git named no working tree for {} — commit hooks live in a checkout, not a bare repository",
                    dir.display()
                ),
            )
        };
        let Some(worktree) = one_path(dir, "--show-toplevel")? else {
            return Err(guard_err("hooks", "not inside a git repository"));
        };
        let Some(common) = one_path(dir, "--git-common-dir")? else {
            return Err(no_work_tree());
        };
        let worktree = worktree
            .canonicalize()
            .map_err(|e| CoreError::io(&worktree, e))?;
        // A relative common dir is relative to where git was asked — `dir` —
        // not to the top level: from a subdirectory git says `../.git`, and
        // joining that onto the top level names the wrong repository.
        let common_dir = match common.is_absolute() {
            true => common,
            false => dir
                .canonicalize()
                .map_err(|e| CoreError::io(dir, e))?
                .join(common),
        };
        let common_dir = common_dir
            .canonicalize()
            .map_err(|e| CoreError::io(&common_dir, e))?;
        let started_at = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
        Ok(Repo {
            worktree,
            common_dir,
            started_at,
        })
    }

    /// The repository at `dir`, or `None` where there is none.
    ///
    /// [`Repo::at`] answers one question with two meanings: a directory
    /// outside any repository and a git that could not run both arrive as
    /// the same error. A caller deciding whether a verdict is *owed* needs
    /// them apart — "no repository here, so no gate is expected" is a clean
    /// answer, while "git would not run" is a check that could not be
    /// taken. Only the first is `Ok(None)`.
    pub fn probe(dir: &Path) -> Result<Option<Repo>> {
        let output = english(Hardened::git(
            &["rev-parse", "--is-inside-work-tree"],
            Some(dir),
        ))
        .run()?;
        let answer = String::from_utf8_lossy(&output.stdout);
        if output.status.success() {
            return match answer.trim() {
                "true" => Repo::at(dir).map(Some),
                // Inside a repository but not a checkout — a bare one, or a
                // git directory reached directly. No gate is expected.
                "false" => Ok(None),
                other => Err(guard_err(
                    "hooks",
                    format!(
                        "git answered '{other}' when asked whether {} is a work tree",
                        dir.display()
                    ),
                )),
            };
        }
        // A failure is only "no repository" when git says so in as many
        // words. Exit 128 covers far more — a malformed config, a
        // repository whose ownership git refuses, an unreadable object
        // store — and every one of those is a check that could not be
        // taken. Calling them "nothing here" would read as a pass.
        let complaint = String::from_utf8_lossy(&output.stderr);
        match NOT_A_REPOSITORY
            .iter()
            .any(|phrase| complaint.contains(phrase))
        {
            true => Ok(None),
            false => Err(guard_err(
                "hooks",
                format!(
                    "could not tell whether {} is a work tree (git exited {:?}): {}",
                    dir.display(),
                    output.status.code(),
                    complaint.trim()
                ),
            )),
        }
    }
}
