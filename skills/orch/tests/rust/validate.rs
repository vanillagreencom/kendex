//! The validation run: `validate start` and `validate run` through the built
//! binary, against a worktree, the child fixture that writes a planted
//! sentinel, the launcher fixtures, the classifier fixtures and a mailbox
//! that snapshots the record at the send. Every child a row starts goes
//! through `support::program`; the detached job the real launcher starts
//! inherits the binary's own environment.
//!
//! The rows replace `tests/dev_validate_run.sh`'s mode-resolution rows
//! (`744fd5727:skills/orch/tests/dev_validate_run.sh:600-682`, "The mode
//! picks the command" and "--resolve-mode names the mode") and its
//! `--run-id` rows (`:1109-1154`, "the directory the admission named"),
//! whose guarantees the runtime now holds.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests run the built binary and hold owned children"
)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{Duration, Instant};

mod support;

use serde_json::{Value, json};
use support::{Owned, fixtures, program, reply, stderr, tool_path, write_executable};

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
/// The fixture's open dev round.
const ROUND: &str = "1769600000123456789-1837";
const ITEM_ID: &str = "KEN-4687";
/// How long a row waits on a record the detached job writes.
const JOB_BOUND: Duration = Duration::from_secs(60);

/// One row's world: a state directory with the item, a worktree with one
/// commit, and the logs the fixtures append to.
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
        // The run directories live under `tmp/`, which the project ignores,
        // so a start's own records never move the snapshot tree.
        fs::write(worktree.join(".gitignore"), "tmp\n").unwrap();
        git(&worktree, &["add", "a.txt", ".gitignore"]);
        git(&worktree, &["commit", "-q", "-m", "base"]);
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

    /// A second commit on the branch; the base of a fix round is the first.
    fn commit(&self, name: &str) -> String {
        fs::write(self.worktree.join(name), format!("{name}\n")).unwrap();
        git(&self.worktree, &["add", name]);
        git(&self.worktree, &["commit", "-q", "-m", name]);
        git(&self.worktree, &["rev-parse", "HEAD"])
    }

    fn head(&self) -> String {
        git(&self.worktree, &["rev-parse", "HEAD"])
    }

    fn log(&self, name: &str) -> PathBuf {
        self.root.join(format!("{name}.log"))
    }

    fn log_lines(&self, name: &str) -> Vec<String> {
        fs::read_to_string(self.log(name))
            .map(|t| t.lines().map(str::to_owned).collect())
            .unwrap_or_default()
    }

    /// The environment every binary and every child of the real launcher
    /// carries: the fixtures as the executor, the classifier, the
    /// launcher and the mailbox, the declaration, and the logs.
    fn env(&self) -> Vec<(String, String)> {
        let f = fixtures();
        let s = |p: PathBuf| p.display().to_string();
        vec![
            (
                "DEV_VALIDATE_CLI".into(),
                s(f.join("dev-validate-child/dev-validate-run")),
            ),
            (
                "CHANGE_SCOPE_PATHS_CLI".into(),
                s(f.join("change-scope-fixture/harness-only")),
            ),
            ("ORCH_JOB_UNIT".into(), s(f.join("job-unit-real/job-unit"))),
            ("JOB_UNIT_REAL".into(), s(support::job_unit())),
            (
                "LANE_MAIL_CLI".into(),
                s(f.join("lane-mail-validate/lane-mail")),
            ),
            ("DEV_VALIDATE_CMD".into(), "echo full".into()),
            ("DEV_VALIDATE_TIMEOUT_SECS".into(), "20".into()),
            ("DEV_VALIDATE_LOG".into(), s(self.log("child"))),
            ("JOB_UNIT_LOG".into(), s(self.log("job-unit"))),
            ("LANE_MAIL_LOG".into(), s(self.log("lane-mail"))),
            ("CHANGE_SCOPE_LOG".into(), s(self.log("change-scope"))),
            ("JOB_UNIT_STATE".into(), s(self.item.clone())),
            ("LANE_MAIL_STATE".into(), s(self.item.clone())),
        ]
    }

    /// The binary with the world's environment and `extra` over it.
    fn run(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut command = support::isolated();
        command.arg("--state-dir").arg(&self.state).args(args);
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

    /// The validate stage under `run_dir`, from the file or a snapshot of it.
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

    /// The stage once the detached job closed it, within the bound: a poll
    /// on the record, the only barrier a detached job offers.
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

    /// The notice's mark once the detached job wrote it.
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
    assert!(out.status.success(), "{}", stderr(out));
    reply(out)["result"].clone()
}

fn refusal(out: &Output) -> (String, String) {
    assert_eq!(out.status.code(), Some(1), "{}", stderr(out));
    let line = stderr(out).lines().next().unwrap_or_default().to_owned();
    (
        reply(out)["refusal"]["key"].as_str().unwrap().to_owned(),
        line,
    )
}

fn run_file(run_dir: &str, name: &str) -> String {
    fs::read_to_string(Path::new(run_dir).join(name)).unwrap_or_default()
}

/// A1 row (1): the proof facts and the launcher's record path are on the
/// stage when the launcher is asked (the launcher fixture snapshots the
/// record at that moment), the launcher's identity is written after it,
/// the run directory holds what the executor reads, and a launcher that
/// refuses leaves the stage `stopped` with its cause, never open. Defect
/// caught: a run launched before its record, which a reconcile would read
/// as never started and a crash would leave unknown.
#[test]
fn a_start_records_the_proof_and_the_job_before_the_launcher_is_asked_and_a_refused_launch_stops() {
    let w = World::new();
    let snapshot = w.root.join("at-launch.json");
    let out = w.start(
        &[],
        &[("JOB_UNIT_SNAPSHOT", &snapshot.display().to_string())],
    );
    let result = ok(&out);
    let run_dir = result["run_dir"].as_str().unwrap().to_owned();
    assert_eq!(result["launched"], true);
    assert_eq!(result["mode"], "full");
    assert_eq!(
        result["started_line"],
        format!(
            "state=started run-dir={rd} log={rd}/log sentinel={rd}/exit timeout-secs=20 poll-secs=1 cap-secs=31 class=small docs-only=false",
            rd = run_dir
        )
    );
    // What the record held when the launcher was asked.
    let at_launch: Value = serde_json::from_str(&fs::read_to_string(&snapshot).unwrap()).unwrap();
    let stage = World::stage_in(&at_launch, &run_dir);
    assert_eq!(stage["proof"]["mode"], "full");
    assert_eq!(stage["proof"]["cmd"], "echo full");
    assert_eq!(stage["proof"]["class"], "small");
    assert_eq!(stage["proof"]["head"], w.head());
    assert_eq!(
        stage["proof"]["tree"],
        git(&w.worktree, &["rev-parse", "HEAD^{tree}"])
    );
    assert_eq!(stage["proof"]["caller"], "dev");
    assert_eq!(stage["job"]["record"], format!("{run_dir}/runner"));
    assert!(
        stage["job"].get("runner").is_none(),
        "no identity before the ask: {stage}"
    );
    assert!(stage["end"].is_null());
    // The identity the launcher's record names, written after its answer.
    let stage = w.stage(&run_dir);
    assert_eq!(stage["job"]["runner"], "setsid");
    let pid = stage["job"]["pid"].as_u64().unwrap() as u32;
    assert!(
        stage["job"]["start"]
            .as_str()
            .unwrap()
            .starts_with("ticks:")
    );
    assert_eq!(
        stage["job"]["line"].as_str().unwrap(),
        format!(
            "runner=setsid reason=no-linger pid={pid} start={}",
            stage["job"]["start"].as_str().unwrap()
        )
    );
    // The run directory the executor reads.
    assert_eq!(run_file(&run_dir, "cmd"), "echo full");
    let start = run_file(&run_dir, "start");
    assert!(start.contains("validate-mode=full\n"), "{start}");
    assert!(
        start.contains("timeout-secs=20\ncap-secs=31\n")
            || start.contains("poll-secs=1\ncap-secs=31\n"),
        "{start}"
    );
    assert_eq!(run_file(&run_dir, "paths"), "src/a.rs\n");
    let index = fs::read_to_string(w.worktree.join("tmp/validation-runs")).unwrap();
    assert_eq!(
        index,
        format!(
            "dev-validate-runs-v1\n{}\n",
            Path::new(&run_dir).file_name().unwrap().to_str().unwrap()
        )
    );
    // The detached job ran the child and closed the stage.
    let closed = w.wait_closed(&run_dir);
    assert_eq!(closed["outcome"], "pass");
    assert!(run_file(&run_dir, "exit").starts_with("guard-exit=0 at="));
    w.wait_marked(&run_dir);
    // A second start of the round while that run was open was refused; now
    // the round has no open run, and the launcher that refuses stops it.
    let out = w.start(
        &["--fresh"],
        &[(
            "ORCH_JOB_UNIT",
            &fixtures()
                .join("job-unit-fail/job-unit")
                .display()
                .to_string(),
        )],
    );
    let (key, line) = refusal(&out);
    assert_eq!(key, "launch-failed");
    let stopped_dir = line
        .split(' ')
        .find_map(|f| f.strip_prefix("run_dir="))
        .unwrap()
        .to_owned();
    let stopped = w.stage(&stopped_dir);
    assert_eq!(stopped["outcome"], "stopped");
    assert!(!stopped["end"].is_null());
    assert_eq!(stopped["job"]["runner"], "none");
    assert_eq!(
        stopped["job"]["cause"],
        "job-unit: launch-failed detail=fixture"
    );
}

