//! The tracker and GitHub read duties: each inventory read once per pass
//! through the linear, gh and mailbox fixtures and the github package's
//! reducer reading through that gh, a dependency
//! failure refusing the inventory and never reading as an empty set, the
//! quota receipt holding the tracker reads alone, the recorded watch's
//! answers on its own fixtures, the triage key, the terminal close, the
//! heartbeat's inputs, and the GitHub duty's split from the tracker's: the
//! reducer pass, the security alerts, the outside contributions, the budget
//! scan, the owner's tracker answers and the due tracker asks. Each row's
//! name carries the defect it catches.
//!
//! Most rows call the duty's body on a hand-built tick and apply what it
//! produced to the baseline themselves, as the runner's `commit` does; the
//! rows that need the runner's threads drive it on the fake clock.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the fixtures and records they plant and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use agent_runtime::record::{FLEET_FILE_NAME, Locking};
use std::collections::BTreeMap;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use agent_runtime::clock::Clock;
use agent_runtime::process::Identity;
use agent_runtime::settings::Roots;
use orch_runtime::error::Error;
use orch_runtime::schedule::Duty;
use orch_runtime::settings::{self, Flags as SettingsFlags, Settings};
use orch_runtime::watch::github;
use orch_runtime::watch::heartbeat;
use orch_runtime::watch::tracker::{self, Context, OpenHold, OwedState, Shared, TerminalState};
use orch_runtime::watch::verifying;
use orch_runtime::watch::{
    self, Baseline, Change, Event, Flags, Paths, Produced, Recorded, Runner, Tick,
};
use serde_json::{Value, json};
use support::*;

/// The floor the recorded watch ran with.
const SINCE: &str = "2026-08-15T09:00:00Z";
const SINCE_EPOCH: u64 = 1_786_784_400;

/// One world: a fleet record, the two fixtures' reply maps and logs, and
/// the wrappers that hand each fixture its map.
struct World {
    dir: tempfile::TempDir,
    linear_replies: BTreeMap<String, Value>,
    gh_replies: BTreeMap<String, Value>,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let world = World {
            dir,
            linear_replies: BTreeMap::from([
                ("comments owner-questions".to_owned(), json!({"body": []})),
                (
                    "comments owner-questions --prefix".to_owned(),
                    json!({"body": "a54c6f77-50d1-"}),
                ),
            ]),
            gh_replies: BTreeMap::new(),
        };
        world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": [], "fleet_log": []}));
        // Each fixture is symlinked into the world under the name the duty
        // runs, and reads its map and log beside that name; the github
        // package's reducer runs behind its wrapper there, which a child
        // writes, so no other row's child holds it open (ETXTBSY). Its
        // listing has no answer until a row plants one: the reducer's
        // global failure, which `quiet_audits` answers for the one
        // repository most rows name.
        let fix = fixtures();
        for (name, fixture) in [
            ("linear", "linear-fixture/linear.sh"),
            ("linear-held", "linear-hold/linear.sh"),
            ("gh", "gh/gh"),
        ] {
            std::os::unix::fs::symlink(fix.join(fixture), world.dir.path().join(name)).unwrap();
        }
        real_github_script(&world.dir.path().join("pr-watch"), "pr-watch.sh");
        world.store();
        world
    }

    fn fleet_path(&self) -> PathBuf {
        self.dir.path().join(FLEET_FILE_NAME)
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

    fn linear(&mut self, key: &str, reply: Value) -> &mut World {
        self.linear_replies.insert(key.to_owned(), reply);
        self.store();
        self
    }

    fn gh(&mut self, path: &str, reply: Value) -> &mut World {
        self.gh_replies.insert(path.to_owned(), reply);
        self.store();
        self
    }

    fn store(&self) {
        std::fs::write(
            self.dir.path().join("linear.json"),
            serde_json::to_string(&self.linear_replies).unwrap(),
        )
        .unwrap();
        std::fs::write(
            self.dir.path().join("gh.json"),
            serde_json::to_string(&self.gh_replies).unwrap(),
        )
        .unwrap();
    }

    /// The fixture's call log, one argv line per call.
    fn linear_calls(&self) -> Vec<String> {
        lines(&self.dir.path().join("linear.log"))
    }

    fn gh_calls(&self) -> Vec<String> {
        lines(&self.dir.path().join("gh.log"))
    }

    /// The comments the fixture was asked to create, in order: each one's
    /// issue, parent (empty for none) and whole body.
    fn posted_comments(&self) -> Vec<(String, String, String)> {
        self.comment_calls()
            .iter()
            .map(|c| {
                let text = |k: &str| c[k].as_str().unwrap().to_owned();
                (text("issue"), text("parent"), text("body"))
            })
            .collect()
    }

    /// Each comment and its original argv, including the body's exact bytes.
    fn comment_calls(&self) -> Vec<Value> {
        lines(&self.dir.path().join("linear-comments.jsonl"))
            .iter()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    /// The gh fixture's environment log: `GH_TOKEN=<value> <argv>` per
    /// call, the first line of each entry (a GraphQL query argument spans
    /// lines of its own).
    fn gh_env(&self) -> Vec<String> {
        lines(&self.dir.path().join("gh.env"))
            .into_iter()
            .filter(|l| l.starts_with("GH_TOKEN="))
            .collect()
    }

    /// `repo`'s open pull requests as GitHub answers the reducer's listing.
    fn pulls(&mut self, repo: &str, pulls: Vec<Value>) -> &mut World {
        let (owner, name) = repo.split_once('/').unwrap();
        self.gh(
            &format!("graphql pulls owner={owner} name={name}"),
            reducer_listing(pulls),
        )
    }

    /// The settings a duty in this world runs under: the fixture as the
    /// tracker, the real mailbox program as the close's, the team,
    /// and the alert pass off (its token file is a row's own plant; with
    /// none the pass prints its credential-unread line). A later `extra`
    /// entry overrides.
    fn settings(&self, extra: &[(&str, &str)]) -> Settings {
        let dir = self.dir.path();
        let roots = Roots {
            project: dir.to_path_buf(),
            common: dir.to_path_buf(),
        };
        let mut env: Vec<(std::ffi::OsString, std::ffi::OsString)> = vec![
            ("OVERSEE_WATCH_TRACKER".into(), dir.join("linear").into()),
            ("LANE_MAIL_CLI".into(), lane_mail().into()),
            ("LINEAR_TEAM".into(), "kendex".into()),
            ("ORCH_SECURITY_ALERTS".into(), "off".into()),
        ];
        for (k, v) in extra {
            env.push(((*k).into(), (*v).into()));
        }
        settings::load(
            &roots,
            &env,
            &SettingsFlags {
                state_dir: Some(dir.to_path_buf()),
                private_env: false,
            },
        )
        .unwrap()
    }

    fn context(&self, settings: Settings, since: Option<&str>) -> Context {
        Context {
            fleet: self.fleet_path(),
            settings,
            since: since.map(|_| SINCE_EPOCH),
            gh: self.dir.path().join("gh"),
            repos: Vec::new(),
            locking: Locking::FLOCK,
            nonce: 7,
            owner: Some(agent_runtime::intent::Owner {
                pid: u64::from(std::process::id()),
                start: start_of(std::process::id()),
            }),
            shared: Shared::default(),
        }
    }

    /// The GitHub duty's context: the `--repo` names, the fixtures as `gh`
    /// and the reducer, the slot shared with the tracker duty.
    fn github_context(
        &self,
        settings: Settings,
        since: Option<&str>,
        repos: &[&str],
        shared: Shared,
    ) -> github::Context {
        github::Context {
            fleet: self.fleet_path(),
            settings,
            since: since.map(|_| SINCE_EPOCH),
            since_iso: since.map(str::to_owned),
            repos: repos.iter().map(|r| (*r).to_owned()).collect(),
            gh: self.dir.path().join("gh"),
            pr_watch: self.dir.path().join("pr-watch"),
            shared,
        }
    }
}

fn lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The statuses every tracker world answers (`linear-stub.sh`'s default).
fn statuses() -> Value {
    json!({"body": [
        {"name": "In Progress", "type": "started"}, {"name": "In Review", "type": "started"},
        {"name": "Verifying", "type": "started"}, {"name": "Todo", "type": "unstarted"},
        {"name": "Backlog", "type": "backlog"}, {"name": "Triage", "type": "triage"},
        {"name": "Done", "type": "completed"}, {"name": "Canceled", "type": "canceled"}
    ]})
}

/// One open item in the owed select's shape.
fn item(
    id: &str,
    created_at: &str,
    state: &str,
    state_type: &str,
    priority: Value,
    blocked_by: &[&str],
) -> Value {
    json!({"id": id, "title": id, "description": "", "in_pr_bundle": false, "priority": priority,
        "state": state, "state_type": state_type, "parent_id": "", "created_at": created_at,
        "blocked_by_open": blocked_by, "blocked_by": blocked_by, "blocked_by_launch": blocked_by,
        "labels": []})
}

/// The triage world the recorded watch ran.
fn triage_items() -> Vec<Value> {
    vec![
        item(
            "KEN-1",
            "2026-08-16T00:00:00.000Z",
            "Todo",
            "unstarted",
            json!(2),
            &[],
        ),
        item(
            "KEN-2",
            "2026-08-17T00:00:00Z",
            "In Progress",
            "started",
            json!(1),
            &["KEN-1"],
        ),
        item(
            "KEN-3",
            "2026-08-18T00:00:00Z",
            "Todo",
            "unstarted",
            json!(0),
            &[],
        ),
        item(
            "KEN-4",
            "2026-08-19T00:00:00Z",
            "Backlog",
            "backlog",
            Value::Null,
            &[],
        ),
        item(
            "KEN-5",
            "2026-08-01T00:00:00Z",
            "Todo",
            "unstarted",
            json!(3),
            &[],
        ),
    ]
}

fn comments(ids: &[&str], newest: &[(&str, &str)]) -> Value {
    let mut map = serde_json::Map::new();
    for id in ids {
        let rows: Vec<Value> = newest
            .iter()
            .filter(|(i, _)| i == id)
            .map(|(_, at)| json!({"id": "c", "body": "x", "user": "u", "user_email": "u@x", "created_at": at, "updated_at": at}))
            .collect();
        map.insert((*id).to_owned(), Value::Array(rows));
    }
    json!({"body": map})
}

/// A GitHub world where every audit of `repo` answers quiet: the workflow
/// list proves every workflow absent, so the refresh and main-push reads
/// clear and nothing is red; the open pull request and issue lists are
/// empty, so no contribution is outside; no pull request is open to the
/// reducer, so no attention stands. A row plants its own reading over these.
fn quiet_audits(world: &mut World, repo: &str) {
    world.gh(
        &format!("repos/{repo}/actions/workflows?per_page=100&page=1"),
        json!({"body": {"total_count": 0, "workflows": []}}),
    );
    for list in ["pulls", "issues"] {
        world.gh(
            &format!("repos/{repo}/{list}?state=open&per_page=100&page=1"),
            json!({"body": []}),
        );
    }
    world.pulls(repo, Vec::new());
}

/// `quiet_audits` for the one repository most rows name.
fn quiet_github(world: &mut World) {
    quiet_audits(world, "owner/repo");
}

/// Run the tracker body once on `baseline` at fake epoch `wall`, apply
/// what it produced as the runner's commit would, and hand back the
/// produced.
fn pass(
    body: &mut watch::Body,
    baseline: &mut Baseline,
    clock: &FakeClock,
    wall: u64,
) -> Result<Produced, Error> {
    pass_as(Duty::Tracker, body, baseline, clock, wall)
}

/// `pass` for the body of `duty`.
fn pass_as(
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

fn set(kind: &str, identity: &str, value: &str) -> Change {
    Change::Set {
        kind: kind.into(),
        identity: identity.into(),
        value: value.into(),
    }
}

/// A dependency failure never becomes an empty or passing inventory. Each
/// row refuses with its cause key and field, and nothing of the pass moves:
/// no line, no row, no call past the failed one.
#[test]
fn an_auth_failure_a_short_page_and_a_malformed_member_each_refuse_their_inventory() {
    let clock = FakeClock::new();
    // (key, fields the refusal carries, the world's planted defect)
    type Fields = Vec<(&'static str, &'static str)>;
    type Planted = Box<dyn Fn(&mut World)>;
    let rows: Vec<(&str, Fields, Planted)> = vec![
        (
            "tracker-list-failed",
            vec![("read", "statuses")],
            Box::new(|w| {
                w.linear(
                    "statuses list",
                    json!({"exit": 1, "stderr": "linear: auth-failed source=api-key"}),
                );
            }),
        ),
        (
            "tracker-list-invalid",
            vec![("read", "issues"), ("field", "id")],
            Box::new(|w| {
                w.linear("statuses list", statuses());
                w.linear("issues list", json!({"body": [item("KEN 1", "2026-08-16T00:00:00Z", "Todo", "unstarted", json!(2), &[])]}));
            }),
        ),
        (
            "tracker-list-invalid",
            vec![("read", "issues"), ("field", "created_at")],
            Box::new(|w| {
                w.linear("statuses list", statuses());
                w.linear("issues list", json!({"body": [item("KEN-1", "yesterday", "Todo", "unstarted", json!(2), &[])]}));
            }),
        ),
        (
            "tracker-list-invalid",
            vec![("read", "statuses")],
            Box::new(|w| {
                w.linear("statuses list", json!({"body": [{"name": "Todo"}]}));
            }),
        ),
        (
            "github-total-mismatch",
            vec![("read", "merged-search")],
            Box::new(|w| {
                w.linear("statuses list", statuses());
                w.linear("issues list", json!({"body": []}));
                w.linear(
                    "issues bulk-get",
                    json!({"body": {"issues": {"nodes": [{"identifier": "KEN-1", "state": {"type": "started"}, "description": "", "children": {"nodes": []}}]}}}),
                );
                w.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
                    "lanes": [{"item": "KEN-1", "tracker": "linear", "repo": "owner/repo", "harness": "claude", "window": null, "host": null, "mail_root": "/w/KEN-1", "status": "stopped"}]}));
                w.gh(
                    "repos/owner/repo/pulls?state=closed&head=owner%3Aken-1&per_page=100&page=1",
                    json!({"body": []}),
                );
                // The search says two results and hands over one, then an
                // empty page: a short page.
                let q = "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-1%22%20in%3Atitle%2Cbody%20merged%3A%3E%3D2026-08-15T09%3A00%3A00Z";
                w.gh(&format!("{q}&per_page=100&page=1"), json!({"body": {"total_count": 2, "incomplete_results": false, "items": [{"number": 2, "pull_request": {"merged_at": "2026-10-02T00:00:00Z"}}]}}));
                w.gh(
                    &format!("{q}&per_page=100&page=2"),
                    json!({"body": {"total_count": 2, "incomplete_results": false, "items": []}}),
                );
            }),
        ),
        (
            "github-response-invalid",
            vec![("read", "refresh"), ("field", "conclusion")],
            Box::new(|w| {
                w.linear("statuses list", statuses());
                w.linear("issues list", json!({"body": []}));
                // A completed run whose conclusion is null: a member the
                // judgement cannot read.
                w.gh("repos/owner/repo/actions/workflows/kendex-refresh.yml/runs?status=completed&per_page=2",
                    json!({"body": {"total_count": 1, "workflow_runs": [{"id": 9, "run_attempt": 1, "conclusion": null, "created_at": "2026-10-01T00:00:00Z", "status": "completed", "path": ".github/workflows/kendex-refresh.yml", "head_sha": "0000000000000000000000000000000000000000", "head_branch": "main", "workflow_id": 1, "event": "schedule", "updated_at": "2026-10-01T00:00:00Z", "repository": {"id": 1296269, "full_name": "owner/repo"}, "head_repository": {"id": 1296269, "full_name": "owner/repo"}, "pull_requests": []}]}}));
            }),
        ),
    ];
    for (key, fields, plant) in rows {
        let mut world = World::new();
        world.linear("statuses list", statuses());
        world.linear("issues list", json!({"body": []}));
        world.linear(
            "issues bulk-get",
            json!({"body": {"issues": {"nodes": []}}}),
        );
        quiet_github(&mut world);
        plant(&mut world);
        let settings = world.settings(&[]);
        let ctx = world.context(settings.clone(), Some(SINCE));
        let shared = ctx.shared.clone();
        // A GitHub defect is the GitHub duty's refusal.
        let mut body = if key.starts_with("github") {
            github::body(world.github_context(
                settings,
                Some(SINCE),
                &["owner/repo"],
                shared.clone(),
            ))
        } else {
            tracker::body(ctx)
        };
        let mut baseline = Baseline::default();
        let err = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap_err();
        assert_eq!(err.key(), key, "{key} {fields:?}: {err}");
        let got: Vec<(String, String)> = err.fields();
        for (name, value) in &fields {
            assert!(
                got.iter().any(|(k, v)| k == name && v == value),
                "{key}: field {name}={value} in {got:?}"
            );
        }
        assert_eq!(baseline, Baseline::default(), "{key}: no row moved");
        let latest = shared.lock().unwrap();
        assert!(
            latest.tracker.is_none() && latest.github.is_none(),
            "{key}: no inventory handed over before a refusal"
        );
    }
}

/// The receipt is held as a typed row; while it holds, a pass makes no
/// tracker call and fails nothing, the GitHub reads and the mail duty run
/// on; at the reset the row clears and the tracker is read again.
#[test]
fn the_quota_receipt_holds_tracker_reads_until_its_reset_and_nothing_else() {
    let mut world = World::new();
    let clock = FakeClock::new();
    let reset = clock.wall_secs() + 5000;
    let receipt = json!({"code": "RATELIMITED", "quota": {"limit": "requests", "status": "future",
        "reset": agent_runtime::clock::iso_utc(reset), "reset_epoch": reset}});
    world.linear(
        "statuses list",
        json!({"exit": 1, "stderr": receipt.to_string()}),
    );
    quiet_github(&mut world);
    let settings = world.settings(&[("ORCH_WATCH_MAIL_INTERVAL", "20")]);
    let paths = Paths::of(&world.fleet_path()).unwrap();
    let identity = me();
    let mut runner = Runner::new(
        paths.clone(),
        &clock,
        &settings,
        Flags {
            interval: secs(240),
            max_loops: 25,
            since: Some(SINCE.into()),
            repos: Vec::new(),
            fresh: false,
        },
        identity.clone(),
        Recorded {
            pane: "none".into(),
            script: "/w/orch-runtime".into(),
            cwd: "/w".into(),
        },
    )
    .unwrap();
    let mail = Arc::new(AtomicUsize::new(0));
    let mail_in = mail.clone();
    runner.register(
        Duty::Mail,
        Box::new(move |_: &Tick| {
            mail_in.fetch_add(1, Ordering::SeqCst);
            Ok(Produced::default())
        }),
    );
    let ctx = world.context(settings.clone(), Some(SINCE));
    let shared = ctx.shared.clone();
    runner.register(Duty::Tracker, tracker::body(ctx));
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(2);
        let calls_after_first = world.linear_calls().len();
        assert_eq!(calls_after_first, 1, "one refused call");
        // Two long cadences under the hold: no tracker call, mail on.
        for _ in 0..24 {
            clock.pass(secs(20));
        }
        assert_eq!(world.linear_calls().len(), 1, "no tracker call while held");
        assert!(
            mail.load(Ordering::SeqCst) >= 24,
            "mail ran through the hold: {}",
            mail.load(Ordering::SeqCst)
        );
        // The reset passes: the next tracker run reads again.
        let remaining = reset.saturating_sub(clock.wall_secs()) + 240;
        world.linear("statuses list", statuses());
        world.linear("issues list", json!({"body": []}));
        for _ in 0..(remaining / 20 + 1) {
            clock.pass(secs(20));
        }
        assert!(
            world.linear_calls().len() >= 3,
            "the tracker was read again after the reset: {:?}",
            world.linear_calls()
        );
    });
    assert!(ended.is_ok(), "{ended:?}");
    let log = lines(&paths.log);
    assert!(
        !log.iter().any(|l| l.starts_with("EVENT watch-step-failed")),
        "the hold fails nothing: {log:?}"
    );
    let quota_lines: Vec<&String> = log
        .iter()
        .filter(|l| l.starts_with("EVENT tracker-quota "))
        .collect();
    assert_eq!(
        quota_lines,
        vec![&format!(
            "EVENT tracker-quota status=future reset={} limit=requests",
            agent_runtime::clock::iso_utc(reset)
        )],
        "the one limit event, printed when the receipt was taken: {log:?}"
    );
    let baseline = Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.get(tracker::QUOTA_ROW, "fleet"),
        None,
        "the row cleared at the reset"
    );
    let latest = shared.lock().unwrap();
    assert!(
        latest.quota.is_none() && latest.tracker.is_some(),
        "the inventory stands after the reset"
    );
}

/// On the real body: the `linear-hold` fixture holds the tracker's first
/// call on a FIFO while the clock passes three mail intervals.
#[test]
fn a_tracker_read_held_on_the_fifo_delays_no_mail_run() {
    let mut world = World::new();
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    quiet_github(&mut world);
    let fifo = world.dir.path().join("linear.fifo");
    assert!(
        std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    let settings = world.settings(&[
        ("ORCH_WATCH_MAIL_INTERVAL", "20"),
        (
            "OVERSEE_WATCH_TRACKER",
            &world.dir.path().join("linear-held").display().to_string(),
        ),
    ]);
    let clock = FakeClock::new();
    let paths = Paths::of(&world.fleet_path()).unwrap();
    let identity = me();
    let mut runner = Runner::new(
        paths.clone(),
        &clock,
        &settings,
        Flags {
            interval: secs(240),
            max_loops: 25,
            since: None,
            repos: Vec::new(),
            fresh: false,
        },
        identity.clone(),
        Recorded {
            pane: "none".into(),
            script: "/w/orch-runtime".into(),
            cwd: "/w".into(),
        },
    )
    .unwrap();
    let mail = Arc::new(AtomicUsize::new(0));
    let mail_in = mail.clone();
    runner.register(
        Duty::Mail,
        Box::new(move |_: &Tick| {
            mail_in.fetch_add(1, Ordering::SeqCst);
            Ok(Produced::default())
        }),
    );
    runner.register(
        Duty::Tracker,
        tracker::body(world.context(settings.clone(), None)),
    );
    let hold_log = world.dir.path().join("linear-hold.log");
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        let deadline = Instant::now() + secs(10);
        while lines(&hold_log).is_empty() || mail.load(Ordering::SeqCst) == 0 {
            assert!(
                Instant::now() < deadline,
                "the tracker never reached its hold"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let settle = Instant::now() + secs(2);
        while clock.sleepers() == 0 && Instant::now() < settle {
            std::thread::sleep(Duration::from_millis(10));
        }
        for _ in 0..3 {
            clock.pass(secs(20));
        }
        let mail_runs = mail.load(Ordering::SeqCst);
        // Release the held read with its line, then wait for the tracker to
        // commit and sleep beside the mail thread.
        std::fs::write(&fifo, b"go\n").unwrap();
        assert!(
            mail_runs >= 4,
            "mail ran at start and at each of three intervals while the tracker was held: {mail_runs}"
        );
        clock.await_sleepers(2);
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert!(
        lines(&hold_log).len() >= 2,
        "the first call held and the next went on: {:?}",
        lines(&hold_log)
    );
    assert!(
        world.linear_calls().len() >= 2,
        "the released read completed: {:?}",
        world.linear_calls()
    );
}

/// The recorded watch's answer on its triage world (`recorded/triage.out`:
/// KEN-1, KEN-2 and KEN-4; KEN-3 kept, KEN-5 before the floor). The first
/// pass raises the three; the second raises nothing; a comment on KEN-2
/// raises it once; a verdict on KEN-1 clears its row; the items are read in
/// one list and the comments in one batch.
#[test]
fn an_unchanged_item_emits_no_line_and_a_moved_key_raises_it_once() {
    let mut world = World::new();
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": triage_items()}));
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-1", "state": {"type": "unstarted"}, "children": {"nodes": []}},
            {"identifier": "KEN-2", "state": {"type": "started"}, "children": {"nodes": []}},
            {"identifier": "KEN-3", "state": {"type": "unstarted"}, "children": {"nodes": []}},
            {"identifier": "KEN-4", "state": {"type": "backlog"}, "children": {"nodes": []}},
            {"identifier": "KEN-5", "state": {"type": "unstarted"}, "children": {"nodes": []}}
        ]}}}),
    );
    world.linear(
        "comments bulk-list",
        comments(&["KEN-1", "KEN-2", "KEN-4"], &[]),
    );
    world.write_fleet(&json!({"issue_id": "oversee", "launch_queue": [], "lanes": [], "fleet_log": [],
        "triaged": [{"issue": "KEN-3", "verdict": "kept"}, {"issue": "KEN-4", "verdict": "pending"}]}));
    quiet_github(&mut world);
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let mut body = tracker::body(world.context(settings, Some(SINCE)));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        vec![
            "EVENT triage KEN-1",
            "EVENT triage KEN-2",
            "EVENT triage KEN-4"
        ],
        "the released watch's recorded answer"
    );
    let calls = world.linear_calls();
    assert_eq!(
        calls
            .iter()
            .filter(|c| c.starts_with("issues list"))
            .count(),
        1,
        "one list: {calls:?}"
    );
    assert_eq!(
        calls
            .iter()
            .filter(|c| c.starts_with("comments bulk-list"))
            .count(),
        1,
        "one comment batch: {calls:?}"
    );
    assert!(
        calls
            .iter()
            .any(|c| c == "comments bulk-list KEN-1 KEN-2 KEN-4 --format=safe"),
        "{calls:?}"
    );
    assert_eq!(
        baseline.get(tracker::TRIAGE_ROW, "KEN-2"),
        Some("In Progress|-")
    );
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(
        rendered(&second),
        Vec::<String>::new(),
        "an unchanged item emits no line"
    );
    world.linear(
        "comments bulk-list",
        comments(
            &["KEN-1", "KEN-2", "KEN-4"],
            &[("KEN-2", "2026-08-20T00:00:00Z")],
        ),
    );
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    assert_eq!(
        rendered(&third),
        vec!["EVENT triage KEN-2"],
        "a moved key raises it once"
    );
    let fourth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap();
    assert_eq!(rendered(&fourth), Vec::<String>::new());
    world.write_fleet(&json!({"issue_id": "oversee", "launch_queue": [], "lanes": [], "fleet_log": [],
        "triaged": [{"issue": "KEN-3", "verdict": "kept"}, {"issue": "KEN-1", "verdict": "canceled"}]}));
    let fifth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1960).unwrap();
    assert_eq!(rendered(&fifth), Vec::<String>::new());
    assert_eq!(
        baseline.get(tracker::TRIAGE_ROW, "KEN-1"),
        None,
        "an acknowledged item's row is cleared"
    );
    assert_eq!(
        baseline.get(tracker::TRIAGE_ROW, "KEN-4"),
        Some("Backlog|-"),
        "a pending verdict acknowledges nothing"
    );
}

/// The recorded watch's answer on the owed world (`recorded/owed.lines`:
/// nine lines with their state, priority and lane). The owed rows match the
/// recorded lines field for field, in the recorded order; the wall verdict
/// is the heartbeat's.
#[test]
fn the_owed_inventory_matches_the_released_recorded_lines() {
    let mut world = World::new();
    let recorded_dir = fixtures().join("released-recorded");
    let fleet: Value = serde_json::from_str(
        &std::fs::read_to_string(recorded_dir.join("owed-state.json")).unwrap(),
    )
    .unwrap();
    let tracker_out: Vec<Value> = serde_json::from_str(
        &std::fs::read_to_string(recorded_dir.join("owed-tracker.json")).unwrap(),
    )
    .unwrap();
    let recorded = lines(&recorded_dir.join("owed.lines"));
    assert_eq!(recorded.len(), 9, "the released watch's nine owed lines");
    // The suite's items carry id, state and priority; the CLI's owed select
    // carries the rest, filled here as the CLI would, and the team's open
    // states filter drops KEN-8 (Done), as the recorded run's `--state` does.
    let items: Vec<Value> = tracker_out
        .iter()
        .filter(|i| i["state"] != "Done")
        .map(|i| {
            let state = i["state"].as_str().unwrap();
            let state_type = if state == "Done" {
                "completed"
            } else {
                "started"
            };
            item(
                i["id"].as_str().unwrap(),
                "2026-09-01T00:00:00Z",
                state,
                state_type,
                i["priority"].clone(),
                &[],
            )
        })
        .collect();
    world.write_fleet(&fleet);
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": items}));
    let nodes: Vec<Value> = tracker_out
        .iter()
        .map(|i| json!({"identifier": i["id"], "state": {"type": "started"}, "children": {"nodes": []}}))
        .collect();
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": nodes}}}),
    );
    quiet_github(&mut world);
    for lane in fleet["lanes"].as_array().unwrap() {
        let item = lane["item"].as_str().unwrap();
        let branch = item.to_ascii_lowercase();
        world.gh(
            &format!(
                "repos/owner/repo/pulls?state=closed&head=owner%3A{branch}&per_page=100&page=1"
            ),
            json!({"body": []}),
        );
        world.gh(
            &format!("search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22{item}%22%20in%3Atitle%2Cbody&per_page=100&page=1"),
            json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
        );
    }
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let ctx = world.context(settings, None);
    let shared = ctx.shared.clone();
    let mut body = tracker::body(ctx);
    let mut baseline = Baseline::default();
    pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    let latest = shared.lock().unwrap();
    let inventory = latest.tracker.as_ref().expect("the inventory");
    let got: Vec<String> = inventory
        .owed
        .iter()
        .map(|o| {
            format!(
                "owed {} state={} priority={} lane={}",
                o.id,
                o.state.word(),
                o.priority,
                o.lane
            )
        })
        .collect();
    let expected: Vec<String> = recorded
        .iter()
        .map(|l| l.split(" verdict=").next().unwrap().to_owned())
        .collect();
    assert_eq!(got, expected);
    let deliveries: Vec<(String, Option<String>)> = inventory
        .owed
        .iter()
        .map(|o| (o.id.clone(), o.delivery.clone()))
        .collect();
    assert!(
        deliveries.contains(&("KEN-5".into(), Some("pr=15".into()))),
        "{deliveries:?}"
    );
    assert!(
        deliveries.contains(&(
            "KEN-13".into(),
            Some("commit=0123456789abcdef0123456789abcdef01234567".into())
        )),
        "{deliveries:?}"
    );
    assert!(
        deliveries.contains(&("KEN-2".into(), None)),
        "{deliveries:?}"
    );
    assert!(
        inventory.verifying.is_empty(),
        "no Verifying item in the world"
    );
    assert_eq!(
        inventory
            .owed
            .iter()
            .filter(|o| o.state == OwedState::InReview)
            .count(),
        3
    );
}

