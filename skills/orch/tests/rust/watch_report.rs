//! The verification, report, heartbeat-body and retention duties: the
//! `verifying` lines and `verifying-deadline` events on the recorded watch's
//! own fixtures, recorded once; a deadline
//! row that moves only after its event line is durable; `report-due` once
//! per due with its reason and `report-unjudged` on a bad answer; both
//! duties indifferent to the controller's state; the heartbeat's body under
//! busy mail, carrying the capacity line and moving no due time, and saying
//! `unread` for every list no duty has read; and retention judging each
//! record by its own recorded end and its own session's close, writing
//! nothing over a fresh fleet record, removing only the kinds it names and
//! compacting the overseer mailbox.
//!
//! Most rows call a duty's body on a hand-built tick and apply what it
//! produced to the baseline themselves, as the runner's `commit` does; the
//! rows that need the runner's threads drive it on the fake clock. Every
//! program a duty runs is a fixture symlinked into the row's world, named
//! to the duty through the settings or its context.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the fixtures and records they plant and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use agent_runtime::record::{FLEET_FILE_NAME, Locking};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::clock::Clock;
use agent_runtime::clock::SystemClock;
use agent_runtime::journal::Env;
use agent_runtime::process::Identity;
use agent_runtime::record::Wait;
use agent_runtime::settings::Roots;
use orch_runtime::error::Error;
use orch_runtime::ops::prune::{PlannedRows, PruneRecords, RecordsPruned, prune_records};
use orch_runtime::schedule::Duty;
use orch_runtime::settings::{self, Flags as SettingsFlags, Settings};
use orch_runtime::state::{self, InitFields};
use orch_runtime::watch::github;
use orch_runtime::watch::heartbeat;
use orch_runtime::watch::pr_watch;
use orch_runtime::watch::report;
use orch_runtime::watch::retention::{self, Judgement};
use orch_runtime::watch::tracker::{
    OwedItem, OwedState, Quota, QuotaLimit, QuotaStatus, Shared, TrackerInventory, VerifyingItem,
};
use orch_runtime::watch::verifying::{self, Lines};
use orch_runtime::watch::wake;
use orch_runtime::watch::{self, Baseline, Event, Flags, Paths, Produced, Recorded, Runner, Tick};
use serde_json::{Value, json};
use support::*;

fn epoch(stamp: &str) -> u64 {
    clock::epoch_secs(stamp).unwrap_or_else(|| panic!("{stamp}"))
}

/// The recorded answers these duties keep byte for byte.
fn recorded_lines(name: &str) -> Vec<String> {
    lines(&fixtures().join("released-recorded").join(name))
}

fn lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The Done-when text the recorded owed world gives its two Verifying items.
const DEADLINE_BOXES: &str = "## Done when\n- [x] branch proof\n- [ ] Post-merge: Read deployed health; Where: live service; Why after merge: needs deployment; Deadline: 2026-10-02T00:00:00Z\n- [ ] Post-merge: Read consumer refresh; Where: consumer PR; Why after merge: needs rollout; Deadline: 2026-10-03T00:00:00Z";

/// The real mailbox program behind a wrapper under `dir`, run with a
/// cleared environment and no git configuration. The compaction starts it
/// in `dir`, so its ceiling is `dir`'s parent: no checkout above `dir` is
/// the project root whose private files its `orch-env` would load.
fn real_mail(dir: &Path) -> PathBuf {
    let path = dir.join("real-lane-mail");
    let actual = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts/lane-mail")
        .canonicalize()
        .unwrap();
    let text = format!(
        "#!/bin/sh\nexec env -i HOME='{}' PATH='{}' LANG=C.UTF-8 TMPDIR='{}' GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES='{}' '{}' \"$@\"\n",
        dir.display(),
        tool_path(&[]),
        std::env::temp_dir().display(),
        ceilings(dir.parent().unwrap()).to_string_lossy(),
        actual.display()
    );
    write_executable(&path, text);
    path
}

/// One world: a state directory with the fleet record, the fixtures
/// symlinked under the names the duties run, and the settings naming them.
struct World {
    dir: tempfile::TempDir,
    settings: Settings,
    /// The caller's environment the settings were loaded under.
    env: Vec<(String, String)>,
}

impl World {
    fn new() -> World {
        World::new_in(&std::env::temp_dir())
    }

    /// A world whose folder is made under `parent`.
    fn new_in(parent: &Path) -> World {
        let dir = tempfile::tempdir_in(parent).unwrap();
        let fix = fixtures();
        for (name, fixture) in [
            ("linear", "linear-fixture/linear.sh"),
            ("gh", "gh/gh"),
            ("lane-host", "lane-host/lane-host"),
            ("oversee-report", "oversee-report-fixture/oversee-report"),
            ("github.sh", "github-fixture/github.sh"),
        ] {
            std::os::unix::fs::symlink(fix.join(fixture), dir.path().join(name)).unwrap();
        }
        install_lane_host(dir.path(), dir.path());
        let mail = real_mail(dir.path());
        let at = |name: &str| dir.path().join(name).display().to_string();
        // The accounts the listing lists are planted under `home` with
        // their records, served for a day of the fake clock; no usage
        // endpoint is ever reached, and a request that slipped past the
        // records would open no socket.
        let env: Vec<(String, String)> = [
            ("ORCH_WATCH_MAIL_INTERVAL", "5".to_owned()),
            ("FLEET_DIR", at("fleet")),
            ("OVERSEE_WATCH_TRACKER", at("linear")),
            ("OVERSEE_WATCH_REPORT", at("oversee-report")),
            ("LANE_MAIL_CLI", mail.display().to_string()),
            ("HOME", at("home")),
            ("OVERSEE_WATCH_STATE_DIR", at("")),
            ("AGENT_RUNTIME_ACCOUNT_STATE_DIR", at("")),
            ("AGENT_RUNTIME_USAGE_TTL", "86400".to_owned()),
            (
                "AGENT_RUNTIME_CLAUDE_USAGE_URL",
                "file:///nonexistent/usage".to_owned(),
            ),
            (
                "AGENT_RUNTIME_CODEX_USAGE_URL",
                "file:///nonexistent/usage".to_owned(),
            ),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v))
        .collect();
        let settings = World::load(dir.path(), &env, &[]);
        let world = World { dir, settings, env };
        world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": [], "fleet_log": []}));
        world
    }

    fn load(dir: &Path, env: &[(String, String)], extra: &[(String, String)]) -> Settings {
        let roots = Roots {
            project: dir.to_path_buf(),
            common: dir.to_path_buf(),
        };
        let environment: Vec<(std::ffi::OsString, std::ffi::OsString)> = env
            .iter()
            .chain(extra.iter())
            .map(|(k, v)| match k.as_str() {
                "ORCH_LANE_HOST" => (k.into(), named_host(dir, v).into()),
                _ => (k.into(), v.into()),
            })
            .collect();
        settings::load(
            &roots,
            &environment,
            &SettingsFlags {
                state_dir: Some(dir.to_path_buf()),
                private_env: false,
            },
        )
        .unwrap()
    }

    /// The settings under the world's environment with `extra` over it:
    /// the directories a pass plants, which discovery cannot name.
    fn settings_with(&self, extra: &[(String, String)]) -> Settings {
        World::load(self.path(), &self.env, extra)
    }

    /// The accounts a pass lists, planted as the listing reads them at
    /// `now`; the environment naming them, less the provider, which the
    /// owed record names for its own read.
    fn plant_accounts(
        &self,
        host: Option<&str>,
        rows: &[Value],
        now: u64,
    ) -> Vec<(String, String)> {
        plant_accounts(self.path(), self.path(), host, rows, now)
            .into_iter()
            .filter(|(k, _)| k != "ORCH_LANE_HOST")
            .collect()
    }

    /// The directory a planted local account `/home/u/.<alias>` stands at.
    fn home_dir(&self, alias: &str) -> String {
        self.path()
            .join("home")
            .join(format!(".{alias}"))
            .display()
            .to_string()
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn fleet_path(&self) -> PathBuf {
        self.path().join(FLEET_FILE_NAME)
    }

    fn paths(&self) -> Paths {
        Paths::of(&self.fleet_path()).unwrap()
    }

    fn pass(&self, now: u64) -> Result<retention::Pruned, Error> {
        retention::pass(
            &self.fleet_path(),
            &self.paths(),
            &self.settings,
            Locking::FLOCK,
            now,
        )
    }

    fn write_fleet(&self, value: &Value) {
        std::fs::write(
            self.fleet_path(),
            serde_json::to_string_pretty(value).unwrap(),
        )
        .unwrap();
    }

    fn fleet(&self) -> Value {
        serde_json::from_str(&std::fs::read_to_string(self.fleet_path()).unwrap()).unwrap()
    }

    /// A fixture's reply file beside its name.
    fn plant(&self, name: &str, value: &Value) {
        std::fs::write(
            self.path().join(name),
            serde_json::to_string(value).unwrap(),
        )
        .unwrap();
    }

    fn verifying_context(&self, shared: Shared, lines: Lines) -> verifying::Context {
        verifying::Context {
            settings: self.settings.clone(),
            gh: self.path().join("gh"),
            shared,
            lines,
        }
    }

    fn real_report_github(&self) -> PathBuf {
        let path = self.path().join("real-github");
        let actual = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../github/scripts/github.sh")
            .canonicalize()
            .unwrap();
        let text = format!(
            "#!/bin/sh\ncd '{}' || exit 1\nexec env -i HOME='{}' PATH='{}' LANG=C.UTF-8 TMPDIR='{}' GH_TOKEN=fixture GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null '{}' \"$@\"\n",
            self.path().display(),
            self.path().display(),
            tool_path(&[self.path()]),
            std::env::temp_dir().display(),
            actual.display()
        );
        write_executable(&path, text);
        path
    }

    fn real_report_mail(&self) -> PathBuf {
        real_mail(self.path())
    }

    fn report_context(&self) -> report::Context {
        if !self.path().join(".git").exists() {
            for args in [
                vec!["init", "--quiet"],
                vec!["config", "gc.auto", "0"],
                vec!["config", "maintenance.auto", "false"],
            ] {
                let out = program("git")
                    .arg("-C")
                    .arg(self.path())
                    .args(args)
                    .output()
                    .unwrap();
                assert!(
                    out.status.success(),
                    "{}",
                    String::from_utf8_lossy(&out.stderr)
                );
            }
        }
        let mut settings = self.settings.clone();
        settings.lane_mail_cli = self.real_report_mail();
        report::Context {
            fleet: self.fleet_path(),
            settings,
            github: self.real_report_github(),
            gh: self.path().join("gh"),
            repos: vec!["owner/repo".to_owned()],
            shared: Default::default(),
        }
    }
}

fn verifying_item(id: &str, priority: &str, description: &str, container: bool) -> VerifyingItem {
    VerifyingItem {
        id: id.to_owned(),
        created_at: "2026-09-20T00:00:00Z".to_owned(),
        description: description.to_owned(),
        priority: priority.to_owned(),
        container,
        blocked_by_open: Vec::new(),
    }
}

/// The slot as the tracker duty leaves it after a pass that read `items`
/// as Verifying.
fn shared_with(items: Vec<VerifyingItem>) -> Shared {
    let shared = Shared::default();
    shared.lock().unwrap().tracker = Some(TrackerInventory {
        read_at: 0,
        owed: Vec::new(),
        verifying: items,
        open_unblocked: Vec::new(),
    });
    shared
}

/// Run `body` once on `baseline` at fake epoch `wall`, apply what it
/// produced as the runner's commit would, and hand back the produced.
fn pass(
    duty: Duty,
    body: &mut watch::Body,
    baseline: &mut Baseline,
    clock: &FakeClock,
    wall: u64,
) -> Result<Produced, Error> {
    let tick = Tick {
        duty,
        now: clock.now(),
        wall,
        baseline: &baseline.clone(),
        clock,
    };
    let produced = body(&tick)?;
    for change in produced.changes.clone() {
        baseline.apply(change);
    }
    Ok(produced)
}

fn rendered(produced: &Produced) -> Vec<String> {
    produced.events.iter().map(Event::render).collect()
}

fn me() -> Identity {
    let pid = std::process::id();
    Identity {
        pid,
        start: start_of(pid),
    }
}

fn runner<'a>(world: &World, clock: &'a FakeClock) -> Runner<'a> {
    Runner::new(
        world.paths(),
        clock,
        &world.settings,
        Flags {
            interval: secs(240),
            max_loops: 25,
            since: None,
            replace: None,
        },
        me(),
        Recorded {
            pane: "none".into(),
            script: "/w/orch-runtime".into(),
            cwd: "/w".into(),
        },
    )
    .unwrap()
}

/// The recorded answers on the owed suite's own worlds, recorded once: the
/// deadline world's four events and four lines, then nothing on the second
/// pass with the lines held for the heartbeat; the unfired trigger's four
/// waiting lines and no event; the Triage container's outcome box, then
/// `boxes=0` once its only box is the child's.
#[test]
fn the_verifying_lines_and_deadline_events_match_the_recorded_bytes() {
    let clock = FakeClock::new();
    let now = epoch("2026-10-02T00:00:01Z");
    // The deadline world: two Verifying items, two post-merge boxes each.
    let world = World::new();
    let lines = Lines::default();
    let shared = shared_with(vec![
        verifying_item("KEN-4", "2", DEADLINE_BOXES, false),
        verifying_item("KEN-1", "1", DEADLINE_BOXES, false),
    ]);
    let mut body = verifying::body(world.verifying_context(shared, lines.clone()));
    let mut baseline = Baseline::default();
    let produced = pass(Duty::Verification, &mut body, &mut baseline, &clock, now).unwrap();
    let mut want = recorded_lines("verifying-deadline.events");
    want.extend(recorded_lines("verifying-deadline.lines"));
    assert_eq!(rendered(&produced), want, "the event block");
    assert_eq!(
        *lines.lock().unwrap(),
        recorded_lines("verifying-deadline.lines"),
        "the heartbeat's lines"
    );
    assert_eq!(
        baseline.get("verifying-deadline", "KEN-1"),
        Some(
            "box=2 trigger=\"merge\" status=overdue deadline=2026-10-02T00:00:00Z|box=3 trigger=\"merge\" status=due deadline=2026-10-03T00:00:00Z"
        )
    );
    let again = pass(
        Duty::Verification,
        &mut body,
        &mut baseline,
        &clock,
        now + 240,
    )
    .unwrap();
    assert_eq!(
        rendered(&again),
        Vec::<String>::new(),
        "a standing deadline emits once"
    );
    assert_eq!(
        *lines.lock().unwrap(),
        recorded_lines("verifying-deadline.lines")
    );
    // No GitHub read: a fixed deadline needs no merge.
    assert!(
        !world.path().join("gh.log").try_exists().unwrap(),
        "no gh call"
    );

    // The unfired time trigger, one second ahead of now.
    let world = World::new();
    let future =
        DEADLINE_BOXES.replace("; Deadline:", "; Trigger: 2026-10-01T12:00:00Z; Deadline:");
    let lines = Lines::default();
    let shared = shared_with(vec![
        verifying_item("KEN-1", "1", &future, false),
        verifying_item("KEN-4", "2", &future, false),
    ]);
    let mut body = verifying::body(world.verifying_context(shared, lines.clone()));
    let mut baseline = Baseline::default();
    let produced = pass(
        Duty::Verification,
        &mut body,
        &mut baseline,
        &clock,
        epoch("2026-10-01T11:59:59Z"),
    )
    .unwrap();
    assert_eq!(
        rendered(&produced),
        Vec::<String>::new(),
        "an unfired trigger raises no event"
    );
    assert_eq!(
        *lines.lock().unwrap(),
        recorded_lines("verifying-future.lines")
    );
    assert_eq!(
        baseline.get("verifying-deadline", "KEN-1"),
        Some("-"),
        "a valid read with nothing due"
    );

    // The Triage container whose children ended: an outcome box beside the
    // child box, then the child box alone.
    let world = World::new();
    let lines = Lines::default();
    let shared = shared_with(vec![verifying_item(
        "KEN-P",
        "-",
        "## Done when\n- [ ] Read shared outcome at source",
        true,
    )]);
    let mut body = verifying::body(world.verifying_context(shared.clone(), lines.clone()));
    let mut baseline = Baseline::default();
    let produced = pass(Duty::Verification, &mut body, &mut baseline, &clock, now).unwrap();
    let mut want = recorded_lines("verifying-container.events");
    want.extend(recorded_lines("verifying-container.lines"));
    assert_eq!(rendered(&produced), want);
    shared.lock().unwrap().tracker.as_mut().unwrap().verifying = vec![verifying_item(
        "KEN-P",
        "-",
        "## Done when\n- [ ] Every child Done or cancelled",
        true,
    )];
    let produced = pass(
        Duty::Verification,
        &mut body,
        &mut baseline,
        &clock,
        now + 240,
    )
    .unwrap();
    let mut want = recorded_lines("verifying-container-closed.events");
    want.extend(recorded_lines("verifying-container-closed.lines"));
    assert_eq!(rendered(&produced), want);
    assert_eq!(baseline.get("verifying-deadline", "KEN-P"), Some("boxes=0"));
    assert_eq!(
        *lines.lock().unwrap(),
        recorded_lines("verifying-container-closed.lines")
    );
    // An item no longer Verifying loses its row.
    shared.lock().unwrap().tracker.as_mut().unwrap().verifying = Vec::new();
    pass(
        Duty::Verification,
        &mut body,
        &mut baseline,
        &clock,
        now + 480,
    )
    .unwrap();
    assert_eq!(baseline.get("verifying-deadline", "KEN-P"), None);
}

/// A deadline row that moved before its event line were durable would lose
/// the deadline to a crash between the two. Through the runner with the
/// baseline's write blocked: the eight lines of the deadline world are on
/// disk and no row moved; the next run reprints them once and lands the
/// row; the run after prints nothing.
#[test]
fn a_deadline_row_moves_only_after_its_event_line_is_durable() {
    let world = World::new();
    let paths = world.paths();
    let clock = FakeClock::new();
    let now = epoch("2026-10-02T00:00:01Z");
    let real_wall = clock.wall_secs();
    assert!(
        real_wall < now,
        "the fake wall precedes the world's deadlines"
    );
    let shared = shared_with(vec![
        verifying_item("KEN-1", "1", DEADLINE_BOXES, false),
        verifying_item("KEN-4", "2", DEADLINE_BOXES, false),
    ]);
    let body = |lines: Lines| verifying::body(world.verifying_context(shared.clone(), lines));
    let mut block = recorded_lines("verifying-deadline.events");
    // Both boxes are due (not overdue) at the fake wall, which precedes
    // their deadlines; the lines say so.
    block = block
        .into_iter()
        .map(|l| l.replace("status=overdue", "status=due"))
        .collect();
    let mut body_lines: Vec<String> = recorded_lines("verifying-deadline.lines")
        .into_iter()
        .map(|l| l.replace("status=overdue", "status=due"))
        .collect();
    block.append(&mut body_lines);
    let blocked = paths.baseline.with_extension("json.tmp");
    std::fs::create_dir(&blocked).unwrap();
    let mut first = runner(&world, &clock);
    first.register(Duty::Verification, body(Lines::default()));
    let crashed = first.run();
    assert!(
        matches!(&crashed, Err(e) if e.key() == "watch-record"),
        "{crashed:?}"
    );
    assert_eq!(lines(&paths.log), block, "the lines are on disk");
    assert!(
        std::fs::metadata(&paths.baseline).is_err(),
        "the row never moved: no baseline was written"
    );
    std::fs::remove_dir(&blocked).unwrap();
    for (round, advance) in [(2, None), (3, Some(secs(240)))] {
        let mut again = runner(&world, &clock);
        again.register(Duty::Verification, body(Lines::default()));
        let identity = me();
        let ended = run_driven(again, &clock, &paths, &identity, || {
            clock.await_sleepers(1);
            if let Some(advance) = advance {
                clock.pass(advance);
            }
        });
        assert!(ended.is_ok(), "round {round}: {ended:?}");
        let twice: Vec<String> = block.iter().chain(block.iter()).cloned().collect();
        assert_eq!(
            lines(&paths.log),
            twice,
            "round {round}: printed once more, then nothing"
        );
        let baseline = Baseline::load(&paths.baseline).unwrap();
        assert_eq!(
            baseline.get("verifying-deadline", "KEN-1"),
            Some(
                "box=2 trigger=\"merge\" status=due deadline=2026-10-02T00:00:00Z|box=3 trigger=\"merge\" status=due deadline=2026-10-03T00:00:00Z"
            ),
            "round {round}"
        );
    }
}

/// A fleet whose lanes the report's body lists: one with a recorded cycle,
/// one parked on a pull request, one with a retained pull request the
/// timeline cannot read, one with nothing.
/// A report setting as the settings load carries it: its text.
fn set_report(ctx: &mut report::Context, key: &str, value: &str) {
    ctx.settings.report.retain(|(k, _)| k != key);
    ctx.settings.report.push((key.to_owned(), value.to_owned()));
}

fn report_fleet(overseer: Option<Value>) -> Value {
    let mut fleet = json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [
            {"item": "KEN-13", "status": "done", "launched_at": "2026-09-20T00:00:00Z", "tier": "small",
             "cycle": {"commit": "0123456789abcdef0123456789abcdef01234567",
                       "stamps": {"launched": "2026-09-20T00:00:00Z", "first_commit": "2026-09-20T00:01:00Z"}}},
            {"item": "KEN-4", "status": "parked", "launched_at": "2026-09-20T00:00:00Z",
             "cycle": {"stamps": {"first_commit": "2026-09-20T00:10:00Z"}},
             "parked": {"pr": 14, "head": "abc", "repo": "owner/repo", "at": "2026-09-27T00:00:00Z"}},
            {"item": "KEN-2", "status": "stopped", "launched_at": "2026-09-20T00:00:00Z",
             "pending_pr": {"pr": 15, "head": "def"}},
            {"item": "KEN-1", "status": "running", "launched_at": "2026-09-21T00:00:00Z"}
        ]
    });
    if let Some(overseer) = overseer {
        fleet["overseer"] = overseer;
    }
    fleet
}

const REPORT_BODY: [&str; 4] = [
    "  first-commit KEN-13 launched=2026-09-20T00:00:00Z first_commit=2026-09-20T00:01:00Z secs=60 tier=small",
    "  first-commit KEN-4 launched=2026-09-20T00:00:00Z first_commit=2026-09-20T00:10:00Z secs=600 tier=-",
    "  first-commit KEN-2 launched=2026-09-20T00:00:00Z first_commit=unread secs=- tier=-",
    "  first-commit KEN-1 launched=2026-09-21T00:00:00Z first_commit=none secs=- tier=-",
];

/// The report duty's own due judgement: one `report-due` line with the four
/// span lines, nothing while it stands, the row cleared once a report file
/// is written, and a mailbox the duty cannot read refuses the pass rather
/// than read as no owner report.
#[test]
fn report_due_prints_once_and_file_cadence_clears_it_without_a_script_answer() {
    let world = World::new();
    world.write_fleet(&report_fleet(None));
    let clock = FakeClock::new();
    let now = epoch("2026-10-02T00:00:01Z");
    let mut body = report::body(world.report_context());
    let mut baseline = Baseline::default();
    let due = "report-due reason=minutes since=2026-09-20T00:00:00Z";
    let produced = pass(Duty::Report, &mut body, &mut baseline, &clock, now).unwrap();
    let mut want = vec![format!("EVENT {due}")];
    want.extend(REPORT_BODY.iter().map(|l| (*l).to_owned()));
    assert_eq!(rendered(&produced), want);
    assert_eq!(baseline.get("report-due", "fleet"), Some(due));
    let again = pass(Duty::Report, &mut body, &mut baseline, &clock, now + 240).unwrap();
    assert!(again.events.is_empty());
    let dir = &world.settings.store.progress_report_dir;
    std::fs::create_dir_all(dir).unwrap();
    let report = dir.join("10-02-00-00.md");
    std::fs::write(&report, "report").unwrap();
    set_modified(&report, now + 300);
    let cleared = pass(Duty::Report, &mut body, &mut baseline, &clock, now + 480).unwrap();
    assert!(cleared.events.is_empty());
    assert_eq!(baseline.get("report-due", "fleet"), None);
    let mailbox = world.path().join("tmp/lane-mail/overseer");
    std::fs::create_dir_all(&mailbox).unwrap();
    std::fs::create_dir(mailbox.join("to-overseer.jsonl")).unwrap();
    assert!(pass(Duty::Report, &mut body, &mut baseline, &clock, now + 600).is_err());
}

