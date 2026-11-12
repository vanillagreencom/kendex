//! The GitHub read duty, one
//! body on `Duty::GitHub` on the long cadence after the tracker: the
//! merged index of every lane item, the parked dependency's state, the
//! refresh workflow's last runs, the main branch's push and nightly runs
//! and their budget warnings, the reducer pass (`pr_watch`), the outside
//! contributions (`outside`) and the security alerts (`security`), each
//! read once per pass through `gh api` via the one runner, decoded at the
//! boundary in the verify module's wire forms (`T`, `Optional<T>`,
//! `Nullable<T>`), and paginated with the page set's
//! total checked against what arrived. A failed call, a malformed member
//! or a page set that disagrees with its total refuses the inventory with
//! its cause and never reads as an empty one; the refusal is
//! this duty's, printed as `watch-step-failed step=github`, so a GitHub
//! refusal discards no tracker news and no close. A refused sign-in is
//! renewed for every duty's reads (§ the sign-in); one that cannot be
//! renewed is also the owner's turn, `github-auth-failed`.
//!
//! The tracker's terminal verdicts the parked-merged hand consults come
//! through the slot the tracker duty writes (`tracker::Shared`), which
//! this duty's inventory joins: both bodies run on the shared thread, the
//! tracker first in the tie order, each writing its own member.
//!
//! The reads name an object by its own identity, a repository and a
//! number, a workflow file, a run or job id, or a head by owner and
//! branch; a search for an item's mention is bounded
//! by the search endpoint's documented cap, past which it is refused
//! (`github-capped`).

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use agent_runtime::clock;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::state::{self, FleetState, Lane, LaneStatus};
use crate::verify::wire::{
    Issue, Job, Nullable, Optional, Pull, RunStatus, RunsPage, WorkflowRun, WorkflowsPage,
};
use crate::verify::{self, Answer, Failed, Gh, MAX_PAGES, PER_PAGE, Page, Unrun};
use crate::watch::{Baseline, Body, Change, Event, Produced, Tick};

use super::owner_alert::{self, Word};
use super::tracker::{Shared, TerminalState};
use super::{outside, pr_watch, security};

/// The start-counter tag every GitHub call is counted under.
const TAG: &str = "github";

/// The search endpoint's documented cap on results: a search reaching it
/// is refused, never read as the whole set.
const SEARCH_CAP: usize = 1000;

/// The default-branch workflows a red main is read from, beside the
/// declared ones.
const MAIN_WORKFLOWS: [&str; 2] = ["skill-tests.yml", "ci.yml"];

/// The refresh workflow the consumer-refresh incident reads.
const REFRESH_WORKFLOW: &str = "kendex-refresh.yml";

/// Baseline row kinds this module owns.
pub const MERGED_ROW: &str = "merged";
pub const PARKED_UNTIL_ROW: &str = "parked-until";
pub const REFRESH_ROW: &str = "refresh-failing";
pub const MAIN_PUSH_ROW: &str = "main-push-failing";
pub const MAIN_SCHEDULE_ROW: &str = "main-schedule-failing";
pub const MAIN_ABSENT_ROW: &str = "main-workflow-absent";

/// The repository the refresh pull request's merged line names; its row
/// is kept through the prune.
pub(super) const REFRESH_ITEM: &str = "kendex/refresh";

/// The workflow whose completed runs carry the budget annotations.
const BUDGET_WORKFLOW: &str = "skill-tests.yml";

/// Baseline row kind of the budget scan's state.
pub const MAIN_BUDGET_ROW: &str = "main-push-budget";

/// The prefix of a budget warning's message.
const BUDGET_WARNING: &str = "run-all-budget ";

/// Baseline row kind of the owner's turn for a sign-in that cannot be
/// renewed: one row, under the one key, holding the turn's word.
pub const SIGN_IN_ROW: &str = "github-auth";
const SIGN_IN_KEY: &str = "github";
const SIGN_IN_STATE: &str = "unrenewed";

/// The owner's notice of that sign-in, under the state directory.
const SIGN_IN_ALERT_FILE: &str = "github-auth-failed.txt";

// --- what a pass hands over -----------------------------------------------------

/// What the GitHub reads of one pass settled, for the heartbeat.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize)]
pub struct Inventory {
    /// The merged keys (`<repo>#<n>`) of each item that has any.
    pub merged: BTreeMap<String, Vec<String>>,
    /// The repositories whose refresh workflow stands red, with the cause.
    pub refresh_failing: BTreeMap<String, String>,
    /// The `<repo>:<workflow>` rows standing red on main, with the failing
    /// jobs.
    pub main_failing: BTreeMap<String, String>,
    /// The reducer pass's standing attention (`pr_watch_context`), `None`
    /// where every repository's reducer exited zero.
    pub pr_watch: Option<pr_watch::Context>,
    /// Each open Dependabot pull request an alert links, `<repo>#<pr>`, to
    /// its open alerts or `none` (the `bot-fix` rows the heartbeat marks
    /// its open list with).
    pub bot_fix: BTreeMap<String, String>,
}

/// What the reads of one pass produced.
pub struct Read {
    pub produced: Produced,
    pub inventory: Inventory,
}

/// What the reads run on.
pub struct Inputs<'a> {
    pub repos: &'a [String],
    pub settings: &'a Settings,
    pub lanes: &'a [Lane],
    /// The tracker's terminal state of each lane item it answered for on
    /// its last pass, which the parked-merged hand consults.
    pub terminal: &'a BTreeMap<String, TerminalState>,
    /// The merged search's floor as an epoch second and its ISO form.
    pub since: Option<u64>,
    pub since_iso: Option<&'a str>,
    pub now: u64,
}

// --- the transport ----------------------------------------------------------------

pub(super) fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// The refusal of a read `gh` gave no answer to.
pub(super) fn unrun(read: &'static str, unrun: &Unrun) -> Error {
    refused(
        "github-read-failed",
        &[("read", read), ("cause", &unrun.detail())],
    )
}

// --- the sign-in ------------------------------------------------------------------
//
// `watch run` selects its credential through the github skill's ladder before
// its claim and starts itself again in place under the selection, so a watch
// that cannot read GitHub never claims, and every program the watch starts
// outside the handle inherits a validated pair. The process lives for hours
// and across hand-overs, so a credential that expires later is renewed here,
// by running the ladder again: the renewal rides each handle's own pairs,
// since a process running threads cannot reset its own environment safely,
// and a second start in place would end the duties in flight, drop the
// runner's state and lose the read that met the refusal.

/// The github skill's credential ladder under the project's install.
const GH_AUTH_LADDER: &str = ".agents/skills/github/scripts/gh-auth-ladder";

/// How long the ladder's bounded probes may take together.
const GH_AUTH_LADDER_TIMEOUT: Duration = Duration::from_secs(120);

/// The two token variables as the ladder leaves them. An empty value is one
/// gh reads as unset (gh 2.103.3), so a pair masks an inherited token.
pub type Credential = Vec<(String, OsString)>;

/// `credential` as the runner's environment pairs.
pub(crate) fn credential_env(credential: &[(String, OsString)]) -> Vec<(&str, &OsStr)> {
    credential
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_os_str()))
        .collect()
}

/// Run the ladder over the project at `project`, its environment this
/// process's with `current` over it: the two variables it prints, or
/// `auth-failed service=github` with its last line where no candidate
/// works, the ladder's refusal naming each source it tried and why that
/// failed, after any warning the ladder printed first; a ladder that never
/// started or gave no answer is the runner's error.
#[allow(
    clippy::disallowed_methods,
    reason = "the watch's run of the github skill's credential ladder through the one runner, at its start and on a refused sign-in"
)]
pub fn select_sign_in(project: &Path, current: &[(String, OsString)]) -> Result<Credential> {
    let env = credential_env(current);
    let out = agent_runtime::host::run_tagged_in(
        "watch",
        "gh-auth-ladder",
        &project.join(GH_AUTH_LADDER),
        "select",
        &["--project", &project.display().to_string()],
        agent_runtime::host::Place {
            cwd: None,
            env: &env,
        },
        GH_AUTH_LADDER_TIMEOUT,
    )?;
    if !out.status.success() {
        let stderr = agent_runtime::host::stderr_text(&out);
        let line = stderr.lines().last().unwrap_or_default();
        return Err(refused(
            "auth-failed",
            &[("service", "github"), ("detail", line)],
        ));
    }
    Ok(agent_runtime::host::stdout_text(&out)
        .lines()
        .filter_map(|line| line.split_once('='))
        .filter(|(name, _)| matches!(*name, "GH_TOKEN" | "GITHUB_TOKEN"))
        .map(|(name, value)| (name.to_owned(), value.into()))
        .collect())
}

/// The watch's sign-in after its start: the project the ladder runs over
/// and where the renewals stand. Installed by `watch run` alone, so every
/// other command's reads keep their own environment's credential.
struct SignIn {
    project: PathBuf,
    standing: Mutex<Renewals>,
}

#[derive(Default)]
struct Renewals {
    /// The pair the last renewal selected; empty until one has run, the
    /// start's selection standing in this process's environment.
    pairs: Credential,
    /// How many renewals have selected.
    generation: u64,
    /// A renewal that selected nothing, its cause word and its words,
    /// standing until the GitHub duty's next pass, so a refused sign-in
    /// runs the ladder at most once per long cadence.
    failed: Option<(String, String)>,
}

static SIGN_IN: OnceLock<SignIn> = OnceLock::new();

/// The sign-in of this `watch run`, renewed over `project`.
pub fn install_sign_in(project: &Path) {
    let _ = SIGN_IN.set(SignIn {
        project: project.to_path_buf(),
        standing: Mutex::new(Renewals::default()),
    });
}

fn renewals_of(sign_in: &SignIn) -> std::sync::MutexGuard<'_, Renewals> {
    sign_in.standing.lock().unwrap_or_else(|p| p.into_inner())
}

/// The pair a child that reads GitHub takes over this process's
/// environment, and the renewal it was selected by.
fn sign_in_now() -> (Credential, u64) {
    match SIGN_IN.get() {
        None => (Credential::new(), 0),
        Some(sign_in) => {
            let standing = renewals_of(sign_in);
            (standing.pairs.clone(), standing.generation)
        }
    }
}

