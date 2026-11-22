//! The standing scheduler: one long-lived `watch run` per fleet state,
//! claimed by process identity, running every duty on its own due time
//! from one clock and writing every event the controller session follows
//! to one numbered log.
//!
//! Threads: the mail duty runs on its own thread and every other duty on
//! one shared thread, each thread owning the due times of its duties, so a
//! slow tracker read never delays a mail turn and a slow mail call never
//! delays the shared duties. Each duty's due time is its own (`schedule`):
//! running one moves no other, each resumes from its own pass stamp after
//! a restart, and the heartbeat is due every `max-loops × interval` seconds
//! from the last heartbeat, never moved by an event.
//!
//! A due duty that finds nothing emits no line, so the session it follows
//! is not woken; the heartbeat is the only periodic line. A duty hands back
//! the events it has and the baseline changes they imply; `commit` appends
//! and syncs the events first, then writes the baseline, so a crash between
//! the two reprints the line on the duty's next run and never loses it.
//!
//! Failure policy: a duty body that fails, whole or in part, is loud in the
//! log, `EVENT watch-step-failed step=<duty> count=N` with the consecutive
//! count, its cause on stderr, and its due time moves one cadence on from
//! its anchor; the other duties and the other thread go on. The line goes
//! out on the first failure and every `ORCH_OVERSEER_MARK_REPEAT`th after,
//! so a standing failure does not wake the session it follows every pass;
//! a run with no failure ends the count. Only the runner's own records
//! failing (the log, the baseline, the claim, the stop request) end the
//! run, `watch-record`, which releases the claim. A duty whose program
//! answers that this installation cannot serve it (agent-runtime unbuilt,
//! as while an update builds it) fails its step like any other: nothing
//! starts a watch again, so the run keeps its claim, the duty is done on
//! its first pass after the build, and on an installation that stays
//! unbuilt the line wakes the session it follows to a cause naming the
//! setup.
//!
//! A runner placed from an orch install's sources follows them
//! (`program`): at the start of each long pass it reads their key, and
//! where it names another placed program the two threads end at their next
//! duty boundary and the process replaces itself with that program in
//! place, the same pid and start, so the claim still names it, the log and
//! every reader's cursor stand, and the new program reads the claim as its
//! own. A program not placed yet leaves the run on its own program.
//!
//! The runner reconciles every open intent on the long cadence through the
//! existing `reconcile` request, which is read-only toward a live or
//! unreadable owner; a transfer's or stop's effect keeps its own detached
//! job. It stops on `watch stop` or a terminal signal; a stop releases the
//! claim, a signal leaves it for the next runner to read gone and take
//! over.

pub mod baseline;
pub mod claim;
pub mod context;
pub mod events;
pub mod github;
pub mod heartbeat;
pub mod hosted;
pub mod lanes;
pub mod mail;
pub mod outside;
pub mod overseer;
pub mod owner_alert;
pub mod pr_watch;
pub mod program;
pub mod report;
pub mod retention;
pub mod security;
pub mod tracker;
pub mod verifying;
pub mod wake;

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, UNIX_EPOCH};

use agent_runtime::process::Identity;
use agent_runtime::reading::Reading;
use serde::Serialize;

use crate::error::{Error, Result, WatchError};
use agent_runtime::clock::Clock;

use crate::schedule::{Anchor, Cadences, Duty, Schedule};
use crate::settings::Settings;
use program::{Current, Program};

pub use baseline::{Baseline, Change};
pub use claim::{Paths, Stopped};
pub use events::{Event, EventLog, Takeover};

/// The longest one wait between two reads of the stop request and the
/// claim: a stop lands within this, and a duty due again at once waits this
/// long first.
const SLICE: Duration = Duration::from_secs(1);

/// How many times a start tries its claim after another start linked a
/// record first: the second try reads what that start wrote.
const CLAIM_TRIES: u32 = 2;

