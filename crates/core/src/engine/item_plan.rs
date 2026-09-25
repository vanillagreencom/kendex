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

/// The records a pass kept in the new lock as they were, in place of
/// writing them: a conflict or a hold in the item pass, a refusal's edit
/// hold, a withheld copy kept. The one account of that fact, which the
/// orphan pass reads to keep what such a record requires; a record written
/// this pass, in sync with its old one or not, is never in it.
#[derive(Default)]
pub(super) struct KeptAsIs(std::collections::BTreeSet<String>);

impl KeptAsIs {
    /// Keep `entry` under `key` in the new lock as it was, and say so.
    pub(super) fn keep(&mut self, new_lock: &mut Lock, key: &str, entry: &LockEntry) {
        new_lock.entries.insert(key.to_owned(), entry.clone());
        self.0.insert(key.to_owned());
    }

    pub(super) fn contains(&self, key: &str) -> bool {
        self.0.contains(key)
    }
}

/// Everything one pass over the desired items accumulates.
pub(super) struct PlanSink<'a> {
    pub(super) drift: &'a mut Vec<DriftRow>,
    pub(super) fork_edits: &'a mut Vec<super::ForkEdit>,
    /// For each package whose fork edit this pass took into the local
    /// source, the one position those bytes were read at. Several
    /// renderings of one package capture once, and a rendering holding
    /// other bytes than the captured ones is not covered by that capture.
    pub(super) absorbed:
        &'a mut std::collections::BTreeMap<(crate::model::ItemKind, String), PathBuf>,
    pub(super) ops: &'a mut Vec<PlannedOp>,
    pub(super) config_edits: &'a mut ConfigEditPlan,
    pub(super) new_lock: &'a mut Lock,
    pub(super) kept: &'a mut KeptAsIs,
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
    ownership: &super::PlanOwnership,
    replace_unmanaged: bool,
    sink: &mut PlanSink,
) -> Result<()> {
    let PlanSink {
        drift,
        ops,
        config_edits,
        new_lock,
        kept,
        written,
        ..
    } = sink;
    let row = row_for(item, scope);
    let existing = lock.entries.get(&item.key);

    if let Some(entry) = existing
        && let Some(detail) = rebound(entry, &item.provenance, item.recorded_fork)
    {
        drift.push(row(DriftState::Conflict, detail));
        kept.keep(new_lock, &item.key, entry);
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
        Artifact::File { .. } => {
            plan_file(env, scope, item, replace_unmanaged, &ownership.paths, ops)
        }
        Artifact::Tree { .. } => plan_tree(
            env,
            scope,
            item,
            replace_unmanaged,
            &ownership.paths,
            written,
            ops,
        ),
        Artifact::Registration { .. } => plan_registration(
            env,
            scope,
            item,
            existing,
            ownership.recovered_registrations.get(&item.key),
            replace_unmanaged,
            &ownership.paths,
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
        Planned::Uncompared(detail) => Some((Some(DriftCause::Uncompared), detail, None, vec![])),
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
        // engine does not do. The evidence is still in the ops here, so
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
            kept.keep(new_lock, &item.key, entry);
        }
        return Ok(());
    }

    let hash_moved = existing.is_some_and(|entry| entry.source_hash != item.hash);
    // Inputs that moved while the rendering did not are worth a row only
    // where somebody else moved them. A fork's inputs are the person's own
    // local source, and the pass that absorbs an edit into it leaves
    // exactly this state — a source they just changed, rendering to bytes
    // already on disk. Saying it would be the same never-clearing report
    // the absorb exists to end: this pass records the new hash, and the
    // one after has nothing to say either way.
    if hash_moved && !dirty && !item.recorded_fork {
        drift.push(row(
            DriftState::Stale,
            "source or customization changed since install".into(),
        ));
    }
    // Kept where this machine made the install and nothing moved since;
    // a clone holds no record of when its install was made, and its first
    // apply here is when.
    let installed_at = existing
        .filter(|_| !dirty && !hash_moved)
        .and_then(|entry| entry.machine.as_ref())
        .map_or_else(timestamp, |machine| machine.installed_at.clone());
    new_lock
        .entries
        .insert(item.key.clone(), record(item, installed_at));
    Ok(())
}

