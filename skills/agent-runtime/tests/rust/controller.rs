//! The hand-over's verbs at the `agent-runtime` command line: each runs the
//! built binary over a controller record this harness writes, in a world of
//! its own that holds what lies behind every guard: a root no git walk
//! leaves, a tmux stand-in that answers no server, a mailbox program that
//! records each notice, and nothing set but what the row names.

use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

#[path = "isolation.rs"]
mod isolation;
use isolation::*;

const FLEET: &str = include_str!("fixtures/workflow-state-oversee.json");
/// The server the fixture's controller record names.
const FIXTURE_SOCKET: &str = "\"server_socket\": \"/tmp/tmux-1000/default\"";
const MAIL_PROGRAM: &str = ".agents/skills/mailbox/scripts/lane-mail";

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_agent-runtime"))
}

/// A row's world under a temporary root below git's ceiling: `bin/tmux`
/// logs every call to `tmux.log` and answers that no server runs, so the
/// code behind a removed guard asks no real server; `mail/lane-mail` logs
/// every notice to `mail.log`; `mail-root` and `tmux.sock` are the mailbox
/// root and the server the row's requests name. Dropping it waits for every
/// process whose command line names the root and kills what is left.
struct World {
    dir: tempfile::TempDir,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("bin")).unwrap();
        std::fs::create_dir_all(root.join("mail-root")).unwrap();
        write_executable(
            &root.join("bin/tmux"),
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\necho 'no server running on stand-in' >&2\nexit 1\n",
                root.join("tmux.log").display()
            ),
        );
        let world = World { dir };
        world.mailbox(&world.mail_program(), &world.root().join("mail.log"));
        world
    }

    fn root(&self) -> &Path {
        self.dir.path()
    }

    /// A mailbox program at `program` that appends each call to `log`.
    fn mailbox(&self, program: &Path, log: &Path) {
        std::fs::create_dir_all(program.parent().unwrap()).unwrap();
        write_executable(
            program,
            format!("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n", log.display()),
        );
    }

    fn mail_program(&self) -> PathBuf {
        self.root().join("mail/lane-mail")
    }

    fn socket(&self) -> PathBuf {
        self.root().join("tmux.sock")
    }

    /// The flags naming the world's mailbox and server.
    fn reach(&self) -> Vec<String> {
        vec![
            "--mail-program".to_owned(),
            self.mail_program().display().to_string(),
            "--mail-root".to_owned(),
            self.root().join("mail-root").display().to_string(),
            "--socket".to_owned(),
            self.socket().display().to_string(),
        ]
    }

    /// The fixture record at `path` with `fleet`'s text, its recorded server
    /// the world's.
    fn record(&self, path: &Path, fleet: &str) -> String {
        let text = fleet.replacen(
            FIXTURE_SOCKET,
            &format!("\"server_socket\": \"{}\"", self.socket().display()),
            1,
        );
        assert!(
            !text.contains("/tmp/tmux-"),
            "the record names a server outside the world"
        );
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, &text).unwrap();
        text
    }

    fn log(&self, name: &str) -> String {
        std::fs::read_to_string(self.root().join(name)).unwrap_or_default()
    }

    /// `agent-runtime controller <args>` in `cwd` under the isolated
    /// environment, the stand-in tmux first on `PATH`, tmux's default
    /// socket directory and the home inside the world, and the pairs the
    /// row names.
    fn controller(&self, cwd: &Path, args: &[String], pairs: &[(&str, &str)]) -> Output {
        let mut command = program(binary());
        command
            .arg("controller")
            .args(args)
            .current_dir(cwd)
            .env("PATH", tool_path(&[&self.root().join("bin")]))
            .env("TMUX_TMPDIR", self.root())
            .env("HOME", self.root());
        for (key, value) in pairs {
            command.env(key, value);
        }
        command.output().unwrap()
    }

    /// The processes other than this one whose command line names the root.
    fn naming(&self) -> Vec<u32> {
        let root = self.root().as_os_str().as_encoded_bytes().to_vec();
        let own = std::process::id();
        std::fs::read_dir("/proc")
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok()?.file_name().to_str()?.parse::<u32>().ok())
                    .filter(|pid| *pid != own && names(*pid, &root))
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// Whether `pid`'s command line holds `root`.
fn names(pid: u32, root: &[u8]) -> bool {
    std::fs::read(format!("/proc/{pid}/cmdline"))
        .is_ok_and(|line| line.windows(root.len()).any(|w| w == root))
}

