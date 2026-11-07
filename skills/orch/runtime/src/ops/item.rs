//! The item transitions: rounds minted and superseded, a validation run
//! admitted for a round before any work starts, a stage closed with its
//! outcome, a round's admitted runs reconciled against the host, the
//! verification verdict of a published head (recorded, or read from GitHub
//! and then recorded by the `verify` module), and the handoff record a
//! session leaves for the one that continues its round.
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::clock;
use agent_runtime::host;
use agent_runtime::process::{self, Identity};
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Env;
use crate::effects::{self, JobHandle, SidecarRead};
use crate::error::{Error, Result};
use crate::state::{
    self, Authorization, AuthorizedBy, Document, ItemState, Record, Stage, StageKind, StageOutcome,
    SummaryComment, ValidateJob,
};

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

/// Mint a round token, supersede the open stage of the kind and open the
/// new one, in one write.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BeginRound {
    pub kind: RoundKind,
    /// The item's `updatedAt` as the caller's own read of the item returned it,
    /// recorded on the round's stage as handed; the reply says `body_moved`
    /// where it is later than the revision the kind's previous round recorded,
    /// compared as the tracker's own ISO 8601 UTC text. A stale value is
    /// recorded, not judged: the record says what the round read.
    #[serde(default)]
    pub body_revision: Option<String>,
}

/// Record that a validation run was admitted for a round before any work
/// starts, so a run with no process yet is not read as no run.
///
/// Without `run_dir` the runtime mints the run's identity: `run_id` is `<UTC
/// stamp>-<nonce>` and `run_dir` is `<worktree>/tmp/dev-validate-<run_id>`
/// under the item's recorded worktree, the directory `dev-validate-run --run-id
/// <run_id>` then creates. The request is idempotent per round: while an
/// admitted run of the round stands open, a repeat returns that run and writes
/// nothing, whatever clock or nonce the call carries, so a replayed delegation
/// command continues the attempt it admitted instead of minting a second
/// identity. A further attempt is minted only when the request says `attempt:
/// next`, the rerun the dev gate permits after a run that ended without a pass,
/// or when no open admission of the round stands. With `run_dir` the caller's
/// runner minted the identity first, `run_id` is read from the directory's
/// name, and the same directory admitted again is a no-op. An empty `run_dir`
/// is read as absent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordValidationAdmission {
    pub round_id: String,
    #[serde(default)]
    pub run_dir: Option<String>,
    #[serde(default)]
    pub attempt: Attempt,
}

/// Which attempt of the round a minted admission names: the one that
/// stands open, or the next one beside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Attempt {
    #[default]
    Current,
    Next,
}

/// Close a round's stage with its outcome, which the request names: the
/// round acceptance owner computes the word, and no word is assumed. With
/// `run_dir` the open `validate` stage of the round for that run closes
/// instead. `end`, when given, names the artifact whose modification time
/// is the stage's end, bounded to `[start, now]`; the review workflow names
/// the batch's last accepted artifact. Without it the stage ends now.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AcceptResult {
    pub round_id: String,
    #[serde(default)]
    pub run_dir: Option<String>,
    pub outcome: StageOutcome,
    #[serde(default)]
    pub end: Option<EndSource>,
    /// Who accepts the step, recorded on the stage at the close and part of
    /// the acceptance's identity after it. A
    /// round's own close on an item keyed `directive-<id>` must name the
    /// owner's directive, by that id; a run's close (`run_dir`) is the
    /// runner's verdict and names none.
    #[serde(default)]
    pub authorization: Option<Authorization>,
    /// The round's Completion Summary to post after the close, by
    /// `ops::accept`.
    #[serde(default)]
    pub summary_file: Option<PathBuf>,
    /// The files to attach to the summary comment where this acceptance
    /// creates it, the round's screenshots as the dev return artifact names
    /// them; an update keeps the links
    /// the record carries instead.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<PathBuf>,
    /// The comment the post earned, recorded as the item's
    /// `summary_comment` by the acceptance's own repeat of its request. A
    /// caller names the file, never the comment.
    #[serde(default)]
    pub summary_comment: Option<SummaryComment>,
}

/// Where a stage's end is read from: the file whose modification time the
/// acceptance rests on, stat'ed by the runtime at the close.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EndSource {
    pub from_artifact: PathBuf,
}

/// Reconcile a round's admitted validation runs against the host, so no
/// admitted run stays open after it ended. Every open
/// `validate` stage of the round is read through its run directory: an
/// ended run, its sentinel written, closes with the word the sentinel
/// names; an admitted directory that was never created, a refused or never
/// attempted start, closes `stopped`; a run whose recorded child is gone
/// with no sentinel, or that never recorded one, closes `lost`; a run whose
/// recorded child still runs stays open; a run whose process or files
/// cannot be read stays open and is reported so. The stages' starts, the
/// `validate_rounds` cost rows and every other key are untouched.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReconcileRound {
    pub round_id: String,
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
    /// The reader, such as `verify-pr`.
    pub source: String,
}

/// Verify a published head where it stands and record the verdict.
/// `verify::run` reads GitHub for `head`, a full 40-hex
/// lowercase commit id, on `base` of `repo` (`owner/name`), and on a final
/// verdict writes `.verification` through [`RecordVerification`] in the
/// same call. `required_only` judges the base's required contexts alone
/// and, where it names none and no check exists, derives `none` from the
/// absence probes. The reads come before the transition, so `apply`
/// refuses this request as `op-not-transition`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerifyHead {
    pub repo: String,
    pub base: String,
    pub head: String,
    #[serde(default)]
    pub required_only: bool,
}

