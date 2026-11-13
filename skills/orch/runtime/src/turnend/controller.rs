//! A controller's own turn end: the overseer's and a managed Jarvis
//! session's context, marks and hand-over, judged on the role `role` reads.
//! The overseer's reading is recorded in the fleet's overseer mailbox under
//! its key, or, where it took none, the gap naming why, so the record moves
//! at every turn end and the watch reports a gap rather than a stale
//! figure.

use std::path::{Path, PathBuf};
use std::rc::Rc;

use agent_runtime::controller::views::MarkKind;
use agent_runtime::trust;
use serde_json::Value;

use super::answer::{self, Harness, Reached, Said};
use super::identity::Lane;
use super::marks::{self, Judge, OVERSEER_ITEM, Reading, Seat};
use super::payload::Payload;
use super::role::{Binding, Controller, Jarvis, Key, Kind};
use super::{Flow, Turn, Vars, mail, rows};
use crate::marker::CONTEXT_RECORD;
use crate::ops::store::handoff_standing;
use crate::settings::Settings;
use crate::watch::context::ContextRecord;
use crate::watch::mail::overseer_dir;
use crate::watch::overseer::marks_verb;

/// The overseer mailbox's told cache: `<session>\t<first keyed line>` of
/// the tool-call notice told last.
const CONTEXT_TOLD: &str = "context-told";

/// The turn end of a lead with no lane item: a managed Jarvis session meets
/// its own context mark, the fleet's overseer records its reading and meets
/// its marks; the controller the record lost records its gap where the
/// overseer's record still names it; any other session meets nothing here.
pub(super) fn turn_end(turn: &mut Turn, lane: &Lane, vars: &Vars, payload: &Payload) -> Flow {
    let role = Rc::clone(&turn.role);
    let Some(key) = &role.key else {
        return Ok(());
    };
    match (&role.kind, &role.binding) {
        (Kind::Jarvis(jarvis), binding) => {
            let bound = match binding {
                Binding::Bound(controller) => Some((caller_key(key), controller)),
                Binding::Lost(_) | Binding::None => None,
            };
            jarvis_marks(turn, lane, vars, payload, jarvis, bound)
        }
        (Kind::Overseer, Binding::Bound(controller)) => {
            overseer(turn, lane, vars, payload, key, controller)
        }
        (Kind::None | Kind::Overseer, Binding::Lost(controller)) => {
            lost(turn, lane, vars, payload, key, controller);
            Ok(())
        }
        (Kind::None, Binding::Bound(_)) | (Kind::None | Kind::Overseer, Binding::None) => Ok(()),
    }
}

