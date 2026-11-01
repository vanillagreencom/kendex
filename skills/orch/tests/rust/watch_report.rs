//! The verification, report, heartbeat-body and retention duties (decisions
//! 121 Q5, Q8; 126 (1); 128 (9); 141 (1), (2), (6); step5-map § A1, § A5,
//! § A6, § A11): the `verifying` lines and `verifying-deadline` events on
//! the legacy's own fixtures, recorded once (decision 135 (5)); a deadline
//! row that moves only after its event line is durable; `report-due` once
//! per due with its reason and `report-unjudged` on a bad answer; both
//! duties indifferent to the controller's state; the heartbeat's body under
//! busy mail, carrying the capacity line and moving no due time, and saying
//! `unread` for every list no duty has read; and retention judging each
//! record by its own recorded end and its own session's close, writing
//! nothing over a fresh fleet record. Each row names the defect it catches
//! at its doc comment.
//!
//! Most rows call a duty's body on a hand-built tick and apply what it
//! produced to the baseline themselves, as the runner's `commit` does; the
//! rows that need the runner's threads drive it on the fake clock. Every
//! program a duty runs is a fixture symlinked into the row's world, named
//! to the duty through the settings or its context (decision 164).
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the fixtures and records they plant and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::process::Identity;
use orch_runtime::error::Error;
use orch_runtime::ops::Env;
use orch_runtime::ops::prune::{PruneRecords, RecordsPruned, prune_records};
use orch_runtime::schedule::{Clock, Duty};
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings};
use orch_runtime::state::{self, FLEET_FILE_NAME, InitFields, Locking};
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

/// The recorded legacy answers (`tmp/orch-rebuild/u5f/record-legacy.sh`).
fn recorded_lines(name: &str) -> Vec<String> {
    lines(&fixtures().join("legacy-recorded").join(name))
}

fn lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The Done-when text `oversee_watch_owed.sh`'s `verifying_world` gives
/// its two Verifying items.
const DEADLINE_BOXES: &str = "## Done when\n- [x] branch proof\n- [ ] Post-merge: Read deployed health; Where: live service; Why after merge: needs deployment; Deadline: 2026-10-02T00:00:00Z\n- [ ] Post-merge: Read consumer refresh; Where: consumer PR; Why after merge: needs rollout; Deadline: 2026-10-03T00:00:00Z";

/// One world: a state directory with the fleet record, the fixtures
/// symlinked under the names the duties run, and the settings naming them.
struct World {
    dir: tempfile::TempDir,
    settings: Settings,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let fix = fixtures();
        for (name, fixture) in [
            ("linear", "linear-fixture/linear.sh"),
            ("gh", "gh/gh"),
            ("lanes", "lanes-fixture/lanes"),
            ("oversee-report", "oversee-report-fixture/oversee-report"),
            ("github.sh", "github-fixture/github.sh"),
        ] {
            std::os::unix::fs::symlink(fix.join(fixture), dir.path().join(name)).unwrap();
        }
        let roots = Roots {
            project: dir.path().to_path_buf(),
            common: dir.path().to_path_buf(),
        };
        let at = |name: &str| dir.path().join(name).display().to_string();
        let settings = settings::load(
            &roots,
            &[
                ("ORCH_WATCH_MAIL_INTERVAL".into(), "5".into()),
                ("OVERSEE_WATCH_TRACKER".into(), at("linear").into()),
                ("OVERSEE_WATCH_LANES".into(), at("lanes").into()),
                ("OVERSEE_WATCH_REPORT".into(), at("oversee-report").into()),
            ],
            &SettingsFlags {
                state_dir: Some(dir.path().to_path_buf()),
                private_env: false,
            },
        )
        .unwrap();
        let world = World { dir, settings };
        world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": [], "fleet_log": []}));
        world
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

    fn report_context(&self) -> report::Context {
        report::Context {
            fleet: self.fleet_path(),
            settings: self.settings.clone(),
            github: self.path().join("github.sh"),
            repos: vec!["owner/repo".to_owned()],
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
            args: vec!["watch".into(), "run".into()],
        },
    )
}

