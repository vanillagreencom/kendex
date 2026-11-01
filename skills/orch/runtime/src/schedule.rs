//! The standing scheduler's due times and the one clock: every duty has its
//! own cadence and its own due time. Running one duty, or an event that
//! makes it due now, moves no other duty's deadline; in particular mail
//! activity never resets the heartbeat (decision 121, Q5).
//!
//! The logic reads no clock of its own. The runner (`watch`) passes the
//! instant it is acting at, so a test drives a schedule with instants it
//! chooses and asserts ordering without waiting. [`Clock`] is the one clock
//! every wait and every wall-clock moment of the runtime reads (decision
//! 121, Q16): `main.rs` builds it and hands it to the operation handle and
//! the runner alike, so a test supplies one fake and drives both.

use std::time::{Duration, Instant, SystemTime};

use serde::{Deserialize, Serialize};

/// The duties the fleet watch runs on one clock: the mail turn, the pane and
/// process observations, tracker work, verification, the report check, the
/// reconcile of every open intent (decision 121, Q4) and the heartbeat. The
/// serialized word is [`Duty::word`], the key of a duty's baseline row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Duty {
    Mail,
    NativeObservation,
    Tracker,
    Verification,
    Report,
    Reconcile,
    Heartbeat,
}

impl Duty {
    /// Every duty, in the order a tie between equal due times is broken.
    pub const ALL: [Duty; 7] = [
        Duty::Mail,
        Duty::NativeObservation,
        Duty::Tracker,
        Duty::Verification,
        Duty::Report,
        Duty::Reconcile,
        Duty::Heartbeat,
    ];

    /// The duty's word in a reply or a diagnostic.
    pub fn word(self) -> &'static str {
        match self {
            Duty::Mail => "mail",
            Duty::NativeObservation => "native-observation",
            Duty::Tracker => "tracker",
            Duty::Verification => "verification",
            Duty::Report => "report",
            Duty::Reconcile => "reconcile",
            Duty::Heartbeat => "heartbeat",
        }
    }
}

/// Where a cadence counts from once the duty ran.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    /// The next due time is the run's start plus the cadence (the legacy
    /// long pass: `LONG_DUE = started + INTERVAL`).
    Start,
    /// The next due time is the run's end plus the cadence (the legacy mail
    /// turn: `MAIL_DUE = now + MAIL_INTERVAL` after the turn).
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cadence {
    pub every: Duration,
    pub anchor: Anchor,
}

/// One cadence per duty.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cadences {
    pub mail: Cadence,
    pub long: Cadence,
    pub heartbeat: Cadence,
}

impl Cadences {
    /// The cadences the watch settings name (step5-map F1): the mail interval
    /// end to start; every long-pass duty at `interval` start to start; the
    /// heartbeat every `max_loops × interval` from the last heartbeat.
    pub fn of_settings(mail: Duration, interval: Duration, max_loops: u32) -> Cadences {
        Cadences {
            mail: Cadence {
                every: mail,
                anchor: Anchor::End,
            },
            long: Cadence {
                every: interval,
                anchor: Anchor::Start,
            },
            heartbeat: Cadence {
                every: interval.saturating_mul(max_loops),
                anchor: Anchor::Start,
            },
        }
    }

    /// The legacy watch's defaults: `ORCH_WATCH_MAIL_INTERVAL=20`,
    /// `--interval 240`, `--max-loops 25`.
    pub fn legacy() -> Cadences {
        Cadences::of_settings(Duration::from_secs(20), Duration::from_secs(240), 25)
    }

    pub fn of(&self, duty: Duty) -> Cadence {
        match duty {
            Duty::Mail => self.mail,
            Duty::NativeObservation
            | Duty::Tracker
            | Duty::Verification
            | Duty::Report
            | Duty::Reconcile => self.long,
            Duty::Heartbeat => self.heartbeat,
        }
    }
}