#[test]
fn a_launch_whose_answer_was_lost_keeps_its_stage_open_until_the_reconcile_reads_its_job() {
    let w = World::new();
    let lost = [("JOB_UNIT_RECORD_ONLY", "1"), ("JOB_UNIT_ANSWER_LOST", "1")];
    let (key, line) = refusal(&w.start(&[], &lost));
    assert_eq!(key, "launch-unanswered", "{line}");
    let run_dir = line
        .split(' ')
        .find_map(|f| f.strip_prefix("run_dir="))
        .unwrap()
        .to_owned();
    let stage = w.stage(&run_dir);
    assert!(stage["end"].is_null(), "the stage stays open: {stage}");
    assert!(
        stage["job"]["runner"].is_null(),
        "no identity read from a lost answer: {stage}"
    );
    let (key, _) = refusal(&w.start(&[], &[("JOB_UNIT_RECORD_ONLY", "1")]));
    assert_eq!(key, "run-live", "nothing launched beside it");
    // The launcher's record names a pid that does not run: the round's
    // reconcile reads the job gone and closes the stage.
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    assert_eq!(w.stage(&run_dir)["outcome"], "lost");
}

#[test]
fn a_unit_start_whose_answer_and_read_are_lost_keeps_its_live_run_open_until_the_reconcile_reads_the_unit()
 {
    let w = World::new();
    // A lingering manager that starts the unit, loses the start's answer,
    // and answers the unit read only once the row has planted its answer.
    let tools = w.root.join("manager");
    fs::create_dir(&tools).unwrap();
    let fake = fs::read_to_string(fixtures().join("cutover-fakes/systemd-run")).unwrap();
    let started = fake.strip_suffix("exit 0\n").unwrap();
    let systemd_run = format!(
        "{started}run_dir=\"\"\nfor ((i=0;i<${{#argv[@]}};i++)); do\n  [ \"${{argv[i]}}\" != --run-dir ] || run_dir=\"${{argv[i+1]}}\"\ndone\nfor ((i=0;i<600;i++)); do [ ! -f \"$run_dir/pid\" ] || break; sleep 0.05; done\nexit 1\n"
    );
    let answer = tools.join("answer");
    let systemctl = format!(
        "#!/bin/bash\n[ -f '{}' ] || exit 1\ncat '{}'\n",
        answer.display(),
        answer.display()
    );
    for (name, text) in [
        ("systemd-run", systemd_run),
        ("systemctl", systemctl),
        ("loginctl", "#!/bin/bash\necho yes\n".to_owned()),
    ] {
        write_executable(&tools.join(name), text);
    }
    let hold = w.root.join("child-hold");
    assert!(program("mkfifo").arg(&hold).status().unwrap().success());
    let launcher = support::job_unit().display().to_string();
    let path = tool_path(&[&tools]);
    let hold_path = hold.display().to_string();
    let env = [
        ("ORCH_JOB_UNIT", launcher.as_str()),
        ("PATH", path.as_str()),
        ("DEV_VALIDATE_CHILD_HOLD", hold_path.as_str()),
    ];
    let (key, line) = refusal(&w.start(&[], &env));
    let run_dir = line
        .split(' ')
        .find_map(|f| f.strip_prefix("run_dir="))
        .unwrap_or_default()
        .to_owned();
    let unit: u32 = fs::read_dir(tools.join("units"))
        .ok()
        .and_then(|mut entries| entries.next())
        .and_then(|entry| fs::read_to_string(entry.unwrap().path()).ok())
        .and_then(|pid| pid.trim().parse().ok())
        .expect("the manager started the unit");
    // The run's own close, and the unit's group, once the row has read it.
    let release = || {
        let _ = fs::write(&hold, "release\n");
        let _ = program("kill")
            .args(["-TERM", "--", &format!("-{unit}")])
            .status();
    };
    let stage = w.stage(&run_dir);
    let child: u32 = run_file(&run_dir, "pid").trim().parse().unwrap();
    let open = (key.clone(), stage["end"].is_null(), support::live(child));
    let second = refusal(&w.start(&[], &env)).0;
    // The unit still runs: the reconcile keeps the run open.
    fs::write(&answer, "loaded\nactive\n").unwrap();
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &env));
    let kept = w.stage(&run_dir)["end"].is_null();
    release();
    assert_eq!(open, ("launch-unanswered".to_owned(), true, true), "{line}");
    assert_eq!(second, "run-live", "nothing launched beside the live run");
    assert!(kept, "the reconcile keeps a live unit's run open");
    // The unit ended: the reconcile closes the run.
    let deadline = Instant::now() + JOB_BOUND;
    while support::live(child) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    fs::write(&answer, "not-found\ninactive\n").unwrap();
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &env));
    assert!(!w.stage(&run_dir)["end"].is_null(), "{}", w.stage(&run_dir));
}

/// Defect: a launch the launcher answered possibly started, its group not
/// read empty (`status=unwound-failed`), closed `stopped` by the round's
/// reconcile while its job runs, or closed `lost` once its leader exited
/// while a member of its group runs. The launcher reports a live job through
/// the real library's ended-launch path, its record naming the leader's
/// start or the group's key alone: the start refuses `launch-unanswered`
/// with the stage open, a reconcile while the job runs keeps it open, and
/// the stage closes once the job has ended. With the leader ended and its
/// member running, the reconcile keeps the stage open until the member ends.
#[test]
fn a_launch_whose_group_could_not_be_read_empty_keeps_its_stage_open_while_its_job_runs() {
    for mode in ["identity", "key", "leader-exits"] {
        let w = World::new();
        let hold = w.root.join("child-hold");
        assert!(program("mkfifo").arg(&hold).status().unwrap().success());
        let hold_path = hold.display().to_string();
        let member_file = w.root.join("member");
        let member_path = member_file.display().to_string();
        let env = [
            ("JOB_UNIT_UNWOUND_FAILED", mode),
            ("DEV_VALIDATE_CHILD_HOLD", hold_path.as_str()),
            ("JOB_UNIT_MEMBER_FILE", member_path.as_str()),
        ];
        let (key, line) = refusal(&w.start(&[], &env));
        let run_dir = line
            .split(' ')
            .find_map(|f| f.strip_prefix("run_dir="))
            .unwrap_or_default()
            .to_owned();
        let record = run_file(&run_dir, "runner");
        let reconcile = || ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
        let await_gone = |pid: u32| {
            let deadline = Instant::now() + JOB_BOUND;
            while support::live(pid) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
        };
        let (kept, closed) = if mode == "leader-exits" {
            let deadline = Instant::now() + JOB_BOUND;
            while fs::read_to_string(&member_file)
                .unwrap_or_default()
                .is_empty()
                && Instant::now() < deadline
            {
                std::thread::sleep(Duration::from_millis(50));
            }
            let member: u32 = fs::read_to_string(&member_file)
                .unwrap_or_default()
                .trim()
                .parse()
                .unwrap_or_default();
            let leader: u32 = record
                .lines()
                .find_map(|l| l.strip_prefix("pid="))
                .and_then(|p| p.parse().ok())
                .unwrap_or_default();
            let _ = program("kill")
                .args(["-KILL", &leader.to_string()])
                .status();
            await_gone(leader);
            let stat = fs::read_to_string(format!("/proc/{member}/stat")).unwrap_or_default();
            let group = stat
                .rsplit_once(')')
                .and_then(|(_, rest)| rest.split_whitespace().nth(2))
                .and_then(|g| g.parse::<u32>().ok());
            reconcile();
            let kept = (
                w.stage(&run_dir),
                !support::live(leader) && support::live(member) && group == Some(leader),
            );
            let _ = program("kill")
                .args(["-KILL", &member.to_string()])
                .status();
            await_gone(member);
            reconcile();
            (kept, w.stage(&run_dir))
        } else {
            let deadline = Instant::now() + JOB_BOUND;
            while run_file(&run_dir, "pid").is_empty() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            let child: u32 = run_file(&run_dir, "pid").trim().parse().unwrap_or_default();
            reconcile();
            let kept = (w.stage(&run_dir), support::live(child));
            let _ = fs::write(&hold, "release\n");
            (kept, w.wait_closed(&run_dir))
        };
        assert_eq!(key, "launch-unanswered", "{mode}: {line}");
        assert!(
            record.contains("status=unwound-failed\n")
                && record.contains("pgid=")
                && record.contains("start=") == (mode != "key"),
            "{mode}: the launcher's record: {record}"
        );
        assert!(
            kept.0["end"].is_null() && kept.1,
            "{mode}: the reconcile keeps the stage open while its job runs: {}",
            kept.0
        );
        let ended = if mode == "leader-exits" {
            "lost"
        } else {
            "pass"
        };
        assert_eq!(closed["outcome"], ended, "{mode}: {closed}");
    }
}

