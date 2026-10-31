//! The differential against the legacy oracle (decisions 107 (3), 110
//! (3)-(5) and 112): a corpus of cases, each rendered once to the REST and
//! GraphQL replies the operation reads and once to the legacy's inputs; the
//! operation judges the first through `evidence::read` over a fake
//! transport (`FakeGh`, the one way a test builds an `Evidence`), the
//! legacy's own functions judge the second through
//! `tests/rust/fixtures/gh/legacy-oracle/oracle.sh`, and the test compares
//! the selections first, through the private projection `project`, then
//! the classifications. The corpus is every legacy fixture, the named
//! cases R-U4e7 H2 executed, the eleven witnesses of R-U4e8 and R-U4e9, and
//! a deterministic generator over the legacy's input domain (`generate`,
//! whose doc comment holds the dimension table).
//!
//! The case model is GitHub's object graph with independent identities
//! (decision 112 (1)): a workflow, a workflow run, a check suite, a check
//! run, a commit status, a required definition and a source file proof,
//! each with its own id, and each side rendered from the documented
//! relations between them alone. The adapter never consults the operation's
//! placement, join or ranking.
//!
//! The legacy's side is a transcription of the code that produced the
//! legacy's inputs in production (decision 114 (1)): gh v2.103.3
//! `pkg/cmd/pr/checks` built the rollup the lib read, and the lib's own
//! `gh api` calls read the rest. Each transcribed snippet is quoted at the
//! function that follows it; a relation with no transcribed source line is
//! not rendered:
//!
//! | Snippet | Source | Applied in |
//! |---|---|---|
//! | The checks query's fields: `...on StatusContext { context, state, targetUrl, createdAt, description, isRequired }`, `...on CheckRun { name, checkSuite{workflowRun{event,workflow{name}}}, status, conclusion, startedAt, completedAt, detailsUrl, isRequired }` | gh `api/query_builder.go:286-304` (`RequiredStatusCheckRollupGraphQL`, `eventField` at `:275`), received by `api.CheckContext`, `api/queries_pr.go:219-252`; the contexts are `StatusCheckRollup.contexts`, "A list of status contexts and check runs for this commit" (docs.github.com/en/graphql/reference/commits), the one declared premise: every case check run and every status is a context, as every one is a member of the `filter=all` read and the combined status the operation reads | `Case::check_contexts`: one `CheckContext` per case check run and per status, GitHub's graph read for `checkSuite.workflowRun` (`CheckSuite.workflowRun: WorkflowRun`, nullable; `WorkflowRun.event: String!`, `WorkflowRun.workflow: Workflow!`, `Workflow.name: String!`), Go's zero values where null; the contexts in the order of `TieOrder` (below) |
//! | `sort.Slice(... StartedAt.After ...)`; one per `Context`; one per `Name/Workflow.Name/Event`, the slash-joined string | `aggregate.go:95-119` (`eliminateDuplicates`) | `eliminate_duplicates` |
//! | `state`, `link := c.DetailsURL` else `TargetURL`, `name`, `StartedAt`, `Event`, `Workflow`, the bucket `switch` | `aggregate.go:42-88` (`aggregateChecks`, `requiredChecks` false) | `aggregate_checks` |
//! | `gh pr checks "$1" --json name,state,bucket,link,startedAt,workflow` | HEAD `ci-run-correlation.sh:218` | `Case::legacy_rollup`: the six exported fields, `startedAt` as Go marshals `time.Time` (RFC 3339, the zero time `0001-01-01T00:00:00Z`) |
//! | `gh api "repos/$path/check-suites/$suite/check-runs?per_page=100"`, `map({name, link: .html_url})` | `ci-run-correlation.sh:489-495`; the read's default `filter=latest`: "Filters check runs by their completed_at timestamp. latest returns the most recent check runs." (rest/checks/runs, "List check runs in a check suite") | `Case::suite_jobs`: the members GitHub's `latest` answer holds for the suite, a drawn input of the case (`CaseRun::latest`), each by `name` and `html_url`; the operation reads the same members through the same endpoint (`Case::rest`), and neither side derives them (decision 117 (1)) |
//! | `gh api "repos/$REPO/actions/runs?head_sha=…"`, the suite node query, `repos/<name>` | `ci-run-correlation.sh:372-419`, `:63-81` of the oracle's `gh` | `Case::rest_run`, `Case::suite_node`, `sources` |
//!
//! The two URLs a check run carries are independent inputs (`CaseCheck::details`,
//! `CaseCheck::page`): gh printed `detailsUrl` (REST `details_url`, "the
//! URL of the integrator's site"), the suite read listed `html_url`, and
//! the legacy compared the two by equality (`:112`, `:119`), unequal
//! included. Decision 113 names one correction on the legacy's input: a
//! `STARTUP_FAILURE` row's bucket reads `fail`
//! (`Case::legacy_rollup(Correction::StartupFailure)`); a case carrying one
//! is compared against the corrected derivation alone (decision 114 (4)).
//!
//! Ties (decisions 117 (3), 122 (1)-(2)): Go's `sort.Slice` is documented
//! unstable ("equal elements may be reversed from their original order"),
//! and gh sorted GitHub's one union connection of check runs and statuses
//! in the order GitHub returned it (gh `api/query_builder.go:284`,
//! `checks.go:290`), which no documentation fixes: the legacy's answer on
//! a tie was order-dependent, in gh's deduplication and in the lib's
//! run-status and run-less picks alike, wherever two contexts shared a
//! name or gh's key. The operation never reads that union; it defines the
//! order over its own evidence listing (`selection::Context::order`: among
//! equal starts the later position in the listing first, then the higher
//! check-run id). The case lists its check runs in the order the REST
//! endpoint returns them (`Case::checks`, drawn apart from the ids by the
//! generator), its statuses after them: the operation's listing. For
//! every case the adapter renders the legacy's union in that order
//! (`TieOrder::Port`), so the transcribed sort, stable over an input
//! already in its order, keeps what gh's sort keeps on that input, and the
//! differential requires agreement, as 117 (3) prescribes for a tied case;
//! GitHub's own order is never the comparison's input, since the legacy's
//! answer under it was no single verdict. The correction's reach is
//! counted apart and never accepted as a match: for a tied case
//! (`Case::tied`: two contexts sharing a name and a start, or two check
//! runs sharing gh's key and a start) the legacy runs once more with every
//! tie reversed (`TieOrder::Union` over `Case::listing`: the union in the
//! listing's own order, which gh's sort leaves as it stands), and for a
//! case carrying a drawn union order (`Case::union`: the check runs in an
//! order drawn apart from the REST listing, the statuses at drawn
//! positions) once more under that union; the cases whose legacy selection
//! or conclusion changes are counted (`tie-order-dependent`,
//! `union-order-dependent`) and printed in the test's summary line. Both
//! renderings are exact for a union of at most twelve contexts, where Go's
//! `sort.Slice` is an insertion sort that moves no equal elements; above
//! twelve it is pdqsort, whose order the adapter does not compute, so such
//! a case is counted `union-order-unrendered`, printed beside the two
//! counts and left out of both (decision 123 (1)).
//!
//! Suite ids are drawn apart from run ids and check ids; a run may own
//! jobs whether or not REST carries its `check_suite_id`; a check's link
//! and its suite are independent inputs, so they can name different runs
//! or none; a run's GraphQL `databaseId` may be null while the run exists
//! (`CaseRun::graphql_id`); a workflow may be absent from the repository's
//! list while its runs remain (`CaseWorkflow::listed`), and its REST
//! detail by id may answer, 404 or fail apart from that
//! (`CaseWorkflow::detail`); the operation's check-run nodes query may
//! answer, answer null for some check's node (error-free, or with the
//! field error GraphQL adds for a node it cannot resolve), or fail, apart
//! from the detail (`Case::graph`, decisions 119 (2), 122 (4)): gh's
//! GraphQL client fails
//! `gh pr checks` on any reply error (`api/client.go`, `Client.GraphQL`;
//! `checks.go:281`), so where the graph failed the legacy printed
//! `checks-failed` and no verdict (`ci-wait:854-864`), which the oracle
//! renders as the legacy's answer (`outcome: error`); the operation's
//! verdict on such a case, reached through the detail route, is compared
//! with the legacy over the same input with the graph answering, a named
//! correction (`corrected-119-2`), and its refusal there is the one
//! agreement. A null node is the operation's own route, which the legacy
//! never read: where the operation refuses because every route failed,
//! the legacy's verdict is not compared (`route-refused`). A workflow's
//! name is shared by other workflows and a path by other ids (a recreated
//! file), and names on both sides of gh's key carry `/`.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::{Map, Value, json};

use crate::ops::VerifyHead;

use super::judge::{self, Judgement};
use super::selection::{self, Identity, Scope, Selection};
use super::{Answer, Bucket, Cause, Endpoint, Read, Source, Transport, evidence};

const REPO: &str = "owner/repo";
/// The consumer repository's id, as the branch and run objects name it.
const REPO_ID: u64 = 1_296_269;
const BASE: &str = "main";
/// The pinned head every reply is about.
const HEAD: &str = "737bce791577e140436490e0fed5751bb5144a61";
/// The source commit a `workflows` rule pins the required workflow to.
const WORKFLOW_SHA: &str = "0123456789abcdef0123456789abcdef01234567";
/// Another source commit, which binds no rule.
const OTHER_SHA: &str = "89abcdef0123456789abcdef0123456789abcdef";
const WORKFLOW_PATH: &str = ".github/workflows/required.yml";
/// The required workflow's source repository and its id.
const SOURCE_REPO: &str = "owner/source";
const SOURCE_REPO_ID: u64 = 7;
/// A repository id no proof names.
const OTHER_REPO_ID: u64 = 8;
/// A fork of the source: the same files at the same commits, another id.
const FORK_REPO: &str = "owner/fork";
const FORK_REPO_ID: u64 = 9;
/// A run id no case holds, which a link may still name.
const UNHELD_RUN: u64 = 999;

/// The substantive-event list the oracle runs with. It mirrors the
/// operation's constant; the corpus generates every event here and
/// `schedule`, so a difference between the two lists reaches a verdict
/// mismatch.
const SUBSTANTIVE_EVENTS: [&str; 6] = [
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "merge_group",
    "push",
    "workflow_dispatch",
];

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("tests/rust/fixtures/gh")
}

fn fixture(name: &str) -> Value {
    serde_json::from_str(&fs::read_to_string(fixtures().join(name)).unwrap()).unwrap()
}

// --- the fake transport ---------------------------------------------------------

/// The transport the differential reads through: the same protocol as the
/// fake `gh` script beside the fixtures (`fixtures/gh/gh`), so one
/// rendering serves both. `gh api PATH` answers from the map by path, as
/// `{exit?, body?, text?}`; `gh api graphql -f query=… -f ids[]=…` answers
/// from the `graphql` entry, whose `body.nodes` maps a node id to its node
/// and is assembled into `{data: {nodes: […]}}` in the order asked, null
/// for an id it lacks, and whose `body.errored` lists the ids GitHub
/// cannot resolve: each asked one is null with a `NOT_FOUND` error at its
/// path `["nodes", i]` in `errors`, GraphQL's shape for a field error
/// (specification § 6.4.4); a GraphQL reply carrying `errors` is printed
/// with exit 1 and its failure's detail is `gh: ` then the errors'
/// messages, one per line, as gh exits nonzero on every such reply and
/// writes that to stderr (v2.103.3 `pkg/cmd/api/api.go:492-557`, `:722`);
/// a planted `exit` with an error-free `body` is a call that failed for a
/// cause its output does not carry; a query over check-run nodes answers
/// from the `graphql CheckRun` entry first, where one is set, so the two
/// node queries fail apart (`fail_check_run_nodes`). A path with no entry
/// is a failed request. Every call is logged as the script logs it.
struct FakeGh {
    replies: Map<String, Value>,
    log: RefCell<Vec<String>>,
}

/// The entry a check-run nodes query reads before `graphql`.
const CHECK_RUN_NODES: &str = "graphql CheckRun";

impl FakeGh {
    fn new() -> Self {
        FakeGh {
            replies: Map::new(),
            log: RefCell::new(Vec::new()),
        }
    }

    fn answer(&mut self, path: &str, body: Value) -> &mut Self {
        self.replies.insert(path.to_owned(), json!({"body": body}));
        self
    }

    /// A request gh fails with a server error, as it prints one.
    fn fail(&mut self, path: &str) -> &mut Self {
        self.replies.insert(
            path.to_owned(),
            json!({"exit": 1, "text": "HTTP 500: Internal Server Error"}),
        );
        self
    }

    /// The check-run nodes query fails with a server error while the
    /// check-suite nodes query keeps answering: two requests, two
    /// transports' worth of luck.
    fn fail_check_run_nodes(&mut self) -> &mut Self {
        self.fail(CHECK_RUN_NODES)
    }

    fn log(&self) -> Vec<String> {
        self.log.borrow().clone()
    }
}

impl Transport for FakeGh {
    fn call(&self, endpoint: Endpoint, args: &[&str]) -> Read<Answer> {
        self.log.borrow_mut().push(args.join(" "));
        let failed = |detail: &str| Cause::ReadFailed {
            endpoint,
            detail: detail.to_owned(),
        };
        let reply = match args {
            ["api", "graphql", rest @ ..] => {
                let ids: Vec<&str> = rest
                    .iter()
                    .filter_map(|arg| arg.strip_prefix("ids[]="))
                    .collect();
                let over_check_runs = rest
                    .iter()
                    .any(|arg| arg.starts_with("query=") && arg.contains("... on CheckRun "));
                let entry = over_check_runs
                    .then(|| self.replies.get(CHECK_RUN_NODES))
                    .flatten()
                    .or_else(|| self.replies.get("graphql"));
                entry.map(|reply| {
                    let mut reply = reply.clone();
                    if let Some(nodes) = reply["body"]["nodes"].as_object().cloned() {
                        let answered: Vec<Value> = ids
                            .iter()
                            .map(|id| nodes.get(*id).cloned().unwrap_or(Value::Null))
                            .collect();
                        let errored: Vec<&str> = reply["body"]["errored"]
                            .as_array()
                            .map(|ids| ids.iter().filter_map(Value::as_str).collect())
                            .unwrap_or_default();
                        let errors: Vec<Value> = ids
                            .iter()
                            .enumerate()
                            .filter(|(_, id)| errored.contains(id))
                            .map(|(at, id)| json!({"type": "NOT_FOUND", "path": ["nodes", at], "message": format!("Could not resolve to a node with the global id of '{id}'")}))
                            .collect();
                        reply["body"] = if errors.is_empty() {
                            json!({"data": {"nodes": answered}})
                        } else {
                            json!({"data": {"nodes": answered}, "errors": errors})
                        };
                    }
                    // gh exits 1 and writes `gh: ` then the errors'
                    // messages, one per line, to stderr (`api.go:557`,
                    // `parseErrorResponse`, `:722`).
                    let stderr = reply["body"]["errors"]
                        .as_array()
                        .filter(|errors| !errors.is_empty())
                        .map(|errors| {
                            let messages: Vec<&str> = errors
                                .iter()
                                .map(|error| error["message"].as_str().unwrap_or_default())
                                .collect();
                            format!("gh: {}", messages.join("\n"))
                        });
                    if let Some(stderr) = stderr {
                        reply["exit"] = json!(1);
                        reply["stderr"] = json!(stderr);
                    }
                    reply
                })
            }
            ["api", path] => self.replies.get(*path).cloned(),
            other => panic!("fake gh: unexpected call {other:?}"),
        };
        let Some(reply) = reply else {
            return Err(failed("HTTP 404: Not Found"));
        };
        let exit = reply["exit"].as_u64().unwrap_or(0);
        let bytes = match reply.get("text") {
            Some(text) => text.as_str().unwrap().as_bytes().to_vec(),
            None => reply["body"].to_string().into_bytes(),
        };
        if exit != 0 {
            // What gh wrote to stderr, else its stdout: `Gh::call`'s detail.
            let detail = reply["stderr"].as_str().map_or_else(
                || String::from_utf8_lossy(&bytes).into_owned(),
                str::to_owned,
            );
            return Ok(Answer::Failed {
                stdout: bytes,
                detail,
            });
        }
        if bytes.iter().all(u8::is_ascii_whitespace) {
            return Err(failed("empty answer"));
        }
        Ok(Answer::Printed(bytes))
    }
}

// --- the paths the operation requests ---------------------------------------

fn page(path: &str, n: usize) -> String {
    let join = if path.contains('?') { '&' } else { '?' };
    format!("{path}{join}per_page=100&page={n}")
}

fn check_runs_path(n: usize) -> String {
    page(
        &format!("repos/{REPO}/commits/{HEAD}/check-runs?filter=all"),
        n,
    )
}

fn check_suites_path(n: usize) -> String {
    page(&format!("repos/{REPO}/commits/{HEAD}/check-suites"), n)
}

fn statuses_path(n: usize) -> String {
    page(&format!("repos/{REPO}/commits/{HEAD}/status"), n)
}

fn runs_path(n: usize) -> String {
    page(&format!("repos/{REPO}/actions/runs?head_sha={HEAD}"), n)
}

fn workflows_path(n: usize) -> String {
    page(&format!("repos/{REPO}/actions/workflows"), n)
}

fn rules_path(n: usize) -> String {
    page(&format!("repos/{REPO}/rules/branches/{BASE}"), n)
}

fn branch_path() -> String {
    format!("repos/{REPO}/branches/{BASE}")
}

/// The suite read of a bound run, under the endpoint's default `filter`.
fn suite_check_runs_path(suite: u64, n: usize) -> String {
    page(&format!("repos/{REPO}/check-suites/{suite}/check-runs"), n)
}

fn workflow_path_by_id(id: u64) -> String {
    format!("repos/{REPO}/actions/workflows/{id}")
}

fn job_link(run: u64, check: u64) -> String {
    format!("https://github.com/{REPO}/actions/runs/{run}/job/{check}")
}

fn run_link(run: u64) -> String {
    format!("https://github.com/{REPO}/actions/runs/{run}")
}

fn check_page_link(check: u64) -> String {
    format!("https://github.com/{REPO}/runs/{check}")
}

fn blob_url(repository: &str, sha: &str, path: &str) -> String {
    format!("https://github.com/{repository}/blob/{sha}/{path}")
}

/// A check suite's GraphQL node id.
fn suite_node_id(suite: u64) -> String {
    format!("CS_{suite}")
}

/// A check run's GraphQL node id.
fn check_node_id(check: u64) -> String {
    format!("CR_{check}")
}

// --- the case model -------------------------------------------------------------

/// A head's evidence as GitHub's object graph: what the legacy's inputs
/// and the operation's replies are both rendered from.
#[derive(Clone, Debug)]
struct Case {
    name: String,
    required_only: bool,
    /// The classic contexts the base requires.
    contexts: Vec<String>,
    /// The `workflows` rule's definitions, in the order the rule lists
    /// them; duplicates allowed, as a rule set may repeat one.
    definitions: Vec<Definition>,
    /// The repositories a proof may name, answered by `repos/{name}`.
    sources: Vec<SourceRepo>,
    /// The repository's workflows, the objects runs name by id.
    workflows: Vec<CaseWorkflow>,
    runs: Vec<CaseRun>,
    /// The check runs in the order the REST endpoint lists them for the
    /// head: with the statuses after them, the operation's evidence
    /// listing, whose positions break its ties among equal starts
    /// (decision 122 (1)); the generator draws this order apart from the
    /// ids.
    checks: Vec<CaseCheck>,
    statuses: Vec<CaseStatus>,
    /// The order GitHub returned the rollup's one union connection of
    /// check runs and statuses in, the legacy's input alone (gh
    /// `api/query_builder.go:284`, `checks.go:290`; no documentation fixes
    /// it, and the operation reads nothing for it): every check run and
    /// every status once, the check runs in an order drawn apart from the
    /// REST listing and the statuses at drawn positions, where the
    /// generator or a witness states one. `None` leaves the union order
    /// unstated, and the legacy's dependence on it is counted under the
    /// listing's own order alone (`Case::listing`).
    union: Option<Vec<Member>>,
    /// What the operation's check-run nodes query answers (decision 119
    /// (2)), drawn apart from every workflow's REST detail.
    graph: Graph,
    /// Whether the generator drew the case: the floor holds the generator
    /// to the dimensions the fixed witnesses hold alone otherwise.
    generated: bool,
    /// The counts this fixed case holds: the corpus test asserts each is
    /// recorded for it, so a count a witness exists for cannot fall
    /// silently (R-U4e14 L1).
    holds: &'static [&'static str],
}

/// One member of the rollup's union connection: a check run by id or a
/// status by context.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Member {
    Check(u64),
    Status(String),
}

/// The check-run nodes query's readability: every node answers; the
/// viewer cannot resolve the named check runs' nodes, as an error-free
/// null entry (`NullNodes`) or as a null entry with a `NOT_FOUND` error at
/// its path (`ErroredNodes`, GraphQL's documented shape for a field it
/// could not resolve, specification § 6.4.4; decision 122 (4)), the
/// operation's own route either way, which `gh pr checks` never read; or
/// the query fails as a whole, on which gh's GraphQL client failed `gh pr
/// checks` and the legacy printed `checks-failed` with no verdict.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Graph {
    Answers,
    NullNodes(Vec<u64>),
    ErroredNodes(Vec<u64>),
    Failed,
}

impl Graph {
    /// The check runs whose nodes the viewer cannot resolve.
    fn unresolved(&self) -> &[u64] {
        match self {
            Graph::Answers | Graph::Failed => &[],
            Graph::NullNodes(ids) | Graph::ErroredNodes(ids) => ids,
        }
    }
}

/// One required workflow definition as the rule states it.
#[derive(Clone, Debug)]
struct Definition {
    repository_id: u64,
    path: String,
    sha: String,
    reference: Option<String>,
}

#[derive(Clone, Debug)]
struct SourceRepo {
    id: u64,
    full_name: String,
}

/// A workflow: its id, its non-null name (shared with other workflows
/// where two files name alike) and its current path (shared with another
/// id where a file was recreated).
#[derive(Clone, Debug)]
struct CaseWorkflow {
    id: u64,
    name: String,
    path: String,
    /// Whether `actions/workflows` lists it: a deleted file's runs remain
    /// while the list drops it, and an organization ruleset workflow is
    /// never listed, so the operation resolves a name the list lacks
    /// through the graph, then by id (decision 117 (4)).
    listed: bool,
    /// What `actions/workflows/{id}` answers, drawn apart from `listed`.
    detail: Detail,
}

/// The REST detail of a workflow by id: the object, gh's documented 404
/// (an organization or enterprise ruleset workflow the viewer may not
/// read, gh `pkg/cmd/run/shared/shared.go:460-470`), or a failed request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Detail {
    Answers,
    NotFound,
    Failed,
}

