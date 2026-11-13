//! The review admission a launched lane asks from its own shell before it
//! starts an attached review panel or a process-owned reviewer: the lane
//! names its item and the launch kind, nothing of its session. The session
//! and its transcript come from the lane's context record, which the
//! session's own tool call bound to it before this call ran
//! (`marks::session_record`), read by the caller's pane; the reading is the
//! turn end's own, through agent-runtime's reader for the harness, and the
//! judge is the one judge of a reading. The answer is one JSON line,
//! `verdict`, `decision` and `source`, at exit 0, or a keyed refusal at
//! exit 2.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::answer::{Harness, Said};
use super::identity::Lane;
use super::marks::{self, Judge, Reading};
use super::payload::Payload;
use super::role;
use super::{Answer, Flow, Turn, Vars};
use crate::marker::{self, CONTEXT_RECORD};
use crate::ops::store::handoff_standing;
use crate::watch::context::ContextRecord;

/// Why no record of the caller's session could be bound.
#[derive(Debug)]
pub enum Unbound {
    /// No record stands, it cannot be read, or it names no session.
    Unrecorded { record: PathBuf, cause: String },
    /// The record was written at another pane than the caller's.
    OtherPane {
        recorded: Option<String>,
        caller: Option<String>,
    },
}

/// The record of the session bound to the caller's own pane in `mailbox`:
/// the record must name a session and the pane key the caller sits on, a
/// caller and a record that both name none (a lane with no pane) being told
/// apart by the session id alone, which the caller's own tool call wrote.
pub fn bound_session(mailbox: &Path) -> Result<ContextRecord, Unbound> {
    let record = mailbox.join(CONTEXT_RECORD);
    let unrecorded = |cause: String| Unbound::Unrecorded {
        record: record.clone(),
        cause,
    };
    let text = std::fs::read_to_string(&record).map_err(|e| unrecorded(e.to_string()))?;
    let bound = ContextRecord::parse(&text).map_err(unrecorded)?;
    if bound.session_id.as_deref().is_none_or(str::is_empty) {
        return Err(unrecorded("the record names no session".to_owned()));
    }
    let caller = role::pane_key(&Vars::read(false));
    if bound.pane_key != caller {
        return Err(Unbound::OtherPane {
            recorded: bound.pane_key,
            caller,
        });
    }
    Ok(bound)
}

/// Judge `item`'s session for an attached launch, with the attached-agent
/// reserve, or with `checkpoint` for a process launch on the plain mark;
/// `private_env` is the command line's word on the private env file.
pub fn run(item: &str, checkpoint: bool, private_env: bool) -> Answer {
    let vars = Vars::read(private_env);
    let mut turn = Turn::new(Harness::Unlisted, PathBuf::new());
    match admit(&mut turn, &vars, item, checkpoint) {
        Ok(answer) => turn.said(&answer),
        Err(answer) => answer,
    }
}

fn admit(turn: &mut Turn, vars: &Vars, item: &str, checkpoint: bool) -> Flow<String> {
    if marker::item_name(item).is_err() {
        return Err(turn.refuse(Said::ItemInvalid, ""));
    }
    let unnamed = Payload::decode(b"", false)
        .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
    let dir = vars.project_dir.as_ref().unwrap_or(&vars.pwd).clone();
    // A directory that is no lane passes a hook silently; here nothing of
    // this session is recorded there.
    let mut lane = match Lane::read(turn, vars, &unnamed) {
        Ok(lane) => lane,
        Err(answer) if answer.code != 0 => return Err(answer),
        Err(_) => {
            let record = dir.join("tmp/lane-mail").join(item).join(CONTEXT_RECORD);
            return Err(turn.refuse(Said::SessionUnrecorded(record), ""));
        }
    };
    lane.item = Some(item.to_owned());
    let mailbox = lane.mail_root.join(item);
    let record = match bound_session(&mailbox) {
        Ok(record) => record,
        Err(Unbound::Unrecorded { record, cause }) => {
            return Err(turn.refuse(Said::SessionUnrecorded(record), &cause));
        }
        Err(Unbound::OtherPane { recorded, caller }) => {
            let said = Said::SessionOtherPane {
                recorded: recorded.unwrap_or_else(|| "none".to_owned()),
                caller: caller.unwrap_or_else(|| "none".to_owned()),
            };
            return Err(turn.refuse(said, ""));
        }
    };
    turn.harness = [
        Harness::Claude,
        Harness::Codex,
        Harness::Pi,
        Harness::Copilot,
    ]
    .into_iter()
    .find(|h| record.harness.as_deref() == Some(marks::harness_word(*h)))
    .unwrap_or(Harness::Unlisted);
    let named = json!({"session_id": record.session_id, "transcript_path": record.transcript});
    let payload = Payload::decode(named.to_string().as_bytes(), false)
        .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
    let settings = match marks::marks_settings(&lane.root, vars.private_env) {
        Ok(settings) => settings,
        Err(cause) => {
            let said = Said::AgentInput {
                value: "unanswered".to_owned(),
                instruction: String::new(),
            };
            return Err(turn.refuse(said, &cause));
        }
    };
    let file = handoff_standing(&settings.state_dir, item, Some(&lane.root))
        .ok()
        .and_then(|standing| standing["file"].as_str().map(PathBuf::from))
        .unwrap_or_default();
    let judge = Judge::admission(&lane, item, vars, &payload, settings, file, mailbox.clone());
    judge.context_share(turn)?;
    let reserve = if checkpoint {
        None
    } else {
        Some(judge.agent_reserve(turn)?)
    };
    let (verdict, decision) = match judge.read_and_record(turn, &mailbox)? {
        Reading::Measured { tokens, window, .. } => {
            let marks = judge.judged_marks(turn, tokens, window, reserve)?;
            let judged = if reserve.is_some() {
                &marks["reserve"]
            } else {
                &marks
            };
            let verdict = match judged["context"].as_str() {
                Some(verdict @ ("due" | "room")) => verdict.to_owned(),
                _ => return Err(judge.refuse_input(turn, "context-unmeasured")),
            };
            // A reserve-only refusal of a Codex attached launch is no parent
            // handoff: the plain mark still has room, so the panel runs as
            // process-owned reviewers. A plain reading that is not room
            // proves no room.
            let alternate = verdict == "due"
                && reserve.is_some()
                && turn.harness == Harness::Codex
                && marks["context"].as_str() == Some("room");
            let verdict = if alternate {
                "alternate-review".to_owned()
            } else {
                verdict
            };
            (verdict, judged["context_decision"].clone())
        }
        // Past the mark whatever a reading says, before any judgement.
        Reading::Compacted => ("due".to_owned(), Value::Null),
        Reading::Unread => return Err(judge.refuse_input(turn, "usage-unread")),
        Reading::None(gap) => {
            return Err(judge.refuse_input(turn, gap.unwrap_or("usage-absent")));
        }
    };
    let answer = json!({"verdict": verdict, "decision": decision, "source": judge.source(turn)});
    Ok(format!("{answer}\n"))
}
