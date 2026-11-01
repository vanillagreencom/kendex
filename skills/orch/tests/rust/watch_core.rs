//! The scheduler core (decision 121; step5-map § A0, § A1, § B rows 5 and
//! 6, § D; decision 148): the identity-bound claim and its legacy form, the
//! duty threads on one fake clock, the event line durable before its
//! baseline row, the failure policy, the per-duty stamps, the `EVENT`
//! grammar and the legacy `watch-pid.sh` reading the runner's record. Each
//! row names the defect it catches at its doc comment.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows hold owned children, write the records they plant and drive the one fake clock"
)]

#[path = "support.rs"]
mod support;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant, SystemTime};

use agent_runtime::process::Identity;
use orch_runtime::error::Error;
use orch_runtime::ops::{self, Env, Request};
use orch_runtime::schedule::Duty;
use orch_runtime::settings::{self, Flags as SettingsFlags, Roots, Settings, Succession};
use orch_runtime::state::{self, FLEET_FILE_NAME, Locking, Owner};
use orch_runtime::watch::events::OverseerCase;
use orch_runtime::watch::{self, Change, Event, Flags, Paths, Produced, Recorded, Runner, Tick};
use serde_json::{Value, json};
use support::*;

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

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
        args: vec!["watch".into(), "run".into()],
    }
}

