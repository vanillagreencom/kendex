//! The item transitions: rounds minted and superseded, a validation run
//! admitted for a round before any work starts, a stage closed with its
//! outcome, a round's admitted runs reconciled against the host, the
//! verification verdict of a published head (recorded, or read from GitHub
//! and then recorded by the `verify` module), and the handoff record a
//! session leaves for the one that continues its round.
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use agent_runtime::clock;
use agent_runtime::process;
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::Env;
use crate::error::{Error, Result};
use crate::state::{self, Document, ItemState, Record, Stage, StageKind, StageOutcome};

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
}

/// Record that a validation run was admitted for a round before any work
/// starts, so a run with no process yet is not read as no run.
///
/// Without `run_dir` the runtime mints the run's identity: `run_id` is
/// `<UTC stamp>-<nonce>` and `run_dir` is `<worktree>/tmp/dev-validate-
/// <run_id>` under the item's recorded worktree, the directory
/// `dev-validate-run --run-id <run_id>` then creates. The request is
/// idempotent per round: while an admitted run of the round stands open, a
/// repeat returns that run and writes nothing, whatever clock or nonce the
/// call carries, so a replayed delegation command continues the attempt it
/// admitted instead of minting a second identity. A further attempt is
/// minted only when the request says `attempt: next`, the rerun the dev
/// gate permits after a run that ended without a pass, or when no open
/// admission of the round stands. With `run_dir` the caller's runner
/// minted the identity first, the legacy order, `run_id` is read from the
/// directory's name, and the same directory admitted again is a no-op. An
/// empty `run_dir` is read as absent.
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
}

/// Where a stage's end is read from: the file whose modification time the
/// acceptance rests on, stat'ed by the runtime at the close.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EndSource {
    pub from_artifact: PathBuf,
}

/// Reconcile a round's admitted validation runs against the host, so no
/// admitted run stays open after it ended (decision 102). Every open
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
    /// The reader, such as `ci-wait --required-only`.
    pub source: String,
}

/// Verify a published head where it stands and record the verdict
/// (decision 93). `verify::run` reads GitHub for `head`, a full 40-hex
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
    #[serde(default)]
    pub written_at: Option<String>,
}

/// Stamp the standing handoff record resumed and report the round it
/// continues. A record stands while its `resumed_at` is unset; a second
/// resume changes nothing and reports the first stamp.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResumeHandoff {}

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
    /// The word on the stage; absent on a stage a legacy writer closed
    /// before this operation existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<StageOutcome>,
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
    /// The recorded child still runs; the stage stays open.
    Live { pid: u32 },
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
}

/// A handoff record stamped resumed: what the continuing session reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandoffResumed {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub round_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relaunch: Option<Relaunch>,
    pub remaining: Vec<String>,
    /// The run directories of the round's open validation stages: the runs
    /// the continuation waits on instead of starting new ones.
    pub open_runs: Vec<String>,
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

/// The directory name prefix every validation run directory carries.
const RUN_DIR_PREFIX: &str = "dev-validate-";

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
    let end = match &r.end {
        Some(source) => artifact_mtime(&source.from_artifact)?,
        None => env.now_secs,
    };
    let closed = close_stage(path, doc, index, stage, end, r.outcome, env)?;
    Ok(ResultAccepted {
        round_id: r.round_id.clone(),
        kind: stage.kind,
        run_dir: stage.run_dir.clone(),
        start: stage.start,
        end: closed.end,
        outcome: closed.outcome,
        closed_now: closed.closed_now,
    })
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
struct Closed {
    end: u64,
    /// The word on the stage; absent on a stage a legacy writer closed
    /// before the word existed.
    outcome: Option<StageOutcome>,
    closed_now: bool,
}

/// The one close of a stage: `end` is held to `[start, now]` before anything
/// else, a stale request being a request error whatever the stage holds; an
/// open stage takes the end and the word, a closed one keeps its own and
/// reports them.
fn close_stage(
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
    /// No run will end: the word its absence closes with, and why.
    Gone {
        outcome: StageOutcome,
        cause: RunCause,
    },
    Unreadable(String),
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

/// The word a sentinel line names, the rule `lib/validation-verdict.sh`
/// holds: `verdict=no-verdict` is no verdict, `guard-exit=0` a pass, any
/// other exit a failure. `None` for a line that is no sentinel.
fn sentinel_outcome(line: &str) -> Option<StageOutcome> {
    let exit = line.strip_prefix("guard-exit=")?;
    let exit = exit.split(' ').next()?;
    exit.parse::<u32>().ok()?;
    Some(if line.contains(" verdict=no-verdict") {
        StageOutcome::NoVerdict
    } else if exit == "0" {
        StageOutcome::Pass
    } else {
        StageOutcome::Fail
    })
}

#[allow(
    clippy::disallowed_methods,
    reason = "a validation run's recorded pid is read beside the record for the stage's reconcile; it is never signalled here"
)]
fn read_run(run_dir: &Path) -> RunRead {
    // Three-valued (decision 124c): the directory is opened for listing, and
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
    let sentinel = match run_file(run_dir, "exit") {
        Ok(s) => s,
        Err(cause) => return RunRead::Unreadable(cause),
    };
    if let Some(line) = sentinel {
        let line = line.trim_end();
        let Some(outcome) = sentinel_outcome(line) else {
            return RunRead::Unreadable(format!("exit: no sentinel line in {line:?}"));
        };
        let at = line
            .split(' ')
            .find_map(|f| f.strip_prefix("at="))
            .and_then(clock::epoch_secs);
        let seconds = match run_file(run_dir, "timing") {
            Ok(timing) => timing
                .as_deref()
                .and_then(|t| record_field(t, "seconds"))
                .and_then(|s| s.parse().ok()),
            Err(cause) => return RunRead::Unreadable(cause),
        };
        return RunRead::Ended {
            outcome,
            at,
            seconds,
        };
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
    // The runner records the child's pid and no process start, so this is
    // a pid read, not an identity read: a reused pid keeps a dead run open
    // until the rebuilt runner records the identity; it never closes a live
    // one.
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
        let (outcome, end, cause, seconds) = match read_run(Path::new(&run_dir)) {
            RunRead::Live { pid } => {
                runs.push(RunReconciled {
                    run_dir,
                    state: RunState::Live { pid },
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
            RunRead::Gone { outcome, cause } => (outcome, env.now_secs, cause, None),
        };
        close_stage(path, doc, index, stage, end, outcome, env)?;
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

/// The key `.verification` is written under.
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

/// The key `.handoff` is written under.
const HANDOFF_KEY: &str = "handoff";

/// The legacy stamp rule for `written_at`: absent or empty is stamped from
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
    let open_runs = stages(path, doc)?
        .into_iter()
        .filter(|s| {
            s.kind == StageKind::Validate && s.end.is_none() && s.round_id == record.round_id
        })
        .filter_map(|s| s.run_dir)
        .collect();
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
