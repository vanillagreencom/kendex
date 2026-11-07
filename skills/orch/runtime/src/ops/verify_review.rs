//! The `verify-review` operation: the review gate's verdict on a pull
//! request's current head, read then recorded, one call per read set. The
//! gate mode a base's rules set is resolved on the first call and recorded
//! on the item as its floor. The gate's acts, the ready mark and the
//! Copilot request with its one error retry, are each claimed under the
//! head's key before the act and read on a later call as absent, attempted
//! or confirmed by GitHub's own record, so an act whose answer was lost is
//! made once more. Copilot's work in flight is bounded by
//! `ORCH_COPILOT_HOLD_SECS` from that key's stamp and holds every verdict
//! that permits a merge; the reviewer's silence is bounded by
//! `PR_REVIEW_WAIT_SECS` per period, each `timeout` ending one period and
//! counted. The workflow repeats the call under its own budget: `pending`
//! and `unreadable` are results, never verdicts, as `verify-pr` answers
//! them.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{Env, loaded, reread};
use crate::error::{Error, Result, ShapeReason};
use crate::settings::{self, ReviewSettings, Settings};
use crate::state::{self, Document, Locking};
use crate::verify::review::{self, Acted, CopilotReviews, GateMode, View, Work};
use crate::verify::wire::{Nullable, PullRequestState};
use crate::verify::{self, Gh, Status, Unreadable};

const REVIEW_KEY: &str = "pr_review";
const GATE_MODE_KEY: &str = "REVIEW_GATE_MODE";
const REFRESH_REVIEW_KEY: &str = "REVIEW_GATE_REFRESH_REVIEW";
const REFRESH_BRANCH_KEY: &str = "REVIEW_GATE_REFRESH_BRANCH";
const REFRESH_AUTHOR_KEY: &str = "REVIEW_GATE_REFRESH_AUTHOR";
/// The blocker kind the merge refuses on while one stands open on the
/// item's escalated findings.
const REGRESSION_KIND: &str = "regression-against-main";
const REQUESTED: &str = "requested";
const EXISTING: &str = "existing";
const FALLBACK: &str = "fallback";
const OFF: &str = "off";

/// Verify the review gate on a pull request's current head and record the
/// verdict. `repo` is `owner/name`, `pr` the number, `base_checkout` the
/// consumer base whose committed policy sets the gate, `mark_ready` whether
/// an open draft is marked ready before its request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerifyReview {
    pub repo: String,
    pub pr: u64,
    pub base_checkout: PathBuf,
    #[serde(default)]
    pub mark_ready: bool,
}

/// The request the gate recorded under the head: what went out, or why
/// nothing did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RequestReport {
    /// `requested` (the POST made), `existing` (Copilot's work already
    /// stands on the head) or `fallback` (no request, `cause` says why).
    pub outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit: Option<i32>,
    /// Whether this call wrote the outcome: the once-per-head cue the
    /// fallback notice is sent on.
    pub recorded_now: bool,
}

/// Copilot's work in flight on the head and where it stands against the
/// hold: `none`, `pending` or `expired`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CopilotReport {
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewRecorded {
    pub head: String,
    pub verdict: String,
    pub reason: String,
    pub at: String,
    pub replaced: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewVerified {
    pub pr: u64,
    pub repo: String,
    pub status: Status,
    /// On `complete`, what was read, as the record's `reason`; on `pending`
    /// or `unreadable`, the stable cause key and the values it acted on.
    pub reason: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    /// The gate mode the item records, `approval` or `off`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<RequestReport>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub copilot: Option<CopilotReport>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub review_decision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approvals: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changes_requested: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unresolved_count: Option<usize>,
    /// On `complete`: `approved`, `changes_requested`, `comments`,
    /// `timeout`, `proceeded`, `copilot-error`, `off` or `blocked`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verdict: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded: Option<ReviewRecorded>,
}

impl ReviewVerified {
    fn new(r: &VerifyReview) -> ReviewVerified {
        ReviewVerified {
            pr: r.pr,
            repo: r.repo.clone(),
            status: Status::Pending,
            reason: String::new(),
            detail: None,
            head: None,
            base: None,
            mode: None,
            request: None,
            copilot: None,
            review_decision: None,
            approvals: None,
            changes_requested: None,
            unresolved_count: None,
            verdict: None,
            recorded: None,
        }
    }

    fn unreadable(mut self, cause: Unreadable) -> ReviewVerified {
        self.status = Status::Unreadable;
        self.reason = cause.reason;
        self.detail = cause.detail;
        self
    }

    fn pending(mut self, reason: String) -> ReviewVerified {
        self.status = Status::Pending;
        self.reason = reason;
        self
    }
}

/// What a spent review period answers with no reviewer engaged:
/// `proceed`, the reviewer-down verdict, or `block`, a timeout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OnTimeout {
    Proceed,
    Block,
}

/// The review settings as the gate reads them: the loader carries their
/// text as read, so a value outside its form refuses here, in the one
/// verb that reads it, and in no other.
struct Review {
    copilot_hold: u64,
    wait: u64,
    on_timeout: OnTimeout,
    copilot_requests: bool,
}

