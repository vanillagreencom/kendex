//! The standing scheduler: every duty has its own cadence and its own due
//! time. Running one duty, or an event that makes it due now, moves no other
//! duty's deadline; in particular mail activity never resets the heartbeat.
//!
//! The logic reads no clock of its own. A caller passes the instant it is
//! acting at, or a [`Clock`] it owns, so a test drives the schedule with a
//! fake and asserts ordering without waiting.

use std::time::{Duration, Instant};

/// The duties the legacy fleet watch runs on one clock: the mail turn, the
/// pane and process observations, tracker work, verification, the report
/// check and the heartbeat that ends a quiet run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Duty {
    Mail,
    NativeObservation,
    Tracker,
    Verification,
    Report,
    Heartbeat,
}

impl Duty {
    /// Every duty, in the order a tie between equal due times is broken.
    pub const ALL: [Duty; 6] = [
        Duty::Mail,
        Duty::NativeObservation,
        Duty::Tracker,
        Duty::Verification,
        Duty::Report,
        Duty::Heartbeat,
    ];
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
    pub native_observation: Cadence,
    pub tracker: Cadence,
    pub verification: Cadence,
    pub report: Cadence,
    pub heartbeat: Cadence,
}

impl Cadences {
    /// The legacy watch's settings: `ORCH_WATCH_MAIL_INTERVAL=20` end to
    /// start; every long-pass check at `--interval 240` start to start; the
    /// heartbeat after `--max-loops 25` quiet passes, 25 × 240 s.
    pub fn legacy() -> Cadences {
        let long = Cadence {
            every: Duration::from_secs(240),
            anchor: Anchor::Start,
        };
        Cadences {
            mail: Cadence {
                every: Duration::from_secs(20),
                anchor: Anchor::End,
            },
            native_observation: long,
            tracker: long,
            verification: long,
            report: long,
            heartbeat: Cadence {
                every: Duration::from_secs(25 * 240),
                anchor: Anchor::Start,
            },
        }
    }

    pub fn of(&self, duty: Duty) -> Cadence {
        match duty {
            Duty::Mail => self.mail,
            Duty::NativeObservation => self.native_observation,
            Duty::Tracker => self.tracker,
            Duty::Verification => self.verification,
            Duty::Report => self.report,
            Duty::Heartbeat => self.heartbeat,
        }
    }
}

/// The clock a running scheduler reads. Production reads the monotonic
/// clock; a test supplies the instants it wants.
pub trait Clock {
    fn now(&self) -> Instant;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Entry {
    duty: Duty,
    cadence: Cadence,
    due: Instant,
}

/// The due time of every duty.
#[derive(Debug, Clone)]
pub struct Schedule {
    entries: [Entry; 6],
}

impl Schedule {
    /// Every duty is due at `start`.
    pub fn new(cadences: &Cadences, start: Instant) -> Schedule {
        Schedule {
            entries: Duty::ALL.map(|duty| Entry {
                duty,
                cadence: cadences.of(duty),
                due: start,
            }),
        }
    }

    fn entry(&self, duty: Duty) -> &Entry {
        &self.entries[Duty::ALL
            .iter()
            .position(|d| *d == duty)
            .expect("every duty has an entry")]
    }

    fn entry_mut(&mut self, duty: Duty) -> &mut Entry {
        &mut self.entries[Duty::ALL
            .iter()
            .position(|d| *d == duty)
            .expect("every duty has an entry")]
    }

    pub fn due(&self, duty: Duty) -> Instant {
        self.entry(duty).due
    }