#[test]
fn parked_merges_fall_back_to_github_only_without_a_linear_team() {
    if !isolated_row("parked_merges_fall_back_to_github_only_without_a_linear_team") {
        return;
    }
    let mut world = World::new();
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [
            {"item": "KEN-1", "status": "parked", "parked": {"pr": 7, "repo": "owner/repo", "head": "abc"}},
            {"item": "KEN-2", "status": "parked", "parked": {"until_pr": 8, "repo": "owner/repo", "head": "abc"}},
            {"item": "KEN-3", "status": "running", "pending_pr": {"until_pr": 8, "repo": "owner/repo", "head": "abc"}},
        ]}));
    quiet_github(&mut world);
    let pull = |number, branch| {
        json!({"number": number, "state": "closed", "title": "repair", "body": null,
        "merged_at": "2026-10-01T00:00:00Z", "merge_commit_sha": null, "author_association": "NONE", "user": null,
        "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"},
        "head": {"ref": branch, "sha": "0000000000000000000000000000000000000000", "repo": {"full_name": "owner/repo", "owner": {"login": "owner", "type": "User"}}}})
    };
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aken-1&per_page=100&page=1",
        json!({"body": [pull(7, "ken-1")]}),
    );
    world.gh("search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-1%22%20in%3Atitle%2Cbody&per_page=100&page=1",
        json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}));
    world.gh(
        "repos/owner/repo/pulls/8",
        json!({"body": pull(8, "dependency")}),
    );
    let both = [("KEN-1", "7", "owner/repo"), ("KEN-2", "8", "owner/repo")];
    for (team, verdict, expected) in [
        (Some("kendex"), None, &[][..]),
        (None, None, &both[..]),
        (None, Some(TerminalState::Completed), &[][..]),
        (None, Some(TerminalState::Canceled), &[][..]),
    ] {
        let settings = world.settings(&[("LINEAR_TEAM", team.unwrap_or_default())]);
        assert_eq!(settings.linear_team.as_deref(), team);
        let shared = Shared::default();
        if let Some(verdict) = verdict {
            shared.lock().unwrap().terminal =
                BTreeMap::from([("KEN-1".to_owned(), verdict), ("KEN-2".to_owned(), verdict)]);
        }
        let mut body = github::body(world.github_context(settings, None, &["owner/repo"], shared));
        let clock = FakeClock::new();
        let mut baseline = Baseline::default();
        for (pass, wall) in [
            ("first", SINCE_EPOCH + 1000),
            ("standing", SINCE_EPOCH + 1240),
        ] {
            let produced = pass_as(Duty::GitHub, &mut body, &mut baseline, &clock, wall).unwrap();
            let parked: Vec<_> = produced
                .events
                .iter()
                .filter_map(|event| match event {
                    Event::ParkedMerged { item, pr, repo } => {
                        Some((item.as_str(), pr.as_str(), repo.as_str()))
                    }
                    _ => None,
                })
                .collect();
            assert_eq!(
                parked, expected,
                "pass={pass} team={team:?} verdict={verdict:?}"
            );
            if pass == "standing" {
                assert!(
                    !produced
                        .events
                        .iter()
                        .any(|event| matches!(event, Event::Merged { .. }))
                );
            }
        }
    }
}

/// The recorded watch's answer on the merged fixture
/// (`recorded/merged.lines`: #1 on the branch and #2 by title scope; #3 a
/// fork, #4 a mention, #5 before the floor; nothing on the second pass).
/// The two lines print once, in the recorded order; the search and the head
/// list are each read once per repository.
#[test]
fn the_merged_index_matches_the_released_recorded_lines() {
    let mut world = World::new();
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [{"item": "KEN-1", "tracker": "linear", "harness": "claude", "window": null, "host": null, "mail_root": "/w/KEN-1", "launched_at": "2026-09-20T00:00:00Z", "status": "stopped"}]}));
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [{"identifier": "KEN-1", "state": {"type": "started"}, "description": "", "children": {"nodes": []}}]}}}));
    quiet_github(&mut world);
    let pull = |number: u64,
                branch: &str,
                owner: &str,
                title: &str,
                body: &str,
                merged_at: &str| {
        json!({"number": number, "state": "closed", "title": title, "body": body, "merged_at": merged_at, "merge_commit_sha": null,
            "author_association": "NONE", "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null,
            "head": {"sha": "0000000000000000000000000000000000000000", "ref": branch, "repo": {"full_name": format!("{owner}/repo"), "owner": {"login": owner, "type": "User"}}}})
    };
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aken-1&per_page=100&page=1",
        json!({"body": [pull(5, "ken-1", "owner", "old", "", "2026-08-01T00:00:00Z"), pull(1, "ken-1", "owner", "repair", "Closes KEN-1", "2026-10-01T00:00:00Z")]}),
    );
    let q = "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-1%22%20in%3Atitle%2Cbody%20merged%3A%3E%3D2026-08-15T09%3A00%3A00Z";
    world.gh(
        &format!("{q}&per_page=100&page=1"),
        json!({"body": {"total_count": 3, "incomplete_results": false, "items": [
        {"number": 4, "pull_request": {"merged_at": "2026-10-04T00:00:00Z"}},
        {"number": 3, "pull_request": {"merged_at": "2026-10-03T00:00:00Z"}},
        {"number": 2, "pull_request": {"merged_at": "2026-10-02T00:00:00Z"}}]}}),
    );
    world.gh(
        "repos/owner/repo/pulls/4",
        json!({"body": pull(4, "other", "owner", "revert KEN-1", "", "2026-10-04T00:00:00Z")}),
    );
    world.gh(
        "repos/owner/repo/pulls/3",
        json!({"body": pull(3, "ken-1", "fork", "fix(KEN-1): fork", "", "2026-10-03T00:00:00Z")}),
    );
    world.gh("repos/owner/repo/pulls/2", json!({"body": pull(2, "cloud-branch", "owner", "fix(KEN-1): repair", "", "2026-10-02T00:00:00Z")}));
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let shared = Shared::default();
    let mut body =
        github::body(world.github_context(settings, Some(SINCE), &["owner/repo"], shared.clone()));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        vec![
            "EVENT merged 1 ken-1 owner/repo",
            "EVENT merged 2 ken-1 owner/repo"
        ],
        "the released watch's recorded answer"
    );
    assert_eq!(
        baseline.get("merged", "KEN-1"),
        Some("owner/repo#1@1790812800 owner/repo#2@1790899200")
    );
    let calls = world.gh_calls();
    assert_eq!(
        calls.iter().filter(|c| c.contains("search/issues")).count(),
        1,
        "{calls:?}"
    );
    assert_eq!(
        calls
            .iter()
            .filter(|c| c.contains("pulls?state=closed"))
            .count(),
        1,
        "{calls:?}"
    );
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(
        rendered(&second),
        Vec::<String>::new(),
        "a standing key prints nothing"
    );
    assert_eq!(
        shared
            .lock()
            .unwrap()
            .github
            .as_ref()
            .unwrap()
            .merged
            .get("KEN-1"),
        Some(&vec!["owner/repo#1".to_owned(), "owner/repo#2".to_owned()])
    );
}

/// The Verifying items no live lane carries, through the real tracker,
/// GitHub and verification duties over the `gh` fixture: a bundle child
/// named only by its parent pull request's indented `Closes` line is found
/// by the key search floored at its creation, a prose mention passed over;
/// an item whose lane closed is read by the number and repository its cycle
/// recorded, with no search for it, and so is an item joined to that lane.
/// Each joins the merged index with no
/// `merged` line or row, and its box counts from that merge.
#[test]
fn a_verifying_item_no_live_lane_carries_reads_its_landing() {
    const NOW: u64 = 1_790_899_201;
    const BOX: &str = "## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Deadline: +72h";
    let mut world = World::new();
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [{"item": "KEN-3", "tracker": "linear", "repo": "owner/repo", "harness": "claude", "window": null, "host": null,
            "mail_root": "/w/KEN-3", "launched_at": "2026-09-20T00:00:00Z", "status": "done",
            "cycle": {"pr": 7, "repo": "Owner/Repo"},
            "carried": [{"item": "KEN-4", "tracker": "linear", "at": "2026-09-20T01:00:00Z"}]}]}));
    world.linear("statuses list", statuses());
    let verifying = |id: &str| {
        let mut item = item(
            id,
            "2026-09-20T00:00:00Z",
            "Verifying",
            "started",
            json!(1),
            &[],
        );
        item["description"] = json!(BOX);
        item
    };
    world.linear(
        "issues list",
        json!({"body": [verifying("KEN-2"), verifying("KEN-3"), verifying("KEN-4")]}),
    );
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-2", "state": {"type": "started"}, "children": {"nodes": []}},
            {"identifier": "KEN-3", "state": {"type": "started"}, "children": {"nodes": []}},
            {"identifier": "KEN-4", "state": {"type": "started"}, "children": {"nodes": []}}
        ]}}}),
    );
    quiet_github(&mut world);
    let pull = |number: u64, branch: &str, title: &str, body: &str, merged_at: &str| {
        json!({"body": {"number": number, "state": "closed", "title": title, "body": body, "merged_at": merged_at, "merge_commit_sha": null,
            "author_association": "NONE", "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null,
            "head": {"sha": "0000000000000000000000000000000000000000", "ref": branch, "repo": {"full_name": "owner/repo", "owner": {"login": "owner", "type": "User"}}}}})
    };
    let search = "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D2026-09-20T00%3A00%3A00Z%20%28%28head%3Aken-2%20OR%20%22KEN-2%22%29%29%20in%3Atitle%2Cbody&per_page=100&page=1";
    world.gh(
        search,
        json!({"body": {"total_count": 2, "incomplete_results": false, "items": [
            {"number": 9, "pull_request": {}}, {"number": 8, "pull_request": {}}]}}),
    );
    world.gh(
        "repos/owner/repo/pulls/9",
        pull(
            9,
            "ken-1",
            "feat(KEN-1): bundle",
            "## Completed Issues\n  - Closes KEN-2 - child\n",
            "2026-10-01T00:00:00Z",
        ),
    );
    world.gh(
        "repos/owner/repo/pulls/8",
        pull(
            8,
            "claude/notes",
            "chore: notes",
            "Follow-up to KEN-2.",
            "2026-10-01T06:00:00Z",
        ),
    );
    world.gh(
        "repos/owner/repo/pulls/7",
        pull(7, "claude/descriptive", "work", "", "2026-09-30T00:00:00Z"),
    );
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let ctx = world.context(settings.clone(), None);
    let shared = ctx.shared.clone();
    let mut tracker = tracker::body(ctx);
    let mut github =
        github::body(world.github_context(settings.clone(), None, &["owner/repo"], shared.clone()));
    let lines_slot = verifying::Lines::default();
    let mut verification = verifying::body(verifying::Context {
        settings,
        gh: world.dir.path().join("gh"),
        shared: shared.clone(),
        lines: lines_slot.clone(),
    });
    let mut baseline = Baseline::default();
    pass(&mut tracker, &mut baseline, &clock, NOW).unwrap();
    let read = pass_as(Duty::GitHub, &mut github, &mut baseline, &clock, NOW).unwrap();
    assert_eq!(rendered(&read), Vec::<String>::new());
    assert_eq!(
        baseline.identities(github::MERGED_ROW),
        Vec::<String>::new()
    );
    let merged = shared
        .lock()
        .unwrap()
        .github
        .as_ref()
        .unwrap()
        .merged
        .clone();
    assert_eq!(
        (
            merged.get("KEN-2"),
            merged.get("KEN-3"),
            merged.get("KEN-4")
        ),
        (
            Some(&vec!["owner/repo#9".to_owned()]),
            Some(&vec!["owner/repo#7".to_owned()]),
            Some(&vec!["owner/repo#7".to_owned()])
        ),
        "the joined KEN-4 lands with its lane's pull request: {merged:?}"
    );
    let calls = world.gh_calls();
    assert_eq!(
        calls.iter().filter(|c| c.contains("search/issues")).count(),
        1,
        "{calls:?}"
    );
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW,
    )
    .unwrap();
    let said = lines_slot.lock().unwrap().clone();
    // The deadline counts 72 hours from each merge.
    for (id, deadline) in [
        ("KEN-2", "2026-10-04T00:00:00Z"),
        ("KEN-3", "2026-10-03T00:00:00Z"),
    ] {
        assert!(
            said.iter()
                .any(|l| l.starts_with(&format!("verifying {id} box=1 "))
                    && l.contains(&format!(" deadline={deadline} "))),
            "{id}: {said:?}"
        );
    }
}

/// A stopped lane whose item is Done with every box checked gets one
/// `close-owned-resources` request, its line prints and the record reads
/// done; one whose item is Done with an open box stays open; a canceled one
/// closes; a refused close prints its line and is held under its key. A
/// reading lane stays out of the tracker batch so the other items can close.
#[test]
fn a_terminal_item_with_no_recorded_close_gets_one_close_request() {
    let lane = |item: &str| {
        json!({"item": item, "tracker": "linear", "repo": "owner/repo", "harness": "codex", "window": null, "host": null,
            "mail_root": "/srv/lane/x", "status": "stopped", "session_since": "2026-10-09T00:00:00Z"})
    };
    let reading_lane = |item| {
        let mut record = lane(item);
        record.as_object_mut().unwrap().remove("tracker");
        record
    };
    let mut world = World::new();
    world.write_fleet(
        &json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [lane("KEN-1"), lane("KEN-2"), lane("KEN-3"), lane("KEN-4"),
            reading_lane("verify-KEN-1-box-1"),
            reading_lane("verify-gh-e4f602fb1d01f06eb268feb7e179579ccbdac5ec-1-box-1")]}),
    );
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    let open_box = "Intro\n\n## Done when\n- [x] Branch\n  Evidence: yes\n- [ ] Post-merge: Read release; Where: feed; Why after merge: publish; Trigger: release owner/repo v*; Deadline: +24h\n";
    world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
        {"identifier": "KEN-1", "state": {"type": "completed"}, "description": "## Done when\n- [x] Done\n  Evidence: yes\n", "children": {"nodes": []}},
        {"identifier": "KEN-2", "state": {"type": "completed"}, "description": open_box, "children": {"nodes": []}},
        {"identifier": "KEN-3", "state": {"type": "canceled"}, "description": null, "children": {"nodes": []}},
        {"identifier": "KEN-4", "state": {"type": "started"}, "description": "", "children": {"nodes": []}}
    ]}}}));
    quiet_github(&mut world);
    // The head lists and searches of the four items answer nothing.
    for item in ["KEN-1", "KEN-2", "KEN-3", "KEN-4"] {
        let branch = item.to_ascii_lowercase();
        world.gh(
            &format!(
                "repos/owner/repo/pulls?state=closed&head=owner%3A{branch}&per_page=100&page=1"
            ),
            json!({"body": []}),
        );
        let q = format!(
            "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22{item}%22%20in%3Atitle%2Cbody&per_page=100&page=1"
        );
        world.gh(
            &q,
            json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
        );
    }
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let mut body = tracker::body(world.context(settings, None));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        vec!["EVENT lane-closed KEN-1", "EVENT lane-closed KEN-3"],
        "Done with every box checked and Canceled close; an open box and a started item stay"
    );
    let status = |fleet: &Value, item: &str| {
        fleet["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .unwrap()["status"]
            .clone()
    };
    let fleet = world.fleet();
    assert_eq!(status(&fleet, "KEN-1"), "done");
    assert_eq!(status(&fleet, "KEN-3"), "done");
    assert_eq!(status(&fleet, "KEN-2"), "stopped");
    assert_eq!(status(&fleet, "KEN-4"), "stopped");
    let closes = fleet["intents"].as_array().map_or(0, |i| {
        i.iter().filter(|x| x["op"] == "close-resources").count()
    });
    assert_eq!(closes, 2, "one request per ended item: {fleet}");
    assert_eq!(baseline.get(tracker::TERMINAL_CLOSE_ROW, "KEN-1"), None);
    // The second pass: the closed lanes are no candidates, the open ones
    // are read again and still stay; no second request.
    let done_when_calls = |w: &World| {
        w.linear_calls()
            .iter()
            .filter(|c| c.starts_with("done-when parse"))
            .count()
    };
    assert_eq!(done_when_calls(&world), 2, "one parse per completed item");
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(rendered(&second), Vec::<String>::new());
    let fleet = world.fleet();
    let closes = fleet["intents"].as_array().map_or(0, |i| {
        i.iter().filter(|x| x["op"] == "close-resources").count()
    });
    assert_eq!(closes, 2, "no second request");
    assert_eq!(
        world
            .linear_calls()
            .iter()
            .rfind(|c| c.starts_with("issues bulk-get"))
            .map(String::as_str),
        Some("issues bulk-get KEN-2 KEN-4 --format=raw"),
        "the second pass reads only the lanes still open"
    );
    // A refused close: the mailbox the close asks for unanswered asks
    // refuses, the line prints, the row holds it, the next pass asks again
    // only once the key moves.
    let settings = world.settings(&[]);
    world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
        {"identifier": "KEN-2", "state": {"type": "canceled"}, "description": open_box, "children": {"nodes": []}},
        {"identifier": "KEN-4", "state": {"type": "started"}, "description": "", "children": {"nodes": []}}
    ]}}}));
    let mut body = tracker::body(world.context(settings, None));
    // The store cannot land the close's write: the state directory admits
    // no new file, so the request is refused where it would persist. The
    // guard gives the mode back however the row ends, so the temporary
    // directory stays removable.
    struct Writable<'a>(&'a Path);
    impl Drop for Writable<'_> {
        fn drop(&mut self) {
            let _ = std::fs::set_permissions(self.0, std::fs::Permissions::from_mode(0o755));
        }
    }
    std::fs::set_permissions(world.dir.path(), std::fs::Permissions::from_mode(0o555)).unwrap();
    let writable = Writable(world.dir.path());
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    assert_eq!(rendered(&third), vec!["EVENT lane-close-refused KEN-2"]);
    // The row keeps the refusal's cause after its key.
    let row = baseline
        .get(tracker::TERMINAL_CLOSE_ROW, "KEN-2")
        .unwrap_or_default();
    assert!(
        row.strip_prefix("canceled|2026-10-09T00:00:00Z|create-temp on ")
            .is_some_and(|cause| cause.ends_with("Permission denied (os error 13)")),
        "{row}"
    );
    let fourth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap();
    assert_eq!(
        rendered(&fourth),
        Vec::<String>::new(),
        "a refused close is not asked again under the same key"
    );
    drop(writable);
    assert_eq!(
        world.fleet()["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == "KEN-2")
            .unwrap()["status"],
        "stopped"
    );
}

/// The orch, github and mailbox packages' scripts installed where the watch
/// runs its steps from (`<project>/.agents/skills/orch/scripts`), the
/// shipped script the in-process cycle recorder starts (the github skill's
/// `github.sh`) behind a wrapper of its name that starts it under the test
/// child's isolation: the world's `gh` fixture first on `PATH`, a fixture
/// token, a scratch home and git's ceiling at the temporary root, so no
/// checkout above the world is read and no real `gh` is reached. The
/// recorder's own `git` reads run in this process, so
/// the world's root holds a `.git` file git refuses (`invalid gitfile
/// format`), which ends its discovery there: no repository above the world
/// is read, fetched or written.
fn installed_cycle_recorder(world: &World) -> PathBuf {
    let skills = world.dir.path().join(".agents/skills");
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    for package in ["orch", "github", "mailbox"] {
        let dest = skills.join(package);
        std::fs::create_dir_all(&dest).unwrap();
        let out = program("cp")
            .arg("-R")
            .arg(repo.join(package).join("scripts"))
            .arg(&dest)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    }
    std::fs::write(
        world.dir.path().join(".git"),
        "not a repository: git's discovery ends at the world\n",
    )
    .unwrap();
    let scripts = skills.join("orch/scripts");
    let root = std::env::temp_dir();
    let home = root.join("isolated-home");
    std::fs::create_dir_all(&home).unwrap();
    let wrapper = skills.join("github/scripts/github.sh");
    let shipped = wrapper.with_file_name("github.sh.shipped");
    std::fs::rename(&wrapper, &shipped).unwrap();
    write_executable(
        &wrapper,
        format!(
            "#!/bin/sh\nexec env -i PATH='{path}' LANG=C.UTF-8 TMPDIR='{root}' HOME='{home}' GIT_CEILING_DIRECTORIES='{ceiling}' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=fixture-token bash '{shipped}' \"$@\"\n",
            path = tool_path(&[world.dir.path()]),
            root = root.display(),
            // The world's own `.git` ends discovery inside it; the
            // temporary root above it is the ceiling past that.
            ceiling = ceilings(&root).to_string_lossy(),
            home = home.display(),
            shipped = shipped.display(),
        ),
    );
    scripts
}

/// The lanes the cycle row's cases plant: a hosted parked lane as `main`
/// wrote one (only a hosted lane parks), its `host` the fixture provider and its `kind` the one the
/// provider declares, `ssh`, with `mail_root` its root on the host; or a
/// local stopped lane, as a keep-sandbox close leaves one. Both
/// carry the tier, the launch stamp and the repository `main`'s launch
/// recorded.
fn cycle_lane(world: &World, hosted: bool) -> Value {
    let mut lane = json!({"item": "KEN-1", "tracker": "linear", "repo": "owner/repo", "harness": "codex",
        "window": null, "tier": "small", "tier_inputs": {"estimate": 2, "delta": 40, "paths": 3},
        "launched_at": "2026-09-20T08:50:00Z", "session_since": "2026-09-20T08:50:00Z"});
    if hosted {
        let disk = world.dir.path().join("host-disk");
        std::fs::create_dir_all(&disk).unwrap();
        let provider = world.dir.path().join("provider");
        write_executable(
            &provider,
            format!(
                "#!/bin/bash\nexport LANE_HOST_STUB_LOG='{}' LANE_HOST_STUB_DIR='{}'\nexec '{}' \"$@\"\n",
                world.dir.path().join("provider.log").display(),
                disk.display(),
                orch_package().join("tests/fixtures/lane-host").display()
            ),
        );
        lane["host"] = json!(provider.display().to_string());
        lane["kind"] = json!("ssh");
        lane["mail_root"] = json!("/remote/KEN-1");
        lane["status"] = json!("parked");
        lane["parked"] =
            json!({"repo": "owner/repo", "pr": 7, "head": "h2", "at": "2026-09-20T11:30:00Z"});
    } else {
        let mail_root = world.dir.path().join("lane");
        std::fs::create_dir_all(&mail_root).unwrap();
        lane["host"] = json!(null);
        lane["kind"] = json!("local");
        lane["mail_root"] = json!(mail_root.display().to_string());
        lane["status"] = json!("stopped");
    }
    lane
}

/// A merged pull request `number` of `owner/repo` in the shape the merged
/// index reads it.
fn merged_pull(number: u64, branch: &str) -> Value {
    json!({"number": number, "state": "closed", "title": "work", "body": "", "merged_at": "2026-09-20T11:20:00Z", "merge_commit_sha": null,
        "author_association": "NONE", "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null,
        "head": {"sha": "0000000000000000000000000000000000000000", "ref": branch, "repo": {"full_name": "owner/repo", "owner": {"login": "owner", "type": "User"}}}})
}

/// pr-timeline's one GraphQL read of the merged pull request 7, its three
/// selections of `commits` planted under their arguments.
fn timeline_seven() -> Value {
    json!({"body": {"data": {"repository": {"pullRequest": {
        "number": 7, "state": "MERGED", "body": "", "createdAt": "2026-09-20T09:10:00Z", "mergedAt": "2026-09-20T11:20:00Z",
        "author": {"login": "lane-app"}, "headRefName": "", "headRepository": null,
        "mergeCommit": {"__typename": "Commit", "oid": "m1",
            "checkSuites": {"__typename": "CheckSuiteConnection", "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}},
        "commits(first: 1)": {"nodes": [{"commit": {"authoredDate": "2026-09-20T09:00:00Z"}}]},
        "commits(last: 1)": {"nodes": [{"commit": {"__typename": "Commit", "oid": "h2", "committedDate": "2026-09-20T10:10:00Z",
            "status": {"context": {"state": "SUCCESS", "createdAt": "2026-09-20T10:25:00Z"}},
            "checkSuites": {"__typename": "CheckSuiteConnection", "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}}}]},
        "commits(last: 100)": {"totalCount": 0, "nodes": []},
        "reviews": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []},
        "timelineItems": {"pageInfo": {"hasNextPage": false}, "nodes": []}
    }}}}})
}

/// Through the real tracker duty, its cycle recorder and the real
/// `pr-timeline` over the `gh` fixture's GraphQL answer, and for a hosted
/// lane the runtime's provider call to the fixture provider, a table of cases:
///
/// - a hosted parked lane whose item ended at its merge, read ended before
///   the GitHub duty (which runs after the tracker on the shared cadence)
///   has written any `merged` row: the merge read finds its pull request,
///   the cycle is read before the close and written with it, its line said
///   and then `lane-closed`, the record carrying it and the fleet log its
///   row, and the next pass asks nothing;
/// - an earlier pull request's `merged` row standing, written by the
///   GitHub duty's pass before the merge that ended the item: the current
///   merge read finds the lane's own, and the row hides nothing;
/// - two merged pull requests on the item's branch, the lane's parked one
///   the second: that one is recorded, never the other;
/// - a held refused close whose record carries the cycle already: the pass
///   records nothing again and reads no timeline;
/// - a local stopped lane, its merge found in its repository;
/// - a released Linear lane, whose record names no `repo` (`main`'s launch
///   recorded none for it), read ended first: its merge is found in the
///   watch's `--repo` names, the repositories the GitHub duty reads;
/// - a hosted stopped lane holding a last notice no pass read: the close
///   reads it from the host before the provider's close and the duty says
///   it as its `lane-notice` line before the close's lines.
#[test]
fn an_ended_lanes_merge_cycle_is_recorded_before_its_close() {
    if !isolated_row("an_ended_lanes_merge_cycle_is_recorded_before_its_close") {
        return;
    }
    let seven: &[u64] = &[7];
    let both: &[u64] = &[5, 7];
    for (case, hosted, merged_row, pulls, cycle, held) in [
        (
            "the tracker reads it ended first",
            true,
            None,
            seven,
            false,
            false,
        ),
        (
            "an earlier pull request's row standing",
            true,
            Some("owner/repo#5"),
            both,
            false,
            false,
        ),
        ("two merged pull requests", true, None, both, false, false),
        (
            "a held close, its cycle standing",
            true,
            Some("owner/repo#7"),
            seven,
            true,
            true,
        ),
        ("a local stopped lane", false, None, seven, false, false),
        (
            "a lane with no repo, read ended first",
            true,
            None,
            seven,
            false,
            false,
        ),
        (
            "a hosted stopped lane's last notice",
            true,
            None,
            seven,
            false,
            false,
        ),
    ] {
        let mut world = World::new();
        let mut lane = cycle_lane(&world, hosted);
        let notice = case == "a hosted stopped lane's last notice";
        if notice {
            lane["status"] = json!("stopped");
            lane.as_object_mut().unwrap().remove("parked");
            let mailbox = world
                .dir
                .path()
                .join("host-disk/remote/KEN-1/tmp/lane-mail/KEN-1/to-overseer.jsonl");
            std::fs::create_dir_all(mailbox.parent().unwrap()).unwrap();
            std::fs::write(
                &mailbox,
                "{\"kind\":\"notice\",\"id\":\"n-last\",\"text\":\"result: done\"}\n",
            )
            .unwrap();
        }
        if cycle {
            lane["cycle"] = json!({"pr": 7, "item": "KEN-1"});
        }
        let unnamed = case.starts_with("a lane with no repo");
        if unnamed {
            lane["repo"] = json!(null);
        }
        world.write_fleet(
            &json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
            "lanes": [lane]}),
        );
        world.linear("statuses list", statuses());
        world.linear("issues list", json!({"body": []}));
        world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-1", "state": {"type": "completed"}, "description": "## Done when\n- [x] Done\n  Evidence: yes\n", "children": {"nodes": []}}
        ]}}}));
        quiet_github(&mut world);
        // The merged index's reads of the item: its head branch's closed
        // pull requests, the case's merged ones, and its mentions, none.
        let listed: Vec<Value> = pulls.iter().map(|n| merged_pull(*n, "ken-1")).collect();
        world.gh(
            "repos/owner/repo/pulls?state=closed&head=owner%3Aken-1&per_page=100&page=1",
            json!({ "body": listed }),
        );
        world.gh(
            "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-1%22%20in%3Atitle%2Cbody&per_page=100&page=1",
            json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
        );
        world.gh("graphql number=7 cursor=", timeline_seven());
        installed_cycle_recorder(&world);
        let clock = FakeClock::new();
        let settings = world.settings(&[]);
        let mut context = world.context(settings, None);
        if unnamed {
            context.repos = vec!["owner/repo".to_owned()];
        }
        let mut body = tracker::body(context);
        let mut baseline = Baseline::default();
        if let Some(row) = merged_row {
            baseline.apply(set(github::MERGED_ROW, "KEN-1", row));
        }
        if held {
            baseline.apply(set(
                tracker::TERMINAL_CLOSE_ROW,
                "KEN-1",
                "completed|2026-09-20T08:50:00Z|close-failed cause=boxes-unsettled",
            ));
        }
        let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
        let mut said = rendered(&first);
        if notice {
            let mail: Vec<String> = said.drain(..2.min(said.len())).collect();
            assert_eq!(
                mail,
                ["EVENT lane-notice KEN-1 n-last", "  result: done"],
                "{case}: {said:?}"
            );
        }
        let timeline_reads = || {
            world
                .gh_calls()
                .iter()
                .filter(|c| c.contains("-F number=7 -f gate="))
                .count()
        };
        let lane = world.fleet()["lanes"][0].clone();
        if held {
            assert_eq!(said, Vec::<String>::new(), "{case}");
            assert_eq!(timeline_reads(), 0, "{case}: {:?}", world.gh_calls());
            assert_eq!(lane["status"], "parked", "{case}: {lane}");
            continue;
        }
        assert_eq!(said.len(), 2, "{case}: {said:?}");
        assert!(
            said[0].starts_with("cycle item=KEN-1 pr=7 "),
            "{case}: {said:?}"
        );
        assert_eq!(said[1], "EVENT lane-closed KEN-1", "{case}: {said:?}");
        assert_eq!(lane["cycle"]["pr"], json!(7), "{case}: {lane}");
        assert_eq!(lane["cycle"]["repo"], json!("owner/repo"), "{case}: {lane}");
        assert_eq!(lane["status"], "done", "{case}: {lane}");
        let fleet = world.fleet();
        assert!(
            fleet["fleet_log"]
                .as_array()
                .unwrap()
                .iter()
                .any(|row| row["kind"] == "cycle" && row["item"] == "KEN-1"),
            "{case}: {}",
            fleet["fleet_log"]
        );
        // The GitHub duty's pass writes the row the tracker read past.
        baseline.apply(set(github::MERGED_ROW, "KEN-1", "owner/repo#7"));
        let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
        assert_eq!(rendered(&second), Vec::<String>::new(), "{case}");
        assert_eq!(timeline_reads(), 1, "{case}: {:?}", world.gh_calls());
    }
}

/// Linear's state type `duplicate` (every team holds a state Duplicate of
/// that type) is finished work as `canceled` is: the owed read asks for no
/// Duplicate item, and a hosted parked lane whose item reads `duplicate`
/// gets the terminal verdict and closes as one whose item reads `canceled`.
#[test]
fn a_parked_lane_whose_item_reads_duplicate_closes_as_a_canceled_one() {
    if !isolated_row("a_parked_lane_whose_item_reads_duplicate_closes_as_a_canceled_one") {
        return;
    }
    for kind in ["canceled", "duplicate"] {
        let mut world = World::new();
        world.write_fleet(
            &json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
            "lanes": [cycle_lane(&world, true)]}),
        );
        let mut team = statuses();
        team["body"]
            .as_array_mut()
            .unwrap()
            .push(json!({"name": "Duplicate", "type": "duplicate"}));
        world.linear("statuses list", team);
        world.linear("issues list", json!({"body": []}));
        world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-1", "state": {"type": kind}, "description": null, "children": {"nodes": []}}
        ]}}}));
        quiet_github(&mut world);
        world.gh(
            "repos/owner/repo/pulls?state=closed&head=owner%3Aken-1&per_page=100&page=1",
            json!({ "body": [merged_pull(7, "ken-1")] }),
        );
        world.gh(
            "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-1%22%20in%3Atitle%2Cbody&per_page=100&page=1",
            json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
        );
        world.gh("graphql number=7 cursor=", timeline_seven());
        installed_cycle_recorder(&world);
        let clock = FakeClock::new();
        let mut body = tracker::body(world.context(world.settings(&[]), None));
        let mut baseline = Baseline::default();
        let said = rendered(&pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap());
        assert_eq!(said.len(), 2, "{kind}: {said:?}");
        assert!(
            said[0].starts_with("cycle item=KEN-1 pr=7 "),
            "{kind}: {said:?}"
        );
        assert_eq!(said[1], "EVENT lane-closed KEN-1", "{kind}: {said:?}");
        let lane = world.fleet()["lanes"][0].clone();
        assert_eq!(lane["status"], "done", "{kind}: {lane}");
        let calls = world.linear_calls();
        let owed = calls
            .iter()
            .find(|c| c.starts_with("issues list"))
            .unwrap_or_else(|| panic!("{kind}: {calls:?}"));
        assert!(
            owed.contains(" --state In Progress,In Review,Verifying,Todo,Backlog,Triage --select "),
            "{kind}: {owed}"
        );
    }
}