#[test]
fn a_launcher_that_never_started_stops_its_stage() {
    use std::os::unix::fs::PermissionsExt;
    let w = World::new();
    let launcher = w.root.join("job-unit-not-executable");
    fs::copy(support::job_unit(), &launcher).unwrap();
    fs::set_permissions(&launcher, fs::Permissions::from_mode(0o644)).unwrap();
    let launcher = launcher.display().to_string();
    let (key, line) = refusal(&w.start(&[], &[("ORCH_JOB_UNIT", &launcher)]));
    assert_eq!(key, "launch-failed", "{line}");
    let run_dir = line
        .split(' ')
        .find_map(|f| f.strip_prefix("run_dir="))
        .unwrap()
        .to_owned();
    assert_eq!(w.stage(&run_dir)["outcome"], "stopped");
}

/// A1 row (1), the live rule: a round with an open started run refuses a
/// second start as `run-live` and records nothing. Defect caught: two
/// batteries beside each other, the slower failing on load.
#[test]
fn a_second_start_beside_an_open_started_run_is_refused_run_live() {
    let w = World::new();
    let out = w.start(&[], &[("JOB_UNIT_RECORD_ONLY", "1")]);
    let run_dir = ok(&out)["run_dir"].as_str().unwrap().to_owned();
    let before = w.state();
    let (key, line) = refusal(&w.start(&[], &[("JOB_UNIT_RECORD_ONLY", "1")]));
    assert_eq!(key, "run-live");
    assert!(line.ends_with(&format!("run_dir={run_dir}")), "{line}");
    assert_eq!(w.state(), before);
}

/// A1 row (2): `reconcile-round` reads a started run by its recorded job
/// identity, three-valued: a live job under its recorded start stays open;
/// the same pid under another start is the job gone, closed `lost`; a unit
/// the manager has no record of is gone, one it holds active is live; a
/// job whose launcher never answered is read from the launcher's record.
/// Defect caught: a reused pid keeping a dead run open, or a live run
/// closed over a bare pid read.
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
    // The fixture answers not-found for every unit this pass; the live
    // unit is read on a second pass with the manager answering active.
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

/// A started run whose user manager does not answer is read `unreadable`, and
/// its stage stays open — a read that failed never closes a run that may
/// still be live. Defect caught: a manager error read as a gone job, closing
/// a live run.
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

/// A runtime-started job gone between its sentinel and its `end` is closed by
/// the reconcile from the sentinel, with the lane's end notice recorded
/// `owed` in the same write; the owed walk the reconcile runs then sends it.
/// Defect caught: a reconcile that closes the run but never tells the lane.
#[test]
fn a_reconcile_closes_a_gone_runtime_run_and_owes_its_end_notice() {
    let w = World::new();
    // A live process under a start no run recorded reads gone (as row (2)'s
    // reused case does), so the job is gone with its sentinel standing.
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
    // The reconcile closes the gone run from its sentinel and, in the same
    // call, the owed walk sends the notice it owed.
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
    assert!(
        w.log_lines("lane-mail")
            .iter()
            .any(|l| l.starts_with(&format!("send --item {ITEM_ID} --directive"))),
        "the end notice went out on the lane's outbound route: {:?}",
        w.log_lines("lane-mail")
    );
}

/// A1 row (3): the job closes the stage once with the notice recorded
/// `owed` in the same write, before the send (the mailbox fixture snapshots
/// the record at the send), marks it `sent` after, and a second run of the
/// same job changes nothing and sends nothing; a crash between the close
/// and the send, planted as a closed stage whose notice is still owed, is
/// sent once by the round's next reconcile. Defect caught: a lane never
/// told its run ended, or told twice.
#[test]
fn the_job_closes_once_records_the_notice_owed_before_the_send_and_a_second_end_changes_nothing() {
    let w = World::new();
    let out = w.start(&[], &[("JOB_UNIT_RECORD_ONLY", "1")]);
    let run_dir = ok(&out)["run_dir"].as_str().unwrap().to_owned();
    let snapshot = w.root.join("at-send.json");
    let out = w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &run_dir,
        ],
        &[
            ("LANE_MAIL_SNAPSHOT", &snapshot.display().to_string()),
            ("DEV_VALIDATE_CHILD_SELECTION", "battery"),
        ],
    );
    let result = ok(&out);
    assert_eq!(result["closed_now"], true);
    assert_eq!(result["outcome"], "pass");
    assert_eq!(result["notice"], "sent");
    let run_id = Path::new(&run_dir)
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .strip_prefix("dev-validate-")
        .unwrap()
        .to_owned();
    let key = format!("validate-{run_id}");
    // The child ran once, through the executor, and wrote the sentinel.
    assert_eq!(
        w.log_lines("child"),
        vec![format!("--child --run-dir {run_dir}")]
    );
    // At the send, the stage was closed and the notice owed.
    let at_send: Value = serde_json::from_str(&fs::read_to_string(&snapshot).unwrap()).unwrap();
    let stage = World::stage_in(&at_send, &run_dir);
    assert_eq!(stage["outcome"], "pass");
    assert!(!stage["end"].is_null());
    assert_eq!(stage["notice"]["owner"], "owed");
    assert_eq!(stage["notice"]["to"], ITEM_ID);
    assert_eq!(stage["notice"]["key"], key);
    // The notice's text names the run and its outcome.
    let text =
        format!("validation-end run={run_id} state=pass run-dir={run_dir} log={run_dir}/log");
    assert_eq!(stage["notice"]["text"], text);
    // The send is the mailbox's outbound directive route to the lane, keyed
    // by the run, not the inbound `notice` verb that lands in the overseer's
    // box; the fixture logs the call and the directive's first line. The file
    // is this walker's own, named by the key and the walker's stamp: the key
    // is the record's, the file is scratch.
    let calls = w.log_lines("lane-mail");
    assert_eq!(calls.len(), 2, "{calls:?}");
    let file_prefix = format!(
        "send --item {ITEM_ID} --directive --file {}/validate/{key}.",
        w.state.display()
    );
    let file_suffix = format!(".notice --delivery-id {key}");
    assert!(
        calls[0].starts_with(&file_prefix) && calls[0].ends_with(&file_suffix),
        "the outbound route with this walker's own file: {calls:?}"
    );
    assert_eq!(calls[1], format!("send-text {text}"));
    let after = w.stage(&run_dir);
    assert_eq!(after["notice"]["owner"], "sent");
    assert_eq!(after["proof"]["selection"], "battery");
    // A second end of the same run: the close stands, nothing is sent.
    let out = w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &run_dir,
        ],
        &[],
    );
    let again = ok(&out);
    assert_eq!(again["closed_now"], false);
    assert_eq!(again["notice"], "sent");
    assert_eq!(w.log_lines("lane-mail").len(), 2);
    assert_eq!(w.log_lines("child").len(), 1);
    assert_eq!(w.stage(&run_dir), after);
    // A crash between the close and the send: the round's next reconcile
    // sends once and marks.
    let mut doc = w.state();
    for s in doc["stages"].as_array_mut().unwrap() {
        if s["run_dir"] == run_dir {
            s["notice"]["owner"] = json!("owed");
        }
    }
    w.write_state(&doc);
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    assert_eq!(w.log_lines("lane-mail").len(), 4);
    assert_eq!(w.stage(&run_dir)["notice"]["owner"], "sent");
    ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    assert_eq!(
        w.log_lines("lane-mail").len(),
        4,
        "a marked notice is not sent again"
    );
    // A mailbox that refuses leaves the mark as the refusal, never the close.
    let out = w.start(&["--fresh"], &[("JOB_UNIT_RECORD_ONLY", "1")]);
    let second = ok(&out)["run_dir"].as_str().unwrap().to_owned();
    let second_id = Path::new(&second)
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .strip_prefix("dev-validate-")
        .unwrap()
        .to_owned();
    let out = w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &second,
        ],
        &[("LANE_MAIL_STATUS", "2"), ("DEV_VALIDATE_CHILD_EXIT", "1")],
    );
    let result = ok(&out);
    assert_eq!(result["outcome"], "fail");
    assert!(
        result["notice"]
            .as_str()
            .unwrap()
            .starts_with("unsent:send: status=2"),
        "{result}"
    );
    assert_eq!(
        w.stage(&second)["notice"]["key"],
        format!("validate-{second_id}")
    );
    // A child gone with no sentinel is lost, said in the notice.
    let out = w.start(&["--fresh"], &[("JOB_UNIT_RECORD_ONLY", "1")]);
    let third = ok(&out)["run_dir"].as_str().unwrap().to_owned();
    let out = w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &third,
        ],
        &[("DEV_VALIDATE_CHILD_NO_SENTINEL", "1")],
    );
    let result = ok(&out);
    assert_eq!(result["outcome"], "lost");
    let third_id = Path::new(&third)
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .strip_prefix("dev-validate-")
        .unwrap()
        .to_owned();
    assert_eq!(
        w.stage(&third)["notice"]["text"],
        format!("validation-end run={third_id} state=lost run-dir={third} log={third}/log")
    );
}

