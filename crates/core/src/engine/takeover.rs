//! What a take-over has to settle before the plan that carries it out is
//! allowed to run.

use crate::model::ItemKind;

use super::{DriftRow, PlanOptions};

/// A take-over named per item answers for that item whole, read off the
/// same plan that would carry it out — never a second look at the disk,
/// which can disagree with the plan it is guarding.
///
/// The name has to reach something still in the way, and nothing of that
/// item may be left in the way afterwards: half an item taken over leaves
/// the rest blocked with the item no longer theirs.
///
/// Only the named form refuses here. The scope-wide sweep holds an
/// unsettleable item back and replaces the rest (`hold_back_sweep`) —
/// a refusal there would leave a scope with one odd item no way to take
/// over any of the others.
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

/// An item the scope-wide sweep cannot settle whole has its take-over held
/// back, never a reason to abort the scope: a repo with one odd item still
/// needs the way out the flag is. The plan is rebuilt naming only the items
/// that settle, so nothing staged for a held item survives as half a
/// take-over — and a sweep that settles nothing at all refuses, naming what
/// it held, rather than reporting a success it did not have. Items a caller
/// named individually are not exempted from the split: the named check
/// above has already refused any of them a dead stop reaches.
pub(crate) fn hold_back_sweep(
    options: &PlanOptions,
    report: super::EngineReport,
    replan: impl FnOnce(&PlanOptions) -> crate::error::Result<super::EngineReport>,
) -> crate::error::Result<super::EngineReport> {
    if !options.replace_unmanaged {
        return Ok(report);
    }
    let (settled, held) = split_sweep(&report.drift);
    if held.is_empty() {
        return Ok(report);
    }
    if settled.is_empty() {
        return Err(crate::error::CoreError::TakeOverAllHeld {
            held: held
                .iter()
                .map(|(item, why)| format!("{item} — {why}"))
                .collect(),
        });
    }
    // Only the take-over is held: the item is otherwise planned exactly as
    // a run without the flag plans it, so one of its places with nothing
    // in the way still gets its install.
    let sweep = PlanOptions {
        replace_unmanaged: false,
        replace_unmanaged_names: Some(settled),
        ..options.clone()
    };
    let mut report = replan(&sweep)?;
    for (item, why) in &held {
        report.notes.push(format!(
            "{item} was not replaced, so the files in its way stay where they are — {why}"
        ));
    }
    Ok(report)
}

/// The sweep's division of the items it swept up: the ones every row lets
/// it settle whole, and the ones a dead-stop row beside the files blocks —
/// each held one carried with the place holding it, since under the flag
/// that row is the only place the dead stop shows: without the flag the
/// files in the way are refused before the place beside them is looked at.
type Swept = Vec<(ItemKind, String)>;
fn split_sweep(drift: &[DriftRow]) -> (Swept, Vec<(String, String)>) {
    let mut settled: Swept = Vec::new();
    let mut held: Vec<(String, String)> = Vec::new();
    for row in drift
        .iter()
        .filter(|row| row.detail == super::file_plan::TAKEN_OVER)
    {
        let stop = drift
            .iter()
            .find(|other| other.kind == row.kind && other.name == row.name && other.dead_stop());
        let Some(stop) = stop else {
            let item = (row.kind, row.name.clone());
            if !settled.contains(&item) {
                settled.push(item);
            }
            continue;
        };
        let item = format!("{} {}", row.kind.name(), row.name);
        if !held.iter().any(|(name, _)| *name == item) {
            held.push((
                item,
                format!(
                    "replacing cannot settle its conflict for {}: {}",
                    stop.harness.display_name(),
                    // A note is a finished sentence its readers print as
                    // it stands, so the path is escaped here rather than
                    // at each of them.
                    crate::names::shown(&stop.detail)
                ),
            ));
        }
    }
    (settled, held)
}
