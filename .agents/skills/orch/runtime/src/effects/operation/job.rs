//! The detached job a controller retirement runs in (decisions 76, 109 (3)):
//! a succession and the explicit stop both end the controller, and the
//! process that asked for either answers from the controller's own pane as
//! often as not, so neither effect runs in the caller's process. The caller
//! writes the request beside the record, starts the job through the orch
//! package's job-unit launcher, waits until the job has claimed the intent's
//! owner lease and answers `<op>-started intent=<id>`; the job claims, runs
//! the effect, records the outcome and announces a failure once (decision
//! 109 (7)): the fleet-log row and the owner notice the legacy `die_status`
//! emitted, recorded on the intent so a later reconcile of the same outcome
//! emits nothing again. A job the launcher was asked for is an obligation
//! from that moment until it claims or is read ended (decision 111 (5)): the
//! handle writes it before the launcher is asked, reads the launcher's
//! record into it, and a launcher reply that failed, or a job that never
//! claimed within the bound, leaves the intent `unconfirmed` with the job
//! standing, never `failed` over a job that may still run. A job asked for
//! again extends the recorded set (decision 120 (5)), and the
//! outstanding-job predicate reads the recorded job obligations alone, never
//! the claim's `handed_from` (decision 120, C2).

use std::path::Path;
use std::time::Duration;

use agent_runtime::host;
use agent_runtime::process::{self, Identity};
use agent_runtime::protocol::Outcome;
use serde::Serialize;
use serde_json::{Value, json};

use super::obligations::{Discharge, JobEnd, JobHandle, SidecarRead};
use super::{Operation, Reading, Word};
use crate::effects::{POLL, Run, read_intent, transfer};
use crate::error::{Error, Result};
use crate::ops::{self, Applied, ClaimIntent, RecordProgress, Request};
use crate::state::{self, EffectOp, Intent, Notice, Obligation, Owner, Role, WatchJob};
use crate::watch::claim;

/// What the caller of a transfer or a stop gets back at once: the effect
/// runs in a detached job that took the intent's owner lease, so retiring
/// the controller's pane, the caller's own as often as not, ends nothing
/// that owns the operation.
#[derive(Debug, Clone, Serialize)]
pub struct JobStarted {
    /// `transfer-started` or `stop-started`, so a reply reads as one at a
    /// glance.
    pub started: &'static str,
    pub intent: String,
    /// job-unit's runner line: the unit the job runs as, or its process
    /// group's runner.
    pub job: String,
    /// The job's identity, the intent's owner from its claim on.
    pub owner: Owner,
    /// The identity that persisted the intent and handed it over.
    pub handed_from: Owner,
}

/// How long job-unit's own launch may take to answer.
const JOB_LAUNCH_TIMEOUT: Duration = Duration::from_secs(60);

/// How long the mailbox CLI is given to take an owner notice.
const NOTICE_TIMEOUT: Duration = Duration::from_secs(60);

/// How long the user manager is given to answer for a unit's state.
const UNIT_READ_TIMEOUT: Duration = Duration::from_secs(30);

/// The launcher's record of the fleet watch's start, beside the fleet state
/// (`lib/watch-pid.sh`'s `oversee-watch.runner`): written whole before the
/// start, read here as the job's sidecar.
const WATCH_RUNNER_FILE: &str = "oversee-watch.runner";
/// The watch's stderr file beside the fleet state, appended on every start
/// (`workflows/oversee.md` § 4).
const WATCH_ERR_FILE: &str = "oversee-watch.err";

/// What the start's watch step found (step6-map A7): the watch claimed, by
/// this run's launch or by an earlier start; the launcher refused before it
/// started anything; a job started that has not claimed within the bound,
/// standing in the set for the reconcile; or a claim the runtime could not
/// read, never acted on.
pub(in crate::effects) enum WatchStart {
    Claimed(WatchJob),
    Refused { cause: String },
    Unclaimed { job: String },
    Unreadable { cause: String },
}

/// The notes a start held on its watch carries, each the key of the owner
/// notice the hold owes (decision 184 (6)).
const WATCH_LAUNCH_FAILED: &str = "watch-launch-failed";
const WATCH_UNCLAIMED: &str = "watch-unclaimed";
const WATCH_CLAIM_UNREADABLE: &str = "watch-claim-unreadable";

impl WatchStart {
    /// The watch the start publishes, or what holds it: the note the hold
    /// is recorded under and the observation it carries.
    pub(in crate::effects) fn held(self) -> std::result::Result<WatchJob, (&'static str, Value)> {
        match self {
            WatchStart::Claimed(job) => Ok(job),
            WatchStart::Refused { cause } => Err((WATCH_LAUNCH_FAILED, json!({"cause": cause}))),
            WatchStart::Unclaimed { job } => Err((WATCH_UNCLAIMED, json!({"job": job}))),
            WatchStart::Unreadable { cause } => {
                Err((WATCH_CLAIM_UNREADABLE, json!({"cause": cause})))
            }
        }
    }

    /// Whether `note` is one a start held on its watch carries.
    fn is_hold_note(note: &str) -> bool {
        [WATCH_LAUNCH_FAILED, WATCH_UNCLAIMED, WATCH_CLAIM_UNREADABLE].contains(&note)
    }
}

/// Which controller operation a job runs, and the words its start replies
/// and its job-unit name carry.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(in crate::effects) enum Op {
    Transfer,
    Stop,
}

impl Op {
    fn of_request(request: &Request) -> Option<Op> {
        match request {
            Request::RequestTransfer(_) => Some(Op::Transfer),
            Request::StopController(_) => Some(Op::Stop),
            Request::LaunchLane(_)
            | Request::CloseOwnedResources(_)
            | Request::StartController(_)
            | Request::AdoptSession(_)
            | Request::BeginRound(_)
            | Request::RecordValidationAdmission(_)
            | Request::AdoptController(_)
            | Request::ClaimIntent(_)
            | Request::AcceptResult(_)
            | Request::RecordVerification(_)
            | Request::VerifyHead(_)
            | Request::VerifyPr(_)
            | Request::ReconcileRound(_)
            | Request::RecordHandoff(_)
            | Request::ResumeHandoff(_)
            | Request::ParkLane(_)
            | Request::ReserveLane(_)
            | Request::ReleaseLane(_)
            | Request::RecordOutcome(_)
            | Request::RecordPhase(_)
            | Request::RecordProgress(_)
            | Request::RecordDirectiveSend(_)
            | Request::RecordWallPauses(_)
            | Request::AdmitPaths(_)
            | Request::PruneRecords(_)
            | Request::Validate(_) => None,
        }
    }

    pub(in crate::effects) fn of_intent(op: EffectOp) -> Option<Op> {
        match op {
            EffectOp::RequestTransfer => Some(Op::Transfer),
            EffectOp::StopController => Some(Op::Stop),
            EffectOp::LaunchLane | EffectOp::CloseOwnedResources | EffectOp::StartController => {
                None
            }
        }
    }

    fn started(self) -> &'static str {
        match self {
            Op::Transfer => "transfer-started",
            Op::Stop => "stop-started",
        }
    }

    /// The job-unit name, which names the unit where a manager runs one.
    fn job_name(self) -> &'static str {
        match self {
            Op::Transfer => "transfer",
            Op::Stop => "stop",
        }
    }

    fn word(self) -> &'static str {
        match self {
            Op::Transfer => "request-transfer",
            Op::Stop => "stop-controller",
        }
    }
}

/// Whether the job's request is the intent's first, or a repeat over a job
/// whose owner the reconcile read dead with the effect still to run: the
/// stale request file of the dead job is replaced, never refused as a
/// second launch.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(in crate::effects) enum Start {
    First,
    Repeat,
}

/// What the job launcher answered.
enum Asked {
    /// The launcher answered its runner line.
    Started(String),
    /// The launcher ran and refused, with its first stderr line.
    Refused(String),
    /// The launcher could not be run.
    Unrun(String),
}

