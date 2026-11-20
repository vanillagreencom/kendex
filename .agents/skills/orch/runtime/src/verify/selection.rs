//! The selection stage: which members of the validated `Evidence` the
//! verdict considers and which runs its correlation reads. `select` is a
//! pure function `Evidence → Selection`: the rollup's reduction, the
//! required-definition walk and bound required-job membership, and a failed
//! required workflow's placeholders; the classification stage (`judge`)
//! reads the selected members only.
//!
//! The stage, in order:
//!
//! 1. The rollup (`eliminate_duplicates`): gh's reduction of the head's
//!    check runs and statuses, as `gh pr checks` prints it, transcribed
//!    (gh v2.103.3 `pkg/cmd/pr/checks/aggregate.go:95-119`): the
//!    contexts sorted by `StartedAt`, newest first, then one per status
//!    context and one per slash-joined `name/workflow/event` string, the
//!    first in that order kept. The contexts are the commit's check runs
//!    and status contexts (GraphQL `StatusCheckRollup.contexts`, "A list
//!    of status contexts and check runs for this commit"), the `filter=all`
//!    read and the combined status here. Every check run was validated
//!    before this reduction (`evidence`). gh's `sort.Slice` documents no
//!    order among equal starts ("The sort is not guaranteed to be stable:
//!    equal elements may be reversed from their original order"), and its
//!    input is GitHub's one union connection of check runs and statuses in
//!    an order no documentation fixes (gh `api/query_builder.go:284`,
//!    `checks.go:290`), so gh's answer on contexts started alike is
//!    order-dependent. The stage reads nothing to import that order; it
//!    fixes the tie over its own validated evidence: among equal starts the
//!    member with the later position in the evidence listing sorts first,
//!    then the higher check-run id. That listing is the `filter=all` read's
//!    members in the order the endpoint listed them, then the combined
//!    status's contexts in their listed order; every member carries its
//!    position in it (`Context::order`). Three picks consume that one
//!    order: gh's deduplication keeps the first of it (step 1), the
//!    run-status pick (step 5) and the run-less deduplication (step 6)
//!    keep the last of it. A check run GitHub listed for the head and gh's
//!    rule dropped is not read again here; the bound-job list of step 7 is
//!    the suite's own listing, apart from this rollup.
//! 2. Placement, from two reads of an entry: the run its link names
//!    (`runid`; the link is the check run's `details_url`, gh
//!    `aggregate.go:51`) and the workflow name its suite's run carries
//!    (`workflow`, `gh pr checks`'s `checkSuite.workflowRun.workflow.name`).
//!    A linked entry with a workflow name is a job of that run under that
//!    name; a linked entry with none is a run status; an unlinked entry is
//!    run-less. The association the evidence read (`Association`) travels
//!    with the member and is read by the classification alone.
//! 3. Run rank per workflow name: a run's jobs grouped by run under the
//!    workflow name the rollup showed, so two workflow files sharing a name
//!    are one group; ranked by `[last job start, run id]` when every run of
//!    the group is settled and dated, else by `["", run id]`.
//! 4. Selected runs: a required workflow's bound runs are kept whatever
//!    their rank; the pick is the top-ranked substantive run, or the
//!    top-ranked run when every run is all-skipped. Jobs of other runs are
//!    dropped.
//! 5. Run statuses: the latest per name by run id (among equal run ids the
//!    later entry of step 1's order wins: the earlier-listed member among
//!    equal starts); an aggregate (run-level link) whose run ranks below a
//!    selected run of its source group with no failed job is rewritten
//!    `expected`, pending, while that newer run publishes its own.
//! 6. Run-less members: deduplicated by name, the latest start winning, the
//!    later entry of step 1's order on an equal start (the earlier-listed
//!    member).
//! 7. The required-definition walk (`walk` and `bind`): the definitions in
//!    their sorted order, each bound to the candidates whose proof names
//!    the definition's repository (by the looked-up id), path and pinned
//!    sha, no candidate claimed by an earlier definition; the current
//!    execution per workflow among them. The first definition that is not
//!    ready ends the walk: unresolved (no proven candidate, an unproven
//!    one, no current execution, one unfinished, one without a suite, a
//!    bound run with no linked job, an ambiguous source) holds the
//!    requirement `expected`, the one member reported, before anything is
//!    scoped; a current execution concluded outside success, neutral and
//!    skipped fails, and the failed runs replace the rollup as placeholders,
//!    one entry per failed run named alike, which the scoping then reduces
//!    to the greatest run id. A bound run's jobs are the suite's check runs
//!    as GitHub listed them under its default `filter=latest`, each by
//!    `name` and `html_url`, the server's selection consumed and never
//!    re-derived (`bound_jobs`).
//! 8. The considered set and the correlation's runs: under a required set
//!    that names anything, each named context's members or `expected`,
//!    every member whose link is a bound job's link by equality (the
//!    rollup's `details_url` or status target against the suite read's
//!    `html_url`, unequal where GitHub's two URLs differ), each bound job
//!    whose link the scoped rollup lacks as `expected`
//!    (`missing_required`); the runs are the bound runs and the runs of
//!    every workflow a named context's member ran in. Otherwise every
//!    member and every run.

