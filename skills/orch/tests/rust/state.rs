//! The state verbs through the executable: the pointer writes under the
//! record's lock, the file-bound appends, the value judge, the round caps
//! and retry budgets, the post-PR stop, the fleet log and standing rows,
//! the handoff record's places, the reads and the item's close-out.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests run the built binary and hold a record's lock themselves"
)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{SystemTime, UNIX_EPOCH};
mod support;

use serde_json::{Value, json};

const ITEM: &str = "KEN-4687";

/// One state directory under a temporary root, and the binary run against
/// it with the suites' isolation.
struct Store {
    dir: tempfile::TempDir,
}

impl Store {
    fn new() -> Store {
        Store {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn state_dir(&self) -> PathBuf {
        self.dir.path().join("state")
    }

    fn item_path(&self, item: &str) -> PathBuf {
        self.state_dir().join(format!("workflow-state-{item}.json"))
    }

    fn fleet_path(&self) -> PathBuf {
        self.state_dir().join("workflow-state-oversee.json")
    }

    fn run_env(&self, args: &[&str], env: &[(&str, &str)]) -> Output {
        let mut command = support::isolated();
        command.arg("--state-dir").arg(self.state_dir());
        command.args(args);
        for (name, value) in env {
            command.env(name, value);
        }
        command.output().unwrap()
    }

    fn run(&self, args: &[&str]) -> Output {
        self.run_env(args, &[])
    }

    /// The `result` of a reply that succeeded.
    fn ok(&self, args: &[&str]) -> Value {
        let out = self.run(args);
        assert!(
            out.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        reply(&out)["result"].take()
    }

    fn ok_env(&self, args: &[&str], env: &[(&str, &str)]) -> Value {
        let out = self.run_env(args, env);
        assert!(
            out.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        reply(&out)["result"].take()
    }

    /// The refusal key of a call that exited 1, and its keyed stderr line.
    fn refused(&self, args: &[&str]) -> (String, String) {
        refused_env(self, args, &[])
    }

    fn init(&self, item: &str) {
        self.ok(&["state", "init", "--item", item]);
    }

    fn init_fleet(&self) {
        self.ok(&["state", "init", "--fleet"]);
    }

    fn doc(&self, path: &Path) -> Value {
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }

    fn write_file(&self, name: &str, text: &str) -> String {
        let path = self.dir.path().join(name);
        fs::write(&path, text).unwrap();
        path.display().to_string()
    }
}

fn refused_env(store: &Store, args: &[&str], env: &[(&str, &str)]) -> (String, String) {
    let out = store.run_env(args, env);
    assert_eq!(
        out.status.code(),
        Some(1),
        "{args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let answer = reply(&out);
    assert_eq!(answer["ok"], false, "{args:?}");
    let key = answer["refusal"]["key"].as_str().unwrap().to_owned();
    let line = String::from_utf8_lossy(&out.stderr)
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned();
    assert!(
        line.starts_with(&format!("orch-runtime: {key}")),
        "{args:?}: {line}"
    );
    (key, line)
}

fn reply(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstdout={}\nstderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    })
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// The real program `name` on this host's `PATH`, which a fixture execs.
fn real(name: &str) -> String {
    let out = std::process::Command::new("sh")
        .args(["-c", &format!("command -v {name}")])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// The bytes the archive at `archive` holds for `path`.
fn archived_file(archive: &str, path: &Path) -> String {
    let member = path.strip_prefix("/").unwrap().display().to_string();
    let out = support::program("tar")
        .args(["-xzOf", archive, &member])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{member}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn iso_shaped(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() == 20
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[13] == b':'
        && b[16] == b':'
        && b[19] == b'Z'
}

/// A `set` whose record's lock another process holds waits on it and refuses
/// `lock-timeout` with the file untouched, so a write never lands over a
/// holder's read-modify-write; two writers on one record keep each other's
/// keys, since a snapshot the other moved is read again.
#[test]
fn a_pointer_write_waits_on_the_records_lock_and_two_writers_keep_each_others_keys() {
    let store = Store::new();
    store.init(ITEM);
    let path = store.item_path(ITEM);
    let before = fs::read_to_string(&path).unwrap();
    let mut guard = agent_runtime::record::lock(&path).unwrap();
    guard
        .with(|| {
            let out = store.run(&["state", "set", "--item", ITEM, "/phase", "held"]);
            assert_eq!(
                out.status.code(),
                Some(1),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            assert_eq!(reply(&out)["refusal"]["key"], "lock-timeout");
            assert_eq!(fs::read_to_string(&path).unwrap(), before);
            Ok(())
        })
        .unwrap();

    let writers: Vec<std::thread::JoinHandle<()>> = ["a", "b"]
        .into_iter()
        .map(|writer| {
            let store_dir = store.state_dir();
            std::thread::spawn(move || {
                for n in 0..12 {
                    let mut command = support::isolated();
                    command.arg("--state-dir").arg(&store_dir);
                    let pointer = format!("/{writer}/{n}");
                    command.args(["state", "set", "--item", ITEM, &pointer, "1"]);
                    let out = command.output().unwrap();
                    assert!(
                        out.status.success(),
                        "{pointer}: {}",
                        String::from_utf8_lossy(&out.stderr)
                    );
                }
            })
        })
        .collect();
    for writer in writers {
        writer.join().unwrap();
    }
    let doc = store.doc(&path);
    for writer in ["a", "b"] {
        for n in 0..12 {
            assert_eq!(doc[writer][n.to_string()], 1, "/{writer}/{n}");
        }
    }
    assert_eq!(doc["issue_id"], ITEM);
}

/// Reviewer text with newlines, quotes, backticks and `$` reaches the record
/// byte for byte through a file, the array created where absent; a file
/// holding none or two values, or no file, refuses with the record untouched.
#[test]
fn append_file_carries_bytes_the_shell_would_split_and_refuses_what_is_not_one_value() {
    let store = Store::new();
    store.init(ITEM);
    let cause = json!({
        "cause": "fs.rs::write_all's guard \"quoted\" $(whoami) `id` | ;\nsecond line\ttab",
        "commit": "abc1234"
    });
    let file = store.write_file("cause.json", &cause.to_string());
    let pointer = "/pr_comment_review/patched_causes";
    store.ok(&["state", "append-file", "--item", ITEM, pointer, &file]);
    let result = store.ok(&["state", "append-file", "--item", ITEM, pointer, &file]);
    assert_eq!(result["length"], 2);
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        doc["pr_comment_review"]["patched_causes"],
        json!([cause, cause])
    );
    assert_eq!(
        doc["pr_comment_review"]["iterations"], 0,
        "the siblings stand"
    );

    let before = fs::read_to_string(store.item_path(ITEM)).unwrap();
    let rows: [(&str, &str, &str); 3] = [
        ("bad.json", "not json\n", "append-value"),
        ("two.json", "{\"a\":1}\n{\"b\":2}\n", "append-value"),
        ("nope.json", "", "append-missing"),
    ];
    for (name, text, key) in rows {
        let file = if text.is_empty() {
            store.dir.path().join(name).display().to_string()
        } else {
            store.write_file(name, text)
        };
        let (got, _) = store.refused(&["state", "append-file", "--item", ITEM, pointer, &file]);
        assert_eq!(got, key, "{name}");
        assert_eq!(
            fs::read_to_string(store.item_path(ITEM)).unwrap(),
            before,
            "{name}"
        );
    }
}

/// `set` never parses a JSON string literal: a quoted word stores its
/// quotes, a bare word stores a string, and only `{`, `[`, `null`, `true`,
/// `false` and digits splice as JSON; a `{` that does not parse refuses.
#[test]
fn set_stores_a_value_that_is_not_json_raw() {
    let store = Store::new();
    store.init(ITEM);
    let rows: [(&str, &str, Value); 9] = [
        ("/pr_review/mode", "review", json!("review")),
        ("/pr_review/mode", "\"review\"", json!("\"review\"")),
        ("/pr_review/mode", "off", json!("off")),
        (
            "/pr_review_baseline",
            r#"{"last_threads":["PRRT_t"]}"#,
            json!({"last_threads": ["PRRT_t"]}),
        ),
        ("/review_agents", r#"["a"]"#, json!(["a"])),
        ("/skip_qa", "true", json!(true)),
        ("/pre_delegate_sha", "null", Value::Null),
        ("/cycles", "7", json!(7)),
        ("/branch", "007", json!(7)),
    ];
    for (pointer, text, want) in &rows {
        let result = store.ok(&["state", "set", "--item", ITEM, pointer, text]);
        assert_eq!(result["value"], *want, "{pointer} {text}");
        let got = store.ok(&["state", "get", "--item", ITEM, pointer]);
        assert_eq!(got["value"], *want, "{pointer} {text}");
    }
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        doc["pr_review"]["mode"], "off",
        "the intermediate object was created"
    );
    let before = fs::read_to_string(store.item_path(ITEM)).unwrap();
    let (key, _) = store.refused(&["state", "set", "--item", ITEM, "/x", "{not json"]);
    assert_eq!(key, "request-invalid");
    let (key, _) = store.refused(&["state", "set", "--item", ITEM, "cycles", "1"]);
    assert_eq!(key, "pointer-invalid");
    assert_eq!(fs::read_to_string(store.item_path(ITEM)).unwrap(), before);
    let (key, line) = store.refused(&["state", "set", "--item", ITEM, "/handoff", r#"{"a":1}"#]);
    assert_eq!(key, "handoff-route");
    assert!(line.ends_with("op=record-handoff"), "{line}");
}

/// The lift replaces `standing[]` with the array the file holds and records
/// one `ruling` row naming the lifted ids in the same write; a file that is
/// not one array refuses with both arrays as they were.
#[test]
fn standing_lift_writes_the_array_as_the_file_holds_it_and_one_ruling_row() {
    let store = Store::new();
    store.init_fleet();
    for id in ["n1", "n2"] {
        let row = store.write_file(
            &format!("{id}.json"),
            &json!({"id": id, "scope": "fleet", "end": "until lifted", "text": "keep"}).to_string(),
        );
        let result = store.ok(&["state", "standing", "add", "--fleet", &row]);
        assert!(
            iso_shaped(result["row"]["at"].as_str().unwrap()),
            "{result}"
        );
    }
    let doc = store.doc(&store.fleet_path());
    assert_eq!(doc["standing"].as_array().unwrap().len(), 2);
    let keep = doc["standing"][1].clone();
    let lifted = store.write_file("lift.json", &json!([keep]).to_string());
    let result = store.ok(&["state", "standing", "lift", "--fleet", &lifted]);
    assert_eq!(result["lifted"], json!(["n1"]));
    let doc = store.doc(&store.fleet_path());
    assert_eq!(doc["standing"], json!([keep]));
    let log = doc["fleet_log"].as_array().unwrap();
    assert_eq!(log.len(), 1);
    assert_eq!(log[0]["kind"], "ruling");
    assert_eq!(log[0]["text"], "standing lifted: n1");
    assert!(iso_shaped(log[0]["at"].as_str().unwrap()));

    let before = fs::read_to_string(store.fleet_path()).unwrap();
    let object = store.write_file("object.json", r#"{"id":"n3"}"#);
    let (key, _) = store.refused(&["state", "standing", "lift", "--fleet", &object]);
    assert_eq!(key, "standing-array");
    let (key, _) = store.refused(&["state", "standing", "add", "--fleet", &lifted]);
    assert_eq!(key, "standing-record");
    assert_eq!(fs::read_to_string(store.fleet_path()).unwrap(), before);
}

/// `ci-fix` counts across cycles that each push a new head, so
/// `CI_FIX_MAX_CYCLES` bounds the loop; a take at the cap spends nothing on
/// replay; a passing run's clear restarts it; `review-wait` restarts on a
/// new head and holds a `small` item to two rounds.
#[test]
fn head_budget_take_spends_once_and_ci_fix_counts_across_new_heads() {
    let store = Store::new();
    store.init(ITEM);
    let take = |kind: &str, head: &str, cap: &str| -> String {
        let result = store.ok_env(
            &[
                "state",
                "head-budget",
                "take",
                "--item",
                ITEM,
                "--kind",
                kind,
                "--head",
                head,
            ],
            &[
                ("CI_FIX_MAX_CYCLES", cap),
                ("REVIEW_MAX_EXTERNAL_ROUNDS", cap),
            ],
        );
        format!(
            "{} {}/{}",
            result["verdict"].as_str().unwrap(),
            result["attempts"],
            result["limit"]
        )
    };
    assert_eq!(take("ci-fix", "head-a", "2"), "continue 1/2");
    assert_eq!(take("ci-fix", "head-b", "2"), "continue 2/2");
    assert_eq!(take("ci-fix", "head-c", "2"), "at-cap 2/2");
    let before = fs::read_to_string(store.item_path(ITEM)).unwrap();
    assert_eq!(take("ci-fix", "head-d", "2"), "at-cap 2/2");
    assert_eq!(
        fs::read_to_string(store.item_path(ITEM)).unwrap(),
        before,
        "a take at the cap writes nothing"
    );
    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/post_pr_budgets/ci_fix",
        "null",
    ]);
    assert_eq!(take("ci-fix", "head-d", "2"), "continue 1/2");

    assert_eq!(take("review-wait", "h1", "4"), "continue 1/4");
    assert_eq!(take("review-wait", "h1", "4"), "continue 2/4");
    assert_eq!(take("review-wait", "h2", "4"), "continue 1/4");
    store.ok(&["state", "set", "--item", ITEM, "/tier", "small"]);
    assert_eq!(take("review-wait", "h2", "4"), "continue 2/2");
    assert_eq!(take("review-wait", "h2", "4"), "at-cap 2/2");
    let (key, _) = store.refused(&[
        "state",
        "head-budget",
        "take",
        "--item",
        "KEN-none",
        "--kind",
        "ci-fix",
        "--head",
        "h",
    ]);
    assert_eq!(key, "record-missing");
}

/// `record` renders the named stop with its remaining work into the comment
/// file; `record-if-empty` keeps a precise stop over a generic one and
/// renders nothing, so the comment is written once; a cleared stop records
/// again.
#[test]
fn post_pr_stop_record_if_empty_keeps_a_precise_stop_and_renders_once() {
    let store = Store::new();
    store.init(ITEM);
    let comment = store.dir.path().join("stop.md");
    let comment_text = comment.display().to_string();
    let stop = |mode: &str, name: &str, gate: &str, remaining: &str| -> Value {
        store.ok(&[
            "state",
            "post-pr-stop",
            mode,
            "--item",
            ITEM,
            "--name",
            name,
            "--gate",
            gate,
            "--remaining",
            remaining,
            "--comment-file",
            &comment_text,
        ])
    };
    let first = stop(
        "record",
        "review-round-cap",
        "review",
        "one unresolved review thread",
    );
    assert_eq!(first["result"], "recorded");
    let rendered = fs::read_to_string(&comment).unwrap();
    assert_eq!(
        rendered,
        "## Orchestration stopped\n\n- Stop: `review-round-cap`\n- Gate: `review`\n- Remaining: one unresolved review thread\n"
    );
    let kept = stop(
        "record-if-empty",
        "merge-gates-unmet",
        "merge",
        "CI pending",
    );
    assert_eq!(kept["result"], "kept");
    assert_eq!(kept["stop"]["name"], "review-round-cap");
    assert_eq!(fs::read_to_string(&comment).unwrap(), rendered);
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["post_pr_stop"]["name"], "review-round-cap");
    assert_eq!(
        doc["post_pr_stop"]["remaining"],
        json!(["one unresolved review thread"])
    );
    store.ok(&["state", "set", "--item", ITEM, "/post_pr_stop", "null"]);
    let again = stop(
        "record-if-empty",
        "merge-gates-unmet",
        "merge",
        "CI pending",
    );
    assert_eq!(again["result"], "recorded");
    assert!(fs::read_to_string(&comment).unwrap().contains("CI pending"));
}

/// A second `init` of a standing record refuses `state-exists` and leaves
/// its bytes, so a workflow that re-enters never drops an item's state.
#[test]
fn init_refuses_a_standing_file() {
    let store = Store::new();
    store.init(ITEM);
    store.ok(&["state", "set", "--item", ITEM, "/cycles", "3"]);
    let before = fs::read_to_string(store.item_path(ITEM)).unwrap();
    let (key, _) = store.refused(&["state", "init", "--item", ITEM, "--branch", "b"]);
    assert_eq!(key, "state-exists");
    assert_eq!(fs::read_to_string(store.item_path(ITEM)).unwrap(), before);
}

/// `exists` answers the standing of a record and its key at exit 0 for a
/// standing and a missing one: a false answer on a standing record would
/// re-initialize the item, a true one on a missing record would skip the
/// init and fail every later verb.
#[test]
fn exists_answers_the_record_and_its_key_for_a_standing_and_a_missing_record() {
    let store = Store::new();
    store.init("issue-353");
    let standing = store.ok(&["state", "exists", "--item", "issue-353"]);
    assert_eq!(standing["exists"], true);
    assert_eq!(standing["issue_id"], "issue-353");
    assert_eq!(
        standing["path"],
        store.item_path("issue-353").display().to_string()
    );
    let missing = store.ok(&["state", "exists", "--item", "issue-404"]);
    assert_eq!(missing["exists"], false);
    assert_eq!(missing["issue_id"], "issue-404");
    let fleet = store.ok(&["state", "exists", "--fleet"]);
    assert_eq!(fleet["exists"], false);
    assert_eq!(fleet["issue_id"], "oversee");
    let path = store.ok(&["state", "path", "--fleet"]);
    assert_eq!(path["path"], store.fleet_path().display().to_string());
    let (key, _) = store.refused(&["state", "get", "--item", "issue-404"]);
    assert_eq!(key, "record-missing");
}

/// The cap verdict flips to `at-cap` on the count the `rereview_panel` write
/// refuses on, so the setting is the number of entries allowed; the write
/// raises `rereview_cycles` itself and a refused write spends nothing; a
/// `small` item holds the caps to its ceilings and its panels to three
/// reviewers with the external lane counted.
#[test]
fn cap_flips_where_the_rereview_panel_write_refuses_and_tier_small_holds_the_ceilings() {
    let store = Store::new();
    store.init(ITEM);
    let panel = r#"{"agents": ["rev-a"], "reason": "test"}"#;
    let cap = |setting: &str, env: &[(&str, &str)]| -> String {
        let result = store.ok_env(&["state", "cap", setting, "--item", ITEM], env);
        format!(
            "{} {}/{}",
            result["verdict"].as_str().unwrap(),
            result["count"],
            result["limit"]
        )
    };
    assert_eq!(cap("REVIEW_MAX_CYCLES", &[]), "below 0/1");
    let entered = store.ok(&["state", "set", "--item", ITEM, "/rereview_panel", panel]);
    assert_eq!(entered["rereview_cycles"], 1);
    assert_eq!(cap("REVIEW_MAX_CYCLES", &[]), "at-cap 1/1");
    let (key, line) = store.refused(&["state", "set", "--item", ITEM, "/rereview_panel", panel]);
    assert_eq!(key, "cycle-cap");
    assert_eq!(line, "orch-runtime: cycle-cap count=1 limit=1");
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["rereview_cycles"], 1, "a refused write spends nothing");
    assert_eq!(
        cap("REVIEW_MAX_CYCLES", &[("REVIEW_MAX_CYCLES", "4")]),
        "below 1/4"
    );
    store.ok(&["state", "set", "--item", ITEM, "/qa_recheck_panel", panel]);
    assert_eq!(store.doc(&store.item_path(ITEM))["rereview_cycles"], 1);

    // The zero cap allows the one fix round until the fix delegation marks it.
    assert_eq!(
        cap("REVIEW_MAX_CYCLES", &[("REVIEW_MAX_CYCLES", "0")]),
        "at-cap 1/0"
    );
    store.ok(&["state", "set", "--item", ITEM, "/rereview_cycles", "0"]);
    assert_eq!(
        cap("REVIEW_MAX_CYCLES", &[("REVIEW_MAX_CYCLES", "0")]),
        "below 0/0"
    );
    store.ok(&["state", "set", "--item", ITEM, "/review_fix_round", "true"]);
    assert_eq!(
        cap("REVIEW_MAX_CYCLES", &[("REVIEW_MAX_CYCLES", "0")]),
        "at-cap 0/0"
    );

    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/pr_comment_review/iterations",
        "3",
    ]);
    assert_eq!(cap("REVIEW_MAX_EXTERNAL_ROUNDS", &[]), "below 3/4");
    store.ok(&["state", "set", "--item", ITEM, "/tier", "small"]);
    assert_eq!(cap("REVIEW_MAX_EXTERNAL_ROUNDS", &[]), "at-cap 3/2");
    // The ceiling lowers a raised setting to one entry and leaves a setting
    // under it alone.
    assert_eq!(
        cap("REVIEW_MAX_CYCLES", &[("REVIEW_MAX_CYCLES", "4")]),
        "below 0/1"
    );
    store.ok(&["state", "set", "--item", ITEM, "/rereview_cycles", "1"]);
    assert_eq!(
        cap("REVIEW_MAX_CYCLES", &[("REVIEW_MAX_CYCLES", "4")]),
        "at-cap 1/1"
    );
    assert_eq!(
        cap("REVIEW_MAX_CYCLES", &[("REVIEW_MAX_CYCLES", "0")]),
        "at-cap 1/0"
    );
    let bare = store.ok_env(
        &["state", "cap", "REVIEW_MAX_CYCLES"],
        &[("REVIEW_MAX_CYCLES", "4")],
    );
    assert_eq!(
        bare["limit"], 4,
        "a bare cap names no item, so no tier bounds it"
    );
    let counted = store.ok(&["state", "cap", "CI_FIX_MAX_CYCLES", "--count", "5"]);
    assert_eq!(counted["verdict"], "below");
    assert_eq!(counted["limit"], 6);

    let four = r#"{"agents": ["r1","r2","r3","r4"], "reason": "t", "external": false}"#;
    let (key, _) = store.refused(&["state", "set", "--item", ITEM, "/first_panel", four]);
    assert_eq!(key, "panel-bound");
    let unmarked = r#"{"agents": ["r1"], "reason": "t"}"#;
    let (key, _) = store.refused(&["state", "set", "--item", ITEM, "/first_panel", unmarked]);
    assert_eq!(key, "panel-external");
    let three_external = r#"{"agents": ["r1","r2","r3"], "reason": "t", "external": true}"#;
    let (key, _) = store.refused(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/first_panel",
        three_external,
    ]);
    assert_eq!(key, "panel-bound");
    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/first_panel",
        r#"{"agents": ["r1","r2"], "reason": "t", "external": true}"#,
    ]);
    let copy = r#"{"agents": ["r1","r2"], "reason": "t", "external": false}"#;
    let (key, line) = store.refused(&["state", "set", "--item", ITEM, "/verification_panel", copy]);
    assert_eq!(key, "panel-copy");
    assert!(line.ends_with("uncovered=r1,r2"), "{line}");
    let reasoned = r#"{"agents": ["r1","r2"], "reason": "t", "external": false, "domain_reasons": {"r1": "fs", "r2": "docs"}}"#;
    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/verification_panel",
        reasoned,
    ]);
    let (key, _) = store.refused(&["state", "set", "--item", ITEM, "/tier", "Small"]);
    assert_eq!(key, "tier-value");
    let (key, _) = store.refused(&["state", "cap", "NOT_A_CAP"]);
    assert_eq!(key, "unknown-cap");
    let (key, _) = store.refused(&["state", "cap", "CI_FIX_MAX_CYCLES", "--item", ITEM]);
    assert_eq!(key, "cap-count-required");
}

