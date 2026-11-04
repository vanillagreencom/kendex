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

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::process::Identity;
use agent_runtime::record::{SystemTimer, Wait};
use orch_runtime::error::Error;
use orch_runtime::ops::Env;
use orch_runtime::ops::prune::{PlannedRows, PruneRecords, RecordsPruned, prune_records};
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

/// The recorded answers these duties keep byte for byte.
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

/// The Done-when text the recorded owed world gives its two Verifying items.
const DEADLINE_BOXES: &str = "## Done when\n- [x] branch proof\n- [ ] Post-merge: Read deployed health; Where: live service; Why after merge: needs deployment; Deadline: 2026-10-02T00:00:00Z\n- [ ] Post-merge: Read consumer refresh; Where: consumer PR; Why after merge: needs rollout; Deadline: 2026-10-03T00:00:00Z";

/// The mailbox program as the retention duty runs it: each call's argv a
/// line of `lane-mail.argv` beside it; with `lane-mail.refuse` beside it,
/// a keyed refusal and exit 2.
const LANE_MAIL_FIXTURE: &str = r#"#!/bin/sh
here="$(dirname "$0")"
printf '%s\n' "$*" >> "$here/lane-mail.argv"
if [ -e "$here/lane-mail.refuse" ]; then
  echo "lane-mail: write-failed=$here/tmp/lane-mail/overseer" >&2
  exit 2
