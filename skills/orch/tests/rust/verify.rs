//! The `verify-head` operation through the built binary
//! against a fake `gh` on PATH: the pinned reads, the closed decoding and
//! completeness of every reply, the decision rows the verdict pins, the
//! required workflow's binding proof, the `none` route over every absence
//! page, and the record written on `complete`. The fake answers from a
//! JSON map the row builds, starting from the documented replies beside
//! it, and logs every call, so a row can assert what was read and what
//! never was. Recorded answer sets under `fixtures/gh/witnesses/` are
//! the verdict's correctness floor, one table row each
//! (`the_recorded_witnesses_keep_the_legacy_verdict`).
//!
//! The `verify-pr` operation is the same verification over the head
//! one `gh pr view` answers for a pull request; its rows at the end pin the
//! read of the pull request, the refusal of one that is not open, and the
//! head re-read on every call.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests run the built binary against a fake gh on PATH"
)]

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
mod support;

use std::process::Output;

use orch_runtime::error::Error;
use orch_runtime::ops::{Env, Request, VerifyHead, VerifyPr, apply};
use orch_runtime::state::Locking;
use serde_json::{Map, Value, json};
use tempfile::TempDir;

const ITEM: &str = include_str!("fixtures/workflow-state-KEN-4687.json");
const REPO: &str = "owner/repo";
/// The consumer repository's id, as the branch and run objects name it.
const REPO_ID: u64 = 1_296_269;
const BASE: &str = "main";
/// The pinned head every fixture reply is about.
const HEAD: &str = "737bce791577e140436490e0fed5751bb5144a61";
/// Where the branch moved to after publication; never read.
const MOVED: &str = "e99849b1c72b1c082cf8325f316799e753f99561";
/// The source commit a `workflows` rule pins the required workflow to.
const WORKFLOW_SHA: &str = "0123456789abcdef0123456789abcdef01234567";
/// Another source commit, which binds no rule.
const OTHER_SHA: &str = "89abcdef0123456789abcdef0123456789abcdef";
const WORKFLOW_PATH: &str = ".github/workflows/required.yml";
/// The required workflow's source repository and its id, the rule's
/// `repository_id`.
const SOURCE_REPO: &str = "owner/source";
const SOURCE_REPO_ID: u64 = 7;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("tests/rust/fixtures/gh")
}

fn fixture(name: &str) -> Value {
    serde_json::from_str(&fs::read_to_string(fixtures().join(name)).unwrap()).unwrap()
}

// --- the paths the operation requests --------------------------------------

fn page(path: &str, n: usize) -> String {
    let join = if path.contains('?') { '&' } else { '?' };
    format!("{path}{join}per_page=100&page={n}")
}

/// Every check run on the commit, not GitHub's `latest` selection, which
/// the suite read below consumes.
fn check_runs(head: &str, n: usize) -> String {
    page(
        &format!("repos/{REPO}/commits/{head}/check-runs?filter=all"),
        n,
    )
}

/// The ref's check-suites count, the completeness proof of the check-runs
/// read.
fn check_suites(head: &str, n: usize) -> String {
    page(&format!("repos/{REPO}/commits/{head}/check-suites"), n)
}

fn statuses(head: &str, n: usize) -> String {
    page(&format!("repos/{REPO}/commits/{head}/status"), n)
}

fn runs(head: &str, n: usize) -> String {
    page(&format!("repos/{REPO}/actions/runs?head_sha={head}"), n)
}

fn rules(n: usize) -> String {
    page(&format!("repos/{REPO}/rules/branches/{BASE}"), n)
}

fn branch() -> String {
    format!("repos/{REPO}/branches/{BASE}")
}

fn workflows(n: usize) -> String {
    page(&format!("repos/{REPO}/actions/workflows"), n)
}

/// A required workflow candidate's suite as GitHub lists its check runs
/// under the endpoint's default `filter=latest`: the bound-job list.
fn suite_check_runs(suite: u64, n: usize) -> String {
    page(&format!("repos/{REPO}/check-suites/{suite}/check-runs"), n)
}

/// The fake's key for the GraphQL suite-nodes query.
const GRAPHQL: &str = "graphql";

/// The source repository's lookup, for the id its proof is matched by.
fn source_repository() -> String {
    format!("repos/{SOURCE_REPO}")
}

// --- reply builders -----------------------------------------------------------

/// The fixture run's check suite.
const SUITE: u64 = 5;

/// When every built check run started and completed, unless a row says
/// otherwise.
const STARTED: &str = "2026-01-29T15:10:00Z";
const COMPLETED: &str = "2026-01-29T15:15:00Z";

/// A check run in the fixture run's suite.
fn check_run(name: Value, status: &str, conclusion: Value) -> Value {
    check_run_in(Some(SUITE), 9, name, status, conclusion)
}

/// A check run with its suite (`None` for a check with no suite) and id.
/// Its two URLs are one page, its job page under the suite's run or its
/// check page, as the Actions app sets them; a row that needs them apart
/// sets one.
fn check_run_in(
    suite: Option<u64>,
    id: u64,
    name: Value,
    status: &str,
    conclusion: Value,
) -> Value {
    let check_suite = suite.map_or(Value::Null, |id| json!({"id": id}));
    let html_url = match suite {
        Some(run) => format!("https://github.com/{REPO}/actions/runs/{run}/job/{id}"),
        None => format!("https://github.com/{REPO}/runs/{id}"),
    };
    json!({"id": id, "node_id": check_node_id(id), "name": name, "status": status, "conclusion": conclusion, "head_sha": HEAD, "check_suite": check_suite, "started_at": STARTED, "completed_at": COMPLETED, "html_url": html_url, "details_url": html_url})
}

fn check_node_id(check: u64) -> String {
    format!("CR_{check}")
}

/// A check run's GraphQL node, the suite join the operation reads where
/// REST omits it: the suite's id, and its run, where an Actions workflow
/// made the suite, with the run's `databaseId` as GitHub identifies it
/// (an id, or null), a `push` dispatch and the run's workflow name.
fn check_node(check: u64, suite: Option<u64>, run: Option<(Value, &str)>) -> Value {
    let workflow_run = run.map_or(
        Value::Null,
        |(id, workflow)| json!({"databaseId": id, "event": "push", "workflow": {"name": workflow}}),
    );
    json!({"id": check_node_id(check), "checkSuite": {"databaseId": suite, "workflowRun": workflow_run}})
}

/// The read of a workflow by id, gh's route for a run whose workflow the
/// repository's list lacks.
fn workflow_by_id(id: u64) -> String {
    format!("repos/{REPO}/actions/workflows/{id}")
}

/// A workflow object as the read by id answers it.
fn workflow_object(id: u64, name: &str) -> Value {
    json!({"id": id, "node_id": format!("W_{id}"), "name": name, "path": ".github/workflows/old-ci.yml", "state": "deleted"})
}

/// The documented Actions run beside this file naming a workflow the
/// repository's list lacks.
fn unlisted_run() -> Value {
    let mut runs = fixture("actions-runs.json");
    runs["workflow_runs"][0]["workflow_id"] = json!(424_242);
    runs
}

/// The nodes of the documented check runs beside this file, each in the
/// suite of `run`, whose workflow the graph names `workflow`: the route
/// `gh pr checks` read every workflow name through.
fn fixture_check_nodes(run: u64, workflow: &str) -> Vec<Value> {
    fixture("check-runs.json")["check_runs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            json!({"id": c["node_id"], "checkSuite": {"workflowRun": {"databaseId": run, "event": "push", "workflow": {"name": workflow}}}})
        })
        .collect()
}

/// The check-run nodes of the check runs no run among `runs` owns through
/// its `check_suite_id`: external suites, which the operation asks GitHub
/// about.
fn external_nodes(check_runs: &[Value], runs: &[Value]) -> Vec<Value> {
    let owned: BTreeSet<u64> = runs
        .iter()
        .filter_map(|r| r["check_suite_id"].as_u64())
        .collect();
    check_runs
        .iter()
        .filter(|c| {
            !c["check_suite"]["id"]
                .as_u64()
                .is_some_and(|s| owned.contains(&s))
        })
        .map(|c| {
            check_node(
                c["id"].as_u64().unwrap(),
                c["check_suite"]["id"].as_u64(),
                None,
            )
        })
        .collect()
}

fn check_runs_page(total: usize, members: Vec<Value>) -> Value {
    json!({"total_count": total, "check_runs": members})
}

/// The check-suites count page for these check runs: one suite per
/// distinct `check_suite.id`.
fn check_suites_for(check_runs: &[Value]) -> Value {
    let ids: BTreeSet<u64> = check_runs
        .iter()
        .filter_map(|c| c["check_suite"]["id"].as_u64())
        .collect();
    check_suites_page(ids.len(), ids.into_iter().collect())
}

fn check_suites_page(total: usize, ids: Vec<u64>) -> Value {
    let members: Vec<Value> = ids.iter().map(|id| json!({"id": id})).collect();
    json!({"total_count": total, "check_suites": members})
}

fn status(context: &str, state: &str) -> Value {
    json!({"context": context, "state": state, "description": null, "target_url": null})
}

fn statuses_page(members: Vec<Value>) -> Value {
    json!({"state": "pending", "total_count": members.len(), "statuses": members, "sha": HEAD})
}

/// The fixture run's workflow, and the required workflow's own, the next
/// in the fixture's list.
const WORKFLOW_ID: u64 = 161_335;
const REQUIRED_WORKFLOW_ID: u64 = 161_336;

fn run(id: u64, head: &str, status: &str, conclusion: Value) -> Value {
    execution(id, 1, "2026-01-29T15:09:00Z", head, status, conclusion)
}

/// A run of the fixture workflow: `attempt` and `started` are what the
/// current-execution selection reads. Its check suite id is its run id and
/// its suite node `suite-{id}`; a `push` dispatch, as the documented reply
/// beside this file.
fn execution(
    id: u64,
    attempt: u64,
    started: &str,
    head: &str,
    status: &str,
    conclusion: Value,
) -> Value {
    json!({
        "id": id, "name": "CI", "path": ".github/workflows/ci.yml", "head_sha": head,
        "status": status, "conclusion": conclusion, "event": "push",
        "workflow_id": WORKFLOW_ID, "check_suite_id": id, "check_suite_node_id": suite_node_id(id),
        "run_attempt": attempt, "run_started_at": started, "updated_at": started,
    })
}

fn suite_node_id(run: u64) -> String {
    format!("suite-{run}")
}

/// A run of the required workflow's own file (`WORKFLOW_PATH`), the
/// candidate a `workflows` rule may bind; its proof is the node
/// `required_node` gives.
fn required_run(id: u64, attempt: u64, started: &str, status: &str, conclusion: Value) -> Value {
    with(
        with(
            execution(id, attempt, started, HEAD, status, conclusion),
            "path",
            json!(WORKFLOW_PATH),
        ),
        "workflow_id",
        json!(REQUIRED_WORKFLOW_ID),
    )
}

/// The workflow file a run executed, as its suite node proves it: the file
/// at `sha` in `repository`, readable by the viewer.
fn source_file(repository: &str, sha: &str) -> Value {
    json!({
        "path": WORKFLOW_PATH, "repositoryName": repository,
        "repositoryFileUrl": format!("https://github.com/{repository}/blob/{sha}/{WORKFLOW_PATH}"),
        "viewerCanReadRepository": true,
    })
}

/// The suite node of `run` (attempt `attempt`) with `file` as its executed
/// workflow file.
fn suite_node(run: u64, attempt: u64, file: Value) -> Value {
    json!({
        "id": suite_node_id(run), "databaseId": run,
        "workflowRun": {"databaseId": run, "runAttempt": attempt, "file": file},
    })
}

/// The fake's GraphQL answer: the nodes by id.
fn nodes(nodes: &[Value]) -> Value {
    let by_id: Map<String, Value> = nodes
        .iter()
        .map(|n| (n["id"].as_str().unwrap().to_owned(), n.clone()))
        .collect();
    json!({"nodes": by_id})
}

/// The source repository's documented reply, with the id the rule names.
fn repository(id: u64, full_name: &str) -> Value {
    json!({"id": id, "node_id": "R_kgDOAA", "name": full_name.rsplit('/').next().unwrap(), "full_name": full_name, "default_branch": "main"})
}

/// A bound required workflow in the green world: one proven run of
/// `WORKFLOW_PATH` at `WORKFLOW_SHA` in the source repository, its one
/// check run `request`, on the ref and in its suite's `latest` listing
/// alike, and the rule naming that definition.
fn bound_world() -> Github {
    let request = check_run_in(
        Some(700),
        9,
        json!("request"),
        "completed",
        json!("success"),
    );
    let mut gh = Github::green();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(1, vec![request.clone()]),
    )
    .answer(&suite_check_runs(700, 1), check_runs_page(1, vec![request]))
    .answer(&check_suites(HEAD, 1), check_suites_page(1, vec![700]))
    .answer(
        &runs(HEAD, 1),
        runs_page(vec![required_run(
            700,
            1,
            "2026-01-29T15:09:00Z",
            "completed",
            json!("success"),
        )]),
    )
    .answer(&rules(1), json!([workflows_rule(Some(WORKFLOW_SHA))]))
    .answer(&workflows(1), workflows_page(2, &["active", "active"]))
    .answer(
        GRAPHQL,
        nodes(&[suite_node(700, 1, source_file(SOURCE_REPO, WORKFLOW_SHA))]),
    )
    .answer(
        &source_repository(),
        repository(SOURCE_REPO_ID, SOURCE_REPO),
    );
    gh
}

/// `object` with `field` set to `value`.
fn with(mut object: Value, field: &str, value: Value) -> Value {
    object
        .as_object_mut()
        .unwrap()
        .insert(field.to_owned(), value);
    object
}

/// `object` without `field`.
fn without(mut object: Value, field: &str) -> Value {
    object.as_object_mut().unwrap().remove(field);
    object
}

fn runs_page(members: Vec<Value>) -> Value {
    runs_page_of(members.len(), members)
}

fn runs_page_of(total: usize, members: Vec<Value>) -> Value {
    json!({"total_count": total, "workflow_runs": members})
}

/// A workflows page whose members are the fixture workflow and the ids
/// after it, in the given states.
fn workflows_page(total: usize, states: &[&str]) -> Value {
    workflows_page_from(total, WORKFLOW_ID, states)
}

fn workflows_page_from(total: usize, first_id: u64, states: &[&str]) -> Value {
    let members: Vec<Value> = states
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let id = first_id + i as u64;
            json!({"id": id, "node_id": format!("W_{id}"), "name": if id == WORKFLOW_ID { "CI".to_owned() } else { format!("wf-{id}") }, "path": format!(".github/workflows/wf-{id}.yml"), "state": s})
        })
        .collect();
    json!({"total_count": total, "workflows": members})
}

fn protected(protected: bool, contexts: &[&str]) -> Value {
    json!({"name": BASE, "protected": protected, "protection": {"enabled": protected, "required_status_checks": {"contexts": contexts, "checks": []}}})
}

/// A protected base whose classic `required_status_checks` is `checks`
/// verbatim.
fn classic(checks: Value) -> Value {
    json!({"name": BASE, "protected": true, "protection": {"enabled": true, "required_status_checks": checks}})
}

fn status_checks_rule(contexts: &[&str]) -> Value {
    let checks: Vec<Value> = contexts.iter().map(|c| json!({"context": c})).collect();
    json!({"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": checks}})
}

/// A `workflows` rule; without `sha` the key is absent, as GitHub omits an
/// unpinned source.
fn workflows_rule(sha: Option<&str>) -> Value {
    let mut workflow =
        json!({"path": WORKFLOW_PATH, "repository_id": SOURCE_REPO_ID, "ref": "refs/heads/main"});
    if let Some(sha) = sha {
        workflow["sha"] = json!(sha);
    }
    json!({"type": "workflows", "parameters": {"workflows": [workflow]}})
}

// --- the fake GitHub ------------------------------------------------------------

/// One row's GitHub: the replies the fake answers by path, the log it
/// writes, and the item file the operation records on.
struct Github {
    dir: TempDir,
    replies: Map<String, Value>,
}

impl Github {
    /// No replies: every read is a failed request.
    fn empty() -> Self {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("workflow-state-KEN-4687.json"), ITEM).unwrap();
        Github {
            dir,
            replies: Map::new(),
        }
    }

    /// The documented replies beside this file: two passing check runs in
    /// one suite, no statuses, one completed CI run, no rules, an
    /// unprotected base with an empty protection block, one active
    /// workflow.
    fn green() -> Self {
        let mut gh = Github::empty();
        gh.answer(&check_runs(HEAD, 1), fixture("check-runs.json"))
            .answer(&check_suites(HEAD, 1), fixture("check-suites.json"))
            .answer(&statuses(HEAD, 1), fixture("status.json"))
            .answer(&runs(HEAD, 1), fixture("actions-runs.json"))
            .answer(&rules(1), fixture("rules.json"))
            .answer(&branch(), fixture("branch.json"))
            .answer(&workflows(1), fixture("workflows.json"));
        gh
    }

    /// Nothing on the head and nothing configured: the `none` route.
    fn bare() -> Self {
        let mut gh = Github::green();
        gh.answer(&check_runs(HEAD, 1), check_runs_page(0, vec![]))
            .answer(&check_suites(HEAD, 1), check_suites_page(0, vec![]))
            .answer(&statuses(HEAD, 1), statuses_page(vec![]))
            .answer(&runs(HEAD, 1), runs_page(vec![]))
            .answer(&workflows(1), workflows_page(0, &[]));
        gh
    }

    /// A recorded witness's replies (`fixtures/gh/witnesses/<name>.json`):
    /// the whole map the fake answers from, as one head's reads answered.
    fn recorded(name: &str) -> Self {
        let mut gh = Github::empty();
        gh.replies = fixture(&format!("witnesses/{name}.json"))
            .as_object()
            .unwrap()
            .clone();
        gh
    }

    fn answer(&mut self, path: &str, body: Value) -> &mut Self {
        self.replies.insert(path.to_owned(), json!({"body": body}));
        self
    }

    /// An answer that is not JSON.
    fn text(&mut self, path: &str, text: &str) -> &mut Self {
        self.replies.insert(path.to_owned(), json!({"text": text}));
        self
    }

    fn fail(&mut self, path: &str) -> &mut Self {
        self.replies.insert(
            path.to_owned(),
            json!({"text": "{\"message\":\"Server Error\"}", "exit": 1}),
        );
        self
    }

    /// A call that printed `body` and exited 1 with nothing on stderr: gh
    /// on an HTTP status above 299 whose body carries no error message
    /// (`api.go:553-557`), the failure's detail then the body it printed.
    fn failed_printing(&mut self, path: &str, body: Value) -> &mut Self {
        self.replies
            .insert(path.to_owned(), json!({"body": body, "exit": 1}));
        self
    }

    fn item(&self) -> PathBuf {
        self.dir.path().join("workflow-state-KEN-4687.json")
    }

    fn state(&self) -> Value {
        serde_json::from_str(&fs::read_to_string(self.item()).unwrap()).unwrap()
    }

    fn log(&self) -> Vec<String> {
        fs::read_to_string(self.dir.path().join("gh.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// The pull request `pr view` answers for `pr`: its head, base and
    /// state in gh's export, as the fake's `pr view N` entry.
    fn pull(&mut self, pr: u64, head: &str, base: &str, state: &str) -> &mut Self {
        self.answer(
            &format!("pr view {pr}"),
            json!({"headRefOid": head, "baseRefName": base, "state": state}),
        )
    }

    /// Run `verify-head` for `head` on the base as one call of the binary
    /// with the fake ahead of the inherited PATH.
    fn verify_head(&self, head: &str, required_only: bool) -> Output {
        self.verify_target(&["--item", "KEN-4687"], head, required_only)
    }

    fn verify_target(&self, target: &[&str], head: &str, required_only: bool) -> Output {
        self.op(
            target,
            json!({"op": "verify-head", "repo": REPO, "base": BASE, "head": head, "required_only": required_only}),
        )
    }

    /// Run `verify-pr` for `pr` as one call of the binary.
    fn verify_pr(&self, pr: u64, required_only: bool) -> Output {
        self.verify_pr_target(&["--item", "KEN-4687"], pr, required_only)
    }

    fn verify_pr_target(&self, target: &[&str], pr: u64, required_only: bool) -> Output {
        self.op(
            target,
            json!({"op": "verify-pr", "repo": REPO, "pr": pr, "required_only": required_only}),
        )
    }

    /// One call of the binary over `request`, the fake ahead of the
    /// inherited PATH, answering from this row's replies.
    fn op(&self, target: &[&str], request_body: Value) -> Output {
        let replies = self.dir.path().join("replies.json");
        fs::write(&replies, serde_json::to_vec(&self.replies).unwrap()).unwrap();
        let request = self.dir.path().join("request.json");
        fs::write(&request, request_body.to_string()).unwrap();
        support::isolated()
            .args(["--state-dir", &self.dir.path().display().to_string()])
            .arg("op")
            .args(target)
            .arg("--request")
            .arg(&request)
            .env("PATH", support::tool_path(&[fixtures().as_path()]))
            .env("GH_FAKE_REPLIES", &replies)
            .env("GH_FAKE_LOG", self.dir.path().join("gh.log"))
            .current_dir(self.dir.path())
            .output()
            .unwrap()
    }

    fn verify(&self, required_only: bool) -> Output {
        self.verify_head(HEAD, required_only)
    }
}

fn reply(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
        panic!(
            "no reply: {e}\nstdout={}\nstderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        )
    })
}

/// The result of a successful call.
fn ok_result(out: &Output) -> Value {
    assert!(
        out.status.success(),
        "exit {:?}: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stderr)
    );
    let reply = reply(out);
    assert_eq!(reply["ok"], true, "{reply}");
    reply["result"].clone()
}

type Reported = (String, String, String, String);

fn checks(result: &Value) -> Vec<Reported> {
    result["checks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            (
                c["name"].as_str().unwrap().to_owned(),
                c["source"].as_str().unwrap().to_owned(),
                c["state"].as_str().unwrap().to_owned(),
                c["bucket"].as_str().unwrap().to_owned(),
            )
        })
        .collect()
}