#[derive(Clone, Debug)]
struct CaseRun {
    id: u64,
    /// The `workflow_id`.
    workflow: u64,
    /// The REST run's own `name`, string or null, which neither side
    /// reads: a workflow's name is the workflow object's.
    display_name: Option<String>,
    /// The workflow file at the run, as GitHub renders `path`, with or
    /// without `@ref`; the workflow's current path can differ.
    path: String,
    event: String,
    status: String,
    conclusion: Option<String>,
    /// `None` omits `run_attempt`.
    attempt: Option<u64>,
    /// `None` omits `run_started_at`.
    started: Option<String>,
    updated: String,
    /// The run's check suite, drawn apart from its id.
    suite: u64,
    /// Whether REST carries `check_suite_id` and `check_suite_node_id`,
    /// which are not in its required list.
    rest_suite: bool,
    /// Whether the GraphQL `WorkflowRun.databaseId` is present; null is
    /// documented (`Int`, nullable), and leaves the run present but
    /// unidentified wherever it is read through the graph (decision 114
    /// (2)).
    graphql_id: bool,
    /// The workflow file the run executed, as its suite node proves it;
    /// `None` is a node whose `file` is null.
    source: Option<SourceFile>,
    /// The check runs `check-suites/{suite}/check-runs` lists for the run's
    /// suite under its default `filter=latest`: the server's selection, a
    /// drawn input both sides receive (decision 117 (1)).
    latest: Latest,
}

/// GitHub's `latest` answer for a suite: every check run of the suite,
/// which a fixed case whose names are unique states this way, or the
/// members by check id, which the generator draws per name among the
/// suite's repeats, whatever their `completed_at`. "Filters check runs by
/// their completed_at timestamp. latest returns the most recent check
/// runs." fixes neither which member of a repeated name the server returns
/// nor that it is one, so the draw is the input, never a rule.
#[derive(Clone, Debug)]
enum Latest {
    Every,
    These(Vec<u64>),
}

/// The source proof of one run: the file's repository, path and the
/// commit it was read at, and whether the viewer can read that repository.
#[derive(Clone, Debug)]
struct SourceFile {
    repository: String,
    path: String,
    sha: String,
    readable: bool,
}

#[derive(Clone, Debug)]
struct CaseCheck {
    id: u64,
    name: String,
    status: String,
    conclusion: Option<String>,
    /// The check suite, which every check run has (`CheckSuite!`); a run's
    /// suite makes the check a job of that run, another suite an external
    /// check.
    suite: u64,
    /// Whether REST carries `check_suite`, documented nullable.
    rest_suite: bool,
    /// The check run's `details_url`, the GraphQL `detailsUrl` gh printed
    /// as the legacy's `link` (`aggregate.go:51`).
    details: Link,
    /// The check run's `html_url`, its page, which the legacy's suite read
    /// listed a bound run's jobs by (`ci-run-correlation.sh:495`). Drawn
    /// apart from `details`: GitHub documents no relation between the two.
    page: Link,
    started: Option<String>,
    /// `completed_at`, the key of the suite read's `latest` filter.
    completed: Option<String>,
}

/// A check run's URL: a job page under a run (its job id the check's
/// own), any other URL, or null.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Link {
    Job(u64),
    Url(String),
    None,
}

impl Link {
    fn url(&self, check: u64) -> Option<String> {
        match self {
            Link::Job(run) => Some(job_link(*run, check)),
            Link::Url(url) => Some(url.clone()),
            Link::None => None,
        }
    }
}

#[derive(Clone, Debug)]
struct CaseStatus {
    context: String,
    state: String,
    target: Target,
}

#[derive(Clone, Debug)]
enum Target {
    None,
    /// A run-level link, the legacy's aggregate.
    Run(u64),
    /// A job link into a run.
    Job(u64, u64),
    /// A link naming no run.
    Foreign(String),
}

impl Target {
    fn url(&self) -> Option<String> {
        match self {
            Target::None => None,
            Target::Run(run) => Some(run_link(*run)),
            Target::Job(run, job) => Some(job_link(*run, *job)),
            Target::Foreign(url) => Some(url.clone()),
        }
    }
}

/// A workflow's name; workflows 1 and 4 share one, as two files may,
/// workflow 5 is the required file recreated under a new id with the same
/// name, and workflows 6 and 7 are named so that a job `build/CI` of
/// `tests` and a job `build` of `CI/tests` share gh's slash-joined key
/// (decision 117 (2)).
fn workflow_name(id: u64) -> String {
    match id {
        1 | 4 => "CI".to_owned(),
        2 => "Guard".to_owned(),
        3 | 5 => "Required".to_owned(),
        6 => "CI/tests".to_owned(),
        7 => "tests".to_owned(),
        other => format!("wf-{other}"),
    }
}

/// A workflow's current file path; workflows 3 and 5 are the required
/// path, two ids at one path.
fn workflow_path(id: u64) -> String {
    match id {
        1 => ".github/workflows/ci.yml".to_owned(),
        2 => ".github/workflows/guard.yml".to_owned(),
        3 | 5 => WORKFLOW_PATH.to_owned(),
        4 => ".github/workflows/ci-nightly.yml".to_owned(),
        6 => ".github/workflows/ci-tests.yml".to_owned(),
        7 => ".github/workflows/tests.yml".to_owned(),
        other => format!(".github/workflows/wf-{other}.yml"),
    }
}

fn case_workflow(id: u64) -> CaseWorkflow {
    CaseWorkflow {
        id,
        name: workflow_name(id),
        path: workflow_path(id),
        listed: true,
        detail: Detail::Answers,
    }
}

/// The workflows a case's runs name, each once.
fn workflows_of(runs: &[CaseRun]) -> Vec<CaseWorkflow> {
    let ids: BTreeSet<u64> = runs.iter().map(|r| r.workflow).collect();
    ids.into_iter().map(case_workflow).collect()
}

/// A fixed case's suite for a run: apart from every run and check id.
fn suite_of(run: u64) -> u64 {
    run + 5_000_000
}

/// A suite no run owns: an external app's.
const EXTERNAL_SUITE: u64 = 9001;

/// The proof of a run of the required workflow at the rule's commit.
fn required_source(sha: &str) -> SourceFile {
    SourceFile {
        repository: SOURCE_REPO.to_owned(),
        path: WORKFLOW_PATH.to_owned(),
        sha: sha.to_owned(),
        readable: true,
    }
}

/// The proof of a run of the consumer's own workflow file at the head.
fn own_source(path: &str) -> SourceFile {
    SourceFile {
        repository: REPO.to_owned(),
        path: path.to_owned(),
        sha: HEAD.to_owned(),
        readable: true,
    }
}

/// The one definition the legacy fixtures and most generated cases
/// require: `WORKFLOW_PATH` from the source repository at `WORKFLOW_SHA`.
fn required_definition() -> Definition {
    Definition {
        repository_id: SOURCE_REPO_ID,
        path: WORKFLOW_PATH.to_owned(),
        sha: WORKFLOW_SHA.to_owned(),
        reference: Some("refs/heads/main".to_owned()),
    }
}

/// The three repositories every case answers `repos/{name}` for.
fn sources() -> Vec<SourceRepo> {
    vec![
        SourceRepo {
            id: REPO_ID,
            full_name: REPO.to_owned(),
        },
        SourceRepo {
            id: SOURCE_REPO_ID,
            full_name: SOURCE_REPO.to_owned(),
        },
        SourceRepo {
            id: FORK_REPO_ID,
            full_name: FORK_REPO.to_owned(),
        },
    ]
}

impl Case {
    fn run_by_id(&self, id: u64) -> Option<&CaseRun> {
        self.runs.iter().find(|r| r.id == id)
    }

    /// The run a suite belongs to, where an Actions workflow made it
    /// (`CheckSuite.workflowRun`).
    fn suite_run(&self, suite: u64) -> Option<&CaseRun> {
        self.runs.iter().find(|r| r.suite == suite)
    }

    /// The workflow a run executed (`WorkflowRun.workflow`).
    fn workflow_of(&self, run: &CaseRun) -> &CaseWorkflow {
        self.workflows
            .iter()
            .find(|w| w.id == run.workflow)
            .unwrap_or_else(|| {
                panic!(
                    "{}: run {} names workflow {} the case lacks",
                    self.name, run.id, run.workflow
                )
            })
    }

    /// The contexts gh's checks query received for the head
    /// (`api/query_builder.go:286-304`, decoded into `api.CheckContext`,
    /// `api/queries_pr.go:219-252`): every check run and every status
    /// (`StatusCheckRollup.contexts`, "A list of status contexts and check
    /// runs for this commit"), each at its position in the operation's
    /// listing (the check runs as listed, then the statuses) or in the
    /// union order `tie` carries, sorted by start, then in the order `tie`
    /// names among equal starts, since GraphQL documents none. A check
    /// run's `checkSuite.workflowRun` is its suite's run or null
    /// (`CheckSuite.workflowRun: WorkflowRun`), whose `event` and
    /// `workflow.name` are non-null; Go leaves both `""` where the run is
    /// null, and a null `startedAt` or `detailsUrl` its zero value. The
    /// run's `databaseId` is not in gh's query: a run GitHub does not
    /// identify still names its workflow and event here.
    fn check_contexts(&self, tie: TieOrder<'_>) -> Vec<CheckContext> {
        let checks = self.checks.iter().map(|c| {
            let (event, workflow) = self.suite_run(c.suite).map_or_else(
                || (String::new(), String::new()),
                |run| (run.event.clone(), self.workflow_of(run).name.clone()),
            );
            CheckContext {
                name: c.name.clone(),
                event,
                workflow,
                status: c.status.to_ascii_uppercase(),
                conclusion: c
                    .conclusion
                    .as_deref()
                    .map(str::to_ascii_uppercase)
                    .unwrap_or_default(),
                started_at: c.started.clone().unwrap_or_else(|| ZERO_TIME.to_owned()),
                details_url: c.details.url(c.id).unwrap_or_default(),
                context: String::new(),
                state: String::new(),
                target_url: String::new(),
                id: format!("check:{}", c.id),
                order: (0, c.id),
            }
        });
        let statuses = self.statuses.iter().map(|s| CheckContext {
            name: String::new(),
            event: String::new(),
            workflow: String::new(),
            status: String::new(),
            conclusion: String::new(),
            started_at: ZERO_TIME.to_owned(),
            details_url: String::new(),
            context: s.context.clone(),
            state: s.state.to_ascii_uppercase(),
            target_url: s.target.url().unwrap_or_default(),
            id: format!("status:{}", s.context),
            order: (0, 0),
        });
        let members = self.listing();
        let position = |member: &Member| -> usize {
            let listing = match tie {
                TieOrder::Port => members.as_slice(),
                TieOrder::Union(union) => union,
            };
            listing
                .iter()
                .position(|m| m == member)
                .unwrap_or_else(|| panic!("{}: {member:?} is not in the union", self.name))
        };
        let mut contexts: Vec<CheckContext> = checks
            .chain(statuses)
            .zip(&members)
            .map(|(context, member)| CheckContext {
                order: (position(member), context.order.1),
                ..context
            })
            .collect();
        // Started alike (RFC 3339 at one offset, the zero time for none):
        // the operation's order, the later listing position then the higher
        // check-run id; or the union's own order, which gh's insertion sort
        // leaves standing on at most `GH_SORT_EXACT_UP_TO` contexts; a
        // longer union is not rendered (`Case::union_rendered`).
        contexts.sort_by(|a, b| match b.started_at.cmp(&a.started_at) {
            std::cmp::Ordering::Equal => match tie {
                TieOrder::Port => b.order.cmp(&a.order),
                TieOrder::Union(_) => a.order.cmp(&b.order),
            },
            unequal => unequal,
        });
        contexts
    }

    /// The operation's listing as a union: every check run in the order the
    /// REST endpoint returns them, then every status. Under `TieOrder::Port`
    /// it is the positions the operation's order reads; as
    /// `TieOrder::Union` it is the union in the listing's own order, which
    /// reverses every tie of `Port`.
    fn listing(&self) -> Vec<Member> {
        self.checks
            .iter()
            .map(|c| Member::Check(c.id))
            .chain(
                self.statuses
                    .iter()
                    .map(|s| Member::Status(s.context.clone())),
            )
            .collect()
    }

    /// gh's deduplication key of a check (`aggregate.go:110`) in its parts:
    /// its name, its suite's run's workflow name and event, `""` for a
    /// suite no run made.
    fn key_parts(&self, c: &CaseCheck) -> (String, String, String) {
        let (workflow, event) = self.suite_run(c.suite).map_or_else(
            || (String::new(), String::new()),
            |run| (self.workflow_of(run).name.clone(), run.event.clone()),
        );
        (c.name.clone(), workflow, event)
    }

    /// Whether the legacy's answer could follow its input order (decision
    /// 117 (3); 122 (2)): two contexts sharing a name started alike (both
    /// undated included; a status has no start), whatever their types, the
    /// pairs the lib's run-status pick (`max_by(._runid)`) and run-less
    /// deduplication (`sort_by(.startedAt) | last`) reduce by name across
    /// gh's key and across a status and a check run; or two check runs
    /// sharing gh's slash-joined key started alike, whatever their names
    /// (`tied_in_key`), the pairs gh's own survivor depends on. The
    /// combined status holds one per context, so two statuses never tie.
    fn tied(&self) -> bool {
        let mut seen = BTreeSet::new();
        self.checks
            .iter()
            .map(|c| (c.name.as_str(), c.started.as_deref()))
            .chain(self.statuses.iter().map(|s| (s.context.as_str(), None)))
            .any(|context| !seen.insert(context))
            || self.tied_in_key()
    }

    /// Whether the adapter renders gh's sort of this case's union exactly:
    /// at most `GH_SORT_EXACT_UP_TO` contexts, every check run and status
    /// a member (decision 123 (1)).
    fn union_rendered(&self) -> bool {
        self.checks.len() + self.statuses.len() <= GH_SORT_EXACT_UP_TO
    }

    /// Whether two check runs sharing gh's deduplication key started alike:
    /// the ties gh's own survivor depends on, named alike or not.
    fn tied_in_key(&self) -> bool {
        let mut seen = BTreeSet::new();
        self.checks.iter().any(|c| {
            let (name, workflow, event) = self.key_parts(c);
            !seen.insert((format!("{name}/{workflow}/{event}"), c.started.clone()))
        })
    }

    /// Whether two contexts tie (`tied`) without sharing gh's deduplication
    /// key: a status and a check run, or two check runs under different
    /// workflows or events, which only the lib's picks reduce by name.
    fn cross_key_tie(&self) -> bool {
        // gh's keys per (name, start); a status's is its context alone.
        let mut keys: BTreeMap<(&str, Option<&str>), BTreeSet<String>> = BTreeMap::new();
        for c in &self.checks {
            let (name, workflow, event) = self.key_parts(c);
            keys.entry((c.name.as_str(), c.started.as_deref()))
                .or_default()
                .insert(format!("check {name}/{workflow}/{event}"));
        }
        for s in &self.statuses {
            keys.entry((s.context.as_str(), None))
                .or_default()
                .insert(format!("status {}", s.context));
        }
        keys.values().any(|members| members.len() > 1)
    }

    /// Whether REST joins a check to a run: the check carries its suite and
    /// a run carries that suite as its `check_suite_id`.
    fn rest_joined(&self, c: &CaseCheck) -> bool {
        c.rest_suite && self.suite_run(c.suite).is_some_and(|r| r.rest_suite)
    }

    /// Whether the operation's nodes query resolves a check's node: the
    /// query answers and the check is not among the unresolved.
    fn node_resolves(&self, c: &CaseCheck) -> bool {
        self.graph != Graph::Failed && !self.graph.unresolved().contains(&c.id)
    }

    /// Whether a validated node names `workflow` (decisions 119 (2), 122
    /// (3)): a check of some run of that workflow whose node resolves, the
    /// node naming the run's workflow for the run REST joins the check to,
    /// or for the run GitHub identifies through `workflowRun.databaseId`
    /// (`CaseRun::graphql_id`). Every such check is asked while the
    /// workflow is unlisted.
    fn names_by_graph(&self, workflow: u64) -> bool {
        self.runs
            .iter()
            .filter(|r| r.workflow == workflow)
            .any(|r| {
                self.checks.iter().any(|c| {
                    c.suite == r.suite
                        && self.node_resolves(c)
                        && (self.rest_joined(c) || r.graphql_id)
                })
            })
    }

    /// Whether the operation's refusal with `cause` is one decisions 117 (4)
    /// and 119 (2) admit: every route to what the cause names failed on
    /// this case, judged from the case's documented relations alone. An
    /// unjoined check (REST carries no suite on the check, or no run names
    /// its suite) has the graph as its one route; a joined check's workflow
    /// has the list, the graph through its own node or a sibling node of a
    /// run of the same workflow (`names_by_graph`), and the detail. A
    /// refusal with a route left, or with another cause, is a disagreement.
    fn every_route_failed(&self, cause: &str) -> bool {
        match cause {
            "check-run-suites-read-failed" => {
                self.graph == Graph::Failed && self.checks.iter().any(|c| !self.rest_joined(c))
            }
            "check-run-suites-response-invalid" => self
                .checks
                .iter()
                .any(|c| !self.rest_joined(c) && self.graph.unresolved().contains(&c.id)),
            "workflow-read-failed" => self.runs.iter().any(|run| {
                let workflow = self.workflow_of(run);
                !workflow.listed
                    && workflow.detail != Detail::Answers
                    && self
                        .checks
                        .iter()
                        .any(|c| c.suite == run.suite && self.rest_joined(c))
                    && !self.names_by_graph(run.workflow)
            }),
            _ => false,
        }
    }

    /// Whether some run's drawn `latest` answer lists one name twice, as a
    /// suite with two distinct jobs sharing a name may be answered.
    fn latest_names_twice(&self) -> bool {
        self.runs.iter().any(|run| match &run.latest {
            Latest::Every => false,
            Latest::These(ids) => {
                let mut names = BTreeSet::new();
                ids.iter().any(|id| {
                    let check = self.checks.iter().find(|c| c.id == *id);
                    check.is_some_and(|c| !names.insert(c.name.as_str()))
                })
            }
        })
    }

    /// Whether the check runs are listed in an order other than ascending
    /// id, so the rollup's positions and the ids disagree on some tie.
    fn listing_apart_from_ids(&self) -> bool {
        self.checks.windows(2).any(|pair| pair[0].id > pair[1].id)
    }

    /// Whether two check runs with different `(name, workflow, event)`
    /// share gh's slash-joined string key (decision 117 (2)).
    fn key_collision(&self) -> bool {
        let mut by_key: BTreeMap<String, BTreeSet<(String, String, String)>> = BTreeMap::new();
        for c in &self.checks {
            let parts = self.key_parts(c);
            by_key
                .entry(format!("{}/{}/{}", parts.0, parts.1, parts.2))
                .or_default()
                .insert(parts);
        }
        by_key.values().any(|tuples| tuples.len() > 1)
    }

    /// Whether some run's suite lists a name twice, so its `latest` answer
    /// chose among repeats.
    fn repeats_a_suite_name(&self) -> bool {
        self.runs.iter().any(|run| {
            let mut names = BTreeSet::new();
            self.checks
                .iter()
                .filter(|c| c.suite == run.suite)
                .any(|c| !names.insert(c.name.as_str()))
        })
    }

    /// Whether a run some check joins names a workflow the list lacks and
    /// whose REST detail does not answer: the graph alone names it.
    fn names_a_workflow_by_graph_alone(&self) -> bool {
        self.runs.iter().any(|run| {
            let workflow = self.workflow_of(run);
            !workflow.listed
                && workflow.detail != Detail::Answers
                && self.checks.iter().any(|c| c.suite == run.suite)
        })
    }

    /// The legacy's rollup: `gh pr checks "$1" --json
    /// name,state,bucket,link,startedAt,workflow` (`ci-run-correlation.sh:218`)
    /// over `aggregate_checks`, the six fields as `cmdutil.StructExportData`
    /// exports them (`aggregate.go:32-34`; `StartedAt` marshalled as Go
    /// marshals `time.Time`, RFC 3339), plus `_id`, a tag the legacy never
    /// reads and the projection reads an entry's identity back from. Under
    /// `Correction::StartupFailure` a `STARTUP_FAILURE` row's bucket is
    /// `fail` (decision 113 (3)); everything else is gh's.
    fn legacy_rollup(&self, corrections: Corrections, tie: TieOrder<'_>) -> Vec<Value> {
        aggregate_checks(self.check_contexts(tie))
            .into_iter()
            .map(|row| {
                let bucket = match (corrections.startup_failure, row.state.as_str()) {
                    (true, "STARTUP_FAILURE") => "fail",
                    (true | false, _) => row.bucket,
                };
                json!({
                    "name": row.name, "state": row.state, "bucket": bucket, "link": row.link,
                    "startedAt": row.started_at, "workflow": row.workflow, "_id": row.id,
                })
            })
            .collect()
    }

    /// Whether the legacy's rollup carries a row decision 113 corrects.
    fn has_startup_failure(&self) -> bool {
        self.legacy_rollup(Corrections::NONE, TieOrder::Port)
            .iter()
            .any(|row| row["state"] == "STARTUP_FAILURE")
    }

    /// Whether a required definition's run the rule can bind (the required
    /// path from the source repository at the rule's sha, concluded) lists
    /// one job name twice in its suite, so the drawn `latest` answer decides
    /// which page the bound job carries (decision 117 (1)).
    fn bound_suite_repeats_a_name(&self) -> bool {
        self.required_only
            && self.definitions.iter().any(|d| {
                d.repository_id == SOURCE_REPO_ID
                    && d.path == WORKFLOW_PATH
                    && d.sha == WORKFLOW_SHA
            })
            && self.runs.iter().any(|run| {
                run.status == "completed"
                    && run.source.as_ref().is_some_and(|f| {
                        f.repository == SOURCE_REPO && f.sha == WORKFLOW_SHA && f.readable
                    })
                    && {
                        let mut names = BTreeSet::new();
                        self.checks
                            .iter()
                            .filter(|c| c.suite == run.suite)
                            .any(|c| !names.insert(c.name.as_str()))
                    }
            })
    }

    /// The check runs GitHub's `latest` answer holds for a run's suite
    /// (`CaseRun::latest`): every check run of the suite, which a fixed
    /// case states only where no name repeats, or the drawn members, each
    /// of the suite.
    fn suite_members(&self, run: &CaseRun) -> Vec<&CaseCheck> {
        match &run.latest {
            Latest::Every => {
                let members: Vec<&CaseCheck> = self
                    .checks
                    .iter()
                    .filter(|c| c.suite == run.suite)
                    .collect();
                let mut names = BTreeSet::new();
                for c in &members {
                    assert!(
                        names.insert(c.name.as_str()),
                        "{}: suite {} lists {} twice: the case states its latest answer",
                        self.name,
                        run.suite,
                        c.name
                    );
                }
                members
            }
            Latest::These(ids) => ids
                .iter()
                .map(|id| {
                    let check = self
                        .checks
                        .iter()
                        .find(|c| c.id == *id)
                        .unwrap_or_else(|| panic!("{}: no check run {id}", self.name));
                    assert_eq!(
                        check.suite, run.suite,
                        "{}: check run {id} is not in suite {}",
                        self.name, run.suite
                    );
                    check
                })
                .collect(),
        }
    }

