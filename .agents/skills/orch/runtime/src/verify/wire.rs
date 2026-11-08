//! GitHub's documented shapes at the wire boundary, and the one guard for
//! how a field may be absent or null.
//!
//! A wire struct's field takes exactly one of three forms:
//!
//! - `T`: documented required and not nullable. An absent key and a null
//!   both fail to decode.
//! - `Optional<T>`: documented optional and not nullable, declared with
//!   `#[serde(default)]`. An absent key is `Absent`; a null fails to decode.
//! - `Nullable<T>`: documented nullable. A null is `Null`. On a required
//!   key it is declared without a default, so an absent key fails to
//!   decode and `Absent` is never built; on a key documented optional as
//!   well, `#[serde(default)]` makes absence `Absent`.
//!
//! No bare `Option` appears here: serde's missing-field path answers an
//! `Option` with `None`, which reads an absent key and an explicit null as
//! one state, and a present value outside its documented type must not
//! become the default for omission. Both wrappers
//! buffer through `serde_json::Value` for the same reason.
//!
//! A field documented `object` is declared `Object`, so an array, string
//! or number on it refuses the reply whatever the enclosing kind.
//!
//! Value sets are from docs.github.com/en/rest: checks/runs,
//! checks/suites, commits/statuses, actions/workflow-runs,
//! actions/workflows, repos/rules, repos/repos and branches/branches, API
//! version 2022-11-28, and from docs.github.com/en/graphql/reference for
//! the source proof's objects; each field's form cites the schema line it
//! follows. A word outside a documented set refuses the reply, except in
//! a set another reader reads as no word it judges (a run's status and
//! conclusion, a workflow's state, a rule's type): there it decodes as
//! `Other`, which the verification's readers refuse. GitHub adds fields to
//! its objects, so the structs tolerate
//! unknown fields. The catalogue test at the bottom deserializes every
//! struct from a probe that sets each field to null and to absent and
//! asserts the documented answer; a field without a row fails it.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};

use super::{Bucket, Cause, Endpoint, Page, Read};

/// A JSON object as GitHub documents one: the only shape a field declared
/// `object` may take. An array, string or number on such a field refuses
/// the reply before any kind-specific decoding reads it.
pub(super) type Object = serde_json::Map<String, serde_json::Value>;

// --- the three forms -----------------------------------------------------------

/// A field GitHub documents as optional and not nullable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Optional<T> {
    Absent,
    Present(T),
}

/// Absence is the default for any `T`: the derive would demand
/// `T: Default`, which a wire struct need not have.
#[allow(
    clippy::derivable_impls,
    reason = "the derive bounds T: Default; absence is the default for any T"
)]
impl<T> Default for Optional<T> {
    fn default() -> Self {
        Optional::Absent
    }
}

impl<T> Optional<T> {
    pub fn present(&self) -> Option<&T> {
        match self {
            Optional::Absent => None,
            Optional::Present(value) => Some(value),
        }
    }
}

impl<'de, T: DeserializeOwned> Deserialize<'de> for Optional<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        if value.is_null() {
            return Err(serde::de::Error::custom(
                "null on a field documented optional and not nullable",
            ));
        }
        T::deserialize(value)
            .map(Optional::Present)
            .map_err(serde::de::Error::custom)
    }
}

/// A field GitHub documents as nullable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Nullable<T> {
    Absent,
    Null,
    Present(T),
}

#[allow(
    clippy::derivable_impls,
    reason = "the derive bounds T: Default; absence is the default for any T"
)]
impl<T> Default for Nullable<T> {
    fn default() -> Self {
        Nullable::Absent
    }
}

impl<'de, T: DeserializeOwned> Deserialize<'de> for Nullable<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        if value.is_null() {
            return Ok(Nullable::Null);
        }
        T::deserialize(value)
            .map(Nullable::Present)
            .map_err(serde::de::Error::custom)
    }
}

// --- checks/runs ----------------------------------------------------------------

/// A check run's `status` (checks/runs, enum); a workflow run's `status` is
/// the same word set (actions/workflow-runs, `status` filter values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RunStatus {
    Queued,
    InProgress,
    Completed,
    Waiting,
    Requested,
    Pending,
    /// A word outside the documented set: the watch and the validation
    /// read it as no word they judge; the verification refuses it.
    #[serde(other)]
    Other,
}

impl RunStatus {
    pub(super) fn word(self) -> &'static str {
        match self {
            RunStatus::Queued => "queued",
            RunStatus::InProgress => "in_progress",
            RunStatus::Completed => "completed",
            RunStatus::Waiting => "waiting",
            RunStatus::Requested => "requested",
            RunStatus::Pending => "pending",
            RunStatus::Other => "other",
        }
    }
}

/// A check run's or workflow run's `conclusion`, set once completed: the
/// GraphQL `CheckConclusionState` enum (graphql/reference/checks), which
/// the REST schemas list without `stale` and `startup_failure`; the
/// check-run prose documents `stale`, and `startup_failure` ("the check
/// suite or run has failed at startup") is the state a run takes when its
/// workflow file cannot be parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RunConclusion {
    Success,
    Failure,
    Neutral,
    Cancelled,
    Skipped,
    TimedOut,
    ActionRequired,
    Stale,
    StartupFailure,
    /// A word outside the documented set: the watch and the validation
    /// read it as no word they judge; the verification refuses it.
    #[serde(other)]
    Other,
}

impl RunConclusion {
    pub(crate) fn word(self) -> &'static str {
        match self {
            RunConclusion::Success => "success",
            RunConclusion::Failure => "failure",
            RunConclusion::Neutral => "neutral",
            RunConclusion::Cancelled => "cancelled",
            RunConclusion::Skipped => "skipped",
            RunConclusion::TimedOut => "timed_out",
            RunConclusion::ActionRequired => "action_required",
            RunConclusion::Stale => "stale",
            RunConclusion::StartupFailure => "startup_failure",
            RunConclusion::Other => "other",
        }
    }

    /// What a check's conclusion means: the reading through gh's
    /// bucket (gh v2.103.3 `aggregate.go:72-88`): `neutral` is skipping
    /// beside `skipped`, never a failure; `stale`
    /// is pending, a superseded suite's evidence that settles nothing;
    /// `startup_failure` is the one correction, a failure (GitHub documents
    /// it as a completed run's conclusion; gh's pending reading would leave
    /// the wait forever on a workflow that cannot start).
    pub(super) fn check_bucket(self) -> Bucket {
        match self {
            RunConclusion::Success => Bucket::Pass,
            RunConclusion::Skipped | RunConclusion::Neutral => Bucket::Skipping,
            RunConclusion::Stale => Bucket::Pending,
            RunConclusion::Failure
            | RunConclusion::Cancelled
            | RunConclusion::TimedOut
            | RunConclusion::ActionRequired
            | RunConclusion::StartupFailure
            | RunConclusion::Other => Bucket::Fail,
        }
    }

    /// What an Actions run's conclusion means: the run list's reading,
    /// where a `neutral` or
    /// `skipped` run fails nothing. A run's checks carry their own
    /// conclusions.
    pub(super) fn run_bucket(self) -> Bucket {
        match self {
            RunConclusion::Success | RunConclusion::Neutral | RunConclusion::Skipped => {
                Bucket::Pass
            }
            RunConclusion::Failure
            | RunConclusion::Cancelled
            | RunConclusion::TimedOut
            | RunConclusion::ActionRequired
            | RunConclusion::Stale
            | RunConclusion::StartupFailure
            | RunConclusion::Other => Bucket::Fail,
        }
    }
}

