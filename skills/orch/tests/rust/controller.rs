//! Live-effect process tests of the controller lifetimes (step4-map § A2 to
//! A8), each driven through the `orch-runtime` executable against a private
//! tmux server and a stub harness: a self-succession started from the
//! predecessor's own pane and completed by the detached job (decision 76),
//! the succession rows, death recovery with and without a recorded identity
//! (decision 77), the walled and off refusals and the explicit stop
//! (decision 78), the first launch and the adoption.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests hold owned children and a private tmux server and wait on real time for them"
)]

#[path = "support.rs"]
mod support;

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::*;

/// The bound a detached job's succession settles in.
const SETTLE: Duration = Duration::from_secs(40);

/// The fixture record on the test's own server at its real start, naming
/// `pane`, with the predecessor identity given or none recorded.
fn record_on(server: &Server, cwd: &Path, pane: &str, identity: Option<(u32, &str)>) -> Value {
    let mut record = overseer_record(0, "", server, cwd);
    record["server_start"] = json!(server.start);
    record["pane"] = json!(pane);
    match identity {
        Some((pid, start)) => {
            record["harness_pid"] = json!(pid.to_string());
            record["harness_start"] = json!(start);
        }
        None => {
            let record = record.as_object_mut().unwrap();
            record.remove("harness_pid");
            record.remove("harness_start");
        }
    }
    record
}

/// A transfer request under `cause` whose expected set is `record` with the
/// test's pending standing, and the same pending as successor.
fn request_for(record: &Value, cwd: &Path, cause: &str) -> Value {
    json!({
        "op": "request-transfer",
        "cause": cause,
        "expected": {
            "server": record["server"],
            "server_start": record["server_start"],
            "pane": record["pane"],
            "generation": record["generation"],
            "launch_line": record["launch_line"],
            "cwd": record["cwd"],
            "pending": pending(cwd),
        },
        "successor": pending(cwd),
    })
}

/// Write `record` as the overseer with the test's pending standing.
fn plant(runner: &Runner, record: Value) {
    let mut fleet = runner.fleet();
    fleet["overseer"] = record;
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    runner.write_fleet(&fleet);
}

/// Poll until `f` holds, bounded; `what` names the condition on failure.
fn wait_until(what: &str, bound: Duration, f: impl Fn() -> bool) {
    let deadline = Instant::now() + bound;
    while !f() {
        assert!(Instant::now() < deadline, "never: {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The reply a run inside a pane wrote to `path`, once it parses; `evidence`
/// is read into the failure when none comes.
fn wait_reply(path: &Path, bound: Duration, evidence: impl Fn() -> String) -> Value {
    let deadline = Instant::now() + bound;
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Ok(value) = serde_json::from_str::<Value>(&text)
            && value.get("ok").is_some()
        {
            return value;
        }
        assert!(
            Instant::now() < deadline,
            "no reply at {}: {:?}\n{}",
            path.display(),
            std::fs::read_to_string(path),
            evidence()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The refusal a run printed: the key after the program's name on its first
/// stderr line, `orch-runtime: <key> field=value...`.
fn refusal_key(out: &std::process::Output) -> String {
    let answer = reply(out);
    assert_eq!(answer["ok"], false, "{answer}");
    let line = stderr(out).lines().next().unwrap_or_default().to_owned();
    line.split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_owned()
}

/// Decision 76, step4-map F3: the overseer runs its succession from its own
/// pane. The predecessor here is a stub harness in a pane that runs the
/// `op` as a foreground child, as the overseer's shell tool runs
/// `oversee-succeed`. The op hands the effect to a detached job and answers
/// `transfer-started`; the job retires the predecessor, whose exit closes
/// the pane the op asked from, and completes the succession. The tmux shim
/// holds the job at each `send-keys`: the launch line typed into the
/// runner's window, released at once, and the brief typed after the
/// retirement, where the row reads the job alive with the predecessor dead
/// and its window gone, before the retirement is recorded.
#[test]
fn a_self_succession_from_the_predecessors_own_pane_completes() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let pane = server.open_stub(
        "overseer",
        "stub-succeed",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    let start = start_of(pid);
    let record = record_on(&server, runner.state_dir(), &pane, Some((pid, &start)));
    plant(&runner, record.clone());
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let mut request = request_for(&record, runner.state_dir(), "live");
    request["brief_file"] = json!(brief.display().to_string());
    let request_path = runner.state_dir().join("self.json");
    std::fs::write(&request_path, serde_json::to_vec(&request).unwrap()).unwrap();
    let out = runner.state_dir().join("op.out");
    let err = runner.state_dir().join("op.err");
    let fifo = runner.state_dir().join("hold.fifo");
    mkfifo(&fifo);
    let holddir = fixtures().join("tmux-hold");
    let mut words = runner.env_words();
    words.push(format!(
        "PATH={}:{}",
        holddir.display(),
        std::env::var("PATH").unwrap_or_default()
    ));
    words.push(format!("TMUX_REAL={}", which_tmux()));
    words.push(format!("TMUX_HOLD_FIFO={}", fifo.display()));
    words.push("TMUX_HOLD_VERB=send-keys".to_owned());
    // The command goes through a script: a line typed into a pane is cut at
    // the terminal's canonical line length, which the inherited PATH alone
    // can exceed.
    let script = runner.state_dir().join("self.sh");
    let quoted: Vec<String> = words.iter().map(|w| format!("'{w}'")).collect();
    std::fs::write(
        &script,
        format!(
            "exec env {} {} --no-private-env --state-dir {} op --fleet --request {} > {} 2> {}\n",
            quoted.join(" "),
            binary().display(),
            runner.state_dir().display(),
            request_path.display(),
            out.display(),
            err.display(),
        ),
    )
    .unwrap();
    server.send_line(&pane, &format!("RUN bash {}", script.display()));
    let evidence = || {
        format!(
            "op.err {:?}\nscreen {:?}\nfleet {}",
            std::fs::read_to_string(&err),
            String::from_utf8_lossy(
                &tmux(&server.socket, &["capture-pane", "-p", "-t", &pane]).stdout
            ),
            runner.fleet()
        )
    };
    // The first hold, the launch line into the runner's window: released
    // as soon as whatever runs the effect reaches it, within the bound every
    // other wait here has, so a route that never opens the window fails the
    // row with the phase it reached.
    release_hold(&fifo, Duration::from_secs(30), evidence);
    // The op answers at once, the effect handed to the job that now owns
    // the intent.
    let answer = wait_reply(&out, Duration::from_secs(30), evidence);
    assert_eq!(
        answer["ok"],
        true,
        "{answer}\n{}",
        std::fs::read_to_string(&err).unwrap_or_default()
    );
    let effect = &answer["result"]["effect"];
    assert_eq!(effect["started"], "transfer-started", "{effect}");
    let owner = effect["owner"].clone();
    let owner_pid = owner["pid"].as_u64().unwrap() as u32;
    assert_ne!(
        owner_pid,
        effect["handed_from"]["pid"].as_u64().unwrap() as u32,
        "the job, not the op, owns the intent"
    );
    assert!(
        effect["job"].as_str().unwrap().starts_with("runner="),
        "{effect}"
    );
    assert_eq!(runner.fleet()["intents"][0]["owner"], owner);
    assert_eq!(
        runner.fleet()["intents"][0]["handed_from"],
        effect["handed_from"]
    );
    // The job retires the predecessor: the stub harness ends and its exit
    // closes the pane the op asked from; the job, on its way to the brief
    // it will type, is alive after the process that asked is gone.
    wait_until("the predecessor stopped", Duration::from_secs(20), || {
        !live(pid)
    });
    assert!(
        live(owner_pid),
        "the job survived the predecessor's retirement"
    );
    assert_eq!(
        start_of(owner_pid),
        owner["start"],
        "under its recorded identity"
    );
    wait_until(
        "the predecessor's pane closed",
        Duration::from_secs(10),
        || !server.panes().contains(&pane),
    );
    assert!(live(owner_pid), "the job survived the pane's close");
    // The second hold, the brief: released, the job confirms the turn and
    // publishes.
    release_hold(&fifo, Duration::from_secs(30), evidence);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(intent["phase"]["phase"], "identity-read");
    assert_eq!(intent["observation"]["retired_by"], "identity");
    assert_eq!(intent["owner"], owner, "recorded by the job");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    let successor = overseer["pane"].as_str().unwrap().to_owned();
    assert_ne!(successor, pane);
    assert_eq!(overseer["harness_pid"], server.pane_pid(&successor));
    assert!(overseer["pending"].is_null());
    assert_eq!(
        runner.stub_turns(runner.state_dir(), runner.state_dir()),
        vec!["HANDOFF".to_owned()],
        "the brief reached the successor"
    );
    assert!(
        !live(effect["handed_from"]["pid"].as_u64().unwrap() as u32),
        "the op that asked is gone with its pane"
    );
}

/// Decision 76: a repeated request while the job runs reconciles against the
/// live owner and touches nothing (decision 72). Decision 61, R-U18 P12: a
/// runner that lost the pasted brief records no turn, so the job never
/// publishes it; the runner is kept for a reconcile, which reads the same.
#[test]
fn a_repeated_request_reads_the_job_as_owner_live_and_a_lost_brief_keeps_the_runner() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-mute");
    runner.verify = Some(3);
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    let started = runner.transfer_started(&request);
    // The repeat shares the file with the job's own writes: a write the job
    // made between the repeat's read and its store refuses it, and the
    // repeat asks again, as any contender does.
    let repeat = loop {
        let out = runner.op_fleet(&request);
        let answer = reply(&out);
        if answer["ok"] == true {
            break answer["result"]["effect"]["report"].clone();
        }
        assert_eq!(refusal_key(&out), "record-changed", "{}", stderr(&out));
    };
    assert_eq!(repeat["intent"]["outcome"], "unconfirmed", "{repeat}");
    assert_eq!(repeat["intent"]["observation"]["note"], "owner-live");
    assert_eq!(repeat["intent"]["owner"], started["owner"]);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["note"], "brief-unconfirmed");
    assert_eq!(intent["phase"]["phase"], "delivered");
    assert!(!live(predecessor.pid()), "retired before delivery");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 3, "nothing published");
    let kept = &overseer["pending"]["runner"];
    assert!(kept["pane"].as_str().unwrap().starts_with('%'));
    assert_eq!(kept["socket"], server.socket.display().to_string());
    assert!(
        kept["pid"].as_u64().is_some(),
        "the runner identity is kept"
    );
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
}

#[test]
fn a_succession_retires_the_predecessor_then_publishes_the_successor() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(predecessor.pid()), "the predecessor was retired");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    // The published record names the successor's own pane on the server,
    // with the tmux server start and socket, so its watch start keeps it.
    assert_eq!(overseer["server"], server.pid.to_string());
    assert_eq!(overseer["server_start"], server.start);
    assert_eq!(
        overseer["server_socket"],
        server.socket.display().to_string()
    );
    let pane = overseer["pane"].as_str().unwrap().to_owned();
    assert!(pane.starts_with('%'));
    // The successor's identity is the runner's own process, written as the
    // number the runtime writes (decision 63 reads the legacy string).
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert!(overseer["pending"].is_null(), "pending dropped on publish");
    // The intent recorded every phase on its way (decision 62).
    assert_eq!(intent["phase"]["phase"], "identity-read");
    assert_eq!(intent["phase"]["pid"], server.pane_pid(&pane));
    assert_eq!(intent["cause"], "live");
}

/// Decision 61, R-U18 high 2: the brief is delivered only after retirement
/// and the runner's composer, and the successor is published only once the
/// runner's own session file records that turn.
#[test]
fn a_succession_delivers_the_brief_after_retirement_and_publishes_on_the_runner_s_turn() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF line one\nHANDOFF line two\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(predecessor.pid()));
    let turns = runner.stub_turns(runner.state_dir(), runner.state_dir());
    assert_eq!(
        turns,
        vec!["HANDOFF line one".to_owned(), "HANDOFF line two".to_owned()],
        "the runner recorded the brief as its turns"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    assert_eq!(intent["phase"]["phase"], "identity-read");
}