/// The session route a relaunch over a standing handoff takes: a `fresh`
/// session that continues from the record, or a `resume` of the session
/// the lane is bound to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Relaunch {
    Fresh,
    Resume,
}

/// Write the lane's handoff record, `.handoff`, for the session that
/// continues the item: the round it continues, what merged, what remains,
/// the branch, worktree, open pull request and traps, the context decision
/// that caused it and the relaunch route. `written_at` is stamped from the
/// runtime's clock when absent; a given one must be ISO 8601 UTC and not
/// later than that clock. The content, every field but `written_at`, is
/// the operation's identity: a repeat with the same content is a no-op that
/// reports the standing record's stamp, a standing record with other
/// content refuses unless `supersede` is set, and a supersede keeps the
/// record's `resumed_at`, so a consumed handoff stays consumed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordHandoff {
    #[serde(default)]
    pub supersede: bool,
    #[serde(default)]
    pub round_id: Option<String>,
    #[serde(default)]
    pub merged: Vec<String>,
    #[serde(default)]
    pub remaining: Vec<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub worktree: Option<String>,
    #[serde(default)]
    pub open_pr: Value,
    #[serde(default)]
    pub traps: Vec<String>,
    #[serde(default)]
    pub context: Value,
    #[serde(default)]
    pub relaunch: Option<Relaunch>,
    /// The session the lane handed off from and why, as the turn-end hook
    /// records them on a model switch: the relaunch resumes the session they
    /// name. Each is written only where given.
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub pane_key: Option<String>,
    #[serde(default)]
    pub cause: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub written_at: Option<String>,
}

/// Stamp the standing handoff record resumed and report the round it
/// continues. A record stands while its `resumed_at` is unset; a second
/// resume changes nothing and reports the first stamp.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResumeHandoff {}

/// The verdicts a verification record carries. A read that ended without
/// a result (`pending`, `unreadable`) is no verdict about the head: it is
/// refused, never recorded.
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

    pub fn word(self) -> &'static str {
        match self {
            Verdict::Pass => "pass",
            Verdict::Fail => "fail",
            Verdict::None => "none",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoundBegun {
    pub kind: RoundKind,
    pub round_id: String,
    pub start: u64,
    /// The round ids of the open stages of this kind the new round closed.
    pub superseded: Vec<Option<String>>,
    /// True where `body_revision` was handed and is later than the
    /// one the kind's previous round recorded; false with nothing to
    /// compare.
    pub body_moved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidationAdmitted {
    pub round_id: String,
    pub run_id: String,
    pub run_dir: String,
    /// True when this call minted the run's identity. False when the
    /// caller's runner named it, or an admitted run of the round already
    /// stood and its identity won.
    pub minted: bool,
    pub start: u64,
    /// False when the same run was already admitted.
    pub admitted_now: bool,
}

/// A stage closed with its outcome.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResultAccepted {
    pub round_id: String,
    pub kind: StageKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_dir: Option<String>,
    pub start: u64,
    pub end: u64,
    /// The word on the stage; absent on a stage another writer closed
    /// without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<StageOutcome>,
    /// False when the stage was already closed.
    pub closed_now: bool,
    /// The authorization the stage was closed under.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authorization: Option<Authorization>,
    /// The item's recorded Completion Summary comment, after this
    /// request's own record of it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary_comment: Option<SummaryComment>,
    /// How this acceptance's summary post ended, where a file was named.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<super::accept::SummaryPost>,
}

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

/// A handoff record written, or found standing with the same content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandoffRecorded {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round_id: Option<String>,
    /// The record's stamp: this write's, or the standing record's on a
    /// repeat.
    pub written_at: String,
    /// True when a record with other content stood and this write replaced
    /// it.
    pub replaced: bool,
    /// False when the same content already stood and nothing was written.
    pub recorded_now: bool,
}

/// A round's admitted runs reconciled: one row per open `validate` stage
/// the round had when the call began.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoundReconciled {
    pub round_id: String,
    pub runs: Vec<RunReconciled>,
}

/// What the reconcile found for one admitted run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunReconciled {
    pub run_dir: String,
    #[serde(flatten)]
    pub state: RunState,
}

/// How an admitted run stands after the reconcile read it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum RunState {
    /// The recorded child, or the started run's job, still runs; the stage
    /// stays open.
    Live { pid: u32 },
    /// The started run's unit still runs under the user manager.
    LiveUnit { unit: String },
    /// This call closed the stage with the word. A stage an earlier call
    /// closed is not read again and has no row.
    Closed {
        outcome: StageOutcome,
        cause: RunCause,
        /// The run's wall time from its `timing` record; absent where the
        /// run left none, which is reported, never estimated.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seconds: Option<u64>,
    },
    /// The run's files or process could not be read; the stage stays open
    /// and the cause is the reader's.
    Unreadable { cause: String },
}

/// What closed an admitted run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RunCause {
    /// The run's own sentinel named the word.
    Sentinel,
    /// The admitted directory was never created: the start was refused or
    /// never attempted. The runner records no refusal cause anywhere the
    /// runtime can read, so this is the cause it can state.
    RunDirAbsent,
    /// The recorded child is gone and left no sentinel.
    ProcessGone,
    /// The directory holds no sentinel and no recorded child: the launch
    /// failed or the child died before it recorded its process id.
    PidUnrecorded,
    /// The started run's unit ended under the user manager with no
    /// sentinel.
    UnitEnded,
    /// The launcher's record says the launch ended with nothing started.
    LaunchFailed,
}

