//! The `verify-review` operation: the review gate's verdict on a pull
//! request's current head, read then recorded, one call per read set. The
//! gate mode a base's rules set is resolved on the first call and recorded
//! on the item as its floor; the Copilot request is the operation's one
//! effect, claimed under the head's key before the POST and read after;
//! Copilot's work in flight is bounded by `ORCH_COPILOT_HOLD_SECS` from
//! that key's stamp, and the reviewer's silence by `PR_REVIEW_WAIT_SECS`
//! per period, each `timeout` ending one period and counted. The workflow
//! repeats the call under its own budget: `pending` and `unreadable` are
//! results, never verdicts, as `verify-pr` answers them.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{Env, loaded, reread};
use crate::error::{Error, Result, ShapeReason};
use crate::settings::{self, ReviewSettings, Settings};
use crate::state::{self, Document, Locking};
use crate::verify::review::{self, Acted, CopilotReviews, GateMode, Work};
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
    /// Whether this call wrote the record: the once-per-head cue the
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

/// The reply of one `verify-review` call.
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

/// The head's record under `pr_review.heads`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct HeadRecord {
    at: String,
    period_started: String,
    timeouts: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ready: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    request: Option<RequestRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    retry: Option<RetryRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RequestRecord {
    outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cause: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    exit: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RetryRecord {
    review_id: u64,
    outcome: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cause: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    exit: Option<i32>,
}

impl RequestRecord {
    fn requested() -> RequestRecord {
        RequestRecord {
            outcome: "requested".into(),
            reason: None,
            cause: None,
            exit: None,
        }
    }

    fn existing(reason: &str) -> RequestRecord {
        RequestRecord {
            outcome: "existing".into(),
            reason: Some(reason.to_owned()),
            cause: None,
            exit: None,
        }
    }

    fn fallback(cause: &str, exit: Option<i32>) -> RequestRecord {
        RequestRecord {
            outcome: "fallback".into(),
            reason: None,
            cause: Some(cause.to_owned()),
            exit,
        }
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

/// Read the pull request, refuse one that is not open, resolve or read the
/// gate mode, judge the reviewers' state on the head, make the one request
/// the head still owes, and record the verdict on the item at `path`. The
/// request's forms refuse before any read; a missing record refuses before
/// any network read.
#[allow(
    clippy::disallowed_methods,
    reason = "the verify-review operation's one record read before GitHub, its reads of the pull request and its one request through gh, and its writes under the record's write check"
)]
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
    let gh = Gh;
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
    let mut reply = ReviewVerified {
        head: Some(view.head.clone()),
        base: Some(view.base.clone()),
        ..reply
    };
    let now = env.now_secs;
    let stamp = env.iso();

    // The gate mode: recorded once, read on every later call.
    let mode = match recorded_mode(path, &snapshot.doc)? {
        Some(mode) => mode,
        None => {
            let policy = policy(&r.base_checkout)?;
            let mode = match policy.get(GATE_MODE_KEY).map(String::as_str) {
                None | Some("enforce") => match review::gate_mode(&gh, &r.repo, &view.base) {
                    Ok(mode) => mode,
                    Err(cause) => return Ok(reply.unreadable(cause.into())),
                },
                Some("off") => GateMode::Off,
                Some(other) => return Err(settings::value_refusal(GATE_MODE_KEY, other)),
            };
            let (base, at) = (view.base.clone(), stamp.clone());
            write(path, locking, |doc| {
                let record = review_mut(path, doc)?;
                if let Some(standing) = record.get("mode").and_then(Value::as_str) {
                    return GateMode::parse(standing).ok_or_else(|| shape(path, "mode"));
                }
                record.insert("mode".into(), json!(mode.word()));
                record.insert("mode_at".into(), json!(at));
                record.insert("base".into(), json!(base));
                Ok(mode)
            })?
        }
    };
    reply.mode = Some(mode.word().to_owned());

    // The ready mark comes under either mode: a push-first draft is made
    // ready by its early request, which the gate's mode does not gate.
    let mut record = head_record(path, &snapshot.doc, &view.head)?;
    let mut draft = view.draft;
    if record.is_none() && r.mark_ready && draft {
        let fresh = HeadRecord {
            at: stamp.clone(),
            period_started: stamp.clone(),
            timeouts: 0,
            ready: Some("marking".into()),
            request: None,
            retry: None,
        };
        let head = view.head.clone();
        let fresh = write(path, locking, |doc| {
            let heads = heads_mut(path, doc)?;
            match heads.get(&head) {
                Some(standing) => serde_json::from_value::<HeadRecord>(standing.clone())
                    .map_err(|_| shape(path, "heads")),
                None => {
                    heads.insert(head.clone(), serde_json::to_value(&fresh)?);
                    Ok(fresh.clone())
                }
            }
        })?;
        match review::mark_ready(&gh, &r.repo, r.pr) {
            Ok(Acted::Made) => {}
            Ok(Acted::Refused { detail, .. }) => {
                return Ok(reply.unreadable(Unreadable {
                    reason: "ready-failed".into(),
                    detail: Some(detail),
                }));
            }
            Err(cause) => return Ok(reply.unreadable(cause.into())),
        }
        let after = match review::view(&gh, &r.repo, r.pr) {
            Ok(after) => after,
            Err(cause) => return Ok(reply.unreadable(cause.into())),
        };
        if after.head != view.head {
            return Ok(reply.pending(format!("ready-head-moved head={}", after.head)));
        }
        if after.draft {
            return Ok(reply.unreadable(Unreadable {
                reason: "ready-unconfirmed".into(),
                detail: None,
            }));
        }
        draft = false;
        record = Some(fresh);
    }
    if mode == GateMode::Off {
        return record_verdict(
            path, locking, reply, &view.head, "off", "gate off", &stamp, None,
        );
    }

    // The reviewers' state on the head, routed before any request.
    let unresolved = match review::unresolved_threads(&gh, &r.repo, r.pr) {
        Ok(count) => count,
        Err(cause) => return Ok(reply.unreadable(cause.into())),
    };
    let mut copilot: Option<CopilotReviews> = None;
    if review::copilot_reviewed(&view) {
        copilot = match review::copilot_reviews(&gh, &r.repo, r.pr, &view.head) {
            Ok(reviews) => Some(reviews),
            Err(cause) => return Ok(reply.unreadable(cause.into())),
        };
    }
    let judged = review::judge(&view, copilot.as_ref());
    reply.review_decision = Some(judged.decision.clone());
    reply.approvals = Some(judged.approvals);
    reply.changes_requested = Some(judged.changes_requested);
    reply.unresolved_count = Some(unresolved);
    let blocker = regression_blocker(path, &snapshot.doc)?;
    let approved_or = |reply: ReviewVerified, verdict: &str, reason: String| match &blocker {
        Some(location) => record_verdict(
            path,
            locking,
            reply,
            &view.head,
            "blocked",
            &format!("regression-open location={location}"),
            &stamp,
            None,
        ),
        None => record_verdict(
            path, locking, reply, &view.head, verdict, &reason, &stamp, None,
        ),
    };
    if judged.approved && unresolved == 0 {
        let reason = format!(
            "decision={} approvals={} unresolved={unresolved}",
            judged.decision, judged.approvals
        );
        return approved_or(reply, "approved", reason);
    }
    if !judged.approved && (judged.decision == "CHANGES_REQUESTED" || judged.changes_requested > 0)
    {
        let reason = format!(
            "changes_requested={} unresolved={unresolved}",
            judged.changes_requested
        );
        return record_verdict(
            path,
            locking,
            reply,
            &view.head,
            "changes_requested",
            &reason,
            &stamp,
            None,
        );
    }
    if unresolved > 0 {
        let reason = format!("unresolved={unresolved} decision={}", judged.decision);
        return record_verdict(
            path, locking, reply, &view.head, "comments", &reason, &stamp, None,
        );
    }

    // The head's record: the request the head owes, claimed once.
    let mut work_read: Option<Option<Work>> = None;
    let mut recorded_now = false;
    let mut record = match record {
        Some(record) if record.request.is_some() => record,
        standing => {
            let mut fresh = standing.unwrap_or(HeadRecord {
                at: stamp.clone(),
                period_started: stamp.clone(),
                timeouts: 0,
                ready: None,
                request: None,
                retry: None,
            });
            let policy = policy(&r.base_checkout)?;
            let pull = match review::pull(&gh, &r.repo, r.pr) {
                Ok(pull) => pull,
                Err(cause) => return Ok(reply.unreadable(cause.into())),
            };
            if pull.head.sha != view.head {
                return Ok(reply.pending(format!("head-moved head={}", pull.head.sha)));
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
                Some(other) => return Err(settings::value_refusal(REFRESH_REVIEW_KEY, other)),
            };
            // An error answer standing on the head makes this request its
            // one retry: claimed in the same write, so no second POST follows.
            let mut retry = None;
            let request = if refresh {
                RequestRecord::fallback("refresh", None)
            } else if !review.copilot_requests {
                RequestRecord::fallback("off", None)
            } else if draft || pull.draft {
                RequestRecord::fallback("draft", None)
            } else {
                let reviews = match copilot.clone() {
                    Some(reviews) => reviews,
                    None => match review::copilot_reviews(&gh, &r.repo, r.pr, &view.head) {
                        Ok(reviews) => reviews,
                        Err(cause) => return Ok(reply.unreadable(cause.into())),
                    },
                };
                let work = match review::copilot_work(&gh, &r.repo, r.pr, &view.head) {
                    Ok(work) => work,
                    Err(cause) => return Ok(reply.unreadable(cause.into())),
                };
                work_read = Some(work.clone());
                let released = released_retry(path, &snapshot.doc, &view.head)?;
                if reviews
                    .latest
                    .as_ref()
                    .is_some_and(|latest| latest.no_files)
                {
                    RequestRecord::fallback("no-files", None)
                } else if released.as_deref() == Some("requested") {
                    RequestRecord::existing("existing-error-retry")
                } else if released.as_deref() == Some("fallback") {
                    RequestRecord::fallback("error", None)
                } else if work.is_some() {
                    RequestRecord::existing("existing-run")
                } else if reviews.any_non_error {
                    RequestRecord::existing("existing-review")
                } else {
                    retry = reviews
                        .latest
                        .as_ref()
                        .filter(|latest| latest.error)
                        .map(|latest| RetryRecord {
                            review_id: latest.id,
                            outcome: "requested".into(),
                            cause: None,
                            exit: None,
                        });
                    RequestRecord::requested()
                }
            };
            let post = request.outcome == "requested";
            fresh.request = Some(request);
            fresh.retry = retry;
            let head = view.head.clone();
            let claimed = write(path, locking, |doc| {
                let heads = heads_mut(path, doc)?;
                match heads.get(&head) {
                    Some(standing) => {
                        let standing: HeadRecord = serde_json::from_value(standing.clone())
                            .map_err(|_| shape(path, "heads"))?;
                        if standing.request.is_some() {
                            return Ok((standing, false));
                        }
                        let merged = HeadRecord {
                            request: fresh.request.clone(),
                            retry: fresh.retry.clone(),
                            ..standing
                        };
                        heads.insert(head.clone(), serde_json::to_value(&merged)?);
                        Ok((merged, true))
                    }
                    None => {
                        heads.insert(head.clone(), serde_json::to_value(&fresh)?);
                        Ok((fresh.clone(), true))
                    }
                }
            })?;
            let (claimed, claimed_now) = claimed;
            recorded_now = claimed_now;
            if claimed_now && post {
                match review::request_review(&gh, &r.repo, r.pr) {
                    Ok(Acted::Made) => {}
                    Ok(Acted::Refused { exit, .. }) => {
                        let refused = RequestRecord::fallback("refused", exit);
                        let head = view.head.clone();
                        let standing = write(path, locking, |doc| {
                            let heads = heads_mut(path, doc)?;
                            let mut standing: HeadRecord = heads
                                .get(&head)
                                .cloned()
                                .map(serde_json::from_value)
                                .transpose()
                                .map_err(|_| shape(path, "heads"))?
                                .ok_or_else(|| shape(path, "heads"))?;
                            standing.request = Some(refused.clone());
                            heads.insert(head.clone(), serde_json::to_value(&standing)?);
                            Ok(standing)
                        })?;
                        reply.request = standing.request.as_ref().map(|q| q.report(true));
                        let reason = format!(
                            "request-refused exit={}",
                            exit.map_or("none".to_owned(), |e| e.to_string())
                        );
                        return finish(
                            path, locking, reply, &view.head, &standing, &review, now, &stamp,
                            &judged, reason, work_read, &gh, r,
                        );
                    }
                    Err(cause) => return Ok(reply.unreadable(cause.into())),
                }
            }
            claimed
        }
    };
    reply.request = record.request.as_ref().map(|q| q.report(recorded_now));

    // Copilot's error answer: one retry per head, claimed before its request.
    let error = copilot
        .as_ref()
        .and_then(|reviews| reviews.latest.as_ref())
        .filter(|latest| latest.error)
        .map(|latest| latest.id);
    if let Some(error_id) = error
        && review.copilot_requests
    {
        match &record.retry {
            None => {
                let retry = RetryRecord {
                    review_id: error_id,
                    outcome: "requested".into(),
                    cause: None,
                    exit: None,
                };
                let head = view.head.clone();
                let claimed = write(path, locking, |doc| {
                    let heads = heads_mut(path, doc)?;
                    let mut standing: HeadRecord = heads
                        .get(&head)
                        .cloned()
                        .map(serde_json::from_value)
                        .transpose()
                        .map_err(|_| shape(path, "heads"))?
                        .ok_or_else(|| shape(path, "heads"))?;
                    if standing.retry.is_some() {
                        return Ok(false);
                    }
                    standing.retry = Some(retry.clone());
                    heads.insert(head.clone(), serde_json::to_value(&standing)?);
                    Ok(true)
                })?;
                if claimed {
                    record.retry = Some(retry);
                    match review::request_review(&gh, &r.repo, r.pr) {
                        Ok(Acted::Made) => {}
                        Ok(Acted::Refused { exit, .. }) => {
                            let cause = format!(
                                "refused exit={}",
                                exit.map_or("none".to_owned(), |e| e.to_string())
                            );
                            record_retry_fallback(path, locking, &view.head, &cause, exit)?;
                            let reason = format!("copilot-error cause={cause}");
                            return record_verdict(
                                path,
                                locking,
                                reply,
                                &view.head,
                                "copilot-error",
                                &reason,
                                &stamp,
                                None,
                            );
                        }
                        Err(cause) => return Ok(reply.unreadable(cause.into())),
                    }
                }
            }
            Some(retry) if retry.outcome != "fallback" && retry.review_id != error_id => {
                record_retry_fallback(path, locking, &view.head, "error", None)?;
                return record_verdict(
                    path,
                    locking,
                    reply,
                    &view.head,
                    "copilot-error",
                    "copilot-error cause=error",
                    &stamp,
                    None,
                );
            }
            Some(_) => {}
        }
    }

    finish(
        path,
        locking,
        reply,
        &view.head,
        &record,
        &review,
        now,
        &stamp,
        &judged,
        String::new(),
        work_read,
        &gh,
        r,
    )
}