/// Decision 61, R-U18 high 4: a precondition read before retirement refuses
/// `failed` with the predecessor in control and no runner left. The job
/// reads them, so its environment carries each row's setting.
#[test]
fn a_succession_whose_preconditions_fail_never_retires() {
    struct Row {
        name: &'static str,
        env: &'static [(&'static str, &'static str)],
        brief: Option<&'static str>,
        cwd: Option<&'static str>,
        note: &'static str,
    }
    let rows = [
        Row {
            name: "missing binary",
            env: &[("ORCH_HARNESS_BINARIES", "claude=/nonexistent/bin/claude")],
            brief: None,
            cwd: None,
            note: "harness-binary-missing",
        },
        Row {
            name: "unreadable brief",
            env: &[],
            brief: Some("/nonexistent/handoff.md"),
            cwd: None,
            note: "brief-unreadable",
        },
        Row {
            name: "missing directory",
            env: &[],
            brief: None,
            cwd: Some("/nonexistent/successor/dir"),
            note: "cwd-missing",
        },
        Row {
            name: "never-drawing successor",
            env: &[("ORCH_HARNESS_BINARIES", "claude=STUB_UNCONFIRMED")],
            brief: None,
            cwd: None,
            note: "successor-not-ready",
        },
    ];
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.verify = Some(1);
        runner.init_fleet();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let mut request = transfer_request(&server, runner.state_dir());
        if let Some(cwd) = row.cwd {
            let mut p = pending(runner.state_dir());
            p["cwd"] = json!(cwd);
            let mut fleet = runner.fleet();
            fleet["overseer"]["pending"] = p.clone();
            runner.write_fleet(&fleet);
            request["expected"]["pending"] = p.clone();
            request["successor"] = p;
        }
        if let Some(brief) = row.brief {
            request["brief_file"] = json!(brief);
        }
        let unconfirmed = stub("stub-unconfirmed").display().to_string();
        let env: Vec<(&str, String)> = row
            .env
            .iter()
            .map(|(k, v)| (*k, v.replace("STUB_UNCONFIRMED", &unconfirmed).to_owned()))
            .collect();
        let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (*k, v.as_str())).collect();
        runner.transfer_started_env(&request, &env);
        let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
        assert_eq!(intent["outcome"], "failed", "{}: {intent}", row.name);
        assert_eq!(intent["observation"]["note"], row.note, "{}", row.name);
        assert_eq!(intent["observation"]["retired"], false, "{}", row.name);
        assert!(
            live(predecessor.pid()),
            "{}: the predecessor still runs",
            row.name
        );
        assert_eq!(
            server.panes().len(),
            1,
            "{}: no runner window is left",
            row.name
        );
        assert_eq!(runner.fleet()["overseer"]["generation"], 3, "{}", row.name);
    }
}

/// Decision 120 (2), (3): the predecessor's handles join the intent's set
/// at the start of its retirement, before the first signal, so a retirement
/// that does not end it cannot fail the succession out from under them. A
/// recorded start that is not the live process's reads stale: nothing is
/// signalled, the waiting runner is stopped, and the intent holds
/// `predecessor-not-retired` with the recorded identity standing on one
/// stale reading. The reconcile's second independent reading settles that
/// identity (decision 68), and the succession, its runner gone, fails after
/// retirement; the live process under the reused pid is never signalled.
#[test]
fn a_succession_that_cannot_retire_the_predecessor_holds_it_and_signals_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    // A recorded start that is not the live process's: the stop reads the
    // identity as stale and never signals it.
    plant_transfer(&runner, &server, predecessor.pid(), "ticks:1");
    runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["note"], "predecessor-not-retired");
    assert_eq!(intent["observation"]["retired"], false);
    assert_eq!(
        remaining(&intent["observation"], "process")["pid"],
        predecessor.pid(),
        "the predecessor's recorded identity stands, acquired at the start of retirement: {intent}"
    );
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
    assert!(
        live(predecessor.pid()),
        "the live process was never signalled"
    );
    // The runner opened at its composer was stopped: the only pane is the
    // server's own.
    assert_eq!(server.panes().len(), 1);
    // The second independent reading settles the stale identity (decision
    // 68): the recorded controller is gone, and with the runner gone too the
    // succession fails after retirement, the live process still untouched.
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "successor-exited");
    assert_eq!(report["intent"]["observation"]["retired"], true);
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
    assert!(live(predecessor.pid()), "still never signalled");
}

/// Decision 65, R-U19 probe A: a neighbouring lead session in the same home
/// and directory takes turns throughout; they never confirm the runner's
/// delivery, which is read in the runner's own file alone.
#[test]
fn a_neighbour_session_s_turns_never_confirm_the_runner_s_delivery() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-mute");
    runner.verify = Some(2);
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let neighbour = Neighbour::writing(runner.state_dir(), runner.state_dir(), 0, "user");
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["note"], "brief-unconfirmed");
    assert!(
        neighbour.user_turns() >= 2,
        "the neighbour took user rows while the succession waited"
    );
    // The bound file is the runner's own, named by the id the launch fixed,
    // with no turn before the paste.
    let phase = &intent["phase"];
    assert_eq!(phase["phase"], "delivered");
    let session_id = phase["session_id"].as_str().expect("the fixed session id");
    assert_eq!(phase["session"]["session_id"], session_id);
    let file = phase["session"]["file"].as_str().unwrap();
    assert_eq!(
        Path::new(file),
        project_dir(runner.state_dir(), runner.state_dir()).join(format!("{session_id}.jsonl"))
    );
    assert_eq!(phase["turns_before"], 0);
    assert!(!live(predecessor.pid()), "retired before delivery");
    assert_eq!(
        runner.fleet()["overseer"]["generation"],
        3,
        "nothing published"
    );
    assert!(runner.fleet()["overseer"]["pending"]["runner"].is_object());
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
}

/// Decision 65, R-U19 probe B: a neighbouring lead session holding more
/// turns than the runner is kept the newest file by replies; the runner's
/// recorded turn in its own file still publishes the succession.
#[test]
fn a_neighbour_holding_more_turns_never_hides_the_runner_s_recorded_turn() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let neighbour = Neighbour::writing(runner.state_dir(), runner.state_dir(), 3, "assistant");
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(intent["phase"]["phase"], "identity-read");
    let session_id = intent["phase"]["session_id"]
        .as_str()
        .expect("the fixed session id");
    let own =
        project_dir(runner.state_dir(), runner.state_dir()).join(format!("{session_id}.jsonl"));
    assert_eq!(file_turns(&own), vec!["HANDOFF".to_owned()]);
    assert_eq!(
        neighbour.user_turns(),
        3,
        "the neighbour's turns are its own"
    );
    assert!(neighbour.rows() > 3, "the neighbour was written throughout");
    assert_eq!(runner.fleet()["overseer"]["generation"], 4);
}

/// Decision 77: a dead-cause recovery of a predecessor with no recorded
/// identity. The generation-bound exit record proves it terminal whatever
/// the pane shows; so does the recorded pane gone on the proven server. A
/// pane standing on that server is an unknown stop, refused before anything
/// opens; absence on a server that is not the recorded one proves nothing.
/// The successor's readiness is gated on the stub's acknowledgement, the
/// shim answering the job's first pane-field read of the pane it opened
/// only once the stub holds it, and the runner's verification bound is the
/// production default (decision 124i (34)): the retirement judgement is
/// what each row proves, not the stub's startup under load.
#[test]
fn a_dead_predecessor_with_no_identity_is_proven_terminal_by_the_exit_record_or_its_pane_alone() {
    struct Row {
        name: &'static str,
        /// What the record names, on a fresh server: the pane and an exit
        /// record, or an unproven server.
        plant: fn(&Server, &Runner) -> Value,
        outcome: &'static str,
        note: &'static str,
        retired_by: Option<&'static str>,
        cause: Option<&'static str>,
    }
    let rows = [
        Row {
            name: "exit record at the generation, pane standing",
            plant: |server, runner| {
                let standing = server.open_idle("overseer", runner.state_dir());
                let mut record = record_on(server, runner.state_dir(), &standing, None);
                record["exit"] = json!({
                    "status": 0,
                    "at": "2026-10-26T10:00:00Z",
                    "run": {"generation": 3, "pane": standing},
                });
                record
            },
            outcome: "confirmed",
            note: "successor-confirmed",
            retired_by: Some("exit-record"),
            cause: None,
        },
        Row {
            name: "exit record of an earlier generation, pane gone",
            plant: |server, runner| {
                let mut record = record_on(server, runner.state_dir(), "%99", None);
                record["exit"] = json!({"status": 0, "run": {"generation": 2}});
                record
            },
            outcome: "confirmed",
            note: "successor-confirmed",
            retired_by: Some("pane-gone"),
            cause: None,
        },
        Row {
            name: "pane standing on the proven server",
            plant: |server, runner| {
                let standing = server.open_idle("overseer", runner.state_dir());
                record_on(server, runner.state_dir(), &standing, None)
            },
            outcome: "failed",
            note: "predecessor-identity-missing",
            retired_by: None,
            cause: None,
        },
        Row {
            name: "unproven server: its socket gone with its process",
            plant: |server, runner| {
                let mut record = record_on(server, runner.state_dir(), "%99", None);
                record["server"] = json!(GONE_PID.to_string());
                record["server_start"] = json!(1);
                record["server_socket"] = json!(
                    runner
                        .state_dir()
                        .join("no-such.sock")
                        .display()
                        .to_string()
                );
                record
            },
            outcome: "failed",
            note: "predecessor-unproven",
            retired_by: None,
            cause: Some("server-gone"),
        },
    ];
    let real_tmux = which_tmux();
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.verify = None;
        runner.tools = Some(fixtures().join("tmux-hold"));
        let opened = runner.state_dir().join("hold.opened");
        runner.env.extend([
            ("TMUX_REAL".to_owned(), real_tmux.clone()),
            ("TMUX_HOLD_OPENED".to_owned(), opened.display().to_string()),
            ("TMUX_HOLD_READY_COMM".to_owned(), "claude".to_owned()),
        ]);
        runner.init_fleet();
        let record = (row.plant)(&server, &runner);
        plant(&runner, record.clone());
        let panes_before = server.panes().len();
        runner.transfer_started(&request_for(&record, runner.state_dir(), "dead"));
        let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
        assert_eq!(intent["outcome"], row.outcome, "{}: {intent}", row.name);
        assert_eq!(intent["observation"]["note"], row.note, "{}", row.name);
        assert_eq!(intent["cause"], "dead", "{}", row.name);
        let overseer = runner.fleet()["overseer"].clone();
        match row.retired_by {
            Some(by) => {
                assert_eq!(intent["observation"]["retired_by"], by, "{}", row.name);
                assert_eq!(overseer["generation"], 4, "{}", row.name);
                assert!(overseer.get("exit").is_none(), "{}: exit dropped", row.name);
            }
            None => {
                assert_eq!(intent["observation"]["retired"], false, "{}", row.name);
                assert_eq!(overseer["generation"], 3, "{}", row.name);
                assert_eq!(
                    server.panes().len(),
                    panes_before,
                    "{}: nothing opened",
                    row.name
                );
                assert_eq!(
                    overseer["pending"],
                    pending(runner.state_dir()),
                    "{}: the held line stands",
                    row.name
                );
            }
        }
        if let Some(cause) = row.cause {
            assert_eq!(intent["observation"]["cause"], cause, "{}", row.name);
        }
    }
}

/// Step4-map A6: a walled succession names the spent account, and a
/// successor resolving to it refuses before any intent persists; one on
/// another account runs.
#[test]
fn a_walled_succession_refuses_a_successor_on_the_spent_account() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let before =
        std::fs::read_to_string(runner.state_dir().join("workflow-state-oversee.json")).unwrap();
    let mut request = transfer_request(&server, runner.state_dir());
    request["cause"] = json!("walled");
    // The successor's account is the state dir; spelled with a trailing
    // slash it is still the same directory.
    request["exclude_account"] = json!(format!("{}/", runner.state_dir().display()));
    let out = runner.op_fleet(&request);
    assert_eq!(refusal_key(&out), "successor-account-spent");
    assert_eq!(
        std::fs::read_to_string(runner.state_dir().join("workflow-state-oversee.json")).unwrap(),
        before,
        "nothing written"
    );
    assert!(live(predecessor.pid()));
    let elsewhere = dir.path().join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    request["exclude_account"] = json!(elsewhere.display().to_string());
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(intent["cause"], "walled");
    assert_eq!(runner.fleet()["overseer"]["generation"], 4);
}

/// Decision 78: `ORCH_OVERSEER_SUCCESSION=off` refuses a transfer before
/// any transition, so the record and the intents directory are as they
/// were; a stop under the same setting is admitted.
#[test]
fn succession_off_refuses_a_transfer_and_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let path = runner.state_dir().join("workflow-state-oversee.json");
    let before = std::fs::read_to_string(&path).unwrap();
    let out = runner.op_fleet_env(
        &transfer_request(&server, runner.state_dir()),
        &[("ORCH_OVERSEER_SUCCESSION", "off")],
    );
    assert_eq!(refusal_key(&out), "succession-off");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
    assert!(
        !runner.state_dir().join("intents").exists(),
        "no job request was written"
    );
    assert!(live(predecessor.pid()));
    let started = reply(&runner.op_fleet_env(
        &json!({"op": "stop-controller"}),
        &[("ORCH_OVERSEER_SUCCESSION", "off")],
    ));
    assert_eq!(
        started["result"]["effect"]["started"], "stop-started",
        "{started}"
    );
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(predecessor.pid()));
}

