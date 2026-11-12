//! The lane operation: orch's one opener of the effect engine's handle and
//! the owner of what a lane's close owes beside what the engine holds.
//!
//! The engine's set holds the generic kinds alone (processes, panes,
//! windows, receipts, jobs). A close also owes the worktree's validation
//! runs and the lane's local worktree: those are this module's own set,
//! [`LaneObligations`], private to it, recorded as the intent's
//! `lane_obligations` member and discharged only by this module's own reads
//! and answers. [`LaneOperation`] owns the engine handle by value: an effect
//! file borrows it through [`LaneOperation::engine`] for every generic act
//! and read and can never move it out, so a terminal is reached only
//! through [`LaneOperation::settle`], [`LaneOperation::hold`] or
//! [`LaneOperation::refuse`], and a settlement needs both sets settled. A
//! lane act writes the engine's `signalled` first and discharges its own
//! obligation with that receipt in hand, so the engine's revision and owner
//! checks cover it and no refusal is expressible after it. The lane's wake
//! is the engine's auxiliary process, named from the lane record.
//!
//! The lane intents' recording boundary is here too: a lane outcome is
//! applied with the lane set's remainder beside the engine's and the keys
//! the store's moved-lane judgement takes.

mod worktree;

use std::path::{Path, PathBuf};

use agent_runtime::harness::Harness;
use agent_runtime::reading::Reading;
use serde_json::{Value, json};

use super::operation::{self, Bootstrap, EffectOutcome, Identity, Operation, Signalled, Word};
use super::{Run, lane_for_intent, read_intent};
use crate::error::{Error, Result};
use crate::mailbox::{Mailbox, Refusal};
use crate::ops::{
    self, Applied, CLOUD_KIND, LaneObligation, LaneObligationRecord, RecordLaneProgress, Report,
    Request,
};
use crate::settings::Settings;
use crate::state::{Lane, LaneMembers};
use agent_runtime::intent::Intent;
use agent_runtime::intent::Owner;
use agent_runtime::intent::{EffectOp, PrincipalKeys, Role};
use agent_runtime::journal::{OutcomeWritten, Progress};
use agent_runtime::record::Locking;

pub(super) use worktree::WorktreeRelease;

use lane_obligations::{LaneDischarge, LaneObligations, ValidationEnd, WorktreeEnd};

mod lane_obligations {
    use super::worktree::{KeptReason, WorktreeRelease};
    use crate::ops::{
        LaneDischarged, LaneObligation, LaneObligationRecord, WORKTREE_KEPT, WORKTREE_MAIL_KEPT,
    };

    /// What ended the worktree's validation obligation: the stop's answer
    /// that every run is ended, or the lane moved under the close, so the
    /// worktree's runs belong to the session that now holds the lane.
    pub(super) enum ValidationEnd {
        Stopped,
        LaneMoved,
    }

    /// What ended the lane's worktree obligation, by the release's own
    /// reads: the path read gone before any removal, the removal succeeded
    /// and the path read gone after it, or the worktree kept for a recorded
    /// reason; a path or a read that failed leaves the obligation standing.
    /// Under a lane that moved, the worktree is the new session's, released
    /// to it as the validation stop is.
    pub(super) enum WorktreeEnd {
        Gone,
        Released { kept_mail: Option<String> },
        Kept(KeptReason),
        LaneMoved,
        Unreadable { cause: String },
    }

    impl From<&WorktreeRelease> for WorktreeEnd {
        fn from(release: &WorktreeRelease) -> WorktreeEnd {
            match release {
                WorktreeRelease::Gone => WorktreeEnd::Gone,
                WorktreeRelease::Released { kept_mail } => WorktreeEnd::Released {
                    kept_mail: kept_mail.clone(),
                },
                WorktreeRelease::Kept { reason } => WorktreeEnd::Kept(reason.clone()),
                WorktreeRelease::Held { cause } => WorktreeEnd::Unreadable {
                    cause: cause.clone(),
                },
            }
        }
    }

    /// Evidence that settles one named lane obligation.
    pub(super) enum LaneDischarge {
        Validation(ValidationEnd),
        Worktree { path: String, end: WorktreeEnd },
    }

