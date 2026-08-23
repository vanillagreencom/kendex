//! What a take-over named per item has to settle before the plan that
//! carries it out is allowed to run.

use crate::model::ItemKind;

use super::{DriftRow, PlanOptions};

/// A take-over named per item answers for that item whole, read off the
/// same plan that would carry it out — never a second look at the disk,
/// which can disagree with the plan it is guarding.
///
/// The name has to reach something still in the way, and nothing of that
/// item may be left in the way afterwards: half an item taken over leaves
/// the rest blocked with the item no longer theirs.
pub(crate) fn refuse_unsettled_takeover(
    options: &PlanOptions,
    drift: &[DriftRow],
) -> crate::error::Result<()> {
    // The scope-wide flag answers for every item it reaches, so it owes
    // each of them the same whole-item rule the per-item form does.
    let scope_wide: Vec<(ItemKind, String)> = match options.replace_unmanaged {
        true => drift
            .iter()
            .filter(|row| row.detail == super::file_plan::TAKEN_OVER)
            .map(|row| (row.kind, row.name.clone()))
            .collect(),
        false => Vec::new(),
    };
    let named = options
        .replace_unmanaged_names
        .as_deref()
        .unwrap_or_default();
    for (kind, name) in named.iter().chain(scope_wide.iter()) {
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
        // A name the reader typed has to reach something; an item the
        // scope-wide flag swept up was found by its take-over already.
        if options.replace_unmanaged_names.is_some()
            && !rows
                .iter()
                .any(|row| row.detail == super::file_plan::TAKEN_OVER)
        {
            return Err(crate::error::CoreError::TakeOverMatchesNothing { name: name.clone() });
        }
    }
    Ok(())
}
