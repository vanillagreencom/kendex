//! Which ways out a blocked row actually has.
//!
//! One answer for every surface. The rules live on `DriftCause`, and a
//! surface that re-derives them from the cause drifts from them: adding a
//! cause then makes one surface offer an action the plan rejects, or hide
//! one another surface offers.

use serde::{Deserialize, Serialize};
use specta::Type;

use super::{DriftCause, DriftRow};
use crate::env::Env;
use crate::model::Scope;

/// What one installation of an item is waiting on, and what may be done
/// about it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct RowExits {
    /// `kind:name:harness`, the row this describes.
    pub key: String,
    /// Whether this row stops every exit its item has. Both exits act on
    /// the whole item, so one place nothing can settle takes the offers
    /// off every other place too.
    pub blocking: bool,
    /// Whether adoption can keep what is at this position — the shape
    /// allows it, and the tool has something here to take.
    pub keep: bool,
    /// Whether installing what the manifest asks for over it is an answer.
    pub replace: bool,
}

/// The row key a surface groups installations by.
pub fn row_key(row: &DriftRow) -> String {
    format!("{}:{}:{}", row.kind.name(), row.name, row.harness.name())
}

/// Read once per audit, so the page, the plan and the printed commands
/// never answer this differently.
pub fn for_rows(env: &Env, scope: &Scope, rows: &[DriftRow]) -> Vec<RowExits> {
    rows.iter()
        .filter(|row| row.dead_stop())
        .map(|row| RowExits {
            key: row_key(row),
            blocking: true,
            keep: row.cause.is_some_and(DriftCause::can_keep)
                && super::adopt::can_keep_for(env, scope, row.kind, &row.name, row.harness),
            replace: row.cause.is_some_and(DriftCause::can_replace),
        })
        .collect()
}
