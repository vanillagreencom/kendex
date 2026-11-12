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
//! and a settlement needs every obligation discharged. `apply_outcome_with`
//! is the one path from an outcome to the store, its opener's own part of
//! the request an argument. The effect files' other entries to the store,
//! beside the handle's own writes, are the few this module names:
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
//! one clock, which `main.rs` builds and `open` takes. A handle's writes
//! yield to a job that claimed the intent, and `apply` retries the
//! owner-conditional transition on a conflicting snapshot so the claimant's
//! state is the answer. The set an intent records nothing of starts from the
//! record data its opener names ([`Bootstrap`]); the set's roles select the
//! harness and the pane from then on, and the harness kind recorded under
//! the harness role names what a stop may signal below a recorded root. An
//! act outside the handle holds the receipt of its `signalled` write
//! ([`Signalled`]).
//!
//! `host.rs` reads, signals and closes processes and panes; `window.rs`
//! opens a window, recovers an `opening` and polls a pane; `job.rs` asks the
//! job launcher and reads its record; `obligations.rs` is the private
//! outcome model; `receipt.rs` the pane's own registration.

mod adoption;
mod host;
pub mod job;
mod obligations;
mod receipt;
#[cfg(test)]
mod testing;
mod window;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::harness::Harness;
use crate::intent::Owner;
use crate::protocol::Outcome;
use serde_json::{Value, json};

pub use crate::host::tmux::{Close, Pane, Server};
pub use crate::observe::{ProcessReading, State};
pub use crate::process::{Identity, Stop};
pub use crate::reading::Reading;
pub use host::Recorded;
pub use host::{
    Binding, Delivery, Foreground, ProcessRead, Proof, SessionFloor, WindowClose, adopt_controller,
    default_home, fixed_file, fixed_id_file, heal_controller, owner,
};
pub use host::{Observed, fleet_sockets, overseer_socket, server_at};
pub use host::{SignIn, process_var, register_controller};
pub use host::{poll_until, server_home, session_owner};
pub use job::{Claimant, Companion};
pub use obligations::{EffectOutcome, Published, Wire, Word};
pub use obligations::{JobHandle, SidecarRead};
pub use window::{OpenRefusal, Polled, Recovered, TurnConfirm, opening_observation};

use obligations::{Discharge, Obligations, PaneRef, Terminal};

use crate::clock::Clock;
use crate::controller::Overseer;
use crate::error::{Error, Result};
use crate::intent::Intent;
use crate::intent::LaunchIdentity;
use crate::intent::{EffectOp, Obligation, OpenedPane, Phase, Role};
use crate::journal::{Env, OutcomeArm, OutcomeWritten, Progress, RecordOutcome, RecordProgress};
use crate::record::Locking;
use crate::settings::{EngineSettings, Judged};

/// How often a poll re-reads the record, a process or a pane within its
/// bound.
const POLL: Duration = Duration::from_millis(200);

/// What one run of the engine acts with, as its opener passes it: the
/// record, the engine's own settings, the directory its job, receipt,
/// brief and notice files live in, the grace a stop leaves between its
/// signals, the mailbox program the owner notice runs and the main checkout
/// it runs at, the writer's stamp and lock policy, the one clock every wait
/// reads, and the opener's part of an outcome's transition, which moves the
/// target record the intent names.
pub struct Run<'a> {
    pub path: &'a Path,
    pub settings: &'a EngineSettings,
    pub state_dir: PathBuf,
    pub close_grace: Judged<Duration>,
    pub mail_program: PathBuf,
    pub root: PathBuf,
    pub env: &'a Env,
    pub locking: Locking,
    pub clock: &'a dyn Clock,
    pub outcome_arm: OutcomeArm<Error>,
}

impl Run<'_> {
    /// Where the pane of `intent_id` registers itself.
    fn receipt_path(&self, intent_id: &str) -> PathBuf {
        crate::record::receipt_path(&self.state_dir, intent_id)
    }
}

