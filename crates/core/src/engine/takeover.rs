//! What a take-over named per item has to settle before the plan that
//! carries it out is allowed to run.

use super::{DriftCause, DriftRow, PlanOptions};

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
    let Some(names) = &options.replace_unmanaged_names else {
        return Ok(());
    };
    for (kind, name) in names {
        let rows: Vec<&DriftRow> = drift
            .iter()
            .filter(|row| row.kind == *kind && &row.name == name)
            .collect();
        if rows
            .iter()
            .any(|row| row.cause.is_some_and(DriftCause::in_the_way))
        {
            return Err(crate::error::CoreError::TakeOverLeavesSome { name: name.clone() });
        }
        if !rows
            .iter()
            .any(|row| row.detail == super::file_plan::TAKEN_OVER)
        {
            return Err(crate::error::CoreError::TakeOverMatchesNothing { name: name.clone() });
        }
    }
    Ok(())
}
