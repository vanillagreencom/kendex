//! The evidence stage: the GitHub boundary returns one
//! validated, complete `Evidence` value or a refusal, and nothing else
//! reaches the judgement. Every member of every reply is validated here,
//! before any selection or reduction, so no member the selection would
//! later discard escapes validation. The judgement's entry
//! (`judge::judge`) takes an `Evidence` by value and nothing else: no page,
//! no `Value`, no bare wire member. Every field of `Evidence` and of its
//! member structs is private behind a read-only accessor, so `read` is the
//! type's one constructor; a test that needs one builds
//! it through a fake transport, as production does.
//!
//! Completeness is proven per endpoint, caps included. A reached cap is
//! `unreadable` with its cause and writes no record, never `pass` or
//! `none`:
//!
//! | Read | Pages | Completeness proof |
//! |---|---|---|
//! | `commits/{sha}/check-runs?filter=all` | every page; each page's `total_count` equal and the members adding up to it | The endpoint covers the ref's 1,000 most recent check suites (docs.github.com, checks/runs, "List check runs for a Git reference"), so its total alone proves only that window. The ref's check-suites count (next row) below `CHECK_SUITES_CAP` proves every suite of the ref is inside the window; then the total is the whole set. |
//! | `commits/{sha}/check-suites` | the first page, for `total_count` | The count is the endpoint's own total over the ref. At or above `CHECK_SUITES_CAP` the check-runs read is not proven whole: `check-runs-capped`. |
//! | `commits/{sha}/status` | every page; totals compared as above | The combined status is the latest status per context; GitHub documents no cap. |
//! | `actions/runs?head_sha={sha}` | every page; totals compared as above | GitHub caps a filtered run search at 1,000 results (docs.github.com, actions/workflow-runs). At or above `ACTIONS_SEARCH_CAP` members unseen runs can remain: `actions-runs-capped`. |
//! | `actions/workflows` | every page; totals compared as above | Read on every call: the first route to the workflow name a job's run carries (gh's rollup `workflow`, `CheckRunEvidence::workflow`), by the run's `workflow_id`, and the absence probe's active count. The list is the repository's current workflows, not a cover of every run's (a deleted file's runs remain; an organization or enterprise ruleset workflow is never listed), so membership is never a prerequisite for judging a run. |
//! | graphql `nodes(ids:)` over check-run nodes | one query per 100 ids | Read for the check runs whose REST suite join is absent (a null `check_suite`, or a suite no run on the head carries as its `check_suite_id`): the suite, its run with its event and that run's workflow name, as `gh pr checks` read them (`wire::CheckRunNode`); a null node there is `check-run-suites-response-invalid`, and a failed query there refuses with its own cause, since nothing else names the check's suite. Read too for every joined check whose run's workflow the list lacks: the second route to its workflow name, `checkSuite.workflowRun.workflow.name`, the path gh read every name through; the names its validated answers give are collected per workflow id, for the run REST joins each node's check to and for the held run the node's `workflowRun.databaseId` identifies, so a readable sibling node names a held run's workflow; a reply carrying `data` and errors that each name one node, `["nodes", i]`, keeps its other nodes and leaves node `i` null (GraphQL specification § 6.4.4), read from the output of the nonzero exit gh gives every reply carrying errors (`nodes_of`), and one carrying any other error is a failed query; a null node or a failed query is a failed route for a joined check, which continues to the route below (`check_run_suites`). |
//! | `actions/workflows/{id}` | one object per workflow id no graph answer named | The last route (`workflow_by_id`, gh's `pkg/cmd/run/shared/shared.go:456-470`): "Get a workflow" by the run's `workflow_id`, decoded through `wire::Workflow`; an answer naming another id is `workflow-response-invalid`, a failed request `workflow-read-failed`. Only a name no route gave is `unreadable`, never pass or fail. |
//! | `check-suites/{id}/check-runs` | every page; totals compared as above | One read per check suite of a required definition's candidate run, under the endpoint's default `filter`, `latest` ("Filters check runs by their completed_at timestamp. latest returns the most recent check runs.", rest/checks/runs): the bound-job list, which names no `filter`. The server's selection is consumed as it answers (`suite_jobs`); each member decodes through `wire::CheckRun` and an empty name is `suite-check-runs-response-invalid`. |
//! | `rules/branches/{base}` | bare array pages until a short page | No total is documented; a page shorter than the page size is the last. |
//! | `branches/{base}` | one object | A single object; absent or null protection refuses it. |
//! | graphql `nodes(ids:)` over the candidate runs' check-suite nodes | one query | One node per id (docs.github.com/en/graphql, `nodes`); a null node, error-free or named by a field error at its path `["nodes", i]` (`nodes_of`, the same reading as the check-run nodes above), is an id the viewer cannot resolve and leaves its candidate unproven, the definition pending `expected` with no record, an unreadable required set being no verdict; a reply carrying any other error is a failed query. Read only when a `workflows` rule names a definition some run on the head executed by path. |
//! | `repos/{owner}/{name}` per source repository a proof names | one object | A single object whose `full_name` must be the name asked for; read only for the names the proofs of a fully proven definition carry. |
//!
//! Per-member validation, over every member of every reply: a check run
//! or Actions run that is `completed` with a null `conclusion`, or without
//! the key, is `response-invalid` (`wire::outcome`); an empty check name or
//! status context is invalid; a run of another head is invalid; a rule's
//! `parameters` is an object for every kind (`wire::Object`), and the two
//! consumed kinds decode their shape from it; a required workflow without
//! an explicit source sha is `workflow-source-unbound`.
//!
//! The association of a check or status with an Actions run is read
//! here and carried as one
//! of three states (`Association`): the link, the check run's `details_url`
//! that `gh pr checks` printed (gh v2.103.3 `aggregate.go:51`), names the
//! run, and the check's suite, where it
//! names a run, is the agreeing second source; a link naming a run the
//! evidence does not hold, a suite and link that disagree, or a suite whose
//! run GitHub names but does not identify (`SuiteRun::RunUnidentified`) is
//! `Unresolved`, a distinct state the selection places where the entry
//! stood and the classification never reads as a proved external
//! failure while a substantive run is unfinished. A bound run's jobs are
//! not derived from these joins: they are the suite's own listing
//! (`suite_jobs`), whose `html_url` is matched by equality.
//!
//! The required-definition binding proof: a definition is the complete
//! rule, `repository_id`, `path` and the pinned `sha` (its `ref`
//! orders the walk and binds nothing). Its candidates are the head's runs
//! whose own workflow file is the definition's path (the head and
//! the consumer repository are pinned by the runs endpoint). Each
//! candidate's proof is the workflow file its check suite's run executed,
//! read through the suite node: the node must name the
//! candidate's suite, run and attempt and a readable file whose repository
//! is `owner/name`, else the candidate is unproven and the definition
//! cannot bind (`selection::bind`). The repositories the proofs name are
//! looked up for their ids, so the rule's `repository_id` is
//! matched against a repository the proof named, never assumed.