/// Step5-map § A5, decision 135 (5). Defect: a `verifying` line or a
/// `verifying-deadline` event drifting from the legacy bytes the session
/// keys on; a standing deadline raised on every pass; a waiting box raised;
/// a container's outcome box missed or its child box read as open. The
/// legacy's answers on `oversee_watch_owed.sh`'s own worlds, recorded once
/// (`tmp/orch-rebuild/u5f/recorded/`): the deadline world's four events
/// and four lines, then nothing on the second pass with the lines held for
/// the heartbeat; the unfired trigger's four waiting lines and no event;
/// the Triage container's outcome box, then `boxes=0` once its only box is
/// the child's.
#[test]
fn the_verifying_lines_and_deadline_events_match_the_legacys_recorded_bytes() {
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

/// Step5-map § D, decision 121 Q5 (U5a's order on this duty). Defect: a
/// `verifying-deadline` row advanced before its event line is on disk, so
/// a crash between the two loses the deadline for good (the legacy
/// committed the row first, `A1:174`). Through the runner with the
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
fn report_fleet(overseer: Option<Value>) -> Value {
    let mut fleet = json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [
            {"item": "KEN-13", "status": "done", "launched_at": "2026-09-20T00:00:00Z", "tier": "small",
             "cycle": {"commit": "0123456789abcdef0123456789abcdef01234567",
                       "stamps": {"launched": "2026-09-20T00:00:00Z", "first_commit": "2026-09-20T00:01:00Z"}}},
            {"item": "KEN-4", "status": "parked", "launched_at": "2026-09-20T00:00:00Z",
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

/// Step5-map § A6, decisions 94, 128 (5), 130, 141 (6). Defect: a due
/// report said on every long pass (the legacy's, corrected by the row), or
/// not said again when its reason moves; a refused or unparsable answer
/// read as "not due" (silence); the span line missing a lane or reading an
/// unreadable timeline as none. `oversee-report due`'s answer through the
/// fixture: one `report-due` line with the four span lines, nothing while
/// it stands, the row cleared when the report is written, the line again
/// on a new reason; exit 1, two lines and a line of another shape each
/// refuse `report-unjudged` with the exit and the answer.
#[test]
fn report_due_prints_once_per_due_with_its_reason_and_a_bad_answer_is_report_unjudged() {
    let world = World::new();
    world.write_fleet(&report_fleet(None));
    world.plant(
        "github.json",
        &json!({"pr-timeline 14 owner/repo": {"body": {"pr": 14, "stamps": {"first_commit": "2026-09-20T00:10:00Z"}}}}),
    );
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let mut body = report::body(world.report_context());
    let mut baseline = Baseline::default();
    let due = "report-due reason=minutes since=2026-10-01T00:00:00Z";
    world.plant("oversee-report.json", &json!({"text": format!("{due}\n")}));
    let produced = pass(Duty::Report, &mut body, &mut baseline, &clock, wall).unwrap();
    let mut want = vec![format!("EVENT {due}")];
    want.extend(REPORT_BODY.iter().map(|l| (*l).to_owned()));
    assert_eq!(rendered(&produced), want);
    assert_eq!(baseline.get("report-due", "fleet"), Some(due));
    assert_eq!(
        lines(&world.path().join("oversee-report.log")),
        vec![format!(
            "due --state {} --repo owner/repo",
            world.fleet_path().display()
        )]
    );
    assert_eq!(
        lines(&world.path().join("github.log")),
        vec![
            "pr-timeline 14 --repo owner/repo".to_owned(),
            "pr-timeline 15 --repo owner/repo".to_owned()
        ],
        "a lane with a recorded cycle reads no timeline"
    );
    let again = pass(Duty::Report, &mut body, &mut baseline, &clock, wall + 240).unwrap();
    assert_eq!(
        rendered(&again),
        Vec::<String>::new(),
        "a standing due report is said once"
    );
    assert!(again.changes.is_empty(), "{again:?}");
    // The report was written: the judge answers nothing, the row clears.
    std::fs::remove_file(world.path().join("oversee-report.json")).unwrap();
    let written = pass(Duty::Report, &mut body, &mut baseline, &clock, wall + 480).unwrap();
    assert_eq!(rendered(&written), Vec::<String>::new());
    assert_eq!(baseline.get("report-due", "fleet"), None);
    let issues = "report-due reason=issues since=2026-10-01T00:00:00Z landed=3";
    world.plant(
        "oversee-report.json",
        &json!({"text": format!("{issues}\n")}),
    );
    let produced = pass(Duty::Report, &mut body, &mut baseline, &clock, wall + 720).unwrap();
    assert_eq!(rendered(&produced)[0], format!("EVENT {issues}"));
    assert_eq!(rendered(&produced).len(), 5);
    // A bad answer is `report-unjudged`, never silence.
    let bad: [(Value, &str); 3] = [
        (
            json!({"exit": 1, "text": "oversee-report: setting ORCH_REPORT_EVERY_MINUTES:x\n"}),
            "1",
        ),
        (json!({"text": format!("{due}\n{due}\n")}), "0"),
        (json!({"text": "report due reason=minutes\n"}), "0"),
    ];
    for (reply, exit) in bad {
        world.plant("oversee-report.json", &reply);
        let err = pass(Duty::Report, &mut body, &mut baseline, &clock, wall + 960).unwrap_err();
        assert_eq!(err.key(), "report-unjudged", "{reply}");
        assert!(
            err.fields().contains(&("exit".to_owned(), exit.to_owned())),
            "{reply}: {:?}",
            err.fields()
        );
    }
    assert_eq!(
        baseline.get("report-due", "fleet"),
        Some(issues),
        "a refused pass moves no row"
    );
}

/// Decision 121 Q8. Defect: a controller gate on verification or the
/// report (the legacy ran neither while the overseer read dead, walled or
/// off, `A1:232`). The same fleet with no controller record, with an
/// explicit `off`, and with a record naming a pane on a server that is
/// gone: both duties produce the same lines on each.
#[test]
fn verification_and_report_run_with_the_controller_dead_walled_and_off() {
    let clock = FakeClock::new();
    let now = epoch("2026-10-02T00:00:01Z");
    let due = "report-due reason=minutes since=2026-10-01T00:00:00Z";
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
        world.plant("oversee-report.json", &json!({"text": format!("{due}\n")}));
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

/// Decisions 121 Q5, Q9, 126 (1), 130; step5-map § A1, § B row 5.
/// Defect: a heartbeat body that moves its own due time or is moved by
/// mail; a body line drifting from the legacy bytes (the open list, the
/// roster, the verifying and owed lines with their wall verdicts); the
/// capacity line missing or naming held items. Under one mail event every
/// 7 s for 7000 s, with the tracker, GitHub and verification slots holding
/// `oversee_watch_owed.sh`'s world and the account fixture its roster and
/// picks: one heartbeat at the first tick at or past 6000 s, its block the
/// legacy's recorded bytes, then the quota, reducer and capacity lines.
#[test]
fn the_heartbeat_body_carries_the_capacity_line_and_moves_no_due_time() {
    let world = World::new();
    let paths = world.paths();
    let account = |alias: &str, harness: &str, verdict: &str, resets: &str| {
        json!({"alias": alias, "harness": harness, "config_dir": format!("/home/u/.{alias}"),
               "measured_through": "local", "status": "ok", "verdict": verdict, "headroom_pct": 0,
               "binding_bucket": "weekly", "binding_resets_at": resets})
    };
    world.plant(
        "lanes.json",
        &json!([
            account("claude", "claude", "room", "2026-10-01T00:00:00Z"),
            account("claude2", "claude", "walled", "2026-10-02T00:00:00Z"),
            account("codex", "codex", "walled", "2026-10-05T00:00:00Z"),
            account("codex2", "codex", "walled", "2026-10-03T00:00:00Z"),
        ]),
    );
    world.plant(
        "pick-claude-claude-sonnet-5.json",
        &json!({"exit": 0, "body": {"config_dir": "/home/u/.claude"}}),
    );
    world.plant(
        "pick-codex--.json",
        &json!({"exit": 3, "body": {"walled": 2, "unmeasured": 0, "walled_resets_at": "2026-10-03T00:00:00Z"}}),
    );
    world.plant(
        "pick-claude-claude-opus-5.json",
        &json!({"exit": 3, "body": {"walled": 2, "unmeasured": 0, "walled_resets_at": "2026-10-04T00:00:00Z"}}),
    );
    world.plant(
        "pick-provider-x-codex--.json",
        &json!({"exit": 0, "body": {"config_dir": "/home/u/.codex"}}),
    );
    world.plant(
        "gh.json",
        &json!({"repos/owner/repo/pulls?state=open&per_page=100&page=1": {"body": [
            {"number": 16, "title": "the review item", "head": {"ref": "ken-6"}}
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
                    "provider-x",
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
    let clock = FakeClock::new();
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
            settings: world.settings.clone(),
            max_loops: 25,
            interval: secs(240),
            since: None,
            repos: vec!["owner/repo".to_owned()],
            gh: world.path().join("gh"),
            shared,
            verifying,
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
    // The recording ran the legacy watch with `--max-loops 1 --interval 0`;
    // its first line is the flags', every line under it the body's.
    let mut want = vec!["EVENT heartbeat loops=25 interval=240s since=none".to_owned()];
    want.extend(recorded_lines("heartbeat.out").into_iter().skip(1));
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
    // The roster once with no host, the hosted listing under its host, one
    // pick per host, harness and model.
    let calls = lines(&world.path().join("lanes.log"));
    assert_eq!(
        calls
            .iter()
            .filter(|c| c.ends_with(" list --json"))
            .cloned()
            .collect::<Vec<_>>(),
        vec![
            "ORCH_LANE_HOST=unset list --json".to_owned(),
            "ORCH_LANE_HOST=provider-x list --json".to_owned()
        ],
        "{calls:?}"
    );
    assert_eq!(
        calls.iter().filter(|c| c.contains(" pick ")).count(),
        4,
        "{calls:?}"
    );
}

/// R-RECON S7. Defect: a heartbeat with nothing read yet saying nothing
/// where the owed list goes, so a standing tracker failure reads as
/// nothing owed. The body with every slot empty, the roster refused and
/// the open list unanswered: each list's `unread` line in its place, the
/// owed list's among them.
#[test]
fn the_heartbeat_body_says_unread_for_every_list_no_duty_has_read() {
    let world = World::new();
    std::fs::write(world.path().join("lanes.rc"), "1\n").unwrap();
    let clock = FakeClock::new();
    let mut body = heartbeat::body(heartbeat::Context {
        settings: world.settings.clone(),
        max_loops: 25,
        interval: secs(240),
        since: None,
        repos: vec!["owner/repo".to_owned()],
        gh: world.path().join("gh"),
        shared: Shared::default(),
        verifying: Lines::default(),
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
            "account-roster unread".to_owned(),
            "owed unread".to_owned(),
            "open-unblocked count=unread items=-".to_owned(),
        ]
    );
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

/// Decisions 128 (9), 141 (1), (2), 146. Defect: a lane read ended by
/// `done` alone (an old vintage's `closed` record kept for a month, round
/// 6 item 1); a record judged by a directory's newest write (an append-only
/// `handoffs/` keeping a sibling's file alive); a lane with its worktree
/// standing and no reason recorded pruned; a kept worktree touched; unread
/// mail or the newest log segment removed; the fleet start's record
/// dropped; a running lane relaunched after a confirmed close read ended by
/// that earlier session's close, its state files deleted and its record
/// dropped (R-RECON F1). One pass at the fake wall over ten records and
/// three segments.
#[test]
fn retention_prunes_each_record_by_its_own_recorded_end_and_never_unread_mail_or_a_kept_worktree() {
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
        json!({"id": format!("close-owned-resources:{item}:1-1"), "op": "close-owned-resources",
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
    // The paths: each item's state, lock, run directory and handoff, the
    // mailbox beside them; the live lane's handoff written now makes the
    // handoffs directory's newest write now.
    let dir = world.path();
    for item in [
        "KEN-0", "KEN-A", "KEN-B", "KEN-C", "KEN-D", "KEN-E", "KEN-G", "KEN-H", "KEN-R",
    ] {
        touch(&dir.join(format!("workflow-state-{item}.json")));
        touch(&dir.join(format!("workflow-state-{item}.json.lock")));
        touch(&dir.join(format!("{item}.run")).join("stdout.log"));
        touch(&dir.join("handoffs").join(format!("{item}-handoff.md")));
        touch(&dir.join("lane-mail").join(item).join("to-lane.jsonl"));
        for path in [
            dir.join(format!("workflow-state-{item}.json")),
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
    let pruned = retention::pass(&world.fleet_path(), &paths, dir, 5, wall).unwrap();
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
        for path in [
            dir.join(format!("workflow-state-{item}.json")),
            dir.join(format!("workflow-state-{item}.json.lock")),
            dir.join(format!("{item}.run")),
            dir.join("handoffs").join(format!("{item}-handoff.md")),
        ] {
            assert!(gone(path.clone()), "{} pruned", path.display());
        }
        assert!(
            !gone(dir.join("lane-mail").join(item).join("to-lane.jsonl")),
            "{item}: unread mail is never pruned"
        );
    }
    for item in ["KEN-C", "KEN-D", "KEN-E", "KEN-R"] {
        for path in [
            dir.join(format!("workflow-state-{item}.json")),
            dir.join(format!("workflow-state-{item}.json.lock")),
            dir.join(format!("{item}.run")),
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
        lanes: pruned.records.clone(),
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
    let again = retention::pass(&world.fleet_path(), &paths, dir, 5, wall).unwrap();
    assert_eq!(again.segments, Vec::<PathBuf>::new());
    assert_eq!(again.paths, Vec::<PathBuf>::new());
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

/// R-RECON S3. Defect: a first retention pass rewriting a fresh fleet
/// record (`state init --fleet` writes no `lanes` and no `fleet_log`; an
/// array read that inserts the absent key changes the document, and the
/// store writes it). The duty on the fake clock over the record as `state
/// init` writes it: the pass is stamped and the file's bytes are as before.
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
