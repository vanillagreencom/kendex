//! Live-effect process tests of the controller lifetimes, each driven
//! through the `orch-runtime` executable against a private tmux server and
//! a stub harness: a self-succession started from the predecessor's own
//! pane and completed by the detached job, the succession rows, death
//! recovery with and without a recorded identity, the walled and off
//! refusals and the explicit stop, the first launch and the adoption. The
//! runtime's waits run on its own clock in the op and the job, so a row
//! reaches none of them: every wait here is a bounded poll of a child's own
//! signal, its bound the suite's (`SETTLE`, which the op's claim wait is
//! given too), and a stub a short bound must find ready is read through a
//! gate on its exec, never raced.
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

/// The bound a detached job's succession settles in, and the bound its
/// caller waits for the job's claim.
const SETTLE: Duration = Duration::from_secs(40);

/// The binary as every row runs it: the job's claim waited for as long as
/// the row waits for the intent, and the launch bound the production one. A
/// row that needs a bound to elapse sets its own.
fn suite_runner(server: &Server, stub: &str) -> Runner {
    let mut runner = Runner::new(server, stub);
    // The state folder lives inside the server's: the runner drops before
    // the server, and a stub or job the server still runs then writes into
    // a folder that goes with the server's, never a fresh one under TMPDIR.
    runner.dir =
        tempfile::tempdir_in(server.socket.parent().expect("the server's folder")).unwrap();
    runner.verify = None;
    runner.env.push((
        "AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(),
        SETTLE.as_secs().to_string(),
    ));
    runner
}

/// Gate the runner's readiness on the stub holding its pane: the tmux shim
/// answers the job's first pane-field read of a pane it opened only once
/// `/proc/<pane pid>/comm` names the harness, so a short launch bound
/// measures what the stub does once it runs, never its start.
fn gated_readiness(runner: &mut Runner) {
    let opened = runner.state_dir().join("hold.opened");
    runner.tools = Some(fixtures().join("tmux-hold"));
    runner.env.extend([
        ("TMUX_REAL".to_owned(), which_tmux()),
        ("TMUX_HOLD_OPENED".to_owned(), opened.display().to_string()),
        ("TMUX_HOLD_READY_COMM".to_owned(), "claude".to_owned()),
    ]);
}

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

fn plant(runner: &Runner, record: Value) {
    let mut fleet = runner.fleet();
    fleet["overseer"] = record;
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    runner.write_fleet(&fleet);
}

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

/// The refusal a run printed: the key after the program's name on the first
/// `orch-runtime: ` line of stderr, `orch-runtime: <key> field=value...`; a
/// settings notice may stand ahead of it.
fn refusal_key(out: &std::process::Output) -> String {
    let answer = reply(out);
    assert_eq!(answer["ok"], false, "{answer}");
    let err = stderr(out);
    let line = err
        .lines()
        .find(|line| line.starts_with("orch-runtime: "))
        .unwrap_or_else(|| panic!("no refusal line: {err}"));
    line.split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_owned()
}

/// The predecessor here is a stub harness in a pane that runs the `op` as a
/// foreground child, as the overseer's shell tool does. The op hands the
/// effect to a detached job and answers `transfer-started`; the job types
/// the brief, retires the predecessor once the runner's turn stands, whose
/// exit closes the pane the op asked from, and completes the succession
/// from beyond it. The tmux shim holds the job at each `send-keys`: the
/// launch line typed into the runner's window, released at once, and the
/// brief, held while the predecessor still runs.
#[test]
fn a_self_succession_from_the_predecessors_own_pane_completes() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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
    words.push(format!("PATH={}", support::tool_path(&[holddir.as_path()])));
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
    release_hold(&fifo, secs(30), evidence);
    // The op answers at once, the effect handed to the job that now owns
    // the intent.
    let answer = wait_reply(&out, secs(30), evidence);
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
    assert!(live(pid), "the predecessor runs until the runner's turn");
    assert_eq!(
        start_of(owner_pid),
        owner["start"],
        "under its recorded identity"
    );
    // The second hold, the brief, typed while the predecessor still runs:
    // released, the job confirms the turn, retires the predecessor, whose
    // exit closes the pane the op asked from, and publishes from beyond it.
    release_hold(&fifo, secs(30), evidence);
    wait_until("the predecessor stopped", secs(20), || !live(pid));
    wait_until("the predecessor's pane closed", secs(10), || {
        !server.panes().contains(&pane)
    });
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

/// The repeat reconciles against the live owner and touches nothing; the
/// runner that records no turn for its brief is never published and the
/// predecessor is never retired for it: the runner is stopped and the
/// predecessor stays in control.
#[test]
fn a_repeated_request_reads_the_job_as_owner_live_and_a_lost_brief_keeps_the_runner() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-mute");
    runner.verify = Some(3);
    gated_readiness(&mut runner);
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    // The tmux shim holds the job at each `send-keys`, writing the mark just
    // before it: the launch line typed into the runner's window, held until
    // the repeat has read the record, so the repeat meets a live owner and no
    // other writer however the two processes are scheduled; then the brief.
    // The mark is taken away before the first release, so its return says
    // the first hold's reader is gone and the second release reaches the
    // second hold. A held tmux call ends at agent-runtime's 15 s command
    // bound, so the first hold spans the repeat alone.
    let fifo = runner.state_dir().join("hold.fifo");
    let mark = runner.state_dir().join("hold.mark");
    mkfifo(&fifo);
    let hold = [
        ("TMUX_HOLD_FIFO", fifo.to_str().unwrap()),
        ("TMUX_HOLD_MARK", mark.to_str().unwrap()),
        ("TMUX_HOLD_VERB", "send-keys"),
    ];
    let started = runner.transfer_started_env(&request, &hold);
    wait_until("the job reached the launch line", SETTLE, || mark.exists());
    let answer = reply(&runner.op_fleet(&request));
    assert_eq!(answer["ok"], true, "{answer}");
    let repeat = &answer["result"]["effect"]["report"];
    assert_eq!(repeat["intent"]["outcome"], "unconfirmed", "{repeat}");
    assert_eq!(repeat["intent"]["observation"]["note"], "owner-live");
    assert_eq!(repeat["intent"]["owner"], started["owner"]);
    std::fs::remove_file(&mark).unwrap();
    release_hold(&fifo, secs(10), || runner.fleet().to_string());
    wait_until("the job reached the brief", SETTLE, || mark.exists());
    release_hold(&fifo, secs(10), || runner.fleet().to_string());
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "brief-unconfirmed");
    assert_eq!(intent["observation"]["runner"], "stopped");
    assert_eq!(intent["phase"]["phase"], "delivered");
    assert!(live(predecessor.pid()), "never retired without the turn");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 3, "nothing published");
    assert!(
        overseer["pending"].get("runner").is_none(),
        "no runner is kept: {overseer}"
    );
}

#[test]
fn a_succession_retires_the_predecessor_then_publishes_the_successor() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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
    // The successor's identity is the runner's own process, written as a
    // number.
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert!(overseer["pending"].is_null(), "pending dropped on publish");
    // The intent recorded every phase on its way.
    assert_eq!(intent["phase"]["phase"], "identity-read");
    assert_eq!(intent["phase"]["pid"], server.pane_pid(&pane));
    assert_eq!(intent["cause"], "live");
}

/// The brief is typed into the runner while the predecessor still runs, the
/// predecessor is retired only once the runner's own file records that turn,
/// and the successor is published after.
#[test]
fn a_succession_types_the_brief_before_retirement_and_retires_on_the_runner_s_turn() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    gated_readiness(&mut runner);
    runner.init_fleet();
    let brief = runner.state_dir().join("handoff.md");
    std::fs::write(&brief, "HANDOFF\n").unwrap();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let mut request = transfer_request(&server, runner.state_dir());
    request["brief_file"] = json!(brief.display().to_string());
    // The tmux shim holds the job at each `send-keys`, writing the mark just
    // before it: the launch line, then the brief.
    let fifo = runner.state_dir().join("hold.fifo");
    let mark = runner.state_dir().join("hold.mark");
    mkfifo(&fifo);
    let hold = [
        ("TMUX_HOLD_FIFO", fifo.to_str().unwrap()),
        ("TMUX_HOLD_MARK", mark.to_str().unwrap()),
        ("TMUX_HOLD_VERB", "send-keys"),
    ];
    runner.transfer_started_env(&request, &hold);
    wait_until("the job reached the launch line", SETTLE, || mark.exists());
    std::fs::remove_file(&mark).unwrap();
    release_hold(&fifo, secs(10), || runner.fleet().to_string());
    wait_until("the job reached the brief", SETTLE, || mark.exists());
    assert!(
        live(predecessor.pid()),
        "the brief is typed while the predecessor runs"
    );
    assert_eq!(
        runner.fleet()["intents"][0]["phase"]["phase"],
        "delivering",
        "{}",
        runner.fleet()
    );
    release_hold(&fifo, secs(10), || runner.fleet().to_string());
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(predecessor.pid()), "retired after the runner's turn");
    assert_eq!(
        runner.stub_turns(runner.state_dir(), runner.state_dir()),
        vec!["HANDOFF".to_owned()],
        "the runner recorded the brief as its turn"
    );
    assert_eq!(runner.fleet()["overseer"]["generation"], 4);
    assert_eq!(intent["phase"]["phase"], "identity-read");
}

/// A successor whose first turn meets a login wall is refused before
/// retirement with its cause and the account it ran on: the predecessor
/// keeps running, the runner's window is closed, the record stands as it
/// was, and the owner is told once.
#[test]
fn a_successor_meeting_a_login_wall_at_its_first_turn_is_refused_before_retirement_with_the_predecessor_live()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-unsigned");
    let mail_log = runner.state_dir().join("lane-mail.log");
    runner
        .env
        .push(("LANE_MAIL_LOG".to_owned(), mail_log.display().to_string()));
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let before = runner.fleet()["overseer"].clone();
    runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    let observation = &intent["observation"];
    assert_eq!(observation["note"], "successor-not-signed-in", "{intent}");
    assert_eq!(observation["cause"], "auth-wall");
    assert_eq!(
        observation["account"],
        runner.state_dir().display().to_string()
    );
    assert_eq!(observation["retired"], false);
    assert!(live(predecessor.pid()), "the predecessor keeps running");
    let runner_pane = intent["phase"]["pane"].as_str().unwrap().to_owned();
    assert!(
        !server.panes().contains(&runner_pane),
        "the runner's window is closed"
    );
    assert_eq!(runner.fleet()["overseer"], before, "the record as it stood");
    assert_eq!(intent["notice"]["key"], "successor-not-signed-in");
    assert_eq!(intent["notice"]["owner"], "sent");
    let calls = std::fs::read_to_string(&mail_log).unwrap();
    assert_eq!(
        calls
            .lines()
            .filter(|l| l.starts_with("notice --item overseer --to owner"))
            .count(),
        1,
        "{calls}"
    );
}

/// A named account holding no credential its harness signs in with is no
/// successor: refused `successor-not-signed-in` before any window opens or
/// any trust record is written into it, the predecessor running. The same
/// account under a launch environment that carries a token is left to the
/// first turn, which signs it in, and the outcome names the token.
#[test]
fn a_named_account_holding_no_credential_opens_nothing_and_writes_no_trust_file() {
    for token in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = suite_runner(&server, "stub-confirm");
        runner.init_fleet();
        if token {
            let out = tmux(
                &server.socket,
                &[
                    "set-environment",
                    "-g",
                    "CLAUDE_CODE_OAUTH_TOKEN",
                    "planted",
                ],
            );
            assert!(out.status.success(), "{}", stderr(&out));
        }
        let account = runner.state_dir().join("unsigned");
        std::fs::create_dir_all(&account).unwrap();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let mut unsigned = pending(runner.state_dir());
        unsigned["account"] = json!(account.display().to_string());
        unsigned["home"] = json!(account.display().to_string());
        let mut fleet = runner.fleet();
        fleet["overseer"]["pending"] = unsigned.clone();
        runner.write_fleet(&fleet);
        let panes = server.panes();
        let mut request = transfer_request(&server, runner.state_dir());
        request["expected"]["pending"] = unsigned.clone();
        request["successor"] = unsigned;
        runner.transfer_started(&request);
        let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
        if token {
            assert_eq!(intent["outcome"], "confirmed", "{intent}");
            assert_eq!(
                intent["observation"]["sign_in"],
                json!({"token": "CLAUDE_CODE_OAUTH_TOKEN"}),
                "{intent}"
            );
            continue;
        }
        assert_eq!(intent["outcome"], "failed", "{intent}");
        let observation = &intent["observation"];
        assert_eq!(observation["note"], "successor-not-signed-in", "{intent}");
        assert_eq!(
            observation["fields"],
            json!({"account": account.display().to_string(), "cause": "no-credential"})
        );
        assert!(
            std::fs::symlink_metadata(account.join(".claude.json")).is_err(),
            "no trust record was written into the account"
        );
        assert_eq!(server.panes(), panes, "nothing opened");
        assert!(live(predecessor.pid()), "the predecessor keeps running");
    }
}

/// A runner a wrapper handed another account than its launch named is
/// refused before its brief is typed, the predecessor left running.
#[test]
fn a_successor_running_another_account_than_its_launch_named_is_refused_before_retirement() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-rehomed");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    let account = runner.state_dir().display().to_string();
    assert_eq!(intent["observation"]["note"], "successor-wrong-account");
    assert_eq!(intent["observation"]["account"], account.as_str());
    assert_eq!(
        intent["observation"]["found"],
        format!("{account}-wrapped"),
        "{intent}"
    );
    assert_eq!(
        intent["phase"]["phase"], "window-opened",
        "no brief was typed"
    );
    assert!(live(predecessor.pid()), "the predecessor keeps running");
}

/// A succession whose job ended while its delivered brief waited for the
/// runner's turn, the predecessor still running, is abandoned by the
/// reconcile: the runner stopped, the predecessor left in control, nothing
/// published over it.
#[test]
fn a_reconcile_at_delivered_with_the_predecessor_live_abandons_the_runner() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-mute");
    runner.verify = Some(30);
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let started = runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    wait_until("the brief delivered", SETTLE, || {
        runner.fleet()["intents"][0]["phase"]["phase"] == "delivered"
    });
    let job = started["owner"]["pid"].as_u64().unwrap() as u32;
    let _ = std::process::Command::new("kill")
        .args(["-KILL", "--", &format!("-{job}")])
        .status();
    wait_until("the job ended", SETTLE, || !live(job));
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"],
        "abandoned-before-retirement"
    );
    assert_eq!(report["intent"]["observation"]["retired"], false);
    assert!(live(predecessor.pid()), "the predecessor keeps running");
    let runner_pane = report["intent"]["phase"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!server.panes().contains(&runner_pane), "the runner stopped");
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
}

/// A precondition read before retirement refuses `failed` with the
/// predecessor in control and no runner left. The job reads them, so its
/// environment carries each row's setting; the bound is short, since the
/// fourth row needs it to elapse over a stub that never draws.
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
            env: &[(
                "AGENT_RUNTIME_HARNESS_BINARIES",
                "claude=/nonexistent/bin/claude",
            )],
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
            env: &[("AGENT_RUNTIME_HARNESS_BINARIES", "claude=STUB_UNCONFIRMED")],
            brief: None,
            cwd: None,
            note: "successor-not-ready",
        },
    ];
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        runner.verify = Some(1);
        runner.init_fleet();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let mut request = transfer_request(&server, runner.state_dir());
        if let Some(cwd) = row.cwd {
            let mut p = pending(runner.state_dir());
            p["cwd"] = json!(cwd);
            p["handoff"] = json!(
                runner
                    .state_dir()
                    .join("tmp/handoffs/OVERSEER-HANDOFF.md")
                    .display()
                    .to_string()
            );
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

/// The predecessor's handles join the intent's set at the start of its
/// retirement, before the first signal. A recorded start that is not the
/// live process's reads stale: nothing is signalled, the waiting runner is
/// stopped, and the intent holds `predecessor-not-retired` with the
/// recorded identity standing on one stale reading. The reconcile's second
/// independent reading settles that identity, and the succession, its
/// runner gone, fails after retirement; the live process under the reused
/// pid is never signalled.
#[test]
fn a_succession_that_cannot_retire_the_predecessor_holds_it_and_signals_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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
    // The second independent reading settles the stale identity: the
    // recorded controller is gone, and with the runner gone too the
    // succession fails after retirement, the live process still untouched.
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["note"], "successor-exited");
    assert_eq!(report["intent"]["observation"]["retired"], true);
    assert_eq!(runner.fleet()["overseer"]["generation"], 3);
    assert!(live(predecessor.pid()), "still never signalled");
}

/// A neighbouring lead session in the same home and directory takes turns
/// throughout; they never confirm the runner's delivery, which is read in
/// the runner's own file alone. The runner is read ready through the gate,
/// so the short bound measures the turn that never comes.
#[test]
fn a_neighbour_session_s_turns_never_confirm_the_runner_s_delivery() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-mute");
    runner.verify = Some(2);
    gated_readiness(&mut runner);
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
    assert_eq!(intent["outcome"], "failed", "{intent}");
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
    assert!(live(predecessor.pid()), "never retired without the turn");
    assert_eq!(
        runner.fleet()["overseer"]["generation"],
        3,
        "nothing published"
    );
}

/// A neighbouring lead session holding more turns than the runner is kept
/// the newest file by replies; the runner's recorded turn in its own file
/// still publishes the succession.
#[test]
fn a_neighbour_holding_more_turns_never_hides_the_runner_s_recorded_turn() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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

/// In a dead-cause recovery the generation-bound exit record proves it
/// terminal whatever the pane shows; so does the recorded pane gone on the
/// proven server. A pane standing on that server is an unknown stop,
/// refused before anything opens; absence on a server that is not the
/// recorded one proves nothing. The successor's readiness is read through
/// the gate: the retirement judgement is what each row proves.
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
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        gated_readiness(&mut runner);
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

/// A pane where the recorded harness ran and its shell now holds alone: a
/// stub that hands its terminal to a shell, waited until the shell has
/// replaced it.
fn shell_left(server: &Server, runner: &Runner) -> String {
    let pane = server.open_stub(
        "overseer",
        "stub-shell",
        runner.state_dir(),
        runner.state_dir(),
    );
    await_named(server, &pane, "bash");
    pane
}

/// A pane the stub harness holds, drawn.
fn harness_held(server: &Server, runner: &Runner) -> String {
    let pane = server.open_stub(
        "overseer",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    server.await_composer(&pane);
    pane
}

/// A pane whose process exited, which its server keeps dead.
fn kept_dead(server: &Server, runner: &Runner) -> String {
    server.open_kept_dead("overseer", runner.state_dir())
}

/// A recorded controller with no identity whose pane its shell holds alone,
/// or whose pane its server keeps dead, has ended: a start replaces the
/// record and closes the predecessor's window, a dead-cause transfer
/// proceeds with the predecessor proven `harness-gone` or `pane-dead`, and
/// a live-cause transfer refuses `predecessor-not-live`, since an ended
/// controller is the dead recovery's. The same record over a pane the
/// harness still holds refuses the start `overseer-live` and the dead
/// transfer `predecessor-identity-missing`, as an unknown stop.
#[test]
fn a_recorded_controller_whose_pane_holds_only_its_shell_or_is_kept_dead_is_replaced_and_one_holding_a_harness_is_not()
 {
    struct Row {
        name: &'static str,
        /// The recorded pane, on the row's own server.
        pane: fn(&Server, &Runner) -> String,
        /// `start`, or a transfer's cause.
        mode: &'static str,
        outcome: &'static str,
        note: &'static str,
        retired_by: Option<&'static str>,
    }
    let rows = [
        Row {
            name: "start over the shell",
            pane: shell_left,
            mode: "start",
            outcome: "confirmed",
            note: "successor-confirmed",
            retired_by: Some("harness-gone"),
        },
        Row {
            name: "start over the harness",
            pane: harness_held,
            mode: "start",
            outcome: "failed",
            note: "overseer-live",
            retired_by: None,
        },
        Row {
            name: "dead transfer over the shell",
            pane: shell_left,
            mode: "dead",
            outcome: "confirmed",
            note: "successor-confirmed",
            retired_by: Some("harness-gone"),
        },
        Row {
            name: "dead transfer over the harness",
            pane: harness_held,
            mode: "dead",
            outcome: "failed",
            note: "predecessor-identity-missing",
            retired_by: None,
        },
        Row {
            name: "live transfer over the shell",
            pane: shell_left,
            mode: "live",
            outcome: "failed",
            note: "predecessor-not-live",
            retired_by: None,
        },
        Row {
            name: "start over the kept dead pane",
            pane: kept_dead,
            mode: "start",
            outcome: "confirmed",
            note: "successor-confirmed",
            retired_by: Some("pane-dead"),
        },
        Row {
            name: "dead transfer over the kept dead pane",
            pane: kept_dead,
            mode: "dead",
            outcome: "confirmed",
            note: "successor-confirmed",
            retired_by: Some("pane-dead"),
        },
        Row {
            name: "live transfer over the kept dead pane",
            pane: kept_dead,
            mode: "live",
            outcome: "failed",
            note: "predecessor-not-live",
            retired_by: None,
        },
    ];
    for row in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        if row.mode != "start" {
            gated_readiness(&mut runner);
        }
        runner.init_fleet();
        let pane = (row.pane)(&server, &runner);
        let record = record_on(&server, runner.state_dir(), &pane, None);
        let intent = if row.mode == "start" {
            let mut fleet = runner.fleet();
            fleet["overseer"] = record.clone();
            runner.write_fleet(&fleet);
            let brief = runner.state_dir().join("brief.md");
            std::fs::write(&brief, "START HERE\n").unwrap();
            effect_report(&runner.op_fleet(&json!({
                "op": "start-controller",
                "controller": pending(runner.state_dir()),
                "brief_file": brief.display().to_string(),
            })))["intent"]
                .clone()
        } else {
            plant(&runner, record.clone());
            runner.transfer_started(&request_for(&record, runner.state_dir(), row.mode));
            runner.wait_intent_settled("request-transfer:", SETTLE)
        };
        assert_eq!(intent["outcome"], row.outcome, "{}: {intent}", row.name);
        assert_eq!(intent["observation"]["note"], row.note, "{}", row.name);
        let overseer = runner.fleet()["overseer"].clone();
        match row.retired_by {
            Some(by) => {
                assert_eq!(intent["observation"]["retired_by"], by, "{}", row.name);
                assert_eq!(overseer["generation"], 4, "{}", row.name);
                assert_ne!(overseer["pane"], json!(pane), "{}: replaced", row.name);
                assert!(
                    !server.panes().contains(&pane),
                    "{}: the predecessor's window closed",
                    row.name
                );
            }
            None => {
                assert_eq!(overseer["generation"], 3, "{}", row.name);
                assert_eq!(overseer["pane"], json!(pane), "{}: kept", row.name);
            }
        }
    }
}

/// An adoption over a recorded controller with no identity whose pane its
/// shell holds alone binds the adopted pane; one whose pane the harness
/// holds refuses `overseer-live`. A stop of the ended controller is
/// confirmed by the same proof and records `off`.
#[test]
fn an_ended_controller_with_no_identity_is_adopted_over_and_stopped_by_its_bare_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let adopted = harness_held(&server, &runner);
    let request = json!({
        "op": "adopt-controller",
        "pane": adopted,
        "harness": "claude",
        "cwd": runner.state_dir().display().to_string(),
    });
    let held = harness_held(&server, &runner);
    let mut fleet = runner.fleet();
    fleet["overseer"] = record_on(&server, runner.state_dir(), &held, None);
    runner.write_fleet(&fleet);
    assert_eq!(refusal_key(&runner.op_fleet(&request)), "overseer-live");
    assert_eq!(
        runner.fleet()["overseer"]["pane"],
        json!(held),
        "nothing written"
    );
    let ended = shell_left(&server, &runner);
    let mut fleet = runner.fleet();
    fleet["overseer"] = record_on(&server, runner.state_dir(), &ended, None);
    runner.write_fleet(&fleet);
    let answer = reply(&runner.op_fleet(&request));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["result"]["report"]["generation"], 4);
    assert_eq!(runner.fleet()["overseer"]["pane"], json!(adopted));

    let mut fleet = runner.fleet();
    fleet["overseer"] = record_on(&server, runner.state_dir(), &ended, None);
    fleet["intents"] = json!([]);
    runner.write_fleet(&fleet);
    runner.op_fleet(&json!({"op": "stop-controller"}));
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(intent["observation"]["retired_by"], "harness-gone");
    assert_eq!(runner.fleet()["overseer"]["off"]["generation"], 3);
}

/// The takeover brief an overseer's transfer holds is written once its
/// intent stands; a brief that cannot be written refuses `io-failed
/// operation=write-brief` naming that intent as `persisted_intent`, so the
/// caller's reconcile finds it, and no job starts.
#[test]
fn a_held_brief_that_cannot_be_written_names_the_intent_it_left_standing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    std::fs::write(runner.state_dir().join("intents"), "not a directory").unwrap();
    let elsewhere = dir.path().join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let mut request = transfer_request(&server, runner.state_dir());
    request["cause"] = json!("walled");
    request["exclude_account"] = json!(elsewhere.display().to_string());
    let answer = reply(&runner.op_fleet(&request));
    assert_eq!(answer["refusal"]["key"], "io-failed", "{answer}");
    let fields = &answer["refusal"]["fields"];
    let named = |name: &str| {
        fields
            .as_array()
            .and_then(|all| all.iter().find(|pair| pair[0] == name))
            .map(|pair| pair[1].clone())
            .unwrap_or(Value::Null)
    };
    assert_eq!(named("operation"), "write-brief", "{answer}");
    let open = runner.fleet()["intents"]
        .as_array()
        .and_then(|all| {
            all.iter()
                .find(|i| {
                    i["id"]
                        .as_str()
                        .is_some_and(|id| id.starts_with("request-transfer:"))
                        && !i["completed_at"].is_string()
                })
                .cloned()
        })
        .unwrap_or(Value::Null);
    assert_eq!(named("persisted_intent"), open["id"], "{answer} {open}");
    assert!(open["id"].is_string(), "the intent stands: {open}");
    assert!(live(predecessor.pid()), "no job retired the predecessor");
}

/// `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off` refuses a transfer before any transition,
/// so the record and the intents directory are as they were; a stop under
/// the same setting is admitted.
#[test]
fn succession_off_refuses_a_transfer_and_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let path = runner.state_dir().join("workflow-state-oversee.json");
    let before = std::fs::read_to_string(&path).unwrap();
    let out = runner.op_fleet_env(
        &transfer_request(&server, runner.state_dir()),
        &[("AGENT_RUNTIME_CONTROLLER_SUCCESSION", "off")],
    );
    assert_eq!(refusal_key(&out), "succession-off");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), before);
    assert!(
        !runner.state_dir().join("intents").exists(),
        "no job request was written"
    );
    assert!(live(predecessor.pid()));
    // A key the transfer's effect reads, outside its form, refuses the
    // transfer the same way before any transition; `state path`, which
    // reads none, answers under it.
    for (key, value) in [
        ("AGENT_RUNTIME_CONTROLLER_SUCCESSION", "maybe"),
        ("AGENT_RUNTIME_QUESTION_TOOL", "lane"),
        ("AGENT_RUNTIME_JOB_CLAIM_SECS", "0"),
        ("AGENT_RUNTIME_TMUX_VERIFY_SECS", "1.5"),
        ("ORCH_LANE_CLOSE_SECS", "-1"),
        ("AGENT_RUNTIME_LAUNCH_PERMISSION", "yes"),
        ("AGENT_RUNTIME_HARNESS_BINARIES", "claude=bin/claude"),
    ] {
        let env = [(key, value)];
        let out = runner.op_fleet_env(&transfer_request(&server, runner.state_dir()), &env);
        let answer = reply(&out);
        assert_eq!(
            answer["refusal"]["key"], "setting-invalid",
            "{key}: {answer}"
        );
        assert_eq!(
            answer["refusal"]["fields"],
            json!([["key", key], ["value", value]]),
            "{key}"
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), before, "{key}");
        assert!(!runner.state_dir().join("intents").exists(), "{key}");
        let control = runner.run_env(&["state", "path", "--fleet"], &env);
        assert!(control.status.success(), "{key}: {}", stderr(&control));
    }
    let started = reply(&runner.op_fleet_env(
        &json!({"op": "stop-controller"}),
        &[("AGENT_RUNTIME_CONTROLLER_SUCCESSION", "off")],
    ));
    assert_eq!(
        started["result"]["effect"]["started"], "stop-started",
        "{started}"
    );
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(predecessor.pid()));
}

/// The `setsid` route's world for a job that never claims: `bin`, for the
/// op's `PATH`, holds the `setsid-sleeper` fixture (a `setsid` that logs
/// its argv to `SETSID_LOG` and execs a sleep the row owns) and its
/// `loginctl` saying the user manager does not linger. Returns `bin` and
/// the log.
fn sleeper_world(dir: &Path) -> (std::path::PathBuf, std::path::PathBuf) {
    let bin = dir.join("sleeper-bin");
    std::fs::create_dir_all(&bin).unwrap();
    for tool in ["setsid", "loginctl"] {
        std::os::unix::fs::symlink(fixtures().join("setsid-sleeper").join(tool), bin.join(tool))
            .unwrap();
    }
    (bin, dir.join("setsid.log"))
}

/// The launches the `setsid` fixture logged.
fn launches(log: &Path) -> usize {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .count()
}

/// The pid the standing job obligation of the one open intent names, as
/// the fleet records it.
fn standing_job_pid(runner: &Runner) -> u32 {
    let intent = runner.fleet()["intents"][0].clone();
    intent["obligations"]["standing"]
        .as_array()
        .and_then(|rows| rows.iter().find(|o| o["kind"] == "job-group"))
        .and_then(|o| o["pid"].as_u64())
        .unwrap_or_else(|| panic!("a job group stands: {intent}")) as u32
}

/// End the sleeper the row owns by its pid and wait until it reads gone.
fn end_sleeper(pid: u32) {
    let _ = std::process::Command::new("kill")
        .args(["-KILL", &pid.to_string()])
        .status();
    wait_until("the sleeper ended", secs(10), || !live(pid));
}

/// One outstanding-job predicate serves both routes, so a repeated stop
/// whose job never claimed reconciles that job rather than starting a
/// second; the launcher spawns once.
#[test]
fn a_repeated_stop_with_an_unclaimed_job_does_not_start_a_second_job() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let (bin, log) = sleeper_world(runner.state_dir());
    runner.tools = Some(bin);
    runner
        .env
        .push(("AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(), "1".to_owned()));
    runner
        .env
        .push(("SETSID_LOG".to_owned(), log.display().to_string()));
    // The job never claims within the bound: it stands by its identity, the
    // stop intent open.
    let out = runner.op_fleet(&json!({"op": "stop-controller"}));
    assert_eq!(refusal_key(&out), "job-unclaimed", "{}", stderr(&out));
    let job = standing_job_pid(&runner);
    assert!(live(job), "the job the launcher recorded runs");
    // A job whose own settings put its effect's bound outside its form
    // refuses by key and value before its claim: the intent stays its
    // caller's, unclaimed.
    let before = runner.fleet();
    let intent = before["intents"][0]["id"].as_str().unwrap().to_owned();
    let mail_program = fixtures().join("lane-mail-quiet/lane-mail");
    let mail_root = runner.state_dir().display().to_string();
    let refused = runner.run_env(
        &[
            "job",
            "--fleet",
            "--intent",
            &intent,
            "--mail-program",
            mail_program.to_str().unwrap(),
            "--mail-root",
            &mail_root,
        ],
        &[("AGENT_RUNTIME_JOB_CLAIM_SECS", "0")],
    );
    let refusal = &reply(&refused)["refusal"];
    assert_eq!(refusal["key"], "setting-invalid", "{}", stderr(&refused));
    assert_eq!(
        refusal["fields"],
        json!([["key", "AGENT_RUNTIME_JOB_CLAIM_SECS"], ["value", "0"]])
    );
    assert_eq!(runner.fleet(), before, "the refused job claimed nothing");
    // The repeated stop reconciles the standing job and starts no second one.
    let out2 = runner.op_fleet(&json!({"op": "stop-controller"}));
    let report = effect_report(&out2);
    assert_eq!(
        report["intent"]["observation"]["job"], "possibly-started",
        "{report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "job")["pid"],
        job,
        "the standing group is what holds the repeat: {report}"
    );
    assert_eq!(launches(&log), 1, "a second job while the first stands");
    assert!(live(predecessor.pid()), "nothing retired the predecessor");
    end_sleeper(job);
}

/// The explicit stop retires the controller exactly by its identity and
/// records `off`; a death recovery then refuses `controller-off`; the one
/// way back is `start-controller`, whose confirmation clears the mark.
#[test]
fn stop_controller_retires_exactly_and_records_off_which_death_recovery_honours() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    let bystander = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    // The stop runs as a detached job: the reply is its start, the outcome
    // is read off the intent once the job recorded it.
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

/// The terminal proof confirms the stop (the pane gone on the proven
/// server) and `off` is recorded; a pane standing with nothing naming what
/// runs in it fails the stop, since an exact retirement has nothing to act
/// on, and records nothing.
#[test]
fn stop_controller_without_an_identity_takes_the_proof_or_fails() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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

/// A controller the real `start-controller` opens and publishes on the
/// runner's server: its pane.
fn started_controller(runner: &Runner) -> String {
    let report = effect_report(&runner.op_fleet(&json!({
        "op": "start-controller",
        "controller": pending(runner.state_dir()),
    })));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    runner.fleet()["overseer"]["pane"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// End the published controller's harness as a crash does, by the identity
/// its record names, and wait for its pane to stand dead or to go.
fn crash_controller(server: &Server, runner: &Runner, pane: &str) {
    let pid = runner.fleet()["overseer"]["harness_pid"]
        .as_u64()
        .expect("the published identity");
    let out = std::process::Command::new("kill")
        .args(["-KILL", &pid.to_string()])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    wait_until("the harness's pane ended", SETTLE, || {
        server.pane_dead(pane) || !server.panes().iter().any(|p| p == pane)
    });
}

/// A session whose one window is the controller's, its creator's own window
/// closed after the start, outlives the controller's harness: the published
/// pane is kept dead, so the watch reads the death and its recovery opens
/// the successor in that same session, then closes the dead window, and the
/// successor's window stands alone.
#[test]
fn a_controller_alone_in_its_session_outlives_its_harness_and_is_recovered_there() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    runner.tools = Some(bin);
    runner.env.extend(env);
    let predecessor = started_controller(&runner);
    server.close_birth_window();
    assert_eq!(server.session_panes(), vec![predecessor.clone()]);
    crash_controller(&server, &runner, &predecessor);
    let intent = watched_transfer(&runner);
    assert_eq!(intent["cause"], "dead", "{intent}");
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let successor = runner.fleet()["overseer"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(successor, predecessor);
    assert_eq!(
        server.session_panes(),
        vec![successor],
        "the dead window is closed and the successor's alone stands"
    );
}

/// A completed hand-over leaves one controller window: the predecessor's
/// pane, kept past its harness, has its window closed by the retirement,
/// and the successor's window stands alone in the session.
#[test]
fn a_completed_hand_over_closes_the_kept_predecessor_and_leaves_one_controller_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = started_controller(&runner);
    server.close_birth_window();
    let mut fleet = runner.fleet();
    fleet["overseer"]["pending"] = pending(runner.state_dir());
    runner.write_fleet(&fleet);
    let record = runner.fleet()["overseer"].clone();
    runner.transfer_started(&request_for(&record, runner.state_dir(), "live"));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let successor = runner.fleet()["overseer"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(successor, predecessor);
    assert_eq!(
        server.session_panes(),
        vec![successor],
        "the predecessor's window is gone and one controller window stands"
    );
}

/// An explicit stop of a published controller leaves no controller window:
/// the pane kept past its harness has its window closed by the stop, and
/// the session holds its creator's window alone.
#[test]
fn a_stop_closes_the_kept_controller_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let birth = server.session_panes();
    started_controller(&runner);
    runner.op_fleet(&json!({"op": "stop-controller"}));
    let intent = runner.wait_intent_settled("stop-controller:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(server.session_panes(), birth, "no controller window stands");
}

/// The first launch of a controller on a fleet that recorded none publishes
/// generation 1 with the runner's identity; a start over a controller whose
/// identity reads live fails `overseer-live` before anything opens.
#[test]
fn start_controller_opens_the_first_controller_and_refuses_over_a_live_one() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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
        "a bare fleet's record names no session"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 1);
    assert_eq!(overseer["harness"], "claude");
    assert_eq!(overseer["server"], server.pid.to_string());
    let pane = overseer["pane"].as_str().unwrap().to_owned();
    assert_eq!(overseer["harness_pid"], server.pane_pid(&pane));
    assert_eq!(overseer["model"], "opus");
    assert_eq!(
        runner.stub_turns(runner.state_dir(), runner.state_dir()),
        vec!["START HERE".to_owned()],
        "the brief was delivered"
    );
    // Over a live controller: nothing opens, the record stands.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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

/// A controller's start builds its directory's own install before its
/// window, through the preparation a lane's launch shares: the orch and
/// agent-runtime packages linked where an apply puts them, orch's one real
/// setup over agent-runtime's planted cargo. A build that fails is `failed` before
/// retirement with the setup's refusal, nothing opened.
#[test]
fn a_controller_start_whose_install_does_not_build_opens_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let packages = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let skills = runner.state_dir().join(".agents/skills");
    std::fs::create_dir_all(&skills).unwrap();
    for package in ["orch", "agent-runtime"] {
        std::os::unix::fs::symlink(packages.join(package), skills.join(package)).unwrap();
    }
    let tools = dir.path().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    std::os::unix::fs::symlink(
        packages.join("agent-runtime/tests/setup/cargo"),
        tools.join("cargo"),
    )
    .unwrap();
    runner.tools = Some(tools);
    runner.env.extend([
        (
            "AGENT_RUNTIME_CACHE".to_owned(),
            dir.path().join("cache").display().to_string(),
        ),
        (
            "FAKE_CARGO_LOG".to_owned(),
            dir.path().join("cargo.log").display().to_string(),
        ),
        ("FAKE_CARGO_EXIT".to_owned(), "1".to_owned()),
    ]);
    let report = effect_report(&runner.op_fleet(&json!({
        "op": "start-controller",
        "controller": pending(runner.state_dir()),
    })));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    let observation = &report["intent"]["observation"];
    assert_eq!(observation["note"], "runtime-unbuilt", "{report}");
    assert_eq!(observation["retired"], false);
    assert!(
        observation["fields"]["detail"]
            .as_str()
            .is_some_and(|line| line.starts_with("agent-runtime-setup: build-failed status=1 key=")),
        "the setup's own refusal, its first build's: {report}"
    );
    assert_eq!(server.panes().len(), 1, "nothing opened");
}

/// A controller's start on a computer with no `tmux` refuses `unready`
/// naming its install before it claims: the fleet's record is as it was
/// and no window opens.
#[test]
fn a_controller_start_with_no_tmux_refuses_before_it_claims() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let record = runner.state_dir().join("workflow-state-oversee.json");
    let before = std::fs::read_to_string(&record).unwrap();
    let no_tmux = path_without(&runner.state_dir().join("no-tmux"), "tmux");
    let out = runner.op_fleet_env(
        &json!({
            "op": "start-controller",
            "controller": pending(runner.state_dir()),
        }),
        &[("PATH", &no_tmux)],
    );
    assert_eq!(out.status.code(), Some(1), "{}", stderr(&out));
    assert_eq!(
        stderr(&out).lines().next(),
        Some("orch-runtime: unready duty=controller program=tmux cause=absent fix=install-tmux")
    );
    assert_eq!(
        std::fs::read_to_string(&record).unwrap(),
        before,
        "the start claimed before it asked"
    );
    assert_eq!(server.panes().len(), 1, "nothing opened");
}

