//! The intent journal of the fleet record: the one-open-intent rule, the
//! claim of an intent's owner lease, the progress write and the generic part
//! of the outcome write, each committed through the record store's write
//! check. The record a caller's operation moves beside an outcome is the
//! caller's own, through the arm it passes: the journal writes no member its
//! frame does not own.

use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::clock;
use crate::controller::WatchJob;
use crate::error::{Error, Result};
use crate::intent::{
    EffectOp, Intent, LaunchIdentity, NOTICE_OWED, Notice, OWNER_LIVE, OWNER_UNREAD,
    ObligationRecord, Owner, Phase, PrincipalKeys, Reconciled,
};
use crate::protocol::Outcome;
use crate::record::{self, Document, FLEET_FILE_NAME, Locking};

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
    /// The stamp the call mints: `<nanoseconds since the epoch>-<random>`.
    /// An intent id ends in it.
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
    pub watch: Option<WatchJob>,
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
    /// The keys a terminal carries for its target's record: the lane arms
    /// move the lane only while its launch names nothing but these and its
    /// stamp is the intent's; otherwise the intent closes `intent-stale` and
    /// the lane is left as found. An outcome without them is judged by the
    /// intent's own recorded set, else by its stamp alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub principal_keys: Option<PrincipalKeys>,
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

/// What the journal's outcome write recorded: the intent as written, whether
/// this write moved the record, why the intent closed apart from its own
/// outcome, and what the operation's arm reported of the target record it
/// moved, as the arm wrote it.
#[derive(Debug, Clone, PartialEq)]
pub struct OutcomeWritten {
    pub intent: Intent,
    pub recorded_now: bool,
    pub reconciled: Option<Reconciled>,
    pub target: Map<String, Value>,
}

/// The part of an outcome's transition the intent's operation owns: the
/// target record the outcome moves, judged against the record's target as
/// it stands now. It answers the staleness the intent closes with, `None`
/// where its target is the intent's own; a target that moved notes what it
/// observed on `intent` and answers `IntentStale` on a terminal word
/// (`terminal`), so the handles an unconfirmed outcome's set still holds
/// keep their reader. What it moved it reports into the map, the outcome
/// report's `target`. `E` is the caller's error, which holds this crate's.
pub type OutcomeArm<E> = fn(
    &Path,
    &mut Document,
    &mut Intent,
    &RecordOutcome,
    &str,
    bool,
    &mut Map<String, Value>,
) -> std::result::Result<Option<Reconciled>, E>;

/// Take the owner lease of an open intent whose effect has not started: the
/// detached job's first act, before it opens anything.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClaimIntent {
    pub intent_id: String,
}

/// The intent under its new owner.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IntentClaimed {
    pub intent: Intent,
}

/// Write an effect's progress into its intent before the wait that follows:
/// the phase where one moved and the obligation set as it stands, each
/// written on an open intent alone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordProgress {
    pub intent_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<Phase>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub obligations: Option<ObligationRecord>,
    /// The owner the launcher-side handle writes under: the write is a no-op
    /// once another owner holds the intent, so a job that claimed between the
    /// launcher's last read and its write keeps its own set; `apply` retries
    /// the transition on a conflicting snapshot. `None` writes always.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub while_owner: Option<Owner>,
    /// The failure announcement a job's outcome made, written after the
    /// outcome's own write applied:
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

/// What the store did with a progress write: recorded it; accepted it as
/// the intent already stood, so the revision did not move; or yielded it to
/// the owner that holds the intent now, writing nothing, where the request
/// named `while_owner` and the intent is another's. An unchanged set under
/// the recorded owner is accepted, never yielded.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Progress {
    Recorded,
    Unchanged,
    Yielded { owner: Owner },
}