fn flags() -> Flags {
    Flags {
        interval: secs(240),
        max_loops: 25,
        since: None,
        replace: None,
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
}

fn log_lines(paths: &Paths) -> Vec<String> {
    std::fs::read_to_string(&paths.log)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// A duty body that counts its runs and records the fake epoch second of
/// each, emitting `event` (with a tick-specific id where it takes one) and
/// the changes `changes` gives.
struct Counting {
    runs: Arc<AtomicUsize>,
    at: Arc<std::sync::Mutex<Vec<u64>>>,
}

impl Counting {
    fn new() -> Counting {
        Counting {
            runs: Arc::new(AtomicUsize::new(0)),
            at: Arc::new(std::sync::Mutex::new(Vec::new())),
        }
    }

    fn body(
        &self,
        mut produce: impl FnMut(&Tick) -> Produced + Send + 'static,
    ) -> watch::Body<'static> {
        self.body_result(move |tick| Ok(produce(tick)))
    }

    /// A body whose runs may refuse: the count and the stamps are taken
    /// before the result is known.
    fn body_result(
        &self,
        mut produce: impl FnMut(&Tick) -> Result<Produced, Error> + Send + 'static,
    ) -> watch::Body<'static> {
        let runs = self.runs.clone();
        let at = self.at.clone();
        Box::new(move |tick: &Tick| {
            runs.fetch_add(1, Ordering::SeqCst);
            at.lock().unwrap().push(tick.wall);
            produce(tick)
        })
    }

    fn runs(&self) -> usize {
        self.runs.load(Ordering::SeqCst)
    }

    fn at(&self) -> Vec<u64> {
        self.at.lock().unwrap().clone()
    }
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

/// Plant the record a legacy `oversee-watch` writes (`watch_pid_write`):
/// the six legacy fields and no `start=`.
fn plant_legacy_claim(paths: &Paths, pid: u32) {
    std::fs::write(
        &paths.pid,
        format!(
            "pid={pid}\nstate={}\npane=none\norigin=hand\nscript=/x/oversee-watch\ncwd=/x\n",
            paths.state.display()
        ),
    )
    .unwrap();
}

/// A held child whose command line names `oversee-watch`, as the legacy
/// watch's does and as `watch_pid_runs` reads it.
fn legacy_holder() -> Owned {
    Owned(
        Command::new("bash")
            .args(["-c", "exec -a oversee-watch sleep 30"])
            .spawn()
            .expect("oversee-watch holder"),
    )
}

/// Run `runner` to its end on a thread while `drive` works the clock; the
/// run's result. A `drive` that fails still stops the runner, so a failed
/// assertion is reported rather than hanging the row on the scope's join.
/// The stop wakes only threads asleep on the clock, so a drive returns with
/// every runner thread asleep (a strict `pass` or `await_sleepers` leaves
/// them so).
fn run_driven(
    runner: Runner<'_>,
    clock: &FakeClock,
    paths: &Paths,
    identity: &Identity,
    drive: impl FnOnce(),
) -> Result<watch::Ended, Error> {
    std::thread::scope(|s| {
        let handle = s.spawn(move || runner.run());
        let drove = std::panic::catch_unwind(std::panic::AssertUnwindSafe(drive));
        if let Err(panic) = &drove {
            // Said before the join, which a body the drive was to release
            // can hold.
            let text = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| (*s).to_owned()))
                .unwrap_or_default();
            let _ = std::io::Write::write_all(
                &mut std::io::stderr(),
                format!("drive failed before the runner stopped: {text}\n").as_bytes(),
            );
        }
        let _ = watch::claim::request_stop(paths, identity);
        // One release wakes the threads asleep now; a thread still in a body
        // sleeps again past the clock, so the release repeats, in real time,
        // until the runner has ended or the bound passes.
        let bound = Instant::now() + secs(10);
        loop {
            clock.release(secs(1));
            if handle.is_finished() || Instant::now() >= bound {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if let Err(panic) = drove {
            std::panic::resume_unwind(panic);
        }
        handle.join().expect("the runner thread")
    })
}

/// Row (a). Defect: a claim judged by its pid alone, which a reused pid
/// would read live (refusing forever) or a live runner's pid read gone
/// (two runners on one fleet). A claim whose identity reads live is
/// refused `watch-running` and nothing is written; a dead pid and a reused
/// pid under another start are both taken over, each with the event line
/// naming the identity read, and the claim then names the taker.
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

/// Decision 148 (1), R-U5a F1 and follow-up 2. Defect: a start-less legacy
/// record (the one `watch_pid_write` writes on every fleet today) read as
/// released by `stop`, which answered `released` for a watch it never
/// stopped, and overwritten by `--replace`, which ran a second watch beside
/// the live legacy one; and, the other way, a start-less record whose pid a
/// later process reused read live forever. A live legacy holder refuses
/// `stop` and `--replace` as `watch-legacy-live` with nothing written; a
/// start-less record whose process started after the record was written
/// reads gone and is taken over with its line.
#[test]
fn a_live_legacy_claim_refuses_stop_and_replace_and_a_reused_pid_is_taken_over() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 20);
    let clock = FakeClock::new();
    // Live: the holder started, then the record was written, as the legacy
    // watch writes its own.
    let holder = legacy_holder();
    plant_legacy_claim(&paths, holder.pid());
    let before = std::fs::read_to_string(&paths.pid).unwrap();
    let stopped = watch::claim::stop(&paths, &clock);
    assert!(
        matches!(&stopped, Err(e) if e.key() == "watch-legacy-live"),
        "{stopped:?}"
    );
    assert!(
        std::fs::metadata(&paths.stop).is_err(),
        "no stop request is written for a legacy watch"
    );
    let replacing = Runner::new(
        paths_in(dir.path()),
        &clock,
        &settings,
        Flags {
            replace: Some(holder.pid()),
            ..flags()
        },
        me(),
        recorded(),
    );
    let replaced = replacing.run();
    assert!(
        matches!(&replaced, Err(e) if e.key() == "watch-legacy-live"),
        "{replaced:?}"
    );
    assert_eq!(
        std::fs::read_to_string(&paths.pid).unwrap(),
        before,
        "the legacy record is unchanged"
    );
    assert!(log_lines(&paths).is_empty(), "nothing was logged");
    assert!(live(holder.pid()), "the legacy holder lives");
    drop(holder);
    // Reused: the record was written before the process holding its pid
    // started, so the pid is another process's.
    let later = legacy_holder();
    plant_legacy_claim(&paths, later.pid());
    std::fs::File::options()
        .write(true)
        .open(&paths.pid)
        .unwrap()
        .set_modified(SystemTime::now() - secs(120))
        .unwrap();
    assert_eq!(
        watch::status(&paths).unwrap().claim.unwrap().standing,
        "gone"
    );
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
            "EVENT watch-taken-over pid={} start=none reason=gone",
            later.pid()
        )]
    );
    assert!(live(later.pid()), "the later process was never touched");
}

