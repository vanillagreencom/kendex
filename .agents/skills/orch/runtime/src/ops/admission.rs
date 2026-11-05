//! The admission judgement a lane launch runs before the cap, and a
//! running lane runs for a path it adds: the item's eligibility from its
//! body, its touched set as the
//! union of the item's Location paths, the brief's paths, the change-scope
//! paths over the range the request names and the paths the request adds,
//! and every holder of a shared path judged by its lane's liveness through
//! the occupancy identity reads, never by its status word.
//!
//! | Holder's lane reads (`occupancy::lane_charge`) | Judgement |
//! |---|---|
//! | `live`, `wake` or `preparing` | blocks: `launch-overlap holder=<item>` |
//! | `unknown`: an unreadable identity, or an in-flight record with none | blocks: `holder-unreadable read=identity` |
//! | `reservation`, or no charge: a stopped, parked or gone holder | yields: a [`RebaseObligation`] naming it is recorded on the launching item's lane record |
//! | a hosted lane (`host` recorded): no identity this host reads | `running` or `preparing` blocks, else yields (its host's) |
//! | `done` | no holder |
//!
//! A holder is a record of the item's repository: a path is relative to
//! its own repository, so a lane of another holds nothing here. A holder's
//! touched set is its record's, else its item's Location paths read now;
//! a holder whose set cannot be read blocks `holder-unreadable
//! read=touched`. `changelog.d/` paths never count, and a path the request
//! names in scope is left out of the comparison.
//!
//! An open pull request of the item's repository is a holder of the paths
//! it changes: its liveness is
//! its state, read from GitHub by number through the one `gh api`
//! transport (`watch::github::Gh`, the `gh` on `PATH`). Open yields, a
//! [`RebaseObligation`] naming `#N` and its head branch; closed, merged, a
//! fork's or a deleted fork's holds nothing. A list, object or files read
//! that fails, answers nothing, decodes to no member or falls short of the
//! object's `changed_files` blocks `holders-unreadable`: an unread
//! inventory is never an empty one. A pull request
//! a lane record of this fleet names, by its `pending_pr` or `parked`
//! number or by its head branch (the lane's recorded branch, or its item
//! key), is that lane's work and judged once, as the lane; a record
//! reading `done` names none, so its open pull request is a holder as a
//! pull request; the item's own branch holds nothing against it. The pull
//! requests are read once per admission, after the lanes, only where the
//! candidate set is not empty, of the repository the request names, else
//! of the checkout it names (`repo_dir`, the fleet's own repository, whose
//! lane records name none): the slug `gh repo view` answers in the
//! checkout, else the one its `origin` remote names on github.com; a
//! checkout naming no GitHub repository
//! blocks `holders-unreadable read=repo`. A request naming neither reads
//! none.
//!
//! The item's body is read only where the request names its tracker: a
//! launch that names none is judged on the sources it does name. A
//! `linear` item's launch blockers are read with it, and every container
//! ancestor's up its `parent_id` chain: an open blocker anywhere on the
//! chain refuses `launch-blocked` naming the blockers, and a node the
//! tracker could not read whole, or whose answer carries no launch-blocker
//! field, refuses `launch-blocked-unread`, before any holder is judged or
//! any record is written.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::occupancy::{self, ChargeReason, Host};
use super::{Env, intents, lane_at, lane_doc_mut, lanes};
use crate::error::{Error, Result};
use crate::state::{self, Document, Intent, Lane, LaneStatus, RebaseObligation};
use crate::verify::wire::{Nullable, Optional};
use crate::watch::github::Gh;

/// The item as its tracker reports it: the body the Location paths are
/// read from, and what eligibility is judged on.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ItemRead {
    pub body: String,
    pub labels: Vec<String>,
    pub children: usize,
    /// The review audit's in-PR bundle root, the one container launched
    /// (`skill-rules.md` § Containers; the linear package's `in_pr_bundle`).
    pub in_pr_bundle: bool,
    /// The container the item sits under, where the tracker reports one.
    pub parent_id: Option<String>,
    /// The items that block this one's launch as the tracker judges them
    /// (the linear package's `blocked_by_launch`, read under the safe bundle
    /// format this runtime asks for by name); `None` where the answer
    /// carries no such field, which is no judgement: the gate refuses on it
    /// rather than reading no blocker.
    pub blocked_by_launch: Option<Vec<String>>,
}

/// A diff range the change-scope paths are read over,
/// each end a revision the checkout resolves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScopeRange {
    pub base: String,
    pub head: String,
}

/// The programs the admission reads through, from the settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Clis {
    /// The linear package's CLI.
    pub tracker: PathBuf,
    /// GitHub's CLI, for an `issue-N` item.
    pub gh: PathBuf,
    /// The change-scope package's path reader, `harness-only`.
    pub scope_paths: PathBuf,
}

/// Why a read answered nothing: the cause the refusal carries.
pub type ReadFailure = String;

/// One open same-repository pull request and the paths it changes, a
/// holder of them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct OpenPull {
    pub number: u64,
    /// Its head branch, `head.ref`.
    pub branch: String,
    pub files: Vec<String>,
}

/// The open pull requests of one repository, with the `owner/name` they
/// were read from.
pub(super) struct OpenPulls {
    pub repo: String,
    pub pulls: Vec<OpenPull>,
}

/// Why the pull requests could not be read: which read (`repo`, `pulls`,
/// `pull`, `files`), the repository as named (the slug, or the checkout it
/// was to be read from) and the cause.
pub(super) struct PullsFailure {
    pub read: &'static str,
    pub repo: String,
    pub cause: String,
}

/// The item read, by tracker (`linear` or `github`), item and repository.
pub(super) type ItemReader<'a> =
    Box<dyn Fn(&Clis, &str, &str, Option<&str>) -> std::result::Result<ItemRead, ReadFailure> + 'a>;

/// The changed paths of a range, read in the checkout at the path.
pub(super) type RangeReader<'a> =
    Box<dyn Fn(&Clis, &Path, &ScopeRange) -> std::result::Result<Vec<String>, ReadFailure> + 'a>;

/// The open pull requests of the repository the request names, else of
/// the checkout it names; `None` where it names neither.
pub(super) type PullsReader<'a> = Box<
    dyn Fn(
            &Clis,
            Option<&str>,
            Option<&Path>,
        ) -> std::result::Result<Option<OpenPulls>, PullsFailure>
        + 'a,
>;

/// The admission's reads a host carries: the programs and the three
/// readers over them. A host built without them (the effect and duty
/// entries, which launch no lane) judges a launch that names a source as
/// `touched-unreadable`.
pub(super) struct AdmissionReads<'a> {
    pub clis: Clis,
    pub item: ItemReader<'a>,
    pub range_paths: RangeReader<'a>,
    pub pulls: PullsReader<'a>,
}

impl AdmissionReads<'static> {
    /// The production reads through the named programs.
    pub(super) fn through(clis: Clis) -> AdmissionReads<'static> {
        AdmissionReads {
            clis,
            item: Box::new(read_item),
            range_paths: Box::new(read_range_paths),
            pulls: Box::new(read_open_pulls),
        }
    }
}

/// Judge the paths a lane adds within its item's outcome, or a launch
/// before any record stands. The
/// touched set judged is the union of the sources the request names and
/// `paths`; where a lane record stands, it is widened by that set and the
/// obligations found, and a lane record reading `done` refuses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AdmitPaths {
    pub item: String,
    #[serde(default)]
    pub tracker: Option<String>,
    #[serde(default)]
    pub repo: Option<String>,
    /// The paths added, judged as touched.
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub brief_file: Option<PathBuf>,
    /// The checkout the change-scope paths are read in.
    #[serde(default)]
    pub repo_dir: Option<PathBuf>,
    #[serde(default)]
    pub scope_range: Option<ScopeRange>,
    #[serde(default)]
    pub in_scope: Vec<String>,
}

