//! The wake entry, `scripts/open-terminal --wake`, through the real
//! executable over a Claude lane the real `launch-lane` launched on a
//! private tmux server: a codex or copilot wake is refused by the harness
//! gate, a record no longer in flight by its status, and a second wake
//! while the turn the first started still runs by that turn's recorded
//! identity, each before the runtime is asked anything; and the lane record
//! the recovery suites plant is the one this launch wrote. Each row's name
//! carries the defect it catches, and each row holds the runtime's own
//! reading beside the wake's answer. The scripts run from a directory of
//! links to the shipped tree under a private home, and a control copies the
//! entry with its rule cut.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold a private tmux server and plant the homes and stubs the entry reads"
)]

#[path = "support.rs"]
mod support;

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::*;

const CLAUDE_ID: &str = "22222222-2222-2222-2222-222222222222";
const PERMISSION: &str = "--permission-mode dontAsk";

fn scripts() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts")
}

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("tests/fixtures/launch-lane/claude-dontask.json")
}

/// The shipped scripts as a directory of links under `root`, the mailbox
/// skill linked beside them as the store's lock library expects, so the
/// entry resolves its libraries beside itself and no checkout above it is a
/// project root; with `edit`, `open-terminal` is a copy with that one text
/// replaced, the control's cut.
fn linked_scripts(root: &Path, name: &str, edit: Option<(&str, &str)>) -> PathBuf {
    let skills = scripts().parent().unwrap().parent().unwrap().to_path_buf();
    let dir = root.join(name).join("orch/scripts");
    std::fs::create_dir_all(&dir).unwrap();
    std::os::unix::fs::symlink(skills.join("mailbox"), root.join(name).join("mailbox")).unwrap();
    for entry in std::fs::read_dir(scripts()).unwrap().flatten() {
        std::os::unix::fs::symlink(entry.path(), dir.join(entry.file_name())).unwrap();
    }
    if let Some((old, new)) = edit {
        let text = std::fs::read_to_string(scripts().join("open-terminal")).unwrap();
        assert_eq!(
            text.matches(old).count(),
            1,
            "the control's one site: {old}"
        );
        std::fs::remove_file(dir.join("open-terminal")).unwrap();
        write_executable(&dir.join("open-terminal"), text.replace(old, new));
    }
    dir
}