/// A transfer and a stop on a computer with no `tmux` each refuse `unready`
/// naming its install before either claims: the fleet's record is as it
/// was, no job request is written, the row's planted `setsid` launches no
/// job, and the predecessor still runs. A job a broken admission started is
/// ended before the row judges, so the row leaves nothing behind.
#[test]
fn a_transfer_or_a_stop_with_no_tmux_refuses_before_any_job() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let (sleepers, log) = sleeper_world(runner.state_dir());
    let no_tmux = path_without(&runner.state_dir().join("no-tmux"), "tmux");
    runner.env.extend([
        (
            "PATH".to_owned(),
            format!("{}:{no_tmux}", sleepers.display()),
        ),
        ("SETSID_LOG".to_owned(), log.display().to_string()),
        ("AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(), "1".to_owned()),
    ]);
    let record = runner.state_dir().join("workflow-state-oversee.json");
    let before = std::fs::read_to_string(&record).unwrap();
    for (name, request) in [
        ("transfer", transfer_request(&server, runner.state_dir())),
        ("stop", json!({"op": "stop-controller"})),
    ] {
        let out = runner.op_fleet(&request);
        end_standing_jobs(&runner);
        assert_eq!(out.status.code(), Some(1), "{name}: {}", stderr(&out));
        assert_eq!(
            stderr(&out).lines().next(),
            Some("orch-runtime: unready duty=job program=tmux cause=absent fix=install-tmux"),
            "{name}"
        );
        assert_eq!(
            std::fs::read_to_string(&record).unwrap(),
            before,
            "{name}: claimed before it asked"
        );
        assert!(
            !runner.state_dir().join("intents").exists(),
            "{name}: a job request was written"
        );
        assert_eq!(launches(&log), 0, "{name}: a job was launched");
    }
    assert!(live(predecessor.pid()));
}

/// End every job group the fleet's open intents record as standing.
fn end_standing_jobs(runner: &Runner) {
    let fleet = runner.fleet();
    let standing = fleet["intents"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|intent| intent["obligations"]["standing"].as_array())
        .flatten()
        .filter(|o| o["kind"] == "job-group")
        .filter_map(|o| o["pid"].as_u64());
    for pid in standing {
        end_sleeper(pid as u32);
    }
}

/// An adoption records the harness identity read in the pane's foreground,
/// never the caller's word for it; a record of another, live controller
/// refuses `overseer-live`; a pane holding no harness refuses
/// `pane-not-harness`; the same pane adopted again is healed in place.
#[test]
fn adopt_controller_binds_the_harness_read_in_the_pane_and_refuses_a_live_record_or_a_shell() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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

/// The table `kendex list` prints for a checkout whose install covers the
/// Claude harness with the turn-end hook.
const CLAUDE_HOOK: &str = "hook Stop::lane-mail-check claude project\n";

/// The `kendex` fixture first on the runner's PATH, its `list` answering
/// `table` at `exit`; the directory it is linked into, its log beside it.
fn register_tools(runner: &mut Runner, table: &str, exit: i32) -> std::path::PathBuf {
    let tools = runner.state_dir().join("register-tools");
    std::fs::create_dir_all(&tools).unwrap();
    let link = tools.join("kendex");
    if std::fs::symlink_metadata(&link).is_err() {
        std::os::unix::fs::symlink(fixtures().join("kendex-register/kendex"), &link).unwrap();
    }
    std::fs::write(tools.join("list.txt"), table).unwrap();
    std::fs::write(tools.join("list.exit"), exit.to_string()).unwrap();
    runner.tools = Some(tools.clone());
    tools
}

/// A fleet of its own on `server`, its install covering Claude.
fn register_runner(server: &Server) -> Runner {
    let mut runner = suite_runner(server, "stub-confirm");
    runner.init_fleet();
    register_tools(&mut runner, CLAUDE_HOOK, 0);
    runner
}

/// `orch-runtime register --fleet ARGS` run as from `pane`.
fn register(
    runner: &Runner,
    pane: &str,
    extra: &[(&str, &str)],
    args: &[&str],
) -> std::process::Output {
    let mut words = vec!["register", "--fleet"];
    words.extend_from_slice(args);
    let mut env = vec![("TMUX_PANE", pane)];
    env.extend_from_slice(extra);
    runner.run_env(&words, &env)
}

/// The rows file the hook keeps for `pane`: under the checkout's overseer
/// mailbox, named for the server and the pane.
fn rows_file(runner: &Runner, server: &Server, pane: &str) -> std::path::PathBuf {
    std::fs::canonicalize(runner.state_dir())
        .unwrap()
        .join("tmp/lane-mail/overseer")
        .join(format!(
            "session-{}-{}.jsonl",
            server.pid,
            pane.trim_start_matches('%')
        ))
}

/// A hand-opened Claude session registers from its own pane: outside a pane
/// it is refused; with no SessionStart row the pane is read, the named
/// fallback said; the account is always the one the harness process's own
/// environment names, ahead of the caller's and the row's; with the row its
/// harness wrote, the row's model and directory, the
/// record naming this pane keeping its generation, the binding cleared so a
/// resumed session binds its new id, a stale pending and an ended session's
/// exit dropped, and `--account` taken; a checkout whose install lists no
/// turn-end hook for the harness is said; a server start that cannot be
/// read writes nothing.
#[test]
fn a_hand_opened_session_registers_from_its_start_row_or_its_pane_and_registering_again_rebinds_it()
{
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = register_runner(&server);
    let tools = runner.tools.clone().unwrap();
    let work = runner.state_dir().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let pane_home = runner.state_dir().join("pane-home");
    let pane = server.open_stub("hand", "stub-confirm", &work, &pane_home);
    server.await_composer(&pane);
    let pane_home = pane_home.display().to_string();
    let caller_home = runner
        .state_dir()
        .join("caller-claude")
        .display()
        .to_string();
    let fleet_file = runner.state_dir().join("workflow-state-oversee.json");

    let out = runner.run_env(&["register", "--fleet"], &[]);
    assert_eq!(refusal_key(&out), "tmux-missing");
    assert_eq!(
        refusal_key(&register(&runner, "fleet:0", &[], &[])),
        "pane-invalid"
    );
    assert_eq!(
        refusal_key(&register(&runner, "%999", &[], &[])),
        "pane-gone"
    );
    assert_eq!(runner.fleet()["overseer"], Value::Null, "nothing written");

    let out = register(&runner, &pane, &[("CLAUDE_CONFIG_DIR", &caller_home)], &[]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    assert_eq!(
        answer["result"]["notices"],
        json!([format!(
            "identity-fallback session={pane} cause=no-start-row"
        )])
    );
    assert_eq!(answer["result"]["adopted"]["report"]["generation"], 1);
    let record = runner.fleet()["overseer"].clone();
    let rows = rows_file(&runner, &server, &pane);
    let project = std::fs::canonicalize(runner.state_dir()).unwrap();
    assert_eq!(record["harness"], "claude");
    // The account the harness process runs under, not the caller's own.
    assert_eq!(record["account"], pane_home.as_str());
    assert_eq!(record["home"], pane_home.as_str());
    assert_eq!(record["permission"], "native");
    assert_eq!(record["extra_args"], json!([]));
    assert_eq!(
        record["cwd"],
        std::fs::canonicalize(&work).unwrap().display().to_string()
    );
    assert_eq!(record["model"], Value::Null);
    assert_eq!(record["effort"], Value::Null);
    assert_eq!(record["session_rows"], rows.display().to_string());
    assert_eq!(record["server_socket"], server.socket.display().to_string());
    assert_eq!(record["harness_pid"], server.pane_pid(&pane));
    let log = std::fs::read_to_string(tools.join("kendex.log")).unwrap();
    assert!(
        log.contains(&format!("list --harness claude cwd={}", project.display())),
        "{log}"
    );

    std::fs::create_dir_all(rows.parent().unwrap()).unwrap();
    let stated = runner
        .state_dir()
        .join("stated-account")
        .display()
        .to_string();
    let start = json!({
        "event": "SessionStart",
        "harness": "claude",
        "account": stated,
        "model": "claude-fable-5-1",
        "cwd": "/elsewhere",
    });
    std::fs::write(
        &rows,
        format!(
            "{start}\n{}\n",
            json!({"event": "Stop", "harness": "claude"})
        ),
    )
    .unwrap();
    let mut fleet = runner.fleet();
    fleet["overseer"]["session_id"] = json!("before-resume");
    fleet["overseer"]["pending"] = json!({"harness": "claude"});
    fleet["overseer"]["exit"] = json!({"status": 0});
    runner.write_fleet(&fleet);
    let out = register(&runner, &pane, &[("CLAUDE_CONFIG_DIR", &caller_home)], &[]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    assert_eq!(answer["result"]["notices"], json!([]));
    assert_eq!(answer["result"]["adopted"]["report"]["healed"], true);
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["generation"], 1);
    assert_eq!(
        record["account"],
        pane_home.as_str(),
        "the process's environment ahead of the row's {stated}"
    );
    assert_eq!(record["model"], "claude-fable-5-1");
    assert_eq!(record["cwd"], "/elsewhere");
    assert_eq!(record["session_id"], Value::Null, "the binding cleared");
    assert!(
        record.get("pending").is_none() && record.get("exit").is_none(),
        "{record}"
    );
    let log = std::fs::read_to_string(tools.join("kendex.log")).unwrap();
    assert_eq!(
        log.matches(&format!("cwd={}", project.display())).count(),
        2,
        "the checkout's install is asked, never the row's directory: {log}"
    );

    let named = runner
        .state_dir()
        .join("named-account")
        .display()
        .to_string();
    let out = register(&runner, &pane, &[], &["--account", &named]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["generation"], 1);
    assert_eq!(record["account"], named.as_str());

    register_tools(&mut runner, "", 1);
    let out = register(&runner, &pane, &[], &[]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(
        answer["result"]["notices"],
        json!([
            "turn-end-hook=missing harness=claude exit=1 fix=add claude to [install] harnesses in kendex.toml and run kendex apply"
        ])
    );

    let before = std::fs::read_to_string(&fleet_file).unwrap();
    let real = which_tmux();
    let shim = fixtures().join("tmux-fail");
    let path = tool_path(&[runner.tools.as_deref().unwrap(), shim.as_path()]);
    let out = register(
        &runner,
        &pane,
        &[
            ("PATH", &path),
            ("TMUX_FAIL_VERB", "display-message"),
            ("TMUX_REAL", &real),
        ],
        &[],
    );
    assert_eq!(reply(&out)["ok"], false, "{}", stderr(&out));
    assert_eq!(
        std::fs::read_to_string(&fleet_file).unwrap(),
        before,
        "nothing written"
    );
}

/// A session a person started by hand, with its own model, effort and a
/// narrower permission word on its command line and its own config dir in
/// its environment, registers with no start row; the next hand-over,
/// composed by the real `successor --recover` from that record alone,
/// launches its successor with the same words on the same account and no
/// bypass word, and the successor takes over with no hand step. A Pi
/// session on a `pi-claude/` model records the Claude seat its model bills
/// as its account and its own root as its home, and its successor launches
/// with each in its own variable.
#[test]
fn a_hand_started_session_records_its_command_line_and_its_next_hand_over_launches_from_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-record");
    runner.init_fleet();
    register_tools(&mut runner, CLAUDE_HOOK, 0);
    let work = runner.state_dir().join("work");
    std::fs::create_dir_all(&work).unwrap();
    let work = std::fs::canonicalize(&work).unwrap();
    let account = runner.state_dir().join("hand-account");
    plant_credential(&account);
    let pane = server.open_window(
        "hand",
        &work,
        &format!(
            "exec env CLAUDE_CONFIG_DIR={} {} --model opus --effort high --permission-mode dontAsk",
            account.display(),
            stub("stub-confirm").display()
        ),
    );
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    let out = register(&runner, &pane, &[], &[]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["account"], account.display().to_string(), "{record}");
    assert_eq!(record["model"], "opus");
    assert_eq!(record["effort"], "high");
    assert_eq!(record["permission"], "native");
    assert_eq!(
        record["extra_args"],
        json!(["--permission-mode", "dontAsk"])
    );
    // The handoff snapshot the live transfer is admitted on, written by the
    // real verb where the successor's brief names it.
    let body = runner.state_dir().join("handoff-body.md");
    std::fs::write(&body, "## State\nHanded over by hand.\n").unwrap();
    let handoff = work.join("tmp/handoffs/OVERSEER-HANDOFF.md");
    let out = runner.run(&[
        "handoff",
        "--fleet",
        "--body",
        &body.display().to_string(),
        "--handoff",
        &handoff.display().to_string(),
    ]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));

    let out = runner.run(&[
        "successor",
        "--fleet",
        "--predecessor",
        &pane,
        "--recover",
        "--cwd",
        &work.display().to_string(),
    ]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    let request = json!({
        "op": "request-transfer",
        "cause": "live",
        "expected": answer["result"]["expected"],
        "successor": answer["result"]["successor"],
    });
    runner.transfer_started(&request);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(pid), "the hand-started predecessor was retired");
    let launched = launch_record(&work);
    assert_eq!(
        launched_var(&launched, "CLAUDE_CONFIG_DIR"),
        &json!(account.display().to_string()),
        "{launched}"
    );
    let argv = argv_of(&launched);
    for words in [
        ["--model", "opus"],
        ["--effort", "high"],
        ["--permission-mode", "dontAsk"],
    ] {
        assert!(argv.windows(2).any(|w| w == words), "{words:?} in {argv:?}");
    }
    assert!(
        !argv.iter().any(|a| a == "--dangerously-skip-permissions"),
        "no bypass word under the native posture: {argv:?}"
    );

    let mut runner = register_runner(&server);
    runner.verify = Some(1);
    let root = runner.state_dir().join("pi-root");
    let seat = runner.state_dir().join("claude-seat");
    std::fs::create_dir_all(&root).unwrap();
    pi_root_marked(&root);
    plant_credential(&seat);
    let pi = fixtures().join("stub-record/pi");
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("pi={}", pi.display()),
    ));
    let pane = server.open_window(
        "hand-pi",
        runner.state_dir(),
        &format!(
            "exec env PI_CODING_AGENT_DIR={} CLAUDE_CONFIG_DIR={} {} --model pi-claude/opus",
            root.display(),
            seat.display(),
            pi.display(),
        ),
    );
    await_named(&server, &pane, "pi");
    let out = register(&runner, &pane, &[], &[]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["account"], seat.display().to_string(), "{record}");
    assert_eq!(record["home"], root.display().to_string(), "{record}");
    let out = runner.run(&[
        "handoff",
        "--fleet",
        "--body",
        &body.display().to_string(),
        "--handoff",
        &runner
            .state_dir()
            .join("tmp/handoffs/OVERSEER-HANDOFF.md")
            .display()
            .to_string(),
    ]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let out = runner.run(&[
        "successor",
        "--fleet",
        "--predecessor",
        &pane,
        "--recover",
        "--cwd",
        &runner.state_dir().display().to_string(),
    ]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    // The record the hand start wrote is the predecessor's own.
    launch_record(runner.state_dir());
    std::fs::remove_file(runner.state_dir().join("launch-record.json")).unwrap();
    runner.transfer_started(&json!({
        "op": "request-transfer",
        "cause": "live",
        "expected": answer["result"]["expected"],
        "successor": answer["result"]["successor"],
    }));
    let launched = launch_record(runner.state_dir());
    assert_eq!(
        launched_var(&launched, "CLAUDE_CONFIG_DIR"),
        &json!(seat.display().to_string()),
        "{launched}"
    );
    assert_eq!(
        launched_var(&launched, "PI_CODING_AGENT_DIR"),
        &json!(root.display().to_string()),
        "{launched}"
    );
    runner.wait_intent_settled("request-transfer:", SETTLE);
}

/// A register never takes a record another session may still hold: from a
/// second server whose pane carries the recorded pane's id it is refused
/// while the recorded controller lives, and takes over once that server
/// stopped; a record naming this pane on this server pid at another server
/// start is a gone server's, taken over; a record with no identity whose
/// server cannot be judged is refused unread, the record kept.
#[test]
fn a_register_never_takes_a_record_another_live_or_unjudged_server_may_hold() {
    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    let a = Server::start(dir_a.path(), "fleet");
    let b = Server::start(dir_b.path(), "fleet");
    let runner = register_runner(&a);
    let pane_a = a.open_stub(
        "hand",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    let pane_b = b.open_stub(
        "hand",
        "stub-confirm",
        runner.state_dir(),
        runner.state_dir(),
    );
    a.await_composer(&pane_a);
    b.await_composer(&pane_b);
    assert_eq!(pane_a, pane_b, "both servers hand out the same pane id");
    let on_b = format!("{},0,0", b.socket.display());
    let fleet_file = runner.state_dir().join("workflow-state-oversee.json");
    let out = register(&runner, &pane_a, &[], &[]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));

    let before = std::fs::read_to_string(&fleet_file).unwrap();
    assert_eq!(
        refusal_key(&register(&runner, &pane_b, &[("TMUX", &on_b)], &[])),
        "overseer-live"
    );
    assert_eq!(
        std::fs::read_to_string(&fleet_file).unwrap(),
        before,
        "kept"
    );

    drop(a);
    let out = register(&runner, &pane_b, &[("TMUX", &on_b)], &[]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    assert_eq!(answer["result"]["adopted"]["report"]["generation"], 2);
    assert_eq!(runner.fleet()["overseer"]["server"], b.pid.to_string());

    let gone = Owned::sleep();
    let (pid, start) = (gone.pid(), gone.start());
    drop(gone);
    let mut fleet = runner.fleet();
    fleet["overseer"]["server_start"] = json!(b.start - 5);
    fleet["overseer"]["harness_pid"] = json!(pid);
    fleet["overseer"]["harness_start"] = json!(start);
    runner.write_fleet(&fleet);
    let out = register(&runner, &pane_b, &[("TMUX", &on_b)], &[]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    assert_eq!(answer["result"]["adopted"]["report"]["healed"], false);
    assert_eq!(answer["result"]["adopted"]["report"]["generation"], 3);

    let unjudged = Owned::sleep();
    let mut fleet = runner.fleet();
    let record = fleet["overseer"].as_object_mut().unwrap();
    record.remove("harness_pid");
    record.remove("harness_start");
    record.insert("server".into(), json!(unjudged.pid().to_string()));
    record.insert("server_start".into(), json!(1));
    record.insert(
        "server_socket".into(),
        json!(dir_b.path().join("none.sock").display().to_string()),
    );
    runner.write_fleet(&fleet);
    let before = std::fs::read_to_string(&fleet_file).unwrap();
    assert_eq!(
        refusal_key(&register(&runner, &pane_b, &[("TMUX", &on_b)], &[])),
        "overseer-unreadable"
    );
    assert_eq!(
        std::fs::read_to_string(&fleet_file).unwrap(),
        before,
        "kept"
    );
}

/// Each harness a hand-opened pane runs is read off its foreground, with
/// the account its own home variable names: Codex's account apart from its
/// private `CODEX_HOME`, a Copilot CLI under its `node` launcher on the
/// `COPILOT_HOME` its process runs with (`--account` ahead of it), Pi's
/// root. A Copilot home gets the context reader, said to load at the next
/// start, and its missing hooks said; one whose extensions are off and
/// that runs no status line is said to have no reader and still
/// registered; another harness's missing turn-end hook is said. A pane no
/// harness holds is refused.
#[test]
fn a_register_reads_each_harness_and_its_account_off_its_pane_and_says_what_its_coverage_lacks() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    for name in ["codex", "copilot"] {
        named_sleep(&bin, name);
    }
    write_executable(&bin.join("node"), "#!/bin/bash\n\"${0%/*}/copilot\" 600\n");
    let fix = |name: &str| {
        format!("fix=add {name} to [install] harnesses in kendex.toml and run kendex apply")
    };

    let runner = register_runner(&server);
    let account = runner.state_dir().join("codex-account");
    let private = account.join("lane-launch/work-1/home");
    let pane = server.open_window(
        "codex",
        runner.state_dir(),
        &format!(
            "exec env CODEX_HOME={} {} 600",
            private.display(),
            bin.join("codex").display()
        ),
    );
    await_named(&server, &pane, "codex");
    let out = register(&runner, &pane, &[], &[]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["harness"], "codex");
    assert_eq!(record["account"], account.display().to_string());
    assert_eq!(record["home"], private.display().to_string());
    assert_eq!(
        answer["result"]["notices"][1],
        format!(
            "turn-end-hook=missing harness=codex exit=0 {}",
            fix("codex")
        )
    );

    let runner = register_runner(&server);
    let copilot_home = runner.state_dir().join("copilot-home");
    std::fs::create_dir_all(&copilot_home).unwrap();
    let caller = runner.state_dir().join("caller-home");
    std::fs::create_dir_all(&caller).unwrap();
    let caller = caller.display().to_string();
    let pane = server.open_window(
        "copilot",
        runner.state_dir(),
        &format!(
            "exec env COPILOT_HOME={} {}",
            copilot_home.display(),
            bin.join("node").display()
        ),
    );
    await_named(&server, &pane, "node");
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let out = register(&runner, &pane, &[("HOME", &caller)], &[]);
        if reply(&out)["ok"] == true {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the Copilot child never ran: {}",
            stderr(&out)
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["harness"], "copilot");
    assert_eq!(record["account"], copilot_home.display().to_string());
    assert!(
        copilot_home
            .join("extensions/kendex-lane-context/extension.mjs")
            .is_file()
    );
    let named = runner.state_dir().join("named-copilot");
    std::fs::create_dir_all(&named).unwrap();
    std::fs::write(
        named.join("settings.json"),
        r#"{"enabledFeatureFlags": {"EXTENSIONS": false}}"#,
    )
    .unwrap();
    let named = named.display().to_string();
    let out = register(&runner, &pane, &[("HOME", &caller)], &["--account", &named]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer} {}", stderr(&out));
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["account"], named.as_str());
    let notices = answer["result"]["notices"].as_array().unwrap().clone();
    assert!(
        notices[1]
            .as_str()
            .unwrap()
            .starts_with(&format!("context-reader=missing home={named} cause=")),
        "{notices:?}"
    );
    assert!(
        notices[2]
            .as_str()
            .unwrap()
            .starts_with("turn-end-hook=missing harness=copilot reason=unsupported-for-oversee"),
        "{notices:?}"
    );
    std::fs::remove_dir_all(&named).unwrap();
    let out = register(&runner, &pane, &[("HOME", &caller)], &["--account", &named]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(
        answer["result"]["notices"][1],
        format!("context-reader=next-start home={named}")
    );

    // A fleet with no state yet: the register makes it first.
    let runner = register_runner(&server);
    std::fs::remove_file(runner.state_dir().join("workflow-state-oversee.json")).unwrap();
    let root = runner.state_dir().join("pi-root").display().to_string();
    // A model Pi bills to its own root, so the root is the account too.
    let pane = server.open_window(
        "pi",
        runner.state_dir(),
        &format!(
            "exec env PI_CODING_AGENT_DIR={root} {} --model github-copilot/gpt-5",
            fixtures().join("stub-record/pi").display()
        ),
    );
    await_named(&server, &pane, "pi");
    let out = register(&runner, &pane, &[], &[]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    let record = runner.fleet()["overseer"].clone();
    assert_eq!(record["harness"], "pi");
    assert_eq!(record["account"], root.as_str());

    let runner = register_runner(&server);
    let idle = server.open_idle("idle", runner.state_dir());
    assert_eq!(
        refusal_key(&register(&runner, &idle, &[], &[])),
        "pane-not-harness"
    );
    assert_eq!(runner.fleet()["overseer"], Value::Null, "nothing written");
}

/// Abandoning a waiting runner before retirement completes `failed` only
/// once its stop and its window's close both answered. A pane the host does
/// not answer for is left as it stands and the intent stays open; a window
/// close the host refuses after the runner's stop holds the intent open
/// with the cause. The runner stands at its composer before the reconcile,
/// so the bound is short: it is what an unanswering host is retried for.
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
        pane_stands: bool,
        /// Whether the runner's identity is still an obligation afterwards:
        /// discharged by its own stop, never by the window's close.
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
        let mut runner = suite_runner(&server, "stub-confirm");
        runner.verify = Some(1);
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
        // phase carries it, so the abandonment stops exactly that process
        // and carries it on an unsettled outcome.
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

/// A succession guard reads `state inspect` before it acts: an open
/// transfer is listed, a closed one is not, and an item file lists none.
#[test]
fn inspect_lists_the_open_intents_the_runtime_judges_open() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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

/// The explicit stop runs as the detached job the succession runs as. The
/// predecessor here is a stub harness in a pane that runs the `op` as a
/// foreground child, as the overseer's shell tool runs an explicit off from
/// its own pane. The op hands the stop to the job and answers
/// `stop-started`; the job lets the op exit, retires the predecessor by its
/// identity, whose exit closes the pane the op asked from, closes the
/// window and records `off`.
#[test]
fn a_self_stop_from_the_predecessors_own_pane_records_off_and_closes_the_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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
    let answer = wait_reply(&out, secs(30), || {
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
    wait_until("the predecessor stopped", secs(20), || !live(pid));
    wait_until("the predecessor's pane closed", secs(10), || {
        !server.panes().contains(&pane)
    });
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
    wait_until("the job exited", secs(10), || !live(owner_pid));
}

/// A live stub in a pane the record names on this server with no server
/// start and no identity is unresolved, not absent. A start refuses
/// `predecessor-unproven` and opens nothing; an adoption from another pane
/// refuses the same; a stop names nothing to retire and touches the pane;
/// the stub runs on throughout. The remedy, adoption from the record's own
/// pane, binds the start and heals the record.
#[test]
fn an_unproven_predecessor_is_never_replaced_and_its_pane_never_closed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
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

/// The window is a handle the publication settles. With its close refused
/// by the host, the succession stays `unconfirmed` at `identity-read` with
/// the successor live and the brief delivered, nothing published; the host
/// answering again, the reconcile closes the window and publishes.
#[test]
fn a_publication_waits_for_the_predecessors_window_to_read() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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
    runner.tools = Some(fixtures().join("tmux-fail"));
    runner.env.push(("TMUX_REAL".to_owned(), which_tmux()));
    runner
        .env
        .push(("TMUX_FAIL_VERB".to_owned(), "kill-window".to_owned()));
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
    // A failed publication consumed nothing: the predecessor's window stands
    // among the held handles, beside the runner's own, which the publication
    // did not take.
    assert!(
        intent["observation"]["remaining"]
            .as_array()
            .is_some_and(|rows| rows
                .iter()
                .any(|o| o["kind"] == "pane" && o["pane"] == json!(idle))),
        "{intent}"
    );
    // The runner's own process was not published either: a failed
    // publication consumes nothing.
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
}

/// A crash between a job intent's failed outcome write and its send leaves
/// a closed intent whose notice is recorded `owed`. The next reconcile,
/// with no open intent to reconcile, sends that notice once and marks it
/// `sent`; the reconcile after it sends nothing again.
#[test]
fn a_reconcile_sends_the_notice_a_closed_intent_still_owes_once() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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
        "obligations": {"standing": [], "discharged": [{"obligation": {"kind": "job-sidecar", "record": job_record(&runner, id)}, "by": "launch-failed:7", "role": "job"}], "revision": 2}
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

/// The launcher's record of the intent `id`'s detached job, the address its
/// sidecar obligation records.
fn job_record(runner: &Runner, id: &str) -> String {
    runner
        .state_dir()
        .join("intents")
        .join(format!("{id}.job"))
        .display()
        .to_string()
}

fn owner_notices(mail_log: &Path) -> usize {
    std::fs::read_to_string(mail_log)
        .unwrap_or_default()
        .lines()
        .filter(|l| l.starts_with("notice --item overseer --to owner --file "))
        .count()
}

/// A live `request-transfer` on a fleet whose closed intent of an earlier
/// generation still owes its notice sends the notice once, marks it `sent`,
/// and proceeds to its own effect, `transfer-started`; the walk never fails
/// the request it precedes.
#[test]
fn a_live_request_with_an_owed_notice_proceeds() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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
        "obligations": {"standing": [], "discharged": [{"obligation": {"kind": "job-sidecar", "record": job_record(&runner, id)}, "by": "launch-failed:7", "role": "job"}], "revision": 2}
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
    let mut runner = suite_runner(&server, "stub-mute");
    runner.verify = Some(2);
    gated_readiness(&mut runner);
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
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "brief-unconfirmed");
    let id = intent["id"].as_str().unwrap().to_owned();
    let text =
        format!("orch-runtime: brief-unconfirmed op=request-transfer intent={id} outcome=failed");
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
    // A reconcile after the closed outcome announces nothing again.
    let out = runner.run(&["reconcile", "--fleet"]);
    assert_eq!(reply(&out)["ok"], true, "{}", stderr(&out));
    assert_eq!(runner.fleet()["intents"][0]["notice"]["text"], text);
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

/// The runtime builds the successor's command from the typed launch fields
/// through the one launch builder, which routes the account by the
/// harness's table. A Pi successor on a `pi-claude/` model is launched with
/// Pi's own root in `PI_CODING_AGENT_DIR` and the chosen Claude seat in
/// `CLAUDE_CONFIG_DIR`, its model word carrying the provider and the
/// effort, the caller's own words appended; the recorded `launch_line` is
/// never what runs. A Claude successor under `native` keeps the caller's
/// permission words and gains no bypass word.
#[test]
fn the_successor_is_launched_from_its_typed_fields_with_the_account_routed() {
    // Pi: the stub records what it was launched as and draws no composer,
    // so the succession abandons it before retirement; the record is read.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("seat");
    let pi_home = dir.path().join("pi-home");
    std::fs::create_dir_all(&seat).unwrap();
    pi_root_marked(&pi_home);
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
    runner.transfer_started_env(&request, &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)]);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "successor-not-ready");
    let launched = launch_record(runner.state_dir());
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
    let runner = suite_runner(&server, "stub-record");
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
    let launched = launch_record(runner.state_dir());
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
        overseer["launch_line"],
        Value::Null,
        "a released pending's display line is not published"
    );

    // Copilot under the bypass posture: the builder owns the permission
    // environment, so `COPILOT_ALLOW_ALL=true` reaches the
    // launched process whatever the argv words, read off the recorded env.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("copilot-home");
    std::fs::create_dir_all(&seat).unwrap();
    copilot_gate_passed(&mut runner, &seat);
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
    runner.transfer_started_env(&request, &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)]);
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(intent["observation"]["note"], "successor-not-ready");
    let launched = launch_record(runner.state_dir());
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
// The recorded set across a crash, the job identity and the posture guard.
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

