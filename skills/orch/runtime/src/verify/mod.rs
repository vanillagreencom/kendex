//! Verification of a published head where it stands: the
//! `verify-head` operation reads GitHub for one pinned commit through
//! `gh api`, decodes every reply into the closed types of `wire`, gathers
//! them into one validated, complete `Evidence` (`evidence`), judges the
//! verdict over it (`judge`: `Evidence → Selection → Classification`) and
//! records it through `record-verification` in the same call.
//!
//! Every read names the pinned sha, the base's rule set, or an object by
//! its own id (the repository's workflows, a check suite's or check run's
//! node, a source repository by the name a proof gave), never a branch
//! head or a pull request, so a push that moved the branch after
//! publication cannot change what is read. A reply the types
//! cannot decode, a page set whose total disagrees with what arrived, a
//! collection at an endpoint's documented cap, a failed request and a
//! required workflow with no explicit source sha each end `unreadable`
//! with a stable cause: a dependency failure is never a verdict, and
//! `none` holds only once every absence probe was read to its last page.
//! No type defaults a field GitHub documents as required: an absent required key, a null where none is documented
//! and a word outside a documented set each refuse the reply, so malformed
//! evidence cannot read as an empty requirement or an admissible member,
//! and every member is validated before any selection reduces the set.
//!
//! The verdict's rules: a pushed base is judged, `startup_failure` fails,
//! and a tie of equal starts follows the listing order. The verdict's
//! witnesses are recorded rows (`tests/rust/verify.rs`).
//!
//! No polling loop runs here. One call is one read set; the caller repeats
//! on `pending` under its own budget, so the budget and the retry stay with
//! the workflow that owns them and a hung read never holds the record lock.
//! A caller that waits under a deadline of its own hands the read set what
//! it has left ([`Budget`]): no call starts past it, each call is bounded by
//! what is left, and an answer that arrives past it is no answer.
//!
//! The `verify-pr` operation (`ops::verify_pr`) is the one caller that
//! names a pull request: [`pull_request`] reads its current head, base and
//! state through `gh pr view`, by number, and [`run`] then judges that
//! head exactly as above, recording under its own `source`. The review
//! gate's reads (`review`) name the pull request too: its verdict is the
//! reviewers' state on the head the pull request answers.

pub mod ci_proof;
mod evidence;
mod judge;
pub mod review;
mod selection;
pub mod wire;

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use agent_runtime::host;
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::ops::{self, Applied, Env, RecordVerification, Request, Verdict, VerifyHead};
use crate::schedule::Clock;
use crate::state::{self, Locking};

pub(crate) use evidence::required_contexts;
use judge::Judgement;

/// Which operation asked for the verdict: the `source` the record names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Caller {
    /// `verify-head`, over the head its request pinned.
    VerifyHead,
    /// `verify-pr`, over the head its pull request's `pr view` answered.
    VerifyPr,
}

impl Caller {
    fn source(self) -> &'static str {
        match self {
            Caller::VerifyHead => "verify-head",
            Caller::VerifyPr => "verify-pr",
        }
    }
}

/// The bound on one `gh` call.
const GH_TIMEOUT: Duration = Duration::from_secs(60);

/// The fields `pr view` is asked for, in gh's own names (`wire::PullRequestView`).
const PULL_REQUEST_FIELDS: &str = "headRefOid,baseRefName,state";

/// GitHub's largest page, requested explicitly so each page's total can be
/// checked against what arrived; `gh api --paginate` hides the pages.
pub(crate) const PER_PAGE: usize = 100;

/// The most pages one collection is read over; past it the collection is
/// not the documented total and is refused.
pub(crate) const MAX_PAGES: usize = 100;

// --- the reply ------------------------------------------------------------

/// How the read set ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    /// A final verdict, recorded.
    Complete,
    /// Not final: a check or run has not ended, or nothing has registered
    /// yet while CI exists. Nothing is recorded; the caller repeats.
    Pending,
    /// Evidence that could not be read or decoded; `reason` is the cause.
    /// Nothing is recorded.
    Unreadable,
}

/// Where a reported check came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Source {
    CheckRun,
    CommitStatus,
    WorkflowRun,
    /// A required context or workflow no check on the head reports yet.
    Required,
}

/// What a check's state means for the verdict: `skipped` and `neutral`
/// are skipping, counted as passed only under `required_only`, `stale`
/// is pending, and `cancelled`, `timed_out`, `action_required` and
/// `startup_failure` read as failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Bucket {
    Pass,
    Fail,
    Pending,
    Skipping,
}

impl Bucket {
    /// Whether a check in this bucket is a success the verdict counts: a
    /// skipped check counts only when the caller asked for the required set
    /// (the required set is where a skipped check is the base's choice).
    fn counts_as_passed(self, required_only: bool) -> bool {
        match self {
            Bucket::Pass => true,
            Bucket::Skipping => required_only,
            Bucket::Fail | Bucket::Pending => false,
        }
    }
}