/// A terminal close whose landing the recorder cannot write is held, never
/// made without its cycle: through the real tracker duty and `pr-timeline`
/// over the `gh` fixture, a hosted parked lane whose item ended at its
/// merge, the timeline unanswered, stays parked with nothing said and its
/// hold under the close's row; the next pass asks the timeline again with
/// the same cause and keeps the row as it was (its line said once); once
/// the timeline answers, the cycle is written with the close.
#[test]
fn a_terminal_close_over_an_unrecorded_landing_is_held_until_its_cycle_records() {
    if !isolated_row("a_terminal_close_over_an_unrecorded_landing_is_held_until_its_cycle_records")
    {
        return;
    }
    let mut world = World::new();
    let lane = cycle_lane(&world, true);
    world.write_fleet(
        &json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [lane]}),
    );
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
        {"identifier": "KEN-1", "state": {"type": "completed"}, "description": "## Done when\n- [x] Done\n  Evidence: yes\n", "children": {"nodes": []}}
    ]}}}));
    quiet_github(&mut world);
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aken-1&per_page=100&page=1",
        json!({ "body": [merged_pull(7, "ken-1")] }),
    );
    world.gh(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-1%22%20in%3Atitle%2Cbody&per_page=100&page=1",
        json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
    );
    installed_cycle_recorder(&world);
    let clock = FakeClock::new();
    let mut body = tracker::body(world.context(world.settings(&[]), None));
    let mut baseline = Baseline::default();
    let timeline_reads = || {
        world
            .gh_calls()
            .iter()
            .filter(|c| c.contains("-F number=7 -f gate="))
            .count()
    };
    let held_row = |produced: &Produced| {
        produced.changes.iter().any(|c| {
            matches!(c, Change::Set { kind, identity, .. }
                if kind == tracker::TERMINAL_CLOSE_ROW && identity == "KEN-1")
        })
    };

    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(rendered(&first), Vec::<String>::new());
    assert!(held_row(&first), "the hold is kept under the close's row");
    assert_eq!(world.fleet()["lanes"][0]["status"], "parked");
    let reads = timeline_reads();
    assert!(reads > 0, "{:?}", world.gh_calls());

    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(rendered(&second), Vec::<String>::new());
    assert!(!held_row(&second), "the same cause is said once");
    assert!(timeline_reads() > reads, "the held close is asked again");
    assert_eq!(world.fleet()["lanes"][0]["status"], "parked");

    world.gh("graphql number=7 cursor=", timeline_seven());
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    let said = rendered(&third);
    assert_eq!(
        said.last().map(String::as_str),
        Some("EVENT lane-closed KEN-1"),
        "{said:?}"
    );
    let lane = world.fleet()["lanes"][0].clone();
    assert_eq!(lane["status"], "done", "{lane}");
    assert_eq!(lane["cycle"]["pr"], json!(7), "{lane}");
}

#[test]
fn a_terminal_close_whose_effect_fails_is_said_refused_not_closed() {
    let harness = Owned::sleep();
    let mut world = World::new();
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [{"item": "KEN-3", "tracker": "linear", "repo": "owner/repo", "harness": "claude",
            "window": null, "host": null, "mail_root": "/srv/lane/x", "status": "stopped",
            "session_since": "2026-10-09T00:00:00Z",
            "launch": {"pane": "%7", "server": 41020, "pid": harness.pid(), "start": harness.start()}}]}));
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
        {"identifier": "KEN-3", "state": {"type": "canceled"}, "description": null, "children": {"nodes": []}}
    ]}}}));
    quiet_github(&mut world);
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aken-3&per_page=100&page=1",
        json!({"body": []}),
    );
    world.gh(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-3%22%20in%3Atitle%2Cbody&per_page=100&page=1",
        json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
    );
    // The harness still runs and holds an unanswered ask: the close's
    // effect refuses it and records `failed`, the harness untouched.
    let mailbox = world.dir.path().join("asking-lane-mail");
    write_executable(
        &mailbox,
        "#!/bin/bash\n[ \"${1:-}\" = pending ] && printf '%s\\n' '{\"id\":\"1769700000-9-31\",\"kind\":\"ask\",\"text\":\"which base\"}'\nexit 0\n",
    );
    let mailbox = mailbox.display().to_string();
    let clock = FakeClock::new();
    // A close bound outside its form refuses the close before its intent
    // persists: the pass says it refused, and no intent stands.
    let judged = world.settings(&[
        ("LANE_MAIL_CLI", mailbox.as_str()),
        ("ORCH_LANE_CLOSE_SECS", "0"),
    ]);
    let mut refusing = tracker::body(world.context(judged, None));
    let refused = pass(
        &mut refusing,
        &mut Baseline::default(),
        &clock,
        SINCE_EPOCH + 1000,
    )
    .unwrap();
    assert_eq!(rendered(&refused), vec!["EVENT lane-close-refused KEN-3"]);
    assert_eq!(world.fleet()["intents"], Value::Null, "no intent persisted");
    let settings = world.settings(&[("LANE_MAIL_CLI", mailbox.as_str())]);
    let mut body = tracker::body(world.context(settings, None));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(rendered(&first), vec!["EVENT lane-close-refused KEN-3"]);
    let close = world.fleet()["intents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["op"] == "close-resources")
        .cloned()
        .unwrap();
    assert_eq!(close["outcome"], "failed", "{close}");
    assert!(live(harness.pid()), "the refused close stopped nothing");
}

/// A stopped lane whose own item ended while an item joined to it reads
/// open is not closed: the batch reads the joined item, and the close is
/// asked only once it ended too. The close runs under a bound outside its
/// form, so its asking is seen as its refusal and no intent persists.
#[test]
fn a_lane_carrying_an_open_joined_item_is_not_closed_until_that_item_ends() {
    let mut world = World::new();
    world.write_fleet(
        &json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [{"item": "KEN-3", "tracker": "linear", "repo": "owner/repo", "harness": "claude",
            "window": null, "host": null, "mail_root": "/srv/lane/x", "status": "stopped",
            "session_since": "2026-10-09T00:00:00Z",
            "carried": [{"item": "KEN-7", "tracker": "linear", "at": "2026-10-09T01:00:00Z"}]}]}),
    );
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    quiet_github(&mut world);
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aken-3&per_page=100&page=1",
        json!({"body": []}),
    );
    world.gh(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-3%22%20in%3Atitle%2Cbody&per_page=100&page=1",
        json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
    );
    let clock = FakeClock::new();
    let batch = |joined: &str| {
        json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-3", "state": {"type": "canceled"}, "description": null, "children": {"nodes": []}},
            {"identifier": "KEN-7", "state": {"type": joined}, "description": null, "children": {"nodes": []}}
        ]}}})
    };
    for (joined, expected) in [
        ("started", Vec::<&str>::new()),
        ("canceled", vec!["EVENT lane-close-refused KEN-3"]),
    ] {
        world.linear("issues bulk-get", batch(joined));
        let settings = world.settings(&[("ORCH_LANE_CLOSE_SECS", "0")]);
        let mut body = tracker::body(world.context(settings, None));
        let produced = pass(
            &mut body,
            &mut Baseline::default(),
            &clock,
            SINCE_EPOCH + 1000,
        )
        .unwrap();
        assert_eq!(rendered(&produced), expected, "KEN-7 {joined}");
    }
    assert_eq!(world.fleet()["intents"], Value::Null, "no intent persisted");
}

#[test]
fn an_open_terminal_close_the_watch_asked_is_settled_by_its_own_next_pass() {
    let harness = Owned::sleep();
    // A live process that is no tmux server stands at the recorded server
    // pid: the pane cannot be read, so the close's effect stays open.
    let mut not_a_server = Some(Owned::sleep());
    let server_pid = not_a_server.as_ref().unwrap().pid();
    let mut world = World::new();
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [{"item": "KEN-3", "tracker": "linear", "repo": "owner/repo", "harness": "claude",
            "window": null, "host": null, "mail_root": "/srv/lane/x", "status": "stopped",
            "session_since": "2026-10-09T00:00:00Z",
            "launch": {"pane": "%7", "server": server_pid, "pid": harness.pid(), "start": harness.start()}}]}));
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
        {"identifier": "KEN-3", "state": {"type": "canceled"}, "description": null, "children": {"nodes": []}}
    ]}}}));
    quiet_github(&mut world);
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aken-3&per_page=100&page=1",
        json!({"body": []}),
    );
    world.gh(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-3%22%20in%3Atitle%2Cbody&per_page=100&page=1",
        json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
    );
    let mailbox = world.dir.path().join("quiet-lane-mail");
    write_executable(&mailbox, "#!/bin/bash\nexit 0\n");
    let mailbox = mailbox.display().to_string();
    let settings = world.settings(&[("LANE_MAIL_CLI", mailbox.as_str())]);
    let clock = FakeClock::new();
    let mut body = tracker::body(world.context(settings, None));
    let mut baseline = Baseline::default();
    let close = |w: &World| -> Value {
        w.fleet()["intents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["op"] == "close-resources")
            .cloned()
            .unwrap_or(Value::Null)
    };
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert!(rendered(&first).is_empty(), "{:?}", rendered(&first));
    assert_eq!(close(&world)["outcome"], "unconfirmed", "{}", close(&world));
    // The process at the recorded server pid ends: the pane reads gone, so
    // the watch's own next pass settles its close.
    not_a_server.take();
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(rendered(&second), vec!["EVENT lane-closed KEN-3"]);
    assert_eq!(close(&world)["outcome"], "confirmed", "{}", close(&world));
}

/// The slot the heartbeat body reads names the open items with no open
/// blocker that no lane holds and the queue does not name, sorted; an item
/// joined to a running lane is held by that lane, unblocked or owed alike.
#[test]
fn the_heartbeat_slot_names_the_open_unblocked_items_no_lane_holds() {
    let mut world = World::new();
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": triage_items()}));
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-1", "state": {"type": "unstarted"}, "children": {"nodes": []}},
            {"identifier": "KEN-2", "state": {"type": "started"}, "children": {"nodes": []}},
            {"identifier": "KEN-3", "state": {"type": "unstarted"}, "children": {"nodes": []}},
            {"identifier": "KEN-4", "state": {"type": "backlog"}, "children": {"nodes": []}},
            {"identifier": "KEN-5", "state": {"type": "unstarted"}, "children": {"nodes": []}}
        ]}}}),
    );
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": ["KEN-5"], "fleet_log": [],
        "lanes": [
            {"item": "KEN-3", "tracker": "linear", "harness": "claude", "window": null, "host": null, "mail_root": "/w/KEN-3", "status": "running",
             "carried": [
                 {"item": "KEN-1", "tracker": "linear", "at": "2026-08-20T00:00:00Z"},
                 {"item": "KEN-2", "tracker": "linear", "at": "2026-08-20T00:00:00Z"}
             ]},
            {"item": "KEN-4", "tracker": "linear", "harness": "claude", "window": null, "host": null, "mail_root": "/w/KEN-4", "status": "done"}
        ]}));
    quiet_github(&mut world);
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aken-3&per_page=100&page=1",
        json!({"body": []}),
    );
    world.gh(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-3%22%20in%3Atitle%2Cbody&per_page=100&page=1",
        json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
    );
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let ctx = world.context(settings, None);
    let shared = ctx.shared.clone();
    let mut body = tracker::body(ctx);
    let mut baseline = Baseline::default();
    pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    let latest = shared.lock().unwrap();
    let inventory = latest.tracker.as_ref().unwrap();
    assert_eq!(
        inventory.open_unblocked,
        vec!["KEN-4".to_owned()],
        "KEN-1 joined to KEN-3's lane, KEN-2 blocked, KEN-3 held by a lane, KEN-5 queued; a done lane holds nothing"
    );
    assert_eq!(
        inventory.open,
        ["KEN-1", "KEN-2", "KEN-3", "KEN-4", "KEN-5"]
            .into_iter()
            .map(|id| {
                let hold = if id == "KEN-2" {
                    OpenHold::Relation
                } else {
                    OpenHold::Unblocked
                };
                (id.to_owned(), hold)
            })
            .collect::<BTreeMap<_, _>>(),
        "every open item, whatever lane or queue holds it, with KEN-2 held by its blocker"
    );
    assert!(
        inventory.owed.iter().all(|row| row.id != "KEN-2"),
        "KEN-2, in progress, is joined to a running lane: not owed: {:?}",
        inventory.owed.iter().map(|row| &row.id).collect::<Vec<_>>()
    );
}

/// The heartbeat owes Todo and Backlog items that can start. It owes
/// started items unless the label holds them or a live lane has them.
/// A stopped lane with a label and a completed relation waits on the
/// blocker. A parked lane's saved ask takes effect again when the label
/// clears, or when a relation holds launch. The last column is the
/// `open-unblocked` membership.
#[test]
fn the_heartbeat_applies_selection_holds_and_reports_the_stopped_blocker() {
    let mut world = World::new();
    // id, state, state type, priority, then the row's other fields; the
    // `owed` line expected, or none; whether `open-unblocked` lists it.
    type Row<'a> = (
        &'a str,
        &'a str,
        &'a str,
        Value,
        Value,
        Option<&'a str>,
        bool,
    );
    let rows: Vec<Row> = vec![
        (
            "KEN-1",
            "Todo",
            "unstarted",
            json!(2),
            json!({}),
            Some("state=todo priority=2"),
            true,
        ),
        (
            "KEN-2",
            "Backlog",
            "backlog",
            Value::Null,
            json!({}),
            Some("state=backlog priority=-"),
            true,
        ),
        // A renamed unstarted state is Todo work by its type.
        (
            "KEN-3",
            "Ready",
            "unstarted",
            json!(1),
            json!({}),
            Some("state=todo priority=1"),
            true,
        ),
        (
            "KEN-4",
            "Todo",
            "unstarted",
            json!(1),
            json!({"blocked_by_open": ["KEN-1"], "blocked_by": ["KEN-1"], "blocked_by_launch": ["KEN-1"]}),
            None,
            false,
        ),
        // The label alone: a blocker outside the tracker.
        (
            "KEN-5",
            "Backlog",
            "backlog",
            json!(2),
            json!({"labels": ["skills", "blocked"]}),
            None,
            false,
        ),
        // A completed relation leaves the label in force.
        (
            "KEN-6",
            "Backlog",
            "backlog",
            json!(2),
            json!({"labels": ["blocked"], "blocked_by": ["KEN-99"]}),
            None,
            false,
        ),
        // A Verifying blocker holds no launch.
        (
            "KEN-7",
            "Todo",
            "unstarted",
            json!(3),
            json!({"blocked_by_open": ["KEN-98"], "blocked_by": ["KEN-98"]}),
            Some("state=todo priority=3"),
            true,
        ),
        (
            "KEN-8",
            "Todo",
            "unstarted",
            json!(1),
            json!({}),
            None,
            true,
        ),
        (
            "KEN-9",
            "Todo",
            "unstarted",
            json!(2),
            json!({"parent_id": "KEN-8"}),
            Some("state=todo priority=2"),
            true,
        ),
        (
            "KEN-10",
            "Todo",
            "unstarted",
            json!(2),
            json!({"labels": ["agent:multi"]}),
            None,
            true,
        ),
        (
            "KEN-11",
            "Todo",
            "unstarted",
            json!(1),
            json!({"in_pr_bundle": true}),
            Some("state=todo priority=1"),
            true,
        ),
        // The bundle root's lane works its children.
        (
            "KEN-12",
            "Backlog",
            "backlog",
            json!(1),
            json!({"parent_id": "KEN-11"}),
            None,
            true,
        ),
        (
            "KEN-13",
            "Todo",
            "unstarted",
            json!(1),
            json!({"blocked_by_open": ["KEN-1"], "blocked_by": ["KEN-1"], "blocked_by_launch": ["KEN-1"]}),
            None,
            false,
        ),
        // Its container ancestor holds it, as the Ancestor gate does.
        (
            "KEN-14",
            "Todo",
            "unstarted",
            json!(1),
            json!({"parent_id": "KEN-13"}),
            None,
            true,
        ),
        (
            "KEN-15",
            "In Progress",
            "started",
            json!(2),
            json!({"labels": ["blocked"], "blocked_by_open": ["KEN-1"], "blocked_by": ["KEN-1"], "blocked_by_launch": ["KEN-1"]}),
            Some("state=in-progress priority=2"),
            false,
        ),
        (
            "KEN-16",
            "In Progress",
            "started",
            json!(2),
            json!({}),
            Some("state=in-progress priority=2"),
            true,
        ),
        (
            "KEN-17",
            "Triage",
            "triage",
            json!(1),
            json!({"parent_id": "KEN-16"}),
            None,
            true,
        ),
        // Held two levels up: KEN-14's parent KEN-13 is blocked.
        (
            "KEN-18",
            "Todo",
            "unstarted",
            json!(1),
            json!({"parent_id": "KEN-14"}),
            None,
            true,
        ),
        (
            "KEN-19",
            "Todo",
            "unstarted",
            json!(2),
            json!({"labels": ["blocked"], "blocked_by_open": ["KEN-1"], "blocked_by": ["KEN-1"], "blocked_by_launch": ["KEN-1"]}),
            None,
            false,
        ),
        // The same completed relation without the outside blocker.
        (
            "KEN-20",
            "Backlog",
            "backlog",
            json!(2),
            json!({"blocked_by": ["KEN-99"]}),
            Some("state=backlog priority=2"),
            true,
        ),
        (
            "KEN-21",
            "In Progress",
            "started",
            json!(2),
            json!({"labels": ["blocked"], "blocked_by": ["KEN-99"]}),
            None,
            false,
        ),
        // Verifying is open for verification but holds no launch.
        (
            "KEN-22",
            "Todo",
            "unstarted",
            json!(3),
            json!({"labels": ["blocked"], "blocked_by_open": ["KEN-98"], "blocked_by": ["KEN-98"]}),
            None,
            false,
        ),
        (
            "KEN-23",
            "In Progress",
            "started",
            json!(2),
            json!({"labels": ["blocked"], "blocked_by": ["KEN-99"]}),
            None,
            false,
        ),
        (
            "KEN-24",
            "In Progress",
            "started",
            json!(2),
            json!({"labels": ["blocked"], "blocked_by_open": ["KEN-1"], "blocked_by": ["KEN-1"], "blocked_by_launch": ["KEN-1"]}),
            None,
            false,
        ),
    ];
    let mut items: Vec<Value> = rows
        .iter()
        .map(|(id, state, kind, priority, fields, _, _)| {
            let mut row = item(
                id,
                "2026-08-16T00:00:00Z",
                state,
                kind,
                priority.clone(),
                &[],
            );
            for (key, value) in fields.as_object().unwrap() {
                row[key] = value.clone();
            }
            row
        })
        .collect();
    let nodes: Vec<Value> = items
        .iter()
        .map(|row| {
            let children: Vec<Value> = items
                .iter()
                .filter(|child| child["parent_id"] == row["id"])
                .map(|child| json!({"identifier": child["id"], "state": {"type": child["state_type"]}}))
                .collect();
            json!({"identifier": row["id"], "state": {"type": row["state_type"]},
                "children": {"nodes": children}})
        })
        .collect();
    let mut statuses = statuses();
    statuses["body"]
        .as_array_mut()
        .unwrap()
        .push(json!({"name": "Ready", "type": "unstarted"}));
    world.linear("statuses list", statuses);
    world.linear("issues list", json!({"body": &items}));
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": nodes}}}),
    );
    world.write_fleet(&json!({
        "issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [
            {"item": "KEN-21", "tracker": "linear", "status": "stopped"},
            {"item": "KEN-23", "tracker": "linear", "status": "parked",
             "parked": {"head": "abc", "repo": "owner/repo", "at": SINCE, "ask": "a-23"}},
            {"item": "KEN-24", "tracker": "linear", "status": "parked",
             "parked": {"head": "abc", "repo": "owner/repo", "at": SINCE, "ask": "a-24"}}
        ]
    }));
    quiet_github(&mut world);
    let clock = FakeClock::new();
    let ctx = world.context(world.settings(&[]), None);
    let shared = ctx.shared.clone();
    let mut tracker_body = tracker::body(ctx);
    let mut baseline = Baseline::default();
    pass(&mut tracker_body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    let mut heartbeat_body = heartbeat::body(heartbeat::Context {
        settings: world.settings(&[]),
        path: world.fleet_path(),
        max_loops: 25,
        interval: Duration::from_secs(240),
        since: None,
        repos: Vec::new(),
        gh: world.dir.path().join("gh"),
        shared,
        verifying: verifying::Lines::default(),
        locking: Locking::FLOCK,
        nonce: 7,
        owner: None,
    });
    let produced = pass_as(
        Duty::Heartbeat,
        &mut heartbeat_body,
        &mut baseline,
        &clock,
        SINCE_EPOCH + 1000,
    )
    .unwrap();
    let lines = rendered(&produced);
    assert_eq!(
        lines
            .iter()
            .find(|line| line.starts_with("EVENT lane-ended KEN-21 "))
            .map(String::as_str),
        Some("EVENT lane-ended KEN-21 lane=stopped waits=blocker"),
    );
    let owed: Vec<&str> = lines
        .iter()
        .map(String::as_str)
        .filter(|l| l.starts_with("owed "))
        .collect();
    let mut expected: Vec<(&str, String)> = rows
        .iter()
        .filter_map(|(id, _, _, _, _, line, _)| {
            line.map(|line| (*id, format!("owed {id} {line} lane=none verdict=queue")))
        })
        .collect();
    expected.sort();
    let expected: Vec<&str> = expected.iter().map(|(_, line)| line.as_str()).collect();
    assert_eq!(owed, expected, "{lines:?}");
    let mut unblocked: Vec<&str> = rows.iter().filter(|row| row.6).map(|row| row.0).collect();
    unblocked.sort();
    let line = format!(
        "open-unblocked count={} items={}",
        unblocked.len(),
        unblocked.join(",")
    );
    assert!(lines.contains(&line), "{line}: {lines:?}");

    assert!(
        lines
            .iter()
            .any(|line| line == "EVENT lane-ended KEN-23 lane=parked waits=blocker"),
        "{lines:?}"
    );
    assert!(
        lines
            .iter()
            .any(|line| line == "EVENT lane-ended KEN-24 lane=parked waits=owner"),
        "{lines:?}"
    );

    // Only the fresh tracker read changes. The same parked record still holds its ask.
    items.iter_mut().find(|row| row["id"] == "KEN-23").unwrap()["labels"] = json!([]);
    world.linear("issues list", json!({"body": items}));
    pass(&mut tracker_body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    let produced = pass_as(
        Duty::Heartbeat,
        &mut heartbeat_body,
        &mut baseline,
        &clock,
        SINCE_EPOCH + 1240,
    )
    .unwrap();
    let lines = rendered(&produced);
    assert!(
        lines
            .iter()
            .any(|line| line == "EVENT lane-ended KEN-23 lane=parked waits=owner"),
        "{lines:?}"
    );
}

/// The terminal state read of a GitHub-tracked item and a container's
/// Verifying reading, both through the one batch each.
#[test]
fn containers_and_github_tracked_items_are_read_in_their_batches() {
    let mut world = World::new();
    world.linear("statuses list", statuses());
    let mut items = vec![item(
        "KEN-10",
        "2026-09-01T00:00:00Z",
        "In Progress",
        "started",
        json!(1),
        &[],
    )];
    items[0]["in_pr_bundle"] = json!(false);
    world.linear("issues list", json!({"body": items}));
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-10", "state": {"type": "started"}, "children": {"nodes": [
                {"identifier": "KEN-11", "state": {"type": "completed"}},
                {"identifier": "KEN-12", "state": {"type": "canceled"}}]}}
        ]}}}),
    );
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
        "lanes": [{"item": "issue-7", "tracker": "github", "repo": "Owner/Repo", "harness": "claude", "window": null, "host": null, "mail_root": "/w/issue-7", "status": "stopped", "session_since": "2026-10-09T00:00:00Z"}]}));
    quiet_github(&mut world);
    world.gh(
        "repos/owner/repo/issues/7",
        json!({"body": {"number": 7, "state": "closed", "state_reason": "not_planned", "user": null, "author_association": "NONE"}}),
    );
    world.gh(
        "repos/owner/repo/pulls?state=closed&head=owner%3Aissue-7&per_page=100&page=1",
        json!({"body": []}),
    );
    world.gh("search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22issue-7%22%20in%3Atitle%2Cbody&per_page=100&page=1",
        json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}));
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let ctx = world.context(settings, None);
    let shared = ctx.shared.clone();
    let mut body = tracker::body(ctx);
    let mut baseline = Baseline::default();
    let produced = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&produced),
        vec!["EVENT lane-closed issue-7"],
        "a closed, not-planned issue ends canceled"
    );
    let latest = shared.lock().unwrap();
    let verifying = &latest.tracker.as_ref().unwrap().verifying;
    assert_eq!(verifying.len(), 1);
    assert!(
        verifying[0].container && verifying[0].id == "KEN-10",
        "{verifying:?}"
    );
    assert!(
        latest.tracker.as_ref().unwrap().owed.is_empty(),
        "a container is Verifying, not owed"
    );
    let _ = TerminalState::Open;
}

/// The settings a refusal of a GitHub read leaves alone and the
/// `since-invalid` refusal of a malformed floor are the verb's; here the
/// Baseline change set is checked once for shape: a Set and a Clear from
/// the duty carry the row kinds it owns.
#[test]
fn the_duty_owns_its_row_kinds() {
    assert_eq!(
        tracker::row_kinds(),
        [
            "tracker-quota",
            "triage",
            "terminal-close",
            "owner-ask-mark"
        ]
    );
    assert_eq!(
        github::row_kinds(),
        [
            "merged",
            "parked-until",
            "refresh-failing",
            "main-push-failing",
            "main-schedule-failing",
            "main-workflow-absent",
            "main-push-budget",
            "pr-watch",
            "outside-contribution",
            "security-alert",
            "bot-fix",
            "github-auth",
            "verifying-unjudged"
        ]
    );
    let _ = set("triage", "KEN-1", "Todo|-");
}

// --- the GitHub duty's readings and the split -----------------------------

/// The main-push reads of the one repository answer an empty list for
/// every workflow and event (the push read's first page, the scheduled
/// read's newest completed run), so the budget workflow stands and
/// nothing is red.
fn quiet_main(world: &mut World) {
    for workflow in ["skill-tests.yml", "ci.yml"] {
        for query in [
            "event=push&per_page=100&page=1",
            "event=schedule&status=completed&per_page=1",
        ] {
            world.gh(
                &format!("repos/owner/repo/actions/workflows/{workflow}/runs?branch=main&{query}"),
                json!({"body": {"total_count": 0, "workflow_runs": []}}),
            );
        }
    }
}

/// The push read of `skill-tests.yml` on main: its first page with no
/// mark, or every run created at or after `floor`.
fn push_path(floor: Option<&str>) -> String {
    let base = "repos/owner/repo/actions/workflows/skill-tests.yml/runs?branch=main&event=push";
    match floor {
        None => format!("{base}&per_page=100&page=1"),
        Some(floor) => format!("{base}&created=%3E%3D{floor}&per_page=100&page=1"),
    }
}

/// The head a push row's run `id` carries: the id, zero-padded to a sha.
fn push_head(id: u64) -> String {
    format!("{id:040}")
}

/// A push run on main in GitHub's documented shape; `conclusion` is null
/// for a run not completed.
fn push_run(id: u64, created_at: &str, status: &str, conclusion: Option<&str>) -> Value {
    json!({"id": id, "run_attempt": 1, "created_at": created_at, "updated_at": created_at,
        "status": status, "conclusion": conclusion, "event": "push", "head_branch": "main",
        "path": ".github/workflows/skill-tests.yml", "head_sha": push_head(id),
        "workflow_id": 1, "repository": {"id": 1296269, "full_name": "owner/repo"},
        "head_repository": {"id": 1296269, "full_name": "owner/repo"}, "pull_requests": []})
}

/// A world whose main-push reads answer quiet but for `skill-tests.yml`'s
/// push runs, which a row plants, and whose budget workflow has no run.
fn push_world() -> World {
    let mut world = World::new();
    quiet_github(&mut world);
    quiet_main(&mut world);
    world.gh(
        "repos/owner/repo/actions/workflows/skill-tests.yml/runs?per_page=100&page=1",
        json!({"body": {"total_count": 0, "workflow_runs": []}}),
    );
    world
}

/// Plants `runs` as one page at `path`.
fn plant_runs(world: &mut World, path: &str, runs: Vec<Value>) {
    world.gh(
        path,
        json!({"body": {"total_count": runs.len(), "workflow_runs": runs}}),
    );
}

/// Plants run `id`'s one failed job, named `tests`, and its log.
fn plant_red_jobs(world: &mut World, id: u64) {
    let job = id * 10;
    world.gh(
        &format!("repos/owner/repo/actions/runs/{id}/jobs?per_page=100&page=1"),
        json!({"body": {"total_count": 1, "jobs": [{"id": job, "run_id": id, "name": "tests",
            "head_sha": "0000000000000000000000000000000000000000", "status": "completed",
            "conclusion": "failure", "started_at": "2026-08-15T09:00:00Z", "completed_at": "2026-08-15T09:01:00Z",
            "check_run_url": format!("https://api.github.com/repos/owner/repo/check-runs/{job}")}]}}),
    );
    world.gh(
        &format!("repos/owner/repo/actions/jobs/{job}/logs"),
        json!({"text": format!("2026-10-18T00:00:00.0000000Z FAILED: suite-{id}\n")}),
    );
}

/// The `main-push-failing` line a red push run of `skill-tests.yml` prints,
/// its range starting at run `since`'s head, `None` where no green run is
/// known.
fn red_line(id: u64, since: Option<u64>) -> String {
    let since = since.map_or_else(|| "none".to_owned(), push_head);
    format!(
        "EVENT main-push-failing owner/repo workflow=skill-tests.yml event=push run={id} head={} since={since} jobs=[\"tests\"] cause=FAILED: suite-{id}",
        push_head(id)
    )
}

