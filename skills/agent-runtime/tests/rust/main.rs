//! Process-protocol tests of the `agent-runtime` executable: they run the
//! built binary against fixtures this harness owns.

use std::path::{Path, PathBuf};
use std::process::Command;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_agent-runtime"))
}

/// `text` as the executable `path`, written by a child shell: a write
/// descriptor open in this process leaks into any sibling test's child
/// between its fork and exec, and an exec of the file meanwhile fails with
/// ETXTBSY.
fn write_executable(path: &std::path::Path, text: impl AsRef<str>) {
    let written = Command::new("sh")
        .args(["-c", "printf '%s' \"$2\" > \"$1\" && chmod 755 \"$1\"", "_"])
        .arg(path)
        .arg(text.as_ref())
        .status()
        .unwrap();
    assert!(written.success(), "write-executable {}", path.display());
}

#[test]
fn version_prints_the_protocol_reply() {
    let out = Command::new(binary()).arg("version").output().unwrap();
    assert!(out.status.success());
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["protocol"], "agent-runtime-v1");
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["result"]["protocol"], "agent-runtime-v1");
}

#[test]
fn a_refusal_prints_one_keyed_line_and_a_refused_reply() {
    let dir = tempfile::tempdir().unwrap();
    let out = Command::new(binary())
        .args(["inspect", "--record"])
        .arg(dir.path().join("none.json"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.lines()
            .next()
            .unwrap()
            .starts_with("agent-runtime: record-missing path="),
        "{err}"
    );
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["refusal"]["key"], "record-missing");
}

/// A usage error is clap's, not a refusal: the keyed usage line, clap's
/// message, exit 2 and no JSON reply. orch-runtime answers the same way, so
/// a wrapper routing on the exit status reads both alike.
#[test]
fn a_usage_error_prints_the_usage_key_exits_2_and_gives_no_reply() {
    let rows: [&[&str]; 3] = [
        &["inspect"],
        &["judge", "--harness", "claude"],
        &["frobnicate"],
    ];
    for args in rows {
        let out = Command::new(binary()).args(args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert_eq!(
            stderr.lines().next().unwrap_or_default(),
            "agent-runtime: usage",
            "{args:?}"
        );
        assert!(stderr.lines().count() >= 2, "{args:?}: {stderr}");
        assert!(out.stdout.is_empty(), "{args:?}");
    }
    let out = Command::new(binary()).arg("--help").output().unwrap();
    assert!(out.status.success());
    assert!(out.stderr.is_empty());
}

/// The one runner drains both pipes while the child runs: a reply larger
/// than a pipe holds (more than 1 MiB on stdout beside 200 KiB on stderr)
/// arrives whole within the timeout instead of the child blocking on a
/// full pipe until the timeout kills it.
#[test]
fn the_runner_reads_an_answer_larger_than_a_pipe_within_the_timeout() {
    use std::path::Path;
    use std::time::Duration;
    let out = agent_runtime::host::run(
        "sh",
        Path::new("sh"),
        "flood",
        &[
            "-c",
            "head -c 1200000 /dev/zero | tr '\\0' x; head -c 200000 /dev/zero | tr '\\0' e >&2",
        ],
        Duration::from_secs(20),
    )
    .unwrap();
    assert!(out.status.success());
    assert_eq!(out.stdout.len(), 1_200_000);
    assert!(out.stdout.iter().all(|b| *b == b'x'));
    assert_eq!(out.stderr.len(), 200_000);
    assert!(out.stderr.iter().all(|b| *b == b'e'));
}

/// The bypass posture is the one place a harness's permission flag is
/// spelled; a native posture never carries it.
#[test]
fn a_bypass_launch_spells_the_claude_bypass_flag_and_a_native_one_does_not() {
    use agent_runtime::Harness;
    use agent_runtime::launch::{Brief, Compaction, LaunchIntent, Permission, QuestionTool, build};
    let intent = |permission: Permission| LaunchIntent {
        harness: Harness::Claude,
        home: Some("/home/x/.1claude".into()),
        account: None,
        cwd: "/work/tree".into(),
        model: Some("opus".into()),
        effort: None,
        agent: None,
        permission,
        question_tool: QuestionTool::Off,
        compaction: Compaction::Native,
        brief: Brief::None,
        resume: None,
        session_id: None,
        env: Default::default(),
        env_remove: Vec::new(),
        compaction_env: None,
        extra_args: Vec::new(),
        program: None,
        grants: None,
        claude_sign_in: None,
    };
    let flag = "--dangerously-skip-permissions".to_owned();
    let bypass = build(&intent(Permission::Bypass)).unwrap();
    assert_eq!(bypass.args.iter().filter(|a| **a == flag).count(), 1);
    let native = build(&intent(Permission::Native)).unwrap();
    assert!(!native.args.contains(&flag));
}

/// Pi 1.4.0's default composer at rest: the capture-pane output of a real
/// Pi session at rest once its turns ended.
const PI_IDLE: &str = include_str!("fixtures/pi-idle.txt");
/// The same session while its first turn ran: the drawn lines its
/// inspection kept, with the `── ⠹ Working ──` editor border.
const PI_WORKING: &str = include_str!("fixtures/pi-working.txt");

#[test]
fn pi_captures_judge_idle_at_rest_and_working_mid_turn() {
    use agent_runtime::Harness;
    use agent_runtime::observe::{ProcessReading, State, judge};
    assert_eq!(
        judge(PI_IDLE, Harness::Pi, &ProcessReading::HarnessUp, None),
        State::Idle
    );
    assert_eq!(
        judge(PI_WORKING, Harness::Pi, &ProcessReading::HarnessUp, None),
        State::Working
    );
    // The same idle capture settles nothing for a marker-drawing harness.
    assert!(matches!(
        judge(PI_IDLE, Harness::Claude, &ProcessReading::HarnessUp, None),
        State::Unjudged { .. }
    ));
}

/// `judge` over a capture file answers the screen's state with exit 0,
/// `working` as much as `idle`, so a sender reads the state and never the
/// exit status; a harness it has no rule for is a refusal, exit 1.
#[test]
fn judge_answers_the_screen_s_state_and_refuses_a_harness_it_does_not_know() {
    use agent_runtime::effects::prepare::up;
    use agent_runtime::observe::State;

    let runtime = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let fixtures = runtime.join("../tests/rust/fixtures");
    let dir = tempfile::tempdir().unwrap();
    let setup = dir.path().join("setup.txt");
    std::fs::write(&setup, "Choose a theme\n❯ 1. Dark\n  2. Light\n").unwrap();
    let dialog = dir.path().join("dialog.txt");
    std::fs::write(
        &dialog,
        "◉ Working ctrl+c interrupt\nSelect a model\n❯ 1. GPT-6.1 Sol\n  2. Auto\n",
    )
    .unwrap();
    let process_only = dir.path().join("process-only.txt");
    std::fs::write(&process_only, "Copilot v1.0.109 uses AI.\n").unwrap();
    let ask = |screen: &std::path::Path, harness: &str| {
        reply_of(&[
            "judge".as_ref(),
            "--screen".as_ref(),
            screen.as_os_str(),
            "--harness".as_ref(),
            harness.as_ref(),
        ])
    };
    for (screen, harness, want, ready) in [
        (fixtures.join("pi-idle.txt"), "pi", "idle", true),
        (fixtures.join("pi-working.txt"), "pi", "working", true),
        (
            fixtures.join("copilot-model-turn-sidebar.txt"),
            "copilot",
            "working",
            true,
        ),
        (
            fixtures.join("copilot-model-turn.txt"),
            "copilot",
            "working",
            true,
        ),
        (
            runtime.join("../../orch/tests/fixtures/oversee-watch/copilot-dialog-trust.txt"),
            "copilot",
            "asking",
            false,
        ),
        (setup, "copilot", "asking", false),
        (
            runtime.join("../../orch/tests/fixtures/oversee-watch/copilot-idle.txt"),
            "copilot",
            "walled",
            false,
        ),
        (dialog, "copilot", "asking", false),
        (process_only, "copilot", "unjudged", false),
    ] {
        let (code, reply) = ask(&screen, harness);
        assert_eq!(code, Some(0), "{}: {reply}", screen.display());
        let state: State = serde_json::from_value(reply["result"].clone()).unwrap();
        assert_eq!(up(&state), ready, "{}: {reply}", screen.display());
        assert_eq!(
            reply["result"]["state"],
            want,
            "{}: {reply}",
            screen.display()
        );
    }
    let (code, reply) = ask(&fixtures.join("pi-idle.txt"), "nope");
    assert_eq!(reply["refusal"]["key"], "harness-unknown", "{reply}");
    assert_eq!(code, Some(1), "{reply}");
}

/// Pi 1.5.2's foot in a lane: `pi-session-bridge` draws its status line
/// `bridge:<pid>` under the footer, at rest and mid-turn. The close guard
/// and delivery read idle from this screen alone, so an idle lane that
/// carries the bridge must read idle; the same foot with no status line
/// reads as before.
#[test]
fn a_pi_foot_with_an_extension_s_status_line_under_the_footer_reads_idle_at_rest_and_working_mid_turn()
 {
    let fixtures = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/rust/fixtures");
    let idle = fixtures.join("pi-status-idle.txt");
    let text = std::fs::read_to_string(&idle).unwrap();
    let (foot, status) = text.trim_end().rsplit_once('\n').unwrap();
    assert!(status.starts_with("bridge:"), "{status}");
    let dir = tempfile::tempdir().unwrap();
    let bare = dir.path().join("pi-no-status.txt");
    std::fs::write(&bare, format!("{foot}\n")).unwrap();
    for (screen, want) in [
        (idle, "idle"),
        (fixtures.join("pi-status-working.txt"), "working"),
        (bare, "idle"),
    ] {
        let (code, reply) = reply_of(&[
            "judge".as_ref(),
            "--screen".as_ref(),
            screen.as_os_str(),
            "--harness".as_ref(),
            "pi".as_ref(),
        ]);
        assert_eq!(
            reply["result"]["state"],
            want,
            "{}: {reply}",
            screen.display()
        );
        assert_eq!(code, Some(0), "{reply}");
    }
}

/// Each first-run question a Claude launch can open on reads asking, with
/// the step a person takes named (a refusal's `step=`, which the overseer
/// acts on), as Claude Code 2.1.330 drew it under a fresh config dir on
/// 2026-11-22; any other dialog reads asking `other`, which names no step.
#[test]
fn a_first_run_dialog_reads_asking_with_its_step() {
    use agent_runtime::Harness;
    use agent_runtime::observe::{Dialog, ProcessReading, State, judge};
    let rows = [
        (
            include_str!("fixtures/claude-folder-trust.txt"),
            Dialog::FolderTrust,
            Some("folder-trust"),
        ),
        (
            include_str!("fixtures/claude-bypass-consent.txt"),
            Dialog::BypassConsent,
            Some("bypass-consent"),
        ),
        (
            "❯ fix the build\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n Esc to cancel",
            Dialog::Other,
            None,
        ),
    ];
    for (screen, dialog, step) in rows {
        assert_eq!(
            judge(screen, Harness::Claude, &ProcessReading::HarnessUp, None),
            State::Asking { dialog },
            "{screen}"
        );
        assert_eq!(dialog.step(), step, "{screen}");
    }
}

/// The three marker-drawing harnesses at rest, as the native probe's
/// `inspect` captured them after the first turn: each reads
/// idle under its own composer rule. Codex's `›` line is no other
/// harness's composer, and neither Claude's nor Copilot's is Codex's;
/// Copilot's unpadded `❯` is not Claude's. Claude frames its padded marker
/// with rules as Copilot does, so Copilot's rule reads it idle too.
#[test]
fn each_harness_s_real_idle_capture_reads_idle_under_its_own_rule() {
    use agent_runtime::Harness;
    use agent_runtime::observe::{ProcessReading, State, judge};
    let claude = include_str!("fixtures/claude-idle.txt");
    let codex = include_str!("fixtures/codex-idle.txt");
    let copilot = include_str!("fixtures/copilot-idle.txt");
    let rows = [
        (Harness::Claude, claude),
        (Harness::Codex, codex),
        (Harness::Copilot, copilot),
    ];
    for (harness, screen) in rows {
        assert_eq!(
            judge(screen, harness, &ProcessReading::HarnessUp, None),
            State::Idle,
            "{harness:?}"
        );
        // The same screen with a shell in the foreground is not idle.
        assert!(matches!(
            judge(
                screen,
                harness,
                &ProcessReading::ForegroundShell {
                    name: "fish".to_owned()
                },
                None
            ),
            State::Unjudged { .. }
        ));
    }
    let foreign = [
        (claude, Harness::Codex),
        (codex, Harness::Claude),
        (codex, Harness::Copilot),
        (copilot, Harness::Claude),
        (copilot, Harness::Codex),
    ];
    for (screen, other) in foreign {
        assert!(
            matches!(
                judge(screen, other, &ProcessReading::HarnessUp, None),
                State::Unjudged { .. }
            ),
            "under {other:?}"
        );
    }
}

/// A private tmux server on its own socket with one detached session,
/// started by the runtime's own constructor, so no configuration file, no
/// login shell and none of the host's environment reaches a pane, and
/// sized to 80 by 24; ended on drop. Its first pane is the one a planted
/// launch record names.
struct PrivatePane {
    socket: PathBuf,
    server_pid: u64,
    server_start: u64,
    pane: String,
    window: String,
    session: String,
}

/// One tmux command on the private server at `socket`, its stdout.
fn tmux_at(socket: &std::path::Path, args: &[&str]) -> String {
    let out = Command::new("tmux")
        .arg("-S")
        .arg(socket)
        .args(args)
        .output()
        .expect("tmux");
    assert!(
        out.status.success(),
        "tmux {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("tmux's answer is UTF-8")
}

impl PrivatePane {
    fn start(dir: &std::path::Path) -> PrivatePane {
        let socket = dir.join("tmux.sock");
        let server = agent_runtime::host::tmux::start_private_server(&socket, "probe", dir)
            .expect("a private tmux server");
        PrivatePane::sized(socket, u64::from(server.pid), server.start)
    }

    /// [`PrivatePane::start`] on a server started from a copy of the `tmux`
    /// on `PATH` named `multiplexer`: the runtime runs no program that is
    /// not named `tmux`, so it reaches this server through the `tmux` on
    /// `PATH`, where a row plants its own answer.
    fn behind_path(dir: &std::path::Path) -> PrivatePane {
        let real = std::env::var_os("PATH")
            .and_then(|path| {
                std::env::split_paths(&path)
                    .map(|d| d.join("tmux"))
                    .find(|p| p.is_file())
            })
            .expect("tmux on PATH");
        let program = dir.join("server-bin/multiplexer");
        std::fs::create_dir_all(program.parent().unwrap()).unwrap();
        // Copied by a child, so no write descriptor of this process is
        // inherited by a sibling test's child when the copy is run.
        let copied = Command::new("cp")
            .arg(&real)
            .arg(&program)
            .status()
            .unwrap();
        assert!(copied.success(), "the copy of {}", real.display());
        let socket = dir.join("tmux.sock");
        let started = Command::new(&program)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", dir)
            .env("SHELL", "/bin/sh")
            .arg("-S")
            .arg(&socket)
            .args(["-f", "/dev/null", "new-session", "-d", "-s", "probe", "-c"])
            .arg(dir)
            .args([
                "/bin/sh",
                ";",
                "set-option",
                "-g",
                "default-command",
                "/bin/sh",
            ])
            .output()
            .unwrap();
        assert!(
            started.status.success(),
            "the server: {}",
            String::from_utf8_lossy(&started.stderr)
        );
        let identity = tmux_at(&socket, &["display-message", "-p", "#{pid} #{start_time}"]);
        let (pid, start) = identity
            .trim()
            .split_once(' ')
            .expect("the server's identity");
        PrivatePane::sized(socket, pid.parse().unwrap(), start.parse().unwrap())
    }

    fn sized(socket: PathBuf, server_pid: u64, server_start: u64) -> PrivatePane {
        tmux_at(
            &socket,
            &["resize-window", "-t", "probe", "-x", "80", "-y", "24"],
        );
        let text = tmux_at(
            &socket,
            &[
                "display-message",
                "-p",
                "#{pane_id}\t#{window_id}\t#{session_name}",
            ],
        );
        let mut parts = text.trim_end().split('\t');
        let pane = parts.next().unwrap().to_owned();
        let window = parts.next().unwrap().to_owned();
        let session = parts.next().unwrap().to_owned();
        PrivatePane {
            socket,
            server_pid,
            server_start,
            pane,
            window,
            session,
        }
    }

    fn tmux(&self, args: &[&str]) -> String {
        tmux_at(&self.socket, args)
    }

    /// The pane's width in cells, as the server holds it.
    fn width(&self) -> usize {
        self.tmux(&["display-message", "-p", "-t", &self.pane, "#{pane_width}"])
            .trim()
            .parse()
            .expect("pane width")
    }

    /// Replace the pane's shell with `program`, run directly as the pane's
    /// own process: no shell echoes anything into the pane. tmux runs a
    /// one-word command through `/bin/sh -c`, and dash, Debian's and
    /// Ubuntu's `sh`, waits on its last command where bash replaces itself
    /// with it, so the `exec` is what makes `program` the pane's process.
    fn run(&self, program: &std::path::Path) {
        let program = agent_runtime::launch::shell_quote(&program.display().to_string());
        self.tmux(&[
            "respawn-pane",
            "-k",
            "-t",
            &self.pane,
            &format!("exec {program}"),
        ]);
    }

    /// The pane's screen, row by row with trailing blanks trimmed
    /// (`capture-pane -p`) or with wrapped rows joined (`-J`), read by the
    /// test's own tmux call: the two reads the runtime does not make.
    fn screen(&self, joined: bool) -> String {
        let mut args = vec!["capture-pane", "-p"];
        if joined {
            args.push("-J");
        }
        args.extend(["-t", self.pane.as_str()]);
        self.tmux(&args)
    }

    /// Replace the pane's shell with a bash script named `name` under
    /// `dir`, so the kernel names the pane's process for that harness, whose
    /// body is `script`; it ends with the pane.
    fn run_stub(&self, dir: &std::path::Path, name: &str, script: &str) {
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let stub = bin.join(name);
        write_executable(&stub, format!("#!/bin/bash\n{script}read -r _\n"));
        self.run(&stub);
    }

    /// The pane's rows, polled until one satisfies `drawn`, bounded.
    fn await_row(&self, drawn: &dyn Fn(&str) -> bool) -> String {
        use std::time::{Duration, Instant};
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let rows = self.screen(false);
            if rows.lines().any(drawn) {
                return rows;
            }
            assert!(
                Instant::now() < deadline,
                "the row was never drawn:\n{rows}"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// A launch record naming this pane for `harness` in `cwd` under `home`,
    /// launched a minute ago, with `baseline` as given (`None`: no key, as
    /// a record written before the field).
    fn record(
        &self,
        harness: &str,
        home: &std::path::Path,
        cwd: &std::path::Path,
        baseline: Option<serde_json::Value>,
    ) -> serde_json::Value {
        let launched = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - 60;
        let mut record = serde_json::json!({
            "record_version": 1,
            "revision": 1,
            "harness": harness,
            "intent": {"harness": harness, "home": home, "cwd": cwd},
            "command_line": harness,
            "pane": {
                "server": {"socket": self.socket, "pid": self.server_pid, "start": self.server_start},
                "id": self.pane,
                "window": self.window,
                "session": self.session,
            },
            "launched_at": agent_runtime::clock::iso_utc(launched),
        });
        if let Some(baseline) = baseline {
            record["baseline"] = baseline;
        }
        record
    }
}

impl Drop for PrivatePane {
    fn drop(&mut self) {
        let _ = Command::new("tmux")
            .arg("-S")
            .arg(&self.socket)
            .arg("kill-server")
            .output();
    }
}

/// `inspect` on a record written at `path`, the reply's result.
fn inspect(path: &std::path::Path, record: &serde_json::Value) -> serde_json::Value {
    std::fs::write(path, serde_json::to_vec(record).unwrap()).unwrap();
    let out = Command::new(binary())
        .args(["inspect", "--record"])
        .arg(path)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstderr={}",
            String::from_utf8_lossy(&out.stderr)
        )
    });
    assert_eq!(
        reply["ok"],
        true,
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    reply["result"].clone()
}

/// The judge reads drawn rows, not joined lines. A harness-named process
/// holds the pane and has drawn an echo of the launch line that fills its
/// last row exactly, then its composer on the next row: the way a readline
/// shell's echo of a typed launch line lands when (prompt + line) is a
/// multiple of the pane width. tmux flags that next row as the echo's
/// wrapped continuation, so a `-J` capture appends the composer to the echo
/// and no line starts with it, while the row capture keeps it its own row.
/// `inspect` reads the pane idle; the same pane's joined capture judges
/// unjudged, which names the mechanism the row read avoids.
#[test]
#[cfg(unix)]
fn a_composer_row_after_an_echo_that_fills_its_row_exactly_reads_idle() {
    use agent_runtime::Harness;
    use agent_runtime::observe::{ProcessReading, State, judge};
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let width = pane.width();
    // A launch line's echo of exactly the pane width: the marker, a blank
    // and the line, padded to the width in single-cell characters.
    let echo = format!(
        "\u{276f} {:x<w$}",
        "exec claude --session-id 0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c",
        w = width - 2
    );
    assert_eq!(echo.chars().count(), width);
    let composer = "\u{276f}\u{a0}";
    // The stub stands as the harness: it writes the echo with no newline,
    // so its composer's first glyph forces tmux's autowrap and the wrapped
    // flag on the echo's row.
    pane.run_stub(
        dir.path(),
        "claude",
        &format!("printf '%s' '{echo}'\nprintf '%s\\n  ? for shortcuts\\n' '{composer}'\n"),
    );
    let rows = pane.await_row(&|l| l == composer);
    // The plant reached the bound: the echo is one whole row, the composer
    // the next, and the joined capture of the same pane runs them together.
    assert!(rows.lines().any(|l| l == echo), "{rows}");
    let joined = pane.screen(true);
    let run_together = format!("{echo}{composer}");
    assert!(joined.lines().any(|l| l == run_together), "{joined}");
    assert!(!joined.lines().any(|l| l.starts_with(composer)), "{joined}");
    assert!(matches!(
        judge(&joined, Harness::Claude, &ProcessReading::HarnessUp, None),
        State::Unjudged { .. }
    ));
    let home = dir.path().join("home");
    let result = inspect(
        &dir.path().join("record.json"),
        &pane.record("claude", &home, dir.path(), None),
    );
    assert_eq!(result["state"]["state"], "idle", "{result}");
}

/// A trailing blank can be the drawing: Codex's composer over an empty
/// draft is `› ` and nothing after (its placeholder goes once the draft is
/// non-empty, a blank included), and a draft whose first row is blank
/// draws the arrow and blanks. tmux trims a row's trailing blanks unless
/// asked to keep them, so a trimmed row read hands the judge `›`, which
/// Codex's rule does not take. `inspect` reads each pane idle; the trimmed
/// row capture of the same pane judges unjudged, which names the mechanism.
#[test]
#[cfg(unix)]
fn a_codex_composer_over_a_blank_draft_reads_idle() {
    use agent_runtime::Harness;
    use agent_runtime::observe::{ProcessReading, State, judge};
    // Each row: the composer line as drawn, trailing blanks included.
    let rows = ["\u{203a} ", "\u{203a}    "];
    for drawn in rows {
        let dir = tempfile::tempdir().unwrap();
        let pane = PrivatePane::start(dir.path());
        pane.run_stub(
            dir.path(),
            "codex",
            &format!("printf '%s\\n' '\u{203a} first turn' 'some answer' '{drawn}'\n"),
        );
        let trimmed = pane.await_row(&|l| l == "\u{203a}");
        assert!(matches!(
            judge(&trimmed, Harness::Codex, &ProcessReading::HarnessUp, None),
            State::Unjudged { .. }
        ));
        let result = inspect(
            &dir.path().join("record.json"),
            &pane.record("codex", &dir.path().join("home"), dir.path(), None),
        );
        assert_eq!(result["state"]["state"], "idle", "{drawn:?}: {result}");
    }
}

/// Through `inspect`: a cold directory. The launch read an
/// empty baseline (`baseline: []`), and the one Codex lead that appeared for
/// the cwd after it binds; the same record written before the field, with
/// no baseline key, binds nothing, since nothing tells its session from a
/// neighbour's.
#[test]
fn an_empty_baseline_read_binds_the_one_lead_that_appeared_and_no_baseline_binds_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let home = dir.path().join("home");
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let day = home.join("sessions").join("2026").join("10").join("27");
    std::fs::create_dir_all(&day).unwrap();
    std::fs::write(
        day.join("rollout-a-R.jsonl"),
        format!(
            r#"{{"type":"session_meta","payload":{{"id":"R","cwd":{},"parent_thread_id":null,"source":"cli"}}}}"#,
            serde_json::json!(cwd)
        ),
    )
    .unwrap();
    let record_path = dir.path().join("record.json");
    let cold = pane.record("codex", &home, &cwd, Some(serde_json::json!([])));
    let result = inspect(&record_path, &cold);
    assert_eq!(result["native_session"]["id"], "R", "{result}");
    assert!(result.get("native_session_unreadable").is_none());
    // The record as written carries the bound session and its empty
    // baseline, present.
    let written: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&record_path).unwrap()).unwrap();
    assert_eq!(written["native_session"]["id"], "R");
    assert_eq!(written["baseline"], serde_json::json!([]));
    let unbound = pane.record("codex", &home, &cwd, None);
    let result = inspect(&dir.path().join("unbound.json"), &unbound);
    assert!(result["native_session"].is_null(), "{result}");
    assert!(result.get("native_session_unreadable").is_none());
}

