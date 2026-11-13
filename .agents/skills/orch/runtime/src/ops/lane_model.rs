//! A fleet lane's model recovery on the fleet record: the claim the turn
//! end's switch takes before anything stops, counted against the recovery
//! limit since the lane's last reset, and the marks its detached job writes
//! on the switch's log row as the replacement starts and ends. And a hosted
//! lane's predecessor stop on the item's record: the failure its job keeps
//! on the handoff the switch wrote, bound to the launch it stopped.

use std::path::{Path, PathBuf};

use agent_runtime::journal::Env;
use agent_runtime::record::{self, Document};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{Error, Result};

/// `recover-lane-model`: the lane `item` whose session `session` switched
/// models under the launch `launch_identity` (`{launch, launched_at}`).
/// With no `mark` it claims the recovery; the job's own requests carry the
/// mark they write.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecoverLaneModel {
    pub item: String,
    pub session: String,
    pub launch_identity: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mark: Option<Mark>,
    /// The recovery limit the entry read from its own settings before the
    /// claim, so a request file never carries one.
    #[serde(skip)]
    pub limit: Option<u32>,
}

/// How far the recovery's replacement got, the switch row's `recovery`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Mark {
    Starting,
    Replaced,
    Failed,
}

/// What a recovery request wrote.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "recorded", rename_all = "kebab-case")]
pub enum RecoveryRecorded {
    /// The switched check marked started, with the recoveries counted since
    /// the lane's last reset; `limited` where this one reaches the limit and
    /// the limit's row was written instead of a recovery.
    Claim {
        item: String,
        recoveries: u32,
        limit: u32,
        limited: bool,
    },
    /// The mark written on each of the switch's rows.
    Mark {
        item: String,
        mark: Mark,
        rows: usize,
    },
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// The fleet transition of `r`: its claim, or the mark it carries.
pub(super) fn recover_lane_model(
    path: &Path,
    doc: &mut Document,
    r: &RecoverLaneModel,
    env: &Env,
) -> Result<RecoveryRecorded> {
    match r.mark {
        None => claim(path, doc, r, env),
        Some(mark) => Ok(mark_rows(doc, r, mark)),
    }
}

/// The claim: the lane still runs `launch_identity`, and its check is this
/// session's switch bound to that launch with no recovery started. It marks
/// the check started and counts the switches whose replacement reached a
/// harness since the lane's last reset: one `replaced`, or one left
/// `starting` under another launch than this check's (its replacement ran
/// and switched again before its mark). Where this recovery would reach the
/// limit the claim writes the limit's row in the same write, so the switch
/// is spent and never recovered again.
fn claim(
    path: &Path,
    doc: &mut Document,
    r: &RecoverLaneModel,
    env: &Env,
) -> Result<RecoveryRecorded> {
    let limit = r.limit.ok_or(Error::OpNotTransition {
        op: "recover-lane-model",
    })?;
    let item = r.item.as_str();
    let unbound = || refused("model-recovery-unbound", &[("item", item)]);
    let lanes = record::array_mut(path, doc, "lanes")?;
    let first = lanes
        .iter()
        .find(|l| l.get("item").and_then(Value::as_str) == Some(item))
        .ok_or_else(unbound)?;
    let check = first.get("model_check").cloned().unwrap_or(Value::Null);
    let launch = |key: &str| r.launch_identity.get(key).unwrap_or(&Value::Null);
    let bound = first.get("launch").unwrap_or(&Value::Null) == launch("launch")
        && first.get("launched_at").unwrap_or(&Value::Null) == launch("launched_at")
        && check.get("outcome").and_then(Value::as_str) == Some("switched")
        && check.get("session_id").and_then(Value::as_str) == Some(r.session.as_str())
        && check.get("launch_identity") == Some(&r.launch_identity)
        && check.get("recovery_started") != Some(&Value::Bool(true));
    if !bound {
        return Err(unbound());
    }
    for lane in lanes
        .iter_mut()
        .filter(|l| l.get("item").and_then(Value::as_str) == Some(item))
    {
        if let Some(check) = lane.get_mut("model_check").and_then(Value::as_object_mut) {
            check.insert("recovery_started".to_owned(), Value::Bool(true));
        }
    }
    let log = record::array_mut(path, doc, "fleet_log")?;
    let recoveries = log
        .iter()
        .filter(|row| row.get("item").and_then(Value::as_str) == Some(item))
        .fold(0_u32, |count, row| {
            let recovery = row.get("recovery").and_then(Value::as_str);
            match row.get("kind").and_then(Value::as_str) {
                Some("model-recovery-reset") => 0,
                Some("model-switched")
                    if recovery == Some("replaced")
                        || (recovery == Some("starting")
                            && row.get("launch_identity") != Some(&r.launch_identity)) =>
                {
                    count + 1
                }
                _ => count,
            }
        });
    let limited = recoveries.saturating_add(1) >= limit;
    if limited {
        log.push(json!({
            "kind": "model-recovery-limit",
            "item": item,
            "at": env.iso(),
            "recoveries": recoveries,
            "limit": limit,
            "text": format!("model-recovery-limit item={item} recoveries={recoveries} limit={limit}"),
        }));
    }
    Ok(RecoveryRecorded::Claim {
        item: item.to_owned(),
        recoveries,
        limit,
        limited,
    })
}

/// `mark` written on every switch row of the lane's session under the
/// recovered launch.
fn mark_rows(doc: &mut Document, r: &RecoverLaneModel, mark: Mark) -> RecoveryRecorded {
    let mut rows = 0;
    if let Some(log) = doc.get_mut("fleet_log").and_then(Value::as_array_mut) {
        for row in log.iter_mut().filter(|row| {
            row.get("kind").and_then(Value::as_str) == Some("model-switched")
                && row.get("item").and_then(Value::as_str) == Some(r.item.as_str())
                && row.get("session_id").and_then(Value::as_str) == Some(r.session.as_str())
                && row.get("launch_identity") == Some(&r.launch_identity)
        }) {
            if let Some(row) = row.as_object_mut() {
                row.insert("recovery".to_owned(), json!(mark));
                rows += 1;
            }
        }
    }
    RecoveryRecorded::Mark {
        item: r.item.clone(),
        mark,
        rows,
    }
}

/// `stop-model-predecessor`: the hosted lane's predecessor, the process
/// group recorded at `file`, stopped for the session `session` whose
/// switch was taken under `launch_identity`. The caller's request starts
/// the job; `job` marks the job's own, which stops the group.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StopModelPredecessor {
    pub session: String,
    pub launch_identity: Value,
    pub file: PathBuf,
    /// The group's leader as the switch's member read answered it: the job
    /// stops the group only while `file` still names this leader, since a
    /// replacement may lead a group recorded there before the job runs.
    pub leader: agent_runtime::process::Identity,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub job: bool,
    /// What the job's stop met, kept by its transition: set by the job
    /// from the stop it ran, so a request file never carries one.
    #[serde(skip)]
    pub failure: Option<StopFailure>,
}