/// A check's or run's validated state: ended with its conclusion, or not.
/// A workflow run's `status` is documented nullable; the rollup reads a
/// null status as not completed (`(.status // "") != "completed"`), so an
/// unfinished run may carry no status word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Outcome {
    Concluded(RunConclusion),
    Unfinished(Option<RunStatus>),
}

impl Outcome {
    /// The documented word read: the conclusion once completed, else the
    /// status, `null` for a run whose status is null. A conclusion on a run
    /// still in flight is not documented as invalid and reads as its status.
    pub(super) fn word(self) -> &'static str {
        match self {
            Outcome::Concluded(conclusion) => conclusion.word(),
            Outcome::Unfinished(Some(status)) => status.word(),
            Outcome::Unfinished(None) => "null",
        }
    }

    pub(super) fn check_bucket(self) -> Bucket {
        match self {
            Outcome::Concluded(conclusion) => conclusion.check_bucket(),
            Outcome::Unfinished(_) => Bucket::Pending,
        }
    }

    pub(super) fn run_bucket(self) -> Bucket {
        match self {
            Outcome::Concluded(conclusion) => conclusion.run_bucket(),
            Outcome::Unfinished(_) => Bucket::Pending,
        }
    }

    pub(super) fn unfinished(self) -> bool {
        matches!(self, Outcome::Unfinished(_))
    }
}

/// The validated state from a status and a required nullable `conclusion`:
/// null is the documented value until completion, so a completed run with
/// null and a run without the key are both outside the documented shape.
fn outcome(
    endpoint: Endpoint,
    status: Option<RunStatus>,
    conclusion: Nullable<RunConclusion>,
) -> Read<Outcome> {
    if status == Some(RunStatus::Other) || conclusion == Nullable::Present(RunConclusion::Other) {
        return Err(Cause::ResponseInvalid(endpoint));
    }
    match (status, conclusion) {
        (Some(RunStatus::Completed), Nullable::Present(conclusion)) => {
            Ok(Outcome::Concluded(conclusion))
        }
        (Some(RunStatus::Completed), Nullable::Null) => Err(Cause::ResponseInvalid(endpoint)),
        (_, Nullable::Absent) => Err(Cause::ResponseInvalid(endpoint)),
        (status, Nullable::Null | Nullable::Present(_)) => Ok(Outcome::Unfinished(status)),
    }
}

/// The check suite a check run belongs to; an Actions job's suite is its
/// workflow run's `check_suite_id`, the REST join of the job to its run
/// (`evidence::check_run_suites`).
#[derive(Debug, Deserialize)]
pub(super) struct CheckSuiteRef {
    /// Required (checks/runs, `check_suite.id`: integer).
    pub(super) id: u64,
}

#[derive(Debug, Deserialize)]
pub(crate) struct CheckRun {
    /// Required (checks/runs, `id`: integer): the check run's identity,
    /// which orders two check runs started alike in the rollup
    /// (`selection::eliminate_duplicates`).
    pub(super) id: u64,
    /// Required (checks/runs, `node_id`: string): the GraphQL id the suite
    /// of a check run is read through where REST omits the join
    /// (`evidence::check_run_suites`).
    pub(super) node_id: String,
    /// Required (checks/runs, `name`: string).
    pub(crate) name: String,
    /// Required, not nullable (checks/runs, `status`: enum).
    pub(crate) status: RunStatus,
    /// Required, nullable (checks/runs, `conclusion`: enum or null).
    pub(crate) conclusion: Nullable<RunConclusion>,
    /// Required, nullable (checks/runs, `check_suite`: object or null).
    pub(super) check_suite: Nullable<CheckSuiteRef>,
    /// Required, nullable (checks/runs, `started_at`: date-time or null).
    /// A run's jobs are ranked and run-less checks deduplicated by this
    /// time.
    pub(super) started_at: Nullable<String>,
    /// Required, nullable (checks/runs, `completed_at`: date-time or null).
    /// The key GitHub's `latest` filter selects by ("Filters check runs by
    /// their completed_at timestamp. latest returns the most recent check
    /// runs.", rest/checks/runs, `filter`); that selection is the server's,
    /// read as it answers the suite's check runs (`evidence`), and nothing
    /// here reduces by the field.
    #[allow(
        dead_code,
        reason = "documented required: its absence refuses the page"
    )]
    pub(super) completed_at: Nullable<String>,
    /// Required, nullable (checks/runs, `html_url`: string or null): the
    /// check run's page on GitHub. The required suite read lists a bound
    /// run's jobs by this field and matches the rollup's `link` against it
    /// by equality, so the two fields are read apart and compared, unequal
    /// included.
    /// The same struct decodes the members of that suite read
    /// (`evidence::suite_jobs`).
    pub(super) html_url: Nullable<String>,
    /// Required, nullable (checks/runs, `details_url`: string or null): the
    /// URL the integrator set on the check run ("The URL of the
    /// integrator's site that has the full details of the check", checks
    /// runs, create), the GraphQL `CheckRun.detailsUrl`: gh's rollup
    /// `link` (gh v2.103.3 `pkg/cmd/pr/checks/aggregate.go:51-53`,
    /// `link := c.DetailsURL`), which the run is read out of.
    pub(super) details_url: Nullable<String>,
}

impl CheckRun {
    pub(super) fn outcome(&self) -> Read<Outcome> {
        outcome(Endpoint::CheckRuns, Some(self.status), self.conclusion)
    }

    /// Whether a word is outside its documented set (`Other`).
    pub(super) fn undocumented(&self) -> bool {
        self.status == RunStatus::Other
            || self.conclusion == Nullable::Present(RunConclusion::Other)
    }

    pub(super) fn suite(&self) -> Option<u64> {
        match &self.check_suite {
            Nullable::Absent | Nullable::Null => None,
            Nullable::Present(suite) => Some(suite.id),
        }
    }

    /// When the check run started, where GitHub recorded it.
    pub(super) fn started(&self) -> Option<&str> {
        match &self.started_at {
            Nullable::Absent | Nullable::Null => None,
            Nullable::Present(started) => Some(started),
        }
    }

    /// The check run's page, where GitHub names one: the bound-job link of
    /// the suite read.
    pub(crate) fn page(&self) -> Option<&str> {
        match &self.html_url {
            Nullable::Absent | Nullable::Null => None,
            Nullable::Present(url) => Some(url),
        }
    }

    /// The integrator's details URL, where one is set: gh's rollup
    /// `link`.
    pub(super) fn details(&self) -> Option<&str> {
        match &self.details_url {
            Nullable::Absent | Nullable::Null => None,
            Nullable::Present(url) => Some(url),
        }
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct CheckRunsPage {
    /// Required (checks/runs, `total_count`: integer).
    total_count: usize,
    /// Required (checks/runs, `check_runs`: array).
    check_runs: Vec<CheckRun>,
}

impl Page for CheckRunsPage {
    type Member = CheckRun;
    fn total(&self) -> usize {
        self.total_count
    }
    fn members(self) -> Vec<CheckRun> {
        self.check_runs
    }
}

// --- checks/suites ---------------------------------------------------------------

/// The first page of a ref's check suites, read for its total: the
/// check-runs endpoint covers a ref's 1,000 most recent suites, so the
/// count proves that endpoint's answer whole (see `evidence`).
#[derive(Debug, Deserialize)]
pub(super) struct CheckSuitesPage {
    /// Required (checks/suites, `total_count`: integer).
    pub(super) total_count: usize,
    /// Required (checks/suites, `check_suites`: array). Only the count is
    /// consumed; the members decode so the page is the documented shape.
    #[allow(
        dead_code,
        reason = "documented required: its absence refuses the page"
    )]
    pub(super) check_suites: Vec<CheckSuiteRef>,
}

