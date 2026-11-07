//! Validation admission, execution, record reads and proof coverage.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows run the real binary in isolated repositories and hold their own children"
)]
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{Duration, Instant};
mod support;
use serde_json::{Value, json};
use support::{Owned, fixtures, program, reply, stderr, tool_path};
const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
const ROUND: &str = "1769600000123456789-1837";
const ITEM_ID: &str = "KEN-4687";
const JOB_BOUND: Duration = Duration::from_secs(30);
struct World {
    _dir: tempfile::TempDir,
    root: PathBuf,
    state: PathBuf,
    item: PathBuf,
    worktree: PathBuf,
}

fn git(worktree: &Path, args: &[&str]) -> String {
    let out = program("git")
        .arg("-C")
        .arg(worktree)
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let state = root.join("state");
        fs::create_dir_all(&state).unwrap();
        let worktree = root.join("wt");
        fs::create_dir_all(worktree.join("tmp")).unwrap();
        git(&worktree, &["init", "-q", "-b", "main"]);
        git(&worktree, &["config", "gc.auto", "0"]);
        git(&worktree, &["config", "maintenance.auto", "false"]);
        fs::write(worktree.join("a.txt"), "a\n").unwrap();
        fs::write(worktree.join(".gitignore"), "tmp\n").unwrap();
        fs::write(worktree.join("kendex.settings.toml"), "[env]\nHARNESS_CI_PER_PUSH_REASON = \"fixture exercises per-push coverage\"\nHARNESS_CI_QUEUE_PATHS = \"queue.rs\"\n").unwrap();
        git(
            &worktree,
            &["add", "a.txt", ".gitignore", "kendex.settings.toml"],
        );
        git(&worktree, &["commit", "-q", "-m", "base"]);
        git(
            &worktree,
            &["update-ref", "refs/remotes/origin/main", "HEAD"],
        );
        let item = state.join(format!("workflow-state-{ITEM_ID}.json"));
        fs::write(
            &item,
            ITEM.replacen(
                "\"worktree\": \"/home/u/dev/.worktrees/kendex/ken-4687\"",
                &format!("\"worktree\": \"{}\"", worktree.display()),
                1,
            ),
        )
        .unwrap();
        World {
            _dir: dir,
            root,
            state,
            item,
            worktree,
        }
    }

    fn commit(&self, name: &str) -> String {
        fs::create_dir_all(self.worktree.join(name).parent().unwrap()).unwrap();
        fs::write(self.worktree.join(name), format!("{name}\n")).unwrap();
        git(&self.worktree, &["add", name]);
        git(&self.worktree, &["commit", "-q", "-m", name]);
        git(&self.worktree, &["rev-parse", "HEAD"])
    }

    fn head(&self) -> String {
        git(&self.worktree, &["rev-parse", "HEAD"])
    }

    fn env(&self) -> Vec<(String, String)> {
        let scripts = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("scripts");
        let scope = scripts.join("../../change-scope/scripts/harness-only");
        vec![
            (
                "DEV_VALIDATE_CLI".into(),
                scripts.join("dev-validate-run").display().to_string(),
            ),
            ("CHANGE_SCOPE_PATHS_CLI".into(), scope.display().to_string()),
            ("DEV_VALIDATE_CMD".into(), "echo full".into()),
            ("DEV_VALIDATE_TIMEOUT_SECS".into(), "20".into()),
            ("ORCH_STATE_DIR".into(), self.state.display().to_string()),
            ("ORCH_PR_ORDER".into(), "review-first".into()),
            ("ORCH_DELIVERY".into(), "push-base".into()),
            (
                "LANE_MAIL_CLI".into(),
                scripts
                    .join("../../mailbox/scripts/lane-mail")
                    .display()
                    .to_string(),
            ),
            (
                "LANE_MAIL_DIR".into(),
                self.root.join("mail").display().to_string(),
            ),
        ]
    }

    fn run(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut command = support::isolated();
        command
            .arg("--state-dir")
            .arg(&self.state)
            .args(args)
            .current_dir(&self.worktree);
        for (k, v) in self.env() {
            command.env(k, v);
        }
        for (k, v) in extra {
            command.env(k, v);
        }
        command.output().unwrap()
    }

    fn start(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut full = vec![
            "validate", "start", "--item", ITEM_ID, "--round", ROUND, "--poll", "1",
        ];
        full.extend_from_slice(args);
        self.run(&full, extra)
    }

    fn state(&self) -> Value {
        serde_json::from_str(&fs::read_to_string(&self.item).unwrap()).unwrap()
    }

    fn write_state(&self, value: &Value) {
        fs::write(&self.item, serde_json::to_string_pretty(value).unwrap()).unwrap();
    }

    fn stage_in(doc: &Value, run_dir: &str) -> Value {
        doc["stages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["kind"] == "validate" && s["run_dir"] == run_dir)
            .cloned()
            .unwrap_or_else(|| panic!("no validate stage for {run_dir} in {doc}"))
    }

    fn stage(&self, run_dir: &str) -> Value {
        World::stage_in(&self.state(), run_dir)
    }

    fn wait_closed(&self, run_dir: &str) -> Value {
        let deadline = Instant::now() + JOB_BOUND;
        loop {
            let stage = self.stage(run_dir);
            if !stage["end"].is_null() {
                return stage;
            }
            assert!(Instant::now() < deadline, "the run never closed: {stage}");
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    fn wait_marked(&self, run_dir: &str) -> Value {
        let deadline = Instant::now() + JOB_BOUND;
        loop {
            let stage = self.stage(run_dir);
            if stage["notice"]["owner"]
                .as_str()
                .is_some_and(|o| o != "owed")
            {
                return stage;
            }
            assert!(
                Instant::now() < deadline,
                "the notice was never marked: {stage}"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    fn op(&self, request: &Value, extra: &[(&str, &str)]) -> Output {
        let path = self.root.join("request.json");
        fs::write(&path, request.to_string()).unwrap();
        self.run(
            &[
                "op",
                "--item",
                ITEM_ID,
                "--request",
                &path.display().to_string(),
            ],
            extra,
        )
    }
}

fn ok(out: &Output) -> Value {
    assert!(
        out.status.success(),
        "{}\n{}",
        stderr(out),
        String::from_utf8_lossy(&out.stdout)
    );
    reply(out)["result"].clone()
}
fn refusal(out: &Output) -> String {
    assert_eq!(out.status.code(), Some(1), "{}", stderr(out));
    reply(out)["refusal"]["key"].as_str().unwrap().into()
}
fn run_file(dir: &str, name: &str) -> String {
    fs::read_to_string(Path::new(dir).join(name)).unwrap_or_default()
}
impl World {
    fn entry(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut full = vec!["validate", "entry"];
        full.extend_from_slice(args);
        self.run(&full, extra)
    }
    fn local(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let wt = self.worktree.display().to_string();
        let mut full = vec!["--worktree", wt.as_str(), "--foreground", "--poll", "1"];
        full.extend_from_slice(args);
        self.entry(&full, extra)
    }
}
fn text(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).trim().into()
}
fn directory(out: &Output) -> String {
    text(out)
        .lines()
        .find_map(|line| line.strip_prefix("state=started run-dir="))
        .and_then(|line| line.split_whitespace().next())
        .unwrap_or_else(|| panic!("{} {}", text(out), stderr(out)))
        .into()
}
fn field(line: &str, key: &str) -> String {
    line.split_whitespace()
        .find_map(|w| w.strip_prefix(&format!("{key}=")))
        .unwrap_or("")
        .into()
}
fn read_record(w: &World, dir: &str) -> String {
    let out = w.entry(&["--record", "--run-dir", dir], &[]);
    assert!(out.status.success(), "{}", stderr(&out));
    text(&out)
}
#[allow(
    clippy::too_many_arguments,
    reason = "each persisted proof field is varied independently by the coverage rows"
)]
fn proof_row(
    run: &str,
    mode: &str,
    tree: &str,
    head: &str,
    base: &str,
    selection: &str,
    scoped: bool,
    outcome: Option<&str>,
    start: u64,
) -> Value {
    let cmd = match mode {
        "full" => "echo full",
        _ => "echo range",
    };
    let mut proof = json!({
        "tree": tree, "head": head, "base": base, "mode": mode, "caller": "dev",
        "cmd": cmd, "class": "standard", "docs_only": false, "paths_hash": "",
        "scoped": scoped, "selection": selection, "finding_prefix": "",
        "timeout_secs": 20, "poll_secs": 1, "cap_secs": 31,
    });
    if mode == "range" {
        proof["class_base"] = json!(base);
    }
    let mut row = json!({
        "kind": "validate", "round_id": ROUND, "start": start, "end": Value::Null,
        "run_dir": format!("/w/tmp/dev-validate-{run}"), "proof": proof,
    });
    if let Some(outcome) = outcome {
        row["end"] = json!(start + 1);
        row["outcome"] = json!(outcome);
    }
    row
}

impl World {
    fn plant(&self, rows: &[Value], restack_skips: &[Value]) {
        let mut state = self.state();
        let mut stages = vec![state["stages"][0].clone()];
        stages.extend_from_slice(rows);
        state["stages"] = json!(stages);
        if !restack_skips.is_empty() {
            state["restack_skips"] = json!(restack_skips);
        }
        self.write_state(&state);
    }

    fn read_proof(&self, args: &[&str], extra: &[(&str, &str)]) -> Value {
        let mut full = vec!["read-proof", "--item", ITEM_ID];
        full.extend_from_slice(args);
        ok(&self.run(&full, extra))
    }
}

const RANGE_DECLARED: [(&str, &str); 1] = [("DEV_VALIDATE_RANGE_CMD", "echo range")];
const CI_DECLARED: [(&str, &str); 2] = [
    ("DEV_VALIDATE_RANGE_CMD", "echo range"),
    ("DEV_VALIDATE_CI_CONTEXT", "CI"),
];

#[test]
fn a_whole_tree_full_pass_is_complete_for_every_need_at_its_tree() {
    let w = World::new();
    w.plant(
        &[proof_row(
            "battery",
            "full",
            "t1",
            "h1",
            "",
            "battery",
            false,
            Some("pass"),
            10,
        )],
        &[],
    );
    for declaration in [&[][..], &RANGE_DECLARED[..], &CI_DECLARED[..]] {
        for need in ["round", "submit", "restack"] {
            let read = w.read_proof(
                &["--need", need, "--tree", "t1", "--base", "elsewhere"],
                declaration,
            );
            assert_eq!(read["proof"], "complete", "{need} {declaration:?}: {read}");
            assert_eq!(read["rows"][0]["run_dir"], "/w/tmp/dev-validate-battery");
            assert_eq!(read["rows"].as_array().unwrap().len(), 1);
            assert!(read.get("lacks").is_none());
        }
    }
    w.plant(
        &[proof_row(
            "branch",
            "full",
            "t1",
            "h1",
            "",
            "all",
            false,
            Some("pass"),
            10,
        )],
        &[],
    );
    let read = w.read_proof(&["--need", "submit", "--tree", "t1"], &[]);
    assert_eq!(read["proof"], "complete");
    let read = w.read_proof(&["--need", "submit", "--tree", "t2"], &[]);
    assert_eq!(read["proof"], "missing");
    assert_eq!(read["lacks"], json!({"tree": "t2", "mode": "full"}));
}

#[test]
fn a_range_pass_is_complete_for_publication_where_range_is_declared_and_its_rows_cover_the_need() {
    let w = World::new();
    let h0 = w.head();
    let t0 = git(&w.worktree, &["rev-parse", "HEAD^{tree}"]);
    let h1 = w.commit("b.txt");
    let t1 = git(&w.worktree, &["rev-parse", "HEAD^{tree}"]);
    w.plant(
        &[
            proof_row("impl", "full", &t0, &h0, "", "all", false, Some("pass"), 10),
            proof_row(
                "fix",
                "range",
                &t1,
                &h1,
                &h0,
                "all",
                false,
                Some("pass"),
                20,
            ),
        ],
        &[],
    );
    let read = w.read_proof(
        &["--need", "submit", "--tree", &t1, "--base", "merge-base"],
        &RANGE_DECLARED,
    );
    assert_eq!(read["proof"], "complete", "{read}");
    assert_eq!(
        read["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["run_dir"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        ["/w/tmp/dev-validate-fix", "/w/tmp/dev-validate-impl"]
    );
    w.plant(
        &[
            proof_row("impl", "full", &t0, &h0, "", "all", false, Some("pass"), 10),
            proof_row(
                "fix",
                "range",
                &t1,
                &h1,
                "no-such-commit",
                "all",
                false,
                Some("pass"),
                20,
            ),
        ],
        &[],
    );
    let read = w.read_proof(
        &["--need", "submit", "--tree", &t1, "--base", "merge-base"],
        &RANGE_DECLARED,
    );
    assert_eq!(read["proof"], "missing");
    assert_eq!(read["lacks"], json!({"tree": t1, "mode": "range"}));
    w.plant(
        &[proof_row(
            "restack",
            "range",
            "t-restacked",
            "h-restacked",
            "base-moved",
            "all",
            false,
            Some("pass"),
            30,
        )],
        &[],
    );
    let covered = [
        "--need",
        "restack",
        "--tree",
        "t-restacked",
        "--head",
        "h-restacked",
        "--base",
        "base-moved",
    ];
    let read = w.read_proof(&covered, &RANGE_DECLARED);
    assert_eq!(read["proof"], "complete", "{read}");
    assert_eq!(read["rows"][0]["run_dir"], "/w/tmp/dev-validate-restack");
    let read = w.read_proof(
        &[
            "--need",
            "restack",
            "--tree",
            "t-restacked",
            "--head",
            "h-restacked",
            "--base",
            "base-moved-again",
        ],
        &RANGE_DECLARED,
    );
    assert_eq!(read["proof"], "missing");
    assert_eq!(
        read["lacks"],
        json!({"tree": "t-restacked", "mode": "range"})
    );
    let read = w.read_proof(&covered, &[]);
    assert_eq!(read["proof"], "missing");
    assert_eq!(
        read["lacks"],
        json!({"tree": "t-restacked", "mode": "full"})
    );
    let read = w.read_proof(&covered, &CI_DECLARED);
    assert_eq!(read["proof"], "missing");
    assert_eq!(read["lacks"], json!({"tree": "t-restacked", "mode": "ci"}));
    let read = w.read_proof(
        &[
            "--need",
            "round",
            "--tree",
            "t-restacked",
            "--base",
            "base-moved",
        ],
        &CI_DECLARED,
    );
    assert_eq!(read["proof"], "complete");
}

#[test]
fn a_scoped_row_is_never_proof_and_a_ci_row_reads_pending() {
    let w = World::new();
    w.plant(
        &[proof_row(
            "scoped",
            "full",
            "t1",
            "h1",
            "",
            "subset",
            true,
            Some("pass"),
            10,
        )],
        &[],
    );
    let read = w.read_proof(&["--need", "submit", "--tree", "t1"], &[]);
    assert_eq!(read["proof"], "missing", "{read}");
    assert_eq!(read["lacks"], json!({"tree": "t1", "mode": "full"}));
    let mut ci = proof_row(
        "ci",
        "ci",
        "t1",
        "h1",
        "base",
        "unreported",
        false,
        Some("pass"),
        20,
    );
    ci["proof"]["ci_event"] = json!("pull_request");
    w.plant(&[ci], &[]);
    for need in ["round", "submit"] {
        let read = w.read_proof(&["--need", need, "--tree", "t1"], &CI_DECLARED);
        assert_eq!(read["proof"], "pending", "{need}: {read}");
        assert_eq!(read["rows"][0]["mode"], "ci");
        assert!(read.get("lacks").is_none());
    }
}

#[test]
fn a_later_red_row_at_the_same_tree_voids_the_earlier_pass() {
    let w = World::new();
    w.plant(
        &[
            proof_row(
                "pass",
                "full",
                "t1",
                "h1",
                "",
                "battery",
                false,
                Some("pass"),
                10,
            ),
            proof_row(
                "red",
                "full",
                "t1",
                "h1",
                "",
                "all",
                false,
                Some("fail"),
                20,
            ),
        ],
        &[],
    );
    let read = w.read_proof(&["--need", "submit", "--tree", "t1"], &[]);
    assert_eq!(read["proof"], "missing", "{read}");
    w.plant(
        &[
            proof_row(
                "red",
                "full",
                "t1",
                "h1",
                "",
                "all",
                false,
                Some("fail"),
                10,
            ),
            proof_row(
                "pass",
                "full",
                "t1",
                "h1",
                "",
                "battery",
                false,
                Some("pass"),
                20,
            ),
        ],
        &[],
    );
    assert_eq!(
        w.read_proof(&["--need", "submit", "--tree", "t1"], &[])["proof"],
        "complete"
    );
    w.plant(
        &[
            proof_row(
                "pass",
                "full",
                "t1",
                "h1",
                "",
                "battery",
                false,
                Some("pass"),
                10,
            ),
            proof_row("open", "full", "t1", "h1", "", "all", false, None, 30),
        ],
        &[],
    );
    assert_eq!(
        w.read_proof(&["--need", "submit", "--tree", "t1"], &[])["proof"],
        "missing"
    );
}

#[test]
fn a_restack_reads_its_recorded_skip_by_the_head_and_takes_the_validated_runs_tree() {
    let w = World::new();
    let skip = json!({"head": "h-restacked", "condition": "no-conflict", "validated_head": "h0", "paths": []});
    w.plant(
        &[proof_row(
            "impl",
            "full",
            "t0",
            "h0",
            "",
            "battery",
            false,
            Some("pass"),
            10,
        )],
        std::slice::from_ref(&skip),
    );
    let read = w.read_proof(
        &[
            "--need",
            "restack",
            "--tree",
            "t-restacked",
            "--head",
            "h-restacked",
        ],
        &[],
    );
    assert_eq!(read["proof"], "complete", "{read}");
    assert_eq!(read["rows"][0]["tree"], "t0");
    assert_eq!(
        read["skip"],
        json!({"head": "h-restacked", "validated_head": "h0"})
    );
    w.plant(
        &[proof_row(
            "fix",
            "range",
            "t0",
            "h0",
            "b",
            "all",
            false,
            Some("pass"),
            10,
        )],
        &[skip],
    );
    let read = w.read_proof(
        &[
            "--need",
            "restack",
            "--tree",
            "t-restacked",
            "--head",
            "h-restacked",
        ],
        &[],
    );
    assert_eq!(read["proof"], "missing");
    assert_eq!(
        read["lacks"],
        json!({"tree": "t-restacked", "mode": "full"})
    );
}

#[test]
fn a_restacked_trees_own_red_row_outranks_its_recorded_skip() {
    let w = World::new();
    let skip = json!({"head": "h-restacked", "condition": "version-only", "validated_head": "h-original", "paths": []});
    let original = proof_row(
        "original",
        "full",
        "t-original",
        "h-original",
        "",
        "battery",
        false,
        Some("pass"),
        10,
    );
    let restacked = |run: &str, outcome: Option<&str>, start: u64| {
        proof_row(
            run,
            "full",
            "t-restacked",
            "h-restacked",
            "",
            "all",
            false,
            outcome,
            start,
        )
    };
    let ask = [
        "--need",
        "restack",
        "--tree",
        "t-restacked",
        "--head",
        "h-restacked",
    ];
    w.plant(
        &[
            original.clone(),
            restacked("restacked-pass", Some("pass"), 20),
            restacked("restacked-red", Some("fail"), 30),
        ],
        std::slice::from_ref(&skip),
    );
    let read = w.read_proof(&ask, &[]);
    assert_eq!(read["proof"], "missing", "{read}");
    assert_eq!(
        read["lacks"],
        json!({"tree": "t-restacked", "mode": "full"})
    );
    assert_eq!(read.get("skip"), None);
    for own in [
        restacked("restacked-red", Some("fail"), 30),
        restacked("restacked-open", None, 30),
    ] {
        w.plant(&[original.clone(), own], std::slice::from_ref(&skip));
        let read = w.read_proof(&ask, &[]);
        assert_eq!(read["proof"], "missing", "{read}");
    }
    w.plant(std::slice::from_ref(&original), std::slice::from_ref(&skip));
    let read = w.read_proof(&ask, &[]);
    assert_eq!(read["proof"], "complete", "{read}");
    assert_eq!(read["rows"][0]["tree"], "t-original");
}

#[test]
fn command_exits_and_signals_keep_their_native_verdict_and_atomic_timing() {
    for (command, status, verdict) in [
        ("echo output; exit 0", "0", "pass"),
        ("exit 1", "1", "FAILING"),
        ("exit 3", "3", "no-verdict"),
        ("exit 124", "124", "FAILING"),
        ("exit 137", "137", "FAILING"),
        ("kill -TERM $$", "143", "FAILING"),
        ("kill -INT $$", "130", "FAILING"),
        ("kill -QUIT $$", "0", "pass"),
    ] {
        let w = World::new();
        let out = w.local(&[], &[("DEV_VALIDATE_CMD", command)]);
        assert_eq!(
            out.status.code(),
            Some(i32::from(status != "0")),
            "{}",
            stderr(&out)
        );
        let dir = directory(&out);
        let sentinel = run_file(&dir, "exit");
        assert_eq!(field(&sentinel, "guard-exit"), status);
        assert_eq!(
            field(text(&out).lines().last().unwrap(), "validate"),
            verdict
        );
        assert!(Path::new(&dir).join("own-exit").exists());
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "verdict"), verdict);
        assert_eq!(field(&record, "ended-at"), field(&sentinel, "at"));
        assert!(!field(&record, "started-at").is_empty());
        assert!(!field(&record, "seconds").is_empty());
        assert_eq!(sentinel.contains("cause=host"), status == "3");
        assert!(!Path::new(&dir).join("exit.part").exists());
    }
}

#[test]
fn the_executor_uses_bash_and_replaces_inherited_validation_context() {
    let w = World::new();
    w.commit("src.rs");
    let command = "[[ -n $BASH_VERSION ]] && printf '%s|%s|%s|%s|%s\n' \"$DEV_VALIDATE_CLASS\" \"$DEV_VALIDATE_DOCS_ONLY\" \"$DEV_VALIDATE_SCOPED\" \"$DEV_VALIDATE_BASE\" \"$(cat \"$DEV_VALIDATE_PATHS\")\"";
    let out = w.local(
        &[],
        &[
            ("DEV_VALIDATE_CMD", command),
            ("DEV_VALIDATE_CLASS", "wrong"),
            ("DEV_VALIDATE_DOCS_ONLY", "wrong"),
            ("DEV_VALIDATE_SCOPED", "wrong"),
            ("DEV_VALIDATE_BASE", "wrong"),
            ("DEV_VALIDATE_PATHS", "wrong"),
        ],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    let dir = directory(&out);
    let log = run_file(&dir, "log");
    assert!(log.starts_with("runner=attached\n"), "{log}");
    assert!(!log.contains("wrong"), "{log}");
    assert!(log.contains("|false|false||src.rs"), "{log}");
    assert_eq!(field(&read_record(&w, &dir), "head"), w.head());
}

#[test]
fn the_started_and_done_lines_and_run_inventory_keep_the_reader_contract() {
    let w = World::new();
    let old = w.worktree.join("tmp/dev-validate-before");
    fs::create_dir(&old).unwrap();
    fs::write(old.join("start"), "validate-mode=ci\nstart=1\n").unwrap();
    fs::write(old.join("exit"), "guard-exit=0 at=2026-01-01T00:00:00Z\n").unwrap();
    let out = w.local(&[], &[]);
    assert!(out.status.success(), "{}", stderr(&out));
    let dir = directory(&out);
    let first = text(&out).lines().next().unwrap().to_owned();
    assert!(first.starts_with(&format!("state=started run-dir={dir} log={dir}/log sentinel={dir}/exit timeout-secs=20 poll-secs=1 cap-secs=31 class=")),"{first}");
    assert!(
        text(&out)
            .lines()
            .last()
            .unwrap()
            .starts_with("state=done guard-exit=0 at=")
    );
    let index = fs::read_to_string(w.worktree.join("tmp/validation-runs")).unwrap();
    assert_eq!(index.lines().next(), Some("dev-validate-runs-v1"));
    assert!(index.lines().any(|n| n == "dev-validate-before"));
    assert!(
        index
            .lines()
            .any(|n| n == Path::new(&dir).file_name().unwrap())
    );
}

#[test]
fn record_reads_the_last_valid_selection_candidate_and_refuses_unreadable_evidence() {
    let rows = [
        (
            "validate: lanes=one,two.three-4 selection=battery",
            "one,two.three-4",
            "battery",
        ),
        ("validate: lanes=one selection=all", "one", "all"),
        ("validate: lanes=one selection=subset", "one", "subset"),
        ("validate: lanes=one, selection=all", "", "unreported"),
        ("validate: lanes=one selection=other", "", "unreported"),
        (
            "validate: lanes=one selection=all extra=yes",
            "",
            "unreported",
        ),
        ("validate:  lanes=one selection=all", "", "unreported"),
    ];
    for (line, lanes, selection) in rows {
        let w = World::new();
        let out = w.local(&[], &[]);
        let dir = directory(&out);
        fs::write(
            Path::new(&dir).join("log"),
            format!("runner=attached\nvalidate: lanes=before selection=all\n{line}\n"),
        )
        .unwrap();
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "lanes"), lanes);
        assert_eq!(field(&record, "selection"), selection);
        fs::write(Path::new(&dir).join("timing"), "seconds=wrong\n").unwrap();
        let refused = w.entry(&["--record", "--run-dir", &dir], &[]);
        assert_eq!(refused.status.code(), Some(2));
        assert!(stderr(&refused).contains("timing-unreadable"));
        fs::write(
            Path::new(&dir).join("exit"),
            "guard-exit=not-a-number at=2026-01-01T00:00:00Z\n",
        )
        .unwrap();
        let refused = w.entry(&["--record", "--run-dir", &dir], &[]);
        assert_eq!(refused.status.code(), Some(2));
        assert!(stderr(&refused).contains("sentinel-unreadable"));
    }
}