/// The launch record a record stub writes in `cwd`, read once it stands:
/// the stub writes it from its own process, which may run after the launch
/// answers.
fn launch_record(cwd: &Path) -> Value {
    let path = cwd.join("launch-record.json");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(record) = serde_json::from_str::<Value>(&text)
        {
            return record;
        }
        assert!(
            Instant::now() < deadline,
            "no launch record at {}",
            path.display()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
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

/// The recorded set is the window-opened one; the predecessor is gone and
/// its window's close is refused by the host. The reconcile acquires the
/// predecessor's handles before it acts and publishes nothing over its
/// unread window: `unconfirmed`, the window standing.
#[test]
fn a_crash_before_the_retired_write_never_publishes_over_an_unread_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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
    // among the held handles, beside the runner's own.
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

/// The close lands on the predecessor's own pane key. With the runner's own
/// window close refused and the runner's identity gone, the predecessor's
/// window is closed and discharged by that close while the runner's pane
/// stands held; two reconciles later the intent is still open, never
/// `failed` with the runner's window standing.
#[test]
fn the_predecessors_close_never_discharges_the_runners_pane() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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
    write_executable(
        &shim,
        format!(
            "#!/bin/bash\nfor a in \"$@\"; do [ \"$a\" = kill-window ] && k=1; [ \"$a\" = '{window}' ] && w=1; done\n[ -n \"$k\" ] && [ -n \"$w\" ] && {{ echo refused >&2; exit 1; }}\nexec {} \"$@\"\n",
            which_tmux()
        ),
    );
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

/// The controller stop records `signalled` before its first signal. Its
/// `kill` stands in for a process that ignores the signal, so the stop
/// times out and holds; with the record then moved under the open intent by
/// another writer, the reconcile holds `target-moved` with `stop` not
/// `none`: a refusal is impossible after a signal on the intent. That moved
/// reconcile retries on the intent's own set, so the signalled predecessor
/// is stopped by its own token there, never left live for the operator. The
/// predecessor's pane is planted on a server process that is live (this
/// test's own) but answers at no socket, the unobservable reading that
/// holds the set open; a pane on a server replaced at the recorded pid
/// reads gone instead and settles it.
#[test]
fn a_signalled_controller_stop_never_refuses() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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
    // Another writer of the record moves the generation under the open
    // intent.
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
    // The moved target closes the intent only on a terminal word. Held
    // `unconfirmed` on its planted pane
    // the host cannot prove, it stays open with the generation it observed
    // noted, its receipt and job files kept.
    let after = runner.fleet()["intents"][0].clone();
    assert!(
        after["completed_at"].is_null(),
        "an unconfirmed moved target stays open: {after}"
    );
    assert!(after["reconciled"].is_null(), "{after}");
    assert_eq!(after["observed_generation"], 4, "{after}");
    // The moved reconcile stopped the signalled predecessor through its own
    // set's token, with the real `kill` now in reach; nothing the record
    // names at generation 4 was read for it.
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

/// With the pending gone, the runner's pane standing and its recorded
/// identity gone, the recorded set holds the predecessor's pane and
/// identity. The failure consumes the whole recorded set: the runner
/// stopped and its window closed, the predecessor's identity read and its
/// window closed, nothing dropped.
#[test]
fn pending_missing_after_retirement_consumes_the_predecessor() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let since = now_ms();
    let pane = server.open_idle("overseer", runner.state_dir());
    let idle = server.open_idle("predecessor", runner.state_dir());
    let mut ph = phase("delivered", &server, &pane, since, None);
    ph["identity"] = json!({"pid": GONE_PID - 7, "start": "ticks:7"});
    ph["turns_before"] = json!(0);
    ph["session"] = json!({"session_id": "s", "file": runner.state_dir().join("s.jsonl")});
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

/// An earlier job of the intent claimed it; the repeat's own job was
/// launched and never claimed, and its group identity reads live: a further
/// repeat starts no other job while that one stands.
#[test]
fn a_repeat_after_a_claimed_job_starts_no_job_while_one_stands() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let (bin, log) = sleeper_world(runner.state_dir());
    runner.tools = Some(bin);
    runner
        .env
        .push(("AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(), "1".to_owned()));
    runner
        .env
        .push(("SETSID_LOG".to_owned(), log.display().to_string()));
    let out = runner.op_fleet(&json!({"op": "stop-controller"}));
    assert_eq!(refusal_key(&out), "job-unclaimed", "{}", stderr(&out));
    let job = standing_job_pid(&runner);
    // An earlier job of this intent had claimed it.
    let mut fleet = runner.fleet();
    fleet["intents"][0]["handed_from"] = json!({"pid": 1, "start": "ticks:1"});
    runner.write_fleet(&fleet);
    let out2 = runner.op_fleet(&json!({"op": "stop-controller"}));
    let report = effect_report(&out2);
    assert_eq!(
        report["intent"]["observation"]["job"], "possibly-started",
        "{report}"
    );
    assert_eq!(
        remaining(&report["intent"]["observation"], "job")["pid"],
        job,
        "the standing group is what holds the repeat: {report}"
    );
    assert_eq!(launches(&log), 1, "a second job while the first stands");
    assert!(live(job));
    assert!(live(predecessor.pid()), "nothing retired the predecessor");
    end_sleeper(job);
}

/// Where no user manager lingers the launcher forks the job under `setsid`
/// and reads its identity from the kernel's table before it returns,
/// records it before the claim wait, and a child that exits before it
/// claims stands as its recorded group until the reconcile reads it gone by
/// that identity and discharges `job-exited`: `failed`, the request
/// removed, the predecessor it never retired standing. The child is a sleep
/// that never claims, so the claim bound is one second and the row ends the
/// child itself once the identity is recorded.
#[test]
fn a_job_is_a_setsid_group_where_no_manager_lingers_and_a_job_that_exits_before_claiming_is_read_gone_by_its_recorded_identity()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    let (bin, log) = sleeper_world(runner.state_dir());
    runner.tools = Some(bin);
    runner
        .env
        .push(("AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(), "1".to_owned()));
    runner
        .env
        .push(("SETSID_LOG".to_owned(), log.display().to_string()));
    let out = runner.op_fleet(&transfer_request(&server, runner.state_dir()));
    assert_eq!(refusal_key(&out), "job-unclaimed", "{}", stderr(&out));
    let intent = runner.fleet()["intents"][0].clone();
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    // The refusal came after the intent was persisted, and names it.
    assert!(
        stderr(&out)
            .lines()
            .next()
            .unwrap_or_default()
            .ends_with(&format!(
                " persisted_intent={}",
                intent["id"].as_str().unwrap()
            )),
        "{}",
        stderr(&out)
    );
    let job = remaining(&intent["observation"], "job").clone();
    let pid = job["pid"]
        .as_u64()
        .expect("the launcher read the child's pid") as u32;
    let start = job["start"].as_str().expect("and its start").to_owned();
    assert_eq!(start, start_of(pid), "the start the kernel reports for it");
    let id = intent["id"].as_str().unwrap().to_owned();
    let record = std::fs::read_to_string(job_record(&runner, &id)).unwrap();
    assert!(
        record.contains(&format!("pid={pid}\nstart={start}\n")),
        "the launcher's record names the identity it read: {record}"
    );
    assert!(
        record.lines().any(|l| l.starts_with("line=runner=setsid ")),
        "the setsid route, with its reason: {record}"
    );
    let request = runner
        .state_dir()
        .join("intents")
        .join(format!("{id}.request"));
    assert!(request.exists(), "the request is kept for the job");
    assert_eq!(launches(&log), 1);
    // The child exits before claiming: the reconcile reads the recorded
    // group gone and discharges the job, so the intent fails rather than
    // standing forever.
    end_sleeper(pid);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(report["intent"]["observation"]["job"], "ended");
    assert!(
        remaining(&report["intent"]["observation"], "job").is_null(),
        "the exited job is discharged: {report}"
    );
    assert!(!request.exists(), "the request is removed with the outcome");
    assert!(live(predecessor.pid()), "nothing retired the predecessor");
}

#[test]
fn a_unit_start_whose_reply_and_state_read_are_lost_keeps_the_unit_standing() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    // The manager starts the unit and its reply is lost: the start answers
    // a failure, and the manager refuses the state read that follows.
    let launcher = bin.join("systemd-run");
    let text = std::fs::read_to_string(&launcher).unwrap();
    let started = text
        .strip_suffix("exit 0\n")
        .expect("the fake ends on its answer");
    write_executable(&launcher, format!("{started}exit 1\n"));
    write_executable(&bin.join("systemctl"), "#!/bin/bash\nexit 1\n");
    runner.tools = Some(bin.clone());
    runner
        .env
        .push(("AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(), "1".to_owned()));
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let report = effect_report(&runner.op_fleet_env(
        &json!({
            "op": "start-controller",
            "controller": pending(runner.state_dir()),
            // The start's reach joins the words as the sleeper's ignored
            // arguments.
            "watch": ["sh", "-c", "exec sleep 30", "sleeper"],
        }),
        &env,
    ));
    let units: Vec<std::path::PathBuf> = std::fs::read_dir(bin.join("units"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(units.len(), 1, "the manager started one unit: {units:?}");
    let pid: u32 = std::fs::read_to_string(&units[0])
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let unit_ran = live(pid);
    end_sleeper(pid);
    assert!(unit_ran, "the unit the manager started ran");
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    let unit = units[0].file_name().unwrap().to_str().unwrap();
    let standing = report["intent"]["obligations"]["standing"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert!(
        standing
            .iter()
            .any(|o| o["kind"] == "job-unit" && o["unit"] == unit),
        "the unit stands as the job's obligation: {report}"
    );
}

/// `orch-runtime launch-job` and `stop-job` in `dir` with `path` as `PATH`
/// where a row names one, the mailbox and a tmux socket no server holds
/// planted in `dir`.
fn job_verb(dir: &Path, path: Option<&Path>, args: &[&str]) -> std::process::Output {
    let mut command = isolated();
    command
        .args(args)
        .current_dir(dir)
        .env(
            "LANE_MAIL_CLI",
            fixtures().join("lane-mail-quiet/lane-mail"),
        )
        .env("TMUX", format!("{},0,0", dir.join("tmux.sock").display()));
    if let Some(path) = path {
        command.env("PATH", path);
    }
    command.output().unwrap()
}

/// A job `launch-job` starts where no manager lingers runs as a `setsid`
/// group: the reply names the identity the record holds, the command's
/// standard error lands in `--stderr`, and `stop-job` ends the group by
/// that record, then answers `stopped: null` once nothing runs. A record
/// naming no identity, as an unread launch leaves it, is refused, never
/// read as stopped.
#[test]
fn a_launched_job_runs_as_its_recorded_group_and_stop_job_ends_it_by_that_record() {
    let dir = tempfile::tempdir().unwrap();
    let record = dir.path().join("wait.runner");
    let err = dir.path().join("wait.err");
    let out = job_verb(
        dir.path(),
        None,
        &[
            "launch-job",
            "--name",
            "wait-row",
            "--record",
            "wait.runner",
            "--stderr",
            "wait.err",
            "--",
            "sh",
            "-c",
            "printf '%s\\n' job-stderr >&2; exec sleep 60",
        ],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    let job = reply(&out)["result"].clone();
    assert_eq!(job["launch"], "started", "{job}");
    assert_eq!(job["runner"], "setsid", "{job}");
    let pid = job["pid"].as_u64().expect("the group's pid") as u32;
    assert_eq!(job["start"], start_of(pid), "{job}");
    let text = std::fs::read_to_string(&record).unwrap();
    assert!(
        text.contains(&format!("pid={pid}\nstart={}\n", start_of(pid))),
        "{text}"
    );
    wait_until("the job's stderr", secs(10), || {
        std::fs::read_to_string(&err).is_ok_and(|t| t.lines().any(|l| l == "job-stderr"))
    });
    let stop = |record: &str| job_verb(dir.path(), None, &["stop-job", "--record", record]);
    let out = stop("wait.runner");
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(reply(&out)["result"]["stopped"], "setsid");
    wait_until("the stopped job ended", secs(10), || !live(pid));
    let out = stop("wait.runner");
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(
        reply(&out)["result"]["stopped"].is_null(),
        "{}",
        stderr(&out)
    );
    std::fs::write(
        dir.path().join("unread.runner"),
        "runner=setsid\nline=runner=setsid reason=no-linger\n",
    )
    .unwrap();
    assert_eq!(refusal_key(&stop("unread.runner")), "stop-unreadable");
}

/// Under a lingering manager `launch-job` starts a unit and answers 0 with
/// the unit its record names, which `stop-job` stops; a start whose answer
/// is lost while the manager cannot say whether it holds the unit answers
/// 75, possibly started, so its caller starts nothing again.
#[test]
fn a_launched_unit_is_started_or_possibly_started_and_never_refused_while_the_manager_may_hold_it()
{
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    for fake in ["systemd-run", "systemctl", "loginctl"] {
        write_executable(
            &bin.join(fake),
            std::fs::read_to_string(fixtures().join("cutover-fakes").join(fake)).unwrap(),
        );
    }
    let path = tool_path(&[bin.as_path()]);
    let launch = || {
        job_verb(
            dir.path(),
            Some(Path::new(&path)),
            &[
                "launch-job",
                "--name",
                "wait-row",
                "--record",
                "wait.runner",
                "--",
                "sleep",
                "60",
            ],
        )
    };
    let out = launch();
    assert!(out.status.success(), "{}", stderr(&out));
    let job = reply(&out)["result"].clone();
    assert_eq!(job["launch"], "started", "{job}");
    assert_eq!(job["runner"], "systemd", "{job}");
    let unit = job["unit"].as_str().unwrap().to_owned();
    assert!(unit.starts_with("orch-wait-row-"), "{unit}");
    assert!(bin.join("units").join(&unit).is_file(), "{unit}");
    let out = job_verb(
        dir.path(),
        Some(Path::new(&path)),
        &["stop-job", "--record", "wait.runner"],
    );
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(reply(&out)["result"]["stopped"], "systemd");
    // The manager starts the unit and its reply is lost: the start answers
    // a failure, and the manager refuses the state read that follows.
    let launcher = bin.join("systemd-run");
    let text = std::fs::read_to_string(&launcher).unwrap();
    let started = text
        .strip_suffix("exit 0\n")
        .expect("the fake ends on its answer");
    write_executable(&launcher, format!("{started}exit 1\n"));
    write_executable(&bin.join("systemctl"), "#!/bin/bash\nexit 1\n");
    let out = launch();
    let units: Vec<std::path::PathBuf> = std::fs::read_dir(bin.join("units"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(units.len(), 1, "the manager started one unit: {units:?}");
    let pid: u32 = std::fs::read_to_string(&units[0])
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    end_sleeper(pid);
    assert_eq!(out.status.code(), Some(75), "{}", stderr(&out));
    assert_eq!(reply(&out)["result"]["launch"], "unanswered");
}

/// A launch that starts nothing is refused `job-launch-failed` at exit 1:
/// a host with neither `systemd-run` nor `setsid`, whose record the
/// launcher closes as nothing started, and a record that cannot be written.
#[test]
fn a_launch_that_starts_nothing_is_refused_and_its_record_says_nothing_runs() {
    let dir = tempfile::tempdir().unwrap();
    let empty = dir.path().join("no-tools");
    std::fs::create_dir_all(&empty).unwrap();
    for (record, path) in [
        ("wait.runner", Some(empty.as_path())),
        ("missing/wait.runner", None),
    ] {
        let out = job_verb(
            dir.path(),
            path,
            &[
                "launch-job",
                "--name",
                "wait-row",
                "--record",
                record,
                "--",
                "sleep",
                "60",
            ],
        );
        assert_eq!(out.status.code(), Some(1), "{record}: {}", stderr(&out));
        assert_eq!(refusal_key(&out), "job-launch-failed", "{record}");
    }
    let text = std::fs::read_to_string(dir.path().join("wait.runner")).unwrap();
    assert!(
        text.lines().any(|l| l == "status=setsid-unrun"),
        "the record says nothing runs: {text}"
    );
}

/// A released `oversee-watch` repeat loop the row runs, its process group
/// killed on drop where it still runs; a row that fails also stops the
/// runtime watch a pass of the loop started, so neither outlives the row.
struct ReleasedLoop<'a> {
    child: std::process::Child,
    runner: &'a Runner,
    state: std::path::PathBuf,
}

impl Drop for ReleasedLoop<'_> {
    fn drop(&mut self) {
        if matches!(self.child.try_wait(), Ok(None)) {
            let _ = std::process::Command::new("kill")
                .args(["-KILL", "--", &format!("-{}", self.child.id())])
                .status();
            let _ = self.child.wait();
        }
        if !std::thread::panicking() {
            return;
        }
        let paths = orch_runtime::watch::claim::Paths::of(&self.state).unwrap();
        let deadline = Instant::now() + SETTLE;
        while Instant::now() < deadline {
            if let Ok(Some(claim)) = orch_runtime::watch::claim::read(&paths)
                && claim.start.is_some()
                && live(claim.pid)
            {
                let _ = self.runner.run(&["watch", "stop", "--fleet"]);
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

#[test]
fn a_released_watch_loop_running_across_an_upgrade_hands_its_claim_to_one_runtime_watch() {
    use std::os::unix::process::CommandExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    for fake in ["systemd-run", "systemctl", "loginctl"] {
        std::fs::remove_file(bin.join(fake)).unwrap();
    }
    runner.tools = Some(bin);
    runner.env.extend(env);
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let scripts = runner.state_dir().join("scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(shipped_scripts().join("lib"), scripts.join("lib")).unwrap();
    std::os::unix::fs::symlink(
        runner.state_dir().join("orch-runtime"),
        scripts.join("orch-runtime"),
    )
    .unwrap();
    let entry = scripts.join("oversee-watch");
    write_executable(
        &entry,
        std::fs::read_to_string(fixtures().join("released-watch-loop/oversee-watch")).unwrap(),
    );
    let err = runner.state_dir().join("loop.err");
    let mut command = program(&entry);
    runner.apply_env(&mut command);
    command
        .args(["--repeat", "1", "--state", &state.display().to_string()])
        .args(["--since", "2026-01-01T00:00:00Z"])
        .current_dir(runner.state_dir())
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(&err).unwrap())
        .process_group(0);
    let mut released = ReleasedLoop {
        child: command.spawn().unwrap(),
        runner: &runner,
        state: state.clone(),
    };
    let loop_pid = released.child.id();
    let paths = orch_runtime::watch::claim::Paths::of(&state).unwrap();
    let claim = || orch_runtime::watch::claim::read(&paths).ok().flatten();
    wait_until("the loop's start-less claim", SETTLE, || {
        claim().is_some_and(|c| c.pid == loop_pid && c.start.is_none())
    });
    // The upgrade writes the shipped entry over the path the loop runs as
    // each pass, renamed into place.
    let next = scripts.join(".oversee-watch.next");
    write_executable(
        &next,
        std::fs::read_to_string(shipped_scripts().join("oversee-watch")).unwrap(),
    );
    std::fs::rename(&next, &entry).unwrap();
    let deadline = Instant::now() + SETTLE;
    let status = loop {
        if let Some(status) = released.child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "the released loop never ended: {}",
            std::fs::read_to_string(&err).unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(
        status.success(),
        "{status:?}: {}",
        std::fs::read_to_string(&err).unwrap_or_default()
    );
    wait_until("the runtime's claim", SETTLE, || {
        claim().is_some_and(|c| c.start.is_some() && live(c.pid))
    });
    let job = std::fs::read_to_string(runner.state_dir().join("oversee-watch.runner")).unwrap();
    let claimed = claim().unwrap();
    assert!(
        job.lines().any(|l| l == format!("pid={}", claimed.pid)),
        "the claim is the relaunched job's: {claimed:?}, {job}"
    );
    stop_live_watch(&runner, &state);
}

#[test]
fn a_released_watch_loop_upgraded_before_setup_keeps_its_claim_until_the_runtime_is_built_then_migrates()
 {
    use std::os::unix::process::CommandExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    for fake in ["systemd-run", "systemctl", "loginctl"] {
        std::fs::remove_file(bin.join(fake)).unwrap();
    }
    runner.tools = Some(bin);
    runner.env.extend(env);
    // The package as an apply lays it out, the shipped wrapper between the
    // entry and the binary: it answers `setup-required` until the binary
    // its key names stands in the cache.
    let package = runner.state_dir().join("package");
    let scripts = package.join("orch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::fs::create_dir_all(package.join("agent-runtime/scripts")).unwrap();
    let shipped = shipped_scripts();
    std::os::unix::fs::symlink(shipped.join("lib"), scripts.join("lib")).unwrap();
    std::os::unix::fs::symlink(shipped.join("../runtime"), package.join("orch/runtime")).unwrap();
    std::os::unix::fs::symlink(
        shipped.join("../../agent-runtime/scripts/lib"),
        package.join("agent-runtime/scripts/lib"),
    )
    .unwrap();
    write_executable(
        &scripts.join("orch-runtime"),
        std::fs::read_to_string(shipped.join("orch-runtime")).unwrap(),
    );
    let cache = runner.state_dir().join("cache");
    runner.env.push((
        "AGENT_RUNTIME_CACHE".to_owned(),
        cache.display().to_string(),
    ));
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let entry = scripts.join("oversee-watch");
    write_executable(
        &entry,
        std::fs::read_to_string(fixtures().join("released-watch-loop/oversee-watch")).unwrap(),
    );
    let err = runner.state_dir().join("loop.err");
    let mut command = program(&entry);
    runner.apply_env(&mut command);
    command
        .args(["--repeat", "1", "--state", &state.display().to_string()])
        .args(["--since", "2026-01-01T00:00:00Z"])
        .current_dir(runner.state_dir())
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(&err).unwrap())
        .process_group(0);
    let mut released = ReleasedLoop {
        child: command.spawn().unwrap(),
        runner: &runner,
        state: state.clone(),
    };
    let loop_pid = released.child.id();
    let paths = orch_runtime::watch::claim::Paths::of(&state).unwrap();
    let claim = || orch_runtime::watch::claim::read(&paths).ok().flatten();
    wait_until("the loop's start-less claim", SETTLE, || {
        claim().is_some_and(|c| c.pid == loop_pid && c.start.is_none())
    });
    let next = scripts.join(".oversee-watch.next");
    write_executable(
        &next,
        std::fs::read_to_string(shipped.join("oversee-watch")).unwrap(),
    );
    std::fs::rename(&next, &entry).unwrap();
    // Two passes answer the wrapper's refusal and the loop runs on with its
    // claim.
    let refused =
        format!("oversee-watch: watch-relaunch-failed pid={loop_pid} error=setup-required");
    let said = || std::fs::read_to_string(&err).unwrap_or_default();
    wait_until("two passes refused before setup", SETTLE, || {
        said().lines().filter(|l| *l == refused).count() >= 2
    });
    assert!(
        released.child.try_wait().unwrap().is_none(),
        "the loop runs on: {}",
        said()
    );
    assert!(
        claim().is_some_and(|c| c.pid == loop_pid && c.start.is_none()),
        "the loop keeps its claim: {:?}",
        claim()
    );
    assert!(
        !runner.state_dir().join("oversee-watch.runner").exists(),
        "nothing was launched"
    );
    // Setup places the binary its key names; the next pass migrates.
    let text = said();
    let key = text
        .lines()
        .find_map(|l| l.strip_prefix("orch-runtime: setup-required key="))
        .and_then(|rest| rest.split_whitespace().next())
        .expect("the wrapper's own line names its key")
        .to_owned();
    std::fs::create_dir_all(cache.join("bin")).unwrap();
    std::os::unix::fs::symlink(
        runner.state_dir().join("orch-runtime"),
        cache.join("bin").join(format!("orch-runtime-{key}")),
    )
    .unwrap();
    let deadline = Instant::now() + SETTLE;
    let status = loop {
        if let Some(status) = released.child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "the released loop never ended: {}",
            said()
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success(), "{status:?}: {}", said());
    let claimed = claim().expect("a claim stands once the loop has ended");
    assert!(
        claimed.start.is_some() && live(claimed.pid) && claimed.pid != loop_pid,
        "the runtime's claim stood before the loop was told to end: {claimed:?}"
    );
    let job = std::fs::read_to_string(runner.state_dir().join("oversee-watch.runner")).unwrap();
    assert!(
        job.lines().any(|l| l == format!("pid={}", claimed.pid)),
        "the claim is the relaunched job's: {claimed:?}, {job}"
    );
    stop_live_watch(&runner, &state);
}

#[test]
fn a_dead_recovery_whose_transfer_fails_is_said_and_asked_once_more_then_reported() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-unconfirmed");
    runner.verify = Some(1);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let (bin, env) = watch_world(&work);
    runner.tools = Some(bin);
    runner.env.extend(env);
    let pane = server.open_window("overseer", &work, "bash --norc --noprofile");
    let agent_runtime::reading::Reading::Live(fields) = agent_runtime::host::tmux::pane_fields(
        &agent_runtime::host::tmux::server(&server.socket).unwrap(),
        &pane,
    ) else {
        panic!("the overseer's pane reads")
    };
    let ended = Owned::sleep();
    let mut record = overseer_record(ended.pid(), &ended.start(), &server, &work);
    drop(ended);
    record["pane"] = json!(pane);
    record["window"] = json!(fields.pane.window);
    record["server_start"] = json!(server.start);
    record.as_object_mut().unwrap().remove("launch_line");
    let mut fleet = runner.fleet();
    fleet["overseer"] = record;
    runner.write_fleet(&fleet);
    let state = work.join(agent_runtime::record::FLEET_FILE_NAME);
    let paths = orch_runtime::watch::claim::Paths::of(&state).unwrap();
    let err = work.join("watch.err");
    let mut watch = isolated();
    watch
        .args(["--state-dir", &work.display().to_string()])
        .args(["watch", "run", "--file", &state.display().to_string()])
        .args(watch_reach(&runner, &work))
        .args(["--interval", "1", "--since", "2026-01-01T00:00:00Z"])
        .current_dir(&work)
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(&err).unwrap());
    runner.apply_env(&mut watch);
    let mut watch = Owned(watch.spawn().expect("watch run"));
    let transfers = |runner: &Runner| -> Vec<Value> {
        runner.fleet()["intents"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|i| i["op"] == "request-transfer")
            .collect()
    };
    let key = format!("{} {pane}", server.pid);
    let row = || {
        orch_runtime::watch::Baseline::load(&paths.baseline)
            .ok()
            .and_then(|b| b.get("overseer-dead", &key).map(str::to_owned))
    };
    // The watch is stopped before any assertion, so a failing row leaves no
    // watch running.
    let deadline = Instant::now() + Duration::from_secs(120);
    while row().as_deref() != Some("reported") && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let reported = row();
    let asked = transfers(&runner);
    let said = std::fs::read_to_string(&err).unwrap_or_default();
    stop_live_watch(&runner, &state);
    let _ = watch.0.wait();
    assert_eq!(reported.as_deref(), Some("reported"), "{said}");
    assert_eq!(
        asked.len(),
        2,
        "the failed transfer is asked once more: {asked:?}"
    );
    for intent in &asked {
        assert_eq!(intent["outcome"], "failed", "{intent}");
        assert_eq!(
            intent["observation"]["note"], "successor-not-ready",
            "{intent}"
        );
    }
    for (attempt, retry) in [(1, "pending"), (2, "exhausted")] {
        let line = format!(
            "overseer-relaunch-failed pane={pane} attempt={attempt} retry={retry} step=successor-not-ready"
        );
        assert_eq!(
            said.lines().filter(|l| *l == line).count(),
            1,
            "each failed transfer is said once: {said}"
        );
    }
}

#[test]
fn a_brief_refused_before_its_paste_is_typed_on_the_repeat_and_one_whose_paste_went_unanswered_never_twice()
 {
    // (the tmux verb refused once, the note, the repeat's outcome, the
    // turns the runner recorded after the repeat)
    let cases = [
        ("load-buffer", "brief-unsent", "confirmed", 1),
        ("paste-buffer", "brief-undelivered", "unconfirmed", 0),
    ];
    for (verb, note, repeat, turns) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        runner.verify = Some(3);
        runner.init_fleet();
        let work = runner.state_dir();
        let tools = work.join("refusing-tools");
        std::fs::create_dir(&tools).unwrap();
        // The first launch types its line through load-buffer and
        // paste-buffer; the brief is the second of each, refused once.
        let shim = tools.join("tmux");
        let body = r#"#!/bin/bash
set -eu
for arg in "$@"; do
  if [ "$arg" = "__VERB__" ]; then
    count=0
    [ ! -f "$REFUSE_COUNT" ] || count="$(cat "$REFUSE_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$REFUSE_COUNT"
    if [ "$count" -eq 2 ]; then
      printf 'refused: %s\n' "$arg" >&2
      exit 1
    fi
  fi
done
exec "__TMUX__" "$@"
"#;
        write_executable(
            &shim,
            body.replace("__VERB__", verb)
                .replace("__TMUX__", &which_tmux()),
        );
        runner.env.push((
            "REFUSE_COUNT".to_owned(),
            work.join("refuse-count").display().to_string(),
        ));
        runner.tools = Some(tools);
        let request = json!({"op": "start-controller", "controller": pending(runner.state_dir())});
        let first = effect_report(&runner.op_fleet(&request));
        assert_eq!(first["intent"]["outcome"], "unconfirmed", "{verb}: {first}");
        assert_eq!(
            first["intent"]["observation"]["note"], note,
            "{verb}: {first}"
        );
        assert!(
            runner
                .stub_turns(runner.state_dir(), runner.state_dir())
                .is_empty(),
            "{verb}: no turn before the repeat"
        );
        let second = effect_report(&runner.op_fleet(&request));
        assert_eq!(second["intent"]["outcome"], repeat, "{verb}: {second}");
        assert_eq!(
            runner
                .stub_turns(runner.state_dir(), runner.state_dir())
                .len(),
            turns,
            "{verb}: the brief typed once at most"
        );
    }
}

#[test]
fn a_transfer_asked_with_effect_exit_answers_its_jobs_outcome_not_its_start() {
    // A successor that never draws its composer fails before retirement,
    // the predecessor kept, status 3 with the job's note; one at its
    // composer is up under its recorded identity, status 0, and the job
    // goes on to retire the predecessor once this caller has exited.
    for (stub, code) in [("stub-unconfirmed", 3), ("stub-confirm", 0)] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, stub);
        runner.verify = Some(1);
        runner.init_fleet();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let path = runner.state_dir().join("transfer.json");
        std::fs::write(
            &path,
            serde_json::to_vec(&transfer_request(&server, runner.state_dir())).unwrap(),
        )
        .unwrap();
        let mut op = isolated();
        op.args(["--state-dir", &runner.state_dir().display().to_string()])
            .args(["op", "--fleet", "--effect-exit", "--request"])
            .arg(&path);
        runner.apply_env(&mut op);
        let out = op.output().unwrap();
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
        assert_eq!(
            out.status.code(),
            Some(code),
            "{stub}: {reply}\n{}",
            stderr(&out)
        );
        assert_eq!(
            reply["result"]["effect"]["started"], "transfer-started",
            "{stub}: {reply}"
        );
        let settled = &reply["result"]["settled"];
        if code == 3 {
            assert_eq!(settled["outcome"], "failed", "{stub}: {reply}");
            assert_eq!(
                settled["observation"]["note"], "successor-not-ready",
                "{stub}: {reply}"
            );
            assert!(live(predecessor.pid()), "the predecessor keeps running");
        } else {
            assert!(
                settled["outcome"] == "confirmed" || settled["phase"]["identity"].is_object(),
                "{stub}: the successor stands under its identity: {reply}"
            );
            let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
            assert_eq!(intent["outcome"], "confirmed", "{stub}: {intent}");
        }
    }
}

#[test]
fn a_notice_whose_send_got_no_answer_is_sent_once_more_by_the_heartbeat_and_never_by_a_walk() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-unconfirmed");
    runner.verify = Some(1);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let (bin, env) = watch_world(&work);
    runner.tools = Some(bin);
    runner.env.extend(env);
    // The mailbox's first notice ends by a signal before it answers; every
    // later call answers.
    let sends = work.join("notices.log");
    let lost = work.join("notice-lost");
    let mailbox = work.join("lane-mail-lossy");
    write_executable(
        &mailbox,
        format!(
            "#!/bin/bash\nif [ \"${{1:-}}\" = notice ]; then\n  printf 'notice\\n' >> '{sends}'\n  if [ ! -e '{lost}' ]; then : > '{lost}'; kill -KILL $$; fi\n  exit 0\nfi\nexec '{quiet}' \"$@\"\n",
            sends = sends.display(),
            lost = lost.display(),
            quiet = fixtures().join("lane-mail-quiet/lane-mail").display(),
        ),
    );
    runner
        .env
        .push(("LANE_MAIL_CLI".to_owned(), mailbox.display().to_string()));
    let sent = || {
        std::fs::read_to_string(&sends)
            .unwrap_or_default()
            .lines()
            .count()
    };
    let mark = |runner: &Runner| {
        runner.fleet()["intents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["op"] == "request-transfer")
            .map(|i| i["notice"]["owner"].as_str().unwrap_or("").to_owned())
            .unwrap_or_default()
    };
    // A transfer whose successor never draws fails and owes its notice; the
    // send gets no answer.
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    runner.transfer_started(&transfer_request(&server, &work));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert!(
        mark(&runner).starts_with("unanswered:"),
        "{}",
        mark(&runner)
    );
    assert_eq!(sent(), 1);
    // A request's walk and a reconcile send nothing more.
    let _ = runner.op_fleet(&json!({"op": "close-owned-resources", "item": "KEN-NONE"}));
    let _ = runner.run(&["reconcile", "--fleet"]);
    assert_eq!(sent(), 1, "no walk resends an unanswered notice");
    // The record's server named by a live process no socket answers for:
    // the watch cannot tell its controller from gone, so the overseer duty
    // says nothing and sends no death alert of its own.
    let mut fleet = runner.fleet();
    fleet["overseer"]["server"] = json!(predecessor.pid().to_string());
    runner.write_fleet(&fleet);
    // The watch's heartbeat sends it once more, and marks it.
    let state = work.join(agent_runtime::record::FLEET_FILE_NAME);
    let mut watch = isolated();
    watch
        .args(["--state-dir", &work.display().to_string()])
        .args(["watch", "run", "--file", &state.display().to_string()])
        .args(watch_reach(&runner, &work))
        .args(["--interval", "1", "--max-loops", "1"])
        .args(["--since", "2026-01-01T00:00:00Z"])
        .current_dir(&work)
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(work.join("watch.err")).unwrap());
    runner.apply_env(&mut watch);
    let mut watch = Owned(watch.spawn().expect("watch run"));
    let deadline = Instant::now() + SETTLE;
    while mark(&runner) != "sent" && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let marked = mark(&runner);
    stop_live_watch(&runner, &state);
    let _ = watch.0.wait();
    let log = runner.run(&["watch", "log", "--fleet"]);
    assert_eq!(
        marked,
        "sent",
        "{}\n{}",
        std::fs::read_to_string(work.join("watch.err")).unwrap_or_default(),
        String::from_utf8_lossy(&log.stdout)
    );
    assert_eq!(sent(), 2, "sent once more");
}

#[test]
fn a_transfer_the_watch_asked_whose_job_never_claimed_is_settled_by_the_watch_itself() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let (bin, env) = watch_world(&work);
    // The job launcher takes its setsid route, whose child never claims.
    for fake in ["systemd-run", "systemctl", "loginctl"] {
        std::fs::remove_file(bin.join(fake)).unwrap();
    }
    for tool in ["setsid", "loginctl"] {
        std::os::unix::fs::symlink(fixtures().join("setsid-sleeper").join(tool), bin.join(tool))
            .unwrap();
    }
    runner.tools = Some(bin);
    runner.env.extend(env);
    runner
        .env
        .push(("AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(), "1".to_owned()));
    let pane = server.open_window("overseer", &work, "bash --norc --noprofile");
    let agent_runtime::reading::Reading::Live(fields) = agent_runtime::host::tmux::pane_fields(
        &agent_runtime::host::tmux::server(&server.socket).unwrap(),
        &pane,
    ) else {
        panic!("the overseer's pane reads")
    };
    let ended = Owned::sleep();
    let mut record = overseer_record(ended.pid(), &ended.start(), &server, &work);
    drop(ended);
    record["pane"] = json!(pane);
    record["window"] = json!(fields.pane.window);
    record["server_start"] = json!(server.start);
    record.as_object_mut().unwrap().remove("launch_line");
    let mut fleet = runner.fleet();
    fleet["overseer"] = record;
    runner.write_fleet(&fleet);
    let state = work.join(agent_runtime::record::FLEET_FILE_NAME);
    let mut watch = isolated();
    watch
        .args(["--state-dir", &work.display().to_string()])
        .args(["watch", "run", "--file", &state.display().to_string()])
        .args(watch_reach(&runner, &work))
        .args(["--interval", "1", "--since", "2026-01-01T00:00:00Z"])
        .current_dir(&work)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    runner.apply_env(&mut watch);
    let mut watch = Owned(watch.spawn().expect("watch run"));
    let transfers = |runner: &Runner| -> Vec<Value> {
        runner.fleet()["intents"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|i| i["op"] == "request-transfer")
            .collect()
    };
    let sleepers = |runner: &Runner| -> Vec<u32> {
        transfers(runner)
            .iter()
            .filter_map(|i| remaining(&i["observation"], "job")["pid"].as_u64())
            .map(|pid| pid as u32)
            .collect()
    };
    // The first transfer's job is launched and never claims: the intent
    // stands open, the watch its owner.
    let deadline = Instant::now() + SETTLE;
    while sleepers(&runner).is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let first = transfers(&runner).first().cloned().unwrap_or(Value::Null);
    let held = (first["outcome"].clone(), first["owner"]["pid"].as_u64());
    for pid in sleepers(&runner) {
        end_sleeper(pid);
    }
    // Its job ended: the watch's own reconcile reads it gone and closes the
    // intent, where it deferred to itself as a live owner.
    let id = first["id"].clone();
    let settled = || {
        transfers(&runner)
            .into_iter()
            .find(|i| i["id"] == id)
            .is_some_and(|i| i["outcome"] == "failed")
    };
    let deadline = Instant::now() + SETTLE;
    while !settled() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    let closed = settled();
    stop_live_watch(&runner, &state);
    let _ = watch.0.wait();
    for pid in sleepers(&runner) {
        end_sleeper(pid);
    }
    assert_eq!(
        held,
        (json!("unconfirmed"), Some(u64::from(watch.pid()))),
        "{first}"
    );
    assert!(closed, "{}", json!(transfers(&runner)));
}

/// The caller's argv reaches the launched command exactly as given, the
/// judged posture travels as its own field, and the builder derives the
/// environment from the posture: a `native` posture whose words carry the
/// harness's bypass word refuses `permission-mismatch` before any window; a
/// `bypass` posture whose words already carry it adds no second word and
/// sets the prompt-suppression values; the dead-pane Copilot bypass
/// replay's half, a Copilot `bypass` with `--allow-all` among its words,
/// sets `COPILOT_ALLOW_ALL=true` with the word once.
#[test]
fn the_callers_argv_reaches_the_launch_as_given_under_the_posture_it_spells() {
    // A two-word value stays one argv element.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-record");
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
    let runner = suite_runner(&server, "stub-record");
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
    let runner = suite_runner(&server, "stub-record");
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
    assert_eq!(
        launched_var(
            &launched,
            "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS"
        ),
        "1"
    );

    // Copilot under bypass with its replayed `--allow-all`: the word once and
    // `COPILOT_ALLOW_ALL=true`.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let seat = dir.path().join("copilot-home");
    std::fs::create_dir_all(&seat).unwrap();
    copilot_gate_passed(&mut runner, &seat);
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
    runner.transfer_started_env(&request, &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)]);
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

/// A stop that reads `Unreadable` before it sends any signal (a `ps` that
/// fails for the predecessor's pid, whose recorded start is the `lstart`
/// form read through `ps`) leaves the predecessor as it was. Its handles
/// return to its record, discharged `not-signalled` by that answer, and the
/// succession fails before retirement with the pending restored: the
/// healthy predecessor runs on and a new controller operation is not
/// refused `intent-open`.
#[test]
fn a_stop_unread_before_any_signal_fails_before_retirement_and_restores_the_pending() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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
    write_executable(
        &ps,
        format!(
            "#!/bin/bash\nfor a; do last=$a; done\nif [ \"$last\" = {pid} ]; then exit 2; fi\nexec /usr/bin/ps \"$@\"\n",
            pid = predecessor.pid()
        ),
    );
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

/// A stop that signalled and timed out (a `kill` that signals nothing)
/// holds the succession with the predecessor live; the reconcile, reading
/// it live, runs the stop again through the signalling method, and with the
/// host's own `kill` the predecessor ends.
#[test]
fn a_live_predecessor_after_a_timed_out_stop_is_re_signalled_by_the_reconcile() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
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

/// A `native` posture with a narrower permission word launches with exactly
/// that word and no bypass word or environment, for each harness's narrower
/// spelling; a `native` posture carrying a full-bypass alias refuses
/// `permission-mismatch`.
#[test]
fn a_native_posture_keeps_a_narrower_permission_word_and_refuses_a_bypass_alias() {
    // `started`: the words admit the posture, so the successor's stub runs
    // and its record is read once it stands; a mismatch is refused before
    // any window, and no record is awaited.
    let launch = |harness: &str, words: &[&str], started: bool| -> (Value, Value) {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let seat = dir.path().join("seat");
        plant_credential(&seat);
        plant_codex_credential(&seat);
        copilot_gate_passed(&mut runner, &seat);
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
        runner.transfer_started_env(&request, &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)]);
        let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
        let launched = if started {
            launch_record(runner.state_dir())
        } else {
            Value::Null
        };
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
        let (intent, launched) = launch(harness, words, true);
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
    let (intent, _) = launch("copilot", &["--yolo"], false);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        intent["observation"]["note"], "permission-mismatch",
        "{intent}"
    );
    // A `native` posture whose words carry a narrower permission word before
    // a full-bypass one is a mismatch; the builder reads every word, not the
    // first.
    let (intent, _) = launch(
        "claude",
        &[
            "--permission-mode=dontAsk",
            "--dangerously-skip-permissions",
        ],
        false,
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

/// The reconcile reads the launcher's record at the sidecar's recorded
/// address three-valued: a `status=` word, the rewrite a launch that ended
/// after its fork leaves, settles the job as nothing started; a record
/// naming no identity, what a launcher crash between its pre-write and its
/// identity read leaves, holds the job `possibly-started`; a record naming
/// a gone identity discharges the job `job-exited` and the transfer fails;
/// a record that cannot be read holds the job. The predecessor the job
/// never retired stands in every case.
#[test]
fn the_reconcile_reads_a_launcher_record_three_valued() {
    // record text (a directory where `None`), outcome, observation job word, a job remains
    let rows: [(Option<&str>, &str, Option<&str>, bool); 4] = [
        (
            Some("runner=setsid\nstatus=identity-unread\nline=runner=setsid reason=no-linger\n"),
            "failed",
            None,
            false,
        ),
        (
            Some("runner=setsid\nline=runner=setsid reason=no-linger\n"),
            "unconfirmed",
            Some("possibly-started"),
            true,
        ),
        (
            Some(
                "runner=setsid\npid=2000000000\nstart=ticks:1\nline=runner=setsid reason=no-linger\n",
            ),
            "failed",
            Some("ended"),
            false,
        ),
        (None, "unconfirmed", Some("possibly-started"), true),
    ];
    for (text, outcome, job, remains) in rows {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = suite_runner(&server, "stub-confirm");
        runner.init_fleet();
        let predecessor = Owned::sleep();
        plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
        let id = "request-transfer:overseer:3:1-1";
        let mut fleet = runner.fleet();
        fleet["intents"] = json!([{
            "id": id, "op": "request-transfer", "target": "overseer:3", "created_at": "2026-01-29T15:20:00Z", "outcome": "not-started",
            "obligations": {"standing": [{"kind": "job-sidecar", "record": job_record(&runner, id), "role": "job"}], "discharged": [], "signalled": false},
        }]);
        runner.write_fleet(&fleet);
        let record = runner.state_dir().join("intents").join(format!("{id}.job"));
        std::fs::create_dir_all(record.parent().unwrap()).unwrap();
        match text {
            Some(text) => std::fs::write(&record, text).unwrap(),
            None => std::fs::create_dir(&record).unwrap(),
        }
        let report = runner.reconcile_one();
        let observation = &report["intent"]["observation"];
        assert_eq!(report["intent"]["outcome"], outcome, "{text:?}: {report}");
        assert_eq!(
            observation.get("job").and_then(Value::as_str),
            job,
            "{text:?}: {report}"
        );
        assert_eq!(
            !remaining(observation, "job").is_null(),
            remains,
            "{text:?}: {report}"
        );
        assert!(
            live(predecessor.pid()),
            "{text:?}: nothing retired the predecessor"
        );
    }
}

/// The world a start's fleet watch launches into, in the runner's state
/// directory `dir`: `bin`, for the op's `PATH`, holds the cutover fakes as
/// the user manager (`systemd-run` runs a unit's argv under setsid and
/// records its pid under `bin/units/<unit>`), the `gh` fixture that
/// answers the credential ladder and the usage fixture as `curl`, its
/// answers under `usage-fixtures`; beside it the runtime wrapper the watch
/// words name (the test binary, as the shipped wrapper execs the keyed
/// binary), the report judge fixture, and the github skill under the
/// project's install layout, whose ladder `watch run` runs before it
/// claims. The op's environment reaches the job as the launcher's own.
/// Returns `bin` and the environment the op carries for the watch.
fn watch_world(dir: &Path) -> (std::path::PathBuf, Vec<(String, String)>) {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    for fake in ["systemd-run", "systemctl", "loginctl"] {
        let to = bin.join(fake);
        write_executable(
            &to,
            std::fs::read_to_string(fixtures().join("cutover-fakes").join(fake)).unwrap(),
        );
    }
    std::os::unix::fs::symlink(fixtures().join("gh-auth-fixture/gh"), bin.join("gh")).unwrap();
    // The account the state directory holds (`init_fleet`'s credential) has
    // room for the watch's whole life: a controller the watch reads live has
    // its account marks judged on every pass.
    std::os::unix::fs::symlink(account_fixtures().join("usage-curl/curl"), bin.join("curl"))
        .unwrap();
    let usage = dir.join("usage-fixtures");
    std::fs::create_dir_all(&usage).unwrap();
    std::fs::write(
        usage.join("planted.usage.json"),
        json!({"five_hour": {"utilization": 5, "resets_at": "2027-01-01T00:00:00Z"},
            "seven_day": {"utilization": 20, "resets_at": "2027-01-01T00:00:00Z"}})
        .to_string(),
    )
    .unwrap();
    github_skill_under(dir);
    let report = dir.join("oversee-report");
    std::os::unix::fs::symlink(
        fixtures().join("oversee-report-fixture/oversee-report"),
        &report,
    )
    .unwrap();
    let wrapper = dir.join("orch-runtime");
    write_executable(
        &wrapper,
        format!(
            "#!/bin/bash\nexec \"{}\" --no-private-env \"$@\"\n",
            binary().display()
        ),
    );
    let env = vec![
        ("ORCH_SECURITY_ALERTS".to_owned(), "off".to_owned()),
        (
            "ORCH_AGENT_RUNTIME".to_owned(),
            fixtures()
                .join("agent-runtime-built/agent-runtime")
                .display()
                .to_string(),
        ),
        (
            "OVERSEE_WATCH_REPORT".to_owned(),
            report.display().to_string(),
        ),
        ("ORCH_STATE_DIR".to_owned(), dir.display().to_string()),
        ("USAGE_FIXTURE_DIR".to_owned(), usage.display().to_string()),
    ];
    (bin, env)
}

/// A test child whose world plants no answer for a provider's program runs
/// the constructor's refusal, never the operator's program: a watch whose
/// controller reads live judges its account on every pass, and a world
/// with a credential and no usage answer otherwise sends that read through
/// the operator's `curl` to the real endpoint. `--version` reaches nothing
/// either way.
#[test]
fn a_test_child_with_no_planted_answer_runs_the_refusing_provider_programs() {
    for name in ["curl", "codex", "secret-tool", "ssh", "gh"] {
        let out = program(name).arg("--version").output().expect(name);
        let said = stderr(&out);
        assert_eq!(
            (out.status.code(), said.as_str()),
            (
                Some(4),
                format!("{name}: no fixture on PATH answers: --version\n").as_str()
            ),
            "{name} answered: {}",
            String::from_utf8_lossy(&out.stdout)
        );
    }
}

/// The watch words a `start-controller` request carries for the fleet
/// state `state`: the runtime wrapper beside it, `watch run --file` the
/// state and the flags the workflow's launch composes. `--repo` is left out: the
/// row claims the watch, and a repository would set the GitHub duty
/// reading.
fn watch_words(state: &Path) -> Value {
    let wrapper = state.parent().unwrap().join("orch-runtime");
    json!([
        wrapper.display().to_string(),
        "watch",
        "run",
        "--file",
        state.display().to_string(),
        "--interval",
        "240",
        "--since",
        "2026-01-01T00:00:00Z",
    ])
}

/// The request carries the watch words; the effect launches them through
/// its own launcher as a unit of the cutover fakes' user manager once the
/// runner is read at its composer, and the row reads the claim the runtime
/// wrote, the record's `overseer.watch` naming the unit the manager
/// started, and the job discharged by that claim. A launch that cannot open
/// the watch's stderr file (a directory stands at its path) leaves the
/// start `unconfirmed` naming the launch, the record naming no controller
/// and the runner standing for the reconcile.
#[test]
fn start_controller_launches_the_fleet_watch_and_a_refused_launch_is_unconfirmed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    runner.tools = Some(bin.clone());
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let report = effect_report(&runner.op_fleet_env(
        &json!({
            "op": "start-controller",
            "controller": pending(runner.state_dir()),
            "watch": watch_words(&state),
        }),
        &env,
    ));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 1, "{overseer}");
    assert_eq!(overseer["watch"]["runner"], "systemd", "{overseer}");
    let unit = overseer["watch"]["unit"].as_str().unwrap().to_owned();
    assert!(unit.starts_with("orch-watch-"), "{unit}");
    assert!(
        bin.join("units").join(&unit).is_file(),
        "the manager started the unit the record names"
    );
    let paths = orch_runtime::watch::claim::Paths::of(&state).unwrap();
    let claim = orch_runtime::watch::claim::read(&paths)
        .unwrap()
        .expect("the runtime claimed the fleet state");
    assert!(live(claim.pid), "a live runtime claim: {claim:?}");
    // The watch names on its own command line, after the request's words,
    // the mailbox and the server the start reached.
    let argv: Vec<String> = std::fs::read(format!("/proc/{}/cmdline", claim.pid))
        .unwrap()
        .split(|b| *b == 0)
        .filter(|w| !w.is_empty())
        .map(|w| String::from_utf8_lossy(w).into_owned())
        .collect();
    let intent = runner.fleet()["intents"][0].clone();
    let out = runner.run(&["watch", "stop", "--file", &state.display().to_string()]);
    assert!(out.status.success(), "watch stop: {}", stderr(&out));
    wait_until("the stopped watch ended", secs(20), || !live(claim.pid));
    assert_eq!(
        discharged_by(&intent, "watch-claimed").len(),
        1,
        "the job is the fleet's once its claim stands: {intent}"
    );
    let at = argv.iter().position(|w| w == "--mail-program").unwrap_or(0);
    let reach = &argv[at..(at + 6).min(argv.len())];
    assert_eq!(reach.len(), 6, "{argv:?}");
    let canonical = |p: &str| std::fs::canonicalize(p).unwrap_or_else(|_| p.into());
    assert_eq!(
        (
            reach[0].as_str(),
            std::path::PathBuf::from(&reach[1]),
            reach[2].as_str(),
            canonical(&reach[3]),
            reach[4].as_str(),
            std::path::PathBuf::from(&reach[5]),
        ),
        (
            "--mail-program",
            fixtures().join("lane-mail-quiet/lane-mail"),
            "--mail-root",
            std::fs::canonicalize(runner.state_dir()).unwrap(),
            "--socket",
            server.socket.clone(),
        ),
        "{argv:?}"
    );

    // The watch's stderr file cannot be opened: nothing started, the start
    // held with the cause.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let bin = runner.state_dir().join("no-linger-bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("setsid-sleeper/loginctl"),
        bin.join("loginctl"),
    )
    .unwrap();
    std::fs::create_dir(runner.state_dir().join("oversee-watch.err")).unwrap();
    runner.tools = Some(bin);
    let mail_log = runner.state_dir().join("lane-mail.log");
    let snapshot = runner.state_dir().join("at-notice.json");
    let mailbox = snapshot_mailbox(&runner, &snapshot, &mail_log);
    let report = effect_report(&runner.op_fleet_env(
        &json!({
            "op": "start-controller",
            "controller": pending(runner.state_dir()),
            "watch": watch_words(&state),
        }),
        &[("LANE_MAIL_CLI", mailbox.to_str().unwrap())],
    ));
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"], "watch-launch-failed",
        "{report}"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert!(
        overseer.get("generation").is_none(),
        "no controller is published without its watch: {overseer}"
    );
    assert!(overseer.get("watch").is_none(), "{overseer}");
    assert!(
        overseer["pending"]["runner"]["pane"].is_string(),
        "the runner stands for the reconcile: {overseer}"
    );
    assert!(
        orch_runtime::watch::claim::read(&orch_runtime::watch::claim::Paths::of(&state).unwrap())
            .unwrap()
            .is_none(),
        "nothing claimed the fleet state"
    );
    // The hold owes the owner one notice, recorded `owed` with the outcome
    // before the send runs, sent once and marked.
    let intent = runner.fleet()["intents"][0].clone();
    let text = format!(
        "orch-runtime: watch-launch-failed op=start-controller intent={} outcome=unconfirmed cause={}",
        intent["id"].as_str().unwrap(),
        intent["observation"]["cause"].as_str().unwrap()
    );
    assert_eq!(intent["notice"]["key"], "watch-launch-failed", "{intent}");
    assert_eq!(intent["notice"]["text"], text, "{intent}");
    assert_eq!(intent["notice"]["owner"], "sent", "{intent}");
    let at_send: Value =
        serde_json::from_str(&std::fs::read_to_string(&snapshot).unwrap()).unwrap();
    assert_eq!(
        at_send["intents"][0]["outcome"], "unconfirmed",
        "the hold was recorded before the send: {at_send}"
    );
    assert_eq!(
        at_send["intents"][0]["notice"]["owner"], "owed",
        "{at_send}"
    );
    assert_eq!(owner_notices(&mail_log), 1, "sent once");
    let calls = std::fs::read_to_string(&mail_log).unwrap();
    assert!(
        calls.lines().any(|l| l == format!("notice-text {text}")),
        "{calls}"
    );
    let log = runner.fleet()["fleet_log"].clone();
    assert_eq!(
        log.as_array().unwrap().last().unwrap()["text"],
        text,
        "{log}"
    );
}

/// The mailbox CLI of the owner-notice assertions: a `notice` copies the
/// runner's fleet file to `snapshot` as it stands at the call and logs the
/// call's argv and the notice's first line to `log`, so a row reads what
/// the record said when the send ran. Written beside the fleet state,
/// executable; the path.
fn snapshot_mailbox(runner: &Runner, snapshot: &Path, log: &Path) -> std::path::PathBuf {
    let fleet = runner.state_dir().join("workflow-state-oversee.json");
    let script = [
        "#!/bin/bash".to_owned(),
        "set -u".to_owned(),
        format!("printf '%s\\n' \"$*\" >> '{}'", log.display()),
        "[ \"${1:-}\" = notice ] || exit 0".to_owned(),
        format!("cp -- '{}' '{}'", fleet.display(), snapshot.display()),
        "file=\"\"".to_owned(),
        "while [ $# -gt 0 ]; do case \"$1\" in --file) file=${2:-}; shift ;; esac; shift; done"
            .to_owned(),
        format!(
            "{{ printf 'notice-text '; sed -n 1p -- \"$file\"; }} >> '{}'",
            log.display()
        ),
        String::new(),
    ]
    .join("\n");
    let path = runner.state_dir().join("lane-mail");
    write_executable(&path, script);
    path
}

/// The start's process dies the moment it has recorded the launched job's
/// identity in the intent's set, before the claim wait: the `setsid`
/// fixture that execs the job watches the fleet record for the group naming
/// its own pid, then kills its launcher and sleeps on as the job the row
/// owns. The reconcile then reads the job by that identity: live, it holds
/// the start with the job standing and launches nothing, owing the owner
/// one notice; gone, it discharges `job-exited` and launches once more, the
/// fixture this time execing the real `setsid` on the words as given, so
/// the watch claims and the reconcile confirms the start.
#[test]
fn a_crash_between_the_watch_launch_and_its_record_read_launches_no_second_watch() {
    use std::os::unix::process::ExitStatusExt;
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    for fake in ["systemd-run", "systemctl", "loginctl"] {
        std::fs::remove_file(bin.join(fake)).unwrap();
    }
    for tool in ["setsid", "loginctl"] {
        std::os::unix::fs::symlink(fixtures().join("setsid-crash").join(tool), bin.join(tool))
            .unwrap();
    }
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let log = runner.state_dir().join("setsid.log");
    let once = runner.state_dir().join("setsid.crashed");
    let real_setsid = {
        let out = std::process::Command::new("sh")
            .args(["-c", "command -v setsid"])
            .output()
            .expect("which setsid");
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    };
    let mut crash_env: Vec<(&str, &str)> =
        env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let log_s = log.display().to_string();
    let once_s = once.display().to_string();
    crash_env.extend([
        ("SETSID_LOG", log_s.as_str()),
        ("SETSID_CRASH_ONCE", once_s.as_str()),
        ("SETSID_REAL", real_setsid.as_str()),
    ]);
    let mut op = runner.spawn_op_fleet(
        &json!({
            "op": "start-controller",
            "controller": pending(runner.state_dir()),
            "watch": watch_words(&state),
        }),
        &crash_env,
        &bin,
    );
    let status = op.wait().unwrap();
    assert_eq!(
        status.signal(),
        Some(9),
        "the job's fixture ended the start once its identity was recorded: {status:?}"
    );
    let intent = runner.fleet()["intents"][0].clone();
    assert_eq!(intent["outcome"], "not-started", "{intent}");
    let watch = standing_job_pid(&runner);
    assert!(live(watch), "the job the start recorded runs on: {intent}");
    let record = std::fs::read_to_string(runner.state_dir().join("oversee-watch.runner")).unwrap();
    assert!(
        record.contains(&format!("pid={watch}\nstart={}\n", start_of(watch))),
        "the record names the job the set names: {record}"
    );
    assert_eq!(launches(&log), 1, "the crashed start's own launch");
    runner.tools = Some(bin.clone());
    runner.env.extend(env.iter().cloned());
    runner.env.extend([
        ("SETSID_LOG".to_owned(), log_s.clone()),
        ("SETSID_CRASH_ONCE".to_owned(), once_s.clone()),
        ("SETSID_REAL".to_owned(), real_setsid.clone()),
    ]);
    // Live: the job stands by its identity; nothing launches over it.
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "unconfirmed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"], "watch-unclaimed",
        "{report}"
    );
    assert_eq!(report["intent"]["observation"]["job"], "setsid", "{report}");
    assert_eq!(
        launches(&log),
        1,
        "a live job is the watch's start; nothing launches over it"
    );
    let intent = runner.fleet()["intents"][0].clone();
    assert_eq!(
        intent["notice"]["key"], "watch-unclaimed",
        "the hold owes the owner its notice: {intent}"
    );
    assert_eq!(intent["notice"]["owner"], "sent", "{intent}");
    // Gone: the job ended, read so by its identity, and the watch is
    // launched once more, which claims and confirms the start.
    end_sleeper(watch);
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(launches(&log), 2, "one more launch, for the job read gone");
    let intent = runner.fleet()["intents"][0].clone();
    assert_eq!(discharged_by(&intent, "job-exited").len(), 1, "{intent}");
    assert_eq!(discharged_by(&intent, "watch-claimed").len(), 1, "{intent}");
    assert_eq!(
        intent["notice"]["key"], "watch-unclaimed",
        "one notice per intent: {intent}"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["watch"]["runner"], "setsid", "{overseer}");
    stop_live_watch(&runner, &state);
}

/// The orch package's `scripts/` directory beside these tests.
fn shipped_scripts() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts")
}

/// The checkout a launch of the workflow runs from, under the runner's
/// state directory: `skills/orch/scripts` links every shipped script but
/// the three this world answers for (`orch-runtime` is the wrapper
/// `watch_world` wrote around the test binary, `lanes` nothing, `lane-host`
/// the host fixture answering the local capabilities), and the sibling
/// skills the scripts source are linked beside `orch`. The listing the
/// launcher's pick reads through the runtime's judge lists `account` on
/// `harness` as the one measured account, with room: its credential under
/// the account and its usage from the usage fixture `watch_world` plants
/// as `curl` in `bin`, named to the launch through `env`. The walk's
/// `kendex tier-model` finds the `kendex-launch` fixture in `bin`, the
/// watch world's directory first on the rows' `PATH`, never the operator's
/// install. The runtime sources are linked beside `scripts` and
/// agent-runtime's planted cargo is `cargo` in `bin`, into a cache of the
/// world's own, so a successor whose directory holds this install builds
/// it as a real one does. Returns the scripts directory the launch runs
/// from.
fn launcher_checkout(
    runner: &Runner,
    bin: &Path,
    env: &mut Vec<(String, String)>,
    account: &Path,
    harness: &str,
) -> std::path::PathBuf {
    use std::os::unix::fs::symlink;
    let dir = runner.state_dir();
    symlink(
        account_fixtures().join("kendex-launch/kendex"),
        bin.join("kendex"),
    )
    .unwrap();
    let shipped = shipped_scripts();
    let skills = shipped.parent().unwrap().parent().unwrap();
    let scripts = dir.join("skills/orch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    for entry in std::fs::read_dir(skills).unwrap() {
        let entry = entry.unwrap();
        if entry.file_name() != "orch" {
            symlink(entry.path(), dir.join("skills").join(entry.file_name())).unwrap();
        }
    }
    for entry in std::fs::read_dir(&shipped).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name();
        if ["orch-runtime", "lanes", "lane-host"]
            .iter()
            .any(|n| name == *n)
        {
            continue;
        }
        symlink(entry.path(), scripts.join(name)).unwrap();
    }
    symlink(dir.join("orch-runtime"), scripts.join("orch-runtime")).unwrap();
    symlink(shipped.join("../runtime"), dir.join("skills/orch/runtime")).unwrap();
    symlink(
        skills.join("agent-runtime/tests/setup/cargo"),
        bin.join("cargo"),
    )
    .unwrap();
    env.push((
        "AGENT_RUNTIME_CACHE".to_owned(),
        dir.join("runtime-cache").display().to_string(),
    ));
    env.push((
        "FAKE_CARGO_LOG".to_owned(),
        dir.join("cargo.log").display().to_string(),
    ));
    symlink(
        fixtures().join("lane-host/lane-host"),
        scripts.join("lane-host"),
    )
    .unwrap();
    std::fs::write(
        scripts.join("lane-host.json"),
        json!({
            "capabilities": {"stdout": "kind=local\tlaunch=tmux\tchannel=mailbox\tfiles=local\tstatus=pane\tstop=local\tpool=plan\n"},
        })
        .to_string(),
    )
    .unwrap();
    let usage = dir.join("usage-fixtures");
    let (credential, body) = if harness == "codex" {
        (
            json!({"tokens": {"access_token": "token-fixture", "account_id": "acct-fixture"}}),
            json!({"rate_limit": {
                "primary_window": {"used_percent": 5, "reset_at": 1_798_761_600, "limit_window_seconds": 18_000},
                "secondary_window": {"used_percent": 20, "reset_at": 1_798_761_600, "limit_window_seconds": 604_800}}}),
        )
    } else {
        (
            json!({"claudeAiOauth": {"accessToken": "token-fixture", "refreshToken": "refresh-fixture",
                "expiresAt": 4_102_444_800_000u64, "subscriptionType": "max"}}),
            json!({"five_hour": {"utilization": 5, "resets_at": "2027-01-01T00:00:00Z"},
                "seven_day": {"utilization": 20, "resets_at": "2027-01-01T00:00:00Z"}}),
        )
    };
    let file = if harness == "codex" {
        "auth.json"
    } else {
        ".credentials.json"
    };
    std::fs::write(account.join(file), credential.to_string()).unwrap();
    std::fs::write(usage.join("token-fixture.usage.json"), body.to_string()).unwrap();
    env.push((
        "AGENT_RUNTIME_ACCOUNT_DIRS".to_owned(),
        account.display().to_string(),
    ));
    env.push((
        "OVERSEE_WATCH_STATE_DIR".to_owned(),
        dir.join("watch-state").display().to_string(),
    ));
    env.push((
        "AGENT_RUNTIME_ACCOUNT_STATE_DIR".to_owned(),
        dir.join("watch-state").display().to_string(),
    ));
    scripts
}

/// The fleet's controller launched as `workflows/oversee.md` § 1 spells it,
/// from `work` on the row's server through the runtime wrapper the scripts
/// checkout links, with one preference entry, `harness:model:high`, and
/// `program_path` as that harness's executable: the watch's world `bin` and
/// `env`, the mailbox and validation runner the quiet fixtures. `run` asks
/// the steps in the workflow's order.
#[allow(
    clippy::too_many_arguments,
    reason = "the launch's whole world, named once per row"
)]
fn workflow_launch(
    runner: &Runner,
    scripts: &Path,
    bin: &Path,
    env: &[(String, String)],
    work: &Path,
    harness: &str,
    model: &str,
    program_path: &Path,
) -> Launch {
    let mut world = vec![
        ("PATH".to_owned(), tool_path(&[bin])),
        (
            "TMUX".to_owned(),
            format!("{},0,0", runner.server_socket.display()),
        ),
        (
            "AGENT_RUNTIME_TMUX_SESSION".to_owned(),
            runner.session.clone(),
        ),
        (
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
            format!("{harness}:{model}:high"),
        ),
        (
            "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
            format!("{harness}={}", program_path.display()),
        ),
        (
            "AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(),
            SETTLE.as_secs().to_string(),
        ),
        (
            "LANE_MAIL_CLI".to_owned(),
            fixtures()
                .join("lane-mail-quiet/lane-mail")
                .display()
                .to_string(),
        ),
    ];
    world.extend(env.iter().cloned());
    Launch {
        runtime: scripts.join("orch-runtime"),
        state: runner
            .state_dir()
            .join(agent_runtime::record::FLEET_FILE_NAME),
        work: work.to_owned(),
        env: world,
        predecessor: None,
        words: Vec::new(),
        wait_secs: 10,
    }
}

