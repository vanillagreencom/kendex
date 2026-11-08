//! The review gate's reads for one pull request: the view the verdict is
//! judged over, the gate mode a base's rules set, the pull request object
//! the refresh route compares, Copilot's reviews bound to the head by the
//! timeline's arrival time, the unresolved-thread walk, and the two acts
//! the gate makes through `gh`, the Copilot request and the ready mark.
//! Every read answers a closed wire type or a refusal with its cause; a
//! failed read is never a verdict, a count or an empty requirement.

use serde_json::Value;

pub(crate) use super::Acted;
use super::evidence;
pub(crate) use super::evidence::{Flight, Work};
use super::wire::{
    Branch, ClassicProtection, GraphReply, LatestReview, Nullable, Optional, Protection, Pull,
    PullRequestParameters, PullRequestState, Review, ReviewView, Rule, RuleKind, ThreadsData,
    TimelineEvent,
};
use super::{Cause, Endpoint, Gh, Read, Reader, head_form, refused_by_github, segment};

/// The GitHub login of the Copilot reviewer, as REST spells it with its
/// `[bot]` suffix and as GraphQL actors spell it bare.
pub const COPILOT_REVIEWER: &str = "copilot-pull-request-reviewer";

/// The sentence Copilot's review carries when it could not review.
const COPILOT_ERROR_SENTENCE: &str =
    "Copilot encountered an error and was unable to review this pull request.";

/// The sentence Copilot's review carries when it found no file to review,
/// its apostrophe left out of the match.
const COPILOT_NO_FILES_SENTENCE: &str = "able to review any files in this pull request";

/// The fields the review gate asks `pr view` for, in gh's own names.
const VIEW_FIELDS: &str =
    "headRefOid,baseRefName,state,isDraft,reviewDecision,latestReviews,author";

/// A thread walk past this many pages cannot be verified in one read and
/// refuses rather than reporting the pages it managed.
const THREAD_PAGE_MAX: usize = 20;

const THREADS_QUERY: &str = "query=query($owner: String!, $name: String!, $number: Int!, $cursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { isResolved } } } } }";

/// The gate mode a base sets: `approval` where a review is required,
/// `off` where none is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateMode {
    Approval,
    Off,
}

impl GateMode {
    pub fn word(self) -> &'static str {
        match self {
            GateMode::Approval => "approval",
            GateMode::Off => "off",
        }
    }

    pub fn parse(word: &str) -> Option<GateMode> {
        match word {
            "approval" => Some(GateMode::Approval),
            "off" => Some(GateMode::Off),
            _ => None,
        }
    }
}

/// The pull request as the verdict reads it: the head and base, whether it
/// is open and a draft, the aggregate decision (`""` where the base
/// requires no review), the latest review per reviewer and the author's
/// bare login (gh spells an App `app/<slug>`; the reviews spell it bare).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct View {
    pub head: String,
    pub base: String,
    pub state: PullRequestState,
    pub draft: bool,
    pub decision: String,
    pub latest: Vec<LatestReview>,
    pub author: String,
}

pub(crate) fn view(gh: &Gh, repo: &str, pr: u64) -> Read<View> {
    let endpoint = Endpoint::PullRequest;
    let number = pr.to_string();
    let bytes = gh
        .call(
            endpoint,
            &["pr", "view", &number, "--repo", repo, "--json", VIEW_FIELDS],
        )?
        .printed(endpoint)?;
    let view: ReviewView =
        serde_json::from_slice(&bytes).map_err(|_| Cause::ResponseInvalid(endpoint))?;
    if !head_form(&view.pull.head) || view.pull.base.is_empty() || view.author.login.is_empty() {
        return Err(Cause::ResponseInvalid(endpoint));
    }
    let decision = match view.decision {
        Nullable::Absent => return Err(Cause::ResponseInvalid(endpoint)),
        Nullable::Null => String::new(),
        Nullable::Present(word) => word,
    };
    let author = view
        .author
        .login
        .strip_prefix("app/")
        .unwrap_or(&view.author.login)
        .to_owned();
    Ok(View {
        head: view.pull.head,
        base: view.pull.base,
        state: view.pull.state,
        draft: view.draft,
        decision,
        latest: view.latest,
        author,
    })
}

