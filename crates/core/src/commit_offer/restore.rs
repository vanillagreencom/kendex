//! Putting a pending kendex change back to what the last commit holds.
//!
//! One of the two ways out of a change a person does not want, and the one
//! git answers: the committed content comes back over what stands in the
//! working tree now. The other way out is the engine's — discard the direct
//! edits and render the package again from its source and customization —
//! and it answers a different question, so nothing here is worded as if it
//! did. A rendering restored to its committed bytes is still a rendering
//! whose source has moved on.
//!
//! Three rules shape it.
//!
//! **Only what the offer covers.** The set is re-read here, so a path the
//! person names is restored only where kendex still owns it and it still
//! differs. Everything else in the repository is theirs.
//!
//! **The index is not touched.** `git restore --worktree` writes the
//! working tree and leaves the index exactly as it was, so a change the
//! person staged themselves survives a restore of the same path.
//!
//! **Removal never deletes.** A path the last commit does not hold — one
//! kendex added — is taken away by moving it to the trash, the same way
//! every other kendex removal takes something off disk.

use std::collections::BTreeSet;
use std::io;
use std::path::Path;

use crate::engine::GeneratedPaths;
use crate::env::Env;
use crate::model::Scope;
use crate::process::Hardened;

use super::pathspec::{self, Spec};
use super::{Failed, Refusal, Step, git};

/// What restoring the named paths does, path by path. The same value is
/// the preview a person confirms and the account of what ran.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RestorePlan {
    /// Paths whose committed content comes back over what stands there now.
    pub restored: Vec<String>,
    /// Paths the last commit does not hold. Restoring means taking them
    /// away, which kendex does by moving them to the trash.
    pub removed: Vec<String>,
    /// Paths named that the offer no longer covers: they have changed back,
    /// or kendex no longer owns them.
    pub dropped: Vec<String>,
    /// Paths not named that were taken in anyway, because what is being
    /// restored cannot stand without it: the inventory that records which
    /// paths kendex renders here.
    pub added: Vec<String>,
    /// Paths this restore changes that the next write into this project
    /// would write again, because kendex still renders them.
    ///
    /// A restore moves the working tree. It does not change what kendex is
    /// asked to render, and it cannot undo a commit of the declaration that
    /// asks for it — kendex never moves a ref backwards. So a render taken
    /// away here comes back the next time kendex writes in this project,
    /// and one put back to its committed bytes is written over. Naming them
    /// is the whole of what kendex can do about it: the way to stop one is
    /// to change the package or the project's manifest, which is a
    /// different operation and says so.
    pub rerendered: Vec<String>,
}

impl RestorePlan {
    /// Whether this plan would change anything at all.
    pub fn empty(&self) -> bool {
        self.restored.is_empty() && self.removed.is_empty()
    }
}

/// What restoring `chosen` would do, without doing any of it.
pub fn restore_plan(
    scope: &Scope,
    generated: &GeneratedPaths,
    chosen: &BTreeSet<String>,
) -> Result<RestorePlan, Failed> {
    let Some(scan) = super::scan(scope, generated)? else {
        return Ok(RestorePlan {
            dropped: chosen.iter().cloned().collect(),
            ..RestorePlan::default()
        });
    };
    let covered: BTreeSet<&str> = scan.owned.iter().map(|owned| owned.path.as_str()).collect();
    let dropped: Vec<String> = chosen
        .iter()
        .filter(|path| !covered.contains(path.as_str()))
        .cloned()
        .collect();
    let taken: BTreeSet<String> = chosen
        .iter()
        .filter(|path| covered.contains(path.as_str()))
        .cloned()
        .collect();
    let declarations: BTreeSet<String> = crate::engine::generated_paths::companions(&scan.root)
        .iter()
        .filter_map(|path| {
            path.strip_prefix(&scan.root)
                .ok()
                .map(crate::paths::slashed)
        })
        .collect();
    // A restore that changes which paths exist is a restore of what kendex
    // renders here, and the file that records what it renders has to go back
    // with it — otherwise the inventory names a set the tree no longer
    // holds. It is kendex's own file end to end, which is what makes writing
    // over it whole allowed; the manifest is not, and is not among them.
    let structural = taken
        .iter()
        .any(|path| !declarations.contains(path) && changes_existence(&scan, path));
    let added: Vec<String> = match structural {
        false => Vec::new(),
        true => declarations
            .iter()
            .filter(|path| covered.contains(path.as_str()) && !taken.contains(*path))
            .cloned()
            .collect(),
    };
    let whole: BTreeSet<String> = taken.iter().chain(&added).cloned().collect();
    // What this plan still renders. A path in it is one the next write puts
    // back or writes over, whatever this restore does to the working tree.
    let rendered: BTreeSet<String> = generated
        .whole
        .iter()
        .filter_map(|path| {
            path.strip_prefix(&scan.root)
                .ok()
                .map(crate::paths::slashed)
        })
        .collect();
    let rerendered: Vec<String> = whole
        .iter()
        .filter(|path| rendered.contains(*path))
        .cloned()
        .collect();
    // Asked of the exit status, so a repository git could not read refuses
    // rather than answering "no commit" — which would put every chosen path
    // in `removed` and trash the files the person asked to put back.
    let born = git::born(&scan.root)?;
    let mut plan = RestorePlan {
        dropped,
        added,
        rerendered,
        ..RestorePlan::default()
    };
    for path in whole {
        match born && committed(&scan.root, &path)? {
            true => plan.restored.push(path),
            false => plan.removed.push(path),
        }
    }
    plan.restored.sort();
    plan.removed.sort();
    Ok(plan)
}