/// Neither verification nor the report waits on a controller. The same
/// fleet with no controller record, with an explicit `off`, and with a
/// record naming a pane on a server that is gone: both duties produce the
/// same lines on each.
#[test]
fn verification_and_report_run_with_the_controller_dead_walled_and_off() {
    let clock = FakeClock::new();
    let now = epoch("2026-10-02T00:00:01Z");
    let controllers: [(&str, Option<Value>); 3] = [
        ("absent", None),
        (
            "off",
            Some(json!({"generation": 3, "off": {"at": "2026-10-01T00:00:00Z", "generation": 3}})),
        ),
        (
            "dead",
            Some(
                json!({"generation": 4, "server": 1, "server_start": 1, "pane": "%999", "window": "@9",
                        "runtime": "tmux", "session_rows": "/nowhere/session-1-999.jsonl"}),
            ),
        ),
    ];
    let mut answers: Vec<(Vec<String>, Vec<String>)> = Vec::new();
    for (case, overseer) in controllers {
        let world = World::new();
        world.write_fleet(&report_fleet(overseer));
        world.plant(
            "github.json",
            &json!({"pr-timeline 14 owner/repo": {"body": {"stamps": {"first_commit": "2026-09-20T00:10:00Z"}}}}),
        );
        let shared = shared_with(vec![verifying_item("KEN-1", "1", DEADLINE_BOXES, false)]);
        let mut verifying = verifying::body(world.verifying_context(shared, Lines::default()));
        let mut report = report::body(world.report_context());
        let mut baseline = Baseline::default();
        let v = pass(
            Duty::Verification,
            &mut verifying,
            &mut baseline,
            &clock,
            now,
        )
        .unwrap();
        let r = pass(Duty::Report, &mut report, &mut baseline, &clock, now).unwrap();
        assert_eq!(v.events.len(), 4, "{case}: two deadlines and their lines");
        assert_eq!(r.events.len(), 5, "{case}: the due line and four spans");
        answers.push((rendered(&v), rendered(&r)));
    }
    assert_eq!(answers[0], answers[1], "off reads as absent does");
    assert_eq!(answers[0], answers[2], "dead reads as absent does");
}

/// One owed item from its row: id, state, priority, lane, host, harness,
/// model, delivery.
type OwedRow<'a> = (
    &'a str,
    OwedState,
    &'a str,
    &'a str,
    &'a str,
    &'a str,
    &'a str,
    Option<&'a str>,
);

fn owed((id, state, priority, lane, host, harness, model, delivery): OwedRow<'_>) -> OwedItem {
    OwedItem {
        id: id.to_owned(),
        state,
        priority: priority.to_owned(),
        lane: lane.to_owned(),
        host: host.to_owned(),
        harness: harness.to_owned(),
        model: model.to_owned(),
        delivery: delivery.map(str::to_owned),
    }
}

/// Under one mail event every 7 s for 7000 s, with the tracker, GitHub and
/// verification slots holding the recorded owed world and the listing
/// fixture its roster: one heartbeat at the first tick at or past 6000 s,
/// its block the recorded bytes, then the quota, reducer and capacity
/// lines. The owed verdicts are the accounts judge's over the listing's
/// windows: the Opus windows of both claude accounts walled until
/// 2026-10-04 and their shared windows with room, so an Opus launch is
/// `dated` there and a Sonnet one `queue`; every codex window walled,
/// codex2 resetting first; the hosted codex record judged on the provider's
/// own listing under its host (the judge reads the provider's rows and asks
/// the reader for no pick), where the one codex account has room, and the
/// host's capability line read for the repository rule.
#[test]
fn the_heartbeat_body_carries_the_capacity_line_and_moves_no_due_time() {
    let world = World::new();
    let paths = world.paths();
    // The roster line's fields as the recording holds them, and the windows
    // the judge reads beside them: the 5-hour and weekly percentages with
    // their resets, and the model-scoped buckets.
    let account = |alias: &str, harness: &str, verdict: &str, resets: &str, windows: Value| {
        let mut row = json!({"alias": alias, "harness": harness, "config_dir": format!("/home/u/.{alias}"),
               "measured_through": "local", "status": "ok", "verdict": verdict, "headroom_pct": 0,
               "binding_bucket": "weekly", "binding_resets_at": resets});
        for (key, value) in windows.as_object().unwrap() {
            row[key] = value.clone();
        }
        row
    };
    let opus_walled = |weekly: u64, weekly_resets: &str| {
        json!({"session_5h_pct": 10, "weekly_pct": weekly,
               "resets": {"session": "2026-10-01T04:00:00Z", "weekly": weekly_resets},
               "model_buckets": [{"label": "Opus", "pct": 100, "resets_at": "2026-10-04T00:00:00Z"}]})
    };
    // The hosted record is judged on the provider's listing, read under
    // its host: one codex account with room, so the verdict is `queue`
    // where the local codex accounts are walled.
    let mut hosted = account(
        "codex",
        "codex",
        "room",
        "2026-10-05T00:00:00Z",
        json!({"headroom_pct": 60, "session_5h_pct": 10, "weekly_pct": 40,
               "resets": {"session": "2026-10-01T04:00:00Z", "weekly": "2026-10-05T00:00:00Z"},
               "model_buckets": []}),
    );
    hosted["measured_through"] = json!("host");
    let clock = FakeClock::new();
    let planted = world.plant_accounts(
        Some("provider-x"),
        &[
            account(
                "claude",
                "claude",
                "room",
                "2026-10-01T00:00:00Z",
                opus_walled(10, "2026-10-01T00:00:00Z"),
            ),
            account(
                "claude2",
                "claude",
                "walled",
                "2026-10-02T00:00:00Z",
                opus_walled(60, "2026-10-02T00:00:00Z"),
            ),
            account(
                "codex",
                "codex",
                "walled",
                "2026-10-05T00:00:00Z",
                json!({}),
            ),
            account(
                "codex2",
                "codex",
                "walled",
                "2026-10-03T00:00:00Z",
                json!({}),
            ),
            hosted,
        ],
        clock.wall_secs(),
    );
    world.plant(
        "gh.json",
        &json!({"repos/owner/repo/pulls?state=open&per_page=100&page=1": {"body": [
            {"number": 16, "state": "open", "title": "the review item", "body": null, "merged_at": null, "merge_commit_sha": null, "author_association": "NONE", "head": {"sha": "0000000000000000000000000000000000000000", "ref": "ken-6", "repo": null}, "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null}
        ]}}),
    );
    let shared = Shared::default();
    {
        let mut latest = shared.lock().unwrap();
        latest.tracker = Some(TrackerInventory {
            read_at: 0,
            owed: vec![
                owed((
                    "KEN-10",
                    OwedState::InProgress,
                    "2",
                    "stopped",
                    "local",
                    "claude",
                    "-",
                    Some("pr=21"),
                )),
                owed((
                    "KEN-11",
                    OwedState::InProgress,
                    "1",
                    "stopped",
                    "local",
                    "claude",
                    "claude-opus-5",
                    None,
                )),
                owed((
                    "KEN-12",
                    OwedState::InProgress,
                    "2",
                    "stopped",
                    named_host(world.path(), "provider-x").as_str(),
                    "codex",
                    "-",
                    None,
                )),
                owed((
                    "KEN-13",
                    OwedState::InReview,
                    "2",
                    "done",
                    "local",
                    "claude",
                    "-",
                    Some("commit=0123456789abcdef0123456789abcdef01234567"),
                )),
                owed((
                    "KEN-2",
                    OwedState::InProgress,
                    "2",
                    "stopped",
                    "local",
                    "claude",
                    "claude-sonnet-5",
                    None,
                )),
                owed((
                    "KEN-3",
                    OwedState::InProgress,
                    "1",
                    "stopped",
                    "local",
                    "codex",
                    "-",
                    None,
                )),
                owed((
                    "KEN-5",
                    OwedState::InReview,
                    "2",
                    "done",
                    "local",
                    "claude",
                    "-",
                    Some("pr=15"),
                )),
                owed((
                    "KEN-6",
                    OwedState::InReview,
                    "3",
                    "none",
                    "local",
                    "-",
                    "-",
                    None,
                )),
                owed((
                    "KEN-9",
                    OwedState::InProgress,
                    "-",
                    "stopped",
                    "local",
                    "pi",
                    "-",
                    None,
                )),
            ],
            verifying: Vec::new(),
            open_unblocked: vec!["KEN-6".to_owned(), "KEN-8".to_owned()],
        });
        latest.quota = Some(Quota {
            limit: QuotaLimit::Requests,
            status: QuotaStatus::Future,
            reset: "2026-10-01T00:10:00Z".to_owned(),
            reset_epoch: Some(epoch("2026-10-01T00:10:00Z")),
        });
        latest.github = Some(github::Inventory {
            pr_watch: Some(pr_watch::Context {
                rc: 1,
                out: "owner/repo\t16\tabc\tci-failed\n".to_owned(),
                err: String::new(),
            }),
            ..github::Inventory::default()
        });
    }
    let verifying = Lines::default();
    *verifying.lock().unwrap() = recorded_lines("verifying-deadline.lines");
    let start_wall = clock.wall_secs();
    let mail = Counting::new();
    let mut runner = runner(&world, &clock);
    runner.register(
        Duty::Mail,
        mail.body(|tick| Produced {
            events: vec![Event::DirectiveRead {
                item: "KEN-1".into(),
                id: tick.wall.to_string(),
            }],
            ..Produced::default()
        }),
    );
    runner.register(
        Duty::Heartbeat,
        heartbeat::body(heartbeat::Context {
            settings: world.settings_with(&planted),
            path: world.fleet_path(),
            max_loops: 25,
            interval: secs(240),
            since: None,
            repos: vec!["owner/repo".to_owned()],
            gh: world.path().join("gh"),
            shared,
            verifying,
            locking: Locking::FLOCK,
            nonce: 7,
            owner: None,
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(2);
        for _ in 0..1000 {
            clock.pass(secs(7));
        }
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(
        mail.runs(),
        1001,
        "one mail run per tick, the first at start"
    );
    let log = lines(&paths.log);
    let heartbeats: Vec<usize> = log
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with("EVENT heartbeat "))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(heartbeats.len(), 1, "one heartbeat in 7000 s");
    let at = heartbeats[0];
    let block: Vec<String> = log[at..]
        .iter()
        .take_while(|l| !l.starts_with("EVENT directive-read "))
        .cloned()
        .collect();
    // The recording ran the recorded watch with `--max-loops 1 --interval 0`;
    // its first line is the flags', every line under it the body's.
    let mut want = vec!["EVENT heartbeat loops=25 interval=240s since=none".to_owned()];
    // The accounts stand where the world planted them.
    let home = format!("{}/home/", world.path().display());
    want.extend(
        recorded_lines("heartbeat.out")
            .into_iter()
            .skip(1)
            .map(|line| line.replace("config_dir=/home/u/", &format!("config_dir={home}"))),
    );
    want.extend([
        "tracker-quota status=future reset=2026-10-01T00:10:00Z limit=requests".to_owned(),
        "pr-watch rc=1".to_owned(),
        "owner/repo\t16\tabc\tci-failed".to_owned(),
        "open-unblocked count=2 items=KEN-6,KEN-8".to_owned(),
    ]);
    assert_eq!(block, want);
    // The due time is the runner's: 6000 s from the start, the first tick
    // at or past it being 6006; the body asked for nothing earlier.
    let baseline = Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.passes.get(&Duty::Heartbeat),
        Some(&(start_wall + 6006))
    );
    assert!(
        log[at - 1].starts_with("EVENT directive-read KEN-1 ")
            && log[at + want.len()].starts_with("EVENT directive-read KEN-1 "),
        "mail ran on both sides of the heartbeat"
    );
    // What the judge asked the provider: its capability line and its
    // accounts under the hosted record's host, once each for the listing
    // and the line again for the repository rule; nothing under no host.
    let hosts = lines(&world.path().join("lane-host.log"));
    assert_eq!(
        hosts
            .iter()
            .filter(|h| *h == "ORCH_LANE_HOST=provider-x accounts")
            .count(),
        1,
        "{hosts:?}"
    );
    assert!(
        hosts
            .iter()
            .all(|h| h.starts_with("ORCH_LANE_HOST=provider-x ")),
        "the provider is asked under its host alone: {hosts:?}"
    );
}

/// A heartbeat that said nothing where an unread list goes would read a
/// standing tracker failure as nothing owed. The body with every slot
/// empty, the roster refused and the open list unanswered: each list's
/// `unread` line in its place, the owed list's among them.
#[test]
fn the_heartbeat_body_says_unread_for_every_list_no_duty_has_read() {
    let world = World::new();
    let clock = FakeClock::new();
    let mut body = heartbeat::body(heartbeat::Context {
        settings: world.settings.clone(),
        path: world.fleet_path(),
        max_loops: 25,
        interval: secs(240),
        since: None,
        repos: vec!["owner/repo".to_owned()],
        gh: world.path().join("gh"),
        shared: Shared::default(),
        verifying: Lines::default(),
        locking: Locking::FLOCK,
        nonce: 7,
        owner: None,
    });
    let mut baseline = Baseline::default();
    let produced = pass(
        Duty::Heartbeat,
        &mut body,
        &mut baseline,
        &clock,
        clock.wall_secs(),
    )
    .unwrap();
    assert_eq!(
        rendered(&produced),
        vec![
            "EVENT heartbeat loops=25 interval=240s since=none".to_owned(),
            "owner/repo\topen-prs unread".to_owned(),
            "account-roster accounts=0".to_owned(),
            "accounts-unconfigured key=AGENT_RUNTIME_ACCOUNT_DIRS".to_owned(),
            "owed unread".to_owned(),
            "open-unblocked count=unread items=-".to_owned(),
        ]
    );
}

/// One listing record as the recorded accounts world wrote it: `-` for
/// the headroom or the reset is the null an unmeasured account carries.
fn account_record(alias: &str, through: &str, reading: &str) -> Value {
    let words: Vec<&str> = reading.split_whitespace().collect();
    let [status, verdict, headroom, resets] = words[..] else {
        panic!("{reading}");
    };
    json!({
        "alias": alias, "harness": "claude", "config_dir": format!("/home/u/.{alias}"),
        "measured_through": through, "status": status, "verdict": verdict,
        "headroom_pct": if headroom == "-" { Value::Null } else { json!(headroom.parse::<u64>().unwrap()) },
        "binding_bucket": if resets == "-" { Value::Null } else { json!("weekly") },
        "binding_resets_at": if resets == "-" { Value::Null } else { json!(resets) },
    })
}

/// The heartbeat body with every slot empty and no open list: the roster
/// and its account events are what the pass produces.
fn roster_body(world: &World, planted: &[(String, String)]) -> watch::Body<'static> {
    heartbeat::body(heartbeat::Context {
        settings: world.settings_with(planted),
        path: world.fleet_path(),
        max_loops: 25,
        interval: secs(240),
        since: None,
        repos: Vec::new(),
        gh: world.path().join("gh"),
        shared: Shared::default(),
        verifying: Lines::default(),
        locking: Locking::FLOCK,
        nonce: 7,
        owner: None,
    })
}

/// The `account` events of a pass, which stand ahead of its heartbeat line.
fn account_events(produced: &Produced) -> Vec<String> {
    let lines = rendered(produced);
    let heartbeat = lines
        .iter()
        .position(|l| l.starts_with("EVENT heartbeat "))
        .unwrap_or_else(|| panic!("{lines:?}"));
    let events: Vec<String> = lines
        .iter()
        .filter(|l| l.starts_with("EVENT account "))
        .cloned()
        .collect();
    assert_eq!(
        lines[..heartbeat].to_vec(),
        events,
        "the account events stand ahead of the heartbeat line"
    );
    events
}

/// The baseline row key of the local `claude` account where the world
/// plants it.
fn claude_key(world: &World) -> String {
    format!("claude|local|{}", world.home_dir("claude"))
}

/// The recorded accounts world's `renewal`, `crossing`, `reset`, `dropped`,
/// `reset_unparsed` and `shared_alias` cases. Each sequence is its passes'
/// listings and the account events each pass says, at the wall it runs at.
#[test]
fn an_account_change_is_said_once_with_what_changed_from_what_and_again_on_the_next() {
    // One hour before and after the reset sequence's first reset.
    const BEFORE: u64 = 1_790_247_600;
    const AFTER: u64 = 1_790_254_800;
    const ANY: u64 = BEFORE;
    let claude = |reading: &str| account_record("claude", "local", reading);
    let eclaude = |reading: &str| account_record("eclaude", "local", reading);
    let srv = |reading: &str| {
        let mut record = claude(reading);
        record["config_dir"] = json!("/srv/u/.claude");
        record
    };
    /// One pass: its wall, the listing it reads, the account events it says.
    type Pass<'a> = (u64, Vec<Value>, Vec<&'a str>);
    let sequences: Vec<(&str, Vec<Pass>)> = vec![
        (
            "renewal",
            vec![
                (
                    ANY,
                    vec![
                        claude("expired unmeasured - -"),
                        eclaude("ok room 40 2026-10-02T00:00:00Z"),
                    ],
                    vec![],
                ),
                (
                    ANY,
                    vec![
                        claude("ok room 80 2026-10-01T00:00:00Z"),
                        eclaude("ok room 40 2026-10-02T00:00:00Z"),
                    ],
                    vec![
                        "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=80 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=status,headroom was=expired/unmeasured",
                    ],
                ),
                (
                    ANY,
                    vec![
                        claude("ok room 80 2026-10-01T00:00:00Z"),
                        eclaude("ok room 40 2026-10-02T00:00:00Z"),
                    ],
                    vec![],
                ),
            ],
        ),
        (
            "crossing",
            vec![
                (ANY, vec![claude("ok room 10 2026-10-01T00:00:00Z")], vec![]),
                (
                    ANY,
                    vec![claude("ok walled 3 2026-10-01T00:00:00Z")],
                    vec![
                        "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=walled headroom_pct=3 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/room",
                    ],
                ),
                (
                    ANY,
                    vec![claude("ok room 30 2026-10-01T00:00:00Z")],
                    vec![
                        "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled",
                    ],
                ),
                (ANY, vec![claude("ok room 50 2026-10-01T00:00:00Z")], vec![]),
            ],
        ),
        (
            "reset",
            vec![
                (
                    BEFORE,
                    vec![claude("ok walled 2 2026-09-24T12:00:00Z")],
                    vec![],
                ),
                (
                    BEFORE,
                    vec![claude("ok walled 2 2026-09-24T12:30:00Z")],
                    vec![],
                ),
                (
                    AFTER,
                    vec![claude("ok walled 2 2026-09-24T12:30:00Z")],
                    vec![],
                ),
                (
                    AFTER,
                    vec![claude("ok room 20 2026-09-24T12:30:00Z")],
                    vec![
                        "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=20 binding_bucket=weekly binding_resets_at=2026-09-24T12:30:00Z change=headroom was=ok/walled",
                    ],
                ),
                (
                    AFTER,
                    vec![claude("ok room 20 2026-10-01T12:00:00Z")],
                    vec![
                        "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=20 binding_bucket=weekly binding_resets_at=2026-10-01T12:00:00Z change=reset was=ok/room",
                    ],
                ),
            ],
        ),
        (
            "dropped",
            vec![
                (
                    ANY,
                    vec![claude("ok walled 2 2026-10-01T00:00:00Z")],
                    vec![],
                ),
                (
                    ANY,
                    vec![eclaude("ok room 40 2026-10-02T00:00:00Z")],
                    vec![],
                ),
                (
                    ANY,
                    vec![claude("ok room 30 2026-10-01T00:00:00Z")],
                    vec![
                        "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled",
                    ],
                ),
            ],
        ),
        (
            "reset_unparsed",
            vec![
                (ANY, vec![claude("ok walled 2 not-a-time")], vec![]),
                (
                    ANY,
                    vec![claude("ok room 30 2026-10-01T00:00:00Z")],
                    vec![
                        "EVENT account claude config_dir=/home/u/.claude harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled",
                    ],
                ),
            ],
        ),
        (
            "shared_alias",
            vec![
                (
                    ANY,
                    vec![
                        claude("ok room 80 2026-10-01T00:00:00Z"),
                        srv("ok room 70 2026-10-01T00:00:00Z"),
                    ],
                    vec![],
                ),
                (
                    ANY,
                    vec![
                        claude("ok room 80 2026-10-01T00:00:00Z"),
                        srv("ok walled 2 2026-10-01T00:00:00Z"),
                    ],
                    vec![
                        "EVENT account claude config_dir=/srv/u/.claude harness=claude through=local status=ok verdict=walled headroom_pct=2 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/room",
                    ],
                ),
            ],
        ),
    ];
    let world = World::new();
    let clock = FakeClock::new();
    // The readings are a provider's rows under `fleet-vm`: a reading the
    // provider states is served as stated, where this machine's own
    // record of a window whose reset has passed is read again.
    for (name, passes) in sequences {
        let mut baseline = Baseline::default();
        for (n, (wall, listing, want)) in passes.into_iter().enumerate() {
            let listing: Vec<Value> = listing
                .iter()
                .map(|row| {
                    let mut row = row.clone();
                    row["measured_through"] = json!("host");
                    row
                })
                .collect();
            let mut planted = world.plant_accounts(Some("fleet-vm"), &listing, wall);
            planted.push(("ORCH_LANE_HOST".to_owned(), "fleet-vm".to_owned()));
            let mut body = roster_body(&world, &planted);
            let want: Vec<String> = want
                .iter()
                .map(|w| w.replace("through=local", "through=host"))
                .collect();
            let produced = pass(Duty::Heartbeat, &mut body, &mut baseline, &clock, wall).unwrap();
            assert_eq!(produced.failed, None, "{name} pass {}", n + 1);
            assert_eq!(account_events(&produced), want, "{name} pass {}", n + 1);
            // The roster under the line is the pass's own reading.
            let roster: Vec<String> = rendered(&produced)
                .into_iter()
                .filter(|l| l.starts_with("account "))
                .collect();
            assert_eq!(roster.len(), listing.len(), "{name} pass {}", n + 1);
        }
    }
}