impl Drop for World {
    fn drop(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !self.naming().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
        }
        let root = self.root().as_os_str().as_encoded_bytes().to_vec();
        for pid in self.naming() {
            // Signalled only while its command line still names the root,
            // so a reused pid is never touched.
            if names(pid, &root) {
                let _ = std::process::Command::new("kill")
                    .args(["-KILL", &pid.to_string()])
                    .output();
            }
        }
    }
}

/// The refusal's key and its fields as the reply carries them.
fn refusal(out: &Output) -> (String, Value) {
    assert_eq!(
        out.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["ok"], false);
    (
        reply["refusal"]["key"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        reply["refusal"]["fields"].clone(),
    )
}

fn field<'a>(fields: &'a Value, name: &str) -> Option<&'a str> {
    fields
        .as_array()?
        .iter()
        .find(|pair| pair[0] == name)
        .and_then(|pair| pair[1].as_str())
}

/// The fixture controller as the requester saw it.
fn expected() -> Value {
    json!({
        "server": "41020",
        "server_start": 1769590000,
        "pane": "%7",
        "generation": 3,
        "launch_line": "cd /home/u/dev/kendex && CLAUDE_CONFIG_DIR=/home/u/.claude-lanes/a1 claude --model claude-opus-5-5 --effort high",
        "cwd": "/home/u/dev/kendex",
    })
}

fn successor() -> Value {
    json!({
        "harness": "codex",
        "account": "/a/c2",
        "model": "gpt-5.5-codex",
        "cwd": "/r",
        "handoff": "tmp/handoffs/H.md",
    })
}

/// A transfer the hand-over admits: its predecessor read dead, its brief
/// and handoff named.
fn dead_transfer() -> Value {
    json!({"expected": expected(), "successor": successor(), "brief_file": "/r/brief.md", "cause": "dead"})
}

fn write(path: &Path, value: &Value) -> PathBuf {
    std::fs::write(path, serde_json::to_vec(value).unwrap()).unwrap();
    path.to_path_buf()
}

/// `words` as owned arguments with the record and, where named, the
/// request file.
fn args(words: &[&str], record: &Path, request: Option<&Path>) -> Vec<String> {
    let mut args: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
    args.extend(["--record".to_owned(), record.display().to_string()]);
    if let Some(path) = request {
        args.extend(["--request".to_owned(), path.display().to_string()]);
    }
    args
}

/// A request the hand-over refuses before any intent writes nothing: a
/// transfer under the switched-off succession, a start or a transfer that
/// names no brief, a transfer on a record another writer moved, a stop with
/// no controller recorded. Each refusal is keyed as the contract names it,
/// the record keeps its bytes, and no server is asked and no notice sent.
#[test]
fn a_request_the_hand_over_refuses_before_any_intent_writes_nothing() {
    let world = World::new();
    let record = world.root().join("workflow-state-oversee.json");
    let dead = |mut request: Value| {
        request["cause"] = json!("dead");
        request
    };
    let transfer =
        json!({"expected": expected(), "successor": successor(), "brief_file": "/r/brief.md"});
    let mut moved = expected();
    moved["pane"] = json!("%9");
    let no_overseer = FLEET.replacen("\"overseer\"", "\"overseer_was\"", 1);
    // (verb, record, request, settings, refusal key, a field it names)
    type Row<'a> = (
        &'a str,
        &'a str,
        Option<Value>,
        Vec<(&'a str, &'a str)>,
        &'a str,
        Option<(&'a str, &'a str)>,
    );
    let rows: Vec<Row> = vec![
        (
            "transfer",
            FLEET,
            Some(dead(transfer.clone())),
            vec![("AGENT_RUNTIME_CONTROLLER_SUCCESSION", "off")],
            "succession-off",
            None,
        ),
        (
            "transfer",
            FLEET,
            Some(dead(
                json!({"expected": expected(), "successor": successor()}),
            )),
            vec![],
            "brief-missing",
            Some(("field", "brief_file")),
        ),
        (
            "start",
            FLEET,
            Some(
                json!({"controller": {"harness": "codex", "cwd": "/r"}, "brief_file": "/r/brief.md"}),
            ),
            vec![],
            "brief-missing",
            Some(("field", "handoff")),
        ),
        (
            "transfer",
            FLEET,
            Some(dead(
                json!({"expected": moved, "successor": successor(), "brief_file": "/r/brief.md"}),
            )),
            vec![],
            "overseer-changed",
            Some(("fields", "pane")),
        ),
        ("stop", &no_overseer, None, vec![], "overseer-missing", None),
    ];
    for (verb, fleet, request, pairs, key, named) in rows {
        let text = world.record(&record, fleet);
        let request_path = request.map(|r| write(&world.root().join("request.json"), &r));
        let mut words = args(&[verb], &record, request_path.as_deref());
        words.extend(world.reach());
        let out = world.controller(world.root(), &words, &pairs);
        let (found, fields) = refusal(&out);
        assert_eq!(
            found,
            key,
            "{verb}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        if let Some((name, value)) = named {
            assert_eq!(field(&fields, name), Some(value), "{verb} {key}: {fields}");
        }
        assert_eq!(
            std::fs::read_to_string(&record).unwrap(),
            text,
            "{verb} {key}"
        );
    }
    assert_eq!(
        world.log("tmux.log"),
        "",
        "a refused request asks no server"
    );
    assert_eq!(
        world.log("mail.log"),
        "",
        "a refused request sends no notice"
    );
}