    impl LaneDischarge {
        fn names(&self) -> LaneObligation {
            match self {
                LaneDischarge::Validation(_) => LaneObligation::Validation,
                LaneDischarge::Worktree { path, .. } => {
                    LaneObligation::Worktree { path: path.clone() }
                }
            }
        }
    }

    /// Every lane obligation discharged: minted by [`LaneObligations::settled`]
    /// alone.
    pub(super) struct LaneSettled(());

    /// The lane set as this operation read it, with the store's revision of
    /// that read, and why each discharge that settled nothing left its
    /// obligation standing on this run.
    pub(super) struct LaneObligations {
        record: LaneObligationRecord,
        held: Vec<String>,
    }

    impl LaneObligations {
        pub(super) fn of(record: LaneObligationRecord) -> LaneObligations {
            LaneObligations {
                record,
                held: Vec::new(),
            }
        }

        /// `obligation` acquired, where the record does not hold it yet,
        /// standing or discharged: whether it was added.
        pub(super) fn add(&mut self, obligation: LaneObligation) -> bool {
            let held = self.record.standing.contains(&obligation)
                || self
                    .record
                    .discharged
                    .iter()
                    .any(|d| d.obligation == obligation);
            if !held {
                self.record.standing.push(obligation);
            }
            !held
        }

        pub(super) fn stands(&self, obligation: &LaneObligation) -> bool {
            self.record.standing.contains(obligation)
        }

        /// The standing worktree path: what a close releases or keeps.
        pub(super) fn worktree(&self) -> Option<String> {
            self.record.standing.iter().find_map(|o| match o {
                LaneObligation::Worktree { path } => Some(path.clone()),
                LaneObligation::Validation => None,
            })
        }

        /// Settle the obligation `evidence` names, where it stands: a read or
        /// an answer that does not settle leaves it standing with the cause.
        /// Whether the set changed.
        pub(super) fn discharge(&mut self, evidence: LaneDischarge) -> bool {
            let named = evidence.names();
            if !self.stands(&named) {
                return false;
            }
            let judged = match evidence {
                LaneDischarge::Validation(ValidationEnd::Stopped) => {
                    Ok("validation-stopped".to_owned())
                }
                LaneDischarge::Validation(ValidationEnd::LaneMoved)
                | LaneDischarge::Worktree {
                    end: WorktreeEnd::LaneMoved,
                    ..
                } => Ok("lane-moved".to_owned()),
                LaneDischarge::Worktree { end, .. } => match end {
                    WorktreeEnd::Gone => Ok("worktree-gone".to_owned()),
                    WorktreeEnd::Released { kept_mail: None } => Ok("released".to_owned()),
                    WorktreeEnd::Released {
                        kept_mail: Some(mail),
                    } => Ok(format!("{WORKTREE_MAIL_KEPT}{mail}")),
                    WorktreeEnd::Kept(reason) => Ok(format!("{WORKTREE_KEPT}{}", reason.word())),
                    WorktreeEnd::LaneMoved => Ok("lane-moved".to_owned()),
                    WorktreeEnd::Unreadable { cause } => {
                        Err(format!("worktree-unreadable:{cause}"))
                    }
                },
            };
            match judged {
                Ok(by) => {
                    self.record.standing.retain(|o| *o != named);
                    self.record.discharged.push(LaneDischarged {
                        obligation: named,
                        by,
                    });
                    true
                }
                Err(cause) => {
                    self.held.push(cause);
                    false
                }
            }
        }

        pub(super) fn settled(&self) -> Option<LaneSettled> {
            self.record.standing.is_empty().then_some(LaneSettled(()))
        }

        /// The first reason a discharge left its obligation standing.
        pub(super) fn cause(&self) -> Option<&str> {
            self.held.first().map(String::as_str)
        }

        pub(super) fn record(&self) -> &LaneObligationRecord {
            &self.record
        }

        pub(super) fn set_revision(&mut self, revision: u64) {
            self.record.revision = revision;
        }
    }
}

