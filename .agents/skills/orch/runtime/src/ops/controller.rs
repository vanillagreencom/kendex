//! The controller transitions: the seven lifetimes of step4-map § A2 to A8
//! as four operations. `start-controller` opens a controller's lane with no
//! predecessor to retire (first launch, and the launch after an explicit
//! `off`); `adopt-controller` binds a controller a person opened by hand,
//! from an identity the effects read in its pane (decisions 60, 99);
//! `request-transfer` asks for a succession under one of four causes
//! (live, dead, walled, refused-recovery), compared against the record the
//! requester saw; `stop-controller` is the explicit off of decision 78. The
//! `claim-intent` transition hands an open intent's owner lease to the
//! detached job that runs a transfer (decision 76). The outcome arms publish
//! the successor, restore the pending a failed request overwrote, keep a
//! waiting runner, or record `off`.

use std::path::{Path, PathBuf};

use agent_runtime::process::Identity;
use agent_runtime::protocol::Outcome;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{
    Applied, Effect, Env, OutcomeRecorded, RecordOutcome, Report, Request, intents, new_intent,
    null_held, push_intent, same_open_intent, string_or_null,
};
use crate::effects::Recorded;
use crate::error::{Error, Result};
use crate::settings::{Settings, Succession};
use crate::state::{
    self, Document, EffectOp, Intent, Locking, Notice, OVERSEER_COMPARE_KEYS, ObligationRecord,
    Overseer, Owner, PREDECESSOR_SESSION_KEYS, Pending, Phase, SUCCESSOR_BINDING_KEYS,
    SUCCESSOR_IDENTITY_KEYS, TransferCause,
};

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
/// intent to open it, when the record still is what the requester saw. The
/// successor is the judged input (decision 75): the legacy account walk
/// picked it, or the watch read it off the record as the held line.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestTransfer {
    pub expected: OverseerExpected,
    pub successor: Pending,
    /// The successor's opening instruction, the handoff. Not a record
    /// field: the effect carries it to the launch.
    #[serde(default)]
    pub brief_file: Option<PathBuf>,
    /// Why the succession is asked for; `live` when left out.
    #[serde(default)]
    pub cause: TransferCause,
    /// A `walled` succession's spent account: the successor must not
    /// resolve to it.
    #[serde(default)]
    pub exclude_account: Option<String>,
    /// A `refused-recovery` succession's standing handoff names the session
    /// that wrote it; it must be the recorded controller's.
    #[serde(default)]
    pub handoff_session_id: Option<String>,
    /// A model recovery's binding (decision 109 (8)): the record the
    /// recovery was acquired against, as `ol_recovery_bound` reads it. The
    /// transition refuses `recovery-unbound` and writes nothing unless the
    /// record still carries that launch, a `model_check` that read
    /// `switched` for the recorded session, and the same launch identity.
    #[serde(default)]
    pub recovery: Option<Recovery>,
}

/// The launch a model recovery was bound to: the seven fields the legacy
/// `ol_model_launch` projects. A field left out compares as `null`.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Recovery {
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
    pub session_id: Value,
}

/// The keys `ol_model_launch` projects, the launch a recovery is bound to.
pub const MODEL_LAUNCH_KEYS: &[&str] = &[
    "server",
    "server_start",
    "pane",
    "generation",
    "launch_line",
    "cwd",
    "session_id",
];

impl Recovery {
    fn field(&self, key: &str) -> &Value {
        match key {
            "server" => &self.server,
            "server_start" => &self.server_start,
            "pane" => &self.pane,
            "generation" => &self.generation,
            "launch_line" => &self.launch_line,
            "cwd" => &self.cwd,
            "session_id" => &self.session_id,
            _ => unreachable!("MODEL_LAUNCH_KEYS names the seven fields above"),
        }
    }
}

/// The legacy `ol_recovery_bound` predicate on the record as it stands: the
/// record's launch is the request's, its `model_check` read `switched` for
/// the recorded session, and that check's `launch_identity` is the record's
/// launch. The cause names the first clause that fails.
fn recovery_bound(record: &Document, recovery: &Recovery) -> std::result::Result<(), &'static str> {
    let launch = |key: &str| record.get(key).cloned().unwrap_or(Value::Null);
    if MODEL_LAUNCH_KEYS
        .iter()
        .any(|key| &launch(key) != recovery.field(key))
    {
        return Err("launch-changed");
    }
    let Some(check) = record.get("model_check").filter(|v| v.is_object()) else {
        return Err("model-check-missing");
    };
    if check.get("outcome").and_then(Value::as_str) != Some("switched") {
        return Err("model-check-not-switched");
    }
    if check.get("session_id").unwrap_or(&Value::Null) != &launch("session_id") {
        return Err("model-check-session");
    }
    let identity: serde_json::Map<String, Value> = MODEL_LAUNCH_KEYS
        .iter()
        .map(|key| ((*key).to_owned(), launch(key)))
        .collect();
    if check.get("launch_identity") != Some(&Value::Object(identity)) {
        return Err("model-check-identity");
    }
    Ok(())
}

/// A succession recorded as pending.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TransferRequested {
    pub generation: u64,
    pub pending: Pending,
    pub effect: Effect,
}

/// Open a controller's lane where none runs: the first launch, or the launch
/// after an explicit `off`. `controller` is the launch identity and line the
/// legacy launcher built (decision 75); the effect refuses `overseer-live`
/// over a controller it reads live, so no record compare is asked for.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StartController {
    pub controller: Pending,
    #[serde(default)]
    pub brief_file: Option<PathBuf>,
}

/// A start recorded, its controller pending until the launch confirms.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControllerStarted {
    pub generation: u64,
    pub effect: Effect,
}

/// Bind a controller this runtime did not launch: the pane a person opened
/// it in, on the fleet server (or the one `socket` names), and what the
/// person knows of its launch. The identity is read in that pane by the
/// effects (decision 60), never taken from the caller.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AdoptController {
    pub pane: String,
    #[serde(default)]
    pub socket: Option<PathBuf>,
    pub harness: String,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub account: Option<String>,
    #[serde(default)]
    pub home: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
}

/// What the effects read of the pane an adoption names, handed to the
/// transition: the harness identity in its foreground and the server and
/// window the pane is on.
#[derive(Debug, Clone, PartialEq)]
pub struct AdoptionRead {
    pub identity: Identity,
    pub server: u64,
    pub server_start: u64,
    pub socket: String,
    pub window: String,
    /// Whether the record already names this pane on this server
    /// (`ol_owns`): the record is healed, not replaced.
    pub same: bool,
}

/// A controller bound.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControllerAdopted {
    pub generation: u64,
    /// True when the record already named this pane and was healed in
    /// place; false when the record was written for this session.
    pub healed: bool,
}

/// Retire the recorded controller exactly and record `off` (decision 78).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct StopController {}

/// A stop asked for.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StopRequested {
    pub generation: u64,
    pub effect: Effect,
}

/// Take the owner lease of an open intent whose effect has not started
/// (decision 76): the detached job's first act, before it opens anything.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClaimIntent {
    pub intent_id: String,
}

/// The intent under its new owner.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IntentClaimed {
    pub intent: Intent,
}

/// Write an effect's progress into its intent before the wait that follows
/// (decisions 62, 115 (A)): the phase where one moved and the obligation set
/// as it stands, each written on an open intent alone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordProgress {
    pub intent_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<Phase>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obligations: Option<ObligationRecord>,
    /// The owner the launcher-side handle writes under: the write is a no-op
    /// once another owner holds the intent, so a job that claimed between the
    /// launcher's last read and its write keeps its own set (decision 124b);
    /// `apply` retries the transition on a conflicting snapshot (decision
    /// 124d (18)). `None` writes always.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub while_owner: Option<Owner>,
    /// The failure announcement a job's outcome made (decision 109 (7)),
    /// written after the outcome's own write applied (decision 124d (17)):
    /// the fleet-log row is appended in this write and the notice recorded on
    /// the intent, once; an intent that carries one takes no second.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice: Option<Notice>,
}

/// The intent as the progress write left it, and what the store did with
/// the write.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProgressRecorded {
    pub intent: Intent,
    pub progress: Progress,
}

/// What the store did with a progress write (decision 124h (32)): recorded
/// it; accepted it as the intent already stood, so the revision did not
/// move (decision 89); or yielded it to the owner that holds the intent
/// now, writing nothing, where the request named `while_owner` and the
/// intent is another's (decision 124b). An unchanged set under the
/// recorded owner is accepted, never yielded.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Progress {
    Recorded,
    Unchanged,
    Yielded { owner: Owner },
}

