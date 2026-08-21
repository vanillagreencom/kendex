//! Planning a rendered tree and the harness-native link to it. The two swap
//! places over an item's life: a variant whose bytes match the shared tree
//! collapses onto it through a link, and one that grows past a tool's byte
//! cap gets a directory of its own. Both transitions land on a position we
//! already own, so both are ours to make — an unowned position is still a
//! conflict (invariant 6).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use super::desired::{Artifact, Desired, artifact_disk_hash};
use super::file_plan::{TAKEN_OVER, set_aside};
use super::item_plan::{Claim, Planned, unmanaged};
use super::{DriftCause, DriftState};
use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::hash::hash_tree;
use crate::model::Scope;

#[allow(clippy::too_many_arguments)]
pub(super) fn plan_tree(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    claim: Claim,
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
    let collapsed = match collapsed_link(env, scope, item, canonical, owned) {
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
        if !canonical.is_file() || claim.owns(canonical, owned) {
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
    let wanted = artifact_disk_hash(&item.artifact);
    let readable = collapsed.is_none() && canonical.is_dir();
    let disk = match readable.then(|| hash_tree(canonical)).transpose() {
        Ok(disk) => disk,
        Err(error) => return Ok(uncomparable(canonical, &error)),
    };
    let mut result = Planned::Clean;
    if disk.as_deref() != Some(wanted.as_str()) {
        let unowned = wrong_shape.is_some()
            || (disk.is_some()
                && !claim.owns(canonical, owned)
                && !written.canonicals.contains(canonical));
        if unowned && !claim.replace_unmanaged {
            return Ok(in_the_way(canonical));
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
    plan_link(
        env, item, link, canonical, claim, owned, written, ops, result,
    )
}

/// Positions this pass has already planned a write for. Two harnesses can
/// read one physical tree — and, where a global root is pointed at another
/// tool's, one link — and planning the same write twice fails the second op
/// and rolls the whole apply back.
#[derive(Default)]
pub(super) struct Written {
    pub(super) canonicals: BTreeSet<PathBuf>,
    links: BTreeSet<PathBuf>,
    /// What the item being planned right now claimed. A refusal is reached
    /// after the tree half has already claimed its position, and a claim
    /// left standing for an item that plans nothing would silently drop the
    /// next harness's install of the same tree.
    claimed: Vec<Claimed>,
}

enum Claimed {
    Canonical(PathBuf),
    Link(PathBuf),
}

impl Written {
    /// Start one item's pass. What it claims from here is undone together.
    pub(super) fn start_item(&mut self) {
        self.claimed.clear();
    }

    /// Take back everything the item just claimed — it plans nothing.
    pub(super) fn undo_item(&mut self) {
        for claimed in self.claimed.drain(..) {
            match claimed {
                Claimed::Canonical(path) => self.canonicals.remove(&path),
                Claimed::Link(path) => self.links.remove(&path),
            };
        }
    }

    /// Whether this pass is the one that claims the position.
    fn claim_canonical(&mut self, path: &Path) -> bool {
        let first = self.canonicals.insert(path.to_path_buf());
        if first {
            self.claimed.push(Claimed::Canonical(path.to_path_buf()));
        }
        first
    }

    fn claim_link(&mut self, path: &Path) -> bool {
        let first = self.links.insert(path.to_path_buf());
        if first {
            self.claimed.push(Claimed::Link(path.to_path_buf()));
        }
        first
    }
}

/// Files kendex did not write, where a tree goes. Adoption puts a folder
/// in the local source, so a folder there is something it can take and
/// anything else is not — said as the cause, because a surface that
/// offered to keep the wrong shape would fail on the click.
fn in_the_way(path: &Path) -> Planned {
    let cause = match path.is_dir() {
        true => DriftCause::UnmanagedContent,
        false => DriftCause::UnmanagedWrongShape,
    };
    unmanaged(cause, path)
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
    owned: &BTreeSet<PathBuf>,
) -> std::result::Result<Option<PathBuf>, Planned> {
    if !canonical.is_symlink() {
        return Ok(None);
    }
    if !owned.contains(canonical) {
        return Err(
            match super::adopt_shared::link_target(env, scope, item.kind, &item.name, canonical) {
                Some(target) => unmanaged(DriftCause::SharedLink, &target),
                None => Planned::Conflict(format!(
                    "{} is a link kendex did not create",
                    canonical.display()
                )),
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
#[allow(clippy::too_many_arguments)]
fn plan_link(
    env: &Env,
    item: &Desired,
    link: &Path,
    canonical: &Path,
    claim: Claim,
    owned: &BTreeSet<PathBuf>,
    written: &mut Written,
    ops: &mut Vec<PlannedOp>,
    result: Planned,
) -> Result<Planned> {
    if link.is_symlink() {
        let points_to = std::fs::read_link(link).unwrap_or_default();
        if points_to == canonical {
            return Ok(result);
        }
        // A target that is the canonical tree under its pre-rename spelling
        // is our own: only kendex ever pointed links there, so the position
        // is ours to replace (invariant 6). The first-launch move carries
        // the trees but cannot rewrite links scattered across harness dirs
        // — this relink is what reconnects them.
        if env.legacy_app_path(canonical).as_deref() != Some(points_to.as_path()) {
            return Ok(Planned::Conflict(format!(
                "{} links somewhere kendex does not own ({})",
                link.display(),
                points_to.display()
            )));
        }
        if written.claim_link(link) {
            ops.push(PlannedOp {
                description: format!(
                    "Drop {}'s link to the app's old folder",
                    item.harness.display_name()
                ),
                op: Op::Trash {
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
                    target: canonical.to_path_buf(),
                    pre: Pre::Absent,
                },
            });
        }
        return Ok(Planned::Drift(
            DriftState::Stale,
            format!(
                "{} still reads the app's old folder",
                item.harness.display_name()
            ),
        ));
    }
    let diverged = link.exists();
    let unowned = diverged && !claim.owns(link, owned);
    if unowned && !claim.replace_unmanaged {
        return Ok(in_the_way(link));
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
                target: canonical.to_path_buf(),
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

/// An artifact we cannot hash is reported uncompared (invariant 12) — a read
/// error must never read as passing, and must not kill the scope.
fn uncomparable(path: &Path, error: &crate::error::CoreError) -> Planned {
    Planned::Conflict(format!(
        "{} cannot be compared ({error}) — fix its permissions or remove it",
        path.display()
    ))
}
