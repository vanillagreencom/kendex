//! The overseer's ledger on the fleet record: the last backlog audit, the
//! launch queue, the triage verdicts, the security alerts' verdicts and the
//! overseer's own handoff. `record-overseer-ledger` is the one writer of
//! each; the pointer verbs reach them only through the checks below.

use agent_runtime::record::{self, Document};
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::findings::added_entries;
use super::store::{array_at, one_value, stamp};
use crate::error::{Error, Result};
use crate::state;
use agent_runtime::journal::Env;

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// One ledger entry, tagged by `entry`. A triage or an alert verdict carries
/// the overseer's own reason, so its entry is the one value `file` holds.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "entry", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RecordOverseerLedger {
    /// The team backlog's count at a full audit, stamped with the runtime's
    /// clock: the next heartbeat compares its count and age.
    BacklogAudit {
        backlog: u64,
    },
    /// The items not yet launched, in launch order, replacing the queue.
    LaunchQueue {
        items: Vec<String>,
    },
    Triage {
        file: PathBuf,
    },
    AlertVerdict {
        file: PathBuf,
    },
    /// The record a fresh overseer resumes from, `written_at` stamped under
    /// the store's time rule.
    Handoff {
        handoff_file: String,
        pane_key: String,
        session_id: String,
        #[serde(default)]
        context: Value,
        #[serde(default)]
        written_at: Option<Value>,
    },
}