/// The Codex fixed-id lookup reads the store's
/// root three-valued through the listing. No root is an absent session; a
/// root this process cannot list is unreadable, never absent; a rollout
/// whose name ends in the id is present.
#[test]
#[cfg(unix)]
fn the_codex_fixed_id_lookup_reads_an_unlistable_store_as_unreadable() {
    use agent_runtime::Harness;
    use agent_runtime::reading::Reading;
    use agent_runtime::session::resume_owner;
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&home).unwrap();
    let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
    assert_eq!(
        resume_owner(Harness::Codex, &home, &cwd, id),
        Reading::Gone,
        "no sessions root is a cold home"
    );
    let day = home.join("sessions").join("2026").join("10").join("30");
    std::fs::create_dir_all(&day).unwrap();
    assert_eq!(
        resume_owner(Harness::Codex, &home, &cwd, id),
        Reading::Gone,
        "a root with no rollout for the id is absent"
    );
    std::fs::write(
        day.join(format!("rollout-a-{id}.jsonl")),
        format!(
            "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"cwd\":\"{}\",\"parent_thread_id\":null,\"source\":\"cli\"}}}}\n",
            cwd.display()
        ),
    )
    .unwrap();
    assert_eq!(
        resume_owner(Harness::Codex, &home, &cwd, id),
        Reading::Live(Some(cwd.clone())),
        "the rollout named by the id is present and names its directory"
    );
    let root = home.join("sessions");
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o000)).unwrap();
    let denied = matches!(
        std::fs::read_dir(&root),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied
    );
    let read = resume_owner(Harness::Codex, &home, &cwd, id);
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(
        denied,
        "the fixture needs a directory this process cannot list; a root run reads everything"
    );
    assert!(
        matches!(read, Reading::Unreadable { .. }),
        "a root that cannot be listed is unreadable, never absent: {read:?}"
    );
}

/// Through `inspect`: a Copilot session directory this
/// process cannot enter beside one readable lead. The store is unread, so
/// nothing binds and the reply names the cause; with the directory readable
/// again the one lead binds.
#[test]
#[cfg(unix)]
fn an_unreadable_session_store_binds_nothing_and_names_its_cause() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let home = dir.path().join("home");
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let readable = home.join("session-state").join("S1");
    std::fs::create_dir_all(&readable).unwrap();
    std::fs::write(
        readable.join("workspace.yaml"),
        format!("id: S1\ncwd: {}\n", cwd.display()),
    )
    .unwrap();
    std::fs::write(readable.join("events.jsonl"), "{\"type\":\"x\"}\n").unwrap();
    let dark = home.join("session-state").join("S2");
    std::fs::create_dir_all(&dark).unwrap();
    std::fs::set_permissions(&dark, std::fs::Permissions::from_mode(0o000)).unwrap();
    assert!(
        matches!(
            std::fs::read_dir(&dark),
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied
        ),
        "the fixture needs a directory this process cannot enter; a root run reads everything"
    );
    let record_path = dir.path().join("record.json");
    let record = pane.record("copilot", &home, &cwd, Some(serde_json::json!([])));
    let result = inspect(&record_path, &record);
    assert!(result["native_session"].is_null(), "{result}");
    assert_eq!(
        result["native_session_unreadable"], "session-store-unreadable",
        "{result}"
    );
    std::fs::set_permissions(&dark, std::fs::Permissions::from_mode(0o755)).unwrap();
    let result = inspect(&record_path, &record);
    assert_eq!(result["native_session"]["id"], "S1", "{result}");
    assert!(result.get("native_session_unreadable").is_none());
}

/// A composer stub named `claude` under `dir`, recording each line it
/// reads as a user turn in the session file its `--session-id` names under
/// `home` (Claude Code's shape, as `session::user_turns` counts it), or
/// recording nothing when `drops`. Returns its path.
#[cfg(unix)]
fn turns_stub(dir: &std::path::Path, home: &std::path::Path, drops: bool) -> PathBuf {
    let bin = dir.join(if drops { "drops" } else { "keeps" });
    std::fs::create_dir_all(&bin).unwrap();
    let stub = bin.join("claude");
    let record = if drops {
        ""
    } else {
        "printf '{\"type\":\"user\",\"message\":{\"content\":\"%s\"},\"sessionId\":\"%s\",\"cwd\":\"%s\"}\\n' \"$line\" \"$session\" \"$PWD\" >> \"$rows\""
    };
    let script = format!(
        "#!/bin/bash\nhome='{}'\nsession=stub\nwhile [ $# -gt 0 ]; do case \"$1\" in --session-id) session=\"$2\"; shift ;; esac; shift; done\nslug=\"${{PWD//[\\/.]/-}}\"\nmkdir -p \"$home/projects/$slug\"\nrows=\"$home/projects/$slug/$session.jsonl\"\n: > \"$rows\"\nprintf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n  ? for shortcuts\\n'\nwhile IFS= read -r line; do\n  {record}\n  printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'\ndone\n",
        home.display()
    );
    write_executable(&stub, script);
    stub
}

/// `deliver` on a session named by its facts, the reply's JSON and exit.
fn deliver_on(
    pane: &PrivatePane,
    home: &std::path::Path,
    args: &[&str],
) -> (serde_json::Value, i32) {
    let out = Command::new(binary())
        .args([
            "deliver",
            "--harness",
            "claude",
            "--socket",
            &pane.socket.display().to_string(),
            "--server-pid",
            &pane.server_pid.to_string(),
            "--server-start",
            &pane.server_start.to_string(),
            "--pane",
            &pane.pane,
            "--home",
            &home.display().to_string(),
            "--cwd",
            &pane.socket.parent().unwrap().display().to_string(),
        ])
        .args(args)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstderr={}",
            String::from_utf8_lossy(&out.stderr)
        )
    });
    (reply, out.status.code().unwrap_or(-1))
}