/// A managed Jarvis session's turn end: its context mark alone, judged on
/// the reading of the transcript bound to its account home, with no
/// handoff record, fleet state or account behind it; a reached mark is
/// handed Jarvis's own succession. Where the fleet record binds it, keyed
/// as `bound` names with its controller, the watch's facts follow the
/// binding: its wake, its Stop row, and its reading or gap recorded in the
/// overseer mailbox.
fn jarvis_marks(
    turn: &mut Turn,
    lane: &Lane,
    vars: &Vars,
    payload: &Payload,
    jarvis: &Jarvis,
    bound: Option<(String, &Controller)>,
) -> Flow {
    let Ok(settings) = marks::marks_settings(turn, &lane.root, vars.private_env) else {
        return Ok(());
    };
    let (bound, controller) = bound.unzip();
    if let Some(controller) = controller {
        super::wake::check(turn, vars, lane, payload, &controller.fleet)?;
        rows::session_row(turn, vars, lane, payload)?;
    }
    let mailbox = overseer_dir(&settings.roots.common);
    let scripts = jarvis_scripts(&settings.lane_mail_cli);
    let seat = Seat::Jarvis {
        key: bound.clone(),
        home: jarvis.home.clone(),
        scripts,
    };
    let judge = Judge::controller(lane, vars, payload, settings, PathBuf::new(), mailbox, seat);
    let gap = |turn: &mut Turn, gap: &str| {
        if let Some(key) = &bound {
            gap_record(turn, &judge.mailbox, &payload.session, key, gap);
        }
    };
    let transcript = &payload.transcript;
    let owned = transcript_owned(
        turn.harness,
        transcript,
        &payload.session,
        &jarvis.account_home,
    );
    if let Err(reason) = owned {
        let said = Said::JarvisUnjudged(Box::new(Said::TranscriptUnowned(transcript.clone())));
        turn.note(&said, reason);
        gap(turn, reason);
        return Ok(());
    }
    // The setting is judged before the reading, so a value out of its form
    // is told in the one form every seat is told, never as a reading's fault.
    judge.context_share(turn)?;
    match judge.read_and_record(turn, &judge.mailbox)? {
        Reading::Measured {
            tokens,
            window,
            model,
        } => {
            let marks = judge.judged_marks(turn, tokens, window, None)?;
            match marks["context"].as_str() {
                Some("due") => {
                    let decision = marks["context_decision"].clone();
                    let instruction = judge.instruction(turn, decision, Some("context"))?;
                    let said = Said::JarvisContext {
                        tokens,
                        instruction,
                    };
                    return Err(turn.refuse(said, ""));
                }
                Some("room") => {}
                _ => {
                    let named = if model.is_empty() {
                        marks::harness_word(turn.harness).to_owned()
                    } else {
                        model
                    };
                    let said = Said::JarvisUnjudged(Box::new(Said::WindowUnread(named)));
                    turn.note(&said, "");
                }
            }
        }
        Reading::Unread => {
            let said = Said::JarvisUnjudged(Box::new(Said::UsageUnread(transcript.clone())));
            turn.note(&said, "");
            gap(turn, "usage-unread");
        }
        Reading::None(Some(reason)) => gap(turn, reason),
        Reading::None(None) | Reading::Compacted => {}
    }
    Ok(())
}

/// The installed Jarvis package's scripts directory, beside the mailbox
/// package whose reader the settings name, where Jarvis's own record
/// reader was found.
fn jarvis_scripts(reader: &Path) -> PathBuf {
    let skills = reader
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .unwrap_or(Path::new(""));
    skills.join("jarvis").join("scripts")
}

/// The overseer's turn end. Its own standing handoff passes it: it reached
/// its safe point and is ending. A handoff that cannot be read, or settings
/// that cannot be loaded, pass it with the gap reported, since the record
/// that clears a refusal would be written there.
fn overseer(
    turn: &mut Turn,
    lane: &Lane,
    vars: &Vars,
    payload: &Payload,
    key: &Key,
    controller: &Controller,
) -> Flow {
    let settings = match marks::marks_settings(turn, &lane.root, vars.private_env) {
        Ok(settings) => settings,
        Err(cause) => {
            turn.note(&Said::HandoffUnanswered, &cause);
            return Err(turn.pass());
        }
    };
    let caller_key = caller_key(key);
    let standing = match handoff_standing(&settings.state_dir, OVERSEER_ITEM, None) {
        Ok(standing) => standing,
        Err(e) => {
            turn.note(&Said::HandoffUnanswered, &e.to_string());
            return Err(turn.pass());
        }
    };
    let file = standing["file"].as_str().unwrap_or_default().to_owned();
    match standing["standing"].as_str() {
        Some("stands") if handoff_mine(&standing["record"], &payload.session, &caller_key) => {
            return Err(turn.pass());
        }
        Some("stands" | "none") => {}
        _ => {
            turn.note(&Said::HandoffUnreadable(file), "");
            return Err(turn.pass());
        }
    }
    super::wake::check(turn, vars, lane, payload, &controller.fleet)?;
    rows::session_row(turn, vars, lane, payload)?;
    // The record's own writer makes the box where the fleet has not
    // written to it yet.
    let mailbox = overseer_dir(&settings.roots.common);
    let seat = Seat::Overseer {
        key: caller_key.clone(),
        pane: key.pane.clone(),
        home: controller.home.clone(),
    };
    let judge = Judge::controller(lane, vars, payload, settings, file.into(), mailbox, seat);
    let read = context_read(turn, &judge, payload, &controller.home, &caller_key)?;
    // The compaction backstop is a verdict, not a reading: no judge derives
    // it, and it is refused whatever the succession setting, as the context
    // mark is.
    if let Read::Compacted = read {
        let instruction = judge.instruction(turn, Value::Null, None)?;
        return Err(turn.refuse(Said::Compacted { instruction }, ""));
    }
    overseer_marks(turn, &judge, controller, &read)
}