/// The end notice's mailbox route reads the program's answer three ways. A
/// program that never started, or refused by its own key, appended nothing:
/// `unsent`. One whose answer cannot be read (exit 0 with no receipt, or
/// ended by a signal) may have appended: the notice stays owed and the
/// round's reconcile sends it again under its key, `sent` on the receipt.
/// A session send the program routed to itself is marked by its result,
/// never `sent` whatever it was. A fleet record that cannot be read picks
/// no route: nothing is sent and the notice stays owed.
#[test]
fn an_end_notice_whose_send_answer_is_unknown_stays_owed_and_one_never_started_is_unsent() {
    let w = World::new();
    let mut fresh = false;
    let mut run = |extra: &[(&str, &str)]| -> (String, Value) {
        let flags: &[&str] = if fresh { &["--fresh"] } else { &[] };
        fresh = true;
        let run_dir = ok(&w.start(flags, &[("JOB_UNIT_RECORD_ONLY", "1")]))["run_dir"]
            .as_str()
            .unwrap()
            .to_owned();
        let result = ok(&w.run(
            &[
                "validate",
                "run",
                "--item",
                ITEM_ID,
                "--round",
                ROUND,
                "--run-dir",
                &run_dir,
            ],
            extra,
        ));
        (run_dir, result)
    };
    let sends = |w: &World| {
        w.log_lines("lane-mail")
            .iter()
            .filter(|l| l.starts_with("send "))
            .count()
    };
    let reconcile = |w: &World| {
        ok(&w.op(&json!({"op": "reconcile-round", "round_id": ROUND}), &[]));
    };

    for answer in ["quiet", "signal"] {
        let (run_dir, result) = run(&[("LANE_MAIL_ANSWER", answer)]);
        assert_eq!(result["notice"], "owed", "{answer}: {result}");
        assert_eq!(w.stage(&run_dir)["notice"]["owner"], "owed", "{answer}");
        let before = sends(&w);
        reconcile(&w);
        assert_eq!(sends(&w), before + 1, "{answer}: sent again under its key");
        assert_eq!(w.stage(&run_dir)["notice"]["owner"], "sent", "{answer}");
    }

    let absent = w.root.join("no-such-lane-mail");
    let (run_dir, result) = run(&[("LANE_MAIL_CLI", absent.to_str().unwrap())]);
    let mark = result["notice"].as_str().unwrap().to_owned();
    assert!(mark.starts_with("unsent:send: "), "{result}");
    assert_eq!(w.stage(&run_dir)["notice"]["owner"], mark.as_str());

    let (run_dir, result) = run(&[("LANE_MAIL_ANSWER", "session-failed")]);
    assert_eq!(result["notice"], "unsent:session:failed", "{result}");
    assert_eq!(
        w.stage(&run_dir)["notice"]["owner"],
        "unsent:session:failed"
    );

    let fleet = w.state.join("workflow-state-oversee.json");
    fs::write(&fleet, "{ not a fleet").unwrap();
    let before = sends(&w);
    let (run_dir, result) = run(&[]);
    assert_eq!(result["notice"], "owed", "{result}");
    assert_eq!(sends(&w), before, "an unread fleet routes no send");
    fs::remove_file(&fleet).unwrap();
    reconcile(&w);
    assert_eq!(w.stage(&run_dir)["notice"]["owner"], "sent");
}

/// The real mailbox program beside this crate, for the destination proof.
fn real_lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap()
}

/// The end notice goes out through the mailbox's outbound directive route to
/// the lane, so one line lands in the lane's own inbox (`to-lane.jsonl`) and
/// none in the overseer's box (`to-overseer.jsonl`), and a replay and a
/// crash-replay, keyed by the run, each land once. Run against the real
/// `lane-mail` on the worktree, as `tests/rust/send.rs` does. Defect caught:
/// the inbound `notice` verb, which lands in the overseer's box as if the
/// lane wrote it and tells the lane nothing, and a replay that lands a second
/// envelope.
#[test]
fn the_end_notice_lands_in_the_lanes_inbox_and_a_replay_lands_once() {
    let w = World::new();
    let lane_mail = real_lane_mail();
    let out = w.start(&[], &[("JOB_UNIT_RECORD_ONLY", "1")]);
    let run_dir = ok(&out)["run_dir"].as_str().unwrap().to_owned();
    // Run the job directly with the real mailbox program and the worktree as
    // its working directory, as the detached job runs under the launcher.
    let child = fixtures().join("dev-validate-child/dev-validate-run");
    let run = |args: &[&str]| {
        let mut command = support::isolated();
        command
            .arg("--state-dir")
            .arg(&w.state)
            .args(args)
            .env("LANE_MAIL_CLI", &lane_mail)
            .env("ORCH_STATE_DIR", &w.state)
            .env("DEV_VALIDATE_CLI", &child)
            .current_dir(&w.worktree);
        command.output().unwrap()
    };
    ok(&run(&[
        "validate",
        "run",
        "--item",
        ITEM_ID,
        "--round",
        ROUND,
        "--run-dir",
        &run_dir,
    ]));
    let box_dir = w.worktree.join("tmp/lane-mail").join(ITEM_ID);
    let to_lane = box_dir.join("to-lane.jsonl");
    let to_overseer = box_dir.join("to-overseer.jsonl");
    let lines = |p: &Path| {
        fs::read_to_string(p)
            .map(|t| t.lines().filter(|l| !l.trim().is_empty()).count())
            .unwrap_or(0)
    };
    assert_eq!(lines(&to_lane), 1, "the lane's inbox holds the one notice");
    assert_eq!(lines(&to_overseer), 0, "nothing in the overseer's box");
    let directive = fs::read_to_string(&to_lane).unwrap();
    assert!(
        directive.contains("validation-end run="),
        "the directive carries the end notice: {directive}"
    );
    assert_eq!(w.stage(&run_dir)["notice"]["owner"], "sent");
    // A replay (the notice planted owed) and a crash-replay, each keyed by
    // the run, land once: the mailbox reads the repeat as delivered.
    for _ in 0..2 {
        let mut doc = w.state();
        for s in doc["stages"].as_array_mut().unwrap() {
            if s["run_dir"] == run_dir {
                s["notice"]["owner"] = json!("owed");
            }
        }
        w.write_state(&doc);
        let path = w.root.join("reconcile.json");
        fs::write(
            &path,
            json!({"op": "reconcile-round", "round_id": ROUND}).to_string(),
        )
        .unwrap();
        ok(&run(&[
            "op",
            "--item",
            ITEM_ID,
            "--request",
            &path.display().to_string(),
        ]));
        assert_eq!(lines(&to_lane), 1, "the replay lands once");
        assert_eq!(w.stage(&run_dir)["notice"]["owner"], "sent");
    }
    assert_eq!(
        lines(&to_overseer),
        0,
        "still nothing in the overseer's box"
    );
}

