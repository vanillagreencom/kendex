//! The state verbs: a workflow's reads of its own record, the pointer writes,
//! and the typed ops the store's rules are (the round caps, the retry budgets,
//! the post-PR stop, the fleet log row, the standing instructions, the handoff
//! record's places). A write is one transition on the document, committed
//! through the state module's write check; a read loads the document and judges
//! it. The verbs take their inputs from argv or a file and run no effect, so
//! none is a `Request`.

use agent_runtime::record::{self, Document, Locking};
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::controller::heal::{self, Heal};
use agent_runtime::controller::model::{self, Check, Place};
use agent_runtime::host;
use serde_json::{Map, Value, json};

use super::{findings, ledger, loaded, progress, reviewers};
use agent_runtime::error::ShapeReason;
use agent_runtime::journal::Env;

use crate::error::{Error, Result};
use crate::settings::StoreSettings;
use crate::state::{self, Kind};
use crate::watch::lanes::{HandoffReading, handoff_places, handoff_read};

const GIT_TIMEOUT: Duration = Duration::from_secs(30);

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

fn shape(path: &Path, field: &str, reason: ShapeReason, cause: impl Into<String>) -> Error {
    Error::Runtime(agent_runtime::Error::RecordShape {
        path: path.to_path_buf(),
        field: field.to_owned(),
        reason,
        cause: cause.into(),
    })
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn text_of(path: &Path) -> String {
    path.display().to_string()
}

// ---------------------------------------------------------------------------
// Pointers and values
// ---------------------------------------------------------------------------

/// The tokens of an RFC 6901 pointer below the root; the root names the
/// whole document, which `get` reads and no write replaces.
fn tokens(pointer: &str) -> Result<Vec<String>> {
    match pointer.strip_prefix('/') {
        Some(rest) => Ok(rest
            .split('/')
            .map(|t| t.replace("~1", "/").replace("~0", "~"))
            .collect()),
        None => Err(refused("pointer-invalid", &[("pointer", pointer)])),
    }
}

/// The value at `pointer`, `null` where nothing stands there, as jq's
/// `.a.b` reads an absent key; the whole document for the empty pointer.
pub fn get(doc: &Document, pointer: &str) -> Result<Value> {
    if pointer.is_empty() {
        return Ok(Value::Object(doc.clone()));
    }
    tokens(pointer)?;
    let whole = Value::Object(doc.clone());
    Ok(whole.pointer(pointer).cloned().unwrap_or(Value::Null))
}

/// The slot `tokens` name, created `null` where absent; each intermediate
/// object is created where absent or `null`, as jq's `.a.b = v` creates
/// `a`. An intermediate that is neither an object nor an indexed array
/// refuses `record-shape`.
fn slot_mut<'a>(
    path: &Path,
    doc: &'a mut Document,
    pointer: &str,
    tokens: &[String],
) -> Result<&'a mut Value> {
    let Some((first, rest)) = tokens.split_first() else {
        return Err(refused("pointer-invalid", &[("pointer", pointer)]));
    };
    let mut current = doc.entry(first.clone()).or_insert(Value::Null);
    for token in rest {
        if current.is_null() {
            *current = Value::Object(Map::new());
        }
        current = match current {
            Value::Object(map) => map.entry(token.clone()).or_insert(Value::Null),
            Value::Array(items) => {
                let index: usize = token.parse().map_err(|_| {
                    shape(
                        path,
                        pointer,
                        ShapeReason::NotObject,
                        format!("index {token}"),
                    )
                })?;
                items
                    .get_mut(index)
                    .ok_or_else(|| shape(path, pointer, ShapeReason::NotObject, "absent"))?
            }
            other => {
                return Err(shape(
                    path,
                    pointer,
                    ShapeReason::NotObject,
                    format!("found {}", json_type(other)),
                ));
            }
        };
    }
    Ok(current)
}

/// Write `value` at `pointer`, each intermediate created as `slot_mut`
/// creates it.
pub(super) fn set_at(path: &Path, doc: &mut Document, pointer: &str, value: Value) -> Result<()> {
    *slot_mut(path, doc, pointer, &tokens(pointer)?)? = value;
    Ok(())
}

/// The value a `set` or `append` argument stands for: a `{` or `[` prefix
/// is JSON and refused when it does not parse, `null`, `true`, `false` and
/// an all-digit word are JSON, and anything else is the string itself, so a
/// quoted word keeps its quotes.
pub fn judge(text: &str) -> Result<Value> {
    let invalid = |cause: String| Error::Request {
        path: PathBuf::from("<value>"),
        cause,
    };
    if text.starts_with('{') || text.starts_with('[') {
        return serde_json::from_str(text).map_err(|e| invalid(e.to_string()));
    }
    match text {
        "null" => return Ok(Value::Null),
        "true" => return Ok(Value::Bool(true)),
        "false" => return Ok(Value::Bool(false)),
        _ => {}
    }
    if !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) {
        return text
            .parse::<u64>()
            .map(Value::from)
            .map_err(|e| invalid(e.to_string()));
    }
    Ok(Value::String(text.to_owned()))
}

/// The one JSON value a file holds: `append-missing` where there is no
/// file, `append-value` where it holds none or several.
pub(super) fn one_value(file: &Path) -> Result<Value> {
    let text = match std::fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(refused("append-missing", &[("file", &text_of(file))]));
        }
        Err(e) => return Err(agent_runtime::Error::io("read", file, e).into()),
    };
    let mut values = serde_json::Deserializer::from_str(&text).into_iter::<Value>();
    match (values.next(), values.next()) {
        (Some(Ok(value)), None) => Ok(value),
        _ => Err(refused("append-value", &[("file", &text_of(file))])),
    }
}

pub(super) fn tier(doc: &Document) -> Option<&str> {
    doc.get("tier").and_then(Value::as_str)
}

/// A whole-number count at `pointer`: an absent or null field is 0.
pub(super) fn count_at(path: &Path, doc: &Document, pointer: &str) -> Result<u64> {
    match get(doc, pointer)? {
        Value::Null => Ok(0),
        Value::Number(n) => n.as_u64().ok_or_else(|| {
            shape(
                path,
                pointer,
                ShapeReason::TypeMismatch,
                format!("found {n}"),
            )
        }),
        other => Err(shape(
            path,
            pointer,
            ShapeReason::TypeMismatch,
            format!("found {}", json_type(&other)),
        )),
    }
}

// ---------------------------------------------------------------------------
// The round caps
// ---------------------------------------------------------------------------

