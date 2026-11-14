//! The validation run's stage transitions: the proof facts and the job's
//! record written on the admitted stage before the launch, the launcher's
//! answer written after it, the one close with the lane's end notice
//! recorded `owed` in the same write, the mark that says how the send went,
//! and the stop recorded on an open stage before its job is ended. Every
//! step is one in-process request, `Request::Validate`, so the envelope's
//! exhaustive matches take one arm. The reads that precede the
//! start (the settings, the tree, the launcher) are `crate::validate`'s;
//! nothing here runs a process.
//!
//! The reuse judge over the stages, [`reuse`], is the start's own reading of
//! the proof rows already on the item: the proof reader's `round` need
//! (`ops::proof`) for the pass, and the bound-ended run beside it.
use agent_runtime::intent::Notice;
use agent_runtime::record::{self, Document};
use std::fs;
use std::io::ErrorKind;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::json;

use super::item::{self, AcceptResult, Attempt, RecordValidationAdmission};
use super::proof;
use crate::error::{Error, Result};
use crate::state::{
    ItemState, Proof, Record, Stage, StageKind, StageOutcome, Stop, ValidateJob, ValidateMode,
};
use agent_runtime::effects::job::Launch;
use agent_runtime::journal::Env;

/// The validation run's steps, tagged by `step`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case")]
pub enum Validate {
    Start(Box<RecordStart>),
    Launch(RecordLaunch),
    End(RecordEnd),
    Mark(MarkNotice),
    Stop(RecordStop),
}

impl Validate {
    /// The step's word, for the request's name.
    pub fn step(&self) -> &'static str {
        match self {
            Validate::Start(_) => "start",
            Validate::Launch(_) => "launch",
            Validate::End(_) => "end",
            Validate::Mark(_) => "mark",
            Validate::Stop(_) => "stop",
        }
    }
}

/// Write the proof facts and the launcher's record path on the round's
/// admitted run before the launcher is asked. With `run_dir` the stage the
/// dev agent's admission named, open and not yet started; without it the
/// round's open admitted run, or one minted here through the admission.
/// A round with an open run that carries a job refuses `run-live`: one run
/// at a time per round.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordStart {
    pub round_id: String,
    #[serde(default)]
    pub run_dir: Option<String>,
    pub proof: Proof,
}

/// The launcher's record beside the run, `<run_dir>/runner`: the job's
/// identity-to-be, on the stage from before the launch, and the record the
/// executor reads its runner from.
pub fn job_record(run_dir: &str) -> String {
    format!("{run_dir}/runner")
}

/// Write what the launcher answered: the job's identity, or the refusal,
/// which closes the stage `stopped` with its cause, never leaving it open
/// over nothing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordLaunch {
    pub round_id: String,
    pub run_dir: String,
    pub launch: Launch,
}

/// The one close of a started run: `accept-result` on the stage with the
/// sentinel's word, and the lane's end notice recorded `owed` in the same
/// write, so a crash between the close and the send leaves the notice for
/// the next reconcile. `end` is the sentinel's own time where it parses,
/// bounded to `[start, now]` as the reconcile bounds it (a time outside
/// them yields to the close's); `seconds` the run's wall time from its
/// `timing` record, reported, never written. `selection` is the command's
/// own `validate:` line where the log carries one. A run
/// that ran nothing closes with no notice: its caller holds the verdict. A
/// stage already closed changes nothing and reports its recorded close and
/// notice.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordEnd {
    pub round_id: String,
    pub run_dir: String,
    pub outcome: StageOutcome,
    #[serde(default)]
    pub end: Option<u64>,
    #[serde(default)]
    pub seconds: Option<u64>,
    #[serde(default)]
    pub selection: Option<String>,
    #[serde(default)]
    pub notice: Option<NoticeText>,
}

