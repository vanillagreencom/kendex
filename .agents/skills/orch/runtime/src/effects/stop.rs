//! The stop effect: end a lane's recorded harness exactly, the detached
//! wake turn it names and its window, by the identity recorded or the one
//! read in its pane's foreground, on the ground the close intent recorded. A
//! live harness is asked for its unanswered asks first, a `no-landing`
//! disposition stops only the attempt's own identity and only idle, unless
//! it interrupts a turn (a model switch), where the ask guard alone stands,
//! and keeps the worktree and its validation runs for the session that takes
//! the item over; on every other ground the worktree's validation runs are
//! ended before the window closes, and the worktree itself is released after
//! it, or kept with its reason on the lane record. Every
//! handle the lane records is an obligation of the close intent's set, read
//! and discharged through the operation handle, which acts only on a standing
//! token. The lane's launch record is read once, at the open's bootstrap; the
//! harness and the pane are the set's, by role, from then on. A lane whose
//! stamp or launch keys are not the intent's is a moved lane the close acts
//! on only through its own recorded set. Also the close cells of the
//! reconcile matrix.

use std::path::Path;

use agent_runtime::controller::Overseer;
use agent_runtime::harness::Harness;
use serde_json::{Value, json};

use super::close::{StopRead, read_stop};
use super::grants;
use super::lane_operation::{LaneOperation, Unread, WorktreeRelease};
use super::{Run, Target, fleet, lane_for_intent, launch_intent_of, pane_harness, read_intent};
use crate::error::Result;
use crate::state::{CloseGround, Lane, LaneMembers, TerminalVerdict};
use crate::watch::hosted::{self, Asked, HostClosed};
use crate::watch::lanes::{self, LaneState};
use crate::watch::mail::ClosingMail;
use agent_runtime::effects::{
    EffectOutcome, Foreground, Identity, Observed, ProcessRead, ProcessReading, Reading, State,
    Stop, Word,
};
use agent_runtime::intent::Intent;

fn remove_local_gh_token(lane: &Lane) -> Result<()> {
    if lane.host.is_none()
        && let Some(root) = lane.mail_root.as_deref()
    {
        grants::remove_token(
            &grants::folder(Path::new(root), &lane.item).join(grants::GH_TOKEN_FILE),
        )?;
    }
    Ok(())
}

