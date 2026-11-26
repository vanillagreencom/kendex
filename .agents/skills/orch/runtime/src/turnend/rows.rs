//! A session's own event rows: a session with no lane item and a lane's
//! turn, each written through agent-runtime's
//! rows writer, which owns the rows' shapes, the stamps and their locks. A
//! row or a stamp that could not be written is reported and passed: a
//! session's events never stop the session.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::UNIX_EPOCH;

use agent_runtime::rows::{self, Fields, LaneRow, SessionRow, TurnEvent, Unwritten};
use serde_json::Value;

use super::answer::{Harness, Said};
use super::identity::{Lane, Seat};
use super::marks::harness_word;
use super::payload::{Caller, Payload};
use super::role::Key;
use super::{Arm, Flow, Turn, Vars};

/// A session with no lane item writes its own event row into the overseer
/// mailbox directory of its checkout, keyed by its pane: the row arm under
/// the event its payload or its row hook names, the overseer's turn end as
/// a Stop. A session the record keys no pane for writes none; a named pane
/// whose server did not answer is told, ahead of the box, the top-level
/// and the subagent checks, so those checks cannot hide an unavailable key.
pub(super) fn session_row(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    let role = Rc::clone(&turn.role);
    let Some(key) = &role.key else {
        if let Some(cause) = &role.unkeyed {
            turn.note(&Said::RowsUnwritten(lane.root.clone()), cause);
        }
        return Ok(());
    };
    let event = match &turn.arm {
        Some(Arm::Row { event }) => event.clone(),
        Some(Arm::Stop) => "Stop".to_owned(),
        Some(
            Arm::ModelSwitch
            | Arm::Halt
            | Arm::Compact
            | Arm::Usage
            | Arm::Lane
            | Arm::Deliver
            | Arm::Start
            | Arm::Prompt,
        )
        | None => return Ok(()),
    };
    let written = Written {
        key,
        event: &event,
        account: &account(turn.harness, vars),
        at: wall_secs(),
    };
    written.session(turn, lane, payload, rows::top_level_here(key.server));
    Ok(())
}

/// One session row's facts past the role: the key, the event its arm
/// names, the account and the time.
struct Written<'a> {
    key: &'a Key,
    event: &'a str,
    account: &'a str,
    at: u64,
}

impl Written<'_> {
    /// The row, once `top_level` says this session is its pane's
    /// top-level harness. A lane item writes no session row whichever
    /// caller asks: its rows are its own mailbox's. Nothing is written where
    /// the overseer mailbox directory is absent, since no fleet made it and
    /// no reader looks.
    fn session(
        &self,
        turn: &mut Turn,
        lane: &Lane,
        payload: &Payload,
        top_level: Result<bool, Unwritten>,
    ) {
        if lane.item.is_some() {
            return;
        }
        let dir = overseer_box(lane);
        // Read as the shell's `-d` reads it: a directory this cannot read
        // is no fleet's.
        if !std::fs::metadata(&dir).is_ok_and(|meta| meta.is_dir()) {
            return;
        }
        let unwritten = Said::RowsUnwritten(lane.root.clone());
        match top_level {
            Ok(true) => {}
            Ok(false) => return,
            Err(e) => return turn.note(&unwritten, &e.to_string()),
        }
        if payload.caller == Caller::Subagent {
            return;
        }
        let event = text(payload, "hook_event_name").unwrap_or(self.event);
        if event.is_empty() {
            return turn.note(&unwritten, &Unwritten::EventUnnamed.to_string());
        }
        let harness = harness_word(turn.harness);
        let session_id = either(payload, "session_id", "sessionId");
        let transcript = either(payload, "transcript_path", "transcriptPath");
        let row = SessionRow {
            event,
            harness,
            account: self.account,
            at: self.at,
            fields: Fields {
                session_id,
                transcript_path: transcript,
                cwd: text(payload, "cwd"),
                source: text(payload, "source"),
                model: text(payload, "model"),
                reason: text(payload, "reason"),
                error: text(payload, "error"),
                error_details: text(payload, "error_details"),
                message: text(payload, "last_assistant_message"),
            },
        };
        let file = rows::session_file(&dir, self.key.server, &self.key.pane);
        if let Err(e) = rows::write_session(&file, &row, rows::WAIT) {
            turn.note(&unwritten, &e.to_string());
        }
    }
}