/// One launch of the workflow. `wait_secs` is the bound the runtime gives
/// the session to reach its composer.
struct Launch {
    runtime: std::path::PathBuf,
    state: std::path::PathBuf,
    work: std::path::PathBuf,
    env: Vec<(String, String)>,
    predecessor: Option<String>,
    /// The caller's own permission words under the native posture, the
    /// controller's `extra_args`.
    words: Vec<String>,
    wait_secs: u64,
}

impl Launch {
    fn env(mut self, name: &str, value: &str) -> Launch {
        self.env.push((name.to_owned(), value.to_owned()));
        self
    }

    fn predecessor(mut self, pane: &str) -> Launch {
        self.predecessor = Some(pane.to_owned());
        self
    }

    fn wait_secs(mut self, secs: u64) -> Launch {
        self.wait_secs = secs;
        self
    }

    fn wrapper(mut self, path: &Path) -> Launch {
        self.runtime = path.to_owned();
        self
    }

    fn words(mut self, words: &[&str]) -> Launch {
        self.words = words.iter().map(|w| (*w).to_owned()).collect();
        self
    }

    fn runtime(&self, args: &[&str]) -> std::process::Command {
        let mut command = program(&self.runtime);
        command.args(args).current_dir(&self.work);
        for (name, value) in &self.env {
            command.env(name, value);
        }
        command
    }

    /// The workflow's steps: the fleet state where none stands, the
    /// successor the walk chose, its brief under the state's `intents/`,
    /// and the one request handed to `op --fleet`: `start-controller` with
    /// the successor as the controller and the fleet watch's words, or,
    /// named a predecessor, `request-transfer` with cause `live`, waited
    /// for under `--effect-exit`. `sync-base`, the checkout step between,
    /// is the worktree skill's own command and is not run here.
    fn run(&self) -> Launched {
        let exists = reply(
            &self
                .runtime(&["state", "exists", "--fleet"])
                .output()
                .unwrap(),
        );
        if exists["result"]["exists"] != true {
            let out = self
                .runtime(&["state", "init", "--fleet"])
                .output()
                .unwrap();
            assert!(out.status.success(), "state init: {}", stderr(&out));
        }
        let cwd = self.work.display().to_string();
        let mut args = vec!["successor", "--fleet", "--cwd", &cwd];
        if let Some(pane) = &self.predecessor {
            args.extend(["--predecessor", pane]);
        }
        let verb = self.runtime(&args).output().unwrap();
        let chosen = reply(&verb);
        if chosen["result"]["walk"]["answer"] != "lane" {
            return Launched { verb, op: None };
        }
        let mut successor = chosen["result"]["successor"].clone();
        if !self.words.is_empty() {
            successor["extra_args"] = json!(self.words);
        }
        let dir = self.state.parent().unwrap();
        let intents = dir.join("intents");
        std::fs::create_dir_all(&intents).unwrap();
        let op = if self.predecessor.is_some() {
            "request-transfer"
        } else {
            "start-controller"
        };
        let brief = intents.join(format!("{op}.{}.{}.brief", now_ms(), std::process::id()));
        std::fs::write(
            &brief,
            format!("{}\n", chosen["result"]["brief"].as_str().unwrap()),
        )
        .unwrap();
        if self.predecessor.is_some() {
            let body = intents.join("handoff-body.md");
            std::fs::write(&body, "## State\nSession: live\n").unwrap();
            let handoff = successor["handoff"]
                .as_str()
                .unwrap_or("tmp/handoffs/OVERSEER-HANDOFF.md");
            let out = self
                .runtime(&[
                    "handoff",
                    "--fleet",
                    "--body",
                    &body.display().to_string(),
                    "--handoff",
                    handoff,
                ])
                .output()
                .unwrap();
            assert!(out.status.success(), "handoff: {}", stderr(&out));
        }
        let request = if self.predecessor.is_some() {
            json!({
                "op": op,
                "cause": "live",
                "expected": chosen["result"]["expected"],
                "successor": successor,
                "brief_file": brief,
            })
        } else {
            json!({
                "op": op,
                "controller": successor,
                "brief_file": brief,
                "watch": watch_words(&self.state),
            })
        };
        let file = dir.join(format!("request.{}.json", now_ms()));
        std::fs::write(&file, request.to_string()).unwrap();
        let file = file.display().to_string();
        let mut args = vec!["op", "--fleet"];
        if self.predecessor.is_some() {
            args.push("--effect-exit");
        }
        args.extend(["--request", &file]);
        let op = self
            .runtime(&args)
            .env("AGENT_RUNTIME_TMUX_VERIFY_SECS", self.wait_secs.to_string())
            .output()
            .unwrap();
        Launched { verb, op: Some(op) }
    }
}

struct Launched {
    verb: std::process::Output,
    op: Option<std::process::Output>,
}

impl Launched {
    fn chosen(&self) -> Value {
        reply(&self.verb)
    }

    fn op(&self) -> &std::process::Output {
        self.op
            .as_ref()
            .expect("the walk chose a lane, so the request was handed over")
    }

    /// The intent a start's reply reports.
    fn started(&self) -> Value {
        reply(self.op())["result"]["effect"]["report"]["intent"].clone()
    }

    /// The intent a succession settled under `--effect-exit`.
    fn settled(&self) -> Value {
        reply(self.op())["result"]["settled"].clone()
    }
}

/// The runner's one window on the server, as the record and the receipt
/// name it: the pane that is not the session's first.
fn runner_pane(server: &Server) -> String {
    let panes: Vec<String> = server.panes().into_iter().filter(|p| p != "%0").collect();
    assert_eq!(panes.len(), 1, "one runner opened: {panes:?}");
    panes.into_iter().next().unwrap()
}

fn rollouts(home: &Path) -> Vec<std::path::PathBuf> {
    fn walk(dir: &Path, into: &mut Vec<std::path::PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, into);
            } else if path.extension().is_some_and(|e| e == "jsonl") {
                into.push(path);
            }
        }
    }
    let mut files = Vec::new();
    walk(&home.join("sessions"), &mut files);
    files.sort();
    files
}

/// The user turns the gated Codex stub's rollouts under `home` record, as
/// the text of each completed `UserMessage` item, in file order.
fn codex_turns(home: &Path) -> Vec<String> {
    let mut turns = Vec::new();
    for file in rollouts(home) {
        for line in std::fs::read_to_string(&file).unwrap().lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["type"] == "event_msg"
                && row["payload"]["type"] == "item_completed"
                && row["payload"]["item"]["type"] == "UserMessage"
            {
                turns.push(
                    row["payload"]["item"]["content"][0]["text"]
                        .as_str()
                        .unwrap()
                        .to_owned(),
                );
            }
        }
    }
    turns
}

/// The fake user manager starts the watch's unit and then its `systemd-run`
/// ends by a signal, or exits 1 with the real client's line for a reply the
/// bus dropped (`Connection reset by peer`) or for its own method timeout
/// (`Connection timed out`), or with that line carrying a manager answer
/// that holds the words of a refusal the client makes before it asks (the
/// client prints the manager's text verbatim after its own words), and the
/// manager reads the unit `not-found`, as `--collect` leaves a unit that
/// ran and ended. The launch holds the job by its unit, never a second
/// watch beside it: the record names the unit the manager started, one unit
/// stands, and no `setsid` route ran.
#[test]
fn a_unit_start_whose_answer_was_lost_or_failed_after_the_manager_acted_is_held_by_its_unit_and_never_launched_again()
 {
    // (the case, how the fake `systemd-run` ends once the unit started)
    for (case, ending) in [
        ("signal", "kill -KILL $$\n"),
        (
            "bus-reset",
            "echo 'Failed to start transient service unit: Connection reset by peer' >&2\nexit 1\n",
        ),
        (
            "client-timeout",
            "echo 'Failed to start transient service unit: Connection timed out' >&2\nexit 1\n",
        ),
        (
            "answer-with-connect-words",
            "echo 'Failed to start transient service unit: Failed to connect to the moon: No such file or directory' >&2\nexit 1\n",
        ),
        (
            "answer-with-assign-words",
            "echo 'Failed to start transient service unit: Cannot assign environment variable X: Invalid argument' >&2\nexit 1\n",
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        runner.init_fleet();
        let (bin, env) = watch_world(runner.state_dir());
        let fake = std::fs::read_to_string(bin.join("systemd-run")).unwrap();
        let lost = fake
            .strip_suffix("exit 0\n")
            .expect("the fake ends its start with exit 0")
            .to_owned()
            + ending;
        write_executable(&bin.join("systemd-run"), lost);
        let show_gone = "#!/bin/bash\nd=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\nprintf 'systemctl %s\\n' \"$*\" >> \"$d/systemd.log\"\ncase \" $* \" in\n  *\" show \"*) echo not-found; echo inactive; exit 0 ;;\nesac\nlast=\"${!#}\"\nunit=\"${last%.service}\"\n[[ -f \"$d/units/$unit\" ]] || exit 5\npid=\"$(<\"$d/units/$unit\")\"\nrm -f \"$d/units/$unit\"\nkill -TERM -- \"-$pid\" 2>/dev/null || true\nexit 0\n";
        write_executable(&bin.join("systemctl"), show_gone);
        runner.tools = Some(bin.clone());
        let state = runner
            .state_dir()
            .join(agent_runtime::record::FLEET_FILE_NAME);
        let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let report = effect_report(&runner.op_fleet_env(
            &json!({
                "op": "start-controller",
                "controller": pending(runner.state_dir()),
                "watch": watch_words(&state),
            }),
            &env,
        ));
        let overseer = runner.fleet()["overseer"].clone();
        let units = units_started(&bin);
        let record = std::fs::read_to_string(runner.state_dir().join("oversee-watch.runner"))
            .unwrap_or_default();
        stop_live_watch(&runner, &state);
        assert_eq!(report["intent"]["outcome"], "confirmed", "{case}: {report}");
        assert_eq!(overseer["watch"]["runner"], "systemd", "{case}: {overseer}");
        assert_eq!(units, 1, "{case}: one unit, no second launch: {record}");
        assert!(
            record.contains("runner=systemd") && !record.contains("runner=setsid"),
            "{case}: the launcher's record names the unit alone: {record}"
        );
    }
}

/// The fake user manager answers as the real client does under a private
/// runtime directory and a private bus: a `--setenv` name outside shell
/// syntax or a value holding a noncharacter is its parser's refusal, a bus
/// it cannot reach is its connect's, the line shaped by its own logging
/// settings and put after a planted warning, and `SYSTEMD_INVOKED_AS=run0`
/// in its own environment is run0's parser refusing `--collect` before any
/// connect. An exported bash function, or a variable holding a
/// noncharacter: the launch hands neither over and the watch runs as its
/// unit. The bus unreachable after the probe, on a plain host, one whose
/// environment asks systemd for debug logging, one whose empty ratelimit
/// setting draws the warning, or one whose `LD_PRELOAD` names a missing
/// object: the launch falls to `setsid` and the watch runs there, the job's
/// value of the client's own name handed to the unit explicitly. The
/// environment naming run0: the client runs as itself and the watch runs as
/// its unit.
#[test]
fn a_unit_start_the_client_refused_before_asking_the_manager_runs_the_job_and_no_variable_it_refuses_is_handed_to_it()
 {
    // (the case, the op's added environment, the bus unreachable after the
    // probe, the warning the client puts before its own line, the runner the
    // watch runs under, the `--setenv` word the client's invocation holds)
    for (case, extra, unreachable, warning, runner, handed) in [
        (
            "bash-function",
            ("BASH_FUNC_probe%%", "() {  :\n}"),
            false,
            None,
            "systemd",
            None,
        ),
        (
            "noncharacter",
            ("ORCH_PROBE_VALUE", "v\u{FFFF}w"),
            false,
            None,
            "systemd",
            None,
        ),
        (
            "bus-unreachable",
            ("ORCH_PROBE_VALUE", "plain"),
            true,
            None,
            "setsid",
            Some("--setenv=ORCH_PROBE_VALUE "),
        ),
        (
            "debug-logging",
            ("SYSTEMD_LOG_LEVEL", "debug"),
            true,
            None,
            "setsid",
            Some("--setenv=SYSTEMD_LOG_LEVEL=debug "),
        ),
        (
            "extra-logging",
            ("SYSTEMD_LOG_RATELIMIT_KMSG", ""),
            true,
            Some("Failed to parse log ratelimit kmsg boolean '', ignoring.\n"),
            "setsid",
            Some("--setenv=SYSTEMD_LOG_RATELIMIT_KMSG= "),
        ),
        (
            "loader",
            ("LD_PRELOAD", "/nonexistent/x.so"),
            true,
            None,
            "setsid",
            Some("--setenv=LD_PRELOAD=/nonexistent/x.so "),
        ),
        (
            "run0",
            ("SYSTEMD_INVOKED_AS", "run0"),
            false,
            None,
            "systemd",
            Some("--setenv=SYSTEMD_INVOKED_AS=run0 "),
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner_world = suite_runner(&server, "stub-confirm");
        runner_world.init_fleet();
        let (bin, env) = watch_world(runner_world.state_dir());
        if unreachable {
            std::fs::write(bin.join("unreachable"), "").unwrap();
        }
        if let Some(warning) = warning {
            std::fs::write(bin.join("warning"), warning).unwrap();
        }
        runner_world.tools = Some(bin.clone());
        let state = runner_world
            .state_dir()
            .join(agent_runtime::record::FLEET_FILE_NAME);
        let mut env: Vec<(&str, &str)> =
            env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        env.push(extra);
        let report = effect_report(&runner_world.op_fleet_env(
            &json!({
                "op": "start-controller",
                "controller": pending(runner_world.state_dir()),
                "watch": watch_words(&state),
            }),
            &env,
        ));
        let overseer = runner_world.fleet()["overseer"].clone();
        let units = units_started(&bin);
        let calls = std::fs::read_to_string(bin.join("systemd.log")).unwrap_or_default();
        let record = std::fs::read_to_string(runner_world.state_dir().join("oversee-watch.runner"))
            .unwrap_or_default();
        if report["intent"]["outcome"] == "confirmed" {
            stop_live_watch(&runner_world, &state);
        }
        assert_eq!(report["intent"]["outcome"], "confirmed", "{case}: {report}");
        assert_eq!(overseer["watch"]["runner"], runner, "{case}: {overseer}");
        assert_eq!(
            units,
            usize::from(runner == "systemd"),
            "{case}: the units the manager started: {record}"
        );
        assert!(
            !calls.contains("--setenv=BASH_FUNC") && !calls.contains("\u{FFFF}"),
            "{case}: no variable the client refuses is handed to it: {calls}"
        );
        if let Some(handed) = handed {
            assert!(
                calls.contains(handed),
                "{case}: the client's invocation hands the job's value as the client takes it: {calls}"
            );
        }
    }
}

/// Every local user reads the client's command line through
/// `/proc/<pid>/cmdline` while it runs, so no exported value, a lane's
/// token among them, may stand there. The op's environment carries a
/// token-shaped value and asks systemd for debug logging; the fake user
/// manager starts the watch's unit with the variables its `--setenv`
/// arguments resolve to, as a unit gets them. The client's recorded
/// invocation holds the variable's name and never its value, and the unit's
/// environment holds the variable with its value and the job's logging
/// setting, where the client itself runs on the runtime's.
#[test]
fn a_unit_launch_hands_the_jobs_variables_to_the_unit_and_no_value_to_the_clients_command_line() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    runner.tools = Some(bin.clone());
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let token = "ghp_value_never_on_a_command_line";
    let mut env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    env.push(("ORCH_PROBE_TOKEN", token));
    env.push(("SYSTEMD_LOG_LEVEL", "debug"));
    let report = effect_report(&runner.op_fleet_env(
        &json!({
            "op": "start-controller",
            "controller": pending(runner.state_dir()),
            "watch": watch_words(&state),
        }),
        &env,
    ));
    let overseer = runner.fleet()["overseer"].clone();
    let calls = std::fs::read_to_string(bin.join("systemd.log")).unwrap_or_default();
    let unit_env: Vec<String> = std::fs::read_dir(bin.join("units"))
        .map(|units| units.map(|unit| unit.unwrap().path()).collect::<Vec<_>>())
        .unwrap_or_default()
        .iter()
        .map(|unit| std::fs::read_to_string(unit).unwrap())
        .flat_map(|pid| std::fs::read(format!("/proc/{}/environ", pid.trim())).unwrap_or_default())
        .collect::<Vec<u8>>()
        .split(|byte| *byte == 0)
        .map(|variable| String::from_utf8_lossy(variable).into_owned())
        .collect();
    if report["intent"]["outcome"] == "confirmed" {
        stop_live_watch(&runner, &state);
    }
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    assert_eq!(overseer["watch"]["runner"], "systemd", "{overseer}");
    assert!(
        calls.contains("--setenv=ORCH_PROBE_TOKEN ") && !calls.contains(token),
        "the client's command line names the variable and never its value: {calls}"
    );
    assert!(
        unit_env.contains(&format!("ORCH_PROBE_TOKEN={token}")),
        "the unit gets the variable with its value: {unit_env:?}"
    );
    assert!(
        unit_env.contains(&"SYSTEMD_LOG_LEVEL=debug".to_owned()),
        "the unit gets the job's logging setting, not the client's: {unit_env:?}"
    );
}

/// The number of units the fake user manager started under `bin`: the fleet
/// watches launched.
fn units_started(bin: &Path) -> usize {
    std::fs::read_dir(bin.join("units")).map_or(0, |d| d.count())
}

/// The runtime's claim on the fleet state at `state`, live, then the watch
/// holding it stopped and read gone, so no row leaves a watch behind.
fn stop_live_watch(runner: &Runner, state: &Path) {
    let paths = orch_runtime::watch::claim::Paths::of(state).unwrap();
    let claim = orch_runtime::watch::claim::read(&paths)
        .unwrap()
        .expect("the runtime claimed the fleet state");
    assert!(live(claim.pid), "a live watch claim: {claim:?}");
    let out = runner.run(&["watch", "stop", "--fleet"]);
    assert!(out.status.success(), "watch stop: {}", stderr(&out));
    wait_until("the stopped watch ended", secs(20), || !live(claim.pid));
}

/// The first launch's brief outlives the process that wrote it, because the
/// runtime delivers it, and a start held before delivery is delivered by a
/// reconcile that runs after the launch ended. The row drives the
/// workflow's launch into the real runtime's `start-controller`, the join
/// of the request and the runtime's effect that a row pinned against a
/// fixture of either half misses: the gated Codex stub holds the start
/// before delivery and the start answers `unconfirmed`; the brief file the
/// intent names stands under the state directory; a repeated launch before
/// the release meets the same intent and holds, opening no second runner
/// and no watch; the gate released, the next reconcile binds the session,
/// types that file's text and publishes the controller, one intent.
#[test]
fn a_launchers_brief_outlives_it_for_the_reconcile_that_delivers_a_held_start() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, mut env) = watch_world(runner.state_dir());
    let work = runner.state_dir().join("work");
    let account = runner.state_dir().join("codex-account");
    std::fs::create_dir(&work).unwrap();
    github_skill_under(&work);
    std::fs::create_dir(&account).unwrap();
    // The account trusts the launch directory already, so the launch runs
    // under the account as its home, where the stub writes its rollout.
    std::fs::write(
        account.join("config.toml"),
        format!(
            "[projects.\"{}\"]\ntrust_level = \"trusted\"\n",
            work.display()
        ),
    )
    .unwrap();
    let gate = account.join("rollout-gate");
    mkfifo(&gate);
    let scripts = launcher_checkout(&runner, &bin, &mut env, &account, "codex");
    let codex = fixtures().join("stub-codex-gated/codex");
    let launch = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "codex",
        "gpt-6-astra",
        &codex,
    );
    let held = launch.run().started();
    assert_eq!(
        held["outcome"], "unconfirmed",
        "held before delivery: {held}"
    );
    assert_eq!(held["observation"]["note"], "session-unbound", "{held}");
    let fleet = runner.fleet();
    let intents = fleet["intents"].as_array().unwrap();
    assert_eq!(intents.len(), 1, "{fleet}");
    let intent = intents[0].clone();
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert_eq!(intent["observation"]["note"], "session-unbound", "{intent}");
    assert!(fleet["overseer"].get("generation").is_none(), "{fleet}");
    let brief = Path::new(intent["phase"]["brief"].as_str().unwrap());
    assert!(
        brief.starts_with(runner.state_dir().join("intents")),
        "the brief lives with the runtime's per-intent files: {}",
        brief.display()
    );
    let text = std::fs::read_to_string(brief)
        .unwrap_or_else(|e| panic!("the brief left with the launch: {} {e}", brief.display()));
    assert_eq!(
        server.panes().len(),
        2,
        "the runner's one pane: {:?}",
        server.panes()
    );
    let pane = runner_pane(&server);

    // A repeated launch before the release meets the open intent and holds
    // where it held: no second runner, no watch.
    let repeated = launch.run().started();
    assert_eq!(
        repeated["outcome"], "unconfirmed",
        "the same hold: {repeated}"
    );
    assert_eq!(
        repeated["observation"]["note"], "session-unbound",
        "{repeated}"
    );
    let fleet = runner.fleet();
    assert_eq!(fleet["intents"].as_array().unwrap().len(), 1, "{fleet}");
    assert_eq!(fleet["intents"][0]["id"], intent["id"], "{fleet}");
    assert_eq!(runner_pane(&server), pane, "the same runner");
    assert_eq!(units_started(&bin), 0, "no watch before the controller");

    // The rollout appears; the reconcile delivers the launch's brief and
    // publishes the controller.
    release_hold(&gate, secs(10), || format!("{:?}", server.window_names()));
    // The reconcile binds the runner by the rollout's `session_meta` line,
    // which the stub writes after it makes the directory.
    wait_until("the stub wrote its session metadata", secs(10), || {
        rollouts(&account).iter().any(|file| {
            std::fs::read_to_string(file).is_ok_and(|text| {
                text.split_once('\n')
                    .and_then(|(first, _)| serde_json::from_str::<Value>(first).ok())
                    .is_some_and(|row| row["type"] == "session_meta")
            })
        })
    });
    runner.tools = Some(bin.clone());
    runner.env.extend(env.iter().cloned());
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("codex={}", codex.display()),
    ));
    let report = runner.reconcile_one();
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let fleet = runner.fleet();
    assert_eq!(fleet["intents"].as_array().unwrap().len(), 1, "{fleet}");
    let overseer = &fleet["overseer"];
    assert_eq!(overseer["generation"], 1, "{overseer}");
    assert_eq!(overseer["harness"], "codex", "{overseer}");
    assert_eq!(overseer["pane"], pane, "{overseer}");
    assert_eq!(overseer["model"], "gpt-6-astra", "{overseer}");
    assert_eq!(
        overseer["account"],
        account.display().to_string(),
        "{overseer}"
    );
    assert_eq!(overseer["permission"], "bypass", "{overseer}");
    assert_eq!(
        codex_turns(&account),
        vec![text.trim_end().to_owned()],
        "the reconcile typed the file the launch wrote"
    );
    assert_eq!(units_started(&bin), 1, "the controller's one watch");
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    stop_live_watch(&runner, &state);
}