/// The round caps, each a setting with the record field its count is read
/// from and the ceiling a `small` item holds it to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cap {
    ReviewMaxCycles,
    ReviewMaxExternalRounds,
    CiFixMaxCycles,
}

const CAPS: [Cap; 3] = [
    Cap::ReviewMaxCycles,
    Cap::ReviewMaxExternalRounds,
    Cap::CiFixMaxCycles,
];

impl Cap {
    /// The cap a setting word names; another word refuses `unknown-cap`
    /// with the roster.
    pub fn parse(setting: &str) -> Result<Cap> {
        CAPS.into_iter()
            .find(|cap| cap.setting() == setting)
            .ok_or_else(|| {
                let known: Vec<&str> = CAPS.iter().map(|c| c.setting()).collect();
                refused(
                    "unknown-cap",
                    &[("setting", setting), ("known", &known.join(","))],
                )
            })
    }

    pub fn setting(self) -> &'static str {
        match self {
            Cap::ReviewMaxCycles => "REVIEW_MAX_CYCLES",
            Cap::ReviewMaxExternalRounds => "REVIEW_MAX_EXTERNAL_ROUNDS",
            Cap::CiFixMaxCycles => "CI_FIX_MAX_CYCLES",
        }
    }

    /// The pointer the cap's count is read from; the CI-fix cap keeps its
    /// count in the retry budget alone.
    fn field(self) -> Option<&'static str> {
        match self {
            Cap::ReviewMaxCycles => Some("/rereview_cycles"),
            Cap::ReviewMaxExternalRounds => Some("/pr_comment_review/iterations"),
            Cap::CiFixMaxCycles => None,
        }
    }

    /// The ceiling a `small` item holds the cap to: one re-review, two bot
    /// rounds, no bound on CI fixes.
    fn small(self) -> Option<u64> {
        match self {
            Cap::ReviewMaxCycles => Some(1),
            Cap::ReviewMaxExternalRounds => Some(2),
            Cap::CiFixMaxCycles => None,
        }
    }

    /// The resolved cap, held to the small ceiling where `tier` is `small`.
    /// The ceiling lowers a cap and never raises one.
    pub fn limit(self, store: &StoreSettings, tier: Option<&str>) -> Result<u64> {
        let limit = match self {
            Cap::ReviewMaxCycles => &store.review_max_cycles,
            Cap::ReviewMaxExternalRounds => &store.review_max_external_rounds,
            Cap::CiFixMaxCycles => &store.ci_fix_max_cycles,
        }
        .get()?;
        Ok(match (tier, self.small()) {
            (Some("small"), Some(ceiling)) if limit > ceiling => ceiling,
            _ => limit,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CapSource<'a> {
    Bare,
    Item(&'a Document),
    Count(u64),
}

/// The `cap` read: the resolved limit, or the verdict `below` or `at-cap`
/// over a count. `at-cap` is count >= limit, the count being entries
/// already taken, except that `REVIEW_MAX_CYCLES` 0 read on a record reads
/// `below` until `review_fix_round` is set: a cap of none still allows the
/// one blockers-only fix round, which the fix delegation marks and nothing
/// clears.
pub fn cap(path: &Path, store: &StoreSettings, cap: Cap, source: &CapSource<'_>) -> Result<Value> {
    let setting = cap.setting();
    let (count, limit, fix_round_pending) = match source {
        CapSource::Bare => {
            return Ok(json!({"setting": setting, "limit": cap.limit(store, None)?}));
        }
        CapSource::Count(count) => (*count, cap.limit(store, None)?, false),
        CapSource::Item(doc) => {
            let Some(field) = cap.field() else {
                return Err(refused("cap-count-required", &[("setting", setting)]));
            };
            let limit = cap.limit(store, tier(doc))?;
            let fix_round_set = doc
                .get("review_fix_round")
                .is_some_and(|v| !v.is_null() && *v != Value::Bool(false));
            let pending = cap == Cap::ReviewMaxCycles && limit == 0 && !fix_round_set;
            (count_at(path, doc, field)?, limit, pending)
        }
    };
    let verdict = if count >= limit && !(fix_round_pending && count == 0) {
        "at-cap"
    } else {
        "below"
    };
    Ok(json!({"setting": setting, "verdict": verdict, "count": count, "limit": limit}))
}

// ---------------------------------------------------------------------------
// The writes
// ---------------------------------------------------------------------------

/// The automatic retry budgets a pull request's post-steps spend.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BudgetKind {
    /// Restarts its count on a new head.
    ReviewWait,
    /// Counts across heads: every CI-fix cycle pushes a new head, so a
    /// head-keyed count would bound nothing.
    CiFix,
}

impl BudgetKind {
    pub fn parse(word: &str) -> Option<BudgetKind> {
        match word {
            "review-wait" => Some(BudgetKind::ReviewWait),
            "ci-fix" => Some(BudgetKind::CiFix),
            _ => None,
        }
    }

    pub fn word(self) -> &'static str {
        match self {
            BudgetKind::ReviewWait => "review-wait",
            BudgetKind::CiFix => "ci-fix",
        }
    }

    fn field(self) -> &'static str {
        match self {
            BudgetKind::ReviewWait => "review_wait",
            BudgetKind::CiFix => "ci_fix",
        }
    }

    fn cap(self) -> Cap {
        match self {
            BudgetKind::ReviewWait => Cap::ReviewMaxExternalRounds,
            BudgetKind::CiFix => Cap::CiFixMaxCycles,
        }
    }

    fn head_keyed(self) -> bool {
        match self {
            BudgetKind::ReviewWait => true,
            BudgetKind::CiFix => false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopMode {
    Record,
    RecordIfEmpty,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Write {
    Set {
        pointer: String,
        value: Value,
    },
    SetFile {
        pointer: String,
        file: PathBuf,
    },
    Append {
        pointer: String,
        value: Value,
    },
    /// Under `unique`, a value the array already holds is not appended.
    AppendFile {
        pointer: String,
        file: PathBuf,
        unique: bool,
    },
    /// The file's one object merged into the fleet record's lane `lane`.
    LaneMerge {
        lane: String,
        file: PathBuf,
    },
    Increment {
        pointer: String,
    },
    HeadBudget {
        kind: BudgetKind,
        head: String,
    },
    /// The budget restarted: a passing result, or a new period, owes its
    /// retries again.
    HeadBudgetReset {
        kind: BudgetKind,
    },
    PostPrStop {
        mode: StopMode,
        name: String,
        gate: String,
        remaining: String,
    },
    /// The standing stop lifted, so the next stop is recorded again.
    PostPrStopClear,
    StandingAdd {
        file: PathBuf,
    },
    StandingLift {
        file: PathBuf,
    },
    LogAppend {
        file: PathBuf,
    },
    FindingsRecord {
        file: PathBuf,
    },
    /// Several writes in one transition, so a group a caller sets together
    /// lands together or not at all.
    Many(Vec<Write>),
    /// The file's one value appended to the array at `pointer` in place of
    /// every element whose `key` field equals the value's.
    Upsert {
        pointer: String,
        key: String,
        file: PathBuf,
    },
    /// A finding moved into the bucket `into`, dropped from each of `drop`
    /// by its (location, description).
    Bucket(Bucket),
    /// Every member of the map at `pointer` closed: its `status` `closed`.
    CloseAll {
        pointer: String,
    },
    ModelSlot {
        session: String,
        cause: String,
        observed: String,
    },
    ModelCheck(ModelCheck),
    /// The standing switched check of `session` at `place` marked
    /// `recovery_started` before its recovery starts.
    ModelStart {
        place: Place,
        session: String,
    },
    ModelReset {
        lane: String,
        session: String,
        expected: PathBuf,
    },
    Heal(Heal),
}

/// A finding's bucket write: the entry is the file's one value, or, at
/// `element`, the description and location of the element there with the
/// `fields` beside them, an empty field left out.
#[derive(Debug, Clone, PartialEq)]
pub struct Bucket {
    pub into: String,
    pub drop: Vec<String>,
    pub file: PathBuf,
    pub element: Option<String>,
    pub fields: Vec<(String, String)>,
}

/// A model switch's check: the launch it is bound to is `expected`'s (the
/// record the hook read), the outcome `switched` or `unavailable`.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelCheck {
    pub place: Place,
    pub check: Check,
    pub expected: PathBuf,
}

/// Apply `write` to the record at `path` and report what it wrote. The
/// transition is a pure function of the document and its inputs, so a
/// record another writer moved between the read and the store is read again
/// and the transition re-applied. A file the write names is read inside the
/// transition, so its text never crosses argv and a re-applied transition
/// reads it again. A field a named operation owns is held to that
/// operation's check before the store, so a pointer write lands nothing the
/// operation would refuse.
#[allow(
    clippy::disallowed_methods,
    reason = "the state verbs' one store write: the transition's document committed through the state module's write check"
)]
pub fn run_write(
    path: &Path,
    locking: Locking,
    store: &StoreSettings,
    env: &Env,
    write: &Write,
) -> Result<Value> {
    record::reread(
        || {
            let snapshot = loaded(path)?;
            let mut doc = snapshot.doc.clone();
            let report = transition(path, &mut doc, store, env, write)?;
            super::records::check_owned(&snapshot.doc, &doc)?;
            record::store(path, &snapshot.doc, &doc, locking)?;
            Ok(report)
        },
        Error::key,
    )
}

fn transition(
    path: &Path,
    doc: &mut Document,
    store: &StoreSettings,
    env: &Env,
    write: &Write,
) -> Result<Value> {
    match write {
        Write::Set { pointer, value } => set(path, doc, store, env, pointer, value.clone()),
        Write::SetFile { pointer, file } => set(path, doc, store, env, pointer, one_value(file)?),
        Write::Append { pointer, value } => append(path, doc, pointer, value.clone(), false),
        Write::AppendFile {
            pointer,
            file,
            unique,
        } => append(path, doc, pointer, one_value(file)?, *unique),
        Write::LaneMerge { lane, file } => {
            super::lane::merge_lane(path, doc, lane, one_value(file)?)
        }
        Write::Increment { pointer } => increment(path, doc, pointer),
        Write::HeadBudget { kind, head } => head_budget_take(path, doc, store, *kind, head),
        Write::HeadBudgetReset { kind } => head_budget_reset(path, doc, *kind),
        Write::PostPrStop {
            mode,
            name,
            gate,
            remaining,
        } => Ok(post_pr_stop_record(doc, *mode, name, gate, remaining)),
        Write::PostPrStopClear => Ok(post_pr_stop_clear(doc)),
        Write::StandingAdd { file } => standing_add(path, doc, env, one_value(file)?, file),
        Write::StandingLift { file } => standing_lift(path, doc, env, one_value(file)?, file),
        Write::LogAppend { file } => log_append(path, doc, store, env, one_value(file)?, file),
        Write::FindingsRecord { file } => findings_record_batch(doc, one_value(file)?, file),
        Write::Many(writes) => {
            let mut reports = Vec::with_capacity(writes.len());
            for write in writes {
                reports.push(transition(path, doc, store, env, write)?);
            }
            Ok(json!({"writes": reports}))
        }
        Write::Upsert { pointer, key, file } => upsert(path, doc, pointer, key, one_value(file)?),
        Write::Bucket(bucket) => bucket_write(path, doc, bucket),
        Write::CloseAll { pointer } => close_all(path, doc, pointer),
        Write::ModelSlot {
            session,
            cause,
            observed,
        } => Ok(model_slot(path, doc, env, session, cause, observed)),
        Write::ModelCheck(check) => Ok(model::record_model_check(
            path,
            doc,
            &env.iso(),
            &check.place,
            &check.check,
            &one_value(&check.expected)?,
        )?),
        Write::ModelStart { place, session } => {
            Ok(model::start_model_recovery(path, doc, place, session)?)
        }
        Write::ModelReset {
            lane,
            session,
            expected,
        } => model_reset(path, doc, env, lane, session, &one_value(expected)?),
        Write::Heal(given) => Ok(heal::heal(doc, given)?),
    }
}

/// The judgements the store makes on a `set`, by the field it names. An
/// item's handoff record is `record-handoff`'s: a pointer write there would
/// land a record with no stamp. The fleet record's whole `handoff` is
/// `record-overseer-ledger`'s write, stamped under the time rule.
fn set(
    path: &Path,
    doc: &mut Document,
    store: &StoreSettings,
    env: &Env,
    pointer: &str,
    value: Value,
) -> Result<Value> {
    let tokens = tokens(pointer)?;
    let field = tokens[0].as_str();
    if field == "handoff" && Kind::of_path(path) == Kind::Item {
        return Err(refused(
            "handoff-route",
            &[("pointer", pointer), ("op", "record-handoff")],
        ));
    }
    if tokens.len() == 1 {
        if field == "handoff" {
            return ledger::handoff(doc, env, value);
        }
        if field == "tier" {
            progress::tier_value(field, &value)?;
        }
        // A whole panel is `record-panel`'s write, its rules and the
        // rereview count with it.
        if let Some(kind) = reviewers::PanelKind::of_field(field)
            && value.is_object()
        {
            let panel: reviewers::Panel = serde_json::from_value(value).map_err(|e| {
                super::records::owned_refusal(field, "record-panel", &e.to_string())
            })?;
            return reviewers::panel_write(path, doc, store, kind, &panel);
        }
    }
    *slot_mut(path, doc, pointer, &tokens)? = value.clone();
    Ok(json!({"pointer": pointer, "value": value}))
}

/// Append to the array at `pointer`, created when absent. The fleet log row
/// is `log append`'s, which stamps and bounds it; a `triaged` row is held
/// to the shape the watch rebuilds its acknowledged keys from.
fn append(
    path: &Path,
    doc: &mut Document,
    pointer: &str,
    value: Value,
    unique: bool,
) -> Result<Value> {
    let tokens = tokens(pointer)?;
    if tokens[0] == "fleet_log" {
        return Err(refused(
            "fleet-log-append",
            &[("pointer", pointer), ("route", "log-append")],
        ));
    }
    if tokens.len() == 1 && tokens[0] == "triaged" {
        ledger::triage_row(&value)?;
    }
    let slot = slot_mut(path, doc, pointer, &tokens)?;
    if slot.is_null() {
        *slot = Value::Array(Vec::new());
    }
    let Value::Array(items) = slot else {
        return Err(shape(
            path,
            pointer,
            ShapeReason::NotArray,
            format!("found {}", json_type(slot)),
        ));
    };
    let appended = !(unique && items.contains(&value));
    if appended {
        items.push(value.clone());
    }
    let length = items.len();
    Ok(json!({"pointer": pointer, "value": value, "length": length, "appended": appended}))
}

pub(super) fn increment(path: &Path, doc: &mut Document, pointer: &str) -> Result<Value> {
    let tokens = tokens(pointer)?;
    let slot = slot_mut(path, doc, pointer, &tokens)?;
    let count = match slot {
        Value::Null => 0,
        Value::Number(n) => n.as_u64().ok_or_else(|| {
            shape(
                path,
                pointer,
                ShapeReason::TypeMismatch,
                format!("found {n}"),
            )
        })?,
        other => {
            return Err(shape(
                path,
                pointer,
                ShapeReason::TypeMismatch,
                format!("found {}", json_type(other)),
            ));
        }
    };
    *slot = Value::from(count + 1);
    Ok(json!({"pointer": pointer, "value": count + 1}))
}

/// Spend one attempt of a retry budget, or report it spent. A `review-wait`
/// budget restarts on a new head; a `ci-fix` budget counts across heads. At
/// the cap nothing is written, so a replayed take spends nothing.
fn head_budget_take(
    path: &Path,
    doc: &mut Document,
    store: &StoreSettings,
    kind: BudgetKind,
    head: &str,
) -> Result<Value> {
    let limit = kind.cap().limit(store, tier(doc))?;
    let saved = doc
        .get("post_pr_budgets")
        .and_then(|b| b.get(kind.field()))
        .cloned()
        .unwrap_or(Value::Null);
    let used = if kind.head_keyed() && saved.get("head").and_then(Value::as_str) != Some(head) {
        0
    } else {
        saved.get("attempts").and_then(Value::as_u64).unwrap_or(0)
    };
    if used >= limit {
        return Ok(
            json!({"kind": kind.word(), "verdict": "at-cap", "attempts": used, "limit": limit}),
        );
    }
    let pointer = format!("/post_pr_budgets/{}", kind.field());
    *slot_mut(path, doc, &pointer, &tokens(&pointer)?)? =
        json!({"head": head, "attempts": used + 1});
    Ok(json!({"kind": kind.word(), "verdict": "continue", "attempts": used + 1, "limit": limit}))
}

fn head_budget_reset(path: &Path, doc: &mut Document, kind: BudgetKind) -> Result<Value> {
    let spent = doc
        .get("post_pr_budgets")
        .and_then(|b| b.get(kind.field()))
        .is_some_and(|b| !b.is_null());
    set_at(
        path,
        doc,
        &format!("/post_pr_budgets/{}", kind.field()),
        Value::Null,
    )?;
    let result = if spent { "reset" } else { "none" };
    Ok(json!({"kind": kind.word(), "result": result}))
}

/// A budget is `null` or the head it was last spent on and its attempts.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Budget {
    #[serde(rename = "head")]
    _head: String,
    #[serde(rename = "attempts")]
    _attempts: u64,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Budgets {
    #[serde(default, rename = "review_wait")]
    _review_wait: Option<Budget>,
    #[serde(default, rename = "ci_fix")]
    _ci_fix: Option<Budget>,
}

pub(crate) fn check_budgets(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<Option<Budgets>>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}

/// Record the stop, or keep the one standing under `record-if-empty`: the
/// first stop a pull request is told is the precise one.
fn post_pr_stop_record(
    doc: &mut Document,
    mode: StopMode,
    name: &str,
    gate: &str,
    remaining: &str,
) -> Value {
    let current = doc.get("post_pr_stop").cloned().unwrap_or(Value::Null);
    if mode == StopMode::RecordIfEmpty && !current.is_null() {
        return json!({"result": "kept", "stop": current});
    }
    let stop = json!({"name": name, "gate": gate, "remaining": [remaining]});
    record::set(doc, "post_pr_stop", stop.clone());
    json!({"result": "recorded", "stop": stop})
}

fn post_pr_stop_clear(doc: &mut Document) -> Value {
    let standing = doc.get("post_pr_stop").is_some_and(|stop| !stop.is_null());
    record::set(doc, "post_pr_stop", Value::Null);
    json!({"result": if standing { "cleared" } else { "none" }})
}

/// A stop is `null` or the one `record` writes.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Stop {
    #[serde(rename = "name")]
    _name: String,
    #[serde(rename = "gate")]
    _gate: String,
    #[serde(rename = "remaining")]
    _remaining: Vec<String>,
}