/// Copilot's flight against the hold and the reviewer's silence against
/// the period: `pending` while either budget runs, else the period's
/// verdict, `proceeded` on a silent reviewer under `proceed`, `timeout`
/// otherwise, which ends the period and counts it.
#[allow(
    clippy::too_many_arguments,
    reason = "the one tail of the operation, called from its two exits"
)]
#[allow(
    clippy::disallowed_methods,
    reason = "the verify-review operation's reads of Copilot's work through gh and its verdict write under the record's write check"
)]
fn finish(
    path: &Path,
    locking: Locking,
    mut reply: ReviewVerified,
    head: &str,
    record: &HeadRecord,
    review: &Review,
    now: u64,
    stamp: &str,
    judged: &review::Judged,
    refused: String,
    work_read: Option<Option<Work>>,
    gh: &Gh,
    r: &VerifyReview,
) -> Result<ReviewVerified> {
    let since = clock::epoch_secs(&record.at).ok_or_else(|| shape(path, "heads"))?;
    let work = match work_read {
        Some(work) => work,
        None => match review::copilot_work(gh, &r.repo, r.pr, head) {
            Ok(work) => work,
            Err(cause) => return Ok(reply.unreadable(cause.into())),
        },
    };
    let hold = review.copilot_hold;
    reply.copilot = Some(match work {
        None => CopilotReport {
            state: "none".into(),
            run: None,
            started_at: None,
        },
        Some(work) => CopilotReport {
            state: if now.saturating_sub(since) < hold {
                "pending".into()
            } else {
                "expired".into()
            },
            run: Some(work.id),
            started_at: work.started_at,
        },
    });
    let period = clock::epoch_secs(&record.period_started).ok_or_else(|| shape(path, "heads"))?;
    if now.saturating_sub(period) < review.wait {
        let reason = if refused.is_empty() {
            format!(
                "review-pending copilot={} remaining={}",
                reply.copilot.as_ref().map_or("none", |c| c.state.as_str()),
                review.wait - now.saturating_sub(period)
            )
        } else {
            refused
        };
        return Ok(reply.pending(reason));
    }
    let silent = judged.engaged == 0;
    if review.on_timeout == OnTimeout::Proceed && silent {
        let blocker = regression_blocker(path, &loaded(path)?.doc)?;
        return match blocker {
            Some(location) => record_verdict(
                path,
                locking,
                reply,
                head,
                "blocked",
                &format!("regression-open location={location}"),
                stamp,
                None,
            ),
            None => record_verdict(
                path,
                locking,
                reply,
                head,
                "proceeded",
                &format!("silent after {}s", review.wait),
                stamp,
                None,
            ),
        };
    }
    let reason = format!("engaged={} after {}s", judged.engaged, review.wait);
    record_verdict(
        path,
        locking,
        reply,
        head,
        "timeout",
        &reason,
        stamp,
        Some(head),
    )
}