/// Decision 111 (5), R-U4a6b C1 (4): once the job launcher has been asked,
/// the job is an obligation until it claims or is read ended. A launcher
/// that wrote its record and then failed without saying nothing started
/// leaves the transfer `unconfirmed` with the job standing and its request
/// file kept for it; the reconcile reads the record, finds no claim and
/// keeps it standing, never `failed` over a job that may still run. The
/// launcher's own statement that nothing started (`status=`, a `setsid`
/// that forked nothing) is honoured: `failed`, the pending restored, the
/// request removed.
#[test]
fn a_job_the_launcher_did_not_answer_for_stands_until_read_and_the_reconcile_reads_it() {
    let job_unit = fixtures().join("job-unit-fail/job-unit");
    let job_unit = job_unit.display().to_string();
    for (line, outcome) in [
        ("job-unit: launch-failed detail=no-answer", "unconfirmed"),
        ("job-unit: launch-failed status=1", "failed"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let out = runner.op_fleet_env(
            &transfer_request(&server, runner.state_dir()),
            &[("ORCH_JOB_UNIT", &job_unit), ("JOB_UNIT_FAIL_LINE", line)],
        );
        assert_eq!(
            refusal_key(&out),
            "job-launch-failed",
            "{line}: {}",
            stderr(&out)
        );
        let fleet = runner.fleet();
        let intent = &fleet["intents"][0];
        assert_eq!(intent["outcome"], outcome, "{line}: {intent}");
        assert_eq!(intent["observation"]["note"], "job-launch-failed", "{line}");
        let id = intent["id"].as_str().unwrap().to_owned();
        let request = runner
            .state_dir()
            .join("intents")
            .join(format!("{id}.request"));
        if outcome == "failed" {
            assert!(intent["completed_at"].is_string(), "{line}: {intent}");
            assert!(
                intent["observation"].get("job").is_none(),
                "{line}: nothing started, nothing stands: {intent}"
            );
            assert!(!request.exists(), "{line}: the request is removed");
            assert!(live(predecessor.pid()), "{line}: the predecessor stands");
            continue;
        }
        assert!(intent["completed_at"].is_null(), "{line}: {intent}");
        assert_eq!(intent["observation"]["job"], "possibly-started", "{line}");
        assert_eq!(
            remaining(&intent["observation"], "job")["job"],
            "possibly-started",
            "{line}: the launcher's record names no identity yet, so the job stands unread: {intent}"
        );
        assert!(request.exists(), "{line}: the request is kept for the job");
        assert_eq!(
            fleet["overseer"]["pending"],
            pending(runner.state_dir()),
            "{line}: the pending stands as requested while the job may run"
        );
        // The reconcile reads the record: no claim, a job that names no
        // identity to read, so it stands; nothing is assumed absent.
        let report = runner.reconcile_one();
        assert_eq!(
            report["intent"]["outcome"], "unconfirmed",
            "{line}: {report}"
        );
        assert_eq!(report["intent"]["observation"]["note"], "nothing-opened");
        assert_eq!(report["intent"]["observation"]["job"], "possibly-started");
        assert_eq!(
            remaining(&report["intent"]["observation"], "job")["job"],
            "possibly-started",
            "{line}: the reconcile reads the unread record and the job stands: {report}"
        );
        assert!(request.exists(), "{line}: the request is still kept");
        assert!(
            runner.fleet()["intents"][0]["completed_at"].is_null(),
            "{line}: the intent stays open for the job's claim"
        );
        assert!(live(predecessor.pid()), "{line}: the predecessor stands");
    }
}

/// Decision 115 (B): a `setsid` job that recorded its own identity and exited
/// before claiming is read gone at the reconcile by that identity and
/// discharged, so the intent reconciles to `failed` rather than standing
/// forever; the predecessor it never retired stands.
#[test]
fn an_unclaimed_setsid_job_that_exits_before_claiming_reconciles() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let job_unit = fixtures().join("job-unit-fail/job-unit");
    let job_unit = job_unit.display().to_string();
    let dead = (GONE_PID as u32).to_string();
    let out = runner.op_fleet_env(
        &transfer_request(&server, runner.state_dir()),
        &[
            ("ORCH_JOB_UNIT", &job_unit),
            ("JOB_UNIT_FAIL_PID", &dead),
            ("JOB_UNIT_FAIL_START", "ticks:1"),
        ],
    );
    assert_eq!(refusal_key(&out), "job-launch-failed", "{}", stderr(&out));
    let fleet = runner.fleet();
    let intent = &fleet["intents"][0];
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["job"], "possibly-started");
    assert_eq!(
        remaining(&intent["observation"], "job")["pid"],
        GONE_PID,
        "the recorded setsid group stands by its own pid: {intent}"
    );
    // The reconcile reads that group identity gone and discharges the job,
    // so the intent fails rather than standing forever.
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["job"], "ended");
    assert!(
        remaining(&report["intent"]["observation"], "job").is_null(),
        "the exited job is discharged: {report}"
    );
    assert!(live(predecessor.pid()), "nothing retired the predecessor");
}

/// Decision 115 (B): one outstanding-job predicate serves both routes, so a
/// repeated stop whose job never claimed reconciles that job rather than
/// starting a second; the launcher is asked once.
#[test]
fn a_repeated_stop_with_an_unclaimed_job_does_not_start_a_second_job() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let job_unit = fixtures().join("job-unit-fail/job-unit");
    let job_unit = job_unit.display().to_string();
    let log = runner.state_dir().join("job-unit.log");
    let log_s = log.display().to_string();
    let env = [
        ("ORCH_JOB_UNIT", job_unit.as_str()),
        ("JOB_UNIT_LOG", log_s.as_str()),
        (
            "JOB_UNIT_FAIL_LINE",
            "job-unit: launch-failed detail=no-answer",
        ),
    ];
    // The launcher is asked and does not answer for the job: the unread
    // sidecar stands, the stop intent open.
    let out = runner.op_fleet_env(&json!({"op": "stop-controller"}), &env);
    assert_eq!(refusal_key(&out), "job-launch-failed", "{}", stderr(&out));
    assert_eq!(
        runner.fleet()["intents"][0]["observation"]["job"],
        "possibly-started"
    );
    // The repeated stop reconciles the standing job and starts no second one.
    let out2 = runner.op_fleet_env(&json!({"op": "stop-controller"}), &env);
    let report = effect_report(&out2);
    assert_eq!(
        report["intent"]["observation"]["job"], "possibly-started",
        "{report}"
    );
    let calls = std::fs::read_to_string(&log)
        .unwrap()
        .lines()
        .filter(|l| l.starts_with("launch "))
        .count();
    assert_eq!(calls, 1, "the launcher was asked once, no second job");
    assert!(live(predecessor.pid()), "nothing retired the predecessor");
}

/// Decision 78: the explicit stop retires the controller exactly by its
/// identity and records `off`; a death recovery then refuses
/// `controller-off`; the one way back is `start-controller`, whose
/// confirmation clears the mark.
#[test]
fn stop_controller_retires_exactly_and_records_off_which_death_recovery_honours() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    let bystander = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    // The stop runs as a detached job (decision 109 (3)): the reply is its
    // start, the outcome is read off the intent once the job recorded it.
    let started = runner.op_fleet(&json!({"op": "stop-controller"}));
    assert_eq!(
        reply(&started)["result"]["effect"]["started"],
        "stop-started",
        "{}",
        stderr(&started)
    );
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(intent["observation"]["retired_by"], "identity");
    assert!(!live(predecessor.pid()), "the recorded identity ended");
    assert!(live(bystander.pid()), "nothing else was signalled");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["off"]["generation"], 3);
    assert!(overseer["off"]["at"].is_string());
    assert_eq!(overseer["generation"], 3);
    // Death recovery never relaunches an off controller.
    let mut dead = transfer_request(&server, runner.state_dir());
    dead["cause"] = json!("dead");
    let out = runner.op_fleet(&dead);
    assert_eq!(refusal_key(&out), "controller-off");
    assert_eq!(runner.fleet()["overseer"], overseer, "nothing written");
    // An explicit start opens a controller again and clears the mark.
    let report = effect_report(&runner.op_fleet(&json!({
        "op": "start-controller",
        "controller": pending(runner.state_dir()),
    })));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["generation"], 4);
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    assert!(overseer.get("off").is_none(), "{overseer}");
    let pane = overseer["pane"].as_str().unwrap().to_owned();
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
}

/// Decision 78 with no identity recorded: decision 77's proof confirms the
/// stop (the pane gone on the proven server) and `off` is recorded; a pane
/// standing with nothing naming what runs in it fails the stop, since an
/// exact retirement has nothing to act on, and records nothing.
#[test]
fn stop_controller_without_an_identity_takes_the_proof_or_fails() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    plant(&runner, record_on(&server, runner.state_dir(), "%99", None));
    runner.op_fleet(&json!({"op": "stop-controller"}));
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(intent["observation"]["retired_by"], "pane-gone");
    assert_eq!(runner.fleet()["overseer"]["off"]["generation"], 3);

    let standing = server.open_idle("overseer", runner.state_dir());
    let mut fleet = runner.fleet();
    fleet["intents"] = json!([]);
    runner.write_fleet(&fleet);
    plant(
        &runner,
        record_on(&server, runner.state_dir(), &standing, None),
    );
    runner.op_fleet(&json!({"op": "stop-controller"}));
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "identity-missing");
    assert!(runner.fleet()["overseer"].get("off").is_none());
    assert!(
        server.panes().contains(&standing),
        "the pane was not touched"
    );
}

/// Step4-map A2: the first launch of a controller on a fleet that recorded
/// none publishes generation 1 with the runner's identity; a start over a
/// controller whose identity reads live fails `overseer-live` before
/// anything opens.
#[test]
fn start_controller_opens_the_first_controller_and_refuses_over_a_live_one() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    assert!(runner.fleet().get("overseer").is_none());
    let brief = runner.state_dir().join("brief.md");
    std::fs::write(&brief, "START HERE\n").unwrap();
    let report = effect_report(&runner.op_fleet(&json!({
        "op": "start-controller",
        "controller": pending(runner.state_dir()),
        "brief_file": brief.display().to_string(),
    })));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(report["generation"], 1);
    assert_eq!(
        report["intent"]["observation"]["retired_by"], "record-empty",
        "a bare fleet's record names no session (decision 109 (1))"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 1);
    assert_eq!(overseer["harness"], "claude");
    assert_eq!(overseer["server"], server.pid.to_string());
    let pane = overseer["pane"].as_str().unwrap().to_owned();
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert_eq!(overseer["launch_line"], "cd /r && claude --model opus");
    assert_eq!(
        runner.stub_turns(runner.state_dir(), runner.state_dir()),
        vec!["START HERE".to_owned()],
        "the brief was delivered"
    );
    // Over a live controller: nothing opens, the record stands.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let live_controller = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(
        live_controller.pid(),
        &live_controller.start(),
        &server,
        runner.state_dir(),
    );
    runner.write_fleet(&fleet);
    let before = runner.fleet()["overseer"].clone();
    let report = effect_report(&runner.op_fleet(&json!({
        "op": "start-controller",
        "controller": pending(runner.state_dir()),
    })));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "overseer-live");
    assert_eq!(report["intent"]["observation"]["retired"], false);
    assert_eq!(
        runner.fleet()["overseer"],
        before,
        "the pending is gone again"
    );
    assert_eq!(server.panes().len(), 1, "nothing opened");
    assert!(live(live_controller.pid()));
}

/// Step4-map A3: an adoption records the harness identity read in the
/// pane's foreground, never the caller's word; a record of another, live
/// controller refuses `overseer-live`; a pane holding no harness refuses
/// `pane-not-harness`; the same pane adopted again is healed in place.
#[test]
fn adopt_controller_binds_the_harness_read_in_the_pane_and_refuses_a_live_record_or_a_shell() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let pane = server.open_stub(
        "overseer",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let request = json!({
        "op": "adopt-controller",
        "pane": pane,
        "harness": "claude",
        "session_id": "by-hand-1",
        "account": runner.state_dir().display().to_string(),
        "cwd": runner.state_dir().display().to_string(),
    });
    let answer = reply(&runner.op_fleet(&request));
    assert_eq!(answer["ok"], true, "{answer}");
    let report = &answer["result"]["report"];
    assert_eq!(report["op"], "adopt-controller");
    assert_eq!(report["generation"], 1);
    assert_eq!(report["healed"], false);
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["pane"], pane);
    assert_eq!(overseer["server"], server.pid.to_string());
    assert_eq!(overseer["server_start"], server.start);
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert_eq!(overseer["harness_start"], start_of(server.pane_pid(&pane)));
    assert_eq!(overseer["session_id"], "by-hand-1");
    assert!(overseer["window"].as_str().unwrap().starts_with('@'));
    // The same pane again: healed, the generation kept.
    let answer = reply(&runner.op_fleet(&request));
    assert_eq!(answer["result"]["report"]["healed"], true, "{answer}");
    assert_eq!(runner.fleet()["overseer"]["generation"], 1);
    // A pane whose foreground is no harness.
    let idle = server.open_idle("other", runner.state_dir());
    let mut shell = request.clone();
    shell["pane"] = json!(idle);
    assert_eq!(refusal_key(&runner.op_fleet(&shell)), "pane-not-harness");
    // Another, live controller recorded: a second one is refused.
    let live_controller = Owned::sleep();
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(
        live_controller.pid(),
        &live_controller.start(),
        &server,
        runner.state_dir(),
    );
    runner.write_fleet(&fleet);
    assert_eq!(refusal_key(&runner.op_fleet(&request)), "overseer-live");
    assert_eq!(runner.fleet()["overseer"]["pane"], "%99", "nothing written");
    // That controller gone: adopted at the next generation.
    drop(live_controller);
    let answer = reply(&runner.op_fleet(&request));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["result"]["report"]["generation"], 4);
    assert_eq!(runner.fleet()["overseer"]["pane"], pane);
}

