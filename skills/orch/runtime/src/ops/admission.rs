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
//! transport (`verify::Gh`, the `gh` on `PATH`). Open yields, a
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
//!
//! A launch is bound before its item is read: its checkout (`mail_root`)
//! is of the fleet's repository, the one the fleet file sits in, by git
//! common directory or by the `owner/name` both origins name, or of one
//! the fleet's `ORCH_CONNECTED_REPOS` lists; any other refuses
//! `overseer-foreign`, and a binding that cannot be read `overseer-unjudged`.
//! A fleet file in no checkout names no repository and binds every launch
//! as its own. A relaunch is bound the same way, on its request's checkout
//! and its effective tracker and repository (the request's, else the
//! record's); the rest of its judgement stands from its first admission. A `github` item of another repository than the checkout's,
//! or a `linear` item of another team than the fleet's `LINEAR_TEAM` on
//! the fleet's own repository, refuses `item-foreign`, and a repository or
//! team that cannot be resolved `item-repo-unresolved`.

use agent_runtime::record::{self, Document};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::occupancy::{self, ChargeReason, Host};
use super::{lane_at, lane_doc_mut, lanes};
use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::state::{self, Lane, LaneStatus, RebaseObligation};
use crate::verify::wire::{Nullable, Optional, Pull, PullFile};
use crate::verify::{Answer, Gh};
use agent_runtime::intent::Intent;
use agent_runtime::journal::{Env, intents};

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
    /// The github package's repository resolver ([`crate::repo::resolver`]).
    pub resolver: PathBuf,
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

/// The repository a directory sits in, as git names it: its common
/// directory, resolved, and the `owner/name` its `origin` names on
/// github.com, where it names one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Repository {
    pub root: PathBuf,
    pub slug: Option<String>,
}

/// The repository of a directory, `None` for one in no checkout.
pub(super) type CheckoutReader<'a> =
    Box<dyn Fn(&Clis, &Path) -> std::result::Result<Option<Repository>, ReadFailure> + 'a>;

/// The key of the Linear team a key or name names, through the tracker.
pub(super) type TeamReader<'a> =
    Box<dyn Fn(&Clis, &str) -> std::result::Result<String, ReadFailure> + 'a>;

/// The cycle change-scope's launch arm answers, in the checkout, for a
/// requested cycle taken as a floor over the touched paths.
pub(super) type TierReader<'a> = Box<
    dyn Fn(
            &Clis,
            &str,
            &[String],
            &Path,
        ) -> std::result::Result<super::tier::Classified, super::tier::Refused>
        + 'a,
>;

/// The admission's reads a host carries: the programs and the readers
/// over them. A host built without them (the effect and duty
/// entries, which launch no lane) judges a launch that names a source as
/// `touched-unreadable`.
pub(super) struct AdmissionReads<'a> {
    pub clis: Clis,
    pub item: ItemReader<'a>,
    pub range_paths: RangeReader<'a>,
    pub pulls: PullsReader<'a>,
    pub checkout: CheckoutReader<'a>,
    pub team_key: TeamReader<'a>,
    pub tier: TierReader<'a>,
}

impl AdmissionReads<'static> {
    /// The production reads through the named programs.
    pub(super) fn through(clis: Clis) -> AdmissionReads<'static> {
        AdmissionReads {
            clis,
            item: Box::new(read_item),
            range_paths: Box::new(read_range_paths),
            pulls: Box::new(read_open_pulls),
            checkout: Box::new(read_checkout),
            team_key: Box::new(read_team_key),
            tier: Box::new(read_tier),
        }
    }
}

fn read_tier(
    clis: &Clis,
    requested: &str,
    paths: &[String],
    dir: &Path,
) -> std::result::Result<super::tier::Classified, super::tier::Refused> {
    super::tier::classify(
        &super::tier::arm_cli(&clis.scope_paths),
        &super::tier::ArmInput {
            floors: &[requested],
            paths,
            repo: Some(dir),
            ..super::tier::ArmInput::default()
        },
    )
}