fn row(name: &str, source: &str, state: &str, bucket: &str) -> Reported {
    (name.into(), source.into(), state.into(), bucket.into())
}

/// The stable key a `pending` or `unreadable` reason starts with.
fn key(result: &Value) -> &str {
    result["reason"]
        .as_str()
        .unwrap()
        .split(' ')
        .next()
        .unwrap()
}

/// The one `pr view` line a `verify-pr` call writes to the log.
fn pr_view(pr: u64) -> String {
    format!("pr view {pr} --repo {REPO} --json headRefOid,baseRefName,state")
}

/// A `verify-pr` call's reads: the pull request by its number first, then
/// every read pinned to `head`, the head that answer named.
fn assert_pull_then_pinned(log: &[String], pr: u64, head: &str) {
    assert_eq!(log.first(), Some(&pr_view(pr)), "{log:?}");
    assert_pinned(&log[1..], head);
}

/// Every read named the pinned head or the base, a suite node or a
/// repository a proof named, and no pull request.
fn assert_pinned(log: &[String], head: &str) {
    assert!(!log.is_empty(), "no gh call");
    let repository_lookup = |line: &str| {
        line.strip_prefix("api repos/")
            .is_some_and(|name| name.split('/').count() == 2 && !name.contains(' '))
    };
    for line in log {
        assert!(
            line.starts_with("api repos/owner/repo/")
                || line.starts_with("api graphql ")
                || repository_lookup(line),
            "{line}"
        );
        assert!(!line.contains(" pr "), "{line}");
        if line.contains("/commits/") || line.contains("head_sha=") {
            assert!(line.contains(head), "{line}");
        }
        assert!(!line.contains(MOVED), "{line}");
    }
}

/// Which checks a row judges by: every check on the head, or the base's
/// required set under `required_only` with these rules (an empty list is
/// the flag with nothing named, which judges every check).
enum Scope {
    All,
    RequiredOnly(Vec<Value>),
}

/// One verdict row: the head's evidence and the answer, structured: the
/// status, the verdict, the pending cause key and the reported members.
struct Verdict {
    name: &'static str,
    check_runs: Vec<Value>,
    statuses: Vec<Value>,
    runs: Vec<Value>,
    scope: Scope,
    status: &'static str,
    verdict: Option<&'static str>,
    /// The reason's stable key on `pending`.
    cause: Option<&'static str>,
    checks: Vec<Reported>,
}

/// What a row expects of one call's answer: the status, the verdict, the
/// pending cause key and the reported members, with the record written
/// exactly when the verdict is final and every read pinned.
struct Answer {
    name: &'static str,
    status: &'static str,
    verdict: Option<&'static str>,
    cause: Option<&'static str>,
    checks: Vec<Reported>,
}

fn assert_answer(gh: &Github, result: &Value, a: &Answer) {
    assert_eq!(result["status"], a.status, "{}: {result}", a.name);
    assert_eq!(
        result["verdict"].as_str(),
        a.verdict,
        "{}: {result}",
        a.name
    );
    if let Some(cause) = a.cause {
        assert_eq!(key(result), cause, "{}: {result}", a.name);
    }
    assert_eq!(checks(result), a.checks, "{}: {result}", a.name);
    assert_eq!(
        result.get("recorded").is_some(),
        a.verdict.is_some(),
        "{}",
        a.name
    );
    assert_eq!(
        gh.state().get("verification").is_some(),
        a.verdict.is_some(),
        "{}",
        a.name
    );
    assert_pinned(&gh.log(), HEAD);
}

/// Run one verdict row against the green world and assert its answer.
fn assert_verdict(r: Verdict) {
    let mut gh = Github::green();
    let total = r.check_runs.len();
    let (required_only, rule_set) = match r.scope {
        Scope::All => (false, Vec::new()),
        Scope::RequiredOnly(rule_set) => (true, rule_set),
    };
    gh.answer(&check_suites(HEAD, 1), check_suites_for(&r.check_runs))
        .answer(GRAPHQL, nodes(&external_nodes(&r.check_runs, &r.runs)))
        .answer(&check_runs(HEAD, 1), check_runs_page(total, r.check_runs))
        .answer(&statuses(HEAD, 1), statuses_page(r.statuses))
        .answer(&runs(HEAD, 1), runs_page(r.runs))
        .answer(&rules(1), Value::Array(rule_set));
    let result = ok_result(&gh.verify(required_only));
    assert_answer(
        &gh,
        &result,
        &Answer {
            name: r.name,
            status: r.status,
            verdict: r.verdict,
            cause: r.cause,
            checks: r.checks,
        },
    );
}

/// A final verdict is recorded through `record-verification`
/// in the same call, and a later verdict replaces it. Without
/// `required_only` the base's rules and protection are not read; the
/// check-suites count is read beside the check runs, and the workflows
/// beside the runs, for the name each run's workflow carries. The two
/// documented check runs started alike, so the later-listed, higher id
/// is reported first.
#[test]
fn a_passing_head_is_complete_pass_and_recorded() {
    let gh = Github::green();
    let before = gh.state();
    assert!(before.get("verification").is_none());
    let result = ok_result(&gh.verify(false));
    assert_eq!(result["status"], "complete");
    assert_eq!(result["verdict"], "pass");
    assert_eq!(result["head"], HEAD);
    assert_eq!(result["repo"], REPO);
    assert_eq!(
        checks(&result),
        vec![
            row("test", "check-run", "success", "pass"),
            row("build", "check-run", "success", "pass"),
        ]
    );
    let recorded = &result["recorded"]["report"];
    assert_eq!(recorded["op"], "record-verification");
    assert_eq!(recorded["replaced"], false);
    assert_eq!(recorded["verdict"], "pass");
    let state = gh.state();
    let record = &state["verification"];
    assert_eq!(record["head"], HEAD);
    assert_eq!(record["verdict"], "pass");
    assert_eq!(record["source"], "verify-head");
    assert_eq!(record["reason"], result["reason"]);
    assert!(record["at"].as_str().unwrap().ends_with('Z'));
    let log = gh.log();
    assert_pinned(&log, HEAD);
    assert_eq!(
        log,
        vec![
            format!("api {}", check_runs(HEAD, 1)),
            format!("api {}", check_suites(HEAD, 1)),
            format!("api {}", statuses(HEAD, 1)),
            format!("api {}", runs(HEAD, 1)),
            format!("api {}", workflows(1)),
        ]
    );
    let again = ok_result(&gh.verify(false));
    assert_eq!(again["recorded"]["report"]["replaced"], true);
}

/// The rules the verdict pins beyond the recorded witnesses: the check
/// taxonomy, the wire's nullable run status, the empty head, the
/// skipped-check flag, the substantive events and the held failure's
/// relabel. The witnesses' own answers are the witness rows
/// (`the_recorded_witnesses_keep_the_legacy_verdict`).
#[test]
fn verdicts_follow_the_check_and_run_states() {
    let aggregate = |context: &str, state: &str, run_id: u64| {
        with(
            status(context, state),
            "target_url",
            json!(format!("https://github.com/{REPO}/actions/runs/{run_id}")),
        )
    };
    let event = |run: Value, event: &str| with(run, "event", json!(event));
    let rows = [
        Verdict {
            name: "a neutral check run is skipping beside a green sibling, which passes",
            check_runs: vec![
                check_run(json!("build"), "completed", json!("neutral")),
                check_run_in(
                    Some(SUITE),
                    10,
                    json!("test"),
                    "completed",
                    json!("success"),
                ),
            ],
            statuses: vec![],
            runs: vec![run(700, HEAD, "completed", json!("success"))],
            scope: Scope::All,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![
                row("build", "check-run", "neutral", "skipping"),
                row("test", "check-run", "success", "pass"),
            ],
        },
        Verdict {
            name: "a stale check run alone is pending, with no record",
            check_runs: vec![check_run(json!("build"), "completed", json!("stale"))],
            statuses: vec![],
            runs: vec![run(700, HEAD, "completed", json!("success"))],
            scope: Scope::All,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![row("build", "check-run", "stale", "pending")],
        },
        Verdict {
            name: "a startup-failed check run is a recorded failure",
            check_runs: vec![check_run(
                json!("build"),
                "completed",
                json!("startup_failure"),
            )],
            statuses: vec![],
            runs: vec![run(700, HEAD, "completed", json!("startup_failure"))],
            scope: Scope::All,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![row("build", "check-run", "startup_failure", "fail")],
        },
        Verdict {
            name: "a neutral Actions run fails no run",
            check_runs: vec![check_run(json!("build"), "completed", json!("success"))],
            statuses: vec![],
            runs: vec![run(700, HEAD, "completed", json!("neutral"))],
            scope: Scope::All,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Verdict {
            name: "a run whose status is null is not completed",
            check_runs: vec![check_run(json!("build"), "completed", json!("success"))],
            statuses: vec![],
            runs: vec![with(
                run(701, HEAD, "queued", Value::Null),
                "status",
                Value::Null,
            )],
            scope: Scope::All,
            status: "pending",
            verdict: None,
            cause: Some("actions-run-active"),
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Verdict {
            name: "no check and no run, not required-only, is not final",
            check_runs: vec![],
            statuses: vec![],
            runs: vec![],
            scope: Scope::All,
            status: "pending",
            verdict: None,
            cause: Some("checks-unregistered"),
            checks: vec![],
        },
        Verdict {
            name: "a skipped-only rollup without required_only never passes",
            check_runs: vec![check_run(json!("build"), "completed", json!("skipped"))],
            statuses: vec![],
            runs: vec![run(700, HEAD, "completed", json!("skipped"))],
            scope: Scope::All,
            status: "pending",
            verdict: None,
            cause: Some("skipped-only"),
            checks: vec![row("build", "check-run", "skipped", "skipping")],
        },
        Verdict {
            name: "a skipped-only rollup under required_only with an empty required set passes",
            check_runs: vec![check_run(json!("build"), "completed", json!("skipped"))],
            statuses: vec![],
            runs: vec![run(700, HEAD, "completed", json!("skipped"))],
            scope: Scope::RequiredOnly(vec![]),
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "skipped", "skipping")],
        },
        Verdict {
            name: "a newer successful push run on the pinned head supersedes an earlier failure of the same workflow",
            check_runs: vec![check_run_in(
                Some(701),
                10,
                json!("lint"),
                "completed",
                json!("success"),
            )],
            statuses: vec![aggregate("CI Required", "failure", 700)],
            runs: vec![
                event(run(700, HEAD, "completed", json!("failure")), "push"),
                event(
                    execution(
                        701,
                        1,
                        "2026-01-29T15:20:00Z",
                        HEAD,
                        "completed",
                        json!("success"),
                    ),
                    "push",
                ),
            ],
            scope: Scope::All,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("lint", "check-run", "success", "pass")],
        },
        Verdict {
            name: "a failure whose newer same-workflow execution is not substantive stays terminal",
            check_runs: vec![check_run_in(
                Some(701),
                10,
                json!("lint"),
                "completed",
                json!("success"),
            )],
            statuses: vec![aggregate("CI Required", "failure", 700)],
            runs: vec![
                event(run(700, HEAD, "completed", json!("failure")), "schedule"),
                event(
                    execution(
                        701,
                        1,
                        "2026-01-29T15:20:00Z",
                        HEAD,
                        "completed",
                        json!("success"),
                    ),
                    "schedule",
                ),
            ],
            scope: Scope::All,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("lint", "check-run", "success", "pass"),
                row("CI Required", "commit-status", "failure", "fail"),
            ],
        },
        Verdict {
            name: "a failed check held by its unfinished run is reported expected",
            check_runs: vec![check_run_in(
                Some(700),
                9,
                json!("build"),
                "completed",
                json!("failure"),
            )],
            statuses: vec![],
            runs: vec![run(700, HEAD, "in_progress", Value::Null)],
            scope: Scope::All,
            status: "pending",
            verdict: None,
            cause: Some("failed-run-active"),
            checks: vec![row("build", "check-run", "expected", "pending")],
        },
    ];
    for r in rows {
        assert_verdict(r);
    }
}

/// One recorded witness of the verdict: the answers one head's reads
/// gave, as one reply map under `fixtures/gh/witnesses/`, and the verdict
/// recorded over them under the recorded corrections. The row is named
/// for the defect it catches.
struct Witness {
    defect: &'static str,
    /// The reply map's name under `fixtures/gh/witnesses/`.
    fixture: &'static str,
    required_only: bool,
    status: &'static str,
    verdict: Option<&'static str>,
    /// The reason's stable key on `pending`.
    cause: Option<&'static str>,
    checks: Vec<Reported>,
}

