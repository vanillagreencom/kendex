//! Finding the installed package's scripts, exactly as its own generated
//! hook helper finds them.
//!
//! The two must never disagree. A repository where the shim runs one copy
//! and kendex reports on another would gate commits one way and describe
//! them another, and the disagreement would surface only as a check calling
//! a repository fine while its commits fail.

use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::fs::is_executable;

use super::{SKILL, guard_err};

/// Where an installed skill can sit: every project skills directory a
/// kendex install writes, plus the source layout kendex itself has.
///
/// It is the harness adapters' own list — `a_root_for_every_harness_skills_
/// surface` pins it against them, not merely against the shell copy below,
/// because two duplicates agreeing is no evidence that either is right.
/// `.cursor/rules` used to be here and is not a skills directory at all;
/// cursor's own adapter says so, and `.gemini/skills` and `.github/skills`
/// were missing, so a `method = copy` install into any of the three was a
/// package the guard verbs could not find.
///
/// The package searches the same list, from a single definition in
/// `lib/skill-roots.sh` that the installer bakes into the helper it writes.
/// A repository where the shim finds a script and kendex finds a different
/// one would gate commits one way and report them another, so
/// `guard_skill_roots::the_packages_own_list_is_the_same_roots_in_the_same_
/// order` holds the two to the same roots in the same order — and
/// `…covers_every_harness_skills_surface` holds the package's list to the
/// adapters as well, so neither is ever only compared to its twin.
pub const SKILL_ROOTS: [&str; 7] = [
    ".agents/skills",
    ".claude/skills",
    ".cursor/skills",
    ".gemini/skills",
    ".github/skills",
    ".opencode/skills",
    "skills",
];

/// One resolved script of the installed package.
pub struct Installed {
    /// The skill directory it was found under, for messages that name where.
    pub dir: PathBuf,
    /// The executable itself.
    pub script: PathBuf,
}