/// The recorded accounts world's sequence table and its four controls. Each
/// row of the table is one pass's reading, the event tail it says and the
/// `account` row saved under the recorded watch's key afterwards, `-` for
/// none.
#[test]
fn an_unmeasured_reading_keeps_the_row_and_a_terminal_status_is_news() {
    const SEQUENCES: &[(&str, &str, &str, &str)] = &[
        (
            "quiet",
            "ok room 80 2099-01-01T00:00:00Z",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "quiet",
            "unreachable unmeasured - -",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "quiet",
            "held unmeasured - -",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "quiet",
            "ok room 80 2099-01-01T00:00:00Z",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "crossing",
            "ok walled 2 2099-01-01T00:00:00Z",
            "-",
            "ok|walled|2099-01-01T00:00:00Z|-",
        ),
        (
            "crossing",
            "unreachable unmeasured - -",
            "-",
            "ok|walled|2099-01-01T00:00:00Z|-",
        ),
        (
            "crossing",
            "ok room 80 2099-01-01T00:00:00Z",
            "change=headroom was=ok/walled",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "expired",
            "ok room 80 2099-01-01T00:00:00Z",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "expired",
            "unreachable unmeasured - -",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "expired",
            "expired unmeasured - -",
            "change=status,headroom was=ok/room",
            "expired|unmeasured|-|expired",
        ),
        (
            "expired",
            "held unmeasured - -",
            "-",
            "expired|unmeasured|-|expired",
        ),
        (
            "expired",
            "ok room 80 2099-01-01T00:00:00Z",
            "change=status,headroom was=expired/unmeasured",
            "ok|room|2099-01-01T00:00:00Z|expired",
        ),
        (
            "expired",
            "expired unmeasured - -",
            "change=status,headroom was=ok/room",
            "expired|unmeasured|-|expired",
        ),
        (
            "expired",
            "expired unmeasured - -",
            "-",
            "expired|unmeasured|-|expired",
        ),
        (
            "retired",
            "ok room 80 2099-01-01T00:00:00Z",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "retired",
            "unreachable unmeasured - -",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "retired",
            "retired unmeasured - -",
            "change=status,headroom was=ok/room",
            "retired|unmeasured|-|retired",
        ),
        (
            "retired",
            "held unmeasured - -",
            "-",
            "retired|unmeasured|-|retired",
        ),
        (
            "retired",
            "ok room 80 2099-01-01T00:00:00Z",
            "change=status,headroom was=retired/unmeasured",
            "ok|room|2099-01-01T00:00:00Z|retired",
        ),
        (
            "retired",
            "retired unmeasured - -",
            "change=status,headroom was=ok/room",
            "retired|unmeasured|-|retired",
        ),
        (
            "retired",
            "retired unmeasured - -",
            "-",
            "retired|unmeasured|-|retired",
        ),
        ("no_baseline", "unreachable unmeasured - -", "-", "-"),
        ("no_baseline", "held unmeasured - -", "-", "-"),
        (
            "no_baseline",
            "ok room 80 2099-01-01T00:00:00Z",
            "-",
            "ok|room|2099-01-01T00:00:00Z|-",
        ),
        (
            "retired_baseline",
            "retired unmeasured - -",
            "-",
            "retired|unmeasured|-|retired",
        ),
        (
            "retired_baseline",
            "ok room 80 2099-01-01T00:00:00Z",
            "change=status,headroom was=retired/unmeasured",
            "ok|room|2099-01-01T00:00:00Z|retired",
        ),
    ];
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let mut got = Vec::new();
    let mut want = Vec::new();
    let mut current: Option<(&str, watch::Body<'static>, Baseline)> = None;
    for &(name, reading, expected, saved) in SEQUENCES {
        let planted = world.plant_accounts(
            Some("fleet-vm"),
            &[account_record("claude", "host", reading)],
            wall,
        );
        let planted: Vec<(String, String)> = planted
            .into_iter()
            .chain([("ORCH_LANE_HOST".to_owned(), "fleet-vm".to_owned())])
            .collect();
        if current.as_ref().is_none_or(|(c, _, _)| *c != name) {
            current = Some((name, roster_body(&world, &planted), Baseline::default()));
        }
        let (_, body, baseline) = current.as_mut().unwrap();
        let produced = pass(Duty::Heartbeat, body, baseline, &clock, wall).unwrap();
        assert_eq!(produced.failed, None, "{name}: {reading}");
        let events = account_events(&produced);
        let tail = match events.as_slice() {
            [] => "-".to_owned(),
            [one] => one[one.find(" change=").unwrap() + 1..].to_owned(),
            more => panic!("{name}: {reading}: {more:?}"),
        };
        let row = baseline
            .get("account", "claude|host|/home/u/.claude")
            .unwrap_or("-");
        got.push(format!("{name}: {reading}: {tail} row={row}"));
        want.push(format!("{name}: {reading}: {expected} row={saved}"));
    }
    assert_eq!(got, want);
}

/// A listing that cannot be read is no fleet without accounts and no
/// change, or the next readable pass would say a change against nothing. A
/// configured account whose directory cannot be read is a counted failure
/// with `account-roster unread` and the row as it stood; the readable pass after it says the
/// change against the reading before it.
#[test]
fn an_unreadable_listing_is_a_counted_failure_that_keeps_the_previous_reading() {
    use std::os::unix::fs::PermissionsExt;
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let mut baseline = Baseline::default();
    let claude = |reading: &str| vec![account_record("claude", "local", reading)];
    let planted = world.plant_accounts(None, &claude("ok walled 2 2026-10-01T00:00:00Z"), wall);
    let mut body = roster_body(&world, &planted);
    let produced = pass(Duty::Heartbeat, &mut body, &mut baseline, &clock, wall).unwrap();
    assert_eq!(produced.failed, None);
    assert_eq!(account_events(&produced), Vec::<String>::new());
    let held = "ok|walled|2026-10-01T00:00:00Z|-";
    assert_eq!(baseline.get("account", &claude_key(&world)), Some(held));
    let home = world.path().join("home");
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o000)).unwrap();
    let produced = pass(Duty::Heartbeat, &mut body, &mut baseline, &clock, wall);
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o755)).unwrap();
    let produced = produced.unwrap();
    assert!(
        produced
            .failed
            .as_deref()
            .is_some_and(|c| c.starts_with("account-unread path=")),
        "{:?}",
        produced.failed
    );
    let lines = rendered(&produced);
    assert_eq!(account_events(&produced), Vec::<String>::new());
    assert!(
        lines.contains(&"account-roster unread".to_owned())
            && !lines.iter().any(|l| l.starts_with("account ")),
        "{lines:?}"
    );
    assert_eq!(produced.changes, Vec::new(), "no row moves");
    assert_eq!(baseline.get("account", &claude_key(&world)), Some(held));
    world.plant_accounts(None, &claude("ok room 30 2026-10-01T00:00:00Z"), wall);
    let produced = pass(Duty::Heartbeat, &mut body, &mut baseline, &clock, wall).unwrap();
    assert_eq!(produced.failed, None);
    assert_eq!(
        account_events(&produced),
        vec![format!(
            "EVENT account claude config_dir={} harness=claude through=local status=ok verdict=room headroom_pct=30 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z change=headroom was=ok/walled",
            world.home_dir("claude")
        )],
        "the change is said against the reading before the unreadable pass"
    );
    assert_eq!(
        baseline.get("account", &claude_key(&world)),
        Some("ok|room|2026-10-01T00:00:00Z|-")
    );
}

#[test]
fn an_owed_local_item_under_a_fleet_provider_is_judged_on_the_local_listing() {
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let mut baseline = Baseline::default();
    // The provider's reading names the same account as the local one, so
    // under the provider it is the one reading of that account.
    let mut provider = account_record("claude", "host", "ok walled 0 2026-10-04T00:00:00Z");
    provider["config_dir"] = json!(world.home_dir("claude"));
    let planted: Vec<(String, String)> = world
        .plant_accounts(
            Some("provider-x"),
            &[
                account_record("claude", "local", "ok room 60 2026-10-01T00:00:00Z"),
                provider,
            ],
            wall,
        )
        .into_iter()
        .chain([("ORCH_LANE_HOST".to_owned(), "provider-x".to_owned())])
        .collect();
    let shared = Shared::default();
    shared.lock().unwrap().tracker = Some(TrackerInventory {
        read_at: 0,
        owed: vec![owed((
            "KEN-1",
            OwedState::InProgress,
            "2",
            "stopped",
            "local",
            "claude",
            "-",
            None,
        ))],
        verifying: Vec::new(),
        open_unblocked: Vec::new(),
    });
    let mut body = heartbeat::body(heartbeat::Context {
        settings: world.settings_with(&planted),
        path: world.fleet_path(),
        max_loops: 25,
        interval: secs(240),
        since: None,
        repos: Vec::new(),
        gh: world.path().join("gh"),
        shared,
        verifying: Lines::default(),
        locking: Locking::FLOCK,
        nonce: 7,
        owner: None,
    });
    let produced = pass(Duty::Heartbeat, &mut body, &mut baseline, &clock, wall).unwrap();
    assert_eq!(produced.failed, None);
    let lines = rendered(&produced);
    assert!(
        lines.contains(
            &"owed KEN-1 state=in-progress priority=2 lane=stopped verdict=queue".to_owned()
        ),
        "the local item is judged on the local account's room, not the provider's wall: {lines:?}"
    );
}

#[test]
fn an_owed_local_item_is_judged_on_the_local_listing_while_the_fleet_provider_cannot_be_read() {
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let mut baseline = Baseline::default();
    let planted: Vec<(String, String)> = world
        .plant_accounts(
            Some("provider-x"),
            &[account_record(
                "claude",
                "local",
                "ok room 60 2026-10-01T00:00:00Z",
            )],
            wall,
        )
        .into_iter()
        .chain([("ORCH_LANE_HOST".to_owned(), "provider-x".to_owned())])
        .collect();
    let map = world.path().join("lane-host.json");
    let mut answers: Value = serde_json::from_str(&std::fs::read_to_string(&map).unwrap()).unwrap();
    answers["provider-x capabilities"] =
        json!({"exit": 1, "stderr": "lane-host-fixture: provider down\n"});
    std::fs::write(&map, answers.to_string()).unwrap();
    let shared = Shared::default();
    shared.lock().unwrap().tracker = Some(TrackerInventory {
        read_at: 0,
        owed: vec![owed((
            "KEN-1",
            OwedState::InProgress,
            "2",
            "stopped",
            "local",
            "claude",
            "-",
            None,
        ))],
        verifying: Vec::new(),
        open_unblocked: Vec::new(),
    });
    let mut body = heartbeat::body(heartbeat::Context {
        settings: world.settings_with(&planted),
        path: world.fleet_path(),
        max_loops: 25,
        interval: secs(240),
        since: None,
        repos: Vec::new(),
        gh: world.path().join("gh"),
        shared,
        verifying: Lines::default(),
        locking: Locking::FLOCK,
        nonce: 7,
        owner: None,
    });
    let produced = pass(Duty::Heartbeat, &mut body, &mut baseline, &clock, wall).unwrap();
    let lines = rendered(&produced);
    assert!(
        lines.contains(&"account-roster unread".to_owned()),
        "the fleet's roster under the provider is unread: {lines:?}"
    );
    assert!(
        lines.contains(
            &"owed KEN-1 state=in-progress priority=2 lane=stopped verdict=queue".to_owned()
        ),
        "the local item is judged on this machine's listing: {lines:?}"
    );
}

/// An owed item on a provider whose `accounts` read fails is never judged
/// on this machine's listing: its local account at room, the pick under
/// the item's host is unjudged and the owed line says so, the provider's
/// accounts asked by the listing and again by the pick.
#[test]
fn an_owed_hosted_item_under_a_failed_accounts_read_is_unjudged() {
    let exit = 1;
    {
        let world = World::new();
        let clock = FakeClock::new();
        let wall = clock.wall_secs();
        let mut baseline = Baseline::default();
        let planted = world.plant_accounts(
            Some("provider-x"),
            &[account_record(
                "claude",
                "local",
                "ok room 60 2026-10-01T00:00:00Z",
            )],
            wall,
        );
        let map = world.path().join("lane-host.json");
        let mut answers: Value =
            serde_json::from_str(&std::fs::read_to_string(&map).unwrap()).unwrap();
        answers["provider-x accounts"] =
            json!({"exit": exit, "stderr": "lane-host-fixture: accounts-refused\n"});
        std::fs::write(&map, answers.to_string()).unwrap();
        let shared = Shared::default();
        shared.lock().unwrap().tracker = Some(TrackerInventory {
            read_at: 0,
            owed: vec![owed((
                "KEN-1",
                OwedState::InProgress,
                "2",
                "stopped",
                named_host(world.path(), "provider-x").as_str(),
                "claude",
                "-",
                None,
            ))],
            verifying: Vec::new(),
            open_unblocked: Vec::new(),
        });
        let mut body = heartbeat::body(heartbeat::Context {
            settings: world.settings_with(&planted),
            path: world.fleet_path(),
            max_loops: 25,
            interval: secs(240),
            since: None,
            repos: Vec::new(),
            gh: world.path().join("gh"),
            shared,
            verifying: Lines::default(),
            locking: Locking::FLOCK,
            nonce: 7,
            owner: None,
        });
        let produced = pass(Duty::Heartbeat, &mut body, &mut baseline, &clock, wall).unwrap();
        assert_eq!(
            rendered(&produced),
            [
                "EVENT heartbeat loops=25 interval=240s since=none".to_owned(),
                "account-roster accounts=1".to_owned(),
                format!(
                    "account claude config_dir={} harness=claude through=local status=ok verdict=room headroom_pct=60 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z",
                    world.home_dir("claude")
                ),
                "owed KEN-1 state=in-progress priority=2 lane=stopped verdict=unjudged harness=claude"
                    .to_owned(),
                "open-unblocked count=0 items=-".to_owned(),
            ],
            "{exit}"
        );
        let asked = lines(&world.path().join("lane-host.log"));
        assert_eq!(
            asked
                .iter()
                .filter(|h| *h == "ORCH_LANE_HOST=provider-x accounts")
                .count(),
            2,
            "{exit}: {asked:?}"
        );
    }
}

/// A lane record of the vintage `status` with `launched_at` and the
/// fields given.
fn lane(item: &str, status: &str, launched_at: &str, extra: Value) -> Value {
    let mut record = json!({"item": item, "status": status, "launched_at": launched_at});
    for (key, value) in extra.as_object().into_iter().flatten() {
        record[key] = value.clone();
    }
    record
}

fn set_modified(path: &Path, at: u64) {
    std::fs::File::open(path)
        .unwrap()
        .set_modified(UNIX_EPOCH + Duration::from_secs(at))
        .unwrap();
}

fn touch(path: &Path) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, "x\n").unwrap();
}

/// Each record is judged by its own recorded end, never by `done` alone (a
/// released `closed` record) or by a directory's newest write (an
/// append-only `handoffs/`); a lane whose worktree stands with no reason
/// recorded, a kept worktree, mail within the retention, the newest log
/// segment and the fleet start's record stand; a lane relaunched after a
/// confirmed close is read by its own session. One pass at the fake wall
/// over ten records and three segments.
#[test]
fn retention_prunes_each_record_by_its_own_recorded_end_and_never_recent_mail_or_a_kept_worktree() {
    let world = World::new();
    let paths = world.paths();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let day = 86_400;
    let old = clock::iso_utc(wall - 10 * day);
    let recent = clock::iso_utc(wall - day);
    let wt = |item: &str| world.path().join("wt").join(item);
    for item in ["KEN-B", "KEN-C", "KEN-G", "KEN-R"] {
        touch(&wt(item).join("draft.txt"));
    }
    // A close bound to the session it closed, `lane_since` the lane's
    // `session_since` when the close was written, as the runtime writes it.
    let close = |item: &str, by: &str, at: &str, since: &str| {
        json!({"id": format!("close-resources:{item}:1-1"), "op": "close-resources",
               "target": item, "created_at": at, "completed_at": at, "outcome": "confirmed", "lane_since": since,
               "obligations": {"standing": [], "signalled": true, "revision": 2,
                               "discharged": [{"obligation": {"kind": "worktree", "path": wt(item).display().to_string()},
                                               "by": by, "role": "worktree"}]}})
    };
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [],
        "lanes": [
            lane("KEN-0", "done", &old, json!({})),
            lane("KEN-A", "closed", &old, json!({"mail_root": wt("KEN-A")})),
            lane("KEN-B", "done", &old, json!({"mail_root": wt("KEN-B"), "kept": "unmerged"})),
            lane("KEN-C", "done", &old, json!({"mail_root": wt("KEN-C")})),
            lane("KEN-D", "done", &recent, json!({"mail_root": wt("KEN-D")})),
            lane("KEN-E", "stopped", &old, json!({})),
            lane("KEN-F", "running", &old, json!({})),
            lane("KEN-G", "done", &old, json!({"mail_root": wt("KEN-G"), "session_since": old})),
            lane("KEN-H", "running", &old, json!({"mail_root": wt("KEN-H"), "session_since": old})),
            // Relaunched after its close (`ops::lane::launch_lane`): `running`
            // under a new `session_since`, the close's `kept` word kept, the
            // earlier session's close still among the intents.
            lane("KEN-R", "running", &old, json!({"mail_root": wt("KEN-R"), "session_since": recent, "running_at": recent, "kept": "dirty"})),
        ],
        "intents": [
            close("KEN-G", &format!("released:mail-kept:{}", world.path().join("tmp/lane-mail/KEN-G").display()), &old, &old),
            close("KEN-H", "kept:dirty", &old, &old),
            close("KEN-R", "kept:dirty", &old, &old),
        ],
        "fleet_log": [
            {"at": old, "kind": "close", "item": "KEN-A", "text": "closed"},
            {"at": recent, "kind": "close", "item": "KEN-D", "text": "closed"},
            {"kind": "ruling", "item": "KEN-1", "text": "no stamp"}
        ]
    }));
    // The paths: each item's state, lock, status file and handoff, the
    // mailbox beside them; the live lane's handoff written now makes the
    // handoffs directory's newest write now.
    let dir = world.path();
    for item in [
        "KEN-0", "KEN-A", "KEN-B", "KEN-C", "KEN-D", "KEN-E", "KEN-G", "KEN-H", "KEN-R",
    ] {
        touch(&dir.join(format!("workflow-state-{item}.json")));
        touch(&dir.join(format!("workflow-state-{item}.json.lock")));
        touch(&dir.join(format!("lane-status-{item}.md")));
        touch(&dir.join("handoffs").join(format!("{item}-handoff.md")));
        touch(&dir.join("lane-mail").join(item).join("to-lane.jsonl"));
        for path in [
            dir.join(format!("workflow-state-{item}.json")),
            dir.join(format!("lane-status-{item}.md")),
            dir.join("handoffs").join(format!("{item}-handoff.md")),
        ] {
            set_modified(&path, wall - 10 * day);
        }
    }
    touch(&dir.join("handoffs").join("KEN-F-handoff.md"));
    touch(&dir.join("handoffs").join("OVERSEER-HANDOFF.md"));
    touch(&dir.join("workflow-state-KEN-10.json"));
    // Three rotated segments, every one past the retention, and the live log.
    for base in [0u64, 10_000, 20_000] {
        let segment = dir.join(format!("oversee-watch.log.{base}"));
        touch(&segment);
        set_modified(&segment, wall - 8 * day);
    }
    touch(&paths.log);
    touch(&wake::record_path(&world.fleet_path()));
    let pruned = world.pass(wall).unwrap();
    assert_eq!(
        pruned.segments,
        vec![
            dir.join("oversee-watch.log.0"),
            dir.join("oversee-watch.log.10000")
        ],
        "the newest segment carries the live log's numbering"
    );
    assert_eq!(
        pruned.records,
        vec!["KEN-A", "KEN-B", "KEN-G", "KEN-H"],
        "the records past their own recorded end, the fleet start's left out, the relaunched lane live"
    );
    let gone = |path: PathBuf| std::fs::symlink_metadata(&path).is_err();
    for item in ["KEN-0", "KEN-A", "KEN-B", "KEN-G", "KEN-H"] {
        assert!(
            gone(dir.join(format!("workflow-state-{item}.json"))),
            "{item}: the record pruned"
        );
        for path in [
            dir.join(format!("lane-status-{item}.md")),
            dir.join("handoffs").join(format!("{item}-handoff.md")),
        ] {
            assert!(!gone(path.clone()), "{}: the close-out's", path.display());
        }
        assert!(
            !gone(dir.join(format!("workflow-state-{item}.json.lock"))),
            "{item}: the record's lock stays"
        );
        assert!(
            !gone(dir.join("lane-mail").join(item).join("to-lane.jsonl")),
            "{item}: a mailbox written within the retention stays"
        );
    }
    for item in ["KEN-C", "KEN-D", "KEN-E", "KEN-R"] {
        for path in [
            dir.join(format!("workflow-state-{item}.json")),
            dir.join(format!("workflow-state-{item}.json.lock")),
            dir.join(format!("lane-status-{item}.md")),
            dir.join("handoffs").join(format!("{item}-handoff.md")),
        ] {
            assert!(!gone(path.clone()), "{} kept", path.display());
        }
    }
    for path in [
        wt("KEN-B").join("draft.txt"),
        wt("KEN-C").join("draft.txt"),
        wt("KEN-G").join("draft.txt"),
        wt("KEN-R").join("draft.txt"),
        dir.join("handoffs").join("KEN-F-handoff.md"),
        dir.join("handoffs").join("OVERSEER-HANDOFF.md"),
        dir.join("workflow-state-KEN-10.json"),
        dir.join("oversee-watch.log.20000"),
        paths.log.clone(),
        wake::record_path(&world.fleet_path()),
        world.fleet_path(),
    ] {
        assert!(!gone(path.clone()), "{} untouched", path.display());
    }
    // The judgement, record by record.
    let fleet = world.fleet();
    let lanes = fleet["lanes"].as_array().unwrap();
    let intents = fleet["intents"].as_array().unwrap();
    let rows = fleet["fleet_log"].as_array().unwrap();
    let cutoff = retention::cutoff(wall, 5);
    let judged: Vec<(String, Judgement)> = lanes
        .iter()
        .map(|l| {
            (
                l["item"].as_str().unwrap().to_owned(),
                retention::judge(l, intents, rows, dir, cutoff),
            )
        })
        .collect();
    assert_eq!(
        judged,
        vec![
            ("KEN-0".to_owned(), Judgement::Prune { kept: None }),
            ("KEN-A".to_owned(), Judgement::Prune { kept: None }),
            (
                "KEN-B".to_owned(),
                Judgement::Prune {
                    kept: Some("unmerged".to_owned())
                }
            ),
            ("KEN-C".to_owned(), Judgement::Keep),
            ("KEN-D".to_owned(), Judgement::Keep),
            ("KEN-E".to_owned(), Judgement::Keep),
            ("KEN-F".to_owned(), Judgement::Keep),
            ("KEN-G".to_owned(), Judgement::Prune { kept: None }),
            (
                "KEN-H".to_owned(),
                Judgement::Prune {
                    kept: Some("dirty".to_owned())
                }
            ),
            ("KEN-R".to_owned(), Judgement::Keep),
        ]
    );
    // The fleet transition in the dispatcher's shape: the named records go,
    // the first stays, the rows past the cutoff go, a row with no stamp
    // stays.
    let mut doc = match fleet {
        Value::Object(map) => map,
        other => panic!("{other}"),
    };
    let env = Env {
        now_secs: wall,
        now_nanos: u128::from(wall) * 1_000_000_000,
        nonce: 1,
        owner: None,
    };
    let request = PruneRecords {
        lanes: pruned.rows.clone(),
        cutoff,
    };
    let report = prune_records(&world.fleet_path(), &mut doc, &request, &env).unwrap();
    assert_eq!(
        report,
        RecordsPruned {
            lanes: vec![
                "KEN-A".into(),
                "KEN-B".into(),
                "KEN-G".into(),
                "KEN-H".into()
            ],
            confirmed: pruned.rows.iter().map(|r| r.item.clone()).collect(),
            fleet_log: 1,
        }
    );
    let left: Vec<&str> = doc["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["item"].as_str().unwrap())
        .collect();
    assert_eq!(
        left,
        vec!["KEN-0", "KEN-C", "KEN-D", "KEN-E", "KEN-F", "KEN-R"]
    );
    assert_eq!(doc["fleet_log"].as_array().unwrap().len(), 2);
    // A second pass finds nothing more to remove.
    let again = world.pass(wall).unwrap();
    assert_eq!(again.segments, Vec::<PathBuf>::new());
    assert_eq!(again.paths, Vec::<PathBuf>::new());
}