use std::collections::{BTreeMap, BTreeSet};

use crate::ops::VerifyHead;

use super::review::COPILOT_REVIEWER;
use super::wire::{
    Branch, CheckRun, CheckRunNode, CheckRunsPage, CheckSuiteNode, CheckSuitesPage,
    CombinedStatusPage, Nullable, Optional, Outcome, Repository, RequiredStatusChecksParameters,
    Rule, RuleKind, RunsPage, StatusState, Workflow, WorkflowRun, WorkflowState, WorkflowsPage,
    WorkflowsParameters, run_in_url,
};
use super::wire::{Review, RunStatus, TimelineEvent};
use super::{Cause, Endpoint, Gh, Read, Reader, Unreadable, segment};

/// GitHub's bound on a filtered run search: a `head_sha` search answers at
/// most this many runs, so a set this large is not proven whole.
pub(super) const ACTIONS_SEARCH_CAP: usize = 1000;

/// The check-runs endpoint covers a ref's most recent check suites up to
/// this count; a ref with this many suites is not proven whole.
pub(super) const CHECK_SUITES_CAP: usize = 1000;

/// The most ids one `nodes(ids:)` query asks for.
const NODES_PER_QUERY: usize = 100;

/// Everything the judgement may see, validated and complete.
#[derive(Debug)]
pub(super) struct Evidence {
    /// Every check run on the head, every attempt's (`filter=all`).
    check_runs: Vec<CheckRunEvidence>,
    /// The latest commit status per context.
    statuses: Vec<StatusEvidence>,
    /// Every Actions run on the head.
    runs: Vec<RunEvidence>,
    /// The base's required set, read under `required_only`; `None` is the
    /// default mode, where every check counts.
    required: Option<RequiredEvidence>,
}

impl Evidence {
    pub(super) fn check_runs(&self) -> &[CheckRunEvidence] {
        &self.check_runs
    }

    pub(super) fn statuses(&self) -> &[StatusEvidence] {
        &self.statuses
    }

    pub(super) fn runs(&self) -> &[RunEvidence] {
        &self.runs
    }

    pub(super) fn required(&self) -> Option<&RequiredEvidence> {
        self.required.as_ref()
    }

    pub(super) fn run(&self, id: u64) -> Option<&RunEvidence> {
        self.runs.iter().find(|r| r.id == id)
    }
}

/// How a check or status is associated with an Actions run on the head
///
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Association {
    /// The link names a run the evidence holds, and the suite, where it
    /// names a run, names the same one.
    Run(u64),
    /// Neither the link nor the suite names a run: an external check or
    /// status, a run-less member.
    None,
    /// The link names a run the evidence does not hold, or the suite names
    /// a run while the link names another or none, or the suite's run is
    /// one GitHub does not identify. `linked` is the run the link names,
    /// where the evidence holds it.
    Unresolved { linked: Option<u64> },
}

/// The run a check run's suite belongs to, as GitHub's graph names it
/// : none (`CheckSuite.workflowRun` null: no Actions
/// workflow made the suite), one the evidence identifies (the run whose
/// `check_suite_id` is the suite, or the node's `workflowRun.databaseId`),
/// or one GitHub names but does not identify (a `WorkflowRun` present whose
/// `databaseId` is null). The third is never read as the first: it is an
/// unresolved association (`association`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SuiteRun {
    NoRun,
    Run(u64),
    RunUnidentified,
}

#[derive(Debug)]
pub(super) struct CheckRunEvidence {
    /// The check run's id: the second key among check runs started alike
    /// in the rollup, after the listing position
    /// (`selection::eliminate_duplicates`); the judgement names a check by
    /// its link.
    id: u64,
    name: String,
    outcome: Outcome,
    /// The suite's run's workflow name, `""` where the suite has no run
    /// (an Actions workflow made none): gh's rollup `workflow`
    /// (gh v2.103.3 `aggregate.go:68`, `CheckSuite.workflowRun.workflow.name`),
    /// which grouped a run's jobs. Resolved by `check_run_suites` through
    /// the three routes below.
    workflow: String,
    /// The suite's run's dispatch event, `""` where the suite has no run:
    /// gh's `c.CheckSuite.WorkflowRun.Event` (`aggregate.go:67`), one key
    /// of its deduplication (`:110`).
    event: String,
    /// When it started, where recorded (gh's `startedAt`).
    started: Option<String>,
    /// The `details_url`, gh's rollup `link` (`aggregate.go:51`).
    link: Option<String>,
    /// The run the link names, whether or
    /// not the evidence holds that run.
    linked: Option<u64>,
    /// Whether the link names a run itself rather than a job of it (the
    /// aggregate link).
    run_level: bool,
    association: Association,
}

impl CheckRunEvidence {
    pub(super) fn id(&self) -> u64 {
        self.id
    }

    pub(super) fn name(&self) -> &str {
        &self.name
    }

    pub(super) fn outcome(&self) -> Outcome {
        self.outcome
    }

    pub(super) fn workflow(&self) -> &str {
        &self.workflow
    }

    pub(super) fn event(&self) -> &str {
        &self.event
    }

    pub(super) fn started(&self) -> Option<&str> {
        self.started.as_deref()
    }

    pub(super) fn link(&self) -> Option<&str> {
        self.link.as_deref()
    }

    pub(super) fn linked(&self) -> Option<u64> {
        self.linked
    }

    pub(super) fn run_level(&self) -> bool {
        self.run_level
    }

    pub(super) fn association(&self) -> Association {
        self.association
    }
}

#[derive(Debug)]
pub(super) struct StatusEvidence {
    context: String,
    state: StatusState,
    /// The run the status's link names.
    linked: Option<u64>,
    /// Whether the link names the run itself rather than a job of it (the
    /// aggregate link): only such an aggregate is held behind a
    /// newer run of its workflow.
    run_level: bool,
    /// The link itself, matched by equality against a
    /// required workflow's job links.
    target: Option<String>,
    association: Association,
}

