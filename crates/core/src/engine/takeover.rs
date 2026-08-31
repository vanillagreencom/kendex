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
    for row in drift
        .iter()
        .filter(|row| row.detail == super::file_plan::TAKEN_OVER)
    {
        let Some(stop) = drift
            .iter()
            .find(|other| other.kind == row.kind && other.name == row.name && other.dead_stop())
        else {
            continue;
        };
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
