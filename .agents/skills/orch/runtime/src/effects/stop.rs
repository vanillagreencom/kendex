//! The stop effect: end a lane's recorded harness exactly, the detached
//! wake turn it names and its window, by the identity recorded or the one
//! read in its pane's foreground, on the ground the close intent recorded. A
//! live harness is asked for its unanswered asks first, a `no-landing`
//! disposition stops only the attempt's own identity and only idle, the
//! worktree's validation runs are ended before the window closes, and the
//! worktree itself is released after it, or kept with its reason on the lane
//! record (decision 128 (9)). Every
//! handle the lane records is an obligation of the close intent's set, read
//! and discharged through the operation handle, which acts only on a standing
//! token. The lane's launch record is read once, at the open's bootstrap; the
//! harness and the pane are the set's, by role, from then on. A lane whose
//! stamp or launch keys are not the intent's is a moved lane the close acts
//! on only through its own recorded set. Also the close cells of the
//! reconcile matrix.

use agent_runtime::harness::Harness;
use serde_json::{Value, json};

use super::operation::{
    EffectOutcome, Foreground, Identity, Observed, Operation, ProcessRead, ProcessReading, Reading,
    State, Stop, Word, WorktreeRelease,
};
use super::{Run, Target, lane_for_intent, launch_intent_of, pane_harness, read_intent};
use crate::error::Result;
use crate::state::{CloseGround, Intent, Lane};

/// `stale` is what the reconcile of the same request already read stale,
/// counted no second time here (decision 124e (22)).
pub(super) fn stop_effect(run: &Run, intent_id: &str, stale: &[Identity]) -> Result<EffectOutcome> {
    let (lane, item) = lane_for_intent(run.path, intent_id)?;
    let intent = read_intent(run.path, intent_id)?;
    let harness = pane_harness(&lane, launch_intent_of(run.path, &item)?.as_ref());
    // The lane's recorded handles as the durable set, read from the intent
    // where it stands, else bootstrapped from the lane's launch record and
    // written before the first signal. This is the one read of the launch
    // record; from here identity and pane come from the set.
    let mut operation = Operation::open(run, &intent)?;
    operation.already_read_stale(stale);
    let close = Close {
        item: &item,
        lane: &lane,
        target: harness.map(|h| Target::new(run.settings, h)),
        ground: intent.close.as_ref(),
    };
    // A lane whose stamp or launch keys are not the intent's is a moved lane
    // (the one judgement the store applies too): before any signal the close
    // refuses with no effect; after one it retries on the recorded set alone
    // and never acts on the new session.
    if operation.lane_moved(&lane) {
        return moved_lane(run, operation, close.observed(json!({})));
    }
    // The worktree's validation runs are owed from the close's start,
    // acquired before the first signal; so is the worktree itself, except
    // under a `no-landing` disposition, which keeps the attempt's work
    // (decision 98).
    operation.owe_validation()?;
    if !close.no_landing() {
        operation.owe_worktree(&lane)?;
    }
    // The harness is the set's, by role, never the lane's launch record.
    let Some(identity) = operation.harness_identity() else {
        // No recorded process identity: a legacy record may name a pid with
        // no start, read by that pid and discharged gone where nothing holds
        // it; then the pane the record names is the one handle left, and what
        // it holds is stopped by the identity read there.
        if let Some(pid) = operation.harness_pid() {
            let _ = operation.read_pid(pid)?;
        }
        return close.by_pane(operation, None, json!({"identity": "none"}));
    };
    // What the recorded harness reads as before anything is signalled.
    match operation.read_process(&identity)? {
        ProcessRead::Live => {
            if let Err((cause, fields)) = close.guard_live(&mut operation, &identity)? {
                return Ok(close.refuse_or_hold(operation, cause, fields));
            }
        }
        // The recorded process ended, by this read of its own identity. The
        // pane it ran in may hold another process now: the pane route reads
        // and stops what stands there by its own identity.
        ProcessRead::Gone => {
            return close.by_pane(operation, None, json!({"identity": "gone"}));
        }
        ProcessRead::Stale { other } => {
            return close.by_pane(
                operation,
                Some(&identity),
                json!({"identity": "stale", "observed_start": other.start}),
            );
        }
        ProcessRead::Unreadable { cause } => {
            return Ok(close.hold(
                operation,
                json!({"identity": "unreadable", "pid": identity.pid, "cause": cause}),
            ));
        }
    }
    // The recorded identity read live: it must stand in the set to be
    // stopped. One the set no longer names is a moved lane, taken by the pane
    // route.
    let Some(token) = operation.standing_process(&identity) else {
        return close.by_pane(operation, None, json!({"identity": "none"}));
    };
    // Copilot writes its session totals on `/exit`; give it that before the
    // signal. Best effort: the stop below handles a pane that did not exit.
    if close.harness() == Some(Harness::Copilot)
        && let Some(Observed::Present(pane)) = operation.observe_lane_pane()?
    {
        operation.copilot_exit(&pane)?;
    }
    let stop = operation.stop_process(token, &|name| close.owns(name))?;
    match stop.answer() {
        Stop::Stopped { .. } | Stop::AlreadyGone => {
            let mut observation = json!({"identity": "stopped"});
            if close.wake_held(&mut operation, &mut observation)? {
                return Ok(close.hold(operation, observation));
            }
            close.finish(operation, observation)
        }
        // The pid now holds another process: never a name-based kill. The
        // signal already sent is recorded, so a stale pid takes the pane
        // route holding, not refusing.
        Stop::IdentityStale => {
            close.by_pane(operation, Some(&identity), json!({"identity": "stale"}))
        }
        Stop::Timeout { pid } => {
            Ok(close.hold(operation, json!({"identity": "live", "timeout_pid": pid})))
        }
        Stop::Unreadable { pid, cause, .. } => Ok(close.hold(
            operation,
            json!({"identity": "unreadable", "pid": pid, "cause": cause}),
        )),
    }
}

