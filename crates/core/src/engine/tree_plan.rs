//! Planning a rendered tree and the harness-native link to it. The two swap
//! places over an item's life: a variant whose bytes match the shared tree
//! collapses onto it through a link, and one that grows past a tool's byte
//! cap gets a directory of its own. Both transitions land on a position we
//! already own, so both are ours to make — an unowned position is still a
//! conflict (invariant 6).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use super::compared::of_tree;
use super::desired::{Artifact, Desired};
use super::file_plan::{TAKEN_OVER, set_aside};
use super::item_plan::{Planned, unmanaged, unmanaged_compared};
use super::written::Written;
use super::{DriftCause, DriftState};
use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::hash::hash_tree;
use crate::model::Scope;

mod link;

#[allow(clippy::too_many_arguments)]
pub(super) fn plan_tree(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    replace_unmanaged: bool,
    owned: &BTreeSet<PathBuf>,
    written: &mut Written,
    ops: &mut Vec<PlannedOp>,
) -> Result<Planned> {
    let Artifact::Tree {
        canonical,
        files,
        link,
    } = &item.artifact
    else {
        return Ok(Planned::Clean);
    };
    let collapsed = match collapsed_link(env, scope, item, canonical, files, owned) {
        Ok(collapsed) => collapsed,
        Err(conflict) => return Ok(conflict),
    };
    // A file where a tree goes is unmanaged content in an awkward shape.
    // Its bytes are read here and moved aside below, with the position's
    // one claimant — two tools reading one tree both arrive here, and a
    // second trash op for a path the first one already emptied fails its
    // precondition and rolls the whole apply back. A socket or a device is
    // nobody's to move either way.
    let mut wrong_shape: Option<String> = None;
    if collapsed.is_none() && canonical.exists() && !canonical.is_dir() {
        if !canonical.is_file() || owned.contains(canonical) {
            return Ok(Planned::Conflict(format!(
                "a file sits at {}",
                crate::names::shown(&canonical.display().to_string())
            )));
        }
        match hash_tree(canonical) {
            Ok(hash) => wrong_shape = Some(hash),
            Err(error) => return Ok(uncomparable(canonical, &error)),
        }
    }
    let wanted = item.artifact.disk_hash();
    let readable = collapsed.is_none() && canonical.is_dir();
    let disk = match readable.then(|| hash_tree(canonical)).transpose() {
        Ok(disk) => disk,
        Err(error) => return Ok(uncomparable(canonical, &error)),
    };
    let mut result = Planned::Clean;
    if disk.as_deref() != Some(wanted.as_str()) {
        let unowned = wrong_shape.is_some()
            || (disk.is_some()
                && !owned.contains(canonical)
                && !written.canonicals.contains(canonical));
        if unowned && !replace_unmanaged {
            // The refusal ends the pass here, so the harness-native
            // position is never planned — and a take-over empties both.
            // The row carries the second one, or an offer built on it
            // names one directory and moves two.
            return Ok(also_in_the_way(
                in_the_way(canonical, files),
                unowned_link(link.as_deref(), owned),
            ));
        }
        result = match (disk.is_some() || collapsed.is_some(), unowned) {
            (_, true) => Planned::Drift(DriftState::Missing, TAKEN_OVER.into()),
            (true, false) => Planned::Drift(DriftState::Stale, "newer content is available".into()),
            (false, false) => Planned::Drift(DriftState::Missing, "not installed yet".into()),
        };
        if written.claim_canonical(canonical) {
            // Taken over, the tree goes to the trash whole rather than
            // being written through: what kendex did not write is kept
            // recoverable, never quietly merged under the new render.
            if let Some(hash) = wrong_shape.or_else(|| disk.clone().filter(|_| unowned)) {
                ops.push(set_aside(canonical, Pre::HashIs { hash }));
            }
            write_ops(
                item,
                canonical,
                files,
                &collapsed,
                disk.filter(|_| !unowned),
                link.is_some(),
                ops,
            );
        }
    }
    let Some(link) = link else {
        return Ok(result);
    };
    let linked = link::plan_link(
        scope,
        item,
        link,
        canonical,
        files,
        replace_unmanaged,
        owned,
        written,
        ops,
        &result,
    )?;
    // A take-over staged for the tree is what this item's row has to say:
    // the sweep reads the row back to know which items it settled, and a
    // link that merely is not connected yet must not hide the files going
    // to the trash. A refusal at the link still wins — the item plans
    // nothing then.
    Ok(match (&result, &linked) {
        (Planned::Drift(_, staged), Planned::Drift(..)) if staged == TAKEN_OVER => result,
        _ => linked,
    })
}

