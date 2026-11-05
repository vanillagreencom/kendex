//! The domain operations over the workflow records. Each is one transition
//! performed under the record's lock through the write check: the result a
//! caller gets is derived from the state the write committed, never from a
//! later unlocked read.
//!
//! A transition reads typed views of the document and writes it back as a
//! patch: the keys the writer of the same transition writes, deletes or
//! appends, and nothing else. An operation that starts an external effect
//! persists its intent (operation, target, owner) in the same transition and
//! reports how far the effect got as agent-runtime's `Outcome`. One intent per
//! target may be open: a repeated request of the same operation reconciles it,
//! another operation on the target refuses. A transition never runs the effect
//! itself: it returns the persisted intent as [`Effect::Persisted`], the
//! `effects` module runs the effect against the host and records what it
//! observed through `record-outcome`, and a reconciliation re-observes an open
//! intent the same way.
//!
//! The transitions are grouped by the record they move: `item` (rounds,
//! validation admission, accepted results, verification), `lane` (launch,
//! adoption, close, phases and the lane outcome arms) and `controller`
//! (succession and its outcome arms). This module holds the request and report
//! envelopes, the dispatch, the intent contract every effect operation shares
//! and the `record-outcome` frame that closes an intent.

pub mod accept;
pub mod accounts;
mod admission;
mod controller;
mod item;
mod lane;
pub mod mail;
mod occupancy;
pub mod proof;
pub mod prune;
pub mod queue_watch;
pub mod store;
pub mod successor;
#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows' shared store entry point"
)]
mod testing;
pub mod validate;
pub mod verify_pr;
pub mod verify_review;
pub mod wake;
pub mod walk;
pub mod wall;

pub use accept::{SummaryPost, accept};
pub use admission::{AdmitPaths, Clis, ItemRead, PathsAdmitted, ReadFailure, ScopeRange};
pub(crate) use controller::apply_adoption;
pub use controller::{
    AdoptController, AdoptionRead, ClaimIntent, ControllerAdopted, ControllerStarted,
    IntentClaimed, OverseerExpected, Progress, ProgressRecorded, RecordProgress, RequestTransfer,
    StartController, StopController, StopRequested, TransferRequested, admit, overseer_target,
};
pub use item::{
    AcceptResult, Attempt, BeginRound, EndSource, HandoffRecorded, HandoffResumed, OpenRun,
    ReconcileRound, RecordHandoff, RecordValidationAdmission, RecordVerification, Relaunch,
    ResultAccepted, ResumeHandoff, RoundBegun, RoundKind, RoundReconciled, RunCause, RunReconciled,
    RunState, ValidationAdmitted, Verdict, VerificationRecorded, VerifyHead,
};
// The stop's bounded wait reads the job by the item transitions' one identity
// reader.
pub(crate) use admission::origin_slug;
pub(crate) use item::job_ended;
pub use lane::{
    AdoptSession, CloseOwnedResources, CloseRequested, LaneAdopted, LaneLaunched, LaneParked,
    LaneReleased, LaneReserved, LaunchLane, NoLanding, ParkLane, PhaseRecorded, RecordPhase,
    ReleaseLane, ReserveLane, Terminal, lane_moved,
};
pub(crate) use occupancy::CLOUD_KIND;
pub use occupancy::{Charge, ChargeReason, ChargeSource, Host, Occupancy};
pub use verify_pr::{PrVerified, VerifyPr};
pub use verify_review::{ReviewVerified, VerifyReview};

use std::path::Path;

use agent_runtime::clock;
use agent_runtime::protocol::Outcome;
use lane::IntentTarget;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::state::{
    self, Document, EffectOp, Intent, Kind, Lane, LaneKeys, LaunchIdentity, Locking, Notice, Owner,
    Reconciled, Snapshot,
};

/// The clock and nonce an operation stamps with, supplied by the caller so
/// a transition is a pure function of the record and this value. One call
/// mints one `Env`; the stamp it yields names the round or intent that call
/// creates, so two calls never share one.
#[derive(Debug, Clone)]
pub struct Env {
    pub now_secs: u64,
    pub now_nanos: u128,
    pub nonce: u32,
    /// The identity of the process persisting an intent, read through
    /// agent-runtime's one identity reader. `None` where the caller could not
    /// read it; an operation that persists an intent then refuses
    /// `owner-unreadable`.
    pub owner: Option<Owner>,
}

impl Env {
    /// The round token `begin-round` mints: `<nanoseconds since the
    /// epoch>-<random>`. An intent id ends in the same stamp.
    pub fn round_id(&self) -> String {
        format!("{}-{}", self.now_nanos, self.nonce)
    }

    /// The ISO 8601 UTC stamp every record field carries.
    pub fn iso(&self) -> String {
        clock::iso_utc(self.now_secs)
    }
}

/// Record how an effect ended. On `confirmed` the intent's transition
/// completes: a launched lane runs, a closed lane is done, a succession
/// publishes the pending successor. A confirmed transfer's `launch` is the
/// successor's: its pane on its server is required, since the published
/// record is that session's own.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordOutcome {
    pub intent_id: String,
    pub outcome: Outcome,
    #[serde(default)]
    pub launch: Option<LaunchIdentity>,
    #[serde(default)]
    pub session_id: Option<String>,
    /// The start of the tmux server `launch` names, which a confirmed
    /// transfer records as the successor's `server_start`. `launch.start`
    /// is the harness process start, not this. Left out, the record is
    /// unstarted: the successor's watch start owns and fills it, and
    /// `oversee register` from that pane writes the next generation.
    #[serde(default)]
    pub server_start: Option<u64>,
    /// The socket of the server `launch` names, recorded as the successor's
    /// `server_socket` and on the kept runner, so a later observation reaches
    /// that server by name.
    #[serde(default)]
    pub server_socket: Option<String>,
    /// The record's `window`: `<session>:<title>` on a lane, the tmux window
    /// id on the overseer.
    #[serde(default)]
    pub window: Option<String>,
    /// The tmux session a confirmed lane launch opened in; the fleet records
    /// the first as `tmux.session`, as the first launch does.
    #[serde(default)]
    pub tmux_session: Option<String>,
    /// The line a confirmed successor ran, written over the pending one.
    #[serde(default)]
    pub launch_line: Option<String>,
    /// The home a confirmed successor or local lane runs its sessions under,
    /// as its launch prepared it: written over the pending's, or as the
    /// lane's `home`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// That launch named no home, written as the lane's `home_implicit`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home_implicit: bool,
    /// The fleet watch a confirmed start launched or found claimed, written as
    /// the record's `overseer.watch`; a succession carries none and keeps the
    /// field as it stands.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watch: Option<crate::state::WatchJob>,
    /// The root a confirmed lane's files are read under, where its host
    /// named one: a hosted lane's worktree on its host, a cloud lane's
    /// worktree the launch made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mail_root: Option<String>,
    /// What the effect observed, kept on the intent for a reconciliation.
    #[serde(default)]
    pub observation: Option<Value>,
    /// The owner the launcher-side handle closes under: the outcome is a no-op
    /// once another owner holds the intent, so a job that claimed keeps its
    /// own record; the transition is retried on a conflicting snapshot and
    /// answers the claimant's state. `None` records always.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub while_owner: Option<Owner>,
    /// The lane keys a lane intent's terminal carries: the lane arms move the
    /// lane only while its launch names nothing but these and its stamp is the
    /// intent's; otherwise the intent closes `intent-stale` and the lane is
    /// left as found. An outcome without them is judged by the intent's own
    /// recorded set, else by its stamp alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane_keys: Option<LaneKeys>,
    /// The announcement a failed or unconfirmed outcome of a transfer or a
    /// stop owes: recorded `owed` with the outcome, its fleet-log row appended
    /// in the same write, where the intent carries none yet; the send is the
    /// continuation the recording boundary runs after the write. Ignored on
    /// every other operation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<Notice>,
    /// The obligation set's revision as the writer read it: the store refuses
    /// the outcome where the record's set holds another, so a terminal never
    /// closes over a set another handle replaced. `None` compares nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub set_revision: Option<u64>,
}