/// A restore that stopped part-way, and what it had already written.
///
/// Returned boxed: it carries a whole plan, which is four path lists, and an
/// error that large on every `Ok` is what `clippy::result_large_err` names.
///
/// A restore writes the working tree in two passes, and a failure in the
/// second one leaves the first standing. Reporting that as a bare refusal
/// would tell a person nothing happened while their files had already moved,
/// so what did happen travels with the failure — the same shape
/// [`super::CommitFailure`] uses for the paths a refused commit left staged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreFailure {
    pub failed: Failed,
    /// What had already been written when the failure came: the paths whose
    /// committed content is back, and the paths already moved to the trash.
    /// Empty where the restore stopped before writing anything.
    pub done: RestorePlan,
}

impl From<Failed> for Box<RestoreFailure> {
    fn from(failed: Failed) -> Box<RestoreFailure> {
        Box::new(RestoreFailure {
            failed,
            done: RestorePlan::default(),
        })
    }
}

/// Run the plan and hand back what it did.
///
/// The plan is derived here rather than taken from the caller: a preview a
/// person read a moment ago describes a project that may have moved on, and
/// the one thing a restore may never do is take a path the offer has
/// stopped covering.
///
/// A failure carries what was already written. The `git restore` pass is one
/// call and lands whole or not at all; the removals are one path at a time,
/// so a failure among them names the ones already gone.
pub fn restore(
    env: &Env,
    scope: &Scope,
    generated: &GeneratedPaths,
    chosen: &BTreeSet<String>,
) -> Result<RestorePlan, Box<RestoreFailure>> {
    let plan = restore_plan(scope, generated, chosen).map_err(Box::<RestoreFailure>::from)?;
    let Scope::Project { root } = scope else {
        return Ok(plan);
    };
    // Nothing has been written yet, so a failure in this pass carries an
    // empty account: `git restore` writes every named path or none.
    if !plan.restored.is_empty() {
        let spec =
            Spec::write(&plan.restored, Step::Restore).map_err(Box::<RestoreFailure>::from)?;
        let mut args = vec![
            "restore".to_owned(),
            "--source=HEAD".to_owned(),
            "--worktree".to_owned(),
        ];
        args.extend(spec.args());
        let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
        git::run(Hardened::git(&borrowed, Some(root)), Step::Restore)
            .map_err(Box::<RestoreFailure>::from)?;
    }
    // Past this point the restored paths are on disk, so every failure below
    // reports them alongside the removals that had already gone.
    let mut done = RestorePlan {
        restored: plan.restored.clone(),
        rerendered: plan.rerendered.clone(),
        ..RestorePlan::default()
    };
    let stopped = |done: &RestorePlan, failed: Failed| {
        Box::new(RestoreFailure {
            failed,
            done: done.clone(),
        })
    };
    for path in &plan.removed {
        // The path is one git itself reported inside this project and the
        // set was re-read a moment ago, so it names a file here and not a
        // place a link could carry the removal out to: `move_to_trash` moves
        // what stands at the path without following it.
        let whole = root.join(path);
        match std::fs::symlink_metadata(&whole) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(stopped(&done, io_refused(&whole, &error))),
            Ok(_) => {}
        }
        if let Err(error) = crate::fs::move_to_trash(env, &whole) {
            return Err(stopped(
                &done,
                Failed {
                    step: Step::Restore,
                    refusal: Refusal::Said(vec![error.to_string()]),
                },
            ));
        }
        done.removed.push(path.clone());
    }
    Ok(plan)
}

/// Whether restoring this path changes which paths exist, rather than only
/// what one of them holds: a path kendex added, or one it took away.
///
/// Absence is asked without following a link. `exists` reports a link whose
/// target has gone as absent, and a link kendex rewrote is a rewrite rather
/// than a removal.
fn changes_existence(scan: &super::Scan, path: &str) -> bool {
    scan.owned
        .iter()
        .find(|owned| owned.path == path)
        .is_some_and(|owned| owned.added || gone(&scan.root.join(path)))
}

/// Whether nothing stands at this path. A read the machine refused is not
/// absence, and answers `false`: the plan then treats the path as one whose
/// content comes back, which `git restore` answers for on its own.
fn gone(whole: &Path) -> bool {
    matches!(
        whole.symlink_metadata(),
        Err(error) if error.kind() == io::ErrorKind::NotFound
    )
}

/// Whether the last commit holds a file at this path.
///
/// `ls-tree` answers the question it was asked: it exits 0 and prints
/// nothing for a path `HEAD` does not hold, so a non-zero exit is git
/// failing and travels as the failure it is rather than as "kendex added
/// this", which would turn a restore into a removal.
///
/// The path sits in a pathspec position, so it goes through
/// [`pathspec::literal`] the way every other pathspec this module hands
/// git does: a path read as a pattern would answer about a different file,
/// and this answer decides whether the path is put back or trashed.
fn committed(root: &Path, path: &str) -> Result<bool, Failed> {
    let listed = git::read_required(root, &["ls-tree", "HEAD", "--", &pathspec::literal(path)])?;
    let text = String::from_utf8_lossy(&listed);
    Ok(text
        .lines()
        .next()
        .and_then(|entry| entry.split_whitespace().nth(1))
        .is_some_and(|kind| kind == "blob"))
}

fn io_refused(at: &Path, error: &io::Error) -> Failed {
    Failed {
        step: Step::Restore,
        refusal: Refusal::Said(vec![format!("{}: {error}", crate::paths::slashed(at))]),
    }
}