/// The judgement, and the lane record as widened where one stands.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PathsAdmitted {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane: Option<Box<Lane>>,
    /// The touched set judged: the record's and the request's together
    /// where a record stands.
    pub touched: Vec<String>,
    pub in_scope: Vec<String>,
    pub rebase: Vec<RebaseObligation>,
    /// Whether a lane record was widened.
    pub recorded: bool,
}

/// What one judgement reads: the launch's or the added paths' inputs.
pub(super) struct Admission<'r> {
    pub item: &'r str,
    pub tracker: Option<&'r str>,
    pub repo: Option<&'r str>,
    pub brief_file: Option<&'r Path>,
    pub repo_dir: Option<&'r Path>,
    pub scope_range: Option<&'r ScopeRange>,
    pub in_scope: &'r [String],
    /// The paths the request adds to the touched set.
    pub paths: &'r [String],
}

/// What the judge answers when it admits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Judged {
    pub touched: Vec<String>,
    pub in_scope: Vec<String>,
    pub rebase: Vec<RebaseObligation>,
}

/// Paths the overlap never counts: the changelog fragments every lane
/// adds beside its own.
const UNCOUNTED_PREFIX: &str = "changelog.d/";

/// The launch blockers of `item` and of every container ancestor up its
/// `parent_id` chain, each ancestor read through `reader`: a chain read
/// whole with none passes; a blocker on it refuses `launch-blocked` with
/// the blockers sorted, once each; a node whose read fails, whose answer
/// names no launch blockers (a formatter without the field), or whose
/// parent is an item already read refuses `launch-blocked-unread` naming
/// it.
fn launch_blockers(
    item: &str,
    read: &ItemRead,
    reader: impl Fn(&str) -> std::result::Result<ItemRead, ReadFailure>,
) -> Result<()> {
    let unread = |read: &str, cause: &str| Error::LaunchBlockedUnread {
        item: item.to_owned(),
        read: read.to_owned(),
        cause: cause.to_owned(),
    };
    let mut blockers: BTreeSet<String> = BTreeSet::new();
    let mut seen: BTreeSet<String> = [item.to_owned()].into();
    let mut current = read.clone();
    let mut current_id = item.to_owned();
    loop {
        match &current.blocked_by_launch {
            Some(judged) => blockers.extend(judged.iter().cloned()),
            None => return Err(unread(&current_id, "blocked-by-launch-missing")),
        }
        let Some(parent) = current.parent_id.clone().filter(|p| !p.is_empty()) else {
            break;
        };
        if !seen.insert(parent.clone()) {
            return Err(unread(&parent, "chain-repeats"));
        }
        current = reader(&parent).map_err(|cause| unread(&parent, &cause))?;
        current_id = parent;
    }
    if blockers.is_empty() {
        return Ok(());
    }
    Err(Error::LaunchBlocked {
        item: item.to_owned(),
        blockers: blockers.into_iter().collect(),
    })
}

/// Whether the cause word a container refusal carries.
fn eligibility(item: &ItemRead) -> std::result::Result<(), &'static str> {
    if item.in_pr_bundle {
        return Ok(());
    }
    if item.children > 0 {
        return Err("parent-with-children");
    }
    if item.labels.iter().any(|l| l == "agent:multi") {
        return Err("agent-multi");
    }
    Ok(())
}

/// Whether `line` is a Location header:
/// optional bullet, optional emphasis marks, `Location`, emphasis marks, a
/// colon.
fn is_location_line(line: &str) -> bool {
    let mut rest = line.trim_start();
    if let Some(after) = rest.strip_prefix(['-', '*', '+'])
        && after.starts_with(char::is_whitespace)
    {
        rest = after.trim_start();
    }
    let rest = rest.trim_start_matches(['*', '_']);
    let Some(rest) = rest.strip_prefix("Location") else {
        return false;
    };
    rest.trim_start_matches(['*', '_'])
        .trim_start()
        .starts_with(':')
}

/// The backticked tokens of `text` holding no whitespace, each less a
/// `:N` or `:N-M` line suffix.
fn ticks(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('`') {
        let after = &rest[open + 1..];
        let Some(close) = after.find('`') else {
            break;
        };
        let token = &after[..close];
        if !token.is_empty() && !token.chars().any(char::is_whitespace) {
            found.push(without_line_suffix(token).to_owned());
        }
        rest = &after[close + 1..];
    }
    found
}

/// `token` less a trailing `:N` or `:N-M`.
fn without_line_suffix(token: &str) -> &str {
    let Some((head, tail)) = token.rsplit_once(':') else {
        return token;
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let is_lines = match tail.split_once('-') {
        Some((from, to)) => digits(from) && digits(to),
        None => digits(tail),
    };
    if is_lines && !head.is_empty() {
        head
    } else {
        token
    }
}

/// The paths the body's Location lines name. A Location line naming no
/// backticked path is unread (`location`).
fn location_paths(body: &str) -> std::result::Result<Vec<String>, &'static str> {
    let mut located = false;
    let mut paths = Vec::new();
    for line in body.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if is_location_line(line) {
            located = true;
            paths.extend(ticks(line));
        }
    }
    if located && paths.is_empty() {
        return Err("location");
    }
    Ok(paths)
}

/// The paths a brief names: its backticked tokens that hold a `/`, less
/// a URL and an option word. A brief names files in prose, so the form is
/// the rule; a token that is no path overlaps nothing.
fn brief_paths(brief: &str) -> Vec<String> {
    ticks(brief)
        .into_iter()
        .filter(|t| t.contains('/') && !t.contains("://") && !t.starts_with('-'))
        .collect()
}

/// Whether `a` and `b` name one file: equal, or one a directory (`/`) the
/// other is under.
fn meets(a: &str, b: &str) -> bool {
    a == b || (a.ends_with('/') && b.starts_with(a)) || (b.ends_with('/') && a.starts_with(b))
}

/// Whether an in-scope entry `scope` covers `file`.
fn covers(scope: &str, file: &str) -> bool {
    scope == file || (scope.ends_with('/') && file.starts_with(scope))
}

/// The paths `a` and `b` share that the scope leaves in, each the longer
/// of its pair, sorted and unique.
fn shared(a: &[String], b: &[String], scope: &[String]) -> Vec<String> {
    let mut files = BTreeSet::new();
    for x in a {
        for y in b {
            if y.starts_with(UNCOUNTED_PREFIX) || !meets(x, y) {
                continue;
            }
            let file = if y.len() > x.len() { y } else { x };
            if !scope.iter().any(|s| covers(s, file)) {
                files.insert(file.clone());
            }
        }
    }
    files.into_iter().collect()
}

/// Whether a holder record belongs to the request's repository: both name
/// the same one, case apart, or neither names one, the fleet's own.
fn same_repo(lane: &Lane, repo: Option<&str>) -> bool {
    match (lane.repo.as_deref(), repo) {
        (None, None) => true,
        (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
        (None, Some(_)) | (Some(_), None) => false,
    }
}

/// How a holder stands: live blocks, unknown blocks as unreadable,
/// anything else yields.
enum Holding {
    Live,
    Unknown(String),
    Yields,
}

fn holding(lane: &Lane, intents: &[Intent], env: &Env, host: &Host) -> Holding {
    if lane.host.is_some() {
        return if lane.status.in_flight() {
            Holding::Live
        } else {
            Holding::Yields
        };
    }
    let ids = occupancy::read_identities(lane, host);
    let charge = occupancy::lane_charge(
        lane,
        occupancy::launch_open(intents, &lane.item),
        env.now_secs,
        &ids,
    );
    match charge.map(|c| (c.reason, c.cause)) {
        Some((
            ChargeReason::Live
            | ChargeReason::Wake
            | ChargeReason::Preparing
            | ChargeReason::Session,
            _,
        )) => Holding::Live,
        Some((ChargeReason::Unknown, cause)) => Holding::Unknown(cause.unwrap_or_default()),
        Some((ChargeReason::Reservation, _)) | None => Holding::Yields,
    }
}

/// The branch the holder's item state records, read beside the fleet
/// record: `None` where no item state stands or it names none.
#[allow(
    clippy::disallowed_methods,
    reason = "the admission's one read of a holder's item state, for the branch its obligation names; nothing is written"
)]
fn holder_branch(fleet: &Path, holder: &str) -> Result<Option<String>> {
    let dir = fleet.parent().unwrap_or(Path::new(""));
    let Some(snapshot) = state::load(&state::item_path(dir, holder))? else {
        return Ok(None);
    };
    Ok(snapshot
        .doc
        .get("branch")
        .and_then(Value::as_str)
        .filter(|b| !b.is_empty())
        .map(str::to_owned))
}