#[test]
#[cfg(unix)]
fn deliver_matches_only_the_sent_text_after_the_cursor_on_readback() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let pane = PrivatePane::start(dir.path());
    let keeps = turns_stub(dir.path(), &home, false);
    pane.tmux(&[
        "respawn-pane",
        "-k",
        "-t",
        &pane.pane,
        &format!("{} --session-id receipt", keeps.display()),
    ]);
    pane.await_row(&|l| l == "\u{276f}\u{a0}");
    let file = home
        .join("projects")
        .join(agent_runtime::session::claude_slug(dir.path()))
        .join("receipt.jsonl");
    type Row<'a> = (&'a [&'a str], u64, &'a str, &'a str);
    let rows: &[Row] = &[
        (&["another prompt"], 0, "you have mail", "turn-unmatched"),
        (
            &["you have mail", "another prompt"],
            1,
            "you have mail",
            "turn-unmatched",
        ),
        (
            &["you have", "prefix you have mail suffix", "have mail"],
            0,
            "you have mail",
            "turn-unmatched",
        ),
        (&["you have mail"], 1, "you have mail", "turn-pending"),
        (&["another prompt", "you have mail"], 0, "you have mail", ""),
        (&["  first\nsecond"], 0, "  first \r\nsecond\t\r\n", ""),
        (&[" first\nsecond"], 0, "  first\nsecond", "turn-unmatched"),
        (
            &["\n\n<pasted_content id=\"634f\">\nfirst\nsecond\n</pasted_content id=\"634f\">\n"],
            0,
            "first\nsecond",
            "",
        ),
        (
            &[
                "<command-message>orch</command-message>\n<command-name>/orch</command-name>\n<command-args>oversee</command-args>",
            ],
            0,
            "/orch oversee",
            "",
        ),
        (
            &[
                "<command-message>orch</command-message>\n<command-name>/orch</command-name>\n<command-args>oversee now</command-args>",
            ],
            0,
            "/orch oversee",
            "turn-unmatched",
        ),
    ];
    for (texts, cursor, sent, cause) in rows {
        let content: String = texts
            .iter()
            .map(|text| {
                serde_json::json!({"type":"user", "message":{"content":text}}).to_string() + "\n"
            })
            .collect();
        std::fs::write(&file, &content).unwrap();
        let sent_file = dir.path().join("sent.txt");
        std::fs::write(&sent_file, sent).unwrap();
        let digest = agent_runtime::record::cksum(
            agent_runtime::session::normalize_user_text(sent).as_bytes(),
        )
        .to_string();
        for (flag, value) in [
            ("--line", sent.to_string()),
            ("--file", sent_file.display().to_string()),
            ("--line-digest", digest),
        ] {
            let (answer, code) = deliver_on(
                &pane,
                &home,
                &[
                    "--session-id",
                    "receipt",
                    "--no-paste",
                    "--turns-before",
                    &cursor.to_string(),
                    flag,
                    &value,
                    "--bound-secs",
                    "0",
                ],
            );
            assert_eq!(code, 0, "{flag}: {answer}");
            if cause.is_empty() {
                assert_eq!(
                    answer["result"]["delivery"], "confirmed",
                    "{flag}: {answer}"
                );
                assert_eq!(answer["result"]["route"], "session-read", "{answer}");
                assert_eq!(answer["result"]["turns_after"], texts.len(), "{answer}");
            } else {
                assert_eq!(
                    answer["result"]["delivery"], "unconfirmed",
                    "{flag}: {answer}"
                );
                assert_eq!(answer["result"]["cause"], *cause, "{flag}: {answer}");
            }
            assert_eq!(std::fs::read_to_string(&file).unwrap(), content);
        }
    }
    pane.run_stub(dir.path(), "claude", "printf 'starting up\\n'\n");
    pane.await_row(&|l| l == "starting up");
    std::fs::write(
        &file,
        "{\"type\":\"user\",\"message\":{\"content\":\"you have mail\"}}\n",
    )
    .unwrap();
    let (answer, code) = deliver_on(
        &pane,
        &home,
        &[
            "--session-id",
            "receipt",
            "--no-paste",
            "--turns-before",
            "0",
            "--line",
            "you have mail",
            "--bound-secs",
            "0",
        ],
    );
    assert_eq!(code, 0, "{answer}");
    assert_eq!(answer["result"]["delivery"], "confirmed", "{answer}");
}

/// A `--no-paste` read gives the idle state and the fixed file's turn
/// count; a paste into a stub that records the line is confirmed by that
/// file; a paste into one that records nothing is `unconfirmed` once the
/// bound passes; a session naming no id is a limit, nothing typed; a server
/// the socket does not answer for under the recorded pid is refused; a
/// server start left out matches the live server by its pid.
#[test]
#[cfg(unix)]
fn deliver_confirms_by_the_fixed_file_s_user_turn_and_never_by_the_paste_alone() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let pane = PrivatePane::start(dir.path());
    let keeps = turns_stub(dir.path(), &home, false);
    pane.tmux(&[
        "respawn-pane",
        "-k",
        "-t",
        &pane.pane,
        &format!("{} --session-id keeps-1", keeps.display()),
    ]);
    pane.await_row(&|l| l == "\u{276f}\u{a0}");
    let file = home
        .join("projects")
        .join(agent_runtime::session::claude_slug(dir.path()))
        .join("keeps-1.jsonl");
    let (read, code) = deliver_on(&pane, &home, &["--session-id", "keeps-1", "--no-paste"]);
    assert_eq!(code, 0, "{read}");
    assert_eq!(read["result"]["delivery"], "read", "{read}");
    assert_eq!(read["result"]["state"]["state"], "idle", "{read}");
    assert_eq!(read["result"]["turns"], 0, "{read}");
    assert_eq!(read["result"]["file"], file.display().to_string(), "{read}");
    let (confirmed, code) = deliver_on(
        &pane,
        &home,
        &[
            "--session-id",
            "keeps-1",
            "--turns-before",
            "0",
            "--line",
            "you have mail",
            "--bound-secs",
            "5",
        ],
    );
    assert_eq!(code, 0, "{confirmed}");
    assert_eq!(confirmed["result"]["delivery"], "confirmed", "{confirmed}");
    assert_eq!(confirmed["result"]["outcome"], "confirmed");
    assert_eq!(confirmed["result"]["turns_before"], 0);
    assert_eq!(confirmed["result"]["turns_after"], 1);
    assert_eq!(
        agent_runtime::session::user_turns(agent_runtime::Harness::Claude, &file).unwrap(),
        1
    );
    assert!(
        std::fs::read_to_string(&file)
            .unwrap()
            .contains("you have mail"),
        "the harness's own record of the line"
    );
    // The server start left out: the live server at the socket stands for
    // the pid; a pid the socket does not answer for is refused before any
    // read of the pane.
    let out = Command::new(binary())
        .args([
            "deliver",
            "--harness",
            "claude",
            "--socket",
            &pane.socket.display().to_string(),
            "--server-pid",
            &pane.server_pid.to_string(),
            "--pane",
            &pane.pane,
            "--home",
            &home.display().to_string(),
            "--cwd",
            &dir.path().display().to_string(),
            "--session-id",
            "keeps-1",
            "--no-paste",
        ])
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["turns"], 1, "{reply}");
    let out = Command::new(binary())
        .args([
            "deliver",
            "--harness",
            "claude",
            "--socket",
            &pane.socket.display().to_string(),
            "--server-pid",
            &(pane.server_pid + 1).to_string(),
            "--pane",
            &pane.pane,
            "--cwd",
            &dir.path().display().to_string(),
            "--session-id",
            "keeps-1",
            "--no-paste",
        ])
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["refusal"]["key"], "server-unmatched", "{reply}");
    // No id: a limit, and the stub reads no line.
    let (limit, code) = deliver_on(&pane, &home, &["--line", "lost"]);
    assert_eq!(code, 0, "{limit}");
    assert_eq!(limit["result"]["delivery"], "limit", "{limit}");
    assert_eq!(limit["result"]["cause"], "session-unbound", "{limit}");
    assert_eq!(
        agent_runtime::session::user_turns(agent_runtime::Harness::Claude, &file).unwrap(),
        1,
        "nothing typed for a limit"
    );
    // A stub that records nothing: the paste goes in, no turn arrives.
    let drops = turns_stub(dir.path(), &home, true);
    pane.tmux(&[
        "respawn-pane",
        "-k",
        "-t",
        &pane.pane,
        &format!("{} --session-id drops-1", drops.display()),
    ]);
    pane.await_row(&|l| l == "\u{276f}\u{a0}");
    let started = std::time::Instant::now();
    let (unconfirmed, code) = deliver_on(
        &pane,
        &home,
        &[
            "--session-id",
            "drops-1",
            "--line",
            "you have mail",
            "--bound-secs",
            "1",
        ],
    );
    assert_eq!(code, 0, "{unconfirmed}");
    assert_eq!(
        unconfirmed["result"]["delivery"], "unconfirmed",
        "{unconfirmed}"
    );
    assert_eq!(unconfirmed["result"]["outcome"], "unconfirmed");
    assert_eq!(unconfirmed["result"]["cause"], "turn-pending");
    assert!(
        started.elapsed() >= std::time::Duration::from_secs(1),
        "the bound was waited out"
    );
    // A pane that is no composer is refused, nothing typed.
    pane.run_stub(dir.path(), "claude", "printf 'starting up\\n'\n");
    pane.await_row(&|l| l == "starting up");
    let (refused, code) = deliver_on(&pane, &home, &["--session-id", "x", "--line", "lost"]);
    assert_eq!(code, 1, "{refused}");
    assert_eq!(refused["refusal"]["key"], "deliver-refused", "{refused}");
    // A composer under a usage banner is a wall, refused; a caller that
    // read the account with room after its reset reads it idle.
    pane.run_stub(
        dir.path(),
        "claude",
        "printf '%s\\n' \"You've hit your session limit · resets 6pm (UTC)\"\nprintf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'\n",
    );
    pane.await_row(&|l| l.contains("session limit"));
    let read = ["--session-id", "keeps-1", "--no-paste"];
    let (walled, code) = deliver_on(&pane, &home, &read);
    assert_eq!(code, 1, "{walled}");
    assert_eq!(walled["refusal"]["key"], "deliver-refused", "{walled}");
    let state = walled["refusal"]["fields"]
        .as_array()
        .and_then(|fields| fields.iter().find(|field| field[0] == "state"))
        .map(|field| field[1].clone());
    assert_eq!(state, Some(serde_json::json!("walled")), "{walled}");
    let (past, code) = deliver_on(&pane, &home, &[&read[..], &["--account-room"]].concat());
    assert_eq!(code, 0, "{past}");
    assert_eq!(past["result"]["delivery"], "read", "{past}");
    assert_eq!(past["result"]["state"]["state"], "idle", "{past}");
}

/// A pane holding a transport: its foreground a client named `ssh`, never
/// the harness, whose screen the far session draws. With `--transport` an
/// idle composer is typed the line and the reply is `pasted`, unconfirmed;
/// without it the foreground settles nothing and nothing is typed. A screen
/// with no harness on it (the client dropped to a shell while the far
/// harness still reads running) is refused and its shell is typed nothing;
/// so is a working screen. `--transport` beside a session file's flag is a
/// usage error.
#[test]
#[cfg(unix)]
fn a_transport_pane_is_typed_after_a_harness_up_idle_read_and_answers_pasted() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let typed = dir.path().join("typed");
    let deliver = |args: &[&str]| -> (Option<i32>, String) {
        let out = Command::new(binary())
            .args([
                "deliver",
                "--harness",
                "claude",
                "--socket",
                &pane.socket.display().to_string(),
                "--server-pid",
                &pane.server_pid.to_string(),
                "--server-start",
                &pane.server_start.to_string(),
                "--pane",
                &pane.pane,
                "--cwd",
                &dir.path().display().to_string(),
            ])
            .args(args)
            .output()
            .unwrap();
        (
            out.status.code(),
            String::from_utf8_lossy(&out.stdout).into_owned(),
        )
    };
    let reply = |text: &str| -> serde_json::Value {
        serde_json::from_str(text).unwrap_or_else(|e| panic!("no reply: {e}: {text}"))
    };
    let lines = || std::fs::read_to_string(&typed).unwrap_or_default();
    // The client draws the far harness's composer and records each line the
    // pane is typed.
    let client = format!(
        "printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> '{}'; printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'; done\n",
        typed.display()
    );
    pane.run_stub(&dir.path().join("idle"), "ssh", &client);
    pane.await_row(&|l| l == "\u{276f}\u{a0}");
    let (code, out) = deliver(&["--line", "you have mail"]);
    assert_eq!(code, Some(1), "{out}");
    assert_eq!(reply(&out)["refusal"]["key"], "deliver-refused", "{out}");
    assert_eq!(lines(), "", "nothing typed past an unread foreground");
    let (code, out) = deliver(&["--transport", "--line", "you have mail"]);
    assert_eq!(code, Some(0), "{out}");
    let pasted = reply(&out);
    assert_eq!(pasted["result"]["delivery"], "pasted", "{out}");
    assert_eq!(pasted["result"]["outcome"], "unconfirmed", "{out}");
    assert_eq!(pasted["result"]["cause"], "transport", "{out}");
    assert_eq!(pasted["result"]["pane"], pane.pane.as_str(), "{out}");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while lines() != "you have mail\n" {
        assert!(std::time::Instant::now() < deadline, "typed: {:?}", lines());
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    // The client dropped to a shell: no harness on the screen, refused, and
    // the shell is typed nothing.
    pane.run_stub(
        &dir.path().join("dropped"),
        "ssh",
        &format!(
            "printf 'Connection to box closed.\\nuser@here:~$ \\n'\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> '{}'; done\n",
            typed.display()
        ),
    );
    pane.await_row(&|l| l.starts_with("user@here"));
    let (code, out) = deliver(&["--transport", "--line", "lost"]);
    assert_eq!(code, Some(1), "{out}");
    assert_eq!(reply(&out)["refusal"]["key"], "deliver-refused", "{out}");
    // A turn in flight on the far session: refused, nothing typed.
    pane.run_stub(
        &dir.path().join("working"),
        "ssh",
        &format!(
            "printf '%s\\n' '\u{273b} Thinking\u{2026} (esc to interrupt)'\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> '{}'; done\n",
            typed.display()
        ),
    );
    pane.await_row(&|l| l.contains("esc to interrupt"));
    let (code, out) = deliver(&["--transport", "--line", "lost"]);
    assert_eq!(code, Some(1), "{out}");
    assert_eq!(reply(&out)["refusal"]["key"], "deliver-refused", "{out}");
    assert_eq!(
        lines(),
        "you have mail\n",
        "a refused pane is typed nothing"
    );
    for flag in [
        &["--session-id", "s"][..],
        &["--home", "/h"],
        &["--pid", "1", "--start", "1"],
        &["--turns-before", "0"],
        &["--no-paste"],
        &["--force"],
    ] {
        let (code, out) = deliver(&[&["--transport", "--line", "x"][..], flag].concat());
        assert_eq!(code, Some(2), "{flag:?}: {out}");
        assert_eq!(out, "", "{flag:?}");
    }
}

/// A Claude Code permission dialog as the judge reads it: a question over
/// numbered rows, the selection marker on the first.
const DIALOG: &str = "printf 'Do you want to proceed?\\n\\xe2\\x9d\\xaf 1. Yes\\n  2. No\\n'\n";

/// A stub body that draws `screen` and then records every line its pane is
/// typed into `typed`, bracketed, so a bare Enter is the line `[]`.
fn recording(screen: &str, typed: &std::path::Path) -> String {
    format!(
        "{screen}while IFS= read -r line; do printf '[%s]\\n' \"$line\" >> '{}'; done\n",
        typed.display()
    )
}

/// `deliver --key` on the pane by its facts as Claude Code's, under the
/// caller's tmux variables `tmux` (none: the variables unset), with `args`
/// after; the exit and the reply's text.
fn press_on(
    pane: &PrivatePane,
    tmux: Option<(&str, &str)>,
    args: &[&str],
) -> (Option<i32>, String) {
    let mut command = Command::new(binary());
    command
        .args([
            "deliver",
            "--harness",
            "claude",
            "--socket",
            &pane.socket.display().to_string(),
            "--server-pid",
            &pane.server_pid.to_string(),
            "--server-start",
            &pane.server_start.to_string(),
            "--pane",
            &pane.pane,
            "--cwd",
            &pane.socket.parent().unwrap().display().to_string(),
        ])
        .args(args)
        .env_remove("TMUX")
        .env_remove("TMUX_PANE");
    if let Some((tmux, own)) = tmux {
        command.env("TMUX", tmux).env("TMUX_PANE", own);
    }
    let out = command.output().unwrap();
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
    )
}

fn reply_text(text: &str) -> serde_json::Value {
    serde_json::from_str(text).unwrap_or_else(|e| panic!("no reply: {e}: {text}"))
}