/// One check the verdict considered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckReport {
    pub name: String,
    pub source: Source,
    /// The documented word read: a conclusion once completed, else the
    /// status; `expected` for a required check not yet on the head.
    pub state: String,
    pub bucket: Bucket,
}

/// The reply of one `verify-head` call.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Verified {
    pub status: Status,
    /// The schema's word on `complete`, absent otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verdict: Option<String>,
    /// On `complete`, what was read, as the record's `reason`; on `pending`
    /// or `unreadable`, the stable cause key and the values it acted on.
    pub reason: String,
    /// What the failed program said, on an `unreadable` read failure.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub head: String,
    pub repo: String,
    pub checks: Vec<CheckReport>,
    /// The `record-verification` transition that committed, on `complete`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded: Option<Applied>,
}

/// Read GitHub for the request's pinned head and, on a final verdict, record
/// it on the item at `path` under `caller`'s source. `pending` and
/// `unreadable` are results, not refusals: the reply carries them and the
/// record is untouched.
pub fn run(
    path: &Path,
    r: &VerifyHead,
    gh: &Path,
    env: &Env,
    locking: Locking,
    caller: Caller,
) -> Result<Verified> {
    run_with(path, r, &Gh::new(gh), env, locking, caller)
}

/// [`run`] over a `gh` handle the caller built, with the budget it carries.
#[allow(
    clippy::disallowed_methods,
    reason = "the verification's one store call: the verdict recorded through record-verification"
)]
pub(crate) fn run_with(
    path: &Path,
    r: &VerifyHead,
    gh: &Gh<'_>,
    env: &Env,
    locking: Locking,
    caller: Caller,
) -> Result<Verified> {
    validate(r)?;
    // The record is read before GitHub so a missing file refuses before any
    // network read, as `apply` would have refused after them.
    state::load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    let reply = |status, verdict: Option<Verdict>, reason, detail, checks, recorded| Verified {
        status,
        verdict: verdict.map(|v| v.word().to_owned()),
        reason,
        detail,
        head: r.head.clone(),
        repo: r.repo.clone(),
        checks,
        recorded,
    };
    match evidence::read(gh, r).map(judge::judge) {
        Ok(Judgement::Final {
            verdict,
            reason,
            checks,
        }) => {
            let request = Request::RecordVerification(RecordVerification {
                round_id: None,
                head: r.head.clone(),
                verdict: verdict.word().to_owned(),
                reason: reason.clone(),
                source: caller.source().to_owned(),
            });
            let recorded = ops::apply(path, &request, env, locking)?;
            Ok(reply(
                Status::Complete,
                Some(verdict),
                reason,
                None,
                checks,
                Some(recorded),
            ))
        }
        Ok(Judgement::Pending { reason, checks }) => {
            Ok(reply(Status::Pending, None, reason, None, checks, None))
        }
        Err(cause) => Ok(reply(
            Status::Unreadable,
            None,
            cause.key(),
            cause.detail(),
            Vec::new(),
            None,
        )),
    }
}

/// The request's fields in the forms the reads pin. A head is the full
/// lowercase 40-hex id `worktree-push --publish-base` pins: a prefix can
/// name more than one commit. A base is one branch name; a repo is
/// `owner/name`. Each refuses before any read.
fn validate(r: &VerifyHead) -> Result<()> {
    validate_repo(&r.repo)?;
    if !base_form(&r.base) {
        return Err(Error::VerifyRequestInvalid {
            field: "base",
            value: r.base.clone(),
        });
    }
    if !head_form(&r.head) {
        return Err(Error::VerifyRequestInvalid {
            field: "head",
            value: r.head.clone(),
        });
    }
    Ok(())
}

/// `repo` is `owner/name`, each word non-empty and of the characters a
/// GitHub name takes; else the refusal names the field.
pub(crate) fn validate_repo(repo: &str) -> Result<()> {
    let invalid = || Error::VerifyRequestInvalid {
        field: "repo",
        value: repo.to_owned(),
    };
    let (owner, name) = repo.split_once('/').ok_or_else(invalid)?;
    // GitHub's own classes: a login is letters, digits and hyphens, never a
    // dot; a name may carry dots but is never dots alone, since `.` and `..`
    // are path segments in `repos/<repo>/`.
    let login = !owner.is_empty() && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    let named = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        && !name.chars().all(|c| c == '.');
    if !login || !named {
        return Err(invalid());
    }
    Ok(())
}

/// One branch name: non-empty, no whitespace, not a flag.
fn base_form(base: &str) -> bool {
    !base.is_empty() && !base.starts_with('-') && !base.chars().any(char::is_whitespace)
}

/// The full lowercase 40-hex commit id.
fn head_form(head: &str) -> bool {
    head.len() == 40
        && head
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Why a read answered nothing usable: the reply's `reason` key and, for a
/// failed call, what the program said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unreadable {
    pub reason: String,
    pub detail: Option<String>,
}

impl From<Cause> for Unreadable {
    fn from(cause: Cause) -> Unreadable {
        Unreadable {
            reason: cause.key(),
            detail: cause.detail(),
        }
    }
}