/// Record an intentional stop on the round's open started run, before its
/// job is ended: `stop {at}` on the stage, which the
/// job's own close and the reconcile both read for a job gone with no
/// sentinel. A closed stage refuses `run-closed`; a stage with no runtime
/// job, or one the start ran nothing for, refuses `run-unstarted`. A stop
/// already recorded stands and is reported.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecordStop {
    pub round_id: String,
    pub run_dir: String,
}

/// The notice's key and text; `to` and `owner` are the transition's.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NoticeText {
    pub key: String,
    pub text: String,
}

/// The end notice a run's close owes its lane: the key the
/// send is judged by (`validate-<run_id>`, the mailbox's delivery id, so a
/// replay after a lost mark lands once and reads `duplicate` = delivered) and
/// a text naming the run and its outcome. Both the job's own close and the
/// reconcile that closes a gone job's stage build it, so a replay from either
/// is the same line. A failure the run's memory cap caused carries that
/// cause from the run's sentinel. `run_id` is the run directory's basename
/// without the `dev-validate-` prefix.
pub fn end_notice(run_id: &str, run_dir: &str, outcome: StageOutcome) -> NoticeText {
    let cause = match outcome {
        StageOutcome::Fail => run_sentinel(run_dir)
            .as_deref()
            .and_then(memory_cap_cause)
            .map(|cause| format!(" {cause}"))
            .unwrap_or_default(),
        StageOutcome::Pass
        | StageOutcome::NoVerdict
        | StageOutcome::Lost
        | StageOutcome::Stopped
        | StageOutcome::NoChange
        | StageOutcome::HandedOver
        | StageOutcome::PassExcused => String::new(),
    };
    NoticeText {
        key: format!("validate-{run_id}"),
        text: format!(
            "validation-end run={run_id} state={}{cause} run-dir={run_dir} log={run_dir}/log",
            outcome.word()
        ),
    }
}

/// Mark the stage's owed notice with how its send went: `sent`, or
/// `unsent:<cause>`. A notice already marked keeps its mark.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MarkNotice {
    pub round_id: String,
    pub run_dir: String,
    pub owner: String,
}