/// The recorded verdict is the correctness floor. Each row is a recorded
/// witness: a fixture or incident head (superseded runs,
/// stale pre-approval failures, request-only rollups, rerun attempts and
/// newer siblings, required sets and bound workflows) or a reviewer's
/// counterexample (the suite join's omissions, the `latest` listing, gh's
/// slash-joined key, the order among equal or absent starts, the run-less
/// pick, the graph's null nodes and the startup-failure correction), with
/// the status, verdict, cause key and reported members recorded over the
/// same answers under the recorded corrections. A verdict that changes
/// here is one named correction.
#[test]
fn the_recorded_witnesses_keep_the_legacy_verdict() {
    let rows = [
        Witness {
            defect: "the cancelled jobs of a superseded run counted as failures",
            fixture: "superseded-run-cancelled-jobs",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![
                row("License Key Guard", "check-run", "success", "pass"),
                row("Changes", "check-run", "in_progress", "pending"),
            ],
        },
        Witness {
            defect: "a stale pre-approval failure read as terminal while the approved run is active",
            fixture: "stale-preapproval-active-approved",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![
                row("Build", "check-run", "in_progress", "pending"),
                row("CI Required", "commit-status", "failure", "fail"),
            ],
        },
        Witness {
            defect: "a pre-approval failure with no fresh substantive run left pending",
            fixture: "stale-preapproval-no-fresh-run",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("CI Gate Publisher", "check-run", "skipped", "skipping"),
                row("Changes", "check-run", "skipped", "skipping"),
                row("CI Required", "commit-status", "failure", "fail"),
            ],
        },
        Witness {
            defect: "a failed approved run left pending beside its stale failure",
            fixture: "stale-preapproval-fresh-failed",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("Build", "check-run", "failure", "fail"),
                row("CI Required", "commit-status", "failure", "fail"),
            ],
        },
        Witness {
            defect: "a lagging aggregate judged settled on the approved run's green jobs alone",
            fixture: "stale-preapproval-status-lag",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![
                row("Build", "check-run", "success", "pass"),
                row("CI Required", "commit-status", "expected", "pending"),
            ],
        },
        Witness {
            defect: "the replacement status published against the approved run read as stale",
            fixture: "approved-status-replaced",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![
                row("CI Gate Publisher", "check-run", "success", "pass"),
                row("Build", "check-run", "success", "pass"),
                row("CI Required", "commit-status", "success", "pass"),
            ],
        },
        Witness {
            defect: "a request-only rollup judged final while a substantive run is active",
            fixture: "request-only-run-active",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("actions-run-active"),
            checks: vec![row("request", "check-run", "success", "pass")],
        },
        Witness {
            defect: "a request-only rollup held after its substantive run completed",
            fixture: "request-only-run-completed",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("request", "check-run", "success", "pass")],
        },
        Witness {
            defect: "an active optional check holding a satisfied required set",
            fixture: "required-build-optional-docs-active",
            required_only: true,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Witness {
            defect: "a required context nothing reports yet read as satisfied",
            fixture: "required-build-missing",
            required_only: true,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![row("build", "required", "expected", "pending")],
        },
        Witness {
            defect: "a failed latest run hidden behind a request-only rollup",
            fixture: "failed-run-behind-request-only",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("request", "check-run", "success", "pass"),
                row(
                    ".github/workflows/wf-245303662.yml",
                    "workflow-run",
                    "failure",
                    "fail",
                ),
            ],
        },
        Witness {
            defect: "another workflow's newer success erasing a failure",
            fixture: "other-workflow-success-beside-failure",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("request", "check-run", "success", "pass"),
                row(
                    ".github/workflows/wf-245303662.yml",
                    "workflow-run",
                    "failure",
                    "fail",
                ),
            ],
        },
        Witness {
            defect: "a later skipped dispatch erasing a substantive failure",
            fixture: "skipped-dispatch-after-failure",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("request", "check-run", "success", "pass"),
                row(
                    ".github/workflows/wf-245303662.yml",
                    "workflow-run",
                    "failure",
                    "fail",
                ),
            ],
        },
        Witness {
            defect: "a successful rerun attempt of an older run id read as superseded by the failed newer dispatch",
            fixture: "rerun-attempt-success-older-id",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("request", "check-run", "success", "pass")],
        },
        Witness {
            defect: "a cancelled run's failure read as terminal while a newer sibling is active",
            fixture: "newer-sibling-active",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("failed-run-active"),
            checks: vec![
                row("CI Gate Publisher", "check-run", "expected", "pending"),
                row("Lint", "check-run", "expected", "pending"),
                row("Changes", "check-run", "expected", "pending"),
                row("CI Required", "commit-status", "expected", "pending"),
            ],
        },
        Witness {
            defect: "a cancelled run's frozen failures kept beside the newer sibling's success",
            fixture: "newer-sibling-success",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("CI Required", "commit-status", "success", "pass")],
        },
        Witness {
            defect: "a cancelled run with no newer sibling left pending",
            fixture: "cancelled-run-alone",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("CI Gate Publisher", "check-run", "failure", "fail"),
                row("Lint", "check-run", "cancelled", "fail"),
                row("Changes", "check-run", "cancelled", "fail"),
                row("CI Required", "commit-status", "failure", "fail"),
            ],
        },
        Witness {
            defect: "an in-flight attempt of an older run id not read as the current run",
            fixture: "rerun-attempt-active",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("failed-run-active"),
            checks: vec![
                row("CI Gate Publisher", "check-run", "expected", "pending"),
                row("Lint", "check-run", "expected", "pending"),
                row("Changes", "check-run", "expected", "pending"),
                row("CI Required", "commit-status", "expected", "pending"),
            ],
        },
        Witness {
            defect: "a later skipped job of one name read past for its earlier success",
            fixture: "later-skipped-job",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("skipped-only"),
            checks: vec![row("build", "check-run", "skipped", "skipping")],
        },
        Witness {
            defect: "a run-less check's later failure hidden by its earlier success",
            fixture: "runless-later-failure",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![row("external", "check-run", "failure", "fail")],
        },
        Witness {
            defect: "a failed newer run hidden by the older run's green jobs and aggregate",
            fixture: "rerun-incident",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("CI Gate Publisher", "check-run", "success", "pass"),
                row("build", "check-run", "success", "pass"),
                row("CI Required", "commit-status", "success", "pass"),
                row(
                    ".github/workflows/ci.yml",
                    "workflow-run",
                    "failure",
                    "fail",
                ),
            ],
        },
        Witness {
            defect: "a job's later failure hidden by its earlier success",
            fixture: "later-failed-job",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![row("build", "check-run", "failure", "fail")],
        },
        Witness {
            defect: "an older run's aggregate status scoped out with that run's job",
            fixture: "stale-aggregate-status",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![
                row("build", "check-run", "success", "pass"),
                row("CI Required", "commit-status", "success", "pass"),
            ],
        },
        Witness {
            defect: "a failed aggregate status targeting a job-less run dropped as stale",
            fixture: "failed-run-status-no-jobs",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("build", "check-run", "success", "pass"),
                row("CI Required", "commit-status", "failure", "fail"),
            ],
        },
        Witness {
            defect: "a bound job scoped out by a later-started execution read as satisfied",
            fixture: "required-two-runs-bound-dropped",
            required_only: true,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![row("request", "required", "expected", "pending")],
        },
        Witness {
            defect: "a required context's older-run aggregate scoped out as stale",
            fixture: "required-stale-aggregate",
            required_only: true,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("CI Required", "commit-status", "success", "pass")],
        },
        Witness {
            defect: "a bound successful run passing over its failed own check",
            fixture: "bound-run-failed-own-check",
            required_only: true,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![row("request", "check-run", "failure", "fail")],
        },
        Witness {
            defect: "an external failed check whose details URL names an active run read as terminal",
            fixture: "external-check-linking-active-run",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("failed-run-active"),
            checks: vec![row("build", "check-run", "expected", "pending")],
        },
        Witness {
            defect: "a bound job whose details URL is not its page matched by id",
            fixture: "bound-job-details-url-apart",
            required_only: true,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![row("request", "required", "expected", "pending")],
        },
        Witness {
            defect: "a startup-failed job bucketed pending beside a failed status targeting an unheld run",
            fixture: "startup-failure-beside-unheld-status",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![
                row("request", "check-run", "startup_failure", "fail"),
                row("CI Required", "commit-status", "failure", "fail"),
            ],
        },
        Witness {
            defect: "two workflow ids sharing a display name grouped apart",
            fixture: "two-workflow-ids-one-name",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Witness {
            defect: "null REST run names breaking the grouping of a later rerun",
            fixture: "rerun-null-run-names",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Witness {
            defect: "a bound suite's in-progress rerun read as its completed predecessor",
            fixture: "bound-suite-rerun-in-progress",
            required_only: true,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![row("request", "check-run", "in_progress", "pending")],
        },
        Witness {
            defect: "gh's slash-joined key not colliding `build/CI` under `tests` with `build` under `CI/tests`",
            fixture: "slash-key-collision",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Witness {
            defect: "two undated check runs of one name ordered by id before listing position",
            fixture: "undated-pair-listing-order",
            required_only: false,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            checks: vec![row("build", "check-run", "failure", "fail")],
        },
        Witness {
            defect: "a run-less status outranking the queued check sharing its name",
            fixture: "runless-status-beside-queued-check",
            required_only: false,
            status: "pending",
            verdict: None,
            cause: Some("checks-pending"),
            checks: vec![row("build", "check-run", "queued", "pending")],
        },
        Witness {
            defect: "a null node read by the detail while an unjoined sibling's node identifies the held run",
            fixture: "unjoined-sibling-node-names-run",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![
                row("test", "check-run", "success", "pass"),
                row("build", "check-run", "success", "pass"),
            ],
        },
        Witness {
            defect: "a run-less failed status outranking the successful check sharing its name",
            fixture: "runless-status-beside-success-check",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Witness {
            defect: "two check runs of one name started alike ordered by id before listing position",
            fixture: "dated-pair-listing-order",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![row("build", "check-run", "success", "pass")],
        },
        Witness {
            defect: "the older run's build selected in place of the newer run's build and skipped docs",
            fixture: "newer-run-build-and-skipped-docs",
            required_only: false,
            status: "complete",
            verdict: Some("pass"),
            cause: None,
            checks: vec![
                row("docs", "check-run", "skipped", "skipping"),
                row("build", "check-run", "success", "pass"),
            ],
        },
    ];
    for w in rows {
        let gh = Github::recorded(w.fixture);
        let result = ok_result(&gh.verify(w.required_only));
        assert_answer(
            &gh,
            &result,
            &Answer {
                name: w.defect,
                status: w.status,
                verdict: w.verdict,
                cause: w.cause,
                checks: w.checks,
            },
        );
    }
}

/// A failed job's run is read from its link, the check run's `details_url`,
/// with the suite as the agreeing second source. With the check's REST
/// `check_suite` null the suite is read through the check-run node and the
/// failure is still held by its in-progress run; a failed check whose link
/// names a run the head does not hold is unresolved and held while a
/// substantive run is in flight, and terminal once none is; a check with no
/// link at all in an external suite is a proved external failure, terminal at
/// once; a check with no link whose node names a run GitHub does not identify
/// (`databaseId` null) is unresolved, held while the push run is in flight,
/// and records nothing.
#[test]
fn a_failed_check_is_associated_through_its_link_and_held_while_unresolved() {
    let in_flight = run(700, HEAD, "in_progress", Value::Null);
    let settled = run(700, HEAD, "completed", json!("success"));
    let linked_to = |run: u64, suite: Value| {
        with(
            with(
                check_run_in(Some(700), 9, json!("build"), "completed", json!("failure")),
                "details_url",
                json!(format!(
                    "https://github.com/{REPO}/actions/runs/{run}/job/9"
                )),
            ),
            "check_suite",
            suite,
        )
    };
    let unlinked = |suite: Value| {
        with(
            with(
                with(
                    check_run_in(
                        Some(SUITE),
                        9,
                        json!("build"),
                        "completed",
                        json!("failure"),
                    ),
                    "details_url",
                    Value::Null,
                ),
                "html_url",
                Value::Null,
            ),
            "check_suite",
            suite,
        )
    };
    struct Row {
        name: &'static str,
        check: Value,
        node: Value,
        run: Value,
        status: &'static str,
        verdict: Option<&'static str>,
        cause: Option<&'static str>,
        state: &'static str,
    }
    let rows = [
        Row {
            name: "a null REST check_suite, the node naming the in-progress run",
            check: linked_to(700, Value::Null),
            node: check_node(9, Some(700), Some((json!(700), "CI"))),
            run: in_flight.clone(),
            status: "pending",
            verdict: None,
            cause: Some("failed-run-active"),
            state: "expected",
        },
        Row {
            name: "a null REST check_suite and null URLs, the node's run present but unidentified, a push run in flight",
            check: unlinked(Value::Null),
            node: check_node(9, Some(SUITE), Some((Value::Null, "CI"))),
            run: in_flight.clone(),
            status: "pending",
            verdict: None,
            cause: Some("failed-run-active"),
            state: "expected",
        },
        Row {
            name: "a link naming a run the head does not hold, a substantive run in flight",
            check: linked_to(999, json!({"id": 700})),
            node: Value::Null,
            run: in_flight,
            status: "pending",
            verdict: None,
            cause: Some("failed-run-active"),
            state: "expected",
        },
        Row {
            name: "a link naming a run the head does not hold, every run settled",
            check: linked_to(999, json!({"id": 700})),
            node: Value::Null,
            run: settled.clone(),
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            state: "failure",
        },
        Row {
            name: "no link, an external suite: a proved external failure",
            check: unlinked(json!({"id": SUITE})),
            node: check_node(9, Some(SUITE), None),
            run: settled,
            status: "complete",
            verdict: Some("fail"),
            cause: None,
            state: "failure",
        },
    ];
    for r in rows {
        let mut gh = Github::green();
        let nodes: Vec<Value> = [r.node].into_iter().filter(|n| !n.is_null()).collect();
        gh.answer(&check_runs(HEAD, 1), check_runs_page(1, vec![r.check]))
            .answer(&runs(HEAD, 1), runs_page(vec![r.run]))
            .answer(GRAPHQL, self::nodes(&nodes));
        let result = ok_result(&gh.verify(false));
        assert_eq!(result["status"], r.status, "{}: {result}", r.name);
        assert_eq!(
            result["verdict"].as_str(),
            r.verdict,
            "{}: {result}",
            r.name
        );
        if let Some(cause) = r.cause {
            assert_eq!(key(&result), cause, "{}: {result}", r.name);
        }
        let bucket = if r.state == "expected" {
            "pending"
        } else {
            "fail"
        };
        assert_eq!(
            checks(&result),
            vec![row("build", "check-run", r.state, bucket)],
            "{}: {result}",
            r.name
        );
        assert_eq!(
            gh.state().get("verification").is_some(),
            r.verdict.is_some(),
            "{}",
            r.name
        );
        assert_pinned(&gh.log(), HEAD);
    }
}

/// A run whose workflow the repository's list lacks is
/// judged under the workflow fetched by id, as gh fetches it, so a
/// successful historical run of a deleted workflow passes; membership in
/// the list is no prerequisite. The fetch's refusals are in the malformed
/// table.
/// A job's workflow name the repository's list lacks is
/// read through the graph, the check's `checkSuite.workflowRun.workflow.name`
/// (the route `gh pr checks` read every name by), before the REST detail
/// by id, which is read only when the graph does not resolve the check's
/// node; a 404 on the detail (gh `shared.go:460-470`, an organization
/// ruleset workflow) refuses nothing while the graph names it.
#[test]
fn a_workflow_the_list_lacks_is_named_through_the_graph_then_by_id() {
    let passes = |result: &Value| {
        assert_eq!(result["status"], "complete", "{result}");
        assert_eq!(result["verdict"], "pass");
        assert_eq!(
            checks(result),
            vec![
                row("test", "check-run", "success", "pass"),
                row("build", "check-run", "success", "pass"),
            ]
        );
    };
    let by_id = format!("api {}", workflow_by_id(424_242));
    let graph = |l: &String| l.starts_with("api graphql ") && l.contains("MDg6Q2hlY2tSdW40");

    // The graph names it; the detail answers 404 and is never asked.
    let mut gh = Github::green();
    gh.answer(&runs(HEAD, 1), unlisted_run())
        .answer(GRAPHQL, nodes(&fixture_check_nodes(700, "Old CI")));
    passes(&ok_result(&gh.verify(false)));
    let log = gh.log();
    assert_pinned(&log, HEAD);
    assert!(log.iter().any(graph), "{log:?}");
    assert!(!log.contains(&by_id), "{log:?}");

    // The graph does not resolve the check runs' nodes; the detail by id
    // answers, after the graph was asked.
    let mut gh = Github::green();
    gh.answer(&runs(HEAD, 1), unlisted_run())
        .answer(GRAPHQL, nodes(&[]))
        .answer(&workflow_by_id(424_242), workflow_object(424_242, "Old CI"));
    passes(&ok_result(&gh.verify(false)));
    let log = gh.log();
    assert_pinned(&log, HEAD);
    let graph_at = log.iter().position(graph);
    let by_id_at = log.iter().position(|l| *l == by_id);
    assert!(
        graph_at.is_some() && by_id_at.is_some() && graph_at < by_id_at,
        "{log:?}"
    );

    // The graph request fails: a failed route for check runs REST already
    // joined to the run, so the detail by id is still tried and names it.
    let mut gh = Github::green();
    gh.answer(&runs(HEAD, 1), unlisted_run())
        .fail(GRAPHQL)
        .answer(&workflow_by_id(424_242), workflow_object(424_242, "Old CI"));
    passes(&ok_result(&gh.verify(false)));
    let log = gh.log();
    assert_pinned(&log, HEAD);
    let graph_at = log.iter().position(graph);
    let by_id_at = log.iter().position(|l| *l == by_id);
    assert!(
        graph_at.is_some() && by_id_at.is_some() && graph_at < by_id_at,
        "{log:?}"
    );

    // The graph call fails having printed the complete answer with no
    // errors: its output is admitted through no error, so this is a failed
    // route for check runs REST already joined, and the detail by id is
    // tried and names it, after the graph was asked.
    let mut gh = Github::green();
    gh.answer(&runs(HEAD, 1), unlisted_run())
        .failed_printing(
            GRAPHQL,
            json!({"data": {"nodes": fixture_check_nodes(700, "Old CI")}}),
        )
        .answer(&workflow_by_id(424_242), workflow_object(424_242, "Old CI"));
    passes(&ok_result(&gh.verify(false)));
    let log = gh.log();
    assert_pinned(&log, HEAD);
    let graph_at = log.iter().position(graph);
    let by_id_at = log.iter().position(|l| *l == by_id);
    assert!(
        graph_at.is_some() && by_id_at.is_some() && graph_at < by_id_at,
        "{log:?}"
    );

    // GitHub cannot resolve one check's node and says so with a field
    // error at its path, a reply gh prints with a nonzero exit (the fake
    // exits 1 on it as gh does); the sibling node in the same reply names
    // the workflow, so the detail, answering 404, is never asked.
    let mut gh = Github::green();
    let fixture_nodes = fixture_check_nodes(700, "Old CI");
    let errored = fixture_nodes[0]["id"].clone();
    gh.answer(&runs(HEAD, 1), unlisted_run()).answer(
        GRAPHQL,
        with(nodes(&fixture_nodes[1..]), "errored", json!([errored])),
    );
    passes(&ok_result(&gh.verify(false)));
    let log = gh.log();
    assert_pinned(&log, HEAD);
    assert!(log.iter().any(graph), "{log:?}");
    assert!(!log.contains(&by_id), "{log:?}");
}

/// Under `required_only` the base's named contexts alone decide; a context
/// no check reports yet is expected, and a red optional check is not a
/// failure.
#[test]
fn required_only_judges_the_named_contexts_alone() {
    let mut gh = Github::green();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(
            2,
            vec![
                check_run(json!("build"), "completed", json!("success")),
                check_run(json!("lint"), "completed", json!("failure")),
            ],
        ),
    )
    .answer(&rules(1), json!([status_checks_rule(&["build"])]));
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "pass");
    assert_eq!(
        checks(&result),
        vec![row("build", "check-run", "success", "pass")]
    );
    assert_pinned(&gh.log(), HEAD);

    // A classic protection context not on the head yet.
    let mut gh = Github::green();
    gh.answer(&branch(), protected(true, &["build", "deploy"]));
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(key(&result), "checks-pending");
    assert_eq!(
        checks(&result),
        vec![
            row("build", "check-run", "success", "pass"),
            row("deploy", "required", "expected", "pending"),
        ]
    );
    assert!(gh.state().get("verification").is_none());
}

/// `none` holds only once every absence probe was read to its
/// last page; a later page that says CI exists keeps it off.
#[test]
fn none_needs_every_absence_probe_read_to_its_last_page() {
    let disabled = ["disabled_manually"; 100];
    let mut gh = Github::bare();
    gh.answer(&workflows(1), workflows_page(150, &disabled))
        .answer(
            &workflows(2),
            workflows_page_from(150, WORKFLOW_ID + 100, &disabled[..50]),
        );
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "none");
    assert_eq!(result["checks"], json!([]));
    assert_eq!(gh.state()["verification"]["verdict"], "none");
    let log = gh.log();
    assert_pinned(&log, HEAD);
    for read in [
        check_runs(HEAD, 1),
        check_suites(HEAD, 1),
        statuses(HEAD, 1),
        runs(HEAD, 1),
        rules(1),
        branch(),
        workflows(1),
        workflows(2),
    ] {
        assert!(
            log.contains(&format!("api {read}")),
            "{read} not in {log:?}"
        );
    }
    assert!(!log.contains(&format!("api {}", workflows(3))), "{log:?}");

    struct Row {
        name: &'static str,
        set: fn(&mut Github),
    }
    let rows = [
        Row {
            name: "an active workflow on the second page",
            set: |gh| {
                let disabled = ["disabled_manually"; 100];
                gh.answer(&workflows(1), workflows_page(101, &disabled))
                    .answer(
                        &workflows(2),
                        workflows_page_from(101, WORKFLOW_ID + 100, &["active"]),
                    );
            },
        },
        Row {
            name: "a protected base",
            set: |gh| {
                gh.answer(&branch(), protected(true, &[]));
            },
        },
        Row {
            name: "a gating rule that names no context",
            set: |gh| {
                gh.answer(&rules(1), json!([status_checks_rule(&[])]));
            },
        },
        Row {
            name: "a run on the head",
            set: |gh| {
                gh.answer(
                    &runs(HEAD, 1),
                    runs_page(vec![run(702, HEAD, "completed", json!("success"))]),
                )
                .answer(&workflows(1), workflows_page(1, &["disabled_manually"]));
            },
        },
    ];
    for r in rows {
        let mut gh = Github::bare();
        (r.set)(&mut gh);
        let result = ok_result(&gh.verify(true));
        assert_eq!(result["status"], "pending", "{}: {result}", r.name);
        assert_eq!(key(&result), "checks-unregistered", "{}: {result}", r.name);
        assert!(gh.state().get("verification").is_none(), "{}", r.name);
    }
}

/// A reply outside the documented shape or value set, a page set that does
/// not add up, a collection at its endpoint's cap and a failed request
/// each end `unreadable` with the endpoint's cause, never a verdict,
/// whether or not the selection would have discarded the malformed
/// member. The rows cover malformed replies, the Actions replies, the
/// snapshot's own, absent or null required fields, present nulls on
/// fields documented optional and not nullable, and discarded members,
/// non-object parameters and caps.
#[test]
fn malformed_replies_are_unreadable_with_their_cause() {
    for r in malformed_rows() {
        assert_unreadable(r);
    }
}

/// One malformed reply: how to plant it in the green world, its cause, and
/// for a failed call the detail where the row fixes it: the line the fake
/// wrote to stderr, as gh writes `gh: <message>` for a reply carrying
/// errors (`api.go:557`), which the transport takes before the body it
/// printed; `None` asserts a non-empty detail alone.
struct Malformed {
    name: &'static str,
    required_only: bool,
    set: fn(&mut Github),
    cause: &'static str,
    detail: Option<&'static str>,
}