/// The workflow's request against the real effect in one call, the healthy
/// path: the launch's steps with the Claude stub confirm in their own call,
/// and the record carries the launch's directory, model, account and pane;
/// the brief typed into the stub is the file the request named, which the
/// launch left standing; the record names the launch's posture and handoff.
#[test]
fn a_first_launch_confirmed_in_its_call_records_the_launchers_identity() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, mut env) = watch_world(runner.state_dir());
    let work = runner.state_dir().join("work");
    let account = runner.state_dir().join("claude-account");
    std::fs::create_dir(&work).unwrap();
    github_skill_under(&work);
    std::fs::create_dir(&account).unwrap();
    let scripts = launcher_checkout(&runner, &bin, &mut env, &account, "claude");
    let launched = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-confirm"),
    )
    .run();
    let started = launched.started();
    assert_eq!(
        started["outcome"],
        "confirmed",
        "{started}\n{}",
        stderr(launched.op())
    );
    let fleet = runner.fleet();
    let overseer = &fleet["overseer"];
    assert_eq!(overseer["generation"], 1, "{overseer}");
    assert_eq!(overseer["cwd"], work.display().to_string(), "{overseer}");
    assert_eq!(
        overseer["account"],
        account.display().to_string(),
        "{overseer}"
    );
    assert_eq!(overseer["model"], "fable", "{overseer}");
    assert_eq!(overseer["pane"], runner_pane(&server), "{overseer}");
    assert_eq!(
        overseer["handoff"], "tmp/handoffs/OVERSEER-HANDOFF.md",
        "{overseer}"
    );
    assert_eq!(overseer["permission"], "bypass", "{overseer}");
    let intent = &fleet["intents"][0];
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let brief = Path::new(intent["phase"]["brief"].as_str().unwrap());
    let text = std::fs::read_to_string(brief)
        .unwrap_or_else(|e| panic!("the brief left with the launch: {} {e}", brief.display()));
    assert_eq!(
        runner.stub_turns(&account, &work),
        vec![text.trim_end().to_owned()],
        "the start typed the file the launch wrote"
    );
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    stop_live_watch(&runner, &state);
}

/// The real hook installed in the checkout `work` as a kendex install has
/// it: a repository, the hook copied into its hook directory, the orch
/// checkout `scripts` and the mailbox package linked under its install.
/// Returns the hook's path.
fn install_hook(scripts: &Path, work: &Path) -> std::path::PathBuf {
    use std::os::unix::fs::symlink;
    let git = program("git")
        .args(["init", "-q"])
        .arg(work)
        .output()
        .unwrap();
    assert!(git.status.success(), "git init: {}", stderr(&git));
    let skills = shipped_scripts()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_owned();
    let installed = work.join(".agents/skills");
    std::fs::create_dir_all(&installed).unwrap();
    symlink(scripts.parent().unwrap(), installed.join("orch")).unwrap();
    symlink(skills.join("mailbox"), installed.join("mailbox")).unwrap();
    let hook = work.join(".claude/hooks/lane-mail-check.sh");
    std::fs::create_dir_all(hook.parent().unwrap()).unwrap();
    std::fs::copy(
        skills.parent().unwrap().join("hooks/lane-mail-check.sh"),
        &hook,
    )
    .unwrap();
    hook
}

/// The real installed hook's `PostModelSwitch` for the overseer `record`
/// names, run as the harness runs it from `work` under `home` and the
/// fleet's environment `env` ([`install_hook`]'s install, made once per
/// checkout). Returns the hook's output and the check the record carries
/// after it.
fn model_switch(
    runner: &Runner,
    scripts: &Path,
    env: &[(String, String)],
    home: &Path,
    work: &Path,
    record: &Value,
) -> (std::process::Output, Value) {
    let installed = work.join(".claude/hooks/lane-mail-check.sh");
    let hook = if installed.exists() {
        installed
    } else {
        install_hook(scripts, work)
    };
    let session = record["session_id"].as_str().unwrap();
    let payload = json!({
        "session_id": session,
        "hook_event_name": "PostModelSwitch",
        "to_model": "claude-sonnet-5-5",
        "transcript_path": project_dir(home, work).join(format!("{session}.jsonl")),
    });
    let out = run_hook(runner, &hook, env, home, work, record, &payload);
    (out, runner.fleet()["overseer"]["model_check"].clone())
}

/// The installed `hook` run as the harness runs it for the overseer
/// `record` names, from `work` under `home` and `env`, `payload` on its
/// standard input, inside the record's pane on the runner's server.
fn run_hook(
    runner: &Runner,
    hook: &Path,
    env: &[(String, String)],
    home: &Path,
    work: &Path,
    record: &Value,
    payload: &Value,
) -> std::process::Output {
    use std::io::Write;
    let mut child = program("/bin/bash");
    for (name, value) in env {
        child.env(name, value);
    }
    let mut child = child
        .arg(hook)
        .current_dir(work)
        .env("ORCH_STATE_DIR", runner.state_dir())
        .env("CLAUDE_CONFIG_DIR", home)
        .env("TMUX", format!("{},0,0", runner.server_socket.display()))
        .env("TMUX_PANE", record["pane"].as_str().unwrap())
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(payload.to_string().as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

const MODEL_SWITCHED: &str = "lane-mail-check: model-switched=fable observed=claude-sonnet-5-5";

/// The recovery the real hook asked after a model switch, followed to its
/// settled outcome: the transfer of generation `generation` confirmed, the
/// successor published on the model the predecessor was launched with
/// (`launched`), not the one it switched to, on the same account, under the
/// snapshot the handoff verb wrote over the predecessor's: one `Start here`
/// line at that generation, the recovery's own words below it.
fn recovered(runner: &Runner, work: &Path, generation: u64, launched: &str, account: &Value) {
    let intent =
        runner.wait_intent_settled(&format!("request-transfer:overseer:{generation}:"), SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], generation + 1, "{overseer}");
    assert_eq!(
        overseer["model"], launched,
        "the launched model: {overseer}"
    );
    assert_eq!(&overseer["account"], account, "{overseer}");
    let snapshot = std::fs::read_to_string(work.join("tmp/handoffs/OVERSEER-HANDOFF.md")).unwrap();
    let headers: Vec<&str> = snapshot
        .lines()
        .filter(|l| l.starts_with("Start here:"))
        .collect();
    assert_eq!(headers.len(), 1, "{snapshot}");
    assert!(
        headers[0].ends_with(&format!(" generation={generation}")),
        "{snapshot}"
    );
    assert!(
        snapshot.contains(&format!(
            "The predecessor changed from {launched} to claude-sonnet-5-5."
        )),
        "{snapshot}"
    );
}

/// A model switch after a first launch through the fence: the real hook's
/// `PostModelSwitch` acquires the check and recovers the controller through
/// the runtime, the real `successor --recover`, `handoff` and
/// `request-transfer`, onto the model the record says it was launched with.
/// A second switch, on the recovered controller, whose successor exits
/// before it comes up is said by the transfer's own outcome, failed, never
/// by its admission, the controller standing.
#[test]
fn a_model_switch_after_a_first_launch_recovers_the_launched_model_through_the_typed_transfer() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, mut env) = watch_world(runner.state_dir());
    let work = runner.state_dir().join("work");
    let account = runner.state_dir().join("claude-account");
    std::fs::create_dir(&work).unwrap();
    github_skill_under(&work);
    std::fs::create_dir(&account).unwrap();
    let scripts = launcher_checkout(&runner, &bin, &mut env, &account, "claude");
    let launch = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-confirm"),
    );
    let launched = launch.run();
    let started = launched.started();
    assert_eq!(
        started["outcome"],
        "confirmed",
        "{started}\n{}",
        stderr(launched.op())
    );
    let overseer = runner.fleet()["overseer"].clone();
    let (out, check) = model_switch(&runner, &scripts, &launch.env, &account, &work, &overseer);
    assert_eq!(
        check["outcome"],
        "switched",
        "{check}\n{}\n{}",
        String::from_utf8_lossy(&out.stdout),
        stderr(&out)
    );
    assert_eq!(check["launched"], "fable", "{check}");
    assert_eq!(check["observed"], "claude-sonnet-5-5", "{check}");
    assert_eq!(check["recovery_started"], true, "{check}");
    assert_eq!(
        stderr(&out).lines().next().unwrap_or_default(),
        MODEL_SWITCHED,
        "the overseer's notice: {}",
        stderr(&out)
    );
    recovered(&runner, &work, 1, "fable", &overseer["account"]);
    let controller = runner.fleet()["overseer"].clone();
    let mut failing: Vec<(String, String)> = launch
        .env
        .iter()
        .filter(|(name, _)| name != "AGENT_RUNTIME_HARNESS_BINARIES")
        .cloned()
        .collect();
    failing.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!("claude={}", stub("stub-fail").display()),
    ));
    let home = controller["home"]
        .as_str()
        .map_or_else(|| account.clone(), std::path::PathBuf::from);
    let (out, _) = model_switch(&runner, &scripts, &failing, &home, &work, &controller);
    let context: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    assert_eq!(
        context["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .and_then(|text| text.lines().next())
            .unwrap_or_default(),
        "lane-mail-check: model-unavailable=recovery-failed",
        "the transfer's own outcome, handed to the session: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        stderr(&out)
    );
    let intent = runner.wait_intent_settled("request-transfer:overseer:2:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        runner.fleet()["overseer"]["session_id"],
        controller["session_id"],
        "the controller stands"
    );
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    stop_live_watch(&runner, &state);
}

/// A model switch whose transfer job never claims: the real hook's recovery
/// reads the runtime's refusal naming its `persisted_intent` as the
/// outcome unknown, never as nothing done, and hands the session
/// `recovery-unconfirmed`; the intent stands `unconfirmed` for its
/// reconcile and the controller stands.
#[test]
fn a_model_switch_whose_transfer_job_never_claims_is_handed_over_unconfirmed() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, mut env) = watch_world(runner.state_dir());
    let work = runner.state_dir().join("work");
    let account = runner.state_dir().join("claude-account");
    std::fs::create_dir(&work).unwrap();
    github_skill_under(&work);
    std::fs::create_dir(&account).unwrap();
    let scripts = launcher_checkout(&runner, &bin, &mut env, &account, "claude");
    let launch = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-confirm"),
    );
    let launched = launch.run();
    let started = launched.started();
    assert_eq!(
        started["outcome"],
        "confirmed",
        "{started}\n{}",
        stderr(launched.op())
    );
    let overseer = runner.fleet()["overseer"].clone();
    let (sleepers, log) = sleeper_world(runner.state_dir());
    let mut unclaimed: Vec<(String, String)> = launch
        .env
        .iter()
        .filter(|(name, _)| name != "PATH" && name != "AGENT_RUNTIME_JOB_CLAIM_SECS")
        .cloned()
        .collect();
    unclaimed.push((
        "PATH".to_owned(),
        tool_path(&[sleepers.as_path(), bin.as_path()]),
    ));
    unclaimed.push(("AGENT_RUNTIME_JOB_CLAIM_SECS".to_owned(), "1".to_owned()));
    unclaimed.push(("SETSID_LOG".to_owned(), log.display().to_string()));
    let (out, _) = model_switch(&runner, &scripts, &unclaimed, &account, &work, &overseer);
    let intent = runner.fleet()["intents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| {
            i["id"]
                .as_str()
                .is_some_and(|id| id.starts_with("request-transfer:overseer:1:"))
        })
        .cloned()
        .expect("the recovery's transfer intent");
    // The sleeper ends before any assertion, so a red row leaves none.
    let job = remaining(&intent["observation"], "job")["pid"].as_u64();
    if let Some(pid) = job {
        end_sleeper(pid as u32);
    }
    let context: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    assert_eq!(
        context["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .and_then(|text| text.lines().next())
            .unwrap_or_default(),
        "lane-mail-check: model-unavailable=recovery-unconfirmed",
        "the persisted refusal, handed to the session: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        stderr(&out)
    );
    assert_eq!(intent["outcome"], "unconfirmed", "{intent}");
    assert!(
        job.is_some(),
        "the launcher read the sleeper's pid: {intent}"
    );
    assert_eq!(launches(&log), 1, "{intent}");
    assert_eq!(
        runner.fleet()["overseer"]["session_id"],
        overseer["session_id"],
        "the controller stands"
    );
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    stop_live_watch(&runner, &state);
}

/// The real `marks` verb through the real installed hook: at a launched
/// controller's turn end the hook asks the runtime's judge on the reading
/// it took off the session's transcript and acts on the reply's key. A
/// reading past the context cap is refused with the figure the judge read
/// and the succession route named; a reading under the cap whose window
/// the transcript does not name is the judge's `mark-unmeasured
/// kind=context`, reported with the judge's own line and the turn passed.
#[test]
fn the_installed_hook_acts_on_the_real_marks_verbs_reply_at_a_controllers_turn_end() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, mut env) = watch_world(runner.state_dir());
    let work = runner.state_dir().join("work");
    let account = runner.state_dir().join("claude-account");
    std::fs::create_dir(&work).unwrap();
    github_skill_under(&work);
    std::fs::create_dir(&account).unwrap();
    let scripts = launcher_checkout(&runner, &bin, &mut env, &account, "claude");
    let launch = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-confirm"),
    );
    let launched = launch.run();
    let started = launched.started();
    assert_eq!(
        started["outcome"],
        "confirmed",
        "{started}\n{}",
        stderr(launched.op())
    );
    let overseer = runner.fleet()["overseer"].clone();
    let session = overseer["session_id"].as_str().unwrap().to_owned();
    let transcript = project_dir(&account, &work).join(format!("{session}.jsonl"));
    std::fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    let hook = install_hook(&scripts, &work);
    let mut hook_env = launch.env.clone();
    hook_env.push(("ORCH_OVERSEER_WALL_MINUTES".to_owned(), "0".to_owned()));
    // The controller's wake, armed as the turn-end check asks: a follower
    // of the live watch's log in a waiter under the claim's checkout, in a
    // process group of its own the row ends.
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let claim =
        orch_runtime::watch::claim::read(&orch_runtime::watch::claim::Paths::of(&state).unwrap())
            .unwrap()
            .expect("the launch claimed the fleet state");
    let waiter = Path::new(&claim.cwd).join("tmp/waiter.fixture");
    std::fs::create_dir_all(&waiter).unwrap();
    struct Group(std::process::Child);
    impl Drop for Group {
        fn drop(&mut self) {
            let _ = program("kill")
                .args(["-KILL", "--", &format!("-{}", self.0.id())])
                .status();
            let _ = self.0.wait();
        }
    }
    let _wake = {
        use std::os::unix::process::CommandExt;
        Group(
            program("sh")
                .args(["-c", "sleep 600; :", "follow.sh"])
                .arg(waiter.join("watch.log"))
                .process_group(0)
                .spawn()
                .unwrap(),
        )
    };
    let stop = |tokens: u64| {
        let line = json!({"type": "assistant", "message": {"model": "claude-opus-5-5", "usage": {
            "input_tokens": 1, "cache_read_input_tokens": tokens - 8,
            "cache_creation_input_tokens": 0, "output_tokens": 7}}});
        std::fs::write(&transcript, format!("{line}\n")).unwrap();
        let payload = json!({
            "session_id": session,
            "hook_event_name": "Stop",
            "stop_hook_active": false,
            "transcript_path": transcript,
        });
        run_hook(
            &runner, &hook, &hook_env, &account, &work, &overseer, &payload,
        )
    };
    let due = stop(612_000);
    assert_eq!(
        (
            due.status.code(),
            stderr(&due).lines().next().unwrap_or_default().to_owned()
        ),
        (Some(2), "lane-mail-check: context=612000".to_owned()),
        "{}",
        stderr(&due)
    );
    assert!(
        stderr(&due).contains("orch-runtime successor --fleet"),
        "the refusal names the runtime's succession: {}",
        stderr(&due)
    );
    let unnamed = stop(1_000);
    let said = stderr(&unnamed);
    assert_eq!(
        (
            unnamed.status.code(),
            said.lines().next().unwrap_or_default()
        ),
        (Some(0), "lane-mail-check: marks=unmeasured"),
        "{said}"
    );
    let judged: Value = serde_json::from_str(
        said.lines()
            .find(|l| l.starts_with('{'))
            .unwrap_or_else(|| panic!("the judge's own line: {said}")),
    )
    .unwrap();
    assert_eq!(
        (&judged["key"], &judged["kind"], &judged["reason"]),
        (
            &json!("mark-unmeasured"),
            &json!("context"),
            &json!("window-unnamed")
        ),
        "{said}"
    );
    stop_live_watch(&runner, &state);
}

// ---------------------------------------------------------------------------
// The controller's resume, an adopted controller's own succession owner and
// the record heal.
// ---------------------------------------------------------------------------

/// The Claude session file `id` names under `home` for `cwd`, laid out as
/// the harness lays it out, holding its permission row.
fn plant_claude_session(home: &Path, cwd: &Path, id: &str) -> std::path::PathBuf {
    let dir = project_dir(home, cwd);
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join(format!("{id}.jsonl"));
    std::fs::write(
        &file,
        format!(
            "{{\"type\":\"permission-mode\",\"permissionMode\":\"bypassPermissions\",\"sessionId\":\"{id}\"}}\n"
        ),
    )
    .unwrap();
    file
}

/// A `start-controller` request continuing the native session `id` in
/// `harness` under `home`, from `cwd`.
fn resume_request(cwd: &Path, harness: &str, home: &Path, id: &str) -> Value {
    let mut controller = pending(cwd);
    controller["harness"] = json!(harness);
    controller["home"] = json!(home.display().to_string());
    controller["account"] = json!(home.display().to_string());
    controller["resume"] = json!(id);
    json!({"op": "start-controller", "controller": controller})
}

/// The start continues the recorded native session in each harness's own
/// resume form: the Claude stub refuses a resume of a file the home lacks,
/// so a confirmed start, the bound id and the brief typed into that id's
/// own file prove the line; Codex and Copilot draw no composer, so their
/// words are read off the launch record; an id the home never held fails
/// before anything opens.
#[test]
fn a_controller_resume_continues_the_recorded_session_in_each_harness_s_own_form() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-resume");
    runner.init_fleet();
    let home = runner.state_dir().to_path_buf();
    let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
    let file = plant_claude_session(&home, &home, id);
    let brief = home.join("brief.md");
    std::fs::write(&brief, "RESUME HERE\n").unwrap();
    let mut request = resume_request(&home, "claude", &home, id);
    request["brief_file"] = json!(brief.display().to_string());
    let report = effect_report(&runner.op_fleet(&request));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["session_id"], id, "{overseer}");
    assert_eq!(overseer["generation"], 1, "{overseer}");
    assert_eq!(
        file_turns(&file),
        vec!["RESUME HERE".to_owned()],
        "the brief went into the resumed session's own file"
    );
    assert!(
        overseer.get("resume").is_none(),
        "a launch field, not a record field: {overseer}"
    );

    // An id the home never held: nothing opens, the record names nothing.
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-resume");
    runner.init_fleet();
    let home = runner.state_dir().to_path_buf();
    let report =
        effect_report(&runner.op_fleet(&resume_request(&home, "claude", &home, "never-held")));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"], "session-missing",
        "{report}"
    );
    assert_eq!(server.panes().len(), 1, "nothing opened");

    // Codex and Copilot: the harness's own resume word on the line, no
    // fresh id fixed, read off the record the stub writes.
    for harness in ["codex", "copilot"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-resume");
        runner.verify = Some(1);
        runner.init_fleet();
        let cwd = runner.state_dir().to_path_buf();
        let home = dir.path().join(format!("{harness}-home"));
        if harness == "codex" {
            let day = home.join("sessions/2026/01/01");
            std::fs::create_dir_all(&day).unwrap();
            std::fs::write(
                day.join(format!("rollout-2026-01-01T00-00-00-{id}.jsonl")),
                format!(
                    "{{\"type\":\"session_meta\",\"payload\":{{\"id\":\"{id}\",\"cwd\":\"{}\",\"parent_thread_id\":null,\"source\":\"cli\"}}}}\n",
                    cwd.display()
                ),
            )
            .unwrap();
            plant_codex_credential(&home);
        } else {
            let session = home.join("session-state").join(id);
            std::fs::create_dir_all(&session).unwrap();
            std::fs::write(session.join("workspace.yaml"), "cwd: /r\n").unwrap();
            copilot_gate_passed(&mut runner, &home);
        }
        let binaries = format!(
            "claude={},{harness}={}",
            stub("stub-resume").display(),
            fixtures().join("stub-record").join(harness).display()
        );
        let report = effect_report(&runner.op_fleet_env(
            &resume_request(&cwd, harness, &home, id),
            &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)],
        ));
        assert_eq!(report["intent"]["outcome"], "failed", "{harness}: {report}");
        assert_eq!(
            report["intent"]["observation"]["note"], "successor-not-ready",
            "{harness}: {report}"
        );
        let argv = argv_of(&launch_record(&cwd));
        let resumed = match harness {
            "codex" => argv.windows(2).any(|w| w[0] == "resume" && w[1] == id),
            _ => argv.iter().any(|a| *a == format!("--resume={id}")),
        };
        assert!(resumed, "{harness}: {argv:?}");
        assert!(
            !argv.iter().any(|a| a == "--session-id"),
            "{harness}: no fresh id beside a resume: {argv:?}"
        );
    }
}

/// An overseer's start through orch hands its session what a lane's launch
/// does. On a fleet server whose environment carries an opener's own
/// declaration, model-line hold and Codex compaction reading, a Copilot CLI
/// controller declares the model its pending pins, a Codex controller
/// declares nothing and sees its own line's compaction reading, and the
/// opener's hold reaches neither. Both stubs draw no composer, so each start
/// is abandoned once the stub has written what it was opened with.
#[test]
fn an_overseer_s_start_declares_its_pinned_model_to_the_review_as_a_lane_does() {
    for (harness, model, declared) in [
        ("copilot", "claude-opus-5", Some("claude-opus-5")),
        ("codex", "gpt-5.5", None),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        for (name, value) in [
            ("SECOND_OPINION_CURRENT_MODEL", "the opener's model"),
            ("ORCH_MODEL_LINES_HELD", "1"),
            ("ORCH_COMPACTION_OVERRIDES", "the opener's reading"),
        ] {
            let out = tmux(&server.socket, &["set-environment", "-g", name, value]);
            assert!(
                out.status.success(),
                "{harness}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
        let mut runner = suite_runner(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let cwd = runner.state_dir().to_path_buf();
        let home = dir.path().join(format!("{harness}-home"));
        std::fs::create_dir_all(&home).unwrap();
        if harness == "codex" {
            plant_codex_credential(&home);
        } else {
            copilot_gate_passed(&mut runner, &home);
        }
        let mut controller = pending(&cwd);
        controller["harness"] = json!(harness);
        controller["home"] = json!(home.display().to_string());
        controller["account"] = json!(home.display().to_string());
        controller["model"] = json!(model);
        let binaries = format!(
            "claude={},{harness}={}",
            stub("stub-record").display(),
            fixtures().join("stub-record").join(harness).display()
        );
        let report = effect_report(&runner.op_fleet_env(
            &json!({"op": "start-controller", "controller": controller}),
            &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)],
        ));
        assert_eq!(
            report["intent"]["observation"]["note"], "successor-not-ready",
            "{harness}: {report}"
        );
        let opened = &launch_record(&cwd)["opened"];
        assert_eq!(
            opened["SECOND_OPINION_CURRENT_MODEL"],
            declared.map_or(Value::Null, |m| json!(m)),
            "{harness}: the model the controller declares: {opened}"
        );
        assert_eq!(
            opened["ORCH_MODEL_LINES_HELD"],
            Value::Null,
            "{harness}: the opener's hold: {opened}"
        );
        if harness == "codex" {
            let reading = opened["ORCH_COMPACTION_OVERRIDES"].as_str().unwrap_or("");
            let reading: Value = serde_json::from_str(reading)
                .unwrap_or_else(|e| panic!("the line's own reading {reading:?}: {e}"));
            assert_eq!(reading["harness"], "codex", "{opened}");
        }
    }
}

/// An accountless start resuming the session its pending names under a home
/// resumes it there, the home named as the pending names it (the resume
/// stub refuses a file its config dir lacks, so a confirmed start is the
/// proof); a fresh accountless Claude or Codex start runs on, and records,
/// the home the fleet server hands its panes, a Claude config dir named as
/// found even where it spells `$HOME/.claude`, and the implicit default,
/// the variable cleared, only where the server names none.
#[test]
fn a_controller_with_no_account_runs_under_the_one_home_its_session_is_proved_and_recorded_under() {
    // The case, the harness, the home the pending names its session under
    // (`dir` a home of its own, `default` `$HOME/.claude`, `none` no resume),
    // what the server names (`current`, `home-claude` `$HOME/.claude`
    // spelled out, `nothing`), and the stub.
    let cases = [
        (
            "claude: resumes under its recorded config dir",
            "claude",
            "dir",
            "current",
            "stub-resume",
        ),
        (
            "claude: resumes under the default the pending names",
            "claude",
            "default",
            "current",
            "stub-record",
        ),
        (
            "claude: a fresh start under the server's config dir",
            "claude",
            "none",
            "current",
            "stub-record",
        ),
        (
            "claude: a fresh start, the server naming $HOME/.claude",
            "claude",
            "none",
            "home-claude",
            "stub-record",
        ),
        (
            "claude: a fresh start, the server naming nothing",
            "claude",
            "none",
            "nothing",
            "stub-record",
        ),
        (
            "codex: a fresh start",
            "codex",
            "none",
            "current",
            "stub-record",
        ),
    ];
    let id = "0f6e2c1a-7d1b-4a0e-9f3c-2b5d8e1f4a6c";
    for (case, harness, recorded, served, stub_name) in cases {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, stub_name);
        runner.verify = Some(1);
        runner.init_fleet();
        let home = dir.path().join("home");
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        runner
            .env
            .push(("HOME".to_owned(), home.display().to_string()));
        let cwd = runner.state_dir().to_path_buf();
        let (variable, store) = match harness {
            "codex" => ("CODEX_HOME", "sessions"),
            _ => ("CLAUDE_CONFIG_DIR", "projects"),
        };
        let served = match served {
            "nothing" => None,
            "home-claude" => Some(home.join(".claude")),
            other => Some(dir.path().join(other)),
        };
        if let Some(served) = &served {
            std::fs::create_dir_all(served).unwrap();
            let out = tmux(
                &server.socket,
                &[
                    "set-environment",
                    "-g",
                    variable,
                    &served.display().to_string(),
                ],
            );
            assert!(out.status.success(), "{case}: {}", stderr(&out));
        }
        let recorded = match recorded {
            "dir" => Some(dir.path().join("dir")),
            "default" => Some(home.join(".claude")),
            _ => None,
        };
        // The home the harness should run on, and whether it is named.
        let (expected, named) = match (&recorded, &served) {
            (Some(recorded), _) => (recorded.clone(), true),
            (None, Some(served)) => (served.clone(), true),
            (None, None) => (home.join(".claude"), false),
        };
        let mut controller = pending(&cwd);
        controller["harness"] = json!(harness);
        controller.as_object_mut().unwrap().remove("account");
        controller.as_object_mut().unwrap().remove("home");
        if harness == "codex" {
            controller["model"] = json!("gpt-6.1");
        }
        if let Some(recorded) = &recorded {
            plant_claude_session(recorded, &cwd, id);
            controller["home"] = json!(recorded.display().to_string());
            controller["resume"] = json!(id);
        }
        let mut request = json!({"op": "start-controller", "controller": controller});
        let brief = cwd.join("brief.md");
        std::fs::write(&brief, "RESUME HERE\n").unwrap();
        request["brief_file"] = json!(brief.display().to_string());
        let binaries = format!(
            "{harness}={}",
            fixtures().join(stub_name).join(harness).display()
        );
        let report = effect_report(
            &runner.op_fleet_env(&request, &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)]),
        );
        // A home is its session store: a private Codex launch home links the
        // account's.
        let store_of = |path: &Path| {
            std::fs::canonicalize(path.join(store))
                .or_else(|_| std::fs::canonicalize(path))
                .ok()
        };
        if stub_name == "stub-resume" {
            assert_eq!(report["intent"]["outcome"], "confirmed", "{case}: {report}");
            assert_eq!(runner.fleet()["overseer"]["session_id"], id, "{case}");
        } else {
            // The harness wrote its record: the session was proved and the
            // window opened.
            let launched = launch_record(&cwd);
            let child = launched["env"][variable].as_str().unwrap_or("");
            if harness == "claude" {
                let spelled = if named {
                    expected.display().to_string()
                } else {
                    String::new()
                };
                assert_eq!(
                    child, spelled,
                    "{case}: the config dir named as it was found, or none: {launched}"
                );
            } else {
                assert_eq!(
                    store_of(Path::new(child)),
                    store_of(&expected),
                    "{case}: the harness runs on the home its session is proved under: {launched}"
                );
            }
        }
        let phase = &report["intent"]["phase"];
        assert_eq!(
            phase["home"]
                .as_str()
                .and_then(|recorded| store_of(Path::new(recorded))),
            store_of(&expected),
            "{case}: the start records the home the harness runs on: {report}"
        );
        assert_eq!(
            phase["home_implicit"].as_bool().unwrap_or(false),
            !named,
            "{case}: the start records whether it named its home: {report}"
        );
    }
}

/// A Pi successor's fallback root is the lane launch's one rule, so a root
/// that does not stand refuses `home-missing` as a lane launch on the same
/// host does, never at the harness gate as a settings choice under it.
#[test]
fn an_accountless_pi_successor_with_no_root_kept_refuses_home_missing_before_any_window() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-record");
    runner.verify = Some(1);
    runner.init_fleet();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    let cwd = runner.state_dir().to_path_buf();
    let mut controller = pending(&cwd);
    controller["harness"] = json!("pi");
    controller["model"] = json!("openrouter/anthropic/claude-fable-5-1");
    controller.as_object_mut().unwrap().remove("account");
    controller.as_object_mut().unwrap().remove("home");
    let mut request = json!({"op": "start-controller", "controller": controller});
    let brief = cwd.join("brief.md");
    std::fs::write(&brief, "RESUME HERE\n").unwrap();
    request["brief_file"] = json!(brief.display().to_string());
    let binaries = format!("pi={}", fixtures().join("stub-record/pi").display());
    let panes = server.panes().len();
    let report = effect_report(
        &runner.op_fleet_env(&request, &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)]),
    );
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"], "home-missing",
        "the successor's fallback root is checked as the lane launch's is: {report}"
    );
    assert_eq!(server.panes().len(), panes, "no window opened: {report}");
    assert!(
        !home.join(".pi/agent").exists(),
        "the root was never made: {report}"
    );
}