pub(crate) fn check_stop(now: &Value) -> std::result::Result<(), String> {
    serde_json::from_value::<Option<Stop>>(now.clone())
        .map(drop)
        .map_err(|e| e.to_string())
}

/// The stop recorded, then its Markdown comment rendered where this write
/// recorded it; a kept stop renders nothing, so the comment is written once.
pub fn post_pr_stop(
    path: &Path,
    locking: Locking,
    store: &StoreSettings,
    env: &Env,
    write: &Write,
    comment_file: &Path,
) -> Result<Value> {
    let Write::PostPrStop {
        name,
        gate,
        remaining,
        ..
    } = write
    else {
        unreachable!("post_pr_stop runs the stop write alone");
    };
    let mut result = run_write(path, locking, store, env, write)?;
    if result["result"] == "recorded" {
        render_comment(comment_file, name, gate, remaining)?;
    }
    result["comment"] = json!(text_of(comment_file));
    Ok(result)
}

/// The stop's comment, written whole beside its final name and renamed into
/// place, so a reader never sees a partial file.
#[allow(
    clippy::disallowed_methods,
    reason = "the stop comment is the one file the state verbs write beside a record, replaced atomically"
)]
fn render_comment(comment_file: &Path, name: &str, gate: &str, remaining: &str) -> Result<()> {
    let text = format!(
        "## Orchestration stopped\n\n- Stop: `{name}`\n- Gate: `{gate}`\n- Remaining: {remaining}\n"
    );
    let mut temp = comment_file.as_os_str().to_owned();
    temp.push(".tmp");
    let temp = PathBuf::from(temp);
    std::fs::write(&temp, text).map_err(|e| agent_runtime::Error::io("write", &temp, e))?;
    std::fs::rename(&temp, comment_file)
        .map_err(|e| agent_runtime::Error::io("rename", comment_file, e))?;
    Ok(())
}