use std::collections::{BTreeMap, BTreeSet};

use super::evidence::{
    Association, CheckRunEvidence, Evidence, RequiredEvidence, RequiredWorkflowEvidence,
    RunEvidence, StatusEvidence,
};
use super::{Bucket, CheckReport, Source};

/// One check the verdict considers, with its association to a run.
#[derive(Debug, Clone)]
pub(super) struct Member {
    pub(super) report: CheckReport,
    pub(super) association: Association,
    /// The run the member's link names, held or not.
    pub(super) linked: Option<u64>,
}

impl Member {
    pub(super) fn bucket(&self) -> Bucket {
        self.report.bucket
    }
}

/// Which checks decide: the base's required set alone, or every check on
/// the head.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Scope {
    RequiredSet,
    AllChecks,
}

/// What the absence probe read, for a head carrying no check and no
/// status under `required_only`.
#[derive(Debug, Clone, Copy)]
pub(super) struct AbsenceFacts {
    pub(super) active_workflows: usize,
    pub(super) gating_rules: usize,
    pub(super) protected: bool,
    pub(super) runs: usize,
}

/// The selection the classification reads.
#[derive(Debug)]
pub(super) struct Selection<'a> {
    /// The members the verdict considers, in the order they are reported.
    pub(super) members: Vec<Member>,
    /// The runs the correlation reads.
    pub(super) runs: Vec<&'a RunEvidence>,
    pub(super) scope: Scope,
    /// The caller's flag: a skipped check counts as passed under it.
    pub(super) required_only: bool,
    /// The absence probe's facts, present under `required_only`.
    pub(super) absence: Option<AbsenceFacts>,
}

/// The current execution among one workflow's runs. The newest run by id is
/// current unless a re-run (attempt above 1) of an older run started after
/// it; among those the latest start wins, then the id. An old run
/// finishing later never replaces a newer run.
pub(super) fn current_execution<'a>(group: &[&'a RunEvidence]) -> Option<&'a RunEvidence> {
    let newest = group.iter().max_by_key(|r| r.id())?;
    group
        .iter()
        .filter(|r| r.id() == newest.id() || (r.attempt() > 1 && r.started() > newest.started()))
        .max_by_key(|r| (r.started(), r.id()))
        .copied()
}

/// One workflow's runs each, keyed by `workflow_id`: the Actions-run
/// grouping of the head's runs.
pub(super) fn by_workflow<'a>(runs: &[&'a RunEvidence]) -> BTreeMap<u64, Vec<&'a RunEvidence>> {
    let mut groups: BTreeMap<u64, Vec<&'a RunEvidence>> = BTreeMap::new();
    for run in runs {
        groups.entry(run.workflow_id()).or_default().push(run);
    }
    groups
}

/// A member's place: a job, a run status, or run-less.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Place<'a> {
    /// A linked entry whose suite's run has a workflow name, under that
    /// name and the link's run.
    Job {
        workflow: &'a str,
        run: u64,
    },
    /// A linked entry with no workflow name; `run_level` when the link
    /// names the run itself rather than a job of it.
    RunStatus {
        run: u64,
        run_level: bool,
    },
    Runless,
}

/// One rollup member before selection.
#[derive(Debug, Clone)]
struct Entry<'a> {
    name: &'a str,
    source: Source,
    state: &'static str,
    bucket: Bucket,
    /// The check run's `startedAt`, `""` where unknown.
    started: &'a str,
    place: Place<'a>,
    /// A check run's `details_url` or a status's
    /// target, matched by equality against a bound job's `html_url`.
    link: Option<&'a str>,
    association: Association,
}