/// Pi continues a session by its file: a start whose pending names that
/// file launches `--session <file>` with no fresh id; one whose session has
/// no file under the home fails `session-missing`, one naming no file
/// `resume-file-missing`, and one naming another file `session-missing`,
/// each before anything opens.
#[test]
fn a_pi_controller_resume_continues_by_the_session_file_its_pending_names() {
    let id = "abc";
    for case in ["no-file", "unnamed", "other", "named"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-record");
        runner.verify = Some(1);
        runner.init_fleet();
        let cwd = runner.state_dir().to_path_buf();
        let home = dir.path().join("pi-home");
        std::fs::create_dir_all(&home).unwrap();
        pi_root_marked(&home);
        let sessions = home
            .join("sessions")
            .join(agent_runtime::session::pi_slug(&cwd));
        let file = sessions.join(format!("2026-11-12T00-00-00-000Z_{id}.jsonl"));
        if case != "no-file" {
            std::fs::create_dir_all(&sessions).unwrap();
            std::fs::write(&file, "{}\n").unwrap();
        }
        let mut request = resume_request(&cwd, "pi", &home, id);
        request["controller"]["model"] = json!("pi-claude/claude-fable-5-1");
        match case {
            "named" | "no-file" => {
                request["controller"]["resume_file"] = json!(file.display().to_string());
            }
            "other" => {
                request["controller"]["resume_file"] =
                    json!(home.join("other.jsonl").display().to_string());
            }
            _ => {}
        }
        let brief = cwd.join("brief.md");
        std::fs::write(&brief, "RESUME HERE\n").unwrap();
        request["brief_file"] = json!(brief.display().to_string());
        let binaries = format!("pi={}", fixtures().join("stub-record/pi").display());
        let report = effect_report(
            &runner.op_fleet_env(&request, &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)]),
        );
        assert_eq!(report["intent"]["outcome"], "failed", "{case}: {report}");
        let owed = match case {
            "no-file" | "other" => "session-missing",
            "unnamed" => "resume-file-missing",
            _ => "successor-not-ready",
        };
        assert_eq!(
            report["intent"]["observation"]["note"], owed,
            "{case}: {report}"
        );
        if case != "named" {
            assert_eq!(server.panes().len(), 1, "{case}: nothing opened");
            continue;
        }
        let argv = argv_of(&launch_record(&cwd));
        assert!(
            argv.windows(2)
                .any(|w| w[0] == "--session" && w[1] == file.display().to_string()),
            "{argv:?}"
        );
        assert!(
            !argv.iter().any(|a| a == "--session-id"),
            "no fresh id beside a resume: {argv:?}"
        );
    }
}

/// After a restart the record names a controller whose server is gone and
/// whose session recorded its end; a
/// start of its own launch resuming its recorded session (the shape
/// `agent-runtime controller successor --resume` answers) opens in the
/// standing session the setting names and continues that session, and
/// where that session does not stand fails `tmux-session-missing` with
/// nothing opened and the record as it stood.
#[test]
fn a_resume_after_a_restart_opens_in_the_standing_session_or_none() {
    let id = "5b2d9c3e-1f4a-4e6b-8c7d-0a9b8c7d6e5f";
    for session in ["fleet", "nosuch"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let runner = suite_runner(&server, "stub-resume");
        runner.init_fleet();
        let home = runner.state_dir().to_path_buf();
        let file = plant_claude_session(&home, &home, id);
        let mut fleet = runner.fleet();
        let mut gone = pending(&home);
        gone["server"] = json!("1");
        gone["server_start"] = json!(1);
        gone["pane"] = json!("%99");
        gone["generation"] = json!(4);
        gone["session_id"] = json!(id);
        // The session recorded its end before the server went: a replaced
        // server alone proves nothing (`predecessor-unproven`).
        gone["exit"] = json!({"run": {"generation": 4}});
        fleet["overseer"] = gone;
        runner.write_fleet(&fleet);
        let before = runner.fleet()["overseer"].clone();
        let mut request = resume_request(&home, "claude", &home, id);
        let brief = home.join("brief.md");
        std::fs::write(&brief, "RESUME HERE\n").unwrap();
        request["brief_file"] = json!(brief.display().to_string());
        let report = effect_report(
            &runner.op_fleet_env(&request, &[("AGENT_RUNTIME_TMUX_SESSION", session)]),
        );
        if session == "nosuch" {
            assert_eq!(report["intent"]["outcome"], "failed", "{report}");
            assert_eq!(
                report["intent"]["observation"]["note"], "tmux-session-missing",
                "{report}"
            );
            assert_eq!(server.panes().len(), 1, "nothing opened");
            assert_eq!(runner.fleet()["overseer"], before, "the record as it stood");
            continue;
        }
        assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
        let overseer = runner.fleet()["overseer"].clone();
        assert_eq!(overseer["session_id"], id, "{overseer}");
        assert_ne!(overseer["pane"], "%99", "{overseer}");
        assert_eq!(
            file_turns(&file),
            vec!["RESUME HERE".to_owned()],
            "the brief went into the resumed session's own file"
        );
    }
}

/// The compare-and-swap set of `record`, with no pending standing.
fn expected_of(record: &Value) -> Value {
    json!({
        "server": record["server"],
        "server_start": record["server_start"],
        "pane": record["pane"],
        "generation": record["generation"],
        "launch_line": record["launch_line"],
        "cwd": record["cwd"],
        "pending": Value::Null,
    })
}

#[test]
fn the_reconcile_heals_an_unbound_controllers_identity_and_never_binds_a_previous_sessions_file() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let home = runner.state_dir().to_path_buf();
    let previous = project_dir(&home, &home).join("previous-session.jsonl");
    std::fs::create_dir_all(previous.parent().unwrap()).unwrap();
    std::fs::write(
        &previous,
        json!({
            "type": "user", "sessionId": "previous-session", "cwd": home,
            "message": {"role": "user", "content": "previous work"}
        })
        .to_string(),
    )
    .unwrap();
    let pane = server.open_stub("overseer", "stub-confirm", &home, &home);
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    let mut fleet = runner.fleet();
    fleet["overseer"] = json!({
        "runtime": "tmux",
        "generation": 2,
        "server": server.pid.to_string(),
        "server_socket": server.socket.display().to_string(),
        "pane": pane,
        "window": "@9",
        "harness": "claude",
        "account": home.display().to_string(),
        "home": home.display().to_string(),
        "model": "opus",
        "cwd": home.display().to_string(),
        "session_id": "",
    });
    runner.write_fleet(&fleet);
    let out = runner.run(&["reconcile", "--fleet"]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert_eq!(answer["result"]["controller"]["healed"], true, "{answer}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["session_id"], "", "{overseer}");
    assert_eq!(overseer["harness_pid"], pid, "{overseer}");
    assert_eq!(overseer["harness_start"], start_of(pid), "{overseer}");
    assert_eq!(overseer["server_start"], server.start, "{overseer}");
    assert_eq!(overseer["generation"], 2, "{overseer}");
    assert_eq!(overseer["model"], "opus", "{overseer}");
    server.send_line(&pane, "first turn");
    wait_until("the stub recorded its first turn", secs(10), || {
        runner
            .stub_turns(&home, &home)
            .contains(&"first turn".to_owned())
    });
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let bytes = std::fs::read(&state).unwrap();
    let out = runner.run(&["reconcile", "--fleet"]);
    let answer = reply(&out);
    assert_eq!(answer["ok"], true, "{}", stderr(&out));
    assert!(answer["result"].get("controller").is_none(), "{answer}");
    assert_eq!(std::fs::read(&state).unwrap(), bytes);
    // The session's own id, as the turn-end binding reads it from the
    // session itself, binds where the record holds none.
    let answer = reply(&runner.op_fleet(&json!({
        "op": "adopt-controller",
        "pane": pane,
        "harness": "claude",
        "session_id": format!("stub-{pid}"),
        "account": home.display().to_string(),
        "cwd": home.display().to_string(),
    })));
    assert_eq!(answer["result"]["report"]["healed"], true, "{answer}");
    assert_eq!(
        runner.fleet()["overseer"]["session_id"],
        format!("stub-{pid}")
    );
}

// ---------------------------------------------------------------------------
// The controller's own marks: the judge's answers through `marks --fleet`,
// the memory mark on fixture cgroup files, and the transfer onto the mark
// reply's successor.
// ---------------------------------------------------------------------------

/// A world the marks are judged over: planted accounts under its home, the
/// fleet state in its root, the judge's fixtures on its `bin`.
struct MarksWorld {
    dir: tempfile::TempDir,
    env: Vec<(String, String)>,
}

impl MarksWorld {
    fn new() -> MarksWorld {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("bin")).unwrap();
        std::fs::create_dir_all(dir.path().join("home")).unwrap();
        for (name, fixture) in [
            ("lane-host", "lane-host/lane-host"),
            ("bin/curl", "usage-curl/curl"),
            ("bin/kendex", "kendex-launch/kendex"),
        ] {
            let base = if fixture.starts_with("lane-host") {
                fixtures()
            } else {
                account_fixtures()
            };
            std::os::unix::fs::symlink(base.join(fixture), dir.path().join(name)).unwrap();
        }
        install_lane_host(dir.path(), dir.path());
        let root = dir.path().display().to_string();
        let env = vec![
            (
                "HOME".to_owned(),
                dir.path().join("home").display().to_string(),
            ),
            ("OVERSEE_WATCH_STATE_DIR".to_owned(), root.clone()),
            ("AGENT_RUNTIME_ACCOUNT_STATE_DIR".to_owned(), root.clone()),
            ("ORCH_STATE_DIR".to_owned(), root.clone()),
            (
                "USAGE_FIXTURE_DIR".to_owned(),
                dir.path().join("fixtures").display().to_string(),
            ),
            (
                "AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR".to_owned(),
                "0".to_owned(),
            ),
            // The world's own mailbox and a tmux socket no server holds, so
            // a notice or a server read stays inside it.
            (
                "LANE_MAIL_CLI".to_owned(),
                fixtures()
                    .join("lane-mail-quiet/lane-mail")
                    .display()
                    .to_string(),
            ),
            (
                "TMUX".to_owned(),
                format!("{},0,0", dir.path().join("tmux.sock").display()),
            ),
        ];
        MarksWorld { dir, env }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn dir(&self, alias: &str) -> String {
        self.path()
            .join("home")
            .join(format!(".{alias}"))
            .display()
            .to_string()
    }

    fn plant(&mut self, host: Option<&str>, rows: &[Value]) {
        let env = plant_accounts(self.path(), self.path(), host, rows, now_secs());
        for (key, value) in env {
            self.env.retain(|(k, _)| *k != key);
            self.env.push((key, value));
        }
    }

    /// The fleet state whose controller record names `account` on the
    /// Claude harness in this world's root.
    fn write_fleet(&self, account: &str) {
        self.write_fleet_on(json!("claude"), account);
    }

    /// [`MarksWorld::write_fleet`] on `harness`, `null` for a record naming
    /// none.
    fn write_fleet_on(&self, harness: Value, account: &str) {
        let fleet = json!({
            "issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": [], "fleet_log": [],
            "overseer": {
                "generation": 3, "harness": harness, "account": account, "home": account,
                "model": "opus", "effort": "high", "cwd": self.path().display().to_string(),
                "server": "1", "pane": "%1", "permission": "bypass",
            },
        });
        std::fs::write(
            self.path().join(agent_runtime::record::FLEET_FILE_NAME),
            serde_json::to_string(&fleet).unwrap(),
        )
        .unwrap();
    }

    fn environment(&self) -> Vec<(std::ffi::OsString, std::ffi::OsString)> {
        self.env.iter().map(|(k, v)| (k.into(), v.into())).collect()
    }

    /// The binary in this world, with `extra` settings over its own.
    fn run(&self, args: &[&str], extra: &[(&str, &str)]) -> std::process::Output {
        let mut command = isolated();
        command
            .current_dir(self.path())
            .env("PATH", tool_path(&[&self.path().join("bin")]))
            .args(args);
        for (key, value) in &self.env {
            command.env(key, value);
        }
        for (key, value) in extra {
            command.env(key, value);
        }
        command.output().unwrap()
    }

    /// `marks --fleet` with `args` under `extra`: the reply's result.
    fn marks(&self, args: &[&str], extra: &[(&str, &str)]) -> Value {
        let out = self.run(&[&["marks", "--fleet"][..], args].concat(), extra);
        let answer = reply(&out);
        assert_eq!(answer["ok"], json!(true), "{}", stderr(&out));
        answer["result"].clone()
    }

    /// The question a Claude lane's turn end asks the account judge about
    /// its own home `dir` under `extra`, as the hook asks it: `lane
    /// pick --fleet --lane DIR --harness claude --min-headroom-pct 3`. The
    /// whole reply.
    fn pick_lane(&self, dir: &str, extra: &[(&str, &str)]) -> Value {
        let out = self.run(
            &[
                "lane",
                "pick",
                "--fleet",
                "--lane",
                dir,
                "--harness",
                "claude",
                "--min-headroom-pct",
                "3",
            ],
            extra,
        );
        let answer = reply(&out);
        assert_eq!(answer["ok"], json!(true), "{}", stderr(&out));
        answer
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// A measured Claude account at `alias`, `used` percent on its weekly
/// window, rated slowly so the rate mark reads measured and far off.
fn measured_account(alias: &str, used: u64) -> Value {
    let weekly = agent_runtime::clock::iso_utc(now_secs() + 60 * 3600);
    json!({
        "alias": alias,
        "harness": "claude",
        "config_dir": format!("/home/me/.{alias}"),
        "measured_through": "local",
        "status": "ok",
        "verdict": if used < 95 { "room" } else { "walled" },
        "headroom_pct": 100 - used,
        "binding_bucket": "weekly",
        "binding_resets_at": weekly,
        "wall": used,
        "session_5h_pct": 5,
        "weekly_pct": used,
        "monthly_pct": null,
        "model_buckets": [],
        "resets": {"session": agent_runtime::clock::iso_utc(now_secs() + 3600), "weekly": weekly, "model": null, "monthly": null},
        "usage_rate_state": "measured",
        "usage_rate_pct_per_min": 0.005,
        "usage_age_s": 0,
        "claims": 0,
        "pool": "plan"
    })
}

/// The overseer's own-account mark under a provider whose `accounts` read
/// fails or answers busy reads the account unreadable, never judged on this
/// machine's reading of it alone; the same world answered reads its room.
#[test]
fn an_overseers_own_account_under_a_failed_or_busy_accounts_read_is_unreadable() {
    let unreadable = (
        Value::Null,
        json!("mark-unmeasured"),
        json!("headroom-unreadable"),
    );
    let cases = [
        (None, (json!("90"), json!("below-mark"), Value::Null)),
        (Some(1), unreadable.clone()),
        (Some(69), unreadable),
    ];
    for (exit, (headroom, key, reason)) in cases {
        let mut world = MarksWorld::new();
        world.plant(Some("vm"), &[measured_account("eclaude", 10)]);
        world.write_fleet(&world.dir("eclaude"));
        if let Some(exit) = exit {
            let answers = world.path().join("lane-host.json");
            let mut map: Value = serde_json::from_slice(&std::fs::read(&answers).unwrap()).unwrap();
            map["vm accounts"] = json!({"exit": exit, "stderr": "lane-host-fixture: refused\n"});
            std::fs::write(&answers, map.to_string()).unwrap();
        }
        let marks = world.marks(&["--context", "100000:1000000"], &[]);
        assert_eq!(
            (&marks["headroom"], &marks["key"], &marks["reason"]),
            (&headroom, &key, &reason),
            "{exit:?}: {marks}"
        );
    }
}

/// A reading past the token cap is `mark-reached kind=context` before any
/// account is read, with the decision the handoff record carries; a reading
/// below both marks with the account above the trigger is `below-mark`
/// carrying the headroom read; a reading with no window is `mark-unmeasured
/// kind=context`.
#[test]
fn the_marks_judge_reads_the_context_mark_before_the_account_and_the_rest_below_both() {
    let mut world = MarksWorld::new();
    world.write_fleet("/home/nobody/.claude");
    let reached = world.marks(&["--context", "520000:1000000"], &[]);
    assert_eq!(reached["key"], json!("mark-reached"), "{reached}");
    assert_eq!(reached["kind"], json!("context"));
    assert_eq!(reached["value"], json!("520000"));
    assert_eq!(reached["mark"], json!("90"));
    assert_eq!(reached["headroom"], json!("unreadable"));
    assert_eq!(reached["succession"], json!("on"));
    assert_eq!(
        reached["context_decision"],
        json!({"tokens": 520000, "window": 1000000, "cap": 400000, "mark_pct": 90,
               "cap_mark": 400000, "window_mark": 900000, "reserve_applied": false, "reserve_tokens": 0})
    );
    world.plant(None, &[measured_account("eclaude", 10)]);
    world.write_fleet(&world.dir("eclaude"));
    let below = world.marks(&["--context", "100000:1000000"], &[]);
    assert_eq!(below["key"], json!("below-mark"), "{below}");
    assert_eq!(below["context"], json!("room"));
    assert_eq!(below["tokens"], json!(100000));
    assert_eq!(below["window"], json!(1000000));
    assert_eq!(below["mark"], json!("90"));
    assert_eq!(below["headroom"], json!("90"));
    let unnamed = world.marks(&["--context", "100000:"], &[]);
    assert_eq!(unnamed["key"], json!("mark-unmeasured"), "{unnamed}");
    assert_eq!(unnamed["kind"], json!("context"));
    assert_eq!(unnamed["reason"], json!("window-unnamed"));
    let alone = world.marks(&[], &[]);
    assert_eq!(alone["key"], json!("below-mark"), "{alone}");
    assert_eq!(alone["context"], json!("unjudged"));
    assert_eq!(alone["headroom"], json!("90"));
}

/// The shipped mailbox reader, run under an environment of its own rooted
/// at `root`, a git checkout of its own whose parent is the ceiling, so the
/// asks a row plants are the reader's own writes.
fn real_mail(root: &Path) -> std::path::PathBuf {
    let path = root.join("real-lane-mail");
    let actual = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap();
    write_executable(
        &path,
        format!(
            "#!/bin/sh\nexec env -i HOME='{}' PATH='{}' LANG=C.UTF-8 TMPDIR='{}' GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES='{}' '{}' \"$@\"\n",
            root.join("home").display(),
            tool_path(&[]),
            std::env::temp_dir().display(),
            ceilings(root.parent().unwrap()).to_string_lossy(),
            actual.display()
        ),
    );
    for args in [
        vec!["init", "--quiet"],
        vec!["config", "gc.auto", "0"],
        vec!["config", "maintenance.auto", "false"],
    ] {
        let out = program("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
    path
}

/// The value a refusal names for `field`; the reply carries its fields as
/// name and value pairs.
fn refused_field(answer: &Value, field: &str) -> String {
    answer["refusal"]["fields"]
        .as_array()
        .and_then(|pairs| pairs.iter().find(|p| p[0] == json!(field)))
        .and_then(|p| p[1].as_str())
        .unwrap_or("absent")
        .to_owned()
}

/// The snapshot carries the fleet record's generation in its `Start here`
/// header and, in its State section, every open ask a running lane's own
/// mailbox holds, read through the shipped reader: a parked lane's mailbox
/// is not read, and a body's own spelling of the line is replaced. The
/// takeover's read of the same asks answers them. Every body the writer
/// refuses leaves the installed snapshot as it stood.
#[test]
fn the_handoff_snapshot_carries_the_generation_and_every_open_lane_ask_from_the_mailboxes() {
    let world = MarksWorld::new();
    let root = world.path().display().to_string();
    let mail = real_mail(world.path());
    let fleet = json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [
            {"item": "KEN-6", "status": "running", "mail_root": root},
            {"item": "KEN-8", "status": "parked", "mail_root": root},
        ],
        "overseer": {"generation": 7, "harness": "claude", "server": "1", "pane": "%1"},
    });
    std::fs::write(
        world.path().join(agent_runtime::record::FLEET_FILE_NAME),
        serde_json::to_string(&fleet).unwrap(),
    )
    .unwrap();
    for (item, text) in [("KEN-6", "Which schema?"), ("KEN-8", "Parked question")] {
        let file = world.path().join(format!("{item}.txt"));
        std::fs::write(&file, text).unwrap();
        let asked = program(&mail)
            .current_dir(world.path())
            .args(["ask", "--item", item, "--file"])
            .arg(&file)
            .output()
            .unwrap();
        assert!(asked.status.success(), "{}", stderr(&asked));
    }
    let lane_mail = mail.display().to_string();
    let extra = [("LANE_MAIL_CLI", lane_mail.as_str())];
    let listed = world.run(&["handoff", "--fleet", "--asks"], &extra);
    let listed = reply(&listed)["result"]["asks"].clone();
    assert_eq!(listed.as_array().map(Vec::len), Some(1), "{listed}");
    assert_eq!(listed[0]["lane"], json!("KEN-6"), "{listed}");
    assert_eq!(
        listed[0]["asks"][0]["text"],
        json!("Which schema?"),
        "{listed}"
    );
    let id = listed[0]["asks"][0]["id"].as_str().unwrap().to_owned();
    let body = world.path().join("body.md");
    std::fs::write(
        &body,
        "## State\nSession: live\nOpen lane asks: none\n\n## Workarounds\nnone\n",
    )
    .unwrap();
    let handoff = world.path().join("tmp/handoffs/H.md");
    let handoff_arg = handoff.display().to_string();
    let body_arg = body.display().to_string();
    let write = |body: &str| {
        world.run(
            &[
                "handoff",
                "--fleet",
                "--body",
                body,
                "--handoff",
                &handoff_arg,
            ],
            &extra,
        )
    };
    let out = write(&body_arg);
    assert_eq!(reply(&out)["ok"], json!(true), "{}", stderr(&out));
    let text = std::fs::read_to_string(&handoff).unwrap();
    let mut lines = text.lines();
    let header = lines.next().unwrap();
    assert!(
        header.starts_with("Start here: ") && header.ends_with(" generation=7"),
        "{text}"
    );
    let line = format!("Open lane asks: {id} (KEN-6)");
    assert_eq!(
        text.lines()
            .filter(|l| l.starts_with("Open lane asks:"))
            .collect::<Vec<_>>(),
        vec![line.as_str()],
        "{text}"
    );
    assert!(text.contains("## State\nOpen lane asks:"), "{text}");
    for (name, content, key, reason) in [
        (
            "header",
            "Start here: x generation=1\n## State\n",
            "handoff-body-invalid",
            Some("header"),
        ),
        (
            "ruling",
            "## Progress log\n- Ruling: merge\n",
            "handoff-body-invalid",
            Some("progress-log-ruling"),
        ),
        (
            "filing",
            "## Progress log\nKEN-12 filed for the gap\n",
            "handoff-body-invalid",
            Some("progress-log-filing"),
        ),
        (
            "verifying",
            "## Progress log\nbox 3 passed\n",
            "handoff-body-invalid",
            Some("progress-log-verifying"),
        ),
        (
            "empty",
            "",
            "handoff-body-invalid",
            Some("not-nonempty-regular"),
        ),
    ] {
        let file = world.path().join(format!("{name}.md"));
        std::fs::write(&file, content).unwrap();
        let out = write(&file.display().to_string());
        let answer = reply(&out);
        assert_eq!(answer["refusal"]["key"], json!(key), "{name}: {answer}");
        if let Some(reason) = reason {
            assert_eq!(refused_field(&answer, "reason"), reason, "{name}: {answer}");
        }
        assert_eq!(std::fs::read_to_string(&handoff).unwrap(), text, "{name}");
    }
    let installed = write(&handoff_arg);
    assert_eq!(
        refused_field(&reply(&installed), "reason"),
        "installed-handoff",
        "{}",
        stderr(&installed)
    );
    let recovery = world.path().join("recovery.md");
    std::fs::write(&recovery, "The predecessor changed models.\n").unwrap();
    let kept = world.run(
        &[
            "handoff",
            "--fleet",
            "--body",
            &recovery.display().to_string(),
            "--handoff",
            &handoff_arg,
            "--keep-prior",
        ],
        &extra,
    );
    assert_eq!(reply(&kept)["ok"], json!(true), "{}", stderr(&kept));
    let after = std::fs::read_to_string(&handoff).unwrap();
    assert_eq!(
        after
            .lines()
            .filter(|l| l.starts_with("Start here:"))
            .count(),
        1,
        "{after}"
    );
    assert!(
        after.contains("Session: live") && after.ends_with("The predecessor changed models.\n"),
        "{after}"
    );
    let mut stale = fleet.clone();
    stale["overseer"]
        .as_object_mut()
        .unwrap()
        .remove("generation");
    std::fs::write(
        world.path().join(agent_runtime::record::FLEET_FILE_NAME),
        serde_json::to_string(&stale).unwrap(),
    )
    .unwrap();
    let unstamped = reply(&write(&body_arg));
    assert_eq!(
        unstamped["refusal"]["key"],
        json!("handoff-stale"),
        "{unstamped}"
    );
    assert_eq!(refused_field(&unstamped, "found"), "none", "{unstamped}");
}

/// The replies the hook suites plant for the judge (`hooks/tests/fixtures/
/// marks-replies.json`) are the `marks` verb's own, each answered here for
/// the inputs it records: through the real executable, and the memory mark
/// through the judge itself over a fixture cgroup reading. Only `resets`, a
/// time the planted account's reset stands at, is compared by presence.
#[test]
fn the_hook_suites_plant_the_marks_verbs_own_replies() {
    use agent_runtime::controller::views::Caller;
    use agent_runtime::process::{Identity, Memory};
    use agent_runtime::reading::Reading;
    use orch_runtime::watch::overseer::{MarksAsk, judge_marks};
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../hooks/tests/fixtures/marks-replies.json");
    let planted: Value = serde_json::from_str(&std::fs::read_to_string(&fixture).unwrap()).unwrap();
    let comparable = |reply: &Value| {
        let mut reply = reply.clone();
        if let Some(resets) = reply.get_mut("resets") {
            *resets = json!("present");
        }
        reply
    };
    let mut wrong = serde_json::Map::new();
    for (name, case) in planted.as_object().unwrap() {
        let inputs = &case["inputs"];
        let mut world = MarksWorld::new();
        match inputs["used"].as_u64() {
            Some(used) => {
                let mut account = measured_account("eclaude", used);
                if let Some(rate) = inputs["rate"].as_f64() {
                    account["usage_rate_pct_per_min"] = json!(rate);
                }
                world.plant(None, &[account]);
                world.write_fleet(&world.dir("eclaude"));
            }
            None => world.write_fleet("/home/nobody/.claude"),
        }
        let env: Vec<(String, String)> = inputs["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_owned()))
            .collect();
        let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let answered = match inputs["memory"].as_array() {
            None => {
                let mut args = Vec::new();
                if let Some(context) = inputs["context"].as_str() {
                    args.extend(["--context", context]);
                }
                world.marks(&args, &env)
            }
            Some(memory) => {
                let roots = agent_runtime::settings::Roots {
                    project: world.path().to_path_buf(),
                    common: world.path().to_path_buf(),
                };
                let mut environment = world.environment();
                environment.extend(env.iter().map(|(k, v)| ((*k).into(), (*v).into())));
                let settings = orch_runtime::settings::load(
                    &roots,
                    &environment,
                    &orch_runtime::settings::Flags {
                        state_dir: Some(world.path().to_path_buf()),
                        private_env: false,
                    },
                )
                .unwrap();
                let host = orch_runtime::ops::Host::kernel();
                let reading = Reading::Live(Some(Memory {
                    current: memory[0].as_u64().unwrap(),
                    max: memory[1].as_u64().unwrap(),
                    oom_kill: None,
                }));
                let read = |_: &Identity| reading.clone();
                let caller = Caller {
                    harness: Some(agent_runtime::harness::Harness::Claude),
                    account: Some(world.dir("eclaude")),
                    home: Some(world.dir("eclaude")),
                    model: Some("opus".to_owned()),
                    cwd: Some(world.path().display().to_string()),
                    identity: Some(Identity {
                        pid: 4242,
                        start: "ticks:1".to_owned(),
                    }),
                    ..Caller::default()
                };
                judge_marks(&MarksAsk {
                    settings: &settings,
                    fleet_path: &world.path().join(agent_runtime::record::FLEET_FILE_NAME),
                    host: &host,
                    caller: &caller,
                    context: None,
                    memory: &read,
                    now: now_secs(),
                })
                .unwrap()
                .reply()
            }
        };
        if comparable(&case["reply"]) != comparable(&answered) {
            wrong.insert(name.clone(), answered);
        }
    }
    assert!(
        wrong.is_empty(),
        "planted replies the verb does not answer: {}",
        Value::Object(wrong)
    );
}

/// An account kept from workers, by the owner's
/// `AGENT_RUNTIME_ACCOUNT_EXCLUDE` or by a provider's `reserved=1` on a row
/// with no reading, is kept from every lane, never from the controller
/// already on it: the real `marks` verb reads the kept home's figures for
/// the controller seated on it, and the real `lane pick --lane` refuses the
/// same home to a lane by its word, with the figures it measured.
#[test]
fn a_home_kept_from_workers_is_measured_for_its_overseers_marks_and_refused_to_a_lane_pick() {
    // case, the provider's host, the owner's setting, the lane's answer
    let cases = [
        (
            "excluded",
            None,
            Some(("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "eclaude")),
            "excluded",
        ),
        ("reserved", Some("vm"), None, "reserved"),
    ];
    for (case, host, setting, answer) in cases {
        let mut world = MarksWorld::new();
        let home = world.dir("eclaude");
        let mut measured = measured_account("eclaude", 20);
        measured["model_buckets"] =
            json!([{"label": null, "pct": 20, "resets_at": measured["binding_resets_at"]}]);
        let mut rows = vec![measured];
        if host.is_some() {
            rows.push(json!({
                "harness": "claude", "config_dir": home, "measured_through": "host", "reserved": 1
            }));
        }
        world.plant(host, &rows);
        world.write_fleet(&home);
        let env: Vec<(&str, &str)> = setting.into_iter().collect();
        let marks = world.marks(&["--context", "100000:1000000"], &env);
        assert_eq!(marks["key"], json!("below-mark"), "{case}: {marks}");
        assert_eq!(
            marks["headroom"],
            json!("80"),
            "{case}: the overseer reads its kept home's figures: {marks}"
        );
        let pick = world.pick_lane(&home, &env)["result"].clone();
        assert_eq!(pick["answer"], json!(answer), "{case}: {pick}");
        assert_eq!(pick["exit"], json!(3), "{case}: {pick}");
        assert_eq!(pick["record"]["word"], json!("reserve"), "{case}: {pick}");
        assert_eq!(
            pick["record"]["headroom_pct"],
            json!(80),
            "{case}: the refused home is measured: {pick}"
        );
    }
}

/// The account judge's replies the hook suites plant for a lane's turn end
/// (`hooks/tests/fixtures/pick-replies.json`) are the real `lane pick
/// --lane`'s, each answered here for the inputs it records: a measured
/// Claude home `used` percent spent, the provider's row where `host` names
/// one (`reserved` its reserve word), under `env`, compared in
/// [`planted_form`]. A shape whose inputs name a `row` is that row's to
/// answer.
#[test]
fn the_hook_suites_plant_the_account_judges_own_replies() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../hooks/tests/fixtures/pick-replies.json");
    let planted: Value = serde_json::from_str(&std::fs::read_to_string(&fixture).unwrap()).unwrap();
    let mut wrong = serde_json::Map::new();
    for (name, case) in planted.as_object().unwrap() {
        let inputs = &case["inputs"];
        if inputs["row"].is_string() {
            continue;
        }
        let mut world = MarksWorld::new();
        let mut account = measured_account("eclaude", inputs["used"].as_u64().unwrap());
        let host = inputs["host"].as_str();
        let dir = match host {
            Some(_) => {
                account["measured_through"] = json!("host");
                account["reserved"] = inputs["reserved"].clone();
                account["config_dir"].as_str().unwrap().to_owned()
            }
            None => world.dir("eclaude"),
        };
        world.plant(host, &[account]);
        world.write_fleet("/home/nobody/.claude");
        let env: Vec<(String, String)> = inputs["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_owned()))
            .collect();
        let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let answered = world.pick_lane(&dir, &env)["result"].clone();
        let home = world.path().join("home");
        if planted_form(&case["reply"], Path::new("/home/me")) != planted_form(&answered, &home) {
            wrong.insert(name.clone(), spelled_home(&answered, &home));
        }
    }
    assert!(
        wrong.is_empty(),
        "planted replies the judge does not answer: {}",
        Value::Object(wrong)
    );
}

#[test]
fn a_memory_mark_set_to_zero_is_no_mark_rather_than_one_every_pass_crosses() {
    let dir = tempfile::tempdir().unwrap();
    let roots = agent_runtime::settings::Roots {
        project: dir.path().to_path_buf(),
        common: dir.path().to_path_buf(),
    };
    let memory_pct = |value: Option<&str>| {
        let mut environment: Vec<(std::ffi::OsString, std::ffi::OsString)> =
            vec![("HOME".into(), dir.path().into())];
        if let Some(value) = value {
            environment.push(("ORCH_OVERSEER_MEMORY_PCT".into(), value.into()));
        }
        orch_runtime::settings::load(
            &roots,
            &environment,
            &orch_runtime::settings::Flags {
                state_dir: Some(dir.path().to_path_buf()),
                private_env: false,
            },
        )
        .unwrap()
        .marks
        .memory_pct
        .get()
        .unwrap()
    };
    for (value, expected) in [(None, None), (Some("0"), None), (Some("80"), Some(80))] {
        assert_eq!(memory_pct(value), expected, "{value:?}");
    }
}

/// The provider's row with room supplies the caller's headroom; a
/// `plan_ended` row reaches the headroom mark at zero carrying its status.
#[test]
fn a_hosted_caller_reads_its_headroom_off_the_providers_row_and_an_ended_plan_the_mark() {
    let mut world = MarksWorld::new();
    let mut room = measured_account("claude", 5);
    room["measured_through"] = json!("host");
    room["usage_rate_state"] = json!("one-sample");
    world.plant(Some("prov"), &[room]);
    world.write_fleet("/home/me/.claude");
    let off = [("ORCH_OVERSEER_WALL_MINUTES", "0")];
    let below = world.marks(&["--context", "100000:1000000"], &off);
    assert_eq!(below["key"], json!("below-mark"), "{below}");
    assert_eq!(below["headroom"], json!("95"));
    let mut ended = measured_account("claude", 5);
    ended["measured_through"] = json!("host");
    ended["status"] = json!("plan_ended");
    ended["detail"] = json!("http-403-oauth_not_allowed_for_organization");
    world.plant(Some("prov"), &[ended]);
    let reached = world.marks(&["--context", "100000:1000000"], &off);
    assert_eq!(reached["key"], json!("mark-reached"), "{reached}");
    assert_eq!(reached["kind"], json!("headroom"));
    assert_eq!(reached["value"], json!("0"));
    assert_eq!(reached["mark"], json!("5"));
    assert_eq!(reached["status"], json!("plan_ended"));
    assert_eq!(reached["account"], json!("claude"));
    assert_eq!(reached["resets"], json!("none"));
    assert_eq!(reached["context_decision"]["tokens"], json!(100000));
}

/// Sixty points of headroom burning two points a minute reach the wall in
/// thirty minutes: the rate mark fires at thirty and not at twenty-nine. A
/// rate the reader holds one sample of is `mark-unmeasured kind=rate`,
/// its reason the rate's state, while the rate mark is set, and no answer
/// at all with the mark off.
#[test]
fn a_fast_burn_reaches_the_rate_mark_at_the_minutes_the_sample_projects() {
    let mut world = MarksWorld::new();
    let mut fast = measured_account("eclaude", 40);
    fast["usage_rate_pct_per_min"] = json!(2.0);
    world.plant(None, &[fast]);
    world.write_fleet(&world.dir("eclaude"));
    let reached = world.marks(
        &["--context", "100000:1000000"],
        &[("ORCH_OVERSEER_WALL_MINUTES", "30")],
    );
    assert_eq!(reached["key"], json!("mark-reached"), "{reached}");
    assert_eq!(reached["kind"], json!("rate"));
    assert_eq!(reached["value"], json!("30"));
    assert_eq!(reached["mark"], json!("30"));
    assert_eq!(reached["account"], json!("eclaude"));
    let below = world.marks(
        &["--context", "100000:1000000"],
        &[("ORCH_OVERSEER_WALL_MINUTES", "29")],
    );
    assert_eq!(below["key"], json!("below-mark"), "{below}");
    assert_eq!(below["headroom"], json!("60"));
    let mut sampled = measured_account("eclaude", 40);
    sampled["usage_rate_state"] = json!("one-sample");
    sampled["usage_rate_pct_per_min"] = Value::Null;
    world.plant(None, &[sampled]);
    let unread = world.marks(
        &["--context", "100000:1000000"],
        &[("ORCH_OVERSEER_WALL_MINUTES", "30")],
    );
    assert_eq!(unread["key"], json!("mark-unmeasured"), "{unread}");
    assert_eq!(unread["kind"], json!("rate"));
    assert_eq!(unread["reason"], json!("one-sample"));
    let off = world.marks(
        &["--context", "100000:1000000"],
        &[("ORCH_OVERSEER_WALL_MINUTES", "0")],
    );
    assert_eq!(off["key"], json!("below-mark"), "{off}");
}

/// A Codex controller whose plan windows are spent at the trigger and
/// whose credits hold a balance short of the launch floor reaches the
/// headroom mark `reserve_only`: the watch keeps it working on its reserve
/// rather than calling it walled. With no balance the mark is an ordinary
/// wall.
#[test]
fn a_codex_controller_at_the_trigger_with_spendable_credits_reaches_the_mark_on_its_reserve() {
    let spent = |balance: u64| {
        let resets = agent_runtime::clock::iso_utc(now_secs() + 60 * 3600);
        json!({
            "alias": "ecodex",
            "harness": "codex",
            "config_dir": "/home/me/.ecodex",
            "measured_through": "local",
            "status": "ok",
            "headroom_pct": 0,
            "session_5h_pct": 100,
            "weekly_pct": 100,
            "resets": {"session": resets, "weekly": resets, "model": null, "monthly": null},
            "credits": {"has_credits": true, "unlimited": false, "overage_limit_reached": false,
                        "spend_control_reached": false, "balance": balance},
        })
    };
    let mut world = MarksWorld::new();
    world.plant(None, &[spent(1000)]);
    world.write_fleet_on(json!("codex"), &world.dir("ecodex"));
    let off = [("ORCH_OVERSEER_WALL_MINUTES", "0")];
    let reserve = world.marks(&[], &off);
    assert_eq!(reserve["key"], json!("mark-reached"), "{reserve}");
    assert_eq!(reserve["kind"], json!("headroom"));
    assert_eq!(reserve["value"], json!("0"));
    assert_eq!(reserve["reserve_only"], json!(true), "{reserve}");
    world.plant(None, &[spent(0)]);
    let walled = world.marks(&[], &off);
    assert_eq!(walled["key"], json!("mark-reached"), "{walled}");
    assert_eq!(walled["kind"], json!("headroom"));
    assert!(walled.get("reserve_only").is_none(), "{walled}");
}

/// The verb's refusals, each its keyed line and nothing judged: a context
/// reading that is no `TOKENS:WINDOW`, a record naming no harness with
/// none named, a harness nobody runs, and a fleet holding no controller
/// record.
#[test]
fn the_marks_verb_refuses_an_unread_context_an_unnamed_or_unknown_harness_and_no_record() {
    let mut world = MarksWorld::new();
    world.plant(None, &[measured_account("eclaude", 10)]);
    let refused = |world: &MarksWorld, args: &[&str]| {
        refusal_key(&world.run(&[&["marks", "--fleet"][..], args].concat(), &[]))
    };
    assert_eq!(refused(&world, &[]), "record-missing");
    world.write_fleet(&world.dir("eclaude"));
    assert_eq!(
        refused(&world, &["--context", "many:tokens"]),
        "context-invalid"
    );
    assert_eq!(refused(&world, &["--harness", "emacs"]), "harness-unknown");
    world.write_fleet_on(Value::Null, &world.dir("eclaude"));
    assert_eq!(
        refused(&world, &["--context", "100000:1000000"]),
        "harness-unnamed"
    );
    let named = world.marks(
        &["--context", "100000:1000000", "--harness", "claude"],
        &[("ORCH_OVERSEER_WALL_MINUTES", "0")],
    );
    assert_eq!(
        named["key"],
        json!("below-mark"),
        "the named harness judges: {named}"
    );
    // A mark, the succession switch or an account setting outside its form
    // refuses `marks --fleet` by key and value, and an account setting the
    // accounts judge's `lane pick` too; a lane's `marks --item`, which
    // reads the context mark alone, answers under each but that mark, and
    // `state path --fleet` under that one.
    world.write_fleet(&world.dir("eclaude"));
    let dir = world.dir("eclaude");
    let refusal = |out: &std::process::Output| {
        let refusal = &reply(out)["refusal"];
        json!({"key": refusal["key"], "fields": refusal["fields"]})
    };
    for (key, value, judge) in [
        ("ORCH_OVERSEER_WALL_MINUTES", "-5", false),
        ("ORCH_OVERSEER_MEMORY_PCT", "101", false),
        ("ORCH_HANDOFF_CONTEXT_PCT", "0", false),
        ("AGENT_RUNTIME_CONTROLLER_SUCCESSION", "maybe", false),
        ("AGENT_RUNTIME_ACCOUNT_RETIRE", "a=2027-02-30", true),
        ("ORCH_LANE_CLOUD_REPOS", "a=repo", true),
        ("AGENT_RUNTIME_COPILOT_POOL", "/p=1/0", true),
        ("AGENT_RUNTIME_ACCOUNT_EXCLUDE", "~/x", true),
        ("AGENT_RUNTIME_ACCOUNT_MAX_PCT", "101", true),
        ("AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR", "five", true),
        ("AGENT_RUNTIME_CONTROLLER_HEADROOM_PCT", "-1", true),
        ("AGENT_RUNTIME_CODEX_CREDIT_FLOOR", "1.5", true),
        ("AGENT_RUNTIME_CLOUD_CREDIT_FLOOR", "x", true),
        ("AGENT_RUNTIME_USAGE_TTL", "5m", true),
        ("AGENT_RUNTIME_USAGE_MAX_AGE", "+1", true),
        ("ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S", "-30", true),
    ] {
        let env = [(key, value)];
        let want = json!({"key": "setting-invalid", "fields": [["key", key], ["value", value]]});
        let fleet = world.run(&["marks", "--fleet", "--context", "100000:1000000"], &env);
        assert_eq!(refusal(&fleet), want, "{key}: {}", stderr(&fleet));
        if judge {
            let pick = world.run(
                &[
                    "lane",
                    "pick",
                    "--fleet",
                    "--lane",
                    &dir,
                    "--harness",
                    "claude",
                ],
                &env,
            );
            assert_eq!(refusal(&pick), want, "{key}: {}", stderr(&pick));
        }
        let control: &[&str] = if key == "ORCH_HANDOFF_CONTEXT_PCT" {
            &["state", "path", "--fleet"]
        } else {
            &["marks", "--item", "KEN-1", "--context", "100000:1000000"]
        };
        let out = world.run(control, &env);
        assert_eq!(reply(&out)["ok"], json!(true), "{key}: {}", stderr(&out));
    }
}

#[test]
fn an_unmeasured_caller_answers_mark_unmeasured_headroom() {
    let mut world = MarksWorld::new();
    let mut unread = measured_account("eclaude", 10);
    unread["status"] = json!("unreachable");
    unread["headroom_pct"] = Value::Null;
    unread["wall"] = Value::Null;
    world.plant(None, &[unread, measured_account("bclaude", 10)]);
    world.write_fleet(&world.dir("eclaude"));
    let answer = world.marks(&[], &[]);
    assert_eq!(answer["key"], json!("mark-unmeasured"), "{answer}");
    assert_eq!(answer["kind"], json!("headroom"));
    assert_eq!(answer["reason"], json!("headroom-none"));
}

/// On fixture cgroup files: a cap on a parent of the group is the nearest
/// cap and the charge against it reaches the mark, read with the caps' OOM
/// kill count, each capped group's `memory.events` `oom_kill` summed and
/// none where one is unread; a path with no cap is inert; a group whose charge cannot be read is `mark-unmeasured
/// kind=memory`; a pid the proc tree lacks is gone; with no setting the
/// mark is never judged.
#[test]
fn the_memory_mark_reads_the_cgroup_three_valued_and_fires_at_the_setting() {
    use agent_runtime::controller::views::{Caller, MarkKind};
    use agent_runtime::process::{Identity, Memory, memory_of};
    use agent_runtime::reading::Reading;
    use orch_runtime::watch::overseer::{MarkKey, MarksAsk, judge_marks};
    let mut world = MarksWorld::new();
    world.plant(None, &[measured_account("eclaude", 10)]);
    world.write_fleet(&world.dir("eclaude"));
    let proc_root = world.path().join("proc");
    let cgroup = world.path().join("cgroup");
    std::fs::create_dir_all(proc_root.join("4242")).unwrap();
    std::fs::write(proc_root.join("4242/cgroup"), "0::/a/b\n").unwrap();
    std::fs::create_dir_all(cgroup.join("a/b")).unwrap();
    std::fs::write(cgroup.join("a/b/memory.current"), "100\n").unwrap();
    std::fs::write(cgroup.join("a/b/memory.max"), "max\n").unwrap();
    std::fs::write(cgroup.join("a/memory.current"), "900\n").unwrap();
    std::fs::write(cgroup.join("a/memory.max"), "1000\n").unwrap();
    let parent = Reading::Live(Some(Memory {
        current: 900,
        max: 1000,
        oom_kill: None,
    }));
    assert_eq!(memory_of(&proc_root, &cgroup, 4242), parent);
    let kills = |oom_kill: Option<u64>| {
        Reading::Live(Some(Memory {
            current: 900,
            max: 1000,
            oom_kill,
        }))
    };
    std::fs::write(
        cgroup.join("a/memory.events"),
        "low 0\nhigh 0\nmax 4\noom 2\noom_kill 2\noom_group_kill 0\n",
    )
    .unwrap();
    assert_eq!(memory_of(&proc_root, &cgroup, 4242), kills(Some(2)));
    std::fs::write(cgroup.join("a/b/memory.max"), "2000\n").unwrap();
    assert_eq!(
        memory_of(&proc_root, &cgroup, 4242),
        kills(None),
        "a capped group whose count is unread leaves the sum unread, the charge standing"
    );
    std::fs::write(cgroup.join("a/b/memory.events"), "oom_kill 1\n").unwrap();
    assert_eq!(memory_of(&proc_root, &cgroup, 4242), kills(Some(3)));
    std::fs::write(cgroup.join("a/b/memory.max"), "max\n").unwrap();
    std::fs::remove_file(cgroup.join("a/b/memory.events")).unwrap();
    std::fs::remove_file(cgroup.join("a/memory.events")).unwrap();
    std::fs::write(cgroup.join("a/b/memory.max"), "2000\n").unwrap();
    assert_eq!(memory_of(&proc_root, &cgroup, 4242), parent);
    std::fs::write(cgroup.join("a/b/memory.max"), "max\n").unwrap();
    std::fs::remove_file(cgroup.join("a/memory.current")).unwrap();
    assert_eq!(
        memory_of(&proc_root, &cgroup, 4242),
        Reading::Unreadable {
            cause: "memory-current-unreadable"
        }
    );
    std::fs::write(cgroup.join("a/memory.max"), "max\n").unwrap();
    assert_eq!(memory_of(&proc_root, &cgroup, 4242), Reading::Live(None));
    assert_eq!(memory_of(&proc_root, &cgroup, 9999), Reading::Gone);
    let settings = |extra: &[(&str, &str)]| {
        let roots = agent_runtime::settings::Roots {
            project: world.path().to_path_buf(),
            common: world.path().to_path_buf(),
        };
        let mut environment = world.environment();
        environment.extend(extra.iter().map(|(k, v)| ((*k).into(), (*v).into())));
        orch_runtime::settings::load(
            &roots,
            &environment,
            &orch_runtime::settings::Flags {
                state_dir: Some(world.path().to_path_buf()),
                private_env: false,
            },
        )
        .unwrap()
    };
    let fleet_path = world.path().join(agent_runtime::record::FLEET_FILE_NAME);
    let caller = Caller {
        harness: Some(agent_runtime::harness::Harness::Claude),
        account: Some(world.dir("eclaude")),
        home: Some(world.dir("eclaude")),
        model: Some("opus".to_owned()),
        effort: None,
        cwd: Some(world.path().display().to_string()),
        permission: None,
        extra_args: Vec::new(),
        handoff: None,
        identity: Some(Identity {
            pid: 4242,
            start: "ticks:1".to_owned(),
        }),
    };
    let judge = |extra: &[(&str, &str)], reading: Reading<Option<Memory>>| {
        let settings = settings(extra);
        let host = orch_runtime::ops::Host::kernel();
        let memory = |_: &Identity| reading.clone();
        judge_marks(&MarksAsk {
            settings: &settings,
            fleet_path: &fleet_path,
            host: &host,
            caller: &caller,
            context: None,
            memory: &memory,
            now: now_secs(),
        })
        .unwrap()
    };
    let set = [
        ("ORCH_OVERSEER_MEMORY_PCT", "80"),
        ("ORCH_OVERSEER_WALL_MINUTES", "0"),
    ];
    let capped = Reading::Live(Some(Memory {
        current: 900,
        max: 1000,
        oom_kill: None,
    }));
    let reached = judge(&set, capped.clone());
    assert_eq!(reached.key, MarkKey::Reached(MarkKind::Memory));
    assert_eq!(reached.value, "90");
    assert_eq!(reached.mark, "80");
    assert_eq!(judge(&set, Reading::Live(None)).key, MarkKey::Below);
    let unread = judge(
        &set,
        Reading::Unreadable {
            cause: "memory-current-unreadable",
        },
    );
    assert_eq!(unread.key, MarkKey::Unmeasured(MarkKind::Memory));
    assert_eq!(unread.reason, "memory-current-unreadable");
    let unset = judge(
        &[("ORCH_OVERSEER_WALL_MINUTES", "0")],
        Reading::Unreadable {
            cause: "memory-current-unreadable",
        },
    );
    assert_eq!(unset.key, MarkKey::Below, "no setting judges no memory");
}

// ---------------------------------------------------------------------------
// The watch a start launches over a released loop's record.
// ---------------------------------------------------------------------------

/// A released repeat loop that died without its trap leaves a claim record
/// naming a dead pid and no `start=`. The start's watch step reads that
/// record gone, launches `watch run`, which takes the record over with one
/// `watch-taken-over` line naming `start=none`, claims under its own
/// identity, and the start confirms with the job discharged by that claim.
#[test]
fn a_stale_start_less_claim_is_taken_over_by_the_starts_watch_with_one_line() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (bin, env) = watch_world(runner.state_dir());
    runner.tools = Some(bin);
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let paths = orch_runtime::watch::claim::Paths::of(&state).unwrap();
    std::fs::write(
        &paths.pid,
        format!(
            "pid={GONE_PID}\nstate={}\npane=%1\norigin=hand\nscript=/w/oversee-watch\ncwd=/w\n",
            paths.state.display()
        ),
    )
    .unwrap();
    let env: Vec<(&str, &str)> = env.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let report = effect_report(&runner.op_fleet_env(
        &json!({
            "op": "start-controller",
            "controller": pending(runner.state_dir()),
            "watch": watch_words(&state),
        }),
        &env,
    ));
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let claim = orch_runtime::watch::claim::read(&paths)
        .unwrap()
        .expect("the runtime's claim replaced the released record");
    assert!(
        claim.start.is_some(),
        "the claim names an identity: {claim:?}"
    );
    assert!(live(claim.pid), "a live runtime claim: {claim:?}");
    let lines: Vec<String> = std::fs::read_to_string(&paths.log)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    assert_eq!(
        lines.first().map(String::as_str),
        Some(format!("EVENT watch-taken-over pid={GONE_PID} start=none reason=gone").as_str()),
        "{lines:?}"
    );
    assert_eq!(
        lines
            .iter()
            .filter(|l| l.starts_with("EVENT watch-taken-over "))
            .count(),
        1,
        "one takeover line: {lines:?}"
    );
    let intent = runner.fleet()["intents"][0].clone();
    assert_eq!(discharged_by(&intent, "watch-claimed").len(), 1, "{intent}");
    stop_live_watch(&runner, &state);
}

// ---------------------------------------------------------------------------
// The workflow's launch: the runtime's `successor` verb, its answer through
// the real `start-controller` and `request-transfer`.
// ---------------------------------------------------------------------------

/// A running controller the row owns: on SIGTERM it copies the fleet state
/// at `fleet` to `snapshot`, so a row reads what the record said when the
/// controller was stopped, then exits.
struct Stopped(std::process::Child);

impl Stopped {
    fn start(fleet: &Path, snapshot: &Path) -> Stopped {
        let script = format!(
            "trap 'cp -- \"{}\" \"{}\"; exit 0' TERM; while :; do sleep 0.1; done",
            fleet.display(),
            snapshot.display()
        );
        Stopped(
            std::process::Command::new("bash")
                .args(["-c", &script])
                .spawn()
                .expect("bash"),
        )
    }

    fn pid(&self) -> u32 {
        self.0.id()
    }
}

impl Drop for Stopped {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// The launch's world on the runner's server: the watch world's `bin` and
/// environment, the checkout the launch runs from, the accounts `rows`
/// planted for the walk's judge, and the work directory the launch starts
/// in. Returns the scripts directory, `bin`, the environment and the work
/// directory.
fn walk_world(
    runner: &Runner,
    rows: &[Value],
) -> (
    std::path::PathBuf,
    std::path::PathBuf,
    Vec<(String, String)>,
    std::path::PathBuf,
) {
    walk_world_on(runner, None, rows)
}

/// [`walk_world`] with the provider `host` named, its rows the ones
/// measured through `host`.
fn walk_world_on(
    runner: &Runner,
    host: Option<&str>,
    rows: &[Value],
) -> (
    std::path::PathBuf,
    std::path::PathBuf,
    Vec<(String, String)>,
    std::path::PathBuf,
) {
    let (bin, mut env) = watch_world(runner.state_dir());
    let work = runner.state_dir().join("work");
    std::fs::create_dir(&work).unwrap();
    github_skill_under(&work);
    // A controller a row starts with `pending(&work)` names it its account.
    plant_credential(&work);
    let unplanted = runner.state_dir().join("unplanted");
    std::fs::create_dir(&unplanted).unwrap();
    let scripts = launcher_checkout(runner, &bin, &mut env, &unplanted, "claude");
    env.extend(plant_accounts(
        &runner.state_dir().join("accounts"),
        &runner.state_dir().join("watch-state"),
        host,
        rows,
        now_secs(),
    ));
    if host.is_some() {
        install_lane_host(runner.state_dir(), &runner.state_dir().join("accounts"));
    }
    env.push((
        "AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR".to_owned(),
        "0".to_owned(),
    ));
    (scripts, bin, env, work)
}

/// The directory `walk_world` planted the account `alias` at.
fn planted(runner: &Runner, alias: &str) -> String {
    runner
        .state_dir()
        .join("accounts/home")
        .join(format!(".{alias}"))
        .display()
        .to_string()
}

/// The controller record a succession replaces: `pid` running on the
/// account `alias` in `work`, under `permission` with `words`.
fn recorded_on(
    runner: &Runner,
    server: &Server,
    pid: u32,
    alias: &str,
    work: &Path,
    permission: &str,
    words: &[&str],
) -> Value {
    let mut record = overseer_record(pid, &start_of(pid), server, work);
    record["account"] = json!(planted(runner, alias));
    record["home"] = json!(planted(runner, alias));
    record["permission"] = json!(permission);
    record["extra_args"] = json!(words);
    let mut fleet = runner.fleet();
    fleet["overseer"] = record.clone();
    runner.write_fleet(&fleet);
    record
}

fn intents(runner: &Runner) -> usize {
    runner.fleet()["intents"].as_array().map_or(0, Vec::len)
}

/// The workflow asks the runtime's walk and hands its answer to the real
/// `start-controller`: with the first entry's only account walled, that
/// entry is passed over by name and the overseer opens on the second
/// entry's account with the walk's model and the settings' posture
/// recorded; with that walled entry alone, the walk answers `none` with its
/// counts and no successor, so no request is composed and no window, intent
/// or record is made.
#[test]
fn a_first_launch_opens_on_the_walks_choice_past_a_walled_entry_and_a_walk_choosing_none_opens_nothing()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let mut walled = measured_account("xcodex", 99);
    walled["harness"] = json!("codex");
    let (scripts, bin, env, work) = walk_world(&runner, &[walled, measured_account("aclaude", 5)]);
    let launch = |preference: &str| {
        workflow_launch(
            &runner,
            &scripts,
            &bin,
            &env,
            &work,
            "claude",
            "fable",
            &stub("stub-confirm"),
        )
        .env("AGENT_RUNTIME_CONTROLLER_PREFERENCE", preference)
        .run()
    };
    let none = launch("codex:gpt-6.1-sol:high");
    let chosen = none.chosen();
    let walk = &chosen["result"]["walk"];
    assert_eq!(walk["answer"], "none", "{chosen}");
    assert_eq!(
        (&walk["entries"], &walk["walled"], &walk["unmeasured"]),
        (&json!(1), &json!(1), &json!(0)),
        "{walk}"
    );
    assert!(chosen["result"]["successor"].is_null(), "{chosen}");
    assert!(none.op.is_none(), "no request where the walk chose none");
    assert_eq!(server.panes().len(), 1, "nothing opened");
    assert_eq!(intents(&runner), 0, "no intent: {}", runner.fleet());
    assert!(runner.fleet().get("overseer").is_none(), "no record");

    let opened = launch("codex:gpt-6.1-sol:high,claude:fable:high");
    let chosen = opened.chosen();
    let skipped = &chosen["result"]["walk"]["skipped"][0];
    assert_eq!(skipped["entry"], "codex:gpt-6.1-sol:high", "{chosen}");
    assert_eq!(skipped["reason"], "walled", "{chosen}");
    assert_eq!(skipped["lane"], planted(&runner, "xcodex"), "{chosen}");
    let started = opened.started();
    assert_eq!(
        started["outcome"],
        "confirmed",
        "{started}\n{}",
        stderr(opened.op())
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 1, "{overseer}");
    assert_eq!(overseer["harness"], "claude", "{overseer}");
    assert_eq!(
        overseer["account"],
        planted(&runner, "aclaude"),
        "{overseer}"
    );
    assert_eq!(overseer["model"], "fable", "{overseer}");
    assert_eq!(overseer["permission"], "bypass", "{overseer}");
    assert_eq!(overseer["pane"], runner_pane(&server), "{overseer}");
    stop_live_watch(
        &runner,
        &runner
            .state_dir()
            .join(agent_runtime::record::FLEET_FILE_NAME),
    );
}

/// The workflow, named the live recorded controller, asks the runtime for
/// the successor and hands it to the real `request-transfer`: when the
/// predecessor is signalled the intent already records the successor's
/// runner by its process identity; the successor is published on the
/// account the walk chose, launched with the predecessor's own permission
/// words and no bypass word, and its record carries that posture on.
#[test]
fn a_named_predecessor_is_succeeded_on_the_walks_choice_with_its_posture_once_the_successor_stands_recorded()
 {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (scripts, bin, env, work) = walk_world(
        &runner,
        &[
            measured_account("eclaude", 50),
            measured_account("bclaude", 5),
        ],
    );
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let snapshot = runner.state_dir().join("at-stop.json");
    let predecessor = Stopped::start(&state, &snapshot);
    let words = ["--permission-mode", "dontAsk"];
    recorded_on(
        &runner,
        &server,
        predecessor.pid(),
        "eclaude",
        &work,
        "native",
        &words,
    );
    let out = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-record"),
    )
    .predecessor("%99")
    .run();
    let op = out.op();
    assert!(op.status.success(), "{}", stderr(op));
    assert_eq!(
        reply(op)["result"]["effect"]["started"],
        "transfer-started",
        "{}",
        reply(op)
    );
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    let at_stop: Value = serde_json::from_str(
        &std::fs::read_to_string(&snapshot)
            .unwrap_or_else(|e| panic!("the predecessor was stopped by its signal: {e} {intent}")),
    )
    .unwrap();
    let at_stop_intent = &at_stop["intents"][0];
    let runner_pid = json!(server.pane_pid(&runner_pane(&server)));
    assert_eq!(
        at_stop_intent["phase"]["identity"]["pid"], runner_pid,
        "the successor's runner was recorded by its identity before the stop: {at_stop}"
    );
    assert!(
        at_stop_intent["obligations"]["standing"]
            .as_array()
            .unwrap()
            .iter()
            .any(|o| o["kind"] == "process" && o["role"] == "runner" && o["pid"] == runner_pid),
        "the runner stands in the intent's set at the stop: {at_stop}"
    );
    assert_eq!(
        at_stop["overseer"]["pending"]["account"],
        planted(&runner, "bclaude"),
        "{at_stop}"
    );
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(predecessor.pid()), "the predecessor was retired");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4, "{overseer}");
    assert_eq!(
        overseer["account"],
        planted(&runner, "bclaude"),
        "{overseer}"
    );
    assert_eq!(overseer["permission"], "native", "{overseer}");
    assert_eq!(overseer["extra_args"], json!(words), "{overseer}");
    let argv = argv_of(&launch_record(&work));
    assert!(
        argv.windows(2).any(|w| w == words),
        "the predecessor's words reach the successor: {argv:?}"
    );
    assert!(
        !argv.iter().any(|a| a == "--dangerously-skip-permissions"),
        "no bypass word under a native posture: {argv:?}"
    );
}

/// The hook's model-switch recovery relaunches the model and account the
/// published record names, so a record naming the predecessor's would
/// relaunch its model on the account it spent. The predecessor holds its
/// own pane on the fleet server, its record carrying the line a released
/// launch wrote for it, planted as `main` wrote it; the successor's record
/// names what it was launched with and no display line, and the real hook's
/// recovery reopens that.
#[test]
fn a_succession_publishes_the_successor_it_launched_and_a_model_switch_recovers_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (scripts, bin, env, work) = walk_world(
        &runner,
        &[
            measured_account("eclaude", 50),
            measured_account("bclaude", 5),
        ],
    );
    let pane = server.open_window(
        "overseer",
        &work,
        "trap 'exit 0' TERM; while :; do sleep 0.1; done",
    );
    let pid = server.pane_pid(&pane);
    let window = tmux(
        &server.socket,
        &["display-message", "-p", "-t", &pane, "#{window_id}"],
    );
    let spent = planted(&runner, "eclaude");
    let released = format!(
        "CLAUDE_CONFIG_DIR={spent} claude -n overseer --model opus --effort low \
         --dangerously-skip-permissions 'Read .agents/skills/orch/SKILL.md and follow \
         .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at \
         tmp/handoffs/OVERSEER-HANDOFF.md'"
    );
    let mut record = recorded_on(&runner, &server, pid, "eclaude", &work, "bypass", &[]);
    record["pane"] = json!(pane);
    record["window"] = json!(String::from_utf8_lossy(&window.stdout).trim());
    record["effort"] = json!("low");
    record["launch_line"] = json!(released);
    let mut fleet = runner.fleet();
    fleet["overseer"] = record;
    runner.write_fleet(&fleet);
    let launch = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-confirm"),
    )
    .predecessor(&pane);
    let out = launch.run();
    let op = out.op();
    assert!(op.status.success(), "{}", stderr(op));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert!(!live(pid), "the predecessor was retired");
    let overseer = runner.fleet()["overseer"].clone();
    let chosen = planted(&runner, "bclaude");
    assert_eq!(overseer["account"], chosen, "{overseer}");
    assert_eq!(
        overseer["model"], "fable",
        "the successor's model: {overseer}"
    );
    assert_eq!(
        overseer["effort"], "high",
        "the successor's effort: {overseer}"
    );
    assert_eq!(overseer["permission"], "bypass", "{overseer}");
    assert_eq!(
        overseer["launch_line"],
        Value::Null,
        "the predecessor's released line is dropped with its session: {overseer}"
    );
    let home = Path::new(overseer["home"].as_str().unwrap()).to_owned();
    let generation = overseer["generation"].as_u64().unwrap();
    let (hook, check) = model_switch(&runner, &scripts, &launch.env, &home, &work, &overseer);
    assert_eq!(
        check["outcome"],
        "switched",
        "{check}\n{}\n{}",
        String::from_utf8_lossy(&hook.stdout),
        stderr(&hook)
    );
    assert_eq!(
        stderr(&hook).lines().next().unwrap_or_default(),
        MODEL_SWITCHED,
        "the successor's notice: {}",
        stderr(&hook)
    );
    recovered(&runner, &work, generation, "fable", &json!(chosen));
}