/// The run id a run directory's name carries.
fn run_id(run_dir: &str) -> String {
    Path::new(run_dir)
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .strip_prefix("dev-validate-")
        .unwrap()
        .to_owned()
}

/// The job's close records the stage's `end` from the sentinel's own `at=`,
/// bounded to `[start, now]` as the reconcile's close bounds it, and reports
/// the run's wall time from its `timing` record, where the reconcile reported
/// them before the job became the closer; and the job's `now` is the clock at
/// the close, not at its launch. The executor is held three and a half
/// seconds (wall time, the claim being timer wiring: the stage's clock must
/// move past the job's launch second for a launch-time stamp to differ from a
/// close-time one) and writes a sentinel two seconds after the stage's start,
/// inside the close's bounds and past the launch's. Defect caught: a close
/// stamped at the job's own clock, so a run that ended seconds before its
/// close reads as ending at the close; the run's seconds reported nowhere;
/// and the job's clock read once at its launch, so every sentinel time later
/// than the launch second fell outside the bounds and the stage ended at the
/// launch (the one-job killed row's `stop.at <= end` read false).
#[test]
fn the_jobs_close_records_the_sentinels_time_and_reports_the_runs_seconds() {
    let w = World::new();
    let run_dir = ok(&w.start(&[], &[("JOB_UNIT_RECORD_ONLY", "1")]))["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    let start = w.stage(&run_dir)["start"].as_u64().unwrap();
    let fifo = w.root.join("hold.fifo");
    let made = program("mkfifo").arg(&fifo).output().unwrap();
    assert!(made.status.success(), "{}", stderr(&made));
    let mut command = support::isolated();
    command
        .arg("--state-dir")
        .arg(&w.state)
        .args([
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &run_dir,
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    for (k, v) in w.env() {
        command.env(k, v);
    }
    command
        .env("DEV_VALIDATE_CHILD_HOLD", &fifo)
        .env("DEV_VALIDATE_CHILD_AT", (start + 2).to_string());
    let job = command.spawn().unwrap();
    std::thread::sleep(Duration::from_millis(3500));
    fs::write(&fifo, "go\n").unwrap();
    let reply = ok(&job.wait_with_output().unwrap());
    assert_eq!(reply["closed_now"], true);
    assert_eq!(reply["seconds"], 1, "the timing record's seconds: {reply}");
    let stage = w.stage(&run_dir);
    assert_eq!(
        stage["end"],
        start + 2,
        "the sentinel's own time, inside the close's bounds: {stage}"
    );
    // A sentinel time before the stage's start, a clock the runner and this
    // host disagree on, yields to the close's own.
    let second = ok(&w.start(&["--fresh"], &[("JOB_UNIT_RECORD_ONLY", "1")]))["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    let before = w.stage(&second)["start"].as_u64().unwrap();
    ok(&w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &second,
        ],
        &[("DEV_VALIDATE_CHILD_AT", &(before - 100).to_string())],
    ));
    let end = w.stage(&second)["end"].as_u64().unwrap();
    assert!(
        end >= before,
        "the close's own clock, not {}: {end}",
        before - 100
    );
}

/// The orch scripts as a tree of their own beside the row, every script and
/// `lib` linked to the real one but `orch-runtime`, which runs the binary
/// under test with the row's state directory: the real `dev-validate-run
/// --stop` entry then hands a run the runtime started to that binary's
/// `validate stop`. The tree keeps the install's layout: the mailbox
/// skill's `scripts/lib` two directories from orch's `scripts`, where the
/// script sources its lock library.
fn scripts_tree(w: &World) -> PathBuf {
    let real = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../scripts")
        .canonicalize()
        .unwrap();
    let mailbox = w.root.join("mailbox").join("scripts");
    fs::create_dir_all(&mailbox).unwrap();
    std::os::unix::fs::symlink(
        real.join("../../mailbox/scripts/lib")
            .canonicalize()
            .unwrap(),
        mailbox.join("lib"),
    )
    .unwrap();
    let tree = w.root.join("orch").join("scripts");
    fs::create_dir_all(&tree).unwrap();
    for entry in fs::read_dir(&real).unwrap() {
        let entry = entry.unwrap();
        if entry.file_name() == "orch-runtime" {
            continue;
        }
        std::os::unix::fs::symlink(entry.path(), tree.join(entry.file_name())).unwrap();
    }
    let wrapper = tree.join("orch-runtime");
    write_executable(
        &wrapper,
        format!(
            "#!/bin/bash\nexec {} --no-private-env --state-dir \"${{ORCH_STATE_DIR:?}}\" \"$@\"\n",
            support::binary().display()
        ),
    );
    tree
}

/// The process `pid`, read through the one identity reader, is gone within
/// the bound.
fn await_gone(pid: u32, what: &str) {
    let deadline = Instant::now() + JOB_BOUND;
    while matches!(
        agent_runtime::process::identity(pid),
        agent_runtime::reading::Reading::Live(_)
    ) {
        assert!(Instant::now() < deadline, "{what} survived the stop");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// An intentional stop is a record before the effect, and the stage closes
/// `stopped` on both routes. The real `dev-validate-run --stop` entry hands a
/// run the runtime started to `validate stop`, which writes `stop {at}` on
/// the open stage, ends the job by its recorded identity through the launcher
/// (the setsid group by the held executor's pid; the unit by its name,
/// through a user manager faked on `PATH` that ends the unit's job and
/// executor as a stop does), waits for the job gone and runs the finishing
/// transition. On the setsid route the job outlives its child's group and
/// closes the stage itself; on the unit route the manager ended the job with
/// its child and the reconcile closes it with the notice owed, sent by the
/// owed walk in the same call. Either way the stage reads `stopped` with the
/// notice `sent` naming that word, the executor is gone, the script's
/// `state=stopped` line counts the route's kind, and a second stop of the
/// closed run refuses `run-closed`. Defect caught: an intentional stop
/// closing `lost`, the word a run's process going away unasked closes with,
/// on either route.
#[test]
fn a_stop_records_its_intent_before_ending_the_job_and_the_stage_closes_stopped_on_both_routes() {
    for route in ["setsid", "systemd"] {
        let w = World::new();
        let tree = scripts_tree(&w);
        let fifo = w.root.join("hold.fifo");
        let made = program("mkfifo").arg(&fifo).output().unwrap();
        assert!(made.status.success(), "{route}: {}", stderr(&made));
        // The real launcher starts the job detached; its executor holds on
        // the fifo until ended.
        let started = ok(&w.start(&[], &[("DEV_VALIDATE_CHILD_HOLD", fifo.to_str().unwrap())]));
        let dir = started["run_dir"].as_str().unwrap().to_owned();
        let deadline = Instant::now() + JOB_BOUND;
        let child = loop {
            if let Ok(pid) = fs::read_to_string(Path::new(&dir).join("pid")) {
                break pid.trim().parse::<u32>().unwrap();
            }
            assert!(
                Instant::now() < deadline,
                "{route}: the executor never recorded its pid"
            );
            std::thread::sleep(Duration::from_millis(50));
        };
        let job = w.stage(&dir)["job"]["pid"].as_u64().unwrap() as u32;
        let fake = w.root.join("manager");
        fs::create_dir_all(&fake).unwrap();
        if route == "systemd" {
            // The user manager: a stop ends the unit's job and its executor;
            // a show after it reads the unit gone.
            let systemctl = fake.join("systemctl");
            write_executable(
                &systemctl,
                format!(
                    "#!/bin/bash\ncase \"$*\" in\n*' stop '*) kill -TERM -- -{child}; kill -TERM -- {job}; exit 0;;\n*) printf 'not-found\\ninactive\\n';;\nesac\n"
                ),
            );
            fs::write(
                Path::new(&dir).join("runner"),
                "runner=systemd\nunit=fixture-validation\nline=runner=systemd unit=fixture-validation\n",
            )
            .unwrap();
            let mut doc = w.state();
            for s in doc["stages"].as_array_mut().unwrap() {
                if s["run_dir"] == dir {
                    s["job"]["runner"] = json!("systemd");
                    s["job"]["unit"] = json!("fixture-validation");
                }
            }
            w.write_state(&doc);
        }
        let path = tool_path(&[&fake]);
        let stop = |w: &World| {
            let mut stop = program(tree.join("dev-validate-run"));
            stop.args(["--stop", "--worktree"])
                .arg(&w.worktree)
                .current_dir(&w.worktree)
                .env("PATH", &path)
                .env("ORCH_STATE_DIR", &w.state);
            for (key, value) in w.env() {
                stop.env(key, value);
            }
            stop.output().unwrap()
        };
        let stopped = stop(&w);
        assert!(stopped.status.success(), "{route}: {}", stderr(&stopped));
        let counts = if route == "systemd" {
            "state=stopped units=1 groups=0"
        } else {
            "state=stopped units=0 groups=1"
        };
        assert_eq!(
            String::from_utf8_lossy(&stopped.stdout).trim_end(),
            counts,
            "{route}: the script's line counts the route's kind"
        );
        await_gone(child, &format!("{route}: the executor"));
        await_gone(job, &format!("{route}: the job"));
        let stage = w.wait_marked(&dir);
        assert_eq!(stage["outcome"], "stopped", "{route}: {stage}");
        assert!(stage["stop"]["at"].is_u64(), "{route}: {stage}");
        assert!(
            stage["stop"]["at"].as_u64().unwrap() <= stage["end"].as_u64().unwrap(),
            "{route}: the stop was recorded before the close: {stage}"
        );
        assert_eq!(stage["notice"]["owner"], "sent", "{route}: {stage}");
        assert_eq!(
            stage["notice"]["text"],
            format!(
                "validation-end run={} state=stopped run-dir={dir} log={dir}/log",
                run_id(&dir)
            ),
            "{route}"
        );
        assert!(
            w.log_lines("lane-mail").iter().any(
                |l| l.starts_with("send-text validation-end ") && l.contains(" state=stopped ")
            ),
            "{route}: the notice went out naming the word: {:?}",
            w.log_lines("lane-mail")
        );
        assert!(
            fs::metadata(Path::new(&dir).join("exit")).is_err(),
            "{route}: the stopped run left no sentinel"
        );
        // A second stop of the closed run refuses by name, and the script's
        // stop loop skips a run with a verdict or none to stop.
        let out = w.run(&["validate", "stop", "--run-dir", &dir], &[]);
        let (key, _) = refusal(&out);
        assert_eq!(key, "run-closed", "{route}");
        let again = stop(&w);
        assert!(again.status.success(), "{route}: {}", stderr(&again));
        assert_eq!(
            String::from_utf8_lossy(&again.stdout).trim_end(),
            "state=stopped units=0 groups=0",
            "{route}: nothing left to stop"
        );
    }
}

/// A1 row (4) (R8 item 1): a fix round on a project declaring a range
/// command, started with no mode named, resolves `range` over the round's
/// base and hands the executor that base. Defect caught: a fix round running
/// the full battery for want of a flag.
#[test]
fn a_fix_round_on_a_project_declaring_a_range_command_resolves_range_with_no_mode_named() {
    let w = World::new();
    let base = w.head();
    w.commit("b.txt");
    let extra = [
        ("DEV_VALIDATE_RANGE_CMD", "echo range"),
        ("JOB_UNIT_RECORD_ONLY", "1"),
    ];
    let out = w.start(&["--base", &base], &extra);
    let result = ok(&out);
    let run_dir = result["run_dir"].as_str().unwrap().to_owned();
    assert_eq!(result["mode"], "range");
    assert_eq!(result["base"], base);
    let stage = w.stage(&run_dir);
    assert_eq!(stage["proof"]["mode"], "range");
    assert_eq!(stage["proof"]["base"], base);
    assert_eq!(stage["proof"]["cmd"], "echo range");
    assert_eq!(stage["proof"]["class_base"], base);
    assert!(stage["proof"].get("cause").is_none());
    let start = run_file(&run_dir, "start");
    assert!(start.contains("validate-mode=range\n"), "{start}");
    assert!(
        start.contains(&format!("validate-base={base}\n")),
        "{start}"
    );
    assert!(start.contains(&format!("class-base={base}\n")), "{start}");
    // The classifier was handed the round's base, not the branch's.
    let reads = w.log_lines("change-scope");
    assert!(
        reads
            .iter()
            .any(|l| l.starts_with("change-scope ") && l.contains(&format!("--base {base} "))),
        "{reads:?}"
    );
    // The executor reads the base from the record and exports it.
    ok(&w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &run_dir,
        ],
        &extra,
    ));
    assert!(run_file(&run_dir, "log").contains(&format!("DEV_VALIDATE_BASE={base}\n")));
    // An implement round on the same project runs the whole battery.
    let out = w.start(&[], &extra);
    let full = ok(&out);
    assert_eq!(full["mode"], "full");
    assert_eq!(
        w.stage(full["run_dir"].as_str().unwrap())["proof"]["cmd"],
        "echo full"
    );
    // A project declaring no range command runs a fix round as full, no
    // cause owed: nothing narrower is declared.
    let w2 = World::new();
    let base2 = w2.head();
    w2.commit("c.txt");
    // A range or ci request on an implement round names no base: refused.
    let (key, _) = refusal(&w2.start(&["--mode", "range"], &[("JOB_UNIT_RECORD_ONLY", "1")]));
    assert_eq!(key, "mode-base-required");
    let out = w2.start(&["--base", &base2], &[("JOB_UNIT_RECORD_ONLY", "1")]);
    let result = ok(&out);
    assert_eq!(result["mode"], "full");
    assert_eq!(result["base"], "");
}

/// A1 row (5): `full` on a fix round of a project declaring a range
/// command refuses `mode-cause-missing` and records nothing; with a cause,
/// the mode and the cause are both on the proof. Defect caught: a full
/// battery run for a fix round with no record of who asked for it.
#[test]
fn full_on_a_project_declaring_a_narrower_mode_needs_a_cause_and_records_both() {
    let w = World::new();
    let base = w.head();
    w.commit("b.txt");
    let extra = [
        ("DEV_VALIDATE_RANGE_CMD", "echo range"),
        ("JOB_UNIT_RECORD_ONLY", "1"),
    ];
    let before = w.state();
    let (key, line) = refusal(&w.start(&["--base", &base, "--mode", "full"], &extra));
    assert_eq!(key, "mode-cause-missing");
    assert_eq!(
        line,
        "orch-runtime: mode-cause-missing mode=full narrower=range"
    );
    assert_eq!(w.state(), before);
    assert!(
        fs::read_dir(w.worktree.join("tmp"))
            .unwrap()
            .next()
            .is_none(),
        "nothing recorded"
    );
    let out = w.start(
        &[
            "--base",
            &base,
            "--mode",
            "full",
            "--cause",
            "the range command misses a generated input",
        ],
        &extra,
    );
    let result = ok(&out);
    assert_eq!(result["mode"], "full");
    let stage = w.stage(result["run_dir"].as_str().unwrap());
    assert_eq!(stage["proof"]["mode"], "full");
    assert_eq!(
        stage["proof"]["cause"],
        "the range command misses a generated input"
    );
    assert_eq!(stage["proof"]["cmd"], "echo full");
    assert_eq!(stage["proof"]["base"], "");
    // A project declaring only a CI context owes the cause to `ci`.
    let w2 = World::new();
    let base2 = w2.head();
    w2.commit("c.txt");
    let (key, line) = refusal(&w2.start(
        &["--base", &base2, "--mode", "full"],
        &[
            ("DEV_VALIDATE_CI_CONTEXT", "ci/validate"),
            ("JOB_UNIT_RECORD_ONLY", "1"),
        ],
    ));
    assert_eq!(key, "mode-cause-missing");
    assert!(line.ends_with("narrower=ci"), "{line}");
}

/// A4's ci row: a fix round on a project declaring `DEV_VALIDATE_CI_CONTEXT`
/// resolves `ci` where the open pull request's base requires the context,
/// runs nothing, and closes the stage at once as a `ci` row with the sentinel
/// and log `dev-validate-run` writes; where the base does not require it, the
/// round runs locally with the cause recorded. Defect caught: a round
/// deferred to CI the base never runs, or a covered round run twice.
#[test]
fn a_fix_round_resolves_ci_where_the_context_is_declared_and_required_on_the_base() {
    let w = World::new();
    let base = w.head();
    w.commit("b.txt");
    let gh = fixtures().join("gh");
    let path = tool_path(&[&gh]);
    let replies = w.root.join("gh.json");
    let gh_log = w.root.join("gh.log");
    let rules = |context: &str| {
        json!({
            "repos/{owner}/{repo}/rules/branches/main": {"body": [{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": context}]}}]},
            "repos/{owner}/{repo}/branches/main": {"body": {"protection": {"required_status_checks": {"contexts": [], "checks": []}}}}
        })
    };
    fs::write(&replies, rules("ci/validate").to_string()).unwrap();
    let extra = [
        ("DEV_VALIDATE_RANGE_CMD", "echo range"),
        ("DEV_VALIDATE_CI_CONTEXT", "ci/validate"),
        (
            "PR_VIEW_FIXTURE",
            r#"{"baseRefName": "main", "state": "OPEN"}"#,
        ),
        ("GH_FAKE_REPLIES", &replies.display().to_string()),
        ("GH_FAKE_LOG", &gh_log.display().to_string()),
        ("PATH", &path),
        ("JOB_UNIT_RECORD_ONLY", "1"),
    ];
    let out = w.start(&["--base", &base], &extra);
    let result = ok(&out);
    let run_dir = result["run_dir"].as_str().unwrap().to_owned();
    assert_eq!(
        result["mode"],
        "ci",
        "{}\n{}",
        w.stage(&run_dir),
        run_file(&run_dir, "class.log")
    );
    assert_eq!(result["launched"], false);
    assert_eq!(result["outcome"], "pass");
    let stage = w.stage(&run_dir);
    assert_eq!(stage["proof"]["mode"], "ci");
    assert_eq!(stage["proof"]["ci_event"], "pull_request");
    assert_eq!(stage["proof"]["cmd"], "");
    assert!(stage["proof"].get("ci_fallback").is_none(), "{stage}");
    assert_eq!(stage["outcome"], "pass");
    assert!(!stage["end"].is_null(), "{stage}");
    assert_eq!(stage["job"]["runner"], "none");
    assert!(
        stage.get("notice").is_none(),
        "the caller holds the verdict: {stage}"
    );
    assert!(run_file(&run_dir, "exit").starts_with("guard-exit=0 at="));
    assert_eq!(
        run_file(&run_dir, "log"),
        "runner=none class=small ci-event=pull_request: required CI validates this change\n"
    );
    assert!(
        run_file(&run_dir, "start").contains("validate-mode=ci\nvalidate-base="),
        "{}",
        run_file(&run_dir, "start")
    );
    assert_eq!(
        w.log_lines("job-unit"),
        Vec::<String>::new(),
        "nothing launched"
    );
    assert_eq!(
        fs::read_to_string(&gh_log).unwrap(),
        "api repos/{owner}/{repo}/rules/branches/main\napi repos/{owner}/{repo}/branches/main\n"
    );
    // The base requires another context: the round runs locally, range,
    // with the cause on the record.
    fs::write(&replies, rules("ci/other").to_string()).unwrap();
    let out = w.start(&["--base", &base], &extra);
    let result = ok(&out);
    assert_eq!(result["mode"], "range");
    let local = result["run_dir"].as_str().unwrap().to_owned();
    let stage = w.stage(&local);
    assert_eq!(stage["proof"]["ci_fallback"], "context-unrequired");
    assert_eq!(stage["proof"]["cmd"], "echo range");
    // The started line the dev agent parses carries the CI fallback cause
    // where the rules read fell back.
    assert!(
        result["started_line"]
            .as_str()
            .unwrap()
            .ends_with(" ci-fallback=context-unrequired"),
        "{}",
        result["started_line"]
    );
    // That run ends before the next start of the round.
    ok(&w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &local,
        ],
        &extra,
    ));
    // No open pull request: `pr-not-open`, local.
    let mut no_pr = extra.to_vec();
    no_pr.retain(|(k, _)| *k != "PR_VIEW_FIXTURE");
    fs::write(&replies, rules("ci/validate").to_string()).unwrap();
    let out = w.start(&["--base", &base], &no_pr);
    let stage = w.stage(ok(&out)["run_dir"].as_str().unwrap());
    assert_eq!(stage["proof"]["mode"], "range");
    assert_eq!(stage["proof"]["ci_fallback"], "pr-not-open");
}

/// `dev-validate-run`'s start, `--worktree W --run-id RID`, forwards to
/// `validate start`, prints the `state=started` line as it always printed it,
/// and waits on the run the runtime's job runs to its `state=done` line; a
/// run id no admission named is refused. Defect caught: the dev skill's
/// current call starting a run the runtime never recorded.
#[test]
fn the_legacy_start_forwards_a_run_id_to_validate_start_and_prints_the_started_line() {
    let w = World::new();
    // The admission the dev agent runs, which names the run directory.
    let admitted = ok(&w.op(
        &json!({"op": "record-validation-admission", "round_id": ROUND}),
        &[],
    ));
    let run_id = admitted["report"]["run_id"].as_str().unwrap().to_owned();
    let run_dir = admitted["report"]["run_dir"].as_str().unwrap().to_owned();
    // The wrapper the script runs finds the built binary in its cache under
    // the key agent-runtime computes for these sources.
    let scripts = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts");
    let runtime = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let key_lib = scripts.join("../../agent-runtime/scripts/lib/key.sh");
    let key = program("bash")
        .arg("-c")
        .arg(format!(
            ". '{}' && agent_runtime_key '{}'",
            key_lib.display(),
            runtime.display()
        ))
        .output()
        .unwrap();
    assert!(key.status.success(), "{}", stderr(&key));
    let key = String::from_utf8_lossy(&key.stdout).trim().to_owned();
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
        &w.worktree.display().to_string(),
        "--run-id",
        &run_id,
        "--poll",
        "1",
    ]);
    for (k, v) in w.env() {
        command.env(k, v);
    }
    command
        .env("AGENT_RUNTIME_CACHE", &cache)
        .env("ORCH_STATE_DIR", &w.state)
        .current_dir(&w.worktree);
    let out = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(out.status.code(), Some(0), "{stdout}\n{}", stderr(&out));
    assert_eq!(
        lines[0],
        format!(
            "state=started run-dir={rd} log={rd}/log sentinel={rd}/exit timeout-secs=20 poll-secs=1 cap-secs=31 class=small docs-only=false",
            rd = run_dir
        )
    );
    let done = lines.last().unwrap();
    assert!(
        done.starts_with("state=done guard-exit=0 at=")
            && done.ends_with(&format!(
                " validate=pass run-dir={run_dir} log={run_dir}/log"
            )),
        "{done}"
    );
    assert_eq!(lines.len(), 2, "{stdout}");
    // The stage is read after the job's mark lands, never in the window
    // between the wait's done line and the close.
    w.wait_marked(&run_dir);
    let stage = w.stage(&run_dir);
    assert_eq!(stage["outcome"], "pass");
    assert_eq!(stage["proof"]["mode"], "full");
    assert_eq!(stage["job"]["runner"], "setsid");
    assert_eq!(w.log_lines("lane-mail").len(), 2);
    // A run id no admission named.
    let mut command = program(scripts.join("dev-validate-run"));
    command.args([
        "--worktree",
        &w.worktree.display().to_string(),
        "--run-id",
        "20300101T000000Z-unadmitted",
    ]);
    for (k, v) in w.env() {
        command.env(k, v);
    }
    command
        .env("AGENT_RUNTIME_CACHE", &cache)
        .env("ORCH_STATE_DIR", &w.state)
        .current_dir(&w.worktree);
    let out = command.output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(
        stderr(&out).lines().next().unwrap_or_default(),
        format!(
            "dev-validate-run: run-unadmitted run_dir={}/tmp/dev-validate-20300101T000000Z-unadmitted",
            w.worktree.display()
        )
    );
}

/// The reuse judge over the item's proof rows: a pass over the same tree
/// answers a later start of the same command, class, docs verdict, base
/// and prefix over covered paths, and a later red row at that tree voids
/// it. Defect caught: a battery rerun over a tree it already passed, or a
/// pass reused past a failure at the same tree.
#[test]
fn a_pass_over_the_same_tree_answers_a_later_start_until_a_later_row_at_that_tree_is_red() {
    let w = World::new();
    let extra = [
        ("JOB_UNIT_RECORD_ONLY", "1"),
        ("DEV_VALIDATE_FINDING_PREFIX", "FINDING:"),
    ];
    let first = ok(&w.start(&[], &extra))["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(&w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &first,
        ],
        &extra,
    ));
    assert_eq!(w.stage(&first)["outcome"], "pass");
    let out = w.start(&[], &extra);
    let result = ok(&out);
    assert_eq!(result["launched"], false, "{}", w.state());
    assert_eq!(result["outcome"], "pass");
    let second = result["run_dir"].as_str().unwrap().to_owned();
    let stage = w.stage(&second);
    assert_eq!(
        stage["proof"]["reused"],
        json!({"kind": "pass-run", "run_dir": first})
    );
    assert!(run_file(&second, "start").contains(&format!("pass-run={first}\n")));
    assert_eq!(
        run_file(&second, "log"),
        format!(
            "runner=none pass-run={first}: that run passed this command over the same tree\nvalidate: lanes=fixture selection=all\n"
        )
    );
    assert_eq!(w.log_lines("child").len(), 1, "the command ran once");
    // A later red row at the tree: the next start runs the command.
    let third = ok(&w.start(&["--fresh"], &extra))["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(&w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &third,
        ],
        &[
            ("JOB_UNIT_RECORD_ONLY", "1"),
            ("DEV_VALIDATE_CHILD_EXIT", "1"),
        ],
    ));
    assert_eq!(w.stage(&third)["outcome"], "fail");
    let out = w.start(&[], &extra);
    assert_eq!(ok(&out)["launched"], true);
    assert_eq!(w.log_lines("child").len(), 2);
}