fn review_settings(settings: &ReviewSettings) -> Result<Review> {
    let secs = |key: &'static str, text: &str| -> Result<u64> {
        text.parse::<u64>()
            .map_err(|_| settings::value_refusal(key, text))
    };
    Ok(Review {
        copilot_hold: secs(settings::COPILOT_HOLD_SECS_KEY, &settings.copilot_hold)?,
        wait: secs(settings::REVIEW_WAIT_SECS_KEY, &settings.wait)?,
        on_timeout: match settings.on_timeout.as_str() {
            "proceed" => OnTimeout::Proceed,
            "block" => OnTimeout::Block,
            other => {
                return Err(settings::value_refusal(
                    settings::REVIEW_ON_TIMEOUT_KEY,
                    other,
                ));
            }
        },
        copilot_requests: match settings.copilot_requests.as_str() {
            "on" => true,
            "off" => false,
            other => {
                return Err(settings::value_refusal(
                    settings::COPILOT_REQUESTS_KEY,
                    other,
                ));
            }
        },
    })
}

/// The ready mark under the head: `marking` is written before `gh pr
/// ready`, so a mark whose answer was refused or lost is made again while
/// the pull request reads draft; `done` once a view after it reads the
/// flag ready, this call's or a later one's, so a draft a person restores
/// is never marked over.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Ready {
    Marking,
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct HeadRecord {
    at: String,
    period_started: String,
    timeouts: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ready: Option<Ready>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    request: Option<RequestRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    retry: Option<RetryRecord>,
}

impl HeadRecord {
    fn fresh(stamp: &str) -> HeadRecord {
        HeadRecord {
            at: stamp.to_owned(),
            period_started: stamp.to_owned(),
            timeouts: 0,
            ready: None,
            request: None,
            retry: None,
        }
    }

    /// Whether the head's request stands as the `draft` fallback: no
    /// request went out, and none will while the head reads draft.
    fn held_as_draft(&self) -> bool {
        self.request.as_ref().is_some_and(|request| {
            request.outcome == FALLBACK && request.cause.as_deref() == Some("draft")
        })
    }
}

/// `resent` marks a `requested` POST GitHub showed no sign of, sent once
/// more: a second miss falls back as `unconfirmed`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RequestRecord {
    outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cause: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    exit: Option<i32>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    resent: bool,
}

/// The one retry an error answer earns: `requested` (the POST made),
/// `existing` (Copilot's work already in flight stood for it) or
/// `fallback`; `resent` as on the request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RetryRecord {
    review_id: u64,
    outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cause: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    exit: Option<i32>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    resent: bool,
}

impl RequestRecord {
    fn new(outcome: &str, reason: Option<&str>, cause: Option<&str>, exit: Option<i32>) -> Self {
        RequestRecord {
            outcome: outcome.to_owned(),
            reason: reason.map(str::to_owned),
            cause: cause.map(str::to_owned),
            exit,
            resent: false,
        }
    }

    fn existing(reason: &str) -> RequestRecord {
        RequestRecord::new(EXISTING, Some(reason), None, None)
    }

    fn fallback(cause: &str, exit: Option<i32>) -> RequestRecord {
        RequestRecord::new(FALLBACK, None, Some(cause), exit)
    }

    fn report(&self, recorded_now: bool) -> RequestReport {
        RequestReport {
            outcome: self.outcome.clone(),
            reason: self.reason.clone(),
            cause: self.cause.clone(),
            exit: self.exit,
            recorded_now,
        }
    }
}

impl RetryRecord {
    fn new(review_id: u64, outcome: &str) -> RetryRecord {
        RetryRecord {
            review_id,
            outcome: outcome.to_owned(),
            cause: None,
            exit: None,
            resent: false,
        }
    }

    fn fallback(self, cause: &str, exit: Option<i32>) -> RetryRecord {
        RetryRecord {
            outcome: FALLBACK.into(),
            cause: Some(cause.to_owned()),
            exit,
            ..self
        }
    }
}

/// Why a call ends without a verdict: the caller repeats on `pending` and
/// `unreadable`; a refusal is the operation's error.
enum Stop {
    Pending(String),
    Unreadable(Unreadable),
    Refused(Error),
}

impl From<Error> for Stop {
    fn from(error: Error) -> Stop {
        Stop::Refused(error)
    }
}

impl From<verify::Cause> for Stop {
    fn from(cause: verify::Cause) -> Stop {
        Stop::Unreadable(cause.into())
    }
}

type Step<T> = std::result::Result<T, Stop>;

/// What the locked read of an unconfirmed request found.
enum Unconfirmed {
    /// Its first miss: the `resent` mark written, the POST owed again.
    Resend,
    /// A miss after the resend: written `fallback cause=unconfirmed`.
    FellBack,
    /// Another writer moved the request since this call read it.
    Moved,
}

struct Verdict {
    word: &'static str,
    reason: String,
    /// A `timeout` ends the head's period.
    period_ends: bool,
}

impl Verdict {
    fn new(word: &'static str, reason: String) -> Verdict {
        Verdict {
            word,
            reason,
            period_ends: false,
        }
    }
}