/// Decision 105: abandoning a waiting runner before retirement completes
/// `failed` only once its stop and its window's close both answered. A pane
/// the host does not answer for is left as it stands and the intent stays
/// open; a window close the host refuses after the runner's stop holds the
/// intent open with the cause, never `failed` with the runner claimed gone.
#[test]
fn an_abandonment_whose_runner_cannot_be_read_or_closed_holds_the_intent_open() {
    struct Row {
        name: &'static str,
        /// The fixture directory put ahead of `PATH`, and the tmux verbs
        /// its shim refuses where it is the tmux shim.
        tools: &'static str,
        fail_verb: Option<&'static str>,
        runner: &'static str,
        cause_prefix: &'static str,
        /// Whether the runner's pane still stands afterwards.
        pane_stands: bool,
        /// Whether the runner's identity is still an obligation afterwards
        /// (decision 111 (A)): discharged by its own stop, never by the
        /// window's close.
        identity_stands: bool,
    }
    let rows = [
        Row {
            name: "the pane cannot be read",
            tools: "tmux-fail",
            fail_verb: Some("display-message"),
            runner: "unobservable",
            cause_prefix: "server-unreachable",
            pane_stands: true,
            identity_stands: true,
        },
        Row {
            name: "the window close is refused",
            tools: "tmux-fail",
            fail_verb: Some("kill-window"),
            runner: "unsettled",
            cause_prefix: "pane-close:",
            pane_stands: false,
            identity_stands: false,
        },
        // The runner's stop times out: a `kill` that signals nothing stands
        // in for a process that ignores its signals, and the runner's
        // identity stays on the outcome for the next reconcile.
        Row {
            name: "the runner's stop times out",
            tools: "kill-noop",
            fail_verb: None,
            runner: "unsettled",
            cause_prefix: "stop-timeout:",
            pane_stands: true,
            identity_stands: true,
        },
    ];
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let predecessor = Owned::sleep();
        let pane = server.open_stub(
            "overseer",
            "stub-confirm",
            runner.state_dir(),
            runner.state_dir(),
        );
        server.await_composer(&pane);
        let runner_pid = server.pane_pid(&pane);
        let mut fleet = runner.fleet();
        fleet["overseer"] = overseer_record(
            predecessor.pid(),
            &predecessor.start(),
            &server,
            runner.state_dir(),
        );
        fleet["overseer"]["pending"] = pending(runner.state_dir());
        // The runner's identity was read before this process ended: the
        // phase carries it (decision 99), so the abandonment stops exactly
        // that process and carries it on an unsettled outcome.
        let mut opened = phase("window-opened", &server, &pane, now_ms(), None);
        opened["identity"] = json!({"pid": runner_pid, "start": start_of(runner_pid)});
        fleet["intents"] = json!([transfer_intent(Some(opened), None)]);
        runner.write_fleet(&fleet);
        runner.tools = Some(fixtures().join(row.tools));
        runner.env.push(("TMUX_REAL".to_owned(), which_tmux()));
        // A short grace, so a stop that times out does so within the row.
        runner
            .env
            .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
        if let Some(verb) = row.fail_verb {
            runner
                .env
                .push(("TMUX_FAIL_VERB".to_owned(), verb.to_owned()));
        }
        let report = runner.reconcile_one();
        assert_eq!(
            report["intent"]["outcome"], "unconfirmed",
            "{}: {report}",
            row.name
        );
        assert_eq!(
            report["intent"]["observation"]["retired"], false,
            "{}",
            row.name
        );
        assert_eq!(
            report["intent"]["observation"]["runner"], row.runner,
            "{}",
            row.name
        );
        let cause = report["intent"]["observation"]["cause"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        assert!(
            cause.starts_with(row.cause_prefix),
            "{}: cause {cause}",
            row.name
        );
        if row.runner == "unsettled" {
            let observation = &report["intent"]["observation"];
            assert_eq!(
                remaining(observation, "pane")["pane"],
                pane,
                "{}: the pane is on the outcome",
                row.name
            );
            let identity = &remaining(observation, "process")["pid"];
            if row.identity_stands {
                assert_eq!(
                    *identity, runner_pid,
                    "{}: the runner identity stands on the outcome",
                    row.name
                );
            } else {
                assert!(
                    identity.is_null(),
                    "{}: the stopped identity is discharged: {observation}",
                    row.name
                );
            }
        }
        let intent = runner.fleet()["intents"][0].clone();
        assert!(
            intent["completed_at"].is_null(),
            "{}: the intent stays open",
            row.name
        );
        assert_eq!(intent["phase"]["phase"], "window-opened", "{}", row.name);
        assert_eq!(
            runner.fleet()["overseer"]["pending"],
            pending(runner.state_dir()),
            "{}: the pending stands as requested",
            row.name
        );
        assert!(
            live(predecessor.pid()),
            "{}: the predecessor runs on",
            row.name
        );
        if row.pane_stands {
            assert!(
                server.panes().contains(&pane),
                "{}: the runner's pane stands",
                row.name
            );
            assert!(
                live(runner_pid),
                "{}: the runner was not signalled",
                row.name
            );
        }
        // With the host answering again, the abandonment completes.
        runner.tools = None;
        runner.env.retain(|(name, _)| name != "TMUX_FAIL_VERB");
        let report = runner.reconcile_one();
        assert_eq!(
            report["intent"]["outcome"], "failed",
            "{}: {report}",
            row.name
        );
        assert_eq!(
            report["intent"]["observation"]["note"], "abandoned-before-retirement",
            "{}",
            row.name
        );
        assert!(
            !server.panes().contains(&pane),
            "{}: the runner's window is closed",
            row.name
        );
        assert!(
            live(predecessor.pid()),
            "{}: the predecessor keeps control",
            row.name
        );
    }
}

/// The runtime's judgement of which intents are open, read by the legacy
/// watch's succession guard through `state inspect`: an open transfer is
/// listed, a closed one is not, and an item file lists none.
#[test]
fn inspect_lists_the_open_intents_the_runtime_judges_open() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let mut fleet = runner.fleet();
    let mut closed = transfer_intent(None, None);
    closed["id"] = json!("request-transfer:overseer:2:1-0");
    closed["outcome"] = json!("failed");
    closed["completed_at"] = json!("2026-01-29T15:21:00Z");
    fleet["intents"] = json!([closed, transfer_intent(None, None)]);
    runner.write_fleet(&fleet);
    let out = runner.run(&["state", "inspect", "--fleet"]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    let open = answer["result"]["open_intents"].as_array().unwrap();
    assert_eq!(open.len(), 1, "{open:?}");
    assert_eq!(open[0]["id"], "request-transfer:overseer:3:1-1");
    assert_eq!(open[0]["op"], "request-transfer");
    assert_eq!(
        answer["result"]["state"]["intents"]
            .as_array()
            .unwrap()
            .len(),
        2,
        "the raw record keeps both"
    );
}

/// Decision 109 (3): the explicit stop runs as the detached job the
/// succession runs as. The predecessor here is a stub harness in a pane that
/// runs the `op` as a foreground child, as the overseer's shell tool runs an
/// explicit off from its own pane. The op hands the stop to the job and
/// answers `stop-started`; the job lets the op exit, retires the predecessor
/// by its identity, whose exit closes the pane the op asked from, closes the
/// window and records `off`.
#[test]
fn a_self_stop_from_the_predecessors_own_pane_records_off_and_closes_the_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let pane = server.open_stub(
        "overseer",
        "stub-succeed",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    let start = start_of(pid);
    let record = record_on(&server, runner.state_dir(), &pane, Some((pid, &start)));
    plant(&runner, record);
    let request_path = runner.state_dir().join("stop.json");
    std::fs::write(
        &request_path,
        serde_json::to_vec(&json!({"op": "stop-controller"})).unwrap(),
    )
    .unwrap();
    let out = runner.state_dir().join("op.out");
    let err = runner.state_dir().join("op.err");
    let words = runner.env_words();
    let script = runner.state_dir().join("self-stop.sh");
    let quoted: Vec<String> = words.iter().map(|w| format!("'{w}'")).collect();
    std::fs::write(
        &script,
        format!(
            "exec env {} {} --no-private-env --state-dir {} op --fleet --request {} > {} 2> {}\n",
            quoted.join(" "),
            binary().display(),
            runner.state_dir().display(),
            request_path.display(),
            out.display(),
            err.display(),
        ),
    )
    .unwrap();
    server.send_line(&pane, &format!("RUN bash {}", script.display()));
    let answer = wait_reply(&out, Duration::from_secs(30), || {
        format!(
            "op.err {:?}\nscreen {:?}\nfleet {}",
            std::fs::read_to_string(&err),
            String::from_utf8_lossy(
                &tmux(&server.socket, &["capture-pane", "-p", "-t", &pane]).stdout
            ),
            runner.fleet()
        )
    });
    assert_eq!(
        answer["ok"],
        true,
        "{answer}\n{}",
        std::fs::read_to_string(&err).unwrap_or_default()
    );
    let effect = &answer["result"]["effect"];
    assert_eq!(effect["started"], "stop-started", "{effect}");
    let owner = effect["owner"].clone();
    let owner_pid = owner["pid"].as_u64().unwrap() as u32;
    assert_ne!(
        owner_pid,
        effect["handed_from"]["pid"].as_u64().unwrap() as u32,
        "the job, not the op, owns the intent"
    );
    // The job retires the predecessor: the stub ends and its exit closes
    // the pane the op asked from; the job outlives both and records `off`.
    wait_until("the predecessor stopped", Duration::from_secs(20), || {
        !live(pid)
    });
    wait_until(
        "the predecessor's pane closed",
        Duration::from_secs(10),
        || !server.panes().contains(&pane),
    );
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(intent["observation"]["retired_by"], "identity");
    // The stub's exit closed its own pane before the window close reached
    // it: the recorded pane read gone on the proven server.
    assert_eq!(intent["observation"]["window"], "pane-gone");
    assert_eq!(intent["owner"], owner, "recorded by the job");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["off"]["generation"], 3, "{overseer}");
    assert!(overseer["off"]["at"].is_string());
    assert_eq!(overseer["generation"], 3);
    assert!(
        !live(effect["handed_from"]["pid"].as_u64().unwrap() as u32),
        "the op that asked is gone with its pane"
    );
    wait_until("the job exited", Duration::from_secs(10), || {
        !live(owner_pid)
    });
}

/// Decision 109 (1), the R-U4c C1 probe as a row: a live stub in a pane the
/// record names on this server with no server start and no identity is an
/// unresolved controller, not an absent one. A start refuses
/// `predecessor-unproven` and opens nothing; an adoption from another pane
/// refuses the same; a stop names nothing to retire and touches the pane;
/// the stub runs on throughout. The remedy, adoption from the record's own
/// pane, binds the start and heals the record.
#[test]
fn an_unproven_predecessor_is_never_replaced_and_its_pane_never_closed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let pane = server.open_stub(
        "overseer",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    let mut record = record_on(&server, runner.state_dir(), &pane, None);
    record.as_object_mut().unwrap().remove("server_start");
    plant(&runner, record);
    let panes_before = server.panes();
    let report = effect_report(&runner.op_fleet(&json!({
        "op": "start-controller",
        "controller": pending(runner.state_dir()),
    })));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"],
        "predecessor-unproven"
    );
    assert_eq!(
        report["intent"]["observation"]["cause"],
        "server-start-unrecorded"
    );
    assert_eq!(
        server.panes(),
        panes_before,
        "nothing opened, nothing closed"
    );
    assert!(live(pid), "the live stub was never signalled");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 3);
    assert_eq!(overseer["pane"], pane);
    // An adoption from another pane: the record is not replaced either.
    let other = server.open_stub(
        "other",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&other);
    let out = runner.op_fleet(&json!({
        "op": "adopt-controller",
        "pane": other,
        "harness": "claude",
        "cwd": runner.state_dir().display().to_string(),
    }));
    assert_eq!(refusal_key(&out), "predecessor-unproven");
    assert_eq!(runner.fleet()["overseer"]["pane"], pane, "nothing written");
    // A stop names nothing to retire and closes nothing.
    let report = effect_report(&runner.op_fleet(&json!({"op": "stop-controller"})));
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{report}\n{intent}");
    assert_eq!(intent["observation"]["note"], "identity-missing");
    assert_eq!(intent["observation"]["cause"], "server-start-unrecorded");
    assert!(server.panes().contains(&pane), "the pane stands");
    assert!(live(pid), "the stub runs on");
    assert!(runner.fleet()["overseer"].get("off").is_none());
    // Adoption from the record's own pane heals it: the server start bound,
    // the identity read in the pane.
    let answer = reply(&runner.op_fleet(&json!({
        "op": "adopt-controller",
        "pane": pane,
        "harness": "claude",
        "cwd": runner.state_dir().display().to_string(),
    })));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["result"]["report"]["healed"], true);
    let healed = runner.fleet()["overseer"].clone();
    assert_eq!(healed["server_start"], server.start);
    assert_eq!(healed["harness_pid"], pid);
}