/// A run of the round the continuation reads instead of starting a new one:
/// an open validation stage it waits on (`outcome` none), or a stage that
/// ended while the lane was away, whose recorded `outcome` the continuation
/// reuses. Listed newest first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenRun {
    pub run_dir: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<StageOutcome>,
}

/// A handoff record stamped resumed: what the continuing session reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandoffResumed {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relaunch: Option<Relaunch>,
    pub remaining: Vec<String>,
    /// The round's runs whose result the continuation has not consumed: its
    /// open validation stages and the stages closed since the handoff, each
    /// with its outcome.
    pub open_runs: Vec<OpenRun>,
    pub resumed_at: u64,
    /// False when the record was already stamped; `resumed_at` is then the
    /// first stamp.
    pub resumed_now: bool,
}

/// The handoff record as the resume reads it. Every other field stays in
/// the document, unread.
#[derive(Debug, Clone, PartialEq, Deserialize)]
struct HandoffRecord {
    #[serde(default)]
    round_id: Option<String>,
    #[serde(default)]
    remaining: Vec<String>,
    #[serde(default)]
    relaunch: Option<Relaunch>,
    #[serde(default)]
    resumed_at: Option<u64>,
}

fn stages(path: &Path, doc: &Document) -> Result<Vec<Stage>> {
    Ok(ItemState::view(path, doc)?.stages)
}

/// True when a non-validate stage of the item carries the round.
fn round_known(stages: &[Stage], round_id: &str) -> bool {
    stages
        .iter()
        .any(|s| s.kind != StageKind::Validate && s.round_id.as_deref() == Some(round_id))
}

const RUN_DIR_PREFIX: &str = "dev-validate-";

/// The item a state file names: the stem after `workflow-state-`.
fn item_name(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .and_then(|s| s.strip_prefix("workflow-state-"))
        .unwrap_or_default()
        .to_owned()
}

/// The run id a run directory's name carries: its basename without the
/// prefix, or the whole basename where a caller named it otherwise.
fn run_id_of(run_dir: &str) -> String {
    let name = Path::new(run_dir)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(run_dir);
    name.strip_prefix(RUN_DIR_PREFIX).unwrap_or(name).to_owned()
}

/// The run id the runtime mints: the compact UTC stamp `dev-validate-run`
/// names its directories with, then the call's nonce, so two admissions in
/// one second never share a directory.
fn mint_run_id(env: &Env) -> String {
    let stamp: String = env
        .iso()
        .chars()
        .filter(|c| *c != '-' && *c != ':')
        .collect();
    format!("{stamp}-{}", env.nonce)
}

pub(super) fn begin_round(
    path: &Path,
    doc: &mut Document,
    r: &BeginRound,
    env: &Env,
) -> Result<RoundBegun> {
    let round_id = env.round_id();
    let now = env.now_secs;
    let stages = stages(path, doc)?;
    // The kind's previous round is the last stage of the kind that
    // recorded a revision; the stamps are the tracker's own ISO 8601 UTC
    // text, so later is greater.
    let previous = stages
        .iter()
        .rev()
        .filter(|s| s.kind == r.kind.stage())
        .find_map(|s| s.body_revision.as_deref());
    let body_moved = match (r.body_revision.as_deref(), previous) {
        (Some(now), Some(before)) => now > before,
        (_, _) => false,
    };
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
    let mut row = json!({
        "kind": r.kind.stage().word(),
        "round_id": round_id,
        "start": now,
        "end": Value::Null,
    });
    if let Some(revision) = &r.body_revision {
        row["body_revision"] = json!(revision);
    }
    rows.push(row);
    Ok(RoundBegun {
        kind: r.kind,
        round_id,
        start: now,
        superseded,
        body_moved,
    })
}

pub(super) fn record_validation_admission(
    path: &Path,
    doc: &mut Document,
    r: &RecordValidationAdmission,
    env: &Env,
) -> Result<ValidationAdmitted> {
    let stages = stages(path, doc)?;
    if !round_known(&stages, &r.round_id) {
        return Err(Error::RoundUnknown {
            round_id: r.round_id.clone(),
        });
    }
    let given = r.run_dir.as_deref().filter(|d| !d.is_empty());
    let (run_id, run_dir, minted) = match given {
        Some(run_dir) => {
            if let Some(existing) = stages.iter().find(|s| {
                s.kind == StageKind::Validate
                    && s.round_id.as_deref() == Some(&r.round_id)
                    && s.run_dir.as_deref() == Some(run_dir)
            }) {
                return Ok(ValidationAdmitted {
                    round_id: r.round_id.clone(),
                    run_id: run_id_of(run_dir),
                    run_dir: run_dir.to_owned(),
                    minted: false,
                    start: existing.start,
                    admitted_now: false,
                });
            }
            (run_id_of(run_dir), run_dir.to_owned(), false)
        }
        None => {
            // The operation's identity is the round: the open admission is
            // the request's result until the request asks for the next
            // attempt, so a replay never mints a second run.
            let open = stages.iter().rev().find_map(|s| {
                (s.kind == StageKind::Validate
                    && s.round_id.as_deref() == Some(&r.round_id)
                    && s.end.is_none())
                .then(|| s.run_dir.as_deref().map(|d| (d, s.start)))
                .flatten()
            });
            if let (Attempt::Current, Some((run_dir, start))) = (r.attempt, open) {
                return Ok(ValidationAdmitted {
                    round_id: r.round_id.clone(),
                    run_id: run_id_of(run_dir),
                    run_dir: run_dir.to_owned(),
                    minted: false,
                    start,
                    admitted_now: false,
                });
            }
            let worktree: Option<String> = state::field(path, doc, "worktree")?;
            let worktree =
                worktree
                    .filter(|w| !w.is_empty())
                    .ok_or_else(|| Error::WorktreeUnrecorded {
                        path: path.to_path_buf(),
                    })?;
            let run_id = mint_run_id(env);
            let run_dir = format!("{worktree}/tmp/{RUN_DIR_PREFIX}{run_id}");
            (run_id, run_dir, true)
        }
    };
    state::array_mut(path, doc, "stages")?.push(json!({
        "kind": StageKind::Validate.word(),
        "round_id": r.round_id,
        "start": env.now_secs,
        "end": Value::Null,
        "run_dir": run_dir,
    }));
    Ok(ValidationAdmitted {
        round_id: r.round_id.clone(),
        run_id,
        run_dir,
        minted,
        start: env.now_secs,
        admitted_now: true,
    })
}