/// Read the pull request, refuse one that is not open, resolve or read the
/// gate mode, judge the reviewers' state on the head, make the acts the
/// head still owes, and record the verdict on the item at `path`. The
/// request's forms refuse before any read; a missing record refuses before
/// any network read.
pub fn run(
    path: &Path,
    r: &VerifyReview,
    settings: &Settings,
    env: &Env,
    locking: Locking,
) -> Result<ReviewVerified> {
    verify::validate_repo(&r.repo)?;
    if r.pr == 0 {
        return Err(Error::VerifyRequestInvalid {
            field: "pr",
            value: r.pr.to_string(),
        });
    }
    let base_dir = std::fs::metadata(&r.base_checkout)
        .map(|m| m.is_dir())
        .unwrap_or(false);
    if r.base_checkout.as_os_str().is_empty() || !base_dir {
        return Err(Error::VerifyRequestInvalid {
            field: "base_checkout",
            value: r.base_checkout.display().to_string(),
        });
    }
    let review = review_settings(&settings.review)?;
    let snapshot = loaded(path)?;
    let gh = Gh::new(Path::new("gh"));
    let reply = ReviewVerified::new(r);
    let view = match review::view(&gh, &r.repo, r.pr) {
        Ok(view) => view,
        Err(cause) => return Ok(reply.unreadable(cause.into())),
    };
    match view.state {
        PullRequestState::Open => {}
        PullRequestState::Closed | PullRequestState::Merged => {
            return Err(Error::PullRequestNotOpen {
                pr: r.pr,
                state: view.state.word(),
            });
        }
    }
    let reply = ReviewVerified {
        head: Some(view.head.clone()),
        base: Some(view.base.clone()),
        ..reply
    };
    let mut gate = Gate {
        path,
        locking,
        r,
        review,
        gh,
        view,
        doc: snapshot.doc,
        now: env.now_secs,
        stamp: env.iso(),
        reply,
        reviews: None,
        work: None,
        asked: false,
        note: None,
    };
    match gate.judge() {
        Ok(verdict) => gate.record_verdict(verdict),
        Err(Stop::Pending(reason)) => Ok(gate.reply.pending(reason)),
        Err(Stop::Unreadable(cause)) => Ok(gate.reply.unreadable(cause)),
        Err(Stop::Refused(error)) => Err(error),
    }
}

/// One call's reads and acts on one head: the view, the item as the call
/// found it, and Copilot's reviews and work, each read at most once.
struct Gate<'a> {
    path: &'a Path,
    locking: Locking,
    r: &'a VerifyReview,
    review: Review,
    gh: Gh<'a>,
    view: View,
    doc: Document,
    now: u64,
    stamp: String,
    reply: ReviewVerified,
    reviews: Option<CopilotReviews>,
    work: Option<Option<Work>>,
    /// Whether this call sent a POST, which no read in the same call can
    /// yet confirm.
    asked: bool,
    /// The pending reason a refused request leaves while the period runs.
    note: Option<String>,
}

