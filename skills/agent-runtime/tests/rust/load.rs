//! `agent-runtime session load` through the executable, over one session
//! file per harness in the shape that harness records: Copilot CLI's a
//! recorded 1.0.112 log with its values blanked, the others built from the
//! sources `session::entries` names.

#[path = "isolation.rs"]
mod isolation;

use std::path::{Path, PathBuf};

use isolation::*;
use serde_json::{Value, json};

struct Row {
    harness: &'static str,
    fixture: &'static str,
    /// The context the first turn's last response left.
    start: u64,
    /// JSON pointers into the reply's `result`, each with its value.
    more: fn() -> Vec<(&'static str, Value)>,
}

const ROWS: &[Row] = &[
    Row {
        harness: "claude",
        fixture: "load/claude.jsonl",
        // msg_1: 2 + 23454 + 900 + 30; the sidechain's message is passed over.
        start: 24386,
        more: || {
            vec![
                // msg_2's prompt less msg_1's prompt and output.
                (
                    "/context/1/tokens",
                    json!({"basis": "attributed", "value": 32}),
                ),
                // msg_4's growth holds the persona.md read and turn p-3
                // together, so neither the read nor its source owns it.
                ("/sections/0/tokens", json!({"basis": "unclear"})),
                ("/context/2/source", json!("rule-reads")),
                ("/context/2/tokens", json!({"basis": "unclear"})),
            ]
        },
    },
    Row {
        harness: "codex",
        fixture: "load/codex.jsonl",
        start: 12080,
        more: Vec::new,
    },
    Row {
        harness: "copilot",
        fixture: "copilot-events.jsonl",
        // The last tool.execution_complete count in the one turn.
        start: 44644,
        more: Vec::new,
    },
    Row {
        harness: "pi",
        fixture: "load/pi.jsonl",
        start: 10070,
        more: Vec::new,
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

/// Each harness's Start is measured, and its first delivery, which shares
/// the first call with the harness's own prompt, is unsupported.
#[test]
fn session_load_reads_each_harness_record_with_each_figure_named_by_its_basis() {
    for row in ROWS {
        let (reply, out) = load(row.harness, &fixture(row.fixture));
        let result = &reply["result"];
        let mut want = vec![
            (
                "/start/tokens",
                json!({"basis": "measured", "value": row.start}),
            ),
            ("/context/0/source", json!("first-delivery")),
            ("/context/0/tokens", json!({"basis": "unsupported"})),
        ];
        want.extend((row.more)());
        for (pointer, want) in want {
            assert_eq!(
                result.pointer(pointer),
                Some(&want),
                "{}: {pointer} in {reply}\n{}",
                row.harness,
                stderr(&out)
            );
        }
    }
}

/// Pi's `/tree` writes a second child of an earlier entry into the same
/// file; read in file order, it would mix the path the session left with
/// the one it took.
#[test]
fn a_pi_session_holding_a_branch_is_refused_by_name() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("pi.jsonl");
    let rows = [
        r#"{"type":"message","id":"e1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"a"}]}}"#,
        r#"{"type":"message","id":"e2","parentId":"e1","message":{"role":"user","content":[{"type":"text","text":"b"}]}}"#,
        r#"{"type":"message","id":"e3","parentId":"e1","message":{"role":"user","content":[{"type":"text","text":"c"}]}}"#,
    ];
    std::fs::write(&file, rows.join("\n")).unwrap();
    let (reply, out) = load("pi", &file);
    assert_eq!(
        reply["refusal"]["key"],
        json!("session-branched"),
        "{reply}\n{}",
        stderr(&out)
    );
}