/// A push mark's value: `floor`, the `judged` runs, the `red` run's JSON or
/// `null`, and the run whose head is `green`.
fn push_mark(floor: &str, judged: &str, red: &str, green: Option<u64>) -> String {
    let green = green.map_or_else(|| "null".to_owned(), |id| format!("\"{}\"", push_head(id)));
    format!(r#"{{"floor":"{floor}","judged":{judged},"red":{red},"green":{green}}}"#)
}

/// The alert token file the fleet renews: mode 600, one word.
fn plant_token(world: &World, token: &str) -> PathBuf {
    let path = world.dir.path().join("alert-token");
    std::fs::write(&path, format!("{token}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    path
}

/// The head of the reducer row's pull request 12, and the one a push moves
/// it to.
const HEAD_12: &str = "abcdef0123456789abcdef0123456789abcdef01";
const HEAD_12_PUSHED: &str = "bbbb0000bbbb0000bbbb0000bbbb0000bbbb0000";

/// The reducer pass: the github package's reducer reads the repository
/// `GH_REPO` names, every open pull request, through the `gh` fixture.
#[test]
fn the_reducer_runs_per_repository_with_gh_repo_and_a_rising_edge_is_news_once() {
    let mut world = World::new();
    quiet_github(&mut world);
    world.pulls(
        "owner/repo",
        vec![reducer_pull(12, HEAD_12, "REVIEW_REQUIRED", false, 2)],
    );
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let shared = Shared::default();
    let mut body =
        github::body(world.github_context(settings.clone(), None, &["owner/repo"], shared.clone()));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        Vec::<String>::new(),
        "attention standing on the first pass of a run is the baseline"
    );
    assert_eq!(
        baseline.get("pr-watch", "owner/repo"),
        Some("12\tthreads-open")
    );
    let listings: Vec<String> = world
        .gh_calls()
        .into_iter()
        .filter(|c| c.starts_with("api graphql --paginate -f owner="))
        .collect();
    assert!(
        listings.len() == 1
            && listings[0]
                .starts_with("api graphql --paginate -f owner=owner -f name=repo -f query="),
        "GH_REPO names the repository and the reducer lists every open pull request: {listings:?}"
    );
    let threads_open = "owner/repo\t12\tabcdef01\tthreads-open\t2 unresolved review thread(s)";
    assert_eq!(
        shared.lock().unwrap().github.as_ref().unwrap().pr_watch,
        Some(github::pr_watch_context(1, threads_open, "")),
        "the standing attention reaches the heartbeat's slot"
    );
    // A new kind on the baselined pull request is the event, its line
    // after the event line, prefixed with its repository.
    world.pulls(
        "owner/repo",
        vec![reducer_pull(12, HEAD_12, "CHANGES_REQUESTED", false, 2)],
    );
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(
        rendered(&second),
        vec![
            "EVENT pr-watch rc=1",
            "owner/repo\t12\tabcdef01\tchanges-requested\ta reviewer requested changes (reviewDecision CHANGES_REQUESTED)"
        ]
    );
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    assert_eq!(
        rendered(&third),
        Vec::<String>::new(),
        "a standing key is not news"
    );
    // The same key under a new head is not news; a key that clears and
    // recurs is.
    world.pulls(
        "owner/repo",
        vec![reducer_pull(
            12,
            HEAD_12_PUSHED,
            "CHANGES_REQUESTED",
            false,
            0,
        )],
    );
    let fourth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap();
    assert_eq!(rendered(&fourth), Vec::<String>::new());
    assert_eq!(
        baseline.get("pr-watch", "owner/repo"),
        Some("12\tchanges-requested")
    );
    world.pulls(
        "owner/repo",
        vec![reducer_pull(
            12,
            HEAD_12_PUSHED,
            "REVIEW_REQUIRED",
            false,
            1,
        )],
    );
    let fifth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1960).unwrap();
    assert_eq!(
        rendered(&fifth)[0],
        "EVENT pr-watch rc=1",
        "a cleared key that recurs is news again"
    );
    // An error key on a repository's opening pass preempts the baseline:
    // a review decision outside GitHub's enum is pull request 14's error
    // line, and what `gh` wrote on stderr follows.
    let mut fresh = World::new();
    quiet_github(&mut fresh);
    let head = "aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000";
    let mut listing = reducer_listing(vec![
        reducer_pull(12, head, "REVIEW_REQUIRED", false, 2),
        reducer_pull(14, head, "DISMISSED", false, 0),
    ]);
    listing["stderr"] = json!("warning: GraphQL rate limit at 90%");
    fresh.gh("graphql pulls owner=owner name=repo", listing);
    let mut body = github::body(fresh.github_context(
        fresh.settings(&[]),
        None,
        &["owner/repo"],
        Shared::default(),
    ));
    let mut baseline = Baseline::default();
    let opening = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&opening),
        vec![
            "EVENT pr-watch rc=2",
            "owner/repo\t12\taaaa0000\tthreads-open\t2 unresolved review thread(s)",
            "owner/repo\t14\taaaa0000\terror\treview-state read is malformed (GraphQL errors, a missing field, or a value outside the queue or reviewDecision enums)",
            "owner/repo\twarning: GraphQL rate limit at 90%"
        ],
        "an error at start is the event, and the pass's stderr follows"
    );
    // The reducer's global failure: nonzero with no line is a refusal of
    // the pass, never no attention; no row moves. GitHub refuses the
    // listing.
    let mut failing = World::new();
    quiet_github(&mut failing);
    failing.gh(
        "graphql pulls owner=owner name=repo",
        json!({"exit": 1, "stderr": "gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)"}),
    );
    let mut body = github::body(failing.github_context(
        failing.settings(&[]),
        None,
        &["owner/repo"],
        Shared::default(),
    ));
    let mut baseline = Baseline::default();
    let err = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap_err();
    assert_eq!(err.key(), "reducer-failed", "{err}");
    assert!(
        err.fields()
            .contains(&("repo".to_owned(), "owner/repo".to_owned()))
            && err.fields().contains(&("exit".to_owned(), "2".to_owned())),
        "{:?}",
        err.fields()
    );
    assert_eq!(baseline, Baseline::default());
}

/// The recorded bytes of a merge replay: a rolling refresh has no item, so
/// its `refresh-ready` identity is kept by number once the reducer's line
/// clears, until the pull request merges (one `EVENT merged 1144
/// kendex/refresh <repo>`) or closes unmerged.
#[test]
fn a_refresh_identity_is_kept_until_its_pull_request_merges_once() {
    let repo = "vanillagreencom/hyprtrade";
    let mut world = World::new();
    quiet_audits(&mut world, repo);
    // The lanes app's refresh head, its CI passed, awaiting review.
    let head = "aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000";
    let mut refresh = reducer_pull(1144, head, "REVIEW_REQUIRED", false, 0);
    refresh["headRefName"] = json!("kendex/refresh");
    refresh["author"] = json!({"login": "vanillagreen-fleet-lanes", "__typename": "Bot"});
    refresh["commits"]["nodes"][0]["commit"]["checkSuites"]["nodes"] = json!([{"checkRuns": {"pageInfo": {"hasNextPage": false},
            "nodes": [{"name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS"}]}}]);
    world.pulls(repo, vec![refresh.clone()]);
    let clock = FakeClock::new();
    let mut body =
        github::body(world.github_context(world.settings(&[]), None, &[repo], Shared::default()));
    let mut baseline = Baseline::default();
    let ready = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&ready)[0],
        "EVENT pr-watch rc=1",
        "the ready head wakes on the opening pass"
    );
    // Approved and armed: the reducer's line clears, the pull request is
    // still open.
    refresh["reviewDecision"] = json!("APPROVED");
    refresh["autoMergeRequest"] = json!({"mergeMethod": "SQUASH"});
    world.pulls(repo, vec![refresh]);
    let pull = |state: &str, merged_at: Value| {
        json!({"body": {"number": 1144, "state": state, "title": "refresh", "body": "", "merged_at": merged_at, "merge_commit_sha": null,
            "author_association": "NONE", "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null,
            "head": {"sha": "0000000000000000000000000000000000000000", "ref": "kendex/refresh", "repo": {"full_name": "vanillagreencom/hyprtrade", "owner": {"login": "vanillagreencom", "type": "Organization"}}}}})
    };
    world.gh(
        "repos/vanillagreencom/hyprtrade/pulls/1144",
        pull("open", Value::Null),
    );
    let approved = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(rendered(&approved), Vec::<String>::new());
    assert_eq!(
        baseline.get("pr-watch", repo),
        Some("1144\trefresh-ready:aaaa0000"),
        "the identity is carried while the pull request is open"
    );
    world.gh(
        "repos/vanillagreencom/hyprtrade/pulls/1144",
        pull("closed", json!("2026-10-20T00:00:00Z")),
    );
    let merged = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    assert_eq!(
        rendered(&merged),
        vec!["EVENT merged 1144 kendex/refresh vanillagreencom/hyprtrade"]
    );
    assert_eq!(
        baseline.get("merged", "kendex/refresh"),
        Some("vanillagreencom/hyprtrade#1144")
    );
    assert_eq!(
        baseline.get("pr-watch", repo),
        Some(""),
        "the identity ends at the merge"
    );
    let after = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap();
    assert_eq!(
        rendered(&after),
        Vec::<String>::new(),
        "the merged line prints once"
    );
    assert_eq!(
        world
            .gh_calls()
            .iter()
            .filter(|c| c.ends_with("pulls/1144"))
            .count(),
        2,
        "the pull request is read by number only while its identity stands"
    );
}

/// The alert pass, the recorded bytes (`LINE_DEPENDABOT pr=12`,
/// `LINE_CODE`, `LINE_SECRET`, the repeats, the unread line).
#[test]
fn security_alerts_are_repeated_until_recorded_and_a_failed_read_is_never_no_alerts() {
    let url = "https://github.com/owner/repo/security";
    let dependabot = json!({"number": 7, "html_url": format!("{url}/dependabot/7"),
        "dependency": {"package": {"ecosystem": "npm", "name": "fast-uri"}, "manifest_path": "ui/package-lock.json", "scope": "runtime"},
        "security_advisory": {"ghsa_id": "GHSA-aaaa-bbbb-cccc", "severity": "high"}});
    let code = json!({"number": 9, "html_url": format!("{url}/code-scanning/9"),
        "rule": {"id": "js/xss", "severity": "error", "security_severity_level": "medium"}});
    let secret = json!({"number": 3, "html_url": format!("{url}/secret-scanning/3"),
        "secret_type": "github_personal_access_token", "validity": "active"});
    let line_dependabot = format!(
        "EVENT security-alert owner/repo kind=dependabot number=7 severity=high package=fast-uri manifest=ui/package-lock.json scope=runtime advisory=GHSA-aaaa-bbbb-cccc url={url}/dependabot/7 pr=12"
    );
    let line_code = format!(
        "EVENT security-alert owner/repo kind=code-scanning number=9 severity=medium rule=js/xss url={url}/code-scanning/9"
    );
    let line_secret = format!(
        "EVENT security-alert owner/repo kind=secret-scanning number=3 rule=github_personal_access_token validity=active url={url}/secret-scanning/3"
    );
    let mut world = World::new();
    quiet_github(&mut world);
    let token = plant_token(&world, "ghs_fixture_overseer");
    world.gh(
        "repos/owner/repo/dependabot/alerts?state=open&per_page=100",
        json!({"body": [dependabot]}),
    );
    world.gh(
        "repos/owner/repo/code-scanning/alerts?state=open&per_page=100",
        json!({"body": [code]}),
    );
    world.gh(
        "repos/owner/repo/secret-scanning/alerts?state=open&hide_secret=true&per_page=100",
        json!({"body": [secret]}),
    );
    world.gh(
        "graphql owner=owner name=repo",
        json!({"body": {"data": {"repository": {"vulnerabilityAlerts": {"pageInfo": {"hasNextPage": false, "endCursor": null},
            "nodes": [{"number": 7, "state": "OPEN", "dependabotUpdate": {"pullRequest": {"number": 12, "state": "OPEN"}}}]}}}}}),
    );
    let settings = world.settings(&[
        ("ORCH_SECURITY_ALERTS", "on"),
        (
            "ORCH_SECURITY_ALERT_TOKEN_FILE",
            &token.display().to_string(),
        ),
    ]);
    let clock = FakeClock::new();
    let shared = Shared::default();
    let mut body =
        github::body(world.github_context(settings, None, &["owner/repo"], shared.clone()));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        vec![
            line_dependabot.clone(),
            line_code.clone(),
            line_secret.clone()
        ],
        "an open alert of each kind is one line each, the Dependabot one naming its pull request"
    );
    let env = world.gh_env();
    let with_token: Vec<&String> = env
        .iter()
        .filter(|l| l.starts_with("GH_TOKEN=ghs_fixture_overseer "))
        .collect();
    assert_eq!(
        with_token.len(),
        4,
        "the three lists and the link read carry the token: {env:?}"
    );
    assert!(
        with_token
            .iter()
            .all(|l| l.contains("/alerts?") || l.contains("api graphql")),
        "{with_token:?}"
    );
    // The guarantee is that the overseer token reaches the alert reads
    // alone; the runner hands `gh` the caller's environment by contract, so
    // a caller's own `GH_TOKEN` on the other reads is not this row's.
    assert!(
        env.iter()
            .filter(|l| !l.starts_with("GH_TOKEN=ghs_fixture_overseer "))
            .all(|l| !l.contains("ghs_fixture_overseer")),
        "no other read carries the overseer token: {env:?}"
    );
    assert_eq!(
        shared.lock().unwrap().github.as_ref().unwrap().bot_fix,
        BTreeMap::from([("owner/repo#12".to_owned(), "7".to_owned())]),
        "the heartbeat's bot-fix mapping"
    );
    // The next pass, with no verdict recorded, repeats each.
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(
        rendered(&second),
        vec![
            format!("{line_dependabot} report=repeat"),
            format!("{line_code} report=repeat"),
            format!("{line_secret} report=repeat")
        ]
    );
    // A failed Dependabot read: the other lists still reported, its rows
    // standing, its unread line on the second pass it fails and no other.
    world.gh(
        "repos/owner/repo/dependabot/alerts?state=open&per_page=100",
        json!({"exit": 1, "stderr": "gh: Resource not accessible by integration (HTTP 403)"}),
    );
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    assert_eq!(
        rendered(&third),
        vec![
            format!("{line_code} report=repeat"),
            format!("{line_secret} report=repeat"),
        ],
        "a failed read is never no alerts, and one failure reaches no one"
    );
    assert_eq!(
        baseline.get("security-alert", "owner/repo#dependabot/7"),
        Some("reported"),
        "a failed read keeps its rows"
    );
    assert_eq!(
        baseline.get("bot-fix", "owner/repo#12"),
        Some("7"),
        "and its mapping"
    );
    assert_eq!(
        shared.lock().unwrap().github.as_ref().unwrap().bot_fix,
        BTreeMap::from([("owner/repo#12".to_owned(), "7".to_owned())]),
        "the mapping stands through the outage"
    );
    let fourth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap();
    assert_eq!(
        rendered(&fourth),
        vec![
            format!("{line_code} report=repeat"),
            format!("{line_secret} report=repeat"),
            "EVENT security-alerts-unread reads=owner/repo/dependabot:permission".to_owned()
        ],
        "a read failing on two consecutive passes is the unread line"
    );
    let standing = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1840).unwrap();
    assert_eq!(
        rendered(&standing),
        vec![
            format!("{line_code} report=repeat"),
            format!("{line_secret} report=repeat")
        ],
        "a standing failure prints no unread line"
    );
    // The read returns: the alert is a repeat, not a first report; the
    // unread row clears.
    world.gh(
        "repos/owner/repo/dependabot/alerts?state=open&per_page=100",
        json!({"body": [dependabot]}),
    );
    let fifth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1960).unwrap();
    assert_eq!(
        rendered(&fifth)[0],
        format!("{line_dependabot} report=repeat")
    );
    assert_eq!(
        baseline.get("security-alerts-unread", "owner/repo/dependabot"),
        None
    );
    // A verdict recorded for the secret ends its repeats; a reopened alert
    // is news again.
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": [], "fleet_log": [],
        "alerts_triaged": [{"repo": "Owner/Repo", "kind": "secret-scanning", "number": 3, "verdict": "filed"}]}));
    world.gh(
        "repos/owner/repo/code-scanning/alerts?state=open&per_page=100",
        json!({"body": []}),
    );
    let sixth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2200).unwrap();
    assert_eq!(
        rendered(&sixth),
        vec![format!("{line_dependabot} report=repeat")]
    );
    assert_eq!(
        baseline.get("security-alert", "owner/repo#secret-scanning/3"),
        None
    );
    world.gh(
        "repos/owner/repo/code-scanning/alerts?state=open&per_page=100",
        json!({"body": [code]}),
    );
    let seventh = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2440).unwrap();
    assert_eq!(
        rendered(&seventh),
        vec![
            format!("{line_dependabot} report=repeat"),
            line_code.clone()
        ],
        "an alert closed and reopened is a first report again"
    );
    // The link read pages: a pull request linked on the second page links
    // its alert as one on the first does.
    world.gh(
        "graphql owner=owner name=repo",
        json!({"pages": {
            "": {"data": {"repository": {"vulnerabilityAlerts": {"pageInfo": {"hasNextPage": true, "endCursor": "Y3Vyc29yOjE="},
                "nodes": [{"number": 5, "state": "DISMISSED", "dependabotUpdate": null}]}}}},
            "Y3Vyc29yOjE=": {"data": {"repository": {"vulnerabilityAlerts": {"pageInfo": {"hasNextPage": false, "endCursor": "Y3Vyc29yOjI="},
                "nodes": [{"number": 7, "state": "OPEN", "dependabotUpdate": {"pullRequest": {"number": 12, "state": "OPEN"}}}]}}}}
        }}),
    );
    let paged = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2560).unwrap();
    assert_eq!(
        rendered(&paged),
        vec![
            format!("{line_dependabot} report=repeat"),
            format!("{line_code} report=repeat")
        ],
        "the Dependabot line names the pull request its second page links"
    );
    assert_eq!(
        shared.lock().unwrap().github.as_ref().unwrap().bot_fix,
        BTreeMap::from([("owner/repo#12".to_owned(), "7".to_owned())])
    );
    // The Dependabot list pages by the Link header's cursor, never a page
    // number GitHub refuses: an alert on its second page is reported as one
    // on the first is.
    let later = json!({"number": 8, "html_url": format!("{url}/dependabot/8"),
        "dependency": {"package": {"ecosystem": "npm", "name": "undici"}, "manifest_path": "ui/package-lock.json", "scope": "runtime"},
        "security_advisory": {"ghsa_id": "GHSA-dddd-eeee-ffff", "severity": "low"}});
    world.gh(
        "repos/owner/repo/dependabot/alerts?state=open&per_page=100",
        json!({"pages": [[dependabot], [later]]}),
    );
    let cursor_paged = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2620).unwrap();
    assert_eq!(
        rendered(&cursor_paged),
        vec![
            format!("{line_dependabot} report=repeat"),
            format!("{line_code} report=repeat"),
            format!(
                "EVENT security-alert owner/repo kind=dependabot number=8 severity=low package=undici manifest=ui/package-lock.json scope=runtime advisory=GHSA-dddd-eeee-ffff url={url}/dependabot/8"
            ),
        ],
        "the alert on the list's second page is a first report"
    );
    // A token the reader refuses: the credential source is unread, its line
    // on the second pass, no alert read runs, and the rows and mapping
    // stand.
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o640)).unwrap();
    let calls_before = world.gh_calls().len();
    let eighth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2680).unwrap();
    assert_eq!(rendered(&eighth), Vec::<String>::new());
    let ninth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2800).unwrap();
    assert_eq!(
        rendered(&ninth),
        vec!["EVENT security-alerts-unread reads=installation-token:credential"]
    );
    assert!(
        !world.gh_calls()[calls_before..]
            .iter()
            .any(|c| c.contains("/alerts?") || c.contains("vulnerabilityAlerts")),
        "no alert read without a usable token"
    );
    assert_eq!(
        baseline.get("security-alert", "owner/repo#dependabot/7"),
        Some("reported")
    );
    assert_eq!(
        shared.lock().unwrap().github.as_ref().unwrap().bot_fix,
        BTreeMap::from([("owner/repo#12".to_owned(), "7".to_owned())])
    );
}

#[test]
fn a_security_read_failure_reaches_the_overseer_on_its_second_consecutive_pass_alone() {
    let lists = [
        "repos/owner/repo/dependabot/alerts?state=open&per_page=100",
        "repos/owner/repo/code-scanning/alerts?state=open&per_page=100",
        "repos/owner/repo/secret-scanning/alerts?state=open&hide_secret=true&per_page=100",
    ];
    let code_list = lists[1];
    let link = "graphql owner=owner name=repo";
    let linked = json!({"body": {"data": {"repository": {"vulnerabilityAlerts": {
        "pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": []}}}}});
    // A web page answered with a success status, as GitHub's edge serves one.
    let page = json!({"text": "<!DOCTYPE html>\n<html><head><title>Unicorn! · GitHub</title></head><body></body></html>\n"});
    let mut world = World::new();
    quiet_github(&mut world);
    let token = plant_token(&world, "ghs_fixture_overseer");
    for list in lists {
        world.gh(list, json!({"body": []}));
    }
    world.gh(link, page.clone());
    let settings = world.settings(&[
        ("ORCH_SECURITY_ALERTS", "on"),
        (
            "ORCH_SECURITY_ALERT_TOKEN_FILE",
            &token.display().to_string(),
        ),
    ]);
    let clock = FakeClock::new();
    let mut body =
        github::body(world.github_context(settings, None, &["owner/repo"], Shared::default()));
    // A planted row for a repository the watch no longer reads.
    let mut baseline = Baseline::default();
    baseline.apply(set(
        "security-alerts-unread",
        "gone/repo/dependabot",
        "http-502",
    ));
    let mut wall = SINCE_EPOCH + 1000;
    let mut next = |body: &mut watch::Body, baseline: &mut Baseline| {
        wall += 240;
        rendered(&pass(body, baseline, &clock, wall).unwrap())
    };
    let unread = |reads: &str| vec![format!("EVENT security-alerts-unread reads={reads}")];
    let none: Vec<String> = Vec::new();
    // One failure that the next pass reads clean reaches no one.
    assert_eq!(next(&mut body, &mut baseline), none, "the first failure");
    assert_eq!(
        baseline.get("security-alerts-unread", "gone/repo/dependabot"),
        None,
        "a source naming no watched repository is swept"
    );
    world.gh(link, linked.clone());
    assert_eq!(next(&mut body, &mut baseline), none, "read clean");
    assert_eq!(
        baseline.identities("security-alerts-unread"),
        Vec::<String>::new(),
        "a clean read clears its source"
    );
    // Two consecutive failures print once, named by what came back.
    world.gh(link, page.clone());
    assert_eq!(next(&mut body, &mut baseline), none);
    assert_eq!(
        next(&mut body, &mut baseline),
        unread("owner/repo/dependabot-prs:invalid-html"),
        "a web page in place of data, on its second pass"
    );
    assert_eq!(next(&mut body, &mut baseline), none, "a third failure");
    // Another source failing beside it is named alone, on its own second
    // pass, by gh's exit status.
    world.gh(code_list, json!({"exit": 7, "stderr": "something else"}));
    assert_eq!(next(&mut body, &mut baseline), none);
    assert_eq!(
        next(&mut body, &mut baseline),
        unread("owner/repo/code-scanning:exit-7")
    );
    // A token refused for one pass judges no repository source: their rows
    // stand, and the standing failures are not named again.
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o640)).unwrap();
    assert_eq!(next(&mut body, &mut baseline), none);
    std::fs::set_permissions(&token, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(next(&mut body, &mut baseline), none);
    // A named failure whose cause changes is not named again; its row
    // holds the latest cause.
    world.gh(link, json!({"exit": 1, "stderr": "gh: HTTP 502"}));
    assert_eq!(next(&mut body, &mut baseline), none);
    assert_eq!(
        baseline.get("security-alerts-unread", "owner/repo/dependabot-prs"),
        Some("http-502|reported")
    );
    // Read clean, then failing with a cause that alternates: the second
    // consecutive failure is named, with its own cause.
    world.gh(link, linked.clone());
    assert_eq!(next(&mut body, &mut baseline), none);
    world.gh(link, json!({"exit": 1, "stderr": "gh: HTTP 502"}));
    assert_eq!(next(&mut body, &mut baseline), none);
    world.gh(link, page);
    assert_eq!(
        next(&mut body, &mut baseline),
        unread("owner/repo/dependabot-prs:invalid-html")
    );
    world.gh(link, linked);
    world.gh(code_list, json!({"body": []}));
    assert_eq!(next(&mut body, &mut baseline), none);
    assert_eq!(
        baseline.identities("security-alerts-unread"),
        Vec::<String>::new()
    );
}

