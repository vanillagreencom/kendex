//! Each provider stop recorded on a harness reads as its kind. The fixtures
//! under `fixtures/stops/` were recorded from each installed harness against
//! a local endpoint that answered every model call with one stop: Claude
//! Code 2.1.332, Codex 0.172.0, Copilot CLI 1.0.116 (its own-provider route:
//! a Copilot account's endpoint cannot be stood in for) and Pi 1.6.1.
//!
//! - Claude Code: the StopFailure hook payload.
//! - Pi: the failed assistant row of its session file, whose `errorMessage`
//!   the carrier sends as the StopFailure's message.
//! - Codex and Copilot: the turn rows of their own session record.
//!
//! Claude Code and Pi rows go through the overseer rows writer and are read
//! back. Codex and Copilot records go through the record reader.

use std::path::{Path, PathBuf};

use std::time::Duration;

use agent_runtime::harness::Harness;
use agent_runtime::observe::{self, ProcessReading, State, WallKind};
use agent_runtime::reading::Reading;
use agent_runtime::rows::{self, Fields, Row, SessionRow};
use agent_runtime::session;
use agent_runtime::stop::reset::{self, Day};
use agent_runtime::stop::{self, Action, Ground, Kind, Session};
use serde_json::Value;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/rust/fixtures/stops")
        .join(name)
}

/// The row the writer appends for a StopFailure from `harness` with this
/// error and message, read back as the verdict reads it.
fn written(harness: &str, error: Option<&str>, message: &str) -> Row {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("session.jsonl");
    let row = SessionRow {
        event: "StopFailure",
        harness,
        account: "",
        at: 100,
        fields: Fields {
            session_id: Some("s1"),
            transcript_path: None,
            cwd: None,
            source: None,
            model: None,
            reason: None,
            error,
            error_details: None,
            message: Some(message),
        },
    };
    rows::write_session(&file, &row, rows::WAIT).unwrap();
    match rows::last_row(&file) {
        Reading::Live(row) => row,
        other => panic!("{harness} row unread: {other:?}"),
    }
}

fn row_of(name: &str) -> Row {
    let text = std::fs::read_to_string(fixture(name)).unwrap();
    let harness = name.split('-').next().unwrap();
    match harness {
        "claude" => {
            let payload: Value = serde_json::from_str(&text).unwrap();
            written(
                harness,
                payload["error"].as_str(),
                payload["last_assistant_message"].as_str().unwrap(),
            )
        }
        "pi" => {
            let entry: Value = serde_json::from_str(text.trim_end()).unwrap();
            written(
                harness,
                None,
                entry["message"]["errorMessage"].as_str().unwrap(),
            )
        }
        "codex" | "copilot" => {
            let harness = Harness::parse(harness).unwrap();
            // A Copilot session's record is the `events.jsonl` in its directory.
            let dir = tempfile::tempdir().unwrap();
            let record = dir.path().join("events.jsonl");
            std::fs::write(&record, &text).unwrap();
            match session::last_failure(harness, &record) {
                Reading::Live(Some(failure)) => rows::failure_row(harness, &failure),
                other => panic!("{name}: no failure read: {other:?}"),
            }
        }
        other => panic!("{name}: no harness {other}"),
    }
}

#[test]
fn every_recorded_stop_reads_as_its_kind() {
    let rows = [
        ("claude-overload.json", Kind::Provider),
        ("claude-stream.json", Kind::Provider),
        ("claude-network.json", Kind::Provider),
        ("claude-safety.json", Kind::Provider),
        ("claude-billing.json", Kind::Usage),
        ("codex-overload.jsonl", Kind::Provider),
        ("codex-stream.jsonl", Kind::Provider),
        ("codex-network.jsonl", Kind::Provider),
        ("codex-safety.jsonl", Kind::Provider),
        ("codex-credits.jsonl", Kind::Usage),
        ("copilot-overload.jsonl", Kind::Provider),
        ("copilot-stream.jsonl", Kind::Provider),
        ("copilot-network.jsonl", Kind::Provider),
        ("copilot-safety.jsonl", Kind::Provider),
        ("copilot-rate-limit.jsonl", Kind::Usage),
        ("copilot-quota.jsonl", Kind::Usage),
        ("pi-overload.jsonl", Kind::Provider),
        ("pi-stream.jsonl", Kind::Provider),
        ("pi-network.jsonl", Kind::Provider),
        ("pi-safety.jsonl", Kind::Provider),
        ("pi-auth.jsonl", Kind::Auth),
    ];
    for (name, kind) in rows {
        assert_eq!(rows::stop_of(&row_of(name)), Some(kind), "{name}");
    }
}