/// The judgement (the module's table). `lanes` and `intents` are the
/// fleet's as the transition read them under the launch lock.
pub(super) fn judge(
    path: &Path,
    lanes: &[Lane],
    intents: &[Intent],
    a: &Admission,
    env: &Env,
    host: &Host,
) -> Result<Judged> {
    let unreadable = |read: &'static str, cause: String| Error::TouchedUnreadable {
        item: a.item.to_owned(),
        read,
        cause,
    };
    let reads = |read: &'static str| {
        host.admission
            .as_ref()
            .ok_or_else(|| unreadable(read, "admission-reads-unavailable".to_owned()))
    };
    let mut touched: BTreeSet<String> = BTreeSet::new();
    if let Some(tracker) = a.tracker {
        let reads = reads("item")?;
        let item = (reads.item)(&reads.clis, tracker, a.item, a.repo)
            .map_err(|c| unreadable("item", c))?;
        if let Err(cause) = eligibility(&item) {
            return Err(Error::ItemIneligible {
                item: a.item.to_owned(),
                cause,
            });
        }
        if tracker == "linear" {
            launch_blockers(a.item, &item, |parent| {
                (reads.item)(&reads.clis, tracker, parent, a.repo)
            })?;
        }
        touched.extend(location_paths(&item.body).map_err(|c| unreadable("location", c.into()))?);
    }
    if let Some(brief) = a.brief_file {
        let text =
            std::fs::read_to_string(brief).map_err(|e| unreadable("brief", e.to_string()))?;
        touched.extend(brief_paths(&text));
    }
    if let Some(range) = a.scope_range {
        let reads = reads("classification")?;
        let dir = a
            .repo_dir
            .ok_or_else(|| unreadable("classification", "repo-dir-unnamed".to_owned()))?;
        touched.extend(
            (reads.range_paths)(&reads.clis, dir, range)
                .map_err(|c| unreadable("classification", c))?,
        );
    }
    touched.extend(a.paths.iter().cloned());
    touched.retain(|p| !p.is_empty() && !p.starts_with(UNCOUNTED_PREFIX));
    let touched: Vec<String> = touched.into_iter().collect();
    let in_scope: Vec<String> = a
        .in_scope
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let mut rebase = Vec::new();
    if touched.is_empty() {
        return Ok(Judged {
            touched,
            in_scope,
            rebase,
        });
    }
    let holder_unreadable =
        |holder: &str, read: &'static str, cause: String| Error::HolderUnreadable {
            item: a.item.to_owned(),
            holder: holder.to_owned(),
            read,
            cause,
        };
    for lane in lanes {
        if lane.item == a.item || lane.status == LaneStatus::Done || !same_repo(lane, a.repo) {
            continue;
        }
        let read;
        let held = match &lane.touched {
            Some(paths) => paths,
            None => {
                let tracker = lane.tracker.as_deref().ok_or_else(|| {
                    holder_unreadable(&lane.item, "touched", "tracker-unnamed".to_owned())
                })?;
                let reads = host.admission.as_ref().ok_or_else(|| {
                    holder_unreadable(
                        &lane.item,
                        "touched",
                        "admission-reads-unavailable".to_owned(),
                    )
                })?;
                let item = (reads.item)(&reads.clis, tracker, &lane.item, lane.repo.as_deref())
                    .map_err(|c| holder_unreadable(&lane.item, "touched", c))?;
                read = location_paths(&item.body)
                    .map_err(|c| holder_unreadable(&lane.item, "touched", c.to_owned()))?;
                &read
            }
        };
        let paths = shared(&touched, held, &in_scope);
        let Some(file) = paths.first() else {
            continue;
        };
        match holding(lane, intents, env, host) {
            Holding::Live => {
                return Err(Error::LaunchOverlap {
                    item: a.item.to_owned(),
                    file: file.clone(),
                    holder: lane.item.clone(),
                });
            }
            Holding::Unknown(cause) => {
                return Err(holder_unreadable(&lane.item, "identity", cause));
            }
            Holding::Yields => rebase.push(RebaseObligation {
                holder: lane.item.clone(),
                branch: holder_branch(path, &lane.item)?,
                paths,
                at: env.iso(),
            }),
        }
    }
    if a.repo.is_some() || a.repo_dir.is_some() {
        let reads = host
            .admission
            .as_ref()
            .ok_or_else(|| Error::HoldersUnreadable {
                item: a.item.to_owned(),
                repo: a
                    .repo
                    .map(str::to_owned)
                    .or_else(|| a.repo_dir.map(|dir| dir.display().to_string()))
                    .unwrap_or_default(),
                read: "pulls",
                cause: "admission-reads-unavailable".to_owned(),
            })?;
        let read = (reads.pulls)(&reads.clis, a.repo, a.repo_dir).map_err(|failure| {
            Error::HoldersUnreadable {
                item: a.item.to_owned(),
                repo: failure.repo,
                read: failure.read,
                cause: failure.cause,
            }
        })?;
        if let Some(OpenPulls { repo, pulls }) = read
            && !pulls.is_empty()
        {
            let own_branch = holder_branch(path, a.item)?;
            // A `done` record names no pull request: its lane is no holder
            // (the module table), so an open pull request it left is judged
            // as a pull request.
            let named: Vec<(&Lane, Option<String>)> = lanes
                .iter()
                .filter(|lane| lane.status != LaneStatus::Done && same_repo(lane, a.repo))
                .map(|lane| Ok((lane, holder_branch(path, &lane.item)?)))
                .collect::<Result<_>>()?;
            for pull in pulls {
                let own = pull.branch.eq_ignore_ascii_case(a.item)
                    || own_branch.as_deref() == Some(pull.branch.as_str());
                if own
                    || named
                        .iter()
                        .any(|(lane, branch)| names_pull(lane, branch.as_deref(), &pull, &repo))
                {
                    continue;
                }
                let paths = shared(&touched, &pull.files, &in_scope);
                if paths.is_empty() {
                    continue;
                }
                rebase.push(RebaseObligation {
                    holder: format!("#{}", pull.number),
                    branch: Some(pull.branch),
                    paths,
                    at: env.iso(),
                });
            }
        }
    }
    Ok(Judged {
        touched,
        in_scope,
        rebase,
    })
}

/// Whether a lane record names the pull request as its own work: its
/// `pending_pr` or `parked` record carries the number, for this repository
/// where it names one, or the pull request's head branch is the lane's, the
/// branch its item state records or its item key. A record's own facts,
/// not the merged index's mention rule: a stranger's pull request that
/// cites an item in its title is exactly the holder kept.
fn names_pull(lane: &Lane, branch: Option<&str>, pull: &OpenPull, repo: &str) -> bool {
    let numbered = ["pending_pr", "parked"]
        .iter()
        .filter_map(|key| lane.extra.get(*key))
        .any(|record| {
            let here = record
                .get("repo")
                .and_then(Value::as_str)
                .is_none_or(|r| r.eq_ignore_ascii_case(repo));
            here && record.get("pr").and_then(Value::as_u64) == Some(pull.number)
        });
    numbered || branch == Some(pull.branch.as_str()) || pull.branch.eq_ignore_ascii_case(&lane.item)
}