#[test]
fn a_docs_only_tree_runs_the_real_selectors_text_checks_and_its_pass_is_submit_proof() {
    let w = World::new();
    let base = w.head();
    w.commit("note.md");
    let selector = "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then printf 'text-checks\nvalidate: lanes=text selection=subset\n'; else printf 'selection=subset\n'; fi";
    let out = w.start(
        &["--base", &base, "--foreground"],
        &[
            ("DEV_VALIDATE_RANGE_CMD", "echo product-range"),
            ("DEV_VALIDATE_SELECTION_CMD", selector),
        ],
    );
    let result = ok(&out);
    assert_eq!(result["mode"], "docs");
    assert_eq!(result["docs_only"], true);
    let dir = result["run_dir"].as_str().unwrap();
    let log = run_file(dir, "log");
    assert!(log.contains("text-checks"), "{log}");
    assert!(!log.contains("product-range"));
    let stage = w.stage(dir);
    assert_eq!(stage["proof"]["scoped"], true);
    assert_eq!(stage["outcome"], "pass");
    assert_eq!(stage["proof"]["class_base"], Value::Null);
    assert_eq!(stage["proof"]["base"], "");
    let tree = git(&w.worktree, &["rev-parse", "HEAD^{tree}"]);
    let proof = w.read_proof(
        &["--tree", &tree, "--head", &w.head(), "--need", "submit"],
        &[
            ("DEV_VALIDATE_RANGE_CMD", "echo product-range"),
            ("DEV_VALIDATE_SELECTION_CMD", selector),
        ],
    );
    assert_eq!(proof["proof"], "complete");
    assert_eq!(proof["rows"][0]["run_dir"], dir);
}