/// A request that names no mailbox, or no server where its record names
/// none, is refused before any intent, job or server: its key names what
/// is missing, the record keeps its bytes, no server is asked and no notice
/// sent. The detached job is held to the same, so a job started by hand
/// with nothing named reaches nothing either.
#[test]
fn a_request_naming_no_mailbox_or_server_is_refused_before_any_intent() {
    let world = World::new();
    let record = world.root().join("workflow-state-oversee.json");
    let request = write(&world.root().join("request.json"), &dead_transfer());
    let unbound = FLEET.replacen(FIXTURE_SOCKET, "\"server_socket\": null", 1);
    let reach = world.reach();
    let without = |flag: &str| -> Vec<String> {
        let at = reach.iter().position(|w| w == flag).unwrap();
        let mut words = reach.clone();
        words.drain(at..at + 2);
        words
    };
    // (verb, record text, request, reach flags, refusal key, field)
    type Row<'a> = (
        &'a str,
        &'a str,
        Option<&'a Path>,
        Vec<String>,
        &'a str,
        Option<&'a str>,
    );
    let rows: Vec<Row> = vec![
        (
            "transfer",
            FLEET,
            Some(&request),
            without("--mail-program"),
            "mailbox-unnamed",
            Some("mail_program"),
        ),
        (
            "transfer",
            FLEET,
            Some(&request),
            without("--mail-root"),
            "mailbox-unnamed",
            Some("mail_root"),
        ),
        (
            "stop",
            FLEET,
            None,
            vec![],
            "mailbox-unnamed",
            Some("mail_program"),
        ),
        (
            "transfer",
            &unbound,
            Some(&request),
            without("--socket"),
            "tmux-server-unnamed",
            None,
        ),
        (
            "reconcile",
            &unbound,
            None,
            without("--socket"),
            "tmux-server-unnamed",
            None,
        ),
    ];
    for (verb, fleet, request, flags, key, named) in rows {
        let text = world.record(&record, fleet);
        let mut words = args(&[verb], &record, request);
        words.extend(flags);
        let (found, fields) = refusal(&world.controller(world.root(), &words, &[]));
        assert_eq!(found, key, "{verb}: {fields}");
        assert_eq!(named, field(&fields, "field"), "{verb} {key}: {fields}");
        assert_eq!(std::fs::read_to_string(&record).unwrap(), text, "{verb}");
    }
    let mut job = args(&["job"], &record, None);
    job.extend([
        "--intent".to_owned(),
        "request-transfer:overseer:3:1-1".to_owned(),
    ]);
    let (found, fields) = refusal(&world.controller(world.root(), &job, &[]));
    assert_eq!(found, "mailbox-unnamed", "{fields}");
    assert_eq!(world.log("tmux.log"), "", "nothing named, no server asked");
    assert_eq!(world.log("mail.log"), "", "nothing named, no notice sent");
}