/// A successor re-applies a standing instruction it reads, so the prune
/// reaches only its two arrays. A standing instruction is a row of the
/// fleet record's `standing[]` and has no retention; the fixture's is older
/// than the cutoff, with a `fleet_log` row on each side of the cutoff. The
/// duty as the runner runs it, the record read back from the disk after the
/// store's write: the aged row and the closed lane's record leave, the
/// array is byte for byte what was written.
#[test]
fn retention_leaves_a_standing_instruction_older_than_the_cutoff_byte_for_byte() {
    let world = World::new();
    let paths = world.paths();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let old = clock::iso_utc(wall - 10 * 86_400);
    let recent = clock::iso_utc(wall - 86_400);
    let standing = json!([{"at": old, "id": "note-1", "scope": "fleet", "end": "until lifted",
                           "text": "the two-reviewer gate is waived for docs-only changes"}]);
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [],
        "lanes": [lane("KEN-0", "running", &old, json!({})), lane("KEN-A", "closed", &old, json!({}))],
        "fleet_log": [
            {"at": old, "kind": "ruling", "item": "KEN-A", "text": "old"},
            {"at": recent, "kind": "ruling", "item": "KEN-0", "text": "recent"}
        ],
        "standing": standing
    }));
    touch(&world.path().join("workflow-state-KEN-A.json"));
    let mut runner = runner(&world, &clock);
    runner.register(
        Duty::Retention,
        retention::body(retention::Context {
            locking: Locking::FLOCK,
            fleet: world.fleet_path(),
            paths: paths.clone(),
            settings: world.settings.clone(),
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
    });
    assert!(ended.is_ok(), "{ended:?}");
    let fleet = world.fleet();
    let texts = |key: &str, field: &str| -> Vec<String> {
        fleet[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| row[field].as_str().unwrap().to_owned())
            .collect()
    };
    assert_eq!(
        texts("fleet_log", "text"),
        vec!["recent"],
        "the row past the cutoff left"
    );
    assert_eq!(
        texts("lanes", "item"),
        vec!["KEN-0"],
        "the closed lane's record left"
    );
    assert_eq!(
        serde_json::to_string(&fleet["standing"]).unwrap(),
        serde_json::to_string(&standing).unwrap(),
        "the standing instruction, byte for byte"
    );
}

/// The duty wired as the runner runs it: a pass on the fake clock removes
/// what `pass` removes and prints nothing.
#[test]
fn the_retention_duty_prints_nothing_and_removes_through_the_runner() {
    let world = World::new();
    let paths = world.paths();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let old = clock::iso_utc(wall - 10 * 86_400);
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [lane("KEN-0", "running", &old, json!({})), lane("KEN-A", "closed", &old, json!({}))]
    }));
    touch(&world.path().join("workflow-state-KEN-A.json"));
    let mut runner = runner(&world, &clock);
    runner.register(
        Duty::Retention,
        retention::body(retention::Context {
            locking: Locking::FLOCK,
            fleet: world.fleet_path(),
            paths: paths.clone(),
            settings: world.settings.clone(),
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert!(std::fs::symlink_metadata(world.path().join("workflow-state-KEN-A.json")).is_err());
    assert_eq!(lines(&paths.log), Vec::<String>::new(), "nothing printed");
    let baseline = Baseline::load(&paths.baseline).unwrap();
    assert_eq!(baseline.passes.get(&Duty::Retention), Some(&wall));
}

/// `state init --fleet` writes no `lanes` and no `fleet_log`, and an array
/// read that inserts the absent key would change the document. The duty on
/// the fake clock over the record as `state init` writes it: the pass is
/// stamped and the file's bytes are as before.
#[test]
fn a_first_retention_pass_over_a_fresh_fleet_record_writes_nothing() {
    let world = World::new();
    let paths = world.paths();
    std::fs::remove_file(world.fleet_path()).unwrap();
    state::init(&world.fleet_path(), &InitFields::default()).unwrap();
    let before = std::fs::read_to_string(world.fleet_path()).unwrap();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let mut runner = runner(&world, &clock);
    runner.register(
        Duty::Retention,
        retention::body(retention::Context {
            locking: Locking::FLOCK,
            fleet: world.fleet_path(),
            paths: paths.clone(),
            settings: world.settings.clone(),
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
    });
    assert!(ended.is_ok(), "{ended:?}");
    let baseline = Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.passes.get(&Duty::Retention),
        Some(&wall),
        "the pass ran"
    );
    assert_eq!(
        std::fs::read_to_string(world.fleet_path()).unwrap(),
        before,
        "the fleet record's bytes"
    );
}

/// The paths an archive holds, as `tar` lists them, each relative to `/`.
fn archived(archive: &Path) -> Vec<String> {
    let out = program("tar")
        .args(["-tzf", &archive.display().to_string()])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_owned)
        .collect()
}

fn relative(path: &Path) -> String {
    path.strip_prefix("/").unwrap().display().to_string()
}

/// The effect, the reconcile and the mailbox still read an open intent's
/// receipt and request, a brief, a closed intent's notice and a file no
/// intent names, and a unit removed with no archive is its only copy's end.
/// One pass over an open intent and a closed one, each with files older
/// than the cutoff, unnamed files under `intents/`, the handoff files and
/// the progress reports: only the closed intent's receipt, request and job
/// record and the stamped reports leave, and the archive the pass names
/// holds every path that left.
#[test]
fn retention_keeps_an_open_intents_files_and_archives_every_unit_that_leaves() {
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let day = 86_400;
    let old = clock::iso_utc(wall - 10 * day);
    let dir = world.path();
    let intents = dir.join("intents");
    let brief = intents.join("start-controller.20260101T000000Z.7.brief");
    let mut held = lane_intent("launch-session", "KEN-1", "not-started", None);
    held["phase"] = json!({"phase": "opening", "server": 1, "server_start": 1, "socket": "/none",
                           "since_ms": 0, "brief": brief.display().to_string()});
    let mut closed = lane_intent("close-resources", "KEN-2", "confirmed", None);
    closed["completed_at"] = json!(old);
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [lane("KEN-0", "running", &old, json!({}))],
        "intents": [held, closed]
    }));
    let stands = [
        intents.join("launch-session:KEN-1:1-1.pane"),
        intents.join("launch-session:KEN-1:1-1.request"),
        brief.clone(),
        intents.join("close-resources:KEN-2:1-1.notice"),
        intents.join("close-resources:KEN-2:1-1.pane.tmp"),
        intents.join("stray.pane"),
        intents.join("fresh.pane"),
        dir.join("handoffs").join("OVERSEER-HANDOFF.md"),
        dir.join("handoffs").join("session-1.md"),
        dir.join("tmp").join("progress-reports").join("notes.md"),
    ];
    let leaves = [
        intents.join("close-resources:KEN-2:1-1.pane"),
        intents.join("close-resources:KEN-2:1-1.request"),
        intents.join("close-resources:KEN-2:1-1.job"),
        dir.join("tmp")
            .join("progress-reports")
            .join("01-01-00-00.md"),
        dir.join("tmp")
            .join("progress-reports")
            .join("12-31-23-59-succession.md"),
    ];
    for path in stands.iter().chain(&leaves) {
        touch(path);
        set_modified(path, wall - 10 * day);
    }
    set_modified(&intents.join("fresh.pane"), wall - day);
    let pruned = world.pass(wall).unwrap();
    for path in &stands {
        assert!(
            std::fs::symlink_metadata(path).is_ok(),
            "{} stands",
            path.display()
        );
    }
    for path in &leaves {
        assert!(
            std::fs::symlink_metadata(path).is_err(),
            "{} left",
            path.display()
        );
    }
    let archive = pruned.archive.expect("the archive the pass wrote");
    let name = archive.file_name().unwrap().to_string_lossy().into_owned();
    assert!(
        archive.starts_with(dir.join("fleet").join("archive"))
            && name.starts_with(&format!("prune-{wall}-"))
            && name.ends_with(".tgz"),
        "{}",
        archive.display()
    );
    let listed = archived(&archive);
    for path in &leaves {
        let want = relative(path);
        assert!(listed.contains(&want), "{want} archived: {listed:?}");
    }
    assert!(
        listed.iter().any(|p| p.ends_with("/records.json")),
        "the records file: {listed:?}"
    );
    assert_eq!(
        pruned.paths.len(),
        leaves.len(),
        "every unit that left, and nothing else: {:?}",
        pruned.paths
    );
}

/// A pane can write its receipt after its intent was closed by hand, and
/// the watch would read that live pane as a stray once the receipt left. A
/// launch closed ten days ago, its request as old and its receipt written a
/// minute ago: the request leaves and the receipt stands.
#[test]
fn retention_keeps_a_receipt_written_after_its_intent_closed() {
    let world = World::new();
    let wall = FakeClock::new().wall_secs();
    let mut closed = lane_intent("launch-session", "KEN-3", "failed", None);
    closed["completed_at"] = json!(clock::iso_utc(wall - 10 * 86_400));
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [], "intents": [closed]
    }));
    let intents = world.path().join("intents");
    let request = intents.join("launch-session:KEN-3:1-1.request");
    touch(&request);
    set_modified(&request, wall - 10 * 86_400);
    let receipt = intents.join("launch-session:KEN-3:1-1.pane");
    touch(&receipt);
    set_modified(&receipt, wall - 60);
    let pruned = world.pass(wall).unwrap();
    assert_eq!(pruned.paths.len(), 1, "{:?}", pruned.paths);
    assert!(!request.exists(), "the superseded request leaves");
    assert!(receipt.exists(), "the late receipt stands");
}