/// What a duty hands back from one run: the lines to append, in order, the
/// baseline changes those lines settle, the instant it asks to run again
/// at where that is earlier than its cadence gives (the overseer box's
/// poll), and the cause where part of the run failed (a mailbox the turn
/// could not read, a due ask that would not close) while its lines and
/// rows stand: the runner counts it under the one failure rule and says
/// the cause. Nothing found is nothing of any.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Produced {
    pub events: Vec<Event>,
    pub changes: Vec<Change>,
    pub next_due: Option<Instant>,
    pub failed: Option<String>,
    /// The run judged nothing the failure count is about (the mail duty's
    /// one-second poll between full turns): it neither counts a failure
    /// nor ends a standing one.
    pub unjudged: bool,
}

/// What a duty runs with: the instant and epoch second it was started at,
/// the baseline as it stood (a snapshot, so a slow body holds no lock) and
/// the clock, for a body that waits or reads a moment.
pub struct Tick<'a> {
    pub duty: Duty,
    pub now: Instant,
    pub wall: u64,
    pub baseline: &'a Baseline,
    pub clock: &'a dyn Clock,
}

/// A duty's body, registered by its duty. It reads what it must and hands
/// back what it found; the runner writes.
pub type Body<'a> = Box<dyn FnMut(&Tick) -> Result<Produced> + Send + 'a>;

/// The runner's own flags: `--interval`, `--max-loops`, `--since` and
/// `--fresh`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flags {
    pub interval: Duration,
    pub max_loops: u32,
    /// Printed in the heartbeat's `since=` field: the stamp the runner was
    /// handed.
    pub since: Option<String>,
    /// A fleet's first start: the log is emptied once the claim is taken,
    /// so a fresh reader from line 1 is handed no earlier fleet's line.
    pub fresh: bool,
}

/// How a run ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Ended {
    /// The number of the last event line in the log.
    pub events: u64,
    pub stopped: &'static str,
}

/// The runner's records open: the log and the baseline, under one lock so
/// the two threads' commits serialize and line numbers stay in order.
struct Store {
    log: EventLog,
    baseline: Baseline,
    paths: Paths,
}

pub struct Runner<'a> {
    paths: Paths,
    clock: &'a dyn Clock,
    identity: Identity,
    record: Recorded,
    flags: Flags,
    cadences: Cadences,
    mark_repeat: u32,
    bodies: Vec<(Duty, Body<'a>)>,
    /// The placed program this runner runs as, followed against its
    /// install's sources; `None` follows nothing.
    program: Option<Program>,
}

/// How the runner holds its claim.
enum Held {
    /// Linked into place by this start; `takeover` is the line where it
    /// took a gone runner's claim over.
    Claimed { takeover: Option<Event> },
    /// Standing under this runner's own identity: this process held it
    /// before it replaced its program in place, and `replaced` says so.
    Resumed { replaced: Event },
}

/// What the claim records of the process beside its identity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recorded {
    pub pane: String,
    pub script: String,
    pub cwd: String,
}