/// What `ORCH_OVERSEER_SUCCESSION` admits before any transition runs: a
/// `request-transfer` under `off` refuses `succession-off` and persists
/// nothing (decision 78). Every other request is admitted.
pub fn admit(request: &Request, settings: &Settings) -> Result<()> {
    if let (Request::RequestTransfer(_), Succession::Off) = (request, settings.succession) {
        return Err(Error::SuccessionOff);
    }
    Ok(())
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

/// The overseer view and its document, or `overseer-missing`.
pub(super) fn overseer(path: &Path, doc: &Document) -> Result<Overseer> {
    state::field::<Overseer>(path, doc, "overseer")?.ok_or_else(|| Error::OverseerMissing {
        path: path.to_path_buf(),
    })
}

/// An open intent of another controller operation, or of this one on an
/// earlier generation, refuses: one controller operation at a time, on the
/// one overseer (decision 36). The same operation on the same target is
/// the caller's to reconcile, read before this.
fn no_other_controller_intent(intents: &[Intent], op: EffectOp, target: &str) -> Result<()> {
    match intents
        .iter()
        .find(|i| i.open() && i.op.on_controller() && (i.op != op || i.target != target))
    {
        Some(intent) => Err(Error::IntentOpen {
            intent: intent.id.clone(),
            op: intent.op,
            target: intent.target.clone(),
        }),
        None => Ok(()),
    }
}

/// A controller stopped on purpose refuses every succession (decision 78):
/// only `start-controller` opens one again.
fn refuse_off(path: &Path, current: &Overseer) -> Result<()> {
    if current.extra.get("off").is_some_and(|off| !off.is_null()) {
        return Err(Error::ControllerOff {
            path: path.to_path_buf(),
            generation: current.generation.unwrap_or(0),
        });
    }
    Ok(())
}

/// An account directory as `lane_claims_canon` compares two: resolved
/// through the filesystem where it exists, else the spelling with its
/// trailing slashes dropped.
fn canonical_account(account: &str) -> String {
    match std::fs::canonicalize(account) {
        Ok(path) => path.display().to_string(),
        Err(_) => {
            let mut text = account;
            while text.len() > 1 && text.ends_with('/') {
                text = &text[..text.len() - 1];
            }
            text.to_owned()
        }
    }
}

/// What a cause requires of the request beyond the compare-and-swap.
fn check_cause(r: &RequestTransfer, current: &Overseer) -> Result<()> {
    match r.cause {
        TransferCause::Live | TransferCause::Dead => Ok(()),
        TransferCause::Walled => {
            let spent = r
                .exclude_account
                .as_deref()
                .ok_or(Error::TransferFieldMissing {
                    cause: "walled",
                    field: "exclude_account",
                })?;
            let account = r
                .successor
                .account
                .as_deref()
                .or(r.successor.home.as_deref())
                .unwrap_or_default();
            if canonical_account(account) == canonical_account(spent) {
                return Err(Error::SuccessorAccountSpent {
                    account: account.to_owned(),
                });
            }
            Ok(())
        }
        TransferCause::RefusedRecovery => {
            let expected = r
                .handoff_session_id
                .as_deref()
                .ok_or(Error::TransferFieldMissing {
                    cause: "refused-recovery",
                    field: "handoff_session_id",
                })?;
            if current.session_id.as_deref() != Some(expected) {
                return Err(Error::HandoffSessionMismatch {
                    expected: expected.to_owned(),
                    recorded: current.session_id.clone(),
                });
            }
            Ok(())
        }
    }
}

pub(super) fn request_transfer(
    path: &Path,
    doc: &mut Document,
    r: &RequestTransfer,
    env: &Env,
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
    // One open controller operation per overseer, not per generation
    // string: a transfer still open on an earlier generation is reconciled
    // first.
    no_other_controller_intent(&intents, EffectOp::RequestTransfer, &target)?;
    refuse_off(path, &current)?;
    check_cause(r, &current)?;
    // A model recovery's binding (decision 109 (8)): the legacy predicate,
    // judged in the same transition that installs the pending, so a recovery
    // whose authorization no longer holds writes nothing.
    let record = state::object_mut(path, doc, "overseer")?;
    if let Some(recovery) = &r.recovery
        && let Err(cause) = recovery_bound(record, recovery)
    {
        return Err(Error::RecoveryUnbound {
            path: path.to_path_buf(),
            cause,
        });
    }
    // The legacy compare-and-swap, `ol_succession_owned`: the six identity
    // keys equal, `session_id` equal or not expected, `pending` equal. A
    // dead controller's recovery takes the held line as the successor, so
    // the standing `pending` is its input, not something it compares.
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
    if r.cause != TransferCause::Dead && standing != r.expected.pending {
        changed.push("pending".to_owned());
    }
    if !changed.is_empty() {
        return Err(Error::OverseerChanged {
            path: path.to_path_buf(),
            fields: changed,
        });
    }
    state::set(record, "pending", serde_json::to_value(&r.successor)?);
    let mut intent = new_intent(EffectOp::RequestTransfer, &target, env)?;
    intent.original_pending = Some(standing).filter(|v| !v.is_null());
    intent.cause = Some(r.cause);
    push_intent(path, doc, &intent)?;
    Ok(TransferRequested {
        generation,
        pending: r.successor.clone(),
        effect: Effect::Persisted { intent },
    })
}

pub(super) fn start_controller(
    path: &Path,
    doc: &mut Document,
    r: &StartController,
    env: &Env,
) -> Result<ControllerStarted> {
    let current: Option<Overseer> = state::field(path, doc, "overseer")?;
    let generation = current.as_ref().and_then(|o| o.generation).unwrap_or(0);
    let target = overseer_target(generation);
    let intents = intents(path, doc)?;
    if let Some(intent) = same_open_intent(&intents, EffectOp::StartController, &target)? {
        return Ok(ControllerStarted {
            generation,
            effect: Effect::Reconciled { intent },
        });
    }
    no_other_controller_intent(&intents, EffectOp::StartController, &target)?;
    // A fleet that never recorded a controller gets the object the first
    // launch publishes into; the confirmation writes generation 1.
    if matches!(doc.get("overseer"), None | Some(Value::Null)) {
        state::set(doc, "overseer", json!({}));
    }
    let record = state::object_mut(path, doc, "overseer")?;
    let standing = record.get("pending").cloned().unwrap_or(Value::Null);
    state::set(record, "pending", serde_json::to_value(&r.controller)?);
    let mut intent = new_intent(EffectOp::StartController, &target, env)?;
    intent.original_pending = Some(standing).filter(|v| !v.is_null());
    push_intent(path, doc, &intent)?;
    Ok(ControllerStarted {
        generation,
        effect: Effect::Persisted { intent },
    })
}

pub(super) fn stop_controller(
    path: &Path,
    doc: &mut Document,
    _r: &StopController,
    env: &Env,
) -> Result<StopRequested> {
    let current = overseer(path, doc)?;
    let generation = current.generation.unwrap_or(0);
    let target = overseer_target(generation);
    let intents = intents(path, doc)?;
    if let Some(intent) = same_open_intent(&intents, EffectOp::StopController, &target)? {
        return Ok(StopRequested {
            generation,
            effect: Effect::Reconciled { intent },
        });
    }
    no_other_controller_intent(&intents, EffectOp::StopController, &target)?;
    let intent = new_intent(EffectOp::StopController, &target, env)?;
    push_intent(path, doc, &intent)?;
    Ok(StopRequested {
        generation,
        effect: Effect::Persisted { intent },
    })
}

/// Hand an open, not yet started intent to the process asking (decision
/// 76): its owner becomes this `Env`'s. An intent that ended refuses
/// `intent-complete`; one whose effect recorded a phase refuses
/// `intent-started`, since its prior owner opened something a second owner
/// would open again.
pub(super) fn claim_intent(
    path: &Path,
    doc: &mut Document,
    r: &ClaimIntent,
    env: &Env,
) -> Result<IntentClaimed> {
    let owner = env
        .owner
        .clone()
        .ok_or(Error::OwnerUnreadable { op: "claim-intent" })?;
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
    if intent.phase.is_some() {
        return Err(Error::IntentStarted {
            id: intent.id.clone(),
        });
    }
    intent.handed_from = intent.owner.replace(owner.clone());
    // The job the launcher was asked for is this claimant: its handle and
    // its unread record are settled by the claim itself (decision 115 (B)),
    // and the job's own owner lease is what a reconcile reads from here. A
    // set the claim changed is a replaced set: its revision moves, so a token
    // the launcher minted before the claim acts no more (decision 124d (16)).
    if let Some(obligations) = &mut intent.obligations
        && obligations.discharge_where(ObligationRecord::is_job, "claimed") > 0
    {
        obligations.revision += 1;
    }
    let rows = state::array_mut(path, doc, "intents")?;
    let row = state::element_mut(path, rows, index, "intents")?;
    state::set(row, "owner", serde_json::to_value(&owner)?);
    if let Some(handed_from) = &intent.handed_from {
        state::set(row, "handed_from", serde_json::to_value(handed_from)?);
    }
    if let Some(obligations) = &intent.obligations {
        state::set(row, "obligations", serde_json::to_value(obligations)?);
    }
    Ok(IntentClaimed { intent })
}

/// Write an effect's progress (decisions 62, 115 (A)). The phase and the
/// obligation set go onto an open intent, refusing `intent-complete` on a
/// closed one as a phase write always has; the sent mark goes onto the
/// notice the outcome's write recorded owed, once: a second write finds it
/// recorded and changes nothing. A write that leaves the document as it was
/// is written nowhere (decision 89).
pub(super) fn record_progress(
    path: &Path,
    doc: &mut Document,
    r: &RecordProgress,
) -> Result<ProgressRecorded> {
    let intents = intents(path, doc)?;
    let index = intents
        .iter()
        .position(|i| i.id == r.intent_id)
        .ok_or_else(|| Error::IntentUnknown {
            id: r.intent_id.clone(),
        })?;
    let mut intent = intents[index].clone();
    // The launcher-side handle writes only while it still owns the intent: a
    // job that claimed between the launcher's last read and this write keeps
    // its own set, read under the store lock (decision 124b), and the write
    // is yielded to that claimant by name (decision 124h (32)).
    if let Some(expected) = &r.while_owner
        && intent.owner.as_ref() != Some(expected)
    {
        let owner = intent.owner.clone().unwrap_or_else(|| expected.clone());
        return Ok(ProgressRecorded {
            intent,
            progress: Progress::Yielded { owner },
        });
    }
    // A write that carries only a notice mark is a continuation of the
    // intent's recorded outcome, taken on the closed intent (decision 124i
    // (36)); the store's content comparison still holds the mark.
    let continuation = r.phase.is_none() && r.obligations.is_none();
    if !continuation && !intent.open() {
        return Err(Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        });
    }
    let before = doc.clone();
    // The notice the outcome's write recorded `owed` is marked with how its
    // send went (decision 124f (28)); a notice already marked, or none
    // recorded, is left as it is, so a second sender changes nothing.
    if let Some(notice) = &r.notice
        && intent.notice.as_ref().is_some_and(Notice::owed)
    {
        intent.notice = Some(notice.clone());
    }
    let rows = state::array_mut(path, doc, "intents")?;
    let row = state::element_mut(path, rows, index, "intents")?;
    if let Some(notice) = &intent.notice
        && r.notice.is_some()
    {
        state::set(row, "notice", serde_json::to_value(notice)?);
    }
    if let Some(phase) = &r.phase {
        intent.phase = Some(phase.clone());
        state::set(row, "phase", serde_json::to_value(phase)?);
    }
    if let Some(obligations) = &r.obligations {
        // The compare-and-swap on the set (decision 124f (26)): the write
        // names the revision its handle read the set at, and a record that
        // holds another was replaced by another handle or process since, so
        // the write is refused and the handle acts on nothing. A write that
        // changes the set replaces it: the store assigns the next revision;
        // the same set keeps its revision.
        let mut next = obligations.clone();
        if let Some(current) = &intent.obligations
            && current.revision != next.revision
        {
            return Err(Error::SetReplaced {
                id: intent.id.clone(),
                expected: next.revision,
                found: current.revision,
            });
        }
        next.revision = match &intent.obligations {
            Some(current) if current.same_set(&next) => current.revision,
            Some(current) => current.revision + 1,
            None => 1,
        };
        intent.obligations = Some(next.clone());
        state::set(row, "obligations", serde_json::to_value(&next)?);
    }
    if state::same_document(path, doc, &before)? {
        return Ok(ProgressRecorded {
            intent,
            progress: Progress::Unchanged,
        });
    }
    Ok(ProgressRecorded {
        intent,
        progress: Progress::Recorded,
    })
}