/// Codex's offers past its limit, captured from its pane: the limit-increase
/// dialog at a workspace member's usage limit, and the error line that
/// offers Pro and more credits at a Plus plan's 5-hour limit. An
/// observation, which asserts no account room, reads each as that account's
/// limit, and no action for a limit resumes the session, so no turn is
/// typed into it. The dialog stays a wall even where a caller asserts room
/// after a reset, so no key answers it.
#[test]
fn a_limit_increase_prompt_is_a_usage_limit_that_is_never_resumed() {
    for (name, room) in [
        ("codex-limit-increase.txt", None),
        ("codex-limit-increase.txt", Some(true)),
        ("codex-purchase-offer.txt", None),
    ] {
        let screen = std::fs::read_to_string(fixture(name)).unwrap();
        let state = observe::judge(&screen, Harness::Codex, &ProcessReading::HarnessUp, room);
        assert!(
            matches!(
                state,
                State::Walled {
                    kind: WallKind::Usage,
                    ..
                }
            ),
            "{name} room {room:?}: {state:?}"
        );
    }
    for session in [Session::Worker, Session::Overseer, Session::Jarvis] {
        for (own_room, room, reset) in [
            (true, true, true),
            (true, false, false),
            (false, false, true),
        ] {
            let ground = Ground {
                own_room,
                room,
                reset,
            };
            let action = stop::action(Kind::Usage, Duration::from_secs(60), session, ground);
            assert_ne!(action, Action::Resume, "{session:?} {ground:?}");
        }
    }
}

/// The purchase line stays drawn after the 5-hour window resets. A caller
/// that asserts the account has room then (`deliver --account-room`, the
/// close's lift) judges past it, and the line's banner, wrapped onto a
/// second row by the 100-column pane, keeps its reset clause.
#[test]
fn a_purchase_line_is_judged_past_on_asserted_room_and_names_its_reset() {
    let screen = std::fs::read_to_string(fixture("codex-purchase-offer.txt")).unwrap();
    let process = ProcessReading::HarnessUp;
    assert_eq!(
        observe::judge(&screen, Harness::Codex, &process, Some(true)),
        State::Idle
    );
    let State::Walled { banner, .. } = observe::judge(&screen, Harness::Codex, &process, None)
    else {
        panic!("the purchase line is no wall");
    };
    let key = reset::key(&banner).expect("the banner keeps its reset clause");
    assert_eq!((key.day, key.hour, key.minute), (Day::Clock, 13, 33));
}

/// A Codex failure whose `codex_error_info` carries data is written as an
/// object under the variant's name, and a word the table does not list is
/// still a provider stop: a failed Codex or Copilot turn never reads as none.
#[test]
fn a_codex_failure_with_an_unlisted_or_data_carrying_word_is_a_provider_stop() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("rollout.jsonl");
    std::fs::write(
        &file,
        concat!(
            r#"{"timestamp":"2026-11-26T01:17:55.743Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            "\n",
            r#"{"timestamp":"2026-11-26T01:17:55.817Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"unexpected status 502","codex_error_info":{"http_connection_failed":{"http_status_code":502}}}}}"#,
            "\n",
        ),
    )
    .unwrap();
    let Reading::Live(Some(failure)) = session::last_failure(Harness::Codex, &file) else {
        panic!("no failure read");
    };
    assert_eq!(failure.error.as_deref(), Some("http_connection_failed"));
    assert_eq!(
        rows::stop_of(&rows::failure_row(Harness::Codex, &failure)),
        Some(Kind::Provider)
    );
}

/// A Codex or Copilot record whose last turn ran after the failure holds no
/// stop: the turn that opened after it is the session's state.
#[test]
fn a_turn_opened_after_a_recorded_failure_leaves_no_stop() {
    let dir = tempfile::tempdir().unwrap();
    for (harness, name, opening) in [
        (
            Harness::Codex,
            "codex-overload.jsonl",
            r#"{"timestamp":"2026-11-26T01:18:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#,
        ),
        (
            Harness::Copilot,
            "copilot-overload.jsonl",
            r#"{"type":"user.message","data":{"content":"Go on."},"id":"m2","timestamp":"2026-11-26T01:20:00.000Z"}"#,
        ),
    ] {
        let file = dir.path().join(match harness {
            Harness::Copilot => "events.jsonl".to_owned(),
            Harness::Claude | Harness::Codex | Harness::Pi => name.to_owned(),
        });
        let mut text = std::fs::read_to_string(fixture(name)).unwrap();
        text.push_str(opening);
        text.push('\n');
        std::fs::write(&file, text).unwrap();
        assert_eq!(
            session::last_failure(harness, &file),
            Reading::Live(None),
            "{name}"
        );
    }
}