/// The overseer's marks, judged once by the runtime's one judge of a
/// controller's marks on the reading this turn end took, and acted on
/// here. A judge that cannot answer, and a figure it could not take, pass
/// the turn end with the gap reported: an overseer whose marks nothing can
/// measure must still be able to end a turn. Succession off passes an
/// account mark, which the watch reports every pass; the context mark is
/// refused whatever the setting, since no watch event reports it.
fn overseer_marks(turn: &mut Turn, judge: &Judge, controller: &Controller, read: &Read) -> Flow {
    let context = match read {
        Read::Measured { tokens, window, .. } => Some(format!(
            "{tokens}:{}",
            window.map(|w| w.to_string()).unwrap_or_default()
        )),
        Read::Unbound(_) | Read::Unmeasured(_) | Read::Compacted => None,
    };
    let harness = match read {
        Read::Unbound(_) => Some(marks::harness_word(turn.harness)).filter(|word| !word.is_empty()),
        Read::Measured { .. } | Read::Unmeasured(_) | Read::Compacted => None,
    };
    let reply = match marks_verb(
        &judge.settings,
        &controller.fleet,
        context.as_deref(),
        harness,
        None,
        marks::epoch_now(),
    ) {
        Ok(reply) => reply,
        Err(e) => {
            turn.note(&Said::Marks("unjudged"), &e.to_string());
            return Ok(());
        }
    };
    let line = reply.to_string();
    match reply["key"].as_str() {
        Some("mark-reached") => {}
        Some("mark-unmeasured") => {
            turn.note(&Said::Marks("unmeasured"), &line);
            return Ok(());
        }
        Some("below-mark") => return Ok(()),
        _ => {
            turn.note(&Said::Marks("unjudged"), &line);
            return Ok(());
        }
    }
    let field = |name: &str| reply[name].as_str().unwrap_or_default().to_owned();
    let (value, mark) = (field("value"), field("mark"));
    let kind = reply["kind"].as_str().and_then(MarkKind::parse);
    let Some(kind) = kind.filter(|_| !value.is_empty() && !mark.is_empty()) else {
        turn.note(&Said::Marks("unjudged"), &line);
        return Ok(());
    };
    if reply["succession"].as_str() == Some("off") && kind != MarkKind::Context {
        return Ok(());
    }
    let decision = reply
        .get("context_decision")
        .cloned()
        .unwrap_or(Value::Null);
    let cap = marks::decision_cap(&decision);
    let instruction = judge.instruction(turn, decision, Some(kind.word()))?;
    let window = match read {
        Read::Measured {
            window: Some(window),
            ..
        } => window.to_string(),
        Read::Measured { window: None, .. }
        | Read::Unbound(_)
        | Read::Unmeasured(_)
        | Read::Compacted => String::new(),
    };
    let said = Said::ControllerMark(Box::new(Reached {
        kind,
        value,
        mark,
        window,
        cap,
        instruction,
    }));
    Err(turn.refuse(said, ""))
}

