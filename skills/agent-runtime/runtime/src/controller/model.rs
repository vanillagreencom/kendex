//! The model check: a session's switch away from the model its launch named,
//! or its model read unavailable, recorded once per launch where the record
//! still runs that launch. One rule for every place a check is kept: the
//! item record's `model_checks` slot, a lane of the fleet record, and the
//! controller member, so a lane and the controller cannot come to judge a
//! duplicate, a stale reading or a recovery's start differently.

use std::path::Path;

use serde_json::{Map, Value, json};

use super::MEMBER;
use super::transition::MODEL_LAUNCH_KEYS;
use crate::error::{Error, Result, ShapeReason};
use crate::record::{self, Document};

/// Where a check is kept: the item record's own `model_checks` slot for the
/// session, the fleet record's lane for the item, or the controller member.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Place {
    Item,
    Lane(String),
    Controller,
}

impl Place {
    /// The place's word as a reply names it.
    pub fn word(&self) -> &'static str {
        match self {
            Place::Item => "item",
            Place::Lane(_) => "lane",
            Place::Controller => "overseer",
        }
    }
}

/// A check as its reader saw it: the outcome `switched` or `unavailable`,
/// with why, the model the launch named and the one read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Check {
    pub session: String,
    pub outcome: String,
    pub cause: String,
    pub launched: String,
    pub observed: String,
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    Error::refused(key, fields)
}

/// The record a check's reader read, the file's one JSON value:
/// `expected-missing` where no file stands, `expected-invalid` where it holds
/// anything but one value.
pub fn expected(file: &Path) -> Result<Value> {
    let named = file.display().to_string();
    let text = match std::fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(refused("expected-missing", &[("file", &named)]));
        }
        Err(e) => return Err(Error::io("read", file, e)),
    };
    let mut values = serde_json::Deserializer::from_str(&text).into_iter::<Value>();
    match (values.next(), values.next()) {
        (Some(Ok(value)), None) => Ok(value),
        _ => Err(refused("expected-invalid", &[("file", &named)])),
    }
}

/// The launch a check is bound to: the controller's
/// `{server, server_start, pane, generation, launch_line, cwd, session_id}`,
/// a lane's or an item's `{launch, launched_at}`.
pub fn launch_of(place: &Place, record: &Value) -> Value {
    let keys: &[&str] = match place {
        Place::Controller => MODEL_LAUNCH_KEYS,
        Place::Item | Place::Lane(_) => &["launch", "launched_at"],
    };
    Value::Object(
        keys.iter()
            .map(|key| {
                (
                    (*key).to_owned(),
                    record.get(*key).cloned().unwrap_or(Value::Null),
                )
            })
            .collect(),
    )
}

/// A check standing for the same session and launch answers `duplicate`:
/// a switch once its recovery started, an unavailable check for another
/// unavailable one, and an unavailable reading over a switch. A switch whose
/// recovery never started is acquired again, so a lost answer never
/// suppresses the recovery.
fn stands(current: &Value, session: &str, identity: &Value, outcome: &str) -> bool {
    let word = |key: &str| current.get(key).and_then(Value::as_str);
    if word("session_id") != Some(session) || current.get("launch_identity") != Some(identity) {
        return false;
    }
    match word("outcome") {
        Some("switched") => {
            outcome != "switched" || current.get("recovery_started") == Some(&Value::Bool(true))
        }
        Some("unavailable") => outcome == "unavailable",
        _ => false,
    }
}

fn written(check: &Check, identity: &Value, at: &str) -> Value {
    let mut out = json!({"outcome": check.outcome, "session_id": check.session, "launch_identity": identity,
                         "launched": check.launched, "observed": check.observed, "at": at,
                         "cause": check.cause});
    if check.outcome == "switched" {
        out["recovery_started"] = json!(false);
    }
    out
}