// --- commits/statuses ------------------------------------------------------------

/// A commit status's `state` (commits/statuses, create: "Can be one of").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum StatusState {
    Error,
    Failure,
    Pending,
    Success,
}

impl StatusState {
    pub(super) fn word(self) -> &'static str {
        match self {
            StatusState::Error => "error",
            StatusState::Failure => "failure",
            StatusState::Pending => "pending",
            StatusState::Success => "success",
        }
    }

    pub(super) fn bucket(self) -> Bucket {
        match self {
            StatusState::Success => Bucket::Pass,
            StatusState::Pending => Bucket::Pending,
            StatusState::Error | StatusState::Failure => Bucket::Fail,
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct CommitStatus {
    /// Required (commits/statuses, `context`: string).
    pub(super) context: String,
    /// Required, not nullable (commits/statuses, `state`: string).
    pub(super) state: StatusState,
    /// Required, nullable (commits/statuses, `target_url`: string or
    /// null). A status's Actions run is read out of its link; `evidence`
    /// reads it through `run_in_url`.
    pub(super) target_url: Nullable<String>,
}

/// The run id in an Actions link: the maximal digit run after
/// `/actions/runs/`.
pub(super) fn run_in_url(url: &str) -> Option<u64> {
    let (_, after) = url.split_once("/actions/runs/")?;
    let digits: String = after.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

/// The combined status: the latest status per context, paginated.
#[derive(Debug, Deserialize)]
pub(super) struct CombinedStatusPage {
    /// Required (commits/statuses, `total_count`: integer).
    total_count: usize,
    /// Required (commits/statuses, `statuses`: array).
    statuses: Vec<CommitStatus>,
}

impl Page for CombinedStatusPage {
    type Member = CommitStatus;
    fn total(&self) -> usize {
        self.total_count
    }
    fn members(self) -> Vec<CommitStatus> {
        self.statuses
    }
}

// --- actions/workflow-runs ------------------------------------------------------

/// A run on the head, with the fields the correlation reads: its suite
/// joins its checks to it, `workflow_id` groups its executions and names
/// its workflow (`Workflow`), `event` tells a substantive dispatch,
/// `run_attempt`, `run_started_at` and `updated_at` select the current
/// execution (`selection::current_execution`), and `path` with
/// `check_suite_node_id` identify a required workflow's candidate
/// execution. The watch reads a workflow's latest runs by `created_at`,
/// and a run's `head_branch` and `event` name the budget scan's producer.
/// The run's own `name` (string or null, the run's display title,
/// `run-name` where a workflow sets one) is read by nothing: gh's rollup
/// `workflow` is the workflow object's name, not the run's.
#[derive(Debug, Deserialize)]
pub(crate) struct WorkflowRun {
    /// Required (actions/workflow-runs, `id`: integer).
    pub(crate) id: u64,
    /// Required (actions/workflow-runs, `path`: string): the workflow file
    /// as it was at the run, with its ref after `@` where GitHub appends
    /// one; a workflow's current `Workflow.path` can differ after a rename.
    pub(super) path: String,
    /// Required (actions/workflow-runs, `head_sha`: string).
    pub(super) head_sha: String,
    /// Required, nullable (actions/workflow-runs, `head_branch`: string or
    /// null).
    pub(crate) head_branch: Nullable<String>,
    /// Required, nullable (actions/workflow-runs, `status`: string or
    /// null).
    pub(crate) status: Nullable<RunStatus>,
    /// Required, nullable (actions/workflow-runs, `conclusion`: string or
    /// null).
    pub(crate) conclusion: Nullable<RunConclusion>,
    /// Required (actions/workflow-runs, `workflow_id`: integer).
    pub(super) workflow_id: u64,
    /// Required (actions/workflow-runs, `event`: string). The event names
    /// are GitHub's webhook events, an open set, so the word is kept.
    pub(crate) event: String,
    /// Required (actions/workflow-runs, `created_at`: date-time).
    pub(crate) created_at: String,
    /// Required (actions/workflow-runs, `updated_at`: date-time).
    pub(super) updated_at: String,
    /// Optional, not nullable (actions/workflow-runs, `check_suite_id`:
    /// integer, not in the required list).
    #[serde(default)]
    pub(super) check_suite_id: Optional<u64>,
    /// Optional, not nullable (actions/workflow-runs,
    /// `check_suite_node_id`: string, not in the required list): the node
    /// the source proof is read for.
    #[serde(default)]
    pub(super) check_suite_node_id: Optional<String>,
    /// Optional, not nullable (actions/workflow-runs, `run_attempt`:
    /// integer, not in the required list): 1 for a first attempt.
    #[serde(default)]
    pub(crate) run_attempt: Optional<u64>,
    /// Optional, not nullable (actions/workflow-runs, `run_started_at`:
    /// date-time, not in the required list): the start of the latest
    /// attempt.
    #[serde(default)]
    pub(super) run_started_at: Optional<String>,
}

impl WorkflowRun {
    /// Whether a word is outside its documented set (`Other`).
    pub(super) fn undocumented(&self) -> bool {
        self.status == Nullable::Present(RunStatus::Other)
            || self.conclusion == Nullable::Present(RunConclusion::Other)
    }

    pub(super) fn outcome(&self) -> Read<Outcome> {
        let status = match self.status {
            Nullable::Absent => return Err(Cause::ResponseInvalid(Endpoint::ActionsRuns)),
            Nullable::Null => None,
            Nullable::Present(status) => Some(status),
        };
        outcome(Endpoint::ActionsRuns, status, self.conclusion)
    }

    /// The attempt, 1 where omitted.
    pub(super) fn attempt(&self) -> u64 {
        *self.run_attempt.present().unwrap_or(&1)
    }

    /// When the current attempt started
    /// (`run_started_at // updated_at`).
    pub(super) fn started(&self) -> &str {
        self.run_started_at
            .present()
            .map_or(&self.updated_at, String::as_str)
    }

    pub(super) fn suite(&self) -> Option<u64> {
        self.check_suite_id.present().copied()
    }

    pub(super) fn suite_node(&self) -> Option<&str> {
        self.check_suite_node_id.present().map(String::as_str)
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct RunsPage {
    /// Required (actions/workflow-runs, `total_count`: integer).
    total_count: usize,
    /// Required (actions/workflow-runs, `workflow_runs`: array).
    pub(crate) workflow_runs: Vec<WorkflowRun>,
}

impl Page for RunsPage {
    type Member = WorkflowRun;
    fn total(&self) -> usize {
        self.total_count
    }
    fn members(self) -> Vec<WorkflowRun> {
        self.workflow_runs
    }
}

// --- actions/workflows ------------------------------------------------------------

/// A repository workflow's `state` (actions/workflows, enum).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum WorkflowState {
    Active,
    Deleted,
    DisabledFork,
    DisabledInactivity,
    DisabledManually,
    /// A word outside the documented set: the watch and the validation
    /// read it as no word they judge; the verification refuses it.
    #[serde(other)]
    Other,
}

/// A repository workflow (actions/workflows, "List repository workflows",
/// and "Get a workflow" for one fetched by id): the object a run's
/// `workflow_id` names, whose `name` is what `gh pr checks` printed as a
/// job's `workflow` (the GraphQL `Workflow.name`, `String!`, through
/// `CheckSuite.workflowRun.workflow`; gh v2.103.3 `aggregate.go:68`). The
/// workflow syntax reference states the name is the file path relative to
/// the repository root where the file sets none, so a workflow always has
/// one. The list need not carry every run's workflow (a deleted file's
/// runs remain, and an organization ruleset workflow answers 404 by id, gh
/// `pkg/cmd/run/shared/shared.go:460-470`), so a name the list lacks is
/// read through the graph and then by id (`evidence::check_run_suites`,
/// above).
#[derive(Debug, Deserialize)]
pub(crate) struct Workflow {
    /// Required (actions/workflows, `id`: integer).
    pub(super) id: u64,
    /// Required (actions/workflows, `name`: string).
    pub(super) name: String,
    /// Required (actions/workflows, `path`: string): the file the watch
    /// looks for on the default branch.
    pub(crate) path: String,
    /// Required (actions/workflows, `state`: enum).
    pub(super) state: WorkflowState,
}

#[derive(Debug, Deserialize)]
pub(crate) struct WorkflowsPage {
    /// Required (actions/workflows, `total_count`: integer).
    total_count: usize,
    /// Required (actions/workflows, `workflows`: array).
    workflows: Vec<Workflow>,
}

impl Page for WorkflowsPage {
    type Member = Workflow;
    fn total(&self) -> usize {
        self.total_count
    }
    fn members(self) -> Vec<Workflow> {
        self.workflows
    }
}

// --- repos/rules -----------------------------------------------------------------

/// The rule types a branch's rule set documents (repos/rules, the
/// repository rule union). Only `required_status_checks` names contexts
/// and only `workflows` names required workflows; the others gate the ref,
/// its commits, files, reviews or scanning results and put nothing in the
/// check rollup.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RuleKind {
    BranchNamePattern,
    CodeCoverage,
    CodeQuality,
    CodeScanning,
    CommitAuthorEmailPattern,
    CommitMessagePattern,
    CommitterEmailPattern,
    CopilotCodeReview,
    Creation,
    Deletion,
    FileExtensionRestriction,
    FilePathRestriction,
    LicenseComplianceScanning,
    MaxFilePathLength,
    MaxFileSize,
    MergeQueue,
    NonFastForward,
    PullRequest,
    RequiredDeployments,
    RequiredLinearHistory,
    RequiredSignatures,
    RequiredStatusChecks,
    TagNamePattern,
    Update,
    Workflows,
    /// A word outside the documented set, which every reader of a rule set
    /// refuses.
    #[serde(other)]
    Other,
}

#[derive(Debug, Deserialize)]
pub(crate) struct Rule {
    /// Required (repos/rules, `type`: enum).
    #[serde(rename = "type")]
    pub(crate) kind: RuleKind,
    /// Optional, not documented nullable (repos/rules, `parameters`:
    /// object, not in the required list; several types take none). An
    /// object for every kind; the consumed kinds decode their shape from
    /// it (`evidence`), the others keep it opaque.
    #[serde(default)]
    pub(crate) parameters: Optional<Object>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct RequiredCheck {
    /// Required (repos/rules, status check configuration `context`;
    /// branches/branches, `checks[].context`).
    pub(crate) context: String,
}

#[derive(Debug, Deserialize)]
pub(crate) struct RequiredStatusChecksParameters {
    /// Required (repos/rules, `required_status_checks` parameters).
    pub(crate) required_status_checks: Vec<RequiredCheck>,
}

/// A required workflow: its path in the source repository, that
/// repository's id and, where the rule pins one, the source commit it runs
/// from. The four fields are the definition, sorted and
/// deduplicated, so `ref` is read for that
/// order alone: binding never resolves it.
#[derive(Debug, Clone, Deserialize)]
pub(super) struct RequiredWorkflow {
    /// Required (repos/rules, workflow file reference `path`).
    pub(super) path: String,
    /// Optional, not documented nullable (repos/rules, workflow file
    /// reference `ref`, not in the required list).
    #[serde(default, rename = "ref")]
    pub(super) reference: Optional<String>,
    /// Required (repos/rules, workflow file reference `repository_id`).
    pub(super) repository_id: u64,
    /// Optional, not documented nullable (repos/rules, workflow file
    /// reference `sha`, not in the required list).
    #[serde(default)]
    pub(super) sha: Optional<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct WorkflowsParameters {
    /// Required (repos/rules, `workflows` parameters).
    pub(super) workflows: Vec<RequiredWorkflow>,
}

// --- repos/repos -----------------------------------------------------------------

/// A repository by name (repos/repos, "Get a repository"): the lookup that
/// turns a source proof's `repositoryName` into the id a `workflows` rule
/// names.
#[derive(Debug, Deserialize)]
pub(super) struct Repository {
    /// Required (repos/repos, `id`: integer).
    pub(super) id: u64,
    /// Required (repos/repos, `full_name`: string).
    pub(super) full_name: String,
}

// --- graphql: the reply envelope ---------------------------------------------------

/// A GraphQL response (GraphQL specification § 7.1) as `gh api graphql`
/// prints it, over the data `D` of one query: `data`, null when the request
/// failed as a whole and absent on a request error, and `errors` when
/// anything failed. Each reader judges the errors: the nodes queries keep
/// the nodes a field error left null (`evidence::nodes_of`,
/// `GraphError::node_index`), the thread walk refuses any, the queue read
/// reports their messages.
#[derive(Debug, Deserialize)]
#[serde(bound(deserialize = "D: DeserializeOwned"))]
pub(crate) struct GraphReply<D> {
    /// Nullable, absent on a request error (graphql, response `data`).
    #[serde(default)]
    pub(crate) data: Nullable<D>,
    /// Optional (graphql, response `errors`: array).
    #[serde(default)]
    pub(crate) errors: Optional<Vec<GraphError>>,
}

/// One entry of a GraphQL response's `errors` (GraphQL specification
/// § 7.1.2 Errors): its `message`, and its `path`, since an error raised
/// while resolving a field leaves that field null and names it here
/// (§ 6.4.4 Handling Field Errors), so a client can tell a null the viewer
/// could not resolve from a null the server meant.
#[derive(Debug, Deserialize)]
pub(crate) struct GraphError {
    /// Required (§ 7.1.2: every error has a `message` string).
    pub(crate) message: String,
    /// Optional (§ 7.1.2: present when the error can be associated to a
    /// field; its segments are field names as strings and list indices as
    /// integers).
    #[serde(default)]
    pub(super) path: Optional<Vec<serde_json::Value>>,
}

impl GraphError {
    /// The index of the one node this error is about, where its path is
    /// exactly `["nodes", i]`: the shape of an id the viewer cannot resolve
    /// (§ 6.4.4; the field `nodes(ids:)` answers one entry per id). An
    /// error without a path, or at any other path, is about something else.
    pub(super) fn node_index(&self) -> Option<usize> {
        match self.path.present()?.as_slice() {
            [field, index] if field == "nodes" => {
                index.as_u64().and_then(|i| usize::try_from(i).ok())
            }
            _ => None,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(bound(deserialize = "N: DeserializeOwned"))]
pub(super) struct NodesData<N> {
    /// Required (graphql, `nodes(ids:)`: `[Node]!`, one entry per id, null
    /// where the id names nothing the viewer can see).
    pub(super) nodes: Vec<Nullable<N>>,
}

// --- graphql: the suite join -------------------------------------------------------

/// A check run node (graphql/reference/checks, object CheckRun), read for
/// the suite join REST omitted: its suite is `CheckSuite!`, so every check
/// run has one; the suite's `workflowRun` is the run it belongs to, where
/// an Actions workflow made it; the run's `workflow` is `Workflow!`, whose
/// `name` is `String!`, and its `event` is `String!`. This is the path
/// `gh pr checks` read a job's `workflow` and `event` through (gh v2.103.3
/// `api/query_builder.go:297`, `checkSuite{workflowRun{event,workflow{name}}}`;
/// `aggregate.go:67-68`).
#[derive(Debug, Deserialize)]
pub(super) struct CheckRunNode {
    /// Required (CheckRun `id`: `ID!`).
    pub(super) id: String,
    /// Required (CheckRun `checkSuite`: `CheckSuite!`).
    #[serde(rename = "checkSuite")]
    pub(super) check_suite: CheckSuiteOfRun,
}

/// The suite of a check run (object CheckSuite), the field the join reads.
#[derive(Debug, Deserialize)]
pub(super) struct CheckSuiteOfRun {
    /// Nullable (CheckSuite `workflowRun`: `WorkflowRun`): null for a
    /// suite no Actions workflow made.
    #[serde(rename = "workflowRun")]
    pub(super) workflow_run: Nullable<WorkflowRunOfSuite>,
}

/// The run a suite belongs to (object WorkflowRun), the fields the join
/// reads.
#[derive(Debug, Deserialize)]
pub(super) struct WorkflowRunOfSuite {
    /// Nullable (WorkflowRun `databaseId`: `Int`, "Identifies the primary
    /// key from the database"): the REST run `id`. A present run with a
    /// null id is a run the evidence cannot identify, never a suite without
    /// one (`evidence::SuiteRun::RunUnidentified`).
    #[serde(rename = "databaseId")]
    pub(super) database_id: Nullable<u64>,
    /// Required (WorkflowRun `event`: `String!`): the dispatch, one key of
    /// gh's deduplication (`aggregate.go:110`).
    pub(super) event: String,
    /// Required (WorkflowRun `workflow`: `Workflow!`).
    pub(super) workflow: WorkflowOfRun,
}

/// The workflow a run executed (object Workflow), the field the join reads.
#[derive(Debug, Deserialize)]
pub(super) struct WorkflowOfRun {
    /// Required (Workflow `name`: `String!`).
    pub(super) name: String,
}

// --- graphql: the source proof ---------------------------------------------------

/// A check suite node (graphql/reference, object CheckSuite), read for the
/// source proof (objects CheckSuite, WorkflowRun and WorkflowRunFile).
#[derive(Debug, Deserialize)]
pub(super) struct CheckSuiteNode {
    /// Required (CheckSuite `id`: `ID!`).
    pub(super) id: String,
    /// Nullable (CheckSuite `databaseId`: `Int`).
    #[serde(rename = "databaseId")]
    pub(super) database_id: Nullable<u64>,
    /// Nullable (CheckSuite `workflowRun`: `WorkflowRun`).
    #[serde(rename = "workflowRun")]
    pub(super) workflow_run: Nullable<WorkflowRunNode>,
}

/// The run a suite belongs to (graphql/reference, object WorkflowRun).
#[derive(Debug, Deserialize)]
pub(super) struct WorkflowRunNode {
    /// Nullable (WorkflowRun `databaseId`: `Int`).
    #[serde(rename = "databaseId")]
    pub(super) database_id: Nullable<u64>,
    /// Required (WorkflowRun `runAttempt`: `Int!`).
    #[serde(rename = "runAttempt")]
    pub(super) run_attempt: u64,
    /// Nullable (WorkflowRun `file`: `WorkflowRunFile`).
    pub(super) file: Nullable<WorkflowRunFile>,
}

/// The workflow file a run executed (graphql/reference, object
/// WorkflowRunFile): the source proof a required
/// definition binds against.
#[derive(Debug, Deserialize)]
pub(super) struct WorkflowRunFile {
    /// Required (WorkflowRunFile `path`: `String!`).
    pub(super) path: String,
    /// Required (WorkflowRunFile `repositoryName`: `URI!`): `owner/name`.
    #[serde(rename = "repositoryName")]
    pub(super) repository_name: String,
    /// Required (WorkflowRunFile `repositoryFileUrl`: `URI!`): the file at
    /// the commit it was read from.
    #[serde(rename = "repositoryFileUrl")]
    pub(super) repository_file_url: String,
    /// Required (WorkflowRunFile `viewerCanReadRepository`: `Boolean!`).
    #[serde(rename = "viewerCanReadRepository")]
    pub(super) viewer_can_read_repository: bool,
}

// --- branches/branches -------------------------------------------------------------

/// Classic protection's required checks.
#[derive(Debug, Deserialize)]
pub(crate) struct ProtectionChecks {
    /// Required (branches/branches, `required_status_checks.contexts`).
    pub(crate) contexts: Vec<String>,
    /// Required (branches/branches, `required_status_checks.checks`).
    pub(crate) checks: Vec<RequiredCheck>,
}

/// The branch's protection.
#[derive(Debug, Deserialize)]
pub(crate) struct Protection {
    /// Optional, not nullable (branches/branches, `protection.enabled`:
    /// boolean, not in the required list).
    #[serde(default)]
    pub(super) enabled: Optional<bool>,
    /// Optional, not nullable (branches/branches,
    /// `protection.required_status_checks`: object, not in the required
    /// list). Absent names nothing.
    #[serde(default)]
    pub(crate) required_status_checks: Optional<ProtectionChecks>,
}

/// The branch object (branches/branches, "Get a branch"). GitHub omits
/// `protection` from a caller without push access, so "nothing required"
/// cannot be told from "not shown" by the type: each reader judges an
/// absent protection, and a null one does not decode.
#[derive(Debug, Deserialize)]
pub(crate) struct Branch {
    /// Required (branches/branches, `commit`: commit).
    pub(crate) commit: BranchCommit,
    /// Required (branches/branches, `protected`: boolean).
    pub(super) protected: bool,
    /// Conditional, not nullable (branches/branches, `protection`: object,
    /// omitted from a caller without push access).
    #[serde(default)]
    pub(crate) protection: Optional<Protection>,
}

/// The branch's head commit (branches/branches, `commit`: `sha` and
/// `commit` required).
#[derive(Debug, Deserialize)]
pub(crate) struct BranchCommit {
    pub(crate) sha: String,
    pub(crate) commit: CommitBody,
}

/// The git commit (commits/commits, `commit.committer`: required,
/// nullable git user).
#[derive(Debug, Deserialize)]
pub(crate) struct CommitBody {
    pub(crate) committer: Nullable<Committer>,
}

/// A git user (commits/commits, `committer.date`: optional date-time).
#[derive(Debug, Deserialize)]
pub(crate) struct Committer {
    #[serde(default)]
    pub(crate) date: Optional<String>,
}

// --- gh pr view: the pull request ---------------------------------------------------

/// A pull request as `gh pr view N --repo O/R --json headRefOid,baseRefName,state`
/// exports it: gh's own JSON export, not a REST object. The three
/// are among the fields gh v2.103.3 lists for `pr view --json` (its usage
/// text with an empty `--json`), each printed for every asked field, so
/// each is required here. `headRefOid` is the head commit's id,
/// `baseRefName` the base branch, `state` GitHub's `PullRequestState`
/// (docs.github.com/en/graphql/reference/enums#pullrequeststate: `OPEN`,
/// `CLOSED`, `MERGED`); a word outside that set refuses the reply.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PullRequestView {
    #[serde(rename = "headRefOid")]
    pub head: String,
    #[serde(rename = "baseRefName")]
    pub base: String,
    pub state: PullRequestState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum PullRequestState {
    Open,
    Closed,
    Merged,
}

impl PullRequestState {
    /// The word GitHub names the state by.
    pub fn word(self) -> &'static str {
        match self {
            PullRequestState::Open => "OPEN",
            PullRequestState::Closed => "CLOSED",
            PullRequestState::Merged => "MERGED",
        }
    }
}

// --- the review gate: gh pr view, pulls, reviews, the timeline, threads -------------

/// A pull request as `gh pr view N --repo O/R --json
/// headRefOid,baseRefName,state,isDraft,reviewDecision,latestReviews,author`
/// exports it: the three fields of `PullRequestView` and four more; gh
/// prints every asked field, so each is required here.
/// `reviewDecision` is GitHub's `PullRequestReviewDecision` or null where
/// the base requires no review (`gh pr view --json reviewDecision` prints
/// `""` for that null); `latestReviews` is the latest review per reviewer.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ReviewView {
    #[serde(flatten)]
    pub pull: PullRequestView,
    #[serde(rename = "isDraft")]
    pub draft: bool,
    #[serde(rename = "reviewDecision")]
    pub decision: Nullable<String>,
    #[serde(rename = "latestReviews")]
    pub latest: Vec<LatestReview>,
    pub author: Actor,
}

/// One row of `latestReviews`: the reviewer as a GraphQL actor and the
/// review's state.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct LatestReview {
    pub author: Actor,
    pub state: String,
}

/// A GraphQL actor as gh exports it: a bot's login is `app/<slug>`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Actor {
    pub login: String,
}

/// A pull request as REST lists it (pulls/pulls, "List pull requests",
/// `pull-request-simple`) or gets it by number ("Get a pull request",
/// `pull-request`): the listed form is the got one less the fields only
/// the got form documents, of which `changed_files` is read here.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Pull {
    /// Required (pulls/pulls, `number`: integer).
    pub number: u64,
    /// Required (pulls/pulls, `state`: `open` or `closed`).
    pub state: String,
    /// Required (pulls/pulls, `title`: string).
    pub title: String,
    /// Required, nullable (pulls/pulls, `body`: string or null).
    pub body: Nullable<String>,
    /// Optional (pulls/pulls, `draft`: boolean, not in the required list).
    #[serde(default)]
    pub draft: Optional<bool>,
    /// Required, nullable (pulls/pulls, `merged_at`: date-time, null while
    /// unmerged).
    pub merged_at: Nullable<String>,
    /// Required, nullable (pulls/pulls, `merge_commit_sha`: string or null).
    pub merge_commit_sha: Nullable<String>,
    /// Required on the got form alone (pulls/pulls, `changed_files`:
    /// integer); absent from a listed one.
    #[serde(default)]
    pub changed_files: Optional<u64>,
    /// Required (pulls/pulls, `author_association`: string).
    pub author_association: String,
    pub head: PullHead,
    pub base: PullBase,
    /// Required, nullable (pulls/pulls, `user`: simple-user or null).
    pub user: Nullable<User>,
}

/// The head (pulls/pulls, `head`: `sha`, `ref` and `repo` required).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PullHead {
    pub sha: String,
    #[serde(rename = "ref")]
    pub branch: String,
    /// Required, nullable (pulls/pulls, `head.repo`): null for a deleted
    /// fork.
    pub repo: Nullable<HeadRepo>,
}

/// The head's repository (repos/repos, `repository`: `full_name` and
/// `owner` required).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct HeadRepo {
    pub full_name: String,
    pub owner: User,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PullBase {
    #[serde(rename = "ref")]
    pub branch: String,
}

/// A simple user (users, `simple-user`: `login` and `type` required): the
/// login REST spells an App as `<slug>[bot]`, and its `type`, `Bot` for an
/// App.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct User {
    pub login: String,
    #[serde(rename = "type")]
    pub kind: String,
}

