//! The item transitions: rounds, validation admission, accepted results with
//! their outcome and end, a round's admitted runs reconciled against the host,
//! the verification record and the handoff record. Each row applies the
//! library's operations to the item fixture beside this file, in the shape the
//! `workflow-state` script writes, under an injected clock; the last rows run
//! the built binary so the wire names of the new fields are the ones a workflow
//! writes.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and wait on real time for them"
)]

use agent_runtime::record::{Document, Locking};
use std::fs::{self, File};
use std::path::{Path, PathBuf};
mod support;

use std::process::{Child, Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::journal::Env;
use orch_runtime::error::Error;
use orch_runtime::ops::{
    AcceptResult, Applied, Attempt, BeginRound, EndSource, OpenRun, ReconcileRound, RecordHandoff,
    RecordValidationAdmission, RecordVerification, Relaunch, Report, Request, ResumeHandoff,
    RoundKind, RunCause, RunState, apply,
};
use orch_runtime::state::{ItemState, Record, Stage, StageKind, StageOutcome};
use serde_json::{Value, json};

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
/// The fixture's open dev round and its start.
const ROUND: &str = "1769600000123456789-1837";
const ROUND_START: u64 = 1_769_600_000;
const NOW_SECS: u64 = 1_769_700_000;
const NOW_NANOS: u128 = 1_769_700_000_123_456_789;
const BASE_NONCE: u32 = 4242;
const LOCK: Locking = Locking::FLOCK;
/// The fixture's recorded worktree.
const WORKTREE: &str = "/home/u/dev/.worktrees/kendex/ken-4687";

/// The base stamp a row mints with: `2026-01-29T15:20:00Z`, nonce 4242.
fn env() -> Env {
    Env {
        now_secs: NOW_SECS,
        now_nanos: NOW_NANOS,
        nonce: BASE_NONCE,
        owner: None,
    }
}

fn at(now_secs: u64) -> Env {
    Env { now_secs, ..env() }
}

/// The nonces `run` mints: one per call, as one process mints one `Env`
/// per request, so two calls never replay a stamp.
static NONCES: AtomicU32 = AtomicU32::new(BASE_NONCE + 1);

/// Apply `request` as one call of the runtime at `now_secs`, with a fresh
/// nonce.
fn run_at(path: &Path, request: &Request, now_secs: u64) -> Result<Applied, Error> {
    let env = Env {
        nonce: NONCES.fetch_add(1, Ordering::Relaxed),
        ..at(now_secs)
    };
    apply(path, request, &env, LOCK)
}

fn run(path: &Path, request: &Request) -> Result<Applied, Error> {
    run_at(path, request, NOW_SECS)
}

fn item_file(dir: &Path) -> PathBuf {
    let path = dir.join("workflow-state-KEN-4687.json");
    fs::write(&path, ITEM).unwrap();
    path
}

fn object(path: &Path) -> Document {
    match serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap() {
        Value::Object(map) => map,
        other => panic!("not an object: {other}"),
    }
}

fn item(path: &Path) -> ItemState {
    ItemState::view(path, &object(path)).unwrap()
}

fn keys(doc: &Document) -> Vec<String> {
    doc.keys().cloned().collect()
}

fn begin(kind: RoundKind) -> Request {
    Request::BeginRound(BeginRound {
        kind,
        body_revision: None,
    })
}

fn admit(round: &str, run_dir: Option<&str>) -> Request {
    Request::RecordValidationAdmission(RecordValidationAdmission {
        round_id: round.into(),
        run_dir: run_dir.map(str::to_owned),
        attempt: Attempt::Current,
    })
}

fn admit_next(round: &str) -> Request {
    Request::RecordValidationAdmission(RecordValidationAdmission {
        round_id: round.into(),
        run_dir: None,
        attempt: Attempt::Next,
    })
}

fn admitted(applied: Applied) -> orch_runtime::ops::ValidationAdmitted {
    let Report::RecordValidationAdmission(a) = applied.report else {
        panic!("{:?}", applied.report)
    };
    a
}

fn accept(
    round: &str,
    run_dir: Option<&str>,
    outcome: StageOutcome,
    end: Option<&Path>,
) -> Request {
    Request::AcceptResult(AcceptResult {
        round_id: round.into(),
        run_dir: run_dir.map(str::to_owned),
        outcome,
        end: end.map(|from_artifact| EndSource {
            from_artifact: from_artifact.to_path_buf(),
        }),
        authorization: None,
        summary_file: None,
        attachments: Vec::new(),
        summary_comment: None,
    })
}

/// A file whose modification time is `mtime` epoch seconds: the artifact an
/// acceptance rests on.
fn artifact(dir: &Path, name: &str, mtime: u64) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, "{}").unwrap();
    File::open(&path)
        .unwrap()
        .set_modified(UNIX_EPOCH + Duration::from_secs(mtime))
        .unwrap();
    path
}

fn handoff_with(
    round: Option<&str>,
    relaunch: Option<Relaunch>,
    written_at: Option<&str>,
    remaining: &str,
    supersede: bool,
) -> Request {
    Request::RecordHandoff(Box::new(RecordHandoff {
        supersede,
        round_id: round.map(str::to_owned),
        merged: vec!["#2714".into()],
        remaining: vec![remaining.into()],
        branch: Some("rebuild/orch-architecture".into()),
        worktree: Some(WORKTREE.into()),
        open_pr: Value::Null,
        traps: vec!["the guard chain refuses the branch under main's scripts".into()],
        context: json!({"decision": "handoff", "source": "native"}),
        relaunch,
        session_id: None,
        pane_key: None,
        cause: None,
        model: None,
        written_at: written_at.map(str::to_owned),
    }))
}

fn handoff(round: Option<&str>, relaunch: Option<Relaunch>, written_at: Option<&str>) -> Request {
    handoff_with(round, relaunch, written_at, "merge-pr § 5 step 3", false)
}

fn resume() -> Request {
    Request::ResumeHandoff(ResumeHandoff {})
}

fn reconcile(round: &str) -> Request {
    Request::ReconcileRound(ReconcileRound {
        round_id: round.into(),
    })
}

fn validate_stages(path: &Path) -> Vec<Stage> {
    item(path)
        .stages
        .into_iter()
        .filter(|s| s.kind == StageKind::Validate)
        .collect()
}

mod dev_artifacts {
    use super::*;
    use agent_runtime::settings::Roots;
    use orch_runtime::ops::artifact::{self as receipt, CheckReturn};
    use orch_runtime::settings::{self, Flags};
    use std::sync::Arc;
    use std::time::SystemTime;
    use support::{fixtures, program, stderr};

    struct World {
        _dir: tempfile::TempDir,
        root: PathBuf,
        wt: PathBuf,
        state: PathBuf,
    }

    fn git(wt: &Path, args: &[&str]) -> String {
        let out = program("git")
            .arg("-C")
            .arg(wt)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
        String::from_utf8(out.stdout).unwrap().trim_end().to_owned()
    }