/// The malformed replies, in the order the reports found them.
fn malformed_rows() -> Vec<Malformed> {
    vec![
        Malformed {
            name: "a check run without a name",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        1,
                        vec![check_run(Value::Null, "completed", json!("success"))],
                    ),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a check run with an undocumented conclusion",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        1,
                        vec![check_run(json!("build"), "completed", json!("mystery"))],
                    ),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a completed check run without a conclusion",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(1, vec![check_run(json!("build"), "completed", Value::Null)]),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a check run with an undocumented status",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(1, vec![check_run(json!("build"), "weird", Value::Null)]),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a check-runs page set whose total disagrees",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        3,
                        vec![
                            check_run(json!("build"), "completed", json!("success")),
                            check_run(json!("test"), "completed", json!("success")),
                        ],
                    ),
                )
                .answer(&check_runs(HEAD, 2), check_runs_page(3, vec![]));
            },
            cause: "check-runs-total-mismatch",
            detail: None,
        },
        Malformed {
            name: "a commit status with an undocumented state",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &statuses(HEAD, 1),
                    statuses_page(vec![status("external", "weird")]),
                );
            },
            cause: "statuses-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run with an undocumented conclusion",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &runs(HEAD, 1),
                    runs_page(vec![run(700, HEAD, "completed", json!("mystery"))]),
                );
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a completed Actions run without a conclusion",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &runs(HEAD, 1),
                    runs_page(vec![run(700, HEAD, "completed", Value::Null)]),
                );
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run with an undocumented status",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &runs(HEAD, 1),
                    runs_page(vec![run(700, HEAD, "weird", Value::Null)]),
                );
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run of another head",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &runs(HEAD, 1),
                    runs_page(vec![run(700, MOVED, "completed", json!("success"))]),
                );
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "rules {}",
            required_only: true,
            set: |gh| {
                gh.answer(&rules(1), json!({}));
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a required_status_checks rule without its parameters",
            required_only: true,
            set: |gh| {
                gh.answer(
                    &rules(1),
                    json!([{"type": "required_status_checks", "parameters": {}}]),
                );
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "rules [null]",
            required_only: true,
            set: |gh| {
                gh.answer(&rules(1), json!([null]));
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a rule of an undocumented type",
            required_only: true,
            set: |gh| {
                gh.answer(&rules(1), json!([{"type": "mystery"}]));
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a branch answer whose protection is null",
            required_only: true,
            set: |gh| {
                gh.answer(
                    &branch(),
                    json!({"name": "main", "protected": false, "protection": null}),
                );
            },
            cause: "protection-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a branch answer without a protection object",
            required_only: true,
            set: |gh| {
                gh.answer(&branch(), json!({"name": "main", "protected": false}));
            },
            cause: "protection-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a workflow member without a readable state",
            required_only: true,
            set: |gh| {
                gh.answer(&check_runs(HEAD, 1), check_runs_page(0, vec![]))
                    .answer(&runs(HEAD, 1), runs_page(vec![]))
                    .answer(
                        &workflows(1),
                        json!({"total_count": 1, "workflows": [null]}),
                    );
            },
            cause: "workflows-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a workflows page set whose total disagrees",
            required_only: true,
            set: |gh| {
                gh.answer(&check_runs(HEAD, 1), check_runs_page(0, vec![]))
                    .answer(&runs(HEAD, 1), runs_page(vec![]))
                    .answer(&workflows(1), workflows_page(2, &["disabled_manually"]))
                    .answer(&workflows(2), workflows_page_from(2, WORKFLOW_ID + 1, &[]));
            },
            cause: "workflows-total-mismatch",
            detail: None,
        },
        // A required field that is absent or null is not an
        // empty requirement or an admissible member.
        Malformed {
            name: "classic protection whose required_status_checks is {}",
            required_only: true,
            set: |gh| {
                gh.answer(&branch(), classic(json!({})));
            },
            cause: "protection-response-invalid",
            detail: None,
        },
        Malformed {
            name: "classic protection with only checks: []",
            required_only: true,
            set: |gh| {
                gh.answer(&branch(), classic(json!({"checks": []})));
            },
            cause: "protection-response-invalid",
            detail: None,
        },
        Malformed {
            name: "classic protection with only contexts: []",
            required_only: true,
            set: |gh| {
                gh.answer(&branch(), classic(json!({"contexts": []})));
            },
            cause: "protection-response-invalid",
            detail: None,
        },
        Malformed {
            name: "classic protection whose required_status_checks is null",
            required_only: true,
            set: |gh| {
                gh.answer(&branch(), classic(Value::Null));
            },
            cause: "protection-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a queued check run without a conclusion key",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        2,
                        vec![
                            check_run(json!("build"), "completed", json!("success")),
                            without(
                                check_run(json!("test"), "queued", Value::Null),
                                "conclusion",
                            ),
                        ],
                    ),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a check run without a check_suite key",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        1,
                        vec![without(
                            check_run(json!("build"), "completed", json!("success")),
                            "check_suite",
                        )],
                    ),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a check run without a started_at key",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        1,
                        vec![without(
                            check_run(json!("build"), "completed", json!("success")),
                            "started_at",
                        )],
                    ),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a required workflow without its repository_id",
            required_only: true,
            set: |gh| {
                gh.answer(
                    &rules(1),
                    json!([{"type": "workflows", "parameters": {"workflows": [{"path": WORKFLOW_PATH, "ref": "refs/heads/main", "sha": WORKFLOW_SHA}]}}]),
                );
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a queued Actions run without a conclusion key",
            required_only: false,
            set: |gh| {
                let queued = without(run(700, HEAD, "queued", Value::Null), "conclusion");
                gh.answer(&runs(HEAD, 1), runs_page(vec![queued]));
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run without its workflow_id",
            required_only: false,
            set: |gh| {
                let unowned = without(run(700, HEAD, "completed", json!("success")), "workflow_id");
                gh.answer(&runs(HEAD, 1), runs_page(vec![unowned]));
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run whose check_suite_node_id is null",
            required_only: false,
            set: |gh| {
                let odd = with(
                    run(700, HEAD, "completed", json!("success")),
                    "check_suite_node_id",
                    Value::Null,
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![odd]));
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a check run without an html_url key",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        1,
                        vec![without(
                            check_run(json!("build"), "completed", json!("success")),
                            "html_url",
                        )],
                    ),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        // The binding proof's own replies refuse like
        // every other: a nodes answer without its data (gh exits nonzero
        // on every reply carrying errors, so its cause is the failed
        // call's, the line it wrote to stderr), one without its nodes, a
        // repository answer for another name, and failed requests. The one
        // reply carrying errors that is read, a field error at a node's
        // own path, leaves the candidate unproven instead (the binding
        // test's unproven rows). A failed call that printed a complete,
        // error-free answer is read through no error: its output is not
        // admitted, and its failure is the cause with what it printed.
        Malformed {
            name: "a suite-nodes answer carrying errors",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.answer(
                    GRAPHQL,
                    json!({"data": null, "errors": [{"message": "Something went wrong"}]}),
                );
            },
            cause: "workflow-files-read-failed",
            detail: Some("gh: Something went wrong"),
        },
        Malformed {
            name: "a failed suite-nodes call that printed the complete answer with no errors",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.failed_printing(
                    GRAPHQL,
                    json!({"data": {"nodes": [suite_node(700, 1, source_file(SOURCE_REPO, WORKFLOW_SHA))]}}),
                );
            },
            cause: "workflow-files-read-failed",
            detail: None,
        },
        Malformed {
            name: "a failed suite-nodes call that printed the complete answer with an empty errors list",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.failed_printing(
                    GRAPHQL,
                    json!({"data": {"nodes": [suite_node(700, 1, source_file(SOURCE_REPO, WORKFLOW_SHA))]}, "errors": []}),
                );
            },
            cause: "workflow-files-read-failed",
            detail: None,
        },
        Malformed {
            name: "a suite-nodes answer whose nodes are not an array",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.answer(GRAPHQL, json!({"data": {"nodes": {}}}));
            },
            cause: "workflow-files-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a suite node whose runAttempt is null",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                let mut node = suite_node(700, 1, source_file(SOURCE_REPO, WORKFLOW_SHA));
                node["workflowRun"]["runAttempt"] = Value::Null;
                gh.answer(GRAPHQL, nodes(&[node]));
            },
            cause: "workflow-files-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a failed suite-nodes request",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.fail(GRAPHQL);
            },
            cause: "workflow-files-read-failed",
            detail: None,
        },
        Malformed {
            name: "a source repository answer for another name",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.answer(
                    &source_repository(),
                    repository(SOURCE_REPO_ID, "owner/renamed"),
                );
            },
            cause: "source-repository-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a source repository answer without its id",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.answer(&source_repository(), json!({"full_name": SOURCE_REPO}));
            },
            cause: "source-repository-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a failed source repository request",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.fail(&source_repository());
            },
            cause: "source-repository-read-failed",
            detail: None,
        },
        // A present null on a field documented optional and not nullable
        // is not the reading for omission.
        Malformed {
            name: "an Actions run whose run_attempt is null",
            required_only: false,
            set: |gh| {
                let odd = with(
                    run(700, HEAD, "completed", json!("success")),
                    "run_attempt",
                    Value::Null,
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![odd]));
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run whose run_started_at is null",
            required_only: false,
            set: |gh| {
                let odd = with(
                    run(700, HEAD, "completed", json!("success")),
                    "run_started_at",
                    Value::Null,
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![odd]));
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run whose check_suite_id is null",
            required_only: false,
            set: |gh| {
                let odd = with(
                    run(700, HEAD, "completed", json!("success")),
                    "check_suite_id",
                    Value::Null,
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![odd]));
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run without its event",
            required_only: false,
            set: |gh| {
                let odd = without(run(700, HEAD, "completed", json!("success")), "event");
                gh.answer(&runs(HEAD, 1), runs_page(vec![odd]));
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a required workflow whose sha is null",
            required_only: true,
            set: |gh| {
                let mut rule = workflows_rule(None);
                rule["parameters"]["workflows"][0]["sha"] = Value::Null;
                gh.answer(&rules(1), json!([rule]));
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a rule whose parameters are null",
            required_only: true,
            set: |gh| {
                gh.answer(&rules(1), json!([{"type": "creation", "parameters": null}]));
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        // A member the selection would discard is validated
        // first; a declared object is an object for every kind; a
        // collection at its endpoint's cap is not complete.
        Malformed {
            name: "a discarded check run of a re-run attempt whose conclusion is null",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_runs(HEAD, 1),
                    check_runs_page(
                        2,
                        vec![
                            check_run_in(Some(SUITE), 9, json!("build"), "completed", Value::Null),
                            check_run_in(
                                Some(SUITE),
                                12,
                                json!("build"),
                                "completed",
                                json!("success"),
                            ),
                        ],
                    ),
                );
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an older Actions run the selection would drop whose conclusion is null",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &runs(HEAD, 1),
                    runs_page(vec![
                        run(700, HEAD, "completed", Value::Null),
                        execution(
                            701,
                            1,
                            "2026-01-29T15:20:00Z",
                            HEAD,
                            "completed",
                            json!("success"),
                        ),
                    ]),
                );
            },
            cause: "actions-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a rule whose parameters are an array",
            required_only: true,
            set: |gh| {
                gh.answer(
                    &rules(1),
                    json!([{"type": "code_quality", "parameters": []}, status_checks_rule(&["build"])]),
                );
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a rule whose parameters are a string",
            required_only: true,
            set: |gh| {
                gh.answer(&rules(1), json!([{"type": "creation", "parameters": "x"}]));
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a rule whose parameters are a number",
            required_only: true,
            set: |gh| {
                gh.answer(
                    &rules(1),
                    json!([{"type": "required_status_checks", "parameters": 7}]),
                );
            },
            cause: "rules-response-invalid",
            detail: None,
        },
        Malformed {
            name: "an Actions run set at the search cap",
            required_only: false,
            set: |gh| {
                for p in 1..=10u64 {
                    let members: Vec<Value> = (0..100u64)
                        .map(|i| run(10_000 + p * 100 + i, HEAD, "completed", json!("success")))
                        .collect();
                    gh.answer(&runs(HEAD, p as usize), runs_page_of(1000, members));
                }
            },
            cause: "actions-runs-capped",
            detail: None,
        },
        Malformed {
            name: "a head whose check suites reach the endpoint's cap",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &check_suites(HEAD, 1),
                    check_suites_page(1000, (1..=100).collect()),
                );
            },
            cause: "check-runs-capped",
            detail: None,
        },
        Malformed {
            name: "a check-suites count answer without its total",
            required_only: false,
            set: |gh| {
                gh.answer(&check_suites(HEAD, 1), json!({"check_suites": [{"id": 5}]}));
            },
            cause: "check-suites-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a failed check-suites count read",
            required_only: false,
            set: |gh| {
                gh.fail(&check_suites(HEAD, 1));
            },
            cause: "check-suites-read-failed",
            detail: None,
        },
        Malformed {
            name: "a check-runs answer that is not JSON",
            required_only: false,
            set: |gh| {
                gh.text(&check_runs(HEAD, 1), "<html>502</html>");
            },
            cause: "check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a failed check-runs request",
            required_only: false,
            set: |gh| {
                gh.fail(&check_runs(HEAD, 1));
            },
            cause: "check-runs-read-failed",
            detail: None,
        },
        Malformed {
            name: "a check-runs request that answered nothing",
            required_only: false,
            set: |gh| {
                gh.text(&check_runs(HEAD, 1), "\n");
            },
            cause: "check-runs-read-failed",
            detail: None,
        },
        Malformed {
            name: "a failed rules request",
            required_only: true,
            set: |gh| {
                gh.fail(&rules(1));
            },
            cause: "rules-read-failed",
            detail: None,
        },
        Malformed {
            name: "a failed protection request",
            required_only: true,
            set: |gh| {
                gh.fail(&branch());
            },
            cause: "protection-read-failed",
            detail: None,
        },
        // The check-run nodes read, made for a check
        // whose suite no run on the head carries, refuses like every
        // other; a run whose workflow the repository's list lacks is not
        // the documented answer.
        Malformed {
            name: "a check-run nodes answer carrying errors",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), runs_page(vec![]))
                    .answer(GRAPHQL, json!({"data": null, "errors": [{"message": "x"}]}));
            },
            cause: "check-run-suites-read-failed",
            detail: Some("gh: x"),
        },
        // gh prints a reply carrying errors and exits nonzero; an error at
        // a node's own path leaves that node null and the reply readable
        // through that exit, and an error at any other path, or beside a
        // present node, leaves the call's failure as the cause. A failed
        // call that printed a complete, error-free answer is read through
        // no error, so for an unjoined check nothing names its suite.
        Malformed {
            name: "a check-run nodes answer whose error names a path other than a node",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), runs_page(vec![])).answer(
                    GRAPHQL,
                    json!({"data": {"nodes": [null, null]}, "errors": [{"path": ["nodes", 0, "checkSuite"], "message": "x"}]}),
                );
            },
            cause: "check-run-suites-read-failed",
            detail: Some("gh: x"),
        },
        Malformed {
            name: "a check-run nodes answer whose error names a present node",
            required_only: false,
            set: |gh| {
                let nodes = external_nodes(
                    fixture("check-runs.json")["check_runs"].as_array().unwrap(),
                    &[],
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![])).answer(
                    GRAPHQL,
                    json!({"data": {"nodes": nodes}, "errors": [{"path": ["nodes", 0], "message": "x"}]}),
                );
            },
            cause: "check-run-suites-read-failed",
            detail: Some("gh: x"),
        },
        Malformed {
            name: "a failed check-run nodes call that printed the complete answer with no errors",
            required_only: false,
            set: |gh| {
                let nodes = external_nodes(
                    fixture("check-runs.json")["check_runs"].as_array().unwrap(),
                    &[],
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![]))
                    .failed_printing(GRAPHQL, json!({"data": {"nodes": nodes}}));
            },
            cause: "check-run-suites-read-failed",
            detail: None,
        },
        Malformed {
            name: "a null check-run node for a listed check run",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), runs_page(vec![]))
                    .answer(GRAPHQL, nodes(&[]));
            },
            cause: "check-run-suites-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a failed check-run nodes request",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), runs_page(vec![])).fail(GRAPHQL);
            },
            cause: "check-run-suites-read-failed",
            detail: None,
        },
        // A job's workflow name the list lacks is read through the graph,
        // then by id; the detail is reached once the graph did not resolve
        // the check's node or the graph request failed, and a detail that
        // fails or answers another shape leaves the name unreadable by every
        // route.
        Malformed {
            name: "a joined check run whose workflow the list lacks, its node unresolved and the fetch by id failing",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), unlisted_run())
                    .answer(GRAPHQL, nodes(&[]));
            },
            cause: "workflow-read-failed",
            detail: None,
        },
        Malformed {
            name: "a joined check run whose workflow the list lacks, the graph request and the fetch by id both failing",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), unlisted_run()).fail(GRAPHQL);
            },
            cause: "workflow-read-failed",
            detail: None,
        },
        Malformed {
            name: "a joined check run whose workflow the list lacks, the graph answer carrying an error at another path and the fetch by id failing",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), unlisted_run()).answer(
                    GRAPHQL,
                    json!({"data": {"nodes": [null, null]}, "errors": [{"path": ["nodes", 0, "checkSuite"], "message": "x"}]}),
                );
            },
            cause: "workflow-read-failed",
            detail: None,
        },
        Malformed {
            name: "a workflow fetched by id without its name",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), unlisted_run())
                    .answer(GRAPHQL, nodes(&[]))
                    .answer(
                        &workflow_by_id(424_242),
                        without(workflow_object(424_242, "Old CI"), "name"),
                    );
            },
            cause: "workflow-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a workflow fetched by id naming another id",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), unlisted_run())
                    .answer(GRAPHQL, nodes(&[]))
                    .answer(&workflow_by_id(424_242), workflow_object(424_243, "Old CI"));
            },
            cause: "workflow-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a joined check run whose workflow the list lacks and whose node's suite names no run",
            required_only: false,
            set: |gh| {
                gh.answer(&runs(HEAD, 1), unlisted_run()).answer(
                    GRAPHQL,
                    nodes(
                        &fixture_check_nodes(700, "Old CI")
                            .into_iter()
                            .map(|n| with(n, "checkSuite", json!({"workflowRun": null})))
                            .collect::<Vec<_>>(),
                    ),
                );
            },
            cause: "check-run-suites-response-invalid",
            detail: None,
        },
        // The suite read of a bound run refuses like
        // every other collection; its members decode as check runs.
        Malformed {
            name: "a suite check run without a name",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.answer(
                    &suite_check_runs(700, 1),
                    check_runs_page(
                        1,
                        vec![check_run_in(
                            Some(700),
                            9,
                            Value::Null,
                            "completed",
                            json!("success"),
                        )],
                    ),
                );
            },
            cause: "suite-check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a completed suite check run without a conclusion",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.answer(
                    &suite_check_runs(700, 1),
                    check_runs_page(
                        1,
                        vec![check_run_in(
                            Some(700),
                            9,
                            json!("request"),
                            "completed",
                            Value::Null,
                        )],
                    ),
                );
            },
            cause: "suite-check-runs-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a suite check-runs page set whose total disagrees",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.answer(&suite_check_runs(700, 1), check_runs_page(2, vec![]));
            },
            cause: "suite-check-runs-total-mismatch",
            detail: None,
        },
        Malformed {
            name: "a failed suite check-runs request",
            required_only: true,
            set: |gh| {
                *gh = bound_world();
                gh.fail(&suite_check_runs(700, 1));
            },
            cause: "suite-check-runs-read-failed",
            detail: None,
        },
        Malformed {
            name: "a workflow member without its name",
            required_only: false,
            set: |gh| {
                gh.answer(
                    &workflows(1),
                    json!({"total_count": 1, "workflows": [{"id": WORKFLOW_ID, "state": "active"}]}),
                );
            },
            cause: "workflows-response-invalid",
            detail: None,
        },
        Malformed {
            name: "a second workflows page that fails",
            required_only: true,
            set: |gh| {
                let disabled = ["disabled_manually"; 100];
                gh.answer(&check_runs(HEAD, 1), check_runs_page(0, vec![]))
                    .answer(&runs(HEAD, 1), runs_page(vec![]))
                    .answer(&workflows(1), workflows_page(101, &disabled))
                    .fail(&workflows(2));
            },
            cause: "workflows-read-failed",
            detail: None,
        },
    ]
}

/// A malformed reply ends `unreadable` with its cause: no verdict, no
/// record, no reported check, the item untouched, every read pinned.
fn assert_unreadable(r: Malformed) {
    let mut gh = Github::green();
    (r.set)(&mut gh);
    let before = fs::read(gh.item()).unwrap();
    let result = ok_result(&gh.verify(r.required_only));
    assert_eq!(result["status"], "unreadable", "{}: {result}", r.name);
    assert_eq!(result["reason"], r.cause, "{}: {result}", r.name);
    assert!(result.get("verdict").is_none(), "{}: {result}", r.name);
    assert!(result.get("recorded").is_none(), "{}: {result}", r.name);
    assert_eq!(result["checks"], json!([]), "{}", r.name);
    match r.detail {
        Some(line) => assert_eq!(result["detail"], line, "{}: {result}", r.name),
        None if r.cause.ends_with("-read-failed") => assert!(
            !result["detail"].as_str().unwrap_or_default().is_empty(),
            "{}: {result}",
            r.name
        ),
        None => {}
    }
    assert_eq!(fs::read(gh.item()).unwrap(), before, "{}", r.name);
    assert_pinned(&gh.log(), HEAD);
}

/// Every read names the pinned sha; the branch's later head
/// is never asked for, so what it carries cannot change the verdict.
#[test]
fn a_moved_branch_head_is_never_read() {
    let mut gh = Github::green();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(1, vec![check_run(json!("build"), "queued", Value::Null)]),
    )
    .answer(&runs(HEAD, 1), runs_page(vec![]))
    .answer(GRAPHQL, nodes(&[check_node(9, Some(SUITE), None)]))
    .answer(&check_runs(MOVED, 1), fixture("check-runs.json"))
    .answer(&check_suites(MOVED, 1), fixture("check-suites.json"))
    .answer(&statuses(MOVED, 1), fixture("status.json"))
    .answer(
        &runs(MOVED, 1),
        runs_page(vec![run(800, MOVED, "completed", json!("success"))]),
    );
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(key(&result), "checks-pending");
    assert_eq!(
        checks(&result),
        vec![row("build", "check-run", "queued", "pending")]
    );
    let log = gh.log();
    assert_pinned(&log, HEAD);
    assert!(log.iter().any(|l| l.contains(HEAD)), "{log:?}");
    assert!(gh.state().get("verification").is_none());
}