/// The contribution pass, the recorded bytes.
#[test]
fn outside_contributions_are_reported_once_and_a_pull_request_again_on_a_new_head() {
    let head_a = "a".repeat(40);
    let head_b = "b".repeat(40);
    let pull = |number: u64, login: &str, kind: &str, association: &str, head: &str| json!({"number": number, "state": "open", "title": "a contribution", "body": null, "merged_at": null, "merge_commit_sha": null, "user": {"login": login, "type": kind}, "author_association": association, "head": {"sha": head, "ref": "contribution", "repo": null}, "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}});
    let issue = |number: u64, login: &str, kind: &str, association: &str, pr: bool| {
        let mut v = json!({"number": number, "state": "open", "created_at": "2026-08-15T09:00:00Z", "user": {"login": login, "type": kind}, "author_association": association});
        if pr {
            v["pull_request"] = json!({"url": "x"});
        }
        v
    };
    let mut world = World::new();
    quiet_github(&mut world);
    world.gh(
        "repos/owner/repo/pulls?state=open&per_page=100&page=1",
        json!({"body": [
            pull(3100, "fixture-visitor", "User", "CONTRIBUTOR", &head_a),
            pull(3134, "fixture-lanes[bot]", "Bot", "CONTRIBUTOR", &head_a),
            pull(3130, "fixture-admin", "User", "COLLABORATOR", &head_a),
            pull(3126, "private-member", "User", "CONTRIBUTOR", &head_a)
        ]}),
    );
    world.gh(
        "repos/owner/repo/issues?state=open&per_page=100&page=1",
        json!({"body": [
            issue(3100, "fixture-visitor", "User", "CONTRIBUTOR", true),
            issue(3101, "fixture-visitor", "User", "NONE", false),
            issue(3129, "teammate", "User", "MEMBER", false),
            issue(3128, "founder", "User", "OWNER", false),
            issue(3127, "private-member", "User", "CONTRIBUTOR", false),
            {"number": 5, "state": "open", "created_at": "2026-08-15T09:00:00Z", "user": null, "author_association": "NONE"}
        ]}),
    );
    world.gh(
        "repos/owner/repo/collaborators/private-member/permission",
        json!({"body": {"permission": "admin"}}),
    );
    let clock = FakeClock::new();
    let mut body = github::body(world.github_context(
        world.settings(&[]),
        None,
        &["owner/repo"],
        Shared::default(),
    ));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        vec![
            format!(
                "EVENT outside-contribution owner/repo#3100 kind=pr author=fixture-visitor head={head_a}"
            ),
            "EVENT outside-contribution owner/repo#3101 kind=issue author=fixture-visitor"
                .to_owned(),
            "EVENT outside-contribution owner/repo#5 kind=issue author=ghost".to_owned()
        ],
        "an outside pull request, an outside issue and a deleted account's issue are one event each; the fleet prints nothing"
    );
    let permission_reads = |w: &World| {
        w.gh_calls()
            .iter()
            .filter(|c| c.contains("collaborators/"))
            .count()
    };
    // Every author outside by its own fields is asked once per pass: the
    // visitor once for its two items, the private member, the deleted
    // account.
    assert_eq!(
        permission_reads(&world),
        3,
        "one permission read per repository and login: {:?}",
        world.gh_calls()
    );
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(
        rendered(&second),
        Vec::<String>::new(),
        "already reported, same head"
    );
    assert_eq!(
        permission_reads(&world),
        6,
        "the permissions are read again each pass"
    );
    world.gh(
        "repos/owner/repo/pulls?state=open&per_page=100&page=1",
        json!({"body": [pull(3100, "fixture-visitor", "User", "CONTRIBUTOR", &head_b)]}),
    );
    world.gh(
        "repos/owner/repo/issues?state=open&per_page=100&page=1",
        json!({"body": []}),
    );
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    assert_eq!(
        rendered(&third),
        vec![format!(
            "EVENT outside-contribution owner/repo#3100 kind=pr author=fixture-visitor head={head_b}"
        )],
        "a pushed head is reported once more"
    );
    assert_eq!(
        baseline.get("outside-contribution", "owner/repo#3101"),
        None,
        "an item that left the list loses its row"
    );
    // A failed list is a refusal of the pass, never an empty list.
    world.gh(
        "repos/owner/repo/issues?state=open&per_page=100&page=1",
        json!({"exit": 1, "stderr": "gh: Server Error (HTTP 502)"}),
    );
    let err = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap_err();
    assert_eq!(err.key(), "outside-list-failed", "{err}");
    assert!(
        err.fields()
            .contains(&("list".to_owned(), "issues".to_owned())),
        "{:?}",
        err.fields()
    );
    assert_eq!(
        baseline.get("outside-contribution", "owner/repo#3100"),
        Some(format!("pr {head_b}").as_str()),
        "a refused pass moves no row"
    );
}

/// The budget scan, the recorded bytes of the event and the row's raw
/// compact JSON.
#[test]
fn the_budget_scan_reports_a_completed_producer_run_once_and_keeps_its_row_bytes() {
    let suite = "run-all-budget run=202 attempt=2 os=Linux shard=orch-state suite=slow seconds=301 bound=900 review=300 margin-percent=125";
    let job = "run-all-budget run=202 attempt=2 os=Linux shard=orch-state suite=job seconds=333 bound=900 review=300 margin-percent=125";
    let event = format!(
        "EVENT main-push-budget owner/repo workflow=skill-tests.yml run=202 warnings=[\"{job}\",\"{suite}\"]"
    );
    let world_for = |event_name: &str, branch: &str| {
        let mut world = World::new();
        quiet_github(&mut world);
        quiet_main(&mut world);
        world.gh(
            "repos/owner/repo/actions/workflows/skill-tests.yml/runs?per_page=100&page=1",
            json!({"body": {"total_count": 1, "workflow_runs": [{"id": 202, "created_at": "2026-10-18T00:00:00Z", "status": "completed", "head_branch": branch, "event": event_name, "path": ".github/workflows/skill-tests.yml", "head_sha": "0000000000000000000000000000000000000000", "conclusion": "success", "workflow_id": 1, "updated_at": "2026-10-18T00:00:00Z", "repository": {"id": 1296269, "full_name": "owner/repo"}, "head_repository": {"id": 1296269, "full_name": "owner/repo"}, "pull_requests": []}]}}),
        );
        world.gh(
            "repos/owner/repo/actions/runs/202/jobs?per_page=100&page=1",
            json!({"body": {"total_count": 2, "jobs": [
                {"id": 902, "run_id": 202, "name": "a", "head_sha": "0000000000000000000000000000000000000000", "status": "completed", "conclusion": "success", "started_at": "2026-10-18T00:00:00Z", "completed_at": "2026-10-18T00:01:00Z", "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/902"},
                {"id": 903, "run_id": 202, "name": "b", "head_sha": "0000000000000000000000000000000000000000", "status": "completed", "conclusion": "success", "started_at": "2026-10-18T00:00:00Z", "completed_at": "2026-10-18T00:01:00Z", "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/903"}]}}),
        );
        world.gh(
            "repos/owner/repo/check-runs/902/annotations?per_page=100&page=1",
            json!({"body": [{"annotation_level": "warning", "message": suite}, {"annotation_level": "warning", "message": job},
                {"annotation_level": "notice", "message": suite}, {"annotation_level": "warning", "message": "another warning"}]}),
        );
        world.gh(
            "repos/owner/repo/check-runs/903/annotations?per_page=100&page=1",
            json!({"body": [{"annotation_level": "warning", "message": suite}]}),
        );
        world
    };
    let clock = FakeClock::new();
    let evidence_reads = |w: &World| {
        w.gh_calls()
            .iter()
            .filter(|c| c.contains("/actions/runs/202") || c.contains("check-runs/"))
            .count()
    };
    let world = world_for("push", "main");
    let mut body = github::body(world.github_context(
        world.settings(&[]),
        None,
        &["owner/repo"],
        Shared::default(),
    ));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        vec![event.clone()],
        "all producer evidence emits one record"
    );
    assert_eq!(
        baseline.get("main-push-budget", "owner/repo:skill-tests.yml"),
        Some(r#"{"watermark":"2026-10-18T00:00:00Z","seen":[202],"pending":[]}"#),
        "saved state is raw compact JSON"
    );
    assert_eq!(evidence_reads(&world), 3, "{:?}", world.gh_calls());
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(
        rendered(&second),
        Vec::<String>::new(),
        "a consumed run makes no evidence read"
    );
    assert_eq!(evidence_reads(&world), 3);
    assert_eq!(
        baseline.get("main-push-budget", "owner/repo:skill-tests.yml"),
        Some(r#"{"watermark":"2026-10-18T00:00:00Z","seen":[202],"pending":[]}"#)
    );
    // A null status, which GitHub documents, is a run not yet judged: it
    // reads as unfinished, no record and no evidence read.
    let mut world = world_for("push", "main");
    world.gh(
        "repos/owner/repo/actions/workflows/skill-tests.yml/runs?per_page=100&page=1",
        json!({"body": {"total_count": 1, "workflow_runs": [{"id": 202, "created_at": "2026-10-18T00:00:00Z", "status": null, "head_branch": "main", "event": "push", "path": ".github/workflows/skill-tests.yml", "head_sha": "0000000000000000000000000000000000000000", "conclusion": null, "workflow_id": 1, "updated_at": "2026-10-18T00:00:00Z", "repository": {"id": 1296269, "full_name": "owner/repo"}, "head_repository": {"id": 1296269, "full_name": "owner/repo"}, "pull_requests": []}]}}),
    );
    let mut body = github::body(world.github_context(
        world.settings(&[]),
        None,
        &["owner/repo"],
        Shared::default(),
    ));
    let mut baseline = Baseline::default();
    let unfinished = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&unfinished),
        Vec::<String>::new(),
        "a null status is no completed run: {:?}",
        baseline.get("main-push-budget", "owner/repo:skill-tests.yml")
    );
    assert_eq!(evidence_reads(&world), 0, "{:?}", world.gh_calls());
    assert_eq!(
        baseline.get("main-push-budget", "owner/repo:skill-tests.yml"),
        Some(r#"{"watermark":"2026-10-18T00:00:00Z","seen":[202],"pending":[202]}"#),
        "the unfinished producer run stays pending"
    );
    for (event_name, branch) in [
        (
            "merge_group",
            "gh-readonly-queue/main/pr-5421-c7012cfbf29daef1a5bc63c0ccf179f23a859bc1",
        ),
        ("schedule", "main"),
        ("workflow_dispatch", "main"),
    ] {
        let world = world_for(event_name, branch);
        let mut body = github::body(world.github_context(
            world.settings(&[]),
            None,
            &["owner/repo"],
            Shared::default(),
        ));
        let mut baseline = Baseline::default();
        let produced = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
        assert_eq!(
            rendered(&produced),
            vec![event.clone()],
            "{event_name} {branch} selects"
        );
    }
    for (event_name, branch) in [
        ("workflow_dispatch", "feature"),
        ("merge_group", "gh-readonly-queue/release/pr-7-abc"),
        ("pull_request", "main"),
    ] {
        let world = world_for(event_name, branch);
        let mut body = github::body(world.github_context(
            world.settings(&[]),
            None,
            &["owner/repo"],
            Shared::default(),
        ));
        let mut baseline = Baseline::default();
        let produced = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
        assert_eq!(
            rendered(&produced),
            Vec::<String>::new(),
            "{event_name} {branch} is no producer"
        );
        assert_eq!(
            evidence_reads(&world),
            0,
            "{event_name} {branch}: no evidence read"
        );
    }
}

/// Each pass reports every push run on main that finished red since the
/// last pass, once, oldest first: a red run behind a green one, and a run
/// that was unfinished at the last pass and finished red behind a newer
/// green one, whose creation time the mark kept as the next search's
/// floor. Each names its head and the head of the last green run before it,
/// which the mark keeps across passes. The first pass, with no mark, judges
/// only the standing run. A failed read refuses the pass and moves no mark.
#[test]
fn every_red_push_run_since_the_last_pass_is_reported_once() {
    let (t1, t2, t3, t4) = (
        "2026-10-18T01:00:00Z",
        "2026-10-18T02:00:00Z",
        "2026-10-18T03:00:00Z",
        "2026-10-18T04:00:00Z",
    );
    let mut world = push_world();
    plant_runs(
        &mut world,
        &push_path(None),
        vec![
            push_run(502, t2, "completed", Some("success")),
            push_run(501, t1, "in_progress", None),
            push_run(500, "2026-10-18T00:00:00Z", "completed", Some("success")),
            push_run(499, "2026-10-17T23:00:00Z", "completed", Some("failure")),
        ],
    );
    let clock = FakeClock::new();
    let mut body = github::body(world.github_context(
        world.settings(&[]),
        None,
        &["owner/repo"],
        Shared::default(),
    ));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        Vec::<String>::new(),
        "with no mark only the standing run is judged"
    );
    assert_eq!(
        baseline.get("main-push-failing", "owner/repo:skill-tests.yml"),
        Some(push_mark(t1, "[[502,1]]", "null", Some(500)).as_str()),
        "the unfinished run holds the floor, the last green run before it the range's start"
    );
    plant_runs(
        &mut world,
        &push_path(Some(t1)),
        vec![
            push_run(504, t4, "completed", Some("success")),
            push_run(503, t3, "completed", Some("failure")),
            push_run(502, t2, "completed", Some("success")),
            push_run(501, t1, "completed", Some("failure")),
        ],
    );
    plant_red_jobs(&mut world, 501);
    plant_red_jobs(&mut world, 503);
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2000).unwrap();
    assert_eq!(
        rendered(&second),
        vec![red_line(501, Some(500)), red_line(503, Some(502))],
        "each red run's range starts at the last green run before it, the mark's before the floor"
    );
    assert_eq!(
        baseline.get("main-push-failing", "owner/repo:skill-tests.yml"),
        Some(push_mark(t4, "[[504,1]]", "null", Some(502)).as_str()),
        "the newest green run stands"
    );
    let jobs_reads = |w: &World| {
        w.gh_calls()
            .iter()
            .filter(|c| c.contains("/jobs"))
            .cloned()
            .collect::<Vec<_>>()
    };
    assert_eq!(
        jobs_reads(&world),
        [
            "api repos/owner/repo/actions/runs/501/jobs?per_page=100&page=1",
            "api repos/owner/repo/actions/jobs/5010/logs --allow-escape-sequences",
            "api repos/owner/repo/actions/runs/503/jobs?per_page=100&page=1",
            "api repos/owner/repo/actions/jobs/5030/logs --allow-escape-sequences",
        ],
        "a green run's jobs are never read"
    );
    world.gh(
        &push_path(Some(t4)),
        json!({"exit": 1, "stderr": "gh: Server Error (HTTP 502)"}),
    );
    let before = baseline.clone();
    let err = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 3000).unwrap_err();
    assert_eq!(err.key(), "github-read-failed", "{err}");
    assert_eq!(baseline, before, "a failed read moves no mark");
    let t5 = "2026-10-18T05:00:00Z";
    plant_runs(
        &mut world,
        &push_path(Some(t4)),
        vec![
            push_run(505, t5, "completed", Some("failure")),
            push_run(504, t4, "completed", Some("success")),
        ],
    );
    plant_red_jobs(&mut world, 505);
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 4000).unwrap();
    assert_eq!(rendered(&third), vec![red_line(505, Some(504))]);
    let red = push_mark(
        t5,
        "[[505,1]]",
        r#"{"run":505,"attempt":1,"jobs":["tests"]}"#,
        Some(504),
    );
    let red = red.as_str();
    assert_eq!(
        baseline.get("main-push-failing", "owner/repo:skill-tests.yml"),
        Some(red)
    );
    plant_runs(
        &mut world,
        &push_path(Some(t5)),
        vec![push_run(505, t5, "completed", Some("failure"))],
    );
    let fourth = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 5000).unwrap();
    assert_eq!(
        rendered(&fourth),
        Vec::<String>::new(),
        "a reported run is not reported again"
    );
    assert_eq!(
        baseline.get("main-push-failing", "owner/repo:skill-tests.yml"),
        Some(red)
    );
    assert_eq!(jobs_reads(&world).len(), 6, "{:?}", jobs_reads(&world));
}

/// A completed run of the refresh workflow in GitHub's documented shape.
fn refresh_run(id: u64, created_at: &str, conclusion: &str) -> Value {
    json!({"id": id, "run_attempt": 1, "created_at": created_at, "updated_at": created_at,
        "status": "completed", "conclusion": conclusion, "event": "schedule", "head_branch": "main",
        "path": ".github/workflows/kendex-refresh.yml", "head_sha": push_head(id),
        "workflow_id": 2, "repository": {"id": 1296269, "full_name": "owner/repo"},
        "head_repository": {"id": 1296269, "full_name": "owner/repo"}, "pull_requests": []})
}

/// One job log the duty cannot read as GitHub sent it is one unread item,
/// never the pass's failure. A log carrying its producer's colour and title
/// sequences, which gh refuses to print without its raw-output option, is
/// read with every control dropped; a log gh fails to answer, or answers
/// 404, leaves the refresh incident's cause `unread`, as no cause is judged
/// over a part of the run's failed jobs. In each the pass's merged line
/// prints beside the refresh line.
#[test]
fn an_unreadable_job_log_is_one_unread_item_and_the_pass_goes_on() {
    let escaped = json!({"text": "2026-10-18T00:00:00.0000000Z \u{1b}[31;1mError: refresh\u{1b}[0m \u{9b}blocked\u{7}\r\n2026-10-18T00:00:01.0000000Z \u{1b}]0;title\u{7}done\n"});
    let readable = json!({"text": "2026-10-18T00:00:00.0000000Z Error: refresh blocked\n"});
    let failed = json!({"exit": 1, "stderr": "gh: Server Error (HTTP 502)"});
    let rows: [(&str, Vec<Option<Value>>, &str); 3] = [
        (
            "colour sequences",
            vec![Some(escaped)],
            "Error: refresh blocked",
        ),
        (
            "a failed read",
            vec![Some(readable.clone()), Some(failed)],
            "unread",
        ),
        ("a 404", vec![Some(readable), None], "unread"),
    ];
    let (t1, t2) = ("2026-10-18T01:00:00Z", "2026-10-18T02:00:00Z");
    for (case, logs, cause) in rows {
        let mut world = World::new();
        world.write_fleet(&json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [],
            "lanes": [{"item": "KEN-1", "tracker": "linear", "harness": "claude", "window": null, "host": null, "mail_root": "/w/KEN-1", "launched_at": "2026-09-20T00:00:00Z", "status": "stopped"}]}));
        world.linear("statuses list", statuses());
        world.linear("issues list", json!({"body": []}));
        world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [{"identifier": "KEN-1", "state": {"type": "started"}, "description": "", "children": {"nodes": []}}]}}}));
        quiet_github(&mut world);
        world.gh(
            "repos/owner/repo/pulls?state=closed&head=owner%3Aken-1&per_page=100&page=1",
            json!({ "body": [merged_pull(1, "ken-1")] }),
        );
        world.gh(
            "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20%22KEN-1%22%20in%3Atitle%2Cbody%20merged%3A%3E%3D2026-08-15T09%3A00%3A00Z&per_page=100&page=1",
            json!({"body": {"total_count": 0, "incomplete_results": false, "items": []}}),
        );
        let runs = vec![
            refresh_run(701, t2, "failure"),
            refresh_run(700, t1, "failure"),
        ];
        plant_runs(
            &mut world,
            "repos/owner/repo/actions/workflows/kendex-refresh.yml/runs?status=completed&per_page=2",
            runs.clone(),
        );
        plant_runs(
            &mut world,
            "repos/owner/repo/actions/workflows/kendex-refresh.yml/runs?per_page=20",
            runs,
        );
        let jobs: Vec<Value> = (0..logs.len() as u64)
            .map(|i| json!({"id": 7010 + i, "run_id": 701, "name": format!("refresh-{i}"),
                "head_sha": push_head(701), "status": "completed", "conclusion": "failure",
                "started_at": t2, "completed_at": t2,
                "check_run_url": format!("https://api.github.com/repos/owner/repo/check-runs/{}", 7010 + i)}))
            .collect();
        world.gh(
            "repos/owner/repo/actions/runs/701/jobs?per_page=100&page=1",
            json!({"body": {"total_count": jobs.len(), "jobs": jobs}}),
        );
        for (i, log) in logs.into_iter().enumerate() {
            if let Some(log) = log {
                world.gh(
                    &format!("repos/owner/repo/actions/jobs/{}/logs", 7010 + i),
                    log,
                );
            }
        }
        let clock = FakeClock::new();
        let mut body = github::body(world.github_context(
            world.settings(&[]),
            Some(SINCE),
            &["owner/repo"],
            Shared::default(),
        ));
        let mut baseline = Baseline::default();
        let said = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000)
            .unwrap_or_else(|e| panic!("{case}: {e}"));
        assert_eq!(
            rendered(&said),
            vec![
                "EVENT merged 1 ken-1 owner/repo".to_owned(),
                format!(
                    "EVENT refresh-failing owner/repo runs=2 last=701 since={t1} report=initial cause={cause}"
                ),
            ],
            "{case}"
        );
    }
}

/// A cancelled run decides nothing when the watch picks the run that
/// stands: on the first pass the red run behind a cancelled newest one is
/// reported and stands red; a later pass whose only run is cancelled keeps
/// it; a red run behind a cancelled one since the last pass is reported.
#[test]
fn a_cancelled_push_run_is_skipped_when_the_standing_run_is_picked() {
    let (t1, t2, t3, t4) = (
        "2026-10-18T01:00:00Z",
        "2026-10-18T02:00:00Z",
        "2026-10-18T03:00:00Z",
        "2026-10-18T04:00:00Z",
    );
    let mut world = push_world();
    plant_runs(
        &mut world,
        &push_path(None),
        vec![
            push_run(302, t2, "completed", Some("cancelled")),
            push_run(301, t1, "completed", Some("failure")),
        ],
    );
    plant_red_jobs(&mut world, 301);
    let clock = FakeClock::new();
    let shared = Shared::default();
    let mut body = github::body(world.github_context(
        world.settings(&[]),
        None,
        &["owner/repo"],
        shared.clone(),
    ));
    let mut baseline = Baseline::default();
    let first = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        vec![red_line(301, None)],
        "a red run with no green run read before it names no range start"
    );
    let red = push_mark(
        t2,
        "[[302,1]]",
        r#"{"run":301,"attempt":1,"jobs":["tests"]}"#,
        None,
    );
    let red = red.as_str();
    assert_eq!(
        baseline.get("main-push-failing", "owner/repo:skill-tests.yml"),
        Some(red)
    );
    let standing = |shared: &Shared| {
        shared
            .lock()
            .unwrap()
            .github
            .as_ref()
            .map(|g| g.main_failing.clone())
    };
    let tests = BTreeMap::from([(
        "owner/repo:skill-tests.yml".to_owned(),
        r#"["tests"]"#.to_owned(),
    )]);
    assert_eq!(standing(&shared), Some(tests.clone()));
    plant_runs(
        &mut world,
        &push_path(Some(t2)),
        vec![push_run(302, t2, "completed", Some("cancelled"))],
    );
    let second = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2000).unwrap();
    assert_eq!(rendered(&second), Vec::<String>::new());
    assert_eq!(
        baseline.get("main-push-failing", "owner/repo:skill-tests.yml"),
        Some(red),
        "a cancelled run leaves the red run standing"
    );
    assert_eq!(standing(&shared), Some(tests));
    plant_runs(
        &mut world,
        &push_path(Some(t2)),
        vec![
            push_run(304, t4, "completed", Some("cancelled")),
            push_run(303, t3, "completed", Some("failure")),
            push_run(302, t2, "completed", Some("cancelled")),
        ],
    );
    plant_red_jobs(&mut world, 303);
    let third = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 3000).unwrap();
    assert_eq!(rendered(&third), vec![red_line(303, None)]);
    assert_eq!(
        baseline.get("main-push-failing", "owner/repo:skill-tests.yml"),
        Some(
            push_mark(
                t4,
                "[[304,1]]",
                r#"{"run":303,"attempt":1,"jobs":["tests"]}"#,
                None
            )
            .as_str()
        )
    );
}

/// A marked search that reaches GitHub's bound on a filtered run search
/// may leave runs unread: it refuses, never reads as the whole set.
#[test]
fn a_push_search_at_githubs_bound_is_refused() {
    let floor = "2026-10-18T00:00:00Z";
    let mut world = push_world();
    plant_runs(
        &mut world,
        &push_path(None),
        vec![push_run(1, floor, "completed", Some("success"))],
    );
    let base = "repos/owner/repo/actions/workflows/skill-tests.yml/runs?branch=main&event=push&created=%3E%3D2026-10-18T00:00:00Z";
    for page in 0..10_u64 {
        let runs: Vec<Value> = (0..100)
            .map(|i| push_run(1 + page * 100 + i, floor, "completed", Some("success")))
            .collect();
        world.gh(
            &format!("{base}&per_page=100&page={}", page + 1),
            json!({"body": {"total_count": 1000, "workflow_runs": runs}}),
        );
    }
    let clock = FakeClock::new();
    let mut body = github::body(world.github_context(
        world.settings(&[]),
        None,
        &["owner/repo"],
        Shared::default(),
    ));
    let mut baseline = Baseline::default();
    pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    let before = baseline.clone();
    let err = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 2000).unwrap_err();
    assert_eq!(err.key(), "github-capped", "{err}");
    assert_eq!(baseline, before);
}

/// The GitHub duty's refusal leaves the tracker's pass standing, each
/// lane's end read on its own. Through the runner with both duties: every
/// gh read fails, the tracker's triage lines land, the Linear lane whose
/// merges the failed read could not name stays stopped with its close held
/// (its landing unrecorded), the GitHub lane stays stopped with no verdict,
/// the tracker's partial failure is one counted line after its news, and
/// the GitHub duty's failure line names `step=github`.
#[test]
fn a_github_refusal_leaves_the_trackers_triage_line_and_close_intact() {
    let mut world = World::new();
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": triage_items()}));
    world.linear("issues bulk-get", json!({"body": {"issues": {"nodes": [
        {"identifier": "KEN-1", "state": {"type": "completed"}, "description": "## Done when\n- [x] Done\n  Evidence: yes\n", "children": {"nodes": []}},
        {"identifier": "KEN-2", "state": {"type": "started"}, "children": {"nodes": []}},
        {"identifier": "KEN-3", "state": {"type": "unstarted"}, "children": {"nodes": []}},
        {"identifier": "KEN-4", "state": {"type": "backlog"}, "children": {"nodes": []}},
        {"identifier": "KEN-5", "state": {"type": "unstarted"}, "children": {"nodes": []}}
    ]}}}));
    world.linear(
        "comments bulk-list",
        comments(&["KEN-1", "KEN-2", "KEN-4"], &[]),
    );
    // KEN-3 kept, as in the recorded triage world, so the comment batch is
    // read for the three candidates alone.
    world.write_fleet(&json!({"issue_id": "oversee", "triaged": [{"issue": "KEN-3", "verdict": "kept"}], "launch_queue": [], "fleet_log": [],
        "lanes": [{"item": "KEN-1", "tracker": "linear", "repo": "owner/repo", "harness": "codex", "window": null, "host": null,
            "mail_root": "/srv/lane/x", "status": "stopped", "session_since": "2026-10-09T00:00:00Z"},
            {"item": "issue-7", "tracker": "github", "repo": "owner/repo", "harness": "claude", "window": null, "host": null,
            "mail_root": "/srv/lane/y", "status": "stopped", "session_since": "2026-10-09T00:00:00Z"}]}));
    // No gh reply at all: every GitHub read is a 404 the workflow list
    // cannot prove absent, the merged index's head list and the GitHub
    // lane's issue among them.
    let settings = world.settings(&[]);
    let clock = FakeClock::new();
    let paths = Paths::of(&world.fleet_path()).unwrap();
    let identity = me();
    let mut runner = Runner::new(
        paths.clone(),
        &clock,
        &settings,
        Flags {
            interval: secs(240),
            max_loops: 25,
            since: Some(SINCE.into()),
            repos: Vec::new(),
            fresh: false,
        },
        identity.clone(),
        Recorded {
            pane: "none".into(),
            script: "/w/orch-runtime".into(),
            cwd: "/w".into(),
        },
    )
    .unwrap();
    let ctx = world.context(settings.clone(), Some(SINCE));
    let shared = ctx.shared.clone();
    runner.register(Duty::Tracker, tracker::body(ctx));
    runner.register(
        Duty::GitHub,
        github::body(world.github_context(settings, Some(SINCE), &["owner/repo"], shared.clone())),
    );
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
    });
    assert!(ended.is_ok(), "{ended:?}");
    let log = lines(&paths.log);
    assert_eq!(
        log,
        vec![
            "EVENT triage KEN-1",
            "EVENT triage KEN-2",
            "EVENT triage KEN-4",
            "EVENT watch-step-failed step=tracker count=1",
            "EVENT watch-step-failed step=github count=1"
        ],
        "the tracker's news stands; each refusal is its own counted line"
    );
    let latest = shared.lock().unwrap();
    assert!(
        latest.tracker.is_some(),
        "the tracker's inventory handed over"
    );
    assert!(
        latest.github.is_none(),
        "no GitHub inventory from a refused pass"
    );
    assert_eq!(
        latest.terminal.get("KEN-1"),
        Some(&TerminalState::Completed)
    );
    assert_eq!(
        latest.terminal.get("issue-7"),
        None,
        "a refused read is no verdict"
    );
    let status_of = |item: &str| {
        world.fleet()["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .map(|l| l["status"].clone())
    };
    assert_eq!(
        status_of("issue-7"),
        Some(json!("stopped")),
        "no close for the unread item"
    );
    assert_eq!(
        status_of("KEN-1"),
        Some(json!("stopped")),
        "a landing the merged read could not name holds the Linear lane's close"
    );
}

/// The tracker body reads the item with its blocker, the verification body
/// judges the slot it left: the box is `blocked` and names the blocker,
/// with no deadline event, past its deadline too; once the blocker closes
/// the box is due or overdue and the event fires. The first lines and event
/// are the recorded watch's bytes on the suite's own world.
#[test]
fn an_open_blocker_read_by_the_tracker_holds_the_verifying_box_blocked_until_it_closes() {
    const NOW: u64 = 1_790_899_201; // 2026-10-02T00:00:01Z, `verifying_one`'s clock
    const BOX: &str = "## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: 2026-10-01T12:00:00Z; Deadline: 2026-10-03T00:00:00Z";
    let recorded = |name: &str| lines(&fixtures().join("released-recorded").join(name));
    let mut world = World::new();
    world.linear("statuses list", statuses());
    let verifying_item = |blockers: &[&str]| {
        let mut item = item(
            "KEN-1",
            "2026-09-20T00:00:00Z",
            "Verifying",
            "started",
            json!(1),
            blockers,
        );
        item["description"] = json!(BOX);
        json!({"body": [item]})
    };
    world.linear("issues list", verifying_item(&["KEN-99"]));
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-1", "state": {"type": "started"}, "children": {"nodes": []}}
        ]}}}),
    );
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let ctx = world.context(settings.clone(), None);
    let shared = ctx.shared.clone();
    let mut tracker = tracker::body(ctx);
    let lines_slot = verifying::Lines::default();
    let mut verification = verifying::body(verifying::Context {
        settings,
        gh: world.dir.path().join("gh"),
        shared: shared.clone(),
        lines: lines_slot.clone(),
    });
    let mut baseline = Baseline::default();
    pass(&mut tracker, &mut baseline, &clock, NOW).unwrap();
    assert_eq!(
        shared.lock().unwrap().tracker.as_ref().unwrap().verifying[0].blocked_by_open,
        vec!["KEN-99".to_owned()],
        "the tracker hands the blockers over"
    );
    let produced = pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW,
    )
    .unwrap();
    assert_eq!(
        *lines_slot.lock().unwrap(),
        recorded("verifying-blocked.lines"),
        "a blocked box is the released watch's blocked line"
    );
    assert_eq!(
        rendered(&produced),
        Vec::<String>::new(),
        "a blocker holds due attention"
    );
    assert_eq!(baseline.get("verifying-deadline", "KEN-1"), Some("-"));
    // The blocker closes: the next tracker read carries none, and the box
    // is due, said once.
    world.linear("issues list", verifying_item(&[]));
    pass(&mut tracker, &mut baseline, &clock, NOW).unwrap();
    let produced = pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW,
    )
    .unwrap();
    assert_eq!(
        *lines_slot.lock().unwrap(),
        recorded("verifying-unblocked.lines")
    );
    let mut want = recorded("verifying-unblocked.events");
    want.extend(recorded("verifying-unblocked.lines"));
    assert_eq!(
        rendered(&produced),
        want,
        "closing a blocker raises due attention"
    );
    // Past its deadline the open blocker still holds the box: blocked, no
    // event; once the blocker closes the box is overdue, said once.
    const PAST: &str = "## Done when\n- [ ] Post-merge: Read health; Where: service; Why after merge: live release; Trigger: 2026-10-01T12:00:00Z; Deadline: 2026-10-01T23:00:00Z";
    let past_item = |blockers: &[&str]| {
        let mut body = verifying_item(blockers);
        body["body"][0]["description"] = json!(PAST);
        body
    };
    world.linear("issues list", past_item(&["KEN-99"]));
    pass(&mut tracker, &mut baseline, &clock, NOW).unwrap();
    let produced = pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW,
    )
    .unwrap();
    assert_eq!(
        *lines_slot.lock().unwrap(),
        vec![
            "verifying KEN-1 box=1 trigger=\"2026-10-01T12:00:00Z\" status=blocked deadline=2026-10-01T23:00:00Z blocked_by=KEN-99 reading=\"Read health\" where=\"service\" why=\"live release\""
        ],
        "an open blocker holds a box past its deadline"
    );
    assert_eq!(rendered(&produced), Vec::<String>::new());
    assert_eq!(baseline.get("verifying-deadline", "KEN-1"), Some("-"));
    world.linear("issues list", past_item(&[]));
    pass(&mut tracker, &mut baseline, &clock, NOW).unwrap();
    let produced = pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW,
    )
    .unwrap();
    let overdue = "verifying KEN-1 box=1 trigger=\"2026-10-01T12:00:00Z\" status=overdue deadline=2026-10-01T23:00:00Z blocked_by=- reading=\"Read health\" where=\"service\" why=\"live release\" read=unread cause=no-reader";
    assert_eq!(*lines_slot.lock().unwrap(), vec![overdue]);
    assert_eq!(
        rendered(&produced),
        vec![
            "EVENT verifying-deadline KEN-1 box=1 trigger=\"2026-10-01T12:00:00Z\" status=overdue deadline=2026-10-01T23:00:00Z read=unread",
            overdue
        ],
        "the closed blocker's past deadline is said once"
    );
}

#[test]
fn a_failed_verification_read_neither_repeats_nor_forgets_a_told_box() {
    const PATH: &str = "repos/owner/repo/actions/jobs/77";
    const DEADLINE: &str = "2026-10-03T00:00:00Z";
    let deadline = agent_runtime::clock::epoch_secs(DEADLINE).unwrap();
    let mut world = World::new();
    world.linear("comments create", json!({"body": {"success": true}}));
    let shared = Shared::default();
    shared.lock().unwrap().tracker = Some(tracker::TrackerInventory {
        read_at: deadline - 60,
        owed: Vec::new(),
        verifying: vec![tracker::VerifyingItem {
            id: "KEN-1".to_owned(),
            created_at: "2026-10-01T00:00:00Z".to_owned(),
            description: format!(
                "## Done when\n- [ ] Post-merge: job time <= 600 s; Where: https://github.com/owner/repo/actions/runs/5/job/77; Why after merge: runs on main; Deadline: {DEADLINE}"
            ),
            priority: "-".to_owned(),
            container: false,
            blocked_by_open: Vec::new(),
        }],
        open_unblocked: Vec::new(),
        open: Default::default(),
    });
    let job = json!({"body": {"id": 77, "run_id": 5, "name": "perf",
        "head_sha": "0000000000000000000000000000000000000000", "status": "completed",
        "conclusion": "success", "started_at": "2026-10-01T10:00:00Z",
        "completed_at": "2026-10-01T10:15:00Z",
        "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/77"}});
    let unread = json!({"exit": 1, "stderr": "HTTP 500"});
    let gh = world.dir.path().join("gh");
    let context = |settings| verifying::Context {
        settings,
        gh: gh.clone(),
        shared: shared.clone(),
        lines: verifying::Lines::default(),
    };
    let mut body = verifying::body(context(world.settings(&[])));
    let mut baseline = Baseline::default();
    let clock = FakeClock::new();
    for (wall, answer, event_count) in [
        (deadline - 60, &job, 1),
        (deadline - 50, &unread, 0),
        (deadline - 40, &job, 0),
        (deadline, &unread, 0),
        (deadline + 10, &job, 1),
    ] {
        world.gh(PATH, answer.clone());
        let produced = pass_as(Duty::Verification, &mut body, &mut baseline, &clock, wall).unwrap();
        assert_eq!(
            produced
                .events
                .iter()
                .filter(|event| matches!(event, Event::VerifyingDeadline { .. }))
                .count(),
            event_count,
            "deadline events at {wall}: {:?}",
            rendered(&produced)
        );
        assert_eq!(
            world
                .linear_calls()
                .iter()
                .filter(|call| call.starts_with("comments create KEN-1 --body-file "))
                .count(),
            1,
            "ruling comments at {wall}"
        );
    }
    let parser_tools = world.dir.path().join("parser-tools");
    std::fs::create_dir(&parser_tools).unwrap();
    write_executable(&parser_tools.join("jq"), "#!/bin/sh\nexit 127\n");
    let cli = world.dir.path().join("linear-with-unread-parser");
    write_executable(
        &cli,
        format!(
            "#!/bin/sh\nPATH='{}':\"$PATH\" exec '{}' \"$@\"\n",
            parser_tools.display(),
            world.dir.path().join("linear").display(),
        ),
    );
    let mut unread_parser = verifying::body(context(
        world.settings(&[("OVERSEE_WATCH_TRACKER", cli.to_str().unwrap())]),
    ));
    let before = baseline
        .get(verifying::DEADLINE_ROW, "KEN-1")
        .unwrap()
        .to_owned();
    let produced = pass_as(
        Duty::Verification,
        &mut unread_parser,
        &mut baseline,
        &clock,
        deadline + 20,
    )
    .unwrap();
    assert!(produced.events.is_empty());
    assert_eq!(
        baseline.get(verifying::DEADLINE_ROW, "KEN-1"),
        Some(before.as_str())
    );
    let recovered = pass_as(
        Duty::Verification,
        &mut body,
        &mut baseline,
        &clock,
        deadline + 30,
    )
    .unwrap();
    assert!(recovered.events.is_empty());
    assert_eq!(
        world
            .linear_calls()
            .iter()
            .filter(|call| call.starts_with("comments create KEN-1 --body-file "))
            .count(),
        1,
    );
}