/// `standing` joined by `added`, each holder once: a holder already
/// recorded keeps its stamp and gains the paths.
fn merged(standing: &[RebaseObligation], added: Vec<RebaseObligation>) -> Vec<RebaseObligation> {
    let mut by_holder: BTreeMap<String, RebaseObligation> = BTreeMap::new();
    let mut order = Vec::new();
    for obligation in standing.iter().cloned().chain(added) {
        match by_holder.get_mut(&obligation.holder) {
            Some(held) => {
                for path in obligation.paths {
                    if !held.paths.contains(&path) {
                        held.paths.push(path);
                    }
                }
                held.paths.sort();
            }
            None => {
                order.push(obligation.holder.clone());
                by_holder.insert(obligation.holder.clone(), obligation);
            }
        }
    }
    order
        .into_iter()
        .filter_map(|holder| by_holder.remove(&holder))
        .collect()
}

/// `a` and `b` as one sorted set.
fn union(a: &[String], b: &[String]) -> Vec<String> {
    a.iter()
        .chain(b)
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Write a judgement onto the lane record at `index`.
pub(super) fn record(path: &Path, doc: &mut Document, index: usize, judged: &Judged) -> Result<()> {
    let lane = lane_doc_mut(path, doc, index)?;
    state::set(lane, "touched", serde_json::to_value(&judged.touched)?);
    state::set(lane, "in_scope", serde_json::to_value(&judged.in_scope)?);
    if judged.rebase.is_empty() {
        state::delete(lane, "rebase");
    } else {
        state::set(lane, "rebase", serde_json::to_value(&judged.rebase)?);
    }
    Ok(())
}

/// The `admit-paths` transition: the judgement of the request's sources
/// and paths, widened onto the lane record where one stands. The record's
/// own touched set is not judged again: the paths it holds were admitted
/// when they were recorded.
pub(super) fn admit_paths(
    path: &Path,
    doc: &mut Document,
    r: &AdmitPaths,
    env: &Env,
    host: &Host,
) -> Result<PathsAdmitted> {
    let lanes = lanes(path, doc)?;
    let intents = intents(path, doc)?;
    let position = lanes.iter().position(|l| l.item == r.item);
    if let Some(index) = position
        && lanes[index].status == LaneStatus::Done
    {
        return Err(Error::LaneDone {
            item: r.item.clone(),
        });
    }
    let standing_scope = position
        .and_then(|i| lanes[i].in_scope.clone())
        .unwrap_or_default();
    let in_scope = union(&standing_scope, &r.in_scope);
    let judged = judge(
        path,
        &lanes,
        &intents,
        &Admission {
            item: &r.item,
            tracker: r.tracker.as_deref(),
            repo: r.repo.as_deref(),
            brief_file: r.brief_file.as_deref(),
            repo_dir: r.repo_dir.as_deref(),
            scope_range: r.scope_range.as_ref(),
            in_scope: &in_scope,
            paths: &r.paths,
        },
        env,
        host,
    )?;
    let Some(index) = position else {
        return Ok(PathsAdmitted {
            lane: None,
            touched: judged.touched,
            in_scope: judged.in_scope,
            rebase: judged.rebase,
            recorded: false,
        });
    };
    let standing = &lanes[index];
    let widened = Judged {
        touched: union(
            standing.touched.as_deref().unwrap_or_default(),
            &judged.touched,
        ),
        in_scope: judged.in_scope,
        rebase: merged(&standing.rebase, judged.rebase),
    };
    record(path, doc, index, &widened)?;
    Ok(PathsAdmitted {
        lane: Some(Box::new(lane_at(path, doc, index)?)),
        touched: widened.touched,
        in_scope: widened.in_scope,
        rebase: widened.rebase,
        recorded: true,
    })
}

/// How long one read may take: a tracker call, or `harness-only` over a
/// range.
const READ_TIMEOUT: Duration = Duration::from_secs(60);
/// The runner tag the admission's reads are counted under.
const TAG: &str = "admission";

/// The linear package's `issues get ID --with-bundle --format=safe`
/// (`lib/formatters.sh` `format_issue_with_bundle`): the description, the
/// label names, the flattened children, the in-PR bundle mark, the
/// container's id and the launch blockers its one classifier judges.
/// `blocked_by_launch` has no default: a bundle formatter without the field
/// answers `None`, which the gate refuses rather than reads as no blocker.
#[derive(Deserialize)]
struct LinearIssue {
    #[serde(default)]
    description: String,
    #[serde(default)]
    labels: Vec<String>,
    #[serde(default)]
    children: Vec<Value>,
    #[serde(default)]
    in_pr_bundle: bool,
    #[serde(default)]
    parent_id: String,
    blocked_by_launch: Option<Vec<String>>,
}

/// `gh issue view N --repo R --json body,labels`: the body and the labels
/// as `{name}` objects.
#[derive(Deserialize)]
struct GithubIssue {
    #[serde(default)]
    body: String,
    #[serde(default)]
    labels: Vec<GithubLabel>,
}

#[derive(Deserialize)]
struct GithubLabel {
    name: String,
}

/// The first non-empty stderr line, the cause a failed call names.
fn first_line(output: &std::process::Output) -> String {
    host::stderr_text(output)
        .lines()
        .find(|l| !l.trim().is_empty())
        .map(str::trim)
        .unwrap_or("")
        .to_owned()
}

/// Run `cli` with `args` through the one runner, answering its stdout; a
/// run that could not start or exited nonzero is the failure's cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the admission's reads of the tracker, gh and the change-scope path reader through agent-runtime's one runner, no effect on a lane or a controller"
)]
fn read_stdout(
    program: &'static str,
    cli: &Path,
    read: &'static str,
    args: &[&str],
) -> std::result::Result<Vec<u8>, ReadFailure> {
    let output =
        host::run_tagged(TAG, program, cli, read, args, READ_TIMEOUT).map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("{read} {}: {}", output.status, first_line(&output)));
    }
    Ok(output.stdout)
}