/// The epoch second the clock's wall reads: what a baseline row holds.
#[allow(
    clippy::disallowed_methods,
    reason = "the runner's one wall-clock read of the injected clock, for the epoch second its rows record"
)]
fn epoch(clock: &dyn Clock) -> u64 {
    clock
        .wall()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The instant a duty is due at, from the epoch second its row recorded and
/// its cadence: `now` plus what remains of the cadence, or `now` where the
/// cadence has passed. With no row, `first`: the mail turn and the long
/// duties run at once, the heartbeat one period out.
fn due_from_row(
    now: Instant,
    wall: u64,
    last: Option<u64>,
    every: Duration,
    first: Duration,
) -> Instant {
    match last {
        Some(last) => now + every.saturating_sub(Duration::from_secs(wall.saturating_sub(last))),
        None => now + first,
    }
}

impl<'a> Runner<'a> {
    /// A runner over the fleet state `paths` name, claiming as `identity`,
    /// with the heartbeat registered; every other duty is registered by its
    /// owner through [`Runner::register`]. The watch's settings are judged
    /// here, before the claim, so a value outside its form refuses the run.
    pub fn new(
        paths: Paths,
        clock: &'a dyn Clock,
        settings: &Settings,
        flags: Flags,
        identity: Identity,
        record: Recorded,
    ) -> Result<Runner<'a>> {
        let watch = settings.watch.get()?;
        let cadences = Cadences::of_settings(watch.mail_interval, flags.interval, flags.max_loops);
        let heartbeat = Event::Heartbeat {
            loops: flags.max_loops,
            interval: flags.interval,
            since: flags.since.clone(),
        };
        let mut runner = Runner {
            paths,
            clock,
            identity,
            record,
            flags,
            cadences,
            mark_repeat: watch.mark_repeat,
            bodies: Vec::new(),
            program: None,
        };
        // The heartbeat's line with the fields the runner holds; its pass
        // stamp is the runner's, as every duty's is. The heartbeat module's
        // body replaces this registration.
        runner.register(
            Duty::Heartbeat,
            Box::new(move |_: &Tick| {
                Ok(Produced {
                    events: vec![heartbeat.clone()],
                    ..Produced::default()
                })
            }),
        );
        Ok(runner)
    }

    /// Register `body` for `duty`, replacing one registered before.
    pub fn register(&mut self, duty: Duty, body: Body<'a>) {
        self.bodies.retain(|(d, _)| *d != duty);
        self.bodies.push((duty, body));
    }

    pub fn cadences(&self) -> &Cadences {
        &self.cadences
    }

    /// Follow `program` against its install's sources.
    pub fn follow(&mut self, program: Program) {
        self.program = Some(program);
    }

    /// Claim, open the records, run the duties until a stop, release.
    pub fn run(mut self) -> Result<Ended> {
        let held = self.claim()?;
        let bodies = std::mem::take(&mut self.bodies);
        let outcome = self.serve(held, bodies);
        // The claim is released whatever ended the run, where it still
        // names this runner, so a stop leaves no record a successor must
        // read gone first and a moved claim is left to its holder.
        let released = claim::release(&self.paths, &self.identity);
        let cleared = claim::clear_stop(&self.paths);
        let ended = outcome?;
        released?;
        cleared?;
        Ok(ended)
    }

    /// Take the claim: refuse a live one, take over a gone one with the event
    /// that says so, refuse an unreadable one. Linked into place before any
    /// duty runs; where another start links first, what it wrote is read.
    /// One that names this runner's identity is this process's own from
    /// before it replaced its program, and is resumed.
    fn claim(&self) -> Result<Held> {
        let record = claim::Record {
            identity: &self.identity,
            pane: &self.record.pane,
            origin: "hand",
            script: &self.record.script,
            cwd: &self.record.cwd,
        };
        for _ in 0..CLAIM_TRIES {
            let mut takeover = None;
            if let Some(standing) = claim::read(&self.paths)? {
                if standing.names(&self.identity) {
                    return self.resume(&standing);
                }
                match claim::read_live(&standing) {
                    Reading::Live(live) => {
                        return Err(WatchError::Running {
                            path: self.paths.pid.clone(),
                            pid: live.pid,
                            start: live.start,
                        }
                        .into());
                    }
                    Reading::Gone => {
                        takeover = Some(Event::WatchTakenOver {
                            pid: standing.pid,
                            start: standing.start.clone(),
                            reason: Takeover::Gone,
                        });
                    }
                    Reading::Unreadable { cause } => {
                        return Err(WatchError::ClaimUnreadable {
                            path: self.paths.pid.clone(),
                            pid: standing.pid,
                            cause: cause.to_owned(),
                        }
                        .into());
                    }
                }
                claim::remove_gone(&self.paths)?;
            }
            match claim::write(&self.paths, &record)? {
                claim::Written::Claimed => {
                    // A stop request left for the runner this one replaces
                    // is served.
                    claim::clear_stop(&self.paths)?;
                    return Ok(Held::Claimed { takeover });
                }
                claim::Written::Held => continue,
            }
        }
        // Another start linked first on every try: what stands is its.
        let standing = claim::read(&self.paths)?;
        Err(WatchError::Running {
            path: self.paths.pid.clone(),
            pid: standing.as_ref().map_or(0, |c| c.pid),
            start: standing.and_then(|c| c.start).unwrap_or_default(),
        }
        .into())
    }

    /// Resume this process's own claim under the program it now runs: the
    /// record is rewritten with its script, its origin kept, and a stop
    /// request naming the identity is left standing for the loop to serve.
    fn resume(&self, standing: &claim::Claim) -> Result<Held> {
        claim::rewrite(
            &self.paths,
            &claim::Record {
                identity: &self.identity,
                pane: &self.record.pane,
                origin: &standing.origin,
                script: &self.record.script,
                cwd: &self.record.cwd,
            },
        )?;
        let key = |script: &str| {
            program::key_of(Path::new(script))
                .unwrap_or("none")
                .to_owned()
        };
        Ok(Held::Resumed {
            replaced: Event::WatchReplaced {
                from: key(&standing.script),
                to: key(&self.record.script),
            },
        })
    }

    /// Open the records, start the schedules at the clock's instant from the
    /// recorded rows, and run the two duty threads until one ends. Where
    /// they ended for a placed program, replace the process with it; an
    /// exec that fails is said and the threads run again.
    #[allow(
        clippy::disallowed_methods,
        reason = "the runner's start: the one instant the schedules count from, read off the injected clock"
    )]
    fn serve(&self, held: Held, bodies: Vec<(Duty, Body<'a>)>) -> Result<Ended> {
        // A resumed claim's log is the one its readers follow: a fresh
        // start's emptying was this process's first start's.
        let (opening, fresh) = match held {
            Held::Claimed { takeover } => (takeover, self.flags.fresh),
            Held::Resumed { replaced } => (Some(replaced), false),
        };
        let mut baseline = Baseline::load(&self.paths.baseline)?;
        baseline.cadences = Some(baseline::Cadences {
            mail_secs: self.cadences.mail.every.as_secs(),
            interval_secs: self.cadences.long.every.as_secs(),
            max_loops: self.flags.max_loops,
        });
        if fresh {
            events::empty(&self.paths.log)?;
        }
        let mut log = EventLog::open(&self.paths.log)?;
        if let Some(event) = opening {
            log.append(&[event])?;
        }
        let now = self.clock.now();
        let wall = epoch(self.clock);
        let registered: Vec<Duty> = bodies.iter().map(|(d, _)| *d).collect();
        let (mail_duties, shared_duties): (Vec<Duty>, Vec<Duty>) =
            registered.iter().partition(|d| **d == Duty::Mail);
        let mut mail = Schedule::new(&self.cadences, now, &mail_duties);
        let mut shared = Schedule::new(&self.cadences, now, &shared_duties);
        for schedule in [&mut mail, &mut shared] {
            for duty in schedule.duties() {
                let every = self.cadences.of(duty).every;
                let first = match duty {
                    Duty::Heartbeat => every,
                    Duty::Wake
                    | Duty::GitHub
                    | Duty::Retention
                    | Duty::Mail
                    | Duty::NativeObservation
                    | Duty::Tracker
                    | Duty::Verification
                    | Duty::Report
                    | Duty::Reconcile => Duration::ZERO,
                };
                let last = baseline.passes.get(&duty).copied();
                schedule.set_due(duty, due_from_row(now, wall, last, every, first));
            }
        }
        let store = Mutex::new(Store {
            log,
            baseline,
            paths: self.paths.clone(),
        });
        let stop = AtomicBool::new(false);
        let failure: Mutex<Option<Error>> = Mutex::new(None);
        let (mut mail_body, mut shared_body): (Vec<_>, Vec<_>) =
            bodies.into_iter().partition(|(d, _)| *d == Duty::Mail);
        let follow = self.program.as_ref().map(|program| Follow {
            program,
            cadences: self.cadences,
            said: Mutex::new(None),
            unread: Mutex::new(None),
            placed: Mutex::new(None),
            failed: Mutex::new(None),
        });
        let thread = Thread {
            store: &store,
            stop: &stop,
            clock: self.clock,
            paths: &self.paths,
            identity: &self.identity,
            mark_repeat: self.mark_repeat,
            follow: follow.as_ref(),
        };
        loop {
            std::thread::scope(|s| {
                if !mail_body.is_empty() {
                    let mail = &mut mail;
                    let mail_body = &mut mail_body;
                    let failure = &failure;
                    s.spawn(move || {
                        let ended = thread.serve(mail, mail_body);
                        thread.ended(ended, failure);
                    });
                }
                let ended = thread.serve(&mut shared, &mut shared_body);
                thread.ended(ended, &failure);
            });
            if let Some(error) = lock(&failure).take() {
                return Err(error);
            }
            let Some((follow, (key, binary))) = follow
                .as_ref()
                .and_then(|f| lock(&f.placed).take().map(|p| (f, p)))
            else {
                break;
            };
            // Both threads stand between duties, every line synced: the
            // process becomes the placed program here, or says why not.
            let cause = program::replace(&binary);
            let _ = writeln!(
                std::io::stderr(),
                "watch-replace-failed binary={} cause={cause}",
                binary.display()
            );
            follow.stale(&store, key.clone(), "exec-failed")?;
            *lock(&follow.failed) = Some(key);
            stop.store(false, Ordering::SeqCst);
        }
        let store = store.into_inner().unwrap_or_else(|p| p.into_inner());
        Ok(Ended {
            events: store.log.last(),
            stopped: "requested",
        })
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|p| p.into_inner())
}