/// The time rule the fleet log row, the standing row and the overseer's
/// handoff record share: the writer stamps an absent time field from its
/// clock, keeps a past one, and refuses one outside `YYYY-MM-DDThh:mm:ssZ`,
/// one naming no calendar instant, and one later than the clock, since no
/// write lands in the future.
pub(super) fn stamp(
    row: &mut Map<String, Value>,
    env: &Env,
    field: &str,
    invalid: &'static str,
    future: &'static str,
) -> Result<()> {
    let given = match row.get(field) {
        None | Some(Value::Null) | Some(Value::Bool(false)) => None,
        Some(Value::String(s)) if s.is_empty() => None,
        Some(value) => Some(value.clone()),
    };
    let Some(given) = given else {
        row.insert(field.to_owned(), Value::String(env.iso()));
        return Ok(());
    };
    let text = given
        .as_str()
        .map_or_else(|| given.to_string(), str::to_owned);
    let epoch = given
        .as_str()
        .and_then(clock::epoch_secs)
        .filter(|epoch| clock::iso_utc(*epoch) == text);
    let Some(epoch) = epoch else {
        return Err(refused(invalid, &[("at", &text)]));
    };
    if epoch > env.now_secs {
        return Err(refused(future, &[("at", &text), ("now", &env.iso())]));
    }
    Ok(())
}

