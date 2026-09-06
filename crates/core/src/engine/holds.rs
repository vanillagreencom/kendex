//! The holds that outrank planning: situations where the right plan for
//! an item is to write nothing at all and say why — a revision wanted two
//! ways at once, or bytes the user's hands were on.

use std::collections::BTreeSet;

use std::path::PathBuf;

use super::desired::{Artifact, Desired};
use super::item_plan::PlanSink;
use super::{DriftCause, DriftRow, DriftState, ForkEdit};
use crate::env::Env;
use crate::lock::{Lock, LockEntry};
use crate::model::Scope;

/// An item wanted at two revisions at once writes nothing: the conflict
/// row says so, the existing install and its record stay exactly as they
/// were, and the expansion's warning already names the fix. Returns true
/// when the item was held back this way.
pub(super) fn hold_rev_conflict(
    item: &Desired,
    scope: &Scope,
    lock: &Lock,
    conflicts: &BTreeSet<(crate::model::ItemKind, String)>,
    sink: &mut PlanSink,
) -> bool {
    if !conflicts.contains(&(item.kind, item.name.clone())) {
        return false;
    }
    sink.drift.push(DriftRow {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        scope: scope.clone(),
        state: DriftState::Conflict,
        detail: "wanted at two different revisions — nothing was changed".into(),
        cause: None,
        compared: None,
        also_in_the_way: Vec::new(),
    });
    if let Some(entry) = lock.entries.get(&item.key) {
        sink.new_lock
            .entries
            .insert(item.key.clone(), entry.clone());
    }
    true
}

/// What the artifact's bytes on disk hash to right now — `None` when there
/// is nothing comparable (absent, a symlink where content should be, a
/// registration, unreadable). `None` never blocks: the paths that need a
/// human already produce conflicts of their own.
///
/// A toggled-off installation keeps its content under the `.disabled`
/// sibling, so enabling it plans against a path that does not exist yet;
/// the sibling is checked too, or an edit made while the item was off
/// would be overwritten the moment it came back on.
fn observed_artifact_hash(artifact: &Artifact) -> Option<String> {
    let here = |p: &std::path::Path| {
        (!p.is_symlink() && p.exists())
            .then(|| crate::hash::hash_tree(p).ok())
            .flatten()
    };
    let path = compared_position(artifact)?;
    here(path).or_else(|| here(&disabled_sibling(path)))
}

/// The one position an artifact's bytes are read at. Only the backing
/// script of a registration is ours to compare; the shared config it also
/// edits holds other people's keys.
fn compared_position(artifact: &Artifact) -> Option<&std::path::Path> {
    match artifact {
        Artifact::File { path, .. } => Some(path),
        Artifact::Tree { canonical, .. } => Some(canonical),
        Artifact::Registration {
            script: Some((path, _)),
            ..
        } => Some(path),
        Artifact::Registration { script: None, .. } => None,
    }
}

/// A path with the toggled-off suffix stripped: an enabled render and its
/// disabled twin are one location.
fn base_position(path: &std::path::Path) -> PathBuf {
    let text = path.display().to_string();
    text.strip_suffix(".disabled")
        .map(PathBuf::from)
        .unwrap_or_else(|| path.to_path_buf())
}

/// Whether this entry recorded writing the position the bytes were read
/// at. An entry's word covers where it actually wrote, never every
/// position the declaration now points at — an installation that changed
/// how it installs compares against somewhere it never wrote, and reading
/// that as its own edit puts a stranger's files under the edit gate, where
/// neither way out reaches them.
fn recorded_at(env: &Env, scope: &Scope, entry: &LockEntry, position: &std::path::Path) -> bool {
    let position = base_position(position);
    super::owned::installed(env, scope, entry)
        .files
        .iter()
        .any(|owned| base_position(owned) == position)
}