#[test]
fn docs_mode_uses_the_declared_text_command_and_keeps_the_range_fallback_explicit() {
    for text_command in [Some("echo text-command"), None] {
        let w = World::new();
        let base = w.head();
        w.commit("docs/screen.txt");
        let mut extra = vec![("DEV_VALIDATE_RANGE_CMD", "echo range-command")];
        if let Some(cmd) = text_command {
            extra.push(("DEV_VALIDATE_TEXT_CMD", cmd));
        }
        let result = ok(&w.start(&["--base", &base, "--foreground"], &extra));
        assert_eq!(
            result["mode"],
            if text_command.is_some() {
                "docs"
            } else {
                "range"
            }
        );
        let log = run_file(result["run_dir"].as_str().unwrap(), "log");
        assert!(
            log.contains(if text_command.is_some() {
                "text-command"
            } else {
                "range-command"
            }),
            "{log}"
        );
    }
}

#[test]
fn docs_scope_is_not_proof_when_the_record_does_not_describe_a_docs_only_tree() {
    let w = World::new();
    let mut row = proof_row(
        "docs",
        "full",
        "T",
        "H",
        "",
        "subset",
        true,
        Some("pass"),
        100,
    );
    row["proof"]["mode"] = json!("docs");
    row["proof"]["cmd"] = json!("text");
    for docs_only in [false, true] {
        row["proof"]["docs_only"] = json!(docs_only);
        w.plant(&[row.clone()], &[]);
        let proof = w.read_proof(
            &["--tree", "T", "--need", "submit"],
            &[("DEV_VALIDATE_SELECTION_CMD", "text")],
        );
        assert_eq!(
            proof["proof"],
            if docs_only { "complete" } else { "missing" }
        );
    }
}

#[test]
fn range_resolution_uses_the_declared_command_and_records_the_resolved_base() {
    for range in [None, Some("printf 'range=%s\n' \"$DEV_VALIDATE_BASE\"")] {
        let w = World::new();
        let base = w.head();
        w.commit("source.rs");
        let extra = range
            .map(|cmd| vec![("DEV_VALIDATE_RANGE_CMD", cmd)])
            .unwrap_or_default();
        let resolved = w.entry(
            &["--resolve-mode", "--worktree", w.worktree.to_str().unwrap()],
            &extra,
        );
        assert!(resolved.status.success(), "{}", stderr(&resolved));
        assert_eq!(
            text(&resolved),
            format!(
                "validate-mode={}",
                if range.is_some() { "range" } else { "full" }
            )
        );
        assert!(!w.worktree.join("tmp/validation-runs").exists());
        let out = w.local(&["--validate-mode", "range", "--base", &base], &extra);
        assert!(out.status.success(), "{}", stderr(&out));
        let dir = directory(&out);
        assert_eq!(
            field(&read_record(&w, &dir), "validate-mode"),
            if range.is_some() { "range" } else { "full" }
        );
        assert!(run_file(&dir, "start").contains(&format!("class-base={base}\n")));
        if range.is_some() {
            assert!(run_file(&dir, "log").contains(&format!("range={base}")));
        }
    }
}

