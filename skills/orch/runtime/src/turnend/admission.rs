//! Review admission uses the turn end's context reader and mark judge
//! for the session bound at the lane's pane or named on stdin.

use std::io::{IsTerminal, Read};
use std::path::{Path, PathBuf};

use agent_runtime::context::{Member, calling_session};
use agent_runtime::controller::{Overseer, status};
use agent_runtime::effects::{Target, predecessor_identity};
use agent_runtime::harness::Harness as NativeHarness;
use agent_runtime::reading::Reading as ProcessReading;
use agent_runtime::{record, rows, session as native_session};
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

/// The model, effort and name of the session bound at the caller's pane,
/// for a call that names no session. The lane's context or the live
/// controller binds it. The session reader supplies the current values,
/// with a bound launch's effort filling an unrecorded session effort.
pub fn session(private_env: bool) -> Answer {
    let vars = Vars::read(private_env);
    let mut turn = Turn::new(Harness::Unlisted, PathBuf::new());
    let unnamed = |fields: String| Answer {
        stdout: format!("session-unnamed {fields}\n"),
        stderr: String::new(),
        code: 2,
        ack: None,
        unwritten: None,
    };
    let payload = match Payload::decode(b"", false) {
        Ok(payload) => payload,
        Err(invalid) => return turn.refuse(Said::PayloadInvalid, &invalid.0),
    };
    let dir = vars.project_dir.as_ref().unwrap_or(&vars.pwd).clone();
    let lane = match Lane::read(&mut turn, &vars, &payload) {
        Ok(lane) => lane,
        Err(answer) if answer.code != 0 => return answer,
        Err(_) => return unnamed(format!("dir={} cause=no lane", dir.display())),
    };
    let Some(item) = &lane.item else {
        return controller_session(&mut turn, &vars, &lane, &payload)
            .unwrap_or_else(|| unnamed(format!("dir={} cause=no lane", dir.display())));
    };
    let mailbox = lane.mail_root.join(item);
    let path = mailbox.join(CONTEXT_RECORD);
    let record = match bound_session(&mailbox) {
        Ok(record) => record,
        Err(Unbound::Unrecorded { record, cause }) => {
            return unnamed(format!("record={} cause={cause}", record.display()));
        }
        Err(Unbound::OtherPane { recorded, caller }) => {
            let pane = |key: Option<String>| key.unwrap_or_else(|| "none".to_owned());
            return unnamed(format!(
                "record={} cause=recorded at pane {}, called from pane {}",
                path.display(),
                pane(recorded),
                pane(caller)
            ));
        }
    };
    let Some(harness) = record.harness.as_deref().and_then(NativeHarness::parse) else {
        return unnamed(format!("record={} cause=no harness", path.display()));
    };
    let session = record.session_id.unwrap_or_default();
    let settings = marks::marks_settings(&mut turn, &lane.root, vars.private_env).ok();
    let launch = settings
        .as_ref()
        .and_then(|settings| crate::send::lane_record(settings, item).ok().flatten());
    let lead = settings
        .as_ref()
        .zip(launch.as_ref())
        .and_then(|(settings, launch)| {
            if launch.provider_hosted() || launch.session_channel() {
                return None;
            }
            crate::send::lead_call(settings, launch)
        });
    let owns_session = match super::model::hosted_caller(&lane) {
        Ok(Some(_)) => true,
        Ok(None) => match lead {
            Some(ProcessReading::Live(_)) => true,
            Some(ProcessReading::Gone | ProcessReading::Unreadable { .. }) => false,
            None => record.pane_key.is_some(),
        },
        Err(cause) => return unnamed(format!("record={} cause={cause}", path.display())),
    };
    if !owns_session {
        return unnamed(format!("record={} cause=no caller binding", path.display()));
    }
    let effort = launch
        .as_ref()
        .filter(|launch| {
            launch.session_id.as_deref() == Some(&session)
                && launch.harness.as_deref() == Some(harness.name())
        })
        .and_then(|launch| launch.effort.as_deref());
    session_answer(
        harness,
        &session,
        record.transcript.as_deref().map(Path::new),
        effort,
    )
}

