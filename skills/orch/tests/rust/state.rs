//! The state verbs through the executable: the pointer writes under the
//! record's lock, the file-bound appends, the value judge, the round caps
//! and retry budgets, the post-PR stop, the fleet log and standing rows,
//! the handoff record's places, the reads and the item's close-out; and the
//! named record writes the workflows run through `op`, which own the fields
//! a pointer write is held to.
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

    /// The `result` of the named operation `request` on the item, given
    /// whole on argv as a workflow's one line gives it.
    fn op_ok(&self, request: &Value) -> Value {
        self.ok(&["op", "--item", ITEM, "--request-json", &request.to_string()])
    }

    /// The refusal of `request` on the item, the record left byte for byte
    /// as it stood.
    fn op_refused(&self, request: &Value) -> (String, String) {
        let path = self.item_path(ITEM);
        let before = fs::read_to_string(&path).unwrap();
        let refusal = self.refused(&["op", "--item", ITEM, "--request-json", &request.to_string()]);
        assert_eq!(fs::read_to_string(&path).unwrap(), before, "{request}");
        refusal
    }

    /// The `result` of the named operation `request` on the fleet record.
    fn fleet_op_ok(&self, request: &Value) -> Value {
        self.ok(&["op", "--fleet", "--request-json", &request.to_string()])
    }

    /// The refusal of `request` on the fleet record, the record left byte
    /// for byte as it stood.
    fn fleet_op_refused(&self, request: &Value) -> (String, String) {
        let path = self.fleet_path();
        let before = fs::read_to_string(&path).unwrap();
        let refusal = self.refused(&["op", "--fleet", "--request-json", &request.to_string()]);
        assert_eq!(fs::read_to_string(&path).unwrap(), before, "{request}");
        refusal
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
/// holding none or two values, or no file, refuses with the record untouched;
/// under `--unique` a value the array holds is not appended again.
#[test]
fn append_file_carries_bytes_the_shell_would_split_and_refuses_what_is_not_one_value() {
    let store = Store::new();
    store.init(ITEM);
    let cause = json!({
        "cause": "fs.rs::write_all's guard \"quoted\" $(whoami) `id` | ;\nsecond line\ttab",
        "commit": "abc1234",
        "location": "fs.rs:12"
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

    // The proposed rules as `main`'s deduplicating update left them, sorted;
    // a `--unique` append adds a new rule after them and a held one never.
    let rules = "/pr_comment_review/proposed_rules";
    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        rules,
        r#"["a rule","b rule"]"#,
    ]);
    let rule = store.write_file("rule.json", r#""0 rule""#);
    let unique = |file: &str| {
        store.ok(&[
            "state",
            "append-file",
            "--item",
            ITEM,
            "--unique",
            rules,
            file,
        ])["appended"]
            .clone()
    };
    assert_eq!(unique(&rule), json!(true));
    assert_eq!(unique(&rule), json!(false), "a held rule is not appended");
    assert_eq!(
        unique(&store.write_file("held.json", r#""a rule""#)),
        json!(false)
    );
    assert_eq!(
        store.doc(&store.item_path(ITEM))["pr_comment_review"]["proposed_rules"],
        json!(["a rule", "b rule", "0 rule"])
    );
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
        ("/pr_review/round", "007", json!(7)),
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
/// replay; a passing run's reset restarts it and leaves the other budget;
/// `review-wait` restarts on a new head and holds a `small` item to two
/// rounds.
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
    let reset = |kind: &str| {
        store.ok(&[
            "state",
            "head-budget",
            "reset",
            "--item",
            ITEM,
            "--kind",
            kind,
        ])["result"]
            .clone()
    };
    assert_eq!(reset("ci-fix"), "reset");
    assert_eq!(
        reset("ci-fix"),
        "none",
        "a restarted budget has nothing spent"
    );
    assert_eq!(take("ci-fix", "head-d", "2"), "continue 1/2");

    assert_eq!(take("review-wait", "h1", "4"), "continue 1/4");
    assert_eq!(take("review-wait", "h1", "4"), "continue 2/4");
    assert_eq!(take("review-wait", "h2", "4"), "continue 1/4");
    store.ok(&["state", "set", "--item", ITEM, "/tier", "small"]);
    assert_eq!(take("review-wait", "h2", "4"), "continue 2/2");
    assert_eq!(take("review-wait", "h2", "4"), "at-cap 2/2");
    assert_eq!(reset("review-wait"), "reset");
    assert_eq!(take("review-wait", "h2", "4"), "continue 1/2");
    assert_eq!(
        store.doc(&store.item_path(ITEM))["post_pr_budgets"]["ci_fix"]["attempts"],
        1,
        "a reset leaves the other budget"
    );
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
    let clear = || store.ok(&["state", "post-pr-stop", "clear", "--item", ITEM])["result"].clone();
    assert_eq!(clear(), "cleared");
    assert_eq!(
        store.doc(&store.item_path(ITEM))["post_pr_stop"],
        Value::Null
    );
    assert_eq!(clear(), "none");
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
/// reviewers with the external lane counted. A pointer write of a panel is
/// `record-panel`'s write, held to the panel's rules and shape alike.
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

    let panel = |which: &str, agents: Value, rest: Value| -> Value {
        let mut request =
            json!({"op": "record-panel", "panel": which, "agents": agents, "reason": "t"});
        for (key, value) in rest.as_object().unwrap() {
            request[key] = value.clone();
        }
        request
    };
    let four = panel(
        "first",
        json!(["r1", "r2", "r3", "r4"]),
        json!({"external": false}),
    );
    assert_eq!(store.op_refused(&four).0, "panel-bound");
    let unmarked = panel("first", json!(["r1"]), json!({}));
    assert_eq!(store.op_refused(&unmarked).0, "panel-external");
    let three_external = panel(
        "first",
        json!(["r1", "r2", "r3"]),
        json!({"external": true}),
    );
    assert_eq!(store.op_refused(&three_external).0, "panel-bound");
    let twice = panel("first", json!(["r1", "r1"]), json!({"external": false}));
    assert_eq!(store.op_refused(&twice).0, "panel-agents");
    store.op_ok(&panel(
        "first",
        json!(["r1", "r2"]),
        json!({"external": true}),
    ));
    let copy = panel(
        "verification",
        json!(["r1", "r2"]),
        json!({"external": false}),
    );
    let (key, line) = store.op_refused(&copy);
    assert_eq!(key, "panel-copy");
    assert!(line.ends_with("uncovered=r1,r2"), "{line}");
    let reasoned = panel(
        "verification",
        json!(["r1", "r2"]),
        json!({"external": false, "domain_reasons": {"r1": "fs", "r2": "docs"}}),
    );
    store.op_ok(&reasoned);
    assert_eq!(
        store.doc(&store.item_path(ITEM))["verification_panel"]["domain_reasons"],
        json!({"r1": "fs", "r2": "docs"})
    );
    let (key, line) = store.refused(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/first_panel",
        r#"{"agents": ["r1"], "reason": "t", "external": false, "extra": 1}"#,
    ]);
    assert_eq!(
        key, "field-owned",
        "a pointer write is held to the panel's shape"
    );
    assert!(line.contains("op=record-panel"), "{line}");
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
/// acknowledges, through the ledger's `triage` entry and the pointer verbs
/// alike; a string row or an `item`-keyed one would rebuild no key.
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
    let triage =
        |file: &str| json!({"op": "record-overseer-ledger", "entry": "triage", "file": file});
    for row in rows {
        let (key, _) = store.refused(&["state", "append", "--fleet", "/triaged", row]);
        assert_eq!(key, "triaged-record-invalid", "{row}");
        let file = store.write_file("triaged.json", row);
        let (key, _) = store.refused(&["state", "append-file", "--fleet", "/triaged", &file]);
        assert_eq!(key, "triaged-record-invalid", "{row}");
        let (key, _) = store.fleet_op_refused(&triage(&file));
        assert_eq!(key, "triaged-record-invalid", "{row}");
    }
    assert_eq!(fs::read_to_string(store.fleet_path()).unwrap(), before);
    let kept = store.write_file(
        "kept.json",
        r#"{"issue":"KEN-4137","verdict":"kept","reason":"checked"}"#,
    );
    let entered = store.fleet_op_ok(&triage(&kept));
    assert_eq!(
        (&entered["entry"], &entered["pointer"]),
        (&json!("triage"), &json!("/triaged"))
    );
    store.ok(&[
        "state",
        "append",
        "--fleet",
        "/triaged",
        r#"{"issue":"KEN-4138","verdict":"canceled","reason":"checked"}"#,
    ]);
    let triaged = store.doc(&store.fleet_path())["triaged"].clone();
    assert_eq!(
        (&triaged[0]["issue"], &triaged[1]["verdict"]),
        (&json!("KEN-4137"), &json!("canceled"))
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

/// The fleet record's `handoff` is the overseer's own: the ledger's
/// `handoff` entry and a pointer write there land it with its `written_at`
/// stamped, where an item's refuses toward
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
    // The ledger's `handoff` entry is the same write, one request on argv.
    let entry = json!({"op": "record-overseer-ledger", "entry": "handoff",
        "handoff_file": "tmp/handoffs/OVERSEER-HANDOFF.md", "pane_key": "41020:%7",
        "session_id": "0f3d", "context": {"used_pct": 81}});
    let written = store.fleet_op_ok(&entry);
    assert_eq!(
        (&written["entry"], &written["pointer"]),
        (&json!("handoff"), &json!("/handoff"))
    );
    let stamp = written["value"]["written_at"].as_str().unwrap();
    assert!(iso_shaped(stamp), "{stamp}");
    assert_eq!(store.doc(&store.fleet_path())["handoff"], written["value"]);
    let mut ahead = entry.clone();
    ahead["written_at"] = json!("2099-01-01T00:00:00Z");
    let (key, _) = store.fleet_op_refused(&ahead);
    assert_eq!(key, "handoff-written-at-future");
    let mut unnamed = entry.clone();
    unnamed.as_object_mut().unwrap().remove("session_id");
    let (key, _) = store.fleet_op_refused(&unnamed);
    assert_eq!(key, "request-invalid");
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

/// A close-out under a writer's held lock would lose the write in flight
/// and archive the record before it. The runtime's own lock guard held:
/// `state remove` waits on it and refuses `lock-timeout`, the record and
/// its lock untouched.
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

/// The shell store's `update` as the writer, held between its locked read
/// and its move by a `jq` that waits for a release: `state remove` refuses
/// `lock-timeout` and leaves the writer's temporary file; released, the
/// writer lands its update, and the close-out then archives the record
/// holding it and removes the record, its lock staying.
#[test]
fn state_remove_keeps_a_shell_store_update_in_flight() {
    let store = Store::new();
    store.init(ITEM);
    store.init_fleet();
    let path = store.item_path(ITEM);
    let tools = store.dir.path().join("bin");
    fs::create_dir(&tools).unwrap();
    let jq = tools.join("jq");
    support::write_executable(
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
    );
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

/// An update lands first; the close-out is then held inside its archive by
/// a `tar` that waits for a release, and a second shell `update` starts
/// against the held lock. It does not finish while the close-out holds the
/// lock; released, the close-out ends and the writer refuses on the record
/// it finds gone, no record and no temporary file stand, and the archive
/// holds the landed update and not the late one.
#[test]
fn state_remove_leaves_a_shell_update_waiting_on_its_lock_no_record_to_write() {
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
    support::write_executable(
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
    );
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

/// `state remove` with no fleet state runs the retention pass, its ambient
/// server a private one: the file of a pane that server does not hold
/// leaves, archived; the file of its live pane and the file of a pid that
/// is not the answering server stand.
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

/// An unlinked lock pathname would let a shell writer on the unlinked inode
/// and a runtime writer on the new one both hold the lock once `state init`
/// creates the key again. The close-out held at its archive while a shell
/// `update` waits on the lock; released, the key is created again before
/// the shell reads it, and a `state set` starts while the shell holds the
/// lock: it waits, and the record keeps both writes.
#[test]
fn a_reinitialized_item_keeps_both_old_and_new_lock_writers() {
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
        support::write_executable(&path, text);
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

/// The record's content is compared at the removal, not only when the pass
/// selected it. `state remove` with no fleet state runs the pass; the stale
/// record is selected, and the shell store updates it during the pass's own
/// tmux read after that: the record stands, updated.
#[test]
fn retention_keeps_a_record_written_after_its_selection() {
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
    support::write_executable(
        &shim,
        r#"#!/bin/sh
if [ ! -e "$WROTE" ]; then
  : > "$WROTE"
  /bin/bash "$STORE" --no-private-env --state-dir "$STATE" update KEN-9 '.review_turn = "resumed"' || exit
fi
exec "$REAL_TMUX" "$@"
"#,
    );
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

/// Run from a directory holding `extra/run.log` with `--archive extra`: the
/// archive holds that file under its absolute path.
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

/// A state setting outside its form refuses the state verb that reads it
/// alone, never the settings load every verb and hook reads through:
/// `state path --fleet` answers and `state init` writes under each. A
/// relative `ORCH_ARCHIVE_ROOT` and a retention of none refuse `state
/// remove`, which writes an archive and, where no fleet stands, prunes,
/// with the record standing; the takeover window, the row bound and the
/// round caps refuse the read or the write that uses them.
#[test]
fn a_relative_archive_root_refuses_the_archive_write_alone() {
    let remove = |_: &Store| {
        vec![
            "state".to_owned(),
            "remove".into(),
            "--item".into(),
            ITEM.into(),
        ]
    };
    type Args = Box<dyn Fn(&Store) -> Vec<String>>;
    let cases: Vec<(&str, &str, bool, Args)> = vec![
        ("ORCH_ARCHIVE_ROOT", "archives", false, Box::new(remove)),
        ("ORCH_RECORD_RETENTION_DAYS", "0", false, Box::new(remove)),
        (
            "ORCH_TAKEOVER_ROWS",
            "x",
            true,
            Box::new(|_| {
                ["state", "log", "takeover", "--fleet"]
                    .map(str::to_owned)
                    .to_vec()
            }),
        ),
        (
            "ORCH_FLEET_LOG_ROW_BYTES",
            "-1",
            true,
            Box::new(|store| {
                let row = store.write_file("row.json", r#"{"kind":"ruling","text":"t"}"#);
                vec![
                    "state".into(),
                    "log".into(),
                    "append".into(),
                    "--fleet".into(),
                    row,
                ]
            }),
        ),
        (
            "REVIEW_MAX_CYCLES",
            "1.5",
            false,
            Box::new(|_| {
                ["state", "cap", "REVIEW_MAX_CYCLES"]
                    .map(str::to_owned)
                    .to_vec()
            }),
        ),
        (
            "REVIEW_MAX_EXTERNAL_ROUNDS",
            "two",
            false,
            Box::new(|_| {
                ["state", "cap", "REVIEW_MAX_EXTERNAL_ROUNDS"]
                    .map(str::to_owned)
                    .to_vec()
            }),
        ),
        (
            "CI_FIX_MAX_CYCLES",
            "+6",
            false,
            Box::new(|_| {
                ["state", "cap", "CI_FIX_MAX_CYCLES", "--count", "5"]
                    .map(str::to_owned)
                    .to_vec()
            }),
        ),
    ];
    for (key, value, fleet_stands, args) in cases {
        let store = Store::new();
        let env = [(key, value)];
        let fleet = store.ok_env(&["state", "path", "--fleet"], &env);
        assert_eq!(
            fleet["path"],
            store.fleet_path().display().to_string(),
            "{key}"
        );
        store.ok_env(&["state", "init", "--item", ITEM], &env);
        if fleet_stands {
            store.ok_env(&["state", "init", "--fleet"], &env);
        }
        let args = args(&store);
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let out = store.run_env(&args, &env);
        let answer = reply(&out);
        assert_eq!(
            answer["refusal"]["key"], "setting-invalid",
            "{key}: {answer}"
        );
        assert_eq!(
            answer["refusal"]["fields"],
            json!([["key", key], ["value", value]]),
            "{key}"
        );
        assert!(store.item_path(ITEM).exists(), "{key}: the record stands");
    }
}

/// The archive verbs a caller runs before a removal no state verb makes.
/// `archive write` files its paths as one private tarball under
/// `<root>/<project's name>/oversee` and answers the tarball and that
/// directory; `archive root` answers the root a caller files under. A
/// configured root the caller's removal root, the state directory or a
/// linked worktree of the project would take refuses before anything is
/// written there: an archive inside what is removed next is no copy. Each
/// verb runs from a directory that is no checkout, so the project the write
/// names, not the caller's directory, files the archive.
#[test]
fn the_archive_verbs_file_under_a_root_no_removal_takes() {
    let store = Store::new();
    let tmp = fs::canonicalize(store.dir.path()).unwrap();
    let project = tmp.join("project");
    fs::create_dir_all(&project).unwrap();
    let git = |args: &[&str]| {
        let out = support::program("git")
            .arg("-C")
            .arg(&project)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            support::stderr(&out)
        );
    };
    git(&["init", "-q", "-b", "main"]);
    git(&["commit", "-q", "--allow-empty", "-m", "init"]);
    let worktree = tmp.join("lane");
    git(&[
        "worktree",
        "add",
        "-q",
        &worktree.display().to_string(),
        "-b",
        "lane",
    ]);
    let state = tmp.join("state");
    fs::create_dir_all(&state).unwrap();
    let removal = tmp.join("box");
    fs::create_dir_all(&removal).unwrap();
    let input = removal.join("to-lane.jsonl");
    fs::write(&input, "{\"id\":\"1\"}\n").unwrap();
    let elsewhere = tmp.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    let fleet = tmp.join("fleet");
    let path = |p: &Path| p.display().to_string();
    let write = [
        "archive".to_owned(),
        "write".into(),
        "--project".into(),
        path(&project),
        "--removal-root".into(),
        path(&removal),
        "--stem".into(),
        "compact-KEN-1-7".into(),
        path(&input),
    ];
    let root = ["archive", "root", "--suffix", "repo/KEN-1"].map(str::to_owned);
    /// The case, the verb's words, its working directory, the configured
    /// root, then the archive root answered or the path an overlap names.
    type Case<'a> = (
        &'a str,
        &'a [String],
        &'a Path,
        Option<PathBuf>,
        Result<PathBuf, PathBuf>,
    );
    let cases: Vec<Case> = vec![
        (
            "write, default",
            &write,
            &elsewhere,
            None,
            Ok(fleet.join("archive")),
        ),
        (
            "write, configured",
            &write,
            &elsewhere,
            Some(tmp.join("archives")),
            Ok(tmp.join("archives")),
        ),
        (
            "write, inside the removal root",
            &write,
            &elsewhere,
            Some(removal.join("archives")),
            Err(removal.clone()),
        ),
        (
            "write, inside the state directory",
            &write,
            &elsewhere,
            Some(state.join("archives")),
            Err(state.clone()),
        ),
        (
            "write, inside a linked worktree",
            &write,
            &elsewhere,
            Some(worktree.join("archives")),
            Err(worktree.clone()),
        ),
        (
            "root, default",
            &root,
            &project,
            None,
            Ok(fleet.join("archive")),
        ),
        (
            "root, configured",
            &root,
            &project,
            Some(tmp.join("archives")),
            Ok(tmp.join("archives")),
        ),
        (
            "root, inside the state directory",
            &root,
            &project,
            Some(state.join("archives")),
            Err(state.clone()),
        ),
        (
            "root, inside a linked worktree",
            &root,
            &project,
            Some(worktree.join("archives")),
            Err(worktree.clone()),
        ),
    ];
    for (case, words, cwd, configured, want) in cases {
        let mut command = support::isolated();
        command
            .arg("--state-dir")
            .arg(&state)
            .args(words)
            .env("FLEET_DIR", &fleet)
            .current_dir(cwd);
        if let Some(configured) = &configured {
            command.env("ORCH_ARCHIVE_ROOT", configured);
        }
        let out = command.output().unwrap();
        let answer = reply(&out);
        match want {
            Ok(want) if words[1] == "root" => {
                assert!(out.status.success(), "{case}: {}", support::stderr(&out));
                assert_eq!(answer["result"]["root"], path(&want), "{case}: {answer}");
            }
            Ok(want) => {
                assert!(out.status.success(), "{case}: {}", support::stderr(&out));
                let dir = want.join("project").join("oversee");
                assert_eq!(answer["result"]["dir"], path(&dir), "{case}: {answer}");
                let archive = PathBuf::from(answer["result"]["archive"].as_str().unwrap());
                assert_eq!(archive.parent(), Some(dir.as_path()), "{case}");
                let name = archive.file_name().unwrap().to_string_lossy();
                assert!(
                    name.starts_with("compact-KEN-1-7-") && name.ends_with(".tgz"),
                    "{case}: {name}"
                );
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(
                    fs::metadata(&archive).unwrap().permissions().mode() & 0o777,
                    0o600,
                    "{case}: a private tarball"
                );
                assert_eq!(
                    fs::read_dir(&dir).unwrap().count(),
                    1,
                    "{case}: the tarball alone, its stage removed"
                );
                assert_eq!(
                    archived_file(&path(&archive), &input),
                    "{\"id\":\"1\"}\n",
                    "{case}"
                );
            }
            Err(removed) => {
                assert_eq!(out.status.code(), Some(1), "{case}: {answer}");
                assert_eq!(
                    answer["refusal"]["key"], "archive-root-overlap",
                    "{case}: {answer}"
                );
                assert_eq!(
                    answer["refusal"]["fields"][1],
                    json!(["removed", path(&removed)]),
                    "{case}: {answer}"
                );
                let configured = configured.unwrap();
                assert!(
                    fs::symlink_metadata(&configured).is_err(),
                    "{case}: nothing is written under the refused root"
                );
            }
        }
    }
}

/// Several pointer pairs are one write: every pair lands, or a refused
/// pair or a pointer left without its value writes nothing at all.
#[test]
fn set_and_append_write_every_pair_in_one_transition_and_a_refused_pair_writes_none() {
    let store = Store::new();
    store.init(ITEM);
    store.ok(&["state", "set", "--item", ITEM, "/a", "1", "/b", "x"]);
    store.ok(&[
        "state",
        "append",
        "--item",
        ITEM,
        "/l",
        "1",
        "/m",
        r#"{"k":2}"#,
    ]);
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["a"], 1);
    assert_eq!(doc["b"], "x");
    assert_eq!(doc["l"], json!([1]));
    assert_eq!(doc["m"], json!([{"k": 2}]));
    let (key, _) = store.refused(&["state", "set", "--item", ITEM, "/c", "1", "/d"]);
    assert_eq!(key, "pair-unmatched");
    let (key, _) = store.refused(&["state", "append", "--item", ITEM, "/c", "1", "/d"]);
    assert_eq!(key, "pair-unmatched");
    assert!(store.doc(&store.item_path(ITEM)).get("c").is_none());
    // A field a named operation owns takes only what that operation writes,
    // and the refusal lands none of the call's pairs.
    let (key, line) = store.refused(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/c",
        "1",
        "/review_agents",
        r#"[1]"#,
    ]);
    assert_eq!(key, "field-owned");
    assert!(
        line.contains("field=review_agents op=record-agents"),
        "{line}"
    );
    let (key, _) = store.refused(&[
        "state",
        "append",
        "--item",
        ITEM,
        "/fixed_items",
        r#"{"description":"Fix"}"#,
    ]);
    assert_eq!(key, "field-owned", "a finding names its location");
    let doc = store.doc(&store.item_path(ITEM));
    assert!(doc.get("c").is_none());
    assert_eq!(doc["review_agents"], json!([]));
    assert_eq!(doc["fixed_items"], json!([]));
    store.init_fleet();
    let (key, _) = store.refused(&[
        "state",
        "set",
        "--fleet",
        "/x",
        "1",
        "/handoff",
        r#""pending""#,
    ]);
    assert_eq!(key, "handoff-record");
    assert!(store.doc(&store.fleet_path()).get("x").is_none());
}

/// An upsert replaces the element its key names and refuses a value that
/// lacks the key.
#[test]
fn upsert_replaces_the_element_its_key_names_and_refuses_a_value_without_it() {
    let store = Store::new();
    store.init(ITEM);
    let first = store.write_file("a1.json", r#"{"head":"a","n":1}"#);
    let again = store.write_file("a2.json", r#"{"head":"a","n":2}"#);
    let other = store.write_file("b.json", r#"{"head":"b"}"#);
    let keyless = store.write_file("none.json", r#"{"n":3}"#);
    let up = |file: &str| {
        store.ok(&[
            "state", "upsert", "--item", ITEM, "/heads", "--key", "head", file,
        ])
    };
    assert_eq!(up(&first)["replaced"], 0);
    let replaced = up(&again);
    assert_eq!(replaced["replaced"], 1);
    assert_eq!(replaced["length"], 1);
    assert_eq!(up(&other)["length"], 2);
    assert_eq!(
        store.doc(&store.item_path(ITEM))["heads"],
        json!([{"head": "a", "n": 2}, {"head": "b"}])
    );
    let (key, _) = store.refused(&[
        "state", "upsert", "--item", ITEM, "/heads", "--key", "head", &keyless,
    ]);
    assert_eq!(key, "upsert-key");
}

/// The fleet record as `main` wrote it for a surface-2 fleet: its store's
/// `init oversee` object, then three lanes its overseer appended with the
/// store's `append oversee lanes`, two with their lineage unknown and one
/// bound.
const SURFACE_TWO_FLEET: &str = r#"{"issue_id":"oversee","sub_issues":[],"agent":"","worktree":"","branch":"","qa_labels":[],"near_ceiling":[],"finding_occurrences":{"prior":"none","records":[]},"child_sessions":{},"review_agents":[],"review_agent_ids":{},"review_agent_runtime_types":{},"pre_delegate_sha":null,"skip_qa":false,"cycles":0,"rereview_cycles":0,"json_paths":[],"fixed_items":[],"escalated_items":[],"audit_issues_created":[],"pr_review_baseline":null,"pr_comment_review":{"iterations":0,"fixes":[],"issues_created":[],"skipped":[]},"post_pr_budgets":{"review_wait":null,"ci_fix":null},"post_pr_stop":null,"lanes":[{"item":"KEN-1","tracker":"linear","repo":null,"harness":"codex","window":null,"account":null,"host":null,"mail_root":"/w/ken-1","surface":"gui","model":"gpt-5.5-codex","session_id":null,"launched_at":"2026-10-24T19:00:00Z","status":"running","obligation":null},{"item":"KEN-2","tracker":"linear","repo":null,"harness":"codex","window":null,"account":null,"host":null,"mail_root":"/w/ken-2","surface":"gui","model":"gpt-5.5-codex","session_id":null,"launched_at":"2026-10-24T19:05:00Z","status":"running","obligation":{"repo":"o/r","item":"KEN-2","parent_repo":null,"parent_item":null}},{"item":"KEN-3","tracker":"linear","repo":null,"harness":"codex","window":null,"account":null,"host":null,"mail_root":"/w/ken-3","surface":"gui","model":"gpt-5.5-codex","session_id":null,"launched_at":"2026-10-24T19:10:00Z","status":"running","obligation":null}]}"#;

/// A surface-2 lane's merge, `record-surface-lane`'s and the pointer verb's
/// alike, writes the fields it names into the lane its item finds and binds
/// the lineage once: an absent or null obligation
/// keeps the lane's, an unknown one binds, a known one differing refuses
/// with nothing written, and an obligation of another shape refuses.
#[test]
fn merge_writes_a_lanes_fields_and_binds_its_obligation_once() {
    let store = Store::new();
    fs::create_dir_all(store.state_dir()).unwrap();
    fs::write(store.fleet_path(), SURFACE_TWO_FLEET).unwrap();
    let request = |lane: &str, name: &str, mapping: &str| {
        let file = store.write_file(name, mapping);
        json!({"op": "record-surface-lane", "step": "merge", "item": lane, "file": file})
    };
    let merge =
        |lane: &str, name: &str, mapping: &str| store.fleet_op_ok(&request(lane, name, mapping));
    let refused = |lane: &str, name: &str, mapping: &str| {
        store.fleet_op_refused(&request(lane, name, mapping)).0
    };
    let bound = r#"{"repo":"o/r","item":"KEN-1","parent_repo":"o/r","parent_item":"KEN-0"}"#;
    let lane = |item: &str| {
        store.doc(&store.fleet_path())["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .cloned()
            .unwrap()
    };

    // The pointer verb is the same merge.
    let file = store.write_file(
        "wake.json",
        r#"{"status":"stopped","session_id":"s-1","obligation":null}"#,
    );
    let merged = store.ok(&["state", "merge", "--fleet", "--lane", "KEN-1", &file]);
    assert_eq!(merged["pointer"], "/lanes/0");
    let one = lane("KEN-1");
    assert_eq!(
        (&one["status"], &one["session_id"], &one["obligation"]),
        (&json!("stopped"), &json!("s-1"), &Value::Null)
    );
    assert_eq!(
        one["launched_at"], "2026-10-24T19:00:00Z",
        "an unnamed field stands"
    );

    merge(
        "KEN-1",
        "bind.json",
        &format!(r#"{{"obligation":{bound}}}"#),
    );
    let known: Value = serde_json::from_str(bound).unwrap();
    assert_eq!(
        lane("KEN-1")["obligation"],
        known,
        "an unknown lineage binds"
    );

    let other = r#"{"repo":"o/r","item":"KEN-1","parent_repo":null,"parent_item":null}"#;
    let before = store.doc(&store.fleet_path());
    let key = refused(
        "KEN-1",
        "conflict.json",
        &format!(r#"{{"status":"running","obligation":{other}}}"#),
    );
    assert_eq!(key, "obligation-conflict");
    assert_eq!(
        store.doc(&store.fleet_path()),
        before,
        "a conflict writes nothing"
    );
    let file = store.write_file("conflict.json", &format!(r#"{{"obligation":{other}}}"#));
    let (key, _) = store.refused(&["state", "merge", "--fleet", "--lane", "KEN-1", &file]);
    assert_eq!(
        key, "obligation-conflict",
        "the pointer verb binds once too"
    );

    merge(
        "KEN-2",
        "keep.json",
        r#"{"model":"gpt-6","obligation":null}"#,
    );
    let two = lane("KEN-2");
    assert_eq!(two["model"], "gpt-6");
    assert_eq!(
        two["obligation"],
        json!({"repo": "o/r", "item": "KEN-2", "parent_repo": null, "parent_item": null}),
        "a null obligation keeps the known binding"
    );

    let key = refused(
        "KEN-3",
        "half.json",
        r#"{"obligation":{"repo":"o/r","item":"KEN-3","parent_repo":"o/r"}}"#,
    );
    assert_eq!(key, "obligation-invalid");
    assert_eq!(lane("KEN-3")["obligation"], Value::Null);
    assert_eq!(
        refused("KEN-3", "item.json", r#"{"item":"KEN-2"}"#),
        "merge-item"
    );
    assert_eq!(
        refused("KEN-9", "missing.json", r#"{"status":"done"}"#),
        "lane-missing"
    );
    assert_eq!(
        store.doc(&store.fleet_path())["lanes"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
}

/// A bucket write moves a finding: out of every `--drop` array by its
/// location and description, into `--into` with its named fields, an
/// empty field left out.
#[test]
fn bucket_moves_a_finding_out_of_each_drop_array_with_its_named_fields() {
    let store = Store::new();
    store.init(ITEM);
    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/findings/open",
        r#"[{"location":"a.rs:1","description":"d","x":1},{"location":"b.rs:2","description":"e"}]"#,
    ]);
    let file = store.write_file(
        "finding.json",
        r#"{"findings":[{"location":"a.rs:1","description":"d","severity":"high"}]}"#,
    );
    let moved = store.ok(&[
        "state",
        "bucket",
        "--item",
        ITEM,
        "--into",
        "/findings/fixed",
        "--drop",
        "/findings/open",
        "--drop",
        "/findings/deferred",
        "--element",
        "/findings/0",
        "--field",
        "round=r1",
        "--field",
        "note=",
        &file,
    ]);
    assert_eq!(moved["dropped"], 1);
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        doc["findings"]["fixed"],
        json!([{"description": "d", "location": "a.rs:1", "round": "r1"}])
    );
    assert_eq!(
        doc["findings"]["open"],
        json!([{"location": "b.rs:2", "description": "e"}])
    );
    assert_eq!(doc["findings"]["deferred"], json!([]));
    let (key, _) = store.refused(&[
        "state",
        "bucket",
        "--item",
        ITEM,
        "--into",
        "/findings/fixed",
        "--element",
        "/findings/9",
        &file,
    ]);
    assert_eq!(key, "bucket-element");
    let (key, _) = store.refused(&[
        "state",
        "bucket",
        "--item",
        ITEM,
        "--into",
        "/findings/fixed",
        "--field",
        "=v",
        &file,
    ]);
    assert_eq!(key, "bucket-field");
    let whole = store.write_file("whole.json", r#"{"location":"c","description":"f"}"#);
    store.ok(&[
        "state",
        "bucket",
        "--item",
        ITEM,
        "--into",
        "/findings/fixed",
        &whole,
    ]);
    assert_eq!(
        store.doc(&store.item_path(ITEM))["findings"]["fixed"][1],
        json!({"location": "c", "description": "f"})
    );
}

/// `close-all` marks every member of the map closed, a null member among
/// them, and makes an absent map empty.
#[test]
fn close_all_closes_every_member_of_the_map() {
    let store = Store::new();
    store.init(ITEM);
    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/members",
        r#"{"a":{"status":"open","pid":1},"b":null}"#,
    ]);
    let closed = store.ok(&["state", "close-all", "--item", ITEM, "/members"]);
    assert_eq!(closed["closed"], 2);
    assert_eq!(
        store.doc(&store.item_path(ITEM))["members"],
        json!({"a": {"status": "closed", "pid": 1}, "b": {"status": "closed"}})
    );
    assert_eq!(
        store.ok(&["state", "close-all", "--item", ITEM, "/none"])["closed"],
        0
    );
    assert_eq!(store.doc(&store.item_path(ITEM))["none"], json!({}));
}

/// The model checks: the item's once-only unavailable slot; a switch
/// acquired until its recovery starts, then a duplicate, the start marking
/// only a standing switched check of its own session; a lane or a
/// controller that moved is stale; a fleet check logs one row however often
/// it is acquired before its recovery starts; a
/// replacement's first turn end resets the lane's check to `passed` once.
#[test]
fn a_model_check_is_acquired_once_its_recovery_starts_and_a_moved_launch_is_stale() {
    let store = Store::new();
    store.init(ITEM);
    let slot = |session: &str| {
        store.ok(&[
            "state",
            "model-check",
            "slot",
            "--item",
            ITEM,
            "--session",
            session,
            "--cause",
            "c",
            "--observed",
            "o",
        ])["recorded"]
            .clone()
    };
    assert_eq!(slot("s2"), true);
    assert_eq!(slot("s2"), false);
    let lane = json!({"item": ITEM, "session_id": "s1", "model": "m", "launch": {"pane": "%1"}, "launched_at": 1});
    let expected = store.write_file("lane.json", &lane.to_string());
    let record = |place: &[&str], outcome: &str, expected: &str| {
        let mut args = vec!["state", "model-check", "record"];
        args.extend_from_slice(place);
        args.extend_from_slice(&[
            "--session",
            "s1",
            "--outcome",
            outcome,
            "--launched",
            "L",
            "--observed",
            "O",
            "--expected",
            expected,
        ]);
        store.ok(&args)["result"].clone()
    };
    let item = ["--item", ITEM];
    assert_eq!(record(&item, "switched", &expected), "acquired");
    let check = &store.doc(&store.item_path(ITEM))["model_checks"]["s1"];
    assert_eq!(check["recovery_started"], false);
    assert_eq!(
        check["launch_identity"],
        json!({"launch": {"pane": "%1"}, "launched_at": 1})
    );
    assert_eq!(record(&item, "switched", &expected), "acquired");
    let start = |place: &[&str], session: &str| {
        let mut args = vec!["state", "model-check", "start"];
        args.extend_from_slice(place);
        args.extend_from_slice(&["--session", session]);
        store.ok(&args)
    };
    assert_eq!(
        start(&item, "s1"),
        json!({"place": "item", "session": "s1", "started_now": true})
    );
    assert_eq!(
        start(&item, "s1")["started_now"],
        false,
        "a repeat spends nothing"
    );
    assert_eq!(record(&item, "switched", &expected), "duplicate");
    assert_eq!(record(&item, "unavailable", &expected), "duplicate");
    assert_eq!(slot("s1"), false);
    // The unavailable check of s2 is no switch to recover.
    let out = store.run(&[
        "state",
        "model-check",
        "start",
        "--item",
        ITEM,
        "--session",
        "s2",
    ]);
    assert_eq!(out.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        stderr.lines().next(),
        Some("orch-runtime: model-check-missing session=s2")
    );
    assert_eq!(reply(&out)["ok"], false);
    // Another launch of the same session is its own switch.
    let relaunched = store.write_file(
        "relaunched.json",
        &json!({"item": ITEM, "session_id": "s1", "model": "m", "launch": {"pane": "%1"}, "launched_at": 2})
            .to_string(),
    );
    assert_eq!(record(&item, "switched", &relaunched), "acquired");
    start(&item, "s1");
    assert_eq!(record(&item, "switched", &relaunched), "duplicate");
    // A pointer write lands only a mark a model check would.
    let (key, _) = store.refused(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/model_checks/s9/recovery_started",
        "true",
    ]);
    assert_eq!(key, "field-owned");
    let (key, _) = store.refused(&[
        "state",
        "model-check",
        "record",
        "--item",
        ITEM,
        "--session",
        "s1",
        "--outcome",
        "passed",
        "--expected",
        &expected,
    ]);
    assert_eq!(key, "model-outcome");

    store.init_fleet();
    store.ok(&[
        "state",
        "set",
        "--fleet",
        "/lanes",
        &json!([lane]).to_string(),
    ]);
    let lane_place = ["--fleet", "--lane", ITEM];
    assert_eq!(record(&lane_place, "switched", &expected), "acquired");
    let fleet = store.doc(&store.fleet_path());
    let row = fleet["fleet_log"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()
        .clone();
    assert_eq!(row["kind"], "model-switched");
    assert_eq!(row["item"], ITEM);
    assert_eq!(row["text"], "launched=L observed=O");
    assert_eq!(fleet["lanes"][0]["model_check"]["outcome"], "switched");
    // Acquired again before its recovery starts, the check keeps its one
    // log row, the row the relaunch's recovery limit counts.
    assert_eq!(record(&lane_place, "switched", &expected), "acquired");
    let switched = store.doc(&store.fleet_path())["fleet_log"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["kind"] == "model-switched")
        .count();
    assert_eq!(switched, 1, "one row per launch");
    for (name, moved) in [
        (
            "session",
            json!({"session_id": "s0", "model": "m", "launch": {"pane": "%1"}, "launched_at": 1}),
        ),
        (
            "model",
            json!({"session_id": "s1", "model": "m2", "launch": {"pane": "%1"}, "launched_at": 1}),
        ),
        (
            "launch",
            json!({"session_id": "s1", "model": "m", "launch": {"pane": "%2"}, "launched_at": 1}),
        ),
        (
            "launched",
            json!({"session_id": "s1", "model": "m", "launch": {"pane": "%1"}, "launched_at": 2}),
        ),
    ] {
        let moved = store.write_file(&format!("moved-{name}.json"), &moved.to_string());
        assert_eq!(record(&lane_place, "switched", &moved), "stale", "{name}");
    }
    // Another session's check standing on the lane is no duplicate of this one.
    let other = "/lanes/0/model_check/session_id";
    let started = "/lanes/0/model_check/recovery_started";
    store.ok(&["state", "set", "--fleet", other, "s9", started, "true"]);
    assert_eq!(record(&lane_place, "switched", &expected), "acquired");
    assert_eq!(
        record(&["--fleet", "--lane", "KEN-1"], "switched", &expected),
        "stale"
    );
    assert_eq!(
        start(&lane_place, "s1"),
        json!({"place": "lane", "session": "s1", "started_now": true})
    );
    assert_eq!(record(&lane_place, "switched", &expected), "duplicate");
    for (place, session) in [
        (&lane_place[..], "s9"),
        (&["--fleet", "--lane", "KEN-1"], "s1"),
    ] {
        let mut args = vec!["state", "model-check", "start"];
        args.extend_from_slice(place);
        args.extend_from_slice(&["--session", session]);
        let (key, _) = store.refused(&args);
        assert_eq!(key, "model-check-missing", "{place:?} {session}");
    }

    let fleet = store.doc(&store.fleet_path());
    let read = store.write_file("read.json", &fleet["lanes"][0].to_string());
    let mut away = fleet["lanes"][0].clone();
    away["launch"] = json!({"pane": "%7"});
    let away = store.write_file("away.json", &away.to_string());
    let reset = |expected: &str| {
        store.ok(&[
            "state",
            "model-check",
            "reset",
            "--fleet",
            "--lane",
            ITEM,
            "--session",
            "s1",
            "--expected",
            expected,
        ])["reset"]
            .clone()
    };
    assert_eq!(reset(&away), false);
    assert_eq!(reset(&read), true);
    let fleet = store.doc(&store.fleet_path());
    assert_eq!(fleet["lanes"][0]["model_check"]["outcome"], "passed");
    let row = fleet["fleet_log"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()
        .clone();
    assert_eq!(row["kind"], "model-recovery-reset");
    assert_eq!(row["text"], "first-turn-complete");
    assert_eq!(reset(&read), false);

    let overseer = json!({"server": "7000", "server_start": 1, "pane": "%9", "generation": 2, "cwd": "/w",
        "session_id": "s1", "model": "m"});
    store.ok(&[
        "state",
        "set",
        "--fleet",
        "/overseer",
        &overseer.to_string(),
    ]);
    let bound = store.write_file("overseer.json", &overseer.to_string());
    assert_eq!(record(&["--fleet"], "switched", &bound), "acquired");
    let row = store.doc(&store.fleet_path())["fleet_log"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()
        .clone();
    assert_eq!(row["item"], "oversee");
    assert_eq!(start(&["--fleet"], "s1")["place"], "overseer");
    assert_eq!(record(&["--fleet"], "switched", &bound), "duplicate");
    let mut next = overseer.clone();
    next["generation"] = json!(3);
    let next = store.write_file("next.json", &next.to_string());
    assert_eq!(record(&["--fleet"], "switched", &next), "stale");
}

/// The heal fills the controller record's server start and each missing
/// harness, home and native session only for the session the record
/// names: a recorded harness, home or session that disagrees, a missing
/// native session, another server start or another pane refuses
/// `overseer-native-unbound` and writes nothing.
#[test]
fn the_heal_fills_only_the_session_the_record_names_and_refuses_any_other() {
    let rows = [
        ("", "", "", "/claude", "s1", true),
        ("claude", "/claude", "s1", "/claude", "s1", true),
        ("copilot", "/claude", "s1", "/claude", "s1", false),
        ("claude", "/other", "s1", "/claude", "s1", false),
        ("claude", "/claude", "child", "/claude", "s1", false),
        ("", "", "child", "/claude", "s1", false),
        ("claude", "/claude", "s1", "", "s1", true),
        ("", "", "", "/claude", "", false),
    ];
    for (harness, home, session, caller_home, caller_session, heals) in rows {
        let store = Store::new();
        store.init_fleet();
        let record = json!({"server": "7000", "pane": "%9", "harness": harness, "home": home, "session_id": session});
        store.ok(&["state", "set", "--fleet", "/overseer", &record.to_string()]);
        let args = [
            "state",
            "heal",
            "--fleet",
            "--server",
            "7000",
            "--pane",
            "%9",
            "--start",
            "1790000000",
            "--harness",
            "claude",
            "--home",
            caller_home,
            "--session",
            caller_session,
        ];
        let row = format!("{harness}|{home}|{session}|{caller_home}|{caller_session}");
        if heals {
            store.ok(&args);
            let after = &store.doc(&store.fleet_path())["overseer"];
            let home = if home.is_empty() { caller_home } else { home };
            assert_eq!(
                [
                    &after["server_start"],
                    &after["harness"],
                    &after["home"],
                    &after["session_id"]
                ],
                [
                    &json!(1_790_000_000),
                    &json!("claude"),
                    &json!(home),
                    &json!(caller_session)
                ],
                "{row}"
            );
        } else {
            let (key, _) = store.refused(&args);
            assert_eq!(key, "overseer-native-unbound", "{row}");
            assert_eq!(store.doc(&store.fleet_path())["overseer"], record, "{row}");
        }
    }
    let store = Store::new();
    store.init_fleet();
    let heal = |start: &str, pane: &str| {
        store
            .refused(&[
                "state",
                "heal",
                "--fleet",
                "--server",
                "7000",
                "--pane",
                pane,
                "--start",
                start,
                "--session",
                "s1",
            ])
            .0
    };
    assert_eq!(heal("1790000000", "%9"), "overseer-native-unbound");
    store.ok(&[
        "state",
        "set",
        "--fleet",
        "/overseer",
        r#"{"server":"7000","pane":"%9","server_start":1}"#,
    ]);
    assert_eq!(heal("1790000000", "%9"), "overseer-native-unbound");
    assert_eq!(heal("1", "%8"), "overseer-native-unbound");
    store.ok(&[
        "state",
        "set",
        "--fleet",
        "/overseer",
        r#"{"server":"7000","pane":"%9"}"#,
    ]);
    assert_eq!(heal("soon", "%9"), "server-start-invalid");
}

/// The `marks` verb's lane form judges a reading alone: the plain answer
/// and, with an agent reserve, the reserve's beside it, each with the
/// decision record a handoff carries. A reading with no window below the
/// cap is unmeasured; a reserve is a whole count with no leading zero, and
/// one past every mark leaves no room.
#[test]
fn the_lane_marks_judge_a_reading_alone_with_the_reserve_beside_the_plain_answer() {
    let store = Store::new();
    let marks = |args: &[&str], env: &[(&str, &str)]| {
        let mut all = vec!["marks", "--item", "judged"];
        all.extend_from_slice(args);
        store.ok_env(&all, env)
    };
    let judged = marks(
        &["--context", "500000:1000000", "--agent-reserve", "150000"],
        &[],
    );
    assert_eq!(judged["context"], "room");
    assert_eq!(judged["mark"], 90);
    assert_eq!(judged["reserve"]["context"], "due");
    assert_eq!(
        judged["reserve"]["context_decision"],
        json!({"tokens": 500000, "window": 1000000, "cap": 650000, "mark_pct": 90, "cap_mark": 500000,
            "window_mark": 750000, "reserve_applied": true, "reserve_tokens": 150000})
    );
    assert_eq!(
        judged["context_decision"],
        json!({"tokens": 500000, "window": 1000000, "cap": 650000, "mark_pct": 90, "cap_mark": 650000,
            "window_mark": 900000, "reserve_applied": false, "reserve_tokens": 0})
    );
    assert!(judged.get("reserve").is_some());
    assert!(marks(&["--context", "1:10"], &[]).get("reserve").is_none());
    assert_eq!(
        marks(
            &["--context", "101:200"],
            &[("ORCH_HANDOFF_CONTEXT_PCT", "50")]
        )["context"],
        "due"
    );
    assert_eq!(
        marks(
            &["--context", "100:200"],
            &[("ORCH_HANDOFF_CONTEXT_PCT", "50")]
        )["context"],
        "room"
    );
    assert_eq!(
        marks(&["--context", "649999:"], &[])["context"],
        "unmeasured"
    );
    assert_eq!(marks(&["--context", "650000:"], &[])["context"], "due");
    let beyond = marks(
        &[
            "--context",
            "0:",
            "--agent-reserve",
            "999999999999999999999",
        ],
        &[],
    );
    assert_eq!(beyond["reserve"]["context"], "due");
    let (key, _) = store.refused(&["marks", "--item", "judged", "--context", "x:10"]);
    assert_eq!(key, "context-invalid");
    let (key, _) = store.refused(&["marks", "--item", "judged"]);
    assert_eq!(key, "context-unnamed");
    for args in [
        &[
            "marks",
            "--item",
            "judged",
            "--context",
            "1:10",
            "--agent-reserve",
            "015",
        ][..],
        &[
            "marks",
            "--item",
            "judged",
            "--context",
            "1:10",
            "--agent-reserve",
            "-1",
        ][..],
    ] {
        let out = store.run(args);
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(
            String::from_utf8_lossy(&out.stderr).starts_with("orch-runtime: usage"),
            "{args:?}"
        );
    }
    let (key, _) = store.refused(&[
        "marks",
        "--fleet",
        "--context",
        "1:10",
        "--agent-reserve",
        "1",
    ]);
    assert_eq!(key, "reserve-unpaired");
}

/// A git checkout under the store's root with one commit, and its HEAD.
fn checkout(store: &Store) -> (String, impl Fn(&[&str]) -> String + '_) {
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
    (store.dir.path().join("repo").display().to_string(), git)
}

/// A CI round mints its own token beside the dev round's and opens no stage:
/// its cleanup entries key on it and its fix runs as the dev round's work.
#[test]
fn a_ci_round_mints_its_own_token_and_opens_no_stage() {
    let store = Store::new();
    store.init(ITEM);
    let dev = store.op_ok(&json!({"op": "begin-round", "kind": "dev"}));
    let stages = store.doc(&store.item_path(ITEM))["stages"].clone();
    let ci = store.op_ok(&json!({"op": "begin-round", "kind": "ci"}));
    let doc = store.doc(&store.item_path(ITEM));
    let token = &ci["report"]["round_id"];
    assert!(token.is_string(), "{ci}");
    assert_ne!(token, &dev["report"]["round_id"]);
    assert_eq!(&doc["ci_round_id"], token);
    assert_eq!(
        doc["dev_round_id"], dev["report"]["round_id"],
        "the dev round stands"
    );
    assert_eq!(doc["stages"], stages, "no stage opened or superseded");
    assert_eq!(ci["report"]["superseded"], json!([]));
}

/// A round's base is the checkout's HEAD, read before the write, and only a
/// review's fix round marks `review_fix_round`; a checkout that cannot be
/// read writes nothing.
#[test]
fn a_round_base_records_the_checkouts_head_and_only_a_fix_round_marks_it() {
    let store = Store::new();
    store.init(ITEM);
    let (repo, git) = checkout(&store);
    let base = |worktree: &str, review_fix: bool| json!({"op": "record-round", "step": "base", "worktree": worktree, "review_fix": review_fix});
    store.op_ok(&base(&repo, false));
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        doc["pre_delegate_sha"],
        git(&["-C", "repo", "rev-parse", "HEAD"])
    );
    assert!(doc.get("review_fix_round").is_none(), "{doc}");
    git(&["-C", "repo", "commit", "-q", "--allow-empty", "-m", "fix"]);
    store.op_ok(&base(&repo, true));
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        doc["pre_delegate_sha"],
        git(&["-C", "repo", "rev-parse", "HEAD"])
    );
    assert_eq!(doc["review_fix_round"], true);
    let missing = store.dir.path().join("no-repo").display().to_string();
    store.op_refused(&base(&missing, false));
}

/// The delegation time is stamped only on a minted round: a dev or CI
/// round's on `dev_delegated_at`, a review round's on `review_delegated_at`.
/// A round never minted refuses with the record unchanged.
#[test]
fn a_delegation_stamp_refuses_a_round_never_minted() {
    let store = Store::new();
    store.init(ITEM);
    let stamp = |round: &str| json!({"op": "record-round", "step": "delegated", "round": round});
    for round in ["dev", "review", "ci"] {
        let (key, line) = store.op_refused(&stamp(round));
        assert_eq!(key, "round-unminted", "{round}");
        assert!(line.ends_with(&format!("round={round}")), "{line}");
    }
    store.op_ok(&json!({"op": "begin-round", "kind": "ci"}));
    let before = now_secs();
    store.op_ok(&stamp("ci"));
    let doc = store.doc(&store.item_path(ITEM));
    let at = doc["dev_delegated_at"].as_u64().unwrap();
    assert!((before..=now_secs()).contains(&at), "{at}");
    assert!(doc.get("review_delegated_at").is_none(), "{doc}");
    store.op_ok(&json!({"op": "begin-round", "kind": "review"}));
    store.op_ok(&stamp("review"));
    let at = store.doc(&store.item_path(ITEM))["review_delegated_at"]
        .as_u64()
        .unwrap();
    assert!((before..=now_secs()).contains(&at), "{at}");
}

/// A fix round counts on `cycles` and a comment triage pass on its own
/// iterations, each from the count it finds, with the ledger beside it kept.
#[test]
fn a_counted_round_adds_one_to_its_own_counter() {
    let store = Store::new();
    store.init(ITEM);
    let count =
        |counter: &str| json!({"op": "record-round", "step": "counted", "counter": counter});
    store.op_ok(&count("fix"));
    store.op_ok(&count("fix"));
    assert_eq!(store.op_ok(&count("external"))["value"], 1);
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["cycles"], 2);
    assert_eq!(doc["pr_comment_review"]["iterations"], 1);
    assert_eq!(
        doc["pr_comment_review"]["fixes"],
        json!([]),
        "the ledger stands"
    );
}

/// The reviewer set names each id and runtime type by one of its agents,
/// each agent once; a return records its artifact and the agent's wave
/// return once however often it is replayed; the dev round's sessions open
/// `active` under their agent type and close together.
#[test]
fn the_reviewer_set_lists_only_its_agents_and_a_return_lands_once() {
    let store = Store::new();
    store.init(ITEM);
    let step = |fields: Value| -> Value {
        let mut request = json!({"op": "record-agents"});
        for (key, value) in fields.as_object().unwrap() {
            request[key] = value.clone();
        }
        request
    };
    store.op_ok(&step(json!({"step": "wave-start", "slots_observed": 3})));
    let active = |agents: Value, ids: Value| {
        step(
            json!({"step": "active", "agents": agents, "ids": ids, "runtime_types": {"rev-a": "claude"}}),
        )
    };
    store.op_ok(&active(json!(["rev-a", "rev-b"]), json!({"rev-a": "t1"})));
    let (key, line) = store.op_refused(&active(json!(["rev-a"]), json!({"rev-c": "t3"})));
    assert_eq!(key, "reviewer-unlisted");
    assert!(line.ends_with("agent=rev-c"), "{line}");
    let (key, _) = store.op_refused(&active(json!(["rev-a", "rev-a"]), json!({})));
    assert_eq!(key, "reviewer-duplicate");
    let returned = step(json!({"step": "returned", "artifact": "tmp/a.json", "agent": "rev-a"}));
    store.op_ok(&returned);
    let again = store.op_ok(&returned);
    assert_eq!(again["artifact_recorded"], false);
    assert_eq!(again["agent_recorded"], false);
    store.op_ok(&step(json!({"step": "returned", "artifact": "tmp/b.json"})));
    let (key, _) = store.op_refused(&step(json!({"step": "returned"})));
    assert_eq!(key, "agents-field");
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["reviewer_slots_observed"], 3);
    assert_eq!(doc["review_agents"], json!(["rev-a", "rev-b"]));
    assert_eq!(doc["review_agent_ids"], json!({"rev-a": "t1"}));
    assert_eq!(doc["json_paths"], json!(["tmp/a.json", "tmp/b.json"]));
    assert_eq!(doc["review_wave_done"], json!(["rev-a"]));
    store.op_ok(&step(json!({"step": "cleared"})));
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["review_agents"], json!([]));
    assert_eq!(doc["review_agent_ids"], json!({}));
    assert_eq!(doc["review_wave_done"], json!([]));
    assert_eq!(
        doc["review_agent_runtime_types"],
        json!({"rev-a": "claude"})
    );

    store.op_ok(&step(json!({
        "step": "child-open",
        "agent_type": "backend",
        "agent_id": "a1",
        "runtime_agent_type": "dev-backend",
        "agent_type_fallback": null
    })));
    assert_eq!(
        store.doc(&store.item_path(ITEM))["child_sessions"]["backend"],
        json!({"status": "active", "agent_id": "a1", "runtime_agent_type": "dev-backend", "agent_type_fallback": null})
    );
    store.op_ok(&step(json!({"step": "children-closed"})));
    assert_eq!(
        store.doc(&store.item_path(ITEM))["child_sessions"]["backend"]["status"],
        "closed"
    );
}

/// A disposition moves one finding out of the arrays it leaves and into the
/// one it lands in, read from its file or from an artifact's element with
/// the named fields beside it, an empty field left out; an entry naming no
/// location refuses with the record unchanged.
#[test]
fn a_disposition_moves_a_finding_and_refuses_one_without_its_location() {
    let store = Store::new();
    store.init(ITEM);
    let fixed = store.write_file(
        "fixed.json",
        r#"{"description":"d","location":"a.rs:1","commit":"abc1234","source":"review"}"#,
    );
    let into_fixed = json!({"op": "record-disposition", "into": "fixed", "drop": ["fixed", "escalated"], "file": fixed});
    store.op_ok(&into_fixed);
    assert_eq!(
        store.op_ok(&into_fixed)["dropped"],
        1,
        "a replay replaces the entry"
    );
    assert_eq!(
        store.doc(&store.item_path(ITEM))["fixed_items"],
        json!([{"description": "d", "location": "a.rs:1", "commit": "abc1234", "source": "review"}])
    );
    let artifact = store.write_file(
        "artifact.json",
        r#"{"blockers":[{"description":"d","location":"a.rs:1","severity":"high"}]}"#,
    );
    store.op_ok(&json!({
        "op": "record-disposition",
        "into": "escalated",
        "drop": ["fixed"],
        "file": artifact,
        "element": "/blockers/0",
        "fields": {"reason": "outstanding", "outcome": "blocked", "kind": ""}
    }));
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["fixed_items"], json!([]));
    assert_eq!(
        doc["escalated_items"],
        json!([{"description": "d", "location": "a.rs:1", "reason": "outstanding", "outcome": "blocked"}])
    );
    let unlocated = store.write_file("unlocated.json", r#"{"description":"Fix"}"#);
    let (key, _) =
        store.op_refused(&json!({"op": "record-disposition", "into": "fixed", "file": unlocated}));
    assert_eq!(key, "disposition-entry");
}

/// Each ledger entry lands in its own array in the shape its readers take:
/// a cause or a finding read from its file, a proposed rule once, a reply's
/// outcome one of four, an issue under the triage or the audit that filed
/// it, the baseline replaced whole. An entry outside its shape refuses with
/// the record unchanged.
#[test]
fn each_ledger_entry_lands_in_its_own_array_in_its_readers_shape() {
    let store = Store::new();
    store.init(ITEM);
    let ledger = |fields: Value| -> Value {
        let mut request = json!({"op": "record-comment-ledger"});
        for (key, value) in fields.as_object().unwrap() {
            request[key] = value.clone();
        }
        request
    };
    let get = |pointer: &str| store.ok(&["state", "get", "--item", ITEM, pointer])["value"].take();
    let rows: [(&str, &str, &str); 5] = [
        (
            "frozen-cause",
            r#"{"cause":"c","issue":"KEN-1"}"#,
            "/pr_comment_review/frozen_causes",
        ),
        (
            "patched-cause",
            r#"{"cause":"c","commit":"abc1234","location":"a.rs:1"}"#,
            "/pr_comment_review/patched_causes",
        ),
        (
            "proposed-rule",
            r#""a rule""#,
            "/pr_comment_review/proposed_rules",
        ),
        (
            "fix",
            r#"{"description":"d","location":"a.rs:1","commit":"abc1234","source":"copilot"}"#,
            "/pr_comment_review/fixes",
        ),
        (
            "skip",
            r#"{"description":"d","reason":"r"}"#,
            "/pr_comment_review/skipped",
        ),
    ];
    for (entry, text, pointer) in rows {
        let file = store.write_file(&format!("{entry}.json"), text);
        store.op_ok(&ledger(json!({"entry": entry, "file": file})));
        let want: Value = serde_json::from_str(text).unwrap();
        assert_eq!(get(pointer), json!([want]), "{entry}");
    }
    let rule = store.write_file("proposed-rule.json", r#""a rule""#);
    let again = store.op_ok(&ledger(json!({"entry": "proposed-rule", "file": rule})));
    assert_eq!(again["appended"], false, "a held rule is not appended");
    store.op_ok(&ledger(json!({"entry": "reply", "source_id": "PRRT_1", "commit": "abc1234", "outcome": "already_fixed"})));
    assert_eq!(
        get("/pr_comment_review/replied"),
        json!([{"source_id": "PRRT_1", "commit": "abc1234", "outcome": "already_fixed"}])
    );
    store.op_ok(&ledger(
        json!({"entry": "issue", "id": "KEN-2", "origin": "triage"}),
    ));
    store.op_ok(&ledger(
        json!({"entry": "issue", "id": "KEN-3", "origin": "audit"}),
    ));
    assert_eq!(get("/pr_comment_review/issues_created"), json!(["KEN-2"]));
    assert_eq!(get("/audit_issues_created"), json!(["KEN-3"]));
    store.op_ok(&ledger(
        json!({"entry": "baseline", "last_threads": ["PRRT_1"]}),
    ));
    assert_eq!(
        get("/pr_review_baseline"),
        json!({"last_threads": ["PRRT_1"]})
    );
    assert_eq!(get("/pr_comment_review/iterations"), 0, "the count stands");

    let stray = store.write_file(
        "stray.json",
        r#"{"cause":"c","commit":"abc1234","location":"a.rs:1","x":1}"#,
    );
    let (key, line) = store.op_refused(&ledger(json!({"entry": "patched-cause", "file": stray})));
    assert_eq!(key, "ledger-entry");
    assert!(line.contains("entry=patched-cause"), "{line}");
    let unfiled = store.write_file("unfiled.json", r#"{"cause":"c"}"#);
    let (key, _) = store.op_refused(&ledger(json!({"entry": "frozen-cause", "file": unfiled})));
    assert_eq!(key, "ledger-entry");
    let (key, _) = store.op_refused(&ledger(
        json!({"entry": "reply", "source_id": "PRRT_2", "commit": "abc1234", "outcome": "merged"}),
    ));
    assert_eq!(key, "request-invalid");
}

/// `request` with the fields of `fields` beside its `op`.
fn with_op(op: &str, fields: Value) -> Value {
    let mut request = json!({"op": op});
    for (key, value) in fields.as_object().unwrap() {
        request[key] = value.clone();
    }
    request
}

/// A route names the checkout by its absolute path, a branch and the tier
/// and floor words `item-tier` assigns, each replacing the record's; a
/// request naming none, or any field outside its shape, writes nothing.
#[test]
fn a_route_records_its_checkout_and_tier_and_refuses_a_word_outside_the_tiers() {
    let store = Store::new();
    store.init(ITEM);
    let route = |fields: Value| with_op("record-route", fields);
    store.op_ok(&route(
        json!({"worktree": "/w/ken-4687", "branch": "ken-4687", "tier": "standard"}),
    ));
    store.op_ok(&route(json!({"tier": "small", "review_floor": "small"})));
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        (
            &doc["worktree"],
            &doc["branch"],
            &doc["tier"],
            &doc["review_floor"]
        ),
        (
            &json!("/w/ken-4687"),
            &json!("ken-4687"),
            &json!("small"),
            &json!("small")
        )
    );
    let rows = [
        (json!({}), "route-empty"),
        (json!({"worktree": "w/ken-4687"}), "worktree-invalid"),
        (json!({"branch": "  "}), "branch-invalid"),
        (json!({"tier": "Small"}), "tier-value"),
        (json!({"review_floor": "large"}), "review-floor-value"),
        (
            json!({"tier": "micro", "worktree": "relative"}),
            "worktree-invalid",
        ),
        (json!({"tier": "micro", "reviewers": 2}), "request-invalid"),
    ];
    for (fields, want) in rows {
        let (key, _) = store.op_refused(&route(fields.clone()));
        assert_eq!(key, want, "{fields}");
    }
}

/// A dev return replaces each list it names and keeps the ones it leaves
/// out, so a probe that did not answer keeps the standing near-ceiling
/// lines; an empty line or a request naming no list writes nothing.
#[test]
fn a_dev_return_replaces_its_lists_and_refuses_an_empty_line() {
    let store = Store::new();
    store.init(ITEM);
    let ret = |fields: Value| with_op("record-dev-return", fields);
    let near = json!(["byte-ceiling: near-ceiling=assets/a.bin:189000:204800:92"]);
    store.op_ok(&ret(json!({"near_ceiling": near})));
    store.op_ok(&ret(
        json!({"qa_labels": ["qa-ui"], "sub_issues": ["KEN-1"]}),
    ));
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        (&doc["near_ceiling"], &doc["qa_labels"], &doc["sub_issues"]),
        (&near, &json!(["qa-ui"]), &json!(["KEN-1"]))
    );
    store.op_ok(&ret(json!({"near_ceiling": []})));
    assert_eq!(store.doc(&store.item_path(ITEM))["near_ceiling"], json!([]));
    let rows = [
        (json!({}), "dev-return-empty"),
        (json!({"near_ceiling": null}), "dev-return-empty"),
        (
            json!({"near_ceiling": ["x"], "qa_labels": [""]}),
            "dev-return-field",
        ),
        (json!({"sub_issues": "KEN-1"}), "request-invalid"),
    ];
    for (fields, want) in rows {
        let (key, line) = store.op_refused(&ret(fields.clone()));
        assert_eq!(key, want, "{fields}");
        if want == "dev-return-field" {
            assert!(line.ends_with("field=qa_labels"), "{line}");
        }
    }
}

/// A pull request's progress: its order one of the seven words, the
/// approval flags and the detach set once, one rerun per head stamped by
/// the runtime with the run recorded only against that head, and a
/// restack's skip replacing the one of its head.
#[test]
fn pr_progress_holds_its_order_words_and_a_rerun_run_names_its_head() {
    let store = Store::new();
    store.init(ITEM);
    let step = |fields: Value| with_op("record-pr-progress", fields);
    store.op_ok(&step(json!({"step": "order", "order": "open-first"})));
    store.op_ok(&step(
        json!({"step": "order", "order": "open-first-returned"}),
    ));
    for flag in ["forced", "reviewer-down", "children-detached"] {
        store.op_ok(&step(json!({ "step": flag })));
    }
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(doc["pr_order"], "open-first-returned");
    assert_eq!(
        doc["pr_approval"],
        json!({"forced": true, "reviewer_down": true})
    );
    assert_eq!(doc["children_detached"], true);

    let head = "a".repeat(40);
    let other = "b".repeat(40);
    let (key, line) = store.op_refused(&step(
        json!({"step": "ci-rerun-run", "head": head, "run": 7}),
    ));
    assert_eq!(key, "ci-rerun-head");
    assert!(line.ends_with("recorded=none"), "{line}");
    let before = now_secs();
    store.op_ok(&step(json!({"step": "ci-rerun", "head": head})));
    let rerun = store.doc(&store.item_path(ITEM))["ci_rerun"].clone();
    assert_eq!(
        (&rerun["head"], &rerun["run"]),
        (&json!(head), &Value::Null)
    );
    let at = agent_runtime::clock::epoch_secs(rerun["at"].as_str().unwrap()).unwrap();
    assert!((before..=now_secs()).contains(&at), "{rerun}");
    let (key, _) = store.op_refused(&step(
        json!({"step": "ci-rerun-run", "head": other, "run": 7}),
    ));
    assert_eq!(key, "ci-rerun-head");
    store.op_ok(&step(
        json!({"step": "ci-rerun-run", "head": head, "run": 7}),
    ));
    let ran = store.doc(&store.item_path(ITEM))["ci_rerun"].clone();
    assert_eq!(ran, json!({"head": head, "run": 7, "at": rerun["at"]}));
    let (key, _) = store.op_refused(&step(json!({"step": "ci-rerun", "head": "[HEAD]"})));
    assert_eq!(key, "head-invalid");

    let skip = |name: &str, head: &str, condition: &str, paths: Value| {
        let file = store.write_file(
            name,
            &json!({"head": head, "condition": condition, "validated_head": other, "paths": paths})
                .to_string(),
        );
        step(json!({"step": "restack-skip", "file": file}))
    };
    store.op_ok(&skip("s1.json", &head, "no-conflict", json!([])));
    let replaced = store.op_ok(&skip(
        "s2.json",
        &head,
        "version-only",
        json!(["CHANGELOG.md"]),
    ));
    assert_eq!(replaced["replaced"], 1);
    store.op_ok(&skip("s3.json", &other, "no-conflict", json!([])));
    let skips = store.doc(&store.item_path(ITEM))["restack_skips"].clone();
    assert_eq!(
        (
            skips.as_array().unwrap().len(),
            &skips[0]["condition"],
            &skips[1]["head"]
        ),
        (2, &json!("version-only"), &json!(other))
    );
    let rows = [
        (
            step(json!({"step": "order", "order": "open-first-merged"})),
            "pr-order-value",
        ),
        (
            skip("s4.json", &head, "clean", json!([])),
            "restack-skip-field",
        ),
        (
            skip("s5.json", "HEAD", "no-conflict", json!([])),
            "restack-skip-field",
        ),
        (
            step(json!({"step": "forced", "value": false})),
            "request-invalid",
        ),
    ];
    for (request, want) in rows {
        let (key, _) = store.op_refused(&request);
        assert_eq!(key, want, "{request}");
    }
}

/// The surface-2 record `oversee.md` creates after an item's first launch.
const SURFACE_LANE: &str = r#"{"item":"KEN-4500","tracker":"linear","repo":null,"harness":"codex","window":null,"account":null,"host":null,"mail_root":"/w/ken-4500","surface":"gui","model":"gpt-5.5-codex","session_id":null,"launched_at":"2026-10-24T19:00:00Z","status":"running","obligation":null}"#;

/// A surface lane is created whole, once per item, and a tmux lane is the
/// lane operations' own: neither step creates, merges into or turns a
/// record into one.
#[test]
fn a_surface_lane_is_created_whole_and_a_tmux_lane_is_refused() {
    let store = Store::new();
    store.init_fleet();
    let lane: Value = serde_json::from_str(SURFACE_LANE).unwrap();
    let create =
        |lane: &Value| json!({"op": "record-surface-lane", "step": "create", "lane": lane});
    let created = store.fleet_op_ok(&create(&lane));
    assert_eq!(created["pointer"], "/lanes/0");
    assert_eq!(store.doc(&store.fleet_path())["lanes"], json!([lane]));
    let variant = |key: &str, value: Value| {
        let mut other = lane.clone();
        other["item"] = json!("KEN-4501");
        match value {
            Value::Null if key == "surface" => {
                other.as_object_mut().unwrap().remove(key);
            }
            value => other[key] = value,
        }
        other
    };
    let rows = [
        (lane.clone(), "lane-standing"),
        (variant("surface", json!("tmux")), "surface-lane"),
        (variant("surface", Value::Null), "surface-lane"),
        (variant("status", json!("lost")), "lane-invalid"),
        (
            variant("obligation", json!({"repo": "o/r"})),
            "obligation-invalid",
        ),
    ];
    for (lane, want) in rows {
        let (key, _) = store.fleet_op_refused(&create(&lane));
        assert_eq!(key, want, "{lane}");
    }

    let tmux = json!({"item": "KEN-4502", "surface": "tmux", "status": "running"});
    store.ok(&["state", "append", "--fleet", "/lanes", &tmux.to_string()]);
    let merge = |item: &str, mapping: &str| {
        let file = store.write_file("merge.json", mapping);
        json!({"op": "record-surface-lane", "step": "merge", "item": item, "file": file})
    };
    for (item, mapping) in [
        ("KEN-4502", r#"{"status":"stopped"}"#),
        ("KEN-4500", r#"{"surface":"tmux"}"#),
    ] {
        let (key, _) = store.fleet_op_refused(&merge(item, mapping));
        assert_eq!(key, "surface-lane", "{item} {mapping}");
    }
    store.fleet_op_ok(&merge("KEN-4500", r#"{"status":"stopped"}"#));
    assert_eq!(
        store.doc(&store.fleet_path())["lanes"][0]["status"],
        "stopped"
    );
    store.init(ITEM);
    let (key, _) = store.op_refused(&create(&lane));
    assert_eq!(key, "op-kind", "a lane is the fleet record's");
}

/// The overseer's ledger: the backlog audit stamped with the runtime's
/// clock, the launch queue unique, and an alert verdict the watch can key,
/// naming its item exactly when filed; anything else writes nothing.
#[test]
fn the_overseers_ledger_stamps_its_audit_and_holds_each_entry_to_its_readers_shape() {
    let store = Store::new();
    store.init_fleet();
    let entry = |fields: Value| with_op("record-overseer-ledger", fields);
    let before = now_secs();
    store.fleet_op_ok(&entry(json!({"entry": "backlog-audit", "backlog": 120})));
    let audit = store.doc(&store.fleet_path())["last_backlog_audit"].clone();
    assert_eq!(audit["backlog"], 120);
    let at = agent_runtime::clock::epoch_secs(audit["at"].as_str().unwrap()).unwrap();
    assert!((before..=now_secs()).contains(&at), "{audit}");
    store.fleet_op_ok(&entry(
        json!({"entry": "launch-queue", "items": ["KEN-1", "KEN-2"]}),
    ));
    assert_eq!(
        store.doc(&store.fleet_path())["launch_queue"],
        json!(["KEN-1", "KEN-2"])
    );
    let verdict = |name: &str, row: Value| {
        let file = store.write_file(name, &row.to_string());
        entry(json!({"entry": "alert-verdict", "file": file}))
    };
    let filed = json!({"repo": "o/r", "kind": "dependabot", "number": 7, "verdict": "filed", "item": "KEN-9", "reason": "a fix item"});
    let dismissed = json!({"repo": "o/r", "kind": "secret-scanning", "number": 8, "verdict": "dismissed", "item": null, "reason": "a test key"});
    store.fleet_op_ok(&verdict("filed.json", filed.clone()));
    store.fleet_op_ok(&verdict("dismissed.json", dismissed.clone()));
    assert_eq!(
        store.doc(&store.fleet_path())["alerts_triaged"],
        json!([filed, dismissed])
    );
    let changed = |key: &str, value: Value| {
        let mut row = filed.clone();
        row[key] = value;
        row
    };
    let rows = [
        (
            entry(json!({"entry": "launch-queue", "items": ["KEN-1", "KEN-1"]})),
            "launch-queue-entry",
        ),
        (
            entry(json!({"entry": "launch-queue", "items": [""]})),
            "launch-queue-entry",
        ),
        (
            verdict("a.json", changed("item", Value::Null)),
            "alert-verdict",
        ),
        (
            verdict("b.json", changed("verdict", json!("dismissed"))),
            "alert-verdict",
        ),
        (
            verdict("c.json", changed("kind", json!("codeql"))),
            "alert-verdict",
        ),
        (
            verdict("d.json", changed("repo", json!("o"))),
            "alert-verdict",
        ),
        (
            verdict("e.json", changed("number", json!("7"))),
            "alert-verdict",
        ),
        (entry(json!({"entry": "backlog-audit"})), "request-invalid"),
    ];
    for (request, want) in rows {
        let (key, _) = store.fleet_op_refused(&request);
        assert_eq!(key, want, "{request}");
    }
}

/// The merge question's hold: the ask opens one `merge-hold` pause stamped
/// by the runtime, an ask again while it stands keeps that one, the answer
/// closes it, and an answer with none standing changes nothing.
#[test]
fn a_merge_hold_opens_at_the_ask_and_closes_at_the_answer() {
    let store = Store::new();
    store.init(ITEM);
    let step = |name: &str| with_op("record-pr-progress", json!({ "step": name }));
    let pauses = || store.doc(&store.item_path(ITEM))["pauses"].clone();
    let before = now_secs();
    let asked = store.op_ok(&step("merge-asked"));
    assert_eq!(asked["opened"], true, "{asked}");
    let opened = pauses();
    let from = agent_runtime::clock::epoch_secs(opened[0]["from"].as_str().unwrap()).unwrap();
    assert!((before..=now_secs()).contains(&from), "{opened}");
    assert_eq!(
        (&opened[0]["to"], &opened[0]["cause"]),
        (&Value::Null, &json!("merge-hold"))
    );
    let again = store.op_ok(&step("merge-asked"));
    assert_eq!(
        (&again["opened"], pauses()),
        (&json!(false), opened.clone())
    );
    let answered = store.op_ok(&step("merge-answered"));
    assert_eq!(answered["closed"], true, "{answered}");
    let closed = pauses();
    assert_eq!(closed.as_array().unwrap().len(), 1, "{closed}");
    let to = agent_runtime::clock::epoch_secs(closed[0]["to"].as_str().unwrap()).unwrap();
    assert!((from..=now_secs()).contains(&to), "{closed}");
    let late = store.op_ok(&step("merge-answered"));
    assert_eq!((&late["closed"], pauses()), (&json!(false), closed));
}

/// A pointer write into a field a progress, budget, stop or ledger record
/// owns lands only a value its owner writes: anything else refuses
/// `field-owned` naming the field and the operation, with nothing written.
#[test]
fn a_pointer_write_into_an_owned_progress_field_is_held_to_its_owners_check() {
    let store = Store::new();
    store.init(ITEM);
    store.init_fleet();
    let skip = store.write_file("skip.json", r#"{"head":"abc"}"#);
    let rows: [(&[&str], &str, &str); 15] = [
        (
            &["set", "--item", ITEM, "/worktree", "w/ken"],
            "worktree",
            "record-route",
        ),
        (
            &["set", "--item", ITEM, "/branch", "007"],
            "branch",
            "record-route",
        ),
        (
            &["set", "--item", ITEM, "/review_floor", "large"],
            "review_floor",
            "record-route",
        ),
        (
            &["set", "--item", ITEM, "/near_ceiling", r#"[""]"#],
            "near_ceiling",
            "record-dev-return",
        ),
        (
            &["set", "--item", ITEM, "/qa_labels", "[1]"],
            "qa_labels",
            "record-dev-return",
        ),
        (
            &["set", "--item", ITEM, "/pr_order", "later"],
            "pr_order",
            "record-pr-progress",
        ),
        (
            &["set", "--item", ITEM, "/pr_approval/forced", "yes"],
            "pr_approval",
            "record-pr-progress",
        ),
        (
            &["set", "--item", ITEM, "/children_detached", "1"],
            "children_detached",
            "record-pr-progress",
        ),
        (
            &["set", "--item", ITEM, "/ci_rerun", r#"{"head":"x"}"#],
            "ci_rerun",
            "record-pr-progress",
        ),
        (
            &[
                "upsert",
                "--item",
                ITEM,
                "/restack_skips",
                "--key",
                "head",
                &skip,
            ],
            "restack_skips",
            "record-pr-progress",
        ),
        (
            &[
                "set",
                "--item",
                ITEM,
                "/pauses",
                r#"[{"from":"2026-09-20T08:00:00Z","to":null,"cause":"walled"}]"#,
            ],
            "pauses",
            "record-pr-progress",
        ),
        (
            &["set", "--item", ITEM, "/post_pr_stop", r#"{"name":"n"}"#],
            "post_pr_stop",
            "post-pr-stop",
        ),
        (
            &[
                "set",
                "--item",
                ITEM,
                "/post_pr_budgets/ci_fix",
                r#"{"attempts":1}"#,
            ],
            "post_pr_budgets",
            "head-budget",
        ),
        (
            &[
                "set",
                "--fleet",
                "/last_backlog_audit",
                r#"{"at":"now","backlog":1}"#,
            ],
            "last_backlog_audit",
            "record-overseer-ledger",
        ),
        (
            &["set", "--fleet", "/launch_queue", r#"["KEN-1","KEN-1"]"#],
            "launch_queue",
            "record-overseer-ledger",
        ),
    ];
    let item = fs::read_to_string(store.item_path(ITEM)).unwrap();
    let fleet = fs::read_to_string(store.fleet_path()).unwrap();
    for (args, field, op) in rows {
        let mut call = vec!["state"];
        call.extend_from_slice(args);
        let (key, line) = store.refused(&call);
        assert_eq!(key, "field-owned", "{args:?}");
        assert!(line.contains(&format!("field={field} op={op}")), "{line}");
    }
    assert_eq!(fs::read_to_string(store.item_path(ITEM)).unwrap(), item);
    assert_eq!(fs::read_to_string(store.fleet_path()).unwrap(), fleet);
    store.ok(&[
        "state",
        "set",
        "--item",
        ITEM,
        "/pr_order",
        "push-first",
        "/tier",
        "micro",
    ]);
    let doc = store.doc(&store.item_path(ITEM));
    assert_eq!(
        (&doc["pr_order"], &doc["tier"]),
        (&json!("push-first"), &json!("micro"))
    );
}