/// The lines the stub recorded, once `wanted` holds them or the bound
/// passes.
fn typed_lines(typed: &std::path::Path, wanted: &str) -> String {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let lines = std::fs::read_to_string(typed).unwrap_or_default();
        if lines == wanted || std::time::Instant::now() >= deadline {
            return lines;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// A key reaches a pane whose screen reads a dialog, and only such a pane:
/// a composer at rest and a turn in flight are refused `deliver-refused`
/// with the state, and nothing reaches the harness, where a key would land
/// as typing in its input or in the turn.
#[test]
#[cfg(unix)]
fn a_key_reaches_a_pane_that_shows_a_dialog_and_never_a_composer_or_a_turn() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let typed = dir.path().join("typed");
    pane.run_stub(
        &dir.path().join("idle"),
        "claude",
        &recording("printf '\\xe2\\x9d\\xaf\\xc2\\xa0\\n'\n", &typed),
    );
    pane.await_row(&|l| l == "\u{276f}\u{a0}");
    let (code, out) = press_on(&pane, None, &["--key", "Enter"]);
    assert_eq!(code, Some(1), "{out}");
    let refused = reply_text(&out);
    assert_eq!(refused["refusal"]["key"], "deliver-refused", "{out}");
    assert_eq!(
        refusal_field(&refused, "state").as_deref(),
        Some("idle"),
        "{out}"
    );
    pane.run_stub(
        &dir.path().join("working"),
        "claude",
        &recording(
            "printf '%s\\n' '\u{273b} Thinking\u{2026} (esc to interrupt)'\n",
            &typed,
        ),
    );
    pane.await_row(&|l| l.contains("esc to interrupt"));
    let (code, out) = press_on(&pane, None, &["--key", "Enter"]);
    assert_eq!(code, Some(1), "{out}");
    let refused = reply_text(&out);
    assert_eq!(refused["refusal"]["key"], "deliver-refused", "{out}");
    assert_eq!(
        refusal_field(&refused, "state").as_deref(),
        Some("working"),
        "{out}"
    );
    assert_eq!(
        typed_lines(&typed, ""),
        "",
        "a refused pane is pressed nothing"
    );
    pane.run_stub(
        &dir.path().join("asking"),
        "claude",
        &recording(DIALOG, &typed),
    );
    pane.await_row(&|l| l.starts_with("\u{276f} 1. Yes"));
    let (code, out) = press_on(&pane, None, &["--key", "Enter"]);
    assert_eq!(code, Some(0), "{out}");
    let pressed = reply_text(&out);
    assert_eq!(pressed["result"]["delivery"], "pressed", "{out}");
    assert_eq!(pressed["result"]["key"], "Enter", "{out}");
    assert_eq!(pressed["result"]["pane"], pane.pane.as_str(), "{out}");
    assert_eq!(
        typed_lines(&typed, "[]\n"),
        "[]\n",
        "the dialog took the key"
    );
}

#[test]
#[cfg(unix)]
fn a_recorded_dialog_takes_a_key_only_at_its_recorded_process_start() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let typed = dir.path().join("typed");
    pane.run_stub(
        &dir.path().join("asking"),
        "claude",
        &recording(DIALOG, &typed),
    );
    pane.await_row(&|l| l.starts_with("\u{276f} 1. Yes"));
    let path = dir.path().join("record.json");
    let record = pane.record("claude", &dir.path().join("home"), dir.path(), None);
    let result = inspect(&path, &record);
    assert!(result["harness_process"]["pid"].is_number(), "{result}");
    let recorded: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    for changed_start in [true, false] {
        let mut record = recorded.clone();
        if changed_start {
            let start = record["harness_process"]["start"].as_str().unwrap();
            let different = if let Some(ticks) = start.strip_prefix("ticks:") {
                format!("ticks:{}", ticks.parse::<u64>().unwrap() + 1)
            } else {
                "lstart:Thu Jan  1 00:00:00 1970".to_owned()
            };
            assert_ne!(start, different);
            record["harness_process"]["start"] = different.into();
        }
        std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
        let out = Command::new(binary())
            .args(["deliver", "--record"])
            .arg(&path)
            .args(["--key", "Enter"])
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .output()
            .unwrap();
        let reply = reply_text(&String::from_utf8_lossy(&out.stdout));
        if changed_start {
            assert_eq!(out.status.code(), Some(1), "{reply}");
            assert_eq!(reply["refusal"]["key"], "process-mismatch", "{reply}");
            assert_eq!(typed_lines(&typed, ""), "");
        } else {
            assert!(out.status.success(), "{reply}");
            assert_eq!(reply["result"]["delivery"], "pressed", "{reply}");
            assert_eq!(typed_lines(&typed, "[]\n"), "[]\n");
        }
    }
}

/// The caller's own pane, `$TMUX_PANE` on the server `$TMUX` names, is
/// refused `pane-self` with its dialog standing: a key the overseer meant
/// for a lane would answer its own prompt.
#[test]
#[cfg(unix)]
fn a_key_into_the_caller_s_own_pane_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let typed = dir.path().join("typed");
    pane.run_stub(
        &dir.path().join("asking"),
        "claude",
        &recording(DIALOG, &typed),
    );
    pane.await_row(&|l| l.starts_with("\u{276f} 1. Yes"));
    let tmux = format!("{},{},0", pane.socket.display(), pane.server_pid);
    let (code, out) = press_on(&pane, Some((&tmux, &pane.pane)), &["--key", "Enter"]);
    assert_eq!(code, Some(1), "{out}");
    assert_eq!(reply_text(&out)["refusal"]["key"], "pane-self", "{out}");
    assert_eq!(
        typed_lines(&typed, ""),
        "",
        "the caller's pane is pressed nothing"
    );
}

/// A pane whose foreground is not the harness is refused
/// `process-mismatch` with what runs there, whatever its screen draws; under
/// `--transport` the foreground must be the transport's client, and a
/// client's dialog takes the key.
#[test]
#[cfg(unix)]
fn a_key_into_a_pane_that_runs_another_process_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let typed = dir.path().join("typed");
    pane.run_stub(
        &dir.path().join("other"),
        "other",
        &recording(DIALOG, &typed),
    );
    pane.await_row(&|l| l.starts_with("\u{276f} 1. Yes"));
    let (code, out) = press_on(&pane, None, &["--key", "Enter"]);
    assert_eq!(code, Some(1), "{out}");
    let refused = reply_text(&out);
    assert_eq!(refused["refusal"]["key"], "process-mismatch", "{out}");
    assert_eq!(
        refusal_field(&refused, "expected").as_deref(),
        Some("claude"),
        "{out}"
    );
    assert_eq!(
        refusal_field(&refused, "running").as_deref(),
        Some("other"),
        "{out}"
    );
    let (code, out) = press_on(&pane, None, &["--transport", "--key", "Enter"]);
    assert_eq!(code, Some(1), "{out}");
    let refused = reply_text(&out);
    assert_eq!(refused["refusal"]["key"], "process-mismatch", "{out}");
    assert_eq!(
        refusal_field(&refused, "expected").as_deref(),
        Some("ssh"),
        "{out}"
    );
    assert_eq!(
        typed_lines(&typed, ""),
        "",
        "another process is pressed nothing"
    );
    pane.run_stub(
        &dir.path().join("client"),
        "ssh",
        &recording(DIALOG, &typed),
    );
    pane.await_row(&|l| l.starts_with("\u{276f} 1. Yes"));
    let (code, out) = press_on(&pane, None, &["--transport", "--key", "Down"]);
    assert_eq!(code, Some(0), "{out}");
    assert_eq!(reply_text(&out)["result"]["delivery"], "pressed", "{out}");
}

/// A key outside the set (`Escape`, which declines a Claude Code dialog and
/// ends its turn) is refused `key-invalid` before the pane is read, its
/// dialog standing; a key beside text, a read or `--force` is a usage error.
#[test]
#[cfg(unix)]
fn a_key_outside_the_set_or_beside_text_is_refused_and_presses_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    let typed = dir.path().join("typed");
    pane.run_stub(
        &dir.path().join("asking"),
        "claude",
        &recording(DIALOG, &typed),
    );
    pane.await_row(&|l| l.starts_with("\u{276f} 1. Yes"));
    let (code, out) = press_on(&pane, None, &["--key", "Escape"]);
    assert_eq!(code, Some(1), "{out}");
    assert_eq!(reply_text(&out)["refusal"]["key"], "key-invalid", "{out}");
    let file = dir.path().join("line");
    std::fs::write(&file, "x").unwrap();
    for flag in [
        &["--line", "x"][..],
        &["--file", file.to_str().unwrap()],
        &["--no-paste"],
        &["--force"],
    ] {
        let (code, out) = press_on(&pane, None, &[&["--key", "Enter"][..], flag].concat());
        assert_eq!(code, Some(2), "{flag:?}: {out}");
        assert_eq!(out, "", "{flag:?}");
    }
    assert_eq!(typed_lines(&typed, ""), "", "a refused key presses nothing");
}