/// A required workflow binds to a run only when the run's own workflow file
/// is the rule's path and its suite node proves that file at the rule's
/// explicit source sha in the repository whose id the rule names; never
/// through a resolved ref. Its members are the bound run's check runs as its
/// suite's `latest` listing names them. Every unproven part leaves the
/// requirement expected, never passed and never failed.
#[test]
fn a_required_workflow_binds_only_through_its_proven_source() {
    // Bound: the run's path, its proof's path, repository and sha match the
    // rule, so its check run is the member.
    let gh = bound_world();
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "pass");
    assert_eq!(
        checks(&result),
        vec![row("request", "check-run", "success", "pass")]
    );
    let log = gh.log();
    assert_pinned(&log, HEAD);
    assert!(
        log.iter()
            .any(|l| l.starts_with("api graphql ") && l.contains(&suite_node_id(700))),
        "{log:?}"
    );
    assert!(
        log.contains(&format!("api {}", source_repository())),
        "{log:?}"
    );

    // The bound run's jobs are its suite's own listing, so a check run whose
    // suite the ref's listing nulls is the bound run's job whether its node
    // identifies the run or names it without an id; the member is the job the
    // rollup links to the run.
    for run_id in [json!(700), Value::Null] {
        let unsuited = check_run_in(None, 9, json!("request"), "completed", json!("success"));
        let mut gh = bound_world();
        gh.answer(
            &check_runs(HEAD, 1),
            check_runs_page(1, vec![unsuited.clone()]),
        )
        .answer(
            &suite_check_runs(700, 1),
            check_runs_page(1, vec![unsuited]),
        )
        .answer(
            GRAPHQL,
            nodes(&[
                suite_node(700, 1, source_file(SOURCE_REPO, WORKFLOW_SHA)),
                check_node(9, None, Some((run_id.clone(), "wf-161336"))),
            ]),
        );
        let result = ok_result(&gh.verify(true));
        assert_eq!(result["status"], "complete", "{run_id}: {result}");
        assert_eq!(result["verdict"], "pass", "{run_id}");
        assert_eq!(
            checks(&result),
            vec![row("request", "check-run", "success", "pass")],
            "{run_id}"
        );
    }

    // The suite lists `request` twice, completed in the
    // same second; which the `latest` listing names is the server's answer,
    // consumed as given. The rollup keeps the later-started one (gh's
    // rule), so the listing naming it passes and the listing naming the
    // other leaves that job missing.
    let twins = || {
        let older = check_run_in(
            Some(700),
            9,
            json!("request"),
            "completed",
            json!("success"),
        );
        let newer = with(
            check_run_in(
                Some(700),
                12,
                json!("request"),
                "completed",
                json!("success"),
            ),
            "started_at",
            json!("2026-01-29T15:12:00Z"),
        );
        (older, newer)
    };
    let (older, newer) = twins();
    let mut gh = bound_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(2, vec![older.clone(), newer.clone()]),
    )
    .answer(&suite_check_runs(700, 1), check_runs_page(1, vec![newer]));
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "pass");
    assert_eq!(
        checks(&result),
        vec![row("request", "check-run", "success", "pass")]
    );
    let (older, newer) = twins();
    let mut gh = bound_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(2, vec![older.clone(), newer]),
    )
    .answer(&suite_check_runs(700, 1), check_runs_page(1, vec![older]));
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(key(&result), "checks-pending");
    assert_eq!(
        checks(&result),
        vec![row("request", "required", "expected", "pending")]
    );
    assert!(gh.state().get("verification").is_none());

    struct Unproven {
        name: &'static str,
        set: fn(&mut Github),
    }
    let rows = [
        Unproven {
            name: "the proof names another source commit",
            set: |gh| {
                gh.answer(
                    GRAPHQL,
                    nodes(&[suite_node(700, 1, source_file(SOURCE_REPO, OTHER_SHA))]),
                );
            },
        },
        Unproven {
            name: "the rule names a repository the proof does not",
            set: |gh| {
                let mut rule = workflows_rule(Some(WORKFLOW_SHA));
                rule["parameters"]["workflows"][0]["repository_id"] = json!(8);
                gh.answer(&rules(1), json!([rule]));
            },
        },
        Unproven {
            name: "the proof names a fork with the same file at the same commit",
            set: |gh| {
                gh.answer(
                    GRAPHQL,
                    nodes(&[suite_node(700, 1, source_file("owner/fork", WORKFLOW_SHA))]),
                )
                .answer("repos/owner/fork", repository(9, "owner/fork"));
            },
        },
        Unproven {
            name: "the run's own file is the consumer's, a caller at the required path",
            set: |gh| {
                gh.answer(
                    GRAPHQL,
                    nodes(&[suite_node(700, 1, source_file(REPO, HEAD))]),
                )
                .answer(&format!("repos/{REPO}"), repository(REPO_ID, REPO));
            },
        },
        Unproven {
            name: "the viewer cannot read the source repository",
            set: |gh| {
                let mut file = source_file(SOURCE_REPO, WORKFLOW_SHA);
                file["viewerCanReadRepository"] = json!(false);
                gh.answer(GRAPHQL, nodes(&[suite_node(700, 1, file)]));
            },
        },
        Unproven {
            name: "the node proves another attempt",
            set: |gh| {
                gh.answer(
                    GRAPHQL,
                    nodes(&[suite_node(700, 2, source_file(SOURCE_REPO, WORKFLOW_SHA))]),
                );
            },
        },
        Unproven {
            name: "the node's file is null",
            set: |gh| {
                gh.answer(GRAPHQL, nodes(&[suite_node(700, 1, Value::Null)]));
            },
        },
        Unproven {
            // GitHub cannot resolve the suite node and says so with a field
            // error at its path, a reply gh prints with a nonzero exit: the
            // node is null and the candidate unproven, so an unreadable
            // required set is held pending.
            name: "the proof's suite node is one the viewer cannot resolve, with its field error",
            set: |gh| {
                gh.answer(
                    GRAPHQL,
                    with(nodes(&[]), "errored", json!([suite_node_id(700)])),
                );
            },
        },
        Unproven {
            name: "the run carries no suite node",
            set: |gh| {
                let unnoded = without(
                    required_run(
                        700,
                        1,
                        "2026-01-29T15:09:00Z",
                        "completed",
                        json!("success"),
                    ),
                    "check_suite_node_id",
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![unnoded]));
            },
        },
        Unproven {
            // Without the run's `check_suite_id` its check run's suite is
            // joined through the check-run node; the binding still needs
            // the run's suite and holds.
            name: "the run carries no check suite",
            set: |gh| {
                let unsuited = without(
                    required_run(
                        700,
                        1,
                        "2026-01-29T15:09:00Z",
                        "completed",
                        json!("failure"),
                    ),
                    "check_suite_id",
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![unsuited])).answer(
                    GRAPHQL,
                    nodes(&[
                        suite_node(700, 1, source_file(SOURCE_REPO, WORKFLOW_SHA)),
                        check_node(9, Some(700), Some((json!(700), "wf-161336"))),
                    ]),
                );
            },
        },
        Unproven {
            // A bound run whose suite lists no check run is `pending`.
            name: "the bound run's suite lists no check run",
            set: |gh| {
                gh.answer(&suite_check_runs(700, 1), check_runs_page(0, vec![]));
            },
        },
        Unproven {
            // A listed job without a page is an `error`.
            name: "the bound run's suite lists a check run without a page",
            set: |gh| {
                gh.answer(
                    &suite_check_runs(700, 1),
                    check_runs_page(
                        1,
                        vec![with(
                            check_run_in(
                                Some(700),
                                9,
                                json!("request"),
                                "completed",
                                json!("success"),
                            ),
                            "html_url",
                            Value::Null,
                        )],
                    ),
                );
            },
        },
        Unproven {
            name: "the run's own file is another path",
            set: |gh| {
                let other = with(
                    required_run(
                        700,
                        1,
                        "2026-01-29T15:09:00Z",
                        "completed",
                        json!("success"),
                    ),
                    "path",
                    json!(".github/workflows/caller.yml"),
                );
                gh.answer(&runs(HEAD, 1), runs_page(vec![other]));
            },
        },
    ];
    for r in rows {
        let mut gh = bound_world();
        (r.set)(&mut gh);
        let result = ok_result(&gh.verify(true));
        assert_eq!(result["status"], "pending", "{}: {result}", r.name);
        assert_eq!(key(&result), "checks-pending", "{}: {result}", r.name);
        assert_eq!(
            checks(&result),
            vec![row(WORKFLOW_PATH, "required", "expected", "pending")],
            "{}: {result}",
            r.name
        );
        assert!(gh.state().get("verification").is_none(), "{}", r.name);
        assert_pinned(&gh.log(), HEAD);
    }

    // No sha, absent or empty: refused before any binding, with no ref
    // resolved and no proof read.
    for sha in [None, Some("")] {
        let mut gh = bound_world();
        gh.answer(&rules(1), json!([workflows_rule(sha)]));
        let result = ok_result(&gh.verify(true));
        assert_eq!(result["status"], "unreadable", "{result}");
        assert_eq!(
            result["reason"],
            format!("workflow-source-unbound path={WORKFLOW_PATH}")
        );
        assert!(gh.state().get("verification").is_none());
        let log = gh.log();
        assert_pinned(&log, HEAD);
        assert!(
            log.iter()
                .all(|l| !l.contains(SOURCE_REPO) && !l.starts_with("api graphql ")),
            "{log:?}"
        );
    }
}

/// The definitions are walked in sorted order and the first that is not
/// ready ends the read: an earlier
/// unresolved definition holds the requirement expected though a later one
/// failed, and an earlier failed definition fails though a later one is
/// bound; a failed commit status whose target is the bound job's URL is a
/// required member by link.
#[test]
fn the_definition_walk_and_link_membership_follow_the_legacy() {
    let unresolved_first = {
        let mut rule = workflows_rule(Some(WORKFLOW_SHA));
        rule["parameters"]["workflows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"path": ".github/workflows/a.yml", "repository_id": SOURCE_REPO_ID, "sha": WORKFLOW_SHA, "ref": "refs/heads/main"}));
        rule
    };
    let mut gh = bound_world();
    gh.answer(
        &runs(HEAD, 1),
        runs_page(vec![required_run(
            700,
            1,
            "2026-01-29T15:09:00Z",
            "completed",
            json!("failure"),
        )]),
    )
    .answer(&rules(1), json!([unresolved_first]));
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(key(&result), "checks-pending");
    assert_eq!(
        checks(&result),
        vec![row(
            ".github/workflows/a.yml",
            "required",
            "expected",
            "pending"
        )]
    );
    assert!(gh.state().get("verification").is_none());

    let failed_first = {
        let mut rule = workflows_rule(Some(WORKFLOW_SHA));
        rule["parameters"]["workflows"]
            .as_array_mut()
            .unwrap()
            .push(json!({"path": ".github/workflows/z.yml", "repository_id": SOURCE_REPO_ID, "sha": WORKFLOW_SHA, "ref": "refs/heads/main"}));
        rule
    };
    let mut gh = bound_world();
    gh.answer(
        &runs(HEAD, 1),
        runs_page(vec![required_run(
            700,
            1,
            "2026-01-29T15:09:00Z",
            "completed",
            json!("failure"),
        )]),
    )
    .answer(&rules(1), json!([failed_first]));
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "fail");
    assert_eq!(
        checks(&result),
        vec![row(WORKFLOW_PATH, "workflow-run", "failure", "fail")]
    );

    let mut gh = bound_world();
    gh.answer(
        &statuses(HEAD, 1),
        statuses_page(vec![with(
            status("gate", "failure"),
            "target_url",
            json!(format!("https://github.com/{REPO}/actions/runs/700/job/9")),
        )]),
    );
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "fail");
    assert_eq!(
        checks(&result),
        vec![
            row("request", "check-run", "success", "pass"),
            row("gate", "commit-status", "failure", "fail"),
        ]
    );
}

/// Every documented rule type decodes, and the four that gate on
/// scanning results add nothing to the required set.
#[test]
fn documented_rule_kinds_outside_the_rollup_change_no_required_set() {
    for kind in [
        "code_scanning",
        "code_quality",
        "code_coverage",
        "license_compliance_scanning",
    ] {
        let mut gh = Github::green();
        gh.answer(
            &rules(1),
            json!([
                {"type": kind, "parameters": {"severity_threshold": "high"}},
                status_checks_rule(&["build"]),
            ]),
        );
        let result = ok_result(&gh.verify(true));
        assert_eq!(result["status"], "complete", "{kind}: {result}");
        assert_eq!(result["verdict"], "pass", "{kind}");
        assert_eq!(
            checks(&result),
            vec![row("build", "check-run", "success", "pass")],
            "{kind}"
        );
    }
}

/// The selection fields documented optional keep their reading for
/// omission (`run_attempt // 1`, `run_started_at //
/// updated_at`); only a present null refuses (the malformed table). The
/// bound run's own check runs carry the members, so each run here owns
/// one, and each run's suite node proves the required file at the rule's
/// sha for the attempt the run reads as.
#[test]
fn omitted_selection_fields_read_as_the_legacy_defaults() {
    // Run 700's job started after run 701's, so gh's rule keeps whichever
    // run is current here by start, not by the tie order.
    let own = |id: u64, conclusion: &str| {
        with(
            check_run_in(
                Some(id),
                id + 1,
                json!("request"),
                "completed",
                json!(conclusion),
            ),
            "started_at",
            json!(if id == 700 {
                "2026-01-29T16:01:00Z"
            } else {
                STARTED
            }),
        )
    };
    // Each run's suite listing is its one job, read for every candidate.
    let suites = |gh: &mut Github| {
        gh.answer(
            &suite_check_runs(700, 1),
            check_runs_page(1, vec![own(700, "success")]),
        )
        .answer(
            &suite_check_runs(701, 1),
            check_runs_page(1, vec![own(701, "failure")]),
        );
    };
    let proofs = |older_attempt: u64| {
        nodes(&[
            suite_node(700, older_attempt, source_file(SOURCE_REPO, WORKFLOW_SHA)),
            suite_node(701, 1, source_file(SOURCE_REPO, WORKFLOW_SHA)),
        ])
    };
    // Without run_attempt the older run is not a re-run and cannot replace
    // the newer id through a later start.
    let older = without(
        required_run(
            700,
            2,
            "2026-01-29T16:00:00Z",
            "completed",
            json!("success"),
        ),
        "run_attempt",
    );
    let newer = required_run(
        701,
        1,
        "2026-01-29T15:30:00Z",
        "completed",
        json!("failure"),
    );
    let mut gh = bound_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(2, vec![own(700, "success"), own(701, "failure")]),
    )
    .answer(&check_suites(HEAD, 1), check_suites_page(2, vec![700, 701]))
    .answer(&runs(HEAD, 1), runs_page(vec![older, newer]))
    .answer(GRAPHQL, proofs(1));
    suites(&mut gh);
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["verdict"], "fail", "{result}");
    assert_eq!(
        checks(&result),
        vec![row(WORKFLOW_PATH, "workflow-run", "failure", "fail")]
    );

    // Without run_started_at the start is updated_at, so a re-run whose
    // updated_at is later than the newer run's still replaces it.
    let older = without(
        with(
            required_run(
                700,
                2,
                "2026-01-29T15:00:00Z",
                "completed",
                json!("success"),
            ),
            "updated_at",
            json!("2026-01-29T16:00:00Z"),
        ),
        "run_started_at",
    );
    let newer = required_run(
        701,
        1,
        "2026-01-29T15:30:00Z",
        "completed",
        json!("failure"),
    );
    let mut gh = bound_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(2, vec![own(700, "success"), own(701, "failure")]),
    )
    .answer(&check_suites(HEAD, 1), check_suites_page(2, vec![700, 701]))
    .answer(&runs(HEAD, 1), runs_page(vec![older, newer]))
    .answer(GRAPHQL, proofs(2));
    suites(&mut gh);
    let result = ok_result(&gh.verify(true));
    assert_eq!(result["verdict"], "pass", "{result}");
    assert_eq!(
        checks(&result),
        vec![row("request", "check-run", "success", "pass")]
    );
}

/// The target's kind is checked before any read, so a
/// verification aimed at the fleet refuses `op-kind` without reaching
/// GitHub.
#[test]
fn a_fleet_target_refuses_op_kind_before_any_read() {
    let gh = Github::green();
    let out = gh.verify_target(&["--fleet"], HEAD, true);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(reply(&out)["refusal"]["key"], "op-kind");
    assert!(gh.log().is_empty(), "{:?}", gh.log());
    assert!(gh.state().get("verification").is_none());
}

/// A request outside the pinned forms refuses on the keyed line before any
/// read.
#[test]
fn an_invalid_request_refuses_before_any_read() {
    let gh = Github::green();
    let out = gh.verify_head("737BCE791577E140436490E0FED5751BB5144A61", true);
    assert_eq!(out.status.code(), Some(1));
    let line = String::from_utf8_lossy(&out.stderr)
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned();
    assert_eq!(line, "orch-runtime: verify-request-invalid field=head");
    assert_eq!(reply(&out)["refusal"]["key"], "verify-request-invalid");
    assert!(gh.log().is_empty(), "{:?}", gh.log());
    assert!(gh.state().get("verification").is_none());
}

/// `apply` is the transition path; the verifications' reads come before
/// their transition, so the library refuses both requests there.
#[test]
fn apply_refuses_the_verifications_as_transitions() {
    let gh = Github::empty();
    let env = Env {
        now_secs: 1_769_700_000,
        now_nanos: 1_769_700_000_123_456_789,
        nonce: 4242,
        owner: None,
    };
    let requests = [
        (
            "verify-head",
            Request::VerifyHead(VerifyHead {
                repo: REPO.into(),
                base: BASE.into(),
                head: HEAD.into(),
                required_only: true,
            }),
        ),
        (
            "verify-pr",
            Request::VerifyPr(VerifyPr {
                repo: REPO.into(),
                pr: PR,
                required_only: true,
            }),
        ),
    ];
    for (name, request) in requests {
        match apply(&gh.item(), &request, &env, Locking::FLOCK) {
            Err(Error::OpNotTransition { op }) => assert_eq!(op, name),
            other => panic!("{name}: {other:?}"),
        }
    }
    assert!(Path::new(&gh.item()).exists());
}

// --- verify-pr ------------------------------------------------------------------

/// The pull request every `verify-pr` row names.
const PR: u64 = 7;

/// Where the pull request's head moves to between two `verify-pr` calls:
/// read by the second, unlike `MOVED`, which no row reads.
const NEXT: &str = "d049a699ebe08c6b639fdc19855a7152ae768084";

/// `value` with `HEAD` replaced by `head` in every string it holds.
fn rehead(value: Value, head: &str) -> Value {
    match value {
        Value::String(s) => Value::String(s.replace(HEAD, head)),
        Value::Array(a) => Value::Array(a.into_iter().map(|v| rehead(v, head)).collect()),
        Value::Object(o) => {
            Value::Object(o.into_iter().map(|(k, v)| (k, rehead(v, head))).collect())
        }
        other => other,
    }
}

/// The green world's evidence for `head`: the documented replies with the
/// head rewritten, what a verify-pr call reads once the pull request's
/// head is `head`.
fn green_evidence(gh: &mut Github, head: &str) {
    gh.answer(
        &check_runs(head, 1),
        rehead(fixture("check-runs.json"), head),
    )
    .answer(
        &check_suites(head, 1),
        rehead(fixture("check-suites.json"), head),
    )
    .answer(&statuses(head, 1), rehead(fixture("status.json"), head))
    .answer(&runs(head, 1), rehead(fixture("actions-runs.json"), head));
}

/// The head is read from the pull request on every call, so a head that moved
/// between two calls is judged on the newer one and the older verdict is
/// replaced (`item.rs` `record_verification`'s `replaced`). The defect: a
/// verification that keeps judging the head its first call read, or a record
/// that keeps the older head's verdict beside a newer head.
#[test]
fn a_pull_requests_moved_head_is_judged_on_the_newer_head_and_the_older_verdict_replaced() {
    let mut gh = Github::green();
    gh.pull(PR, HEAD, BASE, "OPEN");
    let first = ok_result(&gh.verify_pr(PR, false));
    assert_eq!(first["status"], "complete", "{first}");
    assert_eq!(first["verdict"], "pass");
    assert_eq!(first["pr"], PR);
    assert_eq!(first["head"], HEAD);
    assert_eq!(first["base"], BASE);
    assert_eq!(first["recorded"]["report"]["replaced"], false);
    let record = gh.state()["verification"].clone();
    assert_eq!(record["head"], HEAD);
    assert_eq!(record["verdict"], "pass");
    assert_eq!(record["source"], "verify-pr");
    let first_log = gh.log();
    assert_pull_then_pinned(&first_log, PR, HEAD);

    // The branch moved: the pull request now answers NEXT, whose evidence
    // is green too, so only the reads tell which head was judged.
    gh.pull(PR, NEXT, BASE, "OPEN");
    green_evidence(&mut gh, NEXT);
    let second = ok_result(&gh.verify_pr(PR, false));
    assert_eq!(second["status"], "complete", "{second}");
    assert_eq!(second["head"], NEXT);
    assert_eq!(second["recorded"]["report"]["replaced"], true);
    let record = gh.state()["verification"].clone();
    assert_eq!(record["head"], NEXT, "{record}");
    assert_eq!(record["source"], "verify-pr");
    let second_log: Vec<String> = gh.log()[first_log.len()..].to_vec();
    assert_pull_then_pinned(&second_log, PR, NEXT);
    assert!(
        second_log.iter().any(|l| l.contains(NEXT)),
        "{second_log:?}"
    );
    assert!(
        !second_log.iter().any(|l| l.contains(HEAD)),
        "{second_log:?}"
    );
}

/// A closed or merged pull request refuses `pr-not-open` after the one `pr
/// view` and before any verdict read, and records nothing. The defect: a
/// merged pull request's old head verified and recorded as if the wait were
/// still open.
#[test]
fn a_closed_or_merged_pull_request_refuses_before_any_verdict_read() {
    for state in ["CLOSED", "MERGED"] {
        let mut gh = Github::green();
        gh.pull(PR, HEAD, BASE, state);
        let out = gh.verify_pr(PR, true);
        assert_eq!(out.status.code(), Some(1), "{state}");
        let line = String::from_utf8_lossy(&out.stderr)
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        assert_eq!(
            line,
            format!("orch-runtime: pr-not-open pr={PR} state={state}")
        );
        assert_eq!(reply(&out)["refusal"]["key"], "pr-not-open", "{state}");
        assert_eq!(gh.log(), vec![pr_view(PR)], "{state}");
        assert!(gh.state().get("verification").is_none(), "{state}");
    }
}

/// The pull request read is three-valued: a failed `pr view`, an answer
/// outside gh's shape and a head or base outside the pinned forms are each
/// `unreadable` with the read's cause, after that one read and before any
/// other; nothing is recorded and the call is not a refusal, so the caller
/// repeats it as it repeats `pending`. A request outside the pinned forms,
/// or aimed at the fleet, refuses before any read at all.
#[test]
fn an_unreadable_pull_request_is_a_result_with_its_cause_and_an_invalid_request_refuses_first() {
    let unreadable = [
        ("absent", None, "pull-request-read-failed"),
        (
            "no state",
            Some(json!({"headRefOid": HEAD, "baseRefName": BASE})),
            "pull-request-response-invalid",
        ),
        (
            "undocumented state",
            Some(json!({"headRefOid": HEAD, "baseRefName": BASE, "state": "DRAFT"})),
            "pull-request-response-invalid",
        ),
        (
            "short head",
            Some(json!({"headRefOid": "737bce7", "baseRefName": BASE, "state": "OPEN"})),
            "pull-request-response-invalid",
        ),
        (
            "blank base",
            Some(json!({"headRefOid": HEAD, "baseRefName": "", "state": "OPEN"})),
            "pull-request-response-invalid",
        ),
    ];
    for (name, body, cause) in unreadable {
        let mut gh = Github::green();
        if let Some(body) = body {
            gh.answer(&format!("pr view {PR}"), body);
        }
        let result = ok_result(&gh.verify_pr(PR, true));
        assert_eq!(result["status"], "unreadable", "{name}: {result}");
        assert_eq!(result["reason"], cause, "{name}: {result}");
        assert!(result.get("head").is_none(), "{name}: {result}");
        assert!(result.get("verdict").is_none(), "{name}: {result}");
        assert_eq!(
            result["detail"].is_string(),
            cause == "pull-request-read-failed",
            "{name}: {result}"
        );
        assert_eq!(gh.log(), vec![pr_view(PR)], "{name}");
        assert!(gh.state().get("verification").is_none(), "{name}");
    }

    let gh = Github::green();
    let refused = [
        (
            "pr",
            gh.op(
                &["--item", "KEN-4687"],
                json!({"op": "verify-pr", "repo": REPO, "pr": 0, "required_only": true}),
            ),
        ),
        (
            "repo",
            gh.op(
                &["--item", "KEN-4687"],
                json!({"op": "verify-pr", "repo": "owner", "pr": PR, "required_only": true}),
            ),
        ),
    ];
    for (field, out) in refused {
        assert_eq!(out.status.code(), Some(1), "{field}");
        assert_eq!(
            reply(&out)["refusal"]["key"],
            "verify-request-invalid",
            "{field}"
        );
        let line = String::from_utf8_lossy(&out.stderr)
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        assert_eq!(
            line,
            format!("orch-runtime: verify-request-invalid field={field}")
        );
    }
    let out = gh.verify_pr_target(&["--fleet"], PR, true);
    assert_eq!(reply(&out)["refusal"]["key"], "op-kind");
    assert!(gh.log().is_empty(), "{:?}", gh.log());
    assert!(gh.state().get("verification").is_none());
}