/// An issue as REST lists it (issues/issues, "List repository issues",
/// which lists pull requests too, marked with `pull_request`) or gets it by
/// number ("Get an issue").
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct Issue {
    /// Required (issues/issues, `number`: integer).
    pub(crate) number: u64,
    /// Required (issues/issues, `state`: string).
    pub(crate) state: String,
    /// Optional, nullable (issues/issues, `state_reason`: string or null,
    /// not in the required list).
    #[serde(default)]
    pub(crate) state_reason: Nullable<String>,
    /// Required, nullable (issues/issues, `user`: simple-user or null).
    pub(crate) user: Nullable<User>,
    /// Required (issues/issues, `author_association`: string).
    pub(crate) author_association: String,
    /// Optional (issues/issues, `pull_request`: object), on a pull request
    /// alone.
    #[serde(default)]
    pub(crate) pull_request: Optional<Object>,
}

/// One review (pulls/reviews, "List reviews for a pull request").
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Review {
    /// Required (pulls/reviews, `id`: integer).
    pub id: u64,
    /// Required, nullable (pulls/reviews, `user`: simple-user or null).
    pub user: Nullable<User>,
    /// Required, nullable (pulls/reviews, `body`: string); null arrives
    /// for a review with no text.
    #[serde(default)]
    pub body: Nullable<String>,
    /// Required (pulls/reviews, `state`: string).
    pub state: String,
    /// Required, nullable (pulls/reviews, `commit_id`: string or null).
    pub commit_id: Nullable<String>,
    /// Optional (pulls/reviews, `submitted_at`: date-time, absent on a
    /// pending review).
    #[serde(default)]
    pub submitted_at: Optional<String>,
}