/// Invariant 4: a recorded source is never silently rebound. The one
/// sanctioned rebind is a recorded fork — remote to local, written into
/// the manifest by the fork operation the user confirmed. The conflict
/// row's detail where the record is not the declaration's, and `None`
/// where the declaration may write over the record. The item pass and the
/// withheld pass (`plan_pass::plan_withheld`) share this one judgement.
pub(super) fn rebound(entry: &LockEntry, provenance: &str, recorded_fork: bool) -> Option<String> {
    let sanctioned = entry.source_repo == provenance
        || entry.source_repo == crate::manifest::LOCAL_SOURCE_NAME
        || (provenance == crate::manifest::LOCAL_SOURCE_NAME && recorded_fork);
    if sanctioned {
        return None;
    }
    Some(format!(
        "installed from {} but now set to come from {provenance} — remove it first",
        entry.source_repo
    ))
}

/// What this pass records about the installation it just planned.
fn record(item: &Desired, installed_at: String) -> LockEntry {
    // The artifact's own hash every pass, never the record's copy of it:
    // an entry in sync renders to the bytes on disk, so the value written
    // last time is this one already, and a recorded value that is not it
    // is the record's to answer for in `attest::record`.
    let rendered_hash = rendered_hash(item);
    LockEntry {
        name: item.name.clone(),
        kind: item.kind,
        harness: item.harness,
        source: item.source_name.clone(),
        source_repo: item.provenance.clone(),
        machine: Some(crate::lock::MachineRecord {
            method: item.method,
            installed_at,
        }),
        source_hash: item.hash.clone(),
        source_commit: item.source_commit.clone(),
        rendered_hash,
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
    /// What sits at the item's position would not read, so nothing was
    /// compared (invariant 12). The detail names the position and the
    /// read's own error; the cause carries that no exit is on offer.
    Uncompared(String),
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

/// A drift row about this item, as the planners find its state.
fn row_for<'a>(
    item: &'a Desired,
    scope: &'a Scope,
) -> impl Fn(DriftState, String) -> DriftRow + 'a {
    move |state, detail| DriftRow {
        kind: item.kind,
        name: item.name.clone(),
        harness: item.harness,
        scope: scope.clone(),
        state,
        detail,
        cause: None,
        compared: None,
        also_in_the_way: Vec::new(),
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
    recovered_registration: Option<&crate::lock::HookRegistration>,
    replace_unmanaged: bool,
    owned: &std::collections::BTreeSet<PathBuf>,
    ops: &mut Vec<PlannedOp>,
    config_edits: &mut ConfigEditPlan,
) -> Result<Planned> {
    let Artifact::Registration { script, edits } = &item.artifact else {
        return Ok(Planned::Clean);
    };
    let locked = existing.is_some();
    // What the record says this installation registered, where that is no
    // longer what it registers: a changed event or matcher is a move, and
    // a move takes the old entry out before it puts the current one in,
    // read off the record and the file as they are now.
    let edits: Vec<(PathBuf, ConfigEdit)> = super::item_record::edit_sequence(
        edits,
        existing
            .and_then(|entry| entry.registration.as_ref())
            .or(recovered_registration),
        &|path| crate::fs::read_if_exists(path).ok().flatten(),
    );
    let edits = &edits;
    // Every edit is checked before anything is planned: a settings file
    // kendex cannot read back — comments in a JSON, a torn edit — blocks
    // this one registration whole, script included, not the whole scope.
    let mut pending = Vec::new();
    for (path, edit) in edits {
        let current = crate::fs::read_if_exists(path)?.unwrap_or_default();
        match edit.in_sync(&current) {
            Ok(true) => {}
            Ok(false) => pending.push((path, edit)),
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
    if matches!(
        planned,
        Planned::Conflict(_) | Planned::Uncompared(_) | Planned::Unmanaged { .. }
    ) {
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