/// Open the engine's handle on a launch or a controller operation, with the
/// start each names: a lane launch's phase under the harness role with the
/// harness its selection names, a controller operation's own. A close opens
/// through [`LaneOperation::open_close`].
pub(super) fn open<'a>(run: &'a Run<'a>, intent: &Intent) -> Result<Operation<'a>> {
    let bootstrap = match intent.op {
        EffectOp::LaunchLane => Bootstrap::Phase {
            principal: Role::Harness,
            harness: LaneMembers::of(run.engine.path, intent)?
                .selection
                .and_then(|s| Harness::parse(&s.harness)),
        },
        EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController => {
            let Some(bootstrap) = Bootstrap::controller(intent.op) else {
                unreachable!("a controller operation has its own start")
            };
            bootstrap
        }
        EffectOp::CloseOwnedResources => {
            let (lane, _) = lane_for_intent(run.engine.path, &intent.id)?;
            return Operation::open(&run.engine, intent, close_bootstrap(&lane));
        }
    };
    Operation::open(&run.engine, intent, bootstrap)
}

/// A close's start in the engine's set: the lane's launch record under the
/// harness role with the harness kind the lane runs, and its current wake
/// as the auxiliary process.
fn close_bootstrap(lane: &Lane) -> Bootstrap<'_> {
    Bootstrap::Launch {
        launch: lane.launch.as_ref(),
        harness: lane.harness.as_deref().and_then(Harness::parse),
        auxiliary: ops::wake::wake_identity(lane),
    }
}

/// A lane's close: the engine handle, owned by value, and the lane set.
pub(super) struct LaneOperation<'a> {
    run: &'a Run<'a>,
    engine: Operation<'a>,
    lane: LaneObligations,
    /// The lane's stamp the intent was written at: the keys' stamp for the
    /// moved-lane judgement.
    lane_since: Option<String>,
    /// The owner every lane write is made under, as the engine's are.
    while_owner: Option<Owner>,
}