/// Named another pane than the recorded one, the transfer is refused before
/// anything is written, its key read on the first `orch-runtime: ` line
/// after the settings notice that stands ahead of it; named the recorded
/// pane whose process has ended, the transfer fails `predecessor-not-live`
/// before any window opens, the pending put back.
#[test]
fn a_predecessor_that_is_not_the_live_recorded_controller_is_refused_with_nothing_opened() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (scripts, bin, env, work) = walk_world(&runner, &[measured_account("bclaude", 5)]);
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    // A settings notice ahead of the refusal: the state directory's private
    // settings file carries an account key in a form only a shell reads (a
    // user's tilde), which the runtime passes over with a notice on stderr
    // before any verb answers, read through a wrapper that keeps the private
    // file.
    std::fs::write(
        runner.state_dir().join(".env.local"),
        "AGENT_RUNTIME_ACCOUNT_DIRS=~orch-no-such-user/accounts\n",
    )
    .unwrap();
    let private = runner.state_dir().join("orch-runtime-private");
    write_executable(
        &private,
        format!("#!/bin/bash\nexec \"{}\" \"$@\"\n", binary().display()),
    );
    let launch = |pane: &str| {
        workflow_launch(
            &runner,
            &scripts,
            &bin,
            &env,
            &work,
            "claude",
            "fable",
            &stub("stub-confirm"),
        )
        .predecessor(pane)
        .wrapper(&private)
        .run()
    };
    let running = Stopped::start(&state, &runner.state_dir().join("unused.json"));
    let before = recorded_on(
        &runner,
        &server,
        running.pid(),
        "bclaude",
        &work,
        "bypass",
        &[],
    );
    let other = launch("%98");
    assert!(
        stderr(other.op()).starts_with("settings-skipped "),
        "the notice stands ahead of the refusal: {}",
        stderr(other.op())
    );
    assert_eq!(
        refusal_key(other.op()),
        "overseer-changed",
        "{}",
        stderr(other.op())
    );
    assert_eq!(intents(&runner), 0, "nothing written: {}", runner.fleet());
    assert_eq!(runner.fleet()["overseer"], before);
    assert!(live(running.pid()));

    let ended = Stopped::start(&state, &runner.state_dir().join("unused.json"));
    let gone = ended.pid();
    let before = recorded_on(&runner, &server, gone, "bclaude", &work, "bypass", &[]);
    drop(ended);
    let dead = launch("%99");
    let op = dead.op();
    assert_eq!(op.status.code(), Some(3), "{}", stderr(op));
    assert_eq!(
        dead.settled()["observation"]["note"],
        "predecessor-not-live",
        "{}",
        reply(op)
    );
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        intent["observation"]["note"], "predecessor-not-live",
        "{intent}"
    );
    assert_eq!(server.panes().len(), 1, "nothing opened");
    assert_eq!(
        runner.fleet()["overseer"],
        before,
        "the pending is put back"
    );
}

/// The successor's harness never draws its composer within the launch's
/// bound: the transfer fails before retirement, the runner's window is
/// closed, the predecessor keeps running and the record is as it stood.
#[test]
fn a_successor_that_never_comes_up_leaves_the_predecessor_running_and_its_record_put_back() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (scripts, bin, env, work) = walk_world(&runner, &[measured_account("bclaude", 5)]);
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let running = Stopped::start(&state, &runner.state_dir().join("unused.json"));
    let before = recorded_on(
        &runner,
        &server,
        running.pid(),
        "bclaude",
        &work,
        "bypass",
        &[],
    );
    let out = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-unconfirmed"),
    )
    .predecessor("%99")
    .wait_secs(1)
    .run();
    let op = out.op();
    assert_eq!(op.status.code(), Some(3), "{}", stderr(op));
    assert_eq!(
        out.settled()["observation"]["note"],
        "successor-not-ready",
        "{}",
        reply(op)
    );
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        intent["observation"]["note"], "successor-not-ready",
        "{intent}"
    );
    assert_eq!(intent["observation"]["retired"], false, "{intent}");
    assert!(live(running.pid()), "the predecessor keeps running");
    assert_eq!(server.panes().len(), 1, "the runner's window is closed");
    assert_eq!(runner.fleet()["overseer"], before, "the record as it stood");
}

/// The fleet's session the server does not hold fails the start
/// `tmux-session-missing`, naming it, before any window opens, and nothing
/// is published.
#[test]
fn a_start_into_a_tmux_session_the_server_lacks_fails_with_nothing_opened() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let report = effect_report(&runner.op_fleet_env(
        &json!({"op": "start-controller", "controller": pending(runner.state_dir())}),
        &[("AGENT_RUNTIME_TMUX_SESSION", "nosuch")],
    ));
    assert_eq!(report["intent"]["outcome"], "failed", "{report}");
    assert_eq!(
        report["intent"]["observation"]["note"], "tmux-session-missing",
        "{report}"
    );
    assert_eq!(
        report["intent"]["observation"]["fields"]["session"], "nosuch",
        "{report}"
    );
    assert_eq!(server.panes().len(), 1, "nothing opened");
    assert!(
        runner.fleet()["overseer"].get("generation").is_none(),
        "nothing published: {}",
        runner.fleet()
    );
}

// ---------------------------------------------------------------------------
// The successor's launch prerequisites: the home and trust the launch's own
// preparation makes, and the brief a controller opens on, for every
// succession the watch asks.
// ---------------------------------------------------------------------------

/// The pending the watch's walled succession opens for the recorded
/// controller when its walk chose `entry` on `account`: the watch's own
/// `Caller::successor_of` over the record as the fleet state holds it.
fn walled_successor(runner: &Runner, entry: &str, account: &Path) -> Value {
    use agent_runtime::accounts::walk::Chosen;
    use agent_runtime::controller::views::{Caller, Record};
    use orch_runtime::state::{FleetState, Record as _};
    let path = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let snapshot = orch_runtime::state::load(&path).unwrap().unwrap();
    let fleet = FleetState::view(&path, &snapshot.doc).unwrap();
    let record = Record::read(fleet.overseer.as_ref()).expect("the recorded controller");
    let mut words = entry.split(':');
    let (harness, model, effort) = (
        words.next().unwrap(),
        words.next().unwrap(),
        words.next().unwrap(),
    );
    let chosen = Chosen {
        entry: entry.to_owned(),
        harness: agent_runtime::harness::Harness::named(harness).unwrap(),
        host: None,
        model: model.to_owned(),
        class: None,
        effort: effort.to_owned(),
        pick_model: model.to_owned(),
        account: Some(account.display().to_string()),
        record: None,
        warning: None,
        launch: None,
        kept: false,
        kept_unmeasured: false,
    };
    serde_json::to_value(Caller::of(&record).successor_of(&chosen)).unwrap()
}

/// A walled controller of `caller` on the account `spent` under `home`,
/// running as a sleep the row owns, recorded under `runner`'s server; the
/// predecessor is returned so it stands until the row ends.
fn walled_on(runner: &Runner, server: &Server, caller: &str, spent: &Path, home: &Path) -> Owned {
    std::fs::create_dir_all(spent).unwrap();
    std::fs::create_dir_all(home).unwrap();
    let predecessor = Owned::sleep();
    let mut fleet = runner.fleet();
    let mut record = overseer_record(
        predecessor.pid(),
        &predecessor.start(),
        server,
        runner.state_dir(),
    );
    record["harness"] = json!(caller);
    record["account"] = json!(spent.display().to_string());
    record["home"] = json!(home.display().to_string());
    record["permission"] = json!("bypass");
    fleet["overseer"] = record;
    runner.write_fleet(&fleet);
    predecessor
}

/// The watch's walled request for `successor` off the spent account,
/// through the real `request-transfer` with the recording stubs as every
/// harness; the settled intent, and the launch record the successor's stub
/// wrote in the working directory.
fn walled_transfer(runner: &Runner, spent: &Path, successor: &Value) -> (Value, Value) {
    let before = runner.fleet()["overseer"].clone();
    let binaries = ["claude", "codex", "pi"]
        .map(|h| format!("{h}={}", fixtures().join("stub-record").join(h).display()))
        .join(",");
    runner.transfer_started_env(
        &json!({
            "op": "request-transfer",
            "cause": "walled",
            "exclude_account": spent.display().to_string(),
            "expected": expected_of(&before),
            "successor": successor,
        }),
        &[("AGENT_RUNTIME_HARNESS_BINARIES", &binaries)],
    );
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    let launched = launch_record(runner.state_dir());
    (intent, launched)
}

#[test]
fn a_walled_successor_on_another_harness_runs_on_the_home_its_launch_prepared() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let spent = work.join("claude-a");
    let codex = work.join("codex-b");
    plant_codex_credential(&codex);
    let _predecessor = walled_on(&runner, &server, "claude", &spent, &spent);
    let successor = walled_successor(&runner, "codex:gpt-6.1-sol:high", &codex);
    let (intent, launched) = walled_transfer(&runner, &spent, &successor);
    let prepared = agent_runtime::trust::home_path(&codex, &work);
    assert_eq!(
        launched["env"]["CODEX_HOME"],
        prepared.display().to_string(),
        "the prepared home, not the account's root: {launched} {intent}"
    );
    let config = std::fs::read_to_string(prepared.join("config.toml")).unwrap_or_default();
    assert!(
        config.contains(&format!("[projects.\"{}\"]", work.display()))
            && config.contains("trust_level = \"trusted\""),
        "the checkout is trusted before the window opened: {config}"
    );

    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(5);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let spent = work.join("codex-a");
    let claude = work.join("claude-b");
    plant_credential(&claude);
    let _predecessor = walled_on(&runner, &server, "codex", &spent, &spent);
    let successor = walled_successor(&runner, "claude:fable:high", &claude);
    let (intent, launched) = walled_transfer(&runner, &spent, &successor);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(
        launched["env"]["CLAUDE_CONFIG_DIR"],
        claude.display().to_string(),
        "{launched}"
    );
    let state: Value = serde_json::from_str(
        &std::fs::read_to_string(claude.join(".claude.json")).unwrap_or_default(),
    )
    .unwrap_or(Value::Null);
    assert_eq!(
        state["projects"][work.display().to_string()]["hasTrustDialogAccepted"],
        true,
        "the checkout is trusted before the window opened: {state}"
    );
    assert_eq!(
        runner.fleet()["overseer"]["home"],
        claude.display().to_string(),
        "the record names the home the launch ran under"
    );
}