/// A first launch's requested cycle judged over its touched set by the arm
/// the `tier` verb runs: a brief that requests a cycle narrower than the one
/// its touched set earns refuses the launch, naming both; an arm that could
/// not answer refuses it too, since an unjudged cycle grants nothing. A
/// standard request is the widest cycle, which no touched set can widen.
pub(super) fn tier_judged(
    item: &str,
    requested: &str,
    touched: &[String],
    dir: &Path,
    host: &Host,
) -> Result<()> {
    if touched.is_empty() || requested == super::tier::Cycle::Standard.word() {
        return Ok(());
    }
    let unjudged = |cause: &str| {
        Error::from(agent_runtime::Error::refused(
            "tier-unjudged",
            &[("item", item), ("requested", requested), ("cause", cause)],
        ))
    };
    let reads = host
        .admission
        .as_ref()
        .ok_or_else(|| unjudged("admission-reads-unavailable"))?;
    let judged =
        (reads.tier)(&reads.clis, requested, touched, dir).map_err(|r| unjudged(&r.cause))?;
    if judged.cycle.word() == requested {
        return Ok(());
    }
    let cause = judged.cause.split(' ').next().unwrap_or_default();
    Err(Error::from(agent_runtime::Error::refused(
        "tier-narrower",
        &[
            ("item", item),
            ("requested", requested),
            ("judged", judged.cycle.word()),
            ("cause", cause),
        ],
    )))
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
    /// The checkout a launch runs in, bound to the fleet's repository
    /// before anything is read; `None` for paths a running lane adds,
    /// bound when it was admitted.
    pub checkout: Option<&'r Path>,
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
pub(super) fn is_location_line(line: &str) -> bool {
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

/// The touched set: the body's Location paths, the brief's paths, the
/// range's changed paths and the paths added, `changelog.d/` left out,
/// sorted and once each. The admission judges holders over it and the tier
/// classifies it, so both read one set from the same inputs. A Location line
/// naming no path is unread (`location`).
pub(super) fn touched(
    body: Option<&str>,
    brief: Option<&str>,
    range: &[String],
    added: &[String],
) -> std::result::Result<Vec<String>, &'static str> {
    let mut touched: BTreeSet<String> = BTreeSet::new();
    if let Some(body) = body {
        touched.extend(location_paths(body)?);
    }
    if let Some(brief) = brief {
        touched.extend(brief_paths(brief));
    }
    touched.extend(range.iter().chain(added).cloned());
    touched.retain(|p| !p.is_empty() && !p.starts_with(UNCOUNTED_PREFIX));
    Ok(touched.into_iter().collect())
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
        Some((ChargeReason::Reservation | ChargeReason::Sandbox, _)) | None => Holding::Yields,
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

/// How a launch's checkout stands to the fleet's repository.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Binding {
    /// The fleet's own repository, or any, where the fleet names none.
    Own,
    /// A repository the fleet's `ORCH_CONNECTED_REPOS` lists.
    Connected,
}

/// The binding refusal for an unread input, naming the cause and where.
fn unjudged(cause: &str, at: &Path) -> Error {
    Error::from(agent_runtime::Error::refused(
        "overseer-unjudged",
        &[("cause", cause), ("path", &at.display().to_string())],
    ))
}

fn unresolved(fields: &[(&str, &str)]) -> Error {
    Error::from(agent_runtime::Error::refused(
        "item-repo-unresolved",
        fields,
    ))
}

fn item_foreign(repo: &str) -> Error {
    Error::from(agent_runtime::Error::refused(
        "item-foreign",
        &[("repo", repo), ("route", "peer-mail")],
    ))
}

/// The launch bound to the fleet's repository and its item to the
/// checkout's (the module's binding paragraph). `settings` are the
/// fleet's, which name its connected repositories and its team; a host
/// built without them reads none, so a checkout of another repository
/// is unjudged and a `linear` item is judged on no team. On a connected
/// binding a `linear` item's team is the connected checkout's setting,
/// which the fleet's settings do not carry: the binding is the gate there.
fn bind(
    path: &Path,
    a: &Admission,
    checkout: &Path,
    reads: &AdmissionReads,
    settings: Option<&Settings>,
) -> Result<()> {
    let fleet_dir = path.parent().unwrap_or(Path::new("/"));
    let fleet = (reads.checkout)(&reads.clis, fleet_dir)
        .map_err(|_| unjudged("overseer-root", fleet_dir))?;
    let binding = match fleet {
        None => Binding::Own,
        Some(fleet) => {
            let launch = (reads.checkout)(&reads.clis, checkout)
                .ok()
                .flatten()
                .ok_or_else(|| unjudged("checkout-root", checkout))?;
            let same_slug = match (&launch.slug, &fleet.slug) {
                (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
                _ => false,
            };
            if launch.root == fleet.root || same_slug {
                Binding::Own
            } else {
                let connected = &settings
                    .ok_or_else(|| unjudged("setting", fleet_dir))?
                    .reads
                    .connected_repos;
                match &launch.slug {
                    Some(slug) if connected.contains(&slug.to_ascii_lowercase()) => {
                        Binding::Connected
                    }
                    None if !connected.is_empty() => return Err(unjudged("origin", checkout)),
                    Some(_) | None => {
                        let named = |repo: &Repository| {
                            repo.slug
                                .clone()
                                .unwrap_or_else(|| repo.root.display().to_string())
                        };
                        return Err(Error::from(agent_runtime::Error::refused(
                            "overseer-foreign",
                            &[
                                ("item", a.item),
                                ("repo", &named(&launch)),
                                ("overseer", &named(&fleet)),
                                ("route", "connected-repos,peer-mail"),
                            ],
                        )));
                    }
                }
            }
        }
    };
    match (a.tracker, a.repo) {
        (Some("github"), Some(repo)) => {
            let own = crate::repo::of(&reads.clis.resolver, checkout)
                .map_err(|_| unresolved(&[("tracker", "github")]))?;
            if !own.eq_ignore_ascii_case(repo) {
                return Err(item_foreign(repo));
            }
        }
        (Some("linear"), _) if binding == Binding::Own => {
            let Some(team) = settings.and_then(|s| s.linear_team.as_deref()) else {
                return Ok(());
            };
            let key = (reads.team_key)(&reads.clis, team)
                .map_err(|_| unresolved(&[("tracker", "linear"), ("team", team)]))?;
            let prefix = a.item.rsplit_once('-').map_or(a.item, |(prefix, _)| prefix);
            if !prefix.eq_ignore_ascii_case(&key) {
                return Err(item_foreign(prefix));
            }
        }
        _ => {}
    }
    Ok(())
}

/// The binding alone (the module's binding paragraph): a first launch's,
/// inside the judgement, and a relaunch's, whose touched set, Ancestor gate
/// and rebase set were judged when it was first admitted but whose checkout,
/// tracker and repository the request may change.
pub(super) fn bound(
    path: &Path,
    item: &str,
    tracker: Option<&str>,
    repo: Option<&str>,
    checkout: &Path,
    host: &Host,
) -> Result<()> {
    let reads = host
        .admission
        .as_ref()
        .ok_or_else(|| unjudged("admission-reads-unavailable", checkout))?;
    let a = Admission {
        item,
        tracker,
        repo,
        brief_file: None,
        repo_dir: None,
        scope_range: None,
        in_scope: &[],
        paths: &[],
        checkout: Some(checkout),
    };
    bind(path, &a, checkout, reads, host.accounts)
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
    if let Some(checkout) = a.checkout {
        bound(path, a.item, a.tracker, a.repo, checkout, host)?;
    }
    let mut body = None;
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
        location_paths(&item.body).map_err(|c| unreadable("location", c.into()))?;
        body = Some(item.body);
    }
    let brief = a
        .brief_file
        .map(|brief| std::fs::read_to_string(brief).map_err(|e| unreadable("brief", e.to_string())))
        .transpose()?;
    let mut range_paths = Vec::new();
    if let Some(range) = a.scope_range {
        let reads = reads("classification")?;
        let dir = a
            .repo_dir
            .ok_or_else(|| unreadable("classification", "repo-dir-unnamed".to_owned()))?;
        range_paths = (reads.range_paths)(&reads.clis, dir, range)
            .map_err(|c| unreadable("classification", c))?;
    }
    let touched = touched(body.as_deref(), brief.as_deref(), &range_paths, a.paths)
        .map_err(|c| unreadable("location", c.into()))?;
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
                // A `github` item's own pull request: issue and pull request
                // numbers share one sequence per repository, so the pull
                // request numbered as the item is the item (a review lane).
                let own = pull.branch.eq_ignore_ascii_case(a.item)
                    || own_branch.as_deref() == Some(pull.branch.as_str())
                    || (a.tracker == Some("github")
                        && a.item.strip_prefix("issue-") == Some(pull.number.to_string().as_str()));
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
    record::set(lane, "touched", serde_json::to_value(&judged.touched)?);
    record::set(lane, "in_scope", serde_json::to_value(&judged.in_scope)?);
    if judged.rebase.is_empty() {
        record::delete(lane, "rebase");
    } else {
        record::set(lane, "rebase", serde_json::to_value(&judged.rebase)?);
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
            checkout: None,
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
fn first_line(stderr: &str) -> String {
    stderr
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
        return Err(format!(
            "{read} {}: {}",
            output.status,
            first_line(&host::stderr_text(&output))
        ));
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
            let read = "issue-view";
            let answer = Gh::new(&clis.gh)
                .tagged(TAG)
                .run(
                    read,
                    &[
                        "issue",
                        "view",
                        number,
                        "--repo",
                        repo,
                        "--json",
                        "body,labels",
                    ],
                    None,
                )
                .map_err(|unrun| unrun.detail())?;
            let stdout = match answer {
                Answer::Printed { stdout, .. } => stdout,
                Answer::Failed(failed) => {
                    return Err(format!(
                        "{read} {}: {}",
                        failed.status,
                        first_line(&failed.stderr)
                    ));
                }
            };
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

/// The production checkout read: git's common directory for `dir`,
/// resolved, and the `owner/name` its `origin` names ([`crate::repo::origin`]),
/// `None` where it has no origin or one off github.com; `None` for a
/// directory git reads as in no repository, and any other failure of git (a
/// directory that does not stand, a repository git cannot read) or of the
/// resolver the cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the admission's reads of a checkout's repository through the one runner; they act on nothing"
)]
fn read_checkout(clis: &Clis, dir: &Path) -> std::result::Result<Option<Repository>, ReadFailure> {
    let place = dir.display().to_string();
    // git's "not a git repository" is read by its words, which a translated
    // git words otherwise: the C locale outranks `LANGUAGE` too.
    let c_locale = [("LC_ALL", std::ffi::OsStr::new("C"))];
    let output = host::run_tagged_in(
        TAG,
        "git",
        Path::new("git"),
        "common-dir",
        &[
            "-C",
            &place,
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        host::Place {
            cwd: None,
            env: &c_locale,
        },
        READ_TIMEOUT,
    )
    .map_err(|e| e.to_string())?;
    if !output.status.success() {
        if host::stderr_text(&output).starts_with("fatal: not a git repository") {
            return Ok(None);
        }
        return Err(format!(
            "common-dir {}: {}",
            output.status,
            first_line(&host::stderr_text(&output))
        ));
    }
    let common = host::stdout_text(&output);
    let root = std::fs::canonicalize(&common).map_err(|e| format!("common-dir {common}: {e}"))?;
    let slug = match crate::repo::origin(&clis.resolver, dir) {
        Ok(slug) => Some(slug),
        Err(crate::repo::Unread::Unresolved) => None,
        Err(unread) => return Err(format!("origin {unread}")),
    };
    Ok(Some(Repository { root, slug }))
}

/// `teams get TEAM --format=safe` (`lib/formatters.sh`
/// `format_team_single`): the team's key, which prefixes its items'
/// identifiers.
#[derive(Deserialize)]
struct LinearTeam {
    key: String,
}

/// The production team read: the key the linear CLI answers for a team
/// key or name; an answer with no key is the failure.
fn read_team_key(clis: &Clis, team: &str) -> std::result::Result<String, ReadFailure> {
    let stdout = read_stdout(
        "linear",
        &clis.tracker,
        "team-read",
        &["teams", "get", team, "--format=safe"],
    )?;
    let read: LinearTeam =
        serde_json::from_slice(&stdout).map_err(|e| format!("team-read: {e}"))?;
    Some(read.key)
        .filter(|key| !key.is_empty())
        .ok_or_else(|| "team-read: key-empty".to_owned())
}

/// The production pull-request read: the open same-repository pull
/// requests of the repository the request names, else of the checkout it
/// names ([`crate::repo::of`]), `None` where it names neither; their files
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
        (Some(named), _) => {
            crate::verify::validate_repo(named).map_err(|_| PullsFailure {
                read: "repo",
                repo: named.to_owned(),
                cause: format!("slug-form: {named}"),
            })?;
            named.to_owned()
        }
        (None, Some(dir)) => {
            crate::repo::of(&clis.resolver, dir).map_err(|unread| PullsFailure {
                read: "repo",
                repo: dir.display().to_string(),
                cause: unread.to_string(),
            })?
        }
        (None, None) => return Ok(None),
    };
    let failed = |read: &'static str, cause: String| PullsFailure {
        read,
        repo: slug.clone(),
        cause,
    };
    let gh = crate::watch::github::handle(&clis.gh);
    let repo = slug.to_ascii_lowercase();
    let listed: Vec<Pull> = gh
        .list(PULLS_READ, &format!("repos/{repo}/pulls?state=open"))
        .map_err(|e| failed("pulls", e.to_string()))?
        .ok_or_else(|| failed("pulls", "not-found".to_owned()))?;
    let mut out = Vec::new();
    for number in listed.iter().map(|pull| pull.number) {
        let pull: Pull = gh
            .object(PULLS_READ, &format!("repos/{repo}/pulls/{number}"))
            .map_err(|e| failed("pull", format!("#{number}: {e}")))?
            .ok_or_else(|| failed("pull", format!("#{number}: not-found")))?;
        // The got form documents its file count; a pull without one cannot
        // prove its files whole.
        let Optional::Present(changed_files) = pull.changed_files else {
            return Err(failed("pull", format!("#{number}: changed_files absent")));
        };
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
        if files.len() as u64 != changed_files {
            return Err(failed(
                "files",
                format!("#{number}: {} of {changed_files} files", files.len()),
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
                lane_cap: Some(agent_runtime::settings::Judged { read: Ok(4) }),
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
                    checkout: Box::new(|_: &Clis, _: &Path| Ok(None)),
                    team_key: Box::new(|_: &Clis, _: &str| Err("unplanted".to_owned())),
                    tier: as_requested(),
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
            checkout: None,
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
    fn location_lines_are_read_into_their_paths() {
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
    fn overlap_meets_files_directories_and_the_scope() {
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

    /// At the lane: a pull request a record names, by its
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

    /// At the holder: the holder is judged by its identity
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

    /// The touched set is the union of the Location
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

    /// A container is refused from its body with nothing
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
}