fi
echo "compacted item=overseer to-lane=0 to-overseer=0"
"#;

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
        let dir = tempfile::tempdir().unwrap();
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
        let mail = dir.path().join("lane-mail-fixture");
        std::fs::write(&mail, LANE_MAIL_FIXTURE).unwrap();
        std::fs::set_permissions(&mail, std::fs::Permissions::from_mode(0o755)).unwrap();
        let at = |name: &str| dir.path().join(name).display().to_string();
        // The accounts the listing lists are planted under `home` with
        // their records, served for a day of the fake clock; no usage
        // endpoint is ever reached, and a request that slipped past the
        // records would open no socket.
        let env: Vec<(String, String)> = [
            ("ORCH_WATCH_MAIL_INTERVAL", "5".to_owned()),
            ("FLEET_DIR", at("fleet")),
            ("OVERSEE_WATCH_TRACKER", at("linear")),
            ("OVERSEE_WATCH_LANES", at("lanes")),
            ("OVERSEE_WATCH_REPORT", at("oversee-report")),
            ("LANE_MAIL_CLI", mail.display().to_string()),
            ("HOME", at("home")),
            ("OVERSEE_WATCH_STATE_DIR", at("")),
            ("ORCH_LANES_USAGE_TTL", "86400".to_owned()),
            (
                "ORCH_LANES_CLAUDE_USAGE_URL",
                "file:///nonexistent/usage".to_owned(),
            ),
            (
                "ORCH_LANES_CODEX_USAGE_URL",
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
            .map(|(k, v)| (k.into(), v.into()))
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

/// Defect: a `verifying` line or a
/// `verifying-deadline` event drifting from the recorded bytes the session
/// keys on; a standing deadline raised on every pass; a waiting box raised;
/// a container's outcome box missed or its child box read as open. The
/// recorded answers on the owed suite's own worlds, recorded once: the
/// deadline world's four events
/// and four lines, then nothing on the second pass with the lines held for
/// the heartbeat; the unfired trigger's four waiting lines and no event;
/// the Triage container's outcome box, then `boxes=0` once its only box is
/// the child's.
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

/// Defect: a
/// `verifying-deadline` row advanced before its event line is on disk, so
/// a crash between the two loses the deadline for good. Through the runner
/// with the
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

/// Defect: a due
/// report said on every long pass, or
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

/// Defect: a controller gate on verification or the report, so neither
/// runs while the overseer reads dead, walled or off. The same fleet with no controller record, with an
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

/// Defect: a heartbeat body that moves its own due time or is moved by
/// mail; a body line drifting from the recorded bytes (the open list, the
/// roster, the verifying and owed lines with their wall verdicts); the
/// capacity line missing or naming held items; an owed verdict that
/// ignores the listing the judge reads. Under one mail event every 7 s for
/// 7000 s, with the tracker, GitHub and verification slots holding
/// the recorded owed world and the
/// listing fixture its roster: one heartbeat at the first tick at or past
/// 6000 s, its block the recorded bytes, then the quota, reducer
/// and capacity lines. The owed verdicts are the accounts judge's over the
/// listing's windows: the
/// Opus windows of both claude accounts walled until 2026-10-04 and their
/// shared windows with room, so an Opus launch is `dated` there and a
/// Sonnet one `queue`; every codex window walled, codex2 resetting first;
/// the hosted codex record judged on the provider's own listing under its
/// host (the judge reads the provider's rows and asks the reader for
/// no pick), where the one codex account has room, and the host's
/// capability line read for the repository rule.
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

/// Defect: a heartbeat with nothing read yet saying nothing
/// where the owed list goes, so a standing tracker failure reads as
/// nothing owed. The body with every slot empty, the roster refused and
/// the open list unanswered: each list's `unread` line in its place, the
/// owed list's among them.
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
/// `reset_unparsed` and `shared_alias` cases. Defect: an account's change said twice while unchanged (the row
/// not advanced), or not said again on the next change; the `change=` or
/// `was=` text drifting from the recorded bytes; a reset time that moved
/// while still ahead read as a reset, or a passed reset the reading still
/// names; an account the listing dropped for a pass losing its row, so its
/// return is judged against nothing; two accounts sharing an alias judged
/// as one. Each sequence is its passes' listings and the account events
/// each pass says, at the wall it runs at.
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

/// The recorded accounts world's sequence table and its four controls.
/// Defect: an unmeasured reading moving the
/// row (so a provider holding a credential while a lane runs flaps an
/// event every other pass, the recorded watch's `flap` control); a measured
/// change after the gap not said (`measured`); an `expired` or `retired`
/// reading after a measured one not said, or said only once when it
/// recurs after a renewal (`expired`, `retired`); an unmeasured first
/// sighting written as a row. Each row of the table is one pass's
/// reading, the event tail it says and the `account` row saved under the
/// recorded watch's key afterwards, `-` for none.
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

/// Defect: a listing that could not be read, read as a fleet with no
/// accounts or as no change: the pass not counted a failure, the roster
/// printed as accounts, the row moved, so the next readable pass says the
/// change against nothing. A home discovery cannot list is a counted
/// failure with `account-roster unread` and the row as it stood; the
/// readable pass after it says the change against the reading before it.
#[test]
fn an_unreadable_listing_is_a_counted_failure_that_keeps_the_previous_reading() {
    use std::os::unix::fs::PermissionsExt;
    let world = World::new();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let mut baseline = Baseline::default();
    let claude = |reading: &str| vec![account_record("claude", "local", reading)];
    let planted = world.plant_accounts(None, &claude("ok walled 2 2026-10-01T00:00:00Z"), wall);
    // The planted directory is named to discovery alone: the listing
    // reads the home for every other account.
    let planted: Vec<(String, String)> = planted
        .into_iter()
        .filter(|(k, _)| k != "ORCH_LANE_DIRS")
        .collect();
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

/// Defect: a lane read ended by
/// `done` alone (an old vintage's `closed` record kept for a month); a record judged by a directory's newest write (an append-only
/// `handoffs/` keeping a sibling's file alive); a lane with its worktree
/// standing and no reason recorded pruned; a kept worktree touched; mail
/// written within the retention or the newest log segment removed; the fleet start's record
/// dropped; a running lane relaunched after a confirmed close read ended by
/// that earlier session's close, its state files deleted and its record
/// dropped. One pass at the fake wall over ten records and
/// three segments.
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

/// Defect: a prune that reaches past its two arrays and
/// drops a standing instruction from the live record, so a successor
/// re-applies a stop the owner had lifted. A standing
/// instruction is a row of the fleet record's `standing[]` and has no
/// retention; the fixture's is older than the cutoff, with a `fleet_log`
/// row on each side of the cutoff. The duty as the runner runs it, the
/// record read back from the disk after the store's write: the aged row and
/// the closed lane's record leave, the array is byte for byte what was
/// written.
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

/// Defect: a first retention pass rewriting a fresh fleet
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

/// Defect: an open intent's receipt or request, a brief, a closed intent's
/// notice or a file no intent names removed with the closed intents' files,
/// so the effect, the reconcile or the mailbox that still reads it finds
/// nothing; and a unit removed with no archive is the only copy's end. One
/// pass over an open intent and a closed one, each with files older than
/// the cutoff, unnamed files under `intents/`, the handoff files and the
/// progress reports: only the closed intent's receipt, request and job
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
    let mut held = lane_intent("launch-lane", "KEN-1", "not-started", None);
    held["phase"] = json!({"phase": "opening", "server": 1, "server_start": 1, "socket": "/none",
                           "since_ms": 0, "brief": brief.display().to_string()});
    let mut closed = lane_intent("close-owned-resources", "KEN-2", "confirmed", None);
    closed["completed_at"] = json!(old);
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [lane("KEN-0", "running", &old, json!({}))],
        "intents": [held, closed]
    }));
    let stands = [
        intents.join("launch-lane:KEN-1:1-1.pane"),
        intents.join("launch-lane:KEN-1:1-1.request"),
        brief.clone(),
        intents.join("close-owned-resources:KEN-2:1-1.notice"),
        intents.join("close-owned-resources:KEN-2:1-1.pane.tmp"),
        intents.join("stray.pane"),
        intents.join("fresh.pane"),
        dir.join("handoffs").join("OVERSEER-HANDOFF.md"),
        dir.join("handoffs").join("session-1.md"),
        dir.join("tmp").join("progress-reports").join("notes.md"),
    ];
    let leaves = [
        intents.join("close-owned-resources:KEN-2:1-1.pane"),
        intents.join("close-owned-resources:KEN-2:1-1.request"),
        intents.join("close-owned-resources:KEN-2:1-1.job"),
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

/// Defect: a receipt a pane writes after its intent was closed by hand,
/// judged by that close alone and removed on the next pass, so the watch
/// reads the live pane as a stray. A launch closed ten days ago, its
/// request as old and its receipt written a minute ago: the request leaves
/// and the receipt stands.
#[test]
fn retention_keeps_a_receipt_written_after_its_intent_closed() {
    let world = World::new();
    let wall = FakeClock::new().wall_secs();
    let mut closed = lane_intent("launch-lane", "KEN-3", "failed", None);
    closed["completed_at"] = json!(clock::iso_utc(wall - 10 * 86_400));
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [], "intents": [closed]
    }));
    let intents = world.path().join("intents");
    let request = intents.join("launch-lane:KEN-3:1-1.request");
    touch(&request);
    set_modified(&request, wall - 10 * 86_400);
    let receipt = intents.join("launch-lane:KEN-3:1-1.pane");
    touch(&receipt);
    set_modified(&receipt, wall - 60);
    let pruned = world.pass(wall).unwrap();
    assert_eq!(pruned.paths.len(), 1, "{:?}", pruned.paths);
    assert!(!request.exists(), "the old request leaves");
    assert!(receipt.exists(), "the late receipt stands");
}

