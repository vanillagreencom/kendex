//! The session send verb (step6-map § A6, § B "a hand-opened session's
//! send"; decisions 31, 170, 182): `orch-runtime send` against the real
//! mailbox program on a temporary checkout, the Claude CLI a fixture, the
//! account listing a stub. Each row names the defect it catches at its doc
//! comment.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records, run the built binary and the real mailbox program, and read the files they left"
)]

#[path = "support.rs"]
mod support;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;

use serde_json::{Value, json};
use support::*;

const CLOUD: &str = "CC-1";
const MAILBOX: &str = "CC-2";
const FOREIGN: &str = "CC-3";
const SESSION: &str = "session_01CLOUD";
const TEXT: &str = "Rebase on main, then push.\n";
const OPEN_CREDIT: &str = r#"{"remaining_dollars":12.5,"locked_reason":null}"#;

/// The real mailbox program, the sibling package's, and the orch scripts
/// beside this crate.
fn real_lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap()
}

fn orch_scripts() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../scripts")
        .canonicalize()
        .unwrap()
}

/// One checkout holding the fleet state as its own state directory, three
/// lanes on it (a cloud session, a mailbox lane and a cloud session whose
/// root is another repository's), and a scripts tree the mailbox program
/// runs beside: every orch script linked to the real one but `lanes`, a
/// stub printing the planted listing, and `workflow-state`, the real one
/// behind a wrapper that logs each verb it is asked.
struct World {
    _dir: tempfile::TempDir,
    _aux: tempfile::TempDir,
    root: PathBuf,
    lane_mail: PathBuf,
    account: PathBuf,
    directive: PathBuf,
    claude_log: PathBuf,
    lanes_log: PathBuf,
    state_log: PathBuf,
}

