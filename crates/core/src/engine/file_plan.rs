//! Planning one rendered file: the artifact itself, and the toggled name
//! its content parks under while it is switched off. A position the lock
//! says is ours is ours to rewrite; anything else on it is the user's, and
//! only an explicit take-over moves it (invariant 6).

use std::collections::BTreeSet;
use std::path::PathBuf;

use super::compared::of_file;
use super::desired::{Artifact, Desired};
use super::item_plan::{Planned, unmanaged, unmanaged_compared};
use super::{DriftCause, DriftState};
use crate::apply::{Description, Op, PlannedOp, Pre};
use crate::env::Env;
use crate::error::Result;
use crate::hash::hash_tree;
use crate::model::Scope;

pub(super) fn plan_file(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    replace_unmanaged: bool,
    owned: &BTreeSet<PathBuf>,
    ops: &mut Vec<PlannedOp>,
) -> Result<Planned> {
    let Artifact::File { path, bytes } = &item.artifact else {
        return Ok(Planned::Clean);
    };
    plan_written_file(env, scope, item, path, bytes, replace_unmanaged, owned, ops)
}

#[allow(clippy::too_many_arguments)]
pub(super) fn plan_written_file(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    path: &std::path::Path,
    bytes: &[u8],
    replace_unmanaged: bool,
    owned: &BTreeSet<PathBuf>,
    ops: &mut Vec<PlannedOp>,
) -> Result<Planned> {
    if path.is_symlink() {
        return Ok(unmanaged(DriftCause::ForeignLink, path));
    }
    if path.exists() && !path.is_file() {
        // A directory where a file goes is unmanaged content in an awkward
        // shape: taken over it goes to the trash whole and the file lands
        // in its place. Refused, it carries its own cause — adoption puts
        // one file in the local source and cannot read a folder as one, so
        // a row that offered to keep it would fail on the click. Anything
        // that is neither a file nor a directory — a socket, a device — is
        // nobody's to move.
        if !path.is_dir() || owned.contains(path) {
            return Ok(Planned::Conflict(format!(
                "a directory sits at {}",
                crate::names::shown(&path.display().to_string())
            )));
        }
        if !replace_unmanaged {
            return Ok(unmanaged(DriftCause::UnmanagedWrongShape, path));
        }
        let hash = match hash_tree(path) {
            Ok(hash) => hash,
            Err(error) => return Ok(uncomparable(path, &error)),
        };
        ops.push(set_aside(path, Pre::HashIs { hash }));
        ops.push(install(env, scope, item, path, bytes, Pre::Absent));
        return Ok(Planned::Drift(DriftState::Missing, TAKEN_OVER.into()));
    }
    // An artifact we cannot hash is reported uncompared (invariant 12) —
    // a read error must never read as passing, and must not kill the scope.
    let disk = match path.is_file().then(|| hash_tree(path)).transpose() {
        Ok(disk) => disk,
        Err(error) => return Ok(uncomparable(path, &error)),
    };
    let wanted = crate::hash::hash_bytes(bytes);
    match disk {
        Some(current) if current == wanted => Ok(Planned::Clean),
        Some(current) => {
            if !ours(path, owned) {
                if !replace_unmanaged {
                    return Ok(unmanaged_compared(
                        DriftCause::UnmanagedContent,
                        path,
                        of_file(path, bytes),
                    ));
                }
                ops.push(set_aside(path, Pre::HashIs { hash: current }));
                ops.push(install(env, scope, item, path, bytes, Pre::Absent));
                return Ok(Planned::Drift(DriftState::Missing, TAKEN_OVER.into()));
            }
            ops.push(PlannedOp {
                description: format!(
                    "Update {} {} for {}{}",
                    item.kind.name(),
                    item.name,
                    item.harness.display_name(),
                    advisory(env, scope, item)
                )
                .into(),
                op: Op::WriteFile {
                    path: path.to_path_buf(),
                    bytes: bytes.to_vec(),
                    pre: Pre::HashIs { hash: current },
                },
            });
            Ok(Planned::Drift(
                DriftState::Stale,
                "newer content is available".into(),
            ))
        }
        None => Ok(plan_absent_file(
            env,
            scope,
            item,
            path,
            bytes,
            replace_unmanaged,
            owned,
            ops,
        )),
    }
}

/// What a drift row says when the take-over is on: the files in the way are
/// recoverable, and the plan says where they went.
pub(super) const TAKEN_OVER: &str =
    "not installed yet — the files already there will be moved to the trash";