/// The renewed pair for a child the watch starts outside the handle.
pub(crate) fn renewed_credential() -> Credential {
    sign_in_now().0
}

/// The refusal of a sign-in that could not be renewed: `cause` one word,
/// `detail` what said so.
fn sign_in_failed(cause: &str, detail: &str) -> Error {
    refused(
        "github-auth-failed",
        &[("cause", cause), ("detail", detail)],
    )
}

/// What a read whose sign-in was refused does next.
enum Renewal {
    /// No `watch run` installed a sign-in: the refusal stands as the read's.
    Unowned,
    /// Read again under this pair.
    Selected(Credential),
}

/// Renew the sign-in a read under renewal `seen` met refused: a newer
/// renewal is taken as it stands, a failed one standing refuses at once,
/// else the ladder runs. The lock is held while it runs, so the reads of
/// other duties wait for its pair rather than run it again.
fn renew_sign_in(seen: u64) -> Result<Renewal> {
    let Some(sign_in) = SIGN_IN.get() else {
        return Ok(Renewal::Unowned);
    };
    let mut standing = renewals_of(sign_in);
    if let Some((cause, detail)) = &standing.failed {
        return Err(sign_in_failed(cause, detail));
    }
    if standing.generation == seen {
        match select_sign_in(&sign_in.project, &standing.pairs) {
            Ok(pairs) => {
                standing.pairs = pairs;
                standing.generation += 1;
                let _ = writeln!(
                    std::io::stderr(),
                    "github-sign-in-renewed generation={}",
                    standing.generation
                );
            }
            Err(e) => {
                let failed = (e.key().to_owned(), e.to_string());
                let refusal = sign_in_failed(&failed.0, &failed.1);
                standing.failed = Some(failed);
                return Err(refusal);
            }
        }
    }
    Ok(Renewal::Selected(standing.pairs.clone()))
}

/// A read under a renewed pair refused again: the refusal stands until the
/// GitHub duty's next pass, as a failed renewal does.
fn refused_again(failed: &Failed) -> Error {
    let cause = if failed.exit == Some(4) {
        "exit-4"
    } else {
        "http-401"
    };
    let detail = failed.detail();
    if let Some(sign_in) = SIGN_IN.get() {
        renewals_of(sign_in).failed = Some((cause.to_owned(), detail.clone()));
    }
    sign_in_failed(cause, &detail)
}

/// The GitHub duty's pass may run the ladder again.
fn retry_renewal() {
    if let Some(sign_in) = SIGN_IN.get() {
        renewals_of(sign_in).failed = None;
    }
}

/// The watch's `gh` handle: `cli` resolved as the caller named it
/// (production: on `PATH`), its starts counted under the GitHub tag, under
/// the renewed sign-in where one stands.
pub(crate) fn handle(cli: &Path) -> Gh<'static> {
    Gh::with_env(cli, renewed_credential()).tagged(TAG)
}

/// The watch's reads over the one handle: GitHub's 404 is the answer
/// `None`, every other failure the read's refusal under the duty's keys.
impl Gh<'_> {
    /// What one `gh api` read answered: the bytes of a call that exited
    /// zero, or `None` where the last status gh wrote is 404. A refused
    /// sign-in is renewed and the read asked once more; one that cannot be
    /// renewed refuses `github-auth-failed`.
    fn answer(&self, read: &'static str, path: &str) -> Result<Option<Vec<u8>>> {
        let (pairs, seen) = sign_in_now();
        let answer = match self.adding_env(pairs).run(read, &["api", path], None) {
            Ok(Answer::Failed(failed)) if failed.sign_in_refused() => match renew_sign_in(seen)? {
                Renewal::Unowned => Ok(Answer::Failed(failed)),
                Renewal::Selected(pairs) => {
                    match self.adding_env(pairs).run(read, &["api", path], None) {
                        Ok(Answer::Failed(again)) if again.sign_in_refused() => {
                            return Err(refused_again(&again));
                        }
                        other => other,
                    }
                }
            },
            other => other,
        };
        match answer {
            Err(e) => Err(unrun(read, &e)),
            Ok(Answer::Printed { stdout, .. }) => Ok(Some(stdout)),
            Ok(Answer::Failed(failed)) if failed.http() == Some(404) => Ok(None),
            Ok(Answer::Failed(failed)) => Err(refused(
                "github-read-failed",
                &[("read", read), ("path", path), ("cause", &failed.detail())],
            )),
        }
    }

    /// One object, decoded; a 404 is `None`.
    pub(crate) fn object<T: DeserializeOwned>(
        &self,
        read: &'static str,
        path: &str,
    ) -> Result<Option<T>> {
        match self.answer(read, path)? {
            None => Ok(None),
            Some(bytes) => serde_json::from_slice(&bytes).map(Some).map_err(|e| {
                refused(
                    "github-response-invalid",
                    &[("read", read), ("path", path), ("cause", &e.to_string())],
                )
            }),
        }
    }

    /// The raw text an endpoint printed (a job's log); a 404 is `None`.
    fn text(&self, read: &'static str, path: &str) -> Result<Option<String>> {
        Ok(self
            .answer(read, path)?
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned()))
    }

    /// Every member of a collection whose pages carry a total
    /// (`verify::collection`); a 404 on any page is `None`.
    fn collection<P: Page>(
        &self,
        read: &'static str,
        path: &str,
    ) -> Result<Option<Vec<P::Member>>> {
        let read_all = verify::collection(
            path,
            |page| match self.object::<P>(read, page) {
                Ok(Some(decoded)) => Ok(decoded),
                Ok(None) => Err(None),
                Err(e) => Err(Some(e)),
            },
            || {
                Some(refused(
                    "github-total-mismatch",
                    &[("read", read), ("path", path)],
                ))
            },
        );
        match read_all {
            Ok(members) => Ok(Some(members)),
            Err(None) => Ok(None),
            Err(Some(e)) => Err(e),
        }
    }

    /// Every member of a list endpoint with no total (`verify::list`),
    /// past whose last page it is refused; a 404 on any page is `None`.
    pub(crate) fn list<T: DeserializeOwned>(
        &self,
        read: &'static str,
        path: &str,
    ) -> Result<Option<Vec<T>>> {
        let read_all = verify::list(
            path,
            |page| match self.object::<Vec<T>>(read, page) {
                Ok(Some(decoded)) => Ok(decoded),
                Ok(None) => Err(None),
                Err(e) => Err(Some(e)),
            },
            || Some(refused("github-capped", &[("read", read), ("path", path)])),
        );
        match read_all {
            Ok(members) => Ok(Some(members)),
            Err(None) => Ok(None),
            Err(Some(e)) => Err(e),
        }
    }
}

// --- the wire shapes ------------------------------------------------------------------

/// `GET /search/issues`: the items' numbers; `pull_request` is present on
/// a pull request alone.
#[derive(Debug, serde::Deserialize)]
struct SearchPage {
    total_count: usize,
    incomplete_results: bool,
    items: Vec<SearchItem>,
}

#[derive(Debug, serde::Deserialize)]
struct SearchItem {
    number: u64,
    #[serde(default)]
    pull_request: Optional<Value>,
}

impl Page for SearchPage {
    type Member = SearchItem;
    fn total(&self) -> usize {
        self.total_count
    }
    fn members(self) -> Vec<SearchItem> {
        self.items
    }
}

/// `GET /repos/{owner}/{repo}/actions/runs/{id}/jobs`.
#[derive(Debug, serde::Deserialize)]
struct JobsPage {
    total_count: usize,
    jobs: Vec<Job>,
}

/// `GET /repos/{owner}/{repo}/check-runs/{id}/annotations` (no total).
#[derive(Debug, serde::Deserialize)]
struct Annotation {
    message: String,
    annotation_level: String,
}

/// The budget scan's row, `{watermark,seen,pending}` as raw compact JSON,
/// in the field order a released watch's row holds.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, serde::Deserialize)]
struct BudgetState {
    watermark: String,
    seen: Vec<u64>,
    pending: Vec<u64>,
}

impl Page for JobsPage {
    type Member = Job;
    fn total(&self) -> usize {
        self.total_count
    }
    fn members(self) -> Vec<Job> {
        self.jobs
    }
}

// --- the lane-own rule ------------------------------------------------------------------

/// Whether a pull request is the lane's own: its head owner is the
/// repository's, and its
/// number is the recorded one, its head branch the key, the key in the
/// conventional-commit scope that opens the title, or the first word
/// after `Closes` on a body line.
fn lane_own(pull: &Pull, item: &str, owner: &str, pr: Option<u64>) -> bool {
    let key = item.to_ascii_lowercase();
    let head_owner = match &pull.head.repo {
        Nullable::Present(repo) => repo.owner.login.to_ascii_lowercase(),
        Nullable::Absent | Nullable::Null => return false,
    };
    if head_owner != owner.to_ascii_lowercase() {
        return false;
    }
    if pr == Some(pull.number) || pull.head.branch.to_ascii_lowercase() == key {
        return true;
    }
    let title = pull.title.to_ascii_lowercase();
    if scope_names(&title, &key) {
        return true;
    }
    let body = match &pull.body {
        Nullable::Present(body) => body.to_ascii_lowercase(),
        Nullable::Absent | Nullable::Null => String::new(),
    };
    body.lines().any(|line| closes_names(line, &key))
}

/// `^[a-z]+\(([^)]*[ ,])?KEY([ ,][^)]*)?\)!?:` on a lowercased title.
pub(crate) fn scope_names(title: &str, key: &str) -> bool {
    let Some(open) = title.find('(') else {
        return false;
    };
    if open == 0 || !title[..open].bytes().all(|b| b.is_ascii_lowercase()) {
        return false;
    }
    let rest = &title[open + 1..];
    let Some(close) = rest.find(')') else {
        return false;
    };
    let scope = &rest[..close];
    let after = &rest[close + 1..];
    if !(after.starts_with(':') || after.starts_with("!:")) {
        return false;
    }
    scope.split([' ', ',']).any(|word| word == key)
}