/// One operation request, tagged by `op`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Request {
    LaunchLane(Box<LaunchLane>),
    AdoptSession(Box<AdoptSession>),
    BeginRound(BeginRound),
    RecordValidationAdmission(RecordValidationAdmission),
    RequestTransfer(Box<RequestTransfer>),
    StartController(Box<StartController>),
    /// Read the pane's foreground identity, then record; the `effects`
    /// module runs it, since the read comes before the one transition it
    /// makes.
    AdoptController(Box<AdoptController>),
    StopController(StopController),
    /// Take an open intent's owner lease: the detached job's first act.
    ClaimIntent(ClaimIntent),
    AcceptResult(AcceptResult),
    RecordVerification(RecordVerification),
    /// Read GitHub for a pinned head, then record; the `verify` module runs
    /// it, since the reads come before the one transition it makes.
    VerifyHead(VerifyHead),
    /// Read a pull request's current head, then verify it as `verify-head`
    /// does; `ops::verify_pr` runs it, since the reads come before the one
    /// transition it makes.
    VerifyPr(VerifyPr),
    /// Read a pull request's review state, make the one request its
    /// head owes, then record; `ops::verify_review` runs it, since the
    /// reads and the request come before its writes.
    VerifyReview(VerifyReview),
    ReconcileRound(ReconcileRound),
    RecordHandoff(Box<RecordHandoff>),
    ResumeHandoff(ResumeHandoff),
    CloseOwnedResources(CloseOwnedResources),
    ParkLane(ParkLane),
    ReserveLane(ReserveLane),
    ReleaseLane(ReleaseLane),
    RecordOutcome(Box<RecordOutcome>),
    RecordPhase(RecordPhase),
    /// An effect's phase and obligation set, written before the wait that
    /// follows.
    RecordProgress(Box<RecordProgress>),
    /// A directive's send receipt onto the lane.
    RecordDirectiveSend(mail::RecordDirectiveSend),
    /// The lanes' walls as the observation duty read them this pass.
    RecordWallPauses(wall::RecordWallPauses),
    /// The admission judgement of a candidate's paths against the fleet's
    /// holders, under the launch lock.
    AdmitPaths(Box<AdmitPaths>),
    /// The retention duty's judged records leaving the fleet state.
    PruneRecords(prune::PruneRecords),
    /// The validation run's steps, tagged by `step`.
    Validate(validate::Validate),
    /// The queue wait's memory, replaced whole on the item before its next
    /// poll.
    RecordQueueWatch(queue_watch::RecordQueueWatch),
}

impl Request {
    pub fn name(&self) -> &'static str {
        match self {
            Request::LaunchLane(_) => "launch-lane",
            Request::AdoptSession(_) => "adopt-session",
            Request::ParkLane(_) => "park-lane",
            Request::ReserveLane(_) => "reserve-lane",
            Request::ReleaseLane(_) => "release-lane",
            Request::BeginRound(_) => "begin-round",
            Request::RecordValidationAdmission(_) => "record-validation-admission",
            Request::RequestTransfer(_) => "request-transfer",
            Request::StartController(_) => "start-controller",
            Request::AdoptController(_) => "adopt-controller",
            Request::StopController(_) => "stop-controller",
            Request::ClaimIntent(_) => "claim-intent",
            Request::AcceptResult(_) => "accept-result",
            Request::RecordVerification(_) => "record-verification",
            Request::VerifyHead(_) => "verify-head",
            Request::VerifyPr(_) => "verify-pr",
            Request::VerifyReview(_) => "verify-review",
            Request::ReconcileRound(_) => "reconcile-round",
            Request::RecordHandoff(_) => "record-handoff",
            Request::ResumeHandoff(_) => "resume-handoff",
            Request::CloseOwnedResources(_) => "close-owned-resources",
            Request::RecordOutcome(_) => "record-outcome",
            Request::RecordPhase(_) => "record-phase",
            Request::RecordProgress(_) => "record-progress",
            Request::RecordDirectiveSend(_) => "record-directive-send",
            Request::RecordWallPauses(_) => "record-wall-pauses",
            Request::AdmitPaths(_) => "admit-paths",
            Request::PruneRecords(_) => "prune-records",
            Request::Validate(_) => "validate",
            Request::RecordQueueWatch(_) => "record-queue-watch",
        }
    }

    /// The state file the operation transitions.
    pub fn kind(&self) -> Kind {
        match self {
            Request::BeginRound(_)
            | Request::RecordValidationAdmission(_)
            | Request::AcceptResult(_)
            | Request::RecordVerification(_)
            | Request::VerifyHead(_)
            | Request::VerifyPr(_)
            | Request::VerifyReview(_)
            | Request::ReconcileRound(_)
            | Request::RecordHandoff(_)
            | Request::ResumeHandoff(_)
            | Request::Validate(_)
            | Request::RecordQueueWatch(_) => Kind::Item,
            Request::LaunchLane(_)
            | Request::AdoptSession(_)
            | Request::RequestTransfer(_)
            | Request::StartController(_)
            | Request::AdoptController(_)
            | Request::StopController(_)
            | Request::ClaimIntent(_)
            | Request::CloseOwnedResources(_)
            | Request::ParkLane(_)
            | Request::ReserveLane(_)
            | Request::ReleaseLane(_)
            | Request::RecordOutcome(_)
            | Request::RecordPhase(_)
            | Request::RecordProgress(_)
            | Request::RecordDirectiveSend(_)
            | Request::RecordWallPauses(_)
            | Request::AdmitPaths(_)
            | Request::PruneRecords(_) => Kind::Fleet,
        }
    }
}

/// How far the external effect of an operation got in this call.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "kebab-case")]
pub enum Effect {
    /// An intent for the target already stood unfinished; nothing new was
    /// created and the record did not move. The caller reconciles it.
    Reconciled { intent: Intent },
    /// The intent is persisted and has not started; the caller runs the
    /// effect and records its outcome.
    Persisted { intent: Intent },
    /// A launch intent for the target stands open; nothing was created. The
    /// caller reconciles it and, when it stays unconfirmed with a recorded
    /// pane, closes it `superseded-by-close` and asks again, so the close
    /// stops what the pane holds.
    Supersedes { intent: Intent },
}

/// An outcome written onto its intent and the record it moved.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OutcomeRecorded {
    pub intent: Intent,
    /// False when the same outcome was already recorded.
    pub recorded_now: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane: Option<Box<Lane>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation: Option<u64>,
    /// Set when the outcome closed the intent without moving its target,
    /// because the target's record had moved under it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reconciled: Option<Reconciled>,
}

/// The typed result of one committed transition, tagged like its request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Report {
    LaunchLane(Box<LaneLaunched>),
    AdoptSession(Box<LaneAdopted>),
    BeginRound(RoundBegun),
    RecordValidationAdmission(ValidationAdmitted),
    RequestTransfer(Box<TransferRequested>),
    StartController(Box<ControllerStarted>),
    AdoptController(Box<ControllerAdopted>),
    StopController(Box<StopRequested>),
    ClaimIntent(Box<IntentClaimed>),
    AcceptResult(ResultAccepted),
    RecordVerification(VerificationRecorded),
    ReconcileRound(RoundReconciled),
    RecordHandoff(HandoffRecorded),
    ResumeHandoff(HandoffResumed),
    CloseOwnedResources(Box<CloseRequested>),
    ParkLane(Box<LaneParked>),
    ReserveLane(Box<LaneReserved>),
    ReleaseLane(Box<LaneReleased>),
    RecordOutcome(Box<OutcomeRecorded>),
    RecordPhase(Box<PhaseRecorded>),
    RecordProgress(Box<ProgressRecorded>),
    RecordDirectiveSend(mail::DirectiveSendRecorded),
    RecordWallPauses(wall::WallPausesRecorded),
    AdmitPaths(Box<PathsAdmitted>),
    PruneRecords(prune::RecordsPruned),
    /// The validation run's step reports, tagged by `step`.
    Validate(Box<validate::Validated>),
    RecordQueueWatch(queue_watch::QueueWatchRecorded),
}