#[allow(
    clippy::disallowed_methods,
    reason = "the verify-review operation's reads of the pull request and its acts through gh, and its writes under the record's write check"
)]
impl Gate<'_> {
    fn judge(&mut self) -> Step<Verdict> {
        let mode = self.mode()?;
        self.reply.mode = Some(mode.word().to_owned());
        let mut record = head_record(self.path, &self.doc, &self.view.head)?;
        // The ready mark comes under either mode: a push-first draft is made
        // ready by its early request, which the gate's mode does not gate.
        let marked = self.mark_ready(&mut record)?;
        if mode == GateMode::Off {
            return self.permit(Verdict::new(OFF, "gate off".into()), record.as_ref());
        }

        // The reviewers' state on the head, then its request: every head
        // Copilot has not reviewed is requested before its verdict, an
        // approval standing from an earlier commit included, so Copilot
        // reviews the commit a push lands, and its work on the head, this
        // request included, holds the approval until that review lands.
        let unresolved = review::unresolved_threads(&self.gh, &self.r.repo, self.r.pr)?;
        let copilot = if review::copilot_reviewed(&self.view) {
            Some(self.reviews()?.clone())
        } else {
            None
        };
        let judged = review::judge(&self.view, copilot.as_ref());
        self.reply.review_decision = Some(judged.decision.clone());
        self.reply.approvals = Some(judged.approvals);
        self.reply.changes_requested = Some(judged.changes_requested);
        self.reply.unresolved_count = Some(unresolved);
        let draft = self.view.draft && !marked;
        let record = self.request(record, draft, marked)?;
        if judged.approved && unresolved == 0 {
            let reason = format!(
                "decision={} approvals={} unresolved={unresolved}",
                judged.decision, judged.approvals
            );
            return self.permit(Verdict::new("approved", reason), Some(&record));
        }
        if !judged.approved
            && (judged.decision == "CHANGES_REQUESTED" || judged.changes_requested > 0)
        {
            let reason = format!(
                "changes_requested={} unresolved={unresolved}",
                judged.changes_requested
            );
            return Ok(Verdict::new("changes_requested", reason));
        }
        if unresolved > 0 {
            let reason = format!("unresolved={unresolved} decision={}", judged.decision);
            return Ok(Verdict::new("comments", reason));
        }

        let error = copilot
            .as_ref()
            .and_then(|reviews| reviews.latest.as_ref())
            .filter(|latest| latest.error);
        if let Some(latest) = error
            && self.review.copilot_requests
            && let Some(verdict) = self.retry(&record, latest.id, &latest.submitted_at)?
        {
            return Ok(verdict);
        }
        self.period(&record, judged.engaged)
    }

    /// The gate mode: recorded once, read on every later call.
    fn mode(&self) -> Step<GateMode> {
        if let Some(mode) = recorded_mode(self.path, &self.doc)? {
            return Ok(mode);
        }
        let policy = policy(&self.r.base_checkout)?;
        let mode = match policy.get(GATE_MODE_KEY).map(String::as_str) {
            None | Some("enforce") => review::gate_mode(&self.gh, &self.r.repo, &self.view.base)?,
            Some("off") => GateMode::Off,
            Some(other) => return Err(settings::value_refusal(GATE_MODE_KEY, other).into()),
        };
        let (path, base, at) = (self.path, &self.view.base, &self.stamp);
        Ok(write(path, self.locking, |doc| {
            let record = review_mut(path, doc)?;
            if let Some(standing) = record.get("mode").and_then(Value::as_str) {
                return GateMode::parse(standing).ok_or_else(|| shape(path, "mode"));
            }
            record.insert("mode".into(), json!(mode.word()));
            record.insert("mode_at".into(), json!(at));
            record.insert("base".into(), json!(base));
            Ok(mode)
        })?)
    }

    /// Mark an open draft ready where the call asks: a mark recorded
    /// `marking` and a view still draft is sent again; one the view reads
    /// ready is confirmed, whoever's call asks. Answers whether the gate's
    /// mark made the draft ready, this call's or one whose answer was lost.
    fn mark_ready(&mut self, record: &mut Option<HeadRecord>) -> Step<bool> {
        let done = |head: &HeadRecord| head.ready == Some(Ready::Done);
        let marking = |head: &HeadRecord| head.ready == Some(Ready::Marking);
        if !self.view.draft && record.as_ref().is_some_and(marking) {
            let path = self.path;
            *record = Some(self.update_head(|standing| {
                let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
                head.ready = Some(Ready::Done);
                Ok((head.clone(), head))
            })?);
            return Ok(true);
        }
        if !self.r.mark_ready || !self.view.draft || record.as_ref().is_some_and(done) {
            return Ok(false);
        }
        let stamp = &self.stamp;
        let marking = self.update_head(|standing| {
            let mut head = standing.unwrap_or_else(|| HeadRecord::fresh(stamp));
            if !done(&head) {
                head.ready = Some(Ready::Marking);
            }
            Ok((head.clone(), head))
        })?;
        if done(&marking) {
            *record = Some(marking);
            return Ok(false);
        }
        match review::mark_ready(&self.gh, &self.r.repo, self.r.pr)? {
            Acted::Made => {}
            Acted::Refused { detail, .. } => {
                return Err(Stop::Unreadable(Unreadable {
                    reason: "ready-failed".into(),
                    detail: Some(detail),
                }));
            }
        }
        let after = review::view(&self.gh, &self.r.repo, self.r.pr)?;
        if after.head != self.view.head {
            return Err(Stop::Pending(format!(
                "ready-head-moved head={}",
                after.head
            )));
        }
        if after.draft {
            return Err(Stop::Unreadable(Unreadable {
                reason: "ready-unconfirmed".into(),
                detail: None,
            }));
        }
        let path = self.path;
        *record = Some(self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            head.ready = Some(Ready::Done);
            Ok((head.clone(), head))
        })?);
        Ok(true)
    }

    /// The head's request, claimed once and read after: a standing
    /// `requested` GitHub shows no sign of is sent once more, then falls
    /// back `unconfirmed`. A `draft` fallback lapses once the gate's mark
    /// made the draft ready, or once the view and `pulls/N` both read it
    /// ready, so a call where the two reads disagree records and notifies
    /// nothing again.
    fn request(
        &mut self,
        record: Option<HeadRecord>,
        draft: bool,
        marked: bool,
    ) -> Step<HeadRecord> {
        let mut pull = None;
        let mut ready = marked;
        if !ready && !self.view.draft && record.as_ref().is_some_and(HeadRecord::held_as_draft) {
            let read = review::pull(&self.gh, &self.r.repo, self.r.pr)?;
            ready = !read.draft;
            pull = Some(read);
        }
        let stands = |head: &HeadRecord| head.request.is_some() && !(ready && head.held_as_draft());
        if let Some(head) = record.as_ref().filter(|head| stands(head)) {
            self.reply.request = head.request.as_ref().map(|q| q.report(false));
            return self.confirm_request(head.clone());
        }
        let policy = policy(&self.r.base_checkout)?;
        let pull = match pull {
            Some(pull) => pull,
            None => review::pull(&self.gh, &self.r.repo, self.r.pr)?,
        };
        if pull.head.sha != self.view.head {
            return Err(Stop::Pending(format!("head-moved head={}", pull.head.sha)));
        }
        let refresh = match policy.get(REFRESH_REVIEW_KEY).map(String::as_str) {
            None | Some("copilot") => false,
            Some("overseer") => {
                let declared = |key: &str| -> Result<String> {
                    policy
                        .get(key)
                        .filter(|v| !v.is_empty())
                        .cloned()
                        .ok_or_else(|| settings::value_refusal(key, ""))
                };
                let (branch, author) =
                    (declared(REFRESH_BRANCH_KEY)?, declared(REFRESH_AUTHOR_KEY)?);
                match &pull.user {
                    Nullable::Present(user) => {
                        pull.head.branch == branch && user.login == author && user.kind == "Bot"
                    }
                    Nullable::Absent | Nullable::Null => false,
                }
            }
            Some(other) => return Err(settings::value_refusal(REFRESH_REVIEW_KEY, other).into()),
        };
        // The released writer's retry is carried into the head's retry, so
        // a head mid-wait at an upgrade spends no second retry; an error
        // answer standing on the head makes this request its one retry,
        // claimed in the same write, so no second POST follows.
        let released = released_retry(self.path, &self.doc, &self.view.head)?;
        let mut retry = released.clone();
        let request = if refresh {
            RequestRecord::fallback("refresh", None)
        } else if !self.review.copilot_requests {
            RequestRecord::fallback("off", None)
        } else if draft || pull.draft {
            RequestRecord::fallback("draft", None)
        } else {
            let reviews = self.reviews()?.clone();
            let work = self.work()?.is_some();
            let released = released.as_ref().map(|retry| retry.outcome.as_str());
            if reviews
                .latest
                .as_ref()
                .is_some_and(|latest| latest.no_files)
            {
                RequestRecord::fallback("no-files", None)
            } else if released == Some(REQUESTED) {
                RequestRecord::existing("existing-error-retry")
            } else if released == Some(FALLBACK) {
                RequestRecord::fallback("error", None)
            } else if work {
                RequestRecord::existing("existing-run")
            } else if reviews.any_non_error {
                RequestRecord::existing("existing-review")
            } else {
                retry = reviews
                    .latest
                    .as_ref()
                    .filter(|latest| latest.error)
                    .map(|latest| RetryRecord::new(latest.id, REQUESTED));
                RequestRecord::new(REQUESTED, None, None, None)
            }
        };
        let post = request.outcome == REQUESTED;
        let stamp = &self.stamp;
        let (claimed, claimed_now) = self.update_head(|standing| match standing {
            Some(standing) if stands(&standing) => Ok((standing.clone(), (standing, false))),
            standing => {
                let base = standing.unwrap_or_else(|| HeadRecord::fresh(stamp));
                // A lapsing draft fallback starts the period and the hold
                // with the request it releases: no review was asked for
                // while the head stood as a draft.
                let (at, period_started) = if base.held_as_draft() {
                    (stamp.clone(), stamp.clone())
                } else {
                    (base.at.clone(), base.period_started.clone())
                };
                let merged = HeadRecord {
                    at,
                    period_started,
                    request: Some(request.clone()),
                    retry: retry.clone().or(base.retry.clone()),
                    ..base
                };
                Ok((merged.clone(), (merged, true)))
            }
        })?;
        self.reply.request = claimed.request.as_ref().map(|q| q.report(claimed_now));
        if claimed_now && post {
            return self.post_request(claimed);
        }
        Ok(claimed)
    }

    /// A standing `requested` read against GitHub's record of it: Copilot's
    /// work in flight, the pending request among it, or a Copilot review on
    /// the head confirms it. A request whose work ended with no review of the
    /// head, its check completed or cancelled or the request removed, is not
    /// confirmed by its event: it is sent once more under its `resent`
    /// mark, and a second miss falls back `unconfirmed` so the fallback
    /// notice goes out.
    fn confirm_request(&mut self, head: HeadRecord) -> Step<HeadRecord> {
        let Some(request) = head.request.clone() else {
            return Ok(head);
        };
        if request.outcome != REQUESTED {
            return Ok(head);
        }
        let reviews = self.reviews()?.clone();
        let landed = self.work()?.is_some() || reviews.latest.is_some() || reviews.any_non_error;
        if landed {
            return Ok(head);
        }
        let path = self.path;
        let (head, read) = self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            let read = match &mut head.request {
                Some(request) if request.outcome == REQUESTED && !request.resent => {
                    request.resent = true;
                    Unconfirmed::Resend
                }
                Some(request) if request.outcome == REQUESTED => {
                    *request = RequestRecord::fallback("unconfirmed", None);
                    Unconfirmed::FellBack
                }
                Some(_) | None => Unconfirmed::Moved,
            };
            Ok((head.clone(), (head, read)))
        })?;
        match read {
            Unconfirmed::Resend => self.post_request(head),
            Unconfirmed::FellBack => {
                self.reply.request = head.request.as_ref().map(|q| q.report(true));
                Ok(head)
            }
            Unconfirmed::Moved => {
                self.reply.request = head.request.as_ref().map(|q| q.report(false));
                Ok(head)
            }
        }
    }

    /// The request's POST, its claim standing; a refusal rewrites the
    /// request, and the retry claimed in the same write, as refused.
    fn post_request(&mut self, claimed: HeadRecord) -> Step<HeadRecord> {
        self.asked = true;
        let exit = match review::request_review(&self.gh, &self.r.repo, self.r.pr)? {
            Acted::Made => {
                // The work read before the POST knows nothing of it: read
                // again, so this call's hold sees the request it made.
                self.work = None;
                return Ok(claimed);
            }
            Acted::Refused { exit, .. } => exit,
        };
        let path = self.path;
        let head = self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            head.request = Some(RequestRecord::fallback("refused", Some(exit)));
            if let Some(retry) = head.retry.take() {
                head.retry = Some(if retry.outcome == REQUESTED {
                    retry.fallback("refused", Some(exit))
                } else {
                    retry
                });
            }
            Ok((head.clone(), head))
        })?;
        self.reply.request = head.request.as_ref().map(|q| q.report(true));
        self.note = Some(format!("request-refused exit={exit}"));
        Ok(head)
    }

    /// Copilot's error answer `error_id`: one retry per head, decided with
    /// the request. A head held as a draft takes no retry: the request that
    /// releases it claims the retry in its own write, so one POST is both.
    /// A request the refresh policy held back holds the retry back too, its
    /// cause the verdict's; Copilot's work already in flight stands for the
    /// retry; a retry the released writer recorded is the head's; a
    /// `requested` retry GitHub shows no sign of is sent once more; and a
    /// second error answer after the retry is the verdict.
    fn retry(
        &mut self,
        record: &HeadRecord,
        error_id: u64,
        error_at: &str,
    ) -> Step<Option<Verdict>> {
        if record.held_as_draft() {
            return Ok(None);
        }
        let released = released_retry(self.path, &self.doc, &self.view.head)?;
        let standing = record.retry.clone().or(released.clone());
        let Some(retry) = standing else {
            let held = record
                .request
                .as_ref()
                .filter(|request| request.outcome == FALLBACK)
                .and_then(|request| request.cause.as_deref())
                .filter(|cause| *cause == "refresh");
            if let Some(cause) = held {
                let fallback = RetryRecord {
                    cause: Some(cause.to_owned()),
                    ..RetryRecord::new(error_id, FALLBACK)
                };
                if self.set_retry(|standing| standing.is_none().then(|| fallback.clone()))? {
                    return Ok(Some(Verdict::new(
                        "copilot-error",
                        format!("copilot-error cause={cause}"),
                    )));
                }
                return Ok(None);
            }
            let fresh = if self.work()?.is_some() {
                RetryRecord::new(error_id, EXISTING)
            } else {
                RetryRecord::new(error_id, REQUESTED)
            };
            let claimed = self.set_retry(|standing| standing.is_none().then(|| fresh.clone()))?;
            if claimed && fresh.outcome == REQUESTED {
                return self.post_retry(fresh);
            }
            return Ok(None);
        };
        if retry.outcome != FALLBACK && retry.review_id != error_id {
            self.set_retry(|_| Some(retry.clone().fallback("error", None)))?;
            return Ok(Some(Verdict::new(
                "copilot-error",
                "copilot-error cause=error".into(),
            )));
        }
        if retry.outcome != REQUESTED || self.asked {
            return Ok(None);
        }
        let landed = self.work()?.is_some()
            || self
                .reviews()?
                .requested_at
                .as_deref()
                .is_some_and(|at| at >= error_at);
        if landed {
            return Ok(None);
        }
        let carried = |standing: Option<RetryRecord>| standing.or(released.clone());
        if retry.resent {
            let cause = "unconfirmed";
            self.set_retry(|standing| carried(standing).map(|r| r.fallback(cause, None)))?;
            return Ok(Some(Verdict::new(
                "copilot-error",
                format!("copilot-error cause={cause}"),
            )));
        }
        let resent = RetryRecord {
            resent: true,
            ..retry.clone()
        };
        let claimed = self.set_retry(|standing| {
            (carried(standing).as_ref() == Some(&retry)).then(|| resent.clone())
        })?;
        if claimed {
            return self.post_retry(resent);
        }
        Ok(None)
    }

    /// The retry's POST, its claim standing; a refusal is the verdict.
    fn post_retry(&mut self, retry: RetryRecord) -> Step<Option<Verdict>> {
        self.asked = true;
        let exit = match review::request_review(&self.gh, &self.r.repo, self.r.pr)? {
            Acted::Made => return Ok(None),
            Acted::Refused { exit, .. } => exit,
        };
        let cause = format!("refused exit={exit}");
        self.set_retry(|_| Some(retry.clone().fallback(&cause, Some(exit))))?;
        Ok(Some(Verdict::new(
            "copilot-error",
            format!("copilot-error cause={cause}"),
        )))
    }

    /// Copilot's flight against the hold and the reviewer's silence against
    /// the period: `pending` while the period runs, else the period's
    /// verdict, `proceeded` on a silent reviewer under `proceed`, `timeout`
    /// otherwise, which ends the period and counts it. A head held as a
    /// draft has no period: no review was asked for, so it stays `pending`
    /// until the request that releases it starts one.
    fn period(&mut self, record: &HeadRecord, engaged: usize) -> Step<Verdict> {
        self.hold(Some(record))?;
        if record.held_as_draft() {
            return Err(Stop::Pending("request-fallback cause=draft".into()));
        }
        let started =
            clock::epoch_secs(&record.period_started).ok_or_else(|| shape(self.path, "heads"))?;
        let spent = self.now.saturating_sub(started);
        let wait = self.review.wait;
        if spent < wait {
            let state = self
                .reply
                .copilot
                .as_ref()
                .map_or("none", |c| c.state.as_str());
            let reason = self.note.take().unwrap_or_else(|| {
                format!("review-pending copilot={state} remaining={}", wait - spent)
            });
            return Err(Stop::Pending(reason));
        }
        if self.review.on_timeout == OnTimeout::Proceed && engaged == 0 {
            let reason = format!("silent after {wait}s");
            return self.permit(Verdict::new("proceeded", reason), Some(record));
        }
        Ok(Verdict {
            word: "timeout",
            reason: format!("engaged={engaged} after {wait}s"),
            period_ends: true,
        })
    }

    /// The one judgement before a verdict that permits a merge is
    /// published: a regression blocker standing open refuses it, and
    /// Copilot's work in flight within its hold keeps it `pending`, the
    /// review the gate itself asked for included. The hold stands under
    /// either gate mode: an `off` gate asks Copilot for nothing, yet a
    /// review already running on the head still lands before the merge.
    fn permit(&mut self, verdict: Verdict, record: Option<&HeadRecord>) -> Step<Verdict> {
        if let Some(location) = regression_blocker(self.path, &loaded(self.path)?.doc)? {
            return Ok(Verdict::new(
                "blocked",
                format!("regression-open location={location}"),
            ));
        }
        if let Some(remaining) = self.hold(record)? {
            let run = self
                .reply
                .copilot
                .as_ref()
                .and_then(|c| c.run)
                .unwrap_or_default();
            return Err(Stop::Pending(format!(
                "copilot-pending run={run} remaining={remaining}"
            )));
        }
        Ok(verdict)
    }

    /// Copilot's work in flight against the hold from the head record's
    /// stamp, written to the reply: the seconds left while the hold runs.
    /// Work on a head with no record yet stamps one, so the hold has a
    /// start every later call reads.
    fn hold(&mut self, record: Option<&HeadRecord>) -> Step<Option<u64>> {
        let Some(work) = self.work()?.clone() else {
            self.reply.copilot = Some(CopilotReport {
                state: "none".into(),
                run: None,
                started_at: None,
            });
            return Ok(None);
        };
        let at = match record {
            Some(record) => record.at.clone(),
            None => {
                let stamp = &self.stamp;
                self.update_head(|standing| {
                    let head = standing.unwrap_or_else(|| HeadRecord::fresh(stamp));
                    Ok((head.clone(), head))
                })?
                .at
            }
        };
        let since = clock::epoch_secs(&at).ok_or_else(|| shape(self.path, "heads"))?;
        let held = self.now.saturating_sub(since);
        let remaining = self
            .review
            .copilot_hold
            .checked_sub(held)
            .filter(|&r| r > 0);
        self.reply.copilot = Some(CopilotReport {
            state: if remaining.is_some() {
                "pending".into()
            } else {
                "expired".into()
            },
            run: Some(work.id),
            started_at: work.started_at,
        });
        Ok(remaining)
    }

    fn reviews(&mut self) -> Step<&CopilotReviews> {
        let reviews = match self.reviews.take() {
            Some(reviews) => reviews,
            None => review::copilot_reviews(&self.gh, &self.r.repo, self.r.pr, &self.view.head)?,
        };
        Ok(self.reviews.insert(reviews))
    }

    fn work(&mut self) -> Step<&Option<Work>> {
        let work = match self.work.take() {
            Some(work) => work,
            None => review::copilot_work(&self.gh, &self.r.repo, self.r.pr, &self.view.head)?,
        };
        Ok(self.work.insert(work))
    }

    /// One locked read-modify-write of the head's record: `f` takes the
    /// standing record, absent where none is, and answers the record to
    /// store beside its own answer.
    fn update_head<T>(
        &self,
        f: impl Fn(Option<HeadRecord>) -> Result<(HeadRecord, T)>,
    ) -> Result<T> {
        let (path, head) = (self.path, self.view.head.as_str());
        write(path, self.locking, |doc| {
            let heads = heads_mut(path, doc)?;
            let standing = heads
                .get(head)
                .cloned()
                .map(serde_json::from_value::<HeadRecord>)
                .transpose()
                .map_err(|_| shape(path, "heads"))?;
            let (record, answer) = f(standing)?;
            heads.insert(head.to_owned(), serde_json::to_value(&record)?);
            Ok(answer)
        })
    }

    /// Write the head's retry as `f` answers it from the standing one;
    /// answers whether `f` wrote one.
    fn set_retry(&self, f: impl Fn(Option<RetryRecord>) -> Option<RetryRecord>) -> Result<bool> {
        let path = self.path;
        self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            let Some(retry) = f(head.retry.clone()) else {
                return Ok((head, false));
            };
            head.retry = Some(retry);
            Ok((head, true))
        })
    }

    /// Record the verdict under `pr_review.verdict`; a `timeout` ends the
    /// head's period and counts it.
    fn record_verdict(mut self, verdict: Verdict) -> Result<ReviewVerified> {
        let (path, head, stamp) = (self.path, self.view.head.as_str(), self.stamp.as_str());
        let recorded = write(path, self.locking, |doc| {
            let record = review_mut(path, doc)?;
            let replaced = !matches!(record.get("verdict"), None | Some(Value::Null));
            record.insert(
                "verdict".into(),
                json!({"head": head, "verdict": verdict.word, "reason": verdict.reason, "at": stamp}),
            );
            if verdict.period_ends {
                let heads = heads_mut(path, doc)?;
                let mut standing: HeadRecord = heads
                    .get(head)
                    .cloned()
                    .map(serde_json::from_value)
                    .transpose()
                    .map_err(|_| shape(path, "heads"))?
                    .ok_or_else(|| shape(path, "heads"))?;
                standing.period_started = stamp.to_owned();
                standing.timeouts += 1;
                heads.insert(head.to_owned(), serde_json::to_value(&standing)?);
            }
            Ok(ReviewRecorded {
                head: head.to_owned(),
                verdict: verdict.word.to_owned(),
                reason: verdict.reason.clone(),
                at: stamp.to_owned(),
                replaced,
            })
        })?;
        self.reply.status = Status::Complete;
        self.reply.reason = recorded.reason.clone();
        self.reply.verdict = Some(recorded.verdict.clone());
        self.reply.recorded = Some(recorded);
        Ok(self.reply)
    }
}