/// The index of the item's lane in the fleet record, where one stands.
fn lane_index(doc: &Document, lane: &str) -> Option<usize> {
    doc.get("lanes")
        .and_then(Value::as_array)
        .and_then(|lanes| {
            lanes
                .iter()
                .position(|l| l.get("item").and_then(Value::as_str) == Some(lane))
        })
}

/// The object `keys` name below the document, each created where absent or
/// `null`, as jq's `.a.b = v` creates `a`; another value on the way refuses
/// `record-shape`. A number names an element of an array that holds it.
fn object_at<'a>(path: &Path, doc: &'a mut Document, keys: &[String]) -> Result<&'a mut Document> {
    let shape = |found: &str| Error::RecordShape {
        path: path.to_path_buf(),
        field: format!("/{}", keys.join("/")),
        reason: ShapeReason::NotObject,
        cause: format!("found {found}"),
    };
    let mut current = doc;
    for key in keys {
        let slot = current.entry(key.clone()).or_insert(Value::Null);
        if slot.is_null() {
            *slot = Value::Object(Map::new());
        }
        current = match slot {
            Value::Object(map) => map,
            Value::Array(_) | Value::Bool(_) | Value::Number(_) | Value::String(_) => {
                return Err(shape("another value"));
            }
            Value::Null => unreachable!("a null slot was made an object above"),
        };
    }
    Ok(current)
}

/// The entry a fleet place's check is kept on, as its keys from the root:
/// the controller member, or the item's lane; `None` where no lane names it.
fn entry_keys(doc: &Document, place: &Place) -> Option<Vec<String>> {
    match place {
        Place::Controller => Some(vec![MEMBER.to_owned()]),
        Place::Lane(lane) => lane_index(doc, lane).map(|i| vec!["lanes".to_owned(), i.to_string()]),
        Place::Item => None,
    }
}

/// The value at `keys` below the document, `null` where nothing stands.
fn value_at(doc: &Document, keys: &[String]) -> Value {
    let mut current = doc.get(&keys[0]);
    for key in &keys[1..] {
        current = current.and_then(|v| match v {
            Value::Array(items) => key.parse::<usize>().ok().and_then(|i| items.get(i)),
            Value::Object(_)
            | Value::Null
            | Value::Bool(_)
            | Value::Number(_)
            | Value::String(_) => v.get(key),
        });
    }
    current.cloned().unwrap_or(Value::Null)
}

/// The lane entry at `keys` (`lanes`, index) as an object.
fn entry_mut<'a>(path: &Path, doc: &'a mut Document, keys: &[String]) -> Result<&'a mut Document> {
    match keys {
        [member] => object_at(path, doc, std::slice::from_ref(member)),
        [lanes, index] => {
            let index: usize = index.parse().unwrap_or(usize::MAX);
            record::element_mut(path, record::array_mut(path, doc, lanes)?, index, lanes)
        }
        _ => unreachable!("an entry is the controller member or one lane"),
    }
}