impl StatusEvidence {
    pub(super) fn context(&self) -> &str {
        &self.context
    }

    pub(super) fn state(&self) -> StatusState {
        self.state
    }

    pub(super) fn linked(&self) -> Option<u64> {
        self.linked
    }

    pub(super) fn run_level(&self) -> bool {
        self.run_level
    }

    pub(super) fn target(&self) -> Option<&str> {
        self.target.as_deref()
    }

    pub(super) fn association(&self) -> Association {
        self.association
    }
}

#[derive(Debug)]
pub(super) struct RunEvidence {
    id: u64,
    workflow_id: u64,
    /// The workflow file as GitHub names it at the run, with its ref after
    /// `@` where one is appended.
    path: String,
    event: String,
    outcome: Outcome,
    /// `run_attempt`, 1 where omitted.
    attempt: u64,
    /// `run_started_at`, `updated_at` where omitted.
    started: String,
    updated_at: String,
    suite: Option<u64>,
    /// The suite's node id, which the source proof is read through.
    suite_node: Option<String>,
}

impl RunEvidence {
    pub(super) fn id(&self) -> u64 {
        self.id
    }

    pub(super) fn workflow_id(&self) -> u64 {
        self.workflow_id
    }

    /// The workflow file without its ref.
    pub(super) fn file(&self) -> &str {
        self.path.split('@').next().unwrap_or_default()
    }

    pub(super) fn event(&self) -> &str {
        &self.event
    }

    pub(super) fn outcome(&self) -> Outcome {
        self.outcome
    }

    pub(super) fn attempt(&self) -> u64 {
        self.attempt
    }

    pub(super) fn started(&self) -> &str {
        &self.started
    }

    pub(super) fn updated_at(&self) -> &str {
        &self.updated_at
    }

    pub(super) fn suite(&self) -> Option<u64> {
        self.suite
    }
}

/// The base's required set and the facts the absence probe reads.
#[derive(Debug)]
pub(super) struct RequiredEvidence {
    contexts: Vec<String>,
    /// The required workflow definitions, sorted and deduplicated as the
    /// jq's `unique` leaves them: the order
    /// the selection walks them in.
    workflows: Vec<RequiredWorkflowEvidence>,
    /// The repositories the proofs named, each looked up by that name.
    sources: Vec<SourceRepository>,
    /// Each candidate run's check suite as GitHub lists its check runs
    /// under the default `filter`, by suite id (`suite_jobs`).
    suites: BTreeMap<u64, Vec<SuiteJob>>,
    /// Rules that gate on checks, counted for the absence probe: a rule
    /// naming no context still says CI is configured.
    gating_rules: usize,
    protected: bool,
    /// The repository's active workflows, the absence probe's count.
    active_workflows: usize,
}

impl RequiredEvidence {
    pub(super) fn contexts(&self) -> &[String] {
        &self.contexts
    }

    pub(super) fn workflows(&self) -> &[RequiredWorkflowEvidence] {
        &self.workflows
    }

    pub(super) fn sources(&self) -> &[SourceRepository] {
        &self.sources
    }

    /// The check runs GitHub lists for `suite` under `filter=latest`, read
    /// for every candidate run's suite; `None` for a suite no candidate
    /// run carries.
    pub(super) fn suite_jobs(&self, suite: u64) -> Option<&[SuiteJob]> {
        self.suites.get(&suite).map(Vec::as_slice)
    }

    pub(super) fn gating_rules(&self) -> usize {
        self.gating_rules
    }

    pub(super) fn protected(&self) -> bool {
        self.protected
    }

    pub(super) fn active_workflows(&self) -> usize {
        self.active_workflows
    }

    /// Whether the set names anything to judge by; an empty set falls back
    /// to every check.
    pub(super) fn names_anything(&self) -> bool {
        !self.contexts.is_empty() || !self.workflows.is_empty()
    }
}

/// A required workflow definition with its candidate executions.
#[derive(Debug)]
pub(super) struct RequiredWorkflowEvidence {
    repository_id: u64,
    path: String,
    /// The source commit the rule pins.
    sha: String,
    /// The rule's `ref`, kept for the walk order alone.
    reference: Option<String>,
    /// The head's runs whose own workflow file is the definition's path.
    candidates: Vec<Candidate>,
}

impl RequiredWorkflowEvidence {
    pub(super) fn repository_id(&self) -> u64 {
        self.repository_id
    }

    pub(super) fn path(&self) -> &str {
        &self.path
    }

    pub(super) fn sha(&self) -> &str {
        &self.sha
    }

    pub(super) fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }

    /// jq's object order, which `unique` sorted the definitions by: the
    /// sorted key sets first (a definition with a `ref` has the key set
    /// `[path, ref, repository_id, sha]`, which sorts before
    /// `[path, repository_id, sha]`), then the values key by key.
    fn order_key(&self) -> (bool, &str, Option<&str>, u64, &str) {
        (
            self.reference.is_none(),
            &self.path,
            self.reference.as_deref(),
            self.repository_id,
            &self.sha,
        )
    }
}

/// One member of a check suite's listing under GitHub's `latest` filter:
/// `{name, link: .html_url}`,
/// the page nullable as the wire documents it.
#[derive(Debug)]
pub(super) struct SuiteJob {
    name: String,
    page: Option<String>,
}

impl SuiteJob {
    pub(super) fn name(&self) -> &str {
        &self.name
    }

    pub(super) fn page(&self) -> Option<&str> {
        self.page.as_deref()
    }
}

/// One run that executed a required definition's path, with the source
/// proof its suite node gave, or none when any part of that proof failed.
#[derive(Debug)]
pub(super) struct Candidate {
    run: u64,
    proof: Option<SourceProof>,
}

impl Candidate {
    pub(super) fn run(&self) -> u64 {
        self.run
    }

    pub(super) fn proof(&self) -> Option<&SourceProof> {
        self.proof.as_ref()
    }
}

/// The workflow file a candidate's run executed, as its suite node proved
/// it: the file's path, its `owner/name` repository and the URL of the file
/// at the commit it was read from.
#[derive(Debug)]
pub(super) struct SourceProof {
    path: String,
    repository_name: String,
    file_url: String,
}

impl SourceProof {
    pub(super) fn path(&self) -> &str {
        &self.path
    }

    pub(super) fn repository_name(&self) -> &str {
        &self.repository_name
    }

    pub(super) fn file_url(&self) -> &str {
        &self.file_url
    }
}