pub(super) fn accept_result(
    path: &Path,
    doc: &mut Document,
    r: &AcceptResult,
    env: &Env,
) -> Result<ResultAccepted> {
    accept_result_at(path, doc, r, None, env)
}

/// [`accept_result`] with the end the caller read itself, where it gives
/// one: the validation job's close at its sentinel's time; the request's
/// own source, or now, otherwise.
pub(super) fn accept_result_at(
    path: &Path,
    doc: &mut Document,
    r: &AcceptResult,
    read_end: Option<u64>,
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
    // A directed item's step is accepted under the owner's directive alone;
    // its runs close on their verdicts.
    if r.run_dir.is_none()
        && let Some(directive) = state::directive_of(path)
        && !r
            .authorization
            .as_ref()
            .is_some_and(|a| a.by == AuthorizedBy::OwnerDirective && a.id == directive)
    {
        return Err(Error::AuthorizationMissing {
            directive: directive.to_owned(),
        });
    }
    // The authorization is part of the acceptance's identity: a closed
    // stage keeps the one it was closed under.
    if stage.end.is_some()
        && let Some(given) = &r.authorization
        && stage.authorization.as_ref() != Some(given)
    {
        return Err(Error::AuthorizationDiffers {
            round_id: r.round_id.clone(),
        });
    }
    let end = match (read_end, &r.end) {
        (Some(end), _) => end,
        (None, Some(source)) => artifact_mtime(&source.from_artifact)?,
        (None, None) => env.now_secs,
    };
    let closed = close_stage(path, doc, index, stage, end, r.outcome, env)?;
    let authorization = match (closed.closed_now, &r.authorization) {
        (true, Some(given)) => {
            let rows = state::array_mut(path, doc, "stages")?;
            let row = state::element_mut(path, rows, index, "stages")?;
            state::set(row, "authorization", serde_json::to_value(given)?);
            Some(given.clone())
        }
        (true, None) => None,
        (false, _) => stage.authorization.clone(),
    };
    let summary_comment = record_summary_comment(path, doc, r.summary_comment.as_ref())?;
    Ok(ResultAccepted {
        round_id: r.round_id.clone(),
        kind: stage.kind,
        run_dir: stage.run_dir.clone(),
        start: stage.start,
        end: closed.end,
        outcome: closed.outcome,
        closed_now: closed.closed_now,
        authorization,
        summary_comment,
        summary: None,
    })
}

const SUMMARY_COMMENT_KEY: &str = "summary_comment";

/// Record the comment the acceptance's post earned or its list found, and
/// answer the item's recorded comment after it. The id alone is the comment's
/// identity: a given id that differs refuses, so no comment is orphaned by a
/// second record, and a given naming the recorded id writes its stamp and
/// attachments over the record's.
fn record_summary_comment(
    path: &Path,
    doc: &mut Document,
    given: Option<&SummaryComment>,
) -> Result<Option<SummaryComment>> {
    let recorded: Option<SummaryComment> = state::field(path, doc, SUMMARY_COMMENT_KEY)?;
    let Some(given) = given else {
        return Ok(recorded);
    };
    if let Some(recorded) = &recorded
        && recorded.id != given.id
    {
        return Err(Error::SummaryCommentDiffers {
            path: path.to_path_buf(),
            recorded: recorded.id.clone(),
            given: given.id.clone(),
        });
    }
    state::set(doc, SUMMARY_COMMENT_KEY, serde_json::to_value(given)?);
    Ok(Some(given.clone()))
}

/// The modification time of the artifact an acceptance rests on, in epoch
/// seconds; a file that cannot be stat'ed refuses, never ends the stage now.
#[allow(
    clippy::disallowed_methods,
    reason = "arithmetic over a file's recorded modification time, read from its metadata; no clock is read"
)]
fn artifact_mtime(artifact: &Path) -> Result<u64> {
    let unreadable = |cause: String| Error::EndArtifactUnreadable {
        path: artifact.to_path_buf(),
        cause,
    };
    let modified = fs::metadata(artifact)
        .and_then(|m| m.modified())
        .map_err(|e| unreadable(e.to_string()))?;
    modified
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|e| unreadable(e.to_string()))
}

/// A stage as a close left it.
pub(super) struct Closed {
    pub(super) end: u64,
    /// The word on the stage; absent on a stage another writer closed
    /// without one.
    pub(super) outcome: Option<StageOutcome>,
    pub(super) closed_now: bool,
}