#[test]
#[cfg(unix)]
fn a_launch_whose_line_never_reached_its_window_closes_it_and_one_whose_paste_went_unanswered_keeps_its_record()
 {
    let real = std::env::var_os("PATH")
        .and_then(|path| {
            std::env::split_paths(&path)
                .map(|d| d.join("tmux"))
                .find(|p| p.is_file())
        })
        .expect("tmux on PATH");
    // (the tmux verb refused, the refusal, whether the window and its record
    // stand after it)
    for (verb, key, stands) in [
        ("load-buffer", "launch-line-unsent", false),
        ("paste-buffer", "launch-line-unanswered", true),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let pane = PrivatePane::behind_path(&root);
        let shims = root.join("refusing-tmux");
        std::fs::create_dir(&shims).unwrap();
        write_executable(
            &shims.join("tmux"),
            format!(
                "#!/bin/bash\nfor arg in \"$@\"; do [ \"$arg\" != {verb} ] || {{ echo refused >&2; exit 1; }}; done\nexec '{}' \"$@\"\n",
                real.display()
            ),
        );
        plant_login(&root.join("home"));
        let intent = root.join("intent.json");
        std::fs::write(
            &intent,
            serde_json::json!({"harness": "claude", "home": root.join("home"), "cwd": root})
                .to_string(),
        )
        .unwrap();
        let record = root.join("launch-record.json");
        let path = std::env::join_paths(std::iter::once(shims.clone()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        let out = Command::new(binary())
            .args(["launch", "--intent"])
            .arg(&intent)
            .arg("--record")
            .arg(&record)
            .arg("--socket")
            .arg(&pane.socket)
            .args(["--session", &pane.session, "--window-name", "launched"])
            .env("PATH", &path)
            .output()
            .unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_default();
        assert_eq!(reply["refusal"]["key"], key, "{verb}: {reply}");
        let windows = pane.tmux(&["list-windows", "-t", &pane.session, "-F", "#{window_name}"]);
        assert_eq!(
            windows.lines().any(|w| w == "launched"),
            stands,
            "{verb}: the window: {windows}"
        );
        assert_eq!(record.exists(), stands, "{verb}: the record");
        if stands {
            let recorded: serde_json::Value =
                serde_json::from_slice(&std::fs::read(&record).unwrap()).unwrap();
            let inspected = inspect(&record, &recorded);
            assert_eq!(
                inspected["pane"]["reading"], "live",
                "{verb}: the record names the window it opened: {inspected}"
            );
        }
    }
}

/// Through the real binary on a private server, the record path already
/// holding a record, so the launch's write is refused after its window
/// opened: a close tmux answers leaves no window and the write's own
/// refusal; a `kill-window` tmux refuses leaves the window, and the refusal
/// names it.
#[test]
#[cfg(unix)]
fn a_launch_whose_record_cannot_be_written_closes_its_window_or_names_the_one_it_could_not_close() {
    let real = std::env::var_os("PATH")
        .and_then(|path| {
            std::env::split_paths(&path)
                .map(|d| d.join("tmux"))
                .find(|p| p.is_file())
        })
        .expect("tmux on PATH");
    let shims = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../tests/rust/fixtures/tmux-refusing");
    // (the verb the tmux on PATH refuses, the refusal, whether the window stands)
    for (refuse, key, stands) in [
        ("", "revision-mismatch", false),
        ("kill-window", "launch-window-unclosed", true),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let pane = PrivatePane::behind_path(&root);
        plant_login(&root.join("home"));
        let intent = root.join("intent.json");
        std::fs::write(
            &intent,
            serde_json::json!({"harness": "claude", "home": root.join("home"), "cwd": root})
                .to_string(),
        )
        .unwrap();
        let record = root.join("launch-record.json");
        let standing = serde_json::json!({"version": 1, "revision": 1}).to_string();
        std::fs::write(&record, &standing).unwrap();
        let path = std::env::join_paths(std::iter::once(shims.clone()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        let out = Command::new(binary())
            .args(["launch", "--intent"])
            .arg(&intent)
            .arg("--record")
            .arg(&record)
            .arg("--socket")
            .arg(&pane.socket)
            .args(["--session", &pane.session, "--window-name", "launched"])
            .env("PATH", &path)
            .env("TMUX_REAL", &real)
            .env("TMUX_REFUSE", refuse)
            .output()
            .unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_default();
        assert_eq!(reply["refusal"]["key"], key, "{key}: {reply}");
        let windows = pane.tmux(&[
            "list-windows",
            "-t",
            &pane.session,
            "-F",
            "#{window_id} #{window_name}",
        ]);
        let window = windows
            .lines()
            .find_map(|w| w.strip_suffix(" launched"))
            .map(str::to_owned);
        assert_eq!(window.is_some(), stands, "{key}: the window: {windows}");
        assert_eq!(
            std::fs::read_to_string(&record).unwrap(),
            standing,
            "{key}: the standing record is untouched"
        );
        if let Some(window) = window {
            let named = reply["refusal"]["fields"]
                .as_array()
                .and_then(|fields| fields.iter().find(|field| field[0] == "window"))
                .map(|field| field[1].clone());
            assert_eq!(
                named,
                Some(serde_json::json!(window)),
                "the refusal names the window: {reply}"
            );
        }
    }
}

/// Through the real binary on a private server, with a `tmux` on `PATH`
/// that answers one verb its own way: a `new-window` tmux refuses is
/// `tmux-refused`, no window opened; one that opens the window and then
/// gives no answer within the bound is `launch-window-unanswered`, naming
/// the session and the window, which stands. A server whose
/// `after-new-window` hook fails makes tmux exit non-zero after the window
/// opened and its pane printed: `tmux-refused`, the window closed.
#[test]
fn a_new_window_tmux_refused_is_refused_and_one_that_gave_no_answer_is_unanswered() {
    let real = std::env::var_os("PATH")
        .and_then(|path| {
            std::env::split_paths(&path)
                .map(|d| d.join("tmux"))
                .find(|p| p.is_file())
        })
        .expect("tmux on PATH");
    // (what the shim does on new-window, the server's after-new-window hook,
    // the refusal, whether the window stands)
    for (answer, hook, key, stands) in [
        ("echo refused >&2; exit 1", None, "tmux-refused", false),
        (
            "\"$real\" \"$@\" >/dev/null; exec sleep 30",
            None,
            "launch-window-unanswered",
            true,
        ),
        (":", Some("run-shell 'exit 1'"), "tmux-refused", false),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let pane = PrivatePane::behind_path(&root);
        if let Some(hook) = hook {
            pane.tmux(&["set-hook", "-g", "after-new-window", hook]);
        }
        let shims = root.join("answering-tmux");
        std::fs::create_dir(&shims).unwrap();
        write_executable(
            &shims.join("tmux"),
            format!(
                "#!/bin/bash\nreal='{}'\nfor arg in \"$@\"; do [ \"$arg\" != new-window ] || {{ {answer}; }}; done\nexec \"$real\" \"$@\"\n",
                real.display()
            ),
        );
        plant_login(&root.join("home"));
        let intent = root.join("intent.json");
        std::fs::write(
            &intent,
            serde_json::json!({"harness": "claude", "home": root.join("home"), "cwd": root})
                .to_string(),
        )
        .unwrap();
        let record = root.join("launch-record.json");
        let path = std::env::join_paths(std::iter::once(shims.clone()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        let out = Command::new(binary())
            .args(["launch", "--intent"])
            .arg(&intent)
            .arg("--record")
            .arg(&record)
            .arg("--socket")
            .arg(&pane.socket)
            .args(["--session", &pane.session, "--window-name", "launched"])
            .env("PATH", &path)
            .output()
            .unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_default();
        assert_eq!(reply["refusal"]["key"], key, "{key}: {reply}");
        let windows = pane.tmux(&["list-windows", "-t", &pane.session, "-F", "#{window_name}"]);
        assert_eq!(
            windows.lines().any(|w| w == "launched"),
            stands,
            "{key}: the window: {windows}"
        );
        assert!(!record.exists(), "{key}: no pane to record");
        if stands {
            let fields = &reply["refusal"]["fields"];
            assert!(
                fields.to_string().contains("\"launched\""),
                "the refusal names the window: {fields}"
            );
        }
    }
}

/// With no `$TMUX`, no numeric `$UID` and an `id` that fails, a launch that
/// names no socket refuses `uid-unread` before any tmux call.
#[test]
fn a_launch_whose_uid_cannot_be_read_refuses_and_names_no_socket() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let shims = root.join("failing-id");
    std::fs::create_dir(&shims).unwrap();
    write_executable(
        &shims.join("id"),
        "#!/bin/bash\necho 'id: unread' >&2\nexit 1\n",
    );
    plant_login(&root.join("home"));
    let intent = root.join("intent.json");
    std::fs::write(
        &intent,
        serde_json::json!({"harness": "claude", "home": root.join("home"), "cwd": root})
            .to_string(),
    )
    .unwrap();
    let path = std::env::join_paths(std::iter::once(shims.clone()).chain(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    )))
    .unwrap();
    let out = Command::new(binary())
        .args(["launch", "--intent"])
        .arg(&intent)
        .arg("--record")
        .arg(root.join("launch-record.json"))
        .args(["--session", "probe", "--window-name", "launched"])
        .env("PATH", &path)
        .env("TMUX_TMPDIR", &root)
        .env_remove("TMUX")
        .env_remove("UID")
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_default();
    assert_eq!(reply["refusal"]["key"], "uid-unread", "{reply}");
}

#[test]
fn session_file_finds_the_rollout_by_its_id_and_answers_three_valued() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("codex");
    let day = home.join("sessions").join("2026").join("09").join("27");
    std::fs::create_dir_all(&day).unwrap();
    let rollout = day.join("rollout-2026-09-27T00-00-00-s1.jsonl");
    std::fs::write(&rollout, "{}\n").unwrap();
    std::fs::write(day.join("rollout-2026-09-27T00-00-01-s2.jsonl"), "{}\n").unwrap();
    let ask = |harness: &str, home: &std::path::Path, id: &str| {
        let out = Command::new(binary())
            .args(["session-file", "--harness", harness, "--home"])
            .arg(home)
            .arg("--cwd")
            .arg(dir.path())
            .args(["--id", id])
            .output()
            .unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
        (out.status.code(), reply)
    };
    let (code, reply) = ask("codex", &home, "s1");
    assert_eq!(code, Some(0), "{reply}");
    assert_eq!(reply["result"]["reading"], "live", "{reply}");
    assert_eq!(reply["result"]["file"], rollout.display().to_string());
    let (_, reply) = ask("codex", &home, "s3");
    assert_eq!(reply["result"]["reading"], "gone", "{reply}");
    let (_, reply) = ask("codex", &dir.path().join("cold"), "s1");
    assert_eq!(reply["result"]["reading"], "gone", "{reply}");
    let sealed = dir.path().join("sealed");
    std::fs::create_dir_all(sealed.join("sessions")).unwrap();
    std::fs::set_permissions(
        sealed.join("sessions"),
        std::fs::Permissions::from_mode(0o000),
    )
    .unwrap();
    let (_, reply) = ask("codex", &sealed, "s1");
    std::fs::set_permissions(
        sealed.join("sessions"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    assert_eq!(reply["result"]["reading"], "unreadable", "{reply}");
    assert!(reply["result"]["cause"].is_string(), "{reply}");
    let (code, reply) = ask("nope", &home, "s1");
    assert_eq!(code, Some(1));
    assert_eq!(reply["refusal"]["key"], "harness-unknown", "{reply}");
}

/// `rows verdict --kind KIND --file FILE`'s exit and reply, with `stdin`
/// piped in where given.
fn rows_verdict(
    kind: &str,
    file: &std::path::Path,
    stdin: Option<&[u8]>,
) -> (Option<i32>, serde_json::Value) {
    use std::io::Write as _;
    let mut child = Command::new(binary())
        .args(["rows", "verdict", "--kind", kind, "--file"])
        .arg(file)
        .stdin(match stdin {
            Some(_) => std::process::Stdio::piped(),
            None => std::process::Stdio::null(),
        })
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    if let Some(text) = stdin {
        let mut pipe = child.stdin.take().unwrap();
        pipe.write_all(text).unwrap();
    }
    let out = child.wait_with_output().unwrap();
    let reply = serde_json::from_slice(&out.stdout).unwrap_or_else(|_| {
        panic!(
            "rows verdict --kind {kind}: no reply: {}",
            String::from_utf8_lossy(&out.stderr)
        )
    });
    (out.status.code(), reply)
}

/// Each verdict word of the lane and the session table, `gone` and
/// `unreadable` with its cause, read from a planted rows file and from the
/// same text on stdin: the reading a provider gets for rows it fetched. A
/// last line a killed writer left half written is `unreadable`, never passed
/// over for the row before it. A lane Stop that ended on an error reads its
/// count first: agents still at work are `working`, an unread count
/// `unreadable`, whatever the error says.
#[test]
fn rows_verdict_reads_each_word_of_both_tables_from_a_file_and_from_stdin() {
    use serde_json::json;
    let live = |verdict: serde_json::Value| {
        let mut fields = verdict;
        fields["reading"] = json!("live");
        fields
    };
    let unreadable = |cause: &str| json!({"reading": "unreadable", "cause": cause});
    let gone = json!({"reading": "gone"});
    let earlier = r#"{"harness":"pi","event":"PreToolUse"}"#;
    let fragment = format!("{earlier}\n{{\"harness\":\"pi\",\"event\":\"Sto\n");
    let rows: Vec<(&str, String, serde_json::Value)> = vec![
        (
            "lane",
            r#"{"harness":"claude","event":"UserPromptSubmit"}"#.into(),
            live(json!({"verdict": "working"})),
        ),
        (
            "lane",
            r#"{"harness":"codex","event":"UserPromptSubmit"}"#.into(),
            live(json!({"verdict": "working"})),
        ),
        (
            "lane",
            r#"{"harness":"copilot","event":"UserPromptSubmit"}"#.into(),
            live(json!({"verdict": "working"})),
        ),
        (
            "lane",
            "{\"harness\":\"claude\",\"event\":\"UserPromptSubmit\"}\n{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"model_not_found\"}".into(),
            live(json!({"verdict": "idle", "cause": "model_not_found"})),
        ),
        (
            "lane",
            r#"{"harness":"claude","event":"StopFailure","error":"rate_limit"}"#.into(),
            live(json!({"verdict": "walled"})),
        ),
        (
            "lane",
            r#"{"harness":"claude","event":"StopFailure","error":"authentication_failed"}"#.into(),
            live(json!({"verdict": "walled"})),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"PreToolUse"}"#.into(),
            live(json!({"verdict": "working"})),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"Stop","working_agents":2}"#.into(),
            live(json!({"verdict": "working"})),
        ),
        (
            "lane",
            format!("{earlier}\n{}", r#"{"harness":"pi","event":"Stop","working_agents":0}"#),
            live(json!({"verdict": "idle", "cause": null})),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"Stop","stop_reason":"length","working_agents":0}"#.into(),
            live(json!({"verdict": "idle", "cause": "length"})),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"429 Usage limit reached for this model"}"#.into(),
            live(json!({"verdict": "walled"})),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"429 Usage limit reached for this model","working_agents":1}"#.into(),
            live(json!({"verdict": "working"})),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"Stop","stop_reason":"error","message":"429 Usage limit reached for this model","working_agents":null}"#.into(),
            unreadable("working-agents-unread"),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"Stop","working_agents":null}"#.into(),
            unreadable("working-agents-unread"),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"Stop","working_agents":2.0}"#.into(),
            unreadable("working-agents-unread"),
        ),
        (
            "lane",
            r#"{"harness":"pi","event":"SessionStart"}"#.into(),
            unreadable("lane-row-unjudged"),
        ),
        (
            "session",
            r#"{"harness":"copilot","event":"SessionEnd","reason":"exit"}"#.into(),
            live(json!({"verdict": "unsupported"})),
        ),
        (
            "session",
            r#"{"harness":"claude","event":"SessionEnd","reason":"exit"}"#.into(),
            live(json!({"verdict": "ended"})),
        ),
        (
            "session",
            r#"{"harness":"claude","event":"StopFailure","error":"authentication_failed"}"#.into(),
            live(json!({"verdict": "walled", "kind": "auth"})),
        ),
        (
            "session",
            r#"{"harness":"claude","event":"StopFailure","error":"rate_limit","message":"You've hit your weekly limit"}"#.into(),
            live(json!({"verdict": "walled", "kind": "usage"})),
        ),
        (
            "session",
            r#"{"harness":"claude","event":"StopFailure","error":"other","message":"Prompt is too long"}"#.into(),
            live(json!({"verdict": "wedged"})),
        ),
        (
            "session",
            r#"{"harness":"claude","event":"Stop","session_id":"s"}"#.into(),
            live(json!({"verdict": "live"})),
        ),
        ("lane", fragment.clone(), unreadable("rows-row-unparsed")),
        ("session", fragment, unreadable("rows-row-unparsed")),
        ("lane", String::new(), gone.clone()),
        ("session", "\n\n".into(), gone.clone()),
    ];
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("session-rows.jsonl");
    for (kind, text, expected) in &rows {
        std::fs::write(&file, format!("{text}\n")).unwrap();
        for stdin in [None, Some(format!("{text}\n"))] {
            let path = match stdin {
                Some(_) => std::path::Path::new("-"),
                None => file.as_path(),
            };
            let (code, reply) = rows_verdict(kind, path, stdin.as_deref().map(str::as_bytes));
            assert_eq!(
                code,
                Some(0),
                "{kind} {text} stdin={}: {reply}",
                stdin.is_some()
            );
            assert_eq!(
                &reply["result"],
                expected,
                "{kind} {text} stdin={}",
                stdin.is_some()
            );
        }
    }
    for kind in ["lane", "session"] {
        let (code, reply) = rows_verdict(kind, &dir.path().join("absent.jsonl"), None);
        assert_eq!((code, &reply["result"]), (Some(0), &gone), "{kind} absent");
        let (code, reply) = rows_verdict(kind, dir.path(), None);
        assert_eq!(
            (code, &reply["result"]),
            (Some(0), &unreadable("rows-file-unreadable")),
            "{kind} directory"
        );
    }
}

/// Rows that are no text are `unreadable`, from a file as from stdin, never
/// `gone`: a read that failed says nothing of the session.
#[test]
fn rows_verdict_reads_rows_that_are_no_text_as_unreadable() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("session-rows.jsonl");
    let bytes = b"{\"harness\":\"pi\",\"event\":\"Stop\"}\n\xff\xfe\n";
    std::fs::write(&file, bytes).unwrap();
    let unreadable = serde_json::json!({"reading": "unreadable", "cause": "rows-file-unreadable"});
    for kind in ["lane", "session"] {
        for (path, stdin) in [
            (file.as_path(), None),
            (std::path::Path::new("-"), Some(&bytes[..])),
        ] {
            let (code, reply) = rows_verdict(kind, path, stdin);
            assert_eq!(
                (code, &reply["result"]),
                (Some(0), &unreadable),
                "{kind} stdin={}",
                stdin.is_some()
            );
        }
    }
}

#[test]
fn rows_verdict_refuses_a_kind_it_has_no_table_for() {
    let dir = tempfile::tempdir().unwrap();
    let (code, reply) = rows_verdict("overseer", &dir.path().join("rows.jsonl"), None);
    assert_eq!(code, Some(1), "{reply}");
    assert_eq!(reply["refusal"]["key"], "rows-kind-unknown", "{reply}");
    assert_eq!(refusal_field(&reply, "kind").as_deref(), Some("overseer"));
}

/// The binary's exit status and its one reply line, over `args`.
fn reply_of(args: &[&std::ffi::OsStr]) -> (Option<i32>, serde_json::Value) {
    let out = Command::new(binary())
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let reply = serde_json::from_slice(&out.stdout).unwrap_or_else(|_| {
        panic!(
            "{args:?}: no reply: {}",
            String::from_utf8_lossy(&out.stderr)
        )
    });
    (out.status.code(), reply)
}

fn refusal_field(reply: &serde_json::Value, name: &str) -> Option<String> {
    reply["refusal"]["fields"]
        .as_array()?
        .iter()
        .find(|pair| pair[0] == name)
        .and_then(|pair| pair[1].as_str().map(str::to_owned))
}

/// The reading `process identity` gives for `pid`, a process this row started.
fn identity_reading(pid: u32) -> serde_json::Value {
    let pid = pid.to_string();
    reply_of(&["process".as_ref(), "identity".as_ref(), pid.as_ref()])
        .1
        .get("result")
        .cloned()
        .unwrap()
}