/// A repository a proof named, looked up by that name for its id.
#[derive(Debug)]
pub(super) struct SourceRepository {
    /// The name as the proof spelt it and the lookup asked for it.
    name: String,
    id: u64,
    full_name: String,
}

impl SourceRepository {
    pub(super) fn name(&self) -> &str {
        &self.name
    }

    pub(super) fn id(&self) -> u64 {
        self.id
    }

    pub(super) fn full_name(&self) -> &str {
        &self.full_name
    }
}

/// Read and validate everything the judgement may see for the request's
/// pinned head and base. The first refusal ends the read set.
pub(super) fn read(gh: &Gh, r: &VerifyHead) -> Read<Evidence> {
    let gh = Reader { gh };
    let commit = format!("repos/{}/commits/{}", r.repo, r.head);
    let check_runs = gh.collection::<CheckRunsPage>(
        Endpoint::CheckRuns,
        &format!("{commit}/check-runs?filter=all"),
    )?;
    if check_runs.iter().any(CheckRun::undocumented) {
        return Err(Cause::ResponseInvalid(Endpoint::CheckRuns));
    }
    let suites: CheckSuitesPage = gh.object(
        Endpoint::CheckSuites,
        &super::paged(&format!("{commit}/check-suites"), 1),
    )?;
    if suites.total_count >= CHECK_SUITES_CAP {
        return Err(Cause::Capped(Endpoint::CheckRuns));
    }
    let statuses =
        gh.collection::<CombinedStatusPage>(Endpoint::Statuses, &format!("{commit}/status"))?;
    let runs = gh.collection::<RunsPage>(
        Endpoint::ActionsRuns,
        &format!("repos/{}/actions/runs?head_sha={}", r.repo, r.head),
    )?;
    if runs.iter().any(WorkflowRun::undocumented) {
        return Err(Cause::ResponseInvalid(Endpoint::ActionsRuns));
    }
    if runs.len() >= ACTIONS_SEARCH_CAP {
        return Err(Cause::Capped(Endpoint::ActionsRuns));
    }
    let workflows = gh.collection::<WorkflowsPage>(
        Endpoint::Workflows,
        &format!("repos/{}/actions/workflows", r.repo),
    )?;
    if workflows.iter().any(|w| w.state == WorkflowState::Other) {
        return Err(Cause::ResponseInvalid(Endpoint::Workflows));
    }
    let active_workflows = workflows
        .iter()
        .filter(|w| w.state == WorkflowState::Active)
        .count();

    let runs = runs
        .iter()
        .map(|run| workflow_run(run, &r.head))
        .collect::<Read<Vec<_>>>()?;
    let check_runs = check_run_suites(&gh, r, &check_runs, &runs, &workflows)?;
    let statuses = statuses
        .iter()
        .map(|status| {
            if status.context.is_empty() {
                return Err(Cause::ResponseInvalid(Endpoint::Statuses));
            }
            let (linked, run_level, target) = match &status.target_url {
                Nullable::Absent | Nullable::Null => (None, false, None),
                Nullable::Present(url) => (run_in_url(url), run_level(url), Some(url.clone())),
            };
            Ok(StatusEvidence {
                context: status.context.clone(),
                state: status.state,
                linked,
                run_level,
                target,
                association: association(linked, SuiteRun::NoRun, &runs),
            })
        })
        .collect::<Read<Vec<_>>>()?;

    let required = if r.required_only {
        Some(required_set(&gh, r, &runs, active_workflows)?)
    } else {
        None
    };
    Ok(Evidence {
        check_runs,
        statuses,
        runs,
        required,
    })
}

/// The association of a member whose link names `linked` and whose suite's
/// run is `suite_run`: a run GitHub names
/// but does not identify agrees with nothing and is never read as no run.
fn association(linked: Option<u64>, suite_run: SuiteRun, runs: &[RunEvidence]) -> Association {
    let held = |id: u64| runs.iter().any(|run| run.id == id);
    match (linked, suite_run) {
        (None, SuiteRun::NoRun) => Association::None,
        (Some(run), SuiteRun::NoRun) if held(run) => Association::Run(run),
        (Some(run), SuiteRun::Run(of_suite)) if held(run) && of_suite == run => {
            Association::Run(run)
        }
        (linked, SuiteRun::NoRun | SuiteRun::Run(_) | SuiteRun::RunUnidentified) => {
            Association::Unresolved {
                linked: linked.filter(|run| held(*run)),
            }
        }
    }
}

/// The last route to a run's workflow name: "Get a
/// workflow" by the run's `workflow_id`, which gh reads for a run its
/// workflow list lacks (gh v2.103.3 `pkg/cmd/run/shared/shared.go:456-470`):
///
/// ```go
///     for i, run := range runs {
///         if _, ok := workflowMap[run.WorkflowID]; !ok {
///             // Look up workflow by ID because it may have been deleted
///             workflow, err := workflowShared.GetWorkflow(client, repo, run.WorkflowID)
///             // If the error is an httpError and it is a 404, this is likely a
///             // organization or enterprise ruleset workflow. The user does not
///             // have permissions to view the details of the workflow, so we cannot
///             // look it up directly without receiving a 404, but it is nonetheless
///             // in the workflow run list. To handle this, we set the workflow name
///             // to an empty string.
///             // Deciding to put this here instead of in GetWorkflow to allow
///             // the caller to decide what a 404 means.
///             if httpErr, ok := err.(api.HTTPError); ok && httpErr.StatusCode == 404 {
///                 workflowMap[run.WorkflowID] = ""
///                 continue
///             }
///             if err != nil {
///                 return err
///             }
///             workflowMap[run.WorkflowID] = workflow.Name
/// ```
///
/// `GetWorkflow` is `GET repos/{owner}/{repo}/actions/workflows/{id}`
/// (`pkg/cmd/workflow/shared/shared.go:151-173`). gh names a 404 workflow
/// `""`, the organization or enterprise ruleset workflow its comment
/// describes; `gh pr checks` takes every name from the graph. This read is reached only after the graph
/// gave no name, so its failure is a name no route gave: a failed request
/// is `workflow-read-failed`, an answer naming another workflow than the
/// one asked for `workflow-response-invalid`, and either is `unreadable`,
/// never pass or fail. `names` holds the names already known per workflow
/// id, the graph's answers among them: a known id is answered without a
/// read, and one read per unknown id is kept there.
fn workflow_by_id(
    gh: &Reader<'_>,
    r: &VerifyHead,
    id: u64,
    names: &mut BTreeMap<u64, String>,
) -> Read<String> {
    if let Some(name) = names.get(&id) {
        return Ok(name.clone());
    }
    let workflow: Workflow = gh.object(
        Endpoint::Workflow,
        &format!("repos/{}/actions/workflows/{id}", r.repo),
    )?;
    if workflow.id != id || workflow.state == WorkflowState::Other {
        return Err(Cause::ResponseInvalid(Endpoint::Workflow));
    }
    names.insert(id, workflow.name.clone());
    Ok(workflow.name)
}