/// One timeline event (issues/timeline). The documented shape differs by
/// `event`, so every other field is read from the object where the event
/// kind needs it and refused there when it is not the documented type.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct TimelineEvent {
    /// Required (issues/timeline, `event`: string).
    pub event: String,
    #[serde(flatten)]
    pub fields: Object,
}

#[derive(Debug, Deserialize)]
pub struct ThreadsData {
    pub repository: Nullable<ThreadsRepository>,
}

#[derive(Debug, Deserialize)]
pub struct ThreadsRepository {
    #[serde(rename = "pullRequest")]
    pub pull_request: Nullable<ThreadsPullRequest>,
}

#[derive(Debug, Deserialize)]
pub struct ThreadsPullRequest {
    #[serde(rename = "reviewThreads")]
    pub review_threads: Nullable<ReviewThreads>,
}

#[derive(Debug, Deserialize)]
pub struct ReviewThreads {
    #[serde(rename = "pageInfo")]
    pub page_info: PageInfo,
    pub nodes: Vec<ReviewThread>,
}

#[derive(Debug, Deserialize)]
pub struct PageInfo {
    #[serde(rename = "hasNextPage")]
    pub has_next_page: bool,
    #[serde(rename = "endCursor")]
    pub end_cursor: Nullable<String>,
}

