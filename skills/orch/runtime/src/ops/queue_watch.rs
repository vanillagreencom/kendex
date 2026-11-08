//! The merge-queue membership wait for one pull request, run as a job over
//! the item's record: each poll reads the pull request's state and its queue
//! entry, what earlier polls saw is written on the item before the next
//! poll, an unresolved review thread read while the pull request is queued
//! or armed pulls the arm (the github skill's `pr-threads` is the one thread
//! reader and its `merge-queue-mutation` the one sender of the disarm and
//! the dequeue), a failed required check on an armed, unenqueued pull request is
//! read through `verify-pr` within the budget the wait has left, and the
//! reply is the result object the merge workflow routes on its `verdict`
//! and `cause` words.
//!
//! The memory on the item is what separates an ejection from a pull request
//! that never entered the queue: a run that starts after another ended, or
//! after a crash between two polls, reads the membership the earlier polls
//! recorded instead of starting from nothing. The memory belongs to one head
//! and one arm: the first `autoMergeRequest.enabledAt` a poll reads is bound
//! to it, and a new head, or another `enabledAt` beside the bound one,
//! starts it afresh.
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use agent_runtime::host::{self, Place};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Env, Request, Verdict as CiVerdict, VerifyPr, verify_pr};
use crate::error::{Error, Result};
use crate::schedule::Clock;
use crate::state::{self, Document, Locking};
use crate::verify::wire::{CheckRunsPage, GraphError, GraphReply, Nullable, Optional, RunStatus};
use crate::verify::{self, Answer, Bucket, Budget, Gh, Status};

/// The github package's program under the project's install, whose
/// `pr-threads` reads the review threads.
const GITHUB_CLI_DEFAULT: &str = ".agents/skills/github/scripts/github.sh";
/// How long one `gh` or `github.sh` call is given.
const CALL_TIMEOUT: Duration = Duration::from_secs(120);
/// Polls within which a change of the queue entry or its check-run count
/// still reads as progress.
const PROGRESS_WINDOW_POLLS: u64 = 3;
/// Consecutive unreadable queue bodies before the wait ends on them.
const MAX_MALFORMED_POLLS: u64 = 3;
/// The transient backoff's cap, in poll intervals.
const RETRY_CAP_POLLS: u32 = 8;

// --- the record -----------------------------------------------------------------

const MEMORY_KEY: &str = "queue_watch";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordQueueWatch {
    pub memory: Memory,
}

/// What the polls of one pull request's head have seen, as the item holds
/// it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Memory {
    pub pr: u64,
    pub head: String,
    /// The arm the memory belongs to: `autoMergeRequest.enabledAt` where
    /// the pull request carries one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled_at: Option<String>,
    /// Any poll saw the pull request queued or armed.
    pub was_queued: bool,
    /// Any poll saw an actual queue entry.
    pub was_in_queue: bool,
    /// The late-findings guard's mutations, written owed before each is
    /// sent and settled after.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guard: Option<Guard>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Guard {
    pub threads: u64,
    pub disarm: Mutation,
    pub dequeue: Mutation,
}

/// One guard mutation's standing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum Mutation {
    /// The pull request's shape did not call for it.
    Unneeded,
    /// Written before the call; a crash leaves it here for the next run.
    Owed,
    Done,
    Failed {
        reason: String,
    },
}

impl Mutation {
    fn owed(&self) -> bool {
        matches!(self, Mutation::Owed)
    }