    fn scripts() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../scripts")
            .canonicalize()
            .unwrap()
    }

    impl World {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().canonicalize().unwrap();
            let wt = root.join("wt");
            let state = root.join("state");
            fs::create_dir_all(wt.join("tmp")).unwrap();
            fs::create_dir(&state).unwrap();
            git(&wt, &["init", "-q", "-b", "main"]);
            git(&wt, &["config", "gc.auto", "0"]);
            git(&wt, &["config", "maintenance.auto", "false"]);
            fs::write(wt.join(".gitignore"), "tmp/\n.cache/\n").unwrap();
            fs::write(wt.join("app.txt"), "base\n").unwrap();
            git(&wt, &["add", ".gitignore", "app.txt"]);
            git(&wt, &["commit", "-qm", "base"]);
            git(&wt, &["switch", "-qc", "work"]);
            support::install_orch_scripts(&wt);
            let w = Self {
                _dir: dir,
                root,
                wt,
                state,
            };
            fs::write(w.item(), json!({"worktree":w.wt,"branch":"work","dev_round_id":"r1","stages":[{"kind":"dev","round_id":"r1","start":1,"end":null}]}).to_string()).unwrap();
            w
        }
        fn item(&self) -> PathBuf {
            self.state.join("workflow-state-issue-8.json")
        }
        fn doc(&self) -> Value {
            serde_json::from_str(&fs::read_to_string(self.item()).unwrap()).unwrap()
        }
        fn head(&self) -> String {
            git(&self.wt, &["rev-parse", "HEAD"])
        }
        fn tree(&self) -> String {
            git(&self.wt, &["rev-parse", "HEAD^{tree}"])
        }
        fn command(&self) -> Command {
            let mut command = support::isolated();
            command
                .arg("--state-dir")
                .arg(&self.state)
                .current_dir(&self.wt)
                .env(
                    "DEV_VALIDATE_CMD",
                    "printf 'validate: lanes=unit selection=battery\\n'",
                )
                .env("DEV_VALIDATE_TIMEOUT_SECS", "20")
                .env("ORCH_PR_ORDER", "review-first")
                .env("WORKTREE_DEFAULT_BRANCH", "main")
                .env(
                    "CHANGE_SCOPE_PATHS_CLI",
                    scripts().join("../../change-scope/scripts/harness-only"),
                );
            command
        }
        fn run(&self, args: &[&str]) -> Output {
            self.command().args(args).output().unwrap()
        }
        fn identity(&self, round: &str) -> Vec<String> {
            vec![
                "--worktree".into(),
                self.wt.display().to_string(),
                "--issue".into(),
                "issue-8".into(),
                "--round-id".into(),
                round.into(),
            ]
        }
        fn call(&self, verb: &[&str], round: &str, args: &[&str]) -> Output {
            self.command()
                .args(verb)
                .args(self.identity(round))
                .args(args)
                .output()
                .unwrap()
        }
        fn stamp(&self, round: &str) -> Value {
            result(&self.call(
                &["round", "stamp"],
                round,
                &["--item", "1", "repair parser", "app.txt CLI input"],
            ))
        }
        fn round_path(&self, round: &str) -> PathBuf {
            self.wt.join(format!("tmp/dev-round-issue-8-{round}.json"))
        }
        fn receipt_path(&self, round: &str) -> PathBuf {
            self.wt.join(format!("tmp/dev-return-issue-8-{round}.json"))
        }
        fn check(&self, round: &str) -> Value {
            result(&self.call(
                &["dev-return", "check"],
                round,
                &["--expect-items-from-round"],
            ))
        }
        fn write(&self, round: &str, kind: &str, validate: &str, extra: &[&str]) -> Output {
            let head = self.head();
            let mut args = vec![
                "--kind",
                kind,
                "--branch",
                "work",
                "--commit",
                &head,
                "--validate",
                validate,
            ];
            args.extend_from_slice(extra);
            self.call(&["dev-return", "write"], round, &args)
        }
        fn commit(&self, path: &str) {
            let file = self.wt.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, "change\n").unwrap();
            git(&self.wt, &["add", path]);
            git(&self.wt, &["commit", "-qm", "change"]);
        }
        fn released_receipt(&self, round: &str, kind: &str) -> Value {
            let mut v = json!({"schema_version":1,"round_id":round,"kind":kind,"issue":"issue-8","branch":"work","commit":self.head(),"validate":"FAILING: lint","validate_mode":null,"validate_time":null,"validate_note":null,"qa_labels":[],"summary_posted":false,"summary":null,"bundled":false,"items":[{"n":1,"decision":"Applied","reasoning":"parser input reaches this branch"}]});
            if kind == "implement" {
                v["baseline_lines"] = json!(1);
            }
            v
        }
        fn plant_receipt(&self, round: &str, v: &Value) {
            fs::write(self.receipt_path(round), v.to_string()).unwrap();
        }
        fn released_run(&self, name: &str, mode: &str) -> PathBuf {
            let dir = self.wt.join(format!("tmp/dev-validate-{name}"));
            fs::create_dir(&dir).unwrap();
            fs::write(
                dir.join("start"),
                format!(
                    "start=1\nvalidate-mode={mode}\nhead={}\nvalidate-base={}\n",
                    self.head(),
                    self.head()
                ),
            )
            .unwrap();
            fs::write(
                dir.join("cmd"),
                "printf 'validate: lanes=unit selection=battery\\n'",
            )
            .unwrap();
            fs::write(dir.join("paths"), "app.txt\n").unwrap();
            fs::write(dir.join("log"), "validate: lanes=unit selection=battery\n").unwrap();
            fs::write(
                dir.join("timing"),
                "started-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:00:01Z\nseconds=1\n",
            )
            .unwrap();
            fs::write(dir.join("exit"), "guard-exit=0 at=2026-01-01T00:00:01Z\n").unwrap();
            dir
        }
        fn record_start(&self, run: &Path, line: &str) {
            let start = run.join("start");
            let text = fs::read_to_string(&start).unwrap();
            fs::write(start, format!("{text}{line}\n")).unwrap();
        }
        fn transcript(&self, round: &str, report: &str, channel: &str) -> PathBuf {
            let mut lines =
                vec![json!({"message":{"role":"user","content":format!("Round ID: {round}")}})];
            lines.push(match channel {
                "codex" => json!({"payload":{"type":"function_call","name":"send_input","arguments":json!({"message":report}).to_string()}}),
                "pi" => json!({"message":{"role":"assistant","content":[{"type":"text","text":report}]}}),
                _ => json!({"message":{"role":"assistant","content":[{"type":"tool_use","name":"SendMessage","input":{"message":report}},{"type":"text","text":"Reported."}]}}),
            });
            let path = self.root.join("transcript.jsonl");
            fs::write(
                &path,
                lines
                    .iter()
                    .map(Value::to_string)
                    .collect::<Vec<_>>()
                    .join("\n"),
            )
            .unwrap();
            path
        }
    }

    struct Validation<'a>(&'a World, String);
    impl Drop for Validation<'_> {
        fn drop(&mut self) {
            let _ = self
                .0
                .command()
                .args([
                    "validate",
                    "stop",
                    "--item",
                    "issue-8",
                    "--run-dir",
                    &self.1,
                ])
                .output();
        }
    }

    fn result(out: &Output) -> Value {
        let v: Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!(
                "{e}: {} {}",
                String::from_utf8_lossy(&out.stdout),
                stderr(out)
            )
        });
        assert!(v["ok"] == true, "{v} {}", stderr(out));
        v["result"].clone()
    }
    fn refused(out: &Output, key: &str) {
        let v: Value =
            serde_json::from_slice(&out.stdout).unwrap_or_else(|e| panic!("{e}: {}", stderr(out)));
        assert_eq!(v["refusal"]["key"], key, "{v} {}", stderr(out));
        assert!(!out.status.success());
    }

    #[test]
    fn same_second_round_receipts_require_the_internal_token() {
        let w = World::new();
        w.stamp("r1");
        w.stamp("r2");
        for round in ["r1", "r2"] {
            File::open(w.round_path(round))
                .unwrap()
                .set_modified(UNIX_EPOCH + Duration::from_secs(100))
                .unwrap();
        }
        for (want, internal) in [
            ("r2", "r1"),
            ("group-b", "group-a"),
            ("ci-fix", "review"),
            ("replacement", "late-old"),
        ] {
            w.stamp(want);
            w.plant_receipt(want, &w.released_receipt(internal, "fix"));
            assert_eq!(w.check(want)["reason"], "invalid", "{want}/{internal}");
        }
        let mut other_issue = w.released_receipt("r1", "fix");
        other_issue["issue"] = json!("issue-9");
        w.plant_receipt("r1", &other_issue);
        assert_eq!(w.check("r1")["reason"], "invalid");
        w.plant_receipt("r1", &w.released_receipt("r1", "fix"));
        assert_eq!(w.check("r1")["reason"], "valid");
    }

    #[test]
    fn round_stamp_is_immutable_and_retries_keep_the_original_delegation() {
        let w = World::new();
        let before = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let a = w.stamp("r1");
        let path = PathBuf::from(a["path"].as_str().unwrap());
        let first = fs::read(&path).unwrap();
        let stamped: Value = serde_json::from_slice(&first).unwrap();
        assert!(stamped["delegated_at"].as_u64().unwrap() >= before);
        assert_eq!(w.stamp("r1")["path"], a["path"]);
        assert_eq!(fs::read(&path).unwrap(), first);
        // A retry of the same content keeps the delegation already recorded.
        let mut earlier = stamped.clone();
        earlier["delegated_at"] = json!(5);
        fs::write(&path, earlier.to_string()).unwrap();
        w.stamp("r1");
        let kept: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(kept["delegated_at"], 5);
        std::os::unix::fs::symlink(w.root.join("absent"), w.round_path("link")).unwrap();
        refused(
            &w.call(
                &["round", "stamp"],
                "link",
                &["--item", "1", "x", "app CLI"],
            ),
            "record-symlink",
        );
        let items = w.root.join("items.json");
        fs::write(
            &items,
            json!([{"n":1,"text":"from file","reach":"app CLI","extra":true}]).to_string(),
        )
        .unwrap();
        let findings = w.root.join("findings.json");
        let occurrences = json!({"prior":"none","classes":["lint"]});
        fs::write(&findings, occurrences.to_string()).unwrap();
        let out = w.call(
            &["round", "stamp"],
            "file",
            &[
                "--items-file",
                items.to_str().unwrap(),
                "--finding-occurrences-file",
                findings.to_str().unwrap(),
            ],
        );
        let v: Value = serde_json::from_str(
            &fs::read_to_string(result(&out)["path"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(
            v["items"],
            json!([{"n":1,"text":"from file","reach":"app CLI"}])
        );
        assert_eq!(v["finding_occurrences"], occurrences);
        let bad_findings = w.root.join("bad-findings.json");
        fs::write(
            &bad_findings,
            json!({"prior":"many","classes":[]}).to_string(),
        )
        .unwrap();
        refused(
            &w.call(
                &["round", "stamp"],
                "r1",
                &["--item", "1", "another set", "app CLI"],
            ),
            "record-conflict",
        );
        for extra in [
            vec!["--item", "1", "x", "prrt_123"],
            vec!["--item", "1", "x", "the finding"],
            vec!["--item", "1", "x", "Copilot thread"],
            vec!["--item", "1", "x", " "],
            vec!["--item", "1", "x", "CLI", "--adds", "../outside"],
            vec!["--item", "1", "x", "CLI", "--adds", "tools/a tools/a"],
            vec!["--item", "1", "x", "CLI", "--adds", " "],
            vec!["--item", "1", "x", "CLI", "--item", "1", "y", "CLI"],
            vec![
                "--item",
                "1",
                "x",
                "CLI",
                "--items-file",
                items.to_str().unwrap(),
            ],
            vec![
                "--item",
                "1",
                "x",
                "CLI",
                "--finding-occurrences-file",
                bad_findings.to_str().unwrap(),
            ],
        ] {
            let out = w.call(&["round", "stamp"], "bad", &extra);
            assert!(!out.status.success(), "{extra:?}");
            assert!(!w.round_path("bad").exists());
        }
        let out = w.call(
            &["round", "cut"],
            "cut",
            &[
                "--item",
                "1",
                "x",
                "app CLI",
                "--adds",
                "tools/new",
                "--pr-open",
                "true",
                "--source",
                "review",
            ],
        );
        let path = result(&out)["path"].as_str().unwrap().to_owned();
        let v: Value = serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(v["cut"], true);
        assert_eq!(v["adds"], json!(["tools/new"]));
        assert_eq!(v["source"], "review");
        assert_eq!(v["pr_open"], true);
    }

    #[test]
    fn receipt_schema_and_gate_order_refuse_the_first_invalid_evidence() {
        let w = World::new();
        w.stamp("r1");
        let receipt = w.released_receipt("r1", "fix");
        for (key, value) in [
            ("kind", json!("unknown")),
            ("issue", json!([])),
            ("branch", json!(true)),
            ("round_id", json!(1)),
            ("schema_version", Value::Null),
            ("commit", json!("")),
            ("validate_mode", json!("class")),
            ("validate_time", json!({"seconds":1})),
            ("validate_note", json!(0)),
            ("baseline_lines", json!(1)),
        ] {
            let mut bad = receipt.clone();
            bad[key] = value;
            w.plant_receipt("r1", &bad);
            assert_eq!(w.check("r1")["reason"], "invalid", "{key}");
        }
        let second = json!({"started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:00:01Z","seconds":1});
        let mut five = second.clone();
        five["seconds"] = json!(5);
        for patch in [
            vec![
                ("validate", json!("pass")),
                ("validate_mode", json!("full")),
            ],
            vec![("validate_mode", json!("full")), ("validate_time", five)],
            vec![("validate_time", second.clone())],
            vec![
                ("validate", json!("no-verdict")),
                ("validate_mode", json!("full")),
                ("validate_time", second.clone()),
            ],
            vec![("kind", json!("implement")), ("baseline_lines", json!(0))],
        ] {
            let mut bad = receipt.clone();
            for (key, value) in &patch {
                bad[*key] = value.clone();
            }
            w.plant_receipt("r1", &bad);
            assert_eq!(w.check("r1")["reason"], "invalid", "{patch:?}");
        }
        let mut timeless = receipt.clone();
        timeless.as_object_mut().unwrap().remove("validate_time");
        w.plant_receipt("r1", &timeless);
        assert_eq!(w.check("r1")["reason"], "invalid");
        let mut named = receipt.clone();
        named["commit"] = json!("HEAD");
        w.plant_receipt("r1", &named);
        assert_eq!(w.check("r1")["reason"], "commit_unresolvable");
        // Read by its own path, the receipt's issue is its token and its
        // repository the worktree its tmp directory belongs to.
        let mut loose = receipt.clone();
        loose["issue"] = json!("a/b");
        let file = w.wt.join("tmp/loose.json");
        fs::write(&file, loose.to_string()).unwrap();
        let by_file = |path: &Path| {
            result(&w.run(&["dev-return", "check", "--file", path.to_str().unwrap()]))["reason"]
                .clone()
        };
        assert_eq!(by_file(&file), "invalid");
        fs::create_dir(w.wt.join("other")).unwrap();
        let outside = w.wt.join("other/receipt.json");
        fs::write(&outside, receipt.to_string()).unwrap();
        assert_eq!(by_file(&outside), "commit_unverifiable");
        // A run-less ci receipt defers to CI only where the pull request runs
        // it: open at the stamp, or published first.
        let mut ci = receipt.clone();
        ci["validate"] = json!("pass");
        ci["validate_mode"] = json!("ci");
        ci["validate_time"] = second.clone();
        w.plant_receipt("r1", &ci);
        assert_eq!(w.check("r1")["reason"], "mode_mismatch");
        let ordered = |order: &str| {
            result(
                &w.command()
                    .env("ORCH_PR_ORDER", order)
                    .args(["dev-return", "check"])
                    .args(w.identity("r1"))
                    .arg("--expect-items-from-round")
                    .output()
                    .unwrap(),
            )
        };
        let push_first = ordered("push-first");
        assert_eq!(push_first["verdict"], "accept", "{push_first}");
        // An order `pr-order` refuses is no order: the round runs review-first.
        let refused = ordered("bogus");
        assert_eq!(refused["reason"], "mode_mismatch", "{refused}");
        result(&w.call(
            &["round", "stamp"],
            "open",
            &[
                "--item",
                "1",
                "repair parser",
                "app CLI",
                "--pr-open",
                "true",
            ],
        ));
        w.plant_receipt("open", &{
            let mut v = ci.clone();
            v["round_id"] = json!("open");
            v
        });
        assert_eq!(w.check("open")["verdict"], "accept");
        let parent = w.head();
        w.commit("later.txt");
        w.plant_receipt("open", &{
            let mut v = ci.clone();
            v["round_id"] = json!("open");
            v["commit"] = json!(parent);
            v
        });
        assert_eq!(w.check("open")["reason"], "ci_head_mismatch");
        let mut bad = receipt.clone();
        bad["commit"] = json!("badbad");
        bad["items"] = json!([]);
        w.plant_receipt("r1", &bad);
        assert_eq!(w.check("r1")["reason"], "commit_unresolvable");
        bad["commit"] = json!(w.head());
        w.plant_receipt("r1", &bad);
        assert_eq!(w.check("r1")["reason"], "incomplete");
        w.commit("tools/new-helper");
        bad["commit"] = json!(w.head());
        w.plant_receipt("r1", &bad);
        assert_eq!(w.check("r1")["reason"], "unapproved_additions");
        let started = result(
            &w.command()
                .env(
                    "DEV_VALIDATE_RANGE_CMD",
                    "printf 'validate: lanes=range selection=all\\n'",
                )
                .args([
                    "validate", "start", "--item", "issue-8", "--round", "r1", "--base", "main",
                    "--mode", "range", "--poll", "1",
                ])
                .output()
                .unwrap(),
        );
        let mode_run = Validation(&w, started["run_dir"].as_str().unwrap().to_owned());
        let run_id = Path::new(&mode_run.1)
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .strip_prefix("dev-validate-")
            .unwrap();
        let keyed =
            w.wt.join(format!("tmp/dev-return-issue-8-r1-{run_id}.json"));
        bad["validate_mode"] = json!("full");
        bad["validate_time"] = json!({"started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:00:00Z","seconds":0});
        fs::write(keyed, bad.to_string()).unwrap();
        assert_eq!(w.check("r1")["reason"], "mode_mismatch");
    }

    #[test]
    fn receipt_items_are_the_exact_delegated_set() {
        let w = World::new();
        w.stamp("r1");
        let good = w.released_receipt("r1", "fix");
        for items in [
            json!([]),
            json!([{"n":2,"decision":"Applied","reasoning":"x"}]),
            json!([{"n":1,"decision":"Applied","reasoning":"x"},{"n":1,"decision":"Skipped","reasoning":"x"}]),
            json!([{"n":1,"decision":"Done","reasoning":"x"}]),
            json!([{"n":1,"decision":"Applied","reasoning":""}]),
            json!([{"n":1,"decision":"Applied","reasoning":"x"},{"n":2,"decision":"Applied","reasoning":"x"}]),
        ] {
            let mut bad = good.clone();
            bad["items"] = items;
            w.plant_receipt("r1", &bad);
            assert_eq!(w.check("r1")["reason"], "incomplete");
        }
        let mut bundle = good.clone();
        bundle["kind"] = json!("implement");
        bundle["baseline_lines"] = json!(1);
        bundle["bundled"] = json!(true);
        bundle["items"] = json!([]);
        w.plant_receipt("bundle", &bundle);
        assert_eq!(
            result(&w.run(&[
                "dev-return",
                "check",
                "--file",
                w.receipt_path("bundle").to_str().unwrap()
            ]))["reason"],
            "incomplete"
        );
        // A count passed as the item numbers reads as incomplete with a hint.
        let mut counted = good.clone();
        counted["items"] = json!(
            [1, 2, 3]
                .iter()
                .map(|n| json!({"n":n,"decision":"Applied","reasoning":"x"}))
                .collect::<Vec<_>>()
        );
        let counted_path = w.wt.join("tmp/counted.json");
        fs::write(&counted_path, counted.to_string()).unwrap();
        for (expect, hinted) in [("3", true), ("1,2,3", false)] {
            let answer = result(&w.run(&[
                "dev-return",
                "check",
                "--file",
                counted_path.to_str().unwrap(),
                "--expect-items",
                expect,
            ]));
            assert_eq!(answer["hint"].is_string(), hinted, "{answer}");
        }
        w.plant_receipt("r1", &good);
        assert_eq!(w.check("r1")["verdict"], "retry");
        let orphan = git(&w.wt, &["commit-tree", &w.tree(), "-m", "orphan"]);
        let mut value = good.clone();
        value["commit"] = json!(orphan);
        w.plant_receipt("r1", &value);
        assert_eq!(w.check("r1")["warning"], "commit_unreachable");
        w.plant_receipt("r1", &good);
        let nested = w.wt.join("nested/tmp");
        fs::create_dir_all(&nested).unwrap();
        let path = nested.join("receipt.json");
        fs::write(&path, good.to_string()).unwrap();
        assert_eq!(
            result(&w.run(&["dev-return", "check", "--file", path.to_str().unwrap()]))["reason"],
            "commit_unverifiable"
        );
        let out = w.call(&["dev-return", "check"], "r1", &[]);
        refused(&out, "expected-round-required");
    }

    #[test]
    fn receipt_writer_preserves_sources_timing_summary_and_failure_identity() {
        let w = World::new();
        w.stamp("r1");
        let run = w.released_run("one", "full");
        let dir = run.to_str().unwrap();
        let out = w.write(
            "r1",
            "fix",
            "pass",
            &[
                "--validate-run-dir",
                dir,
                "--item",
                "1",
                "Applied",
                "parser fixed",
                "--summary",
                "done",
                "--qa-label",
                "needs-test",
                "--no-summary",
            ],
        );
        let path = result(&out)["path"].as_str().unwrap().to_owned();
        let v: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(v["validate_time"]["seconds"], 1);
        assert_eq!(v["summary"], "done");
        assert_eq!(v["summary_posted"], false);
        assert_eq!(v["qa_labels"], json!(["needs-test"]));
        assert_eq!(v["validate_lanes"], "unit");
        assert_eq!(v["validate_selection"], "battery");
        assert_eq!(w.check("r1")["verdict"], "accept");
        refused(
            &w.write(
                "r1",
                "fix",
                "no-verdict",
                &["--validate-run-dir", dir, "--item", "1", "Applied", "x"],
            ),
            "required",
        );
        fs::write(run.join("exit"), "guard-exit=1 at=2026-01-01T00:00:01Z\n").unwrap();
        refused(
            &w.write(
                "r1",
                "fix",
                "pass",
                &["--validate-run-dir", dir, "--item", "1", "Applied", "x"],
            ),
            "validate-disagrees",
        );
        result(&w.write(
            "r1",
            "fix",
            "FAILING: lint",
            &[
                "--validate-run-dir",
                dir,
                "--item",
                "1",
                "Blocked",
                "lint failed",
            ],
        ));
        fs::write(run.join("exit"), "guard-exit=0 at=2026-01-01T00:00:01Z\n").unwrap();
        refused(
            &w.write(
                "r1",
                "fix",
                "pass",
                &["--validate-run-dir", dir, "--item", "1", "Applied", "x"],
            ),
            "receipt-exists",
        );
        let scratch: Vec<_> = fs::read_dir(w.wt.join("tmp"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".tmp"))
            .collect();
        assert!(scratch.is_empty(), "{scratch:?}");
        assert_eq!(w.check("r1")["verdict"], "retry");
        let second = w.released_run("two", "full");
        result(&w.write(
            "r1",
            "fix",
            "FAILING: lint",
            &[
                "--validate-run-dir",
                second.to_str().unwrap(),
                "--item",
                "1",
                "Blocked",
                "lint failed",
            ],
        ));
        refused(
            &w.call(
                &["dev-return", "check"],
                "r1",
                &["--expect-items-from-round"],
            ),
            "receipt-ambiguous",
        );
        // A ci run's pending pass records the full commit its pending
        // contents were compared with, which the checker holds to HEAD.
        result(&w.call(
            &["round", "stamp"],
            "ci",
            &[
                "--item",
                "1",
                "repair parser",
                "app CLI",
                "--pr-open",
                "true",
            ],
        ));
        let ci = w.released_run("ci", "full");
        fs::write(
            ci.join("start"),
            fs::read_to_string(ci.join("start"))
                .unwrap()
                .replace("validate-mode=full", "validate-mode=ci"),
        )
        .unwrap();
        w.record_start(&ci, &format!("tree={}", w.tree()));
        let head = w.head();
        let ci_args = |commit: &str| {
            w.call(
                &["dev-return", "write"],
                "ci",
                &[
                    "--kind",
                    "fix",
                    "--branch",
                    "work",
                    "--commit",
                    commit,
                    "--validate",
                    "pass",
                    "--validate-run-dir",
                    ci.to_str().unwrap(),
                    "--item",
                    "1",
                    "Applied",
                    "x",
                ],
            )
        };
        let path = result(&ci_args(&head[..7]))["path"]
            .as_str()
            .unwrap()
            .to_owned();
        let v: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(v["commit"], head);
        assert_eq!(v["validate_mode"], "ci");
        assert_eq!(w.check("ci")["verdict"], "accept");
        fs::remove_file(&path).unwrap();
        w.commit("more.txt");
        refused(&ci_args(&w.head()), "ci-contents-mismatch");
        // The record keeps every field the evidence and the arguments name.
        let shot = w.root.join("shot.png");
        fs::write(&shot, "png").unwrap();
        let classed = w.released_run("class", "full");
        w.record_start(&classed, &format!("class-base={head}"));
        let answer = result(&w.write(
            "bundle",
            "implement",
            "FAILING: lint",
            &[
                "--validate-run-dir",
                classed.to_str().unwrap(),
                "--screenshot",
                shot.to_str().unwrap(),
                "--validate-note",
                "a caveat",
                "--bundled",
                "--item",
                "1",
                "Applied",
                "x",
            ],
        ));
        let v: Value =
            serde_json::from_str(&fs::read_to_string(answer["path"].as_str().unwrap()).unwrap())
                .unwrap();
        assert_eq!(v["screenshots"], json!([shot.canonicalize().unwrap()]));
        assert_eq!(v["validate_note"], "a caveat");
        assert_eq!(v["bundled"], true);
        assert_eq!(v["validate_class_base"], head);
        let span = w.released_run("span", "full");
        fs::write(
            span.join("timing"),
            "started-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:00:01Z\nseconds=5\n",
        )
        .unwrap();
        refused(
            &w.write(
                "span",
                "implement",
                "FAILING: lint",
                &["--validate-run-dir", span.to_str().unwrap()],
            ),
            "timing-unreadable",
        );
        // An unfinished run has no wall time yet.
        let open = w.released_run("open", "full");
        fs::remove_file(open.join("exit")).unwrap();
        fs::remove_file(open.join("timing")).unwrap();
        let answer = result(&w.write(
            "open",
            "implement",
            "FAILING: lost",
            &["--validate-run-dir", open.to_str().unwrap()],
        ));
        let v: Value =
            serde_json::from_str(&fs::read_to_string(answer["path"].as_str().unwrap()).unwrap())
                .unwrap();
        assert_eq!(v["validate_mode"], "full");
        assert!(v["validate_time"].is_null());
        // The round's receipt is the one keyed by its newest admitted run.
        let mut doc = w.doc();
        for (start, name) in [(10, "older"), (20, "newer")] {
            doc["stages"].as_array_mut().unwrap().push(json!({"kind":"validate","round_id":"pick","start":start,"end":start,"outcome":"pass","run_dir":w.wt.join(format!("tmp/dev-validate-{name}"))}));
        }
        fs::write(w.item(), doc.to_string()).unwrap();
        w.stamp("pick");
        let mut stale = w.released_receipt("pick", "fix");
        stale["kind"] = json!("unknown");
        fs::write(
            w.wt.join("tmp/dev-return-issue-8-pick-older.json"),
            stale.to_string(),
        )
        .unwrap();
        fs::write(
            w.wt.join("tmp/dev-return-issue-8-pick-newer.json"),
            w.released_receipt("pick", "fix").to_string(),
        )
        .unwrap();
        assert_eq!(w.check("pick")["reason"], "valid");
    }

    #[test]
    fn released_foreground_records_need_complete_timing_and_a_clean_recorded_tree() {
        let w = World::new();
        w.stamp("r1");
        let file = w.root.join("foreground");
        let record = format!(
            "validate-mode=full\nhead={}\nstarted-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:00:01Z\nexit=0\nselection=unreported\n",
            w.head()
        );
        fs::write(&file, &record).unwrap();
        result(&w.write(
            "r1",
            "fix",
            "pass",
            &[
                "--validate-record",
                file.to_str().unwrap(),
                "--item",
                "1",
                "Applied",
                "x",
            ],
        ));
        assert_eq!(w.check("r1")["verdict"], "accept");
        let foreground = |validate: &str, extra: &[&str]| {
            let mut args = vec!["--validate-record", file.to_str().unwrap()];
            args.extend_from_slice(extra);
            args.extend_from_slice(&["--item", "1", "Applied", "x"]);
            w.write("r1", "fix", validate, &args)
        };
        let subset = record.replace("selection=unreported", "selection=subset\nlanes=lint");
        for (record, key) in [
            (
                record.replace(
                    "ended-at=2026-01-01T00:00:01Z",
                    "ended-at=2025-01-01T00:00:00Z",
                ),
                "validate-record-time",
            ),
            (record.clone() + "exit=0\n", "validate-record-line"),
            (record.clone() + "unknown=value\n", "validate-record-line"),
            (record.replace("head=", "missing="), "validate-record-line"),
            (
                record.replace("selection=unreported\n", ""),
                "validate-record-missing",
            ),
            (
                record.replace("validate-mode=full", "validate-mode=ci"),
                "validate-record-value",
            ),
            (
                record.replace(&format!("head={}", w.head()), "head=abc"),
                "validate-record-value",
            ),
            (
                record.replace("selection=unreported", "selection=everything"),
                "validate-record-value",
            ),
            (
                record.replace("selection=unreported", "selection=all"),
                "validate-record-lanes",
            ),
            (record.clone() + "lanes=lint\n", "validate-record-lanes"),
            (
                subset.replace("lanes=lint", "lanes=lint,"),
                "validate-record-lanes",
            ),
            (
                record.replace("2026-01-01T00:00:00Z", "2026-13-01T00:00:00Z"),
                "validate-record-value",
            ),
            (
                record.replace("exit=0", "exit=1000"),
                "validate-record-value",
            ),
            (record.replace("exit=0", "exit=x"), "validate-record-value"),
            (record.clone() + "verdict=pass\n", "validate-record-value"),
        ] {
            fs::write(&file, &record).unwrap();
            refused(&foreground("pass", &[]), key);
        }
        fs::remove_file(&file).unwrap();
        fs::create_dir(&file).unwrap();
        refused(&foreground("pass", &[]), "validate-record-unreadable");
        fs::remove_dir(&file).unwrap();
        // The exit and the bounded-run marker are the run's verdict.
        fs::write(&file, record.replace("exit=0", "exit=1")).unwrap();
        refused(&foreground("pass", &[]), "validate-disagrees");
        fs::write(&file, record.clone() + "verdict=no-verdict\n").unwrap();
        refused(&foreground("pass", &[]), "validate-disagrees");
        fs::remove_file(w.receipt_path("r1")).unwrap();
        result(&foreground("no-verdict", &["--validate-note", "bounded"]));
        fs::remove_file(w.receipt_path("r1")).unwrap();
        fs::write(&file, &subset).unwrap();
        let path = result(&foreground("pass", &[]))["path"]
            .as_str()
            .unwrap()
            .to_owned();
        let v: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(v["validate_lanes"], "lint");
        fs::remove_file(&path).unwrap();
        // A project that declares a finding prefix proves a foreground run as
        // run under it; a failure binds by its tree before any proof.
        fs::write(&file, &record).unwrap();
        let prefixed = |validate: &str| {
            let head = w.head();
            w.command()
                .env("DEV_VALIDATE_FINDING_PREFIX", "finding:")
                .args(["dev-return", "write"])
                .args(w.identity("r1"))
                .args(["--kind", "fix", "--branch", "work", "--commit", &head])
                .args(["--validate", validate, "--validate-record"])
                .arg(&file)
                .args(["--item", "1", "Applied", "x"])
                .output()
                .unwrap()
        };
        result(&prefixed("pass"));
        fs::remove_file(w.receipt_path("r1")).unwrap();
        fs::write(
            &file,
            record.replace("validate-mode=full", "validate-mode=range"),
        )
        .unwrap();
        result(&prefixed("FAILING: lint"));
        fs::remove_file(w.receipt_path("r1")).unwrap();
        // With no declared command a foreground row proves nothing.
        fs::write(&file, &record).unwrap();
        let head = w.head();
        refused(
            &w.command()
                .env_remove("DEV_VALIDATE_CMD")
                .args(["dev-return", "write"])
                .args(w.identity("r1"))
                .args(["--kind", "fix", "--branch", "work", "--commit", &head])
                .args(["--validate", "pass", "--validate-record"])
                .arg(&file)
                .args(["--item", "1", "Applied", "x"])
                .output()
                .unwrap(),
            "run-off-round",
        );
        // A record without a snapshot proves its own HEAD only: an empty
        // commit keeps the tree and still leaves the record behind.
        git(&w.wt, &["commit", "-q", "--allow-empty", "-m", "empty"]);
        refused(&foreground("pass", &[]), "run-off-round");
        fs::write(&file, record.replace(&head, &w.head())).unwrap();
        // An untracked file git would track leaves the tree unknown; an
        // ignored one is no part of it.
        fs::write(w.wt.join("tmp/ignored.txt"), "x").unwrap();
        result(&foreground("pass", &[]));
        fs::remove_file(w.receipt_path("r1")).unwrap();
        fs::write(w.wt.join("untracked.txt"), "x").unwrap();
        refused(&foreground("pass", &[]), "run-off-round");
        fs::remove_file(w.wt.join("untracked.txt")).unwrap();
        let record = record.replace(&head, &w.head());
        fs::write(&file, record).unwrap();
        fs::write(w.wt.join("app.txt"), "dirty\n").unwrap();
        refused(
            &w.write(
                "r1",
                "fix",
                "pass",
                &[
                    "--validate-record",
                    file.to_str().unwrap(),
                    "--item",
                    "1",
                    "Applied",
                    "x",
                ],
            ),
            "run-off-round",
        );
        // A fix round's two orders: a record written before the round's
        // commit names that commit's parent and proves no tree of the
        // receipt's; the workflow commits first and records that HEAD.
        let w = World::new();
        w.stamp("r1");
        let at = |head: &str| {
            format!(
                "validate-mode=full\nhead={head}\nstarted-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:00:01Z\nexit=0\nselection=unreported\n"
            )
        };
        let receipt = |w: &World| {
            w.write(
                "r1",
                "fix",
                "pass",
                &[
                    "--validate-record",
                    file.to_str().unwrap(),
                    "--item",
                    "1",
                    "Applied",
                    "x",
                ],
            )
        };
        fs::write(&file, at(&w.head())).unwrap();
        w.commit("app.txt");
        refused(&receipt(&w), "run-off-round");
        fs::write(&file, at(&w.head())).unwrap();
        result(&receipt(&w));
        fs::remove_file(w.receipt_path("r1")).unwrap();
        // The clean check reads the user's own excludes file, as the
        // validation snapshot does: a file only that file ignores is no
        // part of the tree.
        let home = w.root.join("home");
        fs::create_dir(&home).unwrap();
        fs::write(home.join("excludes"), ".idea/\n").unwrap();
        fs::write(
            home.join(".gitconfig"),
            format!(
                "[core]\n\texcludesFile = {}\n",
                home.join("excludes").display()
            ),
        )
        .unwrap();
        fs::create_dir(w.wt.join(".idea")).unwrap();
        fs::write(w.wt.join(".idea/workspace.xml"), "x").unwrap();
        let head = w.head();
        let excluded = |home: &Path| {
            w.command()
                .env("HOME", home)
                .args(["dev-return", "write"])
                .args(w.identity("r1"))
                .args(["--kind", "fix", "--branch", "work", "--commit", &head])
                .args(["--validate", "pass", "--validate-record"])
                .arg(&file)
                .args(["--item", "1", "Applied", "x"])
                .output()
                .unwrap()
        };
        refused(&excluded(&w.root), "run-off-round");
        result(&excluded(&home));
    }

    #[test]
    fn a_stopped_run_reads_no_verdict_never_a_failure_or_a_pass() {
        let w = World::new();
        w.stamp("r1");
        let run = w.released_run("stopped", "full");
        fs::write(run.join("exit"), "guard-exit=143 at=2026-01-01T00:00:01Z\n").unwrap();
        fs::write(run.join("stop"), "stop-requested\n").unwrap();
        let dir = run.to_str().unwrap();
        let out = w.write(
            "r1",
            "fix",
            "pass",
            &["--validate-run-dir", dir, "--item", "1", "Applied", "x"],
        );
        refused(&out, "validate-disagrees");
        assert!(stderr(&out).contains("run=no-verdict"), "{}", stderr(&out));
        let out = w.write(
            "r1",
            "fix",
            "no-verdict",
            &[
                "--validate-run-dir",
                dir,
                "--validate-note",
                "stopped by its owner",
                "--item",
                "1",
                "Applied",
                "x",
            ],
        );
        let path = result(&out)["path"].as_str().unwrap().to_owned();
        let v: Value = serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(v["validate"], "no-verdict");
        assert_eq!(v["validate_mode"], "full");
    }

    #[test]
    fn an_unreadable_run_record_refuses_the_receipt_with_the_readers_own_diagnostic() {
        let w = World::new();
        w.stamp("r1");
        let bad = w.released_run("bad", "class");
        let empty = w.wt.join("tmp/dev-validate-empty");
        fs::create_dir(&empty).unwrap();
        for (dir, cause) in [
            (bad, "cause=invalid-mode cause=class".to_owned()),
            (
                empty.clone(),
                format!("cause=record cause={}/start: ", empty.display()),
            ),
        ] {
            let head = w.head();
            let out = w
                .command()
                .args(["dev-return", "--text", "write"])
                .args(w.identity("r1"))
                .args([
                    "--kind",
                    "implement",
                    "--branch",
                    "work",
                    "--commit",
                    &head,
                    "--validate",
                    "pass",
                    "--validate-run-dir",
                ])
                .arg(&dir)
                .output()
                .unwrap();
            assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
            assert!(out.stdout.is_empty());
            let want = format!(
                "dev-return-write: run-record-unreadable path={} {cause}",
                dir.display()
            );
            assert!(stderr(&out).starts_with(&want), "{}", stderr(&out));
            let name = dir.file_name().unwrap().to_str().unwrap();
            let key = name.strip_prefix("dev-validate-").unwrap();
            assert!(
                !w.wt
                    .join(format!("tmp/dev-return-issue-8-r1-{key}.json"))
                    .exists()
            );
        }
    }

    #[test]
    fn the_writers_own_refusals_exit_two_name_their_guard_and_write_nothing() {
        let w = World::new();
        w.stamp("r1");
        let run = w.released_run("one", "full");
        let dir = run.to_str().unwrap();
        let shots = w.root.join("shots");
        fs::create_dir(&shots).unwrap();
        let shots = shots.to_str().unwrap();
        let gone = w.root.join("gone");
        let gone = gone.to_str().unwrap();
        let locked = w.root.join("locked.png");
        fs::write(&locked, "png").unwrap();
        fs::set_permissions(
            &locked,
            <fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o000),
        )
        .unwrap();
        let locked = locked.to_str().unwrap();
        let wt = w.wt.to_str().unwrap();
        let head = w.head();
        let receipts = || {
            fs::read_dir(w.wt.join("tmp"))
                .unwrap()
                .filter(|e| {
                    e.as_ref()
                        .unwrap()
                        .file_name()
                        .to_string_lossy()
                        .starts_with("dev-return-")
                })
                .count()
        };
        let before = receipts();
        let pass = ["--validate", "pass", "--validate-run-dir", dir];
        for (identity, rest, key) in [
            (
                ["issue-8", "r1", wt],
                vec!["--kind", "implement", "--validate", "pass"],
                "required",
            ),
            (
                ["issue-8", "r1", wt],
                vec![
                    "--kind",
                    "implement",
                    "--validate",
                    "no-verdict",
                    "--validate-run-dir",
                    dir,
                ],
                "required",
            ),
            (
                ["issue-8", "r1", wt],
                vec!["--kind", "implement", "--validate", "weird"],
                "invalid-validate",
            ),
            (
                ["issue-8", "r1", wt],
                vec![
                    "--kind",
                    "implement",
                    "--validate",
                    "pass_with_notes",
                    "--validate-note",
                    "x",
                ],
                "invalid-validate",
            ),
            (
                ["issue-8", "r1", wt],
                [&["--kind", "implement", "--summary", " "][..], &pass].concat(),
                "empty-text",
            ),
            (
                ["issue-8", "r1", wt],
                [&["--kind", "implement", "--validate-note", " "][..], &pass].concat(),
                "empty-text",
            ),
            (
                ["issue-8", "r1", wt],
                [&["--kind", "implement", "--summary-file", gone][..], &pass].concat(),
                "missing-file",
            ),
            (
                ["issue-8", "r1", wt],
                [&["--kind", "implement", "--screenshot", shots][..], &pass].concat(),
                "screenshot-unreadable",
            ),
            (
                ["issue-8", "r1", wt],
                [&["--kind", "implement", "--screenshot", gone][..], &pass].concat(),
                "screenshot-unreadable",
            ),
            (
                ["issue-8", "r1", wt],
                [&["--kind", "implement", "--screenshot", locked][..], &pass].concat(),
                "screenshot-unreadable",
            ),
            (
                ["issue-8", "r1", wt],
                vec![
                    "--kind",
                    "fix",
                    "--validate",
                    "FAILING: lint",
                    "--item",
                    "x",
                    "Applied",
                    "y",
                ],
                "missing-items",
            ),
            (
                ["issue-8", "r1", wt],
                [
                    &["--kind", "implement", "--near-ceiling-base", ""][..],
                    &pass,
                ]
                .concat(),
                "required",
            ),
            (
                ["issue-8", "r1", wt],
                vec!["--kind", "fix", "--validate", "FAILING: lint"],
                "missing-items",
            ),
            (
                ["issue-8", "r1", wt],
                vec![
                    "--kind",
                    "implement",
                    "--bundled",
                    "--validate",
                    "FAILING: lint",
                ],
                "missing-items",
            ),
            (
                ["issue-8", "r1", wt],
                vec![
                    "--kind",
                    "fix",
                    "--validate",
                    "FAILING: lint",
                    "--item",
                    "1",
                    "Fixed",
                    "x",
                ],
                "missing-items",
            ),
            (
                ["a/b", "r1", wt],
                vec!["--kind", "implement", "--validate", "FAILING: lint"],
                "invalid-id",
            ),
            (
                ["issue-8", "..", wt],
                vec!["--kind", "implement", "--validate", "FAILING: lint"],
                "invalid-id",
            ),
            (
                ["issue-8", "r1", gone],
                vec!["--kind", "implement", "--validate", "FAILING: lint"],
                "not-directory",
            ),
        ] {
            let out = w
                .command()
                .args(["dev-return", "--text", "write", "--issue", identity[0]])
                .args(["--round-id", identity[1], "--worktree", identity[2]])
                .args(["--branch", "work", "--commit", &head])
                .args(&rest)
                .output()
                .unwrap();
            assert_eq!(out.status.code(), Some(2), "{rest:?} {}", stderr(&out));
            assert!(
                stderr(&out).starts_with(&format!("dev-return-write: {key} ")),
                "{rest:?} {}",
                stderr(&out)
            );
            assert!(out.stdout.is_empty());
            assert_eq!(receipts(), before, "{rest:?}");
        }
        for (branch, commit) in [("work", ""), (" ", head.as_str())] {
            let out = w
                .command()
                .args(["dev-return", "--text", "write"])
                .args(w.identity("r1"))
                .args([
                    "--kind",
                    "implement",
                    "--branch",
                    branch,
                    "--commit",
                    commit,
                ])
                .args(["--validate", "FAILING: lint"])
                .output()
                .unwrap();
            assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
            assert!(
                stderr(&out).starts_with("dev-return-write: required "),
                "{}",
                stderr(&out)
            );
            assert_eq!(receipts(), before);
        }
        // A kind outside the two is refused at the arguments, before any answer.
        let out = w
            .command()
            .args(["dev-return", "write"])
            .args(w.identity("r1"))
            .args(["--kind", "review", "--branch", "work", "--commit", &head])
            .args(["--validate", "FAILING: lint"])
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
        assert!(out.stdout.is_empty());
        assert_eq!(receipts(), before);
    }

    #[test]
    fn the_stamp_and_checker_refusals_name_their_guard_and_write_nothing() {
        let w = World::new();
        let wt = w.wt.to_str().unwrap();
        let gone = w.root.join("gone");
        let gone = gone.to_str().unwrap();
        let headless = w.root.join("headless");
        fs::create_dir(&headless).unwrap();
        git(&headless, &["init", "-q"]);
        let headless = headless.to_str().unwrap();
        let item = ["--item", "1", "repair parser", "app CLI"];
        let object = w.root.join("object.json");
        fs::write(&object, "{}").unwrap();
        let object = object.to_str().unwrap();
        for (identity, rest, key) in [
            (["", "r1", wt], item.to_vec(), "invalid-id"),
            (
                ["issue-8", "r1", wt],
                vec!["--items-file", gone],
                "invalid-json",
            ),
            (
                ["issue-8", "r1", wt],
                vec!["--items-file", object],
                "invalid-items",
            ),
            (["a/b", "r1", wt], item.to_vec(), "invalid-id"),
            (["issue-8", "..", wt], item.to_vec(), "invalid-id"),
            (
                ["issue-8", "r1", wt],
                [&item[..], &["--source", "pr/comments"]].concat(),
                "invalid-id",
            ),
            (["issue-8", "r1", gone], item.to_vec(), "not-directory"),
            (["issue-8", "r1", headless], item.to_vec(), "git-failed"),
            (["issue-8", "r1", wt], vec![], "invalid-items"),
            (
                ["issue-8", "r1", wt],
                vec!["--item", "x", "t", "app CLI"],
                "invalid-items",
            ),
            (
                ["issue-8", "r1", wt],
                vec!["--item", "01", "t", "app CLI"],
                "invalid-items",
            ),
            (
                ["issue-8", "r1", wt],
                vec!["--item", "1", " ", "app CLI"],
                "invalid-items",
            ),
            (
                ["issue-8", "r1", wt],
                [&item[..], &["--item", "1", "again", "app CLI"]].concat(),
                "invalid-items",
            ),
        ] {
            let out = w
                .command()
                .args(["round", "--text", "stamp", "--issue", identity[0]])
                .args(["--round-id", identity[1], "--worktree", identity[2]])
                .args(&rest)
                .output()
                .unwrap();
            assert_eq!(out.status.code(), Some(2), "{rest:?} {}", stderr(&out));
            assert!(
                stderr(&out).starts_with(&format!("dev-round-write: {key} ")),
                "{rest:?} {}",
                stderr(&out)
            );
            assert!(
                fs::read_dir(w.wt.join("tmp")).unwrap().next().is_none(),
                "{rest:?}"
            );
        }
        let receipt = w.root.join("receipt.json");
        fs::write(&receipt, w.released_receipt("r1", "fix").to_string()).unwrap();
        let receipt = receipt.to_str().unwrap();
        for (args, key) in [
            (
                vec!["--worktree", wt, "--issue", "a/b", "--round-id", "r1"],
                "invalid-id",
            ),
            (
                vec!["--worktree", wt, "--issue", "issue-8", "--round-id", ".."],
                "invalid-id",
            ),
            (
                vec!["--worktree", gone, "--issue", "issue-8", "--round-id", "r1"],
                "not-directory",
            ),
            (
                vec!["--file", receipt, "--expect-items", "1,x"],
                "invalid-item-numbers",
            ),
            (
                vec![
                    "--worktree",
                    wt,
                    "--issue",
                    "issue-8",
                    "--round-id",
                    "r1",
                    "--expect-items",
                    "1",
                ],
                "file-mode-required",
            ),
        ] {
            let out = w
                .command()
                .args(["dev-return", "--text", "check"])
                .args(&args)
                .output()
                .unwrap();
            assert_eq!(out.status.code(), Some(2), "{args:?} {}", stderr(&out));
            assert!(
                stderr(&out).starts_with(&format!("dev-artifact-check: {key} ")),
                "{args:?} {}",
                stderr(&out)
            );
        }
        // Arguments outside a verb's grammar are refused before any answer.
        let id = ["--worktree", wt, "--issue", "issue-8", "--round-id", "r1"];
        for args in [
            [&["round", "stamp"][..], &id, &item, &["--pr-open", "yes"]].concat(),
            vec!["dev-return", "check", "--file", receipt, "--interval", "0"],
            vec![
                "dev-return",
                "check",
                "--file",
                receipt,
                "--expect-items-from-round",
            ],
        ] {
            let out = w.run(&args);
            assert_eq!(out.status.code(), Some(2), "{args:?} {}", stderr(&out));
            assert!(out.stdout.is_empty(), "{args:?}");
            assert!(!w.round_path("r1").exists(), "{args:?}");
        }
    }

    #[test]
    fn a_docs_only_pass_proves_its_snapshot_for_a_fix_whether_recorded_or_read_from_its_run() {
        let w = World::new();
        git(&w.wt, &["update-ref", "refs/remotes/origin/main", "main"]);
        w.stamp("r1");
        w.commit("note.md");
        let text_cmd = "printf 'validate: lanes=text selection=subset\\n'";
        let started = result(
            &w.command()
                .env("DEV_VALIDATE_TEXT_CMD", text_cmd)
                .args([
                    "validate",
                    "start",
                    "--item",
                    "issue-8",
                    "--round",
                    "r1",
                    "--base",
                    "main",
                    "--poll",
                    "1",
                    "--foreground",
                ])
                .output()
                .unwrap(),
        );
        assert_eq!(started["mode"], "docs", "{started}");
        let dir = started["run_dir"].as_str().unwrap().to_owned();
        let write = || {
            let head = w.head();
            w.command()
                .env("DEV_VALIDATE_TEXT_CMD", text_cmd)
                .args(["dev-return", "write"])
                .args(w.identity("r1"))
                .args([
                    "--kind",
                    "fix",
                    "--branch",
                    "work",
                    "--commit",
                    &head,
                    "--validate",
                    "pass",
                    "--validate-run-dir",
                    &dir,
                    "--item",
                    "1",
                    "Applied",
                    "the note reads right",
                ])
                .output()
                .unwrap()
        };
        let path = result(&write())["path"].as_str().unwrap().to_owned();
        let v: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(v["validate_mode"], "docs");
        assert_eq!(w.check("r1")["verdict"], "accept");
        // The same run with no stage recording it: its run file is the proof.
        let mut doc = w.doc();
        doc["stages"]
            .as_array_mut()
            .unwrap()
            .retain(|s| s["run_dir"] != dir.as_str());
        fs::write(w.item(), doc.to_string()).unwrap();
        fs::remove_file(&path).unwrap();
        result(&write());
        assert_eq!(w.check("r1")["verdict"], "accept");
    }

    #[test]
    fn additions_classify_real_commits_and_allow_only_the_declared_paths() {
        for (path, protected) in [
            ("crates/p/lib.rs", true),
            ("tools/check", true),
            ("skills/p/scripts/check", true),
            (".agents/skills/p/scripts/check", true),
            ("src/test/fixture", true),
            ("tests/support/helper.rs", true),
            ("tests/test-helper.rs", true),
            ("helpers/build.rs", true),
            ("test-util.rs", true),
            ("tests/lib/fixture.rs", true),
            ("tests/check_helper.rs", true),
            ("src/app.rs", false),
            ("tests/feature.rs", false),
            ("fixtures/data.json", false),
            ("docs/reference.md", false),
        ] {
            let w = World::new();
            w.stamp("r1");
            w.commit(path);
            w.plant_receipt("r1", &w.released_receipt("r1", "fix"));
            assert_eq!(
                w.check("r1")["reason"],
                if protected {
                    "unapproved_additions"
                } else {
                    "valid"
                },
                "{path}"
            );
        }
        let w = World::new();
        result(&w.call(
            &["round", "stamp"],
            "r1",
            &[
                "--item",
                "1",
                "repair",
                "app CLI",
                "--adds",
                "tools/authorized",
            ],
        ));
        w.commit("tools/authorized");
        w.plant_receipt("r1", &w.released_receipt("r1", "fix"));
        assert_eq!(w.check("r1")["reason"], "valid");
        // A protected path the round's base already held is no addition,
        // whether the round edits it or moves a file onto a protected path.
        w.stamp("edits");
        fs::write(w.wt.join("tools/authorized"), "edited\n").unwrap();
        git(&w.wt, &["commit", "-qam", "edit"]);
        git(&w.wt, &["mv", "app.txt", "tools/app.txt"]);
        git(&w.wt, &["commit", "-qm", "move"]);
        w.plant_receipt("edits", &w.released_receipt("edits", "fix"));
        assert_eq!(w.check("edits")["reason"], "valid");
        let linked = w.root.join("linked");
        git(
            &w.wt,
            &[
                "worktree",
                "add",
                "-q",
                linked.to_str().unwrap(),
                "-b",
                "linked",
            ],
        );
        let linked_identity = [
            "--worktree",
            linked.to_str().unwrap(),
            "--issue",
            "issue-8",
            "--round-id",
            "linked",
        ];
        result(
            &w.command()
                .args(["round", "stamp"])
                .args(linked_identity)
                .args(["--item", "1", "linked fix", "linked CLI"])
                .output()
                .unwrap(),
        );
        fs::create_dir_all(linked.join("tools")).unwrap();
        fs::write(linked.join("tools/linked"), "change").unwrap();
        git(&linked, &["add", "tools/linked"]);
        git(&linked, &["commit", "-qm", "linked change"]);
        let mut value = w.released_receipt("linked", "fix");
        value["commit"] = json!(git(&linked, &["rev-parse", "HEAD"]));
        fs::write(
            linked.join("tmp/dev-return-issue-8-linked.json"),
            value.to_string(),
        )
        .unwrap();
        let out = w
            .command()
            .args(["dev-return", "check"])
            .args(linked_identity)
            .arg("--expect-items-from-round")
            .output()
            .unwrap();
        assert_eq!(result(&out)["reason"], "unapproved_additions");
    }

    #[test]
    fn a_real_validation_pass_proves_an_identical_tree_for_a_replacement_round() {
        let w = World::new();
        let start = w.run(&[
            "validate", "start", "--item", "issue-8", "--round", "r1", "--base", "main", "--mode",
            "full", "--poll", "1",
        ]);
        let started = result(&start);
        let dir = PathBuf::from(started["run_dir"].as_str().unwrap());
        let bound = std::time::Instant::now() + Duration::from_secs(90);
        loop {
            let doc = w.doc();
            if doc["stages"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["run_dir"] == dir.to_str().unwrap() && s["outcome"] == "pass")
            {
                break;
            }
            assert!(
                std::time::Instant::now() < bound,
                "{} {doc}",
                fs::read_to_string(dir.join("log")).unwrap_or_default()
            );
            std::thread::sleep(Duration::from_millis(30));
        }
        let original: Value = serde_json::from_str(
            fs::read_to_string(dir.join("start"))
                .unwrap()
                .lines()
                .find_map(|l| l.strip_prefix("start="))
                .unwrap(),
        )
        .unwrap();
        w.stamp("replacement");
        let mut round: Value =
            serde_json::from_str(&fs::read_to_string(w.round_path("replacement")).unwrap())
                .unwrap();
        round["delegated_at"] = json!(original.as_u64().unwrap() + 100);
        fs::write(w.round_path("replacement"), round.to_string()).unwrap();
        result(&w.write(
            "replacement",
            "fix",
            "pass",
            &[
                "--validate-run-dir",
                dir.to_str().unwrap(),
                "--item",
                "1",
                "Applied",
                "unchanged tree remains proven",
            ],
        ));
        assert_eq!(w.check("replacement")["verdict"], "accept");
        let transcript = w.transcript(
            "replacement",
            "| 1 | Applied | unchanged work |\nCommits: none\nValidate: pass",
            "codex",
        );
        assert_eq!(
            result(&w.call(
                &["round", "recover"],
                "replacement",
                &["--transcript", transcript.to_str().unwrap()]
            ))["state"],
            "recovered"
        );
        // The round's admitted run is its run, whatever a later run beside it
        // answered.
        let late = w.released_run("late", "full");
        fs::write(
            late.join("start"),
            fs::read_to_string(late.join("start"))
                .unwrap()
                .replace("start=1", "start=4000000000"),
        )
        .unwrap();
        fs::write(late.join("exit"), "guard-exit=1 at=2026-01-01T00:00:01Z\n").unwrap();
        let report = format!(
            "Branch: work\nCommit: {}\nQA: none\nValidate: pass",
            w.head()
        );
        let transcript = w.transcript("r1", &report, "claude");
        assert_eq!(
            result(&w.call(
                &["round", "recover"],
                "r1",
                &["--transcript", transcript.to_str().unwrap()]
            ))["state"],
            "recovered"
        );
        w.commit("app.txt");
        refused(
            &w.write(
                "replacement",
                "fix",
                "pass",
                &[
                    "--validate-run-dir",
                    dir.to_str().unwrap(),
                    "--item",
                    "1",
                    "Applied",
                    "changed tree",
                ],
            ),
            "run-off-round",
        );
        // A fix run binds to its round's base by ancestry, by having compared
        // from it or by an identical tree, and its proof is the declared
        // command's.
        let w = World::new();
        w.stamp("r1");
        let write = |round: &str, run: &Path| {
            w.write(
                round,
                "fix",
                "pass",
                &[
                    "--validate-run-dir",
                    run.to_str().unwrap(),
                    "--item",
                    "1",
                    "Applied",
                    "x",
                ],
            )
        };
        refused(
            &write("unstamped", &w.released_run("unstamped", "full")),
            "round-missing",
        );
        let other = w.released_run("other-command", "full");
        fs::write(other.join("cmd"), "another command").unwrap();
        refused(&write("r1", &other), "run-off-round");
        let round = w.round_path("r1");
        let stamped = fs::read_to_string(&round).unwrap();
        let mut absent: Value = serde_json::from_str(&stamped).unwrap();
        absent["base_sha"] = json!("1".repeat(40));
        fs::write(&round, absent.to_string()).unwrap();
        refused(
            &write("r1", &w.released_run("absent-base", "full")),
            "ancestry-unreadable",
        );
        fs::write(&round, stamped).unwrap();
        // The round's base X is rewritten away: HEAD Y does not contain it.
        w.commit("x.txt");
        w.stamp("orph");
        let base = w.head();
        let base_tree = w.tree();
        git(&w.wt, &["reset", "-q", "--hard", "main"]);
        w.commit("y.txt");
        let snapshot = |name: &str, line: Option<String>| {
            let run = w.released_run(name, "full");
            w.record_start(&run, &format!("tree={}", w.tree()));
            if let Some(line) = line {
                w.record_start(&run, &line);
            }
            run
        };
        refused(&write("orph", &snapshot("unbound", None)), "run-off-round");
        result(&write(
            "orph",
            &snapshot("compared", Some(format!("validate-base={base}"))),
        ));
        let main = git(&w.wt, &["rev-parse", "main"]);
        refused(
            &write(
                "orph",
                &snapshot("compared-other", Some(format!("validate-base={main}"))),
            ),
            "run-off-round",
        );
        // A HEAD whose tree is the base's own proves the base unchanged.
        let equivalent = git(
            &w.wt,
            &["commit-tree", &base_tree, "-p", &main, "-m", "same"],
        );
        git(&w.wt, &["reset", "-q", "--hard", &equivalent]);
        result(&write("orph", &snapshot("equivalent", None)));
        // A recorded snapshot proves its tree for a later HEAD with it.
        let held = snapshot("snapshot", None);
        git(&w.wt, &["commit", "-q", "--allow-empty", "-m", "empty"]);
        result(&write("orph", &held));
    }

    #[test]
    fn released_bare_receipts_and_bound_recovery_companions_remain_readable() {
        let w = World::new();
        w.stamp("r1");
        let parent = w.released_receipt("r1", "fix");
        w.plant_receipt("r1", &parent);
        assert_eq!(w.check("r1")["reason"], "valid");
        let mut child = parent.clone();
        child["validate"] = json!("pass");
        child["validate_mode"] = json!("full");
        child["validate_time"] = json!({"started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:00:00Z","seconds":0});
        child["recovery_of"] = json!("dev-return-issue-8-r1.json");
        let path = w.wt.join("tmp/dev-return-issue-8-r1-recovery.json");
        fs::write(&path, child.to_string()).unwrap();
        assert_eq!(w.check("r1")["verdict"], "accept");
        let companion = |child: &Value| {
            fs::write(&path, child.to_string()).unwrap();
            w.call(
                &["dev-return", "check"],
                "r1",
                &["--expect-items-from-round"],
            )
        };
        let mut other_parent = child.clone();
        other_parent["recovery_of"] = json!("another.json");
        refused(&companion(&other_parent), "recovery-invalid");
        let mut other_branch = child.clone();
        other_branch["branch"] = json!("elsewhere");
        refused(&companion(&other_branch), "recovery-invalid");
        fs::remove_file(&path).unwrap();
        // A run the round admitted with no proof recorded and no receipt of
        // its own leaves the round's bare receipt the answer.
        let mut doc = w.doc();
        doc["stages"].as_array_mut().unwrap().push(json!({"kind":"validate","round_id":"r1","start":5,"end":6,"outcome":"pass","run_dir":w.wt.join("tmp/dev-validate-bare")}));
        fs::write(w.item(), doc.to_string()).unwrap();
        assert_eq!(w.check("r1")["reason"], "valid");
    }

    #[test]
    fn recovery_reads_each_harness_return_channel_and_feeds_the_real_receipt_checker() {
        for channel in ["claude", "codex", "pi"] {
            let w = World::new();
            w.stamp("r1");
            let report = "| 1 | Applied | parser fixed |\nCommits: none\nValidate: FAILING: lint\nProposed rule: handle empty input";
            let transcript = w.transcript("r1", report, channel);
            let recovered = result(&w.call(
                &["round", "recover"],
                "r1",
                &["--transcript", transcript.to_str().unwrap()],
            ));
            assert_eq!(recovered["state"], "recovered", "{channel}");
            let artifact: Value = serde_json::from_str(
                &fs::read_to_string(recovered["artifact"].as_str().unwrap()).unwrap(),
            )
            .unwrap();
            assert_eq!(artifact["recovered_from"], "transcript");
            assert_eq!(artifact["summary_posted"], false);
            assert_eq!(artifact["commit"], w.head());
            assert!(
                artifact["summary"]
                    .as_str()
                    .unwrap()
                    .contains("### Proposed Rules")
            );
            assert_eq!(w.check("r1")["verdict"], "retry");
        }
        // Codex records the delegation as a user_message; the last field of
        // a report wins; the text answer names the artifact.
        let w = World::new();
        w.stamp("r1");
        let report = "| 1 | Applied | parser fixed |\nCommits: none\nValidate: pass\nValidate: FAILING: lint";
        let lines = [
            json!({"payload":{"type":"user_message","message":"Round ID: r1"}}),
            json!({"payload":{"type":"function_call","name":"send_input","arguments":json!({"message":report}).to_string()}}),
        ];
        let transcript = w.root.join("codex.jsonl");
        fs::write(
            &transcript,
            lines
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join("\n"),
        )
        .unwrap();
        let out = w
            .command()
            .args(["round", "--text", "recover"])
            .args(w.identity("r1"))
            .arg("--transcript")
            .arg(&transcript)
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        let artifact = text
            .trim()
            .strip_prefix("round-recover: recovered artifact=")
            .unwrap_or_else(|| panic!("{text} {}", stderr(&out)));
        let v: Value = serde_json::from_str(&fs::read_to_string(artifact).unwrap()).unwrap();
        assert_eq!(v["validate"], "FAILING: lint");
        // An implement report: its commit may be quoted, its QA labels kept;
        // the round's run is the newest over the receipt's tree.
        let implement = |w: &World| {
            let report = format!(
                "Branch: work\nCommit: `{}`\nQA: needs-review needs-test\nValidate: pass",
                w.head()
            );
            let file = w.transcript("r1", &report, "claude");
            result(&w.call(
                &["round", "recover"],
                "r1",
                &["--transcript", file.to_str().unwrap()],
            ))
        };
        let w = World::new();
        w.released_run("passed", "full");
        let recovered = implement(&w);
        let v: Value = serde_json::from_str(
            &fs::read_to_string(recovered["artifact"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        assert_eq!(v["qa_labels"], json!(["needs-review", "needs-test"]));
        let w = World::new();
        let stale = w.released_run("stale", "full");
        w.record_start(&stale, "tree=0000000000000000000000000000000000000000");
        assert_eq!(implement(&w)["reason"], "validate-unproven");
        let w = World::new();
        w.released_run("older", "full");
        let newer = w.released_run("newer", "full");
        fs::write(
            newer.join("start"),
            fs::read_to_string(newer.join("start"))
                .unwrap()
                .replace("start=1", "start=2"),
        )
        .unwrap();
        fs::write(newer.join("exit"), "guard-exit=1 at=2026-01-01T00:00:01Z\n").unwrap();
        assert_eq!(implement(&w)["reason"], "validate-unproven");
        // A worktree with no HEAD refuses on its git read.
        let w = World::new();
        let headless = w.root.join("headless");
        fs::create_dir_all(headless.join("tmp")).unwrap();
        git(&headless, &["init", "-q"]);
        let file = w.transcript(
            "r1",
            "Branch: work\nCommit: abc\nQA: none\nValidate: pass",
            "claude",
        );
        refused(
            &w.command()
                .args(["round", "recover"])
                .args(["--worktree", headless.to_str().unwrap()])
                .args(["--issue", "issue-8", "--round-id", "r1", "--transcript"])
                .arg(&file)
                .output()
                .unwrap(),
            "git-failed",
        );
    }

    #[test]
    fn recovery_uses_the_last_exact_marker_and_exhausts_one_redelegation() {
        let w = World::new();
        let path = w.transcript("r1x", "Validate: FAILING: lint", "codex");
        let out = w.call(
            &["round", "recover"],
            "r1",
            &["--transcript", path.to_str().unwrap()],
        );
        let first = result(&out);
        assert_eq!(out.status.code(), Some(3));
        assert_eq!(first["reason"], "no-report");
        let next = first["round_id"].as_str().unwrap();
        let before = w.doc();
        assert_eq!(
            result(&w.call(&["round", "recover"], "r1", &[]))["round_id"],
            next
        );
        assert_eq!(w.doc(), before);
        let exhausted = w.call(&["round", "recover"], next, &[]);
        assert_eq!(exhausted.status.code(), Some(1));
        assert_eq!(result(&exhausted)["state"], "exhausted");
        assert_eq!(w.doc(), before);
        let out = w.call(&["round", "recover"], next, &["--directive-unconfirmed"]);
        assert_eq!(out.status.code(), Some(3));
        assert_eq!(result(&out)["reason"], "directive-unconfirmed");
        assert_eq!(w.doc()["recovery_round_id"], next);
        // A round the item has moved past is not replaced again.
        refused(
            &w.call(&["round", "recover"], "r1-old", &[]),
            "round-superseded",
        );
        // The text answer is the line the workflow reads: the new id and the
        // round it replaces.
        let w = World::new();
        let out = w
            .command()
            .args(["round", "--text", "recover"])
            .args(w.identity("r1"))
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(3));
        let minted = w.doc()["dev_round_id"].as_str().unwrap().to_owned();
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).trim(),
            format!("round-recover: redelegate round-id={minted} from=r1 reason=no-transcript")
        );
        let out = w
            .command()
            .args(["round", "recover"])
            .args(["--worktree", w.wt.to_str().unwrap()])
            .args(["--issue", "issue-9", "--round-id", "r1"])
            .output()
            .unwrap();
        refused(&out, "record-missing");
    }

    struct Group(PathBuf);
    impl Drop for Group {
        fn drop(&mut self) {
            if let Ok(pid) = fs::read_to_string(&self.0) {
                let _ = program("kill")
                    .args(["-KILL", "--", &format!("-{}", pid.trim())])
                    .status();
            }
        }
    }

    fn until(what: &str, mut done: impl FnMut() -> bool) {
        let deadline = std::time::Instant::now() + Duration::from_secs(60);
        while !done() {
            assert!(std::time::Instant::now() < deadline, "{what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn a_released_bare_pid_run_holds_recovery_and_directive_replacement_stops_its_group_first() {
        // The shell producer's records: its runner record before the launch,
        // then the child's own pid, written by the child, whose argv ends in
        // the run directory. The child outlives `until`'s bound, so within
        // it only a stop ends the child; the group guard ends it otherwise.
        let live_run = |w: &World, name: &str| {
            let dir = w.released_run(name, "full");
            fs::remove_file(dir.join("exit")).unwrap();
            fs::write(
                dir.join("runner"),
                "runner=setsid\nline=runner=setsid reason=no-linger\n",
            )
            .unwrap();
            let pid_file = dir.join("pid");
            let group = Group(pid_file.clone());
            let started = program("setsid")
                .args([
                    "-f",
                    "sh",
                    "-c",
                    "echo $$ > \"$1\"; exec perl -e 'sleep 120' -- planted --child --run-dir \"$2\"",
                    "child",
                    pid_file.to_str().unwrap(),
                    dir.to_str().unwrap(),
                ])
                .status()
                .unwrap();
            assert!(started.success());
            until("the child recorded its pid", || {
                fs::read_to_string(&pid_file).is_ok_and(|p| p.ends_with('\n'))
            });
            let pid = fs::read_to_string(&pid_file).unwrap().trim().to_owned();
            (dir, group, pid)
        };
        let alive = |pid: &str| {
            program("kill")
                .args(["-0", pid])
                .status()
                .unwrap()
                .success()
        };
        let w = World::new();
        let (dir, _group, pid) = live_run(&w, "live");
        let before = w.doc();
        let out = w.call(&["round", "recover"], "r1", &[]);
        assert_eq!(out.status.code(), Some(4), "{}", stderr(&out));
        assert_eq!(result(&out)["state"], "round-live");
        assert_eq!(w.doc(), before);
        let unreadable = w.root.join("transcript-dir");
        fs::create_dir(&unreadable).unwrap();
        let unreadable = unreadable.to_str().unwrap();
        refused(
            &w.call(&["round", "recover"], "r1", &["--transcript", unreadable]),
            "transcript-unreadable",
        );
        let out = w.call(
            &["round", "recover"],
            "r1",
            &["--transcript", unreadable, "--directive-unconfirmed"],
        );
        assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
        assert!(out.stdout.is_empty());
        assert_eq!(w.doc(), before);
        let answer = result(&w.call(&["round", "recover"], "r1", &["--directive-unconfirmed"]));
        assert_eq!(answer["state"], "redelegate");
        assert_eq!(answer["reason"], "directive-unconfirmed");
        assert_eq!(
            fs::read_to_string(dir.join("stop")).unwrap(),
            "stop-requested\n"
        );
        until("the stop ended the child's group", || !alive(&pid));
        // A process that took the child's number under another argv is not
        // the run: it holds no recovery and a replacement never signals it.
        let w = World::new();
        let dir = w.released_run("other", "full");
        fs::remove_file(dir.join("exit")).unwrap();
        fs::write(
            dir.join("runner"),
            "runner=setsid\nline=runner=setsid reason=no-linger\n",
        )
        .unwrap();
        let other = support::Owned::sleep();
        fs::write(dir.join("pid"), format!("{}\n", other.pid())).unwrap();
        let out = w.call(&["round", "recover"], "r1", &[]);
        assert_eq!(out.status.code(), Some(3), "{}", stderr(&out));
        assert_eq!(result(&out)["reason"], "no-transcript");
        let answer = result(&w.call(&["round", "recover"], "r1", &["--directive-unconfirmed"]));
        assert_eq!(answer["state"], "redelegate");
        assert!(alive(&other.pid().to_string()), "the other process runs on");
        // A run still going over an earlier tree is not the round's run.
        let w = World::new();
        let (_, _group, pid) = live_run(&w, "earlier");
        w.commit("app.txt");
        w.released_run("own", "full");
        let out = w.call(&["round", "recover"], "r1", &[]);
        assert_eq!(out.status.code(), Some(3), "{}", stderr(&out));
        assert!(alive(&pid));
        // The item's own runs its stage loop does not stop, admitted with no
        // job yet or closed while their files run on, end before the
        // replacement too.
        for stage in [
            json!({"kind":"validate","round_id":"r1","start":1,"end":null}),
            json!({"kind":"validate","round_id":"r1","start":1,"end":2,"outcome":"fail"}),
        ] {
            let w = World::new();
            let (dir, _group, pid) = live_run(&w, "own-stage");
            let mut doc = w.doc();
            let mut stage = stage;
            stage["run_dir"] = json!(dir);
            doc["stages"].as_array_mut().unwrap().push(stage.clone());
            fs::write(w.item(), doc.to_string()).unwrap();
            let answer = result(&w.call(&["round", "recover"], "r1", &["--directive-unconfirmed"]));
            assert_eq!(answer["reason"], "directive-unconfirmed", "{stage}");
            until("the stop ended the item's own run", || !alive(&pid));
        }
    }

    #[test]
    fn recovery_contradicted_reports_redelegate_without_a_receipt() {
        for (report, reason) in [
            (
                "Branch: work\nCommit: badbad\nQA: none\nValidate: FAILING: lint",
                "commit-mismatch",
            ),
            ("Branch: work\nValidate: FAILING: lint", "unparsed"),
            ("Validate: no-verdict", "validate-unproven"),
            (
                "Branch: work\nCommit: abc\nQA: none\nValidate: pass",
                "commit-mismatch",
            ),
        ] {
            let w = World::new();
            let path = w.transcript("r1", report, "codex");
            assert_eq!(
                result(&w.call(
                    &["round", "recover"],
                    "r1",
                    &["--transcript", path.to_str().unwrap()]
                ))["reason"],
                reason
            );
            assert!(!w.receipt_path("r1").exists());
        }
        for rows in [
            "| 1 | Applied | x |\n| 1 | Skipped | duplicate |",
            "| 2 | Applied | invented |",
        ] {
            let w = World::new();
            w.stamp("r1");
            let report = format!("{rows}\nCommits: none\nValidate: FAILING: lint");
            let file = w.transcript("r1", &report, "claude");
            assert_eq!(
                result(&w.call(
                    &["round", "recover"],
                    "r1",
                    &["--transcript", file.to_str().unwrap()]
                ))["reason"],
                "unparsed"
            );
            assert!(!w.receipt_path("r1").exists());
        }
        // Each report is the round's first recovery: a replacement already
        // minted would answer every later call with its own reason.
        let recover = |w: &World, report: &str| {
            fs::write(w.item(), json!({"worktree":w.wt,"branch":"work","dev_round_id":"r1","stages":[{"kind":"dev","round_id":"r1","start":1,"end":null}]}).to_string()).unwrap();
            let file = w.transcript("r1", report, "claude");
            result(&w.call(
                &["round", "recover"],
                "r1",
                &["--transcript", file.to_str().unwrap()],
            ))
        };
        // An implement report needs its branch, commit, QA labels and a cause
        // for a bounded run, and its verdict is its round's run's.
        let w = World::new();
        let head = w.head();
        for (report, reason) in [
            ("Validate: no-verdict:   ".to_owned(), "validate-unproven"),
            (
                format!("Commit: {head}\nQA: none\nValidate: FAILING: lint"),
                "unparsed",
            ),
            (
                format!("Branch: work\nCommit: {head}\nValidate: FAILING: lint"),
                "unparsed",
            ),
        ] {
            assert_eq!(recover(&w, &report)["reason"], reason, "{report}");
            assert!(!w.receipt_path("r1").exists());
        }
        let pass = |w: &World| {
            format!(
                "Branch: work\nCommit: {}\nQA: none\nValidate: pass",
                w.head()
            )
        };
        let w = World::new();
        let failed = w.released_run("failed", "full");
        fs::write(
            failed.join("exit"),
            "guard-exit=1 at=2026-01-01T00:00:01Z\n",
        )
        .unwrap();
        assert_eq!(recover(&w, &pass(&w))["reason"], "validate-unproven");
        let w = World::new();
        let ci = w.released_run("ci", "full");
        fs::write(
            ci.join("start"),
            fs::read_to_string(ci.join("start"))
                .unwrap()
                .replace("validate-mode=full", "validate-mode=ci"),
        )
        .unwrap();
        w.record_start(&ci, &format!("tree={}", w.tree()));
        assert_eq!(recover(&w, &pass(&w))["state"], "recovered");
        // A fix report's rows and commits: every named commit after the base
        // and in HEAD, one of them HEAD, or none for an unmoved HEAD.
        let rows = "| 1 | Done | x |\n| 1 | Applied | y |";
        let w = World::new();
        w.stamp("r1");
        assert_eq!(
            recover(
                &w,
                &format!("{rows}\nCommits: none\nValidate: FAILING: lint")
            )["state"],
            "recovered"
        );
        let applied = "| 1 | Applied | y |";
        let w = World::new();
        w.commit("p.txt");
        w.stamp("r1");
        assert_eq!(
            recover(&w, &format!("{applied}\nValidate: FAILING: lint"))["reason"],
            "unparsed"
        );
        let base = w.head();
        assert_eq!(
            recover(
                &w,
                &format!("{applied}\nCommits: {base}\nValidate: FAILING: lint")
            )["reason"],
            "commit-mismatch"
        );
        let side = git(
            &w.wt,
            &["commit-tree", &w.tree(), "-p", &base, "-m", "side"],
        );
        w.commit("q1.txt");
        let first = w.head();
        w.commit("q2.txt");
        let head = w.head();
        for commits in [
            "none".to_owned(),
            "HEAD".to_owned(),
            "abcdef1".to_owned(),
            git(&w.wt, &["rev-parse", "main^{commit}"]) + " " + &head,
            format!("{side} {head}"),
            first.clone(),
        ] {
            assert_eq!(
                recover(
                    &w,
                    &format!("{applied}\nCommits: {commits}\nValidate: FAILING: lint")
                )["reason"],
                "commit-mismatch",
                "{commits}"
            );
        }
        assert_eq!(
            recover(
                &w,
                &format!("{applied}\nCommits: {first} {head}\nValidate: FAILING: lint")
            )["state"],
            "recovered"
        );
    }

    #[test]
    fn receipt_optional_fields_keep_unread_information_and_filter_wrong_shapes() {
        let w = World::new();
        w.stamp("r1");
        let good = w.released_receipt("r1", "fix");
        for (field, input, expected) in [
            (
                "near_ceiling",
                json!(["binary: near", 0]),
                json!(["binary: near"]),
            ),
            ("near_ceiling", Value::Null, Value::Null),
            ("near_ceiling", json!("wrong"), json!([])),
            (
                "screenshots",
                json!(["/a", false, "/b"]),
                json!(["/a", "/b"]),
            ),
            ("screenshots", json!("wrong"), json!([])),
            (
                "validate_selection",
                json!("unreported"),
                json!("unreported"),
            ),
            ("validate_class_base", json!("abc"), json!("abc")),
            ("near_ceiling_error", json!(5), Value::Null),
        ] {
            let mut value = good.clone();
            value[field] = input;
            w.plant_receipt("r1", &value);
            assert_eq!(w.check("r1")[field], expected, "{field}");
        }
    }

    #[test]
    fn malformed_round_records_never_supply_the_expected_items() {
        let w = World::new();
        w.stamp("r1");
        w.plant_receipt("r1", &w.released_receipt("r1", "fix"));
        let path = w.round_path("r1");
        let good: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        for (field, value, key) in [
            ("round_id", json!("another"), "round-mismatch"),
            ("schema_version", json!(1), "round-schema"),
            ("issue", json!("another"), "round-schema"),
            ("base_sha", json!("abc"), "round-schema"),
            ("adds", json!(["../bad"]), "round-schema"),
            ("adds", json!(["x", "x"]), "round-schema"),
            ("adds", json!(["-x"]), "round-schema"),
            ("adds", json!(["a b"]), "round-schema"),
            ("base_sha", json!("a".repeat(41)), "round-schema"),
            ("cut", json!("yes"), "round-schema"),
            ("pr_open", Value::Null, "round-schema"),
            ("items", json!([]), "round-schema"),
            ("items", json!([{"n":1,"text":""}]), "round-schema"),
        ] {
            let mut bad = good.clone();
            bad[field] = value;
            fs::write(&path, bad.to_string()).unwrap();
            refused(
                &w.call(
                    &["dev-return", "check"],
                    "r1",
                    &["--expect-items-from-round"],
                ),
                key,
            );
        }
        let check = || {
            w.call(
                &["dev-return", "check"],
                "r1",
                &["--expect-items-from-round"],
            )
        };
        fs::write(&path, "not json").unwrap();
        refused(&check(), "round-json");
        let copy = w.root.join("round-copy.json");
        fs::write(&copy, good.to_string()).unwrap();
        fs::remove_file(&path).unwrap();
        refused(&check(), "round-missing");
        std::os::unix::fs::symlink(&copy, &path).unwrap();
        refused(&check(), "round-missing");
    }

    #[test]
    fn the_apple_gate_reads_the_base_workflow_and_committed_project_members() {
        for (path, manifest, trigger) in [
            ("macos/App.swift", None, true),
            (
                "Package.swift",
                Some("let platforms = [.macOS(.v14)]\n"),
                true,
            ),
            (
                "Sources/App.swift",
                Some(
                    "{ objects = { A = { isa = PBXFileReference; path = Sources/App.swift; }; }; }",
                ),
                true,
            ),
            ("Sources/App.swift", Some("{ unfinished"), true),
            ("src/app.rs", None, false),
        ] {
            let w = World::new();
            git(&w.wt, &["switch", "-q", "main"]);
            fs::create_dir_all(w.wt.join(".github/workflows")).unwrap();
            fs::write(w.wt.join(".github/workflows/mac-run.yml"), "name: mac\n").unwrap();
            if let Some(manifest) = manifest
                && path != "Package.swift"
            {
                fs::create_dir_all(w.wt.join("App.xcodeproj")).unwrap();
                fs::write(w.wt.join("App.xcodeproj/project.pbxproj"), manifest).unwrap();
            }
            git(&w.wt, &["add", "."]);
            git(&w.wt, &["commit", "-qm", "apple workflow"]);
            git(&w.wt, &["switch", "-q", "work"]);
            git(&w.wt, &["merge", "-q", "main"]);
            w.stamp("r1");
            w.commit(path);
            if path == "Package.swift" {
                fs::write(w.wt.join(path), manifest.unwrap()).unwrap();
                git(&w.wt, &["commit", "-qam", "manifest"]);
            }
            refused(
                &w.write(
                    "r1",
                    "fix",
                    "no-verdict",
                    &["--validate-note", "host", "--item", "1", "Applied", "x"],
                ),
                "required",
            );
            let run = w.released_run("apple", "full");
            let dir = run.to_str().unwrap();
            refused(
                &w.write(
                    "r1",
                    "fix",
                    "pass",
                    &["--validate-run-dir", dir, "--item", "1", "Applied", "x"],
                ),
                "labels-undeclared",
            );
            let out = w.write(
                "r1",
                "fix",
                "pass",
                &[
                    "--validate-run-dir",
                    dir,
                    "--no-labels",
                    "--item",
                    "1",
                    "Applied",
                    "x",
                ],
            );
            if trigger {
                refused(&out, "mac-run-missing");
            } else {
                result(&out);
            }
            result(&w.write(
                "r1",
                "fix",
                "pass",
                &[
                    "--validate-run-dir",
                    dir,
                    "--no-labels",
                    "--validate-note",
                    "mac run test: pass run=123",
                    "--item",
                    "1",
                    "Applied",
                    "x",
                ],
            ));
            let report = format!(
                "| 1 | Applied | checked |\nCommits: {}\nValidate: pass",
                w.head()
            );
            let transcript = w.transcript("r1", &report, "claude");
            assert_eq!(
                result(&w.call(
                    &["round", "recover"],
                    "r1",
                    &["--transcript", transcript.to_str().unwrap()]
                ))["reason"],
                "mac-run-unproven"
            );
        }
        // Each world is private to its case: its base branch and the work
        // the receipt's commit adds over it.
        let world = |base: &[(&str, &str)], work: &[(&str, Option<&str>)]| {
            let w = World::new();
            git(&w.wt, &["switch", "-q", "main"]);
            for (path, text) in base {
                let file = w.wt.join(path);
                fs::create_dir_all(file.parent().unwrap()).unwrap();
                fs::write(&file, text).unwrap();
                git(&w.wt, &["add", path]);
            }
            git(&w.wt, &["commit", "-q", "--allow-empty", "-m", "base"]);
            git(&w.wt, &["switch", "-q", "work"]);
            git(&w.wt, &["merge", "-q", "main"]);
            for (path, text) in work {
                match text {
                    Some(text) => {
                        let file = w.wt.join(path);
                        fs::create_dir_all(file.parent().unwrap()).unwrap();
                        fs::write(&file, text).unwrap();
                        git(&w.wt, &["add", path]);
                    }
                    None => {
                        git(&w.wt, &["rm", "-q", path]);
                    }
                }
            }
            git(&w.wt, &["commit", "-q", "--allow-empty", "-m", "work"]);
            w
        };
        let wf = (".github/workflows/mac-run.yml", "name: mac\n");
        let ios = [("ios/App.swift", Some("change\n"))];
        let notes = [("notes.txt", Some("change\n"))];
        let project = |text: &'static str| ("App.xcodeproj/project.pbxproj", text);
        let pass = |w: &World, env: &[(&str, &str)], extra: &[&str]| {
            let run = w.released_run("apple", "full");
            let head = w.head();
            w.command()
                .envs(env.iter().copied())
                .args(["dev-return", "write"])
                .args(w.identity("r1"))
                .args(["--kind", "implement", "--branch", "work", "--commit", &head])
                .args(["--validate", "pass", "--validate-run-dir"])
                .arg(run)
                .args(extra)
                .output()
                .unwrap()
        };
        let none: &[(&str, &str)] = &[];
        let gate = "mac-run-missing";
        for (label, w, env, extra, expect) in [
            (
                "an ios/ path",
                world(&[wf], &ios),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "the configured workflow",
                world(&[(".github/workflows/apple.yml", "name: apple\n")], &ios),
                &[("ORCH_APPLE_WORKFLOW", ".github/workflows/apple.yml")][..],
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "a workflow the base branch lacks",
                world(
                    &[],
                    &[(wf.0, Some(wf.1)), ("ios/App.swift", Some("change\n"))],
                ),
                none,
                vec![],
                None,
            ),
            (
                "the ios label",
                world(&[wf], &notes),
                none,
                vec!["--label", "ios"],
                Some(gate),
            ),
            (
                "a configured label",
                world(&[wf], &notes),
                &[("ORCH_APPLE_LABELS", "apple-x")][..],
                vec!["--label", "apple-x"],
                Some(gate),
            ),
            (
                "a default label outside the configured set",
                world(&[wf], &notes),
                &[("ORCH_APPLE_LABELS", "apple-x")][..],
                vec!["--label", "ios"],
                None,
            ),
            (
                "an .xcodeproj path",
                world(&[wf], &[("App.xcodeproj/notes.txt", Some("x\n"))]),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "an .xcworkspace path",
                world(
                    &[wf],
                    &[("App.xcworkspace/contents.xcworkspacedata", Some("x\n"))],
                ),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "a file named ios",
                world(&[wf], &[("docs/ios", Some("x\n"))]),
                none,
                vec!["--no-labels"],
                None,
            ),
            (
                "a move out of ios/",
                world(
                    &[wf, ("ios/Moved.swift", "moved\n")],
                    &[
                        ("ios/Moved.swift", None),
                        ("src/Moved.swift", Some("moved\n")),
                    ],
                ),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "a Package.swift naming .iOS",
                world(
                    &[wf],
                    &[("Package.swift", Some("platforms: [.iOS(.v17)]\n"))],
                ),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "a Package.swift naming neither platform",
                world(
                    &[wf],
                    &[("Package.swift", Some("platforms: [.watchOS(.v10)]\n"))],
                ),
                none,
                vec!["--no-labels"],
                None,
            ),
            (
                "a synchronized folder member",
                world(
                    &[
                        wf,
                        project(
                            "{ objects = { A = { isa = PBXFileSystemSynchronizedRootGroup; path = Features; }; }; }",
                        ),
                    ],
                    &[("Features/New.swift", Some("x\n"))],
                ),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "a member by its name",
                world(
                    &[
                        wf,
                        project(
                            "{ objects = { A = { isa = PBXFileReference; name = Greeting.swift; }; }; }",
                        ),
                    ],
                    &[("App/Greeting.swift", Some("x\n"))],
                ),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "a member name with an escape the reader cannot decode",
                world(
                    &[
                        wf,
                        project(
                            r#"{ objects = { A = { isa = PBXFileReference; path = "Caf\U00e9.swift"; }; }; }"#,
                        ),
                    ],
                    &[("App/Café.swift", Some("x\n"))],
                ),
                none,
                vec!["--no-labels"],
                Some(gate),
            ),
            (
                "an undecodable escape in a build script",
                world(
                    &[
                        wf,
                        project(
                            r#"{ objects = { B = { isa = PBXShellScriptBuildPhase; shellScript = "printf \"done\n\""; }; }; }"#,
                        ),
                    ],
                    &notes,
                ),
                none,
                vec!["--no-labels"],
                None,
            ),
            (
                "an undecodable escape in a group",
                world(
                    &[
                        wf,
                        project(
                            r#"{ objects = { G = { isa = PBXGroup; path = "Caf\U00e9"; }; }; }"#,
                        ),
                    ],
                    &notes,
                ),
                none,
                vec!["--no-labels"],
                None,
            ),
            (
                "a group path is no member",
                world(
                    &[
                        wf,
                        project("{ objects = { G = { isa = PBXGroup; path = Lib; }; }; }"),
                    ],
                    &[("Lib/x.swift", Some("x\n"))],
                ),
                none,
                vec!["--no-labels"],
                None,
            ),
            (
                "a Linux package source",
                world(&[wf], &[("Sources/App/main.swift", Some("x\n"))]),
                none,
                vec!["--no-labels"],
                None,
            ),
            (
                "text before the pass line",
                world(&[wf], &ios),
                none,
                vec![
                    "--no-labels",
                    "--validate-note",
                    "x mac run test: pass run=1",
                ],
                Some(gate),
            ),
            (
                "text after the run id",
                world(&[wf], &ios),
                none,
                vec![
                    "--no-labels",
                    "--validate-note",
                    "mac run test: pass run=1 then",
                ],
                Some(gate),
            ),
            (
                "the pass line below a scoped note",
                world(&[wf], &ios),
                none,
                vec![
                    "--no-labels",
                    "--validate-note",
                    "scoped suites green\nmac run test: pass run=4242",
                ],
                None,
            ),
        ] {
            let out = pass(&w, env, &extra);
            let answer: Value = serde_json::from_slice(&out.stdout)
                .unwrap_or_else(|e| panic!("{label}: {e}: {}", stderr(&out)));
            assert_eq!(
                answer["refusal"]["key"].as_str(),
                expect,
                "{label}: {answer} {}",
                stderr(&out)
            );
            assert_eq!(out.status.success(), expect.is_none(), "{label}");
        }
        // A FAILING return needs no Mac proof; a bounded run needs it as a
        // pass does; a label beside --no-labels is refused at the arguments.
        let w = world(&[wf], &ios);
        result(&w.write("r1", "implement", "FAILING: mac run test", &[]));
        let w = world(&[wf], &ios);
        let stopped = w.released_run("stopped", "full");
        fs::write(
            stopped.join("exit"),
            "guard-exit=143 at=2026-01-01T00:00:01Z\n",
        )
        .unwrap();
        fs::write(stopped.join("stop"), "stop-requested\n").unwrap();
        refused(
            &w.write(
                "r1",
                "implement",
                "no-verdict",
                &[
                    "--validate-run-dir",
                    stopped.to_str().unwrap(),
                    "--validate-note",
                    "host",
                    "--no-labels",
                ],
            ),
            gate,
        );
        let out = pass(&w, none, &["--label", "skills", "--no-labels"]);
        assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
        assert!(out.stdout.is_empty());
        // A project listed at the base whose contents git cannot read cannot
        // rule out Mac work.
        let w = world(&[wf, project("{ objects = {}; }")], &notes);
        let blob = git(&w.wt, &["rev-parse", "HEAD:App.xcodeproj/project.pbxproj"]);
        let objects = PathBuf::from(git(
            &w.wt,
            &[
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "objects",
            ],
        ));
        fs::remove_file(objects.join(&blob[..2]).join(&blob[2..])).unwrap();
        refused(&pass(&w, none, &["--no-labels"]), gate);
    }

    #[test]
    fn rebased_round_additions_use_the_shared_map_without_consuming_it() {
        let w = World::new();
        w.commit("old.txt");
        let old = w.head();
        w.stamp("r1");
        git(&w.wt, &["switch", "-qc", "replacement", "main"]);
        w.commit("new.txt");
        let new = w.head();
        w.commit("tools/new");
        let receipt = w.released_receipt("r1", "fix");
        w.plant_receipt("r1", &receipt);
        assert_eq!(w.check("r1")["reason"], "additions_unattributable");
        let map = PathBuf::from(git(
            &w.wt,
            &[
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "kendex-rebase-map",
            ],
        ));
        fs::create_dir(&map).unwrap();
        assert_eq!(w.check("r1")["reason"], "comparison_failed");
        fs::remove_dir(&map).unwrap();
        let bound = |name: &str, head: &str| {
            let run = w.released_run(name, "full");
            fs::write(
                run.join("start"),
                fs::read_to_string(run.join("start"))
                    .unwrap()
                    .replace(&format!("head={}", w.head()), &format!("head={head}")),
            )
            .unwrap();
            w.record_start(&run, &format!("tree={}", w.tree()));
            w.write(
                "r1",
                "fix",
                "pass",
                &[
                    "--validate-run-dir",
                    run.to_str().unwrap(),
                    "--item",
                    "1",
                    "Applied",
                    "x",
                ],
            )
        };
        let head = w.head();
        refused(&bound("unmapped", &head), "run-off-round");
        let content = format!("rebase-hop:\nrebase-map: {old} {new}\n");
        fs::write(&map, &content).unwrap();
        assert_eq!(w.check("r1")["reason"], "unapproved_additions");
        assert_eq!(fs::read_to_string(&map).unwrap(), content);
        // A mapped base the work no longer contains attributes nothing.
        let main = git(&w.wt, &["rev-parse", "main"]);
        let side = git(
            &w.wt,
            &["commit-tree", &w.tree(), "-p", &main, "-m", "side"],
        );
        fs::write(&map, format!("rebase-hop:\nrebase-map: {old} {side}\n")).unwrap();
        assert_eq!(w.check("r1")["reason"], "additions_unattributable");
        fs::write(&map, &content).unwrap();
        // The receipt's run binds through the mapped base only where its own
        // head contains it.
        result(&bound("mapped", &head));
        refused(&bound("before-map", &main), "run-off-round");
    }

    #[test]
    fn receipt_cost_and_findings_are_recorded_once_even_when_another_gate_retries() {
        let w = World::new();
        w.stamp("r1");
        w.commit("tools/new");
        let mut value = w.released_receipt("r1", "fix");
        value["validate_mode"] = json!("full");
        value["validate_time"] = json!({"started_at":"2026-01-01T00:00:00Z","ended_at":"2026-01-01T00:00:01Z","seconds":1});
        w.plant_receipt("r1", &value);
        assert_eq!(w.check("r1")["reason"], "unapproved_additions");
        let before = w.doc();
        assert_eq!(before["stages"][0]["kind"], "fix");
        assert!(before["stages"][0]["end"].is_null());
        assert_eq!(before["validate_rounds"][0]["seconds"], 1);
        assert_eq!(before["finding_occurrences"]["records"][0]["check"], "lint");
        w.check("r1");
        assert_eq!(w.doc(), before);
        let state = w.item();
        let lock = state.with_file_name("workflow-state-issue-8.json.lock");
        if lock.exists() {
            fs::remove_file(&lock).unwrap();
        }
        fs::set_permissions(
            &w.state,
            <fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o555),
        )
        .unwrap();
        let out = w.call(
            &["dev-return", "check"],
            "r1",
            &["--expect-items-from-round"],
        );
        fs::set_permissions(
            &w.state,
            <fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(0o755),
        )
        .unwrap();
        let answer = result(&out);
        assert_eq!(answer["reason"], "unapproved_additions");
        assert!(answer["record_warning"].is_string());
    }

    #[test]
    fn runtime_entries_delegate_arguments_and_preserve_the_plain_answer_contract() {
        let w = World::new();
        let key_lib = scripts().join("../../agent-runtime/scripts/lib/key.sh");
        let runtime = Path::new(env!("CARGO_MANIFEST_DIR"));
        let out = program("/bin/bash")
            .args(["-c", ". \"$1\"; agent_runtime_key \"$2\"", "key"])
            .arg(key_lib)
            .arg(runtime)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        let key = String::from_utf8(out.stdout).unwrap().trim().to_owned();
        let cache = w.root.join("cache");
        fs::create_dir_all(cache.join("bin")).unwrap();
        // Copied by a child: a file this process held open for writing would
        // be held by every other test thread's child between its fork and
        // its exec, and running the copy then fails `ETXTBSY`.
        let copied = program("cp")
            .arg(support::binary())
            .arg(cache.join(format!("bin/orch-runtime-{key}")))
            .status()
            .unwrap();
        assert!(copied.success());
        w.stamp("r1");
        let out = program(scripts().join("dev-artifact-check"))
            .current_dir(&w.wt)
            .args(w.identity("r1"))
            .arg("--expect-items-from-round")
            .env("AGENT_RUNTIME_CACHE", &cache)
            .env("ORCH_STATE_DIR", &w.state)
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(1));
        let v: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(v["verdict"], "wait");
        // A value that begins with a hyphen is prose, not a flag.
        let out = w.call(
            &["round", "--text", "stamp"],
            "dash",
            &["--item", "1", "- the parser drops input", "- CLI input"],
        );
        assert!(out.status.success(), "{}", stderr(&out));
        let round: Value = serde_json::from_str(
            &fs::read_to_string(String::from_utf8_lossy(&out.stdout).trim()).unwrap(),
        )
        .unwrap();
        assert_eq!(round["items"][0]["text"], "- the parser drops input");
        let head = w.head();
        let out = w.call(
            &["dev-return", "--text", "write"],
            "dash",
            &[
                "--kind",
                "fix",
                "--branch",
                "work",
                "--commit",
                &head,
                "--validate",
                "FAILING: lint",
                "--validate-note",
                "-y caveat",
                "--summary",
                "-x summary",
                "--no-summary",
                "--item",
                "1",
                "Skipped",
                "-- not reproducible",
            ],
        );
        assert!(out.status.success(), "{}", stderr(&out));
        let receipt: Value = serde_json::from_str(
            &fs::read_to_string(String::from_utf8_lossy(&out.stdout).trim()).unwrap(),
        )
        .unwrap();
        assert_eq!(receipt["items"][0]["reasoning"], "-- not reproducible");
        assert_eq!(receipt["summary"], "-x summary");
        assert_eq!(receipt["validate_note"], "-y caveat");
    }

    #[test]
    fn the_receipt_reads_the_real_byte_ceiling_probe_and_keeps_an_unread_probe_unknown() {
        let w = World::new();
        fs::create_dir_all(w.wt.join(".agents/skills")).unwrap();
        std::os::unix::fs::symlink(
            scripts()
                .join("../../commit-guards")
                .canonicalize()
                .unwrap(),
            w.wt.join(".agents/skills/commit-guards"),
        )
        .unwrap();
        fs::write(w.wt.join("asset.bin"), vec![0u8; 950]).unwrap();
        git(&w.wt, &["add", "asset.bin"]);
        git(&w.wt, &["commit", "-qm", "asset"]);
        let args = [
            "dev-return",
            "write",
            "--worktree",
            w.wt.to_str().unwrap(),
            "--issue",
            "issue-8",
            "--round-id",
            "asset",
            "--kind",
            "implement",
            "--branch",
            "work",
            "--commit",
            &w.head(),
            "--validate",
            "FAILING: test",
            "--near-ceiling-base",
            "main",
        ];
        let answer = result(
            &w.command()
                .env("COMMIT_GUARDS_BYTE_CEILING_KB", "1")
                .args(args)
                .output()
                .unwrap(),
        );
        let value: Value =
            serde_json::from_str(&fs::read_to_string(answer["path"].as_str().unwrap()).unwrap())
                .unwrap();
        assert_eq!(value["baseline_lines"], 1);
        assert!(
            value["near_ceiling"][0]
                .as_str()
                .unwrap()
                .starts_with("byte-ceiling: near-ceiling=asset.bin:950:1024:")
        );
        let mut bad_args = args;
        bad_args[7] = "bad-probe";
        let answer = result(
            &w.command()
                .env("COMMIT_GUARDS_BYTE_CEILING_KB", "invalid")
                .args(bad_args)
                .output()
                .unwrap(),
        );
        let value: Value =
            serde_json::from_str(&fs::read_to_string(answer["path"].as_str().unwrap()).unwrap())
                .unwrap();
        assert!(value["near_ceiling"].is_null());
        assert!(
            value["near_ceiling_error"]
                .as_str()
                .unwrap()
                .starts_with("byte-ceiling exit 2: "),
            "{value}"
        );
        // Each receipt records what the lane answered, or why it has no answer.
        let probe = |w: &World, round: &str, extra: &[&str], env: &[(&str, &str)]| {
            let head = w.head();
            let out = w
                .command()
                .env("COMMIT_GUARDS_BYTE_CEILING_KB", "1")
                .envs(env.iter().copied())
                .args(["dev-return", "write"])
                .args(w.identity(round))
                .args(["--kind", "implement", "--branch", "work", "--commit", &head])
                .args(["--validate", "FAILING: test"])
                .args(extra)
                .output()
                .unwrap();
            let answer = result(&out);
            let value: Value = serde_json::from_str(
                &fs::read_to_string(answer["path"].as_str().unwrap()).unwrap(),
            )
            .unwrap();
            (
                value["near_ceiling"].clone(),
                value["near_ceiling_error"].clone(),
            )
        };
        let base = ["--near-ceiling-base", "main"];
        let (near, _) = probe(&w, "one", &base, &[]);
        assert_eq!(near.as_array().unwrap().len(), 1, "{near}");
        fs::write(w.wt.join("big.bin"), vec![0u8; 2000]).unwrap();
        git(&w.wt, &["add", "big.bin"]);
        git(&w.wt, &["commit", "-qm", "big"]);
        let (near, error) = probe(&w, "over", &base, &[]);
        assert!(error.is_null(), "{error}");
        assert!(
            near[0]
                .as_str()
                .unwrap()
                .starts_with("byte-ceiling: near-ceiling=asset.bin:"),
            "{near}"
        );
        let w = World::new();
        assert_eq!(
            probe(&w, "unprobed", &[], &[]),
            (
                Value::Null,
                json!("byte-ceiling not probed: no --near-ceiling-base")
            )
        );
        assert_eq!(probe(&w, "absent", &base, &[]), (json!([]), Value::Null));
        let skills = w.wt.join(".agents/skills");
        fs::create_dir_all(&skills).unwrap();
        std::os::unix::fs::symlink(w.root.join("gone"), skills.join("commit-guards")).unwrap();
        assert_eq!(
            probe(&w, "broken", &base, &[]),
            (
                Value::Null,
                json!(format!(
                    "byte-ceiling broken link: {}",
                    skills.join("commit-guards").display()
                ))
            )
        );
        fs::remove_file(skills.join("commit-guards")).unwrap();
        let lane = skills.join("commit-guards/scripts/byte-ceiling");
        fs::create_dir_all(lane.parent().unwrap()).unwrap();
        fs::write(&lane, "#!/bin/sh\n").unwrap();
        let unexecutable = (
            Value::Null,
            json!(format!("byte-ceiling not executable: {}", lane.display())),
        );
        assert_eq!(probe(&w, "plain", &base, &[]), unexecutable);
        fs::remove_file(&lane).unwrap();
        std::os::unix::fs::symlink(w.root.join("gone"), &lane).unwrap();
        assert_eq!(probe(&w, "dangling", &base, &[]), unexecutable);
        // A baseline the shared measurement cannot read refuses the receipt.
        let head = w.head();
        refused(
            &w.command()
                .env("WORKTREE_DEFAULT_BRANCH", "absent")
                .args(["dev-return", "write"])
                .args(w.identity("unmeasured"))
                .args(["--kind", "implement", "--branch", "work", "--commit", &head])
                .args(["--validate", "FAILING: test"])
                .output()
                .unwrap(),
            "baseline-read",
        );
    }

    #[test]
    fn recovery_discards_a_return_before_the_last_delegation_marker() {
        let w = World::new();
        w.stamp("r1");
        let file = w.transcript(
            "r1",
            "| 1 | Applied | parser fixed |\nCommits: none\nValidate: FAILING: lint",
            "claude",
        );
        let mut transcript = fs::read_to_string(&file).unwrap();
        transcript.push('\n');
        transcript.push_str(
            &json!({"message":{"role":"user","content":"Round ID: r1\nReplacement instruction"}})
                .to_string(),
        );
        fs::write(&file, transcript).unwrap();
        let answer = result(&w.call(
            &["round", "recover"],
            "r1",
            &["--transcript", file.to_str().unwrap()],
        ));
        assert_eq!(answer["reason"], "no-report");
        assert!(!w.receipt_path("r1").exists());
    }

    #[test]
    fn recovery_waits_on_a_real_running_validation_and_stops_it_before_replacement() {
        let w = World::new();
        let hold = w.root.join("hold");
        let ready = w.root.join("ready");
        assert!(program("mkfifo").arg(&hold).status().unwrap().success());
        let started=result(&w.command().env("ARTIFACT_HOLD",&hold).env("ARTIFACT_READY",&ready).env("DEV_VALIDATE_CMD","printf ready > \"$ARTIFACT_READY\"; exec 9<>\"$ARTIFACT_HOLD\"; read -r -t 30 -u 9 release").args(["validate","start","--item","issue-8","--round","r1","--base","main","--mode","full","--poll","1"]).output().unwrap());
        let run = Validation(&w, started["run_dir"].as_str().unwrap().to_owned());
        let deadline = std::time::Instant::now() + Duration::from_secs(60);
        while !ready.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "validation did not reach its barrier"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        let out = w.call(&["round", "recover"], "r1", &[]);
        assert_eq!(out.status.code(), Some(4));
        assert_eq!(result(&out)["state"], "round-live");
        let answer = result(&w.call(&["round", "recover"], "r1", &["--directive-unconfirmed"]));
        assert_eq!(answer["state"], "redelegate");
        assert_eq!(answer["reason"], "directive-unconfirmed");
        // The run was ended through its stage's stop before the replacement
        // was minted: the stop recorded, the stage closed `stopped`.
        let doc = w.doc();
        let stage = doc["stages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["run_dir"] == run.1)
            .unwrap()
            .clone();
        assert!(stage["stop"].is_object(), "{stage}");
        assert!(stage["end"].is_u64(), "{stage}");
        assert_eq!(stage["outcome"], "stopped", "{stage}");
        assert_ne!(doc["dev_round_id"], "r1");
        assert!(doc["recovery_round_id"].is_null());
    }

    #[test]
    fn a_missing_receipt_wait_ends_at_its_budget_on_the_injected_clock() {
        if !support::isolated_row(
            "dev_artifacts::a_missing_receipt_wait_ends_at_its_budget_on_the_injected_clock",
        ) {
            return;
        }
        let w = World::new();
        let flags = Flags {
            state_dir: Some(w.state.clone()),
            private_env: false,
        };
        let roots = Roots {
            project: w.wt.clone(),
            common: w.wt.clone(),
        };
        let settings = settings::load(&roots, &[], &flags).unwrap();
        let request = CheckReturn {
            file: None,
            worktree: Some(w.wt.clone()),
            issue: Some("issue-8".into()),
            round_id: Some("r1".into()),
            expect_items: None,
            expect_items_from_round: false,
            wait: 3,
            interval: 2,
        };
        let clock = Arc::new(support::FakeClock::new());
        let c = clock.clone();
        let thread = std::thread::spawn(move || receipt::check(&settings, &request, &*c).unwrap());
        clock.await_sleepers(1);
        clock.pass(Duration::from_secs(2));
        clock.release(Duration::from_secs(1));
        let answer = thread.join().unwrap();
        assert_eq!(answer.value["verdict"], "wait");
        assert_eq!(clock.elapsed(), Duration::from_secs(3));
        // A receipt that is there answers at once, whatever the budget left.
        w.plant_receipt("r1", &w.released_receipt("r1", "implement"));
        let settings = settings::load(&roots, &[], &flags).unwrap();
        let request = CheckReturn {
            file: None,
            worktree: Some(w.wt.clone()),
            issue: Some("issue-8".into()),
            round_id: Some("r1".into()),
            expect_items: None,
            expect_items_from_round: false,
            wait: 3,
            interval: 2,
        };
        let clock = Arc::new(support::FakeClock::new());
        let c = clock.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(receipt::check(&settings, &request, &*c).unwrap());
        });
        let answer = rx
            .recv_timeout(Duration::from_secs(30))
            .expect("a present receipt answers without waiting");
        assert_eq!(answer.value["reason"], "valid");
        assert_eq!(clock.elapsed(), Duration::ZERO);
    }

    /// The item's sentence that lets a round end with no change, as the
    /// worker quotes it from the description.
    const PERMIT: &str = "If no change is needed, record the comparison on the item and make no commit, test or pull request.";

    impl World {
        /// A Linear item keyed `key` whose round `r1` was delegated at the
        /// current HEAD, and, where `body` is given, the tracker's GraphQL
        /// answer for it with that description.
        fn linear_item(&self, key: &str, body: Option<&str>) {
            fs::write(
                self.state.join(format!("workflow-state-{key}.json")),
                json!({"worktree": self.wt, "branch": "work", "dev_round_id": "r1",
                       "pre_delegate_sha": self.head(),
                       "stages": [{"kind": "dev", "round_id": "r1", "start": 1, "end": null}]})
                .to_string(),
            )
            .unwrap();
            let items = self.root.join("items");
            fs::create_dir_all(&items).unwrap();
            if let Some(body) = body {
                let node = json!({"issue": {
                    "id": format!("uuid-{key}"), "identifier": key, "title": key,
                    "description": body, "state": {"name": "In Progress", "type": "started"},
                    "parent": null, "labels": {"nodes": []}, "children": {"nodes": []},
                    "relations": {"nodes": []}, "inverseRelations": {"nodes": []},
                }});
                fs::write(items.join(format!("{key}.json")), node.to_string()).unwrap();
            }
        }
        /// The command with the tracker CLI as the linear package's item
        /// read, its real bundle formatter over the planted answers.
        fn tracked(&self) -> Command {
            let mut command = self.command();
            command
                .env(
                    "OVERSEE_WATCH_TRACKER",
                    fixtures().join("linear-items/linear.sh"),
                )
                .env("LINEAR_ITEMS_DIR", self.root.join("items"))
                .env(
                    "LINEAR_FORMATTERS",
                    Path::new(env!("CARGO_MANIFEST_DIR"))
                        .join("../../linear/scripts/lib/formatters.sh"),
                )
                .env("LINEAR_FAKE_LOG", self.root.join("linear.log"));
            command
        }
        /// `dev-return --text write` of round `r1` of `key` at HEAD, its
        /// comparison as the summary, quoting `clause`.
        fn no_change(
            &self,
            key: &str,
            kind: &str,
            validate: &str,
            clause: &str,
            extra: &[&str],
        ) -> Output {
            let summary = self.wt.join(format!("tmp/completion-summary-{key}.md"));
            fs::write(
                &summary,
                "## Completion Summary\n\nThe comparison found the two equal.\n",
            )
            .unwrap();
            self.tracked()
                .args(["dev-return", "--text", "write", "--worktree"])
                .arg(&self.wt)
                .args(["--issue", key, "--round-id", "r1", "--kind", kind])
                .args(["--branch", "work", "--commit", &self.head()])
                .args(["--validate", validate, "--no-change", clause])
                .args(["--no-labels", "--summary-file"])
                .arg(&summary)
                .args(extra)
                .output()
                .unwrap()
        }
    }

    /// A round whose item permits ending with no change ends on its own:
    /// the receipt names the unmoved HEAD, the comparison and no check, the
    /// check answers `no-change`, and the round's close records that word.
    /// The defect: such a round could write no accepting receipt, so it
    /// ended only by asking its overseer.
    #[test]
    fn a_permitted_no_change_round_is_written_checked_and_closed_with_that_word() {
        let w = World::new();
        w.linear_item(
            "KEN-9",
            Some(
                "Compare the two.\n\nIf no change is needed, record the comparison on the item\nand make no commit, test or pull request.\n",
            ),
        );
        let head = w.head();
        let out = w.no_change("KEN-9", "implement", "not-run", PERMIT, &[]);
        assert!(out.status.success(), "{}", stderr(&out));
        let receipt: Value = serde_json::from_str(
            &fs::read_to_string(w.wt.join("tmp/dev-return-KEN-9-r1.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(receipt["validate"], "not-run");
        assert_eq!(receipt["validate_mode"], Value::Null);
        assert_eq!(receipt["validate_time"], Value::Null);
        assert_eq!(receipt["commit"], head.as_str());
        assert_eq!(receipt["no_change"], PERMIT);
        let check = |w: &World| {
            result(
                &w.command()
                    .args(["dev-return", "check", "--worktree"])
                    .arg(&w.wt)
                    .args(["--issue", "KEN-9", "--round-id", "r1"])
                    .output()
                    .unwrap(),
            )
        };
        let answer = check(&w);
        assert_eq!(answer["verdict"], "no-change", "{answer}");
        assert_eq!(answer["ok"], true);
        assert_eq!(answer["validate"], "not-run");
        assert_eq!(answer["no_change"], PERMIT);
        let request = write(
            &w.root,
            "close.json",
            r#"{"op": "accept-result", "round_id": "r1", "outcome": "no-change"}"#,
        );
        let closed = result(
            &w.command()
                .args(["op", "--item", "KEN-9", "--request"])
                .arg(&request)
                .output()
                .unwrap(),
        );
        assert_eq!(closed["report"]["outcome"], "no-change", "{closed}");
        let state: Value = serde_json::from_str(
            &fs::read_to_string(w.state.join("workflow-state-KEN-9.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(state["stages"][0]["kind"], "implement");
        assert_eq!(state["stages"][0]["outcome"], "no-change");
        assert!(state.get("validate_rounds").is_none(), "{state}");
        // A commit after the receipt moves the HEAD it named: the answer
        // that ends the item no longer holds.
        w.commit("app.txt");
        let answer = check(&w);
        assert_eq!(answer["verdict"], "retry");
        assert_eq!(answer["reason"], "head_moved");
    }

    /// A round that should have changed something cannot end as one that
    /// needed none: the item's text without the quoted sentence, a HEAD
    /// moved since the delegation, a dirty tree, a run or record beside the
    /// receipt, a fix round, a GitHub issue (whose end without a pull
    /// request has no owner) and an item the tracker did not answer each
    /// refuse with their key and write no receipt.
    #[test]
    fn a_no_change_receipt_is_refused_without_the_items_permission_beside_a_move_a_run_or_dirt() {
        let permitting = format!("Compare the two.\n\n{PERMIT}\n");
        let nothing: fn(&World) = |_| {};
        let moved: fn(&World) = |w| w.commit("app.txt");
        let dirty: fn(&World) = |w| fs::write(w.wt.join("stray.txt"), "stray\n").unwrap();
        // (key, the tracker's description, kind, validate, extra flags, the
        // world's change before the write, the refusal key)
        type Case<'a> = (
            &'a str,
            Option<&'a str>,
            &'a str,
            &'a str,
            &'a [&'a str],
            fn(&World),
            &'a str,
        );
        let cases: [Case<'_>; 8] = [
            (
                "KEN-9",
                Some("Compare the two and land the fix.\n"),
                "implement",
                "not-run",
                &[],
                nothing,
                "no-change-unpermitted",
            ),
            (
                "KEN-9",
                Some(&permitting),
                "implement",
                "not-run",
                &[],
                moved,
                "no-change-moved",
            ),
            (
                "KEN-9",
                Some(&permitting),
                "implement",
                "not-run",
                &[],
                dirty,
                "no-change-dirty",
            ),
            (
                "KEN-9",
                Some(&permitting),
                "implement",
                "pass",
                &[],
                nothing,
                "no-change-run",
            ),
            (
                "KEN-9",
                Some(&permitting),
                "implement",
                "not-run",
                &["--validate-record", "/nonexistent/record"],
                nothing,
                "no-change-run",
            ),
            (
                "KEN-9",
                Some(&permitting),
                "fix",
                "not-run",
                &[],
                nothing,
                "no-change-kind",
            ),
            (
                "issue-8",
                Some(&permitting),
                "implement",
                "not-run",
                &[],
                nothing,
                "no-change-tracker",
            ),
            (
                "KEN-9",
                None,
                "implement",
                "not-run",
                &[],
                nothing,
                "item-unread",
            ),
        ];
        for (key, body, kind, validate, extra, setup, want) in cases {
            let w = World::new();
            w.linear_item(key, body);
            setup(&w);
            let out = w.no_change(key, kind, validate, PERMIT, extra);
            assert_eq!(out.status.code(), Some(2), "{want}: {}", stderr(&out));
            assert!(
                stderr(&out).starts_with(&format!("dev-return-write: {want} ")),
                "{want}: {}",
                stderr(&out)
            );
            let receipts: Vec<_> = fs::read_dir(w.wt.join("tmp"))
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("dev-return-"))
                .collect();
            assert!(receipts.is_empty(), "{want}: {receipts:?}");
        }
    }
}

/// An operation patches only the keys it writes.
#[test]
fn begin_round_mints_supersedes_and_opens_in_one_write() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let before = object(&path);
    let applied = apply(&path, &begin(RoundKind::Dev), &env(), LOCK).unwrap();
    let Report::BeginRound(begun) = &applied.report else {
        panic!("{:?}", applied.report)
    };
    assert_eq!(begun.round_id, "1769700000123456789-4242");
    assert_eq!(begun.superseded, vec![Some(ROUND.to_owned())]);
    let after = object(&path);
    assert_eq!(keys(&after), keys(&before), "top-level key sequence");
    for (key, value) in &before {
        if key != "dev_round_id" && key != "stages" {
            assert_eq!(&after[key], value, "{key}");
        }
    }
    let body = item(&path);
    assert_eq!(body.dev_round_id.as_deref(), Some(begun.round_id.as_str()));
    assert_eq!(body.stages.len(), 2);
    assert_eq!(body.stages[0].end, Some(NOW_SECS));
    assert_eq!(body.stages[0].superseded, Some(true));
    assert_eq!(
        keys(after["stages"][0].as_object().unwrap()),
        ["kind", "round_id", "start", "end", "superseded"]
    );
    assert_eq!(
        keys(after["stages"][1].as_object().unwrap()),
        ["kind", "round_id", "start", "end"]
    );
    assert_eq!(body.stages[1].kind, StageKind::Dev);
    assert_eq!(body.stages[1].start, NOW_SECS);
    assert_eq!(body.stages[1].end, None);
    // A review round leaves the dev stage open.
    apply(&path, &begin(RoundKind::Review), &env(), LOCK).unwrap();
    let body = item(&path);
    assert_eq!(
        body.review_round_id.as_deref(),
        Some("1769700000123456789-4242")
    );
    assert_eq!(body.stages.len(), 3);
    assert_eq!(body.stages[1].end, None);
    assert_eq!(body.stages[2].kind, StageKind::Review);
}

/// The runtime mints the run's identity at admission, before
/// any runner starts, once per round. A repeat of the request, whatever
/// clock or nonce the call carries, returns the open admission and writes
/// nothing; `attempt: next` mints the rerun beside it; with no open
/// admission a plain request mints again.
#[test]
fn admission_is_idempotent_per_round_and_mints_the_next_attempt_on_request() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let err = run(&path, &admit("no-such-round", None)).unwrap_err();
    assert_eq!(err.key(), "round-unknown");
    assert_eq!(validate_stages(&path).len(), 0, "a refusal writes no stage");

    let a = admitted(apply(&path, &admit(ROUND, None), &env(), LOCK).unwrap());
    assert!(a.minted);
    assert!(a.admitted_now);
    assert_eq!(a.run_id, "20260129T152000Z-4242");
    assert_eq!(
        a.run_dir,
        format!("{WORKTREE}/tmp/dev-validate-20260129T152000Z-4242")
    );
    assert_eq!(a.start, NOW_SECS);
    // The id fits dev-validate-run's --run-id grammar and the run index
    // grammar lane-gitfile.sh reads (`^dev-validate-[A-Za-z0-9-]+$`).
    let (stamp, nonce) = a.run_id.split_once('-').unwrap();
    assert_eq!(stamp.len(), 16);
    assert!(stamp[..8].bytes().all(|b| b.is_ascii_digit()));
    assert_eq!(&stamp[8..9], "T");
    assert!(stamp[9..15].bytes().all(|b| b.is_ascii_digit()));
    assert_eq!(&stamp[15..], "Z");
    assert!(nonce.bytes().all(|b| b.is_ascii_alphanumeric()));
    let doc = object(&path);
    let rows = doc["stages"].as_array().unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        keys(rows[1].as_object().unwrap()),
        ["kind", "round_id", "start", "end", "run_dir"]
    );
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 1);
    assert_eq!(stages[0].round_id.as_deref(), Some(ROUND));
    assert_eq!(stages[0].run_dir.as_deref(), Some(a.run_dir.as_str()));
    assert_eq!(stages[0].end, None, "the stage stays open until the result");
    assert_eq!(stages[0].outcome, None);

    // The replayed delegation command, later and with another nonce, is
    // the same operation: the open admission, nothing minted or written.
    let same = admitted(run_at(&path, &admit(ROUND, None), NOW_SECS + 120).unwrap());
    assert!(!same.admitted_now);
    assert!(!same.minted);
    assert_eq!(same.run_id, a.run_id);
    assert_eq!(same.run_dir, a.run_dir);
    assert_eq!(same.start, NOW_SECS, "the first admission's start stands");
    assert_eq!(validate_stages(&path), stages, "the repeat wrote nothing");

    // The rerun the dev gate permits is the next attempt, asked for by
    // name: its own identity beside the open one.
    let b = admitted(run_at(&path, &admit_next(ROUND), NOW_SECS + 120).unwrap());
    assert!(b.admitted_now);
    assert!(b.minted);
    assert_ne!(b.run_dir, a.run_dir);
    assert_eq!(b.start, NOW_SECS + 120);
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 2);
    assert_eq!(stages[0].end, None);
    assert_eq!(stages[1].end, None);
    // Two next attempts in one second differ by their nonce, so neither
    // directory is the other's.
    let c = admitted(run_at(&path, &admit_next(ROUND), NOW_SECS + 120).unwrap());
    assert_ne!(c.run_id, b.run_id);
    assert_eq!(&c.run_id[..17], &b.run_id[..17], "same stamp");
    assert_eq!(validate_stages(&path).len(), 3);
    // A plain repeat now names the newest open attempt.
    let newest = admitted(run_at(&path, &admit(ROUND, None), NOW_SECS + 130).unwrap());
    assert!(!newest.admitted_now);
    assert_eq!(newest.run_dir, c.run_dir);

    // Once every admitted run of the round is closed, a plain request has
    // no open admission to return and mints again.
    for (run_dir, outcome) in [
        (&a.run_dir, StageOutcome::Fail),
        (&b.run_dir, StageOutcome::Lost),
        (&c.run_dir, StageOutcome::Fail),
    ] {
        run_at(
            &path,
            &accept(ROUND, Some(run_dir), outcome, None),
            NOW_SECS + 150,
        )
        .unwrap();
    }
    let d = admitted(run_at(&path, &admit(ROUND, None), NOW_SECS + 200).unwrap());
    assert!(d.admitted_now);
    assert!(d.minted);
    assert_eq!(d.start, NOW_SECS + 200);
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 4);
    assert_eq!(stages[0].outcome, Some(StageOutcome::Fail));
    assert_eq!(stages[3].end, None);

    // An item recording no worktree can name no directory: refused, with
    // nothing written.
    let bare = dir.path().join("workflow-state-KEN-1.json");
    fs::write(
        &bare,
        ITEM.replacen(
            &format!("\"worktree\": \"{WORKTREE}\""),
            "\"worktree\": \"\"",
            1,
        ),
    )
    .unwrap();
    let text = fs::read_to_string(&bare).unwrap();
    let err = run(&bare, &admit(ROUND, None)).unwrap_err();
    assert_eq!(err.key(), "worktree-unrecorded");
    assert_eq!(fs::read_to_string(&bare).unwrap(), text);
}

