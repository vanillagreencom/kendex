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

/// Step6-map A7 row (2)'s contract on the runtime: `watch status` carries
/// what the overseer's turn-end hook reads (`hooks/lane-mail-check.sh`,
/// `watch_status`): the claim's standing, its cwd and origin, and the event
/// log's path. Defect: a status that drops one, so the hook arms a follow
/// on no log, or reads a live watch's cwd as none and refuses the turn end.
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

/// How a planted legacy holder stands to the entry's stop.
#[derive(Clone, Copy)]
enum Holder {
    /// A session leader that answers TERM, as a launcher-started legacy
    /// watch stood (`job-unit.sh launch` under setsid or a unit's main
    /// process): the TERM route stops it.
    Leader,
    /// A leader that ignores TERM (`trap '' TERM` kept across its exec), as
    /// a launcher-started watch wedged in a pass stands: the TERM route
    /// runs out its bound and the group route ends it.
    DeafLeader,
    /// A process in its parent's group that ignores TERM, as a watch a shell
    /// started with `&` and wedged stands: it owns no group, so no route
    /// stops it.
    DeafMember,
}

/// A process whose command line names `oversee-watch`, shaped by `holder`:
/// started through a shell that disowns it, so init reaps it, its pid read
/// from the file it writes before it execs. Its pid. The script runs under
/// the interpreter, not by exec: a sibling row's fork can hold the
/// just-written file open and exec refuses it as busy.
fn daemon_legacy_holder(dir: &Path, holder: Holder) -> u32 {
    let inner = dir.join("holder-inner.sh");
    std::fs::write(
        &inner,
        "[ -z \"$DEAF\" ] || trap '' TERM\necho $$ > \"$1\"\nexec -a oversee-watch sleep 60\n",
    )
    .unwrap();
    let script = dir.join("holder.sh");
    let pidfile = dir.join("holder.pid");
    let (prefix, deaf) = match holder {
        Holder::Leader => ("setsid ", ""),
        Holder::DeafLeader => ("setsid ", "1"),
        Holder::DeafMember => ("", "1"),
    };
    std::fs::write(
        &script,
        format!(
            "DEAF={deaf} {prefix}bash '{}' \"$1\" >/dev/null 2>&1 &\ndisown\n",
            inner.display()
        ),
    )
    .unwrap();
    let out = Command::new("bash")
        .arg(&script)
        .arg(&pidfile)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let deadline = Instant::now() + secs(5);
    loop {
        if let Ok(text) = std::fs::read_to_string(&pidfile)
            && let Ok(pid) = text.trim().parse::<u32>()
        {
            return pid;
        }
        assert!(Instant::now() < deadline, "the holder never wrote its pid");
        std::thread::sleep(Duration::from_millis(20));
    }
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
/// later process reused read live forever; and (decisions 150 (4), 156
/// (3)) a live legacy watch read gone because a wall-clock step moved its
/// `btime`-derived start past the record's time. A live legacy holder, one
/// whose command line names `oversee-watch`, refuses `stop` and `--replace`
/// as `watch-legacy-live` with nothing written, and still reads live when
/// its record's time is set before its start; a start-less record whose
/// pid runs something else, started after the record was written, reads
/// gone and is taken over with its line.
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
    // The record's time moved before the holder's start, as a forward
    // step of the wall clock moves the `btime`-derived start past it: the
    // command line still names the watch, so it still reads live.
    std::fs::File::options()
        .write(true)
        .open(&paths.pid)
        .unwrap()
        .set_modified(SystemTime::now() - secs(120))
        .unwrap();
    assert_eq!(
        watch::status(&paths).unwrap().claim.unwrap().standing,
        "live",
        "a live legacy watch is read by its command line, not the record's time"
    );
    let stepped = runner(dir.path(), &clock, &settings, me()).run();
    assert!(
        matches!(&stepped, Err(e) if e.key() == "watch-running"),
        "{stepped:?}"
    );
    assert_eq!(
        std::fs::read_to_string(&paths.pid).unwrap(),
        before,
        "the legacy record is unchanged"
    );
    drop(holder);
    // Reused: the record was written before the process holding its pid
    // started, and that process runs something else, so the pid is another
    // process's.
    let later = Owned::sleep();
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
/// fails twice then succeeds: the first failure's `watch-step-failed` line
/// (the second is under the repeat rule, the row below), mail running
/// throughout, and the third run's own line; the run goes on until it is
/// stopped.
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

/// Decision 156 (1), R-U5a2 follow-up 1. Defect: a standing failure waking
/// the session the log follows on every pass (a `watch-step-failed` line
/// each 240 s with no news), and a body's partial failure said by the body
/// under a count of its own, outside the one rule. Under
/// `ORCH_OVERSEER_MARK_REPEAT=3`, a body failing on every one of seven runs
/// is said at the first, third and sixth; a body whose first and third runs
/// hand back a line and a cause has its line, then the failure line, and
/// its pass stamped before any clean run; its clean second run ends the
/// count, so the third is said as a first failure again. The failing duty
/// keeps its cadence from its anchor.
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
            Err(Error::RecordMissing {
                path: PathBuf::from("/x/tracker"),
            })
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
        (
            Event::WatchTakenOver {
                pid: 4242,
                start: None,
                reason: watch::Takeover::Gone,
            },
            "EVENT watch-taken-over pid=4242 start=none reason=gone",
        ),
        // U5g: the wake duty's own lines.
        (
            Event::WakeDelivered { target: s("KEN-1") },
            "EVENT wake-delivered KEN-1",
        ),
        (
            Event::WakeUnconfirmed {
                target: s("overseer"),
                cause: s("turn-pending"),
            },
            "EVENT wake-unconfirmed overseer cause=turn-pending",
        ),
        (
            Event::WakeLimit {
                target: s("KEN-1"),
                harness: s("codex"),
                cause: s("process-running"),
            },
            "EVENT wake-limit KEN-1 harness=codex cause=process-running",
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
        // U5d: the observation duty's lines (decision 152).
        // oversee-watch:4960, the bytes 744fd5727:skills/orch/tests/oversee_watch_pi_lanes.sh and
        // 744fd5727:skills/orch/tests/oversee_watch_usage_limit.sh pin
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
        // U5c: the mail duty's lines (decision 152).
        // oversee-watch:3195 and :3199, the bytes 744fd5727:skills/orch/tests/oversee_watch_mail.sh pins
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
        // U5e: the tracker and GitHub read duty's lines (decision 152).
        (
            Event::TrackerQuota {
                line: s("tracker-quota status=future reset=2026-01-01T00:10:00Z limit=requests"),
            },
            "EVENT tracker-quota status=future reset=2026-01-01T00:10:00Z limit=requests",
        ),
        // U5d2: the local-lane readings' lines (decision 152).
        // lib/watch-host-kinds.sh:462, the bytes 744fd5727:skills/orch/tests/oversee_watch_start_stall.sh
        // pins (`separate_counts`, `parked`)
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
        // U5e2: the GitHub duty's readings' lines (decision 152).
        // lib/pr-watch-pass.sh:191, the bytes 744fd5727:skills/orch/tests/oversee_watch.sh § 1 pins
        (Event::PrWatch { rc: 1 }, "EVENT pr-watch rc=1"),
        // lib/security-alerts.sh:235-245, the bytes 744fd5727:skills/orch/tests/oversee_watch_security.sh
        // pins (LINE_DEPENDABOT with pr=12, LINE_SECRET, a repeat)
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
        // lib/security-alerts.sh:298
        (
            Event::SecurityAlertsUnread {
                reads: s("owner/repo/dependabot:permission,owner/repo/code-scanning:http-502"),
            },
            "EVENT security-alerts-unread reads=owner/repo/dependabot:permission,owner/repo/code-scanning:http-502",
        ),
        // lib/outside-contribution.sh:116-117, the bytes 744fd5727:skills/orch/tests/oversee_watch_outside.sh pins
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
        // U5f: the report and heartbeat duties' lines (decision 152).
        // oversee-watch:5248 (`echo "EVENT $out"` on `oversee-report due`'s
        // line), the bytes 744fd5727:skills/orch/tests/oversee_watch_report.sh pins
        (
            Event::ReportDue {
                line: s("report-due reason=minutes since=2026-10-01T00:00:00Z"),
            },
            "EVENT report-due reason=minutes since=2026-10-01T00:00:00Z",
        ),
        // oversee-watch:5715-5733: a heartbeat body line, printed as the
        // legacy printed it, unprefixed (744fd5727:skills/orch/tests/oversee_watch_owed.sh pins
        // the `owed` line)
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

/// Run the binary's `watch` verb against `dir` with the fleet server's
/// environment kept off it: the watch reads no tmux.
fn watch_cmd(dir: &Path, args: &[&str]) -> std::process::Output {
    let mut command = isolated();
    command
        .args(["--state-dir", &dir.display().to_string()])
        .args(args)
        .env("ORCH_JOB_UNIT", job_unit().display().to_string())
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

/// The thin entry, `scripts/oversee-watch`, as the workflow starts it.
fn entry() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts/oversee-watch")
}

/// The runtime the entry execs, named by `OVERSEE_WATCH_RUNTIME`: a wrapper
/// that takes the entry's name through `ORCH_RUNTIME_NAME`, as the shipped
/// `orch-runtime` wrapper does, and adds `--no-private-env` to the test
/// binary (the shipped wrapper resolves the keyed cache binary, which a
/// test has not built).
fn runtime_wrapper(dir: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("orch-runtime");
    std::fs::write(
        &path,
        format!(
            "#!/bin/bash\nname=\"${{ORCH_RUNTIME_NAME:-$0}}\"\nunset ORCH_RUNTIME_NAME\nexec -a \"$name\" \"{}\" --no-private-env \"$@\"\n",
            binary().display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
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

/// The environment an entry start in `dir` runs under, on `command`, with
/// every duty's program named so the run is quiet on an empty fleet
/// (decision 164): the shipped mailbox client over the test directory, the
/// alert pass off (with no token file it would print its credential line),
/// the report judge as the fixture that answers "not due" (it reads its
/// reply beside the path it is invoked as, so the row links it in), and
/// `gh` as the fixture that answers the entry's credential ladder
/// (`bin/gh`, its status from `bin/gh.auth-status`, absent for 0, every
/// other call refused). `bin` is first on `PATH`, so a row's own fakes go
/// there too. The same environment serves a program that starts the entry
/// (a launcher, the retired loop), which hands it down.
fn entry_env(command: &mut Command, dir: &Path) {
    let report = dir.join("oversee-report");
    link_fixture("oversee-report-fixture/oversee-report", &report);
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    link_fixture("gh-auth-fixture/gh", &bin.join("gh"));
    isolation_env(command);
    command
        .env("PATH", tool_path(&[&bin]))
        .env("OVERSEE_WATCH_RUNTIME", runtime_wrapper(dir))
        .env("ORCH_JOB_UNIT", job_unit().display().to_string())
        .env("LANE_MAIL_CLI", lane_mail())
        .env("ORCH_SECURITY_ALERTS", "off")
        .env("OVERSEE_WATCH_REPORT", &report)
        .current_dir(dir);
}

/// The entry on the fleet state in `dir`, `--repeat 60 --state <file>` then
/// `flags`, under [`entry_env`].
fn entry_command(dir: &Path, flags: &[&str]) -> Command {
    let state = dir.join(FLEET_FILE_NAME);
    let mut command = Command::new(entry());
    entry_env(&mut command, dir);
    command
        .args(["--repeat", "60", "--state", &state.display().to_string()])
        .args(flags)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

/// The user manager a lingering host's `job-unit.sh launch` reaches, faked
/// in `dir`'s `bin` (R-U5h's probes, decision 179 (1)): `systemd-run` runs
/// a unit's argv under setsid and records its pid under `bin/units/<unit>`,
/// `systemctl stop` TERMs that group, `loginctl` says the manager lingers.
/// Copied, not linked: the fakes write their log and units beside
/// themselves.
fn install_manager_fakes(dir: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    for fake in ["systemd-run", "systemctl", "loginctl"] {
        let to = bin.join(fake);
        std::fs::copy(fixtures().join("cutover-fakes").join(fake), &to).unwrap();
        std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}

/// The workflow's launch block (`workflows/oversee.md` § 4) on the fleet
/// state in `dir`, under [`entry_env`]: `job-unit.sh launch` on the state's
/// runner record, the entry's stderr appended to its `.err`, the entry with
/// `--repeat 60 --state <state>` then `words`, the block's remaining
/// placeholders as the row fills them. The manager is the row's to fake.
fn workflow_launch(dir: &Path, words: &[&str]) -> Command {
    let state = dir.join(FLEET_FILE_NAME);
    let mut launch = Command::new("bash");
    entry_env(&mut launch, dir);
    launch
        .arg(job_unit())
        .args([
            "launch",
            "watch-R",
            &dir.join("oversee-watch.runner").display().to_string(),
            "--",
            "sh",
            "-c",
            "err=$1; shift; exec \"$@\" 2>>\"$err\"",
            "sh",
            &dir.join("oversee-watch.err").display().to_string(),
            &entry().display().to_string(),
            "--repeat",
            "60",
            "--state",
            &state.display().to_string(),
        ])
        .args(words);
    launch
}

/// The legacy record library a faithful copy of the commit-11 loop sources.
fn watch_pid_lib() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("scripts/lib/watch-pid.sh")
}

/// The runtime's claim on `paths`, once a record carrying a start names a
/// live pid, within `bound`: its pid, or none. For a runner no child handle
/// holds (a detached start).
fn await_runtime_claim(paths: &Paths, bound: Duration) -> Option<u32> {
    let deadline = Instant::now() + bound;
    loop {
        if let Ok(Some(claim)) = watch::claim::read(paths)
            && claim.start.is_some()
            && live(claim.pid)
        {
            return Some(claim.pid);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// `child` ended within `bound`: its status, or none while it still runs.
fn ended_within(
    child: &mut std::process::Child,
    bound: Duration,
) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + bound;
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return Some(status);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The output of an entry start that must end on its own within `bound`:
/// one that runs on past it is a runner the row forbids, killed and
/// reported as `overrun`.
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

/// Spawn the entry in `dir` with `flags`; the runtime it execs claims as
/// the child's pid.
fn spawn_watch_run(dir: &Path, flags: &[&str]) -> std::process::Child {
    entry_command(dir, flags).spawn().expect("spawn the entry")
}

/// Wait until the entry's runtime has claimed `paths`, bounded; a child
/// that ends first or never claims fails the row with its stderr, the
/// entry's own lines among them.
fn await_entry_claim(child: &mut std::process::Child, paths: &Paths) {
    // Past the TERM route's bound (10 s plus its one-second slack) and the
    // group teardown's kill grace (10 s) after it, so a stop that ran both
    // out reports its own line rather than this bound.
    let deadline = Instant::now() + secs(30);
    loop {
        if let Ok(Some(claim)) = watch::claim::read(paths)
            && claim.pid == child.id()
        {
            return;
        }
        let ended = child.try_wait().ok().flatten();
        if ended.is_some() || Instant::now() >= deadline {
            if ended.is_none() {
                let _ = child.kill();
            }
            let status = child.wait().ok();
            let mut err = String::new();
            if let Some(stderr) = child.stderr.as_mut() {
                let _ = std::io::Read::read_to_string(stderr, &mut err);
            }
            panic!(
                "the entry {} before its runtime claimed: {err}",
                match ended {
                    Some(status) => format!("ended {status}"),
                    None => format!("never claimed ({status:?})"),
                }
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The retained command the claim's `.argv` record holds, as
/// `watch_argv_read` splits it.
fn argv_words(paths: &Paths) -> Vec<String> {
    std::fs::read(&paths.argv)
        .unwrap()
        .split(|b| *b == 0)
        .filter(|w| !w.is_empty())
        .map(|w| String::from_utf8_lossy(w).into_owned())
        .collect()
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

/// Row (f), step5-map F10 and decision 121 Q7/Q12. Defect: a claim record
/// the hook's liveness check cannot read as a live watch, under which the
/// hook and the runner both read the overseer box; or an entry that maps
/// a legacy flag wrong, dropping one the runtime takes or handing it one it
/// does not. The thin entry, started with the retired loop's whole flag
/// set, execs the runtime under its own name: `watch_pid_live` reads the
/// claim live with the child's pid, the retained command carries the five
/// mapped flags and none of the rest, and the claim reads gone after
/// `watch stop`.
#[test]
fn the_legacy_watch_pid_library_reads_the_runner_live_and_gone_after_stop() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    assert_eq!(watch_pid_live(&state).0, 1, "no record yet");
    let mut child = spawn_watch_run(
        &state_dir,
        &[
            "--interval",
            "240",
            "--max-loops",
            "25",
            "--since",
            "2026-01-01T00:00:00Z",
            "--item",
            "KEN-1",
            "--root",
            "KEN-1=/x",
            "--hosted",
            "KEN-2=/h",
            "--skip-lane",
            "gh-9",
            "--handoff",
            "tmp/h.md",
            "--harness",
            "claude",
            "gh-1",
            "--",
            "--model",
            "opus",
        ],
    );
    let paths = Paths::of(&state).unwrap();
    await_claim(&mut child, &paths);
    assert_eq!(
        watch_pid_live(&state),
        (0, child.id().to_string()),
        "the legacy library reads the runner live by its record"
    );
    let words = argv_words(&paths);
    // The record holds the runtime's own arguments after the program and
    // the directory; the test wrapper's `--no-private-env` precedes the
    // verb, so the comparison starts at it.
    let verb = words
        .iter()
        .position(|w| w == "watch")
        .unwrap_or_else(|| panic!("{words:?}"));
    assert_eq!(
        &words[verb..],
        &[
            "watch",
            "run",
            "--file",
            &state.display().to_string(),
            "--interval",
            "240",
            "--max-loops",
            "25",
            "--since",
            "2026-01-01T00:00:00Z",
        ],
        "the retained command is the runtime's, the five flags mapped and the rest dropped: {words:?}"
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
    // Every other duty ran at start too, on an empty fleet with no unread
    // row, no controller record, no team and no repository, and emitted no
    // line; their stamps are the other due times reported. The heartbeat
    // alone is not stamped before its period.
    let mut expected: Vec<String> = Duty::ALL
        .iter()
        .filter(|d| **d != Duty::Heartbeat)
        .map(|d| d.word().to_owned())
        .collect();
    expected.sort();
    assert_eq!(
        due.keys().cloned().collect::<Vec<_>>(),
        expected,
        "{answer}"
    );
    // The credential ladder ran before the claim, one probe of the fixture.
    assert_eq!(
        std::fs::read_to_string(state_dir.join("bin/gh.log")).unwrap_or_default(),
        "auth status\n",
        "the ladder's one probe before the claim"
    );
}

/// Decision 178. Defect: an entry that starts the runtime with no GitHub
/// credential selected, so on a host whose env token is stale and whose
/// keyring fails, every GitHub read of every pass refuses where the retired
/// loop selected the project's bot token; or one that claims the fleet
/// before the ladder answers. With `gh auth status` failing and no bot
/// token to load, the entry refuses `auth-failed` (exit 2) with no claim
/// record, no retained command and no runtime started, after the ladder's
/// one probe.
#[test]
fn an_entry_that_cannot_authenticate_refuses_before_any_claim() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "init: {}", stderr(&init));
    let mut command = entry_command(&state_dir, &["--interval", "240"]);
    std::fs::write(state_dir.join("bin/gh.auth-status"), "1\n").unwrap();
    let out = bounded_output(
        command.spawn().unwrap(),
        secs(10),
        "the entry ran on with no credential selected",
    );
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(2), "{err}");
    assert!(
        err.lines()
            .any(|line| line == "oversee-watch: auth-failed service=github"),
        "{err}"
    );
    let paths = paths_in(&state_dir);
    assert!(
        !paths.pid.exists() && !paths.argv.exists(),
        "the entry claimed before the ladder answered"
    );
    assert_eq!(
        std::fs::read_to_string(state_dir.join("bin/gh.log")).unwrap_or_default(),
        "auth status\n",
        "each candidate probed once: the env token absent, the keyring once, the bot token unloadable"
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
    let mut child = spawn_watch_run(&state_dir, &[]);
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

/// Decision 184 (5), R-U6-1 M2. Defect: an owed session send no receipt
/// settles reported in the reconcile's reply alone, so the log carries
/// nothing and the operator learns of it from the next send's refusal; or
/// reported on every pass. Through `watch run` on a one-second long
/// cadence over a lane whose `directive_send` stands owed with no kept
/// receipt, the reconcile duty prints one `directive-send-unsettled` line
/// across two passes, keys it in the baseline by item and cause as
/// `reconcile-refused` is keyed, and leaves the record as it stood.
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

/// Work item 1 of the cutover (decisions 121 Q7/Q12, 148 (1), 150 (4),
/// 156 (3)). Defect: a cutover that starts the runtime beside a live watch
/// of the retired loop, which reads no stop request, so two readers hold
/// one overseer box; or an entry that stops the live runtime it should
/// defer to. The entry stops a live legacy watch by its pid, TERM to the
/// loop's trap first and its process group only where the record is held
/// past that route's bound (R-U5h2 F2), never through the runner record
/// beside the claim, waits it out and execs the runtime, which takes the
/// gone record over with its line; a second entry start beside the live
/// runtime refuses `watch-running` and the claim stands.
#[test]
fn the_entry_stops_a_live_legacy_watch_first_and_refuses_a_second_runner() {
    for (route, holder) in [("term", Holder::Leader), ("kill-group", Holder::DeafLeader)] {
        let dir = tempfile::tempdir().unwrap();
        let state_dir = std::fs::canonicalize(dir.path()).unwrap();
        let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
        assert!(init.status.success(), "{route}: {}", stderr(&init));
        let paths = Paths::of(&state_dir.join(FLEET_FILE_NAME)).unwrap();
        // No caller holds the watch, so init reaps it once it is stopped, as
        // a launcher-started watch stood; a held child would stand as a
        // zombie, which the teardown keeps counting and `watch_stop` keeps
        // reading live, each to its bound. The routes differ by whether the
        // holder answers TERM; a runner record beside the claim is read by
        // neither.
        let holder_pid = daemon_legacy_holder(&state_dir, holder);
        plant_legacy_claim(&paths, holder_pid);
        std::fs::write(
            paths.dir.join("oversee-watch.runner"),
            "runner=setsid\nline=runner=setsid reason=fixture\n",
        )
        .unwrap();
        let mut child = spawn_watch_run(&state_dir, &[]);
        await_entry_claim(&mut child, &paths);
        assert!(!live(holder_pid), "{route}: the legacy watch was stopped");
        // The takeover line lands once the runtime opens its log, after
        // the claim.
        let deadline = Instant::now() + secs(10);
        while watch::events::line_count(&paths.log).unwrap() == 0 {
            assert!(
                Instant::now() < deadline,
                "{route}: the takeover was never logged"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(
            log_lines(&paths),
            vec![format!(
                "EVENT watch-taken-over pid={holder_pid} start=none reason=gone"
            )],
            "{route}"
        );
        let second = bounded_output(
            entry_command(&state_dir, &[]).spawn().unwrap(),
            secs(10),
            &format!("{route}: a second runner ran on beside the live claim"),
        );
        assert_eq!(
            second.status.code(),
            Some(1),
            "{route}: {}",
            stderr(&second)
        );
        assert!(
            stderr(&second).contains("watch-running"),
            "{route}: the second start is refused by the one claim: {}",
            stderr(&second)
        );
        assert_eq!(
            watch::claim::read(&paths).unwrap().unwrap().pid,
            child.id(),
            "{route}: the claim stands"
        );
        let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
        assert!(
            reply(&stop)["ok"].as_bool().unwrap_or(false),
            "{route}: {}",
            stderr(&stop)
        );
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success(), "{route}: {}", stderr(&out));
        let line = stderr(&out)
            .lines()
            .find(|l| l.starts_with("oversee-watch: watch-taken-over "))
            .map(str::to_owned)
            .unwrap_or_default();
        assert!(
            line.contains(&format!("pid={holder_pid} "))
                && line.ends_with(&format!("route={route}")),
            "{route}: the entry names the watch it stopped and the route: {line:?}"
        );
    }
}

/// R-U5h F7, Copilot F1 (decision 179 (1)). Defect: a legacy stop that
/// fails read as a takeover, the entry then waiting on the pid with no
/// bound and no refusal. A holder that ignores TERM and owns no group
/// still holds its record at `watch_stop`'s bound, and the group route
/// leaves it alone: the entry refuses `watch-stop-failed` naming the TERM
/// route, exit 1, starts no runtime and claims nothing, and the holder runs
/// on.
#[test]
fn a_legacy_watch_that_holds_its_record_past_the_bound_is_a_refusal_not_a_takeover() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "{}", stderr(&init));
    let paths = Paths::of(&state_dir.join(FLEET_FILE_NAME)).unwrap();
    let holder = daemon_legacy_holder(&state_dir, Holder::DeafMember);
    plant_legacy_claim(&paths, holder);
    let record = std::fs::read_to_string(&paths.pid).unwrap();
    // Past the library's stop bound (10 s plus its one-second slack), so
    // a refusal arrives before the overrun does.
    let out = bounded_output(
        entry_command(&state_dir, &[]).spawn().unwrap(),
        secs(20),
        "the entry waited past the stop bound on a watch it could not stop",
    );
    let holder_live = live(holder);
    let _ = program("kill")
        .args(["-KILL", &holder.to_string()])
        .output();
    let err = stderr(&out);
    assert_eq!(out.status.code(), Some(1), "{err}");
    assert!(
        err.lines()
            .any(|l| l
                == format!("oversee-watch: watch-stop-failed pid={holder} route=term secs=10")),
        "the refusal names the watch and the route: {err:?}"
    );
    assert!(
        !err.contains("watch-taken-over"),
        "no takeover is said for a watch not taken over: {err:?}"
    );
    assert!(holder_live, "the watch ran on");
    assert_eq!(
        std::fs::read_to_string(&paths.pid).unwrap(),
        record,
        "the claim stands as the watch wrote it"
    );
    assert!(!paths.argv.exists(), "no runtime started");
}

/// Decision 179 (1), R-U5h F1 site a. Defect: the entry stopping a legacy
/// watch by the launcher's runner record, which the workflow's own launch
/// line writes for the entry's unit before the entry runs, so the entry
/// stops itself and the legacy watch runs on. The workflow's launch line
/// through the real `job-unit.sh launch` under a lingering user manager
/// (faked), beside a live start-less record whose holder stands as a unit
/// of its own: the holder ends, the runtime claims under the launched
/// unit, and `oversee-watch.err` carries the entry's takeover line with the
/// pid route it took.
#[test]
fn the_workflow_launch_cuts_over_a_live_legacy_unit_by_its_pid() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "{}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    let paths = Paths::of(&state).unwrap();
    install_manager_fakes(&state_dir);
    let holder = daemon_legacy_holder(&state_dir, Holder::Leader);
    plant_legacy_claim(&paths, holder);
    let units = state_dir.join("bin/units");
    std::fs::create_dir_all(&units).unwrap();
    std::fs::write(units.join("orch-watch-OLD-1"), format!("{holder}\n")).unwrap();
    let record = paths.dir.join("oversee-watch.runner");
    std::fs::write(
        &record,
        "runner=systemd\nunit=orch-watch-OLD-1\nline=runner=systemd unit=orch-watch-OLD-1\n",
    )
    .unwrap();
    let err = paths.dir.join("oversee-watch.err");
    let out = workflow_launch(&state_dir, &["--interval", "240"])
        .output()
        .unwrap();
    assert!(out.status.success(), "the launch: {}", stderr(&out));
    let launched = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    // Past the group teardown's kill grace (10 s), so a stop that ran it
    // out is read as its own line rather than the bound.
    let claimed = await_runtime_claim(&paths, secs(25));
    let holder_live = live(holder);
    let err_text = std::fs::read_to_string(&err).unwrap_or_default();
    let record_after = std::fs::read_to_string(&record).unwrap_or_default();
    // The detached runner is nobody's child: stopped before the asserts,
    // whatever they say.
    if claimed.is_some() {
        let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
        assert!(
            reply(&stop)["ok"].as_bool().unwrap_or(false),
            "{}",
            stderr(&stop)
        );
    }
    if holder_live {
        let _ = program("kill").arg(holder.to_string()).output();
    }
    assert!(
        launched.starts_with("runner=systemd unit=orch-watch-R-"),
        "the launch ran as a unit: {launched}"
    );
    assert_eq!(
        record_after,
        format!(
            "runner=systemd\nunit={}\nline={launched}\n",
            &launched["runner=systemd unit=".len()..]
        ),
        "the launch wrote the entry's own unit over the holder's record"
    );
    assert!(!holder_live, "the legacy holder was stopped: {err_text}");
    let claimed = claimed
        .unwrap_or_else(|| panic!("the runtime claimed under the launched unit: {err_text}"));
    assert_ne!(claimed, holder);
    assert!(
        err_text.lines().any(|l| l
            == format!(
                "oversee-watch: watch-taken-over pid={holder} pane=none reason=legacy route=term"
            )),
        "the entry's takeover line names the holder and the pid route: {err_text:?}"
    );
}

/// R-U5h2 F2 (decision 180). Defect: a cutover stop that signals the loop's
/// whole process group, which ends a `lane-close` the loop's pass is part
/// way through (`lane-close` traps no TERM), where the loop's own TERM
/// route reaches its trap alone and the pass keeps the close to its row.
/// The commit-11 loop's claim, traps and pass (`fixtures/cutover-fakes/
/// legacy-close-loop`) leading its group as a launcher started it, its pass
/// inside a close that takes seconds (`lane-close-slow`), and the entry
/// started beside it: the entry stops the loop on the TERM route, waits it
/// out, and the close's end is in the log before the runtime claims.
#[test]
fn a_cutover_stop_beside_a_lane_close_in_flight_lets_the_close_finish() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "{}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    let paths = Paths::of(&state).unwrap();
    // Installed under the loop's own name, so its command line names
    // oversee-watch as `watch_pid_runs` reads it; the close beside it is
    // run by path, so it carries the fixture's mode.
    let legacy_dir = state_dir.join("legacy");
    std::fs::create_dir_all(&legacy_dir).unwrap();
    let legacy_script = legacy_dir.join("oversee-watch");
    std::fs::copy(
        fixtures().join("cutover-fakes/legacy-close-loop"),
        &legacy_script,
    )
    .unwrap();
    let close = legacy_dir.join("lane-close");
    std::fs::copy(fixtures().join("cutover-fakes/lane-close-slow"), &close).unwrap();
    std::fs::set_permissions(&close, std::fs::Permissions::from_mode(0o755)).unwrap();
    let log = state_dir.join("legacy.log");
    // Started through a shell that disowns it, so init reaps it once it is
    // stopped, as `daemon_legacy_holder` starts its holders; under setsid
    // it leads its group, as a launcher-started loop did.
    let starter = state_dir.join("start-loop.sh");
    std::fs::write(
        &starter,
        format!(
            "setsid bash '{}' \"$1\" \"$2\" \"$3\" >/dev/null 2>&1 </dev/null &\ndisown\n",
            legacy_script.display()
        ),
    )
    .unwrap();
    let out = program("bash")
        .arg(&starter)
        .arg(&state)
        .arg(&log)
        .arg(&close)
        .env("WATCH_PID_LIB", watch_pid_lib())
        .env("CLOSE_LOG", &log)
        // Longer than the entry takes to reach its stop, so the stop meets
        // the close in flight.
        .env("CLOSE_SECS", "5")
        .current_dir(&state_dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let deadline = Instant::now() + secs(10);
    while !std::fs::read_to_string(&log)
        .unwrap_or_default()
        .contains("close: started")
    {
        assert!(
            Instant::now() < deadline,
            "the close never started: {}",
            std::fs::read_to_string(&log).unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let loop_pid = watch::claim::read(&paths)
        .unwrap()
        .expect("the loop's claim")
        .pid;
    let mut child = spawn_watch_run(&state_dir, &[]);
    await_entry_claim(&mut child, &paths);
    let at_claim = std::fs::read_to_string(&log).unwrap_or_default();
    let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
    assert!(
        reply(&stop)["ok"].as_bool().unwrap_or(false),
        "{}",
        stderr(&stop)
    );
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let err = stderr(&out);
    assert!(
        at_claim.contains("close: done\n"),
        "the close ran to its end before the runtime claimed: {at_claim}{err}"
    );
    assert!(
        err.lines().any(|l| l
            == format!(
                "oversee-watch: watch-taken-over pid={loop_pid} pane=none reason=legacy route=term"
            )),
        "the loop was stopped on its own TERM route: {err:?}"
    );
}

/// Decision 179 (1), R-U5h F1 site b. Defect: the loop's own pass, which is
/// the entry once this tree is installed over the loop's script, stopping
/// its parent, whose trap ends the pass with it: the loop exits 143 and no
/// watch stands. A faithful copy of the commit-11 loop's claim, traps and
/// pass spawn (`fixtures/cutover-fakes/legacy-oversee-watch`) runs the real
/// entry as its pass under the faked lingering manager: the pass starts one
/// entry detached through the workflow's launch line, says so and exits 4;
/// the loop reads that status and ends releasing its record (0 on its own,
/// 143 where the detached entry's stop reached it first, both the release);
/// the detached entry claims as the one runner. The stop can reach the loop
/// before the pass's launch returns, which ends the pass with nothing said
/// (R-U5h2 Copilot S1): the pass's words are owed only where the loop read
/// its status.
#[test]
fn the_loops_own_pass_relaunches_the_entry_detached_and_the_loop_ends() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "{}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    let paths = Paths::of(&state).unwrap();
    install_manager_fakes(&state_dir);
    // Installed under the loop's own name, so its command line names
    // oversee-watch as `watch_pid_runs` reads it.
    let legacy_dir = state_dir.join("legacy");
    std::fs::create_dir_all(&legacy_dir).unwrap();
    let legacy_script = legacy_dir.join("oversee-watch");
    std::fs::copy(
        fixtures().join("cutover-fakes/legacy-oversee-watch"),
        &legacy_script,
    )
    .unwrap();
    let log = state_dir.join("legacy.log");
    let mut command = Command::new("setsid");
    entry_env(&mut command, &state_dir);
    command
        .arg("bash")
        .arg(&legacy_script)
        .arg(&state)
        .arg(entry())
        .arg(&log)
        .env("WATCH_PID_LIB", watch_pid_lib())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut legacy = command.spawn().unwrap();
    let claimed = await_runtime_claim(&paths, secs(25));
    let ended = ended_within(&mut legacy, secs(10));
    let legacy_log = std::fs::read_to_string(&log).unwrap_or_default();
    let pass_err =
        std::fs::read_to_string(state_dir.join("legacy.log.pass-err")).unwrap_or_default();
    let record =
        std::fs::read_to_string(paths.dir.join("oversee-watch.runner")).unwrap_or_default();
    if claimed.is_some() {
        let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
        assert!(
            reply(&stop)["ok"].as_bool().unwrap_or(false),
            "{}",
            stderr(&stop)
        );
    }
    if ended.is_none() {
        let _ = legacy.kill();
        let _ = legacy.wait();
    }
    let claimed = claimed.unwrap_or_else(|| {
        panic!("one runner claimed after the loop's pass: {legacy_log}{pass_err}")
    });
    assert_ne!(
        claimed,
        legacy.id(),
        "the runner is the detached entry's, not the loop"
    );
    let code = ended.and_then(|s| s.code());
    assert!(
        matches!(code, Some(0) | Some(143)),
        "the loop ended releasing its record: {code:?} {legacy_log}"
    );
    // The race between the pass's exit and the detached entry's stop: a
    // loop that read its pass's status read 4, and the pass said what it
    // started; one the stop reached while the pass was still inside its
    // launch ended the pass with itself and said nothing.
    if legacy_log.contains("legacy: pass rc=") {
        assert!(
            legacy_log.contains("legacy: pass rc=4\n"),
            "the loop read the pass as its stop status: {legacy_log}"
        );
        assert!(
            pass_err.lines().any(|l| l.starts_with(&format!(
                "oversee-watch: watch-relaunched pid={} unit=runner=systemd unit=orch-watch-",
                legacy.id()
            ))),
            "the pass says what it started and for which loop: {pass_err:?}"
        );
    } else {
        assert_eq!(
            code,
            Some(143),
            "the loop ended by the detached entry's stop before its pass returned: {legacy_log}"
        );
    }
    assert!(
        record.starts_with("runner=systemd\nunit=orch-watch-"),
        "the detached entry's unit stands as the one runner: {record:?}"
    );
}

/// Decision 179 (2), R-U5h F2, R-U5h2 F1. Defect: a watch start that drops
/// `--harness` and `-- FLAGS`, so a hand-opened overseer's record holds no
/// launch line and its death has no successor to replay (`held_successor`),
/// or keeps a former session's line and its permission words; the
/// workflow's launch block once passed neither. The record `oversee
/// register` writes for a hand-opened session (this pane on this server, its
/// start, an identity, no line) and the workflow's launch block, its
/// placeholders filled, run from that pane: the record's `launch_line` is
/// the line `oversee-succeed --print-launch-line` printed for the block's
/// harness and flags, the permission word among them, and the identity
/// stands beside it.
#[test]
fn a_registered_sessions_record_holds_the_line_the_entry_hands_on() {
    let dir = tempfile::tempdir().unwrap();
    let state_dir = std::fs::canonicalize(dir.path()).unwrap();
    let server = Server::start(&state_dir, "fleet");
    let init = watch_cmd(&state_dir, &["state", "init", "--fleet"]);
    assert!(init.status.success(), "{}", stderr(&init));
    let state = state_dir.join(FLEET_FILE_NAME);
    let paths = Paths::of(&state).unwrap();
    install_manager_fakes(&state_dir);
    let pane = server.open_idle("overseer", &state_dir);
    let mut fleet: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    fleet["overseer"] = json!({
        "runtime": "tmux",
        "generation": 1,
        "server": server.pid.to_string(),
        "server_start": server.start,
        "server_socket": server.socket.display().to_string(),
        "pane": pane,
        "harness": "claude",
        "account": state_dir.display().to_string(),
        "home": state_dir.display().to_string(),
        "model": "opus",
        "cwd": state_dir.display().to_string(),
    });
    std::fs::write(&state, serde_json::to_string_pretty(&fleet).unwrap()).unwrap();
    // The block's words after `--state`, each placeholder filled; the
    // launch runs in the pane, as § 4 has it.
    let mut launch = workflow_launch(
        &state_dir,
        &[
            "--interval",
            "240",
            "--since",
            "2026-01-01T00:00:00Z",
            "--harness",
            "codex",
            "--repo",
            "owner/items",
            "--repo",
            "owner/other",
            "--",
            "--dangerously-bypass-approvals-and-sandbox",
            "--model",
            "fable",
        ],
    );
    launch
        .env("TMUX", format!("{},0,0", server.socket.display()))
        .env("TMUX_PANE", &pane)
        .env(
            "OVERSEE_WATCH_SUCCEED",
            fixtures().join("succeed-print/oversee-succeed"),
        );
    let out = launch.output().unwrap();
    assert!(out.status.success(), "the launch: {}", stderr(&out));
    let claimed = await_runtime_claim(&paths, secs(25));
    let err_text = std::fs::read_to_string(paths.dir.join("oversee-watch.err")).unwrap_or_default();
    let after: Value = serde_json::from_str(&std::fs::read_to_string(&state).unwrap()).unwrap();
    // The detached runner is nobody's child: stopped before the asserts.
    if claimed.is_some() {
        let stop = watch_cmd(&state_dir, &["watch", "stop", "--fleet"]);
        assert!(
            reply(&stop)["ok"].as_bool().unwrap_or(false),
            "{}",
            stderr(&stop)
        );
    }
    assert!(
        claimed.is_some(),
        "the runtime claimed under the launched unit: {err_text}"
    );
    let overseer = &after["overseer"];
    assert_eq!(
        overseer["launch_line"],
        "launch: --print-launch-line --handoff tmp/handoffs/OVERSEER-HANDOFF.md --harness codex -- --dangerously-bypass-approvals-and-sandbox --model fable",
        "the line a death replays is the print of the block's harness and flags, the permission word among them: {overseer} {err_text}"
    );
    assert_eq!(
        (
            overseer["pane"].as_str(),
            overseer["harness"].as_str(),
            overseer["model"].as_str()
        ),
        (Some(pane.as_str()), Some("claude"), Some("opus")),
        "the registered identity stands beside it: {overseer}"
    );
}

/// Work item 2 of the cutover (decisions 121 Q3/Q15, 176 (2)): the handover
/// layer is gone. Defect: a succession that stops, replaces or restarts the
/// fleet watch, so the successor reads a log a restart truncated or a
/// claim another runner holds. A real transfer through the runtime, beside
/// the entry's live runner whose log holds one line (the takeover of a gone
/// legacy record, planted): the claim names the same runner before and
/// after, that line stands, and the successor's `watch log --since` from
/// the handoff's last line returns it at its number with what followed.
#[test]
fn a_succession_under_a_live_scheduler_leaves_its_claim_and_log_and_the_successor_reads_on() {
    let dir = tempfile::tempdir().unwrap();
    let server = Server::start(dir.path(), "fleet");
    let runner = support::Runner::new(&server, "stub-confirm");
    runner.init_fleet();
    let state_dir = std::fs::canonicalize(runner.state_dir()).unwrap();
    let paths = Paths::of(&state_dir.join(FLEET_FILE_NAME)).unwrap();
    plant_legacy_claim(&paths, GONE_PID as u32);
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
    assert_eq!(runner.fleet()["overseer"]["generation"], 4, "published");
    assert_eq!(
        watch::claim::read(&paths).unwrap().unwrap(),
        claim_before,
        "the succession left the claim as it stood"
    );
    assert_eq!(
        watch_pid_live(&paths.state),
        (0, child.id().to_string()),
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