/// The production item read: the linear CLI's bundle read for a `linear`
/// item, `gh issue view` for a `github` item keyed `issue-N`.
pub(super) fn read_item(
    clis: &Clis,
    tracker: &str,
    item: &str,
    repo: Option<&str>,
) -> std::result::Result<ItemRead, ReadFailure> {
    match tracker {
        "linear" => {
            let stdout = read_stdout(
                "linear",
                &clis.tracker,
                "issue-read",
                &["issues", "get", item, "--with-bundle", "--format=safe"],
            )?;
            let issue: LinearIssue =
                serde_json::from_slice(&stdout).map_err(|e| format!("issue-read: {e}"))?;
            Ok(ItemRead {
                body: issue.description,
                labels: issue.labels,
                children: issue.children.len(),
                in_pr_bundle: issue.in_pr_bundle,
                parent_id: Some(issue.parent_id).filter(|p| !p.is_empty()),
                blocked_by_launch: issue.blocked_by_launch,
            })
        }
        "github" => {
            let number = item
                .strip_prefix("issue-")
                .filter(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
                .ok_or_else(|| "key-form".to_owned())?;
            let repo = repo.ok_or_else(|| "repo-unnamed".to_owned())?;
            let stdout = read_stdout(
                "gh",
                &clis.gh,
                "issue-view",
                &[
                    "issue",
                    "view",
                    number,
                    "--repo",
                    repo,
                    "--json",
                    "body,labels",
                ],
            )?;
            let issue: GithubIssue =
                serde_json::from_slice(&stdout).map_err(|e| format!("issue-view: {e}"))?;
            Ok(ItemRead {
                body: issue.body,
                labels: issue.labels.into_iter().map(|l| l.name).collect(),
                children: 0,
                in_pr_bundle: false,
                parent_id: None,
                blocked_by_launch: None,
            })
        }
        other => Err(format!("tracker-unknown:{other}")),
    }
}

/// The production range read: the change-scope package's `harness-only`
/// over the range in the checkout, its changed paths written to stdout
/// (`--paths-output`), one per line, ahead of the one line its stdout
/// documents, the verdict `harness_only=true|false`, which is dropped.
pub(super) fn read_range_paths(
    clis: &Clis,
    repo_dir: &Path,
    range: &ScopeRange,
) -> std::result::Result<Vec<String>, ReadFailure> {
    let dir = repo_dir.display().to_string();
    let stdout = read_stdout(
        "harness-only",
        &clis.scope_paths,
        "range-paths",
        &[
            "--event",
            "pull_request",
            "--base",
            &range.base,
            "--head",
            &range.head,
            "--repo",
            &dir,
            "--output",
            "/dev/null",
            "--paths-output",
            "/dev/stdout",
        ],
    )?;
    let text = String::from_utf8(stdout).map_err(|e| format!("range-paths: {e}"))?;
    let mut lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    match lines.pop() {
        Some("harness_only=true" | "harness_only=false") => {}
        other => return Err(format!("range-paths: no verdict line, found {other:?}")),
    }
    Ok(lines.into_iter().map(str::to_owned).collect())
}

/// The label the pull-request reads carry in a `gh` refusal.
const PULLS_READ: &str = "pr-holders";

/// `GET /repos/{owner}/{repo}/pulls` (REST pulls, "Pull Request Simple"):
/// the number alone; the holder is read by it.
#[derive(Deserialize)]
struct PullNumber {
    number: u64,
}

/// `GET /repos/{owner}/{repo}/pulls/{n}`: the fields the holder rule reads,
/// each documented required; `head.repo` documented nullable (a deleted
/// fork).
#[derive(Deserialize)]
struct PullObject {
    state: String,
    changed_files: u64,
    head: PullHead,
}

#[derive(Deserialize)]
struct PullHead {
    #[serde(rename = "ref")]
    branch: String,
    repo: Nullable<PullHeadRepo>,
}

#[derive(Deserialize)]
struct PullHeadRepo {
    full_name: String,
}

/// `GET /repos/{owner}/{repo}/pulls/{n}/files` ("Diff Entry"): `filename`
/// required; `previous_filename` documented optional, a rename's old path.
#[derive(Deserialize)]
struct PullFile {
    filename: String,
    #[serde(default)]
    previous_filename: Optional<String>,
}

/// The `owner/name` GitHub issues, the shared resolver's classes
/// (`github/scripts/lib/gh-repo.sh`): one slash, an owner of alphanumerics
/// and hyphens, a name of alphanumerics, dots, underscores and hyphens
/// that is not dots alone; anything else reaches no `repos/<slug>/` path.
fn checked_slug(text: &str) -> Option<String> {
    let (owner, name) = text.split_once('/')?;
    let owner_ok = !owner.is_empty()
        && owner
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-');
    let name_ok = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        && !name.bytes().all(|b| b == b'.');
    (owner_ok && name_ok).then(|| text.to_owned())
}

/// The `owner/name` an origin URL names on github.com, as the shared
/// resolver's `kendex_github_origin_slug` reads it: github.com where a
/// hostname sits, after an optional scheme and userinfo holding no `/`,
/// then the two segments less a trailing `.git`; a URL mentioning
/// github.com on another host names none.
pub(crate) fn origin_slug(url: &str) -> Option<String> {
    let mut rest = url.trim();
    if let Some((scheme, after)) = rest.split_once("://") {
        let mut chars = scheme.chars();
        let well_formed = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
            && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-'));
        if !well_formed {
            return None;
        }
        rest = after;
    }
    if let Some((user, after)) = rest.split_once('@')
        && !user.contains('/')
    {
        rest = after;
    }
    let rest = rest.strip_prefix("github.com")?;
    if !rest.starts_with([':', '/']) {
        return None;
    }
    let (owner, name) = rest.trim_start_matches([':', '/']).split_once('/')?;
    let name = name.strip_suffix(".git").unwrap_or(name);
    if owner.is_empty() || name.is_empty() || name.contains('/') {
        return None;
    }
    Some(format!("{owner}/{name}"))
}

/// What `gh repo view --json nameWithOwner -q .nameWithOwner` answers in
/// `dir`; `None` for a call that fails or prints nothing, which the origin
/// remote then answers.
#[allow(
    clippy::disallowed_methods,
    reason = "the admission's one gh read in the checkout, for the repository whose pull requests it reads; no effect on a lane or a controller"
)]
fn viewed_repo(clis: &Clis, dir: &Path) -> Option<String> {
    let place = host::Place {
        cwd: Some(dir),
        env: &[],
    };
    let output = host::run_tagged_in(
        TAG,
        "gh",
        &clis.gh,
        "repo-view",
        &[
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "-q",
            ".nameWithOwner",
        ],
        place,
        READ_TIMEOUT,
    )
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = host::stdout_text(&output);
    (!text.is_empty()).then_some(text)
}

/// The GitHub repository of the checkout at `dir`: what `gh repo view`
/// answers in it, else the
/// `owner/name` its `origin` remote names on github.com, judged by the
/// resolver's classes; neither is the failure, `read=repo`.
fn checkout_slug(clis: &Clis, dir: &Path) -> std::result::Result<String, PullsFailure> {
    let place = dir.display().to_string();
    let failed = |cause: String| PullsFailure {
        read: "repo",
        repo: place.clone(),
        cause,
    };
    let candidate = match viewed_repo(clis, dir) {
        Some(viewed) => viewed,
        None => {
            let url = read_stdout(
                "git",
                Path::new("git"),
                "origin-url",
                &["-C", &place, "remote", "get-url", "origin"],
            )
            .map(|out| String::from_utf8_lossy(&out).trim().to_owned())
            .map_err(&failed)?;
            origin_slug(&url).ok_or_else(|| failed(format!("origin-not-github: {url}")))?
        }
    };
    checked_slug(&candidate).ok_or_else(|| failed(format!("slug-form: {candidate}")))
}