/// One locked read-modify-write of the item under the record's write
/// check, read again while another writer moves it.
#[allow(
    clippy::disallowed_methods,
    reason = "the review gate's record writes: the item read and stored under the state module's write check"
)]
fn write<R>(path: &Path, locking: Locking, f: impl Fn(&mut Document) -> Result<R>) -> Result<R> {
    reread(|| {
        let snapshot = loaded(path)?;
        let mut doc = snapshot.doc.clone();
        let out = f(&mut doc)?;
        state::store(path, &snapshot, &doc, locking)?;
        Ok(out)
    })
}

fn shape(path: &Path, field: &str) -> Error {
    Error::Shape {
        path: path.to_path_buf(),
        field: format!("{REVIEW_KEY}/{field}"),
        reason: ShapeReason::TypeMismatch,
        cause: "not the review record's shape".into(),
    }
}

fn review_mut<'a>(path: &Path, doc: &'a mut Document) -> Result<&'a mut Document> {
    if matches!(doc.get(REVIEW_KEY), None | Some(Value::Null)) {
        doc.insert(REVIEW_KEY.into(), Value::Object(Map::new()));
    }
    state::object_mut(path, doc, REVIEW_KEY)
}

fn heads_mut<'a>(path: &Path, doc: &'a mut Document) -> Result<&'a mut Document> {
    let record = review_mut(path, doc)?;
    if matches!(record.get("heads"), None | Some(Value::Null)) {
        record.insert("heads".into(), Value::Object(Map::new()));
    }
    match record.get_mut("heads") {
        Some(Value::Object(heads)) => Ok(heads),
        _ => Err(shape(path, "heads")),
    }
}