/// The fleet log row: an object, stamped, its text under
/// `ORCH_FLEET_LOG_ROW_BYTES` since a successor reads the last rows whole
/// at takeover.
fn log_append(
    path: &Path,
    doc: &mut Document,
    store: &StoreSettings,
    env: &Env,
    row: Value,
    file: &Path,
) -> Result<Value> {
    let Value::Object(mut row) = row else {
        return Err(refused("fleet-log-record", &[("file", &text_of(file))]));
    };
    stamp(
        &mut row,
        env,
        "at",
        "fleet-log-at-invalid",
        "fleet-log-at-future",
    )?;
    let bytes = match row.get("text") {
        None | Some(Value::Null) => 0,
        Some(Value::String(text)) => text.len(),
        Some(other) => other.to_string().len(),
    } as u64;
    let cap = store.fleet_log_row_bytes.get()?;
    if bytes > cap {
        return Err(refused(
            "fleet-log-row-bytes",
            &[("bytes", &bytes.to_string()), ("cap", &cap.to_string())],
        ));
    }
    let row = Value::Object(row);
    record::array_mut(path, doc, "fleet_log")?.push(row.clone());
    Ok(json!({"row": row}))
}

/// One standing instruction joins `standing[]`, stamped as a log row is.
fn standing_add(
    path: &Path,
    doc: &mut Document,
    env: &Env,
    row: Value,
    file: &Path,
) -> Result<Value> {
    let Value::Object(mut row) = row else {
        return Err(refused("standing-record", &[("file", &text_of(file))]));
    };
    stamp(
        &mut row,
        env,
        "at",
        "standing-at-invalid",
        "standing-at-future",
    )?;
    let row = Value::Object(row);
    record::array_mut(path, doc, "standing")?.push(row.clone());
    Ok(json!({"row": row}))
}

/// `standing[]` becomes the array the file holds, and one `ruling` row
/// naming the ids that left joins the fleet log in the same write, so the
/// lift and its record never stand apart.
fn standing_lift(
    path: &Path,
    doc: &mut Document,
    env: &Env,
    standing: Value,
    file: &Path,
) -> Result<Value> {
    let Value::Array(rows) = standing else {
        return Err(refused("standing-array", &[("file", &text_of(file))]));
    };
    let ids = |rows: &[Value]| -> Vec<String> {
        rows.iter()
            .filter_map(|row| row.get("id"))
            .map(|id| id.as_str().map_or_else(|| id.to_string(), str::to_owned))
            .collect()
    };
    let before = ids(record::array_mut(path, doc, "standing")?);
    let after = ids(&rows);
    let mut lifted: Vec<String> = Vec::new();
    for id in before {
        if !after.contains(&id) && !lifted.contains(&id) {
            lifted.push(id);
        }
    }
    let text = if lifted.is_empty() {
        "standing lifted: none".to_owned()
    } else {
        format!("standing lifted: {}", lifted.join(", "))
    };
    let ruling = json!({"at": env.iso(), "kind": "ruling", "item": "overseer", "text": text});
    record::set(doc, "standing", Value::Array(rows.clone()));
    record::array_mut(path, doc, "fleet_log")?.push(ruling.clone());
    Ok(json!({"standing": rows, "lifted": lifted, "ruling": ruling}))
}

// ---------------------------------------------------------------------------
// The reads
// ---------------------------------------------------------------------------

#[allow(
    clippy::disallowed_methods,
    reason = "the state read verbs' one read of a record"
)]
pub fn read_if_standing(path: &Path) -> Result<Option<Document>> {
    Ok(state::load(path)?.map(|snapshot| snapshot.doc))
}

