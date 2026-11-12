//! A reviewer's on-disk artifact, checked for review acceptance: found by
//! its path or by its agent's name under `tmp/`, fresh against the
//! delegation boundary, one JSON object with a verdict, and usable by every
//! content gate. The answer is one result object; a check that cannot judge
//! refuses with a keyed line instead.
//!
//! The artifact is read once and every gate judges that one parsed value, so
//! no gate can fail apart from the parse. In glob mode only a stale file and
//! the verdict step (unparsable, no verdict) let an older sibling answer:
//! every other rejection is the artifact's own report on this run.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::clock;
use clap::{Args, Subcommand};
use serde_json::{Value, json};

use super::artifact::Answer;
use super::store;
use crate::error::{Error, Result};
use crate::settings;
use crate::state;
use agent_runtime::clock::Clock;

#[derive(Debug, Subcommand)]
pub enum ReviewArtifact {
    /// Create `tmp/` and print the artifact path an agent writes to.
    Path(MintPath),
    /// Check one artifact (`--file`) or an agent's newest (`--agent`).
    Check(CheckArtifact),
}

#[derive(Debug, Args)]
pub struct MintPath {
    #[arg(long)]
    pub worktree: PathBuf,
    #[arg(long)]
    pub agent: String,
}

#[derive(Debug, Args)]
pub struct CheckArtifact {
    #[arg(long)]
    pub worktree: PathBuf,
    #[arg(
        long,
        conflicts_with = "file",
        required_unless_present = "file",
        requires = "delegated_at"
    )]
    pub agent: Option<String>,
    #[arg(long)]
    pub file: Option<PathBuf>,
    /// Epoch seconds: an artifact modified before it belongs to an earlier
    /// round.
    #[arg(long)]
    pub delegated_at: Option<u64>,
    /// Seconds to poll for a fresh artifact (glob mode).
    #[arg(long, default_value_t = 0, conflicts_with = "file")]
    pub wait: u64,
    #[arg(long, default_value_t = 5, value_parser = clap::value_parser!(u64).range(1..), conflicts_with = "file")]
    pub interval: u64,
    /// The item whose `declined_items` an accepted artifact's findings are
    /// matched against by location.
    #[arg(long)]
    pub issue: Option<String>,
}

const DECLARATION_BAR: &str = "a declaration must name the instrument and what it did — at least 20 characters and 3 words, not a null token (n/a, none, unknown, ...) or bare punctuation";

const ZERO_SAMPLE_REMEDY: &str = "a measurement that produced no samples, or whose measuring pipeline exited nonzero, is instrument failure, not a result. If the instrument was YOURS, keep the evidence and declare it: set the TOP-LEVEL measurement_failed to a string naming the instrument and what it did. If you are QUOTING someone else's zeroed run, put it in the blocker or suggestion it belongs to — only the summary and qa_metadata count as your own measurement.";

fn refuse(key: &'static str, cause: String) -> Error {
    Error::Artifact { key, cause }
}

fn worktree_dir(worktree: &Path) -> Result<()> {
    match fs::metadata(worktree) {
        Ok(m) if m.is_dir() => Ok(()),
        _ => Err(refuse(
            "worktree",
            format!(
                "path={}\nThe worktree must be a directory.",
                worktree.display()
            ),
        )),
    }
}

fn agent(name: &str) -> Result<()> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return Err(refuse(
            "agent",
            format!("value={name}\nUse a nonempty agent name with path-safe characters."),
        ));
    }
    Ok(())
}

#[allow(
    clippy::disallowed_methods,
    reason = "path mode creates the worktree's own tmp/ the reviewer writes its artifact under and reads the wall clock for its name, as the check's one write"
)]
pub fn path(r: &MintPath, clock: &dyn Clock) -> Result<Answer> {
    worktree_dir(&r.worktree)?;
    agent(&r.agent)?;
    let tmp = r.worktree.join("tmp");
    fs::create_dir_all(&tmp).map_err(|e| refuse("path", format!("path={} {e}", tmp.display())))?;
    let secs = clock
        .wall()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    // `YYYY-MM-DDTHH:MM:SSZ` becomes `YYYYMMDD-HHMMSS`.
    let stamp: String = clock::iso_utc(secs)
        .chars()
        .filter_map(|c| match c {
            '-' | ':' | 'Z' => None,
            'T' => Some('-'),
            c => Some(c),
        })
        .collect();
    let path = tmp.join(format!("review-{}-{stamp}.json", r.agent));
    Ok(Answer {
        value: json!({ "path": path }),
        text: path.display().to_string(),
        status: 0,
    })
}