/// The lane's events follow the answer: a held Stop keeps the turn open,
/// and only a passed Stop closes it. A call outside the lane's lead never
/// changes the lead's turn.
pub(super) fn lane_row(
    turn: &mut Turn,
    _vars: &Vars,
    lane: &Lane,
    payload: &Payload,
    held: bool,
) -> Flow {
    let Some(item) = &lane.item else {
        return Ok(());
    };
    if turn.caller != Caller::Lead
        || turn.seat == Seat::Elsewhere
        || turn.harness == Harness::Unlisted
    {
        return Ok(());
    }
    let Some(event) = turn_event(turn, payload, held) else {
        return Ok(());
    };
    if !lane.launched(turn)? {
        return Ok(());
    }
    let pi_stop = event == TurnEvent::Stop && turn.harness == Harness::Pi;
    let transcript = Path::new(&payload.transcript);
    let row = LaneRow {
        event,
        harness: harness_word(turn.harness),
        at: wall_secs(),
        transcript: (pi_stop && !payload.transcript.is_empty()).then_some(transcript),
        working_agents: payload.field("working_agents").filter(|_| pi_stop),
    };
    let dir = lane.mail_root.join(item);
    if let Err(e) = rows::write_lane(&dir, &row, rows::WAIT) {
        turn.note(&Said::LaneRowsUnwritten(dir), &e.to_string());
    }
    Ok(())
}

fn turn_event<'a>(turn: &Turn, payload: &'a Payload, held: bool) -> Option<TurnEvent<'a>> {
    match &turn.arm {
        Some(Arm::Stop) => Some(if held {
            TurnEvent::PreToolUse
        } else {
            TurnEvent::Stop
        }),
        Some(Arm::Halt) => Some(TurnEvent::PreToolUse),
        Some(Arm::Prompt) if turn.harness != Harness::Pi => Some(TurnEvent::Prompt {
            digest: text(payload, "prompt").map(agent_runtime::session::text_digest),
        }),
        // The lane row keeps no message, so the word names a safety
        // refusal apart from the other `invalid_request` refusals.
        Some(Arm::Row { event }) if event == "StopFailure" && turn.harness == Harness::Claude => {
            Some(TurnEvent::StopFailure {
                error: agent_runtime::stop::claude_failure_word(
                    text(payload, "error"),
                    text(payload, "last_assistant_message").unwrap_or_default(),
                ),
            })
        }
        Some(
            Arm::ModelSwitch
            | Arm::Compact
            | Arm::Usage
            | Arm::Lane
            | Arm::Row { .. }
            | Arm::Deliver
            | Arm::Start
            | Arm::Prompt,
        )
        | None => None,
    }
}

/// The overseer mailbox directory of the checkout the lane's root is in:
/// `tmp/lane-mail/overseer` at its main checkout, the directory above a
/// common git directory named `.git`, else at the root itself.
fn overseer_box(lane: &Lane) -> PathBuf {
    let main = lane
        .common
        .as_deref()
        .filter(|common| common.file_name().is_some_and(|name| name == ".git"))
        .and_then(Path::parent)
        .unwrap_or(&lane.root);
    main.join("tmp").join("lane-mail").join("overseer")
}

/// The account a session of `harness` runs on, read from this process's
/// environment, which is the harness's own: its home variable, else the
/// harness's default under the home; a Codex home a launch built under an
/// account names that account. An install naming no harness takes the one
/// home variable set of Claude Code's and Codex's, and none where both or
/// neither is.
fn account(harness: Harness, vars: &Vars) -> String {
    use agent_runtime::harness::Harness as Native;
    let var = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    let home = |native| super::model::harness_home(native, vars);
    let path = match harness {
        Harness::Claude => home(Native::Claude),
        Harness::Codex => {
            let codex = home(Native::Codex);
            agent_runtime::trust::account_of(&codex).to_path_buf()
        }
        Harness::Pi => home(Native::Pi),
        Harness::Copilot => home(Native::Copilot),
        Harness::Unlisted => match (var("CLAUDE_CONFIG_DIR"), var("CODEX_HOME")) {
            (Some(_), Some(_)) | (None, None) => return String::new(),
            (Some(one), None) | (None, Some(one)) => {
                agent_runtime::trust::account_of(Path::new(&one)).to_path_buf()
            }
        },
    };
    path.display().to_string()
}

/// The payload's `name` where it is a string.
fn text<'p>(payload: &'p Payload, name: &str) -> Option<&'p str> {
    payload.field(name).and_then(Value::as_str)
}

/// `first`, else `second` where `first` is absent, `null` or `false`, read
/// as a string: a Claude Code field and its Copilot camelCase spelling.
fn either<'p>(payload: &'p Payload, first: &str, second: &str) -> Option<&'p str> {
    payload
        .field(first)
        .filter(|value| !matches!(value, Value::Null | Value::Bool(false)))
        .or_else(|| payload.field(second))
        .and_then(Value::as_str)
}