/// The runner minted the directory and the caller names it. The id is read from
/// the name, the caller's identity wins, and a repeat of the same directory is
/// a no-op with the same reply shape.
#[test]
fn a_runner_named_run_dir_is_admitted_as_given_and_repeats_as_a_no_op() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let given = "/w/tmp/dev-validate-20260129T152000Z-777";
    let a = admitted(apply(&path, &admit(ROUND, Some(given)), &env(), LOCK).unwrap());
    assert!(a.admitted_now);
    assert!(!a.minted, "the caller's identity won");
    assert_eq!(a.run_dir, given);
    assert_eq!(a.run_id, "20260129T152000Z-777");
    assert_eq!(a.start, NOW_SECS);
    let b = admitted(run_at(&path, &admit(ROUND, Some(given)), NOW_SECS + 60).unwrap());
    assert!(!b.admitted_now);
    assert!(!b.minted);
    assert_eq!(b.start, NOW_SECS, "the first admission's start stands");
    let stages = validate_stages(&path);
    assert_eq!(stages.len(), 1);
    assert_eq!(stages[0].run_dir.as_deref(), Some(given));
    assert_eq!(stages[0].end, None);
    // A directory named without the prefix is still the run's identity.
    let c = admitted(run(&path, &admit(ROUND, Some("/w/tmp/elsewhere"))).unwrap());
    assert!(c.admitted_now);
    assert_eq!(c.run_id, "elsewhere");
    assert_eq!(validate_stages(&path).len(), 2);
}