/// The item records' directory by its one key, as `workflow-state` resolves
/// it: the `--state-dir` flag, else the caller's `ORCH_STATE_DIR`, else the
/// checkout's settings files and private env file, else `tmp`; a relative
/// directory joins the common root. No other setting is read, so no other
/// key can refuse the check; a directory that cannot be resolved refuses as
/// its record would.
pub fn state_dir(
    issue: &str,
    worktree: &Path,
    flag: Option<&Path>,
    caller: Option<&str>,
) -> Result<PathBuf> {
    let roots = agent_runtime::settings::roots(worktree).map_err(|_| unread_state(issue))?;
    let dir = match (flag, caller.filter(|v| !v.is_empty())) {
        (Some(dir), _) => dir.to_path_buf(),
        (None, Some(dir)) => PathBuf::from(dir),
        (None, None) => settings::state_dir_named(&roots.project, &|p: &Path| {
            agent_runtime::settings::read_text(p)
        })
        .map_err(|_| unread_state(issue))?,
    };
    Ok(if dir.is_absolute() {
        dir
    } else {
        roots.common.join(dir)
    })
}

fn unread_state(issue: &str) -> Error {
    refuse(
        "declined_state",
        format!(
            "issue={issue}\nThe item record's declined_items could not be read, so no finding can be judged a repeat. Refusing rather than reporting every finding as new."
        ),
    )
}

/// One recorded decline, as a repeat carries it.
#[derive(Debug, Clone)]
struct Declined {
    location: Value,
    description: Value,
    reason: Value,
}

#[allow(
    clippy::disallowed_methods,
    reason = "the review check's one read of the item record, for its declined items, before any artifact"
)]
fn declined(dir: &Path, issue: &str) -> Result<Vec<Declined>> {
    let unread = || unread_state(issue);
    let path = state::item_path(dir, issue);
    let snapshot = state::load(&path)
        .map_err(|_| unread())?
        .ok_or_else(unread)?;
    let entries: Vec<&Value> = match snapshot.doc.get("declined_items") {
        None | Some(Value::Null | Value::Bool(false)) => Vec::new(),
        Some(Value::Array(items)) => items.iter().collect(),
        Some(Value::Object(items)) => items.values().collect(),
        Some(_) => return Err(unread()),
    };
    entries
        .into_iter()
        .map(|entry| match entry {
            Value::Null => Ok(Declined {
                location: Value::Null,
                description: Value::Null,
                reason: Value::Null,
            }),
            Value::Object(fields) => {
                let get = |k: &str| fields.get(k).cloned().unwrap_or(Value::Null);
                Ok(Declined {
                    location: get("location"),
                    description: get("description"),
                    reason: get("reason"),
                })
            }
            _ => Err(unread()),
        })
        .collect()
}

/// A rejection's reason word and its detail, the detail's first line keyed.
#[derive(Debug, Clone, PartialEq)]
struct Finding {
    reason: &'static str,
    detail: String,
}

fn finding(reason: &'static str, detail: impl Into<String>) -> Finding {
    Finding {
        reason,
        detail: detail.into(),
    }
}

/// One artifact as read.
#[derive(Debug)]
enum Read {
    /// Older than the boundary: an older sibling may answer.
    Stale(Finding),
    /// The verdict step failed (not JSON, no verdict): the write may be
    /// torn, so an older sibling may answer.
    Unread(Finding),
    /// The artifact's own report on this run: no sibling answers it.
    Rejected(Finding),
    Accepted {
        artifact: Value,
        declared: Option<String>,
        suppressed: Option<String>,
    },
}

#[allow(
    clippy::disallowed_methods,
    reason = "an artifact's modification time against the delegation boundary, read from its metadata; no clock is read"
)]
fn mtime(path: &Path, meta: &fs::Metadata) -> Result<u64> {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .ok_or_else(|| {
            refuse(
                "mtime",
                format!(
                    "path={}\nThe artifact timestamp could not be read, so its freshness is unknown. Refusing rather than judging it against the boundary.",
                    path.display()
                ),
            )
        })
}

