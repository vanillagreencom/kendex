//! The item's finding records: the three arrays a review moves a finding
//! between (`fixed_items`, `escalated_items`, `declined_items`), the comment
//! triage ledger under `pr_comment_review` with its baseline, and the issues an
//! audit filed. This module is the one writer of each: `record-disposition` and
//! `record-comment-ledger` add and move entries, a push's commit remap rewrites
//! their `commit`, and the pointer verbs reach them only through the checks
//! below.

use agent_runtime::record::{self, Document};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::proof::{self, Hop};
use super::store::{array_at, one_value};
use crate::error::{Error, Result};

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// The disposition arrays, by the word a request names them with.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Bucket {
    Fixed,
    Escalated,
    Declined,
}

impl Bucket {
    pub(crate) const FIELDS: [&'static str; 3] =
        ["fixed_items", "escalated_items", "declined_items"];

    fn field(self) -> &'static str {
        match self {
            Bucket::Fixed => Self::FIELDS[0],
            Bucket::Escalated => Self::FIELDS[1],
            Bucket::Declined => Self::FIELDS[2],
        }
    }
}

/// Move one finding into `into`, out of each `drop` array first by its
/// location and description. The entry is the file's one value, or with
/// `element` the description and location of the element at that pointer in
/// it; each of `fields` stands beside them and an empty one is left out. The
/// entry names a string `description` and `location`, or the request refuses
/// `disposition-entry`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordDisposition {
    pub into: Bucket,
    #[serde(default)]
    pub drop: Vec<Bucket>,
    pub file: PathBuf,
    #[serde(default)]
    pub element: Option<String>,
    #[serde(default)]
    pub fields: BTreeMap<String, String>,
}

/// The finding fields every disposition reader keys an entry by.
#[derive(Deserialize)]
struct Finding {
    #[serde(rename = "description")]
    _description: String,
    #[serde(rename = "location")]
    _location: String,
}

/// The entry a bucket write moves: the file's value, or the element's
/// description and location, with the named fields beside it.
pub(crate) fn entry_of(
    file: &Path,
    element: Option<&str>,
    fields: &[(String, String)],
) -> Result<Value> {
    let value = one_value(file)?;
    let text = file.display().to_string();
    let mut entry = match element {
        None => value,
        Some(element) => {
            let Some(found) = value.pointer(element) else {
                return Err(refused(
                    "bucket-element",
                    &[("file", &text), ("element", element)],
                ));
            };
            json!({
                "description": found.get("description").cloned().unwrap_or(Value::Null),
                "location": found.get("location").cloned().unwrap_or(Value::Null),
            })
        }
    };
    let Value::Object(map) = &mut entry else {
        return Err(refused("bucket-entry", &[("file", &text)]));
    };
    for (name, value) in fields {
        if !value.is_empty() {
            map.insert(name.clone(), Value::String(value.clone()));
        }
    }
    Ok(entry)
}

fn same_finding(a: &Value, b: &Value) -> bool {
    a.get("location") == b.get("location") && a.get("description") == b.get("description")
}

/// Drop `entry` from each array at `drop`, then append it to the array at
/// `into`; each array is created where absent.
pub(crate) fn bucket(
    path: &Path,
    doc: &mut Document,
    into: &str,
    drop: &[String],
    entry: Value,
) -> Result<Value> {
    let mut dropped = 0;
    for pointer in drop {
        let items = array_at(path, doc, pointer)?;
        let before = items.len();
        items.retain(|item| !same_finding(item, &entry));
        dropped += before - items.len();
    }
    array_at(path, doc, into)?.push(entry.clone());
    Ok(json!({"into": into, "entry": entry, "dropped": dropped}))
}

pub(crate) fn record_disposition(
    path: &Path,
    doc: &mut Document,
    r: &RecordDisposition,
) -> Result<Value> {
    let fields: Vec<(String, String)> = r.fields.clone().into_iter().collect();
    let entry = entry_of(&r.file, r.element.as_deref(), &fields)?;
    if let Err(cause) = serde_json::from_value::<Finding>(entry.clone()) {
        return Err(refused(
            "disposition-entry",
            &[
                ("file", &r.file.display().to_string()),
                ("cause", &cause.to_string()),
            ],
        ));
    }
    let pointer = |b: Bucket| format!("/{}", b.field());
    let drop: Vec<String> = r.drop.iter().map(|b| pointer(*b)).collect();
    bucket(path, doc, &pointer(r.into), &drop, entry)
}