/// The one close of a stage: `end` is held to `[start, now]` before anything
/// else, a stale request being a request error whatever the stage holds; an
/// open stage takes the end and the word, a closed one keeps its own and
/// reports them.
pub(super) fn close_stage(
    path: &Path,
    doc: &mut Document,
    index: usize,
    stage: &Stage,
    end: u64,
    outcome: StageOutcome,
    env: &Env,
) -> Result<Closed> {
    if end < stage.start || end > env.now_secs {
        return Err(Error::EndOutOfRange {
            round_id: stage.round_id.clone().unwrap_or_default(),
            end,
            start: stage.start,
            now: env.now_secs,
        });
    }
    Ok(match stage.end {
        Some(recorded) => Closed {
            end: recorded,
            outcome: stage.outcome,
            closed_now: false,
        },
        None => {
            let rows = state::array_mut(path, doc, "stages")?;
            let row = state::element_mut(path, rows, index, "stages")?;
            state::set(row, "end", end);
            state::set(row, "outcome", outcome.word());
            Closed {
                end,
                outcome: Some(outcome),
                closed_now: true,
            }
        }
    })
}

/// How a run directory reads at the reconcile: the sentinel's verdict and
/// time once the run ended, the recorded child's liveness before, or what
/// its absence means.
enum RunRead {
    Ended {
        outcome: StageOutcome,
        /// The sentinel's `at=` time, where it parses.
        at: Option<u64>,
        seconds: Option<u64>,
    },
    Live {
        pid: u32,
    },
    /// The recorded unit still runs under the user manager.
    LiveUnit {
        unit: String,
    },
    /// No run will end: the word its absence closes with, and why.
    Gone {
        outcome: StageOutcome,
        cause: RunCause,
    },
    Unreadable(String),
}

/// The seconds the user manager is given to answer for a unit.
const UNIT_READ_TIMEOUT: Duration = Duration::from_secs(30);

/// What a unit's `LoadState` and `ActiveState` say of the job: ended, or
/// still running (`None`), as the operation handle reads its own jobs.
fn unit_ended(load: &str, active: &str) -> Option<bool> {
    match (load, active) {
        ("not-found", _) => Some(true),
        ("loaded", "inactive" | "failed") => Some(true),
        ("loaded", _) => Some(false),
        (_, _) => None,
    }
}

/// The job a started run records, read by its identity: the unit through
/// the user manager, or the group its process leads by the shared group
/// reading (the leader by pid and start, then the group's members), so a
/// pid the system reused reads gone under another start and never keeps a
/// dead run open, and a leader that exited leaving a member is a job still
/// running. A job whose launcher never answered is
/// read from the launcher's record beside the run, through the one reader
/// of that record: an ended launch is nothing started, a group the launcher
/// could not read empty is read by its key, and a record that names no
/// identity is unreadable, never gone.
#[allow(
    clippy::disallowed_methods,
    reason = "a started validation run's job is read by its recorded identity for the stage's reconcile, the unit through the user manager, the process through the one reader; nothing is signalled here"
)]
fn read_job(job: &ValidateJob) -> RunRead {
    let (runner, unit, pid, start) = match job.runner.as_deref() {
        Some(runner) => (
            runner.to_owned(),
            job.unit.clone(),
            job.pid,
            job.start.clone(),
        ),
        // The launcher was asked and the start never wrote its answer: the
        // record it writes before the fork is the job's own statement.
        None => match effects::read_handle(Path::new(&job.record)) {
            SidecarRead::Absent => {
                return RunRead::Gone {
                    outcome: StageOutcome::Lost,
                    cause: RunCause::PidUnrecorded,
                };
            }
            SidecarRead::Failed { .. } => {
                return RunRead::Gone {
                    outcome: StageOutcome::Stopped,
                    cause: RunCause::LaunchFailed,
                };
            }
            SidecarRead::Unreadable { cause } => {
                return RunRead::Unreadable(format!("job record: {cause}"));
            }
            SidecarRead::Present(JobHandle::Unit { unit }) => {
                ("systemd".to_owned(), Some(unit), None, None)
            }
            SidecarRead::Present(JobHandle::Group(identity)) => (
                "setsid".to_owned(),
                None,
                Some(identity.pid),
                Some(identity.start),
            ),
            SidecarRead::Present(JobHandle::Pgid(pgid)) => {
                return match effects::pgid_reading(pgid) {
                    Reading::Live(()) => RunRead::Live { pid: pgid },
                    Reading::Gone => RunRead::Gone {
                        outcome: StageOutcome::Lost,
                        cause: RunCause::ProcessGone,
                    },
                    Reading::Unreadable { cause } => {
                        RunRead::Unreadable(format!("job group {pgid}: {cause}"))
                    }
                };
            }
        },
    };
    if runner == "attached" {
        return read_attached(job, pid, start);
    }
    match (runner.as_str(), unit, pid, start) {
        ("systemd", Some(unit), _, _) => {
            let service = format!("{unit}.service");
            let out = host::run_tagged(
                "validate",
                "systemctl",
                Path::new("systemctl"),
                "show",
                &[
                    "--user",
                    "show",
                    "-p",
                    "LoadState,ActiveState",
                    "--value",
                    "--",
                    &service,
                ],
                UNIT_READ_TIMEOUT,
            );
            let out = match out {
                Ok(out) if out.status.success() => out,
                Ok(out) => {
                    return RunRead::Unreadable(format!(
                        "unit {unit}: {}",
                        host::stderr_text(&out)
                    ));
                }
                Err(e) => return RunRead::Unreadable(format!("unit {unit}: {e}")),
            };
            let text = host::stdout_text(&out);
            let mut lines = text.lines();
            match unit_ended(
                lines.next().unwrap_or_default(),
                lines.next().unwrap_or_default(),
            ) {
                Some(true) => RunRead::Gone {
                    outcome: StageOutcome::Lost,
                    cause: RunCause::UnitEnded,
                },
                Some(false) => RunRead::LiveUnit { unit },
                None => RunRead::Unreadable(format!("unit {unit}: state {text:?}")),
            }
        }
        (_, _, Some(pid), Some(start)) => match effects::group_reading(&Identity { pid, start }) {
            Reading::Live(()) => RunRead::Live { pid },
            Reading::Gone => RunRead::Gone {
                outcome: StageOutcome::Lost,
                cause: RunCause::ProcessGone,
            },
            Reading::Unreadable { cause } => RunRead::Unreadable(format!("job pid {pid}: {cause}")),
        },
        (runner, _, _, _) => RunRead::Unreadable(format!("job runner {runner:?}: no identity")),
    }
}

