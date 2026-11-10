//! The operation handle: one per intent run, the owner of the intent's
//! recorded obligation set and of every effect primitive the effect files
//! reach.
//!
//! What the types enforce. The set (`Obligations`) and every token are
//! private to this directory, so an effect file reads or changes the set
//! only through a handle method. A stop, a kill, a close and the exit
//! keystroke take a `Standing` token the set mints from a standing
//! obligation; each refuses `token-stale` where the key no longer stands in
//! the handle's set, and its first write, `signalled`, names the revision
//! the handle read the set at, which the store refuses `set-replaced` where
//! the record holds another, so nothing acts on a set another handle or
//! process replaced. The brief's delivery takes the same token, signals
//! nothing and writes its `delivering` phase before it types. `Recorded`
//! and `Stopped` carry evidence this module's own readers produced. Every
//! write a handle makes is made under the owner the intent recorded when
//! the handle opened: a write the store finds under another owner is
//! yielded to that claimant and the handle acts on nothing. A terminal
//! outcome is built only by consuming the handle: `settle`, `hold`,
//! `refuse` and `publish`; nothing else constructs one,
//! and a settlement needs every obligation discharged. `apply_outcome` is
//! the one path from an outcome to the store. The effect files' other
//! entries to the store, beside the handle's own writes, are the few this
//! module names: `persist_close` for the close over a superseded launch,
//! `adopt_controller`'s one adoption write, `run_job`'s claim, the
//! owed-notice walk's marks, and `load`, their one read.
//!
//! What the guard is for. The fleet record tells the truth
//! about what is open, owned, free and finished, so an overseer or the
//! scheduler never acts on a guess; the ledger above holds that for the
//! code that acts. The guard against a developer's accidental call past the
//! handle is the compiler's `disallowed-methods` list (`clippy.toml`): it
//! refuses an ordinary call of a primitive, a store entry, a clock read, a
//! wait or a file write outside this directory and the allowed functions.
//! Code deliberately written to defeat that list is a code-review matter,
//! never the list's. Each allowance, one function, one trait impl's method
//! or one test module, carries its reason at its attribute; the skill's
//! `DEVELOPMENT.md` § Effect boundary states the rule for adding one.
//!
//! What the methods do, each stated at its own declaration: write the
//! acquisition before the action or wait, discharge by the method's own
//! read or answer. Every wait and every wall-clock moment reads the run's
//! one clock, which `main.rs` builds and `open` takes. The validation stop
//! takes the lane's recorded worktree root and no token; its caller runs
//! after the moved-lane judgement. A handle's writes yield to a job that
//! claimed the intent, and `apply` retries the owner-conditional transition
//! on a conflicting snapshot so the claimant's state is the answer. The
//! bootstrap at `open` is the one read of a lane's launch record; the set's
//! roles select the harness and the pane from then on, and the harness kind
//! recorded under the harness role names what a stop may signal below a
//! recorded root.
//!
//! `host.rs` reads, signals and closes processes and panes; `window.rs`
//! opens a window, recovers an `opening` and polls a pane; `job.rs` asks the
//! job launcher and reads its record; `obligations.rs` is the private
//! outcome model; `receipt.rs` the pane's own registration.

mod host;
pub(in crate::effects) mod job;
mod obligations;
mod receipt;
mod window;

use agent_runtime::harness::Harness;
use agent_runtime::protocol::Outcome;
use serde_json::{Value, json};

pub(in crate::effects) use agent_runtime::host::tmux::{Close, Pane, Server};
pub(in crate::effects) use agent_runtime::observe::{ProcessReading, State};
pub(in crate::effects) use agent_runtime::process::{Identity, Stop};
pub(in crate::effects) use agent_runtime::reading::Reading;
pub(crate) use host::Recorded;
pub(in crate::effects) use host::register_controller;
pub(in crate::effects) use host::{
    Binding, Delivery, Foreground, Observed, ProcessRead, Proof, SessionFloor, WindowClose,
    WorktreeRelease, adopt_controller, default_home, fixed_file, fixed_id_file, heal_controller,
    owner,
};
pub(in crate::effects) use host::{
    apply_request, pending_ask, pick_account, poll_until, server_home, session_owner,
    stop_released_prepare,
};
pub(in crate::effects) use obligations::{EffectOutcome, Published, Wire, Word};
pub(crate) use obligations::{JobHandle, SidecarRead};
pub(in crate::effects) use window::{
    OpenRefusal, Polled, Recovered, TurnConfirm, opening_observation,
};

use obligations::{Discharge, Obligations, PaneRef, Terminal};

use super::{Run, lane_for_intent, overseer_identity, read_intent, read_overseer};
use crate::error::{Error, Result};
use crate::ops::{
    self, Applied, CLOUD_KIND, Progress, RecordOutcome, RecordProgress, Report, Request,
};
use crate::schedule::Clock;
use crate::state::{
    self, EffectOp, Intent, LaneKeys, Obligation, OpenedPane, Overseer, Owner, Phase, Role,
};