/// The gate mode the base's rules set under an `enforce` policy: a
/// `pull_request` rule requiring an approval (a general count, code-owner
/// review, last-push approval or a team minimum) is `approval`; else the
/// branch's classic protection, where an enabled protection with a
/// `required_pull_request_reviews` object is `approval`, even at a zero
/// count, and a disabled protection or a null object is `off`. Each read
/// is validated: a failed or malformed one refuses, never `off`.
pub(crate) fn gate_mode(gh: &Gh, repo: &str, base: &str) -> Read<GateMode> {
    let reader = Reader { gh };
    let segment = segment(base);
    let rules: Vec<Rule> = reader.array(
        Endpoint::Rules,
        &format!("repos/{repo}/rules/branches/{segment}"),
    )?;
    if rules.iter().any(|rule| rule.kind == RuleKind::Other) {
        return Err(Cause::ResponseInvalid(Endpoint::Rules));
    }
    for rule in rules {
        if rule.kind != RuleKind::PullRequest {
            continue;
        }
        let parameters = match rule.parameters {
            Optional::Absent => return Err(Cause::ResponseInvalid(Endpoint::Rules)),
            Optional::Present(object) => object,
        };
        let p: PullRequestParameters = serde_json::from_value(Value::Object(parameters))
            .map_err(|_| Cause::ResponseInvalid(Endpoint::Rules))?;
        let flag = |value: Optional<bool>| matches!(value, Optional::Present(true));
        let teams = match p.required_reviewers {
            Optional::Absent => false,
            Optional::Present(teams) => teams.iter().any(|team| team.minimum_approvals >= 1),
        };
        if p.required_approving_review_count >= 1
            || flag(p.require_code_owner_review)
            || flag(p.require_last_push_approval)
            || teams
        {
            return Ok(GateMode::Approval);
        }
    }
    let branch: Branch = reader.object(
        Endpoint::Protection,
        &format!("repos/{repo}/branches/{segment}"),
    )?;
    let enabled = match branch.protection {
        Optional::Present(Protection {
            enabled: Optional::Present(enabled),
            ..
        }) => enabled,
        Optional::Present(_) | Optional::Absent => {
            return Err(Cause::ResponseInvalid(Endpoint::Protection));
        }
    };
    if !enabled {
        return Ok(GateMode::Off);
    }
    let classic: ClassicProtection = reader.object(
        Endpoint::ClassicProtection,
        &format!("repos/{repo}/branches/{segment}/protection"),
    )?;
    Ok(match classic.required_pull_request_reviews {
        Nullable::Absent | Nullable::Null => GateMode::Off,
        Nullable::Present(_) => GateMode::Approval,
    })
}

/// The pull request object, for the refresh route and the draft flag;
/// the gate judges the flag, so an object without it is unreadable.
pub(crate) fn pull(gh: &Gh, repo: &str, pr: u64) -> Read<Pull> {
    let pull: Pull = Reader { gh }.object(Endpoint::Pull, &format!("repos/{repo}/pulls/{pr}"))?;
    if !head_form(&pull.head.sha) || pull.draft.present().is_none() {
        return Err(Cause::ResponseInvalid(Endpoint::Pull));
    }
    Ok(pull)
}