impl<'a> LaneOperation<'a> {
    /// Open a close on `lane`: the engine's set where the intent records
    /// one, else bootstrapped from the lane's launch record and its wake; the
    /// lane set where the intent records one, else the validation stop a
    /// last outcome recorded `validate: stop-failed` for, written at once.
    pub(super) fn open_close(
        run: &'a Run<'a>,
        intent: &Intent,
        lane: &Lane,
    ) -> Result<LaneOperation<'a>> {
        let engine = Operation::open(&run.engine, intent, close_bootstrap(lane))?;
        let recorded = LaneObligationRecord::of(run.engine.path, intent)?;
        let owed = recorded.is_none()
            && intent.observation.as_ref().is_some_and(|prior| {
                prior.get("validate").and_then(Value::as_str) == Some("stop-failed")
            });
        let mut operation = LaneOperation {
            run,
            engine,
            lane: LaneObligations::of(recorded.unwrap_or_default()),
            lane_since: LaneMembers::of(run.engine.path, intent)?.lane_since,
            while_owner: intent.owner.clone(),
        };
        if owed {
            operation.add(LaneObligation::Validation)?;
        }
        Ok(operation)
    }

    /// The engine, borrowed for its acts and reads.
    pub(super) fn engine(&mut self) -> &mut Operation<'a> {
        &mut self.engine
    }

    /// The engine, read.
    pub(super) fn engine_ref(&self) -> &Operation<'a> {
        &self.engine
    }

    /// Whether `lane` moved under this intent: its stamp is not the
    /// intent's, or its launch names a key the engine's set did not record
    /// under the harness role. The one judgement the store's lane arm
    /// applies too, on the same keys.
    pub(super) fn lane_moved(&self, lane: &Lane) -> bool {
        ops::lane_moved(lane, &self.keys())
    }

    fn keys(&self) -> PrincipalKeys {
        PrincipalKeys {
            since: self.lane_since.clone(),
            keys: self.engine.principal_keys(),
        }
    }

    /// Write the lane set before the act or the wait that follows, under
    /// the owner the intent recorded at open; the revision the store
    /// assigned is mirrored.
    fn write(&mut self) -> Result<()> {
        let applied = apply_lane_store(
            self.run,
            &Request::RecordLaneProgress(Box::new(RecordLaneProgress {
                intent_id: self.engine.intent_id().to_owned(),
                lane_obligations: self.lane.record().clone(),
                while_owner: self.while_owner.clone(),
            })),
        )?;
        let Report::RecordLaneProgress(r) = &applied.report else {
            unreachable!("record-lane-progress returns its own report")
        };
        match &r.progress {
            Progress::Recorded => {
                if let Some(record) = LaneObligationRecord::of(self.run.engine.path, &r.intent)? {
                    self.lane.set_revision(record.revision);
                }
                Ok(())
            }
            Progress::Unchanged => Ok(()),
            Progress::Yielded { owner } => Err(Error::Yielded {
                id: self.engine.intent_id().to_owned(),
                owner: owner.clone(),
            }),
        }
    }

    fn add(&mut self, obligation: LaneObligation) -> Result<()> {
        if self.lane.add(obligation) {
            self.write()?;
        }
        Ok(())
    }

    /// A discharge by a read, with nothing signalled.
    fn discharge_read(&mut self, evidence: LaneDischarge) -> Result<()> {
        if self.lane.discharge(evidence) {
            self.write()?;
        }
        Ok(())
    }

    /// A discharge by the answer of an act made after the engine's
    /// `signalled` write, whose receipt the act holds.
    fn discharge_act(&mut self, evidence: LaneDischarge, _signalled: &Signalled) -> Result<()> {
        self.discharge_read(evidence)
    }

    /// Whether neither set ever acquired anything: nothing stands and
    /// nothing was ever discharged in the engine's set or the lane set. Such
    /// a record, with neither identity nor pane, stays `unconfirmed` and is
    /// closed by hand.
    pub(super) fn recorded_nothing(&self) -> bool {
        let lane = self.lane.record();
        self.engine.recorded_nothing() && lane.standing.is_empty() && lane.discharged.is_empty()
    }

    pub(super) fn owes_validation(&self) -> bool {
        self.lane.stands(&LaneObligation::Validation)
    }

    /// A close about to run owes the worktree's validation runs to their
    /// stop: acquired before the first signal.
    pub(super) fn owe_validation(&mut self) -> Result<()> {
        self.add(LaneObligation::Validation)
    }

    /// A close about to run owes the lane's local worktree, the record's
    /// `mail_root` (a local lane's mail root is its worktree),
    /// to its own release or keep: acquired before the
    /// first signal. A hosted lane's worktree is its host's,
    /// except a `claude-cloud` lane's, whose `mail_root` is the item's
    /// worktree on this machine (the `lanes` row of the schema), the one
    /// worktree the close removes for a hosted lane; a record naming
    /// none owes nothing.
    pub(super) fn owe_worktree(&mut self, lane: &Lane) -> Result<()> {
        if lane.host.is_some() && lane.kind.as_deref() != Some(CLOUD_KIND) {
            return Ok(());
        }
        let Some(root) = lane.mail_root.as_deref() else {
            return Ok(());
        };
        self.add(LaneObligation::Worktree {
            path: root.to_owned(),
        })
    }

    /// Stop the lane's detached wake turn and every other process the
    /// engine's set still holds. The lane's current wake is acquired as the
    /// engine's auxiliary process, written, before its stop; a wake whose pid
    /// a later process holds is a turn already over, read again through the
    /// one identity reader. `Some(cause)` where one outlived its grace or
    /// could not be read: a handle still standing, which the repeated close
    /// stops again.
    pub(super) fn stop_wake(
        &mut self,
        lane: &Lane,
        owns: &dyn Fn(&str) -> bool,
    ) -> Result<Option<String>> {
        let wake = ops::wake::wake_identity(lane);
        if let Some(id) = &wake {
            self.engine.acquire_auxiliary(id.clone())?;
        }
        self.engine.stop_standing_processes(owns, wake.as_ref())
    }

    /// Acquire the lane's current wake as the engine's auxiliary process,
    /// written, and read it through the one identity reader, signalling
    /// nothing: a reconcile's read.
    pub(super) fn read_wake(&mut self, lane: &Lane) -> Result<Option<Reading<Identity>>> {
        let Some(id) = ops::wake::wake_identity(lane) else {
            return Ok(None);
        };
        self.engine.acquire_auxiliary(id.clone())?;
        self.engine.read_process_end(&id).map(Some)
    }

    /// [`pending_ask`] through this run's mailbox CLI.
    pub(super) fn unanswered_ask(
        &self,
        lane: &Lane,
    ) -> std::result::Result<Option<String>, String> {
        pending_ask(&self.run.settings.lane_mail_cli, lane)
    }

    /// End every validation run in a local lane's worktree before the
    /// window closes, by the validation runner's own worktree stop, and
    /// discharge the validation obligation by its answer. A hosted lane's
    /// runs are its host's; a worktree that is gone has none. The inner `Err`
    /// names why the stop did not confirm, the obligation standing.
    pub(super) fn stop_validations(
        &mut self,
        lane: &Lane,
    ) -> Result<std::result::Result<(), String>> {
        // Nothing to stop discharges the obligation with no signal: a hosted
        // lane's runs are its host's, and a worktree with no recorded root
        // or one read gone has none.
        let root = match &lane.host {
            Some(_) => None,
            None => lane.mail_root.as_deref(),
        };
        let Some(root) = root else {
            self.discharge_read(LaneDischarge::Validation(ValidationEnd::Stopped))?;
            return Ok(Ok(()));
        };
        match std::fs::metadata(root) {
            Ok(meta) if meta.is_dir() => {}
            // A worktree gone, or a path that is not a directory, has no runs.
            Ok(_) => {
                self.discharge_read(LaneDischarge::Validation(ValidationEnd::Stopped))?;
                return Ok(Ok(()));
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                self.discharge_read(LaneDischarge::Validation(ValidationEnd::Stopped))?;
                return Ok(Ok(()));
            }
            // A root that cannot be read is no proof of absence: the
            // obligation stands, with the cause, and nothing is signalled.
            Err(e) => return Ok(Err(format!("validation-unreadable:{}", e.kind()))),
        }
        // A real stop is the first signal of the close as often as not:
        // recorded before the stop runs, and the obligation discharged only
        // by the stop's own answer.
        let signalled = self.engine.signal()?;
        // Every unfinished run of the worktree ends, an admitted one through
        // its item's stage: the close keeps no stage's job running.
        let answer = crate::validate::run::stop_worktree(
            self.run.settings,
            Path::new(root),
            None,
            self.run.engine.env,
            self.run.engine.locking,
        )
        .map(|_| ())
        .map_err(|e| format!("{}: {e}", e.key()));
        if answer.is_ok() {
            self.discharge_act(
                LaneDischarge::Validation(ValidationEnd::Stopped),
                &signalled,
            )?;
        }
        Ok(answer)
    }

    /// The worktree's validation runs under a lane that moved belong to the
    /// session that now holds the lane, which owes its own stop: the
    /// obligation is discharged `lane-moved` where it stands;
    /// nothing of this close touches that worktree.
    pub(super) fn release_validation_moved(&mut self) -> Result<()> {
        self.discharge_read(LaneDischarge::Validation(ValidationEnd::LaneMoved))
    }

    /// Release the lane's worktree the set records, or keep it with its
    /// reason, by this operation's own reads: the path gone discharges
    /// `worktree-gone`; a linked worktree (its `.git` a file,
    /// git-worktree(1) § DETAILS) with a dirty tree or commits no other ref
    /// reaches is kept `dirty` or `unmerged`; a clean, merged one is
    /// removed, after the engine's signal is written, by the worktree
    /// package's `remove`, the one owner of what a removal must preserve (it
    /// moves every lane mailbox under the worktree to the main checkout's
    /// `tmp/lane-mail/` before git deletes the tree, and refuses a locked
    /// worktree, an unreconciled rebase map or an unregistered target before
    /// anything is removed), discharged `released` once the path reads gone,
    /// `kept:mail-unmoved` where the package moved no mailbox and removed
    /// nothing, or kept with the package's refusal; a path with no `.git`,
    /// or the main worktree, is kept as such. A path or a read that fails
    /// leaves the obligation standing `worktree-unreadable`: never released,
    /// never kept. Nothing to release where the set records no worktree.
    pub(super) fn release_worktree(&mut self) -> Result<Option<WorktreeRelease>> {
        let Some(path) = self.lane.worktree() else {
            return Ok(None);
        };
        let release = match worktree::plan(&path) {
            worktree::Plan::Answered(release) => {
                self.discharge_read(LaneDischarge::Worktree {
                    path,
                    end: WorktreeEnd::from(&release),
                })?;
                release
            }
            worktree::Plan::Remove { main } => {
                // The removal is an action: recorded before it runs.
                let signalled = self.engine.signal()?;
                let release = worktree::remove(&self.run.settings.worktree_cli, &main, &path);
                self.discharge_act(
                    LaneDischarge::Worktree {
                        path,
                        end: WorktreeEnd::from(&release),
                    },
                    &signalled,
                )?;
                release
            }
        };
        Ok(Some(release))
    }

    /// The worktree under a lane that moved belongs to the session that now
    /// holds the lane: the obligation is discharged `lane-moved` where it
    /// stands, as the validation stop is, and nothing of this close touches
    /// that worktree.
    pub(super) fn release_worktree_moved(&mut self) -> Result<()> {
        if let Some(path) = self.lane.worktree() {
            self.discharge_read(LaneDischarge::Worktree {
                path,
                end: WorktreeEnd::LaneMoved,
            })?;
        }
        Ok(())
    }

    /// The item's files out of the state directory once their archive
    /// stands (`archive::close_out`), the close of an item its tracker
    /// ended, before the provider's close, signalled before it runs: a
    /// removal that fails is the cause, and nothing past it runs.
    pub(super) fn close_out_files(
        &mut self,
        item: &str,
    ) -> Result<std::result::Result<Option<PathBuf>, String>> {
        let _signalled = self.engine.signal()?;
        let settings = self.run.settings;
        Ok(crate::archive::close_out(
            &settings.archive_root,
            &settings.roots.project,
            &settings.state_dir,
            item,
            &[],
            self.run.engine.locking,
            self.run.engine.env.now_secs,
        )
        .map(|closed| closed.archive)
        .map_err(|e| format!("{}: {e}", e.key())))
    }

    /// The provider's close of a hosted lane's sandbox (`lane-host close
    /// --item ITEM [--merged]`), signalled before it runs: what it answered,
    /// or `Err` with the cause of a close that refused at the dispatcher or
    /// gave no answer.
    pub(super) fn host_close(
        &mut self,
        lane: &Lane,
        merged: bool,
    ) -> Result<std::result::Result<crate::watch::hosted::HostClosed, crate::watch::hosted::Asked>>
    {
        let _signalled = self.engine.signal()?;
        let scripts = crate::watch::overseer::scripts_dir(&self.run.settings.roots.project);
        Ok(crate::watch::hosted::close(
            &scripts,
            crate::watch::hosted::host_of(lane),
            &lane.item,
            merged,
        ))
    }

    /// Whether `worktree merged ITEM`, asked from the project checkout,
    /// shows the item's branch merged: `Ok(true)` on 0, `Ok(false)` on 1,
    /// `Err` with the status on any other answer.
    pub(super) fn worktree_merged(&self, item: &str) -> std::result::Result<bool, String> {
        worktree::merged(
            &self.run.settings.worktree_cli,
            &self.run.settings.roots.project,
            item,
        )
    }

    /// The terminal `word` once both sets are settled: the engine's settle
    /// runs only with the lane set's proof in hand, and a lane obligation
    /// standing holds the intent with what stands. The first reason a lane
    /// discharge left its obligation standing is the observation's `cause`
    /// where neither it nor the engine names one.
    pub(super) fn settle(self, word: Word, observation: Value) -> EffectOutcome {
        let LaneOperation { engine, lane, .. } = self;
        let mut outcome = match lane.settled() {
            Some(_settled) => engine.settle(word, observation),
            None => engine.hold(observation),
        };
        note_cause(&mut outcome, lane.cause());
        outcome
    }

    /// Nothing ends here: the intent stays open with what stands in both
    /// sets.
    pub(super) fn hold(self, observation: Value) -> EffectOutcome {
        let LaneOperation { engine, lane, .. } = self;
        let mut outcome = engine.hold(observation);
        note_cause(&mut outcome, lane.cause());
        outcome
    }

    /// A refusal with `cause` where the engine's record says nothing was
    /// signalled, which every lane act writes first, else the same cause
    /// held with everything standing.
    pub(super) fn refuse(self, cause: &str, observation: Value) -> EffectOutcome {
        self.engine.refuse(cause, observation)
    }
}