    /// The suite read the legacy made for a bound run
    /// (`ci-run-correlation.sh:489-495`): the check runs
    /// `check-suites/{suite}/check-runs` listed under its default
    /// `filter=latest`, each by `name` and `html_url`. The members are the
    /// case's drawn input (`suite_members`), the same the operation reads
    /// through `Case::rest`; nothing here selects among them.
    fn suite_jobs(&self, run: &CaseRun) -> Vec<Value> {
        self.suite_members(run)
            .into_iter()
            .map(|c| json!({"name": c.name, "html_url": c.page.url(c.id)}))
            .collect()
    }

    /// A check run as the REST check-runs endpoints list it, on the ref
    /// and in its suite alike.
    fn rest_check(c: &CaseCheck) -> Value {
        json!({
            "id": c.id, "node_id": check_node_id(c.id), "name": c.name, "status": c.status,
            "conclusion": c.conclusion, "head_sha": HEAD,
            "check_suite": if c.rest_suite { json!({"id": c.suite}) } else { Value::Null },
            "started_at": c.started, "completed_at": c.completed,
            "html_url": c.page.url(c.id), "details_url": c.details.url(c.id),
        })
    }

    fn rules(&self) -> Vec<Value> {
        let mut rules = Vec::new();
        if !self.contexts.is_empty() {
            let checks: Vec<Value> = self
                .contexts
                .iter()
                .map(|c| json!({"context": c}))
                .collect();
            rules.push(json!({"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": checks}}));
        }
        if !self.definitions.is_empty() {
            let workflows: Vec<Value> = self
                .definitions
                .iter()
                .map(|d| {
                    let mut workflow =
                        json!({"path": d.path, "repository_id": d.repository_id, "sha": d.sha});
                    if let Some(reference) = &d.reference {
                        workflow["ref"] = json!(reference);
                    }
                    workflow
                })
                .collect();
            rules.push(json!({"type": "workflows", "parameters": {"workflows": workflows}}));
        }
        rules
    }

    fn branch() -> Value {
        json!({"name": BASE, "protected": false, "protection": {"enabled": false, "required_status_checks": {"contexts": [], "checks": []}}})
    }

    /// A run's GraphQL `databaseId`: its REST id, or null (`Int`, nullable).
    fn graphql_id(run: &CaseRun) -> Value {
        if run.graphql_id {
            json!(run.id)
        } else {
            Value::Null
        }
    }

    /// A run's check-suite node, as the GraphQL answer carries it: the
    /// suite and run ids, the attempt as the legacy read it, and the file
    /// from the case's source fields, null where the run has none.
    fn suite_node(run: &CaseRun) -> Value {
        let file = run.source.as_ref().map_or(Value::Null, |f| {
            json!({
                "path": f.path, "repositoryName": f.repository,
                "repositoryFileUrl": blob_url(&f.repository, &f.sha, &f.path),
                "viewerCanReadRepository": f.readable,
            })
        });
        json!({
            "id": suite_node_id(run.suite), "databaseId": run.suite,
            "workflowRun": {"databaseId": Case::graphql_id(run), "runAttempt": run.attempt.unwrap_or(1), "file": file},
        })
    }

    /// A check run's GraphQL node: its suite, the suite's run or null with
    /// the run's id as GitHub identifies it, its event and its workflow
    /// name, the path `gh pr checks` read.
    fn check_node(&self, check: &CaseCheck) -> Value {
        let run = self.suite_run(check.suite).map_or(Value::Null, |run| {
            json!({
                "databaseId": Case::graphql_id(run), "event": run.event,
                "workflow": {"name": self.workflow_of(run).name},
            })
        });
        json!({
            "id": check_node_id(check.id),
            "checkSuite": {"databaseId": check.suite, "workflowRun": run},
        })
    }

    /// The REST workflow object (actions/workflows), as the list and the
    /// read by id both carry it.
    fn rest_workflow(w: &CaseWorkflow) -> Value {
        json!({"id": w.id, "node_id": format!("W_{}", w.id), "name": w.name, "path": w.path, "state": "active"})
    }

    /// The REST run object, the fields both sides' Actions lists carry.
    fn rest_run(r: &CaseRun) -> Value {
        let mut run = json!({
            "id": r.id, "name": r.display_name, "path": r.path, "head_sha": HEAD,
            "status": r.status, "conclusion": r.conclusion, "event": r.event,
            "workflow_id": r.workflow, "updated_at": r.updated,
            "repository": {"id": REPO_ID, "full_name": REPO},
        });
        if r.rest_suite {
            run["check_suite_id"] = json!(r.suite);
            run["check_suite_node_id"] = json!(suite_node_id(r.suite));
        }
        if let Some(attempt) = r.attempt {
            run["run_attempt"] = json!(attempt);
        }
        if let Some(started) = &r.started {
            run["run_started_at"] = json!(started);
        }
        run
    }

    /// The REST and GraphQL replies the operation reads: every check run
    /// with its suite where REST carries it and its two URLs; the suites'
    /// count; the statuses; every run with its suite where REST carries it,
    /// and its suite's `latest` listing; the listed workflows, and each
    /// workflow by id as its detail answers; the rules and the unprotected
    /// documented branch; the suite nodes of the runs that carry one and
    /// every check run's node as `graph` answers it; the repositories by
    /// name.
    fn rest(&self) -> FakeGh {
        let mut gh = FakeGh::new();
        let check_runs: Vec<Value> = self.checks.iter().map(Case::rest_check).collect();
        let suites: BTreeSet<u64> = self
            .checks
            .iter()
            .map(|c| c.suite)
            .chain(self.runs.iter().map(|r| r.suite))
            .collect();
        let statuses: Vec<Value> = self
            .statuses
            .iter()
            .map(|s| json!({"context": s.context, "state": s.state, "description": null, "target_url": s.target.url()}))
            .collect();
        let runs: Vec<Value> = self.runs.iter().map(Case::rest_run).collect();
        let workflows: Vec<Value> = self
            .workflows
            .iter()
            .filter(|w| w.listed)
            .map(Case::rest_workflow)
            .collect();
        let suite_members: Vec<Value> = suites.iter().map(|id| json!({"id": id})).collect();
        let mut nodes: Map<String, Value> = self
            .runs
            .iter()
            .filter(|r| r.rest_suite)
            .map(|r| (suite_node_id(r.suite), Case::suite_node(r)))
            .collect();
        for c in &self.checks {
            if !self.graph.unresolved().contains(&c.id) {
                nodes.insert(check_node_id(c.id), self.check_node(c));
            }
        }
        let mut graphql = json!({"nodes": nodes});
        match &self.graph {
            Graph::Answers | Graph::NullNodes(_) => {}
            Graph::ErroredNodes(ids) => {
                let errored: Vec<String> = ids.iter().map(|id| check_node_id(*id)).collect();
                graphql["errored"] = json!(errored);
            }
            Graph::Failed => {
                gh.fail_check_run_nodes();
            }
        }
        gh.answer(
            &check_runs_path(1),
            json!({"total_count": check_runs.len(), "check_runs": check_runs}),
        )
        .answer(
            &check_suites_path(1),
            json!({"total_count": suites.len(), "check_suites": suite_members}),
        )
        .answer(
            &statuses_path(1),
            json!({"state": "pending", "total_count": statuses.len(), "statuses": statuses, "sha": HEAD}),
        )
        .answer(
            &runs_path(1),
            json!({"total_count": runs.len(), "workflow_runs": runs}),
        )
        .answer(
            &workflows_path(1),
            json!({"total_count": workflows.len(), "workflows": workflows}),
        )
        .answer(&rules_path(1), Value::Array(self.rules()))
        .answer(&branch_path(), Case::branch())
        .answer("graphql", graphql);
        for w in &self.workflows {
            match w.detail {
                Detail::Answers => {
                    gh.answer(&workflow_path_by_id(w.id), Case::rest_workflow(w));
                }
                // No entry is the fake's 404.
                Detail::NotFound => {}
                Detail::Failed => {
                    gh.fail(&workflow_path_by_id(w.id));
                }
            }
        }
        for r in &self.runs {
            let members: Vec<Value> = self
                .suite_members(r)
                .into_iter()
                .map(Case::rest_check)
                .collect();
            gh.answer(
                &suite_check_runs_path(r.suite, 1),
                json!({"total_count": members.len(), "check_runs": members}),
            );
        }
        for source in &self.sources {
            gh.answer(
                &format!("repos/{}", source.full_name),
                json!({"id": source.id, "full_name": source.full_name}),
            );
        }
        gh
    }

    /// The legacy's inputs for `oracle.sh`: the rollup `gh pr checks`
    /// printed (`legacy_rollup`), or null where the graph failed and `gh pr
    /// checks` with it (`Graph::Failed`, unless the corrections hold the
    /// graph answering), the Actions list with the consumer repository on
    /// every run and the suite node where REST carries one, the rules and
    /// branch as the REST rendering, the repositories by name, and each
    /// suite's check runs for the suite read (`suite_jobs`), keyed by the
    /// suite id the run's REST object carries.
    fn legacy_inputs(&self, corrections: Corrections, tie: TieOrder<'_>) -> Value {
        let rollup = if self.graph == Graph::Failed && !corrections.graph_answers {
            Value::Null
        } else {
            Value::Array(self.legacy_rollup(corrections, tie))
        };
        let runs: Vec<Value> = self
            .runs
            .iter()
            .map(|r| {
                let mut run = Case::rest_run(r);
                run["repository_name"] = json!(REPO);
                if r.rest_suite {
                    run["_node"] = Case::suite_node(r);
                }
                run
            })
            .collect();
        let mut suites: Map<String, Value> = Map::new();
        for r in self.runs.iter().filter(|r| r.rest_suite) {
            suites.insert(r.suite.to_string(), Value::Array(self.suite_jobs(r)));
        }
        let sources: Vec<Value> = self
            .sources
            .iter()
            .map(|s| json!({"id": s.id, "full_name": s.full_name, "default_branch": "main"}))
            .collect();
        json!({
            "head": HEAD, "repo": REPO, "repo_id": REPO_ID, "required_only": self.required_only,
            "rollup": rollup, "runs": runs, "rules": self.rules(), "branch": Case::branch(),
            "sources": sources, "suites": suites,
        })
    }
}

/// The named expected differences between the operation and the legacy,
/// each applied to the legacy's input per case, so the legacy's own
/// functions derive the rest; never an exclusion: `startup_failure` reads
/// `fail` where gh bucketed it `pending` (decision 113 (3), (4)), and the
/// graph answers where it failed, so the legacy judges the input the
/// operation reached through the detail route (decision 119 (2)).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Corrections {
    startup_failure: bool,
    graph_answers: bool,
}

impl Corrections {
    const NONE: Corrections = Corrections {
        startup_failure: false,
        graph_answers: false,
    };
}

/// The order of the legacy's contexts among equal starts (decisions 117
/// (3), 122 (2)): the operation's documented order, the comparison; or the
/// legacy under a union gh's sort leaves standing, run to count the
/// legacy's order-dependence and never as the match (`Union`): the union
/// in the operation's listing order (`Case::listing`, every tie of `Port`
/// reversed), or a drawn union order (`Case::union`). Go's `sort.Slice` is
/// an insertion sort on at most `GH_SORT_EXACT_UP_TO` elements, which
/// moves no equal elements, so `Union` renders gh exactly on a union of
/// at most that many contexts; above it gh ran pdqsort, whose order on
/// the union is one outcome the adapter does not compute, so the counts
/// leave such a case out (`union-order-unrendered`, decision 123 (1)).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TieOrder<'a> {
    Port,
    Union(&'a [Member]),
}

/// The length up to which Go's `sort.Slice` is an insertion sort
/// (`sort/zsortfunc.go`, `maxInsertion`: `length <= 12`); above it,
/// pdqsort.
const GH_SORT_EXACT_UP_TO: usize = 12;

// --- gh v2.103.3 `pkg/cmd/pr/checks`, transcribed -------------------------------------

/// Go's zero `time.Time` as `encoding/json` marshals it: what a null
/// `startedAt` decodes to and `--json` prints.
const ZERO_TIME: &str = "0001-01-01T00:00:00Z";

/// `api.CheckContext` (gh `api/queries_pr.go:219-239`), the fields the
/// checks query reads, as Go decoded them: strings `""` and times the zero
/// time where GraphQL answered null or the type has no such field.
///
/// ```go
/// type CheckContext struct {
///     TypeName   string     `json:"__typename"`
///     Name       string     `json:"name"`
///     IsRequired bool       `json:"isRequired"`
///     CheckSuite CheckSuite `json:"checkSuite"`
///     // QUEUED IN_PROGRESS COMPLETED WAITING PENDING REQUESTED
///     Status string `json:"status"`
///     // ACTION_REQUIRED TIMED_OUT CANCELLED FAILURE SUCCESS NEUTRAL SKIPPED STARTUP_FAILURE STALE
///     Conclusion  CheckConclusionState `json:"conclusion"`
///     StartedAt   time.Time            `json:"startedAt"`
///     CompletedAt time.Time            `json:"completedAt"`
///     DetailsURL  string               `json:"detailsUrl"`
///
///     /* StatusContext fields */
///     Context     string `json:"context"`
///     Description string `json:"description"`
///     // EXPECTED ERROR FAILURE PENDING SUCCESS
///     State     StatusState `json:"state"`
///     TargetURL string      `json:"targetUrl"`
///     CreatedAt time.Time   `json:"createdAt"`
/// }
/// ```
///
/// `CheckSuite.WorkflowRun.{Event, Workflow.Name}` are flattened here;
/// `TypeName`, `IsRequired`, `CompletedAt`, `Description` and `CreatedAt`
/// reach none of the six exported fields. `id` is the adapter's tag, and
/// `order` the context's position in the listing `TieOrder` names (the
/// operation's, the check runs in the case's order then the statuses, or
/// the drawn union), then the check-run id.
#[derive(Debug, Clone)]
struct CheckContext {
    name: String,
    event: String,
    workflow: String,
    status: String,
    conclusion: String,
    started_at: String,
    details_url: String,
    context: String,
    state: String,
    target_url: String,
    id: String,
    order: (usize, u64),
}

/// One row of `gh pr checks --json`: gh's `check` struct (`aggregate.go:12-22`),
/// the six fields the legacy requested.
#[derive(Debug)]
struct GhCheck {
    name: String,
    state: String,
    started_at: String,
    link: String,
    bucket: &'static str,
    workflow: String,
    id: String,
}

/// `aggregate.go:95-119`, transcribed:
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
/// RFC 3339 times at one offset order as their strings do, the zero time
/// before every date. Go's `sort.Slice` is documented unstable ("equal
/// elements may be reversed from their original order"); its
/// implementation is deterministic over a given input (insertion sort on
/// at most `GH_SORT_EXACT_UP_TO` elements, pdqsort above, `zsortfunc.go`)
/// and leaves an input already in its order unmoved at every length, so
/// the survivor among contexts started alike was the input's. The sort
/// here receives the contexts already in the order `TieOrder` names
/// (`Case::check_contexts`) and moves none, so what it keeps is what gh
/// keeps on that input (decision 117 (3)); whether that input is gh's own
/// order of the union is `TieOrder`'s claim, exact up to that length.
fn eliminate_duplicates(mut contexts: Vec<CheckContext>) -> Vec<CheckContext> {
    contexts.sort_by(|a, b| b.started_at.cmp(&a.started_at));
    let mut map_checks: BTreeSet<String> = BTreeSet::new();
    let mut map_contexts: BTreeSet<String> = BTreeSet::new();
    let mut unique = Vec::with_capacity(contexts.len());
    for ctx in contexts {
        if !ctx.context.is_empty() {
            if !map_contexts.insert(ctx.context.clone()) {
                continue;
            }
        } else {
            let key = format!("{}/{}/{}", ctx.name, ctx.workflow, ctx.event);
            if !map_checks.insert(key) {
                continue;
            }
        }
        unique.push(ctx);
    }
    unique
}

/// `aggregate.go:36-93`, transcribed with `requiredChecks` false (the lib
/// passed no `--required`, `ci-run-correlation.sh:218`):
///
/// ```go
/// func aggregateChecks(checkContexts []api.CheckContext, requiredChecks bool) (checks []check, counts checkCounts) {
///     for _, c := range eliminateDuplicates(checkContexts) {
///         if requiredChecks && !c.IsRequired {
///             continue
///         }
///
///         state := string(c.State)
///         if state == "" {
///             if c.Status == "COMPLETED" {
///                 state = string(c.Conclusion)
///             } else {
///                 state = c.Status
///             }
///         }
///
///         link := c.DetailsURL
///         if link == "" {
///             link = c.TargetURL
///         }
///
///         name := c.Name
///         if name == "" {
///             name = c.Context
///         }
///
///         item := check{
///             Name:        name,
///             State:       state,
///             StartedAt:   c.StartedAt,
///             CompletedAt: c.CompletedAt,
///             Link:        link,
///             Event:       c.CheckSuite.WorkflowRun.Event,
///             Workflow:    c.CheckSuite.WorkflowRun.Workflow.Name,
///             Description: c.Description,
///         }
///
///         switch state {
///         case "SUCCESS":
///             item.Bucket = "pass"
///             counts.Passed++
///         case "SKIPPED", "NEUTRAL":
///             item.Bucket = "skipping"
///             counts.Skipping++
///         case "ERROR", "FAILURE", "TIMED_OUT", "ACTION_REQUIRED":
///             item.Bucket = "fail"
///             counts.Failed++
///         case "CANCELLED":
///             item.Bucket = "cancel"
///             counts.Canceled++
///         default: // "EXPECTED", "REQUESTED", "WAITING", "QUEUED", "PENDING", "IN_PROGRESS", "STALE"
///             item.Bucket = "pending"
///             counts.Pending++
///         }
///
///         checks = append(checks, item)
///     }
///     return
/// }
/// ```
///
/// `STARTUP_FAILURE` falls to the `default` arm (decision 113). The lib
/// read this `bucket` before its own table (`ci-run-correlation.sh:86`),
/// so every legacy row carried it.
fn aggregate_checks(contexts: Vec<CheckContext>) -> Vec<GhCheck> {
    let mut checks = Vec::new();
    for c in eliminate_duplicates(contexts) {
        let mut state = c.state.clone();
        if state.is_empty() {
            if c.status == "COMPLETED" {
                state = c.conclusion.clone();
            } else {
                state = c.status.clone();
            }
        }
        let mut link = c.details_url.clone();
        if link.is_empty() {
            link = c.target_url.clone();
        }
        let mut name = c.name.clone();
        if name.is_empty() {
            name = c.context.clone();
        }
        let bucket = match state.as_str() {
            "SUCCESS" => "pass",
            "SKIPPED" | "NEUTRAL" => "skipping",
            "ERROR" | "FAILURE" | "TIMED_OUT" | "ACTION_REQUIRED" => "fail",
            "CANCELLED" => "cancel",
            _ => "pending",
        };
        checks.push(GhCheck {
            name,
            state,
            started_at: c.started_at,
            link,
            bucket,
            workflow: c.workflow,
            id: c.id,
        });
    }
    checks
}

// --- the operation over a case ------------------------------------------------------

/// What the operation made of a case: its selection projected, its
/// classification, and the calls it made.
struct Judged {
    projection: Projection,
    conclusion: Conclusion,
    log: Vec<String>,
}

/// The operation over a case: its judgement, or the cause it refused the
/// evidence for (every route to a check's suite or workflow name failed,
/// decision 119 (2)) with the calls it made.
fn judge_case(case: &Case) -> Result<Judged, (Cause, Vec<String>)> {
    let gh = case.rest();
    let request = VerifyHead {
        repo: REPO.to_owned(),
        base: BASE.to_owned(),
        head: HEAD.to_owned(),
        required_only: case.required_only,
    };
    let evidence = match evidence::read(&gh, &request) {
        Ok(evidence) => evidence,
        Err(cause) => return Err((cause, gh.log())),
    };
    let selection = selection::select(&evidence);
    let projection = project(&selection);
    let unresolved_workflow = selection
        .members
        .iter()
        .find(|m| m.identity == Identity::ExpectedWorkflow)
        .map(|m| m.report.name.clone());
    let judgement = judge::classify(selection);
    Ok(Judged {
        projection,
        conclusion: op_conclusion(
            &judgement,
            case.required_only,
            unresolved_workflow.as_deref(),
        ),
        log: gh.log(),
    })
}

/// Every read named the pinned head, the base, the repository's own
/// objects, a node or a source repository the case names, and no pull
/// request.
fn assert_pinned(case: &Case, log: &[String]) {
    assert!(!log.is_empty(), "{}: no gh call", case.name);
    for line in log {
        let source_lookup = case
            .sources
            .iter()
            .any(|s| *line == format!("api repos/{}", s.full_name));
        assert!(
            line.starts_with("api repos/owner/repo/")
                || line.starts_with("api graphql ")
                || source_lookup,
            "{}: {line}",
            case.name
        );
        assert!(!line.contains(" pr "), "{}: {line}", case.name);
        if line.contains("/commits/") || line.contains("head_sha=") {
            assert!(line.contains(HEAD), "{}: {line}", case.name);
        }
    }
}

/// The detail by id is the last route (decision 117 (4)): it is read for a
/// workflow only when no validated node named it, through a REST-joined
/// check of a run of that workflow or a node whose run GitHub identifies
/// as a held run of it (`Case::names_by_graph`, decision 122 (3)).
fn assert_detail_last(case: &Case, log: &[String]) {
    for workflow in &case.workflows {
        let detail = format!("api {}", workflow_path_by_id(workflow.id));
        if log.contains(&detail) {
            assert!(
                !case.names_by_graph(workflow.id),
                "{}: the detail of workflow {} was read while a validated node named it: {log:?}",
                case.name,
                workflow.id
            );
        }
    }
}

// --- the selection projection (decision 110 (4)) ------------------------------------

/// One selected member with its identity: the legacy `link` form is the
/// identity both sides are projected to, and `run` is the run that link
/// names, as the legacy `runid` read it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Projected {
    name: String,
    source: &'static str,
    state: String,
    bucket: &'static str,
    link: Option<String>,
    run: Option<u64>,
}

/// The selection as both sides show it.
#[derive(Debug, PartialEq, Eq)]
enum Projection {
    /// The required read ended before any scoping: pending or unreadable
    /// for the legacy, an unresolved definition for the operation.
    Unresolved,
    Scoped {
        scope: &'static str,
        /// The whole scoped rollup, sorted: what `scope_current_run`
        /// returned, or the scoped failed-required placeholders.
        scoped: Vec<Projected>,
        /// The considered members, sorted.
        members: Vec<Projected>,
        /// The runs the scoped rollup links to, held aggregates excluded:
        /// the legacy `head_runs`.
        head_runs: Vec<u64>,
        /// The required workflows' bound runs, failed runs included.
        bound_runs: Vec<u64>,
        /// The runs the failure correlation reads.
        correlation_runs: Vec<u64>,
    },
}

fn source_word(source: Source) -> &'static str {
    match source {
        Source::CheckRun => "check-run",
        Source::CommitStatus => "commit-status",
        Source::WorkflowRun => "workflow-run",
        Source::Required => "required",
    }
}