/// Hand a just-persisted transfer or stop to a detached job: write the
/// request where the job reads it, start the job through the orch package's
/// job-unit launcher (a transient user unit where the manager lingers, a
/// `setsid` group elsewhere; it holds the caller's environment and
/// directory), and wait until the job has claimed the intent, so no window
/// stands in which a contender reads a dead owner. A launcher refused before
/// it was asked leaves the intent `failed` with its cause and the controller
/// as it was; one asked that did not answer, and a job that never claims
/// within the bound, leave it `unconfirmed` with the job standing, which the
/// reconcile reads (decision 111 (5)).
pub(in crate::effects) fn start(
    run: &Run,
    intent: &Intent,
    request: &Request,
    start: Start,
) -> Result<JobStarted> {
    let Some(op) = Op::of_request(request) else {
        unreachable!("only a transfer or a stop is handed to the job")
    };
    let handed_from = intent
        .owner
        .clone()
        .ok_or(Error::OwnerUnreadable { op: op.word() })?;
    // The launcher owns the intent until the job claims it: the handle
    // writes under that owner, so every write yields once the job's claim
    // moved it, a job that claimed keeps its own set (decision 124b), and
    // the handle stops at that write without acting (decision 124h (32));
    // the claimant's state is then the answer, `<op>-started`, as it is for
    // a claim the outcome write found.
    let operation = Operation::open(run, intent)?;
    match launch_job(run, operation, intent, request, op, &handed_from, start) {
        Err(Error::Yielded { owner, .. }) => Ok(JobStarted {
            started: op.started(),
            intent: intent.id.clone(),
            job: String::new(),
            owner,
            handed_from,
        }),
        answer => answer,
    }
}

/// Write the request, ask the launcher, read its record and wait for the
/// claim, under the launcher-side handle. A repeat's removal of the prior
/// job's files and its request rewrite follow the handle's owner-conditional
/// write (decision 124k (40)): the write proves, under the store lock, that
/// the intent is still this launcher's and its set the record's, and a
/// `Yielded` stops before either file is touched, so a job that claimed
/// meanwhile keeps its request and its record.
fn launch_job(
    run: &Run,
    mut operation: Operation,
    intent: &Intent,
    request: &Request,
    op: Op,
    handed_from: &Owner,
    start: Start,
) -> Result<JobStarted> {
    let id = intent.id.as_str();
    let request_path = state::job_request_path(&run.settings.state_dir, id);
    let record_path = state::job_record_path(&run.settings.state_dir, id);
    if start == Start::Repeat {
        operation.write()?;
        remove_files(&run.settings.state_dir, id);
    }
    if let Err(e) = write_request(&request_path, request) {
        return fail(
            run,
            operation,
            op,
            handed_from,
            "",
            "job-request-unwritable",
            e.to_string(),
        );
    }
    let job_unit = run.settings.job_unit.clone();
    if !job_unit.is_file() {
        return fail(
            run,
            operation,
            op,
            handed_from,
            "",
            "job-unit-missing",
            job_unit.display().to_string(),
        );
    }
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(e) => {
            return fail(
                run,
                operation,
                op,
                handed_from,
                "",
                "job-launch-failed",
                e.to_string(),
            );
        }
    };
    let exe = exe.display().to_string();
    let record = record_path.display().to_string();
    let state_dir = run.settings.state_dir.display().to_string();
    let file = run.path.display().to_string();
    let args = [
        "launch",
        op.job_name(),
        &record,
        "--",
        &exe,
        "--state-dir",
        &state_dir,
        "job",
        "--file",
        &file,
        "--intent",
        id,
    ];
    let line = match operation.ask_job(&record_path, &args)? {
        Asked::Started(line) => line,
        Asked::Refused(reply) => {
            operation.read_sidecar(&record_path, &reply)?;
            return fail(
                run,
                operation,
                op,
                handed_from,
                "",
                "job-launch-failed",
                reply,
            );
        }
        Asked::Unrun(cause) => {
            operation.read_sidecar(&record_path, "")?;
            return fail(
                run,
                operation,
                op,
                handed_from,
                "",
                "job-launch-failed",
                cause,
            );
        }
    };
    // The launcher answered that the job started and wrote its identity: it is
    // read into the set before the claim wait begins (decision 120 (1), C2),
    // so a contender and a reconcile find the job by its own identity, not the
    // unread sidecar, and the launcher-side handle writes nothing more once the
    // loop begins.
    operation.read_sidecar(&record_path, &line)?;
    // The job's first act is its claim (`claim-intent`); until then this
    // process holds the lease, so a contender defers to it (decision 72).
    let deadline = operation.now() + run.settings.claim;
    loop {
        let current = read_intent(run.path, id)?;
        if let Some(owner) = &current.owner
            && owner != handed_from
        {
            return Ok(JobStarted {
                started: op.started(),
                intent: id.to_owned(),
                job: line,
                owner: owner.clone(),
                handed_from: handed_from.clone(),
            });
        }
        if !current.open() || operation.now() >= deadline {
            // The job the launcher recorded stands, read before this wait,
            // until it claims or a reconcile reads it ended.
            return fail(
                run,
                operation,
                op,
                handed_from,
                &line,
                "job-unclaimed",
                line.clone(),
            );
        }
        operation.sleep(POLL);
    }
}

/// Record the operation's end before anything of it ran here, with `note`
/// and `cause`, and refuse the request with the matching kind. Where the
/// launcher's word settled the job (nothing started), `failed` with the
/// whole set discharged (a transfer's overwritten pending is restored);
/// otherwise the job the launcher was asked for stands: `unconfirmed`, the
/// request file kept for it, until it claims or the reconcile reads it
/// ended. The writes are the launcher's, made only while it still owns the
/// intent: where a job claimed meanwhile, nothing is written and the
/// claimant's state is the answer, `<op>-started` (decision 124c).
fn fail(
    run: &Run,
    operation: Operation,
    op: Op,
    handed_from: &Owner,
    line: &str,
    note: &'static str,
    cause: String,
) -> Result<JobStarted> {
    let intent = operation.intent_id().to_owned();
    let outcome = if operation.nothing_stands() {
        operation.settle(
            Word::Failed,
            json!({"retired": false, "note": note, "cause": cause}),
        )
    } else {
        operation.hold(json!({
            "retired": false,
            "note": note,
            "cause": cause,
            "job": "possibly-started",
        }))
    };
    let applied = super::apply_outcome(run, outcome)?;
    if let ops::Report::RecordOutcome(r) = &applied.report
        && let Some(owner) = &r.intent.owner
        && owner != handed_from
    {
        return Ok(JobStarted {
            started: op.started(),
            intent,
            job: line.to_owned(),
            owner: owner.clone(),
            handed_from: handed_from.clone(),
        });
    }
    Err(match note {
        "job-unclaimed" => Error::JobUnclaimed { intent },
        _ => Error::JobLaunchFailed { intent, cause },
    })
}