/// `^\s*([-*+]\s+)?closes\s+KEY($|[^a-z0-9])` on a lowercased line.
fn closes_names(line: &str, key: &str) -> bool {
    let mut rest = line.trim_start();
    if let Some(stripped) = rest.strip_prefix(['-', '*', '+']) {
        let trimmed = stripped.trim_start();
        if trimmed.len() < stripped.len() {
            rest = trimmed;
        }
    }
    let Some(after) = rest.strip_prefix("closes") else {
        return false;
    };
    let trimmed = after.trim_start();
    if trimmed.len() == after.len() {
        return false;
    }
    let Some(tail) = trimmed.strip_prefix(key) else {
        return false;
    };
    !tail.starts_with(|c: char| c.is_ascii_alphanumeric())
}

/// The merge epoch of a lane's own merged pull request at or after
/// `since`.
fn merged_at(pull: &Pull, since: Option<u64>) -> Option<u64> {
    let stamp = match &pull.merged_at {
        Nullable::Present(stamp) => stamp,
        Nullable::Absent | Nullable::Null => return None,
    };
    let at = super::tracker::stamp_epoch(stamp)?;
    since.is_none_or(|floor| at >= floor).then_some(at)
}

// --- the reads ------------------------------------------------------------------------------

/// A lane's part in the merged index: its own recorded pull request where
/// one stands, and the dependency it is parked until.
struct MergeItem {
    item: String,
    /// `<repo>#<n>` of the item's own parked pull request.
    parked_key: Option<String>,
    /// The dependency's `(repo, number)` the record is parked until.
    until: Option<(String, u64)>,
    /// A record carrying a dependency: its own `(repo, number)`, read by
    /// number rather than searched.
    own: Option<(String, Option<u64>)>,
}

fn merge_items(lanes: &[Lane]) -> Vec<MergeItem> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for lane in lanes.iter().filter(|l| l.status != LaneStatus::Done) {
        if !seen.insert(lane.item.clone()) {
            continue;
        }
        let parked = lane
            .extra
            .get("parked")
            .filter(|_| lane.status == LaneStatus::Parked);
        let record = parked.or_else(|| lane.extra.get("pending_pr"));
        let repo_of = |v: &Value| {
            v.get("repo")
                .and_then(Value::as_str)
                .map(str::to_ascii_lowercase)
        };
        let parked_key =
            parked.and_then(|p| Some(format!("{}#{}", repo_of(p)?, p.get("pr")?.as_u64()?)));
        let until = record.and_then(|p| {
            let until_pr = p.get("until_pr")?.as_u64()?;
            let repo = p
                .get("until_repo")
                .and_then(Value::as_str)
                .map(str::to_ascii_lowercase)
                .or_else(|| repo_of(p))?;
            Some((repo, until_pr))
        });
        let own = until.as_ref().and_then(|_| {
            let record = record?;
            Some((repo_of(record)?, record.get("pr").and_then(Value::as_u64)))
        });
        out.push(MergeItem {
            item: lane.item.clone(),
            parked_key,
            until,
            own,
        });
    }
    out
}

/// The repositories the lane inventories read: the caller's, the lanes'
/// and the connected ones, lowercased, in that order, once each.
fn repositories(inputs: &Inputs) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let named = inputs
        .repos
        .iter()
        .map(String::as_str)
        .chain(inputs.lanes.iter().filter_map(|l| l.repo.as_deref()))
        .chain(
            inputs
                .settings
                .reads
                .connected_repos
                .iter()
                .map(String::as_str),
        );
    for repo in named {
        let repo = repo.to_ascii_lowercase();
        if repo.contains('/') && !out.contains(&repo) {
            out.push(repo);
        }
    }
    out
}

/// The repositories the audits read: the `--repo` names, then the
/// connected ones,
/// lowercased, once each; the first `--repo` is the first repository,
/// whose issues the outside check reads and whose reducer line the pass
/// opens with.
pub(super) fn audit_repositories(repos: &[String], settings: &Settings) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for repo in repos.iter().chain(settings.reads.connected_repos.iter()) {
        let repo = repo.to_ascii_lowercase();
        if !out.contains(&repo) {
            out.push(repo);
        }
    }
    out
}

/// The reducer's repositories: the first
/// `--repo` and every connected repository, once each.
pub(super) fn reducer_repositories(repos: &[String], settings: &Settings) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for repo in repos
        .iter()
        .take(1)
        .chain(settings.reads.connected_repos.iter())
    {
        let repo = repo.to_ascii_lowercase();
        if !out.contains(&repo) {
            out.push(repo);
        }
    }
    out
}

// --- the duty ----------------------------------------------------------------------------

/// What the duty runs with, fixed at registration.
pub struct Context {
    /// The fleet state file.
    pub fleet: PathBuf,
    pub settings: Settings,
    /// The merged search's floor (`--since`) as an epoch second and its
    /// ISO form.
    pub since: Option<u64>,
    pub since_iso: Option<String>,
    /// The `--repo` names.
    pub repos: Vec<String>,
    /// The `gh` program; `gh` on `PATH` in production.
    pub gh: PathBuf,
    /// The reducer the pass runs per repository (`OVERSEE_WATCH_PR_WATCH`).
    pub pr_watch: PathBuf,
    /// The slot shared with the tracker duty: the tracker's verdicts are
    /// read from it, this duty's inventory written to it.
    pub shared: Shared,
}

/// The duty's body: the pass count is this run's, so a repository's
/// standing attention on the first
/// pass of a run with no row is its baseline, never an event.
pub fn body<'a>(ctx: Context) -> Body<'a> {
    let mut passes: u32 = 0;
    Box::new(move |tick: &Tick| {
        passes += 1;
        run(&ctx, passes, tick)
    })
}

/// Register the duty on `runner` for the fleet at `path`:
/// `--since` is one UTC stamp (`since-invalid`), `repos` the
/// `--repo` names, `shared` the tracker duty's slot.
pub fn register(
    runner: &mut crate::watch::Runner<'_>,
    path: &Path,
    settings: &Settings,
    since: Option<String>,
    repos: Vec<String>,
    shared: Shared,
) -> Result<()> {
    let since_epoch = match since.as_deref() {
        None => None,
        Some(stamp) => Some(
            clock::epoch_secs(stamp)
                .ok_or_else(|| refused("since-invalid", &[("value", stamp)]))?,
        ),
    };
    runner.register(
        crate::schedule::Duty::GitHub,
        body(Context {
            fleet: path.to_path_buf(),
            settings: settings.clone(),
            since: since_epoch,
            since_iso: since,
            repos,
            gh: PathBuf::from("gh"),
            pr_watch: settings.reads.pr_watch_cli.clone(),
            shared,
        }),
    );
    Ok(())
}

/// The fleet record and its `alerts_triaged` verdicts, read once per pass.
#[allow(
    clippy::disallowed_methods,
    reason = "the GitHub duty's one read of the fleet record per pass: the lanes its inventories are about and the alert verdicts, which it judges and never writes"
)]
fn load_fleet(path: &Path) -> Result<(FleetState, Vec<Value>)> {
    let snapshot = state::load(path)?.ok_or_else(|| {
        Error::Runtime(agent_runtime::Error::RecordMissing {
            path: path.to_path_buf(),
        })
    })?;
    let fleet = snapshot.view::<FleetState>(path)?;
    let verdicts = match snapshot.doc.get("alerts_triaged") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(rows)) => rows.clone(),
        Some(other) => vec![other.clone()],
    };
    Ok((fleet, verdicts))
}

/// The pass: the reads, under a sign-in this pass may renew once. A sign-in
/// that could not be renewed is the owner's turn ([`sign_in_turn`]) and the
/// pass's failure; a pass whose reads answered clears the turn.
fn run(ctx: &Context, passes: u32, tick: &Tick) -> Result<Produced> {
    retry_renewal();
    match pass_reads(ctx, passes, tick) {
        Ok(mut produced) => {
            if tick.baseline.get(SIGN_IN_ROW, SIGN_IN_KEY).is_some() {
                produced.changes.push(Change::Clear {
                    kind: SIGN_IN_ROW.to_owned(),
                    identity: SIGN_IN_KEY.to_owned(),
                });
            }
            Ok(produced)
        }
        Err(e) => match sign_in_cause(&e) {
            Some(cause) => Ok(sign_in_turn(ctx, tick.baseline, &cause, &e.to_string())),
            None => Err(e),
        },
    }
}

/// The cause word of a `github-auth-failed` refusal.
fn sign_in_cause(e: &Error) -> Option<String> {
    let Error::Runtime(agent_runtime::Error::Refused {
        key: "github-auth-failed",
        fields,
    }) = e
    else {
        return None;
    };
    fields
        .iter()
        .find(|(name, _)| name == "cause")
        .map(|(_, value)| value.clone())
}

/// The owner's turn for a sign-in that cannot be renewed, as the owner
/// alert runs it: the line and the told row on the pass that reads it, the
/// owner's notice on the next, nothing while it stands. The cause stays
/// the pass's failure under the runner's one rule.
fn sign_in_turn(ctx: &Context, baseline: &Baseline, cause: &str, words: &str) -> Produced {
    let mut produced = Produced {
        failed: Some(words.to_owned()),
        ..Produced::default()
    };
    let prior = baseline.get(SIGN_IN_ROW, SIGN_IN_KEY).unwrap_or("");
    match Word::of_row(prior, SIGN_IN_STATE) {
        Some(Word::Alerted) => {}
        Some(Word::Told) => {
            match owner_alert::send(&ctx.settings, SIGN_IN_ALERT_FILE, &sign_in_text(words)) {
                Ok(()) => produced.changes.push(Change::Set {
                    kind: SIGN_IN_ROW.to_owned(),
                    identity: SIGN_IN_KEY.to_owned(),
                    value: Word::Alerted.row(SIGN_IN_STATE),
                }),
                Err(cause) => {
                    let _ = writeln!(
                        std::io::stderr(),
                        "github-auth-notice-failed channel=owner cause={cause}"
                    );
                }
            }
        }
        None => {
            produced.events.push(Event::GitHubAuthFailed {
                cause: cause.to_owned(),
            });
            produced.changes.push(Change::Set {
                kind: SIGN_IN_ROW.to_owned(),
                identity: SIGN_IN_KEY.to_owned(),
                value: Word::Told.row(SIGN_IN_STATE),
            });
        }
    }
    produced
}