#[test]
fn accept_result_closes_the_round_stage_once_with_its_outcome() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    assert_eq!(
        run(&path, &accept("nope", None, StageOutcome::Pass, None))
            .unwrap_err()
            .key(),
        "round-unknown"
    );
    let applied = apply(
        &path,
        &accept(ROUND, None, StageOutcome::Pass, None),
        &env(),
        LOCK,
    )
    .unwrap();
    let Report::AcceptResult(a) = applied.report else {
        panic!("{:?}", applied.report)
    };
    assert!(a.closed_now);
    assert_eq!((a.start, a.end), (ROUND_START, NOW_SECS));
    assert_eq!(a.run_dir, None);
    assert_eq!(a.outcome, Some(StageOutcome::Pass));
    let doc = object(&path);
    assert_eq!(
        keys(doc["stages"][0].as_object().unwrap()),
        ["kind", "round_id", "start", "end", "outcome"]
    );
    assert_eq!(doc["stages"][0]["outcome"], "pass");
    // The repeat is a no-op: the recorded end and word, whatever it asks.
    let again = run_at(
        &path,
        &accept(ROUND, None, StageOutcome::Fail, None),
        NOW_SECS + 60,
    )
    .unwrap();
    let Report::AcceptResult(b) = again.report else {
        panic!("{:?}", again.report)
    };
    assert!(!b.closed_now);
    assert_eq!(b.end, NOW_SECS);
    assert_eq!(b.outcome, Some(StageOutcome::Pass));
    assert_eq!(object(&path)["stages"][0]["outcome"], "pass");
    // A superseded round's result is history, not the current round's.
    let path = item_file(dir.path());
    run(&path, &begin(RoundKind::Dev)).unwrap();
    let err = run(&path, &accept(ROUND, None, StageOutcome::Pass, None)).unwrap_err();
    assert_eq!(err.key(), "round-superseded");
    // A stage another writer closed without a word carries none; the reply
    // says so.
    let unworded = dir.path().join("workflow-state-KEN-2.json");
    fs::write(
        &unworded,
        ITEM.replacen("\"end\": null", "\"end\": 1769600900", 1),
    )
    .unwrap();
    let closed = run(&unworded, &accept(ROUND, None, StageOutcome::Pass, None)).unwrap();
    let Report::AcceptResult(c) = closed.report else {
        panic!("{:?}", closed.report)
    };
    assert!(!c.closed_now);
    assert_eq!(c.end, 1_769_600_900);
    assert_eq!(c.outcome, None);
}