impl Entry<'_> {
    fn linked(&self) -> Option<u64> {
        match self.place {
            Place::Job { run, .. } | Place::RunStatus { run, .. } => Some(run),
            Place::Runless => None,
        }
    }

    fn member(&self) -> Member {
        Member {
            report: CheckReport {
                name: self.name.to_owned(),
                source: self.source,
                state: self.state.to_owned(),
                bucket: self.bucket,
            },
            association: self.association,
            linked: self.linked(),
        }
    }
}

/// The placement of an entry from its two reads.
fn place<'a>(linked: Option<u64>, workflow: &'a str, run_level: bool) -> Place<'a> {
    match linked {
        None => Place::Runless,
        Some(run) if workflow.is_empty() => Place::RunStatus { run, run_level },
        Some(run) => Place::Job { workflow, run },
    }
}

/// One run's jobs with its per-run facts.
#[derive(Debug)]
struct RunGroup {
    run: u64,
    /// Indices into the entries.
    jobs: Vec<usize>,
    substantive: bool,
    failed: usize,
    rank: (String, u64),
}

/// How one required definition binds to the head's runs.
#[derive(Debug)]
enum Binding<'a> {
    /// Nothing proven yet, or evidence that reads pending or unreadable:
    /// the requirement is not met and the walk ends.
    Unresolved,
    /// A current execution concluded outside success, neutral and skipped.
    Failed(Vec<&'a RunEvidence>),
    /// Every current execution ended green; its linked jobs are the
    /// members. The matched runs are claimed against later definitions.
    Bound {
        runs: Vec<BoundRun<'a>>,
        claimed: Vec<u64>,
    },
}

/// A bound run with its jobs as the suite read carries them: each check
/// run's name and page, the page matched by equality against the rollup's
/// link for membership and for `missing_required`.
#[derive(Debug)]
struct BoundRun<'a> {
    run: &'a RunEvidence,
    jobs: Vec<(&'a str, &'a str)>,
}

/// The suite's check runs for a bound run: the evidence stage's read of
/// `repos/{repo}/check-suites/{suite}/check-runs`, every page, each run
/// with a non-empty `name` and `html_url` and the count equal to
/// `total_count` (`RequiredEvidence::suite_jobs`). The read names no
/// `filter`, so GitHub answered its default, `latest`: "Filters check runs
/// by their completed_at timestamp. latest returns the most recent check
/// runs." (rest/checks/runs, the same words on "List check runs in a check
/// suite"). Its answer is consumed here as the server gave it: which check
/// run of a repeated name it returns is GitHub's selection, never
/// re-derived from `completed_at`. A member without a page is unreadable
/// and a run with no job pending; either leaves the definition unresolved.
fn bound_jobs<'a>(
    run: &RunEvidence,
    required: &'a RequiredEvidence,
) -> Option<Vec<(&'a str, &'a str)>> {
    let listed = required.suite_jobs(run.suite()?)?;
    let mut jobs = Vec::with_capacity(listed.len());
    for job in listed {
        let page = job.page().filter(|page| !page.is_empty())?;
        jobs.push((job.name(), page));
    }
    if jobs.is_empty() {
        return None;
    }
    Some(jobs)
}