impl Operation<'_> {
    /// Ask the job launcher for the operation's job, its record at `record`:
    /// the launcher's unread record is an obligation from this moment
    /// (decisions 111 (5), 115 (B)), written with its address before the
    /// launcher is asked, so a contender that reads a dead owner finds the
    /// job the record names, at the address the ask named (decision 184
    /// (6)). A repeated ask extends the recorded set (decision 120 (5)).
    fn ask_job(&mut self, record: &Path, args: &[&str]) -> Result<Asked> {
        self.obligations.ask_job(record);
        self.write()?;
        let job_unit = self.run.settings.job_unit.clone();
        Ok(
            match host::run_tagged(
                "job",
                "job-unit",
                &job_unit,
                "launch",
                args,
                JOB_LAUNCH_TIMEOUT,
            ) {
                Ok(out) if out.status.success() => Asked::Started(host::stdout_text(&out)),
                Ok(out) => Asked::Refused(host::stderr_text(&out)),
                Err(e) => Asked::Unrun(e.to_string()),
            },
        )
    }

    /// Read the launcher's record into the set: the sidecar obligation is
    /// discharged by the record it names, and the handle it names becomes the
    /// job's obligation (decision 115 (B)). A reply that carries the launch's
    /// ended status (`status=<word>`, written by the launcher that unwound
    /// the child and its group; `load=` for a unit the manager holds
    /// unloaded) is read before the record, since a launcher whose store was
    /// unwritable says so on the reply alone (decision 124d (19)): the word
    /// settles the sidecar as nothing started, except `unwound-failed`, a
    /// group the launcher could not read empty, which holds the job as
    /// possibly started. Every other reply reads the record.
    fn read_sidecar(&mut self, record: &Path, reply: &str) -> Result<()> {
        let address = record.display().to_string();
        let line = reply.lines().next().unwrap_or_default();
        if let Some(read) = reply_status(line) {
            self.obligations.discharge(Discharge::Sidecar {
                record: address,
                read,
            });
            return self.write();
        }
        match read_handle(record) {
            SidecarRead::Present(handle) => {
                self.obligations.replace(
                    &Obligation::JobSidecar { record: address },
                    "sidecar-read",
                    handle.obligation(),
                    Role::Job,
                    None,
                );
            }
            // Absent, or the record's own `status=` line: the launch ended,
            // nothing started, so the sidecar settles. Unreadable holds it.
            read @ (SidecarRead::Absent
            | SidecarRead::Failed { .. }
            | SidecarRead::Unreadable { .. }) => {
                self.obligations.discharge(Discharge::Sidecar {
                    record: address,
                    read,
                });
            }
        }
        self.write()
    }

    /// Whether nothing stands in the recorded set.
    pub(super) fn nothing_stands(&self) -> bool {
        self.obligations.record().standing.is_empty()
    }

    /// The fleet watch a start owes (step6-map A7, decision 133): the claim
    /// beside the fleet state read first, and a live one, this run's or an
    /// earlier start's, is the watch; else a job of this intent still
    /// standing is read again and holds while it runs; else `words`, the
    /// entry and its arguments as the workflow's launch block names them,
    /// are launched detached through the job launcher, the launcher's
    /// unread record an obligation before it is asked (decision 111 (5)),
    /// its stderr appended beside the fleet state, and the claim is waited
    /// for within the job claim bound. A job that claimed is discharged by
    /// that read; one that has not stands for the reconcile, which runs
    /// this step again. An unreadable claim is never a reason to launch
    /// (decision 99).
    pub(in crate::effects) fn ensure_watch(&mut self, words: &[String]) -> Result<WatchStart> {
        let paths = claim::Paths::of(self.run.path)?;
        match self.watch_claimed(&paths)? {
            Reading::Live(job) => return Ok(WatchStart::Claimed(job)),
            Reading::Unreadable { cause } => {
                return Ok(WatchStart::Unreadable {
                    cause: cause.to_owned(),
                });
            }
            Reading::Gone => {}
        }
        if !self.obligations.jobs().is_empty() {
            self.read_standing_jobs()?;
            if let Some(job) = self.obligations.jobs().first() {
                return Ok(WatchStart::Unclaimed {
                    job: watch_job_of(job).runner,
                });
            }
        }
        let record = paths.dir.join(WATCH_RUNNER_FILE);
        let record_s = record.display().to_string();
        let err = paths.dir.join(WATCH_ERR_FILE).display().to_string();
        let name = format!("watch-{}", self.run.env.iso().replace(['-', ':'], ""));
        let mut args = vec![
            "launch",
            &name,
            &record_s,
            "--",
            "sh",
            "-c",
            "err=$1; shift; exec \"$@\" 2>>\"$err\"",
            "sh",
            &err,
        ];
        args.extend(words.iter().map(String::as_str));
        let line = match self.ask_job(&record, &args)? {
            Asked::Started(line) => line,
            Asked::Refused(reply) => {
                self.read_sidecar(&record, &reply)?;
                return Ok(WatchStart::Refused { cause: reply });
            }
            Asked::Unrun(cause) => {
                self.read_sidecar(&record, "")?;
                return Ok(WatchStart::Refused { cause });
            }
        };
        self.read_sidecar(&record, &line)?;
        let deadline = self.now() + self.run.settings.claim;
        loop {
            match self.watch_claimed(&paths)? {
                Reading::Live(job) => return Ok(WatchStart::Claimed(job)),
                Reading::Unreadable { cause } => {
                    return Ok(WatchStart::Unreadable {
                        cause: cause.to_owned(),
                    });
                }
                Reading::Gone => {}
            }
            if self.now() >= deadline {
                return Ok(WatchStart::Unclaimed { job: line });
            }
            self.sleep(POLL);
        }
    }

    /// The watch's claim beside the fleet state, read by the runtime's own
    /// reader: `Live` with the record `overseer.watch` takes where it names
    /// a live identity, every job obligation of this intent discharged
    /// `watch-claimed` by that read and the first of them naming the job;
    /// `Gone` where no record stands or its identity reads gone; the
    /// reader's own unreadable otherwise. A record whose file the runtime
    /// cannot read is unreadable too.
    fn watch_claimed(&mut self, paths: &claim::Paths) -> Result<Reading<WatchJob>> {
        let claimed = match claim::read(paths) {
            Ok(Some(claimed)) => claimed,
            Ok(None) => return Ok(Reading::Gone),
            Err(e) => return Ok(Reading::Unreadable { cause: e.key() }),
        };
        let identity = match claim::read_live(&claimed) {
            Reading::Live(identity) => identity,
            Reading::Gone => return Ok(Reading::Gone),
            Reading::Unreadable { cause } => return Ok(Reading::Unreadable { cause }),
        };
        let jobs = self.obligations.jobs();
        let job = jobs.first().map(watch_job_of).unwrap_or(WatchJob {
            runner: "claimed".to_owned(),
            unit: None,
            pid: Some(identity.pid),
            start: Some(identity.start.clone()),
        });
        for standing in jobs {
            let handle = match standing {
                Obligation::JobUnit { unit } => JobHandle::Unit { unit },
                Obligation::JobGroup(identity) => JobHandle::Group(identity),
                Obligation::JobPgid { pgid } => JobHandle::Pgid(pgid),
                // The launcher's record unread: nothing of the job is
                // named yet, so nothing of it is settled by the claim.
                Obligation::JobSidecar { .. }
                | Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::Validation
                | Obligation::Worktree { .. } => continue,
            };
            self.discharge(Discharge::Job {
                job: handle,
                end: JobEnd::Claimed,
            })?;
        }
        Ok(Reading::Live(job))
    }

    /// The outstanding-job predicate both the transfer and the stop
    /// reconciles apply before replacing a sidecar or starting another job
    /// (decision 115 (B)): the job obligations the intent recorded, each read
    /// for its end. A unit read not-found or ended, a group read gone
    /// (`job-exited`), and a sidecar whose record now names a handle or is
    /// gone update the set; a job that still runs stands. The predicate reads
    /// the recorded set alone (decision 120, C2): a job that claimed was
    /// discharged by its claim, so nothing of it stands.
    pub(in crate::effects) fn job_standing(&mut self, intent: &Intent) -> Result<bool> {
        if Op::of_intent(intent.op).is_none() {
            return Ok(false);
        }
        self.read_standing_jobs()?;
        // A job still stands where any job obligation remains undischarged.
        Ok(!self.obligations.jobs().is_empty())
    }

    /// Read every standing job obligation by its own key (decision 124a (2)):
    /// the unread sidecar at the address its ask recorded (decision 184
    /// (6)), a unit through the manager, a group through the one identity
    /// reader, each discharged where it reads ended.
    pub(super) fn read_standing_jobs(&mut self) -> Result<()> {
        for job in self.obligations.jobs() {
            match job {
                Obligation::JobSidecar { record } => self.read_sidecar(Path::new(&record), "")?,
                Obligation::JobUnit { unit } => {
                    if let Some(end) = unit_end(&unit) {
                        self.discharge(Discharge::Job {
                            job: JobHandle::Unit { unit },
                            end,
                        })?;
                    }
                }
                Obligation::JobGroup(identity) => {
                    if let Some(end) = group_end(&identity) {
                        self.discharge(Discharge::Job {
                            job: JobHandle::Group(identity),
                            end,
                        })?;
                    }
                }
                Obligation::JobPgid { pgid } => {
                    if let Some(end) = pgid_end(pgid) {
                        self.discharge(Discharge::Job {
                            job: JobHandle::Pgid(pgid),
                            end,
                        })?;
                    }
                }
                // `jobs()` returns only the job obligations above.
                Obligation::Process(_)
                | Obligation::Pid { .. }
                | Obligation::Pane { .. }
                | Obligation::PaneUnaddressed { .. }
                | Obligation::Window { .. }
                | Obligation::Receipt
                | Obligation::Validation
                | Obligation::Worktree { .. } => {}
            }
        }
        Ok(())
    }

    /// Whether the record says a job of this intent ended by its own read,
    /// for the observation's `job: ended`.
    pub(in crate::effects) fn job_ended(&self) -> bool {
        self.obligations.jobs().is_empty()
            && self
                .obligations
                .record()
                .discharged
                .iter()
                .any(|d| d.by == "job-exited" || d.by.starts_with("unit-"))
    }
}