/// The duty as the runner runs it, over the real mailbox program at the
/// main checkout: a compaction that answers is a pass that ran, and one the
/// program refuses, there a second overseer mailbox spelled apart by case,
/// says `watch-step-failed` while a file past the retention still leaves.
#[test]
fn the_retention_duty_compacts_the_overseer_mailbox_and_says_a_refusal() {
    let world = World::new();
    let paths = world.paths();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let body = || {
        retention::body(retention::Context {
            locking: Locking::FLOCK,
            fleet: world.fleet_path(),
            paths: paths.clone(),
            settings: world.settings.clone(),
        })
    };
    let baseline = Baseline::default();
    let answered = body()(&Tick {
        duty: Duty::Retention,
        now: clock.now(),
        wall,
        baseline: &baseline,
        clock: &clock,
    })
    .unwrap();
    assert_eq!(answered.failed, None, "the compaction answered");
    let old = world.path().join("workflow-state-KEN-9.json");
    std::fs::write(&old, "{}\n").unwrap();
    set_modified(&old, wall - 10 * 86_400);
    std::fs::create_dir_all(world.path().join("tmp/lane-mail/Overseer")).unwrap();
    let mut runner = runner(&world, &clock);
    runner.register(Duty::Retention, body());
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(
        lines(&paths.log),
        vec!["EVENT watch-step-failed step=retention count=1".to_owned()]
    );
    assert!(std::fs::symlink_metadata(&old).is_err(), "the prune ran");

    // A world inside a checkout whose private file names a retention the
    // program refuses: the mailbox, started in the world, reads no project
    // root above it, so the compaction answers.
    let canary = tempfile::tempdir().unwrap();
    for args in [
        vec!["init", "--quiet"],
        vec!["config", "gc.auto", "0"],
        vec!["config", "maintenance.auto", "false"],
    ] {
        let out = program("git")
            .arg("-C")
            .arg(canary.path())
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
    std::fs::write(
        canary.path().join(".env.local"),
        "ORCH_RECORD_RETENTION_DAYS=0\n",
    )
    .unwrap();
    let world = World::new_in(canary.path());
    let answered = retention::body(retention::Context {
        locking: Locking::FLOCK,
        fleet: world.fleet_path(),
        paths: world.paths(),
        settings: world.settings.clone(),
    })(&Tick {
        duty: Duty::Retention,
        now: clock.now(),
        wall,
        baseline: &baseline,
        clock: &clock,
    })
    .unwrap();
    assert_eq!(
        answered.failed, None,
        "the checkout above the world is not read"
    );
}

/// The real program `name` on this host's `PATH`, which a fixture execs.
fn real(name: &str) -> String {
    let out = program("sh")
        .args(["-c", &format!("command -v {name}")])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A record a writer holds mid-update, or one written since the pass judged
/// it, stands. A stale record with no lane record and no worktree, the
/// shell store's `update` held between its locked read and its move by a
/// `jq` that waits for a release; the pass starts and is released into
/// after the writer: the update lands and the record stands.
#[test]
fn retention_leaves_an_item_record_a_shell_writer_holds() {
    let world = World::new();
    let wall = FakeClock::new().wall_secs();
    let record = world.path().join("workflow-state-KEN-9.json");
    std::fs::write(&record, "{\"issue_id\":\"KEN-9\"}\n").unwrap();
    set_modified(&record, wall - 10 * 86_400);
    let tools = world.path().join("bin");
    std::fs::create_dir(&tools).unwrap();
    let jq = tools.join("jq");
    write_executable(
        &jq,
        r#"#!/bin/sh
case "$*" in
  *late*)
    "$REAL_JQ" "$@" > "$HOLD_CAPTURE" || exit 1
    : > "$HOLD_READY"
    n=0
    while [ ! -e "$HOLD_RELEASE" ]; do
      n=$((n + 1))
      [ "$n" -lt 3000 ] || exit 1
      sleep 0.01
    done
    cat "$HOLD_CAPTURE" ;;
  *) exec "$REAL_JQ" "$@" ;;
esac
"#,
    );
    let ready = world.path().join("ready");
    let release = world.path().join("release");
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/workflow-state");
    let mut writer = program(&script);
    writer
        .args(["--no-private-env", "--state-dir"])
        .arg(world.path())
        .args(["update", "KEN-9", ".late = \"held\""])
        .env("PATH", tool_path(&[tools.as_path()]))
        .env("REAL_JQ", real("jq"))
        .env("HOLD_READY", &ready)
        .env("HOLD_RELEASE", &release)
        .env("HOLD_CAPTURE", world.path().join("captured"))
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped());
    let mut writer = Owned(writer.spawn().unwrap());
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    while !ready.exists() {
        assert!(
            std::time::Instant::now() < deadline,
            "the writer reached its locked read"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let pruned = std::thread::scope(|s| {
        let pass = s.spawn(|| world.pass(wall));
        // Bounded, and only the control's reach depends on it: a pass that
        // has not reached the lock by then waits on it all the same.
        let held = std::time::Instant::now() + Duration::from_secs(2);
        while std::time::Instant::now() < held && !pass.is_finished() {
            std::thread::sleep(Duration::from_millis(50));
        }
        std::fs::write(&release, "").unwrap();
        pass.join().unwrap()
    })
    .unwrap();
    let status = writer.0.wait().unwrap();
    let mut cause = String::new();
    std::io::Read::read_to_string(&mut writer.0.stderr.take().unwrap(), &mut cause).unwrap();
    assert!(status.success(), "the writer's update: {cause}");
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
    assert_eq!(doc["late"], "held");
    assert!(!pruned.paths.contains(&record), "{:?}", pruned.paths);
}

/// One record whose lock stays held, a stale mutex on a host without
/// `flock`, fails no other record's retention. The duty as the runner runs
/// it under the mutex policy with a short wait, over an old record whose
/// `.lock.d` stands and another old record: the pass says
/// `watch-step-failed`, the record and its mutex stand for the next pass,
/// and the other record leaves.
#[test]
fn a_record_whose_lock_stays_held_keeps_its_item_and_the_pass_takes_the_rest() {
    let world = World::new();
    let paths = world.paths();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let record = world.path().join("workflow-state-KEN-S.json");
    std::fs::write(&record, "{}\n").unwrap();
    set_modified(&record, wall - 10 * 86_400);
    let mutex = world.path().join("workflow-state-KEN-S.json.lock.d");
    std::fs::create_dir(&mutex).unwrap();
    let scratch = world.path().join("workflow-state-KEN-T.json");
    std::fs::write(&scratch, "{}\n").unwrap();
    set_modified(&scratch, wall - 10 * 86_400);
    let mut runner = runner(&world, &clock);
    runner.register(
        Duty::Retention,
        retention::body(retention::Context {
            locking: Locking {
                wait: Wait {
                    limit: Duration::from_millis(200),
                    poll: Duration::from_millis(20),
                    timer: &SystemClock,
                },
                mkdir_mutex: true,
            },
            fleet: world.fleet_path(),
            paths: paths.clone(),
            settings: world.settings.clone(),
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(
        lines(&paths.log),
        vec!["EVENT watch-step-failed step=retention count=1".to_owned()]
    );
    assert!(record.exists() && mutex.exists());
    assert!(
        std::fs::symlink_metadata(&scratch).is_err(),
        "the pass went on"
    );
}

/// A lock taken with its record would let a holder of the unlinked inode
/// and a newcomer on a new one both hold the lock once the key is created
/// again. An old item record with its old lock and mutex: the record
/// leaves; its lock and mutex stand.
#[test]
fn no_lock_file_leaves_and_a_record_leaves_without_its_lock() {
    let world = World::new();
    let wall = FakeClock::new().wall_secs();
    let dir = world.path();
    let record = dir.join("workflow-state-KEN-9.json");
    std::fs::write(&record, "{}\n").unwrap();
    let record_lock = dir.join("workflow-state-KEN-9.json.lock");
    touch(&record_lock);
    let record_mutex = dir.join("workflow-state-KEN-9.json.lock.d");
    std::fs::create_dir(&record_mutex).unwrap();
    for path in [&record, &record_lock, &record_mutex] {
        set_modified(path, wall - 10 * 86_400);
    }
    let pruned = world.pass(wall).unwrap();
    assert!(!record.exists() && record_lock.exists() && record_mutex.exists());
    assert_eq!(pruned.paths, vec![record.clone()], "{:?}", pruned.paths);
}

/// A relaunch during the archive turns the ended lane live, and the pass
/// keeps what the fleet moved under its judgement. The duty's body, its
/// `tar` updating the lane to `running` under a new session and appending a
/// mailbox turn before it archives: the live row, the record and the
/// mailbox all stand.
#[test]
fn retention_keeps_a_lane_relaunched_during_its_archive() {
    if std::env::var_os("RELAUNCH_CHILD").is_none() {
        // The archive's `tar` is found on this process's `PATH`: the row
        // runs again as a child with the fixture first on it.
        let dir = tempfile::tempdir().unwrap();
        let shim = dir.path().join("tar");
        write_executable(
            &shim,
            r#"#!/bin/bash
set -euo pipefail
args=("$@")
while [[ "$1" != -T ]]; do shift; done
record=$(grep 'workflow-state-KEN-9.json$' "$2")
state="/${record%/*}"
/bin/bash "$STORE" --no-private-env --state-dir "$state" update oversee '.lanes[1].status = "running" | .lanes[1].session_since = "new-session"'
printf 'new turn\n' >> "$state/lane-mail/KEN-9/to-lane.jsonl"
exec "$REAL_TAR" "${args[@]}"
"#,
        );
        let out = program(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "retention_keeps_a_lane_relaunched_during_its_archive",
                "--nocapture",
            ])
            .env("RELAUNCH_CHILD", "1")
            .env("PATH", tool_path(&[dir.path()]))
            .env("REAL_TAR", real("tar"))
            .env(
                "STORE",
                Path::new(env!("CARGO_MANIFEST_DIR")).join("../scripts/workflow-state"),
            )
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let old = clock::iso_utc(wall - 10 * 86_400);
    world.write_fleet(&json!({
        "issue_id": "oversee", "launch_queue": [], "fleet_log": [],
        "lanes": [lane("KEN-0", "running", &old, json!({})), lane("KEN-9", "done", &old, json!({}))]
    }));
    let record = world.path().join("workflow-state-KEN-9.json");
    std::fs::write(&record, "{\"issue_id\":\"KEN-9\"}\n").unwrap();
    set_modified(&record, wall - 10 * 86_400);
    let mailbox = world.path().join("lane-mail/KEN-9");
    touch(&mailbox.join("to-lane.jsonl"));
    set_modified(&mailbox.join("to-lane.jsonl"), wall - 10 * 86_400);
    set_modified(&mailbox, wall - 10 * 86_400);
    let baseline = Baseline::default();
    let tick = Tick {
        duty: Duty::Retention,
        now: clock.now(),
        wall,
        baseline: &baseline,
        clock: &clock,
    };
    let mut body = retention::body(retention::Context {
        fleet: world.fleet_path(),
        paths: world.paths(),
        settings: world.settings.clone(),
        locking: Locking::FLOCK,
    });
    let produced = body(&tick);
    assert!(produced.is_ok(), "{produced:?}");
    let fleet = world.fleet();
    assert!(
        fleet["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["item"] == "KEN-9" && row["status"] == "running"),
        "{fleet}"
    );
    assert!(record.exists() && mailbox.exists());
}

/// The judgement's rows of an ended lane, and the fleet record holding that
/// lane relaunched: nothing leaves and the item is not confirmed; the
/// unmoved item's rows leave.
#[test]
fn prune_records_drops_no_row_moved_since_the_judgement() {
    let world = World::new();
    let ended = lane("KEN-9", "done", "2026-01-01T00:00:00Z", json!({}));
    let unmoved = lane("KEN-8", "done", "2026-01-01T00:00:00Z", json!({}));
    let mut relaunched = ended.clone();
    relaunched["status"] = json!("running");
    let fleet = json!({
        "issue_id": "oversee",
        "lanes": [lane("KEN-0", "running", "2026-01-01T00:00:00Z", json!({})), relaunched, unmoved.clone()]
    });
    let Value::Object(mut doc) = fleet else {
        unreachable!()
    };
    let request = PruneRecords {
        lanes: vec![
            PlannedRows {
                item: "KEN-9".into(),
                rows: vec![ended],
                drop: true,
            },
            PlannedRows {
                item: "KEN-8".into(),
                rows: vec![unmoved],
                drop: true,
            },
        ],
        cutoff: 0,
    };
    let env = Env {
        now_secs: 0,
        now_nanos: 0,
        nonce: 1,
        owner: None,
    };
    let report = prune_records(&world.fleet_path(), &mut doc, &request, &env).unwrap();
    assert_eq!(report.confirmed, vec!["KEN-8".to_owned()]);
    assert_eq!(report.lanes, vec!["KEN-8".to_owned()]);
    let left: Vec<(&str, &str)> = doc["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| (l["item"].as_str().unwrap(), l["status"].as_str().unwrap()))
        .collect();
    assert_eq!(left, vec![("KEN-0", "running"), ("KEN-9", "running")]);
}

/// The overseer or the successor bound to a session rows file still reads
/// it after its pane is gone. Four files of panes the private ambient
/// server does not hold, three named by `overseer.session_rows`,
/// `overseer.pending.session_rows` and `pending.session_rows`: only the
/// unnamed one leaves.
#[test]
fn retention_keeps_a_session_rows_file_the_fleet_names() {
    if std::env::var_os("NAMED_ROWS_CHILD").is_none() {
        // The pane read goes to the ambient server `TMUX` names: the row
        // runs again as a child whose `TMUX` is a private server's.
        let dir = tempfile::tempdir().unwrap();
        let server = Server::start(dir.path(), "named");
        let out = program(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "retention_keeps_a_session_rows_file_the_fleet_names",
                "--nocapture",
            ])
            .env("NAMED_ROWS_CHILD", "1")
            .env(
                "TMUX",
                format!("{},{},0", server.socket.display(), server.pid),
            )
            .env("ROWS_SERVER", server.pid.to_string())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let world = World::new();
    let wall = FakeClock::new().wall_secs();
    let pid: u32 = std::env::var("ROWS_SERVER").unwrap().parse().unwrap();
    let overseer = world.path().join("tmp/lane-mail/overseer");
    std::fs::create_dir_all(&overseer).unwrap();
    let rows = |pane: u32| {
        let file = overseer.join(format!("session-{pid}-{pane}.jsonl"));
        std::fs::write(&file, "{}\n").unwrap();
        file.display().to_string()
    };
    let named = [rows(99_991), rows(99_992), rows(99_993)];
    let unnamed = rows(99_994);
    world.write_fleet(&json!({
        "issue_id": "oversee", "launch_queue": [], "lanes": [], "fleet_log": [],
        "overseer": {"session_rows": named[0], "pending": {"session_rows": named[1]}},
        "pending": {"session_rows": named[2]}
    }));
    let pruned = world.pass(wall).unwrap();
    assert_eq!(pruned.paths, vec![PathBuf::from(&unnamed)]);
    for file in &named {
        assert!(Path::new(file).exists(), "{file}");
    }
}

/// An ended lane's row leaves once its item's files are gone, though no
/// file names the item any more. An ended lane whose item `state remove`
/// closed out: two duty passes, and the row has left.
#[test]
fn retention_retires_an_ended_row_without_remaining_files() {
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let old = clock::iso_utc(wall - 10 * 86_400);
    world.write_fleet(&json!({
        "issue_id": "oversee", "launch_queue": [], "fleet_log": [],
        "lanes": [lane("KEN-0", "running", &old, json!({})), lane("KEN-9", "done", &old, json!({}))]
    }));
    let record = world.path().join("workflow-state-KEN-9.json");
    std::fs::write(&record, "{\"issue_id\":\"KEN-9\"}\n").unwrap();
    let removed = isolated()
        .arg("--state-dir")
        .arg(world.path())
        .args(["state", "remove", "--item", "KEN-9"])
        .env("FLEET_DIR", world.path().join("fleet"))
        .current_dir(world.path())
        .output()
        .unwrap();
    assert!(
        removed.status.success(),
        "{}",
        String::from_utf8_lossy(&removed.stderr)
    );
    assert!(!record.exists());
    for _ in 0..2 {
        let baseline = Baseline::default();
        let tick = Tick {
            duty: Duty::Retention,
            now: clock.now(),
            wall,
            baseline: &baseline,
            clock: &clock,
        };
        let mut body = retention::body(retention::Context {
            fleet: world.fleet_path(),
            paths: world.paths(),
            settings: world.settings.clone(),
            locking: Locking::FLOCK,
        });
        assert!(body(&tick).is_ok());
    }
    assert!(
        !world.fleet()["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["item"] == "KEN-9"),
        "the ended row left"
    );
}

/// The duty's body over `world` with `settings`, once, at `wall`.
fn duty_pass(world: &World, settings: &Settings, clock: &FakeClock, wall: u64) {
    let baseline = Baseline::default();
    let tick = Tick {
        duty: Duty::Retention,
        now: clock.now(),
        wall,
        baseline: &baseline,
        clock,
    };
    let mut body = retention::body(retention::Context {
        fleet: world.fleet_path(),
        paths: world.paths(),
        settings: settings.clone(),
        locking: Locking::FLOCK,
    });
    let produced = body(&tick);
    assert!(produced.is_ok(), "{produced:?}");
}

fn ended_lane_world(world: &World, wall: u64) -> PathBuf {
    let old = clock::iso_utc(wall - 10 * 86_400);
    world.write_fleet(&json!({
        "issue_id": "oversee", "launch_queue": [], "fleet_log": [],
        "lanes": [lane("KEN-0", "running", &old, json!({})), lane("KEN-9", "done", &old, json!({}))]
    }));
    let record = world.path().join("workflow-state-KEN-9.json");
    std::fs::write(&record, "{\"issue_id\":\"KEN-9\"}\n").unwrap();
    set_modified(&record, wall - 10 * 86_400);
    record
}

/// The pass removes only the kinds it names: a writer it does not serialize
/// can still write or bind every other entry of the state directory, and a
/// later pass keeps them once their item's record and row are gone. An
/// ended lane and an expired item with no lane, each with its record past
/// the retention, and every such entry ten days old: the two records and
/// the row leave, and through a second pass everything else stands.
#[test]
fn retention_removes_only_the_kinds_it_names_and_every_other_entry_stands() {
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let record = ended_lane_world(&world, wall);
    let dir = world.path();
    let expired = dir.join("workflow-state-KEN-5.json");
    std::fs::write(&expired, "{}\n").unwrap();
    set_modified(&expired, wall - 10 * 86_400);
    let stays = [
        dir.join("completion-summary-KEN-5.md"),
        dir.join("audit-KEN-5.json"),
        dir.join("lane-status-KEN-9.md"),
        dir.join("dev-round-KEN-9-r1.json"),
        dir.join("lane-wake-KEN-9.log"),
        dir.join("wall-relaunch-KEN-9.log"),
        dir.join("completion-summary-KEN-9.md"),
        dir.join("handoffs").join("KEN-9-handoff.md"),
        dir.join("model-handoff.abcdef"),
        dir.join("lane-mail").join("KEN-9").join("to-lane.jsonl"),
        dir.join("oversee-watch")
            .join("claims")
            .join("claim.ABCDEF.claim"),
        dir.join("directive-send").join("KEN-2.r0.json"),
        dir.join("overseer-wake-unread.txt"),
        dir.join("mutstab-diag").join("run.log"),
    ];
    for path in &stays {
        touch(path);
        for at in path.ancestors().take_while(|at| *at != dir) {
            set_modified(at, wall - 10 * 86_400);
        }
    }
    duty_pass(&world, &world.settings, &clock, wall);
    assert!(!record.exists(), "the ended lane's record leaves");
    assert!(!expired.exists(), "the expired item's record leaves");
    assert!(
        !world.fleet()["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["item"] == "KEN-9"),
        "the row leaves"
    );
    for path in &stays {
        assert!(path.exists(), "{} stands", path.display());
    }
    duty_pass(&world, &world.settings, &clock, wall);
    for path in &stays {
        assert!(path.exists(), "next pass: {} stands", path.display());
    }
}

/// An item state that names a linked worktree, or a branch a linked
/// worktree has checked out, stands while the lane works there, and one
/// naming nothing that stands ages out. The twelve shapes a workflow state
/// names a worktree in, on a repository with linked worktrees, one pass:
/// each state is kept or removed as the table says. The pass reads the
/// worktrees through `git` by name, in this process, so the row runs as a
/// child under the isolated environment and that `git` reads no
/// configuration of the operator's.
#[test]
fn retention_keeps_an_item_state_that_names_a_standing_linked_worktree_and_takes_the_rest() {
    if std::env::var_os("ISOLATED_CHILD").is_none() {
        let out = program(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "retention_keeps_an_item_state_that_names_a_standing_linked_worktree_and_takes_the_rest",
                "--nocapture",
            ])
            .env("ISOLATED_CHILD", "1")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(
            out.status.success() && String::from_utf8_lossy(&out.stdout).contains("1 passed"),
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let day = 86_400;
    let project = world.path();
    let git = |args: &[&str]| {
        let out = program("git")
            .args(["-C", &project.display().to_string()])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    };
    git(&["init", "-q", "-b", "main"]);
    git(&["config", "gc.auto", "0"]);
    git(&["config", "commit.gpgsign", "false"]);
    git(&["commit", "-q", "--allow-empty", "-m", "base"]);
    git(&["branch", "ken-4"]);
    git(&["branch", "ken-6"]);
    let trees = project.join("trees");
    for name in ["ken-1", "other-2", "ken-3", "ken-5", "ken-12"] {
        git(&[
            "worktree",
            "add",
            "-q",
            "-b",
            name,
            &trees.join(name).display().to_string(),
            "main",
        ]);
    }
    std::fs::remove_dir_all(trees.join("ken-12")).unwrap();
    let quoted = trees.join("ken-q\ntree");
    git(&[
        "worktree",
        "add",
        "-q",
        "-b",
        "ken-11",
        &quoted.display().to_string(),
        "main",
    ]);
    let plain = project.join("plain");
    std::fs::create_dir(&plain).unwrap();
    let at = |p: &Path| p.display().to_string();
    let shapes: [(&str, Value, bool); 12] = [
        (
            "KEN-1",
            json!({"worktree": at(&trees.join("ken-1")), "branch": "ken-1"}),
            true,
        ),
        (
            "KEN-2",
            json!({"worktree": at(&trees.join("other-2"))}),
            true,
        ),
        (
            "KEN-3",
            json!({"worktree": at(&trees.join("gone-3")), "branch": "ken-3"}),
            true,
        ),
        (
            "KEN-4",
            json!({"worktree": at(&trees.join("gone-4")), "branch": "ken-4"}),
            false,
        ),
        ("KEN-5", json!({"branch": "ken-5"}), true),
        ("KEN-6", json!({"branch": "ken-6"}), false),
        ("KEN-7", json!({"branch": "main"}), false),
        (
            "KEN-8",
            json!({"worktree": at(project), "branch": "main"}),
            false,
        ),
        ("KEN-9", json!({}), false),
        ("KEN-10", json!({"worktree": at(&plain)}), false),
        ("KEN-11", json!({"worktree": at(&quoted)}), true),
        ("KEN-12", json!({"branch": "ken-12"}), false),
    ];
    for (item, state, _) in &shapes {
        let path = project.join(format!("workflow-state-{item}.json"));
        std::fs::write(&path, serde_json::to_string(state).unwrap()).unwrap();
        set_modified(&path, wall - 10 * day);
    }
    world.pass(wall).unwrap();
    for (item, _, kept) in &shapes {
        let name = format!("workflow-state-{item}.json");
        assert_eq!(
            std::fs::symlink_metadata(project.join(&name)).is_ok(),
            *kept,
            "{name} kept={kept}"
        );
    }
}

#[test]
fn report_owner_notice_waits_for_quiet_end_and_keeps_the_last_sent_window() {
    let world = World::new();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-10-01T06:00:00Z"}]}));
    let ctx = world.report_context();
    std::fs::create_dir_all(&ctx.settings.store.progress_report_dir).unwrap();
    let noise = ctx.settings.store.progress_report_dir.join("unrelated.txt");
    std::fs::write(&noise, "Another owner notice.").unwrap();
    let notice = program(world.real_report_mail())
        .current_dir(world.path())
        .args(["notice", "--item", "overseer", "--to", "owner", "--root"])
        .arg(world.path())
        .arg("--file")
        .arg(&noise)
        .arg("--attach")
        .arg(&noise)
        .output()
        .unwrap();
    assert!(
        notice.status.success(),
        "{}",
        String::from_utf8_lossy(&notice.stderr)
    );
    let summary = world.path().join("summary.txt");
    std::fs::write(&summary, "Work completed.\nWaiting on you: Nothing.\n").unwrap();
    let night = epoch("2026-10-01T09:00:00Z");
    let morning = epoch("2026-10-01T14:00:00Z");
    let night_report = report::write(&ctx, night, &summary, false).unwrap();
    assert!(night_report["notice_id"].is_null(), "{night_report}");
    // The same quiet report again under its standing name refuses, never
    // overwritten.
    assert_eq!(
        report::write(&ctx, night, &summary, false)
            .unwrap_err()
            .fields(),
        vec![("cause".to_owned(), "report-exists".to_owned())]
    );
    let mail = orch_runtime::mailbox::Mailbox::new(ctx.settings.lane_mail_cli.clone());
    assert_eq!(
        mail.events(world.path())
            .unwrap()
            .iter()
            .filter(|e| e.kind() == "notice")
            .count(),
        1
    );
    // A session's due counts from the last sent report, never the quiet
    // night file after it.
    let session = report::Session {
        start: epoch("2026-10-01T06:00:00Z"),
        fleet: None,
    };
    assert_eq!(
        report::due(&ctx, morning, Some(&session)).unwrap(),
        Some("report-due reason=minutes since=2026-10-01T06:00:00Z".to_owned())
    );
    let clock = FakeClock::new();
    let mut baseline = Baseline::default();
    let mut body = report::body(world.report_context());
    let produced = pass(Duty::Report, &mut body, &mut baseline, &clock, morning).unwrap();
    assert_eq!(
        rendered(&produced)[0],
        "EVENT report-due reason=minutes since=2026-10-01T06:00:00Z"
    );
    let sent = report::write(&ctx, morning, &summary, false).unwrap();
    assert!(sent["notice_id"].as_str().is_some(), "{sent}");
    let events = mail.events(world.path()).unwrap();
    let notice = events
        .iter()
        .find(|e| e.attach.as_deref() == sent["path"].as_str())
        .unwrap();
    assert_eq!(notice.attach.as_deref(), sent["path"].as_str());
    assert_eq!(
        notice.text.as_deref(),
        Some("Work completed.\nWaiting on you: Nothing.")
    );
    assert_eq!(report::due(&ctx, morning + 60, None).unwrap(), None);
    let body = sent["body"].as_str().unwrap();
    assert!(body.contains(
        "Issues created: unread; source: Linear, all teams; window: 2026-10-01T06:00:00Z"
    ));
    assert_eq!(
        std::fs::read_to_string(sent["path"].as_str().unwrap()).unwrap(),
        body
    );
    let attempt = Path::new(sent["path"].as_str().unwrap()).with_extension("notice.json");
    assert!(
        !attempt.exists(),
        "a delivered report keeps no attempt record"
    );
    let retry = report::write(&ctx, morning, &summary, false).unwrap_err();
    assert_eq!(
        retry.fields(),
        vec![("cause".to_owned(), "report-exists".to_owned())]
    );
    assert_eq!(
        mail.events(world.path())
            .unwrap()
            .iter()
            .filter(|e| e.kind() == "notice")
            .count(),
        2
    );
    std::fs::write(&summary, "Different summary.").unwrap();
    assert!(report::write(&ctx, morning, &summary, false).is_err());
    assert_eq!(
        std::fs::read_to_string(sent["path"].as_str().unwrap()).unwrap(),
        body
    );
    assert!(
        !body.contains("Work completed."),
        "the summary is the notice's alone"
    );
    // A summary that is missing or holds nothing refuses before any read.
    let later = morning + 120;
    let empty = world.path().join("empty.txt");
    std::fs::write(&empty, "\n\n").unwrap();
    assert_eq!(
        report::write(&ctx, later, &empty, false)
            .unwrap_err()
            .fields(),
        vec![("cause".to_owned(), "summary-empty".to_owned())]
    );
    let missing = world.path().join("missing.txt");
    let fields = report::write(&ctx, later, &missing, false)
        .unwrap_err()
        .fields();
    assert_eq!(
        fields[0],
        ("summary".to_owned(), missing.display().to_string())
    );
    // A summary naming an owner ask that closed before the write refuses,
    // writing and sending nothing; one naming the asks still pending writes.
    let lane_mail = |args: &[&str]| {
        let out = program(world.real_report_mail())
            .current_dir(world.path())
            .args(args)
            .arg("--root")
            .arg(world.path())
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", stderr(&out));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    let question = world.path().join("question.txt");
    let ask = |text: &str| {
        std::fs::write(&question, text).unwrap();
        let printed = lane_mail(&[
            "ask",
            "--item",
            "overseer",
            "--to",
            "owner",
            "--options",
            "yes,no",
            "--recommend",
            "yes",
            "--file",
            question.to_str().unwrap(),
        ]);
        printed
            .lines()
            .find_map(|l| l.strip_prefix("id="))
            .unwrap()
            .to_owned()
    };
    let open = ask("Ship it?\n");
    let closed = ask("Rename it?\n");
    lane_mail(&["resolve", "--item", "overseer", "--id", &closed]);
    let named = morning + 180;
    std::fs::write(
        &summary,
        format!("Waiting on you: {open}, then {closed}.\n"),
    )
    .unwrap();
    let sent_before = mail.events(world.path()).unwrap().len();
    assert_eq!(
        report::write(&ctx, named, &summary, false)
            .unwrap_err()
            .fields(),
        vec![
            ("cause".to_owned(), "summary-stale".to_owned()),
            ("ask".to_owned(), closed.clone()),
        ]
    );
    let dir = &ctx.settings.store.progress_report_dir;
    assert!(!dir.join("10-01-14-03.md").exists());
    assert!(!dir.join("10-01-14-03.notice.json").exists());
    assert_eq!(mail.events(world.path()).unwrap().len(), sent_before);
    std::fs::write(&summary, format!("Waiting on you: {open}.\n")).unwrap();
    report::write(&ctx, named, &summary, false).unwrap();
    // ORCH_REPORT=off silences due alone: a handover write still writes,
    // under its succession name, its notice the summary less its trailing
    // blank lines.
    let mut off = world.report_context();
    set_report(&mut off, report::ENABLED_KEY, "off");
    std::fs::write(&summary, "The overseer hands over.\n\n\n").unwrap();
    let handed = report::write(&off, later, &summary, true).unwrap();
    assert!(
        handed["path"]
            .as_str()
            .unwrap()
            .ends_with("10-01-14-02-succession.md"),
        "{handed}"
    );
    let events = mail.events(world.path()).unwrap();
    let notice = events
        .iter()
        .find(|e| e.attach.as_deref() == handed["path"].as_str())
        .unwrap();
    assert_eq!(notice.text.as_deref(), Some("The overseer hands over."));
    let notices = mail
        .events(world.path())
        .unwrap()
        .iter()
        .filter(|e| e.kind() == "notice")
        .count();
    std::fs::write(world.fleet_path(), "{\"lanes\": [").unwrap();
    std::fs::write(&summary, "Nothing to render.").unwrap();
    assert!(report::write(&ctx, morning + 240, &summary, false).is_err());
    let dir = &ctx.settings.store.progress_report_dir;
    assert!(!dir.join("10-01-14-04.notice.json").exists());
    assert!(!dir.join("10-01-14-04.md").exists());
    assert_eq!(
        mail.events(world.path())
            .unwrap()
            .iter()
            .filter(|e| e.kind() == "notice")
            .count(),
        notices
    );
}

#[test]
fn report_quiet_boundaries_wrap_and_session_cadence_uses_sent_files() {
    let policy = |quiet: &str| {
        report::Policy::read(|key| match key {
            "ORCH_REPORT_QUIET_HOURS" => Some(quiet.to_owned()),
            _ => None,
        })
        .unwrap()
    };
    for (hours, stamp, want) in [
        ("0-7", "2026-10-01T07:00:00Z", true),
        ("0-7", "2026-10-01T14:00:00Z", false),
        ("23-7", "2026-10-01T06:00:00Z", true),
        ("23-7", "2026-10-01T14:00:00Z", false),
        ("", "2026-10-01T09:00:00Z", false),
    ] {
        assert_eq!(
            policy(hours).quiet_at(epoch(stamp)).unwrap(),
            want,
            "{hours} {stamp}"
        );
    }
    for (key, value) in [
        ("ORCH_REPORT_QUIET_HOURS", "25-7"),
        ("ORCH_REPORT_QUIET_HOURS", "7-7"),
        ("ORCH_OWNER_TIME_ZONE", "Mars/Olympus"),
        ("ORCH_OWNER_TIME_ZONE", "America"),
        ("ORCH_REPORT_EVERY_MINUTES", "01"),
        ("ORCH_REPORT_EVERY_MINUTES", "+5"),
        ("ORCH_REPORT_QUIET_HOURS", "+1-7"),
        ("ORCH_REPORT_UPCOMING", "-1"),
        ("ORCH_REPORT_QUIET_HOURS", "07-23"),
        ("ORCH_REPORT", "maybe"),
        ("ORCH_REPORT", ""),
        ("ORCH_REPORT_EVERY_ISSUES", "-1"),
        ("ORCH_REPORT_EVERY_ISSUES", ""),
    ] {
        assert!(
            report::Policy::read(|k| (k == key).then(|| value.to_owned())).is_err(),
            "{key}={value}"
        );
    }
    let world = World::new();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[]}));
    let ctx = world.report_context();
    let start = epoch("2026-10-01T06:00:00Z");
    let session = report::Session { start, fleet: None };
    assert_eq!(
        report::due(&ctx, start + 10800, Some(&session)).unwrap(),
        None
    );
    let morning = epoch("2026-10-01T14:00:00Z");
    assert_eq!(
        report::due(&ctx, morning, Some(&session)).unwrap(),
        Some("report-due reason=minutes since=2026-10-01T06:00:00Z".to_owned())
    );
    // Quiet hours silence a session's due alone: the fleet's stays due.
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-10-01T06:00:00Z"}]}));
    assert_eq!(
        report::due(&ctx, start + 10800, None).unwrap(),
        Some("report-due reason=minutes since=2026-10-01T06:00:00Z".to_owned())
    );
}

#[test]
fn report_render_reads_real_git_and_linear_formatters_and_names_its_window() {
    let world = World::new();
    let _ = world.report_context();
    let actual = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let scripts = world.path().join(".agents/skills/orch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::os::unix::fs::symlink(
        actual
            .join("orch/scripts/resolve-base-branch")
            .canonicalize()
            .unwrap(),
        scripts.join("resolve-base-branch"),
    )
    .unwrap();
    let libs = world.path().join(".agents/skills/github/scripts/lib");
    std::fs::create_dir_all(&libs).unwrap();
    std::os::unix::fs::symlink(
        actual
            .join("github/scripts/lib/gh-repo.sh")
            .canonicalize()
            .unwrap(),
        libs.join("gh-repo.sh"),
    )
    .unwrap();
    let origin = world.path().join("source");
    std::fs::create_dir(&origin).unwrap();
    let git = |root: &Path, args: &[&str], at: Option<&str>| {
        let mut cmd = program("git");
        cmd.arg("-C").arg(root).args(args);
        if let Some(at) = at {
            cmd.env("GIT_AUTHOR_DATE", at).env("GIT_COMMITTER_DATE", at);
        }
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    };
    git(&origin, &["init", "--quiet", "-b", "trunk"], None);
    git(&origin, &["config", "gc.auto", "0"], None);
    git(&origin, &["config", "maintenance.auto", "false"], None);
    git(
        &origin,
        &[
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "Ship the report (#50)",
        ],
        Some("2026-09-29T10:00:00Z"),
    );
    git(
        &origin,
        &[
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "More work (#52)",
        ],
        Some("2026-09-29T10:30:00Z"),
    );
    git(&origin, &["checkout", "--quiet", "-b", "side"], None);
    git(
        &origin,
        &["commit", "--quiet", "--allow-empty", "-m", "Revert #52"],
        Some("2026-09-29T11:00:00Z"),
    );
    git(&origin, &["checkout", "--quiet", "trunk"], None);
    git(
        &origin,
        &[
            "merge",
            "--quiet",
            "--no-ff",
            "side",
            "-m",
            "Merge pull request #53 from owner/side",
        ],
        Some("2026-09-29T11:30:00Z"),
    );
    git(
        world.path(),
        &["remote", "add", "origin", origin.to_str().unwrap()],
        None,
    );
    git(world.path(), &["fetch", "--quiet", "origin"], None);
    git(
        world.path(),
        &["remote", "set-head", "origin", "trunk"],
        None,
    );
    git(
        &origin,
        &[
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "Revert #50 (#51)",
        ],
        Some("2026-09-29T12:00:00Z"),
    );
    // Last week's merge and its revert: the count's last week, whatever
    // week this run falls in.
    let now = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let week = now - (now + 604_800 - 345_600) % 604_800;
    let last = week - 604_800;
    for (at, subject) in [
        (last + 3600, "Last week's work (#60)"),
        (last + 7200, "Revert #60 (#61)"),
    ] {
        git(
            &origin,
            &["commit", "--quiet", "--allow-empty", "-m", subject],
            Some(&clock::iso_utc(at)),
        );
    }
    let linear = world.path().join("report-linear");
    let formatter = actual
        .join("linear/scripts/lib/formatters.sh")
        .canonicalize()
        .unwrap();
    let script = format!(
        r#"#!/bin/bash
set -euo pipefail
source '{}'
printf '%s\n' "$*" >> '{}'
mode=ok
[ ! -f '{}' ] || mode="$(cat '{}')"
case "$mode:$1 $2" in
  fail:'labels list') exit 1 ;;
  object:'labels list') echo '{{"issues": []}}' ;;
  nobug:'labels list') format_labels_list '{{"issueLabels":{{"nodes":[{{"id":"feature","name":"feature"}}]}}}}' ;;
  *:'labels list') format_labels_list '{{"issueLabels":{{"nodes":[{{"id":"bug","name":"Bug"}},{{"id":"bug2","name":"bug"}},{{"id":"feature","name":"feature"}}]}}}}' ;;
  bugs:'issues list') echo '{{}}' ;;
  undated:'issues list') echo '[{{"description":"Regressed-by: #50"}}]' ;;
  *:'issues list') format_issues_list '{{"issues":{{"nodes":[]}}}}' ;;
  *) exit 1 ;;
esac
"#,
        formatter.display(),
        world.path().join("report-linear.args").display(),
        world.path().join("report-linear.mode").display(),
        world.path().join("report-linear.mode").display()
    );
    write_executable(&linear, script);
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-09-29T06:00:00Z"}],"launch_queue":["KEN-1","KEN-2"]}));
    world.plant("gh.json", &json!({}));
    // The owner asks as the mailbox writes them: a reserved one past its
    // deadline, one before it, one the owner answered, a recommended one
    // with a deadline and a two-line text, and two whose tracker posts
    // landed.
    let owner_box = world.path().join("tmp/lane-mail/overseer");
    std::fs::create_dir_all(&owner_box).unwrap();
    let ask = |id: &str, extra: Value| {
        let mut row = json!({"id":id,"kind":"ask","at":"2026-09-21T13:00:00Z","from":"overseer:repo","to":"owner","options":["yes","no"],"wait":60});
        for (k, v) in extra.as_object().unwrap() {
            row[k] = v.clone();
        }
        row.to_string()
    };
    let rows = [
        ask("1790000000-0-c", json!({"text":"Cut 2.0.0?","reserved":true,"deadline":"2026-09-21T14:13:20Z"})),
        ask("1790000000-0-d", json!({"text":"Delete the bucket?","reserved":true,"deadline":"2099-01-01T00:00:00Z"})),
        ask("1790000000-0-e", json!({"text":"Sign the lease?","reserved":true,"deadline":"2026-09-21T14:13:20Z"})),
        ask("1790000000-0-f", json!({"text":"Merge the pricing change?\nIt is small.","recommend":"yes","deadline":"2099-01-01T00:00:00Z"})),
        ask("1790000000-0-g", json!({"text":"First tracker ask","recommend":"yes","deadline":"2099-01-01T00:00:00Z","issue":"KEN-7"})),
        json!({"kind":"tracker-posted","at":"2026-09-21T13:00:01Z","from":"overseer:repo","re":"1790000000-0-g","issue":"KEN-7","tracker_label":"owner-ask"}).to_string(),
        ask("1790000000-0-h", json!({"text":"Second tracker ask","recommend":"yes","deadline":"2099-01-01T00:00:00Z","issue":"KEN-8"})),
        json!({"kind":"tracker-posted","at":"2026-09-21T13:00:01Z","from":"overseer:repo","re":"1790000000-0-h","issue":"KEN-8","tracker_label":"owner-ask"}).to_string(),
    ];
    std::fs::write(owner_box.join("to-overseer.jsonl"), rows.join("\n") + "\n").unwrap();
    std::fs::write(
        owner_box.join("to-lane.jsonl"),
        json!({"id":"1790000000-1-a","kind":"answer","at":"2026-09-21T13:30:00Z","from":"owner","re":"1790000000-0-e","by":"text","closes":false,"text":"wait"}).to_string() + "\n",
    )
    .unwrap();
    // `named`: gh names the checkout's repository there, or names none. The
    // environment's GH_REPO names one either way, for other commands, and
    // is never the checkout's.
    let render = |cwd: &Path, named: bool| {
        let view = if named {
            json!({"repo view": {"text": "owner/repo\n"}})
        } else {
            json!({})
        };
        world.plant("gh.json", &view);
        let mut cmd = isolated();
        cmd.current_dir(cwd)
            .arg("--state-dir")
            .arg(world.path())
            .args([
                "report",
                "render",
                "--repo",
                "owner/repo",
                "--credential-selected",
            ])
            .arg("--state")
            .arg(world.fleet_path())
            .env("PATH", tool_path(&[world.path()]))
            .env("HOME", world.path().join("home"))
            .env("LINEAR_TEAM", "kendex")
            .env("GH_FAKE_REPLIES", world.path().join("gh.json"))
            .env("GH_FAKE_LOG", world.path().join("gh.args"))
            .env("OVERSEE_WATCH_TRACKER", &linear)
            .env("LANE_MAIL_CLI", world.real_report_mail());
        cmd.env("GH_REPO", "owner/repo");
        let output = cmd.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
        reply["result"]["body"].as_str().unwrap().to_owned()
    };
    let body = render(world.path(), true);
    let body = body.as_str();
    assert!(
        body.contains("Escapes: this week 0, last week 1, week of 2026-09-28 1"),
        "{body}"
    );
    for line in [
        "- 2 on the tracker: KEN-7, KEN-8.\n",
        "- Cut 2.0.0? (reserved, no default; overdue since 2026-09-21T14:13:20Z).\n",
        "- Delete the bucket? (reserved, no default; due 2099-01-01T00:00:00Z).\n",
        "- Sign the lease? (reserved, answered, awaiting close).\n",
        "- Merge the pricing change? It is small. (recommended yes; defaults to it after 2099-01-01T00:00:00Z).\n",
    ] {
        assert!(body.contains(line), "{line}\n{body}");
    }
    assert!(!body.contains("First tracker ask"), "{body}");
    let reads = std::fs::read_to_string(world.path().join("report-linear.args")).unwrap();
    for label in ["--label Bug ", "--label bug "] {
        assert!(reads.contains(&format!("issues list {label}")), "{reads}");
    }
    let from = (week - 5 * 604_800).min(1_790_553_600) - 1_209_600;
    let days = (now - from) / 86_400 + 2;
    assert!(
        reads.contains(&format!("--created-since {days}d ")),
        "{reads}"
    );
    // Each source that cannot be read names its cause, in the released words.
    let mode = world.path().join("report-linear.mode");
    let escapes = |body: &str| {
        body.lines()
            .find(|l| l.starts_with("Escapes: "))
            .unwrap_or_default()
            .to_owned()
    };
    for (written, cause) in [
        ("fail", "Linear read failed"),
        ("object", "the Linear label list did not parse"),
        ("nobug", "no Linear label named bug"),
        ("bugs", "the bug list did not parse"),
        ("undated", "the git log or the bug list did not parse"),
    ] {
        std::fs::write(&mode, written).unwrap();
        assert_eq!(
            escapes(&render(world.path(), true)),
            format!("Escapes: unread ({cause})")
        );
    }
    std::fs::remove_file(&mode).unwrap();
    let linear_at = linear.with_extension("moved");
    std::fs::rename(&linear, &linear_at).unwrap();
    assert_eq!(
        escapes(&render(world.path(), true)),
        "Escapes: unread (no Linear CLI)"
    );
    std::fs::rename(&linear_at, &linear).unwrap();
    assert_eq!(
        escapes(&render(world.path(), false)),
        "Escapes: unread (the repository's owner/name did not resolve)"
    );
    // A project that is no checkout, one with no origin, and one whose
    // origin's fetch writes no remote-tracking branch.
    let elsewhere = tempfile::tempdir().unwrap();
    let project = |name: &str, git_init: bool| {
        let dir = elsewhere.path().join(name);
        let scripts = dir.join(".agents/skills/orch/scripts");
        std::fs::create_dir_all(&scripts).unwrap();
        std::os::unix::fs::symlink(
            actual
                .join("orch/scripts/resolve-base-branch")
                .canonicalize()
                .unwrap(),
            scripts.join("resolve-base-branch"),
        )
        .unwrap();
        if git_init {
            git(&dir, &["init", "--quiet", "-b", "main"], None);
            git(&dir, &["config", "gc.auto", "0"], None);
        }
        dir
    };
    let plain = project("plain-project", false);
    assert_eq!(
        escapes(&render(&plain, true)),
        "Escapes: unread (the base branch did not resolve)"
    );
    let unfetched = project("unfetched-project", true);
    assert_eq!(
        escapes(&render(&unfetched, true)),
        "Escapes: unread (git fetch origin main failed)"
    );
    let source = world.path().join("main-source");
    std::fs::create_dir(&source).unwrap();
    git(&source, &["init", "--quiet", "-b", "main"], None);
    git(&source, &["config", "gc.auto", "0"], None);
    git(
        &source,
        &["commit", "--quiet", "--allow-empty", "-m", "base"],
        Some("2026-09-29T10:00:00Z"),
    );
    let untracked = project("untracked-project", true);
    git(
        &untracked,
        &["config", "remote.origin.url", source.to_str().unwrap()],
        None,
    );
    assert_eq!(
        escapes(&render(&untracked, true)),
        "Escapes: unread (git log origin/main failed)"
    );
    // A partial clone whose remote-tracking tip is missing on disk, its
    // promisor origin a local file:// URL that holds it: origin's main is
    // another commit and no fetch refspec moves the tracking ref, so the
    // fetch answers and the log alone needs the missing tip. A git that
    // knows the fence reads the unread line; one that does not reads as it
    // does without it.
    let partial_origin = world.path().join("partial-origin");
    std::fs::create_dir(&partial_origin).unwrap();
    git(&partial_origin, &["init", "--quiet", "-b", "history"], None);
    for (key, value) in [
        ("gc.auto", "0"),
        ("uploadpack.allowFilter", "true"),
        ("uploadpack.allowAnySHA1InWant", "true"),
    ] {
        git(&partial_origin, &["config", key, value], None);
    }
    let at = clock::iso_utc(last + 3600);
    for subject in ["Work (#70)", "Revert #70 (#71)"] {
        git(
            &partial_origin,
            &["commit", "--quiet", "--allow-empty", "-m", subject],
            Some(&at),
        );
    }
    git(
        &partial_origin,
        &["checkout", "--quiet", "--orphan", "main"],
        None,
    );
    git(
        &partial_origin,
        &["commit", "--quiet", "--allow-empty", "-m", "elsewhere"],
        Some(&at),
    );
    let partial = project("partial-project", true);
    let partial_libs = partial.join(".agents/skills/github/scripts/lib");
    std::fs::create_dir_all(&partial_libs).unwrap();
    std::os::unix::fs::symlink(
        actual
            .join("github/scripts/lib/gh-repo.sh")
            .canonicalize()
            .unwrap(),
        partial_libs.join("gh-repo.sh"),
    )
    .unwrap();
    git(
        &partial,
        &[
            "-c",
            "fetch.unpackLimit=100000",
            "fetch",
            "--quiet",
            partial_origin.to_str().unwrap(),
            "history",
        ],
        None,
    );
    git(
        &partial,
        &["update-ref", "refs/remotes/origin/main", "FETCH_HEAD"],
        None,
    );
    let tip = program("git")
        .arg("-C")
        .arg(&partial)
        .args(["rev-parse", "refs/remotes/origin/main"])
        .output()
        .unwrap();
    let tip = String::from_utf8(tip.stdout).unwrap();
    let tip = tip.trim();
    let promisor = format!("file://{}", partial_origin.display());
    for (key, value) in [
        ("remote.origin.url", promisor.as_str()),
        ("core.repositoryformatversion", "1"),
        ("extensions.partialClone", "origin"),
        ("remote.origin.promisor", "true"),
        ("remote.origin.partialclonefilter", "blob:none"),
    ] {
        git(&partial, &["config", key, value], None);
    }
    std::fs::remove_file(partial.join(".git/objects").join(&tip[..2]).join(&tip[2..])).unwrap();
    let fenced = program("git")
        .args(["--no-lazy-fetch", "version"])
        .output()
        .unwrap()
        .status
        .success();
    let line = escapes(&render(&partial, true));
    if fenced {
        assert_eq!(line, "Escapes: unread (git log origin/main failed)");
    } else {
        assert!(line.starts_with("Escapes: this week "), "{line}");
    }
    assert!(
        body.contains("- Queued KEN-2: launch admission pending."),
        "{body}"
    );
    assert!(!body.contains("- Queued KEN-1:"), "{body}");
    assert!(
        body.contains("Issues created: 0; source: Linear, all teams; window: 2026-09-29T06:00:00Z"),
        "{body}"
    );
    for line in [
        r#"Post-merge checks waiting: unread (refused tracker-list-failed: [("read", "statuses"), ("exit", "exit status: 1"), ("cause", "")]); source: the tracker duty's verifying read; as of "#,
        "Blocked\n```\n\n- None; source: lane status of every active lane and each lane's post-PR stop; as of ",
        "Linked issues created\n```\n\n- None; source: Linear, all teams; window: 2026-09-29T06:00:00Z to ",
    ] {
        assert!(body.contains(line), "{line}\n{body}");
    }
    assert!(
        std::fs::read_to_string(world.path().join("report-linear.args"))
            .unwrap()
            .contains("issues list --label Bug --created-since")
    );
    assert!(
        std::fs::read_to_string(world.path().join("report-linear.args"))
            .unwrap()
            .contains("--team kendex")
    );
    assert_eq!(body.matches("> **").count(), 3);
}

