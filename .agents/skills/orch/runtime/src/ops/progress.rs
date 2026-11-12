//! The item's progress records: where it works and the cycle it runs
//! (`record-route`), what a dev round returned (`record-dev-return`), and how
//! far its pull request has come (`record-pr-progress`). `state init` writes
//! the first `worktree`, `branch`, `qa_labels` and `sub_issues`; this module
//! is the one writer of every later value of those and of the other fields
//! below, and the pointer verbs reach them only through the checks at its end.

use agent_runtime::record::{self, Document};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::findings::added_entries;
use super::records::some_commit;
use super::store::{array_at, one_value};
use crate::error::{Error, Result};
use agent_runtime::journal::Env;

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// The cycles an item runs, as `item-tier` assigns them; a review floor
/// names one of them too.
const TIERS: [&str; 3] = ["micro", "small", "standard"];

/// The publication orders: the three `pr-order` answers and the steps an
/// early pull request moves through after it.
const PR_ORDERS: [&str; 7] = [
    "review-first",
    "open-first",
    "open-first-returned",
    "open-first-pushed",
    "push-first",
    "push-first-returned",
    "push-first-pushed",
];

fn text_of(value: &Value) -> String {
    value
        .as_str()
        .map_or_else(|| value.to_string(), str::to_owned)
}

fn word_in(words: &[&str], value: &Value) -> std::result::Result<(), String> {
    match value.as_str() {
        Some(word) if words.contains(&word) => Ok(()),
        _ => Err(format!("not one of {}: {value}", words.join(", "))),
    }
}

/// The refusal of a tier word outside the three, under the key of the field
/// that names it.
pub(crate) fn tier_value(field: &str, value: &Value) -> Result<()> {
    let key = if field == "review_floor" {
        "review-floor-value"
    } else {
        "tier-value"
    };
    word_in(&TIERS, value).map_err(|_| refused(key, &[("value", &text_of(value))]))
}

/// The checkout and branch an item works on and the cycle it runs, each
/// named field replacing the record's. `review_floor` is the lowest tier a
/// directed change's review keeps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordRoute {
    #[serde(default)]
    pub worktree: Option<PathBuf>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub tier: Option<String>,
    #[serde(default)]
    pub review_floor: Option<String>,
}

fn worktree_path(value: &Value) -> std::result::Result<(), String> {
    match value.as_str() {
        Some(path) if Path::new(path).is_absolute() => Ok(()),
        _ => Err(format!("not an absolute path: {value}")),
    }
}

fn branch_name(value: &Value) -> std::result::Result<(), String> {
    match value.as_str() {
        Some(branch) if !branch.trim().is_empty() => Ok(()),
        _ => Err(format!("not a branch: {value}")),
    }
}

pub(crate) fn record_route(doc: &mut Document, r: &RecordRoute) -> Result<Value> {
    let mut route = Map::new();
    if let Some(worktree) = &r.worktree {
        let value = json!(worktree.display().to_string());
        worktree_path(&value)
            .map_err(|_| refused("worktree-invalid", &[("worktree", &text_of(&value))]))?;
        route.insert("worktree".to_owned(), value);
    }
    if let Some(branch) = &r.branch {
        let value = json!(branch);
        branch_name(&value).map_err(|_| refused("branch-invalid", &[("branch", branch)]))?;
        route.insert("branch".to_owned(), value);
    }
    for (field, word) in [("tier", &r.tier), ("review_floor", &r.review_floor)] {
        if let Some(word) = word {
            let value = json!(word);
            tier_value(field, &value)?;
            route.insert(field.to_owned(), value);
        }
    }
    if route.is_empty() {
        return Err(refused("route-empty", &[]));
    }
    for (field, value) in &route {
        record::set(doc, field, value.clone());
    }
    Ok(json!({"route": route}))
}

/// What a dev round returned that the next round reads, each named field
/// replacing the record's: the near-ceiling lines, the QA labels and the
/// sub-issues. A field the round has no answer for is left out, which keeps
/// the record's.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordDevReturn {
    #[serde(default)]
    pub near_ceiling: Option<Vec<String>>,
    #[serde(default)]
    pub qa_labels: Option<Vec<String>>,
    #[serde(default)]
    pub sub_issues: Option<Vec<String>>,
}

pub(crate) fn record_dev_return(doc: &mut Document, r: &RecordDevReturn) -> Result<Value> {
    let named = [
        ("near_ceiling", &r.near_ceiling),
        ("qa_labels", &r.qa_labels),
        ("sub_issues", &r.sub_issues),
    ];
    let mut written = Map::new();
    for (field, lines) in named {
        let Some(lines) = lines else { continue };
        if lines.iter().any(|line| line.trim().is_empty()) {
            return Err(refused("dev-return-field", &[("field", field)]));
        }
        written.insert(field.to_owned(), json!(lines));
    }
    if written.is_empty() {
        return Err(refused("dev-return-empty", &[]));
    }
    for (field, value) in &written {
        record::set(doc, field, value.clone());
    }
    Ok(json!({"written": written}))
}

/// One step of a pull request's progress, tagged by `step`: its
/// publication order, the item-wide approval flags, the one CI rerun of a
/// head and its run, and a restack's skipped re-test.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RecordPrProgress {
    Order {
        order: String,
    },
    /// The user chose Force merge: `pr_approval.forced`, never cleared.
    Forced {},
    /// Every reviewer stayed silent past the period and the setting
    /// proceeds: `pr_approval.reviewer_down`.
    ReviewerDown {},
    /// The children's detach ran before the arm: `children_detached`.
    ChildrenDetached {},
    /// The one rerun of a transient failure on `head`, recorded before it
    /// is asked for, its time the runtime's clock.
    CiRerun {
        head: String,
    },
    /// The run the rerun of `head` started.
    CiRerunRun {
        head: String,
        run: u64,
    },
    /// The skip entry the file holds, replacing one of the same head.
    RestackSkip {
        file: PathBuf,
    },
}