/// A foreground run's job is the caller's own process, which leads no group
/// of its own, while the command it started leads one: the executor is read
/// by its identity, and once it is gone the command it recorded in the run
/// directory holds the run until that command's group ends.
#[allow(
    clippy::disallowed_methods,
    reason = "a foreground run's executor is read by its recorded identity for the stage's reconcile; nothing is signalled here"
)]
fn read_attached(job: &ValidateJob, pid: Option<u32>, start: Option<String>) -> RunRead {
    let (Some(pid), Some(start)) = (pid, start) else {
        return RunRead::Unreadable("job runner \"attached\": no identity".to_owned());
    };
    match process::still_runs(&Identity { pid, start }) {
        Reading::Live(_) => return RunRead::Live { pid },
        Reading::Unreadable { cause } => {
            return RunRead::Unreadable(format!("job pid {pid}: {cause}"));
        }
        Reading::Gone => {}
    }
    let Some(run_dir) = Path::new(&job.record).parent() else {
        return RunRead::Unreadable(format!("job record {}: no run directory", job.record));
    };
    match crate::validate::run::command_reading(run_dir) {
        Ok(Some(Reading::Live(()))) => RunRead::Live { pid },
        Ok(Some(Reading::Unreadable { cause })) => {
            RunRead::Unreadable(format!("command of job pid {pid}: {cause}"))
        }
        Ok(Some(Reading::Gone) | None) => RunRead::Gone {
            outcome: StageOutcome::Lost,
            cause: RunCause::ProcessGone,
        },
        Err(e) => RunRead::Unreadable(format!("command of job pid {pid}: {e}")),
    }
}

/// Whether the job a started run records has ended, for the stop's bounded
/// wait on the job it ended: `Some(true)` read gone
/// by its identity, `Some(false)` live, `None` where the read could not
/// say, which is never gone.
pub(crate) fn job_ended(job: &ValidateJob) -> Option<bool> {
    match read_job(job) {
        RunRead::Gone { .. } => Some(true),
        RunRead::Live { .. } | RunRead::LiveUnit { .. } => Some(false),
        RunRead::Unreadable(_) => None,
        RunRead::Ended { .. } => unreachable!("the job's identity read names no sentinel"),
    }
}

/// One file of a run directory: its text, `None` where it does not exist
/// or is empty (the runner writes each whole, by rename, and reads an empty
/// one as absent).
fn run_file(run_dir: &Path, name: &str) -> std::result::Result<Option<String>, String> {
    match fs::read_to_string(run_dir.join(name)) {
        Ok(text) if text.trim().is_empty() => Ok(None),
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("{name}: {e}")),
    }
}

/// The `key=value` line of a run record, as `dev-validate-run` writes its
/// `start` and `timing` files.
fn record_field(text: &str, key: &str) -> Option<String> {
    text.lines()
        .find_map(|l| l.strip_prefix(key).and_then(|rest| rest.strip_prefix('=')))
        .map(str::to_owned)
}

/// The sentinel a run directory holds, as an `Ended` read: its verdict, the
/// `at=` time where it parses and the `timing` seconds. `None` where no
/// sentinel stands; an unreadable file or an exit line that is no sentinel is
/// the reader's cause.
fn sentinel_ended(run_dir: &Path) -> std::result::Result<Option<RunRead>, String> {
    let Some(line) = run_file(run_dir, "exit")? else {
        return Ok(None);
    };
    let line = line.trim_end();
    let Some(outcome) = super::validate::sentinel_outcome(line) else {
        return Err(format!("exit: no sentinel line in {line:?}"));
    };
    let at = line
        .split(' ')
        .find_map(|f| f.strip_prefix("at="))
        .and_then(clock::epoch_secs);
    let seconds = run_file(run_dir, "timing")?
        .as_deref()
        .and_then(|t| record_field(t, "seconds"))
        .and_then(|s| s.parse().ok());
    Ok(Some(RunRead::Ended {
        outcome,
        at,
        seconds,
    }))
}