/// The record at `path`, refusing `record-missing` where none stands.
pub fn read(path: &Path) -> Result<Document> {
    read_if_standing(path)?.ok_or_else(|| {
        Error::Runtime(agent_runtime::Error::RecordMissing {
            path: path.to_path_buf(),
        })
    })
}

/// Whether the record stands, read three-valued: an unreadable path is its
/// own refusal, never absent.
pub fn exists(path: &Path, issue_id: &str) -> Result<Value> {
    let exists = match std::fs::metadata(path) {
        Ok(_) => true,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(e) => return Err(agent_runtime::Error::io("stat", path, e).into()),
    };
    Ok(json!({"issue_id": issue_id, "path": text_of(path), "exists": exists}))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogReader {
    /// The last `ORCH_TAKEOVER_ROWS` rows but `cycle` and `token`, which
    /// would crowd the rulings out of the window; nothing where no fleet
    /// record stands yet.
    Takeover,
    /// Every proposal and ruling row.
    Audit,
}

pub fn log_rows(
    doc: Option<&Document>,
    store: &StoreSettings,
    reader: LogReader,
) -> Result<Vec<Value>> {
    let rows: Vec<&Value> = doc
        .and_then(|doc| doc.get("fleet_log"))
        .and_then(Value::as_array)
        .map(|rows| rows.iter().collect())
        .unwrap_or_default();
    fn kind(row: &Value) -> &str {
        row.get("kind").and_then(Value::as_str).unwrap_or("")
    }
    Ok(match reader {
        LogReader::Takeover => {
            let kept: Vec<&Value> = rows
                .into_iter()
                .filter(|row| !matches!(kind(row), "cycle" | "token"))
                .collect();
            let n = usize::try_from(store.takeover_rows.get()?).unwrap_or(usize::MAX);
            let skip = kept.len().saturating_sub(n);
            kept.into_iter().skip(skip).cloned().collect()
        }
        LogReader::Audit => rows
            .into_iter()
            .filter(|row| matches!(kind(row), "proposal" | "ruling"))
            .cloned()
            .collect(),
    })
}

/// The key a workflow mints for work whose branch and pull request name no
/// issue: `local-<epoch>-<pid>-<random>`, in the path-safe grammar every
/// round writer checks. Nothing is written; the minter owns the key.
pub fn local_key(env: &Env, pid: u32) -> String {
    format!("local-{}-{pid}-{}", env.now_secs, env.nonce)
}

/// The owner progress report's path: `MM-DD-HH-MM.md` in UTC under the
/// report directory, `-succession` before the extension for the one a
/// succession writes. The directory is created; the report is the caller's.
#[allow(
    clippy::disallowed_methods,
    reason = "the progress report directory is made by the verb that names a path under it"
)]
pub fn progress_report_path(dir: &Path, now_secs: u64, succession: bool) -> Result<PathBuf> {
    if let Err(e) = std::fs::create_dir_all(dir) {
        return Err(refused(
            "progress-dir-failed",
            &[("path", &text_of(dir)), ("cause", &e.kind().to_string())],
        ));
    }
    let iso = clock::iso_utc(now_secs);
    let stamp = format!(
        "{}-{}-{}-{}",
        &iso[5..7],
        &iso[8..10],
        &iso[11..13],
        &iso[14..16]
    );
    let suffix = if succession { "-succession" } else { "" };
    Ok(dir.join(format!("{stamp}{suffix}.md")))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the state verbs run git for the head a `set-git-head` records, no effect on a lane or a controller"
)]
pub fn git_head(worktree: &Path) -> Result<String> {
    let dir = text_of(worktree);
    let output = host::run_tagged(
        "state",
        "git",
        Path::new("git"),
        "rev-parse",
        &["-C", &dir, "rev-parse", "HEAD"],
        GIT_TIMEOUT,
    )?;
    if !output.status.success() {
        return Err(agent_runtime::Error::External {
            program: "git",
            operation: "rev-parse",
            cause: host::stderr_text(&output),
        }
        .into());
    }
    Ok(host::stdout_text(&output))
}

/// The item's standing handoff over the places the watch reads: the record
/// under `stands`, else the first place that could not be read, else none
/// with the first place holding a state file.
pub fn handoff_standing(state_dir: &Path, item: &str, root: Option<&Path>) -> Result<Value> {
    let places = handoff_places(state_dir, item, root);
    let mut unread = None;
    let mut home = None;
    for place in &places {
        match handoff_read(place) {
            HandoffReading::Stands { record } => {
                let record: Value = serde_json::from_str(&record)?;
                return Ok(json!({"standing": "stands", "file": text_of(place), "record": record}));
            }
            HandoffReading::Unreadable { path } => {
                unread.get_or_insert(path);
            }
            HandoffReading::None => {
                if home.is_none() && std::fs::metadata(place).is_ok() {
                    home = Some(place.clone());
                }
            }
        }
    }
    Ok(match unread {
        Some(path) => json!({"standing": "unreadable", "file": text_of(&path)}),
        None => {
            let file = home.unwrap_or_else(|| places[0].clone());
            json!({"standing": "none", "file": text_of(&file)})
        }
    })
}

// ---------------------------------------------------------------------------
// The workflows' compound writes and the turn-end hook's own
// ---------------------------------------------------------------------------

/// The array at `pointer`, created where absent.
pub(super) fn array_at<'a>(
    path: &Path,
    doc: &'a mut Document,
    pointer: &str,
) -> Result<&'a mut Vec<Value>> {
    let tokens = tokens(pointer)?;
    let slot = slot_mut(path, doc, pointer, &tokens)?;
    if slot.is_null() {
        *slot = Value::Array(Vec::new());
    }
    match slot {
        Value::Array(items) => Ok(items),
        other => Err(shape(
            path,
            pointer,
            ShapeReason::NotArray,
            format!("found {}", json_type(other)),
        )),
    }
}

fn upsert(
    path: &Path,
    doc: &mut Document,
    pointer: &str,
    key: &str,
    value: Value,
) -> Result<Value> {
    let Some(named) = value.get(key).cloned() else {
        return Err(refused("upsert-key", &[("pointer", pointer), ("key", key)]));
    };
    let items = array_at(path, doc, pointer)?;
    let before = items.len();
    items.retain(|item| item.get(key) != Some(&named));
    let replaced = before - items.len();
    items.push(value.clone());
    Ok(json!({"pointer": pointer, "value": value, "replaced": replaced, "length": items.len()}))
}