fn bucket_word(bucket: Bucket) -> &'static str {
    match bucket {
        Bucket::Pass => "pass",
        Bucket::Fail => "fail",
        Bucket::Pending => "pending",
        Bucket::Skipping => "skipping",
    }
}

/// The run a link names: the legacy `runid`.
fn linked_run(link: Option<&str>) -> Option<u64> {
    link.and_then(|l| l.split_once("/actions/runs/"))
        .and_then(|(_, rest)| {
            let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
            digits.parse().ok()
        })
}

/// The operation's selection, projected.
fn project(selection: &Selection<'_>) -> Projection {
    if selection
        .members
        .iter()
        .any(|m| m.identity == Identity::ExpectedWorkflow)
    {
        return Projection::Unresolved;
    }
    let failed_required = selection
        .members
        .iter()
        .any(|m| matches!(m.identity, Identity::Run(_)));
    let scope = match (failed_required, selection.scope) {
        (true, _) => "failed-required",
        (false, Scope::RequiredSet) => "required",
        (false, Scope::AllChecks) => "all",
    };
    let projected = |m: &selection::Member| {
        let link = match &m.identity {
            Identity::CheckRun { link, .. } => link.clone(),
            Identity::Status { target } => target.clone(),
            Identity::Run(run) => Some(run_link(*run)),
            Identity::Expected | Identity::ExpectedWorkflow => None,
        };
        Projected {
            name: m.report.name.clone(),
            source: source_word(m.report.source),
            state: m.report.state.clone(),
            bucket: bucket_word(m.report.bucket),
            run: linked_run(link.as_deref()),
            link,
        }
    };
    let mut members: Vec<Projected> = selection.members.iter().map(projected).collect();
    members.sort();
    let mut scoped: Vec<Projected> = selection.scoped.iter().map(projected).collect();
    scoped.sort();
    let head_runs: BTreeSet<u64> = selection
        .scoped
        .iter()
        .filter(|m| m.report.state != "expected")
        .filter_map(|m| m.linked)
        .collect();
    Projection::Scoped {
        scope,
        scoped,
        members,
        head_runs: head_runs.into_iter().collect(),
        bound_runs: selection.bound.clone(),
        correlation_runs: selection.runs.iter().map(|r| r.id()).collect(),
    }
}

/// The legacy's selection, projected from the oracle's record of its own
/// functions: `scoped_required` (the scoped rollup the requirements
/// count) and the `(missing)` entries `classify_checks` added are the
/// members; `rollup_classification.head_runs` is `classify_checks_rollup`'s
/// own run set; the bound runs are the requirements' `workflows[].runs[].id`
/// and `failed_runs`; the correlation runs follow `ci-wait:746-755` over
/// the requirements and the members named by a context. A `required
/// workflow` entry is the failed run's workflow file and conclusion, as
/// the operation names it.
fn legacy_projection(out: &Value, case: &Case) -> Projection {
    let required_state = out["required_state"].as_str().unwrap();
    if matches!(required_state, "pending" | "unreadable") {
        return Projection::Unresolved;
    }
    let requirements = &out["requirements"];
    let all_checks = legacy_all_checks(requirements);
    let scope = if required_state == "failed" {
        "failed-required"
    } else if all_checks {
        "all"
    } else {
        "required"
    };
    let projected = |entry: &Value| -> Projected {
        let name = entry["name"].as_str().unwrap();
        let state = entry["state"].as_str().unwrap();
        let link = entry["link"].as_str().filter(|l| !l.is_empty());
        let bucket = match entry["bucket"].as_str().unwrap() {
            "cancel" => "fail",
            other => match other {
                "pass" => "pass",
                "fail" => "fail",
                "pending" => "pending",
                "skipping" => "skipping",
                other => panic!("bucket {other}"),
            },
        };
        let lower = if state == "EXPECTED" {
            "expected".to_owned()
        } else {
            state.to_ascii_lowercase()
        };
        let tag = entry["_id"].as_str();
        let (name, source, state, link) = match tag {
            Some(tag) if tag.starts_with("check:") => {
                (name.to_owned(), "check-run", lower, link.map(str::to_owned))
            }
            Some(tag) if tag.starts_with("status:") => (
                name.to_owned(),
                "commit-status",
                lower,
                link.map(str::to_owned),
            ),
            Some(other) => panic!("tag {other}"),
            None => {
                assert_eq!(name, "required workflow", "{}: untagged {entry}", case.name);
                let run = case
                    .run_by_id(linked_run(link).unwrap())
                    .unwrap_or_else(|| panic!("{}: no run for {entry}", case.name));
                (
                    run.path.split('@').next().unwrap().to_owned(),
                    "workflow-run",
                    run.conclusion.clone().unwrap(),
                    link.map(str::to_owned),
                )
            }
        };
        Projected {
            name,
            source,
            state,
            bucket,
            run: linked_run(link.as_deref()),
            link,
        }
    };
    let mut scoped: Vec<Projected> = out["scoped"]
        .as_array()
        .unwrap()
        .iter()
        .map(projected)
        .collect();
    scoped.sort();
    let mut members: Vec<Projected> = out["scoped_required"]
        .as_array()
        .unwrap()
        .iter()
        .map(projected)
        .collect();
    for entry in out["classes"]["pending"].as_array().unwrap() {
        let name = entry["name"].as_str().unwrap();
        if let Some(context) = name.strip_suffix(" (missing)") {
            members.push(Projected {
                name: context.to_owned(),
                source: "required",
                state: "expected".to_owned(),
                bucket: "pending",
                link: None,
                run: None,
            });
        }
    }
    members.sort();
    let head_runs: Vec<u64> = out["rollup_classification"]["head_runs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|id| id.as_u64().unwrap())
        .collect();
    let bound_runs = legacy_bound_runs(requirements);
    Projection::Scoped {
        scope,
        scoped,
        members: members.clone(),
        head_runs,
        bound_runs: bound_runs.iter().copied().collect(),
        correlation_runs: legacy_correlation_runs(case, requirements, &members),
    }
}

/// Whether the requirements the legacy classified with count every check
/// (`requirement_set`, `ci-run-correlation.sh:104-107`).
fn legacy_all_checks(requirements: &Value) -> bool {
    requirements.is_array()
        || requirements["all_checks"] == true
        || (requirements["contexts"]
            .as_array()
            .is_some_and(Vec::is_empty)
            && requirements["workflows"]
                .as_array()
                .is_some_and(Vec::is_empty)
            && requirements["failed_runs"]
                .as_array()
                .is_none_or(Vec::is_empty))
}

/// The requirements' bound runs: `workflows[].runs[].id` and `failed_runs`.
fn legacy_bound_runs(requirements: &Value) -> BTreeSet<u64> {
    let mut bound_runs: BTreeSet<u64> = BTreeSet::new();
    if let Some(workflows) = requirements["workflows"].as_array() {
        for run in workflows.iter().flat_map(|w| w["runs"].as_array().unwrap()) {
            bound_runs.insert(run["id"].as_u64().unwrap());
        }
    }
    if let Some(failed) = requirements["failed_runs"].as_array() {
        bound_runs.extend(failed.iter().map(|id| id.as_u64().unwrap()));
    }
    bound_runs
}

/// The runs the legacy's correlation read (`ci-wait:746-755`): under a
/// required set that names anything, the bound runs and the runs of every
/// workflow a named context's member ran in; else every run.
fn legacy_correlation_runs(case: &Case, requirements: &Value, members: &[Projected]) -> Vec<u64> {
    let contexts: Vec<&str> = requirements["contexts"]
        .as_array()
        .map(|c| c.iter().map(|c| c.as_str().unwrap()).collect())
        .unwrap_or_default();
    if case.required_only && !legacy_all_checks(requirements) {
        let bound_runs = legacy_bound_runs(requirements);
        let classic_workflows: BTreeSet<u64> = members
            .iter()
            .filter(|m| contexts.contains(&m.name.as_str()))
            .filter_map(|m| m.run)
            .filter_map(|id| case.run_by_id(id))
            .map(|r| r.workflow)
            .collect();
        case.runs
            .iter()
            .filter(|r| bound_runs.contains(&r.id) || classic_workflows.contains(&r.workflow))
            .map(|r| r.id)
            .collect()
    } else {
        case.runs.iter().map(|r| r.id).collect()
    }
}

// --- the classification comparison ----------------------------------------------------

/// What one side concluded: the verdict word, the pending cause key, and
/// the classified members by class as (name, state), each list sorted.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Conclusion {
    verdict: String,
    cause: Option<String>,
    classes: Option<Classes>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct Classes {
    pending: Vec<(String, String)>,
    failed: Vec<(String, String)>,
    passed: Vec<(String, String)>,
}

impl Classes {
    fn sorted(mut self) -> Classes {
        self.pending.sort();
        self.failed.sort();
        self.passed.sort();
        self
    }
}

/// The operation's judgement as a conclusion: a final verdict's word,
/// `pending` with its key; the reported members fall into classes by
/// bucket, a skipping member counted as passed under `required_only` and
/// dropped otherwise, as the legacy classified. The unresolved required
/// definition the operation names by path takes the legacy's one word for
/// it, `required workflow` (`ci-wait:904`), which named no definition.
fn op_conclusion(
    judgement: &Judgement,
    required_only: bool,
    unresolved_workflow: Option<&str>,
) -> Conclusion {
    let (verdict, cause, checks) = match judgement {
        Judgement::Final {
            verdict, checks, ..
        } => (verdict.word().to_owned(), None, checks),
        Judgement::Pending { reason, checks } => (
            "pending".to_owned(),
            Some(reason.split(' ').next().unwrap().to_owned()),
            checks,
        ),
    };
    let mut classes = Classes::default();
    for check in checks {
        let name = if check.source == Source::Required
            && Some(check.name.as_str()) == unresolved_workflow
        {
            "required workflow".to_owned()
        } else {
            check.name.clone()
        };
        let member = (name, check.state.clone());
        match check.bucket {
            Bucket::Pending => classes.pending.push(member),
            Bucket::Fail => classes.failed.push(member),
            Bucket::Pass => classes.passed.push(member),
            Bucket::Skipping if required_only => classes.passed.push(member),
            Bucket::Skipping => {}
        }
    }
    Conclusion {
        verdict,
        cause,
        classes: Some(classes.sorted()),
    }
}

/// The oracle's output as a conclusion, through one stated mapping:
///
/// | Legacy | Operation |
/// |---|---|
/// | `complete`, exit 0 | `pass` |
/// | `complete`, exit 1 | `fail` |
/// | a poll (the deadline's `timeout`, verdict `pending`) | `pending` |
/// | `actions-read-failed` or `actions-response-invalid` (`unavailable`) | `unreadable` |
/// | `checks-failed`, exit 1 (`gh pr checks` failed, `ci-wait:860-863`; `outcome: error`, read by `legacy_reading` before this mapping) | the operation's refusal, or its verdict compared with the legacy under the graph-answers correction (decision 119 (2)) |
/// | the required set `pending` or `unreadable` | key `checks-pending`; the one class is the pending `required workflow` placeholder (`ci-wait:904`) |
/// | classification pending | key `checks-pending` |
/// | failures, correlation `active` | key `failed-run-active` |
/// | a green rollup, correlation not `settled` | key `actions-run-active` |
/// | no counted success | key `skipped-only` with a counted skipped member, else `checks-superseded` |
/// | `<context> (missing)`, `EXPECTED` | (`<context>`, `expected`) |
/// | `current-head Actions`, `EXPECTED` | no member; the key carries it |
/// | `required workflow`, `FAILURE`, linking run N | (N's file, N's conclusion) |
/// | `required workflow`, `EXPECTED`, no link | (`required workflow`, `expected`): the operation's unresolved definition under the legacy's word |
/// | `Actions run N`, a conclusion | (N's file, the conclusion lower-cased) |
/// | any other `EXPECTED` | `expected` |
/// | any other state word | lower-cased |
/// | bucket `cancel` | `fail` (the classes carry it as failed) |
fn oracle_conclusion(out: &Value, case: &Case) -> Conclusion {
    let outcome = out["outcome"].as_str().unwrap();
    let exit = out["exit"].as_i64().unwrap();
    let required_state = out["required_state"].as_str().unwrap();
    let count = |field: &str| out[field].as_u64().unwrap_or(0);
    let supersede: Vec<&str> = out["supersede"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap())
        .collect();
    let required_unclassified = matches!(required_state, "pending" | "unreadable");
    let (verdict, cause) = match (outcome, exit) {
        ("unavailable", _) => ("unavailable".to_owned(), None),
        ("complete", 0) => ("pass".to_owned(), None),
        ("complete", 1) => ("fail".to_owned(), None),
        ("pending", _) => {
            let key = if required_unclassified || count("pending") > 0 {
                "checks-pending"
            } else if count("failed") > 0 && supersede.first() == Some(&"active") {
                "failed-run-active"
            } else if count("passed") > 0 {
                "actions-run-active"
            } else if out["scoped_required"]
                .as_array()
                .unwrap()
                .iter()
                .any(|m| m["bucket"] == "skipping")
            {
                "skipped-only"
            } else {
                "checks-superseded"
            };
            ("pending".to_owned(), Some(key.to_owned()))
        }
        other => panic!("oracle outcome {other:?}: {out}"),
    };
    let class = |field: &str| -> Vec<(String, String)> {
        out["classes"][field]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|entry| legacy_member(case, entry))
            .collect()
    };
    Conclusion {
        verdict,
        cause,
        classes: Some(
            Classes {
                pending: class("pending"),
                failed: class("failed"),
                passed: class("passed"),
            }
            .sorted(),
        ),
    }
}

/// One classified legacy entry as (name, state), under the mapping
/// `oracle_conclusion` states; `None` for the `current-head Actions`
/// placeholder the key carries.
fn legacy_member(case: &Case, entry: &Value) -> Option<(String, String)> {
    let name = entry["name"].as_str().unwrap();
    let state = entry["state"].as_str().unwrap();
    let file_of = |run: &CaseRun| run.path.split('@').next().unwrap().to_owned();
    let linked = || {
        linked_run(entry["link"].as_str())
            .and_then(|id| case.run_by_id(id))
            .unwrap_or_else(|| panic!("no run for {entry}"))
    };
    if name == "current-head Actions" {
        return None;
    }
    if let Some(context) = name.strip_suffix(" (missing)") {
        return Some((context.to_owned(), "expected".to_owned()));
    }
    if name == "required workflow" {
        if state == "EXPECTED" {
            return Some((name.to_owned(), "expected".to_owned()));
        }
        let run = linked();
        return Some((file_of(run), run.conclusion.clone().unwrap()));
    }
    if let Some(id) = name.strip_prefix("Actions run ") {
        let run = case.run_by_id(id.parse().unwrap()).unwrap();
        return Some((file_of(run), state.to_ascii_lowercase()));
    }
    let state = if state == "EXPECTED" {
        "expected".to_owned()
    } else {
        state.to_ascii_lowercase()
    };
    Some((name.to_owned(), state))
}

// --- the one named correction (decision 112 (2)) --------------------------------------

/// A classified legacy entry's association, read from the case by the rule
/// decisions 112 (2) and 114 (2) state, independently of the operation: the
/// run the link names, held by the case or not, and the suite's run for a
/// check as GitHub's graph identifies it. `None` for an entry no case
/// object carries (the failed-required placeholder, a run of the case).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaseAssociation {
    Run(u64),
    External,
    Unresolved { linked: Option<u64> },
}

/// A check's suite's run as the documented graph identifies it: none
/// (`CheckSuite.workflowRun` null), identified by any documented identity
/// (REST, where the check's `check_suite.id` and the run's `check_suite_id`
/// are both carried; or the GraphQL `WorkflowRun.databaseId`), or present
/// and unidentified (the GraphQL id null and no REST join).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaseSuiteRun {
    NoRun,
    Run(u64),
    Unidentified,
}

fn case_association(case: &Case, entry: &Value) -> Option<CaseAssociation> {
    let held = |id: u64| case.run_by_id(id).is_some();
    let linked = linked_run(entry["link"].as_str());
    let tag = entry["_id"].as_str()?;
    let suite_run = match tag.strip_prefix("check:") {
        Some(id) => {
            let check = case
                .checks
                .iter()
                .find(|c| c.id == id.parse::<u64>().unwrap())?;
            match case.suite_run(check.suite) {
                None => CaseSuiteRun::NoRun,
                Some(run) if (check.rest_suite && run.rest_suite) || run.graphql_id => {
                    CaseSuiteRun::Run(run.id)
                }
                Some(_) => CaseSuiteRun::Unidentified,
            }
        }
        None => CaseSuiteRun::NoRun,
    };
    Some(match (linked, suite_run) {
        (None, CaseSuiteRun::NoRun) => CaseAssociation::External,
        (Some(run), CaseSuiteRun::NoRun) if held(run) => CaseAssociation::Run(run),
        (Some(run), CaseSuiteRun::Run(of_suite)) if held(run) && of_suite == run => {
            CaseAssociation::Run(run)
        }
        (linked, CaseSuiteRun::NoRun | CaseSuiteRun::Run(_) | CaseSuiteRun::Unidentified) => {
            CaseAssociation::Unresolved {
                linked: linked.filter(|run| held(*run)),
            }
        }
    })
}

/// Decision 112 (2) applied to the legacy's conclusion. The legacy read a
/// settled failure it could not attribute as terminal: a link naming no
/// run skipped the correlation (`ci-wait:1057`), a run its correlation's
/// run set lacked was `terminal` (`:776`, `:779`). The operation holds a
/// failure whose association is unresolved `active` while a substantive
/// run among the runs the correlation reads is unfinished, as the legacy
/// held every attributable failure then (`:781`), relabelling the failures
/// `expected` (`:1069`). So the two differ exactly when a substantive run
/// is in flight, no failed member is external or attributed to a run
/// outside that set (either keeps the set terminal on both sides), and some
/// failed member's association is unresolved with no run in that set. The
/// result is the corrected conclusion and whether the correction applied;
/// every other legacy result stands.
fn corrected_by_112_2(case: &Case, out: &Value, legacy: &Conclusion) -> (Conclusion, bool) {
    let settled_failure = out["outcome"] == "complete"
        && out["exit"] == 1
        && out["pending"].as_u64() == Some(0)
        && out["failed"].as_u64().is_some_and(|n| n > 0);
    let Some(classes) = &legacy.classes else {
        return (legacy.clone(), false);
    };
    if !settled_failure {
        return (legacy.clone(), false);
    }
    let members: Vec<Projected> = match legacy_projection(out, case) {
        Projection::Scoped { members, .. } => members,
        Projection::Unresolved => Vec::new(),
    };
    let correlation_runs = legacy_correlation_runs(case, &out["requirements"], &members);
    let head_in_flight = case
        .runs
        .iter()
        .filter(|r| correlation_runs.contains(&r.id))
        .any(|r| SUBSTANTIVE_EVENTS.contains(&r.event.as_str()) && r.status != "completed");
    let associations: Vec<Option<CaseAssociation>> = out["classes"]["failed"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| case_association(case, entry))
        .collect();
    let in_set = |run: u64| correlation_runs.contains(&run);
    let every_member_holds = associations.iter().all(|a| match a {
        Some(CaseAssociation::Run(run)) => in_set(*run),
        Some(CaseAssociation::Unresolved { .. }) => true,
        Some(CaseAssociation::External) | None => false,
    });
    let some_member_differs = associations.iter().any(|a| {
        matches!(a, Some(CaseAssociation::Unresolved { linked }) if !linked.is_some_and(in_set))
    });
    if !(head_in_flight && every_member_holds && some_member_differs) {
        return (legacy.clone(), false);
    }
    let mut pending = classes.pending.clone();
    pending.extend(
        classes
            .failed
            .iter()
            .map(|(name, _)| (name.clone(), "expected".to_owned())),
    );
    (
        Conclusion {
            verdict: "pending".to_owned(),
            cause: Some("failed-run-active".to_owned()),
            classes: Some(
                Classes {
                    pending,
                    failed: Vec::new(),
                    passed: classes.passed.clone(),
                }
                .sorted(),
            ),
        },
        true,
    )
}

/// The legacy branch the oracle's facts show it took, for the corpus's
/// coverage floor.
fn oracle_branch(out: &Value) -> &'static str {
    let outcome = out["outcome"].as_str().unwrap();
    let exit = out["exit"].as_i64().unwrap();
    let required_state = out["required_state"].as_str().unwrap();
    let count = |field: &str| out[field].as_u64().unwrap_or(0);
    let supersede: Vec<&str> = out["supersede"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap())
        .collect();
    if matches!(required_state, "pending" | "unreadable") {
        return "required-pending";
    }
    if required_state == "failed" {
        return "required-failed";
    }
    if count("pending") > 0 {
        return "checks-pending";
    }
    match (
        outcome,
        exit,
        supersede.first().copied(),
        supersede.last().copied(),
    ) {
        ("pending", _, Some("active"), _) if count("failed") > 0 => "failed-run-active",
        (_, _, Some("superseded"), _) => "superseded",
        ("complete", 1, Some("terminal"), _) if count("failed") > 0 => "terminal",
        ("complete", 1, None, _) if count("failed") > 0 => "terminal-unattributable",
        ("complete", 1, _, Some("terminal")) => "actions-terminal",
        ("complete", 0, _, Some("settled")) => "settled",
        ("complete", 0, _, None) => "required-pass",
        ("pending", _, _, _) if count("passed") > 0 => "actions-unsettled",
        ("pending", _, _, _) => "no-success",
        other => panic!("unmapped oracle facts {other:?}: {out}"),
    }
}

/// `bash` on this process's PATH, resolved here rather than by name.
fn bash() -> PathBuf {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .map(|dir| dir.join("bash"))
        .find(|candidate| candidate.is_file())
        .expect("bash on PATH")
}

/// Run the oracle over one case in `dir`, its input rendered under
/// `corrections`, its contexts in the order `tie` names.
fn oracle(case: &Case, dir: &Path, corrections: Corrections, tie: TieOrder<'_>) -> Value {
    let case_file = dir.join("case.json");
    fs::write(&case_file, case.legacy_inputs(corrections, tie).to_string()).unwrap();
    let events = dir.join("events.json");
    fs::write(&events, json!(SUBSTANTIVE_EVENTS).to_string()).unwrap();
    let out = Command::new(bash())
        .arg(fixtures().join("legacy-oracle/oracle.sh"))
        .arg(&case_file)
        .arg(&events)
        .env("TMPDIR", dir)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}: oracle exit {:?}: {}",
        case.name,
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "{}: oracle output: {e}: {}",
            case.name,
            String::from_utf8_lossy(&out.stdout)
        )
    })
}

// --- the legacy fixtures as corpus cases ---------------------------------------

/// A legacy `ci-wait` fixture beside the oracle, verbatim from
/// `skills/orch/tests/fixtures/ci-wait/` at the legacy's HEAD.
fn legacy(name: &str) -> Value {
    fixture(&format!("legacy/{name}.json"))
}