/// What the overseer's read hands its judge.
enum Read {
    Measured {
        tokens: u64,
        window: Option<u64>,
        model: String,
    },
    /// The transcript was not bound, for the reason named: the account
    /// marks alone are judged, on the harness this install names.
    Unbound(&'static str),
    /// No reading, the gap recorded where one names why.
    Unmeasured(Option<&'static str>),
    /// Copilot flagged this session's automatic compaction.
    Compacted,
}

/// The overseer's context, read the one way a lane's is from the
/// transcript its binding owns, and recorded under its key; where nothing
/// was read, the gap record naming why.
fn context_read(
    turn: &mut Turn,
    judge: &Judge,
    payload: &Payload,
    home: &str,
    key: &str,
) -> Flow<Read> {
    let transcript = &payload.transcript;
    let owned = transcript_owned(turn.harness, transcript, &payload.session, home);
    if let Err(reason) = owned {
        turn.note(&Said::TranscriptUnowned(transcript.clone()), reason);
        gap_record(turn, &judge.mailbox, &payload.session, key, reason);
        return Ok(Read::Unbound(reason));
    }
    let gap = match judge.read_and_record(turn, &judge.mailbox)? {
        Reading::Measured {
            tokens,
            window,
            model,
        } => {
            return Ok(Read::Measured {
                tokens,
                window,
                model,
            });
        }
        Reading::None(None) => return Ok(Read::Unmeasured(None)),
        Reading::Compacted => return Ok(Read::Compacted),
        Reading::Unread => {
            turn.note(&Said::UsageUnread(transcript.clone()), "");
            "usage-unread"
        }
        Reading::None(Some(gap)) => gap,
    };
    gap_record(turn, &judge.mailbox, &payload.session, key, gap);
    Ok(Read::Unmeasured(Some(gap)))
}

/// The seat the bound overseer's attached launch is judged in; `None` for
/// any other session with no lane item, which meets no mark there.
pub(super) fn launch_seat(turn: &Turn) -> Option<Seat> {
    let role = &turn.role;
    let (Some(key), Kind::Overseer, Binding::Bound(controller)) =
        (&role.key, &role.kind, &role.binding)
    else {
        return None;
    };
    Some(Seat::Overseer {
        key: caller_key(key),
        pane: key.pane.clone(),
        home: controller.home.clone(),
    })
}

/// The bound overseer's reading at an attached launch, read and recorded
/// as its turn end takes it: the figures, or the input that left the
/// launch unjudged.
pub(super) fn launch_read(
    turn: &mut Turn,
    judge: &Judge,
    payload: &Payload,
    home: &str,
    key: &str,
) -> Flow<Result<(u64, Option<u64>), &'static str>> {
    Ok(match context_read(turn, judge, payload, home, key)? {
        Read::Measured { tokens, window, .. } => Ok((tokens, window)),
        Read::Unbound(gap) | Read::Unmeasured(Some(gap)) => Err(gap),
        Read::Unmeasured(None) | Read::Compacted => Err("usage-absent"),
    })
}

/// The controller the fleet record lost: a session whose native identity
/// the record names on another pane. Where the overseer's context record
/// still holds this session's reading, its turn end records the gap
/// `pane-unrecorded` and says so; it meets no mark. Any other record is
/// another session's and is left as it stands.
fn lost(
    turn: &mut Turn,
    lane: &Lane,
    vars: &Vars,
    payload: &Payload,
    key: &Key,
    controller: &Controller,
) {
    let Ok(settings) = marks::marks_settings(turn, &lane.root, vars.private_env) else {
        return;
    };
    let mailbox = overseer_dir(&settings.roots.common);
    let caller_key = caller_key(key);
    let Ok(text) = std::fs::read_to_string(mailbox.join(CONTEXT_RECORD)) else {
        return;
    };
    let Ok(record) = ContextRecord::parse(&text) else {
        return;
    };
    if record.pane_key.as_deref() != Some(caller_key.as_str()) {
        return;
    }
    let word = |field: &str| match &controller.recorded[field] {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        _ => String::new(),
    };
    let named = format!("{} {}", word("server"), word("pane"));
    let named = if named == " " {
        "none".to_owned()
    } else {
        named
    };
    turn.note(&Said::PaneUnrecorded(caller_key.clone()), &named);
    gap_record(
        turn,
        &mailbox,
        &payload.session,
        &caller_key,
        "pane-unrecorded",
    );
}

/// The key every controller record carries: `<server pid> <pane>`.
pub(super) fn caller_key(key: &Key) -> String {
    format!("{} {}", key.server, key.pane)
}

/// Whether a standing handoff on the fleet item is this session's own: the
/// native id names it where the payload carries one, else the key. A record
/// naming neither is nobody's.
pub(super) fn handoff_mine(record: &Value, session: &str, key: &str) -> bool {
    if session.is_empty() {
        return !key.is_empty() && record["pane_key"].as_str() == Some(key);
    }
    record["session_id"].as_str() == Some(session)
}

/// The overseer's context record with no reading and `gap` naming why. A
/// write that fails is said under its own key, since no reading stands
/// behind it.
fn gap_record(turn: &mut Turn, mailbox: &Path, session: &str, key: &str, gap: &str) {
    let nul = |text: &str| (!text.is_empty()).then(|| text.to_owned());
    let record = ContextRecord {
        harness: nul(marks::harness_word(turn.harness)),
        tokens: None,
        window: None,
        model: None,
        capacity_source: None,
        session_id: nul(session),
        pane_key: Some(key.to_owned()),
        transcript: None,
        gap: Some(gap.to_owned()),
        at: Some(marks::record_stamp()),
    };
    if let Err(cause) = record.write_to(mailbox) {
        let said = Said::ContextGapUnrecorded(mailbox.join(CONTEXT_RECORD));
        turn.note(&said, &cause);
    }
}

/// Whether `transcript` is the file `harness` writes for `session` under the
/// launch home `home`, by the path shape that harness writes: `Err` with
/// the reason where it is not. A payload naming no transcript, and a
/// harness with no transcript shape, bind nothing and the read goes ahead.
fn transcript_owned(
    harness: Harness,
    transcript: &str,
    session: &str,
    home: &str,
) -> Result<(), &'static str> {
    if transcript.is_empty() {
        return Ok(());
    }
    match harness {
        Harness::Claude | Harness::Codex | Harness::Copilot => {}
        Harness::Pi | Harness::Unlisted => return Ok(()),
    }
    if session.is_empty() {
        return Err("binding-missing");
    }
    if home.is_empty() {
        return Err("home-unnamed");
    }
    let home = home.strip_suffix('/').unwrap_or(home);
    let (named, under): (Vec<String>, Vec<String>) = match harness {
        Harness::Claude => (
            vec![String::new(), format!("/{session}.jsonl")],
            vec![format!("{home}/projects/"), format!("/{session}.jsonl")],
        ),
        Harness::Codex => (
            vec![
                String::new(),
                "/rollout-".to_owned(),
                format!("-{session}.jsonl"),
            ],
            vec![
                format!("{home}/sessions/"),
                "/rollout-".to_owned(),
                format!("-{session}.jsonl"),
            ],
        ),
        Harness::Copilot => (
            vec![
                String::new(),
                format!("/session-state/{session}/events.jsonl"),
            ],
            vec![format!("{home}/session-state/{session}/events.jsonl")],
        ),
        Harness::Pi | Harness::Unlisted => return Ok(()),
    };
    if !glob(transcript, &named) {
        return Err("session-mismatch");
    }
    if !glob(transcript, &under) {
        return Err("home-mismatch");
    }
    Ok(())
}