/// Decision 148 (7). Defect: a check-then-write claim, under which two
/// starts that both read the path free both write and both run. Two
/// runners started together on one fleet state: exactly one claims, the
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
    let results: Vec<Result<watch::Ended, Error>> = std::thread::scope(|s| {
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
        // The winner reaches its first sleep; the loser has returned.
        let settle = Instant::now() + secs(10);
        while clock.sleepers() == 0 && Instant::now() < settle {
            std::thread::sleep(Duration::from_millis(10));
        }
        let claim = watch::claim::read(&paths).unwrap().expect("one claim");
        let winner = contenders
            .iter()
            .find(|c| claim.names(c))
            .expect("the claim names a contender")
            .clone();
        watch::claim::request_stop(&paths, &winner).unwrap();
        let bound = Instant::now() + secs(10);
        loop {
            clock.release(secs(1));
            if handles.iter().all(|h| h.is_finished()) || Instant::now() >= bound {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        handles
            .into_iter()
            .map(|h| h.join().expect("a runner thread"))
            .collect()
    });
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

/// Decision 148 (7). Defect: a runner that never re-reads its claim, which
/// runs on after another start wrote the record over it (two runners on
/// one fleet). A claim rewritten under a running runner ends it within a
/// slice as `watch-claim-moved`, and the record stands as rewritten.
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

/// Row (b)'s sequence: a mail interval under the tick, a mail event every
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

/// The simulated verification run times under row (b)'s sequence up to
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

/// Row (b), § B row 5. Defect: the legacy reset of the heartbeat on any
/// news (step5-map F3), or a long duty's due time moved by a mail run.
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

/// Decision 148 (5), R-U5a follow-up 3. Defect: one pass stamp shared by
/// every long duty and moved by the heartbeat too, under which a restart
/// resumes verification from the heartbeat's start (6246 s in row (b)'s
/// sequence, not its own 6120 s). Each duty resumes from its own stamp.
#[test]
fn a_restart_resumes_each_duty_from_its_own_stamp() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 5);
    let clock = FakeClock::new();
    let start_wall = clock.wall_secs();
    // Row (b)'s sequence to 6006 s: the heartbeat has fired, and the
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

/// Row (c), § B row 6. Defect: one thread for every duty (the legacy
/// sequential pass, `run_due` as written), under which a tracker read held
/// for 60 s holds every mail turn. The tracker body blocks on a FIFO while
/// the clock passes 60 s in three mail intervals: three more mail runs
/// complete while the tracker's has not.
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

/// Decision 148 (2), R-U5a F2. Defect: a zero cadence spinning its thread
/// (a wait of none between two runs). Under `ORCH_WATCH_MAIL_INTERVAL=0`,
/// the legacy's "read the mail once a turn", the mail duty runs once per
/// slice: at start and once more for each second passed.
#[test]
fn a_zero_mail_interval_runs_the_mail_duty_once_per_slice() {
    let dir = tempfile::tempdir().unwrap();
    let paths = paths_in(dir.path());
    let settings = settings_in(dir.path(), 0);
    assert_eq!(settings.watch.mail_interval, Duration::ZERO);
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

/// Decision 148 (4), R-U5a follow-up 1. Defect: a duty body's error ending
/// the run (both threads, the claim released), under which one transient
/// read failure stops mail and verification until a restart. A body that
/// fails twice then succeeds: two `watch-step-failed` lines with the
/// consecutive counts, mail running throughout, and the third run's own
/// line; the run goes on until it is stopped.
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
                return Err(Error::RecordMissing {
                    path: PathBuf::from("/x/tracker"),
                });
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
            "EVENT watch-step-failed step=tracker count=2",
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

/// Decision 148 (6), R-U5a follow-up 5. Defect: a body unable to ask for a
/// run earlier than its cadence (the overseer box's 1 s poll), or a wake
/// moving a due time later. A body asking for a run 1 s later gets it, and
/// the regular cadence resumes from that run.
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

/// Row (d), § D acceptance; decision 148 (9). Defect: the baseline row
/// written before (or without) the event line's durable append, under
/// which a crash between the two loses the news. The baseline write is
/// made to fail where a crash would land, after the log's append and sync:
/// the line is on disk and the row unmoved; the next run finds the same
/// news and prints the line once more; the run after that, at the duty's
/// next due time, finds the moved row, runs and prints nothing.
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

/// Row (e). Defect: a rendering that drifts from the legacy bytes, which
/// the session's event handling keys on. Every variant against the line
/// the legacy printed (`oversee-watch`'s `echo` and `printf` sites, cited
/// at each variant; the suites' pinned heartbeat lines), and this
/// runtime's own lines as it defines them.
#[test]
fn every_event_renders_to_the_legacy_bytes() {
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
                intent: s("close-owned-resources:KEN-GONE:1-1"),
                refusal: s("lane-missing"),
            },
            "EVENT reconcile-refused intent=close-owned-resources:KEN-GONE:1-1 refusal=lane-missing",
        ),
        (
            Event::NoticeUnmarked {
                intent: s("request-transfer:overseer:3:1-1"),
                cause: s("set-replaced"),
            },
            "EVENT notice-unmarked intent=request-transfer:overseer:3:1-1 cause=set-replaced",
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
        (
            Event::WatchTakenOver {
                pid: 4242,
                start: None,
                reason: watch::Takeover::Gone,
            },
            "EVENT watch-taken-over pid=4242 start=none reason=gone",
        ),
        // oversee-watch:2162
        (
            Event::LaneReady { item: s("KEN-1") },
            "EVENT lane-ready KEN-1",
        ),
        // oversee-watch:2161
        (
            Event::LanePrepareStuck {
                item: s("KEN-1"),
                age: 1801,
                log: s("/t/prep.log"),
                reason: None,
            },
            "EVENT lane-prepare-stuck KEN-1 age=1801s log=/t/prep.log",
        ),
        // oversee-watch:4686
        (
            Event::LanePrepareStuck {
                item: s("KEN-1"),
                age: 1801,
                log: s("/t/relaunch.log"),
                reason: Some(s("relaunch-pending")),
            },
            "EVENT lane-prepare-stuck KEN-1 age=1801s log=/t/relaunch.log reason=relaunch-pending",
        ),
        // oversee-watch:2163
        (
            Event::LanePrepareFailed {
                item: s("KEN-1"),
                reason: s("wait-failed"),
                exit: None,
                log: s("/t/prep.log"),
            },
            "EVENT lane-prepare-failed KEN-1 reason=wait-failed log=/t/prep.log",
        ),
        // oversee-watch:4678
        (
            Event::LanePrepareFailed {
                item: s("KEN-1"),
                reason: s("relaunch-failed"),
                exit: Some(3),
                log: s("/t/relaunch.log"),
            },
            "EVENT lane-prepare-failed KEN-1 reason=relaunch-failed exit=3 log=/t/relaunch.log",
        ),
        // oversee-watch:1963
        (
            Event::ParkedMerged {
                item: s("KEN-1"),
                pr: s("5898"),
                repo: s("vanillagreencom/kendex"),
            },
            "EVENT parked-merged KEN-1 pr=5898 repo=vanillagreencom/kendex",
        ),
        // oversee-watch:1884
        (
            Event::ParkedClosed {
                item: s("KEN-1"),
                pr: s("5898"),
                repo: s("vanillagreencom/kendex"),
            },
            "EVENT parked-closed KEN-1 pr=5898 repo=vanillagreencom/kendex",
        ),
        // oversee-watch:1928
        (
            Event::Merged {
                line: s("5898 kendex/refresh vanillagreencom/kendex"),
            },
            "EVENT merged 5898 kendex/refresh vanillagreencom/kendex",
        ),
        // oversee-watch:2228
        (
            Event::MainWorkflowAbsent {
                repo: s("vanillagreencom/kendex"),
                workflow: s("ci.yml"),
                cause: s("not-found"),
            },
            "EVENT main-workflow-absent vanillagreencom/kendex workflow=ci.yml cause=not-found",
        ),
        // oversee-watch:2381
        (
            Event::MainPushFailing {
                repo: s("vanillagreencom/kendex"),
                workflow: s("ci.yml"),
                event: s("push"),
                run: s("1234"),
                jobs: s("guards,tests"),
                cause: s("failure"),
            },
            "EVENT main-push-failing vanillagreencom/kendex workflow=ci.yml event=push run=1234 jobs=guards,tests cause=failure",
        ),
        // oversee-watch:2487
        (
            Event::MainPushBudget {
                repo: s("vanillagreencom/kendex"),
                run: s("1234"),
                warnings: s("[\"budget\"]"),
            },
            "EVENT main-push-budget vanillagreencom/kendex workflow=skill-tests.yml run=1234 warnings=[\"budget\"]",
        ),
        // oversee-watch:2633
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
        // oversee-watch:2735
        (
            Event::LaneStalled {
                item: s("KEN-1"),
                age: 3601,
            },
            "EVENT lane-stalled KEN-1 age=3601",
        ),
        // oversee-watch:3178
        (
            Event::OwnerAskResolved {
                re: s("a-7"),
                by: s("text"),
                id: s("m-9"),
            },
            "EVENT owner-ask-resolved a-7 by=text id=m-9",
        ),
        // oversee-watch:3179
        (
            Event::OwnerAskClosed {
                re: s("a-7"),
                by: s("explicit"),
            },
            "EVENT owner-ask-closed a-7 by=explicit",
        ),
        // oversee-watch:3180
        (Event::OwnerNote { id: s("m-9") }, "EVENT owner-note m-9"),
        // oversee-watch:3181
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
        // oversee-watch:3186
        (
            Event::LaneQuestion {
                item: s("KEN-1"),
                id: s("m-9"),
            },
            "EVENT lane-question KEN-1 m-9",
        ),
        // oversee-watch:3189
        (
            Event::LaneNotice {
                item: s("KEN-1"),
                id: s("m-9"),
            },
            "EVENT lane-notice KEN-1 m-9",
        ),
        // oversee-watch:4061
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
        // oversee-watch:4159
        (
            Event::OverseerContextStale {
                pane: s("%7"),
                age: 3601,
            },
            "EVENT overseer-context-stale %7 age=3601",
        ),
        // oversee-watch:4175
        (
            Event::OverseerContextUnmeasured {
                pane: s("%7"),
                gap: s("3"),
            },
            "EVENT overseer-context-unmeasured %7 gap=3",
        ),
        // oversee-watch:4576
        (
            Event::OverseerSession {
                case: OverseerCase::Dead,
                pane: s("%7"),
                window: s("@3"),
                passes: 2,
                succession: Succession::On,
                source: s("pane"),
                record: None,
            },
            "EVENT overseer-dead %7 window=@3 passes=2 succession=on source=pane",
        ),
        (
            Event::OverseerSession {
                case: OverseerCase::Walled,
                pane: s("%7"),
                window: s("@3"),
                passes: 1,
                succession: Succession::On,
                source: s("rows"),
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
                record: Some(s("none")),
            },
            "EVENT overseer-reserve %7 window=@3 passes=1 succession=off source=rows record=none",
        ),
        // oversee-watch:4751
        (
            Event::LaneRelaunched {
                item: s("KEN-1"),
                lane: s("a2"),
                from: s("a1"),
            },
            "EVENT lane-relaunched KEN-1 lane=a2 from=a1",
        ),
        // oversee-watch:4998
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
        // oversee-watch:5067
        (
            Event::ModelCapacity { lane: s("gh-3") },
            "EVENT model-capacity gh-3",
        ),
        // oversee-watch:5092
        (
            Event::IdleAfterReturn {
                lane: s("gh-3"),
                note: Some(s("stop-cause=allow-all-blocked-by-policy")),
            },
            "EVENT idle-after-return gh-3 stop-cause=allow-all-blocked-by-policy",
        ),
        // oversee-watch:5221
        (
            Event::Account {
                fields: s("a1 harness=claude status=ok verdict=walled"),
                change: s("verdict,reset"),
                was_status: s("ok"),
                was_verdict: s("room"),
            },
            "EVENT account a1 harness=claude status=ok verdict=walled change=verdict,reset was=ok/room",
        ),
        // oversee-watch:5610 and :5621
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
    ];
    for (event, line) in rows {
        assert_eq!(event.render(), line, "{event:?}");
    }
}