/// The run and job ids a legacy `link` names.
fn linked(link: &str) -> Option<(u64, Option<u64>)> {
    let (_, after) = link.split_once("/actions/runs/")?;
    let mut parts = after.split('/');
    let run = parts.next()?.parse().ok()?;
    let job = match (parts.next(), parts.next()) {
        (Some("job"), Some(id)) => Some(id.parse().ok()?),
        _ => None,
    };
    Some((run, job))
}

/// A legacy rollup state as a check's status and conclusion.
fn legacy_check_state(state: &str) -> (String, Option<String>) {
    match state {
        "SUCCESS" | "FAILURE" | "CANCELLED" | "SKIPPED" | "NEUTRAL" => {
            ("completed".to_owned(), Some(state.to_ascii_lowercase()))
        }
        "IN_PROGRESS" | "QUEUED" => (state.to_ascii_lowercase(), None),
        other => panic!("no check state for {other}"),
    }
}

/// The run a legacy fixture names, as a case run: the consumer's own
/// workflow file, proven at the head; a run of the required workflow is
/// proven at `WORKFLOW_SHA` in the source repository when the case
/// requires it. `outcome` is the run's status and conclusion, `times` its
/// attempt, start and update. Its suite is drawn apart from its id and
/// carried by REST.
fn fixture_run(
    id: u64,
    workflow: u64,
    event: &str,
    outcome: (&str, Option<&str>),
    times: (Option<u64>, Option<&str>, &str),
    required: bool,
) -> CaseRun {
    let path = workflow_path(workflow);
    let (status, conclusion) = outcome;
    let (attempt, started, updated) = times;
    CaseRun {
        id,
        workflow,
        display_name: Some(workflow_name(workflow)),
        source: Some(if workflow == 3 && required {
            required_source(WORKFLOW_SHA)
        } else {
            own_source(&path)
        }),
        path,
        event: event.to_owned(),
        status: status.to_owned(),
        conclusion: conclusion.map(str::to_owned),
        attempt,
        started: started.map(str::to_owned),
        updated: updated.to_owned(),
        suite: suite_of(id),
        rest_suite: true,
        graphql_id: true,
        latest: Latest::Every,
    }
}

/// A legacy `gh pr checks` rollup and, where the legacy row had one, its
/// Actions fixture, as a case. An entry with a job link and a workflow is
/// a check run in its run's suite, keeping the job id; a workflow-less
/// entry with a link is a commit status with that target; an entry with no
/// link is a check run in an external suite with a null link. The
/// fixtures carried one `link`, and the lib's own test stubbed the suite
/// read's `html_url` equal to it (HEAD
/// `skills/github/tests/ci-run-correlation.test.sh:96`), so a fixture
/// check's page is its details URL; its `completed_at`, which no fixture
/// carried, is its start once concluded. Go's zero `startedAt` is no
/// start. A row without an Actions fixture gets one run
/// per linked run id (the legacy's stub answered an empty list, which
/// cannot own a check run): completed, concluded from its jobs (red fails
/// it, all skipped skips it, else success) or in flight while a job is, a
/// `pull_request` dispatch, dated by its jobs, proven as the required
/// workflow at `WORKFLOW_SHA` when it runs it and the case requires it.
fn legacy_case(
    name: &str,
    rollup: &Value,
    actions: Option<&Value>,
    required_only: bool,
    contexts: &[&str],
    workflow_rule: bool,
) -> Case {
    let mut checks = Vec::new();
    let mut statuses = Vec::new();
    let mut runless_id = 1000;
    let mut job_workflows: BTreeMap<u64, u64> = BTreeMap::new();
    for entry in rollup.as_array().unwrap() {
        let name = entry["name"].as_str().unwrap().to_owned();
        let state = entry["state"].as_str().unwrap();
        let link = entry["link"].as_str().unwrap_or_default();
        let workflow = entry["workflow"].as_str().unwrap_or_default();
        let started = entry["startedAt"]
            .as_str()
            .filter(|s| *s != "0001-01-01T00:00:00Z")
            .map(str::to_owned);
        match linked(link) {
            Some((run, job)) if !workflow.is_empty() => {
                let id = job.unwrap_or_else(|| {
                    runless_id += 1;
                    runless_id
                });
                let workflow_id = match workflow {
                    "CI" => 1,
                    "Guard" => 2,
                    "Request" | "Required" => 3,
                    other => panic!("no workflow id for {other}"),
                };
                job_workflows.insert(run, workflow_id);
                let (status, conclusion) = legacy_check_state(state);
                let details = match job {
                    Some(_) => Link::Job(run),
                    None => Link::Url(link.to_owned()),
                };
                checks.push(CaseCheck {
                    id,
                    name,
                    status,
                    completed: conclusion.as_ref().and(started.clone()),
                    conclusion,
                    suite: suite_of(run),
                    rest_suite: true,
                    page: details.clone(),
                    details,
                    started,
                });
            }
            Some((run, job)) => statuses.push(CaseStatus {
                context: name,
                state: match state {
                    "SUCCESS" => "success",
                    "FAILURE" => "failure",
                    "EXPECTED" | "PENDING" => "pending",
                    other => panic!("no status state for {other}"),
                }
                .to_owned(),
                target: match job {
                    Some(job) => Target::Job(run, job),
                    None => Target::Run(run),
                },
            }),
            None => {
                // Each in an external suite of its own: the legacy's
                // rollup carried both entries, which one suite's latest
                // selection would have reduced to one by name.
                runless_id += 1;
                let (status, conclusion) = legacy_check_state(state);
                let details = if link.is_empty() {
                    Link::None
                } else {
                    Link::Url(link.to_owned())
                };
                checks.push(CaseCheck {
                    id: runless_id,
                    name,
                    status,
                    completed: conclusion.as_ref().and(started.clone()),
                    conclusion,
                    suite: EXTERNAL_SUITE + runless_id,
                    rest_suite: true,
                    page: details.clone(),
                    details,
                    started,
                });
            }
        }
    }
    let runs: Vec<CaseRun> = match actions {
        Some(actions) => actions["workflow_runs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| {
                fixture_run(
                    r["id"].as_u64().unwrap(),
                    r["workflow_id"].as_u64().unwrap(),
                    r["event"].as_str().unwrap(),
                    (r["status"].as_str().unwrap(), r["conclusion"].as_str()),
                    (
                        r["run_attempt"].as_u64(),
                        r["run_started_at"].as_str(),
                        r["updated_at"]
                            .as_str()
                            .or_else(|| r["created_at"].as_str())
                            .unwrap(),
                    ),
                    false,
                )
            })
            .collect(),
        None => job_workflows
            .iter()
            .map(|(&run, &workflow)| {
                let jobs: Vec<&CaseCheck> =
                    checks.iter().filter(|c| c.suite == suite_of(run)).collect();
                let words: Vec<&str> = jobs
                    .iter()
                    .map(|c| c.conclusion.as_deref().unwrap_or(&c.status))
                    .collect();
                let (status, conclusion) =
                    if words.iter().any(|w| matches!(*w, "in_progress" | "queued")) {
                        ("in_progress", None)
                    } else if words
                        .iter()
                        .any(|w| matches!(*w, "failure" | "cancelled" | "neutral"))
                    {
                        ("completed", Some("failure"))
                    } else if words.iter().all(|w| *w == "skipped") {
                        ("completed", Some("skipped"))
                    } else {
                        ("completed", Some("success"))
                    };
                let starts: Vec<&str> = jobs.iter().filter_map(|c| c.started.as_deref()).collect();
                let started = starts.iter().min().copied();
                let updated = starts
                    .iter()
                    .max()
                    .copied()
                    .unwrap_or("2026-07-26T12:00:00Z");
                fixture_run(
                    run,
                    workflow,
                    "pull_request",
                    (status, conclusion),
                    (None, started, updated),
                    workflow_rule,
                )
            })
            .collect(),
    };
    Case {
        name: name.to_owned(),
        required_only,
        contexts: contexts.iter().map(|c| (*c).to_owned()).collect(),
        definitions: if workflow_rule {
            vec![required_definition()]
        } else {
            Vec::new()
        },
        sources: sources(),
        workflows: workflows_of(&runs),
        runs,
        checks,
        statuses,
        union: None,
        graph: Graph::Answers,
        generated: false,
        holds: &[],
    }
}

/// The legacy's `runs-request-only-active` fixture with its one run's
/// status, conclusion and event rewritten, as `ci_wait.sh` derived its
/// queued, completed, push and manual variants with jq.
fn request_only_run(status: &str, conclusion: Option<&str>, event: &str) -> Value {
    let mut fixture = legacy("runs-request-only-active");
    let run = &mut fixture["workflow_runs"][0];
    run["status"] = json!(status);
    run["conclusion"] = conclusion.map_or(Value::Null, |c| json!(c));
    run["event"] = json!(event);
    fixture
}

/// A copy of the fixture's first run with the next id, `workflow_offset`
/// added to its workflow and `conclusion`, appended, as the legacy's
/// `runs-request-newer-*` derivations.
fn with_newer_run(mut fixture: Value, workflow_offset: u64, conclusion: &str) -> Value {
    let mut newer = fixture["workflow_runs"][0].clone();
    newer["id"] = json!(newer["id"].as_u64().unwrap() + 1);
    newer["workflow_id"] = json!(newer["workflow_id"].as_u64().unwrap() + workflow_offset);
    newer["conclusion"] = json!(conclusion);
    fixture["workflow_runs"].as_array_mut().unwrap().push(newer);
    fixture
}

/// Every legacy fixture as a case: the `ci_wait.sh` rows over the fixture
/// files and the stub's inline rollups, and the `ci-run-correlation.test.sh`
/// heads with the requirement shapes this operation can express (a bound
/// or failed required workflow; not the lib's `unreadable` evidence or its
/// `all_checks` beside a bound run, which arise only from an unreadable
/// protection read this operation refuses).
fn legacy_cases() -> Vec<Case> {
    const R: &str = "https://x/actions/runs";
    let all = |name: &str, rollup: Value, actions: Option<Value>| {
        legacy_case(name, &rollup, actions.as_ref(), false, &[], false)
    };
    let required = |name: &str, rollup: Value, actions: Option<Value>, context: &str| {
        legacy_case(name, &rollup, actions.as_ref(), true, &[context], false)
    };
    let failed_request = request_only_run("completed", Some("failure"), "pull_request");
    let superseded_pending = json!([
        {"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},
        {"name":"Linux Integration","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/102","workflow":"CI","startedAt":"2026-07-10T10:00:01Z"},
        {"name":"macOS","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/103","workflow":"CI","startedAt":"2026-07-10T10:00:02Z"},
        {"name":"Windows","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/104","workflow":"CI","startedAt":"2026-07-10T10:00:03Z"},
        {"name":"Loom","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/105","workflow":"CI","startedAt":"2026-07-10T10:00:04Z"},
        {"name":"Bench (iai-callgrind)","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/106","workflow":"CI","startedAt":"2026-07-10T10:00:05Z"},
        {"name":"Changes","state":"IN_PROGRESS","bucket":"pending","link":"https://github.com/owner/repo/actions/runs/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},
        {"name":"License Key Guard","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}
    ]);
    let superseded_replaced = json!([
        {"name":"Lint","state":"CANCELLED","bucket":"cancel","link":"https://github.com/owner/repo/actions/runs/29098545030/job/101","workflow":"CI","startedAt":"2026-07-10T10:00:00Z"},
        {"name":"Lint","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/201","workflow":"CI","startedAt":"2026-07-10T11:00:00Z"},
        {"name":"Changes","state":"SUCCESS","bucket":"pass","link":"https://github.com/owner/repo/actions/runs/29099680623/job/202","workflow":"CI","startedAt":"2026-07-10T11:00:01Z"}
    ]);
    let required_build_optional_docs = json!([
        {"name":"build","state":"SUCCESS","bucket":"pass"},
        {"name":"docs","state":"IN_PROGRESS","bucket":"pending"}
    ]);
    let mut cases = vec![
        all(
            "ci_wait: a pass is complete with its checks listed",
            json!([{"name":"build","state":"SUCCESS"}]),
            None,
        ),
        all(
            "ci_wait: a settled failing check is a complete fail",
            json!([{"name":"build","state":"FAILURE"}]),
            None,
        ),
        all(
            "ci_wait: a superseded run's cancelled jobs are dropped, the current classifier stays pending",
            superseded_pending,
            None,
        ),
        all(
            "ci_wait: a job the newer run recreated replaces the cancelled one by name",
            superseded_replaced,
            None,
        ),
        all(
            "ci_wait: an active approved run keeps the stale failure pending",
            legacy("stale-preapproval-active-approved"),
            None,
        ),
        all(
            "ci_wait: no fresh substantive run: the pre-approval failure is terminal",
            legacy("stale-preapproval-no-fresh-run"),
            None,
        ),
        all(
            "ci_wait: a failed approved run fails at once",
            legacy("stale-preapproval-fresh-failed"),
            None,
        ),
        all(
            "ci_wait: approved jobs passed but the aggregate lags",
            legacy("stale-preapproval-status-lag"),
            None,
        ),
        all(
            "ci_wait: the replacement status published against the approved run passes",
            legacy("approved-status-replaced"),
            None,
        ),
        all(
            "ci_wait: an unchanged request-only rollup stays pending",
            legacy("request-only-checks"),
            Some(legacy("runs-request-only-active")),
        ),
        all(
            "ci_wait: a queued substantive run holds the request-only rollup",
            legacy("request-only-checks"),
            Some(request_only_run("queued", None, "pull_request")),
        ),
        all(
            "ci_wait: a queued push run holds the request-only rollup",
            legacy("request-only-checks"),
            Some(request_only_run("queued", None, "push")),
        ),
        all(
            "ci_wait: an in-progress push run holds the request-only rollup",
            legacy("request-only-checks"),
            Some(request_only_run("in_progress", None, "push")),
        ),
        all(
            "ci_wait: a queued manual run holds the request-only rollup",
            legacy("request-only-checks"),
            Some(request_only_run("queued", None, "workflow_dispatch")),
        ),
        all(
            "ci_wait: an in-progress manual run holds the request-only rollup",
            legacy("request-only-checks"),
            Some(request_only_run("in_progress", None, "workflow_dispatch")),
        ),
        all(
            "ci_wait: a completed manual run releases the request-only rollup",
            legacy("request-only-checks"),
            Some(request_only_run(
                "completed",
                Some("success"),
                "workflow_dispatch",
            )),
        ),
        all(
            "ci_wait: completed substantive CI releases the request-only rollup",
            legacy("request-only-checks"),
            Some(request_only_run(
                "completed",
                Some("success"),
                "pull_request",
            )),
        ),
        required(
            "ci_wait: a known required build passes while optional docs is active",
            required_build_optional_docs,
            Some(legacy("runs-request-only-active")),
            "build",
        ),
        required(
            "ci_wait: a missing required build stays pending with only the request check visible",
            legacy("request-only-checks"),
            Some(legacy("runs-request-only-active")),
            "build",
        ),
        all(
            "ci_wait: a failed latest run fails even when the rollup carries only the review request",
            legacy("request-only-checks"),
            Some(failed_request.clone()),
        ),
        all(
            "ci_wait: a newer successful run replaces the earlier failure",
            legacy("request-only-checks"),
            Some(with_newer_run(failed_request.clone(), 0, "success")),
        ),
        all(
            "ci_wait: a newer successful workflow cannot erase another workflow's failure",
            legacy("request-only-checks"),
            Some(with_newer_run(failed_request.clone(), 1, "success")),
        ),
        all(
            "ci_wait: a later skipped dispatch cannot erase a substantive failure",
            legacy("request-only-checks"),
            Some(with_newer_run(failed_request, 0, "skipped")),
        ),
        all(
            "ci_wait: a successful rerun with the older run id replaces the failed newer dispatch",
            legacy("request-only-checks"),
            Some(legacy("runs-rerun-attempt-success")),
        ),
        all(
            "ci_wait: a failed latest rerun stays terminal",
            legacy("request-only-checks"),
            Some(legacy("runs-rerun-attempt-failure")),
        ),
        all(
            "ci_wait: an active newer sibling keeps the cancelled run's failure pending",
            legacy("cancelled-review-run-checks"),
            Some(legacy("runs-newer-sibling-active")),
        ),
        required(
            "ci_wait: a required failure still waits for active replacement work",
            legacy("cancelled-review-run-checks"),
            Some(legacy("runs-newer-sibling-active")),
            "CI Required",
        ),
        all(
            "ci_wait: a successful newer sibling discards the frozen failures and passes",
            legacy("cancelled-review-run-status-replaced"),
            Some(legacy("runs-newer-sibling-success")),
        ),
        all(
            "ci_wait: a failed newer sibling is terminal at once",
            legacy("cancelled-review-run-checks"),
            Some(legacy("runs-newer-sibling-failure")),
        ),
        all(
            "ci_wait: a cancelled run with no newer sibling fails closed",
            legacy("cancelled-review-run-checks"),
            Some(legacy("runs-cancelled-alone")),
        ),
        all(
            "ci_wait: an in-flight attempt of an older run keeps the cancelled failure pending",
            legacy("rerun-attempt-checks"),
            Some(legacy("runs-rerun-attempt-active")),
        ),
        all(
            "ci_wait: a successful attempt supersedes through its fresher updated_at",
            legacy("rerun-attempt-status-replaced"),
            Some(legacy("runs-rerun-attempt-success")),
        ),
    ];
    // The lib's heads (`checks_of`), verbatim.
    let job = |name: &str, state: &str, started: &str, run: u64, job: u64| json!({"name": name, "state": state, "workflow": "CI", "startedAt": started, "link": format!("{R}/{run}/job/{job}")});
    let runless = |name: &str, state: &str, started: &str| json!({"name": name, "state": state, "workflow": "", "startedAt": started, "link": ""});
    let aggregate = |name: &str, state: &str, started: Option<&str>, run: u64| {
        let mut entry =
            json!({"name": name, "state": state, "workflow": "", "link": format!("{R}/{run}")});
        if let Some(started) = started {
            entry["startedAt"] = json!(started);
        }
        entry
    };
    let request = |state: &str, started: &str, run: u64, job: u64| json!({"name": "request", "state": state, "workflow": "Request", "startedAt": started, "link": format!("{R}/{run}/job/{job}")});
    let lib = |name: &str, rollup: Value| all(&format!("lib: {name}"), rollup, None);
    cases.extend([
        lib("later-noop", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), job("build", "SKIPPED", "2026-07-26T10:06:00Z", 200, 2)])),
        lib("run-less", json!([runless("external", "SUCCESS", "2026-07-26T10:00:00Z"), runless("external", "FAILURE", "2026-07-26T10:09:00Z")])),
        lib("two-workflows", json!([job("a", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), {"name":"b","state":"SUCCESS","workflow":"Guard","startedAt":"2026-07-26T10:00:00Z","link": format!("{R}/50/job/2")}])),
        lib("rerun", json!([
            job("build", "SUCCESS", "2026-07-26T12:22:11Z", 30201726860, 1),
            job("CI Gate Publisher", "SUCCESS", "2026-07-26T12:23:26Z", 30201726860, 2),
            aggregate("CI Required", "SUCCESS", Some("2026-07-26T12:28:48Z"), 30201726860),
            job("CI Gate Publisher", "FAILURE", "2026-07-26T12:21:56Z", 30201902682, 9),
            job("build", "CANCELLED", "2026-07-26T12:21:45Z", 30201902682, 10),
        ])),
        lib("queued-newer", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), job("build", "QUEUED", "0001-01-01T00:00:00Z", 200, 2)])),
        lib("pending-earlier", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), job("build", "IN_PROGRESS", "2026-07-26T09:00:00Z", 200, 2)])),
        lib("undated-newer", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), job("build", "SUCCESS", "0001-01-01T00:00:00Z", 200, 2)])),
        lib("later-failure", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), job("build", "FAILURE", "2026-07-26T10:30:00Z", 200, 2)])),
        lib("stale-aggregate", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), aggregate("CI Required", "SUCCESS", Some("2026-07-26T10:01:00Z"), 100), job("build", "SUCCESS", "2026-07-26T10:30:00Z", 200, 2)])),
        lib("stale-aggregate-failed", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), aggregate("CI Required", "SUCCESS", Some("2026-07-26T10:01:00Z"), 100), job("build", "FAILURE", "2026-07-26T10:30:00Z", 200, 2)])),
        lib("status-run", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), aggregate("CI Required", "FAILURE", None, 200)])),
        lib("all-skipped", json!([job("build", "SKIPPED", "2026-07-26T10:00:00Z", 100, 1)])),
        lib("status-job-link", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), job("build", "SUCCESS", "2026-07-26T10:30:00Z", 200, 2), {"name":"CI Required","state":"SUCCESS","workflow":"","startedAt":"2026-07-26T10:01:00Z","link": format!("{R}/100/job/9")}])),
        lib("runless-beside-job", json!([job("build", "SUCCESS", "2026-07-26T10:00:00Z", 100, 1), runless("external", "SUCCESS", "2026-07-26T10:05:00Z")])),
    ]);
    let two_runs = |later_state: &str, bound_state: &str| {
        json!([
            request(bound_state, "2026-07-26T10:00:00Z", 200, 2),
            request(later_state, "2026-07-26T10:05:00Z", 100, 1)
        ])
    };
    let bound = |name: &str, rollup: Value| {
        legacy_case(&format!("lib: {name}"), &rollup, None, true, &[], true)
    };
    cases.extend([
        bound("two-runs with ready-200", two_runs("SUCCESS", "SUCCESS")),
        bound(
            "two-runs-bound-failed with failed-200",
            two_runs("SUCCESS", "FAILURE"),
        ),
        bound("two-runs-bound-status with ready-200", {
            let mut rollup = two_runs("SUCCESS", "SUCCESS");
            rollup
                .as_array_mut()
                .unwrap()
                .push(aggregate("CI Required", "SUCCESS", None, 200));
            rollup
        }),
    ]);
    cases
}

// --- the named cases the reviews executed ---------------------------------------------

/// A completed run of `workflow` dispatched by `event`, proven as the
/// consumer's own file, or as the required workflow at `WORKFLOW_SHA` for
/// workflow 3.
fn named_run(id: u64, workflow: u64, event: &str, conclusion: &str, started: &str) -> CaseRun {
    fixture_run(
        id,
        workflow,
        event,
        ("completed", Some(conclusion)),
        (Some(1), Some(started), started),
        true,
    )
}

/// A completed check run in the suite of run `run`, both its URLs its job
/// page, completed when it started.
fn named_check(id: u64, name: &str, conclusion: &str, run: u64, started: &str) -> CaseCheck {
    CaseCheck {
        id,
        name: name.to_owned(),
        status: "completed".to_owned(),
        conclusion: Some(conclusion.to_owned()),
        suite: suite_of(run),
        rest_suite: true,
        details: Link::Job(run),
        page: Link::Job(run),
        started: Some(started.to_owned()),
        completed: Some(started.to_owned()),
    }
}

/// A completed check run in an external suite, both its URLs its check
/// page.
fn external_check(id: u64, name: &str, conclusion: &str, started: &str) -> CaseCheck {
    CaseCheck {
        suite: EXTERNAL_SUITE,
        details: Link::Url(check_page_link(id)),
        page: Link::Url(check_page_link(id)),
        ..named_check(id, name, conclusion, 0, started)
    }
}