/// The takeover read is exactly the last `ORCH_TAKEOVER_ROWS` rows but the
/// `cycle` and `token` rows, which would crowd the rulings out of the
/// window, and nothing on a first session; the audit read every proposal
/// and ruling; the append stamps an absent `at`, keeps a past one, refuses
/// a future or malformed one and a row over the byte bound, and the plain
/// append at the log refuses toward it.
#[test]
fn log_takeover_reads_the_last_rows_but_cycle_and_token_and_append_stamps_and_bounds_the_row() {
    let store = Store::new();
    let empty = store.ok(&["state", "log", "takeover", "--fleet"]);
    assert_eq!(empty["rows"], json!([]));
    let (key, _) = store.refused(&["state", "log", "audit", "--fleet"]);
    assert_eq!(key, "record-missing");
    store.init_fleet();
    let kinds = ["proposal", "ruling", "close", "peer"];
    let rows: Vec<Value> = (0..14)
        .map(|i| {
            json!({"at": "2020-01-01T00:00:00Z", "kind": kinds[i % 4], "item": format!("KEN-{i}"), "text": format!("row {i}")})
        })
        .collect();
    let file = store.write_file("log.json", &Value::Array(rows).to_string());
    store.ok(&["state", "set-file", "--fleet", "/fleet_log", &file]);
    let items = |result: &Value| -> Vec<String> {
        result["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["item"].as_str().unwrap().to_owned())
            .collect()
    };
    let want: Vec<String> = (4..14).map(|i| format!("KEN-{i}")).collect();
    assert_eq!(
        items(&store.ok(&["state", "log", "takeover", "--fleet"])),
        want
    );
    let rows: [(&str, usize); 3] = [("3", 3), ("20", 14), ("0", 0)];
    for (setting, count) in rows {
        let result = store.ok_env(
            &["state", "log", "takeover", "--fleet"],
            &[("ORCH_TAKEOVER_ROWS", setting)],
        );
        assert_eq!(items(&result).len(), count, "ORCH_TAKEOVER_ROWS={setting}");
    }
    let audit = store.ok(&["state", "log", "audit", "--fleet"]);
    assert_eq!(audit["rows"].as_array().unwrap().len(), 8);
    assert!(
        audit["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| matches!(r["kind"].as_str(), Some("proposal" | "ruling")))
    );

    let tokens = Store::new();
    tokens.init_fleet();
    for kind in ["ruling", "ruling", "cycle", "token", "token", "token"] {
        let row = tokens.write_file(
            "row.json",
            &json!({"kind": kind, "item": "member", "text": "event"}).to_string(),
        );
        let result = tokens.ok(&["state", "log", "append", "--fleet", &row]);
        let at = result["row"]["at"].as_str().unwrap();
        assert!(iso_shaped(at), "{at}");
    }
    let window = tokens.ok_env(
        &["state", "log", "takeover", "--fleet"],
        &[("ORCH_TAKEOVER_ROWS", "2")],
    );
    let kinds: Vec<&str> = window["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["ruling", "ruling"]);

    let before = fs::read_to_string(tokens.fleet_path()).unwrap();
    let refusals: [(&str, &str); 5] = [
        (
            r#"{"at":"2020-01-01T00:00:00Z","kind":"ruling","item":"KEN-1","text":"past"}"#,
            "kept",
        ),
        (
            r#"{"at":"2099-01-01T00:00:00Z","kind":"ruling","item":"KEN-1","text":"future"}"#,
            "fleet-log-at-future",
        ),
        (
            r#"{"at":"2020-02-30T00:00:00Z","kind":"ruling","item":"KEN-1","text":"nonday"}"#,
            "fleet-log-at-invalid",
        ),
        (
            r#"{"at":"2020-01-01 00:00:00","kind":"ruling","item":"KEN-1","text":"shape"}"#,
            "fleet-log-at-invalid",
        ),
        (r#""a string""#, "fleet-log-record"),
    ];
    for (row, key) in refusals {
        let file = tokens.write_file("refused.json", row);
        if key == "kept" {
            let result = tokens.ok(&["state", "log", "append", "--fleet", &file]);
            assert_eq!(result["row"]["at"], "2020-01-01T00:00:00Z");
            continue;
        }
        let (got, _) = tokens.refused(&["state", "log", "append", "--fleet", &file]);
        assert_eq!(got, key, "{row}");
    }
    let over = tokens.write_file(
        "over.json",
        &json!({"kind": "ruling", "item": "KEN-8", "text": "a".repeat(601)}).to_string(),
    );
    let (key, line) = tokens.refused(&["state", "log", "append", "--fleet", &over]);
    assert_eq!(key, "fleet-log-row-bytes");
    assert_eq!(line, "orch-runtime: fleet-log-row-bytes bytes=601 cap=600");
    let raised = tokens.ok_env(
        &["state", "log", "append", "--fleet", &over],
        &[("ORCH_FLEET_LOG_ROW_BYTES", "700")],
    );
    assert_eq!(
        raised["row"]["text"].as_str().map(str::len),
        Some(601),
        "the bound is the setting's"
    );
    let (key, line) = tokens.refused(&[
        "state",
        "append",
        "--fleet",
        "/fleet_log",
        r#"{"kind":"ruling"}"#,
    ]);
    assert_eq!(key, "fleet-log-append");
    assert!(line.ends_with("route=log-append"), "{line}");
    let after = tokens.doc(&tokens.fleet_path());
    assert_eq!(
        after["fleet_log"].as_array().unwrap().len(),
        6 + 2,
        "the kept row and the raised bound's row landed, nothing else: {before}"
    );
}

/// A triage row names the issue, the reason and a verdict the watch
/// acknowledges; a string row or an `item`-keyed one would rebuild no key.
#[test]
fn a_triaged_row_is_held_to_the_shape_the_watch_acknowledges() {
    let store = Store::new();
    store.init_fleet();
    let before = fs::read_to_string(store.fleet_path()).unwrap();
    let rows = [
        r#""KEN-4138""#,
        r#"{"item":"KEN-4138","verdict":"kept","reason":"checked"}"#,
        r#"{"issue":"KEN-4138","verdict":"pending","reason":"checked"}"#,
        r#"{"issue":"KEN-4138","verdict":"kept"}"#,
        r#"{"issue":42,"verdict":"kept","reason":"checked"}"#,
        r#"[]"#,
    ];
    for row in rows {
        let (key, _) = store.refused(&["state", "append", "--fleet", "/triaged", row]);
        assert_eq!(key, "triaged-record-invalid", "{row}");
        let file = store.write_file("triaged.json", row);
        let (key, _) = store.refused(&["state", "append-file", "--fleet", "/triaged", &file]);
        assert_eq!(key, "triaged-record-invalid", "{row}");
    }
    assert_eq!(fs::read_to_string(store.fleet_path()).unwrap(), before);
    store.ok(&[
        "state",
        "append",
        "--fleet",
        "/triaged",
        r#"{"issue":"KEN-4138","verdict":"canceled","reason":"checked"}"#,
    ]);
    assert_eq!(
        store.doc(&store.fleet_path())["triaged"][0]["verdict"],
        "canceled"
    );
}

/// The handoff record is read in the state directory's file, then in the
/// lane root's `tmp`: the first standing record wins, an unreadable place
/// is never `none`, and the resume stamps every place a record stands so
/// none keeps a spent record; a resume with none standing or a place it
/// cannot read refuses by name.
#[test]
fn handoff_standing_reads_the_state_directory_then_the_worktree_and_resume_stamps_every_place() {
    let store = Store::new();
    let main_file = store.item_path("KEN-9");
    let wt = store.dir.path().join("wt");
    fs::create_dir_all(wt.join("tmp")).unwrap();
    fs::create_dir_all(store.state_dir()).unwrap();
    let wt_file = wt.join("tmp/workflow-state-KEN-9.json");
    let wt_text = wt.display().to_string();
    let held = r#"{"issue_id":"KEN-9","handoff":{"remaining":["x"]}}"#;
    let spent = r#"{"issue_id":"KEN-9","handoff":{"remaining":["x"],"resumed_at":1}}"#;
    let place = |file: &Path, content: &str| {
        if content.is_empty() {
            let _ = fs::remove_file(file);
        } else {
            fs::write(file, content).unwrap();
        }
    };
    // main content, worktree content, --worktree given, standing, file (main or wt)
    let rows: [(&str, &str, bool, &str, &str); 8] = [
        ("", "", false, "none", "main"),
        ("", held, false, "none", "main"),
        ("", held, true, "stands", "wt"),
        (held, held, true, "stands", "main"),
        ("{", held, true, "stands", "wt"),
        ("{", "", true, "unreadable", "main"),
        (spent, "{", true, "unreadable", "wt"),
        ("", spent, true, "none", "wt"),
    ];
    for (main, worktree, named, standing, which) in rows {
        place(&main_file, main);
        place(&wt_file, worktree);
        let mut args = vec!["state", "handoff-standing", "--item", "KEN-9"];
        if named {
            args.extend(["--worktree", &wt_text]);
        }
        let result = store.ok(&args);
        let want = if which == "main" {
            &main_file
        } else {
            &wt_file
        };
        assert_eq!(
            result["standing"], standing,
            "{main:?} {worktree:?} {named}"
        );
        assert_eq!(
            result["file"],
            want.display().to_string(),
            "{main:?} {worktree:?} {named}"
        );
        if standing == "stands" {
            assert_eq!(result["record"]["remaining"], json!(["x"]));
        }
    }

    place(&main_file, held);
    place(&wt_file, held);
    let resumed = store.ok(&[
        "state",
        "handoff-resume",
        "--item",
        "KEN-9",
        "--worktree",
        &wt_text,
    ]);
    assert_eq!(resumed["resumed"].as_array().unwrap().len(), 2);
    for file in [&main_file, &wt_file] {
        assert!(
            store.doc(file)["handoff"]["resumed_at"].is_number(),
            "{}",
            file.display()
        );
    }
    let after = store.ok(&[
        "state",
        "handoff-standing",
        "--item",
        "KEN-9",
        "--worktree",
        &wt_text,
    ]);
    assert_eq!(after["standing"], "none");
    let (key, line) = store.refused(&[
        "state",
        "handoff-resume",
        "--item",
        "KEN-9",
        "--worktree",
        &wt_text,
    ]);
    assert_eq!(key, "handoff-none");
    assert_eq!(line, "orch-runtime: handoff-none issue=KEN-9");
    place(&main_file, held);
    place(&wt_file, "{");
    let (key, line) = store.refused(&[
        "state",
        "handoff-resume",
        "--item",
        "KEN-9",
        "--worktree",
        &wt_text,
    ]);
    assert_eq!(key, "handoff-unread");
    assert!(
        line.ends_with(&format!("state-file={}", wt_file.display())),
        "{line}"
    );
    assert!(
        store.doc(&main_file)["handoff"]["resumed_at"].is_number(),
        "the standing place was stamped"
    );

    // The implicit second place: a linked worktree the caller runs in.
    let repo = Store::new();
    let root = repo.dir.path();
    let git = |args: &[&str]| {
        let out = support::program("git")
            .args(args)
            .current_dir(root)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    };
    git(&["init", "-q", "main"]);
    git(&["-C", "main", "config", "gc.auto", "0"]);
    git(&["-C", "main", "config", "maintenance.auto", "false"]);
    git(&["-C", "main", "commit", "-q", "--allow-empty", "-m", "base"]);
    git(&[
        "-C",
        "main",
        "worktree",
        "add",
        "-q",
        "-b",
        "wt",
        "../linked",
    ]);
    let linked = root.join("linked");
    fs::create_dir_all(linked.join("tmp")).unwrap();
    fs::write(linked.join("tmp/workflow-state-KEN-9.json"), held).unwrap();
    let mut command = support::isolated();
    command
        .current_dir(&linked)
        .args(["state", "handoff-standing", "--item", "KEN-9"]);
    let out = command.output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let result = &reply(&out)["result"];
    assert_eq!(result["standing"], "stands");
    assert_eq!(
        result["file"],
        fs::canonicalize(&linked)
            .unwrap()
            .join("tmp/workflow-state-KEN-9.json")
            .display()
            .to_string()
    );
}

/// A review request matches a recorded occurrence that shares a cause key,
/// a validation request one with the same check; a request with no usable
/// key reports no count and unknown coverage, so a missing key never reads
/// as a zero.
#[test]
fn findings_query_counts_a_shared_cause_key_and_leaves_an_unbound_request_unknown() {
    let store = Store::new();
    store.init(ITEM);
    let records = json!({"prior": "none", "records": [
        {"kind": "review", "location": "src/x.rs (`f`)", "owner": "src/shared.rs (`rule`)",
         "source": {"round_id": "R1", "artifact": "a.json", "identity": ["artifact", "a.json", "blockers", 0]}},
        {"kind": "review", "text": "blocker|high|src/y.rs (`g`)\nOwner: src/shared.rs (`rule`)\n",
         "source": {"round_id": "R2", "artifact": "b.json", "identity": ["artifact", "b.json", "blockers", 1]}},
        {"kind": "validation", "check": "cargo test",
         "source": {"round_id": "R1", "receipt": "r.json", "identity": ["receipt", "R1", "r.json", "cargo test"]}}
    ]});
    let file = store.write_file("occ.json", &records.to_string());
    store.ok(&[
        "state",
        "set-file",
        "--item",
        ITEM,
        "/finding_occurrences",
        &file,
    ]);
    let requests = json!([
        {"kind": "review", "location": "src/z.rs", "owner": "src/shared.rs (`rule`)"},
        {"kind": "review", "location": "TBD"},
        {"kind": "validation", "check": "cargo test"},
        {"kind": "validation", "check": "cargo fmt"}
    ]);
    let requests_file = store.write_file("req.json", &requests.to_string());
    let result = store.ok(&["state", "findings", "query", "--item", ITEM, &requests_file]);
    assert_eq!(result["prior"], "none");
    let classes = result["classes"].as_array().unwrap();
    assert_eq!(
        classes[0]["observed_count"], 2,
        "the owner key is shared by both review records"
    );
    assert_eq!(classes[0]["sources"].as_array().unwrap().len(), 2);
    assert_eq!(classes[1]["observed_count"], Value::Null);
    assert_eq!(classes[1]["prior"], "unknown");
    assert_eq!(classes[2]["observed_count"], 1);
    assert_eq!(classes[3]["observed_count"], 0);
    assert_eq!(
        classes[3]["class"],
        json!({"kind": "validation", "check": "cargo fmt"})
    );
    let all = store.ok(&["state", "findings", "query", "--item", ITEM]);
    assert_eq!(
        all["classes"].as_array().unwrap().len(),
        3,
        "every known class once"
    );
    let fresh = Store::new();
    fresh.init("KEN-1");
    let none = fresh.ok(&["state", "findings", "query", "--item", "KEN-1"]);
    assert_eq!(none["prior"], "none");
    assert_eq!(none["classes"], json!([]));
    let (key, _) = store.refused(&["state", "findings", "query", "--item", ITEM, &file]);
    assert_eq!(key, "finding-requests");
}

/// The progress report is named by the UTC minute under the setting's
/// directory, created on the read, `-succession` for a succession's; a
/// local key names no issue and two mints differ.
#[test]
fn progress_report_path_names_the_utc_minute_and_a_local_key_names_no_issue() {
    let store = Store::new();
    let reports = store.dir.path().join("reports");
    let reports_text = reports.display().to_string();
    let before = agent_runtime::clock::iso_utc(now_secs());
    let plain = store.ok_env(
        &["state", "progress-report-path"],
        &[("ORCH_PROGRESS_REPORT_DIR", &reports_text)],
    );
    let succession = store.ok_env(
        &["state", "progress-report-path", "--succession"],
        &[("ORCH_PROGRESS_REPORT_DIR", &reports_text)],
    );
    let after = agent_runtime::clock::iso_utc(now_secs());
    let minute = |iso: &str| {
        format!(
            "{}-{}-{}-{}",
            &iso[5..7],
            &iso[8..10],
            &iso[11..13],
            &iso[14..16]
        )
    };
    let plain_name = Path::new(plain["path"].as_str().unwrap())
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    assert!(
        plain_name == format!("{}.md", minute(&before))
            || plain_name == format!("{}.md", minute(&after)),
        "{plain_name}"
    );
    assert!(plain["path"].as_str().unwrap().starts_with(&reports_text));
    assert!(
        fs::metadata(&reports).unwrap().is_dir(),
        "the directory is created"
    );
    assert!(
        succession["path"]
            .as_str()
            .unwrap()
            .ends_with("-succession.md")
    );
    let default = store.ok(&["state", "progress-report-path"]);
    assert!(
        default["path"]
            .as_str()
            .unwrap()
            .contains("/tmp/progress-reports/"),
        "{default}"
    );
    let blocked = store.write_file("a-file", "x\n");
    let (key, _) = refused_env(
        &store,
        &["state", "progress-report-path"],
        &[("ORCH_PROGRESS_REPORT_DIR", &blocked)],
    );
    assert_eq!(key, "progress-dir-failed");

    let first = store.ok(&["state", "new-local-key"]);
    let second = store.ok(&["state", "new-local-key"]);
    let key = first["key"].as_str().unwrap();
    let parts: Vec<&str> = key.split('-').collect();
    assert_eq!(parts.len(), 4, "{key}");
    assert_eq!(parts[0], "local");
    assert!(
        parts[1..]
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())),
        "{key}"
    );
    assert_ne!(first["key"], second["key"]);
    assert_eq!(
        fs::read_dir(store.state_dir())
            .map(|d| d.count())
            .unwrap_or(0),
        0,
        "the mint writes nothing"
    );
}

/// `increment` counts from an absent field, `set-now` writes the clock's
/// epoch seconds as a number and `set-git-head` the checkout's HEAD, each at
/// the pointer named, with every other key kept.
#[test]
fn increment_set_now_and_set_git_head_write_the_count_the_clock_and_the_head() {
    let store = Store::new();
    store.init(ITEM);
    let keys_before = store.doc(&store.item_path(ITEM)).as_object().unwrap().len();
    assert_eq!(
        store.ok(&["state", "increment", "--item", ITEM, "/cycles"])["value"],
        1
    );
    assert_eq!(
        store.ok(&[
            "state",
            "increment",
            "--item",
            ITEM,
            "/pr_comment_review/iterations"
        ])["value"],
        1
    );
    assert_eq!(
        store.ok(&["state", "increment", "--item", ITEM, "/restacks"])["value"],
        1
    );
    let (key, _) = store.refused(&["state", "increment", "--item", ITEM, "/agent"]);
    assert_eq!(key, "record-shape");
    let before = now_secs();
    let now = store.ok(&["state", "set-now", "--item", ITEM, "/review_delegated_at"])["value"]
        .as_u64()
        .unwrap();
    assert!((before..=now_secs()).contains(&now), "{now}");

    let repo = store.dir.path().join("repo");
    let git = |args: &[&str]| -> String {
        let out = support::program("git")
            .args(args)
            .current_dir(store.dir.path())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    git(&["init", "-q", "repo"]);
    git(&["-C", "repo", "config", "gc.auto", "0"]);
    git(&["-C", "repo", "commit", "-q", "--allow-empty", "-m", "base"]);
    let head = git(&["-C", "repo", "rev-parse", "HEAD"]);
    let repo_text = repo.display().to_string();
    let result = store.ok(&[
        "state",
        "set-git-head",
        "--item",
        ITEM,
        "/pre_delegate_sha",
        "--worktree",
        &repo_text,
    ]);
    assert_eq!(result["value"], head);
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["pre_delegate_sha"], head);
    assert_eq!(doc["cycles"], 1);
    assert_eq!(doc["restacks"], 1);
    assert_eq!(
        doc.as_object().unwrap().len(),
        keys_before + 2,
        "restacks and review_delegated_at joined, nothing left"
    );
    let missing = store.dir.path().join("no-repo").display().to_string();
    let out = store.run(&[
        "state",
        "set-git-head",
        "--item",
        ITEM,
        "/pre_delegate_sha",
        "--worktree",
        &missing,
    ]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        store.doc(&store.item_path(ITEM))["pre_delegate_sha"],
        head,
        "a failed read writes nothing"
    );
}

/// A bound record with a new identity joins the occurrences and a repeat of
/// the same identity and class adds nothing; a repeat under another class
/// refuses, lands none of its batch and leaves coverage unknown, as an
/// unbound record does, so a failed or partial record never reads as a
/// complete count; a file holding no batch refuses. The round-id mint sets
/// a fresh token at its pointer.
#[test]
fn findings_record_keeps_the_first_class_of_an_identity_and_a_conflict_leaves_coverage_unknown() {
    let store = Store::new();
    store.init(ITEM);
    let review = json!({"kind": "review", "location": "src/x.rs (`f`)",
        "source": {"round_id": "R1", "artifact": "a.json", "identity": ["artifact", "a.json", "blockers", 0]}});
    let check = json!({"kind": "validation", "check": "cargo test",
        "source": {"round_id": "R1", "receipt": "r.json", "identity": ["receipt", "R1", "r.json", "cargo test"]}});
    let batch = store.write_file("b1.json", &json!({"records": [review, check]}).to_string());
    let first = store.ok(&["state", "findings", "record", "--item", ITEM, &batch]);
    assert_eq!(first["recorded"], 2);
    assert_eq!(first["prior"], "none");
    let again = store.ok(&["state", "findings", "record", "--item", ITEM, &batch]);
    assert_eq!(
        again["recorded"], 2,
        "a repeat of the same identity and class adds nothing"
    );
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        doc["finding_occurrences"]["records"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(doc["finding_occurrences"]["prior"], "none");

    let other_class = json!({"kind": "review", "location": "src/y.rs (`g`)",
        "source": {"round_id": "R2", "artifact": "a.json", "identity": ["artifact", "a.json", "blockers", 0]}});
    let fresh = json!({"kind": "review", "location": "src/z.rs (`h`)",
        "source": {"round_id": "R2", "artifact": "c.json", "identity": ["artifact", "c.json", "blockers", 3]}});
    let conflict = store.write_file(
        "b2.json",
        &json!({"records": [fresh, other_class]}).to_string(),
    );
    let (key, _) = store.refused(&["state", "findings", "record", "--item", ITEM, &conflict]);
    assert_eq!(key, "finding-source-conflict");
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        doc["finding_occurrences"]["records"]
            .as_array()
            .unwrap()
            .len(),
        2,
        "none of the conflicting batch landed"
    );
    assert_eq!(doc["finding_occurrences"]["prior"], "unknown");

    let fresh_store = Store::new();
    fresh_store.init("KEN-2");
    let unbound = json!({"kind": "review", "location": "TBD", "source": {"round_id": "R1", "artifact": "a.json", "identity": ["artifact", "a.json", "blockers", 1]}});
    let batch = fresh_store.write_file("b3.json", &json!({"records": [unbound]}).to_string());
    let result = fresh_store.ok(&["state", "findings", "record", "--item", "KEN-2", &batch]);
    assert_eq!(result["recorded"], 0);
    assert_eq!(result["prior"], "unknown");
    let bad = fresh_store.write_file("b4.json", r#"{"unknown": true}"#);
    let (key, _) = fresh_store.refused(&["state", "findings", "record", "--item", "KEN-2", &bad]);
    assert_eq!(key, "finding-batch");

    let minted = store.ok(&["state", "new-round-id", "--item", ITEM, "/ci_round_id"]);
    let token = minted["value"].as_str().unwrap().to_owned();
    let (nanos, nonce) = token.split_once('-').unwrap();
    assert!(
        nanos.len() >= 19 && nanos.bytes().all(|b| b.is_ascii_digit()),
        "{token}"
    );
    assert!(
        !nonce.is_empty() && nonce.bytes().all(|b| b.is_ascii_digit()),
        "{token}"
    );
    assert_eq!(store.doc(&store.item_path(ITEM))["ci_round_id"], token);
    let second = store.ok(&["state", "new-round-id", "--item", ITEM, "/ci_round_id"]);
    assert_ne!(second["value"], token);
}

/// The fleet record's `handoff` is the overseer's own: a pointer write there
/// stands, its `written_at` stamped, where an item's refuses toward
/// `record-handoff`; the standing read and the resume answer for it as for
/// an item's. A lane's handoff written through `record-handoff` keeps the
/// session, pane, cause and model the relaunch reads.
#[test]
fn the_overseers_handoff_is_a_stamped_pointer_write_and_a_lanes_keeps_its_session_fields() {
    let store = Store::new();
    store.init_fleet();
    let record = r#"{"handoff_file":"tmp/handoffs/OVERSEER-HANDOFF.md","pane_key":"41020:%7","session_id":"0f3d","context":{"used_pct":81}}"#;
    let before = now_secs();
    let written = store.ok(&["state", "set", "--fleet", "/handoff", record]);
    let stamp = written["value"]["written_at"].as_str().unwrap();
    assert!(iso_shaped(stamp), "{stamp}");
    assert!(agent_runtime::clock::epoch_secs(stamp).unwrap() >= before);
    let (key, _) = store.refused(&["state", "set", "--fleet", "/handoff", r#""pending""#]);
    assert_eq!(key, "handoff-record");
    let future = r#"{"written_at":"2099-01-01T00:00:00Z","pane_key":"x"}"#;
    let (key, _) = store.refused(&["state", "set", "--fleet", "/handoff", future]);
    assert_eq!(key, "handoff-written-at-future");
    let standing = store.ok(&["state", "handoff-standing", "--item", "oversee"]);
    assert_eq!(standing["standing"], "stands");
    assert_eq!(standing["record"]["session_id"], "0f3d");
    let resumed = store.ok(&["state", "handoff-resume", "--item", "oversee"]);
    assert_eq!(resumed["resumed"].as_array().unwrap().len(), 1);
    assert!(store.doc(&store.fleet_path())["handoff"]["resumed_at"].is_number());
    assert_eq!(
        store.ok(&["state", "handoff-standing", "--item", "oversee"])["standing"],
        "none"
    );

    store.init(ITEM);
    let request = store.write_file(
        "handoff.json",
        &json!({"op": "record-handoff", "supersede": true, "remaining": ["submit-pr"], "branch": "b",
            "session_id": "s-1", "pane_key": "41020:%3", "cause": "model-switched", "model": "claude-opus-5-5"})
        .to_string(),
    );
    store.ok(&["op", "--item", ITEM, "--request", &request]);
    let standing = store.ok(&["state", "handoff-standing", "--item", ITEM]);
    assert_eq!(standing["record"]["session_id"], "s-1");
    assert_eq!(standing["record"]["cause"], "model-switched");
    assert_eq!(standing["record"]["model"], "claude-opus-5-5");
    assert_eq!(standing["record"]["pane_key"], "41020:%3");
    assert!(standing["record"].get("written_at").is_some());
    // A second switch: the hook's `supersede: true` replaces the standing
    // record, where a write without it refuses the differing content.
    let again = store.write_file(
        "handoff2.json",
        &json!({"op": "record-handoff", "remaining": ["submit-pr"], "branch": "b",
            "session_id": "s-2", "pane_key": "41020:%3", "cause": "model-switched", "model": "claude-sonnet-5-5"})
        .to_string(),
    );
    let out = store.run(&["op", "--item", ITEM, "--request", &again]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(reply(&out)["refusal"]["key"], "handoff-differs");
    let superseding = store.write_file(
        "handoff3.json",
        &json!({"op": "record-handoff", "supersede": true, "remaining": ["submit-pr"], "branch": "b",
            "session_id": "s-2", "pane_key": "41020:%3", "cause": "model-switched", "model": "claude-sonnet-5-5"})
        .to_string(),
    );
    let replaced = store.ok(&["op", "--item", ITEM, "--request", &superseding]);
    assert_eq!(replaced["report"]["replaced"], true);
    let standing = store.ok(&["state", "handoff-standing", "--item", ITEM]);
    assert_eq!(standing["record"]["session_id"], "s-2");
    assert_eq!(standing["record"]["model"], "claude-sonnet-5-5");
}

/// Defect: a close-out that removes the item's record, its lock and a
/// writer's temporary file while a writer holds the record's lock, so the
/// write in flight is lost and the archive holds the record before it.
/// The runtime's own lock guard held: `state remove` waits on it and
/// refuses `lock-timeout`, the record and its lock untouched.
#[test]
fn state_remove_waits_on_the_records_lock_a_writer_holds() {
    let store = Store::new();
    store.init(ITEM);
    store.init_fleet();
    let path = store.item_path(ITEM);
    let before = fs::read_to_string(&path).unwrap();
    let fleet_dir = store.dir.path().display().to_string();
    let mut guard = agent_runtime::record::lock(&path).unwrap();
    guard
        .with(|| {
            let (key, _) = refused_env(
                &store,
                &["state", "remove", "--item", ITEM],
                &[("FLEET_DIR", &fleet_dir)],
            );
            assert_eq!(key, "lock-timeout");
            assert_eq!(fs::read_to_string(&path).unwrap(), before);
            assert!(agent_runtime::record::lock_path(&path).exists());
            Ok(())
        })
        .unwrap();
}

/// Defect: as above, with the shell store's `update` as the writer, held
/// between its locked read and its move by a `jq` that waits for a release:
/// `state remove` refuses `lock-timeout` and leaves the writer's temporary
/// file; released, the writer lands its update, and the close-out then
/// archives the record holding it and removes the record, its lock staying.
#[test]
fn state_remove_keeps_a_shell_store_update_in_flight() {
    use std::os::unix::fs::PermissionsExt;
    let store = Store::new();
    store.init(ITEM);
    store.init_fleet();
    let path = store.item_path(ITEM);
    let tools = store.dir.path().join("bin");
    fs::create_dir(&tools).unwrap();
    let jq = tools.join("jq");
    fs::write(
        &jq,
        r#"#!/bin/sh
case "$*" in
  *review_inflight*)
    "$REAL_JQ" "$@" > "$HOLD_CAPTURE" || exit 1
    : > "$HOLD_READY"
    n=0
    while [ ! -e "$HOLD_RELEASE" ]; do
      n=$((n + 1))
      [ "$n" -lt 3000 ] || exit 1
      sleep 0.01
    done
    cat "$HOLD_CAPTURE" ;;
  *) exec "$REAL_JQ" "$@" ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&jq, fs::Permissions::from_mode(0o755)).unwrap();
    let ready = store.dir.path().join("ready");
    let release = store.dir.path().join("release");
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/workflow-state");
    let mut writer = support::program(&script);
    writer
        .args(["--no-private-env", "--state-dir"])
        .arg(store.state_dir())
        .args(["update", ITEM, ".review_inflight = \"latest turn\""])
        .env("PATH", support::tool_path(&[tools.as_path()]))
        .env("REAL_JQ", real("jq"))
        .env("HOLD_READY", &ready)
        .env("HOLD_RELEASE", &release)
        .env("HOLD_CAPTURE", store.dir.path().join("captured"))
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped());
    let mut writer = support::Owned(writer.spawn().unwrap());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !ready.exists() {
        assert!(
            std::time::Instant::now() < deadline,
            "the writer reached its locked read"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let fleet_dir = store.dir.path().display().to_string();
    let remove = ["state", "remove", "--item", ITEM];
    let (key, _) = refused_env(&store, &remove, &[("FLEET_DIR", &fleet_dir)]);
    assert_eq!(key, "lock-timeout");
    fs::write(&release, "").unwrap();
    let status = writer.0.wait().unwrap();
    let mut cause = String::new();
    std::io::Read::read_to_string(&mut writer.0.stderr.take().unwrap(), &mut cause).unwrap();
    assert!(status.success(), "{cause}");
    assert_eq!(store.doc(&path)["review_inflight"], "latest turn");
    let closed = store.ok_env(&remove, &[("FLEET_DIR", &fleet_dir)]);
    let archive = closed["kept"].as_str().expect("the archive");
    let held: Value = serde_json::from_str(&archived_file(archive, &path)).unwrap();
    assert_eq!(held["review_inflight"], "latest turn");
    assert!(!path.exists());
    assert!(
        agent_runtime::record::lock_path(&path).exists(),
        "the lock stays"
    );
}

/// Defect: a shell writer that waits on the record's lock while the
/// close-out holds it and writes once it gets it: it recreates a record the
/// close-out removed, or a write that landed before the close-out is
/// missing from its archive. An update lands first; the close-out is then
/// held inside its archive by a `tar` that waits for a release, and a
/// second shell `update` starts against the held lock. It does not finish
/// while the close-out holds the lock; released, the close-out ends and the
/// writer refuses on the record it finds gone, no record and no temporary
/// file stand, and the archive holds the landed update and not the late one.
#[test]
fn state_remove_leaves_a_shell_update_waiting_on_its_lock_no_record_to_write() {
    use std::os::unix::fs::PermissionsExt;
    let store = Store::new();
    store.init(ITEM);
    store.init_fleet();
    let path = store.item_path(ITEM);
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/workflow-state");
    let shell = |expr: &str| {
        let mut command = support::program(&script);
        command
            .args(["--no-private-env", "--state-dir"])
            .arg(store.state_dir())
            .args(["update", ITEM, expr]);
        command
    };
    let landed = shell(".landed = \"before the close-out\"")
        .output()
        .unwrap();
    assert!(
        landed.status.success(),
        "{}",
        String::from_utf8_lossy(&landed.stderr)
    );
    let tools = store.dir.path().join("bin");
    fs::create_dir(&tools).unwrap();
    let tar = tools.join("tar");
    fs::write(
        &tar,
        r#"#!/bin/sh
: > "$HOLD_READY"
n=0
while [ ! -e "$HOLD_RELEASE" ]; do
  n=$((n + 1))
  [ "$n" -lt 3000 ] || exit 1
  sleep 0.01
done
exec "$REAL_TAR" "$@"
"#,
    )
    .unwrap();
    fs::set_permissions(&tar, fs::Permissions::from_mode(0o755)).unwrap();
    let ready = store.dir.path().join("ready");
    let release = store.dir.path().join("release");
    let mut remove = support::isolated();
    remove
        .arg("--state-dir")
        .arg(store.state_dir())
        .args(["state", "remove", "--item", ITEM])
        .env("PATH", support::tool_path(&[tools.as_path()]))
        .env("REAL_TAR", real("tar"))
        .env("HOLD_READY", &ready)
        .env("HOLD_RELEASE", &release)
        .env("FLEET_DIR", store.dir.path())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut remove = support::Owned(remove.spawn().unwrap());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !ready.exists() {
        assert!(
            std::time::Instant::now() < deadline,
            "the close-out reached its archive"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let mut late = shell(".late = 1");
    late.stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped());
    let mut late = support::Owned(late.spawn().unwrap());
    // Bounded, and only the control's reach depends on it: a writer that
    // has not reached its lock by then is held there all the same.
    let held = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while std::time::Instant::now() < held {
        assert!(
            late.0.try_wait().unwrap().is_none(),
            "the writer finished while the close-out held the lock"
        );
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    fs::write(&release, "").unwrap();
    let status = remove.0.wait().unwrap();
    let mut reply_text = String::new();
    std::io::Read::read_to_string(&mut remove.0.stdout.take().unwrap(), &mut reply_text).unwrap();
    assert!(status.success(), "{reply_text}");
    let status = late.0.wait().unwrap();
    let mut cause = String::new();
    std::io::Read::read_to_string(&mut late.0.stderr.take().unwrap(), &mut cause).unwrap();
    assert!(!status.success(), "the late writer wrote: {cause}");
    assert!(
        cause.starts_with("workflow-state: jq-failed")
            || cause.starts_with("workflow-state: state-missing"),
        "{cause}"
    );
    assert!(!path.exists(), "no record recreated");
    assert!(!PathBuf::from(format!("{}.tmp", path.display())).exists());
    let reply: Value = serde_json::from_str(&reply_text).unwrap();
    let archive = reply["result"]["kept"].as_str().expect("the archive");
    let held: Value = serde_json::from_str(&archived_file(archive, &path)).unwrap();
    assert_eq!(held["landed"], "before the close-out");
    assert_eq!(held.get("late"), None);
}

/// Defect: the overseer mailbox's session rows files kept for good after
/// their pane is gone, or one taken whose pane still runs or whose server
/// does not answer. `state remove` with no fleet state runs the retention
/// pass, its ambient server a private one: the file of a pane that server
/// does not hold leaves, archived; the file of its live pane and the file
/// of a pid that is not the answering server stand.
#[test]
fn state_remove_retires_the_session_rows_of_a_pane_the_server_no_longer_holds() {
    let store = Store::new();
    store.init(ITEM);
    let server = support::Server::start(store.dir.path(), "rows");
    let live_pane = server.panes()[0].trim_start_matches('%').to_owned();
    let sleeper = support::Owned::sleep();
    let overseer = store.dir.path().join("tmp/lane-mail/overseer");
    fs::create_dir_all(&overseer).unwrap();
    let rows = |pid: u32, pane: &str| {
        let file = overseer.join(format!("session-{pid}-{pane}.jsonl"));
        fs::write(&file, "{}\n").unwrap();
        file
    };
    let dead = rows(server.pid, "99999");
    let live = rows(server.pid, &live_pane);
    let unanswering = rows(sleeper.pid(), "1");
    let mut command = support::isolated();
    command
        .arg("--state-dir")
        .arg(store.state_dir())
        .args(["state", "remove", "--item", ITEM])
        .env("FLEET_DIR", store.dir.path())
        .env(
            "TMUX",
            format!("{},{},0", server.socket.display(), server.pid),
        )
        .current_dir(store.dir.path());
    let out = command.output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let pruned = &reply(&out)["result"]["pruned"];
    let dead = fs::canonicalize(overseer.join("."))
        .unwrap()
        .join(dead.file_name().unwrap());
    assert_eq!(pruned["paths"], json!([dead.display().to_string()]));
    assert!(!dead.exists());
    assert!(live.exists() && unanswering.exists());
    let archive = pruned["kept"].as_str().expect("the archive");
    assert_eq!(archived_file(archive, &dead), "{}\n");
}

/// Defect: a close-out that unlinks the record's lock pathname, so a shell
/// writer waiting on the unlinked inode and a runtime writer on the new one
/// both hold "the" lock once `state init` creates the key again, and the
/// first to commit is overwritten. The close-out held at its archive while
/// a shell `update` waits on the lock; released, the key is created again
/// before the shell reads it, and a `state set` starts while the shell
/// holds the lock: it waits, and the record keeps both writes.
#[test]
fn a_reinitialized_item_keeps_both_old_and_new_lock_writers() {
    use std::os::unix::fs::PermissionsExt;
    use std::process::Stdio;
    if real("flock").is_empty() {
        // Without flock(1) the shell's mkdir mutex is the lock, and the
        // close-out never removes it.
        return;
    }
    let store = Store::new();
    store.init(ITEM);
    store.init_fleet();
    let tools = store.dir.path().join("tools");
    fs::create_dir(&tools).unwrap();
    let fixtures = [
        (
            "tar",
            r#"#!/bin/sh
: > "$TAR_READY"
while [ ! -e "$TAR_RELEASE" ]; do sleep 0.01; done
exec "$REAL_TAR" "$@"
"#,
        ),
        (
            "flock",
            r#"#!/bin/sh
: > "$WRITER_WAITING"
"$REAL_FLOCK" "$@" || exit
: > "$WRITER_ACQUIRED"
while [ ! -e "$INIT_READY" ]; do sleep 0.01; done
"#,
        ),
        (
            "jq",
            r#"#!/bin/sh
case "$*" in
  *review_a*)
    "$REAL_JQ" "$@" > "$WRITER_CAPTURE" || exit 1
    : > "$WRITER_READ"
    while [ ! -e "$WRITER_RELEASE" ]; do sleep 0.01; done
    cat "$WRITER_CAPTURE" ;;
  *) exec "$REAL_JQ" "$@" ;;
esac
"#,
        ),
    ];
    for (name, text) in fixtures {
        let path = tools.join(name);
        fs::write(&path, text).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let at = |name: &str| store.dir.path().join(name);
    let wait = |file: &Path| {
        let bound = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !file.exists() {
            assert!(std::time::Instant::now() < bound, "no {}", file.display());
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    };
    let mut remove = support::isolated();
    remove
        .arg("--state-dir")
        .arg(store.state_dir())
        .args(["state", "remove", "--item", ITEM])
        .env("FLEET_DIR", store.dir.path())
        .env("PATH", support::tool_path(&[&tools]))
        .env("REAL_TAR", real("tar"))
        .env("TAR_READY", at("tar.ready"))
        .env("TAR_RELEASE", at("tar.release"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut remove = support::Owned(remove.spawn().unwrap());
    wait(&at("tar.ready"));
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/workflow-state");
    let mut old = support::program(script);
    old.args(["--no-private-env", "--state-dir"])
        .arg(store.state_dir())
        .args(["update", ITEM, ".review_a = \"old-lock\""])
        .env("PATH", support::tool_path(&[&tools]))
        .env("REAL_FLOCK", real("flock"))
        .env("REAL_JQ", real("jq"))
        .env("WRITER_WAITING", at("writer.waiting"))
        .env("WRITER_ACQUIRED", at("writer.acquired"))
        .env("INIT_READY", at("init.ready"))
        .env("WRITER_CAPTURE", at("writer.capture"))
        .env("WRITER_READ", at("writer.read"))
        .env("WRITER_RELEASE", at("writer.release"))
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    let mut old = support::Owned(old.spawn().unwrap());
    wait(&at("writer.waiting"));
    fs::write(at("tar.release"), "").unwrap();
    assert!(remove.0.wait().unwrap().success());
    wait(&at("writer.acquired"));
    store.init(ITEM);
    fs::write(at("init.ready"), "").unwrap();
    wait(&at("writer.read"));
    let mut new = support::isolated();
    new.arg("--state-dir")
        .arg(store.state_dir())
        .args(["state", "set", "--item", ITEM, "/review_b", "new-lock"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut new = support::Owned(new.spawn().unwrap());
    // Bounded, and only the control's reach depends on it: a `set` that
    // has not reached the lock by then waits on it all the same.
    let held = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while std::time::Instant::now() < held && new.0.try_wait().unwrap().is_none() {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    fs::write(at("writer.release"), "").unwrap();
    assert!(old.0.wait().unwrap().success());
    assert!(new.0.wait().unwrap().success());
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["review_a"], "old-lock");
    assert_eq!(
        doc["review_b"], "new-lock",
        "the write through a new inode was lost"
    );
}

/// Defect: the retention pass judges a stale item record and then removes
/// it after a writer updated it, so a resumed workflow loses its record:
/// the record's content was read when the pass selected it, not compared at
/// the removal. `state remove` with no fleet state runs the pass; the
/// stale record is selected, and the shell store updates it during the
/// pass's own tmux read after that: the record stands, updated.
#[test]
fn retention_keeps_a_record_written_after_its_selection() {
    use std::os::unix::fs::PermissionsExt;
    let store = Store::new();
    store.init("KEN-9");
    let record = store.item_path("KEN-9");
    fs::File::open(&record)
        .unwrap()
        .set_modified(UNIX_EPOCH + std::time::Duration::from_secs(now_secs() - 10 * 86_400))
        .unwrap();
    let server = support::Server::start(store.dir.path(), "stamp");
    let overseer = store.dir.path().join("tmp/lane-mail/overseer");
    fs::create_dir_all(&overseer).unwrap();
    fs::write(
        overseer.join(format!("session-{}-99999.jsonl", server.pid)),
        "{}\n",
    )
    .unwrap();
    let tools = store.dir.path().join("tools");
    fs::create_dir(&tools).unwrap();
    let shim = tools.join("tmux");
    fs::write(
        &shim,
        r#"#!/bin/sh
if [ ! -e "$WROTE" ]; then
  : > "$WROTE"
  /bin/bash "$STORE" --no-private-env --state-dir "$STATE" update KEN-9 '.review_turn = "resumed"' || exit
fi
exec "$REAL_TMUX" "$@"
"#,
    )
    .unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/workflow-state");
    let out = support::isolated()
        .arg("--state-dir")
        .arg(store.state_dir())
        .args(["state", "remove", "--item", "KEN-OTHER"])
        .env("FLEET_DIR", store.dir.path())
        .env(
            "TMUX",
            format!("{},{},0", server.socket.display(), server.pid),
        )
        .env("PATH", support::tool_path(&[&tools]))
        .env("REAL_TMUX", real("tmux"))
        .env("STORE", script)
        .env("STATE", store.state_dir())
        .env("WROTE", store.dir.path().join("wrote"))
        .current_dir(store.dir.path())
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(store.dir.path().join("wrote").exists(), "the update ran");
    assert_eq!(store.doc(&record)["review_turn"], "resumed");
}

/// Defect: a relative `--archive` path read against the runtime's own
/// working directory, or handed to `tar` from `/`, so the caller's path is
/// not archived. Run from a directory holding `extra/run.log` with
/// `--archive extra`: the archive holds that file under its absolute path.
#[test]
fn state_remove_archives_a_relative_path_from_the_callers_directory() {
    let store = Store::new();
    store.init(ITEM);
    store.init_fleet();
    let caller = store.dir.path().join("caller");
    fs::create_dir_all(caller.join("extra")).unwrap();
    let log = caller.join("extra").join("run.log");
    fs::write(&log, "kept\n").unwrap();
    let mut command = support::isolated();
    command
        .arg("--state-dir")
        .arg(store.state_dir())
        .args(["state", "remove", "--item", ITEM, "--archive", "extra"])
        .env("FLEET_DIR", store.dir.path())
        .current_dir(&caller);
    let out = command.output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let archive = reply(&out)["result"]["kept"]
        .as_str()
        .expect("the archive")
        .to_owned();
    let log = fs::canonicalize(&log).unwrap();
    assert_eq!(archived_file(&archive, &log), "kept\n");
}

/// Defect: a relative `ORCH_ARCHIVE_ROOT` refusing the whole settings load,
/// so every verb, and every hook read through one, refuses. A relative
/// root: `state path --fleet` answers, `state init` writes, and `state
/// remove`, which writes an archive, refuses it by key and value with the
/// record standing.
#[test]
fn a_relative_archive_root_refuses_the_archive_write_alone() {
    let store = Store::new();
    let env = [("ORCH_ARCHIVE_ROOT", "archives")];
    let fleet = store.ok_env(&["state", "path", "--fleet"], &env);
    assert_eq!(fleet["path"], store.fleet_path().display().to_string());
    store.ok_env(&["state", "init", "--item", ITEM], &env);
    let out = store.run_env(&["state", "remove", "--item", ITEM], &env);
    let answer = reply(&out);
    assert_eq!(answer["refusal"]["key"], "setting-invalid", "{answer}");
    assert_eq!(
        answer["refusal"]["fields"],
        json!([["key", "ORCH_ARCHIVE_ROOT"], ["value", "archives"]])
    );
    assert!(store.item_path(ITEM).exists());
}