/// The harness-native position when it holds the person's own files too.
/// A link is never a take-over's target and a position kendex recorded
/// writing is its own to replace, so neither is named here.
fn unowned_link(link: Option<&Path>, owned: &BTreeSet<PathBuf>) -> Option<String> {
    let link = link?;
    (!link.is_symlink() && link.exists() && !owned.contains(link))
        .then(|| link.display().to_string())
}

/// Carry another in-the-way position on a refusal that already names one.
fn also_in_the_way(planned: Planned, more: Option<String>) -> Planned {
    match (planned, more) {
        (
            Planned::Unmanaged {
                cause,
                detail,
                compared,
                mut also,
            },
            Some(path),
        ) => {
            also.push(path);
            Planned::Unmanaged {
                cause,
                detail,
                compared,
                also,
            }
        }
        (planned, _) => planned,
    }
}

/// Files kendex did not write, where a tree goes. Adoption puts a folder
/// in the local source, so a folder there is something it can take and
/// anything else is not — said as the cause, because a surface that
/// offered to keep the wrong shape would fail on the click.
pub(super) fn in_the_way(path: &Path, files: &[(PathBuf, Vec<u8>)]) -> Planned {
    match path.is_dir() {
        // A folder against the folder that would replace it. The wrong
        // shape has no per-file answer — one file where a tree goes is
        // not a tree with one file differing — so it carries none.
        true => unmanaged_compared(DriftCause::UnmanagedContent, path, of_tree(path, files)),
        false => unmanaged(DriftCause::UnmanagedWrongShape, path),
    }
}

/// A link where the tree belongs is this installation's own collapse onto a
/// shared tree — some install recorded writing this position — so it comes
/// off before the directory that replaces it.
///
/// A link nobody recorded is somebody else's, and stays untouched. Where it
/// points at a real folder adoption can take, that is a state with a way
/// out rather than a dead end: the hand-made sharing layout, one folder
/// read by several tools. Asked through adoption's own boundary check, so
/// no surface offers a way out that would refuse.
fn collapsed_link(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    canonical: &Path,
    files: &[(PathBuf, Vec<u8>)],
    owned: &BTreeSet<PathBuf>,
) -> std::result::Result<Option<PathBuf>, Planned> {
    if !canonical.is_symlink() {
        return Ok(None);
    }
    if !owned.contains(canonical) {
        return Err(
            match super::adopt::link_target(env, scope, item.kind, &item.name, canonical) {
                // The folder the link points at is real content adoption
                // can take, so it compares like any other.
                Some(target) => {
                    unmanaged_compared(DriftCause::SharedLink, &target, of_tree(&target, files))
                }
                None => unmanaged(DriftCause::ForeignLink, canonical),
            },
        );
    }
    Ok(Some(std::fs::read_link(canonical).unwrap_or_default()))
}

#[allow(clippy::too_many_arguments)]
fn write_ops(
    item: &Desired,
    canonical: &Path,
    files: &[(PathBuf, Vec<u8>)],
    collapsed: &Option<PathBuf>,
    disk: Option<String>,
    // Whether a tool-native link points at this tree — which is what makes
    // it the shared one rather than this tool's own copy.
    shared: bool,
    ops: &mut Vec<PlannedOp>,
) {
    if let Some(target) = collapsed {
        ops.push(PlannedOp {
            description: format!(
                "Give {} its own copy of {} {}",
                item.harness.display_name(),
                item.kind.name(),
                item.name
            ),
            op: Op::Trash {
                absent_is_done: false,
                path: canonical.to_path_buf(),
                pre: Pre::SymlinkTo {
                    target: target.clone(),
                },
            },
        });
    }
    // Which position, in the words a reader has: on a project mid-migration
    // one tool is blocked and another is not, and a line naming neither the
    // tool nor the place reads as the write the conflict just refused.
    ops.push(PlannedOp {
        description: format!(
            "Write {} {}'s files for {}{}",
            item.kind.name(),
            item.name,
            item.harness.display_name(),
            match shared {
                true => ", in the folder its tools share",
                false => "",
            }
        ),
        op: Op::WriteTree {
            root: canonical.to_path_buf(),
            files: files.to_vec(),
            pre: match disk {
                Some(hash) => Pre::HashIs { hash },
                None => Pre::Absent,
            },
        },
    });
}

/// The harness-native position pointing at the tree. A directory sitting
/// there is the copy this installation had while it diverged: it goes to the
/// trash and the link takes its place.
/// An artifact we cannot hash is reported uncompared (invariant 12) — a read
/// error must never read as passing, and must not kill the scope.
pub(super) fn uncomparable(path: &Path, error: &crate::error::CoreError) -> Planned {
    Planned::Conflict(format!(
        "{} cannot be compared ({error}) — fix its permissions or remove it",
        path.display()
    ))
}