pub(in crate::effects) struct Operation<'a> {
    run: &'a Run<'a>,
    intent_id: String,
    op: EffectOp,
    /// The lane's stamp the intent was written at, carried on a lane
    /// intent's terminal with the set's lane keys.
    lane_since: Option<String>,
    phase: Option<Phase>,
    /// The set as this handle read it, carrying the store's `revision` of
    /// that read, mirrored after each of the handle's own writes: the one
    /// value named revision, which every write sends back so the store
    /// refuses `set-replaced` where another handle or process replaced the
    /// set meanwhile.
    obligations: Obligations,
    /// The harness kind the target runs under this intent, recorded on every
    /// handle acquired under the harness role: a lane
    /// close's from the lane record at the bootstrap, a lane launch's from
    /// its selection. `None` on a controller intent, whose handles are the
    /// runner's and the predecessor's.
    harness: Option<Harness>,
    /// The identities this run read stale: the only ones a
    /// stale count may discharge, since that count is this run's own second
    /// reading.
    stale: Vec<Identity>,
    /// The owner the intent recorded when this handle opened, what every
    /// write of the handle is made under: a write the store finds under
    /// another owner, a job's claim landed since, is yielded to that owner
    /// and the handle acts on nothing. `None` on an intent that records no
    /// owner, whose writes are unconditional.
    while_owner: Option<Owner>,
    /// The clock every wait of the handle reads: the run's, the one
    /// `main.rs` builds.
    clock: &'a dyn Clock,
}

