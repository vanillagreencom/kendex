//! The scheduler core: the identity-bound claim, the duty threads on one
//! fake clock, the event line durable before its baseline row, the failure
//! policy, the per-duty stamps and the `EVENT` grammar. Each row's name
//! carries the defect it catches.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold owned children, write the records they plant and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use agent_runtime::record::FLEET_FILE_NAME;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant, SystemTime};

use agent_runtime::process::Identity;
use agent_runtime::settings::{Roots, Succession};
use orch_runtime::error::Error;
use orch_runtime::schedule::Duty;
use orch_runtime::settings::{self, Flags as SettingsFlags, Settings};
use orch_runtime::watch::events::OverseerCase;
use orch_runtime::watch::{self, Change, Event, Flags, Paths, Produced, Recorded, Runner, Tick};
use serde_json::{Value, json};
use support::*;

/// The settings a runner in `dir` runs under, with the mail interval
/// `mail` seconds; nothing is read from the test's own tree.
fn settings_in(dir: &Path, mail: u64) -> Settings {
    let roots = Roots {
        project: dir.to_path_buf(),
        common: dir.to_path_buf(),
    };
    settings::load(
        &roots,
        &[("ORCH_WATCH_MAIL_INTERVAL".into(), mail.to_string().into())],
        &SettingsFlags {
            state_dir: Some(dir.to_path_buf()),
            private_env: false,
        },
    )
    .unwrap()
}

fn paths_in(dir: &Path) -> Paths {
    Paths::of(&dir.join(FLEET_FILE_NAME)).unwrap()
}

/// This test process's own identity, the one a runner in it claims with.
fn me() -> Identity {
    let pid = std::process::id();
    Identity {
        pid,
        start: start_of(pid),
    }
}

fn recorded() -> Recorded {
    Recorded {
        pane: "none".into(),
        script: "/w/orch-runtime".into(),
        cwd: "/w".into(),
    }
}

fn flags() -> Flags {
    Flags {
        interval: secs(240),
        max_loops: 25,
        since: None,
        replace: None,
        fresh: false,
    }
}

fn runner<'a>(
    dir: &Path,
    clock: &'a FakeClock,
    settings: &Settings,
    identity: Identity,
) -> Runner<'a> {
    Runner::new(
        paths_in(dir),
        clock,
        settings,
        flags(),
        identity,
        recorded(),
    )
    .unwrap()
}

fn log_lines(paths: &Paths) -> Vec<String> {
    std::fs::read_to_string(&paths.log)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// Plant a claim record naming `pid` and `start` on `paths`.
fn plant_claim(paths: &Paths, pid: u32, start: &str) {
    std::fs::write(
        &paths.pid,
        format!(
            "pid={pid}\nstate={}\npane=%1\norigin=hand\nscript=/x\ncwd=/x\nstart={start}\n",
            paths.state.display()
        ),
    )
    .unwrap();
}

/// `watch status` carries what the overseer's turn-end hook reads
/// (`hooks/lane-mail-check.sh`, `watch_status`): the claim's standing, its
/// cwd and origin, and the event log's path.
#[test]
fn watch_status_carries_the_claims_cwd_origin_and_the_log_for_the_hook() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let state = paths.state.display().to_string();
    let holder = Owned::sleep();
    plant_claim(&paths, holder.pid(), &holder.start());
    let out = watch_cmd(dir.path(), &["watch", "status", "--file", &state]);
    let status = reply(&out)["result"].clone();
    assert_eq!(status["claim"]["standing"], "live", "{status}");
    assert_eq!(status["claim"]["cwd"], "/x", "{status}");
    assert_eq!(status["claim"]["origin"], "hand", "{status}");
    assert_eq!(status["log"], paths.log.display().to_string(), "{status}");
    std::fs::remove_file(&paths.pid).unwrap();
    let out = watch_cmd(dir.path(), &["watch", "status", "--file", &state]);
    let status = reply(&out)["result"].clone();
    assert!(status["claim"].is_null(), "no claim: {status}");
    assert_eq!(status["log"], paths.log.display().to_string(), "{status}");
}

/// A claim is judged by its identity, never its pid alone: a claim whose
/// identity reads live is refused `watch-running` and nothing is written; a
/// dead pid and a reused pid under another start are both taken over, each
/// with the event line naming the identity read, and the claim then names
/// the taker.
#[test]
fn a_live_claim_is_refused_and_a_gone_one_is_taken_over_with_an_event_line() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    let sleeper = Owned::sleep();
    // Live: the sleeper's own identity.
    plant_claim(&paths, sleeper.pid(), &sleeper.start());
    let before = std::fs::read_to_string(&paths.pid).unwrap();
    let refused = runner(dir.path(), &clock, &settings, me()).run();
    assert!(
        matches!(&refused, Err(e) if e.key() == "watch-running"),
        "{refused:?}"
    );
    assert_eq!(
        std::fs::read_to_string(&paths.pid).unwrap(),
        before,
        "a refused claim writes nothing"
    );
    assert!(log_lines(&paths).is_empty(), "a refused claim logs nothing");
    // Gone: a dead pid, then the sleeper's pid under another start.
    let rows = [
        (GONE_PID as u32, "ticks:1".to_owned()),
        (sleeper.pid(), "ticks:1".to_owned()),
    ];
    let mut expected_lines = Vec::new();
    for (pid, start) in rows {
        plant_claim(&paths, pid, &start);
        let identity = me();
        let ended = run_driven(
            runner(dir.path(), &clock, &settings, identity.clone()),
            &clock,
            &paths,
            &identity,
            || {
                // The taker writes its claim before it sleeps; a runner that
                // refused never sleeps, and the claim read below then finds
                // the planted record and says so.
                let settle = Instant::now() + secs(10);
                while clock.sleepers() == 0 && Instant::now() < settle {
                    std::thread::sleep(Duration::from_millis(10));
                }
                let claim = watch::claim::read(&paths)
                    .unwrap()
                    .expect("the taker's claim");
                assert_eq!(
                    (claim.pid, claim.start.as_deref()),
                    (identity.pid, Some(identity.start.as_str())),
                    "pid {pid}: the claim names the taker"
                );
            },
        );
        assert!(ended.is_ok(), "pid {pid}: {ended:?}");
        expected_lines.push(format!(
            "EVENT watch-taken-over pid={pid} start={start} reason=gone"
        ));
        assert_eq!(log_lines(&paths), expected_lines, "pid {pid}");
        assert_eq!(
            watch::claim::read(&paths).unwrap(),
            None,
            "pid {pid}: a stopped runner releases its claim"
        );
    }
    assert!(live(sleeper.pid()), "the sleeper was never touched");
}

/// The claim record a released repeat loop writes (`lib/watch-pid.sh`)
/// carries no `start=`, and a loop that ended without its trap leaves it
/// naming a dead pid. A start-less record is read by its pid alone: while
/// the pid runs, `status` answers `unreadable` with cause `start-missing`
/// and a start refuses with nothing written; once no process holds it, the
/// record reads `gone` and is taken over with `start=none` on the line.
#[test]
fn a_start_less_record_is_unreadable_while_its_pid_runs_and_taken_over_once_it_is_dead() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    let plant = |pid: u32| {
        std::fs::write(
            &paths.pid,
            format!(
                "pid={pid}\nstate={}\npane=%1\norigin=hand\nscript=/x/oversee-watch\ncwd=/x\n",
                paths.state.display()
            ),
        )
        .unwrap();
    };
    let holder = Owned::sleep();
    plant(holder.pid());
    let before = std::fs::read_to_string(&paths.pid).unwrap();
    let standing = watch::status(&paths).unwrap().claim.expect("the claim");
    assert_eq!(
        (standing.standing, standing.cause.as_deref(), standing.start),
        ("unreadable", Some("start-missing"), None)
    );
    let refused = runner(dir.path(), &clock, &settings, me()).run();
    assert!(
        matches!(&refused, Err(e) if e.key() == "watch-claim-unreadable"),
        "{refused:?}"
    );
    assert_eq!(
        std::fs::read_to_string(&paths.pid).unwrap(),
        before,
        "a refused start writes nothing"
    );
    assert!(log_lines(&paths).is_empty(), "a refused start logs nothing");
    assert!(live(holder.pid()), "the holder was never touched");
    drop(holder);
    plant(GONE_PID as u32);
    let dead = watch::status(&paths).unwrap().claim.expect("the claim");
    assert_eq!((dead.standing, dead.start), ("gone", None));
    let identity = me();
    let ended = run_driven(
        runner(dir.path(), &clock, &settings, identity.clone()),
        &clock,
        &paths,
        &identity,
        || clock.await_sleepers(1),
    );
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(
        log_lines(&paths),
        vec![format!(
            "EVENT watch-taken-over pid={GONE_PID} start=none reason=gone"
        )]
    );
    assert_eq!(
        watch::claim::read(&paths).unwrap(),
        None,
        "the taker released its claim"
    );
}

/// Two runners started together on one fleet state: exactly one claims, the
/// other refuses `watch-running` naming the winner, and the record names
/// the winner until it is stopped.
#[test]
fn two_starts_together_claim_once() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    // Two live identities in one test process: this process and a sleeper.
    let sleeper = Owned::sleep();
    let contenders = [
        me(),
        Identity {
            pid: sleeper.pid(),
            start: sleeper.start(),
        },
    ];
    let barrier = Barrier::new(2);
    // Nothing inside the scope panics or stops driving the clock: a runner
    // left waiting on a fake-clock sleep would hold the scope's join. The
    // stop goes to the claim's holder once the other runner has returned;
    // the clock is released until both have ended, and how long that took
    // is judged after the scope.
    let (results, stopped, elapsed): (Vec<Result<watch::Ended, Error>>, bool, Duration) =
        std::thread::scope(|s| {
            let handles: Vec<_> = contenders
                .iter()
                .map(|identity| {
                    let runner = runner(dir.path(), &clock, &settings, identity.clone());
                    let barrier = &barrier;
                    s.spawn(move || {
                        barrier.wait();
                        runner.run()
                    })
                })
                .collect();
            let started = Instant::now();
            let mut stopped = false;
            while !handles.iter().all(|h| h.is_finished()) {
                if !stopped
                    && handles.iter().any(|h| h.is_finished())
                    && let Ok(Some(claim)) = watch::claim::read(&paths)
                    && let Some(winner) = contenders.iter().find(|c| claim.names(c))
                {
                    stopped = watch::claim::request_stop(&paths, winner).is_ok();
                }
                clock.release(secs(1));
                std::thread::sleep(Duration::from_millis(20));
            }
            let elapsed = started.elapsed();
            let results = handles
                .into_iter()
                .map(|h| h.join().expect("a runner thread"))
                .collect();
            (results, stopped, elapsed)
        });
    assert!(stopped, "no stop reached the claim's holder: {results:?}");
    assert!(
        elapsed < secs(30),
        "the runners ended {elapsed:?} after their start: {results:?}"
    );
    let won: Vec<_> = results.iter().filter(|r| r.is_ok()).collect();
    let lost: Vec<_> = results.iter().filter(|r| r.is_err()).collect();
    assert_eq!((won.len(), lost.len()), (1, 1), "{results:?}");
    let Err(refusal) = lost[0] else {
        unreachable!()
    };
    assert_eq!(refusal.key(), "watch-running", "{refusal}");
    assert_eq!(
        watch::claim::read(&paths).unwrap(),
        None,
        "the winner released its claim on the stop"
    );
    assert!(live(sleeper.pid()));
}

/// A runner re-reads its claim, so a claim rewritten under it ends it
/// within a slice as `watch-claim-moved`, and the record stands as
/// rewritten.
#[test]
fn a_claim_rewritten_under_a_runner_ends_it_without_touching_the_record() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    let identity = me();
    let ended = run_driven(
        runner(dir.path(), &clock, &settings, identity.clone()),
        &clock,
        &paths,
        &identity,
        || {
            clock.await_sleepers(1);
            plant_claim(&paths, GONE_PID as u32, "ticks:1");
            clock.release(secs(1));
        },
    );
    assert!(
        matches!(&ended, Err(e) if e.key() == "watch-claim-moved"),
        "{ended:?}"
    );
    let standing = watch::claim::read(&paths)
        .unwrap()
        .expect("the rewritten record");
    assert_eq!(
        (standing.pid, standing.start.as_deref()),
        (GONE_PID as u32, Some("ticks:1")),
        "the moved runner removed nothing"
    );
}