// --- The proof record's reader -------------------------------------------------------

/// A planted proof row as `validate start` writes it and `accept-result`
/// closes it: `mode` in the declaration's command for that mode, at `tree`
/// committed at `head`, over `base` (a range row's base and class base),
/// with `selection`, closed `outcome` at `start + 1`, or open with none.
#[allow(clippy::too_many_arguments)]
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
    /// The item's stages replaced by the dev round's own and `rows`.
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

/// A2 row (1): a `full` pass reporting `selection=battery` at tree T is
/// complete for every need at T, under every declaration; so is a full
/// pass whose class was read over the whole branch. Defect caught: a whole
/// battery rerun at a tree it passed.
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
    // The same for a full row read over the whole branch (no class base),
    // and never for another tree.
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

/// A `range` pass over base B at T is complete for publication only where the
/// declaration admits range at submission and the rows cover the need: over
/// the need's own base, or chained through the base's committed tree to an
/// earlier whole-tree pass. A restack onto a new base B' is complete where a
/// range row covers B'..T' and missing, naming the tree and the mode, where
/// none does; on a full-only project the range row is no proof and `full` is
/// lacked. Defect caught: a full battery rerun at submission after a range
/// pass on a changed tree, and a range row read as the branch's proof on a
/// project that declared the full command alone.
#[test]
fn a_range_pass_is_complete_for_publication_where_range_is_declared_and_its_rows_cover_the_need() {
    let w = World::new();
    let h0 = w.head();
    let t0 = git(&w.worktree, &["rev-parse", "HEAD^{tree}"]);
    let h1 = w.commit("b.txt");
    let t1 = git(&w.worktree, &["rev-parse", "HEAD^{tree}"]);
    // The implement round's full pass at t0 and the fix round's range pass
    // over h0 (the implement commit) at t1: submission at t1 judged from
    // the branch's merge base is complete through the chain.
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
    // A base git cannot read breaks the chain: never coverage.
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
    // The restack: a range row over the new base at the restacked tree.
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
    // A full-only project: the range row proves nothing, full is lacked.
    let read = w.read_proof(&covered, &[]);
    assert_eq!(read["proof"], "missing");
    assert_eq!(
        read["lacks"],
        json!({"tree": "t-restacked", "mode": "full"})
    );
    // A CI gate declared: publication needs CI or the full battery; the
    // round's own need still admits the range row.
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

/// A2 row (3), A4's submission row: a scoped row covers nothing of the
/// branch and a `ci` row proves nothing locally: it reads `pending`, the
/// submission proof of a CI-gated project with required CI still to run.
/// Defect caught: a scoped subset run published as the branch's proof; a
/// CI-pending row read as a local pass.
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

/// A2 row (4): a later row of any local mode at the same tree that did not
/// pass voids the earlier pass; a pass after a fail stands. Defect caught:
/// a pass reused past a later red at its tree.
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
    // The reverse order: the pass stands. An open later run voids it too.
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

/// § B's restack case through a recorded skip: the restacked head's skip
/// names the validated run's head, whose row at its own tree is the branch's
/// proof; the reader says which skip it read through. Defect caught: a
/// skipped restack whose validated run was a scoped or range pass on a
/// full-only project read as proven.
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
    // A range pass behind the skip on a full-only project proves nothing.
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

/// The tree a restack asks about has evidence of its own, and its own
/// evidence outranks the recorded skip's equivalence claim: a row at the
/// restacked tree that did not pass (red, or still open) refuses the skip's
/// fallback to the validated run's tree, whether or not an earlier pass at
/// the restacked tree stands voided beside it; the skip proves as before only
/// where the restacked tree has no row of its own. Defect caught: an
/// equivalence-based proof outliving the restacked tree's own red run, a
/// fail-open merge gate.
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
    // The reviewer's construction: a pass, then a red, at the restacked tree.
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
    // The red alone, and a run still open, refuse the skip too.
    for own in [
        restacked("restacked-red", Some("fail"), 30),
        restacked("restacked-open", None, 30),
    ] {
        w.plant(&[original.clone(), own], std::slice::from_ref(&skip));
        let read = w.read_proof(&ask, &[]);
        assert_eq!(read["proof"], "missing", "{read}");
    }
    // With no row of its own, the restacked tree is proven through the
    // skip as before.
    w.plant(std::slice::from_ref(&original), std::slice::from_ref(&skip));
    let read = w.read_proof(&ask, &[]);
    assert_eq!(read["proof"], "complete", "{read}");
    assert_eq!(read["rows"][0]["tree"], "t-original");
}