/// A job under a record that stands inside a checkout with a mailbox of its
/// own writes its owner notice only to the mailbox its request names, and
/// asks no server but the one named: the checkout the process stands in,
/// which the detached job inherits, is never where its notice goes.
#[test]
fn a_job_inside_a_checkout_notifies_only_the_mailbox_its_request_names() {
    let world = World::new();
    let checkout = world.root().join("checkout");
    std::fs::create_dir_all(&checkout).unwrap();
    let init = program("git")
        .args(["init", "-q"])
        .current_dir(&checkout)
        .output()
        .unwrap();
    assert!(init.status.success(), "{}", stderr(&init));
    world.mailbox(
        &checkout.join(MAIL_PROGRAM),
        &world.root().join("checkout-mail.log"),
    );
    let record = checkout.join("tmp/state/workflow-state-oversee.json");
    world.record(&record, FLEET);
    let request = write(&world.root().join("request.json"), &dead_transfer());
    let mut words = args(&["transfer"], &record, Some(&request));
    words.extend(world.reach());
    let out = world.controller(&checkout, &words, &[]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        reply["result"]["effect"]["started"], "transfer-started",
        "{reply}"
    );
    // The job's notice is its last act: read the record until the owed
    // notice is marked.
    let deadline = Instant::now() + Duration::from_secs(90);
    let intent = loop {
        let fleet: Value =
            serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
        let intent = fleet["intents"]
            .as_array()
            .and_then(|all| all.iter().find(|i| i["op"] == "request-transfer").cloned())
            .unwrap_or(Value::Null);
        let marked = intent["notice"]["owner"]
            .as_str()
            .is_some_and(|owner| owner != "owed");
        if marked {
            break intent;
        }
        assert!(
            Instant::now() < deadline,
            "the job never sent its notice: {intent}"
        );
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        world.log("checkout-mail.log"),
        "",
        "the checkout's own mailbox took a notice"
    );
    let notices = world.log("mail.log");
    let named_root = format!("--root {}", world.root().join("mail-root").display());
    assert!(
        notices.lines().count() == 1
            && notices.contains("notice ")
            && notices.contains(&named_root),
        "{notices}"
    );
    let named_server = format!("-S {} ", world.socket().display());
    let calls = world.log("tmux.log");
    assert!(
        calls.lines().all(|call| call.starts_with(&named_server)),
        "a server the request does not name was asked: {calls}"
    );
}

