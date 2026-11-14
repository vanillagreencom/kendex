//! The controller record's heal: the facts the session itself knows, written
//! where the record names none, for the session the record names. The turn
//! end of the controller's own session asks it, so a record that lost what
//! the transcript binding reads is filled from the session it describes.

use serde_json::{Value, json};

use super::MEMBER;
use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::record::Document;

/// What the calling session knows of itself: its tmux server's pid, its pane
/// and its server's start, its harness, the home its harness variable
/// carries and its native session id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Heal {
    pub server: String,
    pub pane: String,
    pub start: String,
    pub harness: String,
    pub home: String,
    pub session: String,
}

fn text(value: Option<&Value>) -> String {
    value.and_then(Value::as_str).unwrap_or("").to_owned()
}

/// Whether the session `harness`, `home` and `session` name is the one the
/// controller `member` records: a native id is given, and the recorded
/// harness, home and native id are each unrecorded or the session's; an
/// unread home matches.
pub fn native_match(member: &Value, harness: &str, home: &str, session: &str) -> bool {
    let open = |key: &str, given: &str| {
        let recorded = text(member.get(key));
        recorded.is_empty() || given.is_empty() && key == "home" || recorded == given
    };
    !session.is_empty()
        && open("harness", harness)
        && open("home", home)
        && open("session_id", session)
}

/// Heal the controller member of `doc` for the session `heal` names: the
/// record names that session where it names its server and pane (else its
/// tmux session) on the server's start, or on no start at all, and
/// `native_match` holds. Then the start is written, and the harness, home
/// and native id where the record names none. Any other record refuses
/// `overseer-native-unbound` naming the pane; a harness that is none of the
/// four refuses by its name before anything is read, and a start that is not
/// a number `server-start-invalid`.
pub fn heal(doc: &mut Document, heal: &Heal) -> Result<Value> {
    if !heal.harness.is_empty() {
        Harness::named(&heal.harness)?;
    }
    let unbound = || Error::refused("overseer-native-unbound", &[("pane", &heal.pane)]);
    let Some(Value::Object(record)) = doc.get_mut(MEMBER) else {
        return Err(unbound());
    };
    let pane = record
        .get("pane")
        .filter(|v| !v.is_null())
        .or_else(|| record.get("session"));
    let start = match record.get("server_start") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(other) => Some(other.to_string()),
    };
    let owns = text(record.get("server")) == heal.server
        && text(pane) == heal.pane
        && start.as_deref().is_none_or(|s| s == heal.start);
    let member = Value::Object(record.clone());
    if !(owns && native_match(&member, &heal.harness, &heal.home, &heal.session)) {
        return Err(unbound());
    }
    let Ok(server_start) = heal.start.parse::<u64>() else {
        return Err(Error::refused(
            "server-start-invalid",
            &[("start", &heal.start)],
        ));
    };
    record.insert("server_start".to_owned(), json!(server_start));
    for (key, given) in [
        ("harness", &heal.harness),
        ("home", &heal.home),
        ("session_id", &heal.session),
    ] {
        if text(record.get(key)).is_empty() && !given.is_empty() {
            record.insert(key.to_owned(), json!(given));
        }
    }
    Ok(json!({"controller": Value::Object(record.clone())}))
}