/// The busy-mail sequence: a mail interval under the tick, a mail event every
/// 7 s tick for `ticks` ticks, the verification slot registered; the
/// counters of both. The runner is stopped at the end.
fn busy_mail_run(dir: &Path, clock: &FakeClock, ticks: usize) -> (Counting, Counting) {
    let paths = paths_in(dir);
    let settings = settings_in(dir, 5);
    let mail = Counting::new();
    let verification = Counting::new();
    let mut runner = runner(dir, clock, &settings, me());
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
        Duty::Verification,
        verification.body(|_| Produced::default()),
    );
    let identity = me();
    let ended = run_driven(runner, clock, &paths, &identity, || {
        clock.await_sleepers(2);
        for _ in 0..ticks {
            clock.pass(secs(7));
        }
    });
    assert!(ended.is_ok(), "{ended:?}");
    (mail, verification)
}

/// The simulated verification run times under the busy-mail sequence up to
/// `until` seconds: each run at the first 7 s tick at or past its due time,
/// counted from its last start.
fn verification_ticks(until: u64) -> Vec<u64> {
    let mut expected = Vec::new();
    let mut due: u64 = 0;
    while due <= until {
        let tick = due.div_ceil(7) * 7;
        expected.push(tick);
        due = tick + 240;
    }
    expected
}

/// Under one mail event every 7 s for 7000 s of fake time, the heartbeat
/// fires once, at the first tick at or past its due time (6000 s), and the
/// verification slot runs at every first tick at or past each 240 s due
/// time, counted from its last start.
#[test]
fn busy_mail_moves_neither_the_heartbeat_nor_the_verification_due_times() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let clock = FakeClock::new();
    let start_wall = clock.wall_secs();
    let (mail, verification) = busy_mail_run(dir.path(), &clock, 1000);
    assert_eq!(
        mail.runs(),
        1001,
        "one mail run per tick, the first at start"
    );
    let lines = log_lines(&paths);
    let heartbeats: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with("EVENT heartbeat "))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(heartbeats.len(), 1, "one heartbeat in 7000 s: {lines:?}");
    assert_eq!(
        lines[heartbeats[0]],
        "EVENT heartbeat loops=25 interval=240s since=none"
    );
    let baseline = watch::Baseline::load(&paths.baseline).unwrap();
    // 6000 s due; the ticks land on multiples of 7, the first at or past
    // 6000 being 6006.
    assert_eq!(
        baseline.passes.get(&Duty::Heartbeat),
        Some(&(start_wall + 6006))
    );
    let expected: Vec<u64> = verification_ticks(7000)
        .into_iter()
        .map(|t| start_wall + t)
        .collect();
    assert_eq!(verification.at(), expected);
    assert_eq!(expected.len(), 29);
}

/// Each long duty keeps a pass stamp of its own, which the heartbeat never
/// moves, so a restart resumes each duty from its own stamp.
#[test]
fn a_restart_resumes_each_duty_from_its_own_stamp() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 5);
    let clock = FakeClock::new();
    let start_wall = clock.wall_secs();
    // The busy-mail sequence to 6006 s: the heartbeat has fired, and the
    // verification slot last ran at 5880 s with its next due at 6120 s.
    let (_, verification) = busy_mail_run(dir.path(), &clock, 858);
    let last = *verification.at().last().unwrap();
    assert_eq!(last, start_wall + 5880);
    let baseline = watch::Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.passes.get(&Duty::Heartbeat),
        Some(&(start_wall + 6006))
    );
    assert_eq!(baseline.passes.get(&Duty::Verification), Some(&last));
    // The restart, a few seconds on (the stop's releases moved the clock).
    let restarted_at = clock.wall_secs();
    assert!(restarted_at > start_wall + 6006 && restarted_at < start_wall + 6120);
    let verification = Counting::new();
    let mail = Counting::new();
    let mut again = runner(dir.path(), &clock, &settings, me());
    again.register(Duty::Mail, mail.body(|_| Produced::default()));
    again.register(
        Duty::Verification,
        verification.body(|_| Produced::default()),
    );
    let identity = me();
    let ended = run_driven(again, &clock, &paths, &identity, || {
        clock.await_sleepers(2);
        assert_eq!(
            verification.at(),
            Vec::<u64>::new(),
            "not due at the restart"
        );
        clock.pass(secs(start_wall + 6120 - restarted_at));
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(
        verification.at(),
        vec![start_wall + 6120],
        "verification ran at its own next due"
    );
    assert_eq!(
        log_lines(&paths)
            .iter()
            .filter(|l| l.starts_with("EVENT heartbeat "))
            .count(),
        1,
        "the heartbeat's own stamp stands: no second heartbeat"
    );
}

/// The tracker body blocks on a FIFO while the clock passes 60 s in three
/// mail intervals: three more mail runs complete while the tracker's has
/// not.
#[test]
fn a_tracker_duty_held_on_a_fifo_delays_no_mail_run() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    let fifo = dir.path().join("tracker.fifo");
    mkfifo(&fifo);
    let mail = Counting::new();
    let tracker = Counting::new();
    let held: Arc<AtomicUsize> = Arc::new(AtomicUsize::new(0));
    let completed = tracker.runs.clone();
    let hold = fifo.clone();
    let held_in = held.clone();
    let mut runner = runner(dir.path(), &clock, &settings, me());
    runner.register(Duty::Mail, mail.body(|_| Produced::default()));
    runner.register(
        Duty::Tracker,
        Box::new(move |_tick: &Tick| {
            held_in.fetch_add(1, Ordering::SeqCst);
            // Blocks until the test opens the writing end.
            let _ = std::fs::read_to_string(&hold);
            completed.fetch_add(1, Ordering::SeqCst);
            Ok(Produced::default())
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        // The tracker is in its body and the first mail turn is done.
        let deadline = Instant::now() + secs(10);
        while held.load(Ordering::SeqCst) == 0 || mail.runs() == 0 {
            assert!(Instant::now() < deadline, "the tracker never started");
            std::thread::sleep(Duration::from_millis(10));
        }
        // The mail thread goes to sleep on the clock; a mail turn behind
        // the held tracker never does, and this wait ends at its bound so
        // the count below is what judges it.
        let settle = Instant::now() + secs(2);
        while clock.sleepers() == 0 && Instant::now() < settle {
            std::thread::sleep(Duration::from_millis(10));
        }
        for _ in 0..3 {
            clock.pass(secs(20));
        }
        let mail_runs = mail.runs();
        let tracker_runs = tracker.runs();
        release_hold(&fifo, secs(10), || {
            "the tracker body never reached its hold".into()
        });
        assert!(
            mail_runs >= 4,
            "mail ran at start and at each of three intervals while the tracker was held: {mail_runs}"
        );
        assert_eq!(tracker_runs, 0, "the tracker was still held after 60 s");
        // The released tracker commits and goes back to sleep beside the
        // mail thread; a stop wakes only threads already asleep.
        clock.await_sleepers(2);
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(tracker.runs(), 1);
}

/// Under `ORCH_WATCH_MAIL_INTERVAL=0`, the mail duty runs once per slice:
/// at start and once more for each second passed.
#[test]
fn a_zero_mail_interval_runs_the_mail_duty_once_per_slice() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 0);
    assert_eq!(settings.watch.get().unwrap().mail_interval, Duration::ZERO);
    let clock = FakeClock::new();
    let mail = Counting::new();
    let mut runner = runner(dir.path(), &clock, &settings, me());
    runner.register(Duty::Mail, mail.body(|_| Produced::default()));
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(2);
        for _ in 0..3 {
            clock.pass(secs(1));
        }
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(mail.runs(), 4, "one run at start and one per slice");
}

/// A body that fails twice then succeeds: the first failure's
/// `watch-step-failed` line (the second is under the repeat rule, the row
/// below), mail running throughout, and the third run's own line; the run
/// goes on until it is stopped.
#[test]
fn a_failing_body_is_a_counted_line_and_the_run_goes_on() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    let mail = Counting::new();
    let tracker = Counting::new();
    let mut runner = runner(dir.path(), &clock, &settings, me());
    runner.register(Duty::Mail, mail.body(|_| Produced::default()));
    let failures = Arc::new(AtomicUsize::new(0));
    let failing = failures.clone();
    runner.register(
        Duty::Tracker,
        tracker.body_result(move |_| {
            if failing.fetch_add(1, Ordering::SeqCst) < 2 {
                return Err(Error::Runtime(agent_runtime::Error::RecordMissing {
                    path: PathBuf::from("/x/tracker"),
                }));
            }
            Ok(Produced {
                events: vec![Event::Handoff {
                    item: "KEN-9".into(),
                }],
                ..Produced::default()
            })
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(2);
        clock.pass(secs(240));
        clock.pass(secs(240));
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(
        log_lines(&paths),
        vec![
            "EVENT watch-step-failed step=tracker count=1",
            "EVENT handoff KEN-9",
        ]
    );
    assert_eq!(tracker.runs(), 3, "the duty kept its cadence");
    assert!(
        mail.runs() >= 3,
        "mail ran at start and after each failure: {}",
        mail.runs()
    );
    let baseline = watch::Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.passes.get(&Duty::Tracker),
        Some(&tracker.at()[2]),
        "the stamp is the successful run's"
    );
}

/// Under `ORCH_OVERSEER_MARK_REPEAT=3`, a body failing on every one of
/// seven runs is said at the first, third and sixth; a body whose first and
/// third runs hand back a line and a cause has its line, then the failure
/// line, and its pass stamped before any clean run; its clean second run
/// ends the count, so the third is said as a first failure again. The
/// failing duty keeps its cadence from its anchor.
#[test]
fn a_standing_failure_repeats_its_line_on_the_mark_repeat_rule() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let roots = Roots {
        project: dir.path().to_path_buf(),
        common: dir.path().to_path_buf(),
    };
    let settings = settings::load(
        &roots,
        &[
            ("ORCH_WATCH_MAIL_INTERVAL".into(), "20".into()),
            ("ORCH_OVERSEER_MARK_REPEAT".into(), "3".into()),
        ],
        &SettingsFlags {
            state_dir: Some(dir.path().to_path_buf()),
            private_env: false,
        },
    )
    .unwrap();
    let clock = FakeClock::new();
    let mail = Counting::new();
    let tracker = Counting::new();
    let report = Counting::new();
    let mut runner = runner(dir.path(), &clock, &settings, me());
    runner.register(Duty::Mail, mail.body(|_| Produced::default()));
    runner.register(
        Duty::Tracker,
        tracker.body_result(|_| {
            Err(Error::Runtime(agent_runtime::Error::RecordMissing {
                path: PathBuf::from("/x/tracker"),
            }))
        }),
    );
    let partial = Arc::new(AtomicUsize::new(0));
    let first = partial.clone();
    runner.register(
        Duty::Report,
        report.body(move |_| {
            if matches!(first.fetch_add(1, Ordering::SeqCst), 0 | 2) {
                Produced {
                    events: vec![Event::Handoff {
                        item: "KEN-1".into(),
                    }],
                    failed: Some("a span that could not be read".into()),
                    ..Produced::default()
                }
            } else {
                Produced::default()
            }
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(2);
        let baseline = watch::Baseline::load(&paths.baseline).unwrap();
        assert_eq!(
            baseline.passes.get(&Duty::Report),
            Some(&report.at()[0]),
            "a run that fails in part is stamped before any clean run"
        );
        assert_eq!(baseline.passes.get(&Duty::Tracker), None);
        for _ in 0..6 {
            clock.pass(secs(240));
        }
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(tracker.runs(), 7, "one run at start and one per cadence");
    assert_eq!(report.runs(), 7);
    assert_eq!(
        log_lines(&paths),
        vec![
            "EVENT watch-step-failed step=tracker count=1",
            "EVENT handoff KEN-1",
            "EVENT watch-step-failed step=report count=1",
            "EVENT watch-step-failed step=tracker count=3",
            "EVENT handoff KEN-1",
            "EVENT watch-step-failed step=report count=1",
            "EVENT watch-step-failed step=tracker count=6",
        ]
    );
    let baseline = watch::Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.passes.get(&Duty::Tracker),
        None,
        "a run that fails whole earns no pass stamp"
    );
    assert_eq!(
        tracker.at()[1] - tracker.at()[0],
        240,
        "the failing duty keeps its cadence from its anchor"
    );
}

/// A body asking for a run 1 s later gets it, and the regular cadence
/// resumes from that run.
#[test]
fn a_body_asking_for_an_earlier_run_gets_it_and_the_cadence_resumes() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    let start_wall = clock.wall_secs();
    let tracker = Counting::new();
    let mut runner = runner(dir.path(), &clock, &settings, me());
    let asked = Arc::new(AtomicUsize::new(0));
    let asking = asked.clone();
    runner.register(
        Duty::Tracker,
        tracker.body(move |tick| Produced {
            next_due: (asking.fetch_add(1, Ordering::SeqCst) == 0).then(|| tick.now + secs(1)),
            ..Produced::default()
        }),
    );
    let identity = me();
    let ended = run_driven(runner, &clock, &paths, &identity, || {
        clock.await_sleepers(1);
        clock.pass(secs(1));
        clock.pass(secs(239));
        clock.pass(secs(1));
    });
    assert!(ended.is_ok(), "{ended:?}");
    assert_eq!(
        tracker.at(),
        vec![start_wall, start_wall + 1, start_wall + 241]
    );
}

/// The baseline write is made to fail where a crash would land, after the
/// log's append and sync: the line is on disk and the row unmoved; the next
/// run finds the same news and prints the line once more; the run after
/// that, at the duty's next due time, finds the moved row, runs and prints
/// nothing.
#[test]
fn an_event_line_is_durable_before_its_baseline_row_and_a_crash_between_reprints_it_once() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    let tracker = Counting::new();
    // A duty that reports an item's handoff until its row says it did.
    let body = || -> watch::Body<'static> {
        tracker.body(|tick: &Tick| match tick.baseline.get("handoff", "KEN-9") {
            None => Produced {
                events: vec![Event::Handoff {
                    item: "KEN-9".into(),
                }],
                changes: vec![Change::Set {
                    kind: "handoff".into(),
                    identity: "KEN-9".into(),
                    value: "h1".into(),
                }],
                ..Produced::default()
            },
            Some(_) => Produced::default(),
        })
    };
    let line = "EVENT handoff KEN-9".to_owned();
    // The crash point: the baseline's temporary file cannot be written,
    // because a directory stands where it goes; the log, open already, can.
    let blocked = paths.baseline.with_extension("json.tmp");
    std::fs::create_dir(&blocked).unwrap();
    let mut first = runner(dir.path(), &clock, &settings, me());
    first.register(Duty::Tracker, body());
    let crashed = first.run();
    assert!(
        matches!(&crashed, Err(e) if e.key() == "watch-record"),
        "{crashed:?}"
    );
    assert_eq!(log_lines(&paths), vec![line.clone()], "the line is on disk");
    assert!(
        std::fs::metadata(&paths.baseline).is_err(),
        "the row never moved: no baseline was written"
    );
    assert_eq!(tracker.runs(), 1);
    std::fs::remove_dir(&blocked).unwrap();
    // The second run reprints at once (no stamp survived the crash); the
    // third is due one cadence after the second's stamp.
    for (round, advance) in [(2, None), (3, Some(secs(240)))] {
        let mut again = runner(dir.path(), &clock, &settings, me());
        again.register(Duty::Tracker, body());
        let identity = me();
        let ended = run_driven(again, &clock, &paths, &identity, || {
            clock.await_sleepers(1);
            if let Some(advance) = advance {
                assert_eq!(tracker.runs(), 2, "round 3: not due at the restart");
                clock.pass(advance);
            }
        });
        assert!(ended.is_ok(), "round {round}: {ended:?}");
        assert_eq!(tracker.runs(), round, "round {round}: the body ran");
        assert_eq!(
            log_lines(&paths),
            vec![line.clone(); 2],
            "round {round}: printed once more, then nothing"
        );
        let baseline = watch::Baseline::load(&paths.baseline).unwrap();
        assert_eq!(
            baseline.get("handoff", "KEN-9"),
            Some("h1"),
            "round {round}"
        );
    }
}