fn sign_in_text(words: &str) -> String {
    format!(
        "github-auth-failed: the orch watch cannot sign in to GitHub and the github skill's credential ladder selected no working credential, so every GitHub read of the fleet fails until one works: {words}. Sign gh in again, or renew the token the ladder reads (the caller's GH_TOKEN, the keyring, the project's GH_BOT_TOKEN); the watch runs the ladder again on its next GitHub pass.\n"
    )
}

fn pass_reads(ctx: &Context, passes: u32, tick: &Tick) -> Result<Produced> {
    let (fleet, verdicts) = load_fleet(&ctx.fleet)?;
    let terminal = ctx
        .shared
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .terminal
        .clone();
    let gh = handle(&ctx.gh);
    let inputs = Inputs {
        repos: &ctx.repos,
        settings: &ctx.settings,
        lanes: &fleet.lanes,
        terminal: &terminal,
        since: ctx.since,
        since_iso: ctx.since_iso.as_deref(),
        now: tick.wall,
    };
    let read = read(&gh, &inputs, tick.baseline)?;
    let mut produced = read.produced;
    let mut inventory = read.inventory;
    let audits = audit_repositories(&ctx.repos, &ctx.settings);
    inventory.pr_watch = pr_watch::pass(
        &gh,
        &ctx.pr_watch,
        &reducer_repositories(&ctx.repos, &ctx.settings),
        passes == 1,
        tick.baseline,
        &mut produced,
    )?;
    outside::pass(&gh, &ctx.settings, &audits, tick.baseline, &mut produced)?;
    inventory.bot_fix = security::pass(
        &gh,
        &ctx.settings,
        &audits,
        &verdicts,
        tick.baseline,
        &mut produced,
    )?;
    ctx.shared.lock().unwrap_or_else(|p| p.into_inner()).github = Some(inventory);
    Ok(produced)
}

/// The lane inventories: the merged index, the refresh incident, the
/// main-branch incident and its budget scan.
pub(crate) fn read(gh: &Gh, inputs: &Inputs, baseline: &Baseline) -> Result<Read> {
    let mut produced = Produced::default();
    let mut inventory = Inventory::default();
    let repos = repositories(inputs);
    merged(gh, inputs, &repos, baseline, &mut produced, &mut inventory)?;
    refresh(gh, inputs, &repos, baseline, &mut produced, &mut inventory)?;
    let budget_absent = main_push(gh, inputs, &repos, baseline, &mut produced, &mut inventory)?;
    budget(gh, &repos, &budget_absent, baseline, &mut produced)?;
    Ok(Read {
        produced,
        inventory,
    })
}

/// The end of every GitHub-tracked parked or stopped lane item, one read
/// per item: a closed issue whose reason is
/// `completed` ended completed, closed otherwise canceled, open is open.
/// The tracker duty's read: the item's tracker is GitHub. Each item's read
/// stands or falls alone: a refused read is that item's `Err`, the
/// other items' verdicts are read.
pub(super) fn terminal_github(gh: &Gh, lanes: &[Lane]) -> BTreeMap<String, Result<TerminalState>> {
    let mut out = BTreeMap::new();
    for lane in lanes
        .iter()
        .filter(|l| matches!(l.status, LaneStatus::Parked | LaneStatus::Stopped))
        .filter(|l| l.tracker.as_deref() == Some("github"))
    {
        out.entry(lane.item.clone())
            .or_insert_with(|| terminal_of(gh, lane));
    }
    out
}

pub(super) fn terminal_of(gh: &Gh, lane: &Lane) -> Result<TerminalState> {
    let (Some(number), Some(repo)) = (lane.item.strip_prefix("issue-"), lane.repo.as_deref())
    else {
        return Err(refused("tracker-item-unread", &[("item", &lane.item)]));
    };
    let path = format!("repos/{}/issues/{number}", repo.to_ascii_lowercase());
    let Some(issue) = gh.object::<Issue>("terminal", &path)? else {
        return Err(refused("tracker-item-unread", &[("item", &lane.item)]));
    };
    match issue.state.as_str() {
        "open" => Ok(TerminalState::Open),
        "closed" => Ok(match &issue.state_reason {
            Nullable::Present(reason) if reason == "completed" => TerminalState::Completed,
            Nullable::Present(_) | Nullable::Absent | Nullable::Null => TerminalState::Canceled,
        }),
        other => Err(refused(
            "github-response-invalid",
            &[("read", "terminal"), ("field", "state"), ("value", other)],
        )),
    }
}

/// One lane item's own merged pull requests at or after the floor, per
/// repository, as `(number, repository)`: its recorded pull request by
/// number where its record carries a dependency, else its head branch and
/// its mentions.
fn own_merges(
    gh: &Gh,
    entry: &MergeItem,
    repos: &[String],
    inputs: &Inputs,
) -> Result<Vec<(u64, String)>> {
    let mut hits: Vec<(u64, String)> = Vec::new();
    for repo in repos {
        let owner = repo.split('/').next().unwrap_or(repo);
        let recorded_pr = entry
            .parked_key
            .as_deref()
            .and_then(|k| k.strip_prefix(&format!("{repo}#")))
            .and_then(|n| n.parse::<u64>().ok());
        let pulls: Vec<Pull> = if let Some((own_repo, own_pr)) = &entry.own {
            if own_repo != repo {
                continue;
            }
            let Some(pr) = own_pr else { continue };
            let path = format!("repos/{repo}/pulls/{pr}");
            match gh.object::<Pull>("merged", &path)? {
                Some(pull) => vec![pull],
                None => {
                    return Err(refused(
                        "github-read-failed",
                        &[("read", "merged"), ("path", &path)],
                    ));
                }
            }
        } else {
            own_pulls(gh, repo, &entry.item, inputs.since_iso)?
        };
        for pull in pulls {
            if !lane_own(&pull, &entry.item, owner, recorded_pr) {
                continue;
            }
            if merged_at(&pull, inputs.since).is_none() {
                continue;
            }
            if !hits.iter().any(|(n, r)| *n == pull.number && r == repo) {
                hits.push((pull.number, repo.clone()));
            }
        }
    }
    Ok(hits)
}

/// One lane's merged keys (`<repo>#<n>`) as the merged index reads them
/// ([`own_merges`]) over the repositories this duty reads (`repos` the
/// watch's `--repo` names), for the tracker's terminal close, which reads
/// the lane's current merges before it closes the lane whatever `merged`
/// row a pass of this duty last wrote.
pub(super) fn merged_keys(
    gh: &Gh,
    lane: &Lane,
    repos: &[String],
    settings: &Settings,
    since: Option<u64>,
    since_iso: Option<&str>,
    now: u64,
) -> Result<Vec<String>> {
    let terminal = BTreeMap::new();
    let inputs = Inputs {
        repos,
        settings,
        lanes: std::slice::from_ref(lane),
        terminal: &terminal,
        since,
        since_iso,
        now,
    };
    let repos = repositories(&inputs);
    let mut keys = Vec::new();
    for entry in merge_items(inputs.lanes) {
        for (number, repo) in own_merges(gh, &entry, &repos, &inputs)? {
            keys.push(format!("{repo}#{number}"));
        }
    }
    Ok(keys)
}

/// The merged index: for every
/// lane item and repository, the item's own merged pull requests at or
/// after the floor, by head branch and by mention; a key not in the
/// item's row is a `merged` line, the row then holds every key; a parked
/// item's dependency is read by number and its state change is the
/// parked-merged or parked-closed line, the hand deferred while the
/// tracker's verdict is unknown.
fn merged(
    gh: &Gh,
    inputs: &Inputs,
    repos: &[String],
    baseline: &Baseline,
    produced: &mut Produced,
    inventory: &mut Inventory,
) -> Result<()> {
    let items = merge_items(inputs.lanes);
    let verdict_of = |item: &str| -> Option<TerminalState> { inputs.terminal.get(item).copied() };
    let parked_merged = |item: &str, key: &str, produced: &mut Produced| -> bool {
        // The parked line: deferred with no verdict, nothing on an
        // ended item, the line on an open one. Returns whether the row
        // may advance.
        match verdict_of(item) {
            None => false,
            Some(TerminalState::Completed | TerminalState::Canceled) => true,
            Some(TerminalState::Open) => {
                let (repo, pr) = key.rsplit_once('#').unwrap_or((key, ""));
                produced.events.push(Event::ParkedMerged {
                    item: item.to_owned(),
                    pr: pr.to_owned(),
                    repo: repo.to_owned(),
                });
                true
            }
        }
    };
    let mut parked_items = BTreeSet::new();
    for entry in &items {
        let mut deferred = false;
        if let Some((repo, until)) = &entry.until {
            parked_items.insert(entry.item.clone());
            let path = format!("repos/{repo}/pulls/{until}");
            let Some(pull) = gh.object::<Pull>("parked-until", &path)? else {
                return Err(refused(
                    "github-read-failed",
                    &[("read", "parked-until"), ("path", &path)],
                ));
            };
            let state = match (pull.state.as_str(), &pull.merged_at) {
                ("open", _) => "OPEN",
                ("closed", Nullable::Present(_)) => "MERGED",
                ("closed", Nullable::Absent | Nullable::Null) => "CLOSED",
                (other, _) => {
                    return Err(refused(
                        "github-response-invalid",
                        &[
                            ("read", "parked-until"),
                            ("field", "state"),
                            ("value", other),
                        ],
                    ));
                }
            };
            let parked_key = entry.parked_key.clone().unwrap_or_default();
            let key = format!("{parked_key} {state}");
            if baseline.get(PARKED_UNTIL_ROW, &entry.item) != Some(key.as_str()) {
                match state {
                    "MERGED" => deferred = !parked_merged(&entry.item, &parked_key, produced),
                    "CLOSED" => produced.events.push(Event::ParkedClosed {
                        item: entry.item.clone(),
                        pr: until.to_string(),
                        repo: repo.clone(),
                    }),
                    _ => {}
                }
            }
            if !deferred {
                produced.changes.push(Change::Set {
                    kind: PARKED_UNTIL_ROW.to_owned(),
                    identity: entry.item.clone(),
                    value: key,
                });
            }
        }
        let hits = own_merges(gh, entry, repos, inputs)?;
        if hits.is_empty() {
            produced.changes.push(Change::Clear {
                kind: MERGED_ROW.to_owned(),
                identity: entry.item.clone(),
            });
            continue;
        }
        let prior: Vec<&str> = baseline
            .get(MERGED_ROW, &entry.item)
            .map(|v| v.split(' ').collect())
            .unwrap_or_default();
        let mut keys = Vec::new();
        let mut fresh = Vec::new();
        for (number, repo) in &hits {
            let key = format!("{repo}#{number}");
            if !prior.contains(&key.as_str()) {
                produced.events.push(Event::Merged {
                    line: format!("{number} {} {repo}", entry.item.to_ascii_lowercase()),
                });
                fresh.push(key.clone());
            }
            keys.push(key);
        }
        inventory.merged.insert(entry.item.clone(), keys.clone());
        produced.changes.push(Change::Set {
            kind: MERGED_ROW.to_owned(),
            identity: entry.item.clone(),
            value: keys.join(" "),
        });
        if entry.own.is_some() {
            continue;
        }
        // A parked item's fresh own merge hands it on; a fresh merge that
        // is not its recorded key is not its own delivery.
        if let Some(parked_key) = &entry.parked_key
            && fresh.iter().any(|k| k == parked_key)
        {
            parked_merged(&entry.item, parked_key, produced);
        }
    }
    // The rows pruned to the items carried and the refresh row.
    let carried: BTreeSet<&str> = items.iter().map(|e| e.item.as_str()).collect();
    for identity in baseline.identities(MERGED_ROW) {
        if !carried.contains(identity.as_str()) && identity != REFRESH_ITEM {
            produced.changes.push(Change::Clear {
                kind: MERGED_ROW.to_owned(),
                identity,
            });
        }
    }
    for identity in baseline.identities(PARKED_UNTIL_ROW) {
        if !parked_items.contains(&identity) {
            produced.changes.push(Change::Clear {
                kind: PARKED_UNTIL_ROW.to_owned(),
                identity,
            });
        }
    }
    Ok(())
}