/// The epoch second a row and a start stamp are written at.
#[allow(
    clippy::disallowed_methods,
    reason = "a row's and a start stamp's `at`, the wall clock's epoch second the watch dates a turn by"
)]
fn wall_secs() -> u64 {
    super::wall_now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the row plants a checkout's overseer mailbox directory and reads the rows file the writer made"
)]
mod tests {
    use super::*;

    fn turn(harness: Harness, arm: Arm) -> Turn {
        Turn {
            arm: Some(arm),
            reported: true,
            ..Turn::new(harness, PathBuf::new())
        }
    }

    /// The row arm of a session with no lane item writes its row into its
    /// checkout's overseer mailbox directory, keyed by its pane, under the
    /// event its row hook named where the payload spells none and the
    /// payload's camelCase fields; a lane item writes no session row; a
    /// session nested under another harness writes none; a process table
    /// that could not be read is reported under `rows-unwritten`; a
    /// checkout with no overseer mailbox directory writes and says nothing.
    #[test]
    fn the_row_arm_writes_a_session_row_and_a_lane_writes_none() {
        let root = tempfile::tempdir().unwrap();
        let checkout = root.path().join("fleet");
        let dir = checkout.join("tmp/lane-mail/overseer");
        std::fs::create_dir_all(&dir).unwrap();
        let key = Key {
            socket: root.path().join("socket"),
            server: 4242,
            start: 1,
            pane: "%5".to_owned(),
        };
        let written = Written {
            key: &key,
            event: "SessionStart",
            account: "/h/.copilot",
            at: 3,
        };
        let payload = Payload::decode(br#"{"sessionId":"c1","transcriptPath":"/t/c1"}"#, false)
            .unwrap_or_else(|_| panic!("the payload decodes"));
        let lane = |item: Option<&str>| Lane {
            root: checkout.clone(),
            common: Some(checkout.join(".git")),
            mail_root: checkout.join("tmp/lane-mail"),
            item: item.map(str::to_owned),
        };
        let file = dir.join("session-4242-5.jsonl");
        let mut row_turn = turn(
            Harness::Copilot,
            Arm::Row {
                event: "SessionStart".to_owned(),
            },
        );
        written.session(&mut row_turn, &lane(Some("ken-1")), &payload, Ok(true));
        assert!(!file.exists());
        written.session(&mut row_turn, &lane(None), &payload, Ok(false));
        assert!(!file.exists());
        written.session(&mut row_turn, &lane(None), &payload, Ok(true));
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "{\"at\":3,\"event\":\"SessionStart\",\"harness\":\"copilot\",\"session_id\":\"c1\",\"transcript_path\":\"/t/c1\",\"account\":\"/h/.copilot\"}\n"
        );
        assert_eq!(row_turn.stderr, "");
        written.session(
            &mut row_turn,
            &lane(None),
            &payload,
            Err(Unwritten::TableUnread("proc-unreadable")),
        );
        let unwritten = format!("rows-unwritten={}", checkout.display());
        assert_eq!(keyed(&row_turn), std::slice::from_ref(&unwritten));

        let rows_before = std::fs::read_to_string(&file).unwrap();
        let subagent = Payload::decode(br#"{"agent_id":"a1","sessionId":"c1"}"#, false)
            .unwrap_or_else(|_| panic!("the payload decodes"));
        let mut quiet = turn(
            Harness::Copilot,
            Arm::Row {
                event: "SessionStart".to_owned(),
            },
        );
        written.session(&mut quiet, &lane(None), &subagent, Ok(true));
        let unnamed = Written {
            event: "",
            ..written
        };
        unnamed.session(&mut quiet, &lane(None), &payload, Ok(true));
        assert_eq!(std::fs::read_to_string(&file).unwrap(), rows_before);
        assert_eq!(keyed(&quiet), std::slice::from_ref(&unwritten));

        std::fs::remove_file(&file).unwrap();
        std::fs::remove_dir(&dir).unwrap();
        let mut boxless = turn(
            Harness::Copilot,
            Arm::Row {
                event: "SessionStart".to_owned(),
            },
        );
        written.session(&mut boxless, &lane(None), &payload, Ok(true));
        written.session(
            &mut boxless,
            &lane(None),
            &payload,
            Err(Unwritten::TableUnread("proc-unreadable")),
        );
        assert_eq!(boxless.stderr, "");
    }

    /// Claude Code 2.1.332's StopFailure payload for a safety refusal
    /// (`claude-safety.json`, recorded against an injected refusal) writes a
    /// lane row the lane verdict reads as idle on a refusal, which the
    /// fleet watch continues like any provider stop.
    #[test]
    fn a_claude_safety_refusal_writes_a_lane_row_read_as_a_refusal() {
        let root = tempfile::tempdir().unwrap();
        let checkout = root.path().join("lane");
        let common = checkout.join(".git");
        let mailbox = checkout.join("tmp/lane-mail/ken-1");
        std::fs::create_dir_all(&mailbox).unwrap();
        let marker = crate::marker::marker_path(&common, "ken-1");
        std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
        std::fs::write(&marker, format!("{}\n", checkout.display())).unwrap();
        let lane = Lane {
            root: checkout.clone(),
            common: Some(common),
            mail_root: checkout.join("tmp/lane-mail"),
            item: Some("ken-1".to_owned()),
        };
        let payload = Payload::decode(
            include_bytes!(
                "../../../../agent-runtime/tests/rust/fixtures/stops/claude-safety.json"
            ),
            false,
        )
        .unwrap_or_else(|_| panic!("the payload decodes"));
        let mut failed = turn(
            Harness::Claude,
            Arm::Row {
                event: "StopFailure".to_owned(),
            },
        );
        lane_row(&mut failed, &Vars::read(false), &lane, &payload, false)
            .unwrap_or_else(|_| panic!("passes"));
        let agent_runtime::reading::Reading::Live(row) =
            rows::last_row(&mailbox.join(rows::LANE_FILE))
        else {
            panic!("no lane row written");
        };
        assert_eq!(
            rows::judge_lane(&row),
            agent_runtime::reading::Reading::Live(rows::LaneVerdict::Idle {
                cause: Some(agent_runtime::stop::REFUSAL.to_owned()),
            })
        );
    }

    fn keyed(turn: &Turn) -> Vec<String> {
        turn.stderr
            .lines()
            .filter_map(|line| line.strip_prefix("lane-mail-check: "))
            .map(str::to_owned)
            .collect()
    }

    /// An unlaunched lane and calls outside its lead write none; a file
    /// the writer cannot open is reported under `lane-rows-unwritten`.
    #[test]
    fn lane_rows_require_a_launched_lead_and_report_an_unwritable_file() {
        let root = tempfile::tempdir().unwrap();
        let checkout = root.path().join("lane");
        let common = checkout.join(".git");
        let mailbox = checkout.join("tmp/lane-mail/ken-1");
        std::fs::create_dir_all(&mailbox).unwrap();
        let lane = Lane {
            root: checkout.clone(),
            common: Some(common.clone()),
            mail_root: checkout.join("tmp/lane-mail"),
            item: Some("ken-1".to_owned()),
        };
        let vars = Vars::read(false);
        let payload = Payload::decode(br#"{"working_agents":0}"#, false)
            .unwrap_or_else(|_| panic!("the payload decodes"));
        let file = mailbox.join(rows::LANE_FILE);
        let mut pi = turn(Harness::Pi, Arm::Stop);
        lane_row(&mut pi, &vars, &lane, &payload, false).unwrap_or_else(|_| panic!("passes"));
        assert!(!file.exists(), "no marker binds the lane");
        let marker = crate::marker::marker_path(&common, "ken-1");
        std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
        std::fs::write(&marker, format!("{}\n", checkout.display())).unwrap();
        let mut elsewhere = turn(Harness::Claude, Arm::Prompt);
        elsewhere.seat = Seat::Elsewhere;
        lane_row(&mut elsewhere, &vars, &lane, &payload, false)
            .unwrap_or_else(|_| panic!("passes"));
        let mut subagent = turn(Harness::Pi, Arm::Halt);
        subagent.caller = Caller::Subagent;
        lane_row(&mut subagent, &vars, &lane, &payload, false).unwrap_or_else(|_| panic!("passes"));
        let mut start = turn(Harness::Pi, Arm::Start);
        lane_row(&mut start, &vars, &lane, &payload, false).unwrap_or_else(|_| panic!("passes"));
        assert!(!file.exists());
        lane_row(&mut pi, &vars, &lane, &payload, false).unwrap_or_else(|_| panic!("passes"));
        let mut tool = turn(Harness::Pi, Arm::Halt);
        lane_row(&mut tool, &vars, &lane, &payload, false).unwrap_or_else(|_| panic!("passes"));
        let events: Vec<Value> = std::fs::read_to_string(&file)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .map(|row| serde_json::json!([row["event"], row["harness"], row["working_agents"]]))
            .collect();
        assert_eq!(
            events,
            [
                serde_json::json!(["Stop", "pi", 0]),
                serde_json::json!(["PreToolUse", "pi", null]),
            ]
        );
        assert_eq!(pi.stderr, "");
        std::fs::remove_file(&file).unwrap();
        std::fs::create_dir(&file).unwrap();
        lane_row(&mut pi, &vars, &lane, &payload, false).unwrap_or_else(|_| panic!("passes"));
        assert_eq!(
            keyed(&pi),
            [format!("lane-rows-unwritten={}", mailbox.display())]
        );
    }
}
