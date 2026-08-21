use std::collections::BTreeSet;
use std::path::PathBuf;

use super::{DriftCause, DriftRow, DriftState};
use crate::apply::PlannedOp;
use crate::clock::timestamp;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockEntry};
use crate::model::Scope;

use super::config_edits::ConfigEditPlan;
use super::desired::{Artifact, Desired};
use super::file_plan::{plan_file, plan_written_file};
use super::tree_plan::{Written, plan_tree};

/// Everything one pass over the desired items accumulates.
pub(super) struct PlanSink<'a> {
    pub(super) drift: &'a mut Vec<DriftRow>,
    pub(super) ops: &'a mut Vec<PlannedOp>,
    pub(super) config_edits: &'a mut ConfigEditPlan,
    pub(super) new_lock: &'a mut Lock,
    pub(super) written: &'a mut Written,
}

/// `owned` holds every position this scope's installs recorded writing —
/// a codex command that landed as a skill tree, and the tree several
/// harnesses share. A path in it is ours to replace whichever entry holds
/// it now, and never a stranger's to refuse or to take over.
pub(super) fn plan_item(
    env: &Env,
    item: &Desired,
    scope: &Scope,
    lock: &Lock,
    owned: &BTreeSet<PathBuf>,
    replace_unmanaged: bool,
    sink: &mut PlanSink,
) -> Result<()> {
    let PlanSink {
        drift,
        ops,
        config_edits,
        new_lock,
        written,
    } = sink;
    let row = |state: DriftState, detail: String| DriftRow {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        scope: scope.clone(),
        state,
        detail,
        cause: None,
    };
    let existing = lock.entries.get(&item.key);

    // Invariant 4: a recorded source is never silently rebound. The one
    // sanctioned rebind is a recorded fork — remote to local, written into
    // the manifest by the fork operation the user confirmed.
    if let Some(entry) = existing
        && entry.source_repo != item.provenance
        && entry.source_repo != "local"
        && !(item.provenance == crate::manifest::LOCAL_SOURCE_NAME && item.recorded_fork)
    {
        drift.push(row(
            DriftState::Conflict,
            format!(
                "installed from {} but now set to come from {} — remove it first",
                entry.source_repo, item.provenance
            ),
        ));
        new_lock.entries.insert(item.key.clone(), entry.clone());
        return Ok(());
    }

    let claim = Claim {
        locked: existing.is_some(),
        replace_unmanaged,
    };
    // A refusal plans nothing at all. The artifact planners write ops as
    // they go and only learn of a refusal further in — a tree whose harness
    // link turns out to be a stranger's, say — so what they staged for this
    // item comes back off before the conflict row goes out. Leaving it
    // would apply half an item nothing recorded.
    let staged = ops.len();
    written.start_item();
    let planned = match &item.artifact {
        Artifact::File { .. } => plan_file(env, scope, item, claim, owned, ops),
        Artifact::Tree { .. } => plan_tree(env, scope, item, claim, owned, written, ops),
        Artifact::Registration { .. } => {
            plan_registration(env, scope, item, claim, owned, ops, config_edits)
        }
    }?;
    let dirty = !matches!(planned, Planned::Clean);
    match planned {
        Planned::Conflict(_) | Planned::Unmanaged(..) => {
            let (cause, detail) = match planned {
                Planned::Unmanaged(cause, detail) => (Some(cause), detail),
                Planned::Conflict(detail) => (None, detail),
                _ => unreachable!("only the two refusals reach here"),
            };
            ops.truncate(staged);
            written.undo_item();
            let mut conflict = row(DriftState::Conflict, detail);
            conflict.cause = cause;
            drift.push(conflict);
            if let Some(entry) = existing {
                new_lock.entries.insert(item.key.clone(), entry.clone());
            }
            return Ok(());
        }
        Planned::Drift(state, detail) => drift.push(row(state, detail)),
        Planned::Clean => {}
    }

    let hash_moved = existing.is_some_and(|entry| entry.source_hash != item.hash);
    if hash_moved && !dirty {
        drift.push(row(
            DriftState::Stale,
            "source or customization changed since install".into(),
        ));
    }
    let installed_at = match existing {
        Some(entry) if !dirty && !hash_moved => entry.installed_at.clone(),
        _ => timestamp(),
    };
    new_lock.entries.insert(
        item.key.clone(),
        LockEntry {
            name: item.name.clone(),
            kind: item.kind,
            harness: item.harness,
            source: item.source_name.clone(),
            source_repo: item.provenance.clone(),
            method: item.method,
            installed_at,
            source_hash: item.hash.clone(),
            source_commit: item.source_commit.clone(),
            rendered_hash: rendered_hash(&item.artifact),
            enabled: item.enabled,
            upstream_skills: item.upstream_skills.clone(),
            emitted: item.emitted.clone(),
            registration: super::desired_custom_hooks::hook_registration(item),
            reasons: item.reasons.clone(),
        },
    );
    Ok(())
}