impl RecordOverseerLedger {
    fn word(&self) -> &'static str {
        match self {
            RecordOverseerLedger::BacklogAudit { .. } => "backlog-audit",
            RecordOverseerLedger::LaunchQueue { .. } => "launch-queue",
            RecordOverseerLedger::Triage { .. } => "triage",
            RecordOverseerLedger::AlertVerdict { .. } => "alert-verdict",
            RecordOverseerLedger::Handoff { .. } => "handoff",
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BacklogAudit {
    at: String,
    #[serde(rename = "backlog")]
    _backlog: u64,
}

fn backlog_audit(value: &Value) -> std::result::Result<(), String> {
    let audit: BacklogAudit = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    clock::epoch_secs(&audit.at)
        .filter(|epoch| clock::iso_utc(*epoch) == audit.at)
        .map(drop)
        .ok_or_else(|| format!("at not an ISO 8601 UTC time: {}", audit.at))
}

/// The queue's first entry that is empty or repeats an earlier one.
fn queue_fault(items: &[String]) -> Option<&str> {
    items
        .iter()
        .enumerate()
        .find(|(index, item)| item.is_empty() || items[..*index].contains(item))
        .map(|(_, item)| item.as_str())
}

/// A triage row names the issue, the reason and a verdict the watch reads;
/// a string row or an `item`-keyed one names no key it can acknowledge.
pub(crate) fn triage_row(row: &Value) -> Result<()> {
    let valid = row.as_object().is_some_and(|row| {
        let mut keys: Vec<&str> = row.keys().map(String::as_str).collect();
        keys.sort_unstable();
        keys == ["issue", "reason", "verdict"]
            && row.get("issue").is_some_and(Value::is_string)
            && row.get("reason").is_some_and(Value::is_string)
            && row
                .get("verdict")
                .and_then(Value::as_str)
                .is_some_and(|v| state::ACKNOWLEDGED_VERDICTS.contains(&v))
    });
    if valid {
        Ok(())
    } else {
        Err(refused("triaged-record-invalid", &[("field", "triaged")]))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum AlertOutcome {
    Filed,
    Dismissed,
}

/// The verdict fields beside the alert's key, which the watch's own reader
/// judges.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AlertVerdict {
    #[serde(rename = "repo")]
    _repo: String,
    #[serde(rename = "kind")]
    _kind: String,
    #[serde(rename = "number")]
    _number: u64,
    verdict: AlertOutcome,
    item: Option<String>,
    #[serde(rename = "reason")]
    _reason: String,
}

/// A verdict the watch keys its alert by, naming the item it was filed
/// under exactly when it was filed: a row the watch cannot key makes its
/// whole verdict list unreadable.
fn alert_verdict(row: &Value) -> std::result::Result<(), String> {
    let verdict: AlertVerdict = serde_json::from_value(row.clone()).map_err(|e| e.to_string())?;
    let keyed = crate::watch::security::recorded(std::slice::from_ref(row))
        .is_some_and(|keys| keys.len() == 1);
    if !keyed {
        return Err("no repository, alert kind and number the watch reads".into());
    }
    match (verdict.verdict, verdict.item.as_deref()) {
        (AlertOutcome::Filed, Some(item)) if !item.is_empty() => Ok(()),
        (AlertOutcome::Dismissed, None) => Ok(()),
        (AlertOutcome::Filed, _) => Err("a filed verdict names no item".into()),
        (AlertOutcome::Dismissed, Some(_)) => Err("a dismissed verdict names an item".into()),
    }
}

/// The overseer's handoff record: an object, its `written_at` stamped.
pub(crate) fn handoff(doc: &mut Document, env: &Env, mut value: Value) -> Result<Value> {
    let Value::Object(record) = &mut value else {
        return Err(refused("handoff-record", &[("pointer", "/handoff")]));
    };
    stamp(
        record,
        env,
        "written_at",
        "handoff-written-at-invalid",
        "handoff-written-at-future",
    )?;
    record::set(doc, "handoff", value.clone());
    Ok(json!({"entry": "handoff", "pointer": "/handoff", "value": value}))
}

pub(crate) fn record_overseer_ledger(
    path: &Path,
    doc: &mut Document,
    env: &Env,
    r: &RecordOverseerLedger,
) -> Result<Value> {
    let entry = r.word();
    let (pointer, value) = match r {
        RecordOverseerLedger::BacklogAudit { backlog } => {
            let audit = json!({"at": env.iso(), "backlog": backlog});
            record::set(doc, "last_backlog_audit", audit.clone());
            ("/last_backlog_audit", audit)
        }
        RecordOverseerLedger::LaunchQueue { items } => {
            if let Some(item) = queue_fault(items) {
                return Err(refused("launch-queue-entry", &[("item", item)]));
            }
            record::set(doc, "launch_queue", json!(items));
            ("/launch_queue", json!(items))
        }
        RecordOverseerLedger::Triage { file } => {
            let row = one_value(file)?;
            triage_row(&row)?;
            array_at(path, doc, "/triaged")?.push(row.clone());
            ("/triaged", row)
        }
        RecordOverseerLedger::AlertVerdict { file } => {
            let row = one_value(file)?;
            alert_verdict(&row).map_err(|cause| {
                refused(
                    "alert-verdict",
                    &[("file", &file.display().to_string()), ("cause", &cause)],
                )
            })?;
            array_at(path, doc, "/alerts_triaged")?.push(row.clone());
            ("/alerts_triaged", row)
        }
        RecordOverseerLedger::Handoff {
            handoff_file,
            pane_key,
            session_id,
            context,
            written_at,
        } => {
            let mut record = json!({"handoff_file": handoff_file, "pane_key": pane_key,
                                    "session_id": session_id, "context": context});
            if let Some(at) = written_at {
                record["written_at"] = at.clone();
            }
            return handoff(doc, env, record);
        }
    };
    Ok(json!({"entry": entry, "pointer": pointer, "value": value}))
}

// ---------------------------------------------------------------------------
// The checks a pointer write into these fields is held to
// ---------------------------------------------------------------------------

pub(crate) fn check_backlog_audit(now: &Value) -> std::result::Result<(), String> {
    if now.is_null() {
        return Ok(());
    }
    backlog_audit(now)
}

pub(crate) fn check_queue(now: &Value) -> std::result::Result<(), String> {
    let items: Option<Vec<String>> =
        serde_json::from_value(now.clone()).map_err(|e| e.to_string())?;
    match items.as_deref().and_then(queue_fault) {
        Some(item) => Err(format!("an empty or repeated item: {item:?}")),
        None => Ok(()),
    }
}

pub(crate) fn check_triaged(was: Option<&Value>, now: &Value) -> std::result::Result<(), String> {
    added_entries(was, now)?
        .into_iter()
        .try_for_each(|row| triage_row(row).map_err(|e| e.to_string()))
}

pub(crate) fn check_alerts(was: Option<&Value>, now: &Value) -> std::result::Result<(), String> {
    added_entries(was, now)?
        .into_iter()
        .try_for_each(alert_verdict)
}