/// The production pull-request read: the open same-repository pull
/// requests of the repository the request names, else of the checkout it
/// names ([`checkout_slug`]), `None` where it names neither; their files
/// through the one `gh api` transport: the open list paged to a short
/// page, each pull request read by number for its state, head and
/// `changed_files`, and an open one's files paged to a short page and held
/// to that count, the files endpoint serving at most 3000 files and
/// carrying no total of its own. A closed one, a fork's and a deleted
/// fork's hold nothing and their files are not read. A repository that
/// cannot be named, a failed call, a 404, a member the documented shapes
/// do not decode, a state outside the documented pair or a files list
/// short of its count is the failure, named by read.
fn read_open_pulls(
    clis: &Clis,
    repo: Option<&str>,
    repo_dir: Option<&Path>,
) -> std::result::Result<Option<OpenPulls>, PullsFailure> {
    let slug = match (repo, repo_dir) {
        (Some(named), _) => checked_slug(named).ok_or_else(|| PullsFailure {
            read: "repo",
            repo: named.to_owned(),
            cause: format!("slug-form: {named}"),
        })?,
        (None, Some(dir)) => checkout_slug(clis, dir)?,
        (None, None) => return Ok(None),
    };
    let failed = |read: &'static str, cause: String| PullsFailure {
        read,
        repo: slug.clone(),
        cause,
    };
    let gh = Gh { cli: &clis.gh };
    let repo = slug.to_ascii_lowercase();
    let listed: Vec<PullNumber> = gh
        .list(PULLS_READ, &format!("repos/{repo}/pulls?state=open"))
        .map_err(|e| failed("pulls", e.to_string()))?
        .ok_or_else(|| failed("pulls", "not-found".to_owned()))?;
    let mut out = Vec::new();
    for PullNumber { number } in listed {
        let pull: PullObject = gh
            .object(PULLS_READ, &format!("repos/{repo}/pulls/{number}"))
            .map_err(|e| failed("pull", format!("#{number}: {e}")))?
            .ok_or_else(|| failed("pull", format!("#{number}: not-found")))?;
        let same_repo = match &pull.head.repo {
            Nullable::Present(head) => head.full_name.eq_ignore_ascii_case(&repo),
            Nullable::Absent | Nullable::Null => false,
        };
        match pull.state.as_str() {
            "open" if same_repo => {}
            "open" | "closed" => continue,
            other => return Err(failed("pull", format!("#{number}: state {other:?}"))),
        }
        let files: Vec<PullFile> = gh
            .list(PULLS_READ, &format!("repos/{repo}/pulls/{number}/files"))
            .map_err(|e| failed("files", format!("#{number}: {e}")))?
            .ok_or_else(|| failed("files", format!("#{number}: not-found")))?;
        if files.len() as u64 != pull.changed_files {
            return Err(failed(
                "files",
                format!("#{number}: {} of {} files", files.len(), pull.changed_files),
            ));
        }
        let mut names = Vec::with_capacity(files.len());
        for file in files {
            names.push(file.filename);
            match file.previous_filename {
                Optional::Present(previous) => names.push(previous),
                Optional::Absent => {}
            }
        }
        out.push(OpenPull {
            number,
            branch: pull.head.branch,
            files: names,
        });
    }
    Ok(Some(OpenPulls {
        repo: slug,
        pulls: out,
    }))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows write the brief and fleet fixtures they judge"
)]
#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use agent_runtime::process::Identity;
    use agent_runtime::reading::Reading;
    use serde_json::json;

    use super::super::testing::*;
    use super::*;

    /// A test host whose item reads answer from a planted map and whose
    /// identity reads answer a planted reading per pid.
    struct Planted {
        items: BTreeMap<String, std::result::Result<ItemRead, ReadFailure>>,
        readings: BTreeMap<u32, Reading<Identity>>,
        ranges: Vec<String>,
        reads: RefCell<Vec<String>>,
    }

    impl Planted {
        fn host<'a>(&'a self, still_runs: &'a dyn Fn(&Identity) -> Reading<Identity>) -> Host<'a> {
            Host {
                lane_cap: 4,
                cloud_lane_cap: None,
                still_runs,
                accounts: None,
                admission: Some(AdmissionReads {
                    clis: no_clis(),
                    item: Box::new(|_: &Clis, tracker: &str, item: &str, _: Option<&str>| {
                        self.reads.borrow_mut().push(format!("{tracker}:{item}"));
                        self.items
                            .get(item)
                            .cloned()
                            .unwrap_or_else(|| Err("unplanted".to_owned()))
                    }),
                    range_paths: Box::new(|_: &Clis, _: &Path, _: &ScopeRange| {
                        Ok(self.ranges.clone())
                    }),
                    // No pull request: the process rows read them through
                    // the gh fixture.
                    pulls: Box::new(|_: &Clis, _: Option<&str>, _: Option<&Path>| Ok(None)),
                }),
            }
        }

        /// The identity reader over the planted readings: `Gone` for a
        /// pid not planted.
        fn still_runs(&self) -> impl Fn(&Identity) -> Reading<Identity> + '_ {
            move |id: &Identity| self.readings.get(&id.pid).cloned().unwrap_or(Reading::Gone)
        }
    }

    /// A tracker answer judging no launch blocker, its body naming one
    /// Location.
    fn body(location: &str) -> std::result::Result<ItemRead, ReadFailure> {
        Ok(ItemRead {
            body: format!("Some text.\n**Location**: {location}\nMore.\n"),
            blocked_by_launch: Some(Vec::new()),
            ..ItemRead::default()
        })
    }

    fn holder(item: &str, status: &str, pid: u32, touched: Option<Vec<&str>>) -> Lane {
        let mut doc = json!({
            "item": item,
            "tracker": "linear",
            "status": status,
            "launch": {"pane": "%1", "server": 7, "pid": pid, "start": "ticks:1"},
        });
        if let Some(paths) = touched {
            doc["touched"] = json!(paths);
        }
        serde_json::from_value(doc).unwrap()
    }

    fn admission<'r>(item: &'r str, paths: &'r [String]) -> Admission<'r> {
        Admission {
            item,
            tracker: Some("linear"),
            repo: None,
            brief_file: None,
            repo_dir: None,
            scope_range: None,
            in_scope: &[],
            paths,
        }
    }

    fn fleet_path() -> PathBuf {
        PathBuf::from("/nowhere/workflow-state-oversee.json")
    }

    #[test]
    fn eligibility_is_judged_from_the_body_by_the_container_rule() {
        let item = |children: usize, labels: &[&str], bundle: bool| ItemRead {
            body: String::new(),
            labels: labels.iter().map(|l| (*l).to_owned()).collect(),
            children,
            in_pr_bundle: bundle,
            ..ItemRead::default()
        };
        let rows = [
            (item(0, &[], false), Ok(())),
            (item(2, &[], false), Err("parent-with-children")),
            (item(0, &["agent:multi"], false), Err("agent-multi")),
            (item(0, &["agent:backend"], false), Ok(())),
            (item(2, &["agent:multi"], true), Ok(())),
        ];
        for (read, expected) in rows {
            assert_eq!(eligibility(&read), expected, "{read:?}");
        }
    }

    #[test]
    fn location_lines_are_read_as_the_legacy_read_them() {
        let rows: [(&str, std::result::Result<Vec<&str>, &str>); 8] = [
            ("**Location**: `src/a.sh`", Ok(vec!["src/a.sh"])),
            (
                "* **Location**: `src/a.sh` (the gate)",
                Ok(vec!["src/a.sh"]),
            ),
            (
                "- Location: `src/a.sh`, `src/c.sh`",
                Ok(vec!["src/a.sh", "src/c.sh"]),
            ),
            ("**Location**: `src/a.sh:19-24`", Ok(vec!["src/a.sh"])),
            ("**Location**: `src/a.sh:19`", Ok(vec!["src/a.sh"])),
            ("**Location**: src/a.sh (the gate)", Err("location")),
            ("No location line.", Ok(vec![])),
            ("_Location_:\r\n`a/b`\n**Location**: `c/d`", Ok(vec!["c/d"])),
        ];
        for (body, expected) in rows {
            assert_eq!(
                location_paths(body),
                expected.map(|v| v.into_iter().map(str::to_owned).collect()),
                "{body:?}"
            );
        }
    }

    #[test]
    fn a_brief_names_the_tokens_that_read_as_paths() {
        let brief = "Edit `src/a.sh` and `docs/`. Run `cargo test`, pass `--json`, see \
                     `https://x.y/z`, read `README.md`, line `src/b.rs:12`.";
        assert_eq!(brief_paths(brief), ["src/a.sh", "docs/", "src/b.rs"]);
    }

    #[test]
    fn overlap_meets_files_directories_and_the_scope_as_the_legacy_did() {
        let s = |v: &[&str]| v.iter().map(|x| (*x).to_owned()).collect::<Vec<_>>();
        let rows = [
            (
                s(&["src/a.sh"]),
                s(&["src/a.sh", "x.md"]),
                s(&[]),
                s(&["src/a.sh"]),
            ),
            (s(&["src/a.sh"]), s(&["src/"]), s(&[]), s(&["src/a.sh"])),
            (s(&["src/"]), s(&["src/a.sh"]), s(&[]), s(&["src/a.sh"])),
            (s(&["src/a.sh"]), s(&["src/b.sh"]), s(&[]), s(&[])),
            (
                s(&["changelog.d/orch/", "src/b.sh"]),
                s(&["changelog.d/orch/y.md"]),
                s(&[]),
                s(&[]),
            ),
            (s(&["src/a.sh"]), s(&["src/a.sh"]), s(&["src/"]), s(&[])),
            (
                s(&["src/a.sh"]),
                s(&["src/a.sh"]),
                s(&["docs/"]),
                s(&["src/a.sh"]),
            ),
            (
                s(&["src/a.sh", "src/c.sh"]),
                s(&["src/a.sh", "src/c.sh"]),
                s(&["src/a.sh"]),
                s(&["src/c.sh"]),
            ),
        ];
        for (touched, held, scope, expected) in rows {
            assert_eq!(
                shared(&touched, &held, &scope),
                expected,
                "{touched:?} {held:?}"
            );
        }
    }

    /// The repository the pull requests are read from, as the shared
    /// resolver (`gh-repo.sh`) reads an origin and judges a slug: github.com
    /// where a hostname sits, the two segments less `.git`; a URL naming
    /// github.com on another host, a third segment or a segment GitHub
    /// never issues names none, so nothing unchecked reaches the
    /// `repos/<slug>/` path.
    #[test]
    fn the_repository_slug_is_read_as_the_shared_resolver_reads_it() {
        let origins = [
            ("git@github.com:o/r.git", Some("o/r")),
            ("https://github.com/o/r", Some("o/r")),
            ("https://github.com/o/r.git\n", Some("o/r")),
            ("ssh://git@github.com/o/r.git", Some("o/r")),
            ("https://user:tok@github.com/O/r-x", Some("O/r-x")),
            ("https://gitlab.example/group/github.com/o/r", None),
            ("https://github.com/o/r/extra", None),
            ("https://github.com/o/.git", None),
            ("github.com-mirror/o/r", None),
            ("/srv/origin.git", None),
            ("", None),
        ];
        for (url, expected) in origins {
            assert_eq!(origin_slug(url).as_deref(), expected, "{url:?}");
        }
        let slugs = [
            ("o/r", true),
            ("O/r.x_y-z", true),
            ("./repo", false),
            ("o/..", false),
            ("o/r/s", false),
            ("o r/x", false),
            ("o/", false),
            ("/r", false),
            ("o", false),
        ];
        for (text, ok) in slugs {
            assert_eq!(checked_slug(text).is_some(), ok, "{text:?}");
        }
    }

    /// Decision 165 at the lane: a pull request a record names, by its
    /// `pending_pr` or `parked` number for this repository or by its head
    /// branch (the recorded branch, or the item key, case apart), is that
    /// lane's work and no second holder; a number of another repository or
    /// another branch is not a name.
    #[test]
    fn a_pull_request_is_a_lanes_own_by_the_record_that_names_it() {
        let pull = |number: u64, branch: &str| OpenPull {
            number,
            branch: branch.to_owned(),
            files: vec!["src/a.sh".to_owned()],
        };
        let lane = |record: Value| -> Lane {
            let mut doc = json!({"item": "KEN-S", "status": "stopped"});
            for (key, value) in record.as_object().unwrap() {
                doc[key] = value.clone();
            }
            serde_json::from_value(doc).unwrap()
        };
        /// The record's extra fields, the lane's branch, the pull request
        /// and whether the record names it.
        type Row = (Value, Option<&'static str>, (u64, &'static str), bool);
        let rows: [Row; 9] = [
            (
                json!({"pending_pr": {"repo": "o/r", "pr": 7}}),
                None,
                (7, "feat"),
                true,
            ),
            (
                json!({"pending_pr": {"repo": "O/R", "pr": 7}}),
                None,
                (7, "feat"),
                true,
            ),
            (
                json!({"pending_pr": {"repo": "x/y", "pr": 7}}),
                None,
                (7, "feat"),
                false,
            ),
            (
                json!({"pending_pr": {"repo": "o/r", "pr": 9}}),
                None,
                (7, "feat"),
                false,
            ),
            (json!({"parked": {"pr": 7}}), None, (7, "feat"), true),
            (json!({}), Some("ken-s-work"), (8, "ken-s-work"), true),
            (json!({}), Some("ken-s-work"), (8, "feat"), false),
            (json!({}), None, (8, "KEN-S"), true),
            (json!({}), None, (8, "feat"), false),
        ];
        for (record, branch, (number, head), expected) in rows {
            assert_eq!(
                names_pull(&lane(record.clone()), branch, &pull(number, head), "o/r"),
                expected,
                "{record} {branch:?} #{number} {head}"
            );
        }
    }

    /// Decision 97 at the holder: the holder is judged by its identity
    /// reading, never by its status word, and an unreadable identity
    /// blocks as unknown.
    #[test]
    fn a_holder_is_judged_by_its_identity_reading_never_by_its_status_word() {
        let live = Identity {
            pid: 11,
            start: "ticks:1".into(),
        };
        let planted = Planted {
            items: [("KEN-L".to_owned(), body("`src/a.sh`"))].into(),
            readings: [
                (11, Reading::Live(live)),
                (
                    13,
                    Reading::Unreadable {
                        cause: "permission-denied",
                    },
                ),
            ]
            .into(),
            ranges: Vec::new(),
            reads: RefCell::new(Vec::new()),
        };
        /// A holder's status word and pid, and the judgement: `Ok` yields,
        /// `Err` a refusal key and the field value it names.
        type Row = (
            &'static str,
            u32,
            std::result::Result<&'static str, (&'static str, &'static str)>,
        );
        let rows: [Row; 6] = [
            ("stopped", 11, Err(("launch-overlap", "src/a.sh"))),
            ("running", 11, Err(("launch-overlap", "src/a.sh"))),
            ("running", 12, Ok("yields")),
            ("stopped", 12, Ok("yields")),
            ("parked", 12, Ok("yields")),
            ("running", 13, Err(("holder-unreadable", "identity"))),
        ];
        for (status, pid, expected) in rows {
            let lanes = vec![holder("KEN-H", status, pid, Some(vec!["src/a.sh"]))];
            let judged = judge(
                &fleet_path(),
                &lanes,
                &[],
                &admission("KEN-L", &[]),
                &env(),
                &planted.host(&planted.still_runs()),
            );
            match (judged, expected) {
                (Ok(j), Ok(_)) => {
                    assert_eq!(j.touched, ["src/a.sh"], "{status} {pid}");
                    assert_eq!(j.rebase.len(), 1, "{status} {pid}");
                    assert_eq!(j.rebase[0].holder, "KEN-H");
                    assert_eq!(j.rebase[0].paths, ["src/a.sh"]);
                    assert_eq!(j.rebase[0].branch, None, "no item state stands");
                }
                (Err(e), Err((key, field))) => {
                    assert_eq!(e.key(), key, "{status} {pid}: {e}");
                    assert!(
                        e.fields().iter().any(|(_, v)| v == field),
                        "{status} {pid}: {:?}",
                        e.fields()
                    );
                }
                (other, expected) => panic!("{status} {pid}: {other:?} against {expected:?}"),
            }
        }
        let done = vec![holder("KEN-H", "done", 11, Some(vec!["src/a.sh"]))];
        let judged = judge(
            &fleet_path(),
            &done,
            &[],
            &admission("KEN-L", &[]),
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap();
        assert!(judged.rebase.is_empty(), "a done lane holds nothing");
    }

    /// A holder with no recorded set is read from its item, once, and one
    /// whose item cannot be read blocks; a holder of another repository is
    /// never read.
    #[test]
    fn a_holder_without_a_touched_set_is_read_from_its_item_or_blocks_unread() {
        let planted = Planted {
            items: [
                ("KEN-L".to_owned(), body("`src/a.sh`")),
                ("KEN-H".to_owned(), body("`src/a.sh`")),
                (
                    "KEN-U".to_owned(),
                    Err("issue-read exit 1: refused".to_owned()),
                ),
                ("KEN-T".to_owned(), body("src/a.sh (unticked)")),
            ]
            .into(),
            readings: BTreeMap::new(),
            ranges: Vec::new(),
            reads: RefCell::new(Vec::new()),
        };
        let mut other = holder("KEN-O", "running", 12, None);
        other.repo = Some("o/other".into());
        let lanes = vec![holder("KEN-H", "running", 12, None), other];
        let judged = judge(
            &fleet_path(),
            &lanes,
            &[],
            &admission("KEN-L", &[]),
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap();
        assert_eq!(judged.rebase[0].holder, "KEN-H");
        assert_eq!(
            *planted.reads.borrow(),
            ["linear:KEN-L", "linear:KEN-H"],
            "the other repository's holder is not read"
        );
        for (item, cause) in [("KEN-U", "exit"), ("KEN-T", "location")] {
            let lanes = vec![holder(item, "running", 12, None)];
            let err = judge(
                &fleet_path(),
                &lanes,
                &[],
                &admission("KEN-L", &[]),
                &env(),
                &planted.host(&planted.still_runs()),
            )
            .unwrap_err();
            assert_eq!(err.key(), "holder-unreadable", "{item}");
            assert!(err.to_string().contains(cause), "{item}: {err}");
            assert_eq!(
                err.fields(),
                [
                    ("item".to_owned(), "KEN-L".to_owned()),
                    ("holder".to_owned(), item.to_owned()),
                    ("read".to_owned(), "touched".to_owned())
                ]
            );
        }
    }

    /// Decision 118 (4): the touched set is the union of the Location
    /// paths, the brief's paths, the range's paths and the added paths; a
    /// path only one source names overlaps a holder.
    #[test]
    fn the_touched_set_is_the_union_of_every_source_and_each_alone_overlaps() {
        let dir = tempfile::tempdir().unwrap();
        let brief = dir.path().join("brief.md");
        std::fs::write(&brief, "Change `src/b.sh` under `tools/`.\n").unwrap();
        let planted = Planted {
            items: [("KEN-L".to_owned(), body("`src/a.sh`"))].into(),
            readings: BTreeMap::new(),
            ranges: vec!["src/c.sh".to_owned(), "changelog.d/orch/x.md".to_owned()],
            reads: RefCell::new(Vec::new()),
        };
        let range = ScopeRange {
            base: "main".into(),
            head: "HEAD".into(),
        };
        let added = ["src/d.sh".to_owned()];
        let full = Admission {
            brief_file: Some(&brief),
            repo_dir: Some(dir.path()),
            scope_range: Some(&range),
            paths: &added,
            ..admission("KEN-L", &[])
        };
        let judged = judge(
            &fleet_path(),
            &[],
            &[],
            &full,
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap();
        assert_eq!(
            judged.touched,
            ["src/a.sh", "src/b.sh", "src/c.sh", "src/d.sh", "tools/"]
        );
        for held in ["src/a.sh", "src/b.sh", "src/c.sh", "src/d.sh", "tools/x"] {
            let lanes = vec![holder("KEN-H", "running", 12, Some(vec![held]))];
            let judged = judge(
                &fleet_path(),
                &lanes,
                &[],
                &full,
                &env(),
                &planted.host(&planted.still_runs()),
            )
            .unwrap();
            assert_eq!(judged.rebase.len(), 1, "{held} overlaps");
        }
        let no_range = Admission {
            scope_range: Some(&range),
            repo_dir: None,
            ..admission("KEN-L", &[])
        };
        let err = judge(
            &fleet_path(),
            &[],
            &[],
            &no_range,
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap_err();
        assert_eq!(err.key(), "touched-unreadable");
        assert_eq!(err.fields()[1].1, "classification");
    }

    /// Decision 118 (6): a container is refused from its body with nothing
    /// written; a launch naming no tracker reads no item.
    #[test]
    fn an_ineligible_item_is_refused_and_an_untracked_launch_reads_nothing() {
        let planted = Planted {
            items: [(
                "KEN-C".to_owned(),
                Ok(ItemRead {
                    children: 2,
                    ..ItemRead::default()
                }),
            )]
            .into(),
            readings: BTreeMap::new(),
            ranges: Vec::new(),
            reads: RefCell::new(Vec::new()),
        };
        let err = judge(
            &fleet_path(),
            &[],
            &[],
            &admission("KEN-C", &[]),
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap_err();
        assert_eq!(err.key(), "item-ineligible");
        assert_eq!(err.fields()[1].1, "parent-with-children");
        let untracked = Admission {
            tracker: None,
            ..admission("KEN-C", &[])
        };
        let judged = judge(
            &fleet_path(),
            &[],
            &[],
            &untracked,
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap();
        assert!(judged.touched.is_empty());
        assert_eq!(
            *planted.reads.borrow(),
            ["linear:KEN-C"],
            "one read, the refused one"
        );
    }

    /// Decision 142 (4): a running lane's added path is judged against the
    /// holders and widens its record, or is refused by a live holder with
    /// the record untouched; a done lane refuses.
    #[test]
    fn a_running_lanes_added_path_widens_its_record_or_is_refused_by_a_live_holder() {
        let dir = tempfile::tempdir().unwrap();
        let path = fleet_file(dir.path());
        let live = Identity {
            pid: 11,
            start: "ticks:1".into(),
        };
        let planted = Planted {
            items: BTreeMap::new(),
            readings: [(11, Reading::Live(live))].into(),
            ranges: Vec::new(),
            reads: RefCell::new(Vec::new()),
        };
        let mut doc = object(&path);
        doc["lanes"] = json!([
            {"item": "KEN-L", "status": "running", "touched": ["src/a.sh"], "in_scope": ["docs/"],
             "rebase": [{"holder": "KEN-S", "branch": "ken-s", "paths": ["src/a.sh"], "at": "2026-01-01T00:00:00Z"}]},
            {"item": "KEN-S", "status": "stopped", "touched": ["src/a.sh", "src/b.sh"],
             "launch": {"pane": "%1", "server": 7, "pid": 12, "start": "ticks:1"}},
            {"item": "KEN-H", "status": "running", "touched": ["src/c.sh"],
             "launch": {"pane": "%1", "server": 7, "pid": 11, "start": "ticks:1"}},
            {"item": "KEN-D", "status": "done", "touched": []},
        ]);
        let request = |paths: &[&str]| AdmitPaths {
            item: "KEN-L".into(),
            tracker: None,
            repo: None,
            paths: paths.iter().map(|p| (*p).to_owned()).collect(),
            brief_file: None,
            repo_dir: None,
            scope_range: None,
            in_scope: Vec::new(),
        };
        let admitted = admit_paths(
            &path,
            &mut doc,
            &request(&["src/b.sh"]),
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap();
        assert!(admitted.recorded);
        assert_eq!(admitted.touched, ["src/a.sh", "src/b.sh"]);
        assert_eq!(admitted.in_scope, ["docs/"]);
        assert_eq!(admitted.rebase.len(), 1, "one holder, its paths joined");
        assert_eq!(admitted.rebase[0].paths, ["src/a.sh", "src/b.sh"]);
        assert_eq!(
            admitted.rebase[0].at, "2026-01-01T00:00:00Z",
            "the first stamp stands"
        );
        let lane = admitted.lane.unwrap();
        assert_eq!(
            lane.touched.as_deref(),
            Some(&["src/a.sh".to_owned(), "src/b.sh".to_owned()][..])
        );
        assert_eq!(doc["lanes"][0]["touched"], json!(["src/a.sh", "src/b.sh"]));

        let before = doc.clone();
        let err = admit_paths(
            &path,
            &mut doc,
            &request(&["src/c.sh"]),
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap_err();
        assert_eq!(err.key(), "launch-overlap");
        assert_eq!(err.fields()[2].1, "KEN-H");
        assert_eq!(doc, before, "a refusal writes nothing");

        let unrecorded = admit_paths(
            &path,
            &mut doc,
            &AdmitPaths {
                item: "KEN-N".into(),
                ..request(&["src/z.sh"])
            },
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap();
        assert!(!unrecorded.recorded);
        assert_eq!(unrecorded.touched, ["src/z.sh"]);
        assert_eq!(doc, before, "no record, nothing written");

        let err = admit_paths(
            &path,
            &mut doc,
            &AdmitPaths {
                item: "KEN-D".into(),
                ..request(&["src/z.sh"])
            },
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap_err();
        assert_eq!(err.key(), "lane-done");
    }
}