/// The body `report render` prints for the world's fleet, run through the
/// binary with `tracker` as its tracker CLI and `extra` over the
/// environment; a render that exits nonzero fails the row.
fn render_body(world: &World, tracker: &Path, extra: &[(&str, String)]) -> String {
    let output = isolated()
        .current_dir(world.path())
        .arg("--state-dir")
        .arg(world.path())
        .args([
            "report",
            "render",
            "--repo",
            "owner/repo",
            "--credential-selected",
        ])
        .arg("--state")
        .arg(world.fleet_path())
        .env("PATH", tool_path(&[world.path()]))
        .env("HOME", world.path().join("home"))
        .env("LINEAR_TEAM", "kendex")
        .env("GH_FAKE_REPLIES", world.path().join("gh.json"))
        .env("GH_FAKE_LOG", world.path().join("gh.args"))
        .env("OVERSEE_WATCH_TRACKER", tracker)
        .env("LANE_MAIL_CLI", world.real_report_mail())
        .envs(extra.iter().map(|(k, v)| (*k, v)))
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
    reply["result"]["body"].as_str().unwrap().to_owned()
}

/// The text of the body's section `name`, up to the next section.
fn section<'a>(body: &'a str, name: &str) -> &'a str {
    let start = format!("```\n{name}\n```\n\n");
    let rest = body.split_once(&start).map_or("", |(_, rest)| rest);
    rest.split_once("\n```\n").map_or(rest, |(text, _)| text)
}

/// The created count and the linked section read one list of every team's
/// issues created since the window's start, through the real tracker CLI
/// over a curl that answers that one request alone: a count over two pages
/// and three teams that leaves out an issue dated past the render, the
/// issues linked to a fleet item of any status by parent, blocks, blocked by
/// or related, and both cells unread, the render still printing, when the
/// read fails or the CLI is missing.
#[test]
fn report_counts_issues_created_and_linked_across_all_teams() {
    let world = World::new();
    let _ = world.report_context();
    let tracker = world.path().join("created");
    std::fs::create_dir(&tracker).unwrap();
    for name in ["linear", "curl"] {
        std::os::unix::fs::symlink(
            fixtures().join("linear-created").join(name),
            tracker.join(name),
        )
        .unwrap();
    }
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[
        {"item":"KEN-1","status":"done","launched_at":"2026-09-29T06:00:00Z"},
        {"item":"KEN-2","status":"parked","launched_at":"2026-09-29T07:00:00Z"}
    ]}));
    world.plant("gh.json", &json!({}));
    let connection =
        |nodes: Value| json!({"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":nodes});
    let other = |id: &str| json!({"id":format!("uuid-{id}"),"identifier":id,"title":"Fixture text","state":{"name":"Todo","type":"unstarted"}});
    let issue = |id: &str, at: &str, parent: Option<&str>, relations: Value, inverse: Value| {
        json!({
            "id":format!("uuid-{id}"),"identifier":id,"title":format!("Fixture {id}"),
            "description":"Fixture text","state":{"name":"Todo","type":"unstarted"},
            "assignee":null,"project":null,"projectMilestone":null,"cycle":null,
            "parent":parent.map(|p| json!({"id":format!("uuid-{p}"),"identifier":p,"title":"Fixture text"})),
            "labels":connection(json!([])),"priority":2,"estimate":1,"sortOrder":-1.0,
            "url":format!("https://linear.app/fixture/{id}"),"createdAt":at,"updatedAt":at,
            "archivedAt":null,"trashed":null,
            "relations":connection(relations),"inverseRelations":connection(inverse)
        })
    };
    let pages = json!([
        [
            issue(
                "KEN-31",
                "2026-10-01T10:00:00.123Z",
                Some("KEN-1"),
                json!([]),
                json!([])
            ),
            issue(
                "FLT-32",
                "2026-10-02T10:00:00.000Z",
                None,
                json!([{"id":"r1","type":"blocks","relatedIssue":other("KEN-2")}]),
                json!([])
            ),
        ],
        [
            issue(
                "KEN-33",
                "2026-10-03T10:00:00.000Z",
                None,
                json!([]),
                json!([
                    {"id":"r2","type":"blocks","issue":other("KEN-2")},
                    {"id":"r3","type":"related","issue":other("KEN-1")}
                ])
            ),
            issue(
                "OPS-34",
                "2026-10-04T10:00:00.000Z",
                None,
                json!([{"id":"r4","type":"related","relatedIssue":other("KEN-99")}]),
                json!([])
            ),
            issue(
                "KEN-35",
                "2099-01-01T00:00:00.000Z",
                Some("KEN-1"),
                json!([]),
                json!([])
            ),
        ],
    ]);
    let plant = |code: u16| {
        std::fs::write(
            tracker.join("linear-created.json"),
            json!({"since":"2026-09-29T06:00:00Z","pages":pages,"code":code}).to_string(),
        )
        .unwrap();
    };
    plant(200);
    let linear = tracker.join("linear");
    let body = render_body(&world, &linear, &[]);
    let window = "window: 2026-09-29T06:00:00Z to ";
    for line in [
        format!("- Issues merged: unread; source: Linear, all teams; {window}"),
        format!("- Issues created: 4; source: Linear, all teams; {window}"),
        format!("- Issues verified: unread; source: Linear, all teams; {window}"),
        format!("- Issues cancelled: unread; source: Linear, all teams; {window}"),
    ] {
        assert!(body.contains(&line), "{line}\n{body}");
    }
    assert_eq!(
        section(&body, "Linked issues created"),
        concat!(
            r"- **[\[KEN-31\]](https://linear.app/fixture/KEN-31)** Fixture KEN-31; links KEN-1 (parent).",
            "\n",
            r"- **[\[FLT-32\]](https://linear.app/fixture/FLT-32)** Fixture FLT-32; links KEN-2 (blocks).",
            "\n",
            r"- **[\[KEN-33\]](https://linear.app/fixture/KEN-33)** Fixture KEN-33; links KEN-2 (blocked by), KEN-1 (related).",
            "\n"
        ),
        "{body}"
    );
    // The Verifying list's read asks for the team first, which this curl
    // refuses; every other request is the created read's.
    let requests: Vec<Value> = lines(&tracker.join("linear-created.log"))
        .iter()
        .map(|l| serde_json::from_str::<Value>(l).unwrap())
        .filter(|r| {
            !r["payload"]["query"]
                .as_str()
                .unwrap_or_default()
                .starts_with("query GetTeam(")
        })
        .collect();
    assert_eq!(
        requests
            .iter()
            .map(|r| r["handled"] == true)
            .collect::<Vec<_>>(),
        vec![true, true],
        "one request per page, each the one accepted form: {requests:?}"
    );
    // A tracker answering 5xx, and a missing tracker CLI: both cells read
    // unread and the report still renders.
    plant(500);
    let unread = |body: &str| {
        assert!(
            body.contains(&format!(
                "- Issues created: unread; source: Linear, all teams; {window}"
            )),
            "{body}"
        );
        let linked = section(body, "Linked issues created");
        assert!(
            linked.starts_with(&format!("- Unread; source: Linear, all teams; {window}"))
                && linked.lines().count() == 1,
            "{body}"
        );
    };
    unread(&render_body(&world, &linear, &[]));
    std::fs::rename(&linear, tracker.join("linear.moved")).unwrap();
    unread(&render_body(&world, &linear, &[]));
}

/// The verb's process runs no tracker duty, so its render reads the
/// Verifying list through the duty's own list read for the configured team:
/// the Verifying item is listed, the item in another open state is not.
#[test]
fn report_render_lists_the_verifying_items_its_own_tracker_read_finds() {
    let world = World::new();
    let _ = world.report_context();
    world.plant("gh.json", &json!({}));
    let item = |id: &str, state: &str| {
        json!({"id": id, "title": id, "description": "", "in_pr_bundle": false, "priority": 2,
            "state": state, "state_type": "started", "parent_id": "",
            "created_at": "2026-09-20T00:00:00Z", "blocked_by_open": []})
    };
    world.plant(
        "linear.json",
        &json!({
            "statuses list": {"body": [
                {"name": "In Progress", "type": "started"}, {"name": "Verifying", "type": "started"},
                {"name": "Done", "type": "completed"}
            ]},
            "issues list": {"body": [item("KEN-21", "Verifying"), item("KEN-22", "In Progress")]},
            "issues bulk-get": {"body": {"issues": {"nodes": [
                {"identifier": "KEN-21", "state": {"type": "started"}, "children": {"nodes": []}},
                {"identifier": "KEN-22", "state": {"type": "started"}, "children": {"nodes": []}}
            ]}}}
        }),
    );
    let body = render_body(&world, &world.path().join("linear"), &[]);
    let line = body
        .lines()
        .find(|l| l.starts_with("Post-merge "))
        .unwrap_or_default();
    assert!(
        line.starts_with("Post-merge items waiting: 1; source: tracker duty; read at "),
        "{body}"
    );
    assert!(
        body.contains(
            "- KEN-21: post-merge checks; issue stage age=unread (no stage-entry reader, as of "
        ),
        "{body}"
    );
    assert!(!body.contains("- KEN-22: post-merge"), "{body}");
    assert!(
        lines(&world.path().join("linear.log"))
            .contains(&"statuses list --team kendex --format=safe".to_owned())
    );
}

/// Blocked reads none only when every active lane's status was judged and
/// no lane is blocked: a lane whose status read settles nothing, or refuses,
/// is named unread, alone or beside a post-PR stop, and none is never
/// printed then.
#[test]
fn report_blocked_reads_none_only_when_every_active_lane_was_read() {
    let world = World::new();
    let _ = world.report_context();
    world.plant("gh.json", &json!({}));
    let server = Server::start(world.path(), "fleet");
    let pane = server.open_window("gh-2", world.path(), "bash --norc --noprofile");
    let root = world.path().display().to_string();
    let running = |item: &str, launch: Value| {
        json!({"item":item,"status":"running","harness":"claude","window":"gh-2",
            "launched_at":"2026-09-29T06:00:00Z","mail_root":root,"launch":launch})
    };
    let judged = running("KEN-2", json!({"pane":pane,"server":server.pid}));
    let tmux = [
        ("TMUX", format!("{},0,0", server.socket.display())),
        ("AGENT_RUNTIME_TMUX_SESSION", server.session.clone()),
    ];
    let tracker = world.path().join("linear");
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[judged.clone()]}));
    let body = render_body(&world, &tracker, &tmux);
    assert!(
        body.contains("- KEN-2: Running; ") && body.contains("\n  - Status: exited; stage: "),
        "{body}"
    );
    let blocked = section(&body, "Blocked");
    assert!(
        blocked.starts_with(
            "- None; source: lane status of every active lane and each lane's post-PR stop; as of "
        ) && blocked.lines().count() == 1,
        "{body}"
    );
    // A lane whose status settles nothing and one whose read refuses: each
    // named unread, with no blocker found and no none; then beside a post-PR
    // stop.
    let mut lanes = vec![
        judged,
        running("KEN-3", json!({})),
        running("KEN-4", json!({})),
        running("KEN-4", json!({})),
    ];
    for stop in [false, true] {
        if stop {
            lanes.push(json!({"item":"KEN-5","status":"done","launched_at":"2026-09-29T06:00:00Z","post_pr_stop":{"reason":"owner-hold"}}));
        }
        world.write_fleet(&json!({"issue_id":"oversee","lanes":lanes}));
        let body = render_body(&world, &tracker, &tmux);
        let mut blocked: Vec<&str> = section(&body, "Blocked").lines().collect();
        if stop {
            assert_eq!(
                blocked.first().copied(),
                Some(r#"- KEN-5: {"reason":"owner-hold"}."#),
                "{body}"
            );
            blocked.remove(0);
        }
        assert_eq!(blocked.len(), 2, "{body}");
        assert!(
            blocked[0].starts_with(
                "- Unread for KEN-3: unjudged (pane-unrecorded); source: lane status; as of "
            ),
            "{body}"
        );
        assert!(
            blocked[1].starts_with("- Unread for KEN-4: ")
                && blocked[1].contains("lane-ambiguous")
                && blocked[1].contains("; source: lane status; as of "),
            "{body}"
        );
    }
}