/// Copilot's reviews bound to the head: the arrival time the timeline
/// gives the head (its latest matching force push, else its committed
/// event) binds a review to the delivered head, since GitHub can re-point
/// an older review's commit to a force-pushed commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotReviews {
    /// The latest non-dismissed Copilot review submitted on this head
    /// after it arrived.
    pub latest: Option<CopilotReview>,
    /// Whether any Copilot review on this head after its arrival is not an
    /// error answer: the standing work a request need not repeat.
    pub any_non_error: bool,
    /// When Copilot was last asked for a review of this head: the latest
    /// `review_requested` event naming Copilot at or after the head's
    /// arrival, GitHub's own record that a request landed.
    pub requested_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotReview {
    pub id: u64,
    pub state: String,
    pub submitted_at: String,
    pub error: bool,
    pub no_files: bool,
}

pub(crate) fn copilot_reviews(gh: &Gh, repo: &str, pr: u64, head: &str) -> Read<CopilotReviews> {
    let reader = Reader { gh };
    let reviews: Vec<Review> = reader.array(
        Endpoint::Reviews,
        &format!("repos/{repo}/pulls/{pr}/reviews"),
    )?;
    let events: Vec<TimelineEvent> = reader.array(
        Endpoint::Timeline,
        &format!("repos/{repo}/issues/{pr}/timeline"),
    )?;
    let arrival = arrival(&events, head)?;
    let reviewer = format!("{COPILOT_REVIEWER}[bot]");
    let mut at_head = Vec::new();
    for review in &reviews {
        let by_copilot = match &review.user {
            Nullable::Present(user) => user.login == reviewer,
            Nullable::Absent | Nullable::Null => false,
        };
        let on_head = review.commit_id == Nullable::Present(head.to_owned());
        let formal = matches!(
            review.state.as_str(),
            "APPROVED" | "COMMENTED" | "CHANGES_REQUESTED" | "DISMISSED"
        );
        if !by_copilot || !on_head || !formal {
            continue;
        }
        if !arrival.is_empty() {
            match &review.submitted_at {
                Optional::Present(submitted) if submitted.as_str() > arrival.as_str() => {}
                Optional::Present(_) => continue,
                Optional::Absent => return Err(Cause::ResponseInvalid(Endpoint::Reviews)),
            }
        }
        at_head.push(review);
    }
    let body = |review: &Review| match &review.body {
        Nullable::Present(text) => text.clone(),
        Nullable::Absent | Nullable::Null => String::new(),
    };
    let any_non_error = at_head
        .iter()
        .any(|review| !body(review).contains(COPILOT_ERROR_SENTENCE));
    let latest = at_head
        .iter()
        .rev()
        .find(|review| review.state != "DISMISSED")
        .map(|review| {
            let text = body(review);
            CopilotReview {
                id: review.id,
                state: review.state.clone(),
                submitted_at: match &review.submitted_at {
                    Optional::Present(at) => at.clone(),
                    Optional::Absent => String::new(),
                },
                error: review.state == "COMMENTED" && text.contains(COPILOT_ERROR_SENTENCE),
                no_files: review.state == "COMMENTED" && text.contains(COPILOT_NO_FILES_SENTENCE),
            }
        });
    let mut requested_at: Option<String> = None;
    for event in &events {
        if event.event != "review_requested"
            || !evidence::copilot_actor(event.fields.get("requested_reviewer"))
        {
            continue;
        }
        let created = event
            .fields
            .get("created_at")
            .and_then(Value::as_str)
            .ok_or(Cause::ResponseInvalid(Endpoint::Timeline))?;
        if created >= arrival.as_str() && requested_at.as_deref().is_none_or(|at| created > at) {
            requested_at = Some(created.to_owned());
        }
    }
    Ok(CopilotReviews {
        latest,
        any_non_error,
        requested_at,
    })
}

