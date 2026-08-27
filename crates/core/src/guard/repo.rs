//! The repository a guard verb is standing in, and where git looks for its
//! hooks.
//!
//! Small on purpose, and smaller than it was. kendex arms hooks through the
//! growth-guards package and no longer reasons about them: it needs to know
//! which repository it is in, where the package's scripts should be run
//! from, and where the hook files sit. What "armed" means belongs to the
//! package.

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
    /// Where the verb was invoked, canonical. A kendex project can sit
    /// below the git top level, and the package renders under *its* root —
    /// so finding the render means starting where the caller stood, not
    /// where git's repository begins.
    pub started_at: PathBuf,
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

    /// The hooks directory git reads with no redirect in the way.
    pub fn default_hooks_dir(&self) -> PathBuf {
        self.common_dir.join("hooks")
    }

    /// Whether `core.hooksPath` is set to anything at all.
    ///
    /// Set means git reads hooks from somewhere this does not attempt to
    /// work out — the empty value switches them off, a relative one resolves
    /// against the work tree, an absolute one may or may not be this same
    /// directory under another name, and telling those apart is the grammar
    /// that used to live here and drifted from the package's every time it
    /// was touched. Set at all is answered "not armed", which is safe for
    /// all of them; the package's own `--check` is what says more.
    pub fn hooks_redirected(&self) -> Result<bool> {
        let output =
            Hardened::git(&["config", "--get", "core.hooksPath"], Some(&self.worktree)).run()?;
        match output.status.code() {
            Some(0) => Ok(true),
            // Exit 1 is git for "not set", which is the only unredirected
            // answer. Anything else is a repository this cannot read, and
            // an unreadable one is not a repository known to be armed.
            _ => Ok(false),
        }
    }
}