/// A lane the watch holds over its landing or its close is listed under In
/// progress with the hold's cause, whatever its status but done: the
/// tracker duty's `terminal-close` row, held or refused, and an open
/// `close-resources` intent. A stopped lane with no hold, or whose close
/// ended, stays unlisted, and so does a done lane under a stale row.
#[test]
fn report_lists_a_lane_held_over_its_landing_or_close_with_its_cause() {
    let world = World::new();
    world.plant("gh.json", &json!({}));
    let lane = |item: &str, status: &str| json!({"item":item,"status":status,"launched_at":"2026-09-29T06:00:00Z"});
    let close = |item: &str, outcome: &str| {
        json!({"id":format!("close-{item}"),"op":"close-resources","target":item,
            "created_at":"2026-09-30T06:00:00Z","outcome":outcome,
            "observation":{"host_close":"unanswered","cause":"ssh exit 255"}})
    };
    let mut parked = lane("KEN-13", "parked");
    parked["parked"] = json!({"pr": 7});
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[
        lane("KEN-11", "stopped"), lane("KEN-12", "stopped"), parked,
        lane("KEN-14", "stopped"), lane("KEN-15", "done")
    ],"intents":[close("KEN-13", "unconfirmed"), close("KEN-14", "confirmed")]}));
    let ctx = world.report_context();
    let mut baseline = Baseline::default();
    for (item, value) in [
        ("KEN-11", "held|merged-read-failed"),
        (
            "KEN-12",
            "canceled|2026-09-29T06:00:00Z|close-failed cause=boxes-unsettled",
        ),
        ("KEN-15", "held|merged-read-failed"),
    ] {
        baseline.apply(watch::Change::Set {
            kind: orch_runtime::watch::tracker::TERMINAL_CLOSE_ROW.to_owned(),
            identity: item.to_owned(),
            value: value.to_owned(),
        });
    }
    baseline
        .store(&Paths::of(&ctx.fleet).unwrap().baseline)
        .unwrap();
    let body = report::render(&ctx, epoch("2026-10-01T14:00:00Z")).unwrap();
    let listed: Vec<&str> = section(&body, "In progress")
        .lines()
        .filter(|l| l.starts_with("- KEN-"))
        .collect();
    assert_eq!(
        listed,
        [
            "- KEN-11: Stopped, no pull request; held: landing unrecorded (merged-read-failed).",
            "- KEN-12: Stopped, no pull request; held: close refused (close-failed cause=boxes-unsettled).",
            "- KEN-13: Parked, #7; held: close unconfirmed (host_close=unanswered cause=ssh exit 255).",
        ],
        "{body}"
    );
}

/// A fleet named by `--state` has its lanes' facts read from its own record,
/// and a lane with no checkout on this disk counts the item record beside
/// that fleet, never the configured fleet's of the same key.
#[test]
fn report_reads_lane_facts_of_the_fleet_its_state_names() {
    let world = World::new();
    let other = world.path().join("other");
    std::fs::create_dir(&other).unwrap();
    let fleet = other.join(FLEET_FILE_NAME);
    std::fs::write(
        &fleet,
        json!({"issue_id":"oversee","triaged":[],"launch_queue":[],"fleet_log":[],"lanes":[
            {"item":"KEN-6","status":"preparing","harness":"claude","launched_at":"2026-10-01T06:00:00Z"}
        ]})
        .to_string(),
    )
    .unwrap();
    for (dir, rounds) in [(other.as_path(), 2), (world.path(), 7)] {
        std::fs::write(
            state::item_path(dir, "KEN-6"),
            json!({"rereview_cycles":rounds,"restacks":1,"stages":[]}).to_string(),
        )
        .unwrap();
    }
    let mut ctx = world.report_context();
    ctx.fleet = fleet;
    let body = report::render(&ctx, epoch("2026-10-01T14:00:00Z")).unwrap();
    let worker = body
        .split("- KEN-6: Preparing; ")
        .nth(1)
        .unwrap_or_default();
    assert!(worker.contains("\n  - Status: unjudged; stage: "), "{body}");
    assert!(
        worker.contains("\n  - Rounds: review_rounds=2 fix_receipts=0 "),
        "{body}"
    );
    assert!(!body.contains("Lane facts: unread"), "{body}");
}

#[test]
fn report_notice_reads_its_attachment_after_a_lost_reply_and_retries_a_refused_send() {
    for mode in ["lost", "refused"] {
        let world = World::new();
        world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-10-01T06:00:00Z"}]}));
        let mut ctx = world.report_context();
        if mode == "lost" {
            let actual = ctx.settings.store.progress_report_dir.clone();
            std::fs::create_dir_all(&actual).unwrap();
            let link = world.path().join("reports-link");
            std::os::unix::fs::symlink(actual, &link).unwrap();
            ctx.settings.store.progress_report_dir = link;
        }

        let real = ctx.settings.lane_mail_cli.clone();
        let wrapper = world.path().join("report-mail-interrupted");
        let script = if mode == "lost" {
            format!(
                "#!/bin/sh\nif [ \\\"$1\\\" = notice ]; then\n  '{}' \\\"$@\\\" >/dev/null || exit $?\n  kill -KILL \\\"$$\\\"\nelse\n  exec '{}' \\\"$@\\\"\nfi\n",
                real.display(),
                real.display()
            )
        } else {
            format!(
                "#!/bin/sh\nif [ \\\"$1\\\" = notice ]; then\n  exec '{}' \\\"$@\\\" --file '{}'/missing-summary\nelse\n  exec '{}' \\\"$@\\\"\nfi\n",
                real.display(),
                world.path().display(),
                real.display()
            )
        };
        write_executable(&wrapper, script.replace("\\\"", "\""));
        ctx.settings.lane_mail_cli = wrapper;
        let summary = world.path().join("summary.txt");
        std::fs::write(&summary, "The report is ready.").unwrap();
        let now = epoch("2026-10-01T14:00:00Z");
        let first = report::write(&ctx, now, &summary, false);
        let confirmed = if mode == "refused" {
            assert!(first.is_err(), "{first:?}");
            ctx.settings.lane_mail_cli = real;
            report::write(&ctx, now + 1, &summary, false).unwrap()
        } else {
            ctx.settings.lane_mail_cli = real;
            first.unwrap()
        };
        assert!(confirmed["notice_id"].as_str().is_some(), "{confirmed}");
        let events = orch_runtime::mailbox::Mailbox::new(ctx.settings.lane_mail_cli.clone())
            .events(world.path())
            .unwrap();
        assert_eq!(
            events.iter().filter(|e| e.kind() == "notice").count(),
            1,
            "{mode}"
        );
        // The sent attachment, matched through the linked directory, is the
        // next report's start.
        assert!(
            report::render(&ctx, now + 60)
                .unwrap()
                .contains("window: 2026-10-01T14:00:00Z to"),
            "{mode}"
        );
        assert_eq!(
            std::fs::metadata(confirmed["path"].as_str().unwrap())
                .unwrap()
                .modified()
                .unwrap()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            now
        );
    }
}

#[test]
fn report_due_counts_distinct_direct_push_items_and_preserves_a_capped_old_window() {
    let world = World::new();
    let mut ctx = world.report_context();
    ctx.repos.clear();
    set_report(&mut ctx, report::MINUTES_KEY, "0");
    set_report(&mut ctx, report::ISSUES_KEY, "2");
    let now = epoch("2026-10-02T14:00:00Z");
    let fleet = |start: &str, rows: Vec<Value>| json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":start}],"fleet_log":rows});
    let cycle = |item: &str, at: u64| json!({"item":item,"at":clock::iso_utc(at),"kind":"cycle","text":format!("cycle item={item} commit=abcdef1")});
    for (rows, want) in [
        (vec![cycle("KEN-1", now - 1), cycle("KEN-1", now - 2)], None),
        (
            vec![cycle("KEN-1", now - 1), cycle("KEN-2", now - 2)],
            Some("report-due reason=issues since=2026-10-02T06:00:00Z landed=2"),
        ),
        (vec![cycle("KEN-1", now), cycle("KEN-2", now + 1)], None),
    ] {
        world.write_fleet(&fleet("2026-10-02T06:00:00Z", rows));
        assert_eq!(report::due(&ctx, now, None).unwrap().as_deref(), want);
    }
    world.write_fleet(&fleet(
        "2026-09-01T06:00:00Z",
        vec![cycle("KEN-1", now - 1)],
    ));
    assert_eq!(
        report::due(&ctx, now, None).unwrap().as_deref(),
        Some("report-due reason=issues since=2026-09-01T06:00:00Z landed=1")
    );
    assert!(
        report::render(&ctx, now)
            .unwrap()
            .contains("`Next report: after 2 distinct landed items`")
    );
    set_report(&mut ctx, report::ENABLED_KEY, "off");
    assert_eq!(report::due(&ctx, now, None).unwrap(), None);
    assert!(
        report::render(&ctx, now)
            .unwrap()
            .contains("`Next report: cadence disabled`")
    );
    set_report(&mut ctx, report::ENABLED_KEY, "on");
    set_report(&mut ctx, report::ISSUES_KEY, "0");
    assert_eq!(report::due(&ctx, now, None).unwrap(), None);
    let body = report::render(&ctx, now).unwrap();
    assert!(body.contains("`Next report: cadence disabled`"));
    assert!(body.contains("\nUse 1: none\n"), "{body}");
    assert!(
        body.contains("```\nWaiting on you\n```\n\n- Nothing.\n"),
        "{body}"
    );
    assert!(
        body.contains("Earlier merges not listed; GitHub window starts 2026-09-25T14:00:00Z."),
        "{body}"
    );
    assert!(
        report::render(&ctx, epoch("2026-09-21T12:00:00Z"))
            .unwrap()
            .contains("Escapes: unread (the clock reads before the cap week 2026-09-28)")
    );
    // The minutes trigger alone: due at its interval, not a second short.
    let one = |launched: u64| json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":clock::iso_utc(launched)}]});
    set_report(&mut ctx, report::MINUTES_KEY, "120");
    for (age, due) in [(7140, false), (7200, true)] {
        world.write_fleet(&one(now - age));
        assert_eq!(
            report::due(&ctx, now, None).unwrap(),
            due.then(|| format!(
                "report-due reason=minutes since={}",
                clock::iso_utc(now - age)
            )),
            "{age}"
        );
    }
    set_report(&mut ctx, report::MINUTES_KEY, "0");
    world.write_fleet(&one(now - 999_999));
    assert_eq!(report::due(&ctx, now, None).unwrap(), None);
    // The fleet start is the earliest launch, not the first record's.
    set_report(&mut ctx, report::MINUTES_KEY, "120");
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[
        {"item":"KEN-1","status":"running","launched_at":clock::iso_utc(now - 40_000)},
        {"item":"KEN-2","status":"running","launched_at":clock::iso_utc(now - 86_400)}]}));
    assert_eq!(
        report::due(&ctx, now, None).unwrap(),
        Some(format!(
            "report-due reason=minutes since={}",
            clock::iso_utc(now - 86_400)
        ))
    );
    // A launch or a cycle row whose time does not read refuses.
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":"yesterday"}]}));
    let err = report::due(&ctx, now, None).unwrap_err();
    assert_eq!(
        err.fields(),
        vec![
            ("cause".to_owned(), "launched-at".to_owned()),
            ("item".to_owned(), "KEN-1".to_owned())
        ]
    );
    set_report(&mut ctx, report::MINUTES_KEY, "0");
    set_report(&mut ctx, report::ISSUES_KEY, "1");
    let mut bad = cycle("KEN-1", now - 1);
    bad["at"] = json!("yesterday");
    world.write_fleet(&fleet("2026-10-02T06:00:00Z", vec![bad]));
    assert_eq!(
        report::due(&ctx, now, None).unwrap_err().fields(),
        vec![("cause".to_owned(), "cycle-time".to_owned())]
    );
    let mut stamped = fleet("2026-10-02T06:00:00Z", Vec::new());
    stamped["fleet_log"] = json!([{"kind":"use1","at":"yesterday","outcome":"fallback"}]);
    world.write_fleet(&stamped);
    assert_eq!(
        report::render(&ctx, now).unwrap_err().fields(),
        vec![("cause".to_owned(), "use1-time".to_owned())]
    );
    // A landing before the marker counts for nothing; past the lookback
    // no landing is no due.
    world.write_fleet(&fleet(
        &clock::iso_utc(now - 3600),
        vec![cycle("KEN-1", now - 7200)],
    ));
    assert_eq!(report::due(&ctx, now, None).unwrap(), None);
    set_report(&mut ctx, report::ISSUES_KEY, "2");
    world.write_fleet(&fleet("2026-09-01T06:00:00Z", Vec::new()));
    assert_eq!(report::due(&ctx, now, None).unwrap(), None);
    // ORCH_REPORT_UPCOMING caps the queued lines.
    set_report(&mut ctx, report::UPCOMING_KEY, "2");
    world.write_fleet(
        &json!({"issue_id":"oversee","launch_queue":["KEN-1","KEN-7","KEN-8","KEN-9"],
        "lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-10-02T06:00:00Z"}]}),
    );
    let body = report::render(&ctx, now).unwrap();
    assert!(
        body.contains(
            "- Queued KEN-7: launch admission pending.\n- Queued KEN-8: launch admission pending.\n"
        ),
        "{body}"
    );
    assert!(!body.contains("- Queued KEN-9:"), "{body}");
    // The count's GitHub read refuses the due where it is capped or fails.
    ctx.repos = vec!["owner/repo".to_owned()];
    let search = "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D2026-10-02T06%3A00%3A00Z&per_page=100&page=1";
    world.write_fleet(&fleet("2026-10-02T06:00:00Z", Vec::new()));
    world.plant("gh.json", &json!({}));
    assert_eq!(
        report::due(&ctx, now, None).unwrap_err().key(),
        "github-read-failed"
    );
    world.plant(
        "gh.json",
        &json!({search: {"body":{"total_count":1000,"incomplete_results":false,"items":[]}}}),
    );
    assert_eq!(
        report::due(&ctx, now, None).unwrap_err().key(),
        "github-capped"
    );
    // Only a file named as a report is one, a succession report among them.
    ctx.repos.clear();
    set_report(&mut ctx, report::QUIET_HOURS_KEY, "");
    set_report(&mut ctx, report::ISSUES_KEY, "0");
    set_report(&mut ctx, report::MINUTES_KEY, "120");
    world.write_fleet(&one(now - 86_400));
    let dir = ctx.settings.store.progress_report_dir.clone();
    std::fs::create_dir_all(&dir).unwrap();
    let report_at = |name: &str, at: u64| {
        let path = dir.join(name);
        std::fs::write(&path, "report").unwrap();
        set_modified(&path, at);
    };
    report_at("10-02-11-58.md", now - 7300);
    report_at("notes.md", now - 60);
    assert_eq!(
        report::due(&ctx, now, None).unwrap(),
        Some(format!(
            "report-due reason=minutes since={}",
            clock::iso_utc(now - 7300)
        ))
    );
    report_at("10-02-13-59-succession.md", now - 60);
    assert_eq!(report::due(&ctx, now, None).unwrap(), None);
}

#[test]
fn report_completed_searches_the_window_and_excludes_unowned_late_and_capped_merges() {
    let world = World::new();
    let root = world.path().display().to_string();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[
        {"item":"KEN-1","status":"done","launched_at":"2026-10-01T06:00:00Z"},
        {"item":"KEN-5","status":"done","launched_at":"2026-10-01T06:00:00Z"},
        {"item":"KEN-5","status":"parked","launched_at":"2026-10-01T06:00:00Z","parked":{"pr":14,"head":"abc","repo":"Owner/Repo","at":"2026-10-01T06:30:00Z"}},
        {"item":"KEN-6","status":"running","launched_at":"2026-10-01T06:00:00Z","mail_root":root,"pending_pr":{"pr":15,"head":"def"}},
        {"item":"KEN-7","status":"running","launched_at":"2026-10-01T06:00:00Z","mail_root":root}
    ],"fleet_log":[
        {"kind":"use1","at":"2026-10-01T06:00:00Z","outcome":"declined-unchanged"},
        {"kind":"use1","at":"2026-10-01T07:00:00Z","outcome":"fallback"},
        {"kind":"use1","at":"2026-10-01T08:00:00Z","outcome":"new-value"},
        {"kind":"use1","at":"2026-10-01T14:00:00Z","outcome":"fallback"},
        {"kind":"cycle","item":"KEN-1","at":"2026-10-01T06:00:00Z","text":"cycle item=KEN-1 commit=abcdef1"}
    ]}));
    let pull = |number, branch, owner: &str, at| json!({"body":{"number":number,"state":"closed","title":"Report actual completed work","body":"","merged_at":at,"merge_commit_sha":null,"author_association":"NONE","base":{"ref":"main","sha":"0123456789abcdef0123456789abcdef01234567"},"user":null,"head":{"sha":"0000000000000000000000000000000000000000","ref":branch,"repo":{"full_name":format!("{owner}/repo"),"owner":{"login":owner,"type":"User"}}}}});
    let search = "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D2026-10-01T06%3A00%3A00Z&per_page=100&page=1";
    let items: Vec<Value> = (1..=12)
        .chain([14])
        .map(|n| json!({"number":n,"pull_request":{}}))
        .collect();
    let total = items.len() as u64;
    let hits =
        |total: u64| json!({"body":{"total_count":total,"incomplete_results":false,"items":items}});
    let mut planted = json!({
        "repos/owner/repo/pulls/1": pull(1,"ken-1","owner","2026-10-01T07:00:00Z"),
        "repos/owner/repo/pulls/2": pull(2,"other","owner","2026-10-01T08:00:00Z"),
        "repos/owner/repo/pulls/3": pull(3,"ken-1","fork","2026-10-01T08:00:00Z"),
        "repos/owner/repo/pulls/4": pull(4,"ken-1","owner","2026-10-01T14:00:00Z")
    });
    // A cloud session's branch names no item: its pull request is the
    // item's by the title's conventional-commit scope or a Closes line, and
    // a parked record's by its number in the repository the record names.
    let titled = |number, branch, title: &str, body: &str, at: &str| json!({"body":{"number":number,"state":"closed","title":title,"body":body,"merged_at":at,"merge_commit_sha":null,"author_association":"NONE","base":{"ref":"main","sha":"0123456789abcdef0123456789abcdef01234567"},"user":null,"head":{"sha":"0000000000000000000000000000000000000000","ref":branch,"repo":{"full_name":"owner/repo","owner":{"login":"owner","type":"User"}}}}});
    for (n, branch, title, body, at) in [
        (
            5,
            "claude/fix-a",
            "fix(KEN-1): a",
            "",
            "2026-10-01T09:00:00Z",
        ),
        (
            6,
            "claude/fix-b",
            "chore: b",
            "## Completed Issues\r\n- Closes KEN-1 - b\r\n",
            "2026-10-01T09:05:00Z",
        ),
        (
            7,
            "claude/fix-c",
            "fix(KEN-10): c",
            "- Closes KEN-10",
            "2026-10-01T09:10:00Z",
        ),
        (
            8,
            "claude/fix-d",
            "chore: d",
            "Follow-up to KEN-1.",
            "2026-10-01T09:15:00Z",
        ),
        (
            9,
            "ken-1805",
            "refactor(KEN-1805): x before KEN-1 grows it",
            "",
            "2026-10-01T09:20:00Z",
        ),
        (
            10,
            "revert-5",
            "Revert \"fix(KEN-1): a\"",
            "",
            "2026-10-01T09:25:00Z",
        ),
        (
            11,
            "claude/fix-g",
            "chore: g",
            "- Closes KEN-10 - Follow-up to KEN-1",
            "2026-10-01T09:30:00Z",
        ),
        (
            12,
            "claude/fix-h",
            "docs(KEN-1) notes",
            "",
            "2026-10-01T09:35:00Z",
        ),
        (14, "claude/fix-e", "e", "", "2026-10-01T09:40:00Z"),
    ] {
        planted[format!("repos/owner/repo/pulls/{n}")] = titled(n, branch, title, body, at);
    }
    planted[search] = hits(total);
    let other = "search/issues?q=repo%3Aother%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D2026-10-01T06%3A00%3A00Z&per_page=100&page=1";
    planted[other] = json!({"body":{"total_count":2,"incomplete_results":false,"items":[{"number":31,"pull_request":{}},{"number":14,"pull_request":{}}]}});
    planted["repos/other/repo/pulls/14"] = json!({"body":{"number":14,"state":"closed","title":"Another repository's 14","body":"","merged_at":"2026-10-01T10:05:00Z","merge_commit_sha":null,"author_association":"NONE","base":{"ref":"main","sha":"0123456789abcdef0123456789abcdef01234567"},"user":null,"head":{"sha":"0000000000000000000000000000000000000000","ref":"claude/x","repo":{"full_name":"other/repo","owner":{"login":"other","type":"User"}}}}});
    planted["repos/other/repo/pulls/31"] = json!({"body":{"number":31,"state":"closed","title":"Ship the consumer","body":"","merged_at":"2026-10-01T10:00:00Z","merge_commit_sha":null,"author_association":"NONE","base":{"ref":"main","sha":"0123456789abcdef0123456789abcdef01234567"},"user":null,"head":{"sha":"0000000000000000000000000000000000000000","ref":"ken-1","repo":{"full_name":"other/repo","owner":{"login":"other","type":"User"}}}}});
    world.plant("gh.json", &planted);
    let mut ctx = world.report_context();
    ctx.settings.reads.connected_repos = vec!["Other/Repo".to_owned(), "OWNER/repo".to_owned()];
    ctx.shared = shared_with(vec![verifying_item("KEN-1", "1", "", false)]);
    // KEN-6 waits on an ask it put in its mailbox; KEN-7's mailbox cannot be
    // read, its cursor past every line its box holds.
    let ask = world.path().join("ask.txt");
    std::fs::write(&ask, "Which schema?").unwrap();
    let asked = program(world.real_report_mail())
        .current_dir(world.path())
        .args(["ask", "--item", "KEN-6", "--file"])
        .arg(&ask)
        .output()
        .unwrap();
    assert!(
        asked.status.success(),
        "{}",
        String::from_utf8_lossy(&asked.stderr)
    );
    let box7 = world.path().join("tmp/lane-mail/KEN-7");
    std::fs::create_dir_all(&box7).unwrap();
    std::fs::write(box7.join("to-lane.jsonl"), "").unwrap();
    std::fs::write(box7.join("to-lane.cursor"), "3\n").unwrap();
    let now = epoch("2026-10-01T14:00:00Z");
    let body = report::render(&ctx, now).unwrap();
    assert!(
        body.contains("- KEN-1: direct push; Verifying.\n- KEN-1: Report actual completed work ([owner/repo#1](https://github.com/owner/repo/pull/1)); Verifying.\n"),
        "{body}"
    );
    assert!(
        body.contains(
            "Use 1: approved-on-rerequest=0 fallback=1 declined-unchanged=1 unrecognized=1"
        ),
        "{body}"
    );
    for line in [
        "- KEN-5: Parked, #14.\n",
        "- KEN-6: Running, #15.\n",
        "- KEN-7: Running, no pull request.\n",
        "- KEN-6 waits on the overseer to answer: Which schema?.\n",
        "- KEN-7 mailbox unreadable (mail-read=KEN-7): lane-mail: mail-read-failed=KEN-7 cursor=missed.\n",
    ] {
        assert!(body.contains(line), "{line}\n{body}");
    }
    assert!(
        body.contains("- KEN-1: Ship the consumer ([other/repo#31](https://github.com/other/repo/pull/31)); Verifying.\n"),
        "{body}"
    );
    let log = std::fs::read_to_string(world.path().join("gh.log")).unwrap_or_default();
    let searched = |repo: &str| {
        log.lines()
            .filter(|l| l.contains(&format!("search/issues?q=repo%3A{repo}%20")))
            .count()
    };
    assert_eq!(
        (searched("owner%2Frepo"), searched("other%2Frepo")),
        (1, 1),
        "{log}"
    );
    let worker = body.split("- KEN-6: Running; ").nth(1).unwrap_or_default();
    assert!(worker.contains("\n  - Status: "), "{body}");
    assert!(worker.contains("\n  - Rounds: review_rounds="), "{body}");
    for number in [2, 3, 4, 7, 8, 9, 10, 11, 12] {
        assert!(!body.contains(&format!("[owner/repo#{number}]")), "{body}");
    }
    for line in [
        "- KEN-1: fix(KEN-1): a ([owner/repo#5]",
        "- KEN-1: chore: b ([owner/repo#6]",
        "- KEN-5: e ([owner/repo#14]",
    ] {
        assert!(body.contains(line), "{line}\n{body}");
    }
    assert!(!body.contains("[other/repo#14]"), "{body}");
    planted[search] = hits(1000);
    world.plant("gh.json", &planted);
    let body = report::render(&ctx, now).unwrap();
    assert!(
        body.contains("- Unread; source: GitHub; cause: ") && body.contains("github-capped"),
        "{body}"
    );
    // An overseer box whose owner asks cannot be listed, and a fleet record
    // that cannot be read, refuse the render.
    let real = ctx.settings.lane_mail_cli.clone();
    let refusing = world.path().join("report-mail-unlisted");
    write_executable(
        &refusing,
        format!(
            "#!/bin/sh\nif [ \"$1 $3\" = 'pending overseer' ]; then\n  echo 'lane-mail: mail-read-failed=overseer' >&2\n  exit 2\nfi\nexec '{}' \"$@\"\n",
            real.display()
        ),
    );
    ctx.settings.lane_mail_cli = refusing;
    assert!(report::render(&ctx, now).is_err());
    ctx.settings.lane_mail_cli = real.clone();
    // A running lane whose record names no mailbox refuses; so does one
    // whose mailbox read refuses with any line but its own host's or box's
    // under status 2: a crash, a global refusal, another item's, a longer
    // item's, another key.
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-8","status":"running","launched_at":"2026-10-01T06:00:00Z"}]}));
    assert!(report::render(&ctx, now).is_err());
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-8","status":"running","launched_at":"2026-10-01T06:00:00Z","mail_root":root}]}));
    let unread = world.path().join("report-mail-lane-refused");
    for (status, line) in [
        (1, "host-unreachable=KEN-8 state=unknown"),
        (2, "root-unresolved=/w/KEN-8"),
        (2, "host-unreachable=KEN-9 state=unknown"),
        (2, "mail-read-failed=KEN-80"),
        (2, "item-case-variant=KEN-8"),
    ] {
        write_executable(
            &unread,
            format!(
                "#!/bin/sh\nif [ \"$1 $3\" = 'pending KEN-8' ]; then\n  echo 'lane-mail: {line}' >&2\n  exit {status}\nfi\nexec '{}' \"$@\"\n",
                real.display()
            ),
        );
        ctx.settings.lane_mail_cli = unread.clone();
        assert!(report::render(&ctx, now).is_err(), "{status} {line}");
    }
    ctx.settings.lane_mail_cli = real;
    // A running claude-cloud lane has no mailbox to read: it renders.
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-9","status":"running","kind":"claude-cloud","launched_at":"2026-10-01T06:00:00Z"}]}));
    assert!(report::render(&ctx, now).is_ok());
    std::fs::write(world.fleet_path(), "{\"lanes\": [").unwrap();
    assert!(report::render(&ctx, now).is_err());
}