/// When the head arrived on the pull request: the latest force push that
/// delivered it, else its committed event's committer date, else `""`
/// where the timeline names no arrival.
fn arrival(events: &[TimelineEvent], head: &str) -> Read<String> {
    let invalid = || Cause::ResponseInvalid(Endpoint::Timeline);
    let text = |event: &TimelineEvent, key: &str| -> Read<String> {
        event
            .fields
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(invalid)
    };
    let mut pushes = Vec::new();
    let mut commits = Vec::new();
    for event in events {
        let names = |key: &str| event.fields.get(key).and_then(Value::as_str) == Some(head);
        if event.event == "head_ref_force_pushed" && names("commit_id") {
            pushes.push(text(event, "created_at")?);
        } else if event.event == "committed" && names("sha") {
            let date = event
                .fields
                .get("committer")
                .and_then(|c| c.get("date"))
                .and_then(Value::as_str)
                .ok_or_else(invalid)?;
            commits.push(date.to_owned());
        }
    }
    let latest = if pushes.is_empty() { commits } else { pushes };
    Ok(latest.into_iter().max().unwrap_or_default())
}

/// Copilot's work in flight on the head: a queued or in-progress Copilot
/// check its submitted review of the head has not answered, else a pending
/// timeline request no later Copilot review or removal answered.
pub(crate) fn copilot_work(gh: &Gh, repo: &str, pr: u64, head: &str) -> Read<Option<Work>> {
    evidence::copilot_work(&Reader { gh }, repo, pr, head)
}

/// Copilot's flight on the head as the work reader judges it, for the
/// current-head wait, which reports a settled check apart from no work.
pub(crate) fn copilot_flight(gh: &Gh, repo: &str, pr: u64, head: &str) -> Read<Flight> {
    evidence::copilot_flight(&Reader { gh }, repo, pr, head)
}

/// The unresolved review threads over every page. A partial reply, a
/// malformed page, a non-advancing cursor or a walk past the page bound
/// refuses: an unverifiable read is never "no threads".
pub(crate) fn unresolved_threads(gh: &Gh, repo: &str, pr: u64) -> Read<usize> {
    let endpoint = Endpoint::Threads;
    let invalid = || Cause::ResponseInvalid(endpoint);
    let (owner, name) = repo.split_once('/').ok_or_else(invalid)?;
    let owner = format!("owner={owner}");
    let name = format!("name={name}");
    let number = format!("number={pr}");
    let mut cursor = String::new();
    let mut total = 0;
    for _ in 0..THREAD_PAGE_MAX {
        let after = format!("cursor={cursor}");
        let mut args = vec![
            "api",
            "graphql",
            "-f",
            THREADS_QUERY,
            "-F",
            &owner,
            "-F",
            &name,
            "-F",
            &number,
        ];
        if !cursor.is_empty() {
            args.extend(["-F", after.as_str()]);
        }
        let bytes = gh.call(endpoint, &args)?.printed(endpoint)?;
        let reply: GraphReply<ThreadsData> =
            serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        if matches!(reply.errors, Optional::Present(ref errors) if !errors.is_empty()) {
            return Err(invalid());
        }
        let threads = match reply.data {
            Nullable::Present(data) => match data.repository {
                Nullable::Present(repository) => match repository.pull_request {
                    Nullable::Present(pull) => match pull.review_threads {
                        Nullable::Present(threads) => threads,
                        Nullable::Absent | Nullable::Null => return Err(invalid()),
                    },
                    Nullable::Absent | Nullable::Null => return Err(invalid()),
                },
                Nullable::Absent | Nullable::Null => return Err(invalid()),
            },
            Nullable::Absent | Nullable::Null => return Err(invalid()),
        };
        total += threads.nodes.iter().filter(|t| !t.is_resolved).count();
        if !threads.page_info.has_next_page {
            return Ok(total);
        }
        let next = match threads.page_info.end_cursor {
            Nullable::Present(next) if !next.is_empty() && next != cursor => next,
            Nullable::Present(_) | Nullable::Absent | Nullable::Null => return Err(invalid()),
        };
        cursor = next;
    }
    Err(invalid())
}

