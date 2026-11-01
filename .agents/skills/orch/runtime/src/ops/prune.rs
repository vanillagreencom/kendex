//! The retention duty's fleet transition (decisions 141 (1), (2); 153 (3)):
//! the lane records the duty judged past the retention and the fleet-log
//! rows past its cutoff leave the fleet state. The judgement is the duty's
//! (`watch::retention`), made on the disk it reads; the transition is a
//! pure function of the record and the request.

use std::path::Path;

use agent_runtime::clock;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Env;
use crate::error::Result;
use crate::state::{self, Document};

fn field<'a>(record: &'a Value, key: &str) -> Option<&'a str> {
    record.get(key).and_then(Value::as_str)
}

/// The operation `prune-records`: the lane records the retention duty
/// judged past the retention and the fleet log rows past it leave the
/// fleet state. The judgement is the duty's, made on the disk it reads;
/// the transition is a pure function of the record and this request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PruneRecords {
    /// The items whose lane records go ([`Pruned::records`]).
    pub lanes: Vec<String>,
    /// The epoch second before which a fleet log row's `at` is past the
    /// retention.
    pub cutoff: u64,
}

/// What the write dropped.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordsPruned {
    /// The items whose lane records left, in record order.
    pub lanes: Vec<String>,
    pub fleet_log: usize,
}

/// The transition: every lane record but the first (its `launched_at` is
/// the fleet start) whose item the request names leaves `lanes[]`, its
/// `kept` word with it; every `fleet_log[]` row whose `at` parses and is
/// before the cutoff leaves, a row with no readable `at` stays. The
/// request's epoch second is the clock. Dispatched from the fleet
/// transition under its `Request` variant; the retention duty applies it
/// through `ops::apply` after its pass. Each array is read as the record
/// holds it and written back only when a member leaves: a fresh fleet
/// record (`state init --fleet` writes neither array) and a pass that
/// drops nothing leave the document as found, so the store writes nothing.
pub fn prune_records(
    path: &Path,
    doc: &mut Document,
    r: &PruneRecords,
    _env: &Env,
) -> Result<RecordsPruned> {
    let mut dropped = Vec::new();
    if let Some(lanes) = state::field::<Vec<Value>>(path, doc, "lanes")? {
        let mut kept = Vec::with_capacity(lanes.len());
        for (index, lane) in lanes.into_iter().enumerate() {
            let item = field(&lane, "item").unwrap_or("");
            if index > 0 && r.lanes.iter().any(|named| named == item) {
                dropped.push(item.to_owned());
            } else {
                kept.push(lane);
            }
        }
        if !dropped.is_empty() {
            state::set(doc, "lanes", kept);
        }
    }
    let mut fleet_log = 0;
    if let Some(rows) = state::field::<Vec<Value>>(path, doc, "fleet_log")? {
        let before = rows.len();
        let kept: Vec<Value> = rows
            .into_iter()
            .filter(|row| {
                field(row, "at")
                    .and_then(clock::epoch_secs)
                    .is_none_or(|at| at >= r.cutoff)
            })
            .collect();
        fleet_log = before - kept.len();
        if fleet_log > 0 {
            state::set(doc, "fleet_log", kept);
        }
    }
    Ok(RecordsPruned {
        lanes: dropped,
        fleet_log,
    })
}