/// One tool's install of a shared artifact, edited by hand, and a second
/// tool now declared over the same physical position. Nothing is recorded
/// for the second installation, so its own record cannot hold it — but the
/// bytes are kendex's own output with the user's hands on them, and the
/// second tool is not the one to decide their fate. Without this the edit
/// protection would read as an unmanaged position: a refusal calling our
/// own output a stranger's, and a take-over free to trash it.
fn hold_shared_edit(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    item: &Desired,
    sink: &mut PlanSink,
) -> bool {
    let Some(position) = compared_position(&item.artifact) else {
        return false;
    };
    let shared = lock
        .entries
        .values()
        .any(|entry| recorded_at(env, scope, entry, position));
    if !shared {
        return false;
    }
    sink.drift.push(DriftRow {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        scope: scope.clone(),
        state: DriftState::Conflict,
        detail: "its files were edited on disk after another tool installed them — keep the edits as a fork, or apply with edits discarded".into(),
        cause: Some(DriftCause::LocalEdit),
        compared: None,
        also_in_the_way: Vec::new(),
    });
    true
}

/// The `.disabled` counterpart of a path — the toggled name a disabled
/// installation keeps its bytes under.
fn disabled_sibling(path: &std::path::Path) -> std::path::PathBuf {
    let text = path.display().to_string();
    match text.strip_suffix(".disabled") {
        Some(base) => std::path::PathBuf::from(base),
        None => std::path::PathBuf::from(format!("{text}.disabled")),
    }
}

/// Whether any lock entry that writes to one of `here` currently renders
/// to `disk` — the "these bytes are a render we made at this spot" test,
/// keyed by physical path so a same-hash coincidence elsewhere never
/// counts.
fn wrote_here(env: &Env, scope: &Scope, lock: &Lock, here: &[PathBuf], disk: &str) -> bool {
    // A toggled item's desired path carries `.disabled` while its recorded
    // install path does not (or the reverse); compared with the suffix
    // stripped, an enabled render and its disabled twin are one location.
    let here_bases: Vec<PathBuf> = here.iter().map(|p| base_position(p)).collect();
    lock.entries.values().any(|entry| {
        let Some(rendered) = &entry.rendered_hash else {
            return false;
        };
        if rendered != disk {
            return false;
        }
        let owned = super::owned::installed(env, scope, entry);
        owned
            .files
            .iter()
            .any(|path| here_bases.contains(&base_position(path)))
    })
}

/// The user's hands were on this installation: hold it. An edited artifact
/// becomes a conflict naming the ways out — keep it as a fork, or discard
/// the edits — and no write op is planned for it. Returns true when the
/// item was held.
///
/// The classification is rendered-hash-first: what apply last wrote is the
/// anchor that tells an upstream move from a local edit. Disk matching the
/// desired bytes is never an edit, however it got there. An entry from
/// before the anchor existed falls back on the installation hash — inputs
/// unchanged means the desired render equals the install-time render, so a
/// differing disk is an edit — and when the inputs moved too, the honest
/// answer is that the two cannot be told apart, which is a conflict, never
/// an overwrite.
pub(super) fn hold_local_edit(
    env: &Env,
    item: &Desired,
    scope: &Scope,
    lock: &Lock,
    manifest: &crate::manifest::Manifest,
    sink: &mut PlanSink,
) -> bool {
    let (Some(disk), Some(compared)) = (
        observed_artifact_hash(&item.artifact),
        compared_position(&item.artifact),
    ) else {
        return false;
    };
    let wanted = item.artifact.disk_hash();
    if disk == wanted {
        return false;
    }
    if absorb_fork_edit(env, item, scope, lock, manifest, compared, &disk, sink) {
        return true;
    }
    // Bytes some apply provably wrote *at this location* are never an
    // edit: per-tool variants share and collapse trees, and a command
    // taking its name back reuses the tree a skill left there. Matched by
    // physical path, not just by hash — a different package that merely
    // happens to hash the same must still hold, or one package's edit
    // could ride out on another's upstream change.
    let here = item.artifact.paths();
    if wrote_here(env, scope, lock, &here, &disk) {
        return false;
    }
    let recorded = lock
        .entries
        .get(&item.key)
        .filter(|entry| recorded_at(env, scope, entry, compared));
    let Some(entry) = recorded else {
        return hold_shared_edit(env, scope, lock, item, sink);
    };
    let hash_moved = entry.source_hash != item.hash;
    let cause = match (&entry.rendered_hash, hash_moved) {
        (Some(_), true) => DriftCause::Both,
        (Some(_), false) => DriftCause::LocalEdit,
        (None, false) => DriftCause::LocalEdit,
        (None, true) => DriftCause::Both,
    };
    let detail = match (cause, &entry.rendered_hash) {
        (DriftCause::Both, None) => {
            "changed upstream and on disk — kendex cannot tell your edits from the update; keep it as a fork or apply with edits discarded"
        }
        (DriftCause::Both, _) => {
            "edited on disk and changed upstream — keep your edits as a fork, or apply with edits discarded"
        }
        _ => "edited on disk since install — keep it as a fork, or apply with edits discarded",
    };
    sink.drift.push(DriftRow {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        scope: scope.clone(),
        state: DriftState::Conflict,
        detail: detail.into(),
        cause: Some(cause),
        compared: None,
        also_in_the_way: Vec::new(),
    });
    sink.new_lock
        .entries
        .insert(item.key.clone(), entry.clone());
    true
}