/// A cause a freeze closed, with the class issue that carries it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FrozenCause {
    pub cause: String,
    pub issue: String,
}

/// A cause a fix patched, read by the repeated-class count.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PatchedCause {
    pub cause: String,
    pub commit: String,
    pub location: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReplyOutcome {
    Applied,
    Skipped,
    Blocked,
    AlreadyFixed,
}

/// A thread the triage answered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Reply {
    pub source_id: String,
    pub commit: String,
    pub outcome: ReplyOutcome,
}

/// A comment's fix, its `commit` kept current by a push's remap.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fix {
    pub description: String,
    pub location: String,
    pub commit: String,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Skip {
    pub description: String,
    pub reason: String,
}

/// The unresolved threads the last triage pass read, so the next one
/// names a thread new only when this list lacks it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Baseline {
    pub last_threads: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IssueOrigin {
    /// Filed by the comment triage.
    Triage,
    /// Filed by the review's audit.
    Audit,
}

/// One entry of the comment triage ledger, tagged by `entry`. An entry
/// carrying a finding's or a cause's own text is read from the file it
/// names, so the text never crosses argv.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "entry", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RecordCommentLedger {
    FrozenCause {
        file: PathBuf,
    },
    PatchedCause {
        file: PathBuf,
    },
    /// One JSON string; a rule the ledger holds is not appended again.
    ProposedRule {
        file: PathBuf,
    },
    Fix {
        file: PathBuf,
    },
    Skip {
        file: PathBuf,
    },
    Reply(Reply),
    Issue {
        id: String,
        origin: IssueOrigin,
    },
    Baseline(Baseline),
}

/// The file's one value as `T`, or `ledger-entry` naming the entry.
fn entry_file<T: DeserializeOwned + Serialize>(entry: &str, file: &Path) -> Result<Value> {
    let value = one_value(file)?;
    let typed: T = serde_json::from_value(value).map_err(|e| {
        refused(
            "ledger-entry",
            &[
                ("entry", entry),
                ("file", &file.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )
    })?;
    Ok(serde_json::to_value(typed)?)
}

pub(crate) fn record_comment_ledger(
    path: &Path,
    doc: &mut Document,
    r: &RecordCommentLedger,
) -> Result<Value> {
    let (entry, pointer, value, unique) = match r {
        RecordCommentLedger::FrozenCause { file } => (
            "frozen-cause",
            "/pr_comment_review/frozen_causes",
            entry_file::<FrozenCause>("frozen-cause", file)?,
            false,
        ),
        RecordCommentLedger::PatchedCause { file } => (
            "patched-cause",
            "/pr_comment_review/patched_causes",
            entry_file::<PatchedCause>("patched-cause", file)?,
            false,
        ),
        RecordCommentLedger::ProposedRule { file } => (
            "proposed-rule",
            "/pr_comment_review/proposed_rules",
            entry_file::<String>("proposed-rule", file)?,
            true,
        ),
        RecordCommentLedger::Fix { file } => (
            "fix",
            "/pr_comment_review/fixes",
            entry_file::<Fix>("fix", file)?,
            false,
        ),
        RecordCommentLedger::Skip { file } => (
            "skip",
            "/pr_comment_review/skipped",
            entry_file::<Skip>("skip", file)?,
            false,
        ),
        RecordCommentLedger::Reply(reply) => (
            "reply",
            "/pr_comment_review/replied",
            serde_json::to_value(reply)?,
            false,
        ),
        RecordCommentLedger::Issue { id, origin } => (
            "issue",
            match origin {
                IssueOrigin::Triage => "/pr_comment_review/issues_created",
                IssueOrigin::Audit => "/audit_issues_created",
            },
            json!(id),
            false,
        ),
        RecordCommentLedger::Baseline(baseline) => {
            let value = serde_json::to_value(baseline)?;
            record::set(doc, "pr_review_baseline", value.clone());
            return Ok(
                json!({"entry": "baseline", "pointer": "/pr_review_baseline", "value": value}),
            );
        }
    };
    let items = array_at(path, doc, pointer)?;
    let appended = !(unique && items.contains(&value));
    if appended {
        items.push(value.clone());
    }
    Ok(json!({
        "entry": entry,
        "pointer": pointer,
        "value": value,
        "length": items.len(),
        "appended": appended,
    }))
}

/// Rewrite the `commit` of every fixed item and comment fix through one
/// rewrite's hop: the moved count of each, in that order.
pub(crate) fn remap_commits(doc: &mut Document, hop: &Hop) -> (usize, usize) {
    let remap = |items: &mut Vec<Value>| -> usize {
        let mut moved = 0;
        for item in items.iter_mut() {
            if let Some(commit) = item.get("commit").and_then(Value::as_str)
                && !commit.is_empty()
            {
                let mapped = proof::remap(commit, hop);
                if mapped != commit {
                    item["commit"] = json!(mapped);
                    moved += 1;
                }
            }
        }
        moved
    };
    let mut fixed: Vec<Value> = match doc.get("fixed_items") {
        Some(Value::Array(items)) => items.clone(),
        _ => Vec::new(),
    };
    let mut review = match doc.get("pr_comment_review") {
        Some(Value::Object(map)) => map.clone(),
        _ => Map::new(),
    };
    let mut fixes: Vec<Value> = match review.get("fixes") {
        Some(Value::Array(items)) => items.clone(),
        _ => Vec::new(),
    };
    let moved = (remap(&mut fixed), remap(&mut fixes));
    record::set(doc, "fixed_items", Value::Array(fixed));
    review.insert("fixes".into(), Value::Array(fixes));
    record::set(doc, "pr_comment_review", Value::Object(review));
    moved
}

// ---------------------------------------------------------------------------
// The checks a pointer write into these fields is held to
// ---------------------------------------------------------------------------

/// The elements of `now` that `was` does not hold: a check judges what a
/// write added, so an entry an earlier shape left keeps loading.
pub(super) fn added_entries<'a>(
    was: Option<&Value>,
    now: &'a Value,
) -> std::result::Result<Vec<&'a Value>, String> {
    let Value::Array(items) = now else {
        return Err("not an array".into());
    };
    let before: &[Value] = match was {
        Some(Value::Array(items)) => items,
        _ => &[],
    };
    Ok(items.iter().filter(|i| !before.contains(i)).collect())
}