/// Read pull request `pr` of `repo` through one `gh pr view`: its current
/// head, base and state, as gh exports them (`wire::PullRequestView`). The
/// read names the pull request by its number and nothing else; the head it
/// answers is what the caller then pins every other read to. A failed call,
/// an answer outside gh's documented shape, a head that is not a full
/// lowercase 40-hex id or a base that is no branch name is `Unreadable`
/// with its cause, never a pull request.
pub(crate) fn pull_request(
    gh: &Gh<'_>,
    repo: &str,
    pr: u64,
) -> std::result::Result<wire::PullRequestView, Unreadable> {
    let endpoint = Endpoint::PullRequest;
    let number = pr.to_string();
    let read = || -> Read<wire::PullRequestView> {
        let bytes = gh
            .call(
                endpoint,
                &[
                    "pr",
                    "view",
                    &number,
                    "--repo",
                    repo,
                    "--json",
                    PULL_REQUEST_FIELDS,
                ],
            )?
            .printed(endpoint)?;
        let pull: wire::PullRequestView =
            serde_json::from_slice(&bytes).map_err(|_| Cause::ResponseInvalid(endpoint))?;
        if !head_form(&pull.head) || !base_form(&pull.base) {
            return Err(Cause::ResponseInvalid(endpoint));
        }
        Ok(pull)
    };
    read().map_err(Unreadable::from)
}

/// The base as a URL path segment: every byte outside the unreserved set is
/// percent-encoded, so a branch with `/` reaches the rules and branch
/// endpoints as one segment.
pub(crate) fn segment(base: &str) -> String {
    let mut out = String::with_capacity(base.len());
    for b in base.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

// --- the reads ------------------------------------------------------------

/// The GitHub reads, named as the cause keys name them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Endpoint {
    /// `commits/{sha}/check-runs`.
    CheckRuns,
    /// `commits/{sha}/check-suites`, read for its count.
    CheckSuites,
    /// `commits/{sha}/status`.
    Statuses,
    /// `actions/runs?head_sha={sha}`.
    ActionsRuns,
    /// `rules/branches/{base}`.
    Rules,
    /// `branches/{base}`, read for its protection.
    Protection,
    /// `actions/workflows`: the first route to the workflow name a job's
    /// run carries, and the absence probe.
    Workflows,
    /// `actions/workflows/{id}`: the last route to a run's workflow name,
    /// read as gh reads a workflow its list lacks
    /// (`pkg/cmd/run/shared/shared.go:456-470`), after the graph.
    Workflow,
    /// The GraphQL check-run nodes query: the suite, run and workflow of a
    /// check run whose REST suite join is absent, and the workflow name of
    /// a joined check whose run's workflow the list lacks.
    CheckRunSuites,
    /// `check-suites/{id}/check-runs`: a required workflow candidate's
    /// suite, as GitHub lists it under the endpoint's default `filter`.
    SuiteCheckRuns,
    /// The GraphQL check-suite nodes query: the workflow file each
    /// candidate execution of a required workflow ran.
    WorkflowFiles,
    /// `repos/{owner}/{name}`: a source proof's repository, for its id.
    SourceRepository,
    /// `gh pr view {number}`: the one read that names a pull request, for
    /// the head `verify-pr` then pins every other read to.
    PullRequest,
    /// `pulls/{number}`: the pull request object, for the refresh route's
    /// author and branch and the draft flag.
    Pull,
    /// `pulls/{number}/reviews`: every review, for the Copilot head rule.
    Reviews,
    /// `issues/{number}/timeline`: the head's arrival and Copilot's
    /// pending requests.
    Timeline,
    /// The GraphQL `reviewThreads` walk.
    Threads,
    /// `branches/{base}/protection`: classic review requirements.
    ClassicProtection,
    /// `pulls/{number}/requested_reviewers`, POST: the Copilot request.
    RequestReview,
    /// `gh pr ready {number}`: the draft marked ready.
    Ready,
}