/// The pids a planted program wrote to `path`, once it wrote a whole line.
fn pids_at(path: &std::path::Path) -> Vec<u32> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && text.ends_with('\n')
        {
            return text
                .split_whitespace()
                .map(|p| p.parse().unwrap())
                .collect();
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{} never written",
            path.display()
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// What a group row leaves on its way out, even past a failed assertion:
/// the group its record names, stopped through the verb under test by each
/// member's identity, then the session `setsid` made for the row, by its own
/// group id, then every child this row holds, reaped.
struct GroupWorld {
    record: PathBuf,
    session: Option<u32>,
    children: Vec<std::process::Child>,
}

impl Drop for GroupWorld {
    fn drop(&mut self) {
        let _ = Command::new(binary())
            .args(["process", "stop", "--grace-secs", "1", "--file"])
            .arg(&self.record)
            .output();
        if let Some(session) = self.session {
            let _ = Command::new("kill")
                .args(["-KILL", "--", &format!("-{session}")])
                .status();
        }
        for child in &mut self.children {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// A non-leader with no terminal, as an SSH server runs a command inside the
/// group it shares with every other session's commands: the lead makes a new
/// group in place, records its leader, and becomes the program; the group
/// reads live with its members and the stop ends that group alone, the
/// server's own group and its other member left running.
#[cfg(target_os = "linux")]
#[test]
fn a_lead_without_a_group_or_terminal_makes_the_group_the_stop_ends_alone() {
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("lane-host-pid");
    // `setsid` leads a new session and group here, the stand-in for the
    // server; its background member runs the lead.
    let server = r#"sleep 600 >/dev/null 2>&1 & printf '%s\n' "$!" > "$3/bystander"
"$1" process lead --file "$2" -- sh -c 'sleep 600 >/dev/null 2>&1 & printf "%s %s\n" "$$" "$!" > "$1/lane"; wait' lane "$3" &
wait"#;
    let child = Command::new("setsid")
        .args(["sh", "-c", server, "server"])
        .arg(binary())
        .arg(&record)
        .arg(dir.path())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let server_pid = child.id();
    let _world = GroupWorld {
        record: record.clone(),
        session: Some(server_pid),
        children: vec![child],
    };
    let lane = pids_at(&dir.path().join("lane"));
    let (leader, member) = (lane[0], lane[1]);
    let bystander = pids_at(&dir.path().join("bystander"))[0];
    let recorded: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
    assert_eq!(recorded["pid"], leader, "{recorded}");
    assert_eq!(recorded["start"], identity_reading(leader)["start"]);
    let stat = std::fs::read_to_string(format!("/proc/{leader}/stat")).unwrap();
    let pgrp: u32 = stat[stat.rfind(')').unwrap() + 1..]
        .split_whitespace()
        .nth(2)
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!((pgrp, leader != server_pid), (leader, true));
    let file = record.as_os_str();
    let read = |member: u32| {
        let member = member.to_string();
        reply_of(&[
            "process".as_ref(),
            "group".as_ref(),
            "--file".as_ref(),
            file,
            "--member".as_ref(),
            member.as_ref(),
        ])
    };
    let (code, reply) = read(member);
    assert_eq!(code, Some(0), "{reply}");
    assert_eq!(
        (
            &reply["result"]["reading"],
            &reply["result"]["pid"],
            &reply["result"]["members"],
            &reply["result"]["member"],
        ),
        (
            &serde_json::json!("live"),
            &serde_json::json!(leader),
            &serde_json::json!(2),
            &serde_json::json!(true),
        ),
        "{reply}"
    );
    assert_eq!(read(bystander).1["result"]["member"], false);
    let stop = || {
        reply_of(&[
            "process".as_ref(),
            "stop".as_ref(),
            "--grace-secs".as_ref(),
            "5".as_ref(),
            "--file".as_ref(),
            file,
        ])
    };
    let (code, reply) = stop();
    assert_eq!(code, Some(0), "{reply}");
    assert_eq!(
        reply["result"]["stop"],
        serde_json::json!({"outcome": "stopped", "signaled": 2})
    );
    for pid in [leader, member] {
        assert_eq!(identity_reading(pid)["reading"], "gone", "{pid}");
    }
    for pid in [server_pid, bystander] {
        assert_eq!(identity_reading(pid)["reading"], "live", "{pid}");
    }
    assert_eq!(read(member).1["result"]["reading"], "gone");
    assert_eq!(
        stop().1["result"]["stop"],
        serde_json::json!({"outcome": "already-gone"})
    );
}

/// A caller that leads a group another process is in does not own that
/// group: the lead refuses before it records or runs anything.
#[cfg(target_os = "linux")]
#[test]
fn a_lead_over_a_group_another_process_is_in_refuses_group_shared() {
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("lane-host-pid");
    let shared = r#"sleep 600 >/dev/null 2>&1 &
exec "$1" process lead --file "$2" -- touch "$3/ran""#;
    let child = Command::new("setsid")
        .args(["sh", "-c", shared, "shared"])
        .arg(binary())
        .arg(&record)
        .arg(dir.path())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let _world = GroupWorld {
        record: record.clone(),
        session: Some(child.id()),
        children: Vec::new(),
    };
    let out = child.wait_with_output().unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(out.status.code(), Some(1), "{reply}");
    assert_eq!(reply["refusal"]["key"], "group-shared", "{reply}");
    assert_eq!(refusal_field(&reply, "members").as_deref(), Some("1"));
    assert!(!record.exists() && !dir.path().join("ran").exists());
}

/// A record whose group still runs refuses a second lead over it, whatever
/// the caller's standing: a launch that skipped its stop never starts a
/// second program, and the record stays as it was.
#[test]
fn a_lead_over_a_recorded_group_that_still_runs_refuses_group_live() {
    use std::os::unix::process::CommandExt;
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("lane-host-pid");
    let running = Command::new("sleep")
        .arg("600")
        .process_group(0)
        .spawn()
        .unwrap();
    let pid = running.id();
    let _world = GroupWorld {
        record: dir.path().join("none"),
        session: None,
        children: vec![running],
    };
    let identity = identity_reading(pid);
    let text = serde_json::json!({"pid": pid, "start": identity["start"]}).to_string();
    std::fs::write(&record, &text).unwrap();
    let ran = dir.path().join("ran");
    let (code, reply) = reply_of(&[
        "process".as_ref(),
        "lead".as_ref(),
        "--file".as_ref(),
        record.as_os_str(),
        "--".as_ref(),
        "touch".as_ref(),
        ran.as_os_str(),
    ]);
    assert_eq!(code, Some(1), "{reply}");
    assert_eq!(reply["refusal"]["key"], "group-live", "{reply}");
    assert_eq!(refusal_field(&reply, "pid"), Some(pid.to_string()));
    assert_eq!(std::fs::read_to_string(&record).unwrap(), text);
    assert!(!ran.exists());
}

/// A lead whose program cannot be run leaves no record naming a group
/// nothing leads.
#[cfg(target_os = "linux")]
#[test]
fn a_lead_whose_program_cannot_run_removes_its_record_and_refuses_exec_failed() {
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("lane-host-pid");
    let out = Command::new("setsid")
        .arg(binary())
        .args(["process", "lead", "--file"])
        .arg(&record)
        .arg("--")
        .arg(dir.path().join("absent"))
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(out.status.code(), Some(1), "{reply}");
    assert_eq!(reply["refusal"]["key"], "exec-failed", "{reply}");
    assert!(!record.exists());
}

/// The retired `--file --account` lead still records the account beside the
/// leader in the one folder the account picks count, warning `form-retired`;
/// a file anywhere else would leave the worker uncharged, so it refuses
/// before anything is written or run.
#[cfg(target_os = "linux")]
#[test]
fn a_lead_on_an_account_records_it_in_the_counted_folder_and_refuses_any_other() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let state = root.join("accounts");
    let cwd = root.join("cwd");
    let elsewhere = root.join("elsewhere");
    for made in [&cwd, &elsewhere] {
        std::fs::create_dir_all(made).unwrap();
    }
    let lead = |file: &std::path::Path, program: &[&std::ffi::OsStr]| {
        Command::new("setsid")
            .arg(binary())
            .args(["process", "lead", "--file"])
            .arg(file)
            .args(["--account", "/srv/.wclaude", "--"])
            .args(program)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &root)
            .env("GIT_CEILING_DIRECTORIES", &root)
            .env("AGENT_RUNTIME_ACCOUNT_STATE_DIR", &state)
            .current_dir(&cwd)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap()
    };
    let record = state.join("workers").join("w");
    let child = lead(&record, &["true".as_ref()]);
    let leader = child.id();
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    let warned = String::from_utf8_lossy(&out.stderr);
    assert!(
        warned.starts_with("agent-runtime: form-retired "),
        "{warned}"
    );
    let recorded: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
    assert_eq!(
        (&recorded["pid"], &recorded["account"]),
        (
            &serde_json::json!(leader),
            &serde_json::json!("/srv/.wclaude")
        ),
        "{recorded}"
    );
    assert!(recorded["start"].is_string(), "{recorded}");
    let outside = elsewhere.join("w");
    let ran = root.join("ran");
    let out = lead(&outside, &["touch".as_ref(), ran.as_os_str()])
        .wait_with_output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(out.status.code(), Some(1), "{reply}");
    assert_eq!(reply["refusal"]["key"], "group-file-uncounted", "{reply}");
    assert_eq!(
        refusal_field(&reply, "dir"),
        Some(state.join("workers").display().to_string())
    );
    assert!(!outside.exists() && !ran.exists());
}

/// A worker led by its name lands in the folder the account picks count
/// under the root the runtime resolves, here named only in the private env
/// file so a caller's own default (`~/.local/state`) would miss it; the
/// group and stop verbs read the same record by the same name.
#[cfg(target_os = "linux")]
#[test]
fn a_worker_led_by_name_is_charged_under_the_root_the_private_env_file_names() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let state = root.join("accounts");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        project.join(".env.local"),
        format!("AGENT_RUNTIME_ACCOUNT_STATE_DIR={}\n", state.display()),
    )
    .unwrap();
    // Only the private env file names the root: no XDG folder, the home
    // under the scratch root, and no checkout above the project.
    let in_world = |mut command: Command| {
        command
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &root)
            .env("GIT_CEILING_DIRECTORIES", &root)
            .current_dir(&project)
            .stdin(std::process::Stdio::null());
        command
    };
    let mut lead = in_world(Command::new("setsid"));
    let leader = lead
        .arg(binary())
        .args([
            "process",
            "lead",
            "--worker",
            "w",
            "--account",
            "/srv/.wclaude",
        ])
        .args(["--", "sleep", "300"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let _world = GroupWorld {
        record: state.join("workers").join("w"),
        session: None,
        children: vec![leader],
    };
    let reply = |args: &[&str]| -> serde_json::Value {
        let mut verb = in_world(Command::new(binary()));
        let out = verb.args(args).output().unwrap();
        serde_json::from_slice(&out.stdout).unwrap()
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while reply(&["process", "group", "--worker", "w"])["result"]["reading"] != "live" {
        assert!(std::time::Instant::now() < deadline, "the worker never led");
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let charges = || {
        agent_runtime::group::charges(
            &agent_runtime::group::workers_dir(&state),
            &agent_runtime::process::still_runs,
        )
        .unwrap()
    };
    assert_eq!(
        charges(),
        std::collections::BTreeMap::from([("/srv/.wclaude".to_owned(), 1)])
    );
    let stopped = reply(&["process", "stop", "--grace-secs", "5", "--worker", "w"]);
    assert_eq!(stopped["result"]["stop"]["outcome"], "stopped", "{stopped}");
    assert_eq!(charges(), std::collections::BTreeMap::new());
}

/// The recorded group, read and stopped: a member whose parent exited still
/// names the leader's group and is reached; a process in another group is
/// not. No record reads gone and stops nothing; a record of another shape
/// refuses every verb that reads it.
#[test]
fn the_recorded_group_reads_and_stops_with_its_orphan_and_nothing_else() {
    use std::os::unix::process::CommandExt;
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("lane-host-pid");
    let lane = Command::new("sh")
        .args([
            "-c",
            r#"sleep 600 >/dev/null 2>&1 & printf '%s\n' "$!" > "$1/member"
(sleep 600 >/dev/null 2>&1 & printf '%s\n' "$!" > "$1/orphan")
exec sleep 600"#,
            "lane",
        ])
        .arg(dir.path())
        .process_group(0)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let leader = lane.id();
    let bystander = Command::new("sleep")
        .arg("600")
        .process_group(0)
        .spawn()
        .unwrap();
    let bystander_pid = bystander.id();
    let _world = GroupWorld {
        record: record.clone(),
        session: None,
        children: vec![lane, bystander],
    };
    let member = pids_at(&dir.path().join("member"))[0];
    let orphan = pids_at(&dir.path().join("orphan"))[0];
    let identity = identity_reading(leader);
    std::fs::write(
        &record,
        serde_json::json!({"pid": leader, "start": identity["start"]}).to_string(),
    )
    .unwrap();
    let file = record.as_os_str();
    let read = |member: u32| {
        let member = member.to_string();
        reply_of(&[
            "process".as_ref(),
            "group".as_ref(),
            "--file".as_ref(),
            file,
            "--member".as_ref(),
            member.as_ref(),
        ])
        .1["result"]
            .clone()
    };
    let live = read(orphan);
    assert_eq!(
        (&live["reading"], &live["members"], &live["member"]),
        (
            &serde_json::json!("live"),
            &serde_json::json!(3),
            &serde_json::json!(true)
        ),
        "{live}"
    );
    assert_eq!(read(bystander_pid)["member"], false);
    let stop = |file: &std::ffi::OsStr| {
        reply_of(&[
            "process".as_ref(),
            "stop".as_ref(),
            "--grace-secs".as_ref(),
            "5".as_ref(),
            "--file".as_ref(),
            file,
        ])
    };
    let (code, reply) = stop(file);
    assert_eq!(code, Some(0), "{reply}");
    assert_eq!(
        reply["result"]["stop"],
        serde_json::json!({"outcome": "stopped", "signaled": 3})
    );
    for pid in [leader, member, orphan] {
        assert_eq!(identity_reading(pid)["reading"], "gone", "{pid}");
    }
    assert_eq!(identity_reading(bystander_pid)["reading"], "live");
    assert_eq!(
        read(orphan),
        serde_json::json!({"reading": "gone", "member": false})
    );
    assert_eq!(
        stop(file).1["result"]["stop"],
        serde_json::json!({"outcome": "already-gone"})
    );
    let absent = dir.path().join("absent");
    assert_eq!(
        stop(absent.as_os_str()).1["result"]["stop"],
        serde_json::json!({"outcome": "already-gone"})
    );
    std::fs::write(&record, "4242 Tue Nov 11 09:00:00 2026\n").unwrap();
    for verb in [
        &["process", "group", "--file"][..],
        &["process", "stop", "--file"][..],
    ] {
        let mut args: Vec<&std::ffi::OsStr> = verb.iter().map(|word| word.as_ref()).collect();
        args.push(file);
        let (code, reply) = reply_of(&args);
        assert_eq!(
            (code, &reply["refusal"]["key"]),
            (Some(1), &serde_json::json!("record-shape")),
            "{verb:?}: {reply}"
        );
    }
}

/// A process is the recorded group's where it or one of its ancestors is a
/// member, so a hook its harness runs in a group of its own still reads as
/// the harness's: a member, a child that leads a group of its own under a
/// member, and a process outside the group whose ancestry never meets it,
/// each in the group this row made.
#[cfg(target_os = "linux")]
#[test]
fn a_process_is_the_recorded_groups_where_it_or_an_ancestor_is_a_member() {
    use std::os::unix::process::CommandExt;
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("lane-host-pid");
    let lane = Command::new("sh")
        .args([
            "-c",
            r#"sleep 600 >/dev/null 2>&1 & printf '%s\n' "$!" > "$1/member"
setsid sleep 600 >/dev/null 2>&1 & printf '%s\n' "$!" > "$1/own"
wait"#,
            "lane",
        ])
        .arg(dir.path())
        .process_group(0)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let leader = lane.id();
    let bystander = Command::new("sleep")
        .arg("600")
        .process_group(0)
        .spawn()
        .unwrap();
    let bystander_pid = bystander.id();
    let member = pids_at(&dir.path().join("member"))[0];
    let own = pids_at(&dir.path().join("own"))[0];
    let _world = GroupWorld {
        record: record.clone(),
        session: Some(own),
        children: vec![lane, bystander],
    };
    let identity = identity_reading(leader);
    std::fs::write(
        &record,
        serde_json::json!({"pid": leader, "start": identity["start"]}).to_string(),
    )
    .unwrap();
    let stat = std::fs::read_to_string(format!("/proc/{own}/stat")).unwrap();
    let pgrp: u32 = stat[stat.rfind(')').unwrap() + 1..]
        .split_whitespace()
        .nth(2)
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(pgrp, own, "the child leads a group of its own");
    for (case, pid, want) in [
        ("a member", member, true),
        ("a child in a group of its own under a member", own, true),
        ("neither", bystander_pid, false),
    ] {
        let pid = pid.to_string();
        let (code, reply) = reply_of(&[
            "process".as_ref(),
            "group".as_ref(),
            "--file".as_ref(),
            record.as_os_str(),
            "--member".as_ref(),
            pid.as_ref(),
        ]);
        assert_eq!(code, Some(0), "{case}: {reply}");
        assert_eq!(
            (&reply["result"]["reading"], &reply["result"]["member"]),
            (&serde_json::json!("live"), &serde_json::json!(want)),
            "{case}: {reply}"
        );
    }
}

/// A launch into a window whose shell runs under another that waits on it,
/// as tmux's `sh -c` holds a default command under dash, records the
/// harness itself: the process the launch line `exec`s, by its own pid and
/// start, never the wrapper that holds the pane. The trailing `:` keeps
/// bash from replacing itself, so the wrapper stands on every host.
#[test]
#[cfg(target_os = "linux")]
fn a_launch_under_a_waiting_shell_records_the_harness_itself() {
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    pane.tmux(&["set-option", "-g", "default-command", "/bin/sh; :"]);
    let own_pid = dir.path().join("harness-pid");
    let program = dir.path().join("bin").join("claude");
    std::fs::create_dir_all(program.parent().unwrap()).unwrap();
    write_executable(
        &program,
        format!(
            "#!/bin/bash\nprintf '%s\\n' \"$$\" > '{}'\nprintf '\\342\\235\\257\\302\\240\\n'\nread -r _\n",
            own_pid.display()
        ),
    );
    let home = dir.path().join("home");
    plant_login(&home);
    let intent = dir.path().join("intent.json");
    std::fs::write(
        &intent,
        serde_json::json!({"harness": "claude", "home": home, "cwd": dir.path(), "program": program})
            .to_string(),
    )
    .unwrap();
    let record = dir.path().join("record.json");
    let out = Command::new(binary())
        .args(["launch", "--intent"])
        .arg(&intent)
        .arg("--record")
        .arg(&record)
        .arg("--socket")
        .arg(&pane.socket)
        .args(["--session", &pane.session, "--window-name", "lane"])
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|_| panic!("no reply: {}", String::from_utf8_lossy(&out.stderr)));
    assert_eq!(reply["ok"], true, "{reply}");
    let recorded: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&record).unwrap()).unwrap();
    // The launch answers once it has typed its line, which the pane's shell
    // may not have run yet, so the row waits for the harness's own write.
    let harness_pid = pids_at(&own_pid)[0];
    let lane = recorded["pane"]["id"].as_str().expect("the record's pane");
    let pane_pid: u32 = pane
        .tmux(&["display-message", "-p", "-t", lane, "#{pane_pid}"])
        .trim()
        .parse()
        .unwrap();
    assert_ne!(pane_pid, harness_pid, "the wrapper holds the pane");
    // The first read once the harness is up records its process.
    let result = inspect(&record, &recorded);
    assert_eq!(result["harness_process"]["pid"], harness_pid, "{result}");
    assert_eq!(
        result["harness_process"]["start"],
        identity_reading(harness_pid)["start"]
    );
}

/// A Claude stored login in `home`, which a launch billing that home signs
/// in with where no token file is declared for it.
fn plant_login(home: &Path) {
    std::fs::create_dir_all(home).unwrap();
    std::fs::write(
        home.join(".credentials.json"),
        r#"{"claudeAiOauth":{"accessToken":"planted","subscriptionType":"max"}}"#,
    )
    .unwrap();
}