/// How the walk over the sorted definitions ended.
#[derive(Debug)]
enum Walk<'a> {
    Ready(Vec<BoundRun<'a>>),
    Unresolved {
        bound: Vec<BoundRun<'a>>,
        workflow: &'a RequiredWorkflowEvidence,
    },
    Failed(Vec<&'a RunEvidence>),
}

/// One context of the rollup `gh pr checks` built: a check run or a status
/// context (gh's `api.CheckContext`, `api/queries_pr.go:219-239`).
#[derive(Debug, Clone, Copy)]
enum Context<'a> {
    Check(&'a CheckRunEvidence),
    Status(&'a StatusEvidence),
}

impl Context<'_> {
    /// The rollup's order, greatest first: gh's `StartedAt` (the check
    /// run's; none for a status, whose query reads no start,
    /// `api/query_builder.go:288-294`, and Go decodes a null as its zero
    /// time, which `After` orders before every date, as `None` orders
    /// here), then the tie among equal starts (the module header's tie
    /// rule): the later position in the evidence listing, then the
    /// higher check-run id, which two members at one position would reach.
    /// `position` is the
    /// member's index in that listing: the `filter=all` members as the
    /// endpoint listed them, then the combined status's contexts.
    fn order(&self, position: usize) -> (Option<&str>, usize, u64) {
        match self {
            Context::Check(check) => (check.started(), position, check.id()),
            Context::Status(_) => (None, position, 0),
        }
    }
}

/// The rollup, gh's reduction of the head's contexts transcribed (gh v2.103.3 `pkg/cmd/pr/checks/aggregate.go:95-119`):
///
/// ```go
/// // eliminateDuplicates filters a set of checks to only the most recent ones if the set includes repeated runs
/// func eliminateDuplicates(checkContexts []api.CheckContext) []api.CheckContext {
///     sort.Slice(checkContexts, func(i, j int) bool { return checkContexts[i].StartedAt.After(checkContexts[j].StartedAt) })
///
///     mapChecks := make(map[string]struct{})
///     mapContexts := make(map[string]struct{})
///     unique := make([]api.CheckContext, 0, len(checkContexts))
///
///     for _, ctx := range checkContexts {
///         if ctx.Context != "" {
///             if _, exists := mapContexts[ctx.Context]; exists {
///                 continue
///             }
///             mapContexts[ctx.Context] = struct{}{}
///         } else {
///             key := fmt.Sprintf("%s/%s/%s", ctx.Name, ctx.CheckSuite.WorkflowRun.Workflow.Name, ctx.CheckSuite.WorkflowRun.Event)
///             if _, exists := mapChecks[key]; exists {
///                 continue
///             }
///             mapChecks[key] = struct{}{}
///         }
///         unique = append(unique, ctx)
///     }
///
///     return unique
/// }
/// ```
///
/// Go's `sort.Slice` is documented unstable ("equal elements may be
/// reversed from their original order"), so gh's order among contexts
/// started alike is whatever its input order and its sort leave, no rule.
/// The order among them here is `Context::order` over each member's
/// position in the evidence listing (the module header's tie rule). The key
/// is gh's slash-joined string, so `build/CI` under workflow `tests` and
/// `build` under `CI/tests` collide here as in gh. A status's
/// `Context` is its context; the combined status is already one per
/// context (`evidence`), so that branch drops nothing.
fn eliminate_duplicates(evidence: &Evidence) -> Vec<Context<'_>> {
    let mut contexts: Vec<(usize, Context<'_>)> = evidence
        .check_runs()
        .iter()
        .map(Context::Check)
        .chain(evidence.statuses().iter().map(Context::Status))
        .enumerate()
        .collect();
    contexts.sort_by(|(at_a, a), (at_b, b)| b.order(*at_b).cmp(&a.order(*at_a)));
    let mut map_checks: BTreeSet<String> = BTreeSet::new();
    let mut map_contexts: BTreeSet<&str> = BTreeSet::new();
    let mut unique = Vec::with_capacity(contexts.len());
    for (_, context) in contexts {
        let kept = match context {
            Context::Status(status) => map_contexts.insert(status.context()),
            Context::Check(check) => map_checks.insert(format!(
                "{}/{}/{}",
                check.name(),
                check.workflow(),
                check.event()
            )),
        };
        if kept {
            unique.push(context);
        }
    }
    unique
}

/// The walk over the definitions in their sorted order:
/// the first unresolved or failed definition ends it.
fn walk<'a>(required: &'a RequiredEvidence, evidence: &'a Evidence) -> Walk<'a> {
    let mut claimed: BTreeSet<u64> = BTreeSet::new();
    let mut bound = Vec::new();
    for workflow in required.workflows() {
        match bind(workflow, required, evidence, &claimed) {
            Binding::Unresolved => return Walk::Unresolved { bound, workflow },
            Binding::Failed(runs) => return Walk::Failed(runs),
            Binding::Bound {
                runs,
                claimed: matched,
            } => {
                claimed.extend(matched);
                bound.extend(runs);
            }
        }
    }
    Walk::Ready(bound)
}

/// One definition's binding: every candidate proven, the
/// one repository among the proofs' whose id is the definition's, the
/// candidates whose file is the definition's path at its pinned sha in
/// that repository and claimed by no earlier definition, then the current
/// execution per workflow among them, judged: none or unfinished pends, a
/// missing suite is unreadable, a failed conclusion fails, else the run's
/// suite listing is its jobs (`bound_jobs`), a run with none pending.
fn bind<'a>(
    workflow: &RequiredWorkflowEvidence,
    required: &'a RequiredEvidence,
    evidence: &'a Evidence,
    claimed: &BTreeSet<u64>,
) -> Binding<'a> {
    let mut candidates = Vec::new();
    for candidate in workflow.candidates() {
        let (Some(run), Some(proof)) = (evidence.run(candidate.run()), candidate.proof()) else {
            return Binding::Unresolved;
        };
        candidates.push((run, proof));
    }
    let names: BTreeSet<String> = candidates
        .iter()
        .map(|(_, proof)| proof.repository_name().to_ascii_lowercase())
        .collect();
    let sources: Vec<_> = required
        .sources()
        .iter()
        .filter(|s| names.contains(&s.name().to_ascii_lowercase()))
        .filter(|s| s.id() == workflow.repository_id())
        .collect();
    let matched: Vec<&RunEvidence> = match sources.as_slice() {
        [] => Vec::new(),
        [source] => {
            let url = format!(
                "https://github.com/{}/blob/{}/{}",
                source.full_name(),
                workflow.sha(),
                workflow.path()
            );
            candidates
                .iter()
                .filter(|(_, proof)| {
                    proof.path() == workflow.path()
                        && proof
                            .repository_name()
                            .eq_ignore_ascii_case(source.full_name())
                        && proof.file_url() == url
                })
                .map(|(run, _)| *run)
                .collect()
        }
        _ => return Binding::Unresolved,
    };
    if matched.iter().any(|run| claimed.contains(&run.id())) {
        return Binding::Unresolved;
    }
    let current: Vec<&RunEvidence> = by_workflow(&matched)
        .values()
        .filter_map(|group| current_execution(group))
        .collect();
    if current.is_empty()
        || current
            .iter()
            .any(|r| r.outcome().unfinished() || r.suite().is_none())
    {
        return Binding::Unresolved;
    }
    let failed: Vec<&RunEvidence> = current
        .iter()
        .filter(|r| r.outcome().run_bucket() == Bucket::Fail)
        .copied()
        .collect();
    if !failed.is_empty() {
        return Binding::Failed(failed);
    }
    let mut bound = Vec::new();
    for run in current {
        let Some(jobs) = bound_jobs(run, required) else {
            return Binding::Unresolved;
        };
        bound.push(BoundRun { run, jobs });
    }
    Binding::Bound {
        runs: bound,
        claimed: matched.iter().map(|r| r.id()).collect(),
    }
}