/// Wait for `path` to hold readable JSON, bounded.
fn await_json(path: &Path) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Ok(value) = serde_json::from_str::<Value>(&text)
        {
            return value;
        }
        assert!(
            Instant::now() < deadline,
            "nothing readable at {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Wait until none of `pids` is live, bounded.
fn await_ended(pids: &[u32]) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while pids.iter().any(|pid| live(*pid)) {
        assert!(
            Instant::now() < deadline,
            "a woken turn still runs: {pids:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// One lane, launched by the real `launch-lane` into the runner's checkout
/// with the narrow permission choice, its pane on the fleet server running
/// the recording stub at its composer; beside it the Claude session store
/// naming the checkout, and the stubs the wake calls: the harness, which
/// records the pid of each turn it was woken as and holds while the hold
/// file stands; the worktree CLI; the runtime as the real binary under the
/// runner's environment, each call it gets written down.
struct Lane {
    _dir: tempfile::TempDir,
    root: PathBuf,
    _server: Server,
    runner: Runner,
    bin: PathBuf,
    home: PathBuf,
    capture: PathBuf,
    calls: PathBuf,
    hold: PathBuf,
    fifo: PathBuf,
}

impl Lane {
    fn new() -> Lane {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        let server = Server::start(&root, "fleet");
        let runner = Runner::new(&server, "stub-record");
        runner.init_fleet();
        let work = runner.state_dir().to_path_buf();
        let mut request = launch_request("KEN-1", &work);
        request["model"] = json!("claude-fable-5-1");
        request["effort"] = json!("high");
        request["permission"] = json!(PERMISSION);
        let report = effect_report(&runner.op_fleet(&request));
        assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
        // The stub writes its record as it starts: the harness is up.
        await_json(&work.join("launch-record.json"));
        let home = root.join("home");
        let projects = home.join(".claude-shared/projects/repo");
        std::fs::create_dir_all(&projects).unwrap();
        std::fs::write(
            projects.join(format!("{CLAUDE_ID}.jsonl")),
            format!(
                "{}\n",
                json!({"type": "user", "cwd": work, "isSidechain": false, "message": {"content": "Continue."}})
            ),
        )
        .unwrap();
        let bin = root.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let capture = root.join("woken");
        let calls = root.join("runtime-calls");
        let hold = root.join("hold");
        let fifo = root.join("wake.fifo");
        mkfifo(&fifo);
        write_executable(
            &bin.join("claude"),
            format!(
                "#!/bin/bash\nprintf '%s\\n' \"$$\" >> '{}'\n[ -e '{}' ] || exit 0\nexec 9<>'{}'\nread -r -t 60 -u 9 _\n",
                capture.display(),
                hold.display(),
                fifo.display()
            ),
        );
        write_executable(
            &bin.join("worktree"),
            format!(
                "#!/bin/sh\n[ \"$1\" = path ] || exit 1\nprintf '%s\\n' '{}'\n",
                work.display()
            ),
        );
        write_executable(
            &bin.join("orch-runtime"),
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nexec '{}' --no-private-env \"$@\"\n",
                calls.display(),
                binary().display()
            ),
        );
        Lane {
            _dir: dir,
            root,
            _server: server,
            runner,
            bin,
            home,
            capture,
            calls,
            hold,
            fifo,
        }
    }

    fn record(&self) -> Value {
        self.runner.fleet()["lanes"][0].clone()
    }

    fn set_status(&self, status: &str) {
        let mut fleet = self.runner.fleet();
        fleet["lanes"][0]["status"] = json!(status);
        self.runner.write_fleet(&fleet);
    }

    /// `lane status --item KEN-1` through the real executable.
    fn status(&self) -> Output {
        self.runner.run(&["lane", "status", "--item", "KEN-1"])
    }

    /// The wake of KEN-1 as `harness` through `entry`, a scripts directory
    /// under the root, with every stub on its path and the runtime's
    /// environment.
    fn wake(&self, entry: &Path, harness: &str) -> Output {
        let mut command = Command::new(entry.join("open-terminal"));
        isolation_env(&mut command);
        self.runner.apply_env(&mut command);
        command
            .args([
                "--wake",
                "--harness",
                harness,
                "--state-dir",
                &self.runner.state_dir().display().to_string(),
                "KEN-1",
            ])
            .current_dir(self.runner.state_dir())
            .env("PATH", tool_path(&[&self.bin]))
            .env("HOME", &self.home)
            .env("LANES_HOME", &self.home)
            .env("WORKTREE_CLI", self.bin.join("worktree"))
            .env("ORCH_RUNTIME_CLI", self.bin.join("orch-runtime"))
            .env("GH_ISSUE_PATTERN", "[A-Z]+-[0-9]+");
        command.output().unwrap()
    }

    /// The runtime calls the wake made, one line each.
    fn calls(&self) -> Vec<String> {
        std::fs::read_to_string(&self.calls)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The pids of the turns the harness stub was woken as, in order.
    fn woken(&self) -> Vec<u32> {
        std::fs::read_to_string(&self.capture)
            .unwrap_or_default()
            .lines()
            .map(|line| line.trim().parse().unwrap())
            .collect()
    }

    /// Wait until the stub has recorded `n` woken turns, bounded.
    fn await_woken(&self, n: usize) -> Vec<u32> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let pids = self.woken();
            if pids.len() >= n {
                return pids;
            }
            assert!(
                Instant::now() < deadline,
                "{n} woken turns expected, {pids:?} recorded"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// Release every held turn and wait for it to end. The held turns share
    /// one fifo and any of them may read any line, so the held set is taken
    /// before the first line is written: a liveness read between writes sees
    /// a turn the previous line released and skips the line another still
    /// waits on.
    fn release(&self, pids: &[u32]) {
        let _ = std::fs::remove_file(&self.hold);
        let held: Vec<u32> = pids.iter().copied().filter(|pid| live(*pid)).collect();
        for _ in &held {
            release_hold(&self.fifo, Duration::from_secs(10), || {
                format!("the held turns {held:?} never opened their fifo")
            });
        }
        await_ended(pids);
    }
}

/// A row that fails while a turn is held leaves no turn running past it:
/// each recorded turn still running gets its line, written on a thread of
/// its own since the write waits for the turn to open the fifo, and the
/// teardown waits, bounded, for every one to end. Nothing here panics: it
/// runs while a failed assertion unwinds.
impl Drop for Lane {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.hold);
        let held: Vec<u32> = std::fs::read_to_string(&self.capture)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| line.trim().parse().ok())
            .filter(|pid| live(*pid))
            .collect();
        for _ in &held {
            let fifo = self.fifo.clone();
            std::thread::spawn(move || std::fs::write(fifo, b"go\n"));
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while held.iter().any(|pid| live(*pid)) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

/// A codex or copilot wake reaching the runtime, or a session lookup, for
/// a harness no wake may resume: neither publishes an idle signal, so a
/// resume would run beside a live session; the gate refuses the harness
/// word before any read.
#[test]
fn a_codex_or_copilot_wake_is_refused_by_the_harness_gate_before_any_read() {
    let lane = Lane::new();
    let entry = linked_scripts(&lane.root, "scripts", None);
    for harness in ["codex", "copilot"] {
        let out = lane.wake(&entry, harness);
        assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
        assert!(
            stderr(&out).contains(&format!(
                "open-terminal: wake-invalid option=--wake harness={harness}\n"
            )),
            "{}",
            stderr(&out)
        );
    }
    assert_eq!(lane.calls(), Vec::<String>::new(), "the runtime was asked");
    assert_eq!(lane.woken(), Vec::<u32>::new(), "a turn started");
    // The control: the gate widened, a codex wake asks the runtime and goes
    // looking for a codex session of the lane.
    let cut = linked_scripts(
        &lane.root,
        "scripts-cut",
        Some(("^(claude|pi)$", "^(claude|codex|pi|copilot)$")),
    );
    let out = lane.wake(&cut, "codex");
    assert!(
        lane.calls()
            .iter()
            .any(|call| call.contains("lane status --item KEN-1")),
        "{:?}",
        lane.calls()
    );
    assert!(
        stderr(&out).contains("open-terminal: session-missing item=KEN-1 harness=codex\n"),
        "{}",
        stderr(&out)
    );
}

/// A wake of a lane whose record is no longer in flight resuming its
/// session: the runtime judges only an in-flight record (`lane-missing`
/// for this one), and the wake refuses the record by its status before
/// asking.
#[test]
fn a_record_no_longer_in_flight_is_refused_by_its_status_before_the_read() {
    let lane = Lane::new();
    lane.set_status("done");
    let status = lane.status();
    assert_eq!(status.status.code(), Some(1), "{}", stderr(&status));
    assert_eq!(
        reply(&status)["refusal"]["key"],
        json!("lane-missing"),
        "{}",
        stderr(&status)
    );
    let entry = linked_scripts(&lane.root, "scripts", None);
    let out = lane.wake(&entry, "claude");
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    assert!(
        stderr(&out)
            .contains("open-terminal: wake-invalid option=--wake harness=claude status=done\n"),
        "{}",
        stderr(&out)
    );
    assert_eq!(lane.calls(), Vec::<String>::new(), "the runtime was asked");
    assert_eq!(lane.woken(), Vec::<u32>::new(), "a turn started");
    // The control: the status check cut, the wake asks the runtime, whose
    // refusal it reads as unjudged.
    let cut = linked_scripts(
        &lane.root,
        "scripts-cut",
        Some((
            "    preparing | running) ;;\n",
            "    preparing | running | done) ;;\n",
        )),
    );
    let out = lane.wake(&cut, "claude");
    let err = stderr(&out);
    assert!(
        err.contains("orch-runtime: lane-missing item=KEN-1")
            && err.contains("open-terminal: wake-refused item=KEN-1 reason=unjudged\n"),
        "{err}"
    );
}

/// A second wake starting a turn beside the one the first wake started:
/// the detached print-mode turn runs outside the pane, whose composer the
/// runtime reads `idle` all the while, so the pane's word admits it; the
/// wake refuses by the turn's identity the record names, before any status
/// read, and keeps that identity for lane-close. A turn that ended is no
/// turn: the next wake starts one and records it.
#[test]
fn a_second_wake_while_the_first_turn_runs_is_refused_before_any_status_read() {
    let lane = Lane::new();
    let entry = linked_scripts(&lane.root, "scripts", None);
    std::fs::write(&lane.hold, b"").unwrap();
    let first = lane.wake(&entry, "claude");
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    let turns = lane.await_woken(1);
    let first_wake = lane.record()["wake"].clone();
    assert!(
        first_wake["pid"].as_u64().is_some() && first_wake["start"].as_str().is_some(),
        "the first wake recorded its turn: {first_wake}"
    );
    assert!(live(turns[0]), "the first turn runs on");
    let state = reply(&lane.status());
    assert_eq!(
        state["result"]["state"],
        json!("idle"),
        "the pane reads idle while the detached turn runs: {state}"
    );
    let calls_before = lane.calls();
    let second = lane.wake(&entry, "claude");
    assert_eq!(second.status.code(), Some(1), "{}", stderr(&second));
    assert!(
        stderr(&second).contains("open-terminal: wake-refused item=KEN-1 reason=wake-running\n"),
        "{}",
        stderr(&second)
    );
    assert_eq!(
        lane.calls(),
        calls_before,
        "the second wake asked the runtime"
    );
    assert_eq!(
        lane.record()["wake"],
        first_wake,
        "the second wake rewrote the first turn's identity"
    );
    assert_eq!(lane.woken().len(), 1, "a second turn started");
    lane.release(&turns);
    // The turn over, its identity is no turn: the next wake starts one.
    let third = lane.wake(&entry, "claude");
    assert_eq!(third.status.code(), Some(0), "{}", stderr(&third));
    let turns = lane.await_woken(2);
    assert_ne!(
        lane.record()["wake"],
        first_wake,
        "the wake after the turn ended recorded its own turn"
    );
    await_ended(&turns);
    // The control: the liveness read cut, every recorded turn reads ended,
    // and the second wake starts a turn beside the running first.
    let cut = linked_scripts(
        &lane.root,
        "scripts-cut",
        Some((
            "    lane_identity_status \"${wake_identity%% *}\" \"${wake_identity#* }\" || wake_rc=$?\n",
            "    wake_rc=3\n",
        )),
    );
    std::fs::write(&lane.hold, b"").unwrap();
    let first = lane.wake(&cut, "claude");
    assert_eq!(first.status.code(), Some(0), "{}", stderr(&first));
    let turns = lane.await_woken(3);
    let first_wake = lane.record()["wake"].clone();
    let second = lane.wake(&cut, "claude");
    let turns = {
        let more = lane.await_woken(4);
        assert_eq!(second.status.code(), Some(0), "{}", stderr(&second));
        assert_ne!(
            lane.record()["wake"],
            first_wake,
            "the control kept the identity"
        );
        assert!(
            live(turns[2]) && live(more[3]),
            "the control's two turns run beside each other"
        );
        more
    };
    lane.release(&turns[2..]);
}

/// The lane record the shell suites plant drifting from what the real
/// `launch-lane` writes: `tests/lane_model_recovery.sh` and the hook's
/// `lane-mail-model-switch.test.sh` read the permission words off the
/// record the fixture holds, and `tests/lane-state.sh` and
/// `tests/lane_close.sh` read its launch identity in the start's form, so
/// the fixture is this launch's record, its root and its process, pane and
/// clock values as placeholders and the start's form (`ticks:`) kept before
/// its placeholder.
#[test]
fn the_recovery_suites_planted_record_is_the_real_launch_lanes() {
    let lane = Lane::new();
    let work = lane.runner.state_dir().display().to_string();
    let mut record = lane.record();
    for (field, placeholder) in [
        ("pane", "@PANE@"),
        ("server", "@SERVER@"),
        ("server_start", "@SERVER_START@"),
        ("pid", "@PID@"),
    ] {
        if record["launch"].get(field).is_some() {
            record["launch"][field] = json!(placeholder);
        }
    }
    if let Some(start) = record["launch"]["start"].as_str() {
        let form = start.split_once(':').map_or("", |(form, _)| form);
        record["launch"]["start"] = json!(format!("{form}:@START@"));
    }
    for (field, placeholder) in [
        ("session_id", "@SESSION_ID@"),
        ("launched_at", "@LAUNCHED_AT@"),
        ("running_at", "@RUNNING_AT@"),
        ("session_since", "@SESSION_SINCE@"),
    ] {
        assert!(record[field].is_string(), "{field} on the record: {record}");
        record[field] = json!(placeholder);
    }
    let text = serde_json::to_string_pretty(&record)
        .unwrap()
        .replace(&work, "@ROOT@");
    let planted: Value =
        serde_json::from_str(&std::fs::read_to_string(fixture()).unwrap()).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&text).unwrap(),
        planted,
        "the fixture is not this launch's record:\n{text}"
    );
    assert_eq!(planted["permission"], json!(PERMISSION), "{planted}");
}