/// A restack's skipped re-test as the proof reader reads it: the restacked
/// head equivalent to the validated one under `condition`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RestackSkip {
    head: String,
    condition: SkipCondition,
    validated_head: String,
    paths: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum SkipCondition {
    NoConflict,
    VersionOnly,
}

fn restack_skip(value: &Value) -> std::result::Result<(), String> {
    let skip: RestackSkip = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    some_commit(&json!(skip.head))?;
    some_commit(&json!(skip.validated_head))
}

/// The record of the one rerun a head gets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CiRerun {
    head: String,
    run: Option<u64>,
    at: String,
}

fn head_named(head: &str) -> Result<()> {
    some_commit(&json!(head)).map_err(|_| refused("head-invalid", &[("head", head)]))
}

pub(crate) fn record_pr_progress(
    path: &Path,
    doc: &mut Document,
    env: &Env,
    r: &RecordPrProgress,
) -> Result<Value> {
    let flag = |doc: &mut Document, pointer: &str| -> Result<Value> {
        super::store::set_at(path, doc, pointer, Value::Bool(true))?;
        Ok(json!({"pointer": pointer, "value": true}))
    };
    match r {
        RecordPrProgress::Order { order } => {
            let value = json!(order);
            word_in(&PR_ORDERS, &value)
                .map_err(|_| refused("pr-order-value", &[("order", order)]))?;
            record::set(doc, "pr_order", value.clone());
            Ok(json!({"pointer": "/pr_order", "value": value}))
        }
        RecordPrProgress::Forced {} => flag(doc, "/pr_approval/forced"),
        RecordPrProgress::ReviewerDown {} => flag(doc, "/pr_approval/reviewer_down"),
        RecordPrProgress::ChildrenDetached {} => flag(doc, "/children_detached"),
        RecordPrProgress::CiRerun { head } => {
            head_named(head)?;
            let rerun = json!({"head": head, "run": Value::Null, "at": env.iso()});
            record::set(doc, "ci_rerun", rerun.clone());
            Ok(json!({"pointer": "/ci_rerun", "value": rerun}))
        }
        RecordPrProgress::CiRerunRun { head, run } => {
            let standing = doc
                .get("ci_rerun")
                .and_then(|rerun| rerun.get("head"))
                .and_then(Value::as_str);
            if standing != Some(head.as_str()) {
                return Err(refused(
                    "ci-rerun-head",
                    &[("head", head), ("recorded", standing.unwrap_or("none"))],
                ));
            }
            super::store::set_at(path, doc, "/ci_rerun/run", json!(run))?;
            Ok(json!({"pointer": "/ci_rerun/run", "value": run}))
        }
        RecordPrProgress::RestackSkip { file } => {
            let entry = one_value(file)?;
            restack_skip(&entry).map_err(|cause| {
                refused(
                    "restack-skip-field",
                    &[("file", &file.display().to_string()), ("cause", &cause)],
                )
            })?;
            let skips = array_at(path, doc, "/restack_skips")?;
            let before = skips.len();
            skips.retain(|skip| skip.get("head") != entry.get("head"));
            let replaced = before - skips.len();
            skips.push(entry.clone());
            Ok(json!({"pointer": "/restack_skips", "value": entry, "replaced": replaced}))
        }
    }
}

// ---------------------------------------------------------------------------
// The checks a pointer write into these fields is held to
// ---------------------------------------------------------------------------

fn nullable(
    now: &Value,
    check: fn(&Value) -> std::result::Result<(), String>,
) -> std::result::Result<(), String> {
    if now.is_null() { Ok(()) } else { check(now) }
}

pub(crate) fn check_worktree(now: &Value) -> std::result::Result<(), String> {
    nullable(now, worktree_path)
}

pub(crate) fn check_branch(now: &Value) -> std::result::Result<(), String> {
    nullable(now, branch_name)
}

pub(crate) fn check_tier(now: &Value) -> std::result::Result<(), String> {
    nullable(now, |now| word_in(&TIERS, now))
}

pub(crate) fn check_lines(now: &Value) -> std::result::Result<(), String> {
    let lines: Option<Vec<String>> =
        serde_json::from_value(now.clone()).map_err(|e| e.to_string())?;
    match lines {
        Some(lines) if lines.iter().any(|line| line.trim().is_empty()) => {
            Err("an empty line".into())
        }
        Some(_) | None => Ok(()),
    }
}

pub(crate) fn check_order(now: &Value) -> std::result::Result<(), String> {
    nullable(now, |now| word_in(&PR_ORDERS, now))
}

/// `pr_approval`'s two flags are booleans; its other keys are readers'.
pub(crate) fn check_approval(now: &Value) -> std::result::Result<(), String> {
    let Some(approval) = now.as_object() else {
        return nullable(now, |now| Err(format!("not an object: {now}")));
    };
    for flag in ["forced", "reviewer_down"] {
        match approval.get(flag) {
            None | Some(Value::Null | Value::Bool(_)) => {}
            Some(other) => return Err(format!("{flag} not a boolean: {other}")),
        }
    }
    Ok(())
}

pub(crate) fn check_rerun(now: &Value) -> std::result::Result<(), String> {
    let rerun: Option<CiRerun> = serde_json::from_value(now.clone()).map_err(|e| e.to_string())?;
    rerun.map_or(Ok(()), |rerun| some_commit(&json!(rerun.head)))
}

pub(crate) fn check_skips(was: Option<&Value>, now: &Value) -> std::result::Result<(), String> {
    added_entries(was, now)?
        .into_iter()
        .try_for_each(restack_skip)
}
