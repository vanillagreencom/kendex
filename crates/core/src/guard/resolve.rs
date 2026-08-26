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
    /// The helper's rule, in its order. First the scripts directory baked
    /// into the helper by whichever install wrote it — that is the copy an
    /// armed repository actually runs, and it need not be one the search
    /// below would reach. Only then the MAIN checkout and this work tree,
    /// and inside each the skill roots in turn, taking the first root whose
    /// *script is executable* rather than the first directory that exists.
    ///
    /// Every part of that ordering decides a real case. The baked path is
    /// what a repository armed from an unusual layout runs. Linked
    /// worktrees share one hooks directory but need not carry their own
    /// skills, so one is routinely gated by the main checkout's copy. And a
    /// tool directory holding a partial or non-executable copy must not
    /// shadow a working one beside it.
    pub fn resolve(repo: &super::Repo, relative: &str) -> Option<Installed> {
        // The helper bakes the scripts DIRECTORY and execs a bare lane name
        // inside it, so the baked branch joins the file name rather than the
        // package-relative path the search below uses.
        if let Some(scripts) = baked_scripts(repo)
            && let Some(name) = Path::new(relative).file_name()
        {
            let script = scripts.join(name);
            if is_executable(&script) {
                let dir = scripts.parent().unwrap_or(&scripts).to_path_buf();
                return Some(Installed { dir, script });
            }
        }
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
    pub fn present(repo: &super::Repo) -> Option<PathBuf> {
        search_roots(repo).into_iter().find_map(|root| {
            SKILL_ROOTS
                .iter()
                .map(|base| root.join(base).join(SKILL))
                .find(|dir| dir.exists() || dir.is_symlink())
        })
    }
}

/// The scripts directory the installed helper runs first, read out of the
/// helper itself.
///
/// The installer bakes it in as a single-quoted shell assignment on its own
/// line, so it is read back the same way. A helper that is absent,
/// unreadable, or shaped differently than this installer writes yields
/// nothing and the search below decides — the same outcome the helper
/// reaches when the baked path holds no executable script.
fn baked_scripts(repo: &super::Repo) -> Option<PathBuf> {
    let helper = repo
        .effective_hooks_dir()
        .ok()?
        .join(super::grammar::HELPER);
    let text = std::fs::read_to_string(helper).ok()?;
    let quoted = text
        .lines()
        .find_map(|line| line.strip_prefix("installed_scripts='"))?
        .strip_suffix('\'')?;
    let value = unquote(quoted);
    (!value.is_empty()).then(|| PathBuf::from(value))
}

/// The shell single-quoting the installer writes, undone.
///
/// Single quotes cannot nest, so an apostrophe in the path is written as
/// `'\''` — close, escaped quote, reopen. Reading that back literally gives
/// a path that does not exist, and the helper would run the copy this could
/// not find: `/home/o'brien/repo` and `/home/o'\''brien/repo` are different
/// directories, and only one of them is anyone's.
fn unquote(quoted: &str) -> String {
    quoted.replace("'\\''", "'")
}

/// Where a copy of the package can be, in the order that finds the one this
/// project actually installed.
///
/// The project root comes first, because that is where `kendex add` renders
/// and a kendex project does not have to be the git top level: a repository
/// holding several projects renders each under its own root, and searching
/// only the top level finds none of them. Then the helper's own two roots —
/// the main checkout, because linked worktrees share a hooks directory and
/// need not carry their own skills, and then this work tree.
///
/// Duplicates are dropped rather than avoided: in an ordinary single-project
/// clone all three are the same directory.
fn search_roots(repo: &super::Repo) -> Vec<PathBuf> {
    let main = repo
        .common_dir
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| repo.worktree.clone());
    let mut roots = Vec::new();
    if let Some(project) = project_root(repo) {
        roots.push(project);
    }
    for root in [main, repo.worktree.clone()] {
        if !roots.contains(&root) {
            roots.push(root);
        }
    }
    roots
}

/// The kendex project the caller is standing in: the nearest manifest at or
/// above where the verb was invoked, bounded by the git work tree.
///
/// Bounded there on purpose. Above the work tree is somebody else's
/// repository, and a manifest found up there describes a project this
/// commit has nothing to do with.
fn project_root(repo: &super::Repo) -> Option<PathBuf> {
    let mut dir = repo.started_at.as_path();
    loop {
        let manifest = dir.join(crate::rename::MANIFEST_FILE).is_file()
            || dir.join(crate::rename::LEGACY_MANIFEST_FILE).is_file();
        if manifest {
            return Some(dir.to_path_buf());
        }
        if dir == repo.worktree {
            return None;
        }
        dir = dir.parent()?;
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
pub(super) fn bind(dir: &Path, relative: &str) -> Result<(super::Repo, Installed)> {
    let repo = super::Repo::at(dir)?;
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
                    "no {SKILL} skill under {} ({}) — the checks live in that package; install it with `kendex add --skill {SKILL}`",
                    repo.worktree.display(),
                    SKILL_ROOTS.join(" ")
                ),
            ),
        });
    };
    Ok((repo, installed))
}

#[cfg(test)]
mod tests {
    use super::unquote;

    /// The installer builds the escape as `'` + `\` + `'` + `'`; reading it
    /// back has to undo exactly that and leave every other character alone.
    #[test]
    fn an_apostrophe_in_the_path_survives_the_round_trip() {
        assert_eq!(unquote("/home/plain/repo"), "/home/plain/repo");
        assert_eq!(unquote("/home/o'\\''brien/repo"), "/home/o'brien/repo");
        assert_eq!(
            unquote("/a'\\''b/c'\\''d"),
            "/a'b/c'd",
            "every occurrence, not just the first"
        );
        // A lone backslash is a directory name, not an escape.
        assert_eq!(unquote("/home/back\\slash"), "/home/back\\slash");
    }
}