// --- verify-review: the review gate --------------------------------------------

/// The review gate's reviewer: the GraphQL actor login its `latestReviews`
/// rows carry, and the REST login with its suffix.
const COPILOT: &str = "copilot-pull-request-reviewer";
const COPILOT_REST: &str = "copilot-pull-request-reviewer[bot]";
const COPILOT_ERROR: &str =
    "Copilot encountered an error and was unable to review this pull request.";
/// The POST the gate makes once per head, as the fake logs it.
const REQUEST_LINE: &str = "api repos/owner/repo/pulls/7/requested_reviewers --method POST -f reviewers[]=copilot-pull-request-reviewer[bot]";

fn reviews_path() -> String {
    page(&format!("repos/{REPO}/pulls/{PR}/reviews"), 1)
}

fn timeline_path() -> String {
    page(&format!("repos/{REPO}/issues/{PR}/timeline"), 1)
}

fn pull_path() -> String {
    format!("repos/{REPO}/pulls/{PR}")
}

fn classic_path() -> String {
    format!("repos/{REPO}/branches/{BASE}/protection")
}

const THREADS: &str = "graphql number=7 cursor=";

/// The pull request as `pr view` exports it for the gate.
fn review_view(decision: &str, latest: &[(&str, &str)], draft: bool) -> Value {
    let latest: Vec<Value> = latest
        .iter()
        .map(|(login, state)| json!({"author": {"login": login}, "state": state}))
        .collect();
    json!({"headRefOid": HEAD, "baseRefName": BASE, "state": "OPEN", "isDraft": draft, "reviewDecision": decision, "latestReviews": latest, "author": {"login": "app/lane-app"}})
}