/// Decision 109 (2): the predecessor's window is a handle the publication
/// settles. With the window close refused by the host, the succession stays
/// `unconfirmed` at `identity-read` with the successor live and the brief
/// delivered, nothing published; the host answering again, the reconcile
/// closes the window and publishes, the watch handed over then and not
/// before.
#[test]
fn a_publication_waits_for_the_predecessors_window_to_read() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    // The record names an idle pane on this server as the predecessor's,
    // with the held child as its identity: the identity stops, the pane
    // stands for the window close.
    let idle = server.open_idle("overseer", runner.state_dir());
    let record = record_on(
        &server,
        runner.state_dir(),
        &idle,
        Some((predecessor.pid(), &predecessor.start())),
    );
    plant(&runner, record.clone());
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let handover_log = runner.state_dir().join("handover.log");
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env.push(("TMUX_REAL".to_owned(), which_tmux()));
    runner
        .env
        .push(("TMUX_FAIL_VERB".to_owned(), "kill-window".to_owned()));
    runner.env.push((
        "WATCH_HANDOVER_LOG".to_owned(),
        handover_log.display().to_string(),
    ));
    let mut request = request_for(&record, runner.state_dir(), "live");
    request["brief_file"] = json!(brief.display().to_string());
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["note"], "predecessor-window-unread");
    assert_eq!(intent["observation"]["retired"], true);
    assert!(
        intent["observation"]["cause"]
            .as_str()
            .unwrap_or_default()
            .starts_with("pane-close:"),
        "{intent}"
    );
    // A failed publication consumed nothing (decision 120 (1)): the
    // predecessor's window stands among the held handles, beside the runner's
    // own, which the publication did not take.
    assert!(
        intent["observation"]["remaining"]
            .as_array()
            .is_some_and(|rows| rows
                .iter()
                .any(|o| o["kind"] == "pane" && o["pane"] == json!(idle))),
        "{intent}"
    );
    // The runner's own process was not published either (R-U4g3-codex site 2):
    // a failed publication consumes nothing.
    assert!(
        intent["obligations"]["standing"]
            .as_array()
            .is_some_and(|rows| rows.iter().any(|o| o["kind"] == "process")),
        "the unpublished runner stands: {intent}"
    );
    assert_eq!(intent["phase"]["phase"], "identity-read");
    assert!(!live(predecessor.pid()), "the predecessor was retired");
    assert!(server.panes().contains(&idle), "its window stands unread");
    assert_eq!(
        runner.stub_turns(runner.state_dir(), runner.state_dir()),
        vec!["HANDOFF".to_owned()],
        "the brief was delivered"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 3, "nothing published");
    assert!(
        overseer["pending"]["runner"]["pid"].is_u64(),
        "the runner is kept"
    );
    assert!(
        !handover_log.exists(),
        "no watch handed over before publication"
    );
    // The host answers again: the reconcile closes the window and publishes.
    runner.tools = None;
    runner.env.retain(|(name, _)| name != "TMUX_FAIL_VERB");
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["predecessor_window"],
        "closed"
    );
    assert!(!server.panes().contains(&idle), "the window is closed");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    let successor = overseer["pane"].as_str().unwrap().to_owned();
    assert_eq!(overseer["harness_pid"], server.pane_pid(&successor));
    // The watch continuation is recorded on the intent once the publication
    // is committed (decision 115 (C)).
    assert_eq!(
        runner.fleet()["intents"][0]["watch"]["outcome"],
        "handed-over"
    );
    let handed = std::fs::read_to_string(&handover_log).unwrap();
    assert_eq!(
        handed.lines().count(),
        3,
        "one call: its words, its handoff and the generation it read: {handed}"
    );
    assert_eq!(handed.lines().nth(2), Some("generation=4"), "{handed}");
}

/// Decision 109 (6): a confirmed publication hands the fleet watch to the
/// successor's pane through the existing owner, with the predecessor's
/// recorded pane, the successor's account variable and account, its harness
/// and the flag words its command carries, less the fixed session id. The
/// outcome carries how it went; a handover the owner refuses leaves the
/// publication confirmed with `watch: failed`.
#[test]
fn a_confirmed_publication_hands_the_watch_to_the_successor_pane() {
    for fail in [None, Some("helper")] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-confirm");
        runner.init_fleet();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let handover_log = runner.state_dir().join("handover.log");
        runner.env.push((
            "WATCH_HANDOVER_LOG".to_owned(),
            handover_log.display().to_string(),
        ));
        if let Some(step) = fail {
            runner
                .env
                .push(("WATCH_HANDOVER_FAIL".to_owned(), step.to_owned()));
        }
        // A custom handoff destination, as `oversee-succeed --handoff` records
        // it on the intent (decision 115 (F)).
        let brief = runner
            .state_dir()
            .join("tmp")
            .join("handoffs")
            .join("CURRENT.md");
        std::fs::create_dir_all(brief.parent().unwrap()).unwrap();
        std::fs::write(&brief, "HANDOFF\n").unwrap();
        let mut request = transfer_request(&server, runner.state_dir());
        request["brief_file"] = json!(brief.display().to_string());
        runner.transfer_started(&request);
        runner.wait_intent_settled("request-transfer:", SETTLE);
        // The watch continuation is recorded after the publication commits
        // (decision 115 (C)), so the job writes it just after the intent
        // closes: wait for it before reading.
        wait_until("the watch continuation is recorded", SETTLE, || {
            !runner.fleet()["intents"][0]["watch"].is_null()
        });
        let intent = runner.fleet()["intents"][0].clone();
        assert_eq!(intent["outcome"], "confirmed", "{fail:?}: {intent}");
        let overseer = runner.fleet()["overseer"].clone();
        let successor = overseer["pane"].as_str().unwrap().to_owned();
        let handed = std::fs::read_to_string(&handover_log).unwrap();
        let mut lines = handed.lines();
        let words: Vec<&str> = lines.next().unwrap_or_default().split(' ').collect();
        // The destination the intent recorded reaches the owner as `HANDOFF`
        // alone, no `WATCH_HANDOFF_KEEP` letting the running watch's own win
        // (decision 120, M2), and the owner ran once the publication was
        // recorded: it read generation 4 (decision 115 (C)).
        assert_eq!(
            lines.next(),
            Some(format!("HANDOFF={}", brief.display()).as_str()),
            "{fail:?}: {handed}"
        );
        assert_eq!(lines.next(), Some("generation=4"), "{fail:?}: {handed}");
        assert_eq!(
            &words[..5],
            &[
                "%99",
                successor.as_str(),
                "CLAUDE_CONFIG_DIR",
                &runner.state_dir().display().to_string(),
                "claude",
            ],
            "{fail:?}: {handed}"
        );
        assert!(
            words.contains(&"--model") && words.contains(&"opus"),
            "{fail:?}: the flags carry the model: {handed}"
        );
        assert!(
            !words.contains(&"--session-id"),
            "{fail:?}: a fixed session id is not a flag the watch keeps: {handed}"
        );
        // The watch continuation is recorded on the intent, after the
        // publication (decision 115 (C)).
        match fail {
            None => {
                assert_eq!(intent["watch"]["outcome"], "handed-over");
                assert_eq!(
                    intent["watch"]["line"],
                    format!("watch-handover pid=0 pane={successor} runner=fixture")
                );
            }
            Some(step) => {
                assert_eq!(intent["watch"]["outcome"], "failed");
                assert_eq!(
                    intent["watch"]["line"],
                    format!("watch-restart-failed step={step}")
                );
                assert_eq!(overseer["generation"], 4, "published all the same");
            }
        }
    }
}

/// Decision 109 (7): a failure the job records is announced once, to the
/// Decision 124f (28), R-U4g6 opus `probe-notice-crash.rs` and Codex M1: the
/// state a crash between a job intent's failed outcome write and its send
/// leaves is a closed intent whose notice is recorded `owed`. The next
/// reconcile, with no open intent to reconcile, sends that notice once and
/// marks it `sent`; the reconcile after it sends nothing again.
#[test]
fn a_reconcile_sends_the_notice_a_closed_intent_still_owes_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let mail_log = runner.state_dir().join("lane-mail.log");
    runner
        .env
        .push(("LANE_MAIL_LOG".to_owned(), mail_log.display().to_string()));
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let id = "request-transfer:overseer:3:1-1";
    let text =
        format!("orch-runtime: job-launch-failed op=request-transfer intent={id} outcome=failed");
    let mut fleet = runner.fleet();
    fleet["intents"] = json!([{
        "id": id, "op": "request-transfer", "target": "overseer:3", "created_at": "2026-01-29T15:20:00Z",
        "completed_at": "2026-01-29T15:21:00Z", "outcome": "failed",
        "observation": {"retired": false, "note": "job-launch-failed", "cause": "job-unit: launch-failed status=7"},
        "notice": {"key": "job-launch-failed", "text": text, "owner": "owed"},
        "obligations": {"standing": [], "discharged": [{"obligation": {"kind": "job-sidecar"}, "by": "launch-failed:7", "role": "job"}], "revision": 2}
    }]);
    runner.write_fleet(&fleet);
    let first = reply(&runner.run(&["reconcile", "--fleet"]));
    assert_eq!(
        first["result"]["reconciled"].as_array().map(Vec::len),
        Some(0),
        "no open intent: {first}"
    );
    let notices = |calls: &str| {
        calls
            .lines()
            .filter(|l| l.starts_with("notice --item overseer --to owner --file "))
            .count()
    };
    let calls = std::fs::read_to_string(&mail_log).unwrap_or_default();
    assert_eq!(notices(&calls), 1, "the owed notice is sent once: {calls}");
    assert!(
        calls.lines().any(|l| l == format!("notice-text {text}")),
        "{calls}"
    );
    let intent = runner.fleet()["intents"][0].clone();
    assert_eq!(intent["notice"]["owner"], "sent", "{intent}");
    assert_eq!(intent["notice"]["text"], text);
    assert_eq!(
        intent["outcome"], "failed",
        "the closed intent stays as it was"
    );
    let _ = reply(&runner.run(&["reconcile", "--fleet"]));
    let calls = std::fs::read_to_string(&mail_log).unwrap_or_default();
    assert_eq!(
        notices(&calls),
        1,
        "a sent notice is never sent again: {calls}"
    );
}

fn owner_notices(mail_log: &Path) -> usize {
    std::fs::read_to_string(mail_log)
        .unwrap_or_default()
        .lines()
        .filter(|l| l.starts_with("notice --item overseer --to owner --file "))
        .count()
}

/// Decision 124f (28), R-U4g7 opus `probe-notice-stamped.rs` (the request
/// case): a live `request-transfer` on a fleet whose closed intent of an
/// earlier generation still owes its notice. The request sends the notice
/// once, marks it `sent`, and proceeds to its own effect,
/// `transfer-started`; the walk never fails the request it precedes.
#[test]
fn a_live_request_with_an_owed_notice_proceeds() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let mail_log = runner.state_dir().join("lane-mail.log");
    runner
        .env
        .push(("LANE_MAIL_LOG".to_owned(), mail_log.display().to_string()));
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let id = "request-transfer:overseer:2:1-1";
    let text =
        format!("orch-runtime: job-launch-failed op=request-transfer intent={id} outcome=failed");
    let mut fleet = runner.fleet();
    fleet["intents"] = json!([{
        "id": id, "op": "request-transfer", "target": "overseer:2",
        "created_at": "2026-01-29T15:20:00Z",
        "completed_at": "2026-01-29T15:21:00Z", "outcome": "failed",
        "observation": {"retired": false, "note": "job-launch-failed", "cause": "job-unit: launch-failed status=7"},
        "notice": {"key": "job-launch-failed", "text": text, "owner": "owed"},
        "obligations": {"standing": [], "discharged": [{"obligation": {"kind": "job-sidecar"}, "by": "launch-failed:7", "role": "job"}], "revision": 2}
    }]);
    runner.write_fleet(&fleet);
    let request = transfer_request(&server, runner.state_dir());
    let out = runner.op_fleet(&request);
    let answer = reply(&out);
    assert!(
        answer["ok"].as_bool().unwrap_or(false),
        "the request ran its effect: {}",
        stderr(&out)
    );
    assert_eq!(
        answer["result"]["effect"]["started"], "transfer-started",
        "{answer}"
    );
    assert!(
        answer["result"].get("notices_unmarked").is_none(),
        "the mark was written: {answer}"
    );
    assert_eq!(owner_notices(&mail_log), 1, "sent once");
    let closed = runner.fleet()["intents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["id"] == id)
        .cloned()
        .unwrap();
    assert_eq!(closed["notice"]["owner"], "sent", "{closed}");
    // The job the request handed its effect to settles before the fleet goes.
    runner.wait_intent_settled("request-transfer:overseer:3", SETTLE);
}

/// A detached job's failure is announced once: to the fleet log and to the
/// owner through the mailbox CLI, keyed by its cause;
/// the intent records the announcement, and a repeated reconcile of the same
/// outcome announces nothing again.
#[test]
fn a_job_failure_reaches_the_fleet_log_and_the_owner_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-mute");
    runner.verify = Some(2);
    runner.init_fleet();
    let mail_log = runner.state_dir().join("lane-mail.log");
    runner
        .env
        .push(("LANE_MAIL_LOG".to_owned(), mail_log.display().to_string()));
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let rows_before = runner.fleet()["fleet_log"].as_array().map_or(0, Vec::len);
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["note"], "brief-unconfirmed");
    let id = intent["id"].as_str().unwrap().to_owned();
    let text = format!(
        "orch-runtime: brief-unconfirmed op=request-transfer intent={id} outcome=unconfirmed"
    );
    assert_eq!(intent["notice"]["key"], "brief-unconfirmed");
    assert_eq!(intent["notice"]["text"], text);
    assert_eq!(intent["notice"]["owner"], "sent");
    let log = runner.fleet()["fleet_log"].as_array().unwrap().clone();
    assert_eq!(log.len(), rows_before + 1, "{log:?}");
    assert_eq!(log.last().unwrap()["kind"], "close");
    assert_eq!(log.last().unwrap()["item"], "overseer");
    assert_eq!(log.last().unwrap()["text"], text);
    let calls = std::fs::read_to_string(&mail_log).unwrap();
    let notices: Vec<&str> = calls
        .lines()
        .filter(|l| l.starts_with("notice --item overseer --to owner --file "))
        .collect();
    assert_eq!(notices.len(), 1, "{calls}");
    assert!(
        calls.lines().any(|l| l == format!("notice-text {text}")),
        "{calls}"
    );
    // The reconcile reads the same outcome: nothing is announced again.
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "unconfirmed");
    assert_eq!(again["intent"]["notice"]["text"], text);
    assert_eq!(
        runner.fleet()["fleet_log"].as_array().unwrap().len(),
        rows_before + 1
    );
    let calls = std::fs::read_to_string(&mail_log).unwrap();
    assert_eq!(
        calls
            .lines()
            .filter(|l| l.starts_with("notice --item overseer"))
            .count(),
        1,
        "{calls}"
    );
}