/// Apply an adoption: the one transition of the read-then-record
/// `adopt-controller`, on the identity the effects read in the pane. The
/// read travels as the token only the operation module mints from its own
/// pane read (decisions 124 (1), 124i (37)), so no caller supplies
/// adoption evidence; the compiler boundary names this function too, so
/// that module is its one caller.
#[allow(
    clippy::disallowed_methods,
    reason = "the adoption's one store write, committed through the state module's write check"
)]
pub(crate) fn apply_adoption(
    path: &Path,
    r: &AdoptController,
    read: &Recorded<AdoptionRead>,
    locking: Locking,
) -> Result<Applied> {
    let kind = super::target_kind(path, &Request::AdoptController(Box::new(r.clone())))?;
    let snapshot = super::loaded(path)?;
    let mut doc = snapshot.doc.clone();
    let adopted = adopt_controller(path, &mut doc, r, read.evidence())?;
    state::store(path, &snapshot, &doc, locking)?;
    Ok(Applied {
        kind,
        report: Report::AdoptController(Box::new(adopted)),
    })
}

/// Whether a record field is empty as the legacy heal reads it: absent,
/// `null` or `""`.
fn empty(record: &Document, key: &str) -> bool {
    match record.get(key) {
        None | Some(Value::Null) => true,
        Some(Value::String(s)) => s.is_empty(),
        Some(_) => false,
    }
}

/// The record `oversee register` writes, or heals. The same pane on the
/// same server (`ol_owns`) keeps its record: `server_start` is bound,
/// `harness`, `home` and `session_id` are filled only where empty
/// (`ol_record_heal`), and the identity read in the pane is written as the
/// active one, `exit` and `off` dropped. Another session's record, or none,
/// is replaced by this session's at the next generation, with the fields of
/// the session that ended left out.
fn adopt_controller(
    path: &Path,
    doc: &mut Document,
    r: &AdoptController,
    read: &AdoptionRead,
) -> Result<ControllerAdopted> {
    let intents = intents(path, doc)?;
    if let Some(intent) = intents.iter().find(|i| i.open() && i.op.on_controller()) {
        return Err(Error::IntentOpen {
            intent: intent.id.clone(),
            op: intent.op,
            target: intent.target.clone(),
        });
    }
    let current: Option<Overseer> = state::field(path, doc, "overseer")?;
    let prior_generation = current.as_ref().and_then(|o| o.generation).unwrap_or(0);
    if read.same {
        let record = state::object_mut(path, doc, "overseer")?;
        let generation = prior_generation.max(1);
        state::set(record, "generation", generation);
        state::set(record, "server_start", read.server_start);
        state::set(record, "server_socket", read.socket.as_str());
        if empty(record, "harness") {
            state::set(record, "harness", r.harness.as_str());
        }
        if empty(record, "home")
            && let Some(home) = r.home.as_deref().or(r.account.as_deref())
        {
            state::set(record, "home", home);
        }
        if empty(record, "session_id")
            && let Some(id) = &r.session_id
        {
            state::set(record, "session_id", id.as_str());
        }
        state::set(record, "harness_pid", read.identity.pid);
        state::set(record, "harness_start", read.identity.start.as_str());
        state::delete(record, "exit");
        state::delete(record, "off");
        return Ok(ControllerAdopted {
            generation,
            healed: true,
        });
    }
    let generation = prior_generation + 1;
    let record = json!({
        "runtime": "tmux",
        "generation": generation,
        "server": read.server.to_string(),
        "server_start": read.server_start,
        "server_socket": read.socket,
        "pane": r.pane,
        "window": read.window,
        "session_id": string_or_null(&r.session_id),
        "harness_pid": read.identity.pid,
        "harness_start": read.identity.start,
        "harness": r.harness,
        "account": string_or_null(&r.account),
        "home": string_or_null(&r.home.clone().or_else(|| r.account.clone())),
        "model": string_or_null(&r.model),
        "effort": string_or_null(&r.effort),
        "cwd": string_or_null(&r.cwd),
    });
    state::set(doc, "overseer", record);
    Ok(ControllerAdopted {
        generation,
        healed: false,
    })
}

