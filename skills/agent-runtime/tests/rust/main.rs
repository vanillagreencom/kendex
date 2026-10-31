//! Process-protocol tests of the `agent-runtime` executable: they run the
//! built binary against fixtures this harness owns.

use std::path::PathBuf;
use std::process::Command;

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_agent-runtime"))
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

#[test]
fn judge_reads_a_screen_fixture_through_the_one_judge() {
    let dir = tempfile::tempdir().unwrap();
    let screen = dir.path().join("screen.txt");
    std::fs::write(&screen, "❯ do it\n✻ Churned for 6s · done\n❯\u{a0}\n").unwrap();
    let out = Command::new(binary())
        .args(["judge", "--harness", "claude", "--screen"])
        .arg(&screen)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["state"], "idle");
    let out = Command::new(binary())
        .args([
            "judge",
            "--harness",
            "claude",
            "--process",
            "shells-only",
            "--screen",
        ])
        .arg(&screen)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["state"], "exited");
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
        permission,
        question_tool: QuestionTool::Off,
        compaction: Compaction::Native,
        brief: Brief::None,
        resume: None,
        session_id: None,
        env: Default::default(),
        env_remove: Vec::new(),
        extra_args: Vec::new(),
        program: None,
    };
    let flag = "--dangerously-skip-permissions".to_owned();
    let bypass = build(&intent(Permission::Bypass)).unwrap();
    assert_eq!(bypass.args.iter().filter(|a| **a == flag).count(), 1);
    let native = build(&intent(Permission::Native)).unwrap();
    assert!(!native.args.contains(&flag));
}

/// Pi 1.4.0's default composer at rest: the capture-pane output of run 2's
/// probe after its first turn (`tmp/orch-rebuild/native/run2/pi/final-screen.txt`).
const PI_IDLE: &str = include_str!("fixtures/pi-idle.txt");
/// The same session while its first turn ran: the drawn lines the probe's
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

/// The three marker-drawing harnesses at rest, as the native probe's
/// `inspect` captured them after the first turn
/// (`tmp/orch-rebuild/native/run2/<harness>/inspect-idle.json`): each reads
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

#[test]
fn the_judge_verb_takes_the_harness_that_drew_the_screen() {
    let dir = tempfile::tempdir().unwrap();
    let screen = dir.path().join("pi.txt");
    std::fs::write(&screen, PI_IDLE).unwrap();
    let out = Command::new(binary())
        .args(["judge", "--harness", "pi", "--screen"])
        .arg(&screen)
        .output()
        .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["state"], "idle");
    let out = Command::new(binary())
        .args(["judge", "--harness", "nope", "--screen"])
        .arg(&screen)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let reply: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["refusal"]["key"], "harness-unknown");
}