/// The harness a pane runs and the executable configured for it: together
/// they name the processes that are the harness's own, its own names and
/// the configured program's basename (`Harness::owns_process_of`).
#[derive(Clone)]
pub struct Target {
    harness: Harness,
    program: Option<PathBuf>,
}

impl Target {
    pub fn new(binaries: &Judged<BTreeMap<Harness, PathBuf>>, harness: Harness) -> Result<Target> {
        Ok(Target {
            harness,
            program: binaries.get()?.remove(&harness),
        })
    }

    pub fn harness(&self) -> Harness {
        self.harness
    }

    pub fn owns(&self, name: &str) -> bool {
        self.harness.owns_process_of(self.program.as_deref(), name)
    }
}

/// The fields of the fleet record the engine reads, from one read: the
/// intents and the controller record.
pub struct FleetView {
    pub intents: Vec<Intent>,
    pub overseer: Option<Overseer>,
}

/// The fleet record at `path`, read through the store's reader; a missing
/// file refuses `record-missing`.
pub fn fleet_view(path: &Path) -> Result<FleetView> {
    let doc = crate::record::read_document(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    Ok(FleetView {
        intents: crate::record::field(path, &doc, "intents")?.unwrap_or_default(),
        overseer: crate::record::field(path, &doc, "overseer")?,
    })
}

/// The controller record the fleet holds; none refuses `overseer-missing`.
pub fn read_overseer(path: &Path) -> Result<Overseer> {
    fleet_view(path)?
        .overseer
        .ok_or_else(|| Error::OverseerMissing {
            path: path.to_path_buf(),
        })
}

/// The intent `intent_id` as the fleet records it.
pub fn read_intent(path: &Path, intent_id: &str) -> Result<Intent> {
    fleet_view(path)?
        .intents
        .into_iter()
        .find(|i| i.id == intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: intent_id.to_owned(),
        })
}

/// The predecessor's harness and configured program, the processes its
/// exact stop may name below the recorded root.
pub fn overseer_target_of(
    binaries: &Judged<BTreeMap<Harness, PathBuf>>,
    overseer: &Overseer,
) -> Result<Option<Target>> {
    overseer
        .extra
        .get("harness")
        .and_then(Value::as_str)
        .and_then(Harness::parse)
        .map(|h| Target::new(binaries, h))
        .transpose()
}

/// A pid a record carries as the number the runtime writes or the string a
/// shell writer's jq `--arg` writes (the controller's `server` and
/// `harness_pid`).
fn pid_value(value: &Value) -> Option<u64> {
    match value {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse().ok(),
        Value::Null | Value::Bool(_) | Value::Array(_) | Value::Object(_) => None,
    }
}

/// What the opener names as the set's start where the intent records none:
/// record data, never a token. The engine reads no target record of its
/// own beside the controller's.
pub enum Bootstrap<'r> {
    /// A launch or a succession: what its phase names, under `principal`,
    /// the harness kind `harness` recorded on the handles under the harness
    /// role.
    Phase {
        principal: Role,
        harness: Option<Harness>,
    },
    /// A target's recorded launch under the harness role, with the harness
    /// kind it runs, and the auxiliary process it names beside the harness.
    Launch {
        launch: Option<&'r LaunchIdentity>,
        harness: Option<Harness>,
        auxiliary: Option<Identity>,
    },
    /// A controller stop: the handles the controller record names, under
    /// the predecessor role.
    Predecessor,
}

