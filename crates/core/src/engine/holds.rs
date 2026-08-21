//! The holds that outrank planning: situations where the right plan for
//! an item is to write nothing at all and say why — a revision wanted two
//! ways at once, or bytes the user's hands were on.

use std::collections::BTreeSet;

use std::path::PathBuf;

use super::desired::{Artifact, Desired};
use super::item_plan::PlanSink;
use super::{DriftCause, DriftRow, DriftState};
use crate::env::Env;
use crate::lock::Lock;
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
    });
    if let Some(entry) = lock.entries.get(&item.key) {
        sink.new_lock
            .entries
            .insert(item.key.clone(), entry.clone());
    }
    true
}

/// A pi hook whose installation under the directory pi reserved is not
/// provably kendex's holds whole. Writing the fresh rendering and
/// registering it would leave the person's bytes sitting on disk while
/// what runs them moved to a copy they never saw — the opposite of what
/// holding a file back is for. Returns true when the item was held back
/// this way.
///
/// The row says which hold this is, because the remedies are not
/// interchangeable: discarding edits replaces bytes and does nothing at
/// all for a link, a file that cannot be read, or a registration somebody
/// moved. Offering it for those would send the person round a loop that
/// changes nothing and explains nothing.
pub(super) fn hold_legacy_copy(
    item: &Desired,
    scope: &Scope,
    lock: &Lock,
    held: &super::pi_hooks_move::Preflight,
    sink: &mut PlanSink,
) -> bool {
    if item.kind != crate::model::ItemKind::Hook || item.harness != crate::model::HarnessId::Pi {
        return false;
    }
    let Some(hold) = held.hold(&item.name) else {
        return false;
    };
    let (detail, cause) = hold.row(
        "its copy under the directory pi reserved is not the one kendex wrote — that copy is what runs; keep it as a fork, or apply with edits discarded",
    );
    sink.drift.push(DriftRow {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        scope: scope.clone(),
        state: DriftState::Conflict,
        detail,
        cause,
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
    let path = match artifact {
        Artifact::File { path, .. } => path,
        Artifact::Tree { canonical, .. } => canonical,
        // Only the backing script is ours to compare; the shared config a
        // registration also edits holds other people's keys.
        Artifact::Registration {
            script: Some((path, _)),
            ..
        } => return here(path),
        Artifact::Registration { script: None, .. } => return None,
    };
    here(path).or_else(|| here(&disabled_sibling(path)))
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
    let base = |p: &std::path::Path| {
        let text = p.display().to_string();
        text.strip_suffix(".disabled")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| p.to_path_buf())
    };
    let here_bases: Vec<PathBuf> = here.iter().map(|p| base(p)).collect();
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
            .any(|path| here_bases.contains(&base(path)))
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
    sink: &mut PlanSink,
) -> bool {
    let Some(entry) = lock.entries.get(&item.key) else {
        return false;
    };
    let Some(disk) = observed_artifact_hash(&item.artifact) else {
        return false;
    };
    let wanted = super::desired::artifact_disk_hash(&item.artifact);
    if disk == wanted {
        return false;
    }
    // Bytes some apply provably wrote *at this location* are never an
    // edit: per-tool variants share and collapse trees, and a command
    // taking its name back reuses the tree a skill left there. Matched by
    // physical path, not just by hash — a different package that merely
    // happens to hash the same must still hold, or one package's edit
    // could ride out on another's upstream change.
    let here = super::desired::artifact_paths(&item.artifact);
    if wrote_here(env, scope, lock, &here, &disk) {
        return false;
    }
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
    });
    sink.new_lock
        .entries
        .insert(item.key.clone(), entry.clone());
    true
}