fn read(path: &Path, meta: &fs::Metadata, boundary: Option<u64>, worktree: &Path) -> Result<Read> {
    if let Some(boundary) = boundary {
        let mtime = mtime(path, meta)?;
        if mtime < boundary {
            return Ok(Read::Stale(finding(
                "stale",
                format!(
                    "review-artifact-check: stale mtime={mtime} delegated_at={boundary}\nThe artifact belongs to an earlier round."
                ),
            )));
        }
    }
    let unparsable = |cause: String| {
        Read::Unread(finding(
            "invalid",
            format!(
                "review-artifact-check: unparsable path={}\n{cause}",
                path.display()
            ),
        ))
    };
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) => return Ok(unparsable(e.to_string())),
    };
    let mut values = Vec::new();
    for value in serde_json::Deserializer::from_slice(&bytes).into_iter::<Value>() {
        match value {
            Ok(value) => values.push(value),
            Err(e) => return Ok(unparsable(e.to_string())),
        }
    }
    let artifact = match values.len() {
        0 => return Ok(unparsable("The file holds no JSON value.".to_owned())),
        1 => values.remove(0),
        count => {
            return Ok(Read::Rejected(finding(
                "invalid",
                format!(
                    "review-artifact-check: value_count count={count}\nAn artifact must hold exactly one JSON object."
                ),
            )));
        }
    };
    if matches!(
        artifact.get("verdict"),
        None | Some(Value::Null | Value::Bool(false))
    ) {
        return Ok(Read::Unread(finding(
            "invalid",
            "review-artifact-check: verdict field=verdict state=missing_or_null\nEvery review artifact must carry verdict: pass or action_required.",
        )));
    }
    Ok(gates(artifact, worktree))
}