/// A due check whose `Where:` is a GitHub job is read through that job's
/// elapsed seconds and its reading kept in the line and the row key: only
/// a met reading completes the box, once, through the tracker CLI; a failed
/// or inconclusive one takes one comment; a job still running reads
/// missing; a failed read changes only the heartbeat. A check with no
/// comparator reads unread with no GitHub call. Repeating the same answers
/// writes nothing more.
#[test]
fn a_due_check_is_read_through_its_job_and_only_a_met_reading_completes_its_box() {
    const NOW: u64 = 1_790_899_201;
    const JOB: &str = "https://github.com/owner/repo/actions/runs/5/job/77";
    let numeric = format!(
        "## Done when\n- [ ] Post-merge: job time <= 600 s; Where: {JOB}; Why after merge: runs on main; Deadline: 2026-10-03T00:00:00Z"
    );
    let outcome = format!(
        "## Done when\n- [ ] Post-merge: job finishes; Where: {JOB}; Why after merge: runs on main; Deadline: 2026-10-03T00:00:00Z"
    );
    let job = |status: &str, conclusion: Value, completed: Value| {
        json!({"body": {"id": 77, "run_id": 5, "name": "perf",
            "head_sha": "0000000000000000000000000000000000000000", "status": status,
            "conclusion": conclusion, "started_at": "2026-10-01T10:00:00Z", "completed_at": completed,
            "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/77"}})
    };
    /// (description, the job's answer, the line's reading, completions,
    /// the comment's Result field where one is owed, job reads)
    type Row<'a> = (
        &'a str,
        Option<Value>,
        &'a str,
        usize,
        Option<&'a str>,
        usize,
    );
    let rows: Vec<Row> = vec![
        (
            numeric.as_str(),
            Some(job(
                "completed",
                json!("success"),
                json!("2026-10-01T10:06:52Z"),
            )),
            " read=met observed=412",
            1,
            None,
            1,
        ),
        (
            numeric.as_str(),
            Some(job(
                "completed",
                json!("success"),
                json!("2026-10-01T10:15:00Z"),
            )),
            " read=failed observed=900",
            0,
            Some("fail"),
            1,
        ),
        (
            numeric.as_str(),
            Some(job("in_progress", Value::Null, Value::Null)),
            " read=missing",
            0,
            None,
            1,
        ),
        (
            numeric.as_str(),
            Some(job(
                "completed",
                json!("cancelled"),
                json!("2026-10-01T10:01:00Z"),
            )),
            " read=inconclusive cause=cancelled",
            0,
            Some("unread"),
            1,
        ),
        (
            numeric.as_str(),
            None,
            " read=unread cause=read-failed",
            0,
            None,
            1,
        ),
        (
            outcome.as_str(),
            None,
            " read=unread cause=no-reader",
            0,
            None,
            0,
        ),
    ];
    for (description, answer, reading, completions, result, reads) in rows {
        let mut world = World::new();
        world.linear("statuses list", statuses());
        let mut verifying_item = item(
            "KEN-1",
            "2026-09-20T00:00:00Z",
            "Verifying",
            "started",
            json!(1),
            &[],
        );
        verifying_item["description"] = json!(description);
        world.linear("issues list", json!({"body": [verifying_item]}));
        world.linear(
            "issues bulk-get",
            json!({"body": {"issues": {"nodes": [
                {"identifier": "KEN-1", "state": {"type": "started"}, "children": {"nodes": []}}
            ]}}}),
        );
        world.linear("issues complete", json!({"body": {"success": true}}));
        world.linear("comments create", json!({"body": {"success": true}}));
        if let Some(answer) = answer {
            world.gh("repos/owner/repo/actions/jobs/77", answer);
        }
        let clock = FakeClock::new();
        let settings = world.settings(&[]);
        let ctx = world.context(settings.clone(), None);
        let shared = ctx.shared.clone();
        let mut tracker = tracker::body(ctx);
        let lines_slot = verifying::Lines::default();
        let mut verification = verifying::body(verifying::Context {
            settings,
            gh: world.dir.path().join("gh"),
            shared,
            lines: lines_slot.clone(),
        });
        let mut baseline = Baseline::default();
        let kind = reading.split(' ').nth(1).unwrap_or_default();
        let line = format!(
            "verifying KEN-1 box=1 trigger=\"merge\" status=due deadline=2026-10-03T00:00:00Z blocked_by=- reading={} where=\"{JOB}\" why=\"runs on main\"{reading}",
            if description == numeric {
                "\"job time <= 600 s\""
            } else {
                "\"job finishes\""
            }
        );
        let event = format!(
            "EVENT verifying-deadline KEN-1 box=1 trigger=\"merge\" status=due deadline=2026-10-03T00:00:00Z {kind}"
        );
        for round in [1, 2] {
            pass(&mut tracker, &mut baseline, &clock, NOW).unwrap();
            let produced = pass_as(
                Duty::Verification,
                &mut verification,
                &mut baseline,
                &clock,
                NOW,
            )
            .unwrap();
            assert_eq!(*lines_slot.lock().unwrap(), vec![line.clone()], "{reading}");
            let want = if round == 1 && reading != " read=unread cause=read-failed" {
                vec![event.clone(), line.clone()]
            } else {
                Vec::new()
            };
            assert_eq!(rendered(&produced), want, "{reading} round {round}");
        }
        let calls = world.linear_calls();
        let completed: Vec<&String> = calls
            .iter()
            .filter(|c| c.starts_with("issues complete"))
            .collect();
        assert_eq!(completed.len(), completions, "{reading}: {calls:?}");
        for call in completed {
            assert!(
                call.starts_with("issues complete KEN-1 --done-when-met 1 --evidence-file ")
                    && call.ends_with("/evidence"),
                "{call}"
            );
        }
        assert_eq!(
            calls
                .iter()
                .filter(|c| c.starts_with("comments create KEN-1 --body-file "))
                .count(),
            usize::from(result.is_some()),
            "{reading}: {calls:?}"
        );
        // The one comment opens with its result for the person, then
        // records the reading under its box, the watch's marker kept.
        let posted = world.posted_comments();
        let read: Vec<_> = posted
            .iter()
            .map(|(issue, parent, body)| {
                let fields = record_fields(body);
                (
                    issue.as_str(),
                    parent.as_str(),
                    opens_with_prose(body),
                    body.lines().filter(|l| l.starts_with("### Box ")).count(),
                    body.lines().any(|l| l == "### Box 1"),
                    fields.get("Result").cloned(),
                    fields.get("Observed at").cloned(),
                    body.lines().any(|l| l == "read-by=watch"),
                )
            })
            .collect();
        let want: Vec<_> = result
            .iter()
            .map(|result| {
                (
                    "KEN-1",
                    "",
                    true,
                    1,
                    true,
                    Some((*result).to_owned()),
                    Some("2026-10-02T00:00:01Z".to_owned()),
                    true,
                )
            })
            .collect();
        assert_eq!(read, want, "{reading}: {posted:?}");
        assert_eq!(
            world
                .gh_calls()
                .iter()
                .filter(|c| *c == "api repos/owner/repo/actions/jobs/77")
                .count(),
            reads * 2,
            "{reading}: one job read per pass"
        );
    }
}

/// A GitHub item a `Refs` merge left open is judged by the Linear rule
/// from its own merged pull request, and written on its issue: its
/// merge-triggered box, read failed, takes one comment on the issue; read
/// met, it is ticked in the body with its Evidence line, the tick asked
/// again after GitHub refused it. Its release-triggered box waits, also on a
/// later release that does not contain the merge; a release that does is
/// met, ticked, and the issue closes as completed with it. A person's
/// reopen of the closed issue stands, and a box the person adds and ticks
/// by hand closes it again once it carries its Evidence line, a refused
/// close asked again. An issue an
/// outside author wrote is no item: its merge left it open, and it is said
/// once for the overseer. A Linear item's row stands while the tracker is
/// unread; no write reaches the tracker CLI.
#[test]
fn a_github_items_post_merge_boxes_are_judged_and_its_issue_closes_at_the_last() {
    const NOW: u64 = 1_790_899_201; // 2026-10-02T00:00:01Z
    const LATER: u64 = 1_791_007_200; // 2026-10-03T06:00:00Z
    const MERGE: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const BODY: &str = "## Done when\n- [ ] Branch work lands\n- [ ] Post-merge: job time <= 600 s; Where: https://github.com/owner/repo/actions/runs/5/job/77; Why after merge: runs on main; Deadline: +48h\n- [ ] Post-merge: releases >= 1 release; Where: https://github.com/owner/repo/releases; Why after merge: ships in a release; Trigger: release owner/repo v*; Deadline: +24h\n";
    const ADDED: &str = "- [ ] Post-merge: health reads green; Where: service; Why after merge: the regression; Trigger: 2026-10-05T00:00:00Z; Deadline: 2026-10-06T00:00:00Z\n";
    let mut world = World::new();
    quiet_github(&mut world);
    let outside = json!({"number": 8, "state": "open", "title": "a report", "body": BODY,
        "created_at": "2026-09-20T00:00:00Z", "user": {"login": "visitor", "type": "User"},
        "author_association": "NONE"});
    // `None` is the issue closed: GitHub lists the open ones alone.
    let plant_issue = |world: &mut World, body: Option<&str>| {
        let issue = |state: &str, body: &str| {
            json!({"number": 7, "state": state, "title": "the item", "body": body,
                "created_at": "2026-09-20T00:00:00Z", "user": null, "author_association": "OWNER"})
        };
        let (listed, got) = match body {
            Some(body) => (
                vec![issue("open", body), outside.clone()],
                issue("open", body),
            ),
            None => (vec![outside.clone()], issue("closed", "")),
        };
        world.gh(
            "repos/owner/repo/issues?state=open&per_page=100&page=1",
            json!({ "body": listed }),
        );
        world.gh("repos/owner/repo/issues/7", json!({ "body": got }));
    };
    plant_issue(&mut world, Some(BODY));
    let found = |numbers: &[u64]| {
        let items: Vec<Value> = numbers
            .iter()
            .map(|n| json!({"number": n, "pull_request": {}}))
            .collect();
        json!({"body": {"total_count": items.len(), "incomplete_results": false, "items": items}})
    };
    // Both issues' landings are read, and the outside one's alone while the
    // other is closed: it is said, not judged.
    world.gh(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D2026-09-20T00%3A00%3A00Z%20%28%28head%3Aissue-8%20OR%20%22issue-8%22%29%29%20in%3Atitle%2Cbody&per_page=100&page=1",
        found(&[13]),
    );
    world.gh(
        "search/issues?q=repo%3Aowner%2Frepo%20is%3Apr%20is%3Amerged%20merged%3A%3E%3D2026-09-20T00%3A00%3A00Z%20%28%28head%3Aissue-7%20OR%20%22issue-7%22%29%20OR%20%28head%3Aissue-8%20OR%20%22issue-8%22%29%29%20in%3Atitle%2Cbody&per_page=100&page=1",
        found(&[12, 13]),
    );
    for (number, item) in [(12, 7), (13, 8)] {
        world.gh(
            &format!("repos/owner/repo/pulls/{number}"),
            json!({"body": {"number": number, "state": "closed", "title": format!("fix(issue-{item}): the item"),
                "body": format!("Refs #{item}"), "merged_at": "2026-10-01T00:00:00Z", "merge_commit_sha": MERGE,
                "author_association": "OWNER",
                "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null,
                "head": {"sha": "0000000000000000000000000000000000000000", "ref": format!("issue-{item}"),
                    "repo": {"full_name": "owner/repo", "owner": {"login": "owner", "type": "User"}}}}}),
        );
    }
    let job = |completed: &str| {
        json!({"body": {"id": 77, "run_id": 5, "name": "perf",
            "head_sha": "0000000000000000000000000000000000000000", "status": "completed",
            "conclusion": "success", "started_at": "2026-10-01T10:00:00Z",
            "completed_at": completed,
            "check_run_url": "https://api.github.com/repos/owner/repo/check-runs/77"}})
    };
    world.gh(
        "repos/owner/repo/actions/jobs/77",
        job("2026-10-01T10:15:00Z"),
    );
    world.gh(
        "POST repos/owner/repo/issues/7/comments",
        json!({"body": {}}),
    );
    let release =
        |tag: &str, at: &str| json!({"tag_name": tag, "published_at": at, "draft": false});
    world.gh(
        "repos/owner/repo/releases?per_page=100&page=1",
        json!({ "body": [release("v0.9", "2026-09-25T00:00:00Z")] }),
    );
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let shared = Shared::default();
    let mut github =
        github::body(world.github_context(settings.clone(), None, &["owner/repo"], shared.clone()));
    let lines_slot = verifying::Lines::default();
    let mut verification = verifying::body(verifying::Context {
        settings,
        gh: world.dir.path().join("gh"),
        shared,
        lines: lines_slot.clone(),
    });
    // A Linear item's row from an earlier run; the tracker is never read here.
    let mut baseline = Baseline::default();
    baseline.apply(set(verifying::DEADLINE_ROW, "KEN-1", "-"));
    let writes = |world: &World| -> Vec<Value> {
        std::fs::read_to_string(world.dir.path().join("gh.log.input"))
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    };
    let status = |n: u64| -> String {
        let lines = lines_slot.lock().unwrap().clone();
        let prefix = format!("verifying owner/repo#7 box={n} ");
        let line = lines
            .iter()
            .find(|l| l.starts_with(&prefix))
            .unwrap_or_else(|| panic!("box {n}: {lines:?}"));
        line.split(' ')
            .find_map(|field| field.strip_prefix("status="))
            .unwrap()
            .to_owned()
    };
    let mut read_github = |baseline: &mut Baseline, at: u64| -> usize {
        let said = rendered(&pass_as(Duty::GitHub, &mut github, baseline, &clock, at).unwrap());
        said.iter()
            .filter(|l| *l == "EVENT verifying-unjudged owner/repo#8")
            .count()
    };

    assert_eq!(
        read_github(&mut baseline, NOW),
        1,
        "the outside author's merged issue is said once"
    );
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW,
    )
    .unwrap();
    assert_eq!(
        (status(2), status(3)),
        ("due".to_owned(), "waiting".to_owned())
    );
    assert!(
        lines_slot
            .lock()
            .unwrap()
            .iter()
            .all(|l| !l.contains("owner/repo#8")),
        "an outside author's issue is no item"
    );
    let written = writes(&world);
    assert_eq!(written.len(), 1, "{written:?}");
    assert_eq!(
        written[0]["call"],
        "POST repos/owner/repo/issues/7/comments"
    );
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW + 10,
    )
    .unwrap();
    assert_eq!(writes(&world).len(), 1, "a failed reading is said once");

    // Read met: the tick GitHub refuses is asked again on the next pass.
    world.gh(
        "repos/owner/repo/actions/jobs/77",
        job("2026-10-01T10:06:52Z"),
    );
    world.gh(
        "PATCH repos/owner/repo/issues/7",
        json!({"exit": 1, "stderr": "gh: HTTP 502"}),
    );
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW + 20,
    )
    .unwrap();
    world.gh("PATCH repos/owner/repo/issues/7", json!({"body": {}}));
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        NOW + 30,
    )
    .unwrap();
    let written = writes(&world);
    assert_eq!(written.len(), 3, "{written:?}");
    for tick in &written[1..] {
        assert_eq!(tick["call"], "PATCH repos/owner/repo/issues/7");
        assert_eq!(tick["input"].get("state"), None, "{tick}");
        let lines: Vec<&str> = tick["input"]["body"].as_str().unwrap().lines().collect();
        assert_eq!(lines[1], "- [ ] Branch work lands");
        assert!(lines[2].starts_with("- [x] Post-merge: job time"), "{tick}");
        assert!(lines[3].starts_with("  Evidence: 412 s "), "{tick}");
        assert!(lines[4].starts_with("- [ ] Post-merge: releases"), "{tick}");
    }
    let ticked = written[2]["input"]["body"].as_str().unwrap().to_owned();

    // GitHub now holds the ticked body; a release after the merge that
    // does not contain it leaves the release box waiting.
    plant_issue(&mut world, Some(&ticked));
    world.gh(
        "repos/owner/repo/releases?per_page=100&page=1",
        json!({ "body": [release("v0.9", "2026-09-25T00:00:00Z"), release("v1.0", "2026-10-03T00:00:00Z")] }),
    );
    world.gh(
        &format!("repos/owner/repo/compare/{MERGE}...v1.0"),
        json!({"body": {"status": "behind"}}),
    );
    assert_eq!(read_github(&mut baseline, LATER), 0);
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER,
    )
    .unwrap();
    assert_eq!(status(3), "waiting");
    assert_eq!(writes(&world).len(), 3);

    world.gh(
        &format!("repos/owner/repo/compare/{MERGE}...v1.0"),
        json!({"body": {"status": "ahead"}}),
    );
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 60,
    )
    .unwrap();
    assert_eq!(status(3), "due");
    let written = writes(&world);
    assert_eq!(written.len(), 4, "{written:?}");
    assert_eq!(
        (
            &written[3]["input"]["state"],
            &written[3]["input"]["state_reason"]
        ),
        (&json!("closed"), &json!("completed"))
    );
    let closed = written[3]["input"]["body"].as_str().unwrap().to_owned();
    assert!(closed.contains("\n- [x] Post-merge: releases"), "{closed}");

    // Closed, its row goes; reopened with every box ticked, it stays open.
    plant_issue(&mut world, None);
    assert_eq!(read_github(&mut baseline, LATER + 120), 0);
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 120,
    )
    .unwrap();
    assert_eq!(baseline.get(verifying::DEADLINE_ROW, "owner/repo#7"), None);
    plant_issue(&mut world, Some(&closed));
    assert_eq!(read_github(&mut baseline, LATER + 180), 0);
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 180,
    )
    .unwrap();
    assert_eq!(writes(&world).len(), 4, "a reopen stands");

    // A box the person adds waits; ticked by hand, the issue closes, the
    // close GitHub refuses asked again.
    let added = format!("{closed}{ADDED}");
    plant_issue(&mut world, Some(&added));
    assert_eq!(read_github(&mut baseline, LATER + 240), 0);
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 240,
    )
    .unwrap();
    assert_eq!(status(4), "waiting");
    // Ticked by hand with no Evidence line, the box is not passed: the
    // issue stays open.
    let clicked = added.replace("- [ ] Post-merge: health", "- [x] Post-merge: health");
    plant_issue(&mut world, Some(&clicked));
    assert_eq!(read_github(&mut baseline, LATER + 270), 0);
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 270,
    )
    .unwrap();
    assert_eq!(
        writes(&world).len(),
        4,
        "an unproved hand tick closes nothing"
    );
    let proved = format!("{clicked}  Evidence: read by the owner\n");
    plant_issue(&mut world, Some(&proved));
    world.gh(
        "PATCH repos/owner/repo/issues/7",
        json!({"exit": 1, "stderr": "gh: HTTP 502"}),
    );
    assert_eq!(read_github(&mut baseline, LATER + 300), 0);
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 300,
    )
    .unwrap();
    world.gh("PATCH repos/owner/repo/issues/7", json!({"body": {}}));
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 360,
    )
    .unwrap();
    let written = writes(&world);
    assert_eq!(written.len(), 6, "{written:?}");
    for close in &written[4..] {
        assert_eq!(
            close["input"],
            json!({"state": "closed", "state_reason": "completed"})
        );
    }
    pass_as(
        Duty::Verification,
        &mut verification,
        &mut baseline,
        &clock,
        LATER + 420,
    )
    .unwrap();
    assert_eq!(
        writes(&world).len(),
        6,
        "a written close is not asked again"
    );

    assert!(
        writes(&world)
            .iter()
            .all(|w| !w["call"].as_str().unwrap().contains("issues/8")),
        "nothing is written on the outside author's issue"
    );
    assert_eq!(baseline.get(verifying::DEADLINE_ROW, "KEN-1"), Some("-"));
    assert!(
        world
            .linear_calls()
            .iter()
            .all(|c| !c.starts_with("issues complete") && !c.starts_with("comments create")),
        "{:?}",
        world.linear_calls()
    );
}

/// A Verifying item left with an open branch-provable box, as a merge
/// whose lane never completed it leaves one, is named by the event once,
/// not on every pass; once its checklist reads valid and turns invalid
/// again, it is named again.
#[test]
fn a_verifying_item_with_an_open_branch_box_is_named_once() {
    const NOW: u64 = 1_790_899_201;
    let mut world = World::new();
    world.linear("statuses list", statuses());
    let verifying = |description: &str| {
        let mut item = item(
            "KEN-1",
            "2026-09-20T00:00:00Z",
            "Verifying",
            "started",
            json!(1),
            &[],
        );
        item["description"] = json!(description);
        json!({"body": [item]})
    };
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": [
            {"identifier": "KEN-1", "state": {"type": "started"}, "children": {"nodes": []}}
        ]}}}),
    );
    let clock = FakeClock::new();
    let settings = world.settings(&[]);
    let ctx = world.context(settings.clone(), None);
    let shared = ctx.shared.clone();
    let mut tracker = tracker::body(ctx);
    let mut verification = verifying::body(verifying::Context {
        settings,
        gh: world.dir.path().join("gh"),
        shared,
        lines: verifying::Lines::default(),
    });
    let mut baseline = Baseline::default();
    let open = "## Done when\n- [ ] first";
    let proved = "## Done when\n- [x] first\n  Evidence: tests/a.rs first_row";
    let invalid = vec!["EVENT verifying-invalid KEN-1".to_owned()];
    for (description, want) in [
        (open, invalid.clone()),
        (open, Vec::new()),
        (
            proved,
            vec![
                "EVENT verifying-deadline KEN-1 boxes=0".to_owned(),
                "verifying KEN-1 boxes=0".to_owned(),
            ],
        ),
        (open, invalid),
    ] {
        world.linear("issues list", verifying(description));
        pass(&mut tracker, &mut baseline, &clock, NOW).unwrap();
        let produced = pass_as(
            Duty::Verification,
            &mut verification,
            &mut baseline,
            &clock,
            NOW,
        )
        .unwrap();
        assert_eq!(rendered(&produced), want, "{description:?}");
    }
}

/// A comment's record fields: each `**Label**: value` at a line's start,
/// a list item's included.
fn record_fields(body: &str) -> BTreeMap<String, String> {
    body.lines()
        .filter_map(|line| {
            let line = line.strip_prefix("- ").unwrap_or(line);
            let (label, value) = line.strip_prefix("**")?.split_once("**: ")?;
            Some((label.to_owned(), value.to_owned()))
        })
        .collect()
}

/// Whether a comment opens with its result for the person: a sentence,
/// not a record field, a heading or a `key=value` line.
fn opens_with_prose(body: &str) -> bool {
    let first = body.lines().next().unwrap_or_default();
    !first.is_empty()
        && !first.starts_with("**")
        && !first.starts_with('#')
        && !first.split(' ').next().unwrap_or_default().contains('=')
}

fn posted_owner_ask(
    world: &World,
    id: &str,
    item: (&str, Option<&str>),
    question: Option<&str>,
    deadline: &str,
) -> (Settings, PathBuf) {
    let root = std::fs::canonicalize(world.dir.path()).unwrap();
    git_checkout(&root);
    for (key, value) in [("gc.auto", "0"), ("maintenance.auto", "false")] {
        let out = program("git")
            .arg("-C")
            .arg(&root)
            .args(["config", key, value])
            .output()
            .unwrap();
        assert!(out.status.success(), "git config {key}: {}", stderr(&out));
    }
    std::fs::write(
        root.join("kendex.settings.toml"),
        "[env]\nORCH_OWNER_EMAIL = \"owner@example.com\"\nORCH_OWNER_ASK_LABEL = \"owner-gated\"\n",
    )
    .unwrap();
    let mailbox = root.join("tmp/lane-mail/overseer");
    std::fs::create_dir_all(&mailbox).unwrap();
    let events = mailbox.join("to-overseer.jsonl");
    let (issue, uuid) = item;
    let identity = uuid.map(|uuid| json!({"identifier": issue, "uuid": uuid}));
    let ask = json!({"id": id, "kind": "ask", "at": "2026-10-01T00:00:00Z",
        "from": "overseer:test", "to": "owner", "issue": issue, "identity": identity, "text": "Approve?",
        "options": ["yes", "no"], "recommend": "yes", "wait": 0, "effect": "none",
        "deadline": deadline});
    let posted = json!({"id": format!("{id}-tracker"), "kind": "tracker-posted",
        "at": "2026-10-01T00:00:01Z", "from": "overseer:test", "re": id,
        "issue": issue, "tracker_label": "owner-gated", "tracker_comment": question,
        "text": ""});
    std::fs::write(&events, format!("{ask}\n{posted}\n")).unwrap();
    let cli = isolated_program(&fixtures().join("lane-mail-hold/lane-mail"));
    let mut settings = world.settings(&[
        ("LANE_MAIL_CLI", cli.to_str().unwrap()),
        ("ORCH_OWNER_EMAIL", "owner@example.com"),
        ("ORCH_OWNER_ASK_LABEL", "owner-gated"),
    ]);
    settings.reach = Some(agent_runtime::effects::Reach {
        mail_program: cli,
        mail_root: root.clone(),
        socket: Some(root.join("no-server")),
    });
    (settings, mailbox.join("to-lane.jsonl"))
}

/// A watch ruling leaves the active view after the Linear writer posts it
/// under the exact question, even when the account and issue identifier changed.
/// The Jarvis regression consumes the watch's actual argv for each form.
#[test]
fn watch_rulings_leave_the_active_view_after_a_tracker_account_change() {
    const NAME: &str = "watch_rulings_leave_the_active_view_after_a_tracker_account_change";
    const QUESTION: &str = "01234567-89ab-4def-8123-456789abcdef";
    const FORMER_REF: &str = "OLD-7";
    const ITEM_UUID: &str = "KEN-7-uuid";
    if !isolated_row(NAME) {
        return;
    }
    let mut rulings = BTreeMap::new();
    for (form, question, uuid) in [
        ("explicit", Some(QUESTION), Some(ITEM_UUID)),
        ("text", Some(QUESTION), Some(ITEM_UUID)),
        ("default", Some(QUESTION), Some(ITEM_UUID)),
        ("legacy", Some(QUESTION), Some(ITEM_UUID)),
        ("parent-only", Some(QUESTION), None),
        ("unthreaded", None, Some(ITEM_UUID)),
    ] {
        let mut world = World::new();
        let (mut settings, events) = posted_owner_ask(
            &world,
            "ask-1",
            (FORMER_REF, uuid),
            question,
            "2099-01-01T00:00:00Z",
        );
        settings.linear_team = None;
        world
            .linear("issues list --assignee", json!({"body": []}))
            .linear("comments bulk-list", comments(&[FORMER_REF], &[]))
            .linear("comments create", json!({"body": {"success": true}}))
            .linear("issues update", json!({"body": {}}))
            .linear(
                "graphql OwnerAskItem",
                json!({"body": {"issue": {
                    "description": "Body.", "assignee": null, "labels": {"nodes": []}
                }}}),
            );
        let mut body = tracker::body(world.context(settings, None));
        let mut baseline = Baseline::default();
        let clock = FakeClock::new();
        pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
        assert!(world.comment_calls().is_empty(), "{form}: the ask is open");
        let root = world.dir.path().canonicalize().unwrap();
        let mut close = program(lane_mail());
        close
            .args(["resolve", "--item", "overseer", "--id", "ask-1", "--root"])
            .arg(&root)
            .current_dir(&root);
        match form {
            "text" => {
                let answer = root.join("answer.txt");
                std::fs::write(&answer, "Approved.\n").unwrap();
                close.arg("--text").arg(answer);
            }
            "default" => {
                close.arg("--default");
            }
            "legacy" => {
                // Retained answers can lack the by field the current writer adds.
                let answer = json!({"kind": "answer", "id": "legacy-answer", "re": "ask-1",
                    "at": "2026-10-01T00:00:02Z", "from": "owner", "text": "Historical answer."});
                std::fs::write(events, format!("{answer}\n")).unwrap();
            }
            _ => {}
        }
        let closed = close.output().unwrap();
        assert!(closed.status.success(), "{form}: {}", stderr(&closed));
        pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
        let calls = world.comment_calls();
        assert_eq!(calls.len(), 1, "{form}: {calls:?}");
        let args = calls[0]["args"].as_array().unwrap();
        if question.is_some() && uuid.is_some() {
            assert_eq!(args[2], ITEM_UUID, "{form}: {calls:?}");
            rulings.insert(form, calls[0]["args"].clone());
        } else {
            assert_eq!(
                &args[..4],
                &["comments", "create", FORMER_REF, "--body"].map(Value::from)
            );
            let expected = question.map_or_else(Vec::new, |parent| {
                vec![Value::from("--parent"), Value::from(parent)]
            });
            assert_eq!(&args[5..], expected.as_slice(), "{form}: {calls:?}");
        }
    }
    let suite = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../jarvis/tests/owner-asks.test.sh");
    let view = program("bash")
        .arg(suite)
        .arg("PublicOwnerAsks.test_runtime_ruling_survives_tracker_actor_change")
        .env(
            "KENDEX_TEST_RULING_ARGS",
            serde_json::to_string(&rulings).unwrap(),
        )
        .output()
        .unwrap();
    assert!(view.status.success(), "{}", stderr(&view));
}

#[test]
fn a_due_tracker_ask_closes_once_without_a_triage_team() {
    let mut world = World::new();
    let (mut settings, events) = posted_owner_ask(
        &world,
        "ask-1",
        ("KEN-7", None),
        Some("question-1"),
        "2026-10-01T00:00:00Z",
    );
    settings.linear_team = None;
    world.linear("issues list --assignee", json!({"body": []}));
    // The open ask's item is off the owner list, and its question's comments
    // are read all the same.
    world.linear("comments bulk-list", comments(&["KEN-7"], &[]));
    world.linear("comments create", json!({"body": {"success": true}}));
    world.linear("issues update", json!({"body": {}}));
    world.linear(
        "graphql OwnerAskItem",
        json!({"body": {"issue": {"description": "Body.", "assignee": null,
            "labels": {"nodes": []}}}}),
    );
    let mut body = tracker::body(world.context(settings, Some(SINCE)));
    let mut baseline = Baseline::default();
    let clock = FakeClock::new();
    for wall in [SINCE_EPOCH + 1000, SINCE_EPOCH + 1240] {
        let produced = pass(&mut body, &mut baseline, &clock, wall).unwrap();
        assert_eq!(produced.failed, None);
        assert!(
            !rendered(&produced)
                .iter()
                .any(|line| line.contains("triage"))
        );
        let resolutions: Vec<Value> = lines(&events)
            .iter()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|event| event["kind"] == "resolution" && event["re"] == "ask-1")
            .collect();
        assert_eq!(
            resolutions.len(),
            1,
            "resolutions at {wall}: {resolutions:?}"
        );
        assert_eq!(resolutions[0]["by"], "default");
    }
    assert!(
        !world
            .linear_calls()
            .iter()
            .any(|line| line.contains("--team"))
    );
}

#[test]
fn a_ruling_is_not_reposted_after_a_failed_triage_comments_read() {
    let mut world = World::new();
    let (settings, _) = posted_owner_ask(
        &world,
        "ask-1",
        ("KEN-7", None),
        Some("question-1"),
        "2026-10-01T00:00:00Z",
    );
    let candidate = item(
        "KEN-1",
        "2026-08-16T00:00:00Z",
        "Triage",
        "triage",
        json!(1),
        &[],
    );
    world
        .linear("statuses list", statuses())
        .linear("issues list", json!({"body": [candidate]}))
        .linear("issues list --assignee", json!({"body": []}))
        .linear(
            "issues bulk-get",
            json!({"body": {"issues": {"nodes": [
                {"identifier": "KEN-1", "state": {"type": "triage"}, "children": {"nodes": []}}
            ]}}}),
        )
        .linear("comments bulk-list", comments(&["KEN-1"], &[]))
        .linear("comments create", json!({"body": {"success": true}}))
        .linear("issues update", json!({"body": {}}))
        .linear(
            "graphql OwnerAskItem",
            json!({"body": {"issue": {
                "description": "Body.", "assignee": null, "labels": {"nodes": []}
            }}}),
        );
    let mut body = tracker::body(world.context(settings, Some(SINCE)));
    let mut baseline = Baseline::default();
    let clock = FakeClock::new();
    pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    let before = world.linear_calls().len();
    world.linear(
        "comments bulk-list",
        json!({"exit": 1, "stderr": "linear: request-failed status=500"}),
    );
    let failed = pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1240);
    let calls = world.linear_calls();
    let ensuing = &calls[before..];
    let ruling = |call: &&String| call.starts_with("comments create KEN-7 --body ");
    let posted = ensuing.iter().position(|call| ruling(&call)).unwrap();
    let read = ensuing
        .iter()
        .position(|call| call.starts_with("comments bulk-list KEN-1 "))
        .unwrap();
    assert!(posted < read, "{ensuing:?}");
    world.linear("comments bulk-list", comments(&["KEN-1"], &[]));
    pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
    assert_eq!(world.linear_calls().iter().filter(ruling).count(), 1);
    let rulings: Vec<_> = world
        .posted_comments()
        .into_iter()
        .filter(|(issue, _, _)| issue == "KEN-7")
        .map(|(issue, parent, body)| {
            let fields = record_fields(&body);
            (
                issue,
                parent,
                opens_with_prose(&body),
                fields.get("Decided by").cloned(),
                fields.get("Ruling").cloned(),
            )
        })
        .collect();
    assert_eq!(
        rulings,
        [(
            "KEN-7".to_owned(),
            "question-1".to_owned(),
            true,
            Some("recommendation".to_owned()),
            Some("yes".to_owned())
        )],
        "the deadline's ruling, once, under the question"
    );
    assert!(
        failed
            .unwrap()
            .failed
            .unwrap()
            .contains("tracker-list-failed")
    );
}

