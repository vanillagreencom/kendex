//! The `verify-review` operation: the review gate's verdict on a pull
//! request's current head, read then recorded, one call per read set. The
//! gate mode a base's rules set is resolved on the first call and recorded
//! on the item as its floor. The gate's acts, the ready mark and the
//! Copilot request with its one error retry, are each claimed under the
//! head's key before the act and read on a later call as absent, attempted
//! or confirmed by GitHub's own record, so an act whose answer was lost is
//! made once more. Copilot's work in flight is bounded by
//! `ORCH_COPILOT_HOLD_SECS` from that key's stamp and holds every verdict
//! that permits a merge and the review period's own answers; the
//! reviewer's silence is bounded by `PR_REVIEW_WAIT_SECS` per period, each
//! `timeout` ending one period and counted. A fallback, or an error retry
//! that cannot stand, owes the lane's overseer the `copilot-fallback`
//! notice where the item runs in a lane: written `owed` in the write that
//! records the outcome, sent into the lane's mailbox after it and marked,
//! so a call that finds it owed sends it. The workflow repeats the call
//! under its own budget: `pending` and `unreadable` are results, never
//! verdicts, as `verify-pr` answers them.
use agent_runtime::intent::Notice;
use agent_runtime::record::{self, Document, Locking};
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use agent_runtime::reading::Reading;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::loaded;
use agent_runtime::error::ShapeReason;
use agent_runtime::journal::Env;

use crate::error::{Error, Result};
use crate::mailbox::{Mailbox, Noticed};
use crate::marker;
use crate::policy::policy;
use crate::settings::{self, ReviewSettings, Settings};
use crate::state;
use crate::verify::review::{self, Acted, CopilotReviews, GateMode, View, Work};
use crate::verify::wire::{Nullable, Optional, Pull, PullRequestState};
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
/// The kind every Copilot fallback notice opens with, as the overseer's
/// head rules read it.
const NOTICE_KEY: &str = "copilot-fallback";

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
    /// Whether this call wrote the outcome.
    pub recorded_now: bool,
}

/// A `copilot-fallback` notice the head owes its lane's overseer, as this
/// call leaves it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NoticeReport {
    /// The notice's first line: `copilot-fallback PR #N head SHA cause=C`.
    pub notice: String,
    /// `owed`, `sent`, `unsent:<cause>` or `unanswered:<cause>`.
    pub owner: String,
    /// Whether this call ran the send.
    pub sent_now: bool,
    /// The key of the store's refusal of this call's mark: the notice
    /// stands as `owner` says, and the next call sends it again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unmarked: Option<String>,
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
    /// The head's `copilot-fallback` notices, in the order they were owed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notices: Vec<NoticeReport>,
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
            notices: Vec::new(),
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
/// text as read, so a value outside its form refuses in the verbs that
/// read it.
struct Review {
    copilot_hold: u64,
    wait: u64,
    on_timeout: OnTimeout,
    copilot_requests: bool,
}