/// The selection over validated evidence; see the module header for the
/// steps.
pub(super) fn select(evidence: &Evidence) -> Selection<'_> {
    // 1. The rollup, in gh's order; 2. placement.
    let mut entries: Vec<Entry<'_>> = Vec::new();
    for context in eliminate_duplicates(evidence) {
        entries.push(match context {
            Context::Check(check) => Entry {
                name: check.name(),
                source: Source::CheckRun,
                state: check.outcome().word(),
                bucket: check.outcome().check_bucket(),
                started: check.started().unwrap_or_default(),
                place: place(check.linked(), check.workflow(), check.run_level()),
                link: check.link(),
                association: check.association(),
            },
            Context::Status(status) => Entry {
                name: status.context(),
                source: Source::CommitStatus,
                state: status.state().word(),
                bucket: status.state().bucket(),
                started: "",
                place: place(status.linked(), "", status.run_level()),
                link: status.target(),
                association: status.association(),
            },
        });
    }

    // 3. Run rank per workflow name.
    let mut workflows: BTreeMap<&str, Vec<RunGroup>> = BTreeMap::new();
    {
        let mut jobs: BTreeMap<(&str, u64), Vec<usize>> = BTreeMap::new();
        for (i, entry) in entries.iter().enumerate() {
            if let Place::Job { workflow, run } = entry.place {
                jobs.entry((workflow, run)).or_default().push(i);
            }
        }
        for ((workflow, run), indices) in jobs {
            let buckets = || indices.iter().map(|&i| entries[i].bucket);
            let last_start = indices
                .iter()
                .map(|&i| entries[i].started)
                .max()
                .unwrap_or_default()
                .to_owned();
            workflows.entry(workflow).or_default().push(RunGroup {
                run,
                substantive: buckets().any(|b| b != Bucket::Skipping),
                failed: buckets().filter(|b| *b == Bucket::Fail).count(),
                // Pending is read here; the rank below depends on it.
                rank: (
                    if buckets().any(|b| b == Bucket::Pending) {
                        String::new()
                    } else {
                        last_start
                    },
                    run,
                ),
                jobs: indices,
            });
        }
        for groups in workflows.values_mut() {
            // Time ranks only when every run of the group is settled and
            // dated; otherwise run id alone.
            if groups.iter().any(|g| g.rank.0.is_empty()) {
                for g in groups.iter_mut() {
                    g.rank.0.clear();
                }
            }
        }
    }

    // 7. The required-definition walk, first: its bound runs are kept in
    // step 4 whatever their rank.
    let walked = evidence
        .required()
        .filter(|req| !req.workflows().is_empty())
        .map(|req| walk(req, evidence));
    let (bound, unresolved, failed_runs): (
        &[BoundRun<'_>],
        Option<&RequiredWorkflowEvidence>,
        Vec<&RunEvidence>,
    ) = match &walked {
        None => (&[], None, Vec::new()),
        Some(Walk::Ready(bound)) => (bound, None, Vec::new()),
        Some(Walk::Unresolved { bound, workflow }) => (bound, Some(workflow), Vec::new()),
        Some(Walk::Failed(runs)) => (&[], None, runs.clone()),
    };
    let bound_ids: BTreeSet<u64> = bound
        .iter()
        .map(|b| b.run.id())
        .chain(failed_runs.iter().map(|r| r.id()))
        .collect();
    // The bound jobs, each once, as `missing_required` reports them.
    let bound_jobs: BTreeSet<(&str, &str)> =
        bound.iter().flat_map(|b| b.jobs.iter().copied()).collect();
    let bound_links: BTreeSet<&str> = bound_jobs.iter().map(|(_, link)| *link).collect();

    // 4. Selected runs per group: bound runs, then the pick.
    let mut selected: BTreeMap<&str, Vec<&RunGroup>> = BTreeMap::new();
    for (workflow, groups) in &workflows {
        let mut chosen: Vec<&RunGroup> = groups
            .iter()
            .filter(|g| bound_ids.contains(&g.run))
            .collect();
        let substantive: Vec<&RunGroup> = groups.iter().filter(|g| g.substantive).collect();
        let pool = if substantive.is_empty() {
            groups.iter().collect()
        } else {
            substantive
        };
        if let Some(pick) = pool.iter().max_by_key(|g| &g.rank)
            && !bound_ids.contains(&pick.run)
        {
            chosen.push(pick);
        }
        selected.insert(workflow, chosen);
    }
    let selected_ids: BTreeSet<u64> = selected.values().flatten().map(|g| g.run).collect();

    // The scoped list: selected runs' jobs, then run statuses, then
    // run-less members.
    let mut scoped: Vec<Entry<'_>> = Vec::new();
    for groups in selected.values() {
        for group in groups {
            scoped.extend(group.jobs.iter().map(|&i| entries[i].clone()));
        }
    }

    // 5. Run statuses: the latest per name by run id, an aggregate behind
    // a newer selected run of its group held `expected`.
    let mut latest_status: BTreeMap<&str, usize> = BTreeMap::new();
    for (i, entry) in entries.iter().enumerate() {
        if let Place::RunStatus { run, .. } = entry.place {
            let slot = latest_status.entry(entry.name).or_insert(i);
            if let Place::RunStatus { run: held, .. } = entries[*slot].place
                && run >= held
            {
                *slot = i;
            }
        }
    }
    for &i in latest_status.values() {
        let mut entry = entries[i].clone();
        if let Place::RunStatus {
            run,
            run_level: true,
        } = entry.place
        {
            let source_workflow = entries.iter().find_map(|e| match e.place {
                Place::Job { workflow, run: r } if r == run => Some(workflow),
                Place::Job { .. } | Place::RunStatus { .. } | Place::Runless => None,
            });
            let status_run = source_workflow.and_then(|workflow| {
                workflows
                    .get(workflow)
                    .and_then(|groups| groups.iter().find(|g| g.run == run))
                    .map(|g| (workflow, g))
            });
            let newer = status_run.and_then(|(workflow, status_run)| {
                selected.get(workflow).and_then(|groups| {
                    groups
                        .iter()
                        .find(|g| !selected_ids.contains(&run) && g.rank > status_run.rank)
                })
            });
            if newer.is_some_and(|g| g.failed == 0) {
                entry.state = "expected";
                entry.bucket = Bucket::Pending;
            }
        }
        scoped.push(entry);
    }

    // 6. Run-less members, deduplicated by name on the latest start.
    let mut runless: BTreeMap<&str, usize> = BTreeMap::new();
    for (i, entry) in entries.iter().enumerate() {
        if entry.place == Place::Runless {
            let slot = runless.entry(entry.name).or_insert(i);
            if entry.started >= entries[*slot].started {
                *slot = i;
            }
        }
    }
    scoped.extend(runless.values().map(|&i| entries[i].clone()));

    // 8. The considered set and the correlation's runs.
    let expected = |name: &str| CheckReport {
        name: name.to_owned(),
        source: Source::Required,
        state: "expected".to_owned(),
        bucket: Bucket::Pending,
    };
    let expected_member = |name: &str| Member {
        report: expected(name),
        association: Association::None,
        linked: None,
    };
    let expected_workflow = |name: &str| Member {
        report: expected(name),
        association: Association::None,
        linked: None,
    };
    let run_member = |run: &RunEvidence| Member {
        report: CheckReport {
            name: run.file().to_owned(),
            source: Source::WorkflowRun,
            state: run.outcome().word().to_owned(),
            bucket: run.outcome().run_bucket(),
        },
        association: Association::Run(run.id()),
        linked: Some(run.id()),
    };
    let absence = |req: &RequiredEvidence| {
        Some(AbsenceFacts {
            active_workflows: req.active_workflows(),
            gating_rules: req.gating_rules(),
            protected: req.protected(),
            runs: evidence.runs().len(),
        })
    };
    match evidence.required() {
        Some(req) if unresolved.is_some() => Selection {
            members: unresolved
                .map(|workflow| expected_workflow(workflow.path()))
                .into_iter()
                .collect(),
            runs: Vec::new(),
            scope: Scope::RequiredSet,
            required_only: true,
            absence: absence(req),
        },
        Some(req) if !failed_runs.is_empty() => {
            // The placeholders are run statuses named alike; the scoping
            // keeps the greatest run id. The correlation still reads every
            // failed run.
            let kept = failed_runs
                .iter()
                .max_by_key(|r| r.id())
                .map(|r| run_member(r))
                .into_iter()
                .collect::<Vec<_>>();
            Selection {
                members: kept,
                runs: failed_runs,
                scope: Scope::RequiredSet,
                required_only: true,
                absence: absence(req),
            }
        }
        Some(req) if req.names_anything() => {
            let mut taken: BTreeSet<usize> = BTreeSet::new();
            let mut members = Vec::new();
            for context in req.contexts() {
                let found: Vec<usize> = (0..scoped.len())
                    .filter(|&i| scoped[i].name == context)
                    .collect();
                if found.is_empty() {
                    members.push(expected_member(context));
                }
                for i in found {
                    if taken.insert(i) {
                        members.push(scoped[i].member());
                    }
                }
            }
            for (i, entry) in scoped.iter().enumerate() {
                if entry.link.is_some_and(|link| bound_links.contains(link)) && taken.insert(i) {
                    members.push(entry.member());
                }
            }
            for (name, link) in &bound_jobs {
                if !scoped.iter().any(|entry| entry.link == Some(*link)) {
                    members.push(expected_member(name));
                }
            }
            let classic_workflows: BTreeSet<u64> = members
                .iter()
                .filter(|m| req.contexts().contains(&m.report.name))
                .filter_map(|m| m.linked)
                .filter_map(|id| evidence.run(id))
                .map(|r| r.workflow_id())
                .collect();
            let runs = evidence
                .runs()
                .iter()
                .filter(|r| {
                    bound_ids.contains(&r.id()) || classic_workflows.contains(&r.workflow_id())
                })
                .collect();
            Selection {
                members,
                runs,
                scope: Scope::RequiredSet,
                required_only: true,
                absence: absence(req),
            }
        }
        Some(req) => Selection {
            members: scoped.iter().map(Entry::member).collect(),
            runs: evidence.runs().iter().collect(),
            scope: Scope::AllChecks,
            required_only: true,
            absence: absence(req),
        },
        None => Selection {
            members: scoped.iter().map(Entry::member).collect(),
            runs: evidence.runs().iter().collect(),
            scope: Scope::AllChecks,
            required_only: false,
            absence: None,
        },
    }
}
