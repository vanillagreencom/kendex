//! A session's own event rows: a session with no lane item, a Pi lane's
//! turn and a managed Jarvis session, each written through agent-runtime's
//! rows writer, which owns the rows' shapes, the stamps and their locks. A
//! row or a stamp that could not be written is reported and passed: a
//! session's events never stop the session.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::UNIX_EPOCH;

use agent_runtime::rows::{self, Fields, LaneRow, Launch, SessionRow, TurnEvent, Unwritten};
use serde_json::Value;

use super::answer::{Harness, Said};
use super::identity::Lane;
use super::payload::{Caller, Payload};
use super::role::{self, Key};
use super::{Arm, Flow, Turn, Vars};

/// A session with no lane item writes its own event row into the overseer
/// mailbox directory of its checkout, keyed by its pane: the row arm under
/// the event its payload or its row hook names, the overseer's turn end as
/// a Stop. A session the record keys no pane for writes none.
pub(super) fn session_row(turn: &mut Turn, vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    let role = Rc::clone(&turn.role);
    let Some(key) = &role.key else {
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
        jarvis: role.jarvis.as_ref(),
        event: &event,
        account: &account(turn.harness, vars),
        at: wall_secs(),
    };
    written.session(turn, lane, payload, rows::top_level_here(key.server));
    Ok(())
}

/// One session row's facts past the role: the key, the Jarvis launch, the
/// event its arm names, the account and the time.
struct Written<'a> {
    key: &'a Key,
    jarvis: Option<&'a role::Launch>,
    event: &'a str,
    account: &'a str,
    at: u64,
}

impl Written<'_> {
    /// The row and, at a Jarvis launch's SessionStart, its start stamp,
    /// once `top_level` says this session is its pane's top-level harness.
    /// A lane item writes no session row whichever caller asks: its rows
    /// are its own mailbox's. Nothing is written where the overseer
    /// mailbox directory is absent, since no fleet made it and no reader
    /// looks, unless a Jarvis launch awaits the start.
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
        // is no fleet's, and the Jarvis start below still runs.
        let boxed = std::fs::metadata(&dir).is_ok_and(|meta| meta.is_dir());
        if !boxed && self.jarvis.is_none() {
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
        let mut causes = Vec::new();
        if event == "SessionStart"
            && let Some(jarvis) = self.jarvis
        {
            let launch = launch(jarvis, self.key, harness);
            let started = rows::jarvis_start(
                &launch,
                session_id,
                transcript,
                self.account,
                self.at,
                rows::host_locking(),
            );
            if let Err(e) = started {
                causes.push(e.to_string());
            }
        }
        if boxed {
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
            if let Err(e) = rows::write_session(&file, &row, rows::host_locking()) {
                causes.push(e.to_string());
            }
        }
        if !causes.is_empty() {
            turn.note(&unwritten, &causes.join("\n"));
        }
    }
}

/// A Pi lane's own turn rows in its mailbox directory: a Stop at the
/// lead's turn end and a PreToolUse at the first tool call of each turn,
/// which the watch judges a Pi lane idle, working or walled from instead
/// of its pane. Only a Pi install's launched lane writes them; the pane
/// still judges a Claude Code or Codex lane.
pub(super) fn lane_row(turn: &mut Turn, _vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    let Some(item) = &lane.item else {
        return Ok(());
    };
    if turn.caller != Caller::Lead || turn.harness != Harness::Pi {
        return Ok(());
    }
    let Some(event) = turn_event(turn) else {
        return Ok(());
    };
    if !lane.launched(turn)? {
        return Ok(());
    }
    let stop = event == TurnEvent::Stop;
    let transcript = Path::new(&payload.transcript);
    let row = LaneRow {
        event,
        harness: "pi",
        at: wall_secs(),
        transcript: (stop && !payload.transcript.is_empty()).then_some(transcript),
        working_agents: payload.field("working_agents").filter(|_| stop),
    };
    let dir = lane.mail_root.join(item);
    if let Err(e) = rows::write_lane(&dir, &row, rows::host_locking()) {
        turn.note(&Said::LaneRowsUnwritten(dir), &e.to_string());
    }
    Ok(())
}

/// A managed Jarvis session's tool call or turn end stamps its launch's
/// record as the Start brief taken, or a Codex or Copilot turn end before
/// the brief as the kickoff ended, which the Jarvis launch worker reads.
/// Its own place, ahead of every check that may end the run, since a
/// Jarvis session is rarely a lane or a fleet's overseer. A Copilot call
/// no lead record vouches for stamps too: the stamp lands only under the
/// session id the record's own start bound.
pub(super) fn jarvis_row(turn: &mut Turn, _vars: &Vars, lane: &Lane, payload: &Payload) -> Flow {
    if turn.caller == Caller::Subagent || lane.item.is_some() {
        return Ok(());
    }
    let role = Rc::clone(&turn.role);
    let (Some(jarvis), Some(key)) = (&role.jarvis, &role.key) else {
        return Ok(());
    };
    let Some(event) = turn_event(turn) else {
        return Ok(());
    };
    let launch = launch(jarvis, key, harness_word(turn.harness));
    let taken = rows::jarvis_taken(
        &launch,
        event,
        either(payload, "session_id", "sessionId"),
        text(payload, "pi_run_outcome"),
        rows::host_locking(),
    );
    if let Err(e) = taken {
        turn.note(
            &Said::JarvisRowsUnwritten(jarvis.record.clone()),
            &e.to_string(),
        );
    }
    Ok(())
}

