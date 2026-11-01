//! Verification of a published head where it stands (decision 93): the
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
//! publication cannot change what is read (decision 87). A reply the types
//! cannot decode, a page set whose total disagrees with what arrived, a
//! collection at an endpoint's documented cap, a failed request and a
//! required workflow with no explicit source sha each end `unreadable`
//! with a stable cause: a dependency failure is never a verdict, and
//! `none` holds only once every absence probe was read to its last page.
//! No type defaults a field GitHub documents as required (decisions 104,
//! 106 and 107): an absent required key, a null where none is documented
//! and a word outside a documented set each refuse the reply, so malformed
//! evidence cannot read as an empty requirement or an admissible member,
//! and every member is validated before any selection reduces the set.
//!
//! The verdict is the legacy `ci-wait`'s, with the recorded corrections: a
//! pushed base is judged (107), `startup_failure` fails (113), a tie of
//! equal starts follows the port's listing order (117, 122). The oracle is
//! frozen: no new dimension, count or correction machinery; a verdict change
//! waits for the differential's retirement or is one named correction.
//!
//! No polling loop runs here. One call is one read set; the caller repeats
//! on `pending` under its own budget, so the budget and the retry stay with
//! the workflow that owns them and a hung read never holds the record lock.

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the differential runs the legacy ci-wait oracle as a process"
)]
mod differential;
mod evidence;
mod judge;
mod selection;
pub mod wire;

use std::path::Path;
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::ops::{self, Applied, Env, RecordVerification, Request, Verdict, VerifyHead};
use crate::state::{self, Locking};

use judge::Judgement;

/// The `source` the record names.
const SOURCE: &str = "verify-head";

/// The bound on one `gh api` call.
const GH_TIMEOUT: Duration = Duration::from_secs(60);

/// GitHub's largest page, requested explicitly so each page's total can be
/// checked against what arrived; `gh api --paginate` hides the pages.
const PER_PAGE: usize = 100;

/// The most pages one collection is read over; past it the collection is
/// not the documented total and is refused.
const MAX_PAGES: usize = 100;

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

/// What a check's state means for the verdict: the legacy's taxonomy as
/// decision 113 fixes it, where `skipped` and `neutral` are skipping,
/// counted as passed only under `required_only` (`ci-wait:812`), `stale`
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
    /// (the legacy `$ro and bucket == "skipping"`).
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
/// it on the item at `path`. `pending` and `unreadable` are results, not
/// refusals: the reply carries them and the record is untouched.
#[allow(
    clippy::disallowed_methods,
    reason = "the verification's one store call: the verdict recorded through record-verification"
)]
pub fn run(path: &Path, r: &VerifyHead, env: &Env, locking: Locking) -> Result<Verified> {
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
    match evidence::read(&Gh, r).map(judge::judge) {
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
                source: SOURCE.to_owned(),
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
    let invalid = |field: &'static str, value: &str| Error::VerifyRequestInvalid {
        field,
        value: value.to_owned(),
    };
    let (owner, name) = r
        .repo
        .split_once('/')
        .ok_or_else(|| invalid("repo", &r.repo))?;
    let repo_word = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    };
    if !repo_word(owner) || !repo_word(name) {
        return Err(invalid("repo", &r.repo));
    }
    if r.base.is_empty() || r.base.starts_with('-') || r.base.chars().any(char::is_whitespace) {
        return Err(invalid("base", &r.base));
    }
    if r.head.len() != 40
        || !r
            .head
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid("head", &r.head));
    }
    Ok(())
}

/// The base as a URL path segment: every byte outside the unreserved set is
/// percent-encoded, so a branch with `/` reaches the rules and branch
/// endpoints as one segment.
fn segment(base: &str) -> String {
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
enum Endpoint {
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
        }
    }
}

/// Why evidence is unreadable. `key` is the reply's `reason`.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Cause {
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
    /// resolve a live ref (decision 87).
    WorkflowSourceUnbound { path: String },
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
        }
    }

    fn detail(&self) -> Option<String> {
        match self {
            Cause::ReadFailed { detail, .. } => Some(detail.clone()),
            Cause::ResponseInvalid(_) | Cause::TotalMismatch(_) | Cause::Capped(_) => None,
            Cause::WorkflowSourceUnbound { .. } => None,
        }
    }
}

type Read<T> = std::result::Result<T, Cause>;

/// What one `gh` call left: the bytes a call that exited zero printed, or
/// the failure of one that did not, with the stdout it printed beside it.
/// gh prints a GraphQL reply that carries `errors` and exits nonzero
/// (v2.103.3 `pkg/cmd/api/api.go:492-556`, `:698`), so a failed call's
/// stdout travels with its status to the one reader that may consume it,
/// `nodes_of`, in the one shape that is an answer; every other read takes
/// the failure as its own (`printed`; decision 123 (2)).
enum Answer {
    Printed(Vec<u8>),
    Failed { stdout: Vec<u8>, detail: String },
}

impl Answer {
    /// The bytes a call that exited zero printed; a failed call is the
    /// read's failure, its `detail` what gh wrote.
    fn printed(self, endpoint: Endpoint) -> Read<Vec<u8>> {
        match self {
            Answer::Printed(bytes) => Ok(bytes),
            Answer::Failed { detail, .. } => Err(Cause::ReadFailed { endpoint, detail }),
        }
    }
}

/// One `gh` call: the arguments after the program, as `gh api PATH` or the
/// GraphQL form `gh api graphql -f query=… -f ids[]=…`, answered with what
/// it printed and whether it exited zero (`Answer`). Production is `Gh`;
/// the differential test answers from a rendered case
/// (`differential::FakeGh`), so `evidence::read` is the one constructor of
/// an `Evidence` in both.
trait Transport {
    fn call(&self, endpoint: Endpoint, args: &[&str]) -> Read<Answer>;
}

