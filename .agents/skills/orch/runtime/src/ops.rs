//! The domain operations over the workflow records. Each is one transition
//! performed under the record's lock through the write check: the result a
//! caller gets is derived from the state the write committed, never from a
//! later unlocked read (the legacy `update-report` property).
//!
//! A transition reads typed views of the document and writes it back as a
//! patch: the keys the legacy writer of the same transition writes, deletes
//! or appends, and nothing else. An operation that starts an external effect
//! persists its intent (operation, target, expected revision) in the same
//! transition and reports how far the effect got as agent-runtime's
//! `Outcome`. One intent per target may be open: a repeated request of the
//! same operation reconciles it, another operation on the target refuses.
//! A transition never runs the effect itself: it returns the persisted
//! intent as [`Effect::Persisted`], the `effects` module runs the effect
//! against the host and records what it observed through `record-outcome`,
//! and a reconciliation re-observes an open intent the same way.

use std::path::{Path, PathBuf};

use agent_runtime::clock;
use agent_runtime::protocol::Outcome;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::error::{Error, Result};
use crate::state::{
    self, Document, EffectOp, Intent, ItemState, Kind, Lane, LaneStatus, LaunchIdentity, Locking,
    OVERSEER_COMPARE_KEYS, Overseer, PREDECESSOR_SESSION_KEYS, Pending, Phase, Reconciled, Record,
    SUCCESSOR_BINDING_KEYS, SUCCESSOR_IDENTITY_KEYS, Selection, Snapshot, Stage, StageKind, Stamp,
};

/// The clock and nonce an operation stamps with, supplied by the caller so
/// a transition is a pure function of the record and this value. One call
/// mints one `Env`; the stamp it yields names the round or intent that call
/// creates, so two calls never share one.
#[derive(Debug, Clone, Copy)]
pub struct Env {
    pub now_secs: u64,
    pub now_nanos: u128,
    pub nonce: u32,
}

impl Env {
    /// The round token the legacy `new-round-id` mints:
    /// `<nanoseconds since the epoch>-<random>`. An intent id ends in the
    /// same stamp.
    pub fn round_id(&self) -> String {
        format!("{}-{}", self.now_nanos, self.nonce)
    }

    /// The ISO 8601 UTC stamp the legacy stamps use.
    pub fn iso(&self) -> String {
        clock::iso_utc(self.now_secs)
    }
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// The two round kinds `new-round-id` mints.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RoundKind {
    Dev,
    Review,
}

impl RoundKind {
    fn stage(self) -> StageKind {
        match self {
            RoundKind::Dev => StageKind::Dev,
            RoundKind::Review => StageKind::Review,
        }
    }

    fn field(self) -> &'static str {
        match self {
            RoundKind::Dev => "dev_round_id",
            RoundKind::Review => "review_round_id",
        }
    }
}

/// Open a lane for an item: write its record as `preparing` and the intent
/// to launch it. On a relaunch every optional field left out keeps the
/// record's value, and `harness`, `account`, `model` and `effort` reach the
/// record only when the launch confirms, as the legacy launcher writes them
/// at `running`; on a first launch the record carries them from the start,
/// and `kind` and `surface` left out are `local` and `tmux`, the one launch
/// route this runtime has.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaunchLane {
    pub item: String,
    pub harness: String,
    pub mail_root: String,
    #[serde(default)]
    pub tracker: Option<String>,
    #[serde(default)]
    pub repo: Option<String>,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub surface: Option<String>,
    #[serde(default)]
    pub over_cap: Option<String>,
    /// The opening instruction, read by the harness at its start. Not a
    /// record field: the effect carries it to the launch.
    #[serde(default)]
    pub brief_file: Option<PathBuf>,
}

impl LaunchLane {
    /// The optional fields a relaunch writes at `preparing`, in the lane
    /// record's order.
    fn prepared(&self) -> [(&'static str, &Option<String>); 5] {
        [
            ("tracker", &self.tracker),
            ("repo", &self.repo),
            ("kind", &self.kind),
            ("surface", &self.surface),
            ("over_cap", &self.over_cap),
        ]
    }

    /// The fields the launch writes when it confirms.
    fn selection(&self) -> Selection {
        Selection {
            harness: self.harness.clone(),
            account: self.account.clone(),
            model: self.model.clone(),
            effort: self.effort.clone(),
        }
    }
}

/// Bind a session this runtime did not launch to the item's lane record.
/// A `launch` left out keeps the recorded identity, as the legacy wake does.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AdoptSession {
    pub item: String,
    pub session_id: String,
    #[serde(default)]
    pub harness: Option<String>,
    #[serde(default)]
    pub launch: Option<LaunchIdentity>,
}

/// Mint a round token, supersede the open stage of the kind and open the
/// new one, in one write.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BeginRound {
    pub kind: RoundKind,
}

/// Record that a validation run was admitted for a round before any work
/// starts, so a run with no process yet is not read as no run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordValidationAdmission {
    pub round_id: String,
    pub run_dir: String,
}

/// The overseer record the requester saw: the legacy succession
/// compare-and-swap set. A key left out compares as `null`, which is what
/// an absent key reads as. `session_id` left out or empty matches any
/// recorded one; `pending` left out requires none to stand.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OverseerExpected {
    #[serde(default)]
    pub server: Value,
    #[serde(default)]
    pub server_start: Value,
    #[serde(default)]
    pub pane: Value,
    #[serde(default)]
    pub generation: Value,
    #[serde(default)]
    pub launch_line: Value,
    #[serde(default)]
    pub cwd: Value,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub pending: Value,
}

impl OverseerExpected {
    fn compared(&self, key: &str) -> &Value {
        match key {
            "server" => &self.server,
            "server_start" => &self.server_start,
            "pane" => &self.pane,
            "generation" => &self.generation,
            "launch_line" => &self.launch_line,
            "cwd" => &self.cwd,
            _ => unreachable!("OVERSEER_COMPARE_KEYS names the six fields above"),
        }
    }
}

/// Ask for an overseer succession: record the successor as pending and the
/// intent to open it, when the record still is what the requester saw.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestTransfer {
    pub expected: OverseerExpected,
    pub successor: Pending,
    /// The successor's opening instruction, the handoff. Not a record
    /// field: the effect carries it to the launch.
    #[serde(default)]
    pub brief_file: Option<PathBuf>,
}

/// Close a round's stage: its result is accepted. With `run_dir` the open
/// `validate` stage of the round for that run closes instead.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AcceptResult {
    pub round_id: String,
    #[serde(default)]
    pub run_dir: Option<String>,
}

/// Record the verification verdict of a published head as `.verification`,
/// `{head, verdict, reason, source, at}`, written over an earlier record: a
/// newer head's verdict replaces the one before it. `round_id`, when given,
/// must name a stage the item ran.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordVerification {
    #[serde(default)]
    pub round_id: Option<String>,
    pub head: String,
    /// One of [`Verdict`]'s words, read as the request wrote it so the
    /// refusal names the word.
    pub verdict: String,
    /// What the reader read: for `none`, the affirmative absence evidence.
    pub reason: String,
    /// The reader, such as `ci-wait --required-only`.
    pub source: String,
}

/// The verdicts a verification record carries: ci-wait's terminal words.
/// ci-wait's fourth word, `pending`, is a wait that ended without a result
/// and so no verdict about the head; it is refused, never recorded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Pass,
    Fail,
    /// The repository runs no CI for the head, on affirmative absence
    /// evidence.
    None,
}

impl Verdict {
    /// The verdict a word names, `None` for a word that is no verdict.
    pub fn parse(word: &str) -> Option<Verdict> {
        match word {
            "pass" => Some(Verdict::Pass),
            "fail" => Some(Verdict::Fail),
            "none" => Some(Verdict::None),
            _ => Option::None,
        }
    }

    /// The word the record holds.
    pub fn word(self) -> &'static str {
        match self {
            Verdict::Pass => "pass",
            Verdict::Fail => "fail",
            Verdict::None => "none",
        }
    }
}

/// Ask for a lane's owned processes and window to be closed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseOwnedResources {
    pub item: String,
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
    /// `server_socket` and on the kept runner, so a later observation
    /// reaches that server by name (decision 64).
    #[serde(default)]
    pub server_socket: Option<String>,
    /// The record's `window`: `<session>:<title>` on a lane, the tmux
    /// window id on the overseer, as the legacy launchers write them.
    #[serde(default)]
    pub window: Option<String>,
    /// The tmux session a confirmed lane launch opened in; the fleet
    /// records the first as `tmux.session`, as the first legacy launch does.
    #[serde(default)]
    pub tmux_session: Option<String>,
    /// The line a confirmed successor ran, written over the pending one.
    #[serde(default)]
    pub launch_line: Option<String>,
    /// What the effect observed, kept on the intent for a reconciliation.
    #[serde(default)]
    pub observation: Option<Value>,
}

/// Record how far an open effect has got: its phase and the pane it holds,
/// written before the effect waits on its next step (decision 62). Refused
/// on an intent that has ended.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordPhase {
    pub intent_id: String,
    pub phase: Phase,
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
    AcceptResult(AcceptResult),
    RecordVerification(RecordVerification),
    CloseOwnedResources(CloseOwnedResources),
    RecordOutcome(Box<RecordOutcome>),
    RecordPhase(RecordPhase),
}

impl Request {
    /// The request's `op` word.
    pub fn name(&self) -> &'static str {
        match self {
            Request::LaunchLane(_) => "launch-lane",
            Request::AdoptSession(_) => "adopt-session",
            Request::BeginRound(_) => "begin-round",
            Request::RecordValidationAdmission(_) => "record-validation-admission",
            Request::RequestTransfer(_) => "request-transfer",
            Request::AcceptResult(_) => "accept-result",
            Request::RecordVerification(_) => "record-verification",
            Request::CloseOwnedResources(_) => "close-owned-resources",
            Request::RecordOutcome(_) => "record-outcome",
            Request::RecordPhase(_) => "record-phase",
        }
    }

    /// The state file the operation transitions.
    pub fn kind(&self) -> Kind {
        match self {
            Request::BeginRound(_)
            | Request::RecordValidationAdmission(_)
            | Request::AcceptResult(_)
            | Request::RecordVerification(_) => Kind::Item,
            Request::LaunchLane(_)
            | Request::AdoptSession(_)
            | Request::RequestTransfer(_)
            | Request::CloseOwnedResources(_)
            | Request::RecordOutcome(_)
            | Request::RecordPhase(_) => Kind::Fleet,
        }
    }
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

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
    /// stops what the pane holds (decision 67).
    Supersedes { intent: Intent },
}

/// A lane written `preparing` with its launch intent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneLaunched {
    pub lane: Lane,
    pub effect: Effect,
}

/// A lane bound to a session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LaneAdopted {
    pub lane: Lane,
    /// False when the lane already ran this session.
    pub adopted_now: bool,
}

/// A round minted and opened.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoundBegun {
    pub kind: RoundKind,
    pub round_id: String,
    pub start: u64,
    /// The round ids of the open stages of this kind the new round closed.
    pub superseded: Vec<Option<String>>,
}

/// A validation run admitted for a round.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidationAdmitted {
    pub round_id: String,
    pub run_dir: String,
    pub start: u64,
    /// False when the same run was already admitted.
    pub admitted_now: bool,
}

/// A succession recorded as pending.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TransferRequested {
    pub generation: u64,
    pub pending: Pending,
    pub effect: Effect,
}

/// A stage closed as accepted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResultAccepted {
    pub round_id: String,
    pub kind: StageKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_dir: Option<String>,
    pub start: u64,
    pub end: u64,
    /// False when the stage was already closed.
    pub closed_now: bool,
}

/// A verification verdict written for a head.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerificationRecorded {
    pub head: String,
    pub verdict: String,
    pub reason: String,
    pub source: String,
    pub at: String,
    /// True when a record stood before and this write replaced it.
    pub replaced: bool,
}

/// A close asked for, with the lane as it stands until the stop confirms.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseRequested {
    pub lane: Lane,
    pub effect: Effect,
}

/// A phase written onto its open intent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhaseRecorded {
    pub intent: Intent,
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
    AcceptResult(ResultAccepted),
    RecordVerification(VerificationRecorded),
    CloseOwnedResources(Box<CloseRequested>),
    RecordOutcome(Box<OutcomeRecorded>),
    RecordPhase(Box<PhaseRecorded>),
}

/// What `apply` returns: the stamp the file now holds and the report of the
/// transition that write committed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Applied {
    pub kind: Kind,
    pub stamp: Stamp,
    pub report: Report,
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

/// Apply one request to the state file at `path`: read, transition the
/// document, write through the write check, report. A refused write reports
/// nothing.
pub fn apply(path: &Path, request: &Request, env: &Env, locking: Locking) -> Result<Applied> {
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
    let snapshot = loaded(path)?;
    let mut doc = snapshot.doc.clone();
    let report = match kind {
        Kind::Item => item_transition(path, &mut doc, request, env)?,
        Kind::Fleet => fleet_transition(path, &mut doc, request, env, snapshot.stamp.revision())?,
    };
    let stamp = state::store(path, &snapshot, &doc, locking)?;
    Ok(Applied {
        kind,
        stamp,
        report,
    })
}