/// `agent-runtime launch` of an intent billing a named Claude home, a
/// Claude intent's home or account or a Pi `pi-claude/` intent's account,
/// signs in as that home whatever the tmux server's environment holds: the
/// server's token never reaches the harness, the token file the setting
/// declares for the home does, and a home it declares nothing for signs in
/// by its stored login, no token in the environment. A home holding no
/// sign-in, a declared file absent, empty or unreadable among them, refuses
/// before any window opens, naming the home, the cause and the file. Each
/// row: the case, the harness and the field naming the home, the declared
/// file, whether the home holds a stored login, and the token the harness
/// holds or the refusal's cause.
#[test]
fn a_launch_naming_a_claude_home_signs_in_as_that_home_alone() {
    #[derive(Clone, Copy)]
    enum File {
        None,
        Held,
        Absent,
        Empty,
        Directory,
    }
    enum Want {
        Holds(Option<&'static str>),
        Refused(&'static str),
    }
    let rows = [
        (
            "a Claude home by file",
            "claude",
            "home",
            File::Held,
            false,
            Want::Holds(Some("file-token")),
        ),
        (
            "a Claude home by login",
            "claude",
            "home",
            File::None,
            true,
            Want::Holds(None),
        ),
        (
            "a Claude account by file",
            "claude",
            "account",
            File::Held,
            false,
            Want::Holds(Some("file-token")),
        ),
        (
            "a Claude account by login",
            "claude",
            "account",
            File::None,
            true,
            Want::Holds(None),
        ),
        (
            "a Pi seat by file",
            "pi",
            "account",
            File::Held,
            false,
            Want::Holds(Some("file-token")),
        ),
        (
            "a Pi seat by login",
            "pi",
            "account",
            File::None,
            true,
            Want::Holds(None),
        ),
        (
            "a declared file absent",
            "claude",
            "home",
            File::Absent,
            true,
            Want::Refused("declared-token-absent"),
        ),
        (
            "a declared file empty",
            "claude",
            "home",
            File::Empty,
            true,
            Want::Refused("declared-token-absent"),
        ),
        (
            "a declared directory",
            "claude",
            "home",
            File::Directory,
            true,
            Want::Refused("declared-token-unreadable"),
        ),
        (
            "neither",
            "claude",
            "home",
            File::None,
            false,
            Want::Refused("no-credential"),
        ),
    ];
    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    pane.tmux(&[
        "set-environment",
        "-g",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "inherited",
    ]);
    for (n, (case, harness, field, file, stored, want)) in rows.into_iter().enumerate() {
        let row = dir.path().join(format!("row{n}"));
        let seen = row.join("seen-token");
        let program = row.join("bin").join(harness);
        std::fs::create_dir_all(program.parent().unwrap()).unwrap();
        write_executable(
            &program,
            format!(
                "#!/bin/bash\nprintf '%s\\n' \"${{CLAUDE_CODE_OAUTH_TOKEN-unset}}\" > '{seen}.part' && mv '{seen}.part' '{seen}'\nread -r _\n",
                seen = seen.display()
            ),
        );
        let home = row.join("home");
        std::fs::create_dir_all(&home).unwrap();
        if stored {
            plant_login(&home);
        }
        let token = row.join("home.token");
        match file {
            File::Held => std::fs::write(&token, "file-token\n").unwrap(),
            File::Empty => std::fs::write(&token, "\n").unwrap(),
            File::Directory => std::fs::create_dir_all(&token).unwrap(),
            File::None | File::Absent => {}
        }
        let mut body = serde_json::json!({"harness": harness, "cwd": row, "program": program});
        body[field] = serde_json::json!(home);
        if harness == "pi" {
            body["model"] = serde_json::json!("pi-claude/claude-fable-5-1");
        }
        let intent = row.join("intent.json");
        std::fs::write(&intent, body.to_string()).unwrap();
        let setting = match file {
            File::None => String::new(),
            File::Held | File::Absent | File::Empty | File::Directory => {
                format!("{}={}", home.display(), token.display())
            }
        };
        let windows = pane.tmux(&["list-windows", "-a", "-F", "#{window_id}"]);
        let out = Command::new(binary())
            .current_dir(&row)
            .args(["launch", "--intent"])
            .arg(&intent)
            .arg("--record")
            .arg(row.join("record.json"))
            .arg("--socket")
            .arg(&pane.socket)
            .args(["--session", &pane.session, "--window-name", "lane"])
            .env("AGENT_RUNTIME_ACCOUNT_TOKEN_FILES", &setting)
            .output()
            .unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|_| {
            panic!("{case}: no reply: {}", String::from_utf8_lossy(&out.stderr))
        });
        match want {
            Want::Holds(holds) => {
                assert_eq!(reply["ok"], true, "{case}: {reply}");
                let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
                let text = loop {
                    if let Ok(text) = std::fs::read_to_string(&seen) {
                        break text;
                    }
                    assert!(
                        std::time::Instant::now() < deadline,
                        "{case}: the harness never ran"
                    );
                    std::thread::sleep(std::time::Duration::from_millis(50));
                };
                assert_eq!(text.trim_end(), holds.unwrap_or("unset"), "{case}");
            }
            Want::Refused(cause) => {
                assert_eq!(
                    reply["refusal"]["key"], "successor-not-signed-in",
                    "{case}: {reply}"
                );
                let mut fields = vec![
                    serde_json::json!(["account", home.display().to_string()]),
                    serde_json::json!(["cause", cause]),
                ];
                if !matches!(file, File::None) {
                    fields.push(serde_json::json!(["file", token.display().to_string()]));
                }
                assert_eq!(
                    reply["refusal"]["fields"],
                    serde_json::json!(fields),
                    "{case}: {reply}"
                );
                assert_eq!(
                    pane.tmux(&["list-windows", "-a", "-F", "#{window_id}"]),
                    windows,
                    "{case}: no window opened"
                );
                assert!(!seen.exists(), "{case}: the harness never ran");
            }
        }
    }
}

/// An adoption records the harness identity read in the pane's foreground,
/// never the caller's word for it, and the posture that harness was launched
/// under, never the launch setting's; a record of another, live controller
/// refuses `overseer-live`; a pane holding no harness refuses
/// `pane-not-harness`; the same pane adopted again is healed in place.
#[test]
fn adopt_controller_binds_the_harness_read_in_the_pane_and_refuses_a_live_record_or_a_shell() {
    use serde_json::json;

    // A child this test holds, killed and reaped on drop whatever is asserted.
    struct Held(std::process::Child);
    impl Drop for Held {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    let dir = tempfile::tempdir().unwrap();
    let pane = PrivatePane::start(dir.path());
    // The harness runs under a shell that waits on it, as tmux's `sh -c`
    // does under dash, on every host: the trailing `:` keeps bash from
    // replacing itself too. The harness is the shell's child, never the
    // pane's own process.
    let own_pid = dir.path().join("harness-pid");
    let stub = dir.path().join("bin").join("claude");
    std::fs::create_dir_all(stub.parent().unwrap()).unwrap();
    write_executable(
        &stub,
        format!(
            "#!/bin/bash\nprintf '%s\\n' \"$$\" > '{}'\necho ready\nread -r _\n",
            own_pid.display()
        ),
    );
    pane.tmux(&[
        "respawn-pane",
        "-k",
        "-t",
        &pane.pane,
        &format!("'{}'; :", stub.display()),
    ]);
    pane.await_row(&|row| row == "ready");
    let record = dir.path().join("workflow-state-oversee.json");
    std::fs::write(&record, r#"{"intents": []}"#).unwrap();
    let cwd = dir.path().display().to_string();
    let socket = pane.socket.display().to_string();
    let adopt = |target: &str| -> (Option<i32>, serde_json::Value) {
        let out = Command::new(binary())
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", dir.path())
            .env("TMPDIR", dir.path())
            .env("LANG", "C.UTF-8")
            .args(["controller", "adopt", "--record"])
            .arg(&record)
            .args(["--pane", target, "--socket", &socket, "--harness", "claude"])
            .args([
                "--session-id",
                "by-hand-1",
                "--account",
                &cwd,
                "--cwd",
                &cwd,
            ])
            .output()
            .unwrap();
        let reply = serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|_| panic!("no reply: {}", String::from_utf8_lossy(&out.stderr)));
        (out.status.code(), reply)
    };
    // The same adoption by a request file naming the posture's words alone.
    let adopt_naming_words = |words: serde_json::Value| -> (Option<i32>, serde_json::Value) {
        let request = dir.path().join("adopt-request.json");
        let body = json!({
            "pane": pane.pane,
            "socket": socket,
            "harness": "claude",
            "session_id": "by-hand-1",
            "account": cwd,
            "cwd": cwd,
            "extra_args": words,
        });
        std::fs::write(&request, body.to_string()).unwrap();
        let out = Command::new(binary())
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", dir.path())
            .env("TMPDIR", dir.path())
            .env("LANG", "C.UTF-8")
            .args(["controller", "adopt", "--record"])
            .arg(&record)
            .arg("--request")
            .arg(&request)
            .output()
            .unwrap();
        let reply = serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|_| panic!("no reply: {}", String::from_utf8_lossy(&out.stderr)));
        (out.status.code(), reply)
    };
    let fleet = || -> serde_json::Value {
        serde_json::from_slice(&std::fs::read(&record).unwrap()).unwrap()
    };
    let harness_pid: u32 = std::fs::read_to_string(&own_pid)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let pane_pid: u32 = pane
        .tmux(&["display-message", "-p", "-t", &pane.pane, "#{pane_pid}"])
        .trim()
        .parse()
        .unwrap();
    assert_ne!(pane_pid, harness_pid, "the wrapper holds the pane");

    let (code, answer) = adopt(&pane.pane);
    assert_eq!(code, Some(0), "{answer}");
    assert_eq!(answer["result"], json!({"generation": 1, "healed": false}));
    let overseer = fleet()["controller"].clone();
    assert_eq!(overseer["pane"], pane.pane);
    assert_eq!(overseer["server"], pane.server_pid.to_string());
    assert_eq!(overseer["server_start"], pane.server_start);
    assert_eq!(overseer["window"], pane.window);
    assert_eq!(overseer["harness_pid"], harness_pid);
    assert_eq!(
        overseer["harness_start"],
        identity_reading(harness_pid)["start"]
    );
    assert_eq!(overseer["session_id"], "by-hand-1");
    // Started with no permission word: its native defaults, whatever the
    // launch setting's posture, a full bypass when unset as here.
    assert_eq!(overseer["permission"], "native");
    assert_eq!(overseer["extra_args"], json!([]));
    // Named words alone spell the posture, whatever the harness was
    // launched under: never native beside a full-bypass word, which the
    // successor's launch refuses.
    let (code, answer) = adopt_naming_words(json!(["--dangerously-skip-permissions"]));
    assert_eq!(code, Some(0), "{answer}");
    assert_eq!(answer["result"]["healed"], true, "{answer}");
    let overseer = fleet()["controller"].clone();
    assert_eq!(overseer["permission"], "bypass");
    assert_eq!(
        overseer["extra_args"],
        json!(["--dangerously-skip-permissions"])
    );
    // The same pane and process adopted again naming nothing: where the
    // host keeps its launch words (`/proc`), the posture is read off them
    // again, so the bypass the harness does not run under is dropped;
    // elsewhere nothing read contradicts the recorded pair, which is kept.
    let (code, answer) = adopt(&pane.pane);
    assert_eq!(code, Some(0), "{answer}");
    assert_eq!(answer["result"]["healed"], true, "{answer}");
    let overseer = fleet()["controller"].clone();
    let (permission, words) = if cfg!(target_os = "linux") {
        ("native", json!([]))
    } else {
        ("bypass", json!(["--dangerously-skip-permissions"]))
    };
    assert_eq!(overseer["permission"], permission);
    assert_eq!(overseer["extra_args"], words);
    // The same pane again, its harness now started under the full bypass:
    // healed, the generation kept, the posture the one it runs under where
    // the host keeps its words (`/proc`); elsewhere its native defaults.
    std::fs::remove_file(&own_pid).unwrap();
    pane.tmux(&[
        "respawn-pane",
        "-k",
        "-t",
        &pane.pane,
        &format!("'{}' --dangerously-skip-permissions; :", stub.display()),
    ]);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while std::fs::read_to_string(&own_pid).map_or(true, |pid| !pid.ends_with('\n')) {
        assert!(
            std::time::Instant::now() < deadline,
            "the harness never restarted"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let (_, answer) = adopt(&pane.pane);
    assert_eq!(answer["result"]["healed"], true, "{answer}");
    let overseer = fleet()["controller"].clone();
    assert_eq!(overseer["generation"], 1);
    let (permission, words) = if cfg!(target_os = "linux") {
        ("bypass", json!(["--dangerously-skip-permissions"]))
    } else {
        ("native", json!([]))
    };
    assert_eq!(overseer["permission"], permission);
    assert_eq!(overseer["extra_args"], words);
    // A pane whose foreground is no harness.
    let idle = pane
        .tmux(&[
            "new-window",
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            "-t",
            &pane.session,
            "exec sleep 600",
        ])
        .trim()
        .to_owned();
    let (code, answer) = adopt(&idle);
    assert_eq!(code, Some(1), "{answer}");
    assert_eq!(answer["refusal"]["key"], "pane-not-harness", "{answer}");
    // Another, live controller recorded: a second one is refused.
    let live = Held(Command::new("sleep").arg("600").spawn().unwrap());
    let identity = identity_reading(live.0.id());
    let mut doc = fleet();
    doc["controller"] = json!({
        "runtime": "tmux",
        "generation": 3,
        "server": pane.server_pid.to_string(),
        "server_start": pane.server_start,
        "server_socket": socket,
        "pane": "%99",
        "window": "@99",
        "harness_pid": live.0.id().to_string(),
        "harness_start": identity["start"],
        "harness": "claude",
        "cwd": cwd,
    });
    std::fs::write(&record, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    let (code, answer) = adopt(&pane.pane);
    assert_eq!(code, Some(1), "{answer}");
    assert_eq!(answer["refusal"]["key"], "overseer-live", "{answer}");
    assert_eq!(fleet()["controller"]["pane"], "%99", "nothing written");
    // That controller gone: adopted at the next generation.
    drop(live);
    let (code, answer) = adopt(&pane.pane);
    assert_eq!(code, Some(0), "{answer}");
    assert_eq!(answer["result"]["generation"], 4);
    assert_eq!(fleet()["controller"]["pane"], pane.pane);
}

/// The room a session inside a lane reads is its own `CODEX_HOME`'s, never
/// the default home under `HOME`.
#[test]
fn subagent_room_reads_the_config_under_codex_home() {
    let root = tempfile::tempdir().unwrap();
    let codex_home = root.path().join("lane-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::write(
        codex_home.join("config.toml"),
        "[features.multi_agent_v2]\nmax_concurrent_threads_per_session = 8\n",
    )
    .unwrap();
    let out = Command::new(binary())
        .args(["subagent", "room", "--harness", "codex"])
        .env_clear()
        .env("HOME", root.path())
        .env("CODEX_HOME", &codex_home)
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(out.status.code(), Some(0), "{reply}");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(
        reply["result"],
        serde_json::json!({
            "config_path": codex_home.join("config.toml"),
            "effective_cap": 8,
            "cap_source": "config",
            "in_use": "unread",
        })
    );
}

/// A root for a row that runs the wrapper, under the build's own temporary
/// folder: under `/tmp` the wrapper's private `/tmp` would take a write to
/// the row's home for a granted one.
fn wrapper_root() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let root = dir.path().canonicalize().unwrap();
    assert!(!root.starts_with("/tmp"), "{}", root.display());
    (dir, root)
}

/// The wrapper's environment and words for `grants`, run as the pane's
/// line would run them: the environment set on the wrapper's process, the
/// words after its name. Grants with no display and no token spell no word
/// the pane's shell expands.
#[cfg(target_os = "linux")]
fn plain_wrapper(grants: &agent_runtime::confine::Grants) -> (Vec<(String, String)>, Vec<String>) {
    use agent_runtime::confine::{Word, linux_env, linux_words};
    let plain = |word| match word {
        Word::Plain(word) => word,
        Word::Display(_) | Word::Text(_) => panic!("a shell word without its grant"),
    };
    let env = linux_env(grants)
        .into_iter()
        .map(|(name, value)| (name, plain(value)))
        .collect();
    (env, linux_words(grants).into_iter().map(plain).collect())
}

/// The kernel holds what the grants say, for the program and its child:
/// the home refuses a write, the worktree and the seat's session folder
/// take one, the seat itself and its settings refuse a write and a
/// replacement, a socket in the runtime folder is hidden and the one bound
/// back stands. The words alone are run, as the pane would run them, with
/// no launch around them.
#[test]
#[cfg(target_os = "linux")]
fn a_program_under_the_words_writes_its_worktree_and_is_refused_its_home_and_the_runtime_sockets() {
    use agent_runtime::confine::Grants;
    use std::os::unix::net::UnixListener;
    let (_dir, root) = wrapper_root();
    let [home, wt, seat, rt] = ["home", "wt", "seat", "rt"].map(|n| root.join(n));
    for dir in [&home, &wt, &seat.join("projects"), &rt] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(seat.join("settings.json"), "{}").unwrap();
    let _bus = UnixListener::bind(rt.join("bus")).unwrap();
    let _agent = UnixListener::bind(rt.join("agent.sock")).unwrap();
    let grants = Grants {
        writable: vec![wt.clone(), seat.join("projects")],
        seats: vec![seat.clone()],
        read_only: vec![seat.join("settings.json")],
        runtime_dir: Some(rt.clone()),
        sockets: vec![rt.join("agent.sock")],
        desktop: false,
        gh_token: None,
        unconfined: None,
        file: root.join("grants.json"),
    };
    let (env, words) = plain_wrapper(&grants);
    let script = r#"touch "$HOME/x" 2>/dev/null && echo home=written || echo home=refused
sh -c 'touch "$HOME/child"' 2>/dev/null && echo child=written || echo child=refused
touch "$1/y" && echo worktree=written || echo worktree=refused
touch "$2/credentials" 2>/dev/null && echo seat=written || echo seat=refused
touch "$2/projects/session.jsonl" && echo session=written || echo session=refused
{ echo '{"hooks":1}' > "$2/settings.json"; } 2>/dev/null && echo settings=written || echo settings=refused
mv "$2/settings.json" "$2/old.json" 2>/dev/null && echo replace=written || echo replace=refused
[ -S "$3/bus" ] && echo bus=visible || echo bus=hidden
[ -S "$3/agent.sock" ] && echo agent=bound || echo agent=hidden
echo "confined=${AGENT_RUNTIME_CONFINED:-none}"
"#;
    let out = Command::new("bwrap")
        .args(&words)
        .args(["/bin/sh", "-c", script, "_"])
        .args([&wt, &seat, &rt])
        .env_clear()
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin")
        .envs(env)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert_eq!(
        stdout.lines().collect::<Vec<_>>(),
        [
            "home=refused",
            "child=refused",
            "worktree=written",
            "seat=refused",
            "session=written",
            "settings=refused",
            "replace=refused",
            "bus=hidden",
            "agent=bound",
            "confined=1",
        ]
    );
    assert!(!home.join("x").exists() && !home.join("child").exists());
    assert!(wt.join("y").exists() && seat.join("projects/session.jsonl").exists());
    assert!(!seat.join("credentials").exists());
    assert_eq!(
        std::fs::read_to_string(seat.join("settings.json")).unwrap(),
        "{}"
    );
}

/// A pane whose environment names a temporary folder outside the grants
/// (the tmux server's, as a user service manager publishes it) still hands
/// its program a scratch: the words point `TMPDIR` and each harness's own
/// temporary-folder variable at the private `/tmp`, and the outside folder
/// takes nothing.
#[test]
#[cfg(target_os = "linux")]
fn a_program_under_the_words_whose_tmpdir_is_outside_the_grants_writes_its_scratch() {
    use agent_runtime::confine::Grants;
    let (_dir, root) = wrapper_root();
    let [home, wt, outside] = ["home", "wt", "outside"].map(|n| root.join(n));
    for dir in [&home, &wt, &outside] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let grants = Grants {
        writable: vec![wt.clone()],
        seats: Vec::new(),
        read_only: Vec::new(),
        runtime_dir: None,
        sockets: Vec::new(),
        desktop: false,
        gh_token: None,
        unconfined: None,
        file: root.join("grants.json"),
    };
    let (env, words) = plain_wrapper(&grants);
    let names = [
        "TMPDIR",
        "CLAUDE_CODE_TMPDIR",
        "CLAUDE_TMPDIR",
        "BUN_TMPDIR",
        "SQLITE_TMPDIR",
    ];
    let script = r#"scratch=$(mktemp 2>/dev/null) && echo scratch=written || echo scratch=refused
mkdir -p "$CLAUDE_CODE_TMPDIR/claude" 2>/dev/null && echo claude=written || echo claude=refused
for name in "$@"; do eval "echo $name=\$$name"; done"#;
    let out = Command::new("bwrap")
        .args(&words)
        .args(["/bin/sh", "-c", script, "_"])
        .args(names)
        .env_clear()
        .env("HOME", &home)
        .env("PATH", "/usr/bin:/bin")
        .envs(names.map(|name| (name, &outside)))
        .envs(env)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let mut expected = vec!["scratch=written".to_owned(), "claude=written".to_owned()];
    expected.extend(names.map(|name| format!("{name}=/tmp")));
    assert_eq!(
        String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .collect::<Vec<_>>(),
        expected
    );
    assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 0);
}

/// A confined setup that fails because the wrapper cannot make a mount (a
/// read-only grant naming a link, which bwrap refuses as a destination)
/// names the wrapper's refusal; a setup that fails under words that stand
/// keeps its own `runtime-unbuilt`.
#[test]
#[cfg(target_os = "linux")]
fn a_confined_setup_whose_words_fail_names_the_wrapper_and_one_that_fails_itself_is_unbuilt() {
    use agent_runtime::Error;
    use agent_runtime::confine::{Grants, Host, confinement};
    use agent_runtime::effects::prepare::build_runtimes;
    use agent_runtime::harness::Harness;
    use agent_runtime::launch::LaunchCommand;
    let (_dir, root) = wrapper_root();
    let wt = root.join("wt");
    let setup = ".agents/skills/orch/scripts/setup";
    std::fs::create_dir_all(wt.join(setup).parent().unwrap()).unwrap();
    write_executable(
        &wt.join(setup),
        "#!/bin/sh\necho 'setup: failed' >&2\nexit 3\n",
    );
    std::fs::write(root.join("settings-file.json"), "{}").unwrap();
    std::os::unix::fs::symlink(root.join("settings-file.json"), root.join("settings.json"))
        .unwrap();
    let refusal = |read_only: Vec<PathBuf>| {
        let grants = Grants {
            writable: vec![wt.clone()],
            seats: Vec::new(),
            read_only,
            runtime_dir: None,
            sockets: Vec::new(),
            desktop: false,
            gh_token: None,
            unconfined: None,
            file: root.join("grants.json"),
        };
        let command = LaunchCommand {
            program: "claude".to_owned(),
            args: Vec::new(),
            env: std::collections::BTreeMap::new(),
            env_remove: Vec::new(),
            env_files: Default::default(),
            cwd: wt.clone(),
            brief_arg: None,
            brief_path: None,
            confinement: Some(confinement(Host::Linux, Harness::Claude, &grants).unwrap()),
        };
        match build_runtimes(&[setup], &command) {
            Err(Error::Refused { key, fields }) => (key, fields),
            other => panic!("{other:?}"),
        }
    };
    let (key, fields) = refusal(vec![root.join("settings.json")]);
    assert_eq!(key, "confinement-failed", "{fields:?}");
    let field = |fields: &[(String, String)], name: &str| {
        fields
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    };
    assert_eq!(
        field(&fields, "setup"),
        wt.join(setup).display().to_string()
    );
    assert!(
        field(&fields, "detail").starts_with("bwrap: "),
        "bwrap's own line: {fields:?}"
    );
    let (key, fields) = refusal(Vec::new());
    assert_eq!(key, "runtime-unbuilt", "{fields:?}");
    assert_eq!(field(&fields, "detail"), "setup: failed");
}

/// The probe judges the `PATH` the launch's shell searches: no `bwrap`
/// there, a `bwrap` whose trial run is refused (its own line carried), and
/// the host's working one.
#[test]
#[cfg(target_os = "linux")]
fn the_probe_names_a_missing_bwrap_and_a_refused_trial_and_answers_a_working_one() {
    use agent_runtime::Error;
    use agent_runtime::confine::{Answer, Host};
    let probe = |path: Option<&std::ffi::OsStr>| agent_runtime::confine::probe(Host::Linux, path);
    let (_dir, root) = wrapper_root();
    let empty = root.join("empty");
    let planted = root.join("planted");
    std::fs::create_dir_all(&empty).unwrap();
    std::fs::create_dir_all(&planted).unwrap();
    write_executable(
        &planted.join("bwrap"),
        "#!/bin/sh\necho 'bwrap: planted refusal' >&2\nexit 1\n",
    );
    let refusal = |dir: &std::path::Path| match probe(Some(dir.as_os_str())) {
        Err(Error::Refused {
            key: "confinement-unavailable",
            fields,
        }) => fields,
        other => panic!("{}: {other:?}", dir.display()),
    };
    assert_eq!(
        refusal(&empty),
        [("cause".to_owned(), "bwrap-missing".to_owned())]
    );
    assert_eq!(
        refusal(&planted),
        [
            ("cause".to_owned(), "userns-off".to_owned()),
            ("detail".to_owned(), "bwrap: planted refusal".to_owned()),
        ]
    );
    let host = std::env::var_os("PATH").expect("PATH");
    assert_eq!(probe(Some(&host)).unwrap(), Answer::Confined);
}

/// A launch row's world: a root outside `/tmp`, a lanes' tmux server
/// whose socket stands in the runtime folder the grants hide, a second
/// server at that folder's `wayland-1` standing for the display (a tmux
/// client's answer is the proof a socket was reached), the display's name
/// in the lanes server's environment, and the seat and worktree a launch
/// is granted. Both servers end with the world.
struct ConfinedWorld {
    _dir: tempfile::TempDir,
    root: PathBuf,
    rt: PathBuf,
    wt: PathBuf,
    seat: PathBuf,
    lanes: PathBuf,
    display: PathBuf,
}

impl ConfinedWorld {
    fn new() -> ConfinedWorld {
        let (dir, root) = wrapper_root();
        let [rt, wt, seat] = ["rt", "wt", "seat"].map(|n| root.join(n));
        for dir in [&rt, &wt, &seat] {
            std::fs::create_dir_all(dir).unwrap();
        }
        plant_login(&seat);
        let lanes = rt.join("tmux");
        let display = rt.join("wayland-1");
        agent_runtime::host::tmux::start_private_server(&lanes, "lanes", &root)
            .expect("the lanes' server");
        agent_runtime::host::tmux::start_private_server(&display, "display", &root)
            .expect("the display's server");
        // The session's own: tmux records a display name its creating
        // client lacked as removed in the session, over the global one.
        tmux_at(
            &lanes,
            &[
                "set-environment",
                "-t",
                "lanes",
                "WAYLAND_DISPLAY",
                "wayland-1",
            ],
        );
        ConfinedWorld {
            _dir: dir,
            root,
            rt,
            wt,
            seat,
            lanes,
            display,
        }
    }

    /// Launch `harness` through the real `agent-runtime launch` in a window
    /// named `window`, its program a planted script that reports what it
    /// and its child reach into the worktree, under grants of the worktree
    /// and the seat with the runtime folder hidden, `desktop` as given.
    /// The reply, the grants as the intent named them, and the report.
    fn launch(
        &self,
        harness: &str,
        window: &str,
        desktop: bool,
    ) -> (
        serde_json::Value,
        serde_json::Value,
        std::collections::BTreeMap<String, String>,
    ) {
        let bin = self.root.join("bin").join(window);
        std::fs::create_dir_all(&bin).unwrap();
        let program = bin.join(harness);
        let report = self.wt.join(window);
        write_executable(
            &program,
            format!(
                r#"#!/bin/sh
{{
touch "$HOME/x-{window}" 2>/dev/null && echo home=written || echo home=refused
sh -c 'touch "$HOME/child-{window}"' 2>/dev/null && echo child=written || echo child=refused
touch '{wt}/y-{window}' && echo worktree=written || echo worktree=refused
tmux -S '{lanes}' display-message -p ok >/dev/null 2>&1 && echo tmux=reached || echo tmux=refused
tmux -S '{display}' display-message -p ok >/dev/null 2>&1 && echo display=reached || echo display=refused
[ -n "${{TMUX:-}}" ] && echo tmux_var=set || echo tmux_var=none
echo "wayland_var=${{WAYLAND_DISPLAY:-none}}"
echo "confined=${{AGENT_RUNTIME_CONFINED:-none}}"
}} > '{report}.tmp'
mv '{report}.tmp' '{report}'
"#,
                wt = self.wt.display(),
                lanes = self.lanes.display(),
                display = self.display.display(),
                report = report.display(),
            ),
        );
        let grants = serde_json::json!({
            "writable": [self.wt],
            "seats": [self.seat],
            "runtime_dir": self.rt,
            "desktop": desktop,
            "file": self.root.join(format!("grants-{window}.json")),
        });
        let intent = self.root.join(format!("intent-{window}.json"));
        std::fs::write(
            &intent,
            serde_json::json!({
                "harness": harness,
                "home": self.seat,
                "cwd": self.wt,
                "program": program,
                "grants": grants,
            })
            .to_string(),
        )
        .unwrap();
        let out = Command::new(binary())
            .args(["launch", "--intent"])
            .arg(&intent)
            .arg("--record")
            .arg(self.root.join(format!("record-{window}.json")))
            .arg("--socket")
            .arg(&self.lanes)
            .args(["--session", "lanes", "--window-name", window])
            .output()
            .unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!(
                "{window}: no reply: {e}\n{}",
                String::from_utf8_lossy(&out.stderr)
            )
        });
        assert_eq!(reply["ok"], true, "{window}: {reply}");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        while !report.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "{window}: no report; the line: {}",
                reply["result"]["command_line"]
            );
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let text = std::fs::read_to_string(&report).unwrap();
        let rows = text
            .lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect();
        (reply["result"].clone(), grants, rows)
    }
}