fn threads_page(unresolved: usize) -> Value {
    let nodes: Vec<Value> = (0..unresolved)
        .map(|_| json!({"isResolved": false}))
        .collect();
    json!({"data": {"repository": {"pullRequest": {"reviewThreads": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": nodes}}}}})
}

fn rest_pull(draft: bool, branch: &str, login: &str, kind: &str) -> Value {
    json!({"state": "open", "draft": draft, "head": {"sha": HEAD, "ref": branch}, "base": {"ref": BASE}, "user": {"login": login, "type": kind}})
}

/// One review by Copilot on the head.
fn copilot_review(id: u64, state: &str, body: &str, submitted: &str) -> Value {
    json!({"id": id, "user": {"login": COPILOT_REST, "type": "Bot"}, "body": body, "state": state, "commit_id": HEAD, "submitted_at": submitted})
}

/// A Copilot check run on the head in `status`.
fn copilot_check(id: u64, status: &str) -> Value {
    let conclusion = if status == "completed" {
        json!("success")
    } else {
        Value::Null
    };
    check_run_in(None, id, json!(COPILOT), status, conclusion)
}

impl Github {
    /// The gate's world: an open, ready pull request with no review, no
    /// thread, no Copilot work, a base whose rules require one approval,
    /// and a consumer base checkout under `enforce`.
    fn review_world() -> Self {
        let mut gh = Github::empty();
        fs::create_dir_all(gh.base()).unwrap();
        fs::write(
            gh.base().join("kendex.settings.toml"),
            "[env]\nREVIEW_GATE_MODE = \"enforce\"\n",
        )
        .unwrap();
        gh.answer(&format!("pr view {PR}"), review_view("", &[], false))
            .answer(THREADS, threads_page(0))
            .answer(
                &rules(1),
                json!([{"type": "pull_request", "parameters": {"required_approving_review_count": 1}}]),
            )
            .answer(&pull_path(), rest_pull(false, "feat", "lane-app[bot]", "Bot"))
            .answer(&reviews_path(), json!([]))
            .answer(&timeline_path(), json!([]))
            .answer(&check_runs(HEAD, 1), check_runs_page(0, vec![]))
            .answer(&format!("POST repos/{REPO}/pulls/{PR}/requested_reviewers"), json!({}));
        gh
    }

    fn base(&self) -> PathBuf {
        self.dir.path().join("base")
    }

    fn policy(&self, text: &str) {
        fs::write(self.base().join("kendex.settings.toml"), text).unwrap();
    }

    /// One `verify-review` call with `env` over the isolated environment.
    fn review(&self, mark_ready: bool, env: &[(&str, &str)]) -> Output {
        let replies = self.dir.path().join("replies.json");
        fs::write(&replies, serde_json::to_vec(&self.replies).unwrap()).unwrap();
        let request = self.dir.path().join("request.json");
        fs::write(
            &request,
            json!({"op": "verify-review", "repo": REPO, "pr": PR, "base_checkout": self.base(), "mark_ready": mark_ready}).to_string(),
        )
        .unwrap();
        let mut command = support::isolated();
        command
            .args(["--state-dir", &self.dir.path().display().to_string()])
            .arg("op")
            .args(["--item", "KEN-4687"])
            .arg("--request")
            .arg(&request)
            .env("PATH", support::tool_path(&[fixtures().as_path()]))
            .env("GH_FAKE_REPLIES", &replies)
            .env("GH_FAKE_LOG", self.dir.path().join("gh.log"))
            .current_dir(self.dir.path());
        for (key, value) in env {
            command.env(key, value);
        }
        command.output().unwrap()
    }

    /// The log lines since `from`.
    fn log_since(&self, from: usize) -> Vec<String> {
        self.log()[from..].to_vec()
    }

    fn requests(&self) -> usize {
        self.log().iter().filter(|l| *l == REQUEST_LINE).count()
    }

    fn review_record(&self) -> Value {
        self.state()["pr_review"].clone()
    }

    fn head_record(&self) -> Value {
        self.review_record()["heads"][HEAD].clone()
    }

    /// A call to `path` killed by a signal: gh ended with no exit status,
    /// whether or not the call reached GitHub.
    fn killed(&mut self, path: &str) -> &mut Self {
        self.replies
            .insert(path.to_owned(), json!({"signal": "TERM"}));
        self
    }

    /// GitHub's refusal of `path` as gh reports one: the reply's message
    /// on stderr with its status, `gh: <message> (HTTP <status>)`, the body
    /// on stdout, exit 1.
    fn refused(&mut self, path: &str, status: u16, message: &str) -> &mut Self {
        self.replies.insert(
            path.to_owned(),
            json!({"body": {"message": message}, "stderr": format!("gh: {message} (HTTP {status})"), "exit": 1}),
        );
        self
    }

    /// A call to `path` whose transport failed, as gh 2.103.3 reports a
    /// host it cannot reach: nothing on stdout, exit 1; `landed` where
    /// GitHub took the request before its answer was lost.
    fn unreachable(&mut self, path: &str, landed: bool) -> &mut Self {
        self.replies.insert(
            path.to_owned(),
            json!({"text": "", "stderr": "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com", "exit": 1, "landed": landed}),
        );
        self
    }

    /// Rewrite one field of the head's record in the item file.
    fn set_head(&self, field: &str, value: Value) {
        let mut state = self.state();
        state["pr_review"]["heads"][HEAD][field] = value;
        fs::write(self.item(), serde_json::to_vec_pretty(&state).unwrap()).unwrap();
    }
}

/// The ISO stamp `ago` seconds before now, the record's own clock.
fn stamp_ago(ago: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    agent_runtime::clock::iso_utc(now - ago)
}

const BLOCK: &[(&str, &str)] = &[("PR_REVIEW_ON_TIMEOUT", "block")];

/// Run the gate on a head whose period is spent: one call records the
/// head, its stamps are moved past the review budget and Copilot's hold,
/// as time passing moves both, and the second call reads the verdict.
fn review_spent(gh: &Github, env: &[(&str, &str)]) -> Value {
    let first = ok_result(&gh.review(false, env));
    if first["status"] != "pending" {
        return first;
    }
    gh.set_head("at", json!(stamp_ago(901)));
    gh.set_head("period_started", json!(stamp_ago(901)));
    ok_result(&gh.review(false, env))
}

/// The request is the gate's one effect, claimed under the head's key before
/// the POST: a second call on the same head finds the key and asks nothing,
/// Copilot's work already in flight is recorded as existing and asked
/// nothing, and an error answer standing on the head makes the one request
/// its retry, claimed in the same write.
#[test]
fn a_second_run_requests_no_second_review() {
    let gh = Github::review_world();
    let first = ok_result(&gh.review(false, &[]));
    assert_eq!(first["status"], "pending", "{first}");
    assert_eq!(first["mode"], "approval");
    assert_eq!(first["request"]["outcome"], "requested", "{first}");
    assert_eq!(first["request"]["recorded_now"], true);
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());
    assert_eq!(gh.head_record()["request"]["outcome"], "requested");
    let second = ok_result(&gh.review(false, &[]));
    assert_eq!(second["status"], "pending", "{second}");
    assert_eq!(second["request"]["outcome"], "requested");
    assert_eq!(second["request"]["recorded_now"], false);
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());

    // Copilot's work already in flight on the head is the standing request.
    let mut gh = Github::review_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(1, vec![copilot_check(31, "queued")]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["request"]["outcome"], "existing", "{result}");
    assert_eq!(result["request"]["reason"], "existing-run");
    assert_eq!(gh.requests(), 0, "{:?}", gh.log());
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["request"]["recorded_now"], false, "{result}");
    assert_eq!(gh.requests(), 0);

    // An error answer standing on the head: the one request is its retry.
    let mut gh = Github::review_world();
    gh.answer(
        &format!("pr view {PR}"),
        review_view("", &[(COPILOT, "COMMENTED")], false),
    )
    .answer(
        &reviews_path(),
        json!([copilot_review(
            11,
            "COMMENTED",
            COPILOT_ERROR,
            "2026-01-01T00:00:00Z"
        )]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(result["request"]["outcome"], "requested");
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());
    assert_eq!(gh.head_record()["retry"]["review_id"], 11);
    assert_eq!(gh.head_record()["retry"]["outcome"], "requested");
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());

    // A Copilot review already on the head, one that is no error, is the
    // request answered: nothing is asked again.
    let mut gh = Github::review_world();
    gh.answer(
        &format!("pr view {PR}"),
        review_view("", &[(COPILOT, "COMMENTED")], false),
    )
    .answer(
        &reviews_path(),
        json!([copilot_review(
            12,
            "COMMENTED",
            "Reviewed.",
            "2026-01-01T00:00:00Z"
        )]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(result["request"]["outcome"], "existing", "{result}");
    assert_eq!(result["request"]["reason"], "existing-review");
    assert_eq!(gh.requests(), 0, "{:?}", gh.log());
}

/// Each verdict word is read from the head's reviews, threads and the
/// period's budget, and recorded under `pr_review.verdict`: the aggregate
/// approval or a latest approval with no objection, an objection, an open
/// thread, a spent period under `block` or with a reviewer engaged, a spent
/// period on a silent reviewer under `proceed`, an off gate, a second Copilot
/// error after the retry, and a Copilot approval GitHub re-pointed to a
/// force-pushed head, which carries no verdict until a review follows the
/// head's arrival.
#[test]
fn each_verdict_word_is_read_from_the_head() {
    struct Row {
        name: &'static str,
        view: Value,
        unresolved: usize,
        env: &'static [(&'static str, &'static str)],
        /// Whether the verdict is read on a spent period.
        spent: bool,
        verdict: &'static str,
    }
    let rows = [
        Row {
            name: "the aggregate approval",
            view: review_view("APPROVED", &[("colleague", "APPROVED")], false),
            unresolved: 0,
            env: &[],
            spent: false,
            verdict: "approved",
        },
        Row {
            name: "a latest approval with no decision",
            view: review_view("", &[("colleague", "APPROVED")], false),
            unresolved: 0,
            env: &[],
            spent: false,
            verdict: "approved",
        },
        Row {
            name: "an objection beside an approval",
            view: review_view(
                "",
                &[("colleague", "APPROVED"), ("other", "CHANGES_REQUESTED")],
                false,
            ),
            unresolved: 0,
            env: &[],
            spent: false,
            verdict: "changes_requested",
        },
        Row {
            name: "an objection outranks open threads",
            view: review_view(
                "CHANGES_REQUESTED",
                &[("other", "CHANGES_REQUESTED")],
                false,
            ),
            unresolved: 2,
            env: &[],
            spent: false,
            verdict: "changes_requested",
        },
        Row {
            name: "an open thread beside an approval",
            view: review_view("APPROVED", &[("colleague", "APPROVED")], false),
            unresolved: 1,
            env: &[],
            spent: false,
            verdict: "comments",
        },
        Row {
            name: "a required review keeps a latest approval from approving",
            view: review_view("REVIEW_REQUIRED", &[("colleague", "APPROVED")], false),
            unresolved: 0,
            env: BLOCK,
            spent: true,
            verdict: "timeout",
        },
        Row {
            name: "a silent reviewer under block",
            view: review_view("", &[], false),
            unresolved: 0,
            env: BLOCK,
            spent: true,
            verdict: "timeout",
        },
        Row {
            name: "a reviewer who commented is engaged, not silent",
            view: review_view("", &[("colleague", "COMMENTED")], false),
            unresolved: 0,
            env: &[],
            spent: true,
            verdict: "timeout",
        },
        Row {
            name: "the author's own comment is silence",
            view: review_view("", &[("lane-app", "COMMENTED")], false),
            unresolved: 0,
            env: &[],
            spent: true,
            verdict: "proceeded",
        },
        Row {
            name: "a silent reviewer under proceed",
            view: review_view("", &[], false),
            unresolved: 0,
            env: &[],
            spent: true,
            verdict: "proceeded",
        },
    ];
    for row in rows {
        let mut gh = Github::review_world();
        gh.answer(&format!("pr view {PR}"), row.view)
            .answer(THREADS, threads_page(row.unresolved));
        let result = if row.spent {
            review_spent(&gh, row.env)
        } else {
            ok_result(&gh.review(false, row.env))
        };
        assert_eq!(result["status"], "complete", "{}: {result}", row.name);
        assert_eq!(result["verdict"], row.verdict, "{}: {result}", row.name);
        assert_eq!(result["unresolved_count"], row.unresolved, "{}", row.name);
        let record = gh.review_record()["verdict"].clone();
        assert_eq!(record["verdict"], row.verdict, "{}: {record}", row.name);
        assert_eq!(record["head"], HEAD, "{}", row.name);
        assert_eq!(result["recorded"]["replaced"], false, "{}", row.name);
    }

    // An off gate is the verdict before any review read.
    let gh = Github::review_world();
    gh.policy("[env]\nREVIEW_GATE_MODE = \"off\"\n");
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "off");
    assert_eq!(result["mode"], "off");
    assert_eq!(gh.review_record()["mode"], "off");
    assert_eq!(
        gh.log(),
        vec![format!(
            "pr view {PR} --repo {REPO} --json headRefOid,baseRefName,state,isDraft,reviewDecision,latestReviews,author"
        )]
    );

    // A second error after the retry is the fallback cause the overseer
    // approves on; the same error keeps waiting.
    let mut gh = Github::review_world();
    gh.answer(
        &format!("pr view {PR}"),
        review_view("", &[(COPILOT, "COMMENTED")], false),
    )
    .answer(
        &reviews_path(),
        json!([copilot_review(
            11,
            "COMMENTED",
            COPILOT_ERROR,
            "2026-01-01T00:00:00Z"
        )]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(gh.head_record()["retry"]["review_id"], 11);
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    gh.answer(
        &reviews_path(),
        json!([
            copilot_review(11, "COMMENTED", COPILOT_ERROR, "2026-01-01T00:00:00Z"),
            copilot_review(12, "COMMENTED", COPILOT_ERROR, "2026-01-01T00:01:00Z")
        ]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "copilot-error");
    assert_eq!(result["reason"], "copilot-error cause=error");
    assert_eq!(gh.head_record()["retry"]["outcome"], "fallback");
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());

    // A Copilot approval re-pointed to the pushed head carries no verdict;
    // one submitted after the head arrived does.
    for (name, submitted, verdict) in [
        ("re-pointed", "2026-01-01T00:00:00Z", "timeout"),
        ("after the push", "2026-01-03T00:00:00Z", "approved"),
    ] {
        let mut gh = Github::review_world();
        gh.answer(
            &format!("pr view {PR}"),
            review_view("APPROVED", &[(COPILOT, "APPROVED")], false),
        )
        .answer(
            &reviews_path(),
            json!([copilot_review(5, "APPROVED", "Looks good.", submitted)]),
        )
        .answer(
            &timeline_path(),
            json!([{"event": "head_ref_force_pushed", "commit_id": HEAD, "created_at": "2026-01-02T00:00:00Z"}]),
        );
        let result = review_spent(&gh, BLOCK);
        assert_eq!(result["verdict"], verdict, "{name}: {result}");
        if verdict == "timeout" {
            assert_eq!(result["review_decision"], "REVIEW_REQUIRED", "{name}");
        }
    }
}

/// The period is judged on the head record's own stamp, the caller's clock
/// against it: a fresh period is `pending`, a stamp older than the budget is
/// `timeout`, which ends the period and counts it, and the next call runs a
/// new period.
#[test]
fn the_timeout_is_judged_on_the_recorded_stamp() {
    let gh = Github::review_world();
    let first = ok_result(&gh.review(false, &[]));
    assert_eq!(first["status"], "pending", "{first}");
    assert!(
        first["reason"]
            .as_str()
            .unwrap()
            .starts_with("review-pending"),
        "{first}"
    );
    assert_eq!(gh.head_record()["timeouts"], 0);
    let started = gh.head_record()["period_started"]
        .as_str()
        .unwrap()
        .to_owned();
    gh.set_head("period_started", json!(stamp_ago(901)));
    let second = ok_result(&gh.review(false, &[("PR_REVIEW_ON_TIMEOUT", "block")]));
    assert_eq!(second["status"], "complete", "{second}");
    assert_eq!(second["verdict"], "timeout");
    assert_eq!(gh.head_record()["timeouts"], 1);
    assert!(gh.head_record()["period_started"].as_str().unwrap() >= started.as_str());
    let third = ok_result(&gh.review(false, &[("PR_REVIEW_ON_TIMEOUT", "block")]));
    assert_eq!(third["status"], "pending", "{third}");
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());
}

/// Copilot's work in flight holds the call `pending` with its run while the
/// hold runs from the head record's stamp and reads `expired` past it; a
/// pending timeline request is work until a later Copilot review answers it;
/// a failed check-runs read is unreadable, never no work.
#[test]
fn copilot_work_in_flight_holds_pending_within_the_bound_and_expires_past_it() {
    let mut gh = Github::review_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(1, vec![copilot_check(31, "in_progress")]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(result["copilot"]["state"], "pending");
    assert_eq!(result["copilot"]["run"], 31);
    gh.set_head("at", json!(stamp_ago(601)));
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(result["copilot"]["state"], "expired");
    let result = ok_result(&gh.review(false, &[("ORCH_COPILOT_HOLD_SECS", "1000")]));
    assert_eq!(result["copilot"]["state"], "pending", "{result}");

    let mut gh = Github::review_world();
    gh.answer(
        &timeline_path(),
        json!([{"event": "review_requested", "id": 77, "created_at": "2026-01-01T00:00:00Z", "requested_reviewer": {"login": COPILOT_REST}}]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["copilot"]["state"], "pending", "{result}");
    assert_eq!(result["copilot"]["run"], 77);
    assert_eq!(result["request"]["reason"], "existing-run");
    gh.answer(
        &timeline_path(),
        json!([
            {"event": "review_requested", "id": 77, "created_at": "2026-01-01T00:00:00Z", "requested_reviewer": {"login": COPILOT_REST}},
            {"event": "reviewed", "submitted_at": "2026-01-01T00:05:00Z", "user": {"login": COPILOT_REST}}
        ]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["copilot"]["state"], "none", "{result}");

    // A request GitHub removed is no work in flight: the gate asks again.
    let mut gh = Github::review_world();
    gh.answer(
        &timeline_path(),
        json!([
            {"event": "review_requested", "id": 77, "created_at": "2026-01-01T00:00:00Z", "requested_reviewer": {"login": COPILOT_REST}},
            {"event": "review_request_removed", "id": 78, "created_at": "2026-01-01T00:01:00Z", "requested_reviewer": {"login": COPILOT_REST}}
        ]),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["copilot"]["state"], "none", "{result}");
    assert_eq!(result["request"]["outcome"], "requested", "{result}");
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());

    let mut gh = Github::review_world();
    gh.fail(&check_runs(HEAD, 1));
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "unreadable", "{result}");
    assert_eq!(result["reason"], "check-runs-read-failed");
    assert!(
        gh.review_record()["heads"].is_null(),
        "{}",
        gh.review_record()
    );
}

/// A blocker of kind regression-against-main standing open on the item's
/// escalated findings refuses every verdict that permits a merge, by its
/// location, whatever the reviewers say or the gate's mode: an approval, a
/// silent reviewer's `proceeded` and an `off` gate alike; once a fix clears
/// it the verdict stands.
#[test]
fn merge_is_refused_while_a_regression_blocker_stands_and_allowed_once_lifted() {
    for verdict in ["approved", "proceeded", "off"] {
        let mut gh = Github::review_world();
        match verdict {
            "approved" => {
                gh.answer(
                    &format!("pr view {PR}"),
                    review_view("APPROVED", &[("colleague", "APPROVED")], false),
                );
            }
            "off" => gh.policy("[env]\nREVIEW_GATE_MODE = \"off\"\n"),
            _ => {}
        }
        let mut state = gh.state();
        state["escalated_items"] = json!([
            {"location": "src/x.rs", "description": "misreads a moved package", "kind": "regression-against-main", "outcome": "blocked"}
        ]);
        fs::write(gh.item(), serde_json::to_vec_pretty(&state).unwrap()).unwrap();
        let result = review_spent(&gh, &[]);
        assert_eq!(result["status"], "complete", "{verdict}: {result}");
        assert_eq!(result["verdict"], "blocked", "{verdict}: {result}");
        assert_eq!(result["reason"], "regression-open location=src/x.rs");
        assert_eq!(gh.review_record()["verdict"]["verdict"], "blocked");
        let mut state = gh.state();
        state["escalated_items"] = json!([]);
        state["fixed_items"] =
            json!([{"location": "src/x.rs", "description": "misreads a moved package"}]);
        fs::write(gh.item(), serde_json::to_vec_pretty(&state).unwrap()).unwrap();
        let result = ok_result(&gh.review(false, &[]));
        assert_eq!(result["verdict"], verdict, "{result}");
        assert_eq!(result["recorded"]["replaced"], true);
    }
}

/// The gate mode is resolved from the consumer's policy and the base's
/// rules on the first call and recorded as the item's floor: a later call
/// reads the record and no rule, so a rules read that then fails changes
/// nothing. Classic protection decides where no rule requires an approval.
#[test]
fn the_gate_mode_is_recorded_once() {
    let mut gh = Github::review_world();
    let first = ok_result(&gh.review(false, &[]));
    assert_eq!(first["mode"], "approval", "{first}");
    assert!(
        gh.log().iter().any(|l| l.contains("/rules/branches/")),
        "{:?}",
        gh.log()
    );
    assert_eq!(gh.review_record()["mode"], "approval");
    let lines = gh.log().len();
    gh.fail(&rules(1));
    let second = ok_result(&gh.review(false, &[]));
    assert_eq!(second["mode"], "approval", "{second}");
    assert_eq!(second["status"], "pending");
    assert!(
        !gh.log_since(lines)
            .iter()
            .any(|l| l.contains("/rules/branches/")),
        "{:?}",
        gh.log()
    );

    for (name, enabled, classic, mode) in [
        ("no protection", false, Value::Null, "off"),
        (
            "classic reviews",
            true,
            json!({"required_pull_request_reviews": {"required_approving_review_count": 0}}),
            "approval",
        ),
        (
            "classic without reviews",
            true,
            json!({"required_pull_request_reviews": null}),
            "off",
        ),
    ] {
        let mut gh = Github::review_world();
        gh.answer(&rules(1), json!([])).answer(
            &branch(),
            json!({"protected": enabled, "protection": {"enabled": enabled}}),
        );
        if !classic.is_null() {
            gh.answer(&classic_path(), classic);
        }
        let result = ok_result(&gh.review(false, &[]));
        assert_eq!(result["mode"], mode, "{name}: {result}");
    }

    // A rule requiring no general count still requires a review through
    // code-owner review, last-push approval or a team minimum; an optional
    // team minimum requires none.
    for (name, parameters, mode) in [
        (
            "code owner",
            json!({"required_approving_review_count": 0, "require_code_owner_review": true}),
            "approval",
        ),
        (
            "last push",
            json!({"required_approving_review_count": 0, "require_last_push_approval": true}),
            "approval",
        ),
        (
            "a team minimum",
            json!({"required_approving_review_count": 0, "required_reviewers": [{"minimum_approvals": 1}]}),
            "approval",
        ),
        (
            "an optional team",
            json!({"required_approving_review_count": 0, "required_reviewers": [{"minimum_approvals": 0}]}),
            "off",
        ),
    ] {
        let mut gh = Github::review_world();
        gh.answer(
            &rules(1),
            json!([{"type": "pull_request", "parameters": parameters}]),
        )
        .answer(
            &branch(),
            json!({"protected": false, "protection": {"enabled": false}}),
        );
        let result = ok_result(&gh.review(false, &[]));
        assert_eq!(result["mode"], mode, "{name}: {result}");
    }

    // A failed rules read on the first call is no mode: unreadable, nothing
    // recorded, never off.
    let mut gh = Github::review_world();
    gh.fail(&rules(1));
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "unreadable", "{result}");
    assert_eq!(result["reason"], "rules-read-failed");
    assert!(gh.state().get("pr_review").is_none());

    // A policy value outside `enforce` and `off` is refused, nothing read.
    let gh = Github::review_world();
    gh.policy("[env]\nREVIEW_GATE_MODE = \"junk\"\n");
    let out = gh.review(false, &[]);
    assert!(!out.status.success());
    assert_eq!(reply(&out)["refusal"]["key"], "setting-invalid", "{out:?}");
    assert!(gh.state().get("pr_review").is_none());
}

/// A request that sends nothing records why under the head, once: the
/// consumer's declared refresh head, Copilot requests off, a draft without
/// the ready mark, Copilot's no-files answer, and a refused POST with its
/// exit.
#[test]
fn a_request_falls_back_with_its_cause() {
    let refresh_policy = "[env]\nREVIEW_GATE_MODE = \"enforce\"\nREVIEW_GATE_REFRESH_REVIEW = \"overseer\"\nREVIEW_GATE_REFRESH_BRANCH = \"feat\"\nREVIEW_GATE_REFRESH_AUTHOR = \"lane-app[bot]\"\n";
    let no_files = "Copilot wasn't able to review any files in this pull request.";
    for (name, cause, requests) in [
        ("refresh", "refresh", 0),
        ("off", "off", 0),
        ("draft", "draft", 0),
        ("no-files", "no-files", 0),
        ("refused", "refused", 1),
    ] {
        let mut gh = Github::review_world();
        let mut env: Vec<(&str, &str)> = Vec::new();
        match name {
            "refresh" => gh.policy(refresh_policy),
            "off" => env.push(("PR_COPILOT_REQUESTS", "off")),
            "draft" => {
                gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
                    .answer(
                        &pull_path(),
                        rest_pull(true, "feat", "lane-app[bot]", "Bot"),
                    );
            }
            "no-files" => {
                gh.answer(
                    &format!("pr view {PR}"),
                    review_view("", &[(COPILOT, "COMMENTED")], false),
                )
                .answer(
                    &reviews_path(),
                    json!([copilot_review(
                        9,
                        "COMMENTED",
                        no_files,
                        "2026-01-01T00:00:00Z"
                    )]),
                );
            }
            "refused" => {
                gh.refused(
                    &format!("POST repos/{REPO}/pulls/{PR}/requested_reviewers"),
                    422,
                    "Validation Failed",
                );
            }
            _ => unreachable!(),
        }
        let result = ok_result(&gh.review(false, &env));
        assert_eq!(result["status"], "pending", "{name}: {result}");
        assert_eq!(result["request"]["outcome"], "fallback", "{name}: {result}");
        assert_eq!(result["request"]["cause"], cause, "{name}: {result}");
        assert_eq!(result["request"]["recorded_now"], true, "{name}");
        assert_eq!(gh.requests(), requests, "{name}: {:?}", gh.log());
        let record = gh.head_record()["request"].clone();
        assert_eq!(record["cause"], cause, "{name}: {record}");
        if name == "refused" {
            assert_eq!(record["exit"], 1, "{record}");
        }
        let again = ok_result(&gh.review(false, &env));
        assert_eq!(again["request"]["recorded_now"], false, "{name}: {again}");
        assert_eq!(gh.requests(), requests, "{name}: {:?}", gh.log());
    }

    // A refresh route outside `copilot` and `overseer`, or an overseer route
    // with no branch or author declared, is refused before any request.
    for policy in [
        "[env]\nREVIEW_GATE_MODE = \"enforce\"\nREVIEW_GATE_REFRESH_REVIEW = \"junk\"\n",
        "[env]\nREVIEW_GATE_MODE = \"enforce\"\nREVIEW_GATE_REFRESH_REVIEW = \"overseer\"\nREVIEW_GATE_REFRESH_AUTHOR = \"lane-app[bot]\"\n",
    ] {
        let gh = Github::review_world();
        gh.policy(policy);
        let out = gh.review(false, &[]);
        assert!(!out.status.success(), "{policy}");
        assert_eq!(reply(&out)["refusal"]["key"], "setting-invalid", "{policy}");
        assert_eq!(gh.requests(), 0, "{policy}: {:?}", gh.log());
    }
}

/// With `mark_ready`, an open draft is marked ready, the mark recorded
/// under the head before the act and the flag read after, and the request
/// then goes out on the confirmed head.
#[test]
fn a_draft_is_marked_ready_before_its_request() {
    let mut gh = Github::review_world();
    gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
        .answer(
            &pull_path(),
            rest_pull(true, "feat", "lane-app[bot]", "Bot"),
        )
        .answer(&format!("pr ready {PR}"), json!({}));
    let result = ok_result(&gh.review(true, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert_eq!(result["request"]["outcome"], "requested");
    let log = gh.log();
    let ready = log
        .iter()
        .position(|l| l == &format!("pr ready {PR} --repo {REPO}"));
    let request = log.iter().position(|l| l == REQUEST_LINE);
    assert!(
        ready.is_some() && request.is_some() && ready < request,
        "{log:?}"
    );
    assert_eq!(gh.head_record()["ready"], "done");
}

/// A request outside the pinned forms, a pull request number of zero or a
/// base checkout that is no directory refuses on the keyed line before
/// any read; a closed pull request refuses after the one view.
#[test]
fn an_invalid_review_request_refuses_before_any_read() {
    let gh = Github::review_world();
    for (field, body) in [
        (
            "pr",
            json!({"op": "verify-review", "repo": REPO, "pr": 0, "base_checkout": gh.base()}),
        ),
        (
            "repo",
            json!({"op": "verify-review", "repo": "owner", "pr": PR, "base_checkout": gh.base()}),
        ),
        (
            "base_checkout",
            json!({"op": "verify-review", "repo": REPO, "pr": PR, "base_checkout": gh.dir.path().join("absent")}),
        ),
    ] {
        let out = gh.op(&["--item", "KEN-4687"], body);
        assert_eq!(out.status.code(), Some(1), "{field}");
        assert_eq!(
            reply(&out)["refusal"]["key"],
            "verify-request-invalid",
            "{field}"
        );
        let line = String::from_utf8_lossy(&out.stderr)
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        assert_eq!(
            line,
            format!("orch-runtime: verify-request-invalid field={field}")
        );
    }
    assert!(gh.log().is_empty(), "{:?}", gh.log());
    assert!(gh.state().get("pr_review").is_none());

    let mut gh = Github::review_world();
    gh.answer(
        &format!("pr view {PR}"),
        with(review_view("", &[], false), "state", json!("MERGED")),
    );
    let out = gh.review(false, &[]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(reply(&out)["refusal"]["key"], "pr-not-open");
    assert_eq!(gh.log().len(), 1, "{:?}", gh.log());
    assert!(gh.state().get("pr_review").is_none());
}

/// The review settings are read by the review gate alone: a value outside
/// its form leaves every other verb running and refuses `verify-review`
/// by key and value, before any read.
#[test]
fn a_review_setting_outside_its_form_refuses_the_review_gate_alone() {
    for (key, value) in [
        ("PR_COPILOT_REQUESTS", "junk"),
        ("PR_REVIEW_ON_TIMEOUT", "bogus"),
        ("PR_REVIEW_WAIT_SECS", "soon"),
        ("ORCH_COPILOT_HOLD_SECS", "-1"),
    ] {
        let gh = Github::review_world();
        let got = support::isolated()
            .args(["--state-dir", &gh.dir.path().display().to_string()])
            .args(["state", "get", "--item", "KEN-4687", "/tier"])
            .env("PATH", support::tool_path(&[fixtures().as_path()]))
            .env(key, value)
            .current_dir(gh.dir.path())
            .output()
            .unwrap();
        assert_eq!(ok_result(&got)["value"], "standard", "{key}");
        let out = gh.review(false, &[(key, value)]);
        assert_eq!(out.status.code(), Some(1), "{key}");
        assert_eq!(reply(&out)["refusal"]["key"], "setting-invalid", "{key}");
        let line = String::from_utf8_lossy(&out.stderr)
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        assert_eq!(
            line,
            format!("orch-runtime: setting-invalid key={key} value={value}")
        );
        assert!(gh.log().is_empty(), "{key}: {:?}", gh.log());
    }
}

/// A ready mark GitHub refused stands `marking` under the head, and the
/// call the workflow repeats sends it again under either gate mode: the
/// repeat marks the draft, records it `done`, and under `approval` requests
/// the review. A head first seen without the mark is marked by a later
/// call that asks, and its `draft` fallback gives way to the request.
#[test]
fn a_refused_ready_mark_is_sent_again_and_its_request_follows() {
    let ready = format!("pr ready {PR} --repo {REPO}");
    let marks = |gh: &Github| gh.log().iter().filter(|line| **line == ready).count();
    for (policy, status, requests) in [("enforce", "pending", 1), ("off", "complete", 0)] {
        let mut gh = Github::review_world();
        gh.policy(&format!("[env]\nREVIEW_GATE_MODE = \"{policy}\"\n"));
        gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
            .answer(
                &pull_path(),
                rest_pull(true, "feat", "lane-app[bot]", "Bot"),
            )
            .fail(&format!("pr ready {PR}"));
        let first = ok_result(&gh.review(true, &[]));
        assert_eq!(first["status"], "unreadable", "{policy}: {first}");
        assert_eq!(first["reason"], "ready-failed", "{policy}");
        assert_eq!(gh.head_record()["ready"], "marking", "{policy}");
        gh.answer(&format!("pr ready {PR}"), json!({}));
        let second = ok_result(&gh.review(true, &[]));
        assert_eq!(second["status"], status, "{policy}: {second}");
        assert_eq!(marks(&gh), 2, "{policy}: {:?}", gh.log());
        assert_eq!(gh.head_record()["ready"], "done", "{policy}");
        assert_eq!(gh.requests(), requests, "{policy}: {:?}", gh.log());
        if policy == "off" {
            assert_eq!(second["verdict"], "off", "{second}");
        } else {
            assert_eq!(second["request"]["outcome"], "requested", "{second}");
        }
    }

    let mut gh = Github::review_world();
    gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
        .answer(
            &pull_path(),
            rest_pull(true, "feat", "lane-app[bot]", "Bot"),
        )
        .answer(&format!("pr ready {PR}"), json!({}));
    let first = ok_result(&gh.review(false, &[]));
    assert_eq!(first["request"]["cause"], "draft", "{first}");
    let second = ok_result(&gh.review(true, &[]));
    assert_eq!(marks(&gh), 1, "{:?}", gh.log());
    assert_eq!(second["request"]["outcome"], "requested", "{second}");
    assert_eq!(second["request"]["recorded_now"], true, "{second}");
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());
}

/// A ready mark whose answer was lost, its call killed before or after the
/// mark reached GitHub, stands `marking`: the next call reads the head's
/// draft flag, marks again only where it still reads draft, records `done`
/// either way and releases the `draft` fallback an earlier call recorded,
/// so the request goes out once. The mark that landed is settled by a call
/// that does not ask to mark. A head recorded `done` that a person returns
/// to draft is never marked over.
#[test]
fn a_ready_mark_whose_answer_was_lost_is_settled_by_the_heads_flag_and_its_request_follows() {
    let ready = format!("pr ready {PR} --repo {REPO}");
    let marks = |gh: &Github| gh.log().iter().filter(|line| **line == ready).count();
    for (landed, sent) in [(true, 1), (false, 2)] {
        let mut gh = Github::review_world();
        gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
            .answer(
                &pull_path(),
                rest_pull(true, "feat", "lane-app[bot]", "Bot"),
            );
        gh.replies.insert(
            format!("pr ready {PR}"),
            json!({"signal": "TERM", "landed": landed}),
        );
        let held = ok_result(&gh.review(false, &[]));
        assert_eq!(held["request"]["cause"], "draft", "{landed}: {held}");
        let lost = ok_result(&gh.review(true, &[]));
        assert_eq!(lost["status"], "unreadable", "{landed}: {lost}");
        assert_eq!(gh.head_record()["ready"], "marking", "{landed}");
        gh.answer(&format!("pr ready {PR}"), json!({}));
        let repeat = ok_result(&gh.review(!landed, &[]));
        assert_eq!(marks(&gh), sent, "{landed}: {:?}", gh.log());
        assert_eq!(gh.head_record()["ready"], "done", "{landed}");
        assert_eq!(
            repeat["request"]["outcome"], "requested",
            "{landed}: {repeat}"
        );
        assert_eq!(
            repeat["request"]["recorded_now"], true,
            "{landed}: {repeat}"
        );
        assert_eq!(gh.requests(), 1, "{landed}: {:?}", gh.log());

        let acts = gh.dir.path().join("replies.acts.json");
        let mut landed_acts: Value = serde_json::from_slice(&fs::read(&acts).unwrap()).unwrap();
        landed_acts.as_object_mut().unwrap().remove("ready");
        fs::write(&acts, landed_acts.to_string()).unwrap();
        ok_result(&gh.review(true, &[]));
        assert_eq!(
            marks(&gh),
            sent,
            "{landed}: a re-drafted head is marked over: {:?}",
            gh.log()
        );
        assert_eq!(gh.head_record()["ready"], "done", "{landed}");
    }
}

/// A draft made ready outside the gate, by a person or a lane's own `gh pr
/// ready`, lapses its `draft` fallback once the view and `pulls/N` both
/// read it ready, and the request goes out once; while the two reads
/// disagree the fallback stands, recorded and notified once.
#[test]
fn a_draft_made_ready_outside_the_gate_lapses_its_draft_fallback_once_both_reads_agree() {
    let mut gh = Github::review_world();
    gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
        .answer(
            &pull_path(),
            rest_pull(true, "feat", "lane-app[bot]", "Bot"),
        );
    let held = ok_result(&gh.review(false, &[]));
    assert_eq!(held["request"]["cause"], "draft", "{held}");
    assert_eq!(held["request"]["recorded_now"], true, "{held}");
    gh.answer(&format!("pr view {PR}"), review_view("", &[], false));
    let lagging = ok_result(&gh.review(false, &[]));
    assert_eq!(lagging["request"]["cause"], "draft", "{lagging}");
    assert_eq!(lagging["request"]["recorded_now"], false, "{lagging}");
    assert_eq!(gh.requests(), 0, "{:?}", gh.log());
    gh.answer(
        &pull_path(),
        rest_pull(false, "feat", "lane-app[bot]", "Bot"),
    );
    let ready = ok_result(&gh.review(false, &[]));
    assert_eq!(ready["request"]["outcome"], "requested", "{ready}");
    assert_eq!(ready["request"]["recorded_now"], true, "{ready}");
    assert_eq!(gh.requests(), 1, "{:?}", gh.log());
    assert!(
        !gh.log().iter().any(|line| line.starts_with("pr ready")),
        "{:?}",
        gh.log()
    );
}

/// A head that stood as a `draft` fallback past the review budget gets its
/// period from the request that releases it: the releasing call, whether
/// it marks the draft itself, settles a mark whose answer was lost, or
/// reads a draft made ready outside the gate, answers `pending` with the
/// request out, never a spent period's verdict.
#[test]
fn a_draft_fallback_released_past_the_budget_starts_its_period_with_the_request() {
    for route in ["marked", "lost-mark", "outside"] {
        let mut gh = Github::review_world();
        gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
            .answer(
                &pull_path(),
                rest_pull(true, "feat", "lane-app[bot]", "Bot"),
            );
        let held = ok_result(&gh.review(false, &[]));
        assert_eq!(held["request"]["cause"], "draft", "{route}: {held}");
        let aged = json!(stamp_ago(1000));
        gh.set_head("at", aged.clone());
        gh.set_head("period_started", aged.clone());
        let released = match route {
            "marked" => {
                gh.answer(&format!("pr ready {PR}"), json!({}));
                ok_result(&gh.review(true, &[]))
            }
            "lost-mark" => {
                gh.replies.insert(
                    format!("pr ready {PR}"),
                    json!({"signal": "TERM", "landed": true}),
                );
                let lost = ok_result(&gh.review(true, &[]));
                assert_eq!(lost["status"], "unreadable", "{lost}");
                gh.answer(&format!("pr ready {PR}"), json!({}));
                ok_result(&gh.review(true, &[]))
            }
            _ => {
                gh.answer(&format!("pr view {PR}"), review_view("", &[], false))
                    .answer(
                        &pull_path(),
                        rest_pull(false, "feat", "lane-app[bot]", "Bot"),
                    );
                ok_result(&gh.review(false, &[]))
            }
        };
        assert_eq!(released["status"], "pending", "{route}: {released}");
        assert_eq!(released["request"]["outcome"], "requested", "{route}");
        assert_eq!(gh.requests(), 1, "{route}: {:?}", gh.log());
        let head = gh.head_record();
        assert_ne!(head["period_started"], aged, "{route}: {head}");
        assert_ne!(head["at"], aged, "{route}: {head}");
    }
}

/// Defect: a head held as a `draft` fallback past the review budget gets a
/// spent period's verdict (`proceeded` with no request ever made, or a
/// counted `timeout`) on a call that cannot release it: the head still
/// draft, or the view reading it ready while `pulls/N` still reads draft.
/// Under either timeout answer each such call is `pending` with the draft
/// cause and records no verdict; the call where both reads agree releases
/// it, and its request starts the period.
#[test]
fn a_draft_fallback_past_the_budget_takes_no_period_verdict_until_both_reads_release_it() {
    for on_timeout in ["proceed", "block"] {
        let env = [("PR_REVIEW_ON_TIMEOUT", on_timeout)];
        let mut gh = Github::review_world();
        gh.answer(&format!("pr view {PR}"), review_view("", &[], true))
            .answer(
                &pull_path(),
                rest_pull(true, "feat", "lane-app[bot]", "Bot"),
            );
        let held = ok_result(&gh.review(false, &env));
        assert_eq!(held["request"]["cause"], "draft", "{on_timeout}: {held}");
        let aged = json!(stamp_ago(1000));
        gh.set_head("at", aged.clone());
        gh.set_head("period_started", aged.clone());
        let still_draft = ok_result(&gh.review(false, &env));
        gh.answer(&format!("pr view {PR}"), review_view("", &[], false));
        let lagging = ok_result(&gh.review(false, &env));
        for (call, result) in [("still-draft", &still_draft), ("lagging", &lagging)] {
            assert_eq!(result["status"], "pending", "{on_timeout} {call}: {result}");
            assert_eq!(key(result), "request-fallback", "{on_timeout} {call}");
            assert_eq!(result["request"]["cause"], "draft", "{on_timeout} {call}");
        }
        assert_eq!(gh.requests(), 0, "{on_timeout}: {:?}", gh.log());
        assert!(gh.review_record()["verdict"].is_null(), "{on_timeout}");
        assert_eq!(gh.head_record()["timeouts"], 0, "{on_timeout}");
        gh.answer(
            &pull_path(),
            rest_pull(false, "feat", "lane-app[bot]", "Bot"),
        );
        let released = ok_result(&gh.review(false, &env));
        assert_eq!(released["status"], "pending", "{on_timeout}: {released}");
        assert_eq!(key(&released), "review-pending", "{on_timeout}");
        assert_eq!(released["request"]["outcome"], "requested", "{on_timeout}");
        assert_eq!(gh.requests(), 1, "{on_timeout}: {:?}", gh.log());
        assert_ne!(gh.head_record()["period_started"], aged, "{on_timeout}");
    }
}

/// Defect: Copilot's error answer on a head held as a draft read as the
/// error retry's verdict, `copilot-error cause=draft`, which routes to a
/// fallback notice for a draft that took no request; or the retry claimed
/// apart from the request that releases the head, a second POST. Within
/// the budget and past it, each call on the draft is `pending` with the
/// draft cause, claims no retry and sends nothing; the call where both
/// reads say ready sends one POST, recorded as the request and as the
/// error answer's retry, and a later call sends nothing more.
#[test]
fn copilot_error_on_a_draft_held_head_waits_for_the_release_whose_one_request_is_its_retry() {
    for aged in [false, true] {
        let mut gh = Github::review_world();
        gh.answer(
            &format!("pr view {PR}"),
            review_view("", &[(COPILOT, "COMMENTED")], true),
        )
        .answer(
            &pull_path(),
            rest_pull(true, "feat", "lane-app[bot]", "Bot"),
        )
        .answer(
            &reviews_path(),
            json!([copilot_review(
                11,
                "COMMENTED",
                COPILOT_ERROR,
                "2026-01-01T00:05:00Z"
            )]),
        );
        let first = ok_result(&gh.review(false, &[]));
        if aged {
            gh.set_head("at", json!(stamp_ago(1000)));
            gh.set_head("period_started", json!(stamp_ago(1000)));
        }
        let again = ok_result(&gh.review(false, &[]));
        for (call, result) in [("first", &first), ("again", &again)] {
            assert_eq!(result["status"], "pending", "aged={aged} {call}: {result}");
            assert_eq!(key(result), "request-fallback", "aged={aged} {call}");
            assert_eq!(result["request"]["cause"], "draft", "aged={aged} {call}");
        }
        assert_eq!(gh.requests(), 0, "aged={aged}: {:?}", gh.log());
        assert!(gh.review_record()["verdict"].is_null(), "aged={aged}");
        assert!(gh.head_record()["retry"].is_null(), "aged={aged}");
        gh.answer(
            &format!("pr view {PR}"),
            review_view("", &[(COPILOT, "COMMENTED")], false),
        )
        .answer(
            &pull_path(),
            rest_pull(false, "feat", "lane-app[bot]", "Bot"),
        );
        let released = ok_result(&gh.review(false, &[]));
        assert_eq!(released["status"], "pending", "aged={aged}: {released}");
        assert_eq!(released["request"]["outcome"], "requested", "aged={aged}");
        assert_eq!(gh.requests(), 1, "aged={aged}: {:?}", gh.log());
        let head = gh.head_record();
        assert_eq!(head["retry"]["outcome"], "requested", "aged={aged}: {head}");
        assert_eq!(head["retry"]["review_id"], 11, "aged={aged}: {head}");
        let later = ok_result(&gh.review(false, &[]));
        assert_eq!(later["status"], "pending", "aged={aged}: {later}");
        assert_eq!(gh.requests(), 1, "aged={aged}: {:?}", gh.log());
    }
}

/// A POST that ended with no exit status, as a call killed or timed out
/// leaves it, may or may not have reached GitHub: the request stands
/// `requested`, and the next call reads GitHub's record of it. With no sign
/// of it (no Copilot work, no request event since the head's record, no
/// review on the head) the request is sent once more under its `resent`
/// mark; a request GitHub recorded is never sent again, and a second miss
/// falls back `unconfirmed`, written on that call so the fallback notice
/// goes out. The error retry reads the same way, and its second miss is
/// the `copilot-error` verdict.
#[test]
fn a_request_whose_answer_was_lost_is_sent_once_more_then_falls_back_unconfirmed() {
    let post = format!("POST repos/{REPO}/pulls/{PR}/requested_reviewers");

    // The resend lands, and GitHub's record of it stands from then on.
    let mut gh = Github::review_world();
    gh.killed(&post);
    let first = ok_result(&gh.review(false, &[]));
    assert_eq!(first["status"], "unreadable", "{first}");
    assert_eq!(first["reason"], "request-review-read-failed");
    assert_eq!(gh.head_record()["request"]["outcome"], "requested");
    gh.answer(&post, json!({}));
    let second = ok_result(&gh.review(false, &[]));
    assert_eq!(second["status"], "pending", "{second}");
    assert_eq!(gh.requests(), 2, "{:?}", gh.log());
    assert_eq!(gh.head_record()["request"]["resent"], true);
    let third = ok_result(&gh.review(false, &[]));
    assert_eq!(third["request"]["outcome"], "requested", "{third}");
    assert_eq!(gh.requests(), 2, "{:?}", gh.log());

    // The resend is lost too: the request falls back once.
    let mut gh = Github::review_world();
    gh.killed(&post);
    for _ in 0..2 {
        let lost = ok_result(&gh.review(false, &[]));
        assert_eq!(lost["status"], "unreadable", "{lost}");
    }
    assert_eq!(gh.requests(), 2, "{:?}", gh.log());
    let third = ok_result(&gh.review(false, &[]));
    assert_eq!(third["request"]["outcome"], "fallback", "{third}");
    assert_eq!(third["request"]["cause"], "unconfirmed");
    assert_eq!(third["request"]["recorded_now"], true);
    let fourth = ok_result(&gh.review(false, &[]));
    assert_eq!(fourth["request"]["recorded_now"], false, "{fourth}");
    assert_eq!(gh.requests(), 2, "{:?}", gh.log());

    // A POST whose transport failed, or that GitHub answered with a 5xx,
    // has no answer from GitHub on the request and is no refusal: the
    // request stands, and the next call finds it landed or sends it once
    // more.
    for (landed, sent, server_error) in [(true, 1, false), (false, 2, false), (false, 2, true)] {
        let mut gh = Github::review_world();
        if server_error {
            gh.refused(&post, 502, "Bad Gateway");
        } else {
            gh.unreachable(&post, landed);
        }
        let lost = ok_result(&gh.review(false, &[]));
        assert_eq!(lost["status"], "unreadable", "{landed}: {lost}");
        assert_eq!(lost["reason"], "request-review-read-failed", "{landed}");
        assert_eq!(
            gh.head_record()["request"]["outcome"],
            "requested",
            "{landed}"
        );
        gh.answer(&post, json!({}));
        let next = ok_result(&gh.review(false, &[]));
        assert_eq!(next["status"], "pending", "{landed}: {next}");
        assert_eq!(next["request"]["outcome"], "requested", "{landed}: {next}");
        assert_eq!(gh.requests(), sent, "{landed}: {:?}", gh.log());
        assert_eq!(
            gh.head_record()["request"]["resent"] == json!(true),
            !landed,
            "{landed}: {}",
            gh.head_record()
        );
    }

    // A request event from before the head's record, made on the head
    // before it, is no sign of this head's request, though the head's
    // commit is dated earlier still.
    let mut gh = Github::review_world();
    gh.answer(
        &timeline_path(),
        json!([
            {"event": "committed", "sha": HEAD, "committer": {"date": "2026-01-01T00:00:00Z"}},
            {"event": "review_requested", "id": 72, "created_at": "2026-01-01T00:05:00Z", "requested_reviewer": {"login": "Copilot"}},
            {"event": "reviewed", "submitted_at": "2026-01-01T00:06:00Z", "user": {"login": COPILOT_REST}}
        ]),
    )
    .killed(&post);
    let lost = ok_result(&gh.review(false, &[]));
    assert_eq!(lost["status"], "unreadable", "{lost}");
    gh.answer(&post, json!({}));
    let resent = ok_result(&gh.review(false, &[]));
    assert_eq!(resent["status"], "pending", "{resent}");
    assert_eq!(gh.requests(), 2, "{:?}", gh.log());
    assert_eq!(gh.head_record()["request"]["resent"], true);

    // The error retry: Copilot answered the first request with its error,
    // so a request event older than the error is no sign of the retry.
    for lands in [true, false] {
        let mut gh = Github::review_world();
        gh.answer(
            &format!("pr view {PR}"),
            review_view("", &[(COPILOT, "COMMENTED")], false),
        )
        .answer(
            &reviews_path(),
            json!([copilot_review(11, "COMMENTED", COPILOT_ERROR, "2026-01-01T00:05:00Z")]),
        )
        .answer(
            &timeline_path(),
            json!([
                {"event": "review_requested", "id": 70, "created_at": "2026-01-01T00:00:00Z", "requested_reviewer": {"login": "Copilot"}},
                {"event": "reviewed", "submitted_at": "2026-01-01T00:05:00Z", "user": {"login": COPILOT_REST}}
            ]),
        )
        .killed(&post);
        let first = ok_result(&gh.review(false, &[]));
        assert_eq!(first["status"], "unreadable", "{lands}: {first}");
        assert_eq!(gh.head_record()["retry"]["outcome"], "requested");
        if lands {
            gh.answer(&post, json!({}));
        }
        let second = ok_result(&gh.review(false, &[]));
        assert_eq!(gh.requests(), 2, "{lands}: {:?}", gh.log());
        assert_eq!(gh.head_record()["retry"]["resent"], true, "{lands}");
        let third = ok_result(&gh.review(false, &[]));
        assert_eq!(gh.requests(), 2, "{lands}: {:?}", gh.log());
        if lands {
            assert_eq!(second["status"], "pending", "{second}");
            assert_eq!(third["status"], "pending", "{third}");
        } else {
            assert_eq!(third["verdict"], "copilot-error", "{third}");
            assert_eq!(third["reason"], "copilot-error cause=unconfirmed");
            assert_eq!(gh.head_record()["retry"]["outcome"], "fallback");
        }
    }
}

/// An error answer's retry is decided with the request: a request the
/// policy held back holds the retry back, answering `copilot-error` with
/// its cause once; Copilot's work already in flight stands for the retry;
/// and a retry the released writer recorded under
/// `pr_approval.copilot_error_retries` is the head's retry, carried into
/// its record. None of them is requested again.
#[test]
fn an_error_retry_in_flight_or_released_is_not_requested_again() {
    let error_world = || {
        let mut gh = Github::review_world();
        gh.answer(
            &format!("pr view {PR}"),
            review_view("", &[(COPILOT, "COMMENTED")], false),
        )
        .answer(
            &reviews_path(),
            json!([copilot_review(
                11,
                "COMMENTED",
                COPILOT_ERROR,
                "2026-01-01T00:05:00Z"
            )]),
        );
        gh
    };

    let mut gh = error_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(1, vec![copilot_check(31, "queued")]),
    );
    for _ in 0..2 {
        let result = ok_result(&gh.review(false, &[]));
        assert_eq!(result["status"], "pending", "{result}");
        assert_eq!(gh.requests(), 0, "{:?}", gh.log());
    }
    assert_eq!(gh.head_record()["retry"]["outcome"], "existing");
    assert_eq!(gh.head_record()["retry"]["review_id"], 11);

    let gh = error_world();
    gh.policy("[env]\nREVIEW_GATE_MODE = \"enforce\"\nREVIEW_GATE_REFRESH_REVIEW = \"overseer\"\nREVIEW_GATE_REFRESH_BRANCH = \"feat\"\nREVIEW_GATE_REFRESH_AUTHOR = \"lane-app[bot]\"\n");
    let held = ok_result(&gh.review(false, &[]));
    assert_eq!(held["verdict"], "copilot-error", "{held}");
    assert_eq!(held["reason"], "copilot-error cause=refresh");
    let again = ok_result(&gh.review(false, &[]));
    assert_eq!(again["status"], "pending", "{again}");
    assert_eq!(gh.requests(), 0, "{:?}", gh.log());

    // The released writer's retry: a `requested` one GitHub recorded after
    // the error, and a `fallback` one.
    for (outcome, request, timeline) in [
        (
            "requested",
            "existing",
            json!([{"event": "review_requested", "id": 71, "created_at": "2026-01-01T00:06:00Z", "requested_reviewer": {"login": "Copilot"}}]),
        ),
        ("fallback", "fallback", json!([])),
    ] {
        let mut gh = error_world();
        gh.answer(&timeline_path(), timeline);
        let mut state = gh.state();
        state["pr_approval"] =
            json!({"copilot_error_retries": {HEAD: {"review_id": "11", "outcome": outcome}}});
        fs::write(gh.item(), serde_json::to_vec_pretty(&state).unwrap()).unwrap();
        for _ in 0..2 {
            let result = ok_result(&gh.review(false, &[]));
            assert_eq!(result["status"], "pending", "{outcome}: {result}");
            assert_eq!(result["request"]["outcome"], request, "{outcome}: {result}");
        }
        assert_eq!(gh.requests(), 0, "{outcome}: {:?}", gh.log());
        assert_eq!(gh.head_record()["retry"]["review_id"], 11, "{outcome}");
        assert_eq!(gh.head_record()["retry"]["outcome"], outcome, "{outcome}");
    }
}

/// Copilot's work in flight within its hold keeps every verdict that
/// permits a merge `pending`: an approval while Copilot's check runs is
/// recorded only once the hold is spent, and a review period shorter than
/// the hold proceeds only once the hold is spent too.
#[test]
fn copilot_work_in_flight_holds_a_verdict_that_permits_a_merge() {
    let mut gh = Github::review_world();
    gh.answer(
        &format!("pr view {PR}"),
        review_view("APPROVED", &[("colleague", "APPROVED")], false),
    )
    .answer(
        &check_runs(HEAD, 1),
        check_runs_page(1, vec![copilot_check(31, "in_progress")]),
    );
    let held = ok_result(&gh.review(false, &[]));
    assert_eq!(held["status"], "pending", "{held}");
    assert_eq!(held["copilot"]["state"], "pending");
    assert!(
        gh.review_record()["verdict"].is_null(),
        "{}",
        gh.review_record()
    );
    gh.set_head("at", json!(stamp_ago(601)));
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["verdict"], "approved", "{result}");

    let mut gh = Github::review_world();
    gh.answer(
        &check_runs(HEAD, 1),
        check_runs_page(1, vec![copilot_check(31, "in_progress")]),
    );
    let short = &[("PR_REVIEW_WAIT_SECS", "300")];
    let first = ok_result(&gh.review(false, short));
    assert_eq!(first["status"], "pending", "{first}");
    gh.set_head("at", json!(stamp_ago(301)));
    gh.set_head("period_started", json!(stamp_ago(301)));
    let held = ok_result(&gh.review(false, short));
    assert_eq!(held["status"], "pending", "{held}");
    assert_eq!(held["copilot"]["state"], "pending");
    gh.set_head("at", json!(stamp_ago(601)));
    let result = ok_result(&gh.review(false, short));
    assert_eq!(result["verdict"], "proceeded", "{result}");
}

/// The review-thread walk counts every page and refuses what it cannot
/// verify: an unresolved thread on a later page holds the head at
/// `comments`; a partial reply (an `errors` array beside data), a null
/// thread set, a next page with no cursor or one that does not advance,
/// and a failed query are each `unreadable` with no verdict and nothing
/// recorded, never an approval on the pages that could be read. A cursor
/// that repeats is refused on the page that repeats it, not after the page
/// bound.
#[test]
fn a_thread_on_a_later_page_holds_the_head_and_an_unverifiable_page_never_approves() {
    let approved = || review_view("APPROVED", &[("colleague", "APPROVED")], false);
    let paged = |unresolved: usize, cursor: Value| {
        let mut page = threads_page(unresolved);
        page["data"]["repository"]["pullRequest"]["reviewThreads"]["pageInfo"] =
            json!({"hasNextPage": true, "endCursor": cursor});
        page
    };
    let second = format!("{THREADS}page2");
    let thread_reads = |gh: &Github| gh.log().iter().filter(|l| l.contains("number=7")).count();

    let mut gh = Github::review_world();
    gh.answer(&format!("pr view {PR}"), approved())
        .answer(THREADS, paged(0, json!("page2")))
        .answer(&second, threads_page(1));
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "complete", "{result}");
    assert_eq!(result["verdict"], "comments", "{result}");
    assert_eq!(result["unresolved_count"], 1, "{result}");
    assert_eq!(gh.review_record()["verdict"]["verdict"], "comments");
    assert_eq!(thread_reads(&gh), 2, "{:?}", gh.log());

    struct Row {
        name: &'static str,
        first: Value,
        second: Option<Value>,
        reads: usize,
    }
    let rows = [
        Row {
            name: "an errors array beside data",
            first: {
                let mut page = threads_page(0);
                page["errors"] = json!([{"message": "an unread page"}]);
                page
            },
            second: None,
            reads: 1,
        },
        Row {
            name: "a null thread set",
            first: json!({"data": {"repository": {"pullRequest": {"reviewThreads": null}}}}),
            second: None,
            reads: 1,
        },
        Row {
            name: "a next page with an empty cursor",
            first: paged(0, json!("")),
            second: None,
            reads: 1,
        },
        Row {
            name: "a next page with a null cursor",
            first: paged(0, Value::Null),
            second: None,
            reads: 1,
        },
        Row {
            name: "a cursor that does not advance",
            first: paged(0, json!("page2")),
            second: Some(paged(1, json!("page2"))),
            reads: 2,
        },
    ];
    for row in rows {
        let mut gh = Github::review_world();
        gh.answer(&format!("pr view {PR}"), approved())
            .answer(THREADS, row.first);
        if let Some(page) = row.second {
            gh.answer(&second, page);
        }
        let result = ok_result(&gh.review(false, &[]));
        assert_eq!(result["status"], "unreadable", "{}: {result}", row.name);
        assert!(result["verdict"].is_null(), "{}: {result}", row.name);
        assert!(gh.review_record()["verdict"].is_null(), "{}", row.name);
        assert_eq!(thread_reads(&gh), row.reads, "{}: {:?}", row.name, gh.log());
    }

    let mut gh = Github::review_world();
    gh.answer(&format!("pr view {PR}"), approved())
        .fail(THREADS);
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "unreadable", "{result}");
    assert!(
        result["verdict"].is_null() && gh.review_record()["verdict"].is_null(),
        "{result}"
    );
}

/// The request is made on the head the view read: a `pulls/N` read that
/// names another head is `pending` with `head-moved`, no request sent and
/// nothing claimed, so the next call judges the head that stands rather
/// than asking Copilot for a review of one it has not read.
#[test]
fn a_head_that_moved_between_the_view_and_the_pull_read_is_pending_with_no_request() {
    let mut gh = Github::review_world();
    gh.answer(
        &pull_path(),
        json!({"state": "open", "draft": false, "head": {"sha": NEXT, "ref": "feat"}, "base": {"ref": BASE}, "user": {"login": "lane-app[bot]", "type": "Bot"}}),
    );
    let result = ok_result(&gh.review(false, &[]));
    assert_eq!(result["status"], "pending", "{result}");
    assert!(
        result["reason"]
            .as_str()
            .is_some_and(|reason| reason.starts_with("head-moved head=")),
        "{result}"
    );
    assert_eq!(gh.requests(), 0, "{:?}", gh.log());
    assert!(
        gh.head_record()["request"].is_null(),
        "{}",
        gh.head_record()
    );
}
