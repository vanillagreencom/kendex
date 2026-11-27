//! `agent-runtime session load` through the executable, over session files
//! in the shape each harness records. Copilot CLI has a recorded 1.0.112
//! log with its values blanked and a built file; every other harness's
//! file is built from the sources `session::entries` and
//! `context::response` name.

#[path = "isolation.rs"]
mod isolation;

use std::path::{Path, PathBuf};

use isolation::*;
use serde_json::{Value, json};

struct Row {
    harness: &'static str,
    fixture: &'static str,
    /// The fixture's first lines alone, as a session's file stands while
    /// the harness still writes it.
    head: Option<usize>,
    /// The context the first turn's last response left, `None` where that
    /// response's writer never counted it.
    start: Option<u64>,
    /// JSON pointers into the reply's `result`, each with its value: `null`
    /// where the pointer names nothing.
    more: fn() -> Vec<(&'static str, Value)>,
}

const ROWS: &[Row] = &[
    Row {
        harness: "claude",
        fixture: "load/claude.jsonl",
        head: None,
        // msg_1: 2 + 23454 + 900 + 30; the sidechain's message is passed over.
        start: Some(24386),
        more: || {
            vec![
                // The Stop hook's reply is no turn.
                ("/turns", json!(3)),
                // msg_2's prompt less msg_1's prompt and output.
                (
                    "/context/1/tokens",
                    json!({"basis": "attributed", "value": 32}),
                ),
                // p-2's command record as written, not as typed, and p-3.
                (
                    "/context/1/bytes",
                    json!({"basis": "measured", "value": 127 + 10}),
                ),
                // msg_4's growth holds the persona.md read and turn p-3
                // together, so neither the read nor its source owns it.
                ("/sections/0/tokens", json!({"basis": "unclear"})),
                // msg_8's, msg_10's, msg_14's and msg_16's growth, each a
                // call's alone, and msg_12's, shared by the two failed reads
                // of msg_11.
                ("/context/2/source", json!("rule-reads")),
                (
                    "/context/2/tokens",
                    json!({"basis": "attributed", "value": 33 + 40 + 22 + 28 + 30}),
                ),
                ("/context/2/unattributed", json!(1)),
                // msg_6's growth, shared by the two results of msg_5.
                ("/context/3/source", json!("tool-results")),
                (
                    "/context/3/tokens",
                    json!({"basis": "attributed", "value": 52}),
                ),
                // One `cat` of two files, then one beside an `ls`.
                ("/sections/1/read", json!({"kind": "file", "file": "a.md"})),
                ("/sections/1/tokens", json!({"basis": "unclear"})),
                ("/sections/2/read", json!({"kind": "file", "file": "b.md"})),
                ("/sections/2/bytes", json!({"basis": "unclear"})),
                ("/sections/3/read", json!({"kind": "file", "file": "c.md"})),
                ("/sections/3/tokens", json!({"basis": "unclear"})),
                // The failed read and `jarvis-section` of msg_11 read no
                // section. msg_13's command printed its section before its
                // `ls` failed, so the section stands, its share unclear.
                (
                    "/sections/4/read",
                    json!({"kind": "section", "file": "persona.md", "heading": "Role"}),
                ),
                ("/sections/4/tokens", json!({"basis": "unclear"})),
                // msg_15's `cat` failed on its second file after printing
                // its first, so both reads stand, their shares unclear.
                (
                    "/sections/5/read",
                    json!({"kind": "file", "file": "AGENTS.md"}),
                ),
                ("/sections/5/tokens", json!({"basis": "unclear"})),
                (
                    "/sections/6/read",
                    json!({"kind": "file", "file": "CLAUDE.md"}),
                ),
                ("/sections/7", Value::Null),
                // The Stop hook's reply, alone before msg_3.
                ("/context/4/source", json!("injected-text")),
                (
                    "/context/4/bytes",
                    json!({"basis": "measured", "value": 87}),
                ),
                (
                    "/context/4/tokens",
                    json!({"basis": "attributed", "value": 12}),
                ),
            ]
        },
    },
    Row {
        harness: "codex",
        fixture: "load/codex.jsonl",
        head: None,
        // The turn's second response; the event between repeats the first.
        start: Some(12540),
        more: || {
            vec![
                // The UserMessage's text.
                (
                    "/context/0/bytes",
                    json!({"basis": "measured", "value": 18}),
                ),
                (
                    "/sections/0/read",
                    json!({"kind": "file", "file": "a/SKILL.md"}),
                ),
                // The second response's prompt less the first's whole.
                (
                    "/sections/0/tokens",
                    json!({"basis": "attributed", "value": 420}),
                ),
            ]
        },
    },
    Row {
        harness: "copilot",
        fixture: "copilot-events.jsonl",
        head: None,
        // The turn's last session.usage_record, its prompt and output. The
        // CLI's own count on the last tool row, 44644, is older than the
        // turn's last calls.
        start: Some(290886 + 96),
        more: || {
            vec![
                ("/sections/0/read", json!({"kind": "skill", "name": "x"})),
                // A skill's result is not its body.
                ("/sections/0/bytes", json!({"basis": "unclear"})),
                ("/context/2/source", json!("rule-reads")),
                ("/context/2/bytes", json!({"basis": "unclear"})),
                ("/context/2/tokens", json!({"basis": "unsupported"})),
                // The two results the CLI counted; the failure and the
                // sub-agent's result carry no count.
                ("/context/3/source", json!("tool-results")),
                (
                    "/context/3/tokens",
                    json!({"basis": "measured", "value": 60 + 1973}),
                ),
                ("/context/3/unattributed", json!(2)),
            ]
        },
    },
    Row {
        harness: "copilot",
        fixture: "load/copilot.jsonl",
        head: None,
        // u3: the background call after it has a prompt of its own.
        start: Some(20100 + 30),
        more: || {
            vec![
                // The turn as the CLI sent it, its datetime included.
                (
                    "/context/0/bytes",
                    json!({"basis": "measured", "value": 77}),
                ),
                (
                    "/sections/0/read",
                    json!({"kind": "file", "file": "/w/a/SKILL.md"}),
                ),
                (
                    "/sections/0/tokens",
                    json!({"basis": "measured", "value": 12}),
                ),
                (
                    "/sections/1/read",
                    json!({"kind": "file", "file": "/w/b/SKILL.md"}),
                ),
                (
                    "/sections/1/tokens",
                    json!({"basis": "measured", "value": 9}),
                ),
                // The failed view reads no section. u3's growth also holds
                // b's counted result, so the failed view's share of it is
                // unclear.
                ("/sections/2", Value::Null),
                (
                    "/context/2/tokens",
                    json!({"basis": "measured", "value": 12 + 9}),
                ),
                ("/context/2/unattributed", json!(1)),
            ]
        },
    },
    Row {
        harness: "copilot",
        fixture: "load/copilot.jsonl",
        // Cut before u3: the open gap keeps b's counted result.
        head: Some(10),
        start: Some(20060 + 25),
        more: || {
            vec![
                (
                    "/sections/1/tokens",
                    json!({"basis": "measured", "value": 9}),
                ),
                (
                    "/context/2/tokens",
                    json!({"basis": "measured", "value": 12 + 9}),
                ),
                ("/context/2/unattributed", json!(1)),
            ]
        },
    },
    Row {
        harness: "pi",
        fixture: "load/pi.jsonl",
        head: None,
        // e4, after the reads' results and the wake event.
        start: Some(10520),
        more: || {
            vec![
                // The turn alone: the extension's text after it is injected
                // text.
                (
                    "/context/0/bytes",
                    json!({"basis": "measured", "value": 18}),
                ),
                // e4's growth holds the reads' results and the wake event
                // after them, which is not the read's.
                (
                    "/sections/0/read",
                    json!({"kind": "file", "file": "a/SKILL.md"}),
                ),
                ("/sections/0/tokens", json!({"basis": "unclear"})),
                // e15's growth holds the output of e13, whose pi-codex
                // usage is the bridge's placeholder, beside both reads.
                ("/context/2/source", json!("rule-reads")),
                ("/context/2/tokens", json!({"basis": "unclear"})),
                // The failed read of e2 reads no section.
                (
                    "/sections/1/read",
                    json!({"kind": "file", "file": "b/SKILL.md"}),
                ),
                (
                    "/sections/2/read",
                    json!({"kind": "file", "file": "c/SKILL.md"}),
                ),
                ("/sections/2/tokens", json!({"basis": "unclear"})),
                ("/sections/3", Value::Null),
                // e6's growth holds turn e5 and the hook's text after it.
                ("/context/1/tokens", json!({"basis": "unclear"})),
                // e9's growth holds two results and the wake event after
                // them; e11's is the one result after it, alone.
                ("/context/3/source", json!("tool-results")),
                (
                    "/context/3/tokens",
                    json!({"basis": "attributed", "value": 18}),
                ),
                ("/context/3/unattributed", json!(2)),
                // The four custom_message texts.
                ("/context/4/source", json!("injected-text")),
                (
                    "/context/4/bytes",
                    json!({"basis": "measured", "value": 13 + 15 + 13 + 15}),
                ),
            ]
        },
    },
    Row {
        harness: "pi",
        fixture: "load/pi-uncounted.jsonl",
        head: None,
        // The first turn goes on past e2's count, after the wake event, to
        // e3's pi-codex placeholder.
        start: None,
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

/// Each harness's Start is measured where the first turn's last response
/// was counted, and its first delivery, which shares the first call with
/// the harness's own prompt, is unsupported.
#[test]
fn session_load_reads_each_harness_record_with_each_figure_named_by_its_basis() {
    let root = tempfile::tempdir().unwrap();
    for row in ROWS {
        let mut file = fixture(row.fixture);
        if let Some(lines) = row.head {
            let text = std::fs::read_to_string(&file).unwrap();
            let head: Vec<&str> = text.lines().take(lines).collect();
            assert_eq!(head.len(), lines, "{}", row.fixture);
            file = root.path().join("head.jsonl");
            std::fs::write(&file, head.join("\n")).unwrap();
        }
        let (reply, out) = load(row.harness, &file);
        let result = &reply["result"];
        let start = match row.start {
            Some(value) => json!({"basis": "measured", "value": value}),
            None => json!({"basis": "unsupported"}),
        };
        let mut want = vec![
            ("/start/tokens", start),
            ("/context/0/source", json!("first-delivery")),
            ("/context/0/tokens", json!({"basis": "unsupported"})),
        ];
        want.extend((row.more)());
        for (pointer, want) in want {
            assert_eq!(
                result.pointer(pointer).unwrap_or(&Value::Null),
                &want,
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