/// The runner's program followed against its install's sources, read on
/// the shared thread at the start of each long pass.
struct Follow<'p> {
    program: &'p Program,
    cadences: Cadences,
    /// The checkout key and cause the last `watch-stale` line named, so
    /// each is said once.
    said: Mutex<Option<(String, &'static str)>>,
    /// The cause the last unread key was said with on stderr.
    unread: Mutex<Option<String>>,
    /// The checkout's key and its placed program, found by the shared
    /// thread, for the runner to replace itself with once both threads end.
    placed: Mutex<Option<(String, PathBuf)>>,
    /// The checkout key whose placed program failed to exec: not tried
    /// again, since its due duties would never run, until the key moves.
    failed: Mutex<Option<String>>,
}

impl Follow<'_> {
    /// Whether `due` opens a long pass, where the comparison is made.
    fn opens_pass(&self, due: &[Duty]) -> bool {
        due.iter()
            .any(|duty| self.cadences.of(*duty) == self.cadences.long)
    }

    /// Compare the program with its sources now: `true` where a placed
    /// program is to replace it. An unread key is said on stderr when its
    /// cause changes and replaces nothing, the run going on as it was.
    fn compare(&self, store: &Mutex<Store>) -> Result<bool> {
        match self.program.current() {
            Current::Same => {
                *lock(&self.said) = None;
                *lock(&self.unread) = None;
                *lock(&self.failed) = None;
                Ok(false)
            }
            Current::Placed { key, .. } if lock(&self.failed).as_deref() == Some(key.as_str()) => {
                Ok(false)
            }
            Current::Placed { key, binary } => {
                *lock(&self.placed) = Some((key, binary));
                Ok(true)
            }
            Current::Unready { key, cause } => self.stale(store, key, cause).map(|()| false),
            Current::Unread { cause } => {
                let mut unread = lock(&self.unread);
                if unread.as_deref() != Some(cause.as_str()) {
                    let _ = writeln!(std::io::stderr(), "watch-program-unread {cause}");
                    *unread = Some(cause);
                }
                Ok(false)
            }
        }
    }

    /// The `watch-stale` line for the checkout key `key`, once per key and
    /// cause.
    fn stale(&self, store: &Mutex<Store>, key: String, cause: &'static str) -> Result<()> {
        let mut said = lock(&self.said);
        if said.as_ref().is_some_and(|(k, c)| *k == key && *c == cause) {
            return Ok(());
        }
        let line = Event::WatchStale {
            program: self.program.key().to_owned(),
            checkout: key.clone(),
            cause: cause.to_owned(),
        };
        commit(
            store,
            Produced {
                events: vec![line],
                ..Produced::default()
            },
            None,
        )?;
        *said = Some((key, cause));
        Ok(())
    }
}