/// A2 row (6): a recovery is the round's second run accepted `pass` after
/// a first `fail`, both as the runtime ran them: two validate stages, one
/// pass row, and the recovery need reads the round's own rows. Defect
/// caught: a round whose failed run blocks its next attempt, or whose
/// later pass is read as voided by the earlier fail.
#[test]
fn a_recovery_is_the_rounds_later_pass_after_its_first_run_failed() {
    let w = World::new();
    let extra = [("JOB_UNIT_RECORD_ONLY", "1")];
    let first = ok(&w.start(&[], &extra))["run_dir"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(&w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &first,
        ],
        &[
            ("JOB_UNIT_RECORD_ONLY", "1"),
            ("DEV_VALIDATE_CHILD_EXIT", "1"),
        ],
    ));
    assert_eq!(w.stage(&first)["outcome"], "fail");
    let tree = w.stage(&first)["proof"]["tree"]
        .as_str()
        .unwrap()
        .to_owned();
    let read = w.read_proof(
        &["--need", "recovery", "--round", ROUND, "--tree", &tree],
        &[],
    );
    assert_eq!(read["proof"], "missing");
    // The next attempt of the same round: a new stage, its own run.
    let result = ok(&w.start(&[], &extra));
    assert_eq!(result["launched"], true, "{}", w.state());
    let second = result["run_dir"].as_str().unwrap().to_owned();
    assert_ne!(second, first);
    ok(&w.run(
        &[
            "validate",
            "run",
            "--item",
            ITEM_ID,
            "--round",
            ROUND,
            "--run-dir",
            &second,
        ],
        &extra,
    ));
    assert_eq!(w.stage(&second)["outcome"], "pass");
    let read = w.read_proof(
        &["--need", "recovery", "--round", ROUND, "--tree", &tree],
        &[],
    );
    assert_eq!(read["proof"], "complete", "{read}");
    assert_eq!(read["rows"][0]["run_dir"], second);
    assert_eq!(read["rows"][0]["round_id"], ROUND);
    let stages: Vec<Value> = w.state()["stages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["kind"] == "validate")
        .cloned()
        .collect();
    assert_eq!(stages.len(), 2);
    assert_eq!(stages[0]["outcome"], "fail");
    assert_eq!(stages[1]["outcome"], "pass");
    // A recovery reads the round's own rows: another round's name proves
    // nothing.
    let read = w.read_proof(
        &[
            "--need",
            "recovery",
            "--round",
            "other-round",
            "--tree",
            &tree,
        ],
        &[],
    );
    assert_eq!(read["proof"], "missing");
}