/// The target of a controller intent at `generation`.
pub fn overseer_target(generation: u64) -> String {
    format!("overseer:{generation}")
}

/// The generation a controller intent's target names.
pub(super) fn target_generation(target: &str) -> Option<u64> {
    target.strip_prefix("overseer:")?.parse().ok()
}

/// Whether an observation says the succession's predecessor was retired.
fn retired(observation: Option<&Value>) -> bool {
    observation
        .and_then(|o| o.get("retired"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// The controller arms of `record-outcome`, on an overseer whose generation
/// is still the one the intent names: a transfer or a start publishes,
/// restores or keeps its runner; a stop records `off`.
pub(super) fn record_controller_outcome(
    path: &Path,
    doc: &mut Document,
    intent: &Intent,
    r: &RecordOutcome,
    at: &str,
    recorded: &mut OutcomeRecorded,
) -> Result<()> {
    match intent.op {
        EffectOp::RequestTransfer | EffectOp::StartController => {
            record_transfer_outcome(path, doc, intent, r, recorded)
        }
        EffectOp::StopController => {
            let generation = overseer(path, doc)?.generation.unwrap_or(0);
            match r.outcome {
                Outcome::Confirmed => {
                    let record = state::object_mut(path, doc, "overseer")?;
                    state::set(record, "off", json!({"at": at, "generation": generation}));
                    recorded.generation = Some(generation);
                }
                Outcome::Failed | Outcome::Unconfirmed | Outcome::NotStarted => {}
            }
            Ok(())
        }
        EffectOp::LaunchLane | EffectOp::CloseOwnedResources => {
            unreachable!("record_outcome routes the lane operations to the lane arms")
        }
    }
}

/// The succession arms of `record-outcome`. `confirmed` publishes the
/// pending successor; `failed` before retirement restores the pending the
/// request overwrote; `unconfirmed` after retirement keeps the waiting
/// runner under `pending.runner` for a reconcile.
fn record_transfer_outcome(
    path: &Path,
    doc: &mut Document,
    intent: &Intent,
    r: &RecordOutcome,
    recorded: &mut OutcomeRecorded,
) -> Result<()> {
    match r.outcome {
        Outcome::Confirmed => {
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
            // The successor's own native session, where the confirmation
            // bound it (decision 65): written as the heal appends it, so the
            // turn-end hook finds the binding rather than filling it later.
            if let Some(id) = &r.session_id {
                state::set(record, "session_id", id.as_str());
            }
            // A controller that runs is not off: the start after an
            // explicit stop clears the mark (decision 78).
            state::delete(record, "off");
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
        Outcome::Failed => {
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
        Outcome::Unconfirmed => {
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
        Outcome::NotStarted => {}
    }
    Ok(())
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows drive the store through its entry points"
)]
mod tests {
    use std::fs;

    use agent_runtime::protocol::Outcome;
    use serde_json::{Value, json};

    use super::super::testing::*;
    use super::*;
    use crate::error::Error;
    use crate::ops::{Effect, Report, Request};
    use crate::state::{LaunchIdentity, Notice, fixtures};

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
        assert_eq!(intent.cause, Some(TransferCause::Live));
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

    /// A transfer request under each cause and what the transition
    /// requires of it (step4-map A5 to A8): `dead` takes the held line over
    /// a standing pending without comparing it; `walled` names the spent
    /// account and refuses a successor on it, by the canonical directory;
    /// `refused-recovery` names the handoff's session and refuses another
    /// controller's; every cause refuses an `off` controller and is carried
    /// on the intent for the effect and the reconcile.
    #[test]
    fn each_transfer_cause_requires_its_fields_and_refuses_what_it_must() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let with = |cause: TransferCause, patch: fn(&mut RequestTransfer)| {
            let Request::RequestTransfer(mut r) = transfer(expected()) else {
                panic!()
            };
            r.cause = cause;
            patch(&mut r);
            Request::RequestTransfer(r)
        };
        // dead: the standing pending is not compared, and is the original
        // kept for restore.
        let standing = fixtures::FLEET.replacen(
            "\"generation\": 3,",
            "\"generation\": 3, \"pending\": {\"harness\": \"codex\", \"launch_line\": \"held\"},",
            1,
        );
        fs::write(&path, &standing).unwrap();
        let applied = run(&path, &with(TransferCause::Dead, |_| {})).unwrap();
        let Report::RequestTransfer(t) = &applied.report else {
            panic!()
        };
        let Effect::Persisted { intent } = &t.effect else {
            panic!()
        };
        assert_eq!(intent.cause, Some(TransferCause::Dead));
        assert_eq!(
            intent.original_pending,
            Some(json!({"harness": "codex", "launch_line": "held"}))
        );
        assert_eq!(
            fleet(&path).intents[0].cause,
            Some(TransferCause::Dead),
            "the cause is on the record"
        );
        // walled: the spent account is required; a successor resolving to
        // it, by the canonical directory, refuses and writes nothing.
        fs::write(&path, fixtures::FLEET).unwrap();
        let before = fs::read_to_string(&path).unwrap();
        let err = run(&path, &with(TransferCause::Walled, |_| {})).unwrap_err();
        assert!(
            matches!(
                &err,
                Error::TransferFieldMissing {
                    cause: "walled",
                    field: "exclude_account"
                }
            ),
            "{err:?}"
        );
        let spent_dir = dir.path().join("accounts").join("c2");
        fs::create_dir_all(&spent_dir).unwrap();
        let spent = spent_dir.display().to_string();
        let rows: [(&str, &str); 3] = [
            ("the account itself", &spent),
            ("the account with a trailing slash", &format!("{spent}/")),
            (
                "the account through a dot segment",
                &format!("{spent}/../c2"),
            ),
        ];
        for (name, exclude) in rows {
            let Request::RequestTransfer(mut r) = transfer(expected()) else {
                panic!()
            };
            r.cause = TransferCause::Walled;
            r.successor.account = Some(spent.clone());
            r.exclude_account = Some(exclude.to_owned());
            let err = run(&path, &Request::RequestTransfer(r)).unwrap_err();
            assert_eq!(err.key(), "successor-account-spent", "{name}: {err}");
            assert_eq!(fs::read_to_string(&path).unwrap(), before, "{name}");
        }
        let Request::RequestTransfer(mut r) = transfer(expected()) else {
            panic!()
        };
        r.cause = TransferCause::Walled;
        r.exclude_account = Some(spent.clone());
        let applied = run(&path, &Request::RequestTransfer(r)).unwrap();
        let Report::RequestTransfer(t) = &applied.report else {
            panic!()
        };
        assert!(matches!(&t.effect, Effect::Persisted { .. }));
        assert_eq!(fleet(&path).intents[0].cause, Some(TransferCause::Walled));
        // refused-recovery: the handoff's session is required and must be
        // the recorded controller's.
        fs::write(&path, fixtures::FLEET).unwrap();
        let err = run(&path, &with(TransferCause::RefusedRecovery, |_| {})).unwrap_err();
        assert_eq!(err.key(), "transfer-field-missing");
        let err = run(
            &path,
            &with(TransferCause::RefusedRecovery, |r| {
                r.handoff_session_id = Some("another-session".into());
            }),
        )
        .unwrap_err();
        assert!(
            matches!(&err, Error::HandoffSessionMismatch { recorded: Some(s), .. } if s.starts_with("0f3d")),
            "{err:?}"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), before);
        let applied = run(
            &path,
            &with(TransferCause::RefusedRecovery, |r| {
                r.handoff_session_id = Some("0f3d2c1b-9a8e-4d7c-b6a5-443322110000".into());
            }),
        )
        .unwrap();
        let Report::RequestTransfer(t) = &applied.report else {
            panic!()
        };
        assert!(matches!(&t.effect, Effect::Persisted { .. }));
        // off: every cause refuses, and nothing is written (decision 78).
        let off = fixtures::FLEET.replacen(
            "\"generation\": 3,",
            "\"generation\": 3, \"off\": {\"at\": \"2026-10-26T10:00:00Z\", \"generation\": 3},",
            1,
        );
        fs::write(&path, &off).unwrap();
        for cause in [
            TransferCause::Live,
            TransferCause::Dead,
            TransferCause::Walled,
            TransferCause::RefusedRecovery,
        ] {
            let err = run(
                &path,
                &with(cause, |r| {
                    r.exclude_account = Some("/elsewhere".into());
                    r.handoff_session_id = Some("0f3d2c1b-9a8e-4d7c-b6a5-443322110000".into());
                }),
            )
            .unwrap_err();
            assert!(
                matches!(&err, Error::ControllerOff { generation: 3, .. }),
                "{}: {err:?}",
                cause.word()
            );
            assert_eq!(fs::read_to_string(&path).unwrap(), off, "{}", cause.word());
        }
    }

    /// Decision 78 at the transition: `ORCH_OVERSEER_SUCCESSION=off`
    /// refuses a transfer before any transition and admits every other
    /// request.
    #[test]
    fn succession_off_admits_everything_but_a_transfer() {
        let dir = tempfile::tempdir().unwrap();
        let roots = crate::settings::Roots {
            project: dir.path().to_path_buf(),
            common: dir.path().to_path_buf(),
        };
        let flags = crate::settings::Flags {
            state_dir: None,
            private_env: false,
        };
        let off = crate::settings::load(
            &roots,
            &[("ORCH_OVERSEER_SUCCESSION".into(), "off".into())],
            &flags,
        )
        .unwrap();
        let on = crate::settings::load(&roots, &[], &flags).unwrap();
        let err = admit(&transfer(expected()), &off).unwrap_err();
        assert_eq!(err.key(), "succession-off");
        admit(&transfer(expected()), &on).unwrap();
        admit(&start(), &off).unwrap();
        admit(&stop(), &off).unwrap();
        admit(&launch("KEN-1"), &off).unwrap();
    }

    fn start() -> Request {
        Request::StartController(Box::new(StartController {
            controller: successor(),
            brief_file: None,
        }))
    }

    fn stop() -> Request {
        Request::StopController(StopController {})
    }

    fn claim(id: &str) -> Request {
        Request::ClaimIntent(ClaimIntent {
            intent_id: id.to_owned(),
        })
    }

    /// A start on a fleet with no controller creates the object its
    /// confirmation publishes into, at generation 1; one over a recorded
    /// controller holds the controller as pending at the recorded generation
    /// and keeps a standing pending for restore; the three controller
    /// operations exclude one another on the one overseer; a confirmed
    /// start clears `off`.
    #[test]
    fn start_controller_opens_the_lane_and_the_controller_operations_exclude_each_other() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        // No controller recorded.
        let bare = fixtures::FLEET.replacen("\"overseer\"", "\"overseer_was\"", 1);
        fs::write(&path, &bare).unwrap();
        let applied = run(&path, &start()).unwrap();
        let Report::StartController(s) = &applied.report else {
            panic!("{applied:?}")
        };
        assert_eq!(s.generation, 0);
        let Effect::Persisted { intent } = &s.effect else {
            panic!()
        };
        assert_eq!(intent.op, EffectOp::StartController);
        assert_eq!(intent.target, "overseer:0");
        assert_eq!(intent.original_pending, None);
        assert_eq!(fleet(&path).overseer.unwrap().pending, Some(successor()));
        // The repeat reconciles; a transfer or a stop meanwhile refuses.
        let again = run(&path, &start()).unwrap();
        let Report::StartController(s) = &again.report else {
            panic!()
        };
        assert!(matches!(&s.effect, Effect::Reconciled { .. }));
        assert_eq!(run(&path, &stop()).unwrap_err().key(), "intent-open");
        run(&path, &outcome(&intent.id, Outcome::Confirmed)).unwrap();
        let published = object(&path)["overseer"].clone();
        assert_eq!(published["generation"], json!(1));
        assert_eq!(published["harness"], json!("codex"));
        assert_eq!(published["pane"], json!("%12"));
        assert_eq!(published["harness_pid"], json!(6000));
        assert!(published.get("pending").is_none());
        // Over a recorded, off controller with a pending standing: the
        // pending is held for restore, and the confirmation clears `off`.
        let off = fixtures::FLEET.replacen(
            "\"generation\": 3,",
            "\"generation\": 3, \"off\": {\"at\": \"2026-10-26T10:00:00Z\", \"generation\": 3}, \"pending\": {\"harness\": \"codex\"},",
            1,
        );
        fs::write(&path, &off).unwrap();
        let applied = run(&path, &start()).unwrap();
        let Report::StartController(s) = &applied.report else {
            panic!()
        };
        assert_eq!(s.generation, 3);
        let Effect::Persisted { intent } = &s.effect else {
            panic!()
        };
        assert_eq!(intent.original_pending, Some(json!({"harness": "codex"})));
        assert_eq!(
            run(&path, &transfer(expected())).unwrap_err().key(),
            "intent-open"
        );
        run(&path, &outcome(&intent.id, Outcome::Failed)).unwrap();
        let restored = object(&path)["overseer"].clone();
        assert_eq!(restored["pending"], json!({"harness": "codex"}));
        assert!(restored.get("off").is_some(), "a failed start leaves off");
        let id = intend(&path, &start());
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let published = object(&path)["overseer"].clone();
        assert_eq!(published["generation"], json!(4));
        assert!(
            published.get("off").is_none(),
            "a confirmed start clears off"
        );
        // A stop over an open transfer refuses, and a transfer over an open
        // stop refuses.
        fs::write(&path, fixtures::FLEET).unwrap();
        run(&path, &transfer(expected())).unwrap();
        assert_eq!(run(&path, &stop()).unwrap_err().key(), "intent-open");
        assert_eq!(run(&path, &start()).unwrap_err().key(), "intent-open");
        fs::write(&path, fixtures::FLEET).unwrap();
        run(&path, &stop()).unwrap();
        assert_eq!(
            run(&path, &transfer(expected())).unwrap_err().key(),
            "intent-open"
        );
    }

    /// Decision 78: a confirmed stop records `off {at, generation}` and
    /// moves nothing else; a failed or unconfirmed one records nothing. A
    /// dead-cause transfer then refuses `controller-off`.
    #[test]
    fn a_confirmed_stop_records_off_and_a_recovery_then_refuses() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let before = object(&path)["overseer"].clone();
        let id = intend(&path, &stop());
        run(&path, &outcome(&id, Outcome::Unconfirmed)).unwrap();
        assert_eq!(object(&path)["overseer"], before);
        let applied = run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let Report::RecordOutcome(r) = &applied.report else {
            panic!()
        };
        assert_eq!(r.generation, Some(3));
        let after = object(&path)["overseer"].clone();
        assert_eq!(
            after["off"],
            json!({"at": "2026-01-29T15:20:00Z", "generation": 3})
        );
        let mut expected_keys = keys(before.as_object().unwrap());
        expected_keys.push("off".into());
        assert_eq!(keys(after.as_object().unwrap()), expected_keys);
        let Request::RequestTransfer(mut r) = transfer(expected()) else {
            panic!()
        };
        r.cause = TransferCause::Dead;
        let err = run(&path, &Request::RequestTransfer(r)).unwrap_err();
        assert_eq!(err.key(), "controller-off");
        assert_eq!(object(&path)["overseer"], after, "nothing written");
        // A failed stop records nothing either.
        fs::write(&path, fixtures::FLEET).unwrap();
        let id = intend(&path, &stop());
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        assert_eq!(object(&path)["overseer"], before);
    }

    /// Decision 76: the detached job takes the intent's owner lease by
    /// claiming it; a claim of an intent that ended, or whose effect has a
    /// phase, refuses and writes nothing.
    #[test]
    fn claim_intent_moves_the_owner_lease_only_before_the_effect_starts() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &transfer(expected()));
        assert_eq!(fleet(&path).intents[0].owner, Some(owner()));
        let job = Env {
            owner: Some(state::Owner {
                pid: 777,
                start: "ticks:777".into(),
            }),
            ..env()
        };
        let applied = crate::ops::apply(&path, &claim(&id), &job, LOCK).unwrap();
        let Report::ClaimIntent(c) = &applied.report else {
            panic!()
        };
        assert_eq!(c.intent.owner.as_ref().unwrap().pid, 777);
        assert_eq!(c.intent.handed_from, Some(owner()));
        assert_eq!(fleet(&path).intents[0].owner.as_ref().unwrap().pid, 777);
        assert_eq!(fleet(&path).intents[0].handed_from, Some(owner()));
        assert_eq!(
            crate::ops::apply(&path, &claim("nope"), &job, LOCK)
                .unwrap_err()
                .key(),
            "intent-unknown"
        );
        let unowned = Env {
            owner: None,
            ..env()
        };
        assert_eq!(
            crate::ops::apply(&path, &claim(&id), &unowned, LOCK)
                .unwrap_err()
                .key(),
            "owner-unreadable"
        );
        // A phase recorded: the prior owner opened something.
        let opened = state::OpenedPane {
            pane: "%12".into(),
            server: 41020,
            server_start: 1_769_590_000,
            server_process_start: None,
            socket: "/tmp/tmux-1000/default".into(),
            since_ms: 1,
            brief: None,
            session_id: None,
            baseline: Vec::new(),
            identity: None,
        };
        run(
            &path,
            &Request::RecordPhase(crate::ops::RecordPhase {
                intent_id: id.clone(),
                phase: state::Phase::WindowOpened { opened },
            }),
        )
        .unwrap();
        let before = fs::read_to_string(&path).unwrap();
        let err = crate::ops::apply(&path, &claim(&id), &job, LOCK).unwrap_err();
        assert!(
            matches!(&err, Error::IntentStarted { id: i } if *i == id),
            "{err:?}"
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), before);
        run(&path, &outcome(&id, Outcome::Failed)).unwrap();
        assert_eq!(
            crate::ops::apply(&path, &claim(&id), &job, LOCK)
                .unwrap_err()
                .key(),
            "intent-complete"
        );
    }

    /// Decision 124h (32): a launcher-side write of a set the record already
    /// holds, under the owner the record names, is accepted as unchanged,
    /// never yielded; the same write naming another owner is yielded to the
    /// recorded owner by name, and nothing lands.
    #[test]
    fn an_unchanged_set_under_the_recorded_owner_is_accepted_not_yielded() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &transfer(expected()));
        let set = |revision: u64| ObligationRecord {
            standing: vec![crate::state::Held {
                obligation: crate::state::Obligation::JobSidecar,
                role: Some(crate::state::Role::Job),
                harness: None,
            }],
            discharged: Vec::new(),
            signalled: true,
            revision,
            ..Default::default()
        };
        let write = |set: ObligationRecord, while_owner: Option<state::Owner>| {
            Request::RecordProgress(Box::new(RecordProgress {
                intent_id: id.clone(),
                phase: None,
                obligations: Some(set),
                while_owner,
                notice: None,
            }))
        };
        let progress = |applied: Applied| match applied.report {
            Report::RecordProgress(r) => r,
            _ => panic!("a progress report"),
        };
        let first = progress(
            crate::ops::apply(&path, &write(set(0), Some(owner())), &env(), LOCK).unwrap(),
        );
        assert_eq!(first.progress, Progress::Recorded);
        let revision = first.intent.obligations.as_ref().unwrap().revision;
        let again = progress(
            crate::ops::apply(&path, &write(set(revision), Some(owner())), &env(), LOCK).unwrap(),
        );
        assert_eq!(
            again.progress,
            Progress::Unchanged,
            "the same set under the recorded owner is accepted without a write"
        );
        let other = state::Owner {
            pid: 999,
            start: "ticks:999".into(),
        };
        let yielded = progress(
            crate::ops::apply(&path, &write(set(revision), Some(other)), &env(), LOCK).unwrap(),
        );
        assert_eq!(
            yielded.progress,
            Progress::Yielded { owner: owner() },
            "a write under another owner is yielded to the recorded owner"
        );
    }

    /// Decision 124b (6): the launcher-side write guard. A record-progress or
    /// a record-outcome that names `while_owner` is a no-op once another
    /// owner holds the intent, so a job that claimed between the launcher's
    /// last read and its write keeps its own set and the launcher's stale
    /// clone never lands.
    #[test]
    fn a_launcher_side_write_yields_to_a_claimant() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &transfer(expected()));
        // The job claims: the owner moves from the launcher's to the job's.
        let job = Env {
            owner: Some(state::Owner {
                pid: 777,
                start: "ticks:777".into(),
            }),
            ..env()
        };
        crate::ops::apply(&path, &claim(&id), &job, LOCK).unwrap();
        let claimed = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap()
            .obligations
            .clone();
        // The launcher, still naming the intent's original owner, writes a
        // different set and then a failed outcome: both are no-ops.
        let sidecar = || crate::state::Held {
            obligation: crate::state::Obligation::JobSidecar,
            role: Some(crate::state::Role::Job),
            harness: None,
        };
        let launcher_set = ObligationRecord {
            standing: vec![sidecar()],
            discharged: Vec::new(),
            signalled: true,
            ..Default::default()
        };
        let progress = Request::RecordProgress(Box::new(RecordProgress {
            intent_id: id.clone(),
            phase: None,
            obligations: Some(launcher_set),
            while_owner: Some(owner()),
            notice: None,
        }));
        crate::ops::apply(&path, &progress, &env(), LOCK).unwrap();
        let fail = Request::RecordOutcome(Box::new(RecordOutcome {
            intent_id: id.clone(),
            outcome: Outcome::Failed,
            launch: None,
            session_id: None,
            server_start: None,
            server_socket: None,
            window: None,
            tmux_session: None,
            launch_line: None,
            observation: Some(json!({"note": "job-unclaimed"})),
            while_owner: Some(owner()),
            lane_keys: None,
            notice: None,
            set_revision: None,
        }));
        crate::ops::apply(&path, &fail, &env(), LOCK).unwrap();
        let after = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap();
        assert_eq!(
            after.obligations, claimed,
            "the claimant's set stands, the launcher's clone did not land"
        );
        assert!(after.open(), "the launcher's outcome closed nothing");
        assert_eq!(after.owner.as_ref().unwrap().pid, 777);
        // The same writes without the owner guard land when they name the
        // set's current revision, so the guard is what holds the claimant's
        // set; a write naming a revision the record no longer holds is the
        // compare-and-swap's refusal, `set-replaced` (decision 124f (26)).
        let open_progress = |revision: u64| {
            Request::RecordProgress(Box::new(RecordProgress {
                intent_id: id.clone(),
                phase: None,
                obligations: Some(ObligationRecord {
                    standing: vec![sidecar()],
                    discharged: Vec::new(),
                    signalled: true,
                    revision,
                    ..Default::default()
                }),
                while_owner: None,
                notice: None,
            }))
        };
        let current = claimed.as_ref().map_or(0, |c| c.revision);
        crate::ops::apply(&path, &open_progress(current), &env(), LOCK).unwrap();
        let after = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap();
        let landed = after.obligations.unwrap();
        assert_eq!(
            landed.standing,
            vec![sidecar()],
            "an unguarded write at the current revision lands"
        );
        // Decision 124d (16): a write that replaces the set moves its
        // revision; the same set written again keeps it; one naming the
        // revision before the replacement is refused and lands nothing.
        let replaced_at = landed.revision;
        assert_eq!(
            replaced_at,
            current + 1,
            "the replacement took the next revision"
        );
        let stale = crate::ops::apply(&path, &open_progress(current), &env(), LOCK).unwrap_err();
        assert_eq!(stale.key(), "set-replaced", "{stale}");
        assert_eq!(
            fleet(&path).intents[0].obligations.as_ref(),
            Some(&landed),
            "a write at a stale revision lands nothing"
        );
        crate::ops::apply(&path, &open_progress(replaced_at), &env(), LOCK).unwrap();
        assert_eq!(
            fleet(&path).intents[0]
                .obligations
                .as_ref()
                .unwrap()
                .revision,
            replaced_at,
            "the same set keeps its revision"
        );
    }

    /// Decision 124d (18), R-U4g5 Codex `owner-lock-probe.rs`: a claim that
    /// lands between the launcher-side transition's owner read and its store
    /// is answered with the claimant's state, never `record-changed`. The
    /// production `apply` is run with the claim committed in that gap; it
    /// reads again and yields to the claimant.
    #[test]
    fn a_claim_between_the_owner_read_and_the_store_returns_the_claimant() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &transfer(expected()));
        let claimant = Env {
            owner: Some(state::Owner {
                pid: 777,
                start: "ticks:777".into(),
            }),
            ..env()
        };
        let request = Request::RecordProgress(Box::new(RecordProgress {
            intent_id: id.clone(),
            phase: None,
            obligations: Some(ObligationRecord {
                standing: vec![crate::state::Held {
                    obligation: crate::state::Obligation::JobSidecar,
                    role: Some(crate::state::Role::Job),
                    harness: None,
                }],
                ..Default::default()
            }),
            while_owner: Some(owner()),
            notice: None,
        }));
        let once = std::cell::Cell::new(false);
        let claim_in_the_gap = || {
            if !once.replace(true) {
                crate::ops::apply(&path, &claim(&id), &claimant, LOCK).unwrap();
            }
        };
        let applied =
            crate::ops::apply_interleaved(&path, &request, &env(), LOCK, None, &claim_in_the_gap)
                .expect("the claimant's state, not record-changed");
        let Report::RecordProgress(r) = &applied.report else {
            panic!("a progress report")
        };
        assert!(
            matches!(r.progress, Progress::Yielded { ref owner } if owner.pid == 777),
            "the launcher's write yielded to the claimant: {:?}",
            r.progress
        );
        assert_eq!(
            r.intent.owner.as_ref().unwrap().pid,
            777,
            "{:?}",
            r.intent.owner
        );
        let stored = fleet(&path)
            .intents
            .into_iter()
            .find(|i| i.id == id)
            .unwrap();
        assert_eq!(stored.owner.as_ref().unwrap().pid, 777);
        assert!(
            stored.obligations.as_ref().is_none_or(|o| !o
                .standing_obligations()
                .any(|o| *o == crate::state::Obligation::JobSidecar)),
            "the launcher's set never landed over the claim: {stored:?}"
        );
        assert!(once.get(), "the claim landed in the gap");
    }

    /// The adoption transition on the identity the effects read: the same
    /// pane on the same server is healed in place (fields filled only where
    /// empty, the identity written, `exit` and `off` dropped); another
    /// session's record is replaced at the next generation with none of the
    /// ended session's fields; an open controller intent refuses.
    #[test]
    fn adopt_controller_heals_its_own_pane_and_replaces_another_sessions_record() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let request = AdoptController {
            pane: "%7".into(),
            socket: None,
            harness: "claude".into(),
            session_id: Some("fresh-session".into()),
            account: Some("/a/x".into()),
            home: None,
            model: Some("m".into()),
            effort: None,
            cwd: Some("/r".into()),
        };
        let read = |same: bool| {
            Recorded::planted(AdoptionRead {
                identity: Identity {
                    pid: 5151,
                    start: "ticks:5151".into(),
                },
                server: 41020,
                server_start: 1_769_590_000,
                socket: "/tmp/tmux-1000/default".into(),
                window: "@3".into(),
                same,
            })
        };
        // Heal: the record names %7 on 41020; harness and home stand and
        // are kept, session_id is empty and filled, the identity written.
        let healed_from = fixtures::FLEET
            .replacen(
                "\"session_id\": \"0f3d2c1b-9a8e-4d7c-b6a5-443322110000\",\n    \"harness_pid\": \"41388\"",
                "\"session_id\": \"\",\n    \"exit\": {\"status\": 0}, \"off\": {\"at\": \"x\"},\n    \"harness_pid\": \"41388\"",
                1,
            );
        fs::write(&path, &healed_from).unwrap();
        let applied = apply_adoption(&path, &request, &read(true), LOCK).unwrap();
        let Report::AdoptController(a) = &applied.report else {
            panic!()
        };
        assert!(a.healed);
        assert_eq!(a.generation, 3);
        let after = object(&path)["overseer"].clone();
        assert_eq!(after["harness"], json!("claude"));
        assert_eq!(after["home"], json!("/home/u/.claude-lanes/a1"), "kept");
        assert_eq!(after["session_id"], json!("fresh-session"), "filled");
        assert_eq!(after["harness_pid"], json!(5151));
        assert_eq!(after["harness_start"], json!("ticks:5151"));
        assert_eq!(
            after["model"],
            json!("claude-opus-5-5"),
            "not the request's"
        );
        assert!(after.get("exit").is_none() && after.get("off").is_none());
        // Replace: another session's record goes, the new one is written
        // at the next generation with the request's identity.
        fs::write(&path, fixtures::FLEET).unwrap();
        let applied = apply_adoption(&path, &request, &read(false), LOCK).unwrap();
        let Report::AdoptController(a) = &applied.report else {
            panic!()
        };
        assert!(!a.healed);
        assert_eq!(a.generation, 4);
        let after = object(&path)["overseer"].clone();
        assert_eq!(
            after,
            json!({
                "runtime": "tmux",
                "generation": 4,
                "server": "41020",
                "server_start": 1_769_590_000,
                "server_socket": "/tmp/tmux-1000/default",
                "pane": "%7",
                "window": "@3",
                "session_id": "fresh-session",
                "harness_pid": 5151,
                "harness_start": "ticks:5151",
                "harness": "claude",
                "account": "/a/x",
                "home": "/a/x",
                "model": "m",
                "effort": null,
                "cwd": "/r",
            })
        );
        // An open controller intent refuses.
        fs::write(&path, fixtures::FLEET).unwrap();
        run(&path, &transfer(expected())).unwrap();
        let err = apply_adoption(&path, &request, &read(false), LOCK).unwrap_err();
        assert_eq!(err.key(), "intent-open");
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
            // The bound session the confirmation carries (decision 65), as
            // the heal appends it (R-U4c F): the predecessor's was dropped
            // above, so the successor's own takes the next place.
            "session_id": "native-1",
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
        // as the number `ol_record_write` writes (`$start | tonumber`); one
        // that bound no session writes none.
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
        let unbound: Vec<String> = keys(legacy)
            .into_iter()
            .filter(|k| k != "session_id")
            .collect();
        assert_eq!(keys(&after), unbound, "key sequence");
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
                cause: TransferCause::Live,
                exclude_account: None,
                handoff_session_id: None,
                recovery: None,
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

    /// The fixture record's launch as `ol_model_launch` projects it.
    fn bound_recovery() -> Recovery {
        Recovery {
            server: json!("41020"),
            server_start: json!(1769590000),
            pane: json!("%7"),
            generation: json!(3),
            launch_line: json!(
                "cd /home/u/dev/kendex && CLAUDE_CONFIG_DIR=/home/u/.claude-lanes/a1 claude --model claude-opus-5-5 --effort high"
            ),
            cwd: json!("/home/u/dev/kendex"),
            session_id: json!("0f3d2c1b-9a8e-4d7c-b6a5-443322110000"),
        }
    }

    /// The fixture with a `model_check` that binds a recovery to the
    /// recorded launch and session.
    fn fleet_with_model_check(outcome: &str, session: &str) -> String {
        let identity = json!({
            "server": "41020", "server_start": 1769590000, "pane": "%7", "generation": 3,
            "launch_line": "cd /home/u/dev/kendex && CLAUDE_CONFIG_DIR=/home/u/.claude-lanes/a1 claude --model claude-opus-5-5 --effort high",
            "cwd": "/home/u/dev/kendex", "session_id": "0f3d2c1b-9a8e-4d7c-b6a5-443322110000",
        });
        fixtures::FLEET.replacen(
            "    \"harness_start\": \"ticks:9912345\",\n",
            &format!(
                "    \"harness_start\": \"ticks:9912345\",\n    \"model_check\": {},\n",
                json!({"outcome": outcome, "session_id": session, "launch_identity": identity})
            ),
            1,
        )
    }

    /// Decision 109 (8): a transfer carrying a recovery binding is admitted
    /// only where the legacy `ol_recovery_bound` predicate holds on the
    /// record as it stands; each clause that fails refuses `recovery-unbound`
    /// with its cause and writes nothing, the pending untouched and no
    /// intent made.
    #[test]
    fn a_recovery_transfer_is_refused_unbound_unless_the_record_still_binds_it() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let with_recovery = |recovery: Recovery| {
            let Request::RequestTransfer(mut r) = transfer(expected()) else {
                panic!()
            };
            r.recovery = Some(recovery);
            Request::RequestTransfer(r)
        };
        let rows: [(&str, String, Recovery, &str); 5] = [
            (
                "no model check on the record",
                fixtures::FLEET.to_owned(),
                bound_recovery(),
                "model-check-missing",
            ),
            (
                "the record's launch moved",
                fleet_with_model_check("switched", "0f3d2c1b-9a8e-4d7c-b6a5-443322110000")
                    .replacen("\"pane\": \"%7\"", "\"pane\": \"%9\"", 1),
                bound_recovery(),
                "launch-changed",
            ),
            (
                "the check did not switch",
                fleet_with_model_check("matching", "0f3d2c1b-9a8e-4d7c-b6a5-443322110000"),
                bound_recovery(),
                "model-check-not-switched",
            ),
            (
                "the check is another session's",
                fleet_with_model_check("switched", "another-session"),
                bound_recovery(),
                "model-check-session",
            ),
            (
                "the request names another launch",
                fleet_with_model_check("switched", "0f3d2c1b-9a8e-4d7c-b6a5-443322110000"),
                Recovery {
                    generation: json!(2),
                    ..bound_recovery()
                },
                "launch-changed",
            ),
        ];
        for (name, text, recovery, cause) in rows {
            fs::write(&path, &text).unwrap();
            let err = run(&path, &with_recovery(recovery)).unwrap_err();
            assert!(
                matches!(&err, Error::RecoveryUnbound { cause: c, .. } if *c == cause),
                "{name}: {err:?}"
            );
            assert_eq!(err.key(), "recovery-unbound", "{name}");
            assert_eq!(
                fs::read_to_string(&path).unwrap(),
                text,
                "{name}: nothing written"
            );
        }
        // Bound: admitted as any transfer, the pending installed.
        let text = fleet_with_model_check("switched", "0f3d2c1b-9a8e-4d7c-b6a5-443322110000");
        fs::write(&path, &text).unwrap();
        let applied = run(&path, &with_recovery(bound_recovery())).unwrap();
        let Report::RequestTransfer(t) = &applied.report else {
            panic!()
        };
        assert!(matches!(&t.effect, Effect::Persisted { .. }));
        assert_eq!(fleet(&path).overseer.unwrap().pending, Some(successor()));
        // A check whose identity is another launch's.
        let other = text.replacen(
            "\"launch_identity\":{\"server\":\"41020\"",
            "\"launch_identity\":{\"server\":\"41021\"",
            1,
        );
        fs::write(&path, &other).unwrap();
        let err = run(&path, &with_recovery(bound_recovery())).unwrap_err();
        assert!(
            matches!(
                &err,
                Error::RecoveryUnbound {
                    cause: "model-check-identity",
                    ..
                }
            ),
            "{err:?}"
        );
    }

    /// Decisions 109 (7), 124f (28): a failed or unconfirmed outcome of a
    /// transfer or a stop records the notice it owes with its own write,
    /// `owed`, and appends one fleet-log row under the legacy's kind and
    /// item in that write; the follow-up progress write marks the notice
    /// with how the send went and appends nothing; the same mark written
    /// again, or a mark on a notice already sent, changes nothing. A start's
    /// intent takes no row and no notice.
    #[test]
    fn a_job_failure_is_announced_in_the_fleet_log_once_per_intent() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let rows_before = fleet(&path).fleet_log.len();
        let id = intend(&path, &transfer(expected()));
        let text = format!(
            "orch-runtime: successor-not-ready op=request-transfer intent={id} outcome=failed"
        );
        let owed = Notice {
            key: "successor-not-ready".to_owned(),
            text: text.clone(),
            owner: state::NOTICE_OWED.to_owned(),
        };
        let sent = Notice {
            owner: "sent".to_owned(),
            ..owed.clone()
        };
        let marked = |id: &str, notice: &Notice| {
            Request::RecordProgress(Box::new(RecordProgress {
                intent_id: id.to_owned(),
                phase: None,
                obligations: None,
                while_owner: None,
                notice: Some(notice.clone()),
            }))
        };
        // The outcome's own write records the notice owed and the row.
        let Request::RecordOutcome(mut failed) = self::outcome(&id, Outcome::Failed) else {
            panic!()
        };
        failed.observation = Some(json!({"retired": false, "note": "successor-not-ready"}));
        failed.notice = Some(owed.clone());
        let applied = run(&path, &Request::RecordOutcome(failed)).unwrap();
        let Report::RecordOutcome(r) = &applied.report else {
            panic!()
        };
        assert!(r.recorded_now);
        assert_eq!(r.intent.notice, Some(owed.clone()));
        let log = fleet(&path).fleet_log;
        assert_eq!(log.len(), rows_before + 1);
        let row = log.last().unwrap();
        assert_eq!(row["kind"], "close");
        assert_eq!(row["item"], "overseer");
        assert_eq!(row["text"], text);
        assert!(row["at"].is_string());
        assert_eq!(fleet(&path).intents[0].notice, Some(owed.clone()));
        // The send's mark: recorded once, no second row.
        let applied = run(&path, &marked(&id, &sent)).unwrap();
        let Report::RecordProgress(r) = &applied.report else {
            panic!()
        };
        assert_eq!(r.progress, Progress::Recorded);
        assert_eq!(r.intent.notice, Some(sent.clone()));
        assert_eq!(fleet(&path).fleet_log.len(), rows_before + 1);
        assert_eq!(fleet(&path).intents[0].notice, Some(sent.clone()));
        // The same mark again, and a later sender's different mark: nothing
        // recorded anew, the first mark stands.
        let again = run(&path, &marked(&id, &sent)).unwrap();
        let Report::RecordProgress(r) = &again.report else {
            panic!()
        };
        assert_eq!(r.progress, Progress::Unchanged);
        let unsent = Notice {
            owner: "unsent:status=2:refused".to_owned(),
            ..owed.clone()
        };
        let later = run(&path, &marked(&id, &unsent)).unwrap();
        let Report::RecordProgress(r) = &later.report else {
            panic!()
        };
        assert_eq!(r.progress, Progress::Unchanged);
        assert_eq!(fleet(&path).intents[0].notice, Some(sent.clone()));
        assert_eq!(fleet(&path).fleet_log.len(), rows_before + 1);
        // A start's failure carries no row and records no notice.
        fs::write(&path, fixtures::FLEET).unwrap();
        let rows_before = fleet(&path).fleet_log.len();
        let id = intend(&path, &start());
        let Request::RecordOutcome(mut failed) = self::outcome(&id, Outcome::Failed) else {
            panic!()
        };
        failed.notice = Some(owed.clone());
        run(&path, &Request::RecordOutcome(failed)).unwrap();
        assert_eq!(fleet(&path).fleet_log.len(), rows_before);
        assert_eq!(fleet(&path).intents[0].notice, None);
    }

    /// Decision 109 (4): an outcome that changes nothing of the record
    /// leaves the file's bytes as they were; a reconcile reading what the
    /// last one read writes nothing.
    #[test]
    fn an_identical_outcome_recorded_again_moves_no_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let id = intend(&path, &transfer(expected()));
        let unconfirmed = || {
            let Request::RecordOutcome(mut r) = outcome(&id, Outcome::Unconfirmed) else {
                panic!()
            };
            r.launch = None;
            r.session_id = None;
            r.observation = Some(json!({"retired": false, "note": "successor-not-ready"}));
            Request::RecordOutcome(r)
        };
        let first = run(&path, &unconfirmed()).unwrap();
        let bytes = fs::read(&path).unwrap();
        let Report::RecordOutcome(r) = &first.report else {
            panic!()
        };
        assert!(r.recorded_now, "the first outcome is recorded");
        let second = run(&path, &unconfirmed()).unwrap();
        let Report::RecordOutcome(r) = &second.report else {
            panic!()
        };
        assert!(!r.recorded_now, "nothing to record");
        assert_eq!(fs::read(&path).unwrap(), bytes, "the bytes stand");
    }

    /// A Pi successor's publication copies the typed Pi fields as the pending
    /// carries them: the harness word, the provider-bearing model, the seat
    /// it spends and Pi's own home, so the next generation's judgement reads
    /// the account the succession was chosen from.
    #[test]
    fn a_confirmed_pi_transfer_publishes_the_pending_s_provider_bearing_fields() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let mut pi = successor();
        pi.harness = Some("pi".into());
        pi.model = Some("pi-claude/claude-fable-5-1".into());
        pi.effort = Some("high".into());
        pi.account = Some("/a/c2".into());
        pi.home = Some("/a/pi-home".into());
        pi.permission = Some(agent_runtime::launch::Permission::Native);
        pi.extra_args = vec!["--thinking".into(), "high".into()];
        let id = intend(
            &path,
            &Request::RequestTransfer(Box::new(RequestTransfer {
                expected: expected(),
                successor: pi,
                brief_file: None,
                cause: TransferCause::Live,
                exclude_account: None,
                handoff_session_id: None,
                recovery: None,
            })),
        );
        let pending = fleet(&path).overseer.unwrap().pending.unwrap();
        assert_eq!(
            pending.permission,
            Some(agent_runtime::launch::Permission::Native)
        );
        assert_eq!(pending.extra_args, vec!["--thinking", "high"]);
        run(&path, &outcome(&id, Outcome::Confirmed)).unwrap();
        let after = object(&path)["overseer"].clone();
        assert_eq!(after["harness"], json!("pi"));
        assert_eq!(after["model"], json!("pi-claude/claude-fable-5-1"));
        assert_eq!(after["account"], json!("/a/c2"));
        assert_eq!(after["home"], json!("/a/pi-home"));
        assert_eq!(after["effort"], json!("high"));
        assert!(after.get("pending").is_none());
        assert!(
            after.get("permission").is_none(),
            "a launch field, not a record field"
        );
    }
}