/// What `apply` returns: the report of the transition the write committed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Applied {
    pub kind: Kind,
    pub report: Report,
}

/// Apply one request to the state file at `path`: read, transition the
/// document, write through the write check, report. A refused write reports
/// nothing. A request that judges live processes beside the record (a lane
/// launch, adoption or close) needs the host's facts and goes through
/// [`apply_on`]; here it refuses `op-not-transition`.
pub fn apply(path: &Path, request: &Request, env: &Env, locking: Locking) -> Result<Applied> {
    apply_host(path, request, env, locking, None)
}

/// [`apply`] with the host facts a fleet transition judges live processes
/// against: the lane cap, the claim store and the identity reads. The reads
/// happen between the snapshot and the write, and the write check refuses a
/// record another writer moved meanwhile, so the count and the row it admits
/// commit together or not at all.
pub fn apply_on(
    path: &Path,
    request: &Request,
    env: &Env,
    locking: Locking,
    host: &Host,
) -> Result<Applied> {
    apply_host(path, request, env, locking, Some(host))
}

fn apply_host(
    path: &Path,
    request: &Request,
    env: &Env,
    locking: Locking,
    host: Option<&Host>,
) -> Result<Applied> {
    apply_interleaved(path, request, env, locking, host, &|| {})
}

/// How many fresh reads a re-applied write takes before a record that keeps
/// moving under it is reported as `record-changed`.
const REREADS: u32 = 8;

/// Run `attempt` again while its store refuses `record-changed`, up to
/// [`REREADS`] times. Each attempt reads the record afresh and re-applies its
/// transition, so a write another writer committed between the read and the
/// store is kept, never overwritten.
pub(crate) fn reread<R>(attempt: impl Fn() -> Result<R>) -> Result<R> {
    let mut attempts = 0;
    loop {
        match attempt() {
            Err(e) if attempts < REREADS && e.key() == "record-changed" => attempts += 1,
            settled => return settled,
        }
    }
}

/// Whether a store of `request` that refuses `record-changed` is read again
/// and re-applied: the launcher-side progress and outcome writes, which write
/// only while their owner still holds the intent, and the job's claim, whose
/// first store can meet the launcher's sidecar write that lands the instant
/// the job starts.
fn reread_on_record_changed(request: &Request) -> bool {
    match request {
        Request::RecordProgress(r) => r.while_owner.is_some(),
        Request::RecordOutcome(r) => r.while_owner.is_some(),
        Request::ClaimIntent(_) => true,
        Request::LaunchLane(_)
        | Request::AdoptSession(_)
        | Request::BeginRound(_)
        | Request::RecordValidationAdmission(_)
        | Request::RequestTransfer(_)
        | Request::StartController(_)
        | Request::AdoptController(_)
        | Request::StopController(_)
        | Request::AcceptResult(_)
        | Request::RecordVerification(_)
        | Request::VerifyHead(_)
        | Request::VerifyPr(_)
        | Request::VerifyReview(_)
        | Request::ReconcileRound(_)
        | Request::RecordHandoff(_)
        | Request::ResumeHandoff(_)
        | Request::CloseOwnedResources(_)
        | Request::ParkLane(_)
        | Request::ReserveLane(_)
        | Request::ReleaseLane(_)
        | Request::RecordPhase(_)
        | Request::RecordDirectiveSend(_)
        | Request::RecordWallPauses(_)
        | Request::AdmitPaths(_)
        | Request::PruneRecords(_)
        | Request::Validate(_)
        | Request::RecordQueueWatch(_) => false,
    }
}

/// [`apply_host`] with `between` run after the transition and before the
/// store on each attempt: the seam a test uses to land another writer's
/// commit in the gap. Production passes a no-op.
#[allow(
    clippy::disallowed_methods,
    reason = "the one store write of every request: the transition's document committed through the state module's write check"
)]
fn apply_interleaved(
    path: &Path,
    request: &Request,
    env: &Env,
    locking: Locking,
    host: Option<&Host>,
    between: &dyn Fn(),
) -> Result<Applied> {
    let kind = target_kind(path, request)?;
    let transition = || -> Result<Applied> {
        let snapshot = loaded(path)?;
        let mut doc = snapshot.doc.clone();
        let report = match kind {
            Kind::Item => item_transition(path, &mut doc, request, env)?,
            Kind::Fleet => fleet_transition(path, &mut doc, request, env, host)?,
        };
        between();
        state::store(path, &snapshot, &doc, locking)?;
        Ok(Applied { kind, report })
    };
    if reread_on_record_changed(request) {
        // The owner the transition compared is the one the store commits
        // against: a snapshot another writer moved between the read and the
        // store is read again, so a claim that landed in the gap is answered
        // with the claimant's state, never `record-changed`. The ordinary
        // stale-write refusal stays for a record that keeps moving.
        return reread(transition);
    }
    if matches!(request, Request::LaunchLane(_) | Request::AdmitPaths(_)) {
        // A lane admission, and the path admission that judges against the
        // same holders, run under the fleet launch lock (`flock` on
        // `<fleet>.launch.lock`) from before the snapshot read through the
        // committed row, so two contenders on one path are judged one after
        // the other; the state file's own lock is taken inside, by the write.
        return state::locked(&occupancy::launch_lock_base(path), locking, transition);
    }
    transition()
}

/// The precondition every operation shares: the state file at `path` is
/// the kind the request acts on, returned for the transition. It reads
/// nothing, so a caller that reads an external system before its
/// transition runs it first.
pub fn target_kind(path: &Path, request: &Request) -> Result<Kind> {
    let kind = Kind::of_path(path);
    let wanted = request.kind();
    if kind != wanted {
        return Err(Error::OpKind {
            op: request.name(),
            path: path.to_path_buf(),
            kind,
            wanted,
        });
    }
    Ok(kind)
}

/// The snapshot a transition reads: the one read of the state module's
/// reader for every request, which the compiler boundary names.
#[allow(
    clippy::disallowed_methods,
    reason = "the transitions' one read of a state file, whose snapshot the write check commits against"
)]
pub(crate) fn loaded(path: &Path) -> Result<Snapshot> {
    state::load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })
}

fn kind_error(request: &Request, path: &Path, wanted: Kind) -> Error {
    Error::OpKind {
        op: request.name(),
        path: path.to_path_buf(),
        kind: request.kind(),
        wanted,
    }
}

/// The item transitions on the document. A fleet request here is the
/// invariant `apply` checks, violated; it is returned, not assumed away.
pub fn item_transition(
    path: &Path,
    doc: &mut Document,
    request: &Request,
    env: &Env,
) -> Result<Report> {
    match request {
        Request::BeginRound(r) => Ok(Report::BeginRound(item::begin_round(path, doc, r, env)?)),
        Request::RecordValidationAdmission(r) => Ok(Report::RecordValidationAdmission(
            item::record_validation_admission(path, doc, r, env)?,
        )),
        Request::AcceptResult(r) => Ok(Report::AcceptResult(item::accept_result(
            path, doc, r, env,
        )?)),
        Request::RecordVerification(r) => Ok(Report::RecordVerification(
            item::record_verification(path, doc, r, env)?,
        )),
        Request::RecordHandoff(r) => Ok(Report::RecordHandoff(item::record_handoff(
            path, doc, r, env,
        )?)),
        Request::ResumeHandoff(r) => Ok(Report::ResumeHandoff(item::resume_handoff(
            path, doc, r, env,
        )?)),
        Request::ReconcileRound(r) => Ok(Report::ReconcileRound(item::reconcile_round(
            path, doc, r, env,
        )?)),
        Request::Validate(r) => Ok(Report::Validate(Box::new(validate::apply(
            path, doc, r, env,
        )?))),
        Request::RecordQueueWatch(r) => Ok(Report::RecordQueueWatch(queue_watch::record(doc, r)?)),
        Request::VerifyHead(_) | Request::VerifyPr(_) | Request::VerifyReview(_) => {
            Err(Error::OpNotTransition { op: request.name() })
        }
        Request::LaunchLane(_)
        | Request::AdoptSession(_)
        | Request::RequestTransfer(_)
        | Request::StartController(_)
        | Request::AdoptController(_)
        | Request::StopController(_)
        | Request::ClaimIntent(_)
        | Request::CloseOwnedResources(_)
        | Request::ParkLane(_)
        | Request::ReserveLane(_)
        | Request::ReleaseLane(_)
        | Request::RecordOutcome(_)
        | Request::RecordPhase(_)
        | Request::RecordProgress(_)
        | Request::RecordDirectiveSend(_)
        | Request::RecordWallPauses(_)
        | Request::AdmitPaths(_)
        | Request::PruneRecords(_) => Err(kind_error(request, path, Kind::Item)),
    }
}