/// The native probe reads a `process live` reply through
/// `tests/native/lib/reading.sh`, the same function thin-path.sh sources.
/// Fed the binary's own replies: a child this test holds reads `live`,
/// then `gone` once it exited and is still held unreaped; an unreadable
/// reading, in the binary's own serialization, carries its cause; a
/// refusal reply and an empty answer read `unread`. The `identity_start`
/// reader gives a live identity's start and nothing for a gone one.
#[test]
fn the_native_probe_reads_the_binary_s_own_process_replies_by_their_reading() {
    use agent_runtime::process::Identity;
    use agent_runtime::protocol::Reply;
    use agent_runtime::reading::Reading;
    use std::io::Write;
    use std::time::{Duration, Instant};

    let lib = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../tests/native/lib/reading.sh"
    );
    // The shell function over `input`, as the probe runs it.
    let through = |function: &str, input: &[u8]| -> String {
        let mut child = Command::new("bash")
            .args(["-c", &format!(". \"$1\" && {function}"), "_", lib])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{function}: {:?}", out.status);
        String::from_utf8(out.stdout).unwrap().trim_end().to_owned()
    };
    let reading = |input: &[u8]| -> serde_json::Value {
        serde_json::from_str(&through("process_reading", input)).unwrap()
    };
    let reply =
        |args: &[&str]| -> Vec<u8> { Command::new(binary()).args(args).output().unwrap().stdout };

    // A child this test holds, killed and reaped on drop whatever is asserted.
    struct Held(std::process::Child);
    impl Drop for Held {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let mut child = Held(Command::new("sleep").arg("30").spawn().unwrap());
    let pid = child.0.id().to_string();

    let identity = reply(&["process", "identity", &pid]);
    let start = through("identity_start", &identity);
    assert!(!start.is_empty(), "a live identity has a start");
    assert_eq!(
        reading(&reply(&["process", "live", &pid, &start])),
        serde_json::json!({"reading": "live", "cause": null})
    );

    child.0.kill().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let gone = loop {
        let now = reading(&reply(&["process", "live", &pid, &start]));
        if now["reading"] != "live" {
            break now;
        }
        assert!(Instant::now() < deadline, "the child never read gone");
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(gone, serde_json::json!({"reading": "gone", "cause": null}));
    assert_eq!(
        through("identity_start", &reply(&["process", "identity", &pid])),
        "",
        "a gone identity has no start"
    );

    let unreadable = serde_json::to_vec(&Reply::ok(Reading::<Identity>::Unreadable {
        cause: "ticks-unavailable",
    }))
    .unwrap();
    assert_eq!(
        reading(&unreadable),
        serde_json::json!({"reading": "unreadable", "cause": "ticks-unavailable"})
    );
    let refused = reply(&["inspect", "--record", "/nonexistent/record.json"]);
    assert_eq!(
        reading(&refused),
        serde_json::json!({"reading": "unread", "cause": null})
    );
    assert_eq!(
        reading(b""),
        serde_json::json!({"reading": "unread", "cause": null})
    );
}

/// A private tmux server on its own socket with one detached session, read
/// with no configuration file so the host's own reaches no row; ended on
/// drop. Its first pane is the one a planted launch record names.
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
        tmux_at(
            &socket,
            &[
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "probe",
                "-x",
                "80",
                "-y",
                "24",
                "-c",
                &dir.display().to_string(),
            ],
        );
        let text = tmux_at(
            &socket,
            &[
                "display-message",
                "-p",
                "#{pid}\t#{start_time}\t#{pane_id}\t#{window_id}\t#{session_name}",
            ],
        );
        let mut parts = text.trim_end().split('\t');
        let server_pid = parts.next().unwrap().parse().expect("server pid");
        let server_start = parts.next().unwrap().parse().expect("server start");
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
    /// own process: no shell echoes anything into the pane.
    fn run(&self, program: &std::path::Path) {
        self.tmux(&[
            "respawn-pane",
            "-k",
            "-t",
            &self.pane,
            &program.display().to_string(),
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
        use std::os::unix::fs::PermissionsExt;
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let stub = bin.join(name);
        std::fs::write(&stub, format!("#!/bin/bash\n{script}read -r _\n")).unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
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

/// Decision 108 (6) through `inspect`: a cold directory. The launch read an
/// empty baseline (`baseline: []`), and the one Codex lead that appeared for
/// the cwd after it binds; the same record written before the field, with
/// no baseline key, binds nothing, since nothing tells its session from a
/// neighbour's (decision 92).
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
    let legacy = pane.record("codex", &home, &cwd, None);
    let result = inspect(&dir.path().join("legacy.json"), &legacy);
    assert!(result["native_session"].is_null(), "{result}");
    assert!(result.get("native_session_unreadable").is_none());
}

/// Decision 115 (G), 120 L2: the Codex fixed-id lookup reads the store's
/// root three-valued through the listing. No root is an absent session; a
/// root this process cannot list is unreadable, never absent; a rollout
/// whose name ends in the id is present.
#[test]
#[cfg(unix)]
fn the_codex_fixed_id_lookup_reads_an_unlistable_store_as_unreadable() {
    use agent_runtime::Harness;
    use agent_runtime::reading::Reading;
    use agent_runtime::session::resume_present;
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let cwd = dir.path().join("work");
    std::fs::create_dir_all(&home).unwrap();
    let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
    assert_eq!(
        resume_present(Harness::Codex, &home, &cwd, id),
        Reading::Gone,
        "no sessions root is a cold home"
    );
    let day = home.join("sessions").join("2026").join("10").join("30");
    std::fs::create_dir_all(&day).unwrap();
    assert_eq!(
        resume_present(Harness::Codex, &home, &cwd, id),
        Reading::Gone,
        "a root with no rollout for the id is absent"
    );
    std::fs::write(day.join(format!("rollout-a-{id}.jsonl")), "{}\n").unwrap();
    assert_eq!(
        resume_present(Harness::Codex, &home, &cwd, id),
        Reading::Live(()),
        "the rollout named by the id is present"
    );
    let root = home.join("sessions");
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o000)).unwrap();
    let denied = matches!(
        std::fs::read_dir(&root),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied
    );
    let read = resume_present(Harness::Codex, &home, &cwd, id);
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

/// Decision 108 (8) through `inspect`: a Copilot session directory this
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
