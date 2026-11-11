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

/// A job a row started, and what it runs, outlives the row unless ended
/// here: it goes on writing its run directory and the item's record after
/// the scratch is removed, which leaves a part of the scratch behind. Every
/// process whose argv names the world's root or whose working directory
/// lies under it is that world's, so each is killed by its own pid, read
/// again until none stands or the bound passes; a drop never panics.
impl Drop for World {
    fn drop(&mut self) {
        let named = format!("{}/", self.root.display());
        let deadline = Instant::now() + JOB_BOUND;
        loop {
            let standing: Vec<String> = fs::read_dir("/proc")
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|entry| {
                    let pid = entry.file_name().into_string().ok()?;
                    pid.bytes().all(|b| b.is_ascii_digit()).then_some(pid)
                })
                .filter(|pid| {
                    let proc = Path::new("/proc").join(pid);
                    fs::read(proc.join("cmdline"))
                        .is_ok_and(|argv| String::from_utf8_lossy(&argv).contains(&named))
                        || fs::read_link(proc.join("cwd"))
                            .is_ok_and(|cwd| cwd.starts_with(&self.root))
                })
                .collect();
            if standing.is_empty() || Instant::now() >= deadline {
                return;
            }
            let _ = program("kill").arg("-KILL").args(&standing).status();
            std::thread::sleep(Duration::from_millis(50));
        }
    }
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
        World::at("wt")
    }

    /// A world whose worktree is the directory `name`.
    fn at(name: &str) -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let state = root.join("state");
        fs::create_dir_all(&state).unwrap();
        let worktree = root.join(name);
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
    // Bash started as `sh` reads POSIX mode, the shell the setting was not
    // written for.
    let command = "[[ -n $BASH_VERSION ]] && ! shopt -oq posix && printf '%s|%s|%s|%s|%s|%s\n' \"$DEV_VALIDATE_CLASS\" \"$DEV_VALIDATE_DOCS_ONLY\" \"$DEV_VALIDATE_SCOPED\" \"$DEV_VALIDATE_BASE\" \"$(cat \"$DEV_VALIDATE_PATHS\")\" \"$PWD\"";
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
    // The command runs in the worktree it validates.
    let worktree = fs::canonicalize(&w.worktree).unwrap();
    assert!(
        log.contains(&format!("|false|false||src.rs|{}\n", worktree.display())),
        "{log}"
    );
    let record = read_record(&w, &dir);
    assert_eq!(field(&record, "head"), w.head());
    // The record carries the snapshot its start stored, which the return
    // writer binds.
    let tree = field(&run_file(&dir, "start"), "tree");
    assert_eq!(tree.len(), 40, "{record}");
    assert_eq!(field(&record, "tree"), tree, "{record}");
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
    // The cap a waiter reads is the start record's: the bound, the kill grace
    // and one poll.
    let start = run_file(&dir, "start");
    assert_eq!(field(&start, "timeout-secs"), "20", "{start}");
    assert_eq!(field(&start, "cap-secs"), "31", "{start}");
    assert_eq!(field(&start, "poll-secs"), "1", "{start}");
    // The start second orders the run among the worktree's runs.
    let second: u64 = field(&start, "start").parse().unwrap();
    assert!(second.abs_diff(epoch_now()) < 600, "{start}");
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
    // A log the reader cannot read is no selection.
    let w = World::new();
    let dir = directory(&w.local(&[], &[]));
    fs::remove_file(Path::new(&dir).join("log")).unwrap();
    fs::create_dir(Path::new(&dir).join("log")).unwrap();
    let refused = w.entry(&["--record", "--run-dir", &dir], &[]);
    assert_eq!(refused.status.code(), Some(2));
    assert!(
        stderr(&refused).starts_with("dev-validate-run: record-unreadable"),
        "{}",
        stderr(&refused)
    );
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
    // A blank text command declares nothing, as an unset one.
    for text_command in [Some("echo text-command"), None, Some(" ")] {
        let declared = text_command.is_some_and(|c| !c.trim().is_empty());
        let w = World::new();
        let base = w.head();
        w.commit("docs/screen.txt");
        let mut extra = vec![("DEV_VALIDATE_RANGE_CMD", "echo range-command")];
        if let Some(cmd) = text_command {
            extra.push(("DEV_VALIDATE_TEXT_CMD", cmd));
        }
        let result = ok(&w.start(&["--base", &base, "--foreground"], &extra));
        assert_eq!(result["mode"], if declared { "docs" } else { "range" });
        let log = run_file(result["run_dir"].as_str().unwrap(), "log");
        assert!(
            log.contains(if declared {
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
    // A pass at this tree a plain start would reuse.
    let pass = w.local(&[], &[]);
    assert!(pass.status.success(), "{}", stderr(&pass));
    let again = w.local(&["--reproduce"], &[]);
    assert!(again.status.success(), "{}", stderr(&again));
    assert_ne!(directory(&again), directory(&pass));
    assert!(!run_file(&directory(&again), "start").contains("pass-run="));
    assert!(run_file(&directory(&again), "log").contains("full"));
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
fn the_entry_help_states_its_contract_and_a_full_start_ignores_a_base_and_refuses_unused_options() {
    let w = World::new();
    // The workflows send a reader to the entry's `--help` for its contract:
    // the long help, not the one-line summary `-h` prints.
    let help = |flag: &str| {
        let out = w.entry(&[flag], &[]);
        assert!(out.status.success(), "{}", stderr(&out));
        text(&out)
    };
    assert_ne!(help("--help"), help("-h"));
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
    let wt = w.worktree.display().to_string();
    let bad = w.entry(
        &["--worktree", &wt, "--poll", "1", "--run-id", "not-a-run-id"],
        &[],
    );
    assert_eq!(bad.status.code(), Some(2));
    assert!(stderr(&bad).contains("invalid-run-id"), "{}", stderr(&bad));
    // Each refusal exits 2 naming its key and what it refused, and starts
    // nothing. The record rows read run directories whose files a run left
    // unreadable.
    let records = w.root.join("records");
    let record_dir = |name: &str, timing: Option<&str>| {
        let dir = records.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("start"), "validate-mode=full\nstart=1\n").unwrap();
        fs::write(dir.join("exit"), "guard-exit=0 at=2026-01-01T00:55:00Z\n").unwrap();
        if let Some(timing) = timing {
            fs::write(dir.join("timing"), timing).unwrap();
        }
        dir.display().to_string()
    };
    let untimed = record_dir("untimed", None);
    let unstarted = record_dir(
        "badstart",
        Some("started-at=2026-01-01 00:00:00\nended-at=2026-01-01T00:55:00Z\nseconds=3300\n"),
    );
    let unsecond = record_dir(
        "nosecond",
        Some("started-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:55:00Z\n"),
    );
    let empty = records.join("empty").display().to_string();
    fs::create_dir_all(&empty).unwrap();
    // A wait reads the start second, the cap and the poll its start
    // recorded; a start that names none of one is no run.
    let waited = |name: &str, start: &str| {
        let dir = records.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("start"), start).unwrap();
        dir.display().to_string()
    };
    let no_second = waited(
        "no-second",
        "validate-mode=full\ncap-secs=31\npoll-secs=1\n",
    );
    let no_cap = waited("no-cap", "validate-mode=full\nstart=1\npoll-secs=1\n");
    for (args, want) in [
        (vec!["--wait", "--stop"], "mode-conflict"),
        (
            vec!["--wait", "--run-dir", &empty, "--attached"],
            "option-unused cause=start options",
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--fresh"],
            "option-unused cause=start options",
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--reproduce"],
            "option-unused cause=start options",
        ),
        (
            vec!["--worktree", &wt, "--restack"],
            "option-unused cause=--restack",
        ),
        (
            vec![
                "--worktree",
                &wt,
                "--require-proof",
                "H",
                "--expected-head",
                "H",
            ],
            "option-unused cause=--require-proof",
        ),
        (
            vec!["--resolve-mode", "--worktree", &wt, "--expected-head", "H"],
            "option-unused cause=--expected-head",
        ),
        (
            vec!["--resolve-mode", "--worktree", &wt, "--require-proof", "H"],
            "required cause=--expected-head",
        ),
        (
            vec!["--stop", "--worktree", &wt, "--run-dir", &empty],
            "option-unused cause=--run-dir",
        ),
        (
            vec!["--worktree", &wt, "--budget", "5"],
            "option-unused cause=--budget",
        ),
        (
            vec!["--stop", "--worktree", &wt, "--poll", "1"],
            "option-unused cause=--poll",
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--poll", "1"],
            "option-unused cause=--poll",
        ),
        (
            vec!["--stop", "--worktree", &wt, "--validate-mode", "range"],
            "option-unused cause=--validate-mode",
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--validate-mode", "range"],
            "option-unused cause=--validate-mode",
        ),
        (
            vec![
                "--resolve-mode",
                "--worktree",
                &wt,
                "--validate-mode",
                "range",
            ],
            "option-unused cause=--validate-mode",
        ),
        (
            vec!["--stop", "--worktree", &wt, "--base", "HEAD"],
            "option-unused cause=--base",
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--base", "HEAD"],
            "option-unused cause=--base",
        ),
        (vec!["--stop"], "required cause=--worktree"),
        (vec![], "required cause=--worktree"),
        (vec!["--resolve-mode"], "required cause=--worktree"),
        (vec!["--wait"], "required cause=--run-dir"),
        (
            vec!["--stop", "--worktree", "/absent-u8z2p"],
            "not-directory",
        ),
        (
            vec!["--restack-check", "--worktree", &wt],
            "required cause=--base",
        ),
        (
            vec!["--restack-check", "--base", "HEAD"],
            "required cause=--worktree",
        ),
        (
            vec![
                "--restack-check",
                "--worktree",
                "/absent-u8z2p",
                "--base",
                "HEAD",
            ],
            "not-directory",
        ),
        (
            vec!["--worktree", &wt, "--validate-mode", "fast"],
            "invalid-mode cause=fast",
        ),
        (
            vec![
                "--worktree",
                &wt,
                "--validate-mode",
                "range",
                "--base",
                "no-such-ref",
            ],
            "invalid-base base=no-such-ref",
        ),
        (
            vec!["--wait", "--run-dir", &no_second, "--budget", "1"],
            "no-run",
        ),
        (
            vec!["--wait", "--run-dir", &no_cap, "--budget", "1"],
            "no-run cause=cap-secs",
        ),
        (
            vec!["--last-pass", "--worktree", &wt, "--fresh"],
            "option-unused cause=start options",
        ),
        (vec!["--record", "--run-dir", &untimed], "timing-unreadable"),
        (
            vec!["--record", "--run-dir", &unstarted],
            "timing-unreadable cause=started-at",
        ),
        (
            vec!["--record", "--run-dir", &unsecond],
            "timing-unreadable cause=seconds",
        ),
    ] {
        let out = w.entry(&args, &[]);
        let first = stderr(&out).lines().next().unwrap_or_default().to_owned();
        assert_eq!(out.status.code(), Some(2), "{args:?}: {first}");
        assert!(
            first.starts_with(&format!("dev-validate-run: {want}")),
            "{args:?}: {first}"
        );
    }
    let empty_cmd = w.local(&["--fresh"], &[("DEV_VALIDATE_CMD", "")]);
    assert_eq!(empty_cmd.status.code(), Some(2));
    assert!(
        stderr(&empty_cmd)
            .starts_with("dev-validate-run: empty-validate-cmd setting=DEV_VALIDATE_CMD"),
        "{}",
        stderr(&empty_cmd)
    );
    // A validation setting outside its form refuses the start that reads it
    // and no verb that never reads it.
    for (key, value, args) in [
        ("DEV_VALIDATE_TIMEOUT_SECS", "90m", vec![]),
        ("DEV_VALIDATE_TIMEOUT_SECS", "0", vec![]),
        (
            "ORCH_DELIVERY",
            "bogus",
            vec!["--validate-mode", "ci", "--base", base.as_str()],
        ),
    ] {
        let start = w.local(&args, &[(key, value)]);
        assert_eq!(start.status.code(), Some(2), "{key}: {}", text(&start));
        assert!(
            stderr(&start).contains(&format!(
                "dev-validate-run: setting-invalid key={key} value={value}"
            )),
            "{key}: {}",
            stderr(&start)
        );
        let stop = w.entry(&["--stop", "--worktree", &wt], &[(key, value)]);
        assert_eq!(
            text(&stop),
            "state=stopped units=0 groups=0",
            "{key}: {}",
            stderr(&stop)
        );
        let resolved = w.entry(&["--resolve-mode", "--worktree", &wt], &[(key, value)]);
        assert_eq!(text(&resolved), "validate-mode=full", "{key}");
    }
    // A finding prefix holding a newline begins no log line: the start runs
    // and records none.
    let out = w.local(&["--fresh"], &[("DEV_VALIDATE_FINDING_PREFIX", "a\nb")]);
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(!run_file(&directory(&out), "start").contains("finding-prefix="));
    let out = w.local(&["--fresh"], &[("DEV_VALIDATE_FINDING_PREFIX", "guard: ")]);
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(run_file(&directory(&out), "start").contains("\nfinding-prefix=guard: \n"));
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
        "exec 9<> '{}'; echo first; echo second; echo ready > '{}'; read -r -t 5 -u 9 answer; exit 77",
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
    // What the command printed before its deadline stays in its log.
    let log = fs::read_to_string(dir.join("log")).unwrap();
    assert!(log.contains("\nfirst\nsecond\n"), "{log}");
    let id: agent_runtime::process::Identity =
        serde_json::from_slice(&fs::read(dir.join("command")).unwrap()).unwrap();
    assert!(matches!(
        agent_runtime::process::still_runs(&id),
        agent_runtime::reading::Reading::Gone
    ));
    assert!(clock.elapsed() >= Duration::from_secs(2));
}

#[test]
fn a_command_that_ignores_term_is_killed_at_the_grace_after_its_deadline() {
    use orch_runtime::validate::KILL_GRACE;
    use std::sync::{Arc, mpsc};
    let w = World::new();
    let ready = w.root.join("ready");
    let pgid = w.root.join("pgid");
    let _group = Group(pgid.clone());
    // The command outlives the row's own bound unless the grace's KILL ends it.
    let command = format!(
        "trap '' TERM; ps -o pgid= -p $$ > '{}'; echo ready > '{}'; sleep 40; exit 77",
        pgid.display(),
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
    let deadline = Instant::now() + Duration::from_secs(KILL_GRACE + 15);
    let answer = loop {
        match received.try_recv() {
            Ok(answer) => break answer,
            Err(mpsc::TryRecvError::Disconnected) => panic!("executor ended without answer"),
            Err(mpsc::TryRecvError::Empty) => {
                assert!(
                    Instant::now() < deadline,
                    "the command outlived the kill grace"
                );
                clock.release(Duration::from_millis(100));
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    };
    answer.unwrap();
    task.join().unwrap();
    let sentinel = fs::read_to_string(dir.join("exit")).unwrap();
    assert_eq!(field(&sentinel, "guard-exit"), "124", "{sentinel}");
    let id: agent_runtime::process::Identity =
        serde_json::from_slice(&fs::read(dir.join("command")).unwrap()).unwrap();
    assert!(matches!(
        agent_runtime::process::still_runs(&id),
        agent_runtime::reading::Reading::Gone
    ));
}

#[test]
fn a_sentinel_the_device_refuses_fails_the_executor_and_the_run_reads_failing() {
    if !Path::new("/dev/full").exists() {
        return;
    }
    let w = World::new();
    let dir = executor_dir(&w, "exit 0", 20);
    std::os::unix::fs::symlink("/dev/full", dir.join("exit.part")).unwrap();
    let answer = orch_runtime::validate::run::execute(
        &dir,
        &orch_runtime::schedule::SystemClock,
        &PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../github/scripts/lib/group-leader.sh"),
    );
    assert!(answer.is_err(), "{answer:?}");
    assert!(!dir.join("exit").exists());
    // A record with no sentinel is no verdict a return could cite as a pass.
    assert_eq!(
        field(&read_record(&w, dir.to_str().unwrap()), "verdict"),
        "unfinished"
    );
    let out = w.entry(
        &[
            "--wait",
            "--run-dir",
            dir.to_str().unwrap(),
            "--budget",
            "5",
        ],
        &[],
    );
    // No sentinel, so the run past its cap reads failing, never done.
    assert_eq!(field(&text(&out), "validate"), "FAILING", "{}", text(&out));
    assert_ne!(field(&text(&out), "state"), "done");
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
    // The verdict stands before the group is ended: a member that ignores
    // TERM sees the sentinel while it still runs, and the KILL after the
    // grace ends it.
    let w = World::new();
    let command = "d=$(dirname \"$DEV_VALIDATE_PATHS\"); ( trap '' TERM; while [ ! -s \"$d/exit\" ]; do sleep 0.05; done; echo seen > \"$d/seen\"; sleep 30 ) & exit 0";
    let out = w.local(&[], &[("DEV_VALIDATE_CMD", command)]);
    assert!(out.status.success(), "{}", stderr(&out));
    let dir = directory(&out);
    assert_eq!(run_file(&dir, "seen"), "seen\n");
    assert_eq!(field(&read_record(&w, &dir), "verdict"), "pass");
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
fn a_unit_launch_hands_the_manager_the_callers_variables_and_open_file_limit() {
    let w = World::new();
    let (path, manager) = manager(&w);
    let started = ok(&w.start(
        &[],
        &[
            ("PATH", &path),
            ("VALIDATE_MANAGER_DIR", &manager),
            ("VALIDATE_ENV_MARK", "x"),
        ],
    ));
    let dir = started["run_dir"].as_str().unwrap();
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    let launches = fs::read_to_string(Path::new(&manager).join("launches")).unwrap();
    let unit = launches.lines().next().unwrap();
    // The unit is named for the worktree it validates and its run's own
    // directory name, never the directory's path: a unit name is bounded.
    let run = Path::new(dir).file_name().unwrap().to_str().unwrap();
    assert_eq!(unit, format!("orch-validate-wt-{run}"));
    let argv = fs::read_to_string(Path::new(&manager).join(format!("{unit}.argv"))).unwrap();
    let words: Vec<&str> = argv.lines().collect();
    // A unit inherits the manager's environment and limits, not the
    // caller's: the client is handed both.
    assert!(words.contains(&"--setenv=VALIDATE_ENV_MARK"), "{argv}");
    let limits = fs::read_to_string("/proc/self/limits").unwrap();
    let line = limits
        .lines()
        .find(|l| l.starts_with("Max open files"))
        .unwrap();
    let mut limit = line["Max open files".len()..]
        .split_whitespace()
        .map(|w| if w == "unlimited" { "infinity" } else { w });
    let property = format!(
        "LimitNOFILE={}:{}",
        limit.next().unwrap(),
        limit.next().unwrap()
    );
    assert!(words.contains(&property.as_str()), "{argv}");
    // The unit carries the run's cap, takes SIGPIPE at its default, and its
    // record names it as the stop reads it.
    assert!(words.contains(&"RuntimeMaxSec=31"), "{argv}");
    assert!(words.contains(&"IgnoreSIGPIPE=no"), "{argv}");
    assert_eq!(
        run_file(dir, "runner"),
        format!("runner=systemd\nunit={unit}\nline=runner=systemd unit={unit}\n")
    );
}

/// The unit's argument words and its runner record line, for the one unit
/// the planted manager started.
fn unit_launch(manager: &str, dir: &str) -> (Vec<String>, String) {
    let launches = fs::read_to_string(Path::new(manager).join("launches")).unwrap();
    let unit = launches.lines().next().unwrap();
    let argv = fs::read_to_string(Path::new(manager).join(format!("{unit}.argv"))).unwrap();
    let line = run_file(dir, "runner")
        .lines()
        .find_map(|l| l.strip_prefix("line=").map(str::to_owned))
        .unwrap_or_default();
    (argv.lines().map(str::to_owned).collect(), line)
}

/// A memory cap set for validation is its unit's hard limit over the whole
/// tree, swap included, with the manager's stop at the first OOM kill off
/// and no soft cap beside it, on the admitted start and the ad-hoc entry
/// alike, and the runner line names it; with none set, the unit carries
/// none of them.
#[test]
fn a_set_memory_cap_is_the_validation_units_hard_limit_with_no_swap_and_no_oom_stop() {
    for (cap, held) in [(Some("1G"), true), (None, false)] {
        let w = World::new();
        let (path, manager) = manager(&w);
        let mut extra = vec![
            ("PATH", path.as_str()),
            ("VALIDATE_MANAGER_DIR", manager.as_str()),
        ];
        if let Some(cap) = cap {
            extra.push(("ORCH_VALIDATE_MEMORY_MAX", cap));
        }
        let started = ok(&w.start(&[], &extra));
        let dir = started["run_dir"].as_str().unwrap();
        assert_eq!(w.wait_closed(dir)["outcome"], "pass", "{cap:?}");
        let (words, line) = unit_launch(&manager, dir);
        for property in [
            "MemoryMax=1073741824",
            "MemorySwapMax=0",
            "OOMPolicy=continue",
        ] {
            assert_eq!(
                words.iter().any(|w| w == property),
                held,
                "{cap:?} {property}: {words:?}"
            );
        }
        if held {
            assert!(
                !words.iter().any(|w| w.starts_with("MemoryHigh=")),
                "{words:?}"
            );
        }
        assert_eq!(
            line.ends_with(" memory-max=1073741824"),
            held,
            "{cap:?}: {line}"
        );
        assert_eq!(w.stage(dir)["job"]["line"], json!(line), "{cap:?}");
    }
    let w = World::new();
    let (path, manager) = manager(&w);
    let wt = w.worktree.display().to_string();
    let out = w.entry(
        &["--worktree", &wt, "--poll", "1", "--fresh"],
        &[
            ("PATH", path.as_str()),
            ("VALIDATE_MANAGER_DIR", manager.as_str()),
            ("ORCH_VALIDATE_MEMORY_MAX", "2G"),
        ],
    );
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    let (words, line) = unit_launch(&manager, &directory(&out));
    assert!(
        words.iter().any(|w| w == "MemoryMax=2147483648"),
        "{words:?}"
    );
    assert!(line.ends_with(" memory-max=2147483648"), "{line}");
}

/// A memory cap no cgroup of the run's own can hold, a `setsid` job or a
/// run in the caller's own process, is said unheld once, on the runner
/// line the run's record and its log carry, and the run still runs: a
/// manager that does not answer, and a client older than a property the
/// cap sets, which refuses the name before it asks the manager anything.
#[test]
fn a_memory_cap_no_cgroup_of_the_run_holds_is_said_unheld_once_and_the_run_runs() {
    for (answer, opening, cause) in [
        (
            ("VALIDATE_PROBE_ANSWER", "no-manager"),
            "runner=setsid reason=probe-failed ",
            "probe-failed",
        ),
        (
            ("VALIDATE_START_ANSWER", "unknown-assignment"),
            "runner=setsid reason=unit-launch-failed detail=Unknown assignment: OOMPolicy=continue ",
            "unit-launch-failed",
        ),
    ] {
        let w = World::new();
        let (path, manager) = manager(&w);
        let started = ok(&w.start(
            &[],
            &[
                ("PATH", &path),
                ("VALIDATE_MANAGER_DIR", &manager),
                answer,
                ("ORCH_VALIDATE_MEMORY_MAX", "1G"),
            ],
        ));
        let dir = started["run_dir"].as_str().unwrap();
        let stage = w.wait_closed(dir);
        assert_eq!(stage["outcome"], "pass", "{cause}");
        let word = format!(" memory-cap=unavailable cause={cause}");
        let line = stage["job"]["line"].as_str().unwrap();
        assert!(line.starts_with(opening), "{line}");
        assert_eq!(line.matches(&word).count(), 1, "{line}");
        let log = run_file(dir, "log");
        assert_eq!(log.lines().next(), Some(line), "{log}");
        assert!(
            !run_file(dir, "exit").contains("memory-cap"),
            "{}",
            run_file(dir, "exit")
        );
    }
    let w = World::new();
    let started = ok(&w.start(&["--foreground"], &[("ORCH_VALIDATE_MEMORY_MAX", "1G")]));
    let dir = started["run_dir"].as_str().unwrap();
    let stage = w.stage(dir);
    assert_eq!(stage["outcome"], "pass");
    assert_eq!(
        stage["job"]["line"],
        "runner=attached memory-cap=unavailable cause=attached"
    );
}

/// The memory cap's setting is judged by the validation start that reads
/// it, before any record: a value outside systemd's byte form or under the
/// floor refuses the start with the key, the value and the floor, and the
/// item's record is left as it was.
#[test]
fn a_memory_cap_outside_its_form_or_under_its_floor_refuses_the_start_with_nothing_recorded() {
    for value in [
        "512M",
        "1073741823",
        "1.5G",
        "1g",
        "01G",
        "infinity",
        "50%",
        "99999999999T",
    ] {
        let w = World::new();
        let before = fs::read_to_string(&w.item).unwrap();
        let out = w.start(&[], &[("ORCH_VALIDATE_MEMORY_MAX", value)]);
        assert_eq!(refusal(&out), "setting-invalid", "{value}");
        assert_eq!(
            reply(&out)["refusal"]["fields"],
            json!([
                ["key", "ORCH_VALIDATE_MEMORY_MAX"],
                ["value", value],
                ["floor", "1G"]
            ]),
            "{value}"
        );
        assert_eq!(fs::read_to_string(&w.item).unwrap(), before, "{value}");
    }
    let w = World::new();
    let started = ok(&w.start(
        &["--foreground"],
        &[("ORCH_VALIDATE_MEMORY_MAX", "1073741824")],
    ));
    assert_eq!(started["outcome"], "pass");
}

/// A `PATH` of every program the row's own `PATH` names but `without`, each
/// name linked once from the first directory that holds it.
fn farm_without(w: &World, without: &[&str]) -> String {
    let farm = w.root.join(format!("farm-{}", without.join("-")));
    fs::create_dir_all(&farm).unwrap();
    for dir in std::env::split_paths(&tool_path(&[])) {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let link = farm.join(&name);
            if without.iter().any(|w| name == **w) || link.symlink_metadata().is_ok() {
                continue;
            }
            std::os::unix::fs::symlink(entry.path(), link).unwrap();
        }
    }
    farm.display().to_string()
}

#[test]
fn a_host_without_systemd_run_runs_the_job_under_setsid_beyond_its_starters_group() {
    use std::os::unix::process::CommandExt;
    let w = World::new();
    // A detached run forks through no group-leader prefix, so a host without
    // perl runs it; only a foreground start needs perl.
    let path = farm_without(&w, &["systemd-run", "perl"]);
    let mut command = support::isolated();
    command
        .arg("--state-dir")
        .arg(&w.state)
        .args([
            "validate", "start", "--item", ITEM_ID, "--round", ROUND, "--poll", "1",
        ])
        .current_dir(&w.worktree)
        .process_group(0)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    for (k, v) in w.env() {
        command.env(k, v);
    }
    command
        .env("PATH", &path)
        .env("DEV_VALIDATE_CMD", "sleep 1; echo full");
    let child = command.spawn().unwrap();
    let starter = child.id();
    let started = ok(&child.wait_with_output().unwrap());
    // A harness reaps a background shell by its process group: the job is
    // in a session of its own, so it outlives the group that started it.
    let _ = program("kill")
        .args(["-KILL", "--", &format!("-{starter}")])
        .status();
    let dir = started["run_dir"].as_str().unwrap();
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    let log = run_file(dir, "log");
    assert!(
        log.starts_with("runner=setsid reason=no-systemd-run pid="),
        "{log}"
    );
    let wt = w.worktree.display().to_string();
    let out = w.entry(
        &["--worktree", &wt, "--foreground", "--poll", "1", "--fresh"],
        &[("PATH", path.as_str())],
    );
    assert_eq!(out.status.code(), Some(2), "{}", text(&out));
    assert!(
        stderr(&out).contains("dev-validate-run: missing-command cause=commands=perl"),
        "{}",
        stderr(&out)
    );
    // A host with neither runner starts nothing, and says the launch failed.
    let bare = farm_without(&w, &["systemd-run", "setsid", "perl"]);
    let out = w.entry(
        &["--worktree", &wt, "--poll", "1", "--fresh"],
        &[("PATH", bare.as_str())],
    );
    assert_eq!(out.status.code(), Some(2), "{}", text(&out));
    // The cause is the launcher's own: setsid could not be run.
    assert!(
        stderr(&out).starts_with("dev-validate-run: launch-failed cause=launch-failed cause="),
        "{}",
        stderr(&out)
    );
}

#[test]
fn a_user_manager_that_does_not_answer_the_probe_leaves_the_job_to_setsid_naming_why() {
    let w = World::new();
    let (path, manager) = manager(&w);
    let started = ok(&w.start(
        &[],
        &[
            ("PATH", &path),
            ("VALIDATE_MANAGER_DIR", &manager),
            ("VALIDATE_PROBE_ANSWER", "no-manager"),
        ],
    ));
    let dir = started["run_dir"].as_str().unwrap();
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    let log = run_file(dir, "log");
    assert!(
        log.starts_with(
            "runner=setsid reason=probe-failed detail=Failed to connect to user scope bus via local transport: No such file or directory pid="
        ),
        "{log}"
    );
    assert!(!Path::new(&manager).join("launches").exists());
    // A manager that does not linger stops its units at the last logout, and
    // a Linger that cannot be read is no linger: the job runs under setsid.
    for (linger, want) in [
        ("no", "runner=setsid reason=no-linger pid="),
        (
            "unread",
            "runner=setsid reason=linger-unread detail=linger read refused pid=",
        ),
    ] {
        let w = World::new();
        let (path, manager_dir) = self::manager(&w);
        let started = ok(&w.start(
            &[],
            &[
                ("PATH", &path),
                ("VALIDATE_MANAGER_DIR", &manager_dir),
                ("VALIDATE_LINGER", linger),
            ],
        ));
        let dir = started["run_dir"].as_str().unwrap();
        assert_eq!(w.wait_closed(dir)["outcome"], "pass", "{linger}");
        let log = run_file(dir, "log");
        assert!(log.starts_with(want), "{linger}: {log}");
        assert!(
            !Path::new(&manager_dir).join("launches").exists(),
            "{linger}"
        );
    }
}

#[test]
fn a_host_with_a_user_manager_and_no_setsid_runs_the_job_in_a_unit() {
    let w = World::new();
    let (_, manager) = manager(&w);
    let path = format!(
        "{}:{}",
        fixtures().join("validate-tools").display(),
        farm_without(&w, &["setsid"])
    );
    let started = ok(&w.start(&[], &[("PATH", &path), ("VALIDATE_MANAGER_DIR", &manager)]));
    let dir = started["run_dir"].as_str().unwrap();
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    assert!(
        run_file(dir, "log").starts_with("runner=systemd unit=orch-validate-"),
        "{}",
        run_file(dir, "log")
    );
}

#[test]
fn a_worktree_path_holding_a_dollar_reaches_its_unit_as_written_and_names_none() {
    let w = World::at("wt-${HOME}");
    let (path, manager) = manager(&w);
    let started = ok(&w.start(&[], &[("PATH", &path), ("VALIDATE_MANAGER_DIR", &manager)]));
    let dir = started["run_dir"].as_str().unwrap();
    assert_eq!(w.wait_closed(dir)["outcome"], "pass");
    let launches = fs::read_to_string(Path::new(&manager).join("launches")).unwrap();
    let unit = launches.lines().next().unwrap();
    // A unit name carries no `$`; the manager reads `$$` as one `$`.
    assert!(unit.starts_with("orch-validate-wt-__HOME_-"), "{unit}");
    let argv = fs::read_to_string(Path::new(&manager).join(format!("{unit}.argv"))).unwrap();
    assert!(
        argv.lines()
            .any(|word| word == dir.replace('$', "$$").as_str()),
        "{argv}"
    );
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
fn a_failed_unit_call_whose_unit_runs_is_the_job_a_start_waits_on_and_never_opens_a_second_job() {
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
    // The client failed after the manager accepted the unit, which runs.
    ok(&w.start(&[], &env));
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
    // The ad-hoc entry waits on the found unit for its verdict.
    let wt = w.worktree.display().to_string();
    let out = w.entry(
        &["--worktree", &wt, "--poll", "1", "--fresh"],
        &[
            ("PATH", path.as_str()),
            ("VALIDATE_MANAGER_DIR", manager.as_str()),
            ("VALIDATE_START_ANSWER", "lost"),
        ],
    );
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(
        field(text(&out).lines().last().unwrap(), "validate"),
        "pass"
    );
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
    // A worktree with no run has no last pass.
    let w = World::new();
    let out = w.entry(
        &["--last-pass", "--worktree", w.worktree.to_str().unwrap()],
        &[],
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(text(&out), "last-pass=none");
    for (ending, stamp, tree, want) in [
        ("guard-exit=0 at=2026-01-01T00:00:00Z", "2", "T2", "pass"),
        ("guard-exit=1 at=2026-01-01T00:00:00Z", "2", "T2", "red"),
        // A red in the pass's own start second, which the records cannot
        // order, and one that started before the pass.
        ("guard-exit=1 at=2026-01-01T00:00:00Z", "1", "T2", "red"),
        ("guard-exit=1 at=2026-01-01T00:00:00Z", "0", "T2", "before"),
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
    for missing in ["cmd", "paths", "start"] {
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
    // The pass's lanes travel with its reuse.
    let lanes = [(
        "DEV_VALIDATE_CMD",
        "echo 'validate: lanes=a,b selection=subset'",
    )];
    let first = w.local(&[], &lanes);
    assert!(first.status.success());
    let old = directory(&first);
    let reused = w.local(&[], &lanes);
    assert!(reused.status.success());
    let reused = directory(&reused);
    assert!(run_file(&reused, "start").contains(&format!("pass-run={old}\n")));
    assert!(
        run_file(&reused, "log").starts_with(&format!("runner=none pass-run={old}:")),
        "{}",
        run_file(&reused, "log")
    );
    assert_eq!(field(&read_record(&w, &reused), "lanes"), "a,b");
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
    let out = w.local(&[], &lanes);
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(!run_file(&directory(&out), "start").contains("pass-run="));
    // A failure in the pass's own start second, whichever directory sorts
    // first, and one whose start second cannot be read, each void the pass:
    // their records cannot prove they came before it. A pass whose start
    // second cannot be read proves nothing and voids nothing.
    // A failure voids the pass whatever base, class, docs verdict or finding
    // prefix it was handed; one that started before the pass does not.
    for (case, start, exit, voids, edit) in [
        ("tied", "same", "guard-exit=1", true, None),
        ("unordered", "", "guard-exit=1", true, None),
        ("unordered-pass", "", "guard-exit=0", false, None),
        ("older", "older", "guard-exit=1", false, None),
        (
            "other-base",
            "same",
            "guard-exit=1",
            true,
            Some(("validate-base", "0000000000000000000000000000000000000000")),
        ),
        (
            "other-class",
            "same",
            "guard-exit=1",
            true,
            Some(("class", "render")),
        ),
        (
            "other-docs",
            "same",
            "guard-exit=1",
            true,
            Some(("docs-only", "true")),
        ),
        (
            "other-prefix",
            "same",
            "guard-exit=1",
            true,
            Some(("finding-prefix", "OTHER:")),
        ),
    ] {
        let w = World::new();
        w.commit("source.rs");
        let first = w.local(&[], &[]);
        assert!(first.status.success(), "{case}: {}", stderr(&first));
        let pass = directory(&first);
        let record = run_file(&pass, "start");
        let second = record
            .lines()
            .find_map(|l| l.strip_prefix("start="))
            .unwrap()
            .to_owned();
        let planted = w.worktree.join("tmp/dev-validate-0");
        fs::create_dir(&planted).unwrap();
        let older = (second.parse::<u64>().unwrap() - 1).to_string();
        let start = match start {
            "same" => second.as_str(),
            "older" => older.as_str(),
            other => other,
        };
        let mut record = record.replace(&format!("start={second}\n"), &format!("start={start}\n"));
        if let Some((key, value)) = edit {
            let mut lines: Vec<String> = record
                .lines()
                .filter(|l| !l.starts_with(&format!("{key}=")))
                .map(str::to_owned)
                .collect();
            lines.push(format!("{key}={value}"));
            record = lines.join("\n") + "\n";
        }
        fs::write(planted.join("start"), record).unwrap();
        fs::write(
            planted.join("exit"),
            format!("{exit} at=2026-01-01T00:00:00Z\n"),
        )
        .unwrap();
        fs::copy(Path::new(&pass).join("paths"), planted.join("paths")).unwrap();
        fs::copy(Path::new(&pass).join("cmd"), planted.join("cmd")).unwrap();
        let out = w.local(&[], &[]);
        assert!(out.status.success(), "{case}: {}", stderr(&out));
        assert_eq!(
            !run_file(&directory(&out), "start").contains(&format!("pass-run={pass}\n")),
            voids,
            "{case}"
        );
    }
    // A tree changed after the pass runs the command again.
    let w = World::new();
    w.commit("source.rs");
    let first = w.local(&[], &[]);
    assert!(first.status.success(), "{}", stderr(&first));
    fs::write(w.worktree.join("source.rs"), "changed after the pass\n").unwrap();
    let next = w.local(&[], &[]);
    assert!(next.status.success(), "{}", stderr(&next));
    assert!(!run_file(&directory(&next), "start").contains("pass-run="));
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
    // A map the projection cannot read refuses the range start, naming why.
    for (text, cause) in [
        (format!("rebase-unmapped: {third}\n"), "rebase-unmapped"),
        (
            format!("rebase-hop:\nrebase-map: nonsha {second}\n"),
            "map-sha",
        ),
        (
            format!("rebase-hop:\nrebase-map: {base} nonsha\n"),
            "map-sha",
        ),
        (
            format!("rebase-map: {base} {second}\n"),
            "restack-map-grammar",
        ),
        ("rebase-hop:\n".to_owned(), "restack-map-grammar"),
        (
            format!("rebase-hop:\nother: {base}\n"),
            "restack-map-grammar",
        ),
    ] {
        fs::write(&map, &text).unwrap();
        let out = w.local(
            &["--validate-mode", "range", "--base", &base, "--fresh"],
            &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
        );
        assert_eq!(out.status.code(), Some(2), "{text}");
        assert!(
            stderr(&out).starts_with(&format!(
                "dev-validate-run: rebase-map-unreadable cause={cause}"
            )),
            "{text}: {}",
            stderr(&out)
        );
    }
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
    let wt = w.worktree.display().to_string();
    let proof = |proof_head: &str, expected: &str| {
        w.entry(
            &[
                "--resolve-mode",
                "--worktree",
                &wt,
                "--require-proof",
                proof_head,
                "--expected-head",
                expected,
            ],
            &[],
        )
    };
    // No run: the proof is missing, named by the CI admission's own cause.
    let before = w.commit("before.rs");
    let out = proof(&before, &before);
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    assert_eq!(
        field(&text(&out), "ci-fallback"),
        "push-base",
        "{}",
        text(&out)
    );
    w.commit("source.rs");
    let out = w.local(&[], &[]);
    assert!(out.status.success());
    let head = w.head();
    // The released fences pass no --base: the proof's base is the merge base
    // with the origin base branch, and a restack of the run's tree onto it
    // that conflicts nowhere proves the run's head.
    let out = proof(&head, &head);
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    assert_eq!(text(&out).lines().next(), Some("validate-mode=full"));
    assert_eq!(field(&text(&out), "validation-proof"), "tree-pass");
    // A proof asked for another head than the run's is the run's local pass
    // over the tree.
    let out = proof(&before, &head);
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    assert_eq!(field(&text(&out), "validation-proof"), "local-pass");
    let args = [
        "--resolve-mode",
        "--worktree",
        w.worktree.to_str().unwrap(),
        "--require-proof",
        head.as_str(),
        "--expected-head",
        head.as_str(),
    ];
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
    // A base the proof cannot resolve is no answer.
    git(&w.worktree, &["checkout", "-q", "--", "source.rs"]);
    git(
        &w.worktree,
        &["update-ref", "-d", "refs/remotes/origin/main"],
    );
    let out = proof(&head, &head);
    assert_eq!(out.status.code(), Some(2), "{}", text(&out));
    assert!(
        stderr(&out).contains("dev-validate-run: proof-base-unresolved"),
        "{}",
        stderr(&out)
    );
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
    let mut protection = json!({"commit":{"sha":"0000000000000000000000000000000000000000","commit":{"committer":null}},"protected":false,"protection":{"required_status_checks":{"contexts":[],"checks":[]}}});
    let mut view = json!({"state":"OPEN","baseRefName":"main"});
    if case == "context-unrequired" {
        rules = json!([]);
    }
    // Classic branch protection alone names the context: by its contexts
    // list, or by its checks.
    if case == "classic-contexts" {
        rules = json!([{ "type":"merge_queue" }]);
        protection = json!({"commit":{"sha":"0000000000000000000000000000000000000000","commit":{"committer":null}},"protected":true,"protection":{"required_status_checks":{"contexts":["CI"],"checks":[]}}});
    }
    if case == "classic-checks" {
        rules = json!([{ "type":"merge_queue" }]);
        protection = json!({"commit":{"sha":"0000000000000000000000000000000000000000","commit":{"committer":null}},"protected":true,"protection":{"required_status_checks":{"contexts":[],"checks":[{"context":"CI","app_id":null}]}}});
    }
    // GitHub's branch for a caller without push access: no `protection`.
    if case == "protection-unread" {
        protection = json!({"commit":{"sha":"0000000000000000000000000000000000000000","commit":{"committer":null}},"protected":true});
    }
    if case == "pr-not-open" {
        view["state"] = json!("MERGED");
    }
    if case == "base-unresolved" {
        view = json!({"state":"UNKNOWN"});
    }
    if case == "base-empty" {
        view["baseRefName"] = json!("");
    }
    if case == "closed-render" {
        view["state"] = json!("CLOSED");
    }
    if case == "queue-unrequired" {
        rules = json!([]);
    }
    if matches!(
        case,
        "queue-no-merge-queue" | "queue-absent" | "queue-malformed" | "push-first-no-pr-no-queue"
    ) {
        rules = json!([{ "type":"required_status_checks", "parameters":{"required_status_checks":[{"context":"CI"}]} }]);
    }
    // A stacked pull request's own base requires nothing; the default
    // branch still requires the context.
    if case == "stacked" {
        view["baseRefName"] = json!("feature/parent");
    }
    // The rules as GitHub pages them at the size the reader asks for; a
    // base with more rules than one page holds requires the context on
    // its second page.
    let mut pages = vec![rules];
    if case == "rules-second-page" {
        pages.insert(0, json!(vec![json!({"type":"deletion"}); 100]));
    }
    let rules_page = |base: &str, n: usize| {
        format!("repos/{{owner}}/{{repo}}/rules/branches/{base}?per_page=100&page={n}")
    };
    let mut replies = json!({"pr view --json":{"body":view},"repos/{owner}/{repo}/branches/main":{"body":protection}});
    for (n, page) in pages.into_iter().enumerate() {
        replies[rules_page("main", n + 1)] = json!({ "body": page });
    }
    if case == "rules-unread" {
        replies[rules_page("main", 1)]["exit"] = json!(1);
    }
    if case == "pr-unread" {
        replies["pr view --json"] = json!({"exit":1,"stderr":"HTTP 502: Bad Gateway"});
    }
    if case == "stacked" {
        replies[rules_page("feature%2Fparent", 1)] = json!({"body":[]});
        replies["repos/{owner}/{repo}/branches/feature%2Fparent"] = json!({"body":{"commit":{"sha":"0000000000000000000000000000000000000000","commit":{"committer":null}},"protected":false,"protection":{"required_status_checks":{"contexts":[],"checks":[]}}}});
    }
    // gh's answer for a branch with no pull request, which push-first
    // reads as its resolved base.
    if matches!(case, "push-first-no-pr" | "push-first-no-pr-no-queue") {
        replies["pr view --json"] =
            json!({"exit":1,"stderr":"no pull requests found for branch \"feature\""});
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
        ("classic-contexts", "ci", ""),
        ("classic-checks", "ci", ""),
        ("rules-second-page", "ci", ""),
        ("rules-unread", "range", "rules-unread"),
        ("protection-unread", "range", "rules-unread"),
        ("context-unrequired", "range", "context-unrequired"),
        ("pr-not-open", "range", "pr-not-open"),
        ("base-unresolved", "range", "base-unresolved"),
        ("push-base", "range", "push-base"),
        ("setting-empty", "range", "setting-empty"),
        ("stacked", "range", "context-unrequired"),
        ("push-first-no-pr", "ci", ""),
        ("class-render", "range", "class-uncovered"),
        ("class-standard-unmeasured", "ci", ""),
        ("class-micro-unmeasured", "range", "class-uncovered"),
        ("class-docs", "range", "class-uncovered"),
        ("class-docs-unread", "range", "class-uncovered"),
        ("queue-required", "ci", ""),
        ("queue-unrequired", "range", "class-uncovered"),
        ("queue-no-merge-queue", "range", "class-uncovered"),
        // Only a record reading false proves pull-request CI covers the work.
        ("queue-absent", "range", "class-uncovered"),
        ("queue-malformed", "range", "class-uncovered"),
        ("queue-absent-merge-queue", "ci", ""),
        // The pull request read fails, or names an empty base.
        ("pr-unread", "range", "base-unresolved"),
        ("base-empty", "range", "base-unresolved"),
        // No open pull request, and a class CI may not cover.
        ("closed-render", "range", "class-uncovered"),
        ("class-micro-measured", "ci", ""),
    ] {
        let w = World::new();
        let base = w.head();
        w.commit("source.rs");
        let (path, replies, log) = ci_world(&w, case);
        let scope = support::fixtures()
            .join("change-scope-fixture/harness-only")
            .display()
            .to_string();
        let mut extra = vec![
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
        if case == "push-first-no-pr" {
            extra.push(("ORCH_PR_ORDER", "push-first"));
        }
        // The classifier's answer, through the fixture that prints its
        // contract: the class word, its measured marker, the docs verdict
        // and the queue-only record.
        let classified = match case {
            "class-render" | "closed-render" => Some(("render", "true", "false", "false")),
            "class-micro-measured" => Some(("micro", "true", "false", "false")),
            "class-standard-unmeasured" => Some(("standard", "false", "false", "false")),
            "class-micro-unmeasured" => Some(("micro", "false", "false", "false")),
            "class-docs" => Some(("standard", "true", "true", "false")),
            "class-docs-unread" => Some(("micro", "true", "unread", "false")),
            "queue-required" | "queue-unrequired" | "queue-no-merge-queue" => {
                Some(("standard", "true", "false", "true"))
            }
            "queue-absent" | "queue-absent-merge-queue" => {
                Some(("standard", "true", "false", "absent"))
            }
            "queue-malformed" => Some(("standard", "true", "false", "unknown")),
            _ => None,
        };
        if let Some((class, measured, docs, queue)) = classified {
            extra.extend([
                ("CHANGE_SCOPE_PATHS_CLI", scope.as_str()),
                ("CHANGE_SCOPE_CLASS", class),
                ("CHANGE_SCOPE_MEASURED", measured),
                ("CHANGE_SCOPE_DOCS", docs),
                ("CHANGE_SCOPE_QUEUE_ONLY", queue),
            ]);
        }
        let out = w.local(&["--validate-mode", "ci", "--base", &base], &extra);
        assert!(
            out.status.success(),
            "case={case} {} {}",
            text(&out),
            stderr(&out)
        );
        // A run that ran nothing still prints its started line first.
        assert!(
            text(&out).starts_with("state=started "),
            "{case}: {}",
            text(&out)
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
        // A run left to required CI is pending, and no pass a later start
        // could reuse; its log's runner line names that no command ran.
        if want_mode == "ci" {
            assert!(
                run_file(&dir, "log").starts_with("runner=none class="),
                "{case}: {}",
                run_file(&dir, "log")
            );
            let wt = w.worktree.display().to_string();
            let last = w.entry(&["--last-pass", "--worktree", &wt], &[]);
            assert_eq!(last.status.code(), Some(1), "{case}");
            assert_eq!(text(&last).trim(), "last-pass=none", "{case}");
        }
        // A read-only resolution of the same round reads the base the start
        // read: the open PR's, or push-first's resolved base before one.
        if matches!(case, "required" | "stacked" | "push-first-no-pr") {
            let wt = w.worktree.display().to_string();
            let resolved = w.entry(
                &["--resolve-mode", "--worktree", &wt, "--base", &base],
                &extra,
            );
            assert_eq!(
                text(&resolved).trim(),
                format!("validate-mode={want_mode}"),
                "{case}: {}",
                stderr(&resolved)
            );
        }
        // The proof read answers required CI pending with the event that
        // proves the head.
        if matches!(case, "required" | "queue-required") {
            let wt = w.worktree.display().to_string();
            let head = w.head();
            // Required CI answers before a local pass at the same tree, asked
            // for another head than the pass's so no restack proof answers.
            let proof_head = if case == "required" {
                let local = w.local(&["--fresh"], &extra);
                assert!(local.status.success(), "{}", stderr(&local));
                base.clone()
            } else {
                head.clone()
            };
            let proof = w.entry(
                &[
                    "--resolve-mode",
                    "--worktree",
                    &wt,
                    "--require-proof",
                    &proof_head,
                    "--expected-head",
                    &head,
                ],
                &extra,
            );
            assert_eq!(proof.status.code(), Some(0), "{case}: {}", stderr(&proof));
            assert_eq!(field(&text(&proof), "validation-proof"), "ci", "{case}");
            assert_eq!(
                field(&text(&proof), "ci-event"),
                if case == "required" {
                    "pull_request"
                } else {
                    "merge_group"
                },
                "{case}: {}",
                text(&proof)
            );
        }
        // Queue-only work is proved by the merge group's run.
        assert_eq!(
            field(&record, "ci-event"),
            if matches!(case, "queue-required" | "queue-absent-merge-queue") {
                "merge_group"
            } else {
                ""
            },
            "{case}: {record}"
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
        // A restack never asks the selector, so one that fails its preview
        // leaves the round to required CI.
        let selector = if restack {
            "exit 1"
        } else {
            "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then echo scoped-ran; echo 'validate: lanes=unit selection=subset'; else echo selection=subset; fi"
        };
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
fn a_local_start_asks_ci_for_an_all_or_range_subset_selection_and_scopes_a_pre_open_all() {
    // The selector previews with $SEL, recording the mode it was asked
    // for; its scoped run passes unless $SEL ends `-red`.
    let selector = "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then echo 'validate: lanes=scoped selection=subset'; [ \"$SEL\" != all-red ]; else printf '%s\\n' \"$DEV_VALIDATE_MODE\" > \"$MODE_FILE\"; if [ \"$SEL\" = failed ]; then echo 'selector: unavailable' >&2; exit 1; fi; echo \"selection=${SEL%-red}\"; fi";
    // (requested, selection, world, classifier fixture, order) and the
    // record's (mode, scoped, ci-fallback, verdict). The fixture `render`
    // answers that class; `queue` queue-only work; `branch-queue` queue-only
    // work on the branch whole and not in the round.
    for (requested, sel, world, fixture, order, want) in [
        (
            "full",
            "all",
            "required",
            "",
            "review-first",
            ("ci", "true", "", "pending"),
        ),
        (
            "full",
            "subset",
            "required",
            "",
            "review-first",
            ("full", "", "", "pass"),
        ),
        (
            "range",
            "subset",
            "required",
            "",
            "review-first",
            ("ci", "true", "", "pending"),
        ),
        (
            "full",
            "all",
            "pr-not-open",
            "",
            "review-first",
            ("full", "true", "pr-not-open", "pass"),
        ),
        (
            "full",
            "all-red",
            "pr-not-open",
            "",
            "review-first",
            ("full", "true", "pr-not-open", "FAILING"),
        ),
        (
            "full",
            "all",
            "push-first-no-pr",
            "render",
            "push-first",
            ("full", "true", "class-uncovered", "pass"),
        ),
        (
            "full",
            "all",
            "required",
            "render",
            "review-first",
            ("full", "", "class-uncovered", "pass"),
        ),
        (
            "full",
            "failed",
            "required",
            "",
            "review-first",
            ("full", "", "", "pass"),
        ),
        (
            "full",
            "subset",
            "push-first-no-pr",
            "",
            "push-first",
            ("ci", "true", "", "pending"),
        ),
        (
            "ci",
            "unknown",
            "push-first-no-pr",
            "queue",
            "push-first",
            ("range", "", "selection-unread", "pass"),
        ),
        (
            "range",
            "subset",
            "push-first-no-pr-no-queue",
            "branch-queue",
            "push-first",
            ("range", "", "class-uncovered", "pass"),
        ),
    ] {
        let case = format!("{requested} {sel} {world} {fixture} {order}");
        let w = World::new();
        if fixture == "branch-queue" {
            w.commit("early.rs");
        }
        let base = w.head();
        w.commit("source.rs");
        let (path, replies, log) = ci_world(&w, world);
        let mode_file = w.root.join("preview-mode").display().to_string();
        let scope = support::fixtures()
            .join("change-scope-fixture/harness-only")
            .display()
            .to_string();
        let mut extra = vec![
            ("PATH", path.as_str()),
            ("GH_FAKE_REPLIES", replies.as_str()),
            ("GH_FAKE_LOG", log.as_str()),
            ("GH_REPO", "o/r"),
            ("ORCH_DELIVERY", "pr"),
            ("ORCH_PR_ORDER", order),
            ("DEV_VALIDATE_CI_CONTEXT", "CI"),
            ("DEV_VALIDATE_RANGE_CMD", "echo range"),
            ("DEV_VALIDATE_SELECTION_CMD", selector),
            ("SEL", sel),
            ("MODE_FILE", mode_file.as_str()),
        ];
        match fixture {
            "render" => extra.extend([
                ("CHANGE_SCOPE_PATHS_CLI", scope.as_str()),
                ("CHANGE_SCOPE_CLASS", "render"),
            ]),
            "queue" => extra.extend([
                ("CHANGE_SCOPE_PATHS_CLI", scope.as_str()),
                ("CHANGE_SCOPE_CLASS", "standard"),
                ("CHANGE_SCOPE_QUEUE_ONLY", "true"),
            ]),
            "branch-queue" => extra.extend([
                ("CHANGE_SCOPE_PATHS_CLI", scope.as_str()),
                ("CHANGE_SCOPE_CLASS", "standard"),
                ("CHANGE_SCOPE_QUEUE_BASE", "origin/main"),
            ]),
            _ => {}
        }
        let mut args = vec![];
        if requested != "full" {
            args.extend(["--validate-mode", requested, "--base", base.as_str()]);
        }
        let out = w.local(&args, &extra);
        let dir = directory(&out);
        let record = read_record(&w, &dir);
        let got = (
            field(&record, "validate-mode"),
            field(&record, "scoped"),
            field(&record, "ci-fallback"),
            field(&record, "verdict"),
        );
        assert_eq!(
            (
                got.0.as_str(),
                got.1.as_str(),
                got.2.as_str(),
                got.3.as_str()
            ),
            want,
            "{case}: {record} {}",
            stderr(&out)
        );
        // A run whose log reports no selection reads the preview's from its
        // start record.
        if requested == "full" && sel == "subset" && want.0 == "full" {
            assert_eq!(field(&record, "selection"), "subset", "{case}: {record}");
        }
        // The preview is asked for the requested mode.
        assert_eq!(
            fs::read_to_string(&mode_file).unwrap().trim(),
            requested,
            "{case}"
        );
        // One CI admission per start reads the base's rules once.
        let reads = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter(|l| l.contains("/rules/branches/"))
            .count();
        assert!(reads <= 1, "{case}: {reads} rule reads");
        if sel == "failed" {
            assert!(
                run_file(&dir, "class.log").contains("selector: unavailable"),
                "{case}: {}",
                run_file(&dir, "class.log")
            );
        }
        // A read-only resolution answers the mode the start ran.
        if requested == "range" {
            let wt = w.worktree.display().to_string();
            let resolved = w.entry(
                &["--resolve-mode", "--worktree", &wt, "--base", &base],
                &extra,
            );
            assert_eq!(
                text(&resolved).trim(),
                format!("validate-mode={}", want.0),
                "{case}: {}",
                stderr(&resolved)
            );
        }
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

/// An end notice whose program died after its append may have landed:
/// marked final there, one that never landed would be lost. The stage stays
/// owed, and the next walk's replay under the run's key appends nothing and
/// reads the repeat as sent.
#[test]
fn an_end_notice_killed_after_its_append_stays_owed_and_the_next_walk_marks_it_sent_once() {
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
    let (_, real) = w
        .env()
        .into_iter()
        .find(|(key, _)| key == "LANE_MAIL_CLI")
        .unwrap();
    let mark = w.root.join("kill-after");
    fs::write(&mark, "").unwrap();
    let wrapper = w.root.join("lane-mail-killed");
    support::write_executable(
        &wrapper,
        format!(
            "#!/bin/sh\n'{real}' \"$@\"\nrc=$?\nif [ -e '{mark}' ]; then rm -f '{mark}'; kill -KILL $$; fi\nexit $rc\n",
            mark = mark.display()
        ),
    );
    let cli = [("LANE_MAIL_CLI", wrapper.to_str().unwrap())];
    let inbox = w
        .worktree
        .join("tmp/lane-mail")
        .join(ITEM_ID)
        .join("to-lane.jsonl");
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &cli));
    assert!(!mark.exists(), "the send was killed after its append");
    assert_eq!(w.stage(&dir)["notice"]["owner"], "owed");
    assert_eq!(fs::read_to_string(&inbox).unwrap().lines().count(), 1);
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &cli));
    assert_eq!(w.stage(&dir)["notice"]["owner"], "sent");
    assert_eq!(fs::read_to_string(&inbox).unwrap().lines().count(), 1);
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
    // A run the bound ended answers the next start of its command: the start
    // records it, runs nothing and ends no-verdict.
    let w = World::new();
    w.commit("source.rs");
    let bound = [
        ("DEV_VALIDATE_CMD", "sleep 30"),
        ("DEV_VALIDATE_TIMEOUT_SECS", "1"),
        ("DEV_VALIDATE_FINDING_PREFIX", "FINDING:"),
    ];
    let first = w.local(&[], &bound);
    assert_eq!(
        field(text(&first).lines().last().unwrap(), "validate"),
        "no-verdict",
        "{}",
        text(&first)
    );
    let first = directory(&first);
    let out = w.local(&[], &bound);
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    let dir = directory(&out);
    assert!(
        run_file(&dir, "start").contains(&format!("\nbound-run={first}\n")),
        "{}",
        run_file(&dir, "start")
    );
    assert!(
        run_file(&dir, "log").starts_with(&format!("runner=none bound-run={first}:")),
        "{}",
        run_file(&dir, "log")
    );
    assert_eq!(
        field(text(&out).lines().last().unwrap(), "validate"),
        "no-verdict"
    );
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
    assert!(run_file(&dir, "log").contains("fallback-command"));
    let fallback = |out: &Output| {
        field(
            text(out).lines().next().unwrap_or_default(),
            "class-fallback",
        )
    };
    assert_eq!(fallback(&out), "classifier-absent", "{}", text(&out));
    // harness-ci installed without the change-scope package it reads exits
    // non-zero.
    let layout = w.root.join("layout");
    fs::create_dir_all(layout.join("harness-ci")).unwrap();
    fs::create_dir_all(layout.join("change-scope/scripts")).unwrap();
    let scripts = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../harness-ci/scripts");
    assert!(
        program("cp")
            .args(["-R"])
            .arg(&scripts)
            .arg(layout.join("harness-ci"))
            .status()
            .unwrap()
            .success()
    );
    let partial = layout.join("change-scope/scripts/harness-only");
    let out = w.local(
        &["--fresh"],
        &[
            ("DEV_VALIDATE_CMD", "echo fallback-command"),
            ("CHANGE_SCOPE_PATHS_CLI", partial.to_str().unwrap()),
        ],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(
        fallback(&out).starts_with("classifier-exit-"),
        "{}",
        text(&out)
    );
    // An index the snapshot cannot copy is no snapshot.
    {
        use std::os::unix::fs::PermissionsExt;
        let index = w.worktree.join(".git/index");
        let mode = fs::metadata(&index).unwrap().permissions();
        fs::set_permissions(&index, fs::Permissions::from_mode(0o000)).unwrap();
        let out = w.local(
            &["--fresh"],
            &[("DEV_VALIDATE_CMD", "echo fallback-command")],
        );
        fs::set_permissions(&index, mode).unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
        assert_eq!(fallback(&out), "worktree-unrecorded", "{}", text(&out));
    }
    // A worktree with no commit cannot be snapshotted.
    let unborn = w.root.join("unborn");
    fs::create_dir(&unborn).unwrap();
    git(&unborn, &["init", "-q"]);
    let unborn_text = unborn.display().to_string();
    let out = w.entry(
        &["--worktree", &unborn_text, "--foreground", "--poll", "1"],
        &[("DEV_VALIDATE_CMD", "echo fallback-command")],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(fallback(&out), "worktree-unrecorded", "{}", text(&out));
    // A worktree outside any repository has no base branch to read.
    let plain = w.root.join("plain");
    fs::create_dir(&plain).unwrap();
    let plain_text = plain.display().to_string();
    let out = w.entry(
        &["--worktree", &plain_text, "--foreground", "--poll", "1"],
        &[("DEV_VALIDATE_CMD", "echo fallback-command")],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(fallback(&out), "base-unresolved", "{}", text(&out));
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
    // A base whose ancestry git cannot read, the history between it and HEAD
    // missing an object, is no answer and never an orphaned base.
    let w = World::new();
    let base = w.head();
    let middle = w.commit("middle.rs");
    w.commit("top.rs");
    fs::remove_file(
        w.worktree
            .join(".git/objects")
            .join(&middle[..2])
            .join(&middle[2..]),
    )
    .unwrap();
    let out = w.local(
        &["--validate-mode", "range", "--base", &base],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    );
    assert_eq!(out.status.code(), Some(2), "{}", text(&out));
    assert!(
        stderr(&out).contains("dev-validate-run: ancestry-unreadable"),
        "{}",
        stderr(&out)
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
    // A released run directory's records: the start and the runner record before
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
    // A runner record that names no runner a stop reads refuses.
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
    // A released run directory's start and runner records, its child never run:
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

fn epoch_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn kill_group(pid_file: &Path) {
    if let Ok(pid) = fs::read_to_string(pid_file) {
        let _ = program("kill")
            .args(["-KILL", "--", &format!("-{}", pid.trim())])
            .status();
    }
}

#[test]
fn a_stop_recorded_before_the_executors_sentinel_closes_the_stage_stopped() {
    let w = World::new();
    let started = ok(&w.start(&[], &[("DEV_VALIDATE_CMD", "sleep 60")]));
    let dir = started["run_dir"].as_str().unwrap().to_owned();
    let pid_file = Path::new(&dir).join("pid");
    until(|| {
        fs::read_to_string(Path::new(&dir).join("command"))
            .unwrap_or_default()
            .contains("\"start\":\"")
    });
    // The job dies before its own close, the command still running.
    let job = w.stage(&dir)["job"]["pid"].as_u64().unwrap().to_string();
    assert!(
        program("kill")
            .args(["-KILL", &job])
            .status()
            .unwrap()
            .success()
    );
    until(|| {
        !program("kill")
            .args(["-0", &job])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
    });
    // The stop's record first, as `validate stop` writes it before any
    // signal; then the sentinel the executor writes for the TERM-ended
    // command; then the round's reconcile.
    let mut state = w.state();
    for stage in state["stages"].as_array_mut().unwrap() {
        if stage["run_dir"] == dir.as_str() {
            stage["stop"] = json!({"at": epoch_now()});
        }
    }
    w.write_state(&state);
    kill_group(&pid_file);
    fs::write(
        Path::new(&dir).join("exit"),
        format!(
            "guard-exit=143 at={}\n",
            agent_runtime::clock::iso_utc(epoch_now())
        ),
    )
    .unwrap();
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    let stage = w.stage(&dir);
    assert_eq!(stage["outcome"], "stopped", "{stage}");
}

#[test]
fn a_stop_of_an_ad_hoc_run_with_no_state_directory_ends_its_command() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    let absent = w.root.join("no-state").display().to_string();
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
        &absent,
        "validate",
        "entry",
        "--worktree",
        &wt,
        "--foreground",
        "--poll",
        "1",
    ]);
    for (k, v) in w.env() {
        child.env(k, v);
    }
    child
        .env("ORCH_STATE_DIR", &absent)
        .env("DEV_VALIDATE_CMD", command)
        .current_dir(&w.worktree)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let mut child = Owned(child.spawn().unwrap());
    until(|| ready.exists());
    let mut stop = support::isolated();
    stop.args([
        "--state-dir",
        &absent,
        "validate",
        "entry",
        "--stop",
        "--worktree",
        &wt,
    ]);
    for (k, v) in w.env() {
        stop.env(k, v);
    }
    let out = stop
        .env("ORCH_STATE_DIR", &absent)
        .current_dir(&w.worktree)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(text(&out), "state=stopped units=0 groups=1");
    child.0.wait().unwrap();
    assert!(!Path::new(&absent).exists());
}

/// A child of this test under an argv of the row's choosing, its pid written
/// by itself, ended with its group when the row ends.
fn bare_child(dir: &Path, argv_tail: &[&str]) -> (Group, String) {
    let pid_file = dir.join("pid");
    let _ = fs::remove_file(&pid_file);
    let group = Group(pid_file.clone());
    let mut args = vec![
        "-f".to_owned(),
        "sh".to_owned(),
        "-c".to_owned(),
        "echo $$ > \"$1\"; shift; exec perl -e 'sleep 60' -- \"$@\"".to_owned(),
        "child".to_owned(),
        pid_file.display().to_string(),
    ];
    args.extend(argv_tail.iter().map(|a| (*a).to_owned()));
    assert!(program("setsid").args(&args).status().unwrap().success());
    until(|| fs::read_to_string(&pid_file).is_ok_and(|p| !p.trim().is_empty()));
    let pid = fs::read_to_string(&pid_file).unwrap().trim().to_owned();
    (group, pid)
}

#[test]
fn a_bare_pid_is_the_run_only_under_its_own_childs_whole_argv() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    let dir = w.worktree.join("tmp/dev-validate-released");
    fs::create_dir_all(&dir).unwrap();
    let run_dir = dir.display().to_string();
    fs::write(
        dir.join("start"),
        format!(
            "worktree={wt}\ntimeout-bin=timeout\nstart={}\ntimeout-secs=3600\npoll-secs=30\ncap-secs=3640\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead={}\n",
            epoch_now(),
            w.head()
        ),
    )
    .unwrap();
    fs::write(
        dir.join("runner"),
        "runner=setsid\nline=runner=setsid reason=no-linger\n",
    )
    .unwrap();
    let live = |extra: &[(&str, &str)]| w.entry(&["--live", "--worktree", &wt], extra);
    let other_run = w
        .worktree
        .join("tmp/dev-validate-other")
        .display()
        .to_string();
    for tail in [
        // Another run's child: the run directory is not this one.
        vec!["planted", "--child", "--run-dir", other_run.as_str()],
        // This run directory, but no child's words before it.
        vec!["planted", run_dir.as_str()],
    ] {
        let (_group, pid) = bare_child(&dir, &tail);
        assert_eq!(
            live(&[]).status.code(),
            Some(1),
            "{tail:?}: {}",
            text(&live(&[]))
        );
        let out = w.entry(&["--stop", "--worktree", &wt], &[]);
        assert_eq!(text(&out), "state=stopped units=0 groups=0", "{tail:?}");
        assert!(
            program("kill")
                .args(["-0", &pid])
                .status()
                .unwrap()
                .success(),
            "{tail:?}: the process runs on"
        );
        fs::remove_file(dir.join("stop")).unwrap();
        kill_group(&dir.join("pid"));
    }
    // A live child whose argv cannot be read is no other process: it is the
    // run.
    use std::os::unix::fs::PermissionsExt;
    let blind = w.root.join("ps-refuses");
    fs::create_dir_all(&blind).unwrap();
    fs::write(blind.join("ps"), "#!/bin/bash\nexit 1\n").unwrap();
    fs::set_permissions(blind.join("ps"), fs::Permissions::from_mode(0o755)).unwrap();
    let (_group, pid) = bare_child(&dir, &["planted", run_dir.as_str()]);
    let path = support::tool_path(&[&blind]);
    let out = live(&[("PATH", &path)]);
    assert_eq!(text(&out), format!("run-dir={run_dir} pid={pid}"));
    kill_group(&dir.join("pid"));
    // The run's own child that leads no group: no group is the run's, so the
    // stop signals nothing and the process runs on.
    let leader = dir.join("leader");
    let _leader_group = Group(leader.clone());
    let _ = fs::remove_file(dir.join("pid"));
    // The inner shell is not the script's last command, so the outer shell
    // forks it rather than replacing itself with it.
    let script = "echo $$ > \"$1\"; shift; sh -c 'echo $$ > \"$1\"; shift; exec perl -e \"sleep 60\" -- \"$@\"' inner \"$@\"; wait";
    assert!(
        program("setsid")
            .args(["-f", "sh", "-c", script, "leader"])
            .arg(&leader)
            .arg(dir.join("pid"))
            .args(["planted", "--child", "--run-dir", &run_dir])
            .status()
            .unwrap()
            .success()
    );
    until(|| fs::read_to_string(dir.join("pid")).is_ok_and(|p| !p.trim().is_empty()));
    let pid = fs::read_to_string(dir.join("pid"))
        .unwrap()
        .trim()
        .to_owned();
    let out = w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(text(&out), "state=stopped units=0 groups=0");
    assert!(
        program("kill")
            .args(["-0", &pid])
            .status()
            .unwrap()
            .success(),
        "the process runs on"
    );
    fs::remove_file(dir.join("stop")).unwrap();
    kill_group(&leader);
    // The run's own child under a long argv, read whole under an exported
    // terminal width.
    let (_group, pid) = bare_child(&dir, &["planted", "--child", "--run-dir", &run_dir]);
    assert!(run_dir.len() > 80);
    let out = live(&[("COLUMNS", "80")]);
    assert_eq!(text(&out), format!("run-dir={run_dir} pid={pid}"));
}

#[test]
fn a_unit_run_is_stopped_by_its_recorded_unit_name_and_a_refused_stop_fails() {
    let (one, two) = (World::new(), World::new());
    let (path, _) = manager(&one);
    let manager_dir = one.root.join("manager").display().to_string();
    let extra = [
        ("PATH", path.as_str()),
        ("VALIDATE_MANAGER_DIR", manager_dir.as_str()),
    ];
    // Two runs, one per worktree, under one manager, each command held on
    // its own fifo.
    let mut dirs = Vec::new();
    for w in [&one, &two] {
        let fifo = w.root.join("hold");
        assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
        let command = format!("exec 9<> '{}'; read -r -t 30 -u 9 answer", fifo.display());
        let mut env = extra.to_vec();
        env.push(("DEV_VALIDATE_CMD", command.as_str()));
        dirs.push(
            ok(&w.start(&[], &env))["run_dir"]
                .as_str()
                .unwrap()
                .to_owned(),
        );
    }
    for dir in &dirs {
        until(|| Path::new(dir).join("command").exists());
    }
    let unit = |dir: &str| -> String {
        fs::read_to_string(Path::new(dir).join("runner"))
            .unwrap()
            .lines()
            .find_map(|l| l.strip_prefix("unit=").map(str::to_owned))
            .unwrap()
    };
    let unit_live = |dir: &str| {
        program("systemctl")
            .args([
                "--user",
                "show",
                "-p",
                "LoadState,ActiveState",
                "--value",
                "--",
            ])
            .arg(format!("{}.service", unit(dir)))
            .env("PATH", &path)
            .env("VALIDATE_MANAGER_DIR", &manager_dir)
            .output()
            .unwrap()
            .stdout
            == b"loaded\nactive\n"
    };
    // The stop ends this worktree's unit by its recorded name, and only it.
    let wt = one.worktree.display().to_string();
    let out = one.entry(&["--stop", "--worktree", &wt], &extra);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(text(&out), "state=stopped units=1 groups=0");
    let stops = fs::read_to_string(Path::new(&manager_dir).join("stops")).unwrap();
    assert_eq!(stops.lines().collect::<Vec<_>>(), [unit(&dirs[0])]);
    until(|| !unit_live(&dirs[0]));
    assert!(unit_live(&dirs[1]));
    assert_eq!(one.wait_closed(&dirs[0])["outcome"], "stopped");
    // A manager that refuses the stop fails it.
    let wt = two.worktree.display().to_string();
    let mut refusing = extra.to_vec();
    refusing.push(("VALIDATE_STOP_ANSWER", "refused"));
    let out = two.entry(&["--stop", "--worktree", &wt], &refusing);
    assert_eq!(out.status.code(), Some(1), "{}", text(&out));
    assert!(stderr(&out).contains("stop-failed"), "{}", stderr(&out));
    assert_eq!(two.wait_closed(&dirs[1])["outcome"], "stopped");
    // An ad hoc run's unit the manager no longer has ended on its own: the
    // stop that finds it gone stops nothing and fails nothing.
    let three = World::new();
    let fifo = three.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let command = format!("exec 9<> '{}'; read -r -t 30 -u 9 answer", fifo.display());
    let mut env = extra.to_vec();
    env.push(("DEV_VALIDATE_CMD", command.as_str()));
    let wt = three.worktree.display().to_string();
    let runs = three.worktree.join("tmp");
    std::thread::scope(|scope| {
        let start = scope.spawn(|| three.entry(&["--worktree", &wt, "--poll", "1"], &env));
        let held = || {
            fs::read_dir(&runs)
                .into_iter()
                .flatten()
                .flatten()
                .map(|e| e.path())
                .find(|p| p.join("command").exists())
        };
        until(|| held().is_some());
        let dir = held().unwrap().display().to_string();
        let pid_file = Path::new(&manager_dir).join(format!("{}.pid", unit(&dir)));
        let _group = Group(pid_file.clone());
        until(|| fs::read_to_string(&pid_file).is_ok_and(|p| p.ends_with('\n')));
        // The job ends, then the command group it led, so no sentinel is
        // written.
        let command: Value =
            serde_json::from_slice(&fs::read(Path::new(&dir).join("command")).unwrap()).unwrap();
        kill_group(&pid_file);
        let _ = program("kill")
            .args(["-KILL", "--", &format!("-{}", command["pid"])])
            .status();
        fs::remove_file(&pid_file).unwrap();
        assert!(!Path::new(&dir).join("exit").exists());
        let out = three.entry(&["--stop", "--worktree", &wt], &extra);
        assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
        assert_eq!(text(&out), "state=stopped units=0 groups=0");
        let _ = start.join();
    });
}