/// Decision 109 (5), the R-U4c H1 probe as a row: the runtime builds the
/// successor's command from the typed launch fields through the one launch
/// builder, which routes the account by the harness's table. A Pi successor
/// on a `pi-claude/` model is launched with Pi's own root in
/// `PI_CODING_AGENT_DIR` and the chosen Claude seat in `CLAUDE_CONFIG_DIR`,
/// its model word carrying the provider and the effort, the caller's own
/// words appended; the recorded `launch_line` is never what runs. A Claude
/// successor under `native` keeps the caller's permission words and gains
/// no bypass word.
#[test]
fn the_successor_is_launched_from_its_typed_fields_with_the_account_routed() {
    // Pi: the stub records what it was launched as and draws no composer,
    // so the succession abandons it before retirement; the record is read.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("seat");
    let pi_home = dir.path().join("pi-home");
    std::fs::create_dir_all(&seat).unwrap();
    std::fs::create_dir_all(&pi_home).unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut pi = pending(runner.state_dir());
    pi["harness"] = json!("pi");
    pi["home"] = json!(pi_home.display().to_string());
    pi["account"] = json!(seat.display().to_string());
    pi["model"] = json!("pi-claude/claude-fable-5-1");
    pi["effort"] = json!("high");
    pi["permission"] = json!("native");
    pi["extra_args"] = json!(["--thinking", "high"]);
    pi["launch_line"] = json!("cd /r && pi --model never-run");
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = pi.clone();
    runner.write_fleet(&fleet);
    let mut request = transfer_request(&server, runner.state_dir());
    request["expected"]["pending"] = pi.clone();
    request["successor"] = pi;
    let binaries = format!(
        "claude={},pi={}",
        stub("stub-record").display(),
        fixtures().join("stub-record/pi").display()
    );
    runner.transfer_started_env(&request, &[("ORCH_HARNESS_BINARIES", &binaries)]);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "successor-not-ready");
    let launched: Value = serde_json::from_str(
        &std::fs::read_to_string(runner.state_dir().join("launch-record.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        launched["env"]["PI_CODING_AGENT_DIR"],
        pi_home.display().to_string(),
        "{launched}"
    );
    assert_eq!(
        launched["env"]["CLAUDE_CONFIG_DIR"],
        seat.display().to_string(),
        "{launched}"
    );
    let argv: Vec<String> = launched["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap().to_owned())
        .collect();
    let at = argv.iter().position(|a| a == "--model").unwrap();
    assert_eq!(argv[at + 1], "pi-claude/claude-fable-5-1:high", "{argv:?}");
    assert!(
        argv.ends_with(&["--thinking".to_owned(), "high".to_owned()]),
        "{argv:?}"
    );
    assert!(
        !argv.iter().any(|a| a == "never-run"),
        "the recorded line never runs"
    );
    assert!(live(predecessor.pid()), "abandoned before retirement");

    // Claude under native permission: the caller's words, no bypass word.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut native = pending(runner.state_dir());
    native["permission"] = json!("native");
    native["extra_args"] = json!(["--permission-mode", "dontAsk", "--verbose"]);
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = native.clone();
    runner.write_fleet(&fleet);
    let mut request = transfer_request(&server, runner.state_dir());
    request["expected"]["pending"] = native.clone();
    request["successor"] = native;
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let launched: Value = serde_json::from_str(
        &std::fs::read_to_string(runner.state_dir().join("launch-record.json")).unwrap(),
    )
    .unwrap();
    let argv: Vec<String> = launched["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap().to_owned())
        .collect();
    assert!(
        !argv.iter().any(|a| a == "--dangerously-skip-permissions"),
        "{argv:?}"
    );
    assert!(
        argv.ends_with(&[
            "--permission-mode".to_owned(),
            "dontAsk".to_owned(),
            "--verbose".to_owned()
        ]),
        "{argv:?}"
    );
    assert!(argv.iter().any(|a| a == "--session-id"), "{argv:?}");
    assert_eq!(
        launched["env"]["CLAUDE_CONFIG_DIR"],
        runner.state_dir().display().to_string()
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4);
    assert_eq!(
        overseer["launch_line"], "cd /r && claude --model opus",
        "the pending line is recorded for display"
    );

    // Copilot under the bypass posture (decision 115 (E)): the builder owns
    // the permission environment, so `COPILOT_ALLOW_ALL=true` reaches the
    // launched process whatever the argv words, read off the recorded env.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("copilot-home");
    std::fs::create_dir_all(&seat).unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut copilot = pending(runner.state_dir());
    copilot["harness"] = json!("copilot");
    copilot["account"] = json!(seat.display().to_string());
    copilot["home"] = json!(seat.display().to_string());
    copilot["model"] = json!("claude-opus-5.5");
    copilot["permission"] = json!("bypass");
    copilot["extra_args"] = json!([]);
    copilot["launch_line"] = json!("cd /r && copilot --model never-run");
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = copilot.clone();
    runner.write_fleet(&fleet);
    let mut request = transfer_request(&server, runner.state_dir());
    request["expected"]["pending"] = copilot.clone();
    request["successor"] = copilot;
    let binaries = format!(
        "claude={},copilot={}",
        stub("stub-record").display(),
        fixtures().join("stub-record/copilot").display()
    );
    runner.transfer_started_env(&request, &[("ORCH_HARNESS_BINARIES", &binaries)]);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "successor-not-ready");
    let launched: Value = serde_json::from_str(
        &std::fs::read_to_string(runner.state_dir().join("launch-record.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        launched["env"]["COPILOT_ALLOW_ALL"], "true",
        "the bypass posture sets the Copilot permission environment: {launched}"
    );
    let argv: Vec<String> = launched["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap().to_owned())
        .collect();
    assert!(argv.iter().any(|a| a == "--allow-all"), "{argv:?}");
    assert!(live(predecessor.pid()), "abandoned before retirement");
}

// ---------------------------------------------------------------------------
// Decision 120: the controller rows of R-U4g2 (P3 to P7), the Codex probes,
// the job identity and the posture guard.
// ---------------------------------------------------------------------------

/// The discharged rows of the intent's recorded set whose evidence word is
/// `by`, as `{kind, ...}` objects.
fn discharged_by(intent: &Value, by: &str) -> Vec<Value> {
    intent["obligations"]["discharged"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter(|row| row["by"] == by)
                .map(|row| row["obligation"].clone())
                .collect()
        })
        .unwrap_or_default()
}

/// The `launch-record.json` the record stubs write in `cwd`, parsed.
fn launch_record(cwd: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(cwd.join("launch-record.json")).unwrap()).unwrap()
}

fn argv_of(launched: &Value) -> Vec<String> {
    launched["argv"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a.as_str().unwrap().to_owned())
        .collect()
}

/// The variables the record stubs read back, as `launched` names them.
fn launched_var<'a>(launched: &'a Value, name: &str) -> &'a Value {
    &launched["env"][name]
}

/// R-U4g2 P3 (decision 120 (2)): a crash between the predecessor's stop and
/// the `retired` write. The recorded set is the window-opened one; the
/// predecessor is gone and its window's close is refused by the host. The
/// reconcile acquires the predecessor's handles before it acts and publishes
/// nothing over its unread window: `unconfirmed`, the window standing.
#[test]
fn a_crash_before_the_retired_write_never_publishes_over_an_unread_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_stub(
        "overseer",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    let idle = server.open_idle("predecessor", runner.state_dir());
    let pid = server.pane_pid(&pane);
    let mut ph = phase("window-opened", &server, &pane, since, None);
    ph["identity"] = json!({"pid": pid, "start": start_of(pid)});
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(GONE_PID as u32, "ticks:1", &server, runner.state_dir());
    fleet["overseer"]["pane"] = json!(idle);
    fleet["overseer"]["server_start"] = json!(server.start);
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    let mut intent = transfer_intent(Some(ph), None);
    intent["obligations"] = json!({
        "standing": [
            {"kind": "pane", "pane": pane, "server": server.pid, "server_start": server.start, "role": "runner"},
            {"kind": "process", "pid": pid, "start": start_of(pid), "role": "runner"},
        ],
        "discharged": [{"obligation": {"kind": "receipt"}, "by": "receipt-read", "role": "runner"}],
    });
    fleet["intents"] = json!([intent]);
    runner.write_fleet(&fleet);
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env.push(("TMUX_REAL".to_owned(), which_tmux()));
    runner
        .env
        .push(("TMUX_FAIL_VERB".to_owned(), "kill-window".to_owned()));
    let report = runner.reconcile_one();
    assert_eq!(
        report["intent"]["outcome"], "unconfirmed",
        "the predecessor window is unread: {report}"
    );
    assert_eq!(
        report["intent"]["observation"]["note"],
        "predecessor-window-unread"
    );
    // A failed publication consumed nothing: the predecessor's window stands
    // among the held handles, beside the runner's own (decision 120 (1)).
    assert!(
        report["intent"]["observation"]["remaining"]
            .as_array()
            .is_some_and(|rows| rows
                .iter()
                .any(|o| o["kind"] == "pane" && o["pane"] == json!(idle))),
        "{report}"
    );
    assert!(
        server.panes().contains(&idle),
        "the predecessor window stands"
    );
    assert_eq!(
        runner.fleet()["overseer"]["generation"],
        3,
        "nothing published"
    );
    // The host answering, the reconcile closes it and publishes.
    runner.tools = None;
    runner.env.retain(|(name, _)| name != "TMUX_FAIL_VERB");
    let again = runner.reconcile_one();
    assert_eq!(again["intent"]["outcome"], "confirmed", "{again}");
    assert!(!server.panes().contains(&idle));
    assert_eq!(runner.fleet()["overseer"]["generation"], 4);
}

/// R-U4g2 P4 (decision 120 (5)): the predecessor's window close lands on the
/// predecessor's own pane key, never on the runner's. With the runner's own
/// window close refused and the runner's identity gone, the predecessor's
/// window is closed and discharged by that close while the runner's pane
/// stands held; two reconciles later the intent is still open, never
/// `failed` with the runner's window standing.
#[test]
fn the_predecessors_close_never_discharges_the_runners_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_idle("overseer", runner.state_dir());
    let idle = server.open_idle("predecessor", runner.state_dir());
    let window = String::from_utf8_lossy(
        &tmux(
            &server.socket,
            &["display-message", "-p", "-t", &pane, "#{window_id}"],
        )
        .stdout,
    )
    .trim()
    .to_owned();
    let mut ph = phase("identity-read", &server, &pane, since, None);
    ph["pid"] = json!(GONE_PID - 7);
    ph["start"] = json!("ticks:7");
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(GONE_PID as u32, "ticks:1", &server, runner.state_dir());
    fleet["overseer"]["pane"] = json!(idle);
    fleet["overseer"]["server_start"] = json!(server.start);
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    let mut intent = transfer_intent(Some(ph), None);
    // The set as `succeed` records it at `retired` and on: the runner's pane
    // and identity, then the predecessor's pane and identity.
    intent["obligations"] = json!({
        "standing": [
            {"kind": "pane", "pane": pane, "server": server.pid, "server_start": server.start, "role": "runner"},
            {"kind": "process", "pid": GONE_PID - 7, "start": "ticks:7", "role": "runner"},
            {"kind": "pane", "pane": idle, "server": server.pid, "server_start": server.start, "role": "predecessor"},
            {"kind": "process", "pid": GONE_PID, "start": "ticks:1", "role": "predecessor"},
        ],
        "discharged": [{"obligation": {"kind": "receipt"}, "by": "receipt-read", "role": "runner"}],
    });
    fleet["intents"] = json!([intent]);
    runner.write_fleet(&fleet);
    // A shim that refuses only the runner's own window close.
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let shim = tools.join("tmux");
    std::fs::write(
        &shim,
        format!(
            "#!/bin/bash\nfor a in \"$@\"; do [ \"$a\" = kill-window ] && k=1; [ \"$a\" = '{window}' ] && w=1; done\n[ -n \"$k\" ] && [ -n \"$w\" ] && {{ echo refused >&2; exit 1; }}\nexec {} \"$@\"\n",
            which_tmux()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    runner.tools = Some(tools);
    let first = runner.reconcile_one();
    assert_eq!(first["intent"]["outcome"], "unconfirmed", "{first}");
    let recorded = runner.fleet()["intents"][0].clone();
    assert_eq!(
        discharged_by(&recorded, "closed"),
        vec![
            json!({"kind": "pane", "pane": idle, "server": server.pid, "server_start": server.start})
        ],
        "the predecessor's own pane is what its close discharged: {recorded}"
    );
    assert_eq!(
        remaining(&first["intent"]["observation"], "pane")["pane"],
        pane
    );
    assert!(
        !server.panes().contains(&idle),
        "the predecessor's window is closed"
    );
    assert!(
        server.panes().contains(&pane),
        "the runner's pane stands, its close refused"
    );
    let second = runner.reconcile_one();
    assert_eq!(second["intent"]["outcome"], "unconfirmed", "{second}");
    assert!(server.panes().contains(&pane));
    // The host answering, the runner's window closes and the failure completes.
    runner.tools = None;
    let third = runner.reconcile_one();
    assert_eq!(third["intent"]["outcome"], "failed", "{third}");
    assert_eq!(third["intent"]["observation"]["note"], "successor-exited");
    assert!(!server.panes().contains(&pane));
}

/// R-U4g2 P5 (decision 120 (2)): the controller stop records `signalled`
/// before its first signal. Its `kill` stands in for a process that ignores
/// the signal, so the stop times out and holds; with the record then moved
/// under the open intent by a legacy writer, the reconcile holds
/// `target-moved` with `stop` not `none`: a refusal is impossible after a
/// signal on the intent. Decision 124d (20): that moved reconcile retries
/// on the intent's own set, so the signalled predecessor is stopped by its
/// own token there, never left live for the operator. The predecessor's
/// pane is planted on a server process that is live (this test's own) but
/// answers at no socket, the unobservable cell of decision 64 that holds
/// the set open; a pane on a server replaced at the recorded pid reads gone
/// instead and settles it (decision 124g (30)).
#[test]
fn a_signalled_controller_stop_never_refuses() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut fleet = runner.fleet();
    fleet["overseer"]["server"] = json!(std::process::id().to_string());
    runner.write_fleet(&fleet);
    runner.tools = Some(fixtures().join("kill-noop"));
    runner
        .env
        .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
    runner.op_fleet(&json!({"op": "stop-controller"}));
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["stop"], "pending");
    assert_eq!(
        intent["obligations"]["signalled"], true,
        "the signal is recorded on the intent: {intent}"
    );
    assert!(live(predecessor.pid()), "the noop kill signalled nothing");
    runner.tools = None;
    // A legacy record writer (`ol_record_write`) moves the generation under
    // the open intent.
    let mut fleet = runner.fleet();
    fleet["overseer"]["generation"] = json!(4);
    fleet["overseer"].as_object_mut().unwrap().remove("off");
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(report["intent"]["observation"]["cause"], "target-moved");
    assert_eq!(report["intent"]["observation"]["signalled"], true);
    assert_ne!(
        report["intent"]["observation"]["stop"], "none",
        "a signalled stop cannot refuse: {report}"
    );
    assert!(report["intent"]["observation"].get("untouched").is_none());
    // R-U4g3 (opus) C1 (a), decision 124a (1): the moved target closes the
    // intent only on a terminal word. Held `unconfirmed` on its planted pane
    // the host cannot prove, it stays open with the generation it observed
    // noted, its receipt and job files kept.
    let after = runner.fleet()["intents"][0].clone();
    assert!(
        after["completed_at"].is_null(),
        "an unconfirmed moved target stays open: {after}"
    );
    assert!(after["reconciled"].is_null(), "{after}");
    assert_eq!(after["observed_generation"], 4, "{after}");
    // Decision 124d (20): the moved reconcile stopped the signalled
    // predecessor through its own set's token, with the real `kill` now in
    // reach; nothing the record names at generation 4 was read for it.
    assert!(
        discharged_by(&after, "stopped")
            .iter()
            .any(|o| o["kind"] == "process" && o["pid"] == predecessor.pid()),
        "the signalled identity is stopped by the retry on its own set: {report}"
    );
    assert!(
        !live(predecessor.pid()),
        "the predecessor the intent signalled is ended by its own retry"
    );
}