    fn failed(&self) -> bool {
        matches!(self, Mutation::Failed { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueWatchRecorded {
    pub pr: u64,
    pub was_queued: bool,
    pub was_in_queue: bool,
    /// False when no memory stood on the item.
    pub replaced: bool,
}

pub(super) fn record(doc: &mut Document, r: &RecordQueueWatch) -> Result<QueueWatchRecorded> {
    let replaced = !matches!(doc.get(MEMORY_KEY), None | Some(Value::Null));
    state::set(doc, MEMORY_KEY, serde_json::to_value(&r.memory)?);
    Ok(QueueWatchRecorded {
        pr: r.memory.pr,
        was_queued: r.memory.was_queued,
        was_in_queue: r.memory.was_in_queue,
        replaced,
    })
}

// --- the request and the reply --------------------------------------------------

#[derive(Debug, Clone)]
pub struct QueueWatch {
    pub repo: String,
    pub pr: u64,
    pub poll: Duration,
    pub max_wait: Duration,
    /// How long a pull request no poll has seen queued or armed is polled
    /// before `not_queued`: enqueue registration lags the merge call.
    pub arm_grace: Duration,
    /// Consecutive polls a `conflicting`, `ejected` or `disarmed` reading
    /// must hold before it ends the wait.
    pub confirm_polls: u32,
    /// The least time between two guard probes and between two
    /// failed-check probes, each on its own clock.
    pub probe_interval: Duration,
    pub check_probe: bool,
    pub guard: bool,
}

/// The programs the wait runs: `gh` on `PATH` and the github package's
/// `github.sh` in production.
#[derive(Debug, Clone)]
pub struct Programs {
    pub gh: PathBuf,
    pub github: PathBuf,
}

impl Programs {
    pub fn installed(project: &Path) -> Programs {
        Programs {
            gh: PathBuf::from("gh"),
            github: project.join(GITHUB_CLI_DEFAULT),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Complete,
    Timeout,
    Error,
}

impl Outcome {
    fn word(self) -> &'static str {
        match self {
            Outcome::Complete => "complete",
            Outcome::Timeout => "timeout",
            Outcome::Error => "error",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Verdict {
    Merged,
    Conflicting,
    Ejected,
    Disarmed,
    ArmedBlocked,
    Dequeued,
    Closed,
    Queued,
    ArmedAwaitingChecks,
    NotQueued,
    Unknown,
}

impl Verdict {
    fn word(self) -> &'static str {
        match self {
            Verdict::Merged => "merged",
            Verdict::Conflicting => "conflicting",
            Verdict::Ejected => "ejected",
            Verdict::Disarmed => "disarmed",
            Verdict::ArmedBlocked => "armed_blocked",
            Verdict::Dequeued => "dequeued",
            Verdict::Closed => "closed",
            Verdict::Queued => "queued",
            Verdict::ArmedAwaitingChecks => "armed_awaiting_checks",
            Verdict::NotQueued => "not_queued",
            Verdict::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cause {
    BaseConflict,
    MergeGroupFailed,
    CheckFailed,
    NotMergeable,
    AutoMergeCleared,
    NeverArmed,
    ClosedWithoutMerge,
    LateFindings,
    LateFindingsDequeueFailed,
    StillProgressing,
    Stalled,
    BlockedByEntryAhead,
    ProgressUnobservable,
    ExitUnconfirmed,
    ChecksPending,
    ChecksUnread,
}

impl Cause {
    fn word(self) -> &'static str {
        match self {
            Cause::BaseConflict => "base_conflict",
            Cause::MergeGroupFailed => "merge_group_failed",
            Cause::CheckFailed => "check_failed",
            Cause::NotMergeable => "not_mergeable",
            Cause::AutoMergeCleared => "auto_merge_cleared",
            Cause::NeverArmed => "never_armed",
            Cause::ClosedWithoutMerge => "closed_without_merge",
            Cause::LateFindings => "late_findings",
            Cause::LateFindingsDequeueFailed => "late_findings_dequeue_failed",
            Cause::StillProgressing => "still_progressing",
            Cause::Stalled => "stalled",
            Cause::BlockedByEntryAhead => "blocked_by_entry_ahead",
            Cause::ProgressUnobservable => "progress_unobservable",
            Cause::ExitUnconfirmed => "exit_unconfirmed",
            Cause::ChecksPending => "checks_pending",
            Cause::ChecksUnread => "checks_unread",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Reply {
    pub status: &'static str,
    pub verdict: &'static str,
    pub repo: String,
    pub elapsed_seconds: u64,
    pub polls: u64,
    pub pr_state: String,
    pub merged_at: String,
    pub in_merge_queue: bool,
    pub merge_queue_state: String,
    pub auto_merge_enabled: bool,
    pub was_queued: bool,
    pub was_in_merge_queue: bool,
    /// `null` where progress was never observable.
    pub progressing: Option<bool>,
    pub progress_head_polls: u64,
    pub progress_check_reads: u64,
    pub last_running_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cause: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unconfirmed_verdict: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub queue_ahead_pr: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_checks: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unresolved_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_poll_age_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transient_api_errors: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

// --- the reads ------------------------------------------------------------------

/// What one program call answered.
enum Call {
    Printed(Vec<u8>),
    /// `stdout` is what the failed call printed: gh prints a GraphQL
    /// `errors` body there beside its stderr line.
    Failed {
        transient: bool,
        detail: String,
        stdout: Vec<u8>,
    },
}

/// A failure the service or the transport caused, which the budget absorbs;
/// anything else (an HTTP 404, 401 or 403, a malformed argument) ends the
/// wait. `status` is the reply's HTTP status as gh wrote it last; with none,
/// a status named in the text is read.
fn transient(text: &str, status: Option<u16>) -> bool {
    let lower = text.to_ascii_lowercase();
    let by_status = match status {
        Some(code) => (500..600).contains(&code) || code == 429,
        None => text.contains("HTTP 5") || text.contains("HTTP 429"),
    };
    by_status
        || [
            "timeout",
            "timed out",
            "context deadline exceeded",
            "connection refused",
            "connection reset",
            "network is unreachable",
            "no such host",
            "could not resolve",
            "temporary failure",
            "unexpected eof",
            "tls handshake",
            "rate limit",
            "abuse detection",
        ]
        .iter()
        .any(|needle| lower.contains(needle))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the queue wait's reads of the review threads through the github package, no effect on a lane or a controller; the guard's two mutations are recorded owed on the item before they are sent"
)]
fn call(
    program: &'static str,
    executable: &Path,
    operation: &'static str,
    args: &[&str],
    place: Place,
) -> Call {
    let output = match host::run_tagged_in(
        "queue-watch",
        program,
        executable,
        operation,
        args,
        place,
        CALL_TIMEOUT,
    ) {
        Ok(output) => output,
        Err(e) => {
            let detail = e.to_string();
            return Call::Failed {
                transient: transient(&detail, None),
                detail,
                stdout: Vec::new(),
            };
        }
    };
    if output.status.success() {
        return Call::Printed(output.stdout);
    }
    let detail = [host::stderr_text(&output), host::stdout_text(&output)]
        .into_iter()
        .map(|text| text.trim().to_owned())
        .find(|text| !text.is_empty())
        .unwrap_or_else(|| format!("exit status {}", output.status));
    Call::Failed {
        transient: transient(&detail, None),
        detail,
        stdout: output.stdout,
    }
}

#[derive(Deserialize)]
struct PullView {
    state: String,
    #[serde(default, rename = "mergedAt")]
    merged_at: Option<String>,
    #[serde(default)]
    mergeable: Option<String>,
    #[serde(rename = "headRefOid")]
    head: String,
}

#[derive(Deserialize)]
struct QueueData {
    #[serde(default)]
    repository: Option<QueueRepository>,
}

#[derive(Deserialize)]
struct QueueRepository {
    #[serde(default, rename = "pullRequest")]
    pull_request: Option<QueuePull>,
}

#[derive(Deserialize)]
struct QueuePull {
    #[serde(default)]
    id: Option<String>,
    #[serde(default, rename = "mergeQueueEntry")]
    entry: Option<QueueEntry>,
    #[serde(default, rename = "autoMergeRequest")]
    auto_merge: Option<AutoMerge>,
}

#[derive(Deserialize)]
struct QueueEntry {
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    position: Option<i64>,
    #[serde(default, rename = "headCommit")]
    head: Option<Oid>,
    #[serde(default, rename = "mergeQueue")]
    queue: Option<MergeQueue>,
}

#[derive(Deserialize)]
struct Oid {
    #[serde(default)]
    oid: Option<String>,
}

#[derive(Deserialize)]
struct MergeQueue {
    #[serde(default)]
    entries: Option<Entries>,
}

#[derive(Deserialize)]
struct Entries {
    #[serde(default)]
    nodes: Vec<SiblingEntry>,
}

#[derive(Deserialize)]
struct SiblingEntry {
    #[serde(default)]
    position: Option<i64>,
    #[serde(default, rename = "headCommit")]
    head: Option<Oid>,
    #[serde(default, rename = "pullRequest")]
    pull_request: Option<SiblingPull>,
}

#[derive(Deserialize)]
struct SiblingPull {
    #[serde(default)]
    number: Option<u64>,
}

#[derive(Deserialize)]
struct AutoMerge {
    #[serde(default, rename = "enabledAt")]
    enabled_at: Option<String>,
}

#[derive(Deserialize)]
struct Threads {
    unresolved_count: u64,
}

/// A GraphQL string literal: a GitHub name or node id, or a reply the loop
/// refuses to inline.
fn literal(text: &str) -> Option<String> {
    text.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '='))
        .then(|| format!("\"{text}\""))
}

/// What the queue read said about the pull request this poll.
#[derive(Debug, Clone)]
struct QueueRead {
    node_id: Option<String>,
    in_queue: bool,
    queue_state: String,
    auto_merge: bool,
    enabled_at: Option<String>,
    entry_position: Option<i64>,
    entry_head: Option<String>,
    /// The live group ahead of a headless `QUEUED` or `UNMERGEABLE` entry.
    ahead: Option<u64>,
}

impl QueueRead {
    fn of(pull: QueuePull) -> QueueRead {
        // GitHub answers an entry exactly while the pull request is in the
        // queue, so the entry is membership's one reading.
        let in_queue = pull.entry.is_some();
        let (queue_state, position, head, ahead) = match pull.entry {
            None => (String::new(), None, None, None),
            Some(entry) => {
                let state = entry.state.unwrap_or_default();
                let position = entry.position;
                let head = entry.head.and_then(|h| h.oid);
                let headless_hold =
                    matches!(state.as_str(), "QUEUED" | "UNMERGEABLE") && head.is_none();
                let ahead = if headless_hold {
                    entry
                        .queue
                        .and_then(|q| q.entries)
                        .map(|e| e.nodes)
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|n| {
                            n.position.zip(position).is_some_and(|(p, mine)| p < mine)
                                && n.head.as_ref().is_some_and(|h| h.oid.is_some())
                        })
                        .min_by_key(|n| n.position)
                        .and_then(|n| n.pull_request.and_then(|p| p.number))
                } else {
                    None
                };
                (state, position, head, ahead)
            }
        };
        QueueRead {
            node_id: pull.id,
            in_queue,
            queue_state,
            auto_merge: pull.auto_merge.is_some(),
            enabled_at: pull.auto_merge.and_then(|a| a.enabled_at),
            entry_position: position,
            entry_head: head,
            ahead,
        }
    }

    fn armed(&self) -> bool {
        self.in_queue || self.auto_merge
    }
}

/// How a poll's read ended short of a reading.
enum ReadEnd {
    /// Absorbed under the backoff; the key names the read.
    Transient(&'static str, String),
    /// The wait ends with this key and detail.
    Terminal(&'static str, String),
    /// The queue body was no pull request; absorbed up to the bound.
    Malformed,
}

/// What the failed-check probe last read, in `verify-pr`'s terms.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ProbeRead {
    /// No readable answer yet.
    None,
    /// A check running, not registered, or missing, with their names.
    Pending(Vec<String>),
    /// Every required check passed, or no CI runs.
    Settled,
}

/// The candidate verdicts the confirmation count gates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Candidate {
    Conflicting,
    Ejected,
    Disarmed,
}

impl Candidate {
    fn verdict(self) -> Verdict {
        match self {
            Candidate::Conflicting => Verdict::Conflicting,
            Candidate::Ejected => Verdict::Ejected,
            Candidate::Disarmed => Verdict::Disarmed,
        }
    }

    fn cause(self) -> Cause {
        match self {
            Candidate::Conflicting => Cause::BaseConflict,
            Candidate::Ejected => Cause::MergeGroupFailed,
            Candidate::Disarmed => Cause::AutoMergeCleared,
        }
    }
}

// --- the wait -------------------------------------------------------------------

struct Wait<'a> {
    path: &'a Path,
    r: &'a QueueWatch,
    programs: &'a Programs,
    project: &'a Path,
    clock: &'a dyn Clock,
    env: &'a Env,
    locking: Locking,
    owner: String,
    name: String,
    start: Instant,
    polls: u64,
    last_poll_at: Option<Instant>,
    pr_state: String,
    merged_at: String,
    mergeable: String,
    /// The queue read of the last successful poll.
    queue: Option<QueueRead>,
    memory: Option<Memory>,
    /// The memory as last written, so a poll that changes nothing writes
    /// nothing.
    written: Option<Memory>,
    unresolved: Option<u64>,
    transient_errors: u64,
    retry: Duration,
    malformed_polls: u64,
    // The progress signal.
    prev_tuple: Option<String>,
    prev_count: Option<usize>,
    prev_head: Option<String>,
    last_running: Option<u64>,
    last_change_poll: Option<u64>,
    progress_evidence: bool,
    head_polls: u64,
    check_reads: u64,
    // The guard and the probe, each on its own clock.
    guard_at: Option<Instant>,
    probe_at: Option<Instant>,
    probe: ProbeRead,
    // The confirmation.
    candidate: Option<Candidate>,
    candidate_count: u32,
    squeezes: u32,
}

/// What a poll decided.
enum Step {
    /// The wait ends with this reply.
    End(Box<Reply>),
    /// Sleep this long, then poll again.
    Sleep(Duration),
}

fn end(reply: Reply) -> Step {
    Step::End(Box::new(reply))
}

impl<'a> Wait<'a> {
    #[allow(
        clippy::disallowed_methods,
        reason = "the wait's clock reads: elapsed time against the budget, the probe clocks and the poll age, all through the one injected clock"
    )]
    fn elapsed(&self) -> Duration {
        self.clock.now().duration_since(self.start)
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the wait's clock reads: elapsed time against the budget, the probe clocks and the poll age, all through the one injected clock"
    )]
    fn since(&self, at: Instant) -> Duration {
        self.clock.now().duration_since(at)
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the wait's clock reads: elapsed time against the budget, the probe clocks and the poll age, all through the one injected clock"
    )]
    fn now(&self) -> Instant {
        self.clock.now()
    }

    fn remaining(&self) -> Duration {
        self.r.max_wait.saturating_sub(self.elapsed())
    }

    fn gh(&self, operation: &'static str, args: &[&str]) -> Call {
        let answer = Gh::new(&self.programs.gh)
            .tagged("queue-watch")
            .bounded(CALL_TIMEOUT)
            .run(operation, args, None);
        match answer {
            Ok(Answer::Printed { stdout, .. }) => Call::Printed(stdout),
            Ok(Answer::Failed(failed)) => {
                let detail = failed.detail();
                Call::Failed {
                    transient: transient(&detail, failed.http()),
                    detail,
                    stdout: failed.stdout,
                }
            }
            Err(unrun) => {
                let detail = unrun.detail();
                Call::Failed {
                    transient: transient(&detail, None),
                    detail,
                    stdout: Vec::new(),
                }
            }
        }
    }

    /// The memory for `head` and the arm `enabled_at` this poll read: the
    /// recorded one where it belongs to the same head and arm, else a fresh
    /// one. A memory no arm is bound to yet takes the first one read, so a
    /// later arm under another timestamp is a new wait; a poll that reads
    /// no arm keeps the bound one, so an arm GitHub cleared is still
    /// remembered.
    fn memory_for(&self, head: &str, enabled_at: Option<&str>) -> Memory {
        if let Some(m) = &self.memory
            && m.pr == self.r.pr
            && m.head == head
        {
            match (enabled_at, m.enabled_at.as_deref()) {
                (Some(live), Some(bound)) if live != bound => {}
                (Some(live), None) => {
                    return Memory {
                        enabled_at: Some(live.to_owned()),
                        ..m.clone()
                    };
                }
                (_, _) => return m.clone(),
            }
        }
        Memory {
            pr: self.r.pr,
            head: head.to_owned(),
            enabled_at: enabled_at.map(str::to_owned),
            was_queued: false,
            was_in_queue: false,
            guard: None,
        }
    }

    /// Write the memory on the item where it differs from what stands.
    #[allow(
        clippy::disallowed_methods,
        reason = "the queue wait's one store call: its memory recorded through the one dispatcher before the next poll"
    )]
    fn write_memory(&mut self, memory: Memory) -> Result<()> {
        if self.written.as_ref() != Some(&memory) {
            let request = Request::RecordQueueWatch(RecordQueueWatch {
                memory: memory.clone(),
            });
            super::apply(self.path, &request, self.env, self.locking)?;
            self.written = Some(memory.clone());
        }
        self.memory = Some(memory);
        Ok(())
    }

    fn memory_ref(&self) -> &Memory {
        self.memory.as_ref().expect("the poll wrote the memory")
    }

    fn progressing(&self) -> Option<bool> {
        if self
            .last_change_poll
            .is_some_and(|at| self.polls.saturating_sub(at) < PROGRESS_WINDOW_POLLS)
            || self.last_running.is_some_and(|n| n > 0)
        {
            Some(true)
        } else if self.progress_evidence {
            Some(false)
        } else {
            None
        }
    }

    fn reply(&self, status: Outcome, verdict: Verdict, cause: Option<Cause>) -> Reply {
        let progressing = self.progressing();
        let queue = self.queue.as_ref();
        let in_queue = queue.is_some_and(|q| q.in_queue);
        let ahead = queue.and_then(|q| q.ahead);
        let cause = if verdict == Verdict::Queued {
            Some(if !in_queue {
                Cause::ExitUnconfirmed
            } else if ahead.is_some() {
                Cause::BlockedByEntryAhead
            } else {
                match progressing {
                    Some(true) => Cause::StillProgressing,
                    Some(false) => Cause::Stalled,
                    None => Cause::ProgressUnobservable,
                }
            })
        } else {
            cause
        };
        let unconfirmed = (status == Outcome::Timeout)
            .then_some(self.candidate)
            .flatten()
            .map(|c| c.verdict().word());
        let pending = match (&verdict, &cause, &self.probe) {
            (
                Verdict::ArmedAwaitingChecks,
                Some(Cause::ChecksPending),
                ProbeRead::Pending(names),
            ) => Some(names.clone()),
            _ => None,
        };
        let memory = self.memory.as_ref();
        Reply {
            status: status.word(),
            verdict: verdict.word(),
            repo: self.r.repo.clone(),
            elapsed_seconds: self.elapsed().as_secs(),
            polls: self.polls,
            pr_state: self.pr_state.clone(),
            merged_at: self.merged_at.clone(),
            in_merge_queue: in_queue,
            merge_queue_state: queue.map(|q| q.queue_state.clone()).unwrap_or_default(),
            auto_merge_enabled: queue.is_some_and(|q| q.auto_merge),
            was_queued: memory.is_some_and(|m| m.was_queued),
            was_in_merge_queue: memory.is_some_and(|m| m.was_in_queue),
            progressing,
            progress_head_polls: self.head_polls,
            progress_check_reads: self.check_reads,
            last_running_count: self.last_running,
            cause: cause.map(Cause::word),
            unconfirmed_verdict: unconfirmed,
            queue_ahead_pr: ahead,
            pending_checks: pending,
            unresolved_count: self.unresolved,
            last_poll_age_seconds: self.last_poll_at.map(|at| self.since(at).as_secs()),
            transient_api_errors: (self.transient_errors > 0).then_some(self.transient_errors),
            error: None,
        }
    }

    fn error(&self, key: &str, detail: &str) -> Reply {
        let mut reply = self.reply(Outcome::Error, Verdict::Unknown, None);
        reply.error = Some(
            format!("{key} pr={} repo={} {detail}", self.r.pr, self.r.repo)
                .trim_end()
                .to_owned(),
        );
        reply
    }

    // --- the reads per poll ---

    fn read_pull(&mut self) -> std::result::Result<PullView, ReadEnd> {
        let number = self.r.pr.to_string();
        let args = [
            "pr",
            "view",
            &number,
            "--repo",
            &self.r.repo,
            "--json",
            "state,mergedAt,mergeable,headRefOid",
        ];
        match self.gh("pr", &args) {
            Call::Printed(bytes) => serde_json::from_slice::<PullView>(&bytes)
                .map_err(|_| ReadEnd::Terminal("pr-view-failed", "unreadable answer".to_owned())),
            Call::Failed {
                transient: true,
                detail,
                ..
            } => Err(ReadEnd::Transient("pr-view-failed", detail)),
            Call::Failed {
                transient: false,
                detail,
                ..
            } => Err(ReadEnd::Terminal("pr-view-failed", detail)),
        }
    }

    fn read_queue(&mut self) -> std::result::Result<QueueRead, ReadEnd> {
        let query = format!(
            "query {{ repository(owner: {}, name: {}) {{ pullRequest(number: {}) {{ id mergeQueueEntry {{ state position headCommit {{ oid }} mergeQueue {{ entries(first: 100) {{ nodes {{ position headCommit {{ oid }} pullRequest {{ number }} }} }} }} }} autoMergeRequest {{ enabledAt }} }} }} }}",
            self.owner, self.name, self.r.pr
        );
        let query = format!("query={query}");
        let bytes = match self.gh("api", &["api", "graphql", "-f", &query]) {
            Call::Printed(bytes) => bytes,
            Call::Failed {
                transient: true,
                detail,
                ..
            } => {
                return Err(ReadEnd::Transient("queue-fetch-failed", detail));
            }
            // A GraphQL `errors` reply exits nonzero with its body printed.
            Call::Failed {
                transient: false,
                stdout,
                ..
            } => {
                return Err(
                    match serde_json::from_slice::<GraphReply<QueueData>>(&stdout) {
                        Ok(reply) if errors_present(&reply.errors) => {
                            ReadEnd::Terminal("queue-rejected", messages(&reply.errors))
                        }
                        _ => ReadEnd::Malformed,
                    },
                );
            }
        };
        let Ok(reply) = serde_json::from_slice::<GraphReply<QueueData>>(&bytes) else {
            return Err(ReadEnd::Malformed);
        };
        if errors_present(&reply.errors) {
            return Err(ReadEnd::Terminal("queue-rejected", messages(&reply.errors)));
        }
        let data = match reply.data {
            Nullable::Present(data) => Some(data),
            Nullable::Absent | Nullable::Null => None,
        };
        data.and_then(|d| d.repository)
            .and_then(|r| r.pull_request)
            .map(QueueRead::of)
            .ok_or(ReadEnd::Malformed)
    }

    /// The completed and not-completed check-run counts on the merge-group
    /// head `sha`, or `None` where any page could not be read or the pages
    /// fall short of their total: an unknown count is never zero.
    fn check_run_counts(&self, sha: &str) -> Option<(usize, u64)> {
        let path = format!("repos/{}/commits/{sha}/check-runs", self.r.repo);
        let runs = verify::collection(
            &path,
            |page| match self.gh("api", &["api", page]) {
                Call::Printed(bytes) => {
                    serde_json::from_slice::<CheckRunsPage>(&bytes).map_err(|_| ())
                }
                Call::Failed { .. } => Err(()),
            },
            || (),
        )
        .ok()?;
        let completed = runs
            .iter()
            .filter(|run| run.status == RunStatus::Completed)
            .count();
        Some((completed, (runs.len() - completed) as u64))
    }

    fn observe_progress(&mut self, queue: &QueueRead) {
        let tuple = format!(
            "{}|{}|{}",
            queue.queue_state,
            queue
                .entry_position
                .map(|p| p.to_string())
                .unwrap_or_default(),
            queue.entry_head.clone().unwrap_or_default()
        );
        if queue.entry_head != self.prev_head {
            self.last_running = None;
            self.prev_count = None;
        }
        let mut count = None;
        if let Some(head) = &queue.entry_head {
            self.head_polls += 1;
            if let Some((completed, running)) = self.check_run_counts(head) {
                count = Some(completed);
                self.check_reads += 1;
                self.last_running = Some(running);
                self.progress_evidence = true;
            }
        }
        let mut changed = false;
        if let Some(prev) = &self.prev_tuple {
            changed |= *prev != tuple;
            if let (Some(c), Some(p)) = (count, self.prev_count) {
                changed |= c != p;
            }
        }
        if changed {
            self.progress_evidence = true;
            self.last_change_poll = Some(self.polls);
        }
        self.prev_tuple = Some(tuple);
        if count.is_some() {
            self.prev_count = count;
        }
        self.prev_head = queue.entry_head.clone();
    }

    // --- the guard ---

    /// The unresolved thread count through the github package, or `None`
    /// where the read failed: no evidence is never no threads.
    fn unresolved_threads(&self) -> Option<u64> {
        let number = self.r.pr.to_string();
        let repo = std::ffi::OsStr::new(&self.r.repo);
        let place = Place {
            cwd: Some(self.project),
            env: &[("GH_REPO", repo)],
        };
        match call(
            "github",
            &self.programs.github,
            "pr-threads",
            &["pr-threads", &number, "--unresolved"],
            place,
        ) {
            Call::Printed(bytes) => serde_json::from_slice::<Threads>(&bytes)
                .ok()
                .map(|t| t.unresolved_count),
            Call::Failed { .. } => None,
        }
    }

    /// One guard mutation through the github package's
    /// `merge-queue-mutation`, which owns the mutation's form and judges it
    /// on its body; a refusal's reason is what it printed.
    fn mutate(&self, what: &'static str, node_id: &str) -> std::result::Result<(), String> {
        let repo = std::ffi::OsStr::new(&self.r.repo);
        let place = Place {
            cwd: Some(self.project),
            env: &[("GH_REPO", repo)],
        };
        match call(
            "github",
            &self.programs.github,
            "merge-queue-mutation",
            &["merge-queue-mutation", what, node_id],
            place,
        ) {
            Call::Printed(_) => Ok(()),
            Call::Failed { detail, stdout, .. } => {
                let printed = String::from_utf8_lossy(&stdout).trim().to_owned();
                Err(if printed.is_empty() {
                    detail.chars().take(200).collect()
                } else {
                    printed
                })
            }
        }
    }

    /// Pull the arm on `threads` unresolved review threads: the disarm
    /// before the dequeue (an armed pull request re-enqueues itself the
    /// moment its requirements go green), each half recorded owed on the
    /// item before it is sent and settled after.
    fn guard_fire(&mut self, threads: u64) -> Result<Reply> {
        self.unresolved = Some(threads);
        let (node_id, auto_merge, in_queue) = match &self.queue {
            Some(q) => (q.node_id.clone(), q.auto_merge, q.in_queue),
            None => (None, false, false),
        };
        let standing = self.memory_ref().guard.clone();
        // The live read decides a half: one an earlier run landed and the
        // pull request's shape calls for again (armed or queued since) is
        // owed again, never read as done.
        let half = |needed: bool, earlier: Option<&Mutation>| match earlier {
            _ if needed => Mutation::Owed,
            Some(Mutation::Done) => Mutation::Done,
            _ => Mutation::Unneeded,
        };
        let mut guard = Guard {
            threads,
            disarm: half(auto_merge, standing.as_ref().map(|g| &g.disarm)),
            dequeue: half(in_queue, standing.as_ref().map(|g| &g.dequeue)),
        };
        let mut memory = self.memory_ref().clone();
        memory.guard = Some(guard.clone());
        self.write_memory(memory)?;
        let Some(node_id) = node_id else {
            guard.disarm = Mutation::Failed {
                reason: "missing-pr-id".to_owned(),
            };
            return self.guard_settle(guard);
        };
        if guard.disarm.owed() {
            guard.disarm = match self.mutate("disablePullRequestAutoMerge", &node_id) {
                Ok(()) => Mutation::Done,
                Err(reason) => Mutation::Failed { reason },
            };
        }
        if guard.dequeue.owed() {
            guard.dequeue = match self.mutate("dequeuePullRequest", &node_id) {
                Ok(()) => Mutation::Done,
                Err(reason) => Mutation::Failed { reason },
            };
        }
        self.guard_settle(guard)
    }

    fn guard_settle(&mut self, guard: Guard) -> Result<Reply> {
        let failed: Vec<&str> = [
            ("disablePullRequestAutoMerge", &guard.disarm),
            ("dequeuePullRequest", &guard.dequeue),
        ]
        .into_iter()
        .filter(|(_, m)| m.failed())
        .map(|(name, _)| name)
        .collect();
        let mut memory = self.memory_ref().clone();
        memory.guard = Some(guard);
        self.write_memory(memory)?;
        if failed.is_empty() {
            return Ok(self.reply(
                Outcome::Complete,
                Verdict::Dequeued,
                Some(Cause::LateFindings),
            ));
        }
        let mut reply = self.reply(
            Outcome::Error,
            Verdict::Dequeued,
            Some(Cause::LateFindingsDequeueFailed),
        );
        reply.error = Some(format!(
            "guard-failed operation={} pr={} threads={} still-armed=possible",
            failed.join(" and "),
            self.r.pr,
            self.unresolved.unwrap_or_default()
        ));
        Ok(reply)
    }

    /// One guard probe: a thread count fires the guard; a failed read is no
    /// evidence and the wait goes on.
    fn guard_probe(&mut self) -> Result<Option<Reply>> {
        let Some(count) = self.unresolved_threads() else {
            return Ok(None);
        };
        self.unresolved = Some(count);
        if count == 0 {
            return Ok(None);
        }
        self.guard_fire(count).map(Some)
    }

    /// A guard a crashed run left owed: the live arm and a fresh thread read
    /// settle it. Still armed or queued, the threads are read again: none
    /// left settles the owed halves unneeded and the wait goes on, some are
    /// pulled on that count, and an unread count leaves the halves owed for
    /// the next poll; gone, the guard landed and the verdict is the one that
    /// run owed.
    fn resume_guard(&mut self, queue: &QueueRead) -> Result<Option<Reply>> {
        let Some(guard) = self.memory_ref().guard.clone() else {
            return Ok(None);
        };
        if !guard.disarm.owed() && !guard.dequeue.owed() {
            return Ok(None);
        }
        if queue.armed() {
            return match self.unresolved_threads() {
                None => Ok(None),
                Some(0) => {
                    self.unresolved = Some(0);
                    self.guard_at = Some(self.now());
                    let unneeded = |half: Mutation| {
                        if half.owed() {
                            Mutation::Unneeded
                        } else {
                            half
                        }
                    };
                    let mut memory = self.memory_ref().clone();
                    memory.guard = Some(Guard {
                        threads: 0,
                        disarm: unneeded(guard.disarm),
                        dequeue: unneeded(guard.dequeue),
                    });
                    self.write_memory(memory)?;
                    Ok(None)
                }
                Some(threads) => self.guard_fire(threads).map(Some),
            };
        }
        self.unresolved = Some(guard.threads);
        let settled = Guard {
            threads: guard.threads,
            disarm: if guard.disarm.owed() {
                Mutation::Done
            } else {
                guard.disarm
            },
            dequeue: if guard.dequeue.owed() {
                Mutation::Done
            } else {
                guard.dequeue
            },
        };
        self.guard_settle(settled).map(Some)
    }

    // --- the probe ---

    /// What a probe may spend: up to the wait's deadline less the poll
    /// after it, so the probe's reads end where that poll is still owed;
    /// none once that cutoff has passed. The cutoff is counted from the
    /// wait's start, never from a later clock read, so time passing
    /// between two reads cannot carry it later.
    fn probe_budget(&self) -> Option<Budget<'a>> {
        let cutoff = self.start + (self.r.max_wait - self.r.poll);
        (self.now() < cutoff).then(|| Budget::until(self.clock, cutoff))
    }

    /// One `verify-pr` read of the pull request's own required checks
    /// within `budget`: only a complete `fail` ends the wait; `pending` and
    /// the settled words are recorded for the deadline verdict; an
    /// unreadable answer, a refusal or an answer that arrived past the
    /// budget is no reading and leaves the last one standing.
    fn probe_failed_check(&mut self, budget: Budget<'a>) -> bool {
        let request = VerifyPr {
            repo: self.r.repo.clone(),
            pr: self.r.pr,
            required_only: true,
        };
        let Ok(verified) = verify_pr::run_with(
            self.path,
            &request,
            &Gh::within(&self.programs.gh, budget),
            self.env,
            self.locking,
        ) else {
            return false;
        };
        match verified.status {
            Status::Unreadable => false,
            Status::Pending => {
                let names = verified
                    .checks
                    .iter()
                    .filter(|c| c.bucket == Bucket::Pending)
                    .map(|c| c.name.clone())
                    .collect();
                self.probe = ProbeRead::Pending(names);
                false
            }
            Status::Complete => match verified.verdict.as_deref().and_then(CiVerdict::parse) {
                Some(CiVerdict::Fail) => true,
                Some(CiVerdict::Pass | CiVerdict::None) => {
                    self.probe = ProbeRead::Settled;
                    false
                }
                None => false,
            },
        }
    }

    // --- the confirmation ---

    fn note_candidate(&mut self, candidate: Candidate) {
        if self.candidate == Some(candidate) {
            self.candidate_count += 1;
        } else {
            self.candidate = Some(candidate);
            self.candidate_count = 1;
            self.squeezes = 0;
        }
    }

    /// The gap before the next poll: the interval, shortened while a
    /// candidate still owes confirmation polls the remaining budget cannot
    /// fit at the interval, at most `confirm_polls - 1` times per candidate.
    /// The divisor is one slot more than the polls owed, since a gap landing
    /// on the deadline leaves that poll unmade.
    fn next_gap(&mut self) -> Duration {
        let Some(_) = self.candidate else {
            return self.r.poll;
        };
        let need = self.r.confirm_polls.saturating_sub(self.candidate_count);
        if need == 0 || self.squeezes + 1 >= self.r.confirm_polls {
            return self.r.poll;
        }
        let remaining = self.remaining();
        if remaining.is_zero() || self.r.poll * need < remaining {
            return self.r.poll;
        }
        self.squeezes += 1;
        remaining / (need + 1)
    }

    fn sleep_within_budget(&mut self, want: Duration) -> Step {
        Step::Sleep(want.min(self.remaining()))
    }

    /// Absorb one transient failure under the backoff, or end the wait on
    /// it once the budget is spent.
    fn transient_retry(&mut self, key: &str, detail: &str) -> Step {
        self.transient_errors += 1;
        if self.elapsed() >= self.r.max_wait {
            return end(self.error(key, detail));
        }
        let gap = self.retry;
        self.retry = (self.retry * 2).min(self.r.poll * RETRY_CAP_POLLS);
        self.sleep_within_budget(gap)
    }

    // --- one poll ---

    fn poll(&mut self) -> Result<Step> {
        self.polls += 1;
        let pull = match self.read_pull() {
            Ok(pull) => pull,
            Err(ReadEnd::Transient(key, detail)) => return Ok(self.transient_retry(key, &detail)),
            Err(ReadEnd::Terminal(key, detail)) => return Ok(end(self.error(key, &detail))),
            Err(ReadEnd::Malformed) => {
                return Ok(end(self.error("pr-view-failed", "unreadable answer")));
            }
        };
        self.pr_state = pull.state.clone();
        self.merged_at = pull.merged_at.clone().unwrap_or_default();
        self.mergeable = pull.mergeable.clone().unwrap_or_default();
        match pull.state.as_str() {
            "MERGED" => return Ok(end(self.reply(Outcome::Complete, Verdict::Merged, None))),
            "CLOSED" => {
                return Ok(end(self.reply(
                    Outcome::Complete,
                    Verdict::Closed,
                    Some(Cause::ClosedWithoutMerge),
                )));
            }
            _ => {}
        }
        let queue = match self.read_queue() {
            Ok(queue) => queue,
            Err(ReadEnd::Transient(key, detail)) => return Ok(self.transient_retry(key, &detail)),
            Err(ReadEnd::Terminal(key, detail)) => return Ok(end(self.error(key, &detail))),
            Err(ReadEnd::Malformed) => {
                self.malformed_polls += 1;
                if self.malformed_polls >= MAX_MALFORMED_POLLS {
                    let detail = format!("polls={}", self.malformed_polls);
                    return Ok(end(self.error("queue-unreadable", &detail)));
                }
                return Ok(self.sleep_within_budget(self.r.poll));
            }
        };
        self.malformed_polls = 0;
        self.retry = self.r.poll;
        self.last_poll_at = Some(self.now());
        self.observe_progress(&queue);
        // The memory, written before anything below acts or sleeps.
        let mut memory = self.memory_for(&pull.head, queue.enabled_at.as_deref());
        memory.was_queued |= queue.armed();
        memory.was_in_queue |= queue.in_queue;
        self.write_memory(memory)?;
        self.queue = Some(queue.clone());
        let (armed, in_queue, auto_merge) = (queue.armed(), queue.in_queue, queue.auto_merge);
        let (was_queued, was_in_queue) =
            (self.memory_ref().was_queued, self.memory_ref().was_in_queue);
        if let Some(reply) = self.resume_guard(&queue)? {
            return Ok(end(reply));
        }
        if self.mergeable == "CONFLICTING" {
            self.note_candidate(Candidate::Conflicting);
        } else if was_in_queue && !in_queue {
            self.note_candidate(Candidate::Ejected);
        } else if was_queued && !armed {
            self.note_candidate(Candidate::Disarmed);
        } else {
            self.candidate = None;
            self.candidate_count = 0;
        }
        if let Some(candidate) = self.candidate
            && self.candidate_count >= self.r.confirm_polls
        {
            return Ok(end(self.reply(
                Outcome::Complete,
                candidate.verdict(),
                Some(candidate.cause()),
            )));
        }
        if armed {
            if self.r.guard
                && self
                    .guard_at
                    .is_none_or(|at| self.since(at) >= self.r.probe_interval)
            {
                self.guard_at = Some(self.now());
                if let Some(reply) = self.guard_probe()? {
                    return Ok(end(reply));
                }
            }
            // The probe runs only on the armed, unenqueued shape (membership
            // reports a queued pull request's failure as an ejection), never
            // past a candidate awaiting its confirmation, so one probe
            // reading cannot route a standing conflict to a CI cycle, and
            // only within the budget left past the poll after it, which its
            // reads are bounded by.
            if self.r.check_probe
                && self.candidate.is_none()
                && !in_queue
                && auto_merge
                && self
                    .probe_at
                    .is_none_or(|at| self.since(at) >= self.r.probe_interval)
                && let Some(budget) = self.probe_budget()
            {
                self.probe_at = Some(self.now());
                if self.probe_failed_check(budget) {
                    return Ok(end(self.reply(
                        Outcome::Complete,
                        Verdict::ArmedBlocked,
                        Some(Cause::CheckFailed),
                    )));
                }
            }
        } else if !was_queued && self.elapsed() >= self.r.arm_grace {
            return Ok(end(self.reply(
                Outcome::Timeout,
                Verdict::NotQueued,
                Some(Cause::NeverArmed),
            )));
        }
        let gap = self.next_gap();
        Ok(self.sleep_within_budget(gap))
    }

    /// The deadline verdict: the confirmation count is the whole rule, so a
    /// candidate short of it is reported beside `queued`, never as itself.
    fn deadline(&mut self) -> Result<Reply> {
        if self.pr_state.is_empty() {
            return Ok(self.error("pr-view-failed", "no successful read before the deadline"));
        }
        let Some(memory) = self.memory.clone() else {
            return Ok(self.reply(
                Outcome::Timeout,
                Verdict::NotQueued,
                Some(Cause::NeverArmed),
            ));
        };
        if !memory.was_queued {
            return Ok(self.reply(
                Outcome::Timeout,
                Verdict::NotQueued,
                Some(Cause::NeverArmed),
            ));
        }
        let (armed, in_queue, auto_merge) = self
            .queue
            .as_ref()
            .map(|q| (q.armed(), q.in_queue, q.auto_merge))
            .unwrap_or_default();
        if self.r.guard
            && armed
            && let Some(reply) = self.guard_probe()?
        {
            return Ok(reply);
        }
        if !in_queue && auto_merge {
            return Ok(match &self.probe {
                ProbeRead::Pending(_) => self.reply(
                    Outcome::Timeout,
                    Verdict::ArmedAwaitingChecks,
                    Some(Cause::ChecksPending),
                ),
                ProbeRead::Settled => self.reply(
                    Outcome::Timeout,
                    Verdict::ArmedBlocked,
                    Some(Cause::NotMergeable),
                ),
                ProbeRead::None => self.reply(
                    Outcome::Timeout,
                    Verdict::ArmedAwaitingChecks,
                    Some(Cause::ChecksUnread),
                ),
            });
        }
        Ok(self.reply(Outcome::Timeout, Verdict::Queued, None))
    }
}

fn errors_present(errors: &Optional<Vec<GraphError>>) -> bool {
    errors.present().is_some_and(|errors| !errors.is_empty())
}

fn messages(errors: &Optional<Vec<GraphError>>) -> String {
    errors
        .present()
        .map(|errors| {
            errors
                .iter()
                .map(|e| e.message.as_str())
                .collect::<Vec<_>>()
                .join("; ")
        })
        .unwrap_or_default()
}

fn invalid(field: &str, value: &str) -> Error {
    agent_runtime::Error::refused("queue-watch-invalid", &[("field", field), ("value", value)])
        .into()
}

/// Wait on the pull request `r` names for the item at `path`: the request
/// refused before any read, the memory read from the item, the poll loop
/// on `clock` under the budget, the reply the deadline or a verdict ends it
/// with. The checkout `project` is where the thread reader runs and whose
/// disappearance ends the wait without a result.
#[allow(
    clippy::disallowed_methods,
    reason = "the queue wait's one read of the item record before the loop, its sleeps on the one injected clock, and the checkout's presence read before each poll"
)]
pub fn run(
    path: &Path,
    r: &QueueWatch,
    programs: &Programs,
    project: &Path,
    clock: &dyn Clock,
    env: &Env,
    locking: Locking,
) -> Result<Reply> {
    verify::validate_repo(&r.repo)?;
    if r.pr == 0 {
        return Err(Error::VerifyRequestInvalid {
            field: "pr",
            value: r.pr.to_string(),
        });
    }
    if r.poll.is_zero() {
        return Err(invalid("poll", "0"));
    }
    if r.max_wait.is_zero() {
        return Err(invalid("max-wait", "0"));
    }
    if r.poll > r.max_wait {
        return Err(invalid(
            "poll",
            &format!(
                "{} past max-wait {}",
                r.poll.as_secs(),
                r.max_wait.as_secs()
            ),
        ));
    }
    let (owner, name) = r.repo.split_once('/').expect("a validated repository");
    let (owner, name) = (literal(owner), literal(name));
    let (Some(owner), Some(name)) = (owner, name) else {
        return Err(Error::VerifyRequestInvalid {
            field: "repo",
            value: r.repo.clone(),
        });
    };
    let snapshot = state::load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    let memory: Option<Memory> = state::field(path, &snapshot.doc, MEMORY_KEY)?;
    let mut wait = Wait {
        path,
        r,
        programs,
        project,
        clock,
        env,
        locking,
        owner,
        name,
        start: clock.now(),
        polls: 0,
        last_poll_at: None,
        pr_state: String::new(),
        merged_at: String::new(),
        mergeable: String::new(),
        queue: None,
        written: memory.clone(),
        memory,
        unresolved: None,
        transient_errors: 0,
        retry: r.poll,
        malformed_polls: 0,
        prev_tuple: None,
        prev_count: None,
        prev_head: None,
        last_running: None,
        last_change_poll: None,
        progress_evidence: false,
        head_polls: 0,
        check_reads: 0,
        guard_at: None,
        probe_at: None,
        probe: ProbeRead::None,
        candidate: None,
        candidate_count: 0,
        squeezes: 0,
    };
    // At least one poll: a start that spent the budget still looks once.
    while wait.polls == 0 || wait.elapsed() < r.max_wait {
        if !project.is_dir() {
            return Err(agent_runtime::Error::refused(
                "repository-gone",
                &[
                    ("path", &project.display().to_string()),
                    ("pr", &r.pr.to_string()),
                ],
            )
            .into());
        }
        match wait.poll()? {
            Step::End(reply) => return Ok(*reply),
            Step::Sleep(gap) => {
                if !gap.is_zero() {
                    clock.sleep(gap);
                }
            }
        }
    }
    wait.deadline()
}
