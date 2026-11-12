//! The detached job a controller retirement runs in: a succession and the
//! explicit stop both end the controller, and the process that asked for
//! either answers from the controller's own pane as often as not, so
//! neither effect runs in the caller's process. The caller writes the
//! request beside the record, starts the job detached, waits until the job
//! has claimed the intent's owner lease and answers `<op>-started
//! intent=<id>`; the job claims, runs the effect, records the outcome and
//! announces a failure once: the fleet-log row and the owner notice,
//! recorded on the intent so a later reconcile of the same outcome emits
//! nothing again.
//!
//! The launcher is this module: a job runs as a transient user unit where
//! a user manager answers and lingers, since a manager that does not
//! linger is stopped, with its units, when the user's last login session
//! ends while tmux and the lanes run on; elsewhere it runs as a `setsid`
//! child whose identity, pid and kernel start, the launcher reads from the
//! kernel's table itself before it returns, so no child writes its own
//! identity and none is manufactured. A unit holds every process the job
//! starts; under `setsid` a descendant that starts its own session can
//! outlive the job. The record beside the request, `<intent>.job` (the
//! fleet watch's `oversee-watch.runner`), is written whole before each
//! launch attempt and names how the job runs, so a reconcile after a crash
//! reads the job at that address.
//!
//! A job the launcher was asked for is an obligation from that moment until
//! it claims or is read ended: the handle writes it before anything starts,
//! reads the launcher's record into it, and a launch that failed after its
//! fork, or a job that never claimed within the bound, leaves the intent
//! `unconfirmed` with the job standing, never `failed` over a job that may
//! still run. A job asked for again extends the recorded set, and the
//! outstanding-job predicate reads the recorded job obligations alone,
//! never the claim's `handed_from`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use agent_runtime::process::{self, Identity};
use agent_runtime::protocol::Outcome;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::obligations::{Discharge, JobEnd, JobHandle, SidecarRead};
use super::{Bootstrap, Operation, POLL, Reading, Run, Word, fleet_view, read_intent};
use crate::error::{Error, Result};
use crate::ops::{self, ClaimIntent, RecordProgress};
use crate::state::{self, EffectOp, Intent, Notice, Obligation, Owner, Role, WatchJob};

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
    /// The launcher's runner line: the unit the job runs as, or its
    /// `setsid` group's reason and identity.
    pub job: String,
    /// The job's identity, the intent's owner from its claim on.
    pub owner: Owner,
    /// The identity that persisted the intent and handed it over.
    pub handed_from: Owner,
}

/// How long a `systemd-run` may take to answer.
const JOB_LAUNCH_TIMEOUT: Duration = Duration::from_secs(60);

/// The grace between SIGTERM and SIGKILL, both for what a unit still
/// holds when it stops and for the unwind of a child this launcher forked,
/// so the two graces are one number.
const KILL_GRACE: Duration = Duration::from_secs(10);

/// How long the user manager is given to answer for a unit's state, and
/// a `loginctl` or `kill` to answer.
const UNIT_READ_TIMEOUT: Duration = Duration::from_secs(30);

/// The job a controller start owes beside its runner, as the start's opener
/// names it: `argv` launched detached as `name`, the launcher's record at
/// `record`, its standard error appended to `stderr`, and the claimant's
/// record whose live identity is the job's claim. A start that owes no such
/// job passes none.
pub struct Companion<'a> {
    pub argv: &'a [String],
    pub name: String,
    pub record: PathBuf,
    pub stderr: PathBuf,
    pub claim: Claimant,
}

/// A claimant's record: `key=value` lines naming the claimant's `pid`, its
/// process `start` and the `state` it holds. A record naming another state
/// or no pid names no claimant.
pub struct Claimant {
    pub path: PathBuf,
    pub state: String,
}

/// The cause a claimant's record that cannot be read is held under.
const CLAIM_RECORD: &str = "claim-record";

/// The cause a record with no start whose pid runs is held under: a
/// running pid with no start to match is no identity to act by.
const START_MISSING: &str = "start-missing";

impl Claimant {
    /// The claimant's identity read three-valued: live under its recorded
    /// start; gone where no record stands, it names no claimant, or its pid
    /// is dead or reused under another start; unreadable where the record or
    /// the process table cannot be read. A record with no start is read by
    /// its pid alone: gone where no process holds it, else unreadable.
    fn read(&self) -> Reading<Identity> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Reading::Gone,
            Err(_) => {
                return Reading::Unreadable {
                    cause: CLAIM_RECORD,
                };
            }
        };
        let (mut pid, mut start, mut state) = (0, None, "");
        for line in text.lines() {
            match line.split_once('=') {
                Some(("pid", value)) => pid = value.parse().unwrap_or(0),
                Some(("start", value)) => start = Some(value),
                Some(("state", value)) => state = value,
                _ => {}
            }
        }
        if pid == 0 || state != self.state {
            return Reading::Gone;
        }
        let Some(start) = start else {
            return match process::identity(pid) {
                Reading::Live(_) => Reading::Unreadable {
                    cause: START_MISSING,
                },
                Reading::Gone => Reading::Gone,
                Reading::Unreadable { cause } => Reading::Unreadable { cause },
            };
        };
        process::still_runs(&Identity {
            pid,
            start: start.to_owned(),
        })
    }
}

/// What the start's watch step found: the watch claimed, by
/// this run's launch or by an earlier start; the launcher refused before it
/// started anything; a job started that has not claimed within the bound,
/// standing in the set for the reconcile; or a claim the runtime could not
/// read, never acted on.
pub enum WatchStart {
    Claimed(WatchJob),
    Refused { cause: String },
    Unclaimed { job: String },
    Unreadable { cause: String },
}

/// The notes a start held on its watch carries, each the key of the owner
/// notice the hold owes.
const WATCH_LAUNCH_FAILED: &str = "watch-launch-failed";
const WATCH_UNCLAIMED: &str = "watch-unclaimed";
const WATCH_CLAIM_UNREADABLE: &str = "watch-claim-unreadable";