/// The bucket verb is `record-disposition`'s move over pointers: the
/// findings module reads the entry and moves it.
fn bucket_write(path: &Path, doc: &mut Document, bucket: &Bucket) -> Result<Value> {
    let entry = findings::entry_of(&bucket.file, bucket.element.as_deref(), &bucket.fields)?;
    findings::bucket(path, doc, &bucket.into, &bucket.drop, entry)
}

pub(super) fn close_all(path: &Path, doc: &mut Document, pointer: &str) -> Result<Value> {
    let tokens = tokens(pointer)?;
    let slot = slot_mut(path, doc, pointer, &tokens)?;
    if slot.is_null() {
        *slot = Value::Object(Map::new());
    }
    let Value::Object(members) = slot else {
        return Err(shape(
            path,
            pointer,
            ShapeReason::NotObject,
            format!("found {}", json_type(slot)),
        ));
    };
    for (name, member) in members.iter_mut() {
        if member.is_null() {
            *member = Value::Object(Map::new());
        }
        let Value::Object(fields) = member else {
            return Err(shape(
                path,
                &format!("{pointer}/{name}"),
                ShapeReason::NotObject,
                format!("found {}", json_type(member)),
            ));
        };
        fields.insert("status".to_owned(), json!("closed"));
    }
    Ok(json!({"pointer": pointer, "closed": members.len()}))
}

/// The item's once-only notice slot for a session's unavailable model: kept
/// where any check of the session stands.
fn model_slot(
    path: &Path,
    doc: &mut Document,
    env: &Env,
    session: &str,
    cause: &str,
    observed: &str,
) -> Value {
    let _ = path;
    let checks = doc
        .entry("model_checks")
        .or_insert_with(|| Value::Object(Map::new()));
    if checks.is_null() {
        *checks = Value::Object(Map::new());
    }
    if checks.get(session).is_some_and(|c| !c.is_null()) {
        return json!({"recorded": false});
    }
    if let Value::Object(checks) = checks {
        checks.insert(
            session.to_owned(),
            json!({"outcome": "unavailable", "session_id": session, "launched": Value::Null,
                   "observed": observed, "cause": cause, "at": env.iso()}),
        );
    }
    json!({"recorded": true})
}

/// Each check the write changed is one a model check writes: an outcome of
/// `switched` or `unavailable`, and a `recovery_started` mark, a boolean,
/// only on a switch.
pub(crate) fn check_model_checks(
    was: Option<&Value>,
    now: &Value,
) -> std::result::Result<(), String> {
    let Value::Object(checks) = now else {
        return Err("not an object".into());
    };
    let before = was.and_then(Value::as_object);
    for (session, check) in checks {
        if before.and_then(|b| b.get(session)) == Some(check) || check.is_null() {
            continue;
        }
        let outcome = check.get("outcome").and_then(Value::as_str);
        let started = check.get("recovery_started");
        match (outcome, started) {
            (Some("switched"), None | Some(Value::Bool(_))) | (Some("unavailable"), None) => {}
            _ => return Err(format!("{session}: not a check a model check writes")),
        }
    }
    Ok(())
}

/// A replacement's first turn end resets the lane's switched check to
/// `passed`, with its log row, where the lane still runs the launch, the
/// session and the check `expected` holds.
fn model_reset(
    path: &Path,
    doc: &mut Document,
    env: &Env,
    lane: &str,
    session: &str,
    expected: &Value,
) -> Result<Value> {
    let lanes: Vec<usize> = doc
        .get("lanes")
        .and_then(Value::as_array)
        .map(|lanes| {
            lanes
                .iter()
                .enumerate()
                .filter(|(_, l)| l.get("item").and_then(Value::as_str) == Some(lane))
                .map(|(index, _)| index)
                .collect()
        })
        .unwrap_or_default();
    let Some(first) = lanes.first() else {
        return Ok(json!({"reset": false}));
    };
    let current = get(doc, &format!("/lanes/{first}"))?;
    let moved = |key: &str| current.get(key) != expected.get(key);
    if moved("launch") || moved("launched_at") || moved("session_id") || moved("model_check") {
        return Ok(json!({"reset": false}));
    }
    let check = json!({"outcome": "passed", "session_id": session,
                       "launch_identity": model::launch_of(&Place::Lane(lane.to_owned()), &current), "at": env.iso()});
    for index in &lanes {
        let slot = format!("/lanes/{index}/model_check");
        *slot_mut(path, doc, &slot, &tokens(&slot)?)? = check.clone();
    }
    let mut row = check;
    row["kind"] = json!("model-recovery-reset");
    row["item"] = json!(lane);
    row["text"] = json!("first-turn-complete");
    record::array_mut(path, doc, "fleet_log")?.push(row);
    Ok(json!({"reset": true}))
}

// ---------------------------------------------------------------------------
// Finding occurrences
// ---------------------------------------------------------------------------

/// A finding's cause keys: its `location` and `owner`, or the first line's
/// location and the `Owner:` line of a `text` block, each trimmed, with the
/// empty, `TBD` and `general` placeholders dropped.
fn cause_keys(finding: &Value) -> Vec<String> {
    let (location, owner) = match finding.get("text").and_then(Value::as_str) {
        Some(text) => {
            let mut lines = text.split('\n');
            let location = lines
                .next()
                .map(|first| first.split('|').skip(2).collect::<Vec<_>>().join("|"));
            let owner = lines
                .find_map(|line| line.strip_prefix("Owner:"))
                .map(str::to_owned);
            (location, owner)
        }
        None => (
            finding
                .get("location")
                .and_then(Value::as_str)
                .map(str::to_owned),
            finding
                .get("owner")
                .and_then(Value::as_str)
                .map(str::to_owned),
        ),
    };
    let mut keys: Vec<String> = [location, owner]
        .into_iter()
        .flatten()
        .map(|key| key.trim().to_owned())
        .filter(|key| !matches!(key.as_str(), "" | "TBD" | "general"))
        .collect();
    keys.sort();
    keys.dedup();
    keys
}

fn shares_cause_key(a: &Value, b: &Value) -> bool {
    let keys = cause_keys(a);
    cause_keys(b).iter().any(|key| keys.contains(key))
}

/// The class a finding occurrence or request names: a review finding by
/// its location and owner, a validation by its check.
fn occurrence_class(finding: &Value) -> Result<Value> {
    match finding.get("kind").and_then(Value::as_str) {
        Some("review") => {
            let mut class = json!({"kind": "review", "location": finding.get("location").cloned().unwrap_or(Value::Null)});
            if let Some(owner) = finding.get("owner").filter(|o| !o.is_null()) {
                class["owner"] = owner.clone();
            }
            Ok(class)
        }
        Some("validation") => Ok(
            json!({"kind": "validation", "check": finding.get("check").cloned().unwrap_or(Value::Null)}),
        ),
        _ => Err(refused("finding-kind", &[])),
    }
}