fn named_base(name: &str) -> Case {
    Case {
        name: name.to_owned(),
        required_only: false,
        contexts: vec![],
        definitions: vec![],
        sources: sources(),
        workflows: vec![],
        runs: vec![],
        checks: vec![],
        statuses: vec![],
        union: None,
        graph: Graph::Answers,
        generated: false,
        holds: &[],
    }
}

/// A fixed case with the workflows its runs name, unless it states its own.
fn with_workflows(mut case: Case) -> Case {
    if case.workflows.is_empty() {
        case.workflows = workflows_of(&case.runs);
    }
    case
}

/// R-U4e7 H2's four counterexamples, the stale aggregate under every
/// check, and decision 107 (4)'s push supersession.
fn named_cases() -> Vec<Case> {
    let t = |h: u32, m: u32| format!("2026-07-26T{h:02}:{m:02}:00Z");
    let run = |id, workflow, event, conclusion, started: String| {
        named_run(id, workflow, event, conclusion, &started)
    };
    let check = |id, name, conclusion, run, started: String| {
        named_check(id, name, conclusion, run, &started)
    };
    let aggregate = |context: &str, state: &str, run: u64| CaseStatus {
        context: context.to_owned(),
        state: state.to_owned(),
        target: Target::Run(run),
    };
    [
        Case {
            required_only: true,
            contexts: vec!["CI Required".to_owned()],
            runs: vec![
                run(100, 1, "push", "success", t(10, 0)),
                run(200, 1, "push", "success", t(10, 30)),
            ],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 0)),
                check(2001, "build", "success", 200, t(10, 30)),
            ],
            statuses: vec![aggregate("CI Required", "success", 100)],
            ..named_base(
                "H2: a stale successful aggregate under required contexts is held expected",
            )
        },
        Case {
            runs: vec![
                run(100, 1, "push", "success", t(10, 0)),
                run(200, 1, "push", "success", t(10, 30)),
            ],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 0)),
                check(2001, "build", "success", 200, t(10, 30)),
            ],
            statuses: vec![aggregate("CI Required", "success", 100)],
            ..named_base("H2: a stale successful aggregate under every check is held expected")
        },
        Case {
            runs: vec![
                run(100, 1, "push", "cancelled", t(10, 0)),
                run(200, 1, "push", "success", t(10, 30)),
            ],
            checks: vec![
                check(1001, "Lint", "cancelled", 100, t(10, 0)),
                check(2001, "Lint", "success", 200, t(10, 30)),
                check(2002, "Changes", "success", 200, t(10, 31)),
            ],
            ..named_base(
                "H2: a recreated job on a newer successful push run replaces the old failure",
            )
        },
        Case {
            required_only: true,
            definitions: vec![required_definition()],
            runs: vec![run(300, 3, "push", "success", t(10, 0))],
            checks: vec![external_check(1, "build", "success", &t(10, 0))],
            ..named_base("H2: a bound successful run with no checks stays expected")
        },
        Case {
            required_only: true,
            definitions: vec![required_definition()],
            runs: vec![run(300, 3, "push", "success", t(10, 0))],
            checks: vec![check(3001, "request", "failure", 300, t(10, 0))],
            ..named_base("H2: a bound successful run with a failed own check fails")
        },
        Case {
            runs: vec![
                run(700, 1, "push", "failure", t(10, 0)),
                run(701, 1, "push", "success", t(10, 30)),
            ],
            checks: vec![check(7011, "lint", "success", 701, t(10, 30))],
            statuses: vec![aggregate("CI Required", "failure", 700)],
            ..named_base(
                "107 (4): a newer successful push run supersedes an earlier failure of the same workflow",
            )
        },
    ]
    .into_iter()
    .map(with_workflows)
    .collect()
}

/// The reviewer witnesses (decisions 112 (5), 114 (5), 117 and 119):
/// R-U4e8 H1's three and H2's three, R-U4e9 H1's three and H2's two,
/// R-U4e10 H1's one, H2's four and M1's one, R-U4e11 (opus) H1, M1 and M2,
/// R-U4e11-codex items 1 to 4, R-U4e12-codex H1 and M1's two and R-U4e12
/// (opus) M1, each with the legacy reading the review recorded; plus the
/// two the controls of U4e9 mutate against: a consumer
/// workflow at the required path, and two successful runs of one workflow
/// whose selected identity the classification cannot tell apart.
fn witness_cases() -> Vec<Case> {
    let t = |h: u32, m: u32| format!("2026-07-26T{h:02}:{m:02}:00Z");
    let run = |id, workflow, conclusion, started: String| {
        named_run(id, workflow, "push", conclusion, &started)
    };
    let check = |id, name, conclusion, run, started: String| {
        named_check(id, name, conclusion, run, &started)
    };
    let required = |name: &str| Case {
        required_only: true,
        definitions: vec![required_definition()],
        ..named_base(name)
    };
    let in_flight = |id, workflow, started: String| CaseRun {
        status: "in_progress".to_owned(),
        conclusion: None,
        ..run(id, workflow, "success", started)
    };
    [
        // R-U4e8 H1.
        Case {
            definitions: vec![Definition {
                repository_id: OTHER_REPO_ID,
                ..required_definition()
            }],
            runs: vec![run(300, 3, "success", t(10, 0))],
            checks: vec![check(3001, "request", "success", 300, t(10, 0))],
            ..required(
                "R-U4e8 H1: the rule names repository 8, the proof repository 7, at the same path and sha",
            )
        },
        Case {
            runs: vec![CaseRun {
                path: ".github/workflows/caller.yml".to_owned(),
                source: Some(required_source(WORKFLOW_SHA)),
                ..run(300, 1, "success", t(10, 0))
            }],
            checks: vec![check(3001, "request", "success", 300, t(10, 0))],
            ..required(
                "R-U4e8 H1: a caller workflow executing the required source is not the required workflow's run",
            )
        },
        Case {
            runs: vec![CaseRun {
                rest_suite: false,
                ..run(300, 3, "failure", t(10, 0))
            }],
            checks: vec![external_check(1, "build", "success", &t(10, 0))],
            ..required(
                "R-U4e8 H1: a failed bound run without a check suite is unresolved, not failed",
            )
        },
        // R-U4e10 H1: a present run GitHub does not identify is not no run.
        Case {
            runs: vec![CaseRun {
                graphql_id: false,
                ..in_flight(100, 1, t(10, 0))
            }],
            checks: vec![CaseCheck {
                rest_suite: false,
                details: Link::None,
                page: Link::None,
                ..check(1001, "build", "failure", 100, t(10, 0))
            }],
            ..named_base(
                "R-U4e10 H1: a failed check with a null suite and null URLs, its node's run unidentified, is held while a push run is in flight",
            )
        },
        // R-U4e10 H2: the two URLs apart, gh's deduplication, the workflow
        // the list lacks.
        Case {
            runs: vec![in_flight(100, 1, t(10, 0))],
            checks: vec![CaseCheck {
                details: Link::Job(100),
                page: Link::Url(check_page_link(1)),
                ..external_check(1, "build", "failure", &t(10, 0))
            }],
            ..named_base(
                "R-U4e10 H2: an external failed check whose details URL names the active run while its page is its check page is held",
            )
        },
        Case {
            runs: vec![run(300, 3, "success", t(10, 0))],
            checks: vec![CaseCheck {
                details: Link::Url(check_page_link(3001)),
                page: Link::Job(300),
                ..check(3001, "request", "success", 300, t(10, 0))
            }],
            ..required(
                "R-U4e10 H2: a bound job whose details URL is not its page is missing by the legacy's equality",
            )
        },
        Case {
            runs: vec![
                run(100, 1, "success", t(10, 0)),
                run(200, 1, "skipped", t(10, 30)),
            ],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 0)),
                check(2001, "build", "skipped", 200, t(10, 30)),
            ],
            ..named_base(
                "R-U4e10 H2: gh keeps the later-started skipped job of a repeated push dispatch, so the earlier success is unread",
            )
        },
        Case {
            workflows: vec![CaseWorkflow {
                listed: false,
                ..case_workflow(1)
            }],
            runs: vec![run(100, 1, "success", t(10, 0))],
            checks: vec![check(1001, "build", "success", 100, t(10, 0))],
            ..named_base(
                "R-U4e10 H2: a successful run whose workflow the repository's list lacks passes under the workflow fetched by id",
            )
        },
        // R-U4e10 M1: generated #182 of U4e10's corpus, which the
        // uncorrected-first comparison let a startup-pending port pass.
        Case {
            runs: vec![CaseRun {
                display_name: Some("Deploy #182".to_owned()),
                event: "merge_group".to_owned(),
                attempt: Some(2),
                started: None,
                ..run(100, 1, "success", t(10, 0))
            }],
            checks: vec![check(1001, "request", "startup_failure", 100, t(10, 30))],
            statuses: vec![CaseStatus {
                context: "CI Required".to_owned(),
                state: "failure".to_owned(),
                target: Target::Run(UNHELD_RUN),
            }],
            ..named_base(
                "R-U4e10 M1: a startup-failed job beside a failed status targeting an unheld run fails on the corrected input",
            )
        },
        // R-U4e8 H2.
        Case {
            definitions: vec![
                required_definition(),
                Definition {
                    path: ".github/workflows/a.yml".to_owned(),
                    ..required_definition()
                },
            ],
            runs: vec![run(300, 3, "failure", t(10, 0))],
            checks: vec![check(3001, "request", "failure", 300, t(10, 0))],
            ..required(
                "R-U4e8 H2: the earlier sorted definition is unresolved, so the later failed one never decides",
            )
        },
        Case {
            runs: vec![run(300, 3, "success", t(10, 0))],
            checks: vec![check(3001, "request", "success", 300, t(10, 0))],
            statuses: vec![CaseStatus {
                context: "gate".to_owned(),
                state: "failure".to_owned(),
                target: Target::Job(300, 3001),
            }],
            ..required(
                "R-U4e8 H2: a failed commit status targeting the bound job's URL is a required member",
            )
        },
        Case {
            runs: vec![
                run(100, 1, "success", t(10, 0)),
                run(200, 4, "success", t(10, 30)),
            ],
            checks: vec![
                check(1001, "build", "failure", 100, t(10, 0)),
                check(2001, "build", "success", 200, t(10, 30)),
            ],
            ..named_base(
                "R-U4e8 H2: two workflow ids sharing a display name are one group, scoped to the newer job",
            )
        },
        // R-U4e9 H1: the association survives a REST omission of either
        // side of the suite join, and a null REST run name is no workflow
        // name.
        Case {
            runs: vec![CaseRun {
                rest_suite: false,
                ..in_flight(100, 1, t(10, 0))
            }],
            checks: vec![check(1001, "build", "failure", 100, t(10, 0))],
            ..named_base(
                "R-U4e9 H1: a failed job linking an in-progress run whose check_suite_id is absent is held, not terminal",
            )
        },
        Case {
            runs: vec![in_flight(100, 1, t(10, 0))],
            checks: vec![CaseCheck {
                rest_suite: false,
                ..check(1001, "build", "failure", 100, t(10, 0))
            }],
            ..named_base(
                "R-U4e9 H1: a failed job linking an in-progress run, its own check_suite null, is held, not terminal",
            )
        },
        Case {
            runs: vec![
                CaseRun {
                    display_name: None,
                    attempt: Some(2),
                    ..run(100, 1, "success", t(10, 30))
                },
                CaseRun {
                    display_name: None,
                    ..run(200, 1, "success", t(10, 0))
                },
            ],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 30)),
                check(2001, "build", "failure", 200, t(10, 0)),
            ],
            ..named_base(
                "R-U4e9 H1: a successful later rerun beside an older failed job, REST run names null on both, passes under the workflow's name",
            )
        },
        // R-U4e9 H2: a bound job absent from the scoped rollup is missing,
        // and two failed current executions of one definition keep one
        // placeholder by name.
        Case {
            contexts: vec!["lint".to_owned()],
            runs: vec![run(100, 3, "success", t(10, 0))],
            checks: vec![
                CaseCheck {
                    details: Link::Url(check_page_link(1001)),
                    page: Link::Url(check_page_link(1001)),
                    ..check(1001, "build", "success", 100, t(10, 0))
                },
                external_check(1002, "build", "success", &t(10, 30)),
                CaseCheck {
                    suite: EXTERNAL_SUITE + 1,
                    ..external_check(1003, "lint", "success", &t(10, 0))
                },
            ],
            ..required(
                "R-U4e9 H2: a bound job the scoping dropped is missing while another green context stands",
            )
        },
        Case {
            runs: vec![
                run(100, 3, "failure", t(10, 0)),
                CaseRun {
                    source: Some(required_source(WORKFLOW_SHA)),
                    ..run(200, 5, "failure", t(10, 30))
                },
            ],
            checks: vec![
                check(1001, "request", "failure", 100, t(10, 0)),
                check(2001, "request", "failure", 200, t(10, 30)),
            ],
            ..required(
                "R-U4e9 H2: two failed current executions of one definition keep one placeholder by name",
            )
        },
        // R-U4e11-codex 1: gh's survivor among two `build` check runs of
        // one run started in the same second followed its input order
        // through Go's unstable sort (its probe ran the Go body on thirteen
        // contexts, past insertion sort's twelve); the port keeps the
        // higher check-run id, and the legacy's input is rendered in that
        // order (decision 117 (3)). Thirteen contexts: gh's order of the
        // reversed union is pdqsort's, which the adapter does not compute,
        // so this case is counted `union-order-unrendered` (decision 123
        // (1)).
        Case {
            runs: vec![CaseRun {
                latest: Latest::These((2011..=2020).chain([2002]).collect()),
                ..run(200, 1, "success", t(10, 0))
            }],
            checks: (1..=10)
                .map(|i| check(2010 + i, "job", "success", 200, t(10, 30 + i as u32)))
                .map(|c| CaseCheck {
                    name: format!("{}-{}", c.name, c.id - 2010),
                    ..c
                })
                .chain([
                    check(2001, "build", "failure", 200, t(10, 0)),
                    check(2002, "build", "success", 200, t(10, 0)),
                ])
                .collect(),
            statuses: vec![CaseStatus {
                context: "CI Required".to_owned(),
                state: "success".to_owned(),
                target: Target::Run(200),
            }],
            holds: &["tied", "union-order-unrendered"],
            ..named_base(
                "R-U4e11-codex 1: thirteen contexts, two `build` check runs of one run started alike: the higher check-run id survives; gh's order of the union not rendered",
            )
        },
        Case {
            runs: vec![CaseRun {
                latest: Latest::These(vec![2002]),
                ..run(200, 1, "success", t(10, 0))
            }],
            checks: vec![
                CaseCheck {
                    started: None,
                    ..check(2001, "build", "failure", 200, t(10, 0))
                },
                CaseCheck {
                    started: None,
                    ..check(2002, "build", "success", 200, t(10, 0))
                },
            ],
            ..named_base(
                "117 (3): two `build` check runs of one run with no start are ordered by check-run id",
            )
        },
        // R-U4e11-codex 2 and R-U4e11 M1: two `request` check runs of one
        // bound suite completed in the same second; which the suite's
        // `latest` listing names is the server's answer, an input, and the
        // port consumes it (decision 117 (1)).
        Case {
            runs: vec![CaseRun {
                latest: Latest::These(vec![3002]),
                ..run(300, 3, "success", t(10, 0))
            }],
            checks: vec![
                CaseCheck {
                    completed: Some(t(10, 20)),
                    ..check(3001, "request", "success", 300, t(10, 0))
                },
                CaseCheck {
                    completed: Some(t(10, 20)),
                    ..check(3002, "request", "success", 300, t(10, 10))
                },
            ],
            ..required(
                "R-U4e11-codex 2: two `request` check runs of one bound suite completed alike; the suite's latest listing names the newer: pass",
            )
        },
        Case {
            runs: vec![CaseRun {
                latest: Latest::These(vec![3001]),
                ..run(300, 3, "success", t(10, 0))
            }],
            checks: vec![
                CaseCheck {
                    completed: Some(t(10, 20)),
                    ..check(3001, "request", "success", 300, t(10, 0))
                },
                CaseCheck {
                    completed: Some(t(10, 20)),
                    ..check(3002, "request", "success", 300, t(10, 10))
                },
            ],
            ..required(
                "R-U4e11 M1: two `request` check runs of one bound suite completed alike; the suite's latest listing names the older, which the rollup dropped: missing",
            )
        },
        Case {
            runs: vec![CaseRun {
                latest: Latest::These(vec![3002]),
                ..run(300, 3, "success", t(10, 0))
            }],
            checks: vec![
                check(3001, "request", "success", 300, t(10, 0)),
                CaseCheck {
                    status: "in_progress".to_owned(),
                    conclusion: None,
                    completed: None,
                    ..check(3002, "request", "success", 300, t(10, 10))
                },
            ],
            ..required(
                "R-U4e11 M1: a `request` re-run still in progress beside its completed predecessor in one bound suite; the suite's latest listing names it: pending",
            )
        },
        // R-U4e11-codex 3: gh's key is the slash-joined string, so a job
        // `build/CI` of workflow `tests` and a job `build` of `CI/tests`
        // collide, and the later start survives (decision 117 (2)).
        Case {
            runs: vec![
                run(600, 6, "success", t(10, 0)),
                run(700, 7, "success", t(10, 0)),
            ],
            checks: vec![
                check(7001, "build/CI", "failure", 700, t(10, 0)),
                check(6001, "build", "success", 600, t(10, 30)),
            ],
            ..named_base(
                "R-U4e11-codex 3: `build/CI` under workflow `tests` and `build` under `CI/tests` share gh's string key; the later success survives",
            )
        },
        // R-U4e11 H1 and R-U4e11-codex 4: a run whose workflow the list
        // lacks and whose REST detail answers 404 (gh `shared.go:460-470`)
        // or fails is named through the graph, the route the legacy read
        // every name by (decision 117 (4)).
        Case {
            workflows: vec![CaseWorkflow {
                listed: false,
                detail: Detail::NotFound,
                ..case_workflow(1)
            }],
            runs: vec![run(100, 1, "success", t(10, 0))],
            checks: vec![check(1001, "build", "success", 100, t(10, 0))],
            ..named_base(
                "R-U4e11 H1: a successful run whose workflow the list lacks and whose detail answers 404 passes under the graph's name",
            )
        },
        Case {
            workflows: vec![CaseWorkflow {
                listed: false,
                detail: Detail::Failed,
                ..case_workflow(1)
            }],
            runs: vec![run(100, 1, "success", t(10, 0))],
            checks: vec![check(1001, "build", "success", 100, t(10, 0))],
            ..named_base(
                "R-U4e11-codex 4: a successful run whose workflow the list lacks and whose detail read fails passes under the graph's name",
            )
        },
        // R-U4e12-codex H1: the 117 (3) witness with its listing reversed,
        // the higher id first. The later position in the rollup sorts
        // first, so gh's deduplication keeps the failure (decision 119
        // (1)); the reversed order keeps the success, counted.
        Case {
            runs: vec![CaseRun {
                latest: Latest::These(vec![2001]),
                ..run(200, 1, "success", t(10, 0))
            }],
            checks: vec![
                CaseCheck {
                    started: None,
                    ..check(2002, "build", "success", 200, t(10, 0))
                },
                CaseCheck {
                    started: None,
                    ..check(2001, "build", "failure", 200, t(10, 0))
                },
            ],
            ..named_base(
                "R-U4e12-codex H1: two `build` check runs of one run with no start, the higher id listed first: the later-listed failure survives",
            )
        },
        // R-U4e12-codex M1: a graph transport failure is a failed route for
        // a check REST already joined, and the detail names the workflow;
        // the legacy's `gh pr checks` failed, so the comparison is under
        // the graph-answers correction (decision 119 (2)).
        Case {
            workflows: vec![CaseWorkflow {
                listed: false,
                ..case_workflow(1)
            }],
            runs: vec![run(100, 1, "success", t(10, 0))],
            checks: vec![check(1001, "build", "success", 100, t(10, 0))],
            graph: Graph::Failed,
            ..named_base(
                "R-U4e12-codex M1: a joined check whose workflow the list lacks, the graph failing and the detail answering, passes under the detail's name",
            )
        },
        // R-U4e12-codex M1: a null node for one check while a sibling node
        // names the held run's workflow; the detail 404 is never needed.
        Case {
            workflows: vec![CaseWorkflow {
                listed: false,
                detail: Detail::NotFound,
                ..case_workflow(1)
            }],
            runs: vec![run(100, 1, "success", t(10, 0))],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 0)),
                check(1002, "test", "success", 100, t(10, 1)),
            ],
            graph: Graph::NullNodes(vec![1001]),
            ..named_base(
                "R-U4e12-codex M1: two joined checks of one run whose workflow the list lacks, the first node null and the second naming the workflow, the detail 404: pass",
            )
        },
        // R-U4e12 (opus) M1: a status and an undated run-less check share a
        // name outside gh's key; the status, listed after every check run,
        // sorts first among equal starts, and the run-less pick keeps the
        // last, the check. The reversed order keeps the status, counted.
        Case {
            checks: vec![CaseCheck {
                status: "queued".to_owned(),
                conclusion: None,
                started: None,
                completed: None,
                ..external_check(1, "build", "success", &t(10, 0))
            }],
            statuses: vec![CaseStatus {
                context: "build".to_owned(),
                state: "success".to_owned(),
                target: Target::None,
            }],
            ..named_base(
                "R-U4e12 M1: a run-less status `build` beside an undated queued run-less check `build`: the run-less pick keeps the check, pending; reversed, the status, pass",
            )
        },
        // R-U4e13-codex M2: the slash-key collision with equal starts, a
        // tie gh's own survivor depends on between two names (decision 122
        // (2)): the later-listed success survives; reversed, the failure.
        Case {
            runs: vec![
                run(600, 6, "success", t(10, 0)),
                run(700, 7, "success", t(10, 0)),
            ],
            checks: vec![
                check(7001, "build/CI", "failure", 700, t(10, 0)),
                check(6001, "build", "success", 600, t(10, 0)),
            ],
            holds: &["tied", "tie-order-dependent"],
            ..named_base(
                "R-U4e13-codex M2: `build/CI` under `tests` and `build` under `CI/tests` share gh's key and a start: the later-listed success survives; reversed, the failure, counted",
            )
        },
        // R-U4e13-codex M1: the sibling REST does not join names the held
        // run's workflow through its node's `workflowRun.databaseId`, so
        // the joined check's null node reaches no detail read (decision
        // 122 (3)).
        Case {
            workflows: vec![CaseWorkflow {
                listed: false,
                detail: Detail::NotFound,
                ..case_workflow(1)
            }],
            runs: vec![run(100, 1, "success", t(10, 0))],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 0)),
                CaseCheck {
                    rest_suite: false,
                    ..check(1002, "test", "success", 100, t(10, 1))
                },
            ],
            graph: Graph::NullNodes(vec![1001]),
            ..named_base(
                "R-U4e13-codex M1: two checks of one run whose workflow the list lacks, the first REST-joined with a null node, the second unjoined and its node identifying the run, the detail 404: pass, no detail read",
            )
        },
        // R-U4e13 L1: GitHub reports the node it cannot resolve as a null
        // with a field error at its path; the sibling node in the same
        // reply stays a validated answer (decision 122 (4)).
        Case {
            workflows: vec![CaseWorkflow {
                listed: false,
                detail: Detail::NotFound,
                ..case_workflow(1)
            }],
            runs: vec![run(100, 1, "success", t(10, 0))],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 0)),
                check(1002, "test", "success", 100, t(10, 1)),
            ],
            graph: Graph::ErroredNodes(vec![1001]),
            ..named_base(
                "R-U4e13 L1: two joined checks of one run whose workflow the list lacks, the first node null with its error, the second naming the workflow, the detail 404: pass, no detail read",
            )
        },
        // R-U4e13 (opus) P1, P1' and R-U4e13-codex H1: GitHub's union lists
        // the status before the run-less check that shares its name. gh's
        // sort leaves that order standing, and the run-less pick keeps the
        // last of it, the check, as the operation's order keeps it: the
        // stated union agrees. The union in the listing's own order (the
        // check first) is the one that disagrees, counted under the listing
        // on the R-U4e12 M1 witness above.
        Case {
            checks: vec![CaseCheck {
                status: "queued".to_owned(),
                conclusion: None,
                started: None,
                completed: None,
                ..external_check(1, "build", "success", &t(10, 0))
            }],
            statuses: vec![CaseStatus {
                context: "build".to_owned(),
                state: "success".to_owned(),
                target: Target::None,
            }],
            union: Some(vec![Member::Status("build".to_owned()), Member::Check(1)]),
            ..named_base(
                "R-U4e13 P1: a status `build` success listed in the union before an undated queued run-less check `build`: the run-less pick keeps the check under the stated union as under the operation's order, pending",
            )
        },
        Case {
            checks: vec![CaseCheck {
                status: "queued".to_owned(),
                conclusion: None,
                started: None,
                completed: None,
                ..external_check(1, "build", "success", &t(10, 0))
            }],
            statuses: vec![CaseStatus {
                context: "build".to_owned(),
                state: "failure".to_owned(),
                target: Target::None,
            }],
            union: Some(vec![Member::Status("build".to_owned()), Member::Check(1)]),
            ..named_base(
                "R-U4e13 P1': a status `build` failure listed in the union before an undated queued run-less check `build`: pending under the stated union as under the operation's order",
            )
        },
        Case {
            checks: vec![CaseCheck {
                started: None,
                ..external_check(1, "build", "success", &t(10, 0))
            }],
            statuses: vec![CaseStatus {
                context: "build".to_owned(),
                state: "failure".to_owned(),
                target: Target::None,
            }],
            union: Some(vec![Member::Status("build".to_owned()), Member::Check(1)]),
            ..named_base(
                "R-U4e13-codex H1: a status `build` failure listed in the union before an undated successful run-less check `build`: the run-less pick keeps the check, pass, under the stated union as under the operation's order",
            )
        },
        // R-U4e13 (opus) P2: two `build` check runs of one run started
        // alike, REST listing the failure first and the union the success
        // first. gh keeps the first of the union, the success, as the
        // operation keeps the later-listed, the success: the stated union
        // agrees; the union in REST's order is the R-U4e12-codex H1 shape.
        Case {
            runs: vec![CaseRun {
                latest: Latest::These(vec![2002]),
                ..run(200, 1, "success", t(10, 0))
            }],
            checks: vec![
                check(2001, "build", "failure", 200, t(10, 0)),
                check(2002, "build", "success", 200, t(10, 0)),
            ],
            union: Some(vec![Member::Check(2002), Member::Check(2001)]),
            ..named_base(
                "R-U4e13 P2: two dated `build` check runs of one run started alike, REST listing the failure first and the union the success first: pass under the stated union as under the operation's order",
            )
        },
        // R-U4e14-codex M1: thirteen contexts, the two `build` check runs
        // started alike with the failure first in the stated union. Go's
        // pdqsort, not its insertion sort, ordered a union this long, and
        // moved the success ahead of the failure where a stable rendering
        // kept the failure (the review's probe: fail stable, pass under Go);
        // the adapter computes no pdqsort order, so the case is counted
        // `union-order-unrendered` and judged in the operation's order
        // alone (decision 123 (1)).
        {
            let starts = [5, 7, 11, 9, 5, 0, 1, 10, 6, 8, 3, 2, 4];
            let checks: Vec<CaseCheck> = starts
                .iter()
                .enumerate()
                .map(|(i, m)| {
                    let (name, conclusion) = match i {
                        0 => ("build".to_owned(), "failure"),
                        4 => ("build".to_owned(), "success"),
                        _ => (format!("job-{i}"), "success"),
                    };
                    named_check(2001 + i as u64, &name, conclusion, 200, &t(10, *m))
                })
                .collect();
            Case {
                runs: vec![CaseRun {
                    latest: Latest::These(checks.iter().map(|c| c.id).collect()),
                    ..run(200, 1, "success", t(10, 0))
                }],
                union: Some(checks.iter().map(|c| Member::Check(c.id)).collect()),
                checks,
                holds: &["tied", "union-drawn", "union-order-unrendered"],
                ..named_base(
                    "R-U4e14-codex M1: thirteen contexts, two `build` check runs of one run started alike, the failure first in the stated union: gh's order of the union is pdqsort's, not rendered, counted unrendered",
                )
            }
        },
        // The controls' witnesses.
        Case {
            runs: vec![CaseRun {
                source: Some(own_source(WORKFLOW_PATH)),
                ..run(300, 3, "success", t(10, 0))
            }],
            checks: vec![check(3001, "request", "success", 300, t(10, 0))],
            ..required(
                "R-U4e8 H1: a consumer workflow at the required path is not the required workflow's run",
            )
        },
        Case {
            runs: vec![
                run(100, 1, "success", t(10, 0)),
                run(200, 1, "success", t(10, 30)),
            ],
            checks: vec![
                check(1001, "build", "success", 100, t(10, 0)),
                check(2001, "build", "success", 200, t(10, 30)),
                check(2002, "docs", "skipped", 200, t(10, 31)),
            ],
            ..named_base(
                "R-U4e8: equal classes, different selected members: the newer run's build and its skipped docs",
            )
        },
    ]
    .into_iter()
    .map(with_workflows)
    .collect()
}