/// One attempt of a write: the record read, `transition` applied to the
/// document, `between` run, and the document committed through the store's
/// write check against the document it read. The transition's own refusal
/// is the inner result; the store's is the outer, so a write re-applied on
/// `record-changed` is re-applied on the store's refusal alone.
fn attempt<T, E>(
    path: &Path,
    locking: Locking,
    between: &dyn Fn(),
    transition: impl Fn(&mut Document) -> std::result::Result<T, E>,
) -> Result<std::result::Result<T, E>> {
    let Some(read) = record::read_document(path)? else {
        return Err(Error::RecordMissing {
            path: path.to_path_buf(),
        });
    };
    let mut doc = read.clone();
    let report = match transition(&mut doc) {
        Ok(report) => report,
        Err(refused) => return Ok(Err(refused)),
    };
    between();
    record::store(path, &read, &doc, locking)?;
    Ok(Ok(report))
}

/// The one store write of every request and journal write: the record read,
/// `transition` applied to the document, `between` run after it and before
/// the store (the seam a test uses to land another writer's commit in the
/// gap; production passes a no-op), and the document committed through the
/// store's write check against the document it read.
pub fn commit<T, E: From<Error>>(
    path: &Path,
    locking: Locking,
    between: &dyn Fn(),
    transition: impl Fn(&mut Document) -> std::result::Result<T, E>,
) -> std::result::Result<T, E> {
    attempt(path, locking, between, transition)?
}

/// The fleet journal a library write acts on: any other file refuses
/// `op-kind` naming `op`.
pub fn journal_kind(path: &Path, op: &'static str) -> Result<()> {
    if path.file_name().and_then(|n| n.to_str()) != Some(FLEET_FILE_NAME) {
        return Err(Error::refused(
            "op-kind",
            &[
                ("op", op),
                ("path", &path.display().to_string()),
                ("kind", "item"),
                ("wanted", "fleet"),
            ],
        ));
    }
    Ok(())
}

/// The journal's progress write: the phase, the obligation set or the
/// notice's mark on one intent, revision-checked against the set the writer
/// read and conditional on its owner. A write made under an owner is read
/// again while the store refuses `record-changed`, so a claim that landed
/// in the gap is answered with the claimant's state.
pub fn write_progress(
    path: &Path,
    r: &RecordProgress,
    locking: Locking,
) -> Result<ProgressRecorded> {
    journal_kind(path, "record-progress")?;
    let attempt = || commit(path, locking, &|| {}, |doc| record_progress(path, doc, r));
    if r.while_owner.is_some() {
        record::reread(attempt, Error::key)
    } else {
        attempt()
    }
}

/// The journal's claim of an intent's owner lease for the caller, read
/// again while the store refuses `record-changed`: the first store can meet
/// the launcher's own write that lands the instant the job starts.
pub fn write_claim(
    path: &Path,
    r: &ClaimIntent,
    env: &Env,
    locking: Locking,
) -> Result<IntentClaimed> {
    journal_kind(path, "claim-intent")?;
    record::reread(
        || commit(path, locking, &|| {}, |doc| claim_intent(path, doc, r, env)),
        Error::key,
    )
}

/// The journal's outcome write: the intent closed or held with how its
/// effect ended, and `arm` moving the target record in the same locked
/// transition. A write made under an owner is read again while the store
/// refuses `record-changed`.
pub fn write_outcome<E: From<Error>>(
    path: &Path,
    r: &RecordOutcome,
    env: &Env,
    locking: Locking,
    arm: OutcomeArm<E>,
) -> std::result::Result<OutcomeWritten, E> {
    journal_kind(path, "record-outcome")?;
    let once = || {
        attempt(path, locking, &|| {}, |doc| {
            record_outcome(path, doc, r, env, arm)
        })
    };
    if r.while_owner.is_some() {
        record::reread(once, Error::key)?
    } else {
        once()?
    }
}

/// The intent rows of the fleet record at `path`.
pub fn intents(path: &Path, doc: &Document) -> Result<Vec<Intent>> {
    Ok(record::field(path, doc, "intents")?.unwrap_or_default())
}

/// The value of a typed member as the row holds it.
fn json(path: &Path, value: impl Serialize) -> Result<Value> {
    serde_json::to_value(value).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })
}