fn type_word(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn json_word(v: Option<&Value>) -> String {
    serde_json::to_string(v.unwrap_or(&Value::Null)).unwrap_or_default()
}

/// A string's own text, any other value's compact JSON: the text a reason or a category is read as.
fn to_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

/// `.qa_metadata // {}`: absent, null and false read as no metadata.
fn qa(artifact: &Value) -> Option<&Value> {
    artifact
        .get("qa_metadata")
        .filter(|v| !matches!(v, Value::Null | Value::Bool(false)))
}

fn qa_object(artifact: &Value) -> bool {
    matches!(artifact.get("qa_metadata"), Some(Value::Object(_)))
}

fn gates(artifact: Value, worktree: &Path) -> Read {
    let head = match store::git_head(worktree) {
        Ok(head) => head,
        Err(_) => {
            return Read::Rejected(finding(
                "invalid",
                format!(
                    "review-artifact-check: head_read worktree={}",
                    worktree.display()
                ),
            ));
        }
    };
    let rejected = moving_tree(&artifact, &head)
        .map(|d| finding("moving_tree", d))
        .or_else(|| no_review(&artifact).map(|d| finding("no_review", d)))
        .or_else(|| finding_arrays(&artifact).map(|d| finding("incomplete", d)))
        .or_else(|| finding_item(&artifact).map(|d| finding("incomplete", d)))
        .or_else(|| test_cost(&artifact).map(|d| finding("incomplete", d)));
    if let Some(rejected) = rejected {
        return Read::Rejected(rejected);
    }
    let declared = match declaration(&artifact) {
        Declaration::Absent => None,
        Declaration::Invalid(detail) => {
            return Read::Rejected(finding(
                "invalid_declaration",
                format!("{detail}\n{DECLARATION_BAR}"),
            ));
        }
        Declaration::Declared(text) => Some(text),
    };
    let zero = zero_sample(&artifact);
    if let (Some(zero), None) = (&zero, &declared) {
        return Read::Rejected(finding(
            "zero_sample",
            format!("{zero}\n{ZERO_SAMPLE_REMEDY}"),
        ));
    }
    Read::Accepted {
        artifact,
        suppressed: zero.filter(|_| declared.is_some()),
        declared,
    }
}

fn moving_tree(artifact: &Value, head: &str) -> Option<String> {
    let reviewed = artifact.get("head");
    let dirty = artifact.get("dirty_paths");
    if reviewed == Some(&Value::String(head.to_owned())) && dirty == Some(&json!([])) {
        return None;
    }
    Some(format!(
        "review-artifact-check: moving_tree head={} expected={head} dirty_paths={}\nRepeat the review after development finishes.",
        json_word(reviewed),
        json_word(dirty)
    ))
}

/// `no[ _-]?(scope|review)|not[ _-]?reviewed`, case-blind, anywhere.
fn admits_no_review(text: &str) -> bool {
    fn sep(s: &str) -> &str {
        s.strip_prefix([' ', '_', '-']).unwrap_or(s)
    }
    let t = text.to_ascii_lowercase();
    (0..t.len()).filter(|&i| t.is_char_boundary(i)).any(|i| {
        let at = &t[i..];
        at.strip_prefix("not")
            .is_some_and(|rest| rest.starts_with("reviewed") || sep(rest).starts_with("reviewed"))
            || at.strip_prefix("no").is_some_and(|rest| {
                [rest, sep(rest)]
                    .iter()
                    .any(|r| r.starts_with("scope") || r.starts_with("review"))
            })
    })
}

fn no_review(artifact: &Value) -> Option<String> {
    let qa = qa(artifact)?.as_object()?;
    if qa.get("review_performed") == Some(&Value::Bool(false)) {
        return Some("review-artifact-check: no_review review_performed=false\nThe artifact states that no review happened.".to_owned());
    }
    let reason = qa
        .get("reason")
        .filter(|v| !matches!(v, Value::Null | Value::Bool(false)));
    if admits_no_review(&reason.map(to_text).unwrap_or_default()) {
        return Some(format!(
            "review-artifact-check: no_review review_reason={}\nThe reason states that no review happened.",
            json_word(reason)
        ));
    }
    None
}

fn finding_arrays(artifact: &Value) -> Option<String> {
    if !qa_object(artifact) {
        return None;
    }
    let bad: Vec<String> = ["blockers", "suggestions"]
        .into_iter()
        .filter_map(|k| match artifact.get(k) {
            None => Some(format!("{k}=absent")),
            Some(Value::Array(_)) => None,
            Some(v) => Some(format!("{k}={}", type_word(v))),
        })
        .collect();
    if bad.is_empty() {
        return None;
    }
    Some(format!(
        "review-artifact-check: finding_arrays {}\nDeclaring qa_metadata commits the artifact to both finding arrays, empty ones included: a review with nothing to say writes []. An artifact with no qa_metadata does not have to carry them.",
        bad.join(" ")
    ))
}

const ITEM_FIELDS: [&str; 7] = [
    "id",
    "title",
    "location",
    "description",
    "recommendation",
    "priority",
    "estimate",
];

fn item_problems(suggestion: bool, item: &Value) -> (Vec<&'static str>, Vec<String>) {
    let fields = item.as_object();
    let issue = suggestion && fields.is_some_and(|f| f.get("category") == Some(&json!("issue")));
    let mut required: Vec<&'static str> = ITEM_FIELDS.to_vec();
    if suggestion {
        required.push("category");
    }
    if issue {
        required.push("impact");
    }
    let present = |k: &str| fields.and_then(|f| f.get(k)).filter(|v| !v.is_null());
    let missing: Vec<&'static str> = required
        .into_iter()
        .filter(|k| present(k).is_none())
        .collect();
    let mut invalid = Vec::new();
    let Some(fields) = fields else {
        return (missing, invalid);
    };
    if suggestion
        && let Some(category) = present("category")
        && !matches!(to_text(category).as_str(), "fix" | "issue")
    {
        invalid.push("category:enum".to_owned());
    }
    if issue
        && let Some(impact) = present("impact")
        && !impact
            .as_str()
            .is_some_and(|s| s.chars().any(|c| !c.is_whitespace()))
    {
        invalid.push("impact:blank".to_owned());
    }
    for (field, low, high) in [("priority", 1_u8, 4_u8), ("estimate", 1, 5)] {
        if let Some(v) = fields.get(field).filter(|v| !v.is_null())
            && !v
                .as_f64()
                .is_some_and(|n| (f64::from(low)..=f64::from(high)).contains(&n))
        {
            invalid.push(format!("{field}:range[{low},{high}]"));
        }
    }
    (missing, invalid)
}

fn finding_item(artifact: &Value) -> Option<String> {
    if !qa_object(artifact) {
        return None;
    }
    ["blockers", "suggestions"].into_iter().find_map(|array| {
        let items = artifact.get(array)?.as_array()?;
        items.iter().enumerate().find_map(|(i, item)| {
            let (missing, invalid) = item_problems(array == "suggestions", item);
            if missing.is_empty() && invalid.is_empty() {
                return None;
            }
            Some(format!(
                "review-artifact-check: finding_item path={array}[{i}] missing={} invalid={}\nEvery blockers[]/suggestions[] item requires: id, title, location (path plus symbol, no line numbers), description, recommendation, priority (integer 1-4), estimate (1-5); suggestions also category (fix|issue), and category:issue also impact (who hits this, on what real path)",
                missing.join(","),
                invalid.join(",")
            ))
        })
    })
}

const TEST_FORM: &str = "Every tests[] entry names its test and a verdict of keep, add or remove; a kept or added test also states in cost what each run of it costs.";

/// The first `tests[]` entry that keeps or adds a test without its cost.
/// An artifact that lists no test is not judged: only the reviewer can name
/// the tests it kept, so a verdict outside the three is refused rather than
/// read as one that needs no cost.
fn test_cost(artifact: &Value) -> Option<String> {
    let entries = match artifact.get("tests") {
        None | Some(Value::Null) => return None,
        Some(Value::Array(entries)) => entries,
        Some(other) => {
            return Some(format!(
                "review-artifact-check: test_cost field=tests type={}\n{TEST_FORM}",
                type_word(other)
            ));
        }
    };
    entries.iter().enumerate().find_map(|(i, entry)| {
        let costed = entry
            .get("cost")
            .and_then(Value::as_str)
            .is_some_and(|s| s.chars().any(|c| !c.is_whitespace()));
        let problem = match entry.get("verdict").and_then(Value::as_str) {
            Some("remove") => None,
            Some("keep" | "add") if !costed => Some("missing=cost"),
            Some("keep" | "add") => None,
            _ => Some("invalid=verdict"),
        }?;
        Some(format!(
            "review-artifact-check: test_cost path=tests[{i}] test={} {problem}\n{TEST_FORM}",
            json_word(entry.get("test"))
        ))
    })
}

enum Declaration {
    Absent,
    Invalid(String),
    Declared(String),
}

const NULL_TOKENS: [&str; 13] = [
    "na",
    "n/a",
    "none",
    "null",
    "nil",
    "nothing",
    "unknown",
    "unavailable",
    "tbd",
    "failed",
    "error",
    "yes",
    "no",
];

fn declaration(artifact: &Value) -> Declaration {
    let invalid = |what: String| {
        Declaration::Invalid(format!(
            "review-artifact-check: measurement_declaration {what}"
        ))
    };
    let text = match artifact.get("measurement_failed") {
        None | Some(Value::Null) => return Declaration::Absent,
        Some(Value::String(text)) => text.trim(),
        Some(other) => {
            return invalid(format!(
                "type={}\nmeasurement_failed must be a string.",
                type_word(other)
            ));
        }
    };
    let words = text
        .split_whitespace()
        .filter(|w| {
            w.as_bytes()
                .windows(2)
                .any(|p| p.iter().all(u8::is_ascii_alphanumeric))
        })
        .count();
    let length = text.chars().count();
    if length == 0 {
        invalid("state=blank\nName the instrument and what it did.".to_owned())
    } else if NULL_TOKENS.contains(&text.to_ascii_lowercase().trim_end_matches(['.', '!'])) {
        invalid(format!(
            "state=null_token value={}\nThe token names no instrument.",
            json_word(Some(&json!(text)))
        ))
    } else if !text.bytes().any(|b| b.is_ascii_alphabetic()) {
        invalid("state=punctuation\nPunctuation names no instrument.".to_owned())
    } else if length < 20 {
        invalid(format!(
            "characters={length} minimum=20\nName the instrument and what it did."
        ))
    } else if words < 3 {
        invalid(format!(
            "words={words} minimum=3\nName the instrument and what it did."
        ))
    } else {
        Declaration::Declared(text.to_owned())
    }
}

/// The strings an artifact states its own measurements in: `.summary` and
/// every string under `.qa_metadata`, depth first in document order.
fn carriers(artifact: &Value) -> Vec<&str> {
    fn strings<'a>(v: &'a Value, out: &mut Vec<&'a str>) {
        match v {
            Value::String(s) => out.push(s),
            Value::Array(items) => items.iter().for_each(|v| strings(v, out)),
            Value::Object(fields) => fields.values().for_each(|v| strings(v, out)),
            _ => {}
        }
    }
    let mut out: Vec<&str> = artifact
        .get("summary")
        .and_then(Value::as_str)
        .into_iter()
        .collect();
    if let Some(qa) = qa(artifact) {
        strings(qa, &mut out);
    }
    out
}