    /// The duty due soonest and when; a tie goes to the earlier of
    /// [`Duty::ALL`].
    pub fn next_due(&self) -> (Duty, Instant) {
        let first = self
            .entries
            .iter()
            .min_by_key(|e| e.due)
            .expect("six entries");
        (first.duty, first.due)
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

    /// An event asks for the duty at `at`: its due time moves earlier to
    /// `at`, never later, and no other duty moves.
    pub fn wake(&mut self, duty: Duty, at: Instant) {
        let entry = self.entry_mut(duty);
        if at < entry.due {
            entry.due = at;
        }
    }

    /// Run every duty due on the clock, advancing each from its anchor, and
    /// return what ran.
    pub fn run_due<C: Clock>(&mut self, clock: &C, mut run: impl FnMut(Duty)) -> Vec<Duty> {
        let now = clock.now();
        let due = self.due_at(now);
        for duty in &due {
            let started = clock.now();
            run(*duty);
            let anchor = match self.entry(*duty).cadence.anchor {
                Anchor::Start => started,
                Anchor::End => clock.now(),
            };
            self.advance(*duty, anchor);
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    /// A clock the test moves by hand.
    struct FakeClock {
        now: Cell<Instant>,
    }

    impl FakeClock {
        fn at(start: Instant) -> FakeClock {
            FakeClock {
                now: Cell::new(start),
            }
        }

        fn pass(&self, d: Duration) {
            self.now.set(self.now.get() + d);
        }
    }

    impl Clock for FakeClock {
        fn now(&self) -> Instant {
            self.now.get()
        }
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
            let mut s = Schedule::new(&Cadences::legacy(), start);
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
        let mut s = Schedule::new(&Cadences::legacy(), start);
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
        let mut s = Schedule::new(&Cadences::legacy(), start);
        s.advance(Duty::Tracker, start);
        s.wake(Duty::Tracker, start + secs(300));
        assert_eq!(s.due(Duty::Tracker), start + secs(240));
        s.wake(Duty::Tracker, start + secs(30));
        assert_eq!(s.due(Duty::Tracker), start + secs(30));
    }

    #[test]
    fn a_slow_duty_does_not_block_another_duty_becoming_due() {
        let start = Instant::now();
        let mut s = Schedule::new(&Cadences::legacy(), start);
        // The tracker pass started at `start` and took 1000 s; mail was due
        // at start + 20 the whole time and is the next duty, not the tracker.
        s.advance(Duty::Tracker, start);
        s.advance(Duty::Mail, start);
        for duty in [
            Duty::NativeObservation,
            Duty::Verification,
            Duty::Report,
            Duty::Heartbeat,
        ] {
            s.advance(duty, start);
        }
        let after_slow_pass = start + secs(1000);
        assert_eq!(s.next_due(), (Duty::Mail, start + secs(20)));
        let due = s.due_at(after_slow_pass);
        assert_eq!(
            due,
            vec![
                Duty::Mail,
                Duty::NativeObservation,
                Duty::Tracker,
                Duty::Verification,
                Duty::Report
            ]
        );
        assert_eq!(s.due(Duty::Heartbeat), start + secs(6000));
    }

    #[test]
    fn ties_break_in_duty_order_and_run_due_anchors_each_duty_from_its_own_rule() {
        let start = Instant::now();
        let clock = FakeClock::at(start);
        let mut s = Schedule::new(&Cadences::legacy(), start);
        assert_eq!(s.next_due(), (Duty::Mail, start));
        let mut ran = Vec::new();
        let due = s.run_due(&clock, |duty| {
            ran.push(duty);
            // Each duty takes 3 s on the fake clock.
            clock.pass(secs(3));
        });
        assert_eq!(due, Duty::ALL.to_vec());
        assert_eq!(ran, Duty::ALL.to_vec());
        // Mail is end-anchored: it started at +0 and ended at +3.
        assert_eq!(s.due(Duty::Mail), start + secs(3) + secs(20));
        // The long-pass duties are start-anchored: observation started at +3.
        assert_eq!(s.due(Duty::NativeObservation), start + secs(3) + secs(240));
        assert_eq!(s.due(Duty::Tracker), start + secs(6) + secs(240));
        assert_eq!(s.due(Duty::Heartbeat), start + secs(15) + secs(6000));
        // Nothing is due again until mail's end-anchored deadline.
        assert!(s.run_due(&clock, |_| {}).is_empty());
        clock.pass(secs(5));
        assert_eq!(s.run_due(&clock, |_| {}), vec![Duty::Mail]);
    }
}