/// The search endpoint read whole: the first page judged against the
/// documented cap and `incomplete_results`, every page's total equal and
/// the items adding up to it, else refused.
fn search(gh: &Gh, path: &str, repo: &str, item: &str) -> Result<Vec<SearchItem>> {
    verify::collection(
        path,
        |page| {
            let Some(reply) = gh.object::<SearchPage>("merged-search", page)? else {
                return Err(refused(
                    "github-read-failed",
                    &[("read", "merged-search"), ("path", path)],
                ));
            };
            if reply.incomplete_results || reply.total_count >= SEARCH_CAP {
                return Err(refused(
                    "github-capped",
                    &[("read", "merged-search"), ("repo", repo), ("item", item)],
                ));
            }
            Ok(reply)
        },
        || {
            refused(
                "github-total-mismatch",
                &[("read", "merged-search"), ("path", path)],
            )
        },
    )
}

/// The closed pull requests of `repo` that may be `item`'s own: those on
/// the item's branch, read to the last page, and those mentioning the key
/// in title or body since the floor, through the search endpoint with its
/// total checked and each hit not already in hand read by number.
fn own_pulls(gh: &Gh, repo: &str, item: &str, since_iso: Option<&str>) -> Result<Vec<Pull>> {
    let owner = repo.split('/').next().unwrap_or(repo);
    let branch = item.to_ascii_lowercase();
    let head_path = format!(
        "repos/{repo}/pulls?state=closed&head={}",
        verify::segment(&format!("{owner}:{branch}"))
    );
    let Some(mut pulls) = gh.list::<Pull>("merged", &head_path)? else {
        return Err(refused(
            "github-read-failed",
            &[("read", "merged"), ("path", &head_path)],
        ));
    };
    let floor = since_iso
        .map(|s| format!(" merged:>={s}"))
        .unwrap_or_default();
    let query = format!("repo:{repo} is:pr is:merged \"{item}\" in:title,body{floor}");
    let search_path = format!("search/issues?q={}", verify::segment(&query));
    let hits = search(gh, &search_path, repo, item)?;
    for hit in hits {
        if hit.pull_request.present().is_none() || pulls.iter().any(|p| p.number == hit.number) {
            continue;
        }
        let path = format!("repos/{repo}/pulls/{}", hit.number);
        let Some(pull) = gh.object::<Pull>("merged", &path)? else {
            return Err(refused(
                "github-read-failed",
                &[("read", "merged"), ("path", &path)],
            ));
        };
        pulls.push(pull);
    }
    Ok(pulls)
}

/// A lane item's own pull request merged inside a report's window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Completion {
    pub item: String,
    pub repo: String,
    pub number: u64,
    pub at: u64,
    pub title: String,
}

/// The lane items' own pull requests merged at or after `since` and before
/// `until`, oldest first: one search per repository for its merges since
/// the floor, bounded by the search endpoint's cap, each hit read by number
/// and judged by the lane-own rule for every item, its parked pull request
/// counted where the park names this repository.
pub(super) fn report_merges(
    gh: &Gh,
    repos: &[String],
    lanes: &[Lane],
    since: u64,
    until: u64,
) -> Result<Vec<Completion>> {
    let floor = agent_runtime::clock::iso_utc(since);
    let mut rows = Vec::new();
    for repo in repos {
        let owner = repo.split('/').next().unwrap_or(repo);
        let query = format!("repo:{repo} is:pr is:merged merged:>={floor}");
        let search_path = format!("search/issues?q={}", verify::segment(&query));
        for hit in search(gh, &search_path, repo, "report")? {
            if hit.pull_request.present().is_none() {
                continue;
            }
            let path = format!("repos/{repo}/pulls/{}", hit.number);
            let Some(pull) = gh.object::<Pull>("report-merges", &path)? else {
                return Err(refused(
                    "github-read-failed",
                    &[("read", "report-merges"), ("path", &path)],
                ));
            };
            let Some(at) = merged_at(&pull, Some(since)).filter(|at| *at < until) else {
                continue;
            };
            for lane in lanes {
                let parked = lane
                    .extra
                    .get("parked")
                    .filter(|p| {
                        p.get("repo")
                            .and_then(Value::as_str)
                            .is_some_and(|r| r.eq_ignore_ascii_case(repo))
                    })
                    .and_then(|p| p.get("pr"))
                    .and_then(Value::as_u64);
                let row = Completion {
                    item: lane.item.clone(),
                    repo: repo.clone(),
                    number: pull.number,
                    at,
                    title: pull.title.clone(),
                };
                if lane_own(&pull, &lane.item, owner, parked) && !rows.contains(&row) {
                    rows.push(row);
                }
            }
        }
    }
    rows.sort_by_key(|row| row.at);
    Ok(rows)
}

/// Whether `workflow` is absent from `repo`, proved by a complete,
/// successful workflow list alone.
fn workflow_absent(gh: &Gh, repo: &str, workflow: &str) -> Result<bool> {
    let path = format!("repos/{repo}/actions/workflows");
    let Some(workflows) = gh.collection::<WorkflowsPage>("workflows", &path)? else {
        return Err(refused(
            "github-read-failed",
            &[("read", "workflows"), ("path", &path)],
        ));
    };
    let wanted = format!(".github/workflows/{workflow}");
    Ok(!workflows.iter().any(|w| w.path == wanted))
}

/// A run's identity in the refresh row, `[created_at, id, attempt]`,
/// in the order a released watch's row holds.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct RunKey {
    created_at: String,
    id: u64,
    attempt: u64,
}

impl RunKey {
    fn of(run: &WorkflowRun) -> Result<RunKey> {
        let valid = run.created_at.len() == 20
            && agent_runtime::clock::epoch_secs(&run.created_at).is_some();
        if !valid {
            return Err(refused(
                "github-response-invalid",
                &[
                    ("read", "refresh"),
                    ("field", "created_at"),
                    ("value", &run.created_at),
                ],
            ));
        }
        Ok(RunKey {
            created_at: run.created_at.clone(),
            id: run.id,
            attempt: run.run_attempt.present().copied().unwrap_or(1),
        })
    }

    fn render(&self) -> String {
        format!("[\"{}\",{},{}]", self.created_at, self.id, self.attempt)
    }

    fn parse(text: &str) -> Option<RunKey> {
        let inner = text.strip_prefix("[\"")?.strip_suffix(']')?;
        let (created_at, rest) = inner.split_once("\",")?;
        let (id, attempt) = rest.split_once(',')?;
        Some(RunKey {
            created_at: created_at.to_owned(),
            id: id.parse().ok()?,
            attempt: attempt.parse().ok()?,
        })
    }
}

/// The refresh row's standing: the recorded run and what was judged of it.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Standing {
    /// Judged with no incident, or no judgement needed yet.
    Clear,
    /// Judged red: the passes since the report and the cause.
    Failing { passes: u32, cause: String },
    /// The record was moved by a stale read and is not yet judged.
    Unjudged,
}

fn refresh_row(value: &str) -> Result<(Option<RunKey>, Standing)> {
    // `<run json>|<standing>`, or a released watch's unrecorded `<passes>|<cause>`.
    if let Some((record, standing)) = value.split_once("]|") {
        let key = RunKey::parse(&format!("{record}]")).ok_or_else(|| {
            refused(
                "github-row-invalid",
                &[("row", REFRESH_ROW), ("value", value)],
            )
        })?;
        let standing = match standing {
            "" => Standing::Clear,
            "unjudged" => Standing::Unjudged,
            rest => parse_failing(rest).ok_or_else(|| {
                refused(
                    "github-row-invalid",
                    &[("row", REFRESH_ROW), ("value", value)],
                )
            })?,
        };
        return Ok((Some(key), standing));
    }
    match parse_failing(value) {
        Some(standing) => Ok((None, standing)),
        None => Err(refused(
            "github-row-invalid",
            &[("row", REFRESH_ROW), ("value", value)],
        )),
    }
}

fn parse_failing(text: &str) -> Option<Standing> {
    let (passes, cause) = text.split_once('|')?;
    Some(Standing::Failing {
        passes: passes.parse().ok()?,
        cause: cause.to_owned(),
    })
}