impl Drop for ConfinedWorld {
    fn drop(&mut self) {
        for socket in [&self.lanes, &self.display] {
            let _ = Command::new("tmux")
                .arg("-S")
                .arg(socket)
                .arg("kill-server")
                .output();
        }
    }
}

fn reported(rows: &[(&str, &str)]) -> std::collections::BTreeMap<String, String> {
    rows.iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

/// A worker launched with grants runs its harness under the wrapper: the
/// home refuses its write and its child's, the worktree takes one, the
/// lanes' tmux server and the display are out of reach, `TMUX` is cleared
/// and the display's name with it, and the grants file it is pointed at
/// holds its grants. The same launch with `desktop` keeps the display's
/// name and reaches its socket, and still no tmux server.
#[test]
#[cfg(target_os = "linux")]
fn a_confined_launch_refuses_home_child_tmux_and_display_and_a_desktop_grant_reaches_the_display() {
    let world = ConfinedWorld::new();
    let (record, grants, report) = world.launch("claude", "lane", false);
    assert_eq!(
        report,
        reported(&[
            ("home", "refused"),
            ("child", "refused"),
            ("worktree", "written"),
            ("tmux", "refused"),
            ("display", "refused"),
            ("tmux_var", "none"),
            ("wayland_var", "none"),
            ("confined", "1"),
        ]),
        "{}",
        record["command_line"]
    );
    assert!(!world.root.join("x-lane").exists() && !world.root.join("child-lane").exists());
    assert_eq!(
        record["confinement"],
        serde_json::json!({"state": "confined"})
    );
    let file = std::fs::read_to_string(world.root.join("grants-lane.json")).unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&file).unwrap(),
        grants
    );
    let (record, _, report) = world.launch("claude", "desk", true);
    assert_eq!(
        report,
        reported(&[
            ("home", "refused"),
            ("child", "refused"),
            ("worktree", "written"),
            ("tmux", "refused"),
            ("display", "reached"),
            ("tmux_var", "none"),
            ("wayland_var", "wayland-1"),
            ("confined", "1"),
        ]),
        "{}",
        record["command_line"]
    );
}

/// Copilot CLI's answer is unconfined: under the same grants its launch
/// runs the harness bare, which reaches what the operator reaches, and the
/// record names the cause.
#[test]
#[cfg(target_os = "linux")]
fn an_unconfined_harness_launches_bare_and_its_record_names_the_cause() {
    let world = ConfinedWorld::new();
    let (record, _, report) = world.launch("copilot", "copilot", false);
    assert_eq!(
        record["confinement"],
        serde_json::json!({"state": "unconfined", "cause": "token-on-session-bus"})
    );
    assert_eq!(
        report,
        reported(&[
            ("home", "written"),
            ("child", "written"),
            ("worktree", "written"),
            ("tmux", "reached"),
            ("display", "reached"),
            ("tmux_var", "set"),
            ("wayland_var", "none"),
            ("confined", "none"),
        ]),
        "{}",
        record["command_line"]
    );
}
