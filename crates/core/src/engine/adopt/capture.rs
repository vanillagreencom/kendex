//! Reading what the named tools hold, and capturing it into the local
//! source.
//!
//! One copy goes in, so every tool's copy has to be that copy: tools that
//! disagree refuse rather than being merged, and the position each one held
//! is cleared by an op rather than by anything this pass does to disk.
//! Project skills no longer come through here — they are their own source,
//! moved in place — so what is left is agents, and skills at global scope.

use std::fs;
use std::path::{Path, PathBuf};

use crate::apply::{Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, Scope};

use super::{SharedTarget, copies_differ, shared_target};

/// What the named tools have where the item goes: a shared folder several
/// of them link at, the plain copies they hold, and the links whose target
/// is gone.
pub(super) struct Seen {
    pub(super) shared: Option<(HarnessId, SharedTarget)>,
    pub(super) content: Vec<(HarnessId, PathBuf)>,
    pub(super) broken: Vec<(PathBuf, Pre)>,
}

/// One copy goes into the local source, so every tool's copy has to be that
/// copy. Picking one and writing it over the rest is how content gets lost,
/// and only the reader can say which to keep — so tools that disagree
/// refuse here rather than being merged.
pub(super) fn look(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    positions: &[(HarnessId, PathBuf)],
    local_item: &Path,
) -> Result<Seen> {
    let mut seen = Seen {
        shared: None,
        content: Vec::new(),
        broken: Vec::new(),
    };
    for (harness, original) in positions {
        if original.is_symlink() {
            let points_to = fs::read_link(original).map_err(|e| CoreError::io(original, e))?;
            // Broken link: content is gone; declaring is all adoption can
            // do. The link itself is cleared by a planned op — planning
            // never touches disk, so a plan that is never applied (or
            // fails) leaves the world as it was.
            if !original.exists() {
                seen.broken
                    .push((original.clone(), Pre::SymlinkTo { target: points_to }));
                continue;
            }
            let target = shared_target(env, scope, kind, name, original, points_to, local_item)?;
            match &seen.shared {
                Some((_, first)) if first.target == target.target => {}
                Some((first, _)) => return Err(copies_differ(name, *first, *harness)),
                None => seen.shared = Some((*harness, target)),
            }
            continue;
        }
        if original.exists() {
            seen.content.push((*harness, original.clone()));
        }
    }
    // A tool whose own position IS the folder the others link at holds the
    // same files, not a second copy — the hand-made sharing layout, where
    // one real folder sits at one tool's place and the rest read it through
    // links. Folded into the shared capture rather than called a
    // disagreement; only a position that resolves somewhere else is one.
    if let Some((_, shared)) = &seen.shared {
        let target = shared.target.clone();
        seen.content
            .retain(|(_, path)| path.canonicalize().is_ok_and(|at| at != target));
    }
    if let (Some((linked, _)), Some((held, _))) = (seen.shared.as_ref(), seen.content.first()) {
        return Err(copies_differ(name, *linked, *held));
    }
    if let Some((first, first_path)) = seen.content.first() {
        let hash = crate::hash::hash_tree(first_path)?;
        for (harness, path) in &seen.content[1..] {
            if crate::hash::hash_tree(path)? != hash {
                return Err(copies_differ(name, *first, *harness));
            }
        }
    }
    Ok(seen)
}

/// The one copy every tool had goes into the local source, and every
/// position it sat at is cleared. Nothing here runs at plan time: every
/// byte read becomes an op.
pub(super) fn capture_ops(
    kind: ItemKind,
    name: &str,
    content: &[(HarnessId, PathBuf)],
    local_item: &Path,
) -> Result<Vec<PlannedOp>> {
    let mut ops = Vec::new();
    let Some((_, source)) = content.first() else {
        return Ok(ops);
    };
    // A copy the local source already holds is not overwritten in place:
    // it goes to the trash first, where it can be got back.
    if local_item.exists() {
        ops.push(PlannedOp {
            description: format!("trash the local source's earlier copy of {name}"),
            op: Op::Trash {
                absent_is_done: false,
                path: local_item.to_path_buf(),
                pre: Pre::HashIs {
                    hash: crate::hash::hash_tree(local_item)?,
                },
            },
        });
    }
    let capture = match kind {
        ItemKind::Skill => Op::WriteTree {
            root: local_item.to_path_buf(),
            files: crate::capture::read_tree(source)?,
            pre: Pre::Absent,
        },
        _ => Op::WriteFile {
            path: local_item.to_path_buf(),
            bytes: fs::read(source).map_err(|e| CoreError::io(source, e))?,
            pre: Pre::Absent,
        },
    };
    ops.push(PlannedOp {
        description: format!("move {name} into the local source"),
        op: capture,
    });
    for (_, original) in content {
        ops.push(PlannedOp {
            description: format!("trash the unmanaged original at {}", original.display()),
            op: Op::Trash {
                absent_is_done: false,
                path: original.clone(),
                pre: Pre::Any,
            },
        });
    }
    Ok(ops)
}