/// The cause line of a failed run's job logs: the last line of the highest
/// rank among `failed:`, `FAIL check=`, `Error:`, `refresh-error=` and a
/// `kendex-hook-` mention; `unread` with none.
fn refresh_cause(logs: &[String]) -> String {
    let mut best = 0;
    let mut cause = String::new();
    for line in logs.iter().flat_map(|log| log.lines()) {
        let text = strip_log_prefix(line);
        let (rank, found) = if text.starts_with("failed: ") {
            (5, text.to_owned())
        } else if text.starts_with("FAIL check=") {
            (4, text.to_owned())
        } else if text.starts_with("Error: ") {
            (3, text.to_owned())
        } else if text.starts_with("refresh-error=") {
            (2, text.to_owned())
        } else if let Some(at) = text.find("kendex-hook-") {
            (1, text[at..].to_owned())
        } else {
            continue;
        };
        if rank >= best {
            best = rank;
            cause = found.replace('\t', " ");
        }
    }
    if cause.is_empty() {
        "unread".to_owned()
    } else {
        cause
    }
}

/// A job log line without its leading timestamp, as `gh api` prints the
/// log (`<stamp> <text>`), and without a trailing carriage return.
fn strip_log_prefix(line: &str) -> &str {
    let text = line.split_once(' ').map_or(line, |(_, rest)| rest);
    text.strip_suffix('\r').unwrap_or(text)
}

/// The logs of a run's failed jobs, one text per job.
fn failed_job_logs(
    gh: &Gh,
    repo: &str,
    run: u64,
    failing: &[&str],
) -> Result<(Vec<String>, Vec<String>)> {
    let path = format!("repos/{repo}/actions/runs/{run}/jobs");
    let Some(jobs) = gh.collection::<JobsPage>("jobs", &path)? else {
        return Err(refused(
            "github-read-failed",
            &[("read", "jobs"), ("path", &path)],
        ));
    };
    let mut names = BTreeSet::new();
    let mut logs = Vec::new();
    for job in jobs {
        let conclusion = match &job.conclusion {
            Nullable::Present(c) => c.word(),
            Nullable::Absent | Nullable::Null => continue,
        };
        if !failing.contains(&conclusion) {
            continue;
        }
        names.insert(job.name.clone());
        let log_path = format!("repos/{repo}/actions/jobs/{}/logs", job.id);
        if let Some(text) = gh.text("job-log", &log_path)? {
            logs.push(text);
        }
    }
    Ok((names.into_iter().collect(), logs))
}

/// The refresh incident: the two
/// newest completed runs of the refresh workflow; both failed opens or
/// repeats an incident whose cause is read from the failed jobs' logs,
/// repeated every `mark_repeat` passes while it stands; a newest run that
/// is older than the recorded one is stale and judges nothing; a pair
/// that would open an incident is confirmed against the unfiltered
/// recent list first; an absent workflow clears silently.
fn refresh(
    gh: &Gh,
    inputs: &Inputs,
    repos: &[String],
    baseline: &Baseline,
    produced: &mut Produced,
    inventory: &mut Inventory,
) -> Result<()> {
    let mark_repeat = inputs.settings.watch.get()?.mark_repeat;
    for repo in repos {
        let path = format!(
            "repos/{repo}/actions/workflows/{REFRESH_WORKFLOW}/runs?status=completed&per_page=2"
        );
        let page: Option<RunsPage> = gh.object("refresh", &path)?;
        let Some(page) = page else {
            if workflow_absent(gh, repo, REFRESH_WORKFLOW)? {
                produced.changes.push(Change::Clear {
                    kind: REFRESH_ROW.to_owned(),
                    identity: repo.clone(),
                });
                continue;
            }
            return Err(refused(
                "github-read-failed",
                &[("read", "refresh"), ("path", &path)],
            ));
        };
        let runs: Vec<&WorkflowRun> = page.workflow_runs.iter().take(2).collect();
        for run in &runs {
            if conclusion(run).is_none() {
                return Err(refused(
                    "github-response-invalid",
                    &[
                        ("read", "refresh"),
                        ("field", "conclusion"),
                        ("value", &run.id.to_string()),
                    ],
                ));
            }
        }
        let (recorded, mut standing) = match baseline.get(REFRESH_ROW, repo) {
            Some(value) => refresh_row(value)?,
            None => (None, Standing::Clear),
        };
        let newest = runs.first().map(|r| RunKey::of(r)).transpose()?;
        // `order`: the page's newest run against the record.
        let order = match (&recorded, &newest) {
            (None, _) => "unrecorded",
            (Some(_), None) => "older",
            (Some(rec), Some(new)) if new > rec => "newer",
            (Some(rec), Some(new)) if new == rec => "same",
            (Some(_), Some(_)) => "older",
        };
        let since = if runs.len() == 2 && runs.iter().all(|r| conclusion(r) == Some("failure")) {
            Some(runs[1].created_at.clone())
        } else {
            None
        };
        let order = if standing == Standing::Unjudged {
            standing = Standing::Clear;
            if order == "same" { "unjudged" } else { order }
        } else {
            order
        };
        let run = match (order, &newest) {
            ("older", _) => continue,
            ("unrecorded", None) => {
                produced.changes.push(Change::Clear {
                    kind: REFRESH_ROW.to_owned(),
                    identity: repo.clone(),
                });
                continue;
            }
            (_, Some(run)) => run.clone(),
            (_, None) => continue,
        };
        let Some(since) = since else {
            produced.changes.push(Change::Set {
                kind: REFRESH_ROW.to_owned(),
                identity: repo.clone(),
                value: format!("{}|", run.render()),
            });
            continue;
        };
        if order == "same" && standing == Standing::Clear {
            continue;
        }
        if order == "unrecorded" || standing == Standing::Clear {
            // Confirmation from the unfiltered recent list: a completed run
            // newer than the pair's newest makes this read stale.
            let recent_path =
                format!("repos/{repo}/actions/workflows/{REFRESH_WORKFLOW}/runs?per_page=20");
            let Some(recent) = gh.object::<RunsPage>("refresh-all", &recent_path)? else {
                return Err(refused(
                    "github-read-failed",
                    &[("read", "refresh-all"), ("path", &recent_path)],
                ));
            };
            let completed = recent
                .workflow_runs
                .iter()
                .find(|r| r.status == Nullable::Present(RunStatus::Completed));
            let stale = match completed {
                None => Some(run.clone()),
                Some(found) => {
                    let key = RunKey::of(found)?;
                    if key == run {
                        None
                    } else {
                        Some(key.max(run.clone()))
                    }
                }
            };
            if let Some(newest_known) = stale {
                let standing_word = match &standing {
                    Standing::Failing { passes, cause } => format!("{passes}|{cause}"),
                    Standing::Clear | Standing::Unjudged => "unjudged".to_owned(),
                };
                produced.changes.push(Change::Set {
                    kind: REFRESH_ROW.to_owned(),
                    identity: repo.clone(),
                    value: format!("{}|{standing_word}", newest_known.render()),
                });
                continue;
            }
        }
        let (_, logs) = failed_job_logs(gh, repo, run.id, &["failure"])?;
        let cause = refresh_cause(&logs);
        let mut passes = 0;
        if let Standing::Failing {
            passes: prior,
            cause: prior_cause,
        } = &standing
            && *prior_cause == cause
        {
            passes = prior + 1;
            if passes >= mark_repeat {
                passes = 0;
            }
        }
        if passes == 0 {
            let report = match standing {
                Standing::Clear | Standing::Unjudged => "initial",
                Standing::Failing { .. } => "repeat",
            };
            produced.events.push(Event::RefreshFailing {
                repo: repo.clone(),
                last: run.id.to_string(),
                since: since.clone(),
                report: report.to_owned(),
                cause: cause.clone(),
            });
        }
        inventory
            .refresh_failing
            .insert(repo.clone(), cause.clone());
        produced.changes.push(Change::Set {
            kind: REFRESH_ROW.to_owned(),
            identity: repo.clone(),
            value: format!("{}|{passes}|{cause}", run.render()),
        });
    }
    Ok(())
}

/// A run's conclusion as its word, `None` before it concluded.
fn conclusion(run: &WorkflowRun) -> Option<&'static str> {
    match run.conclusion {
        Nullable::Present(conclusion) => Some(conclusion.word()),
        Nullable::Absent | Nullable::Null => None,
    }
}

impl Nullable<String> {
    fn present_str(&self) -> Option<&str> {
        match self {
            Nullable::Present(s) => Some(s.as_str()),
            Nullable::Absent | Nullable::Null => None,
        }
    }
}

/// The failing conclusions per event: a scheduled
/// run cut short or never started reports too.
fn failing_conclusions(event: &str) -> &'static [&'static str] {
    if event == "push" {
        &["failure", "timed_out"]
    } else {
        &["failure", "timed_out", "cancelled", "startup_failure"]
    }
}

/// The suites a failed log names: the producer
/// summary lines, `suite=… fail=N`, `FAILED: …`, `FAIL …` and the
/// runner's own timeouts; the cause is the first, the failures the suite
/// names, unique.
fn main_push_failures(logs: &[String]) -> (String, Option<Vec<String>>) {
    let mut cause = None;
    let mut failures = BTreeSet::new();
    for line in logs.iter().flat_map(|log| log.lines()) {
        let text = strip_log_prefix(line);
        let suite = text.starts_with("suite=")
            && text.split(' ').any(|w| {
                w.strip_prefix("fail=")
                    .is_some_and(|n| n.parse::<u64>().is_ok_and(|n| n > 0))
            });
        let named = suite
            || text.starts_with("FAILED: ")
            || text.starts_with("FAIL ")
            || text.starts_with("FAIL:")
            || text.starts_with("run-all.sh: suite-timeout ")
            || text.starts_with("run-all.sh: run-deadline ");
        if !named {
            continue;
        }
        let text = text.replace('\t', " ");
        if cause.is_none() {
            cause = Some(text.clone());
        }
        if suite {
            failures.insert(text.split(' ').next().unwrap_or("").to_owned());
        } else if let Some(name) = text.strip_prefix("FAILED: ") {
            failures.insert(name.to_owned());
        }
    }
    (
        cause.unwrap_or_else(|| "unread".to_owned()),
        Some(failures.into_iter().collect()),
    )
}