/// `cause` written as the outcome's `cause` where its observation names
/// none.
fn note_cause(outcome: &mut EffectOutcome, cause: Option<&str>) {
    if let Some(cause) = cause
        && !outcome.notes("cause")
    {
        outcome.annotate("cause", json!(cause));
    }
}

/// The lane intents' recording boundary: the engine's outcome applied with
/// the lane set's standing rows beside the engine's in `remaining` or
/// `untouched`, and the keys the store's moved-lane judgement takes, the
/// lane's stamp the intent was written at with the keys the engine's set
/// recorded under the harness role.
pub(super) fn apply_outcome(run: &Run, outcome: EffectOutcome) -> Result<OutcomeWritten> {
    let intent = read_intent(run.engine.path, outcome.intent_id())?;
    let rows: Vec<Value> = LaneObligationRecord::of(run.engine.path, &intent)?
        .map(|record| record.standing.iter().map(standing_value).collect())
        .unwrap_or_default();
    let keys = PrincipalKeys {
        since: LaneMembers::of(run.engine.path, &intent)?.lane_since,
        keys: outcome.principal_keys().to_vec(),
    };
    operation::apply_outcome_with(&run.engine, outcome, |wire| {
        wire.principal_keys = Some(keys);
        if let Some(observation) = wire.observation.as_mut() {
            for key in ["remaining", "untouched"] {
                if let Some(Value::Array(held)) = observation.get_mut(key) {
                    held.extend(rows.iter().cloned());
                }
            }
        }
    })
}