impl Bootstrap<'_> {
    /// A controller operation's start: a succession's or a start's phase
    /// under the runner role, a stop's predecessor record. `None` for the
    /// operations whose opener names their target's record.
    pub fn controller(op: EffectOp) -> Option<Bootstrap<'static>> {
        match op {
            EffectOp::RequestTransfer | EffectOp::StartController => Some(Bootstrap::Phase {
                principal: Role::Runner,
                harness: None,
            }),
            EffectOp::StopController => Some(Bootstrap::Predecessor),
            EffectOp::LaunchSession | EffectOp::CloseResources => None,
        }
    }

    /// The role a handle this operation acquires takes where nothing names
    /// another.
    fn principal(&self) -> Role {
        match self {
            Bootstrap::Phase { principal, .. } => *principal,
            Bootstrap::Launch { .. } => Role::Harness,
            Bootstrap::Predecessor => Role::Predecessor,
        }
    }

    /// The harness kind the target runs, where the opener read one.
    fn harness(&self) -> Option<Harness> {
        match self {
            Bootstrap::Phase { harness, .. } | Bootstrap::Launch { harness, .. } => *harness,
            Bootstrap::Predecessor => None,
        }
    }
}

/// The receipt of the handle's `signalled` write: the proof an act outside
/// the handle holds before it acts, so the act is covered by the write's
/// revision and owner checks and no refusal is expressible after it.
#[must_use]
pub struct Signalled {
    _written: (),
}

