//! The repository a guard verb is standing in, and where git looks for its
//! hooks.
//!
//! Small on purpose. kendex arms hooks through the growth-guards package
//! and reads them back off disk; it needs to know which repository it is in,
//! which directory git actually executes hooks from, and which one it would
//! execute them from with no redirect in the way. Nothing else.

use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::process::Hardened;

use super::guard_err;

/// git's own wording for the one failure that means "no repository here".
/// Matched as a phrase rather than by exit status: 128 is git's catch-all,
/// and a dubious-ownership refusal or a broken config carries it too.
const NOT_A_REPOSITORY: [&str; 2] = ["not a git repository", "not a working tree"];

/// One repository, resolved: the worktree that invoked us and the common
/// dir every linked worktree shares. Both canonical, because paths are
/// compared as text — one worktree reached through a symlink must never
/// read as two, or as none.
pub struct Repo {
    pub worktree: PathBuf,
    pub common_dir: PathBuf,
}

impl Repo {
    pub fn at(dir: &Path) -> Result<Repo> {
        let output = Hardened::git(
            &["rev-parse", "--show-toplevel", "--git-common-dir"],
            Some(dir),
        )
        .run()?;
        if !output.status.success() {
            return Err(guard_err("hooks", "not inside a git repository"));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let mut lines = text.lines();
        let (Some(worktree), Some(common)) = (lines.next(), lines.next()) else {
            return Err(guard_err(
                "hooks",
                format!(
                    "git named no working tree for {} — commit hooks live in a checkout, not a bare repository",
                    dir.display()
                ),
            ));
        };
        let worktree = PathBuf::from(worktree);
        let worktree = worktree
            .canonicalize()
            .map_err(|e| CoreError::io(&worktree, e))?;
        // A relative common dir is relative to where git was asked — `dir` —
        // not to the top level: from a subdirectory git says `../.git`, and
        // joining that onto the top level names the wrong repository.
        let common = PathBuf::from(common);
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
        Ok(Repo {
            worktree,
            common_dir,
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
        let output = Hardened::git(&["rev-parse", "--is-inside-work-tree"], Some(dir)).run()?;
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

    /// The repository's default hooks directory, whether or not git reads
    /// it: where a shim sits dormant behind a `core.hooksPath` redirect, and
    /// where it goes live the moment that redirect is removed.
    pub fn default_hooks_dir(&self) -> PathBuf {
        self.common_dir.join("hooks")
    }

    /// The hooks directory git actually reads, its own answer. Under a
    /// `core.hooksPath` redirect this is the redirected directory; without
    /// one it is the default. Asked rather than derived, because telling
    /// those two apart is what a check about hooks is for.
    pub fn effective_hooks_dir(&self) -> Result<PathBuf> {
        let output =
            Hardened::git(&["rev-parse", "--git-path", "hooks"], Some(&self.worktree)).run()?;
        if !output.status.success() {
            return Err(guard_err(
                "hooks",
                format!(
                    "could not resolve the hooks directory of {}",
                    self.worktree.display()
                ),
            ));
        }
        let answer = String::from_utf8_lossy(&output.stdout);
        let path = PathBuf::from(answer.trim());
        // git answers relative to where it was asked when the path is
        // inside the repository it was asked from.
        Ok(match path.is_absolute() {
            true => path,
            false => self.worktree.join(path),
        })
    }
}