/// Every variant against the line the controller session parses (the
/// suites' pinned heartbeat lines among them), and this runtime's own lines
/// as it defines them.
#[test]
fn every_event_renders_to_its_recorded_bytes() {
    let s = |text: &str| text.to_owned();
    let rows: Vec<(Event, &str)> = vec![
        (
            Event::Heartbeat {
                loops: 1,
                interval: secs(0),
                since: None,
            },
            "EVENT heartbeat loops=1 interval=0s since=none",
        ),
        (
            Event::Heartbeat {
                loops: 1,
                interval: secs(0),
                since: Some(s("2026-01-01T00:00:00Z")),
            },
            "EVENT heartbeat loops=1 interval=0s since=2026-01-01T00:00:00Z",
        ),
        (
            Event::Heartbeat {
                loops: 25,
                interval: secs(240),
                since: None,
            },
            "EVENT heartbeat loops=25 interval=240s since=none",
        ),
        (
            Event::WatchStepFailed {
                step: Duty::Tracker,
                count: 3,
            },
            "EVENT watch-step-failed step=tracker count=3",
        ),
        (
            Event::ReconcileRefused {
                intent: s("close-resources:KEN-GONE:1-1"),
                refusal: s("lane-missing"),
            },
            "EVENT reconcile-refused intent=close-resources:KEN-GONE:1-1 refusal=lane-missing",
        ),
        (
            Event::NoticeUnmarked {
                intent: s("request-transfer:overseer:3:1-1"),
                cause: s("set-replaced"),
            },
            "EVENT notice-unmarked intent=request-transfer:overseer:3:1-1 cause=set-replaced",
        ),
        (
            Event::DirectiveSendUnsettled {
                item: s("CC-1"),
                cause: s("receipt-missing"),
            },
            "EVENT directive-send-unsettled item=CC-1 cause=receipt-missing",
        ),
        (
            Event::LaneClosed {
                item: s("KEN-4687"),
            },
            "EVENT lane-closed KEN-4687",
        ),
        (
            Event::LaneCloseRefused {
                item: s("KEN-4687"),
            },
            "EVENT lane-close-refused KEN-4687",
        ),
        (Event::Triage { id: s("KEN-4700") }, "EVENT triage KEN-4700"),
        (
            Event::Handoff {
                item: s("KEN-4687"),
            },
            "EVENT handoff KEN-4687",
        ),
        (
            Event::WindowGone { lane: s("gh-3") },
            "EVENT window-gone gh-3",
        ),
        (
            Event::LaneExited { lane: s("gh-3") },
            "EVENT lane-exited gh-3",
        ),
        (
            Event::DirectiveRead {
                item: s("KEN-4687"),
                id: s("d-17"),
            },
            "EVENT directive-read KEN-4687 d-17",
        ),
        (
            Event::DirectiveUnread {
                item: s("KEN-4687"),
                id: s("d-17"),
                age: 301,
            },
            "EVENT directive-unread KEN-4687 d-17 age=301",
        ),
        (
            Event::StartStalled {
                item: s("KEN-4687"),
                age: 601,
            },
            "EVENT start-stalled KEN-4687 age=601",
        ),
        (
            Event::IdleUnread { lane: s("gh-3") },
            "EVENT idle-unread gh-3",
        ),
        (
            Event::WatchTakenOver {
                pid: 4242,
                start: Some(s("ticks:9")),
                reason: watch::Takeover::Gone,
            },
            "EVENT watch-taken-over pid=4242 start=ticks:9 reason=gone",
        ),
        (
            Event::WatchTakenOver {
                pid: 4242,
                start: Some(s("ticks:9")),
                reason: watch::Takeover::Replace,
            },
            "EVENT watch-taken-over pid=4242 start=ticks:9 reason=replace",
        ),
        // The wake duty's own lines.
        (
            Event::WakeDelivered {
                target: s("KEN-1"),
                resume: None,
            },
            "EVENT wake-delivered KEN-1",
        ),
        (
            Event::WakeUnconfirmed {
                target: s("overseer"),
                cause: s("turn-pending"),
                resume: None,
            },
            "EVENT wake-unconfirmed overseer cause=turn-pending",
        ),
        (
            Event::WakeLimit {
                target: s("KEN-1"),
                harness: s("codex"),
                cause: s("session-unbound"),
                resume: None,
            },
            "EVENT wake-limit KEN-1 harness=codex cause=session-unbound",
        ),
        (
            Event::LaneReady { item: s("KEN-1") },
            "EVENT lane-ready KEN-1",
        ),
        (
            Event::LanePrepareStuck {
                item: s("KEN-1"),
                age: 1801,
                log: s("/t/prep.log"),
                reason: None,
            },
            "EVENT lane-prepare-stuck KEN-1 age=1801s log=/t/prep.log",
        ),
        (
            Event::LanePrepareStuck {
                item: s("KEN-1"),
                age: 1801,
                log: s("/t/relaunch.log"),
                reason: Some(s("relaunch-pending")),
            },
            "EVENT lane-prepare-stuck KEN-1 age=1801s log=/t/relaunch.log reason=relaunch-pending",
        ),
        (
            Event::LanePrepareFailed {
                item: s("KEN-1"),
                reason: s("wait-failed"),
                exit: None,
                log: s("/t/prep.log"),
            },
            "EVENT lane-prepare-failed KEN-1 reason=wait-failed log=/t/prep.log",
        ),
        (
            Event::LanePrepareFailed {
                item: s("KEN-1"),
                reason: s("relaunch-failed"),
                exit: Some(3),
                log: s("/t/relaunch.log"),
            },
            "EVENT lane-prepare-failed KEN-1 reason=relaunch-failed exit=3 log=/t/relaunch.log",
        ),
        (
            Event::ParkedMerged {
                item: s("KEN-1"),
                pr: s("5898"),
                repo: s("vanillagreencom/kendex"),
            },
            "EVENT parked-merged KEN-1 pr=5898 repo=vanillagreencom/kendex",
        ),
        (
            Event::ParkedClosed {
                item: s("KEN-1"),
                pr: s("5898"),
                repo: s("vanillagreencom/kendex"),
            },
            "EVENT parked-closed KEN-1 pr=5898 repo=vanillagreencom/kendex",
        ),
        (
            Event::Merged {
                line: s("5898 kendex/refresh vanillagreencom/kendex"),
            },
            "EVENT merged 5898 kendex/refresh vanillagreencom/kendex",
        ),
        (
            Event::MainWorkflowAbsent {
                repo: s("vanillagreencom/kendex"),
                workflow: s("ci.yml"),
                cause: s("not-found"),
            },
            "EVENT main-workflow-absent vanillagreencom/kendex workflow=ci.yml cause=not-found",
        ),
        (
            Event::MainPushFailing {
                repo: s("vanillagreencom/kendex"),
                workflow: s("ci.yml"),
                event: s("push"),
                run: s("1234"),
                range: Some((s("b2"), s("a1"))),
                jobs: s("guards,tests"),
                cause: s("failure"),
            },
            "EVENT main-push-failing vanillagreencom/kendex workflow=ci.yml event=push run=1234 head=b2 since=a1 jobs=guards,tests cause=failure",
        ),
        (
            Event::MainPushFailing {
                repo: s("vanillagreencom/kendex"),
                workflow: s("ci.yml"),
                event: s("schedule"),
                run: s("1235"),
                range: None,
                jobs: s("guards"),
                cause: s("failure"),
            },
            "EVENT main-push-failing vanillagreencom/kendex workflow=ci.yml event=schedule run=1235 jobs=guards cause=failure",
        ),
        (
            Event::MainPushBudget {
                repo: s("vanillagreencom/kendex"),
                run: s("1234"),
                warnings: s("[\"budget\"]"),
            },
            "EVENT main-push-budget vanillagreencom/kendex workflow=skill-tests.yml run=1234 warnings=[\"budget\"]",
        ),
        (
            Event::RefreshFailing {
                repo: s("vanillagreencom/kendex"),
                last: s("1234"),
                since: s("2026-01-01T00:00:00Z"),
                report: s("initial"),
                cause: s("failure"),
            },
            "EVENT refresh-failing vanillagreencom/kendex runs=2 last=1234 since=2026-01-01T00:00:00Z report=initial cause=failure",
        ),
        (
            Event::LaneStalled {
                item: s("KEN-1"),
                age: 3601,
                state: None,
            },
            "EVENT lane-stalled KEN-1 age=3601",
        ),
        // The hosted readings' lines; the state word a ready pull request adds.
        (
            Event::LaneStalled {
                item: s("CC-1"),
                age: 0,
                state: Some(s("finished")),
            },
            "EVENT lane-stalled CC-1 age=0 state=finished",
        ),
        // The bytes `references/oversee-events.md` names.
        (
            Event::CloudStallClosed {
                item: s("CC-1"),
                directive_age: 1900,
            },
            "EVENT cloud-stall-closed CC-1 directive_age=1900",
        ),
        (
            Event::OwnerAskResolved {
                re: s("a-7"),
                by: s("text"),
                id: s("m-9"),
            },
            "EVENT owner-ask-resolved a-7 by=text id=m-9",
        ),
        (
            Event::OwnerAskClosed {
                re: s("a-7"),
                by: s("explicit"),
            },
            "EVENT owner-ask-closed a-7 by=explicit",
        ),
        (Event::OwnerNote { id: s("m-9") }, "EVENT owner-note m-9"),
        (
            Event::PeerNote {
                repository: s("vanillagreencom/other"),
                id: s("m-9"),
                kind: s("peer"),
                re: None,
            },
            "EVENT peer-note vanillagreencom/other m-9 kind=peer",
        ),
        (
            Event::PeerNote {
                repository: s("vanillagreencom/other"),
                id: s("m-9"),
                kind: s("peer"),
                re: Some(s("m-2")),
            },
            "EVENT peer-note vanillagreencom/other m-9 kind=peer re=m-2",
        ),
        (
            Event::LaneQuestion {
                item: s("KEN-1"),
                id: s("m-9"),
            },
            "EVENT lane-question KEN-1 m-9",
        ),
        (
            Event::LaneNotice {
                item: s("KEN-1"),
                id: s("m-9"),
            },
            "EVENT lane-notice KEN-1 m-9",
        ),
        (
            Event::OverseerMark {
                pane: s("%7"),
                kind: s("account"),
                value: s("97"),
                mark: s("headroom"),
                succession: Succession::Off,
            },
            "EVENT overseer-mark %7 kind=account value=97 mark=headroom succession=off",
        ),
        (
            Event::OverseerContextStale {
                pane: s("%7"),
                age: 3601,
            },
            "EVENT overseer-context-stale %7 age=3601",
        ),
        (
            Event::OverseerContextUnmeasured {
                pane: s("%7"),
                gap: s("3"),
            },
            "EVENT overseer-context-unmeasured %7 gap=3",
        ),
        (
            Event::OverseerSession {
                case: OverseerCase::Dead,
                pane: s("%7"),
                window: s("@3"),
                passes: 2,
                succession: Succession::On,
                source: s("pane"),
                cause: None,
                record: None,
            },
            "EVENT overseer-dead %7 window=@3 passes=2 succession=on source=pane",
        ),
        (
            Event::OverseerSession {
                case: OverseerCase::Dead,
                pane: s("%7"),
                window: s("@3"),
                passes: 2,
                succession: Succession::On,
                source: s("process"),
                cause: Some("memory-cap"),
                record: Some(s("none")),
            },
            "EVENT overseer-dead %7 window=@3 passes=2 succession=on source=process cause=memory-cap record=none",
        ),
        (
            Event::OverseerSession {
                case: OverseerCase::Walled,
                pane: s("%7"),
                window: s("@3"),
                passes: 1,
                succession: Succession::On,
                source: s("rows"),
                cause: None,
                record: None,
            },
            "EVENT overseer-walled %7 window=@3 passes=1 succession=on source=rows",
        ),
        (
            Event::OverseerSession {
                case: OverseerCase::Reserve,
                pane: s("%7"),
                window: s("@3"),
                passes: 1,
                succession: Succession::Off,
                source: s("rows"),
                cause: None,
                record: Some(s("none")),
            },
            "EVENT overseer-reserve %7 window=@3 passes=1 succession=off source=rows record=none",
        ),
        (
            Event::LaneRelaunched {
                item: s("KEN-1"),
                lane: s("a2"),
                from: s("a1"),
            },
            "EVENT lane-relaunched KEN-1 lane=a2 from=a1",
        ),
        (
            Event::LaneAsking {
                lane: s("gh-3"),
                note: None,
            },
            "EVENT lane-asking gh-3",
        ),
        (
            Event::LaneAsking {
                lane: s("gh-3"),
                note: Some(s("session-record=none")),
            },
            "EVENT lane-asking gh-3 session-record=none",
        ),
        (
            Event::ModelCapacity { lane: s("gh-3") },
            "EVENT model-capacity gh-3",
        ),
        (
            Event::IdleAfterReturn {
                lane: s("gh-3"),
                note: Some(s("stop-cause=allow-all-blocked-by-policy")),
            },
            "EVENT idle-after-return gh-3 stop-cause=allow-all-blocked-by-policy",
        ),
        (
            Event::Account {
                fields: s("a1 harness=claude status=ok verdict=walled"),
                change: s("verdict,reset"),
                was_status: s("ok"),
                was_verdict: s("room"),
            },
            "EVENT account a1 harness=claude status=ok verdict=walled change=verdict,reset was=ok/room",
        ),
        (
            Event::VerifyingDeadline {
                id: s("KEN-1"),
                row: s("boxes=0"),
            },
            "EVENT verifying-deadline KEN-1 boxes=0",
        ),
        (
            Event::VerifyingDeadline {
                id: s("KEN-1"),
                row: s("box=2 trigger={\"kind\":\"ci\"} status=due deadline=2026-01-01T00:00:00Z"),
            },
            "EVENT verifying-deadline KEN-1 box=2 trigger={\"kind\":\"ci\"} status=due deadline=2026-01-01T00:00:00Z",
        ),
        // The observation duty's lines.
        (
            Event::UsageLimit {
                passed: false,
                line: s("gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z"),
            },
            "EVENT usage-limit gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z",
        ),
        (
            Event::UsageLimit {
                passed: true,
                line: s("gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z"),
            },
            "EVENT usage-limit-passed gh-2 /home/me/.eclaude resets=2026-10-04T18:00:00Z",
        ),
        (
            Event::UsageLimit {
                passed: false,
                line: s("gh-2 wall_kind=auth"),
            },
            "EVENT usage-limit gh-2 wall_kind=auth",
        ),
        // this runtime's own
        (
            Event::StrayWindow {
                pane: s("%7"),
                window: s("@3"),
                server: 41020,
                name: s("gh-9"),
            },
            "EVENT stray-window %7 window=@3 server=41020 name=gh-9",
        ),
        (
            Event::Tail(s("⏺ Working through the queue.")),
            "⏺ Working through the queue.",
        ),
        (
            Event::LaneUnreadable {
                lane: s("gh-3"),
                cause: s("server-unreachable"),
            },
            "EVENT lane-unreadable gh-3 cause=server-unreachable",
        ),
        // The mail duty's lines.
        (
            Event::Payload {
                line: s("Hold KEN-7 for the owner."),
            },
            "  Hold KEN-7 for the owner.",
        ),
        (
            Event::Payload {
                line: s("options: cut, keep"),
            },
            "  options: cut, keep",
        ),
        (Event::Payload { line: s("") }, "  "),
        // The tracker and GitHub read duty's lines.
        (
            Event::TrackerQuota {
                line: s("tracker-quota status=future reset=2026-01-01T00:10:00Z limit=requests"),
            },
            "EVENT tracker-quota status=future reset=2026-01-01T00:10:00Z limit=requests",
        ),
        // The local-lane readings' lines: separate counts, and a parked lane.
        (
            Event::LaneLong {
                item: s("issue-1"),
                age: 12601,
                review_rounds: s("5"),
                fix_receipts: s("3"),
                validation_runs: s("4"),
                restacks: s("4"),
                repeated_class_rounds: s("1"),
                stage: s("dev round 1"),
            },
            "EVENT lane-long issue-1 age=12601 review_rounds=5 fix_receipts=3 validation_runs=4 restacks=4 repeated_class_rounds=1 stage=dev round 1",
        ),
        (
            Event::LaneLong {
                item: s("issue-3"),
                age: 12600,
                review_rounds: s("unread"),
                fix_receipts: s("unread"),
                validation_runs: s("unread"),
                restacks: s("unread"),
                repeated_class_rounds: s("unread"),
                stage: s("parked"),
            },
            "EVENT lane-long issue-3 age=12600 review_rounds=unread fix_receipts=unread validation_runs=unread restacks=unread repeated_class_rounds=unread stage=parked",
        ),
        // The GitHub duty's readings' lines.
        (Event::PrWatch { rc: 1 }, "EVENT pr-watch rc=1"),
        // The security alerts: a Dependabot alert with its pull request, a
        // secret, a repeat.
        (
            Event::SecurityAlert {
                repo: s("owner/repo"),
                kind: s("dependabot"),
                number: 7,
                severity: Some(s("high")),
                subject_key: s("package"),
                subject: s("fast-uri"),
                manifest: Some(s("ui/package-lock.json")),
                scope: Some(s("runtime")),
                advisory: Some(s("GHSA-aaaa-bbbb-cccc")),
                validity: None,
                url: s("https://github.com/owner/repo/security/dependabot/7"),
                pr: Some(12),
                repeat: false,
            },
            "EVENT security-alert owner/repo kind=dependabot number=7 severity=high package=fast-uri manifest=ui/package-lock.json scope=runtime advisory=GHSA-aaaa-bbbb-cccc url=https://github.com/owner/repo/security/dependabot/7 pr=12",
        ),
        (
            Event::SecurityAlert {
                repo: s("owner/repo"),
                kind: s("secret-scanning"),
                number: 3,
                severity: None,
                subject_key: s("rule"),
                subject: s("github_personal_access_token"),
                manifest: None,
                scope: None,
                advisory: None,
                validity: Some(s("active")),
                url: s("https://github.com/owner/repo/security/secret-scanning/3"),
                pr: None,
                repeat: true,
            },
            "EVENT security-alert owner/repo kind=secret-scanning number=3 rule=github_personal_access_token validity=active url=https://github.com/owner/repo/security/secret-scanning/3 report=repeat",
        ),
        // The unread set's line.
        (
            Event::SecurityAlertsUnread {
                reads: s("owner/repo/dependabot:permission,owner/repo/code-scanning:http-502"),
            },
            "EVENT security-alerts-unread reads=owner/repo/dependabot:permission,owner/repo/code-scanning:http-502",
        ),
        // The outside contributions.
        (
            Event::OutsideContribution {
                key: s("owner/repo#3100"),
                kind: s("pr"),
                author: s("fixture-visitor"),
                head: Some(s("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
            },
            "EVENT outside-contribution owner/repo#3100 kind=pr author=fixture-visitor head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ),
        (
            Event::OutsideContribution {
                key: s("owner/repo#3101"),
                kind: s("issue"),
                author: s("fixture-visitor"),
                head: None,
            },
            "EVENT outside-contribution owner/repo#3101 kind=issue author=fixture-visitor",
        ),
        // The report and heartbeat duties' lines.
        (
            Event::ReportDue {
                line: s("report-due reason=minutes since=2026-10-01T00:00:00Z"),
            },
            "EVENT report-due reason=minutes since=2026-10-01T00:00:00Z",
        ),
        // A heartbeat body line, printed unprefixed.
        (
            Event::Body {
                line: s("owed KEN-6 state=in-review priority=3 lane=none verdict=queue"),
            },
            "owed KEN-6 state=in-review priority=3 lane=none verdict=queue",
        ),
    ];
    for (event, line) in rows {
        assert_eq!(event.render(), line, "{event:?}");
    }
}

// The hosted close through `watch run`.
/// The watch over a stalled cloud lane, started with the `lane-host` and
/// runtime-entry fixtures under the project's scripts directory and the
/// `gh` fixture first on `PATH`, `extra` on its environment.
fn spawn_hosted_watch_run(dir: &Path, extra: &[(&str, &str)]) -> std::process::Child {
    let mut command = watch_run_command(dir, &["--interval", "1"]);
    for (name, value) in extra {
        command.env(name, value);
    }
    command.spawn().expect("spawn watch run")
}

/// Through `watch run` over a cloud lane whose pull request stood still
/// past the stall bound and whose directive went unanswered past the cloud
/// stall bound, the close verb (`close-lane CC-1` through the runtime's
/// entry) is asked once with the close marker written before it; the
/// fixture ends the runtime before it
/// answers, and the next run finds the marker beside the open lane, asks
/// nothing, and says `lane-close-unconfirmed` as the duty's failure.
#[test]
fn a_cloud_stall_close_cut_by_a_crash_is_not_asked_again_by_the_next_run() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    // The scripts directory the lane duty resolves under the project root,
    // the two fixtures linked there with their planted answers beside.
    let scripts = state_dir.join(".agents/skills/orch/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    link_fixture("lane-host/lane-host", &scripts.join("lane-host"));
    link_fixture("runtime-close/orch-runtime", &scripts.join("orch-runtime"));
    std::fs::write(
        scripts.join("lane-host.json"),
        json!({"capabilities": {"stdout": "kind=claude-cloud\tlaunch=cloud-session\tchannel=session\tfiles=none\tstatus=none\tstop=none\trelaunch=fresh\tpark=none\taccounts=none\tpool=cloud-credit\tland=handoff\tpane=local"}})
            .to_string(),
    )
    .unwrap();
    let closed = json!({"protocol": "orch-runtime-v1", "ok": true, "result": {"item": "CC-1",
        "word": "closed", "observation": {"item_files": "removed", "archive": "/archive/CC-1"}}});
    std::fs::write(
        scripts.join("orch-runtime.json"),
        json!({"exit": 0, "stdout": format!("{closed}\n")}).to_string(),
    )
    .unwrap();
    // The `gh` the entry's credential ladder and the lane duty share: the
    // ladder's `auth status` answered here, every other call the `gh`
    // fixture's, its map and log in `bin`.
    let bin = state_dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    write_executable(
        &bin.join("gh"),
        format!(
            "#!/bin/bash\nif [ \"${{1:-}}\" = auth ] && [ \"${{2:-}}\" = status ]; then exit 0; fi\nexport GH_FAKE_REPLIES={0}/gh.json GH_FAKE_LOG={0}/gh.log\nexec {1} \"$@\"\n",
            bin.display(),
            fixtures().join("gh/gh").display()
        ),
    );
    std::fs::write(
        bin.join("gh.json"),
        json!({"repos/o/r/pulls?head=o:cc-1&state=open": {"body": [{"number": 1, "state": "open", "title": "cloud work", "merged_at": null, "merge_commit_sha": null, "author_association": "NONE", "head": {"sha": "aaa111", "ref": "cc-1", "repo": null}, "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null, "body": "", "draft": true}]}})
            .to_string(),
    )
    .unwrap();
    let now = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let lane = json!({
        "item": "CC-1", "harness": "claude", "host": "claude-cloud", "kind": "claude-cloud",
        "repo": "o/r", "account": "/home/me/.eclaude", "mail_root": state_dir.join("wt"),
        "window": null, "status": "running",
        "launched_at": agent_runtime::clock::iso_utc(now - 7200),
        "running_at": agent_runtime::clock::iso_utc(now - 7200),
        "directive_send": {"at": now - 1900, "result": "sent", "text": "Rebase."}
    });
    let mut fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    fleet["lanes"] = json!([lane]);
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    // The stall row as the earlier passes left it: the head and digest the
    // fixture answers, standing still since past the stall bound.
    let paths = Paths::of(&state).unwrap();
    let mut baseline = watch::Baseline::default();
    baseline.apply(Change::Set {
        kind: "lane-stalled".into(),
        identity: "CC-1".into(),
        value: format!(
            "aaa111|{}|{}||",
            agent_runtime::record::cksum(b"\n"),
            now - 3700
        ),
    });
    baseline.store(&paths.baseline).unwrap();
    let close_log = scripts.join("orch-runtime.log");
    let marker = orch_runtime::watch::hosted::close_marker_path(
        orch_runtime::watch::lanes::watch_state_dir(&settings_in(&state_dir, 20).claim_store),
        "CC-1",
    );
    // Run 1: the fixture ends the runtime before it answers.
    let child = spawn_hosted_watch_run(&state_dir, &[("RUNTIME_CLOSE_KILL_PARENT", "1")]);
    let cut = bounded_output(
        child,
        secs(30),
        "the runtime ran on past the fixture's kill",
    );
    assert!(!cut.status.success(), "{}", cut.status);
    let calls = |log: &Path| -> Vec<String> {
        std::fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    };
    // The entry names no `--state-dir`, so the runtime's is the default
    // under the project root.
    assert_eq!(
        calls(&close_log),
        vec![format!(
            "--state-dir {} op --fleet --request {}",
            state_dir.join("tmp").display(),
            r#"{"item":"CC-1","op":"close-lane"}"#
        )],
        "one close asked: {}",
        stderr(&cut)
    );
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the marker written before the close stands: {}",
        marker.display()
    );
    // Run 2: the gone claim taken over, the marker found, nothing asked.
    let mut child = spawn_hosted_watch_run(&state_dir, &[]);
    await_claim(&mut child, &paths);
    let deadline = Instant::now() + secs(20);
    loop {
        if let Ok(baseline) = watch::Baseline::load(&paths.baseline)
            && baseline.passes.contains_key(&Duty::NativeObservation)
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the lane duty never passed: {}",
            String::from_utf8_lossy(&std::fs::read(&paths.log).unwrap_or_default())
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    assert_eq!(
        calls(&close_log).len(),
        1,
        "no second close: {:?}",
        calls(&close_log)
    );
    assert!(
        std::fs::metadata(&marker).is_ok(),
        "the marker stands beside the open lane"
    );
    let err = stderr(&out);
    assert!(
        err.contains("lane-close-unconfirmed item=CC-1"),
        "the duty's failure names the unconfirmed close: {err}"
    );
    let log = log_lines(&paths);
    assert!(
        log.iter()
            .any(|l| l.starts_with("EVENT watch-step-failed step=native-observation ")),
        "{log:?}"
    );
    assert!(
        !log.iter()
            .any(|l| l.starts_with("EVENT lane-closed ")
                || l.starts_with("EVENT cloud-stall-closed ")),
        "nothing closed on the log: {log:?}"
    );
}

/// Run the binary's `watch` verb against `dir` with the fleet server's
/// environment kept off it: the watch reads no tmux.
fn watch_cmd(dir: &Path, args: &[&str]) -> std::process::Output {
    let mut command = isolated();
    command
        .args(["--state-dir", &dir.display().to_string()])
        .args(args)
        .current_dir(dir);
    command.output().expect("orch-runtime watch")
}

/// The shipped `lane-mail`, run over the test directory as its root, where
/// it finds no mailbox; a row that plants one names it here.
fn lane_mail() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("mailbox/scripts/lane-mail")
}

/// The github skill linked under `dir`'s install layout, where `watch run`
/// finds the credential ladder it runs before it claims.
fn github_skill_under(dir: &Path) {
    let skills = dir.join(".agents/skills");
    std::fs::create_dir_all(&skills).unwrap();
    link_fixture("../../../../github", &skills.join("github"));
}

/// `fixture` linked into the row's world at `at`; a link already there is
/// the same fixture from an earlier command of the row.
fn link_fixture(fixture: &str, at: &Path) {
    match std::os::unix::fs::symlink(fixtures().join(fixture), at) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => panic!("link {fixture}: {e}"),
    }
}

/// The environment a `watch run` in `dir` runs under, on `command`, with
/// every duty's program named so the run is quiet on an empty fleet: the
/// shipped mailbox client over the test directory, the alert pass off (with
/// no token file it would print its credential line), `gh` as the fixture
/// that answers the credential ladder (`bin/gh`, its status from
/// `bin/gh.auth-status`, absent for 0, every other call refused) and the
/// github skill under the directory's install layout, where the ladder is,
/// and an agent-runtime the readiness judge reads built (`version` alone
/// answers). `bin` is first on `PATH`, so a row's own fakes go there too.
fn watch_env(command: &mut Command, dir: &Path) {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    link_fixture("gh-auth-fixture/gh", &bin.join("gh"));
    github_skill_under(dir);
    isolation_env(command);
    command
        .env("PATH", tool_path(&[&bin]))
        .env(
            "ORCH_AGENT_RUNTIME",
            fixtures().join("agent-runtime-built/agent-runtime"),
        )
        .env("LANE_MAIL_CLI", lane_mail())
        .env("ORCH_SECURITY_ALERTS", "off")
        .current_dir(dir);
}

/// `watch run --file <state>` then `flags` on the fleet state in `dir`,
/// under [`watch_env`], its start naming the shipped mailbox client over
/// `dir` and a server socket under `dir` that no server answers.
fn watch_run_command(dir: &Path, flags: &[&str]) -> Command {
    watch_run_with(dir, flags, &lane_mail())
}

/// [`watch_run_command`] with its start naming the mailbox program `mail`.
fn watch_run_with(dir: &Path, flags: &[&str], mail: &Path) -> Command {
    let state = dir.join(FLEET_FILE_NAME);
    let mut command = isolated();
    watch_env(&mut command, dir);
    command
        .args(["watch", "run", "--file", &state.display().to_string()])
        .args(flags)
        .arg("--mail-program")
        .arg(mail)
        .arg("--mail-root")
        .arg(dir)
        .arg("--socket")
        .arg(dir.join("tmux.sock"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// The output of a start that must end on its own within `bound`: one
/// that runs on past it is a runner the row forbids, killed and reported
/// as `overrun`.
fn bounded_output(
    mut child: std::process::Child,
    bound: Duration,
    overrun: &str,
) -> std::process::Output {
    let deadline = Instant::now() + bound;
    while child.try_wait().ok().flatten().is_none() {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("{overrun}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    child.wait_with_output().unwrap()
}

/// Spawn `watch run` in `dir` with `flags`; it claims as the child's pid.
fn spawn_watch_run(dir: &Path, flags: &[&str]) -> std::process::Child {
    watch_run_command(dir, flags)
        .spawn()
        .expect("spawn watch run")
}

/// Wait until the runner `child` has claimed `paths`, bounded; a child
/// that ends first fails the row with its stderr.
fn await_claim(child: &mut std::process::Child, paths: &Paths) {
    let deadline = Instant::now() + secs(10);
    loop {
        if let Ok(Some(claim)) = watch::claim::read(paths)
            && claim.pid == child.id()
        {
            return;
        }
        if let Ok(Some(status)) = child.try_wait() {
            let mut err = String::new();
            if let Some(stderr) = child.stderr.as_mut() {
                let _ = std::io::Read::read_to_string(stderr, &mut err);
            }
            panic!("the runner ended {status}: {err}");
        }
        assert!(Instant::now() < deadline, "the runner never claimed");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Every GitHub read of a pass needs the credential the ladder selects, so
/// the ladder answers before any claim. With `gh auth status` failing and
/// no bot token to load, `watch run` refuses `auth-failed` with no claim
/// record and no event log, after the ladder's one probe of each candidate.
#[test]
fn a_watch_run_that_cannot_authenticate_refuses_before_any_claim() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let mut command = watch_run_command(&state_dir, &["--interval", "240"]);
    std::fs::write(state_dir.join("bin/gh.auth-status"), "1\n").unwrap();
    let out = bounded_output(
        command.spawn().unwrap(),
        secs(30),
        "the watch ran on with no credential selected",
    );
    let err = stderr(&out);
    assert!(!out.status.success(), "{err}");
    assert_eq!(
        err.lines().next().map(|l| l.split_whitespace().nth(1)),
        Some(Some("auth-failed")),
        "{err}"
    );
    let paths = paths_in(&state_dir);
    assert!(
        std::fs::metadata(&paths.pid).is_err() && std::fs::metadata(&paths.log).is_err(),
        "the watch claimed before the ladder answered"
    );
    assert_eq!(
        std::fs::read_to_string(state_dir.join("bin/gh.log")).unwrap_or_default(),
        "auth status\n",
        "each candidate probed once: the env token absent, the keyring once, the bot token unloadable"
    );
    // A watch setting outside its form refuses the run before its claim,
    // and `watch status`, which reads none, answers under it.
    for (key, value) in [
        ("ORCH_WATCH_MAIL_INTERVAL", "x"),
        ("ORCH_OVERSEER_MARK_REPEAT", "0"),
        ("ORCH_OVERSEER_DEAD_PASSES", "two"),
        ("ORCH_WATCH_TAIL_LINES", "-1"),
        ("ORCH_WATCH_PREPARE_SECS", "1m"),
        ("ORCH_DIRECTIVE_UNREAD_SECS", "5s"),
        ("ORCH_WATCH_START_STALL_SECS", "0"),
        ("ORCH_WATCH_LANE_STALL_SECS", "07"),
        ("ORCH_CLOUD_STALL_MINUTES", "0"),
        ("ORCH_WATCH_LANE_AGE_SECS", "x"),
        ("ORCH_WALL_RELAUNCH", "maybe"),
        ("ORCH_MAIN_WORKFLOWS", "owner/repo"),
        ("ORCH_SECURITY_ALERTS", "yes"),
        ("ORCH_EXTERNAL_TRIAGE", "1"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let state_dir = std::fs::canonicalize(dir.path()).unwrap();
        let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
        assert!(init.status.success(), "init: {}", stderr(&init));
        let mut command = watch_run_command(&state_dir, &["--interval", "240"]);
        command.env(key, value);
        let out = bounded_output(
            command.spawn().unwrap(),
            secs(30),
            "the watch ran on under a setting outside its form",
        );
        let err = stderr(&out);
        assert_eq!(out.status.code(), Some(1), "{key}: {err}");
        assert!(
            err.contains(&format!(
                "orch-runtime: setting-invalid key={key} value={value}"
            )),
            "{key}: {err}"
        );
        let paths = paths_in(&state_dir);
        assert!(
            std::fs::metadata(&paths.pid).is_err() && std::fs::metadata(&paths.log).is_err(),
            "{key}: the watch claimed before it judged its settings"
        );
        let mut status = isolated();
        status
            .args(["--state-dir", &state_dir.display().to_string()])
            .args(["watch", "status", "--fleet"])
            .env(key, value)
            .current_dir(&state_dir);
        let status = status.output().unwrap();
        assert!(status.status.success(), "{key}: {}", stderr(&status));
    }
}

/// The watch wakes the overseer through agent-runtime, so it asks first:
/// agent-runtime's real wrapper finding its key unbuilt (an empty cache),
/// `watch run` refuses `unready` naming orch's setup before the credential
/// ladder runs and before any claim, event line or alert.
#[test]
fn a_watch_run_on_an_unbuilt_agent_runtime_refuses_before_the_ladder_and_any_claim() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let mut command = watch_run_command(&state_dir, &["--interval", "240", "--max-loops", "1"]);
    command
        .env(
            "ORCH_AGENT_RUNTIME",
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../agent-runtime/scripts/agent-runtime"),
        )
        .env("AGENT_RUNTIME_CACHE", state_dir.join("cache"));
    let out = bounded_output(
        command.spawn().unwrap(),
        secs(30),
        "the watch ran on with agent-runtime unbuilt",
    );
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(1), "{err}");
    assert_eq!(
        err.lines().next(),
        Some(
            format!(
                "orch-runtime: unready duty=watch program=agent-runtime cause=unbuilt fix={}",
                state_dir
                    .join(".agents/skills/orch/scripts/setup")
                    .display()
            )
            .as_str()
        ),
        "{err}"
    );
    let paths = paths_in(&state_dir);
    assert!(
        std::fs::metadata(&paths.pid).is_err() && std::fs::metadata(&paths.log).is_err(),
        "the watch claimed before it asked"
    );
    assert!(
        std::fs::metadata(state_dir.join("bin/gh.log")).is_err(),
        "the credential ladder ran before the watch asked"
    );
}

/// The watch writes its lane mail through the program its start names, so
/// that program is the one readiness judges: a start naming a program that
/// is gone, beside a `LANE_MAIL_CLI` that stands, refuses `unready` naming
/// lane-mail before the credential ladder and before any claim or event
/// line, where it would otherwise claim and fail every write.
#[test]
fn a_watch_started_with_a_gone_mail_program_is_refused_before_it_claims() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    assert!(lane_mail().is_file(), "LANE_MAIL_CLI names a program");
    let gone = state_dir.join("gone/lane-mail");
    let mut command = watch_run_with(
        &state_dir,
        &["--interval", "240", "--max-loops", "1"],
        &gone,
    );
    let out = bounded_output(
        command.spawn().unwrap(),
        secs(30),
        "the watch ran on with its mail program gone",
    );
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(1), "{err}");
    assert_eq!(
        err.lines().next(),
        Some("orch-runtime: unready duty=watch program=lane-mail cause=absent fix=kendex-apply"),
        "{err}"
    );
    let paths = paths_in(&state_dir);
    assert!(
        std::fs::metadata(&paths.pid).is_err() && std::fs::metadata(&paths.log).is_err(),
        "the watch claimed before it asked"
    );
    assert!(
        std::fs::metadata(state_dir.join("bin/gh.log")).is_err(),
        "the credential ladder ran before the watch asked"
    );
}

/// The ladder's refusal is its last line, after any warning it printed
/// first, and the watch's refusal carries that line: here a bound the
/// ladder cannot read is warned about ahead of it, the env token goes
/// unchecked and no bot token loads, so the refusal names both sources.
#[test]
fn a_watch_run_refusal_carries_the_ladders_sources_after_its_warning() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let mut command = watch_run_command(&state_dir, &["--interval", "240"]);
    command
        .env("GH_TOKEN", "ghp_rowEnvToken")
        .env("KENDEX_GITHUB_AUTH_TIMEOUT", "2.55");
    let out = bounded_output(
        command.spawn().unwrap(),
        secs(30),
        "the watch ran on with no credential selected",
    );
    let err = stderr(&out);
    assert!(!out.status.success(), "{err}");
    assert!(
        err.contains("gh-auth-ladder: auth-failed service=github env=unreadable bot-token=absent")
            && !err.contains("ghp_rowEnvToken"),
        "{err}"
    );
}

/// An open intent the reconcile cannot complete or mark (a close whose lane
/// record is gone) reaches the log. Through `watch run`, the fixture emits
/// one `reconcile-refused` line and the intent stands unchanged; and the
/// run registers the report duty, so a progress report written past the
/// minutes cadence makes the report due.
#[test]
fn a_refused_intent_reaches_the_log_once_through_watch_run() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let reports = state_dir.join("tmp/progress-reports");
    std::fs::create_dir_all(&reports).unwrap();
    let last = reports.join("01-01-00-00.md");
    std::fs::write(&last, "the last report\n").unwrap();
    let written = 1_769_700_000;
    std::fs::File::open(&last)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH + secs(written))
        .unwrap();
    let state = state_dir.join(FLEET_FILE_NAME);
    let gone = json!({
        "id": "close-resources:KEN-GONE:1-1", "op": "close-resources",
        "target": "KEN-GONE", "created_at": "2026-01-29T15:20:00Z",
        "outcome": "unconfirmed", "lane_since": "2026-01-29T15:20:00Z",
        "obligations": {"standing": [], "discharged": [], "signalled": false, "revision": 1}
    });
    let mut fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    fleet["intents"] = json!([gone]);
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    let mut child = watch_run_command(&state_dir, &[])
        .env("ORCH_REPORT_EVERY_MINUTES", "120")
        .spawn()
        .expect("spawn watch run");
    let paths = Paths::of(&state).unwrap();
    await_claim(&mut child, &paths);
    let deadline = Instant::now() + secs(10);
    while watch::events::line_count(&paths.log).unwrap() < 2 {
        assert!(
            Instant::now() < deadline,
            "the reconcile and the report never reported: {:?}",
            log_lines(&paths)
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let mut logged = log_lines(&paths);
    logged.sort();
    assert_eq!(
        logged,
        vec![
            "EVENT reconcile-refused intent=close-resources:KEN-GONE:1-1 refusal=lane-missing"
                .to_owned(),
            format!(
                "EVENT report-due reason=minutes since={}",
                agent_runtime::clock::iso_utc(written)
            ),
        ]
    );
    let after: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    assert_eq!(
        after["intents"][0], gone,
        "the refused intent stands as it was"
    );
    let baseline = watch::Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.get("reconcile-refused", "close-resources:KEN-GONE:1-1"),
        Some("lane-missing"),
        "the row that quiets the next pass"
    );
}

/// Through `watch run` on a one-second long cadence over a lane whose
/// `directive_send` stands owed with no kept receipt, the reconcile duty
/// prints one `directive-send-unsettled` line across two passes, keys it in
/// the baseline by item and cause as `reconcile-refused` is keyed, and
/// leaves the record as it stood.
#[test]
fn an_owed_send_no_receipt_settles_reaches_the_log_once_per_cause_through_watch_run() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    let lane = json!({
        "item": "CC-1", "harness": "claude", "host": "claude-cloud",
        "kind": "claude-cloud", "account": state_dir.join(".eclaude"),
        "session_id": "session_01CLOUD", "mail_root": state_dir.join("wt"),
        "window": null, "status": "running",
        "directive_send": {"result": "owed", "text": "Rebase.", "receipt": "1-1"}
    });
    let mut fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    fleet["lanes"] = json!([lane]);
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    let mut child = spawn_watch_run(&state_dir, &["--interval", "1"]);
    let paths = Paths::of(&state).unwrap();
    await_claim(&mut child, &paths);
    // Two reconcile passes: the duty's pass stamp moved past its first.
    let deadline = Instant::now() + secs(15);
    let mut first = None;
    loop {
        if let Ok(baseline) = watch::Baseline::load(&paths.baseline)
            && let Some(&at) = baseline.passes.get(&Duty::Reconcile)
        {
            match first {
                None => first = Some(at),
                Some(f) if at > f => break,
                Some(_) => {}
            }
        }
        assert!(
            Instant::now() < deadline,
            "the reconcile never passed twice"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let lines: Vec<String> = log_lines(&paths)
        .into_iter()
        .filter(|l| l.starts_with("EVENT directive-send-unsettled "))
        .collect();
    assert_eq!(
        lines,
        vec!["EVENT directive-send-unsettled item=CC-1 cause=receipt-missing"]
    );
    let after: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    assert_eq!(after["lanes"][0], lane, "the owed record stands as it was");
    let baseline = watch::Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.get("directive-send-unsettled", "CC-1"),
        Some("receipt-missing"),
        "the row that quiets the next pass"
    );
}

/// The single-pass follow `references/watch-delivery.md` ships, the fenced
/// block under its `## Single passes`, which a session saves and runs.
fn shipped_single_pass() -> String {
    let doc = std::fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("references/watch-delivery.md"),
    )
    .unwrap();
    let (_, section) = doc
        .split_once("\n## Single passes\n")
        .expect("the single passes section");
    let (_, fenced) = section.split_once("```sh\n").expect("its fenced follow");
    let (text, _) = fenced.split_once("```").expect("the fence's end");
    text.to_owned()
}

/// A session's follow numbers the lines of the file its link names, so a
/// log that set its lines aside at a bound would hand a session past that
/// bound nothing. Over a planted 9,999-line log, `watch run` on a
/// one-second heartbeat appends two lines and is stopped; the shipped
/// single-pass follow on a symbolic link, from the session's next line
/// 10,001, prints every line from 10,001 under the log's own number.
#[test]
fn a_single_pass_follow_past_ten_thousand_lines_prints_each_line_under_the_logs_number() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let paths = Paths::of(&state_dir.join(FLEET_FILE_NAME)).unwrap();
    let planted: String = (1..=9_999)
        .map(|n| format!("EVENT triage KEN-{n}\n"))
        .collect();
    std::fs::write(&paths.log, planted).unwrap();
    let mut child = spawn_watch_run(&state_dir, &["--interval", "1", "--max-loops", "1"]);
    await_claim(&mut child, &paths);
    let deadline = Instant::now() + secs(60);
    while watch::events::line_count(&paths.log).unwrap() < 10_001 {
        assert!(Instant::now() < deadline, "the watch never appended twice");
        std::thread::sleep(Duration::from_millis(20));
    }
    let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let reader = state_dir.join("reader");
    std::fs::create_dir_all(&reader).unwrap();
    std::os::unix::fs::symlink(&paths.log, reader.join("watch.log")).unwrap();
    std::fs::write(reader.join("follow.sh"), shipped_single_pass()).unwrap();
    let follow = Command::new("sh")
        .arg(reader.join("follow.sh"))
        .arg(reader.join("watch.log"))
        .arg("10001")
        .env_clear()
        .env("PATH", tool_path(&[]))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let out = bounded_output(follow, secs(60), "the follow ran past its quiet expiry");
    assert!(out.status.success(), "{}", stderr(&out));
    let printed: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_owned)
        .collect();
    assert!(
        printed.first().is_some_and(|l| l.starts_with("10001: ")),
        "the follow printed {printed:?}"
    );
    let numbered: Vec<String> = log_lines(&paths)
        .iter()
        .enumerate()
        .skip(10_000)
        .map(|(i, line)| format!("{}: {line}", i + 1))
        .collect();
    assert_eq!(printed, numbered);
}

/// A succession neither stops, replaces nor restarts the fleet watch, so
/// the successor reads the log no restart truncated and the claim the same
/// runner holds. A real transfer through the runtime, beside the entry's
/// live runner whose log holds one line (the takeover of a gone record,
/// planted): the claim names the same runner before and after, that line
/// stands, and the successor's `watch log --since` from the handoff's last
/// line returns it at its number with what followed.
#[test]
fn a_succession_under_a_live_scheduler_leaves_its_claim_and_log_and_the_successor_reads_on() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let state_dir = std::fs::canonicalize(runner.state_dir()).unwrap();
    let paths = Paths::of(&state_dir.join(FLEET_FILE_NAME)).unwrap();
    plant_claim(&paths, GONE_PID as u32, "ticks:1");
    let mut child = spawn_watch_run(&state_dir, &[]);
    await_claim(&mut child, &paths);
    let predecessor = Owned::sleep();
    plant_transfer(&runner, &server, predecessor.pid(), &predecessor.start());
    // The takeover line lands once the runtime opens its log, after the
    // claim.
    let deadline = Instant::now() + secs(10);
    while watch::events::line_count(&paths.log).unwrap() == 0 {
        assert!(Instant::now() < deadline, "the takeover was never logged");
        std::thread::sleep(Duration::from_millis(20));
    }
    let before = log_lines(&paths);
    let last_line = before.len() as u64;
    let claim_before = watch::claim::read(&paths)
        .unwrap()
        .expect("the runner's claim");
    runner.transfer_started(&transfer_request(&server, runner.state_dir()));
    let intent = runner.wait_intent_settled("request-transfer:", secs(40));
    assert_eq!(intent["outcome"], "confirmed", "{intent}");
    assert_eq!(runner.fleet()["controller"]["generation"], 4, "published");
    assert_eq!(
        watch::claim::read(&paths).unwrap().unwrap(),
        claim_before,
        "the succession left the claim as it stood"
    );
    let standing = watch::status(&paths).unwrap().claim.expect("the claim");
    assert_eq!(
        (standing.pid, standing.standing),
        (child.id(), "live"),
        "the runner lives through the succession"
    );
    let after = log_lines(&paths);
    assert_eq!(&after[..before.len()], &before[..], "the log's lines stand");
    let read = watch_cmd(
        &state_dir,
        &["watch", "log", "--fleet", "--since", &last_line.to_string()],
    );
    let answer = reply(&read);
    let lines: Vec<String> = answer["result"]["lines"]
        .as_array()
        .unwrap_or_else(|| panic!("{answer}"))
        .iter()
        .map(|l| l["line"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(
        lines,
        after[before.len() - 1..],
        "the successor reads the handoff's last line at its number and what followed: {answer}"
    );
    let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
}

// The GitHub sign-in through `watch run`: the real ladder of the github
// skill over the `gh` fixture's credential judge.

/// The credential the watch is started with.
const START_TOKEN: &str = "ghs_watchStartFixture";

/// The project's bot token a renewal finds in `.env.local`.
const BOT_TOKEN: &str = "ghs_projectBotFixture";

/// The one repository the GitHub duty reads.
const SIGN_IN_REPO: &str = "owner/repo";

/// `value` at `path` whole: a reader between two writes sees one map or
/// the other, never a part.
fn plant_whole(path: &Path, value: &str) {
    let partial = path.with_extension("partial");
    std::fs::write(&partial, value).unwrap();
    std::fs::rename(&partial, path).unwrap();
}

/// The `gh` fixture's map: the repository's audits answer quiet (no
/// workflow, no open pull request or issue) and `sign_in` judges every
/// call's credential.
fn plant_github(bin: &Path, sign_in: Value) {
    let quiet = json!({
        format!("repos/{SIGN_IN_REPO}/actions/workflows?per_page=100&page=1"):
            {"body": {"total_count": 0, "workflows": []}},
        format!("repos/{SIGN_IN_REPO}/pulls?state=open&per_page=100&page=1"): {"body": []},
        format!("repos/{SIGN_IN_REPO}/issues?state=open&per_page=100&page=1"): {"body": []},
        "sign-in": sign_in,
    });
    plant_whole(&bin.join("gh.json"), &quiet.to_string());
}

/// `watch run` on a one-second long cadence over [`SIGN_IN_REPO`], started
/// with [`START_TOKEN`], which the fixture takes until a row expires it:
/// the `gh` fixture first on `PATH`, the reducer quiet, the owner's mailbox
/// the logging fixture, the runner's stderr in `watch.err`.
fn spawn_sign_in_watch(dir: &Path) -> std::process::Child {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    link_fixture("gh/gh", &bin.join("gh"));
    link_fixture("pr-watch-fixture/pr-watch.sh", &bin.join("pr-watch"));
    link_fixture("lane-mail-owner/lane-mail", &bin.join("lane-mail"));
    plant_github(&bin, json!({"expired": [], "stored": null}));
    std::fs::write(
        bin.join("pr-watch.json"),
        json!({SIGN_IN_REPO: {"exit": 0}}).to_string(),
    )
    .unwrap();
    let mut command = watch_run_with(
        dir,
        &["--interval", "1", "--repo", SIGN_IN_REPO],
        &bin.join("lane-mail"),
    );
    command
        .env("GH_TOKEN", START_TOKEN)
        .env("OVERSEE_WATCH_PR_WATCH", bin.join("pr-watch"))
        .stderr(std::fs::File::create(dir.join("watch.err")).unwrap());
    command.spawn().expect("spawn watch run")
}

/// The epoch second now, the floor a pass that starts after a plant is
/// stamped at or past.
fn wall_now() -> u64 {
    SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

/// Wait until the GitHub duty's pass stamp is past `after` and `holds`
/// reads the baseline true, bounded; the bound's failure names the log and
/// the runner's stderr.
fn await_github_pass(
    dir: &Path,
    paths: &Paths,
    after: u64,
    what: &str,
    holds: impl Fn(&watch::Baseline) -> bool,
) -> u64 {
    let deadline = Instant::now() + secs(30);
    loop {
        if let Ok(baseline) = watch::Baseline::load(&paths.baseline)
            && let Some(&at) = baseline.passes.get(&Duty::GitHub)
            && at > after
            && holds(&baseline)
        {
            return at;
        }
        assert!(
            Instant::now() < deadline,
            "{what}: {:?}\n{}",
            log_lines(paths),
            std::fs::read_to_string(dir.join("watch.err")).unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn stop_watch(state_dir: &Path, mut child: std::process::Child) {
    let stop = watch_cmd(state_dir, &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    assert!(child.wait().unwrap().success());
}

fn lines_of(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// A watch whose starting token expires mid-life reads on: the GitHub
/// duty's first read under the expired token is refused 401, the ladder
/// runs again and selects the stored login, the read is asked again under
/// the renewed pair, and the pass completes with no step failure and no
/// alert. The renewed pair masks the token the process inherited, on the
/// duty's reads and on the reducer the duty starts.
#[test]
fn a_token_that_expires_mid_life_is_renewed_and_the_pass_completes() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let paths = Paths::of(&state_dir.join(FLEET_FILE_NAME)).unwrap();
    let mut child = spawn_sign_in_watch(&state_dir);
    await_claim(&mut child, &paths);
    await_github_pass(&state_dir, &paths, 0, "the first pass", |_| true);
    let bin = state_dir.join("bin");
    plant_github(&bin, json!({"expired": [START_TOKEN], "stored": "valid"}));
    let expired = wall_now();
    await_github_pass(
        &state_dir,
        &paths,
        expired,
        "the GitHub duty never passed under the expired token",
        |_| true,
    );
    stop_watch(&state_dir, child);
    let log = log_lines(&paths);
    assert!(
        !log.iter()
            .any(|l| l.starts_with("EVENT watch-step-failed step=github")
                || l.starts_with("EVENT github-auth-failed")),
        "the renewed pass failed nothing: {log:?}"
    );
    let calls = lines_of(&bin.join("gh.env"));
    let read = format!("api repos/{SIGN_IN_REPO}/");
    assert!(
        calls
            .iter()
            .any(|l| l.starts_with(&format!("GH_TOKEN={START_TOKEN} {read}"))),
        "a read went out under the start token: {calls:?}"
    );
    assert!(
        calls
            .iter()
            .any(|l| l.starts_with(&format!("GH_TOKEN= {read}"))),
        "a read went out under the renewed stored login: {calls:?}"
    );
    assert_eq!(
        lines_of(&bin.join("pr-watch.env"))
            .last()
            .map(String::as_str),
        Some("GH_TOKEN="),
        "the reducer's last run took the renewed pair"
    );
}

/// A sign-in the ladder cannot renew (the start token expired, no stored
/// login, no project token) is said once on the log with its cause and
/// once to the owner on the next pass, then nothing while it stands; a
/// project token the ladder then finds renews it and clears the turn, and
/// a later expiry of that token is said again.
#[test]
fn an_unrenewable_sign_in_reaches_the_owner_once_and_a_renewal_clears_it() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let paths = Paths::of(&state_dir.join(FLEET_FILE_NAME)).unwrap();
    let mut child = spawn_sign_in_watch(&state_dir);
    await_claim(&mut child, &paths);
    await_github_pass(&state_dir, &paths, 0, "the first pass", |_| true);
    let bin = state_dir.join("bin");
    let turn = |b: &watch::Baseline| b.get("github-auth", "github").map(str::to_owned);
    plant_github(&bin, json!({"expired": [START_TOKEN], "stored": null}));
    let alerted = await_github_pass(
        &state_dir,
        &paths,
        wall_now(),
        "the owner was never alerted",
        |b| turn(b).as_deref() == Some("unrenewed|alerted"),
    );
    // Two more passes with the condition standing.
    let standing = await_github_pass(&state_dir, &paths, alerted, "standing", |_| true);
    await_github_pass(&state_dir, &paths, standing, "standing", |_| true);
    let said = |log: &[String]| {
        log.iter()
            .filter(|l| l.starts_with("EVENT github-auth-failed "))
            .cloned()
            .collect::<Vec<_>>()
    };
    let notices = || {
        lines_of(&bin.join("lane-mail.log"))
            .into_iter()
            .filter(|l| l.starts_with("notice to=owner github-auth-failed: "))
            .count()
    };
    assert_eq!(
        said(&log_lines(&paths)),
        vec!["EVENT github-auth-failed cause=auth-failed"],
        "said once on the log"
    );
    assert_eq!(notices(), 1, "one notice to the owner");
    std::fs::write(
        state_dir.join(".env.local"),
        format!("GH_BOT_TOKEN={BOT_TOKEN}\n"),
    )
    .unwrap();
    await_github_pass(
        &state_dir,
        &paths,
        wall_now(),
        "the project token never renewed the sign-in",
        |b| turn(b).is_none(),
    );
    assert!(
        lines_of(&bin.join("gh.env"))
            .iter()
            .any(|l| l.starts_with(&format!("GH_TOKEN={BOT_TOKEN} api repos/"))),
        "the reads went out under the project token"
    );
    plant_github(
        &bin,
        json!({"expired": [START_TOKEN, BOT_TOKEN], "stored": null}),
    );
    await_github_pass(
        &state_dir,
        &paths,
        wall_now(),
        "a later expiry was never said",
        |b| turn(b).is_some(),
    );
    stop_watch(&state_dir, child);
    assert_eq!(
        said(&log_lines(&paths)),
        vec![
            "EVENT github-auth-failed cause=auth-failed",
            "EVENT github-auth-failed cause=auth-failed"
        ],
        "a later expiry is said again"
    );
}

// The watch's reach: the mailbox and the server its start names.

/// A watch row's world under a temporary root below git's ceiling, as
/// agent-runtime's controller rows plant theirs: `bin/tmux` logs every call
/// to `tmux.log` and answers that no server runs; `named/lane-mail` logs
/// each call to `named-mail.log`; `checkout` is a checkout holding the fleet
/// state, whose own mailbox program logs to `checkout-mail.log`;
/// `mail-root` and `named.sock` are what a start names, `ambient.sock` the
/// server its `$TMUX` names. Dropping it waits for every process whose
/// command line names the root and kills what is left.
struct ReachWorld {
    dir: tempfile::TempDir,
}

impl ReachWorld {
    fn new() -> ReachWorld {
        let world = ReachWorld {
            dir: tempfile::tempdir().unwrap(),
        };
        let root = world.root();
        std::fs::create_dir_all(root.join("bin")).unwrap();
        std::fs::create_dir_all(root.join("mail-root")).unwrap();
        write_executable(
            &root.join("bin/tmux"),
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\necho 'no server running on stand-in' >&2\nexit 1\n",
                root.join("tmux.log").display()
            ),
        );
        logging_mailbox(&world.named_mail(), &root.join("named-mail.log"));
        let checkout = world.checkout();
        std::fs::create_dir_all(&checkout).unwrap();
        let out = program("git")
            .args(["-C", &checkout.display().to_string(), "init", "-q"])
            .output()
            .unwrap();
        assert!(out.status.success(), "git init: {}", stderr(&out));
        logging_mailbox(
            &checkout.join(".agents/skills/mailbox/scripts/lane-mail"),
            &root.join("checkout-mail.log"),
        );
        let init = watch_cmd(&checkout, &["state", "init", "--fleet"]);
        assert!(init.status.success(), "init: {}", stderr(&init));
        world
    }

    fn root(&self) -> &Path {
        self.dir.path()
    }

    fn checkout(&self) -> PathBuf {
        self.root().join("checkout")
    }

    fn named_mail(&self) -> PathBuf {
        self.root().join("named/lane-mail")
    }

    fn named_socket(&self) -> PathBuf {
        self.root().join("named.sock")
    }

    fn log(&self, name: &str) -> Vec<String> {
        lines_of(&self.root().join(name))
    }

    /// The three flags naming the world's mailbox and server.
    fn reach(&self) -> Vec<String> {
        vec![
            "--mail-program".to_owned(),
            self.named_mail().display().to_string(),
            "--mail-root".to_owned(),
            self.root().join("mail-root").display().to_string(),
            "--socket".to_owned(),
            self.named_socket().display().to_string(),
        ]
    }

    /// `watch run` on the checkout's fleet state, standing in the checkout,
    /// with `reach`: no `LANE_MAIL_CLI`, so the checkout's own mailbox is the
    /// one its walk finds; `$TMUX` naming the ambient socket; the stand-in
    /// tmux first on `PATH` and tmux's default socket directory the root.
    fn watch(&self, reach: &[String]) -> Command {
        let checkout = self.checkout();
        let state = checkout.join(FLEET_FILE_NAME);
        let mut command = isolated();
        watch_env(&mut command, &checkout);
        command
            .args(["--state-dir", &checkout.display().to_string()])
            .args(["watch", "run", "--file", &state.display().to_string()])
            .args(["--interval", "1", "--since", "2026-01-01T00:00:00Z"])
            .args(reach)
            .env_remove("LANE_MAIL_CLI")
            .env(
                "PATH",
                tool_path(&[&self.root().join("bin"), &checkout.join("bin")]),
            )
            .env(
                "TMUX",
                format!("{},0,0", self.root().join("ambient.sock").display()),
            )
            .env("TMUX_TMPDIR", self.root())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }

    /// The processes other than this one whose command line names the root.
    fn naming(&self) -> Vec<u32> {
        let root = self.root().as_os_str().as_encoded_bytes().to_vec();
        let own = std::process::id();
        std::fs::read_dir("/proc")
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok()?.file_name().to_str()?.parse::<u32>().ok())
                    .filter(|pid| *pid != own && cmdline_names(*pid, &root))
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// Whether `pid`'s command line holds `root`.
fn cmdline_names(pid: u32, root: &[u8]) -> bool {
    std::fs::read(format!("/proc/{pid}/cmdline"))
        .is_ok_and(|line| line.windows(root.len()).any(|w| w == root))
}

impl Drop for ReachWorld {
    fn drop(&mut self) {
        let deadline = Instant::now() + secs(10);
        while !self.naming().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
        }
        let root = self.root().as_os_str().as_encoded_bytes().to_vec();
        for pid in self.naming() {
            // Signalled only while its command line still names the root,
            // so a reused pid is never touched.
            if cmdline_names(pid, &root) {
                let _ = Command::new("kill")
                    .args(["-KILL", &pid.to_string()])
                    .output();
            }
        }
    }
}

/// A mailbox program at `program` that appends each call to `log`.
fn logging_mailbox(program: &Path, log: &Path) {
    std::fs::create_dir_all(program.parent().unwrap()).unwrap();
    write_executable(
        program,
        format!("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n", log.display()),
    );
}

/// A watch started under a checkout that holds its own mailbox program and
/// whose `$TMUX` names another server sends its owner notice through the
/// mailbox its start names, under the root its start names, and asks only
/// the server its start names: the controller record names no socket, so
/// its pane is looked for there, and the closed intent's owed notice is
/// the reconcile duty's to send.
#[test]
fn a_watch_under_a_checkout_with_its_own_mailbox_alerts_and_asks_only_what_its_start_names() {
    let world = ReachWorld::new();
    let state = world.checkout().join(FLEET_FILE_NAME);
    let server = Owned::sleep();
    let now = agent_runtime::journal::Env::system().unwrap().iso();
    let mut fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    fleet["controller"] = json!({
        "generation": 1, "server": server.pid(), "pane": "%1",
        "window": "overseer", "harness": "claude"
    });
    fleet["intents"] = json!([{
        "id": "request-transfer:overseer:1:1-1", "op": "request-transfer",
        "target": "overseer:1", "created_at": now, "completed_at": now,
        "outcome": "failed",
        "notice": {"key": "job-launch-failed", "text": "the planted notice", "owner": "owed"}
    }]);
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    let mut child = world.watch(&world.reach()).spawn().expect("watch run");
    let named = format!("-S {} ", world.named_socket().display());
    let notice = format!(
        "notice --item overseer --to owner --file {}",
        world
            .checkout()
            .join("intents/request-transfer:overseer:1:1-1.notice")
            .display()
    );
    let deadline = Instant::now() + secs(40);
    loop {
        let noticed = world
            .log("named-mail.log")
            .iter()
            .any(|l| l.starts_with(&notice));
        let asked = world.log("tmux.log").iter().any(|l| l.starts_with(&named));
        if noticed && asked {
            break;
        }
        if Instant::now() >= deadline || child.try_wait().unwrap().is_some() {
            let _ = child.kill();
            let out = child.wait_with_output().unwrap();
            panic!(
                "noticed={noticed} asked={asked}: tmux {:?} named {:?} checkout {:?}: {}",
                world.log("tmux.log"),
                world.log("named-mail.log"),
                world.log("checkout-mail.log"),
                stderr(&out)
            );
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let stop = watch_cmd(&world.checkout(), &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    let out = bounded_output(child, secs(20), "the stopped watch ran on");
    assert!(out.status.success(), "{}", stderr(&out));
    assert!(
        world
            .log("named-mail.log")
            .iter()
            .any(|l| l.ends_with(&format!(
                "--root {}",
                world.root().join("mail-root").display()
            ))),
        "the notice went under the root the start names: {:?}",
        world.log("named-mail.log")
    );
    assert_eq!(
        world.log("checkout-mail.log"),
        Vec::<String>::new(),
        "the checkout's own mailbox is never run"
    );
    let elsewhere: Vec<String> = world
        .log("tmux.log")
        .into_iter()
        .filter(|l| !l.starts_with(&named))
        .collect();
    assert_eq!(
        elsewhere,
        Vec::<String>::new(),
        "only the named server is asked"
    );
}

/// A watch start that leaves out its mailbox program, its mailbox root or
/// its server is refused by the missing name before the sign-in ladder,
/// the claim, any server or any mailbox, in a world whose checkout and
/// `$TMUX` would answer for each.
#[test]
fn a_watch_start_naming_no_mailbox_or_server_is_refused_before_any_server_or_alert() {
    let world = ReachWorld::new();
    let reach = world.reach();
    let without = |flag: &str| -> Vec<String> {
        let at = reach.iter().position(|w| w == flag).unwrap();
        let mut words = reach.clone();
        words.drain(at..at + 2);
        words
    };
    let cases = [
        (
            "--mail-program",
            "mailbox-unnamed",
            json!([["field", "mail_program"]]),
        ),
        (
            "--mail-root",
            "mailbox-unnamed",
            json!([["field", "mail_root"]]),
        ),
        ("--socket", "tmux-server-unnamed", json!([])),
    ];
    let paths = Paths::of(&world.checkout().join(FLEET_FILE_NAME)).unwrap();
    for (flag, key, fields) in cases {
        let child = world.watch(&without(flag)).spawn().expect("watch run");
        let out = bounded_output(child, secs(20), "a start naming too little ran on");
        assert_eq!(out.status.code(), Some(1), "{flag}: {}", stderr(&out));
        let answer = reply(&out);
        assert_eq!(answer["refusal"]["key"], key, "{flag}: {answer}");
        assert_eq!(answer["refusal"]["fields"], fields, "{flag}: {answer}");
        assert!(
            watch::claim::read(&paths).unwrap().is_none(),
            "{flag}: nothing claimed"
        );
    }
    for log in ["tmux.log", "named-mail.log", "checkout-mail.log"] {
        assert_eq!(
            world.log(log),
            Vec::<String>::new(),
            "{log}: nothing asked or sent"
        );
    }
}