/// A fork is already the person's own copy, so an edit to one is not a
/// divergence anybody has to settle — it is the fork's content. The pass
/// takes those bytes into the fork's local source, leaves the installation
/// exactly as the person left it, records it, and says so through
/// `fork_edits` rather than a conflict row. From the next pass on the fork
/// is an ordinary settled item: its source renders to what is on disk, so
/// every later pass plans nothing and `apply` and the Library's check
/// agree, with no decision left for either to report.
///
/// Writing the source is what makes that true rather than merely recorded,
/// and it is not optional. `rendered_hash` is the anchor the whole engine
/// reads as bytes an apply wrote — `wrote_here` here, `removal::edit_holds`
/// for a sweep — so recording an edit under it while the source still held
/// the bytes it replaced would tell every one of those guards the person's
/// edit was ours to overwrite, and the first re-render (another tool
/// ticked on, a rendering repaired) would take it. With the source
/// holding it, every one of them is right again.
///
/// Only while the fork's own source stands still. A local source edited
/// too is two changes to one item with nothing able to say which of them
/// the person meant to keep, and that is the conflict `hold_local_edit`
/// goes on to report — as is an edit the source cannot be made to hold.
#[allow(clippy::too_many_arguments)]
fn absorb_fork_edit(
    env: &Env,
    item: &Desired,
    scope: &Scope,
    lock: &Lock,
    manifest: &crate::manifest::Manifest,
    compared: &std::path::Path,
    disk: &str,
    sink: &mut PlanSink,
) -> bool {
    if !item.recorded_fork {
        return false;
    }
    // The same record `hold_local_edit` requires: an entry whose own word
    // covers the position these bytes were read at. Without one the bytes
    // are not this installation's to take.
    let Some(entry) = lock
        .entries
        .get(&item.key)
        .filter(|entry| recorded_at(env, scope, entry, compared))
    else {
        return false;
    };
    if entry.source_hash != item.hash {
        return false;
    }
    // One capture per package, and every rendering this absorb speaks for
    // has to be the one it captured. Tools that share a skill's canonical
    // tree reach this once per tool over the same bytes, and a second
    // write of the one local slot would run its precondition against a
    // slot the first already emptied. A rendering standing somewhere else
    // holds bytes the source did not take, and recording those under
    // `rendered_hash` would be the very claim this absorb exists to make
    // true — so it is left to the edit hold, which keeps it and says so.
    let package = (item.kind, item.name.clone());
    let position = base_position(compared);
    match sink.absorbed.get(&package) {
        Some(captured) => {
            if captured != &position {
                return false;
            }
        }
        None => {
            let Ok(ops) = super::fork::absorb_ops(
                env,
                scope,
                manifest,
                item.kind,
                &item.name,
                item.harness,
                compared,
            ) else {
                return false;
            };
            sink.ops.extend(ops);
            sink.absorbed.insert(package, position);
        }
    }
    sink.fork_edits.push(ForkEdit {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
    });
    sink.new_lock.entries.insert(
        item.key.clone(),
        LockEntry {
            rendered_hash: Some(disk.to_owned()),
            ..entry.clone()
        },
    );
    true
}