/// Record the verdict under `pr_review.verdict`; a `timeout` ends the
/// head's period and counts it.
#[allow(
    clippy::too_many_arguments,
    reason = "the one verdict write, called from every complete exit"
)]
fn record_verdict(
    path: &Path,
    locking: Locking,
    mut reply: ReviewVerified,
    head: &str,
    verdict: &str,
    reason: &str,
    stamp: &str,
    period_ends: Option<&str>,
) -> Result<ReviewVerified> {
    let head = head.to_owned();
    let period_ends = period_ends.map(str::to_owned);
    let (verdict, reason, stamp) = (verdict.to_owned(), reason.to_owned(), stamp.to_owned());
    let recorded = write(path, locking, |doc| {
        let record = review_mut(path, doc)?;
        let replaced = !matches!(record.get("verdict"), None | Some(Value::Null));
        record.insert(
            "verdict".into(),
            json!({"head": head, "verdict": verdict, "reason": reason, "at": stamp}),
        );
        if let Some(ending) = &period_ends {
            let heads = heads_mut(path, doc)?;
            let mut standing: HeadRecord = heads
                .get(ending)
                .cloned()
                .map(serde_json::from_value)
                .transpose()
                .map_err(|_| shape(path, "heads"))?
                .ok_or_else(|| shape(path, "heads"))?;
            standing.period_started = stamp.clone();
            standing.timeouts += 1;
            heads.insert(ending.clone(), serde_json::to_value(&standing)?);
        }
        Ok(ReviewRecorded {
            head: head.clone(),
            verdict: verdict.clone(),
            reason: reason.clone(),
            at: stamp.clone(),
            replaced,
        })
    })?;
    reply.status = Status::Complete;
    reply.reason = recorded.reason.clone();
    reply.verdict = Some(recorded.verdict.clone());
    reply.recorded = Some(recorded);
    Ok(reply)
}