/// A run that ended without a pass closes its admitted stage
/// with the word, so no admitted run stays open after it ended, and the
/// closed stage keeps its cost: its start, its end and the `validate_rounds`
/// row beside it.
#[test]
fn a_non_pass_outcome_closes_the_admitted_run_and_keeps_its_cost() {
    let dir = tempfile::tempdir().unwrap();
    let rows = [
        (StageOutcome::Fail, "fail"),
        (StageOutcome::NoVerdict, "no-verdict"),
        (StageOutcome::Lost, "lost"),
        (StageOutcome::Stopped, "stopped"),
    ];
    for (outcome, word) in rows {
        let path = item_file(dir.path());
        let a = admitted(apply(&path, &admit(ROUND, None), &env(), LOCK).unwrap());
        // The cost row dev-artifact-check writes for the round's receipt.
        let mut doc = object(&path);
        doc.insert(
            "validate_rounds".into(),
            json!([{"round_id": ROUND, "kind": "implement", "mode": "full", "seconds": 90}]),
        );
        fs::write(&path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
        let cost = doc["validate_rounds"].clone();

        let closed = apply(
            &path,
            &accept(ROUND, Some(&a.run_dir), outcome, None),
            &at(NOW_SECS + 90),
            LOCK,
        )
        .unwrap();
        let Report::AcceptResult(r) = closed.report else {
            panic!("{:?}", closed.report)
        };
        assert!(r.closed_now, "{word}");
        assert_eq!(r.kind, StageKind::Validate, "{word}");
        assert_eq!(r.outcome, Some(outcome), "{word}");
        assert_eq!((r.start, r.end), (NOW_SECS, NOW_SECS + 90), "{word}");
        let after = object(&path);
        let stage = after["stages"][1].as_object().unwrap();
        assert_eq!(
            keys(stage),
            ["kind", "round_id", "start", "end", "run_dir", "outcome"],
            "{word}"
        );
        assert_eq!(stage["outcome"], word);
        assert_eq!(stage["start"], NOW_SECS);
        assert_eq!(stage["end"], NOW_SECS + 90);
        assert_eq!(stage["run_dir"], a.run_dir);
        assert_eq!(
            after["validate_rounds"], cost,
            "{word}: the cost row stands"
        );
        assert_eq!(
            after["stages"][0]["end"],
            Value::Null,
            "{word}: the round's own stage stays open"
        );
        let stages = validate_stages(&path);
        assert_eq!(stages.len(), 1, "{word}");
        assert_eq!(stages[0].outcome, Some(outcome), "{word}");
        // A later pass on the closed run changes nothing: the first word
        // stands and the reply carries it.
        let again = run_at(
            &path,
            &accept(ROUND, Some(&a.run_dir), StageOutcome::Pass, None),
            NOW_SECS + 120,
        )
        .unwrap();
        let Report::AcceptResult(b) = again.report else {
            panic!("{:?}", again.report)
        };
        assert!(!b.closed_now, "{word}");
        assert_eq!(b.outcome, Some(outcome), "{word}");
        assert_eq!(b.end, NOW_SECS + 90, "{word}");
        assert_eq!(object(&path)["stages"][1]["outcome"], word);
        // Another run of the round is not this one.
        let err = run(
            &path,
            &accept(
                ROUND,
                Some("/w/tmp/dev-validate-9"),
                StageOutcome::Pass,
                None,
            ),
        )
        .unwrap_err();
        assert!(matches!(err, Error::RunUnknown { .. }), "{word}: {err}");
    }
}

/// The runtime stats the artifact the acceptance
/// rests on, and its modification time is the stage's end when it lies in
/// `[start, now]`; one outside is refused with the bounds, an artifact that
/// cannot be stat'ed is refused by name, and the file keeps its bytes.
#[test]
fn accept_result_end_is_read_from_the_artifact_and_bounded_to_the_stage_and_the_clock() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let text = fs::read_to_string(&path).unwrap();
    for (name, mtime) in [
        ("before-start", ROUND_START - 1),
        ("after-now", NOW_SECS + 1),
        ("epoch", 0),
    ] {
        let file = artifact(dir.path(), name, mtime);
        let err = apply(
            &path,
            &accept(ROUND, None, StageOutcome::Pass, Some(&file)),
            &env(),
            LOCK,
        )
        .unwrap_err();
        assert_eq!(err.key(), "end-out-of-range", "{name}");
        assert_eq!(
            err.fields(),
            vec![
                ("round_id".to_owned(), ROUND.to_owned()),
                ("end".to_owned(), mtime.to_string()),
                ("start".to_owned(), ROUND_START.to_string()),
                ("now".to_owned(), NOW_SECS.to_string()),
            ],
            "{name}"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "{name}");
    }
    // An artifact the runtime cannot stat is a refusal, never an end of now.
    let missing = dir.path().join("review-nobody-1.json");
    let err = apply(
        &path,
        &accept(ROUND, None, StageOutcome::Pass, Some(&missing)),
        &env(),
        LOCK,
    )
    .unwrap_err();
    assert_eq!(err.key(), "end-artifact-unreadable");
    assert_eq!(
        err.fields(),
        vec![("path".to_owned(), missing.display().to_string())]
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    // Both bounds are in range; the first close wins.
    for (mtime, label) in [(ROUND_START, "start"), (NOW_SECS, "now")] {
        let path = item_file(dir.path());
        let file = artifact(dir.path(), label, mtime);
        let applied = apply(
            &path,
            &accept(ROUND, None, StageOutcome::Pass, Some(&file)),
            &env(),
            LOCK,
        )
        .unwrap();
        let Report::AcceptResult(a) = applied.report else {
            panic!("{:?}", applied.report)
        };
        assert!(a.closed_now, "{label}");
        assert_eq!(a.end, mtime, "{label}");
        assert_eq!(object(&path)["stages"][0]["end"], mtime, "{label}");
    }
    // The review workflow's case: the review stage ends at the last
    // accepted artifact's time, not at the accept.
    let path = item_file(dir.path());
    let begun = run(&path, &begin(RoundKind::Review)).unwrap();
    let Report::BeginRound(review) = begun.report else {
        panic!("{:?}", begun.report)
    };
    let mtime = NOW_SECS + 300;
    let accepted = artifact(dir.path(), "review-a-1.json", mtime);
    let applied = apply(
        &path,
        &accept(&review.round_id, None, StageOutcome::Pass, Some(&accepted)),
        &at(NOW_SECS + 400),
        LOCK,
    )
    .unwrap();
    let Report::AcceptResult(a) = applied.report else {
        panic!("{:?}", applied.report)
    };
    assert_eq!(a.kind, StageKind::Review);
    assert_eq!(a.end, mtime);
    let newer = artifact(dir.path(), "review-b-1.json", mtime + 5);
    let later = run_at(
        &path,
        &accept(&review.round_id, None, StageOutcome::Pass, Some(&newer)),
        NOW_SECS + 500,
    )
    .unwrap();
    let Report::AcceptResult(b) = later.report else {
        panic!("{:?}", later.report)
    };
    assert!(!b.closed_now);
    assert_eq!(b.end, mtime, "the first end stands");
    // A no-op repeat is still held to the bounds: a stale request is a
    // request error, whatever the stage holds.
    let stale = artifact(dir.path(), "review-stale.json", 1);
    let err = run_at(
        &path,
        &accept(&review.round_id, None, StageOutcome::Pass, Some(&stale)),
        NOW_SECS + 500,
    )
    .unwrap_err();
    assert_eq!(err.key(), "end-out-of-range");
}

/// A child the test holds, so a planted pid names a process it owns; the
/// test reaps it at the end.
struct Owned(Child);

impl Owned {
    fn sleep() -> Owned {
        Owned(Command::new("sleep").arg("30").spawn().expect("sleep"))
    }
    fn pid(&self) -> u32 {
        self.0.id()
    }
    /// End the process without reaping it: the pid stays this child's, as
    /// a zombie, until the drop reaps it.
    fn end(&mut self) {
        self.0.kill().expect("kill");
        // The kernel turns the process into a zombie once the signal
        // lands; wait on that state, read as the runtime reads it, without
        // reaping it.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while matches!(
            agent_runtime::process::identity(self.pid()),
            agent_runtime::reading::Reading::Live(_)
        ) {
            assert!(
                std::time::Instant::now() < deadline,
                "the child did not end"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// A run directory as `dev-validate-run` leaves it: its `start` record and
/// the files the row plants.
fn run_dir(path: &str, files: &[(&str, String)]) -> PathBuf {
    let dir = PathBuf::from(path);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("start"), format!("start={NOW_SECS}\nhead=abc\n")).unwrap();
    for (name, text) in files {
        fs::write(dir.join(name), text).unwrap();
    }
    dir
}

fn state_of(report: &Report, run_dir: &str) -> RunState {
    let Report::ReconcileRound(r) = report else {
        panic!("{report:?}")
    };
    r.runs
        .iter()
        .find(|run| run.run_dir == run_dir)
        .unwrap_or_else(|| panic!("no row for {run_dir} in {:?}", r.runs))
        .state
        .clone()
}

fn closed(outcome: StageOutcome, cause: RunCause, seconds: Option<u64>) -> RunState {
    RunState::Closed {
        outcome,
        cause,
        seconds,
    }
}

/// The reconcile closes every admitted run that will not
/// end on its own, with the word the host supports, keeps a live run open
/// and reports what it could not read, and touches no cost.
#[test]
fn reconcile_round_closes_every_ended_or_lost_run_and_keeps_a_live_one_open() {
    let dir = tempfile::tempdir().unwrap();
    let worktree = dir.path().join("wt");
    fs::create_dir_all(worktree.join("tmp")).unwrap();
    let path = dir.path().join("workflow-state-KEN-4687.json");
    fs::write(
        &path,
        ITEM.replacen(
            &format!("\"worktree\": \"{WORKTREE}\""),
            &format!("\"worktree\": \"{}\"", worktree.display()),
            1,
        ),
    )
    .unwrap();
    assert_eq!(
        run(&path, &reconcile("no-such-round")).unwrap_err().key(),
        "round-unknown"
    );
    // Nine attempts of the round, each admitted at its own second.
    let mut runs = Vec::new();
    for i in 0..9 {
        let request = if i == 0 {
            admit(ROUND, None)
        } else {
            admit_next(ROUND)
        };
        runs.push(admitted(run_at(&path, &request, NOW_SECS + i).unwrap()).run_dir);
    }
    let [
        live,
        refused,
        gone,
        failing,
        bounded,
        passing,
        unlaunched,
        garbled,
        skewed,
    ] = <[String; 9]>::try_from(runs).unwrap();
    let mut live_child = Owned::sleep();
    run_dir(&live, &[("pid", format!("{}\n", live_child.pid()))]);
    // `refused`: the start was refused; the directory never came to be.
    let mut gone_child = Owned::sleep();
    run_dir(&gone, &[("pid", format!("{}\n", gone_child.pid()))]);
    gone_child.end();
    let iso = |secs: u64| at(secs).iso();
    run_dir(
        &failing,
        &[
            ("pid", "1\n".to_owned()),
            ("exit", format!("guard-exit=1 at={}\n", iso(NOW_SECS + 60))),
            (
                "timing",
                format!(
                    "started-at={}\nended-at={}\nseconds=55\n",
                    iso(NOW_SECS + 5),
                    iso(NOW_SECS + 60)
                ),
            ),
        ],
    );
    run_dir(
        &bounded,
        &[(
            "exit",
            format!(
                "guard-exit=3 at={} verdict=no-verdict cause=host\n",
                iso(NOW_SECS + 70)
            ),
        )],
    );
    run_dir(
        &passing,
        &[("exit", format!("guard-exit=0 at={}\n", iso(NOW_SECS + 80)))],
    );
    run_dir(&unlaunched, &[]);
    run_dir(&garbled, &[("exit", "not a sentinel\n".to_owned())]);
    // A sentinel time before the stage started: a clock the runner and this
    // host disagree on yields to the reconcile's.
    run_dir(
        &skewed,
        &[("exit", format!("guard-exit=1 at={}\n", iso(ROUND_START)))],
    );
    // The cost row dev-artifact-check writes for the round's receipt.
    let mut doc = object(&path);
    doc.insert(
        "validate_rounds".into(),
        json!([{"round_id": ROUND, "kind": "implement", "mode": "full", "seconds": 55}]),
    );
    fs::write(&path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    let cost = doc["validate_rounds"].clone();

    let applied = apply(&path, &reconcile(ROUND), &at(NOW_SECS + 100), LOCK).unwrap();
    let report = &applied.report;
    assert_eq!(
        state_of(report, &live),
        RunState::Live {
            pid: live_child.pid()
        }
    );
    assert_eq!(
        state_of(report, &refused),
        closed(StageOutcome::Stopped, RunCause::RunDirAbsent, None)
    );
    assert_eq!(
        state_of(report, &gone),
        closed(StageOutcome::Lost, RunCause::ProcessGone, None)
    );
    assert_eq!(
        state_of(report, &failing),
        closed(StageOutcome::Fail, RunCause::Sentinel, Some(55))
    );
    assert_eq!(
        state_of(report, &bounded),
        closed(StageOutcome::NoVerdict, RunCause::Sentinel, None)
    );
    assert_eq!(
        state_of(report, &passing),
        closed(StageOutcome::Pass, RunCause::Sentinel, None)
    );
    assert_eq!(
        state_of(report, &unlaunched),
        closed(StageOutcome::Lost, RunCause::PidUnrecorded, None)
    );
    assert!(
        matches!(state_of(report, &garbled), RunState::Unreadable { .. }),
        "{report:?}"
    );
    assert_eq!(
        state_of(report, &skewed),
        closed(StageOutcome::Fail, RunCause::Sentinel, None)
    );
    let after = object(&path);
    assert_eq!(after["validate_rounds"], cost, "the cost row stands");
    assert_eq!(
        after["stages"][0]["end"],
        Value::Null,
        "the round's own stage is the acceptance owner's to close"
    );
    let stages = validate_stages(&path);
    let stage = |dir: &str| {
        stages
            .iter()
            .find(|s| s.run_dir.as_deref() == Some(dir))
            .unwrap()
    };
    assert_eq!((stage(&live).end, stage(&live).outcome), (None, None));
    assert_eq!((stage(&garbled).end, stage(&garbled).outcome), (None, None));
    let expected = [
        (&refused, StageOutcome::Stopped, NOW_SECS + 100),
        (&gone, StageOutcome::Lost, NOW_SECS + 100),
        (&failing, StageOutcome::Fail, NOW_SECS + 60),
        (&bounded, StageOutcome::NoVerdict, NOW_SECS + 70),
        (&passing, StageOutcome::Pass, NOW_SECS + 80),
        (&unlaunched, StageOutcome::Lost, NOW_SECS + 100),
        (&skewed, StageOutcome::Fail, NOW_SECS + 100),
    ];
    for (dir, outcome, end) in expected {
        let s = stage(dir);
        assert_eq!((s.outcome, s.end), (Some(outcome), Some(end)), "{dir}");
        assert!(
            s.start <= NOW_SECS + 8,
            "{dir}: the admission's start stands"
        );
    }
    for row in after["stages"].as_array().unwrap().iter().skip(1) {
        let row = row.as_object().unwrap();
        let open = row["end"].is_null();
        let expected: &[&str] = if open {
            &["kind", "round_id", "start", "end", "run_dir"]
        } else {
            &["kind", "round_id", "start", "end", "run_dir", "outcome"]
        };
        assert_eq!(keys(row), expected, "{}", row["run_dir"]);
    }

    // A repeat reads only what stands open: the live and the unreadable
    // run; the closed runs keep their words and are not rows.
    let again = run_at(&path, &reconcile(ROUND), NOW_SECS + 200).unwrap();
    let Report::ReconcileRound(r) = &again.report else {
        panic!("{:?}", again.report)
    };
    let mut open: Vec<&str> = r.runs.iter().map(|run| run.run_dir.as_str()).collect();
    open.sort_unstable();
    let mut expected = [live.as_str(), garbled.as_str()];
    expected.sort_unstable();
    assert_eq!(open, expected);
    assert_eq!(stage(&failing).end, Some(NOW_SECS + 60));
    assert_eq!(validate_stages(&path), stages, "the repeat wrote nothing");

    // The live run's child ends without its sentinel: lost, at the read.
    live_child.end();
    let ended = run_at(&path, &reconcile(ROUND), NOW_SECS + 300).unwrap();
    assert_eq!(
        state_of(&ended.report, &live),
        closed(StageOutcome::Lost, RunCause::ProcessGone, None)
    );
    let s = validate_stages(&path)
        .into_iter()
        .find(|s| s.run_dir.as_deref() == Some(live.as_str()))
        .unwrap();
    assert_eq!(
        (s.outcome, s.end),
        (Some(StageOutcome::Lost), Some(NOW_SECS + 300))
    );
    // A round with nothing open reconciles to no rows.
    let path = item_file(dir.path());
    let none = run(&path, &reconcile(ROUND)).unwrap();
    let Report::ReconcileRound(r) = &none.report else {
        panic!("{:?}", none.report)
    };
    assert!(r.runs.is_empty());
}

/// `.verification` is `{head, verdict, reason, source, at}`,
/// appended on the first write and replaced in place by a later one; a
/// word that is no verdict, a wait's `pending` among them, writes
/// nothing.
#[test]
fn record_verification_writes_the_record_once_and_a_later_write_replaces_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let before = object(&path);
    let verify = |round: Option<&str>, head: &str, verdict: &str| {
        Request::RecordVerification(RecordVerification {
            round_id: round.map(str::to_owned),
            head: head.into(),
            verdict: verdict.into(),
            reason: format!(
                "no CI configured: no active workflows and no required checks on main ({verdict})"
            ),
            source: "ci-wait --required-only".into(),
        })
    };
    let first = apply(
        &path,
        &verify(None, "a".repeat(40).as_str(), "none"),
        &env(),
        LOCK,
    )
    .unwrap();
    let Report::RecordVerification(a) = first.report else {
        panic!("{:?}", first.report)
    };
    assert!(!a.replaced);
    assert_eq!(a.verdict, "none");
    assert_eq!(a.at, env().iso());
    let after = object(&path);
    let mut expected_keys = keys(&before);
    expected_keys.push("verification".to_owned());
    assert_eq!(keys(&after), expected_keys, "the record is appended once");
    for (key, value) in &before {
        assert_eq!(&after[key], value, "{key}");
    }
    let record = after["verification"].as_object().unwrap();
    assert_eq!(keys(record), ["head", "verdict", "reason", "source", "at"]);
    assert_eq!(record["head"], "a".repeat(40));
    assert_eq!(record["verdict"], "none");
    assert_eq!(record["source"], "ci-wait --required-only");
    assert_eq!(record["at"], env().iso());

    // A later head's verdict replaces the record where it stands.
    let later = at(NOW_SECS + 90);
    let second = apply(
        &path,
        &verify(None, "b".repeat(40).as_str(), "pass"),
        &later,
        LOCK,
    )
    .unwrap();
    let Report::RecordVerification(b) = second.report else {
        panic!("{:?}", second.report)
    };
    assert!(b.replaced);
    assert_eq!(b.at, later.iso());
    let again = object(&path);
    assert_eq!(keys(&again), keys(&after), "one record, in its place");
    assert_eq!(again["verification"]["head"], "b".repeat(40));
    assert_eq!(again["verification"]["verdict"], "pass");
    assert_eq!(again["verification"]["at"], later.iso());

    // A word that is no verdict is refused and writes nothing: a wait's
    // `pending` names a wait that ended without a result.
    let text = fs::read_to_string(&path).unwrap();
    for word in ["pending", "green", "PASS", ""] {
        let err = run(&path, &verify(None, "c".repeat(40).as_str(), word)).unwrap_err();
        assert_eq!(err.key(), "verdict-invalid", "{word:?}");
        assert_eq!(
            err.fields(),
            vec![("verdict".to_owned(), word.to_owned())],
            "{word:?}"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "{word:?}");
    }
    // A round named must be one the item ran.
    let err = run(
        &path,
        &verify(Some("no-such-round"), "d".repeat(40).as_str(), "fail"),
    )
    .unwrap_err();
    assert_eq!(err.key(), "round-unknown");
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    let bound = run(&path, &verify(Some(ROUND), "d".repeat(40).as_str(), "fail")).unwrap();
    let Report::RecordVerification(c) = bound.report else {
        panic!("{:?}", bound.report)
    };
    assert!(c.replaced);
    assert_eq!(object(&path)["verification"]["verdict"], "fail");
}

/// A handoff names the round it leaves open; the same content recorded again is
/// the same operation and writes nothing, other content needs `supersede`; the
/// continuing session resumes that same round, stamped once, and reads the
/// admitted run it waits on instead of starting a new one; and that session's
/// own handoff, the hook's printed request or its model-switch supersede,
/// replaces the consumed record whole and stands.
#[test]
fn a_handoff_is_recorded_once_per_content_and_resumed_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let text = fs::read_to_string(&path).unwrap();
    // No record stands: nothing to resume, nothing written.
    let err = run(&path, &resume()).unwrap_err();
    assert_eq!(err.key(), "handoff-none");
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    // The round named must be one the item ran.
    let err = run(&path, &handoff(Some("no-such-round"), None, None)).unwrap_err();
    assert_eq!(err.key(), "round-unknown");
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
    // The stamp rule on written_at.
    for (given, key) in [
        ("2026-01-29 15:20:00Z", "handoff-written-at-invalid"),
        ("soon", "handoff-written-at-invalid"),
        ("2026-01-29T15:20:01Z", "handoff-written-at-future"),
    ] {
        let err = apply(
            &path,
            &handoff(Some(ROUND), None, Some(given)),
            &env(),
            LOCK,
        )
        .unwrap_err();
        assert_eq!(err.key(), key, "{given}");
        assert_eq!(err.fields()[0], ("written_at".to_owned(), given.to_owned()));
        assert_eq!(fs::read_to_string(&path).unwrap(), text, "{given}");
    }

    let a = admitted(apply(&path, &admit(ROUND, None), &env(), LOCK).unwrap());
    let before = object(&path);
    // A past written_at is kept on the first write.
    let past = "2026-01-29T15:00:00Z";
    let written = apply(
        &path,
        &handoff(Some(ROUND), Some(Relaunch::Fresh), Some(past)),
        &at(NOW_SECS + 10),
        LOCK,
    )
    .unwrap();
    let Report::RecordHandoff(h) = written.report else {
        panic!("{:?}", written.report)
    };
    assert!(!h.replaced);
    assert!(h.recorded_now);
    assert_eq!(h.round_id.as_deref(), Some(ROUND));
    assert_eq!(h.written_at, past);
    let after = object(&path);
    let mut expected_keys = keys(&before);
    expected_keys.push("handoff".to_owned());
    assert_eq!(keys(&after), expected_keys, "the record is appended once");
    let record = after["handoff"].as_object().unwrap();
    assert_eq!(
        keys(record),
        [
            "round_id",
            "merged",
            "remaining",
            "branch",
            "worktree",
            "open_pr",
            "traps",
            "context",
            "relaunch",
            "written_at",
        ]
    );
    assert_eq!(record["round_id"], ROUND);
    assert_eq!(record["relaunch"], "fresh");
    assert_eq!(record["written_at"], past);
    assert_eq!(record["merged"], json!(["#2714"]));
    assert_eq!(record["context"]["decision"], "handoff");
    assert!(
        record.get("resumed_at").is_none(),
        "a standing record carries no resumed_at, as the standing-handoff readers read one"
    );
    // The same content again, later and without a stamp, is the same
    // operation: nothing written, the standing stamp reported.
    let repeat = run_at(
        &path,
        &handoff(Some(ROUND), Some(Relaunch::Fresh), None),
        NOW_SECS + 20,
    )
    .unwrap();
    let Report::RecordHandoff(k) = repeat.report else {
        panic!("{:?}", repeat.report)
    };
    assert!(!k.replaced);
    assert!(!k.recorded_now);
    assert_eq!(k.written_at, past);
    assert_eq!(object(&path)["handoff"], after["handoff"]);

    // The resume stamps the record and names what continues: the round,
    // its relaunch route, the remaining steps and the admitted open run.
    let resumed = apply(&path, &resume(), &at(NOW_SECS + 600), LOCK).unwrap();
    let Report::ResumeHandoff(r) = resumed.report else {
        panic!("{:?}", resumed.report)
    };
    assert!(r.resumed_now);
    assert_eq!(r.resumed_at, NOW_SECS + 600);
    assert_eq!(r.round_id.as_deref(), Some(ROUND));
    assert_eq!(r.relaunch, Some(Relaunch::Fresh));
    assert_eq!(r.remaining, vec!["merge-pr § 5 step 3".to_owned()]);
    assert_eq!(
        r.open_runs,
        vec![OpenRun {
            run_dir: a.run_dir.clone(),
            outcome: None,
        }]
    );
    let record = object(&path)["handoff"].as_object().unwrap().clone();
    assert_eq!(record["resumed_at"], NOW_SECS + 600);
    assert_eq!(record["written_at"], past);
    assert_eq!(
        item(&path).stages.len(),
        2,
        "a resume opens no round and admits no run"
    );
    // The second resume is a no-op reporting the first stamp.
    let again = run_at(&path, &resume(), NOW_SECS + 900).unwrap();
    let Report::ResumeHandoff(r2) = again.report else {
        panic!("{:?}", again.report)
    };
    assert!(!r2.resumed_now);
    assert_eq!(r2.resumed_at, NOW_SECS + 600);
    assert_eq!(object(&path)["handoff"]["resumed_at"], NOW_SECS + 600);
    // The relaunch the resume started hands off in turn: its record, here
    // the same content again, replaces the consumed one whole, with no
    // resume stamp, so it stands.
    let relaunched = run_at(
        &path,
        &handoff(Some(ROUND), Some(Relaunch::Fresh), None),
        NOW_SECS + 910,
    )
    .unwrap();
    let Report::RecordHandoff(k) = relaunched.report else {
        panic!("{:?}", relaunched.report)
    };
    assert!(k.replaced);
    assert!(k.recorded_now);
    assert_eq!(k.written_at, at(NOW_SECS + 910).iso());
    let record = object(&path)["handoff"].as_object().unwrap().clone();
    assert!(
        record.get("resumed_at").is_none(),
        "the relaunch's own record stands"
    );
    // Other content over an unconsumed record refuses, naming the fields, and
    // writes nothing.
    let other = |supersede| {
        handoff_with(
            Some(ROUND),
            Some(Relaunch::Fresh),
            None,
            "merge-pr § 5 step 4",
            supersede,
        )
    };
    let err = run_at(&path, &other(false), NOW_SECS + 920).unwrap_err();
    assert_eq!(err.key(), "handoff-differs");
    assert_eq!(
        err.fields(),
        vec![
            ("path".to_owned(), path.display().to_string()),
            ("fields".to_owned(), "remaining".to_owned()),
        ]
    );
    assert_eq!(object(&path)["handoff"], Value::Object(record.clone()));
    // Asked to supersede, the write replaces the content and stamps anew.
    let superseded = apply(&path, &other(true), &at(NOW_SECS + 930), LOCK).unwrap();
    let Report::RecordHandoff(s) = superseded.report else {
        panic!("{:?}", superseded.report)
    };
    assert!(s.replaced);
    assert!(s.recorded_now);
    assert_eq!(s.written_at, at(NOW_SECS + 930).iso());
    let record = object(&path)["handoff"].as_object().unwrap().clone();
    assert_eq!(record["remaining"], json!(["merge-pr § 5 step 4"]));
    assert_eq!(record["written_at"], at(NOW_SECS + 930).iso());
    assert_eq!(keys(&record)[9..], ["written_at".to_owned()]);
    // Over a consumed record, other content stands with or without
    // `supersede`: the lane's printed request carries none, the model-switch
    // handoff asks it.
    for (supersede, remaining, secs) in [
        (false, "merge-pr § 5 step 5", NOW_SECS + 940),
        (true, "merge-pr § 5 step 6", NOW_SECS + 960),
    ] {
        run_at(&path, &resume(), secs).unwrap();
        let next = handoff_with(
            Some(ROUND),
            Some(Relaunch::Fresh),
            None,
            remaining,
            supersede,
        );
        let written = run_at(&path, &next, secs + 10).unwrap();
        let Report::RecordHandoff(w) = written.report else {
            panic!("{:?}", written.report)
        };
        assert!(w.replaced && w.recorded_now, "supersede={supersede}");
        let record = object(&path)["handoff"].as_object().unwrap().clone();
        assert_eq!(
            record["remaining"],
            json!([remaining]),
            "supersede={supersede}"
        );
        assert!(
            record.get("resumed_at").is_none(),
            "supersede={supersede}: the new record stands"
        );
    }
    // Once the run closed, a resume still names it, now by its recorded
    // outcome: the continuation reuses the run its job ended rather than
    // starting a new one.
    run(
        &path,
        &accept(ROUND, Some(&a.run_dir), StageOutcome::Lost, None),
    )
    .unwrap();
    let after_close = run(&path, &resume()).unwrap();
    let Report::ResumeHandoff(r3) = after_close.report else {
        panic!("{:?}", after_close.report)
    };
    assert_eq!(
        r3.open_runs,
        vec![OpenRun {
            run_dir: a.run_dir.clone(),
            outcome: Some(StageOutcome::Lost),
        }]
    );
    // The round's next attempt admitted beside the lost one (a recovery
    // round's shape): the runs are listed newest first, so the
    // continuation's first is the attempt still to read.
    let next = admitted(run_at(&path, &admit_next(ROUND), NOW_SECS + 1000).unwrap());
    let later = run_at(&path, &resume(), NOW_SECS + 1100).unwrap();
    let Report::ResumeHandoff(r4) = later.report else {
        panic!("{:?}", later.report)
    };
    assert_eq!(
        r4.open_runs,
        vec![
            OpenRun {
                run_dir: next.run_dir.clone(),
                outcome: None,
            },
            OpenRun {
                run_dir: a.run_dir.clone(),
                outcome: Some(StageOutcome::Lost),
            },
        ],
        "newest first"
    );

    // A record `workflow-state set handoff` writes names no round and no
    // route and carries `resumed_at: null`; the resume still stamps it, and
    // a supersede of an unresumed one carries no stamp over.
    let unrouted = dir.path().join("workflow-state-KEN-3.json");
    let mut doc: Document = serde_json::from_str(ITEM).unwrap();
    doc.insert(
        "handoff".into(),
        json!({
            "merged": [], "remaining": ["submit-pr § 2"], "branch": "b", "worktree": "/w",
            "open_pr": null, "traps": [], "context": null, "written_at": "2026-01-29T15:00:00Z",
            "resumed_at": null
        }),
    );
    fs::write(&unrouted, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    let superseded = run(&unrouted, &other(true)).unwrap();
    let Report::RecordHandoff(s) = superseded.report else {
        panic!("{:?}", superseded.report)
    };
    assert!(s.replaced);
    assert!(
        object(&unrouted)["handoff"].get("resumed_at").is_none(),
        "an unresumed record superseded stays unresumed"
    );
    fs::write(&unrouted, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    let resumed = run(&unrouted, &resume()).unwrap();
    let Report::ResumeHandoff(l) = resumed.report else {
        panic!("{:?}", resumed.report)
    };
    assert!(l.resumed_now);
    assert_eq!(l.round_id, None);
    assert_eq!(l.relaunch, None);
    assert_eq!(l.remaining, vec!["submit-pr § 2".to_owned()]);
    assert_eq!(l.open_runs, Vec::<OpenRun>::new());
    assert_eq!(object(&unrouted)["handoff"]["resumed_at"], NOW_SECS);
}

// --- the binary: the wire names a workflow writes ------------------------

fn op(path: &Path, request: &Path) -> Output {
    support::isolated()
        .args(["op", "--file"])
        .arg(path)
        .arg("--request")
        .arg(request)
        .output()
        .unwrap()
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

fn first_stderr_line(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr)
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned()
}

fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, text).unwrap();
    path
}

/// The workflows write these requests as JSON files: the `op` words, the
/// `attempt`, `outcome`, `end` and `supersede` fields and the reply's
/// `run_id`, `run_dir`, `outcome` and `state` names are the contract they
/// read.
#[test]
fn op_admits_closes_reconciles_and_hands_off_a_round_through_the_wire_names() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let admit = write(
        dir.path(),
        "admit.json",
        &format!(r#"{{"op": "record-validation-admission", "round_id": "{ROUND}"}}"#),
    );
    let out = op(&path, &admit);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "record-validation-admission");
    assert_eq!(report["minted"], true);
    assert_eq!(report["admitted_now"], true);
    let run_id = report["run_id"].as_str().unwrap().to_owned();
    let run_dir = report["run_dir"].as_str().unwrap().to_owned();
    assert_eq!(run_dir, format!("{WORKTREE}/tmp/dev-validate-{run_id}"));
    // The same request file again is the same admission.
    let out = op(&path, &admit);
    assert!(out.status.success());
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["admitted_now"], false);
    assert_eq!(report["run_dir"], run_dir);

    // A stale end artifact is refused on the keyed line with the bounds.
    let stale_artifact = artifact(dir.path(), "review-stale.json", 1);
    let stale = write(
        dir.path(),
        "stale.json",
        &format!(
            r#"{{"op": "accept-result", "round_id": "{ROUND}", "run_dir": "{run_dir}", "outcome": "fail", "end": {{"from_artifact": "{}"}}}}"#,
            stale_artifact.display()
        ),
    );
    let out = op(&path, &stale);
    assert_eq!(out.status.code(), Some(1));
    let line = first_stderr_line(&out);
    assert!(
        line.starts_with(&format!(
            "orch-runtime: end-out-of-range round_id={ROUND} end=1 start="
        )),
        "{line}"
    );
    assert_eq!(reply(&out)["refusal"]["key"], "end-out-of-range");
    // A word that is no outcome is not a request, and neither is a close
    // without one: no word is assumed.
    for (name, text) in [
        (
            "green.json",
            format!(r#"{{"op": "accept-result", "round_id": "{ROUND}", "outcome": "green"}}"#),
        ),
        (
            "wordless.json",
            format!(r#"{{"op": "accept-result", "round_id": "{ROUND}"}}"#),
        ),
    ] {
        let request = write(dir.path(), name, &text);
        let out = op(&path, &request);
        assert_eq!(out.status.code(), Some(1), "{name}");
        assert_eq!(reply(&out)["refusal"]["key"], "request-invalid", "{name}");
        let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(state["stages"][0]["end"], Value::Null, "{name}");
    }

    let close = write(
        dir.path(),
        "close.json",
        &format!(
            r#"{{"op": "accept-result", "round_id": "{ROUND}", "run_dir": "{run_dir}", "outcome": "no-verdict"}}"#
        ),
    );
    let out = op(&path, &close);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "accept-result");
    assert_eq!(report["kind"], "validate");
    assert_eq!(report["outcome"], "no-verdict");
    assert_eq!(report["closed_now"], true);
    let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(state["stages"][1]["outcome"], "no-verdict");
    assert_eq!(state["stages"][1]["run_dir"], run_dir);

    // The next attempt by name, then the reconcile: its directory was never
    // created, so it closes stopped.
    let next = write(
        dir.path(),
        "next.json",
        &format!(
            r#"{{"op": "record-validation-admission", "round_id": "{ROUND}", "attempt": "next"}}"#
        ),
    );
    let out = op(&path, &next);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    let next_dir = reply(&out)["result"]["report"]["run_dir"].clone();
    assert_ne!(next_dir, run_dir);
    let reconcile = write(
        dir.path(),
        "reconcile.json",
        &format!(r#"{{"op": "reconcile-round", "round_id": "{ROUND}"}}"#),
    );
    let out = op(&path, &reconcile);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "reconcile-round");
    assert_eq!(
        report["runs"],
        json!([{
            "run_dir": next_dir,
            "state": "closed",
            "outcome": "stopped",
            "cause": "run-dir-absent",
        }])
    );
    let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(state["stages"][2]["outcome"], "stopped");

    let record = write(
        dir.path(),
        "handoff.json",
        &format!(
            r#"{{"op": "record-handoff", "round_id": "{ROUND}", "merged": [], "remaining": ["dev-start § 3"], "branch": "b", "worktree": "/w", "open_pr": null, "traps": [], "context": null, "relaunch": "fresh"}}"#
        ),
    );
    let out = op(&path, &record);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "record-handoff");
    assert_eq!(report["replaced"], false);
    assert_eq!(report["recorded_now"], true);
    assert!(report["written_at"].as_str().unwrap().ends_with('Z'));
    let out = op(&path, &record);
    assert!(out.status.success());
    assert_eq!(reply(&out)["result"]["report"]["recorded_now"], false);
    let other = write(
        dir.path(),
        "handoff-other.json",
        &format!(
            r#"{{"op": "record-handoff", "round_id": "{ROUND}", "merged": [], "remaining": ["dev-start § 4"], "branch": "b", "worktree": "/w", "open_pr": null, "traps": [], "context": null, "relaunch": "fresh"}}"#
        ),
    );
    let out = op(&path, &other);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(reply(&out)["refusal"]["key"], "handoff-differs");
    let superseding = write(
        dir.path(),
        "handoff-supersede.json",
        &format!(
            r#"{{"op": "record-handoff", "supersede": true, "round_id": "{ROUND}", "merged": [], "remaining": ["dev-start § 4"], "branch": "b", "worktree": "/w", "open_pr": null, "traps": [], "context": null, "relaunch": "fresh"}}"#
        ),
    );
    let out = op(&path, &superseding);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    assert_eq!(reply(&out)["result"]["report"]["replaced"], true);
    let resume = write(dir.path(), "resume.json", r#"{"op": "resume-handoff"}"#);
    let out = op(&path, &resume);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["op"], "resume-handoff");
    assert_eq!(report["round_id"], ROUND);
    assert_eq!(report["relaunch"], "fresh");
    assert_eq!(report["resumed_now"], true);
    // The round's runs the continuation has not consumed, each with its
    // outcome, newest first: the stopped next attempt, then the no-verdict
    // close.
    assert_eq!(
        report["open_runs"],
        json!([
            {"run_dir": next_dir, "outcome": "stopped"},
            {"run_dir": run_dir, "outcome": "no-verdict"},
        ])
    );
    assert_eq!(report["remaining"], json!(["dev-start § 4"]));
    let state: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert!(state["handoff"]["resumed_at"].as_u64().is_some());
    let out = op(&path, &resume);
    assert!(out.status.success());
    assert_eq!(reply(&out)["result"]["report"]["resumed_now"], false);
}