/// The record `overseer.watch` takes of a standing job obligation: the
/// launcher's runner and unit, or the group's leader identity; a record
/// unread names nothing yet.
fn watch_job_of(job: &Obligation) -> WatchJob {
    match job {
        Obligation::JobUnit { unit } => WatchJob {
            runner: "systemd".to_owned(),
            unit: Some(unit.clone()),
            pid: None,
            start: None,
        },
        Obligation::JobGroup(identity) => WatchJob {
            runner: "setsid".to_owned(),
            unit: None,
            pid: Some(identity.pid),
            start: Some(identity.start.clone()),
        },
        Obligation::JobPgid { pgid } => WatchJob {
            runner: "setsid".to_owned(),
            unit: None,
            pid: Some(*pgid),
            start: None,
        },
        Obligation::JobSidecar { .. }
        | Obligation::Process(_)
        | Obligation::Pid { .. }
        | Obligation::Pane { .. }
        | Obligation::PaneUnaddressed { .. }
        | Obligation::Window { .. }
        | Obligation::Receipt
        | Obligation::Validation
        | Obligation::Worktree { .. } => WatchJob {
            runner: "unread".to_owned(),
            unit: None,
            pid: None,
            start: None,
        },
    }
}

/// The end of the job group `leader` leads, read by its pgid (decision 124g
/// (31)): the leader's identity through the one reader, and, once that
/// reads gone, the kernel's table for any live member naming the leader's
/// pid as its group, so a leader that exited leaving a descendant is a
/// group still running. `None` while the leader lives, while a member
/// lives, or where the leader or the table cannot be read.
fn group_end(leader: &Identity) -> Option<JobEnd> {
    match process::still_runs(leader) {
        Reading::Live(_) | Reading::Unreadable { .. } => return None,
        Reading::Gone => {}
    }
    pgid_end(leader.pid)
}

/// The end of the job group `pgid`, read by the group key alone (decision
/// 124h (33)): the kernel's table for any live member naming it as its
/// group. A pgid is not reallocated while its group has a member, so this
/// read can hold too long and never discharge a running group. `None`
/// while a member lives or where the table cannot be read, which the table
/// reader answers for an unreadable row too (decision 99). A zombie is no
/// member: the table reader leaves an exited process its parent has not
/// reaped out of every row, as the launcher's own group reader does
/// (decision 124l (47)), so a reaped-late member never holds the group.
fn pgid_end(pgid: u32) -> Option<JobEnd> {
    let rows = process::table().ok()?;
    let member = rows.iter().any(|row| row.pgrp == pgid);
    (!member).then_some(JobEnd::Exited)
}

/// The job the launcher's record names, in job-unit's own `runner=`,
/// `unit=`, `pid=`, `start=`, `line=` form (decision 115 (B)): a unit where a
/// manager runs it, else the process group the launcher read the child's
/// identity for before it returned. `Absent` where no record was written:
/// the launcher failed before it asked anything. `Unreadable` where a record
/// stands but names no identity yet, so the job is unread, never absent. A
/// record whose launch ended `unwound-failed` names the group the launcher
/// could not read empty, read on every reconcile from here: by the leader's
/// identity where the launcher read its start (decision 124g (31)), else by
/// the group key `pgid=` alone, which every post-fork path holds (decision
/// 124h (33)); no start is ever made up for it.
fn read_handle(record: &Path) -> SidecarRead {
    let text = match std::fs::read_to_string(record) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return SidecarRead::Absent,
        Err(e) => {
            return SidecarRead::Unreadable {
                cause: e.to_string(),
            };
        }
    };
    let field = |key: &str| {
        text.lines()
            .find_map(|line| {
                line.strip_prefix(key)
                    .and_then(|rest| rest.strip_prefix('='))
            })
            .map(str::to_owned)
    };
    // A launch-failed path after the record's pre-write rewrites it with a
    // `status=` word once the child and its group are unwound (decisions
    // 124b, 124d (19)): nothing started, so a later read settles the job
    // rather than holding it unread; `unwound-failed` says the group did not
    // read empty: with the leader's identity it names that group, read by
    // pgid from here, and without one the job stands as possibly started.
    if let Some(status) = field("status") {
        if status == "unwound-failed" {
            if let (Some(pid), Some(start)) = (field("pid"), field("start"))
                && let Ok(pid) = pid.parse::<u32>()
            {
                return SidecarRead::Present(JobHandle::Group(Identity { pid, start }));
            }
            if let Some(pgid) = field("pgid")
                && let Ok(pgid) = pgid.parse::<u32>()
            {
                return SidecarRead::Present(JobHandle::Pgid(pgid));
            }
        }
        return status_read(status);
    }
    let Some(runner) = field("runner") else {
        return SidecarRead::Unreadable {
            cause: "runner-unnamed".to_owned(),
        };
    };
    match (runner.as_str(), field("unit"), field("pid"), field("start")) {
        ("systemd", Some(unit), _, _) => SidecarRead::Present(JobHandle::Unit { unit }),
        (_, _, Some(pid), Some(start)) => match pid.parse::<u32>() {
            Ok(pid) => SidecarRead::Present(JobHandle::Group(Identity { pid, start })),
            Err(_) => SidecarRead::Unreadable {
                cause: "pid-unparsed".to_owned(),
            },
        },
        // A record that names no identity yet: the launcher has not written
        // the child's pid, so the job is unread rather than absent.
        (_, _, _, _) => SidecarRead::Unreadable {
            cause: "identity-unwritten".to_owned(),
        },
    }
}

/// What a launcher's `status=` word settles: `unwound-failed` with no group
/// key holds the job as possibly started, since the launcher could not read
/// its group empty and named nothing to read it by; every other word is a
/// launch that ended with nothing running.
fn status_read(status: String) -> SidecarRead {
    if status == "unwound-failed" {
        SidecarRead::Unreadable {
            cause: "unwound-failed".to_owned(),
        }
    } else {
        SidecarRead::Failed { status }
    }
}

/// The launch's end a launcher's reply line carries, where it carries one:
/// `job-unit: <key> ... status=<word>` from a launcher that unwound the child
/// (`launch-failed` or `record-unwritable`), or `load=` for a unit the
/// manager holds unloaded. `unwound-failed` carries no end: the record is
/// read, which names the group's leader where the launcher knew it.
fn reply_status(line: &str) -> Option<SidecarRead> {
    let fields = line.strip_prefix("job-unit: ")?;
    let mut words = fields.split_whitespace();
    let key = words.next()?;
    if !matches!(key, "launch-failed" | "record-unwritable") {
        return None;
    }
    for word in words {
        if let Some(status) = word.strip_prefix("status=") {
            if status == "unwound-failed" {
                return None;
            }
            return Some(status_read(status.to_owned()));
        }
        if word.starts_with("load=") {
            return Some(SidecarRead::Absent);
        }
    }
    None
}

/// The end of the unit `unit`, read through the user manager: `None` where
/// the manager did not answer or the unit still runs.
fn unit_end(unit: &str) -> Option<JobEnd> {
    let service = format!("{unit}.service");
    let out = host::run_tagged(
        "job",
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
    )
    .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = host::stdout_text(&out);
    let mut lines = text.lines();
    unit_state(
        lines.next().unwrap_or_default(),
        lines.next().unwrap_or_default(),
    )
}

/// What a unit's `LoadState` and `ActiveState` say of the job: the manager
/// has no record of it, it ended, or it still runs (`None`).
fn unit_state(load: &str, active: &str) -> Option<JobEnd> {
    match (load, active) {
        ("not-found", _) => Some(JobEnd::UnitGone),
        ("loaded", "inactive" | "failed") => Some(JobEnd::UnitEnded {
            state: active.to_owned(),
        }),
        (_, _) => None,
    }
}

/// Write the job's request exclusively: a standing file is another launch
/// of the same intent, which never happens twice, so it is refused rather
/// than replaced.
fn write_request(path: &Path, request: &Request) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    let bytes = serde_json::to_vec(request).map_err(std::io::Error::other)?;
    file.write_all(&bytes)?;
    file.sync_all()
}

/// Remove the job's request and record once its intent closed, or before a
/// repeat replaces them. Best effort, as the receipt's removal is: nothing
/// reads either past the outcome, and a repeat writes its own.
pub(super) fn remove_files(state_dir: &Path, intent_id: &str) {
    let _ = std::fs::remove_file(state::job_request_path(state_dir, intent_id));
    let _ = std::fs::remove_file(state::job_record_path(state_dir, intent_id));
}