fn record_retry_fallback(
    path: &Path,
    locking: Locking,
    head: &str,
    cause: &str,
    exit: Option<i32>,
) -> Result<()> {
    let head = head.to_owned();
    let cause = cause.to_owned();
    write(path, locking, |doc| {
        let heads = heads_mut(path, doc)?;
        let mut standing: HeadRecord = heads
            .get(&head)
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|_| shape(path, "heads"))?
            .ok_or_else(|| shape(path, "heads"))?;
        if let Some(retry) = &mut standing.retry {
            retry.outcome = "fallback".into();
            retry.cause = Some(cause.clone());
            retry.exit = exit;
        }
        heads.insert(head.clone(), serde_json::to_value(&standing)?);
        Ok(())
    })
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

/// The `pr_review` object, made where absent.
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
/// `pr_approval.copilot_error_retries[head]`: its outcome word, where one
/// stands, so a head mid-wait at an upgrade spends no second retry.
fn released_retry(path: &Path, doc: &Document, head: &str) -> Result<Option<String>> {
    let Some(approval) = doc.get("pr_approval") else {
        return Ok(None);
    };
    let Some(retries) = approval.get("copilot_error_retries") else {
        return Ok(None);
    };
    match retries.get(head) {
        None | Some(Value::Null) => Ok(None),
        Some(entry) => entry
            .get("outcome")
            .and_then(Value::as_str)
            .map(|word| Some(word.to_owned()))
            .ok_or_else(|| Error::Shape {
                path: path.to_path_buf(),
                field: "pr_approval/copilot_error_retries".into(),
                reason: ShapeReason::TypeMismatch,
                cause: "outcome is not a word".into(),
            }),
    }
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
    for (key, value) in settings::private_env_file(&base.join(settings::DEFAULT_ENV_FILE))? {
        values.insert(key, value);
    }
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