/// Every check run with its suite join and its workflow name. The join is
/// REST's where the check names a suite some run on the head carries, else
/// the check-run node's, as `gh pr checks` read it. The name is resolved in
/// this order: the repository's workflow list by the
/// run's `workflow_id`; the graph, `checkSuite.workflowRun.workflow.name`
/// on the check's node (the path gh read every name through, gh v2.103.3
/// `api/query_builder.go:297`), the names of every validated node
/// collected per workflow id, for the run REST joins the node's check to
/// and for the held run the node's `workflowRun.databaseId` identifies, so
/// a readable sibling node names a held run's workflow; the REST detail
/// by id (`workflow_by_id`); a refusal only when every route failed. For a joined check a null node
/// (an error-free null, or one a field error names, `nodes_of`) and a
/// failed query (the transport, or a reply carrying any other error or no
/// data) are a failed route, and the detail is tried; for an unjoined
/// check the null node is `check-run-suites-response-invalid` and the
/// failed query refuses with its cause, since nothing else names its
/// suite. A reply answering another count or another id than asked is not
/// the documented shape and refuses. A node whose suite names no run while
/// REST joins the check to one is not the documented answer. A run no
/// check joins needs no name: the rollup never shows one.
fn check_run_suites(
    gh: &Reader<'_>,
    r: &VerifyHead,
    check_runs: &[CheckRun],
    runs: &[RunEvidence],
    workflows: &[Workflow],
) -> Read<Vec<CheckRunEvidence>> {
    let listed: BTreeMap<u64, &str> = workflows.iter().map(|w| (w.id, w.name.as_str())).collect();
    let run_of_suite = |suite: u64| runs.iter().find(|run| run.suite == Some(suite));
    let joined = |check: &CheckRun| check.suite().and_then(run_of_suite);
    let asked: Vec<&CheckRun> = check_runs
        .iter()
        .filter(|check| joined(check).is_none_or(|run| !listed.contains_key(&run.workflow_id)))
        .collect();
    // The graph route's answer per asked id: the node, `None` where the
    // viewer cannot resolve it (GitHub answers `nodes(ids:)` one entry per
    // id, in order), or the failure of the query that asked for it.
    let mut nodes: BTreeMap<&str, Read<Option<CheckRunNode>>> = BTreeMap::new();
    for chunk in asked.chunks(NODES_PER_QUERY) {
        let ids: Vec<&str> = chunk.iter().map(|check| check.node_id.as_str()).collect();
        let answered = match gh.check_run_nodes(&ids) {
            Ok(answered) => answered,
            Err(cause) => {
                for id in ids {
                    nodes.insert(id, Err(cause.clone()));
                }
                continue;
            }
        };
        if answered.len() != ids.len() {
            return Err(Cause::ResponseInvalid(Endpoint::CheckRunSuites));
        }
        for (id, node) in ids.into_iter().zip(answered) {
            let node = match node {
                Nullable::Absent | Nullable::Null => None,
                Nullable::Present(node) if node.id == id => Some(node),
                Nullable::Present(_) => {
                    return Err(Cause::ResponseInvalid(Endpoint::CheckRunSuites));
                }
            };
            nodes.insert(id, Ok(node));
        }
    }
    // The workflow names known per workflow id: the graph's validated
    // answers first, then each detail read. A validated node names the
    // workflow of the run REST joins its check to, and of the held run its
    // own `workflowRun.databaseId` identifies; a node
    // whose run GitHub does not identify names nothing here.
    let mut names: BTreeMap<u64, String> = BTreeMap::new();
    for check in check_runs {
        let Some(Ok(Some(node))) = nodes.get(check.node_id.as_str()) else {
            continue;
        };
        let Nullable::Present(graph_run) = &node.check_suite.workflow_run else {
            continue;
        };
        let identified = match graph_run.database_id {
            Nullable::Present(id) => runs.iter().find(|run| run.id == id),
            Nullable::Absent | Nullable::Null => None,
        };
        for run in joined(check).into_iter().chain(identified) {
            names
                .entry(run.workflow_id)
                .or_insert_with(|| graph_run.workflow.name.clone());
        }
    }
    let mut evidence = Vec::with_capacity(check_runs.len());
    for check in check_runs {
        if check.name.is_empty() {
            return Err(Cause::ResponseInvalid(Endpoint::CheckRuns));
        }
        let node = nodes.get(check.node_id.as_str());
        let (suite_run, workflow, event) = match joined(check) {
            Some(run) => {
                let workflow = match listed.get(&run.workflow_id) {
                    Some(name) => (*name).to_owned(),
                    None => match node {
                        Some(Ok(Some(node))) => match &node.check_suite.workflow_run {
                            Nullable::Present(graph_run) => graph_run.workflow.name.clone(),
                            Nullable::Absent | Nullable::Null => {
                                return Err(Cause::ResponseInvalid(Endpoint::CheckRunSuites));
                            }
                        },
                        Some(Ok(None) | Err(_)) => {
                            workflow_by_id(gh, r, run.workflow_id, &mut names)?
                        }
                        None => return Err(Cause::ResponseInvalid(Endpoint::CheckRunSuites)),
                    },
                };
                (SuiteRun::Run(run.id), workflow, run.event.clone())
            }
            None => {
                let node = match node {
                    Some(Ok(Some(node))) => node,
                    Some(Err(cause)) => return Err(cause.clone()),
                    Some(Ok(None)) | None => {
                        return Err(Cause::ResponseInvalid(Endpoint::CheckRunSuites));
                    }
                };
                match &node.check_suite.workflow_run {
                    Nullable::Absent | Nullable::Null => {
                        (SuiteRun::NoRun, String::new(), String::new())
                    }
                    Nullable::Present(run) => {
                        let identity = match run.database_id {
                            Nullable::Absent | Nullable::Null => SuiteRun::RunUnidentified,
                            Nullable::Present(id) => SuiteRun::Run(id),
                        };
                        (identity, run.workflow.name.clone(), run.event.clone())
                    }
                }
            }
        };
        let (linked, run_level) = match check.details() {
            None => (None, false),
            Some(url) => (run_in_url(url), run_level(url)),
        };
        evidence.push(CheckRunEvidence {
            id: check.id,
            name: check.name.clone(),
            outcome: check.outcome()?,
            workflow,
            event,
            started: check.started().map(str::to_owned),
            link: check.details().map(str::to_owned),
            linked,
            run_level,
            association: association(linked, suite_run, runs),
        });
    }
    Ok(evidence)
}