struct Cite {
    kind: &'static str,
    label: String,
    zero_samples: bool,
    zero_threads: bool,
}

fn skip_space(s: &str) -> &str {
    s.trim_start_matches(char::is_whitespace)
}

fn leading_digits(s: &str) -> Option<(&str, &str)> {
    let end = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
    (end > 0).then(|| s.split_at(end))
}

fn strip_ci<'a>(s: &'a str, word: &str) -> Option<&'a str> {
    s.get(..word.len())
        .filter(|head| head.eq_ignore_ascii_case(word))
        .map(|_| &s[word.len()..])
}

/// `X\s*/\s*Y` after a citation's keyword: the two counts and the rest.
fn ratio(s: &str) -> Option<(&str, &str, &str)> {
    let (x, rest) = leading_digits(skip_space(s))?;
    let rest = skip_space(rest).strip_prefix('/')?;
    let (y, rest) = leading_digits(skip_space(rest))?;
    Some((x, y, rest))
}

/// Every `keyword ratio` match of one text, left to right without overlap,
/// each with the text after it.
fn scan<'a>(text: &'a str, keyword: &str) -> Vec<(&'a str, &'a str, &'a str)> {
    let mut found = Vec::new();
    let mut i = 0;
    while i < text.len() {
        if text.is_char_boundary(i)
            && let Some(rest) = strip_ci(&text[i..], keyword)
            && let Some(hit) = ratio(rest)
        {
            found.push(hit);
            i = text.len() - hit.2.len();
            continue;
        }
        i += 1;
    }
    found
}