impl<'a> Operation<'a> {
    /// Open the handle on `intent`: the recorded set where one stands, else the
    /// bootstrap of an intent that records no set, written at once. A launch or
    /// succession bootstraps from its phase; a lane close from the lane's
    /// launch record, its wake and the validation stop a last outcome recorded
    /// `validate: stop-failed` for (a close that runs owes it from its start,
    /// through [`Operation::owe_validation`]); a controller stop from the
    /// overseer record.
    pub(in crate::effects) fn open(run: &'a Run<'a>, intent: &Intent) -> Result<Operation<'a>> {
        let recorded = Obligations::recorded(intent)?;
        let bootstrapped = recorded.is_none();
        // The harness kind is the set's where one is recorded; the target's
        // record is read for it only at a bootstrap.
        let (obligations, harness) = match recorded {
            Some(obligations) => {
                let harness = obligations.recorded_harness();
                (obligations, harness)
            }
            None => {
                let harness = Operation::harness_of(run, intent)?;
                (Operation::bootstrap(run, intent, harness)?, harness)
            }
        };
        let mut operation = Operation {
            run,
            intent_id: intent.id.clone(),
            op: intent.op,
            lane_since: intent.lane_since.clone(),
            phase: intent.phase.clone(),
            obligations,
            harness,
            stale: Vec::new(),
            while_owner: intent.owner.clone(),
            clock: run.clock,
        };
        if bootstrapped {
            operation.write()?;
        }
        Ok(operation)
    }

    /// The harness kind the intent's target runs, read once at open: a
    /// lane close's from the lane record, a lane
    /// launch's from the intent's selection; a controller intent names none.
    fn harness_of(run: &Run, intent: &Intent) -> Result<Option<Harness>> {
        Ok(match intent.op {
            EffectOp::CloseOwnedResources => {
                let (lane, _) = lane_for_intent(run.path, &intent.id)?;
                lane.harness.as_deref().and_then(Harness::parse)
            }
            EffectOp::LaunchLane => intent
                .selection
                .as_ref()
                .and_then(|s| Harness::parse(&s.harness)),
            EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController => {
                None
            }
        })
    }

    /// The harness kind the set records under the harness role: what names
    /// the processes below a recorded root that a stop on this set may
    /// signal, never the harness the target runs now.
    pub(in crate::effects) fn recorded_harness(&self) -> Option<Harness> {
        self.obligations.recorded_harness()
    }

    /// The role a handle plays under `op` where nothing names another: the
    /// lane's harness for a lane launch or close, the runner for a succession,
    /// the predecessor for a controller stop.
    fn principal(op: EffectOp) -> Role {
        match op {
            EffectOp::LaunchLane | EffectOp::CloseOwnedResources => Role::Harness,
            EffectOp::RequestTransfer | EffectOp::StartController => Role::Runner,
            EffectOp::StopController => Role::Predecessor,
        }
    }

    /// The role a handle this operation acquires takes where nothing names
    /// another.
    pub(super) fn principal_role(&self) -> Role {
        Operation::principal(self.op)
    }

    #[cfg(test)]
    fn revision(&self) -> u64 {
        self.obligations.record().revision
    }

    /// The lane keys a lane intent's terminal carries:
    /// the stamp and the harness identity and pane recorded under the
    /// harness role. `None` on a controller intent.
    fn lane_keys(&self) -> Option<LaneKeys> {
        match self.op {
            EffectOp::LaunchLane | EffectOp::CloseOwnedResources => {
                Some(self.obligations.lane_keys(self.lane_since.clone()))
            }
            EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController => {
                None
            }
        }
    }

    /// Whether `lane` moved under this intent: the one judgement the store's
    /// lane arm applies too, on the same keys.
    pub(in crate::effects) fn lane_moved(&self, lane: &state::Lane) -> bool {
        match self.lane_keys() {
            Some(keys) => ops::lane_moved(lane, &keys),
            None => lane.session_since != self.lane_since,
        }
    }

    /// The identities an earlier handle of this same request read stale: a
    /// reading this handle makes of one counts no second time; a second
    /// reading is a later request's.
    pub(in crate::effects) fn already_read_stale(&mut self, stale: &[Identity]) {
        for id in stale {
            if !self.stale.contains(id) {
                self.stale.push(id.clone());
            }
        }
    }

    fn bootstrap(run: &Run, intent: &Intent, harness: Option<Harness>) -> Result<Obligations> {
        let principal = Operation::principal(intent.op);
        Ok(match intent.op {
            EffectOp::LaunchLane | EffectOp::RequestTransfer | EffectOp::StartController => {
                Obligations::of_phase(intent.phase.as_ref(), principal, harness)
            }
            EffectOp::CloseOwnedResources => {
                let (lane, _) = lane_for_intent(run.path, &intent.id)?;
                let mut obligations = Obligations::of_launch(lane.launch.as_ref(), harness);
                if let Some(wake) = crate::ops::wake::wake_identity(&lane) {
                    obligations.add(Obligation::Process(wake), Role::Wake, None);
                }
                let owed = intent.observation.as_ref().is_some_and(|prior| {
                    prior.get("validate").and_then(Value::as_str) == Some("stop-failed")
                });
                if owed {
                    obligations.add(Obligation::Validation, Role::Validation, None);
                }
                obligations
            }
            EffectOp::StopController => match read_overseer(run.path) {
                Ok(overseer) => Obligations::of_overseer(&overseer),
                Err(_) => Obligations::of_phase(None, principal, None),
            },
        })
    }

    pub(in crate::effects) fn intent_id(&self) -> &str {
        &self.intent_id
    }

    /// Whether the record says this intent signalled anything, on this run or
    /// an earlier one.
    pub(in crate::effects) fn signalled(&self) -> bool {
        self.obligations.record().signalled
    }

    /// Whether the record never acquired a handle at all: nothing stands and
    /// nothing was ever discharged. Such a record, with neither identity nor
    /// pane, stays `unconfirmed` and is closed by hand; a set that recorded
    /// any handle settles by what it reads.
    pub(in crate::effects) fn recorded_nothing(&self) -> bool {
        let record = self.obligations.record();
        record.standing.is_empty() && record.discharged.is_empty()
    }

    pub(in crate::effects) fn owes_validation(&self) -> bool {
        self.obligations.stands(&Obligation::Validation)
    }

    /// A close about to run owes the worktree's validation runs to orch's own
    /// runner's answer: acquired before the first signal.
    pub(in crate::effects) fn owe_validation(&mut self) -> Result<()> {
        self.add_as(Obligation::Validation, Role::Validation)
    }

    /// A close about to run owes the lane's local worktree, the record's
    /// `mail_root` (a local lane's mail root is its worktree),
    /// to its own release or keep: acquired before the
    /// first signal. A hosted lane's worktree is its host's,
    /// except a `claude-cloud` lane's, whose `mail_root` is the item's
    /// worktree on this machine (the `lanes` row of the schema), the one
    /// worktree the close removes for a hosted lane; a record naming
    /// none owes nothing.
    pub(in crate::effects) fn owe_worktree(&mut self, lane: &state::Lane) -> Result<()> {
        if lane.host.is_some() && lane.kind.as_deref() != Some(CLOUD_KIND) {
            return Ok(());
        }
        let Some(root) = lane.mail_root.as_deref() else {
            return Ok(());
        };
        self.add_as(
            Obligation::Worktree {
                path: root.to_owned(),
            },
            Role::Worktree,
        )
    }

    /// Whether the predecessor's handles the overseer record names were
    /// acquired by this intent: retirement begun, on this run or an earlier
    /// one.
    pub(in crate::effects) fn retirement_begun(&self, overseer: &Overseer) -> bool {
        let handles = Obligations::of_overseer(overseer);
        let record = self.obligations.record();
        handles
            .record()
            .standing_obligations()
            .any(|handle| record.holds(handle))
    }

    /// Write the intent's progress: the phase where it stands and the set as it
    /// stands, before the action the caller is about to take. The set names the
    /// revision this handle read it at, and the store refuses `set-replaced`
    /// where the record holds another; the revision the store assigned is
    /// mirrored, so the next write names the set it replaces. A write the store
    /// yielded to the intent's claimant, a job that claimed since this handle
    /// opened, is the error `intent-yielded` naming that owner: every acting
    /// method's first write is this one, so the method stops here and acts on
    /// nothing, and the caller hands the claimant's state back through its own
    /// route. An unchanged set the recorded owner still holds is accepted, not
    /// yielded.
    fn write(&mut self) -> Result<()> {
        let applied = ops::apply(
            self.run.path,
            &Request::RecordProgress(Box::new(RecordProgress {
                intent_id: self.intent_id.clone(),
                phase: self.phase.clone(),
                obligations: Some(self.obligations.record().clone()),
                while_owner: self.while_owner.clone(),
                notice: None,
            })),
            self.run.env,
            self.run.locking,
        )?;
        let Report::RecordProgress(r) = &applied.report else {
            unreachable!("record-progress returns its own report")
        };
        match &r.progress {
            Progress::Recorded => {
                if let Some(record) = &r.intent.obligations {
                    self.obligations.set_revision(record.revision);
                }
                Ok(())
            }
            Progress::Unchanged => Ok(()),
            Progress::Yielded { owner } => Err(Error::Yielded {
                id: self.intent_id.clone(),
                owner: owner.clone(),
            }),
        }
    }

    /// Move the intent to `phase`, written before the wait that follows.
    pub(in crate::effects) fn record_phase(&mut self, phase: Phase) -> Result<()> {
        self.phase = Some(phase);
        self.write()
    }

    /// Record the signal before it is sent: from the first no run of this
    /// intent can refuse. The write is made on every
    /// signal, the first or a later one, since it is the conditional write
    /// that proves this handle's set is still the record's: a set another
    /// handle replaced refuses `set-replaced` here and nothing is signalled.
    fn signal(&mut self) -> Result<()> {
        self.obligations.spend();
        self.write()
    }

    /// Settle the obligation `discharge` names by its evidence and write the
    /// set, where the evidence names a standing obligation; evidence about a
    /// handle the record does not carry is nothing of this operation.
    fn discharge(&mut self, discharge: Discharge) -> Result<()> {
        if !self.obligations.stands(&discharge.names()) {
            return Ok(());
        }
        self.obligations.discharge(discharge);
        self.write()
    }

    /// A handle acquired under the operation's principal role, written.
    fn add(&mut self, obligation: Obligation) -> Result<()> {
        self.add_as(obligation, Operation::principal(self.op))
    }

    /// A handle acquired under `role`, the intent's harness kind recorded on
    /// it under the harness role, written before the action or wait that
    /// follows.
    fn add_as(&mut self, obligation: Obligation, role: Role) -> Result<()> {
        if self.obligations.stands(&obligation) {
            return Ok(());
        }
        self.obligations.add(obligation, role, self.harness);
        self.write()
    }

    /// The predecessor's recorded handles become obligations of the intent
    /// at the start of its retirement: written
    /// before the stop or the close that follows.
    pub(in crate::effects) fn begin_retirement(&mut self, overseer: &Overseer) -> Result<()> {
        self.obligations.extend(Obligations::of_overseer(overseer));
        self.write()
    }

    /// The identity the judge read for the attempt becomes the attempt's:
    /// written into `opened` and the set, where a pid the receipt registered
    /// is settled by this read of its identity, and the pane's receipt is
    /// read and discharged by that read, before the wait that follows. The
    /// identity is a [`Recorded`] token this handle's own reader produced.
    pub(in crate::effects) fn record_identity(
        &mut self,
        opened: &mut OpenedPane,
        identity: &Recorded<Identity>,
    ) -> Result<()> {
        let identity = identity.identity();
        opened.identity = Some(identity.clone());
        self.obligations.replace(
            &Obligation::Pid { pid: identity.pid },
            "identity-read",
            Obligation::Process(identity.clone()),
            Operation::principal(self.op),
            self.harness,
        );
        if self.obligations.stands(&Obligation::Receipt) {
            let end = self.read_receipt_end()?;
            self.obligations.discharge(Discharge::Receipt(end));
        }
        self.record_phase(Phase::WindowOpened {
            opened: opened.clone(),
        })
    }

    /// The terminal `word` once every obligation of the recorded set is
    /// discharged, else the intent held open with what stands; the first
    /// reason a discharge left its obligation standing is written as the
    /// observation's `cause` where it names none.
    pub(in crate::effects) fn settle(self, word: Word, observation: Value) -> EffectOutcome {
        let owner = self.while_owner.clone();
        let keys = self.lane_keys();
        let stale = self.stale.clone();
        EffectOutcome::judged(
            &self.intent_id,
            self.op,
            self.obligations,
            word,
            observation,
        )
        .owned_by(owner)
        .keyed(keys)
        .read_stale(stale)
    }

    /// Nothing ends here: the intent stays open with the recorded remainder.
    pub(in crate::effects) fn hold(self, observation: Value) -> EffectOutcome {
        let owner = self.while_owner.clone();
        let keys = self.lane_keys();
        let stale = self.stale.clone();
        EffectOutcome::unconfirmed(&self.intent_id, self.op, self.obligations, observation)
            .owned_by(owner)
            .keyed(keys)
            .read_stale(stale)
    }

    /// A refusal with `cause` where the record says nothing was signalled,
    /// else the same cause held with everything standing.
    pub(in crate::effects) fn refuse(self, cause: &str, observation: Value) -> EffectOutcome {
        let owner = self.while_owner.clone();
        let keys = self.lane_keys();
        let stale = self.stale.clone();
        EffectOutcome::refused_or_held(
            &self.intent_id,
            self.op,
            self.obligations,
            cause,
            observation,
        )
        .owned_by(owner)
        .keyed(keys)
        .read_stale(stale)
    }

    /// The publication: the runner's pane and identity
    /// pass to the record it publishes; everything else the set names, the
    /// predecessor's handles included, must already be discharged by its own
    /// evidence, else the handle comes back with what stands, boxed since it
    /// carries the whole record.
    pub(in crate::effects) fn publish(
        self,
        published: Published,
        opened: &OpenedPane,
        identity: &Recorded<Identity>,
        observation: Value,
    ) -> Result<std::result::Result<EffectOutcome, Box<Operation<'a>>>> {
        let identity = identity.identity();
        let runner = [
            PaneRef::of_opened(opened).obligation(),
            Obligation::Process(identity.clone()),
        ];
        let keys = self.lane_keys();
        let Operation {
            run,
            intent_id,
            op,
            lane_since,
            phase,
            obligations,
            harness,
            stale,
            while_owner,
            clock,
        } = self;
        Ok(match obligations.publish(runner) {
            Ok(settled) => {
                Ok(
                    EffectOutcome::published(&intent_id, op, published, settled, observation)
                        .owned_by(while_owner.clone())
                        .keyed(keys)
                        .read_stale(stale),
                )
            }
            Err(obligations) => Err(Box::new(Operation {
                run,
                intent_id,
                op,
                lane_since,
                phase,
                obligations,
                harness,
                stale,
                while_owner,
                clock,
            })),
        })
    }
}