/// A check suite's check runs as GitHub lists them under the endpoint's
/// default `filter`, `latest`: the suite read for a bound run (quoted at
/// `selection::bound_jobs`), which names no `filter`. The server's selection is consumed as
/// answered, pages validated like every collection; each member decodes
/// through `wire::CheckRun`, so a completed member without a conclusion
/// refuses, and an empty name is not the documented shape. Nothing here
/// selects among members.
fn suite_jobs(gh: &Reader<'_>, r: &VerifyHead, suite: u64) -> Read<Vec<SuiteJob>> {
    let members = gh.collection::<CheckRunsPage>(
        Endpoint::SuiteCheckRuns,
        &format!("repos/{}/check-suites/{suite}/check-runs", r.repo),
    )?;
    members
        .iter()
        .map(|check| {
            if check.outcome().is_err() || check.name.is_empty() {
                return Err(Cause::ResponseInvalid(Endpoint::SuiteCheckRuns));
            }
            Ok(SuiteJob {
                name: check.name.clone(),
                page: check.page().map(str::to_owned),
            })
        })
        .collect()
}

/// The runs were asked for by the pinned sha; one of another head is not
/// the answer to that question.
fn workflow_run(run: &WorkflowRun, head: &str) -> Read<RunEvidence> {
    if run.head_sha != head {
        return Err(Cause::ResponseInvalid(Endpoint::ActionsRuns));
    }
    Ok(RunEvidence {
        id: run.id,
        workflow_id: run.workflow_id,
        path: run.path.clone(),
        event: run.event.clone(),
        outcome: run.outcome()?,
        attempt: run.attempt(),
        started: run.started().to_owned(),
        updated_at: run.updated_at.clone(),
        suite: run.suite(),
        suite_node: run.suite_node().map(str::to_owned),
    })
}