/// What this artifact leaves on disk, for edit detection later. Only file
/// and tree artifacts have a meaningful disk identity; a registration's
/// shared config file holds other people's keys, so hashing it would read
/// every unrelated settings change as an edit of ours.
fn rendered_hash(artifact: &Artifact) -> Option<String> {
    match artifact {
        Artifact::File { .. } | Artifact::Tree { .. } => {
            Some(super::desired::artifact_disk_hash(artifact))
        }
        // A hook's backing script is a file kendex alone writes, so it can
        // be anchored like any other. A registration with no script edits
        // only shared config, which holds other people's keys — nothing to
        // anchor there.
        Artifact::Registration {
            script: Some(_), ..
        } => Some(super::desired::artifact_disk_hash(artifact)),
        Artifact::Registration { script: None, .. } => None,
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Planned {
    Clean,
    Drift(DriftState, String),
    Conflict(String),
    /// Files kendex never wrote sit where this item installs. A conflict
    /// like any other, carrying the cause that says which ways out this
    /// position has.
    Unmanaged(DriftCause, String),
}

/// What a plan may do with the position an item installs at. `locked` says
/// this installation is on the books — which is what tells a registration
/// apart from a first one, and nothing about who wrote any file;
/// `replace_unmanaged` is the user's word that a declaration outranks
/// whatever else is there.
#[derive(Debug, Clone, Copy)]
pub(super) struct Claim {
    pub(super) locked: bool,
    pub(super) replace_unmanaged: bool,
}

impl Claim {
    /// Whether the bytes at this position are kendex's own: some install
    /// recorded writing exactly here. Read from the paths the lock's
    /// entries actually emitted, never from the entry merely existing — an
    /// installation that changed method writes somewhere new, and calling
    /// that new position ours because the old one was recorded hands a
    /// stranger's files to the writer.
    pub(super) fn owns(&self, path: &std::path::Path, owned: &BTreeSet<PathBuf>) -> bool {
        owned.contains(path)
    }
}

/// The refusal: where the files in the way are, and nothing else. The
/// cause carries what that means, and each surface says it in its own
/// words — the app puts the path in a row with two buttons, the CLI writes
/// a sentence. Said here as well, it would be the same sentence three
/// times in one screen of output, and the app would have a sentence where
/// it needs a path.
///
/// A `DriftState::Unmanaged` row's detail is a bare path for the same
/// reason; these two are read by the same surfaces.
///
/// The path is shown, not printed: these bytes were written by something
/// that is not kendex, and a folder name carrying an escape sequence must
/// reach a terminal as its own characters.
pub(super) fn unmanaged(cause: DriftCause, path: &std::path::Path) -> Planned {
    Planned::Unmanaged(cause, crate::names::shown(&path.display().to_string()))
}

/// A registration is in sync when its backing file matches and re-applying
/// every config edit changes nothing. That idempotency is the whole drift
/// check — unrelated keys in those shared files are never read as ours.
/// Edits that would change the file go to the per-file collector, not
/// straight to ops.
#[allow(clippy::too_many_arguments)]
fn plan_registration(
    env: &Env,
    scope: &Scope,
    item: &Desired,
    claim: Claim,
    owned: &BTreeSet<PathBuf>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut ConfigEditPlan,
) -> Result<Planned> {
    let Artifact::Registration { script, edits } = &item.artifact else {
        return Ok(Planned::Clean);
    };
    // Every edit is checked before anything is planned: a settings file
    // kendex cannot read back — comments in a JSON, a torn edit — blocks
    // this one registration whole, script included, not the whole scope.
    let mut pending = Vec::new();
    for (path, edit) in edits {
        let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
        match edit.apply(&current) {
            Ok(updated) if updated == current => {}
            Ok(_) => pending.push((path, edit)),
            Err(message) => {
                return Ok(Planned::Conflict(format!(
                    "{} could not be edited: {message}",
                    path.display()
                )));
            }
        }
    }
    let mut planned = match script {
        Some((path, bytes)) => plan_written_file(env, scope, item, path, bytes, claim, owned, ops)?,
        None => Planned::Clean,
    };
    if matches!(planned, Planned::Conflict(_) | Planned::Unmanaged(..)) {
        return Ok(planned);
    }
    for (path, edit) in pending {
        config_edits.push(
            path.clone(),
            format!("register {}", item.name),
            edit.clone(),
        );
        if matches!(planned, Planned::Clean) {
            planned = match claim.locked {
                true => Planned::Drift(
                    DriftState::Stale,
                    "its settings entry is out of sync".into(),
                ),
                false => Planned::Drift(DriftState::Missing, "not registered yet".into()),
            };
        }
    }
    Ok(planned)
}