/// The fleet transitions on the document. `host` is what a transition that
/// judges live processes reads beside the record; one asked for without it
/// refuses `op-not-transition`, since it reads before it writes.
pub fn fleet_transition(
    path: &Path,
    doc: &mut Document,
    request: &Request,
    env: &Env,
    host: Option<&Host>,
) -> Result<Report> {
    let host = || host.ok_or(Error::OpNotTransition { op: request.name() });
    match request {
        Request::LaunchLane(r) => Ok(Report::LaunchLane(Box::new(lane::launch_lane(
            path,
            doc,
            r,
            env,
            host()?,
        )?))),
        Request::AdoptSession(r) => Ok(Report::AdoptSession(Box::new(lane::adopt_session(
            path,
            doc,
            r,
            env,
            host()?,
        )?))),
        Request::ParkLane(r) => Ok(Report::ParkLane(Box::new(lane::park_lane(
            path, doc, r, env,
        )?))),
        Request::ReserveLane(r) => Ok(Report::ReserveLane(Box::new(lane::reserve_lane(
            path, doc, r, env,
        )?))),
        Request::ReleaseLane(r) => Ok(Report::ReleaseLane(Box::new(lane::release_lane(
            path, doc, r,
        )?))),
        Request::RequestTransfer(r) => Ok(Report::RequestTransfer(Box::new(
            controller::request_transfer(path, doc, r, env)?,
        ))),
        Request::StartController(r) => Ok(Report::StartController(Box::new(
            controller::start_controller(path, doc, r, env)?,
        ))),
        Request::StopController(r) => Ok(Report::StopController(Box::new(
            controller::stop_controller(path, doc, r, env)?,
        ))),
        Request::ClaimIntent(r) => Ok(Report::ClaimIntent(Box::new(controller::claim_intent(
            path, doc, r, env,
        )?))),
        Request::AdoptController(_) => Err(Error::OpNotTransition { op: request.name() }),
        Request::CloseOwnedResources(r) => Ok(Report::CloseOwnedResources(Box::new(
            lane::close_owned_resources(path, doc, r, env, host()?)?,
        ))),
        Request::RecordOutcome(r) => Ok(Report::RecordOutcome(Box::new(record_outcome(
            path, doc, r, env,
        )?))),
        Request::RecordPhase(r) => Ok(Report::RecordPhase(Box::new(lane::record_phase(
            path, doc, r,
        )?))),
        Request::RecordProgress(r) => Ok(Report::RecordProgress(Box::new(
            controller::record_progress(path, doc, r)?,
        ))),
        Request::RecordDirectiveSend(r) => Ok(Report::RecordDirectiveSend(
            mail::record_directive_send(path, doc, r, env)?,
        )),
        Request::RecordWallPauses(r) => Ok(Report::RecordWallPauses(wall::record_wall_pauses(
            path, doc, r, env,
        )?)),
        Request::AdmitPaths(r) => Ok(Report::AdmitPaths(Box::new(admission::admit_paths(
            path,
            doc,
            r,
            env,
            host()?,
        )?))),
        Request::PruneRecords(r) => Ok(Report::PruneRecords(prune::prune_records(
            path, doc, r, env,
        )?)),
        Request::BeginRound(_)
        | Request::RecordValidationAdmission(_)
        | Request::AcceptResult(_)
        | Request::RecordVerification(_)
        | Request::VerifyHead(_)
        | Request::VerifyPr(_)
        | Request::VerifyReview(_)
        | Request::ReconcileRound(_)
        | Request::RecordHandoff(_)
        | Request::ResumeHandoff(_)
        | Request::Validate(_)
        | Request::RecordQueueWatch(_) => Err(kind_error(request, path, Kind::Fleet)),
    }
}

fn lanes(path: &Path, doc: &Document) -> Result<Vec<Lane>> {
    Ok(state::field(path, doc, "lanes")?.unwrap_or_default())
}

fn intents(path: &Path, doc: &Document) -> Result<Vec<Intent>> {
    Ok(state::field(path, doc, "intents")?.unwrap_or_default())
}

fn lane_at(path: &Path, doc: &Document, index: usize) -> Result<Lane> {
    let lanes = lanes(path, doc)?;
    lanes.into_iter().nth(index).ok_or_else(|| Error::Shape {
        path: path.to_path_buf(),
        field: format!("lanes/{index}"),
        reason: crate::error::ShapeReason::NotObject,
        cause: "absent".to_owned(),
    })
}

fn lane_doc_mut<'a>(path: &Path, doc: &'a mut Document, index: usize) -> Result<&'a mut Document> {
    let rows = state::array_mut(path, doc, "lanes")?;
    state::element_mut(path, rows, index, "lanes")
}

/// What stands open on a target when an operation arrives.
enum Standing {
    /// No open intent: the operation persists its own.
    Clear,
    /// The same operation's intent: the caller reconciles it.
    Same(Intent),
    /// A launch intent a close may supersede once its reconcile reads it still
    /// unconfirmed with a recorded pane.
    Supersedable(Intent),
}

/// The standing open intent on `target` against the operation `op` asks for.
/// Every pair of operations refuses `intent-open`, except a close over an open
/// launch, which supersedes it: a hung launch would otherwise have neither a
/// close nor a relaunch.
fn open_intent(intents: &[Intent], op: EffectOp, target: &str) -> Result<Standing> {
    let Some(intent) = intents.iter().find(|i| i.target == target && i.open()) else {
        return Ok(Standing::Clear);
    };
    match (intent.op, op) {
        (EffectOp::LaunchLane, EffectOp::LaunchLane)
        | (EffectOp::CloseOwnedResources, EffectOp::CloseOwnedResources)
        | (EffectOp::RequestTransfer, EffectOp::RequestTransfer)
        | (EffectOp::StartController, EffectOp::StartController)
        | (EffectOp::StopController, EffectOp::StopController) => {
            Ok(Standing::Same(intent.clone()))
        }
        (EffectOp::LaunchLane, EffectOp::CloseOwnedResources) => {
            Ok(Standing::Supersedable(intent.clone()))
        }
        // Every other pair, the three controller operations on one
        // overseer among them: one controller operation at a time.
        (EffectOp::CloseOwnedResources, EffectOp::LaunchLane)
        | (
            EffectOp::LaunchLane | EffectOp::CloseOwnedResources,
            EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController,
        )
        | (EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController, _) => {
            Err(Error::IntentOpen {
                intent: intent.id.clone(),
                op: intent.op,
                target: target.to_owned(),
            })
        }
    }
}

/// The same operation's open intent on `target`, to reconcile; any other
/// operation's refuses.
fn same_open_intent(intents: &[Intent], op: EffectOp, target: &str) -> Result<Option<Intent>> {
    match open_intent(intents, op, target)? {
        Standing::Clear => Ok(None),
        Standing::Same(intent) => Ok(Some(intent)),
        Standing::Supersedable(intent) => Err(Error::IntentOpen {
            intent: intent.id.clone(),
            op: intent.op,
            target: target.to_owned(),
        }),
    }
}

/// Any open intent on `target` refuses an operation that has no intent of
/// its own.
fn no_open_intent(intents: &[Intent], target: &str) -> Result<()> {
    match intents.iter().find(|i| i.target == target && i.open()) {
        Some(intent) => Err(Error::IntentOpen {
            intent: intent.id.clone(),
            op: intent.op,
            target: target.to_owned(),
        }),
        None => Ok(()),
    }
}

