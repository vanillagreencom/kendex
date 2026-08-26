//! Finding the installed package's scripts, exactly as its own generated
//! hook helper finds them.
//!
//! The two must never disagree. A repository where the shim runs one copy
//! and kendex reports on another would gate commits one way and describe
//! them another, and the disagreement would surface only as a check calling
//! a repository fine while its commits fail.

use std::path::{Path, PathBuf};

use crate::error::Result;

use super::{SKILL, SKILL_ROOTS, guard_err};

/// One resolved script of the installed package.
pub struct Installed {
    /// The skill directory it was found under, for messages that name where.
    pub dir: PathBuf,
    /// The executable itself.
    pub script: PathBuf,
}

impl Installed {
    /// Resolve one of the package's scripts exactly as the generated hook
    /// helper resolves it, because the two must never disagree about which
    /// copy governs a repository.
    ///
    /// The helper's rule, in its order: the MAIN checkout first, then this
    /// work tree, and inside each the skill roots in turn — taking the
    /// first root whose *script is executable*, not the first directory
    /// that exists. Both halves matter. Linked worktrees share one hooks
    /// directory but need not carry their own skills, so a linked worktree
    /// is routinely gated by the main checkout's copy; and a tool directory
    /// holding a partial or non-executable copy must not shadow a working
    /// one beside it.
    pub fn resolve(repo: &crate::githooks::Repo, relative: &str) -> Option<Installed> {
        for root in search_roots(repo) {
            for base in SKILL_ROOTS {
                let dir = root.join(base).join(SKILL);
                let script = dir.join(relative);
                if is_executable(&script) {
                    return Some(Installed { dir, script });
                }
            }
        }
        None
    }

    /// Whether any copy of the package is here at all, for a message that
    /// tells "no package installed" from "a package whose scripts are
    /// broken" — two different things to do something about.
    pub fn present(repo: &crate::githooks::Repo) -> Option<PathBuf> {
        search_roots(repo).into_iter().find_map(|root| {
            SKILL_ROOTS
                .iter()
                .map(|base| root.join(base).join(SKILL))
                .find(|dir| dir.exists() || dir.is_symlink())
        })
    }
}

/// The roots the helper searches, in its order: the main checkout, then this
/// work tree. They are the same directory in an ordinary clone, and the
/// duplicate costs one `is_executable` call.
fn search_roots(repo: &crate::githooks::Repo) -> Vec<PathBuf> {
    let main = repo
        .common_dir
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| repo.worktree.clone());
    match main == repo.worktree {
        true => vec![main],
        false => vec![main, repo.worktree.clone()],
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// The repository the caller is standing in, and the package it carries.
/// Both refusals name what to do next, because this is reached from a
/// commit hook as often as from a terminal.
pub(super) fn bind(dir: &Path, relative: &str) -> Result<(crate::githooks::Repo, Installed)> {
    let repo = crate::githooks::Repo::at(dir)?;
    let Some(installed) = Installed::resolve(&repo, relative) else {
        // A package that is here but cannot run is a broken install, and
        // says so; one that is not here at all is a different sentence.
        return Err(match Installed::present(&repo) {
            Some(dir) => guard_err(
                "hooks",
                format!(
                    "the {SKILL} skill is installed at {} but {relative} is missing or not executable — reinstall it with `kendex refresh`",
                    dir.display()
                ),
            ),
            None => guard_err(
                "hooks",
                format!(
                    "no {SKILL} skill under {} ({}) — the checks live in that package; install it with `kendex add {SKILL}`",
                    repo.worktree.display(),
                    SKILL_ROOTS.join(" ")
                ),
            ),
        });
    };
    Ok((repo, installed))
}