/// Record `check` at `place` in `doc`, bound to the launch `expected` holds
/// (the record its reader read): `acquired` with the check written, and at a
/// fleet place its `model-<outcome>` row in the fleet log; `duplicate` where
/// a standing check already answers it; `stale` where the entry no longer
/// runs that launch, session and model, or no lane names the item. An
/// outcome other than `switched` or `unavailable` refuses `model-outcome`.
pub fn record_model_check(
    path: &Path,
    doc: &mut Document,
    at: &str,
    place: &Place,
    check: &Check,
    expected: &Value,
) -> Result<Value> {
    if !matches!(check.outcome.as_str(), "switched" | "unavailable") {
        return Err(refused("model-outcome", &[("outcome", &check.outcome)]));
    }
    let identity = launch_of(place, expected);
    if place == &Place::Item {
        let keys = ["model_checks".to_owned(), check.session.clone()];
        if stands(
            &value_at(doc, &keys),
            &check.session,
            &identity,
            &check.outcome,
        ) {
            return Ok(json!({"result": "duplicate"}));
        }
        object_at(path, doc, &keys[..1])?
            .insert(check.session.clone(), written(check, &identity, at));
        return Ok(json!({"result": "acquired"}));
    }
    let Some(keys) = entry_keys(doc, place) else {
        return Ok(json!({"result": "stale"}));
    };
    let item = match place {
        Place::Lane(lane) => lane.clone(),
        Place::Controller | Place::Item => "oversee".to_owned(),
    };
    let current = value_at(doc, &keys);
    let moved = |key: &str| current.get(key) != expected.get(key);
    if (place == &Place::Controller && launch_of(place, &current) != identity)
        || moved("session_id")
        || moved("model")
        || moved("launch")
        || moved("launched_at")
    {
        return Ok(json!({"result": "stale"}));
    }
    let standing = current.get("model_check").unwrap_or(&Value::Null);
    if stands(standing, &check.session, &identity, &check.outcome) {
        return Ok(json!({"result": "duplicate"}));
    }
    // A switch acquired again before its recovery started is the same
    // check: the relaunch's recovery limit counts the log's rows for a
    // launch, so its row is replaced, never doubled.
    let again = check.outcome == "switched"
        && standing.get("outcome").and_then(Value::as_str) == Some("switched")
        && standing.get("session_id").and_then(Value::as_str) == Some(check.session.as_str())
        && standing.get("launch_identity") == Some(&identity);
    let written = written(check, &identity, at);
    let mut row = written.clone();
    row["kind"] = json!(format!("model-{}", check.outcome));
    row["item"] = json!(item);
    row["text"] = json!(format!(
        "launched={} observed={}",
        check.launched, check.observed
    ));
    let log = record::array_mut(path, doc, "fleet_log")?;
    let own = log.iter().rposition(|r| {
        r.get("kind") == Some(&row["kind"])
            && r.get("item") == Some(&row["item"])
            && r.get("session_id") == Some(&row["session_id"])
            && r.get("launch_identity") == Some(&identity)
    });
    match own.filter(|_| again) {
        Some(index) => log[index] = row,
        None => log.push(row),
    }
    entry_mut(path, doc, &keys)?.insert("model_check".to_owned(), written);
    Ok(json!({"result": "acquired", "record": value_at(doc, &keys)}))
}

/// Mark the standing switched check of `session` at `place` started, before
/// the recovery it guards starts: a check acquired again while unmarked is
/// the same switch, one marked is a duplicate. A repeat changes nothing, so
/// a replayed mark spends nothing; no switched check of the session refuses
/// `model-check-missing`.
pub fn start_model_recovery(
    path: &Path,
    doc: &mut Document,
    place: &Place,
    session: &str,
) -> Result<Value> {
    let keys = match place {
        Place::Item => Some(vec!["model_checks".to_owned(), session.to_owned()]),
        Place::Controller | Place::Lane(_) => entry_keys(doc, place).map(|mut keys| {
            keys.push("model_check".to_owned());
            keys
        }),
    };
    let check = keys
        .as_ref()
        .map_or(Value::Null, |keys| value_at(doc, keys));
    let word = |key: &str| check.get(key).and_then(Value::as_str);
    let switched = word("outcome") == Some("switched") && word("session_id") == Some(session);
    let Some(keys) = keys.filter(|_| switched) else {
        return Err(refused("model-check-missing", &[("session", session)]));
    };
    let started_now = check.get("recovery_started") != Some(&Value::Bool(true));
    let (parent, last) = keys.split_at(keys.len() - 1);
    let holder = match place {
        Place::Item => object_at(path, doc, parent)?,
        Place::Controller | Place::Lane(_) => entry_mut(path, doc, parent)?,
    };
    object_at(path, holder, last)?.insert("recovery_started".to_owned(), Value::Bool(true));
    Ok(json!({"place": place.word(), "session": session, "started_now": started_now}))
}