#[test]
fn a_reproduction_runs_its_command_even_when_a_pass_or_selector_would_answer_it() {
    let w = World::new();
    w.commit("source.rs");
    let selector = "echo selection=all; echo expected-secs=99999";
    let out = w.local(
        &["--reproduce"],
        &[("DEV_VALIDATE_SELECTION_CMD", selector)],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    let dir = directory(&out);
    assert_eq!(field(&read_record(&w, &dir), "validate-mode"), "full");
    assert!(run_file(&dir, "log").contains("full"));
    assert!(!run_file(&dir, "start").contains("pass-run="));
    let out = w.local(
        &["--reproduce", "--validate-mode", "ci", "--base", "HEAD"],
        &[],
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains("reproduce-ci"));
}

#[test]
fn full_start_ignores_a_carried_base_and_refuses_unused_or_repeated_options() {
    let w = World::new();
    let out = w.local(
        &["--base", "absent-ref"],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(stderr(&out).contains("option-ignored option=--base validate-mode=full"));
    assert_eq!(
        field(&read_record(&w, &directory(&out)), "validate-mode"),
        "full"
    );
    let dir = directory(&out);
    let unused = w.entry(&["--record", "--run-dir", &dir, "--budget", "1"], &[]);
    assert_eq!(unused.status.code(), Some(2));
    assert!(
        stderr(&unused).contains("option-unused"),
        "{}",
        stderr(&unused)
    );
    let base = w.head();
    assert_eq!(
        refusal(&w.start(
            &["--mode", "full", "--base", &base, "--fresh", "--foreground"],
            &[("DEV_VALIDATE_RANGE_CMD", "echo range")]
        )),
        "mode-cause-missing"
    );
    let full = ok(&w.start(
        &[
            "--mode",
            "full",
            "--base",
            &base,
            "--cause",
            "whole-battery",
            "--fresh",
            "--foreground",
        ],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    ));
    assert_eq!(
        w.stage(full["run_dir"].as_str().unwrap())["proof"]["cause"],
        "whole-battery"
    );
    for args in [
        vec!["--wait", "--record", "--run-dir", "/absent"],
        vec!["--wait", "--run-dir", "/absent", "--fresh"],
        vec!["--worktree", "/absent", "--poll", "0"],
        vec!["--worktree", "/absent", "--poll", "1", "--poll", "2"],
        vec!["--worktree", "/absent", "--run-id", "bad"],
        vec![
            "--resolve-mode",
            "--worktree",
            "/absent",
            "--require-proof",
            "H",
        ],
    ] {
        assert_eq!(w.entry(&args, &[]).status.code(), Some(2), "{args:?}");
    }
}

fn until(mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + JOB_BOUND;
    while !predicate() {
        assert!(
            Instant::now() < deadline,
            "producer did not reach its barrier"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn executor_dir(w: &World, command: &str, timeout: u64) -> PathBuf {
    let dir = w.worktree.join("tmp/dev-validate-executor");
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join("start"),format!("worktree={}\nstart=1769700000\ntimeout-secs={timeout}\npoll-secs=1\ncap-secs={}\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead=H\ntree=T\n",w.worktree.display(),timeout+11)).unwrap();
    fs::write(
        dir.join("runner"),
        "runner=attached\nline=runner=attached\n",
    )
    .unwrap();
    fs::write(dir.join("cmd"), command).unwrap();
    fs::write(dir.join("paths"), "a.txt\n").unwrap();
    dir
}

#[test]
fn a_hung_command_ends_at_the_injected_deadline_without_a_passing_verdict() {
    use std::sync::{Arc, mpsc};
    let w = World::new();
    let fifo = w.root.join("held");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let ready = w.root.join("ready");
    let command = format!(
        "exec 9<> '{}'; echo ready > '{}'; read -r -t 5 -u 9 answer; exit 77",
        fifo.display(),
        ready.display()
    );
    let dir = executor_dir(&w, &command, 2);
    let clock = Arc::new(support::FakeClock::new());
    let c = clock.clone();
    let d = dir.clone();
    let (sent, received) = mpsc::channel();
    let task = std::thread::spawn(move || {
        let answer = orch_runtime::validate::run::execute(
            &d,
            c.as_ref(),
            &PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../github/scripts/lib/group-leader.sh"),
        );
        sent.send(answer).unwrap();
    });
    until(|| ready.exists());
    clock.await_sleepers(1);
    clock.release(Duration::from_secs(2));
    let deadline = Instant::now() + Duration::from_secs(15);
    let answer = loop {
        match received.try_recv() {
            Ok(answer) => break answer,
            Err(mpsc::TryRecvError::Disconnected) => panic!("executor ended without answer"),
            Err(mpsc::TryRecvError::Empty) => {
                assert!(
                    Instant::now() < deadline,
                    "executor exceeded parent deadline"
                );
                clock.release(Duration::from_millis(100));
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    };
    answer.unwrap();
    task.join().unwrap();
    let sentinel = fs::read_to_string(dir.join("exit")).unwrap();
    assert_eq!(field(&sentinel, "guard-exit"), "124");
    assert!(sentinel.contains("verdict=no-verdict"));
    assert!(!dir.join("own-exit").exists());
    let id: agent_runtime::process::Identity =
        serde_json::from_slice(&fs::read(dir.join("command")).unwrap()).unwrap();
    assert!(matches!(
        agent_runtime::process::still_runs(&id),
        agent_runtime::reading::Reading::Gone
    ));
    assert!(clock.elapsed() >= Duration::from_secs(2));
}

#[test]
fn an_exited_command_does_not_leave_its_background_group_running() {
    let w = World::new();
    let fifo = w.root.join("held");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let ready = w.root.join("member");
    let command = format!(
        "( exec 9<> '{}'; echo ready > '{}.ready'; read -r -t 20 -u 9 answer ) & member=$!; while [ ! -s '{}.ready' ]; do sleep 0.01; done; printf '%s\n' \"$member\" > '{}'; exit 0",
        fifo.display(),
        ready.display(),
        ready.display(),
        ready.display()
    );
    let out = w.local(&[], &[("DEV_VALIDATE_CMD", &command)]);
    assert!(out.status.success(), "{}", stderr(&out));
    let member: u32 = fs::read_to_string(&ready).unwrap().trim().parse().unwrap();
    let left_alive = support::live(member);
    if left_alive
        && let agent_runtime::reading::Reading::Live(identity) =
            agent_runtime::process::identity(member)
    {
        let _ = agent_runtime::process::stop_identities(&[identity], Duration::from_secs(1));
    }
    assert!(!left_alive, "the command left member {member}");
    assert_eq!(field(&read_record(&w, &directory(&out)), "verdict"), "pass");
}

#[test]
fn wait_budgets_and_launch_grace_use_the_injected_clock_and_do_not_start_work() {
    use std::sync::{Arc, mpsc};
    for (cap, budget, want) in [(100, 1, "running"), (100, 10, "lost"), (2, 10, "timeout")] {
        let w = World::new();
        let dir = executor_dir(&w, "touch must-not-run", 20);
        fs::remove_file(dir.join("runner")).unwrap();
        let mut start = fs::read_to_string(dir.join("start")).unwrap();
        start = start.replace("cap-secs=31", &format!("cap-secs={cap}"));
        fs::write(dir.join("start"), start).unwrap();
        let clock = Arc::new(support::FakeClock::new());
        let c = clock.clone();
        let d = dir.clone();
        let (sent, received) = mpsc::channel();
        let task = std::thread::spawn(move || {
            sent.send(orch_runtime::validate::files::wait(&d, budget, c.as_ref()))
                .unwrap()
        });
        clock.await_sleepers(1);
        clock.release(Duration::from_secs(budget.min(cap)));
        let (line, exit) = received.recv_timeout(JOB_BOUND).unwrap().unwrap();
        task.join().unwrap();
        assert_eq!(field(&line, "state"), want);
        assert_eq!(exit, if want == "running" { 3 } else { 1 });
        assert!(!w.worktree.join("must-not-run").exists());
    }
}

#[test]
fn wait_reads_a_finished_ci_receipt_as_pending_proof_and_a_completed_local_run_as_pass() {
    for mode in ["full", "ci"] {
        let w = World::new();
        let dir = executor_dir(&w, "true", 20);
        let start = fs::read_to_string(dir.join("start"))
            .unwrap()
            .replace("validate-mode=full", &format!("validate-mode={mode}"));
        fs::write(dir.join("start"), start).unwrap();
        fs::write(dir.join("exit"), "guard-exit=0 at=2026-01-01T00:00:00Z\n").unwrap();
        fs::write(
            dir.join("timing"),
            "started-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:00:00Z\nseconds=0\n",
        )
        .unwrap();
        let out = w.entry(&["--wait", "--run-dir", dir.to_str().unwrap()], &[]);
        assert!(out.status.success());
        assert_eq!(field(&text(&out), "validate"), "pass");
        assert_eq!(
            field(&read_record(&w, dir.to_str().unwrap()), "verdict"),
            if mode == "ci" { "pending" } else { "pass" }
        );
    }
}

fn manager(w: &World) -> (String, String) {
    (
        support::tool_path(&[&support::fixtures().join("validate-tools")]),
        w.root.join("manager").display().to_string(),
    )
}

#[test]
fn the_detached_producer_records_before_launch_and_the_real_executor_closes_and_notifies_once() {
    let w = World::new();
    let (path, manager) = manager(&w);
    let snapshot = w.root.join("at-launch.json");
    let out = w.start(
        &[],
        &[
            ("PATH", &path),
            ("VALIDATE_MANAGER_DIR", &manager),
            ("VALIDATE_AT_LAUNCH", snapshot.to_str().unwrap()),
        ],
    );
    let started = ok(&out);
    let dir = started["run_dir"].as_str().unwrap();
    let at: Value = serde_json::from_slice(&fs::read(snapshot).unwrap()).unwrap();
    let at = World::stage_in(&at, dir);
    assert_eq!(at["proof"]["cmd"], "echo full");
    assert_eq!(at["job"]["record"], format!("{dir}/runner"));
    assert!(at["job"]["runner"].is_null());
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    w.wait_marked(dir);
    let inbox = w
        .worktree
        .join("tmp/lane-mail")
        .join(ITEM_ID)
        .join("to-lane.jsonl");
    assert_eq!(fs::read_to_string(&inbox).unwrap().lines().count(), 1);
    let mut state = w.state();
    for stage in state["stages"].as_array_mut().unwrap() {
        if stage["run_dir"] == dir {
            stage["notice"]["owner"] = json!("owed");
        }
    }
    w.write_state(&state);
    ok(&w.op(
        &json!({"op":"reconcile-round","round_id":ROUND}),
        &[("PATH", &path), ("VALIDATE_MANAGER_DIR", &manager)],
    ));
    assert_eq!(fs::read_to_string(inbox).unwrap().lines().count(), 1);
    let absent = w.root.join("not-installed/lane-mail").display().to_string();
    let next = ok(&w.start(
        &["--fresh"],
        &[
            ("PATH", &path),
            ("VALIDATE_MANAGER_DIR", &manager),
            ("LANE_MAIL_CLI", &absent),
        ],
    ));
    let next_dir = next["run_dir"].as_str().unwrap();
    w.wait_closed(next_dir);
    assert!(
        w.wait_marked(next_dir)["notice"]["owner"]
            .as_str()
            .unwrap()
            .starts_with("unsent:")
    );
}

#[test]
fn a_lost_unit_start_answer_is_held_until_the_real_job_finishes_and_never_opens_a_second_job() {
    let w = World::new();
    let (path, manager) = manager(&w);
    let fifo = w.root.join("held");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let ready = w.root.join("ready");
    let command = format!(
        "exec 9<> '{}'; echo ready > '{}'; read -r -t 20 -u 9 answer",
        fifo.display(),
        ready.display()
    );
    let env = [
        ("PATH", path.as_str()),
        ("VALIDATE_MANAGER_DIR", manager.as_str()),
        ("VALIDATE_START_ANSWER", "lost"),
        ("DEV_VALIDATE_CMD", command.as_str()),
    ];
    let out = w.start(&[], &env);
    assert_eq!(refusal(&out), "launch-unanswered");
    until(|| ready.exists());
    let stages = w.state()["stages"].as_array().unwrap().clone();
    let stage = stages.iter().rfind(|s| s["kind"] == "validate").unwrap();
    let dir = stage["run_dir"].as_str().unwrap();
    assert!(stage["end"].is_null());
    assert_eq!(refusal(&w.start(&[], &env)), "run-live");
    assert_eq!(
        fs::read_to_string(Path::new(&manager).join("launches"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    fs::write(&fifo, "release\n").unwrap();
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    w.wait_marked(dir);
}

#[test]
fn an_unread_unit_start_remains_owed_and_a_confirmed_failed_unit_closes_stopped() {
    for (answer, key, open) in [
        ("unread", "launch-unanswered", true),
        ("refused", "launch-failed", false),
    ] {
        let w = World::new();
        let (path, manager) = manager(&w);
        let extra = [
            ("PATH", path.as_str()),
            ("VALIDATE_MANAGER_DIR", manager.as_str()),
            ("VALIDATE_START_ANSWER", answer),
        ];
        let out = w.start(&[], &extra);
        assert_eq!(refusal(&out), key);
        let state = w.state();
        let stage = state["stages"]
            .as_array()
            .unwrap()
            .iter()
            .rfind(|s| s["kind"] == "validate")
            .unwrap();
        assert_eq!(stage["end"].is_null(), open);
        if open {
            assert_eq!(refusal(&w.start(&[], &extra)), "run-live");
        } else {
            assert_eq!(stage["outcome"], "stopped");
        }
    }
}

#[test]
fn last_pass_reads_released_snapshots_and_later_red_or_unknown_order_invalidates_them() {
    for (ending, stamp, tree, want) in [
        ("guard-exit=0 at=2026-01-01T00:00:00Z", "2", "T2", "pass"),
        ("guard-exit=1 at=2026-01-01T00:00:00Z", "2", "T2", "red"),
        ("", "2", "T2", "red"),
        (
            "guard-exit=1 at=2026-01-01T00:00:00Z",
            "unknown",
            "T2",
            "red",
        ),
        (
            "guard-exit=0 at=2026-01-01T00:00:00Z",
            "unknown",
            "T2",
            "before",
        ),
        ("guard-exit=0 at=2026-01-01T00:00:00Z", "2", "", "before"),
        (
            "guard-exit=124 at=2026-01-01T00:00:00Z verdict=no-verdict",
            "2",
            "T2",
            "bound",
        ),
        (
            "guard-exit=124 at=2026-01-01T00:00:00Z verdict=no-verdict",
            "2",
            "T2",
            "red-noprefix",
        ),
        (
            "guard-exit=124 at=2026-01-01T00:00:00Z verdict=no-verdict",
            "unknown",
            "T2",
            "red-finding",
        ),
    ] {
        let w = World::new();
        for (name, stamp, tree, ending) in [
            ("before", "1", "T1", "guard-exit=0 at=2026-01-01T00:00:00Z"),
            ("after", stamp, tree, ending),
        ] {
            let dir = w.worktree.join(format!("tmp/dev-validate-{name}"));
            fs::create_dir(&dir).unwrap();
            fs::write(dir.join("start"),format!("validate-mode=full\nstart={stamp}\nhead=H\ntree={tree}\nfinding-prefix=FINDING:\n")).unwrap();
            fs::write(
                dir.join("log"),
                if name == "after" && want == "red-finding" {
                    "runner=none\nFINDING: code\n"
                } else {
                    "runner=none\n"
                },
            )
            .unwrap();
            if name == "after" && want == "red-noprefix" {
                let start = fs::read_to_string(dir.join("start")).unwrap();
                fs::write(
                    dir.join("start"),
                    start.replace("finding-prefix=FINDING:\n", ""),
                )
                .unwrap();
            }
            if !ending.is_empty() {
                fs::write(dir.join("exit"), ending).unwrap();
            }
        }
        let out = w.entry(
            &["--last-pass", "--worktree", w.worktree.to_str().unwrap()],
            &[],
        );
        let line = text(&out);
        if want.starts_with("red") {
            assert_eq!(out.status.code(), Some(1));
            assert_eq!(field(&line, "last-pass"), "red");
        } else {
            assert!(out.status.success(), "{line}");
            assert_eq!(
                field(&line, "tree"),
                if want == "before" { "T1" } else { "T2" }
            );
            assert_eq!(
                field(&line, "verdict"),
                if want == "bound" { "no-verdict" } else { "" }
            );
        }
    }
}

#[test]
fn a_declared_selection_over_the_bound_refuses_before_any_run_but_reuse_needs_no_new_budget() {
    let w = World::new();
    w.commit("source.rs");
    let out = w.local(
        &[],
        &[(
            "DEV_VALIDATE_SELECTION_CMD",
            "printf 'selection=all\nexpected-secs=21\n'",
        )],
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains("dev-validate-run: over-bound expected-secs=21 bound=20"));
    assert!(!w.worktree.join("tmp/validation-runs").exists());
    let first = w.local(&[], &[]);
    assert!(first.status.success());
    let first_dir = directory(&first);
    let out = w.local(
        &[],
        &[(
            "DEV_VALIDATE_SELECTION_CMD",
            "printf 'selection=all\nexpected-secs=21\n'",
        )],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    let dir = directory(&out);
    assert!(run_file(&dir, "start").contains(&format!("pass-run={first_dir}\n")));
    assert!(!Path::new(&dir).join("execution").exists());
    let out = w.local(
        &["--fresh"],
        &[(
            "DEV_VALIDATE_SELECTION_CMD",
            "printf 'selection=all\nexpected-secs=21\n'",
        )],
    );
    assert_eq!(out.status.code(), Some(2));
}

#[test]
fn reuse_of_the_real_pass_ends_after_a_later_failed_or_unfinished_attempt_on_that_tree() {
    for missing in ["cmd", "paths"] {
        let w = World::new();
        w.commit("source.rs");
        let first = w.local(&[], &[]);
        assert!(first.status.success(), "{}", stderr(&first));
        let dir = directory(&first);
        fs::remove_file(Path::new(&dir).join(missing)).unwrap();
        let next = w.local(&[], &[]);
        assert!(
            next.status.success(),
            "missing {missing}: {}",
            stderr(&next)
        );
        assert!(!run_file(&directory(&next), "start").contains("pass-run="));
        assert!(!run_file(&directory(&next), "start").contains("bound-run="));
    }
    let w = World::new();
    w.commit("source.rs");
    let first = w.local(&[], &[]);
    assert!(first.status.success());
    let old = directory(&first);
    let reused = w.local(&[], &[]);
    assert!(reused.status.success());
    assert!(run_file(&directory(&reused), "start").contains(&format!("pass-run={old}\n")));
    let attempted = w.worktree.join("tmp/dev-validate-red");
    fs::create_dir(&attempted).unwrap();
    let start = run_file(&old, "start");
    let now = start
        .lines()
        .find_map(|l| l.strip_prefix("start="))
        .unwrap()
        .parse::<u64>()
        .unwrap();
    fs::write(
        attempted.join("start"),
        start.replace(&format!("start={now}\n"), &format!("start={}\n", now + 1)),
    )
    .unwrap();
    fs::copy(Path::new(&old).join("paths"), attempted.join("paths")).unwrap();
    fs::copy(Path::new(&old).join("cmd"), attempted.join("cmd")).unwrap();
    let out = w.local(&[], &[]);
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(!run_file(&directory(&out), "start").contains("pass-run="));
}

#[test]
fn a_range_base_projects_once_per_rebase_hop_and_an_unmapped_rewrite_refuses() {
    let w = World::new();
    let base = w.head();
    let second = w.commit("source.rs");
    let third = w.commit("another.rs");
    let map = git(
        &w.worktree,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "kendex-rebase-map",
        ],
    );
    fs::write(
        &map,
        format!("rebase-hop:\nrebase-map: {base} {second}\nrebase-map: {second} {third}\n"),
    )
    .unwrap();
    let out = w.local(
        &["--validate-mode", "range", "--base", &base],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(run_file(&directory(&out), "start").contains(&format!("validate-base={second}\n")));
    fs::write(
        &map,
        format!(
            "rebase-hop:\nrebase-map: {base} {second}\nrebase-hop:\nrebase-map: {second} {third}\n"
        ),
    )
    .unwrap();
    let out = w.local(
        &["--validate-mode", "range", "--base", &base, "--fresh"],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(run_file(&directory(&out), "start").contains(&format!("validate-base={third}\n")));
    fs::write(&map, format!("rebase-unmapped: {third}\n")).unwrap();
    let out = w.local(
        &["--validate-mode", "range", "--base", &base],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains("rebase-map-unreadable"));
}

#[test]
fn the_catalog_shim_consumes_the_real_admission_and_waits_for_its_runtime_run() {
    let w = World::new();
    let base = w.head();
    w.commit("src.rs");
    let admitted = ok(&w.op(
        &json!({"op":"record-validation-admission","round_id":ROUND}),
        &[],
    ));
    let id = admitted["report"]["run_id"].as_str().unwrap();
    let dir = admitted["report"]["run_dir"].as_str().unwrap();
    let scripts = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts");
    let key_lib = scripts.join("../../agent-runtime/scripts/lib/key.sh");
    let key = program("/bin/bash")
        .arg("-c")
        .arg(format!(
            ". '{}' && agent_runtime_key '{}'",
            key_lib.display(),
            env!("CARGO_MANIFEST_DIR")
        ))
        .output()
        .unwrap();
    assert!(key.status.success(), "{}", stderr(&key));
    let key = text(&key);
    let cache = w.root.join("cache");
    fs::create_dir_all(cache.join("bin")).unwrap();
    std::os::unix::fs::symlink(
        support::binary(),
        cache.join("bin").join(format!("orch-runtime-{key}")),
    )
    .unwrap();
    let mut command = program(scripts.join("dev-validate-run"));
    command.args([
        "--worktree",
        w.worktree.to_str().unwrap(),
        "--run-id",
        id,
        "--base",
        &base,
        "--poll",
        "1",
    ]);
    for (k, v) in w.env() {
        if k != "DEV_VALIDATE_CLI" && k != "CHANGE_SCOPE_PATHS_CLI" {
            command.env(k, v);
        }
    }
    command
        .env("DEV_VALIDATE_RANGE_CMD", "echo range")
        .env("AGENT_RUNTIME_CACHE", &cache)
        .current_dir(&w.worktree);
    let out = command.output().unwrap();
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    assert_eq!(directory(&out), dir);
    assert!(!text(&out).contains("class-fallback="), "{}", text(&out));
    assert_eq!(field(&read_record(&w, dir), "validate-mode"), "range");
    assert_eq!(
        field(text(&out).lines().last().unwrap(), "validate"),
        "pass"
    );
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    w.wait_marked(dir);
    let out = w.entry(
        &[
            "--worktree",
            w.worktree.to_str().unwrap(),
            "--run-id",
            "20300101T000000Z-unadmitted",
        ],
        &[],
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains("run-unadmitted"));
    let mut detached = program(scripts.join("dev-validate-run"));
    detached.args(["--worktree", w.worktree.to_str().unwrap(), "--poll", "1"]);
    for (key, value) in w.env() {
        detached.env(key, value);
    }
    let out = detached
        .env("AGENT_RUNTIME_CACHE", &cache)
        .current_dir(&w.root)
        .output()
        .unwrap();
    let adir = directory(&out);
    assert!(
        out.status.success(),
        "{} {} child={}",
        text(&out),
        stderr(&out),
        run_file(&adir, "job.err")
    );
}

#[test]
fn a_foreground_stop_records_intent_before_signalling_and_closes_the_stage_stopped() {
    let w = World::new();
    let fifo = w.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let ready = w.root.join("ready");
    let at_signal = w.root.join("at-signal.json");
    let command = format!(
        "trap \"cp '{}' '{}' ; exit 0\" TERM; exec 9<> '{}'; echo ready > '{}'; read -r -t 20 -u 9 answer",
        w.item.display(),
        at_signal.display(),
        fifo.display(),
        ready.display()
    );
    let mut child = support::isolated();
    child.args([
        "--state-dir",
        w.state.to_str().unwrap(),
        "validate",
        "start",
        "--item",
        ITEM_ID,
        "--round",
        ROUND,
        "--foreground",
    ]);
    for (k, v) in w.env() {
        child.env(k, v);
    }
    child
        .env("DEV_VALIDATE_CMD", command)
        .current_dir(&w.worktree)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let mut child = support::Owned(child.spawn().unwrap());
    until(|| ready.exists());
    let state = w.state();
    let dir = state["stages"]
        .as_array()
        .unwrap()
        .iter()
        .rfind(|s| s["kind"] == "validate")
        .unwrap()["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    let out = w.run(&["validate", "stop", "--run-dir", &dir], &[]);
    let stopped = ok(&out);
    assert_eq!(stopped["recorded_now"], true);
    assert_eq!(w.wait_closed(&dir)["outcome"], "stopped");
    let snapshot: Value = serde_json::from_slice(&fs::read(at_signal).unwrap()).unwrap();
    assert!(World::stage_in(&snapshot, &dir)["stop"].is_object());
    child.0.wait().unwrap();
    assert_eq!(w.stage(&dir)["outcome"], "stopped");
    assert_eq!(field(&read_record(&w, &dir), "verdict"), "no-verdict");
    assert!(Path::new(&dir).join("stop").exists());
    fs::write(Path::new(&dir).join("exit"), "unreadable\n").unwrap();
    assert_eq!(
        w.entry(&["--record", "--run-dir", &dir], &[]).status.code(),
        Some(2)
    );
}

#[test]
fn require_proof_binds_both_the_expected_commit_and_its_snapshot() {
    let w = World::new();
    w.commit("source.rs");
    let out = w.local(&[], &[]);
    assert!(out.status.success());
    let head = w.head();
    let args = [
        "--resolve-mode",
        "--worktree",
        w.worktree.to_str().unwrap(),
        "--require-proof",
        head.as_str(),
        "--expected-head",
        head.as_str(),
    ];
    let out = w.entry(&args, &[]);
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    assert_eq!(field(&text(&out), "validation-proof"), "local-pass");
    fs::write(w.worktree.join("source.rs"), "changed\n").unwrap();
    let out = w.entry(&args, &[]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(field(&text(&out), "cause"), "tree-mismatch");
    let out = w.entry(
        &[
            "--resolve-mode",
            "--worktree",
            w.worktree.to_str().unwrap(),
            "--require-proof",
            &head,
            "--expected-head",
            "other",
        ],
        &[],
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(field(&text(&out), "cause"), "head-mismatch");
}

#[test]
fn the_real_systemd_client_refuses_invalid_environment_and_an_absent_private_bus_before_launch() {
    let w = World::new();
    let executable = Path::new("/usr/bin/systemd-run");
    if !executable.is_file() {
        return;
    }
    for invalid in [false, true] {
        let mut command = program(executable);
        command.env("XDG_RUNTIME_DIR", &w.root).env(
            "DBUS_SESSION_BUS_ADDRESS",
            format!("unix:path={}/absent-bus", w.root.display()),
        );
        command.args([
            "--user",
            "--quiet",
            "--collect",
            "--unit=orch-private-validation-contract",
        ]);
        if invalid {
            command.arg("--setenv=BASH_FUNC_bad%%=x");
        }
        let out = command.args(["--", "/bin/true"]).output().unwrap();
        assert_eq!(out.status.code(), Some(1));
        let error = stderr(&out);
        assert!(
            error.contains(if invalid {
                "Cannot assign environment variable "
            } else {
                "Failed to connect to "
            }),
            "{error}"
        );
    }
}

fn ci_world(w: &World, case: &str) -> (String, String, String) {
    fs::write(
        w.worktree.join("source.rs"),
        (0..100)
            .map(|n| format!("pub fn item_{n}() {{ println!(\"{n}\"); }}\n"))
            .collect::<String>(),
    )
    .unwrap();
    git(&w.worktree, &["add", "source.rs"]);
    git(&w.worktree, &["commit", "-q", "-m", "code"]);

    let mut rules = json!([{ "type":"merge_queue" }, { "type":"required_status_checks", "parameters":{"required_status_checks":[{"context":"CI"}]} }]);
    let mut protection =
        json!({"protection":{"required_status_checks":{"contexts":[],"checks":[]}}});
    let mut view = json!({"state":"OPEN","baseRefName":"main"});
    if case == "context-unrequired" {
        rules = json!([]);
    }
    if case == "protection-unread" {
        protection = json!({});
    }
    if case == "pr-not-open" {
        view["state"] = json!("MERGED");
    }
    if case == "base-unresolved" {
        view = json!({"state":"UNKNOWN"});
    }
    let mut replies = json!({"pr view --json":{"body":view},"repos/{owner}/{repo}/rules/branches/main":{"body":rules},"repos/{owner}/{repo}/branches/main":{"body":protection}});
    if case == "rules-unread" {
        replies["repos/{owner}/{repo}/rules/branches/main"]["exit"] = json!(1);
    }
    let file = w.root.join("gh.json");
    fs::write(&file, replies.to_string()).unwrap();
    (
        support::tool_path(&[&support::fixtures().join("validate-gh")]),
        file.display().to_string(),
        w.root.join("gh.log").display().to_string(),
    )
}

#[test]
fn ci_admission_reads_the_real_pr_reader_and_both_rule_sources_before_skipping_local_work() {
    for (case, want_mode, cause) in [
        ("required", "ci", ""),
        ("rules-unread", "range", "rules-unread"),
        ("protection-unread", "range", "rules-unread"),
        ("context-unrequired", "range", "context-unrequired"),
        ("pr-not-open", "range", "pr-not-open"),
        ("base-unresolved", "range", "base-unresolved"),
        ("push-base", "range", "push-base"),
        ("setting-empty", "range", "setting-empty"),
    ] {
        let w = World::new();
        let base = w.head();
        w.commit("source.rs");
        let (path, replies, log) = ci_world(&w, case);
        let extra = [
            ("PATH", path.as_str()),
            ("GH_FAKE_REPLIES", replies.as_str()),
            ("GH_FAKE_LOG", log.as_str()),
            ("GH_REPO", "o/r"),
            (
                "ORCH_DELIVERY",
                if case == "push-base" {
                    "push-base"
                } else {
                    "pr"
                },
            ),
            (
                "DEV_VALIDATE_CI_CONTEXT",
                if case == "setting-empty" { "" } else { "CI" },
            ),
            ("DEV_VALIDATE_RANGE_CMD", "echo local-range"),
        ];
        let out = w.local(&["--validate-mode", "ci", "--base", &base], &extra);
        assert!(
            out.status.success(),
            "case={case} {} {}",
            text(&out),
            stderr(&out)
        );
        let dir = directory(&out);
        let record = read_record(&w, &dir);
        assert_eq!(
            field(&record, "validate-mode"),
            want_mode,
            "{case}: {record}"
        );
        assert_eq!(field(&record, "ci-fallback"), cause, "{case}");
        assert_eq!(
            field(&record, "verdict"),
            if want_mode == "ci" { "pending" } else { "pass" }
        );
        assert_eq!(
            Path::new(&dir).join("execution").exists(),
            want_mode != "ci"
        );
    }
}

#[test]
fn under_push_first_a_named_range_start_asks_the_ci_admission_and_review_first_runs_it_locally() {
    for (order, want) in [("push-first", "ci"), ("review-first", "range")] {
        let w = World::new();
        let base = w.head();
        w.commit("source.rs");
        let (path, replies, log) = ci_world(&w, "required");
        let extra = [
            ("PATH", path.as_str()),
            ("GH_FAKE_REPLIES", replies.as_str()),
            ("GH_FAKE_LOG", log.as_str()),
            ("GH_REPO", "o/r"),
            ("ORCH_DELIVERY", "pr"),
            ("ORCH_PR_ORDER", order),
            ("DEV_VALIDATE_CI_CONTEXT", "CI"),
            ("DEV_VALIDATE_RANGE_CMD", "echo local-range"),
        ];
        let out = w.local(&["--validate-mode", "range", "--base", &base], &extra);
        assert!(out.status.success(), "{order}: {}", stderr(&out));
        let dir = directory(&out);
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "validate-mode"), want, "{order}: {record}");
        assert_eq!(Path::new(&dir).join("execution").exists(), want != "ci");
    }
}

#[test]
fn an_admitted_ci_round_executes_scoped_suites_but_a_restack_skips_the_selector() {
    for restack in [false, true] {
        let w = World::new();
        let base = w.head();
        w.commit("source.rs");
        let (path, replies, log) = ci_world(&w, "required");
        let selector = "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then echo scoped-ran; echo 'validate: lanes=unit selection=subset'; else echo selection=subset; fi";
        let extra = [
            ("PATH", path.as_str()),
            ("GH_FAKE_REPLIES", replies.as_str()),
            ("GH_FAKE_LOG", log.as_str()),
            ("GH_REPO", "o/r"),
            ("ORCH_DELIVERY", "pr"),
            ("DEV_VALIDATE_CI_CONTEXT", "CI"),
            ("DEV_VALIDATE_RANGE_CMD", "echo range"),
            ("DEV_VALIDATE_SELECTION_CMD", selector),
        ];
        let mut args = vec!["--validate-mode", "ci", "--base", base.as_str()];
        if restack {
            args.push("--restack");
        }
        let out = w.local(&args, &extra);
        assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
        let dir = directory(&out);
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "validate-mode"), "ci");
        assert_eq!(field(&record, "verdict"), "pending");
        assert_eq!(run_file(&dir, "log").contains("scoped-ran"), !restack);
        assert_eq!(field(&record, "scoped"), if restack { "" } else { "true" });
    }
}

#[test]
fn ambiguous_selector_answers_do_not_admit_ci_or_invent_an_over_bound_estimate() {
    for selector in [
        "printf 'selection=all\nselection=subset\nexpected-secs=21\nexpected-secs=22\n'",
        "printf 'selection=unknown\n'",
        "exit 1",
    ] {
        let w = World::new();
        let base = w.head();
        w.commit("source.rs");
        let (path, replies, log) = ci_world(&w, "required");
        let extra = [
            ("PATH", path.as_str()),
            ("GH_FAKE_REPLIES", replies.as_str()),
            ("GH_FAKE_LOG", log.as_str()),
            ("GH_REPO", "o/r"),
            ("ORCH_DELIVERY", "pr"),
            ("DEV_VALIDATE_CI_CONTEXT", "CI"),
            ("DEV_VALIDATE_RANGE_CMD", "echo range"),
            ("DEV_VALIDATE_SELECTION_CMD", selector),
        ];
        let out = w.local(&["--validate-mode", "ci", "--base", &base], &extra);
        assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
        let dir = directory(&out);
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "validate-mode"), "range");
        assert_eq!(field(&record, "ci-fallback"), "selection-unread");
        assert!(run_file(&dir, "log").contains("range"));
    }
}

#[test]
fn reconcile_round_reads_a_started_run_by_its_job_identity_never_the_bare_pid() {
    let w = World::new();
    let live = Owned::sleep();
    let mut doc = w.state();
    let dir = |n: &str| {
        w.worktree
            .join("tmp")
            .join(format!("dev-validate-{n}"))
            .display()
            .to_string()
    };
    for n in [
        "live",
        "reused",
        "unit-gone",
        "unit-live",
        "unanswered",
        "unanswered-failed",
    ] {
        fs::create_dir_all(dir(n)).unwrap();
        fs::write(Path::new(&dir(n)).join("start"), "start=1\nhead=abc\n").unwrap();
    }
    fs::write(
        Path::new(&dir("unanswered")).join("runner"),
        format!(
            "runner=setsid\npid={}\nstart={}\nline=runner=setsid\n",
            live.pid(),
            live.start()
        ),
    )
    .unwrap();
    fs::write(
        Path::new(&dir("unanswered-failed")).join("runner"),
        "runner=setsid\nstatus=exited-1\nline=runner=setsid\n",
    )
    .unwrap();
    let stage = |n: &str, job: Value| json!({"kind": "validate", "round_id": ROUND, "start": 1769600001, "end": null, "run_dir": dir(n), "job": job});
    let record = |n: &str| format!("{}/runner", dir(n));
    let stages = doc["stages"].as_array_mut().unwrap();
    stages.push(stage("live", json!({"record": record("live"), "runner": "setsid", "pid": live.pid(), "start": live.start()})));
    stages.push(stage("reused", json!({"record": record("reused"), "runner": "setsid", "pid": live.pid(), "start": "ticks:1"})));
    stages.push(stage(
        "unit-gone",
        json!({"record": record("unit-gone"), "runner": "systemd", "unit": "orch-validate-wt-1"}),
    ));
    stages.push(stage(
        "unit-live",
        json!({"record": record("unit-live"), "runner": "systemd", "unit": "orch-validate-wt-2"}),
    ));
    stages.push(stage("unanswered", json!({"record": record("unanswered")})));
    stages.push(stage(
        "unanswered-failed",
        json!({"record": record("unanswered-failed")}),
    ));
    w.write_state(&doc);
    let systemctl = fixtures().join("systemctl-unit");
    let path = tool_path(&[&systemctl]);
    let out = w.op(
        &json!({"op": "reconcile-round", "round_id": ROUND}),
        &[("PATH", &path), ("SYSTEMCTL_LOAD", "not-found")],
    );
    let runs = ok(&out)["report"]["runs"].clone();
    let state_of = |n: &str| {
        runs.as_array()
            .unwrap()
            .iter()
            .find(|r| r["run_dir"] == dir(n))
            .cloned()
            .unwrap_or_else(|| panic!("no row for {n}: {runs}"))
    };
    assert_eq!(state_of("live")["state"], "live");
    assert_eq!(state_of("live")["pid"], live.pid());
    assert_eq!(state_of("reused")["state"], "closed");
    assert_eq!(state_of("reused")["outcome"], "lost");
    assert_eq!(state_of("reused")["cause"], "process-gone");
    assert_eq!(state_of("unit-gone")["outcome"], "lost");
    assert_eq!(state_of("unit-gone")["cause"], "unit-ended");
    assert_eq!(state_of("unit-live")["outcome"], "lost");
    assert_eq!(state_of("unanswered")["state"], "live");
    assert_eq!(state_of("unanswered-failed")["outcome"], "stopped");
    assert_eq!(state_of("unanswered-failed")["cause"], "launch-failed");
    assert!(w.stage(&dir("live"))["end"].is_null());
    assert!(!w.stage(&dir("reused"))["end"].is_null());

    let mut doc = w.state();
    doc["stages"].as_array_mut().unwrap().push(stage(
        "unit-live-2",
        json!({"record": record("unit-live-2"), "runner": "systemd", "unit": "orch-validate-wt-3"}),
    ));
    fs::create_dir_all(dir("unit-live-2")).unwrap();
    w.write_state(&doc);
    let out = w.op(
        &json!({"op": "reconcile-round", "round_id": ROUND}),
        &[
            ("PATH", &path),
            ("SYSTEMCTL_LOAD", "loaded"),
            ("SYSTEMCTL_ACTIVE", "active"),
        ],
    );
    let runs = ok(&out)["report"]["runs"].clone();
    let row = runs
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["run_dir"] == dir("unit-live-2"))
        .unwrap();
    assert_eq!(row["state"], "live-unit");
    assert_eq!(row["unit"], "orch-validate-wt-3");
    assert!(w.stage(&dir("unit-live-2"))["end"].is_null());
}

#[test]
fn a_reconcile_holds_a_run_whose_manager_does_not_answer() {
    let w = World::new();
    let mut doc = w.state();
    let dir = w
        .worktree
        .join("tmp/dev-validate-held")
        .display()
        .to_string();
    fs::create_dir_all(&dir).unwrap();
    fs::write(Path::new(&dir).join("start"), "start=1\n").unwrap();
    let record = format!("{dir}/runner");
    doc["stages"].as_array_mut().unwrap().push(json!({
        "kind": "validate", "round_id": ROUND, "start": 1769600001, "end": null, "run_dir": dir,
        "job": {"record": record, "runner": "systemd", "unit": "orch-validate-wt-held"}
    }));
    w.write_state(&doc);
    let systemctl = fixtures().join("systemctl-unit");
    let path = tool_path(&[&systemctl]);
    let out = w.op(
        &json!({"op": "reconcile-round", "round_id": ROUND}),
        &[("PATH", &path), ("SYSTEMCTL_RC", "1")],
    );
    let runs = ok(&out)["report"]["runs"].clone();
    let row = runs
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["run_dir"] == dir)
        .unwrap_or_else(|| panic!("no row for the held run: {runs}"));
    assert_eq!(row["state"], "unreadable");
    assert!(
        row["cause"]
            .as_str()
            .unwrap()
            .contains("orch-validate-wt-held"),
        "{row}"
    );
    assert!(w.stage(&dir)["end"].is_null(), "the stage stays open");
}

#[test]
fn a_reconcile_closes_a_gone_runtime_run_and_owes_its_end_notice() {
    let w = World::new();
    let gone = Owned::sleep();
    let mut doc = w.state();
    let dir = w
        .worktree
        .join("tmp/dev-validate-crash")
        .display()
        .to_string();
    fs::create_dir_all(&dir).unwrap();
    fs::write(Path::new(&dir).join("exit"), "guard-exit=0 at=1769600002\n").unwrap();
    fs::write(Path::new(&dir).join("timing"), "seconds=3\n").unwrap();
    fs::write(Path::new(&dir).join("start"), "start=1\n").unwrap();
    let record = format!("{dir}/runner");
    doc["stages"].as_array_mut().unwrap().push(json!({
        "kind": "validate", "round_id": ROUND, "start": 1769600001, "end": null, "run_dir": dir,
        "job": {"record": record, "runner": "setsid", "pid": gone.pid(), "start": "ticks:1"}
    }));
    w.write_state(&doc);
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    let stage = w.stage(&dir);
    assert_eq!(stage["outcome"], "pass");
    assert_eq!(stage["notice"]["to"], ITEM_ID);
    let run_id = Path::new(&dir)
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .strip_prefix("dev-validate-")
        .unwrap()
        .to_owned();
    assert_eq!(
        stage["notice"]["text"],
        format!("validation-end run={run_id} state=pass run-dir={dir} log={dir}/log")
    );
    assert_eq!(stage["notice"]["owner"], "sent", "the owed walk sent it");
    let inbox = w
        .worktree
        .join("tmp/lane-mail")
        .join(ITEM_ID)
        .join("to-lane.jsonl");
    assert!(
        fs::read_to_string(inbox)
            .unwrap()
            .contains("validation-end run=")
    );
}

#[test]
fn a_stale_group_start_never_signals_the_process_that_reused_its_number() {
    use std::os::unix::process::CommandExt;
    let w = World::new();
    let fifo = w.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let mut child = program("/bin/bash");
    child
        .args([
            "-c",
            &format!("exec 9<> '{}'; read -r -t 20 -u 9 answer", fifo.display()),
        ])
        .process_group(0);
    let mut child = Owned(child.spawn().unwrap());
    let pid = child.0.id();
    until(|| support::live(pid));
    let dir = executor_dir(&w, "true", 20);
    fs::write(
        dir.join("runner"),
        format!("runner=setsid\npid={pid}\nstart=stale-start\nline=runner=setsid\n"),
    )
    .unwrap();
    let out = w.entry(&["--stop", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(field(&text(&out), "groups"), "0");
    assert!(support::live(pid));
    child.0.kill().unwrap();
    child.0.wait().unwrap();
}

#[test]
fn a_command_group_still_holds_the_host_after_its_executor_dies() {
    let w = World::new();
    let fifo = w.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let ready = w.root.join("ready");
    let command = format!(
        "exec 9<> '{}'; echo ready > '{}'; read -r -t 20 -u 9 answer",
        fifo.display(),
        ready.display()
    );
    let started = ok(&w.start(&[], &[("DEV_VALIDATE_CMD", &command)]));
    let dir = started["run_dir"].as_str().unwrap();
    until(|| ready.exists());
    let job = &w.stage(dir)["job"];
    let identity = agent_runtime::process::Identity {
        pid: job["pid"].as_u64().unwrap() as u32,
        start: job["start"].as_str().unwrap().into(),
    };
    assert!(matches!(
        agent_runtime::process::stop_identities(&[identity], Duration::from_secs(1)).unwrap(),
        agent_runtime::process::Stop::Stopped { .. } | agent_runtime::process::Stop::AlreadyGone
    ));
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    assert!(!w.stage(dir)["end"].is_null());
    assert_eq!(refusal(&w.start(&["--fresh"], &[])), "run-live");
    let stopped = w.entry(&["--stop", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert!(stopped.status.success(), "{}", stderr(&stopped));
    assert!(
        orch_runtime::validate::files::live(&w.worktree)
            .unwrap()
            .is_none()
    );
}

#[test]
fn snapshot_classification_preserves_the_index_timestamp_and_writes_no_shared_object() {
    let w = World::new();
    let file = w.worktree.join("racy.rs");
    let old_time = std::time::UNIX_EPOCH + Duration::from_secs(1000);
    git(&w.worktree, &["config", "core.trustctime", "false"]);
    git(&w.worktree, &["config", "core.checkStat", "minimal"]);
    fs::write(&file, "aaaa\n").unwrap();
    fs::File::open(&file)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(old_time))
        .unwrap();
    git(&w.worktree, &["add", "racy.rs"]);
    let index = PathBuf::from(git(
        &w.worktree,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
    ));
    fs::File::open(&index)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(old_time))
        .unwrap();
    fs::write(&file, "bbbb\n").unwrap();
    fs::File::open(&file)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(old_time))
        .unwrap();
    let before = fs::read(&index).unwrap();
    let head = w.head();
    let objects = git(&w.worktree, &["count-objects", "-v"]);
    let out = w.local(&[], &[]);
    assert!(out.status.success(), "{}", stderr(&out));
    let dir = directory(&out);
    assert_eq!(fs::read(&index).unwrap(), before);
    assert_eq!(w.head(), head);
    assert_eq!(git(&w.worktree, &["count-objects", "-v"]), objects);
    git(&w.worktree, &["add", "racy.rs"]);
    let expected = git(&w.worktree, &["write-tree"]);
    assert_eq!(field(&read_record(&w, &dir), "tree"), expected);
}

#[test]
fn released_bound_records_reuse_only_the_same_command_context_with_covered_paths_and_no_finding() {
    use orch_runtime::ops::{
        proof::Declaration,
        validate::{Reuse, Want, reuse},
    };
    let cases = [
        "bound",
        "host",
        "finding",
        "missing-prefix",
        "different-prefix",
        "different-command",
        "different-class",
        "different-docs",
        "different-base",
        "shorter-bound",
        "wider-paths",
        "ci",
        "reused",
    ];
    for case in cases {
        let w = World::new();
        let dir = executor_dir(&w, "echo full", 20);
        let dir_text = dir.display().to_string();
        let at = agent_runtime::clock::iso_utc(1769700020);
        fs::write(
            dir.join("exit"),
            format!(
                "guard-exit={} at={at} verdict=no-verdict{}\n",
                if case == "host" { 3 } else { 124 },
                if case == "host" { " cause=host" } else { "" }
            ),
        )
        .unwrap();
        fs::write(
            dir.join("log"),
            if case == "finding" {
                "runner=none\nFINDING: code\n"
            } else {
                "runner=none\n"
            },
        )
        .unwrap();
        fs::write(dir.join("paths"), "a.rs\n").unwrap();
        let mut start = fs::read_to_string(dir.join("start")).unwrap();
        start.push_str("finding-prefix=FINDING:\n");
        fs::write(dir.join("start"), start).unwrap();
        let mut stage = orch_runtime::validate::files::RunFile::read(&dir)
            .unwrap()
            .stage()
            .unwrap();
        let p = stage.proof.as_mut().unwrap();
        match case {
            "missing-prefix" => p.finding_prefix.clear(),
            "different-prefix" => p.finding_prefix = "OTHER:".into(),
            "different-command" => p.cmd = "other".into(),
            "different-class" => p.class = "small".into(),
            "different-docs" => p.docs_only = true,
            "different-base" => p.base = "other".into(),
            "shorter-bound" => p.timeout_secs = 19,
            "wider-paths" => fs::write(dir.join("paths"), "a.rs\nb.rs\n").unwrap(),
            "ci" => p.mode = orch_runtime::state::ValidateMode::Ci,
            "reused" => {
                p.reused = Some(orch_runtime::state::Reused::BoundRun {
                    run_dir: "prior".into(),
                })
            }
            _ => {}
        }
        let want = Want {
            cmd: "echo full".into(),
            class: "standard".into(),
            docs_only: false,
            base: String::new(),
            finding_prefix: "FINDING:".into(),
            tree: "new-tree".into(),
            paths: vec!["a.rs".into()],
            timeout_secs: 20,
        };
        let declaration = Declaration {
            cmd: "echo full".into(),
            range_cmd: None,
            docs_cmd: None,
            ci_declared: false,
            finding_prefix: "FINDING:".into(),
        };
        let answer = reuse(&[stage], &want, &declaration);
        assert_eq!(
            answer,
            if case == "bound" {
                Reuse::Bound {
                    run_dir: dir_text,
                    exit: 124,
                }
            } else {
                Reuse::None
            },
            "{case}"
        );
    }
}

#[test]
fn a_malformed_last_selection_cannot_turn_a_round_only_run_into_a_whole_tree_pass() {
    let w = World::new();
    let base = w.head();
    w.commit("source.rs");
    let cmd =
        "printf 'validate: lanes=unit selection=battery\nvalidate: lanes=bad, selection=battery\n'";
    let result = ok(&w.start(
        &["--base", &base, "--foreground"],
        &[("DEV_VALIDATE_CMD", cmd)],
    ));
    let dir = result["run_dir"].as_str().unwrap();
    let stage = w.stage(dir);
    assert_eq!(stage["proof"]["selection"], "unreported");
    assert_eq!(field(&read_record(&w, dir), "selection"), "unreported");
    let proof = w.read_proof(
        &[
            "--tree",
            stage["proof"]["tree"].as_str().unwrap(),
            "--need",
            "submit",
        ],
        &[("DEV_VALIDATE_CMD", cmd)],
    );
    assert_eq!(proof["proof"], "missing");
}

#[test]
fn a_spawn_refusal_records_never_started_and_a_missing_answer_keeps_the_real_attempt_owed() {
    let w = World::new();
    let out = w.local(&[], &[]);
    assert!(out.status.success());
    let completed = directory(&out);
    let unknown = w.worktree.join("tmp/dev-validate-unknown");
    fs::create_dir(&unknown).unwrap();
    fs::copy(Path::new(&completed).join("start"), unknown.join("start")).unwrap();
    fs::copy(
        Path::new(&completed).join("execution"),
        unknown.join("execution"),
    )
    .unwrap();
    let live = w.entry(&["--live", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert!(live.status.success());
    assert_eq!(
        field(&text(&live), "run-dir"),
        unknown.display().to_string()
    );
    let out = w.local(&[], &[]);
    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains("run-live"));
    let stopped = w.entry(&["--stop", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert_eq!(stopped.status.code(), Some(1));
    assert!(stderr(&stopped).contains("execution-unanswered"));
    let refused = executor_dir(&w, "true", 20);
    let mut start = fs::read_to_string(refused.join("start")).unwrap();
    start = start.replace(
        &format!("worktree={}\n", w.worktree.display()),
        &format!("worktree={}\n", w.root.join("absent").display()),
    );
    fs::write(refused.join("start"), start).unwrap();
    let prefix =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../github/scripts/lib/group-leader.sh");
    let error = orch_runtime::validate::run::execute(
        &refused,
        &orch_runtime::schedule::SystemClock,
        &prefix,
    )
    .unwrap_err();
    assert!(matches!(
        error,
        orch_runtime::Error::ValidateUnreadable {
            read: "command-not-started",
            ..
        }
    ));
    fs::copy(Path::new(&completed).join("runner"), refused.join("runner")).unwrap();
    fs::copy(refused.join("execution"), unknown.join("execution")).unwrap();
    let live = w.entry(&["--live", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert_eq!(live.status.code(), Some(1));
    assert_eq!(text(&live), "live=none");
}

#[test]
fn a_classifier_refusal_keeps_the_local_command_and_explicit_fallback() {
    let w = World::new();
    git(
        &w.worktree,
        &["update-ref", "-d", "refs/remotes/origin/main"],
    );
    let missing = w.root.join("absent/classifier").display().to_string();
    let out = w.local(
        &[],
        &[
            ("DEV_VALIDATE_CMD", "echo fallback-command"),
            ("CHANGE_SCOPE_PATHS_CLI", &missing),
        ],
    );
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    let dir = directory(&out);
    let start = run_file(&dir, "start");
    assert!(start.contains("class=standard\n"), "{start}");
    assert!(start.contains("docs-only=false\n"), "{start}");
    assert!(text(&out).contains("class-fallback="), "{}", text(&out));
    assert!(run_file(&dir, "log").contains("fallback-command"));
}

#[test]
fn an_orphaned_range_base_records_the_original_and_uses_the_branch_merge_base() {
    let w = World::new();
    let base = w.head();
    w.commit("range.rs");
    let tree = git(&w.worktree, &["rev-parse", "HEAD^{tree}"]);
    let out = program("git")
        .arg("-C")
        .arg(&w.worktree)
        .args(["commit-tree", &tree, "-m", "separate-root"])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let orphan = text(&out);
    let out = w.local(
        &["--validate-mode", "range", "--base", &orphan],
        &[("DEV_VALIDATE_RANGE_CMD", "echo orphan-range")],
    );
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    let dir = directory(&out);
    let fields = orch_runtime::validate::files::fields(&Path::new(&dir).join("start")).unwrap();
    assert_eq!(fields["validate-base-orphaned"], orphan);
    assert_eq!(fields["validate-base"], base);
    assert!(run_file(&dir, "log").contains("orphan-range"));
    assert_eq!(
        field(&read_record(&w, &dir), "validate-base-orphaned"),
        orphan
    );
}

#[test]
fn an_unwritable_output_stream_cannot_report_a_successful_start() {
    use std::fs::OpenOptions;
    let w = World::new();
    let mut command = support::isolated();
    command.args([
        "validate",
        "entry",
        "--worktree",
        w.worktree.to_str().unwrap(),
        "--foreground",
    ]);
    for (key, value) in w.env() {
        command.env(key, value);
    }
    command
        .stdout(OpenOptions::new().write(true).open("/dev/full").unwrap())
        .current_dir(&w.worktree);
    let out = command.output().unwrap();
    assert!(
        !out.status.success(),
        "a failed start publication returned success"
    );
    assert!(stderr(&out).contains("stdout"), "{}", stderr(&out));
    assert!(
        orch_runtime::validate::files::live(&w.worktree)
            .unwrap()
            .is_none()
    );
}

#[test]
fn a_wait_holds_the_real_executor_after_its_command_exits_until_the_sentinel_stands() {
    use orch_runtime::schedule::{Clock, SystemClock};
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    };
    struct ClosingClock {
        calls: AtomicUsize,
        at_close: mpsc::Sender<()>,
        release: Mutex<mpsc::Receiver<()>>,
    }
    impl Clock for ClosingClock {
        fn now(&self) -> Instant {
            SystemClock.now()
        }
        fn wall(&self) -> std::time::SystemTime {
            if self.calls.fetch_add(1, Ordering::SeqCst) == 1 {
                self.at_close.send(()).unwrap();
                self.release
                    .lock()
                    .unwrap()
                    .recv_timeout(JOB_BOUND)
                    .unwrap();
            }
            std::time::UNIX_EPOCH + Duration::from_secs(1769700000)
        }
        fn sleep(&self, d: Duration) {
            SystemClock.sleep(d)
        }
    }
    let w = World::new();
    let dir = executor_dir(&w, "true", 20);
    let agent_runtime::reading::Reading::Live(owner) =
        agent_runtime::process::identity(std::process::id())
    else {
        panic!("the executor owner is unreadable")
    };
    fs::write(
        dir.join("runner"),
        format!(
            "runner=attached\npid={}\nstart={}\nline=runner=attached\n",
            owner.pid, owner.start
        ),
    )
    .unwrap();
    let (closing, at_close) = mpsc::channel();
    let (release, continued) = mpsc::channel();
    let d = dir.clone();
    let executor = std::thread::spawn(move || {
        orch_runtime::validate::run::execute(
            &d,
            &ClosingClock {
                calls: AtomicUsize::new(0),
                at_close: closing,
                release: Mutex::new(continued),
            },
            &PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../github/scripts/lib/group-leader.sh"),
        )
    });
    at_close.recv_timeout(JOB_BOUND).unwrap();
    let clock = Arc::new(support::FakeClock::new());
    let c = clock.clone();
    let d = dir.clone();
    let (sent, received) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        sent.send(orch_runtime::validate::files::wait(&d, 1, c.as_ref()))
            .unwrap()
    });
    let deadline = Instant::now() + JOB_BOUND;
    let answer = loop {
        if let Ok(answer) = received.try_recv() {
            break answer;
        }
        assert!(
            Instant::now() < deadline,
            "the wait exceeded its parent bound"
        );
        clock.release(Duration::from_millis(100));
        std::thread::sleep(Duration::from_millis(10));
    };
    release.send(()).unwrap();
    executor.join().unwrap().unwrap();
    waiter.join().unwrap();
    let (line, exit) = answer.unwrap();
    assert_eq!(exit, 3, "{line}");
    assert_eq!(field(&line, "state"), "running");
    let (line, exit) = orch_runtime::validate::files::wait(&dir, 1, clock.as_ref()).unwrap();
    assert_eq!(exit, 0, "{line}");
    assert_eq!(field(&line, "validate"), "pass");
}

#[test]
fn a_foreground_run_whose_executor_dies_is_held_while_its_command_runs_and_closes_lost_after() {
    let w = World::new();
    let fifo = w.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let ready = w.root.join("ready");
    let command = format!(
        "exec 9<> '{}'; echo ready > '{}'; read -r -t 20 -u 9 answer",
        fifo.display(),
        ready.display()
    );
    let mut child = support::isolated();
    child.args([
        "--state-dir",
        w.state.to_str().unwrap(),
        "validate",
        "start",
        "--item",
        ITEM_ID,
        "--round",
        ROUND,
        "--foreground",
    ]);
    for (k, v) in w.env() {
        child.env(k, v);
    }
    child
        .env("DEV_VALIDATE_CMD", command)
        .current_dir(&w.worktree)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let mut child = Owned(child.spawn().unwrap());
    until(|| ready.exists());
    let dir = w.state()["stages"]
        .as_array()
        .unwrap()
        .iter()
        .rfind(|s| s["kind"] == "validate")
        .unwrap()["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(w.stage(&dir)["job"]["runner"], "attached");
    // The executor dies before its own close; its command runs on in the
    // group it leads.
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    let reconcile = || ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    reconcile();
    assert!(
        w.stage(&dir)["end"].is_null(),
        "the command still runs: {}",
        w.stage(&dir)
    );
    fs::write(&fifo, "release\n").unwrap();
    until(|| {
        reconcile();
        !w.stage(&dir)["end"].is_null()
    });
    assert_eq!(w.stage(&dir)["outcome"], "lost");
    assert!(!Path::new(&dir).join("exit").exists());
}

/// Ends the group a row's detached child leads, whatever the row's answer.
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

#[test]
fn a_bare_pid_run_is_live_by_its_childs_argv_its_stop_ends_that_group_and_its_gone_child_is_lost() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    let dir = w.worktree.join("tmp/dev-validate-released");
    fs::create_dir_all(&dir).unwrap();
    let run_dir = dir.display().to_string();
    // The shell producer's records: the start and the runner record before
    // its launch, then the child's own bare pid, written by the child.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    fs::write(
        dir.join("start"),
        format!(
            "worktree={wt}\ntimeout-bin=timeout\nstart={now}\ntimeout-secs=3600\npoll-secs=30\ncap-secs=3640\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead={}\n",
            w.head()
        ),
    )
    .unwrap();
    fs::write(
        dir.join("runner"),
        "runner=setsid\nline=runner=setsid reason=no-linger\n",
    )
    .unwrap();
    let pid_file = dir.join("pid");
    let _group = Group(pid_file.clone());
    let started = program("setsid")
        .args([
            "-f",
            "sh",
            "-c",
            "echo $$ > \"$1\"; exec perl -e 'sleep 60' -- planted --child --run-dir \"$2\"",
            "child",
            pid_file.to_str().unwrap(),
            &run_dir,
        ])
        .status()
        .unwrap();
    assert!(started.success());
    let live = || w.entry(&["--live", "--worktree", &wt], &[]);
    until(|| live().status.code() == Some(0));
    let pid = fs::read_to_string(&pid_file).unwrap().trim().to_owned();
    assert_eq!(text(&live()), format!("run-dir={run_dir} pid={pid}"));
    let refused = w.local(&[], &[]);
    assert_eq!(refused.status.code(), Some(2));
    assert!(
        stderr(&refused).contains("run-live"),
        "{}",
        stderr(&refused)
    );
    let out = w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(
        text(&out),
        "state=stopped units=0 groups=1",
        "{}",
        stderr(&out)
    );
    until(|| live().status.code() == Some(1));
    let out = w.entry(&["--wait", "--run-dir", &run_dir, "--budget", "5"], &[]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(field(&text(&out), "state"), "lost", "{}", text(&out));
    let out = w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(
        text(&out),
        "state=stopped units=0 groups=0",
        "{}",
        stderr(&out)
    );
    assert_eq!(out.status.code(), Some(0));
    // A process that took the child's number under another argv is not the
    // run: never live, never stopped, and a wait reads the run as running.
    fs::remove_file(dir.join("stop")).unwrap();
    let other = Owned::sleep();
    fs::write(&pid_file, format!("{}\n", other.0.id())).unwrap();
    assert_eq!(live().status.code(), Some(1), "{}", text(&live()));
    let out = w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(text(&out), "state=stopped units=0 groups=0");
    let signal = program("kill")
        .args(["-0", &other.0.id().to_string()])
        .status()
        .unwrap();
    assert!(signal.success(), "the other process runs on");
    let out = w.entry(&["--wait", "--run-dir", &run_dir, "--budget", "2"], &[]);
    assert_eq!(out.status.code(), Some(3), "{}", text(&out));
    // A runner record the shell producer's stop could not read refuses.
    fs::write(dir.join("runner"), "runner=unknown\n").unwrap();
    let out = w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(out.status.code(), Some(1));
    assert!(stderr(&out).contains("stop-unreadable"), "{}", stderr(&out));
}

#[test]
fn a_shell_start_whose_child_never_ran_is_no_run_but_the_runtimes_unread_launch_is_held() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    let dir = w.worktree.join("tmp/dev-validate-unstarted");
    fs::create_dir_all(&dir).unwrap();
    let run_dir = dir.display().to_string();
    // The shell producer's start and runner records, its child never run:
    // started twenty seconds ago, past the ten-second launch grace.
    let started = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        - 20;
    fs::write(
        dir.join("start"),
        format!(
            "worktree={wt}\ntimeout-bin=timeout\nstart={started}\ntimeout-secs=3600\npoll-secs=1\ncap-secs=3611\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead={}\n",
            w.head()
        ),
    )
    .unwrap();
    fs::write(
        dir.join("runner"),
        "runner=setsid\nline=runner=setsid reason=no-linger\n",
    )
    .unwrap();
    let live = w.entry(&["--live", "--worktree", &wt], &[]);
    assert_eq!(live.status.code(), Some(1), "{}", text(&live));
    let out = w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(text(&out), "state=stopped units=0 groups=0");
    let out = w.entry(&["--wait", "--run-dir", &run_dir, "--budget", "2"], &[]);
    assert_eq!(field(&text(&out), "state"), "lost", "{}", text(&out));
    // The same records with the job's error log the runtime's start creates
    // first: its launcher's record names no identity yet, so the run is held.
    fs::remove_file(dir.join("stop")).unwrap();
    fs::write(dir.join("job.err"), "").unwrap();
    let live = w.entry(&["--live", "--worktree", &wt], &[]);
    assert_eq!(live.status.code(), Some(0), "{}", text(&live));
    let out = w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(out.status.code(), Some(1));
    assert!(stderr(&out).contains("stop-unreadable"), "{}", stderr(&out));
    // The runtime's own start, its unit's answer and read lost before any
    // executor claimed the run: the directory it wrote is held live.
    let w = World::new();
    let wt = w.worktree.display().to_string();
    let (path, manager) = manager(&w);
    let extra = [
        ("PATH", path.as_str()),
        ("VALIDATE_MANAGER_DIR", manager.as_str()),
        ("VALIDATE_START_ANSWER", "unread"),
    ];
    assert_eq!(refusal(&w.start(&[], &extra)), "launch-unanswered");
    let live = w.entry(&["--live", "--worktree", &wt], &extra);
    assert_eq!(live.status.code(), Some(0), "{}", text(&live));
}