/// One thread's view of the run: the shared records, the stop flag, the
/// clock and the claim it reads the stop request against.
#[derive(Clone, Copy)]
struct Thread<'r, 'a> {
    store: &'r Mutex<Store>,
    stop: &'r AtomicBool,
    clock: &'a dyn Clock,
    paths: &'r Paths,
    identity: &'r Identity,
    /// Every how many failures in a row the failure line repeats.
    mark_repeat: u32,
    /// The program followed, where the runner follows one.
    follow: Option<&'r Follow<'r>>,
}

impl Thread<'_, '_> {
    /// Record how this thread's loop ended and stop the other.
    fn ended(&self, ended: Result<()>, failure: &Mutex<Option<Error>>) {
        if let Err(e) = ended {
            let mut slot = failure.lock().unwrap_or_else(|p| p.into_inner());
            if slot.is_none() {
                *slot = Some(e);
            }
        }
        self.stop.store(true, Ordering::SeqCst);
    }

    /// Run this thread's duties as they come due until a stop: the claim
    /// and the request file are read between duties, the flag between
    /// slices. A body's failure is a line and a cadence; the records'
    /// failure ends the loop.
    #[allow(
        clippy::disallowed_methods,
        reason = "the scheduler's own reads of the one injected clock: what is due, and the wait until the next due time or the next read of the stop request"
    )]
    fn serve(&self, schedule: &mut Schedule, bodies: &mut [(Duty, Body)]) -> Result<()> {
        let mut failures: BTreeMap<Duty, u64> = BTreeMap::new();
        loop {
            if self.stop.load(Ordering::SeqCst) {
                return Ok(());
            }
            if !claim::names_runner(self.paths, self.identity)? {
                return Err(WatchError::ClaimMoved {
                    path: self.paths.pid.clone(),
                    pid: self.identity.pid,
                    start: self.identity.start.clone(),
                }
                .into());
            }
            if claim::stop_requested(self.paths, self.identity)? {
                return Ok(());
            }
            let now = self.clock.now();
            let due = schedule.due_at(now);
            if let Some(follow) = self.follow
                && follow.opens_pass(&due)
                && follow.compare(self.store)?
            {
                return Ok(());
            }
            for duty in due {
                let Some((_, body)) = bodies.iter_mut().find(|(d, _)| *d == duty) else {
                    unreachable!("a schedule carries only registered duties")
                };
                let started = self.clock.now();
                let started_wall = epoch(self.clock);
                let snapshot = self
                    .store
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .baseline
                    .clone();
                let tick = Tick {
                    duty,
                    now: started,
                    wall: started_wall,
                    baseline: &snapshot,
                    clock: self.clock,
                };
                // A body that fails whole hands back nothing but its cause
                // and earns no pass stamp; one that fails in part hands back
                // its lines and rows with the cause, and its pass is stamped.
                let (mut produced, stamped) = match body(&tick) {
                    Ok(produced) => (produced, true),
                    Err(cause) => (
                        Produced {
                            failed: Some(cause.to_string()),
                            ..Produced::default()
                        },
                        false,
                    ),
                };
                match produced.failed.take() {
                    None if produced.unjudged => {}
                    None => {
                        failures.remove(&duty);
                    }
                    Some(cause) => {
                        let count = failures.entry(duty).or_insert(0);
                        *count += 1;
                        // The cause is said once, here, for the launcher's
                        // record of this run's stderr; the line carries the
                        // step and the count alone and repeats on the
                        // `mark_repeat` rule, after the lines the run earned.
                        let _ = writeln!(
                            std::io::stderr(),
                            "watch-step-failed step={} count={count}\n{cause}",
                            duty.word()
                        );
                        if *count == 1 || count.is_multiple_of(u64::from(self.mark_repeat)) {
                            produced.events.push(Event::WatchStepFailed {
                                step: duty,
                                count: *count,
                            });
                        }
                    }
                }
                let ended = self.clock.now();
                let ended_wall = epoch(self.clock);
                let (anchor, at) = match schedule.anchor(duty) {
                    Anchor::Start => (started, started_wall),
                    Anchor::End => (ended, ended_wall),
                };
                let next_due = produced.next_due;
                let stamp = stamped.then_some(Change::Pass { duty, at });
                commit(self.store, produced, stamp)?;
                schedule.advance(duty, anchor);
                if let Some(at) = next_due {
                    schedule.wake(duty, at);
                }
            }
            let now = self.clock.now();
            let wait = match schedule.next_due() {
                Some((_, next)) => next.saturating_duration_since(now).min(SLICE),
                None => SLICE,
            };
            // A duty due again at once (a mail interval of 0, a body
            // asking for now) waits one slice first: the loop never spins.
            let wait = if wait.is_zero() { SLICE } else { wait };
            self.clock.sleep(wait);
        }
    }
}