/// One close in progress: the lane, its recorded harness and the ground the
/// close stands on.
struct Close<'a> {
    item: &'a str,
    lane: &'a Lane,
    target: Option<Target>,
    ground: Option<&'a CloseGround>,
}

impl Close<'_> {
    fn owns(&self, name: &str) -> bool {
        self.target.as_ref().is_some_and(|t| t.owns(name))
    }

    fn harness(&self) -> Option<Harness> {
        self.target.as_ref().map(|t| t.harness)
    }

    fn no_landing(&self) -> bool {
        matches!(self.ground, Some(CloseGround::NoLanding { .. }))
    }

    fn observed(&self, observation: Value) -> Value {
        let mut observation = observation;
        observation["item"] = json!(self.item);
        observation
    }

    /// Nothing is settled: the intent stays open with what stands.
    fn hold(&self, operation: Operation, observation: Value) -> EffectOutcome {
        let observation = with_pane(&operation, self.observed(observation));
        operation.hold(observation)
    }

    /// The close is complete once every obligation is discharged, else
    /// `unconfirmed` with what stands.
    fn judged(&self, operation: Operation, observation: Value) -> EffectOutcome {
        let observation = with_pane(&operation, self.observed(observation));
        operation.settle(Word::Confirmed, observation)
    }

    /// A refusal where the set says nothing was signalled, else the same
    /// cause held `unconfirmed` with everything standing.
    fn refuse_or_hold(&self, operation: Operation, cause: &str, fields: Value) -> EffectOutcome {
        let observation = with_pane(&operation, self.observed(fields));
        operation.refuse(cause, observation)
    }

    /// What must hold before a live harness is signalled: the asks it holds
    /// unanswered, and a `no-landing` disposition needs the harness idle in
    /// its pane under its recorded identity. The inner `Err` is the refusal's
    /// cause and fields; `Ok(())` lets the stop proceed.
    fn guard_live(
        &self,
        operation: &mut Operation,
        identity: &Identity,
    ) -> Result<std::result::Result<(), (&'static str, Value)>> {
        if self.no_landing() {
            let Some(target) = &self.target else {
                return Ok(Err(("harness-unknown", json!({}))));
            };
            let pane = match operation.observe_lane_pane()? {
                Some(Observed::Present(pane)) => pane,
                Some(Observed::Gone { cause } | Observed::Unobservable { cause }) => {
                    return Ok(Err(("idle-unproved", json!({"pane": cause}))));
                }
                None => {
                    return Ok(Err(("idle-unproved", json!({"pane": "unrecorded"}))));
                }
            };
            match operation.read_pane(
                pane.key(),
                target.harness,
                &|name| target.owns(name),
                Some(identity),
            )? {
                Reading::Live((
                    Foreground {
                        reading: ProcessReading::Harness { .. },
                        ..
                    },
                    State::Idle,
                )) => {}
                Reading::Live((foreground, state)) => {
                    return Ok(Err((
                        "not-idle",
                        json!({
                            "process": serde_json::to_value(&foreground.reading).unwrap_or(Value::Null),
                            "state": serde_json::to_value(&state).unwrap_or(Value::Null),
                        }),
                    )));
                }
                Reading::Gone => {
                    return Ok(Err(("idle-unproved", json!({"pane": "pane-gone"}))));
                }
                Reading::Unreadable { cause } => {
                    return Ok(Err(("idle-unproved", json!({"pane": cause}))));
                }
            }
        }
        Ok(match operation.unanswered_ask(self.lane) {
            Ok(None) => Ok(()),
            Ok(Some(ask)) => Err(("ask-unanswered", json!({"ask": ask}))),
            Err(cause) => Err(("ask-check-failed", json!({"detail": cause}))),
        })
    }

    /// Stop the lane's detached wake turn and every other process the set
    /// still holds, and note a handle that outlived its grace or could not be
    /// read: `true`, with `wake: live` and the cause, and the repeat stops it
    /// again.
    fn wake_held(&self, operation: &mut Operation, observation: &mut Value) -> Result<bool> {
        Ok(
            match operation.stop_wake(self.lane, &|name| self.owns(name))? {
                None => false,
                Some(cause) => {
                    observation["wake"] = json!("live");
                    observation["cause"] = json!(cause);
                    true
                }
            },
        )
    }

    /// The close of what remains once every process the close names has
    /// ended: the worktree's validation runs are stopped, whose answer
    /// discharges that obligation, then the set's standing window is closed,
    /// then the worktree is released or kept with its reason, then the
    /// obligations are judged. A validation stop or a handle that did not
    /// settle leaves the lane, with the cause, for a repeated close.
    fn finish(&self, mut operation: Operation, mut observation: Value) -> Result<EffectOutcome> {
        if let Err(cause) = operation.stop_validations(self.lane)? {
            observation["validate"] = json!("stop-failed");
            observation["cause"] = json!(cause);
            return Ok(self.hold(operation, observation));
        }
        let window = operation.close_lane_window()?;
        observation["window"] = json!(window.word());
        // The run's diagnostic of the release; the set's discharge word and
        // the lane's `kept` and `kept_mail` are the reading.
        match operation.release_worktree()? {
            None => {}
            Some(WorktreeRelease::Gone) => observation["worktree"] = json!("gone"),
            Some(WorktreeRelease::Released { .. }) => observation["worktree"] = json!("released"),
            Some(WorktreeRelease::Kept { .. }) => observation["worktree"] = json!("kept"),
            Some(WorktreeRelease::Held { cause }) => {
                observation["worktree"] = json!("unreadable");
                observation["cause"] = json!(cause);
            }
        }
        Ok(self.judged(operation, observation))
    }

    /// The pane route: the set's standing pane present is stopped by the
    /// harness identity read in its foreground now, by that identity's own
    /// stop, or closed alone when no harness holds it. `stale` is the recorded
    /// identity this run read stale, counted one reading towards the stale
    /// count where the pane is read, never on a pane the host did not answer
    /// for. A `no-landing` disposition stops only the attempt's recorded
    /// identity. A route entered after a signal holds instead of refusing.
    fn by_pane(
        &self,
        mut operation: Operation,
        stale: Option<&Identity>,
        mut observation: Value,
    ) -> Result<EffectOutcome> {
        let count = |operation: &mut Operation, observation: &mut Value| -> Result<()> {
            if let Some(id) = stale {
                operation.count_stale(id, observation)?;
            }
            Ok(())
        };
        let pane = match operation.observe_lane_pane()? {
            // No addressable pane stands: the wake and validation runs are
            // what remains to end.
            None => {
                observation["observed"] = json!("unrecorded");
                count(&mut operation, &mut observation)?;
                if self.wake_held(&mut operation, &mut observation)? {
                    return Ok(self.hold(operation, observation));
                }
                return self.finish(operation, observation);
            }
            Some(Observed::Gone { cause }) => {
                observation["observed"] = json!("gone");
                observation["cause"] = json!(cause);
                count(&mut operation, &mut observation)?;
                if self.wake_held(&mut operation, &mut observation)? {
                    return Ok(self.hold(operation, observation));
                }
                return self.finish(operation, observation);
            }
            // A recorded pane the host did not answer for is a handle still
            // held: nothing confirms on it, and no reading is counted.
            Some(Observed::Unobservable { cause }) => {
                observation["observed"] = json!("unobservable");
                observation["cause"] = json!(cause);
                return Ok(self.hold(operation, observation));
            }
            Some(Observed::Present(pane)) => pane,
        };
        let pane_pid = match operation.pane_pid(pane.key())? {
            Reading::Live(pid) => pid,
            // The pane went between the two reads.
            Reading::Gone => {
                observation["observed"] = json!("gone");
                count(&mut operation, &mut observation)?;
                if self.wake_held(&mut operation, &mut observation)? {
                    return Ok(self.hold(operation, observation));
                }
                return self.finish(operation, observation);
            }
            Reading::Unreadable { cause } => {
                observation["observed"] = json!("unobservable");
                observation["cause"] = json!(cause);
                return Ok(self.hold(operation, observation));
            }
        };
        count(&mut operation, &mut observation)?;
        // The identity read in the pane is an obligation from here, written
        // before anything is done with it.
        let foreground = operation.foreground_of(pane_pid, &|name| self.owns(name), None)?;
        observation["process"] = serde_json::to_value(&foreground.reading).unwrap_or(Value::Null);
        match foreground.reading {
            ProcessReading::Harness { identity } => {
                if self.no_landing() {
                    return Ok(self.refuse_or_hold(operation, "identity-unrecorded", observation));
                }
                match operation.unanswered_ask(self.lane) {
                    Ok(None) => {}
                    Ok(Some(ask)) => {
                        observation["ask"] = json!(ask);
                        return Ok(self.refuse_or_hold(operation, "ask-unanswered", observation));
                    }
                    Err(cause) => {
                        observation["detail"] = json!(cause);
                        return Ok(self.refuse_or_hold(operation, "ask-check-failed", observation));
                    }
                }
                if self.harness() == Some(Harness::Copilot) {
                    operation.copilot_exit(&pane)?;
                }
                observation["stop"] = json!("pane-foreground");
                let Some(token) = operation.standing_process(&identity) else {
                    return Ok(self.hold(operation, observation));
                };
                let stop = operation.stop_process(token, &|name| self.owns(name))?;
                let ended = matches!(stop.answer(), Stop::Stopped { .. } | Stop::AlreadyGone);
                match stop.answer() {
                    Stop::Stopped { .. } | Stop::AlreadyGone => {}
                    Stop::IdentityStale => observation["result"] = json!("identity-stale"),
                    Stop::Timeout { pid } => observation["timeout_pid"] = json!(pid),
                    Stop::Unreadable { pid, cause, .. } => {
                        observation["result"] = json!("identity-unreadable");
                        observation["unread_pid"] = json!(pid);
                        observation["cause"] = json!(cause);
                    }
                }
                if !ended {
                    return Ok(self.hold(operation, observation));
                }
                if self.wake_held(&mut operation, &mut observation)? {
                    return Ok(self.hold(operation, observation));
                }
                self.finish(operation, observation)
            }
            // No harness holds the pane: the window is closed alone.
            ProcessReading::ShellsOnly
            | ProcessReading::HarnessUp
            | ProcessReading::ForegroundShell { .. }
            | ProcessReading::ForegroundOther { .. } => {
                if self.wake_held(&mut operation, &mut observation)? {
                    return Ok(self.hold(operation, observation));
                }
                observation["stop"] = json!("window-only");
                self.finish(operation, observation)
            }
            // Who holds the pane could not be read: nothing is stopped and
            // nothing closed on a reading that is not one.
            ProcessReading::Unread { cause } => {
                observation["stop"] = json!("none");
                observation["cause"] = json!(cause);
                Ok(self.hold(operation, observation))
            }
        }
    }
}