fn all_zero(n: &str) -> bool {
    n.bytes().all(|b| b == b'0')
}

fn cites(text: &str) -> Vec<Cite> {
    let mut out: Vec<Cite> = scan(text, "killed")
        .into_iter()
        .map(|(x, y, _)| Cite {
            kind: "mutation",
            label: format!("killed {x}/{y}"),
            zero_samples: all_zero(y),
            zero_threads: false,
        })
        .collect();
    out.extend(scan(text, "stability:").into_iter().map(|(x, y, rest)| {
        let threads = strip_ci(skip_space(rest), "at")
            .and_then(|r| leading_digits(skip_space(r)))
            .filter(|(_, after)| strip_ci(skip_space(after), "thread").is_some())
            .map(|(t, _)| t);
        Cite {
            kind: "stability",
            label: format!("stability: {x}/{y}"),
            zero_samples: all_zero(y),
            zero_threads: threads.is_some_and(all_zero),
        }
    }));
    out
}

fn evidence_zero(field: &str, name: &str, v: Option<&Value>) -> Option<String> {
    fn positive(v: &Value) -> bool {
        match v {
            Value::Number(n) => n.as_f64().is_some_and(|n| n > 0.0),
            Value::Array(items) => items.iter().any(positive),
            Value::Object(fields) => fields.values().any(positive),
            _ => false,
        }
    }
    let at = format!("review-artifact-check: perf_evidence field=qa_metadata.perf_qa.{field}");
    match v {
        None | Some(Value::Null) => Some(format!(
            "{at} state=missing\nThe benchmark payload requires {name}."
        )),
        Some(v @ (Value::Array(_) | Value::Object(_))) => {
            let empty = v.as_array().map_or_else(
                || v.as_object().is_some_and(|o| o.is_empty()),
                Vec::is_empty,
            );
            if empty {
                Some(format!(
                    "{at} count=0\nThe {name} must contain measurements."
                ))
            } else if !positive(v) {
                Some(format!(
                    "{at} positive_values=0\nThe {name} must contain a measured value above zero."
                ))
            } else {
                None
            }
        }
        Some(v) => Some(format!(
            "{at} type={}\nThe {name} must be an object or an array.",
            type_word(v)
        )),
    }
}

fn measure_zero(pq: &serde_json::Map<String, Value>) -> Option<String> {
    let at = "review-artifact-check: perf_evidence field=qa_metadata.perf_qa";
    let named = ["name", "unit"].into_iter().find_map(|f| {
        let v = pq.get(f);
        let ok = v
            .and_then(Value::as_str)
            .is_some_and(|s| s.chars().any(|c| !c.is_whitespace()));
        (!ok).then(|| {
            format!(
                "{at}.{f} value={}\nA measure names its {f} in a non-blank string.",
                json_word(v)
            )
        })
    });
    let samples = pq.get("samples");
    let counted = || {
        (!samples.and_then(Value::as_f64).is_some_and(|n| n > 0.0)).then(|| {
            format!(
                "{at}.samples value={}\nA measure records how many samples produced its values, above zero.",
                json_word(samples)
            )
        })
    };
    let valued = || {
        (!pq.get("values")
            .and_then(Value::as_object)
            .is_some_and(|o| o.values().any(Value::is_number)))
        .then(|| format!("{at}.values numeric_values=0\nA measure records its result as an object of numbers."))
    };
    named.or_else(counted).or_else(valued)
}