/// Run the binary's `watch` verb against `dir` with the fleet server's
/// environment kept off it: the watch reads no tmux.
fn watch_cmd(dir: &Path, args: &[&str]) -> std::process::Output {
    let mut command = Command::new(binary());
    command
        .args(["--state-dir", &dir.display().to_string()])
        .args(args)
        .env("ORCH_STATE_DIR", "")
        .env("ORCH_JOB_UNIT", job_unit().display().to_string())
        .current_dir(dir);
    command.output().expect("orch-runtime watch")
}

/// Spawn the binary's `watch run --fleet` in `dir`, under the program name
/// `name` (`exec -a`), its output piped.
fn spawn_watch_run(dir: &Path, name: &str) -> std::process::Child {
    Command::new("bash")
        .args(["-c", "exec -a \"$0\" \"$@\"", name])
        .arg(binary())
        .args(["--state-dir", &dir.display().to_string()])
        .args(["watch", "run", "--fleet"])
        .env("ORCH_STATE_DIR", "")
        .env("ORCH_JOB_UNIT", job_unit().display().to_string())
        .current_dir(dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
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

/// `watch_pid_live` from the legacy library, run against `state` under
/// `env -i`: its exit status and the pid it read.
fn watch_pid_live(state: &Path) -> (i32, String) {
    let lib = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts/lib/watch-pid.sh");
    let script = format!(
        "source '{}'; watch_pid_live \"$1\"; rc=$?; printf '%s\\n' \"$WATCH_PID\"; exit $rc",
        lib.display()
    );
    let out = Command::new("env")
        .args([
            "-i",
            "PATH=/usr/bin:/bin",
            "LANG=C.UTF-8",
            "bash",
            "-c",
            &script,
            "_",
        ])
        .arg(state)
        .output()
        .expect("env -i bash");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).trim().to_owned(),
    )
}