/// One standing lane obligation as a reconcile's `remaining` carries it.
fn standing_value(obligation: &LaneObligation) -> Value {
    match obligation {
        LaneObligation::Validation => json!({"kind": "validation"}),
        LaneObligation::Worktree { path } => json!({"kind": "worktree", "path": path}),
    }
}

/// Persist the close the dispatcher found over a superseded launch, once the
/// launch intent is closed, judged against the host as the command's entry
/// is. It takes the typed close alone, never a request.
pub(super) fn persist_close(run: &Run, close: &ops::CloseOwnedResources) -> Result<Applied> {
    ops::apply_on(
        run.engine.path,
        &Request::CloseOwnedResources(close.clone()),
        run.engine.env,
        run.engine.locking,
        &ops::Host::kernel(),
    )
}

/// The close verb's transitions, its one close and its park record, applied
/// as the command applies a request: with the kernel's readers.
pub(super) fn apply_request(
    path: &Path,
    request: &Request,
    env: &agent_runtime::journal::Env,
    locking: Locking,
) -> Result<Applied> {
    let host = ops::Host::kernel();
    ops::apply_on(path, request, env, locking, &host)
}

/// The accounts judge over this fleet's charges for one request, read with
/// the kernel's readers (`lanes pick` in process).
pub(super) fn pick_account(
    settings: &Settings,
    path: &Path,
    lane_host: &str,
    request: &agent_runtime::accounts::PickRequest,
    now: u64,
) -> agent_runtime::accounts::PickAnswer {
    let host = ops::Host::kernel();
    ops::accounts::pick_fleet(settings, path, &host, Some(lane_host), None, request, now)
}