#[test]
fn a_pi_successor_keeps_pi_s_own_root_and_bills_the_chosen_seat() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let home = work.join("home");
    std::fs::create_dir_all(home.join(".pi/agent")).unwrap();
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    let spent = work.join("claude-a");
    let seat = work.join("claude-b");
    std::fs::create_dir_all(&seat).unwrap();
    let _predecessor = walled_on(&runner, &server, "claude", &spent, &spent);
    let before = runner.fleet()["overseer"].clone();
    let panes = server.panes().len();
    let successor = walled_successor(&runner, "pi:pi-claude/claude-fable-5-1:high", &seat);
    runner.transfer_started_env(
        &json!({
            "op": "request-transfer",
            "cause": "walled",
            "exclude_account": spent.display().to_string(),
            "expected": expected_of(&before),
            "successor": successor,
        }),
        &[(
            "AGENT_RUNTIME_HARNESS_BINARIES",
            &format!("pi={}", fixtures().join("stub-record/pi").display()),
        )],
    );
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "failed", "{intent}");
    assert_eq!(
        intent["observation"]["note"], "launch-gate-refused",
        "{intent}"
    );
    assert_eq!(
        intent["observation"]["cause"],
        format!(
            "compaction-on harness=pi file={}/.pi/agent/settings.json",
            home.display()
        ),
        "{intent}"
    );
    assert_eq!(server.panes().len(), panes, "no window opened");
    assert_eq!(runner.fleet()["overseer"], before, "the record as it stood");

    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let home = work.join("home");
    pi_root_marked(&home.join(".pi/agent"));
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    let spent = work.join("claude-a");
    let seat = work.join("claude-b");
    std::fs::create_dir_all(&seat).unwrap();
    let _predecessor = walled_on(&runner, &server, "claude", &spent, &spent);
    let successor = walled_successor(&runner, "pi:pi-claude/claude-fable-5-1:high", &seat);
    let (intent, launched) = walled_transfer(&runner, &spent, &successor);
    assert_eq!(
        launched["env"]["PI_CODING_AGENT_DIR"],
        home.join(".pi/agent").display().to_string(),
        "Pi's own root, never the caller's home: {launched} {intent}"
    );
    assert_eq!(
        launched["env"]["CLAUDE_CONFIG_DIR"],
        seat.display().to_string(),
        "{launched}"
    );

    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let spent = work.join("claude-a");
    let root = work.join("pi-root");
    let seat = work.join("claude-b");
    std::fs::create_dir_all(&seat).unwrap();
    let _predecessor = walled_on(&runner, &server, "pi", &spent, &root);
    pi_root_marked(&root);
    let mut fleet = runner.fleet();
    fleet["overseer"]["model"] = json!("pi-claude/claude-fable-5-1");
    runner.write_fleet(&fleet);
    let successor = walled_successor(&runner, "pi:pi-claude/claude-fable-5-1:high", &seat);
    let (intent, launched) = walled_transfer(&runner, &spent, &successor);
    assert_eq!(
        launched["env"]["PI_CODING_AGENT_DIR"],
        root.display().to_string(),
        "a Pi caller's successor keeps its root: {launched} {intent}"
    );
    assert_eq!(
        launched["env"]["CLAUDE_CONFIG_DIR"],
        seat.display().to_string(),
        "{launched}"
    );
}

#[test]
fn a_dead_controller_recovered_by_the_watch_opens_its_successor_on_the_takeover_brief() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let (bin, env) = watch_world(&work);
    runner.tools = Some(bin);
    runner.env.extend(env);
    let pane = server.open_window("overseer", &work, "bash --norc --noprofile");
    let agent_runtime::reading::Reading::Live(fields) = agent_runtime::host::tmux::pane_fields(
        &agent_runtime::host::tmux::server(&server.socket).unwrap(),
        &pane,
    ) else {
        panic!("the overseer's pane reads")
    };
    let ended = Owned::sleep();
    let mut record = overseer_record(ended.pid(), &ended.start(), &server, &work);
    drop(ended);
    record["pane"] = json!(pane);
    record["window"] = json!(fields.pane.window);
    record["server_start"] = json!(server.start);
    record.as_object_mut().unwrap().remove("launch_line");
    let mut fleet = runner.fleet();
    fleet["overseer"] = record;
    runner.write_fleet(&fleet);
    let intent = watched_transfer(&runner);
    assert_eq!(intent["cause"], "dead", "{intent}");
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(
        runner.stub_turns(&work, &work),
        vec![
            "Read .agents/skills/orch/SKILL.md and follow \
             .agents/skills/orch/workflows/oversee-takeover.md with the overseer \
             handoff at tmp/handoffs/OVERSEER-HANDOFF.md"
                .to_owned()
        ],
        "the successor's first turn is the takeover brief"
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["generation"], 4, "{overseer}");
    assert_eq!(overseer["home"], work.display().to_string(), "{overseer}");
    assert_eq!(
        overseer["permission"], "bypass",
        "the settings' posture, where the dead record named none: {overseer}"
    );
}

/// A Copilot home holding the three lane-mail hooks, and on the runner's
/// tools a `kendex` that reads none of them switched off: the harness
/// gate's terms.
fn copilot_gate_passed(runner: &mut Runner, home: &Path) {
    let hooks = home.join("hooks");
    std::fs::create_dir_all(&hooks).unwrap();
    for name in ["lane-mail-check", "lane-mail-compact", "lane-mail-start"] {
        for ext in ["sh", "json"] {
            std::fs::write(hooks.join(format!("{name}.{ext}")), "").unwrap();
        }
    }
    let tools = runner.state_dir().join("gate-tools");
    std::fs::create_dir_all(&tools).unwrap();
    std::os::unix::fs::symlink(
        fixtures().join("kendex-hooks-off/kendex"),
        tools.join("kendex"),
    )
    .unwrap();
    std::fs::write(
        tools.join("hooks-off.json"),
        r#"{"stdout": "{\"switched_off_by\": null}"}"#,
    )
    .unwrap();
    runner.tools = Some(tools);
}

/// A Pi root whose session will not compact and whose pi-hooks carrier
/// sends the context window and wakes on mail, the harness gate's terms.
fn pi_root_marked(root: &Path) {
    let carrier = root.join("packages/@vanillagreen/pi-hooks");
    std::fs::create_dir_all(carrier.join("extensions")).unwrap();
    std::fs::write(
        root.join("settings.json"),
        r#"{"compaction": {"enabled": false}, "packages": ["./packages/@vanillagreen/pi-hooks"]}"#,
    )
    .unwrap();
    std::fs::write(
        carrier.join("package.json"),
        r#"{"version": "1.4.0", "pi": {"extensions": ["./extensions/lane-mail-wake.ts"]}}"#,
    )
    .unwrap();
    std::fs::write(
        carrier.join("extensions/vocab.ts"),
        "export const fields = { context_window: 0 };\n",
    )
    .unwrap();
}

/// The reach a row's watch start names, as the fleet's own reach reads in
/// the runner's world: the mailbox program a row plants, else the quiet
/// stub, over the checkout `work`, and the fleet server.
fn watch_reach(runner: &Runner, work: &Path) -> Vec<String> {
    let program = runner
        .env
        .iter()
        .find(|(name, _)| name == "LANE_MAIL_CLI")
        .map(|(_, value)| std::path::PathBuf::from(value))
        .unwrap_or_else(|| fixtures().join("lane-mail-quiet/lane-mail"));
    vec![
        "--mail-program".to_owned(),
        program.display().to_string(),
        "--mail-root".to_owned(),
        work.display().to_string(),
        "--socket".to_owned(),
        runner.server_socket.display().to_string(),
    ]
}

/// The real `watch run` on the runner's fleet state, its interval one
/// second, until its overseer duty's transfer settles; the watch stopped
/// and the settled intent returned. The watch is held [`Owned`], so a row
/// that fails before the stop kills it before its world is removed.
fn watched_transfer(runner: &Runner) -> Value {
    let work = runner.state_dir();
    let state = work.join(agent_runtime::record::FLEET_FILE_NAME);
    let mut watch = isolated();
    watch
        .args(["--state-dir", &work.display().to_string()])
        .args(["watch", "run", "--file", &state.display().to_string()])
        .args(watch_reach(runner, work))
        .args(["--interval", "1", "--since", "2026-01-01T00:00:00Z"])
        .current_dir(work)
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(work.join("watch.err")).unwrap());
    runner.apply_env(&mut watch);
    let mut watch = Owned(watch.spawn().expect("watch run"));
    let deadline = Instant::now() + SETTLE;
    while runner.fleet()["intents"].as_array().is_none_or(|intents| {
        !intents.iter().any(|i| {
            i["id"]
                .as_str()
                .is_some_and(|id| id.starts_with("request-transfer:"))
        })
    }) {
        if Instant::now() >= deadline {
            let log = runner.run(&["watch", "log", "--fleet"]);
            panic!(
                "the watch asked no transfer: {} {}",
                String::from_utf8_lossy(&log.stdout),
                std::fs::read_to_string(work.join("watch.err")).unwrap_or_default()
            );
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    stop_live_watch(runner, &state);
    let _ = watch.0.wait();
    intent
}

#[test]
fn a_walled_bypass_controllers_watch_walk_crosses_harness_and_its_successor_runs_prepared() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let mut codex = measured_account("xcodex", 5);
    codex["harness"] = json!("codex");
    let (_, bin, env, work) = walk_world(&runner, &[measured_account("eclaude", 99), codex]);
    runner.tools = Some(bin);
    runner.env.extend(env);
    runner.env.push((
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
        "claude:fable:high,codex:gpt-6.1-sol:high".to_owned(),
    ));
    runner.env.push((
        "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
        format!(
            "claude={},codex={}",
            stub("stub-confirm").display(),
            fixtures().join("stub-record/codex").display()
        ),
    ));
    let pane = server.open_stub("overseer", "stub-confirm", &work, &work);
    server.await_composer(&pane);
    let pid = server.pane_pid(&pane);
    let agent_runtime::reading::Reading::Live(fields) = agent_runtime::host::tmux::pane_fields(
        &agent_runtime::host::tmux::server(&server.socket).unwrap(),
        &pane,
    ) else {
        panic!("the overseer's pane reads")
    };
    let rows = work.join("walled.jsonl");
    std::fs::write(
        &rows,
        "{\"harness\":\"claude\",\"event\":\"StopFailure\",\"error\":\"rate_limit\"}\n",
    )
    .unwrap();
    let mut record = overseer_record(pid, &start_of(pid), &server, &work);
    record["pane"] = json!(pane);
    record["window"] = json!(fields.pane.window);
    record["server_start"] = json!(server.start);
    record["account"] = json!(planted(&runner, "eclaude"));
    record["home"] = json!(planted(&runner, "eclaude"));
    record["permission"] = json!("bypass");
    record["session_rows"] = json!(rows);
    let mut fleet = runner.fleet();
    fleet["overseer"] = record;
    runner.write_fleet(&fleet);
    let intent = watched_transfer(&runner);
    assert_eq!(intent["cause"], "walled", "{intent}");
    let launched = launch_record(&work);
    assert_eq!(
        launched["env"]["CODEX_HOME"],
        agent_runtime::trust::home_path(Path::new(&planted(&runner, "xcodex")), &work)
            .display()
            .to_string(),
        "{launched}"
    );
}

#[test]
fn a_controller_started_on_its_own_handoff_is_recovered_dead_onto_a_brief_naming_it() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let work = runner.state_dir().to_path_buf();
    let (bin, env) = watch_world(&work);
    runner.tools = Some(bin);
    runner.env.extend(env);
    let handoff = "tmp/handoffs/FLEET-B.md";
    let brief = format!(
        "Read .agents/skills/orch/SKILL.md and follow .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at {handoff}"
    );
    let mut controller = pending(&work);
    controller["handoff"] = json!(handoff);
    let report = effect_report(
        &runner.op_fleet(&json!({"op": "start-controller", "controller": controller})),
    );
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["handoff"], handoff, "{overseer}");
    assert_eq!(runner.stub_turns(&work, &work), vec![brief.clone()]);
    let pid: u32 = match &overseer["harness_pid"] {
        Value::String(text) => text.parse().unwrap(),
        other => other.as_u64().unwrap() as u32,
    };
    // The harness ends and its pane stands holding a shell alone.
    let respawned = tmux(
        &server.socket,
        &[
            "respawn-pane",
            "-k",
            "-t",
            overseer["pane"].as_str().unwrap(),
            "bash --norc --noprofile",
        ],
    );
    assert!(respawned.status.success(), "{}", stderr(&respawned));
    wait_until("the controller's harness ended", secs(10), || !live(pid));
    let intent = watched_transfer(&runner);
    assert_eq!(intent["cause"], "dead", "{intent}");
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(
        runner.stub_turns(&work, &work),
        vec![brief.clone(), brief],
        "the recovered successor opens on the launch's own handoff"
    );
    assert_eq!(runner.fleet()["overseer"]["handoff"], handoff);
}

#[test]
fn a_succession_by_hand_through_the_verb_keeps_the_predecessors_own_handoff() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (_, bin, env, work) = walk_world(&runner, &[measured_account("bclaude", 5)]);
    runner.tools = Some(bin);
    runner.env.extend(env);
    runner.env.push((
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
        "claude:fable:high".to_owned(),
    ));
    let handoff = "tmp/handoffs/FLEET-B.md";
    let brief = format!(
        "Read .agents/skills/orch/SKILL.md and follow .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at {handoff}"
    );
    let mut controller = pending(&work);
    controller["handoff"] = json!(handoff);
    let report = effect_report(
        &runner.op_fleet(&json!({"op": "start-controller", "controller": controller})),
    );
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let pane = runner.fleet()["overseer"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let out = runner.run(&[
        "successor",
        "--fleet",
        "--cwd",
        &work.display().to_string(),
        "--predecessor",
        &pane,
    ]);
    let answer = reply(&out);
    let result = answer["result"].clone();
    assert_eq!(result["successor"]["handoff"], handoff, "{answer}");
    assert_eq!(result["brief"], brief.as_str(), "{answer}");
    // The posture the successor launches under and the account judge's
    // settings, outside their form, refuse the verb by key and value.
    for (key, value) in [
        ("AGENT_RUNTIME_LAUNCH_PERMISSION", "yes"),
        ("AGENT_RUNTIME_ACCOUNT_MAX_PCT", "101"),
    ] {
        let refused = runner.run_env(
            &[
                "successor",
                "--fleet",
                "--cwd",
                &work.display().to_string(),
                "--predecessor",
                &pane,
            ],
            &[(key, value)],
        );
        let refusal = &reply(&refused)["refusal"];
        assert_eq!(
            refusal["key"],
            "setting-invalid",
            "{key}: {}",
            stderr(&refused)
        );
        assert_eq!(
            refusal["fields"],
            json!([["key", key], ["value", value]]),
            "{key}"
        );
    }
    runner.snapshot(&work.join(handoff));
    runner.transfer_started(&json!({
        "op": "request-transfer",
        "cause": "live",
        "expected": result["expected"],
        "successor": result["successor"],
    }));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["handoff"], handoff, "{overseer}");
    assert_eq!(
        overseer["account"],
        planted(&runner, "bclaude"),
        "{overseer}"
    );
    assert_eq!(
        runner.stub_turns(Path::new(&planted(&runner, "bclaude")), &work),
        vec![brief],
        "the successor opens on the predecessor's own handoff"
    );
}

/// The overseer walk admits a Claude account whose shared windows the
/// provider measured and whose window scoped to the model nothing read,
/// this machine's reading holding none either: the real `successor` verb
/// chooses it, judged on the shared windows, and names `scope: unread` on
/// the successor, which the transfer publishes on the controller record.
/// A lane's pick of the same account stays `unmeasured`.
#[test]
fn an_overseer_walk_admits_an_account_whose_model_window_is_unread_and_records_the_scope() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let account = planted(&runner, "bclaude");
    let mut shared = measured_account("bclaude", 20);
    shared["measured_through"] = json!("host");
    shared["config_dir"] = json!(account);
    let (_, bin, env, work) = walk_world_on(
        &runner,
        Some("vm"),
        &[measured_account("bclaude", 20), shared],
    );
    runner.tools = Some(bin);
    runner.env.extend(env);
    runner.env.push((
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
        "claude:fable:high".to_owned(),
    ));
    let report = effect_report(
        &runner.op_fleet(&json!({"op": "start-controller", "controller": pending(&work)})),
    );
    assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
    let pane = runner.fleet()["overseer"]["pane"]
        .as_str()
        .unwrap()
        .to_owned();
    let answer = reply(&runner.run(&[
        "successor",
        "--fleet",
        "--cwd",
        &work.display().to_string(),
        "--predecessor",
        &pane,
    ]));
    let result = answer["result"].clone();
    assert_eq!(result["walk"]["answer"], "lane", "{answer}");
    assert_eq!(result["successor"]["account"], account, "{answer}");
    assert_eq!(result["successor"]["scope"], "unread", "{answer}");
    let model = result["walk"]["chosen"]["pick_model"]
        .as_str()
        .unwrap_or_default();
    assert!(
        !model.is_empty(),
        "the walk judged a model's window: {answer}"
    );
    let lane = reply(&runner.run(&[
        "lane",
        "pick",
        "--fleet",
        "--harness",
        "claude",
        "--native-model",
        model,
        "--lane",
        &account,
    ]));
    assert_eq!(lane["result"]["answer"], "unmeasured", "{lane}");
    assert_eq!(lane["result"]["exit"], 5, "{lane}");
    runner.snapshot(&work.join("tmp/handoffs/OVERSEER-HANDOFF.md"));
    runner.transfer_started(&json!({
        "op": "request-transfer",
        "cause": "live",
        "expected": result["expected"],
        "successor": result["successor"],
    }));
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["account"], account, "{overseer}");
    assert_eq!(overseer["scope"], "unread", "{overseer}");
}

/// The real `successor` verb's choice of a first controller over `rows`,
/// under the provider `vm`, on a Claude entry then a Codex one: the reply's
/// `result`.
fn first_choice_on_vm(runner: &mut Runner, rows: &[Value]) -> Value {
    let (_, bin, env, work) = walk_world_on(runner, Some("vm"), rows);
    runner.tools = Some(bin);
    runner.env.extend(env);
    runner.env.push((
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
        "claude:fable:high,codex:gpt-6.1-sol:high".to_owned(),
    ));
    let answer =
        reply(&runner.run(&["successor", "--fleet", "--cwd", &work.display().to_string()]));
    assert_eq!(answer["ok"], true, "{answer}");
    answer["result"].clone()
}

/// A measured Codex account at `alias`, `used` percent on its weekly window.
fn measured_codex(alias: &str, used: u64) -> Value {
    let mut row = measured_account(alias, used);
    row["harness"] = json!("codex");
    row
}

/// A controller opens on this machine and signs in with this machine's
/// stored login of its home: a home holding no credential here, which the
/// provider measures with room through its own token, is judged on this
/// machine's row, so the real `successor` verb passes it over as
/// `unmeasured` and opens on the next entry's credentialed home.
#[test]
fn a_controller_is_not_placed_on_a_home_this_machine_cannot_sign_in_to() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let signed_out = planted(&runner, "aclaude");
    let mut local = measured_account("aclaude", 10);
    local["status"] = json!("no_credentials");
    let mut provider = measured_account("aclaude", 10);
    provider["measured_through"] = json!("host");
    provider["config_dir"] = json!(signed_out);
    let result = first_choice_on_vm(
        &mut runner,
        &[local, provider, measured_codex("xcodex", 20)],
    );
    assert_eq!(
        result["successor"]["account"],
        planted(&runner, "xcodex"),
        "{result}"
    );
    let skipped = &result["walk"]["skipped"][0];
    assert_eq!(skipped["entry"], "claude:fable:high", "{result}");
    assert_eq!(skipped["reason"], "unmeasured", "{result}");
    assert_eq!(skipped["lane"], signed_out, "{result}");
}

/// A provider's row naming a home this machine does not list is no
/// candidate for a controller, which would open here with nothing to sign
/// in with: the real `successor` verb passes over the provider-only home
/// with room and opens on the next entry's home.
#[test]
fn a_controller_is_not_placed_on_a_home_only_the_provider_lists() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let mut provider = measured_account("zclaude", 5);
    provider["measured_through"] = json!("host");
    provider["config_dir"] = json!(planted(&runner, "zclaude"));
    let result = first_choice_on_vm(&mut runner, &[provider, measured_codex("xcodex", 20)]);
    assert_eq!(
        result["successor"]["account"],
        planted(&runner, "xcodex"),
        "{result}"
    );
    let skipped = &result["walk"]["skipped"][0];
    assert_eq!(skipped["entry"], "claude:fable:high", "{result}");
    assert_eq!(skipped["reason"], "no-candidate", "{result}");
}

/// A provider's reservation is a fact of the account, read apart from any
/// measurement: an account the provider's row reserves with no reading at
/// all, whose home here measures the most room, is chosen by no walk: the
/// real `successor` verb opens the controller on the other home, and a
/// lane's pick takes the other home too.
#[test]
fn a_reserved_account_reported_with_no_reading_is_chosen_by_no_walk() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let reserved = planted(&runner, "rclaude");
    let mut measured = measured_account("rclaude", 10);
    measured["model_buckets"] =
        json!([{"label": null, "pct": 10, "resets_at": measured["binding_resets_at"]}]);
    let result = first_choice_on_vm(
        &mut runner,
        &[
            measured,
            json!({"harness": "claude", "config_dir": reserved, "measured_through": "host", "reserved": 1}),
            measured_account("bclaude", 40),
        ],
    );
    let other = planted(&runner, "bclaude");
    assert_eq!(result["successor"]["account"], other, "{result}");
    let lane = reply(&runner.run(&["lane", "pick", "--fleet", "--harness", "claude"]));
    assert_eq!(lane["result"]["answer"], "lane", "{lane}");
    assert_eq!(lane["result"]["record"]["config_dir"], other, "{lane}");
}

/// A provider's reservation reaches every overseer's choice, on an entry
/// whose figures the provider does not judge too: a Codex account the
/// provider reserves, whose home here measures the most room, is passed
/// over by the real `successor` verb for the other Codex home.
#[test]
fn a_providers_reservation_keeps_an_account_from_an_overseer_whose_figures_it_does_not_judge() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let reserved = planted(&runner, "rcodex");
    let result = first_choice_on_vm(
        &mut runner,
        &[
            measured_codex("rcodex", 10),
            json!({"harness": "codex", "config_dir": reserved, "measured_through": "host", "reserved": 1}),
            measured_codex("bcodex", 40),
        ],
    );
    assert_eq!(
        result["successor"]["account"],
        planted(&runner, "bcodex"),
        "{result}"
    );
}

/// An overseer's every entry spends an account the provider `vm` bills, so
/// a provider nobody can read leaves no entry to judge: the real
/// `successor` verb refuses `account-unjudged` naming the host and the
/// cause, whether the capability line or the `accounts` answer went
/// unread, the provider's slot refusal told apart by its cause, and judges
/// no entry on this machine's homes, which have room; the provider is asked
/// once for the walk.
#[test]
fn an_overseers_walk_under_an_unread_provider_refuses_naming_the_host_and_the_cause() {
    for (key, exit, calls, cause) in [
        (
            "vm accounts",
            69,
            &[
                "ORCH_LANE_HOST=vm capabilities",
                "ORCH_LANE_HOST=vm accounts",
            ][..],
            "lane-host-busy step=accounts ",
        ),
        (
            "vm capabilities",
            1,
            &["ORCH_LANE_HOST=vm capabilities"][..],
            "host-capabilities-unread host=vm cause=exit=1 ",
        ),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        runner.init_fleet();
        let (_, bin, env, work) = walk_world_on(
            &runner,
            Some("vm"),
            &[
                measured_account("aclaude", 10),
                measured_codex("xcodex", 20),
            ],
        );
        let planted = runner.state_dir().join("accounts");
        let answers = planted.join("lane-host.json");
        let mut map: Value = serde_json::from_slice(&std::fs::read(&answers).unwrap()).unwrap();
        map[key] = json!({"exit": exit, "stderr": "lane-host-fixture: refused\n"});
        std::fs::write(&answers, map.to_string()).unwrap();
        runner.tools = Some(bin);
        runner.env.extend(env);
        runner.env.push((
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
            "claude:fable:high,codex:gpt-6.1-sol:high".to_owned(),
        ));
        let out = runner.run(&["successor", "--fleet", "--cwd", &work.display().to_string()]);
        let answer = reply(&out);
        assert_eq!(answer["ok"], false, "{key}: {answer}");
        assert_eq!(
            answer["refusal"]["key"], "account-unjudged",
            "{key}: {answer}"
        );
        let fields = answer["refusal"]["fields"].as_array().unwrap();
        assert_eq!(fields.len(), 3, "{key}: one host and its cause: {answer}");
        assert_eq!(
            (&fields[0], &fields[1], &fields[2][0]),
            (
                &json!(["step", "host"]),
                &json!(["host", "vm"]),
                &json!("cause")
            ),
            "{key}: {answer}"
        );
        assert!(
            fields[2][1].as_str().unwrap().starts_with(cause),
            "{key}: {answer}"
        );
        let log: Vec<String> = std::fs::read_to_string(planted.join("lane-host.log"))
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect();
        assert_eq!(log, calls, "{key}");
    }
}

/// A provider line that answers with no `files=` is an unread line: the
/// real `successor` verb refuses `account-unjudged` naming the host and the
/// cause for an overseer's Claude entry and its Codex entry alike, its
/// `accounts` answer and this machine's homes, which have room, never
/// judging either, whichever entry the preference names first; the line
/// is asked once for the walk.
#[test]
fn an_overseers_walk_under_an_unparsed_line_refuses_naming_the_host_and_the_cause() {
    for preference in [
        "claude:fable:high,codex:gpt-6.1-sol:high",
        "codex:gpt-6.1-sol:high,claude:fable:high",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        runner.init_fleet();
        let (_, bin, env, work) = walk_world_on(
            &runner,
            Some("vm"),
            &[
                measured_account("aclaude", 10),
                measured_codex("xcodex", 20),
            ],
        );
        let planted = runner.state_dir().join("accounts");
        let answers = planted.join("lane-host.json");
        let mut map: Value = serde_json::from_slice(&std::fs::read(&answers).unwrap()).unwrap();
        map["vm capabilities"] = json!({
            "stdout": "kind=ssh\tlaunch=ssh\tchannel=mailbox\tstatus=verb\tstop=verb\tpool=plan\n"
        });
        std::fs::write(&answers, map.to_string()).unwrap();
        runner.tools = Some(bin);
        runner.env.extend(env);
        runner.env.push((
            "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
            preference.to_owned(),
        ));
        let out = runner.run(&["successor", "--fleet", "--cwd", &work.display().to_string()]);
        let answer = reply(&out);
        assert_eq!(answer["ok"], false, "{preference}: {answer}");
        assert_eq!(
            answer["refusal"]["fields"],
            json!([
                ["step", "host"],
                ["host", "vm"],
                [
                    "cause",
                    "host-capabilities-unread host=vm cause=capability-invalid key=files value=missing"
                ]
            ]),
            "{preference}: {answer}"
        );
        assert_eq!(answer["refusal"]["key"], "account-unjudged", "{answer}");
        let log = std::fs::read_to_string(planted.join("lane-host.log")).unwrap();
        assert_eq!(log, "ORCH_LANE_HOST=vm capabilities\n", "{preference}");
    }
}

/// An overseer's entry spending no account the judge measures is chosen
/// before any provider is asked for it: under a provider nobody can read,
/// the Pi entry billed to the API before it is passed over with the host
/// and the cause, and the unbilled Pi entry is the walk's choice.
#[test]
fn an_overseers_unbilled_entry_is_chosen_past_an_unread_provider() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.init_fleet();
    let (_, bin, env, work) = walk_world_on(&runner, Some("vm"), &[]);
    let planted = runner.state_dir().join("accounts");
    let answers = planted.join("lane-host.json");
    let mut map: Value = serde_json::from_slice(&std::fs::read(&answers).unwrap()).unwrap();
    map["vm capabilities"] = json!({"exit": 1, "stderr": "lane-host-fixture: refused\n"});
    std::fs::write(&answers, map.to_string()).unwrap();
    runner.tools = Some(bin);
    runner.env.extend(env);
    let root = work.join("custom-pi-root");
    pi_root_marked(&root);
    runner.env.push((
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
        "pi:anthropic/claude-fable-5-1:high,pi:openrouter/anthropic/claude-fable-5-1:high"
            .to_owned(),
    ));
    let _predecessor = walled_on(&runner, &server, "pi", &work.join("unused"), &root);
    let mut fleet = runner.fleet();
    fleet["overseer"]["model"] = json!("openrouter/anthropic/claude-fable-5-1");
    fleet["overseer"].as_object_mut().unwrap().remove("account");
    runner.write_fleet(&fleet);
    let pane = fleet["overseer"]["pane"].as_str().unwrap().to_owned();
    let out = runner.run(&[
        "successor",
        "--fleet",
        "--cwd",
        &work.display().to_string(),
        "--predecessor",
        &pane,
    ]);
    let answer = reply(&out);
    let walk = &answer["result"]["walk"];
    assert_eq!(
        walk["chosen"]["entry"], "pi:openrouter/anthropic/claude-fable-5-1:high",
        "{answer}"
    );
    let skipped = walk["skipped"].as_array().unwrap();
    assert_eq!(skipped.len(), 1, "{answer}");
    assert_eq!(
        (
            &skipped[0]["entry"],
            &skipped[0]["reason"],
            &skipped[0]["host"]
        ),
        (
            &json!("pi:anthropic/claude-fable-5-1:high"),
            &json!("host-unread"),
            &json!("vm")
        ),
        "{answer}"
    );
    assert!(
        skipped[0]["cause"]
            .as_str()
            .unwrap()
            .starts_with("host-capabilities-unread host=vm cause=exit=1 "),
        "{answer}"
    );
    let log = std::fs::read_to_string(planted.join("lane-host.log")).unwrap();
    assert_eq!(log, "ORCH_LANE_HOST=vm capabilities\n");
}

#[test]
fn an_accountless_pi_successor_runs_on_the_pi_root_its_predecessor_kept() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let mut runner = suite_runner(&server, "stub-confirm");
    runner.verify = Some(1);
    runner.init_fleet();
    let (_, bin, env, _) = walk_world(&runner, &[]);
    runner.tools = Some(bin);
    runner.env.extend(env);
    let work = runner.state_dir().to_path_buf();
    let root = work.join("custom-pi-root");
    let home = work.join("operator-home");
    pi_root_marked(&root);
    pi_root_marked(&home.join(".pi/agent"));
    runner
        .env
        .push(("HOME".to_owned(), home.display().to_string()));
    runner.env.push((
        "AGENT_RUNTIME_CONTROLLER_PREFERENCE".to_owned(),
        "pi:openrouter/anthropic/claude-fable-5-1:high".to_owned(),
    ));
    let predecessor = walled_on(&runner, &server, "pi", &work.join("unused"), &root);
    let mut fleet = runner.fleet();
    fleet["overseer"]["model"] = json!("openrouter/anthropic/claude-fable-5-1");
    fleet["overseer"].as_object_mut().unwrap().remove("account");
    runner.write_fleet(&fleet);
    let pane = fleet["overseer"]["pane"].as_str().unwrap().to_owned();
    let answer = reply(&runner.run(&[
        "successor",
        "--fleet",
        "--cwd",
        &work.display().to_string(),
        "--predecessor",
        &pane,
    ]));
    let result = &answer["result"];
    assert_eq!(result["walk"]["answer"], "lane", "{answer}");
    assert!(result["successor"]["account"].is_null(), "{answer}");
    runner.transfer_started_env(
        &json!({
            "op": "request-transfer",
            "cause": "live",
            "expected": result["expected"],
            "successor": result["successor"],
        }),
        &[(
            "AGENT_RUNTIME_HARNESS_BINARIES",
            &format!("pi={}", fixtures().join("stub-record/pi").display()),
        )],
    );
    let intent = runner.wait_intent_settled("request-transfer:", SETTLE);
    assert!(live(predecessor.pid()), "{intent}");
    let launched = launch_record(&work);
    assert_eq!(
        launched["env"]["PI_CODING_AGENT_DIR"],
        root.display().to_string(),
        "{launched} {intent}"
    );
}

#[test]
fn a_reconcile_of_an_opened_successor_writes_no_trust_record_and_asks_no_gate() {
    for harness in ["claude", "copilot"] {
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "fleet");
        let mut runner = suite_runner(&server, "stub-confirm");
        runner.verify = Some(1);
        runner.init_fleet();
        let home = dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        runner
            .env
            .push(("HOME".to_owned(), home.display().to_string()));
        let account = dir.path().join("account");
        std::fs::create_dir_all(&account).unwrap();
        if harness == "copilot" {
            copilot_gate_passed(&mut runner, &account);
            runner.env.push((
                "AGENT_RUNTIME_HARNESS_BINARIES".to_owned(),
                format!("copilot={}", stub("stub-confirm").display()),
            ));
        }
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
        // The home the runner's launch recorded, where its sessions are.
        ph["home"] = json!(runner.state_dir().display().to_string());
        let mut fleet = runner.fleet();
        fleet["overseer"] =
            overseer_record(GONE_PID as u32, "ticks:1", &server, runner.state_dir());
        fleet["overseer"]["pane"] = json!(idle);
        fleet["overseer"]["server_start"] = json!(server.start);
        let mut successor = pending(runner.state_dir());
        successor["harness"] = json!(harness);
        successor["account"] = json!(account.display().to_string());
        successor.as_object_mut().unwrap().remove("home");
        fleet["overseer"]["pending"] = successor;
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
        let report = runner.reconcile_one();
        let written: Vec<String> = [".claude.json", "settings.json", "extensions"]
            .iter()
            .filter(|name| account.join(name).exists())
            .map(|name| (*name).to_owned())
            .collect();
        assert_eq!(written, Vec::<String>::new(), "{harness}: {report}");
        let asked = runner.state_dir().join("gate-tools/kendex.log").exists();
        assert!(!asked, "{harness}: {report}");
        if harness == "claude" {
            assert_eq!(report["intent"]["outcome"], "confirmed", "{report}");
            assert_eq!(
                runner.fleet()["overseer"]["home"],
                runner.state_dir().display().to_string(),
                "the published home is the one the launch recorded"
            );
        }
    }
}

#[test]
fn a_marks_succession_leaves_the_account_a_rate_mark_spends_and_keeps_one_a_context_mark_can_keep()
{
    // The case, the accounts, the preference set (none: unset), the context
    // reading the marks judge and the account the successor spends.
    type Case<'a> = (&'a str, Vec<Value>, Option<&'a str>, &'a str, &'a str);
    let mut fast = measured_account("eclaude", 40);
    fast["usage_rate_pct_per_min"] = json!(2.0);
    let mut unread = measured_account("eclaude", 10);
    unread["status"] = json!("unreachable");
    unread["headroom_pct"] = Value::Null;
    unread["wall"] = Value::Null;
    let mut codex = measured_account("ccodex", 20);
    codex["harness"] = json!("codex");
    let mut burning = measured_account("eclaude", 40);
    burning["usage_rate_pct_per_min"] = json!(2.0);
    let cases: [Case; 6] = [
        (
            "rate",
            vec![fast.clone(), measured_account("bclaude", 70)],
            Some("claude:opus:high"),
            "100000:1000000",
            "bclaude",
        ),
        (
            "rate, empty preference",
            vec![fast, measured_account("bclaude", 70)],
            Some(""),
            "100000:1000000",
            "bclaude",
        ),
        (
            "context, unmeasured caller",
            vec![unread, measured_account("bclaude", 99)],
            Some("claude:opus:high"),
            "950000:1000000",
            "eclaude",
        ),
        (
            "context, caller with room",
            vec![
                measured_account("eclaude", 50),
                measured_account("bclaude", 10),
            ],
            None,
            "950000:1000000",
            "eclaude",
        ),
        (
            "context, caller at its trigger",
            vec![measured_account("eclaude", 97), codex],
            None,
            "950000:1000000",
            "ccodex",
        ),
        (
            "context, caller's rate mark due too",
            vec![burning, measured_account("bclaude", 70)],
            None,
            "950000:1000000",
            "bclaude",
        ),
    ];
    for (case, rows, preference, context, account) in cases {
        let mut world = MarksWorld::new();
        world.plant(None, &rows);
        world.write_fleet(&world.dir("eclaude"));
        let mut extra = vec![("ORCH_OVERSEER_WALL_MINUTES", "30")];
        if let Some(preference) = preference {
            extra.push(("AGENT_RUNTIME_CONTROLLER_PREFERENCE", preference));
        }
        let reached = world.marks(&["--context", context], &extra);
        let kind = reached["kind"].as_str().unwrap_or_default().to_owned();
        let cwd = world.path().display().to_string();
        let out = world.run(
            &[
                "successor",
                "--fleet",
                "--cwd",
                &cwd,
                "--predecessor",
                "%1",
                "--mark",
                &kind,
            ],
            &extra,
        );
        let answer = reply(&out);
        assert_eq!(
            answer["result"]["successor"]["account"],
            json!(world.dir(account)),
            "{case}: {reached} {answer} {}",
            stderr(&out)
        );
    }
}

/// The launch starts with no fleet state, which its first step makes, and
/// names the caller's permission words as the controller's `extra_args`:
/// they reach the harness's argv and the record's line alike, and neither
/// carries a bypass word.
#[test]
fn a_first_launch_under_the_native_posture_opens_with_no_bypass_word_in_its_argv() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = suite_runner(&server, "stub-confirm");
    // The state directory is its own checkout root, so the runtime reads no
    // settings file of the repository these tests run under.
    let git = program("git")
        .args([
            "-C",
            &runner.state_dir().display().to_string(),
            "init",
            "-q",
        ])
        .output()
        .unwrap();
    assert!(git.status.success(), "git init: {}", stderr(&git));
    let (scripts, bin, env, work) = walk_world(&runner, &[measured_account("aclaude", 5)]);
    let opened = workflow_launch(
        &runner,
        &scripts,
        &bin,
        &env,
        &work,
        "claude",
        "fable",
        &stub("stub-record"),
    )
    .env("AGENT_RUNTIME_LAUNCH_PERMISSION", "native")
    .words(&["--permission-mode", "dontAsk"])
    .run();
    let state = runner
        .state_dir()
        .join(agent_runtime::record::FLEET_FILE_NAME);
    let started = opened.started();
    if started["outcome"] == "confirmed" {
        stop_live_watch(&runner, &state);
    }
    assert_eq!(
        started["outcome"],
        "confirmed",
        "{started}\n{}",
        stderr(opened.op())
    );
    let overseer = runner.fleet()["overseer"].clone();
    assert_eq!(overseer["permission"], "native", "{overseer}");
    let argv = argv_of(&launch_record(&work));
    assert!(
        argv.windows(2)
            .any(|w| w == ["--permission-mode", "dontAsk"]),
        "the caller's permission words reach the launch: {argv:?}"
    );
    assert!(
        !argv.iter().any(|a| a == "--dangerously-skip-permissions"),
        "no bypass word under the native posture: {argv:?}"
    );
    assert_eq!(
        overseer["extra_args"],
        json!(["--permission-mode", "dontAsk"]),
        "the caller's permission words stand on the record: {overseer}"
    );
}
