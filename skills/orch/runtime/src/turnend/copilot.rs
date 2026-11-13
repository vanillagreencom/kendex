//! A Copilot session's compaction and context reading, which its hooks hand
//! to the turn end beside the turn end itself. Each is recorded in the box
//! the session's turn end reads it from: a launched lane's mailbox.

use std::path::{Path, PathBuf};

use agent_runtime::context;
use serde_json::{Value, json};

use super::answer::{Harness, Said};
use super::identity::Lane;
use super::payload::{Caller, Payload};
use super::{Flow, Turn, Vars};
use crate::marker::CONTEXT_RECORD;
use crate::watch::context::ContextRecord;

/// The flag a Copilot session's automatic compaction leaves in its box,
/// beside its reading: a file of its own, which no reading rewrites.
const COMPACTION_FLAG: &str = "compaction.json";

/// The compact arm: a Copilot lead's automatic compaction, flagged in the
/// box its turn end reads, which holds that turn end until the handoff
/// record stands. The backstop: the usage reading hands a session off
/// before Copilot compacts it, and the flag holds a turn that crossed into
/// the compaction before any reading past the mark reached a turn end.
/// Copilot's preCompact takes no answer and cannot be held, so a flag that
/// cannot be written is refused at exit 2, which Copilot shows the operator
/// as a warning while the compaction goes on. A manual compaction is the
/// operator's own and flags nothing, nor does a session with no box; the
/// caller rule has already passed a compaction that is not the lead's.
pub(super) fn compaction_mark(
    turn: &mut Turn,
    _vars: &Vars,
    lane: &Lane,
    payload: &Payload,
) -> Flow {
    if turn.harness != Harness::Copilot || payload.trigger != "auto" {
        return Ok(());
    }
    let Some(dir) = gated_box(turn, lane)? else {
        return Ok(());
    };
    let flag = json!({
        "harness": "copilot",
        "trigger": payload.trigger,
        "session_id": (!payload.session.is_empty()).then_some(&payload.session),
        "pane_key": null,
        "at": record_stamp(),
    });
    let path = dir.join(COMPACTION_FLAG);
    let Err(cause) = write_flag(&path, &flag) else {
        return Ok(());
    };
    Err(turn.refuse(Said::CompactionUnflagged(path), &cause))
}

/// The usage arm: the reading Copilot's context extension hands over for
/// the session's root agent, `{session_id, cwd, current_tokens,
/// token_limit}`, recorded in the session's box as its context record, the
/// capacity being the point Copilot compacts at, so its turn end judges it
/// under the shared rule as any other harness's reading. Nothing goes on
/// stdout; a gap is refused on stderr at exit 2, which the extension writes
/// to the session timeline. A session with no box passes silently.
pub(super) fn usage_read(turn: &mut Turn, _vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    if turn.harness != Harness::Copilot {
        return Err(turn.refuse(Said::HarnessUnlisted(turn.hook_dir.clone()), ""));
    }
    let Some(dir) = gated_box(turn, lane)? else {
        return Ok(());
    };
    // The extension hands over the root agent's readings alone, so a session
    // the caller rule leaves unknown is a lead whose record could not be
    // written; refused, so the gap reaches the session timeline.
    if turn.caller != Caller::Lead {
        let session = if payload.session.is_empty() {
            "none"
        } else {
            &payload.session
        };
        return Err(turn.refuse(Said::ReadingUnowned(session.to_owned()), ""));
    }
    let (tokens, capacity) = context::copilot_usage(
        payload.field("current_tokens"),
        payload.field("token_limit"),
    )
    .map_err(|cause| turn.refuse(Said::PayloadInvalid, cause))?;
    let record = ContextRecord {
        harness: Some("copilot".to_owned()),
        tokens: Some(tokens),
        window: Some(capacity),
        model: None,
        capacity_source: Some(context::COPILOT_EXTENSION_SOURCE.to_owned()),
        session_id: (!payload.session.is_empty()).then(|| payload.session.clone()),
        pane_key: None,
        gap: None,
        at: Some(record_stamp()),
    };
    let Err(cause) = record.write_to(&dir) else {
        return Ok(());
    };
    // The record standing there is an earlier reading, which can lie below
    // the mark this one crossed: left in place, the next turn end would judge
    // it as room.
    let path = dir.join(CONTEXT_RECORD);
    let (removed, cause) = match remove_stale(&path) {
        Ok(()) => (true, cause),
        Err(stands) => (false, format!("{cause}\n{stands}")),
    };
    let said = Said::ReadingUnkept {
        record: path,
        removed,
    };
    Err(turn.refuse(said, &cause))
}

/// The box a Copilot session's reading and compaction flag are recorded
/// in, the one its turn end reads: a launched lane's mailbox; `None` for a session that is no
/// launched lane, which passes silently.
fn gated_box(turn: &mut Turn, lane: &Lane) -> Flow<Option<PathBuf>> {
    match &lane.item {
        Some(item) if lane.launched(turn)? => Ok(Some(lane.mail_root.join(item))),
        _ => Ok(None),
    }
}

/// Write the compaction flag `flag` at `path`, through a file renamed over
/// it so no reader meets half a flag. `Err` carries the cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the compaction flag is a mailbox file no state store holds; this is its one writer, through the record module's atomic replace"
)]
fn write_flag(path: &Path, flag: &Value) -> Result<(), String> {
    agent_runtime::record::replace_atomically(path, flag).map_err(|e| e.to_string())
}

/// Remove the context record at `path`, a record already gone counting as
/// removed. `Err` names the path and the cause where it still stands.
#[allow(
    clippy::disallowed_methods,
    reason = "the removal of a Copilot session's earlier context reading, a mailbox file no state store holds, where the reading after it could not be written"
)]
fn remove_stale(path: &Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

/// The wall time a reading is recorded at, which the watch's stale rule and
/// the report compare with the session's rows.
#[allow(
    clippy::disallowed_methods,
    reason = "the context record's `at`, the wall time it was written, which its readers compare with wall-clock rows"
)]
fn record_stamp() -> String {
    agent_runtime::clock::now()
}
