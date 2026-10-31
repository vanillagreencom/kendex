//! The `verify-head` operation (decision 93) through the built binary
//! against a fake `gh` on PATH: the pinned reads, the closed decoding and
//! completeness of every reply, the decision rows the verdict pins, the
//! required workflow's binding proof, the `none` route over every absence
//! page, and the record written on `complete`. The fake answers from a
//! JSON map the row builds, starting from the documented replies beside
//! it, and logs every call, so a row can assert what was read and what
//! never was. The differential against the legacy's own functions over a
//! corpus (decision 107 (3)) is the crate's `verify::differential` test,
//! which builds its evidence through the same reads over a fake transport.
#![allow(
    clippy::disallowed_methods,
    reason = "the process tests run the built binary against a fake gh on PATH"
)]

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use orch_runtime::error::Error;
use orch_runtime::ops::{Env, Request, VerifyHead, apply};
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

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_orch-runtime"))
}

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

/// Every check run on the commit, the set the legacy rollup carried, not
/// GitHub's `latest` selection, which the suite read below consumes.
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
/// under the endpoint's default `filter=latest`: the bound-job list the
/// legacy read (decision 117 (1)).
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

    /// Run `verify-head` for `head` on the base as one call of the binary
    /// with the fake ahead of the inherited PATH.
    fn verify_head(&self, head: &str, required_only: bool) -> Output {
        self.verify_target(&["--item", "KEN-4687"], head, required_only)
    }

    fn verify_target(&self, target: &[&str], head: &str, required_only: bool) -> Output {
        let replies = self.dir.path().join("replies.json");
        fs::write(&replies, serde_json::to_vec(&self.replies).unwrap()).unwrap();
        let request = self.dir.path().join("request.json");
        fs::write(
            &request,
            json!({"op": "verify-head", "repo": REPO, "base": BASE, "head": head, "required_only": required_only}).to_string(),
        )
        .unwrap();
        let inherited = std::env::var("PATH").unwrap_or_default();
        Command::new(binary())
            .args(["--state-dir", &self.dir.path().display().to_string()])
            .arg("--no-private-env")
            .arg("op")
            .args(target)
            .arg("--request")
            .arg(&request)
            .env("PATH", format!("{}:{inherited}", fixtures().display()))
            .env("GH_FAKE_REPLIES", &replies)
            .env("GH_FAKE_LOG", self.dir.path().join("gh.log"))
            .env("ORCH_STATE_DIR", "")
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
/// the flag with nothing named, the legacy `all_checks` fallback).
enum Scope {
    All,
    RequiredOnly(Vec<Value>),
}

/// One verdict row: the head's evidence and the answer, structured
/// (decision 107 (5)): the status, the verdict, the pending cause key and
/// the reported members.
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

/// Run one verdict row against the green world and assert its answer, the
/// record's presence following the verdict, and every read pinned.
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
    assert_eq!(checks(&result), r.checks, "{}: {result}", r.name);
    assert_eq!(
        result.get("recorded").is_some(),
        r.verdict.is_some(),
        "{}",
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

/// Decision 93: a final verdict is recorded through `record-verification`
/// in the same call, and a later verdict replaces it. Without
/// `required_only` the base's rules and protection are not read; the
/// check-suites count is read beside the check runs, and the workflows
/// beside the runs, for the name each run's workflow carries. The two
/// documented check runs started alike, so the later-listed, higher id
/// is reported first (decision 117 (3)).
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

/// The decisions the verdict pins beyond what the oracle corpus holds:
/// decision 113's taxonomy, the wire's nullable run status, the empty head,
/// the skipped-check flag (R-U4e6 H2), the substantive events (decision
/// 107 (4)) and the held failure's relabel. Every other state combination
/// is the corpus's (`the_operation_and_the_legacy_oracle_agree_over_the_corpus`).
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

/// Decisions 112 (2) and 114 (2): a failed job's run is read from its
/// link, the check run's `details_url`, with the suite as the agreeing
/// second source. With the check's REST `check_suite` null the suite is
/// read through the check-run node and the failure is still held by its
/// in-progress run; a failed check whose link names a run the head does
/// not hold is unresolved and held while a substantive run is in flight,
/// and terminal once none is; a check with no link at all in an external
/// suite is a proved external failure, terminal at once; a check with no
/// link whose node names a run GitHub does not identify (`databaseId`
/// null) is unresolved, held while the push run is in flight, and records
/// nothing (R-U4e10 H1).
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

/// Decision 114 (3): a run whose workflow the repository's list lacks is
/// judged under the workflow fetched by id, as gh fetches it, so a
/// successful historical run of a deleted workflow passes; membership in
/// the list is no prerequisite. The fetch's refusals are in the malformed
/// table.
/// Decision 117 (4): a job's workflow name the repository's list lacks is
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
    // joined to the run, so the detail by id is still tried and names it
    // (decision 119 (2)).
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
    // tried and names it, after the graph was asked (decision 123 (2);
    // R-U4e15-codex M1).
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
    // the workflow, so the detail, answering 404, is never asked
    // (decisions 122 (4), 123 (2)).
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

/// Decision 87: `none` holds only once every absence probe was read to its
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

/// Decisions 87, 93, 106 and 107: a reply outside the documented shape or
/// value set, a page set that does not add up, a collection at its
/// endpoint's cap and a failed request each end `unreadable` with the
/// endpoint's cause, never a verdict, whether or not the selection would
/// have discarded the malformed member. The rows are R-U4e2's six
/// replies, R-U4e's Actions replies, the snapshot's own, R-U4e5 H1's
/// absent or null required fields, R-U4e6 H1's present nulls on fields
/// documented optional and not nullable, and R-U4e7 H1's discarded
/// members, non-object parameters and caps.
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
        // R-U4e5 H1: a required field that is absent or null is not an
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
        // Decision 110 (1): the binding proof's own replies refuse like
        // every other: a nodes answer without its data (gh exits nonzero
        // on every reply carrying errors, so its cause is the failed
        // call's, the line it wrote to stderr), one without its nodes, a
        // repository answer for another name, and failed requests. The one
        // reply carrying errors that is read, a field error at a node's
        // own path, leaves the candidate unproven instead (decisions 122
        // (4), 123 (2); the binding test's unproven rows). A failed call
        // that printed a complete, error-free answer is read through no
        // error: its output is not admitted, and its failure is the cause
        // with what it printed (R-U4e15-codex M1).
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
        // R-U4e6 H1: a present null on a field documented optional and not
        // nullable is not the legacy's default for omission.
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
        // R-U4e7 H1: a member the selection would discard is validated
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
        // Decision 112 (2): the check-run nodes read, made for a check
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
        // Decisions 122 (4) and 123 (2): gh prints a reply carrying errors
        // and exits nonzero; an error at a node's own path leaves that node
        // null and the reply readable through that exit, and an error at
        // any other path, or beside a present node, leaves the call's
        // failure as the cause, as the legacy refused every error. A failed
        // call that printed a complete, error-free answer is read through
        // no error, so for an unjoined check nothing names its suite
        // (R-U4e15-codex M1).
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
        // Decisions 117 (4) and 119 (2): a job's workflow name the list
        // lacks is read through the graph, then by id; the detail is
        // reached once the graph did not resolve the check's node or the
        // graph request failed, and a detail that fails or answers another
        // shape leaves the name unreadable by every route.
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
        // Decision 117 (1): the suite read of a bound run refuses like
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

/// Decision 87: every read names the pinned sha; the branch's later head
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

/// Decisions 87 and 110 (1): a required workflow binds to a run only when
/// the run's own workflow file is the rule's path and its suite node proves
/// that file at the rule's explicit source sha in the repository whose id
/// the rule names; never through a resolved ref. Its members are the bound
/// run's check runs as its suite's `latest` listing names them (decisions
/// 107 (2), 117 (1)). Every unproven part leaves the requirement expected,
/// never passed and never failed.
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

    // Decisions 114 (2) and 117 (1): the bound run's jobs are its suite's
    // own listing, so a check run whose suite the ref's listing nulls is
    // the bound run's job whether its node identifies the run or names it
    // without an id; the member is the job the rollup links to the run.
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

    // Decision 117 (1): the suite lists `request` twice, completed in the
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
            // node is null and the candidate unproven, as the legacy held
            // an unreadable required set pending (`ci-wait:897-905`;
            // decisions 122 (4), 123 (2)).
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
            // The legacy's `pending` for a bound run whose suite lists no
            // check run (`ci-run-correlation.sh:500-503`).
            name: "the bound run's suite lists no check run",
            set: |gh| {
                gh.answer(&suite_check_runs(700, 1), check_runs_page(0, vec![]));
            },
        },
        Unproven {
            // The legacy's `error` for a listed job without a page (`:492`).
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

/// Decision 110 (2): the definitions are walked in the legacy's sorted
/// order and the first that is not ready ends the read: an earlier
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

/// R-U4e5 M1: every documented rule type decodes, and the four that gate on
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

/// R-U4e6 H1: the selection fields documented optional keep the legacy's
/// reading for omission (`run_attempt // 1`, `run_started_at //
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

/// R-U4e5 L1: the target's kind is checked before any read, so a
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

/// `apply` is the transition path; the verification's reads come before
/// its transition, so the library refuses the request there.
#[test]
fn apply_refuses_verify_head_as_a_transition() {
    let gh = Github::empty();
    let request = Request::VerifyHead(VerifyHead {
        repo: REPO.into(),
        base: BASE.into(),
        head: HEAD.into(),
        required_only: true,
    });
    let env = Env {
        now_secs: 1_769_700_000,
        now_nanos: 1_769_700_000_123_456_789,
        nonce: 4242,
        owner: None,
    };
    match apply(&gh.item(), &request, &env, Locking::FLOCK) {
        Err(Error::OpNotTransition { op }) => assert_eq!(op, "verify-head"),
        other => panic!("{other:?}"),
    }
    assert!(Path::new(&gh.item()).exists());
}