/// The owner's tracker answers, the description repair and the due tracker
/// asks, on the real mailbox program. The row makes its asks with the
/// mailbox's own `ask`, which posts each to the tracker: the linear fixture,
/// installed beside the mailbox as the linear package's CLI with a map of
/// its own. The watch's reads go through the linear fixture under the
/// tracker's quota rule.
#[test]
fn owner_tracker_answers_are_handed_back_and_due_tracker_asks_closed_after_a_whole_read() {
    const POSTED: &str = "a54c6f77-50d1-4001-8000-000000000001";
    let action = "Post the message. Copy its link. The link closes this ask.";
    let body = "Engineering body.\n\nKeep these bytes.\n\n";
    let mut world = World::new();
    let root = std::fs::canonicalize(world.dir.path()).unwrap();
    for args in [
        vec!["init", "-q"],
        vec!["config", "gc.auto", "0"],
        vec!["config", "maintenance.auto", "false"],
    ] {
        let out = program("git")
            .arg("-C")
            .arg(&root)
            .args(&args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    }
    // The checkout's settings, where the mailbox finds the fleet record and
    // the owner its asks are posted for.
    std::fs::write(
        root.join("kendex.settings.toml"),
        format!(
            "[env]\nORCH_STATE_DIR = \"{}\"\nORCH_OWNER_EMAIL = \"owner@example.com\"\nORCH_OWNER_ASK_LABEL = \"owner-gated\"\n",
            root.display()
        ),
    )
    .unwrap();
    // The overseer an answer is sent to: recorded, its process gone.
    let mut fleet = world.fleet();
    fleet["controller"] = json!({"runtime": "tmux", "generation": 1,
        "server": GONE_PID.to_string(), "server_start": 1,
        "server_socket": root.join("no-server").display().to_string(),
        "pane": "%99", "harness_pid": GONE_PID.to_string(), "harness_start": "1",
        "harness": "claude", "cwd": root.display().to_string()});
    world.write_fleet(&fleet);
    // The mailbox as an install lays it out, with the linear package's CLI
    // and the shim that runs it from the root a call names, as the watch
    // runs it from the project root.
    let skills = root.join("skills");
    let mailbox = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../mailbox/scripts")
        .canonicalize()
        .unwrap();
    for (at, target) in [
        ("mailbox/scripts/lane-mail", mailbox.join("lane-mail")),
        ("mailbox/scripts/lib", mailbox.join("lib")),
        (
            "agent-runtime/scripts/agent-runtime",
            agent_runtime().to_path_buf(),
        ),
        (
            "linear/scripts/linear.sh",
            fixtures().join("linear-fixture/linear.sh"),
        ),
        (
            "orch/tests/rust/fixtures/lane-mail-hold/lane-mail",
            fixtures().join("lane-mail-hold/lane-mail"),
        ),
    ] {
        let at = skills.join(at);
        std::fs::create_dir_all(at.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(target, at).unwrap();
    }
    let lane_mail = skills.join("mailbox/scripts/lane-mail");
    let mail = |args: &[&str]| -> String {
        let out = program(&lane_mail)
            .args(args)
            .current_dir(&root)
            .output()
            .unwrap();
        assert!(out.status.success(), "lane-mail {args:?}: {}", stderr(&out));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    let question = root.join("question.txt");
    std::fs::write(&question, "Approve the action?\n").unwrap();
    let question = question.display().to_string();
    // An owner ask on `issue`, due at once, posted to the tracker under the
    // comment `comment`: its id.
    let ask = |issue: &str, comment: &str| -> String {
        let posting = json!({
            "users list": {"body": [{"id": "maya", "name": "Maya Owner", "email": "owner@example.com", "display_name": "maya"}]},
            "teams keys": {"body": {"urlKey": "test", "keys": ["KEN"]}},
            // The tracker identity the ask reads of its item and of each
            // open ask's item.
            "issues bulk-get": {"body": [
                {"id": "KEN-7", "uuid": "00000007-0000-4000-8000-000000000007"},
                {"id": "KEN-8", "uuid": "00000008-0000-4000-8000-000000000008"},
                {"id": "KEN-9", "uuid": "00000009-0000-4000-8000-000000000009"},
                {"id": "KEN-10", "uuid": "00000010-0000-4000-8000-000000000010"}]},
            "graphql OwnerTracker": {"body": {"issue": {"description": body, "assignee": null,
                "labels": {"pageInfo": {"hasNextPage": false}, "nodes": [{"name": "skills"}]}}}},
            "issues update": {"body": {}},
            "comments owner-questions --id": {"text": comment},
            "comments create": {"body": {"success": true, "data": {"success": true, "comment": {"id": comment}}}},
            // The saved comment read back, mentioning the owner.
            "graphql OwnerTrackerComment": {"body": {"comment": {"bodyData": json!({"type": "doc",
                "content": [{"type": "suggestion_userMentions", "attrs": {"id": "maya"}}]}).to_string()}}},
        });
        std::fs::write(
            skills.join("linear/scripts/linear.json"),
            posting.to_string(),
        )
        .unwrap();
        let out = mail(&[
            "ask",
            "--item",
            "overseer",
            "--to",
            "owner",
            "--issue",
            issue,
            "--do",
            action,
            "--wait",
            "0",
            "--options",
            "approve,hold",
            "--recommend",
            "approve",
            "--effect",
            "none",
            "--file",
            &question,
        ]);
        out.lines()
            .find_map(|l| l.strip_prefix("id="))
            .unwrap_or_else(|| panic!("ask {issue}: {out}"))
            .to_owned()
    };
    let root_text = root.display().to_string();
    // The answers and closes the real mailbox holds for the ask `id`.
    let closes = |id: &str| -> Vec<Value> {
        mail(&["events", "--item", "overseer", "--root", &root_text])
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|e| e["re"] == id && (e["kind"] == "answer" || e["kind"] == "resolution"))
            .collect()
    };
    let answered = ask("KEN-7", POSTED);
    let due = ask("KEN-8", "question-2");
    world.linear("statuses list", statuses());
    world.linear("issues list", json!({"body": []}));
    world.linear(
        "issues bulk-get",
        json!({"body": {"issues": {"nodes": []}}}),
    );
    world.linear(
        "issues list --assignee",
        json!({"body": [
            {"id": "KEN-7", "uuid": "00000007-0000-4000-8000-000000000007", "labels": ["skills", "owner-gated"], "description": body, "assignee": "Maya Owner", "url": "https://linear.app/test/issue/KEN-7"},
            {"id": "KEN-8", "uuid": "00000008-0000-4000-8000-000000000008", "labels": ["skills", "owner-gated"], "description": format!("**Maya, what you do:** {action}\n\n{body}"), "assignee": "Maya Owner", "url": "https://linear.app/test/issue/KEN-8"}
        ]}),
    );
    world.linear("issues update", json!({"body": {}}));
    world.linear("comments create", json!({"body": {"success": true}}));
    world.linear(
        "graphql OwnerAskItem",
        json!({"body": {"issue": {"description": format!("**Maya, what you do:** {action}\n\n{body}"),
            "assignee": {"name": "Maya Owner"},
            "labels": {"pageInfo": {"hasNextPage": false},
                "nodes": [{"name": "skills"}, {"name": "owner-gated"}]}}}}),
    );
    world.linear(
        "comments bulk-list",
        json!({"body": {"KEN-7": [
            {"id": POSTED, "body": "Approve the action?", "user": "agent", "user_email": "agent@example.test", "created_at": "2026-10-01T00:00:00.000Z", "updated_at": "2026-10-01T00:00:00.000Z"},
            {"id": "owner-comment", "body": "OK", "user": "maya", "user_email": "Owner@example.com", "created_at": "2026-10-02T00:00:00.001Z", "updated_at": "2026-10-02T00:00:00.001Z"},
            {"id": "other-comment", "body": "Not me", "user": "riley", "user_email": "other@example.test", "created_at": "2026-10-02T00:00:00.002Z", "updated_at": "2026-10-02T00:00:00.002Z"},
            {"id": "old-comment", "body": "Before", "user": "maya", "user_email": "owner@example.com", "created_at": "2026-09-30T00:00:00.000Z", "updated_at": "2026-09-30T00:00:00.000Z"}
        ], "KEN-8": []}}),
    );
    let cli = isolated_program(&skills.join("orch/tests/rust/fixtures/lane-mail-hold/lane-mail"));
    let cli = cli.display().to_string();
    let settings = world.settings(&[
        ("LANE_MAIL_CLI", &cli),
        ("ORCH_OWNER_EMAIL", "owner@example.com"),
        ("ORCH_OWNER_ASK_LABEL", "owner-gated"),
    ]);
    let clock = FakeClock::new();
    let mut body_fn = tracker::body(world.context(settings, None));
    let mut baseline = Baseline::default();
    let first = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
    assert_eq!(
        rendered(&first),
        Vec::<String>::new(),
        "the answer is the mailbox's line to print, not this duty's"
    );
    let linear_log = std::fs::read_to_string(world.dir.path().join("linear.log")).unwrap();
    assert!(
        linear_log.contains(
            "issues list --assignee owner@example.com --label owner-gated --max --format=safe\n"
        ),
        "the owner's items under the posted asks' label: {linear_log}"
    );
    let repaired = format!(
        "issues update KEN-7 --description **Maya, what you do:** {action}\n\n`Owner question: {POSTED}`\n\n{body}"
    );
    assert_eq!(
        (
            linear_log.matches(&repaired).count(),
            linear_log.matches("issues update KEN-8").count()
        ),
        (1, 0),
        "the description repair restores the name, action and body once, where the line is missing: {linear_log}"
    );
    assert!(
        linear_log.contains("comments bulk-list KEN-7 KEN-8 --format=safe\n"),
        "{linear_log}"
    );
    assert_eq!(
        linear_log
            .matches("comments create KEN-7 --parent owner-comment --body ")
            .count(),
        1,
        "the answer handed over is marked under the owner's comment: {linear_log}"
    );
    // The owner's comment after the question is the answer, handed back
    // before the due asks are closed: each due ask then closes at its
    // deadline, the answered one on its answer and the other on its
    // recommendation.
    let kinds = |id: &str| -> Vec<(Value, Value, Value)> {
        closes(id)
            .iter()
            .map(|e| (e["kind"].clone(), e["by"].clone(), e["text"].clone()))
            .collect()
    };
    assert_eq!(
        kinds(&answered),
        [
            (json!("answer"), json!("text"), json!("OK")),
            (json!("resolution"), json!("default"), json!(""))
        ],
        "the owner's answer alone, not the other author's, the question's or the older one, then the close: {:?}",
        closes(&answered)
    );
    assert_eq!(
        kinds(&due),
        [
            (json!("answer"), json!("default"), json!("approve")),
            (json!("resolution"), json!("default"), json!(""))
        ],
        "{:?}",
        closes(&due)
    );
    // An unread tracker (a failed owner-items read) hands nothing back and
    // closes no due ask: the pass is not failed, its own lines stand.
    let later = ask("KEN-9", "question-3");
    world.linear(
        "issues list --assignee",
        json!({"exit": 1, "stderr": "linear: auth-failed source=api-key"}),
    );
    let second = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
    assert_eq!(rendered(&second), Vec::<String>::new());
    assert_eq!(
        closes(&later),
        Vec::<Value>::new(),
        "an unread tracker closes no due ask"
    );
    // The asks the watch's first pass closed are no floor: the next pass
    // posts each one's ruling under its question and drops its label,
    // assignee and action line.
    // The answered ask's ruling is the owner's although its close came at
    // the deadline; the unanswered one's is the recommendation.
    let linear_log = std::fs::read_to_string(world.dir.path().join("linear.log")).unwrap();
    let posted = world.posted_comments();
    for (issue, uuid, decided, ruling, question) in [
        (
            "KEN-7",
            "00000007-0000-4000-8000-000000000007",
            "owner",
            "OK",
            POSTED,
        ),
        (
            "KEN-8",
            "00000008-0000-4000-8000-000000000008",
            "recommendation",
            "approve",
            "question-2",
        ),
    ] {
        let rulings: Vec<_> = posted
            .iter()
            .filter(|(i, parent, _)| i == uuid && parent == question)
            .map(|(_, _, body)| {
                let fields = record_fields(body);
                (
                    opens_with_prose(body),
                    fields.get("Decided by").cloned(),
                    fields.get("Ruling").cloned(),
                )
            })
            .collect();
        assert_eq!(
            (
                rulings,
                linear_log
                    .matches(&format!(
                        "issues update {issue} --labels skills --clear-assignee\n"
                    ))
                    .count()
            ),
            (
                vec![(true, Some(decided.to_owned()), Some(ruling.to_owned()))],
                1
            ),
            "{issue}'s ruling comment and cleared label, once: {posted:?} {linear_log}"
        );
    }
    // A refused mailbox read of the asks is unread the same way, never no
    // asks: no tracker item is read.
    world.linear("issues list --assignee", json!({"body": []}));
    let box_file = root.join("tmp/lane-mail/overseer/to-overseer.jsonl");
    let held = root.join("to-overseer.held");
    std::fs::rename(&box_file, &held).unwrap();
    std::fs::create_dir(&box_file).unwrap();
    let third = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1480);
    std::fs::remove_dir(&box_file).unwrap();
    std::fs::rename(&held, &box_file).unwrap();
    assert_eq!(rendered(&third.unwrap()), Vec::<String>::new());
    let linear_log = std::fs::read_to_string(world.dir.path().join("linear.log")).unwrap();
    assert_eq!(
        linear_log.matches("issues list --assignee").count(),
        2,
        "a refused ask read reads no tracker item: {linear_log}"
    );
    assert_eq!(closes(&later), Vec::<Value>::new());

    let quota_due = ask("KEN-10", "question-4");
    world.linear(
        "issues list --assignee",
        json!({"body": [{"id": "KEN-10", "uuid": "00000010-0000-4000-8000-000000000010", "description": format!("**Maya, what you do:** {action}\n\n{body}"), "assignee": "Maya Owner"}]}),
    );
    world.linear("comments bulk-list", json!({"exit": 1}));
    pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1600).unwrap();
    assert_eq!(
        closes(&quota_due),
        Vec::<Value>::new(),
        "an unread comment import cannot close a due ask"
    );
    let reset = SINCE_EPOCH + 2000;
    let quota = json!({"limit": "endpoint", "status": "future",
        "reset": agent_runtime::clock::iso_utc(reset), "reset_epoch": reset});
    let receipt = json!({"code": "RATELIMITED", "requests_reset": "unavailable", "quota": quota});
    world.linear(
        "comments bulk-list",
        json!({"exit": 1, "stderr": receipt.to_string()}),
    );
    let limited = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap();
    assert_eq!(
        rendered(&limited),
        [format!(
            "EVENT tracker-quota status=future reset={} limit=endpoint",
            agent_runtime::clock::iso_utc(reset)
        )]
    );
    let stored: Value =
        serde_json::from_str(baseline.get(tracker::QUOTA_ROW, "fleet").unwrap()).unwrap();
    assert_eq!(
        stored, quota,
        "the importer hands the reset to the fleet unchanged"
    );
    assert_eq!(closes(&quota_due), Vec::<Value>::new());
    let read_count = world.linear_calls().len();
    pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1800).unwrap();
    assert_eq!(
        world.linear_calls().len(),
        read_count,
        "the fleet holds tracker reads until the imported reset"
    );
    assert_eq!(closes(&quota_due), Vec::<Value>::new());
}

/// A posted owner ask closed by any route gets its tracker marks from the
/// asking overseer's watch, on the real mailbox program: the asks closed
/// before the first pass are the floor and are never written; a later
/// close, here Jarvis's typed answer through `resolve --text`, gets its
/// ruling comment under the question and its item write, the other open
/// ask on the item keeping its label, assignee and line; a refused comment
/// stops not the item write, is said once per cause, and is tried again
/// until it lands.
#[test]
fn a_closed_owner_ask_gets_its_marks_from_the_asking_watch_once_per_cause_until_they_land() {
    const Q1: &str = "a54c6f77-50d1-4001-8000-000000000001";
    const Q2: &str = "a54c6f77-50d1-4002-8000-000000000002";
    for quota_step in ["graphql OwnerAskItem", "issues update"] {
        let mut world = World::new();
        let root = std::fs::canonicalize(world.dir.path()).unwrap();
        for args in [
            vec!["init", "-q"],
            vec!["config", "gc.auto", "0"],
            vec!["config", "maintenance.auto", "false"],
        ] {
            let out = program("git")
                .arg("-C")
                .arg(&root)
                .args(&args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
        }
        let real = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../mailbox/scripts/lane-mail")
            .canonicalize()
            .unwrap();
        let mail = |args: &[&str]| {
            let out = program(&real)
                .args(args)
                .current_dir(&root)
                .output()
                .unwrap();
            assert!(out.status.success(), "lane-mail {args:?}: {}", stderr(&out));
        };
        let ask = |id: &str, issue: &str, action: &str| {
            json!({"id": id, "kind": "ask", "at": "2026-10-01T00:00:00Z", "from": "overseer:test",
            "to": "owner", "issue": issue, "do": action, "text": "Approve?", "options": ["yes", "no"],
            "recommend": "yes", "wait": 120, "deadline": "2099-01-01T00:00:00Z"})
        };
        let posted = |id: &str, issue: &str, label: &str, comment: &str| {
            json!({"id": format!("{id}-tracker"), "kind": "tracker-posted", "at": "2026-10-01T00:00:01Z",
            "from": "overseer:test", "re": id, "issue": issue, "tracker_label": label,
            "tracker_comment": comment, "text": ""})
        };
        let mailbox = root.join("tmp/lane-mail/overseer");
        std::fs::create_dir_all(&mailbox).unwrap();
        let lines = [
            ask("ask-1", "KEN-7", "Approve one."),
            posted("ask-1", "KEN-7", "owner-gated", Q1),
            ask("ask-2", "KEN-7", "Do two."),
            posted("ask-2", "KEN-7", "owner-other", Q2),
            ask("ask-3", "KEN-8", "Approve three."),
            posted("ask-3", "KEN-8", "owner-gated", "question-3"),
        ];
        let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
        std::fs::write(mailbox.join("to-overseer.jsonl"), text).unwrap();
        let answer = root.join("answer.txt");
        std::fs::write(&answer, "Approved.\n").unwrap();
        let root_text = root.display().to_string();
        let answer_text = answer.display().to_string();
        let resolve = |id: &str| {
            mail(&[
                "resolve",
                "--item",
                "overseer",
                "--root",
                &root_text,
                "--id",
                id,
                "--text",
                &answer_text,
            ]);
        };
        // Closed before the watch's first pass: the floor.
        resolve("ask-3");
        let body = "Body.\n\n";
        world.linear("statuses list", statuses());
        world.linear("issues list", json!({"body": []}));
        world.linear(
            "issues bulk-get",
            json!({"body": {"issues": {"nodes": []}}}),
        );
        world.linear(
        "issues list --assignee",
        json!({"body": [{"id": "KEN-7", "description": format!("**Maya, what you do:** Approve one.\n\n`Owner question: {Q1}`\n\n{body}"), "assignee": "Maya Owner"}]}),
    );
        world.linear("comments bulk-list", json!({"body": {"KEN-7": []}}));
        world.linear(
            "comments owner-questions KEN-8",
            json!({"exit": 1, "stderr": "issue purged"}),
        );
        world.linear(
        "graphql OwnerAskItem",
        json!({"body": {"issue": {"description": format!("**Maya, what you do:** Approve one.\n\n`Owner question: {Q1}`\n\n{body}"),
            "assignee": {"name": "Maya Owner"},
            "labels": {"pageInfo": {"hasNextPage": false},
                "nodes": [{"name": "skills"}, {"name": "owner-gated"}, {"name": "owner-other"}]}}}}),
    );
        world.linear("issues update", json!({"body": {}}));
        world.linear(
            "comments create",
            json!({"exit": 1, "stderr": "linear: request-failed status=500"}),
        );
        let cli = isolated_program(&fixtures().join("lane-mail-hold/lane-mail"));
        let cli = cli.display().to_string();
        let settings = world.settings(&[
            ("LANE_MAIL_CLI", &cli),
            ("ORCH_OWNER_EMAIL", "owner@example.com"),
            ("ORCH_OWNER_ASK_LABEL", "owner-gated"),
        ]);
        let clock = FakeClock::new();
        let mut body_fn = tracker::body(world.context(settings, None));
        let mut baseline = Baseline::default();
        let marks = |log: &str| -> (usize, usize) {
            (
                log.matches("comments create ").count(),
                log.matches("issues update ").count(),
            )
        };
        let first = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
        assert_eq!(rendered(&first), Vec::<String>::new());
        assert_eq!(first.failed, None);
        assert_eq!(
            marks(&world.linear_calls().join("\n")),
            (0, 0),
            "an ask closed before the first pass is never written"
        );
        // Jarvis's typed answer closes ask-1 through the real program.
        resolve("ask-1");
        let second = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
        assert_eq!(
            rendered(&second),
            ["EVENT owner-ask-unmarked ask-1 issue=KEN-7 step=ruling cause=tracker-list-failed"],
            "the refused ruling comment is said with its cause"
        );
        let log = std::fs::read_to_string(world.dir.path().join("linear.log")).unwrap();
        let rulings: Vec<_> = world
            .posted_comments()
            .into_iter()
            .map(|(issue, parent, body)| {
                let fields = record_fields(&body);
                (
                    issue,
                    parent,
                    fields.get("Decided by").cloned(),
                    fields.get("Ruling").cloned(),
                )
            })
            .collect();
        assert_eq!(
            rulings,
            [(
                "KEN-7".to_owned(),
                Q1.to_owned(),
                Some("owner".to_owned()),
                Some("Approved.".to_owned())
            )],
            "the ruling, a reply under the question"
        );
        assert!(
        log.contains(&format!(
            "issues update KEN-7 --labels owner-other,skills --description **Maya, what you do:** Do two.\n\n`Owner question: {Q2}`\n\n{body}"
        )),
        "a refused comment stops not the item write; the open ask keeps its label, assignee and line: {log}"
    );
        assert!(
            !log.lines()
                .any(|line| line.starts_with("issues update KEN-8 ")
                    || line.starts_with("comments create KEN-8 ")),
            "the legacy floor's ask is never written: {log}"
        );
        assert_eq!(marks(&log), (1, 1));
        let third = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1480).unwrap();
        assert_eq!(
            rendered(&third),
            Vec::<String>::new(),
            "a standing cause is said once"
        );
        assert_eq!(
            marks(&world.linear_calls().join("\n")),
            (2, 1),
            "the refused comment is tried again, the landed write is not"
        );
        world.linear("comments create", json!({"body": {"success": true}}));
        let fourth = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1720).unwrap();
        assert_eq!(rendered(&fourth), Vec::<String>::new());
        let fifth = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1960).unwrap();
        assert_eq!(rendered(&fifth), Vec::<String>::new());
        assert_eq!(
            marks(&world.linear_calls().join("\n")),
            (3, 1),
            "a landed comment ends the retries"
        );
        resolve("ask-2");
        let item = json!({"body": {"issue": {"description": format!("**Maya, what you do:** Do two.\n\n`Owner question: {Q2}`\n\n{body}"),
        "assignee": {"name": "Maya Owner"},
        "labels": {"pageInfo": {"hasNextPage": false}, "nodes": [{"name": "owner-other"}]}}}});
        world.linear("graphql OwnerAskItem", item.clone());
        let updates_before_retry = if quota_step == "issues update" { 2 } else { 1 };
        let reset = SINCE_EPOCH + 2400;
        let quota = json!({"limit": "endpoint", "status": "future",
        "reset": agent_runtime::clock::iso_utc(reset), "reset_epoch": reset});
        let receipt =
            json!({"code": "RATELIMITED", "requests_reset": "unavailable", "quota": quota});
        world.linear(
            quota_step,
            json!({"exit": 1, "stderr": receipt.to_string()}),
        );
        let limited = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 2200).unwrap();
        assert_eq!(
            rendered(&limited),
            [format!(
                "EVENT tracker-quota status=future reset={} limit=endpoint",
                agent_runtime::clock::iso_utc(reset)
            )]
        );
        assert_eq!(
            marks(&world.linear_calls().join("\n")),
            (4, updates_before_retry)
        );
        world.linear("graphql OwnerAskItem", item);
        world.linear("issues update", json!({"body": {}}));
        pass(&mut body_fn, &mut baseline, &clock, reset + 1).unwrap();
        assert_eq!(
            marks(&world.linear_calls().join("\n")),
            (4, updates_before_retry + 1),
            "a quota after a landed ruling retries only the item"
        );
        assert_eq!(
            baseline.get(tracker::OWNER_MARK_ROW, "ask-2"),
            Some("ruling=ok item=ok"),
            "the item mark completes after the reset"
        );
    }
}