/// Jarvis's status command resolves its home's fleet and calls this same
/// status reader. Use the reader directly so a comment cannot reconcile
/// open controller intents as the command can.
#[allow(
    clippy::disallowed_methods,
    reason = "find the bound Claude controller's transcript from its launch directory for the shared session reader"
)]
fn controller_session(
    turn: &mut Turn,
    vars: &Vars,
    lane: &Lane,
    payload: &Payload,
) -> Option<Answer> {
    role::session_pane(turn, vars, lane, payload).ok()?;
    let key = turn.role.key.as_ref()?.clone();
    let settings = marks::marks_settings(turn, &lane.root, vars.private_env).ok()?;
    let fleet = record::fleet_path(&settings.state_dir);
    // This invocation has no native hook payload. The caller's pane and the
    // live harness process serving this command establish its identity.
    let caller = status::CallerKey {
        server: &key.server.to_string(),
        socket: Some(&key.socket),
        pane: &key.pane,
        harness: "",
        home: "",
        session: "",
    };
    let status = status::status(&fleet, &settings.engine, Some(&caller)).ok()?;
    if !status.live || status.caller?.binding != status::Binding::Bound {
        return None;
    }
    let controller: Overseer = serde_json::from_value(status.recorded?).ok()?;
    let identity = predecessor_identity(&controller)?;
    let word = |key| controller.extra.get(key).and_then(Value::as_str);
    let harness = NativeHarness::parse(word("harness")?)?;
    let target = Target::new(&settings.engine.harness_binaries, harness).ok();
    let is_harness = |name: &str| {
        NativeHarness::ALL
            .iter()
            .any(|harness| harness.owns_process(name))
            || target.as_ref().is_some_and(|target| target.owns(name))
    };
    if !rows::served_by_here(identity.pid, &is_harness).ok()? {
        return None;
    }
    let session = controller
        .session_id
        .as_deref()
        .filter(|id| !id.is_empty())?;
    let transcript = word("cwd").and_then(|cwd| {
        let home = super::model::harness_home(harness, vars);
        native_session::fixed_file(harness, &home, Path::new(cwd), session)
    });
    Some(session_answer(
        harness,
        session,
        transcript.as_deref(),
        word("effort"),
    ))
}

fn session_answer(
    harness: NativeHarness,
    session: &str,
    transcript: Option<&Path>,
    launch_effort: Option<&str>,
) -> Answer {
    let mut now = calling_session(harness, session, transcript);
    if matches!(now.effort, Ok(Member::Unrecorded))
        && let Some(effort) = launch_effort.filter(|effort| !effort.is_empty())
    {
        now.effort = Ok(Member::Launch(effort.to_owned()));
    }
    let stdout = format!("{}\n", now.lines(harness, session).join("\n"));
    Answer {
        stdout,
        stderr: String::new(),
        code: now.exit_code(),
        ack: None,
        unwritten: None,
    }
}

/// Judge the caller for an attached launch with the reserve or for a
/// checkpoint on the plain mark. Outside a lane, stdin supplies a JSON
/// object with the harness and its native session inputs.
pub fn run(item: &str, checkpoint: bool, private_env: bool) -> Answer {
    let vars = Vars::read(private_env);
    let mut turn = Turn::new(Harness::Unlisted, PathBuf::new());
    let answer = match admit(&mut turn, &vars, item, checkpoint) {
        Ok(answer) => turn.said(&answer),
        Err(answer) => answer,
    };
    turn.finish(answer)
}