fn review_object(path: &Path, doc: &Document) -> Result<Map<String, Value>> {
    match doc.get(REVIEW_KEY) {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::Object(record)) => Ok(record.clone()),
        Some(_) => Err(shape(path, "")),
    }
}

fn recorded_mode(path: &Path, doc: &Document) -> Result<Option<GateMode>> {
    match review_object(path, doc)?.get("mode") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(word)) => GateMode::parse(word)
            .map(Some)
            .ok_or_else(|| shape(path, "mode")),
        Some(_) => Err(shape(path, "mode")),
    }
}

fn head_record(path: &Path, doc: &Document, head: &str) -> Result<Option<HeadRecord>> {
    let record = review_object(path, doc)?;
    match record.get("heads") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Object(heads)) => match heads.get(head) {
            None => Ok(None),
            Some(value) => serde_json::from_value(value.clone())
                .map(Some)
                .map_err(|_| shape(path, "heads")),
        },
        Some(_) => Err(shape(path, "heads")),
    }
}

/// The error retry the released writer recorded under
/// `pr_approval.copilot_error_retries[head]`, as `{review_id, outcome}`
/// with the review id written as text, read as the head's retry.
fn released_retry(path: &Path, doc: &Document, head: &str) -> Result<Option<RetryRecord>> {
    let Some(approval) = doc.get("pr_approval") else {
        return Ok(None);
    };
    let Some(retries) = approval.get("copilot_error_retries") else {
        return Ok(None);
    };
    let entry = match retries.get(head) {
        None | Some(Value::Null) => return Ok(None),
        Some(entry) => entry,
    };
    let refused = |cause: &str| Error::Shape {
        path: path.to_path_buf(),
        field: "pr_approval/copilot_error_retries".into(),
        reason: ShapeReason::TypeMismatch,
        cause: cause.into(),
    };
    let outcome = match entry.get("outcome").and_then(Value::as_str) {
        Some(word @ (REQUESTED | FALLBACK)) => word,
        _ => return Err(refused("outcome is not requested or fallback")),
    };
    let review_id = match entry.get("review_id") {
        Some(Value::String(text)) => text.parse::<u64>().ok(),
        Some(Value::Number(number)) => number.as_u64(),
        _ => None,
    }
    .ok_or_else(|| refused("review_id is not a review id"))?;
    Ok(Some(RetryRecord::new(review_id, outcome)))
}