impl Endpoint {
    fn word(self) -> &'static str {
        match self {
            Endpoint::CheckRuns => "check-runs",
            Endpoint::CheckSuites => "check-suites",
            Endpoint::Statuses => "statuses",
            Endpoint::ActionsRuns => "actions-runs",
            Endpoint::Rules => "rules",
            Endpoint::Protection => "protection",
            Endpoint::Workflows => "workflows",
            Endpoint::Workflow => "workflow",
            Endpoint::CheckRunSuites => "check-run-suites",
            Endpoint::SuiteCheckRuns => "suite-check-runs",
            Endpoint::WorkflowFiles => "workflow-files",
            Endpoint::SourceRepository => "source-repository",
            Endpoint::PullRequest => "pull-request",
            Endpoint::Pull => "pull",
            Endpoint::Reviews => "reviews",
            Endpoint::Timeline => "timeline",
            Endpoint::Threads => "threads",
            Endpoint::ClassicProtection => "classic-protection",
            Endpoint::RequestReview => "request-review",
            Endpoint::Ready => "ready",
        }
    }

    /// The runner's operation word: the call's first argument.
    fn operation(self) -> &'static str {
        match self {
            Endpoint::PullRequest | Endpoint::Ready => "pr",
            Endpoint::CheckRuns
            | Endpoint::CheckSuites
            | Endpoint::Statuses
            | Endpoint::ActionsRuns
            | Endpoint::Rules
            | Endpoint::Protection
            | Endpoint::Workflows
            | Endpoint::Workflow
            | Endpoint::CheckRunSuites
            | Endpoint::SuiteCheckRuns
            | Endpoint::WorkflowFiles
            | Endpoint::SourceRepository
            | Endpoint::Pull
            | Endpoint::Reviews
            | Endpoint::Timeline
            | Endpoint::Threads
            | Endpoint::ClassicProtection
            | Endpoint::RequestReview => "api",
        }
    }

    fn unrun(self, unrun: Unrun) -> Cause {
        match unrun {
            Unrun::Runner(e) => Cause::ReadFailed {
                endpoint: self,
                detail: e.to_string(),
            },
            Unrun::BudgetSpent => Cause::BudgetSpent(self),
        }
    }
}

/// Why evidence is unreadable. `key` is the reply's `reason`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Cause {
    /// The request did not answer: a non-zero exit, no output, or a program
    /// that could not be run or did not return in time.
    ReadFailed { endpoint: Endpoint, detail: String },
    /// The answer is not the documented shape, or a value is outside the
    /// documented set.
    ResponseInvalid(Endpoint),
    /// The pages did not add up to the total every page states.
    TotalMismatch(Endpoint),
    /// The collection reached the endpoint's documented cap, so unseen
    /// members can remain (`evidence`'s completeness table).
    Capped(Endpoint),
    /// A required workflow names no explicit source sha; binding it would
    /// resolve a live ref.
    WorkflowSourceUnbound { path: String },
    /// The caller's budget was spent before the call could start, or before
    /// its answer arrived (`Budget`).
    BudgetSpent(Endpoint),
}

impl Cause {
    fn key(&self) -> String {
        match self {
            Cause::ReadFailed { endpoint, .. } => format!("{}-read-failed", endpoint.word()),
            Cause::ResponseInvalid(endpoint) => format!("{}-response-invalid", endpoint.word()),
            Cause::TotalMismatch(endpoint) => format!("{}-total-mismatch", endpoint.word()),
            Cause::Capped(endpoint) => format!("{}-capped", endpoint.word()),
            Cause::WorkflowSourceUnbound { path } => {
                format!("workflow-source-unbound path={path}")
            }
            Cause::BudgetSpent(endpoint) => format!("{}-budget-spent", endpoint.word()),
        }
    }

    fn detail(&self) -> Option<String> {
        match self {
            Cause::ReadFailed { detail, .. } => Some(detail.clone()),
            Cause::ResponseInvalid(_)
            | Cause::TotalMismatch(_)
            | Cause::Capped(_)
            | Cause::BudgetSpent(_) => None,
            Cause::WorkflowSourceUnbound { .. } => None,
        }
    }
}

pub(crate) type Read<T> = std::result::Result<T, Cause>;

/// What one `gh` call left: what a call that exited zero printed, or the
/// failure of one that did not. gh prints a GraphQL reply that carries
/// `errors` and exits nonzero (v2.103.3 `pkg/cmd/api/api.go:492-556`,
/// `:698`), so a failed call's stdout travels with its status to the
/// reader that may consume that shape.
pub(crate) enum Answer {
    Printed { stdout: Vec<u8>, stderr: String },
    Failed(Failed),
}

/// A `gh` call that exited nonzero or was killed.
pub(crate) struct Failed {
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: String,
    pub(crate) exit: Option<i32>,
    /// The exit status as the process reports it: `exit status: N`, or the
    /// signal that ended it.
    pub(crate) status: String,
}

impl Failed {
    /// What gh said: its stderr, else its stdout, else the exit status. gh
    /// writes an HTTP error's message to stderr and its body to stdout.
    pub(crate) fn detail(&self) -> String {
        [
            self.stderr.trim().to_owned(),
            String::from_utf8_lossy(&self.stdout).trim().to_owned(),
        ]
        .into_iter()
        .find(|text| !text.is_empty())
        .unwrap_or_else(|| self.status.clone())
    }

    /// The HTTP status of GitHub's reply, as gh wrote it last on stderr.
    pub(crate) fn http(&self) -> Option<u16> {
        http_status(&self.stderr)
    }
}

/// Why a `gh` call has no answer.
pub(crate) enum Unrun {
    /// The program could not be run (`NotStarted`), or did not answer
    /// within its bound.
    Runner(agent_runtime::Error),
    /// The handle's budget was spent before the call could start, or before
    /// its answer arrived.
    BudgetSpent,
}

impl Unrun {
    pub(crate) fn detail(&self) -> String {
        match self {
            Unrun::Runner(e) => e.to_string(),
            Unrun::BudgetSpent => "budget-spent".to_owned(),
        }
    }
}