/// Ask Copilot for a review of the pull request: the one POST the gate
/// makes. A refusal is GitHub's own: a failed call whose stderr carries
/// gh's status line for a 4xx reply (`refused_by_github`). Any other
/// failure, a transport failure (`error connecting to <host>`, recorded
/// from gh 2.103.3), a 5xx or a call that could not be made, may or may
/// not have reached GitHub, so it is the read's failure and the request's
/// claim stands for the confirmation.
pub(crate) fn request_review(gh: &Gh, repo: &str, pr: u64) -> Read<Acted> {
    let path = format!("repos/{repo}/pulls/{pr}/requested_reviewers");
    let reviewer = format!("reviewers[]={COPILOT_REVIEWER}[bot]");
    match gh.act(
        Endpoint::RequestReview,
        &["api", &path, "--method", "POST", "-f", &reviewer],
    )? {
        Acted::Refused { detail, .. } if !refused_by_github(&detail) => Err(Cause::ReadFailed {
            endpoint: Endpoint::RequestReview,
            detail,
        }),
        acted => Ok(acted),
    }
}

/// Mark an open draft ready for review: GitHub exposes the transition
/// through GraphQL alone, which `gh pr ready` sends.
pub(crate) fn mark_ready(gh: &Gh, repo: &str, pr: u64) -> Read<Acted> {
    let number = pr.to_string();
    gh.act(Endpoint::Ready, &["pr", "ready", &number, "--repo", repo])
}

/// The verdict rule over the view, with Copilot's latest review on the head
/// put in place of its `latestReviews` row: an approval is the aggregate
/// `APPROVED`, or, with no aggregate, an approving latest review and no
/// standing `CHANGES_REQUESTED`; an aggregate verdict a re-pointed Copilot
/// review carried falls to `REVIEW_REQUIRED`. A reviewer is engaged by any
/// formal latest review that is not the author's, so a reviewer who
/// commented is never read as silent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Judged {
    pub decision: String,
    pub approvals: usize,
    pub changes_requested: usize,
    /// Non-author reviewers whose latest review is a formal state.
    pub engaged: usize,
    pub approved: bool,
}

pub(crate) fn judge(view: &View, copilot: Option<&CopilotReviews>) -> Judged {
    let mut decision = view.decision.clone();
    let mut latest: Vec<(String, String)> = view
        .latest
        .iter()
        .map(|row| (row.author.login.clone(), row.state.clone()))
        .collect();
    if let Some(copilot) = copilot {
        let current = copilot
            .latest
            .as_ref()
            .map_or("COMMENTED", |review| review.state.as_str());
        let removed = matches!(decision.as_str(), "APPROVED" | "CHANGES_REQUESTED")
            && latest.iter().any(|(login, state)| {
                login == COPILOT_REVIEWER && *state == decision && state != current
            });
        for (login, state) in &mut latest {
            if login == COPILOT_REVIEWER {
                *state = current.to_owned();
            }
        }
        if removed {
            decision = "REVIEW_REQUIRED".to_owned();
        }
    }
    let count = |word: &str| latest.iter().filter(|(_, state)| state == word).count();
    let approvals = count("APPROVED");
    let changes_requested = count("CHANGES_REQUESTED");
    let engaged = latest
        .iter()
        .filter(|(login, state)| {
            *login != view.author
                && matches!(
                    state.as_str(),
                    "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED"
                )
        })
        .count();
    let approved =
        decision == "APPROVED" || (decision.is_empty() && approvals > 0 && changes_requested == 0);
    Judged {
        decision,
        approvals,
        changes_requested,
        engaged,
        approved,
    }
}