/// R-U4g2 P6 (decision 120 (3)): after retirement, with the pending gone, the
/// runner's pane standing and its recorded identity gone, the recorded set
/// holds the predecessor's pane and identity. The failure consumes the whole
/// recorded set: the runner stopped and its window closed, the predecessor's
/// identity read and its window closed, nothing dropped.
#[test]
fn pending_missing_after_retirement_consumes_the_predecessor() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_idle("overseer", runner.state_dir());
    let idle = server.open_idle("predecessor", runner.state_dir());
    let mut ph = phase("retired", &server, &pane, since, None);
    ph["identity"] = json!({"pid": GONE_PID - 7, "start": "ticks:7"});
    let mut fleet = runner.fleet();
    fleet["overseer"] = overseer_record(GONE_PID as u32, "ticks:1", &server, runner.state_dir());
    fleet["overseer"]["pane"] = json!(idle);
    fleet["overseer"]["server_start"] = json!(server.start);
    fleet["overseer"].as_object_mut().unwrap().remove("pending");
    let mut intent = transfer_intent(Some(ph), None);
    intent["obligations"] = json!({
        "standing": [
            {"kind": "pane", "pane": pane, "server": server.pid, "server_start": server.start, "role": "runner"},
            {"kind": "process", "pid": GONE_PID - 7, "start": "ticks:7", "role": "runner"},
            {"kind": "pane", "pane": idle, "server": server.pid, "server_start": server.start, "role": "predecessor"},
            {"kind": "process", "pid": GONE_PID, "start": "ticks:1", "role": "predecessor"},
        ],
        "discharged": [{"obligation": {"kind": "receipt"}, "by": "receipt-read", "role": "runner"}],
    });
    fleet["intents"] = json!([intent]);
    runner.write_fleet(&fleet);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "pending-missing");
    assert_eq!(report["intent"]["observation"]["retired"], true);
    assert!(
        !server.panes().contains(&idle),
        "the predecessor's window is closed"
    );
    assert!(
        !server.panes().contains(&pane),
        "the runner's window is closed"
    );
    let recorded = runner.fleet()["intents"][0].clone();
    assert!(
        recorded["obligations"]["standing"]
            .as_array()
            .unwrap()
            .is_empty(),
        "every recorded obligation discharged, none dropped: {recorded}"
    );
    assert_eq!(
        recorded["obligations"]["discharged"]
            .as_array()
            .unwrap()
            .len(),
        5
    );
}

/// R-U4g2 P7, decision 120 (C2): the outstanding-job predicate reads the
/// recorded job obligations, never the claim's `handed_from`. An earlier job
/// of the intent claimed it; the repeat's own job was asked, its launcher did
/// not answer and its group identity reads live: a further repeat starts no
/// other job while that one stands.
#[test]
fn a_repeat_after_a_claimed_job_starts_no_job_while_one_stands() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let standing_job = Owned::sleep();
    let job_unit = fixtures()
        .join("job-unit-fail/job-unit")
        .display()
        .to_string();
    let log = runner.state_dir().join("job-unit.log");
    let log_s = log.display().to_string();
    let pid_s = standing_job.pid().to_string();
    let start_s = standing_job.start();
    let settings = [
        ("ORCH_JOB_UNIT", job_unit.as_str()),
        ("JOB_UNIT_LOG", log_s.as_str()),
        (
            "JOB_UNIT_FAIL_LINE",
            "job-unit: launch-failed detail=no-answer",
        ),
        ("JOB_UNIT_FAIL_PID", pid_s.as_str()),
        ("JOB_UNIT_FAIL_START", start_s.as_str()),
    ];
    let out = runner.op_fleet_env(&json!({"op": "stop-controller"}), &settings);
    assert_eq!(refusal_key(&out), "job-launch-failed", "{}", stderr(&out));
    // An earlier job of this intent had claimed it.
    let mut fleet = runner.fleet();
    fleet["intents"][0]["handed_from"] = json!({"pid": 1, "start": "ticks:1"});
    runner.write_fleet(&fleet);
    let out2 = runner.op_fleet_env(&json!({"op": "stop-controller"}), &settings);
    let report = effect_report(&out2);
    assert_eq!(
        report["intent"]["observation"]["job"], "possibly-started",
        "{report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "job")["pid"],
        standing_job.pid(),
        "the standing group is what holds the repeat: {report}"
    );
    let calls = std::fs::read_to_string(&log)
        .unwrap()
        .lines()
        .filter(|l| l.starts_with("launch "))
        .count();
    assert_eq!(calls, 1, "a second job while the first stands");
    assert!(live(standing_job.pid()));
    assert!(live(predecessor.pid()), "nothing retired the predecessor");
}

/// Decision 120 (C2, L1): the real setsid launcher reads its child's identity
/// from the kernel table before it returns, and the runtime records that
/// identity before the claim wait. A real child that exits before it claims
/// stands as its recorded group until the reconcile reads it gone by that
/// identity and discharges `job-exited`: `failed`, never standing forever,
/// and no start was ever manufactured.
#[test]
fn a_real_setsid_child_that_exits_before_claiming_is_read_gone_by_its_recorded_identity() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let launcher = fixtures()
        .join("job-unit-exit/job-unit")
        .display()
        .to_string();
    let real = job_unit().display().to_string();
    let out = runner.op_fleet_env(
        &transfer_request(&server, runner.state_dir()),
        &[
            ("ORCH_JOB_UNIT", &launcher),
            ("JOB_UNIT_REAL", &real),
            ("JOB_UNIT_EXIT_AFTER", "0.3"),
        ],
    );
    assert_eq!(refusal_key(&out), "job-unclaimed", "{}", stderr(&out));
    let intent = runner.fleet()["intents"][0].clone();
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    let job = remaining(&intent["observation"], "job").clone();
    let pid = job["pid"]
        .as_u64()
        .expect("the launcher read the child's pid") as u32;
    let start = job["start"].as_str().expect("and its start").to_owned();
    assert!(start.starts_with("ticks:"), "{start}");
    assert_ne!(start, "ticks:0", "no manufactured start");
    let record = std::fs::read_to_string(
        runner
            .state_dir()
            .join("intents")
            .join(format!("{}.job", intent["id"].as_str().unwrap())),
    )
    .unwrap();
    assert!(
        record.contains(&format!("pid={pid}\nstart={start}\n")),
        "the launcher's record names the identity it read: {record}"
    );
    // The child is gone: the reconcile reads the recorded group gone and
    // discharges the job, so the intent fails rather than standing forever.
    let deadline = Instant::now() + Duration::from_secs(5);
    while live(pid) {
        assert!(Instant::now() < deadline, "the child never exited");
        std::thread::sleep(Duration::from_millis(20));
    }
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["job"], "ended");
    assert!(live(predecessor.pid()), "nothing retired the predecessor");
}

/// Decision 120 (M1): the caller's argv reaches the launched command exactly
/// as given, the judged posture travels as its own field, and the builder
/// derives the environment from the posture: a `native` posture whose words
/// carry the harness's bypass word refuses `permission-mismatch` before any
/// window; a `bypass` posture whose words already carry it adds no second
/// word and sets the prompt-suppression values; the dead-pane Copilot bypass
/// replay's half, a Copilot `bypass` with `--allow-all` among its words, sets
/// `COPILOT_ALLOW_ALL=true` with the word once.
#[test]
fn the_callers_argv_reaches_the_launch_as_given_under_the_posture_it_spells() {
    // A two-word value stays one argv element.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut native = pending(runner.state_dir());
    native["permission"] = json!("native");
    native["extra_args"] = json!(["--append-system-prompt", "two words"]);
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = native.clone();
    runner.write_fleet(&fleet);
    let mut request = transfer_request(&server, runner.state_dir());
    request["expected"]["pending"] = native.clone();
    request["successor"] = native;
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let argv = argv_of(&launch_record(runner.state_dir()));
    assert!(
        argv.ends_with(&["--append-system-prompt".to_owned(), "two words".to_owned()]),
        "two words reach the launch as two argv elements, the value whole: {argv:?}"
    );

    // A bypass word under the native posture: refused before any window.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut mismatched = pending(runner.state_dir());
    mismatched["permission"] = json!("native");
    mismatched["extra_args"] = json!(["--dangerously-skip-permissions"]);
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = mismatched.clone();
    runner.write_fleet(&fleet);
    let mut request = transfer_request(&server, runner.state_dir());
    request["expected"]["pending"] = mismatched.clone();
    request["successor"] = mismatched;
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "permission-mismatch");
    assert_eq!(intent["observation"]["fields"]["posture"], "native");
    assert_eq!(server.panes().len(), 1, "no window opened");
    assert!(live(predecessor.pid()));

    // The bypass posture with the word already given: once, with the
    // values the posture derives.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-record");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut bypass = pending(runner.state_dir());
    bypass["permission"] = json!("bypass");
    bypass["extra_args"] = json!(["--dangerously-skip-permissions", "--verbose"]);
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = bypass.clone();
    runner.write_fleet(&fleet);
    let mut request = transfer_request(&server, runner.state_dir());
    request["expected"]["pending"] = bypass.clone();
    request["successor"] = bypass;
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let launched = launch_record(runner.state_dir());
    let argv = argv_of(&launched);
    assert_eq!(
        argv.iter()
            .filter(|a| *a == "--dangerously-skip-permissions")
            .count(),
        1,
        "the bypass word once, as the caller gave it: {argv:?}"
    );
    assert!(argv.ends_with(&[
        "--dangerously-skip-permissions".to_owned(),
        "--verbose".to_owned()
    ]));
    assert_eq!(
        launched_var(&launched, "CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT"),
        "1"
    );
    assert_eq!(
        launched_var(&launched, "CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT"),
        "1"
    );

    // Copilot under bypass with its replayed `--allow-all`: the word once and
    // `COPILOT_ALLOW_ALL=true`.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("copilot-home");
    std::fs::create_dir_all(&seat).unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut copilot = pending(runner.state_dir());
    copilot["harness"] = json!("copilot");
    copilot["account"] = json!(seat.display().to_string());
    copilot["home"] = json!(seat.display().to_string());
    copilot["model"] = json!("claude-opus-5.5");
    copilot["permission"] = json!("bypass");
    copilot["extra_args"] = json!(["--allow-all"]);
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = copilot.clone();
    runner.write_fleet(&fleet);
    let mut request = transfer_request(&server, runner.state_dir());
    request["expected"]["pending"] = copilot.clone();
    request["successor"] = copilot;
    let binaries = format!(
        "claude={},copilot={}",
        stub("stub-record").display(),
        fixtures().join("stub-record/copilot").display()
    );
    runner.transfer_started_env(&request, &[("ORCH_HARNESS_BINARIES", &binaries)]);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "successor-not-ready");
    let launched = launch_record(runner.state_dir());
    assert_eq!(
        launched_var(&launched, "COPILOT_ALLOW_ALL"),
        "true",
        "{launched}"
    );
    assert_eq!(
        argv_of(&launched)
            .iter()
            .filter(|a| *a == "--allow-all")
            .count(),
        1,
        "{launched}"
    );
}