fn git(root: &Path, args: &[&str]) {
    let out = program("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
}

fn init_repo(root: &Path) {
    git(root, &["init", "-q"]);
    git(root, &["config", "gc.auto", "0"]);
    git(root, &["config", "maintenance.auto", "false"]);
}

fn script(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let aux = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    init_repo(&root);
    let foreign = root.join("foreign");
    std::fs::create_dir(&foreign).unwrap();
    init_repo(&foreign);
    let account = root.join(".eclaude");
    std::fs::create_dir(&account).unwrap();
    std::fs::create_dir_all(root.join("wt").join(CLOUD)).unwrap();
    let mut fleet: Value =
        serde_json::from_str(include_str!("fixtures/workflow-state-oversee.json")).unwrap();
    let cloud = |item: &str, mail_root: &Path| {
        json!({
            "item": item,
            "harness": "claude",
            "host": "claude-cloud",
            "kind": "claude-cloud",
            "account": account.display().to_string(),
            "session_id": SESSION,
            "mail_root": mail_root.display().to_string(),
            "window": null,
            "status": "running",
        })
    };
    fleet["lanes"] = json!([
        cloud(CLOUD, &root.join("wt").join(CLOUD)),
        {
            "item": MAILBOX,
            "harness": "claude",
            "host": null,
            "kind": "local",
            "account": account.display().to_string(),
            "mail_root": root.display().to_string(),
            "window": "fleet:CC-2",
            "status": "running",
        },
        cloud(FOREIGN, &foreign),
    ]);
    fleet["intents"] = json!([]);
    std::fs::write(
        root.join("workflow-state-oversee.json"),
        serde_json::to_string_pretty(&fleet).unwrap(),
    )
    .unwrap();
    let directive = root.join("directive.txt");
    std::fs::write(&directive, TEXT).unwrap();
    // The scripts tree: the mailbox program finds the orch scripts two
    // directories up from its own place, so it is linked into a tree of
    // its own beside the stubbed `lanes` and the logging `workflow-state`.
    let tree = aux.path().join("tree");
    let mailbox = tree.join("mailbox").join("scripts");
    let orch = tree.join("orch").join("scripts");
    std::fs::create_dir_all(&mailbox).unwrap();
    std::fs::create_dir_all(&orch).unwrap();
    let real = real_lane_mail();
    std::os::unix::fs::symlink(&real, mailbox.join("lane-mail")).unwrap();
    std::os::unix::fs::symlink(real.parent().unwrap().join("lib"), mailbox.join("lib")).unwrap();
    for entry in std::fs::read_dir(orch_scripts()).unwrap() {
        let entry = entry.unwrap();
        std::os::unix::fs::symlink(entry.path(), orch.join(entry.file_name())).unwrap();
    }
    let lanes_log = aux.path().join("lanes.log");
    std::fs::remove_file(orch.join("lanes")).unwrap();
    script(
        &orch.join("lanes"),
        &format!(
            "#!/bin/bash\nprintf 'dirs=%s argv=%s\\n' \"${{ORCH_LANE_DIRS:-}}\" \"$*\" >> {}\nprintf '%s\\n' \"${{LANES_LISTING:-[]}}\"\nexit \"${{LANES_RC:-0}}\"\n",
            lanes_log.display()
        ),
    );
    let state_log = aux.path().join("workflow-state.log");
    std::fs::remove_file(orch.join("workflow-state")).unwrap();
    script(
        &orch.join("workflow-state"),
        &format!(
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> {}\nexec {} \"$@\"\n",
            state_log.display(),
            orch_scripts().join("workflow-state").display()
        ),
    );
    let claude_log = aux.path().join("claude.log");
    World {
        _dir: dir,
        _aux: aux,
        root,
        lane_mail: mailbox.join("lane-mail"),
        account,
        directive,
        claude_log,
        lanes_log,
        state_log,
    }
}

/// The listing `lanes list --json` answers: the account's row with
/// `credit` beside another account's.
fn listing(account: &Path, credit: &str) -> String {
    format!(
        r#"[{{"config_dir":"/other","credits":{{"remaining_dollars":99,"locked_reason":null}}}},{{"config_dir":"{}","credits":{credit}}}]"#,
        account.display()
    )
}

impl World {
    fn fleet_path(&self) -> PathBuf {
        self.root.join("workflow-state-oversee.json")
    }

    fn fleet(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.fleet_path()).unwrap()).unwrap()
    }

    fn lane(&self, item: &str) -> Value {
        self.fleet()["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .cloned()
            .unwrap()
    }

    /// The environment every child of a row carries: the fixture CLI first
    /// on PATH, the mailbox program of the tree, the open credit listing.
    fn env(&self, command: &mut std::process::Command, extra: &[(&str, &str)]) {
        command
            .env("PATH", tool_path(&[&fixtures().join("claude-cloud")]))
            .env("LANE_MAIL_CLI", &self.lane_mail)
            .env("CLAUDE_CLOUD_LOG", &self.claude_log)
            .env("LANES_LISTING", listing(&self.account, OPEN_CREDIT))
            .current_dir(&self.root);
        for (name, value) in extra {
            command.env(name, value);
        }
    }

    /// The verb on the fleet, with `extra` environment.
    fn send(&self, item: &str, extra: &[(&str, &str)]) -> Output {
        let mut command = isolated();
        command
            .args(["--state-dir", &self.root.display().to_string()])
            .args(["send", "--item", item, "--file"])
            .arg(&self.directive);
        self.env(&mut command, extra);
        command.output().unwrap()
    }

    fn reconcile(&self) -> Value {
        let mut command = isolated();
        command
            .args(["--state-dir", &self.root.display().to_string()])
            .args(["reconcile", "--fleet"]);
        self.env(&mut command, &[]);
        let out = command.output().unwrap();
        let answer = reply(&out);
        assert!(answer["ok"].as_bool().unwrap_or(false), "{}", stderr(&out));
        answer["result"].clone()
    }

    /// The operator's `op` on the fleet, as the handling text has it.
    fn op(&self, request: &Value) -> Value {
        let file = self._aux.path().join("request.json");
        std::fs::write(&file, serde_json::to_vec(request).unwrap()).unwrap();
        let mut command = isolated();
        command
            .args(["--state-dir", &self.root.display().to_string()])
            .args(["op", "--fleet", "--request", &file.display().to_string()]);
        self.env(&mut command, &[]);
        let out = command.output().unwrap();
        result(&out)
    }

    /// The mailbox program behind a wrapper that hands the CLI fixture its
    /// own pid, so the fixture can end the program after the directive was
    /// taken and before any receipt.
    fn killable_lane_mail(&self) -> PathBuf {
        let wrapper = self._aux.path().join("lane-mail-killable");
        script(
            &wrapper,
            &format!(
                "#!/bin/bash\nexport CLAUDE_CLOUD_KILL=\"$$\"\nexec {} \"$@\"\n",
                self.lane_mail.display()
            ),
        );
        wrapper
    }

    /// The calls the CLI fixture took, three lines each.
    fn cli_calls(&self) -> Vec<String> {
        std::fs::read_to_string(&self.claude_log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    fn log(&self, path: &Path) -> Vec<String> {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }
}

/// The reply of a verb that answered, refusing a reply that did not.
fn result(out: &Output) -> Value {
    let answer = reply(out);
    assert!(
        answer["ok"].as_bool().unwrap_or(false),
        "refused: {}",
        stderr(out)
    );
    answer["result"].clone()
}

fn first_stderr_line(out: &Output) -> String {
    stderr(out).lines().next().unwrap_or_default().to_owned()
}

/// The three lines one CLI call logs for the directive.
fn one_call(account: &Path) -> [String; 3] {
    [
        format!("argv=-p --cloud {SESSION} --output-format json"),
        format!("config={}", account.display()),
        format!("stdin={}", TEXT.trim_end()),
    ]
}

/// § A6 row (1). Defect: a send queued twice because its record said
/// nothing was out: a crash or a refused mark after the CLI answered, and
/// the next send or the reconcile sending again. The record stands `owed`
/// with the directive's words while the CLI runs (the fixture copies the
/// fleet file as it answers) and `sent` with the credit after; a second
/// send whose mark the store refuses (the state directory sealed by the
/// fixture) leaves the record owed, keeps the receipt beside the state and
/// says so in its reply; a third send is refused `directive-send-owed` with
/// no CLI call; the reconcile stamps the kept receipt, with the send's own
/// epoch, and calls nothing; an owed record naming no kept receipt is
/// reported and left.
#[test]
fn a_send_is_owed_before_the_cli_and_a_refused_mark_is_settled_by_the_reconcile_without_a_second_send()
 {
    let w = world();
    let snapshot = w._aux.path().join("snapshot.json");
    let out = w.send(
        CLOUD,
        &[
            ("CLAUDE_CLOUD_SNAPSHOT", snapshot.to_str().unwrap()),
            ("CLAUDE_CLOUD_SNAPSHOT_OF", w.fleet_path().to_str().unwrap()),
        ],
    );
    let during: Value = serde_json::from_str(&std::fs::read_to_string(&snapshot).unwrap()).unwrap();
    let owed = during["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["item"] == CLOUD)
        .cloned()
        .unwrap();
    assert_eq!(
        owed["directive_send"]["result"], "owed",
        "owed while the CLI runs: {owed}"
    );
    assert_eq!(owed["directive_send"]["text"], TEXT.trim_end());
    assert!(owed["directive_send"]["receipt"].is_string(), "{owed}");
    let answer = result(&out);
    assert_eq!(answer["mark"], "recorded", "{answer}");
    assert_eq!(answer["send"]["result"], "sent");
    let record = w.lane(CLOUD)["directive_send"].clone();
    assert!(record["at"].is_u64(), "{record}");
    assert_eq!(record["result"], "sent");
    assert_eq!(record["text"].as_str().unwrap().trim(), "", "no CLI words");
    assert_eq!(
        record["credit"],
        json!({"remaining_dollars": 12.5, "locked_reason": null})
    );
    assert_eq!(
        answer["directive_send"], record,
        "the reply carries the record"
    );
    assert_eq!(w.cli_calls(), one_call(&w.account));
    assert_eq!(
        w.log(&w.lanes_log),
        [format!(
            "dirs={} argv=list --harness claude --local --json",
            w.account.display()
        )],
        "the credit is read for the record's account alone"
    );
    assert!(
        std::fs::read_dir(w.root.join("directive-send"))
            .map(|d| d.count() == 0)
            .unwrap_or(true),
        "no receipt kept once the mark stands"
    );
    // The mark refused: the state directory is sealed while the CLI runs.
    let out = w.send(CLOUD, &[("CLAUDE_CLOUD_SEAL", w.root.to_str().unwrap())]);
    let answer = result(&out);
    assert_eq!(answer["mark"], "unmarked", "{answer}");
    assert_eq!(answer["send"]["result"], "sent");
    let receipt = PathBuf::from(answer["receipt"].as_str().unwrap());
    let standing = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(standing["result"], "owed", "{standing}");
    assert_eq!(
        receipt,
        w.root.join("directive-send").join(format!(
            "{CLOUD}.{}.json",
            standing["receipt"].as_str().unwrap()
        )),
        "the receipt the record names"
    );
    let kept: Value = serde_json::from_str(&std::fs::read_to_string(&receipt).unwrap()).unwrap();
    assert!(kept["at"].is_u64(), "{kept}");
    assert_eq!(kept["send"]["result"], "sent");
    assert_eq!(w.cli_calls().len(), 6, "two calls so far");
    // A third send is refused before anything runs.
    let out = w.send(CLOUD, &[]);
    assert!(!out.status.success());
    assert_eq!(
        first_stderr_line(&out),
        format!("orch-runtime: directive-send-owed item={CLOUD}")
    );
    assert_eq!(w.cli_calls().len(), 6, "nothing sent");
    assert_eq!(
        w.lane(CLOUD)["directive_send"],
        standing,
        "the record as it stood"
    );
    // The reconcile stamps the kept receipt and sends nothing.
    std::fs::set_permissions(&w.root, std::fs::Permissions::from_mode(0o755)).unwrap();
    let run = w.reconcile();
    assert_eq!(run["sends_settled"], json!([CLOUD]), "{run}");
    assert!(run.get("sends_unsettled").is_none(), "{run}");
    let settled = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(settled["at"], kept["at"], "the send's own epoch");
    assert_eq!(settled["result"], "sent");
    assert_eq!(
        settled["credit"],
        json!({"remaining_dollars": 12.5, "locked_reason": null})
    );
    assert!(std::fs::metadata(&receipt).is_err(), "the receipt is spent");
    assert_eq!(w.cli_calls().len(), 6, "the reconcile sent nothing");
    // An owed record whose receipt was never kept is reported, left owed.
    let mut fleet = w.fleet();
    for lane in fleet["lanes"].as_array_mut().unwrap() {
        if lane["item"] == CLOUD {
            lane["directive_send"] = json!({"result": "owed", "text": "x", "receipt": "none"});
        }
    }
    std::fs::write(
        w.fleet_path(),
        serde_json::to_string_pretty(&fleet).unwrap(),
    )
    .unwrap();
    let run = w.reconcile();
    assert_eq!(
        run["sends_unsettled"],
        json!([{"item": CLOUD, "cause": "receipt-missing"}]),
        "{run}"
    );
    assert_eq!(w.lane(CLOUD)["directive_send"]["result"], "owed");
    assert_eq!(w.cli_calls().len(), 6, "the reconcile sent nothing");
}

/// Decision 184 (5), R-U6-1 M2, the map's A6 row (1) case "the CLI killed
/// after queuing". Defect: an owed send no receipt settles standing for
/// ever, every later send refused and no route out. The mailbox program is
/// killed after the CLI took the directive and before any receipt: the verb
/// refuses `directive-send-unsettled`, the record stands `owed` with the
/// directive's words and no receipt is kept; the next send is refused
/// `directive-send-owed` with no CLI call; the reconcile reports the lane
/// `receipt-missing`, the word the watch's line carries, and sends nothing;
/// the operator's mark through `op` settles the record `failed` with the
/// cause and `owner: operator`, after which the reconcile reports nothing
/// and the next send proceeds and records `sent`.
#[test]
fn a_program_killed_after_queuing_leaves_the_send_owed_until_the_operator_marks_it_failed() {
    let w = world();
    let wrapper = w.killable_lane_mail();
    // The program's scratch under the row's own directory: a killed
    // program runs no cleanup.
    let out = w.send(
        CLOUD,
        &[
            ("LANE_MAIL_CLI", wrapper.to_str().unwrap()),
            ("TMPDIR", w._aux.path().to_str().unwrap()),
        ],
    );
    assert!(!out.status.success(), "{}", stderr(&out));
    assert_eq!(
        first_stderr_line(&out),
        format!("orch-runtime: directive-send-unsettled item={CLOUD}")
    );
    assert_eq!(
        w.cli_calls(),
        one_call(&w.account),
        "the directive was taken"
    );
    let owed = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(owed["result"], "owed", "{owed}");
    assert_eq!(owed["text"], TEXT.trim_end());
    assert!(
        std::fs::read_dir(w.root.join("directive-send"))
            .map(|d| d.count() == 0)
            .unwrap_or(true),
        "no receipt kept"
    );
    // The next send is refused before anything runs.
    let out = w.send(CLOUD, &[]);
    assert!(!out.status.success());
    assert_eq!(
        first_stderr_line(&out),
        format!("orch-runtime: directive-send-owed item={CLOUD}")
    );
    assert_eq!(w.cli_calls().len(), 3, "nothing sent");
    // The reconcile reports it with the line's word and sends nothing.
    let run = w.reconcile();
    assert_eq!(
        run["sends_unsettled"],
        json!([{"item": CLOUD, "cause": "receipt-missing"}]),
        "{run}"
    );
    assert_eq!(w.lane(CLOUD)["directive_send"], owed, "left as it stood");
    assert_eq!(w.cli_calls().len(), 3, "the reconcile sent nothing");
    // The operator's mark, as the handling text has it.
    w.op(&json!({
        "op": "record-directive-send",
        "item": CLOUD,
        "write": {"stage": "failed", "cause": "session reset by hand"},
    }));
    let settled = w.lane(CLOUD)["directive_send"].clone();
    assert!(settled["at"].is_u64(), "{settled}");
    assert_eq!(
        settled,
        json!({
            "at": settled["at"],
            "result": "failed",
            "text": "session reset by hand",
            "credit": "unread",
            "owner": "operator",
        })
    );
    let run = w.reconcile();
    assert!(run.get("sends_unsettled").is_none(), "{run}");
    // The next send proceeds.
    let out = w.send(CLOUD, &[]);
    let answer = result(&out);
    assert_eq!(answer["mark"], "recorded", "{answer}");
    assert_eq!(answer["send"]["result"], "sent");
    assert_eq!(w.lane(CLOUD)["directive_send"]["result"], "sent");
    assert_eq!(w.cli_calls().len(), 6, "the directive went out once more");
}

/// § A6 row (2). Defect: a refusal read as a delivery, or recorded without
/// the words a close names its cause by. An archived session records
/// `archived`, a session not found `failed`, each with the CLI's words and
/// the credit read at the send; a refusal the mailbox program makes before
/// the CLI (a session whose root is another repository's) records `failed`
/// with the program's keyed line, the credit unread, no CLI call; a mailbox
/// lane is refused `lane-channel` before any write, its mailbox untouched.
#[test]
fn a_refused_send_records_its_result_with_the_words_and_a_mailbox_lane_is_refused() {
    let w = world();
    let archived = r#"{"ok":false,"error":"Session session_01CLOUD is archived"}"#;
    let missing = r#"{"ok":false,"error":"Session not found"}"#;
    let locked = r#"{"remaining_dollars":0,"locked_reason":"spend_limit"}"#;
    // item, CLI answer, listing credit, result, words, credit, CLI calls
    let rows: [(&str, &str, &str, &str, &str, Value, usize); 3] = [
        (
            CLOUD,
            archived,
            locked,
            "archived",
            "is archived",
            json!({"remaining_dollars": 0, "locked_reason": "spend_limit"}),
            3,
        ),
        (
            CLOUD,
            missing,
            OPEN_CREDIT,
            "failed",
            "Session not found",
            json!({"remaining_dollars": 12.5, "locked_reason": null}),
            6,
        ),
        (
            FOREIGN,
            "",
            OPEN_CREDIT,
            "failed",
            "lane-foreign=",
            json!("unread"),
            6,
        ),
    ];
    for (item, answer, credit, result_word, words, credit_record, calls) in rows {
        let out = w.send(
            item,
            &[
                ("CLAUDE_CLOUD_ANSWER", answer),
                ("LANES_LISTING", &listing(&w.account, credit)),
            ],
        );
        let answer = result(&out);
        assert_eq!(answer["mark"], "recorded", "{item}: {answer}");
        assert_eq!(answer["send"]["result"], result_word, "{item}");
        let record = w.lane(item)["directive_send"].clone();
        assert!(record["at"].is_u64(), "{item}: {record}");
        assert_eq!(record["result"], result_word, "{item}: {record}");
        assert!(
            record["text"].as_str().unwrap().contains(words),
            "{item}: the words: {record}"
        );
        assert_eq!(record["credit"], credit_record, "{item}: {record}");
        assert_eq!(w.cli_calls().len(), calls, "{item}: the CLI calls");
    }
    let before = std::fs::read(w.fleet_path()).unwrap();
    let out = w.send(MAILBOX, &[]);
    assert!(!out.status.success());
    assert_eq!(
        first_stderr_line(&out),
        format!("orch-runtime: lane-channel item={MAILBOX}")
    );
    assert_eq!(
        std::fs::read(w.fleet_path()).unwrap(),
        before,
        "nothing written"
    );
    assert!(
        std::fs::metadata(w.root.join("tmp").join("lane-mail").join(MAILBOX)).is_err(),
        "no mailbox append"
    );
    assert_eq!(w.cli_calls().len(), 6, "no CLI call");
}

/// § A6 row (3), the mailbox-only contract (decision 31). Defect: the
/// mailbox program writing orch state beside the runtime's own writer, so
/// two writers shape one record. Through the verb, every `workflow-state`
/// call the program makes is a read (`exists`, `get`); a bare `lane-mail
/// send` to the same lane prints the `sent` receipt on stdout and the
/// record line on stderr and leaves the fleet file byte for byte as it was.
#[test]
fn the_mailbox_program_reads_the_fleet_and_writes_none_of_it() {
    let w = world();
    let out = w.send(CLOUD, &[]);
    result(&out);
    let verbs: Vec<String> = w
        .log(&w.state_log)
        .iter()
        .map(|line| {
            let words: Vec<&str> = line.split(' ').collect();
            // `--state-dir <dir> <verb> ...`
            words.get(2).unwrap_or(&"").to_string()
        })
        .collect();
    assert!(
        !verbs.is_empty(),
        "the program read the fleet for the channel"
    );
    assert!(
        verbs.iter().all(|v| v == "exists" || v == "get"),
        "reads alone: {:?}",
        w.log(&w.state_log)
    );
    let before = std::fs::read(w.fleet_path()).unwrap();
    let mut command = program(&w.lane_mail);
    command
        .args(["send", "--item", CLOUD, "--directive", "--file"])
        .arg(&w.directive)
        .args(["--state-dir", &w.root.display().to_string()]);
    w.env(&mut command, &[]);
    let out = command.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(
        String::from_utf8_lossy(&out.stdout).trim_end(),
        format!("lane-mail: sent item={CLOUD} channel=session session={SESSION}")
    );
    assert!(
        stderr(&out)
            .lines()
            .any(|l| l.starts_with(&format!("lane-mail: directive-send item={CLOUD} record="))),
        "the receipt line: {}",
        stderr(&out)
    );
    assert_eq!(
        std::fs::read(w.fleet_path()).unwrap(),
        before,
        "the fleet file as it was"
    );
    assert_eq!(
        w.cli_calls().len(),
        6,
        "the bare send reached the session once"
    );
}

// --- U6l: the validation end notice over the session route (decision 188 (d)) ---

/// The fixture item's open dev round.
const ROUND: &str = "1769600000123456789-1837";

/// The world with the cloud lane's item recorded beside the fleet, its
/// worktree the checkout with one commit, so `validate start` and `validate
/// run` (the job run by the row, the launcher recording only) send the end
/// notice to the cloud lane through the session route and the real
/// mailbox program.
fn validation_world() -> (World, PathBuf) {
    let w = world();
    std::fs::write(w.root.join("a.txt"), "a\n").unwrap();
    std::fs::write(
        w.root.join(".gitignore"),
        "tmp\nwt\nforeign\ndirective-send\nvalidate\n",
    )
    .unwrap();
    git(&w.root, &["add", "a.txt", ".gitignore"]);
    git(&w.root, &["commit", "-q", "-m", "base"]);
    let mut item: Value =
        serde_json::from_str(include_str!("fixtures/workflow-state-KEN-4687.json")).unwrap();
    item["worktree"] = json!(w.root.display().to_string());
    let path = w.root.join(format!("workflow-state-{CLOUD}.json"));
    std::fs::write(&path, serde_json::to_vec(&item).unwrap()).unwrap();
    (w, path)
}

impl World {
    /// The binary on the item beside the fleet, with the validate rows'
    /// fixtures: the child executor, the classifier, the launcher
    /// recording only, the declaration.
    fn validate(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let f = fixtures();
        let mut command = isolated();
        command
            .arg("--state-dir")
            .arg(&self.root)
            .args(args)
            .env(
                "DEV_VALIDATE_CLI",
                f.join("dev-validate-child/dev-validate-run"),
            )
            .env(
                "CHANGE_SCOPE_PATHS_CLI",
                f.join("change-scope-fixture/harness-only"),
            )
            .env("ORCH_JOB_UNIT", f.join("job-unit-real/job-unit"))
            .env("JOB_UNIT_RECORD_ONLY", "1")
            .env("DEV_VALIDATE_CMD", "echo full")
            .env("DEV_VALIDATE_TIMEOUT_SECS", "20");
        self.env(&mut command, extra);
        command.output().unwrap()
    }

    /// One started run, run by the row: the stage closed and the notice
    /// sent over the session route; the run directory.
    fn validated(&self, extra: &[(&str, &str)]) -> (String, Value) {
        let started = result(&self.validate(
            &["validate", "start", "--item", CLOUD, "--round", ROUND],
            &[],
        ));
        let dir = started["run_dir"].as_str().unwrap().to_owned();
        let ended = result(&self.validate(
            &[
                "validate",
                "run",
                "--item",
                CLOUD,
                "--round",
                ROUND,
                "--run-dir",
                &dir,
            ],
            extra,
        ));
        (dir, ended)
    }

    fn stage(&self, item_path: &Path, dir: &str) -> Value {
        let item: Value =
            serde_json::from_str(&std::fs::read_to_string(item_path).unwrap()).unwrap();
        item["stages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["run_dir"] == dir)
            .cloned()
            .unwrap()
    }

    /// The stage's notice planted `owed` again: the crash between the
    /// send's settle and the stage's mark, or a mark the store refused.
    fn owe_notice(&self, item_path: &Path, dir: &str) {
        let mut item: Value =
            serde_json::from_str(&std::fs::read_to_string(item_path).unwrap()).unwrap();
        for stage in item["stages"].as_array_mut().unwrap() {
            if stage["run_dir"] == dir {
                stage["notice"]["owner"] = json!("owed");
            }
        }
        std::fs::write(item_path, serde_json::to_vec(&item).unwrap()).unwrap();
    }

    /// The cloud lane's `directive_send` planted as `record`, or removed.
    fn plant_send(&self, record: Option<Value>) {
        let mut fleet = self.fleet();
        for lane in fleet["lanes"].as_array_mut().unwrap() {
            if lane["item"] == CLOUD {
                match &record {
                    Some(record) => lane["directive_send"] = record.clone(),
                    None => {
                        lane.as_object_mut().unwrap().remove("directive_send");
                    }
                }
            }
        }
        std::fs::write(
            self.fleet_path(),
            serde_json::to_string_pretty(&fleet).unwrap(),
        )
        .unwrap();
    }

    /// The round's reconcile on the item: the owed walk that replays a
    /// notice still owed.
    fn reconcile_round(&self) -> Value {
        let file = self._aux.path().join("reconcile.json");
        std::fs::write(
            &file,
            json!({"op": "reconcile-round", "round_id": ROUND}).to_string(),
        )
        .unwrap();
        result(&self.validate(
            &[
                "op",
                "--item",
                CLOUD,
                "--request",
                &file.display().to_string(),
            ],
            &[],
        ))
    }
}

/// R-U6-2 Copilot 2 (decision 187 (2), 188 (d)): a session the CLI answers
/// archived for took no notice, and the stage says so. The end notice to a
/// cloud lane whose session is archived is marked `unsent:session:archived`,
/// never `sent`, the lane's `directive_send` records `archived` under the
/// notice's key, and the mark is terminal: the round's next reconcile sends
/// nothing again. Defect caught: every `Ok` of the session send read as
/// delivered, so a rejected notice recorded `sent` while the lane heard
/// nothing (the reviewer's `copilot_rejected_cloud_validation_notice_is_not_recorded_sent`).
#[test]
fn a_rejected_session_notice_is_marked_by_its_result_never_sent() {
    let (w, item) = validation_world();
    let archived = r#"{"ok":false,"error":"Session session_01CLOUD is archived"}"#;
    let (dir, ended) = w.validated(&[("CLAUDE_CLOUD_ANSWER", archived)]);
    assert_eq!(ended["closed_now"], true, "{ended}");
    assert_eq!(ended["outcome"], "pass", "{ended}");
    assert_eq!(ended["notice"], "unsent:session:archived", "{ended}");
    let stage = w.stage(&item, &dir);
    assert_eq!(
        stage["notice"]["owner"], "unsent:session:archived",
        "{stage}"
    );
    let key = stage["notice"]["key"].as_str().unwrap().to_owned();
    assert!(key.starts_with("validate-"), "{stage}");
    let record = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(record["result"], "archived", "{record}");
    assert_eq!(
        record["key"], key,
        "the send under the notice's key: {record}"
    );
    assert!(
        record["text"].as_str().unwrap().contains("is archived"),
        "{record}"
    );
    assert_eq!(w.cli_calls().len(), 3, "one call");
    // Terminal: not owed, so the reconcile's owed walk sends nothing.
    w.reconcile_round();
    assert_eq!(w.cli_calls().len(), 3, "the reconcile sent nothing");
    assert_eq!(
        w.stage(&item, &dir)["notice"]["owner"],
        "unsent:session:archived"
    );
}

/// R-U6-2 opus L1 and Copilot's crash construction (decisions 187 (2), 188
/// (d)): the session send is keyed by the notice, so a crash between the
/// send's settle and the stage's mark replays without a second call. The
/// job's run sends once and the lane records `sent` under the notice's key;
/// the stage's notice planted `owed` again (the crash, or a mark the store
/// refused), the round's reconcile reads that keyed send on the lane and
/// marks the stage `sent` with no CLI call. Defect caught: the replay
/// finding no owed record and sending the notice again (the reviewer's
/// `copilot_cloud_notice_crash_after_send_mark_does_not_send_twice`: six
/// CLI lines for three).
#[test]
fn a_crash_between_the_sends_settle_and_the_stages_mark_replays_without_a_second_call() {
    let (w, item) = validation_world();
    let (dir, ended) = w.validated(&[]);
    assert_eq!(ended["notice"], "sent", "{ended}");
    let key = w.stage(&item, &dir)["notice"]["key"].clone();
    let record = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(record["result"], "sent", "{record}");
    assert_eq!(record["key"], key, "{record}");
    assert_eq!(w.cli_calls(), one_call_of(&w, "validation-end run="));
    w.owe_notice(&item, &dir);
    w.reconcile_round();
    assert_eq!(
        w.cli_calls().len(),
        3,
        "a send already settled under this notice's key is not made again"
    );
    assert_eq!(w.stage(&item, &dir)["notice"]["owner"], "sent");
    assert_eq!(
        w.lane(CLOUD)["directive_send"],
        record,
        "the lane's record as it stood"
    );
}

/// The three lines the one CLI call of the notice logs: the argv, the
/// account, and the notice's first line starting `prefix`.
fn one_call_of(w: &World, prefix: &str) -> Vec<String> {
    let calls = w.cli_calls();
    assert_eq!(calls.len(), 3, "{calls:?}");
    assert_eq!(
        calls[0],
        format!("argv=-p --cloud {SESSION} --output-format json")
    );
    assert_eq!(calls[1], format!("config={}", w.account.display()));
    assert!(
        calls[2].starts_with(&format!("stdin={prefix}")),
        "{calls:?}"
    );
    calls
}

/// Decision 188 (d), the replay's reading table: a notice still owed reads
/// the lane's `directive_send` first and acts on what this notice's own
/// send settled. Settled `archived` under this key takes the terminal mark
/// with no call; owed under this key waits, the stage left owed with no
/// call; settled under another key, or no record at all, is the first
/// call's case and sends. Defect caught: a replay taking another send's
/// result as this notice's, or waiting on a send that was never its own.
#[test]
fn a_replay_reads_the_lanes_keyed_send_before_it_sends() {
    let (w, item) = validation_world();
    let (dir, _) = w.validated(&[]);
    let key = w.stage(&item, &dir)["notice"]["key"]
        .as_str()
        .unwrap()
        .to_owned();
    let settled = |result: &str, key: &str| json!({"at": 1_769_700_000, "result": result, "text": "", "credit": "unread", "key": key});
    // lane record planted, mark after the reconcile, CLI lines after
    let rows: [(Option<Value>, &str, usize); 4] = [
        (
            Some(settled("archived", &key)),
            "unsent:session:archived",
            3,
        ),
        (
            Some(json!({"result": "owed", "text": "x", "receipt": "none", "key": key})),
            "owed",
            3,
        ),
        (Some(settled("sent", "validate-other")), "sent", 6),
        (None, "sent", 9),
    ];
    for (record, mark, calls) in rows {
        w.plant_send(record.clone());
        w.owe_notice(&item, &dir);
        w.reconcile_round();
        assert_eq!(
            w.stage(&item, &dir)["notice"]["owner"],
            mark,
            "planted {record:?}"
        );
        assert_eq!(w.cli_calls().len(), calls, "planted {record:?}");
    }
    let record = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(record["result"], "sent", "{record}");
    assert_eq!(
        record["key"], key,
        "the send made under this notice's key: {record}"
    );
}