/// Row (f), step5-map F10 and decision 121 Q7. Defect: a claim record the
/// hook's liveness check cannot read as a live watch, under which the hook
/// and the runner both read the overseer box. The binary runs `watch run`
/// under the `oversee-watch` program name the thin entry gives it;
/// `watch_pid_live` reads it live with its pid, and gone after `watch stop`.
#[test]
fn the_legacy_watch_pid_library_reads_the_runner_live_and_gone_after_stop() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    assert_eq!(watch_pid_live(&state).0, 1, "no record yet");
    // The thin `oversee-watch` entry execs the runtime under its own name
    // (Q7); the row does the same, so the record's pid is the runtime's.
    let mut child = spawn_watch_run(&state_dir, "oversee-watch");
    let paths = Paths::of(&state).unwrap();
    await_claim(&mut child, &paths);
    assert_eq!(
        watch_pid_live(&state),
        (0, child.id().to_string()),
        "the legacy library reads the runner live by its record"
    );
    let status = watch_cmd(&state_dir, &["watch", "status", "--fleet"]);
    let answer = reply(&status);
    assert_eq!(answer["result"]["claim"]["standing"], "live", "{answer}");
    assert_eq!(answer["result"]["claim"]["pid"], child.id(), "{answer}");
    let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
    let answer = reply(&stop);
    assert!(answer["ok"].as_bool().unwrap_or(false), "{}", stderr(&stop));
    assert_eq!(answer["result"]["claim"], "released", "{answer}");
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "the runner ended on the stop: {}",
        stderr(&out)
    );
    let ended = reply(&out);
    assert_eq!(ended["result"]["stopped"], "requested", "{ended}");
    assert_eq!(watch_pid_live(&state).0, 1, "gone after the stop");
    let status = watch_cmd(&state_dir, &["watch", "status", "--fleet"]);
    let answer = reply(&status);
    assert_eq!(answer["result"]["claim"], Value::Null, "{answer}");
    // The reconcile duty ran at start on the empty fleet and emitted no
    // line; its stamp and the heartbeat's are the due times reported.
    assert_eq!(answer["result"]["events"], 0, "{answer}");
    let due: BTreeMap<String, u64> = serde_json::from_value(answer["result"]["due"].clone())
        .unwrap_or_else(|e| panic!("{e}: {answer}"));
    assert_eq!(
        due.keys().cloned().collect::<Vec<_>>(),
        vec!["reconcile".to_owned()],
        "{answer}"
    );
}