// --- the generator ---------------------------------------------------------------------

/// A deterministic generator (xorshift64*, fixed seed) over the legacy's
/// input domain: one dimension per field the oracle's functions read
/// (decision 110 (3)), over the object graph's independent identities
/// (decision 112 (1)), with non-injective maps wherever the legacy keys by
/// something other than an id.
///
/// | Legacy input | Read at | Dimension |
/// |---|---|---|
/// | rollup `name` | lib `bucket`/`group_by(.name)`, `required_only`, `missing_required`, ci-wait `classify_checks`; gh's key (`aggregate.go:110`) | job names from five, `build/CI` among them, drawn apart per job so a suite repeats a name; external names from `external` and `build`; status contexts from `CI Required`, `external-status`, `build`, `gate` |
/// | rollup `state` | lib `bucket`, `head_runs` (`EXPECTED`) | `CHECK_STATES`: every `wire::RunConclusion` word, `startup_failure` included, and the five unfinished statuses; status states success, failure, pending, error |
/// | rollup `bucket` | lib `bucket` (`.bucket // …`) | gh's bucket for the state on every entry (`aggregate_checks`): the legacy requested the field by name, so no row lacks it |
/// | rollup `link` (the check run's `details_url`) | lib `runid`, `status_target`, `required_only` (link equality), `missing_required`, `head_runs`, ci-wait `:1057` | a check's details URL apart from its suite: a job link into its suite's run, into another held run, or into `UNHELD_RUN`; its check page; its run's page; a foreign URL; null. A status target naming a run, a run's job (a bound job's included), `UNHELD_RUN`, a foreign URL, or none |
/// | suite read `html_url` | lib `:494-495`, the equality at `:112`, `:119` | the check's page apart from its details URL: equal to it, its own job page, its check page, a foreign URL, or null |
/// | suite read members (GitHub's `latest` answer) | lib `:489-496`; the operation's `evidence::suite_jobs` | per run's suite, one member per name drawn uniformly among the name's check runs, or every member of a repeated name on 15%, whatever their `completed_at` (equal, or null while unfinished): the server's selection as an input (`CaseRun::latest`) |
/// | the rollup's order among equal starts | gh `aggregate.go:97` (`sort.Slice` over the order GitHub returned the union connection in), lib `:173-175` (`max_by`), `:205` (`last`) | the REST listing of the check runs, a shuffle drawn apart from their ids (`Case::checks`), the statuses after them: the operation's listing, which the comparison renders; and the union order itself, every check run and status shuffled apart from that listing (`Case::union`), which the dependence count renders |
/// | the check-run nodes query | the operation's `evidence::check_run_suites` alone; gh's GraphQL client failed `gh pr checks` on any reply error (`checks.go:281`) | answered (85%), null for one or two check runs' nodes (8%, half of them with a `NOT_FOUND` error at the node's path), failed (7%), apart from every workflow's detail (`Case::graph`); where it failed the legacy's rollup is null and the oracle stops on `checks-failed` |
/// | the compositions the uniform draws reach rarely | decision 117 (1)-(3); R-U4e12 L1 | on 15% of required cases the one definition binds a successful run of the required path listing `request` twice; on 10% both slash workflows run, with `build` under `CI/tests` and `build/CI` under `tests` dispatched by one event; on 12% a status and an undated check outside any run share a name |
/// | check `completed_at` | decoded on both reads; selected by nothing | one of four times for a concluded check, drawn apart from its start and from every other check's, so repeats complete alike; null while unfinished |
/// | rollup `startedAt` | gh `eliminateDuplicates` (`aggregate.go:97`), lib `started`, `last_start`, the run-less dedupe | one of four times or null (gh's zero), independently per check, so checks sharing gh's key start alike (`Case::tied`); never on a status |
/// | rollup `workflow`, gh's `Event` | gh `aggregate.go:67-68, 110`; lib `$jobs`/`$run_statuses` (`!= ""`), `group_by(.workflow)` | the check's suite's run's workflow name and event: `CI` for workflows 1 and 4 (two ids, one name), `Guard`, `Required` for 3 and 5 (two ids, one name, one path), `CI/tests` for 6 and `tests` for 7 (gh's string key collides between a `build/CI` job of 7 and a `build` job of 6); `""` for an external suite |
/// | run `id`, `event`, `status`, `conclusion` | lib `latest_workflow_attempt`, ci-wait `superseding_run_state`, lib `:471-475` | ids by 100; `EVENTS` (the six substantive and `schedule`); `RUN_STATES`: every `wire::RunConclusion` word, `startup_failure` included, success weighted, and the five unfinished statuses |
/// | run `name` | nothing | the workflow's name, a `run-name` title, or null on 5%; both sides leave it unread |
/// | run `workflow_id` | lib `group_by(.workflow_id)` (`:470`), ci-wait `:764`, `:748` | one to six of workflows 1, 2, 4, 6, 7, the required 3 and its recreation 5; zero to three runs each; each workflow listed by `actions/workflows` or absent from it on 10%, and its REST detail by id answering (70%), 404 (20%) or failing (10%), drawn apart (`CaseWorkflow::detail`) |
/// | GraphQL `WorkflowRun.databaseId` | gh's query reads none; lib `:393` on the suite node | present, or null on 5% of runs: the run stays in every rendering, unidentified where the graph alone names it |
/// | run `path` | lib `:373` (`split("@")[0]`) | the workflow's file, or a historical path on 10% of runs of workflow 1, with `@refs/heads/main` appended on half the runs |
/// | run `run_attempt`, `run_started_at`, `updated_at` | lib `latest_workflow_attempt`, `:394`, ci-wait `:788-789` | attempt 1, 2 or omitted; start from four times or omitted; `updated_at` independent |
/// | run `check_suite_id`, `check_suite_node_id` | lib `:375-376`, `:393`, `:473`, `:488` | the run's suite, drawn from 5000 apart from every run id, carried by REST or omitted together on 10% of runs; a run owns jobs either way |
/// | check `check_suite` | the legacy's GraphQL `checkSuite` is non-null | the check's suite, null on REST for 7% of checks |
/// | run `repository.id`, `head_sha` | lib `:373-374` | the consumer and the pinned head on every run (pinned by the endpoints the operation reads) |
/// | source proof `file.path`, `repositoryName`, `repositoryFileUrl`, `viewerCanReadRepository` | lib `:393-399`, `:446-456` | per run of workflow 3 or 5: the required source at `WORKFLOW_SHA` or `OTHER_SHA`; the same path and sha in the fork (another id); the consumer's own file at the head; unreadable; or a null file |
/// | source repository `id`, `full_name` | lib `:410-422` | the three repositories by name: the consumer, the source (7) and the fork (9) |
/// | rule `workflows[]` `repository_id`, `path`, `sha`, `ref` | lib `:346` (`unique`), `:367-368`, `:421`, `:430`, `:451-456` | zero to three definitions in the rule's order, repository 7, 8 or 9, the required path or two others, `WORKFLOW_SHA` or `OTHER_SHA`, a ref or none; one duplicated on 20% |
/// | rule `required_status_checks[].context`, `required_only` | lib `requirement_set`, ci-wait `REQUIRED_ONLY` | contexts from `build` and `CI Required`; the flag half the time |
///
/// Nothing the legacy could read is excluded. A failing `repos/{name}`
/// lookup is a read failure the operation refuses as `unreadable` while
/// the legacy pends: a refusal, which the malformed table holds, not a
/// case the oracle judges.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    /// True with probability `percent`/100.
    fn chance(&mut self, percent: u64) -> bool {
        self.below(100) < percent
    }

    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len() as u64) as usize]
    }
}

const TIMES: [&str; 4] = [
    "2026-07-26T10:00:00Z",
    "2026-07-26T10:10:00Z",
    "2026-07-26T10:20:00Z",
    "2026-07-26T10:30:00Z",
];

/// A check's or run's state: every documented conclusion
/// (`wire::RunConclusion`, `stale` and `startup_failure` included) and the
/// five unfinished statuses, success weighted.
const STATES: [(&str, Option<&str>); 18] = [
    ("completed", Some("success")),
    ("completed", Some("success")),
    ("completed", Some("success")),
    ("completed", Some("success")),
    ("completed", Some("success")),
    ("completed", Some("failure")),
    ("completed", Some("failure")),
    ("completed", Some("cancelled")),
    ("completed", Some("skipped")),
    ("completed", Some("neutral")),
    ("completed", Some("timed_out")),
    ("completed", Some("action_required")),
    ("completed", Some("stale")),
    ("completed", Some("startup_failure")),
    ("in_progress", None),
    ("queued", None),
    ("waiting", None),
    ("requested", None),
];

/// The fifth unfinished status, `pending`, which GitHub Actions alone
/// sets; drawn beside `STATES` so its weight stays small.
const PENDING_STATE: (&str, Option<&str>) = ("pending", None);

const EVENTS: [&str; 8] = [
    "pull_request",
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "merge_group",
    "push",
    "workflow_dispatch",
    "schedule",
];

fn generated_cases(count: usize) -> Vec<Case> {
    let mut rng = Rng(0x05ee_d4e9_0000_0112);
    let mut cases = Vec::new();
    let mut n = 0;
    while cases.len() < count {
        n += 1;
        let case = generate(&mut rng, n);
        if case.checks.is_empty() && case.statuses.is_empty() {
            continue;
        }
        cases.push(case);
    }
    cases
}

fn generate(rng: &mut Rng, n: usize) -> Case {
    let required_only = rng.chance(50);
    let mut contexts = Vec::new();
    if required_only {
        for context in ["build", "CI Required"] {
            if rng.chance(40) {
                contexts.push(context.to_owned());
            }
        }
    }
    let mut definitions = Vec::new();
    if required_only && rng.chance(55) {
        let count = *rng.pick(&[1, 1, 1, 2, 3]);
        for _ in 0..count {
            definitions.push(Definition {
                repository_id: *rng.pick(&[
                    SOURCE_REPO_ID,
                    SOURCE_REPO_ID,
                    SOURCE_REPO_ID,
                    OTHER_REPO_ID,
                    FORK_REPO_ID,
                ]),
                path: (*rng.pick(&[
                    WORKFLOW_PATH,
                    WORKFLOW_PATH,
                    WORKFLOW_PATH,
                    ".github/workflows/a.yml",
                    ".github/workflows/guard.yml",
                ]))
                .to_owned(),
                sha: (*rng.pick(&[WORKFLOW_SHA, WORKFLOW_SHA, WORKFLOW_SHA, OTHER_SHA])).to_owned(),
                reference: rng
                    .pick(&[None, Some("refs/heads/main"), Some("refs/heads/dev")])
                    .map(str::to_owned),
            });
        }
        if rng.chance(20) {
            let duplicate = rng.pick(&definitions).clone();
            definitions.push(duplicate);
        }
    }
    // Compositions the uniform draws reach rarely, each forced on a
    // fraction of cases so the generator holds the dimension, not a fixed
    // witness alone (R-U4e12 L1): a bound required run whose suite repeats
    // a job name, so the drawn `latest` answer decides the bound job's
    // page; both slash workflows running the colliding job names under one
    // event; a status and an undated run-less check sharing a name.
    let bound_repeat = required_only && rng.chance(15);
    let collision = rng.chance(10);
    let cross_tie = rng.chance(12);
    let collide_event = (*rng.pick(&EVENTS)).to_owned();
    if bound_repeat {
        definitions = vec![required_definition()];
    }
    let requires_workflow = !definitions.is_empty();
    let state = |rng: &mut Rng| {
        if rng.chance(3) {
            PENDING_STATE
        } else {
            *rng.pick(&STATES)
        }
    };
    let mut runs: Vec<CaseRun> = Vec::new();
    let mut checks: Vec<CaseCheck> = Vec::new();
    let mut next_run = 100;
    let mut next_check = 1000;
    let mut next_suite = 5000;
    let mut workflows = vec![1];
    if rng.chance(30) {
        workflows.push(2);
    }
    if rng.chance(25) {
        workflows.push(4);
    }
    if requires_workflow && rng.chance(85) || !requires_workflow && rng.chance(10) {
        workflows.push(3);
        if rng.chance(20) {
            workflows.push(5);
        }
    }
    if rng.chance(20) {
        workflows.push(6);
    }
    if rng.chance(20) {
        workflows.push(7);
    }
    if bound_repeat && !workflows.contains(&3) {
        workflows.push(3);
    }
    if collision {
        for workflow in [6, 7] {
            if !workflows.contains(&workflow) {
                workflows.push(workflow);
            }
        }
    }
    // A check's start, one of four times or none, drawn apart from every
    // other check's: checks sharing gh's key start alike often, which the
    // port's tie order and the tie count exercise (decision 117 (3)).
    let draw_start = |rng: &mut Rng| -> Option<String> {
        let options: Vec<Option<&str>> = [None]
            .into_iter()
            .chain(TIMES.iter().copied().map(Some))
            .collect();
        rng.pick(&options).map(str::to_owned)
    };
    // GitHub's `latest` answer for a suite: one member per name, drawn
    // uniformly among the name's check runs, or every member of a repeated
    // name on a fraction (decision 117 (1); the documentation fixes
    // neither which member nor that it is one).
    let draw_latest = |rng: &mut Rng, members: &[&CaseCheck]| -> Latest {
        let mut by_name: BTreeMap<&str, Vec<u64>> = BTreeMap::new();
        for c in members {
            by_name.entry(c.name.as_str()).or_default().push(c.id);
        }
        Latest::These(
            by_name
                .values()
                .flat_map(|ids| {
                    if ids.len() > 1 && rng.chance(15) {
                        ids.clone()
                    } else {
                        vec![*rng.pick(ids)]
                    }
                })
                .collect(),
        )
    };
    for &workflow in &workflows {
        let forced_bound = bound_repeat && workflow == 3;
        let forced_collision = collision && matches!(workflow, 6 | 7);
        let run_count = if forced_bound {
            1
        } else if workflow == 1 {
            *rng.pick(&[1, 1, 2, 2, 3])
        } else if forced_collision {
            (*rng.pick(&[0, 1, 1, 2])).max(1)
        } else {
            *rng.pick(&[0, 1, 1, 2])
        };
        for run_index in 0..run_count {
            let id = next_run;
            next_run += 100;
            let suite = next_suite;
            next_suite += 1;
            let (status, conclusion) = if forced_bound {
                ("completed", Some("success"))
            } else {
                state(rng)
            };
            let event = if forced_collision {
                collide_event.clone()
            } else {
                (*rng.pick(&EVENTS)).to_owned()
            };
            let attempt = if forced_bound {
                Some(1)
            } else if rng.chance(25) {
                Some(2)
            } else if rng.chance(15) {
                None
            } else {
                Some(1)
            };
            let started = (!rng.chance(15)).then(|| (*rng.pick(&TIMES)).to_owned());
            let file = if workflow == 1 && rng.chance(10) {
                ".github/workflows/old-ci.yml".to_owned()
            } else {
                workflow_path(workflow)
            };
            let path = if rng.chance(50) {
                format!("{file}@refs/heads/main")
            } else {
                file.clone()
            };
            let source = if forced_bound {
                Some(required_source(WORKFLOW_SHA))
            } else if matches!(workflow, 3 | 5) {
                match rng.below(100) {
                    0..=59 => Some(required_source(WORKFLOW_SHA)),
                    60..=71 => Some(required_source(OTHER_SHA)),
                    72..=81 => Some(SourceFile {
                        repository: FORK_REPO.to_owned(),
                        ..required_source(WORKFLOW_SHA)
                    }),
                    82..=89 => Some(own_source(&file)),
                    90..=95 => Some(SourceFile {
                        readable: false,
                        ..required_source(WORKFLOW_SHA)
                    }),
                    _ => None,
                }
            } else {
                Some(own_source(&file))
            };
            let display_name = match rng.below(100) {
                0..=4 => None,
                5..=14 => Some(format!("Deploy #{n}")),
                _ => Some(workflow_name(workflow)),
            };
            runs.push(CaseRun {
                id,
                workflow,
                display_name,
                path,
                event,
                status: status.to_owned(),
                conclusion: conclusion.map(str::to_owned),
                attempt,
                started,
                updated: (*rng.pick(&TIMES)).to_owned(),
                suite,
                rest_suite: forced_bound || !rng.chance(10),
                graphql_id: !rng.chance(5),
                source,
                // Drawn once the suite's check runs exist, below.
                latest: Latest::Every,
            });
            // A name drawn apart per job, so a suite lists one twice (a
            // re-run attempt, or jobs sharing a name, lib `:103`), with its
            // state and completion drawn apart from the other's; the bound
            // repeat is two `request` jobs, and the collision adds the
            // colliding job to the first run of each slash workflow.
            let job_count = *rng.pick(&[0, 1, 1, 1, 2, 2, 2]);
            let mut names: Vec<String> = (0..job_count)
                .map(|_| (*rng.pick(&["build", "test", "lint", "request", "build/CI"])).to_owned())
                .collect();
            if forced_bound {
                names = vec!["request".to_owned(), "request".to_owned()];
            }
            if forced_collision && run_index == 0 {
                names.push(if workflow == 6 { "build" } else { "build/CI" }.to_owned());
            }
            let first_check = next_check + 1;
            for name in names {
                let (status, conclusion) = state(rng);
                let completed = conclusion.map(|_| (*rng.pick(&TIMES)).to_owned());
                next_check += 1;
                let details = match rng.below(100) {
                    _ if forced_bound => Link::Job(id),
                    0..=79 => Link::Job(id),
                    80..=84 => Link::Job(rng.pick(&runs).id),
                    85..=88 => Link::Job(UNHELD_RUN),
                    89..=93 => Link::Url(check_page_link(next_check)),
                    94..=96 => Link::Url(run_link(id)),
                    _ => Link::None,
                };
                let page = match rng.below(100) {
                    _ if forced_bound => details.clone(),
                    0..=84 => details.clone(),
                    85..=91 => Link::Job(id),
                    92..=95 => Link::Url(check_page_link(next_check)),
                    96..=97 => Link::Url(format!("https://ci.example.com/jobs/{n}/{next_check}")),
                    _ => Link::None,
                };
                checks.push(CaseCheck {
                    id: next_check,
                    name,
                    status: status.to_owned(),
                    conclusion: conclusion.map(str::to_owned),
                    suite,
                    rest_suite: !rng.chance(7),
                    details,
                    page,
                    started: draw_start(rng),
                    completed,
                });
            }
            let members: Vec<&CaseCheck> = checks.iter().filter(|c| c.id >= first_check).collect();
            let latest = draw_latest(rng, &members);
            runs.last_mut().expect("the run was pushed above").latest = latest;
        }
    }
    let external_count = *rng.pick(&[0, 0, 0, 1, 1, 2]);
    for _ in 0..external_count {
        let (status, conclusion) = state(rng);
        next_check += 1;
        let details = match rng.below(100) {
            0..=54 => Link::Url(check_page_link(next_check)),
            55..=74 => Link::Url(format!("https://ci.example.com/builds/{n}/{next_check}")),
            75..=89 => Link::None,
            _ if runs.is_empty() => Link::None,
            _ => Link::Job(rng.pick(&runs).id),
        };
        let page = match rng.below(100) {
            0..=79 => details.clone(),
            80..=89 => Link::Url(check_page_link(next_check)),
            90..=94 => Link::Url(format!("https://ci.example.com/jobs/{n}/{next_check}")),
            _ => Link::None,
        };
        checks.push(CaseCheck {
            id: next_check,
            name: (*rng.pick(&["external", "external", "build"])).to_owned(),
            status: status.to_owned(),
            conclusion: conclusion.map(str::to_owned),
            suite: EXTERNAL_SUITE + rng.below(2),
            rest_suite: !rng.chance(7),
            details,
            page,
            started: draw_start(rng),
            completed: conclusion.map(|_| (*rng.pick(&TIMES)).to_owned()),
        });
    }
    let mut statuses: Vec<CaseStatus> = Vec::new();
    let status_count = *rng.pick(&[0, 0, 1, 1, 1, 2]);
    for _ in 0..status_count {
        let context = *rng.pick(&[
            "CI Required",
            "CI Required",
            "external-status",
            "build",
            "gate",
        ]);
        if statuses.iter().any(|s| s.context == context) {
            continue;
        }
        let state = *rng.pick(&[
            "success", "success", "success", "failure", "failure", "pending", "error",
        ]);
        let run_id = |rng: &mut Rng, runs: &[CaseRun]| rng.pick(runs).id;
        let target = if runs.is_empty() || rng.chance(15) {
            Target::None
        } else if rng.chance(10) {
            Target::Foreign(format!("https://ci.example.com/builds/{n}"))
        } else if rng.chance(55) {
            Target::Run(run_id(rng, &runs))
        } else if rng.chance(40) {
            Target::Run(UNHELD_RUN)
        } else {
            let run = run_id(rng, &runs);
            let job = checks
                .iter()
                .find(|c| matches!(c.details, Link::Job(r) if r == run))
                .map_or(7, |c| c.id);
            Target::Job(run, job)
        };
        statuses.push(CaseStatus {
            context: context.to_owned(),
            state: state.to_owned(),
            target,
        });
    }
    if cross_tie {
        // A status and an undated check outside any run share a name; the
        // check's details are drawn as an external check's.
        if statuses.is_empty() {
            statuses.push(CaseStatus {
                context: "build".to_owned(),
                state: (*rng.pick(&["success", "failure", "pending"])).to_owned(),
                target: Target::None,
            });
        }
        let context = statuses[0].context.clone();
        let (status, conclusion) = state(rng);
        next_check += 1;
        let details = match rng.below(100) {
            0..=49 => Link::Url(check_page_link(next_check)),
            50..=79 => Link::None,
            _ if runs.is_empty() => Link::None,
            _ => Link::Job(rng.pick(&runs).id),
        };
        checks.push(CaseCheck {
            id: next_check,
            name: context,
            status: status.to_owned(),
            conclusion: conclusion.map(str::to_owned),
            suite: EXTERNAL_SUITE + rng.below(2),
            rest_suite: !rng.chance(7),
            page: details.clone(),
            details,
            started: None,
            completed: conclusion.map(|_| (*rng.pick(&TIMES)).to_owned()),
        });
    }
    // The check-run nodes query: answered, null for one or two check
    // runs' nodes (error-free, or each with its field error), or failed,
    // drawn apart from every workflow's detail (decisions 119 (2), 122
    // (4)).
    let graph = match rng.below(100) {
        0..=84 => Graph::Answers,
        85..=92 if checks.is_empty() => Graph::Answers,
        shape @ 85..=92 => {
            let count = 1 + rng.below(2);
            let ids: Vec<u64> = (0..count).map(|_| rng.pick(&checks).id).collect();
            if shape <= 88 {
                Graph::NullNodes(ids)
            } else {
                Graph::ErroredNodes(ids)
            }
        }
        _ => Graph::Failed,
    };
    // The order the REST endpoint lists the check runs in, drawn apart
    // from their ids (decision 122 (1)): a Fisher-Yates shuffle.
    for i in (1..checks.len()).rev() {
        let j = rng.below(i as u64 + 1) as usize;
        checks.swap(i, j);
    }
    let mut case = Case {
        name: format!("generated #{n}"),
        required_only,
        contexts,
        definitions,
        sources: sources(),
        workflows: workflows
            .into_iter()
            .map(|id| CaseWorkflow {
                listed: !rng.chance(10),
                detail: match rng.below(100) {
                    0..=69 => Detail::Answers,
                    70..=89 => Detail::NotFound,
                    _ => Detail::Failed,
                },
                ..case_workflow(id)
            })
            .collect(),
        runs,
        checks,
        statuses,
        union: None,
        graph,
        generated: true,
        holds: &[],
    };
    // The order GitHub returned the union connection in, drawn apart from
    // the REST listing (decision 122 (2)): every check run and status,
    // shuffled, so the check runs stand in another order than REST's and
    // the statuses at any position. The draw comes from a generator derived
    // from this case's state, so it advances the shared one by nothing and
    // every other dimension of every case keeps the draw it had before
    // this one existed.
    let mut rng = Rng(rng.0 ^ 0x9E37_79B9_7F4A_7C15 ^ n as u64);
    let mut union = case.listing();
    for i in (1..union.len()).rev() {
        let j = rng.below(i as u64 + 1) as usize;
        union.swap(i, j);
    }
    case.union = Some(union);
    case
}