/// R-U4g3 (opus) M1, decision 124a (3): a predecessor stop that reads
/// `Unreadable` before it sends any signal (a `ps` that fails for the
/// predecessor's pid, its legacy `lstart` start read through `ps`) leaves the
/// predecessor as it was. Its handles return to its record, discharged
/// `not-signalled` by that answer, and the succession fails before
/// retirement with the pending restored: the healthy predecessor runs on and
/// a new controller operation is not refused `intent-open`.
#[test]
fn a_stop_unread_before_any_signal_fails_before_retirement_and_restores_the_pending() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    let lstart = String::from_utf8(
        std::process::Command::new("/usr/bin/ps")
            .env("TZ", "UTC")
            .env("LC_ALL", "C")
            .args(["-o", "lstart=", "-p", &predecessor.pid().to_string()])
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap();
    let lstart = lstart.split_whitespace().collect::<Vec<_>>().join(" ");
    plant_transfer(&runner, &server, predecessor.pid(), &lstart);
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    let ps = tools.join("ps");
    std::fs::write(
        &ps,
        format!(
            "#!/bin/bash\nfor a; do last=$a; done\nif [ \"$last\" = {pid} ]; then exit 2; fi\nexec /usr/bin/ps \"$@\"\n",
            pid = predecessor.pid()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&ps, std::fs::Permissions::from_mode(0o755)).unwrap();
    runner.tools = Some(tools);
    runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "predecessor-unreadable");
    assert_eq!(intent["observation"]["retired"], false);
    assert!(
        discharged_by(&intent, "not-signalled")
            .iter()
            .any(|o| o["kind"] == "process"),
        "the predecessor's identity returned to its record: {intent}"
    );
    assert!(
        live(predecessor.pid()),
        "the predecessor was never signalled"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 3, "nothing published");
    assert_eq!(
        overseer["pending"],
        original_pending_of(&runner),
        "the pending is restored"
    );
    // The intent is closed: the next controller operation is not refused
    // `intent-open`.
    runner.tools = None;
    let again = runner.op_fleet(&transfer_request(&server, runner.state_dir()));
    assert_eq!(
        reply(&again)["ok"],
        true,
        "a new succession is taken, not refused intent-open: {}",
        stderr(&again)
    );
}

/// Decision 124a (3): a predecessor stop that signalled and timed out (a `kill`
/// that signals nothing) holds the succession with the predecessor live; the
/// reconcile, reading it live, runs the stop again through the signalling
/// method, and with the host's own `kill` the predecessor ends.
#[test]
fn a_live_predecessor_after_a_timed_out_stop_is_re_signalled_by_the_reconcile() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    runner.tools = Some(fixtures().join("kill-noop"));
    runner
        .env
        .push(("ORCH_LANE_CLOSE_SECS".to_owned(), "1".to_owned()));
    runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["note"], "predecessor-not-retired");
    assert_eq!(intent["obligations"]["signalled"], true);
    assert!(live(predecessor.pid()), "the noop kill signalled nothing");
    runner.tools = None;
    let report = runner.reconcile_one();
    assert!(
        !live(predecessor.pid()),
        "the reconcile re-signalled the live predecessor: {report}"
    );
    assert_ne!(
        report["intent"]["observation"]["note"], "predecessor-retiring",
        "a live predecessor is stopped again, not held: {report}"
    );
    assert_eq!(report["intent"]["observation"]["retired"], true, "{report}");
}

/// Decision 124a (4), R-U4g3 (opus) H1: a `native` posture with a narrower
/// permission word launches with exactly that word and no bypass word or
/// environment, for each harness's narrower spelling; a `native` posture
/// carrying a full-bypass alias refuses `permission-mismatch`.
#[test]
fn a_native_posture_keeps_a_narrower_permission_word_and_refuses_a_bypass_alias() {
    let launch = |harness: &str, words: &[&str]| -> (Value, Value) {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = Runner::new(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let seat = dir.path().join("seat");
        std::fs::create_dir_all(&seat).unwrap();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let mut native = pending(runner.state_dir());
        native["harness"] = json!(harness);
        native["account"] = json!(seat.display().to_string());
        native["home"] = json!(seat.display().to_string());
        native["model"] = json!("m");
        native["permission"] = json!("native");
        native["extra_args"] = json!(words);
        let mut fleet = runner.fleet();
        fleet["overseer"]["pending"] = native.clone();
        runner.write_fleet(&fleet);
        let mut request = transfer_request(&server, runner.state_dir());
        request["expected"]["pending"] = native.clone();
        request["successor"] = native;
        let binaries = format!(
            "claude={},codex={},copilot={}",
            stub("stub-record").display(),
            fixtures().join("stub-record/codex").display(),
            fixtures().join("stub-record/copilot").display()
        );
        runner.transfer_started_env(&request, &[("ORCH_HARNESS_BINARIES", &binaries)]);
        let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
        let launched = std::fs::read_to_string(runner.state_dir().join("launch-record.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        (intent, launched)
    };
    // (harness, words, the bypass word that must not appear, the bypass
    // environment variable that must not be set to its bypass value)
    let narrower: [(&str, &[&str], &str, Option<&str>); 4] = [
        (
            "codex",
            &["-a", "never"],
            "--dangerously-bypass-approvals-and-sandbox",
            None,
        ),
        (
            "codex",
            &["--approve-for-me"],
            "--dangerously-bypass-approvals-and-sandbox",
            None,
        ),
        (
            "claude",
            &["--permission-mode=dontAsk"],
            "--dangerously-skip-permissions",
            Some("CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT"),
        ),
        (
            "copilot",
            &["--allow-all-tools"],
            "--allow-all",
            Some("COPILOT_ALLOW_ALL"),
        ),
    ];
    for (harness, words, bypass, var) in narrower {
        let (intent, launched) = launch(harness, words);
        assert_ne!(
            intent["observation"]["note"], "permission-mismatch",
            "{harness} {words:?}: a narrower word is no mismatch: {intent}"
        );
        let argv = argv_of(&launched);
        for word in words {
            assert!(
                argv.contains(&(*word).to_owned()),
                "{harness}: {word} kept: {argv:?}"
            );
        }
        assert!(
            !argv.contains(&bypass.to_owned()),
            "{harness}: no bypass word: {argv:?}"
        );
        if let Some(var) = var {
            let value = launched_var(&launched, var);
            assert!(
                value.is_null() || value == "",
                "{harness}: no bypass environment ({var}={value}): {launched}"
            );
        }
    }
    let (intent, _) = launch("copilot", &["--yolo"]);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        intent["observation"]["note"], "permission-mismatch",
        "{intent}"
    );
    // Decision 124b (5), L1: a `native` posture whose words carry a narrower
    // permission word before a full-bypass one is a mismatch; the builder
    // reads every word, not the first.
    let (intent, _) = launch(
        "claude",
        &[
            "--permission-mode=dontAsk",
            "--dangerously-skip-permissions",
        ],
    );
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        intent["observation"]["note"], "permission-mismatch",
        "a full bypass after a narrower word is still a mismatch: {intent}"
    );
}

/// The pending the fleet fixture's transfer names, as `record-outcome`
/// restores it on a failure before retirement.
fn original_pending_of(runner: &Runner) -> Value {
    pending(runner.state_dir())
}

/// Decision 124b (6), R-U4g4 L2 and probe P3: a launch-failed path after the
/// record's pre-write rewrites the sidecar with a `status=` word, which a
/// later read settles as nothing started. A stop whose job-sidecar names
/// such a record reconciles rather than holding `possibly-started` for good;
/// the predecessor it never retired stands.
#[test]
fn a_launcher_record_with_a_status_word_settles_the_job() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let id = "stop-controller:overseer:3:1-1";
    let mut fleet = runner.fleet();
    fleet["intents"] = json!([{
        "id": id, "op": "stop-controller", "target": "overseer:3", "created_at": "2026-01-29T15:20:00Z", "outcome": "not-started",
        "obligations": {"standing": [{"kind": "job-sidecar", "role": "job"}], "discharged": [], "signalled": false},
    }]);
    runner.write_fleet(&fleet);
    let record = runner.state_dir().join("intents").join(format!("{id}.job"));
    std::fs::create_dir_all(record.parent().unwrap()).unwrap();
    // Byte for byte what job-unit.sh now leaves on its identity-unread path.
    std::fs::write(
        &record,
        "runner=setsid\nstatus=identity-unread\nline=runner=setsid reason=no-systemd-run\n",
    )
    .unwrap();
    let report = runner.reconcile_one();
    assert_ne!(
        report["intent"]["observation"]["job"], "possibly-started",
        "a record naming a status settles the job: {report}"
    );
    assert!(
        remaining(&report["intent"]["observation"], "job").is_null(),
        "the sidecar is discharged, nothing stands for it: {report}"
    );
}

/// Decision 124c (9), R-U4g4 Codex C1: the launcher-side handle writes only
/// while it still owns the intent. A stub launcher starts the real runtime
/// job, waits for its claim, pauses it, then returns its sidecar: the
/// launcher's identity write after the claim lands nothing, the caller is
/// answered `transfer-started` with the claimant as owner, and the claimant's
/// discharged set stands.
#[test]
fn an_early_job_claim_is_not_overwritten_by_the_launcher_write() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = Runner::new(&server, "stub-confirm");
    runner.verify = Some(30);
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let launcher = dir.path().join("job-unit");
    // The real job's claim is the barrier: the launcher returns only once
    // the fleet file records the claim (`handed_from` set), never on a count
    // alone; a claim that never lands fails the launch loudly.
    std::fs::write(&launcher, fixtures_held_launcher()).unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).unwrap();
    let request = transfer_request(&server, runner.state_dir());
    let out = runner.op_fleet_env(&request, &[("ORCH_JOB_UNIT", launcher.to_str().unwrap())]);
    let after = runner.fleet();
    let intent = after["intents"][0].clone();
    let id = intent["id"].as_str().unwrap().to_owned();
    let record = runner.state_dir().join("intents").join(format!("{id}.job"));
    if let Ok(pid) = std::fs::read_to_string(format!("{}.child", record.display())) {
        let _ = std::process::Command::new("kill")
            .args(["-KILL", pid.trim()])
            .status();
    }
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(
        answer["result"]["effect"]["started"], "transfer-started",
        "the claimant's state is the answer: {answer}"
    );
    assert_ne!(
        answer["result"]["effect"]["owner"], answer["result"]["effect"]["handed_from"],
        "the owner answered is the claimant: {answer}"
    );
    let standing = intent["obligations"]["standing"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert!(
        !standing.iter().any(|o| o["kind"] == "job"),
        "the claimed job was resurrected by the launcher's late write: {intent}"
    );
    assert_eq!(
        discharged_by(&intent, "claimed").len(),
        1,
        "the claim's discharge stands: {intent}"
    );
}

/// The stub launcher of the early-claim row: job-unit's argv contract, the
/// real job started as its child, the claim awaited on the fleet file, the
/// child paused, then its identity recorded and answered as job-unit does.
fn fixtures_held_launcher() -> String {
    [
        "#!/bin/bash",
        "set -u",
        "record=$3",
        "file=${10}",
        "intent=${12}",
        "shift 4",
        "\"$@\" </dev/null >/dev/null 2>&1 &",
        "pid=$!",
        "deadline=$((SECONDS + 60))",
        "claimed=0",
        "while (( SECONDS < deadline )); do",
        "  if jq -e --arg id \"$intent\" '.intents[] | select(.id==$id) | .handed_from != null' \"$file\" >/dev/null 2>&1; then claimed=1; break; fi",
        "  sleep .02",
        "done",
        "kill -STOP \"$pid\" 2>/dev/null || true",
        "printf '%s' \"$pid\" > \"$record.child\"",
        "if (( ! claimed )); then echo 'job-unit: fixture claim never landed' >&2; exit 4; fi",
        "row=$(cat \"/proc/$pid/stat\") || { echo 'job-unit: fixture child row unread' >&2; exit 4; }",
        "start=$(awk '{print $20}' <<<\"${row##*)}\")",
        "printf 'runner=setsid\\npid=%s\\nstart=ticks:%s\\n' \"$pid\" \"$start\" > \"$record\"",
        "printf 'runner=setsid pid=%s start=ticks:%s\\n' \"$pid\" \"$start\"",
        "",
    ]
    .join("\n")
}