/// Whether `text` matches the literals `parts` joined by `*`, which matches
/// any run of bytes, `/` included, as a shell `case` pattern does.
fn glob(text: &str, parts: &[String]) -> bool {
    let Some((first, rest)) = parts.split_first() else {
        return text.is_empty();
    };
    let Some(mut left) = text.strip_prefix(first.as_str()) else {
        return false;
    };
    let Some((last, middle)) = rest.split_last() else {
        return left.is_empty();
    };
    for part in middle {
        match left.find(part.as_str()) {
            Some(at) => left = &left[at + part.len()..],
            None => return false,
        }
    }
    left.ends_with(last.as_str())
}

/// What a controller's tool call or Copilot start hands the model ahead of
/// the call's own answer, and the line the told cache records once it is
/// handed over.
pub(super) struct Notice {
    pub(super) text: String,
    told: Option<Told>,
}

/// The line a notice told once records, in the told cache `file`.
struct Told {
    file: PathBuf,
    line: String,
}

impl Notice {
    /// Records the notice told. A write that fails leaves it to be told
    /// again at the next call, as a notice never handed over is.
    pub(super) fn told(&self) {
        if let Some(Told { file, line }) = &self.told {
            write_told(file, line);
        }
    }
}

/// A Copilot fleet controller's session start on a home that loads no
/// context reader is told so ahead of the start's own context: without
/// the reader its context mark is never judged. The home is read, never
/// made to load one, since a hook must not change the operator's home. Any
/// other session's start is told nothing here.
pub(super) fn context_reader_check(
    turn: &mut Turn,
    vars: &Vars,
    lane: &Lane,
    payload: &Payload,
) -> Flow {
    let role = Rc::clone(&turn.role);
    let Binding::Bound(controller) = &role.binding else {
        return Ok(());
    };
    let Err(cause) = trust::copilot_reader(Path::new(&controller.home)) else {
        return Ok(());
    };
    let text = Said::ContextReaderMissing(controller.home.clone()).text(cause);
    turn.notice = Some(Box::new(Notice { text, told: None }));
    handed(turn, vars, lane, payload)
}

