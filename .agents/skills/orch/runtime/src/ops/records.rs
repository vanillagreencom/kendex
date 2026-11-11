//! The named record writes: the operations a workflow records a step's
//! outcome through, each validating what it writes, and the one table of the
//! record fields each operation owns. They start no effect and persist no
//! intent, so none is a [`super::Request`]: `op` routes a request here by its
//! `op` name. The pointer verbs stay as the adapter for an outside caller;
//! a pointer write into an owned field is held to its owner's check through
//! [`check_owned`].

use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::findings::{self, Bucket, RecordCommentLedger, RecordDisposition};
use super::item::{RecordRound, RoundKind};
use super::reviewers::{self, PanelKind, RecordAgents, RecordPanel};
use super::{Env, item, loaded, qa, reread, store};
use crate::error::{Error, Result};
use crate::settings::StoreSettings;
use crate::state::{self, Document, Kind, Locking};

/// One named record write, tagged by `op`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Record {
    RecordRound(RecordRound),
    RecordPanel(RecordPanel),
    RecordAgents(RecordAgents),
    RecordDisposition(RecordDisposition),
    RecordCommentLedger(RecordCommentLedger),
}

/// The `op` names [`Record`] answers; every other name is a [`super::Request`].
const NAMES: [&str; 5] = [
    "record-round",
    "record-panel",
    "record-agents",
    "record-disposition",
    "record-comment-ledger",
];

impl Record {
    pub fn op_name(&self) -> &'static str {
        match self {
            Record::RecordRound(_) => NAMES[0],
            Record::RecordPanel(_) => NAMES[1],
            Record::RecordAgents(_) => NAMES[2],
            Record::RecordDisposition(_) => NAMES[3],
            Record::RecordCommentLedger(_) => NAMES[4],
        }
    }

    /// The request `value` decoded as a record write, `None` where its `op`
    /// names none.
    pub fn decode(value: &Value) -> Option<std::result::Result<Record, serde_json::Error>> {
        let op = value.get("op")?.as_str()?;
        NAMES
            .contains(&op)
            .then(|| serde_json::from_value(value.clone()))
    }

    fn record_kind(&self) -> Kind {
        match self {
            Record::RecordRound(_)
            | Record::RecordPanel(_)
            | Record::RecordAgents(_)
            | Record::RecordDisposition(_)
            | Record::RecordCommentLedger(_) => Kind::Item,
        }
    }
}

/// Apply `record` to the state file at `path` in one transition under the
/// write check. A read the write records (a checkout's HEAD) comes first.
#[allow(
    clippy::disallowed_methods,
    reason = "the record writes' one store: the transition's document committed through the state module's write check"
)]
pub fn apply_record(
    path: &Path,
    record: &Record,
    store: &StoreSettings,
    env: &Env,
    locking: Locking,
) -> Result<Value> {
    let kind = Kind::of_path(path);
    if kind != record.record_kind() {
        return Err(Error::OpKind {
            op: record.op_name(),
            path: path.to_path_buf(),
            kind,
            wanted: record.record_kind(),
        });
    }
    let head = match record {
        Record::RecordRound(RecordRound::Base { worktree, .. }) => Some(store::git_head(worktree)?),
        Record::RecordRound(_)
        | Record::RecordPanel(_)
        | Record::RecordAgents(_)
        | Record::RecordDisposition(_)
        | Record::RecordCommentLedger(_) => None,
    };
    reread(|| {
        let snapshot = loaded(path)?;
        let mut doc = snapshot.doc.clone();
        let report = match record {
            Record::RecordRound(r) => item::record_round(path, &mut doc, r, env, head.as_deref())?,
            Record::RecordPanel(r) => reviewers::record_panel(path, &mut doc, store, r)?,
            Record::RecordAgents(r) => reviewers::record_agents(path, &mut doc, r)?,
            Record::RecordDisposition(r) => findings::record_disposition(path, &mut doc, r)?,
            Record::RecordCommentLedger(r) => findings::record_comment_ledger(path, &mut doc, r)?,
        };
        state::store(path, &snapshot, &doc, locking)?;
        Ok(report)
    })
}

