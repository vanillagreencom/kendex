//! The session send verb: `orch-runtime send` against the real mailbox
//! program on a temporary checkout, the Claude CLI a fixture, the account's
//! credit the real roster's reading of a planted usage record. Each row's
//! name carries the defect it catches.
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
/// An account's cloud credit: the dollars left and the lock's reason.
type Credit = (f64, Option<&'static str>);
const OPEN_CREDIT: Credit = (12.5, None);

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
/// runs beside: every orch script linked to the real one but
/// `orch-runtime`, linked to this build's binary, and `workflow-state`,
/// the real one behind a wrapper that logs each verb it is asked; and
/// agent-runtime's entry, its built binary, which reads the credit. The
/// lanes' Claude account and another stand under a home of their own,
/// each with its credential and a fresh usage record carrying a credit.
struct World {
    _dir: tempfile::TempDir,
    _aux: tempfile::TempDir,
    root: PathBuf,
    lane_mail: PathBuf,
    account: PathBuf,
    accounts: PathBuf,
    directive: PathBuf,
    claude_log: PathBuf,
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

fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let aux = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(dir.path()).unwrap();
    init_repo(&root);
    let foreign = root.join("foreign");
    std::fs::create_dir(&foreign).unwrap();
    init_repo(&foreign);
    // `plant_accounts` places a local account at `<root>/home/<name>`.
    let accounts = aux.path().join("accounts");
    let account = accounts.join("home").join(".eclaude");
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
    // its own beside the logging `workflow-state`, and agent-runtime's
    // entry two directories up as well. Each package's entry is its built
    // binary, which the shipped wrapper would find only in a set-up cache.
    let tree = aux.path().join("tree");
    let mailbox = tree.join("mailbox").join("scripts");
    let orch = tree.join("orch").join("scripts");
    let shared = tree.join("agent-runtime").join("scripts");
    for dir in [&mailbox, &orch, &shared] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::os::unix::fs::symlink(agent_runtime(), shared.join("agent-runtime")).unwrap();
    let real = real_lane_mail();
    std::os::unix::fs::symlink(&real, mailbox.join("lane-mail")).unwrap();
    std::os::unix::fs::symlink(real.parent().unwrap().join("lib"), mailbox.join("lib")).unwrap();
    for entry in std::fs::read_dir(orch_scripts()).unwrap() {
        let entry = entry.unwrap();
        std::os::unix::fs::symlink(entry.path(), orch.join(entry.file_name())).unwrap();
    }
    std::fs::remove_file(orch.join("orch-runtime")).unwrap();
    std::os::unix::fs::symlink(binary(), orch.join("orch-runtime")).unwrap();
    let state_log = aux.path().join("workflow-state.log");
    std::fs::remove_file(orch.join("workflow-state")).unwrap();
    write_executable(
        &orch.join("workflow-state"),
        format!(
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> {}\nexec {} \"$@\"\n",
            state_log.display(),
            orch_scripts().join("workflow-state").display()
        ),
    );
    std::fs::create_dir_all(accounts.join("usage-answers")).unwrap();
    let claude_log = aux.path().join("claude.log");
    let world = World {
        _dir: dir,
        _aux: aux,
        root,
        lane_mail: mailbox.join("lane-mail"),
        account,
        accounts,
        directive,
        claude_log,
        state_log,
    };
    world.plant_credit(OPEN_CREDIT);
    world
}

/// One local Claude account at `dir` as the roster lists it: its usage
/// record carrying the cloud credit, `remaining` dollars left and the lock
/// `locked` names.
fn credit_row(dir: &Path, (remaining, locked): Credit) -> Value {
    json!({
        "alias": dir.file_name().unwrap().to_string_lossy().trim_start_matches('.'),
        "harness": "claude",
        "config_dir": dir.display().to_string(),
        "credits": {"unit": "usd", "limit_dollars": 50, "used_dollars": 50.0 - remaining,
                    "remaining_dollars": remaining, "resets_at": null, "locked_reason": locked},
    })
}

impl World {
    /// The account the world's own `AGENT_RUNTIME_ACCOUNT_DIRS` names: the lanes'
    /// account is not among them, so a credit the send reads is the one it
    /// asked for by the record's account.
    fn other_account(&self) -> PathBuf {
        self.accounts.join("home").join(".oclaude")
    }

    /// The lanes' account's credit as its usage record states it, beside
    /// the other account's own.
    fn plant_credit(&self, credit: Credit) {
        plant_accounts(
            &self.accounts,
            &self.accounts,
            None,
            &[
                credit_row(&self.account, credit),
                credit_row(&self.other_account(), (99.0, None)),
            ],
            now_ms() / 1000,
        );
    }

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
    /// on PATH, the mailbox program of the tree, the accounts' home and
    /// usage records, the other account as the configured one, and the
    /// usage fixture's `curl` over no answers, so a request the roster
    /// posts is refused, never sent out, and the credit reads unread.
    fn env(&self, command: &mut std::process::Command, extra: &[(&str, &str)]) {
        command
            .env(
                "PATH",
                tool_path(&[
                    &fixtures().join("claude-cloud"),
                    &account_fixtures().join("usage-curl"),
                ]),
            )
            .env("LANE_MAIL_CLI", &self.lane_mail)
            .env("CLAUDE_CLOUD_LOG", &self.claude_log)
            .env("HOME", self.accounts.join("home"))
            .env("OVERSEE_WATCH_STATE_DIR", &self.accounts)
            .env("AGENT_RUNTIME_ACCOUNT_STATE_DIR", &self.accounts)
            .env("AGENT_RUNTIME_ACCOUNT_DIRS", self.other_account())
            .env("USAGE_FIXTURE_DIR", self.accounts.join("usage-answers"))
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
        write_executable(
            &wrapper,
            format!(
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

/// A send whose record said nothing was out would be queued again by the
/// next send or the reconcile. The record stands `owed` with the
/// directive's words while the CLI runs (the fixture copies the fleet file
/// as it answers) and `sent` with the credit after; a second send whose
/// mark the store refuses (the state directory sealed by the fixture)
/// leaves the record owed, keeps the receipt beside the state and says so
/// in its reply; a third send is refused `directive-send-owed` with no CLI
/// call; the reconcile stamps the kept receipt, with the send's own epoch,
/// and calls nothing; an owed record naming no kept receipt is reported and
/// left.
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

/// An owed send no receipt settles has a route out. The mailbox program is
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

/// A refusal is never a delivery, and its record keeps the words a close
/// names its cause by. An archived session records `archived`, a session
/// not found `failed`, each with the CLI's words and the credit read at the
/// send; a refusal the mailbox program makes before the CLI (a session
/// whose root is another repository's) records `failed` with the program's
/// keyed line, the credit unread, no CLI call; a mailbox program that never
/// started records `failed` the same way, never an owed send left unknown;
/// a mailbox lane is refused `lane-channel` before any write, its mailbox
/// untouched.
#[test]
fn a_refused_send_records_its_result_with_the_words_and_a_mailbox_lane_is_refused() {
    let w = world();
    let archived = r#"{"ok":false,"error":"Session session_01CLOUD is archived"}"#;
    let missing = r#"{"ok":false,"error":"Session not found"}"#;
    let locked = (0.0, Some("spend_limit"));
    // item, CLI answer, planted credit, result, words, credit, CLI calls
    let rows: [(&str, &str, Credit, &str, &str, Value, usize); 3] = [
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
        w.plant_credit(credit);
        let out = w.send(item, &[("CLAUDE_CLOUD_ANSWER", answer)]);
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
    let absent = w.root.join("no-such-lane-mail");
    let out = w.send(CLOUD, &[("LANE_MAIL_CLI", absent.to_str().unwrap())]);
    let answer = result(&out);
    assert_eq!(answer["mark"], "recorded", "never started: {answer}");
    assert_eq!(answer["send"]["result"], "failed", "{answer}");
    let record = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(record["result"], "failed", "{record}");
    assert_eq!(record["credit"], "unread", "{record}");
    assert_eq!(w.cli_calls().len(), 6, "never started: no CLI call");
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

/// The mailbox-only contract: the runtime is the one writer of orch state,
/// so through the verb the program reads the fleet record as data and runs
/// no `workflow-state` at all; a bare `lane-mail send` to the same lane
/// prints the `sent` receipt on stdout and the record line on stderr and
/// leaves the fleet file byte for byte as it was.
#[test]
fn the_mailbox_program_reads_the_fleet_and_writes_none_of_it() {
    let w = world();
    let out = w.send(CLOUD, &[]);
    result(&out);
    assert!(
        w.log(&w.state_log).is_empty(),
        "the program reads the record as data: {:?}",
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

// --- the validation end notice over the session route ---

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
    install_orch_scripts(&w.root);
    let mut item: Value =
        serde_json::from_str(include_str!("fixtures/workflow-state-KEN-4687.json")).unwrap();
    item["worktree"] = json!(w.root.display().to_string());
    let path = w.root.join(format!("workflow-state-{CLOUD}.json"));
    std::fs::write(&path, serde_json::to_vec(&item).unwrap()).unwrap();
    (w, path)
}

impl World {
    fn validate(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let scripts = orch_scripts();
        let mut command = isolated();
        command
            .arg("--state-dir")
            .arg(&self.root)
            .args(args)
            .current_dir(&self.root)
            .env(
                "CHANGE_SCOPE_PATHS_CLI",
                scripts.join("../../change-scope/scripts/harness-only"),
            )
            .env("DEV_VALIDATE_CMD", "echo full")
            .env("DEV_VALIDATE_TIMEOUT_SECS", "20")
            .env("ORCH_PR_ORDER", "review-first")
            .env("ORCH_DELIVERY", "push-base")
            .env("VALIDATE_START_ANSWER", "record-only")
            .env("VALIDATE_MANAGER_DIR", self.root.join("manager"));
        self.env(&mut command, extra);
        command.env(
            "PATH",
            tool_path(&[
                &fixtures().join("validate-tools"),
                &fixtures().join("claude-cloud"),
            ]),
        );
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

/// A session the CLI answers archived for took no notice, and the stage
/// says so. The end notice to a cloud lane whose session is archived is
/// marked `unsent:session:archived`, never `sent`, the lane's
/// `directive_send` records `archived` under the notice's key, and the mark
/// is terminal: the round's next reconcile sends nothing again.
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

/// The replay's reading table, read where the send's owed write decides: a
/// notice still owed acts on what the lane's `directive_send` says of this
/// notice's own send. Settled `archived` under this key takes the terminal
/// mark with no call; owed under this key waits, the stage left owed with
/// no call; settled under another key, or no record at all, is the first
/// call's case and sends.
#[test]
fn a_replay_acts_on_what_the_lanes_send_under_its_key_settled() {
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

impl World {
    /// The mailbox program behind a wrapper that runs the second walker of
    /// the notice, the round's reconcile, while the first walker's send is
    /// in flight: the first's owed stage written, its program started and
    /// not yet reading the notice file. It keeps the fleet file as it stood
    /// before and after the second walker (`before.json`, `after.json`),
    /// the item file after it (`item.json`) and the second walker's exit
    /// status (`rc`), under `dir`, then runs the real program with the
    /// first walker's arguments.
    fn second_walker_lane_mail(&self, dir: &Path) -> PathBuf {
        std::fs::create_dir_all(dir).unwrap();
        let request = dir.join("reconcile.json");
        std::fs::write(
            &request,
            json!({"op": "reconcile-round", "round_id": ROUND}).to_string(),
        )
        .unwrap();
        let wrapper = dir.join("lane-mail-second-walker");
        write_executable(
            &wrapper,
            format!(
                "#!/bin/bash\n\
                 set -u\n\
                 d={dir}\n\
                 cp -- {fleet} \"$d/before.json\"\n\
                 LANE_MAIL_CLI={real} {bin} --no-private-env --state-dir {root} op --item {CLOUD} --request {request} >\"$d/walker.json\" 2>\"$d/walker.err\"\n\
                 printf '%s\\n' \"$?\" >\"$d/rc\"\n\
                 cp -- {fleet} \"$d/after.json\"\n\
                 cp -- {item} \"$d/item.json\"\n\
                 exec {real} \"$@\"\n",
                dir = dir.display(),
                real = self.lane_mail.display(),
                fleet = self.fleet_path().display(),
                bin = binary().display(),
                root = self.root.display(),
                request = request.display(),
                item = self
                    .root
                    .join(format!("workflow-state-{CLOUD}.json"))
                    .display(),
            ),
        );
        wrapper
    }
}

/// Two walkers of one notice, the job's own send and the round's reconcile,
/// make one send, because the read of the lane's send under the notice's
/// key is the owed write's own, inside the store's lock, and never a
/// walker's reading made before the other's settle. The reconcile meets the
/// job's send in flight (the lane owed under this key, the job's program
/// not yet reading its notice file): it holds, writes nothing (the fleet
/// file byte for byte as it was), runs no CLI, and removes only its own
/// notice file, so the job's program still reads the job's (the one CLI
/// call carries the notice's text); the stage it read is still owed. The
/// job then settles `sent` and marks, and no notice file is left. The
/// reconcile meets the settled send with a reading of the stage made before
/// the job's mark (the stage planted owed again): it takes the settled
/// result as this notice's, marks `sent`, runs no CLI and leaves the lane's
/// record as it stood. The call log holds the one `send`.
#[test]
fn two_walkers_of_one_notice_make_one_send_the_later_reading_the_earliers_inside_the_write() {
    let (w, item) = validation_world();
    let dir = w._aux.path().join("second-walker");
    let wrapper = w.second_walker_lane_mail(&dir);
    let (run_dir, ended) = w.validated(&[("LANE_MAIL_CLI", wrapper.to_str().unwrap())]);
    assert_eq!(ended["notice"], "sent", "{ended}");
    let key = w.stage(&item, &run_dir)["notice"]["key"]
        .as_str()
        .unwrap()
        .to_owned();
    // The second walker ran, met the first's send owed under this key,
    // held, and wrote nothing.
    let text = |name: &str| std::fs::read_to_string(dir.join(name)).unwrap();
    assert_eq!(text("rc").trim(), "0", "{}", text("walker.err"));
    let before: Value = serde_json::from_str(&text("before.json")).unwrap();
    let in_flight = before["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|l| l["item"] == CLOUD)
        .cloned()
        .unwrap()["directive_send"]
        .clone();
    assert_eq!(in_flight["result"], "owed", "{in_flight}");
    assert_eq!(in_flight["key"], key, "{in_flight}");
    assert_eq!(
        text("before.json"),
        text("after.json"),
        "the fleet file as it stood: nothing written by the second walker"
    );
    let during: Value = serde_json::from_str(&text("item.json")).unwrap();
    let stage = during["stages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["run_dir"] == run_dir)
        .cloned()
        .unwrap();
    assert_eq!(stage["notice"]["owner"], "owed", "held: {stage}");
    // The first walker settled and marked.
    let record = w.lane(CLOUD)["directive_send"].clone();
    assert_eq!(record["result"], "sent", "{record}");
    assert_eq!(record["key"], key, "{record}");
    assert_eq!(w.stage(&item, &run_dir)["notice"]["owner"], "sent");
    assert_eq!(w.cli_calls(), one_call_of(&w, "validation-end run="));
    let notice_files = std::fs::read_dir(w.root.join("validate"))
        .map(|d| {
            d.filter(|e| {
                e.as_ref()
                    .is_ok_and(|e| e.file_name().to_string_lossy().ends_with(".notice"))
            })
            .count()
        })
        .unwrap_or(0);
    assert_eq!(notice_files, 0, "each walker removed its own notice file");
    // The second walker again, its reading of the stage made before the
    // first's mark: the settled send is this notice's, no second call.
    w.owe_notice(&item, &run_dir);
    w.reconcile_round();
    assert_eq!(
        w.cli_calls().len(),
        3,
        "a send settled under this notice's key is read inside the write and not made again"
    );
    assert_eq!(w.stage(&item, &run_dir)["notice"]["owner"], "sent");
    assert_eq!(
        w.lane(CLOUD)["directive_send"],
        record,
        "the lane's record as the first walker left it"
    );
}

/// A checkout with a GitHub origin, the orch scripts beside it, a Claude
/// account and a brief, and a worktree package that makes and pushes the
/// item's branch, logging each call: the world a cloud launch runs in.
struct CloudWorld {
    root: PathBuf,
    account: PathBuf,
    brief: PathBuf,
    worktree: PathBuf,
    worktree_log: PathBuf,
}

fn cloud_world(dir: &Path) -> CloudWorld {
    let root = std::fs::canonicalize(dir).unwrap().join("repo");
    std::fs::create_dir_all(&root).unwrap();
    init_repo(&root);
    git(
        &root,
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/Owner/Repo.git",
        ],
    );
    std::fs::write(root.join("README.md"), "x\n").unwrap();
    git(&root, &["add", "README.md"]);
    git(
        &root,
        &["-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"],
    );
    let scripts = root.join(".agents").join("skills").join("orch");
    std::fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(orch_scripts(), scripts.join("scripts")).unwrap();
    std::os::unix::fs::symlink(
        orch_scripts().join("../../github"),
        root.join(".agents/skills/github"),
    )
    .unwrap();
    let account = root.join(".eclaude");
    std::fs::create_dir_all(&account).unwrap();
    let brief = root.join("brief.md");
    std::fs::write(&brief, "Do the thing for CC-9.\n").unwrap();
    let worktree_log = dir.join("worktree.log");
    let worktree = dir.join("worktree");
    write_executable(
        &worktree,
        format!(
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> {log}\ncase \"$1\" in\n  create) git -C {root} worktree add -q --no-checkout {root}/wt/$2 -b $2 >&2 || exit 1; printf '%s\\n' {root}/wt/$2 ;;\n  push) exit 0 ;;\n  *) exit 64 ;;\nesac\n",
            log = worktree_log.display(),
            root = root.display()
        ),
    );
    CloudWorld {
        root,
        account,
        brief,
        worktree,
        worktree_log,
    }
}

impl CloudWorld {
    /// The runtime in this world, the cloud CLI fixture first on `PATH`.
    fn command(&self, args: &[&str], env: &[(&str, &Path)]) -> std::process::Command {
        let mut command = isolated();
        command
            .args(["--state-dir", &self.root.display().to_string()])
            .args(args)
            .env("PATH", tool_path(&[&fixtures().join("claude-cloud")]))
            .env("WORKTREE_CLI", &self.worktree)
            .current_dir(&self.root);
        for (key, value) in env {
            command.env(key, value);
        }
        command
    }

    fn run(&self, args: &[&str], env: &[(&str, &Path)]) -> std::process::Output {
        self.command(args, env).output().unwrap()
    }

    /// `launch-lane` for `item` on the cloud.
    fn launch(&self, item: &str, env: &[(&str, &Path)]) -> std::process::Output {
        self.run(
            &["op", "--fleet", "--request", &self.launch_request(item)],
            env,
        )
    }

    /// The `launch-lane` request file for `item` on the cloud.
    fn launch_request(&self, item: &str) -> String {
        let request = self.root.join(format!("request-{item}.json"));
        std::fs::write(
            &request,
            json!({
                "op": "launch-lane",
                "item": item,
                "harness": "claude",
                "mail_root": self.root.display().to_string(),
                "account": self.account.display().to_string(),
                "host": "claude-cloud",
                "model": "opus",
                "effort": "high",
                "brief_file": self.brief.display().to_string(),
            })
            .to_string(),
        )
        .unwrap();
        request.display().to_string()
    }

    /// A person's terminal close of `item`.
    fn close(&self, item: &str) -> std::process::Output {
        let request = self.root.join(format!("close-{item}.json"));
        std::fs::write(
            &request,
            json!({
                "op": "close-owned-resources",
                "item": item,
                "terminal": {"verdict": "canceled", "source": "claude.ai/code read by a person"},
            })
            .to_string(),
        )
        .unwrap();
        self.run(
            &["op", "--fleet", "--request", &request.display().to_string()],
            &[],
        )
    }

    fn fleet(&self) -> Value {
        serde_json::from_str(
            &std::fs::read_to_string(self.root.join("workflow-state-oversee.json")).unwrap(),
        )
        .unwrap()
    }

    fn lane(&self, item: &str) -> Value {
        self.fleet()["lanes"]
            .as_array()
            .and_then(|lanes| lanes.iter().find(|l| l["item"] == item))
            .cloned()
            .unwrap_or(Value::Null)
    }

    fn intent(&self, item: &str) -> Value {
        self.fleet()["intents"]
            .as_array()
            .and_then(|intents| {
                intents
                    .iter()
                    .rev()
                    .find(|i| i["target"] == item && i["op"] == "launch-session")
            })
            .cloned()
            .unwrap_or(Value::Null)
    }
}

#[test]
fn a_cloud_launch_pushes_the_branch_creates_the_session_through_the_cli_and_records_it() {
    let dir = tempfile::tempdir().unwrap();
    let world = cloud_world(dir.path());
    let CloudWorld {
        root,
        account,
        brief,
        worktree,
        worktree_log,
    } = &world;
    let claude_log = dir.path().join("claude.log");
    let parent_log = dir.path().join("parent.log");
    let request = root.join("request.json");
    std::fs::write(
        &request,
        json!({
            "op": "launch-lane",
            "item": "CC-9",
            "harness": "claude",
            "mail_root": root.display().to_string(),
            "account": account.display().to_string(),
            "host": "claude-cloud",
            "repo": "o/r",
            "model": "opus",
            "effort": "high",
            "brief_file": brief.display().to_string(),
        })
        .to_string(),
    )
    .unwrap();
    let mut command = isolated();
    command
        .args(["--state-dir", &root.display().to_string()])
        .args(["state", "init", "--fleet"])
        .current_dir(root);
    let out = command.output().unwrap();
    assert!(out.status.success(), "init: {}", stderr(&out));
    let mut command = isolated();
    command
        .args(["--state-dir", &root.display().to_string()])
        .args(["op", "--fleet", "--request", &request.display().to_string()])
        .env("PATH", tool_path(&[&fixtures().join("claude-cloud")]))
        .env("CLAUDE_CLOUD_LOG", &claude_log)
        .env("CLAUDE_CLOUD_PARENT_LOG", &parent_log)
        .env("WORKTREE_CLI", worktree)
        // The overseer's own session marker, which the create must not
        // hand the CLI: the builder's removals reach the child.
        .env("CLAUDECODE", "parent-fixture")
        .current_dir(root);
    let report = effect_report(&command.output().unwrap());
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let lane = &report["lane"];
    assert_eq!(lane["status"], "running", "{lane}");
    assert_eq!(lane["host"], "claude-cloud");
    assert_eq!(lane["kind"], "claude-cloud");
    assert_eq!(lane["session_id"], "session_01CLOUD");
    assert_eq!(lane["window"], Value::Null, "a cloud session has no window");
    assert_eq!(
        lane["mail_root"],
        root.join("wt").join("CC-9").display().to_string(),
        "the worktree the launch made is the lane's root"
    );
    let observation = &report["intent"]["observation"];
    assert_eq!(
        observation["cloud_repo_access"]["url"],
        "https://claude.ai/code/session_01CLOUD"
    );
    assert_eq!(
        observation["cloud_repo_access"]["repositories"],
        json!(["o/r", "owner/repo"]),
        "the origin and the item's repository, as GitHub reads names"
    );
    let calls: Vec<String> = std::fs::read_to_string(worktree_log)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    assert_eq!(
        calls,
        vec![
            "create CC-9 --no-checkout".to_owned(),
            "push CC-9 --set-upstream".to_owned()
        ],
        "the branch is pushed before the session clones it"
    );
    let cli = std::fs::read_to_string(&claude_log).unwrap();
    // The fixture logs the argv whole, the description's own lines inside.
    let argv = cli
        .split_once("argv=")
        .and_then(|(_, rest)| rest.split("\nconfig=").next())
        .expect("the CLI ran");
    assert!(
        argv.starts_with(
            "--model opus --effort high --cloud --output-format json -p Do the thing for CC-9.\n\n"
        ),
        "the description is the brief closed by the session words: {argv:?}"
    );
    assert!(
        argv.contains("cloned the item branch CC-9:") && !argv.contains("{branch}"),
        "the session words name the branch: {argv:?}"
    );
    assert!(
        !["approval-wait", "queue-wait", "ci-wait"]
            .iter()
            .any(|waiter| argv.contains(waiter)),
        "the session words run no waiter: {argv:?}"
    );
    assert!(
        cli.contains(&format!("config={}", account.display())),
        "the session is created under the lane's account: {cli}"
    );
    assert_eq!(
        std::fs::read_to_string(&parent_log).unwrap(),
        "parent-marker=\n",
        "the builder's environment removals reach the CLI"
    );
    // A create whose answer is lost may have made a session nothing here can
    // name: the launch stays open with the lane preparing, never failed, and
    // a reconcile keeps it so; a close is the person's settlement.
    let lost = world.launch(
        "CC-10",
        &[
            ("CLAUDE_CLOUD_LOG", claude_log.as_path()),
            ("CLAUDE_CLOUD_ANSWER", Path::new("not an answer")),
        ],
    );
    let report = effect_report(&lost);
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"], "cloud-create-unknown",
        "{report}"
    );
    assert_eq!(world.lane("CC-10")["status"], "preparing");
    let answer = reply(&world.run(&["reconcile", "--fleet"], &[]));
    let reconciled = &answer["result"]["reconciled"][0]["report"]["intent"];
    assert_eq!(reconciled["outcome"], "unconfirmed", "{answer}");
    assert_eq!(
        reconciled["observation"]["note"], "cloud-create-unknown",
        "{answer}"
    );
    let closed = world.close("CC-10");
    assert!(
        closed.status.success(),
        "the close settles the held create: {}",
        stderr(&closed)
    );
    let launch = world.intent("CC-10");
    assert_eq!(launch["outcome"], "failed", "{launch}");
    assert_eq!(
        launch["observation"]["cloud_create"],
        root.join("wt").join("CC-10").display().to_string(),
        "{launch}"
    );
    assert_ne!(world.lane("CC-10")["status"], "preparing");
}

/// A cloud session clones its branch from the checkout's GitHub origin: a
/// checkout whose origin names no GitHub repository fails the launch
/// `cloud-bundle-risk cause=remote` before any worktree is made.
#[test]
fn a_cloud_launch_from_a_checkout_whose_origin_is_off_github_makes_no_worktree() {
    let dir = tempfile::tempdir().unwrap();
    let world = cloud_world(dir.path());
    git(
        &world.root,
        &[
            "remote",
            "set-url",
            "origin",
            "https://gitlab.example/group/github.com/Owner/Repo.git",
        ],
    );
    let init = world.run(&["state", "init", "--fleet"], &[]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let report = effect_report(&world.launch("CC-12", &[]));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["cause"], "cloud-bundle-risk cause=remote",
        "{report}"
    );
    assert!(
        !world.worktree_log.exists(),
        "no worktree is made for a session that could clone nothing"
    );
}

/// A cloud session arms git hooks only where the claim root's committed
/// policy runs the `git-hooks` stage, read before anything is made: unset
/// names the installer in the description, a policy without the stage
/// names none, whatever is installed, and a policy outside its form fails
/// the launch by its key before a worktree or a session exists.
#[test]
fn a_cloud_launch_arms_git_hooks_only_where_the_claim_roots_policy_runs_them() {
    let dir = tempfile::tempdir().unwrap();
    let world = cloud_world(dir.path());
    let init = world.run(&["state", "init", "--fleet"], &[]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let settings = world.root.join("kendex.settings.toml");
    for (item, policy, arms) in [
        ("CC-20", None, true),
        ("CC-21", Some("preflight doc-limits"), false),
    ] {
        if let Some(policy) = policy {
            std::fs::write(&settings, format!("[env]\nORCH_STAGES = \"{policy}\"\n")).unwrap();
        }
        let log = dir.path().join(format!("claude-{item}.log"));
        let report = effect_report(&world.launch(item, &[("CLAUDE_CLOUD_LOG", log.as_path())]));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{item} {report}");
        let cli = std::fs::read_to_string(&log).unwrap();
        assert_eq!(
            cli.contains("install-git-hooks"),
            arms,
            "{item}: the description arms hooks only under the policy: {cli}"
        );
    }
    std::fs::write(&settings, "[env]\nORCH_STAGES = \"git-hook\"\n").unwrap();
    let log = dir.path().join("claude-CC-22.log");
    let report = effect_report(&world.launch("CC-22", &[("CLAUDE_CLOUD_LOG", log.as_path())]));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["cause"], "setting-invalid", "{report}");
    assert_eq!(observation["key"], "ORCH_STAGES", "{report}");
    assert!(!log.exists(), "no session was asked for");
    let calls = std::fs::read_to_string(&world.worktree_log).unwrap();
    assert!(!calls.contains("CC-22"), "no worktree was made: {calls}");
}

#[test]
fn a_cloud_create_whose_asking_process_ends_is_held_and_never_asked_again() {
    let dir = tempfile::tempdir().unwrap();
    let world = cloud_world(dir.path());
    let claude_log = dir.path().join("claude.log");
    let init = world.run(&["state", "init", "--fleet"], &[]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    // The CLI ends the `op` that asked it, as a caller's own end does
    // mid-create: nothing answers, whatever the cloud made.
    let killed = world.launch(
        "CC-11",
        &[
            ("CLAUDE_CLOUD_LOG", claude_log.as_path()),
            ("CLAUDE_CLOUD_KILL", Path::new("parent")),
        ],
    );
    assert!(!killed.status.success(), "the asking op ended");
    let answer = reply(&world.run(&["reconcile", "--fleet"], &[]));
    let reconciled = &answer["result"]["reconciled"][0]["report"]["intent"];
    assert_eq!(reconciled["outcome"], "unconfirmed", "{answer}");
    assert_eq!(
        reconciled["observation"]["note"], "cloud-create-unknown",
        "{answer}"
    );
    assert_eq!(world.lane("CC-11")["status"], "preparing");
    let again = world.launch("CC-11", &[("CLAUDE_CLOUD_LOG", claude_log.as_path())]);
    let report = reply(&again);
    assert_eq!(world.intent("CC-11")["outcome"], "unconfirmed", "{report}");
    let creates = std::fs::read_to_string(&claude_log)
        .unwrap()
        .matches("argv=")
        .count();
    assert_eq!(creates, 1, "no second create beside the one that may stand");
}

/// A cloud launch's `op` may still be inside the create, whose session
/// would then be recorded nowhere. While the asking `op` runs, the close
/// refuses `intent-open` and the launch stays open; once that `op` has
/// ended, the CLI still inside the create, the close supersedes the held
/// launch, naming its worktree and the time the create's bound ends, so a
/// person reads claude.ai/code only once no session can still appear.
#[test]
fn a_close_beside_a_live_cloud_create_is_refused_and_supersedes_it_once_its_op_is_gone() {
    let dir = tempfile::tempdir().unwrap();
    let world = cloud_world(dir.path());
    let claude_log = dir.path().join("claude.log");
    let hold = dir.path().join("hold.fifo");
    let made = program("mkfifo").arg(&hold).output().unwrap();
    assert!(made.status.success(), "{}", stderr(&made));
    let init = world.run(&["state", "init", "--fleet"], &[]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let wall = || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
    };
    let before = wall();
    // Held so a row that fails before its end still ends the `op`.
    let mut asking = Owned(
        world
            .command(
                &["op", "--fleet", "--request", &world.launch_request("CC-20")],
                &[
                    ("CLAUDE_CLOUD_LOG", claude_log.as_path()),
                    ("CLAUDE_CLOUD_HOLD", hold.as_path()),
                ],
            )
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap(),
    );
    // The CLI's log line is its acknowledgement that the create was asked.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !std::fs::read_to_string(&claude_log).is_ok_and(|log| log.contains("argv=")) {
        assert!(
            std::time::Instant::now() < deadline,
            "the create was never asked"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let asked = wall();
    let refused = world.close("CC-20");
    assert!(!refused.status.success(), "{}", stderr(&refused));
    assert_eq!(
        reply(&refused)["refusal"]["key"],
        "intent-open",
        "{}",
        stderr(&refused)
    );
    let open = world.intent("CC-20");
    assert!(
        matches!(
            open["outcome"].as_str(),
            Some("not-started" | "unconfirmed")
        ),
        "the launch stays open: {open}"
    );
    assert_eq!(world.lane("CC-20")["status"], "preparing");
    // The asking `op` ends inside the create, and the close comes while the
    // CLI still holds it.
    asking.0.kill().unwrap();
    asking.0.wait().unwrap();
    let closed = world.close("CC-20");
    // Read and write, so the open never waits for a reader the CLI's own
    // bound may already have ended.
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&hold)
        .and_then(|mut fifo| std::io::Write::write_all(&mut fifo, b"\n"))
        .unwrap();
    assert!(closed.status.success(), "{}", stderr(&closed));
    let launch = world.intent("CC-20");
    assert_eq!(launch["outcome"], "failed", "{launch}");
    assert_eq!(
        launch["observation"]["cloud_create"],
        world.root.join("wt").join("CC-20").display().to_string(),
        "{launch}"
    );
    // The create's bound, from the phase recorded before the CLI was asked.
    let answer_by = launch["observation"]["answer_by"].as_str().unwrap_or("");
    let bound = 600;
    assert!(
        agent_runtime::clock::iso_utc(before + bound).as_str() <= answer_by
            && answer_by <= agent_runtime::clock::iso_utc(asked + bound).as_str(),
        "the close names when the create's bound ends: {launch}"
    );
    assert_ne!(world.lane("CC-20")["status"], "preparing");
}

/// A record naming the cloud host for a window on this machine would charge
/// the cloud cap and be passed over by the watch's pane reads. Through the
/// real `launch-lane`: a cloud launch records the cloud host and kind; with
/// its session ended by the real no-landing close (the record stopped), a
/// relaunch naming no host records no host and the `local` kind, and its
/// launch is the local one. The cloud session stays named in the fleet log
/// once: by the close's row, or, over a released record whose close row was
/// never written, by the relaunch's.
#[test]
fn a_cloud_lanes_relaunch_naming_no_host_records_the_local_launch_it_makes() {
    let dir = tempfile::tempdir().unwrap();
    let world = cloud_world(dir.path());
    let claude_log = dir.path().join("claude.log");
    let init = world.run(&["state", "init", "--fleet"], &[]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let out = world.launch("CC-30", &[("CLAUDE_CLOUD_LOG", claude_log.as_path())]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let lane = world.lane("CC-30");
    assert_eq!(
        (&lane["host"], &lane["kind"]),
        (&json!("claude-cloud"), &json!("claude-cloud")),
        "{lane}"
    );
    // The session ended through the real no-landing close, the record
    // stopped as the landing lane's predecessor leaves it.
    let close = world.root.join("close-CC-30.json");
    std::fs::write(
        &close,
        json!({
            "op": "close-owned-resources",
            "item": "CC-30",
            "no_landing": {"reason": "landing-lane", "source": "overseer"},
        })
        .to_string(),
    )
    .unwrap();
    let out = world.run(
        &["op", "--fleet", "--request", &close.display().to_string()],
        &[("CLAUDE_CLOUD_LOG", claude_log.as_path())],
    );
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert_eq!(
        world.lane("CC-30")["status"],
        "stopped",
        "{}",
        world.lane("CC-30")
    );
    let request = world.root.join("relaunch.json");
    std::fs::write(
        &request,
        json!({
            "op": "launch-lane",
            "item": "CC-30",
            "harness": "claude",
            "mail_root": world.root.display().to_string(),
            "account": world.account.display().to_string(),
            "model": "opus",
            "effort": "high",
        })
        .to_string(),
    )
    .unwrap();
    let out = world.run(
        &["op", "--fleet", "--request", &request.display().to_string()],
        &[],
    );
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let lane = world.lane("CC-30");
    assert_eq!(
        (&lane["host"], &lane["kind"]),
        (&Value::Null, &json!("local")),
        "the relaunch records where it launched: {lane}"
    );
    // The launch it made is the local one: it needs the fleet's tmux
    // session, which this world runs none of, where a cloud create needs
    // none.
    assert_eq!(
        answer["result"]["effect"]["report"]["intent"]["observation"]["cause"],
        "tmux-session-unresolved",
        "{answer}"
    );
    let cloud_rows = |item: &str| -> Vec<Value> {
        world.fleet()["fleet_log"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|row| row["kind"] == "close" && row["item"] == item)
            .filter(|row| {
                row["text"]
                    .as_str()
                    .is_some_and(|text| text.starts_with("cloud lane closed;"))
            })
            .cloned()
            .collect()
    };
    assert_eq!(
        cloud_rows("CC-30").len(),
        1,
        "the close named the session, so the relaunch names it again nowhere: {}",
        world.fleet()["fleet_log"]
    );
    // A cloud record as the released launcher wrote it, its close row never
    // written (the released close stamped `done` before appending it): the
    // relaunch over it names the session before the record's fields move.
    let account = world.account.display().to_string();
    let mut fleet = world.fleet();
    fleet["lanes"].as_array_mut().unwrap().push(json!({
        "item": "CC-31", "tracker": null, "repo": null, "harness": "claude",
        "window": null, "account": account, "host": "claude-cloud",
        "kind": "claude-cloud", "mail_root": world.root.join("wt/CC-31").display().to_string(),
        "surface": "tmux", "model": "opus", "effort": "high", "session_id": "session_031",
        "session_since": "2026-11-01T10:00:00Z", "launched_at": "2026-11-01T10:00:00Z",
        "running_at": "2026-11-01T10:00:05Z", "status": "done", "over_cap": null,
        "allow_all": null, "touched": null, "in_scope": [], "obligation": null,
        "recovery": {"cwd": world.root.display().to_string(), "flags": "", "session": "", "refresh": false},
        "launch": null,
    }));
    std::fs::write(
        world.root.join("workflow-state-oversee.json"),
        serde_json::to_string(&fleet).unwrap(),
    )
    .unwrap();
    let mut relaunch: Value =
        serde_json::from_str(&std::fs::read_to_string(&request).unwrap()).unwrap();
    relaunch["item"] = json!("CC-31");
    std::fs::write(&request, relaunch.to_string()).unwrap();
    let out = world.run(
        &["op", "--fleet", "--request", &request.display().to_string()],
        &[],
    );
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let rows = cloud_rows("CC-31");
    assert_eq!(rows.len(), 1, "{}", world.fleet()["fleet_log"]);
    assert_eq!(
        rows[0]["text"],
        format!("cloud lane closed; session=session_031 account={account}"),
        "{}",
        rows[0]
    );
    assert_eq!(world.lane("CC-31")["kind"], "local");
}