/// A predecessor stop that did not end the group: the stop's outcome or
/// refusal word, the process it names, and the status `agent-runtime
/// process stop` exits with for the same answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StopFailure {
    pub cause: String,
    pub pid: Option<u32>,
    pub exit: i32,
}

/// Whether the failure was kept: the handoff names the session and its
/// check the launch.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StopFailureRecorded {
    pub written: bool,
}

/// The item transition of the job's failed stop: `handoff.stop_failure`
/// written only where the item's handoff is still this session's and its
/// model check is bound to the stopped launch, so a later switch's handoff
/// never carries an earlier launch's failure.
pub(super) fn record_stop_failure(
    doc: &mut Document,
    r: &StopModelPredecessor,
    env: &Env,
) -> Result<StopFailureRecorded> {
    let failure = r.failure.as_ref().ok_or(Error::OpNotTransition {
        op: "stop-model-predecessor",
    })?;
    let bound = doc
        .get("handoff")
        .and_then(|h| h.get("session_id"))
        .and_then(Value::as_str)
        == Some(r.session.as_str())
        && doc
            .get("model_checks")
            .and_then(|c| c.get(&r.session))
            .and_then(|c| c.get("launch_identity"))
            == Some(&r.launch_identity);
    if !bound {
        return Ok(StopFailureRecorded { written: false });
    }
    let entry = json!({
        "cause": failure.cause,
        "pid": failure.pid,
        "launch": r.launch_identity.get("launch").cloned().unwrap_or(Value::Null),
        "exit": failure.exit,
        "at": env.iso(),
    });
    if let Some(handoff) = doc.get_mut("handoff").and_then(Value::as_object_mut) {
        handoff.insert("stop_failure".to_owned(), entry);
    }
    Ok(StopFailureRecorded { written: true })
}