pub struct Operation<'a> {
    run: &'a Run<'a>,
    intent_id: String,
    op: EffectOp,
    /// The role a handle this operation acquires takes where nothing names
    /// another, from the opener's bootstrap.
    principal: Role,
    phase: Option<Phase>,
    /// The set as this handle read it, carrying the store's `revision` of
    /// that read, mirrored after each of the handle's own writes: the one
    /// value named revision, which every write sends back so the store
    /// refuses `set-replaced` where another handle or process replaced the
    /// set meanwhile.
    obligations: Obligations,
    /// The harness kind the target runs under this intent, recorded on every
    /// handle acquired under the harness role, from the set where one is
    /// recorded, else from the opener. `None` on a controller intent, whose
    /// handles are the runner's and the predecessor's.
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
    /// Open the handle on `intent`: the recorded set where one stands, else
    /// the set `bootstrap` names, written at once.
    pub fn open(
        run: &'a Run<'a>,
        intent: &Intent,
        bootstrap: Bootstrap<'_>,
    ) -> Result<Operation<'a>> {
        let recorded = Obligations::recorded(intent)?;
        let bootstrapped = recorded.is_none();
        let principal = bootstrap.principal();
        // The harness kind is the set's where one is recorded; the opener's
        // only at a bootstrap.
        let (obligations, harness) = match recorded {
            Some(obligations) => {
                let harness = obligations.recorded_harness();
                (obligations, harness)
            }
            None => {
                let harness = bootstrap.harness();
                (Operation::bootstrap(run, intent, bootstrap)?, harness)
            }
        };
        let mut operation = Operation {
            run,
            intent_id: intent.id.clone(),
            op: intent.op,
            principal,
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

    /// The harness kind the set records under the harness role: what names
    /// the processes below a recorded root that a stop on this set may
    /// signal, never the harness the target runs now.
    pub fn recorded_harness(&self) -> Option<Harness> {
        self.obligations.recorded_harness()
    }

    /// The role a handle this operation acquires takes where nothing names
    /// another.
    pub(super) fn principal_role(&self) -> Role {
        self.principal
    }

    #[cfg(test)]
    fn revision(&self) -> u64 {
        self.obligations.record().revision
    }

    /// Every identity, pid and pane key the set recorded under the
    /// principal's role, standing or discharged: what a terminal carries
    /// for its target's record.
    pub fn principal_keys(&self) -> Vec<Obligation> {
        self.obligations.record().principal_keys(self.principal)
    }

    /// The identities an earlier handle of this same request read stale: a
    /// reading this handle makes of one counts no second time; a second
    /// reading is a later request's.
    pub fn already_read_stale(&mut self, stale: &[Identity]) {
        for id in stale {
            if !self.stale.contains(id) {
                self.stale.push(id.clone());
            }
        }
    }

    fn bootstrap(run: &Run, intent: &Intent, bootstrap: Bootstrap<'_>) -> Result<Obligations> {
        Ok(match bootstrap {
            Bootstrap::Phase { principal, harness } => {
                Obligations::of_phase(intent.phase.as_ref(), principal, harness)
            }
            Bootstrap::Launch {
                launch,
                harness,
                auxiliary,
            } => {
                let mut obligations = Obligations::of_launch(launch, harness);
                if let Some(auxiliary) = auxiliary {
                    obligations.add(Obligation::Process(auxiliary), Role::Auxiliary, None);
                }
                obligations
            }
            Bootstrap::Predecessor => match read_overseer(run.path) {
                Ok(overseer) => Obligations::of_overseer(&overseer),
                Err(_) => Obligations::of_phase(None, Role::Predecessor, None),
            },
        })
    }

    pub fn intent_id(&self) -> &str {
        &self.intent_id
    }

    /// Whether the record says this intent signalled anything, on this run or
    /// an earlier one.
    pub fn signalled(&self) -> bool {
        self.obligations.record().signalled
    }

    /// Whether the record never acquired a handle at all: nothing stands and
    /// nothing was ever discharged. Such a record, with neither identity nor
    /// pane, stays `unconfirmed` and is closed by hand; a set that recorded
    /// any handle settles by what it reads.
    pub fn recorded_nothing(&self) -> bool {
        let record = self.obligations.record();
        record.standing.is_empty() && record.discharged.is_empty()
    }

    /// Whether the predecessor's handles the overseer record names were
    /// acquired by this intent: retirement begun, on this run or an earlier
    /// one.
    pub fn retirement_begun(&self, overseer: &Overseer) -> bool {
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
        let r = crate::journal::write_progress(
            self.run.path,
            &RecordProgress {
                intent_id: self.intent_id.clone(),
                phase: self.phase.clone(),
                obligations: Some(self.obligations.record().clone()),
                while_owner: self.while_owner.clone(),
                notice: None,
            },
            self.run.locking,
        )?;
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
    pub fn record_phase(&mut self, phase: Phase) -> Result<()> {
        self.phase = Some(phase);
        self.write()
    }

    /// Record the signal before it is sent: from the first no run of this
    /// intent can refuse. The write is made on every
    /// signal, the first or a later one, since it is the conditional write
    /// that proves this handle's set is still the record's: a set another
    /// handle replaced refuses `set-replaced` here and nothing is signalled.
    fn write_signal(&mut self) -> Result<()> {
        self.obligations.spend();
        self.write()
    }

    /// The signal an act outside the handle sends, written before it acts:
    /// the receipt is what that act holds when it discharges its own
    /// obligation.
    pub fn signal(&mut self) -> Result<Signalled> {
        self.write_signal()?;
        Ok(Signalled { _written: () })
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
        self.add_as(obligation, self.principal)
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

    /// The auxiliary process the target's record names now, acquired under
    /// the auxiliary role and written before the stop or read that follows.
    pub fn acquire_auxiliary(&mut self, id: Identity) -> Result<()> {
        self.add_as(Obligation::Process(id), Role::Auxiliary)
    }

    /// The predecessor's recorded handles become obligations of the intent
    /// at the start of its retirement: written
    /// before the stop or the close that follows.
    pub fn begin_retirement(&mut self, overseer: &Overseer) -> Result<()> {
        self.obligations.extend(Obligations::of_overseer(overseer));
        self.write()
    }

    /// The identity the judge read for the attempt becomes the attempt's:
    /// written into `opened` and the set, where a pid the receipt registered
    /// is settled by this read of its identity, and the pane's receipt is
    /// read and discharged by that read, before the wait that follows. The
    /// identity is a [`Recorded`] token this handle's own reader produced.
    pub fn record_identity(
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
            self.principal,
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
    pub fn settle(self, word: Word, observation: Value) -> EffectOutcome {
        let owner = self.while_owner.clone();
        let keys = self.principal_keys();
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
    pub fn hold(self, observation: Value) -> EffectOutcome {
        let owner = self.while_owner.clone();
        let keys = self.principal_keys();
        let stale = self.stale.clone();
        EffectOutcome::unconfirmed(&self.intent_id, self.op, self.obligations, observation)
            .owned_by(owner)
            .keyed(keys)
            .read_stale(stale)
    }

    /// A refusal with `cause` where the record says nothing was signalled,
    /// else the same cause held with everything standing.
    pub fn refuse(self, cause: &str, observation: Value) -> EffectOutcome {
        let owner = self.while_owner.clone();
        let keys = self.principal_keys();
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
    pub fn publish(
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
        let keys = self.principal_keys();
        let Operation {
            run,
            intent_id,
            op,
            principal,
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
                principal,
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

/// The engine's recording boundary for its own operations: an outcome
/// applied with no caller's arm.
pub fn apply_outcome(run: &Run, outcome: EffectOutcome) -> Result<OutcomeWritten> {
    apply_outcome_with(run, outcome, |_| {})
}

/// The record-outcome request an effect's outcome builds, applied on the
/// same file as a second committed transition. `arm` is the opener's own
/// part of the request (its own set's remainder and keys), applied to
/// the wire record before it is written. The set the effect left is
/// written first where the record does not hold it yet; a job's failure
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
pub fn apply_outcome_with(
    run: &Run,
    outcome: EffectOutcome,
    arm: impl FnOnce(&mut RecordOutcome),
) -> Result<OutcomeWritten> {
    let record_after = outcome.record.clone();
    let while_owner = outcome.while_owner.clone();
    let mut outcome = outcome.wire();
    arm(&mut outcome);
    let intent = read_intent(run.path, &outcome.intent_id)?;
    if intent.open()
        && !intent
            .obligations
            .as_ref()
            .is_some_and(|recorded| recorded.same_set(&record_after))
    {
        let r = crate::journal::write_progress(
            run.path,
            &RecordProgress {
                intent_id: outcome.intent_id.clone(),
                phase: None,
                obligations: Some(record_after),
                while_owner: while_owner.clone(),
                notice: None,
            },
            run.locking,
        )?;
        match &r.progress {
            Progress::Recorded => {
                outcome.set_revision = r.intent.obligations.as_ref().map(|o| o.revision);
            }
            // A yielded set write leaves the outcome's own write to
            // yield by the same owner comparison.
            Progress::Unchanged | Progress::Yielded { .. } => {}
        }
    }
    let r =
        crate::journal::write_outcome(run.path, &outcome, run.env, run.locking, run.outcome_arm)?;
    // The notice the record owes and the closed intent's files are this
    // writer's only while the intent is still its own: a launcher whose
    // intent a job claimed leaves the claimant's notices and files to
    // the claimant.
    let ours = while_owner.is_none() || r.intent.owner == while_owner;
    if ours {
        job::deliver_owed(run, &r.intent, while_owner.clone())?;
        if !r.intent.open() {
            receipt::remove(&run.receipt_path(&r.intent.id));
            job::remove_files(&run.state_dir, &r.intent.id);
        }
    }
    Ok(r)
}

impl EffectOutcome {
    /// The wire record of the outcome: the word,
    /// the record fields it publishes or keeps, and the observation with what
    /// remains or stands untouched written beside it. The principal keys
    /// are the caller's to carry, under the target's stamp it knows.
    pub fn wire(self) -> RecordOutcome {
        let EffectOutcome {
            intent_id,
            op,
            terminal,
            mut observation,
            wire,
            while_owner,
            record,
            ..
        } = self;
        let word = match terminal {
            Terminal::Unconfirmed { remaining } => {
                observation["remaining"] = remaining.value();
                Outcome::Unconfirmed
            }
            Terminal::Failed => Outcome::Failed,
            Terminal::Confirmed => Outcome::Confirmed,
            Terminal::Published(published) => {
                observation["published"] = json!(match published {
                    Published::Target => "target",
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
            home: wire.home,
            watch: wire.watch,
            members: wire.members,
            observation: Some(observation),
            while_owner,
            principal_keys: None,
            notice,
            set_revision: Some(record.revision),
        }
    }
}

/// The predecessor's identity the controller record carries, as an identity
/// the handle's process reads take: `harness_pid` is a string where a shell
/// writer wrote it through jq's `--arg`, and a number where the runtime
/// wrote it. Both are read.
pub fn predecessor_identity(overseer: &Overseer) -> Option<Identity> {
    let pid = overseer.extra.get("harness_pid").and_then(pid_value)?;
    let start = overseer
        .extra
        .get("harness_start")
        .and_then(Value::as_str)?;
    Some(Identity {
        pid: u32::try_from(pid).ok()?,
        start: start.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use crate::process;

    use super::*;

    fn sleeper() -> (std::process::Child, Identity) {
        let child = std::process::Command::new("/bin/sleep")
            .arg("60")
            .spawn()
            .unwrap();
        let id = match process::identity(child.id()) {
            crate::reading::Reading::Live(id) => id,
            crate::reading::Reading::Gone => panic!("the owned child read gone"),
            crate::reading::Reading::Unreadable { cause } => {
                panic!("the owned child's identity: {cause}")
            }
        };
        (child, id)
    }

    fn live(id: &Identity) -> bool {
        matches!(process::still_runs(id), crate::reading::Reading::Live(_))
    }

    /// A fleet under `dir` holding one signalled, unconfirmed close intent
    /// whose set is `standing`, and the run over it.
    fn close_fixture(
        dir: &Path,
        standing: Value,
    ) -> (EngineSettings, crate::journal::Env, PathBuf, Intent) {
        let settings = super::testing::settings(dir);
        let env = crate::journal::Env {
            now_secs: 1_769_700_000,
            now_nanos: 1_769_700_000_000_000_000,
            nonce: 77,
            owner: None,
        };
        let path = dir.join(crate::record::FLEET_FILE_NAME);
        let intent: Intent = serde_json::from_value(json!({
            "id": "close-resources:KEN-T:1-1", "op": "close-resources",
            "target": "KEN-T", "revision": 0, "created_at": "2026-01-29T15:20:00Z",
            "outcome": "unconfirmed",
            "obligations": {"standing": standing, "discharged": [], "signalled": true}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_str(super::testing::FLEET).unwrap();
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
        let run = super::testing::run(
            &path,
            &settings,
            &env,
            dir.path(),
            dir.path().join("lane-mail"),
            &crate::clock::SystemClock,
        );
        let refused = Operation::open(
            &run,
            &intent,
            Bootstrap::Launch {
                launch: None,
                harness: None,
                auxiliary: None,
            },
        )
        .err();
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
        let opened = Operation::open(
            &run,
            &roled,
            Bootstrap::Launch {
                launch: None,
                harness: None,
                auxiliary: None,
            },
        )
        .unwrap();
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
        let server = crate::host::tmux::start_private_server(&socket, "s", dir.path())
            .expect("a private tmux server");
        for (start, expect) in [(server.start + 1, "pane-gone"), (server.start, "closed")] {
            let pane =
                crate::host::tmux::new_window(&server, "s", "w", dir.path()).expect("a window");
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
            let mut fleet: Value = serde_json::from_str(super::testing::FLEET).unwrap();
            fleet["intents"] = json!([intent]);
            std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
            let run = super::testing::run(
                &path,
                &settings,
                &env,
                dir.path(),
                dir.path().join("lane-mail"),
                &crate::clock::SystemClock,
            );
            let mut operation = Operation::open(
                &run,
                &intent,
                Bootstrap::Launch {
                    launch: None,
                    harness: None,
                    auxiliary: None,
                },
            )
            .unwrap();
            operation.close_standing_panes(None).unwrap();
            let record = operation.obligations.record().clone();
            let discharged: Vec<&str> = record.discharged.iter().map(|d| d.by.as_str()).collect();
            assert_eq!(discharged, vec![expect], "start {start}: {record:?}");
            assert!(record.standing.is_empty(), "{record:?}");
            let stands = matches!(
                crate::host::tmux::pane_fields(&server, &pane.id),
                Reading::Live(_)
            );
            assert_eq!(
                stands,
                expect == "pane-gone",
                "start {start}: a pane on a server read replaced is never touched; one on the recorded server is closed"
            );
            if stands {
                let _ = crate::host::tmux::kill_pane(&pane);
            }
        }
        let _ = crate::host::tmux::kill_server(&server);
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
            "id": "close-resources:KEN-U:1-1", "op": "close-resources",
            "target": "KEN-U", "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "obligations": {"standing": [{"kind": "receipt", "role": "harness"}],
                            "discharged": [], "signalled": true}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        fleet["intents"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::to_value(&other).unwrap());
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let run = super::testing::run(
            &path,
            &settings,
            &env,
            dir.path(),
            dir.path().join("lane-mail"),
            &crate::clock::SystemClock,
        );
        let holder = Operation::open(
            &run,
            &holder,
            Bootstrap::Launch {
                launch: None,
                harness: None,
                auxiliary: None,
            },
        )
        .unwrap();
        let token = holder.standing_process(&id).expect("the process stands");
        let mut other = Operation::open(
            &run,
            &other,
            Bootstrap::Launch {
                launch: None,
                harness: None,
                auxiliary: None,
            },
        )
        .unwrap();
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
        let run = super::testing::run(
            &path,
            &settings,
            &env,
            dir.path(),
            dir.path().join("lane-mail"),
            &crate::clock::SystemClock,
        );
        let mut handle = Operation::open(
            &run,
            &intent,
            Bootstrap::Launch {
                launch: None,
                harness: None,
                auxiliary: None,
            },
        )
        .unwrap();
        let minted_at = handle.revision();
        let token = handle.standing_process(&id).expect("the process stands");
        let mut replaced: crate::intent::ObligationRecord = serde_json::from_value(json!({
            "standing": [], "discharged": [], "signalled": true
        }))
        .unwrap();
        replaced.revision = minted_at;
        crate::journal::write_progress(
            &path,
            &RecordProgress {
                intent_id: intent.id.clone(),
                phase: None,
                obligations: Some(replaced),
                while_owner: None,
                notice: None,
            },
            crate::record::Locking::FLOCK,
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
        let run = super::testing::run(
            &path,
            &settings,
            &env,
            dir.path(),
            dir.path().join("lane-mail"),
            &crate::clock::SystemClock,
        );
        let mut handle = Operation::open(
            &run,
            &intent,
            Bootstrap::Launch {
                launch: None,
                harness: None,
                auxiliary: None,
            },
        )
        .unwrap();
        let token = handle.standing_process(&id).expect("the process stands");
        let claimant = crate::journal::Env {
            owner: Some(new.clone()),
            ..env.clone()
        };
        crate::journal::write_claim(
            &path,
            &crate::journal::ClaimIntent {
                intent_id: intent.id.clone(),
            },
            &claimant,
            crate::record::Locking::FLOCK,
        )
        .unwrap();
        let mut replacement = read_intent(&path, &intent.id)
            .unwrap()
            .obligations
            .expect("the claimed intent keeps its set");
        replacement.standing.clear();
        crate::journal::write_progress(
            &path,
            &RecordProgress {
                intent_id: intent.id.clone(),
                phase: None,
                obligations: Some(replacement),
                while_owner: Some(new.clone()),
                notice: None,
            },
            crate::record::Locking::FLOCK,
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