impl WatchStart {
    /// The watch the start publishes, or what holds it: the note the hold
    /// is recorded under and the observation it carries.
    pub fn held(self) -> std::result::Result<WatchJob, (&'static str, Value)> {
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
/// and its job name carry.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Transfer,
    Stop,
}

impl Op {
    pub(super) fn of_intent(op: EffectOp) -> Option<Op> {
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

    /// The job's name, which names the unit where a manager runs one.
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
pub enum Start {
    First,
    Repeat,
}

/// How the launcher ran a job, the record's `runner=` word.
enum Runner {
    /// A transient user unit of this name under the lingering manager.
    Unit(String),
    /// A `setsid` child, with the reason the manager was not used.
    Setsid { reason: String },
}

/// What a launch left: the sidecar's reading, which the launcher knows
/// without reading its record back, the runner line the reply carries, and
/// the cause where nothing runs or the launch ended after its fork.
pub struct Launched {
    pub unanswered: bool,
    pub read: SidecarRead,
    pub line: String,
    pub failed: Option<String>,
}

/// What the launcher answers its caller, as a stage records it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "launch", rename_all = "kebab-case")]
pub enum Launch {
    Started {
        runner: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        unit: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        start: Option<String>,
        line: String,
    },
    Refused {
        cause: String,
    },
    /// The launcher gave no answer: the job may have started, so no caller
    /// starts it again; its record is read back for its handle.
    Unanswered {
        cause: String,
    },
}

impl Launched {
    /// What the launch answers its caller, the one reading every caller
    /// takes: started by the unit or the group identity the record names;
    /// unanswered where the job may run (a lost manager answer, a failure
    /// after the fork that left a group standing, a record that cannot be
    /// read), so no caller starts it twice; refused where nothing runs.
    pub fn answer(self) -> Launch {
        let Launched {
            unanswered,
            read,
            line,
            failed,
        } = self;
        if unanswered || (failed.is_some() && matches!(read, SidecarRead::Present(_))) {
            return Launch::Unanswered {
                cause: failed.unwrap_or(line),
            };
        }
        match read {
            SidecarRead::Present(JobHandle::Unit { unit }) => Launch::Started {
                runner: "systemd".to_owned(),
                unit: Some(unit),
                pid: None,
                start: None,
                line,
            },
            SidecarRead::Present(JobHandle::Group(identity)) => Launch::Started {
                runner: "setsid".to_owned(),
                unit: None,
                pid: Some(identity.pid),
                start: Some(identity.start),
                line,
            },
            SidecarRead::Present(JobHandle::Pgid(pgid)) => Launch::Unanswered {
                cause: format!("pgid={pgid}"),
            },
            SidecarRead::Failed { status } => Launch::Refused {
                cause: failed.unwrap_or(status),
            },
            SidecarRead::Absent => Launch::Refused {
                cause: failed.unwrap_or_else(|| "launcher-unrecorded".to_owned()),
            },
            SidecarRead::Unreadable { cause } => Launch::Unanswered { cause },
        }
    }
}

pub(super) struct Launcher<'a> {
    clock: &'a dyn crate::schedule::Clock,
}

impl Launcher<'_> {
    fn now(&self) -> std::time::Instant {
        self.clock.now()
    }
    fn sleep(&self, duration: Duration) {
        self.clock.sleep(duration);
    }
    /// The unit route: the record pre-written with the unit's name, then
    /// `systemd-run --user` with the caller's directory, environment,
    /// open-file limits and, where the caller runs in a user-manager slice,
    /// that slice with its task and memory caps, so a warden that reads
    /// units outside an agent's slice as escaped work sees the job inside
    /// it. A `systemd-run` that never started, or one that exited before it
    /// asked a manager anything (`ASKED_NOTHING`), proves no unit was asked
    /// for, and falls to `setsid` (`Err` with the reason). Every other
    /// failure is read back as the reconcile reads a unit: one read ended
    /// ends the launch, and any other answer is the job, held by its unit
    /// until its claim or a reconcile reads it. `systemd-run`'s exit status
    /// does not tell a refusal the manager answered from a bus error or a
    /// client timeout after the manager acted, and `--collect` unloads a
    /// unit once it ends, so the manager's having no record of the unit may
    /// be a job that ran.
    fn launch_unit(
        &self,
        record: &Path,
        unit: &str,
        argv: &[&str],
        stderr: Option<&Path>,
        bounds: Bounds,
    ) -> std::result::Result<Launched, String> {
        let memory = bounds
            .memory
            .map(|bytes| format!(" memory-max={bytes}"))
            .unwrap_or_default();
        let line = format!("runner=systemd unit={unit}{memory}");
        if let Err(e) = write_record(
            record,
            &format!("runner=systemd\nunit={unit}\nline={line}\n"),
        ) {
            return Ok(Launched {
                unanswered: false,
                read: SidecarRead::Absent,
                line,
                failed: Some(format!(
                    "record-unwritable path={} cause={e}",
                    record.display()
                )),
            });
        }
        let cwd = std::env::current_dir()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| ".".to_owned());
        let service = format!("{unit}.service");
        let mut words: Vec<String> = vec![
            "--user".to_owned(),
            "--quiet".to_owned(),
            "--collect".to_owned(),
            format!("--unit={unit}"),
            format!("--working-directory={cwd}"),
            "-p".to_owned(),
            format!("TimeoutStopSec={}", KILL_GRACE.as_secs()),
            "-p".to_owned(),
            "IgnoreSIGPIPE=no".to_owned(),
        ];
        if let Some(cap) = bounds.runtime {
            words.extend(["-p".to_owned(), format!("RuntimeMaxSec={}", cap.as_secs())]);
        }
        // The memory cap holds the job's whole tree, swap included, since a
        // swapped page is memory the cap would not count; the manager's own
        // policy stops the unit at its first OOM kill and so ends the job
        // before it records the kill as its verdict.
        if let Some(bytes) = bounds.memory {
            for property in [
                format!("MemoryMax={bytes}"),
                "MemorySwapMax=0".to_owned(),
                "OOMPolicy=continue".to_owned(),
            ] {
                words.extend(["-p".to_owned(), property]);
            }
        }
        if let Some((soft, hard)) = nofile_limits() {
            words.push("-p".to_owned());
            words.push(format!("LimitNOFILE={soft}:{hard}"));
        }
        if let Some(cgroup) = own_cgroup() {
            if let Some(slice) = slice_of(&cgroup) {
                words.push(format!("--slice={slice}"));
            }
            let dir = cgroup_dir(&cgroup);
            if let Some(cap) = cgroup_cap(&dir, "pids.max") {
                words.push("-p".to_owned());
                words.push(format!("TasksMax={cap}"));
            }
            // A soft cap beside the memory cap would throttle the job short
            // of it, so a runaway tree slows to its time bound instead of
            // failing at the cap.
            if bounds.memory.is_none()
                && let Some(cap) = cgroup_cap(&dir, "memory.high")
            {
                words.push("-p".to_owned());
                words.push(format!("MemoryHigh={cap}"));
            }
        }
        // The manager takes an `append:` file by its absolute path only, and
        // a caller of `launch-job` names it relative to its own directory.
        if let Some(err) = stderr {
            let err = std::path::absolute(err).unwrap_or_else(|_| err.to_path_buf());
            words.push("-p".to_owned());
            words.push(format!("StandardError=append:{}", err.display()));
        }
        // A unit inherits the manager's environment, not the caller's, so
        // every exported variable a unit can carry is handed over, the
        // client reading each value from the environment it is given.
        let env = client_env();
        words.extend(unit_setenv());
        words.push("--".to_owned());
        // The manager expands `${NAME}` in a unit's command line, and `$$`
        // is its spelling of one literal `$`.
        words.extend(argv.iter().map(|word| word.replace('$', "$$")));
        let args: Vec<&str> = words.iter().map(String::as_str).collect();
        let detail = match host::run_tagged_alone(
            "job",
            "systemd-run",
            Path::new("systemd-run"),
            "launch",
            &args,
            &runner_env(&env),
            JOB_LAUNCH_TIMEOUT,
        ) {
            Ok(out) if out.status.success() => {
                return Ok(Launched {
                    unanswered: false,
                    read: SidecarRead::Present(JobHandle::Unit {
                        unit: unit.to_owned(),
                    }),
                    line,
                    failed: None,
                });
            }
            Ok(out) => match out.status.code() {
                Some(_) => {
                    let stderr = host::stderr_text(&out);
                    if let Some(refusal) = asked_nothing(&stderr) {
                        return Err(format!("unit-launch-failed detail={refusal}"));
                    }
                    call_line(&stderr)
                }
                None => "signal".to_owned(),
            },
            Err(e @ agent_runtime::Error::NotStarted { .. }) => {
                return Err(format!("unit-launch-failed detail={e}"));
            }
            Err(e) => e.to_string(),
        };
        // A unit the manager has loaded and not ended after the failed call
        // is the job: the call failed after the manager accepted it.
        let states = unit_states(unit);
        if let Some((load, active)) = &states
            && load == "loaded"
            && unit_state(load, active).is_none()
        {
            return Ok(Launched {
                unanswered: false,
                read: SidecarRead::Present(JobHandle::Unit {
                    unit: unit.to_owned(),
                }),
                line,
                failed: None,
            });
        }
        match states.and_then(|(load, active)| unit_state(&load, &active)) {
            Some(JobEnd::UnitEnded { state }) => {
                let status = format!("unit-{state}");
                let ended = ended_record(record, "systemd", &status, None, &line);
                Ok(Launched {
                    unanswered: false,
                    read: SidecarRead::Failed {
                        status: status.clone(),
                    },
                    line,
                    failed: Some(format!(
                        "launch-failed unit={service} active={state} detail={detail}{ended}"
                    )),
                })
            }
            Some(end @ (JobEnd::Exited | JobEnd::Claimed)) => {
                unreachable!("a unit's read answers no {end:?}")
            }
            Some(JobEnd::UnitGone) | None => Ok(Launched {
                unanswered: true,
                read: SidecarRead::Present(JobHandle::Unit {
                    unit: unit.to_owned(),
                }),
                line: format!("{line} start-unconfirmed detail={detail}"),
                failed: None,
            }),
        }
    }

    /// The `setsid` route: the record pre-written with the runner and the
    /// reason, the child started under `setsid`, which execs it in a
    /// session of its own without forking, so the child's pid is the job's;
    /// its start is then read from the kernel's table and recorded before
    /// this returns. A child that has already exited when its row is read
    /// is a launch that failed, by its status; a row that cannot be read
    /// ends the child and refuses the launch; a record that cannot be
    /// rewritten with the identity ends the child the same way, so nothing
    /// runs unrecorded. Each of those unwinds the child's whole group and
    /// reads it empty before the launch is reported ended; a group that
    /// does not read empty stands by its key.
    fn launch_setsid(
        &self,
        record: &Path,
        reason: &str,
        argv: &[&str],
        stderr: Option<&Path>,
        memory: Option<u64>,
    ) -> Launched {
        // A process group holds no memory bound: a cap asked for is said
        // unheld once, on the line the run's record and log carry.
        let unheld = memory
            .map(|_| {
                let cause = reason.split(' ').next().unwrap_or(reason);
                format!(" memory-cap=unavailable cause={cause}")
            })
            .unwrap_or_default();
        let line = format!("runner=setsid reason={reason}{unheld}");
        let ended = |status: &str, cause: String| Launched {
            unanswered: false,
            read: SidecarRead::Failed {
                status: status.to_owned(),
            },
            line: line.clone(),
            failed: Some(cause),
        };
        if let Err(e) = write_record(record, &format!("runner=setsid\nline={line}\n")) {
            return Launched {
                unanswered: false,
                read: SidecarRead::Absent,
                line,
                failed: Some(format!(
                    "record-unwritable path={} cause={e}",
                    record.display()
                )),
            };
        }
        let stderr = match stderr {
            Some(err) => match std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(err)
            {
                Ok(file) => Some(file),
                Err(e) => {
                    let status = "stderr-unwritable";
                    let noted = ended_record(record, "setsid", status, None, &line);
                    return ended(
                        status,
                        format!("launch-failed path={} cause={e}{noted}", err.display()),
                    );
                }
            },
            None => None,
        };
        let mut child = match host::start_detached(
            "job",
            "setsid",
            Path::new("setsid"),
            "launch",
            argv,
            host::Place::default(),
            stderr,
        ) {
            Ok(child) => child,
            Err(e) => {
                let status = "setsid-unrun";
                let noted = ended_record(record, "setsid", status, None, &line);
                return ended(status, format!("launch-failed cause={e}{noted}"));
            }
        };
        let pid = child.pid();
        let identity = match process::identity(pid) {
            Reading::Live(identity) => identity,
            Reading::Gone => {
                // The child exited before its row was read: a launch that
                // failed, by its status. An exited leader proves nothing
                // about what it started: its group is torn down and read
                // empty before the launch is reported ended.
                let status = match child.reap() {
                    Ok(status) => exit_word(status),
                    Err(e) => format!("exited-unread-{e}"),
                };
                let forked = Forked {
                    pgid: pid,
                    leader: None,
                };
                return self.unwound(record, &line, &status, None, forked);
            }
            Reading::Unreadable { cause } => {
                let status = "identity-unread";
                self.end_child(&mut child, None);
                return self.unwound(
                    record,
                    &line,
                    status,
                    Some(format!("cause={cause}")),
                    Forked {
                        pgid: pid,
                        leader: None,
                    },
                );
            }
        };
        let line = format!("{line} pid={pid} start={}", identity.start);
        if let Err(e) = write_record(
            record,
            &format!(
                "runner=setsid\npid={pid}\nstart={}\nline={line}\n",
                identity.start
            ),
        ) {
            // The identity was read but could not be recorded: the child is
            // ended the same way, so nothing runs unrecorded.
            let status = "record-unwritable";
            self.end_child(&mut child, Some(&identity));
            return self.unwound(
                record,
                &line,
                status,
                Some(format!("path={} cause={e}", record.display())),
                Forked {
                    pgid: pid,
                    leader: Some(identity),
                },
            );
        }
        Launched {
            unanswered: false,
            read: SidecarRead::Present(JobHandle::Group(identity)),
            line,
            failed: None,
        }
    }