/// Whether the view's `latestReviews` carries a Copilot row in a formal
/// state: the condition under which the reviews and timeline are read for
/// the head rule.
pub(crate) fn copilot_reviewed(view: &View) -> bool {
    view.latest.iter().any(|row| {
        row.author.login == COPILOT_REVIEWER
            && matches!(
                row.state.as_str(),
                "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED"
            )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::wire::{Actor, Object};

    fn event(kind: &str, fields: Value) -> TimelineEvent {
        let fields: Object = serde_json::from_value(fields).unwrap();
        TimelineEvent {
            event: kind.to_owned(),
            fields,
        }
    }

    /// The arrival time binds a review to the delivered head: the latest
    /// matching force push wins over the committed event, and a timeline
    /// naming neither gives no bound.
    #[test]
    fn the_head_arrives_by_its_latest_force_push_else_its_commit() {
        let head = "737bce791577e140436490e0fed5751bb5144a61";
        let events = vec![
            event(
                "committed",
                serde_json::json!({"sha": head, "committer": {"date": "2026-01-01T00:00:00Z"}}),
            ),
            event(
                "head_ref_force_pushed",
                serde_json::json!({"commit_id": head, "created_at": "2026-01-02T00:00:00Z"}),
            ),
            event(
                "head_ref_force_pushed",
                serde_json::json!({"commit_id": head, "created_at": "2026-01-03T00:00:00Z"}),
            ),
            event(
                "head_ref_force_pushed",
                serde_json::json!({"commit_id": "other", "created_at": "2026-01-09T00:00:00Z"}),
            ),
        ];
        assert_eq!(arrival(&events, head).unwrap(), "2026-01-03T00:00:00Z");
        assert_eq!(arrival(&events[..1], head).unwrap(), "2026-01-01T00:00:00Z");
        assert_eq!(arrival(&[], head).unwrap(), "");
        let bad = vec![event(
            "head_ref_force_pushed",
            serde_json::json!({"commit_id": head, "created_at": 7}),
        )];
        assert!(matches!(
            arrival(&bad, head),
            Err(Cause::ResponseInvalid(Endpoint::Timeline))
        ));
    }

    fn view_with(decision: &str, latest: &[(&str, &str)]) -> View {
        View {
            head: "737bce791577e140436490e0fed5751bb5144a61".into(),
            base: "main".into(),
            state: PullRequestState::Open,
            draft: false,
            decision: decision.into(),
            latest: latest
                .iter()
                .map(|(login, state)| LatestReview {
                    author: Actor {
                        login: (*login).to_owned(),
                    },
                    state: (*state).to_owned(),
                })
                .collect(),
            author: "lane-app".into(),
        }
    }

    /// A re-pointed Copilot approval loses its verdict and the aggregate it
    /// carried; a fresh one keeps both; the author's own comment is not
    /// engagement.
    #[test]
    fn a_repointed_copilot_review_carries_no_verdict() {
        let stale = CopilotReviews {
            latest: None,
            any_non_error: false,
            requested_at: None,
        };
        let judged = judge(
            &view_with("APPROVED", &[(COPILOT_REVIEWER, "APPROVED")]),
            Some(&stale),
        );
        assert_eq!(judged.decision, "REVIEW_REQUIRED");
        assert!(!judged.approved);
        assert_eq!(judged.engaged, 1);
        let fresh = CopilotReviews {
            latest: Some(CopilotReview {
                id: 1,
                state: "APPROVED".into(),
                submitted_at: "2026-01-01T00:00:00Z".into(),
                error: false,
                no_files: false,
            }),
            any_non_error: true,
            requested_at: None,
        };
        let judged = judge(
            &view_with("APPROVED", &[(COPILOT_REVIEWER, "APPROVED")]),
            Some(&fresh),
        );
        assert!(judged.approved);
        let judged = judge(&view_with("", &[("lane-app", "COMMENTED")]), None);
        assert_eq!(judged.engaged, 0);
        assert!(!judged.approved);
        let judged = judge(
            &view_with(
                "",
                &[("colleague", "APPROVED"), ("other", "CHANGES_REQUESTED")],
            ),
            None,
        );
        assert!(!judged.approved);
        assert_eq!(judged.changes_requested, 1);
    }
}
