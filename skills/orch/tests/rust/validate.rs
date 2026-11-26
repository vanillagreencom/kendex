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
        support::install_orch_scripts(&worktree);
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
        let item = support::item_record(&state, ITEM_ID);
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
            ("CHANGE_SCOPE_PATHS_CLI".into(), scope.display().to_string()),
            ("DEV_VALIDATE_CMD".into(), "echo full".into()),
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
        self.run_without(args, extra, &[])
    }

    /// `run` with each key of `unset` left out of the child's environment,
    /// unless `extra` names it.
    fn run_without(&self, args: &[&str], extra: &[(&str, &str)], unset: &[&str]) -> Output {
        let mut command = support::isolated();
        command
            .arg("--state-dir")
            .arg(&self.state)
            .args(args)
            .current_dir(&self.worktree);
        for (k, v) in self.env() {
            command.env(k, v);
        }
        for k in unset {
            command.env_remove(k);
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
            assert!(
                Instant::now() < deadline,
                "the run never closed: {stage}\n{}",
                run_files(run_dir)
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// The stage once its notice is marked: the detached job's last write
    /// (the close, the send, then the mark), so a row that started a job
    /// ends here and no job writes into a world already removed.
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
                "the notice was never marked: {stage}\n{}",
                run_files(run_dir)
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
/// The entry's keyed line: the last on stderr, below the refusal's text.
fn keyed(out: &Output) -> String {
    stderr(out)
        .trim_end()
        .lines()
        .last()
        .unwrap_or_default()
        .to_owned()
}
fn refusal(out: &Output) -> String {
    assert_eq!(out.status.code(), Some(1), "{}", stderr(out));
    reply(out)["refusal"]["key"].as_str().unwrap().into()
}
fn run_file(dir: &str, name: &str) -> String {
    fs::read_to_string(Path::new(dir).join(name)).unwrap_or_default()
}
/// Every file of a run that a wait gave up on: which of the job's writes
/// stand (`execution`, `exit`) and what its standard error (`job.err`)
/// holds tell a job that ended before its close from one still at work.
fn run_files(dir: &str) -> String {
    let mut names: Vec<String> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
        .iter()
        .map(|name| format!("--- {name}\n{}\n", run_file(dir, name)))
        .collect()
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
        "poll_secs": 1,
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

const CHANGELOG: &str = "# Changelog\n\n## Unreleased\n\n- first\n";
const SOURCE: (&str, &str) = ("src.rs", "fn main() {}\n");

impl World {
    /// `files`, each a path and its text, written and committed: the new head.
    fn commit_files(&self, files: &[(&str, &str)]) -> String {
        for (name, text) in files {
            fs::write(self.worktree.join(name), text).unwrap();
            git(&self.worktree, &["add", name]);
        }
        git(&self.worktree, &["commit", "-q", "-m", "change"]);
        self.head()
    }

    /// A base that gained `upstream` after the fork point `fork`, and the
    /// branch restacked onto it as `resolved` resolves it: the new base.
    fn restack_onto(
        &self,
        fork: &str,
        upstream: &[(&str, &str)],
        resolved: &[(&str, &str)],
    ) -> String {
        git(&self.worktree, &["checkout", "-q", "-b", "upstream", fork]);
        let base = self.commit_files(upstream);
        git(&self.worktree, &["checkout", "-q", "-B", "main", &base]);
        self.commit_files(resolved);
        base
    }

    /// The real changelog classifier at its install path.
    fn install_classifier(&self) {
        let guards = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../commit-guards")
            .canonicalize()
            .unwrap();
        std::os::unix::fs::symlink(guards, self.worktree.join(".agents/skills/commit-guards"))
            .unwrap();
    }

    /// `validate entry --restack-check` against `base`: its exit and its
    /// answer's words, less the run's directory and heads.
    fn restack_check(&self, base: &str) -> (Option<i32>, String) {
        let wt = self.worktree.display().to_string();
        let out = self.entry(&["--restack-check", "--worktree", &wt, "--base", base], &[]);
        let words: Vec<String> = text(&out)
            .split(' ')
            .filter(|w| {
                !["run-dir=", "validated-head=", "head="]
                    .iter()
                    .any(|k| w.starts_with(k))
            })
            .map(str::to_owned)
            .collect();
        (out.status.code(), words.join(" "))
    }
}

/// A restack skips its retest only where the validated tree merged onto the
/// new base is the restacked head, or differs from it only in changelog
/// conflicts whose resolution keeps every line outside the entries; every
/// other reading, the classifier's own absence among them, owes the retest.
/// The real check and the real classifier, over branches with one passing
/// full run.
#[test]
fn a_restack_check_skips_only_a_clean_or_changelog_only_merge_of_the_passed_tree() {
    let retest = |cause: &str| (Some(1), format!("restack=retest cause={cause}"));
    let skip = |condition: &str, paths: &str| {
        (
            Some(0),
            format!("restack=skip condition={condition} paths={paths}"),
        )
    };
    let passed = |w: &World| {
        let out = w.local(&[], &[]);
        assert!(out.status.success(), "{}", stderr(&out));
    };

    // A clean merge.
    let w = World::new();
    let fork = w.commit_files(&[("CHANGELOG.md", CHANGELOG)]);
    w.commit_files(&[SOURCE]);
    assert_eq!(w.restack_check("main"), retest("no-passing-run"));
    passed(&w);
    let base = w.restack_onto(&fork, &[("upstream.txt", "upstream\n")], &[SOURCE]);
    assert_eq!(w.restack_check(&base), skip("no-conflict", "none"));
    assert_eq!(w.restack_check("absent-ref"), retest("base-unreadable"));
    git(&w.worktree, &["symbolic-ref", "HEAD", "refs/heads/unborn"]);
    assert_eq!(w.restack_check(&base), retest("head-unreadable"));
    git(&w.worktree, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    w.commit_files(&[("upstream.txt", "edited after the restack\n")]);
    assert_eq!(
        w.restack_check(&base),
        retest("path-unconflicted path=upstream.txt")
    );
    let red = w.local(&["--fresh"], &[("DEV_VALIDATE_CMD", "false")]);
    assert_eq!(red.status.code(), Some(1), "{}", stderr(&red));
    assert_eq!(w.restack_check(&base), retest("newer-red"));

    // A changelog conflict, each side's entry kept.
    let w = World::new();
    let fork = w.commit_files(&[("CHANGELOG.md", CHANGELOG)]);
    w.commit_files(&[SOURCE, ("CHANGELOG.md", &format!("{CHANGELOG}- branch\n"))]);
    passed(&w);
    let base = w.restack_onto(
        &fork,
        &[("CHANGELOG.md", &format!("{CHANGELOG}- base\n"))],
        &[
            SOURCE,
            ("CHANGELOG.md", &format!("{CHANGELOG}- base\n- branch\n")),
        ],
    );
    assert_eq!(w.restack_check(&base), retest("classifier-missing"));
    w.install_classifier();
    assert_eq!(w.restack_check(&base), skip("version-only", "CHANGELOG.md"));
    w.commit_files(&[(
        "CHANGELOG.md",
        &format!("{CHANGELOG}- base\n- branch\n\nA line outside the entries.\n"),
    )]);
    assert_eq!(w.restack_check(&base), retest("hunk path=CHANGELOG.md"));

    // A code conflict.
    let w = World::new();
    let fork = w.commit_files(&[("code.txt", "one\ntwo\nthree\n")]);
    w.commit_files(&[("code.txt", "one\nbranch\nthree\n")]);
    passed(&w);
    let base = w.restack_onto(
        &fork,
        &[("code.txt", "one\nbase\nthree\n")],
        &[("code.txt", "one\nbase and branch\nthree\n")],
    );
    w.install_classifier();
    assert_eq!(w.restack_check(&base), retest("unclassified path=code.txt"));
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
    assert!(first.starts_with(&format!("state=started run-dir={dir} log={dir}/log sentinel={dir}/exit quiet-secs=660 poll-secs=1 memory-bound=")),"{first}");
    let bound = field(&first, "memory-bound");
    assert!(
        first.contains(&format!(" memory-bound={bound} rule=host class=")),
        "{first}"
    );
    // The quiet time the executor ends a stalled run at and the memory it
    // holds the run's tree to are the start record's, and the run has no
    // other limit.
    let start = run_file(&dir, "start");
    assert_eq!(field(&start, "quiet-secs"), "660", "{start}");
    assert_eq!(field(&start, "poll-secs"), "1", "{start}");
    assert_eq!(field(&start, "memory-bound"), bound, "{start}");
    assert_eq!(field(&start, "rule"), "host", "{start}");
    for gone in ["timeout-bin", "timeout-secs", "cap-secs", "quiet-clock"] {
        assert_eq!(field(&start, gone), "", "{start}");
    }
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
        // A line of another form after the selection is no candidate: the
        // entry's own refusal or notice opens `validate:` too.
        ("validate:  lanes=one selection=all", "before", "all"),
        ("validate: run-live run-dir=/r pid=1", "before", "all"),
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
        keyed(&refused).starts_with("validate: validate-unreadable read=record-unreadable"),
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
fn a_full_start_ignores_a_base_and_refuses_unused_options() {
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
    // A wait reads the start second and the poll its start recorded; a
    // start that names none of one is no run.
    let waited = |name: &str, start: &str| {
        let dir = records.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("start"), start).unwrap();
        dir.display().to_string()
    };
    let no_second = waited("no-second", "validate-mode=full\npoll-secs=1\n");
    let no_poll = waited("no-poll", "validate-mode=full\nstart=1\n");
    // An I/O cause is the reader's own words: the system's, read here.
    let absent = fs::canonicalize("/absent-u8z2p").unwrap_err().to_string();
    for (args, want, cause) in [
        (
            vec!["--wait", "--stop"],
            "validate-unreadable read=mode-conflict",
            None,
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--attached"],
            "validate-unreadable read=option-unused",
            None,
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--fresh"],
            "validate-unreadable read=option-unused",
            None,
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--reproduce"],
            "validate-unreadable read=option-unused",
            None,
        ),
        (
            vec!["--worktree", &wt, "--restack"],
            "validate-unreadable read=option-unused cause=--restack",
            None,
        ),
        (
            vec!["--stop", "--worktree", &wt, "--run-dir", &empty],
            "validate-unreadable read=option-unused cause=--run-dir",
            None,
        ),
        (
            vec!["--worktree", &wt, "--attached", "--budget", "5"],
            "validate-unreadable read=option-unused cause=--budget",
            None,
        ),
        (
            vec!["--stop", "--worktree", &wt, "--poll", "1"],
            "validate-unreadable read=option-unused cause=--poll",
            None,
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--poll", "1"],
            "validate-unreadable read=option-unused cause=--poll",
            None,
        ),
        (
            vec!["--stop", "--worktree", &wt, "--validate-mode", "range"],
            "validate-unreadable read=option-unused cause=--validate-mode",
            None,
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--validate-mode", "range"],
            "validate-unreadable read=option-unused cause=--validate-mode",
            None,
        ),
        (
            vec![
                "--resolve-mode",
                "--worktree",
                &wt,
                "--validate-mode",
                "range",
            ],
            "validate-unreadable read=option-unused cause=--validate-mode",
            None,
        ),
        (
            vec!["--stop", "--worktree", &wt, "--base", "HEAD"],
            "validate-unreadable read=option-unused cause=--base",
            None,
        ),
        (
            vec!["--wait", "--run-dir", &empty, "--base", "HEAD"],
            "validate-unreadable read=option-unused cause=--base",
            None,
        ),
        (
            vec!["--stop"],
            "validate-unreadable read=required cause=--worktree",
            None,
        ),
        (
            vec![],
            "validate-unreadable read=required cause=--worktree",
            None,
        ),
        (
            vec!["--resolve-mode"],
            "validate-unreadable read=required cause=--worktree",
            None,
        ),
        (
            vec!["--wait"],
            "validate-unreadable read=required cause=--run-dir",
            None,
        ),
        (
            vec!["--wait", "--run-id", "20300101T000000Z-queued"],
            "validate-unreadable read=required cause=--worktree",
            None,
        ),
        (
            vec![
                "--wait",
                "--worktree",
                &wt,
                "--run-id",
                "20300101T000000Z-queued",
                "--run-dir",
                &empty,
            ],
            "validate-unreadable read=option-unused cause=--run-dir",
            None,
        ),
        (
            vec!["--stop", "--worktree", "/absent-u8z2p"],
            "validate-unreadable read=not-directory",
            Some(absent.as_str()),
        ),
        (
            vec!["--restack-check", "--worktree", &wt],
            "validate-unreadable read=required cause=--base",
            None,
        ),
        (
            vec!["--restack-check", "--base", "HEAD"],
            "validate-unreadable read=required cause=--worktree",
            None,
        ),
        (
            vec![
                "--restack-check",
                "--worktree",
                "/absent-u8z2p",
                "--base",
                "HEAD",
            ],
            "validate-unreadable read=not-directory",
            None,
        ),
        (
            vec!["--worktree", &wt, "--validate-mode", "fast"],
            "validate-unreadable read=invalid-mode",
            None,
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
            None,
        ),
        (
            vec!["--wait", "--run-dir", &no_second, "--budget", "1"],
            "validate-unreadable read=no-run",
            None,
        ),
        (
            vec!["--wait", "--run-dir", &no_poll, "--budget", "1"],
            "validate-unreadable read=no-run cause=poll-secs",
            None,
        ),
        (
            vec!["--last-pass", "--worktree", &wt, "--fresh"],
            "validate-unreadable read=option-unused",
            None,
        ),
        (
            vec!["--record", "--run-dir", &untimed],
            "validate-unreadable read=timing-unreadable",
            None,
        ),
        (
            vec!["--record", "--run-dir", &unstarted],
            "validate-unreadable read=timing-unreadable cause=started-at",
            None,
        ),
        (
            vec!["--record", "--run-dir", &unsecond],
            "validate-unreadable read=timing-unreadable cause=seconds",
            None,
        ),
    ] {
        let out = w.entry(&args, &[]);
        let line = keyed(&out);
        assert_eq!(out.status.code(), Some(2), "{args:?}: {line}");
        // The whole line parses as `field=value` pairs after its key.
        assert_eq!(line, format!("validate: {want}"), "{args:?}");
        // A cause the line leaves out is the refusal's text above it.
        if let Some(cause) = cause {
            let text = stderr(&out);
            let above = text.trim_end().strip_suffix(&line).unwrap_or_default();
            assert!(above.contains(cause), "{args:?}: {text}");
        }
    }
    let empty_cmd = w.local(&["--fresh"], &[("DEV_VALIDATE_CMD", "")]);
    assert_eq!(empty_cmd.status.code(), Some(2));
    assert!(
        keyed(&empty_cmd).starts_with("validate: empty-validate-cmd setting=DEV_VALIDATE_CMD"),
        "{}",
        stderr(&empty_cmd)
    );
    // A validation setting outside its form refuses the start that reads it
    // and no verb that never reads it.
    {
        let (key, value) = ("ORCH_DELIVERY", "bogus");
        let args = ["--validate-mode", "ci", "--base", base.as_str()];
        let start = w.local(&args, &[(key, value)]);
        assert_eq!(start.status.code(), Some(2), "{key}: {}", text(&start));
        assert!(
            stderr(&start).contains(&format!(
                "validate: setting-invalid key={key} value={value}"
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

/// Whether the executor has recorded its command's identity, pid and start,
/// the record a stop signals and a reconcile reads the command by. A row
/// that stops the run or ends its executor waits on this: the command's own
/// marker and the record's first, pid-only write can both land before it.
fn command_identity_recorded(run_dir: &Path) -> bool {
    fs::read(run_dir.join("command"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .is_some_and(|record| record["start"].is_string())
}

/// The run under `worktree` whose executor has recorded its command's
/// identity.
fn recorded_run(worktree: &Path) -> Option<PathBuf> {
    fs::read_dir(worktree.join("tmp"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .find(|dir| command_identity_recorded(dir))
}

fn executor_dir(w: &World, command: &str, quiet: u64) -> PathBuf {
    let dir = w.worktree.join("tmp/dev-validate-executor");
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join("start"),format!("worktree={}\nstart=1769700000\nquiet-secs={quiet}\npoll-secs=1\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead=H\ntree=T\n",w.worktree.display())).unwrap();
    fs::write(
        dir.join("runner"),
        "runner=attached\nline=runner=attached\n",
    )
    .unwrap();
    fs::write(dir.join("cmd"), command).unwrap();
    fs::write(dir.join("paths"), "a.txt\n").unwrap();
    dir
}

/// Stops a process a row's command started, by the identity read while it
/// ran, whatever the row's answer.
struct Started(Option<agent_runtime::process::Identity>);
impl Drop for Started {
    fn drop(&mut self) {
        if let Some(id) = self.0.take() {
            let _ = agent_runtime::process::stop_identities(&[id], Duration::from_secs(1));
        }
    }
}

/// A command tree that prints nothing, starts nothing and uses no CPU for
/// its start's quiet time is ended as stalled, a member in a session of its
/// own with it, and the wait names the step and the log's last line.
#[test]
fn a_silent_idle_command_tree_is_ended_whole_as_stalled_at_its_quiet_time() {
    use std::sync::{Arc, mpsc};
    let w = World::new();
    let fifo = w.root.join("held");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let ready = w.root.join("ready");
    let kid = w.root.join("kid");
    let command = format!(
        "exec 9<> '{}'; setsid sleep 60 & echo $! > '{}'; echo first; echo second; echo ready > '{}'; read -r -t 20 -u 9 answer; exit 77",
        fifo.display(),
        kid.display(),
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
    let kid_pid: u32 = fs::read_to_string(&kid).unwrap().trim().parse().unwrap();
    let agent_runtime::reading::Reading::Live(kid_id) = agent_runtime::process::identity(kid_pid)
    else {
        panic!("the command's own-session member is not running");
    };
    let _kid = Started(Some(kid_id.clone()));
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
    assert_eq!(field(&sentinel, "guard-exit"), "124", "{sentinel}");
    assert!(
        sentinel.ends_with(" cause=stalled quiet-secs=2 step=run last-line=second\n"),
        "{sentinel}"
    );
    assert!(!dir.join("own-exit").exists());
    // What the command printed before it stalled stays in its log.
    let log = fs::read_to_string(dir.join("log")).unwrap();
    assert!(log.contains("\nfirst\nsecond\n"), "{log}");
    let id: agent_runtime::process::Identity =
        serde_json::from_slice(&fs::read(dir.join("command")).unwrap()).unwrap();
    for id in [&id, &kid_id] {
        assert!(matches!(
            agent_runtime::process::still_runs(id),
            agent_runtime::reading::Reading::Gone
        ));
    }
    assert!(clock.elapsed() >= Duration::from_secs(2));
    let (waited, exit) = orch_runtime::validate::files::wait(&dir, 0, clock.as_ref()).unwrap();
    assert_eq!(exit, 1, "{waited}");
    assert!(
        waited.contains(" validate=FAILING cause=stalled step=run last-line=second run-dir="),
        "{waited}"
    );
}

/// A step past its expected time and a run past the selector's each warn
/// once, in the log, the run's `warning` record, the wait and the record's
/// `slow-step=`, and the run goes on; the stall names the newest step, or
/// `run` where the command named none.
#[test]
fn a_slow_step_and_a_slow_run_each_warn_once_and_a_stall_names_the_newest_step() {
    use std::sync::{Arc, mpsc};
    let tail = ": the run goes on while it makes progress; no needed check is dropped to meet the expected time";
    for (case, step_line, step) in [
        (
            "named",
            "echo 'validate-step: name=lint command=cargo clippy expected-secs=3'; ",
            "lint",
        ),
        ("unnamed", "", "run"),
    ] {
        let w = World::new();
        let fifo = w.root.join("held");
        assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
        let ready = w.root.join("ready");
        let command = format!(
            "exec 9<> '{}'; {step_line}echo checking a; : > '{}'; read -r -t 30 -u 9 w; exit 0",
            fifo.display(),
            ready.display()
        );
        let dir = executor_dir(&w, &command, 20);
        let mut start = fs::read_to_string(dir.join("start")).unwrap();
        start.push_str("expected-secs=5\n");
        fs::write(dir.join("start"), start).unwrap();
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
        for _ in 0..8 {
            clock.pass(Duration::from_secs(1));
        }
        assert!(
            !dir.join("exit").exists(),
            "{case}: a warning ended the run"
        );
        let deadline = Instant::now() + Duration::from_secs(15);
        let answer = loop {
            match received.try_recv() {
                Ok(answer) => break answer,
                Err(mpsc::TryRecvError::Disconnected) => panic!("executor ended without answer"),
                Err(mpsc::TryRecvError::Empty) => {
                    assert!(Instant::now() < deadline, "{case}: the run never stalled");
                    clock.release(Duration::from_millis(100));
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        };
        answer.unwrap();
        task.join().unwrap();
        let warnings = fs::read_to_string(dir.join("warning")).unwrap();
        let mut want = Vec::new();
        if case == "named" {
            want.push(format!(
                "validate-warning: slow step=lint command=cargo clippy expected-secs=3 elapsed-secs=4{tail}"
            ));
            want.push(format!(
                "validate-warning: slow step=lint command=cargo clippy expected-secs=5 elapsed-secs=6{tail}"
            ));
        } else {
            let command = command.split_whitespace().collect::<Vec<_>>().join(" ");
            want.push(format!(
                "validate-warning: slow step=run command={command} expected-secs=5 elapsed-secs=6{tail}"
            ));
        }
        assert_eq!(warnings.lines().collect::<Vec<_>>(), want, "{case}");
        let log = fs::read_to_string(dir.join("log")).unwrap();
        for line in &want {
            assert!(log.lines().any(|l| l == line), "{case}: {log}");
        }
        let sentinel = fs::read_to_string(dir.join("exit")).unwrap();
        assert!(
            sentinel.ends_with(&format!(
                " cause=stalled quiet-secs=20 step={step} last-line=checking a\n"
            )),
            "{case}: {sentinel}"
        );
        let (waited, _) = orch_runtime::validate::files::wait(&dir, 0, clock.as_ref()).unwrap();
        let lines: Vec<&str> = waited.lines().collect();
        assert_eq!(lines[..want.len()], want, "{case}: {waited}");
        assert!(
            lines[want.len()].contains(&format!(
                " validate=FAILING cause=stalled step={step} last-line=checking a run-dir="
            )),
            "{case}: {waited}"
        );
        let record = orch_runtime::validate::files::RunFile::read(&dir)
            .unwrap()
            .record()
            .unwrap();
        assert_eq!(field(&record, "slow-step"), step, "{case}: {record}");
    }
}

#[test]
fn a_command_that_ignores_term_is_killed_at_the_grace_after_it_stalls() {
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

/// The `progress` record counts the time a command shows no work, a line at
/// most every ten seconds, and each kind of work restarts the count: output
/// in the log, a process new at or below the leader, and CPU time; the work
/// comes a second before the planted quiet time and spares the run. The
/// command waits on a pipe the row writes, each wait bounded so a failed row
/// leaves nothing running.
#[test]
fn the_progress_record_counts_quiet_time_until_output_a_new_process_or_cpu_work_which_spares_the_run()
 {
    use std::io::Write;
    use std::sync::{Arc, mpsc};
    for (work, kind) in [
        ("echo worked", "output"),
        ("sleep 60 &", "process"),
        (
            "while times > \"$t\" && read -r u s < \"$t\" && u=${u#0m} && [ \"${u%%.*}\" -lt 2 ]; do i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done; done",
            "cpu",
        ),
    ] {
        let w = World::new();
        let fifo = w.root.join("held");
        assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
        let ready = w.root.join("ready");
        let done = w.root.join("done");
        let command = format!(
            "t='{}'; exec 9<> '{}'; : > '{}'; read -r -t 60 -u 9 w\n{work}\n: > '{}'; read -r -t 60 -u 9 w; exit 0",
            w.root.join("times").display(),
            fifo.display(),
            ready.display(),
            done.display()
        );
        let dir = executor_dir(&w, &command, 19);
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
        let lines = || {
            fs::read_to_string(dir.join("progress"))
                .unwrap()
                .lines()
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        for _ in 0..10 {
            clock.pass(Duration::from_secs(1));
        }
        let quiet: u64 = field(&lines()[1], "quiet-for").parse().unwrap();
        assert!(quiet >= 9, "{kind}: {:?}", lines());
        for _ in 0..8 {
            clock.pass(Duration::from_secs(1));
        }
        fs::OpenOptions::new()
            .write(true)
            .open(&fifo)
            .unwrap()
            .write_all(b"work\n")
            .unwrap();
        until(|| done.exists());
        clock.pass(Duration::from_secs(1));
        clock.pass(Duration::from_secs(1));
        let read = lines();
        assert_eq!(read.len(), 3, "{kind}: {read:?}");
        assert_eq!(field(&read[2], "quiet-for"), "1", "{kind}: {read:?}");
        assert!(!field(&read[2], "procs").is_empty(), "{kind}: {read:?}");
        fs::OpenOptions::new()
            .write(true)
            .open(&fifo)
            .unwrap()
            .write_all(b"end\n")
            .unwrap();
        let deadline =
            Instant::now() + Duration::from_secs(orch_runtime::validate::KILL_GRACE + 15);
        let answer = loop {
            match received.try_recv() {
                Ok(answer) => break answer,
                Err(mpsc::TryRecvError::Disconnected) => panic!("executor ended without answer"),
                Err(mpsc::TryRecvError::Empty) => {
                    assert!(
                        Instant::now() < deadline,
                        "{kind}: the executor never ended"
                    );
                    clock.release(Duration::from_millis(100));
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        };
        answer.unwrap();
        task.join().unwrap();
        assert_eq!(
            field(&fs::read_to_string(dir.join("exit")).unwrap(), "guard-exit"),
            "0"
        );
    }
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
        &agent_runtime::clock::SystemClock,
        &PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../github/scripts/lib/group-leader.sh"),
    );
    assert!(answer.is_err(), "{answer:?}");
    assert!(!dir.join("exit").exists());
    // A record with no sentinel is no verdict a return could cite as a pass.
    assert_eq!(
        field(&read_record(&w, dir.to_str().unwrap()), "verdict"),
        "unfinished"
    );
    // The foreground caller that held the run has exited with its error.
    let caller = Owned::sleep();
    let runner = format!(
        "runner=attached\npid={}\nstart={}\nline=runner=attached\n",
        caller.pid(),
        caller.start()
    );
    drop(caller);
    fs::write(dir.join("runner"), runner).unwrap();
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
    // No sentinel, and neither the command nor its caller runs, so the run
    // reads failing, never done.
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
    for (budget, want) in [(1, "running"), (10, "lost")] {
        let w = World::new();
        let dir = executor_dir(&w, "touch must-not-run", 20);
        fs::remove_file(dir.join("runner")).unwrap();
        let clock = Arc::new(support::FakeClock::new());
        let c = clock.clone();
        let d = dir.clone();
        let (sent, received) = mpsc::channel();
        let task = std::thread::spawn(move || {
            sent.send(orch_runtime::validate::files::wait(&d, budget, c.as_ref()))
                .unwrap()
        });
        clock.await_sleepers(1);
        clock.release(Duration::from_secs(budget));
        let (line, exit) = received.recv_timeout(JOB_BOUND).unwrap().unwrap();
        task.join().unwrap();
        assert_eq!(field(&line, "state"), want);
        assert_eq!(exit, if want == "running" { 3 } else { 1 });
        assert!(!w.worktree.join("must-not-run").exists());
    }
}

/// A wait on a run another seat starts holds one call from before the run's
/// directory exists: a run that starts and ends inside the budget answers
/// its verdict line alone; one that never starts ends at the budget with
/// its own `state=queued` line; one that starts late is followed only for
/// what is left of the budget; one whose admission closes with no start
/// record ends with the key of the refusal that kept it from starting, else
/// the close's word; one whose start is refused before it records the run,
/// by id or by round, ends with that refusal's key; one whose start is
/// refused `run-live` stays queued for the start that follows, as does one
/// whose refusal could not be written, which its start names; an id no
/// round admitted is refused.
#[test]
fn a_queued_wait_holds_one_call_from_before_the_start_to_the_verdict_or_its_budget() {
    use std::sync::{Arc, mpsc};
    #[derive(PartialEq)]
    enum Seat {
        Ends,
        Never,
        Late,
        Refused,
        RefusedUnrecorded,
        RefusedByRound,
        RefusalUnwritable,
        RefusedReconciled,
        RunLive,
        Reconciled,
        Unadmitted,
    }
    let rows = [
        (Seat::Ends, Ok(("done", 0))),
        (Seat::Never, Ok(("queued", 3))),
        (Seat::Late, Ok(("running", 3))),
        (
            Seat::Refused,
            Err(("run-ended-unstarted", Some("run-exists"))),
        ),
        (
            Seat::RefusedUnrecorded,
            Err(("start-refused", Some("memory-short"))),
        ),
        (
            Seat::RefusedByRound,
            Err(("start-refused", Some("memory-short"))),
        ),
        (Seat::RefusalUnwritable, Ok(("queued", 3))),
        (
            Seat::RefusedReconciled,
            Err(("run-ended-unstarted", Some("memory-short"))),
        ),
        (Seat::RunLive, Ok(("queued", 3))),
        (
            Seat::Reconciled,
            Err(("run-ended-unstarted", Some("run-dir-absent"))),
        ),
        (Seat::Unadmitted, Err(("run-unadmitted", None))),
    ];
    for (seat, want) in rows {
        let w = World::new();
        let dir = if seat == Seat::Unadmitted {
            w.worktree
                .join("tmp/dev-validate-20300101T000000Z-unadmitted")
        } else {
            let admitted = ok(&w.op(
                &json!({"op":"record-validation-admission","round_id":ROUND}),
                &[],
            ));
            PathBuf::from(admitted["report"]["run_dir"].as_str().unwrap())
        };
        let wt = w.worktree.display().to_string();
        let id = dir
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .strip_prefix("dev-validate-")
            .unwrap()
            .to_owned();
        let clock = Arc::new(support::FakeClock::new());
        let (c, d, state) = (clock.clone(), dir.clone(), w.state.clone());
        let (sent, received) = mpsc::channel();
        let task = std::thread::spawn(move || {
            sent.send(orch_runtime::validate::files::wait_queued(
                &state,
                &d,
                60,
                30,
                c.as_ref(),
            ))
            .unwrap()
        });
        // The run's holder, alive through the window of the late start.
        let mut holder = None;
        if seat != Seat::Unadmitted {
            clock.await_sleepers(1);
        }
        match seat {
            Seat::Ends => {
                // The seat's start lands whole, its command already ended.
                let staged = executor_dir(&w, "true", 20);
                fs::write(
                    staged.join("exit"),
                    "guard-exit=0 at=2026-01-30T15:20:00Z\n",
                )
                .unwrap();
                fs::write(
                    staged.join("timing"),
                    "started-at=2026-01-30T15:20:00Z\nended-at=2026-01-30T15:20:00Z\nseconds=0\n",
                )
                .unwrap();
                fs::rename(&staged, &dir).unwrap();
                clock.release(Duration::from_secs(30));
            }
            Seat::Never => {
                clock.pass(Duration::from_secs(30));
                clock.release(Duration::from_secs(30));
            }
            Seat::Late => {
                // The start lands before the poll at second 30 of the 60,
                // its command held through the window.
                let staged = executor_dir(&w, "true", 20);
                let held = Owned::sleep();
                fs::write(staged.join("job.err"), "").unwrap();
                fs::write(
                    staged.join("runner"),
                    format!(
                        "runner=attached\npid={}\nstart={}\nline=runner=attached\n",
                        held.pid(),
                        held.start()
                    ),
                )
                .unwrap();
                holder = Some(held);
                fs::rename(&staged, &dir).unwrap();
                clock.pass(Duration::from_secs(30));
                clock.release(Duration::from_secs(30));
            }
            Seat::Refused => {
                // The seat's start is refused after its admission: a
                // directory already stands where the run was to be written.
                fs::create_dir(&dir).unwrap();
                let out = w.entry(&["--worktree", &wt, "--run-id", &id], &[]);
                assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
                let line = keyed(&out);
                assert!(line.starts_with("validate: launch-failed "), "{line}");
                assert_eq!(field(&line, "cause"), "run-exists", "{line}");
                clock.release(Duration::from_secs(30));
            }
            Seat::RefusedUnrecorded => {
                // The seat's start is refused before it records the run: the
                // host has no room for the run's need.
                let out = w.entry(
                    &["--worktree", &wt, "--run-id", &id],
                    &[("ORCH_VALIDATE_MEMORY_MAX", "1023T")],
                );
                assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
                assert!(
                    keyed(&out).starts_with("validate: memory-short"),
                    "{}",
                    stderr(&out)
                );
                clock.release(Duration::from_secs(30));
            }
            Seat::RefusedByRound => {
                // The seat starts the round's run by item and round, naming
                // no run directory, and is refused before it records it.
                let out = w.start(&[], &[("ORCH_VALIDATE_MEMORY_MAX", "1023T")]);
                assert_eq!(refusal(&out), "memory-short", "{}", stderr(&out));
                // An item with no record holds no stage to write a refusal
                // on, so its start answers its own refusal.
                let out = w.run(
                    &[
                        "validate", "start", "--item", "KEN-0", "--round", ROUND, "--poll", "1",
                    ],
                    &[],
                );
                assert_eq!(refusal(&out), "record-missing", "{}", stderr(&out));
                // An item whose record cannot be read refuses the write of
                // the start's refusal for the cause that refusal names, so
                // its start answers that refusal as itself.
                let unreadable = support::item_record(&w.state, "KEN-0");
                fs::write(&unreadable, "{").unwrap();
                let out = w.run(
                    &[
                        "validate", "start", "--item", "KEN-0", "--round", ROUND, "--poll", "1",
                    ],
                    &[],
                );
                fs::remove_file(&unreadable).unwrap();
                assert_eq!(refusal(&out), "json-invalid", "{}", stderr(&out));
                clock.release(Duration::from_secs(30));
            }
            Seat::RefusalUnwritable => {
                // The seat's start is refused before it records the run, and
                // the item's record refuses the write of that refusal.
                let folder = w.item.parent().unwrap().to_owned();
                let mode = |m| {
                    fs::set_permissions(
                        &folder,
                        <fs::Permissions as std::os::unix::fs::PermissionsExt>::from_mode(m),
                    )
                    .unwrap()
                };
                mode(0o555);
                let short = w.entry(
                    &["--worktree", &wt, "--run-id", &id],
                    &[("ORCH_VALIDATE_MEMORY_MAX", "1023T")],
                );
                // With room for the run, the start fails at its own record
                // write, which fails the refusal's write the same way.
                let unwritten = w.entry(&["--worktree", &wt, "--run-id", &id], &[]);
                mode(0o755);
                for (out, refused) in [(short, "memory-short"), (unwritten, "io-failed")] {
                    assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
                    let line = keyed(&out);
                    let line = line.as_str();
                    assert!(line.starts_with("validate: refusal-unrecorded "), "{line}");
                    assert_eq!(field(line, "refused"), refused, "{line}");
                    assert_eq!(field(line, "run_dir"), dir.display().to_string());
                    assert_eq!(field(line, "cause"), "io-failed", "{line}");
                }
                clock.pass(Duration::from_secs(30));
                clock.release(Duration::from_secs(30));
            }
            Seat::RefusedReconciled => {
                // The seat's refused start leaves its key on the admission,
                // which the round's reconcile then closes unstarted.
                let out = w.entry(
                    &["--worktree", &wt, "--run-id", &id],
                    &[("ORCH_VALIDATE_MEMORY_MAX", "1023T")],
                );
                assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
                ok(&w.op(&json!({"op":"reconcile-round","round_id":ROUND}), &[]));
                clock.release(Duration::from_secs(30));
            }
            Seat::RunLive => {
                // The seat's start is refused while another run holds the
                // worktree; its route waits for that run and starts again.
                let staged = executor_dir(&w, "true", 20);
                let held = Owned::sleep();
                fs::write(staged.join("job.err"), "").unwrap();
                fs::write(
                    staged.join("runner"),
                    format!(
                        "runner=attached\npid={}\nstart={}\nline=runner=attached\n",
                        held.pid(),
                        held.start()
                    ),
                )
                .unwrap();
                holder = Some(held);
                let out = w.entry(&["--worktree", &wt, "--run-id", &id], &[]);
                assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
                assert!(
                    keyed(&out).starts_with("validate: run-live"),
                    "{}",
                    stderr(&out)
                );
                clock.pass(Duration::from_secs(30));
                clock.release(Duration::from_secs(30));
            }
            Seat::Reconciled => {
                ok(&w.op(&json!({"op":"reconcile-round","round_id":ROUND}), &[]));
                clock.release(Duration::from_secs(30));
            }
            Seat::Unadmitted => {}
        }
        let answer = received.recv_timeout(JOB_BOUND).unwrap();
        task.join().unwrap();
        drop(holder);
        match (want, answer) {
            (Ok((want, exit)), Ok((text, code))) => {
                let states: Vec<_> = text.lines().filter(|l| l.starts_with("state=")).collect();
                assert_eq!(states.len(), 1, "{text}");
                assert_eq!(field(states[0], "state"), want, "{text}");
                assert_eq!(field(states[0], "run-dir"), dir.display().to_string());
                assert_eq!(code, exit, "{text}");
                match want {
                    "done" => assert_eq!(field(states[0], "validate"), "pass", "{text}"),
                    "queued" => assert_eq!(field(states[0], "waited-secs"), "60", "{text}"),
                    _ => assert_eq!(field(states[0], "elapsed-secs"), "60", "{text}"),
                }
            }
            (Err((want, cause)), Err(error)) => {
                assert_eq!(error.key(), want, "{error}");
                // The public wait answers the same refusal on its keyed
                // line, the one a lane reads.
                let out = w.entry(
                    &[
                        "--wait",
                        "--worktree",
                        &wt,
                        "--run-id",
                        &id,
                        "--budget",
                        "1",
                    ],
                    &[],
                );
                assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
                let line = keyed(&out);
                let line = line.as_str();
                assert_eq!(
                    line.strip_prefix("validate: ")
                        .and_then(|l| l.split(' ').next()),
                    Some(want),
                    "{line}"
                );
                assert_eq!(field(line, "run_dir"), dir.display().to_string());
                assert_eq!(field(line, "cause"), cause.unwrap_or_default(), "{line}");
                if want == "run-ended-unstarted" {
                    assert_eq!(field(line, "outcome"), "stopped", "{line}");
                }
            }
            (want, answer) => panic!("want {want:?}, answered {answer:?}"),
        }
        if seat == Seat::RefusedUnrecorded {
            // The refusal left the admission open: the same id starts.
            let out = w.entry(&["--worktree", &wt, "--run-id", &id, "--poll", "1"], &[]);
            assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
            assert_eq!(directory(&out), dir.display().to_string());
            w.wait_marked(&dir.display().to_string());
        }
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
    assert_eq!(w.wait_marked(dir)["outcome"], "pass");
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
    // The unit has no lifetime limit, takes SIGPIPE at its default, and its
    // record names it as the stop reads it.
    assert!(
        !words.iter().any(|w| w.starts_with("RuntimeMaxSec=")),
        "{argv}"
    );
    assert!(words.contains(&"IgnoreSIGPIPE=no"), "{argv}");
    let bound = field(started["started_line"].as_str().unwrap(), "memory-bound");
    assert_eq!(
        run_file(dir, "runner"),
        format!(
            "runner=systemd\nunit={unit}\nline=runner=systemd unit={unit} memory-max={bound}\n"
        )
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

/// The host's memory in bytes, `MemTotal` of `/proc/meminfo`: no bound a
/// start reads from this host's room can pass it.
fn host_memory() -> u64 {
    let meminfo = fs::read_to_string("/proc/meminfo").unwrap();
    let kb: u64 = meminfo
        .lines()
        .find_map(|l| l.strip_prefix("MemTotal:"))
        .and_then(|rest| rest.trim().strip_suffix(" kB"))
        .and_then(|kb| kb.trim().parse().ok())
        .unwrap();
    kb * 1024
}

/// Every validation unit is held to its start's bound over the whole tree,
/// swap included, with the manager's stop at the first OOM kill off and no
/// soft cap beside it, on the admitted start and the ad-hoc entry alike;
/// the bound is the host's room where no value is set (`rule=host`) and a
/// consumer's value under the room where one is (`rule=consumer`), and the
/// started line and the runner line name it.
#[test]
fn a_validation_unit_is_held_at_its_hosts_room_or_a_consumers_narrower_value_with_no_swap() {
    for cap in [Some("1G"), None] {
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
        assert_eq!(w.wait_marked(dir)["outcome"], "pass", "{cap:?}");
        let started_line = started["started_line"].as_str().unwrap();
        let bound: u64 = field(started_line, "memory-bound").parse().unwrap();
        let rule = field(started_line, "rule");
        match cap {
            Some(_) => assert_eq!((bound, rule.as_str()), (1 << 30, "consumer")),
            None => {
                assert_eq!(rule, "host", "{started_line}");
                assert!((1 << 30..=host_memory()).contains(&bound), "{started_line}");
            }
        }
        let start = run_file(dir, "start");
        assert_eq!(field(&start, "memory-bound"), bound.to_string(), "{start}");
        let (words, line) = unit_launch(&manager, dir);
        for property in [
            format!("MemoryMax={bound}"),
            "MemorySwapMax=0".to_owned(),
            "OOMPolicy=continue".to_owned(),
        ] {
            assert!(words.contains(&property), "{cap:?} {property}: {words:?}");
        }
        assert!(
            !words.iter().any(|w| w.starts_with("MemoryHigh=")),
            "{words:?}"
        );
        assert!(line.ends_with(&format!(" memory-max={bound}")), "{line}");
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
/// run in the caller's own process, is held to its start's bound by its
/// executor, whose log says so under the launcher's line, and its
/// launcher's line, which the run's record carries, says nothing of
/// memory: a manager that does not answer, and a client older than a
/// property the cap sets, which refuses the name before it asks the
/// manager anything.
#[test]
fn a_run_no_cgroup_of_its_own_holds_is_held_to_its_bound_by_its_executor() {
    for (answer, opening, cause) in [
        (
            ("VALIDATE_PROBE_ANSWER", "no-manager"),
            "runner=setsid reason=probe-failed ",
            "probe-failed",
        ),
        (
            ("VALIDATE_START_ANSWER", "unknown-assignment"),
            "runner=setsid reason=unit-launch-failed detail=Unknown assignment: OOMPolicy=continue",
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
        let stage = w.wait_marked(dir);
        assert_eq!(stage["outcome"], "pass", "{cause}");
        let line = stage["job"]["line"].as_str().unwrap();
        assert!(line.starts_with(opening), "{line}");
        assert!(!line.contains("memory"), "{line}");
        let log = run_file(dir, "log");
        let mut lines = log.lines();
        assert_eq!(lines.next(), Some(line), "{log}");
        assert_eq!(
            lines.next(),
            Some("memory-held=reader bound=1073741824"),
            "{log}"
        );
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
    assert_eq!(stage["job"]["line"], "runner=attached");
    assert!(
        run_file(dir, "log").contains("\nmemory-held=reader bound=1073741824\n"),
        "{}",
        run_file(dir, "log")
    );
}

/// A command tree whose resident memory passes the bound its start set,
/// where no unit's cap holds it, is ended whole by its executor and fails
/// with the bound and the peak it read, on the sentinel and the wait, on a
/// `setsid` and an attached run alike; a process outside the tree runs on,
/// and a tree under its bound passes with no cause.
#[test]
fn a_tree_past_the_bound_its_executor_holds_ends_failing_with_the_limit_and_the_peak() {
    use std::sync::{Arc, mpsc};
    const BOUND: u64 = 16 << 20;
    const HELD: u64 = 48 << 20;
    /// A process outside the run's tree, ended and reaped whatever the
    /// row's answer.
    struct Sibling(std::process::Child);
    impl Drop for Sibling {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    for (case, runner, line, holds) in [
        (
            "setsid, over",
            "setsid",
            "runner=setsid reason=probe-failed",
            true,
        ),
        ("attached, over", "attached", "runner=attached", true),
        ("attached, under", "attached", "runner=attached", false),
    ] {
        let w = World::new();
        let ready = w.root.join("ready");
        let go = w.root.join("go");
        // The command prints its rank and names itself ready while it holds
        // nothing, so no reading can end it first; only once the row says
        // go does the holder fill a shell variable of its own size, then
        // wait well past the reads that end it.
        let hold = if holds {
            format!("printf -v held '%*s' {HELD} ''; sleep 20")
        } else {
            "sleep 3".to_owned()
        };
        let command = format!(
            "cat /proc/self/oom_score_adj; echo ready > '{}'; until [ -e '{}' ]; do sleep 0.05; done; {hold}; echo done",
            ready.display(),
            go.display()
        );
        let dir = executor_dir(&w, &command, 600);
        let mut start = fs::read_to_string(dir.join("start")).unwrap();
        start.push_str(&format!("memory-bound={BOUND}\n"));
        fs::write(dir.join("start"), start).unwrap();
        fs::write(
            dir.join("runner"),
            format!("runner={runner}\nline={line}\n"),
        )
        .unwrap();
        let mut sibling = Sibling(program("sleep").arg("60").spawn().unwrap());
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
        fs::write(&go, "").unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        let answer = loop {
            match received.try_recv() {
                Ok(answer) => break answer,
                Err(mpsc::TryRecvError::Disconnected) => panic!("executor ended without answer"),
                Err(mpsc::TryRecvError::Empty) => {
                    assert!(
                        Instant::now() < deadline,
                        "{case}: executor exceeded parent deadline"
                    );
                    clock.release(Duration::from_millis(100));
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        };
        answer.unwrap();
        task.join().unwrap();
        assert!(
            sibling.0.try_wait().unwrap().is_none(),
            "{case}: a process outside the tree ended"
        );
        drop(sibling);
        let log = fs::read_to_string(dir.join("log")).unwrap();
        assert!(
            log.contains(&format!("\nmemory-held=reader bound={BOUND}\n")),
            "{case}: {log}"
        );
        // The tree is ranked first for any OOM killer on every route.
        assert!(log.contains("\n1000\n"), "{case}: {log}");
        let sentinel = fs::read_to_string(dir.join("exit")).unwrap();
        let (waited, exit) = orch_runtime::validate::files::wait(&dir, 0, clock.as_ref()).unwrap();
        if !holds {
            assert_eq!(field(&sentinel, "guard-exit"), "0", "{case}: {sentinel}");
            assert!(!sentinel.contains(" cause="), "{case}: {sentinel}");
            assert_eq!(exit, 0, "{case}: {waited}");
            continue;
        }
        assert_eq!(field(&sentinel, "guard-exit"), "137", "{case}: {sentinel}");
        assert_eq!(
            field(&sentinel, "limit"),
            BOUND.to_string(),
            "{case}: {sentinel}"
        );
        let peak: u64 = field(&sentinel, "peak").parse().unwrap();
        // The peak is the reading that ended the tree, which may land while
        // the holder still fills.
        assert!(peak > BOUND, "{case}: {sentinel}");
        assert!(
            sentinel.ends_with(&format!(" cause=memory-cap limit={BOUND} peak={peak}\n")),
            "{case}: {sentinel}"
        );
        assert!(!log.contains("\ndone\n"), "{case}: {log}");
        assert!(!dir.join("own-exit").exists(), "{case}");
        let id: agent_runtime::process::Identity =
            serde_json::from_slice(&fs::read(dir.join("command")).unwrap()).unwrap();
        assert!(matches!(
            agent_runtime::process::still_runs(&id),
            agent_runtime::reading::Reading::Gone
        ));
        assert_eq!(exit, 1, "{case}: {waited}");
        assert!(
            waited.contains(&format!(
                " validate=FAILING cause=memory-cap limit={BOUND} peak={peak} run-dir="
            )),
            "{case}: {waited}"
        );
    }
}

/// The memory cap's setting is judged by the validation start that reads
/// it, before any record: a value outside systemd's byte form or under the
/// floor refuses the start with the key, the value and the floor; a value
/// over the host's room refuses it `memory-short` with the need and the
/// room; either way the item's record is left as it was.
#[test]
fn a_memory_value_outside_its_form_under_its_floor_or_over_the_room_refuses_the_start_with_nothing_recorded()
 {
    let w = World::new();
    let before = fs::read_to_string(&w.item).unwrap();
    let out = w.start(&[], &[("ORCH_VALIDATE_MEMORY_MAX", "1023T")]);
    assert_eq!(refusal(&out), "memory-short", "{}", stderr(&out));
    let fields = &reply(&out)["refusal"]["fields"];
    assert_eq!(fields[0], json!(["need", (1023u64 << 40).to_string()]));
    assert_eq!(fields[1][0], "room");
    let room: u64 = fields[1][1].as_str().unwrap().parse().unwrap();
    assert!(room < 1023 << 40, "{fields}");
    assert_eq!(fields.as_array().unwrap().len(), 2, "{fields}");
    assert_eq!(fs::read_to_string(&w.item).unwrap(), before);
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
    assert_eq!(w.wait_marked(dir)["outcome"], "pass");
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
    assert_eq!(
        keyed(&out),
        "validate: validate-unreadable read=missing-command commands=perl",
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
    // The cause is the launcher's own key: setsid could not be run.
    let line = keyed(&out);
    assert!(line.starts_with("validate: launch-failed "), "{line}");
    assert_eq!(field(&line, "cause"), "launch-failed", "{line}");
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
    assert_eq!(w.wait_marked(dir)["outcome"], "pass");
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
        assert_eq!(w.wait_marked(dir)["outcome"], "pass", "{linger}");
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
    assert_eq!(w.wait_marked(dir)["outcome"], "pass");
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
    assert_eq!(w.wait_marked(dir)["outcome"], "pass");
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
            // The refusal's fields name the run alone, so its keyed line
            // parses; the job's handle, the launcher's free text, is its text.
            let refused = &reply(&out)["refusal"];
            assert_eq!(refused["fields"], json!([["run_dir", stage["run_dir"]]]));
            let launches = fs::read_to_string(Path::new(&manager).join("launches")).unwrap();
            let unit = launches.lines().next().unwrap();
            let text = refused["text"].as_str().unwrap();
            assert!(text.contains(unit), "{text}");
            assert_eq!(refusal(&w.start(&[], &extra)), "run-live");
        } else {
            assert_eq!(stage["outcome"], "stopped");
        }
    }
}

#[test]
fn last_pass_reads_recorded_snapshots_and_later_red_or_unknown_order_invalidates_them() {
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

/// A round's base, then its fix, restacked by hand onto an origin base
/// branch that changed the line the base's own commit changed: the conflict
/// is resolved in `conflict.txt` of the rewritten base commit, before the
/// fix. The rewrite's hop is recorded in the worktree's rebase map as the
/// worktree skill records it. Answers the round's base.
fn restacked(w: &World) -> String {
    let fork = w.head();
    fs::write(w.worktree.join("conflict.txt"), "branch\n").unwrap();
    git(&w.worktree, &["add", "conflict.txt"]);
    git(&w.worktree, &["commit", "-q", "-m", "base"]);
    let base = w.head();
    let fix = w.commit("fix.rs");
    git(&w.worktree, &["checkout", "-q", "-b", "upstream", &fork]);
    fs::write(w.worktree.join("conflict.txt"), "upstream\n").unwrap();
    git(&w.worktree, &["add", "conflict.txt"]);
    git(&w.worktree, &["commit", "-q", "-m", "upstream"]);
    git(
        &w.worktree,
        &["update-ref", "refs/remotes/origin/main", "HEAD"],
    );
    git(&w.worktree, &["checkout", "-q", "main"]);
    let rebase = program("git")
        .arg("-C")
        .arg(&w.worktree)
        .args(["rebase", "-q", "refs/remotes/origin/main"])
        .output()
        .unwrap();
    assert!(!rebase.status.success(), "the restack must conflict");
    fs::write(w.worktree.join("conflict.txt"), "resolved\n").unwrap();
    git(&w.worktree, &["add", "conflict.txt"]);
    git(
        &w.worktree,
        &["-c", "core.editor=true", "rebase", "--continue"],
    );
    let rewritten = git(&w.worktree, &["rev-parse", "HEAD~1"]);
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
        format!(
            "rebase-hop:\nrebase-map: {base} {rewritten}\nrebase-map: {fix} {}\n",
            w.head()
        ),
    )
    .unwrap();
    base
}

#[test]
fn a_range_after_a_restack_compares_from_the_authorized_base_and_holds_the_resolution() {
    let w = World::new();
    let base = restacked(&w);
    let out = w.local(
        &["--validate-mode", "range", "--base", &base],
        &[(
            "DEV_VALIDATE_RANGE_CMD",
            "git diff --name-only \"$DEV_VALIDATE_BASE\" HEAD; cat \"$DEV_VALIDATE_PATHS\"",
        )],
    );
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    let dir = directory(&out);
    // The range command's own diff from the base it received, then the
    // classified paths it is handed: the resolution is in both.
    let log = run_file(&dir, "log");
    assert_eq!(
        log.lines().filter(|line| *line == "conflict.txt").count(),
        2,
        "{log}"
    );
    assert_eq!(
        log.lines().filter(|line| *line == "fix.rs").count(),
        2,
        "{log}"
    );
    let fields = orch_runtime::validate::files::fields(&Path::new(&dir).join("start")).unwrap();
    assert_eq!(fields["validate-base"], base);
    assert_eq!(fields["class-base"], base);
}

#[test]
fn a_base_a_restack_left_unreachable_and_pruned_is_refused_by_name_and_runs_nothing() {
    let w = World::new();
    let base = restacked(&w);
    git(&w.worktree, &["update-ref", "-d", "ORIG_HEAD"]);
    git(
        &w.worktree,
        &[
            "reflog",
            "expire",
            "--expire=now",
            "--expire-unreachable=now",
            "--all",
        ],
    );
    git(&w.worktree, &["gc", "-q", "--prune=now"]);
    let gone = program("git")
        .arg("-C")
        .arg(&w.worktree)
        .args(["cat-file", "-e", &format!("{base}^{{commit}}")])
        .output()
        .unwrap();
    assert!(!gone.status.success(), "the base must be pruned");
    let out = w.local(
        &["--validate-mode", "range", "--base", &base],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    );
    assert_eq!(
        out.status.code(),
        Some(2),
        "{} {}",
        text(&out),
        stderr(&out)
    );
    assert_eq!(keyed(&out), format!("validate: invalid-base base={base}"));
    let runs = fs::read_dir(w.worktree.join("tmp"))
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("dev-validate-"))
        .count();
    assert_eq!(runs, 0, "a refused start leaves no run directory");
}

/// An admitted entry run under its id and its round's base takes the
/// narrowest declared mode, runs in the admitted directory, closes its stage
/// with its verdict and marks the end notice; an id the round never admitted
/// is refused.
#[test]
fn an_admitted_entry_run_resolves_its_mode_from_its_base_and_an_unadmitted_id_is_refused() {
    let w = World::new();
    let base = w.head();
    w.commit("src.rs");
    let admitted = ok(&w.op(
        &json!({"op":"record-validation-admission","round_id":ROUND}),
        &[],
    ));
    let id = admitted["report"]["run_id"].as_str().unwrap();
    let dir = admitted["report"]["run_dir"].as_str().unwrap();
    let wt = w.worktree.display().to_string();
    // Before the start, a wait by the worktree and run id reads the run
    // queued in the directory the admission named.
    let queued = w.entry(
        &["--wait", "--worktree", &wt, "--run-id", id, "--budget", "1"],
        &[],
    );
    assert_eq!(queued.status.code(), Some(3), "{}", stderr(&queued));
    let states: Vec<_> = text(&queued)
        .lines()
        .filter(|l| l.starts_with("state="))
        .map(str::to_owned)
        .collect();
    assert_eq!(states.len(), 1, "{}", text(&queued));
    assert_eq!(field(&states[0], "state"), "queued", "{}", states[0]);
    assert_eq!(field(&states[0], "run-dir"), dir, "{}", states[0]);
    let out = w.entry(
        &[
            "--worktree",
            &wt,
            "--run-id",
            id,
            "--base",
            &base,
            "--poll",
            "1",
        ],
        &[("DEV_VALIDATE_RANGE_CMD", "echo range")],
    );
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
    // A wait by the worktree and run id, as a seat that did not start the
    // run holds it, reads the directory the start ran in.
    let waited = w.entry(&["--wait", "--worktree", &wt, "--run-id", id], &[]);
    assert_eq!(waited.status.code(), Some(0), "{}", stderr(&waited));
    let line = text(&waited);
    let line = line.lines().last().unwrap();
    assert_eq!(field(line, "state"), "done", "{line}");
    assert_eq!(field(line, "validate"), "pass", "{line}");
    assert_eq!(field(line, "run-dir"), dir, "{line}");
    let out = w.entry(
        &["--worktree", &wt, "--run-id", "20300101T000000Z-unadmitted"],
        &[],
    );
    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains("run-unadmitted"), "{}", stderr(&out));
}

#[test]
fn an_admitted_entry_directs_targeted_checks_only_when_required_ci_takes_the_change() {
    for (world, mode, verdict, lanes) in [
        ("required", "ci", "pending", "scoped"),
        ("context-unrequired", "full", "pass", "full"),
    ] {
        let w = World::new();
        w.base_with(&[(INVENTORY, "[]\n")]);
        w.commit("source.rs");
        let (path, replies, log) = ci_world(&w, world);
        let admitted = ok(&w.op(
            &json!({"op":"record-validation-admission","round_id":ROUND}),
            &[],
        ));
        let id = admitted["report"]["run_id"].as_str().unwrap();
        let out = w.local(
            &["--run-id", id],
            &[
                ("PATH", path.as_str()),
                ("GH_FAKE_REPLIES", replies.as_str()),
                ("GH_FAKE_LOG", log.as_str()),
                ("GH_REPO", "o/r"),
                ("ORCH_DELIVERY", "pr"),
                ("DEV_VALIDATE_CI_CONTEXT", "CI"),
                ("DEV_VALIDATE_CMD", "echo 'validate: lanes=full selection=all'"),
                (
                    "DEV_VALIDATE_SELECTION_CMD",
                    "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then echo 'validate: lanes=scoped selection=subset'; else echo selection=subset; fi",
                ),
            ],
        );
        let output = text(&out);
        assert!(out.status.success(), "{world}: {output} {}", stderr(&out));
        let dir = directory(&out);
        assert_eq!(Some(dir.as_str()), admitted["report"]["run_dir"].as_str());
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "validate-mode"), mode, "{world}: {record}");
        assert_eq!(field(&record, "verdict"), verdict, "{world}: {record}");
        assert_eq!(field(&record, "lanes"), lanes, "{world}: {record}");
        let log = run_file(&dir, "log");
        assert_eq!(log.contains("lanes=full"), mode == "full", "{world}: {log}");
        // Both dev workflows consume the keyed line immediately after the start.
        let mut advisory_rows = output
            .lines()
            .enumerate()
            .filter(|(_, line)| !field(line, "local-checks").is_empty());
        let advisory = advisory_rows.next().map(|(index, line)| {
            (
                index,
                field(line, "validate-mode"),
                field(line, "local-checks"),
            )
        });
        let expected = (mode == "ci").then(|| (1, "ci".into(), "targeted-only".into()));
        assert_eq!(advisory, expected, "{world}: {output}");
        assert!(advisory_rows.next().is_none(), "{world}: {output}");
    }
}

/// A detached start, ad hoc or admitted, follows its run for one call's
/// budget and returns with the run still going, so no call outlasts a
/// harness's foreground limit; the next `--wait` follows the same run to its
/// verdict.
#[test]
fn a_detached_start_returns_at_its_budget_with_the_run_going_and_a_wait_reads_it_to_its_end() {
    for admitted in [false, true] {
        let w = World::new();
        let release = w.root.join("release");
        let held = format!(
            "while [ ! -e '{}' ]; do sleep 0.1; done; echo full",
            release.display()
        );
        let wt = w.worktree.display().to_string();
        let id = admitted.then(|| {
            let admission = ok(&w.op(
                &json!({"op":"record-validation-admission","round_id":ROUND}),
                &[],
            ));
            admission["report"]["run_id"].as_str().unwrap().to_owned()
        });
        let mut args = vec!["--worktree", wt.as_str(), "--poll", "1", "--budget", "1"];
        if let Some(id) = &id {
            args.extend(["--run-id", id.as_str()]);
        }
        let out = w.entry(&args, &[("DEV_VALIDATE_CMD", &held)]);
        assert_eq!(
            out.status.code(),
            Some(3),
            "admitted={admitted}: {} {}",
            text(&out),
            stderr(&out)
        );
        let dir = directory(&out);
        let last = text(&out).lines().last().unwrap().to_owned();
        assert_eq!(field(&last, "state"), "running", "{last}");
        assert_eq!(field(&last, "run-dir"), dir, "{last}");
        fs::write(&release, "").unwrap();
        let out = w.entry(&["--wait", "--run-dir", &dir, "--budget", "30"], &[]);
        assert_eq!(
            out.status.code(),
            Some(0),
            "admitted={admitted}: {}",
            text(&out)
        );
        assert_eq!(field(&text(&out), "state"), "done", "{}", text(&out));
        assert_eq!(field(&text(&out), "validate"), "pass", "{}", text(&out));
        if admitted {
            assert_eq!(w.wait_marked(&dir)["outcome"], "pass");
        }
    }
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
    until(|| command_identity_recorded(Path::new(&dir)));
    let out = w.entry(&["--stop", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(text(&out), "state=stopped units=0 groups=1");
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
    if case == "closed-trivial" {
        view["state"] = json!("CLOSED");
    }
    if case == "queue-unrequired" {
        rules = json!([]);
    }
    if matches!(
        case,
        "queue-no-merge-queue" | "queue-absent" | "no-pr-no-queue"
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
    let rules_page =
        |base: &str, n: usize| format!("repos/o/r/rules/branches/{base}?per_page=100&page={n}");
    // The worktree's repository as gh names it there.
    let mut replies = json!({"repo view":{"text":"o/r\n"},"pr view --json":{"body":view},"repos/o/r/branches/main":{"body":protection}});
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
        replies["repos/o/r/branches/feature%2Fparent"] = json!({"body":{"commit":{"sha":"0000000000000000000000000000000000000000","commit":{"committer":null}},"protected":false,"protection":{"required_status_checks":{"contexts":[],"checks":[]}}}});
    }
    // gh's answer for a branch with no pull request, whose rules are read
    // at the resolved base.
    if matches!(case, "no-pr" | "no-pr-no-queue") {
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

/// The render inventory a base holds: with it the classifier measures a
/// size; without it every change is `standard`.
const INVENTORY: &str = ".kendex-generated.json";

impl World {
    /// The base the real classifier reads a round against: `files`
    /// committed over the checkout and origin's main moved there, so the
    /// round and the branch are the commits after it.
    fn base_with(&self, files: &[(&str, &str)]) -> String {
        if !files.is_empty() {
            self.commit_files(files);
        }
        git(
            &self.worktree,
            &["update-ref", "refs/remotes/origin/main", "HEAD"],
        );
        self.head()
    }

    /// A base whose settings put `notes.txt` on the trivial allowlist and
    /// whose inventory a size is measured against: a round of `notes.txt`
    /// is then trivial, a class CI never stands its checks down for.
    fn trivial_base(&self) -> String {
        let settings = fs::read_to_string(self.worktree.join("kendex.settings.toml")).unwrap();
        let settings = format!("{settings}HARNESS_CI_TRIVIAL_PATHS = \"notes.txt\"\n");
        self.base_with(&[("kendex.settings.toml", &settings), (INVENTORY, "[]\n")])
    }
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
        ("no-pr", "ci", ""),
        ("class-trivial", "range", "class-uncovered"),
        ("class-standard-unmeasured", "ci", ""),
        ("class-docs", "range", "class-uncovered"),
        ("queue-required", "ci", ""),
        ("queue-unrequired", "range", "class-uncovered"),
        ("queue-no-merge-queue", "range", "class-uncovered"),
        // Only a record reading false proves pull-request CI covers the work.
        ("queue-absent", "range", "class-uncovered"),
        ("queue-absent-merge-queue", "ci", ""),
        // The pull request read fails, or names an empty base.
        ("pr-unread", "range", "base-unresolved"),
        ("base-empty", "range", "base-unresolved"),
        // No open pull request, and a class CI may not cover.
        ("closed-trivial", "range", "class-uncovered"),
        ("class-micro-measured", "ci", ""),
    ] {
        let w = World::new();
        let (path, replies, log) = ci_world(&w, case);
        // The range the real classifier reads: the base's inventory, and the
        // round's one file. A base with no inventory is `standard`; an
        // unreadable one is `standard` unmeasured; `notes.md` is docs-only;
        // `queue.rs` is on the World's queue list.
        let base = match case {
            "class-trivial" | "closed-trivial" => w.trivial_base(),
            "class-micro-measured" => w.base_with(&[(INVENTORY, "[]\n")]),
            "class-standard-unmeasured" => w.base_with(&[(INVENTORY, "not json\n")]),
            _ => w.base_with(&[]),
        };
        w.commit(match case {
            "class-trivial" | "closed-trivial" => "notes.txt",
            "class-docs" => "notes.md",
            "queue-required" | "queue-unrequired" | "queue-no-merge-queue" => "queue.rs",
            _ => "source.rs",
        });
        // change-scope installed with no harness-ci beside it: the runtime
        // runs change-scope itself, which prints no queue-only record.
        let alone = w.root.join("alone/change-scope");
        if case.starts_with("queue-absent") {
            fs::create_dir_all(&alone).unwrap();
            let package = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../change-scope");
            let out = program("cp")
                .arg("-R")
                .arg(package.join("scripts"))
                .arg(package.join("references"))
                .arg(&alone)
                .output()
                .unwrap();
            assert!(out.status.success(), "cp: {}", stderr(&out));
        }
        let alone = alone.join("scripts/harness-only").display().to_string();
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
        if case.starts_with("queue-absent") {
            extra.push(("CHANGE_SCOPE_PATHS_CLI", alone.as_str()));
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
        // read: the open PR's, or the resolved base before one.
        if matches!(case, "required" | "stacked" | "no-pr") {
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
        // The proof read the workflows run answers an admitted round's
        // required CI pending over the round's own run, which records the
        // event that proves the head.
        if matches!(case, "required" | "queue-required") {
            let started = ok(&w.start(&["--base", &base], &extra));
            assert_eq!(started["mode"], "ci", "{case}: {started}");
            let run_dir = started["run_dir"].as_str().unwrap();
            let tree = git(&w.worktree, &["rev-parse", "HEAD^{tree}"]);
            let head = w.head();
            let read = w.read_proof(
                &[
                    "--need", "submit", "--tree", &tree, "--head", &head, "--base", &base,
                ],
                &extra,
            );
            assert_eq!(read["proof"], "pending", "{case}: {read}");
            assert_eq!(read["rows"][0]["mode"], "ci", "{case}: {read}");
            assert_eq!(read["rows"][0]["run_dir"], run_dir, "{case}: {read}");
            assert_eq!(
                w.stage(run_dir)["proof"]["ci_event"],
                if case == "required" {
                    "pull_request"
                } else {
                    "merge_group"
                },
                "{case}"
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
fn a_named_range_start_asks_the_ci_admission_under_every_publication_order() {
    for order in ["push-first", "review-first", "open-first"] {
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
        assert_eq!(field(&record, "validate-mode"), "ci", "{order}: {record}");
        assert!(!Path::new(&dir).join("execution").exists(), "{order}");
    }
}

/// An implement round asks the CI admission whatever the publication
/// order: admitted, required CI holds its proof and no command runs, the
/// base read at the resolved base branch while no pull request is open;
/// refused, the whole battery runs locally.
#[test]
fn an_implement_round_ci_admits_runs_no_command_under_every_publication_order() {
    for order in [
        Some("review-first"),
        Some("open-first"),
        Some("push-first"),
        None,
    ] {
        for (world, want, cause) in [
            ("required", "ci", ""),
            ("no-pr", "ci", ""),
            ("context-unrequired", "full", "context-unrequired"),
        ] {
            let case = format!("{order:?} {world}");
            let w = World::new();
            let (path, replies, log) = ci_world(&w, world);
            w.base_with(&[]);
            w.commit("source.rs");
            let mut extra = vec![
                ("PATH", path.as_str()),
                ("GH_FAKE_REPLIES", replies.as_str()),
                ("GH_FAKE_LOG", log.as_str()),
                ("GH_REPO", "o/r"),
                ("ORCH_DELIVERY", "pr"),
                ("DEV_VALIDATE_CI_CONTEXT", "CI"),
            ];
            if let Some(order) = order {
                extra.push(("ORCH_PR_ORDER", order));
            }
            let started = ok(&w.run_without(
                &[
                    "validate",
                    "start",
                    "--item",
                    ITEM_ID,
                    "--round",
                    ROUND,
                    "--poll",
                    "1",
                    "--foreground",
                ],
                &extra,
                &["ORCH_PR_ORDER"],
            ));
            assert_eq!(started["mode"], want, "{case}: {started}");
            let dir = started["run_dir"].as_str().unwrap();
            let record = read_record(&w, dir);
            assert_eq!(field(&record, "validate-mode"), want, "{case}: {record}");
            assert_eq!(field(&record, "ci-fallback"), cause, "{case}: {record}");
            assert_eq!(
                Path::new(dir).join("execution").exists(),
                want != "ci",
                "{case}"
            );
        }
    }
}

#[test]
fn a_measured_ci_round_passes_ci_mode_to_its_scoped_command() {
    let w = World::new();
    let base = w.base_with(&[(INVENTORY, "[]\n")]);
    w.commit("source.rs");
    let (path, replies, log) = ci_world(&w, "required");
    let selector = "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then printf 'scoped-mode=%s\\n' \"$DEV_VALIDATE_MODE\"; echo 'validate: lanes=unit selection=subset'; else echo selection=subset; fi";
    let out = w.local(
        &["--validate-mode", "ci", "--base", &base],
        &[
            ("PATH", path.as_str()),
            ("GH_FAKE_REPLIES", replies.as_str()),
            ("GH_FAKE_LOG", log.as_str()),
            ("GH_REPO", "o/r"),
            ("ORCH_DELIVERY", "pr"),
            ("DEV_VALIDATE_CI_CONTEXT", "CI"),
            ("DEV_VALIDATE_SELECTION_CMD", selector),
        ],
    );
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    let dir = directory(&out);
    let record = read_record(&w, &dir);
    assert_eq!(field(&run_file(&dir, "start"), "class"), "small");
    assert_eq!(field(&record, "validate-mode"), "ci");
    assert_eq!(field(&record, "scoped"), "true");
    assert_eq!(field(&record, "verdict"), "pending");
    let log = run_file(&dir, "log");
    assert_eq!(
        log.lines()
            .find_map(|line| line.strip_prefix("scoped-mode=")),
        Some("ci"),
        "{log}"
    );
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
fn every_start_asks_the_ci_admission_before_its_selection_and_scopes_an_all_ci_does_not_take() {
    // The selector previews with $SEL, recording the mode it was asked
    // for; its scoped run passes unless $SEL ends `-red`.
    let selector = "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then echo 'validate: lanes=scoped selection=subset'; [ \"$SEL\" != all-red ]; else printf '%s\\n' \"$DEV_VALIDATE_MODE\" > \"$MODE_FILE\"; if [ \"$SEL\" = failed ]; then echo 'selector: unavailable' >&2; exit 1; fi; echo \"selection=${SEL%-red}\"; fi";
    // (requested, selection, world, change) and the record's (mode,
    // scoped, ci-fallback, verdict). The real classifier reads the change:
    // `trivial` a trivial class; `queue` queue-only work; `branch-queue`
    // queue-only work on the branch whole and not in the round.
    for (requested, sel, world, fixture, want) in [
        ("full", "all", "required", "", ("ci", "true", "", "pending")),
        (
            "full",
            "subset",
            "required",
            "",
            ("ci", "true", "", "pending"),
        ),
        (
            "full",
            "subset",
            "context-unrequired",
            "",
            ("full", "", "context-unrequired", "pass"),
        ),
        (
            "range",
            "subset",
            "required",
            "",
            ("ci", "true", "", "pending"),
        ),
        (
            "full",
            "all",
            "context-unrequired",
            "",
            ("full", "", "context-unrequired", "pass"),
        ),
        (
            "full",
            "all",
            "pr-not-open",
            "",
            ("full", "true", "pr-not-open", "pass"),
        ),
        (
            "full",
            "all-red",
            "pr-not-open",
            "",
            ("full", "true", "pr-not-open", "FAILING"),
        ),
        (
            "full",
            "all",
            "no-pr",
            "trivial",
            ("full", "true", "class-uncovered", "pass"),
        ),
        (
            "full",
            "all",
            "required",
            "trivial",
            ("full", "true", "class-uncovered", "pass"),
        ),
        (
            "full",
            "failed",
            "required",
            "",
            ("full", "", "selection-unread", "pass"),
        ),
        ("full", "subset", "no-pr", "", ("ci", "true", "", "pending")),
        (
            "ci",
            "unknown",
            "no-pr",
            "queue",
            ("range", "", "selection-unread", "pass"),
        ),
        (
            "range",
            "subset",
            "no-pr-no-queue",
            "branch-queue",
            ("range", "", "class-uncovered", "pass"),
        ),
    ] {
        let case = format!("{requested} {sel} {world} {fixture}");
        let w = World::new();
        let (path, replies, log) = ci_world(&w, world);
        let mut base = if fixture == "trivial" {
            w.trivial_base()
        } else {
            w.base_with(&[])
        };
        if fixture == "branch-queue" {
            base = w.commit("queue.rs");
        }
        w.commit(match fixture {
            "trivial" => "notes.txt",
            "queue" => "queue.rs",
            _ => "source.rs",
        });
        let mode_file = w.root.join("preview-mode").display().to_string();
        let extra = [
            ("PATH", path.as_str()),
            ("GH_FAKE_REPLIES", replies.as_str()),
            ("GH_FAKE_LOG", log.as_str()),
            ("GH_REPO", "o/r"),
            ("ORCH_DELIVERY", "pr"),
            ("DEV_VALIDATE_CI_CONTEXT", "CI"),
            ("DEV_VALIDATE_RANGE_CMD", "echo range"),
            ("DEV_VALIDATE_SELECTION_CMD", selector),
            ("SEL", sel),
            ("MODE_FILE", mode_file.as_str()),
        ];
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
fn ambiguous_selector_answers_do_not_admit_ci() {
    for selector in [
        "printf 'selection=all\nselection=subset\n'",
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

/// A selector that writes the CI admission it reads: its preview into
/// `$PREVIEW_FILE`, its scoped run into the run's log as `ci=`; it answers
/// `$SEL`.
const CI_READING_SELECTOR: &str = "if [ \"$DEV_VALIDATE_SCOPED\" = true ]; then echo \"ci=$DEV_VALIDATE_CI_EVENT|$DEV_VALIDATE_CI_ADMISSION\"; echo 'validate: lanes=unit selection=subset'; else printf '%s|%s\\n' \"$DEV_VALIDATE_CI_EVENT\" \"$DEV_VALIDATE_CI_ADMISSION\" > \"$PREVIEW_FILE\"; echo \"selection=$SEL\"; fi";

/// A start in the CI world `world` over one change to `file`, its selector
/// [`CI_READING_SELECTOR`] answering `sel`: the run directory and the
/// preview's reading.
fn ci_reading_start(
    world: &str,
    file: &str,
    sel: &str,
    ci_request: bool,
) -> (World, String, String) {
    let w = World::new();
    let (path, replies, log) = ci_world(&w, world);
    let base = w.base_with(&[]);
    w.commit(file);
    let preview = w.root.join("preview-ci").display().to_string();
    let extra = [
        ("PATH", path.as_str()),
        ("GH_FAKE_REPLIES", replies.as_str()),
        ("GH_FAKE_LOG", log.as_str()),
        ("GH_REPO", "o/r"),
        ("ORCH_DELIVERY", "pr"),
        ("DEV_VALIDATE_CI_CONTEXT", "CI"),
        ("DEV_VALIDATE_RANGE_CMD", "echo range"),
        ("DEV_VALIDATE_SELECTION_CMD", CI_READING_SELECTOR),
        ("SEL", sel),
        ("PREVIEW_FILE", preview.as_str()),
    ];
    let mut args = vec![];
    if ci_request {
        args.extend(["--validate-mode", "ci", "--base", base.as_str()]);
    }
    let out = w.local(&args, &extra);
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    let dir = directory(&out);
    let read = fs::read_to_string(&preview).unwrap_or_default();
    (w, dir, read.trim_end().to_owned())
}

#[test]
fn the_selectors_preview_reads_a_merge_group_admission() {
    let (_w, _dir, preview) = ci_reading_start("queue-required", "queue.rs", "subset", true);
    assert_eq!(preview, "merge_group|admitted");
}

#[test]
fn the_selectors_run_reads_the_admission_its_start_recorded() {
    // An admitted round's scoped run reads the event its preview read; a
    // pre-open whole selection's scoped run reads the fallback's cause.
    for (world, file, sel, ci_request, want) in [
        (
            "queue-required",
            "queue.rs",
            "subset",
            true,
            "merge_group|admitted",
        ),
        ("pr-not-open", "source.rs", "all", false, "|pr-not-open"),
    ] {
        let (w, dir, _preview) = ci_reading_start(world, file, sel, ci_request);
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "scoped"), "true", "{world}: {record}");
        let log = run_file(&dir, "log");
        assert_eq!(
            log.lines().find_map(|l| l.strip_prefix("ci=")),
            Some(want),
            "{world}: {log}"
        );
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

/// A command group outlives its executor and the stage a reconcile closed,
/// and holds the host until a worktree stop ends it. That stop ended live
/// work, so `--record` reads the run `verdict=no-verdict` and `--wait` reads
/// it `state=done stopped`, not `lost`.
#[test]
fn a_command_group_still_holds_the_host_after_its_executor_dies() {
    let w = World::new();
    let fifo = w.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let command = format!("exec 9<> '{}'; read -r -t 20 -u 9 answer", fifo.display());
    let started = ok(&w.start(&[], &[("DEV_VALIDATE_CMD", &command)]));
    let dir = started["run_dir"].as_str().unwrap();
    until(|| command_identity_recorded(Path::new(dir)));
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
    assert!(!Path::new(dir).join("exit").exists());
    let record = read_record(&w, dir);
    assert_eq!(field(&record, "verdict"), "no-verdict", "{record}");
    let wait = text(&w.entry(&["--wait", "--run-dir", dir, "--budget", "1"], &[]));
    assert_eq!(field(&wait, "state"), "done", "{wait}");
    assert_eq!(field(&wait, "validate"), "no-verdict", "{wait}");
    assert!(
        wait.split_whitespace().any(|word| word == "stopped"),
        "{wait}"
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
    let error =
        orch_runtime::validate::run::execute(&refused, &agent_runtime::clock::SystemClock, &prefix)
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
    support::install_orch_scripts(&unborn);
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
    support::install_orch_scripts(&plain);
    let plain_text = plain.display().to_string();
    let out = w.entry(
        &["--worktree", &plain_text, "--foreground", "--poll", "1"],
        &[("DEV_VALIDATE_CMD", "echo fallback-command")],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(fallback(&out), "base-unresolved", "{}", text(&out));
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
    use agent_runtime::clock::{Clock, SystemClock};
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
    until(|| command_identity_recorded(Path::new(&dir)));
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

/// A foreground run of the round whose executor and command a unit stop
/// ended together, so it left no sentinel: its run directory.
fn gone_foreground_run(w: &World) -> String {
    let fifo = w.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let command = format!("exec 9<> '{}'; read -r -t 20 -u 9 answer", fifo.display());
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
    until(|| recorded_run(&w.worktree).is_some());
    let dir = recorded_run(&w.worktree).unwrap().display().to_string();
    kill_group(&Path::new(&dir).join("pid"));
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    dir
}

/// A run with no sentinel whose work is gone reads lost in `--record` as
/// in `--wait`. A start under its own admission is refused as ended, and
/// the gone run's stage stays closed `lost` with its end notice sent rather
/// than holding the round as live, so the round's next admission starts.
#[test]
fn a_run_whose_executor_and_command_ended_reads_lost_and_holds_no_start() {
    let w = World::new();
    let dir = gone_foreground_run(&w);

    let record = read_record(&w, &dir);
    assert_eq!(field(&record, "verdict"), "FAILING", "{record}");
    assert_eq!(field(&record, "state"), "lost", "{record}");
    let wait = w.entry(&["--wait", "--run-dir", &dir, "--budget", "1"], &[]);
    assert_eq!(wait.status.code(), Some(1), "{}", text(&wait));
    assert_eq!(field(&text(&wait), "state"), "lost");
    assert_eq!(field(&text(&wait), "validate"), "FAILING");

    let again = w.run(
        &["validate", "start", "--run-dir", &dir, "--poll", "1"],
        &[],
    );
    assert_eq!(refusal(&again), "run-ended");
    let gone = w.stage(&dir);
    assert_eq!(gone["outcome"], "lost", "{gone}");
    assert_eq!(gone["notice"]["owner"], "sent", "{gone}");
    let next = ok(&w.op(
        &json!({"op": "record-validation-admission", "round_id": ROUND, "attempt": "next"}),
        &[],
    ));
    let next_dir = next["report"]["run_dir"].as_str().unwrap().to_owned();
    ok(&w.run(
        &["validate", "start", "--run-dir", &next_dir, "--poll", "1"],
        &[],
    ));
    w.wait_marked(&next_dir);
}

/// A start that names no run, past a gone one, runs a fresh run rather
/// than the gone one's admission, and a sentinel that lands after the gone
/// run's files were read is not taken for a loss.
#[test]
fn a_gone_run_frees_a_plain_start_and_reads_a_late_sentinel() {
    let w = World::new();
    let dir = gone_foreground_run(&w);
    let fresh = ok(&w.start(&[], &[]))["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(fresh, dir);
    assert_eq!(w.stage(&dir)["outcome"], "lost");
    w.wait_marked(&fresh);

    let read = orch_runtime::validate::files::RunFile::read(Path::new(&dir)).unwrap();
    fs::write(
        Path::new(&dir).join("exit"),
        format!("guard-exit=0 at={}\n", epoch_now()),
    )
    .unwrap();
    assert_eq!(read.verdict().unwrap(), "unfinished");
}

/// A worktree stop of a run gone with no sentinel leaves every reader with
/// the stage's word: a run a start already closed `lost` stays lost, and a
/// run whose stage stood open records the stop and reads `stopped`.
#[test]
fn a_worktree_stop_of_a_gone_run_leaves_its_readers_with_the_stage_word() {
    for (closed_first, outcome, verdict, wait_state, record_state) in [
        (true, "lost", "FAILING", "lost", "lost"),
        (false, "stopped", "no-verdict", "done", ""),
    ] {
        let w = World::new();
        let dir = gone_foreground_run(&w);
        if closed_first {
            let fresh = ok(&w.start(&[], &[]))["run_dir"]
                .as_str()
                .unwrap()
                .to_owned();
            w.wait_marked(&fresh);
        }
        let stop = w.entry(&["--stop", "--worktree", w.worktree.to_str().unwrap()], &[]);
        assert!(stop.status.success(), "{}", stderr(&stop));
        assert_eq!(
            w.stage(&dir)["outcome"],
            outcome,
            "closed_first={closed_first}"
        );
        let record = read_record(&w, &dir);
        assert_eq!(field(&record, "verdict"), verdict, "{record}");
        assert_eq!(field(&record, "state"), record_state, "{record}");
        let wait = w.entry(&["--wait", "--run-dir", &dir, "--budget", "1"], &[]);
        assert_eq!(field(&text(&wait), "state"), wait_state, "{}", text(&wait));
        assert_eq!(field(&text(&wait), "validate"), verdict, "{}", text(&wait));
    }
}

/// A systemd run whose command has ended with no sentinel, as a follower
/// reads it. Inside the wrapper the user manager is hidden, so the
/// executor's own record answers for the unit: a gone executor leaves the
/// run lost (a live one is the next test's, as the executor writes it). With
/// no executor record, past the launch grace the follower is refused
/// `liveness-unreadable` with its cause, never `state=running`; within the
/// grace the run is held. Unconfined, a manager that does not answer holds
/// the run, since a later read can answer it, and one that has no record
/// of the unit reads it lost. A start never overlaps a run whose work is
/// held or cannot be read, and `--live` reads it so.
#[test]
fn a_follower_that_cannot_read_a_unit_runs_liveness_says_so_and_never_reads_it_running() {
    let systemctl = fixtures().join("systemctl-unit");
    let path = tool_path(&[&systemctl]);
    let command = Owned::sleep();
    let executor = Owned::sleep();
    // Each row's executor record (`none`, or a held process under another
    // start), the wait's answer (`Ok` its
    // state, `Err` its keyed refusal), and whether `--live` reads the run.
    for (confined, manager_rc, age, recorded, answer, live) in [
        (
            "1",
            "1",
            20,
            "none",
            Err("validate: validate-unreadable read=liveness-unreadable cause=manager-hidden"),
            true,
        ),
        ("1", "1", 0, "none", Ok("running"), true),
        ("1", "1", 20, "gone", Ok("lost"), false),
        ("", "1", 20, "none", Ok("running"), true),
        ("", "0", 20, "none", Ok("lost"), false),
    ] {
        let row =
            format!("confined={confined} manager-rc={manager_rc} age={age} executor={recorded}");
        let w = World::new();
        let dir = w.worktree.join("tmp/dev-validate-unit-lost");
        fs::create_dir_all(&dir).unwrap();
        let started = epoch_now() - age;
        fs::write(
            dir.join("start"),
            format!(
                "worktree={}\nstart={started}\nquiet-secs=660\npoll-secs=1\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead={}\n",
                w.worktree.display(),
                w.head()
            ),
        )
        .unwrap();
        fs::write(dir.join("job.err"), "").unwrap();
        fs::write(
            dir.join("runner"),
            "runner=systemd\nunit=orch-validate-wt-lost\nline=runner=systemd unit=orch-validate-wt-lost\n",
        )
        .unwrap();
        fs::write(dir.join("execution"), "attempted\n").unwrap();
        // A held process under another start: the recorded command reads gone.
        fs::write(
            dir.join("command"),
            json!({"pid": command.pid(), "start": "ticks:1"}).to_string(),
        )
        .unwrap();
        // An executor gone in its tail: its command's group ended, its
        // sentinel never written.
        if recorded == "gone" {
            fs::write(dir.join("own-exit"), "").unwrap();
            fs::write(
                dir.join("executor"),
                json!({"pid": executor.pid(), "start": "ticks:1"}).to_string(),
            )
            .unwrap();
        }
        let run_dir = dir.display().to_string();
        let env = [
            ("PATH", path.as_str()),
            ("AGENT_RUNTIME_CONFINED", confined),
            ("SYSTEMCTL_RC", manager_rc),
        ];
        let out = w.entry(&["--wait", "--run-dir", &run_dir, "--budget", "1"], &env);
        match answer {
            Ok(state) => {
                assert_eq!(field(&text(&out), "state"), state, "{row}: {}", text(&out));
                let exit = if state == "lost" { 1 } else { 3 };
                assert_eq!(out.status.code(), Some(exit), "{row}: {}", stderr(&out));
            }
            Err(refused) => {
                assert_eq!(out.status.code(), Some(2), "{row}: {}", text(&out));
                assert_eq!(keyed(&out), refused, "{row}: {}", stderr(&out));
            }
        }
        let wt = w.worktree.display().to_string();
        let out = w.entry(&["--live", "--worktree", &wt], &env);
        if live {
            assert_eq!(out.status.code(), Some(0), "{row}: {}", stderr(&out));
            assert_eq!(field(&text(&out), "run-dir"), run_dir, "{row}");
        } else {
            assert_eq!(out.status.code(), Some(1), "{row}: {}", stderr(&out));
            assert_eq!(text(&out), "live=none", "{row}");
        }
    }
}

/// The record a real executor writes holds its unit's run, in the tail
/// where its command has ended and its sentinel has not landed, for a
/// follower whose wrapper hides the unit's manager: the wait reads it
/// running, and `--live` reads it live.
#[test]
fn a_confined_follower_holds_a_unit_run_in_its_tail_by_the_executors_own_record() {
    let w = World::new();
    let dir = executor_dir(&w, "true", 20);
    fs::write(
        dir.join("runner"),
        "runner=systemd\nunit=orch-validate-wt-tail\nline=runner=systemd unit=orch-validate-wt-tail\n",
    )
    .unwrap();
    fs::write(dir.join("job.err"), "").unwrap();
    orch_runtime::validate::run::execute(
        &dir,
        &agent_runtime::clock::SystemClock,
        &PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../github/scripts/lib/group-leader.sh"),
    )
    .unwrap();
    // The executor was this test's process, which still runs: without its
    // sentinel the run stands in the executor's tail.
    fs::remove_file(dir.join("exit")).unwrap();
    let systemctl = fixtures().join("systemctl-unit");
    let path = tool_path(&[&systemctl]);
    let env = [
        ("PATH", path.as_str()),
        ("AGENT_RUNTIME_CONFINED", "1"),
        ("SYSTEMCTL_RC", "1"),
    ];
    let run_dir = dir.display().to_string();
    let out = w.entry(&["--wait", "--run-dir", &run_dir, "--budget", "1"], &env);
    assert_eq!(out.status.code(), Some(3), "{}", stderr(&out));
    assert_eq!(field(&text(&out), "state"), "running", "{}", text(&out));
    let wt = w.worktree.display().to_string();
    let out = w.entry(&["--live", "--worktree", &wt], &env);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(field(&text(&out), "run-dir"), run_dir);
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
fn a_shell_start_whose_child_never_ran_is_no_run_but_the_runtimes_unread_launch_is_held() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    let dir = w.worktree.join("tmp/dev-validate-unstarted");
    fs::create_dir_all(&dir).unwrap();
    let run_dir = dir.display().to_string();
    // A run directory's start and runner records with no error log and no
    // executor's claim, its child never run:
    // started twenty seconds ago, past the ten-second launch grace.
    let started = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        - 20;
    fs::write(
        dir.join("start"),
        format!(
            "worktree={wt}\nstart={started}\nquiet-secs=660\npoll-secs=1\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead={}\n",
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

#[test]
fn a_worktree_stop_keeps_an_admitted_unreadable_job_and_its_open_stage_owed() {
    let w = World::new();
    let dir = w.worktree.join("tmp/dev-validate-unreadable-admitted");
    fs::create_dir_all(&dir).unwrap();
    let started = epoch_now() - 20;
    fs::write(dir.join("start"), format!(
        "worktree={}\nstart={started}\nquiet-secs=660\npoll-secs=1\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead={}\n",
        w.worktree.display(), w.head(),
    )).unwrap();
    fs::write(
        dir.join("runner"),
        "runner=setsid\nline=runner=setsid reason=no-linger\n",
    )
    .unwrap();
    let mut state = w.state();
    state["stages"].as_array_mut().unwrap().push(json!({
        "kind": "validate", "round_id": ROUND, "start": started, "end": null,
        "run_dir": dir, "job": {"record": dir.join("runner"), "runner": "setsid"},
    }));
    w.write_state(&state);
    let out = w.entry(&["--stop", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert_eq!(
        out.status.code(),
        Some(1),
        "{} {}",
        text(&out),
        stderr(&out)
    );
    assert!(stderr(&out).contains("stop-unreadable"), "{}", stderr(&out));
    let stage = w.stage(dir.to_str().unwrap());
    assert!(stage["end"].is_null(), "{stage}");
    assert!(stage["stop"].is_object(), "{stage}");
    assert!(!dir.join("exit").exists());
    assert_eq!(refusal(&w.start(&[], &[])), "validate-unreadable");
    assert!(w.stage(dir.to_str().unwrap())["end"].is_null());
}

#[test]
fn a_worktree_stop_keeps_a_live_attached_launch_with_an_open_stage_owed() {
    let w = World::new();
    let child = Owned(program("sleep").arg("60").spawn().unwrap());
    let agent_runtime::reading::Reading::Live(owner) =
        agent_runtime::process::identity(child.0.id())
    else {
        panic!("the owned attached caller has no identity")
    };
    let dir = w.worktree.join("tmp/dev-validate-attached-launch");
    fs::create_dir_all(&dir).unwrap();
    let started = epoch_now() - 20;
    fs::write(dir.join("start"), format!(
        "worktree={}\nstart={started}\nquiet-secs=660\npoll-secs=1\nclass=standard\ndocs-only=false\nvalidate-mode=full\nvalidate-base=\nhead={}\n",
        w.worktree.display(), w.head(),
    )).unwrap();
    fs::write(
        dir.join("runner"),
        format!(
            "runner=attached\npid={}\nstart={}\nline=runner=attached\n",
            owner.pid, owner.start
        ),
    )
    .unwrap();
    let mut state = w.state();
    state["stages"].as_array_mut().unwrap().push(json!({
        "kind": "validate", "round_id": ROUND, "start": started, "end": null,
        "run_dir": dir, "job": {"record": dir.join("runner"), "runner": "attached", "pid": owner.pid, "start": owner.start},
    }));
    w.write_state(&state);
    let out = w.entry(&["--stop", "--worktree", w.worktree.to_str().unwrap()], &[]);
    assert_eq!(
        out.status.code(),
        Some(1),
        "{} {}",
        text(&out),
        stderr(&out)
    );
    assert!(stderr(&out).contains("stop-failed"), "{}", stderr(&out));
    assert!(w.stage(dir.to_str().unwrap())["end"].is_null());
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
    until(|| command_identity_recorded(Path::new(&dir)));
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
    let command = format!("exec 9<> '{}'; read -r -t 20 -u 9 answer", fifo.display());
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
    until(|| recorded_run(&w.worktree).is_some());
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
        until(|| command_identity_recorded(Path::new(dir)));
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
    assert_eq!(one.wait_marked(&dirs[0])["outcome"], "stopped");
    // A manager that refuses the stop fails it.
    let wt = two.worktree.display().to_string();
    let mut refusing = extra.to_vec();
    refusing.push(("VALIDATE_STOP_ANSWER", "refused"));
    let out = two.entry(&["--stop", "--worktree", &wt], &refusing);
    assert_eq!(out.status.code(), Some(1), "{}", text(&out));
    assert!(stderr(&out).contains("stop-failed"), "{}", stderr(&out));
    assert_eq!(two.wait_marked(&dirs[1])["outcome"], "stopped");
    // An ad hoc run's unit the manager no longer has ended on its own: the
    // stop that finds it gone stops nothing and fails nothing.
    let three = World::new();
    let fifo = three.root.join("hold");
    assert!(program("mkfifo").arg(&fifo).status().unwrap().success());
    let command = format!("exec 9<> '{}'; read -r -t 30 -u 9 answer", fifo.display());
    let mut env = extra.to_vec();
    env.push(("DEV_VALIDATE_CMD", command.as_str()));
    let wt = three.worktree.display().to_string();
    std::thread::scope(|scope| {
        let start = scope.spawn(|| three.entry(&["--worktree", &wt, "--poll", "1"], &env));
        until(|| recorded_run(&three.worktree).is_some());
        let dir = recorded_run(&three.worktree).unwrap().display().to_string();
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

impl World {
    /// A main checkout beside the worktree holding `files`, each a path and
    /// its text.
    fn base_checkout(&self, files: &[(&str, &str)]) -> PathBuf {
        let base = self.root.join("base");
        fs::create_dir_all(base.join(".kendex")).unwrap();
        for (name, text) in files {
            fs::write(base.join(name), text).unwrap();
        }
        base
    }

    fn policy(&self, base: &Path, stage: Option<&str>, extra: &[(&str, &str)]) -> Output {
        let base = base.display().to_string();
        let mut args = vec!["validate", "policy", "--base-checkout", base.as_str()];
        if let Some(stage) = stage {
            args.extend(["--stage", stage]);
        }
        self.run(&args, extra)
    }

    /// `validate policy` from an invocation that reads private env files:
    /// the row's isolation without `--no-private-env`.
    fn policy_reading_private(&self, base: &Path) -> Output {
        let mut command = support::program(support::binary());
        command
            .arg("--state-dir")
            .arg(&self.state)
            .args(["validate", "policy", "--base-checkout"])
            .arg(base)
            .current_dir(&self.worktree);
        for (k, v) in self.env() {
            command.env(k, v);
        }
        command.output().unwrap()
    }
}

const STAGE_WORDS: [&str; 6] = [
    "external-review",
    "local-review",
    "preflight",
    "doc-limits",
    "git-hooks",
    "focused-proof",
];

/// Which optional stage runs is the main checkout's committed choice alone:
/// unset runs every stage, a list runs the stages it names, an empty value
/// none; the private env file outranks the committed files where the
/// invocation reads private files and reaches nothing under
/// `--no-private-env`; neither the caller's own `ORCH_STAGES` nor the
/// worktree's settings file reaches the answer, so a branch never switches
/// off its own stages. No tool is installed in the base checkout, and a
/// chosen stage still answers `run`.
#[test]
fn the_stage_policy_is_the_base_checkouts_committed_choice() {
    type Files<'a> = &'a [(&'a str, &'a str)];
    let cases: [(&str, Files, &[&str], bool); 4] = [
        ("unset", &[], &STAGE_WORDS, false),
        (
            "listed",
            &[(
                "kendex.settings.toml",
                "[env]\nORCH_STAGES = \"preflight git-hooks\"\n",
            )],
            &["preflight", "git-hooks"],
            true,
        ),
        (
            "empty",
            &[("kendex.settings.toml", "[env]\nORCH_STAGES = \"\"\n")],
            &[],
            true,
        ),
        (
            "local settings over committed",
            &[
                (
                    "kendex.settings.toml",
                    "[env]\nORCH_STAGES = \"preflight\"\n",
                ),
                (
                    ".kendex/settings.toml",
                    "[env]\nORCH_STAGES = \"doc-limits\"\n",
                ),
            ],
            &["doc-limits"],
            true,
        ),
    ];
    for (case, files, running, set) in cases {
        let w = World::new();
        fs::write(
            w.worktree.join("kendex.settings.toml"),
            "[env]\nORCH_STAGES = \"focused-proof\"\n",
        )
        .unwrap();
        let base = w.base_checkout(files);
        let caller = [("ORCH_STAGES", "local-review")];
        let all = ok(&w.policy(&base, None, &caller));
        let want: serde_json::Map<String, Value> = STAGE_WORDS
            .iter()
            .map(|word| {
                let answer = if running.contains(word) {
                    "run"
                } else {
                    "skip"
                };
                ((*word).to_owned(), json!(answer))
            })
            .collect();
        assert_eq!(all["stages"], Value::Object(want), "{case}");
        assert_eq!(all["set"], json!(set), "{case}");
        for word in STAGE_WORDS {
            let one = ok(&w.policy(&base, Some(word), &caller));
            assert_eq!(one["stage"], json!(word), "{case}");
            assert_eq!(one["answer"], all["stages"][word], "{case} {word}");
        }
    }

    let w = World::new();
    let base = w.base_checkout(&[
        (
            "kendex.settings.toml",
            "[env]\nORCH_STAGES = \"preflight\"\n",
        ),
        (
            ".kendex/settings.toml",
            "[env]\nORCH_STAGES = \"doc-limits\"\n",
        ),
        (
            ".env.local",
            "ORCH_STAGES=\"external-review local-review\"\n",
        ),
    ]);
    let running = |out: &Output| -> Vec<String> {
        let stages = ok(out)["stages"].clone();
        STAGE_WORDS
            .iter()
            .filter(|word| stages[**word] == "run")
            .map(|word| (*word).to_owned())
            .collect()
    };
    assert_eq!(
        running(&w.policy(&base, None, &[])),
        ["doc-limits"],
        "--no-private-env"
    );
    assert_eq!(
        running(&w.policy_reading_private(&base)),
        ["external-review", "local-review"],
        "the private file over both"
    );
}

/// A stage policy outside its form refuses by name and answers no stage: a
/// word outside the six by the key and the value as written, so a
/// misspelt stage is never silently skipped; a base checkout that is not a
/// directory by its field, since its absent files would read as the
/// default; a `--stage` word outside the six at the command line.
#[test]
fn a_stage_policy_outside_its_form_refuses_by_name() {
    let w = World::new();
    let base = w.base_checkout(&[(
        "kendex.settings.toml",
        "[env]\nORCH_STAGES = \"preflight gti-hooks\"\n",
    )]);
    let out = w.policy(&base, Some("preflight"), &[]);
    assert_eq!(refusal(&out), "setting-invalid");
    assert_eq!(
        reply(&out)["refusal"]["fields"],
        json!([["key", "ORCH_STAGES"], ["value", "preflight gti-hooks"]])
    );
    let absent = w.root.join("absent");
    let out = w.policy(&absent, None, &[]);
    assert_eq!(refusal(&out), "field-invalid");
    assert_eq!(
        reply(&out)["refusal"]["fields"],
        json!([
            ["field", "base_checkout"],
            ["value", absent.display().to_string()]
        ])
    );
    let out = w.policy(&base, Some("benchmark"), &[]);
    assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
    assert!(out.stdout.is_empty());
}

// --- the end notice's reach, with two checkouts' mailbox programs ---

/// The real mailbox program, behind each checkout's recorder.
fn real_lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap()
}

impl World {
    /// A second checkout, `other`, beside the world's worktree, and in each
    /// a mailbox program at the install path (`.agents/skills/mailbox/
    /// scripts/lane-mail`) that appends the directory it runs in and its
    /// words to `<root>/mail-<checkout>.log` and runs the real program. A
    /// row run through [`World::run_in`] names no `LANE_MAIL_CLI`, so each
    /// checkout's settings name its own recorder: a notice sent through the
    /// wrong program, or in the wrong directory, lands in `other`'s
    /// mailbox and its record, inside the root.
    fn two_mailboxes(&self) -> PathBuf {
        let other = self.root.join("other");
        fs::create_dir_all(&other).unwrap();
        git(&other, &["init", "-q", "-b", "main"]);
        git(&other, &["config", "gc.auto", "0"]);
        git(&other, &["config", "maintenance.auto", "false"]);
        fs::write(other.join(".gitignore"), "tmp\n.agents\n").unwrap();
        git(&other, &["add", ".gitignore"]);
        git(&other, &["commit", "-q", "-m", "base"]);
        for checkout in [&self.worktree, &other] {
            let mailbox = checkout.join(".agents/skills/mailbox");
            if fs::symlink_metadata(&mailbox).is_ok() {
                fs::remove_file(&mailbox).unwrap();
            }
            fs::create_dir_all(mailbox.join("scripts")).unwrap();
            support::write_executable(
                &mailbox.join("scripts/lane-mail"),
                format!(
                    "#!/bin/sh\nprintf '%s %s\\n' \"$(pwd -P)\" \"$*\" >> '{}'\nexec '{}' \"$@\"\n",
                    self.mail_log(checkout).display(),
                    real_lane_mail().display()
                ),
            );
        }
        other
    }

    fn mail_log(&self, checkout: &Path) -> PathBuf {
        self.root.join(format!(
            "mail-{}.log",
            checkout.file_name().unwrap().to_string_lossy()
        ))
    }

    /// The calls `checkout`'s recorder took: its directory, then its words.
    fn mail_calls(&self, checkout: &Path) -> Vec<String> {
        fs::read_to_string(self.mail_log(checkout))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The binary run from `cwd` with the world's environment but its
    /// `LANE_MAIL_CLI`.
    fn run_in(&self, cwd: &Path, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut command = support::isolated();
        command.args(args).current_dir(cwd);
        for (k, v) in self.env() {
            if k != "LANE_MAIL_CLI" {
                command.env(k, v);
            }
        }
        for (k, v) in extra {
            command.env(k, v);
        }
        command.output().unwrap()
    }

    /// The end notice of the run in `dir` landed once in `checkout`'s
    /// mailbox, through `checkout`'s own program run there, and `other`'s
    /// program and mailbox took nothing.
    fn notice_landed_in(&self, checkout: &Path, other: &Path, dir: &str) {
        let inbox = |at: &Path| at.join("tmp/lane-mail").join(ITEM_ID).join("to-lane.jsonl");
        let landed = fs::read_to_string(inbox(checkout)).unwrap_or_default();
        assert_eq!(landed.lines().count(), 1, "{landed}");
        assert!(landed.contains(&format!("run-dir={dir} ")), "{landed}");
        let calls = self.mail_calls(checkout);
        assert_eq!(
            calls
                .iter()
                .filter(|c| c.starts_with(&format!(
                    "{} send --item {ITEM_ID} --directive ",
                    checkout.display()
                )))
                .count(),
            1,
            "{calls:?}"
        );
        assert_eq!(self.mail_calls(other), Vec::<String>::new());
        assert!(
            fs::symlink_metadata(other.join("tmp/lane-mail")).is_err(),
            "nothing landed in the other checkout"
        );
    }
}

/// A foreground validation the entry runs for a named worktree, from a
/// shell standing in another checkout, sends its end notice through the
/// worktree checkout's own mailbox program run in that checkout: the notice
/// lands in the worktree's mailbox, never the other checkout's.
#[test]
fn a_foreground_entry_run_from_another_checkout_sends_its_notice_through_the_named_worktrees_mailbox()
 {
    let w = World::new();
    let other = w.two_mailboxes();
    let admitted = ok(&w.op(
        &json!({"op":"record-validation-admission","round_id":ROUND}),
        &[],
    ));
    let id = admitted["report"]["run_id"].as_str().unwrap();
    let dir = admitted["report"]["run_dir"].as_str().unwrap();
    let wt = w.worktree.display().to_string();
    let out = w.run_in(
        &other,
        &[
            "--state-dir",
            w.state.to_str().unwrap(),
            "validate",
            "entry",
            "--worktree",
            &wt,
            "--foreground",
            "--poll",
            "1",
            "--run-id",
            id,
        ],
        &[],
    );
    assert!(out.status.success(), "{} {}", text(&out), stderr(&out));
    assert_eq!(w.stage(dir)["notice"]["owner"], "sent");
    w.notice_landed_in(&w.worktree, &other, dir);
}

/// `words` without `flag` and the value after it, which stands there.
fn without<'a>(words: &[&'a str], flag: &str) -> Vec<&'a str> {
    let at = words
        .iter()
        .position(|w| *w == flag)
        .unwrap_or_else(|| panic!("no {flag} in {words:?}"));
    [&words[..at], &words[at + 2..]].concat()
}

/// A detached validation run reaches only the mailbox its start named. The
/// entry, run for a named worktree from a shell standing in another
/// checkout, launches the run with the worktree checkout's mailbox on its
/// command line; the run started as launched, in the shell's directory,
/// sends its end notice through that program run in that checkout. Started
/// without either flag it refuses `mailbox-unnamed` naming the flag before
/// it runs anything, with no mailbox program asked.
#[test]
fn a_detached_validation_run_sends_through_the_mailbox_its_start_named_and_refuses_without_one() {
    let w = World::new();
    let other = w.two_mailboxes();
    let (path, manager) = manager(&w);
    let admitted = ok(&w.op(
        &json!({"op":"record-validation-admission","round_id":ROUND}),
        &[],
    ));
    let id = admitted["report"]["run_id"].as_str().unwrap();
    let dir = admitted["report"]["run_dir"].as_str().unwrap();
    let wt = w.worktree.display().to_string();
    let state = w.state.display().to_string();
    let launch = [
        ("PATH", path.as_str()),
        ("VALIDATE_MANAGER_DIR", manager.as_str()),
        ("VALIDATE_START_ANSWER", "record-only"),
    ];
    let out = w.run_in(
        &other,
        &[
            "--state-dir",
            &state,
            "validate",
            "entry",
            "--worktree",
            &wt,
            "--poll",
            "1",
            "--budget",
            "1",
            "--run-id",
            id,
        ],
        &launch,
    );
    assert_eq!(directory(&out), dir);
    let (argv, _) = unit_launch(&manager, dir);
    // The run's words after its executable, as the manager would start it.
    let job: Vec<&str> = argv
        .iter()
        .map(String::as_str)
        .skip_while(|w| *w != "--")
        .skip(2)
        .collect();
    for (flag, field) in [
        ("--mail-program", "mail_program"),
        ("--mail-root", "mail_root"),
    ] {
        let out = w.run_in(&other, &without(&job, flag), &[]);
        assert_eq!(refusal(&out), "mailbox-unnamed", "{flag}");
        assert_eq!(
            reply(&out)["refusal"]["fields"],
            json!([["field", field]]),
            "{flag}"
        );
    }
    assert!(
        w.stage(dir)["end"].is_null(),
        "the refused runs ran nothing"
    );
    assert!(fs::symlink_metadata(Path::new(dir).join("exit")).is_err());
    assert_eq!(w.mail_calls(&w.worktree), Vec::<String>::new());
    assert_eq!(w.mail_calls(&other), Vec::<String>::new());
    let ended = ok(&w.run_in(&other, &job, &[]));
    assert_eq!(ended["closed_now"], true, "{ended}");
    assert_eq!(ended["notice"], "sent", "{ended}");
    w.notice_landed_in(&w.worktree, &other, dir);
}

/// A detached start from a process whose tmux server cannot be read (no
/// `$TMUX`, no numeric `$UID`, an `id` that answers nothing) launches its
/// run: the run sends only notices, so its command line names the fleet's
/// mailbox program and root and no server.
#[test]
fn a_detached_start_whose_tmux_server_cannot_be_read_launches_naming_the_fleets_mailbox_and_no_server()
 {
    let w = World::new();
    let other = w.two_mailboxes();
    let (_, manager) = manager(&w);
    let tools = w.root.join("no-uid");
    fs::create_dir_all(&tools).unwrap();
    support::write_executable(&tools.join("id"), "#!/bin/sh\nexit 1\n");
    let path = support::tool_path(&[&tools, &support::fixtures().join("validate-tools")]);
    let admitted = ok(&w.op(
        &json!({"op":"record-validation-admission","round_id":ROUND}),
        &[],
    ));
    let id = admitted["report"]["run_id"].as_str().unwrap();
    let dir = admitted["report"]["run_dir"].as_str().unwrap();
    let wt = w.worktree.display().to_string();
    let state = w.state.display().to_string();
    let out = w.run_in(
        &other,
        &[
            "--state-dir",
            &state,
            "validate",
            "entry",
            "--worktree",
            &wt,
            "--poll",
            "1",
            "--budget",
            "1",
            "--run-id",
            id,
        ],
        &[
            ("PATH", path.as_str()),
            ("VALIDATE_MANAGER_DIR", manager.as_str()),
            ("VALIDATE_START_ANSWER", "record-only"),
        ],
    );
    assert_eq!(directory(&out), dir, "{}", stderr(&out));
    let (argv, _) = unit_launch(&manager, dir);
    let job: Vec<&str> = argv
        .iter()
        .map(String::as_str)
        .skip_while(|w| *w != "--")
        .skip(2)
        .collect();
    let after = |flag: &str| {
        job.iter()
            .position(|w| *w == flag)
            .map(|at| job[at + 1].to_owned())
    };
    let program = w.worktree.join(".agents/skills/mailbox/scripts/lane-mail");
    assert_eq!(
        after("--mail-program").as_deref(),
        Some(program.to_str().unwrap()),
        "{job:?}"
    );
    assert_eq!(
        after("--mail-root").as_deref(),
        Some(w.worktree.to_str().unwrap()),
        "{job:?}"
    );
    assert!(!job.contains(&"--socket"), "{job:?}");
    assert_eq!(w.mail_calls(&w.worktree), Vec::<String>::new());
    assert_eq!(w.mail_calls(&other), Vec::<String>::new());
}

/// `orch-runtime pr ARGS` over the fake `gh` answering `replies`, run from
/// outside the worktree with the private env file read and no caller value
/// of either order key, so the settings it acts on are the worktree's own
/// files (`settings`, the `[env]` lines of its `kendex.settings.toml`, and
/// `private`, its `.env.local`). The output and every `gh` call, one line
/// each.
fn pr_verb(
    w: &World,
    args: &[&str],
    settings: &str,
    private: &str,
    replies: &Value,
) -> (Output, String) {
    fs::write(
        w.worktree.join("kendex.settings.toml"),
        format!("[env]\n{settings}"),
    )
    .unwrap();
    fs::write(w.worktree.join(".env.local"), private).unwrap();
    let file = w.root.join("gh.json");
    fs::write(&file, replies.to_string()).unwrap();
    let log = w.root.join("gh.log");
    let _ = fs::remove_file(&log);
    let out = program(support::binary())
        .current_dir(&w.root)
        .env("HOME", &w.root)
        .env("PATH", tool_path(&[&fixtures().join("validate-gh")]))
        .env("GH_FAKE_REPLIES", &file)
        .env("GH_FAKE_LOG", &log)
        .env_remove("KENDEX_ENV_FILE")
        .env_remove("ORCH_PR_ORDER")
        .env_remove("ORCH_DELIVERY")
        .env_remove("GH_REPO")
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .arg("pr")
        .args(args)
        .output()
        .unwrap();
    (out, fs::read_to_string(&log).unwrap_or_default())
}

/// The fake's answers for a checkout of `o/r` whose visibility gh prints
/// as `visibility`.
fn visible(visibility: &str) -> Value {
    json!({"repo view": {"text": "o/r\n"}, "repo view o/r": {"text": format!("{visibility}\n")}})
}

#[test]
fn the_publication_order_follows_visibility_only_where_unset() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    for (visibility, want) in [
        ("PRIVATE", "open-first"),
        ("PUBLIC", "review-first"),
        ("INTERNAL", "review-first"),
        ("private", "open-first"),
    ] {
        let (out, calls) = pr_verb(&w, &["order", &wt], "", "", &visible(visibility));
        assert_eq!(
            text(&out),
            format!("pr-order={want}"),
            "{visibility}: {}",
            stderr(&out)
        );
        assert_eq!(
            calls.lines().last(),
            Some("repo view o/r --json visibility --jq .visibility"),
            "{visibility}: {calls}"
        );
    }
}

#[test]
fn an_explicit_publication_order_wins_with_no_github_read() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    for order in ["review-first", "open-first", "push-first"] {
        for visibility in ["PRIVATE", "PUBLIC"] {
            let setting = format!("ORCH_PR_ORDER = \"{order}\"\n");
            let (out, calls) = pr_verb(&w, &["order", &wt], &setting, "", &visible(visibility));
            assert_eq!(text(&out), format!("pr-order={order}"), "{}", stderr(&out));
            assert_eq!(calls, "", "{order} {visibility}");
        }
    }
    // Direct delivery reviews before publication, whatever the order.
    for order in ["", "open-first", "push-first"] {
        let mut setting = "ORCH_DELIVERY = \"push-base\"\n".to_owned();
        if !order.is_empty() {
            setting.push_str(&format!("ORCH_PR_ORDER = \"{order}\"\n"));
        }
        let (out, calls) = pr_verb(&w, &["order", &wt], &setting, "", &visible("PRIVATE"));
        assert_eq!(
            text(&out),
            "pr-order=review-first",
            "{order}: {}",
            stderr(&out)
        );
        assert_eq!(calls, "", "push-base {order}");
    }
}

#[test]
fn an_unreadable_or_unknown_publication_order_refuses() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    for (setting, private, key, named) in [
        (
            "ORCH_PR_ORDER = \"bogus\"\n",
            "",
            "setting-invalid",
            "key=ORCH_PR_ORDER",
        ),
        (
            "",
            "ORCH_PR_ORDER=$(echo open-first)\n",
            "setting-unread",
            "key=ORCH_PR_ORDER",
        ),
        (
            "",
            "ORCH_DELIVERY=$(echo push-base)\n",
            "setting-unread",
            "key=ORCH_DELIVERY",
        ),
    ] {
        let (out, calls) = pr_verb(&w, &["order", &wt], setting, private, &visible("PRIVATE"));
        assert_eq!(refusal(&out), key, "{setting}{private}");
        assert!(stderr(&out).contains(named), "{}", stderr(&out));
        assert_eq!(calls, "", "{setting}{private}");
    }
}

#[test]
fn an_unread_visibility_reviews_first() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    for (replies, cause) in [
        (
            json!({"repo view": {"text": "o/r\n"}}),
            "cause=visibility-read-failed repo=o/r",
        ),
        (
            visible("SECRET"),
            "cause=visibility-response-invalid repo=o/r",
        ),
        (json!({}), "cause=repo-unresolved"),
    ] {
        let (out, _) = pr_verb(&w, &["order", &wt], "", "", &replies);
        assert_eq!(
            text(&out),
            "pr-order=review-first",
            "{cause}: {}",
            stderr(&out)
        );
        assert!(
            stderr(&out).contains(&format!("pr-order-visibility-unread {cause}")),
            "{cause}: {}",
            stderr(&out)
        );
    }
}

#[test]
fn a_missing_pull_request_is_told_apart_from_a_failed_read() {
    let w = World::new();
    let wt = w.worktree.display().to_string();
    let open = json!({"number": 7, "state": "OPEN", "baseRefName": "main"});
    let (out, calls) = pr_verb(
        &w,
        &["view", &wt, "--json", "number,state"],
        "",
        "",
        &json!({"pr view --json": {"body": open}}),
    );
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(
        serde_json::from_str::<Value>(&text(&out)).unwrap(),
        json!({"number": 7, "state": "OPEN"})
    );
    assert_eq!(calls.lines().last(), Some("pr view --json number,state"));
    let (out, calls) = pr_verb(
        &w,
        &["view", &wt, "42", "--json", "state"],
        "",
        "",
        &json!({"pr view 42": {"body": open}}),
    );
    assert_eq!(text(&out), r#"{"state":"OPEN"}"#, "{}", stderr(&out));
    assert_eq!(calls.lines().last(), Some("pr view 42 --json state"));
    // gh's words for a branch with no pull request, and for a read that
    // failed.
    let (out, _) = pr_verb(
        &w,
        &["view", &wt, "--json", "number"],
        "",
        "",
        &json!({"pr view --json": {"exit": 1, "stderr": "no pull requests found for branch \"main\""}}),
    );
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert_eq!(
        serde_json::from_str::<Value>(&text(&out)).unwrap(),
        json!({"status": "no_pr", "number": null})
    );
    let (out, _) = pr_verb(
        &w,
        &["view", &wt, "--json", "number"],
        "",
        "",
        &json!({"pr view --json": {"exit": 1, "stderr": "HTTP 502: Bad Gateway"}}),
    );
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    assert_eq!(text(&out), "");
    assert!(
        stderr(&out).starts_with("pr-view: cause=pull-request-read-failed"),
        "{}",
        stderr(&out)
    );
}

/// A lane on this disk whose admitted run goes to a static ssh host: the
/// shipped provider's validation row, its clone made from the host's
/// source and holding the lane's base, and a lane commit that carries the
/// render the unit's setup and executor read, with `settings` added to the
/// lane's committed settings, which the host reads and the lane's own
/// environment outranks here. The lane declares `command` in its
/// environment, which its start resolves into the run's proof.
struct HostLane {
    w: World,
    host: support::SshHost,
    base: String,
    command: &'static str,
    id: String,
    dir: String,
}

/// A host command that outlasts the first read of its run.
const HOST_COMMAND: &str = "sleep 2 && echo 'validate: lanes=unit selection=all'";
/// A host command that outlasts the rows that act during it.
const LONG_COMMAND: &str = "sleep 20 && echo 'validate: lanes=unit selection=all'";

impl HostLane {
    fn new(command: &'static str) -> HostLane {
        HostLane::with(command, "", |_| {})
    }

    /// The lane with `settings` appended to its committed settings and
    /// `render` given the lane's worktree before the lane commit.
    fn with(command: &'static str, settings: &str, render: impl Fn(&Path)) -> HostLane {
        let w = World::new();
        let base = w.head();
        let root = w.root.join("host");
        fs::create_dir_all(&root).unwrap();
        let host = support::SshHost::new(&root, &root.join("scripts"), "validation");
        let clone = host.clone().display().to_string();
        let out = program("git")
            .args(["clone", "-q"])
            .arg(host.source())
            .arg(&clone)
            .output()
            .unwrap();
        assert!(out.status.success(), "clone: {}", stderr(&out));
        git(host.clone().as_path(), &["config", "gc.auto", "0"]);
        git(
            host.clone().as_path(),
            &["config", "maintenance.auto", "false"],
        );
        git(
            host.clone().as_path(),
            &[
                "fetch",
                "-q",
                &w.worktree.display().to_string(),
                "refs/remotes/origin/main",
            ],
        );
        if !settings.is_empty() {
            let path = w.worktree.join("kendex.settings.toml");
            let text = fs::read_to_string(&path).unwrap();
            fs::write(&path, format!("{text}{settings}")).unwrap();
        }
        render(&w.worktree);
        git(
            &w.worktree,
            &["add", "-f", ".agents", "kendex.settings.toml"],
        );
        git(&w.worktree, &["commit", "-q", "-m", "lane"]);
        let mut lane = HostLane {
            w,
            host,
            base,
            command,
            id: String::new(),
            dir: String::new(),
        };
        lane.admit(json!({"op":"record-validation-admission","round_id":ROUND}));
        lane
    }

    /// The round's admission `request` names the lane's run.
    fn admit(&mut self, request: Value) {
        let admitted = ok(&self.w.op(&request, &[]));
        self.id = admitted["report"]["run_id"].as_str().unwrap().to_owned();
        self.dir = admitted["report"]["run_dir"].as_str().unwrap().to_owned();
    }

    /// The host run's caller, each call after a run read running one
    /// second apart, `extra` in its environment.
    fn spawn(&self, host: &str, extra: &[(&str, &str)]) -> std::process::Child {
        let wt = self.w.worktree.display().to_string();
        let mut command = support::isolated();
        command
            .arg("--state-dir")
            .arg(&self.w.state)
            .args([
                "validate",
                "entry",
                "--worktree",
                &wt,
                "--run-id",
                &self.id,
                "--host",
                host,
                "--poll",
                "1",
            ])
            .current_dir(&self.w.worktree)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        for (k, v) in self.w.env() {
            command.env(k, v);
        }
        command.env("DEV_VALIDATE_CMD", self.command);
        for (k, v) in extra {
            command.env(k, v);
        }
        command.spawn().unwrap()
    }

    /// The host run to its end, which a row that breaks the executor's
    /// ending reads as a failure within the job bound, never a hang.
    fn run_with(&self, host: &str, extra: &[(&str, &str)]) -> Output {
        let mut child = self.spawn(host, extra);
        let deadline = Instant::now() + JOB_BOUND;
        while child.try_wait().unwrap().is_none() {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let out = child.wait_with_output().unwrap();
                panic!(
                    "the host run did not end within {JOB_BOUND:?}\n{}\n{}",
                    text(&out),
                    stderr(&out)
                );
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        child.wait_with_output().unwrap()
    }

    fn run(&self, host: &str) -> Output {
        self.run_with(host, &[])
    }

    /// How many of the provider's SSH calls ran a line holding `text`.
    fn ssh_calls(&self, text: &str) -> usize {
        fs::read_to_string(self.host.tools.join("ssh-provider.log"))
            .unwrap_or_default()
            .lines()
            .filter(|line| line.contains(text))
            .count()
    }

    /// The run's unit on the host.
    fn unit(&self) -> PathBuf {
        self.host
            .clone()
            .join("tmp/validate-host")
            .join(ITEM_ID)
            .join(&self.id)
    }

    /// The host's copy of the run: in the unit tree's tmp, under the name
    /// the lane's start gave its own folder, which keys its launch.
    fn host_run(&self) -> PathBuf {
        self.unit()
            .join("tree/tmp")
            .join(Path::new(&self.dir).file_name().unwrap())
    }

    /// The run passed as a local admitted run does: its stage holds the
    /// proof and closes pass with its notice sent, `read-proof` reads its
    /// tree complete for the round, the run index lists it, its record
    /// names the host and the lane's commit, the host's process records
    /// stay behind and the host's unit is removed.
    fn assert_returned(&self, out: &Output) {
        assert_eq!(
            out.status.code(),
            Some(0),
            "{}\n{}\n{:?}",
            text(out),
            stderr(out),
            self.host.calls()
        );
        assert_eq!(directory(out), self.dir);
        let done = text(out);
        let done = done.lines().last().unwrap();
        assert_eq!(field(done, "state"), "done", "{done}");
        assert_eq!(field(done, "validate"), "pass", "{done}");
        let stage = self.w.wait_marked(&self.dir);
        assert_eq!(stage["outcome"], "pass", "{stage}");
        assert_eq!(stage["proof"]["cmd"], self.command, "{stage}");
        let tree = git(&self.w.worktree, &["rev-parse", "HEAD^{tree}"]);
        let read = self.w.read_proof(
            &["--need", "round", "--tree", &tree, "--base", &self.base],
            &[("DEV_VALIDATE_CMD", self.command)],
        );
        assert_eq!(read["proof"], "complete", "{read}");
        let index = fs::read_to_string(self.w.worktree.join("tmp/validation-runs")).unwrap();
        let name = Path::new(&self.dir).file_name().unwrap().to_str().unwrap();
        assert!(index.lines().any(|line| line == name), "{index}");
        let record = read_record(&self.w, &self.dir);
        assert_eq!(field(&record, "verdict"), "pass", "{record}");
        assert_eq!(field(&record, "host"), self.host.provider(), "{record}");
        assert_eq!(field(&record, "head"), self.w.head(), "{record}");
        assert_eq!(field(&record, "tree"), tree, "{record}");
        assert_eq!(field(&record, "lanes"), "unit", "{record}");
        for record in ["executor", "execution", "command", "pid"] {
            assert!(!Path::new(&self.dir).join(record).exists(), "{record}");
        }
        assert!(!self.unit().exists(), "the host's unit is removed");
    }
}

/// A run on the host runs the lane's start's proof at the lane's commit
/// with the runtime the commit's own tree builds, one step per provider
/// call, and is read again until it ends; its outputs then come back into
/// the run directory the start wrote, and the stage closes as a local
/// run's does. A build of the unit's runtime still running is asked about
/// again only after the poll.
#[test]
fn a_host_run_returns_its_folder_to_the_admitted_directory_naming_the_host() {
    let skills = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap();
    // The tree's orch render answers its first setup as a build still
    // running and every later one through the shipped setup, each ask's
    // time logged outside the unit, which the run's end removes.
    let marks = tempfile::tempdir().unwrap();
    let asked = marks.path().join("asked");
    let lane = HostLane::with(HOST_COMMAND, "", |wt| {
        let orch = wt.join(".agents/skills/orch");
        fs::remove_file(&orch).unwrap();
        fs::create_dir_all(orch.join("scripts")).unwrap();
        for entry in fs::read_dir(skills.join("orch")).unwrap().flatten() {
            if entry.file_name() != "scripts" {
                std::os::unix::fs::symlink(entry.path(), orch.join(entry.file_name())).unwrap();
            }
        }
        for entry in fs::read_dir(skills.join("orch/scripts")).unwrap().flatten() {
            if entry.file_name() != "setup" {
                std::os::unix::fs::symlink(
                    entry.path(),
                    orch.join("scripts").join(entry.file_name()),
                )
                .unwrap();
            }
        }
        support::write_executable(
            &orch.join("scripts/setup"),
            format!(
                "#!/bin/bash\ndate +%s.%N >> '{asked}'\nif [ ! -e '{asked}.built' ]; then : > '{asked}.built'; echo 'orch-runtime-setup: runtime-building key=row log=row'; exit 0; fi\nexec '{setup}' \"$@\"\n",
                asked = asked.display(),
                setup = skills.join("orch/scripts/setup").display()
            ),
        );
    });
    let out = lane.run(&lane.host.provider());
    lane.assert_returned(&out);
    assert_eq!(lane.ssh_calls("/tree/.agents/skills/orch/scripts/setup"), 2);
    let asks = setup_asks(&asked);
    assert_eq!(asks.len(), 2, "{asks:?}");
    assert!(
        asks[1] - asks[0] >= 1.0,
        "asked again before the poll: {asks:?}"
    );
    assert_eq!(lane.ssh_calls("validate entry --host-child"), 1);
    assert!(lane.ssh_calls("validate entry --wait --run-dir") >= 1);
    let calls = lane.host.calls();
    let validate = format!(" validate --item {ITEM_ID} --run-id {}", lane.id);
    assert!(calls[0].ends_with(" capabilities"), "{calls:?}");
    assert!(
        calls[1..].iter().all(|call| call.contains(&validate)),
        "{calls:?}"
    );
}

/// The times the building row's unit asked its tree's setup.
fn setup_asks(log: &Path) -> Vec<f64> {
    fs::read_to_string(log)
        .unwrap()
        .lines()
        .map(|line| line.parse().unwrap())
        .collect()
}

/// A launch whose connection drops after the host launched the run keeps
/// the unit, and the executor's next call reads that run to its end: one
/// launch, and the stage closes pass.
#[test]
fn a_host_launch_cut_off_after_the_host_acted_is_read_on_the_next_call() {
    let lane = HostLane::new(HOST_COMMAND);
    fs::write(
        lane.host.tools.join("drop-on"),
        "validate entry --host-child",
    )
    .unwrap();
    let out = lane.run(&lane.host.provider());
    lane.assert_returned(&out);
    assert_eq!(lane.ssh_calls("validate entry --host-child"), 1);
    assert!(!lane.host.tools.join("drop-on").exists(), "the drop ran");
}

/// A launch the host's runtime refuses, here a memory need the host's room
/// cannot hold, ends the run no-verdict with that cause and launches no
/// more. With a finding prefix declared, the run is no finding-free last
/// pass: its command never ran.
#[test]
fn a_host_launch_refused_ends_the_run_no_verdict_and_never_a_last_pass() {
    let lane = HostLane::with(
        HOST_COMMAND,
        "ORCH_VALIDATE_MEMORY_MAX = \"1023T\"\n",
        |_| {},
    );
    let lane_env = [
        ("ORCH_VALIDATE_MEMORY_MAX", "2G"),
        ("DEV_VALIDATE_FINDING_PREFIX", "guard: "),
    ];
    let out = lane.run_with(&lane.host.provider(), &lane_env);
    assert_eq!(
        out.status.code(),
        Some(1),
        "{}\n{}",
        text(&out),
        stderr(&out)
    );
    let done = text(&out);
    let done = done.lines().last().unwrap();
    assert_eq!(field(done, "validate"), "no-verdict", "{done}");
    let stage = lane.w.wait_marked(&lane.dir);
    assert_eq!(stage["outcome"], "no-verdict", "{stage}");
    let wt = lane.w.worktree.display().to_string();
    let last = lane.w.entry(&["--last-pass", "--worktree", &wt], &lane_env);
    assert_eq!(last.status.code(), Some(1), "{}", text(&last));
    assert_eq!(
        text(&last),
        format!("last-pass=red run-dir={}", lane.dir),
        "the run reads red, never a finding-free pass"
    );
    let log = run_file(&lane.dir, "log");
    assert!(
        log.lines().any(
            |line| line.starts_with("guard: validate-host: host-launch-refused")
                && line.contains("memory-short")
        ),
        "{log}"
    );
    assert_eq!(lane.ssh_calls("validate entry --host-child"), 1);
    assert!(!lane.unit().exists(), "the refused unit is removed");
}

/// A folder an earlier call staged for this run's commit is taken back
/// before the next call: the run closes with its verdict, and the unit
/// that call left on the host is stopped and removed.
#[test]
fn a_staged_host_result_is_taken_back_before_the_next_call() {
    let lane = HostLane::new(LONG_COMMAND);
    let mut holder = Owned(lane.spawn(&lane.host.provider(), &[]));
    until(|| lane.host_run().join("runner").exists());
    let staged = Path::new(&lane.dir).with_file_name(format!(
        "host-{}",
        Path::new(&lane.dir).file_name().unwrap().to_str().unwrap()
    ));
    let part = staged.with_extension("part");
    fs::create_dir_all(&part).unwrap();
    fs::write(part.join("start"), format!("head={}\n", lane.w.head())).unwrap();
    fs::write(
        part.join("log"),
        "runner=setsid\nvalidate: lanes=staged selection=all\n",
    )
    .unwrap();
    fs::write(
        part.join("timing"),
        "started-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:00:01Z\nseconds=1\n",
    )
    .unwrap();
    fs::write(part.join("exit"), "guard-exit=0 at=2026-01-01T00:00:01Z\n").unwrap();
    fs::rename(&part, &staged).unwrap();
    let deadline = Instant::now() + JOB_BOUND;
    while holder.0.try_wait().unwrap().is_none() {
        assert!(
            Instant::now() < deadline,
            "the staged result was never taken"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(holder.0.wait().unwrap().success());
    let stage = lane.w.wait_marked(&lane.dir);
    assert_eq!(stage["outcome"], "pass", "{stage}");
    assert_eq!(field(&read_record(&lane.w, &lane.dir), "lanes"), "staged");
    assert!(!staged.exists());
    assert!(
        !lane.unit().exists(),
        "the unit the earlier call left is removed"
    );
}

/// Each host start that cannot run refuses by its key and leaves the key on
/// the admitted stage, which a wait by the run's id reads; nothing lands in
/// the admitted directory. A host whose capability line declares no
/// `validate`, a provider that predates the verb or the local kind, is
/// never asked it.
#[test]
fn a_host_start_that_cannot_run_refuses_by_key_on_the_admitted_stage() {
    let lane = HostLane::new(HOST_COMMAND);
    let wt = lane.w.worktree.display().to_string();
    let broker = support::named_host(&lane.w.root, "broker");
    fs::write(
        lane.w.root.join("lane-host.json"),
        json!({"capabilities": {"stdout": "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=local\n"}}).to_string(),
    )
    .unwrap();
    let edited = lane.w.worktree.join("a.txt");
    let untracked = lane.w.worktree.join("notes.txt");
    for (case, host, plant, key) in [
        (
            "a tracked change the commit lacks",
            lane.host.provider(),
            Some(&edited),
            "host-tree-uncommitted",
        ),
        (
            "an untracked file the project does not ignore",
            lane.host.provider(),
            Some(&untracked),
            "host-tree-uncommitted",
        ),
        (
            "a provider whose line declares no validate",
            broker.clone(),
            None,
            "host-validate-undeclared",
        ),
        (
            "the local kind",
            "local".to_owned(),
            None,
            "host-validate-undeclared",
        ),
    ] {
        if let Some(path) = plant {
            fs::write(path, "edited\n").unwrap();
        }
        let out = lane.run(&host);
        assert_eq!(out.status.code(), Some(2), "{case}: {}", stderr(&out));
        assert!(
            keyed(&out).starts_with(&format!("validate: {key}")),
            "{case}: {}",
            keyed(&out)
        );
        assert_eq!(lane.w.stage(&lane.dir)["refused"], key, "{case}");
        let waited = lane
            .w
            .entry(&["--wait", "--worktree", &wt, "--run-id", &lane.id], &[]);
        assert!(
            stderr(&waited).contains("start-refused"),
            "{case}: {}",
            stderr(&waited)
        );
        assert!(!Path::new(&lane.dir).exists(), "{case}");
        git(&lane.w.worktree, &["checkout", "--", "a.txt"]);
        let _ = fs::remove_file(&untracked);
    }
    let asked = fs::read_to_string(lane.w.root.join("lane-host.log")).unwrap();
    assert!(!asked.contains(" validate "), "{asked}");
    for (case, extra, key) in [
        (
            "a run with no admitted id",
            vec![],
            "read=required cause=--run-id",
        ),
        (
            "a host run held to a budget",
            vec!["--budget", "5"],
            "read=option-unused cause=--budget",
        ),
    ] {
        let mut args = vec!["--worktree", wt.as_str(), "--host", broker.as_str()];
        args.extend(extra.iter().copied());
        if key.starts_with("read=option-unused") {
            args.extend(["--run-id", lane.id.as_str()]);
        }
        let out = lane.w.entry(&args, &[]);
        assert_eq!(out.status.code(), Some(2), "{case}: {}", stderr(&out));
        assert_eq!(
            keyed(&out),
            format!("validate: validate-unreadable {key}"),
            "{case}"
        );
    }
    // The start that then runs clears the refusal it follows.
    lane.assert_returned(&lane.run(&lane.host.provider()));
    assert!(lane.w.stage(&lane.dir)["refused"].is_null());
}

/// A stop of the lane's worktree during a live host run ends the host's
/// run and removes its unit, and the stage closes stopped.
#[test]
fn a_worktree_stop_ends_a_live_host_run_on_its_host() {
    let lane = HostLane::new(LONG_COMMAND);
    let wt = lane.w.worktree.display().to_string();
    let mut holder = Owned(lane.spawn(&lane.host.provider(), &[]));
    until(|| lane.host_run().join("runner").exists());
    let stop = lane.w.entry(&["--stop", "--worktree", &wt], &[]);
    assert_eq!(stop.status.code(), Some(0), "{}", stderr(&stop));
    let stage = lane.w.stage(&lane.dir);
    assert!(!stage["end"].is_null(), "{stage}");
    assert_eq!(
        field(&read_record(&lane.w, &lane.dir), "verdict"),
        "no-verdict"
    );
    assert!(holder.0.wait().is_ok());
    assert!(
        !lane.unit().exists(),
        "the host's run is stopped and its unit removed"
    );
}

/// A host run is held by its caller, as a foreground run is: while the
/// caller follows it, the round's reconcile keeps its stage open and a wait
/// by its id reads it running; once the caller is gone, the wait reads it
/// lost, never queued. The round's next host start then stops the run the
/// gone caller left and removes its unit, so it never holds the host beside
/// the new run. On a host with a user manager each run's copy launches in a
/// unit of its own run, so two runs never share one.
#[test]
fn a_host_run_is_held_by_its_caller_through_a_reconcile_and_read_lost_without_it() {
    let mut lane = HostLane::new(LONG_COMMAND);
    let manager = lane.w.root.join("manager");
    for tool in ["systemd-run", "systemctl", "loginctl"] {
        support::write_executable(
            &lane.host.tools.join(tool),
            format!(
                "#!/bin/sh\nVALIDATE_MANAGER_DIR='{}' exec '{}' \"$@\"\n",
                manager.display(),
                fixtures().join("validate-tools").join(tool).display()
            ),
        );
    }
    let wt = lane.w.worktree.display().to_string();
    let holder = Owned(lane.spawn(&lane.host.provider(), &[]));
    until(|| lane.host_run().join("runner").exists());
    ok(&lane
        .w
        .op(&json!({"op":"reconcile-round","round_id":ROUND}), &[]));
    let stage = lane.w.stage(&lane.dir);
    assert!(stage["end"].is_null(), "{stage}");
    let running = lane.w.entry(
        &[
            "--wait",
            "--worktree",
            &wt,
            "--run-id",
            &lane.id,
            "--budget",
            "1",
        ],
        &[],
    );
    assert_eq!(running.status.code(), Some(3), "{}", stderr(&running));
    assert_eq!(
        field(text(&running).lines().last().unwrap(), "state"),
        "running"
    );
    drop(holder);
    let lost = lane.w.entry(
        &[
            "--wait",
            "--worktree",
            &wt,
            "--run-id",
            &lane.id,
            "--budget",
            "30",
        ],
        &[],
    );
    let line = text(&lost);
    let line = line.lines().last().unwrap();
    assert_eq!(field(line, "state"), "lost", "{line}");
    assert_eq!(field(line, "validate"), "FAILING", "{line}");
    let orphan = lane.unit();
    assert!(orphan.exists(), "the gone caller left its unit");
    let first = lane.id.clone();
    lane.command = HOST_COMMAND;
    lane.admit(json!({"op":"record-validation-admission","round_id":ROUND,"attempt":"next"}));
    lane.assert_returned(&lane.run(&lane.host.provider()));
    assert!(!orphan.exists(), "the next host start removed the orphan");
    let launches = fs::read_to_string(manager.join("launches")).unwrap();
    let units: Vec<&str> = launches.lines().collect();
    assert_eq!(units.len(), 2, "{launches}");
    assert!(units[0].contains(&first), "{launches}");
    assert!(units[1].contains(&lane.id), "{launches}");
    let stops = fs::read_to_string(manager.join("stops")).unwrap_or_default();
    assert!(
        stops.lines().any(|unit| unit == units[0]),
        "the orphan's run is stopped on its host: {stops}"
    );
}