/// The overseer's context at each finished tool call as well as at its
/// turn end, so a mark crossed mid-turn is told at the next call: a turn
/// that runs into the window never reaches the turn end that would judge
/// it. The reading is the turn end's, recorded in the overseer mailbox, so
/// the record also moves while the overseer works; the account marks stay
/// out, since an account read at every call would cost a usage request per
/// call. What it says is handed to the model ahead of the call's own
/// answer: a reached mark, and a mark setting it cannot be judged on, at
/// every call; any other line once per session and first line, the last
/// told kept in the mailbox's told cache and cleared by a call with nothing
/// to say, so a standing gap does not fill the window it is about. The
/// controller the record lost tells its gap the same way. Only a call on a
/// named pane, in a checkout whose overseer mailbox stands, is judged.
pub(super) fn overseer_tool_check(
    turn: &mut Turn,
    vars: &Vars,
    lane: &Lane,
    payload: &Payload,
) -> Flow {
    let role = Rc::clone(&turn.role);
    let (Some(key), Some(_)) = (&role.key, &vars.tmux_pane) else {
        return Ok(());
    };
    let Ok(settings) = marks::marks_settings(turn, &lane.root, vars.private_env) else {
        return Ok(());
    };
    let mailbox = overseer_dir(&settings.roots.common);
    if !std::fs::metadata(&mailbox).is_ok_and(|meta| meta.is_dir()) {
        return Ok(());
    }
    let notes = std::mem::take(&mut turn.stderr);
    let every_call = match (&role.kind, &role.binding) {
        (Kind::Overseer, Binding::Bound(controller)) => {
            tool_judgement(turn, lane, vars, payload, key, controller, settings)
        }
        (_, Binding::Lost(controller)) => {
            lost(turn, lane, vars, payload, key, controller);
            false
        }
        (_, Binding::Bound(_) | Binding::None) => {
            turn.stderr = notes;
            return Ok(());
        }
    };
    let said = std::mem::replace(&mut turn.stderr, notes);
    let file = mailbox.join(CONTEXT_TOLD);
    let told = if every_call {
        None
    } else if said.is_empty() {
        clear_told(&file);
        return Ok(());
    } else {
        let first = said.lines().next().unwrap_or_default();
        let line = format!("{}\t{first}", payload.session);
        if told_last(&file).as_deref() == Some(line.as_str()) {
            turn.stderr.push_str(&said);
            return Ok(());
        }
        Some(Told { file, line })
    };
    let text = said.trim_end_matches('\n').to_owned();
    turn.notice = Some(Box::new(Notice { text, told }));
    handed(turn, vars, lane, payload)
}