fn loaded(path: &Path) -> Result<Snapshot> {
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
        Request::BeginRound(r) => Ok(Report::BeginRound(begin_round(path, doc, r, env)?)),
        Request::RecordValidationAdmission(r) => Ok(Report::RecordValidationAdmission(
            record_validation_admission(path, doc, r, env)?,
        )),
        Request::AcceptResult(r) => Ok(Report::AcceptResult(accept_result(path, doc, r, env)?)),
        Request::RecordVerification(r) => Ok(Report::RecordVerification(record_verification(
            path, doc, r, env,
        )?)),
        Request::LaunchLane(_)
        | Request::AdoptSession(_)
        | Request::RequestTransfer(_)
        | Request::CloseOwnedResources(_)
        | Request::RecordOutcome(_)
        | Request::RecordPhase(_) => Err(kind_error(request, path, Kind::Item)),
    }
}

/// The fleet transitions on the document. `revision` is the revision the
/// read found, the one every intent created here expects.
pub fn fleet_transition(
    path: &Path,
    doc: &mut Document,
    request: &Request,
    env: &Env,
    revision: u64,
) -> Result<Report> {
    match request {
        Request::LaunchLane(r) => Ok(Report::LaunchLane(Box::new(launch_lane(
            path, doc, r, env, revision,
        )?))),
        Request::AdoptSession(r) => Ok(Report::AdoptSession(Box::new(adopt_session(
            path, doc, r, env,
        )?))),
        Request::RequestTransfer(r) => Ok(Report::RequestTransfer(Box::new(request_transfer(
            path, doc, r, env, revision,
        )?))),
        Request::CloseOwnedResources(r) => Ok(Report::CloseOwnedResources(Box::new(
            close_owned_resources(path, doc, r, env, revision)?,
        ))),
        Request::RecordOutcome(r) => Ok(Report::RecordOutcome(Box::new(record_outcome(
            path, doc, r, env,
        )?))),
        Request::RecordPhase(r) => Ok(Report::RecordPhase(Box::new(record_phase(path, doc, r)?))),
        Request::BeginRound(_)
        | Request::RecordValidationAdmission(_)
        | Request::AcceptResult(_)
        | Request::RecordVerification(_) => Err(kind_error(request, path, Kind::Fleet)),
    }
}

// ---- item ------------------------------------------------------------------

fn stages(path: &Path, doc: &Document) -> Result<Vec<Stage>> {
    Ok(ItemState::view(path, doc)?.stages)
}

fn begin_round(path: &Path, doc: &mut Document, r: &BeginRound, env: &Env) -> Result<RoundBegun> {
    let round_id = env.round_id();
    let now = env.now_secs;
    let stages = stages(path, doc)?;
    state::set(doc, r.kind.field(), round_id.clone());
    let rows = state::array_mut(path, doc, "stages")?;
    let mut superseded = Vec::new();
    for (index, stage) in stages.iter().enumerate() {
        if stage.kind == r.kind.stage() && stage.end.is_none() {
            let row = state::element_mut(path, rows, index, "stages")?;
            state::set(row, "end", now);
            state::set(row, "superseded", true);
            superseded.push(stage.round_id.clone());
        }
    }
    rows.push(json!({
        "kind": r.kind.stage().word(),
        "round_id": round_id,
        "start": now,
        "end": Value::Null,
    }));
    Ok(RoundBegun {
        kind: r.kind,
        round_id,
        start: now,
        superseded,
    })
}

fn record_validation_admission(
    path: &Path,
    doc: &mut Document,
    r: &RecordValidationAdmission,
    env: &Env,
) -> Result<ValidationAdmitted> {
    let stages = stages(path, doc)?;
    let bound = stages
        .iter()
        .any(|s| s.kind != StageKind::Validate && s.round_id.as_deref() == Some(&r.round_id));
    if !bound {
        return Err(Error::RoundUnknown {
            round_id: r.round_id.clone(),
        });
    }
    if let Some(existing) = stages.iter().find(|s| {
        s.kind == StageKind::Validate
            && s.round_id.as_deref() == Some(&r.round_id)
            && s.run_dir.as_deref() == Some(&r.run_dir)
    }) {
        return Ok(ValidationAdmitted {
            round_id: r.round_id.clone(),
            run_dir: r.run_dir.clone(),
            start: existing.start,
            admitted_now: false,
        });
    }
    state::array_mut(path, doc, "stages")?.push(json!({
        "kind": StageKind::Validate.word(),
        "round_id": r.round_id,
        "start": env.now_secs,
        "end": Value::Null,
        "run_dir": r.run_dir,
    }));
    Ok(ValidationAdmitted {
        round_id: r.round_id.clone(),
        run_dir: r.run_dir.clone(),
        start: env.now_secs,
        admitted_now: true,
    })
}

fn accept_result(
    path: &Path,
    doc: &mut Document,
    r: &AcceptResult,
    env: &Env,
) -> Result<ResultAccepted> {
    let stages = stages(path, doc)?;
    let index = match &r.run_dir {
        Some(run_dir) => stages
            .iter()
            .position(|s| {
                s.kind == StageKind::Validate
                    && s.round_id.as_deref() == Some(&r.round_id)
                    && s.run_dir.as_deref() == Some(run_dir)
            })
            .ok_or_else(|| Error::RunUnknown {
                round_id: r.round_id.clone(),
                run_dir: run_dir.clone(),
            })?,
        None => stages
            .iter()
            .position(|s| {
                s.kind != StageKind::Validate && s.round_id.as_deref() == Some(&r.round_id)
            })
            .ok_or_else(|| Error::RoundUnknown {
                round_id: r.round_id.clone(),
            })?,
    };
    let stage = &stages[index];
    if stage.superseded == Some(true) {
        return Err(Error::RoundSuperseded {
            round_id: r.round_id.clone(),
        });
    }
    let (end, closed_now) = match stage.end {
        Some(end) => (end, false),
        None => {
            let rows = state::array_mut(path, doc, "stages")?;
            state::set(
                state::element_mut(path, rows, index, "stages")?,
                "end",
                env.now_secs,
            );
            (env.now_secs, true)
        }
    };
    Ok(ResultAccepted {
        round_id: r.round_id.clone(),
        kind: stage.kind,
        run_dir: stage.run_dir.clone(),
        start: stage.start,
        end,
        closed_now,
    })
}

/// The key `.verification` is written under.
const VERIFICATION_KEY: &str = "verification";

fn record_verification(
    path: &Path,
    doc: &mut Document,
    r: &RecordVerification,
    env: &Env,
) -> Result<VerificationRecorded> {
    let verdict = Verdict::parse(&r.verdict).ok_or_else(|| Error::VerdictInvalid {
        verdict: r.verdict.clone(),
    })?;
    if let Some(round_id) = &r.round_id {
        let bound = stages(path, doc)?
            .iter()
            .any(|s| s.round_id.as_deref() == Some(round_id));
        if !bound {
            return Err(Error::RoundUnknown {
                round_id: round_id.clone(),
            });
        }
    }
    let replaced = !matches!(doc.get(VERIFICATION_KEY), None | Some(Value::Null));
    let at = env.iso();
    state::set(
        doc,
        VERIFICATION_KEY,
        json!({
            "head": r.head,
            "verdict": verdict.word(),
            "reason": r.reason,
            "source": r.source,
            "at": at,
        }),
    );
    Ok(VerificationRecorded {
        head: r.head.clone(),
        verdict: verdict.word().to_owned(),
        reason: r.reason.clone(),
        source: r.source.clone(),
        at,
        replaced,
    })
}

// ---- fleet -----------------------------------------------------------------

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
    /// A launch intent a close may supersede once its reconcile reads it
    /// still unconfirmed with a recorded pane (decision 67).
    Supersedable(Intent),
}