/// Append `intent`, refusing `intent-duplicate` when a row already carries
/// its id: the id ends in the call's own stamp, so a match is a replayed
/// `Env`, never a second effect.
fn push_intent(path: &Path, doc: &mut Document, intent: &Intent) -> Result<()> {
    let value = serde_json::to_value(intent)?;
    let rows = state::array_mut(path, doc, "intents")?;
    if rows
        .iter()
        .any(|row| row.get("id").and_then(Value::as_str) == Some(intent.id.as_str()))
    {
        return Err(Error::IntentDuplicate {
            id: intent.id.clone(),
        });
    }
    rows.push(value);
    Ok(())
}

/// The intent an effect operation persists. It carries the identity of the
/// process persisting it, and is never persisted without one: a contender
/// could not tell a live operation with no owner from a dead one, and would
/// fail it out from under the live effect. A stored intent may still lack
/// it, and is judged as one with no owner.
fn new_intent(op: EffectOp, target: &str, env: &Env) -> Result<Intent> {
    let Some(owner) = env.owner.clone() else {
        return Err(Error::OwnerUnreadable { op: op.word() });
    };
    Ok(Intent {
        id: format!("{}:{target}:{}", op.word(), env.round_id()),
        op,
        target: target.to_owned(),
        created_at: env.iso(),
        owner: Some(owner),
        outcome: Outcome::NotStarted,
        completed_at: None,
        lane_since: None,
        selection: None,
        original_pending: None,
        cause: None,
        handed_from: None,
        exclude_account: None,
        watch: None,
        close: None,
        phase: None,
        obligations: None,
        observation: None,
        reconciled: None,
        observed_status: None,
        observed_generation: None,
        notice: None,
    })
}

fn string_or_null(value: &Option<String>) -> Value {
    match value {
        Some(s) => Value::from(s.as_str()),
        None => Value::Null,
    }
}

/// Null `key` where `doc` holds it; an absent optional field gains no null.
fn null_held(doc: &mut Document, key: &str) {
    if doc.contains_key(key) {
        state::set(doc, key, Value::Null);
    }
}

/// Close an intent with how its effect ended and move the record the
/// intent's operation transitions: the lane arms are `lane`'s, the
/// succession arms `controller`'s. A target whose record moved under the
/// intent (a lane whose stamp or launch keys are not the intent's, closed or
/// removed since; an overseer whose generation moved past the one the intent
/// names) closes the intent `intent-stale` and moves nothing, whatever the
/// outcome reports.
fn record_outcome(
    path: &Path,
    doc: &mut Document,
    r: &RecordOutcome,
    env: &Env,
) -> Result<OutcomeRecorded> {
    if r.outcome == Outcome::NotStarted {
        return Err(Error::OutcomeInvalid { outcome: r.outcome });
    }
    let at = env.iso();
    let intents = intents(path, doc)?;
    let index = intents
        .iter()
        .position(|i| i.id == r.intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: r.intent_id.clone(),
        })?;
    let mut intent = intents[index].clone();
    // The launcher-side handle closes only while it still owns the intent: a
    // job that claimed between the launcher's last read and this write keeps
    // its own record; `apply` retries this transition on a conflicting
    // snapshot, so the owner read here is the one the write commits against.
    if r.while_owner.is_some() && intent.owner != r.while_owner {
        return Ok(OutcomeRecorded {
            intent,
            recorded_now: false,
            lane: None,
            generation: None,
            reconciled: None,
        });
    }
    if !intent.open() {
        if intent.outcome == r.outcome {
            return Ok(OutcomeRecorded {
                intent,
                recorded_now: false,
                lane: None,
                generation: None,
                reconciled: None,
            });
        }
        return Err(Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        });
    }
    // The set as the writer read it: a terminal over a set another handle
    // replaced since is refused, the same answer a progress write on that set
    // gets.
    if let Some(read) = r.set_revision {
        let found = intent.obligations.as_ref().map_or(0, |o| o.revision);
        if read != found {
            return Err(Error::SetReplaced {
                id: intent.id.clone(),
                expected: read,
                found,
            });
        }
    }
    // The document as read, kept to compare the patched one against: an
    // outcome that changes nothing, a reconcile reading what the last one
    // read, must not move the file.
    let before = doc.clone();
    let mut recorded = OutcomeRecorded {
        intent: intent.clone(),
        recorded_now: true,
        lane: None,
        generation: None,
        reconciled: None,
    };
    // A reconcile that found the owner still live, or could not read it, wrote
    // this outcome to record only its observation and defer to the owner: it
    // moves no record and marks no staleness, whatever the target now reads.
    let owner_live = matches!(
        r.observation
            .as_ref()
            .and_then(|o| o.get("note"))
            .and_then(Value::as_str),
        Some(state::OWNER_LIVE | state::OWNER_UNREAD)
    );
    // A target that moved under the intent closes it only on a terminal word:
    // an `unconfirmed` outcome keeps the intent open, with the generation or
    // status it observed noted, so the handles its set still holds have a
    // reader on the next reconcile; its receipt and job files stay with it.
    let terminal = matches!(r.outcome, Outcome::Confirmed | Outcome::Failed);
    let stale = if owner_live {
        None
    } else {
        match intent.op {
            EffectOp::LaunchLane => {
                match lane::intent_lane(path, doc, &intent, r.lane_keys.as_ref())? {
                    IntentTarget::Current { index } => {
                        lane::record_launch_outcome(
                            path,
                            doc,
                            &intent,
                            r,
                            &at,
                            index,
                            &mut recorded,
                        )?;
                        None
                    }
                    IntentTarget::Moved { observed } => {
                        intent.observed_status = observed;
                        terminal.then_some(Reconciled::IntentStale)
                    }
                }
            }
            EffectOp::CloseOwnedResources => {
                match lane::intent_lane(path, doc, &intent, r.lane_keys.as_ref())? {
                    IntentTarget::Current { index } => {
                        lane::record_close_outcome(
                            path,
                            doc,
                            &intent,
                            r,
                            &at,
                            index,
                            &mut recorded,
                        )?;
                        None
                    }
                    IntentTarget::Moved { observed } => {
                        intent.observed_status = observed;
                        terminal.then_some(Reconciled::IntentStale)
                    }
                }
            }
            EffectOp::RequestTransfer | EffectOp::StartController | EffectOp::StopController => {
                let generation = controller::overseer(path, doc)?.generation.unwrap_or(0);
                if controller::target_generation(&intent.target) == Some(generation) {
                    controller::record_controller_outcome(
                        path,
                        doc,
                        &intent,
                        r,
                        &at,
                        &mut recorded,
                    )?;
                    None
                } else {
                    intent.observed_generation = Some(generation);
                    terminal.then_some(Reconciled::IntentStale)
                }
            }
        }
    };
    intent.outcome = r.outcome;
    intent.reconciled = stale;
    if let Some(observation) = &r.observation {
        intent.observation = Some(observation.clone());
    }
    if !intent.open() {
        intent.completed_at = Some(at.clone());
    }
    // The one failure announcement of a job's intent, recorded with the
    // outcome that owes it: a fleet-log row under the job's kind and item, and
    // the notice `owed` on the intent, so the send that follows has a record
    // to continue from and a repeated outcome owes nothing again. A start held
    // on its watch takes the same; a lane's intent takes no row.
    if let Some(notice) = &r.notice
        && intent.notice.is_none()
        && matches!(
            intent.op,
            EffectOp::RequestTransfer | EffectOp::StopController | EffectOp::StartController
        )
    {
        state::array_mut(path, doc, "fleet_log")?.push(serde_json::json!({
            "at": at,
            "kind": "close",
            "item": "overseer",
            "text": notice.text,
        }));
        intent.notice = Some(Notice {
            key: notice.key.clone(),
            text: notice.text.clone(),
            to: notice.to.clone(),
            owner: state::NOTICE_OWED.to_owned(),
        });
    }
    let rows = state::array_mut(path, doc, "intents")?;
    let row = state::element_mut(path, rows, index, "intents")?;
    state::set(row, "outcome", serde_json::to_value(r.outcome)?);
    if let Some(notice) = &intent.notice
        && r.notice.is_some()
    {
        state::set(row, "notice", serde_json::to_value(notice)?);
    }
    if let Some(completed_at) = &intent.completed_at {
        state::set(row, "completed_at", completed_at.as_str());
    }
    if let Some(observation) = &r.observation {
        state::set(row, "observation", observation.clone());
    }
    if let Some(reconciled) = stale {
        state::set(row, "reconciled", serde_json::to_value(reconciled)?);
    }
    if let Some(status) = intent.observed_status {
        state::set(row, "observed_status", status.word());
    }
    if let Some(generation) = intent.observed_generation {
        state::set(row, "observed_generation", generation);
    }
    // An outcome that left the document as it was is recorded nowhere, and the
    // store then writes nothing.
    if state::same_document(path, doc, &before)? {
        recorded.recorded_now = false;
    }
    recorded.reconciled = stale;
    recorded.intent = intent;
    Ok(recorded)
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows drive the store through its entry points"
)]
mod tests {
    use std::fs;