/// The bound overseer's reading at a tool call and its context mark judged
/// on it, said on the turn's notes: `true` where a reached mark or a mark
/// setting said it. A refusal on the way is said, never held, since the
/// tool already ran. What the judgement says is dropped while this
/// session's own handoff record stands. A Pi call naming no window is the
/// wake's run or an older carrier's: it takes no reading and says nothing,
/// so the turn end's judgement stands.
fn tool_judgement(
    turn: &mut Turn,
    lane: &Lane,
    vars: &Vars,
    payload: &Payload,
    key: &Key,
    controller: &Controller,
    settings: Settings,
) -> bool {
    if turn.harness == Harness::Pi && payload.context_window.is_none() {
        return false;
    }
    let caller_key = caller_key(key);
    let mailbox = overseer_dir(&settings.roots.common);
    let seat = Seat::Overseer {
        key: caller_key.clone(),
        pane: key.pane.clone(),
        home: controller.home.clone(),
    };
    let judge = Judge::controller(lane, vars, payload, settings, PathBuf::new(), mailbox, seat);
    let every_call = match context_read(turn, &judge, payload, &controller.home, &caller_key) {
        Ok(read) => match tool_mark(turn, &judge, &read) {
            Ok(reached) => reached,
            Err(refused) => {
                turn.stderr = refused.stderr;
                true
            }
        },
        Err(refused) => {
            turn.stderr = refused.stderr;
            false
        }
    };
    if !turn.stderr.is_empty() && handoff_held(&judge.settings.state_dir, payload, &caller_key) {
        turn.stderr.clear();
        return false;
    }
    every_call
}

/// The overseer's context mark on the reading a tool call took, said on
/// the turn's notes: `true` where it is reached. A window the adapter could
/// not name below the token cap is said as the turn end says it.
fn tool_mark(turn: &mut Turn, judge: &Judge, read: &Read) -> Flow<bool> {
    let Read::Measured {
        tokens,
        window,
        model,
    } = read
    else {
        return Ok(false);
    };
    let pct = judge.context_share(turn)?;
    let marks = judge.judged_marks(turn, *tokens, *window, None)?;
    match marks["context"].as_str() {
        Some("due") => {
            let decision = marks["context_decision"].clone();
            let kind = MarkKind::Context;
            let cap = marks::decision_cap(&decision);
            let instruction = judge.instruction(turn, decision, Some(kind.word()))?;
            let said = Said::ControllerMark(Box::new(Reached {
                kind,
                value: tokens.to_string(),
                mark: pct.to_string(),
                window: window.map(|w| w.to_string()).unwrap_or_default(),
                cap,
                instruction,
            }));
            turn.note(&said, "");
            Ok(true)
        }
        Some("room") => Ok(false),
        _ => {
            let named = if model.is_empty() {
                marks::harness_word(turn.harness).to_owned()
            } else {
                model.clone()
            };
            turn.note(&Said::WindowUnread(named), "");
            Ok(false)
        }
    }
}

/// Whether the overseer's own handoff record stands, which silences its
/// tool-call judgement; a state that cannot be read silences it too, since
/// the turn end reports that under its own key.
fn handoff_held(state_dir: &Path, payload: &Payload, key: &str) -> bool {
    let Ok(standing) = handoff_standing(state_dir, OVERSEER_ITEM, None) else {
        return true;
    };
    match standing["standing"].as_str() {
        Some("stands") => handoff_mine(&standing["record"], &payload.session, key),
        Some("none") => false,
        _ => true,
    }
}