#[test]
fn report_write_binds_a_relative_summary_before_the_mailbox_changes_directory() {
    let world = World::new();
    let _ = world.report_context();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[]}));
    let caller = world.path().join("caller");
    std::fs::create_dir(&caller).unwrap();
    std::fs::write(
        caller.join("summary.txt"),
        "Report from the caller directory.",
    )
    .unwrap();
    let out = isolated()
        .current_dir(&caller)
        .arg("--state-dir")
        .arg(world.path())
        .args([
            "report",
            "write",
            "--repo",
            "owner/repo",
            "--summary-file",
            "summary.txt",
            "--credential-selected",
        ])
        .arg("--state")
        .arg(world.fleet_path())
        .env("HOME", world.path().join("home"))
        .env("LANE_MAIL_CLI", world.real_report_mail())
        .env("ORCH_REPORT_QUIET_HOURS", "")
        .env("ORCH_OWNER_TIME_ZONE", "UTC")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(reply["result"]["notice_id"].as_str().is_some(), "{reply}");
    let events = orch_runtime::mailbox::Mailbox::new(world.real_report_mail())
        .events(world.path())
        .unwrap();
    let notice = events
        .iter()
        .find(|e| e.attach.as_deref() == reply["result"]["path"].as_str())
        .unwrap();
    assert_eq!(
        notice.text.as_deref(),
        Some("Report from the caller directory.")
    );
}

/// The real github skill's scripts under the world's project, so the CLI's
/// credential ladder runs, and a `gh` first on the returned directory that
/// logs each call to `token-gh.calls` and answers by the token it is given:
/// `good` reads, any other token is refused as GitHub refuses a revoked one.
fn ladder_world(world: &World) -> PathBuf {
    let actual = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let skill = world.path().join(".agents/skills/github");
    std::fs::create_dir_all(&skill).unwrap();
    std::os::unix::fs::symlink(
        actual.join("github/scripts").canonicalize().unwrap(),
        skill.join("scripts"),
    )
    .unwrap();
    let bin = world.path().join("token-gh");
    std::fs::create_dir(&bin).unwrap();
    write_executable(
        &bin.join("gh"),
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nif [ \"${{GH_TOKEN:-}}\" != good ]; then\n  echo 'gh: Bad credentials (HTTP 401)' >&2\n  exit 1\nfi\nif [ \"$1 $2\" = 'api user' ]; then\n  echo bot\n  exit 0\nfi\nexec '{}' \"$@\"\n",
            world.path().join("token-gh.calls").display(),
            world.path().join("gh").display()
        ),
    );
    bin
}

/// The standalone render reads GitHub under the github skill's credential
/// ladder, never under a stale inherited token alone: with `GH_TOKEN`
/// revoked and no keyring, the project's `GH_BOT_TOKEN` reads Completed;
/// with no credential working, the render refuses `auth-failed`. `gh`
/// answers by the token it is given, as GitHub answers a revoked one.
#[test]
fn report_render_reads_github_under_the_credential_ladder() {
    let world = World::new();
    let _ = world.report_context();
    let bin = ladder_world(&world);
    let now = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let launched = clock::iso_utc(now - 3600);
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":launched}]}));
    let search = format!(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D{}&per_page=100&page=1",
        launched.replace(':', "%3A")
    );
    let mut planted = json!({"repos/owner/repo/pulls/1": {"body":{"number":1,"state":"closed","title":"Ship the ladder","body":"","merged_at":clock::iso_utc(now - 60),"merge_commit_sha":null,"author_association":"NONE","base":{"ref":"main","sha":"0123456789abcdef0123456789abcdef01234567"},"user":null,"head":{"sha":"0000000000000000000000000000000000000000","ref":"ken-1","repo":{"full_name":"owner/repo","owner":{"login":"owner","type":"User"}}}}}});
    planted[search.as_str()] = json!({"body":{"total_count":1,"incomplete_results":false,"items":[{"number":1,"pull_request":{}}]}});
    world.plant("gh.json", &planted);
    let render = |bot: Option<&str>| {
        let mut cmd = isolated();
        cmd.current_dir(world.path())
            .arg("--state-dir")
            .arg(world.path())
            .args(["report", "render", "--repo", "owner/repo"])
            .arg("--state")
            .arg(world.fleet_path())
            .env("PATH", tool_path(&[bin.as_path()]))
            .env("HOME", world.path().join("home"))
            .env("GH_TOKEN", "revoked")
            .env("GH_FAKE_REPLIES", world.path().join("gh.json"))
            .env("GH_FAKE_LOG", world.path().join("gh.args"))
            .env("LANE_MAIL_CLI", world.real_report_mail());
        if let Some(token) = bot {
            cmd.env("GH_BOT_TOKEN", token);
        }
        let out = cmd.output().unwrap();
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap_or_else(|_| {
            panic!(
                "{}\n{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            )
        });
        (out.status.success(), reply)
    };
    let (ok, reply) = render(Some("good"));
    assert!(ok, "{reply}");
    let body = reply["result"]["body"].as_str().unwrap();
    assert!(
        body.contains("- KEN-1: Ship the ladder ([owner/repo#1]"),
        "{body}"
    );
    let (ok, reply) = render(None);
    assert!(!ok, "{reply}");
    assert_eq!(reply["refusal"]["key"], "auth-failed", "{reply}");
    // A project without the github skill has no ladder to run: the render
    // refuses on the ladder that never started.
    std::fs::remove_file(world.path().join(".agents/skills/github/scripts")).unwrap();
    let (ok, reply) = render(Some("good"));
    assert!(!ok, "{reply}");
    assert_eq!(reply["refusal"]["key"], "not-started", "{reply}");
}

/// A session's due reads the fleet record it names and no other: with the
/// landed-item trigger on, a fleet record on the host holding a landed item
/// is not counted by a session due that names no `--state`, and is counted
/// once the same due names it.
#[test]
fn report_session_due_counts_only_the_fleet_it_names() {
    let world = World::new();
    let _ = world.report_context();
    let now = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let start = now - 3600;
    world.write_fleet(&json!({"issue_id":"oversee",
        "lanes":[{"item":"KEN-1","status":"done","launched_at":clock::iso_utc(start)}],
        "fleet_log":[{"item":"KEN-1","at":clock::iso_utc(now - 60),"kind":"cycle","text":"cycle item=KEN-1 commit=abcdef1"}]}));
    let due = |state: Option<PathBuf>| {
        let mut cmd = isolated();
        cmd.current_dir(world.path())
            .arg("--state-dir")
            .arg(world.path())
            .args(["report", "due", "--session-start", &start.to_string()])
            .env("HOME", world.path().join("home"))
            .env("LANE_MAIL_CLI", world.real_report_mail())
            .env("ORCH_REPORT_QUIET_HOURS", "")
            .env("ORCH_OWNER_TIME_ZONE", "UTC")
            .env("ORCH_REPORT_EVERY_MINUTES", "0")
            .env("ORCH_REPORT_EVERY_ISSUES", "1");
        if let Some(path) = state {
            cmd.arg("--state").arg(path).arg("--credential-selected");
        }
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        reply["result"]["line"].clone()
    };
    assert_eq!(due(None), Value::Null);
    assert_eq!(
        due(Some(world.fleet_path())),
        json!(format!(
            "report-due reason=issues since={} landed=1",
            clock::iso_utc(start)
        ))
    );
}

/// A due that reads no GitHub answers without a credential: with the
/// landed-item trigger on, a revoked inherited token and no fallback, a due
/// the minutes decide answers `reason=minutes` and a fleet with no lane
/// answers nothing, each with no `gh` call; the landed-item count alone
/// runs the ladder, which refuses `auth-failed`.
#[test]
fn report_due_answers_without_a_credential_until_its_count() {
    let world = World::new();
    let _ = world.report_context();
    let bin = ladder_world(&world);
    let now = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let launched = clock::iso_utc(now - 7200);
    let due = |minutes: &str| {
        let out = isolated()
            .current_dir(world.path())
            .arg("--state-dir")
            .arg(world.path())
            .args(["report", "due", "--repo", "owner/repo"])
            .arg("--state")
            .arg(world.fleet_path())
            .env("PATH", tool_path(&[bin.as_path()]))
            .env("HOME", world.path().join("home"))
            .env("GH_TOKEN", "revoked")
            .env("LANE_MAIL_CLI", world.real_report_mail())
            .env("ORCH_REPORT_EVERY_MINUTES", minutes)
            .env("ORCH_REPORT_EVERY_ISSUES", "1")
            .env("ORCH_REPORT_QUIET_HOURS", "")
            .env("ORCH_OWNER_TIME_ZONE", "UTC")
            .output()
            .unwrap();
        let reply: Value = serde_json::from_slice(&out.stdout)
            .unwrap_or_else(|_| panic!("{}", String::from_utf8_lossy(&out.stderr)));
        reply
    };
    let calls = || std::fs::read_to_string(world.path().join("token-gh.calls")).unwrap_or_default();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":launched}]}));
    assert_eq!(
        due("60")["result"]["line"],
        json!(format!("report-due reason=minutes since={launched}"))
    );
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[]}));
    assert_eq!(due("60")["result"]["line"], Value::Null);
    assert_eq!(calls(), "", "no gh call before the count");
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":launched}]}));
    let reply = due("0");
    assert_eq!(reply["refusal"]["key"], "auth-failed", "{reply}");
    assert!(!calls().is_empty());
    // The project's bot token counts the landing where the inherited one is
    // revoked.
    let search = format!(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D{}&per_page=100&page=1",
        launched.replace(':', "%3A")
    );
    let mut planted = json!({"repos/owner/repo/pulls/1": {"body":{"number":1,"state":"closed","title":"Ship","body":"","merged_at":clock::iso_utc(now - 60),"merge_commit_sha":null,"author_association":"NONE","base":{"ref":"main","sha":"0123456789abcdef0123456789abcdef01234567"},"user":null,"head":{"sha":"0000000000000000000000000000000000000000","ref":"ken-1","repo":{"full_name":"owner/repo","owner":{"login":"owner","type":"User"}}}}}});
    planted[search.as_str()] = json!({"body":{"total_count":1,"incomplete_results":false,"items":[{"number":1,"pull_request":{}}]}});
    world.plant("gh.json", &planted);
    let out = isolated()
        .current_dir(world.path())
        .arg("--state-dir")
        .arg(world.path())
        .args(["report", "due", "--repo", "owner/repo"])
        .arg("--state")
        .arg(world.fleet_path())
        .env("PATH", tool_path(&[bin.as_path()]))
        .env("HOME", world.path().join("home"))
        .env("GH_TOKEN", "revoked")
        .env("GH_BOT_TOKEN", "good")
        .env("GH_FAKE_REPLIES", world.path().join("gh.json"))
        .env("GH_FAKE_LOG", world.path().join("gh.args"))
        .env("LANE_MAIL_CLI", world.real_report_mail())
        .env("ORCH_REPORT_EVERY_MINUTES", "0")
        .env("ORCH_REPORT_EVERY_ISSUES", "1")
        .env("ORCH_REPORT_QUIET_HOURS", "")
        .env("ORCH_OWNER_TIME_ZONE", "UTC")
        .output()
        .unwrap();
    let reply: Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|_| panic!("{}", String::from_utf8_lossy(&out.stderr)));
    assert_eq!(
        reply["result"]["line"],
        json!(format!(
            "report-due reason=issues since={launched} landed=1"
        )),
        "{reply}"
    );
}

/// The report's settings are its own: through the real settings load an
/// empty `ORCH_REPORT_EVERY_MINUTES` turns the timed report off and an
/// empty `ORCH_REPORT_QUIET_HOURS` turns quiet hours off, as the released
/// report read them; a value outside its form refuses the report's verb
/// and its duty's pass and leaves every other verb answering.
#[test]
fn report_settings_are_judged_by_the_report_alone() {
    let world = World::new();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[]}));
    let empty = world.settings_with(&[
        (report::MINUTES_KEY.to_owned(), String::new()),
        (report::QUIET_HOURS_KEY.to_owned(), String::new()),
    ]);
    let policy = report::Policy::of(&empty).unwrap();
    assert_eq!((policy.minutes, policy.quiet), (0, None));
    let invalid = world.settings_with(&[(report::QUIET_HOURS_KEY.to_owned(), "25-7".to_owned())]);
    let mut ctx = world.report_context();
    ctx.settings = invalid;
    let clock = FakeClock::new();
    let mut baseline = Baseline::default();
    let mut body = report::body(ctx);
    let err = pass(
        Duty::Report,
        &mut body,
        &mut baseline,
        &clock,
        epoch("2026-10-01T14:00:00Z"),
    )
    .unwrap_err();
    assert_eq!(err.key(), "settings-invalid", "{err:?}");
    let run = |args: &[&str]| {
        let out = isolated()
            .arg("--state-dir")
            .arg(world.path())
            .args(args)
            .env("HOME", world.path().join("home"))
            .env(report::QUIET_HOURS_KEY, "25-7")
            .output()
            .unwrap();
        serde_json::from_slice::<Value>(&out.stdout).unwrap()
    };
    let refused = run(&["report", "due", "--session-start", "1790000000"]);
    assert_eq!(refused["refusal"]["key"], "settings-invalid", "{refused}");
    let answered = run(&["state", "get", "--fleet", "/issue_id"]);
    assert_eq!(answered["result"]["value"], "oversee", "{answered}");
}

/// Every fleet request names its fleet record and the repositories it
/// reads, a session's due its start, and no request carries another verb's
/// field, as the released report refused each, so no report is judged or
/// rendered from a fleet or a repository nobody named.
#[test]
fn report_render_and_write_refuse_without_a_repository() {
    let world = World::new();
    let fleet = world.fleet_path().display().to_string();
    let f = fleet.as_str();
    let cases: [(&[&str], &str, Value); 11] = [
        (
            &[
                "write",
                "--session-start",
                "5",
                "--summary-file",
                "/nonexistent",
            ],
            "report-args",
            json!([["action", "write"]]),
        ),
        (
            &["render"],
            "report-args",
            json!([["action", "render"], ["cause", "missing-state"]]),
        ),
        (
            &["write", "--summary-file", "/nonexistent"],
            "report-args",
            json!([["action", "write"], ["cause", "missing-state"]]),
        ),
        (
            &["due"],
            "report-args",
            json!([["action", "due"], ["cause", "missing-state"]]),
        ),
        (
            &["render", "--state", f],
            "report-args",
            json!([["action", "render"], ["cause", "missing-repo"]]),
        ),
        (
            &["write", "--state", f, "--summary-file", "/nonexistent"],
            "report-args",
            json!([["action", "write"], ["cause", "missing-repo"]]),
        ),
        (
            &["due", "--state", f],
            "report-args",
            json!([["action", "due"], ["cause", "missing-repo"]]),
        ),
        (
            &["due", "--session-start", "0"],
            "report-args",
            json!([["action", "due"], ["cause", "session-start"]]),
        ),
        (
            &[
                "render",
                "--session-start",
                "5",
                "--state",
                f,
                "--repo",
                "owner/repo",
            ],
            "report-args",
            json!([["action", "render"]]),
        ),
        (
            &["due", "--state", f, "--repo", "owner/repo", "--succession"],
            "report-args",
            json!([["action", "due"]]),
        ),
        (
            &["write", "--state", f, "--repo", "owner/repo"],
            "report-summary",
            json!([["cause", "missing"]]),
        ),
    ];
    for (args, key, fields) in cases {
        let out = isolated()
            .arg("--state-dir")
            .arg(world.path())
            .arg("report")
            .args(args)
            .arg("--credential-selected")
            .env("HOME", world.path().join("home"))
            .output()
            .unwrap();
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["refusal"]["key"], key, "{args:?} {reply}");
        assert_eq!(reply["refusal"]["fields"], fields, "{args:?} {reply}");
    }
}

/// A write whose owner box could not be read back after its send keeps its
/// attempt, and its retry reads the box first: the notice that landed is
/// the receipt and no second notice is started.
#[test]
fn report_retry_reads_the_box_before_it_sends_again() {
    let world = World::new();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-10-01T06:00:00Z"}]}));
    let mut ctx = world.report_context();
    let real = ctx.settings.lane_mail_cli.clone();
    let wrapper = world.path().join("report-mail-unread-once");
    let flag = world.path().join("noticed");
    let log = world.path().join("notice.calls");
    write_executable(
        &wrapper,
        format!(
            "#!/bin/sh\ncase \"$1\" in\n  notice)\n    echo notice >> '{log}'\n    '{real}' \"$@\"\n    rc=$?\n    : > '{flag}'\n    exit $rc ;;\n  events)\n    if [ -f '{flag}' ] && [ ! -f '{flag}.read' ]; then\n      : > '{flag}.read'\n      echo 'lane-mail: mail-read-failed=overseer' >&2\n      exit 2\n    fi\n    exec '{real}' \"$@\" ;;\n  *) exec '{real}' \"$@\" ;;\nesac\n",
            log = log.display(),
            real = real.display(),
            flag = flag.display()
        ),
    );
    ctx.settings.lane_mail_cli = wrapper;
    let summary = world.path().join("summary.txt");
    std::fs::write(&summary, "The report is ready.").unwrap();
    let now = epoch("2026-10-01T14:00:00Z");
    assert!(report::write(&ctx, now, &summary, false).is_err());
    let retried = report::write(&ctx, now + 1, &summary, false).unwrap();
    assert!(retried["notice_id"].as_str().is_some(), "{retried}");
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "notice\n");
}

/// The attempt record serves its own report alone: a delivered write keeps
/// none, and a failed write's record left at a minute is no attempt of the
/// write a year later at that minute, which writes and sends its own body.
#[test]
fn report_attempt_records_end_with_their_report() {
    let world = World::new();
    world.write_fleet(&json!({"issue_id":"oversee","lanes":[{"item":"KEN-1","status":"done","launched_at":"2026-10-01T06:00:00Z"}]}));
    let mut ctx = world.report_context();
    let real = ctx.settings.lane_mail_cli.clone();
    let refusing = world.path().join("report-mail-refusing");
    write_executable(
        &refusing,
        format!(
            "#!/bin/sh\nif [ \"$1\" = notice ]; then\n  echo 'lane-mail: write-failed=overseer' >&2\n  exit 2\nfi\nexec '{}' \"$@\"\n",
            real.display()
        ),
    );
    ctx.settings.lane_mail_cli = refusing;
    let summary = world.path().join("summary.txt");
    std::fs::write(&summary, "Last year's report.").unwrap();
    let then = epoch("2026-10-01T14:00:00Z");
    assert!(report::write(&ctx, then, &summary, false).is_err());
    let dir = ctx.settings.store.progress_report_dir.clone();
    let file = dir.join("10-01-14-00.md");
    let attempt = dir.join("10-01-14-00.notice.json");
    assert!(attempt.exists());
    std::fs::remove_file(&file).unwrap();
    ctx.settings.lane_mail_cli = real;
    std::fs::write(&summary, "This year's report.").unwrap();
    let year = epoch("2027-10-01T14:00:00Z");
    let written = report::write(&ctx, year, &summary, false).unwrap();
    assert!(written["notice_id"].as_str().is_some(), "{written}");
    assert_eq!(
        std::fs::metadata(&file)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs(),
        year
    );
    assert!(
        !attempt.exists(),
        "the delivered write keeps no attempt record"
    );
    // The same summary again inside the box's day window: the report is
    // written and the notice refused, the owner already holding its text.
    let again = report::write(&ctx, year + 120, &summary, false).unwrap_err();
    assert!(
        again.to_string().contains("owner-notice-repeated"),
        "{again}"
    );
    assert!(dir.join("10-01-14-02.md").exists());
}