fn perf(artifact: &Value) -> Option<String> {
    let pq = match qa(artifact)? {
        Value::Object(qa) => qa
            .get("perf_qa")
            .filter(|v| !matches!(v, Value::Null | Value::Bool(false)))?,
        _ => return None,
    };
    let Value::Object(pq) = pq else {
        return Some(format!(
            "review-artifact-check: perf_evidence field=qa_metadata.perf_qa type={}\nThe benchmark payload must be an object.",
            type_word(pq)
        ));
    };
    let kinds =
        "metric_kind must be \"latency\", \"instruction_count\", \"process_count\" or \"measure\".";
    match pq.get("metric_kind").unwrap_or(&Value::Null) {
        Value::Null => evidence_zero("percentiles", "percentiles", pq.get("percentiles")),
        Value::String(kind) => match kind.as_str() {
            "latency" => evidence_zero("percentiles", "percentiles", pq.get("percentiles")),
            "instruction_count" => evidence_zero(
                "instruction_counts",
                "instruction counts",
                pq.get("instruction_counts"),
            ),
            "process_count" => {
                evidence_zero("process_counts", "process counts", pq.get("process_counts"))
            }
            "measure" => measure_zero(pq),
            _ => Some(format!(
                "review-artifact-check: perf_evidence field=qa_metadata.perf_qa.metric_kind value={}\n{kinds}",
                json_word(Some(&json!(kind)))
            )),
        },
        other => Some(format!(
            "review-artifact-check: perf_evidence field=qa_metadata.perf_qa.metric_kind type={}\n{kinds}",
            type_word(other)
        )),
    }
}

/// The first measurement that produced nothing: a citation with no
/// samples, then one at no threads, then the perf payload. A zero result
/// over counted samples (`stability: 0/10`) is a finding, never this.
fn zero_sample(artifact: &Value) -> Option<String> {
    let cites: Vec<Cite> = carriers(artifact).into_iter().flat_map(cites).collect();
    cites
        .iter()
        .find(|c| c.zero_samples)
        .map(|c| {
            format!(
                "review-artifact-check: zero_sample measurement={} samples=0\nThe citation \"{}\" reports no samples.",
                c.kind, c.label
            )
        })
        .or_else(|| {
            cites.iter().find(|c| c.zero_threads).map(|c| {
                format!(
                    "review-artifact-check: zero_sample measurement=stability threads=0\nThe citation \"{}\" reports no threads.",
                    c.label
                )
            })
        })
        .or_else(|| perf(artifact))
}

/// A check's answer before it is printed: the file it names, the outcome,
/// and the accepted artifact with its declaration.
struct Outcome {
    path: Option<PathBuf>,
    read: Option<Read>,
    missing: Option<String>,
}

fn repeats(artifact: &Value, declined: &[Declined]) -> Value {
    let mut out = Vec::new();
    for array in ["blockers", "suggestions"] {
        let Some(items) = artifact.get(array).and_then(Value::as_array) else {
            continue;
        };
        for (index, item) in items.iter().enumerate() {
            let Some(fields) = item.as_object() else {
                continue;
            };
            let location = fields.get("location").cloned().unwrap_or(Value::Null);
            let hits: Vec<Value> = declined
                .iter()
                .filter(|d| d.location == location)
                .map(|d| json!({"description": d.description, "reason": d.reason}))
                .collect();
            if !hits.is_empty() {
                out.push(
                    json!({"array": array, "index": index, "location": location, "declined": hits}),
                );
            }
        }
    }
    Value::Array(out)
}

fn answer(outcome: Outcome, declined: Option<&[Declined]>) -> Answer {
    let (ok, reason, detail, declared, suppressed, artifact) = match outcome.read {
        Some(Read::Accepted {
            artifact,
            declared,
            suppressed,
        }) => {
            let reason = if declared.is_some() {
                "valid_undermeasured"
            } else {
                "valid"
            };
            (true, reason, None, declared, suppressed, Some(artifact))
        }
        Some(Read::Stale(f) | Read::Unread(f) | Read::Rejected(f)) => {
            (false, f.reason, Some(f.detail), None, None, None)
        }
        None => (false, "missing", outcome.missing, None, None, None),
    };
    let mut value = json!({"ok": ok, "path": outcome.path, "reason": reason});
    if let Some(detail) = detail {
        value["detail"] = json!(detail);
    }
    if let Some(declared) = declared {
        value["measurement_failed"] = json!(declared);
    }
    if let Some(suppressed) = suppressed {
        value["measurement_suppressed"] = json!(suppressed);
    }
    if let (Some(declined), Some(artifact)) = (declined, &artifact) {
        value["repeats"] = repeats(artifact, declined);
    }
    Answer {
        text: value.to_string(),
        value,
        status: i32::from(!ok),
    }
}