/// Closing an owner ask recorded under another spelling of its item, as
/// its replacement's close does, keeps the open replacement's label,
/// assignee and action line: the two asks are on one item where the
/// tracker gave them one UUID, the closed ask's own or the one the
/// replacement's `replaces` entry recorded for it.
#[test]
fn closing_a_predecessor_under_another_spelling_keeps_the_open_replacements_item_state() {
    const Q1: &str = "a54c6f77-50d1-4001-8000-000000000001";
    const Q2: &str = "a54c6f77-50d1-4002-8000-000000000002";
    const UUID: &str = "00000007-0000-4000-8000-000000000007";
    let identity = json!({"identifier": "KEN-7", "uuid": UUID});
    // The closed ask's item ref, and the identity its own envelope carries.
    let rows = [("ken-7", Some(identity.clone())), (UUID, None)];
    for (spelling, own) in rows {
        let mut world = World::new();
        let root = std::fs::canonicalize(world.dir.path()).unwrap();
        for args in [
            vec!["init", "-q"],
            vec!["config", "gc.auto", "0"],
            vec!["config", "maintenance.auto", "false"],
        ] {
            let out = program("git")
                .arg("-C")
                .arg(&root)
                .args(&args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
        }
        let mut predecessor = json!({"id": "ask-1", "kind": "ask", "at": "2026-10-01T00:00:00Z",
            "from": "overseer:test", "to": "owner", "issue": spelling, "do": "Approve one.",
            "text": "Approve?", "options": ["yes", "no"], "recommend": "yes", "wait": 120,
            "deadline": "2099-01-01T00:00:00Z"});
        if let Some(own) = &own {
            predecessor["identity"] = own.clone();
        }
        let replacement = json!({"id": "ask-2", "kind": "ask", "at": "2026-10-01T00:01:00Z",
            "from": "overseer:test", "to": "owner", "issue": "KEN-7", "do": "Do two.",
            "text": "Approve, or hold?", "options": ["yes", "hold"], "recommend": "yes", "wait": 120,
            "deadline": "2099-01-01T00:00:00Z", "identity": identity,
            "replaces": [{"id": "ask-1", "tracker_comment": Q1, "identity": identity}]});
        let posted = |id: &str, issue: &str, comment: &str| {
            json!({"id": format!("{id}-tracker"), "kind": "tracker-posted", "at": "2026-10-01T00:01:01Z",
            "from": "overseer:test", "re": id, "issue": issue, "tracker_label": "owner-gated",
            "tracker_comment": comment, "text": ""})
        };
        let mailbox = root.join("tmp/lane-mail/overseer");
        std::fs::create_dir_all(&mailbox).unwrap();
        let text: String = [
            predecessor,
            posted("ask-1", spelling, Q1),
            replacement,
            posted("ask-2", "KEN-7", Q2),
        ]
        .iter()
        .map(|l| format!("{l}\n"))
        .collect();
        std::fs::write(mailbox.join("to-overseer.jsonl"), text).unwrap();
        let body = "Body.\n\n";
        world.linear("statuses list", statuses());
        world.linear("issues list", json!({"body": []}));
        world.linear(
            "issues bulk-get",
            json!({"body": {"issues": {"nodes": []}}}),
        );
        world.linear(
            "issues list --assignee",
            json!({"body": [{"id": "KEN-7", "uuid": UUID,
                "description": format!("**Maya, what you do:** Approve one.\n\n`Owner question: {Q1}`\n\n{body}"), "assignee": "Maya Owner"}]}),
        );
        world.linear("comments bulk-list", json!({"body": {"KEN-7": []}}));
        world.linear(
            "graphql OwnerAskItem",
            json!({"body": {"issue": {"description": format!("**Maya, what you do:** Approve one.\n\n`Owner question: {Q1}`\n\n{body}"),
                "assignee": {"name": "Maya Owner"},
                "labels": {"pageInfo": {"hasNextPage": false},
                    "nodes": [{"name": "skills"}, {"name": "owner-gated"}]}}}}),
        );
        world.linear("issues update", json!({"body": {}}));
        world.linear("comments create", json!({"body": {"success": true}}));
        let cli = isolated_program(&fixtures().join("lane-mail-hold/lane-mail"));
        let cli = cli.display().to_string();
        let settings = world.settings(&[
            ("LANE_MAIL_CLI", &cli),
            ("ORCH_OWNER_EMAIL", "owner@example.com"),
            ("ORCH_OWNER_ASK_LABEL", "owner-gated"),
        ]);
        let clock = FakeClock::new();
        let mut body_fn = tracker::body(world.context(settings, None));
        let mut baseline = Baseline::default();
        pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
        // The replacement closes its predecessor as `resolve --id` does.
        let real = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../mailbox/scripts/lane-mail")
            .canonicalize()
            .unwrap();
        let root_text = root.display().to_string();
        let out = program(&real)
            .args([
                "resolve", "--item", "overseer", "--root", &root_text, "--id", "ask-1",
            ])
            .current_dir(&root)
            .output()
            .unwrap();
        assert!(out.status.success(), "lane-mail resolve: {}", stderr(&out));
        let closed = pass(&mut body_fn, &mut baseline, &clock, SINCE_EPOCH + 1240).unwrap();
        assert_eq!(rendered(&closed), Vec::<String>::new(), "{spelling}");
        let log = std::fs::read_to_string(world.dir.path().join("linear.log")).unwrap();
        assert!(
            log.contains(&format!(
                "issues update {spelling} --labels owner-gated,skills --description **Maya, what you do:** Do two.\n\n`Owner question: {Q2}`\n\n{body}"
            )),
            "the open replacement keeps its label, assignee and line, recorded as {spelling}: {log}"
        );
    }
}

#[test]
fn two_mailboxes_keep_the_item_gated_until_both_rulings_land() {
    const NAME: &str = "two_mailboxes_keep_the_item_gated_until_both_rulings_land";
    const UUID: &str = "00000007-0000-4000-8000-000000000007";
    const FIRST: &str = "a54c6f77-50d1-4001-8000-000000000001";
    const SECOND: &str = "a54c6f77-50d1-4002-8000-000000000002";
    const LEGACY: &str = "00000007-0000-4000-8000-000000000077";
    let marked =
        |action, id| format!("**Maya, what you do:** {action}\n\n`Owner question: {id}`\n\nBody.");
    let own_action = marked("Approve A.", FIRST);
    if !isolated_row(NAME) {
        return;
    }
    let clock = FakeClock::new();
    let setup = |id, comment, started| {
        let mut world = World::new();
        let (mut settings, events) = posted_owner_ask(
            &world,
            id,
            ("KEN-7", Some(UUID)),
            Some(comment),
            "2099-01-01T00:00:00Z",
        );
        let outward = events.with_file_name("to-overseer.jsonl");
        let rows = std::fs::read_to_string(&outward).unwrap();
        let staged = if id == "ask-a" {
            let mut envelopes: Vec<Value> = rows
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            envelopes[0]["do"] = json!("Approve A.");
            envelopes.iter().map(|event| format!("{event}\n")).collect()
        } else {
            format!(
                "{}{}",
                rows.replace(id, "legacy-ask").replace(comment, LEGACY),
                rows
            )
        };
        std::fs::write(outward, staged).unwrap();
        settings.linear_team = None;
        world
            .linear("issues list --assignee", json!({"body": []}))
            .linear("comments bulk-list", comments(&["KEN-7"], &[]))
            .linear("comments create", json!({"body": {"success": true}}))
            .linear("issues update", json!({"body": {}}))
            .linear(
                "graphql OwnerAskItem",
                json!({"body": {"issue": {
                    "description": if id == "ask-a" { own_action.as_str() } else { "Body." }, "assignee": {"name": "Maya Owner"},
                    "labels": {"nodes": [{"name": "owner-gated"}, {"name": "skills"}]}
                }}}),
            );
        let mut body = tracker::body(world.context(settings, None));
        let mut baseline = Baseline::default();
        if started {
            pass(&mut body, &mut baseline, &clock, SINCE_EPOCH + 1000).unwrap();
        }
        (world, body, baseline)
    };
    let close = |world: &World, id| {
        let out = program(lane_mail())
            .args(["resolve", "--item", "overseer", "--id", id])
            .current_dir(world.dir.path())
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", stderr(&out));
    };
    let updates = |world: &World| {
        world
            .linear_calls()
            .into_iter()
            .filter(|line| line.starts_with("issues update "))
            .collect::<Vec<_>>()
    };
    let legacy = json!({"id": LEGACY, "reserved": false, "ruled": false, "legacy_asks": []});
    let pending =
        json!({"body": [{"id": SECOND, "reserved": true, "ruled": false, "legacy_asks": []}]});
    let (mut first, mut first_watch, mut first_marks) = setup("ask-a", FIRST, true);
    let (mut second, mut second_watch, mut second_marks) = setup("ask-b", SECOND, false);
    first.linear("comments owner-questions", pending.clone());
    close(&first, "ask-a");
    let description = |text| {
        json!({"body": {"issue": {
            "description": text, "assignee": {"name": "Maya Owner"},
            "labels": {"nodes": [{"name": "owner-gated"}, {"name": "skills"}]}
        }}})
    };
    let identical = marked("Approve A.", SECOND);
    let extended = marked("Approve A.\n\nThen check the result.", SECOND);
    let mut writes = Vec::new();
    for (at, text) in [
        (1240, identical.as_str()),
        (1480, extended.as_str()),
        (1720, "**Maya, what you do:** Approve A.\n\nBody."),
    ] {
        first.linear("graphql OwnerAskItem", description(text));
        pass(&mut first_watch, &mut first_marks, &clock, SINCE_EPOCH + at).unwrap();
        writes.push(updates(&first).len());
    }
    assert_eq!(
        writes,
        [0, 0, 0],
        "identical and longer newer actions and unmarked text are preserved"
    );
    first.linear("graphql OwnerAskItem", description(&own_action));
    pass(
        &mut first_watch,
        &mut first_marks,
        &clock,
        SINCE_EPOCH + 1960,
    )
    .unwrap();
    assert_eq!(
        updates(&first),
        ["issues update KEN-7 --description Body."],
        "first close clears only its action while keeping the owner label and assignee"
    );
    assert_eq!(first.posted_comments()[0].1, FIRST);

    second.linear("comments owner-questions", pending);
    second.linear(
        "comments create",
        json!({"exit": 1, "stderr": "linear: request-failed status=500"}),
    );
    close(&second, "ask-b");
    close(&second, "legacy-ask");
    pass(
        &mut second_watch,
        &mut second_marks,
        &clock,
        SINCE_EPOCH + 1240,
    )
    .unwrap();
    assert!(
        updates(&second).is_empty(),
        "the delayed second ruling keeps the gate"
    );

    second.linear("comments create", json!({"body": {"success": true}}));
    second.linear(
        "comments owner-questions",
        json!({"body": [
            legacy, {"id": "unknown-legacy-comment", "reserved": false, "ruled": false, "legacy_asks": []}
        ]}),
    );
    pass(
        &mut second_watch,
        &mut second_marks,
        &clock,
        SINCE_EPOCH + 1480,
    )
    .unwrap();
    assert!(
        updates(&second).is_empty(),
        "the unmarked legacy owner mention keeps the gate"
    );

    second.linear("comments owner-questions", json!({"body": [legacy]}));
    pass(
        &mut second_watch,
        &mut second_marks,
        &clock,
        SINCE_EPOCH + 1720,
    )
    .unwrap();
    assert_eq!(
        updates(&second),
        ["issues update KEN-7 --labels skills --clear-assignee"]
    );
    assert_eq!(
        second
            .posted_comments()
            .iter()
            .map(|c| c.1.as_str())
            .collect::<Vec<_>>(),
        [SECOND, SECOND]
    );

    first.linear("comments owner-questions", json!({"body": []}));
    let snapshot = |description| {
        json!({"body": {"issue": {
            "description": description, "assignee": null, "labels": {"nodes": [{"name": "skills"}]}
        }}})
    };
    // An exact old action can survive an earlier refused action write until the other mailbox clears the assignee.
    first.linear("graphql OwnerAskItem", snapshot(&own_action));
    pass(
        &mut first_watch,
        &mut first_marks,
        &clock,
        SINCE_EPOCH + 2200,
    )
    .unwrap();
    assert_eq!(
        updates(&first).last().unwrap(),
        "issues update KEN-7 --labels skills --description Body.",
        "another mailbox clearing the assignee does not strand the closed action"
    );
}

/// This test process's own identity, the one a runner in it claims with.
fn me() -> Identity {
    let pid = std::process::id();
    Identity {
        pid,
        start: start_of(pid),
    }
}

#[test]
fn lane_status_judges_the_recorded_pane_not_the_records_status_word() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    let pane = server.open_window("gh-2", dir.path(), "bash --norc --noprofile");
    // The controller's own server, not the caller's: the one its record
    // names, where a lane it launched is read.
    let controller_dir = tempfile::tempdir().unwrap();
    let controller = support::Server::start(controller_dir.path(), "fleet");
    let there = controller.open_window("gh-5", dir.path(), "bash --norc --noprofile");
    let record = |item: &str, window: &str, launch: Value| {
        json!({
            "item": item, "window": window, "harness": "claude", "status": "running",
            "mail_root": runner.state_dir().display().to_string(),
            "launch": launch,
        })
    };
    let mut fleet = runner.fleet();
    fleet["controller"] = json!({"server_socket": controller.socket.display().to_string()});
    fleet["lanes"] = json!([
        record("KEN-2", "gh-2", json!({"pane": pane, "server": server.pid})),
        // A live process no socket answers for: its server cannot be told
        // from gone.
        record(
            "KEN-3",
            "gh-3",
            json!({"pane": pane, "server": std::process::id()})
        ),
        record("KEN-4", "gh-4", json!({})),
        record(
            "KEN-5",
            "gh-5",
            json!({"pane": there, "server": controller.pid, "server_start": controller.start})
        ),
    ]);
    runner.write_fleet(&fleet);
    let status = |item: &str| {
        let out = runner.run(&["lane", "status", "--item", item]);
        (out.status.code(), reply(&out))
    };
    let (code, answer) = status("KEN-2");
    assert_eq!(code, Some(0), "{answer}");
    assert_eq!(answer["result"]["state"], "exited", "{answer}");
    assert_eq!(answer["result"]["window"], "gh-2");
    assert_eq!(
        answer["result"]["pane_key"],
        format!("{} {pane}", server.pid)
    );
    let (_, answer) = status("KEN-3");
    assert_eq!(answer["result"]["state"], "unreadable", "{answer}");
    assert_eq!(answer["result"]["cause"], "server-unreachable");
    let (_, answer) = status("KEN-4");
    assert_eq!(answer["result"]["state"], "unjudged", "{answer}");
    assert_eq!(answer["result"]["cause"], "pane-unrecorded");
    let (code, answer) = status("KEN-5");
    assert_eq!(code, Some(0), "{answer}");
    assert_eq!(answer["result"]["state"], "exited", "{answer}");
    assert_eq!(
        answer["result"]["pane_key"],
        format!("{} {there}", controller.pid)
    );
    let (code, answer) = status("KEN-9");
    assert_eq!(code, Some(1));
    assert_eq!(answer["refusal"]["key"], "lane-missing", "{answer}");
}

/// The world of a hosted lane's status read: the catalog's packages linked
/// under the state directory, the project the runtime takes its scripts
/// from, so the runtime's provider call reaches the provider the record
/// names.
fn install_scripts(runner: &support::Runner) {
    let skills = runner.state_dir().join(".agents").join("skills");
    std::fs::create_dir_all(&skills).unwrap();
    let catalog = orch_package().parent().unwrap().to_path_buf();
    for package in ["orch", "mailbox", "agent-runtime"] {
        std::os::unix::fs::symlink(catalog.join(package), skills.join(package)).unwrap();
    }
}

fn orch_package() -> PathBuf {
    support::fixtures()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf()
}

#[test]
fn lane_status_reads_a_provider_pane_through_its_capture_after_its_status_verb() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    install_scripts(&runner);
    let pane = server.open_window("gh-2", dir.path(), "bash --norc --noprofile");
    let provider = orch_package()
        .join("tests")
        .join("fixtures")
        .join("lane-host");
    let screen = dir.path().join("provider-screen");
    std::fs::write(&screen, "› task\n  press to interrupt\n").unwrap();
    let caps = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=verb";
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([{
        "item": "issue-2", "window": "fleet:gh-2", "harness": "codex",
        "host": provider, "status": "running", "mail_root": "/remote/issue-2",
        "launch": {"server": server.pid, "pane": pane}
    }]);
    runner.write_fleet(&fleet);
    let log = dir.path().join("host.log");
    let read = |capture: &str, state: &str, probe: &str| {
        let _ = std::fs::remove_file(&log);
        let env = [
            ("LANE_HOST_STUB_CAPABILITIES", caps),
            ("LANE_HOST_STUB_HARNESS_STATE", state),
            ("LANE_HOST_STUB_CAPTURE_STATUS", capture),
            ("LANE_HOST_STUB_PROBE_STATUS", probe),
            ("LANE_HOST_STUB_CAPTURE_FILE", screen.to_str().unwrap()),
            ("LANE_HOST_STUB_LOG", log.to_str().unwrap()),
        ];
        let out = runner.run_env(&["lane", "status", "--item", "issue-2"], &env);
        let answer = reply(&out);
        assert_eq!(out.status.code(), Some(0), "{answer}");
        (answer, std::fs::read_to_string(&log).unwrap_or_default())
    };
    let count = |calls: &str, verb: &str| calls.lines().filter(|l| l.starts_with(verb)).count();
    // The harness runs on the host and its own pane holds a turn in flight;
    // the local pane under the record is the transport's shell.
    let (answer, calls) = read("0", "running", "0");
    assert_eq!(answer["result"]["state"], "working", "{answer}");
    assert_eq!(count(&calls, "capture --item issue-2"), 1, "{calls}");
    assert_eq!(
        count(&calls, "status --item issue-2 --harness codex"),
        1,
        "{calls}"
    );
    let (answer, _) = read("2", "running", "0");
    assert_eq!(answer["result"]["state"], "unreadable", "{answer}");
    let cause = answer["result"]["cause"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    assert!(cause.starts_with("capture-failed item=issue-2"), "{answer}");
    let (answer, calls) = read("0", "exited", "0");
    assert_eq!(answer["result"]["state"], "exited", "{answer}");
    assert_eq!(count(&calls, "capture --item issue-2"), 0, "{calls}");
    let (answer, calls) = read("0", "running", "7");
    assert_eq!(answer["result"]["state"], "unjudged", "{answer}");
    let cause = answer["result"]["cause"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    assert!(
        cause.starts_with("harness-probe-failed item=issue-2"),
        "{answer}"
    );
    assert_eq!(count(&calls, "capture --item issue-2"), 0, "{calls}");
}

#[test]
fn lane_status_carries_the_lane_long_counts_read_from_the_items_state() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    let pane = server.open_window("gh-2", dir.path(), "bash --norc --noprofile");
    let root = dir.path().join("worktree");
    std::fs::create_dir_all(root.join("tmp")).unwrap();
    std::fs::write(
        support::item_record(&root.join("tmp"), "KEN-2"),
        r#"{"stages":[{"kind":"fix"}],"restacks":1,"rereview_cycles":2}"#,
    )
    .unwrap();
    let record = |item: &str, window: &str| {
        json!({
            "item": item, "window": window, "harness": "claude", "status": "running",
            "mail_root": root.display().to_string(),
            "launch": {"pane": pane, "server": server.pid},
        })
    };
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([record("KEN-2", "gh-2"), record("KEN-3", "gh-3")]);
    runner.write_fleet(&fleet);
    let status = |item: &str| reply(&runner.run(&["lane", "status", "--item", item]));
    let answer = status("KEN-2");
    assert_eq!(answer["result"]["state"], "exited", "{answer}");
    assert_eq!(answer["result"]["review_rounds"], "2", "{answer}");
    assert_eq!(answer["result"]["fix_receipts"], "1", "{answer}");
    assert_eq!(answer["result"]["validation_runs"], "unread", "{answer}");
    assert_eq!(answer["result"]["restacks"], "1", "{answer}");
    assert_eq!(
        answer["result"]["repeated_class_rounds"], "unread",
        "{answer}"
    );
    assert_eq!(answer["result"]["counts_cause"], Value::Null, "{answer}");
    // A lane that has written no state yet counts nothing, and says so.
    let answer = status("KEN-3");
    for key in [
        "review_rounds",
        "fix_receipts",
        "validation_runs",
        "restacks",
        "repeated_class_rounds",
    ] {
        assert_eq!(answer["result"][key], "unread", "{key}: {answer}");
    }
    assert_eq!(answer["result"]["stage"], "none", "{answer}");
}

/// The facts name the item's newest stage still open in the lane's current
/// session, the record's `session_since`, with its start: a closed stage, a
/// superseded one and one an earlier session left open name none.
#[test]
fn lane_status_names_a_stage_only_while_it_is_open_in_the_lanes_current_session() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    let root = dir.path().join("worktree");
    std::fs::create_dir_all(root.join("tmp")).unwrap();
    let since: u64 = 1_769_700_000;
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([{
        "item": "KEN-2", "window": "gh-2", "harness": "claude", "status": "running",
        "mail_root": root.display().to_string(), "launch": {},
        "session_since": agent_runtime::clock::iso_utc(since),
    }]);
    runner.write_fleet(&fleet);
    let closed = json!({"kind": "dev", "start": since - 600, "end": since - 300});
    let open = |kind: &str, start: u64| json!({"kind": kind, "start": start});
    for (stages, stage, start) in [
        (
            json!([closed, open("dev", since + 30), open("review", since + 60)]),
            json!("review"),
            json!(since + 60),
        ),
        (
            json!([open("validate", since)]),
            json!("validate"),
            json!(since),
        ),
        (
            json!([closed, {"kind": "review", "start": since + 60, "end": since + 120}]),
            json!("none"),
            Value::Null,
        ),
        (
            json!([{"kind": "fix", "start": since + 60, "superseded": true}]),
            json!("none"),
            Value::Null,
        ),
        (
            json!([open("review", since - 60)]),
            json!("none"),
            Value::Null,
        ),
    ] {
        std::fs::write(
            support::item_record(&root.join("tmp"), "KEN-2"),
            json!({ "stages": stages }).to_string(),
        )
        .unwrap();
        let answer = reply(&runner.run(&["lane", "status", "--item", "KEN-2"]));
        assert_eq!(answer["result"]["stage"], stage, "{stages}: {answer}");
        assert_eq!(answer["result"]["stage_start"], start, "{stages}: {answer}");
    }
}

/// The facts carry the item's post-PR stop only where it was recorded in the
/// lane's current session: the stop the real verb records stands for a
/// session that began before it, and a later launch's `session_since`
/// leaves it unnamed.
#[test]
fn lane_status_names_the_post_pr_stop_only_when_recorded_in_the_lanes_current_session() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    let ok = |args: &[&str]| {
        let out = runner.run(args);
        assert!(out.status.success(), "{args:?}: {}", support::stderr(&out));
    };
    ok(&["state", "init", "--item", "KEN-2"]);
    let comment = runner.state_dir().join("stop.md");
    ok(&[
        "state",
        "post-pr-stop",
        "record",
        "--item",
        "KEN-2",
        "--name",
        "review-round-cap",
        "--gate",
        "review",
        "--remaining",
        "one unresolved review thread",
        "--comment-file",
        comment.to_str().unwrap(),
    ]);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let stop_since = |since: u64| {
        let mut fleet = runner.fleet();
        fleet["lanes"] = json!([{
            "item": "KEN-2", "window": "gh-2", "harness": "claude", "status": "running",
            "launch": {}, "session_since": agent_runtime::clock::iso_utc(since),
        }]);
        runner.write_fleet(&fleet);
        reply(&runner.run(&["lane", "status", "--item", "KEN-2"]))["result"]["post_pr_stop"].clone()
    };
    let stop = stop_since(now - 3600);
    assert_eq!(stop["name"], "review-round-cap", "{stop}");
    assert_eq!(stop["gate"], "review", "{stop}");
    assert_eq!(stop["remaining"], json!(["one unresolved review thread"]));
    assert_eq!(stop_since(now + 3600), Value::Null);
}

/// A stop an earlier session recorded is not the current session's until
/// the lane reaches it again: the real `record-if-empty` keeps the standing
/// stop and records it now, and the facts name it.
#[test]
fn lane_status_names_a_kept_post_pr_stop_recorded_again_in_the_lanes_current_session() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    let ok = |args: &[&str]| {
        let out = runner.run(args);
        assert!(out.status.success(), "{args:?}: {}", support::stderr(&out));
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([{
        "item": "KEN-2", "window": "gh-2", "harness": "claude", "status": "running",
        "launch": {}, "session_since": agent_runtime::clock::iso_utc(now - 3600),
    }]);
    runner.write_fleet(&fleet);
    ok(&["state", "init", "--item", "KEN-2"]);
    let remaining = "one unresolved review thread";
    let earlier = json!({
        "name": "review-round-cap", "gate": "review", "remaining": [remaining], "at": now - 7200,
    });
    ok(&[
        "state",
        "set",
        "--item",
        "KEN-2",
        "/post_pr_stop",
        &earlier.to_string(),
    ]);
    let facts = || {
        reply(&runner.run(&["lane", "status", "--item", "KEN-2"]))["result"]["post_pr_stop"].clone()
    };
    assert_eq!(facts(), Value::Null);
    let comment = runner.state_dir().join("stop.md");
    ok(&[
        "state",
        "post-pr-stop",
        "record-if-empty",
        "--item",
        "KEN-2",
        "--name",
        "review-round-cap",
        "--gate",
        "review",
        "--remaining",
        remaining,
        "--comment-file",
        comment.to_str().unwrap(),
    ]);
    let stop = facts();
    assert_eq!(stop["name"], "review-round-cap", "{stop}");
    assert_eq!(stop["gate"], "review", "{stop}");
    assert_eq!(stop["remaining"], json!([remaining]), "{stop}");
}

/// A `pane=local` kind's transport pane holds a shell in its foreground, so
/// the provider's answer is the process proof for both pane kinds and the
/// local pane is judged with it: a shell drawing Codex's idle screen reads
/// `idle`, with one status call and no capture; a provider line naming no
/// `pane` is refused by that key and the lane read unjudged, asking no
/// status.
#[test]
fn lane_status_keeps_a_providers_running_answer_over_a_local_transport_shell() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    install_scripts(&runner);
    let pane = server.open_window(
        "gh-2",
        dir.path(),
        "printf '%s\\n' '› complete' '› Type a prompt'; exec bash --norc --noprofile",
    );
    let provider = orch_package()
        .join("tests")
        .join("fixtures")
        .join("lane-host");
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([{
        "item": "issue-2", "window": "fleet:gh-2", "harness": "codex",
        "host": provider, "status": "running", "mail_root": "/remote/issue-2",
        "launch": {"server": server.pid, "pane": pane}
    }]);
    runner.write_fleet(&fleet);
    let log = dir.path().join("host.log");
    let explicit = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=local";
    let absent = explicit.trim_end_matches("\tpane=local");
    for caps in [explicit, absent] {
        let _ = std::fs::remove_file(&log);
        let env = [
            ("LANE_HOST_STUB_CAPABILITIES", caps),
            ("LANE_HOST_STUB_HARNESS_STATE", "running"),
            ("LANE_HOST_STUB_LOG", log.to_str().unwrap()),
        ];
        let out = runner.run_env(&["lane", "status", "--item", "issue-2"], &env);
        let answer = reply(&out);
        assert_eq!(out.status.code(), Some(0), "{answer}");
        let calls = std::fs::read_to_string(&log).unwrap_or_default();
        let probes = calls
            .lines()
            .filter(|l| l.starts_with("status --item issue-2 --harness codex"))
            .count();
        if caps == explicit {
            assert_eq!(answer["result"]["state"], "idle", "{caps}: {answer}");
            assert_eq!(probes, 1, "{calls}");
        } else {
            assert_eq!(answer["result"]["state"], "unjudged", "{caps}: {answer}");
            assert!(
                answer["result"]["cause"]
                    .as_str()
                    .is_some_and(|c| c.ends_with("cause=capability-invalid key=pane value=")),
                "{answer}"
            );
            assert_eq!(probes, 0, "{calls}");
        }
        assert!(!calls.contains("capture"), "{calls}");
    }
}

/// The counts read the state where the checkout's own files put it: a local
/// repository whose settings file names `records`, with a decoy under
/// `tmp`; a checkout whose private env file outranks its settings file; two
/// worktrees of a real `git worktree add`, each `.git` a gitfile, the state
/// under the main checkout's `records` or `tmp` over decoys in the
/// worktree's own; a hosted checkout whose settings file comes through the
/// provider's `cat`, the state under the clone its `.git` names where its
/// `tmp` holds none, the clone's own `.git` directory and a worktree's
/// gitfile alike.
#[test]
fn lane_status_reads_the_counts_under_the_state_directory_the_lanes_checkout_names() {
    let dir = tempfile::tempdir().unwrap();
    let server = support::Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-record");
    runner.init_fleet();
    install_scripts(&runner);
    let pane = server.open_window("gh-2", dir.path(), "bash --norc --noprofile");
    let counts = r#"{"first_panel":{},"rereview_cycles":1,"pr_comment_review":{"iterations":3,"patched_causes":[{"cause":"a","commit":"aaa111"},{"cause":"a","commit":"bbb222"}]},"stages":[{"kind":"fix"},{"kind":"fix"},{"kind":"fix"}],"restacks":4}"#;
    let decoy = r#"{"stages":[{"kind":"fix"}],"restacks":1}"#;
    let settings = "[env]\nORCH_STATE_DIR = \"records\"\n";
    let plant = |root: &Path, files: &[(&str, &str)]| {
        for (name, text) in files {
            let path = root.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
    };
    // Every `git` here runs under the row's own isolation: no global or
    // system configuration, no maintenance a removal could race.
    let git = |args: &[&str]| {
        let out = support::program("git")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(["-c", "gc.auto=0", "-c", "maintenance.auto=false"])
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", support::stderr(&out));
    };
    let local = dir.path().join("local");
    std::fs::create_dir_all(&local).unwrap();
    git(&["init", "-q", "-b", "main", &local.display().to_string()]);
    plant(
        &local,
        &[
            ("kendex.settings.toml", settings),
            ("records/items/KEN-2/workflow-state-KEN-2.json", counts),
            ("tmp/items/KEN-2/workflow-state-KEN-2.json", decoy),
            ("tmp/lane-status-KEN-2.md", "Step: review\n"),
        ],
    );
    let private = dir.path().join("private");
    plant(
        &private,
        &[
            ("kendex.settings.toml", settings),
            (".env.local", "export ORCH_STATE_DIR=kept\n"),
            ("kept/items/KEN-3/workflow-state-KEN-3.json", counts),
            ("records/items/KEN-3/workflow-state-KEN-3.json", decoy),
        ],
    );
    let main = dir.path().canonicalize().unwrap().join("main");
    std::fs::create_dir_all(&main).unwrap();
    let main_word = main.display().to_string();
    git(&["init", "-q", "-b", "main", &main_word]);
    git(&[
        "-C",
        &main_word,
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "base",
    ]);
    let configured = main.with_file_name("wt-configured");
    let unnamed = main.with_file_name("wt-unnamed");
    for worktree in [&configured, &unnamed] {
        git(&[
            "-C",
            &main_word,
            "worktree",
            "add",
            "-q",
            "--detach",
            &worktree.display().to_string(),
        ]);
    }
    plant(
        &configured,
        &[
            ("kendex.settings.toml", settings),
            ("records/items/KEN-5/workflow-state-KEN-5.json", decoy),
            ("tmp/items/KEN-5/workflow-state-KEN-5.json", decoy),
        ],
    );
    plant(
        &unnamed,
        &[("tmp/items/KEN-6/workflow-state-KEN-6.json", decoy)],
    );
    plant(
        &main,
        &[
            ("records/items/KEN-5/workflow-state-KEN-5.json", counts),
            ("tmp/items/KEN-6/workflow-state-KEN-6.json", counts),
        ],
    );
    let disk = dir.path().join("disk");
    plant(
        &disk.join("remote").join("KEN-4"),
        &[
            (".git/HEAD", "ref: refs/heads/main\n"),
            ("kendex.settings.toml", settings),
            ("records/items/KEN-4/workflow-state-KEN-4.json", counts),
            ("tmp/lane-status-KEN-4.md", "Step: review\n"),
            (
                "tmp/validation-runs",
                "dev-validate-runs-v1\ndev-validate-a\ndev-validate-b\ndev-validate-c\ndev-validate-d\n",
            ),
        ],
    );
    plant(
        &disk.join("remote").join("KEN-7"),
        &[
            (".git", "gitdir: /remote/clone/.git/worktrees/KEN-7\n"),
            ("kendex.settings.toml", settings),
            ("records/items/KEN-7/workflow-state-KEN-7.json", decoy),
        ],
    );
    plant(
        &disk.join("remote").join("clone"),
        &[("records/items/KEN-7/workflow-state-KEN-7.json", counts)],
    );
    let provider = orch_package()
        .join("tests")
        .join("fixtures")
        .join("lane-host");
    let mut fleet = runner.fleet();
    fleet["lanes"] = json!([
        {"item": "KEN-2", "window": "gh-2", "harness": "claude", "status": "running",
         "mail_root": local, "launch": {"pane": pane, "server": server.pid}},
        {"item": "KEN-3", "window": "gh-3", "harness": "claude", "status": "running",
         "mail_root": private, "launch": {"pane": pane, "server": server.pid}},
        {"item": "KEN-4", "window": "fleet:gh-4", "harness": "codex", "host": provider,
         "status": "running", "mail_root": "/remote/KEN-4"},
        {"item": "KEN-5", "window": "gh-5", "harness": "claude", "status": "running",
         "mail_root": configured, "launch": {"pane": pane, "server": server.pid}},
        {"item": "KEN-6", "window": "gh-6", "harness": "claude", "status": "running",
         "mail_root": unnamed, "launch": {"pane": pane, "server": server.pid}},
        {"item": "KEN-7", "window": "fleet:gh-7", "harness": "codex", "host": provider,
         "status": "running", "mail_root": "/remote/KEN-7"},
    ]);
    runner.write_fleet(&fleet);
    let log = dir.path().join("host.log");
    let caps = "kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=plan\tland=lane\tpane=local";
    let status = |item: &str| {
        let env = [
            ("LANE_HOST_STUB_CAPABILITIES", caps),
            ("LANE_HOST_STUB_HARNESS_STATE", "exited"),
            ("LANE_HOST_STUB_DIR", disk.to_str().unwrap()),
            ("LANE_HOST_STUB_LOG", log.to_str().unwrap()),
        ];
        reply(&runner.run_env(&["lane", "status", "--item", item], &env))
    };
    for (item, runs) in [
        ("KEN-2", "unread"),
        ("KEN-3", "unread"),
        ("KEN-4", "4"),
        ("KEN-5", "unread"),
        ("KEN-6", "unread"),
        ("KEN-7", "unread"),
    ] {
        let answer = status(item);
        for (key, want) in [
            ("review_rounds", "5"),
            ("fix_receipts", "3"),
            ("validation_runs", runs),
            ("restacks", "4"),
            ("repeated_class_rounds", "1"),
        ] {
            assert_eq!(answer["result"][key], want, "{item} {key}: {answer}");
        }
        assert_eq!(
            answer["result"]["counts_cause"],
            Value::Null,
            "{item}: {answer}"
        );
    }
    let calls = std::fs::read_to_string(&log).unwrap_or_default();
    for (item, path) in [
        (
            "KEN-4",
            "/remote/KEN-4/tmp/items/KEN-4/workflow-state-KEN-4.json",
        ),
        ("KEN-4", "/remote/KEN-4/.git/HEAD"),
        ("KEN-4", "/remote/KEN-4/kendex.settings.toml"),
        (
            "KEN-4",
            "/remote/KEN-4/records/items/KEN-4/workflow-state-KEN-4.json",
        ),
        ("KEN-7", "/remote/KEN-7/.git"),
        ("KEN-7", "/remote/KEN-7/kendex.settings.toml"),
        (
            "KEN-7",
            "/remote/clone/records/items/KEN-7/workflow-state-KEN-7.json",
        ),
    ] {
        assert!(
            calls.contains(&format!("cat --item {item} {path}")),
            "{path}: {calls}"
        );
    }
    // The facts ask a host only for what they print: no lane status file is
    // read, nor touched where it is absent, as on the second hosted lane's.
    assert!(!calls.contains("lane-status-"), "{calls}");
    let hosted: Vec<&str> = calls
        .lines()
        .filter(|line| line.contains("--item KEN-7"))
        .map(str::trim_end)
        .collect();
    assert_eq!(
        hosted,
        [
            "status --item KEN-7 --harness codex",
            "cat --item KEN-7 /remote/KEN-7/tmp/validation-runs",
            "touch --item KEN-7",
            "cat --item KEN-7 /remote/KEN-7/tmp/items/KEN-7/workflow-state-KEN-7.json",
            "touch --item KEN-7",
            "cat --item KEN-7 /remote/KEN-7/.git",
            "cat --item KEN-7 /remote/KEN-7/kendex.settings.toml",
            "cat --item KEN-7 /remote/KEN-7/.kendex/settings.toml",
            "touch --item KEN-7",
            "cat --item KEN-7 /remote/KEN-7/.env.local",
            "touch --item KEN-7",
            "cat --item KEN-7 /remote/clone/records/items/KEN-7/workflow-state-KEN-7.json",
        ],
        "{calls}"
    );
}