/// The record-outcome request an effect's outcome builds, applied on the
/// same file as a second committed transition: the one recording boundary.
/// The set the effect left is written first where the record does not hold
/// it yet; a job's failure
/// travels with the outcome as the notice it owes, recorded `owed` by the
/// outcome's own write, and is sent only once that write stands under this
/// owner, then marked, so an owner that
/// moved announces nothing and the claimant's state is the answer, and a
/// notice a crash left owed is sent by the next outcome or reconcile; an
/// intent the outcome closes takes its pane's receipt and its job's files
/// with it. The outcome's write names the set revision the
/// handle read: the set write's own result moves it
/// forward for the outcome's write, and the store refuses the outcome where
/// the record's set moved. Every file effect here, the
/// receipt's and the job files' removal, runs only where
/// the outcome's write reports the intent still this writer's; an owner
/// that moved leaves the claimant's files alone.
pub(in crate::effects) fn apply_outcome(run: &Run, outcome: EffectOutcome) -> Result<Applied> {
    let record_after = outcome.record.clone();
    let while_owner = outcome.while_owner.clone();
    let mut outcome = record(outcome);
    let intent = read_intent(run.path, &outcome.intent_id)?;
    if intent.open()
        && !intent
            .obligations
            .as_ref()
            .is_some_and(|recorded| recorded.same_set(&record_after))
    {
        let applied = ops::apply(
            run.path,
            &Request::RecordProgress(Box::new(RecordProgress {
                intent_id: outcome.intent_id.clone(),
                phase: None,
                obligations: Some(record_after),
                while_owner: while_owner.clone(),
                notice: None,
            })),
            run.env,
            run.locking,
        )?;
        if let Report::RecordProgress(r) = &applied.report {
            match &r.progress {
                Progress::Recorded => {
                    outcome.set_revision = r.intent.obligations.as_ref().map(|o| o.revision);
                }
                // A yielded set write leaves the outcome's own write to
                // yield by the same owner comparison.
                Progress::Unchanged | Progress::Yielded { .. } => {}
            }
        }
    }
    let applied = ops::apply(
        run.path,
        &Request::RecordOutcome(Box::new(outcome)),
        run.env,
        run.locking,
    )?;
    if let Report::RecordOutcome(r) = &applied.report {
        // The notice the record owes and the closed intent's files are this
        // writer's only while the intent is still its own: a launcher whose
        // intent a job claimed leaves the claimant's notices and files to
        // the claimant.
        let ours = while_owner.is_none() || r.intent.owner == while_owner;
        if ours {
            job::deliver_owed(run, &r.intent, while_owner.clone())?;
            if !r.intent.open() {
                receipt::remove(&run.receipt_path(&r.intent.id));
                job::remove_files(&run.settings.state_dir, &r.intent.id);
            }
        }
    }
    Ok(applied)
}