/// The run directory of an admitted validation stage is read three-valued. A
/// directory that cannot be read (its parent refuses traversal) is no proof of
/// absence: the reconcile holds the stage open as unreadable, never closing it
/// `Stopped`; only a directory read `NotFound` closes it.
#[test]
fn an_unreadable_admitted_run_holds_the_stage_open() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let parent = dir.path().join("locked");
    let root = parent.join("run");
    fs::create_dir_all(&root).unwrap();
    let mut child = Owned::sleep();
    fs::write(root.join("pid"), format!("{}\n", child.pid())).unwrap();
    run(&path, &admit(ROUND, Some(root.to_str().unwrap()))).unwrap();
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o000)).unwrap();
    let metadata = fs::metadata(&root).map(|_| ()).map_err(|e| e.kind());
    let result = run(&path, &reconcile(ROUND));
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
    child.end();
    assert_eq!(
        metadata,
        Err(std::io::ErrorKind::PermissionDenied),
        "the fixture made the run directory unreadable"
    );
    let report = result.unwrap();
    assert!(
        validate_stages(&path).iter().all(|s| s.end.is_none()),
        "an unreadable run directory closed the stage: {:?}",
        report.report
    );
    // Removed, the directory reads absent and the stage closes `Stopped`.
    fs::remove_dir_all(&parent).unwrap();
    run(&path, &reconcile(ROUND)).unwrap();
    assert!(
        validate_stages(&path).iter().all(|s| s.end.is_some()),
        "a run directory read absent closes the stage"
    );
}