/// The one write order: the event lines appended and synced
/// to the log, then the baseline written with the changes they settle and
/// the duty's pass stamp where the run earned one. A failed baseline write
/// leaves the lines on disk and the rows where they were, which the next
/// run reprints from.
fn commit(store: &Mutex<Store>, produced: Produced, stamp: Option<Change>) -> Result<()> {
    let mut store = store.lock().unwrap_or_else(|p| p.into_inner());
    store.log.append(&produced.events)?;
    for change in produced.changes {
        store.baseline.apply(change);
    }
    if let Some(stamp) = stamp {
        store.baseline.apply(stamp);
    }
    let Store {
        baseline, paths, ..
    } = &*store;
    baseline.store(&paths.baseline)
}

/// What `watch status` reports: the claim and whether its identity runs,
/// the due times the records imply, the event log's path and the last
/// event line's number. The overseer's turn-end hook (`lane-mail-check.sh`,
/// `watch_live` and `wake_check`) reads `claim.standing`, `claim.cwd`,
/// `claim.origin` and `log` off it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub claim: Option<ClaimStatus>,
    /// The epoch second each stamped duty is next due at, from its row and
    /// the recorded cadences; a duty with no row yet is absent.
    pub due: BTreeMap<Duty, u64>,
    pub events: u64,
    /// The event log beside the fleet state, the file a reader follows.
    pub log: std::path::PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClaimStatus {
    pub pid: u32,
    /// `None` on a record that carries no start.
    pub start: Option<String>,
    pub pane: String,
    /// `hand` or `succession`, as the claim records it.
    pub origin: String,
    /// The directory the watch runs from, as the claim records it.
    pub cwd: String,
    /// `live`, `gone` or `unreadable`.
    pub standing: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
}