/// The location of a blocker of kind regression-against-main standing open
/// on `escalated_items`: one a fix has not cleared and the review did not
/// skip.
fn regression_blocker(path: &Path, doc: &Document) -> Result<Option<String>> {
    let items: Vec<Value> = state::field(path, doc, "escalated_items")?.unwrap_or_default();
    for item in items {
        let kind = item.get("kind").and_then(Value::as_str);
        let skipped = item.get("outcome").and_then(Value::as_str) == Some("skipped");
        if kind == Some(REGRESSION_KIND) && !skipped {
            let location = item
                .get("location")
                .and_then(Value::as_str)
                .unwrap_or_default();
            return Ok(Some(location.to_owned()));
        }
    }
    Ok(None)
}

/// The consumer's committed review policy from the base checkout's files,
/// `kendex.settings.toml`, then `.kendex/settings.toml`, then its private
/// env file, the later outranking the earlier; no process variable reaches
/// it, since the policy is the consumer's, never the caller's.
fn policy(base: &Path) -> Result<BTreeMap<String, String>> {
    let mut values = BTreeMap::new();
    for name in settings::SETTINGS_FILES {
        for (key, value) in settings::settings_file(&base.join(name))? {
            values.insert(key, value);
        }
    }
    let private = settings::private_env_file(&base.join(settings::DEFAULT_ENV_FILE), None)?;
    values.extend(private.values);
    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A standing escalated blocker of the regression kind refuses the
    /// merge by its location; a skipped one, another kind or none does not.
    #[test]
    fn a_regression_blocker_stands_until_cleared_or_skipped() {
        let path = Path::new("item.json");
        let doc = |items: Value| -> Document {
            let mut doc = Document::new();
            doc.insert("escalated_items".into(), items);
            doc
        };
        let standing = doc(json!([
            {"location": "a.rs", "kind": "other"},
            {"location": "b.rs", "kind": REGRESSION_KIND, "outcome": "blocked"}
        ]));
        assert_eq!(
            regression_blocker(path, &standing).unwrap(),
            Some("b.rs".into())
        );
        let skipped =
            doc(json!([{"location": "b.rs", "kind": REGRESSION_KIND, "outcome": "skipped"}]));
        assert_eq!(regression_blocker(path, &skipped).unwrap(), None);
        assert_eq!(regression_blocker(path, &doc(json!([]))).unwrap(), None);
        assert_eq!(regression_blocker(path, &Document::new()).unwrap(), None);
    }
}