/// Decision 148 (3), R-U5a-codex F2. Defect: the reconcile duty discarding
/// its report, so an open intent it could not complete or mark (a close
/// whose lane record is gone, `tests/rust/effects.rs`'s `lane-missing`
/// fixture) is never surfaced. Through `watch run`, the fixture emits one
/// `reconcile-refused` line and the intent stands unchanged.
#[test]
fn a_refused_intent_reaches_the_log_once_through_watch_run() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    let gone = json!({
        "id": "close-owned-resources:KEN-GONE:1-1", "op": "close-owned-resources",
        "target": "KEN-GONE", "created_at": "2026-01-29T15:20:00Z",
        "outcome": "unconfirmed", "lane_since": "2026-01-29T15:20:00Z",
        "obligations": {"standing": [], "discharged": [], "signalled": false, "revision": 1}
    });
    let mut fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    fleet["intents"] = json!([gone]);
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    let mut child = spawn_watch_run(&state_dir, "oversee-watch");
    let paths = Paths::of(&state).unwrap();
    await_claim(&mut child, &paths);
    let deadline = Instant::now() + secs(10);
    while watch::events::line_count(&paths.log).unwrap() == 0 {
        assert!(Instant::now() < deadline, "the reconcile never reported");
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
        log_lines(&paths),
        vec![
            "EVENT reconcile-refused intent=close-owned-resources:KEN-GONE:1-1 refusal=lane-missing"
        ]
    );
    let after: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    assert_eq!(
        after["intents"][0], gone,
        "the refused intent stands as it was"
    );
    let baseline = watch::Baseline::load(&paths.baseline).unwrap();
    assert_eq!(
        baseline.get("reconcile-refused", "close-owned-resources:KEN-GONE:1-1"),
        Some("lane-missing"),
        "the row that quiets the next pass"
    );
}