/// The wire record of an effect's outcome: the word,
/// the record fields it publishes or keeps, and the observation with what
/// remains or stands untouched written beside it.
fn record(outcome: EffectOutcome) -> RecordOutcome {
    let EffectOutcome {
        intent_id,
        op,
        terminal,
        mut observation,
        wire,
        while_owner,
        lane_keys,
        record,
        ..
    } = outcome;
    let word = match terminal {
        Terminal::Unconfirmed { remaining } => {
            observation["remaining"] = remaining.value();
            Outcome::Unconfirmed
        }
        Terminal::Failed => Outcome::Failed,
        Terminal::Confirmed => Outcome::Confirmed,
        Terminal::Published(published) => {
            observation["published"] = json!(match published {
                Published::Lane => "lane",
                Published::Successor => "successor",
            });
            Outcome::Confirmed
        }
        Terminal::Refused { cause, untouched } => {
            observation["cause"] = json!(cause);
            observation["stop"] = json!("none");
            observation["untouched"] = untouched.value();
            Outcome::Failed
        }
    };
    let notice = job::owed_notice(op, &intent_id, word, &observation);
    RecordOutcome {
        intent_id,
        outcome: word,
        launch: wire.launch,
        session_id: wire.session_id,
        server_start: wire.server_start,
        server_socket: wire.server_socket,
        window: wire.window,
        tmux_session: wire.tmux_session,
        home: wire.home,
        home_implicit: wire.home_implicit,
        watch: wire.watch,
        mail_root: wire.mail_root,
        observation: Some(observation),
        while_owner,
        lane_keys,
        notice,
        set_revision: Some(record.revision),
    }
}