/// `gh api` through agent-runtime's one process runner, `gh` resolved on
/// this process's PATH with its environment, so the caller's GitHub
/// authentication is the one used.
struct Gh;

impl Transport for Gh {
    #[allow(
        clippy::disallowed_methods,
        reason = "the verification reads GitHub through gh for one pinned head, no effect on a lane or a controller"
    )]
    fn call(&self, endpoint: Endpoint, args: &[&str]) -> Read<Answer> {
        let failed = |detail: String| Cause::ReadFailed { endpoint, detail };
        let output = host::run("gh", Path::new("gh"), "api", args, GH_TIMEOUT)
            .map_err(|e| failed(e.to_string()))?;
        if !output.status.success() {
            // gh writes an HTTP error's message to stderr and its body to
            // stdout; whichever it wrote is the detail.
            let detail = [host::stderr_text(&output), host::stdout_text(&output)]
                .into_iter()
                .map(|text| text.trim().to_owned())
                .find(|text| !text.is_empty())
                .unwrap_or_else(|| format!("exit status {}", output.status));
            return Ok(Answer::Failed {
                stdout: output.stdout,
                detail,
            });
        }
        if output.stdout.iter().all(u8::is_ascii_whitespace) {
            return Err(failed("empty answer".to_owned()));
        }
        Ok(Answer::Printed(output.stdout))
    }
}

/// The reads over a transport, decoding each answer into a wire type.
struct Reader<'a> {
    gh: &'a dyn Transport,
}

impl Reader<'_> {
    fn object<T: for<'de> Deserialize<'de>>(&self, endpoint: Endpoint, path: &str) -> Read<T> {
        let bytes = self.gh.call(endpoint, &["api", path])?.printed(endpoint)?;
        serde_json::from_slice(&bytes).map_err(|_| Cause::ResponseInvalid(endpoint))
    }

    /// The check-suite nodes query the legacy sent (`ci-run-correlation.sh:384`).
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

    /// Every member of a collection whose pages each state the total: read
    /// page by page until the members add up to it. An empty page before
    /// that, a page whose total differs, or more members than the total is
    /// the mismatch; no partial set is returned.
    fn collection<P: Page>(&self, endpoint: Endpoint, path: &str) -> Read<Vec<P::Member>> {
        let mut members = Vec::new();
        let mut total: Option<usize> = None;
        for page in 1..=MAX_PAGES {
            let decoded: P = self.object(endpoint, &paged(path, page))?;
            let stated = decoded.total();
            if total.is_some_and(|known| known != stated) {
                return Err(Cause::TotalMismatch(endpoint));
            }
            total = Some(stated);
            let got = decoded.members();
            if got.is_empty() {
                break;
            }
            members.extend(got);
            if members.len() >= stated {
                break;
            }
        }
        if total != Some(members.len()) {
            return Err(Cause::TotalMismatch(endpoint));
        }
        Ok(members)
    }

    /// Every member of a collection whose pages are bare arrays with no
    /// total: read until a page is shorter than the page size.
    fn array<T: for<'de> Deserialize<'de>>(&self, endpoint: Endpoint, path: &str) -> Read<Vec<T>> {
        let mut members = Vec::new();
        for page in 1..=MAX_PAGES {
            let got: Vec<T> = self.object(endpoint, &paged(path, page))?;
            let last = got.len() < PER_PAGE;
            members.extend(got);
            if last {
                return Ok(members);
            }
        }
        Err(Cause::ResponseInvalid(endpoint))
    }
}

/// The nodes of a `nodes(ids:)` reply. GraphQL leaves a field it could not
/// resolve null and adds an error naming the field's path (GraphQL
/// specification § 6.4.4 Handling Field Errors), so a reply carrying
/// `data` whose every error names one node, `["nodes", i]`, is the
/// documented shape of ids the viewer cannot resolve: the other nodes are
/// validated answers and node `i` is null (decision 122 (4)); a node
/// present at a path an error names is not that shape. gh prints such a
/// reply and exits nonzero, as it does for every reply carrying errors
/// (`api.go:492-556`), so this is the one reader of a failed call's
/// output, and it consumes that shape alone (decision 123 (2)): a failed
/// call whose output is not that shape, unparseable, without `data`, with
/// any other error or with no error at all, is the read's failure with
/// what gh wrote, as the legacy refused every error
/// (`ci-run-correlation.sh:387`; gh's client failed on any,
/// `api/client.go:98`); a call that exited zero and printed anything but
/// that shape answered outside the documented one. The errors are what
/// admits a failed call's output: a reply with none is a success's shape,
/// and a call that printed one yet failed did so for a cause the reply
/// does not carry (gh exits nonzero on an HTTP status above 299 with no
/// error message, `api.go:553-557`), so its output is not read.
fn nodes_of<N: for<'de> Deserialize<'de>>(
    endpoint: Endpoint,
    answer: Answer,
) -> Read<Vec<wire::Nullable<N>>> {
    let failed = matches!(answer, Answer::Failed { .. });
    let (bytes, refused) = match answer {
        Answer::Printed(bytes) => (bytes, Cause::ResponseInvalid(endpoint)),
        Answer::Failed { stdout, detail } => (stdout, Cause::ReadFailed { endpoint, detail }),
    };
    let Ok(reply) = serde_json::from_slice::<wire::NodesReply<N>>(&bytes) else {
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

fn paged(path: &str, page: usize) -> String {
    let join = if path.contains('?') { '&' } else { '?' };
    format!("{path}{join}per_page={PER_PAGE}&page={page}")
}

/// One page of a collection that states its total on every page.
trait Page: for<'de> Deserialize<'de> {
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

    #[test]
    fn a_page_request_names_its_page() {
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