/// Defect: nothing compacts the overseer mailbox, or a refused compaction
/// stops the prune or passes unsaid. The duty as the runner runs it, the
/// mailbox program refusing: it was asked to compact the overseer mailbox
/// at the main checkout, the pass says `watch-step-failed`, and a file
/// past the retention still leaves.
#[test]
fn the_retention_duty_compacts_the_overseer_mailbox_and_says_a_refusal() {
    let world = World::new();
    let paths = world.paths();
    let clock = FakeClock::new();
    let wall = clock.wall_secs();
    let old = world.path().join("workflow-state-KEN-9.json");
    std::fs::write(&old, "{}\n").unwrap();
    set_modified(&old, wall - 10 * 86_400);
    touch(&world.path().join("lane-mail.refuse"));
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
    assert_eq!(
        lines(&world.path().join("lane-mail.argv")),
        vec![format!(
            "compact --item overseer --root {}",
            world.path().display()
        )]
    );
    assert_eq!(
        lines(&paths.log),
        vec!["EVENT watch-step-failed step=retention count=1".to_owned()]
    );
    assert!(std::fs::symlink_metadata(&old).is_err(), "the prune ran");
}

/// The real program `name` on this host's `PATH`, which a fixture execs.
fn real(name: &str) -> String {
    let out = program("sh")
        .args(["-c", &format!("command -v {name}")])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// Defect: the retention pass removes an item record while a writer holds
/// its lock mid-update, so the write in flight is lost, or removes a record
/// written since the pass judged it. A stale record with no lane record and
/// no worktree, the shell store's `update` held between its locked read and
/// its move by a `jq` that waits for a release; the pass starts and is
/// released into after the writer: the update lands and the record stands.
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
    std::fs::write(
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
    )
    .unwrap();
    std::fs::set_permissions(&jq, std::fs::Permissions::from_mode(0o755)).unwrap();
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

/// Defect: one record whose lock stays held, a stale mutex on a host
/// without `flock`, fails every retention pass, so nothing else ever ages
/// out. The duty as the runner runs it under the mutex policy with a short
/// wait, over an old record whose `.lock.d` stands and another old record:
/// the pass says `watch-step-failed`, the record and its mutex stand for
/// the next pass, and the other record leaves.
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
                    timer: &SystemTimer,
                },
                legacy_mutex: true,
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