/// The one clock the scheduler and every effect wait read (decision 121,
/// Q16): `main.rs` builds it and hands it down, so a test supplies the
/// instants it wants and a bound can be waited without real time passing.
/// The effects reach it only through the operation handle (decision 124c).
/// `Sync`, since the runner's two duty threads share one.
pub trait Clock: Sync {
    fn now(&self) -> Instant;
    /// The wall-clock time, for a moment a record carries (the instant a
    /// window was asked for, which a session file's appearance is read
    /// against; the epoch second a baseline row holds).
    fn wall(&self) -> SystemTime;
    /// Wait `d` on this clock. The system clock sleeps; a fake clock passes
    /// the time it wants.
    fn sleep(&self, d: Duration);
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

/// The system clock's own reads and its sleep, each behind the one injected
/// clock: the allowance sits on each method alone, so a method added to the
/// trait and this impl needs its own registered site (decision 124i (35)).
impl Clock for SystemClock {
    #[allow(
        clippy::disallowed_methods,
        reason = "the system clock's monotonic read, behind the one injected clock"
    )]
    fn now(&self) -> Instant {
        Instant::now()
    }
    #[allow(
        clippy::disallowed_methods,
        reason = "the system clock's wall read, behind the one injected clock"
    )]
    fn wall(&self) -> SystemTime {
        SystemTime::now()
    }
    #[allow(
        clippy::disallowed_methods,
        reason = "the system clock's sleep, behind the one injected clock"
    )]
    fn sleep(&self, d: Duration) {
        std::thread::sleep(d);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Entry {
    duty: Duty,
    cadence: Cadence,
    due: Instant,
}

/// The due time of a set of duties: the duties one thread of the runner
/// owns (decision 121, Q16: mail on its own thread, the rest on one).
#[derive(Debug, Clone)]
pub struct Schedule {
    entries: Vec<Entry>,
}

impl Schedule {
    /// Every duty of `duties` is due at `start`, in [`Duty::ALL`] order.
    pub fn new(cadences: &Cadences, start: Instant, duties: &[Duty]) -> Schedule {
        Schedule {
            entries: Duty::ALL
                .iter()
                .filter(|d| duties.contains(d))
                .map(|duty| Entry {
                    duty: *duty,
                    cadence: cadences.of(*duty),
                    due: start,
                })
                .collect(),
        }
    }

    pub fn duties(&self) -> Vec<Duty> {
        self.entries.iter().map(|e| e.duty).collect()
    }

    fn entry(&self, duty: Duty) -> &Entry {
        self.entries
            .iter()
            .find(|e| e.duty == duty)
            .expect("the schedule carries the duty")
    }

    fn entry_mut(&mut self, duty: Duty) -> &mut Entry {
        self.entries
            .iter_mut()
            .find(|e| e.duty == duty)
            .expect("the schedule carries the duty")
    }

    pub fn due(&self, duty: Duty) -> Instant {
        self.entry(duty).due
    }

    /// Where `duty` counts its next run from once it ran: its anchor.
    pub fn anchor(&self, duty: Duty) -> Anchor {
        self.entry(duty).cadence.anchor
    }

    /// Set `duty`'s due time outright: the runner's first due time from a
    /// persisted row (the heartbeat from the last heartbeat, the mail turn
    /// from the last turn's end).
    pub fn set_due(&mut self, duty: Duty, at: Instant) {
        self.entry_mut(duty).due = at;
    }

    /// The duty due soonest and when; a tie goes to the earlier of
    /// [`Duty::ALL`]. `None` on an empty schedule.
    pub fn next_due(&self) -> Option<(Duty, Instant)> {
        self.entries
            .iter()
            .min_by_key(|e| e.due)
            .map(|e| (e.duty, e.due))
    }

    /// The duties due at `now`, in [`Duty::ALL`] order.
    pub fn due_at(&self, now: Instant) -> Vec<Duty> {
        self.entries
            .iter()
            .filter(|e| e.due <= now)
            .map(|e| e.duty)
            .collect()
    }

    /// The duty ran; its next due time counts from `ran_at`, the instant its
    /// anchor names. No other duty moves.
    pub fn advance(&mut self, duty: Duty, ran_at: Instant) {
        let entry = self.entry_mut(duty);
        entry.due = ran_at + entry.cadence.every;
    }

    /// The duty asks for its next run at `at` (`Produced::next_due`): its
    /// due time moves earlier to `at`, never later, and no other duty moves.
    pub fn wake(&mut self, duty: Duty, at: Instant) {
        let entry = self.entry_mut(duty);
        if at < entry.due {
            entry.due = at;
        }
    }
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows start the schedule at a real instant and move it by hand"
)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    #[test]
    fn the_legacy_cadences_hold_the_watch_settings() {
        let c = Cadences::legacy();
        let rows = [
            (Duty::Mail, 20, Anchor::End),
            (Duty::NativeObservation, 240, Anchor::Start),
            (Duty::Tracker, 240, Anchor::Start),
            (Duty::Verification, 240, Anchor::Start),
            (Duty::Report, 240, Anchor::Start),
            (Duty::Reconcile, 240, Anchor::Start),
            (Duty::Heartbeat, 6000, Anchor::Start),
        ];
        for (duty, every, anchor) in rows {
            assert_eq!(
                c.of(duty),
                Cadence {
                    every: secs(every),
                    anchor
                },
                "{duty:?}"
            );
        }
    }

    #[test]
    fn running_one_duty_moves_no_other_deadline() {
        let start = Instant::now();
        for ran in Duty::ALL {
            let mut s = Schedule::new(&Cadences::legacy(), start, &Duty::ALL);
            let before: Vec<Instant> = Duty::ALL.iter().map(|d| s.due(*d)).collect();
            s.advance(ran, start + secs(1));
            for (duty, was) in Duty::ALL.iter().zip(before) {
                if *duty == ran {
                    assert_eq!(
                        s.due(*duty),
                        start + secs(1) + Cadences::legacy().of(ran).every
                    );
                } else {
                    assert_eq!(s.due(*duty), was, "{ran:?} moved {duty:?}");
                }
            }
        }
    }

    #[test]
    fn mail_events_do_not_reset_the_heartbeat_deadline() {
        let start = Instant::now();
        let mut s = Schedule::new(&Cadences::legacy(), start, &Duty::ALL);
        let heartbeat = start + secs(6000);
        s.advance(Duty::Heartbeat, start);
        assert_eq!(s.due(Duty::Heartbeat), heartbeat);
        let mut t = start;
        for _ in 0..50 {
            t += secs(7);
            s.wake(Duty::Mail, t);
            assert_eq!(s.due(Duty::Mail), t.min(s.due(Duty::Mail)));
            s.advance(Duty::Mail, t + secs(2));
            assert_eq!(s.due(Duty::Heartbeat), heartbeat);
            assert_eq!(s.due(Duty::Tracker), start);
        }
    }

    #[test]
    fn a_wake_moves_a_duty_earlier_never_later() {
        let start = Instant::now();
        let mut s = Schedule::new(&Cadences::legacy(), start, &Duty::ALL);
        s.advance(Duty::Tracker, start);
        s.wake(Duty::Tracker, start + secs(300));
        assert_eq!(s.due(Duty::Tracker), start + secs(240));
        s.wake(Duty::Tracker, start + secs(30));
        assert_eq!(s.due(Duty::Tracker), start + secs(30));
    }

    /// A schedule carries only the duties its thread owns, in `ALL` order,
    /// and a tie between equal due times breaks in that order.
    #[test]
    fn a_schedule_carries_its_own_duties_in_order_and_ties_break_in_it() {
        let start = Instant::now();
        let s = Schedule::new(
            &Cadences::legacy(),
            start,
            &[Duty::Heartbeat, Duty::Tracker, Duty::Mail],
        );
        assert_eq!(s.duties(), vec![Duty::Mail, Duty::Tracker, Duty::Heartbeat]);
        assert_eq!(s.next_due(), Some((Duty::Mail, start)));
        assert_eq!(
            s.due_at(start),
            vec![Duty::Mail, Duty::Tracker, Duty::Heartbeat]
        );
        assert!(s.due_at(start - secs(1)).is_empty());
        let empty = Schedule::new(&Cadences::legacy(), start, &[]);
        assert_eq!(empty.next_due(), None);
    }
}