impl Answer {
    /// The bytes a call that exited zero printed; a failed call is the
    /// read's failure, its `detail` what gh wrote.
    fn printed(self, endpoint: Endpoint) -> Read<Vec<u8>> {
        match self {
            Answer::Printed { stdout, .. } => Ok(stdout),
            Answer::Failed(failed) => Err(Cause::ReadFailed {
                endpoint,
                detail: failed.detail(),
            }),
        }
    }
}

/// The HTTP status of GitHub's reply in what gh wrote: the status gh
/// appends to the reply's message, `<message> (HTTP NNN)`; the bare
/// `gh: HTTP NNN` where the reply had none; or its client's
/// `HTTP NNN: <message> (<url>)` (each measured on gh 2.103.3). The message
/// is the server's and can quote a status or run over lines
/// (`gh: upstream (HTTP 422) (HTTP 500)`), so the last status gh wrote
/// decides; the scope hint gh can print after it names none.
pub(crate) fn http_status(text: &str) -> Option<u16> {
    let mut status = None;
    for line in text.lines() {
        let code = match line.rsplit_once(" (HTTP ") {
            Some((_, rest)) => rest.strip_suffix(')'),
            None => line
                .strip_prefix("gh: ")
                .unwrap_or(line)
                .strip_prefix("HTTP ")
                .map(|rest| rest.split_once(':').map_or(rest, |(code, _)| code)),
        };
        if let Some(code) = code.filter(|c| c.len() == 3 && c.bytes().all(|b| b.is_ascii_digit())) {
            status = code.parse().ok();
        }
    }
    status
}

/// Whether gh's words report GitHub's 4xx reply (`http_status`).
pub(crate) fn refused_by_github(text: &str) -> bool {
    http_status(text).is_some_and(|code| (400..500).contains(&code))
}

/// How GitHub answered an act: made, or refused with gh's exit status and
/// what it said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Acted {
    Made,
    Refused { exit: i32, detail: String },
}

/// What a read set may spend, on the one injected clock: the deadline of
/// the wait it serves, less the poll that wait still owes after it. No
/// call starts past it, each call is bounded by what is left, and an
/// answer that arrives past it is no answer, since the wait has moved on:
/// a probe never carries its wait past the wait's own deadline.
#[derive(Clone, Copy)]
pub(crate) struct Budget<'a> {
    clock: &'a dyn Clock,
    deadline: Instant,
}

impl<'a> Budget<'a> {
    pub(crate) fn until(clock: &'a dyn Clock, deadline: Instant) -> Budget<'a> {
        Budget { clock, deadline }
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the budget's one clock read, through the injected clock the wait it serves runs on"
    )]
    fn remaining(&self) -> Duration {
        self.deadline.saturating_duration_since(self.clock.now())
    }
}

/// `gh` through agent-runtime's one process runner, the one way the runtime
/// reads GitHub: `program`, a bare `gh` resolved on this process's PATH, or
/// the path the caller already runs `gh` by, with this process's
/// environment, so the caller's GitHub authentication is the one used; a
/// handle built `with_env` adds its variables, so a credential the caller
/// loaded is used instead. The handle never reads the environment itself.
/// One call is the arguments after the program, as `gh api PATH`, the
/// GraphQL form `gh api graphql -f query=…` or `gh pr view N`, answered
/// with what it printed and whether it exited zero (`Answer`). The start is
/// counted under the handle's tag and the call's operation word. A handle
/// built `within` a budget refuses a call past it and bounds each call by
/// what is left.
pub(crate) struct Gh<'a> {
    program: PathBuf,
    tag: &'static str,
    budget: Option<Budget<'a>>,
    env: Vec<(String, OsString)>,
    cwd: Option<PathBuf>,
    bound: Duration,
}

