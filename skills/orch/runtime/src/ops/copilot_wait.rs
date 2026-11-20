//! The current-head Copilot wait: a read that waits while Copilot's work on
//! a pull request's head is in flight, bounded from its own start, and
//! answers `none`, `settled` or `expired`. It requests nothing and writes
//! nothing, so a triage read can wait on Copilot's review before it reads
//! the threads, under either gate mode, without the review gate's acts.

use std::path::Path;
use std::time::Duration;

use serde::Serialize;

use crate::error::{Error, Result};
use crate::settings::{self, ReviewSettings};
use crate::verify::review::{self, Flight};
use crate::verify::{self, Gh, Unreadable};
use agent_runtime::clock::Clock;

/// How long the wait sleeps between reads of Copilot's work.
pub const POLL: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
pub struct CopilotWait {
    /// `owner/name`.
    pub repo: String,
    pub pr: u64,
    /// `ORCH_COPILOT_HOLD_SECS`, counted from this wait's start.
    pub bound: Duration,
}

/// The wait's answer. `status` is `complete` with `state` `none` (no
/// Copilot work on the head), `settled` (work this wait saw ended, or a
/// running check Copilot's review of the head answered, `review` naming
/// that review where one stands) or `expired` (work still in flight at the
/// bound), or `unreadable` with the read's `reason`, never `none`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CopilotWaited {
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<&'static str>,
    pub repo: String,
    pub pr: u64,
    pub head: Option<String>,
    pub review: Option<u64>,
    pub run: Option<u64>,
    pub started_at: Option<String>,
    pub waited: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// `ORCH_COPILOT_HOLD_SECS` as the settings carry it, the one reader of
/// the setting, this wait's bound and the review gate's hold alike: whole
/// seconds above zero written with no sign and no leading zero, else the
/// setting's refusal.
pub fn bound(settings: &ReviewSettings) -> Result<Duration> {
    let text = settings.copilot_hold.as_str();
    let plain = text
        .as_bytes()
        .first()
        .is_some_and(|b| (b'1'..=b'9').contains(b))
        && text.bytes().all(|b| b.is_ascii_digit());
    match text.parse::<u64>() {
        Ok(secs) if plain => Ok(Duration::from_secs(secs)),
        Ok(_) | Err(_) => Err(crate::Error::from(agent_runtime::settings::value_refusal(
            settings::COPILOT_HOLD_SECS_KEY,
            text,
        ))),
    }
}

/// One run of the wait over `gh`. The request's forms refuse before any
/// read. Each pass reads the head, then Copilot's flight on it; a head that
/// moved drops the work seen on the one before and is read again within the
/// same bound. A wait that ends on no work reads the head once more, and a
/// moved head is read again within the bound.
pub fn run(r: &CopilotWait, gh_program: &Path, clock: &dyn Clock) -> Result<CopilotWaited> {
    run_with(r, &Gh::new(gh_program), clock)
}

/// The function's caller builds the `gh` handle, so a wait can read GitHub
/// under a credential the caller loaded, such as the overseer app's file
/// token, rather than the one this process's environment holds.
#[allow(
    clippy::disallowed_methods,
    reason = "the current-head wait reads its own bound and sleeps between its reads on the clock it is given; it reads GitHub through gh and writes nothing"
)]
pub(crate) fn run_with(r: &CopilotWait, gh: &Gh, clock: &dyn Clock) -> Result<CopilotWaited> {
    verify::validate_repo(&r.repo)?;
    if r.pr == 0 {
        return Err(Error::VerifyRequestInvalid {
            field: "pr",
            value: r.pr.to_string(),
        });
    }
    let start = clock.now();
    let waited = || clock.now().saturating_duration_since(start);
    let mut answer = CopilotWaited {
        status: "complete",
        state: None,
        repo: r.repo.clone(),
        pr: r.pr,
        head: None,
        review: None,
        run: None,
        started_at: None,
        waited: 0,
        reason: None,
        detail: None,
    };
    let failed = |mut answer: CopilotWaited, cause: verify::Cause, waited: Duration| {
        let cause = Unreadable::from(cause);
        answer.status = "unreadable";
        answer.reason = Some(cause.reason);
        answer.detail = cause.detail;
        answer.waited = waited.as_secs();
        answer
    };
    loop {
        let head = match review::view(gh, &r.repo, r.pr) {
            Ok(view) => view.head,
            Err(cause) => return Ok(failed(answer, cause, waited())),
        };
        if answer.head.as_deref() != Some(head.as_str()) {
            answer.run = None;
            answer.started_at = None;
            answer.head = Some(head.clone());
        }
        let flight = match review::copilot_flight(gh, &r.repo, r.pr, &head) {
            Ok(flight) => flight,
            Err(cause) => return Ok(failed(answer, cause, waited())),
        };
        let spent = waited();
        let (state, review) = match flight {
            Flight::Work(work) => {
                answer.run = Some(work.id);
                answer.started_at = work.started_at;
                if spent >= r.bound {
                    answer.state = Some("expired");
                    answer.waited = spent.as_secs();
                    return Ok(answer);
                }
                clock.sleep(POLL.min(r.bound - spent));
                continue;
            }
            Flight::Settled { check, review } => {
                answer.run = Some(check.id);
                answer.started_at = check.started_at;
                ("settled", Some(review))
            }
            Flight::None if answer.run.is_some() => {
                let reviews = match review::copilot_reviews(gh, &r.repo, r.pr, &head) {
                    Ok(reviews) => reviews,
                    Err(cause) => return Ok(failed(answer, cause, waited())),
                };
                ("settled", reviews.latest.map(|latest| latest.id))
            }
            Flight::None => ("none", None),
        };
        let confirmed = match review::view(gh, &r.repo, r.pr) {
            Ok(view) => view.head,
            Err(cause) => return Ok(failed(answer, cause, waited())),
        };
        if confirmed == head {
            answer.state = Some(state);
            answer.review = review;
            answer.waited = spent.as_secs();
            return Ok(answer);
        }
        if spent >= r.bound {
            answer.state = Some("expired");
            answer.head = Some(confirmed);
            answer.run = None;
            answer.started_at = None;
            answer.waited = spent.as_secs();
            return Ok(answer);
        }
    }
}