/// The one-open-intent rule: the open intent on `target` where it is the
/// operation `op` asks for, to reconcile; an open intent of another
/// operation refuses `intent-open`.
pub fn open_intent(intents: &[Intent], op: EffectOp, target: &str) -> Result<Option<Intent>> {
    let Some(intent) = intents.iter().find(|i| i.target == target && i.open()) else {
        return Ok(None);
    };
    if intent.op == op {
        return Ok(Some(intent.clone()));
    }
    Err(Error::IntentOpen {
        intent: intent.id.clone(),
        op: intent.op.word(),
        target: target.to_owned(),
    })
}

/// Any open intent on `target` refuses an operation that has no intent of
/// its own.
pub fn no_open_intent(intents: &[Intent], target: &str) -> Result<()> {
    match intents.iter().find(|i| i.target == target && i.open()) {
        Some(intent) => Err(Error::IntentOpen {
            intent: intent.id.clone(),
            op: intent.op.word(),
            target: target.to_owned(),
        }),
        None => Ok(()),
    }
}

/// Close an intent with how its effect ended and move the record the
/// intent's operation transitions through `arm`. A target whose record
/// moved under the intent closes the intent `intent-stale` and moves
/// nothing, whatever the outcome reports.
pub fn record_outcome<E: From<Error>>(
    path: &Path,
    doc: &mut Document,
    r: &RecordOutcome,
    env: &Env,
    arm: OutcomeArm<E>,
) -> std::result::Result<OutcomeWritten, E> {
    if r.outcome == Outcome::NotStarted {
        return Err(Error::OutcomeInvalid { outcome: r.outcome }.into());
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
        return Ok(OutcomeWritten {
            intent,
            recorded_now: false,
            reconciled: None,
            target: Map::new(),
        });
    }
    if !intent.open() {
        if intent.outcome == r.outcome {
            return Ok(OutcomeWritten {
                intent,
                recorded_now: false,
                reconciled: None,
                target: Map::new(),
            });
        }
        return Err(Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        }
        .into());
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
            }
            .into());
        }
    }
    // The document as read, kept to compare the patched one against: an
    // outcome that changes nothing, a reconcile reading what the last one
    // read, must not move the file.
    let before = doc.clone();
    let mut recorded = OutcomeWritten {
        intent: intent.clone(),
        recorded_now: true,
        reconciled: None,
        target: Map::new(),
    };
    // A reconcile that found the owner still live, or could not read it, wrote
    // this outcome to record only its observation and defer to the owner: it
    // moves no record and marks no staleness, whatever the target now reads.
    let owner_live = matches!(
        r.observation
            .as_ref()
            .and_then(|o| o.get("note"))
            .and_then(Value::as_str),
        Some(OWNER_LIVE | OWNER_UNREAD)
    );
    // A target that moved under the intent closes it only on a terminal word:
    // an `unconfirmed` outcome keeps the intent open, with the generation or
    // status it observed noted, so the handles its set still holds have a
    // reader on the next reconcile; its receipt and job files stay with it.
    let terminal = matches!(r.outcome, Outcome::Confirmed | Outcome::Failed);
    let stale = if owner_live {
        None
    } else {
        arm(
            path,
            doc,
            &mut intent,
            r,
            &at,
            terminal,
            &mut recorded.target,
        )?
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
        record::array_mut(path, doc, "fleet_log")?.push(serde_json::json!({
            "at": at,
            "kind": "close",
            "item": "overseer",
            "text": notice.text,
        }));
        intent.notice = Some(Notice {
            key: notice.key.clone(),
            text: notice.text.clone(),
            to: notice.to.clone(),
            owner: NOTICE_OWED.to_owned(),
        });
    }
    let rows = record::array_mut(path, doc, "intents")?;
    let row = record::element_mut(path, rows, index, "intents")?;
    record::set(row, "outcome", json(path, r.outcome)?);
    if let Some(notice) = &intent.notice
        && r.notice.is_some()
    {
        record::set(row, "notice", json(path, notice)?);
    }
    if let Some(completed_at) = &intent.completed_at {
        record::set(row, "completed_at", completed_at.as_str());
    }
    if let Some(observation) = &r.observation {
        record::set(row, "observation", observation.clone());
    }
    if let Some(reconciled) = stale {
        record::set(row, "reconciled", json(path, reconciled)?);
    }
    if let Some(generation) = intent.observed_generation {
        record::set(row, "observed_generation", generation);
    }
    // An outcome that left the document as it was is recorded nowhere, and the
    // store then writes nothing.
    if record::same_document(path, doc, &before)? {
        recorded.recorded_now = false;
    }
    recorded.reconciled = stale;
    recorded.intent = intent;
    Ok(recorded)
}