fn file_once(file: &Path, r: &CheckArtifact) -> Result<Outcome> {
    let meta = match fs::metadata(file) {
        Ok(meta) if meta.is_file() => meta,
        _ => {
            return Ok(Outcome {
                path: None,
                read: None,
                missing: Some(format!(
                    "review-artifact-check: missing path={}\nNo artifact exists at this path.",
                    file.display()
                )),
            });
        }
    };
    Ok(Outcome {
        path: Some(file.to_path_buf()),
        read: Some(read(file, &meta, r.delegated_at, &r.worktree)?),
        missing: None,
    })
}

/// The agent's artifacts under `tmp/`, newest first; an unreadable
/// directory lists none, as the glob over it matched none.
fn agent_artifacts(tmp: &Path, agent: &str) -> Vec<(PathBuf, fs::Metadata)> {
    let prefix = format!("review-{agent}-");
    let mut found: Vec<(PathBuf, fs::Metadata)> = fs::read_dir(tmp)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            e.file_name()
                .to_str()
                .is_some_and(|n| n.starts_with(&prefix) && n.ends_with(".json"))
        })
        .filter_map(|e| Some((e.path(), fs::metadata(e.path()).ok()?)))
        .collect();
    found.sort_by(|(a, am), (b, bm)| {
        bm.modified()
            .ok()
            .cmp(&am.modified().ok())
            .then_with(|| a.cmp(b))
    });
    found
}

fn glob_once(agent: &str, delegated_at: u64, worktree: &Path) -> Result<Outcome> {
    let tmp = worktree.join("tmp");
    let mut first: Option<Outcome> = None;
    for (path, meta) in agent_artifacts(&tmp, agent) {
        let read = read(&path, &meta, Some(delegated_at), worktree)?;
        match read {
            Read::Stale(_) | Read::Unread(_) => {
                if first.is_none() {
                    first = Some(Outcome {
                        path: Some(path),
                        read: Some(read),
                        missing: None,
                    });
                }
            }
            Read::Rejected(_) | Read::Accepted { .. } => {
                return Ok(Outcome {
                    path: Some(path),
                    read: Some(read),
                    missing: None,
                });
            }
        }
    }
    Ok(first.unwrap_or_else(|| Outcome {
        path: None,
        read: None,
        missing: Some(format!(
            "review-artifact-check: missing_glob pattern={}/review-{agent}-*.json\nNo artifact matches this pattern.",
            tmp.display()
        )),
    }))
}

/// Check the artifact. `state` is the item and its state directory when
/// `--issue` was given: its declined items are read once, before any
/// artifact. A glob-mode wait polls on `clock` while no fresh artifact
/// landed, reads a fresh rejection once more after one interval in case the
/// write was mid-way, and returns the last answer at its deadline.
#[allow(
    clippy::disallowed_methods,
    reason = "the artifact wait owns its one injected deadline and bounded polls"
)]
pub fn check_review(
    r: &CheckArtifact,
    state: Option<(&str, &Path)>,
    clock: &dyn Clock,
) -> Result<Answer> {
    let declined = state.map(|(issue, dir)| declined(dir, issue)).transpose()?;
    let declined = declined.as_deref();
    let (agent_name, delegated_at) = match (&r.file, &r.agent, r.delegated_at) {
        (Some(file), _, _) => return Ok(answer(file_once(file, r)?, declined)),
        (None, Some(agent_name), Some(delegated_at)) => (agent_name, delegated_at),
        _ => {
            return Err(refuse(
                "usage",
                "--file, or --agent with --delegated-at".to_owned(),
            ));
        }
    };
    worktree_dir(&r.worktree)?;
    agent(agent_name)?;
    let began = clock.now();
    let mut confirming = false;
    loop {
        let outcome = glob_once(agent_name, delegated_at, &r.worktree)?;
        let elapsed = clock.now().duration_since(began).as_secs();
        let done = elapsed >= r.wait;
        let waiting = matches!(outcome.read, None | Some(Read::Stale(_)));
        if matches!(outcome.read, Some(Read::Accepted { .. })) || done || (!waiting && confirming) {
            return Ok(answer(outcome, declined));
        }
        confirming = !waiting;
        clock.sleep(Duration::from_secs(r.interval.min(r.wait - elapsed)));
    }
}
