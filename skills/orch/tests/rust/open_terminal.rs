//! The wake entry, `scripts/open-terminal --wake`, over the runtime's lane
//! status through the real executable: a Codex pane the runtime reads
//! `idle` still holds the live session, which no second process may run
//! beside, and a record no longer in flight is refused by its status before
//! any read. Each row names the defect it catches at its doc comment and
//! holds the runtime's own reading beside the wake's answer. The scripts
//! run from a directory of links to the shipped tree under a private home,
//! the lane's pane on a private tmux server, and a control copies the entry
//! with its rule cut.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold a private tmux server and plant the records and homes the entry reads"
)]

#[path = "support.rs"]
mod support;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use serde_json::json;
use support::*;

const CODEX_ID: &str = "44444444-4444-4444-4444-444444444444";

fn scripts() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts")
}

fn executable(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
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
        executable(&dir.join("open-terminal"), &text.replace(old, new));
    }
    dir
}

/// One lane: its worktree, the Codex session store naming it, the stubs
/// the wake calls (the harness, which records the line it was woken with;
/// the worktree CLI; the account listing; the runtime as the real binary
/// under the runner's environment), its pane on the fleet server running a
/// Codex stand-in at its idle composer, and its running record naming that
/// pane and process.
struct Lane {
    _dir: tempfile::TempDir,
    root: PathBuf,
    _server: Server,
    runner: Runner,
    bin: PathBuf,
    home: PathBuf,
    capture: PathBuf,
}

