//! The retention duty's fleet transition: the lane records the duty judged
//! past the retention and the fleet-log rows past its cutoff leave the fleet
//! state. The judgement is the duty's (`watch::retention`), made on the disk
//! it reads; the transition is a pure function of the record and the
//! request. The transition is the judgement's commit: an item's rows leave,
//! and the item is confirmed for the removal of its record, only while every
//! row of the item still equals the row the judgement read; a row a writer
//! moved since leaves the item whole for the next pass. The selection is
//! one function, which the duty also reads before the transition to archive
//! what it will drop.

use agent_runtime::record::{self, Document};
use std::path::Path;

use agent_runtime::clock;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Env;
use crate::error::Result;

fn field<'a>(record: &'a Value, key: &str) -> Option<&'a str> {
    record.get(key).and_then(Value::as_str)
}

/// One item the pass removes anything of: every lane row of the item as the
/// judgement read it, in record order, and whether its rows past the first
/// leave.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlannedRows {
    pub item: String,
    pub rows: Vec<Value>,
    pub drop: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PruneRecords {
    pub lanes: Vec<PlannedRows>,
    /// The epoch second before which a fleet log row's `at` is past the
    /// retention.
    pub cutoff: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordsPruned {
    /// The items whose rows left, in record order.
    pub lanes: Vec<String>,
    /// The items whose rows all still equal the judgement's, in request
    /// order: those whose record the removal may take.
    pub confirmed: Vec<String>,
    pub fleet_log: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Dropped {
    pub lanes: Vec<Value>,
    pub fleet_log: Vec<Value>,
}

impl Dropped {
    pub fn is_empty(&self) -> bool {
        self.lanes.is_empty() && self.fleet_log.is_empty()
    }

    /// The archive's `records.json`.
    pub fn records(&self) -> Value {
        serde_json::json!({"fleet_log": self.fleet_log, "lanes": self.lanes})
    }
}

fn item_rows(lanes: &[Value], item: &str) -> Vec<Value> {
    lanes
        .iter()
        .filter(|lane| field(lane, "item") == Some(item))
        .cloned()
        .collect()
}

/// The planned items whose rows in `lanes` still equal the plan's.
fn confirmed<'a>(lanes: &[Value], r: &'a PruneRecords) -> Vec<&'a PlannedRows> {
    r.lanes
        .iter()
        .filter(|planned| item_rows(lanes, &planned.item) == planned.rows)
        .collect()
}

/// Whether the lane record at `index` leaves: every record but the first
/// (its `launched_at` is the fleet start) of a confirmed item the request
/// drops.
fn lane_leaves(index: usize, lane: &Value, confirmed: &[&PlannedRows]) -> bool {
    let item = field(lane, "item").unwrap_or("");
    index > 0 && confirmed.iter().any(|p| p.drop && p.item == item)
}

/// Whether the fleet log row leaves: its `at` parses and is before the
/// cutoff; a row with no readable `at` stays.
fn row_leaves(row: &Value, r: &PruneRecords) -> bool {
    field(row, "at")
        .and_then(clock::epoch_secs)
        .is_some_and(|at| at < r.cutoff)
}

/// The selection, each array read as the record holds it.
pub fn dropped(path: &Path, doc: &Document, r: &PruneRecords) -> Result<Dropped> {
    let mut out = Dropped::default();
    if let Some(lanes) = record::field::<Vec<Value>>(path, doc, "lanes")? {
        let confirmed = confirmed(&lanes, r);
        out.lanes = lanes
            .iter()
            .enumerate()
            .filter(|(index, lane)| lane_leaves(*index, lane, &confirmed))
            .map(|(_, lane)| lane.clone())
            .collect();
    }
    if let Some(rows) = record::field::<Vec<Value>>(path, doc, "fleet_log")? {
        out.fleet_log = rows.into_iter().filter(|row| row_leaves(row, r)).collect();
    }
    Ok(out)
}

/// The transition: what [`dropped`] selects leaves `lanes[]` and
/// `fleet_log[]`, each array written back only when a member leaves, so a
/// fresh fleet record (`state init --fleet` writes neither array) and a
/// pass that drops nothing leave the document as found and the store
/// writes nothing. The request's epoch second is the clock.
pub fn prune_records(
    path: &Path,
    doc: &mut Document,
    r: &PruneRecords,
    _env: &Env,
) -> Result<RecordsPruned> {
    let lanes = record::field::<Vec<Value>>(path, doc, "lanes")?.unwrap_or_default();
    let confirmed = confirmed(&lanes, r);
    let mut pruned = RecordsPruned {
        lanes: Vec::new(),
        confirmed: confirmed.iter().map(|p| p.item.clone()).collect(),
        fleet_log: 0,
    };
    let mut kept = Vec::with_capacity(lanes.len());
    for (index, lane) in lanes.into_iter().enumerate() {
        if lane_leaves(index, &lane, &confirmed) {
            pruned
                .lanes
                .push(field(&lane, "item").unwrap_or("").to_owned());
        } else {
            kept.push(lane);
        }
    }
    if !pruned.lanes.is_empty() {
        record::set(doc, "lanes", kept);
    }
    if let Some(rows) = record::field::<Vec<Value>>(path, doc, "fleet_log")? {
        let before = rows.len();
        let kept: Vec<Value> = rows.into_iter().filter(|row| !row_leaves(row, r)).collect();
        pruned.fleet_log = before - kept.len();
        if pruned.fleet_log > 0 {
            record::set(doc, "fleet_log", kept);
        }
    }
    Ok(pruned)
}