pub fn status(paths: &Paths) -> Result<Status> {
    let claim = match claim::read(paths)? {
        None => None,
        Some(claim) => {
            let (standing, cause) = match claim::read_live(&claim) {
                Reading::Live(_) => ("live", None),
                Reading::Gone => ("gone", None),
                Reading::Unreadable { cause } => ("unreadable", Some(cause.to_owned())),
            };
            Some(ClaimStatus {
                pid: claim.pid,
                start: claim.start,
                pane: claim.pane,
                origin: claim.origin,
                cwd: claim.cwd,
                standing,
                cause,
            })
        }
    };
    let baseline = Baseline::load(&paths.baseline)?;
    let due = match &baseline.cadences {
        Some(c) => baseline
            .passes
            .iter()
            .map(|(duty, at)| {
                let every = match duty {
                    Duty::Mail | Duty::Wake => c.mail_secs,
                    Duty::GitHub | Duty::Retention => c.interval_secs,
                    Duty::Heartbeat => c.interval_secs * u64::from(c.max_loops),
                    Duty::NativeObservation
                    | Duty::Tracker
                    | Duty::Verification
                    | Duty::Report
                    | Duty::Reconcile => c.interval_secs,
                };
                (*duty, at + every)
            })
            .collect(),
        None => BTreeMap::new(),
    };
    Ok(Status {
        claim,
        due,
        events: events::line_count(&paths.log)?,
        log: paths.log.clone(),
    })
}