/// Nothing at the target: our own content may be waiting under the toggled
/// name, otherwise this is a fresh install. Anything else occupying the
/// toggled name belongs to someone else and is never written through.
#[allow(clippy::too_many_arguments)]
fn plan_absent_file(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    path: &std::path::Path,
    bytes: &[u8],
    replace_unmanaged: bool,
    owned: &BTreeSet<PathBuf>,
    ops: &mut Vec<PlannedOp>,
) -> Planned {
    let alternate = toggle_sibling(path);
    if alternate.is_symlink() {
        return unmanaged(DriftCause::ForeignLink, &alternate);
    }
    if alternate.is_file() {
        if !ours(path, owned) {
            if !replace_unmanaged {
                return unmanaged_compared(
                    DriftCause::UnmanagedContent,
                    &alternate,
                    of_file(&alternate, bytes),
                );
            }
            let hash = match hash_tree(&alternate) {
                Ok(hash) => hash,
                Err(error) => return uncomparable(&alternate, &error),
            };
            ops.push(set_aside(&alternate, Pre::HashIs { hash }));
            ops.push(install(env, scope, item, path, bytes, Pre::Absent));
            return Planned::Drift(DriftState::Missing, TAKEN_OVER.into());
        }
        // As it sits, not as it reads: a link to the same bytes put where
        // the file was is not the file the plan looked at.
        let from_pre = match Pre::tree_as_is(&alternate) {
            Ok(pre) => pre,
            Err(error) => return uncomparable(&alternate, &error),
        };
        let flip = if item.enabled { "on" } else { "off" };
        ops.push(PlannedOp {
            description: format!("Turn {} {flip}", item.name).into(),
            op: Op::Rename {
                from_pre,
                from: alternate,
                to: path.to_path_buf(),
                to_pre: Pre::Absent,
            },
        });
        ops.push(install(env, scope, item, path, bytes, Pre::Any));
        return Planned::Drift(DriftState::Stale, format!("should be turned {flip}"));
    }
    ops.push(install(env, scope, item, path, bytes, Pre::Absent));
    Planned::Drift(DriftState::Missing, "not installed yet".into())
}

/// The files kendex did not write leave for the trash before the render
/// takes their place — recoverable, and bound to the exact bytes the plan
/// read (invariants 6 and 7).
/// The path is shown, not printed: these bytes were written by something
/// that is not kendex, and a folder name carrying an escape sequence must
/// reach a terminal as its own characters.
/// The two halves of what [`set_aside`] writes, so the pass that has to
/// recognise one of its ops reads them from here rather than spelling the
/// sentence a second time.
const SET_ASIDE: (&str, &str) = ("Move the files already at ", " to the trash");

/// Whether this op is one [`set_aside`] built — the take-over that moves
/// what kendex did not write out of the way. Asked by the pass that rolls
/// an item's staged work back, which has to know whether the item it is
/// dropping had been swept up.
pub(super) fn is_set_aside(op: &PlannedOp) -> bool {
    op.description == Description::around(SET_ASIDE.0, SET_ASIDE.1)
}

pub(super) fn set_aside(path: &std::path::Path, pre: Pre) -> PlannedOp {
    PlannedOp {
        description: Description::around(SET_ASIDE.0, SET_ASIDE.1),
        op: Op::Trash {
            absent_is_done: false,
            path: path.to_path_buf(),
            pre,
        },
    }
}

fn install(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    path: &std::path::Path,
    bytes: &[u8],
    pre: Pre,
) -> PlannedOp {
    PlannedOp {
        description: format!(
            "Install {} {} for {}{}",
            item.kind.name(),
            item.name,
            item.harness.display_name(),
            advisory(env, scope, item)
        )
        .into(),
        op: Op::WriteFile {
            path: path.to_path_buf(),
            bytes: bytes.to_vec(),
            pre,
        },
    }
}

/// A hook the tool only reads is named as such wherever the plan is shown.
/// An op that reads like protection must not hide that this tool is free to
/// ignore what it installs. Read through `hook_enforcement`, so a Pi hook
/// with no carrier registered anywhere is labeled advisory, not enforced.
pub(super) fn advisory(env: &Env, scope: &Scope, item: &Desired) -> &'static str {
    use crate::harness::Enforcement;
    if item.kind != crate::model::ItemKind::Hook {
        return "";
    }
    match crate::harness::hook_enforcement(env, scope, item.harness) {
        Enforcement::Advisory => " (advisory)",
        Enforcement::Enforced | Enforcement::NotApplicable => "",
    }
}

/// An artifact we cannot hash is reported uncompared (invariant 12) — a
/// read error must never read as passing, and must not kill the scope.
fn uncomparable(path: &std::path::Path, error: &crate::error::CoreError) -> Planned {
    Planned::Conflict(format!(
        "{} cannot be compared ({error}) — fix its permissions or remove it",
        crate::names::shown(&path.display().to_string())
    ))
}

/// A declared-disabled artifact keeps its content under the `.disabled`
/// name; toggling is a rename.
/// Whether the bytes at this position are kendex's own.
///
/// A recorded install names one spelling of the toggled pair — an artifact
/// switched off parks its content under the suffixed name and the lock
/// still holds the plain one — and the position is the same one either
/// way. Asking about the spelling alone reads a switched-off install of
/// ours as somebody else's files, which blocks its next update behind a
/// take-over.
pub(super) fn ours(path: &std::path::Path, owned: &BTreeSet<PathBuf>) -> bool {
    owned.contains(path) || owned.contains(&toggle_sibling(path))
}

pub(super) fn toggle_sibling(path: &std::path::Path) -> std::path::PathBuf {
    let text = path.display().to_string();
    match text.strip_suffix(".disabled") {
        Some(base) => std::path::PathBuf::from(base),
        None => std::path::PathBuf::from(format!("{text}.disabled")),
    }
}