/// Defect: a record's lock taken with its record, so a holder of the
/// unlinked inode and a newcomer on a new one both hold "the" lock once the
/// key is created again. An old item record with its old lock and mutex:
/// the record leaves; its lock and mutex stand.
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

/// Defect: the retention pass drops a lane row, the item's record and its
/// mailbox from a judgement the fleet moved under: a relaunch during the
/// archive turns the ended lane live, and the pass removes it all anyway.
/// The duty's body, its `tar` updating the lane to `running` under a new
/// session and appending a mailbox turn before it archives: the live row,
/// the record and the mailbox all stand.
#[test]
fn retention_keeps_a_lane_relaunched_during_its_archive() {
    if std::env::var_os("RELAUNCH_CHILD").is_none() {
        // The archive's `tar` is found on this process's `PATH`: the row
        // runs again as a child with the fixture first on it.
        let dir = tempfile::tempdir().unwrap();
        let shim = dir.path().join("tar");
        std::fs::write(
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
        )
        .unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
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

/// Defect: `prune-records` drops an item's rows that a writer moved since
/// the judgement read them. The judgement's rows of an ended lane, and the
/// fleet record holding that lane relaunched: nothing leaves and the item
/// is not confirmed; the unmoved item's rows leave.
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

/// Defect: a session rows file the fleet record still names retired
/// because its pane is gone, so the overseer or the successor bound to it
/// loses its rows. Four files of panes the private ambient server does not
/// hold, three named by `overseer.session_rows`, `overseer.pending.
/// session_rows` and `pending.session_rows`: only the unnamed one leaves.
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

/// Defect: an ended lane's row kept for good once its item's files are
/// gone, since the rows the commit drops came only from items a file
/// names. An ended lane whose item `state remove` closed out: two duty
/// passes, and the row has left.
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

/// Defect: an entry of the state directory the pass names no kind for
/// removed by its age, though a writer the pass does not serialize can
/// still write or bind it: a lane's own files, a handoff, a brief, the
/// completion summary and audit of an item whose state expired, a mailbox,
/// the claim store, a directive send's receipt, an owner alert's notice or
/// operator scratch; or removed by a later pass once its item's record and
/// row are gone. An ended lane and an expired item with no lane, each with
/// its record past the retention, and every such entry ten days old: the
/// two records and the row leave, and through a second pass everything
/// else stands.
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

/// Defect: an item with no lane record whose workflow state is older than
/// the retention is pruned under the lane still working in its worktree
/// (a state that names a linked worktree or a branch a linked worktree has
/// checked out), or kept forever when it names nothing that stands. The
/// twelve shapes a workflow state names a worktree in, on a repository with
/// linked worktrees, one pass: each state is kept or removed as the table
/// says.
#[test]
fn retention_keeps_an_item_state_that_names_a_standing_linked_worktree_and_takes_the_rest() {
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