#[allow(
    clippy::disallowed_methods,
    reason = "a validation run's recorded pid is read beside the record for the stage's reconcile; it is never signalled here"
)]
fn read_run(run_dir: &Path, job: Option<&ValidateJob>) -> RunRead {
    // Three-valued: the directory is opened for listing, and
    // only `NotFound` proves it absent; a path that is not a directory, or
    // one that cannot be read, holds the stage as unreadable rather than
    // closing it.
    match fs::read_dir(run_dir) {
        Ok(_) => {}
        Err(e) if e.kind() == ErrorKind::NotFound => {
            return RunRead::Gone {
                outcome: StageOutcome::Stopped,
                cause: RunCause::RunDirAbsent,
            };
        }
        Err(e) => return RunRead::Unreadable(format!("run directory: {e}")),
    }
    // A run the runtime started is read by its job's identity first: while
    // the job lives it owns the close and the end notice, so its stage stays
    // open even past the sentinel the child wrote; only a job read gone
    // falls to the sentinel it left, which the reconcile then closes with the
    // notice owed. A run that ran nothing, or one its caller's runner
    // started, has no runtime job and falls through.
    if let Some(job) = job.filter(|j| j.runner.as_deref() != Some("none")) {
        return match read_job(job) {
            RunRead::Gone { outcome, cause } => match sentinel_ended(run_dir) {
                Ok(Some(ended)) => ended,
                Ok(None) => RunRead::Gone { outcome, cause },
                Err(cause) => RunRead::Unreadable(cause),
            },
            other => other,
        };
    }
    // A run its caller's runner started: the sentinel first, then the
    // child's bare pid.
    match sentinel_ended(run_dir) {
        Ok(Some(ended)) => return ended,
        Ok(None) => {}
        Err(cause) => return RunRead::Unreadable(cause),
    }
    let pid = match run_file(run_dir, "pid") {
        Ok(None) => {
            return RunRead::Gone {
                outcome: StageOutcome::Lost,
                cause: RunCause::PidUnrecorded,
            };
        }
        Ok(Some(text)) => match text.trim().parse::<u32>() {
            Ok(pid) => pid,
            Err(e) => return RunRead::Unreadable(format!("pid: {e}")),
        },
        Err(cause) => return RunRead::Unreadable(cause),
    };
    // The caller's runner records the child's pid and no process start, so
    // this is a pid read, not an identity read: a reused pid keeps a dead
    // run open; it never closes a live one. A run the runtime started is
    // read by its job's identity above.
    match process::identity(pid) {
        Reading::Live(_) => RunRead::Live { pid },
        Reading::Gone => RunRead::Gone {
            outcome: StageOutcome::Lost,
            cause: RunCause::ProcessGone,
        },
        Reading::Unreadable { cause } => RunRead::Unreadable(format!("pid {pid}: {cause}")),
    }
}

pub(super) fn reconcile_round(
    path: &Path,
    doc: &mut Document,
    r: &ReconcileRound,
    env: &Env,
) -> Result<RoundReconciled> {
    let stages = stages(path, doc)?;
    if !round_known(&stages, &r.round_id) {
        return Err(Error::RoundUnknown {
            round_id: r.round_id.clone(),
        });
    }
    let item = item_name(path);
    let mut runs = Vec::new();
    for (index, stage) in stages.iter().enumerate() {
        if stage.kind != StageKind::Validate
            || stage.round_id.as_deref() != Some(&r.round_id)
            || stage.end.is_some()
        {
            continue;
        }
        let Some(run_dir) = stage.run_dir.clone() else {
            continue;
        };
        let (outcome, end, cause, seconds) = match read_run(Path::new(&run_dir), stage.job.as_ref())
        {
            RunRead::Live { pid } => {
                runs.push(RunReconciled {
                    run_dir,
                    state: RunState::Live { pid },
                });
                continue;
            }
            RunRead::LiveUnit { unit } => {
                runs.push(RunReconciled {
                    run_dir,
                    state: RunState::LiveUnit { unit },
                });
                continue;
            }
            RunRead::Unreadable(cause) => {
                runs.push(RunReconciled {
                    run_dir,
                    state: RunState::Unreadable { cause },
                });
                continue;
            }
            RunRead::Ended {
                outcome,
                at,
                seconds,
            } => {
                // The sentinel's time is the end where it lies in the
                // stage's bounds; a time outside them, a clock the runner
                // and this host disagree on, yields to the reconcile's.
                let end = at
                    .filter(|t| (stage.start..=env.now_secs).contains(t))
                    .unwrap_or(env.now_secs);
                (outcome, end, RunCause::Sentinel, seconds)
            }
            // A job gone with no sentinel closes `lost`, unless the stage
            // records the intentional stop `validate stop` wrote before it
            // ended the job: then `stopped`, the word the
            // job's own close reads the same way. No one recorded an
            // intent for a `lost` run.
            RunRead::Gone { outcome, cause } => {
                let outcome = match (outcome, &stage.stop) {
                    (StageOutcome::Lost, Some(_)) => StageOutcome::Stopped,
                    (word, _) => word,
                };
                (outcome, env.now_secs, cause, None)
            }
        };
        close_stage(path, doc, index, stage, end, outcome, env)?;
        // A runtime-started run's close owes its lane the end notice, written
        // in the same transition; the owed walk after the reconcile sends it.
        // The job closed a live run itself and already owns its notice; a run
        // with no runtime job owes none.
        if stage
            .job
            .as_ref()
            .is_some_and(|j| j.runner.as_deref() != Some("none"))
        {
            let notice = super::validate::end_notice(&run_id_of(&run_dir), &run_dir, outcome);
            let rows = state::array_mut(path, doc, "stages")?;
            let row = state::element_mut(path, rows, index, "stages")?;
            state::set(
                row,
                "notice",
                serde_json::to_value(state::Notice {
                    key: notice.key,
                    text: notice.text,
                    to: Some(item.clone()),
                    owner: state::NOTICE_OWED.to_owned(),
                })?,
            );
        }
        runs.push(RunReconciled {
            run_dir,
            state: RunState::Closed {
                outcome,
                cause,
                seconds,
            },
        });
    }
    Ok(RoundReconciled {
        round_id: r.round_id.clone(),
        runs,
    })
}

const VERIFICATION_KEY: &str = "verification";