/// The `findings query` read: `{prior, classes}` over the record's
/// `finding_occurrences`, one class per request (every known class with no
/// request file). A review request matches a record sharing a cause key, a
/// validation request one with the same check; a request with no usable
/// key reports `observed_count` null and prior `unknown`.
pub fn findings_query(doc: &Document, requests: Option<Vec<Value>>) -> Result<Value> {
    let history = doc
        .get("finding_occurrences")
        .filter(|h| !h.is_null())
        .cloned()
        .unwrap_or_else(|| json!({"prior": "unknown", "records": []}));
    let prior = history
        .get("prior")
        .cloned()
        .unwrap_or_else(|| json!("unknown"));
    let records: Vec<Value> = history
        .get("records")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let requests = match requests {
        Some(requests) => requests,
        None => {
            let mut classes = Vec::new();
            for record in &records {
                let class = occurrence_class(record)?;
                if !classes.contains(&class) {
                    classes.push(class);
                }
            }
            classes
        }
    };
    let mut classes = Vec::with_capacity(requests.len());
    for request in &requests {
        let kind = request.get("kind").and_then(Value::as_str);
        let check = request.get("check").and_then(Value::as_str);
        let bound = match kind {
            Some("review") => !cause_keys(request).is_empty(),
            _ => check.is_some_and(|c| !c.is_empty()),
        };
        let matches: Vec<&Value> = records
            .iter()
            .filter(|record| record.get("kind").and_then(Value::as_str) == kind)
            .filter(|record| match kind {
                Some("review") => shares_cause_key(record, request),
                _ => record.get("check").and_then(Value::as_str) == check,
            })
            .collect();
        let sources: Vec<Value> = matches
            .iter()
            .map(|m| m.get("source").cloned().unwrap_or(Value::Null))
            .collect();
        classes.push(json!({
            "class": occurrence_class(request)?,
            "observed_count": if bound { json!(matches.len()) } else { Value::Null },
            "prior": if bound { prior.clone() } else { json!("unknown") },
            "sources": sources,
        }));
    }
    Ok(json!({"prior": prior, "classes": classes}))
}

pub fn finding_requests(file: &Path) -> Result<Vec<Value>> {
    match one_value(file)? {
        Value::Array(requests) => Ok(requests),
        _ => Err(refused("finding-requests", &[("file", &text_of(file))])),
    }
}

/// Whether an occurrence names what the recurrence rule reads: its round and
/// identity, and a review's cause key and artifact or a validation's check
/// and receipt. An unbound record leaves coverage unknown, never another
/// spelling of a class.
fn occurrence_bound(record: &Value) -> bool {
    let text = |value: Option<&Value>| value.and_then(Value::as_str).is_some_and(|s| !s.is_empty());
    let source = record.get("source");
    let round = text(source.and_then(|s| s.get("round_id")));
    let identity = source
        .and_then(|s| s.get("identity"))
        .and_then(Value::as_array)
        .is_some_and(|i| !i.is_empty());
    let kind = match record.get("kind").and_then(Value::as_str) {
        Some("review") => {
            !cause_keys(record).is_empty() && text(source.and_then(|s| s.get("artifact")))
        }
        Some("validation") => {
            text(record.get("check")) && text(source.and_then(|s| s.get("receipt")))
        }
        _ => false,
    };
    round && identity && kind
}

/// The `findings record` transition over one batch: a bound record with a
/// new identity joins, one whose identity stands under the same class adds
/// nothing, and one whose identity stands under another class is a conflict
/// that lands none of the batch and leaves coverage unknown; an unbound
/// record or a batch marked unknown leaves coverage unknown too.
pub(super) fn findings_record_batch(
    doc: &mut Document,
    batch: Value,
    file: &Path,
) -> Result<Value> {
    let Some(records) = batch.get("records").and_then(Value::as_array).cloned() else {
        return Err(refused("finding-batch", &[("file", &text_of(file))]));
    };
    let mut history = match doc.get("finding_occurrences") {
        Some(Value::Object(history)) => history.clone(),
        _ => Map::new(),
    };
    if !history.get("prior").is_some_and(Value::is_string) {
        history.insert("prior".to_owned(), json!("unknown"));
    }
    let mut known: Vec<Value> = history
        .get("records")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut unknown = batch.get("unknown") == Some(&Value::Bool(true));
    let mut added = Vec::new();
    let mut conflict = None;
    for record in records {
        if !occurrence_bound(&record) {
            unknown = true;
            continue;
        }
        let identity = record
            .get("source")
            .and_then(|s| s.get("identity"))
            .cloned();
        let same: Vec<&Value> = known
            .iter()
            .chain(added.iter())
            .filter(|old| old.get("source").and_then(|s| s.get("identity")) == identity.as_ref())
            .collect();
        if same.is_empty() {
            added.push(record);
            continue;
        }
        let class = occurrence_class(&record)?;
        let agree = same
            .iter()
            .map(|old| occurrence_class(old))
            .collect::<Result<Vec<Value>>>()?
            .iter()
            .all(|old| *old == class);
        if !agree {
            conflict = Some(identity.unwrap_or(Value::Null));
            break;
        }
    }
    let recorded = if conflict.is_some() {
        unknown = true;
        0
    } else {
        known.extend(added);
        known.len()
    };
    if unknown {
        history.insert("prior".to_owned(), json!("unknown"));
    }
    if conflict.is_none() {
        history.insert("records".to_owned(), Value::Array(known));
    }
    let prior = history.get("prior").cloned().unwrap_or(Value::Null);
    record::set(doc, "finding_occurrences", Value::Object(history));
    Ok(json!({"recorded": recorded, "prior": prior, "conflict": conflict}))
}

/// Record a batch of verified findings; a class conflict is written as
/// unknown coverage and then refused, so a caller's failed record never
/// reads as complete coverage.
pub fn findings_record(
    path: &Path,
    locking: Locking,
    store: &StoreSettings,
    env: &Env,
    file: &Path,
) -> Result<Value> {
    let write = Write::FindingsRecord {
        file: file.to_path_buf(),
    };
    let result = run_write(path, locking, store, env, &write)?;
    if !result["conflict"].is_null() {
        return Err(refused(
            "finding-source-conflict",
            &[("file", &text_of(file))],
        ));
    }
    Ok(result)
}