impl Lane {
    fn new() -> Lane {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        let server = Server::start(&root, "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let wt = root.join("wt/KEN-1");
        let home = root.join("home");
        let codex_home = home.join(".codex");
        let bin = root.join("bin");
        let capture = root.join("woken");
        for sub in [&wt, &codex_home.join("sessions/2026"), &bin] {
            std::fs::create_dir_all(sub).unwrap();
        }
        std::fs::write(
            codex_home.join("sessions/2026/rollout.jsonl"),
            format!(
                "{}\n",
                json!({"type": "session_meta", "payload": {"id": CODEX_ID, "cwd": wt, "source": "cli", "parent_thread_id": null}})
            ),
        )
        .unwrap();
        executable(
            &bin.join("codex"),
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"codex $*\" > '{}'\n",
                capture.display()
            ),
        );
        executable(
            &bin.join("worktree"),
            &format!(
                "#!/bin/sh\n[ \"$1\" = path ] || exit 1\nprintf '%s\\n' '{}'\n",
                wt.display()
            ),
        );
        executable(
            &bin.join("lanes"),
            &format!(
                "#!/bin/sh\nprintf '[{{\"config_dir\":\"%s\"}}]\\n' '{}'\n",
                codex_home.display()
            ),
        );
        executable(
            &bin.join("orch-runtime"),
            &format!(
                "#!/bin/sh\nexec '{}' --no-private-env \"$@\"\n",
                binary().display()
            ),
        );
        // The pane: a process named `codex` drawing Codex's composer and
        // holding its stdin, as a live session at its prompt does.
        let pane_bin = root.join("pane-bin");
        std::fs::create_dir_all(&pane_bin).unwrap();
        executable(
            &pane_bin.join("codex"),
            "#!/bin/bash\nprintf '\\342\\200\\272 Ask Codex to do anything\\n'\nwhile read -r line; do :; done\n",
        );
        let pane = server.open_window("KEN-1", &wt, &pane_bin.join("codex").display().to_string());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            let cap = tmux(&server.socket, &["capture-pane", "-p", "-t", &pane]);
            if String::from_utf8_lossy(&cap.stdout).contains('\u{203a}') {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the composer was never drawn"
            );
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let pid = server.pane_pid(&pane);
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([{
            "item": "KEN-1", "tracker": "linear", "repo": null, "harness": "codex",
            "window": "fleet:KEN-1", "account": null, "host": null, "kind": "local",
            "mail_root": wt, "surface": "tmux", "model": "gpt-6", "effort": "high",
            "session_id": null, "session_since": "2026-01-29T15:00:00Z",
            "launched_at": "2026-01-29T15:00:00Z", "running_at": "2026-01-29T15:00:01Z",
            "status": "running", "over_cap": null, "allow_all": null,
            "launch": {"pane": pane, "server": server.pid, "pid": pid, "start": start_of(pid)}
        }]);
        runner.write_fleet(&fleet);
        Lane {
            _dir: dir,
            root,
            _server: server,
            runner,
            bin,
            home,
            capture,
        }
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

    /// The wake of KEN-1 through `entry`, a scripts directory under the
    /// root, with every stub on its path and the runtime's environment.
    fn wake(&self, entry: &Path) -> Output {
        let _ = std::fs::remove_file(&self.capture);
        let mut command = Command::new(entry.join("open-terminal"));
        isolation_env(&mut command);
        self.runner.apply_env(&mut command);
        let codex_home = self.home.join(".codex");
        command
            .args([
                "--wake",
                "--harness",
                "codex",
                "--state-dir",
                &self.runner.state_dir().display().to_string(),
                "KEN-1",
            ])
            .current_dir(self.runner.state_dir())
            .env("PATH", tool_path(&[&self.bin]))
            .env("HOME", &self.home)
            .env("LANES_HOME", &self.home)
            .env("CODEX_HOME", &codex_home)
            .env("WORKTREE_CLI", self.bin.join("worktree"))
            .env("LANES_CLI", self.bin.join("lanes"))
            .env("ORCH_RUNTIME_CLI", self.bin.join("orch-runtime"))
            .env("GH_ISSUE_PATTERN", "[A-Z]+-[0-9]+");
        command.output().unwrap()
    }

    /// The line the harness stub was woken with, where a wake started one.
    fn woken(&self) -> Option<String> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !self.capture.exists() {
            if std::time::Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        Some(
            std::fs::read_to_string(&self.capture)
                .unwrap()
                .trim()
                .to_owned(),
        )
    }
}

/// The wake starting a second Codex process beside a live session: the
/// runtime reads the pane at its composer `idle` with the harness in the
/// foreground, and Codex publishes no idle signal, so the wake refuses
/// that lane as `unjudged` and starts nothing.
#[test]
fn a_live_codex_pane_the_runtime_reads_idle_is_refused_by_the_wake() {
    let lane = Lane::new();
    let status = lane.status();
    assert!(status.status.success(), "{}", stderr(&status));
    let result = &reply(&status)["result"];
    assert_eq!(result["state"], json!("idle"), "{result}");
    assert!(
        result["identity"]
            .as_str()
            .is_some_and(|i| i.contains(":ticks:")),
        "the recorded process is the live one: {result}"
    );
    let entry = linked_scripts(&lane.root, "scripts", None);
    let out = lane.wake(&entry);
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    assert!(
        stderr(&out).contains("open-terminal: wake-refused item=KEN-1 reason=unjudged\n"),
        "{}",
        stderr(&out)
    );
    assert_eq!(
        lane.woken(),
        None,
        "nothing started beside the live session"
    );
    // The control: the rule cut, the wake resumes the session beside the
    // live pane.
    let cut = linked_scripts(
        &lane.root,
        "scripts-cut",
        Some((
            "    case \"$HARNESS\" in codex | copilot) message wake-refused \"item=$item\" \"reason=unjudged\" >&2; return 1 ;; esac\n",
            "",
        )),
    );
    let out = lane.wake(&cut);
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let line = lane.woken().expect("the control started a second process");
    assert!(
        line.starts_with("codex exec resume ") && line.contains(CODEX_ID),
        "{line}"
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
    let out = lane.wake(&entry);
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    let err = stderr(&out);
    assert!(
        err.contains("open-terminal: wake-invalid option=--wake harness=codex status=done\n"),
        "{err}"
    );
    assert!(
        !err.contains("orch-runtime: lane-missing"),
        "the record is refused before the read: {err}"
    );
    assert_eq!(lane.woken(), None);
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
    let out = lane.wake(&cut);
    let err = stderr(&out);
    assert!(
        err.contains("orch-runtime: lane-missing item=KEN-1")
            && err.contains("open-terminal: wake-refused item=KEN-1 reason=unjudged\n"),
        "{err}"
    );
}