/// What each step reports, tagged like its request.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case")]
pub enum Validated {
    Start(Started),
    Launch(Launched),
    End(Ended),
    Mark(Marked),
    Stop(Stopped),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Started {
    pub round_id: String,
    pub run_id: String,
    pub run_dir: String,
    pub start: u64,
    /// True when this call admitted the run, false when the admission
    /// stood.
    pub admitted_now: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Launched {
    pub round_id: String,
    pub run_dir: String,
    /// `stopped` where the launcher refused and the stage closed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<StageOutcome>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ended {
    pub round_id: String,
    pub run_dir: String,
    pub outcome: Option<StageOutcome>,
    pub end: u64,
    pub closed_now: bool,
    /// The run's wall time from its `timing` record, as the request
    /// carried it; absent where the run left none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seconds: Option<u64>,
    /// The notice's owner word on the stage: `owed` after this close, or
    /// the mark an earlier close's send earned; none where no notice is
    /// owed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice_owner: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Marked {
    pub round_id: String,
    pub run_dir: String,
    pub owner: String,
    pub marked_now: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stopped {
    pub round_id: String,
    pub run_dir: String,
    /// The stop as the stage records it: this call's, or the earlier one.
    pub stop: Stop,
    pub recorded_now: bool,
}

/// The item's stages, read once per transition.
fn stages(path: &Path, doc: &Document) -> Result<Vec<Stage>> {
    Ok(ItemState::view(path, doc)?.stages)
}

/// The index of the validate stage of `round_id` under `run_dir`.
fn stage_index(stages: &[Stage], round_id: &str, run_dir: &str) -> Result<usize> {
    stages
        .iter()
        .position(|s| {
            s.kind == StageKind::Validate
                && s.round_id.as_deref() == Some(round_id)
                && s.run_dir.as_deref() == Some(run_dir)
        })
        .ok_or_else(|| Error::RunUnknown {
            round_id: round_id.to_owned(),
            run_dir: run_dir.to_owned(),
        })
}

/// The item the record under `path` names: the stem of the state file
/// after `workflow-state-`.
fn item_of(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .and_then(|s| s.strip_prefix("workflow-state-"))
        .unwrap_or_default()
        .to_owned()
}

pub(super) fn apply(path: &Path, doc: &mut Document, r: &Validate, env: &Env) -> Result<Validated> {
    match r {
        Validate::Start(r) => start(path, doc, r, env).map(Validated::Start),
        Validate::Launch(r) => launch(path, doc, r, env).map(Validated::Launch),
        Validate::End(r) => end(path, doc, r, env).map(Validated::End),
        Validate::Mark(r) => mark(path, doc, r).map(Validated::Mark),
        Validate::Stop(r) => stop(path, doc, r, env).map(Validated::Stop),
    }
}

fn start(path: &Path, doc: &mut Document, r: &RecordStart, env: &Env) -> Result<Started> {
    let before = stages(path, doc)?;
    // One run at a time per round: an open run with its job recorded is
    // the round's, whether it still runs or its reconcile is still owed.
    if let Some(open) = before.iter().find(|s| {
        s.kind == StageKind::Validate
            && s.round_id.as_deref() == Some(&r.round_id)
            && s.end.is_none()
            && s.job.is_some()
    }) {
        return Err(Error::RunLive {
            round_id: r.round_id.clone(),
            run_dir: open.run_dir.clone().unwrap_or_default(),
        });
    }
    if let Some(run_dir) = &r.run_dir {
        // The named run is the dev agent's admission: it stands open, or
        // the start is of a run that already ended.
        let index = stage_index(&before, &r.round_id, run_dir)?;
        if before[index].end.is_some() {
            return Err(Error::RunUnknown {
                round_id: r.round_id.clone(),
                run_dir: run_dir.clone(),
            });
        }
    }
    let admitted = item::record_validation_admission(
        path,
        doc,
        &RecordValidationAdmission {
            round_id: r.round_id.clone(),
            run_dir: r.run_dir.clone(),
            attempt: Attempt::Current,
        },
        env,
    )?;
    let after = stages(path, doc)?;
    let index = stage_index(&after, &r.round_id, &admitted.run_dir)?;
    let rows = record::array_mut(path, doc, "stages")?;
    let row = record::element_mut(path, rows, index, "stages")?;
    record::set(row, "proof", serde_json::to_value(&r.proof)?);
    record::set(
        row,
        "job",
        serde_json::to_value(ValidateJob {
            record: job_record(&admitted.run_dir),
            runner: None,
            unit: None,
            pid: None,
            start: None,
            line: None,
            cause: None,
        })?,
    );
    Ok(Started {
        round_id: r.round_id.clone(),
        run_id: admitted.run_id,
        run_dir: admitted.run_dir,
        start: admitted.start,
        admitted_now: admitted.admitted_now,
    })
}

fn launch(path: &Path, doc: &mut Document, r: &RecordLaunch, env: &Env) -> Result<Launched> {
    let stages = stages(path, doc)?;
    let index = stage_index(&stages, &r.round_id, &r.run_dir)?;
    let stage = &stages[index];
    let Some(job) = &stage.job else {
        return Err(Error::RunUnstarted {
            run_dir: r.run_dir.clone(),
        });
    };
    let mut job = job.clone();
    let outcome = match &r.launch {
        Launch::Started {
            runner,
            unit,
            pid,
            start,
            line,
        } => {
            job.runner = Some(runner.clone());
            job.unit = unit.clone();
            job.pid = *pid;
            job.start = start.clone();
            job.line = Some(line.clone());
            None
        }
        Launch::Refused { cause } => {
            job.runner = Some("none".to_owned());
            job.cause = Some(cause.clone());
            Some(StageOutcome::Stopped)
        }
        Launch::Unanswered { cause } => {
            job.cause = Some(cause.clone());
            None
        }
    };
    if let Some(outcome) = outcome {
        item::close_stage(path, doc, index, stage, env.now_secs, outcome, env)?;
    }
    let rows = record::array_mut(path, doc, "stages")?;
    let row = record::element_mut(path, rows, index, "stages")?;
    record::set(row, "job", serde_json::to_value(job)?);
    Ok(Launched {
        round_id: r.round_id.clone(),
        run_dir: r.run_dir.clone(),
        outcome,
    })
}

fn end(path: &Path, doc: &mut Document, r: &RecordEnd, env: &Env) -> Result<Ended> {
    let stages = stages(path, doc)?;
    let index = stage_index(&stages, &r.round_id, &r.run_dir)?;
    let stage = &stages[index];
    if stage.job.is_none() {
        return Err(Error::RunUnstarted {
            run_dir: r.run_dir.clone(),
        });
    }
    // The one close: the stage's end and word through `accept-result`, at
    // the sentinel's time where it lies in the stage's bounds (a time
    // outside them, a clock the runner and this host disagree on, yields
    // to the close's own, as the reconcile's close does).
    let accepted = item::accept_result_at(
        path,
        doc,
        &AcceptResult {
            round_id: r.round_id.clone(),
            run_dir: Some(r.run_dir.clone()),
            outcome: r.outcome,
            end: None,
            authorization: None,
            summary_file: None,
            attachments: Vec::new(),
            summary_comment: None,
        },
        r.end.filter(|t| (stage.start..=env.now_secs).contains(t)),
        env,
    )?;
    if !accepted.closed_now {
        return Ok(Ended {
            round_id: r.round_id.clone(),
            run_dir: r.run_dir.clone(),
            outcome: accepted.outcome,
            end: accepted.end,
            closed_now: false,
            seconds: None,
            notice_owner: stage.notice.as_ref().map(|n| n.owner.clone()),
        });
    }
    let notice = r.notice.as_ref().map(|n| Notice {
        key: n.key.clone(),
        text: n.text.clone(),
        to: Some(item_of(path)),
        owner: agent_runtime::intent::NOTICE_OWED.to_owned(),
    });
    let rows = record::array_mut(path, doc, "stages")?;
    let row = record::element_mut(path, rows, index, "stages")?;
    if let Some(notice) = &notice {
        record::set(row, "notice", serde_json::to_value(notice)?);
    }
    if let Some(selection) = &r.selection
        && let Some(proof) = row.get_mut("proof").and_then(|p| p.as_object_mut())
    {
        proof.insert("selection".to_owned(), json!(selection));
    }
    Ok(Ended {
        round_id: r.round_id.clone(),
        run_dir: r.run_dir.clone(),
        outcome: accepted.outcome,
        end: accepted.end,
        closed_now: true,
        seconds: r.seconds,
        notice_owner: notice.map(|n| n.owner),
    })
}

fn stop(path: &Path, doc: &mut Document, r: &RecordStop, env: &Env) -> Result<Stopped> {
    let stages = stages(path, doc)?;
    let index = stage_index(&stages, &r.round_id, &r.run_dir)?;
    let stage = &stages[index];
    if stage.end.is_some() {
        return Err(Error::RunClosed {
            run_dir: r.run_dir.clone(),
        });
    }
    if stage
        .job
        .as_ref()
        .is_none_or(|j| j.runner.as_deref() == Some("none"))
    {
        return Err(Error::RunUnstarted {
            run_dir: r.run_dir.clone(),
        });
    }
    if let Some(stop) = &stage.stop {
        return Ok(Stopped {
            round_id: r.round_id.clone(),
            run_dir: r.run_dir.clone(),
            stop: stop.clone(),
            recorded_now: false,
        });
    }
    let stop = Stop { at: env.now_secs };
    let rows = record::array_mut(path, doc, "stages")?;
    let row = record::element_mut(path, rows, index, "stages")?;
    record::set(row, "stop", serde_json::to_value(&stop)?);
    Ok(Stopped {
        round_id: r.round_id.clone(),
        run_dir: r.run_dir.clone(),
        stop,
        recorded_now: true,
    })
}

/// The cause a sentinel line ends with where the kernel killed a member of
/// the run's tree at the run's own memory cap: `cause=memory-cap
/// limit=<bytes> peak=<bytes>`.
pub fn memory_cap_cause(line: &str) -> Option<&str> {
    line.find(" cause=memory-cap ").map(|at| &line[at + 1..])
}

/// The word a sentinel line names: the memory cap's cause is a failure
/// whatever the leader's exit, since the leader of a tree can exit 0 after
/// the kill took one of its members; `verdict=no-verdict` is no verdict,
/// `guard-exit=0` a pass, any other exit a failure. `None` for a line that
/// is no sentinel.
pub fn sentinel_outcome(line: &str) -> Option<StageOutcome> {
    let exit = line.strip_prefix("guard-exit=")?;
    let exit = exit.split(' ').next()?;
    exit.parse::<u32>().ok()?;
    Some(if memory_cap_cause(line).is_some() {
        StageOutcome::Fail
    } else if line.contains(" verdict=no-verdict") {
        StageOutcome::NoVerdict
    } else if exit == "0" {
        StageOutcome::Pass
    } else {
        StageOutcome::Fail
    })
}

fn mark(path: &Path, doc: &mut Document, r: &MarkNotice) -> Result<Marked> {
    let stages = stages(path, doc)?;
    let index = stage_index(&stages, &r.round_id, &r.run_dir)?;
    let Some(notice) = &stages[index].notice else {
        return Err(Error::RunUnstarted {
            run_dir: r.run_dir.clone(),
        });
    };
    if !notice.owed() {
        return Ok(Marked {
            round_id: r.round_id.clone(),
            run_dir: r.run_dir.clone(),
            owner: notice.owner.clone(),
            marked_now: false,
        });
    }
    let marked = Notice {
        owner: r.owner.clone(),
        ..notice.clone()
    };
    let rows = record::array_mut(path, doc, "stages")?;
    let row = record::element_mut(path, rows, index, "stages")?;
    record::set(row, "notice", serde_json::to_value(&marked)?);
    Ok(Marked {
        round_id: r.round_id.clone(),
        run_dir: r.run_dir.clone(),
        owner: marked.owner,
        marked_now: true,
    })
}

// --- The reuse judge over the stages ---------------------------------------------

/// What a run about to start would run: the key [`reuse`] judges the item's
/// earlier rows against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Want {
    pub cmd: String,
    pub class: String,
    pub docs_only: bool,
    pub base: String,
    pub finding_prefix: String,
    pub tree: String,
    /// The changed paths this run reads, one per entry.
    pub paths: Vec<String>,
    pub timeout_secs: u64,
}

/// An earlier row that answers the run: a pass over the same tree, or a
/// run the bound ended over no fewer paths, with the exit its sentinel
/// carried. The pass wins where both stand.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reuse {
    Pass { run_dir: String },
    Bound { run_dir: String, exit: u32 },
    None,
}

/// A stable digest of the changed paths, one per line, in the order the
/// reader wrote them: FNV-1a over the joined text, as hex. The key names
/// the selection; the paths themselves stay in the run directory's `paths`
/// for the coverage read.
pub fn paths_hash(paths: &[String]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in paths.join("\n").bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// The lines of a run directory's `paths` file; `None` where it cannot be
/// read, which is never coverage.
fn run_paths(run_dir: &str) -> Option<Vec<String>> {
    let text = fs::read_to_string(Path::new(run_dir).join("paths")).ok()?;
    Some(text.lines().map(str::to_owned).collect())
}

/// The sentinel line of a run directory, `None` where it is absent or
/// unreadable.
fn run_sentinel(run_dir: &str) -> Option<String> {
    match fs::read_to_string(Path::new(run_dir).join("exit")) {
        Ok(text) => Some(text.trim_end().to_owned()),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(_) => None,
    }
}

/// Whether the run's log holds a finding line, the rule `run_has_finding`
/// holds: a line past the runner line starting with the prefix its proof
/// records. A run recording no prefix, or whose log cannot be read, holds
/// one.
fn has_finding(run_dir: &str, prefix: &str) -> bool {
    if prefix.is_empty() {
        return true;
    }
    let Ok(log) = fs::read_to_string(Path::new(run_dir).join("log")) else {
        return true;
    };
    log.lines().skip(1).any(|line| line.starts_with(prefix))
}

/// Every entry of `inner` is among `outer`.
fn covered(inner: &[String], outer: &[String]) -> bool {
    inner.iter().all(|p| outer.contains(p))
}

/// The rows that answer `want` among the item's stages. The pass is the
/// proof reader's `round` need over `want.tree` and
/// `want.base` under `declaration`: a row of an admitted mode running that
/// mode's declared command, covering the tree whole or from the start's
/// own base, not voided by a later or same-second row at that tree that
/// did not pass; the start's own need chains through no other base. Else
/// the newest run the bound ended with no finding over no fewer paths
/// under no smaller bound, the rule `find_bound_run` holds: the same
/// command text, class, docs verdict, base and finding prefix. A `ci` row
/// is never evidence.
pub fn reuse(stages: &[Stage], want: &Want, declaration: &proof::Declaration) -> Reuse {
    let read = proof::read(
        stages,
        &[],
        &proof::ReadProof {
            need: proof::Need::Round,
            tree: want.tree.clone(),
            head: None,
            base: (!want.base.is_empty()).then(|| want.base.clone()),
            round: None,
            exception: None,
        },
        declaration,
        &mut |_| None,
    );
    if read.proof == proof::Verdict::Complete
        && let Some(row) = read.rows.into_iter().next()
    {
        return Reuse::Pass {
            run_dir: row.run_dir,
        };
    }
    let mut bound: Option<(String, u32, u64)> = None;
    for stage in stages {
        let (Some(proof), Some(run_dir), Some(outcome)) =
            (&stage.proof, &stage.run_dir, stage.outcome)
        else {
            continue;
        };
        if stage.kind != StageKind::Validate
            || stage.end.is_none()
            || proof.mode == ValidateMode::Ci
            || proof.reused.is_some()
            || proof.cmd != want.cmd
            || proof.class != want.class
            || proof.docs_only != want.docs_only
            || proof.base != want.base
            || proof.finding_prefix != want.finding_prefix
        {
            continue;
        }
        if outcome != StageOutcome::NoVerdict || proof.timeout_secs < want.timeout_secs {
            continue;
        }
        // A host no-verdict (exit 3) is no bound: the sentinel's match
        // admits `verdict=no-verdict` alone.
        let Some(exit) = run_sentinel(run_dir).and_then(|line| {
            let rest = line.strip_prefix("guard-exit=")?;
            let (exit, tail) = rest.split_once(' ')?;
            tail.ends_with(" verdict=no-verdict")
                .then(|| exit.parse::<u32>().ok())
                .flatten()
        }) else {
            continue;
        };
        let Some(earlier) = run_paths(run_dir).filter(|p| !p.is_empty()) else {
            continue;
        };
        if !covered(&earlier, &want.paths) || has_finding(run_dir, &proof.finding_prefix) {
            continue;
        }
        if bound.as_ref().is_none_or(|(_, _, s)| stage.start > *s) {
            bound = Some((run_dir.clone(), exit, stage.start));
        }
    }
    match bound {
        Some((run_dir, exit, _)) => Reuse::Bound { run_dir, exit },
        None => Reuse::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_paths_digest_is_stable_and_order_sensitive() {
        let a = paths_hash(&["a".into(), "b".into()]);
        assert_eq!(a, paths_hash(&["a".into(), "b".into()]));
        assert_ne!(a, paths_hash(&["b".into(), "a".into()]));
        assert_eq!(paths_hash(&[]), "cbf29ce484222325");
    }
}