fn admit(turn: &mut Turn, vars: &Vars, item: &str, checkpoint: bool) -> Flow<String> {
    if marker::item_name(item).is_err() {
        return Err(turn.refuse(Said::ItemInvalid, ""));
    }
    let unnamed = Payload::decode(b"", false)
        .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
    let mut lane = match Lane::read(turn, vars, &unnamed) {
        Ok(lane) => lane,
        Err(answer) if answer.code != 0 => return Err(answer),
        Err(_) => {
            let root = vars.project_dir.as_ref().unwrap_or(&vars.pwd).clone();
            Lane {
                mail_root: root.join("tmp/lane-mail"),
                root,
                common: None,
                item: None,
            }
        }
    };
    if !lane.launched(turn)? {
        lane.item = None;
    }
    let mailbox = lane.mail_root.join(item);
    let (harness, payload) = if lane.item.is_some() {
        lane_payload(turn, &mailbox)?
    } else {
        standalone_payload(turn)?
    };
    turn.harness = harness;
    let settings = marks::marks_settings(turn, &lane.root, vars.private_env)
        .map_err(|cause| refuse_input(turn, "unanswered", &cause))?;
    let file = if lane.item.is_some() {
        handoff_standing(&settings.state_dir, item, Some(&lane.root))
            .ok()
            .and_then(|standing| standing["file"].as_str().map(PathBuf::from))
            .unwrap_or_default()
    } else {
        PathBuf::new()
    };
    let judge = Judge::admission(&lane, item, vars, &payload, settings, file, mailbox.clone());
    judge_admission(turn, &judge, &mailbox, checkpoint)
}

fn lane_payload(turn: &mut Turn, mailbox: &Path) -> Flow<(Harness, Payload)> {
    let record = match bound_session(mailbox) {
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
    let harness = named_harness(record.harness.as_deref());
    let named = json!({"session_id": record.session_id, "transcript_path": record.transcript});
    let payload = Payload::decode(named.to_string().as_bytes(), false)
        .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
    Ok((harness, payload))
}

fn standalone_payload(turn: &mut Turn) -> Flow<(Harness, Payload)> {
    let mut stdin = std::io::stdin().lock();
    let mut bytes = Vec::new();
    if !stdin.is_terminal() {
        stdin
            .read_to_end(&mut bytes)
            .map_err(|cause| turn.refuse(Said::PayloadUnreadable, &cause.to_string()))?;
    }
    let payload = Payload::decode(&bytes, false)
        .map_err(|invalid| turn.refuse(Said::PayloadInvalid, &invalid.0))?;
    let word = payload.field("harness").and_then(Value::as_str);
    let harness = named_harness(word);
    let gap = match harness {
        Harness::Unlisted if word.is_none_or(str::is_empty) => "harness-unnamed",
        Harness::Unlisted => "harness-unsupported",
        _ if payload.session.is_empty() => "session-unnamed",
        Harness::Copilot => return Ok((harness, payload)),
        _ if payload.transcript.is_empty() => "transcript-unnamed",
        _ => return Ok((harness, payload)),
    };
    Err(refuse_input(turn, gap, ""))
}

fn refuse_input(turn: &mut Turn, value: &str, cause: &str) -> Answer {
    turn.refuse(
        Said::AgentInput {
            value: value.to_owned(),
            instruction: String::new(),
        },
        cause,
    )
}

fn named_harness(word: Option<&str>) -> Harness {
    [
        Harness::Claude,
        Harness::Codex,
        Harness::Pi,
        Harness::Copilot,
    ]
    .into_iter()
    .find(|h| word == Some(marks::harness_word(*h)))
    .unwrap_or(Harness::Unlisted)
}

fn judge_admission(
    turn: &mut Turn,
    judge: &Judge<'_>,
    mailbox: &Path,
    checkpoint: bool,
) -> Flow<String> {
    judge.context_share(turn)?;
    let reserve = if checkpoint {
        None
    } else {
        Some(judge.agent_reserve(turn)?)
    };
    let (verdict, decision) = match judge.read_and_record(turn, mailbox)? {
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