/// Whether a link names a run itself: `/actions/runs/<id>` with nothing
/// after the id.
fn run_level(url: &str) -> bool {
    let url = url.strip_suffix('/').unwrap_or(url);
    url.rsplit_once("/actions/runs/")
        .is_some_and(|(_, digits)| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
}

/// The contexts `base` requires, each once, and whether a merge-queue
/// rule stands, read as the verification reads them (`base_requirement`).
/// `repo` is `owner/name`.
pub(crate) fn required_contexts(
    gh: &Gh<'_>,
    repo: &str,
    base: &str,
) -> std::result::Result<(Vec<String>, bool), Unreadable> {
    let set = base_requirement(&Reader { gh }, repo, base)?;
    Ok((set.contexts.into_iter().collect(), set.queue))
}

/// What a base's rule set and classic protection require, before any run
/// is matched to it.
struct BaseRequirement {
    contexts: BTreeSet<String>,
    /// Sorted and deduplicated, each with no candidate yet.
    workflows: Vec<RequiredWorkflowEvidence>,
    gating_rules: usize,
    queue: bool,
    protected: bool,
}

/// The base's requirement from every page of its rules and from its
/// classic protection. GitHub answers the rules one page per request, so a
/// requirement on a later page is read only by reading every page; every
/// rule is validated before any is consumed.
fn base_requirement(gh: &Reader<'_>, repo: &str, base: &str) -> Read<BaseRequirement> {
    let base = segment(base);
    let rules: Vec<Rule> = gh.array(
        Endpoint::Rules,
        &format!("repos/{repo}/rules/branches/{base}"),
    )?;
    let invalid = || Cause::ResponseInvalid(Endpoint::Rules);
    if rules.iter().any(|rule| rule.kind == RuleKind::Other) {
        return Err(invalid());
    }
    let parameters = |rule: Rule| match rule.parameters {
        Optional::Absent => Err(invalid()),
        Optional::Present(object) => Ok(serde_json::Value::Object(object)),
    };
    let mut contexts = BTreeSet::new();
    let mut workflows = Vec::new();
    let mut gating_rules = 0;
    let mut queue = false;
    for rule in rules {
        match rule.kind {
            RuleKind::RequiredStatusChecks => {
                gating_rules += 1;
                let p: RequiredStatusChecksParameters =
                    serde_json::from_value(parameters(rule)?).map_err(|_| invalid())?;
                for check in p.required_status_checks {
                    if check.context.is_empty() {
                        return Err(invalid());
                    }
                    contexts.insert(check.context);
                }
            }
            RuleKind::Workflows => {
                gating_rules += 1;
                let p: WorkflowsParameters =
                    serde_json::from_value(parameters(rule)?).map_err(|_| invalid())?;
                if p.workflows.is_empty()
                    || p.workflows
                        .iter()
                        .any(|w| w.path.is_empty() || w.repository_id == 0)
                {
                    return Err(invalid());
                }
                for workflow in p.workflows {
                    let sha = workflow
                        .sha
                        .present()
                        .filter(|s| !s.is_empty())
                        .ok_or_else(|| Cause::WorkflowSourceUnbound {
                            path: workflow.path.clone(),
                        })?;
                    workflows.push(RequiredWorkflowEvidence {
                        repository_id: workflow.repository_id,
                        path: workflow.path.clone(),
                        sha: sha.clone(),
                        reference: workflow.reference.present().cloned(),
                        candidates: Vec::new(),
                    });
                }
            }
            // The scanning rules gate on alert results, not on the check
            // rollup: they add no context and no workflow.
            RuleKind::CodeCoverage
            | RuleKind::CodeQuality
            | RuleKind::CodeScanning
            | RuleKind::LicenseComplianceScanning => {}
            RuleKind::MergeQueue => queue = true,
            RuleKind::BranchNamePattern
            | RuleKind::CommitAuthorEmailPattern
            | RuleKind::CommitMessagePattern
            | RuleKind::CommitterEmailPattern
            | RuleKind::CopilotCodeReview
            | RuleKind::Creation
            | RuleKind::Deletion
            | RuleKind::FileExtensionRestriction
            | RuleKind::FilePathRestriction
            | RuleKind::MaxFilePathLength
            | RuleKind::MaxFileSize
            | RuleKind::NonFastForward
            | RuleKind::PullRequest
            | RuleKind::RequiredDeployments
            | RuleKind::RequiredLinearHistory
            | RuleKind::RequiredSignatures
            | RuleKind::TagNamePattern
            | RuleKind::Update => {}
            RuleKind::Other => return Err(invalid()),
        }
    }
    workflows.sort_by(|a, b| a.order_key().cmp(&b.order_key()));
    workflows.dedup_by(|a, b| a.order_key() == b.order_key());
    let branch: Branch = gh.object(
        Endpoint::Protection,
        &format!("repos/{repo}/branches/{base}"),
    )?;
    let Optional::Present(protection) = branch.protection else {
        return Err(Cause::ResponseInvalid(Endpoint::Protection));
    };
    match protection.required_status_checks {
        Optional::Absent => {}
        Optional::Present(checks) => {
            let named = checks
                .contexts
                .into_iter()
                .chain(checks.checks.into_iter().map(|c| c.context));
            for context in named {
                if context.is_empty() {
                    return Err(Cause::ResponseInvalid(Endpoint::Protection));
                }
                contexts.insert(context);
            }
        }
    }
    Ok(BaseRequirement {
        contexts,
        workflows,
        gating_rules,
        queue,
        protected: branch.protected,
    })
}

/// The base's required set and the binding proof of every required
/// definition.
fn required_set(
    gh: &Reader<'_>,
    r: &VerifyHead,
    runs: &[RunEvidence],
    active_workflows: usize,
) -> Read<RequiredEvidence> {
    let BaseRequirement {
        contexts,
        mut workflows,
        gating_rules,
        queue: _,
        protected,
    } = base_requirement(gh, &r.repo, &r.base)?;
    for workflow in &mut workflows {
        workflow.candidates = runs
            .iter()
            .filter(|run| run.file() == workflow.path)
            .map(|run| Candidate {
                run: run.id,
                proof: None,
            })
            .collect();
    }
    let sources = prove_candidates(gh, runs, &mut workflows)?;
    // Every candidate run's suite, each once: the bound-job list the
    // selection consumes for the current executions among them.
    let candidate_suites: BTreeSet<u64> = workflows
        .iter()
        .flat_map(|w| &w.candidates)
        .filter_map(|c| runs.iter().find(|run| run.id == c.run))
        .filter_map(|run| run.suite)
        .collect();
    let mut suites = BTreeMap::new();
    for suite in candidate_suites {
        suites.insert(suite, suite_jobs(gh, r, suite)?);
    }
    Ok(RequiredEvidence {
        contexts: contexts.into_iter().collect(),
        workflows,
        sources,
        suites,
        gating_rules,
        protected,
        active_workflows,
    })
}

/// The source proof of every candidate, through one nodes query over the
/// candidates' check-suite nodes, and the lookup of every repository the
/// proofs of a fully proven definition name.
fn prove_candidates(
    gh: &Reader<'_>,
    runs: &[RunEvidence],
    workflows: &mut [RequiredWorkflowEvidence],
) -> Read<Vec<SourceRepository>> {
    let run_of = |id: u64| runs.iter().find(|run| run.id == id);
    let node_ids: BTreeSet<&str> = workflows
        .iter()
        .flat_map(|w| &w.candidates)
        .filter_map(|c| run_of(c.run))
        .filter_map(|run| run.suite_node.as_deref())
        .collect();
    let mut nodes: BTreeMap<String, CheckSuiteNode> = BTreeMap::new();
    if !node_ids.is_empty() {
        let ids: Vec<&str> = node_ids.into_iter().collect();
        for node in gh.suite_nodes(&ids)? {
            match node {
                Nullable::Absent | Nullable::Null => {}
                Nullable::Present(node) => {
                    nodes.insert(node.id.clone(), node);
                }
            }
        }
    }
    for workflow in workflows.iter_mut() {
        for candidate in &mut workflow.candidates {
            candidate.proof = run_of(candidate.run)
                .and_then(|run| {
                    run.suite_node
                        .as_deref()
                        .and_then(|id| nodes.get(id))
                        .map(|node| (run, node))
                })
                .and_then(|(run, node)| proof(run, node));
        }
    }
    // A repository is looked up only once every candidate of the
    // definition has a readable proof; an unproven candidate ends
    // that definition's read before any lookup.
    let mut names: Vec<&str> = Vec::new();
    for workflow in workflows.iter() {
        if workflow.candidates.iter().any(|c| c.proof.is_none()) {
            continue;
        }
        for name in workflow.candidates.iter().filter_map(|c| c.proof.as_ref()) {
            let name = name.repository_name.as_str();
            if !names.iter().any(|known| known.eq_ignore_ascii_case(name)) {
                names.push(name);
            }
        }
    }
    let mut sources = Vec::new();
    for name in names {
        let repository: Repository =
            gh.object(Endpoint::SourceRepository, &format!("repos/{name}"))?;
        if repository.id == 0 || !repository.full_name.eq_ignore_ascii_case(name) {
            return Err(Cause::ResponseInvalid(Endpoint::SourceRepository));
        }
        sources.push(SourceRepository {
            name: name.to_owned(),
            id: repository.id,
            full_name: repository.full_name,
        });
    }
    Ok(sources)
}

/// The proof a suite node gives for its candidate:
/// the node names the candidate's suite, run and attempt, and a file the
/// viewer can read in an `owner/name` repository. Anything less proves
/// nothing.
fn proof(run: &RunEvidence, node: &CheckSuiteNode) -> Option<SourceProof> {
    let suite = run.suite?;
    if node.database_id != Nullable::Present(suite) {
        return None;
    }
    let execution = match &node.workflow_run {
        Nullable::Absent | Nullable::Null => return None,
        Nullable::Present(execution) => execution,
    };
    if execution.database_id != Nullable::Present(run.id) || execution.run_attempt != run.attempt {
        return None;
    }
    let file = match &execution.file {
        Nullable::Absent | Nullable::Null => return None,
        Nullable::Present(file) => file,
    };
    let owner_and_name = file
        .repository_name
        .split_once('/')
        .is_some_and(|(owner, name)| !owner.is_empty() && !name.is_empty() && !name.contains('/'));
    if !file.viewer_can_read_repository || !owner_and_name {
        return None;
    }
    Some(SourceProof {
        path: file.path.clone(),
        repository_name: file.repository_name.clone(),
        file_url: file.repository_file_url.clone(),
    })
}

/// Copilot's work in flight on a head: a queued or in-progress Copilot
/// check run, by its id and start, unless Copilot's review of the head
/// was submitted at or after that start, else a pending request on the
/// timeline. A request stays pending until a later Copilot review, a
/// removal, or a completed Copilot check started at or after it; its
/// start is the event's time, since the request names no head. A member
/// outside its documented shape refuses the read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Work {
    pub(crate) id: u64,
    pub(crate) started_at: Option<String>,
}