/// The job's side (decision 76): claim the intent, run the effect from the
/// request the caller wrote, record the outcome. A claim that refuses (the
/// intent ended, or its effect began under its first owner) ends the job
/// before it opens anything.
pub(in crate::effects) fn run_job(run: &Run, intent_id: &str) -> Result<Applied> {
    let request_path = state::job_request_path(&run.settings.state_dir, intent_id);
    let bytes = std::fs::read(&request_path).map_err(|e| {
        Error::Runtime(agent_runtime::Error::io(
            "read-job-request",
            &request_path,
            e,
        ))
    })?;
    let request: Request = serde_json::from_slice(&bytes).map_err(|e| Error::Request {
        path: request_path.clone(),
        cause: e.to_string(),
    })?;
    let Some(op) = Op::of_request(&request) else {
        return Err(Error::Request {
            path: request_path,
            cause: format!("{} is not a job's operation", request.name()),
        });
    };
    ops::apply(
        run.path,
        &Request::ClaimIntent(ClaimIntent {
            intent_id: intent_id.to_owned(),
        }),
        run.env,
        run.locking,
    )?;
    let outcome = match (&request, op) {
        (Request::RequestTransfer(r), Op::Transfer) => {
            transfer::transfer_effect(run, intent_id, r)?
        }
        (_, Op::Stop) => transfer::stop_controller_effect(run, intent_id)?,
        (_, Op::Transfer) => unreachable!("a transfer job reads a transfer request"),
    };
    super::apply_outcome(run, outcome)
}