/// The main-branch incident:
/// per repository, per workflow, per event the last completed run on
/// main; a failing conclusion reads the run's failed jobs and their logs,
/// the row holds `[jobs, failures]` and a line prints when the jobs or
/// the known failures change; an absent workflow, proved by the workflow
/// list, clears its rows and, where declared, prints
/// `main-workflow-absent` once per cause. The repositories whose budget
/// workflow read absent are handed back, so the budget scan skips them.
fn main_push(
    gh: &Gh,
    inputs: &Inputs,
    repos: &[String],
    baseline: &Baseline,
    produced: &mut Produced,
    inventory: &mut Inventory,
) -> Result<BTreeSet<String>> {
    let mut budget_absent = BTreeSet::new();
    let watch = inputs.settings.watch.get()?;
    let declared = &watch.main_workflows;
    let absent_line = |repo: &str, workflow: &str, cause: &str, produced: &mut Produced| {
        let key = format!("{repo}:{workflow}");
        if baseline.get(MAIN_ABSENT_ROW, &key) != Some(cause) {
            produced.events.push(Event::MainWorkflowAbsent {
                repo: repo.to_owned(),
                workflow: workflow.to_owned(),
                cause: cause.to_owned(),
            });
            produced.changes.push(Change::Set {
                kind: MAIN_ABSENT_ROW.to_owned(),
                identity: key,
                value: cause.to_owned(),
            });
        }
    };
    // A row for an entry the setting no longer names is dropped, so a
    // returning entry reports again.
    for key in baseline.identities(MAIN_ABSENT_ROW) {
        if !declared.contains(&key) {
            produced.changes.push(Change::Clear {
                kind: MAIN_ABSENT_ROW.to_owned(),
                identity: key,
            });
        }
    }
    for entry in declared {
        let (repo, workflow) = entry.split_once(':').unwrap_or((entry, ""));
        if !repos.iter().any(|r| r == repo) {
            absent_line(repo, workflow, "unwatched", produced);
        }
    }
    for repo in repos {
        let mut workflows: Vec<String> = MAIN_WORKFLOWS.iter().map(|w| (*w).to_owned()).collect();
        for entry in declared {
            if let Some(workflow) = entry.strip_prefix(&format!("{repo}:"))
                && !workflows.iter().any(|w| w == workflow)
            {
                workflows.push(workflow.to_owned());
            }
        }
        for workflow in &workflows {
            let row_key = format!("{repo}:{workflow}");
            let is_declared = declared.contains(&row_key);
            for event in ["push", "schedule"] {
                let row = if event == "push" {
                    MAIN_PUSH_ROW
                } else {
                    MAIN_SCHEDULE_ROW
                };
                let path = format!(
                    "repos/{repo}/actions/workflows/{workflow}/runs?branch=main&event={event}&status=completed&per_page=1"
                );
                let page: Option<RunsPage> = gh.object("main-push", &path)?;
                let Some(page) = page else {
                    if workflow_absent(gh, repo, workflow)? {
                        if workflow == BUDGET_WORKFLOW {
                            budget_absent.insert(repo.clone());
                        }
                        produced.changes.push(Change::Clear {
                            kind: row.to_owned(),
                            identity: row_key.clone(),
                        });
                        if is_declared {
                            absent_line(repo, workflow, "branch", produced);
                        }
                        continue;
                    }
                    return Err(refused(
                        "github-read-failed",
                        &[("read", "main-push"), ("path", &path)],
                    ));
                };
                if is_declared {
                    produced.changes.push(Change::Clear {
                        kind: MAIN_ABSENT_ROW.to_owned(),
                        identity: row_key.clone(),
                    });
                }
                let Some(run) = page.workflow_runs.first() else {
                    continue;
                };
                let Some(conclusion) = conclusion(run) else {
                    return Err(refused(
                        "github-response-invalid",
                        &[
                            ("read", "main-push"),
                            ("field", "conclusion"),
                            ("value", &run.id.to_string()),
                        ],
                    ));
                };
                let failing = failing_conclusions(event);
                if !failing.contains(&conclusion) {
                    produced.changes.push(Change::Clear {
                        kind: row.to_owned(),
                        identity: row_key.clone(),
                    });
                    continue;
                }
                let (jobs, logs) = failed_job_logs(gh, repo, run.id, failing)?;
                let (cause, failures) = main_push_failures(&logs);
                let jobs_json = serde_json::to_string(&jobs).unwrap_or_default();
                let prior: Option<(String, Option<Vec<String>>)> = baseline
                    .get(row, &row_key)
                    .and_then(|v| {
                        serde_json::from_str::<(Vec<String>, Option<Vec<String>>)>(v).ok()
                    })
                    .map(|(j, f)| (serde_json::to_string(&j).unwrap_or_default(), f));
                let known = match (&failures, &prior) {
                    (None, Some((prior_jobs, prior_failures))) if *prior_jobs == jobs_json => {
                        prior_failures.clone()
                    }
                    _ => failures,
                };
                let changed = match &prior {
                    None => true,
                    Some((prior_jobs, prior_failures)) => {
                        *prior_jobs != jobs_json
                            || (prior_failures.is_some() && known != *prior_failures)
                    }
                };
                if changed {
                    produced.events.push(Event::MainPushFailing {
                        repo: repo.clone(),
                        workflow: workflow.clone(),
                        event: event.to_owned(),
                        run: run.id.to_string(),
                        jobs: jobs_json.clone(),
                        cause: cause.clone(),
                    });
                }
                inventory
                    .main_failing
                    .insert(row_key.clone(), jobs_json.clone());
                let value = serde_json::to_string(&(jobs, known)).unwrap_or_default();
                produced.changes.push(Change::Set {
                    kind: row.to_owned(),
                    identity: row_key.clone(),
                    value,
                });
            }
        }
    }
    Ok(budget_absent)
}

// --- the budget scan ----------------------------------------------------------------------

/// Whether a run is a budget producer: a merge-group run for main, or a
/// push, schedule
/// or manual run on main.
fn budget_producer(run: &WorkflowRun) -> bool {
    let branch = run.head_branch.present_str().unwrap_or("");
    if run.event == "merge_group" {
        branch.starts_with("gh-readonly-queue/main/")
    } else {
        branch == "main"
            && matches!(
                run.event.as_str(),
                "push" | "schedule" | "workflow_dispatch"
            )
    }
}

/// A budget read that could not be judged: named on stderr in the
/// released watch's words, the run left pending for the next pass.
fn budget_unread(repo: &str, read: &str, run: Option<u64>, cause: &Error) {
    let run = run.map(|r| format!(" run={r}")).unwrap_or_default();
    let _ = std::io::Write::write_all(
        &mut std::io::stderr(),
        format!(
            "main-push-unread repo={repo} workflow={BUDGET_WORKFLOW} read={read}{run} cause={cause}\n"
        )
        .as_bytes(),
    );
}

/// The budget warnings of a completed run:
/// every job's check run's annotations, the warnings whose message opens
/// with the budget prefix, unique and sorted; `None` where a page could
/// not be read, so the whole run stays pending.
fn budget_warnings(gh: &Gh, repo: &str, run: u64) -> Result<Option<Vec<String>>> {
    let path = format!("repos/{repo}/actions/runs/{run}/jobs");
    let jobs = match gh.collection::<JobsPage>("budget-jobs", &path) {
        Ok(Some(jobs)) => jobs,
        Ok(None) => {
            budget_unread(
                repo,
                "budget-annotations",
                Some(run),
                &refused(
                    "github-read-failed",
                    &[("read", "budget-jobs"), ("path", &path)],
                ),
            );
            return Ok(None);
        }
        Err(cause) => {
            budget_unread(repo, "budget-annotations", Some(run), &cause);
            return Ok(None);
        }
    };
    let mut warnings = BTreeSet::new();
    for job in jobs {
        let Some(check) = job.check_run_url.strip_prefix("https://api.github.com/") else {
            budget_unread(
                repo,
                "budget-annotations",
                Some(run),
                &refused(
                    "github-response-invalid",
                    &[
                        ("read", "budget-jobs"),
                        ("field", "check_run_url"),
                        ("value", &job.check_run_url),
                    ],
                ),
            );
            return Ok(None);
        };
        let path = format!("{check}/annotations");
        let annotations = match gh.list::<Annotation>("budget-annotations", &path) {
            Ok(Some(annotations)) => annotations,
            Ok(None) => {
                budget_unread(
                    repo,
                    "budget-annotations",
                    Some(run),
                    &refused(
                        "github-read-failed",
                        &[("read", "budget-annotations"), ("path", &path)],
                    ),
                );
                return Ok(None);
            }
            Err(cause) => {
                budget_unread(repo, "budget-annotations", Some(run), &cause);
                return Ok(None);
            }
        };
        for annotation in annotations {
            if annotation.annotation_level == "warning"
                && annotation.message.starts_with(BUDGET_WARNING)
            {
                warnings.insert(annotation.message);
            }
        }
    }
    Ok(Some(warnings.into_iter().collect()))
}