/// What the work reader finds on a head: Copilot's work in flight, an
/// active check Copilot's review of the head already answered (its check
/// and the review), or none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Flight {
    Work(Work),
    Settled { check: Work, review: u64 },
    None,
}

/// Whether a timeline actor is Copilot: the REST login with its suffix, or
/// the bare `Copilot` the request events name it by.
pub(super) fn copilot_actor(value: Option<&serde_json::Value>) -> bool {
    value
        .and_then(|v| v.get("login"))
        .and_then(serde_json::Value::as_str)
        .is_some_and(|login| login == format!("{COPILOT_REVIEWER}[bot]") || login == "Copilot")
}

pub(super) fn copilot_work(gh: &Reader<'_>, repo: &str, pr: u64, head: &str) -> Read<Option<Work>> {
    Ok(match copilot_flight(gh, repo, pr, head)? {
        Flight::Work(work) => Some(work),
        Flight::Settled { .. } | Flight::None => None,
    })
}

pub(super) fn copilot_flight(gh: &Reader<'_>, repo: &str, pr: u64, head: &str) -> Read<Flight> {
    let checks = gh.collection::<CheckRunsPage>(
        Endpoint::CheckRuns,
        &format!("repos/{repo}/commits/{head}/check-runs?filter=all"),
    )?;
    if checks.iter().any(CheckRun::undocumented) {
        return Err(Cause::ResponseInvalid(Endpoint::CheckRuns));
    }
    let copilot: Vec<&CheckRun> = checks
        .iter()
        .filter(|check| check.name == COPILOT_REVIEWER)
        .collect();
    if let Some(active) = copilot
        .iter()
        .find(|check| matches!(check.status, RunStatus::Queued | RunStatus::InProgress))
    {
        if active.id == 0 {
            return Err(Cause::ResponseInvalid(Endpoint::CheckRuns));
        }
        let check = Work {
            id: active.id,
            started_at: active.started().map(str::to_owned),
        };
        // GitHub can publish the submitted review before its check reads
        // completed; a review from before the check started answers an
        // earlier request, not this one.
        if let Some(started) = active.started()
            && let Some(review) = reviewed_since(gh, repo, pr, head, started)?
        {
            return Ok(Flight::Settled { check, review });
        }
        return Ok(Flight::Work(check));
    }
    let events: Vec<TimelineEvent> = gh.array(
        Endpoint::Timeline,
        &format!("repos/{repo}/issues/{pr}/timeline"),
    )?;
    let invalid = || Cause::ResponseInvalid(Endpoint::Timeline);
    let mut pending: Option<Work> = None;
    for event in &events {
        let field = |key: &str| event.fields.get(key);
        match event.event.as_str() {
            "review_requested" if copilot_actor(field("requested_reviewer")) => {
                let id = field("id")
                    .and_then(serde_json::Value::as_u64)
                    .ok_or_else(invalid)?;
                let created = field("created_at")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(invalid)?;
                pending = Some(Work {
                    id,
                    started_at: Some(created.to_owned()),
                });
            }
            "copilot_work_started" => {
                let id = field("id")
                    .and_then(serde_json::Value::as_u64)
                    .ok_or_else(invalid)?;
                let created = field("created_at")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(invalid)?;
                pending = Some(Work {
                    id,
                    started_at: Some(created.to_owned()),
                });
            }
            "review_request_removed" if copilot_actor(field("requested_reviewer")) => {
                pending = None;
            }
            "reviewed" if copilot_actor(field("user")) => {
                let submitted = field("submitted_at")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(invalid)?;
                if pending
                    .as_ref()
                    .and_then(|work| work.started_at.as_deref())
                    .is_some_and(|started| submitted >= started)
                {
                    pending = None;
                }
            }
            _ => {}
        }
    }
    let Some(request) = pending else {
        return Ok(Flight::None);
    };
    let answered = copilot.iter().any(|check| {
        matches!(check.status, RunStatus::Completed)
            && check
                .started()
                .zip(request.started_at.as_deref())
                .is_some_and(|(started, requested)| started >= requested)
    });
    Ok(if answered {
        Flight::None
    } else {
        Flight::Work(request)
    })
}

/// Copilot's last review of `head` submitted at or after `since`: an
/// approval, a comment or a change request, never a pending or dismissed
/// one.
fn reviewed_since(
    gh: &Reader<'_>,
    repo: &str,
    pr: u64,
    head: &str,
    since: &str,
) -> Read<Option<u64>> {
    let reviews: Vec<Review> = gh.array(
        Endpoint::Reviews,
        &format!("repos/{repo}/pulls/{pr}/reviews"),
    )?;
    let reviewer = format!("{COPILOT_REVIEWER}[bot]");
    Ok(reviews
        .iter()
        .rev()
        .find(|review| {
            matches!(&review.user, Nullable::Present(user) if user.login == reviewer)
                && review.commit_id == Nullable::Present(head.to_owned())
                && matches!(
                    review.state.as_str(),
                    "APPROVED" | "COMMENTED" | "CHANGES_REQUESTED"
                )
                && matches!(&review.submitted_at, Optional::Present(at) if at.as_str() >= since)
        })
        .map(|review| review.id))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The run-level test: a link ending in the run id, with or
    /// without a trailing slash, names the run; a job link does not.
    #[test]
    fn a_run_level_link_ends_in_its_run_id() {
        let rows = [
            ("https://github.com/o/r/actions/runs/700", true),
            ("https://github.com/o/r/actions/runs/700/", true),
            ("https://github.com/o/r/actions/runs/700/job/4", false),
            (
                "https://github.com/o/r/actions/runs/700?check_suite_focus=true",
                false,
            ),
            ("https://github.com/o/r/actions/runs/", false),
            ("https://github.com/o/r/runs/4", false),
        ];
        for (url, expected) in rows {
            assert_eq!(run_level(url), expected, "{url}");
        }
    }
}