#[derive(Debug, Deserialize)]
pub struct ReviewThread {
    #[serde(rename = "isResolved")]
    pub is_resolved: bool,
}

/// A `pull_request` rule's parameters (repos/rules, `pull_request`): the
/// approval requirements the gate mode reads. The flags and the team list
/// are documented optional.
#[derive(Debug, Deserialize)]
pub(super) struct PullRequestParameters {
    pub(super) required_approving_review_count: u64,
    #[serde(default)]
    pub(super) require_code_owner_review: Optional<bool>,
    #[serde(default)]
    pub(super) require_last_push_approval: Optional<bool>,
    #[serde(default)]
    pub(super) required_reviewers: Optional<Vec<TeamReviewer>>,
}

#[derive(Debug, Deserialize)]
pub(super) struct TeamReviewer {
    pub(super) minimum_approvals: u64,
}

/// Classic branch protection (branches/branch-protection, "Get branch
/// protection"): `required_pull_request_reviews` is an object where
/// reviews are required and absent or null where none are.
#[derive(Debug, Deserialize)]
pub(super) struct ClassicProtection {
    #[serde(default)]
    pub(super) required_pull_request_reviews: Nullable<ClassicReviews>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ClassicReviews {
    #[allow(
        dead_code,
        reason = "documented required on the object: a count outside the whole numbers refuses the reply"
    )]
    pub(super) required_approving_review_count: u64,
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;

    /// How a field may be absent or null, as its declaration says.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Form {
        /// `T`: absent invalid, null invalid.
        Required,
        /// `#[serde(default)] Optional<T>`: absent ok, null invalid.
        Optional,
        /// `Nullable<T>` on a required key: absent invalid, null ok.
        Nullable,
        /// `#[serde(default)] Nullable<T>`: absent ok, null ok.
        OptionalNullable,
    }

    impl Form {
        fn absent_ok(self) -> bool {
            matches!(self, Form::Optional | Form::OptionalNullable)
        }
        fn null_ok(self) -> bool {
            matches!(self, Form::Nullable | Form::OptionalNullable)
        }
    }

    /// One struct's probes: the base decodes, and each listed field answers
    /// absence and null as its form says.
    fn catalogue<T: DeserializeOwned>(base: Value, rows: &[(&str, Form)]) {
        let name = std::any::type_name::<T>();
        let decodes = |probe: &Value| serde_json::from_value::<T>(probe.clone()).is_ok();
        assert!(decodes(&base), "{name}: the base probe must decode: {base}");
        for (field, form) in rows {
            let mut absent = base.clone();
            absent.as_object_mut().unwrap().remove(*field);
            assert_eq!(
                decodes(&absent),
                form.absent_ok(),
                "{name}.{field} absent ({form:?})"
            );
            let mut null = base.clone();
            null[*field] = Value::Null;
            assert_eq!(
                decodes(&null),
                form.null_ok(),
                "{name}.{field} null ({form:?})"
            );
        }
    }

    /// The wire structs' listed fields, each under null and under absence,
    /// answer as their documented form says. The rows are the fields the
    /// declarations above carry; review holds the list to the declarations.
    #[test]
    fn the_listed_wire_fields_answer_null_and_absence_as_documented() {
        use Form::*;
        catalogue::<CheckSuiteRef>(json!({"id": 5}), &[("id", Required)]);
        catalogue::<CheckRun>(
            json!({"id": 4, "node_id": "CR_4", "name": "build", "status": "completed", "conclusion": "success", "check_suite": {"id": 5}, "started_at": "2026-01-29T15:10:00Z", "completed_at": "2026-01-29T15:15:00Z", "html_url": "https://github.com/o/r/actions/runs/700/job/4", "details_url": "https://github.com/o/r/actions/runs/700/job/4"}),
            &[
                ("id", Required),
                ("node_id", Required),
                ("name", Required),
                ("status", Required),
                ("conclusion", Nullable),
                ("check_suite", Nullable),
                ("started_at", Nullable),
                ("completed_at", Nullable),
                ("html_url", Nullable),
                ("details_url", Nullable),
            ],
        );
        catalogue::<CheckRunsPage>(
            json!({"total_count": 0, "check_runs": []}),
            &[("total_count", Required), ("check_runs", Required)],
        );
        catalogue::<CheckSuitesPage>(
            json!({"total_count": 0, "check_suites": []}),
            &[("total_count", Required), ("check_suites", Required)],
        );
        catalogue::<CommitStatus>(
            json!({"context": "ci", "state": "success", "target_url": "https://x/actions/runs/1"}),
            &[
                ("context", Required),
                ("state", Required),
                ("target_url", Nullable),
            ],
        );
        catalogue::<CombinedStatusPage>(
            json!({"total_count": 0, "statuses": []}),
            &[("total_count", Required), ("statuses", Required)],
        );
        catalogue::<WorkflowRun>(
            json!({
                "id": 700, "path": ".github/workflows/ci.yml", "head_sha": "abc",
                "head_branch": "main", "status": "completed", "conclusion": "success",
                "workflow_id": 1, "event": "push", "created_at": "2026-01-29T15:08:00Z",
                "updated_at": "2026-01-29T15:16:00Z",
                "check_suite_id": 5, "check_suite_node_id": "MDEwOkNoZWNrU3VpdGU1", "run_attempt": 1,
                "run_started_at": "2026-01-29T15:09:00Z"
            }),
            &[
                ("id", Required),
                ("path", Required),
                ("head_sha", Required),
                ("head_branch", Nullable),
                ("status", Nullable),
                ("conclusion", Nullable),
                ("workflow_id", Required),
                ("event", Required),
                ("created_at", Required),
                ("updated_at", Required),
                ("check_suite_id", Optional),
                ("check_suite_node_id", Optional),
                ("run_attempt", Optional),
                ("run_started_at", Optional),
            ],
        );
        catalogue::<RunsPage>(
            json!({"total_count": 0, "workflow_runs": []}),
            &[("total_count", Required), ("workflow_runs", Required)],
        );
        catalogue::<Workflow>(
            json!({"id": 1, "name": "CI", "path": ".github/workflows/ci.yml", "state": "active"}),
            &[
                ("id", Required),
                ("name", Required),
                ("path", Required),
                ("state", Required),
            ],
        );
        catalogue::<WorkflowsPage>(
            json!({"total_count": 0, "workflows": []}),
            &[("total_count", Required), ("workflows", Required)],
        );
        catalogue::<Rule>(
            json!({"type": "creation", "parameters": {}}),
            &[("type", Required), ("parameters", Optional)],
        );
        catalogue::<RequiredCheck>(json!({"context": "build"}), &[("context", Required)]);
        catalogue::<RequiredStatusChecksParameters>(
            json!({"required_status_checks": []}),
            &[("required_status_checks", Required)],
        );
        catalogue::<RequiredWorkflow>(
            json!({"path": ".github/workflows/w.yml", "ref": "refs/heads/main", "repository_id": 7, "sha": "0123"}),
            &[
                ("path", Required),
                ("ref", Optional),
                ("repository_id", Required),
                ("sha", Optional),
            ],
        );
        catalogue::<WorkflowsParameters>(json!({"workflows": []}), &[("workflows", Required)]);
        catalogue::<Repository>(
            json!({"id": 7, "full_name": "owner/source"}),
            &[("id", Required), ("full_name", Required)],
        );
        catalogue::<GraphReply<NodesData<CheckSuiteNode>>>(
            json!({"data": {"nodes": []}, "errors": []}),
            &[("data", OptionalNullable), ("errors", Optional)],
        );
        catalogue::<NodesData<CheckSuiteNode>>(json!({"nodes": [null]}), &[("nodes", Required)]);
        catalogue::<GraphReply<NodesData<CheckRunNode>>>(
            json!({"data": {"nodes": []}, "errors": []}),
            &[("data", OptionalNullable), ("errors", Optional)],
        );
        catalogue::<NodesData<CheckRunNode>>(json!({"nodes": [null]}), &[("nodes", Required)]);
        catalogue::<GraphError>(
            json!({"message": "Could not resolve", "path": ["nodes", 0]}),
            &[("message", Required), ("path", Optional)],
        );
        catalogue::<CheckRunNode>(
            json!({"id": "CR_4", "checkSuite": {"workflowRun": null}}),
            &[("id", Required), ("checkSuite", Required)],
        );
        catalogue::<CheckSuiteOfRun>(
            json!({"workflowRun": {"databaseId": 700, "event": "push", "workflow": {"name": "CI"}}}),
            &[("workflowRun", Nullable)],
        );
        catalogue::<WorkflowRunOfSuite>(
            json!({"databaseId": 700, "event": "push", "workflow": {"name": "CI"}}),
            &[
                ("databaseId", Nullable),
                ("event", Required),
                ("workflow", Required),
            ],
        );
        catalogue::<WorkflowOfRun>(json!({"name": "CI"}), &[("name", Required)]);
        catalogue::<CheckSuiteNode>(
            json!({"id": "MDEwOkNoZWNrU3VpdGU1", "databaseId": 5, "workflowRun": null}),
            &[
                ("id", Required),
                ("databaseId", Nullable),
                ("workflowRun", Nullable),
            ],
        );
        catalogue::<WorkflowRunNode>(
            json!({"databaseId": 700, "runAttempt": 1, "file": null}),
            &[
                ("databaseId", Nullable),
                ("runAttempt", Required),
                ("file", Nullable),
            ],
        );
        catalogue::<WorkflowRunFile>(
            json!({"path": ".github/workflows/w.yml", "repositoryName": "owner/source", "repositoryFileUrl": "https://github.com/owner/source/blob/0123/.github/workflows/w.yml", "viewerCanReadRepository": true}),
            &[
                ("path", Required),
                ("repositoryName", Required),
                ("repositoryFileUrl", Required),
                ("viewerCanReadRepository", Required),
            ],
        );
        catalogue::<ProtectionChecks>(
            json!({"contexts": [], "checks": []}),
            &[("contexts", Required), ("checks", Required)],
        );
        catalogue::<Protection>(
            json!({"enabled": false, "required_status_checks": {"contexts": [], "checks": []}}),
            &[("enabled", Optional), ("required_status_checks", Optional)],
        );
        catalogue::<Branch>(
            json!({"commit": {"sha": "abc", "commit": {"committer": null}}, "protected": false, "protection": {}}),
            &[
                ("commit", Required),
                ("protected", Required),
                ("protection", Optional),
            ],
        );
        catalogue::<BranchCommit>(
            json!({"sha": "abc", "commit": {"committer": null}}),
            &[("sha", Required), ("commit", Required)],
        );
        catalogue::<CommitBody>(json!({"committer": null}), &[("committer", Nullable)]);
        catalogue::<Committer>(
            json!({"date": "2026-01-29T15:09:00Z"}),
            &[("date", Optional)],
        );
        catalogue::<User>(
            json!({"login": "owner", "type": "User"}),
            &[("login", Required), ("type", Required)],
        );
        catalogue::<HeadRepo>(
            json!({"full_name": "owner/repo", "owner": {"login": "owner", "type": "User"}}),
            &[("full_name", Required), ("owner", Required)],
        );
        catalogue::<PullHead>(
            json!({"sha": "abc", "ref": "feat", "repo": null}),
            &[("sha", Required), ("ref", Required), ("repo", Nullable)],
        );
        catalogue::<PullBase>(json!({"ref": "main"}), &[("ref", Required)]);
        catalogue::<Issue>(
            json!({"number": 7, "state": "open", "state_reason": null, "user": null, "author_association": "NONE", "pull_request": {}}),
            &[
                ("number", Required),
                ("state", Required),
                ("state_reason", OptionalNullable),
                ("user", Nullable),
                ("author_association", Required),
                ("pull_request", Optional),
            ],
        );
        catalogue::<Pull>(
            json!({
                "number": 7, "state": "open", "title": "feat", "body": null, "draft": false,
                "merged_at": null, "merge_commit_sha": null, "changed_files": 1, "author_association": "NONE",
                "head": {"sha": "abc", "ref": "feat", "repo": null}, "base": {"ref": "main"},
                "user": null
            }),
            &[
                ("number", Required),
                ("state", Required),
                ("title", Required),
                ("body", Nullable),
                ("draft", Optional),
                ("merged_at", Nullable),
                ("merge_commit_sha", Nullable),
                ("changed_files", Optional),
                ("author_association", Required),
                ("head", Required),
                ("base", Required),
                ("user", Nullable),
            ],
        );
    }

    /// The two wrappers keep absence, null and a value apart, and a present
    /// value outside the type refuses in both.
    #[test]
    fn the_wrappers_keep_absent_null_and_present_apart() {
        #[derive(Deserialize)]
        struct Probe {
            #[serde(default)]
            optional: Optional<u8>,
            #[serde(default)]
            nullable: Nullable<u8>,
        }
        let decoded: Probe = serde_json::from_str("{}").unwrap();
        assert_eq!(decoded.optional, Optional::Absent);
        assert_eq!(decoded.nullable, Nullable::Absent);
        let decoded: Probe = serde_json::from_str(r#"{"optional": 7, "nullable": null}"#).unwrap();
        assert_eq!(decoded.optional, Optional::Present(7));
        assert_eq!(decoded.nullable, Nullable::Null);
        let decoded: Probe = serde_json::from_str(r#"{"nullable": 7}"#).unwrap();
        assert_eq!(decoded.nullable, Nullable::Present(7));
        assert!(serde_json::from_str::<Probe>(r#"{"optional": null}"#).is_err());
        assert!(serde_json::from_str::<Probe>(r#"{"optional": "x"}"#).is_err());
        assert!(serde_json::from_str::<Probe>(r#"{"nullable": "x"}"#).is_err());
    }

    /// A field declared `Object` takes an object alone: an array, string or
    /// number on it refuses the reply whatever kind the rule has.
    #[test]
    fn a_declared_object_refuses_every_other_json_value() {
        let decodes = |parameters: Value| {
            serde_json::from_value::<Rule>(
                json!({"type": "code_quality", "parameters": parameters}),
            )
            .is_ok()
        };
        assert!(decodes(json!({})));
        assert!(decodes(json!({"severity_threshold": "high"})));
        for other in [json!([]), json!("x"), json!(7), json!(true)] {
            assert!(!decodes(other.clone()), "{other}");
        }
    }

    /// The run capture: the digits after `/actions/runs/`,
    /// wherever the link puts them.
    #[test]
    fn a_run_is_read_out_of_an_actions_link_as_the_legacy_read_it() {
        let rows = [
            ("https://github.com/o/r/actions/runs/700/job/4", Some(700)),
            ("https://github.com/o/r/actions/runs/700", Some(700)),
            (
                "https://github.com/o/r/actions/runs/700?check_suite_focus=true",
                Some(700),
            ),
            ("https://github.com/o/r/runs/4", None),
            ("https://github.com/o/r/actions/runs/", None),
            ("", None),
        ];
        for (url, expected) in rows {
            assert_eq!(run_in_url(url), expected, "{url}");
        }
    }
}