    /// End the child this launch forked, by its own pid first: it may not
    /// have run its own `setsid` yet, so it leads no process group and a
    /// group teardown alone would miss it. TERM, the grace, then KILL; by
    /// identity through the one stop where its start was read, by the
    /// `kill` program otherwise. Neither the signal's answer nor the wait is
    /// the launch's answer: `unwound` reads the child by its key after this.
    /// A child that still runs after the KILL's grace is never waited for; its
    /// handle's drop reaps it.
    fn end_child(&self, child: &mut host::Detached, identity: Option<&Identity>) {
        let exited = |child: &mut host::Detached| matches!(child.exited(), Ok(Some(_)));
        if let Some(identity) = identity {
            let _ = process::stop_identities(std::slice::from_ref(identity), KILL_GRACE);
        } else {
            let pid = child.pid().to_string();
            for signal in ["-TERM", "-KILL"] {
                let _ = host::run_tagged(
                    "job",
                    "kill",
                    Path::new("kill"),
                    "signal",
                    &[signal, &pid],
                    UNIT_READ_TIMEOUT,
                );
                let deadline = self.now() + KILL_GRACE;
                while !exited(child) && self.now() < deadline {
                    self.sleep(POLL);
                }
                if exited(child) {
                    break;
                }
            }
        }
        let deadline = self.now() + KILL_GRACE;
        while !exited(child) && self.now() < deadline {
            self.sleep(POLL);
        }
    }

    /// A launch ended after its fork: the group the child led (its pgid
    /// being its pid) torn down by every live member's identity and read
    /// in the kernel's table, the record rewritten with `status`, and the
    /// launch reported with its cause. A group that reads empty is nothing
    /// started; one that does not, or a table that cannot be read, holds
    /// the job `unwound-failed` by the leader's identity where it was read,
    /// else by the group key alone, which every post-fork path holds. Both
    /// keys read the child itself as well as its group, so a child its launch
    /// could not end holds the job though it never ran its own `setsid`.
    fn unwound(
        &self,
        record: &Path,
        line: &str,
        status: &str,
        detail: Option<String>,
        forked: Forked,
    ) -> Launched {
        let Forked { pgid, leader } = forked;
        let mut members = Vec::new();
        if let Ok(rows) = process::table() {
            for row in rows.iter().filter(|row| row.pgrp == pgid) {
                if let Reading::Live(member) = process::identity(row.pid) {
                    members.push(member);
                }
            }
        }
        if !members.is_empty() {
            let _ = process::stop_identities(&members, KILL_GRACE);
        }
        let cause = match detail {
            Some(detail) => format!("launch-failed status={status} {detail}"),
            None => format!("launch-failed status={status}"),
        };
        if pgid_end(pgid).is_some() {
            let noted = ended_record(record, "setsid", status, None, line);
            return Launched {
                unanswered: false,
                read: SidecarRead::Failed {
                    status: status.to_owned(),
                },
                line: line.to_owned(),
                failed: Some(format!("{cause}{noted}")),
            };
        }
        let handle = match leader {
            Some(identity) => JobHandle::Group(identity),
            None => JobHandle::Pgid(pgid),
        };
        let noted = ended_record(record, "setsid", "unwound-failed", Some(&handle), line);
        Launched {
            unanswered: false,
            read: SidecarRead::Present(handle),
            line: line.to_owned(),
            failed: Some(format!("{cause} group=unwound-failed{noted}")),
        }
    }
}

/// What a launch bounds its job by: its lifetime, and the memory of its
/// whole process tree in bytes.
#[derive(Clone, Copy, Default)]
pub struct Bounds {
    pub runtime: Option<Duration>,
    pub memory: Option<u64>,
}

pub fn launch_recorded(
    name: &str,
    key: &str,
    record: &Path,
    argv: &[&str],
    stderr: Option<&Path>,
    bounds: Bounds,
    clock: &dyn crate::schedule::Clock,
) -> Launched {
    let launcher = Launcher { clock };
    let runner = match probe_manager() {
        Runner::Unit(_) => Runner::Unit(unit_name(name, key)),
        other => other,
    };
    let runner = match runner {
        Runner::Unit(unit) => match launcher.launch_unit(record, &unit, argv, stderr, bounds) {
            Ok(answer) => return answer,
            Err(reason) => Runner::Setsid { reason },
        },
        other => other,
    };
    let Runner::Setsid { reason } = runner else {
        unreachable!()
    };
    launcher.launch_setsid(record, &reason, argv, stderr, bounds.memory)
}

/// A caller's own command started as a recorded job: `orch-runtime
/// launch-job`, which the watch and waiter fences run. The unit is keyed by
/// this process's pid, so two launches of one name never share a unit.
pub fn launch_command(name: &str, record: &Path, argv: &[&str], stderr: Option<&Path>) -> Launch {
    launch_recorded(
        name,
        &std::process::id().to_string(),
        record,
        argv,
        stderr,
        Bounds::default(),
        &crate::schedule::SystemClock,
    )
    .answer()
}

/// The cgroup v2 directory of this process, where it runs under this
/// user's manager (`own_cgroup`).
pub fn own_cgroup_dir() -> Option<std::path::PathBuf> {
    own_cgroup().map(|cgroup| cgroup_dir(&cgroup))
}

fn cgroup_dir(cgroup: &str) -> std::path::PathBuf {
    Path::new("/sys/fs/cgroup").join(cgroup.trim_start_matches('/'))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the recorded group is stopped by each member's observed start identity"
)]
pub fn stop_group(identity: &Identity) -> Result<bool> {
    let rows = process::table().map_err(|e| {
        Error::Runtime(agent_runtime::Error::refused(
            "stop-unreadable",
            &[("cause", e.cause)],
        ))
    })?;
    if matches!(process::still_runs(identity), Reading::Gone)
        && (rows.iter().any(|r| r.pid == identity.pid)
            || !rows.iter().any(|r| r.pgrp == identity.pid))
    {
        return Ok(false);
    }
    let mut members = Vec::new();
    for row in rows.iter().filter(|r| r.pgrp == identity.pid) {
        match process::identity(row.pid) {
            Reading::Live(id) => members.push(id),
            Reading::Gone => {}
            Reading::Unreadable { cause } => {
                return Err(Error::Runtime(agent_runtime::Error::refused(
                    "stop-unreadable",
                    &[("cause", cause)],
                )));
            }
        }
    }
    match process::stop_identities(&members, KILL_GRACE)? {
        process::Stop::AlreadyGone => Ok(false),
        process::Stop::Stopped { .. } => Ok(true),
        other @ (process::Stop::IdentityStale
        | process::Stop::Timeout { .. }
        | process::Stop::Unreadable { .. }) => Err(Error::Runtime(agent_runtime::Error::refused(
            "stop-unconfirmed",
            &[("reading", &format!("{other:?}"))],
        ))),
    }
}

pub fn recorded_live(record: &Path) -> Reading<()> {
    match read_handle(record) {
        SidecarRead::Present(JobHandle::Unit { unit }) => match unit_end(&unit) {
            Some(JobEnd::UnitGone | JobEnd::UnitEnded { .. }) => Reading::Gone,
            None => Reading::Unreadable {
                cause: "unit-unsettled",
            },
            Some(JobEnd::Exited | JobEnd::Claimed) => unreachable!(),
        },
        SidecarRead::Present(JobHandle::Group(id)) => group_reading(&id),
        SidecarRead::Present(JobHandle::Pgid(pgid)) => pgid_reading(pgid),
        SidecarRead::Absent | SidecarRead::Failed { .. } => Reading::Gone,
        SidecarRead::Unreadable { .. } => Reading::Unreadable {
            cause: "runner-unreadable",
        },
    }
}

pub fn stop_recorded(record: &Path) -> Result<Option<&'static str>> {
    match read_handle(record) {
        SidecarRead::Present(JobHandle::Unit { unit }) => {
            let out = host::run_tagged(
                "validate",
                "systemctl",
                Path::new("systemctl"),
                "stop",
                &["--user", "stop", &format!("{unit}.service")],
                UNIT_READ_TIMEOUT,
            )?;
            if out.status.success() {
                Ok(Some("systemd"))
            } else if matches!(
                unit_end(&unit),
                Some(JobEnd::UnitGone | JobEnd::UnitEnded { .. })
            ) {
                Ok(None)
            } else {
                Err(Error::Runtime(agent_runtime::Error::refused(
                    "stop-failed",
                    &[("unit", &unit)],
                )))
            }
        }
        SidecarRead::Present(JobHandle::Group(identity)) => {
            if stop_group(&identity)? {
                Ok(Some("setsid"))
            } else {
                Ok(None)
            }
        }
        SidecarRead::Failed { .. } | SidecarRead::Absent => Ok(None),
        SidecarRead::Present(JobHandle::Pgid(_)) | SidecarRead::Unreadable { .. } => {
            Err(Error::Runtime(agent_runtime::Error::refused(
                "stop-unreadable",
                &[("record", &record.display().to_string())],
            )))
        }
    }
}