impl<'a> Gh<'a> {
    pub(crate) fn new(program: &Path) -> Gh<'a> {
        Gh {
            program: program.to_path_buf(),
            tag: "verify",
            budget: None,
            env: Vec::new(),
            cwd: None,
            bound: GH_TIMEOUT,
        }
    }

    pub(crate) fn within(program: &Path, budget: Budget<'a>) -> Gh<'a> {
        Gh {
            budget: Some(budget),
            ..Gh::new(program)
        }
    }

    pub(crate) fn with_env(program: &Path, env: Vec<(String, OsString)>) -> Gh<'a> {
        Gh {
            env,
            ..Gh::new(program)
        }
    }

    /// The start-counter tag of the duty or operation that reads.
    pub(crate) fn tagged(self, tag: &'static str) -> Gh<'a> {
        Gh { tag, ..self }
    }

    /// The directory the call runs in, for a read whose repository gh
    /// resolves from the checkout.
    pub(crate) fn in_dir(self, cwd: &Path) -> Gh<'a> {
        Gh {
            cwd: Some(cwd.to_path_buf()),
            ..self
        }
    }

    pub(crate) fn bounded(self, bound: Duration) -> Gh<'a> {
        Gh { bound, ..self }
    }

    /// This handle with `env` added, for the reads of a credential the
    /// caller loaded beside the handle's own, while every other read keeps
    /// the handle as it is.
    pub(crate) fn adding_env(&self, env: Vec<(String, OsString)>) -> Gh<'a> {
        let mut pairs = self.env.clone();
        pairs.extend(env);
        Gh {
            program: self.program.clone(),
            tag: self.tag,
            budget: self.budget,
            env: pairs,
            cwd: self.cwd.clone(),
            bound: self.bound,
        }
    }

    fn call(&self, endpoint: Endpoint, args: &[&str]) -> Read<Answer> {
        let answer = self
            .run(endpoint.operation(), args, None)
            .map_err(|unrun| endpoint.unrun(unrun))?;
        if let Answer::Printed { stdout, .. } = &answer
            && stdout.iter().all(u8::is_ascii_whitespace)
        {
            return Err(Cause::ReadFailed {
                endpoint,
                detail: "empty answer".to_owned(),
            });
        }
        Ok(answer)
    }

    /// One act, judged by gh's exit status alone: an act's success can
    /// print nothing on stdout (`gh pr ready` writes its success line to
    /// stderr, gh v2.103.3 `pkg/cmd/pr/ready`). A call that ended with no
    /// exit status, killed by a signal, may or may not have reached
    /// GitHub, so it is the read's failure, never a refusal.
    fn act(&self, endpoint: Endpoint, args: &[&str]) -> Read<Acted> {
        match self
            .run(endpoint.operation(), args, None)
            .map_err(|unrun| endpoint.unrun(unrun))?
        {
            Answer::Printed { .. } => Ok(Acted::Made),
            Answer::Failed(failed) => match failed.exit {
                Some(exit) => Ok(Acted::Refused {
                    exit,
                    detail: failed.detail(),
                }),
                None => Err(Cause::ReadFailed {
                    endpoint,
                    detail: failed.detail(),
                }),
            },
        }
    }

    /// One `gh` call with `args`, `stdin` fed where given, counted under
    /// `operation`.
    #[allow(
        clippy::disallowed_methods,
        reason = "the runtime's one GitHub transport: the reads of the verification, the review gate, the queue wait, the admission, the approval, the validation start and the watch duties, and the acts the review gate and the approval make, each under its caller's tag; no effect on a lane or a controller"
    )]
    pub(crate) fn run(
        &self,
        operation: &'static str,
        args: &[&str],
        stdin: Option<&[u8]>,
    ) -> std::result::Result<Answer, Unrun> {
        let timeout = match &self.budget {
            None => self.bound,
            Some(budget) => match budget.remaining() {
                left if left.is_zero() => return Err(Unrun::BudgetSpent),
                left => self.bound.min(left),
            },
        };
        let env: Vec<(&str, &OsStr)> = self
            .env
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_os_str()))
            .collect();
        let place = host::Place {
            cwd: self.cwd.as_deref(),
            env: &env,
        };
        let output = match stdin {
            None => host::run_tagged_in(
                self.tag,
                "gh",
                &self.program,
                operation,
                args,
                place,
                timeout,
            ),
            Some(bytes) => host::run_tagged_fed(
                self.tag,
                "gh",
                &self.program,
                operation,
                args,
                place,
                bytes,
                timeout,
            ),
        };
        // An answer that arrived past the budget is no answer: the wait it
        // served has moved on.
        if self
            .budget
            .as_ref()
            .is_some_and(|b| b.remaining().is_zero())
        {
            return Err(Unrun::BudgetSpent);
        }
        let output = output.map_err(Unrun::Runner)?;
        if !output.status.success() {
            return Ok(Answer::Failed(Failed {
                stderr: host::stderr_text(&output),
                exit: output.status.code(),
                status: output.status.to_string(),
                stdout: output.stdout,
            }));
        }
        Ok(Answer::Printed {
            stderr: host::stderr_text(&output),
            stdout: output.stdout,
        })
    }
}

/// The reads over `gh`, decoding each answer into a wire type.
struct Reader<'a> {
    gh: &'a Gh<'a>,
}