pub(super) fn record_verification(
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

const HANDOFF_KEY: &str = "handoff";

/// The stamp rule for `written_at`: absent or empty is stamped from
/// the clock; a given stamp must be the ISO 8601 UTC form and not later
/// than the clock, and a past one is kept.
fn written_at(given: Option<&str>, env: &Env) -> Result<String> {
    let Some(given) = given.filter(|g| !g.is_empty()) else {
        return Ok(env.iso());
    };
    let secs = clock::epoch_secs(given).ok_or_else(|| Error::HandoffWrittenAtInvalid {
        written_at: given.to_owned(),
    })?;
    if secs > env.now_secs {
        return Err(Error::HandoffWrittenAtFuture {
            written_at: given.to_owned(),
            now: env.iso(),
        });
    }
    Ok(given.to_owned())
}

pub(super) fn record_handoff(
    path: &Path,
    doc: &mut Document,
    r: &RecordHandoff,
    env: &Env,
) -> Result<HandoffRecorded> {
    if let Some(round_id) = &r.round_id
        && !round_known(&stages(path, doc)?, round_id)
    {
        return Err(Error::RoundUnknown {
            round_id: round_id.clone(),
        });
    }
    let written_at = written_at(r.written_at.as_deref(), env)?;
    let mut record = Document::new();
    for (key, value) in [
        ("round_id", json!(r.round_id)),
        ("merged", json!(r.merged)),
        ("remaining", json!(r.remaining)),
        ("branch", json!(r.branch)),
        ("worktree", json!(r.worktree)),
        ("open_pr", r.open_pr.clone()),
        ("traps", json!(r.traps)),
        ("context", r.context.clone()),
        ("relaunch", json!(r.relaunch)),
    ] {
        state::set(&mut record, key, value);
    }
    for (key, value) in [
        ("session_id", &r.session_id),
        ("pane_key", &r.pane_key),
        ("cause", &r.cause),
        ("model", &r.model),
    ] {
        if let Some(value) = value {
            state::set(&mut record, key, value.clone());
        }
    }
    let standing = match doc.get(HANDOFF_KEY) {
        None | Some(Value::Null) => None,
        Some(_) => Some(state::object_mut(path, doc, HANDOFF_KEY)?),
    };
    let mut replaced = false;
    let mut resumed_at = None;
    if let Some(standing) = standing {
        // The content is the operation's identity: a field the standing
        // record lacks reads as null, as the request's absent field does.
        let differing: Vec<String> = record
            .iter()
            .filter(|(key, value)| standing.get(*key).unwrap_or(&Value::Null) != *value)
            .map(|(key, _)| key.clone())
            .collect();
        if differing.is_empty() {
            let recorded = standing
                .get("written_at")
                .and_then(Value::as_str)
                .map(str::to_owned);
            return Ok(HandoffRecorded {
                round_id: r.round_id.clone(),
                written_at: recorded.unwrap_or(written_at),
                replaced: false,
                recorded_now: false,
            });
        }
        if !r.supersede {
            return Err(Error::HandoffDiffers {
                path: path.to_path_buf(),
                fields: differing,
            });
        }
        replaced = true;
        // A consumed handoff stays consumed: the stamp the resume wrote
        // outlives the content it was written on.
        resumed_at = standing.get("resumed_at").filter(|v| !v.is_null()).cloned();
    }
    state::set(&mut record, "written_at", written_at.clone());
    if let Some(resumed_at) = resumed_at {
        state::set(&mut record, "resumed_at", resumed_at);
    }
    state::set(doc, HANDOFF_KEY, record);
    Ok(HandoffRecorded {
        round_id: r.round_id.clone(),
        written_at,
        replaced,
        recorded_now: true,
    })
}

pub(super) fn resume_handoff(
    path: &Path,
    doc: &mut Document,
    _r: &ResumeHandoff,
    env: &Env,
) -> Result<HandoffResumed> {
    let record: HandoffRecord =
        state::field(path, doc, HANDOFF_KEY)?.ok_or_else(|| Error::HandoffNone {
            path: path.to_path_buf(),
        })?;
    // The runs the continuation reads: the round's validation stages whose
    // result it has not consumed, each with its outcome, so a run the job
    // closed while the lane was away is reused by its outcome rather than
    // re-run or refused. The round is open at a resume (the handoff was
    // recorded before any accept), so every one of its non-superseded
    // validation stages is unconsumed, open or closed; no cut at the
    // handoff's `written_at` is made, since the job's close can land on
    // either side of it, seconds later and under load.
    // Newest first, by `(start, index)`: a recovery round
    // hands its failed run beside the later pass, and the continuation reads
    // the first.
    let mut runs: Vec<(u64, usize, OpenRun)> = stages(path, doc)?
        .into_iter()
        .enumerate()
        .filter(|(_, s)| {
            s.kind == StageKind::Validate
                && s.round_id == record.round_id
                && s.superseded != Some(true)
        })
        .filter_map(|(index, s)| {
            let run_dir = s.run_dir?;
            Some((
                s.start,
                index,
                OpenRun {
                    run_dir,
                    outcome: s.outcome,
                },
            ))
        })
        .collect();
    runs.sort_by_key(|(start, index, _)| std::cmp::Reverse((*start, *index)));
    let open_runs = runs.into_iter().map(|(_, _, run)| run).collect();
    let (resumed_at, resumed_now) = match record.resumed_at {
        Some(stamped) => (stamped, false),
        None => {
            let handoff = state::object_mut(path, doc, HANDOFF_KEY)?;
            state::set(handoff, "resumed_at", env.now_secs);
            (env.now_secs, true)
        }
    };
    Ok(HandoffResumed {
        round_id: record.round_id,
        relaunch: record.relaunch,
        remaining: record.remaining,
        open_runs,
        resumed_at,
        resumed_now,
    })
}