/// The lane set's store transition, applied as the engine's progress
/// writes are.
fn apply_lane_store(run: &Run, request: &Request) -> Result<Applied> {
    ops::apply(run.engine.path, request, run.engine.env, run.engine.locking)
}

/// The oldest unanswered ask the lane's mailbox holds, read through the
/// mailbox client (`lane-mail pending --item ITEM --root ROOT [--host]`): the
/// first envelope of kind `ask`. A hosted lane's mailbox is read under its
/// record's host, never the caller's. `Err` is a read that did not answer,
/// or a lane with no recorded root; a host's per-home cap refusal leads
/// with `lane-host-busy`, the word the close refuses by.
pub(super) fn pending_ask(cli: &Path, lane: &Lane) -> std::result::Result<Option<String>, String> {
    let Some(root) = lane.mail_root.as_deref() else {
        return Err("mail-root-unrecorded".to_owned());
    };
    let hosted = lane.host.as_deref().filter(|h| !h.is_empty());
    let envelopes = Mailbox::new(cli.to_path_buf())
        .pending(&lane.item, Path::new(root), hosted)
        .map_err(|refusal| match refusal {
            Refusal::Exit {
                status: Some(crate::watch::hosted::LANE_HOST_BUSY_EXIT),
                ..
            } => format!("lane-host-busy step=mail-read {refusal}"),
            Refusal::NotStarted { .. }
            | Refusal::Unanswered { .. }
            | Refusal::Exit { .. }
            | Refusal::Reply { .. } => refusal.to_string(),
        })?;
    Ok(envelopes
        .iter()
        .find(|e| e.kind() == "ask")
        .map(|e| e.id().to_owned()))
}