/// Every case of the corpus: the legacy fixtures, the named cases, the
/// review witnesses and the generated cases.
fn corpus() -> Vec<Case> {
    let mut cases = legacy_cases();
    cases.extend(named_cases());
    cases.extend(witness_cases());
    cases.extend(generated_cases(300));
    cases
}

/// The legacy's reading of a case under `corrections`: its selection and
/// its conclusion, the latter with decision 112 (2)'s correction applied
/// where its predicate holds (`corrected_by_112_2`); or the error it
/// stopped on with no verdict, `checks-failed` where `gh pr checks` failed
/// (`ci-wait:860-863`).
enum LegacyReading {
    Read(Box<LegacyRead>),
    Error { cause: String },
}

struct LegacyRead {
    out: Value,
    selection: Projection,
    conclusion: Conclusion,
    corrected_by_112_2: bool,
}

fn legacy_reading(
    case: &Case,
    dir: &Path,
    corrections: Corrections,
    tie: TieOrder<'_>,
) -> LegacyReading {
    let out = oracle(case, dir, corrections, tie);
    if out["outcome"] == "error" {
        assert_eq!(out["exit"], 1, "{}: {out}", case.name);
        return LegacyReading::Error {
            cause: out["cause"].as_str().unwrap().to_owned(),
        };
    }
    let selection = legacy_projection(&out, case);
    let (conclusion, corrected_by_112_2) =
        corrected_by_112_2(case, &out, &oracle_conclusion(&out, case));
    LegacyReading::Read(Box::new(LegacyRead {
        out,
        selection,
        conclusion,
        corrected_by_112_2,
    }))
}

impl LegacyReading {
    /// The reading of a case the legacy judged.
    fn read(&self, case: &Case) -> &LegacyRead {
        match self {
            LegacyReading::Read(read) => read,
            LegacyReading::Error { cause } => {
                panic!(
                    "{}: the legacy stopped on {cause} where a verdict was read",
                    case.name
                )
            }
        }
    }
}

/// The branches whose floor the generator must reach on its own, apart
/// from the fixed witnesses that hold each (R-U4e12 L1, L2; decision 119).
const GENERATED_FLOOR: [&str; 11] = [
    "tie-order-dependent",
    "cross-key-tie",
    "key-collision",
    "bound-suite-name-repeated",
    "latest-names-twice",
    "listing-apart-from-ids",
    "graph-null-node",
    "graph-errored-node",
    "graph-failed",
    "corrected-119-2",
    "union-order-dependent",
];

/// Decisions 107 (3), 110 (4), 112, 113, 114 (4), 117 and 119: the
/// operation and the legacy's own functions agree on every corpus case,
/// first in the selection they made (`project` against
/// `legacy_projection`), then in verdict, pending cause key and classified
/// members under the one mapping `oracle_conclusion` states, with decision
/// 112 (2)'s correction applied to the legacy's conclusion where its
/// predicate holds (`corrected_by_112_2`); the classes are compared for
/// every case, the required-pending ones included (decision 112 (4)). A
/// case whose rollup carries a `startup_failure` check is compared with the
/// legacy over decision 113's corrected bucket for that row alone
/// (`Corrections::startup_failure`); the legacy over gh's own bucket runs
/// too, counted where it reads differently (`corrected-113`) and never
/// accepted as the match (decision 114 (4)). The legacy's contexts are
/// rendered in the operation's tie order (`TieOrder::Port`); a tied case
/// (`Case::tied`) runs the legacy once more with every tie reversed, and a
/// case carrying a drawn union order (`Case::union`) once more under it,
/// and the cases whose legacy selection or conclusion changes are counted
/// (`tie-order-dependent`, `union-order-dependent`) and printed with the
/// corpus summary, never accepted (decisions 117 (3), 122 (2)); a case
/// whose union exceeds `GH_SORT_EXACT_UP_TO` contexts is counted
/// `union-order-unrendered` instead and left out of both (decision 123
/// (1)). Every count a fixed case holds (`Case::holds`) is asserted
/// recorded for it, after the summary line. Where the graph failed (`Graph::Failed`)
/// the legacy stopped on `checks-failed`: the operation's refusal there is
/// the agreement (`graph-failed-refused`), and its verdict, reached through
/// the detail route, is compared with the legacy over the same input with
/// the graph answering (`Corrections::graph_answers`), counted
/// (`corrected-119-2`) and never taken on its own (decision 119 (2)). A
/// refusal, where the legacy stopped or judged, is admitted only when the
/// case's relations leave no route to what the cause names
/// (`Case::every_route_failed`), counted (`graph-failed-refused`,
/// `route-refused`), with no verdict to compare. A mismatch fails the test with both derivations, the selection
/// first. The corpus is bounded; the floor asserts the generator reached
/// every legacy branch, the 112 (2) correction's predicate, the 113
/// correction, a tie, a tie the legacy's answer depends on, a tie across
/// gh's key, a suite listing a name twice, a bound suite listing a name
/// twice, a `latest` answer naming one name twice, a listing not in id
/// order, a string-key collision, a workflow the graph alone names, a null
/// node, an errored null node, a failed graph, a drawn union, a case
/// dependent on it and the 119 (2) correction; `GENERATED_FLOOR` names the
/// branches the generated cases must reach without the fixed witnesses.
/// Every read of a detail by id is checked against the case's relations
/// (`assert_detail_last`): the route is reached only for a workflow no
/// validated node named.
#[test]
#[allow(
    clippy::print_stdout,
    reason = "the summary line (cases, tied, tie-order-dependent, disagreements) is the differential's one report, read under --nocapture by the must-fail controls"
)]
fn the_operation_and_the_legacy_oracle_agree_over_the_corpus() {
    let cases = corpus();
    let next = AtomicUsize::new(0);
    let mismatches: Mutex<Vec<String>> = Mutex::new(Vec::new());
    let unheld: Mutex<Vec<String>> = Mutex::new(Vec::new());
    let branches: Mutex<BTreeMap<&'static str, usize>> = Mutex::new(BTreeMap::new());
    let generated: Mutex<BTreeMap<&'static str, usize>> = Mutex::new(BTreeMap::new());
    let workers = std::thread::available_parallelism()
        .map_or(4, |n| n.get())
        .clamp(2, 16);
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::SeqCst);
                    let Some(case) = cases.get(i) else { break };
                    let recorded: RefCell<Vec<&'static str>> = RefCell::new(Vec::new());
                    let record = |branch: &'static str| {
                        recorded.borrow_mut().push(branch);
                        *branches.lock().unwrap().entry(branch).or_default() += 1;
                        if case.generated {
                            *generated.lock().unwrap().entry(branch).or_default() += 1;
                        }
                    };
                    // Every count the fixed case holds was recorded for it.
                    let hold = || {
                        let recorded = recorded.borrow();
                        for held in case.holds.iter().filter(|held| !recorded.contains(held)) {
                            unheld.lock().unwrap().push(format!(
                                "{}: holds {held}, recorded {recorded:?}",
                                case.name
                            ));
                        }
                    };
                    let disagree = |text: String| mismatches.lock().unwrap().push(text);
                    match &case.graph {
                        Graph::Answers => {}
                        Graph::NullNodes(_) => record("graph-null-node"),
                        Graph::ErroredNodes(_) => record("graph-errored-node"),
                        Graph::Failed => record("graph-failed"),
                    }
                    if case.cross_key_tie() {
                        record("cross-key-tie");
                    }
                    if case.repeats_a_suite_name() {
                        record("suite-name-repeated");
                    }
                    if case.bound_suite_repeats_a_name() {
                        record("bound-suite-name-repeated");
                    }
                    if case.latest_names_twice() {
                        record("latest-names-twice");
                    }
                    if case.listing_apart_from_ids() {
                        record("listing-apart-from-ids");
                    }
                    if case.key_collision() {
                        record("key-collision");
                    }
                    if case.names_a_workflow_by_graph_alone() {
                        record("workflow-by-graph-alone");
                    }
                    let dir = tempfile::tempdir().unwrap();
                    let startup_failure = case.has_startup_failure();
                    let corrections = Corrections {
                        startup_failure,
                        graph_answers: false,
                    };
                    let legacy = legacy_reading(case, dir.path(), corrections, TieOrder::Port);
                    let judged = match judge_case(case) {
                        Ok(judged) => judged,
                        Err((cause, log)) => {
                            assert_pinned(case, &log);
                            assert_detail_last(case, &log);
                            match &legacy {
                                // Both stopped: the legacy on `gh pr checks`,
                                // the operation on the graph route an
                                // unjoined check has no other route past.
                                LegacyReading::Error { cause: legacy_cause } => {
                                    assert_eq!(legacy_cause, "checks-failed", "{}", case.name);
                                    if case.every_route_failed(&cause.key()) {
                                        record("graph-failed-refused");
                                    } else {
                                        disagree(format!(
                                            "--- {} (refusal where the legacy stopped on checks-failed)\ncase: {case:?}\noperation: unreadable {}\n",
                                            case.name,
                                            cause.key()
                                        ));
                                    }
                                }
                                LegacyReading::Read(_) => {
                                    if case.every_route_failed(&cause.key()) {
                                        record("route-refused");
                                    } else {
                                        disagree(format!(
                                            "--- {} (refusal where the legacy judged)\ncase: {case:?}\noperation: unreadable {}\n",
                                            case.name,
                                            cause.key()
                                        ));
                                    }
                                }
                            }
                            hold();
                            continue;
                        }
                    };
                    assert_pinned(case, &judged.log);
                    assert_detail_last(case, &judged.log);
                    let op = &judged.conclusion;
                    // The operation judged where the legacy stopped: the
                    // legacy is read over the input with the graph
                    // answering, decision 119 (2)'s correction.
                    let (corrections, legacy) = match legacy {
                        LegacyReading::Error { cause } => {
                            assert_eq!(cause, "checks-failed", "{}", case.name);
                            record("corrected-119-2");
                            let corrections = Corrections {
                                graph_answers: true,
                                ..corrections
                            };
                            (
                                corrections,
                                legacy_reading(case, dir.path(), corrections, TieOrder::Port),
                            )
                        }
                        read @ LegacyReading::Read(_) => (corrections, read),
                    };
                    let legacy = legacy.read(case);
                    // The uncorrected run, for its count alone.
                    let uncorrected_differs = startup_failure && {
                        let raw = legacy_reading(
                            case,
                            dir.path(),
                            Corrections {
                                startup_failure: false,
                                ..corrections
                            },
                            TieOrder::Port,
                        );
                        let raw = raw.read(case);
                        raw.selection != legacy.selection || raw.conclusion != legacy.conclusion
                    };
                    // The legacy under another union order, for its count
                    // alone: the listing's own order on a tied case, and
                    // the drawn union where the case carries one.
                    let differs_under = |tie: TieOrder<'_>| {
                        let other = legacy_reading(case, dir.path(), corrections, tie);
                        let other = other.read(case);
                        other.selection != legacy.selection
                            || other.conclusion != legacy.conclusion
                    };
                    let tied = case.tied();
                    // A union of more than `GH_SORT_EXACT_UP_TO` contexts
                    // is not rendered: gh's order of it is pdqsort's, which
                    // the adapter does not compute (decision 123 (1)).
                    let unrendered =
                        (tied || case.union.is_some()) && !case.union_rendered();
                    let listing = case.listing();
                    let tie_dependent =
                        tied && !unrendered && differs_under(TieOrder::Union(&listing));
                    let union_dependent = !unrendered
                        && case
                            .union
                            .as_deref()
                            .is_some_and(|union| differs_under(TieOrder::Union(union)));
                    let stage = if judged.projection != legacy.selection {
                        Some("selection")
                    } else if !(op.verdict == legacy.conclusion.verdict
                        && op.cause == legacy.conclusion.cause
                        && legacy.conclusion.classes == op.classes)
                    {
                        Some("classification")
                    } else {
                        None
                    };
                    record(oracle_branch(&legacy.out));
                    if legacy.corrected_by_112_2 {
                        record("corrected-112-2");
                    }
                    if startup_failure {
                        record("startup-failure-in-rollup");
                    }
                    if uncorrected_differs {
                        record("corrected-113");
                    }
                    if tied {
                        record("tied");
                    }
                    if tie_dependent {
                        record("tie-order-dependent");
                        // The dependence reaches the legacy only through
                        // the lib's by-name picks (R-U4e12 M1).
                        if !case.tied_in_key() {
                            record("cross-key-tie-order-dependent");
                        }
                    }
                    if case.union.is_some() {
                        record("union-drawn");
                    }
                    if union_dependent {
                        record("union-order-dependent");
                    }
                    if unrendered {
                        record("union-order-unrendered");
                    }
                    hold();
                    if let Some(stage) = stage {
                        disagree(format!(
                            "--- {} ({stage}{}{}{})\ncase: {case:?}\noperation selection: {:?}\nlegacy selection: {:?}\noperation: {op:?}\nlegacy: {:?}\n  oracle: {}\n",
                            case.name,
                            if legacy.corrected_by_112_2 { ", legacy corrected by 112 (2)" } else { "" },
                            if corrections.startup_failure { ", legacy corrected by 113" } else { "" },
                            if corrections.graph_answers { ", legacy corrected by 119 (2)" } else { "" },
                            judged.projection,
                            legacy.selection,
                            legacy.conclusion,
                            legacy.out
                        ));
                    }
                }
            });
        }
    });
    let mismatches = mismatches.into_inner().unwrap();
    let unheld = unheld.into_inner().unwrap();
    let branches = branches.into_inner().unwrap();
    let generated = generated.into_inner().unwrap();
    let count = |branch: &str| branches.get(branch).copied().unwrap_or(0);
    println!(
        "corpus: {} cases, {} tied, {} tie-order-dependent (the legacy's answer changes under the reversed tie order), {} union-order-dependent of {} with a drawn union (the legacy's answer changes under the drawn union order), {} union-order-unrendered (more than {GH_SORT_EXACT_UP_TO} contexts: gh's order is pdqsort's, not computed, left out of both counts), {} disagree; branches {branches:?}; generated {generated:?}",
        cases.len(),
        count("tied"),
        count("tie-order-dependent"),
        count("union-order-dependent"),
        count("union-drawn"),
        count("union-order-unrendered"),
        mismatches.len()
    );
    assert!(
        mismatches.is_empty(),
        "{} of {} cases disagree:\n{}",
        mismatches.len(),
        cases.len(),
        mismatches.join("\n")
    );
    assert!(
        unheld.is_empty(),
        "{} counts a fixed case holds were not recorded:\n{}",
        unheld.len(),
        unheld.join("\n")
    );
    for branch in [
        "required-pending",
        "required-failed",
        "checks-pending",
        "failed-run-active",
        "superseded",
        "terminal",
        "terminal-unattributable",
        "actions-terminal",
        "settled",
        "required-pass",
        "actions-unsettled",
        "no-success",
        "corrected-112-2",
        "corrected-113",
        "tied",
        "tie-order-dependent",
        "cross-key-tie",
        "cross-key-tie-order-dependent",
        "suite-name-repeated",
        "bound-suite-name-repeated",
        "latest-names-twice",
        "listing-apart-from-ids",
        "key-collision",
        "workflow-by-graph-alone",
        "graph-null-node",
        "graph-errored-node",
        "graph-failed",
        "graph-failed-refused",
        "union-drawn",
        "union-order-dependent",
        "union-order-unrendered",
        "route-refused",
        "corrected-119-2",
    ] {
        assert!(
            branches.get(branch).is_some_and(|n| *n > 0),
            "the corpus never reached the legacy's {branch} branch: {branches:?}"
        );
    }
    for branch in GENERATED_FLOOR {
        assert!(
            generated.get(branch).is_some_and(|n| *n > 0),
            "no generated case reached {branch}: {generated:?}"
        );
    }
}