impl Reader<'_> {
    fn object<T: for<'de> Deserialize<'de>>(&self, endpoint: Endpoint, path: &str) -> Read<T> {
        let bytes = self.gh.call(endpoint, &["api", path])?.printed(endpoint)?;
        serde_json::from_slice(&bytes).map_err(|_| Cause::ResponseInvalid(endpoint))
    }

    /// The check-suite nodes query: the source proof of a required run.
    fn suite_nodes(&self, ids: &[&str]) -> Read<Vec<wire::Nullable<wire::CheckSuiteNode>>> {
        self.nodes(
            Endpoint::WorkflowFiles,
            "... on CheckSuite { id databaseId workflowRun { databaseId runAttempt file { path repositoryName repositoryFileUrl viewerCanReadRepository } } }",
            ids,
        )
    }

    /// The check-run nodes query for the suite join REST omitted and for
    /// the workflow name the list lacks (`wire::CheckRunNode`): the fields
    /// `gh pr checks` read of a check's suite (gh v2.103.3
    /// `api/query_builder.go:297`, `checkSuite{workflowRun{event,workflow{name}}}`),
    /// with the run's id the join needs.
    fn check_run_nodes(&self, ids: &[&str]) -> Read<Vec<wire::Nullable<wire::CheckRunNode>>> {
        self.nodes(
            Endpoint::CheckRunSuites,
            "... on CheckRun { id checkSuite { workflowRun { databaseId event workflow { name } } } }",
            ids,
        )
    }

    /// One `nodes(ids:)` query with `selection` on each node, its ids as
    /// GraphQL variables (`gh api graphql`: every `-f` field but `query`
    /// is a variable; `ids[]=` builds the array), answered with its nodes
    /// (`nodes_of`).
    fn nodes<N: for<'de> Deserialize<'de>>(
        &self,
        endpoint: Endpoint,
        selection: &str,
        ids: &[&str],
    ) -> Read<Vec<wire::Nullable<N>>> {
        let query = format!("query=query($ids:[ID!]!) {{ nodes(ids:$ids) {{ {selection} }} }}");
        let ids: Vec<String> = ids.iter().map(|id| format!("ids[]={id}")).collect();
        let mut args = vec!["api", "graphql", "-f", query.as_str()];
        for id in &ids {
            args.extend(["-f", id.as_str()]);
        }
        nodes_of(endpoint, self.gh.call(endpoint, &args)?)
    }

    fn collection<P: Page>(&self, endpoint: Endpoint, path: &str) -> Read<Vec<P::Member>> {
        collection(
            path,
            |page| self.object::<P>(endpoint, page),
            || Cause::TotalMismatch(endpoint),
        )
    }

    fn array<T: for<'de> Deserialize<'de>>(&self, endpoint: Endpoint, path: &str) -> Read<Vec<T>> {
        list(
            path,
            |page| self.object(endpoint, page),
            || Cause::ResponseInvalid(endpoint),
        )
    }
}

/// Every member of a collection whose pages each state the total, `page`
/// reading one page's path: page by page at the largest size until the
/// members add up to the total. A page whose total differs, a page short
/// of the size before the total, or more members than the total is
/// `mismatch`: a short page before the total is an incomplete read, never
/// a complete one, and no partial set is returned.
pub(crate) fn collection<P: Page, E>(
    path: &str,
    mut page: impl FnMut(&str) -> std::result::Result<P, E>,
    mismatch: impl Fn() -> E,
) -> std::result::Result<Vec<P::Member>, E> {
    let mut members = Vec::new();
    let mut total: Option<usize> = None;
    for number in 1..=MAX_PAGES {
        let decoded = page(&paged(path, number))?;
        let stated = decoded.total();
        if total.is_some_and(|known| known != stated) {
            return Err(mismatch());
        }
        total = Some(stated);
        let got = decoded.members();
        let short = got.len() < PER_PAGE;
        members.extend(got);
        if members.len() >= stated || short {
            break;
        }
    }
    if total != Some(members.len()) {
        return Err(mismatch());
    }
    Ok(members)
}

/// Every member of a list whose pages are bare arrays with no total, `page`
/// reading one page's path: pages at the largest size until a short one;
/// past `MAX_PAGES` the list is `past`, never the pages read.
pub(crate) fn list<T, E>(
    path: &str,
    mut page: impl FnMut(&str) -> std::result::Result<Vec<T>, E>,
    past: impl Fn() -> E,
) -> std::result::Result<Vec<T>, E> {
    let mut members = Vec::new();
    for number in 1..=MAX_PAGES {
        let got = page(&paged(path, number))?;
        let last = got.len() < PER_PAGE;
        members.extend(got);
        if last {
            return Ok(members);
        }
    }
    Err(past())
}

/// The nodes of a `nodes(ids:)` reply. GraphQL leaves a field it could not
/// resolve null and adds an error naming the field's path (GraphQL
/// specification § 6.4.4 Handling Field Errors), so a reply carrying
/// `data` whose every error names one node, `["nodes", i]`, is the
/// documented shape of ids the viewer cannot resolve: the other nodes are
/// validated answers and node `i` is null; a node
/// present at a path an error names is not that shape. gh prints such a
/// reply and exits nonzero, as it does for every reply carrying errors
/// (`api.go:492-556`), so this is the one reader of a failed call's
/// output, and it consumes that shape alone: a failed
/// call whose output is not that shape, unparseable, without `data`, with
/// any other error or with no error at all, is the read's failure with
/// what gh wrote (gh's client fails on any error, `api/client.go:98`); a call that exited zero and printed anything but
/// that shape answered outside the documented one. The errors are what
/// admits a failed call's output: a reply with none is a success's shape,
/// and a call that printed one yet failed did so for a cause the reply
/// does not carry (gh exits nonzero on an HTTP status above 299 with no
/// error message, `api.go:553-557`), so its output is not read.
fn nodes_of<N: for<'de> Deserialize<'de>>(
    endpoint: Endpoint,
    answer: Answer,
) -> Read<Vec<wire::Nullable<N>>> {
    let failed = matches!(answer, Answer::Failed(_));
    let (bytes, refused) = match answer {
        Answer::Printed { stdout, .. } => (stdout, Cause::ResponseInvalid(endpoint)),
        Answer::Failed(failed) => {
            let detail = failed.detail();
            (failed.stdout, Cause::ReadFailed { endpoint, detail })
        }
    };
    let Ok(reply) = serde_json::from_slice::<wire::GraphReply<wire::NodesData<N>>>(&bytes) else {
        return Err(refused);
    };
    let wire::Nullable::Present(data) = reply.data else {
        return Err(refused);
    };
    let errors = reply.errors.present().map_or(&[][..], Vec::as_slice);
    if failed && errors.is_empty() {
        return Err(refused);
    }
    for error in errors {
        let Some(index) = error.node_index() else {
            return Err(refused);
        };
        match data.nodes.get(index) {
            Some(wire::Nullable::Absent | wire::Nullable::Null) => {}
            Some(wire::Nullable::Present(_)) | None => return Err(refused),
        }
    }
    Ok(data.nodes)
}

