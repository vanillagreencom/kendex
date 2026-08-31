use std::collections::BTreeSet;
use std::path::PathBuf;

use super::compared::Comparison;
use super::{DriftCause, DriftRow, DriftState};
use crate::apply::PlannedOp;
use crate::clock::timestamp;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockEntry};
use crate::model::Scope;

use super::config_edits::ConfigEditPlan;
use super::desired::{Artifact, Desired};
use super::file_plan;
use super::file_plan::{plan_file, plan_written_file};
use super::item_record::{registration, rendered_hash};
use super::tree_plan::plan_tree;
use super::written::Written;
use crate::configedit::ConfigEdit;

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
        compared: None,
        also_in_the_way: Vec::new(),
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

    // A refusal plans nothing at all. The artifact planners write ops as
    // they go and only learn of a refusal further in — a tree whose harness
    // link turns out to be a stranger's, say — so what they staged for this
    // item comes back off before the conflict row goes out. Leaving it
    // would apply half an item nothing recorded.
    let staged = ops.len();
    written.start_item();
    let planned = match &item.artifact {
        Artifact::File { .. } => plan_file(env, scope, item, replace_unmanaged, owned, ops),
        Artifact::Tree { .. } => {
            plan_tree(env, scope, item, replace_unmanaged, owned, written, ops)
        }
        Artifact::Registration { .. } => plan_registration(
            env,
            scope,
            item,
            existing,
            replace_unmanaged,
            owned,
            ops,
            config_edits,
        ),
    }?;
    let dirty = !matches!(planned, Planned::Clean);
    // The two refusals differ only in whether the cause is known.
    let refused = match planned {
        Planned::Unmanaged {
            cause,
            detail,
            compared,
            also,
        } => Some((Some(cause), detail, compared, also)),
        Planned::Conflict(detail) => Some((None, detail, None, Vec::new())),
        Planned::Drift(state, detail) => {
            drift.push(row(state, detail));
            None
        }
        Planned::Clean => None,
    };
    if let Some((cause, detail, compared, also)) = refused {
        // Under the scope-wide flag an item that staged a take-over was
        // swept up, and this refusal is about to drop it. The rows it
        // leaves carry no trace of that, so the sweep's all-or-none check
        // would find its dead stop with nothing to pair against and let the
        // run replace the other items without it — the hold-back this
        // engine no longer does. The evidence is still in the ops here, so
        // the row that records it goes out beside the conflict.
        if replace_unmanaged && ops[staged..].iter().any(file_plan::is_set_aside) {
            drift.push(row(DriftState::Missing, file_plan::TAKEN_OVER.into()));
        }
        ops.truncate(staged);
        written.undo_item();
        let mut conflict = row(DriftState::Conflict, detail);
        conflict.cause = cause;
        conflict.compared = compared;
        conflict.also_in_the_way = also;
        drift.push(conflict);
        if let Some(entry) = existing {
            new_lock.entries.insert(item.key.clone(), entry.clone());
        }
        return Ok(());
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
    new_lock
        .entries
        .insert(item.key.clone(), record(item, installed_at));
    Ok(())
}

/// What this pass records about the installation it just planned.
fn record(item: &Desired, installed_at: String) -> LockEntry {
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
        registration: registration(item),
        reasons: item.reasons.clone(),
    }
}

/// What this artifact leaves on disk, for edit detection later. Only file
/// and tree artifacts have a meaningful disk identity; a registration's
/// shared config file holds other people's keys, so hashing it would read
/// every unrelated settings change as an edit of ours.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Planned {
    Clean,
    Drift(DriftState, String),
    Conflict(String),
    /// Files kendex never wrote sit where this item installs. A conflict
    /// like any other, carrying the cause that says which ways out this
    /// position has and how those files compare with the install they
    /// block.
    Unmanaged {
        cause: DriftCause,
        /// Where the files in the way are — this row's identity.
        detail: String,
        compared: Option<Comparison>,
        /// The other positions a take-over of this refusal also empties.
        also: Vec<String>,
    },
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
/// The path is stored as it is, never as its rendering. A detail like this
/// is an identity — two rows are the same place when their paths match —
/// and escaping first would let two different places compare, and print,
/// as one. Escaping is each surface's own last step (`names::shown`);
/// these bytes were written by something that is not kendex, so a folder
/// name carrying an escape sequence must reach a terminal as its own
/// characters and never as the sequence.
pub(super) fn unmanaged(cause: DriftCause, path: &std::path::Path) -> Planned {
    Planned::Unmanaged {
        cause,
        detail: crate::paths::slashed(path),
        compared: None,
        also: Vec::new(),
    }
}

/// The same refusal, carrying what the plan measured the files in the way
/// against: the bytes it was about to write. Only the passes that hold both
/// sides can answer, and where a position cannot be read as content at all
/// — a link kendex will not follow — there is nothing to compare. The path
/// is stored as it is, for the reason `unmanaged` gives.
pub(super) fn unmanaged_compared(
    cause: DriftCause,
    path: &std::path::Path,
    compared: Option<Comparison>,
) -> Planned {
    Planned::Unmanaged {
        cause,
        detail: crate::paths::slashed(path),
        compared,
        also: Vec::new(),
    }
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
    existing: Option<&LockEntry>,
    replace_unmanaged: bool,
    owned: &BTreeSet<PathBuf>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut ConfigEditPlan,
) -> Result<Planned> {
    let Artifact::Registration { script, edits } = &item.artifact else {
        return Ok(Planned::Clean);
    };
    let locked = existing.is_some();
    // What the record says this installation registered, where that is no
    // longer what it registers: a changed event or matcher is a move, and
    // a move takes the old entry out before it puts the new one in. Added
    // in front of this item's own edits, since the file is edited in the
    // order they are collected — the other way round, an upsert under the
    // new event would leave the old one live and the hook would fire
    // twice.
    let retire = match super::item_record::retire_previous(item, existing) {
        super::item_record::Previous::Settled => None,
        super::item_record::Previous::Retire(path, edit) => Some((path, edit)),
        // Only a pi hook answers this way — elsewhere an unsettled
        // document settles. Nothing is written beside entries this pass
        // cannot tell its own from: this one registration holds, and says
        // which document to look at.
        super::item_record::Previous::Ambiguous(why) => return Ok(Planned::Conflict(why)),
    };
    let edits: Vec<(PathBuf, ConfigEdit)> =
        retire.into_iter().chain(edits.iter().cloned()).collect();
    let edits = &edits;
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
        Some((path, bytes)) => {
            plan_written_file(env, scope, item, path, bytes, replace_unmanaged, owned, ops)?
        }
        None => Planned::Clean,
    };
    if matches!(planned, Planned::Conflict(_) | Planned::Unmanaged { .. }) {
        return Ok(planned);
    }
    for (path, edit) in pending {
        config_edits.push(
            path.clone(),
            format!("register {}", item.name),
            edit.clone(),
        );
        if matches!(planned, Planned::Clean) {
            planned = match locked {
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