/// The host facts a lane transition judges live processes against: the
/// kernel's own read, private to `ops`.
pub(in crate::effects) fn host() -> ops::Host<'static> {
    ops::Host::kernel()
}

/// Read a state file for the effect files: their one entry to the store's
/// reader, which the compiler boundary names. `None`
/// where no file stands.
pub(in crate::effects) fn load(path: &std::path::Path) -> Result<Option<state::Snapshot>> {
    state::load(path)
}

/// Persist the close the dispatcher found over a superseded launch, once the
/// launch intent is closed: one of the effect files' store
/// entries beside the handle's own writes (the header names them), judged
/// against the host as the command's entry is. It takes the typed close
/// alone, never a request.
pub(in crate::effects) fn persist_close(
    run: &Run,
    close: &ops::CloseOwnedResources,
) -> Result<Applied> {
    ops::apply_on(
        run.path,
        &Request::CloseOwnedResources(close.clone()),
        run.env,
        run.locking,
        &host(),
    )
}

/// The predecessor's identity the overseer record carries, as an identity
/// the handle's process reads take.
pub(in crate::effects) fn predecessor_identity(overseer: &Overseer) -> Option<Identity> {
    overseer_identity(overseer)
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use agent_runtime::process;

    use super::*;

    fn sleeper() -> (std::process::Child, Identity) {
        let child = std::process::Command::new("/bin/sleep")
            .arg("60")
            .spawn()
            .unwrap();
        let id = match process::identity(child.id()) {
            agent_runtime::reading::Reading::Live(id) => id,
            agent_runtime::reading::Reading::Gone => panic!("the owned child read gone"),
            agent_runtime::reading::Reading::Unreadable { cause } => {
                panic!("the owned child's identity: {cause}")
            }
        };
        (child, id)
    }

    fn live(id: &Identity) -> bool {
        matches!(
            process::still_runs(id),
            agent_runtime::reading::Reading::Live(_)
        )
    }

    /// A fleet under `dir` holding one signalled, unconfirmed close intent
    /// whose set is `standing`, and the run over it.
    fn close_fixture(
        dir: &Path,
        standing: Value,
    ) -> (crate::settings::Settings, ops::Env, PathBuf, Intent) {
        let roots = crate::settings::Roots {
            project: dir.into(),
            common: dir.into(),
        };
        let settings = crate::settings::load(
            &roots,
            &[],
            &crate::settings::Flags {
                state_dir: Some(dir.into()),
                private_env: false,
            },
        )
        .unwrap();
        let env = ops::Env {
            now_secs: 1_769_700_000,
            now_nanos: 1_769_700_000_000_000_000,
            nonce: 77,
            owner: None,
        };
        let path = dir.join(crate::state::FLEET_FILE_NAME);
        let intent: Intent = serde_json::from_value(json!({
            "id": "close-owned-resources:KEN-T:1-1", "op": "close-owned-resources",
            "target": "KEN-T", "revision": 0, "created_at": "2026-01-29T15:20:00Z",
            "outcome": "unconfirmed",
            "obligations": {"standing": standing, "discharged": [], "signalled": true}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_str(crate::state::fixtures::FLEET).unwrap();
        fleet["intents"] = json!([intent]);
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        (settings, env, path, intent)
    }

    fn process_row(id: &Identity, role: &str) -> Value {
        json!({"kind": "process", "pid": id.pid, "start": id.start, "role": role})
    }

    /// A record with an obligation under no role opens no handle:
    /// `role-missing` names the intent and nothing is written. The same
    /// record under a role opens.
    #[test]
    fn a_record_with_an_obligation_under_no_role_is_refused_role_missing() {
        let dir = tempfile::tempdir().unwrap();
        let id = Identity {
            pid: 4242,
            start: "ticks:4242".into(),
        };
        let (settings, env, path, intent) = close_fixture(
            dir.path(),
            json!([{"kind": "process", "pid": id.pid, "start": id.start}]),
        );
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: crate::state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let refused = Operation::open(&run, &intent).err();
        assert!(
            matches!(&refused, Some(Error::RoleMissing { id }) if *id == intent.id),
            "{refused:?}"
        );
        assert_eq!(
            read_intent(&path, &intent.id).unwrap(),
            intent,
            "the refused open wrote nothing"
        );
        let (_, _, path, roled) = close_fixture(dir.path(), json!([process_row(&id, "harness")]));
        let run = Run { path: &path, ..run };
        let opened = Operation::open(&run, &roled).unwrap();
        assert_eq!(opened.harness_identity(), Some(id));
    }

    /// A moved close holding a pane key
    /// whose server start is not the start of the server now answering at
    /// the key's pid reads that pane gone with its server, `server-unmatched`
    /// on the retry's close of its own panes: the key is
    /// discharged `pane-gone`, the intent settles, and the pane that stands
    /// on the replacement server is never touched. A key at the server's
    /// real start, the control, closes its pane by exact id.
    #[test]
    fn a_pane_key_on_a_server_replaced_at_the_same_pid_reads_gone_on_the_moved_close() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("tmux.sock");
        let server = agent_runtime::host::tmux::start_private_server(&socket, "s", dir.path())
            .expect("a private tmux server");
        for (start, expect) in [(server.start + 1, "pane-gone"), (server.start, "closed")] {
            let pane = agent_runtime::host::tmux::new_window(&server, "s", "w", dir.path())
                .expect("a window");
            let (settings, env, path, mut intent) = close_fixture(
                dir.path(),
                json!([{"kind": "pane", "pane": pane.id, "server": server.pid, "server_start": start, "role": "harness"}]),
            );
            intent.phase = Some(
                serde_json::from_value(json!({
                    "phase": "window-opened", "pane": pane.id, "server": server.pid,
                    "server_start": start, "socket": socket.display().to_string(), "since_ms": 1,
                }))
                .unwrap(),
            );
            let mut fleet: Value = serde_json::from_str(crate::state::fixtures::FLEET).unwrap();
            fleet["intents"] = json!([intent]);
            std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
            let run = Run {
                path: &path,
                settings: &settings,
                env: &env,
                locking: crate::state::Locking::FLOCK,
                clock: &crate::schedule::SystemClock,
            };
            let mut operation = Operation::open(&run, &intent).unwrap();
            operation.close_standing_panes(None).unwrap();
            let record = operation.obligations.record().clone();
            let discharged: Vec<&str> = record.discharged.iter().map(|d| d.by.as_str()).collect();
            assert_eq!(discharged, vec![expect], "start {start}: {record:?}");
            assert!(record.standing.is_empty(), "{record:?}");
            let stands = matches!(
                agent_runtime::host::tmux::pane_fields(&server, &pane.id),
                Reading::Live(_)
            );
            assert_eq!(
                stands,
                expect == "pane-gone",
                "start {start}: a pane on a server read replaced is never touched; one on the recorded server is closed"
            );
            if stands {
                let _ = agent_runtime::host::tmux::kill_pane(&pane);
            }
        }
        let _ = agent_runtime::host::tmux::kill_server(&server);
    }

    /// A token names a key of the set that minted it and acts on no other. The token
    /// one intent's handle minted for its process is handed to another intent's
    /// handle, whose set never held that process: the stop is refused
    /// `token-stale`, nothing is written and the sleeper is never signalled.
    #[test]
    fn a_token_for_a_process_the_handles_set_never_held_is_refused_token_stale() {
        let dir = tempfile::tempdir().unwrap();
        let (mut child, id) = sleeper();
        let (settings, env, path, holder) =
            close_fixture(dir.path(), json!([process_row(&id, "harness")]));
        let other: Intent = serde_json::from_value(json!({
            "id": "close-owned-resources:KEN-U:1-1", "op": "close-owned-resources",
            "target": "KEN-U", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "obligations": {"standing": [{"kind": "validation", "role": "validation"}],
                            "discharged": [], "signalled": true}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        fleet["intents"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::to_value(&other).unwrap());
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: crate::state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let holder = Operation::open(&run, &holder).unwrap();
        let token = holder.standing_process(&id).expect("the process stands");
        let mut other = Operation::open(&run, &other).unwrap();
        let before = read_intent(&path, other.intent_id()).unwrap();
        let refused = other.stop_process(token, &|_| false);
        let survived = live(&id);
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(
            refused.as_ref().err().map(|e| e.key()),
            Some("token-stale"),
            "a key the set never held is refused, never acted on: {refused:?}"
        );
        assert!(survived, "the sleeper was never signalled");
        assert_eq!(
            read_intent(&path, other.intent_id()).unwrap(),
            before,
            "the refused stop wrote nothing"
        );
    }

    /// The set is
    /// replaced through the real transition while a handle stands open, the
    /// process removed from it. The handle's token is refused at its first
    /// write, `set-replaced`, before anything is signalled: the sleeper
    /// lives and the record's set is the replacement, untouched.
    #[test]
    fn a_handle_whose_set_was_replaced_under_it_is_refused_set_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let (mut child, id) = sleeper();
        let (settings, env, path, intent) =
            close_fixture(dir.path(), json!([process_row(&id, "harness")]));
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: crate::state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let mut handle = Operation::open(&run, &intent).unwrap();
        let minted_at = handle.revision();
        let token = handle.standing_process(&id).expect("the process stands");
        let mut replaced: state::ObligationRecord = serde_json::from_value(json!({
            "standing": [], "discharged": [], "signalled": true
        }))
        .unwrap();
        replaced.revision = minted_at;
        ops::apply(
            &path,
            &Request::RecordProgress(Box::new(RecordProgress {
                intent_id: intent.id.clone(),
                phase: None,
                obligations: Some(replaced),
                while_owner: None,
                notice: None,
            })),
            &env,
            crate::state::Locking::FLOCK,
        )
        .unwrap();
        let refused = handle.stop_process(token, &|_| false);
        let survived = live(&id);
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(
            refused.as_ref().err().map(|e| e.key()),
            Some("set-replaced"),
            "the stale handle's first write is refused before it acts: {refused:?}"
        );
        assert!(survived, "the sleeper was never signalled");
        let after = read_intent(&path, &intent.id).unwrap().obligations.unwrap();
        assert!(
            after.standing.is_empty() && after.revision == minted_at + 1,
            "the record's set is the replacement, untouched by the stale handle: {after:?}"
        );
    }

    /// A handle opened under the intent's recorded owner mints a token
    /// for an owned sleeper; a claimant takes the intent through the real claim
    /// and replaces the set with an empty one through the real progress
    /// transition. The first handle's stop is refused `intent-yielded`, naming
    /// the claimant, at its first write, before anything is signalled: the
    /// sleeper lives, the claimant still owns the intent and its empty set is
    /// unchanged.
    #[test]
    fn a_write_the_store_yielded_to_a_claimant_stops_the_handle_before_it_acts() {
        let dir = tempfile::tempdir().unwrap();
        let (mut child, id) = sleeper();
        let (settings, env, path, intent) =
            close_fixture(dir.path(), json!([process_row(&id, "harness")]));
        let old = Owner {
            pid: 123,
            start: "old".into(),
        };
        let new = Owner {
            pid: 456,
            start: "new".into(),
        };
        let mut fleet: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        fleet["intents"][0]["owner"] = serde_json::to_value(&old).unwrap();
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let intent = read_intent(&path, &intent.id).unwrap();
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: crate::state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let mut handle = Operation::open(&run, &intent).unwrap();
        let token = handle.standing_process(&id).expect("the process stands");
        let claimant = ops::Env {
            owner: Some(new.clone()),
            ..env.clone()
        };
        ops::apply(
            &path,
            &Request::ClaimIntent(ops::ClaimIntent {
                intent_id: intent.id.clone(),
            }),
            &claimant,
            crate::state::Locking::FLOCK,
        )
        .unwrap();
        let mut replacement = read_intent(&path, &intent.id)
            .unwrap()
            .obligations
            .expect("the claimed intent keeps its set");
        replacement.standing.clear();
        ops::apply(
            &path,
            &Request::RecordProgress(Box::new(RecordProgress {
                intent_id: intent.id.clone(),
                phase: None,
                obligations: Some(replacement),
                while_owner: Some(new.clone()),
                notice: None,
            })),
            &claimant,
            crate::state::Locking::FLOCK,
        )
        .unwrap();
        let before = read_intent(&path, &intent.id).unwrap();
        let answer = handle.stop_process(token, &|_| false);
        let survived = live(&id);
        let after = read_intent(&path, &intent.id).unwrap();
        let _ = child.kill();
        let _ = child.wait();
        assert!(
            matches!(&answer, Err(Error::Yielded { owner, .. }) if *owner == new),
            "the yielded first write stops the handle and names the claimant: {answer:?}"
        );
        assert!(survived, "the sleeper was never signalled");
        assert_eq!(after.owner, Some(new), "the claimant still owns the intent");
        assert_eq!(
            after.obligations, before.obligations,
            "the claimant's set is unchanged"
        );
        assert!(
            after.obligations.as_ref().unwrap().standing.is_empty(),
            "{after:?}"
        );
    }
}