/// The rest of a call that carries a notice: the mail check, whose answer
/// carries the notice ahead of its own text, else the notice alone as the
/// call's context, recorded told once built.
fn handed(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    let Some(arm) = turn.arm.clone() else {
        return Ok(());
    };
    mail::check(turn, vars, &arm, lane, payload)?;
    let Some(notice) = turn.notice.take() else {
        return Ok(());
    };
    let event = arm.context_event().unwrap_or_default();
    let stdout = answer::context(turn.harness, event, &notice.text, None);
    turn.stderr.push_str(&notice.text);
    turn.stderr.push('\n');
    notice.told();
    Err(turn.said(&stdout))
}

/// The first line the told cache holds, `None` where it holds none.
fn told_last(file: &Path) -> Option<String> {
    let text = std::fs::read_to_string(file).ok()?;
    Some(text.lines().next().unwrap_or_default().to_owned())
}

/// The told cache's one writer: a write that fails is not said, since the
/// notice is then told again, which is what an unrecorded one is.
#[allow(
    clippy::disallowed_methods,
    reason = "the overseer tool-call notice's told cache, its one writer: a line in the overseer mailbox lane-mail keeps, never a workflow record"
)]
fn write_told(file: &Path, line: &str) {
    let _ = std::fs::write(file, format!("{line}\n"));
}

/// The told cache cleared by a call with nothing to say, so a gap that
/// comes back is told again.
#[allow(
    clippy::disallowed_methods,
    reason = "the overseer tool-call notice's told cache, its one remover: a line in the overseer mailbox lane-mail keeps, never a workflow record"
)]
fn clear_told(file: &Path) {
    let _ = std::fs::remove_file(file);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each harness's own path shape binds its transcript to the session
    /// and the launch home; a payload naming no transcript, and a harness
    /// with no shape, bind nothing; an empty session or home is a binding
    /// that cannot be made.
    #[test]
    fn a_transcript_is_bound_by_its_harness_path_shape_under_the_launch_home() {
        type Case<'a> = (Harness, &'a str, &'a str, &'a str, Result<(), &'a str>);
        let s = "abc";
        let cases: [Case; 14] = [
            (Harness::Claude, "/h/projects/p/abc.jsonl", s, "/h", Ok(())),
            (
                Harness::Claude,
                "/h/projects/p/q/abc.jsonl",
                s,
                "/h/",
                Ok(()),
            ),
            (
                Harness::Claude,
                "/h/projects/p/other.jsonl",
                s,
                "/h",
                Err("session-mismatch"),
            ),
            (
                Harness::Claude,
                "/g/projects/p/abc.jsonl",
                s,
                "/h",
                Err("home-mismatch"),
            ),
            (
                Harness::Codex,
                "/h/sessions/2026/rollout-x-abc.jsonl",
                s,
                "/h",
                Ok(()),
            ),
            (
                Harness::Codex,
                "/h/sessions/2026/x-abc.jsonl",
                s,
                "/h",
                Err("session-mismatch"),
            ),
            (
                Harness::Codex,
                "/g/sessions/rollout-x-abc.jsonl",
                s,
                "/h",
                Err("home-mismatch"),
            ),
            (
                Harness::Copilot,
                "/h/session-state/abc/events.jsonl",
                s,
                "/h",
                Ok(()),
            ),
            (
                Harness::Copilot,
                "/h/x/session-state/abc/events.jsonl",
                s,
                "/h",
                Err("home-mismatch"),
            ),
            (
                Harness::Copilot,
                "/h/session-state/zz/events.jsonl",
                s,
                "/h",
                Err("session-mismatch"),
            ),
            (Harness::Claude, "", s, "/h", Ok(())),
            (Harness::Pi, "/anywhere.jsonl", "", "", Ok(())),
            (
                Harness::Claude,
                "/h/projects/p/abc.jsonl",
                "",
                "/h",
                Err("binding-missing"),
            ),
            (
                Harness::Claude,
                "/h/projects/p/abc.jsonl",
                s,
                "",
                Err("home-unnamed"),
            ),
        ];
        for (harness, transcript, session, home, want) in cases {
            assert_eq!(
                transcript_owned(harness, transcript, session, home),
                want,
                "{harness:?} {transcript} {session} {home}"
            );
        }
    }
}
