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
use crate::model::{HarnessId, Scope};

/// What one installation of an item is waiting on, and what may be done
/// about it. Every question a surface asks about a blocked row is answered
/// here, because they are not the same question and answering one of them
/// from another is how a page ends up drawing a button the plan refuses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct RowExits {
    /// `kind:name:harness`, the row this describes.
    pub key: String,
    /// Whether this row stops every exit its item has. Both exits act on
    /// the whole item, so one place nothing can settle takes the offers
    /// off every other place too.
    pub blocking: bool,
    /// Whether this row is about files sitting where the item installs —
    /// which is what the two exits are for. A revision clash or a source
    /// rebind is not: moving files settles nothing there, and it belongs
    /// with the changes rather than under a decision about files.
    pub files: bool,
    /// Whether this place lets the item be kept. The shape has to be one
    /// adoption can take, and it has to be reachable — either here, or
    /// through the tool holding the folder this one reads by a shortcut.
    /// A place that fails this stops the whole item, since keeping is one
    /// move for all of it.
    pub keep: bool,
    /// Whether adoption acts through this tool. A tool reading the item
    /// through a shortcut somebody made has nothing at its own place to
    /// take: its share is kept by the tool that holds the folder, so it is
    /// not named in the command.
    pub enter: bool,
    /// Whether installing what the manifest asks for over it is an answer.
    pub replace: bool,
    /// Every tool keeping this row acts on. A folder shared by hand is
    /// read by whoever links at it, declared or not, and taking it over
    /// clears each of those links — so an offer that named only the rows
    /// on screen would act on a tool it never mentioned.
    pub tools: Vec<HarnessId>,
}

/// What one row is waiting on. Read by the page through the audit and by
/// the CLI directly, so the two never answer this differently.
pub fn for_row(env: &Env, scope: &Scope, row: &DriftRow) -> RowExits {
    let enter = super::adopt::can_keep_for(env, scope, row.kind, &row.name, row.harness);
    RowExits {
        key: format!("{}:{}:{}", row.kind.name(), row.name, row.harness.name()),
        blocking: row.dead_stop(),
        files: row.cause.is_some(),
        keep: row.cause.is_some_and(DriftCause::can_keep)
            && (enter || row.cause == Some(DriftCause::SharedLink)),
        enter,
        replace: row.cause.is_some_and(DriftCause::can_replace),
        tools: tools_touched(env, scope, row),
    }
}

fn tools_touched(env: &Env, scope: &Scope, row: &DriftRow) -> Vec<HarnessId> {
    let shared = (row.cause == Some(DriftCause::SharedLink))
        .then(|| super::adopt::position(env, scope, row.kind, &row.name, row.harness))
        .flatten()
        .and_then(|at| super::adopt_shared::shared_tools(env, scope, row.kind, &row.name, &at));
    shared.unwrap_or_else(|| vec![row.harness])
}

/// Every row a surface has to draw a decision for. A conflict of another
/// kind — a revision clash, a source rebind — carries no exit of its own,
/// and is here because it takes the exits off the rows beside it: left
/// out, the page would offer an action the plan then refuses.
pub fn for_rows(env: &Env, scope: &Scope, rows: &[DriftRow]) -> Vec<RowExits> {
    rows.iter()
        .filter(|row| row.dead_stop())
        .map(|row| for_row(env, scope, row))
        .collect()
}