/// The budget scan: per repository whose
/// budget workflow stands, the run history read newest first to the
/// creation watermark (the first page alone on a fresh row), the producer
/// runs past the watermark and the runs still pending judged by status, a
/// completed run's annotations read and its warnings printed once as
/// `main-push-budget`, the row then advanced: the watermark to the newest
/// creation, `seen` the runs at that boundary, `pending` the discovered
/// runs not yet consumed. A read that fails is named on stderr and leaves
/// its run pending; it is never an empty reading.
fn budget(
    gh: &Gh,
    repos: &[String],
    budget_absent: &BTreeSet<String>,
    baseline: &Baseline,
    produced: &mut Produced,
) -> Result<()> {
    for repo in repos {
        if budget_absent.contains(repo) {
            continue;
        }
        let row_key = format!("{repo}:{BUDGET_WORKFLOW}");
        let state: BudgetState = match baseline.get(MAIN_BUDGET_ROW, &row_key) {
            None => BudgetState::default(),
            Some(value) => serde_json::from_str(value).map_err(|_| {
                refused(
                    "github-row-invalid",
                    &[("row", MAIN_BUDGET_ROW), ("value", value)],
                )
            })?,
        };
        let fresh_row = state == BudgetState::default();
        let mut discovered: Vec<(u64, Nullable<RunStatus>)> = Vec::new();
        let mut next_watermark = String::new();
        let mut next_boundary: Vec<u64> = Vec::new();
        let mut unread = false;
        for page in 1..=MAX_PAGES {
            let path = format!(
                "repos/{repo}/actions/workflows/{BUDGET_WORKFLOW}/runs?per_page={PER_PAGE}&page={page}"
            );
            let reply = match gh.object::<RunsPage>("budget-runs", &path) {
                Ok(reply) => reply,
                Err(cause) => {
                    budget_unread(repo, "budget-runs", None, &cause);
                    unread = true;
                    break;
                }
            };
            let Some(reply) = reply else {
                budget_unread(
                    repo,
                    "budget-runs",
                    None,
                    &refused(
                        "github-read-failed",
                        &[("read", "budget-runs"), ("path", &path)],
                    ),
                );
                unread = true;
                break;
            };
            if reply.workflow_runs.is_empty() {
                break;
            }
            let runs = &reply.workflow_runs;
            let newest = runs
                .iter()
                .map(|r| r.created_at.as_str())
                .max()
                .unwrap_or("")
                .to_owned();
            let boundary: BTreeSet<u64> = runs
                .iter()
                .filter(|r| r.created_at == newest)
                .map(|r| r.id)
                .collect();
            for run in runs {
                let producer = budget_producer(run)
                    && run.created_at >= state.watermark
                    && (run.created_at > state.watermark || !state.seen.contains(&run.id));
                if producer || state.pending.contains(&run.id) {
                    discovered.push((run.id, run.status));
                }
            }
            if page == 1 {
                next_watermark = newest.clone();
                next_boundary = boundary.into_iter().collect();
            } else if newest == next_watermark {
                next_boundary.extend(boundary);
            }
            let more = runs.len() == PER_PAGE
                && !state.watermark.is_empty()
                && runs.iter().all(|r| r.created_at >= state.watermark);
            if !more {
                break;
            }
        }
        if unread {
            continue;
        }
        if next_watermark.is_empty() && fresh_row {
            continue;
        }
        let statuses: BTreeMap<u64, Nullable<RunStatus>> = discovered.iter().copied().collect();
        let candidates: BTreeSet<u64> = state
            .pending
            .iter()
            .copied()
            .chain(discovered.iter().map(|(id, _)| *id))
            .collect();
        let mut consumed: BTreeSet<u64> = BTreeSet::new();
        for run in &candidates {
            let status = match statuses.get(run) {
                Some(status) => *status,
                None => {
                    let path = format!("repos/{repo}/actions/runs/{run}");
                    match gh.object::<WorkflowRun>("budget-status", &path) {
                        Ok(Some(read)) => read.status,
                        Ok(None) => {
                            budget_unread(
                                repo,
                                "budget-status",
                                Some(*run),
                                &refused(
                                    "github-read-failed",
                                    &[("read", "budget-status"), ("path", &path)],
                                ),
                            );
                            continue;
                        }
                        Err(cause) => {
                            budget_unread(repo, "budget-status", Some(*run), &cause);
                            continue;
                        }
                    }
                }
            };
            if status != Nullable::Present(RunStatus::Completed) {
                continue;
            }
            let Some(warnings) = budget_warnings(gh, repo, *run)? else {
                continue;
            };
            if !warnings.is_empty() {
                produced.events.push(Event::MainPushBudget {
                    repo: repo.clone(),
                    run: run.to_string(),
                    warnings: serde_json::to_string(&warnings).unwrap_or_default(),
                });
            }
            consumed.insert(*run);
        }
        let seen: BTreeSet<u64> = if next_watermark > state.watermark {
            next_boundary.iter().copied().collect()
        } else if next_watermark == state.watermark {
            state
                .seen
                .iter()
                .copied()
                .chain(next_boundary.iter().copied())
                .collect()
        } else {
            state.seen.iter().copied().collect()
        };
        let next = BudgetState {
            watermark: if next_watermark > state.watermark {
                next_watermark
            } else {
                state.watermark.clone()
            },
            seen: seen.into_iter().collect(),
            pending: candidates
                .into_iter()
                .filter(|run| !consumed.contains(run))
                .collect(),
        };
        produced.changes.push(Change::Set {
            kind: MAIN_BUDGET_ROW.to_owned(),
            identity: row_key,
            value: serde_json::to_string(&next).unwrap_or_default(),
        });
    }
    Ok(())
}

/// The reducer context's value, for a reader comparing the slot.
pub fn pr_watch_context(rc: i32, out: &str, err: &str) -> pr_watch::Context {
    pr_watch::Context {
        rc,
        out: out.to_owned(),
        err: err.to_owned(),
    }
}

pub fn row_kinds() -> [&'static str; 12] {
    [
        MERGED_ROW,
        PARKED_UNTIL_ROW,
        REFRESH_ROW,
        MAIN_PUSH_ROW,
        MAIN_SCHEDULE_ROW,
        MAIN_ABSENT_ROW,
        MAIN_BUDGET_ROW,
        pr_watch::ROW,
        outside::ROW,
        security::ALERT_ROW,
        security::BOT_FIX_ROW,
        SIGN_IN_ROW,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pull(number: u64, branch: &str, owner: Option<&str>, title: &str, body: &str) -> Pull {
        use crate::verify::wire::{HeadRepo, PullBase, PullHead, User};
        Pull {
            number,
            state: "closed".into(),
            title: title.into(),
            body: Nullable::Present(body.into()),
            draft: Optional::Absent,
            merged_at: Nullable::Present("2026-10-01T00:00:00Z".into()),
            merge_commit_sha: Nullable::Null,
            changed_files: Optional::Absent,
            author_association: "NONE".into(),
            head: PullHead {
                sha: "0".repeat(40),
                branch: branch.into(),
                repo: match owner {
                    Some(login) => Nullable::Present(HeadRepo {
                        full_name: format!("{login}/repo"),
                        owner: User {
                            login: login.into(),
                            kind: "User".into(),
                        },
                    }),
                    None => Nullable::Null,
                },
            },
            base: PullBase {
                branch: "main".into(),
                sha: "0123456789abcdef0123456789abcdef01234567".into(),
            },
            user: Nullable::Null,
        }
    }

    /// The lane-own rule on the merged index's shapes: the branch, the
    /// title scope, the
    /// `Closes` line and the recorded number each own; a fork's head, a
    /// mention elsewhere in the title and a `Closes` of another key do not.
    #[test]
    fn a_pull_request_is_the_lanes_own_by_its_branch_title_or_closes_line() {
        let rows: [(Pull, bool); 8] = [
            (pull(1, "ken-100", Some("owner"), "repair", ""), true),
            (
                pull(2, "cloud-branch", Some("owner"), "fix(KEN-100): repair", ""),
                true,
            ),
            (
                pull(
                    3,
                    "cloud-branch",
                    Some("owner"),
                    "fix(a, KEN-100)!: repair",
                    "",
                ),
                true,
            ),
            (
                pull(
                    4,
                    "cloud-branch",
                    Some("owner"),
                    "repair",
                    "Context\n- Closes KEN-100\n",
                ),
                true,
            ),
            (
                pull(
                    5,
                    "cloud-branch",
                    Some("owner"),
                    "repair",
                    "Closes KEN-1000",
                ),
                false,
            ),
            (
                pull(9999, "ken-100", Some("fork"), "fix(KEN-100): fork", ""),
                false,
            ),
            (
                pull(7, "cloud-branch", Some("owner"), "revert KEN-100", ""),
                false,
            ),
            (pull(8, "cloud-branch", None, "fix(KEN-100): x", ""), false),
        ];
        for (pull, own) in &rows {
            assert_eq!(
                lane_own(pull, "KEN-100", "Owner", None),
                *own,
                "#{}",
                pull.number
            );
        }
        assert!(
            lane_own(&rows[6].0, "KEN-100", "owner", Some(7)),
            "the recorded number owns"
        );
    }

    /// The refresh row's two layouts, the runtime's and a released watch's,
    /// round-trip, and an unknown layout is refused.
    #[test]
    fn the_refresh_row_reads_the_runtime_and_released_layouts() {
        let key = RunKey {
            created_at: "2026-01-01T00:00:00Z".into(),
            id: 1234,
            attempt: 1,
        };
        assert_eq!(key.render(), "[\"2026-01-01T00:00:00Z\",1234,1]");
        assert_eq!(RunKey::parse(&key.render()), Some(key.clone()));
        let rows = [
            (
                format!("{}|", key.render()),
                Some(key.clone()),
                Standing::Clear,
            ),
            (
                format!("{}|unjudged", key.render()),
                Some(key.clone()),
                Standing::Unjudged,
            ),
            (
                format!("{}|2|failed: x", key.render()),
                Some(key.clone()),
                Standing::Failing {
                    passes: 2,
                    cause: "failed: x".into(),
                },
            ),
            (
                "3|Error: y".to_owned(),
                None,
                Standing::Failing {
                    passes: 3,
                    cause: "Error: y".into(),
                },
            ),
        ];
        for (value, recorded, standing) in rows {
            assert_eq!(
                refresh_row(&value).unwrap(),
                (recorded, standing),
                "{value}"
            );
        }
        assert_eq!(
            refresh_row("garbage").unwrap_err().key(),
            "github-row-invalid"
        );
    }

    /// The cause ranking over job logs with their timestamp prefixes.
    #[test]
    fn the_cause_is_the_last_line_of_the_highest_rank() {
        let log = "2026-01-01T00:00:00.0000000Z Error: first\n2026-01-01T00:00:01.0000000Z failed: suite\tx\r\n2026-01-01T00:00:02.0000000Z Error: later\n".to_owned();
        assert_eq!(refresh_cause(&[log]), "failed: suite x");
        assert_eq!(
            refresh_cause(&["2026-01-01T00:00:00Z fine\n".to_owned()]),
            "unread"
        );
        let (cause, failures) = main_push_failures(&[
            "2026-01-01T00:00:00Z suite=a fail=2 pass=1\n2026-01-01T00:00:00Z FAILED: b\n2026-01-01T00:00:00Z suite=c fail=0\n".to_owned(),
        ]);
        assert_eq!(cause, "suite=a fail=2 pass=1");
        assert_eq!(failures, Some(vec!["b".to_owned(), "suite=a".to_owned()]));
    }
}