/// A field's check over its value before (`None` where absent) and after a
/// write; the cause where the value is not one its owner writes.
enum Check {
    Whole(fn(&Value) -> std::result::Result<(), String>),
    Added(fn(Option<&Value>, &Value) -> std::result::Result<(), String>),
}

fn some_text(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<Option<String>>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}

fn some_count(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<Option<u64>>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}

fn some_flag(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<Option<bool>>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}

/// A commit a checkout's HEAD names: hexadecimal, as `git rev-parse`
/// prints it.
fn some_commit(now: &Value) -> std::result::Result<(), String> {
    match now {
        Value::Null => Ok(()),
        Value::String(sha) if !sha.is_empty() && sha.bytes().all(|b| b.is_ascii_hexdigit()) => {
            Ok(())
        }
        other => Err(format!("not a commit: {other}")),
    }
}

/// Every record field a named operation owns, the operation, and the check a
/// pointer write into it is held to.
fn owned_fields() -> Vec<(&'static str, &'static str, Check)> {
    let mut fields: Vec<(&'static str, &'static str, Check)> = Vec::new();
    for field in RoundKind::FIELDS {
        fields.push((field, "begin-round", Check::Whole(some_text)));
    }
    fields.extend([
        (
            "pre_delegate_sha",
            "record-round",
            Check::Whole(some_commit),
        ),
        ("review_fix_round", "record-round", Check::Whole(some_flag)),
        ("dev_delegated_at", "record-round", Check::Whole(some_count)),
        (
            "review_delegated_at",
            "record-round",
            Check::Whole(some_count),
        ),
        ("cycles", "record-round", Check::Whole(some_count)),
        ("rereview_cycles", "record-panel", Check::Whole(some_count)),
        (
            "child_sessions",
            "record-agents",
            Check::Whole(reviewers::check_children),
        ),
        (
            "review_agents",
            "record-agents",
            Check::Whole(reviewers::check_names),
        ),
        (
            "review_agent_ids",
            "record-agents",
            Check::Whole(reviewers::check_named_map),
        ),
        (
            "review_agent_runtime_types",
            "record-agents",
            Check::Whole(reviewers::check_named_map),
        ),
        (
            "review_wave_done",
            "record-agents",
            Check::Whole(reviewers::check_names),
        ),
        (
            "reviewer_slots_observed",
            "record-agents",
            Check::Whole(some_count),
        ),
        (
            "json_paths",
            "record-agents",
            Check::Whole(reviewers::check_names),
        ),
        (
            "pr_comment_review",
            "record-comment-ledger",
            Check::Added(findings::check_ledger),
        ),
        (
            "pr_review_baseline",
            "record-comment-ledger",
            Check::Whole(findings::check_baseline),
        ),
        (
            "audit_issues_created",
            "record-comment-ledger",
            Check::Added(findings::check_issues),
        ),
        (
            "qa_decision",
            "record-qa-decision",
            Check::Whole(qa::check_decision),
        ),
    ]);
    for field in PanelKind::FIELDS {
        fields.push((field, "record-panel", Check::Whole(reviewers::check_panel)));
    }
    for field in Bucket::FIELDS {
        fields.push((
            field,
            "record-disposition",
            Check::Added(findings::check_bucket),
        ));
    }
    fields
}

/// The refusal of a pointer write that lands a value `op` would not write
/// into `field`.
pub(crate) fn owned_refusal(field: &str, op: &str, cause: &str) -> Error {
    agent_runtime::Error::refused(
        "field-owned",
        &[("field", field), ("op", op), ("cause", cause)],
    )
    .into()
}

/// Hold every owned field a write moved between `before` and `after` to its
/// owner's check.
pub(crate) fn check_owned(before: &Document, after: &Document) -> Result<()> {
    for (field, op, check) in owned_fields() {
        let was = before.get(field);
        let Some(now) = after.get(field).filter(|now| was != Some(*now)) else {
            continue;
        };
        let checked = match check {
            Check::Whole(check) => check(now),
            Check::Added(check) => check(was, now),
        };
        checked.map_err(|cause| owned_refusal(field, op, &cause))?;
    }
    Ok(())
}