/// `stale` is what the reconcile of the same request already read stale,
/// counted no second time here.
pub(super) fn stop_effect(run: &Run, intent_id: &str, stale: &[Identity]) -> Result<EffectOutcome> {
    let (lane, item) = lane_for_intent(run.engine.path, intent_id)?;
    let intent = read_intent(run.engine.path, intent_id)?;
    let members = LaneMembers::of(run.engine.path, &intent)?;
    let overseer = fleet(run.engine.path)?.overseer;
    let harness = pane_harness(
        run.engine.path,
        &lane,
        launch_intent_of(run.engine.path, &item)?.as_ref(),
    )?;
    // The lane's recorded handles as the durable set, read from the intent
    // where it stands, else bootstrapped from the lane's launch record and
    // written before the first signal. This is the one read of the launch
    // record; from here identity and pane come from the set.
    let mut operation = LaneOperation::open_close(run, &intent, &lane)?;
    operation.engine().already_read_stale(stale);
    let close = Close {
        item: &item,
        lane: &lane,
        target: harness
            .map(|h| Target::new(&run.settings.engine.harness_binaries, h))
            .transpose()?,
        ground: members.close.as_ref(),
        cycle: members.cycle.as_ref().map(|row| &row.cycle),
        overseer: overseer.as_ref(),
        prior: intent.observation.as_ref(),
    };
    // A lane whose stamp or launch keys are not the intent's is a moved lane
    // (the one judgement the store applies too): before any signal the close
    // refuses with no effect; after one it retries on the recorded set alone
    // and never acts on the new session.
    if operation.lane_moved(&lane) {
        return moved_lane(run, operation, close.overseer, close.observed(json!({})));
    }
    // The worktree's validation runs and the worktree itself are owed from
    // the close's start, acquired before the first signal, except under a
    // `no-landing` disposition: it retires the attempt for the session that
    // takes the item over, which keeps the worktree and its runs with their
    // stage bindings and end notices.
    if !close.no_landing() {
        operation.owe_validation()?;
        operation.owe_worktree(&lane)?;
    }
    // The harness is the set's, by role, never the lane's launch record.
    let Some(identity) = operation.engine_ref().harness_identity() else {
        // A viewer's window runs no harness, whatever its foreground shows
        // while a person watches: nothing in it is read or stopped, and the
        // finish closes the window. Where the close keeps the sandbox, the
        // harness it runs is the provider's to stop, after the guard its
        // provider's reading of the lane answers; a close with no stated
        // ground goes on only where that reading is the harness gone.
        if lane.viewer() {
            let provider = provider_stops(close.ground, &lane);
            let stop = if provider { "provider" } else { "window-only" };
            let mut observation = json!({"identity": "none", "stop": stop});
            if provider && let Err((cause, fields)) = close.guard_hosted(run, &operation) {
                return Ok(close.refuse_or_hold(operation, cause, fields));
            }
            if provider_reads_gone(close.ground, &lane)
                && let Err((cause, fields)) = close.hosted_gone(run)
            {
                return Ok(close.refuse_or_hold(operation, cause, fields));
            }
            if close.wake_held(&mut operation, &mut observation)? {
                return Ok(close.hold(operation, observation));
            }
            return close.finish(operation, observation);
        }
        // No recorded process identity: an earlier launcher's record may name a pid with
        // no start, read by that pid and discharged gone where nothing holds
        // it; then the pane the record names is the one handle left, and what
        // it holds is stopped by the identity read there.
        if let Some(pid) = operation.engine_ref().harness_pid() {
            let _ = operation.engine().read_pid(pid)?;
        }
        return close.by_pane(operation, None, json!({"identity": "none"}));
    };
    // What the recorded harness reads as before anything is signalled.
    match operation.engine().read_process(&identity)? {
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
    let Some(token) = operation.engine_ref().standing_process(&identity) else {
        return close.by_pane(operation, None, json!({"identity": "none"}));
    };
    // Copilot writes its session totals on `/exit`; give it that before the
    // signal. Best effort: the stop below handles a pane that did not exit.
    if close.harness() == Some(Harness::Copilot)
        && let Some(Observed::Present(pane)) =
            operation.engine().observe_target_pane(close.overseer)?
    {
        operation.engine().copilot_exit(&pane)?;
    }
    let stop = operation
        .engine()
        .stop_process(token, &|name| close.owns(name))?;
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
    /// The merge cycle this close records on the lane when it confirms.
    cycle: Option<&'a Value>,
    /// The controller record, whose tmux socket the lane's pane is looked
    /// for on before the ambient one, as the close's own read looks.
    overseer: Option<&'a Overseer>,
    /// What an earlier run of this intent recorded ([`RECEIPTS`]): a repeat
    /// whose own run reads them gone keeps them.
    prior: Option<&'a Value>,
}

impl Close<'_> {
    fn owns(&self, name: &str) -> bool {
        self.target.as_ref().is_some_and(|t| t.owns(name))
    }

    fn harness(&self) -> Option<Harness> {
        self.target.as_ref().map(Target::harness)
    }

    fn no_landing(&self) -> bool {
        matches!(self.ground, Some(CloseGround::NoLanding { .. }))
    }

    /// Whether the provider's close takes `--merged`, which lets it cut the
    /// item's archive: only for an item its tracker ended completed, where
    /// the record's cycle carries the merge or `worktree merged` shows the
    /// branch merged. A merge that read cannot judge is noted
    /// `merged-unjudged`, and the close keeps the whole archive.
    fn merged(&self, operation: &LaneOperation, observation: &mut Value) -> bool {
        if !matches!(
            self.ground,
            Some(CloseGround::Terminal {
                verdict: TerminalVerdict::Completed,
                ..
            })
        ) {
            return false;
        }
        if record_merged(self.lane) || self.cycle.is_some_and(cycle_merged) {
            return true;
        }
        match operation.worktree_merged(self.item) {
            Ok(merged) => merged,
            Err(cause) => {
                observation["merged"] = json!(format!("merged-unjudged {cause}"));
                false
            }
        }
    }

    /// Whether the disposition stops the harness mid-turn, asking no idle
    /// proof of it.
    fn interrupts(&self) -> bool {
        matches!(
            self.ground,
            Some(CloseGround::NoLanding {
                interrupt: true,
                ..
            })
        )
    }

    /// Every outcome's observation: the item, and the [`RECEIPTS`] an
    /// earlier run of the intent recorded that this run did not.
    fn observed(&self, observation: Value) -> Value {
        let mut observation = observation;
        observation["item"] = json!(self.item);
        keep_receipts(&mut observation, self.prior);
        observation
    }

    /// Nothing is settled: the intent stays open with what stands.
    fn hold(&self, operation: LaneOperation, observation: Value) -> EffectOutcome {
        let observation = with_pane(&operation, self.observed(observation));
        operation.hold(observation)
    }

    /// The close is complete once every obligation is discharged, else
    /// `unconfirmed` with what stands.
    fn judged(&self, operation: LaneOperation, observation: Value) -> EffectOutcome {
        let observation = with_pane(&operation, self.observed(observation));
        operation.settle(Word::Confirmed, observation)
    }

    /// A refusal where the set says nothing was signalled, else the same
    /// cause held `unconfirmed` with everything standing.
    fn refuse_or_hold(
        &self,
        operation: LaneOperation,
        cause: &str,
        fields: Value,
    ) -> EffectOutcome {
        let observation = with_pane(&operation, self.observed(fields));
        operation.refuse(cause, observation)
    }

    /// What must hold before a live harness is signalled: the asks it holds
    /// unanswered, and a `no-landing` disposition needs the harness idle in
    /// its pane under its recorded identity. The inner `Err` is the refusal's
    /// cause and fields; `Ok(())` lets the stop proceed.
    fn guard_live(
        &self,
        operation: &mut LaneOperation,
        identity: &Identity,
    ) -> Result<std::result::Result<(), (&'static str, Value)>> {
        if self.no_landing() && !self.interrupts() {
            let Some(target) = &self.target else {
                return Ok(Err(("harness-unknown", json!({}))));
            };
            let pane = match operation.engine().observe_target_pane(self.overseer)? {
                Some(Observed::Present(pane)) => pane,
                Some(Observed::Gone { cause } | Observed::Unobservable { cause }) => {
                    return Ok(Err(("idle-unproved", json!({"pane": cause}))));
                }
                None => {
                    return Ok(Err(("idle-unproved", json!({"pane": "unrecorded"}))));
                }
            };
            match operation.engine().read_pane(
                pane.key(),
                target.harness(),
                &|name| target.owns(name),
                Some(identity),
            )? {
                Reading::Live((
                    Foreground {
                        reading: ProcessReading::Harness { .. },
                        ..
                    },
                    // A walled harness takes no turn either: the wall route
                    // retires it on this ground before its replacement.
                    State::Idle | State::Walled { .. },
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
        Ok(self.no_ask(operation))
    }

    /// What must hold before a viewer's hosted harness is stopped through
    /// its provider, read as the close before its transition reads the lane:
    /// a harness read exited or gone needs nothing; a live one is asked for
    /// its unanswered asks, and a disposition that does not interrupt needs
    /// it idle by its provider's screen. The `Err` is the refusal's cause and
    /// fields.
    fn guard_hosted(
        &self,
        run: &Run,
        operation: &LaneOperation,
    ) -> std::result::Result<(), (&'static str, Value)> {
        let state = self.hosted_state(run);
        match &state {
            LaneState::Exited | LaneState::Gone => return Ok(()),
            // A walled harness takes no turn either, as `guard_live` reads it.
            LaneState::Idle { .. } | LaneState::Walled { .. } => {}
            LaneState::Working
            | LaneState::Asking
            | LaneState::RateLimitSwitch
            | LaneState::Unreadable { .. }
            | LaneState::Unjudged { .. }
                if self.interrupts() => {}
            // The state's own word, as `lane status` prints it.
            LaneState::Working | LaneState::Asking | LaneState::RateLimitSwitch => {
                return Err((
                    "not-idle",
                    serde_json::to_value(&state).unwrap_or(Value::Null),
                ));
            }
            LaneState::Unreadable { cause } | LaneState::Unjudged { cause } => {
                return Err(("idle-unproved", json!({"pane": cause})));
            }
        }
        self.no_ask(operation)
    }

    /// A hosted viewer's harness read gone before a close with no stated
    /// ground goes on, as the op reads a recorded identity gone for any
    /// other lane: the provider's status exited, or a host that holds no
    /// lane of the item. A live harness refuses `lane-live` with its state,
    /// a status read that failed `harness-unreadable` with its cause.
    fn hosted_gone(&self, run: &Run) -> std::result::Result<(), (&'static str, Value)> {
        let state = self.hosted_state(run);
        match &state {
            LaneState::Exited | LaneState::Gone => Ok(()),
            LaneState::Unjudged { cause } if hosted::status_unowned(cause, self.item) => Ok(()),
            LaneState::Unreadable { cause } => Err(("harness-unreadable", json!({"cause": cause}))),
            LaneState::Unjudged { cause } if cause.starts_with("harness-probe-failed") => {
                Err(("harness-unreadable", json!({"cause": cause})))
            }
            // The provider read it running: its screen's state, judged or not.
            LaneState::Unjudged { .. }
            | LaneState::Idle { .. }
            | LaneState::Walled { .. }
            | LaneState::Working
            | LaneState::Asking
            | LaneState::RateLimitSwitch => Err((
                "lane-live",
                serde_json::to_value(&state).unwrap_or(Value::Null),
            )),
        }
    }

    /// The lane as the close before its transition reads it: its provider
    /// first, then the screen.
    fn hosted_state(&self, run: &Run) -> LaneState {
        let socket = self
            .overseer
            .and_then(agent_runtime::effects::overseer_socket);
        lanes::judge(run.settings, self.lane, socket.as_deref(), None)
    }

    /// The live harness's mailbox holds no unanswered ask; the `Err` is the
    /// refusal's cause and fields.
    fn no_ask(&self, operation: &LaneOperation) -> std::result::Result<(), (&'static str, Value)> {
        match operation.unanswered_ask(self.lane) {
            Ok(None) => Ok(()),
            Ok(Some(ask)) => Err(("ask-unanswered", json!({"ask": ask}))),
            Err(cause) => Err(("ask-check-failed", json!({"detail": cause}))),
        }
    }

    /// Stop the lane's detached wake turn and every other process the set
    /// still holds, and note a handle that outlived its grace or could not be
    /// read: `true`, with `wake: live` and the cause, and the repeat stops it
    /// again.
    fn wake_held(&self, operation: &mut LaneOperation, observation: &mut Value) -> Result<bool> {
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

    /// The provider's stop of a lane [`provider_stops`] names, asked after a
    /// window lane's exit, then its status read exited within the close
    /// bound, as the close before its transition asks it of every other
    /// hosted lane:
    /// `true` once stopped or skipped, written under `host_stop`; `false`
    /// with the refusal's key under `host_stop` and its fields beside it,
    /// `exit-timeout` or `pane-read-failed` among them, which the repeat
    /// asks again (the provider's stop of a group already ended signals
    /// nothing).
    fn host_stopped(&self, operation: &mut LaneOperation, observation: &mut Value) -> Result<bool> {
        let harness = self.lane.harness.as_deref().unwrap_or_default();
        let answer = operation.host_stop(self.lane, harness)?;
        let processes = match read_stop(answer, self.no_landing()) {
            StopRead::Stopped(processes) => processes,
            StopRead::Skipped(cause) => {
                observation["host_stop"] = json!(format!(
                    "stop-skipped item={} harness={harness} cause={cause}",
                    self.item
                ));
                return Ok(true);
            }
            StopRead::Refused(key, fields) => {
                observation["host_stop"] = json!(key);
                for (name, value) in fields {
                    observation[name] = json!(value);
                }
                return Ok(false);
            }
        };
        match operation.host_exited(self.lane, harness)? {
            Ok(true) => {
                observation["host_stop"] = json!(format!("stopped processes={processes}"));
                Ok(true)
            }
            Ok(false) => {
                observation["host_stop"] = json!("exit-timeout");
                observation["processes"] = json!(processes);
                observation["cause"] = json!("exit-timeout");
                Ok(false)
            }
            Err(cause) => {
                observation["host_stop"] = json!("pane-read-failed");
                observation["cause"] = json!(cause);
                Ok(false)
            }
        }
    }

    /// The lane's last mail, read before the provider's close takes its
    /// box. A box a park stopped answers no read and holds nothing the park
    /// did not read ([`Lane::mail_parked`]), so none is read.
    fn last_mail(
        &self,
        operation: &LaneOperation,
    ) -> std::result::Result<Option<ClosingMail>, Unread> {
        if self.lane.mail_parked() {
            return Ok(None);
        }
        operation.last_mail(self.lane)
    }

    /// The close of what remains once every process the close names has
    /// ended: the worktree's validation runs are stopped, whose answer
    /// discharges that obligation, unless a `no-landing` disposition keeps
    /// them, then the set's standing window is closed, then the worktree is
    /// released or kept with its reason, then the obligations are judged. A
    /// validation stop or a handle that did not settle leaves the lane, with
    /// the cause, for a repeated close.
    fn finish(
        &self,
        mut operation: LaneOperation,
        mut observation: Value,
    ) -> Result<EffectOutcome> {
        if !self.no_landing()
            && let Err(cause) = operation.stop_validations(self.lane)?
        {
            observation["validate"] = json!("stop-failed");
            observation["cause"] = json!(cause);
            return Ok(self.hold(operation, observation));
        }
        // The close-out and worktree release can carry the mailbox into
        // the main checkout. The lane's credential must leave first.
        remove_local_gh_token(self.lane)?;
        // The item's files leave before the provider's close, so a close
        // that stops past this point repeats whole, the removal included.
        let ends_item = self.ground.is_some_and(CloseGround::ends_item);
        let delivered = self
            .cycle
            .and_then(|cycle| cycle["commit"].as_str())
            .filter(|sha| {
                !self.no_landing() && sha.len() == 40 && sha.bytes().all(|b| b.is_ascii_hexdigit())
            });
        if ends_item || delivered.is_some() {
            match operation.close_out_files(self.lane, ends_item, delivered)? {
                Ok(archive) if ends_item => {
                    observation["item_files"] = json!("removed");
                    if let Some(archive) = archive {
                        observation["archive"] = json!(archive.display().to_string());
                    }
                }
                Ok(_) => {}
                Err(cause) => {
                    observation["item_files"] = json!("failed");
                    observation["cause"] = json!(cause);
                    return Ok(self.hold(operation, observation));
                }
            }
        }
        if provider_stops(self.ground, self.lane)
            && !self.host_stopped(&mut operation, &mut observation)?
        {
            return Ok(self.hold(operation, observation));
        }
        if provider_closes(self.ground, self.lane) {
            match self.last_mail(&operation) {
                Ok(None) => {}
                Ok(Some(mail)) => observation["mail"] = json!(mail),
                Err(unread) => {
                    observation["mail"] = json!("unread");
                    observation["cause"] = json!(unread.to_string());
                    return Ok(self.hold(operation, observation));
                }
            }
            let merged = self.merged(&operation, &mut observation);
            match operation.host_close(self.lane, merged)? {
                // The provider's exit 0 is its word that the sandbox ends,
                // `closed=absent` its word that none stood. A provider may
                // answer before its teardown shows in its `list`, so no
                // list read after the close judges it.
                Ok(HostClosed::Closed { line }) => observation["host_close"] = json!(line),
                Ok(HostClosed::Refused { path }) => {
                    observation["host_close"] = json!("refused");
                    observation["path"] = json!(path);
                    return Ok(self.hold(operation, observation));
                }
                Err(Asked::Failed(cause)) => {
                    observation["host_close"] = json!("failed");
                    observation["cause"] = json!(cause);
                    return Ok(self.hold(operation, observation));
                }
                Err(Asked::Unknown(cause)) => {
                    observation["host_close"] = json!("unanswered");
                    observation["cause"] = json!(cause);
                    return Ok(self.hold(operation, observation));
                }
            }
        }
        let window = operation.engine().close_target_window(self.overseer)?;
        observation["window"] = json!(window.word());
        // The run's diagnostic of the release; the set's discharge word and
        // the lane's `kept` and `kept_mail` are the reading.
        match operation.release_worktree(self.lane)? {
            None => {}
            Some(WorktreeRelease::Gone) => observation["worktree"] = json!("gone"),
            Some(WorktreeRelease::Released { .. }) => observation["worktree"] = json!("released"),
            Some(WorktreeRelease::Kept { .. }) => observation["worktree"] = json!("kept"),
            Some(WorktreeRelease::Held { cause }) => {
                observation["worktree"] = json!("unreadable");
                observation["cause"] = json!(cause);
            }
        }
        // After a recorded landing the base checkout follows it; a refusal
        // is noted and holds nothing.
        if self.cycle.is_some() {
            observation["base"] = json!(operation.follow_base());
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
        mut operation: LaneOperation,
        stale: Option<&Identity>,
        mut observation: Value,
    ) -> Result<EffectOutcome> {
        let count = |operation: &mut LaneOperation, observation: &mut Value| -> Result<()> {
            if let Some(id) = stale {
                operation.engine().count_stale(id, observation)?;
            }
            Ok(())
        };
        let pane = match operation.engine().observe_target_pane(self.overseer)? {
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
        let pane_pid = match operation.engine().pane_pid(pane.key())? {
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
        let foreground =
            operation
                .engine()
                .foreground_of(pane_pid, &|name| self.owns(name), None)?;
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
                    operation.engine().copilot_exit(&pane)?;
                }
                observation["stop"] = json!("pane-foreground");
                let Some(token) = operation.engine_ref().standing_process(&identity) else {
                    return Ok(self.hold(operation, observation));
                };
                let stop = operation
                    .engine()
                    .stop_process(token, &|name| self.owns(name))?;
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

/// Whether a close on `ground` owes a close-out only its finish discharges:
/// the item's files on the tracker's terminal verdict, the provider's close
/// of a hosted sandbox on any ground but `no-landing`, the provider's stop
/// [`provider_stops`] names. None leaves a handle the reconcile
/// can read, and each is safe to ask again (the archive of no files writes
/// nothing, a provider that no longer holds the item answers
/// `closed=absent`, a stop of a group already ended signals nothing), so
/// the reconcile of such a close never confirms it and its repeat runs the
/// close again.
fn owes_close_out(ground: Option<&CloseGround>, lane: &Lane) -> bool {
    ground.is_some_and(CloseGround::ends_item)
        || provider_closes(ground, lane)
        || provider_stops(ground, lane)
}

/// Whether the close's effect asks the provider's stop: a lane that exits
/// in its window ([`Lane::exits_in_window`]), on any ground but a
/// host-absent close, which has no host to ask; and a hosted viewer's lane
/// on the `no-landing` ground, whose kept sandbox the provider's close
/// never ends and whose window runs no harness.
fn provider_stops(ground: Option<&CloseGround>, lane: &Lane) -> bool {
    let kept_viewer = lane.viewer()
        && lane.provider_hosted()
        && matches!(ground, Some(CloseGround::NoLanding { .. }));
    (lane.exits_in_window() || kept_viewer) && !ground.is_some_and(CloseGround::host_absent)
}

/// Whether the close's effect needs a hosted viewer's harness read gone
/// before it acts: a close with no stated ground, which the op admits on a
/// viewer's lane with no identity to read, while the provider's close it
/// asks would end a live harness and its sandbox.
fn provider_reads_gone(ground: Option<&CloseGround>, lane: &Lane) -> bool {
    lane.viewer() && lane.provider_hosted() && matches!(ground, Some(CloseGround::Exited))
}

/// Whether the provider's close ends the lane's sandbox on `ground`: a
/// hosted lane's close on any ground but `no-landing`, which keeps it, and
/// a host-absent close, which has none to close.
fn provider_closes(ground: Option<&CloseGround>, lane: &Lane) -> bool {
    lane.provider_hosted()
        && !matches!(ground, Some(CloseGround::NoLanding { .. }))
        && !ground.is_some_and(CloseGround::host_absent)
}

/// Whether the record's cycle carries a delivery.
pub(super) fn record_merged(lane: &Lane) -> bool {
    lane.extra.get("cycle").is_some_and(cycle_merged)
}

/// Whether a cycle object carries a delivery: a merged pull request, or a
/// direct push whose merged stamp was read.
fn cycle_merged(cycle: &Value) -> bool {
    cycle.get("pr").is_some_and(Value::is_number)
        || (cycle
            .get("commit")
            .and_then(Value::as_str)
            .is_some_and(|c| !c.is_empty())
            && cycle
                .pointer("/stamps/merged")
                .and_then(Value::as_str)
                .is_some_and(|m| !m.is_empty()))
}

/// `observation` with the pane the set records under the harness role.
fn with_pane(operation: &LaneOperation, mut observation: Value) -> Value {
    observation["pane"] = json!(operation.engine_ref().harness_pane_id());
    observation
}

/// A moved lane: before any signal the close refuses
/// `lane-moved` with no effect; after one it retries on the recorded set
/// alone, every standing process stopped by its own token and the set's own
/// pane closed by its full key, the worktree and its validation runs released
/// to the session that now holds the lane, then settles by
/// that set. The processes a stop may signal below a recorded root are
/// named by the harness kind the set recorded at its bootstrap, never by
/// the harness the relaunched session runs. Nothing
/// the lane names now is read or acted on. A handle still standing holds
/// the intent with `stop: pending`, so the repeat retries again.
fn moved_lane(
    run: &Run,
    mut operation: LaneOperation,
    overseer: Option<&Overseer>,
    mut observation: Value,
) -> Result<EffectOutcome> {
    observation["lane"] = json!("moved");
    if !operation.engine_ref().signalled() {
        return Ok(operation.refuse("lane-moved", observation));
    }
    let target = operation
        .engine_ref()
        .recorded_harness()
        .map(|h| Target::new(&run.settings.engine.harness_binaries, h))
        .transpose()?;
    let owns = |name: &str| target.as_ref().is_some_and(|t| t.owns(name));
    operation.engine().read_standing(overseer)?;
    operation.release_validation_moved()?;
    operation.release_worktree_moved()?;
    if let Some(cause) = operation.engine().stop_standing_processes(&owns, None)? {
        observation["cause"] = json!(cause);
    }
    operation.engine().close_standing_panes(overseer)?;
    let mut outcome = operation.settle(Word::Confirmed, observation);
    if !outcome.ended() {
        outcome.annotate("stop", json!("pending"));
    }
    Ok(outcome)
}

/// What a close's run records that its repeat cannot read again: the
/// local archive of the item's files, which leave in the first run.
const RECEIPTS: [&str; 1] = ["archive"];

/// A reconciled close's observation: the reconcile's word and the item,
/// with the [`RECEIPTS`] the intent's earlier run recorded (`prior`), which
/// the repeated close it hands over to reads.
fn reconcile_observation(item: &str, observation: Value, prior: Option<&Value>) -> Value {
    let mut observation = observation;
    observation["reconcile"] = json!("close");
    observation["item"] = json!(item);
    keep_receipts(&mut observation, prior);
    observation
}

/// The [`RECEIPTS`] `prior` recorded, on an observation that records none of
/// its own.
fn keep_receipts(observation: &mut Value, prior: Option<&Value>) {
    for key in RECEIPTS {
        if let Some(kept) = prior.and_then(|p| p.get(key))
            && observation.get(key).is_none()
        {
            observation[key] = kept.clone();
        }
    }
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
/// processes by token and closing its own panes.
pub(super) fn reconcile_close(run: &Run, intent: &Intent) -> Result<EffectOutcome> {
    let (lane, item) = lane_for_intent(run.engine.path, &intent.id)?;
    let overseer = fleet(run.engine.path)?.overseer;
    let overseer = overseer.as_ref();
    let mut operation = LaneOperation::open_close(run, intent, &lane)?;
    // Every standing handle is read by its own key first: a wake the lane's
    // writer replaced, or a replacement foreground whose pane is gone, is read
    // here whatever the lane record names now.
    operation.engine().read_standing(overseer)?;
    if operation.lane_moved(&lane) {
        return moved_lane(
            run,
            operation,
            overseer,
            reconcile_observation(&item, json!({}), intent.observation.as_ref()),
        );
    }
    let hold = |operation: LaneOperation, observation: Value| {
        operation.hold(reconcile_observation(
            &item,
            observation,
            intent.observation.as_ref(),
        ))
    };
    // The set's recorded pane as it stands, written on the observation; a
    // pane gone or none stands is what the close judges beside the recorded
    // process's end, a pane present or unobservable settles nothing here.
    let pane = |operation: &mut LaneOperation, observation: &mut Value| -> Result<bool> {
        let (word, cause, judged) = match operation.engine().observe_target_pane(overseer)? {
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
    // identity reader and discharged where gone; a close-out the ground owes
    // holds last.
    let settled = |mut operation: LaneOperation, mut observation: Value| -> Result<EffectOutcome> {
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
        if owes_close_out(
            LaneMembers::of(run.engine.path, intent)?.close.as_ref(),
            &lane,
        ) {
            observation["close_out"] = json!("owed");
            return Ok(hold(operation, observation));
        }
        remove_local_gh_token(&lane)?;
        let mut outcome = operation.settle(
            Word::Confirmed,
            reconcile_observation(&item, observation, intent.observation.as_ref()),
        );
        // A recorded handle still standing after every read is the repeated
        // close's to stop: `stop: pending`, built from the set, never from
        // the lane record.
        if !outcome.ended() {
            outcome.annotate("stop", json!("pending"));
        }
        Ok(outcome)
    };
    // The harness is the set's, by role, never the lane's launch record.
    match operation.engine_ref().harness_identity() {
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
        Some(id) => match operation.engine().read_process(&id)? {
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
                    operation.engine().count_stale(&id, &mut observation)?;
                    settled(operation, observation)
                } else {
                    Ok(hold(operation, observation))
                }
            }
        },
    }
}