/// The turn event a turn end or a tool call stamps and rows.
fn turn_event(turn: &Turn) -> Option<TurnEvent> {
    match turn.arm {
        Some(Arm::Stop) => Some(TurnEvent::Stop),
        Some(Arm::Halt) => Some(TurnEvent::PreToolUse),
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

fn launch<'a>(jarvis: &'a role::Launch, key: &'a Key, harness: &'a str) -> Launch<'a> {
    Launch {
        record: &jarvis.record,
        generation: jarvis.generation.as_deref().unwrap_or_default(),
        server: key.server,
        pane: &key.pane,
        harness,
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
    let var = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    let home = PathBuf::from(var("LANES_HOME").unwrap_or_else(|| vars.home.clone().into()));
    let path = match harness {
        Harness::Claude => {
            var("CLAUDE_CONFIG_DIR").map_or_else(|| home.join(".claude"), PathBuf::from)
        }
        Harness::Codex => {
            let codex = var("CODEX_HOME").map_or_else(|| home.join(".codex"), PathBuf::from);
            agent_runtime::trust::account_of(&codex).to_path_buf()
        }
        Harness::Pi => vars
            .pi_dir
            .clone()
            .unwrap_or_else(|| home.join(".pi").join("agent")),
        Harness::Copilot => {
            var("COPILOT_HOME").map_or_else(|| home.join(".copilot"), PathBuf::from)
        }
        Harness::Unlisted => match (var("CLAUDE_CONFIG_DIR"), var("CODEX_HOME")) {
            (Some(_), Some(_)) | (None, None) => return String::new(),
            (Some(one), None) | (None, Some(one)) => {
                agent_runtime::trust::account_of(Path::new(&one)).to_path_buf()
            }
        },
    };
    path.display().to_string()
}

fn harness_word(harness: Harness) -> &'static str {
    match harness {
        Harness::Claude => "claude",
        Harness::Codex => "codex",
        Harness::Pi => "pi",
        Harness::Copilot => "copilot",
        Harness::Unlisted => "",
    }
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
    use crate::turnend::agents::Deadline;
    use agent_runtime::clock::SystemClock;

    fn turn(harness: Harness, arm: Arm) -> Turn {
        Turn {
            harness,
            arm: Some(arm),
            caller: Caller::Lead,
            reported: true,
            stderr: String::new(),
            ack: None,
            hook_dir: PathBuf::new(),
            deadline: Deadline::start(&SystemClock),
            role: Rc::new(role::Role::default()),
        }
    }

    /// The row arm of a session with no lane item writes its row into its
    /// checkout's overseer mailbox directory, keyed by its pane, under the
    /// event its row hook named where the payload spells none and the
    /// payload's camelCase fields; a lane item writes no session row; a
    /// session nested under another harness writes none; a process table
    /// that could not be read is reported under `rows-unwritten`; a
    /// checkout with no overseer mailbox directory writes and says nothing,
    /// unless a Jarvis launch awaits its start, which only a SessionStart
    /// stamps and whose refusal is the one cause told.
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
            jarvis: None,
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
        // A Jarvis launch's later event takes no start stamp.
        let fresh = root.path().join("fresh-session.json");
        let awaited = serde_json::json!({"harness": "copilot",
            "pending": {"generation": "g1", "server": 4242, "pane": "%5"}})
        .to_string();
        std::fs::write(&fresh, &awaited).unwrap();
        let fresh_launch = role::Launch {
            record: fresh.clone(),
            generation: Some("g1".to_owned()),
        };
        let later = Written {
            jarvis: Some(&fresh_launch),
            event: "Stop",
            ..written
        };
        later.session(&mut boxless, &lane(None), &payload, Ok(true));
        assert_eq!(std::fs::read_to_string(&fresh).unwrap(), awaited);
        assert_eq!(boxless.stderr, "");
        let record = root.path().join("jarvis-session.json");
        std::fs::write(
            &record,
            serde_json::json!({"harness": "copilot",
                "pending": {"generation": "g1", "server": 4242, "pane": "%5", "native_session_id": "pre"}})
            .to_string(),
        )
        .unwrap();
        let jarvis = role::Launch {
            record: record.clone(),
            generation: Some("g1".to_owned()),
        };
        let launched = Written {
            jarvis: Some(&jarvis),
            ..written
        };
        launched.session(&mut boxless, &lane(None), &payload, Ok(true));
        assert!(!dir.exists());
        assert_eq!(keyed(&boxless), [unwritten]);
        assert!(boxless.stderr.contains("jarvis-identity=mismatch"));
        assert!(!boxless.stderr.contains("-failed"), "{}", boxless.stderr);
    }

    fn keyed(turn: &Turn) -> Vec<String> {
        turn.stderr
            .lines()
            .filter_map(|line| line.strip_prefix("lane-mail-check: "))
            .map(str::to_owned)
            .collect()
    }

    /// A Pi install's launched lane writes a Stop row at its lead's turn
    /// end and a PreToolUse row at its tool call; a Claude Code lane, a
    /// subagent's call, a session start and a lane no launch marker binds
    /// write none; a rows
    /// file the writer cannot open is reported under `lane-rows-unwritten`.
    #[test]
    fn a_pi_lanes_turn_end_and_tool_call_write_its_rows_and_no_other_lane_does() {
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
        lane_row(&mut pi, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        assert!(!file.exists(), "no marker binds the lane");
        let marker = crate::marker::marker_path(&common, "ken-1");
        std::fs::create_dir_all(marker.parent().unwrap()).unwrap();
        std::fs::write(&marker, format!("{}\n", checkout.display())).unwrap();
        let mut claude = turn(Harness::Claude, Arm::Stop);
        lane_row(&mut claude, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        let mut subagent = turn(Harness::Pi, Arm::Halt);
        subagent.caller = Caller::Subagent;
        lane_row(&mut subagent, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        let mut start = turn(Harness::Pi, Arm::Start);
        lane_row(&mut start, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        assert!(!file.exists());
        lane_row(&mut pi, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        let mut tool = turn(Harness::Pi, Arm::Halt);
        lane_row(&mut tool, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
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
        lane_row(&mut pi, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        assert_eq!(
            keyed(&pi),
            [format!("lane-rows-unwritten={}", mailbox.display())]
        );
    }

    /// A managed Jarvis session's Codex turn end before the brief stamps
    /// its launch's kickoff end under the key and generation its role
    /// names; a subagent's turn end, a lane item's and a session start
    /// stamp nothing; a record the stamp
    /// cannot read is reported under `jarvis-rows-unwritten`.
    #[test]
    fn a_jarvis_sessions_turn_end_stamps_its_launch_and_a_subagents_nothing() {
        let root = tempfile::tempdir().unwrap();
        let record = root.path().join("jarvis-session.json");
        std::fs::write(
            &record,
            serde_json::json!({"harness": "codex", "state": "starting",
                "pending": {"generation": "g7", "server": 4242, "pane": "%3",
                    "native_session_id": "sid", "started_at": 1}})
            .to_string(),
        )
        .unwrap();
        let role = |record: &Path| {
            Rc::new(role::Role {
                key: Some(Key {
                    socket: root.path().join("socket"),
                    server: 4242,
                    start: 1,
                    pane: "%3".to_owned(),
                }),
                jarvis: Some(role::Launch {
                    record: record.to_path_buf(),
                    generation: Some("g7".to_owned()),
                }),
                ..role::Role::default()
            })
        };
        let lane = Lane {
            root: root.path().to_path_buf(),
            common: None,
            mail_root: root.path().join("tmp/lane-mail"),
            item: None,
        };
        let vars = Vars::read(false);
        let payload = Payload::decode(br#"{"session_id":"sid"}"#, false)
            .unwrap_or_else(|_| panic!("the payload decodes"));
        let pending = || -> Value {
            serde_json::from_str::<Value>(&std::fs::read_to_string(&record).unwrap()).unwrap()
                ["pending"]
                .clone()
        };
        let mut subagent = turn(Harness::Codex, Arm::Stop);
        subagent.caller = Caller::Subagent;
        subagent.role = role(&record);
        jarvis_row(&mut subagent, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        let item = Lane {
            root: root.path().to_path_buf(),
            common: None,
            mail_root: root.path().join("tmp/lane-mail"),
            item: Some("ken-1".to_owned()),
        };
        let mut in_lane = turn(Harness::Codex, Arm::Stop);
        in_lane.role = role(&record);
        jarvis_row(&mut in_lane, &vars, &item, &payload).unwrap_or_else(|_| panic!("passes"));
        let mut start = turn(Harness::Codex, Arm::Start);
        start.role = role(&record);
        jarvis_row(&mut start, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        assert_eq!(pending().get("kickoff_ended"), None);
        let mut lead = turn(Harness::Codex, Arm::Stop);
        lead.role = role(&record);
        jarvis_row(&mut lead, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        assert_eq!(pending()["kickoff_ended"], Value::Bool(true));
        assert_eq!(lead.stderr, "");
        let unreadable = root.path().join("a-directory");
        std::fs::create_dir(&unreadable).unwrap();
        lead.role = role(&unreadable);
        jarvis_row(&mut lead, &vars, &lane, &payload).unwrap_or_else(|_| panic!("passes"));
        assert_eq!(
            keyed(&lead),
            [format!("jarvis-rows-unwritten={}", unreadable.display())]
        );
    }
}