    use agent_runtime::protocol::Outcome;
    use serde_json::Value;

    use super::testing::*;
    use super::*;
    use crate::error::Error;
    use crate::state::{self, EffectOp, LaneStatus, fixtures};

    #[test]
    fn a_request_on_the_other_kind_of_file_refuses_before_reading() {
        let dir = tempfile::tempdir().unwrap();
        let item_path = item_file(dir.path());
        let fleet_path = fleet_file(dir.path());
        let rows = [
            (launch("KEN-1"), &item_path, Kind::Fleet),
            (
                Request::BeginRound(BeginRound {
                    kind: RoundKind::Dev,
                    body_revision: None,
                }),
                &fleet_path,
                Kind::Item,
            ),
        ];
        for (request, path, wanted) in rows {
            let err = run(path, &request).unwrap_err();
            assert!(
                matches!(&err, Error::OpKind { wanted: w, .. } if *w == wanted),
                "{err}"
            );
        }
        assert_eq!(fs::read_to_string(&item_path).unwrap(), fixtures::ITEM);
    }

    #[test]
    fn a_missing_file_refuses_as_record_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("workflow-state-KEN-1.json");
        let err = run(
            &path,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Dev,
                body_revision: None,
            }),
        )
        .unwrap_err();
        assert_eq!(err.key(), "record-missing");
    }

    #[test]
    fn recording_an_outcome_completes_each_effect_kind() {
        struct Row {
            name: &'static str,
            // Sets the fleet up and returns the intent id.
            setup: fn(&Path) -> String,
            outcome: Outcome,
            check: fn(&Path),
        }
        fn launched(path: &Path) -> String {
            intend(path, &launch("KEN-4468"))
        }
        fn closing(path: &Path) -> String {
            let id = launched(path);
            run(path, &outcome(&id, Outcome::Confirmed)).unwrap();
            intend(path, &close("KEN-4468"))
        }
        fn transferring(path: &Path) -> String {
            intend(path, &transfer(expected()))
        }
        let rows = [
            Row {
                name: "launch confirmed runs the lane",
                setup: launched,
                outcome: Outcome::Confirmed,
                check: |p| {
                    let l = lane(p, "KEN-4468");
                    assert_eq!(l.status, LaneStatus::Running);
                    assert_eq!(l.session_id.as_deref(), Some("native-1"));
                    assert_eq!(l.launch.unwrap().pid, Some(6000));
                    assert_eq!(l.running_at.as_deref(), Some("2026-01-29T15:20:00Z"));
                },
            },
            Row {
                name: "launch failed stops the lane",
                setup: launched,
                outcome: Outcome::Failed,
                check: |p| assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Stopped),
            },
            Row {
                name: "launch unconfirmed keeps the lane preparing",
                setup: launched,
                outcome: Outcome::Unconfirmed,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Preparing);
                    assert!(fleet(p).intents[0].completed_at.is_none());
                },
            },
            Row {
                name: "close confirmed ends the lane, drops its PR identities and logs it",
                setup: closing,
                outcome: Outcome::Confirmed,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Done);
                    let log = fleet(p).fleet_log;
                    assert_eq!(log.len(), 3);
                    assert_eq!(log[2]["kind"], Value::from("close"));
                    assert_eq!(log[2]["item"], Value::from("KEN-4468"));
                    assert_eq!(log[2]["at"], Value::from("2026-01-29T15:20:00Z"));
                },
            },
            Row {
                name: "close failed keeps the lane running",
                setup: closing,
                outcome: Outcome::Failed,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Running);
                    assert_eq!(fleet(p).fleet_log.len(), 2);
                },
            },
            Row {
                name: "transfer confirmed moves the generation",
                setup: transferring,
                outcome: Outcome::Confirmed,
                check: |p| {
                    let o = fleet(p).overseer.unwrap();
                    assert_eq!(o.generation, Some(4));
                    assert_eq!(o.pending, None);
                },
            },
            Row {
                name: "transfer failed leaves the predecessor in control",
                setup: transferring,
                outcome: Outcome::Failed,
                check: |p| {
                    let o = fleet(p).overseer.unwrap();
                    assert_eq!(o.generation, Some(3));
                    assert_eq!(o.pending, None);
                    assert_eq!(o.extra["harness"], Value::from("claude"));
                },
            },
        ];
        for row in &rows {
            let dir = tempfile::tempdir().unwrap();
            let path = fleet_file(dir.path());
            let id = (row.setup)(&path);
            let applied = run(&path, &outcome(&id, row.outcome)).unwrap();
            let Report::RecordOutcome(r) = &applied.report else {
                panic!("{}", row.name)
            };
            assert!(r.recorded_now, "{}", row.name);
            assert_eq!(r.intent.outcome, row.outcome, "{}", row.name);
            let stored = fleet(&path)
                .intents
                .into_iter()
                .find(|i| i.id == id)
                .unwrap();
            assert_eq!(stored.outcome, row.outcome, "{}", row.name);
            (row.check)(&path);
        }
    }

    /// Defect: an intent id that repeats on one target, so a sequence of
    /// operations there sticks. Each sequence completes, every intent closed
    /// and no two sharing an id.
    #[test]
    fn intent_sequences_on_one_target_complete() {
        struct Row {
            name: &'static str,
            steps: fn(&Path),
            intents: usize,
            check: fn(&Path),
        }
        let rows = [
            Row {
                name: "launch, failed, relaunch, confirmed",
                steps: |p| {
                    let first = intend(p, &launch("KEN-4468"));
                    run(p, &outcome(&first, Outcome::Failed)).unwrap();
                    let second = intend(p, &launch("KEN-4468"));
                    assert_ne!(first, second);
                    run(p, &outcome(&second, Outcome::Confirmed)).unwrap();
                },
                intents: 2,
                check: |p| {
                    let l = lane(p, "KEN-4468");
                    assert_eq!(l.status, LaneStatus::Running);
                    assert_eq!(l.session_id.as_deref(), Some("native-1"));
                },
            },
            Row {
                name: "launch, confirmed, close, confirmed, relaunch, confirmed",
                steps: |p| {
                    let first = intend(p, &launch("KEN-4468"));
                    run(p, &outcome(&first, Outcome::Confirmed)).unwrap();
                    let closing = intend(p, &close("KEN-4468"));
                    run(p, &outcome(&closing, Outcome::Confirmed)).unwrap();
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Done);
                    let third = intend(p, &launch("KEN-4468"));
                    assert_ne!(first, third);
                    run(p, &outcome(&third, Outcome::Confirmed)).unwrap();
                },
                intents: 3,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Running);
                    assert_eq!(fleet(p).lanes.len(), 2);
                },
            },
            Row {
                name: "transfer, failed, retry, confirmed",
                steps: |p| {
                    let first = intend(p, &transfer(expected()));
                    run(p, &outcome(&first, Outcome::Failed)).unwrap();
                    assert_eq!(fleet(p).overseer.unwrap().generation, Some(3));
                    let retry = intend(p, &transfer(expected()));
                    assert_ne!(first, retry);
                    run(p, &outcome(&retry, Outcome::Confirmed)).unwrap();
                },
                intents: 2,
                check: |p| {
                    let o = fleet(p).overseer.unwrap();
                    assert_eq!(o.generation, Some(4));
                    assert_eq!(o.pending, None);
                    assert_eq!(o.extra["harness"], Value::from("codex"));
                },
            },
        ];
        for row in &rows {
            let dir = tempfile::tempdir().unwrap();
            let path = fleet_file(dir.path());
            (row.steps)(&path);
            let intents = fleet(&path).intents;
            assert_eq!(intents.len(), row.intents, "{}", row.name);
            assert!(
                intents.iter().all(|i| !i.open()),
                "{}: every intent closed",
                row.name
            );
            let mut ids: Vec<&str> = intents.iter().map(|i| i.id.as_str()).collect();
            ids.dedup();
            assert_eq!(ids.len(), row.intents, "{}: ids distinct", row.name);
            (row.check)(&path);
        }
    }

    /// A launch, close or succession persists no intent without the identity
    /// of the process asking. The refusal carries the stable key and the
    /// operation, and the file is left as it was.
    #[test]
    fn an_intent_is_never_persisted_without_the_owners_identity() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        // A lane the close can target: launched and failed, so it stands
        // `stopped` with no open intent.
        let launched = intend(&path, &launch("KEN-4468"));
        run(&path, &outcome(&launched, Outcome::Failed)).unwrap();
        let unowned = Env {
            owner: None,
            ..env()
        };
        let before = fs::read_to_string(&path).unwrap();
        for (request, op) in [
            (launch("KEN-4468"), "launch-lane"),
            (close("KEN-4468"), "close-owned-resources"),
            (transfer(expected()), "request-transfer"),
        ] {
            let err = apply_on(&path, &request, &unowned, LOCK, &host()).unwrap_err();
            assert!(
                matches!(&err, Error::OwnerUnreadable { op: refused } if *refused == op),
                "{op}: {err}"
            );
            assert_eq!(err.key(), "owner-unreadable");
            assert_eq!(err.fields(), [("op".to_owned(), op.to_owned())]);
            assert_eq!(
                fs::read_to_string(&path).unwrap(),
                before,
                "{op}: nothing written"
            );
        }
        // The same requests with an owner persist, so the refusal is the
        // owner's absence and nothing else about the record.
        let owned = intend(&path, &launch("KEN-4468"));
        assert_eq!(
            fleet(&path)
                .intents
                .into_iter()
                .find(|i| i.id == owned)
                .unwrap()
                .owner,
            Some(owner())
        );
    }

    /// `intent-duplicate` is reachable only by replaying one `Env` onto the
    /// same target, which a mint never does: a stamp that differs in its
    /// nonce or its nanoseconds appends. The refused write leaves the file
    /// as it was.
    #[test]
    fn a_replayed_stamp_refuses_intent_duplicate_and_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let first =
            intent_id(&apply_on(&path, &launch("KEN-4468"), &env(), LOCK, &host()).unwrap());
        apply(&path, &outcome(&first, Outcome::Failed), &env(), LOCK).unwrap();
        let before = fs::read_to_string(&path).unwrap();
        let err = apply_on(&path, &launch("KEN-4468"), &env(), LOCK, &host()).unwrap_err();
        assert!(
            matches!(&err, Error::IntentDuplicate { id } if *id == first),
            "{err}"
        );
        assert_eq!(err.key(), "intent-duplicate");
        assert_eq!(err.fields(), [("intent_id".to_owned(), first.clone())]);
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            before,
            "nothing written"
        );
        for minted in [
            Env {
                nonce: env().nonce + 1,
                ..env()
            },
            Env {
                now_nanos: env().now_nanos + 1,
                ..env()
            },
        ] {
            fs::write(&path, &before).unwrap();
            let second =
                intent_id(&apply_on(&path, &launch("KEN-4468"), &minted, LOCK, &host()).unwrap());
            assert_ne!(second, first);
            assert_eq!(fleet(&path).intents.len(), 2);
        }
    }

    /// One open intent per target, and a late outcome on a lane whose record
    /// moved refuses.
    #[test]
    fn intents_on_one_target_exclude_each_other_and_late_outcomes_refuse() {
        struct Row {
            name: &'static str,
            steps: fn(&Path) -> Result<()>,
            refusal: Option<&'static str>,
            check: fn(&Path),
        }
        fn stopped(path: &Path) {
            fs::write(
                path,
                fixtures::FLEET.replacen("\"status\": \"done\"", "\"status\": \"stopped\"", 1),
            )
            .unwrap();
        }
        /// A writer's edit of the lane between two operations.
        fn writer_edit(path: &Path, item: &str, key: &str, value: Value) {
            let mut doc = object(path);
            let lanes = doc["lanes"].as_array_mut().unwrap();
            let lane = lanes.iter_mut().find(|l| l["item"] == item).unwrap();
            lane[key] = value;
            fs::write(
                path,
                serde_json::to_string_pretty(&Value::Object(doc)).unwrap(),
            )
            .unwrap();
        }
        let rows = [
            Row {
                name: "a launch while a close intent is open",
                steps: |p| {
                    stopped(p);
                    run(p, &close("KEN-4437"))?;
                    run(p, &launch("KEN-4437"))?;
                    Ok(())
                },
                refusal: Some("intent-open"),
                check: |p| {
                    assert_eq!(lane(p, "KEN-4437").status, LaneStatus::Stopped);
                    assert_eq!(fleet(p).intents.len(), 1);
                },
            },
            Row {
                // The close supersedes the launch rather than refusing; no
                // second intent is written until the launch intent is closed.
                name: "a close while a launch intent is open",
                steps: |p| {
                    run(p, &launch("KEN-4468"))?;
                    let applied = run(p, &close("KEN-4468"))?;
                    let Report::CloseOwnedResources(c) = &applied.report else {
                        panic!("{applied:?}")
                    };
                    assert!(
                        matches!(&c.effect, Effect::Supersedes { intent } if intent.op == EffectOp::LaunchLane)
                    );
                    Ok(())
                },
                refusal: None,
                check: |p| {
                    assert_eq!(fleet(p).intents.len(), 1);
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Preparing);
                },
            },
            Row {
                name: "an adoption while a launch intent is open",
                steps: |p| {
                    run(p, &launch("KEN-4468"))?;
                    run(p, &adopt("KEN-4468", "s1", None))?;
                    Ok(())
                },
                refusal: Some("intent-open"),
                check: |p| assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Preparing),
            },
            Row {
                name: "the same launch repeated reconciles",
                steps: |p| {
                    run(p, &launch("KEN-4468"))?;
                    run(p, &launch("KEN-4468"))?;
                    Ok(())
                },
                refusal: None,
                check: |p| assert_eq!(fleet(p).intents.len(), 1),
            },
            Row {
                name: "launch, confirmed, close, confirmed",
                steps: |p| {
                    let id = intent_id(&run(p, &launch("KEN-4468"))?);
                    run(p, &outcome(&id, Outcome::Confirmed))?;
                    let id = intent_id(&run(p, &close("KEN-4468"))?);
                    run(p, &outcome(&id, Outcome::Confirmed))?;
                    Ok(())
                },
                refusal: None,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Done);
                    assert!(fleet(p).intents.iter().all(|i| !i.open()));
                },
            },
            Row {
                name: "a failed launch frees the target for the next launch, which confirms",
                steps: |p| {
                    let id = intent_id(&run(p, &launch("KEN-4468"))?);
                    run(p, &outcome(&id, Outcome::Failed))?;
                    let id = intent_id(&run(p, &launch("KEN-4468"))?);
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Preparing);
                    run(p, &outcome(&id, Outcome::Confirmed))?;
                    Ok(())
                },
                refusal: None,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Running);
                    let intents = fleet(p).intents;
                    assert_eq!(intents.len(), 2);
                    assert!(intents.iter().all(|i| !i.open()));
                    assert_eq!(intents[0].outcome, Outcome::Failed);
                    assert_eq!(intents[1].outcome, Outcome::Confirmed);
                },
            },
            // A `lane-close` moved the lane to done under an open launch
            // intent. The launch's outcome reconciles the intent as
            // `intent-stale` with the observed status and leaves the lane as
            // that writer left it.
            Row {
                name: "a launch confirmed on a lane closed since reconciles stale",
                steps: |p| {
                    let id = intent_id(&run(p, &launch("KEN-4468"))?);
                    writer_edit(p, "KEN-4468", "status", Value::from("done"));
                    run(p, &outcome(&id, Outcome::Confirmed))?;
                    Ok(())
                },
                refusal: None,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Done);
                    let intent = &fleet(p).intents[0];
                    assert!(!intent.open(), "the intent is closed, not wedged");
                    assert_eq!(intent.reconciled, Some(state::Reconciled::IntentStale));
                    assert_eq!(intent.observed_status, Some(LaneStatus::Done));
                },
            },
            // A lane relaunched under an open close intent. The close's
            // outcome reconciles the intent as stale and leaves the running
            // lane alone.
            Row {
                name: "a close confirmed on a lane relaunched since reconciles stale",
                steps: |p| {
                    let id = intent_id(&run(p, &launch("KEN-4468"))?);
                    run(p, &outcome(&id, Outcome::Confirmed))?;
                    let id = intent_id(&run(p, &close("KEN-4468"))?);
                    writer_edit(
                        p,
                        "KEN-4468",
                        "session_since",
                        Value::from("2026-01-29T16:00:00Z"),
                    );
                    run(p, &outcome(&id, Outcome::Confirmed))?;
                    Ok(())
                },
                refusal: None,
                check: |p| {
                    assert_eq!(lane(p, "KEN-4468").status, LaneStatus::Running);
                    let close = fleet(p)
                        .intents
                        .into_iter()
                        .find(|i| i.op == EffectOp::CloseOwnedResources)
                        .unwrap();
                    assert!(!close.open());
                    assert_eq!(close.reconciled, Some(state::Reconciled::IntentStale));
                },
            },
        ];
        for row in rows {
            let dir = tempfile::tempdir().unwrap();
            let path = fleet_file(dir.path());
            let result = (row.steps)(&path);
            match row.refusal {
                Some(key) => {
                    let err = result.expect_err(row.name);
                    assert_eq!(err.key(), key, "{}", row.name);
                    if key == "intent-open" {
                        assert_eq!(err.fields()[0].0, "intent", "{}", row.name);
                    }
                }
                None => result.unwrap_or_else(|e| panic!("{}: {e}", row.name)),
            }
            (row.check)(&path);
        }
    }

    #[test]
    fn an_outcome_is_recorded_once_and_not_started_is_not_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = &intend(&path, &launch("KEN-4468"));
        assert_eq!(
            run(&path, &outcome(id, Outcome::NotStarted))
                .unwrap_err()
                .key(),
            "outcome-invalid"
        );
        assert_eq!(
            run(&path, &outcome("nope", Outcome::Confirmed))
                .unwrap_err()
                .key(),
            "intent-unknown"
        );
        // Unconfirmed may be followed by the real outcome.
        run(&path, &outcome(id, Outcome::Unconfirmed)).unwrap();
        run(&path, &outcome(id, Outcome::Confirmed)).unwrap();
        let Report::RecordOutcome(r) = run(&path, &outcome(id, Outcome::Confirmed)).unwrap().report
        else {
            panic!()
        };
        assert!(!r.recorded_now);
        let err = run(&path, &outcome(id, Outcome::Failed)).unwrap_err();
        assert!(matches!(
            err,
            Error::IntentComplete {
                outcome: Outcome::Confirmed,
                ..
            }
        ));
        // A confirmed launch is no longer an open intent, so a new launch of
        // the item is judged on the lane's status alone.
        let err = run(&path, &launch("KEN-4468")).unwrap_err();
        assert_eq!(err.key(), "lane-live");
    }

    /// Every fleet operation runs on a file whose `triaged` rows include the
    /// `item`-keyed and string shapes.
    #[test]
    fn fleet_operations_run_on_every_triaged_row_shape() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let triaged = object(&path)["triaged"].clone();
        assert!(triaged[1].get("item").is_some() && triaged[2].is_string());
        let id = intend(&path, &launch("KEN-4468"));
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let id = intend(&path, &close("KEN-4468"));
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        run(&path, &adopt("KEN-4437", "s1", None)).unwrap_err();
        run(&path, &transfer(expected())).unwrap();
        assert_eq!(object(&path)["triaged"], triaged, "rows untouched");
    }

    #[test]
    fn the_report_is_the_committed_transition_not_a_later_read() {
        // Two writers hold the same snapshot; the second write refuses and
        // reports nothing, so no report ever describes a lost update.
        let dir = tempfile::tempdir().unwrap();
        let path = item_file(dir.path());
        let first = state::load(&path).unwrap().unwrap();
        let second = state::load(&path).unwrap().unwrap();
        let mut a = first.doc.clone();
        let report_a = item_transition(
            &path,
            &mut a,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Dev,
                body_revision: None,
            }),
            &env(),
        )
        .unwrap();
        state::store(&path, &first, &a, LOCK).unwrap();
        let mut b = second.doc.clone();
        let other = Env { nonce: 1, ..env() };
        item_transition(
            &path,
            &mut b,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Dev,
                body_revision: None,
            }),
            &other,
        )
        .unwrap();
        let err = state::store(&path, &second, &b, LOCK).unwrap_err();
        assert_eq!(err.key(), "record-changed");
        let Report::BeginRound(begun) = report_a else {
            panic!()
        };
        assert_eq!(
            item(&path).dev_round_id.as_deref(),
            Some(begun.round_id.as_str())
        );
    }

    #[test]
    fn requests_and_reports_round_trip_through_their_tagged_json() {
        let rows = [
            (launch("KEN-1"), "launch-lane"),
            (
                Request::BeginRound(BeginRound {
                    kind: RoundKind::Review,
                    body_revision: None,
                }),
                "begin-round",
            ),
            (transfer(expected()), "request-transfer"),
            (
                Request::RecordVerification(RecordVerification {
                    round_id: None,
                    head: "e".repeat(40),
                    verdict: "none".into(),
                    reason: "no CI configured".into(),
                    source: "ci-wait --required-only".into(),
                }),
                "record-verification",
            ),
            (
                Request::RecordOutcome(Box::new(RecordOutcome {
                    intent_id: "x".into(),
                    outcome: Outcome::Unconfirmed,
                    launch: None,
                    session_id: None,
                    server_start: None,
                    server_socket: None,
                    window: None,
                    tmux_session: None,
                    launch_line: None,
                    home: None,
                    home_implicit: false,
                    watch: None,
                    mail_root: None,
                    observation: None,
                    while_owner: None,
                    lane_keys: None,
                    notice: None,
                    set_revision: None,
                })),
                "record-outcome",
            ),
        ];
        for (request, op) in rows {
            let json = serde_json::to_value(&request).unwrap();
            assert_eq!(json["op"], Value::from(op));
            assert_eq!(request.name(), op);
            let back: Request = serde_json::from_value(json).unwrap();
            assert_eq!(back, request);
        }
        let bad: std::result::Result<Request, _> =
            serde_json::from_str(r#"{"op": "launch-lane", "item": "KEN-1"}"#);
        assert!(bad.is_err());
        // An expected overseer record names only the keys the requester saw.
        let sparse: Request = serde_json::from_str(
            r#"{"op": "request-transfer", "expected": {"generation": 3}, "successor": {"harness": "codex"}}"#,
        )
        .unwrap();
        let Request::RequestTransfer(t) = sparse else {
            panic!()
        };
        assert_eq!(t.expected.pane, Value::Null);
        assert_eq!(t.expected.pending, Value::Null);
    }
}
