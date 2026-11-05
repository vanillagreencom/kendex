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

/// Pi 1.4.0's default composer at rest: the capture-pane output of the
/// native probe (`tests/native/thin-path.sh`) at rest once its turns ended.
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
        let server_pid = u64::from(server.pid);
        let server_start = server.start;
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
    let legacy = pane.record("codex", &home, &cwd, None);
    let result = inspect(&dir.path().join("legacy.json"), &legacy);
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
    use std::os::unix::fs::PermissionsExt;
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
    std::fs::write(&stub, script).unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
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

/// Defect: a delivery read as confirmed from the paste
/// alone, with no turn the harness itself recorded; a confirmation read
/// from a file the id does not name; a session with no id typed into. A
/// `--no-paste` read gives the idle state and the fixed file's turn count;
/// a paste into a stub that records the line is confirmed by that file; a
/// paste into one that records nothing is `unconfirmed` once the bound
/// passes; a session naming no id is a limit, nothing typed; a server the
/// socket does not answer for under the recorded pid is refused; a server
/// start left out matches the live server by its pid.
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
}

#[test]
#[cfg(unix)]
fn a_launch_whose_line_never_reached_its_window_closes_it_and_one_whose_paste_went_unanswered_keeps_its_record()
 {
    use std::os::unix::fs::PermissionsExt;
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
        let pane = PrivatePane::start(&root);
        let shims = root.join("refusing-tmux");
        std::fs::create_dir(&shims).unwrap();
        std::fs::write(
            shims.join("tmux"),
            format!(
                "#!/bin/bash\nfor arg in \"$@\"; do [ \"$arg\" != {verb} ] || {{ echo refused >&2; exit 1; }}; done\nexec '{}' \"$@\"\n",
                real.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(shims.join("tmux"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
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

/// Defect: a window left standing, holding only its shell, by a launch whose
/// record could not be written and whose close went unread, with a refusal
/// that names no window. Through the real binary on a private server, the
/// record path already holding a record, so the launch's write is refused
/// after its window opened: a close tmux answers leaves no window and the
/// write's own refusal; a `kill-window` tmux refuses leaves the window, and
/// the refusal names it.
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
        let pane = PrivatePane::start(&root);
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

/// Defect: a timed-out `new-window` read as a refusal, and a tmux refusal
/// read as no answer. Through the real binary on a private server, with a
/// `tmux` on `PATH` that answers one verb its own way: a `new-window` tmux
/// refuses is `tmux-refused`, no window opened; one that opens the window
/// and then gives no answer within the bound is `launch-window-unanswered`,
/// naming the session and the window, which stands.
#[test]
fn a_new_window_tmux_refused_is_refused_and_one_that_gave_no_answer_is_unanswered() {
    use std::os::unix::fs::PermissionsExt;
    let real = std::env::var_os("PATH")
        .and_then(|path| {
            std::env::split_paths(&path)
                .map(|d| d.join("tmux"))
                .find(|p| p.is_file())
        })
        .expect("tmux on PATH");
    // (what the shim does on new-window, the refusal, whether the window stands)
    for (answer, key, stands) in [
        ("echo refused >&2; exit 1", "tmux-refused", false),
        (
            "\"$real\" \"$@\" >/dev/null; exec sleep 30",
            "launch-window-unanswered",
            true,
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let pane = PrivatePane::start(&root);
        let shims = root.join("answering-tmux");
        std::fs::create_dir(&shims).unwrap();
        std::fs::write(
            shims.join("tmux"),
            format!(
                "#!/bin/bash\nreal='{}'\nfor arg in \"$@\"; do [ \"$arg\" != new-window ] || {{ {answer}; }}; done\nexec \"$real\" \"$@\"\n",
                real.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(shims.join("tmux"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
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

/// Defect: a socket under a made-up uid. With no `$TMUX`, no numeric
/// `$UID` and an `id` that fails, a launch that names no socket refuses
/// `uid-unread` before any tmux call.
#[test]
fn a_launch_whose_uid_cannot_be_read_refuses_and_names_no_socket() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let shims = root.join("failing-id");
    std::fs::create_dir(&shims).unwrap();
    std::fs::write(
        shims.join("id"),
        "#!/bin/bash\necho 'id: unread' >&2\nexit 1\n",
    )
    .unwrap();
    std::fs::set_permissions(shims.join("id"), std::fs::Permissions::from_mode(0o755)).unwrap();
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