/// The identity read: the recorded controller, whether it still runs (its
/// recorded harness process), the recorded start and the open controller
/// intents; with the caller group, how the record stands to the caller's
/// pane (bound on the caller's server started at the recorded start,
/// unstarted on a record with no start, other, none with no controller),
/// whether the record's native identity admits the caller's session, and
/// the launch a model check is bound to. A record with no document refuses
/// `record-missing`; a server is asked only on the record's socket.
#[test]
fn controller_status_reads_the_record_and_how_it_stands_to_the_callers_pane() {
    let world = World::new();
    let record = world.root().join("workflow-state-oversee.json");
    let started = 1769590000_u64;
    let session = "0f3d2c1b-9a8e-4d7c-b6a5-443322110000";
    let home = "/home/u/.claude-lanes/a1";
    let child = Reaped(
        std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap(),
    );
    let child = &child.0;
    let stat = std::fs::read_to_string(format!("/proc/{}/stat", child.id())).unwrap();
    let ticks = stat
        .rsplit_once(')')
        .unwrap()
        .1
        .split_whitespace()
        .nth(19)
        .unwrap()
        .to_owned();
    let running = FLEET
        .replacen("\"41388\"", &format!("\"{}\"", child.id()), 1)
        .replacen("ticks:9912345", &format!("ticks:{ticks}"), 1);
    let unstarted = FLEET.replacen("\"server_start\": 1769590000", "\"server_start\": null", 1);
    let no_overseer = FLEET.replacen("\"overseer\"", "\"overseer_was\"", 1);
    // (record, the start the caller's server answers, caller pane, caller
    // session, live, binding, native_match)
    type Row<'a> = (&'a str, u64, &'a str, &'a str, bool, Option<&'a str>, bool);
    let rows: Vec<Row> = vec![
        (FLEET, started, "", "", false, None, false),
        (FLEET, started, "%7", session, false, Some("bound"), true),
        (
            FLEET,
            started + 9,
            "%7",
            session,
            false,
            Some("other"),
            true,
        ),
        (FLEET, started, "%8", session, false, Some("other"), true),
        (FLEET, started, "%7", "another", false, Some("bound"), false),
        (
            &unstarted,
            started,
            "%7",
            "",
            false,
            Some("unstarted"),
            false,
        ),
        (
            &no_overseer,
            started,
            "%7",
            session,
            false,
            Some("none"),
            true,
        ),
        (&running, started, "", "", true, None, false),
    ];
    for (fleet, answer, pane, caller_session, live, binding, native) in rows {
        world.record(&record, fleet);
        write_executable(
            &world.root().join("bin/tmux"),
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\ncase \"$*\" in *display-message*) echo '41020 {answer}' ;; *) exit 1 ;; esac\n",
                world.root().join("tmux.log").display()
            ),
        );
        let mut words = args(&["status"], &record, None);
        if !pane.is_empty() {
            words.extend(
                [
                    "--server",
                    "41020",
                    "--pane",
                    pane,
                    "--harness",
                    "claude",
                    "--home",
                    home,
                ]
                .map(str::to_owned),
            );
            words.extend(["--session".to_owned(), caller_session.to_owned()]);
        }
        let out = world.controller(world.root(), &words, &[]);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let result = serde_json::from_slice::<Value>(&out.stdout).unwrap()["result"].clone();
        let row = format!("{pane} {caller_session} {answer}: {result}");
        assert_eq!(result["live"], live, "{row}");
        assert_eq!(result["open_intents"], json!([]), "{row}");
        assert_eq!(result["binding"].as_str(), binding, "{row}");
        if fleet == no_overseer {
            assert_eq!(result["recorded"], Value::Null, "{row}");
            continue;
        }
        assert_eq!(result["recorded"]["generation"], 3, "{row}");
        assert_eq!(result["server_start"], world_start(fleet), "{row}");
        if binding.is_some() {
            assert_eq!(result["native_match"], native, "{row}");
            assert_eq!(result["model_launch"]["pane"], "%7", "{row}");
            assert_eq!(result["model_launch"]["generation"], 3, "{row}");
        }
    }
    let named_server = format!("-S {} ", world.socket().display());
    let calls = world.log("tmux.log");
    assert!(
        calls.lines().all(|call| call.starts_with(&named_server)),
        "a server the record does not name was asked: {calls}"
    );
    let (key, _) = refusal(&world.controller(
        world.root(),
        &args(&["status"], &world.root().join("absent.json"), None),
        &[],
    ));
    assert_eq!(key, "record-missing");
}

/// A child the row holds, ended and reaped when the row ends however it
/// ends.
struct Reaped(std::process::Child);