fn each_added<T: DeserializeOwned>(
    was: Option<&Value>,
    now: &Value,
) -> std::result::Result<(), String> {
    for item in added_entries(was, now)? {
        serde_json::from_value::<T>(item.clone()).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// A disposition array: each added entry names its description and location.
pub(crate) fn check_bucket(was: Option<&Value>, now: &Value) -> std::result::Result<(), String> {
    each_added::<Finding>(was, now)
}

pub(crate) fn check_issues(was: Option<&Value>, now: &Value) -> std::result::Result<(), String> {
    each_added::<String>(was, now)
}

pub(crate) fn check_baseline(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<Option<Baseline>>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}

/// The ledger object: each array it holds takes only its entry's shape, and
/// the triage count is a whole number.
pub(crate) fn check_ledger(was: Option<&Value>, now: &Value) -> std::result::Result<(), String> {
    let Value::Object(ledger) = now else {
        return Err("not an object".into());
    };
    let before = was.and_then(Value::as_object);
    let prior = |key: &str| before.and_then(|b| b.get(key));
    for (key, value) in ledger {
        if prior(key) == Some(value) {
            continue;
        }
        let checked = match key.as_str() {
            "iterations" => serde_json::from_value::<u64>(value.clone())
                .map(drop)
                .map_err(|e| e.to_string()),
            "frozen_causes" => each_added::<FrozenCause>(prior(key), value),
            "patched_causes" => each_added::<PatchedCause>(prior(key), value),
            "proposed_rules" | "issues_created" => each_added::<String>(prior(key), value),
            "replied" => each_added::<Reply>(prior(key), value),
            "fixes" => each_added::<Fix>(prior(key), value),
            "skipped" => each_added::<Skip>(prior(key), value),
            _ => Ok(()),
        };
        checked.map_err(|cause| format!("{key}: {cause}"))?;
    }
    Ok(())
}