/// Hand an open, not yet started intent to the process asking: its owner
/// becomes this `Env`'s. An intent that ended refuses
/// `intent-complete`; one whose effect recorded a phase refuses
/// `intent-started`, since its prior owner opened something a second owner
/// would open again.
pub fn claim_intent(
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
    // its unread record are settled by the claim itself, and the job's own
    // owner lease is what a reconcile reads from here. A set the claim
    // changed is a replaced set: its revision moves, so a token the launcher
    // minted before the claim acts no more.
    if let Some(obligations) = &mut intent.obligations
        && obligations.discharge_where(ObligationRecord::is_job, "claimed") > 0
    {
        obligations.revision += 1;
    }
    let rows = record::array_mut(path, doc, "intents")?;
    let row = record::element_mut(path, rows, index, "intents")?;
    record::set(row, "owner", json(path, &owner)?);
    if let Some(handed_from) = &intent.handed_from {
        record::set(row, "handed_from", json(path, handed_from)?);
    }
    if let Some(obligations) = &intent.obligations {
        record::set(row, "obligations", json(path, obligations)?);
    }
    Ok(IntentClaimed { intent })
}

/// The claimant a write made under `while_owner` yields to: the owner the
/// intent records now, where it is not the one the writer read. A
/// launcher-side handle writes only while it still owns the intent: a job
/// that claimed between the launcher's last read and the write keeps its own
/// record, read under the store lock. The one owner guard of every progress
/// write of an intent's members.
pub fn yielded_to(intent: &Intent, while_owner: Option<&Owner>) -> Option<Owner> {
    let expected = while_owner?;
    (intent.owner.as_ref() != Some(expected))
        .then(|| intent.owner.clone().unwrap_or_else(|| expected.clone()))
}

/// Write an effect's progress. The phase and the
/// obligation set go onto an open intent, refusing `intent-complete` on a
/// closed one as a phase write always has; the sent mark goes onto the
/// notice the outcome's write recorded owed, once: a second write finds it
/// recorded and changes nothing. A write that leaves the document as it was
/// is written nowhere.
pub fn record_progress(
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
    if let Some(owner) = yielded_to(&intent, r.while_owner.as_ref()) {
        return Ok(ProgressRecorded {
            intent,
            progress: Progress::Yielded { owner },
        });
    }
    // A write that carries only a notice mark is a continuation of the
    // intent's recorded outcome, taken on the closed intent; the store's
    // content comparison still holds the mark.
    let continuation = r.phase.is_none() && r.obligations.is_none();
    if !continuation && !intent.open() {
        return Err(Error::IntentComplete {
            id: intent.id.clone(),
            outcome: intent.outcome,
        });
    }
    let before = doc.clone();
    // The notice the outcome's write recorded `owed`, or one whose send got
    // no answer, is marked with how its send went; a notice already marked
    // otherwise, or none recorded, is left as it is, so a second sender
    // changes nothing.
    if let Some(notice) = &r.notice
        && intent
            .notice
            .as_ref()
            .is_some_and(|n| n.owed() || n.unanswered())
    {
        intent.notice = Some(notice.clone());
    }
    let rows = record::array_mut(path, doc, "intents")?;
    let row = record::element_mut(path, rows, index, "intents")?;
    if let Some(notice) = &intent.notice
        && r.notice.is_some()
    {
        record::set(row, "notice", json(path, notice)?);
    }
    if let Some(phase) = &r.phase {
        intent.phase = Some(phase.clone());
        record::set(row, "phase", json(path, phase)?);
    }
    if let Some(obligations) = &r.obligations {
        // The compare-and-swap on the set: the write
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
        record::set(row, "obligations", json(path, &next)?);
    }
    if record::same_document(path, doc, &before)? {
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