/// `observation` with the pane the set records under the harness role, as
/// the close has always written it.
fn with_pane(operation: &Operation, mut observation: Value) -> Value {
    observation["pane"] = json!(operation.harness_pane_id());
    observation
}

/// A moved lane (decision 124d (20)): before any signal the close refuses
/// `lane-moved` with no effect; after one it retries on the recorded set
/// alone, every standing process stopped by its own token and the set's own
/// pane closed by its full key, the worktree and its validation runs released
/// to the session that now holds the lane (decision 124e (24)), then settles by
/// that set. The processes a stop may signal below a recorded root are
/// named by the harness kind the set recorded at its bootstrap, never by
/// the harness the relaunched session runs (decision 124g (29)). Nothing
/// the lane names now is read or acted on. A handle still standing holds
/// the intent with `stop: pending`, so the repeat retries again.
fn moved_lane(
    run: &Run,
    mut operation: Operation,
    mut observation: Value,
) -> Result<EffectOutcome> {
    observation["lane"] = json!("moved");
    if !operation.signalled() {
        return Ok(operation.refuse("lane-moved", observation));
    }
    let target = operation
        .recorded_harness()
        .map(|h| Target::new(run.settings, h));
    let owns = |name: &str| target.as_ref().is_some_and(|t| t.owns(name));
    operation.read_standing(None)?;
    operation.release_validation_moved()?;
    operation.release_worktree_moved()?;
    if let Some(cause) = operation.stop_standing_processes(&owns, None)? {
        observation["cause"] = json!(cause);
    }
    operation.close_standing_panes(None)?;
    let mut outcome = operation.settle(Word::Confirmed, observation);
    if !outcome.ended() {
        outcome.annotate("stop", json!("pending"));
    }
    Ok(outcome)
}