fn review_settings(settings: &ReviewSettings) -> Result<Review> {
    let secs = |key: &'static str, text: &str| -> Result<u64> {
        text.parse::<u64>()
            .map_err(|_| crate::Error::from(agent_runtime::settings::value_refusal(key, text)))
    };
    Ok(Review {
        copilot_hold: super::copilot_wait::bound(settings)?.as_secs(),
        wait: secs(settings::REVIEW_WAIT_SECS_KEY, &settings.wait)?,
        on_timeout: match settings.on_timeout.as_str() {
            "proceed" => OnTimeout::Proceed,
            "block" => OnTimeout::Block,
            other => {
                return Err(crate::Error::from(agent_runtime::settings::value_refusal(
                    settings::REVIEW_ON_TIMEOUT_KEY,
                    other,
                )));
            }
        },
        copilot_requests: match settings.copilot_requests.as_str() {
            "on" => true,
            "off" => false,
            other => {
                return Err(crate::Error::from(agent_runtime::settings::value_refusal(
                    settings::COPILOT_REQUESTS_KEY,
                    other,
                )));
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
    /// The `copilot-fallback` notices the head owes its lane's overseer:
    /// each written `owed` in the write that records its outcome, then
    /// marked with how its send went.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    notices: Vec<Notice>,
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
            notices: Vec::new(),
        }
    }

    /// Record `notice` owed, once: an outcome written again owes no second
    /// notice with the same words.
    fn owe(&mut self, notice: Option<&Notice>) {
        if let Some(notice) = notice
            && !self.notices.iter().any(|n| n.text == notice.text)
        {
            self.notices.push(notice.clone());
        }
    }

    /// Whether the head's request already fell back, whatever its cause:
    /// a settled record, which `PR_COPILOT_REQUESTS=off` leaves as it
    /// stands.
    fn fell_back(&self) -> bool {
        self.request
            .as_ref()
            .is_some_and(|request| request.outcome == FALLBACK)
    }

    /// Whether the head's request stands as the `draft` fallback: no
    /// request went out, and none will while the head reads draft.
    fn held_as_draft(&self) -> bool {
        self.request.as_ref().is_some_and(|request| {
            request.outcome == FALLBACK && request.cause.as_deref() == Some("draft")
        })
    }
}

/// `resent` marks a `requested` sent once more, its first POST answered by
/// no Copilot work or work that ended with no review of the head: a miss
/// after it falls back as `unconfirmed`.
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

    /// Copilot's work in flight stood for this head's request.
    fn stood_for_run(&self) -> bool {
        self.outcome == EXISTING && self.reason.as_deref() == Some("existing-run")
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
    /// An `existing-run` whose work ended: claimed as `requested`, its
    /// POST owed.
    Claim,
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
        item: state::item_of(path).map(str::to_owned),
        checkout: settings.roots.project.clone(),
        lane: None,
        mail: Mailbox::new(settings.lane_mail_cli.clone()),
        notice_dir: settings.state_dir.join("review"),
        nonce: env.round_id(),
        draft: false,
        pull: None,
        eligibility: None,
        private_env: settings.private_env,
    };
    let judged = gate.judge();
    if !matches!(judged, Err(Stop::Refused(_))) {
        gate.deliver_notices()?;
    }
    match judged {
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
    /// The item the record keys, the lane's mailbox where it runs in one.
    item: Option<String>,
    /// The checkout the call runs in, whose common git directory holds the
    /// lane's launch marker.
    checkout: PathBuf,
    /// The lane's root its marker names, read once and only where a notice
    /// is at stake.
    lane: Option<Reading<PathBuf>>,
    mail: Mailbox,
    /// Where a notice's text is written for the mailbox program to read.
    notice_dir: PathBuf,
    nonce: String,
    /// Whether the head reads draft and this call did not mark it ready.
    draft: bool,
    /// The `pulls/N` read the call made, for the eligibility to reuse.
    pull: Option<Pull>,
    /// The head's eligibility, judged once per call (`ineligible`).
    eligibility: Option<Option<&'static str>>,
    /// Whether the base checkout's policy takes its private env file.
    private_env: bool,
}

/// The head's admission to a Copilot request on this call: only
/// `Gate::eligible` makes one and `Gate::post` takes one, so every POST,
/// the request's and the error retry's, passes the head's eligibility.
struct Eligible(());

#[allow(
    clippy::disallowed_methods,
    reason = "the verify-review operation's reads of the pull request and its acts through gh, and its writes under the record's write check"
)]
impl Gate<'_> {
    fn judge(&mut self) -> Step<Verdict> {
        let mode = self.mode()?;
        self.reply.mode = Some(mode.word().to_owned());
        let mut record = head_record(self.path, &self.doc, &self.view.head)?;
        // Push-first needs a ready PR so Copilot can review it during internal
        // review, independently of the gate mode.
        let marked = self.mark_ready(&mut record)?;
        if mode == GateMode::Off {
            return self.permit(Verdict::new(OFF, "gate off".into()), record.as_ref());
        }

        // An approval carried from an earlier commit is no review of this
        // head, so the head's request is settled before its verdict. Copilot's
        // work holds the approval only within `ORCH_COPILOT_HOLD_SECS` of the
        // head record (`hold`), so a stalled or reviewless run cannot hold the
        // lane indefinitely.
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
        self.draft = self.view.draft && !marked;
        let record = self.request(record, marked)?;
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
        let policy = policy(&self.r.base_checkout, self.private_env)?;
        let mode = match policy.get(GATE_MODE_KEY).map(String::as_str) {
            None | Some("enforce") => review::gate_mode(&self.gh, &self.r.repo, &self.view.base)?,
            Some("off") => GateMode::Off,
            Some(other) => {
                return Err(crate::Error::from(agent_runtime::settings::value_refusal(
                    GATE_MODE_KEY,
                    other,
                ))
                .into());
            }
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
    /// `requested` that drew no Copilot work, or whose work ended with no
    /// review of the head, is sent once more, then falls back
    /// `unconfirmed`; an `existing-run` whose run ended so is claimed and
    /// sent (`confirm_request`). A `draft` fallback lapses once the gate's mark
    /// made the draft ready, or once the view and `pulls/N` both read it
    /// ready, so a call where the two reads disagree records and notifies
    /// nothing again.
    fn request(&mut self, record: Option<HeadRecord>, marked: bool) -> Step<HeadRecord> {
        let mut ready = marked;
        if !ready && !self.view.draft && record.as_ref().is_some_and(HeadRecord::held_as_draft) {
            let read = review::pull(&self.gh, &self.r.repo, self.r.pr)?;
            ready = read.draft != Optional::Present(true);
            self.pull = Some(read);
        }
        let stands = |head: &HeadRecord| head.request.is_some() && !(ready && head.held_as_draft());
        if let Some(head) = record.as_ref().filter(|head| stands(head)) {
            if !self.review.copilot_requests
                && !head.fell_back()
                && self.ineligible()? == Some("off")
            {
                return self.fall_back_off();
            }
            self.reply.request = head.request.as_ref().map(|q| q.report(false));
            return self.confirm_request(head.clone());
        }
        let ineligible = self.ineligible()?;
        // An error answer standing on the head makes this request its one
        // retry, claimed in the same write, so no second POST follows.
        let mut retry = None;
        let request = if let Some(cause) = ineligible {
            RequestRecord::fallback(cause, None)
        } else {
            let reviews = self.reviews()?.clone();
            let work = self.work()?.is_some();
            if reviews
                .latest
                .as_ref()
                .is_some_and(|latest| latest.no_files)
            {
                RequestRecord::fallback("no-files", None)
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
        let owed = match (request.outcome.as_str(), request.cause.as_deref()) {
            (FALLBACK, Some(cause)) => self.notice_for(cause, request.exit),
            _ => None,
        };
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
                let mut merged = HeadRecord {
                    at,
                    period_started,
                    request: Some(request.clone()),
                    retry: retry.clone().or(base.retry.clone()),
                    ..base
                };
                merged.owe(owed.as_ref());
                Ok((merged.clone(), (merged, true)))
            }
        })?;
        self.reply.request = claimed.request.as_ref().map(|q| q.report(claimed_now));
        if claimed_now
            && post
            && let Ok(eligible) = self.eligible()?
        {
            return self.post_request(claimed, eligible);
        }
        Ok(claimed)
    }

    /// `PR_COPILOT_REQUESTS=off` is the consumer's choice for the pull
    /// request, not a passing state: a head whose request record stands
    /// unspent (`requested`, its resend, an `existing` answer) falls back
    /// `cause=off` on the call that reads it, its notice owed in the same
    /// write, as a fresh head under `off` does. A head that already fell
    /// back keeps that fallback and owes no second notice.
    fn fall_back_off(&mut self) -> Step<HeadRecord> {
        let owed = self.notice_for("off", None);
        let path = self.path;
        let (head, now) = self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            if head.fell_back() {
                return Ok((head.clone(), (head, false)));
            }
            head.request = Some(RequestRecord::fallback("off", None));
            head.owe(owed.as_ref());
            Ok((head.clone(), (head, true)))
        })?;
        self.reply.request = head.request.as_ref().map(|q| q.report(now));
        Ok(head)
    }

    /// A standing `requested`, or an `existing-run` that stood for one, read
    /// against GitHub's record of it: Copilot's work in flight, the pending
    /// request among it, or a Copilot review on the head confirms it. Work
    /// that ended with no review of the head, its check completed or
    /// cancelled or the request removed, confirms nothing: an
    /// `existing-run` is claimed as `requested` and sent, a `requested` is
    /// sent once more under its `resent` mark, and a miss after that falls
    /// back `unconfirmed` so the fallback notice goes out. The request is
    /// sent at most twice per head; Copilot's error answer takes its own
    /// retry, sent at most twice (`retry`). A claim and a resend are
    /// requests, so each waits on the head's eligibility (`eligible`): a
    /// call that may not ask sends nothing and leaves the record as it
    /// stands, spending neither.
    fn confirm_request(&mut self, head: HeadRecord) -> Step<HeadRecord> {
        let Some(request) = head.request.clone() else {
            return Ok(head);
        };
        if request.outcome != REQUESTED && !request.stood_for_run() {
            return Ok(head);
        }
        let reviews = self.reviews()?.clone();
        let landed = self.work()?.is_some() || reviews.latest.is_some() || reviews.any_non_error;
        if landed {
            return Ok(head);
        }
        let eligible = if request.resent {
            None
        } else {
            match self.eligible()? {
                Ok(eligible) => Some(eligible),
                Err(_) => return Ok(head),
            }
        };
        let owed = self.notice_for("unconfirmed", None);
        let path = self.path;
        let (head, read) = self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            let read = match &mut head.request {
                Some(request) if request.stood_for_run() => {
                    *request = RequestRecord::new(REQUESTED, None, None, None);
                    Unconfirmed::Claim
                }
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
            if matches!(read, Unconfirmed::FellBack) {
                head.owe(owed.as_ref());
            }
            Ok((head.clone(), (head, read)))
        })?;
        match read {
            Unconfirmed::Claim => {
                self.reply.request = head.request.as_ref().map(|q| q.report(true));
                match eligible {
                    Some(eligible) => self.post_request(head, eligible),
                    None => Ok(head),
                }
            }
            Unconfirmed::Resend => match eligible {
                Some(eligible) => self.post_request(head, eligible),
                None => Ok(head),
            },
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

    /// Why the head may take no Copilot request now, judged before any
    /// claim, resend or POST, a fresh head's and a standing one's alike:
    /// `refresh` where the consumer's refresh policy names the pull request
    /// its refresh head, `off` where `PR_COPILOT_REQUESTS` is `off`, `draft`
    /// where the view's draft this call did not mark ready, or `pulls/N`,
    /// reads it draft; `None` where it may. Judged once per call, over the
    /// `pulls/N` read the call already made, else one read here; a head
    /// that moved between the two reads is `pending head-moved`.
    fn ineligible(&mut self) -> Step<Option<&'static str>> {
        if let Some(judged) = self.eligibility {
            return Ok(judged);
        }
        let policy = policy(&self.r.base_checkout, self.private_env)?;
        let pull = match self.pull.take() {
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
                        .ok_or_else(|| {
                            crate::Error::from(agent_runtime::settings::value_refusal(key, ""))
                        })
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
            Some(other) => {
                return Err(crate::Error::from(agent_runtime::settings::value_refusal(
                    REFRESH_REVIEW_KEY,
                    other,
                ))
                .into());
            }
        };
        let judged = if refresh {
            Some("refresh")
        } else if !self.review.copilot_requests {
            Some("off")
        } else if self.draft || pull.draft == Optional::Present(true) {
            Some("draft")
        } else {
            None
        };
        self.eligibility = Some(judged);
        Ok(judged)
    }

    /// The head's admission to a request on this call, or why it may take
    /// none (`ineligible`): every route asks it before its claim, so a
    /// request the head may not take spends nothing.
    fn eligible(&mut self) -> Step<std::result::Result<Eligible, &'static str>> {
        Ok(match self.ineligible()? {
            None => Ok(Eligible(())),
            Some(cause) => Err(cause),
        })
    }

    /// The gate's one Copilot request POST, the request's and the error
    /// retry's, a claim's and a resend's, on the head's admission. A POST
    /// made drops the call's work read, which knows nothing of it, so the
    /// call's own hold reads the request it made.
    fn post(&mut self, _admitted: Eligible) -> Step<Acted> {
        self.asked = true;
        let acted = review::request_review(&self.gh, &self.r.repo, self.r.pr)?;
        if matches!(acted, Acted::Made) {
            self.work = None;
        }
        Ok(acted)
    }

    /// The request's POST, its claim standing; a refusal rewrites the
    /// request, and the retry claimed in the same write, as refused.
    fn post_request(&mut self, claimed: HeadRecord, admitted: Eligible) -> Step<HeadRecord> {
        let exit = match self.post(admitted)? {
            Acted::Made => return Ok(claimed),
            Acted::Refused { exit, .. } => exit,
        };
        let owed = self.notice_for("refused", Some(exit));
        let path = self.path;
        let head = self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            head.request = Some(RequestRecord::fallback("refused", Some(exit)));
            head.owe(owed.as_ref());
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
    /// the request. A head held as a draft takes no retry: the call that
    /// releases it decides the retry with its request, so at most one POST
    /// goes out. A request the refresh policy held back holds the retry back
    /// too, its cause the verdict's; Copilot's work already in flight stands
    /// for the retry; a `requested` retry GitHub shows no sign of is sent once more; and a
    /// second error answer after the retry is the verdict. Its claim and its
    /// resend wait on the head's eligibility (`eligible`) as the request's
    /// do: on a head that may take no request now nothing is claimed or sent.
    fn retry(
        &mut self,
        record: &HeadRecord,
        error_id: u64,
        error_at: &str,
    ) -> Step<Option<Verdict>> {
        if record.held_as_draft() {
            return Ok(None);
        }
        let Some(retry) = record.retry.clone() else {
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
                if self.set_retry(
                    |standing| standing.is_none().then(|| fallback.clone()),
                    None,
                )? {
                    return Ok(Some(Verdict::new(
                        "copilot-error",
                        format!("copilot-error cause={cause}"),
                    )));
                }
                return Ok(None);
            }
            if self.work()?.is_some() {
                let existing = RetryRecord::new(error_id, EXISTING);
                self.set_retry(
                    |standing| standing.is_none().then(|| existing.clone()),
                    None,
                )?;
                return Ok(None);
            }
            let Ok(admitted) = self.eligible()? else {
                return Ok(None);
            };
            let fresh = RetryRecord::new(error_id, REQUESTED);
            if self.set_retry(|standing| standing.is_none().then(|| fresh.clone()), None)? {
                return self.post_retry(fresh, admitted);
            }
            return Ok(None);
        };
        if retry.outcome != FALLBACK && retry.review_id != error_id {
            let owed = self.notice_for("error", None);
            self.set_retry(
                |_| Some(retry.clone().fallback("error", None)),
                owed.as_ref(),
            )?;
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
        if retry.resent {
            let cause = "unconfirmed";
            let owed = self.notice_for(cause, None);
            self.set_retry(
                |standing| standing.map(|r| r.fallback(cause, None)),
                owed.as_ref(),
            )?;
            return Ok(Some(Verdict::new(
                "copilot-error",
                format!("copilot-error cause={cause}"),
            )));
        }
        let Ok(admitted) = self.eligible()? else {
            return Ok(None);
        };
        let resent = RetryRecord {
            resent: true,
            ..retry.clone()
        };
        let claimed = self.set_retry(
            |standing| (standing.as_ref() == Some(&retry)).then(|| resent.clone()),
            None,
        )?;
        if claimed {
            return self.post_retry(resent, admitted);
        }
        Ok(None)
    }

    /// The retry's POST, its claim standing; a refusal is the verdict.
    fn post_retry(&mut self, retry: RetryRecord, admitted: Eligible) -> Step<Option<Verdict>> {
        let exit = match self.post(admitted)? {
            Acted::Made => return Ok(None),
            Acted::Refused { exit, .. } => exit,
        };
        let cause = format!("refused exit={exit}");
        let owed = self.notice_for("refused", Some(exit));
        self.set_retry(
            |_| Some(retry.clone().fallback(&cause, Some(exit))),
            owed.as_ref(),
        )?;
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
    /// until the request that releases it starts one. Copilot's work in
    /// flight within its hold keeps the period's answers `pending` as it
    /// keeps a verdict that permits a merge, since a caller may arm the
    /// merge on either; a refused request's note stands before it.
    fn period(&mut self, record: &HeadRecord, engaged: usize) -> Step<Verdict> {
        let held = self.hold(Some(record))?;
        if record.held_as_draft() {
            return Err(Stop::Pending("request-fallback cause=draft".into()));
        }
        if let Some(remaining) = held
            && self.note.is_none()
        {
            return Err(Stop::Pending(self.copilot_pending(remaining)));
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
            return Err(Stop::Pending(self.copilot_pending(remaining)));
        }
        Ok(verdict)
    }

    /// The pending reason of Copilot's work held with `remaining` seconds
    /// left, its run as the hold wrote it to the reply.
    fn copilot_pending(&self, remaining: u64) -> String {
        let run = self
            .reply
            .copilot
            .as_ref()
            .and_then(|c| c.run)
            .unwrap_or_default();
        format!("copilot-pending run={run} remaining={remaining}")
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

    /// Write the head's retry as `f` answers it from the standing one, and
    /// `owed` with it; answers whether `f` wrote one.
    fn set_retry(
        &self,
        f: impl Fn(Option<RetryRecord>) -> Option<RetryRecord>,
        owed: Option<&Notice>,
    ) -> Result<bool> {
        let path = self.path;
        self.update_head(|standing| {
            let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
            let Some(retry) = f(head.retry.clone()) else {
                return Ok((head, false));
            };
            head.retry = Some(retry);
            head.owe(owed);
            Ok((head, true))
        })
    }

    /// The notice a fallback with `cause` owes the lane's overseer, as the
    /// record holds it: its first line, `owed`. A `draft` fallback is the
    /// head waiting on its own ready mark and a `refresh` head takes the
    /// overseer's refresh route, so neither owes one; nor does an item
    /// with no launch marker, which runs in no lane. A marker that cannot
    /// be read may be a lane's, so the notice is owed and a later call's
    /// send reads the marker again.
    fn notice_for(&mut self, cause: &str, exit: Option<i32>) -> Option<Notice> {
        if matches!(cause, "draft" | "refresh") {
            return None;
        }
        match self.lane_root() {
            Reading::Gone => return None,
            Reading::Live(_) | Reading::Unreadable { .. } => {}
        }
        let mut text = format!(
            "{NOTICE_KEY} PR #{} head {} cause={cause}",
            self.r.pr, self.view.head
        );
        if let Some(exit) = exit {
            text.push_str(&format!(" exit={exit}"));
        }
        Some(Notice {
            key: NOTICE_KEY.to_owned(),
            text,
            to: self.item.clone(),
            owner: agent_runtime::intent::NOTICE_OWED.to_owned(),
        })
    }

    /// The lane's root, as the launch marker for the item names it under the
    /// common git directory of the checkout the call runs in, where the
    /// launch writes it (`marker::read_from`): the turn-end hook's own
    /// reading of whether the item runs in a lane, from the lane's worktree
    /// and the main checkout alike.
    fn lane_root(&mut self) -> Reading<PathBuf> {
        if let Some(read) = &self.lane {
            return read.clone();
        }
        let read = match self.item.as_deref() {
            Some(item) if marker::item_name(item).is_ok() => {
                marker::read_from(&self.checkout, item).map(PathBuf::from)
            }
            Some(_) | None => Reading::Gone,
        };
        self.lane = Some(read.clone());
        read
    }

    /// Send each notice the head's record still owes, whichever call's
    /// write owed it, and mark it: an `owed` one, and an `unanswered` one
    /// once more, whose second send with no answer is final as `unsent`.
    /// The send follows the write that owed it, so a send whose answer or
    /// mark is lost leaves the notice for the next call; the mailbox reads a
    /// repeat of the notice's delivery key as the notice that landed. A lane
    /// whose marker is gone by
    /// the send marks the notice unsent; one that cannot be read leaves it
    /// as it stands.
    fn deliver_notices(&mut self) -> Result<()> {
        let snapshot = loaded(self.path)?;
        let Some(head) = head_record(self.path, &snapshot.doc, &self.view.head)? else {
            return Ok(());
        };
        let mut reports = Vec::with_capacity(head.notices.len());
        for (index, notice) in head.notices.into_iter().enumerate() {
            let standing = |sent_now, unmarked| NoticeReport {
                notice: notice.text.clone(),
                owner: notice.owner.clone(),
                sent_now,
                unmarked,
            };
            if !notice.owed() && !notice.unanswered() {
                reports.push(standing(false, None));
                continue;
            }
            let (mark, sent_now) = match self.lane_root() {
                Reading::Live(root) => (self.send_fallback_notice(&root, &notice, index), true),
                Reading::Gone => ("unsent:lane-gone".to_owned(), false),
                Reading::Unreadable { .. } => {
                    reports.push(standing(false, None));
                    continue;
                }
            };
            let mark = if notice.unanswered()
                && mark.starts_with(agent_runtime::intent::NOTICE_UNANSWERED)
            {
                format!("unsent:{mark}")
            } else {
                mark
            };
            let path = self.path;
            let marked = self.update_head(|standing| {
                let mut head = standing.ok_or_else(|| shape(path, "heads"))?;
                if let Some(held) = head
                    .notices
                    .iter_mut()
                    .find(|n| n.text == notice.text && n.owner == notice.owner)
                {
                    held.owner = mark.clone();
                }
                Ok((head, ()))
            });
            reports.push(match marked {
                Ok(()) => NoticeReport {
                    owner: mark,
                    ..standing(sent_now, None)
                },
                Err(e) => standing(sent_now, Some(e.key().to_owned())),
            });
        }
        self.reply.notices = reports;
        Ok(())
    }

    /// Send `notice` into the lane's mailbox at `root`, its second line the
    /// lane's status file there, under the notice's first line as its
    /// delivery key, which no other notice of the head carries, and answer
    /// the mark the send earns: `sent` on the receipt or the program's repeat
    /// refusal; `unsent:<cause>` where the refusal wrote nothing;
    /// `unanswered:<cause>` on any other, since the append may stand. The
    /// text file is this call's own, created exclusively and removed after.
    fn send_fallback_notice(&self, root: &Path, notice: &Notice, index: usize) -> String {
        use std::io::Write;
        let item = self.item.as_deref().unwrap_or_default();
        if let Err(e) = std::fs::create_dir_all(&self.notice_dir) {
            return format!("unsent:notice-dir:{e}");
        }
        let file = self
            .notice_dir
            .join(format!("{item}.{}.{index}.notice", self.nonce));
        let status = crate::state::status_file(root, item);
        let mut handle = match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&file)
        {
            Ok(handle) => handle,
            Err(e) => return format!("unsent:notice-write:{e}"),
        };
        let text = format!("{}\n{}\n", notice.text, status.display());
        if let Err(e) = handle.write_all(text.as_bytes()) {
            let _ = std::fs::remove_file(&file);
            return format!("unsent:notice-write:{e}");
        }
        drop(handle);
        let mark = match self.mail.notice(item, root, &file, Some(&notice.text)) {
            Ok(Noticed::Sent { .. } | Noticed::Repeated { .. }) => "sent".to_owned(),
            Err(refusal) if refusal.wrote_nothing() => format!("unsent:{refusal}"),
            Err(refusal) => format!("{}{refusal}", agent_runtime::intent::NOTICE_UNANSWERED),
        };
        let _ = std::fs::remove_file(&file);
        mark
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
    record::reread(
        || {
            let snapshot = loaded(path)?;
            let mut doc = snapshot.doc.clone();
            let out = f(&mut doc)?;
            record::store(path, &snapshot.doc, &doc, locking)?;
            Ok(out)
        },
        Error::key,
    )
}

fn shape(path: &Path, field: &str) -> Error {
    Error::Runtime(agent_runtime::Error::RecordShape {
        path: path.to_path_buf(),
        field: format!("{REVIEW_KEY}/{field}"),
        reason: ShapeReason::TypeMismatch,
        cause: "not the review record's shape".into(),
    })
}

fn review_mut<'a>(path: &Path, doc: &'a mut Document) -> Result<&'a mut Document> {
    if matches!(doc.get(REVIEW_KEY), None | Some(Value::Null)) {
        doc.insert(REVIEW_KEY.into(), Value::Object(Map::new()));
    }
    Ok(record::object_mut(path, doc, REVIEW_KEY)?)
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

/// The location of a blocker of kind regression-against-main standing open
/// on `escalated_items`: one a fix has not cleared and the review did not
/// skip.
fn regression_blocker(path: &Path, doc: &Document) -> Result<Option<String>> {
    let items: Vec<Value> = record::field(path, doc, "escalated_items")?.unwrap_or_default();
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
