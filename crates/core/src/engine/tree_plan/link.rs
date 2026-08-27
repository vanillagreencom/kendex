//! The harness-native position pointing at a rendered tree.
//!
//! Inside a project the link's text is relative, so the pair is committed
//! once and resolves in every clone of the repository. An absolute link is
//! the same tree named the way one machine spells it: ours to rewrite,
//! reported as drift, converged by a single apply.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use super::{in_the_way, uncomparable};
use crate::apply::{Op, PlannedOp, Pre};
use crate::engine::DriftState;
use crate::engine::desired::Desired;
use crate::engine::file_plan::{TAKEN_OVER, set_aside};
use crate::engine::item_plan::Planned;
use crate::engine::written::Written;
use crate::error::Result;
use crate::hash::hash_tree;
use crate::model::Scope;

#[allow(clippy::too_many_arguments)]
pub(super) fn plan_link(
    scope: &Scope,
    item: &Desired,
    link: &Path,
    canonical: &Path,
    files: &[(PathBuf, Vec<u8>)],
    replace_unmanaged: bool,
    owned: &BTreeSet<PathBuf>,
    written: &mut Written,
    ops: &mut Vec<PlannedOp>,
    result: &Planned,
) -> Result<Planned> {
    // The text this link is meant to hold. Inside a project it is relative,
    // so the pair is committed once and resolves in every clone of it.
    let spelled = crate::fs::spelling(project_root(scope), canonical, link);
    if link.is_symlink() {
        return relink(item, link, canonical, spelled, written, ops, result);
    }
    let diverged = link.exists();
    let unowned = diverged && !owned.contains(link);
    if unowned && !replace_unmanaged {
        return Ok(in_the_way(link, files));
    }
    let first = written.claim_link(link);
    if diverged && first {
        let hash = match hash_tree(link) {
            Ok(hash) => hash,
            Err(error) => return Ok(uncomparable(link, &error)),
        };
        ops.push(match unowned {
            true => set_aside(link, Pre::HashIs { hash }),
            false => PlannedOp {
                description: format!(
                    "Put {} back on the shared {} {}",
                    item.harness.display_name(),
                    item.kind.name(),
                    item.name
                ),
                op: Op::Trash {
                    absent_is_done: false,
                    path: link.to_path_buf(),
                    pre: Pre::HashIs { hash },
                },
            },
        });
    }
    if first {
        ops.push(PlannedOp {
            description: format!(
                "Connect {} to {} {}",
                item.harness.display_name(),
                item.kind.name(),
                item.name
            ),
            op: Op::Symlink {
                link: link.to_path_buf(),
                target: spelled,
                pre: Pre::Absent,
            },
        });
    }
    let tool = item.harness.display_name();
    Ok(match (diverged, unowned) {
        (_, true) => Planned::Drift(DriftState::Missing, TAKEN_OVER.into()),
        (true, false) => Planned::Drift(
            DriftState::Stale,
            format!("{tool}'s own copy is no longer needed"),
        ),
        (false, false) => {
            Planned::Drift(DriftState::Missing, format!("{tool} is not connected yet"))
        }
    })
}

/// A link already sitting where the tree is read from. Three answers: the
/// text is already the one a clone can follow; it names the same tree the
/// way an older install spelled it, which is ours to rewrite; or it points
/// somewhere kendex never wrote, which stays the person's.
#[allow(clippy::too_many_arguments)]
fn relink(
    item: &Desired,
    link: &Path,
    canonical: &Path,
    spelled: PathBuf,
    written: &mut Written,
    ops: &mut Vec<PlannedOp>,
    result: &Planned,
) -> Result<Planned> {
    let points_to = std::fs::read_link(link).unwrap_or_default();
    if points_to == spelled {
        return Ok(result.clone());
    }
    let tool = item.harness.display_name();
    // The same tree named the way an older install spelled it. It reads
    // correctly on the machine that wrote it and nowhere else, so it is ours
    // to rewrite rather than a conflict — one apply between it and a link a
    // teammate's checkout can follow.
    if crate::fs::points_at(link, &points_to, canonical) {
        if written.claim_link(link) {
            respell(
                item,
                link,
                format!(
                    "Point {tool}'s link at {} {} the way a clone reads it",
                    item.kind.name(),
                    item.name
                ),
                points_to,
                spelled,
                ops,
            );
        }
        return Ok(Planned::Drift(
            DriftState::Stale,
            format!("{tool}'s link names this machine, so a clone of the project cannot follow it"),
        ));
    }
    Ok(Planned::Conflict(format!(
        "{} links somewhere kendex does not own ({})",
        link.display(),
        points_to.display()
    )))
}

/// Swap a link's text for one a checkout elsewhere can follow. The old text
/// is the precondition, so a link repointed between plan and apply aborts
/// rather than being quietly reeled in.
fn respell(
    item: &Desired,
    link: &Path,
    why: String,
    points_to: PathBuf,
    spelled: PathBuf,
    ops: &mut Vec<PlannedOp>,
) {
    ops.push(PlannedOp {
        description: why,
        op: Op::Trash {
            absent_is_done: false,
            path: link.to_path_buf(),
            pre: Pre::SymlinkTo { target: points_to },
        },
    });
    ops.push(PlannedOp {
        description: format!(
            "Connect {} to {} {}",
            item.harness.display_name(),
            item.kind.name(),
            item.name
        ),
        op: Op::Symlink {
            link: link.to_path_buf(),
            target: spelled,
            pre: Pre::Absent,
        },
    });
}

/// The tree a link and its target both have to survive being moved inside,
/// or nothing at global scope — where a harness directory and the app's own
/// folder share no root a relative path could be read against.
fn project_root(scope: &Scope) -> Option<&Path> {
    match scope {
        Scope::Project { root } => Some(root),
        Scope::Global => None,
    }
}