impl Drop for Reaped {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The recorded start a fixture text carries.
fn world_start(fleet: &str) -> Value {
    serde_json::from_str::<Value>(fleet).unwrap()["overseer"]["server_start"].clone()
}

/// The job a transfer or a stop runs in reads the request its launcher
/// wrote beside the record; an intent with none refuses before any claim
/// and the record keeps its bytes.
#[test]
fn a_job_with_no_request_written_for_its_intent_refuses_before_any_claim() {
    let world = World::new();
    let record = world.root().join("workflow-state-oversee.json");
    let text = world.record(&record, FLEET);
    let mut words = args(&["job"], &record, None);
    words.extend([
        "--intent".to_owned(),
        "request-transfer:overseer:3:1-1".to_owned(),
    ]);
    words.extend(world.reach());
    let (key, fields) = refusal(&world.controller(world.root(), &words, &[]));
    assert_eq!(key, "io-failed", "{fields}");
    assert_eq!(
        field(&fields, "operation"),
        Some("read-job-request"),
        "{fields}"
    );
    assert_eq!(std::fs::read_to_string(&record).unwrap(), text);
}

/// The handoff's one header writer: the snapshot leads with its one `Start
/// here:` line naming the record's controller generation, the body below it
/// as written; a body that already carries a header is refused and the
/// handoff is left as it stood.
#[test]
fn the_handoff_is_written_under_one_header_naming_the_records_generation() {
    let world = World::new();
    let record = world.root().join("workflow-state-oversee.json");
    world.record(&record, FLEET);
    let body = world.root().join("body.md");
    let handoff = world.root().join("handoffs/H.md");
    std::fs::write(&body, "## State\nall quiet\n").unwrap();
    let words = |body: &Path| {
        let mut words = args(&["handoff"], &record, None);
        words.extend([
            "--body".to_owned(),
            body.display().to_string(),
            "--handoff".to_owned(),
            handoff.display().to_string(),
        ]);
        words
    };
    let out = world.controller(world.root(), &words(&body), &[]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["result"]["generation"], 3);
    let written = std::fs::read_to_string(&handoff).unwrap();
    let headers: Vec<&str> = written
        .lines()
        .filter(|l| l.starts_with("Start here:"))
        .collect();
    assert_eq!(headers.len(), 1, "{written}");
    assert!(headers[0].ends_with(" generation=3"), "{written}");
    assert!(written.ends_with("## State\nall quiet\n"), "{written}");
    let headed = world.root().join("headed.md");
    std::fs::write(&headed, "Start here: 2026-01-01T00:00:00Z generation=2\n").unwrap();
    let (key, fields) = refusal(&world.controller(world.root(), &words(&headed), &[]));
    assert_eq!(key, "handoff-body-invalid");
    assert_eq!(field(&fields, "reason"), Some("header"), "{fields}");
    assert_eq!(std::fs::read_to_string(&handoff).unwrap(), written);
}

/// An adoption is made from the session's own pane: an adoption request
/// that names no server, and a registration of the caller's pane, run where
/// `$TMUX` is unset refuse `tmux-missing var=TMUX` before any server is
/// asked, the user's default socket included, and the record keeps its
/// bytes.
#[test]
fn an_adoption_or_registration_with_no_server_named_refuses_before_asking_any() {
    let world = World::new();
    let record = world.root().join("workflow-state-oversee.json");
    let text = world.record(&record, FLEET);
    let request = write(
        &world.root().join("adopt.json"),
        &json!({"pane": "%7", "harness": "claude"}),
    );
    let adopt = world.controller(
        world.root(),
        &args(&["adopt"], &record, Some(&request)),
        &[],
    );
    let register = world.controller(
        world.root(),
        &args(&["adopt"], &record, None),
        &[("TMUX_PANE", "%7")],
    );
    for (form, out) in [("adopt --request", adopt), ("adopt", register)] {
        let (key, fields) = refusal(&out);
        assert_eq!(key, "tmux-missing", "{form}: {fields}");
        assert_eq!(field(&fields, "var"), Some("TMUX"), "{form}: {fields}");
        assert_eq!(std::fs::read_to_string(&record).unwrap(), text, "{form}");
    }
    assert_eq!(
        world.log("tmux.log"),
        "",
        "an adoption with no server named asked one"
    );
}

/// The flag forms: `adopt --pane` reads the pane on the server `--socket`
/// names and on no other, and with neither `--socket` nor `$TMUX` refuses
/// `tmux-missing`; `successor --preference` walks the call's preference
/// over the setting's, so an empty one refuses `preference-empty` where the
/// setting is unset.
#[test]
fn the_flag_forms_reach_the_named_server_and_walk_the_called_preference() {
    let world = World::new();
    let record = world.root().join("workflow-state-oversee.json");
    let text = world.record(&record, FLEET);
    let mut pane = args(&["adopt"], &record, None);
    pane.extend(["--pane", "%7", "--harness", "claude"].map(str::to_owned));
    let (key, fields) = refusal(&world.controller(world.root(), &pane, &[]));
    assert_eq!(key, "tmux-missing", "{fields}");
    assert_eq!(world.log("tmux.log"), "", "no server named, none asked");
    pane.extend(["--socket".to_owned(), world.socket().display().to_string()]);
    let (key, fields) = refusal(&world.controller(world.root(), &pane, &[]));
    assert_eq!(key, "tmux-refused", "{fields}");
    let named_server = format!("-S {} ", world.socket().display());
    let calls = world.log("tmux.log");
    assert!(
        !calls.is_empty() && calls.lines().all(|call| call.starts_with(&named_server)),
        "{calls}"
    );
    assert_eq!(std::fs::read_to_string(&record).unwrap(), text);
    let mut successor = args(&["successor"], &record, None);
    successor.extend(
        [
            "--cwd",
            &world.root().display().to_string(),
            "--preference",
            "",
        ]
        .map(str::to_owned),
    );
    let (key, fields) = refusal(&world.controller(world.root(), &successor, &[]));
    assert_eq!(key, "preference-empty", "{fields}");
}