impl Installed {
    /// Resolve one of the package's scripts the way an armed repository
    /// runs them, as closely as a caller standing outside `.git/hooks` can.
    ///
    /// Not identically, and the difference is deliberate. The helper starts
    /// from the scripts directory baked into it at install; this cannot,
    /// because reading what a hook file says to run is the layer this crate
    /// removed. So it starts from the project root the caller stood in —
    /// where a kendex install renders — then the MAIN checkout, then this
    /// work tree, and inside each the skill roots in turn, taking the first
    /// whose *script is executable* rather than the first directory that
    /// exists.
    ///
    /// Where the two diverge, they diverge safely: this finds a copy the
    /// caller declared, and the verbs run that one. A repository armed from
    /// somewhere else is the package's `--check` to describe.
    ///
    /// Every part of that ordering decides a real case. Linked worktrees
    /// share one hooks directory but need not carry their own skills, so one
    /// is routinely gated by the main checkout's copy. And a tool directory
    /// holding a partial or non-executable copy must not shadow a working
    /// one beside it.
    ///
    /// It used to consult the path baked into `.git/hooks/kendex-guards`
    /// first. That was a read of hook content to decide what kendex runs,
    /// which is the layer this module no longer has: the shim resolves its
    /// own scripts at commit time, and kendex resolves its own here.
    pub fn resolve(repo: &super::Repo, relative: &str) -> Option<Installed> {
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

/// Where a copy of the package can be, in the order that finds the one this
/// project actually installed.
///
/// The project root comes first, because that is where `kendex add` renders
/// and a kendex project does not have to be the git top level: a repository
/// holding several projects renders each under its own root, and searching
/// only the top level finds none of them.
///
/// Then the SAME project inside the main checkout. A linked worktree shares
/// the hooks directory and need not carry its own skills, so it is routinely
/// gated by the main checkout's copy — and in a repository whose projects sit
/// under `apps/web` the copy is at `<main>/apps/web`, not at `<main>`.
/// Looking only at the top level found nothing there and reported a package
/// the commit hook was running perfectly well as missing.
///
/// The two bare roots come last, in the helper's own order: the main checkout
/// and then this work tree.
///
/// Duplicates are dropped rather than avoided: in an ordinary single-project
/// clone every one of these is the same directory.
fn search_roots(repo: &super::Repo) -> Vec<PathBuf> {
    let main = main_checkout(repo);
    let project = project_root(repo);
    // The project path carried across, and only when it IS a path under this
    // work tree: a project root that is not below it has no counterpart to
    // map, and joining an absolute path would silently replace the checkout.
    let mirrored = match (&main, &project) {
        (Some(main), Some(project)) => project
            .strip_prefix(&repo.worktree)
            .ok()
            .map(|rel| main.join(rel)),
        _ => None,
    };
    let mut roots = Vec::new();
    for root in project
        .into_iter()
        .chain(mirrored)
        .chain(main)
        .chain([repo.worktree.clone()])
    {
        if !roots.contains(&root) {
            roots.push(root);
        }
    }
    roots
}

/// The main checkout, where the directory holding the common git dir really
/// is one.
///
/// `<main>/.git` is the ordinary layout and the parent is the main work tree
/// there. Under `--separate-git-dir` the git directory lives outside the
/// checkout entirely, and its parent is then an unrelated directory —
/// somebody's home, a directory of checkouts — which may hold a
/// `growth-guards` of its own. A linked worktree would have executed that
/// one: a package this repository never installed, running as its commit
/// gate.
///
/// Two things have to hold, and the first alone is not enough.
///
/// Owning it: the candidate's own common git directory has to be this
/// repository's. And being a checkout root: the work tree git resolves from
/// the candidate has to be the candidate itself.
///
/// The ownership test alone answers yes for any directory INSIDE this
/// repository's work tree, because git resolves upward — so a git directory
/// at `<worktree>/meta/repo.git` made `<worktree>/meta` the main checkout,
/// and a `growth-guards` under `<worktree>/meta/.agents/skills` would have
/// run as this repository's gate. Same repository, wrong root.
///
/// The package's installer asks both questions in the same way, and where
/// either answer is no this root is not searched at all — a verb that finds
/// nothing says so, which is the safe end of being wrong here.
fn main_checkout(repo: &super::Repo) -> Option<PathBuf> {
    let candidate = repo.common_dir.parent()?;
    let owned = super::Repo::at(candidate).ok()?;
    (owned.common_dir == repo.common_dir && owned.worktree == candidate)
        .then(|| candidate.to_path_buf())
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
        if dir.join(crate::manifest::MANIFEST_FILE).is_file() {
            return Some(dir.to_path_buf());
        }
        if dir == repo.worktree {
            return None;
        }
        dir = dir.parent()?;
    }
}

/// The repository the caller is standing in, and the package it carries.
/// Both refusals name what to do next, because this is reached from a
/// commit hook as often as from a terminal.
pub(super) fn bind(dir: &Path, relative: &str) -> Result<(super::Repo, Installed)> {
    let repo = super::Repo::at(dir)?;
    let installed = installed_or_err(&repo, relative)?;
    Ok((repo, installed))
}

/// Whether any root this repository searches holds the named script at
/// all, and only where every root could actually be looked at.
///
/// `Ok(false)` means every candidate answered `NotFound`, which is the one
/// reading that supports telling somebody nothing is rendered here. An
/// error is a search that did not happen and is returned as one.
///
/// Stat, not [`is_executable`], which cannot say why it said no. What a
/// copy that is there but will not run means is [`bind`]'s sentence, and
/// this is only ever asked after that sentence has been written.
pub(super) fn any_candidate(repo: &super::Repo, relative: &str) -> Result<bool> {
    for root in search_roots(repo) {
        for base in SKILL_ROOTS {
            let script = root.join(base).join(SKILL).join(relative);
            match std::fs::symlink_metadata(&script) {
                Ok(_) => return Ok(true),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(crate::error::CoreError::io(&script, error)),
            }
        }
    }
    Ok(false)
}

/// The package's script in a repository already resolved.
pub(super) fn installed_or_err(repo: &super::Repo, relative: &str) -> Result<Installed> {
    let Some(installed) = Installed::resolve(repo, relative) else {
        // A package that is here but cannot run is a broken install, and
        // says so; one that is not here at all is a different sentence.
        return Err(match Installed::present(repo) {
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
    Ok(installed)
}