/// Hand a just-persisted transfer or stop to a detached job: write the
/// request where the job reads it, start the job detached (a transient user
/// unit where the manager lingers, a `setsid` group elsewhere; it holds the
/// caller's environment and directory), and wait until the job has claimed
/// the intent, so no window stands in which a contender reads a dead owner.
/// A launch that ended with nothing started leaves the intent `failed` with
/// its cause and the controller as it was; a job that may have started, and
/// one that never claims within the bound, leave it `unconfirmed` with the
/// job standing, which the reconcile reads.
pub fn start(
    run: &Run,
    intent: &Intent,
    request: &impl Serialize,
    start: Start,
) -> Result<JobStarted> {
    let Some(op) = Op::of_intent(intent.op) else {
        unreachable!("only a transfer or a stop is handed to the job")
    };
    let handed_from = intent
        .owner
        .clone()
        .ok_or(Error::OwnerUnreadable { op: op.word() })?;
    // The launcher owns the intent until the job claims it: the handle
    // writes under that owner, so every write yields once the job's claim
    // moved it, a job that claimed keeps its own set, and the handle stops
    // at that write without acting; the claimant's state is then the
    // answer, `<op>-started`, as it is for a claim the outcome write found.
    let Some(bootstrap) = Bootstrap::controller(intent.op) else {
        unreachable!("only a transfer or a stop is handed to the job")
    };
    let operation = Operation::open(run, intent, bootstrap)?;
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

/// Write the request, launch the job, read its record and wait for the
/// claim, under the launcher-side handle. A repeat's removal of the prior
/// job's files and its request rewrite follow the handle's owner-conditional
/// write: the write proves, under the store lock, that the intent is still
/// this launcher's and its set the record's, and a `Yielded` stops before
/// either file is touched, so a job that claimed meanwhile keeps its
/// request and its record.
fn launch_job(
    run: &Run,
    mut operation: Operation,
    intent: &Intent,
    request: &impl Serialize,
    op: Op,
    handed_from: &Owner,
    start: Start,
) -> Result<JobStarted> {
    let id = intent.id.as_str();
    let request_path = state::job_request_path(&run.state_dir, id);
    let record_path = state::job_record_path(&run.state_dir, id);
    if start == Start::Repeat {
        operation.write()?;
        remove_files(&run.state_dir, id);
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
    let state_dir = run.state_dir.display().to_string();
    let file = run.path.display().to_string();
    let argv = [
        exe.as_str(),
        "--state-dir",
        &state_dir,
        "job",
        "--file",
        &file,
        "--intent",
        id,
    ];
    let launched = operation.launch(op.job_name(), &record_path, &argv, None)?;
    // The job's identity is read into the set before the claim wait begins,
    // so a contender and a reconcile find the job by its own identity, not
    // the unread sidecar, and the launcher-side handle writes nothing more
    // once the loop begins.
    operation.read_sidecar(&record_path, Some(launched.read))?;
    if let Some(cause) = launched.failed {
        return fail(
            run,
            operation,
            op,
            handed_from,
            &launched.line,
            "job-launch-failed",
            cause,
        );
    }
    let line = launched.line;
    // The job's first act is its claim (`claim-intent`); until then this
    // process holds the lease, so a contender defers to it.
    let deadline = operation.now() + run.settings.claim.get()?;
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
/// launch settled the job (nothing started), `failed` with the whole set
/// discharged (a transfer's overwritten pending is restored); otherwise the
/// job stands: `unconfirmed`, the request file kept for it, until it claims
/// or the reconcile reads it ended. The writes are the launcher's, made only
/// while it still owns the intent: where a job claimed meanwhile, nothing
/// is written and the claimant's state is the answer, `<op>-started`.
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

/// What a launch's fork left: the group its child leads and the child's
/// identity where it was read.
struct Forked {
    pgid: u32,
    leader: Option<Identity>,
}

impl Operation<'_> {
    /// Start `argv` detached as the operation's job named `name`, its
    /// record at `record`: the launcher's unread record is an obligation
    /// from this moment, written with its address before anything starts,
    /// so a contender that reads a dead owner finds the job the record
    /// names, at the address the ask named; a repeated ask extends the
    /// recorded set. The record is then pre-written with the runner, the
    /// job started as a unit under a lingering manager or as a `setsid`
    /// child whose identity is read before this returns, and the record
    /// rewritten with what the launch left. `stderr` names a file the job's
    /// standard error is appended to.
    fn launch(
        &mut self,
        name: &str,
        record: &Path,
        argv: &[&str],
        stderr: Option<&Path>,
    ) -> Result<Launched> {
        self.obligations.ask_job(record);
        self.write()?;
        Ok(launch_recorded(
            name,
            self.intent_id(),
            record,
            argv,
            stderr,
            Bounds::default(),
            self.clock,
        ))
    }

    /// Read the launcher's record into the set: the sidecar obligation is
    /// discharged by the record it names, and the handle it names becomes
    /// the job's obligation. `known` is the reading the launcher made
    /// itself the moment it launched; a reconcile reads the record at its
    /// recorded address. A record carrying the launch's ended `status=` word
    /// settles the sidecar as nothing started, except `unwound-failed`, a
    /// group the launcher could not read empty, which holds the job.
    fn read_sidecar(&mut self, record: &Path, known: Option<SidecarRead>) -> Result<()> {
        let address = record.display().to_string();
        match known.unwrap_or_else(|| read_handle(record)) {
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

    pub(super) fn nothing_stands(&self) -> bool {
        self.obligations.record().standing.is_empty()
    }

    /// The companion job a start owes: its claimant's record read first,
    /// and a live claimant, this run's job or an earlier start's, is the
    /// job; else a job of this intent still standing is read again and
    /// holds while it runs; else the companion's argv is launched detached,
    /// the launcher's unread record an obligation before anything starts,
    /// and the claim is waited for within the job claim bound. A job that
    /// claimed is discharged by that read; one that has not stands for the
    /// reconcile, which runs this step again. An unreadable claim is never a
    /// reason to launch.
    pub fn ensure_watch(&mut self, companion: &Companion) -> Result<WatchStart> {
        match self.watch_claimed(&companion.claim)? {
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
        let argv: Vec<&str> = companion.argv.iter().map(String::as_str).collect();
        let launched = self.launch(
            &companion.name,
            &companion.record,
            &argv,
            Some(&companion.stderr),
        )?;
        self.read_sidecar(&companion.record, Some(launched.read))?;
        if let Some(cause) = launched.failed {
            return Ok(WatchStart::Refused { cause });
        }
        let line = launched.line;
        let deadline = self.now() + self.run.settings.claim.get()?;
        loop {
            match self.watch_claimed(&companion.claim)? {
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

    /// The companion's claim: `Live` with the record `overseer.watch` takes
    /// where the claimant's record names a live identity, every job
    /// obligation of this intent discharged `watch-claimed` by that read and
    /// the first of them naming the job; `Gone` where no claimant stands;
    /// the claimant's unreadable otherwise.
    fn watch_claimed(&mut self, claimant: &Claimant) -> Result<Reading<WatchJob>> {
        let identity = match claimant.read() {
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
                | Obligation::Receipt => continue,
            };
            self.discharge(Discharge::Job {
                job: handle,
                end: JobEnd::Claimed,
            })?;
        }
        Ok(Reading::Live(job))
    }

    /// The outstanding-job predicate both the transfer and the stop
    /// reconciles apply before replacing a sidecar or starting another job:
    /// the job obligations the intent recorded, each read
    /// for its end. A unit read not-found or ended, a group read gone
    /// (`job-exited`), and a sidecar whose record now names a handle or is
    /// gone update the set; a job that still runs stands. The predicate reads
    /// the recorded set alone: a job that claimed was
    /// discharged by its claim, so nothing of it stands.
    pub fn job_standing(&mut self, intent: &Intent) -> Result<bool> {
        if Op::of_intent(intent.op).is_none() {
            return Ok(false);
        }
        self.read_standing_jobs()?;
        // A job still stands where any job obligation remains undischarged.
        Ok(!self.obligations.jobs().is_empty())
    }

    /// Read every standing job obligation by its own key: the unread sidecar
    /// at the address its ask recorded, a unit through the manager, a group
    /// through the one identity
    /// reader, each discharged where it reads ended.
    pub(super) fn read_standing_jobs(&mut self) -> Result<()> {
        for job in self.obligations.jobs() {
            match job {
                Obligation::JobSidecar { record } => self.read_sidecar(Path::new(&record), None)?,
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
                | Obligation::Receipt => {}
            }
        }
        Ok(())
    }

    /// Whether the record says a job of this intent ended by its own read,
    /// for the observation's `job: ended`.
    pub fn job_ended(&self) -> bool {
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
        | Obligation::Receipt => WatchJob {
            runner: "unread".to_owned(),
            unit: None,
            pid: None,
            start: None,
        },
    }
}

/// The end of the job group `leader` leads, by `group_reading`.
fn group_end(leader: &Identity) -> Option<JobEnd> {
    matches!(group_reading(leader), Reading::Gone).then_some(JobEnd::Exited)
}

/// The job group `leader` leads: the leader's identity through the one
/// reader, and, once that reads gone, the kernel's table for any live member
/// naming the leader's pid as its group, so a leader that exited leaving a
/// member is a group still running. A live process at the leader's pid ends
/// the group: the kernel frees a pid number only once no task holds it as its
/// pid, its group or its session, so a process that took the number, one
/// that leads a group of its own included, proves no member of the leader's
/// group runs.
pub fn group_reading(leader: &Identity) -> Reading<()> {
    match process::still_runs(leader) {
        Reading::Live(_) => Reading::Live(()),
        Reading::Unreadable { cause } => Reading::Unreadable { cause },
        Reading::Gone => match process::table() {
            Ok(rows) if rows.iter().any(|row| row.pid == leader.pid) => Reading::Gone,
            Ok(rows) if rows.iter().any(|row| row.pgrp == leader.pid) => Reading::Live(()),
            Ok(_) => Reading::Gone,
            Err(e) => Reading::Unreadable { cause: e.cause },
        },
    }
}

/// The end of the job group `pgid`, read by the group key alone.
fn pgid_end(pgid: u32) -> Option<JobEnd> {
    matches!(pgid_reading(pgid), Reading::Gone).then_some(JobEnd::Exited)
}

/// The job a group key with no identity names, read in the kernel's table:
/// the child whose pid the key is, and any member naming it as its group,
/// since a child that has not yet run its own `setsid` is in its parent's
/// group. A pid and a pgid are not reallocated while that process or a
/// member of that group runs, so this read can hold too long, while another
/// process holds a pid the job left, and never ends a running job.
pub fn pgid_reading(pgid: u32) -> Reading<()> {
    table_reading(|row| row.pid == pgid || row.pgrp == pgid)
}

/// Whether a live row of the kernel's table matches. `Unreadable` where the
/// table cannot be read, which the table reader answers for an unreadable
/// row too. A zombie is no row: the table reader leaves an exited process its
/// parent has not reaped out of every row, so a reaped-late process never
/// holds the job.
fn table_reading(matches: impl Fn(&process::Row) -> bool) -> Reading<()> {
    match process::table() {
        Ok(rows) if rows.iter().any(matches) => Reading::Live(()),
        Ok(_) => Reading::Gone,
        Err(e) => Reading::Unreadable { cause: e.cause },
    }
}

/// The job the launcher's record names, in its `runner=`, `unit=`, `pid=`,
/// `start=`, `line=` form: a unit where a manager runs it, else the process
/// group the launcher read the child's identity for before it returned.
/// `Absent` where no record was written: the launch failed before anything
/// started. `Unreadable` where a record stands but names no identity yet,
/// so the job is unread, never absent. A record whose launch ended
/// `unwound-failed` names the group the launcher could not read empty, read
/// on every reconcile from here: by the leader's identity where the
/// launcher read its start, else by the group key `pgid=` alone, which
/// every post-fork path holds; no start is ever made up for it. The one
/// reader of the record, so every consumer reads one launch three-valued
/// the same way.
pub fn read_handle(record: &Path) -> SidecarRead {
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
    // `status=` word once the child and its group are unwound: nothing
    // started, so a later read settles the job rather than holding it
    // unread; `unwound-failed` says the group did not read empty: with the
    // leader's identity it names that group, read by pgid from here, and
    // without one the job stands as possibly started.
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

/// Which runner a launch takes: a unit where `systemd-run` is on `PATH`,
/// the user manager lingers and a probe unit starts; `setsid` otherwise,
/// with the reason. A `Linger` that cannot be read is no linger. The probe
/// starts a unit, since that is the question: `systemctl is-system-running`
/// exits non-zero on a degraded manager that still runs units.
fn probe_manager() -> Runner {
    let setsid = |reason: String| Runner::Setsid { reason };
    if !on_path("systemd-run") {
        return setsid("no-systemd-run".to_owned());
    }
    let Some(uid) = own_uid() else {
        return setsid("linger-unread detail=uid-unread".to_owned());
    };
    let linger = host::run_tagged(
        "job",
        "loginctl",
        Path::new("loginctl"),
        "show-user",
        &["show-user", &uid, "-p", "Linger", "--value"],
        UNIT_READ_TIMEOUT,
    );
    match linger {
        Err(e) => return setsid(format!("linger-unread detail={e}")),
        Ok(out) if !out.status.success() => {
            return setsid(format!(
                "linger-unread detail={}",
                first_line(&host::stderr_text(&out))
            ));
        }
        Ok(out) if host::stdout_text(&out) != "yes" => return setsid("no-linger".to_owned()),
        Ok(_) => {}
    }
    let env = client_env();
    match host::run_tagged_alone(
        "job",
        "systemd-run",
        Path::new("systemd-run"),
        "probe",
        &["--user", "--quiet", "--collect", "true"],
        &runner_env(&env),
        JOB_LAUNCH_TIMEOUT,
    ) {
        Ok(out) if out.status.success() => Runner::Unit(String::new()),
        Ok(out) => setsid(format!(
            "probe-failed detail={}",
            first_line(&host::stderr_text(&out))
        )),
        Err(e) => setsid(format!("probe-failed detail={e}")),
    }
}

/// `orch-NAME-STAMP`, STAMP the key's last `:` field (an intent id's clock
/// and nonce, a run directory's name), so two jobs one long-lived process
/// launches never share a unit name; anything a unit name cannot carry is
/// replaced by `_`.
fn unit_name(name: &str, intent: &str) -> String {
    let stamp = intent.rsplit(':').next().unwrap_or(intent);
    format!("orch-{name}-{stamp}")
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// An environment variable a unit can carry, as `systemd-run` accepts it
/// by `--setenv=NAME` from its own environment (measured, systemd 262): a
/// shell name, the names `compgen -e` gives the shell launcher, which its
/// parser refuses otherwise before any connect (`Cannot assign environment
/// variable`), and a value of UTF-8 text holding no Unicode noncharacter,
/// which the bus's strings cannot carry, so the client refuses it after its
/// connect with no message built (`Failed to create bus message`). Every
/// other value, a control character included, is accepted and sent.
fn unit_env<'a>(
    name: &'a std::ffi::OsStr,
    value: &'a std::ffi::OsStr,
) -> Option<(&'a str, &'a str)> {
    let name = name.to_str()?;
    let value = value.to_str()?;
    let mut bytes = name.bytes();
    let first = bytes.next()?;
    let shell_name = (first.is_ascii_alphabetic() || first == b'_')
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_');
    let noncharacter =
        |c: char| matches!(c, '\u{FDD0}'..='\u{FDEF}') || u32::from(c) & 0xFFFE == 0xFFFE;
    (shell_name && !value.chars().any(noncharacter)).then_some((name, value))
}

/// `env` in the form the runner takes.
fn runner_env(env: &[(String, std::ffi::OsString)]) -> Vec<(&str, &std::ffi::OsStr)> {
    env.iter()
        .map(|(name, value)| (name.as_str(), value.as_os_str()))
        .collect()
}

/// The client's environment: the job's own variables a unit can carry
/// (`unit_env`) less the names the client, or the loader that starts it,
/// reads for itself; the runtime directory and bus address as found, which
/// it reaches the user manager by; and the client's own settings
/// (`CLIENT_SETTINGS`) at the runtime's value. The client takes each
/// carried variable's value from here (`unit_setenv`): a value on its
/// command line is readable by every local user through `/proc` for as long
/// as the client runs, and a lane's token is among the values.
fn client_env() -> Vec<(String, std::ffi::OsString)> {
    let mut env: std::collections::BTreeMap<String, std::ffi::OsString> =
        std::collections::BTreeMap::new();
    for (key, value) in std::env::vars_os() {
        if let Some((name, value)) = unit_env(&key, &value)
            && !clients_own(name)
        {
            env.insert(name.to_owned(), value.into());
        }
    }
    for name in ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
        if let Some(value) = std::env::var_os(name) {
            env.insert(name.to_owned(), value);
        }
    }
    for (name, value) in CLIENT_SETTINGS {
        if let Some(value) = value {
            env.insert(name.to_owned(), value.into());
        }
    }
    env.into_iter().collect()
}

/// The `--setenv` words that hand the job's variables to the unit: each
/// carried variable by name, the client taking its value from
/// `client_env`; one the client or the loader reads for itself with the
/// job's value explicit, since by name the unit would get the client's own
/// value or none. The values on the command line are those names' alone:
/// the loader's paths, a terminal name, the manager's own stream and socket
/// names, and systemd's logging and bus settings.
fn unit_setenv() -> Vec<String> {
    std::env::vars_os()
        .filter_map(|(key, value)| {
            let (name, value) = unit_env(&key, &value)?;
            Some(if clients_own(name) {
                format!("--setenv={name}={value}")
            } else {
                format!("--setenv={name}")
            })
        })
        .collect()
}

/// Whether the client reads `name` from its environment (`CLIENT_SETTINGS`),
/// or the loader that starts it does (`ld.so(8)`'s `LD_` names, read before
/// the client runs: a missing preload or audit object puts the loader's own
/// line on stderr first, and `LD_DEBUG` puts its trace there).
fn clients_own(name: &str) -> bool {
    name.starts_with("LD_") || CLIENT_SETTINGS.iter().any(|(own, _)| *own == name)
}

/// The names the client reads from its environment, each at the value the
/// client runs under: fixed, or unset. The names are what a `getenv`
/// interposition shows the installed client (systemd 262) asking for on
/// every executed path under a private runtime directory and a private
/// peer: no bus, a started job, the manager's refusal, a dropped and a
/// withheld reply, the parser's refusal, no runtime directory, and the two
/// names that open further reads (`SYSTEMD_EXEC_PID`, debug logging).
/// systemd's logging settings are fixed, since an inherited one moves the
/// line, prefixes it or empties stderr, and an unreadable one puts a warning
/// before it; the locale is fixed for the error text; every other name is
/// unset, so the client runs as itself (`SYSTEMD_INVOKED_AS` picks another
/// program's parser), reads no kernel command line (`SYSTEMD_EXEC_PID`) and
/// waits systemd's own 25 s for a withheld reply (`SYSTEMD_BUS_TIMEOUT`).
/// `PATH`, the runtime directory and the bus address are the job's as found.
const CLIENT_SETTINGS: [(&str, Option<&str>); 21] = [
    ("SYSTEMD_LOG_LEVEL", Some("info")),
    ("SYSTEMD_LOG_TARGET", Some("console")),
    ("SYSTEMD_LOG_TIME", Some("0")),
    ("SYSTEMD_LOG_LOCATION", Some("0")),
    ("SYSTEMD_LOG_TID", Some("0")),
    ("SYSTEMD_LOG_COLOR", Some("0")),
    ("LC_ALL", Some("C")),
    ("JOURNAL_STREAM", None),
    ("NOTIFY_SOCKET", None),
    ("SYSTEMD_BUS_TIMEOUT", None),
    ("SYSTEMD_ENABLE_LOG_CONTEXT", None),
    ("SYSTEMD_EXEC_PID", None),
    ("SYSTEMD_IGNORE_CHROOT", None),
    ("SYSTEMD_IN_CHROOT", None),
    ("SYSTEMD_IN_INITRD", None),
    ("SYSTEMD_INVOKED_AS", None),
    ("SYSTEMD_LOG_RATELIMIT_KMSG", None),
    ("SYSTEMD_MEMPOOL", None),
    ("SYSTEMD_PROC_CMDLINE", None),
    ("SYSTEMD_UTF8", None),
    ("TERM", None),
];

/// The lines of a `systemd-run` that exited before it sent the manager
/// anything, measured on the real client (systemd 262) under a private
/// runtime directory and a private peer: its argument parser's refusal of
/// an environment variable (no connect), a bus it could not connect to (one
/// failed connect), a message it could not build from what it was handed
/// (no `StartTransientUnit` sent), and a property name its own table does
/// not know, which it refuses after the connect while it builds that
/// message: a client older than a property the launch sets (`OOMPolicy=`
/// needs systemd 243). The client parses before it connects and connects
/// before it sends, so such a line proves nothing was sent wherever it
/// stands: after a warning the client puts first, after the loader's line,
/// after its debug lines, or after the time, thread and location prefixes
/// its logging settings put before every line. Every other exit may follow
/// a call the manager received.
const ASKED_NOTHING: [&str; 4] = [
    "Cannot assign environment variable ",
    "Failed to connect to ",
    "Failed to create bus message: ",
    "Unknown assignment: ",
];

/// The client's line for a call the manager received: its answer, which is
/// the manager's own text and may hold a refusal's words, or the reply lost
/// or withheld after the call.
const SENT: &str = "Failed to start transient service unit: ";

/// The line of `stderr` that shows the client sent the manager nothing.
fn asked_nothing(stderr: &str) -> Option<&str> {
    stderr
        .lines()
        .find(|line| !line.contains(SENT) && ASKED_NOTHING.iter().any(|text| line.contains(text)))
}

/// The line of `stderr` for a `detail=` field where the call may have
/// reached the manager: the client's line for the call where one stands,
/// else the first line.
fn call_line(stderr: &str) -> String {
    stderr
        .lines()
        .find(|line| line.contains(SENT))
        .map_or_else(|| first_line(stderr), str::to_owned)
}

fn on_path(name: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| {
            std::fs::metadata(dir.join(name))
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
    })
}

fn own_uid() -> Option<String> {
    std::fs::read_to_string("/proc/self/status")
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|rest| rest.split_whitespace().next())
        .map(str::to_owned)
}

/// The cgroup v2 path this process runs in, where that path is below this
/// user's `user@UID.service`: nothing where the process runs outside that
/// manager (a login session scope, a system service) or the file holds no
/// cgroup v2 line.
fn own_cgroup() -> Option<String> {
    manager_cgroup(
        &std::fs::read_to_string("/proc/self/cgroup").ok()?,
        &own_uid()?,
    )
}

/// The cgroup v2 path a `/proc/PID/cgroup` text names, where that path is
/// below `user@UID.service`.
fn manager_cgroup(text: &str, uid: &str) -> Option<String> {
    let marker = format!("/user@{uid}.service/");
    text.lines()
        .find_map(|line| line.strip_prefix("0::"))
        .filter(|path| path.contains(&marker))
        .map(str::to_owned)
}

/// The innermost `.slice` of a cgroup path below the user manager.
fn slice_of(cgroup: &str) -> Option<String> {
    let (_, below) = cgroup.split_once(".service/")?;
    below
        .split('/')
        .rfind(|part| part.ends_with(".slice"))
        .map(str::to_owned)
}

/// A cgroup v2 limit file's value where it is a whole number; nothing where
/// it reads `max` (no limit), is absent (a controller the cgroup lacks) or
/// cannot be read, since the client's parser refuses `max` as a property
/// value after the connect, with nothing sent to the manager.
fn cgroup_cap(dir: &Path, file: &str) -> Option<String> {
    let value = std::fs::read_to_string(dir.join(file)).ok()?;
    let value = value.trim();
    (!value.is_empty() && value.bytes().all(|b| b.is_ascii_digit())).then(|| value.to_owned())
}

/// This process's open-file limits, soft and hard, as the manager spells
/// them, from `/proc/self/limits`.
fn nofile_limits() -> Option<(String, String)> {
    let text = std::fs::read_to_string("/proc/self/limits").ok()?;
    let line = text
        .lines()
        .find(|line| line.starts_with("Max open files"))?;
    let mut words = line["Max open files".len()..].split_whitespace();
    let spell = |word: &str| {
        if word == "unlimited" {
            "infinity".to_owned()
        } else {
            word.to_owned()
        }
    };
    Some((spell(words.next()?), spell(words.next()?)))
}

/// The first line of a program's answer, for a `detail=` field.
fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().to_owned()
}

/// The `exited-N` word for a reaped child's status: its exit code, or 128
/// plus the signal that ended it.
fn exit_word(status: std::process::ExitStatus) -> String {
    use std::os::unix::process::ExitStatusExt;
    match (status.code(), status.signal()) {
        (Some(code), _) => format!("exited-{code}"),
        (None, Some(signal)) => format!("exited-{}", 128 + signal),
        (None, None) => "exited-unknown".to_owned(),
    }
}

/// Write the launcher's record whole: a part file renamed into place, so a
/// reader never sees half of one.
fn write_record(record: &Path, text: &str) -> std::io::Result<()> {
    let part = record.with_extension("job.part");
    std::fs::write(&part, text)?;
    std::fs::rename(&part, record)
}

/// Rewrite the pre-written record with the launch's ended `status`, the
/// word a later read settles the job by rather than holding it unread; an
/// `unwound-failed` status keeps the group's key, `pgid=`, and the leader's
/// identity where it was read, so the group is read by that key on every
/// reconcile until it empties. A record that could not be rewritten adds
/// ` record=unwritable` to the cause, the reply then being the one place
/// the status is read from.
fn ended_record(
    record: &Path,
    runner: &str,
    status: &str,
    held: Option<&JobHandle>,
    line: &str,
) -> &'static str {
    let mut text = format!("runner={runner}\nstatus={status}\n");
    match held {
        Some(JobHandle::Group(identity)) => {
            text.push_str(&format!(
                "pgid={}\npid={}\nstart={}\n",
                identity.pid, identity.pid, identity.start
            ));
        }
        Some(JobHandle::Pgid(pgid)) => text.push_str(&format!("pgid={pgid}\n")),
        Some(JobHandle::Unit { .. }) | None => {}
    }
    text.push_str(&format!("line={line}\n"));
    match write_record(record, &text) {
        Ok(()) => "",
        Err(_) => " record=unwritable",
    }
}

/// The end of the unit `unit`, read through the user manager: `None` where
/// the manager did not answer or the unit still runs.
fn unit_end(unit: &str) -> Option<JobEnd> {
    let (load, active) = unit_states(unit)?;
    unit_state(&load, &active)
}

/// The unit's `LoadState` and `ActiveState` as the user manager answers
/// them; `None` where it did not answer.
fn unit_states(unit: &str) -> Option<(String, String)> {
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
    Some((
        lines.next().unwrap_or_default().to_owned(),
        lines.next().unwrap_or_default().to_owned(),
    ))
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
fn write_request(path: &Path, request: &impl Serialize) -> std::io::Result<()> {
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

/// Claim the intent for this job. A claim that refuses (the intent ended,
/// or its effect began under its first owner) ends the job before it opens
/// anything.
pub fn claim(run: &Run, intent_id: &str) -> Result<()> {
    ops::write_claim(
        run.path,
        &ClaimIntent {
            intent_id: intent_id.to_owned(),
        },
        run.env,
        run.locking,
    )
    .map(drop)
}

/// The announcement a failed or unconfirmed outcome of a job's operation
/// owes, as the outcome's own write records it `owed`: the key is the
/// observation's `note`, else its `cause`, else the outcome word. A start
/// held on its watch owes the same: its
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
    // No `to`: an intent's notice goes to the owner.
    Some(Notice {
        key,
        text,
        to: None,
        owner: state::NOTICE_OWED.to_owned(),
    })
}

/// Send the notice `intent` records owed, where it records one, and mark
/// it with how the send went in a follow-up write under `while_owner`:
/// the continuation of the outcome's write. A notice
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
/// every write.
fn mark_notice(
    run: &Run,
    intent: &Intent,
    owed: &Notice,
    mark: String,
    while_owner: Option<Owner>,
) -> Result<()> {
    ops::write_progress(
        run.path,
        &RecordProgress {
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
        },
        run.locking,
    )?;
    Ok(())
}

/// An owed notice the walk sent whose mark the store refused or could not
/// write: recorded in the request's reply, never a
/// reason to fail it. The notice stays `owed`, so the next walk sends it
/// again; the mailbox reads a repeat within its window as `sent`.
#[derive(Debug, Clone, Serialize)]
pub struct NoticeUnmarked {
    pub intent: String,
    /// The mark the send earned, `sent`, `unsent:<cause>` or
    /// `unanswered:<cause>`.
    pub mark: String,
    /// The key of the store's refusal.
    pub refusal: String,
}

/// Send every notice a closed intent still records owed: the continuation
/// a crash between the outcome's write and its send left behind, run by
/// every reconcile and every request. An intent whose recorded owner still
/// runs, or cannot be read, is that owner's to finish; one whose owner is
/// gone is sent once here and marked, so the next walk finds nothing owed.
/// A mark the store refused is returned for the reply and stops neither the
/// walk nor the request that runs it.
pub fn send_owed_notices(run: &Run) -> Result<Vec<NoticeUnmarked>> {
    send_notices(run, Notice::owed, false)
}

/// Send once more every notice whose send got no answer: the heartbeat's
/// retry, never the walk's, so the notice's bound is paid once more and not
/// on every request. A retry that gets no answer either is `unsent`, and
/// the notice is sent no more.
pub fn send_unanswered_notices(run: &Run) -> Result<Vec<NoticeUnmarked>> {
    send_notices(run, Notice::unanswered, true)
}

/// Send each notice `due` picks on a closed intent whose owner is gone, and
/// mark it; `last` makes a send with no answer final.
fn send_notices(run: &Run, due: fn(&Notice) -> bool, last: bool) -> Result<Vec<NoticeUnmarked>> {
    let owed: Vec<Intent> = fleet_view(run.path)?
        .intents
        .into_iter()
        .filter(|i| !i.open() && i.notice.as_ref().is_some_and(due))
        .collect();
    let mut unmarked = Vec::new();
    for intent in owed {
        match super::owner(&intent) {
            Reading::Live(_) | Reading::Unreadable { .. } => continue,
            Reading::Gone => {}
        }
        let Some(notice) = intent.notice.as_ref().filter(|n| due(n)) else {
            continue;
        };
        let mut mark = send_owner_notice(run, &intent.id, &notice.text);
        if last && mark.starts_with(state::NOTICE_UNANSWERED) {
            mark = format!("unsent:{mark}");
        }
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

/// Send `text` to the owner through the mailbox's owner notice. A notice
/// the mailbox took, or refused as a repeat of one that landed, is `sent`;
/// a refusal that wrote nothing is `unsent:<cause>`, any other
/// `unanswered:<cause>`, since the notice may have gone. Each is recorded,
/// never a reason to hold the outcome.
fn send_owner_notice(run: &Run, intent_id: &str, text: &str) -> String {
    let path = run
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
    let mark = owner_notice(&run.mail_program, &run.root, &path);
    let _ = std::fs::remove_file(&path);
    mark
}

/// How long the mailbox program's notice may take to answer.
const NOTICE_BOUND: Duration = Duration::from_secs(60);

/// The keyed line's prefix on the mailbox program's stderr.
const NOTICE_KEYED: &str = "lane-mail: ";

/// `notice --item overseer --to owner --file F --root ROOT` of the mailbox
/// program at `program`, run at the main checkout `root`: the mark the send
/// earns. The program prints each keyed refusal of a notice before its
/// append, so an exit with a keyed line wrote nothing (`unsent:`); a repeat
/// of a notice that landed (`duplicate id=` inside the minute,
/// `owner-notice-repeated=` inside the day) is `sent`; a run that gave no
/// answer, a signal, or an exit with no keyed line may follow the append.
fn owner_notice(program: &Path, root: &Path, file: &Path) -> String {
    const VERB: &str = "notice";
    let root_text = root.display().to_string();
    let file = file.display().to_string();
    let argv = [
        VERB, "--item", "overseer", "--to", "owner", "--file", &file, "--root", &root_text,
    ];
    let place = host::Place {
        cwd: Some(root),
        env: &[],
    };
    let output = match host::run_tagged_in(
        "mail",
        "lane-mail",
        program,
        VERB,
        &argv,
        place,
        NOTICE_BOUND,
    ) {
        Ok(output) => output,
        Err(e @ agent_runtime::Error::NotStarted { .. }) => return format!("unsent:{VERB}: {e}"),
        Err(e) => return format!("{}{VERB}: {e}", state::NOTICE_UNANSWERED),
    };
    let stderr = host::stderr_text(&output);
    let keyed = stderr.lines().find_map(|l| l.strip_prefix(NOTICE_KEYED));
    if output.status.success()
        || keyed.is_some_and(|k| {
            k.starts_with("duplicate id=") || k.starts_with("owner-notice-repeated=")
        })
    {
        return "sent".to_owned();
    }
    let status = output.status.code();
    let mark = if status.is_some() && keyed.is_some() {
        "unsent:"
    } else {
        state::NOTICE_UNANSWERED
    };
    let status = status.map_or_else(|| "signal".to_owned(), |code| code.to_string());
    let detail = keyed.map_or_else(|| stderr.trim().to_owned(), str::to_owned);
    format!("{mark}{VERB}: status={status} {detail}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::Request;

    /// The slice a unit is started in and the caps it copies, from the
    /// cgroup file the kernel writes and the cgroup's limit files: a pane
    /// under the agent warden's placement, a nested slice, a tmux service, a
    /// login session outside the user manager, another user's manager, a
    /// cgroup v1 line, a hybrid file and no file at all.
    #[test]
    fn a_unit_takes_the_slice_and_whole_number_caps_of_its_callers_cgroup() {
        let manager = "0::/user.slice/user-1000.slice/user@1000.service";
        for (text, want) in [
            (
                format!("{manager}/agents.slice/agent-confine-1-a.scope\n"),
                Some("agents.slice"),
            ),
            (
                format!("{manager}/agents.slice/agents-lane.slice/x.scope\n"),
                Some("agents-lane.slice"),
            ),
            (
                format!("{manager}/app.slice/tmux.service\n"),
                Some("app.slice"),
            ),
            (
                "0::/user.slice/user-1000.slice/session-4.scope\n".to_owned(),
                None,
            ),
            (
                "0::/user.slice/user-1000.slice/user@91000.service/agents.slice/x.scope\n"
                    .to_owned(),
                None,
            ),
            (
                "1:name=systemd:/user.slice/user-1000.slice/user@1000.service/agents.slice/x.scope\n"
                    .to_owned(),
                None,
            ),
            (
                format!("12:pids:/user.slice\n{manager}/agents.slice/x.scope\n"),
                Some("agents.slice"),
            ),
            (String::new(), None),
        ] {
            let slice = manager_cgroup(&text, "1000").and_then(|path| slice_of(&path));
            assert_eq!(slice.as_deref(), want, "{text:?}");
        }
        let dir = tempfile::tempdir().expect("tempdir");
        for (file, content, want) in [
            ("pids.max", Some("8192\n"), Some("8192")),
            ("memory.high", Some("68719476736\n"), Some("68719476736")),
            ("pids.max", Some("max\n"), None),
            ("memory.high", None, None),
        ] {
            let path = dir.path().join(file);
            let _ = std::fs::remove_file(&path);
            if let Some(content) = content {
                std::fs::write(&path, content).expect("limit file");
            }
            assert_eq!(cgroup_cap(dir.path(), file).as_deref(), want, "{file}");
        }
    }

    #[test]
    fn two_launches_from_one_process_get_two_unit_names() {
        let first = unit_name(
            "transfer",
            "request-transfer:overseer:1769700000123456789-4242",
        );
        let second = unit_name(
            "transfer",
            "request-transfer:overseer:1769700000987654321-77",
        );
        assert!(first.starts_with("orch-transfer-"), "{first}");
        assert_ne!(first, second);
        // A caller's own name reaches the unit only in what a unit name
        // can carry.
        assert_eq!(unit_name("a b/c", "7"), "orch-a_b_c-7");
    }

    /// The launcher's record names a unit or the setsid group the launcher
    /// read before it returned; a record that names
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
        // The launcher's ended status: a word settles the launch as nothing
        // started; `unwound-failed` holds the job.
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
        // The record keeps the leader of a group the launcher could not read
        // empty, and names that group.
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

    /// A launcher record ended
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
        let run = crate::effects::engine_run(
            &path,
            &settings,
            &env,
            state::Locking::FLOCK,
            &crate::schedule::SystemClock,
        );
        let group = Obligation::JobGroup(leader_identity.clone());
        // The leader lives: the record names the group, which stands.
        let mut operation =
            Operation::open(&run, &intent, Bootstrap::controller(intent.op).unwrap()).unwrap();
        operation.read_standing_jobs().unwrap();
        assert_eq!(operation.obligations.jobs(), vec![group.clone()]);
        // The leader exits; its member runs on in the group: still standing.
        let _ = leader.wait();
        assert_eq!(process::still_runs(&leader_identity), Reading::Gone);
        let current = read_intent(&path, id).unwrap();
        let mut operation =
            Operation::open(&run, &current, Bootstrap::controller(current.op).unwrap()).unwrap();
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
        let mut operation =
            Operation::open(&run, &current, Bootstrap::controller(current.op).unwrap()).unwrap();
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

    /// `systemd-run` refuses, before it sends anything, a variable whose name
    /// is outside shell syntax or whose value is not UTF-8 or holds a Unicode
    /// noncharacter, and every unit start handed one fails on every attempt.
    /// Every other value the client accepts and sends (measured on systemd
    /// 262): control characters, `=`, an empty value.
    #[test]
    fn an_environment_variable_a_unit_cannot_carry_is_never_handed_to_systemd_run() {
        use std::os::unix::ffi::OsStrExt;
        let text = std::ffi::OsStr::new;
        // (the name, the value, carried)
        for (name, value, carried) in [
            (text("GOOD"), text("1"), true),
            (text("_x9"), text(""), true),
            (text("GOOD"), text("a=b"), true),
            (text("GOOD"), text("v\t\n\r\u{1b}\u{7f}\u{85}w"), true),
            (text("GOOD"), text("v\u{FFFD}w"), true),
            (text("BASH_FUNC_x%%"), text("() {  :\n}"), false),
            (text("a.b"), text("1"), false),
            (text("a-b"), text("1"), false),
            (text("1abc"), text("1"), false),
            (text(""), text("1"), false),
            (text("GOOD"), std::ffi::OsStr::from_bytes(b"v\xffw"), false),
            (text("GOOD"), text("v\u{FDD0}w"), false),
            (text("GOOD"), text("v\u{FFFF}w"), false),
            (text("GOOD"), text("v\u{1FFFE}w"), false),
            (text("GOOD"), text("v\u{10FFFF}w"), false),
        ] {
            assert_eq!(
                unit_env(name, value).is_some(),
                carried,
                "{name:?}={value:?}"
            );
        }
    }

    /// The leader's identity names another start than the process now
    /// at that pid, which runs in this test's own group or leads a group of
    /// its own (its group the pid itself, as every `setsid` child, service
    /// and shell job does): the leader reads gone, and the group reads ended.
    #[test]
    fn a_group_whose_leader_reads_gone_is_read_by_its_members_never_by_a_process_that_took_its_pid()
    {
        // (the case, the program the pid-taker starts as, its arguments)
        for (case, program, args) in [
            ("in-this-group", "sleep", &["30"][..]),
            ("leads-its-own-group", "setsid", &["sleep", "30"][..]),
        ] {
            let mut taken = host::start_detached(
                "job",
                program,
                Path::new(program),
                "launch",
                args,
                host::Place::default(),
                None,
            )
            .expect("the program on PATH");
            let pid = taken.pid();
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            let leads = || {
                process::table()
                    .is_ok_and(|rows| rows.iter().any(|r| r.pid == pid && r.pgrp == pid))
            };
            while case == "leads-its-own-group" && !leads() && std::time::Instant::now() < deadline
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            let shape = leads() == (case == "leads-its-own-group");
            let leader = Identity {
                pid,
                start: "ticks:1".to_owned(),
            };
            let running = matches!(process::identity(pid), Reading::Live(_));
            let end = group_end(&leader);
            let _ = std::process::Command::new("kill")
                .args(["-KILL", &pid.to_string()])
                .status();
            let _ = taken.reap();
            assert!(running && shape, "{case}: a process holds the leader's pid");
            assert_eq!(end, Some(JobEnd::Exited), "{case}: the group reads ended");
        }
    }

    /// A clock whose waits pass no real time: each sleep moves it on.
    struct Stepping(std::sync::Mutex<std::time::Instant>);

    impl crate::schedule::Clock for Stepping {
        fn now(&self) -> std::time::Instant {
            *self.0.lock().unwrap()
        }
        fn wall(&self) -> std::time::SystemTime {
            std::time::SystemTime::now()
        }
        fn sleep(&self, d: Duration) {
            *self.0.lock().unwrap() += d;
        }
    }

    /// The stop names a start that is not the child's, so it signals nothing and the
    /// child runs on: the launch stops waiting once the KILL's grace has
    /// passed and holds the job by its group's key though that group reads
    /// empty, the child never having run its
    /// own `setsid`; the next read holds the job while the child runs and
    /// discharges it once the child has ended.
    #[test]
    fn a_child_its_launch_cannot_end_is_never_waited_for_and_holds_the_job_until_it_ends() {
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
        let id = "stop-controller:overseer:3:1-1";
        let record = state::job_record_path(dir.path(), id);
        std::fs::create_dir_all(record.parent().unwrap()).unwrap();
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
        let clock = Stepping(std::sync::Mutex::new(std::time::Instant::now()));
        let run = crate::effects::engine_run(&path, &settings, &env, state::Locking::FLOCK, &clock);
        let mut operation =
            Operation::open(&run, &intent, Bootstrap::controller(intent.op).unwrap()).unwrap();
        let mut child = host::start_detached(
            "job",
            "sleep",
            Path::new("sleep"),
            "launch",
            &["30"],
            host::Place::default(),
            None,
        )
        .expect("sleep on PATH");
        let pid = child.pid();
        let not_its_start = Identity {
            pid,
            start: "ticks:1".to_owned(),
        };
        let asked = std::time::Instant::now();
        Launcher {
            clock: operation.clock,
        }
        .end_child(&mut child, Some(&not_its_start));
        let waited = asked.elapsed();
        let running = matches!(process::identity(pid), Reading::Live(_));
        let launched = Launcher {
            clock: operation.clock,
        }
        .unwound(
            &record,
            "runner=setsid reason=fixture",
            "record-unwritable",
            None,
            Forked {
                pgid: pid,
                leader: None,
            },
        );
        operation
            .read_sidecar(&record, Some(launched.read.clone()))
            .unwrap();
        // The next read of the set, as a reconcile makes it.
        let next_read = || {
            let current = read_intent(&path, id).unwrap();
            let mut operation =
                Operation::open(&run, &current, Bootstrap::controller(current.op).unwrap())
                    .unwrap();
            operation.read_standing_jobs().unwrap();
            operation.obligations.jobs()
        };
        let held = next_read();
        let _ = std::process::Command::new("kill")
            .args(["-KILL", &pid.to_string()])
            .status();
        let _ = child.reap();
        let after_end = next_read();
        assert!(running, "the child runs on");
        assert!(waited < Duration::from_secs(5), "no wait on it: {waited:?}");
        assert_eq!(
            launched.read,
            SidecarRead::Present(JobHandle::Pgid(pid)),
            "the job held by its group's key"
        );
        assert_eq!(
            held,
            vec![Obligation::JobPgid { pgid: pid }],
            "the next read holds the job while the child runs"
        );
        assert!(after_end.is_empty(), "the child ended: {after_end:?}");
    }

    /// A launcher record ended `unwound-failed` with the group key alone,
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
        // names both, and exits at once.
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
        let run = crate::effects::engine_run(
            &path,
            &settings,
            &env,
            state::Locking::FLOCK,
            &crate::schedule::SystemClock,
        );
        let group = Obligation::JobPgid { pgid };
        // The record names the group by its key; the member runs: standing.
        let mut operation =
            Operation::open(&run, &intent, Bootstrap::controller(intent.op).unwrap()).unwrap();
        operation.read_standing_jobs().unwrap();
        assert_eq!(operation.obligations.jobs(), vec![group.clone()]);
        let current = read_intent(&path, id).unwrap();
        let mut operation =
            Operation::open(&run, &current, Bootstrap::controller(current.op).unwrap()).unwrap();
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
        let mut operation =
            Operation::open(&run, &current, Bootstrap::controller(current.op).unwrap()).unwrap();
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

    /// A failed outcome committed through the store
    /// alone, the state a crash between the outcome's write and the send
    /// leaves, records its notice `owed` with its fleet-log row and sends
    /// nothing. The next outcome of the same intent under the same owner,
    /// identical and so recorded nowhere, sends the owed notice once and
    /// marks it `sent`; a third changes nothing and sends nothing again.
    #[test]
    fn an_outcome_committed_without_its_send_owes_a_notice_the_next_outcome_sends_once() {
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
        crate::write_executable(
            &mail,
            format!(
                "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '{}'\n",
                calls.display()
            ),
        );
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
        let run = crate::effects::engine_run(
            &path,
            &settings,
            &env,
            state::Locking::FLOCK,
            &crate::schedule::SystemClock,
        );
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
        let operation =
            Operation::open(&run, &intent, Bootstrap::controller(intent.op).unwrap()).unwrap();
        let request = outcome(operation).wire();
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
        let retry =
            Operation::open(&run, &current, Bootstrap::controller(current.op).unwrap()).unwrap();
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
        let again =
            Operation::open(&run, &current, Bootstrap::controller(current.op).unwrap()).unwrap();
        super::super::apply_outcome(&run, outcome(again)).unwrap();
        send_owed_notices(&run).unwrap();
        assert_eq!(sent_calls(), 1, "a sent notice is never sent again");
    }

    /// A job's claim lands
    /// after the reconcile read the prior job ended and before the repeat
    /// launcher touches the job's files. The repeat's first owner-conditional
    /// write yields to the claimant, so the claimant's request and record
    /// stand untouched (the launch's own pre-write of the record never ran),
    /// its set is unchanged, and the claimant is named as the owner.
    #[test]
    fn a_claimed_repeat_keeps_the_claimants_files() {
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
        let run = crate::effects::engine_run(
            &path,
            &settings,
            &env,
            state::Locking::FLOCK,
            &crate::schedule::SystemClock,
        );
        let operation =
            Operation::open(&run, &intent, Bootstrap::controller(intent.op).unwrap()).unwrap();
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
    }

    /// A job's claim lands after the launcher's last loop read and before its `fail`;
    /// the launcher's outcome write yields to the claimant, so nothing is
    /// announced: the mailbox program is never run, the intent carries no
    /// notice, and the claimant's state is the answer.
    #[test]
    fn a_claimed_deadline_announces_nothing() {
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
        crate::write_executable(
            &mail,
            format!("#!/bin/bash\nprintf 'called' > '{}'\n", called.display()),
        );
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
        let run = crate::effects::engine_run(
            &path,
            &settings,
            &env,
            state::Locking::FLOCK,
            &crate::schedule::SystemClock,
        );
        let operation =
            Operation::open(&run, &intent, Bootstrap::controller(intent.op).unwrap()).unwrap();
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
