//! What a take-over has to settle before the plan that carries it out is
//! allowed to run.

use super::{DriftRow, PlanOptions};

/// A take-over named per item answers for that item whole, read off the
/// same plan that would carry it out — never a second look at the disk,
/// which can disagree with the plan it is guarding.
///
/// The name has to reach something still in the way, and nothing of that
/// item may be left in the way afterwards: half an item taken over leaves
/// the rest blocked with the item no longer theirs.
///
/// Both forms refuse: the scope-wide sweep answers for every item it
/// swept up, in [`refuse_unsettleable_sweep`].
pub(crate) fn refuse_unsettled_takeover(
    options: &PlanOptions,
    drift: &[DriftRow],
) -> crate::error::Result<()> {
    let named = options
        .replace_unmanaged_names
        .as_deref()
        .unwrap_or_default();
    for (kind, name) in named {
        let rows: Vec<&DriftRow> = drift
            .iter()
            .filter(|row| row.kind == *kind && &row.name == name)
            .collect();
        // Any conflict the exits cannot settle, not only the ones with
        // files in the way: a foreign link adoption refuses is just as
        // blocking, and taking over the copy beside it settles half the
        // item. An edit is not one of these — it is a decision of its own.
        if rows.iter().any(|row| row.dead_stop()) {
            return Err(crate::error::CoreError::TakeOverLeavesSome { name: name.clone() });
        }
        // A name the reader typed has to reach something.
        if !rows
            .iter()
            .any(|row| row.detail == super::file_plan::TAKEN_OVER)
        {
            return Err(crate::error::CoreError::TakeOverMatchesNothing { name: name.clone() });
        }
    }
    Ok(())
}

/// The scope-wide sweep settles every item it sweeps up, or none of them.
/// An item a dead-stop row blocks cannot be settled whole — half a
/// take-over leaves the rest in the way with the item no longer theirs —
/// so the run refuses, naming each blocked item with the place that
/// blocks it. Under the flag that row is the only place the dead stop
/// shows: without it the files in the way are refused before the place
/// beside them is looked at.
pub(crate) fn refuse_unsettleable_sweep(
    options: &PlanOptions,
    drift: &[DriftRow],
) -> crate::error::Result<()> {
    if !options.replace_unmanaged {
        return Ok(());
    }
    let mut blocked: Vec<String> = Vec::new();
    // In a plan the flag already shaped, the row says both halves itself: a
    // place it took reads as taken over, and a place still standing as a
    // dead stop is one it could not take.
    for (row, stop) in blocked_sweep(
        drift,
        |row| row.detail == super::file_plan::TAKEN_OVER,
        DriftRow::dead_stop,
    ) {
        let said = format!(
            "{} {} — replacing cannot settle its conflict for {}: {}",
            row.kind.name(),
            row.name,
            stop.harness.display_name(),
            // The message is a finished sentence its readers print as it
            // stands, so the path is escaped here rather than at each of
            // them.
            crate::names::shown(&stop.detail)
        );
        if !blocked.contains(&said) {
            blocked.push(said);
        }
    }
    match blocked.is_empty() {
        true => Ok(()),
        false => Err(crate::error::CoreError::TakeOverSweepBlocked { blocked }),
    }
}

/// Whether the scope-wide sweep would refuse on this scope, asked of a
/// plan the flag has NOT shaped — what a surface offering the flag has to
/// know before it names a command the run would refuse.
///
/// The same rule as [`refuse_unsettleable_sweep`], reading "taken" from
/// the only thing an unflagged plan says about it: a place the take-over
/// can replace is a place it would take. Both readings are declared here,
/// beside each other and over one walk, because a surface deriving this
/// separately is a second judgement that drifts silently — and the
/// direction it drifts in is a command offered to somebody that cannot
/// succeed.
///
/// Bounded by what the unflagged pass reports. A conflict it stops at
/// before looking past — a stranger's tree in the canonical position,
/// with the harness link beside it never inspected — is a place this
/// cannot see and cannot answer for.
pub fn sweep_would_refuse(drift: &[DriftRow]) -> bool {
    let replaceable = |row: &DriftRow| {
        row.cause
            .is_some_and(crate::engine::DriftCause::can_replace)
    };
    // Both halves read off the cause, because before the flag runs every
    // place of the item is still a conflict: one the take-over can replace
    // is a place it would take, and one it cannot is what blocks it. A
    // place it can replace never blocks — the flag takes that one too.
    !blocked_sweep(drift, replaceable, |row| {
        row.dead_stop() && !replaceable(row)
    })
    .is_empty()
}

/// Each row a sweep takes, paired with a row BESIDE it, of the same item,
/// that the sweep cannot settle. `taken` says which rows a reading counts
/// as swept up and `blocking` which it counts as stopping them; the two
/// differ by whether the plan has already been shaped by the flag.
///
/// Beside it, never itself: before the flag runs, a place the take-over
/// would replace is a conflict in its own right, so a row read as taken
/// would otherwise answer for its own blocking. What blocks a take-over is
/// always some other place of the same item.
fn blocked_sweep(
    drift: &[DriftRow],
    taken: impl Fn(&DriftRow) -> bool,
    blocking: impl Fn(&DriftRow) -> bool,
) -> Vec<(&DriftRow, &DriftRow)> {
    drift
        .iter()
        .filter(|row| taken(row))
        .filter_map(|row| {
            let stop = drift.iter().find(|other| {
                !std::ptr::eq(*other, row)
                    && other.kind == row.kind
                    && other.name == row.name
                    && blocking(other)
            });
            stop.map(|stop| (row, stop))
        })
        .collect()
}