/// A reconciled close's observation: the reconcile's word and the item.
fn reconcile_observation(item: &str, observation: Value) -> Value {
    let mut observation = observation;
    observation["reconcile"] = json!("close");
    observation["item"] = json!(item);
    observation
}

/// The close cells of the reconcile matrix. The durable set the close
/// recorded is read by its own keys, not rebuilt: a validation stop or a wake
/// turn it owes stands until the repeated close answers it. A recorded
/// identity live is a stop still owed, `unconfirmed` with `stop: pending`
/// built from the standing `Process`; one read gone confirms when the
/// recorded pane is gone with it or none stands; a live pid under another
/// start is an identity change, confirmed on the second independent reading
/// where no pane stands. A recorded pane present is `unconfirmed`, which a
/// repeated close closes through the pane route. A reconcile of a lane that
/// still holds its set stops and closes nothing; one of a lane moved under
/// the intent retries on the recorded set alone, stopping its standing
/// processes by token and closing its own panes (decision 124d (20)).
pub(super) fn reconcile_close(run: &Run, intent: &Intent) -> Result<EffectOutcome> {
    let (lane, item) = lane_for_intent(run.path, &intent.id)?;
    let mut operation = Operation::open(run, intent)?;
    // Every standing handle is read by its own key first: a wake the lane's
    // writer replaced, or a replacement foreground whose pane is gone, is read
    // here whatever the lane record names now.
    operation.read_standing(None)?;
    if operation.lane_moved(&lane) {
        return moved_lane(run, operation, reconcile_observation(&item, json!({})));
    }
    let hold = |operation: Operation, observation: Value| {
        operation.hold(reconcile_observation(&item, observation))
    };
    // The set's recorded pane as it stands, written on the observation; a
    // pane gone or none stands is what the close judges beside the recorded
    // process's end, a pane present or unobservable settles nothing here.
    let pane = |operation: &mut Operation, observation: &mut Value| -> Result<bool> {
        let (word, cause, judged) = match operation.observe_lane_pane()? {
            None => ("unrecorded", None, true),
            Some(Observed::Gone { cause }) => ("gone", Some(cause), true),
            Some(Observed::Present(_)) => ("present", None, false),
            Some(Observed::Unobservable { cause }) => ("unobservable", Some(cause), false),
        };
        observation["pane"] = json!(word);
        observation["observed"] = json!(word);
        observation["cause"] = json!(cause);
        Ok(judged)
    };
    // The close judged once what stands beside the process and the pane is
    // read: a validation stop owed holds; the wake is read through the one
    // identity reader and discharged where gone.
    let settled = |mut operation: Operation, mut observation: Value| -> Result<EffectOutcome> {
        if operation.owes_validation() {
            observation["validate"] = json!("stop-failed");
            observation["cause"] = json!("validation-stop-owed");
            return Ok(hold(operation, observation));
        }
        match operation.read_wake(&lane)? {
            None | Some(Reading::Gone) => {}
            Some(Reading::Live(_)) => {
                observation["wake"] = json!("live");
                return Ok(hold(operation, observation));
            }
            Some(Reading::Unreadable { cause }) => {
                observation["wake"] = json!("unreadable");
                observation["cause"] = json!(cause);
                return Ok(hold(operation, observation));
            }
        }
        let mut outcome =
            operation.settle(Word::Confirmed, reconcile_observation(&item, observation));
        // A recorded handle still standing after every read is the repeated
        // close's to stop: `stop: pending`, built from the set, never from
        // the lane record.
        if !outcome.ended() {
            outcome.annotate("stop", json!("pending"));
        }
        Ok(outcome)
    };
    // The harness is the set's, by role, never the lane's launch record.
    match operation.harness_identity() {
        None => {
            let mut observation = json!({"identity": "none"});
            // A pane present or unobservable settles nothing here. No pane
            // and a set that never acquired a handle is the one documented
            // `unconfirmed` cell, closed by hand; a set that recorded any
            // handle is judged by what the reads above found.
            let judged = pane(&mut operation, &mut observation)?;
            if judged && !(observation["pane"] == "unrecorded" && operation.recorded_nothing()) {
                settled(operation, observation)
            } else {
                Ok(hold(operation, observation))
            }
        }
        Some(id) => match operation.read_process(&id)? {
            ProcessRead::Live => Ok(hold(operation, json!({"stop": "pending"}))),
            ProcessRead::Unreadable { cause } => Ok(hold(
                operation,
                json!({"identity": "unreadable", "cause": cause}),
            )),
            // The recorded process ended: confirmed gone when the pid holds
            // nothing, a reused pid when it holds another process.
            ProcessRead::Gone => {
                let mut observation = json!({"identity": "gone"});
                if pane(&mut operation, &mut observation)? {
                    settled(operation, observation)
                } else {
                    Ok(hold(operation, observation))
                }
            }
            ProcessRead::Stale { other } => {
                let mut observation = json!({
                    "identity": "stale",
                    "observed_start": other.start,
                });
                // A present pane is the repeated close's route; a pane gone or
                // none stands is one reading towards the stale count, never a
                // confirm alone; a recorded pane the host did not answer for
                // is a handle still held.
                if pane(&mut operation, &mut observation)? {
                    operation.count_stale(&id, &mut observation)?;
                    settled(operation, observation)
                } else {
                    Ok(hold(operation, observation))
                }
            }
        },
    }
}