pub(crate) fn paged(path: &str, page: usize) -> String {
    let join = if path.contains('?') { '&' } else { '?' };
    format!("{path}{join}per_page={PER_PAGE}&page={page}")
}

/// One page of a collection that states its total on every page.
pub(crate) trait Page: for<'de> Deserialize<'de> {
    type Member;
    fn total(&self) -> usize;
    fn members(self) -> Vec<Self::Member>;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The request forms the reads pin; every other form refuses before a
    /// read.
    #[test]
    fn a_request_is_validated_before_any_read() {
        let ok = VerifyHead {
            repo: "owner/repo".into(),
            base: "release/1.x".into(),
            head: "737bce791577e140436490e0fed5751bb5144a61".into(),
            required_only: true,
        };
        assert!(validate(&ok).is_ok());
        let rows: &[(&str, VerifyHead)] = &[
            (
                "repo",
                VerifyHead {
                    repo: "owner".into(),
                    ..ok.clone()
                },
            ),
            (
                "repo",
                VerifyHead {
                    repo: "owner/re po".into(),
                    ..ok.clone()
                },
            ),
            (
                "base",
                VerifyHead {
                    base: "-flag".into(),
                    ..ok.clone()
                },
            ),
            (
                "base",
                VerifyHead {
                    base: "".into(),
                    ..ok.clone()
                },
            ),
            (
                "head",
                VerifyHead {
                    head: "737BCE791577E140436490E0FED5751BB5144A61".into(),
                    ..ok.clone()
                },
            ),
            (
                "head",
                VerifyHead {
                    head: "737bce7".into(),
                    ..ok.clone()
                },
            ),
        ];
        for (field, request) in rows {
            match validate(request) {
                Err(Error::VerifyRequestInvalid { field: got, .. }) => assert_eq!(got, *field),
                other => panic!("{field}: {other:?}"),
            }
        }
        assert_eq!(segment("release/1.x"), "release%2F1.x");
    }

    /// The status gh wrote last is the reply's, in each of gh's three
    /// renderings; one quoted before it, or named inside a URL, is not.
    /// A 5xx whose message quotes a 404 is no absence.
    #[test]
    fn the_last_status_gh_wrote_is_the_replys() {
        for (text, status) in [
            ("gh: Not Found (HTTP 404)", Some(404)),
            (
                "gh: HTTP 404: Not Found (https://api.github.com/repos/o/r)",
                Some(404),
            ),
            (
                "HTTP 404: workflow x.yml not found on the default branch (https://api.github.com/repos/o/r/actions/workflows/x.yml)",
                Some(404),
            ),
            (
                "{\"message\":\"Not Found\"}\ngh: Not Found (HTTP 404)",
                Some(404),
            ),
            ("gh: HTTP 404", Some(404)),
            (
                "gh: Resource not accessible by integration (HTTP 403)",
                Some(403),
            ),
            (
                "gh: HTTP 500: Server Error (https://api.github.com/404)",
                Some(500),
            ),
            ("gh: upstream (HTTP 404) (HTTP 502)", Some(502)),
            (
                "gh: upstream (HTTP 422)\ngh: Server Error (HTTP 500)",
                Some(500),
            ),
            ("error connecting to api.github.com", None),
            ("", None),
        ] {
            assert_eq!(http_status(text), status, "{text}");
        }
    }

    #[test]
    fn a_page_request_names_its_page() {
        assert_eq!(segment("a b:\"c\">=d"), "a%20b%3A%22c%22%3E%3Dd");
        assert_eq!(
            paged("repos/o/r/commits/abc/check-runs?filter=all", 2),
            "repos/o/r/commits/abc/check-runs?filter=all&per_page=100&page=2"
        );
        assert_eq!(
            paged("repos/o/r/actions/runs?head_sha=abc", 1),
            "repos/o/r/actions/runs?head_sha=abc&per_page=100&page=1"
        );
    }
}