/// The standing open intent on `target` against the operation `op` asks
/// for. Every pair of operations refuses `intent-open`, except a close over
/// an open launch, which supersedes it: a hung launch would otherwise have
/// neither a close nor a relaunch (decision 67).
fn open_intent(intents: &[Intent], op: EffectOp, target: &str) -> Result<Standing> {
    let Some(intent) = intents.iter().find(|i| i.target == target && i.open()) else {
        return Ok(Standing::Clear);
    };
    match (intent.op, op) {
        (EffectOp::LaunchLane, EffectOp::LaunchLane)
        | (EffectOp::CloseOwnedResources, EffectOp::CloseOwnedResources)
        | (EffectOp::RequestTransfer, EffectOp::RequestTransfer) => {
            Ok(Standing::Same(intent.clone()))
        }
        (EffectOp::LaunchLane, EffectOp::CloseOwnedResources) => {
            Ok(Standing::Supersedable(intent.clone()))
        }
        (EffectOp::CloseOwnedResources, EffectOp::LaunchLane)
        | (EffectOp::LaunchLane | EffectOp::CloseOwnedResources, EffectOp::RequestTransfer)
        | (EffectOp::RequestTransfer, EffectOp::LaunchLane | EffectOp::CloseOwnedResources) => {
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

fn new_intent(op: EffectOp, target: &str, env: &Env, revision: u64) -> Intent {
    Intent {
        id: format!("{}:{target}:{}", op.word(), env.round_id()),
        op,
        target: target.to_owned(),
        expected_revision: revision,
        created_at: env.iso(),
        outcome: Outcome::NotStarted,
        completed_at: None,
        lane_since: None,
        selection: None,
        original_pending: None,
        phase: None,
        observation: None,
        reconciled: None,
        observed_status: None,
        observed_generation: None,
    }
}

fn string_or_null(value: &Option<String>) -> Value {
    match value {
        Some(s) => Value::from(s.as_str()),
        None => Value::Null,
    }
}

/// Null `key` where `doc` holds it; an absent optional field gains no null
/// (decision 34).
fn null_held(doc: &mut Document, key: &str) {
    if doc.contains_key(key) {
        state::set(doc, key, Value::Null);
    }
}

/// The successor's pane and server a transfer confirmation names, or
/// `launch-missing` for the member it lacks: the published record is the
/// successor's own, and its watch start keeps only a record naming its pane
/// on its server.
fn successor_binding<'a>(intent: &str, r: &'a RecordOutcome) -> Result<(&'a str, u64)> {
    let missing = |field| Error::LaunchMissing {
        intent: intent.to_owned(),
        field,
    };
    let launch = r.launch.as_ref().ok_or_else(|| missing("launch"))?;
    let pane = launch.pane.as_deref().ok_or_else(|| missing("pane"))?;
    let server = launch.server.ok_or_else(|| missing("server"))?;
    Ok((pane, server))
}

/// The record a first launch appends, in `lane_record_write`'s key order
/// with `null` where the launch knows no value, as that writer emits it.
fn new_lane_record(r: &LaunchLane, at: &str) -> Value {
    json!({
        "item": r.item,
        "tracker": string_or_null(&r.tracker),
        "repo": string_or_null(&r.repo),
        "harness": r.harness,
        "window": Value::Null,
        "account": string_or_null(&r.account),
        "host": Value::Null,
        "kind": r.kind.as_deref().unwrap_or("local"),
        "mail_root": r.mail_root,
        "surface": r.surface.as_deref().unwrap_or("tmux"),
        "model": string_or_null(&r.model),
        "effort": string_or_null(&r.effort),
        "session_id": Value::Null,
        "session_since": at,
        "launched_at": at,
        "running_at": Value::Null,
        "status": LaneStatus::Preparing.word(),
        "over_cap": string_or_null(&r.over_cap),
        "launch": Value::Null,
    })
}

/// The legacy `unpark($at)`: a standing `parked` moves into `pending_pr`
/// (`{pr, repo, head}` plus `until_pr` and `until_repo` where set) and
/// appends `{from: parked.at, to: $at, cause: "parked"}` to `pauses`; the
/// `parked` key is removed either way.
fn unpark(path: &Path, lane: &mut Document, index: usize, at: &str) -> Result<()> {
    let parked = match lane.get("parked") {
        None => return Ok(()),
        Some(Value::Null) => {
            state::delete(lane, "parked");
            return Ok(());
        }
        Some(Value::Object(parked)) => parked.clone(),
        Some(other) => {
            return Err(Error::Shape {
                path: path.to_path_buf(),
                field: format!("lanes/{index}/parked"),
                reason: crate::error::ShapeReason::NotObject,
                cause: format!("found {other}"),
            });
        }
    };
    if parked.get("at").is_some_and(|v| !v.is_null()) {
        let pause = json!({"from": parked["at"], "to": at, "cause": "parked"});
        state::array_mut(path, lane, "pauses")?.push(pause);
    }
    let mut pending = Map::new();
    for key in ["pr", "repo", "head"] {
        pending.insert(
            key.to_owned(),
            parked.get(key).cloned().unwrap_or(Value::Null),
        );
    }
    for key in ["until_pr", "until_repo"] {
        if let Some(value) = parked.get(key).filter(|v| !v.is_null()) {
            pending.insert(key.to_owned(), value.clone());
        }
    }
    state::set(lane, "pending_pr", Value::Object(pending));
    state::delete(lane, "parked");
    Ok(())
}

fn launch_lane(
    path: &Path,
    doc: &mut Document,
    r: &LaunchLane,
    env: &Env,
    revision: u64,
) -> Result<LaneLaunched> {
    // The one launch route is a local tmux window; a non-local kind or a
    // non-tmux surface is refused before any intent persists (decision 57).
    if let Some(kind) = r.kind.as_deref().filter(|k| *k != "local") {
        return Err(Error::HostUnsupported {
            kind: kind.to_owned(),
            surface: r.surface.clone().unwrap_or_else(|| "tmux".to_owned()),
        });
    }
    if let Some(surface) = r.surface.as_deref().filter(|s| *s != "tmux") {
        return Err(Error::HostUnsupported {
            kind: r.kind.clone().unwrap_or_else(|| "local".to_owned()),
            surface: surface.to_owned(),
        });
    }
    let lanes = lanes(path, doc)?;
    let intents = intents(path, doc)?;
    let position = lanes.iter().position(|l| l.item == r.item);
    if let Some(intent) = same_open_intent(&intents, EffectOp::LaunchLane, &r.item)? {
        let index = position.ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
        return Ok(LaneLaunched {
            lane: lane_at(path, doc, index)?,
            effect: Effect::Reconciled { intent },
        });
    }
    let at = env.iso();
    let index = match position {
        Some(index) => {
            let previous = &lanes[index];
            if previous.status.in_flight() {
                return Err(Error::LaneLive {
                    item: r.item.clone(),
                    status: previous.status,
                });
            }
            // The relaunch patch: what this launch knows, over a record that
            // keeps every other field (its first `launched_at` included, the
            // fleet start the watch reads). `prepare` and `live_display`
            // belong to the earlier session; `running_at` and `launch` are
            // written empty until the launch confirms, and the selection
            // (harness, account, model, effort) waits on the intent until
            // then, as the legacy writer records it at `running`.
            let lane = lane_doc_mut(path, doc, index)?;
            state::set(lane, "mail_root", r.mail_root.as_str());
            for (key, value) in r.prepared() {
                if let Some(value) = value {
                    state::set(lane, key, value.as_str());
                }
            }
            state::set(lane, "session_since", at.as_str());
            state::set(lane, "running_at", Value::Null);
            state::set(lane, "status", LaneStatus::Preparing.word());
            state::set(lane, "launch", Value::Null);
            state::delete(lane, "prepare");
            state::delete(lane, "live_display");
            unpark(path, lane, index, &at)?;
            index
        }
        None => {
            let rows = state::array_mut(path, doc, "lanes")?;
            rows.push(new_lane_record(r, &at));
            rows.len() - 1
        }
    };
    let mut intent = new_intent(EffectOp::LaunchLane, &r.item, env, revision);
    intent.lane_since = Some(at);
    intent.selection = Some(r.selection());
    push_intent(path, doc, &intent)?;
    Ok(LaneLaunched {
        lane: lane_at(path, doc, index)?,
        effect: Effect::Persisted { intent },
    })
}

fn adopt_session(
    path: &Path,
    doc: &mut Document,
    r: &AdoptSession,
    env: &Env,
) -> Result<LaneAdopted> {
    let lanes = lanes(path, doc)?;
    let index = lanes
        .iter()
        .position(|l| l.item == r.item)
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    no_open_intent(&intents(path, doc)?, &r.item)?;
    let previous = &lanes[index];
    match previous.status {
        LaneStatus::Running => {
            if previous.session_id.as_deref() == Some(&r.session_id) {
                return Ok(LaneAdopted {
                    lane: previous.clone(),
                    adopted_now: false,
                });
            }
            Err(Error::LaneLive {
                item: r.item.clone(),
                status: previous.status,
            })
        }
        LaneStatus::Done => Err(Error::LaneDone {
            item: r.item.clone(),
        }),
        LaneStatus::Preparing | LaneStatus::Stopped | LaneStatus::Parked => {
            let at = env.iso();
            let lane = lane_doc_mut(path, doc, index)?;
            state::set(lane, "session_id", r.session_id.as_str());
            if let Some(harness) = &r.harness {
                state::set(lane, "harness", harness.as_str());
            }
            if let Some(launch) = &r.launch {
                state::set(lane, "launch", serde_json::to_value(launch)?);
            }
            state::set(lane, "status", LaneStatus::Running.word());
            state::set(lane, "running_at", at.as_str());
            unpark(path, lane, index, &at)?;
            Ok(LaneAdopted {
                lane: lane_at(path, doc, index)?,
                adopted_now: true,
            })
        }
    }
}

/// The overseer view and its document, or `overseer-missing`.
fn overseer(path: &Path, doc: &Document) -> Result<Overseer> {
    state::field::<Overseer>(path, doc, "overseer")?.ok_or_else(|| Error::OverseerMissing {
        path: path.to_path_buf(),
    })
}

fn request_transfer(
    path: &Path,
    doc: &mut Document,
    r: &RequestTransfer,
    env: &Env,
    revision: u64,
) -> Result<TransferRequested> {
    let current = overseer(path, doc)?;
    let generation = current.generation.unwrap_or(0);
    let target = overseer_target(generation);
    let intents = intents(path, doc)?;
    if let Some(intent) = same_open_intent(&intents, EffectOp::RequestTransfer, &target)? {
        return Ok(TransferRequested {
            generation,
            pending: current.pending.unwrap_or_else(|| r.successor.clone()),
            effect: Effect::Reconciled { intent },
        });
    }
    // One open succession per overseer, not per generation string: a
    // transfer still open on an earlier generation is reconciled first.
    if let Some(intent) = intents
        .iter()
        .find(|i| i.op == EffectOp::RequestTransfer && i.open() && i.target != target)
    {
        return Err(Error::IntentOpen {
            intent: intent.id.clone(),
            op: intent.op,
            target: intent.target.clone(),
        });
    }
    // The legacy compare-and-swap, `ol_succession_owned`: the six identity
    // keys equal, `session_id` equal or not expected, `pending` equal.
    let record = state::object_mut(path, doc, "overseer")?;
    let mut changed: Vec<String> = OVERSEER_COMPARE_KEYS
        .iter()
        .filter(|key| record.get(**key).unwrap_or(&Value::Null) != r.expected.compared(key))
        .map(|key| (*key).to_owned())
        .collect();
    if let Some(expected) = r.expected.session_id.as_deref().filter(|s| !s.is_empty())
        && current.session_id.as_deref() != Some(expected)
    {
        changed.push("session_id".to_owned());
    }
    let standing = record.get("pending").cloned().unwrap_or(Value::Null);
    if standing != r.expected.pending {
        changed.push("pending".to_owned());
    }
    if !changed.is_empty() {
        return Err(Error::OverseerChanged {
            path: path.to_path_buf(),
            fields: changed,
        });
    }
    state::set(record, "pending", serde_json::to_value(&r.successor)?);
    let mut intent = new_intent(EffectOp::RequestTransfer, &target, env, revision);
    intent.original_pending = Some(standing).filter(|v| !v.is_null());
    push_intent(path, doc, &intent)?;
    Ok(TransferRequested {
        generation,
        pending: r.successor.clone(),
        effect: Effect::Persisted { intent },
    })
}

fn close_owned_resources(
    path: &Path,
    doc: &mut Document,
    r: &CloseOwnedResources,
    env: &Env,
    revision: u64,
) -> Result<CloseRequested> {
    let lanes = lanes(path, doc)?;
    let lane = lanes
        .iter()
        .find(|l| l.item == r.item)
        .cloned()
        .ok_or_else(|| Error::LaneMissing {
            item: r.item.clone(),
        })?;
    if lane.status == LaneStatus::Done {
        return Err(Error::LaneDone {
            item: r.item.clone(),
        });
    }
    match open_intent(&intents(path, doc)?, EffectOp::CloseOwnedResources, &r.item)? {
        Standing::Clear => {}
        Standing::Same(intent) => {
            return Ok(CloseRequested {
                lane,
                effect: Effect::Reconciled { intent },
            });
        }
        Standing::Supersedable(intent) => {
            return Ok(CloseRequested {
                lane,
                effect: Effect::Supersedes { intent },
            });
        }
    }
    let mut intent = new_intent(EffectOp::CloseOwnedResources, &r.item, env, revision);
    intent.lane_since = lane.session_since.clone();
    push_intent(path, doc, &intent)?;
    Ok(CloseRequested {
        lane,
        effect: Effect::Persisted { intent },
    })
}

/// The target of a transfer intent at `generation`.
pub fn overseer_target(generation: u64) -> String {
    format!("overseer:{generation}")
}

/// The generation a transfer intent's target names.
fn target_generation(target: &str) -> Option<u64> {
    target.strip_prefix("overseer:")?.parse().ok()
}

/// The lane an intent targets, as it stands, or the reading that its record
/// moved under the intent: the lane is gone, relaunched since (its
/// `session_since` differs), or closed under a launch intent, which a
/// legacy `lane-close` does from any status.
enum IntentTarget {
    Current { index: usize },
    Moved { observed: Option<LaneStatus> },
}

fn intent_lane(path: &Path, doc: &Document, intent: &Intent) -> Result<IntentTarget> {
    let lanes = lanes(path, doc)?;
    let Some(index) = lanes.iter().position(|l| l.item == intent.target) else {
        return Ok(IntentTarget::Moved { observed: None });
    };
    let lane = &lanes[index];
    let moved = lane.session_since != intent.lane_since
        || (intent.op == EffectOp::LaunchLane && lane.status == LaneStatus::Done);
    if moved {
        return Ok(IntentTarget::Moved {
            observed: Some(lane.status),
        });
    }
    Ok(IntentTarget::Current { index })
}

/// Record the fleet's tmux session where none is recorded yet, the legacy
/// first launch's `.tmux.session //= $s`.
fn record_tmux_session(path: &Path, doc: &mut Document, session: &str) -> Result<()> {
    if matches!(doc.get("tmux"), None | Some(Value::Null)) {
        state::set(doc, "tmux", json!({"session": session}));
        return Ok(());
    }
    let tmux = state::object_mut(path, doc, "tmux")?;
    if matches!(tmux.get("session"), None | Some(Value::Null)) {
        state::set(tmux, "session", session);
    }
    Ok(())
}

/// Whether an observation says the succession's predecessor was retired.
fn retired(observation: Option<&Value>) -> bool {
    observation
        .and_then(|o| o.get("retired"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// Write an open intent's phase. A closed intent refuses `intent-complete`:
/// its effect has no next step to wait on.
fn record_phase(path: &Path, doc: &mut Document, r: &RecordPhase) -> Result<PhaseRecorded> {
    let intents = intents(path, doc)?;
    let index = intents
        .iter()
        .position(|i| i.id == r.intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: r.intent_id.clone(),
        })?;
    let mut intent = intents[index].clone();
    if !intent.open() {
        return Err(Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        });
    }
    intent.phase = Some(r.phase.clone());
    let rows = state::array_mut(path, doc, "intents")?;
    let row = state::element_mut(path, rows, index, "intents")?;
    state::set(row, "phase", serde_json::to_value(&r.phase)?);
    Ok(PhaseRecorded { intent })
}

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
    let mut recorded = OutcomeRecorded {
        intent: intent.clone(),
        recorded_now: true,
        lane: None,
        generation: None,
        reconciled: None,
    };
    // Whether the target's record moved under the intent: then the outcome
    // closes the intent and moves nothing, whatever it reports.
    let stale = match intent.op {
        EffectOp::LaunchLane | EffectOp::CloseOwnedResources => {
            match intent_lane(path, doc, &intent)? {
                IntentTarget::Current { .. } => None,
                IntentTarget::Moved { observed } => {
                    intent.observed_status = observed;
                    Some(Reconciled::IntentStale)
                }
            }
        }
        EffectOp::RequestTransfer => {
            let generation = overseer(path, doc)?.generation.unwrap_or(0);
            if target_generation(&intent.target) == Some(generation) {
                None
            } else {
                intent.observed_generation = Some(generation);
                Some(Reconciled::IntentStale)
            }
        }
    };
    match (stale, intent.op, r.outcome) {
        (Some(_), _, _) => {}
        (None, EffectOp::LaunchLane, Outcome::Confirmed) => {
            let IntentTarget::Current { index: lane_index } = intent_lane(path, doc, &intent)?
            else {
                unreachable!("judged current above")
            };
            if let Some(session) = &r.tmux_session {
                record_tmux_session(path, doc, session)?;
            }
            let lane = lane_doc_mut(path, doc, lane_index)?;
            // The whole selection, null where the request named none, as
            // the legacy `running` write records it (`open-terminal`,
            // `lane_record_write`): the session that runs is this
            // request's, so no account, model or effort of the earlier
            // session survives into its record.
            if let Some(selection) = &intent.selection {
                state::set(lane, "harness", selection.harness.as_str());
                for (key, value) in [
                    ("account", &selection.account),
                    ("model", &selection.model),
                    ("effort", &selection.effort),
                ] {
                    state::set(lane, key, string_or_null(value));
                }
            }
            if let Some(window) = &r.window {
                state::set(lane, "window", window.as_str());
            }
            state::set(lane, "status", LaneStatus::Running.word());
            state::set(lane, "running_at", at.as_str());
            state::set(lane, "launch", serde_json::to_value(&r.launch)?);
            state::set(lane, "session_id", string_or_null(&r.session_id));
            recorded.lane = Some(Box::new(lane_at(path, doc, lane_index)?));
        }
        (None, EffectOp::LaunchLane, Outcome::Failed) => {
            let IntentTarget::Current { index: lane_index } = intent_lane(path, doc, &intent)?
            else {
                unreachable!("judged current above")
            };
            let lane = lane_doc_mut(path, doc, lane_index)?;
            state::set(lane, "status", LaneStatus::Stopped.word());
            recorded.lane = Some(Box::new(lane_at(path, doc, lane_index)?));
        }
        (None, EffectOp::CloseOwnedResources, Outcome::Confirmed) => {
            let IntentTarget::Current { index: lane_index } = intent_lane(path, doc, &intent)?
            else {
                unreachable!("judged current above")
            };
            let lane = lane_doc_mut(path, doc, lane_index)?;
            state::set(lane, "status", LaneStatus::Done.word());
            state::delete(lane, "pending_pr");
            state::delete(lane, "parked");
            state::array_mut(path, doc, "fleet_log")?.push(json!({
                "at": at,
                "kind": "close",
                "item": intent.target,
                "text": format!("lane closed; intent {}", intent.id),
            }));
            recorded.lane = Some(Box::new(lane_at(path, doc, lane_index)?));
        }
        (None, EffectOp::RequestTransfer, Outcome::Confirmed) => {
            let (pane, server) = successor_binding(&intent.id, r)?;
            let generation = overseer(path, doc)?.generation.unwrap_or(0);
            let record = state::object_mut(path, doc, "overseer")?;
            let Some(Value::Object(pending)) = record.get("pending").cloned() else {
                return Err(Error::PendingMissing {
                    path: path.to_path_buf(),
                });
            };
            // The successor's record as `ol_record_write` builds one for a
            // session other than the prior: its identity from `pending`,
            // `class` only where the pending carries one, the next
            // generation, the successor's own pane on its server, the
            // server start where the confirmation knows it, the binding its
            // watch start reads afresh nulled unless the confirmation
            // carries it, and the fields of the session that ended dropped.
            // Every other key keeps its value and place.
            for key in SUCCESSOR_IDENTITY_KEYS {
                state::set(
                    record,
                    key,
                    pending.get(*key).cloned().unwrap_or(Value::Null),
                );
            }
            if let Some(line) = &r.launch_line {
                state::set(record, "launch_line", line.as_str());
            }
            match pending.get("class").filter(|v| !v.is_null()) {
                Some(class) => state::set(record, "class", class.clone()),
                None => {
                    state::delete(record, "class");
                }
            }
            state::set(record, "generation", generation + 1);
            // The server as the string the legacy writers hand jq through
            // `--arg`, which `ol_owns` compares it as; a lane's
            // `launch.server` is a number, so the identity carries one.
            state::set(record, "pane", pane);
            state::set(record, "server", server.to_string());
            match r.server_start {
                Some(start) => state::set(record, "server_start", start),
                None => null_held(record, "server_start"),
            }
            if let Some(socket) = &r.server_socket {
                state::set(record, "server_socket", socket.as_str());
            }
            for key in SUCCESSOR_BINDING_KEYS {
                match (*key, &r.window) {
                    ("window", Some(window)) => state::set(record, key, window.as_str()),
                    (_, _) => null_held(record, key),
                }
            }
            for key in PREDECESSOR_SESSION_KEYS {
                state::delete(record, key);
            }
            // The runtime launched the successor and read its process
            // identity, so it writes `harness_pid`/`harness_start` now,
            // appended as `ol_record_start` appends them. The next
            // succession then has a predecessor identity to retire by
            // (decision 58). A confirmation always carries them, since a
            // launch with no readable identity records `unconfirmed`.
            if let (Some(pid), Some(start)) = (
                r.launch.as_ref().and_then(|l| l.pid),
                r.launch.as_ref().and_then(|l| l.start.clone()),
            ) {
                state::set(record, "harness_pid", pid);
                state::set(record, "harness_start", start.as_str());
            }
            recorded.generation = Some(generation + 1);
        }
        (None, EffectOp::RequestTransfer, Outcome::Failed) => {
            // Failure before retirement leaves the predecessor in control
            // and puts back the pending this request overwrote, if any. A
            // failure after it leaves no controller: the pending line stays
            // as the recovery route's own, and the record names nothing
            // else.
            let generation = overseer(path, doc)?.generation;
            // Read retirement from this outcome's observation, not the
            // intent's stored one, which a reconcile overwrites (finding 15).
            if !retired(r.observation.as_ref()) {
                let record = state::object_mut(path, doc, "overseer")?;
                match &intent.original_pending {
                    Some(original) => state::set(record, "pending", original.clone()),
                    None => {
                        state::delete(record, "pending");
                    }
                }
            }
            recorded.generation = generation;
        }
        (None, EffectOp::LaunchLane, Outcome::Unconfirmed) => {
            // The window opened but the composer was not read in the bound.
            // Persist the pane the effect holds on the lane's `launch` so a
            // reconcile can re-observe it; the lane stays `preparing` (task
            // 3). A relaunch that wrote `launch: null` keeps that until the
            // effect names a pane.
            if r.launch.is_some() {
                let IntentTarget::Current { index: lane_index } = intent_lane(path, doc, &intent)?
                else {
                    unreachable!("judged current above")
                };
                let lane = lane_doc_mut(path, doc, lane_index)?;
                state::set(lane, "launch", serde_json::to_value(&r.launch)?);
                recorded.lane = Some(Box::new(lane_at(path, doc, lane_index)?));
            }
        }
        (None, EffectOp::RequestTransfer, Outcome::Unconfirmed) => {
            // A failure after retirement: the predecessor is gone and a
            // waiting runner stands. Keep the runner's identity under
            // `overseer.pending.runner` so a reconcile completes from it, and
            // leave the generation unmoved (decision 58). Before retirement
            // the effect records `failed`, not this.
            if retired(r.observation.as_ref())
                && let Some(runner) = &r.launch
            {
                let record = state::object_mut(path, doc, "overseer")?;
                if let Some(Value::Object(pending)) = record.get_mut("pending") {
                    let mut runner_obj = serde_json::Map::new();
                    runner_obj.insert("pane".to_owned(), string_or_null(&runner.pane));
                    runner_obj.insert(
                        "server".to_owned(),
                        runner.server.map(Value::from).unwrap_or(Value::Null),
                    );
                    runner_obj.insert(
                        "pid".to_owned(),
                        runner.pid.map(Value::from).unwrap_or(Value::Null),
                    );
                    runner_obj.insert("start".to_owned(), string_or_null(&runner.start));
                    runner_obj.insert(
                        "server_start".to_owned(),
                        r.server_start.map(Value::from).unwrap_or(Value::Null),
                    );
                    runner_obj.insert("socket".to_owned(), string_or_null(&r.server_socket));
                    runner_obj.insert("session_id".to_owned(), string_or_null(&r.session_id));
                    pending.insert("runner".to_owned(), Value::Object(runner_obj));
                }
            }
        }
        (None, EffectOp::CloseOwnedResources, Outcome::Failed)
        | (None, EffectOp::CloseOwnedResources, Outcome::Unconfirmed)
        | (None, _, Outcome::NotStarted) => {}
    }
    intent.outcome = r.outcome;
    intent.reconciled = stale;
    if let Some(observation) = &r.observation {
        intent.observation = Some(observation.clone());
    }
    if !intent.open() {
        intent.completed_at = Some(at);
    }
    let rows = state::array_mut(path, doc, "intents")?;
    let row = state::element_mut(path, rows, index, "intents")?;
    state::set(row, "outcome", serde_json::to_value(r.outcome)?);
    if let Some(completed_at) = &intent.completed_at {
        state::set(row, "completed_at", completed_at.as_str());
    }
    if let Some(observation) = &r.observation {
        state::set(row, "observation", observation.clone());
    }
    if let Some(reconciled) = stale {
        state::set(row, "reconciled", serde_json::to_value(reconciled)?);
        if let Some(status) = intent.observed_status {
            state::set(row, "observed_status", status.word());
        }
        if let Some(generation) = intent.observed_generation {
            state::set(row, "observed_generation", generation);
        }
    }
    recorded.reconciled = stale;
    recorded.intent = intent;
    Ok(recorded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{FleetState, fixtures};
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    const ENV: Env = Env {
        now_secs: 1_769_700_000,
        now_nanos: 1_769_700_000_123_456_789,
        nonce: 4242,
    };
    const LOCK: Locking = Locking::FLOCK;

    /// The nonces `run` mints: one per call, as one process mints one `Env`
    /// per request, so two calls never replay a stamp.
    static NONCES: AtomicU32 = AtomicU32::new(ENV.nonce + 1);

    fn item_file(dir: &Path) -> PathBuf {
        let path = dir.join("workflow-state-KEN-4687.json");
        fs::write(&path, fixtures::ITEM).unwrap();
        path
    }

    fn fleet_file(dir: &Path) -> PathBuf {
        let path = dir.join(state::FLEET_FILE_NAME);
        fs::write(&path, fixtures::FLEET).unwrap();
        path
    }

    /// The fleet fixture on either stamp: as checked in (decision 33, every
    /// pre-cutover operation runs on such a file) or after `migrate`.
    fn fleet_file_with(dir: &Path, stamp: Stamp) -> PathBuf {
        let path = fleet_file(dir);
        match stamp {
            Stamp::Legacy => {}
            Stamp::Stamped { .. } => {
                state::migrate(&path, LOCK).unwrap();
            }
        }
        path
    }

    /// The two stamps every fleet sequence must complete on.
    const STAMPS: [Stamp; 2] = [
        Stamp::Legacy,
        Stamp::Stamped {
            record_version: state::RECORD_VERSION,
            revision: 1,
        },
    ];

    /// Apply `request` as one call of the runtime: a fresh stamp each time.
    fn run(path: &Path, request: &Request) -> Result<Applied> {
        let env = Env {
            nonce: NONCES.fetch_add(1, Ordering::Relaxed),
            ..ENV
        };
        apply(path, request, &env, LOCK)
    }

    /// The id of the intent a launch, close or transfer report carries.
    fn intent_id(applied: &Applied) -> String {
        let effect = match &applied.report {
            Report::LaunchLane(l) => &l.effect,
            Report::CloseOwnedResources(c) => &c.effect,
            Report::RequestTransfer(t) => &t.effect,
            other => panic!("no intent on {other:?}"),
        };
        match effect {
            Effect::Reconciled { intent }
            | Effect::Persisted { intent }
            | Effect::Supersedes { intent } => intent.id.clone(),
        }
    }

    /// Run `request`, which creates or reconciles an intent, and return its
    /// id.
    fn intend(path: &Path, request: &Request) -> String {
        intent_id(&run(path, request).unwrap())
    }

    fn object(path: &Path) -> Document {
        match serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap() {
            Value::Object(map) => map,
            other => panic!("not an object: {other}"),
        }
    }

    fn item(path: &Path) -> ItemState {
        ItemState::view(path, &object(path)).unwrap()
    }

    fn fleet(path: &Path) -> FleetState {
        FleetState::view(path, &object(path)).unwrap()
    }

    fn lane(path: &Path, item: &str) -> Lane {
        fleet(path)
            .lanes
            .into_iter()
            .find(|l| l.item == item)
            .unwrap()
    }

    fn lane_doc(path: &Path, item: &str) -> Document {
        let doc = object(path);
        doc["lanes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|l| l["item"] == item)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    fn keys(doc: &Document) -> Vec<String> {
        doc.keys().cloned().collect()
    }

    /// A launch request that names only what every launch must.
    fn launch(item: &str) -> Request {
        Request::LaunchLane(Box::new(LaunchLane {
            item: item.into(),
            harness: "claude".into(),
            mail_root: format!("/w/{item}"),
            tracker: None,
            repo: None,
            account: None,
            model: None,
            effort: None,
            kind: None,
            surface: None,
            over_cap: None,
            brief_file: None,
        }))
    }

    fn launch_full(item: &str) -> Request {
        Request::LaunchLane(Box::new(LaunchLane {
            item: item.into(),
            harness: "claude".into(),
            mail_root: format!("/w/{item}"),
            tracker: Some("linear".into()),
            repo: None,
            account: Some("/a/a1".into()),
            model: Some("claude-opus-5-5".into()),
            effort: Some("high".into()),
            kind: None,
            surface: None,
            over_cap: None,
            brief_file: None,
        }))
    }

    fn close(item: &str) -> Request {
        Request::CloseOwnedResources(CloseOwnedResources { item: item.into() })
    }

    fn adopt(item: &str, session: &str, launch: Option<LaunchIdentity>) -> Request {
        Request::AdoptSession(Box::new(AdoptSession {
            item: item.into(),
            session_id: session.into(),
            harness: None,
            launch,
        }))
    }

    fn identity(pane: &str, pid: u64) -> LaunchIdentity {
        LaunchIdentity {
            pane: Some(pane.into()),
            server: Some(41020),
            pid: Some(pid),
            start: Some(format!("ticks:{pid}")),
        }
    }

    fn outcome(id: &str, outcome: Outcome) -> Request {
        Request::RecordOutcome(Box::new(RecordOutcome {
            intent_id: id.into(),
            outcome,
            launch: Some(identity("%12", 6000)),
            session_id: Some("native-1".into()),
            server_start: None,
            server_socket: None,
            window: None,
            tmux_session: None,
            launch_line: None,
            observation: None,
        }))
    }

    /// A confirmation whose `launch` is `launch`, with or without the tmux
    /// server's start.
    fn confirmed_with(
        id: &str,
        launch: Option<LaunchIdentity>,
        server_start: Option<u64>,
    ) -> Request {
        Request::RecordOutcome(Box::new(RecordOutcome {
            intent_id: id.into(),
            outcome: Outcome::Confirmed,
            launch,
            session_id: None,
            server_start,
            server_socket: None,
            window: None,
            tmux_session: None,
            launch_line: None,
            observation: None,
        }))
    }

    /// jq's `. // ""` on one member: the member unless it is absent, `null`
    /// or `false`.
    fn alt(record: &Document, key: &str) -> Value {
        match record.get(key) {
            None | Some(Value::Null) | Some(Value::Bool(false)) => Value::from(""),
            Some(v) => v.clone(),
        }
    }

    /// `ol_owns($server; $start; $session)` as `OL_JQ_DEFS` defines it
    /// (`overseer-launch.sh`) and the watch start applies it to the record
    /// it meets (`watch-overseer-record.sh:150`), member for member, with
    /// jq's typed equality: `ol_names`, the record naming `$server` as the
    /// string `--arg` hands jq, `$session` as its `pane` (or `session`), and
    /// `$start` as its `server_start`'s `tostring`; or `ol_unstarted`, the
    /// same server and session with `server_start` null.
    fn ol_owns(record: &Document, server: &str, start: &str, session: &str) -> bool {
        let names_server_and_session = alt(record, "server") == server
            && (match record.get("pane") {
                None | Some(Value::Null) | Some(Value::Bool(false)) => alt(record, "session"),
                Some(pane) => pane.clone(),
            }) == session;
        let jq_tostring = |v: &Value| match v {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        let ol_names = names_server_and_session
            && jq_tostring(record.get("server_start").unwrap_or(&Value::Null)) == start;
        let ol_unstarted =
            names_server_and_session && record.get("server_start").is_none_or(Value::is_null);
        ol_names || ol_unstarted
    }

    fn successor() -> Pending {
        Pending {
            launch_line: Some("cd /r && codex".into()),
            harness: Some("codex".into()),
            account: Some("/a/c2".into()),
            home: Some("/a/c2".into()),
            model: Some("gpt-5.5-codex".into()),
            effort: Some("high".into()),
            cwd: Some("/r".into()),
            class: None,
            extra: Default::default(),
        }
    }

    /// The fixture overseer as the requester saw it. `server` is the string
    /// the legacy writers hand jq through `--arg`; a lane's `launch.server`
    /// is the number `open-terminal` converts.
    fn expected() -> OverseerExpected {
        OverseerExpected {
            server: json!("41020"),
            server_start: json!(1769590000),
            pane: json!("%7"),
            generation: json!(3),
            launch_line: json!(
                "cd /home/u/dev/kendex && CLAUDE_CONFIG_DIR=/home/u/.claude-lanes/a1 claude --model claude-opus-5-5 --effort high"
            ),
            cwd: json!("/home/u/dev/kendex"),
            session_id: None,
            pending: Value::Null,
        }
    }

    fn transfer(expected: OverseerExpected) -> Request {
        Request::RequestTransfer(Box::new(RequestTransfer {
            expected,
            successor: successor(),
            brief_file: None,
        }))
    }

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
            }),
        )
        .unwrap_err();
        assert_eq!(err.key(), "record-missing");
    }

    /// Decision 33: an operation on a legacy file leaves it unstamped and
    /// patches only the keys it writes.
    #[test]
    fn begin_round_mints_supersedes_and_opens_in_one_write() {
        let dir = tempfile::tempdir().unwrap();
        let path = item_file(dir.path());
        let before = object(&path);
        let applied = apply(
            &path,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Dev,
            }),
            &ENV,
            LOCK,
        )
        .unwrap();
        assert_eq!(applied.stamp, Stamp::Legacy);
        let Report::BeginRound(begun) = &applied.report else {
            panic!("{:?}", applied.report)
        };
        assert_eq!(begun.round_id, "1769700000123456789-4242");
        assert_eq!(
            begun.superseded,
            vec![Some("1769600000123456789-1837".to_owned())]
        );
        let after = object(&path);
        assert_eq!(keys(&after), keys(&before), "top-level key sequence");
        for (key, value) in &before {
            if key != "dev_round_id" && key != "stages" {
                assert_eq!(&after[key], value, "{key}");
            }
        }
        let body = item(&path);
        assert_eq!(body.dev_round_id.as_deref(), Some(begun.round_id.as_str()));
        assert_eq!(body.stages.len(), 2);
        assert_eq!(body.stages[0].end, Some(ENV.now_secs));
        assert_eq!(body.stages[0].superseded, Some(true));
        assert_eq!(
            keys(after["stages"][0].as_object().unwrap()),
            ["kind", "round_id", "start", "end", "superseded"]
        );
        assert_eq!(
            keys(after["stages"][1].as_object().unwrap()),
            ["kind", "round_id", "start", "end"]
        );
        assert_eq!(body.stages[1].kind, StageKind::Dev);
        assert_eq!(body.stages[1].start, ENV.now_secs);
        assert_eq!(body.stages[1].end, None);
        // A review round leaves the dev stage open.
        apply(
            &path,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Review,
            }),
            &ENV,
            LOCK,
        )
        .unwrap();
        let body = item(&path);
        assert_eq!(
            body.review_round_id.as_deref(),
            Some("1769700000123456789-4242")
        );
        assert_eq!(body.stages.len(), 3);
        assert_eq!(body.stages[1].end, None);
        assert_eq!(body.stages[2].kind, StageKind::Review);
    }

    #[test]
    fn validation_admission_binds_to_a_round_and_repeats_idempotently() {
        let dir = tempfile::tempdir().unwrap();
        let path = item_file(dir.path());
        let admit = |round: &str, run_dir: &str| {
            Request::RecordValidationAdmission(RecordValidationAdmission {
                round_id: round.into(),
                run_dir: run_dir.into(),
            })
        };
        let err = run(&path, &admit("no-such-round", "tmp/dev-validate-1")).unwrap_err();
        assert_eq!(err.key(), "round-unknown");
        let first = run(
            &path,
            &admit("1769600000123456789-1837", "tmp/dev-validate-1"),
        )
        .unwrap();
        let Report::RecordValidationAdmission(a) = first.report else {
            panic!()
        };
        assert!(a.admitted_now);
        assert_eq!(a.start, ENV.now_secs);
        let later = Env {
            now_secs: ENV.now_secs + 60,
            ..ENV
        };
        let again = apply(
            &path,
            &admit("1769600000123456789-1837", "tmp/dev-validate-1"),
            &later,
            LOCK,
        )
        .unwrap();
        let Report::RecordValidationAdmission(b) = again.report else {
            panic!()
        };
        assert!(!b.admitted_now);
        assert_eq!(b.start, ENV.now_secs);
        let stages = item(&path).stages;
        let validate: Vec<&Stage> = stages
            .iter()
            .filter(|s| s.kind == StageKind::Validate)
            .collect();
        assert_eq!(validate.len(), 1);
        assert_eq!(validate[0].run_dir.as_deref(), Some("tmp/dev-validate-1"));
        assert_eq!(validate[0].end, None);
    }

    #[test]
    fn accept_result_closes_the_round_stage_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = item_file(dir.path());
        let accept = |round: &str| {
            Request::AcceptResult(AcceptResult {
                round_id: round.into(),
                run_dir: None,
            })
        };
        assert_eq!(
            run(&path, &accept("nope")).unwrap_err().key(),
            "round-unknown"
        );
        let applied = run(&path, &accept("1769600000123456789-1837")).unwrap();
        let Report::AcceptResult(a) = applied.report else {
            panic!()
        };
        assert!(a.closed_now);
        assert_eq!((a.start, a.end), (1_769_600_000, ENV.now_secs));
        assert_eq!(a.run_dir, None);
        let again = run(&path, &accept("1769600000123456789-1837")).unwrap();
        let Report::AcceptResult(b) = again.report else {
            panic!()
        };
        assert!(!b.closed_now);
        assert_eq!(b.end, ENV.now_secs);
        // A superseded round's result is history, not the current round's.
        let path = item_file(dir.path());
        run(
            &path,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Dev,
            }),
        )
        .unwrap();
        let err = run(&path, &accept("1769600000123456789-1837")).unwrap_err();
        assert_eq!(err.key(), "round-superseded");
    }

    /// Finding 13: with `run_dir` the accepted result closes the round's
    /// admitted validation stage, not the round's own stage.
    #[test]
    fn accept_result_with_a_run_dir_closes_that_validation_stage() {
        let dir = tempfile::tempdir().unwrap();
        let path = item_file(dir.path());
        let round = "1769600000123456789-1837";
        run(
            &path,
            &Request::RecordValidationAdmission(RecordValidationAdmission {
                round_id: round.into(),
                run_dir: "tmp/dev-validate-1".into(),
            }),
        )
        .unwrap();
        let accept = |run_dir: &str| {
            Request::AcceptResult(AcceptResult {
                round_id: round.into(),
                run_dir: Some(run_dir.into()),
            })
        };
        let err = run(&path, &accept("tmp/dev-validate-9")).unwrap_err();
        assert!(matches!(err, Error::RunUnknown { .. }), "{err}");
        let later = Env {
            now_secs: ENV.now_secs + 30,
            ..ENV
        };
        let applied = apply(&path, &accept("tmp/dev-validate-1"), &later, LOCK).unwrap();
        let Report::AcceptResult(a) = applied.report else {
            panic!()
        };
        assert!(a.closed_now);
        assert_eq!(a.kind, StageKind::Validate);
        assert_eq!(a.run_dir.as_deref(), Some("tmp/dev-validate-1"));
        assert_eq!(a.end, later.now_secs);
        let stages = item(&path).stages;
        assert_eq!(stages[0].kind, StageKind::Dev);
        assert_eq!(stages[0].end, None, "the round's own stage stays open");
        assert_eq!(stages[1].kind, StageKind::Validate);
        assert_eq!(stages[1].end, Some(later.now_secs));
        let again = apply(&path, &accept("tmp/dev-validate-1"), &ENV, LOCK).unwrap();
        let Report::AcceptResult(b) = again.report else {
            panic!()
        };
        assert!(!b.closed_now);
        assert_eq!(b.end, later.now_secs);
    }

    /// Decision 52: `.verification` is `{head, verdict, reason, source, at}`,
    /// appended on the first write and replaced in place by a later one; a
    /// word that is no verdict, ci-wait's `pending` among them, writes
    /// nothing.
    #[test]
    fn record_verification_writes_the_record_once_and_a_later_write_replaces_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = item_file(dir.path());
        let before = object(&path);
        let verify = |round: Option<&str>, head: &str, verdict: &str| {
            Request::RecordVerification(RecordVerification {
                round_id: round.map(str::to_owned),
                head: head.into(),
                verdict: verdict.into(),
                reason: format!(
                    "no CI configured: no active workflows and no required checks on main ({verdict})"
                ),
                source: "ci-wait --required-only".into(),
            })
        };
        let first = apply(
            &path,
            &verify(None, "a".repeat(40).as_str(), "none"),
            &ENV,
            LOCK,
        )
        .unwrap();
        let Report::RecordVerification(a) = first.report else {
            panic!("{:?}", first.report)
        };
        assert!(!a.replaced);
        assert_eq!(a.verdict, "none");
        assert_eq!(a.at, ENV.iso());
        let after = object(&path);
        let mut expected_keys = keys(&before);
        expected_keys.push("verification".to_owned());
        assert_eq!(keys(&after), expected_keys, "the record is appended once");
        for (key, value) in &before {
            assert_eq!(&after[key], value, "{key}");
        }
        let record = after["verification"].as_object().unwrap();
        assert_eq!(keys(record), ["head", "verdict", "reason", "source", "at"]);
        assert_eq!(record["head"], "a".repeat(40));
        assert_eq!(record["verdict"], "none");
        assert_eq!(record["source"], "ci-wait --required-only");
        assert_eq!(record["at"], ENV.iso());

        // A later head's verdict replaces the record where it stands.
        let later = Env {
            now_secs: ENV.now_secs + 90,
            ..ENV
        };
        let second = apply(
            &path,
            &verify(None, "b".repeat(40).as_str(), "pass"),
            &later,
            LOCK,
        )
        .unwrap();
        let Report::RecordVerification(b) = second.report else {
            panic!("{:?}", second.report)
        };
        assert!(b.replaced);
        assert_eq!(b.at, later.iso());
        let again = object(&path);
        assert_eq!(keys(&again), keys(&after), "one record, in its place");
        assert_eq!(again["verification"]["head"], "b".repeat(40));
        assert_eq!(again["verification"]["verdict"], "pass");
        assert_eq!(again["verification"]["at"], later.iso());

        // A word that is no verdict is refused and writes nothing: ci-wait's
        // `pending` names a wait that ended without a result.
        let text = fs::read_to_string(&path).unwrap();
        for word in ["pending", "green", "PASS", ""] {
            let err = run(&path, &verify(None, "c".repeat(40).as_str(), word)).unwrap_err();
            assert_eq!(err.key(), "verdict-invalid", "{word:?}");
            assert_eq!(
                err.fields(),
                vec![("verdict".to_owned(), word.to_owned())],
                "{word:?}"
            );
            assert_eq!(fs::read_to_string(&path).unwrap(), text, "{word:?}");
        }
        // A round named must be one the item ran.
        let err = run(
            &path,
            &verify(Some("no-such-round"), "d".repeat(40).as_str(), "fail"),
        )
        .unwrap_err();
        assert_eq!(err.key(), "round-unknown");
        assert_eq!(fs::read_to_string(&path).unwrap(), text);
        let bound = run(
            &path,
            &verify(
                Some("1769600000123456789-1837"),
                "d".repeat(40).as_str(),
                "fail",
            ),
        )
        .unwrap();
        let Report::RecordVerification(c) = bound.report else {
            panic!("{:?}", bound.report)
        };
        assert!(c.replaced);
        assert_eq!(object(&path)["verification"]["verdict"], "fail");
    }

    #[test]
    fn launch_lane_writes_the_legacy_record_and_the_intent_then_reconciles() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let applied = apply(&path, &launch_full("KEN-4468"), &ENV, LOCK).unwrap();
        assert_eq!(applied.stamp, Stamp::Legacy);
        let Report::LaunchLane(l) = &applied.report else {
            panic!()
        };
        assert_eq!(l.lane.status, LaneStatus::Preparing);
        assert_eq!(l.lane.launched_at.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(l.lane.running_at, None);
        assert_eq!(
            l.lane.harness.as_deref(),
            Some("claude"),
            "a first launch records it"
        );
        assert_eq!(l.lane.account.as_deref(), Some("/a/a1"));
        let Effect::Persisted { intent } = &l.effect else {
            panic!("{:?}", l.effect)
        };
        // The id is the op, the target and the call's own stamp, so it does
        // not depend on the file's revision (0 on every unstamped file).
        assert_eq!(intent.id, "launch-lane:KEN-4468:1769700000123456789-4242");
        assert_eq!(intent.outcome, Outcome::NotStarted);
        assert_eq!(intent.expected_revision, 0);
        assert_eq!(intent.lane_since.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(
            intent.selection,
            Some(Selection {
                harness: "claude".into(),
                account: Some("/a/a1".into()),
                model: Some("claude-opus-5-5".into()),
                effort: Some("high".into()),
            })
        );
        // The appended record has `lane_record_write`'s keys in its order.
        let record = lane_doc(&path, "KEN-4468");
        assert_eq!(
            keys(&record),
            [
                "item",
                "tracker",
                "repo",
                "harness",
                "window",
                "account",
                "host",
                "kind",
                "mail_root",
                "surface",
                "model",
                "effort",
                "session_id",
                "session_since",
                "launched_at",
                "running_at",
                "status",
                "over_cap",
                "launch"
            ]
        );
        assert_eq!(record["kind"], Value::from("local"));
        assert_eq!(record["surface"], Value::from("tmux"));
        assert_eq!(record["repo"], Value::Null);
        let body = fleet(&path);
        assert_eq!(body.lanes.len(), 2);
        assert_eq!(body.intents.len(), 1);
        // The repeat finds the open intent and creates nothing.
        let again = run(&path, &launch_full("KEN-4468")).unwrap();
        let Report::LaunchLane(l) = &again.report else {
            panic!()
        };
        assert!(matches!(&l.effect, Effect::Reconciled { intent: i } if i.id == intent.id));
        let body = fleet(&path);
        assert_eq!(body.intents.len(), 1);
        assert_eq!(body.lanes.len(), 2);
    }

    /// Finding 5, probe P12, and decision 37: a parked lane relaunches;
    /// only `preparing` and `running` refuse.
    #[test]
    fn launch_lane_refuses_only_a_preparing_or_running_lane() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let rows = [
            (LaneStatus::Preparing, Some("lane-live")),
            (LaneStatus::Running, Some("lane-live")),
            (LaneStatus::Parked, None),
            (LaneStatus::Stopped, None),
            (LaneStatus::Done, None),
        ];
        for (status, refusal) in rows {
            fs::write(
                &path,
                fixtures::FLEET.replacen("\"done\"", &format!("\"{}\"", status.word()), 1),
            )
            .unwrap();
            let result = run(&path, &launch("KEN-4437"));
            match refusal {
                Some(key) => {
                    let err = result.unwrap_err();
                    assert_eq!(err.key(), key, "{}", status.word());
                    assert!(matches!(err, Error::LaneLive { status: s, .. } if s == status));
                    assert!(fleet(&path).intents.is_empty(), "{}", status.word());
                }
                None => {
                    result.unwrap();
                    let body = fleet(&path);
                    assert_eq!(body.lanes.len(), 1, "{}", status.word());
                    assert_eq!(body.lanes[0].status, LaneStatus::Preparing);
                    assert_eq!(body.intents.len(), 1);
                }
            }
        }
    }

    /// Decision 57: a lane launch naming a non-local `kind` or a non-tmux
    /// `surface` is refused before any intent persists; the one launch route
    /// is a local tmux window.
    #[test]
    fn launch_lane_refuses_a_non_local_kind_or_surface() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let before = fs::read_to_string(&path).unwrap();
        let rows: [(Option<&str>, Option<&str>); 3] = [
            (Some("ssh"), None),
            (None, Some("gui")),
            (Some("managed-cloud"), Some("gui")),
        ];
        for (kind, surface) in rows {
            let req = Request::LaunchLane(Box::new(LaunchLane {
                item: "KEN-9".into(),
                harness: "claude".into(),
                mail_root: "/w/KEN-9".into(),
                tracker: None,
                repo: None,
                account: None,
                model: None,
                effort: None,
                kind: kind.map(str::to_owned),
                surface: surface.map(str::to_owned),
                over_cap: None,
                brief_file: None,
            }));
            let err = run(&path, &req).unwrap_err();
            assert_eq!(err.key(), "host-unsupported", "{kind:?} {surface:?}");
        }
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            before,
            "no intent persisted on a refused host"
        );
        // `local`/`tmux` named explicitly is admitted.
        let req = Request::LaunchLane(Box::new(LaunchLane {
            item: "KEN-9".into(),
            harness: "claude".into(),
            mail_root: "/w/KEN-9".into(),
            tracker: None,
            repo: None,
            account: None,
            model: None,
            effort: None,
            kind: Some("local".into()),
            surface: Some("tmux".into()),
            over_cap: None,
            brief_file: None,
        }));
        assert!(run(&path, &req).is_ok());
    }

    /// Finding 5, probe P13, and decision 37: a relaunch keeps every field
    /// it does not write, drops `prepare` and `live_display`, and keeps the
    /// key sequence of what it keeps. R-U10 finding 3: the harness, account,
    /// model and effort it was asked for reach the record when the launch
    /// confirms, not at `preparing`. R-U13 finding 4: the confirmation
    /// writes all four as the legacy `running` write does, null where the
    /// request named none, so a claude session is never recorded on the
    /// earlier codex session's account.
    #[test]
    fn a_relaunch_keeps_unwritten_fields_and_its_confirmation_writes_the_whole_selection() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let text = fixtures::FLEET
            .replacen("\"status\": \"done\"", "\"status\": \"stopped\"", 1)
            .replacen("\"kind\": \"local\"", "\"kind\": \"claude-cloud\"", 1)
            .replacen("\"surface\": \"tmux\"", "\"surface\": \"cloud\"", 1)
            .replacen("\"over_cap\": null", "\"over_cap\": \"cloud\"", 1)
            .replacen(
                "\"session_id\": null,\n      \"session_since\"",
                "\"session_id\": \"cloud-7\",\n      \"session_since\"",
                1,
            )
            .replacen(
                "      \"launch\": {",
                "      \"prepare\": {\"since\": \"2026-10-24T18:00:00Z\", \"log\": \"/tmp/p.log\", \"reason\": \"sandbox\", \"pid\": 4100},\n      \"live_display\": true,\n      \"launch\": {",
                1,
            );
        fs::write(&path, &text).unwrap();
        let before = lane_doc(&path, "KEN-4437");
        assert!(before.contains_key("prepare") && before.contains_key("live_display"));
        let id = intend(&path, &launch("KEN-4437"));
        let after = lane_doc(&path, "KEN-4437");
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.status, LaneStatus::Preparing);
        assert_eq!(view.kind.as_deref(), Some("claude-cloud"));
        assert_eq!(view.surface.as_deref(), Some("cloud"));
        assert_eq!(view.over_cap.as_deref(), Some("cloud"));
        assert_eq!(view.account.as_deref(), Some("/home/u/.codex-lanes/c2"));
        assert_eq!(view.model.as_deref(), Some("gpt-5.5-codex"));
        assert_eq!(view.effort.as_deref(), Some("high"));
        assert_eq!(view.tracker.as_deref(), Some("linear"));
        assert_eq!(view.session_id.as_deref(), Some("cloud-7"));
        assert_eq!(view.launched_at.as_deref(), Some("2026-10-24T18:02:11Z"));
        assert_eq!(view.session_since.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(
            view.harness.as_deref(),
            Some("codex"),
            "the record's until the launch confirms"
        );
        assert_eq!(view.mail_root.as_deref(), Some("/w/KEN-4437"));
        assert_eq!(view.running_at, None);
        assert_eq!(view.launch, None);
        assert_eq!(view.extra["tier"], Value::from("small"));
        assert_eq!(view.extra["recovery"]["refresh"], Value::Bool(true));
        assert!(!after.contains_key("prepare"));
        assert!(!after.contains_key("live_display"));
        let expected: Vec<String> = keys(&before)
            .into_iter()
            .filter(|k| k != "prepare" && k != "live_display")
            .collect();
        assert_eq!(keys(&after), expected, "kept keys keep their sequence");
        // The confirmed launch writes the whole selection: the harness it
        // was asked for, and null for the account, model and effort the
        // request left out, as `lane_record_write` does at `running`
        // (`open-terminal`, `map_values(if . == "" then null …)`). A claude
        // session after a codex one carries no codex account.
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.status, LaneStatus::Running);
        assert_eq!(view.harness.as_deref(), Some("claude"));
        let doc = lane_doc(&path, "KEN-4437");
        for key in ["account", "model", "effort"] {
            assert_eq!(doc.get(key), Some(&Value::Null), "{key} written null");
        }
        assert_eq!(keys(&doc), expected, "nulled keys keep their place");
        // A request that supplies a field writes it, at `running` too.
        fs::write(&path, &text).unwrap();
        let id = intend(&path, &launch_full("KEN-4437"));
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.account.as_deref(), Some("/home/u/.codex-lanes/c2"));
        assert_eq!(view.model.as_deref(), Some("gpt-5.5-codex"));
        assert_eq!(view.harness.as_deref(), Some("codex"));
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.harness.as_deref(), Some("claude"));
        assert_eq!(view.account.as_deref(), Some("/a/a1"));
        assert_eq!(view.model.as_deref(), Some("claude-opus-5-5"));
        assert_eq!(view.effort.as_deref(), Some("high"));
        assert_eq!(view.kind.as_deref(), Some("claude-cloud"), "not supplied");
        // A relaunch that fails leaves the record's harness, account and
        // model as they were: no session of the requested ones ran.
        fs::write(&path, &text).unwrap();
        let id = intend(&path, &launch_full("KEN-4437"));
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        let view = lane(&path, "KEN-4437");
        assert_eq!(view.status, LaneStatus::Stopped);
        assert_eq!(view.harness.as_deref(), Some("codex"));
        assert_eq!(view.account.as_deref(), Some("/home/u/.codex-lanes/c2"));
        assert_eq!(view.model.as_deref(), Some("gpt-5.5-codex"));
    }

    #[test]
    fn adopt_session_binds_a_prepared_lane_and_refuses_another_running_session() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &launch("KEN-4468"));
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        let bound = |item: &str, session: &str| adopt(item, session, Some(identity("%11", 5000)));
        assert_eq!(
            run(&path, &bound("KEN-none", "s1")).unwrap_err().key(),
            "lane-missing"
        );
        assert_eq!(
            run(&path, &bound("KEN-4437", "s1")).unwrap_err().key(),
            "lane-done"
        );
        let applied = run(&path, &bound("KEN-4468", "s1")).unwrap();
        let Report::AdoptSession(a) = applied.report else {
            panic!()
        };
        assert!(a.adopted_now);
        assert_eq!(a.lane.status, LaneStatus::Running);
        assert_eq!(a.lane.running_at.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(a.lane.launch.as_ref().unwrap().pid, Some(5000));
        let Report::AdoptSession(b) = run(&path, &bound("KEN-4468", "s1")).unwrap().report else {
            panic!()
        };
        assert!(!b.adopted_now);
        let err = run(&path, &bound("KEN-4468", "s2")).unwrap_err();
        assert!(matches!(
            err,
            Error::LaneLive {
                status: LaneStatus::Running,
                ..
            }
        ));
    }

    /// Finding 8, probe P14, and decision 37: adopting a parked lane runs
    /// the legacy `unpark`, and adopting without `launch` keeps the recorded
    /// identity.
    #[test]
    fn adopting_a_parked_lane_unparks_it_and_keeps_the_launch_when_none_is_passed() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let text = fixtures::FLEET
            .replacen("\"status\": \"done\"", "\"status\": \"parked\"", 1)
            .replacen(
                "      \"launch\": {",
                "      \"parked\": {\"pr\": 5814, \"repo\": \"bmethod/kendex\", \"head\": \"abc123\", \"until_pr\": 5820, \"at\": \"2026-10-24T20:00:00Z\"},\n      \"launch\": {",
                1,
            );
        fs::write(&path, &text).unwrap();
        let before = lane_doc(&path, "KEN-4437");
        run(&path, &adopt("KEN-4437", "s9", None)).unwrap();
        let after = lane_doc(&path, "KEN-4437");
        assert_eq!(after["status"], Value::from("running"));
        assert_eq!(after["session_id"], Value::from("s9"));
        assert!(!after.contains_key("parked"));
        assert_eq!(
            after["pending_pr"],
            json!({"pr": 5814, "repo": "bmethod/kendex", "head": "abc123", "until_pr": 5820})
        );
        assert_eq!(
            after["pauses"],
            json!([{"from": "2026-10-24T20:00:00Z", "to": "2026-01-29T15:20:00Z", "cause": "parked"}])
        );
        assert_eq!(after["launch"], before["launch"], "the wake keeps `launch`");
        assert_eq!(after["launch"]["pid"], Value::from(42210));
        // Only `parked` left the sequence; `pending_pr` and `pauses` appended.
        let mut expected: Vec<String> = keys(&before)
            .into_iter()
            .filter(|k| k != "parked")
            .collect();
        expected.extend(["pauses".to_owned(), "pending_pr".to_owned()]);
        assert_eq!(keys(&after), expected);
    }

    /// Finding 6, probe P11b, and decision 37: the compare-and-swap judges
    /// the legacy identity set, and a standing `pending` the requester names
    /// is overwritten and kept for restore.
    #[test]
    fn request_transfer_compares_the_legacy_identity_set() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let drifted = fixtures::FLEET
            .replacen("\"pane\": \"%7\"", "\"pane\": \"%9\"", 1)
            .replacen("\"server\": \"41020\"", "\"server\": \"41999\"", 1);
        fs::write(&path, &drifted).unwrap();
        let err = run(&path, &transfer(expected())).unwrap_err();
        let Error::OverseerChanged { fields, .. } = &err else {
            panic!("{err:?}")
        };
        assert_eq!(fields, &["server", "pane"]);
        assert!(fleet(&path).intents.is_empty());
        assert!(fleet(&path).overseer.unwrap().pending.is_none());

        fs::write(&path, fixtures::FLEET).unwrap();
        let mut wrong_generation = expected();
        wrong_generation.generation = json!(2);
        let err = run(&path, &transfer(wrong_generation)).unwrap_err();
        assert!(
            matches!(&err, Error::OverseerChanged { fields, .. } if fields == &["generation"]),
            "{err:?}"
        );
        let mut wrong_session = expected();
        wrong_session.session_id = Some("another-session".into());
        let err = run(&path, &transfer(wrong_session)).unwrap_err();
        assert!(
            matches!(&err, Error::OverseerChanged { fields, .. } if fields == &["session_id"]),
            "{err:?}"
        );
        let mut same_session = expected();
        same_session.session_id = Some("0f3d2c1b-9a8e-4d7c-b6a5-443322110000".into());
        let applied = run(&path, &transfer(same_session)).unwrap();
        let Report::RequestTransfer(t) = &applied.report else {
            panic!()
        };
        assert_eq!(t.generation, 3);
        let Effect::Persisted { intent } = &t.effect else {
            panic!()
        };
        assert_eq!(intent.target, "overseer:3");
        assert_eq!(intent.original_pending, None);
        let before = object(&path);
        let overseer = fleet(&path).overseer.unwrap();
        assert_eq!(overseer.pending, Some(successor()));
        assert_eq!(overseer.generation, Some(3));
        assert_eq!(overseer.extra["pane"], Value::from("%7"));
        let overseer_keys = keys(before["overseer"].as_object().unwrap());
        assert_eq!(overseer_keys.last().unwrap(), "pending", "appended");
        // The repeat reconciles the open intent.
        let again = run(&path, &transfer(expected())).unwrap();
        let Report::RequestTransfer(t) = &again.report else {
            panic!()
        };
        assert!(matches!(&t.effect, Effect::Reconciled { .. }));
        assert_eq!(fleet(&path).intents.len(), 1);

        // A pending another writer left: the requester must name it, and the
        // original is kept on the intent for restore.
        let standing = fixtures::FLEET.replacen(
            "\"generation\": 3,",
            "\"generation\": 3, \"pending\": {\"harness\": \"codex\"},",
            1,
        );
        fs::write(&path, &standing).unwrap();
        let err = run(&path, &transfer(expected())).unwrap_err();
        assert!(
            matches!(&err, Error::OverseerChanged { fields, .. } if fields == &["pending"]),
            "{err:?}"
        );
        let mut names_pending = expected();
        names_pending.pending = json!({"harness": "codex"});
        let applied = run(&path, &transfer(names_pending)).unwrap();
        let Report::RequestTransfer(t) = &applied.report else {
            panic!()
        };
        let Effect::Persisted { intent } = &t.effect else {
            panic!()
        };
        assert_eq!(intent.original_pending, Some(json!({"harness": "codex"})));
        assert_eq!(fleet(&path).overseer.unwrap().pending, Some(successor()));
        // The failed transfer puts the original back.
        run(&path, &outcome(&intent.id, Outcome::Failed)).unwrap();
        let overseer = object(&path)["overseer"].clone();
        assert_eq!(overseer["pending"], json!({"harness": "codex"}));
        assert_eq!(overseer["generation"], json!(3));

        let no_overseer = fixtures::FLEET.replacen("\"overseer\"", "\"overseer_was\"", 1);
        fs::write(&path, no_overseer).unwrap();
        let err = run(&path, &transfer(expected())).unwrap_err();
        assert_eq!(err.key(), "overseer-missing");
        assert_eq!(err.fields()[0].0, "path");
    }

    /// The fixture fleet with a predecessor that died once and was
    /// model-checked: both records the successor's record must not carry.
    fn fleet_with_exit_and_model_check() -> String {
        fixtures::FLEET.replacen(
            "    \"harness_start\": \"ticks:9912345\",\n",
            "    \"harness_start\": \"ticks:9912345\",\n    \"exit\": {\"at\": \"2026-10-24T21:00:00Z\", \"code\": 0},\n    \"model_check\": {\"at\": \"2026-10-24T20:30:00Z\", \"model\": \"claude-opus-5-5\"},\n",
            1,
        )
    }

    /// Finding 4, probe P11, decision 37 and R-U13 finding 1: the confirmed
    /// transfer writes the record `ol_record_write` writes for a session
    /// other than the prior, field by field. The expected object is that
    /// writer's result for the fixture's predecessor and the test successor:
    /// Decision 62: an effect's phase is written onto its open intent before
    /// the effect waits, a later phase replaces it, and a closed intent
    /// takes none.
    #[test]
    fn record_phase_writes_the_open_intent_s_phase_and_refuses_a_closed_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        fs::write(&path, fixtures::FLEET).unwrap();
        let id = intend(&path, &transfer(expected()));
        let opened = state::OpenedPane {
            pane: "%12".into(),
            server: 41020,
            server_start: 1_769_590_000,
            server_process_start: Some("ticks:7".into()),
            socket: "/tmp/tmux-1000/default".into(),
            since_ms: 1,
            brief: Some("/h/handoff.md".into()),
            session_id: Some("0f6e".into()),
            baseline: Vec::new(),
        };
        let session = state::BoundSession {
            session_id: "0f6e".into(),
            file: "/h/projects/-w/0f6e.jsonl".into(),
        };
        let phase = |phase: Phase| {
            Request::RecordPhase(RecordPhase {
                intent_id: id.clone(),
                phase,
            })
        };
        let applied = run(
            &path,
            &phase(Phase::WindowOpened {
                opened: opened.clone(),
            }),
        )
        .unwrap();
        let Report::RecordPhase(p) = &applied.report else {
            panic!()
        };
        let window_opened = Some(Phase::WindowOpened {
            opened: opened.clone(),
        });
        assert_eq!(p.intent.phase, window_opened);
        let stored = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap();
        assert_eq!(stored.phase, window_opened);
        let row = object(&path)["intents"][0]["phase"].clone();
        assert_eq!(row["phase"], json!("window-opened"));
        assert_eq!(row["pane"], json!("%12"));
        assert_eq!(row["brief"], json!("/h/handoff.md"));
        run(
            &path,
            &phase(Phase::Delivered {
                opened: opened.clone(),
                turns_before: 2,
                session: session.clone(),
            }),
        )
        .unwrap();
        let stored = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap();
        assert_eq!(
            stored.phase,
            Some(Phase::Delivered {
                opened: opened.clone(),
                turns_before: 2,
                session,
            })
        );
        let row = object(&path)["intents"][0]["phase"].clone();
        assert_eq!(row["session"]["file"], json!("/h/projects/-w/0f6e.jsonl"));
        assert_eq!(row["server_process_start"], json!("ticks:7"));
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        let err = run(&path, &phase(Phase::Retired { opened })).unwrap_err();
        assert!(matches!(err, Error::IntentComplete { .. }), "{err:?}");
    }

    /// its identity (nulls where the pending names none), `class` only where
    /// the pending carries one, the next generation, the successor's own
    /// `pane` and `server` from the confirmation (the server as the string
    /// the legacy `--arg` writes), `server_start` where the confirmation
    /// carries it and null otherwise, `window` and `session_rows` null for
    /// the successor's watch start to fill, and none of the ended session's
    /// `session_id`, `harness_pid`, `harness_start`, `model_check`, `exit` or
    /// `pending`. Keys keep their place (decision 34); the expected sequence
    /// below is the fixture's with the dropped keys gone.
    #[test]
    fn a_confirmed_transfer_publishes_the_successor_identity_bound_to_its_own_pane() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let text = fleet_with_exit_and_model_check();
        fs::write(&path, &text).unwrap();
        let before = object(&path)["overseer"].as_object().unwrap().clone();
        assert!(before.contains_key("exit") && before.contains_key("model_check"));
        let id = intend(&path, &transfer(expected()));
        let applied = run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let Report::RecordOutcome(r) = &applied.report else {
            panic!()
        };
        assert_eq!(r.generation, Some(4));
        let after = object(&path)["overseer"].as_object().unwrap().clone();
        let legacy = json!({
            "runtime": "tmux",
            "generation": 4,
            "server": "41020",
            "server_start": null,
            "server_socket": "/tmp/tmux-1000/default",
            "pane": "%12",
            "window": null,
            "session_rows": null,
            "harness": "codex",
            "account": "/a/c2",
            "home": "/a/c2",
            "model": "gpt-5.5-codex",
            "effort": "high",
            "cwd": "/r",
            "launch_line": "cd /r && codex",
            // The runtime launched the successor and read its process
            // identity, so it writes these now, appended as `ol_record_start`
            // appends them (task 1, decision 58). `outcome` carries pid 6000.
            "harness_pid": 6000,
            "harness_start": "ticks:6000",
        });
        let legacy = legacy.as_object().unwrap();
        assert_eq!(keys(&after), keys(legacy), "key sequence");
        for (key, value) in legacy {
            assert_eq!(after.get(key), Some(value), "{key}");
        }
        assert_eq!(&after, legacy);
        // A confirmation that knows the successor's server start records it
        // as the number `ol_record_write` writes (`$start | tonumber`).
        fs::write(&path, &text).unwrap();
        let id = intend(&path, &transfer(expected()));
        run(
            &path,
            &confirmed_with(&id, Some(identity("%20", 7000)), Some(1_769_600_000)),
        )
        .unwrap();
        let after = object(&path)["overseer"].as_object().unwrap().clone();
        assert_eq!(after["pane"], Value::from("%20"));
        assert_eq!(after["server"], Value::from("41020"));
        assert_eq!(after["server_start"], Value::from(1_769_600_000_u64));
        assert_eq!(keys(&after), keys(legacy), "key sequence");
        // A successor whose pending carries a class and a cwd the pending
        // leaves out: `class` is written in place, `cwd` nulled.
        fs::write(&path, &text).unwrap();
        let mut classed = successor();
        classed.class = Some("gpt".into());
        classed.cwd = None;
        let id = intend(
            &path,
            &Request::RequestTransfer(Box::new(RequestTransfer {
                expected: expected(),
                successor: classed,
                brief_file: None,
            })),
        );
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let after = object(&path)["overseer"].as_object().unwrap().clone();
        assert_eq!(after["class"], Value::from("gpt"));
        assert_eq!(after["cwd"], Value::Null);
        let mut with_class = keys(legacy);
        with_class.insert(
            with_class.iter().position(|k| k == "effort").unwrap(),
            "class".into(),
        );
        assert_eq!(
            keys(&after),
            with_class,
            "class keeps the predecessor's place"
        );
    }

    /// R-U13 finding 1: a transfer's confirmation is the successor's
    /// identity. One that names no launch, or a launch without a pane or a
    /// server, refuses `launch-missing` naming the absent member, writes
    /// nothing and leaves the intent open for a confirmation that does.
    #[test]
    fn a_transfer_confirmation_without_the_successor_pane_on_a_server_refuses_launch_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &transfer(expected()));
        let before = fs::read_to_string(&path).unwrap();
        let rows: [(Option<LaunchIdentity>, &str); 3] = [
            (None, "launch"),
            (
                Some(LaunchIdentity {
                    pane: None,
                    ..identity("%20", 7000)
                }),
                "pane",
            ),
            (
                Some(LaunchIdentity {
                    server: None,
                    ..identity("%20", 7000)
                }),
                "server",
            ),
        ];
        for (launch, field) in rows {
            let err = run(&path, &confirmed_with(&id, launch, None)).unwrap_err();
            assert_eq!(err.key(), "launch-missing", "{field}");
            let Error::LaunchMissing {
                intent,
                field: named,
            } = &err
            else {
                panic!("{err:?}")
            };
            assert_eq!(intent, &id);
            assert_eq!(*named, field);
            assert_eq!(fs::read_to_string(&path).unwrap(), before, "{field}");
        }
        assert!(fleet(&path).intents[0].open(), "the intent waits");
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        assert_eq!(fleet(&path).overseer.unwrap().generation, Some(4));
    }

    /// R-U13 finding 1: the successor's own watch start keeps the record a
    /// confirmed transfer leaves only where `ol_owns($server; $start;
    /// $pane)` holds for its pane on its server
    /// (`watch-overseer-record.sh:150`), and rebuilds it from `{}`
    /// otherwise, dropping the generation and the identity the confirmation
    /// published. The condition is encoded in `ol_owns` above, without jq.
    #[test]
    fn the_confirmed_transfer_record_is_owned_by_the_successor_pane_on_its_server_unstarted_or_at_its_start()
     {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let text = fleet_with_exit_and_model_check();
        // The fixture's predecessor owns its own record by `ol_names`, and
        // another pane's or another start's watch start does not: the
        // encoding tells the two apart.
        let predecessor = object(&path)["overseer"].as_object().unwrap().clone();
        assert!(ol_owns(&predecessor, "41020", "1769590000", "%7"));
        assert!(!ol_owns(&predecessor, "41020", "1769590000", "%20"));
        assert!(!ol_owns(&predecessor, "41020", "1769590001", "%7"));
        // The record U13 wrote, the binding nulled: no pane names the
        // successor, so its watch start discards it (R-U13's jq replay).
        let mut nulled = predecessor.clone();
        for key in ["pane", "server", "server_start"] {
            nulled.insert(key.to_owned(), Value::Null);
        }
        assert!(!ol_owns(&nulled, "41020", "1769590000", "%20"));
        // Confirmed without the server start: `ol_unstarted` owns it from
        // the successor's pane, at any start the watch reads.
        fs::write(&path, &text).unwrap();
        let id = intend(&path, &transfer(expected()));
        run(
            &path,
            &confirmed_with(&id, Some(identity("%20", 7000)), None),
        )
        .unwrap();
        let after = object(&path)["overseer"].as_object().unwrap().clone();
        assert!(ol_owns(&after, "41020", "1769590000", "%20"), "{after:?}");
        assert!(ol_owns(&after, "41020", "1769600000", "%20"));
        assert!(
            !ol_owns(&after, "41020", "1769590000", "%7"),
            "not the predecessor's"
        );
        assert!(
            !ol_owns(&after, "41021", "1769590000", "%20"),
            "not another server's"
        );
        // Confirmed with the server start: `ol_names` owns it at that start
        // alone, as the register path judges a same-generation record.
        fs::write(&path, &text).unwrap();
        let id = intend(&path, &transfer(expected()));
        run(
            &path,
            &confirmed_with(&id, Some(identity("%20", 7000)), Some(1_769_600_000)),
        )
        .unwrap();
        let after = object(&path)["overseer"].as_object().unwrap().clone();
        assert!(ol_owns(&after, "41020", "1769600000", "%20"), "{after:?}");
        assert!(
            !ol_owns(&after, "41020", "1769590000", "%20"),
            "another start"
        );
    }

    #[test]
    fn close_owned_resources_persists_the_intent_and_leaves_the_status() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        assert_eq!(
            run(&path, &close("KEN-4437")).unwrap_err().key(),
            "lane-done"
        );
        assert_eq!(
            run(&path, &close("KEN-x")).unwrap_err().key(),
            "lane-missing"
        );
        let id = intend(&path, &launch("KEN-4468"));
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let applied = run(&path, &close("KEN-4468")).unwrap();
        let Report::CloseOwnedResources(c) = &applied.report else {
            panic!()
        };
        assert_eq!(c.lane.status, LaneStatus::Running);
        let Effect::Persisted { intent } = &c.effect else {
            panic!()
        };
        assert_eq!(intent.op, EffectOp::CloseOwnedResources);
        assert_eq!(intent.lane_since.as_deref(), Some("2026-01-29T15:20:00Z"));
        assert_eq!(intent.selection, None, "a close carries no selection");
        let again = run(&path, &close("KEN-4468")).unwrap();
        let Report::CloseOwnedResources(c) = &again.report else {
            panic!()
        };
        assert!(matches!(&c.effect, Effect::Reconciled { .. }));
        let body = fleet(&path);
        assert_eq!(body.intents.len(), 2);
        assert_eq!(body.lanes[1].status, LaneStatus::Running);
    }

    /// Every effect kind's outcome, on an unstamped file and on a migrated
    /// one.
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
        for stamp in STAMPS {
            for row in &rows {
                let dir = tempfile::tempdir().unwrap();
                let path = fleet_file_with(dir.path(), stamp);
                let id = (row.setup)(&path);
                let applied = run(&path, &outcome(&id, row.outcome)).unwrap();
                assert_eq!(
                    matches!(applied.stamp, Stamp::Legacy),
                    matches!(stamp, Stamp::Legacy),
                    "{}: {stamp:?}",
                    row.name
                );
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
    }

    /// R-U10 finding 1: the sequences that stuck on an unstamped file when
    /// the id carried the revision. Each completes on both stamps, every
    /// intent closed and no two sharing an id.
    #[test]
    fn intent_sequences_on_one_target_complete_on_either_stamp() {
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
        for stamp in STAMPS {
            for row in &rows {
                let dir = tempfile::tempdir().unwrap();
                let path = fleet_file_with(dir.path(), stamp);
                (row.steps)(&path);
                let intents = fleet(&path).intents;
                assert_eq!(intents.len(), row.intents, "{}: {stamp:?}", row.name);
                assert!(
                    intents.iter().all(|i| !i.open()),
                    "{}: {stamp:?}: every intent closed",
                    row.name
                );
                let mut ids: Vec<&str> = intents.iter().map(|i| i.id.as_str()).collect();
                ids.dedup();
                assert_eq!(
                    ids.len(),
                    row.intents,
                    "{}: {stamp:?}: ids distinct",
                    row.name
                );
                (row.check)(&path);
            }
        }
    }

    /// `intent-duplicate` is reachable only by replaying one `Env` onto the
    /// same target, which a mint never does: a stamp that differs in its
    /// nonce or its nanoseconds appends. The refused write leaves the file
    /// as it was.
    #[test]
    fn a_replayed_stamp_refuses_intent_duplicate_and_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let first = intent_id(&apply(&path, &launch("KEN-4468"), &ENV, LOCK).unwrap());
        apply(&path, &outcome(&first, Outcome::Failed), &ENV, LOCK).unwrap();
        let before = fs::read_to_string(&path).unwrap();
        let err = apply(&path, &launch("KEN-4468"), &ENV, LOCK).unwrap_err();
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
                nonce: ENV.nonce + 1,
                ..ENV
            },
            Env {
                now_nanos: ENV.now_nanos + 1,
                ..ENV
            },
        ] {
            fs::write(&path, &before).unwrap();
            let second = intent_id(&apply(&path, &launch("KEN-4468"), &minted, LOCK).unwrap());
            assert_ne!(second, first);
            assert_eq!(fleet(&path).intents.len(), 2);
        }
    }

    /// Finding 8, probe P15: a confirmed close removes `pending_pr` and
    /// `parked`, as the legacy `update_status done` does.
    #[test]
    fn a_confirmed_close_deletes_the_pr_identities() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let text = fixtures::FLEET
            .replacen("\"status\": \"done\"", "\"status\": \"running\"", 1)
            .replacen(
                "      \"launch\": {",
                "      \"pending_pr\": {\"pr\": 5814, \"repo\": \"bmethod/kendex\", \"head\": \"abc123\"},\n      \"parked\": {\"pr\": 5814, \"repo\": \"bmethod/kendex\", \"head\": \"abc123\", \"at\": \"2026-10-24T20:00:00Z\"},\n      \"launch\": {",
                1,
            );
        fs::write(&path, &text).unwrap();
        let before = lane_doc(&path, "KEN-4437");
        let id = intend(&path, &close("KEN-4437"));
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let after = lane_doc(&path, "KEN-4437");
        assert_eq!(after["status"], Value::from("done"));
        assert!(!after.contains_key("pending_pr"));
        assert!(!after.contains_key("parked"));
        let expected: Vec<String> = keys(&before)
            .into_iter()
            .filter(|k| k != "pending_pr" && k != "parked")
            .collect();
        assert_eq!(keys(&after), expected);
    }

    /// Finding 7, probes A and B, and decision 36: one open intent per
    /// target, and a late outcome on a lane whose record moved refuses.
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
        /// A legacy writer's edit of the lane between two operations.
        fn legacy_edit(path: &Path, item: &str, key: &str, value: Value) {
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
                name: "probe A: a launch while a close intent is open",
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
                // Decision 67: the close supersedes the launch rather than
                // refusing; no second intent is written until the launch
                // intent is closed.
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
            // Decision 44, sequence 1: a legacy `lane-close` moved the lane
            // to done under an open launch intent. The launch's outcome no
            // longer wedges the lane (R-U13 finding 2): it reconciles the
            // intent as `intent-stale` with the observed status and leaves
            // the lane as the legacy writer left it.
            Row {
                name: "probe B: a launch confirmed on a lane closed since reconciles stale",
                steps: |p| {
                    let id = intent_id(&run(p, &launch("KEN-4468"))?);
                    legacy_edit(p, "KEN-4468", "status", Value::from("done"));
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
            // Decision 44, sequence: a lane relaunched under an open close
            // intent. The close's outcome reconciles the intent as stale and
            // leaves the running lane alone, no longer refusing.
            Row {
                name: "a close confirmed on a lane relaunched since reconciles stale",
                steps: |p| {
                    let id = intent_id(&run(p, &launch("KEN-4468"))?);
                    run(p, &outcome(&id, Outcome::Confirmed))?;
                    let id = intent_id(&run(p, &close("KEN-4468"))?);
                    legacy_edit(
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

    /// Finding 3: every fleet operation runs on a file whose `triaged` rows
    /// include the legacy `item`-keyed and string shapes.
    #[test]
    fn fleet_operations_run_on_legacy_triaged_rows() {
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
        state::migrate(&path, LOCK).unwrap();
        let first = state::load(&path).unwrap().unwrap();
        let second = state::load(&path).unwrap().unwrap();
        let mut a = first.doc.clone();
        let report_a = item_transition(
            &path,
            &mut a,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Dev,
            }),
            &ENV,
        )
        .unwrap();
        state::store(&path, &first, &a, LOCK).unwrap();
        let mut b = second.doc.clone();
        let other = Env { nonce: 1, ..ENV };
        item_transition(
            &path,
            &mut b,
            &Request::BeginRound(BeginRound {
                kind: RoundKind::Dev,
            }),
            &other,
        )
        .unwrap();
        let err = state::store(&path, &second, &b, LOCK).unwrap_err();
        assert_eq!(err.key(), "revision-mismatch");
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
                    observation: None,
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