/// The announcement a failed or unconfirmed outcome of a job's operation
/// owes (decision 109 (7)), as the outcome's own write records it `owed`
/// (decision 124f (28)): the key is the observation's `note`, else its
/// `cause`, else the outcome word; the text is the legacy `die_status`
/// line. A start held on its watch owes the same (decision 184 (6)): its
/// runner stands at the composer and the fleet runs unwatched until a
/// reconcile claims the watch, which only the caller's reply said. A
/// confirmed outcome, a start held on anything else, and an intent of
/// another operation owe none.
pub(super) fn owed_notice(
    op: EffectOp,
    intent_id: &str,
    outcome: Outcome,
    observation: &Value,
) -> Option<Notice> {
    let word = |key: &str| {
        observation
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    match op {
        EffectOp::RequestTransfer | EffectOp::StopController => {}
        EffectOp::StartController => {
            if !word("note").is_some_and(|note| WatchStart::is_hold_note(&note)) {
                return None;
            }
        }
        EffectOp::LaunchLane | EffectOp::CloseOwnedResources => return None,
    }
    match outcome {
        Outcome::Failed | Outcome::Unconfirmed => {}
        Outcome::Confirmed | Outcome::NotStarted => return None,
    }
    let key = word("note").or_else(|| word("cause")).unwrap_or_else(|| {
        match outcome {
            Outcome::Failed => "failed",
            Outcome::Unconfirmed | Outcome::Confirmed | Outcome::NotStarted => "unconfirmed",
        }
        .to_owned()
    });
    let outcome_word = serde_json::to_value(outcome)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default();
    let mut text = format!(
        "orch-runtime: {key} op={} intent={intent_id} outcome={outcome_word}",
        op.word()
    );
    if let Some(cause) = word("cause").filter(|c| *c != key) {
        text.push_str(&format!(" cause={cause}"));
    }
    // No `to`: an intent's notice goes to the owner (U6a, step6-map F7).
    Some(Notice {
        key,
        text,
        to: None,
        owner: state::NOTICE_OWED.to_owned(),
    })
}

/// Send the notice `intent` records owed, where it records one, and mark
/// it with how the send went in a follow-up write under `while_owner`
/// (decision 124f (28)): the continuation of the outcome's write. A notice
/// already marked is nothing to do, so a second caller sends nothing.
pub(super) fn deliver_owed(run: &Run, intent: &Intent, while_owner: Option<Owner>) -> Result<()> {
    let Some(owed) = intent.notice.as_ref().filter(|n| n.owed()) else {
        return Ok(());
    };
    let mark = send_owner_notice(run, &intent.id, &owed.text);
    mark_notice(run, intent, owed, mark, while_owner)
}

/// Write how the send of `owed` went as the notice's mark, under
/// `while_owner`: the continuation of the intent's recorded outcome, taken
/// on the closed intent and judged by the store's content comparison like
/// every write (decisions 124i (36), 129).
fn mark_notice(
    run: &Run,
    intent: &Intent,
    owed: &Notice,
    mark: String,
    while_owner: Option<Owner>,
) -> Result<()> {
    ops::apply(
        run.path,
        &Request::RecordProgress(Box::new(RecordProgress {
            intent_id: intent.id.clone(),
            phase: None,
            obligations: None,
            while_owner,
            notice: Some(Notice {
                key: owed.key.clone(),
                text: owed.text.clone(),
                to: owed.to.clone(),
                owner: mark,
            }),
        })),
        run.env,
        run.locking,
    )?;
    Ok(())
}

/// An owed notice the walk sent whose mark the store refused or could not
/// write (decision 124i (36)): recorded in the request's reply, never a
/// reason to fail it. The notice stays `owed`, so the next walk sends it
/// again; the mailbox reads a repeat within its window as `sent`.
#[derive(Debug, Clone, Serialize)]
pub struct NoticeUnmarked {
    pub intent: String,
    /// The mark the send earned, `sent` or `unsent:<cause>`.
    pub mark: String,
    /// The key of the store's refusal.
    pub refusal: String,
}

/// Send every notice a closed intent still records owed: the continuation
/// a crash between the outcome's write and its send left behind, run by
/// every reconcile and every request (decision 124f (28)). An intent whose
/// recorded owner still runs, or cannot be read, is that owner's to finish
/// (decisions 72, 99); one whose owner is gone is sent once here and
/// marked, so the next walk finds nothing owed. A mark the store refused
/// is returned for the reply and stops neither the walk nor the request
/// that runs it (decision 124i (36)).
pub(in crate::effects) fn send_owed_notices(run: &Run) -> Result<Vec<NoticeUnmarked>> {
    let owed: Vec<Intent> = crate::effects::fleet(run.path)?
        .intents
        .into_iter()
        .filter(|i| !i.open() && i.notice.as_ref().is_some_and(Notice::owed))
        .collect();
    let mut unmarked = Vec::new();
    for intent in owed {
        match super::owner(&intent) {
            Reading::Live(_) | Reading::Unreadable { .. } => continue,
            Reading::Gone => {}
        }
        let Some(notice) = intent.notice.as_ref().filter(|n| n.owed()) else {
            continue;
        };
        let mark = send_owner_notice(run, &intent.id, &notice.text);
        if let Err(e) = mark_notice(run, &intent, notice, mark.clone(), None) {
            unmarked.push(NoticeUnmarked {
                intent: intent.id.clone(),
                mark,
                refusal: e.key().to_owned(),
            });
        }
    }
    Ok(unmarked)
}

/// Send `text` to the owner through the mailbox CLI (`lane-mail notice
/// --item overseer --to owner --file FILE`), as the legacy `fleet_log_refusal`
/// sent it. A notice the owner already received within the mailbox's window
/// is refused by the CLI as a repeat, which is `sent`; any other refusal or
/// a CLI that could not be run is `unsent:<cause>`, recorded, never a reason
/// to hold the outcome.
fn send_owner_notice(run: &Run, intent_id: &str, text: &str) -> String {
    let path = run
        .settings
        .state_dir
        .join("intents")
        .join(format!("{intent_id}.notice"));
    if let Some(dir) = path.parent()
        && let Err(e) = std::fs::create_dir_all(dir)
    {
        return format!("unsent:notice-dir:{e}");
    }
    if let Err(e) = std::fs::write(&path, format!("{text}\n")) {
        return format!("unsent:notice-write:{e}");
    }
    let file = path.display().to_string();
    let result = host::run_tagged(
        "job",
        "lane-mail",
        &run.settings.lane_mail_cli,
        "notice",
        &[
            "notice", "--item", "overseer", "--to", "owner", "--file", &file,
        ],
        NOTICE_TIMEOUT,
    );
    let _ = std::fs::remove_file(&path);
    match result {
        Ok(out) if out.status.success() => "sent".to_owned(),
        Ok(out) => {
            let line = host::stderr_text(&out)
                .lines()
                .next()
                .unwrap_or_default()
                .to_owned();
            if line.starts_with("lane-mail: duplicate id=")
                || line.starts_with("lane-mail: owner-notice-repeated=")
            {
                "sent".to_owned()
            } else {
                format!("unsent:status={}:{line}", out.status.code().unwrap_or(-1))
            }
        }
        Err(e) => format!("unsent:{}", e.key()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The launcher's record names a unit or the setsid group the launcher
    /// read before it returned (decisions 115 (B), 120); a record that names
    /// no identity reads unreadable, never absent, and a missing record reads
    /// absent. The two unit states that end a job are the manager's words.
    #[test]
    fn the_launcher_record_names_the_unit_or_the_setsid_group() {
        let dir = tempfile::tempdir().expect("tempdir");
        let record = dir.path().join("i.job");
        assert_eq!(
            read_handle(&record),
            SidecarRead::Absent,
            "no record: nothing was asked"
        );
        std::fs::write(
            &record,
            "runner=systemd\nunit=orch-transfer-7\nline=runner=systemd unit=orch-transfer-7\n",
        )
        .unwrap();
        assert_eq!(
            read_handle(&record),
            SidecarRead::Present(JobHandle::Unit {
                unit: "orch-transfer-7".to_owned()
            })
        );
        std::fs::write(
            &record,
            "runner=setsid\npid=4242\nstart=ticks:9\nline=runner=setsid reason=no-linger\n",
        )
        .unwrap();
        assert_eq!(
            read_handle(&record),
            SidecarRead::Present(JobHandle::Group(Identity {
                pid: 4242,
                start: "ticks:9".to_owned()
            }))
        );
        std::fs::write(
            &record,
            "runner=setsid\nline=runner=setsid reason=fixture\n",
        )
        .unwrap();
        assert!(
            matches!(read_handle(&record), SidecarRead::Unreadable { .. }),
            "a setsid record with no pid is unread, never absent"
        );
        // Decision 124d (19): the launcher's ended status, durable or on the
        // reply alone where its store was unwritable. A word settles the
        // launch as nothing started; `unwound-failed` holds the job.
        std::fs::write(
            &record,
            "runner=setsid\nstatus=exited-7\nline=runner=setsid reason=fixture\n",
        )
        .unwrap();
        assert_eq!(
            read_handle(&record),
            SidecarRead::Failed {
                status: "exited-7".to_owned()
            }
        );
        std::fs::write(
            &record,
            "runner=setsid\nstatus=unwound-failed\nline=runner=setsid reason=fixture\n",
        )
        .unwrap();
        assert_eq!(
            read_handle(&record),
            SidecarRead::Unreadable {
                cause: "unwound-failed".to_owned()
            },
            "a group the launcher could not read empty, with no leader known, holds the job"
        );
        // Decision 124g (31): the record keeps the leader of a group the
        // launcher could not read empty, and names that group.
        std::fs::write(
            &record,
            "runner=setsid\nstatus=unwound-failed\npid=4243\nstart=ticks:11\nline=runner=setsid reason=fixture\n",
        )
        .unwrap();
        assert_eq!(
            read_handle(&record),
            SidecarRead::Present(JobHandle::Group(Identity {
                pid: 4243,
                start: "ticks:11".to_owned()
            })),
            "the group the launcher could not read empty is read by pgid from here"
        );
        assert_eq!(
            reply_status("job-unit: launch-failed status=exited-7 record=unwritable"),
            Some(SidecarRead::Failed {
                status: "exited-7".to_owned()
            })
        );
        assert_eq!(
            reply_status(
                "job-unit: record-unwritable path=/x status=record-unwritable record=unwritable"
            ),
            Some(SidecarRead::Failed {
                status: "record-unwritable".to_owned()
            })
        );
        assert_eq!(
            reply_status(
                "job-unit: record-unwritable path=/x status=unwound-failed record=unwritable"
            ),
            None,
            "an unwound-failed reply reads the record, which names the group's leader"
        );
        assert_eq!(
            reply_status("job-unit: launch-failed unit=x.service load=masked detail=y"),
            Some(SidecarRead::Absent)
        );
        assert_eq!(
            reply_status("job-unit: record-unwritable path=/x"),
            None,
            "a reply with no status reads the record"
        );
        assert_eq!(reply_status("job-unit: usage subcommand=launch"), None);
        assert_eq!(unit_state("not-found", ""), Some(JobEnd::UnitGone));
        assert_eq!(
            unit_state("loaded", "failed"),
            Some(JobEnd::UnitEnded {
                state: "failed".to_owned()
            })
        );
        assert_eq!(unit_state("loaded", "active"), None);
        assert_eq!(unit_state("", ""), None);
    }

    /// Decision 124g (31), R-U4g6 opus L4: a launcher record ended
    /// `unwound-failed` with the leader's identity names the job group, read
    /// by its pgid on every reconcile. The leader lives: the group stands. The
    /// leader exits leaving a member in its group: the group still stands,
    /// never `job-exited` over a running descendant. The member ends: the
    /// group reads empty and the job is discharged `job-exited`, so the hold
    /// settles.
    #[test]
    fn an_unwound_failed_group_is_read_by_pgid_until_it_empties() {
        let dir = tempfile::tempdir().unwrap();
        let roots = crate::settings::Roots {
            project: dir.path().into(),
            common: dir.path().into(),
        };
        let settings = crate::settings::load(
            &roots,
            &[],
            &crate::settings::Flags {
                state_dir: Some(dir.path().into()),
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
        // The group: a session leader that forks a member into its group,
        // names both, and exits after two seconds while the member sleeps on.
        let pids = dir.path().join("pids");
        let mut leader = std::process::Command::new("setsid")
            .arg("bash")
            .arg("-c")
            .arg("sleep 60 & echo \"$$ $!\" > \"$0\"; exec sleep 2")
            .arg(&pids)
            .spawn()
            .expect("setsid and bash on PATH");
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let (leader_pid, member_pid): (u32, u32) = loop {
            if let Ok(text) = std::fs::read_to_string(&pids)
                && let Some((l, m)) = text.trim().split_once(' ')
                && let (Ok(l), Ok(m)) = (l.parse(), m.parse())
            {
                break (l, m);
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the leader never wrote the pids"
            );
            std::thread::sleep(Duration::from_millis(20));
        };
        let leader_identity = match process::identity(leader_pid) {
            Reading::Live(id) => id,
            Reading::Gone | Reading::Unreadable { .. } => panic!("the leader's identity"),
        };
        let id = "stop-controller:overseer:3:1-1";
        let record = state::job_record_path(dir.path(), id);
        std::fs::create_dir_all(record.parent().unwrap()).unwrap();
        std::fs::write(
            &record,
            format!(
                "runner=setsid\nstatus=unwound-failed\npid={}\nstart={}\nline=runner=setsid reason=no-systemd-run\n",
                leader_identity.pid, leader_identity.start
            ),
        )
        .unwrap();
        let path = dir.path().join(state::FLEET_FILE_NAME);
        let intent: Intent = serde_json::from_value(json!({
            "id": id, "op": "stop-controller", "target": "overseer:3",
            "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "obligations": {"standing": [{"kind": "job-sidecar", "record": record.display().to_string(), "role": "job"}],
                "discharged": [], "signalled": false}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_str(state::fixtures::FLEET).unwrap();
        fleet["intents"] = json!([intent]);
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let group = Obligation::JobGroup(leader_identity.clone());
        // The leader lives: the record names the group, which stands.
        let mut operation = Operation::open(&run, &intent).unwrap();
        operation.read_standing_jobs().unwrap();
        assert_eq!(operation.obligations.jobs(), vec![group.clone()]);
        // The leader exits; its member runs on in the group: still standing.
        let _ = leader.wait();
        assert_eq!(process::still_runs(&leader_identity), Reading::Gone);
        let current = read_intent(&path, id).unwrap();
        let mut operation = Operation::open(&run, &current).unwrap();
        operation.read_standing_jobs().unwrap();
        assert_eq!(
            operation.obligations.jobs(),
            vec![group.clone()],
            "a leader gone with a member running is a group still running"
        );
        // The member ends: the group reads empty and the job is discharged.
        let _ = std::process::Command::new("kill")
            .args(["-KILL", &member_pid.to_string()])
            .status();
        let gone = std::time::Instant::now() + Duration::from_secs(5);
        while process::identity(member_pid) != Reading::Gone && std::time::Instant::now() < gone {
            std::thread::sleep(Duration::from_millis(20));
        }
        let current = read_intent(&path, id).unwrap();
        let mut operation = Operation::open(&run, &current).unwrap();
        operation.read_standing_jobs().unwrap();
        assert!(
            operation.obligations.jobs().is_empty(),
            "{:?}",
            operation.obligations.record()
        );
        assert!(
            operation
                .obligations
                .record()
                .discharged
                .iter()
                .any(|d| d.obligation == group && d.by == "job-exited"),
            "{:?}",
            operation.obligations.record()
        );
    }

    /// Decision 124h (33), R-U4g7 Codex `job-exit-unknown-probe.py` and opus
    /// L1: a launcher record ended `unwound-failed` with the group key alone,
    /// the leader having exited before its start was read, names the job
    /// group by its pgid. A member still in that group holds the job; the
    /// member ending reads the group empty and discharges the job
    /// `job-exited`, so the hold settles with no start made up for it.
    #[test]
    fn an_unwound_failed_record_with_the_group_key_alone_is_read_by_pgid_until_it_empties() {
        let dir = tempfile::tempdir().unwrap();
        let roots = crate::settings::Roots {
            project: dir.path().into(),
            common: dir.path().into(),
        };
        let settings = crate::settings::load(
            &roots,
            &[],
            &crate::settings::Flags {
                state_dir: Some(dir.path().into()),
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
        // The group: a session leader that forks a member into its group,
        // names both, and exits at once, as the probe's job did.
        let pids = dir.path().join("pids");
        let mut leader = std::process::Command::new("setsid")
            .arg("bash")
            .arg("-c")
            .arg("sleep 60 & echo \"$$ $!\" > \"$0\"; exit 7")
            .arg(&pids)
            .spawn()
            .expect("setsid and bash on PATH");
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let (pgid, member_pid): (u32, u32) = loop {
            if let Ok(text) = std::fs::read_to_string(&pids)
                && let Some((l, m)) = text.trim().split_once(' ')
                && let (Ok(l), Ok(m)) = (l.parse(), m.parse())
            {
                break (l, m);
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the leader never wrote the pids"
            );
            std::thread::sleep(Duration::from_millis(20));
        };
        let _ = leader.wait();
        let id = "stop-controller:overseer:3:1-1";
        let record = state::job_record_path(dir.path(), id);
        std::fs::create_dir_all(record.parent().unwrap()).unwrap();
        std::fs::write(
            &record,
            format!(
                "runner=setsid\nstatus=unwound-failed\npgid={pgid}\nline=runner=setsid reason=no-systemd-run\n"
            ),
        )
        .unwrap();
        let path = dir.path().join(state::FLEET_FILE_NAME);
        let intent: Intent = serde_json::from_value(json!({
            "id": id, "op": "stop-controller", "target": "overseer:3",
            "created_at": "2026-01-29T15:20:00Z", "outcome": "unconfirmed",
            "obligations": {"standing": [{"kind": "job-sidecar", "record": record.display().to_string(), "role": "job"}],
                "discharged": [], "signalled": false}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_str(state::fixtures::FLEET).unwrap();
        fleet["intents"] = json!([intent]);
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let group = Obligation::JobPgid { pgid };
        // The record names the group by its key; the member runs: standing.
        let mut operation = Operation::open(&run, &intent).unwrap();
        operation.read_standing_jobs().unwrap();
        assert_eq!(operation.obligations.jobs(), vec![group.clone()]);
        let current = read_intent(&path, id).unwrap();
        let mut operation = Operation::open(&run, &current).unwrap();
        operation.read_standing_jobs().unwrap();
        assert_eq!(
            operation.obligations.jobs(),
            vec![group.clone()],
            "a group with a member running stands, read by its key alone"
        );
        // The member ends: the group reads empty and the job is discharged.
        let _ = std::process::Command::new("kill")
            .args(["-KILL", &member_pid.to_string()])
            .status();
        let gone = std::time::Instant::now() + Duration::from_secs(5);
        while process::identity(member_pid) != Reading::Gone && std::time::Instant::now() < gone {
            std::thread::sleep(Duration::from_millis(20));
        }
        let current = read_intent(&path, id).unwrap();
        let mut operation = Operation::open(&run, &current).unwrap();
        operation.read_standing_jobs().unwrap();
        assert!(
            operation.obligations.jobs().is_empty(),
            "{:?}",
            operation.obligations.record()
        );
        assert!(
            operation
                .obligations
                .record()
                .discharged
                .iter()
                .any(|d| d.obligation == group && d.by == "job-exited"),
            "{:?}",
            operation.obligations.record()
        );
    }

    /// Decision 124f (28), R-U4g6 Codex
    /// `rg6_outcome_committed_without_notice_retries_announcement` and opus
    /// `probe-notice-crash.rs`: a failed outcome committed through the store
    /// alone, the state a crash between the outcome's write and the send
    /// leaves, records its notice `owed` with its fleet-log row and sends
    /// nothing. The next outcome of the same intent under the same owner,
    /// identical and so recorded nowhere, sends the owed notice once and
    /// marks it `sent`; a third changes nothing and sends nothing again.
    #[test]
    fn an_outcome_committed_without_its_send_owes_a_notice_the_next_outcome_sends_once() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let roots = crate::settings::Roots {
            project: dir.path().into(),
            common: dir.path().into(),
        };
        let mut settings = crate::settings::load(
            &roots,
            &[],
            &crate::settings::Flags {
                state_dir: Some(dir.path().into()),
                private_env: false,
            },
        )
        .unwrap();
        let calls = dir.path().join("mail-calls");
        let mail = dir.path().join("lane-mail");
        std::fs::write(
            &mail,
            format!(
                "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '{}'\n",
                calls.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&mail, std::fs::Permissions::from_mode(0o755)).unwrap();
        settings.lane_mail_cli = mail;
        let owner = Owner {
            pid: 77,
            start: "ticks:77".into(),
        };
        let env = ops::Env {
            now_secs: 1_769_700_000,
            now_nanos: 1_769_700_000_000_000_000,
            nonce: 77,
            owner: Some(owner.clone()),
        };
        let path = dir.path().join(state::FLEET_FILE_NAME);
        let intent: Intent = serde_json::from_value(json!({
            "id": "request-transfer:overseer:3:1-1", "op": "request-transfer",
            "target": "overseer:3",
            "created_at": "2026-01-29T15:20:00Z", "outcome": "not-started", "owner": owner,
            "obligations": {"standing": [], "discharged": [], "signalled": false}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_str(state::fixtures::FLEET).unwrap();
        fleet["intents"] = json!([intent]);
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let rows_before = fleet["fleet_log"].as_array().map_or(0, Vec::len);
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let sent_calls = || {
            std::fs::read_to_string(&calls)
                .unwrap_or_default()
                .lines()
                .filter(|l| l.starts_with("notice "))
                .count()
        };
        let outcome = |operation: Operation| {
            operation.settle(
                Word::Failed,
                json!({"retired": false, "note": "job-launch-failed"}),
            )
        };
        // The crash: the outcome's write lands, the send never runs.
        let operation = Operation::open(&run, &intent).unwrap();
        let request = super::super::record(outcome(operation));
        let committed = ops::apply(
            &path,
            &Request::RecordOutcome(Box::new(request)),
            &env,
            state::Locking::FLOCK,
        )
        .unwrap();
        assert!(matches!(committed.report, ops::Report::RecordOutcome(ref r) if r.recorded_now));
        let current = read_intent(&path, &intent.id).unwrap();
        assert!(!current.open());
        let owed = current
            .notice
            .clone()
            .expect("the outcome's write records the notice");
        assert!(owed.owed(), "{owed:?}");
        assert_eq!(owed.key, "job-launch-failed");
        let log = crate::effects::fleet(&path).unwrap().fleet_log;
        assert_eq!(log.len(), rows_before + 1, "the row lands with the outcome");
        assert_eq!(log.last().unwrap()["text"], owed.text);
        assert_eq!(sent_calls(), 0, "nothing was sent before the crash");
        // The next outcome of the intent under the same owner: recorded
        // nowhere, the owed notice sent once and marked.
        let retry = Operation::open(&run, &current).unwrap();
        let applied = super::super::apply_outcome(&run, outcome(retry)).unwrap();
        assert!(matches!(applied.report, ops::Report::RecordOutcome(ref r) if !r.recorded_now));
        assert_eq!(sent_calls(), 1, "the owed notice is sent once");
        let marked = read_intent(&path, &intent.id).unwrap().notice.unwrap();
        assert_eq!(
            marked,
            Notice {
                owner: "sent".to_owned(),
                ..owed
            }
        );
        assert_eq!(
            crate::effects::fleet(&path).unwrap().fleet_log.len(),
            rows_before + 1
        );
        // A third outcome, and a reconcile's walk: nothing more.
        let again = Operation::open(&run, &current).unwrap();
        super::super::apply_outcome(&run, outcome(again)).unwrap();
        send_owed_notices(&run).unwrap();
        assert_eq!(sent_calls(), 1, "a sent notice is never sent again");
    }

    /// Decision 124k (40), R-U4g8 Codex
    /// `rg8_claimed_repeat_keeps_claimants_files`: a job's claim lands after
    /// the reconcile read the prior job ended and before the repeat launcher
    /// touches the job's files. The repeat's first owner-conditional write
    /// yields to the claimant, so the claimant's request and record stand
    /// untouched, its set is unchanged, the launcher program is never run,
    /// and the claimant is named as the owner.
    #[test]
    fn a_claimed_repeat_keeps_the_claimants_files() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let roots = crate::settings::Roots {
            project: dir.path().into(),
            common: dir.path().into(),
        };
        let mut settings = crate::settings::load(
            &roots,
            &[],
            &crate::settings::Flags {
                state_dir: Some(dir.path().into()),
                private_env: false,
            },
        )
        .unwrap();
        let launched = dir.path().join("job-unit-called");
        let job_unit = dir.path().join("job-unit");
        std::fs::write(
            &job_unit,
            format!(
                "#!/bin/bash\nprintf 'called' > '{}'\nexit 7\n",
                launched.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&job_unit, std::fs::Permissions::from_mode(0o755)).unwrap();
        settings.job_unit = job_unit;
        settings.lane_mail_cli = std::path::PathBuf::from("/bin/false");
        let owner = Owner {
            pid: 77,
            start: "ticks:77".into(),
        };
        let claimant = Owner {
            pid: 88,
            start: "ticks:88".into(),
        };
        let env = ops::Env {
            now_secs: 1_769_700_000,
            now_nanos: 1_769_700_000_000_000_000,
            nonce: 77,
            owner: Some(owner.clone()),
        };
        let path = dir.path().join(state::FLEET_FILE_NAME);
        let intent: Intent = serde_json::from_value(json!({
            "id": "stop-controller:overseer:3:1-1", "op": "stop-controller",
            "target": "overseer:3",
            "created_at": "2026-01-29T15:20:00Z", "outcome": "not-started", "owner": owner,
            "obligations": {"standing": [{"kind": "job-sidecar", "record": state::job_record_path(dir.path(), "stop-controller:overseer:3:1-1").display().to_string(), "role": "job"}],
                "discharged": [], "signalled": false}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_str(state::fixtures::FLEET).unwrap();
        fleet["intents"] = json!([intent]);
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let operation = Operation::open(&run, &intent).unwrap();
        // The real claim, landed after the reconcile's last read.
        ops::apply(
            &path,
            &Request::ClaimIntent(ClaimIntent {
                intent_id: intent.id.clone(),
            }),
            &ops::Env {
                owner: Some(claimant.clone()),
                ..env.clone()
            },
            state::Locking::FLOCK,
        )
        .unwrap();
        let request_path = state::job_request_path(&settings.state_dir, &intent.id);
        let record_path = state::job_record_path(&settings.state_dir, &intent.id);
        std::fs::create_dir_all(request_path.parent().unwrap()).unwrap();
        std::fs::write(&request_path, "claimant-request").unwrap();
        std::fs::write(&record_path, "claimant-record").unwrap();
        let before = read_intent(&path, &intent.id).unwrap();
        let answer = launch_job(
            &run,
            operation,
            &intent,
            &Request::StopController(crate::ops::StopController {}),
            Op::Stop,
            &owner,
            Start::Repeat,
        );
        assert!(
            matches!(&answer, Err(Error::Yielded { owner, .. }) if *owner == claimant),
            "the repeat's first write yields to the claimant: {answer:?}"
        );
        assert_eq!(
            std::fs::read_to_string(&request_path).unwrap(),
            "claimant-request",
            "a yielded launcher never replaces the claimant's request"
        );
        assert_eq!(
            std::fs::read_to_string(&record_path).unwrap(),
            "claimant-record",
            "a yielded launcher never removes the claimant's record"
        );
        let after = read_intent(&path, &intent.id).unwrap();
        assert_eq!(
            after.obligations, before.obligations,
            "the claimant's set is unchanged"
        );
        assert_eq!(after.owner, Some(claimant));
        assert!(
            matches!(std::fs::metadata(&launched), Err(e) if e.kind() == std::io::ErrorKind::NotFound),
            "the launcher program was never run"
        );
    }

    /// Decision 124d (17), R-U4g5 Codex
    /// `rg5_claimed_deadline_does_not_send_a_stale_failure_notice`: a job's
    /// claim lands after the launcher's last loop read and before its `fail`;
    /// the launcher's outcome write yields to the claimant, so nothing is
    /// announced: the mailbox program is never run, the intent carries no
    /// notice, and the claimant's state is the answer.
    #[test]
    fn a_claimed_deadline_announces_nothing() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let roots = crate::settings::Roots {
            project: dir.path().into(),
            common: dir.path().into(),
        };
        let mut settings = crate::settings::load(
            &roots,
            &[],
            &crate::settings::Flags {
                state_dir: Some(dir.path().into()),
                private_env: false,
            },
        )
        .unwrap();
        let called = dir.path().join("mail-called");
        let mail = dir.path().join("lane-mail");
        std::fs::write(
            &mail,
            format!("#!/bin/bash\nprintf 'called' > '{}'\n", called.display()),
        )
        .unwrap();
        std::fs::set_permissions(&mail, std::fs::Permissions::from_mode(0o755)).unwrap();
        settings.lane_mail_cli = mail;
        let owner = Owner {
            pid: 77,
            start: "ticks:77".into(),
        };
        let claimant = Owner {
            pid: 88,
            start: "ticks:88".into(),
        };
        let env = ops::Env {
            now_secs: 1_769_700_000,
            now_nanos: 1_769_700_000_000_000_000,
            nonce: 77,
            owner: Some(owner.clone()),
        };
        let path = dir.path().join(state::FLEET_FILE_NAME);
        let intent: Intent = serde_json::from_value(json!({
            "id": "request-transfer:overseer:3:1-1", "op": "request-transfer",
            "target": "overseer:3",
            "created_at": "2026-01-29T15:20:00Z", "outcome": "not-started", "owner": owner,
            "obligations": {"standing": [{"kind": "job-sidecar", "record": state::job_record_path(dir.path(), "request-transfer:overseer:3:1-1").display().to_string(), "role": "job"}],
                "discharged": [], "signalled": false}
        }))
        .unwrap();
        let mut fleet: Value = serde_json::from_str(state::fixtures::FLEET).unwrap();
        fleet["intents"] = json!([intent]);
        std::fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let run = Run {
            path: &path,
            settings: &settings,
            env: &env,
            locking: state::Locking::FLOCK,
            clock: &crate::schedule::SystemClock,
        };
        let operation = Operation::open(&run, &intent).unwrap();
        // The real claim, landed after the launcher's final loop read.
        ops::apply(
            &path,
            &Request::ClaimIntent(ClaimIntent {
                intent_id: intent.id.clone(),
            }),
            &ops::Env {
                owner: Some(claimant.clone()),
                ..env.clone()
            },
            state::Locking::FLOCK,
        )
        .unwrap();
        let answer = fail(
            &run,
            operation,
            Op::Transfer,
            &owner,
            "runner=setsid",
            "job-unclaimed",
            "deadline".into(),
        )
        .unwrap();
        assert_eq!(answer.owner, claimant, "the claimant's state is the answer");
        let current = read_intent(&path, &intent.id).unwrap();
        assert!(current.notice.is_none(), "{current:?}");
        assert!(
            current.open(),
            "the claimant's intent stays open: {current:?}"
        );
        assert!(
            !called.exists(),
            "the mailbox was asked to send a failure the claimant's job owns"
        );
    }
}
