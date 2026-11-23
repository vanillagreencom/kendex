//! `agent-runtime session load` through the executable, over one session
//! file per harness in the shape that harness records: Copilot CLI's a
//! recorded 1.0.112 log with its values blanked, the others built from the
//! sources `session::entries` names. Each row checks the native turn its
//! Start reads, one measured figure and one unsupported field.

#[path = "isolation.rs"]
mod isolation;

use std::path::{Path, PathBuf};

use isolation::*;
use serde_json::{Value, json};

struct Row {
    name: &'static str,
    harness: &'static str,
    fixture: &'static str,
    /// JSON pointers into the reply's `result`, each with its value.
    expect: fn() -> Vec<(&'static str, Value)>,
}

fn unsupported_first_delivery() -> (&'static str, Value) {
    (
        "/context/0",
        json!({"source": "first-delivery", "items": 1, "unattributed": 1,
            "bytes": {"basis": "measured", "value": 18},
            "tokens": {"basis": "unsupported", "cause": "first-call-holds-harness-prompt"}}),
    )
}

const ROWS: &[Row] = &[
    Row {
        name: "claude: the promptId turn, a message spanning lines, a sidechain passed over",
        harness: "claude",
        fixture: "load/claude.jsonl",
        expect: || {
            vec![
                ("/turns", json!(2)),
                ("/start/turn", json!("p-1")),
                // msg_3, the turn's last response: 2 + 23454 + 900 + 30.
                (
                    "/start/tokens",
                    json!({"basis": "measured", "value": 24386}),
                ),
                (
                    "/context/0/tokens",
                    json!({"basis": "unsupported", "cause": "first-call-holds-harness-prompt"}),
                ),
                // The turn and the skill text beside it.
                ("/context/0/bytes/value", json!(73)),
                // msg_4's prompt less msg_3's prompt and output.
                (
                    "/context/1/tokens",
                    json!({"basis": "attributed", "value": 32}),
                ),
                (
                    "/sections/0",
                    json!({"turn": "p-1", "call": "toolu_1",
                        "read": {"kind": "section", "file": "state/handoff.md", "heading": "State"},
                        "bytes": {"basis": "measured", "value": 23},
                        "tokens": {"basis": "attributed", "value": 302}}),
                ),
                // A rule read and a tool result between one pair of responses.
                (
                    "/sections/1/tokens",
                    json!({"basis": "unclear", "cause": "shared-gap"}),
                ),
                (
                    "/context/3/tokens",
                    json!({"basis": "unclear", "cause": "shared-gap"}),
                ),
            ]
        },
    },
    Row {
        name: "codex: the item's turn_id, an exec_command section, a custom tool's output",
        harness: "codex",
        fixture: "load/codex.jsonl",
        expect: || {
            vec![
                ("/start/turn", json!("t-1")),
                (
                    "/start/tokens",
                    json!({"basis": "measured", "value": 12720}),
                ),
                unsupported_first_delivery(),
                (
                    "/sections/0",
                    json!({"turn": "t-1", "call": "call_1",
                        "read": {"kind": "section", "file": "skills/jarvis/persona.md", "heading": "Conduct"},
                        "bytes": {"basis": "measured", "value": 22},
                        "tokens": {"basis": "attributed", "value": 420}}),
                ),
                (
                    "/context/3/tokens",
                    json!({"basis": "attributed", "value": 160}),
                ),
            ]
        },
    },
    Row {
        name: "copilot: the interactionId turn and the CLI's own count of each result",
        harness: "copilot",
        fixture: "copilot-events.jsonl",
        expect: || {
            vec![
                ("/start/turn", json!("00000000-0000-4000-8000-000000000004")),
                // The last tool.execution_complete count in the one turn.
                (
                    "/start/tokens",
                    json!({"basis": "measured", "value": 44644}),
                ),
                (
                    "/context/0/tokens",
                    json!({"basis": "unsupported", "cause": "first-call-holds-harness-prompt"}),
                ),
                (
                    "/sections/0",
                    json!({"turn": "00000000-0000-4000-8000-000000000004", "call": "id-0009",
                        "read": {"kind": "skill", "name": "x"},
                        "bytes": {"basis": "measured", "value": 1},
                        "tokens": {"basis": "measured", "value": 27}}),
                ),
                // The failed call and the task result carry no count.
                (
                    "/context/3",
                    json!({"source": "tool-results", "items": 4, "unattributed": 2,
                        "bytes": {"basis": "measured", "value": 4},
                        "tokens": {"basis": "measured", "value": 2033}}),
                ),
            ]
        },
    },
    Row {
        name: "pi: the entry id turn and a read call's result",
        harness: "pi",
        fixture: "load/pi.jsonl",
        expect: || {
            vec![
                ("/start/turn", json!("e1")),
                (
                    "/start/tokens",
                    json!({"basis": "measured", "value": 10600}),
                ),
                unsupported_first_delivery(),
                (
                    "/sections/0",
                    json!({"turn": "e1", "call": "call_1",
                        "read": {"kind": "file", "file": "skills/jarvis/persona.md"},
                        "bytes": {"basis": "measured", "value": 20},
                        "tokens": {"basis": "attributed", "value": 510}}),
                ),
            ]
        },
    },
];

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/rust/fixtures")
        .join(name)
}

fn load(harness: &str, file: &Path) -> (Value, std::process::Output) {
    let out = program(env!("CARGO_BIN_EXE_agent-runtime"))
        .args(["session", "load", "--harness", harness, "--file"])
        .arg(file)
        .output()
        .unwrap();
    let reply = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    (reply, out)
}

#[test]
fn session_load_reads_each_harness_record_with_each_figure_named_by_its_basis() {
    for row in ROWS {
        let (reply, out) = load(row.harness, &fixture(row.fixture));
        assert_eq!(
            reply["ok"],
            json!(true),
            "{}: {reply}\n{}",
            row.name,
            stderr(&out)
        );
        let result = &reply["result"];
        assert_eq!(result["harness"], json!(row.harness), "{}", row.name);
        for (pointer, want) in (row.expect)() {
            assert_eq!(
                result.pointer(pointer),
                Some(&want),
                "{}: {pointer} in {result}",
                row.name
            );
        }
    }
}

/// A Pi file holds a tree; read in file order, a branch would mix the path
/// the session left with the one it took.
#[test]
fn a_pi_session_holding_a_branch_is_refused_by_name() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("pi.jsonl");
    let rows = [
        r#"{"type":"session","version":3,"id":"s1","cwd":"/w"}"#,
        r#"{"type":"message","id":"e1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"a"}]}}"#,
        r#"{"type":"message","id":"e2","parentId":"e1","message":{"role":"user","content":[{"type":"text","text":"b"}]}}"#,
        r#"{"type":"message","id":"e3","parentId":"e1","message":{"role":"user","content":[{"type":"text","text":"c"}]}}"#,
    ];
    std::fs::write(&file, rows.join("\n")).unwrap();
    let (reply, out) = load("pi", &file);
    assert_eq!(reply["ok"], json!(false), "{reply}");
    assert_eq!(
        reply["refusal"]["key"],
        json!("session-branched"),
        "{reply}\n{}",
        stderr(&out)
    );
    assert_eq!(out.status.code(), Some(1));
}