// ---------------------------------------------------------------------------
// The acceptance's authorization, the directed micro change and the round
// record's two fields.
// ---------------------------------------------------------------------------

use orch_runtime::state::{Authorization, AuthorizedBy};

fn authorized(by: AuthorizedBy, id: &str) -> Option<Authorization> {
    Some(Authorization { by, id: id.into() })
}

/// The round's own close as `pass`, under `authorization`.
fn accept_as(round: &str, authorization: Option<Authorization>) -> Request {
    Request::AcceptResult(AcceptResult {
        round_id: round.into(),
        run_dir: None,
        outcome: StageOutcome::Pass,
        end: None,
        authorization,
        summary_file: None,
        attachments: Vec::new(),
        summary_comment: None,
    })
}

fn accepted(applied: Applied) -> orch_runtime::ops::ResultAccepted {
    let Report::AcceptResult(a) = applied.report else {
        panic!("{:?}", applied.report)
    };
    a
}

fn begun(applied: Applied) -> orch_runtime::ops::RoundBegun {
    let Report::BeginRound(b) = applied.report else {
        panic!("{:?}", applied.report)
    };
    b
}

fn lines(path: &Path) -> Vec<String> {
    fs::read_to_string(path)
        .map(|t| t.lines().map(str::to_owned).collect())
        .unwrap_or_default()
}