/// Work item 8, decision 143. Defect: the claim wait bounded by the tmux
/// verification bound, under which a row that shortens the tmux bound to
/// force a failed delivery also fails the claim. A detached job's claim
/// that lands after the tmux bound (5 s) and before the claim bound (15 s)
/// is accepted as `transfer-started` naming the claimant.
#[test]
fn a_claim_landing_after_the_tmux_bound_and_before_the_claim_bound_is_accepted() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let path = state_dir.join(FLEET_FILE_NAME);
    std::fs::copy(fixtures().join("workflow-state-oversee.json"), &path).unwrap();
    // A launcher that records a live group and answers at once: the job
    // then "claims" when the row says so.
    let sleeper = Owned::sleep();
    let job_unit = state_dir.join("job-unit");
    std::fs::write(
        &job_unit,
        format!(
            "#!/bin/bash\nprintf 'runner=setsid\\npid={pid}\\nstart={start}\\nline=runner=setsid reason=fixture\\n' > \"$3\"\necho 'runner=setsid pid={pid}'\n",
            pid = sleeper.pid(),
            start = sleeper.start()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&job_unit, std::fs::Permissions::from_mode(0o755)).unwrap();
    let roots = Roots {
        project: state_dir.clone(),
        common: state_dir.clone(),
    };
    let settings = settings::load(
        &roots,
        &[
            ("ORCH_TMUX_VERIFY_SECS".into(), "5".into()),
            (
                "ORCH_JOB_UNIT".into(),
                job_unit.display().to_string().into(),
            ),
            (
                "LANE_MAIL_CLI".into(),
                fixtures()
                    .join("lane-mail-quiet/lane-mail")
                    .display()
                    .to_string()
                    .into(),
            ),
        ],
        &SettingsFlags {
            state_dir: Some(state_dir.clone()),
            private_env: false,
        },
    )
    .unwrap();
    assert_eq!(settings.verify, secs(5));
    assert_eq!(settings.claim, secs(15), "the production claim bound");
    let owner = Owner {
        pid: 77,
        start: "ticks:77".into(),
    };
    let env = Env {
        now_secs: 1_769_700_000,
        now_nanos: 1_769_700_000_000_000_000,
        nonce: 77,
        owner: Some(owner.clone()),
    };
    let request: Request = serde_json::from_value(json!({
        "op": "request-transfer",
        "expected": {
            "server": "41020", "server_start": 1769590000, "pane": "%7", "generation": 3,
            "launch_line": "cd /home/u/dev/kendex && CLAUDE_CONFIG_DIR=/home/u/.claude-lanes/a1 claude --model claude-opus-5-5 --effort high",
            "cwd": "/home/u/dev/kendex", "pending": null,
        },
        "successor": {
            "launch_line": "cd /r && claude", "harness": "claude", "account": "/a", "home": "/a",
            "model": "opus", "cwd": "/r",
        },
    }))
    .unwrap();
    let locking = Locking::FLOCK;
    let applied =
        ops::apply_on(&path, &request, &env, locking, &ops::Host::kernel(4, None)).unwrap();
    let claimant = Owner {
        pid: 88,
        start: "ticks:88".into(),
    };
    let clock = FakeClock::new();
    let effected = std::thread::scope(|s| {
        let handle = s.spawn(|| {
            orch_runtime::effects::run(
                &path,
                &request,
                &applied.report,
                &settings,
                &env,
                locking,
                &clock,
            )
        });
        clock.await_sleepers(1);
        // Past the tmux bound, short of the claim bound: 8 s in 200 ms polls.
        for _ in 0..40 {
            clock.pass(Duration::from_millis(200));
        }
        let intent_id = state::load(&path).unwrap().unwrap().doc["intents"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        ops::apply(
            &path,
            &Request::ClaimIntent(ops::ClaimIntent { intent_id }),
            &Env {
                owner: Some(claimant.clone()),
                ..env.clone()
            },
            locking,
        )
        .unwrap();
        clock.release(Duration::from_millis(200));
        handle.join().expect("the launcher thread")
    });
    let effected = effected.unwrap().expect("a transfer has a live effect");
    let value = serde_json::to_value(&effected).unwrap();
    assert_eq!(value["started"], "transfer-started", "{value}");
    assert_eq!(
        value["owner"]["pid"], 88,
        "the claimant owns the intent: {value}"
    );
    assert_eq!(clock.elapsed(), Duration::from_millis(8200));
}