fn record_of(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

/// An acceptance records who accepted the step,
/// and the authorization is part of the acceptance's identity: a repeat
/// under the same one is the no-op a repeat is, one under another refuses
/// and leaves the record, and a close never gains an authorization after
/// the fact. The defect: a step re-authorized after its close, or two
/// authorities recorded for one close.
#[test]
fn an_acceptance_records_its_authorization_and_a_repeat_under_another_refuses() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let overseer = authorized(AuthorizedBy::Overseer, "sess-1");
    let a = accepted(run(&path, &accept_as(ROUND, overseer.clone())).unwrap());
    assert!(a.closed_now);
    assert_eq!(a.authorization, overseer);
    assert_eq!(a.summary_comment, None);
    assert_eq!(a.summary, None);
    let doc = object(&path);
    assert_eq!(
        keys(doc["stages"][0].as_object().unwrap()),
        [
            "kind",
            "round_id",
            "start",
            "end",
            "outcome",
            "authorization"
        ]
    );
    assert_eq!(
        doc["stages"][0]["authorization"],
        json!({"by": "overseer", "id": "sess-1"})
    );
    // The same authorization again is the repeat: nothing moves, the
    // record is reported; a repeat naming none reports the recorded one.
    let b = accepted(run_at(&path, &accept_as(ROUND, overseer.clone()), NOW_SECS + 60).unwrap());
    assert!(!b.closed_now);
    assert_eq!(b.authorization, overseer);
    let c = accepted(run(&path, &accept_as(ROUND, None)).unwrap());
    assert!(!c.closed_now);
    assert_eq!(c.authorization, overseer);
    // Another id, or another authority, refuses and leaves the record.
    for other in [
        authorized(AuthorizedBy::Overseer, "sess-2"),
        authorized(AuthorizedBy::OwnerDirective, "sess-1"),
    ] {
        let err = run(&path, &accept_as(ROUND, other.clone())).unwrap_err();
        assert_eq!(err.key(), "authorization-differs", "{other:?}");
        assert_eq!(
            object(&path)["stages"][0]["authorization"],
            json!({"by": "overseer", "id": "sess-1"}),
            "{other:?}"
        );
    }
    // A stage closed under no authorization is never re-authorized.
    let path = item_file(dir.path());
    run(&path, &accept_as(ROUND, None)).unwrap();
    let err = run(&path, &accept_as(ROUND, overseer)).unwrap_err();
    assert_eq!(err.key(), "authorization-differs");
    assert_eq!(object(&path)["stages"][0].get("authorization"), None);
}

/// An owner-directed micro change runs
/// under the item key `directive-<id>` (the hook's and the mailbox's item
/// alphabet admit no colon), its declared validation runs once as a
/// `validate` row closed on its verdict, and the round's own close names
/// the owner's directive by that id or refuses `authorization-missing`.
/// The defect: a directed change accepted on no one's authority, or under
/// another directive's.
#[test]
fn a_directed_items_acceptance_names_its_directive_or_refuses_authorization_missing() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    fs::create_dir_all(&state).unwrap();
    let path = state.join("workflow-state-directive-m-7.json");
    fs::write(&path, ITEM).unwrap();
    // The directed round and its one run of the declared command: the run's
    // close is the runner's verdict and names no authorization.
    let round = begun(run(&path, &begin(RoundKind::Dev)).unwrap()).round_id;
    let a = admitted(run(&path, &admit(&round, None)).unwrap());
    let closed = accepted(
        run(
            &path,
            &accept(&round, Some(&a.run_dir), StageOutcome::Pass, None),
        )
        .unwrap(),
    );
    assert!(closed.closed_now);
    assert_eq!(closed.authorization, None);
    for (name, authorization) in [
        ("none", None),
        ("the overseer", authorized(AuthorizedBy::Overseer, "m-7")),
        (
            "another directive",
            authorized(AuthorizedBy::OwnerDirective, "m-8"),
        ),
    ] {
        let err = run(&path, &accept_as(&round, authorization)).unwrap_err();
        assert_eq!(err.key(), "authorization-missing", "{name}");
        assert_eq!(object(&path)["stages"][1]["end"], Value::Null, "{name}");
    }
    // On the wire the key names the file and the refusal names the
    // directive the item needs.
    let request = write(
        dir.path(),
        "accept.json",
        &format!(r#"{{"op": "accept-result", "round_id": "{round}", "outcome": "pass"}}"#),
    );
    let out = support::isolated()
        .arg("--state-dir")
        .arg(&state)
        .args(["op", "--item", "directive-m-7", "--request"])
        .arg(&request)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1), "{}", first_stderr_line(&out));
    assert_eq!(
        first_stderr_line(&out),
        "orch-runtime: authorization-missing directive=m-7"
    );
    assert_eq!(reply(&out)["refusal"]["key"], "authorization-missing");
    let directed = authorized(AuthorizedBy::OwnerDirective, "m-7");
    let accepted_now = accepted(run(&path, &accept_as(&round, directed.clone())).unwrap());
    assert!(accepted_now.closed_now);
    assert_eq!(accepted_now.authorization, directed);
    let doc = object(&path);
    assert_eq!(
        doc["stages"][1]["authorization"],
        json!({"by": "owner-directive", "id": "m-7"})
    );
    assert_eq!(doc["stages"][2]["outcome"], "pass");
    assert_eq!(doc["stages"][2].get("authorization"), None);
}

/// An acceptance of `round` naming the summary file and `attachments`,
/// its request written beside the item's `path`, through the
/// `linear-comments` fixture as the tracker CLI with
/// `fixture_env` planted (`LINEAR_COMMENTS`, `LINEAR_COMMENTS_MORE`,
/// `LINEAR_LIST_STATUS`, `LINEAR_STATUS`, `LINEAR_SNAPSHOT`, `LINEAR_KILL`),
/// its calls appended to `log`.
fn accept_posting(
    path: &Path,
    log: &Path,
    summary: &Path,
    attachments: &[&Path],
    round: &str,
    name: &str,
    fixture_env: &[(&str, &str)],
) -> Output {
    let attachments: Vec<String> = attachments
        .iter()
        .map(|p| p.display().to_string())
        .collect();
    let request = write(
        path.parent().unwrap(),
        name,
        &format!(
            r#"{{"op": "accept-result", "round_id": "{round}", "outcome": "pass", "authorization": {{"by": "overseer", "id": "sess-1"}}, "summary_file": "{}", "attachments": {}}}"#,
            summary.display(),
            json!(attachments)
        ),
    );
    let mut cmd = support::isolated();
    cmd.args(["op", "--file"])
        .arg(path)
        .arg("--request")
        .arg(&request)
        .env(
            "OVERSEE_WATCH_TRACKER",
            support::fixtures().join("linear-comments/linear.sh"),
        )
        .env("LINEAR_LOG", log)
        .env("LINEAR_STATE", path);
    for (key, value) in fixture_env {
        cmd.env(key, value);
    }
    cmd.output().unwrap()
}

/// The report of an acceptance that succeeded.
fn accepted_report(out: &Output) -> Value {
    assert!(out.status.success(), "{}", first_stderr_line(out));
    reply(out)["result"]["report"].clone()
}

/// A new dev round on the item, its id.
fn next_round(dir: &Path, path: &Path) -> String {
    let begin = write(dir, "begin.json", r#"{"op": "begin-round", "kind": "dev"}"#);
    let out = op(path, &begin);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    reply(&out)["result"]["report"]["round_id"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// A comment as the CLI's `comments list` answers it, created at `at`.
fn listed(id: &str, body: &str, at: &str) -> Value {
    json!({"id": id, "body": body, "user": "", "user_email": "", "created_at": at, "updated_at": at})
}

/// The link line the fixture appends under a created comment's body for
/// one `--attach`, and the record it reads back as.
fn fixture_link(name: &str) -> (String, Value) {
    let url = format!("https://uploads.linear.app/fixture/{name}");
    (
        format!("![{name}]({url})"),
        json!({"name": name, "url": url, "image": true}),
    )
}

/// One Completion Summary per item, posted by the acceptance after its close
/// committed, created on the item's first acceptance where the item's comment
/// list names none, and updated in place by the recorded id on every later one,
/// with no list once an id is recorded; a refused post is in the reply and the
/// acceptance stands. The defect: a comment per acceptance, a post before the
/// close, a create with no list before it, a created comment not updated in
/// place, or a refused post failing the acceptance.
#[test]
fn two_acceptances_of_one_item_post_one_summary_comment_the_second_an_update_by_the_recorded_id() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let log = dir.path().join("linear.log");
    let snapshot = dir.path().join("at-first-post.json");
    let summary = write(
        dir.path(),
        "completion-summary-KEN-4687.md",
        "## Completion Summary\n\nround one\n",
    );
    let out = accept_posting(
        &path,
        &log,
        &summary,
        &[],
        ROUND,
        "first.json",
        &[("LINEAR_SNAPSHOT", snapshot.to_str().unwrap())],
    );
    let report = accepted_report(&out);
    assert_eq!(report["closed_now"], true);
    assert_eq!(
        report["authorization"],
        json!({"by": "overseer", "id": "sess-1"})
    );
    assert_eq!(report["summary"]["posted"], "created");
    assert_eq!(report["summary"]["id"], "cmt-1");
    assert_eq!(report["summary_comment"]["id"], "cmt-1");
    let state = record_of(&path);
    assert_eq!(state["summary_comment"]["id"], "cmt-1");
    assert_eq!(state["summary_comment"].get("attachments"), None);
    assert!(
        state["summary_comment"]["at"]
            .as_str()
            .unwrap()
            .ends_with('Z')
    );
    assert_eq!(state["stages"][0]["outcome"], "pass");
    // The close was committed before the comment went out, with no id yet.
    let at_post = record_of(&snapshot);
    assert_eq!(at_post["stages"][0]["outcome"], "pass");
    assert_eq!(at_post.get("summary_comment"), None);
    assert_eq!(
        lines(&log),
        [
            "comments list KEN-4687".to_owned(),
            format!("comments create KEN-4687 --body-file {}", summary.display()),
            "body ## Completion Summary".to_owned(),
        ]
    );
    // The next round's acceptance updates the one comment by its id, with
    // no list; with no attachment recorded the summary file is the body.
    let second = next_round(dir.path(), &path);
    fs::write(&summary, "## Completion Summary\n\nround two\n").unwrap();
    let out = accept_posting(&path, &log, &summary, &[], &second, "second.json", &[]);
    let report = accepted_report(&out);
    assert_eq!(report["closed_now"], true);
    assert_eq!(report["summary"]["posted"], "updated");
    assert_eq!(report["summary"]["id"], "cmt-1");
    let posts = lines(&log);
    assert_eq!(posts.len(), 5, "{posts:?}");
    assert_eq!(
        posts[3],
        format!("comments update cmt-1 --body-file {}", summary.display())
    );
    let state = record_of(&path);
    assert_eq!(state["summary_comment"]["id"], "cmt-1");
    assert_eq!(state["stages"][1]["outcome"], "pass");
    // A refused post: the acceptance stands, the reply says why, and the
    // record keeps its comment.
    let third = next_round(dir.path(), &path);
    let out = accept_posting(
        &path,
        &log,
        &summary,
        &[],
        &third,
        "third.json",
        &[("LINEAR_STATUS", "3")],
    );
    let report = accepted_report(&out);
    assert_eq!(report["closed_now"], true);
    assert_eq!(report["summary"]["posted"], "failed");
    let cause = report["summary"]["cause"].as_str().unwrap();
    assert!(cause.starts_with("summary-update: exit 3"), "{cause}");
    let state = record_of(&path);
    assert_eq!(state["stages"][2]["outcome"], "pass");
    assert_eq!(state["summary_comment"]["id"], "cmt-1");
    assert_eq!(lines(&log).len(), 7);
}

/// The round's screenshots reach the item through the
/// acceptance's own post. The request's `attachments` are each an
/// `--attach` on the create; the links the CLI appended under the body
/// are read back from its answer and recorded beside the id; and every
/// later update renders them under the summary in a body file beside the
/// summary file, since the CLI's update replaces the body whole and takes
/// no `--attach`. A later request's attachments are not attached: the
/// create is the one upload. The defect: a captured screenshot never
/// reaching the item, which the dev agent posts no comment to, or an update
/// dropping the links the create carried.
#[test]
fn an_acceptance_with_attachments_creates_the_comment_with_each_and_every_update_keeps_their_links()
{
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let log = dir.path().join("linear.log");
    let written = "## Completion Summary\n\n### Screenshots\n- `tmp/ui-shots/a.png` - Settings, after, dark\n";
    let summary = write(dir.path(), "completion-summary-KEN-4687.md", written);
    let a = write(dir.path(), "a.png", "PNG");
    let b = write(dir.path(), "b.png", "PNG");
    let (link_a, record_a) = fixture_link("a.png");
    let (link_b, record_b) = fixture_link("b.png");
    let out = accept_posting(&path, &log, &summary, &[&a, &b], ROUND, "first.json", &[]);
    let report = accepted_report(&out);
    assert_eq!(report["summary"]["posted"], "created");
    assert_eq!(report["summary"]["id"], "cmt-1");
    assert_eq!(
        report["summary_comment"]["attachments"],
        json!([record_a, record_b])
    );
    let state = record_of(&path);
    assert_eq!(
        state["summary_comment"]["attachments"],
        json!([record_a, record_b])
    );
    assert_eq!(
        lines(&log),
        [
            "comments list KEN-4687".to_owned(),
            format!(
                "comments create KEN-4687 --body-file {} --attach {} --attach {}",
                summary.display(),
                a.display(),
                b.display()
            ),
            "body ## Completion Summary".to_owned(),
        ]
    );
    // The next round's acceptance: the update's body is the summary with
    // the recorded links under it; the round's own attachment is not sent.
    let second = next_round(dir.path(), &path);
    let c = write(dir.path(), "c.png", "PNG");
    let rewritten = "## Completion Summary\n\nround two\n";
    fs::write(&summary, rewritten).unwrap();
    let out = accept_posting(&path, &log, &summary, &[&c], &second, "second.json", &[]);
    let report = accepted_report(&out);
    assert_eq!(report["summary"]["posted"], "updated");
    assert_eq!(report["summary"]["id"], "cmt-1");
    let body = summary.with_extension("linear.md");
    assert_eq!(
        lines(&log)[3..],
        [
            format!("comments update cmt-1 --body-file {}", body.display()),
            "body ## Completion Summary".to_owned(),
            format!("link {link_a}"),
            format!("link {link_b}"),
        ]
    );
    assert_eq!(
        fs::read_to_string(&body).unwrap(),
        format!("{}\n\n{link_a}\n\n{link_b}\n", rewritten.trim_end())
    );
    let state = record_of(&path);
    assert_eq!(
        state["summary_comment"]["attachments"],
        json!([record_a, record_b])
    );
    assert_eq!(state["summary_comment"]["at"], report["summary"]["at"]);
    assert_eq!(state["stages"][1]["outcome"], "pass");
}

/// A record written with an `origin` word names the comment the acceptance
/// updates in place; the word is read past and the record after carries
/// none. The defect: an item whose record carries the word refused, or its
/// comment not updated.
#[test]
fn a_summary_comment_recorded_with_an_origin_word_reads_without_it_and_is_updated_in_place() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let log = dir.path().join("linear.log");
    let summary = write(
        dir.path(),
        "completion-summary-KEN-4687.md",
        "## Completion Summary\n\nround two\n",
    );
    let mut state = record_of(&path);
    state["summary_comment"] =
        json!({"id": "cmt-1", "at": "2026-11-01T10:05:00Z", "origin": "found"});
    fs::write(&path, serde_json::to_string_pretty(&state).unwrap()).unwrap();
    let out = accept_posting(&path, &log, &summary, &[], ROUND, "first.json", &[]);
    let report = accepted_report(&out);
    assert_eq!(report["closed_now"], true);
    assert_eq!(report["summary"]["posted"], "updated");
    assert_eq!(report["summary"]["id"], "cmt-1");
    assert_eq!(
        lines(&log),
        [
            format!("comments update cmt-1 --body-file {}", summary.display()),
            "body ## Completion Summary".to_owned(),
        ]
    );
    let state = record_of(&path);
    assert_eq!(state["summary_comment"]["id"], "cmt-1");
    assert_eq!(state["summary_comment"].get("origin"), None);
    assert_eq!(state["summary_comment"]["at"], report["summary"]["at"]);
}

/// A runtime that ended after the CLI created the comment and before the id's
/// record (the fixture kills it inside the create) leaves the comment on the
/// item with no `summary_comment`. The next acceptance's list names it, the
/// newest headed `## Completion Summary` on any page of the list, not an older
/// headed comment, a comment mentioning the words or one quoting the heading;
/// records it with the links its body carries; and updates it in place with
/// those links kept: one comment, one create. The defect: the crash replay
/// creating a second summary, recording a comment that is not the item's
/// summary, a summary past the list's first page re-created, or the found
/// comment's links lost by the update.
#[test]
fn an_acceptance_after_a_crash_inside_the_create_finds_the_comment_on_any_page_and_updates_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let log = dir.path().join("linear.log");
    let written = "## Completion Summary\n\nround one\n";
    let summary = write(dir.path(), "completion-summary-KEN-4687.md", written);
    let a = write(dir.path(), "a.png", "PNG");
    let (link_a, record_a) = fixture_link("a.png");
    let out = accept_posting(
        &path,
        &log,
        &summary,
        &[&a],
        ROUND,
        "first.json",
        &[("LINEAR_KILL", "create")],
    );
    assert!(!out.status.success(), "the runtime survived the kill");
    // The crash's leavings: the close committed, the create went out, the
    // record holds no id.
    let state = record_of(&path);
    assert_eq!(state["stages"][0]["outcome"], "pass");
    assert_eq!(state.get("summary_comment"), None);
    assert_eq!(lines(&log).len(), 3, "{:?}", lines(&log));
    let second = next_round(dir.path(), &path);
    let page_one = json!([
        listed(
            "cmt-old",
            "## Completion Summary\n\nan earlier round's",
            "2026-11-01T09:00:00.000Z"
        ),
        listed(
            "cmt-blocked",
            "Blocked on KEN-1: see the Completion Summary of KEN-1",
            "2026-11-01T11:00:00.000Z"
        ),
    ]);
    let page_two = json!([
        listed(
            "cmt-1",
            &format!("{}\n\n{link_a}\n", written.trim_end()),
            "2026-11-01T10:00:00.000Z"
        ),
        listed(
            "cmt-quote",
            "> ## Completion Summary\n\nquoted",
            "2026-11-01T12:00:00.000Z"
        ),
    ]);
    let rewritten = "## Completion Summary\n\nround two\n";
    fs::write(&summary, rewritten).unwrap();
    let out = accept_posting(
        &path,
        &log,
        &summary,
        &[],
        &second,
        "second.json",
        &[
            ("LINEAR_COMMENTS", &page_one.to_string()),
            ("LINEAR_COMMENTS_MORE", &page_two.to_string()),
        ],
    );
    let report = accepted_report(&out);
    assert_eq!(report["closed_now"], true);
    assert_eq!(report["summary"]["posted"], "updated");
    assert_eq!(report["summary"]["id"], "cmt-1");
    let state = record_of(&path);
    assert_eq!(state["summary_comment"]["id"], "cmt-1");
    assert_eq!(state["summary_comment"]["attachments"], json!([record_a]));
    let posts = lines(&log);
    assert_eq!(
        posts
            .iter()
            .filter(|l| l.starts_with("comments create"))
            .count(),
        1,
        "{posts:?}"
    );
    let body = summary.with_extension("linear.md");
    assert_eq!(
        posts[3..],
        [
            "comments list KEN-4687".to_owned(),
            format!("comments update cmt-1 --body-file {}", body.display()),
            "body ## Completion Summary".to_owned(),
            format!("link {link_a}"),
        ]
    );
    assert_eq!(
        fs::read_to_string(&body).unwrap(),
        format!("{}\n\n{link_a}\n", rewritten.trim_end())
    );
}

/// A list that fails (the CLI refused, could not run, or
/// answered no list) creates nothing, since whether a comment exists is not
/// known; the acceptance stands with `failed` and the cause, and the next
/// acceptance asks again. The defect: an unreadable list read as an empty
/// one, creating a comment beside one that may exist.
#[test]
fn a_failed_comment_list_creates_no_summary_and_the_acceptance_stands() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(dir.path(), "workflow-state-KEN-4687.json", ITEM);
    let log = dir.path().join("linear.log");
    let summary = write(
        dir.path(),
        "completion-summary-KEN-4687.md",
        "## Completion Summary\n\nround one\n",
    );
    let out = accept_posting(
        &path,
        &log,
        &summary,
        &[],
        ROUND,
        "first.json",
        &[("LINEAR_LIST_STATUS", "5")],
    );
    let report = accepted_report(&out);
    assert_eq!(report["closed_now"], true);
    assert_eq!(report["summary"]["posted"], "failed");
    let cause = report["summary"]["cause"].as_str().unwrap();
    assert!(cause.starts_with("summary-list: exit 5"), "{cause}");
    let state = record_of(&path);
    assert_eq!(state["stages"][0]["outcome"], "pass");
    assert_eq!(state.get("summary_comment"), None);
    assert_eq!(lines(&log), ["comments list KEN-4687"]);
    // A list that is not a list: the same, with its cause.
    let out = accept_posting(
        &path,
        &log,
        &summary,
        &[],
        ROUND,
        "repeat.json",
        &[("LINEAR_COMMENTS", "not a list")],
    );
    let report = accepted_report(&out);
    assert_eq!(report["closed_now"], false);
    assert_eq!(report["summary"]["posted"], "failed");
    let cause = report["summary"]["cause"].as_str().unwrap();
    assert!(cause.starts_with("summary-list: answer:"), "{cause}");
    assert_eq!(lines(&log).len(), 2);
    // The next acceptance's list answers: none, so the comment is created.
    let out = accept_posting(&path, &log, &summary, &[], ROUND, "again.json", &[]);
    let report = accepted_report(&out);
    assert_eq!(report["summary"]["posted"], "created");
    assert_eq!(record_of(&path)["summary_comment"]["id"], "cmt-1");
    let posts = lines(&log);
    assert_eq!(posts.len(), 5, "{posts:?}");
    assert_eq!(
        posts[3],
        format!("comments create KEN-4687 --body-file {}", summary.display())
    );
}

/// A round records the item body revision its caller read and says when it is
/// later than the kind's previous round's; a first round, an equal or older
/// revision and a round handed none report no move. The defect: a round that
/// reads a moved body and says nothing.
#[test]
fn begin_round_records_the_body_revision_and_reports_body_moved_past_the_previous_rounds() {
    let dir = tempfile::tempdir().unwrap();
    let path = item_file(dir.path());
    let rows = [
        (
            RoundKind::Dev,
            Some("2026-01-29T15:20:00.000Z"),
            false,
            "the first recorded revision",
        ),
        (
            RoundKind::Dev,
            Some("2026-01-29T15:20:00.000Z"),
            false,
            "an equal revision",
        ),
        (
            RoundKind::Dev,
            Some("2026-01-29T16:00:00.000Z"),
            true,
            "a later revision",
        ),
        (RoundKind::Dev, None, false, "none handed"),
        (
            RoundKind::Review,
            Some("2026-01-29T16:30:00.000Z"),
            false,
            "another kind's first",
        ),
        (
            RoundKind::Dev,
            Some("2026-01-29T15:30:00.000Z"),
            false,
            "an older one, recorded and not judged",
        ),
        (
            RoundKind::Dev,
            Some("2026-01-29T17:00:00.000Z"),
            true,
            "later than the last recorded",
        ),
    ];
    for (kind, revision, moved, note) in rows {
        let request = Request::BeginRound(BeginRound {
            kind,
            body_revision: revision.map(str::to_owned),
        });
        let b = begun(run(&path, &request).unwrap());
        assert_eq!(b.body_moved, moved, "{note}");
        let doc = object(&path);
        let last = doc["stages"].as_array().unwrap().last().unwrap();
        assert_eq!(last["round_id"], b.round_id, "{note}");
        assert_eq!(
            last.get("body_revision").and_then(Value::as_str),
            revision,
            "{note}"
        );
    }
    // The wire names.
    let request = write(
        dir.path(),
        "begin.json",
        r#"{"op": "begin-round", "kind": "dev", "body_revision": "2026-01-29T18:00:00.000Z"}"#,
    );
    let out = op(&path, &request);
    assert!(out.status.success(), "{}", first_stderr_line(&out));
    let report = reply(&out)["result"]["report"].clone();
    assert_eq!(report["body_moved"], true);
    let state = record_of(&path);
    let last = state["stages"].as_array().unwrap().last().unwrap();
    assert_eq!(last["body_revision"], "2026-01-29T18:00:00.000Z");
}
