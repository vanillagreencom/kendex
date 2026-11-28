//! Admission judges a writable set against the fleet's claims in the
//! effective repository. An admitted attempt protects its paths from
//! preparation through close and, where exclusively authorized, recovery.
//! Confirmed park, terminal close and proven launch failure release that
//! attempt's authority. A destination launch can protect a second set until
//! it settles while the source's retained claim stays in place.
//!
//! Only an active writer before review can receive a join. Direct delivery
//! can admit a later writer beside a writer in review, with the earlier
//! writer retaining recovery precedence. A read-only lane holds no paths
//! and accepts no join. Legacy writers use their writable Location when
//! their record has no set. Changelog fragments and proven request-side
//! append-only exceptions follow the same path matching at every entry.
//!
//! A holder a first launch would join is in its review where it owns an
//! open pull request of the item's repository: one its record names by its
//! `pending_pr` or `parked` number, or by its head branch (the lane's
//! recorded branch, or its item key); the join then refuses by its tie.
//! An open pull request owned by neither the candidate (its branch, key,
//! issue number or a body line `Closes` naming it) nor a fleet lane holds
//! its changed paths against a first launch: `launch-overlap holder=#N`.
//! The open pull requests are read once after the lanes through `verify::Gh`
//! where a join stands or a first launch names touched paths. Closed, merged
//! and forked pull requests hold nothing. An unread or incomplete inventory
//! blocks `holders-unreadable`. They are read of the repository
//! the request names, else of the checkout it names (`repo_dir`, the
//! fleet's own repository, whose lane records name none): the slug `gh repo
//! view` answers in the checkout, else the one its `origin` remote names on
//! github.com; a checkout naming no GitHub repository blocks
//! `holders-unreadable read=repo`. A request naming neither reads none.
//!
//! The item's body is read only where the request names its tracker: a
//! launch that names none is judged on the sources it does name. A writing
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
//! record's). Its touched set, scope and Ancestor gate stand from its first
//! admission, and that set meets the holders standing now as a running
//! lane's added path does ([`relaunch_held`]). A `github` item of another repository than the checkout's,
//! or a `linear` item of another team than the fleet's `LINEAR_TEAM` on
//! the fleet's own repository, refuses `item-foreign`, and a repository or
//! team that cannot be resolved `item-repo-unresolved`.

use agent_runtime::confine::{self, Answer as Confinement};
use agent_runtime::harness::Harness;
use agent_runtime::intent::{EffectOp, Intent};
use agent_runtime::record::{self, Document};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::occupancy::{self, ChargeReason, Host};
use super::{lane_at, lane_doc_mut, lanes};
use crate::error::{Error, Result};
use crate::settings::{Delivery, Settings};
use crate::state::{self, Carried, FileClaim, FileHold, Lane, LaneMembers, LaneStatus, StageKind};
use crate::verify::wire::{Nullable, Pull, PullFile};
use crate::verify::{Answer, Gh};
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
    /// The orch package's scripts directory, which a provider read carries
    /// ([`crate::watch::overseer::scripts_dir`]).
    pub scripts: PathBuf,
}

/// Why a read answered nothing: the cause the refusal carries.
pub type ReadFailure = String;

/// One open same-repository pull request: what names it a lane's own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct OpenPull {
    pub number: u64,
    /// Its head branch, `head.ref`.
    pub branch: String,
    pub body: Nullable<String>,
    /// The detail's count, used to check the completeness of its files list.
    changed_files: Option<u64>,
}

/// The open pull requests of one repository, with the `owner/name` they
/// were read from.
pub(super) struct OpenPulls {
    pub repo: String,
    pub pulls: Vec<OpenPull>,
}

/// Why the pull requests could not be read: which read (`repo`, `pulls`,
/// `pull`), the repository as named (the slug, or the checkout it
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

/// Why a hosted holder's branch could not be judged: the branch, where the
/// read reached it, and the cause, a stable key first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct BranchUnread {
    pub branch: Option<String>,
    pub cause: String,
}

/// A hosted holder's head as its host reads it, and the paths that commit
/// changes that the repository's default branch does not hold: its
/// unmerged change, both sides of a rename.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct BranchChange {
    pub branch: String,
    pub head: String,
    pub files: Vec<String>,
}

/// The hosted holder's unmerged change ([`BranchChange`]).
pub(super) type BranchReader<'a> =
    Box<dyn Fn(&Clis, &Lane) -> std::result::Result<BranchChange, BranchUnread> + 'a>;

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
    pub branch: BranchReader<'a>,
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
            range_paths: Box::new(|clis: &Clis, dir: &Path, range: &ScopeRange| {
                read_range_paths(&clis.scope_paths, dir, range)
            }),
            pulls: Box::new(read_open_pulls),
            branch: Box::new(read_branch_change),
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
    let Some(judged) = wider_cycle(item, requested, touched, dir, host)? else {
        return Ok(());
    };
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

/// The cycle the tier arm judges over `touched` where it is wider than
/// `requested`, `None` where `requested` stands; an arm that could not
/// answer refuses `tier-unjudged`.
fn wider_cycle(
    item: &str,
    requested: &str,
    touched: &[String],
    dir: &Path,
    host: &Host,
) -> Result<Option<super::tier::Classified>> {
    if touched.is_empty() || requested == super::tier::Cycle::Standard.word() {
        return Ok(None);
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
    Ok((judged.cycle.word() != requested).then_some(judged))
}

/// Judge the paths a lane adds within its item's outcome, or a launch
/// before any record stands. The
/// touched set judged is the union of the sources the request names and
/// `paths`; where a lane record stands, it is widened by that set, and a
/// lane record reading `done` refuses.
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
    pub launch: Launch<'r>,
    /// The lane changes no repository file, as its launch enforces: it
    /// touches no path and is not held on its item's launch blockers.
    pub read_only: bool,
}

/// What the judged set is to the fleet, which decides what a live holder
/// of a shared path does to it.
#[derive(Debug, Clone, Copy)]
pub(super) enum Launch<'r> {
    /// A first launch, from the checkout it runs in, bound to the fleet's
    /// repository before anything is read: it may join a live holder.
    First(&'r Path),
    /// Native surface preparation does the first launch checks and opens its own writer.
    Surface(&'r Path),
    /// A recorded lane's relaunch, bound on its own ([`bound`]): it carries
    /// its own record's work, so it never joins another lane.
    Relaunch,
    /// Paths a running lane adds, bound when it was admitted.
    Added,
}

impl<'r> Admission<'r> {
    /// The checkout a first launch runs in; none for any other judgement.
    fn checkout(&self) -> Option<&'r Path> {
        match self.launch {
            Launch::First(checkout) | Launch::Surface(checkout) => Some(checkout),
            Launch::Relaunch | Launch::Added => None,
        }
    }
}

/// What the judge answers when it admits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Judged {
    /// The paths the lane holds: its sources', none for a read-only lane.
    pub touched: Vec<String>,
    /// The sources' paths the tier classifies, whatever the lane writes.
    pub classified: Vec<String>,
    pub in_scope: Vec<String>,
    /// The running lane a first launch joins in place of opening its own.
    pub join: Option<Join>,
    /// The launch checkout's canonical common git folder, as the binding
    /// read it; `None` where no checkout was read.
    pub binding: CheckoutBinding,
    pub hold: FileHold,
}

/// A live holder before its review that a first launch ships with, at its
/// index among the judged lanes, and what tied them: a shared path, or the
/// candidate's launch blockers the holder carries. The tie is the refusal
/// the launch answers where the holder turns out to own a pull request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Join {
    pub holder: usize,
    tie: Tie,
    paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tie {
    File(String),
    Blockers(Vec<String>),
}

impl Tie {
    /// The field a refusal names the tie by, so the overseer sees what
    /// holds the launch without searching the fleet for it.
    fn field(&self) -> (&'static str, String) {
        match self {
            Tie::File(file) => ("file", file.clone()),
            Tie::Blockers(blockers) => ("blockers", blockers.join(",")),
        }
    }
}

/// The `join-unreachable` refusal of `item` by a holder whose stage and
/// mailbox are on its host (`route`): the tie, the holder and the route,
/// then whatever the head verdict adds.
fn join_unreachable(
    item: &str,
    tie: &Tie,
    holder: &str,
    route: &str,
    verdict: &[(&str, &str)],
) -> Error {
    let (key, value) = tie.field();
    let mut fields = vec![
        ("item", item),
        (key, value.as_str()),
        ("holder", holder),
        ("route", route),
    ];
    fields.extend_from_slice(verdict);
    Error::from(agent_runtime::Error::refused("join-unreachable", &fields))
}

impl Join {
    fn refusal(&self, item: &str, holder: &str) -> Error {
        match &self.tie {
            Tie::File(file) => Error::LaunchOverlap {
                item: item.to_owned(),
                file: file.clone(),
                holder: holder.to_owned(),
            },
            Tie::Blockers(blockers) => Error::LaunchBlocked {
                item: item.to_owned(),
                blockers: blockers.clone(),
            },
        }
    }
}

/// Paths the overlap never counts: the changelog fragments every lane
/// adds beside its own.
const UNCOUNTED_PREFIX: &str = "changelog.d/";

/// One node of a `parent_id` chain as a walk reads it: its launch
/// blockers (`None` where its read carries no such field) and its parent.
pub(crate) struct ChainNode {
    pub blocked_by_launch: Option<Vec<String>>,
    pub parent_id: Option<String>,
}

/// A chain read to its end: the launch blockers of the item and every
/// ancestor reached, and those ancestors, nearest first.
pub(crate) struct Chain {
    pub blockers: BTreeSet<String>,
    pub ancestors: Vec<String>,
}

/// The chain above `item`, whose own node is `first`, each ancestor read
/// through `read`. `Ok(None)` from `read` ends the chain at a node its
/// reader does not hold. A node with no launch-blocker field, a parent the
/// walk already read, or a failed read refuses `(node, cause)`.
pub(crate) fn chain(
    item: &str,
    first: ChainNode,
    mut read: impl FnMut(&str) -> std::result::Result<Option<ChainNode>, ReadFailure>,
) -> std::result::Result<Chain, (String, String)> {
    let mut blockers: BTreeSet<String> = BTreeSet::new();
    let mut ancestors = Vec::new();
    let mut seen: BTreeSet<String> = [item.to_owned()].into();
    let mut current = first;
    let mut current_id = item.to_owned();
    loop {
        match current.blocked_by_launch {
            Some(judged) => blockers.extend(judged),
            None => return Err((current_id, "blocked-by-launch-missing".to_owned())),
        }
        let Some(parent) = current.parent_id.filter(|p| !p.is_empty()) else {
            break;
        };
        if !seen.insert(parent.clone()) {
            return Err((parent, "chain-repeats".to_owned()));
        }
        current = match read(&parent).map_err(|cause| (parent.clone(), cause))? {
            Some(node) => node,
            None => break,
        };
        ancestors.push(parent.clone());
        current_id = parent;
    }
    Ok(Chain {
        blockers,
        ancestors,
    })
}

fn node_of(read: &ItemRead) -> ChainNode {
    ChainNode {
        blocked_by_launch: read.blocked_by_launch.clone(),
        parent_id: read.parent_id.clone(),
    }
}

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
    let chain = chain(item, node_of(read), |parent| {
        reader(parent).map(|r| Some(node_of(&r)))
    })
    .map_err(|(read, cause)| Error::LaunchBlockedUnread {
        item: item.to_owned(),
        read,
        cause,
    })?;
    if chain.blockers.is_empty() {
        return Ok(());
    }
    Err(Error::LaunchBlocked {
        item: item.to_owned(),
        blockers: chain.blockers.into_iter().collect(),
    })
}

/// The label that makes an item a container whatever its children.
pub(crate) const MULTI_LABEL: &str = "agent:multi";

/// The cause word of a container the launch refuses, or none: an in-PR
/// bundle root is the one container launched (`skill-rules.md` §
/// Containers).
pub(crate) fn container_cause(
    in_pr_bundle: bool,
    has_children: bool,
    labels: &[String],
) -> std::result::Result<(), &'static str> {
    if in_pr_bundle {
        return Ok(());
    }
    if has_children {
        return Err("parent-with-children");
    }
    if labels.iter().any(|l| l == MULTI_LABEL) {
        return Err("agent-multi");
    }
    Ok(())
}

/// Whether the cause word a container refusal carries.
fn eligibility(item: &ItemRead) -> std::result::Result<(), &'static str> {
    container_cause(item.in_pr_bundle, item.children > 0, &item.labels)
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

enum PathSource {
    Location,
    Brief,
}

/// A brief can name a path for reference. Read the direct instruction
/// and KEN-5910's reported wording, "holds PATH; ..., do not edit it",
/// within the prose next to that mention.
fn do_not_edit(before: &str, after: &str) -> bool {
    let before = before.to_ascii_lowercase();
    if before
        .split_whitespace()
        .rev()
        .take(3)
        .eq(["edit", "not", "do"])
    {
        return true;
    }
    before.split_whitespace().next_back() == Some("holds")
        && after
            .split(['`', '\n', '.', '!', '?'])
            .next()
            .and_then(|sentence| sentence.rsplit([';', ',']).next())
            .is_some_and(|clause| clause.trim().eq_ignore_ascii_case("do not edit it"))
}

/// The backticked tokens of `text` holding no whitespace, each less a
/// `:N` or `:N-M` line suffix. In a brief, omit a do-not-edit mention.
fn ticks(text: &str, source: PathSource) -> Vec<String> {
    let mut found = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('`') {
        let before = &rest[..open];
        let after = &rest[open + 1..];
        let Some(close) = after.find('`') else {
            break;
        };
        let token = &after[..close];
        rest = &after[close + 1..];
        if token.is_empty()
            || token.chars().any(char::is_whitespace)
            || (matches!(source, PathSource::Brief) && do_not_edit(before, rest))
        {
            continue;
        }
        found.push(without_line_suffix(token).to_owned());
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

/// The paths the body's Location lines name, each line read by
/// [`named_paths`]. A Location line naming no path is unread (`location`).
fn location_paths(body: &str) -> std::result::Result<Vec<String>, &'static str> {
    let mut located = false;
    let mut paths = Vec::new();
    for line in body.split('\n') {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if is_location_line(line) {
            located = true;
            paths.extend(named_paths(line, PathSource::Location));
        }
    }
    if located && paths.is_empty() {
        return Err("location");
    }
    Ok(paths)
}

/// Where a source catalog's `skills/` tree renders in the checkout that
/// installs it.
const SKILLS_SOURCE: &str = "skills/";
const SKILLS_RENDER: &str = ".agents/skills/";

/// The paths `text` names: its backticked tokens that read as a path
/// ([`is_path`]). Item text names files in prose beside flags and function
/// names, so the form is the rule; the touched set reaches change-scope
/// as `--path` values, which refuses one that reads as an option. Text
/// that names the bare render directory beside paths under `skills/`
/// ("with their `.agents/skills` renders") names the render of each of
/// those paths in place of the directory, which no file of a branch meets.
/// With no `skills/` path to render, the directory stays, spelled
/// [`SKILLS_RENDER`] so it meets every render under it: it is then the only
/// claim on the renders the item writes, such as those a `kendex-local.toml`
/// instruction or a render-engine change rewrites.
fn named_paths(text: &str, source: PathSource) -> Vec<String> {
    let mut paths: Vec<String> = ticks(text, source)
        .into_iter()
        .filter(|t| is_path(t))
        .collect();
    let is_render_root = |p: &str| p.trim_end_matches('/') == SKILLS_RENDER.trim_end_matches('/');
    if paths.iter().any(|p| is_render_root(p)) {
        let mut renders: Vec<String> = paths
            .iter()
            .filter_map(|p| p.strip_prefix(SKILLS_SOURCE))
            .map(|rest| format!("{SKILLS_RENDER}{rest}"))
            .collect();
        if renders.is_empty() {
            renders.push(SKILLS_RENDER.to_owned());
        }
        paths.retain(|p| !is_render_root(p));
        paths.extend(renders);
    }
    paths
}

/// Whether a backticked token reads as a path: one holding a `/`, less a
/// URL, or a file name with an extension (`Cargo.lock`, `.gitignore`), and
/// never an option word. A function, a field or a version names no file.
fn is_path(token: &str) -> bool {
    if token.starts_with('-') || token.contains("://") {
        return false;
    }
    if token.contains('/') {
        return true;
    }
    let name_chars = token
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+' | '@'));
    let extension = token.rsplit_once('.').is_some_and(|(_, ext)| {
        ext.starts_with(|c: char| c.is_ascii_alphabetic())
            && ext.chars().all(|c| c.is_ascii_alphanumeric())
    });
    name_chars && extension
}

/// The touched set: the body's Location paths, the brief's edit paths, the
/// range's changed paths and the paths added, `changelog.d/` left out in
/// either spelling, read in `root`, the checkout it is recorded for
/// ([`folders`]). The admission judges holders over it and the tier
/// classifies it, so both read one set from the same inputs. A Location
/// line naming no path is unread (`location`).
pub(super) fn touched(
    root: Option<&Path>,
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
        touched.extend(named_paths(brief, PathSource::Brief));
    }
    touched.extend(range.iter().chain(added).cloned());
    touched.retain(|p| !p.is_empty() && !covers(UNCOUNTED_PREFIX, p));
    let touched: Vec<String> = touched.into_iter().collect();
    Ok(folders(root, &touched))
}

/// Whether `a` and `b` name one file: the same path, or one a path under
/// the other. The rule reads the strings alone, a trailing `/` aside, so a
/// folder entry with or without its `/` holds the files under it wherever
/// the folder stands: on a lane's host only, as a submodule's gitlink, or
/// replacing a file another holder names.
fn meets(a: &str, b: &str) -> bool {
    covers(a, b) || covers(b, a)
}

/// Whether an in-scope entry `scope` covers `file`: the same path, or
/// `file` under it, by [`meets`]'s string rule.
fn covers(scope: &str, file: &str) -> bool {
    let (scope, file) = (scope.trim_end_matches('/'), file.trim_end_matches('/'));
    file == scope
        || file
            .strip_prefix(scope)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// `entries` as an admitted set records them, sorted and once each: an
/// entry naming a folder in `root`, the checkout it is recorded for, ends
/// in `/`, the spelling a dev round reads as covering the paths under it
/// and the tier classifies. A file, a symlink (a pull request's files name
/// one at its own path, whatever it points at), or a path naming nothing
/// there or whose metadata cannot be read, stays as written. Matching
/// never needs it: [`meets`] reads either spelling as the folder.
fn folders(root: Option<&Path>, entries: &[String]) -> Vec<String> {
    let is_folder =
        |root: &Path, e: &str| std::fs::symlink_metadata(root.join(e)).is_ok_and(|m| m.is_dir());
    let folder = |e: &String| match root {
        Some(root) if !e.is_empty() && !e.ends_with('/') && is_folder(root, e) => format!("{e}/"),
        _ => e.clone(),
    };
    let set: BTreeSet<String> = entries.iter().map(folder).collect();
    set.into_iter().collect()
}

/// The paths `a` and `b` share that the scope leaves in, each the longer
/// of its pair, sorted and unique.
fn shared(a: &[String], b: &[String], scope: &[String]) -> Vec<String> {
    let mut files = BTreeSet::new();
    for x in a {
        for y in b {
            if covers(UNCOUNTED_PREFIX, y) || !meets(x, y) {
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

fn same_repo(a: Option<&str>, b: Option<&str>, own: Option<&str>) -> bool {
    match (a.or(own), b.or(own)) {
        (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
        (None, None) => true,
        _ => false,
    }
}

pub(super) fn lane_repo(lane: &Lane) -> Option<&str> {
    lane.file_repo.as_deref().or(lane.repo.as_deref())
}

#[derive(Debug, PartialEq, Eq)]
enum Holding {
    Writing,
    Protected,
    Unknown(String),
    Yields,
}

fn execution(lane: &Lane, intents: &[Intent], env: &Env, host: &Host) -> Holding {
    if lane.host.is_some() || lane.native_surface() {
        return match lane.status {
            LaneStatus::Running => Holding::Writing,
            LaneStatus::Preparing => Holding::Protected,
            LaneStatus::Stopped | LaneStatus::Parked | LaneStatus::Done => Holding::Yields,
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
        Some((ChargeReason::Live | ChargeReason::Wake | ChargeReason::Session, _)) => {
            Holding::Writing
        }
        Some((ChargeReason::Preparing, _)) => Holding::Protected,
        Some((ChargeReason::Unknown, cause)) => Holding::Unknown(cause.unwrap_or_default()),
        Some((ChargeReason::Reservation | ChargeReason::Sandbox, _)) | None => Holding::Yields,
    }
}

fn handoff(lane: &Lane, intents: &[Intent]) -> bool {
    lane.file_launch.is_some()
        || lane.extra.contains_key(state::PARK_OWED)
        || intents.iter().any(|i| {
            i.target == lane.item
                && i.open()
                && matches!(i.op, EffectOp::CloseResources | EffectOp::LaunchSession)
        })
}

fn writable(
    lane: &Lane,
    tracker: Option<&str>,
    repo: Option<&str>,
    host: &Host,
) -> std::result::Result<Vec<String>, (&'static str, String)> {
    if lane.read_only {
        return Ok(Vec::new());
    }
    if let Some(touched) = &lane.touched {
        return Ok(touched.clone());
    }
    let tracker = tracker.ok_or(("item", "tracker-unnamed".to_owned()))?;
    let reads = host
        .admission
        .as_ref()
        .ok_or(("item", "admission-reads-unavailable".to_owned()))?;
    let item =
        (reads.item)(&reads.clis, tracker, &lane.item, repo).map_err(|cause| ("item", cause))?;
    let paths = location_paths(&item.body).map_err(|cause| ("location", cause.into()))?;
    if paths.is_empty() {
        return Err(("location", "location-unnamed".to_owned()));
    }
    Ok(folders(lane.mail_root.as_deref().map(Path::new), &paths))
}

fn required_paths(
    lane: &Lane,
    tracker: Option<&str>,
    repo: Option<&str>,
    host: &Host,
) -> Result<Vec<String>> {
    writable(lane, tracker, repo, host).map_err(|(read, cause)| Error::TouchedUnreadable {
        item: lane.item.clone(),
        read,
        cause,
    })
}

fn claim(lane: &Lane, paths: Vec<String>, hold: FileHold) -> FileClaim {
    FileClaim {
        repo: lane_repo(lane).map(str::to_owned),
        touched: paths,
        in_scope: lane.in_scope.clone().unwrap_or_default(),
        hold,
    }
}

struct Held {
    state: Holding,
    paths: std::result::Result<Vec<String>, (&'static str, String)>,
    /// Only exclusive recovery authority drops the holder's append exceptions.
    exceptions: Vec<String>,
}

fn closed_claim(claim: FileClaim) -> Held {
    Held {
        state: Holding::Protected,
        paths: Ok(claim.touched),
        exceptions: if claim.hold == FileHold::Retained {
            claim.in_scope
        } else {
            Vec::new()
        },
    }
}

/// Read both the admitted attempt and a source claim left by its launch.
/// Lifecycle status and the journal decide whether the set can accept work.
fn holding(
    path: &Path,
    lane: &Lane,
    repo: Option<&str>,
    own: Option<&str>,
    intents: &[Intent],
    env: &Env,
    host: &Host,
) -> Result<Vec<Held>> {
    if lane.read_only || lane.status == LaneStatus::Done {
        return Ok(Vec::new());
    }
    let mut held = Vec::new();
    if let Some(launch) = lane
        .file_launch
        .as_ref()
        .and_then(|id| intents.iter().find(|i| &i.id == id))
        && let Some(previous) = LaneMembers::of(path, launch)?.previous_files
        && let Some(claim) = previous.claim
        && same_repo(claim.repo.as_deref(), repo, own)
    {
        held.push(closed_claim(claim));
    }
    if !same_repo(lane_repo(lane), repo, own) {
        return Ok(held);
    }
    if let Some(close) = intents
        .iter()
        .find(|i| i.target == lane.item && i.open() && i.op == EffectOp::CloseResources)
        && let Some(claim) = LaneMembers::of(path, close)?.close_files
    {
        held.push(closed_claim(claim));
        return Ok(held);
    }
    if lane.status == LaneStatus::Parked {
        return Ok(held);
    }
    let moving = handoff(lane, intents);
    let state = match lane.file_hold {
        Some(FileHold::Released) => Holding::Yields,
        Some(FileHold::Retained) => Holding::Protected,
        Some(FileHold::Exclusive | FileHold::Shared) if moving => Holding::Protected,
        Some(FileHold::Exclusive | FileHold::Shared) => match execution(lane, intents, env, host) {
            Holding::Yields => Holding::Protected,
            other => other,
        },
        None => match execution(lane, intents, env, host) {
            Holding::Writing if moving => Holding::Protected,
            // A pre-upgrade close can outlive its active process. Keep that
            // attempt's authority until the journal settles it.
            Holding::Yields if moving && lane.status.in_flight() => Holding::Protected,
            other => other,
        },
    };
    if state != Holding::Yields {
        held.push(Held {
            state,
            paths: writable(lane, lane.tracker.as_deref(), lane.repo.as_deref(), host),
            exceptions: if lane.file_hold == Some(FileHold::Retained) {
                lane.in_scope.clone().unwrap_or_default()
            } else {
                Vec::new()
            },
        });
    }
    Ok(held)
}

/// The old claim a replacement leaves behind until it settles.
pub(super) fn retained(lane: &Lane, host: &Host) -> Result<Option<FileClaim>> {
    if lane.file_hold != Some(FileHold::Retained) || lane.read_only {
        return Ok(None);
    }
    let paths = required_paths(lane, lane.tracker.as_deref(), lane.repo.as_deref(), host)?;
    Ok(Some(claim(lane, paths, FileHold::Retained)))
}

/// A close carries an existing authorization, or checks the entire set
/// before a legacy record can gain recovery authority.
pub(super) fn closing(
    path: &Path,
    lanes: &[Lane],
    intents: &[Intent],
    lane: &Lane,
    retain: bool,
    env: &Env,
    host: &Host,
) -> Result<Option<FileClaim>> {
    if lane.read_only {
        return Ok(None);
    }
    match lane.file_hold {
        Some(FileHold::Exclusive | FileHold::Shared | FileHold::Retained) => {
            let paths = required_paths(lane, lane.tracker.as_deref(), lane.repo.as_deref(), host)?;
            return Ok(Some(claim(lane, paths, lane.file_hold.unwrap())));
        }
        Some(FileHold::Released) if !retain => return Ok(None),
        None if !retain => {
            // Preserve a legacy writer's set while cleanup is still open.
            // Unreadable paths cannot prevent a cleanup that yields.
            return Ok((execution(lane, intents, env, host) != Holding::Yields)
                .then(|| writable(lane, lane.tracker.as_deref(), lane.repo.as_deref(), host).ok())
                .flatten()
                .map(|paths| claim(lane, paths, FileHold::Shared)));
        }
        Some(FileHold::Released) | None => {}
    }
    let paths = required_paths(lane, lane.tracker.as_deref(), lane.repo.as_deref(), host)?;
    let judged = judge_set(
        path,
        lanes,
        intents,
        lane,
        &paths,
        lane_repo(lane),
        Launch::Added,
        env,
        host,
    );
    match judged {
        Ok(_) => Ok(Some(claim(lane, paths, FileHold::Exclusive))),
        // A legacy co-writer can stop its current worker, but only the
        // first checked claimant can recover on the overlapping set.
        Err(Error::LaunchOverlap { .. })
            if execution(lane, intents, env, host) == Holding::Writing =>
        {
            Ok(Some(claim(lane, paths, FileHold::Shared)))
        }
        Err(error) => Err(error),
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

/// Locate the only lane carrying every blocker. Holding determines
/// separately whether that lane can receive this join.
fn carrier(
    lanes: &[Lane],
    blockers: &[String],
    repo: Option<&str>,
    own: Option<&str>,
) -> Option<usize> {
    let mut found = lanes.iter().enumerate().filter(|(_, lane)| {
        lane.status != LaneStatus::Done
            && !lane.read_only
            && same_repo(lane_repo(lane), repo, own)
            && blockers.iter().all(|b| lane.carries(b))
    });
    match (found.next(), found.next()) {
        (Some((index, _)), None) => Some(index),
        _ => None,
    }
}

/// Whether a live holder is before its review, the one state a launch joins:
/// no pull request its record names (`pending_pr`, `parked`) and no `review`
/// stage, open or ended, in its current session, read from its item state on
/// this disk (`watch::lanes::local_held`): a lane fixing after its review
/// would take work no review round read. A state that cannot be read refuses
/// `holder-unreadable read=stage`. A hosted or cloud holder refuses
/// `join-unreachable` naming the `tie`: its stage and its mailbox are on
/// its host, and a join tells its lane itself.
fn before_review(path: &Path, lane: &Lane, item: &str, tie: &Tie) -> Result<bool> {
    if let Some(route) = unreachable(lane) {
        return Err(join_unreachable(item, tie, &lane.item, route, &[]));
    }
    if ["pending_pr", "parked"]
        .iter()
        .any(|key| lane.extra.get(*key).is_some_and(|v| !v.is_null()))
    {
        return Ok(false);
    }
    match crate::watch::lanes::local_held(
        lane,
        path.parent().unwrap_or(Path::new("")),
        StageKind::Review.word(),
    ) {
        Ok(reviewed) => Ok(!reviewed),
        Err(cause) => Err(Error::HolderUnreadable {
            item: item.to_owned(),
            holder: lane.item.clone(),
            read: "stage",
            cause,
        }),
    }
}

/// The route that keeps a holder's stage and mailbox off this host: `session`
/// for a cloud session, `hosted` for a lane on a provider, `None` for a lane
/// here.
fn unreachable(lane: &Lane) -> Option<&'static str> {
    if lane.session_channel() {
        Some("session")
    } else if lane.host.is_some() {
        Some("hosted")
    } else {
        None
    }
}

/// An unreachable holder judged by its head commit's unmerged change. A
/// lane whose stage and mailbox are on its host takes no join, and edits it
/// has not committed are on its host alone, so it holds every path it names
/// whatever its branch shows. Where its head changes a path of `touched`
/// that the scope leaves in, it is judged on as any live holder. Otherwise
/// it refuses `join-unreachable` naming the held `tie`, the branch and the
/// cause: a head that changes none of them is `worktree-unproved`, and a
/// read that failed names its own cause. A cloud session's head is on its
/// cloud, which no verb reads.
fn branch_judged(
    lane: &Lane,
    route: &str,
    tie: &Tie,
    touched: &[String],
    in_scope: &[String],
    item: &str,
    host: &Host,
) -> Result<()> {
    let refused = |unread: BranchUnread| {
        join_unreachable(
            item,
            tie,
            &lane.item,
            route,
            &[
                ("branch", unread.branch.as_deref().unwrap_or("unknown")),
                ("cause", &unread.cause),
            ],
        )
    };
    let unread = |cause: &str| BranchUnread {
        branch: None,
        cause: cause.to_owned(),
    };
    if route == "session" {
        return Err(refused(unread("session-head-unread")));
    }
    let reads = host
        .admission
        .as_ref()
        .ok_or_else(|| refused(unread("admission-reads-unavailable")))?;
    let change = (reads.branch)(&reads.clis, lane).map_err(refused)?;
    if shared(touched, &change.files, in_scope).is_empty() {
        return Err(refused(BranchUnread {
            cause: format!("worktree-unproved head={}", change.head),
            branch: Some(change.branch),
        }));
    }
    Ok(())
}

/// Whether the fleet delivers straight onto its base (`ORCH_DELIVERY`), the
/// publication then taking the landing order; a host with no settings is
/// judged as a pull-request fleet, whose order the refusal keeps.
fn direct(host: &Host) -> Result<bool> {
    match host.accounts {
        Some(settings) => Ok(settings.validate.delivery()? == Delivery::PushBase),
        None => Ok(false),
    }
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
/// Answers the checkout's canonical common git folder where it was read: a
/// fleet in no checkout reads none.
fn bind(
    path: &Path,
    a: &Admission,
    checkout: &Path,
    reads: &AdmissionReads,
    settings: Option<&Settings>,
) -> Result<CheckoutBinding> {
    let fleet_dir = path.parent().unwrap_or(Path::new("/"));
    let fleet = (reads.checkout)(&reads.clis, fleet_dir)
        .map_err(|_| unjudged("overseer-root", fleet_dir))?;
    let mut checkout_binding = CheckoutBinding {
        repo: a.repo.map(str::to_owned),
        ..CheckoutBinding::default()
    };
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
            if a.tracker != Some("github")
                && let (Some(asked), Some(actual)) = (a.repo, launch.slug.as_deref())
                && !asked.eq_ignore_ascii_case(actual)
            {
                return Err(item_foreign(asked));
            }
            checkout_binding.common = Some(launch.root.clone());
            checkout_binding.repo = launch.slug.clone().or(checkout_binding.repo);
            checkout_binding.own = fleet.slug.clone();
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
                return Ok(checkout_binding);
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
    Ok(checkout_binding)
}

/// The binding alone (the module's binding paragraph): a first launch's,
/// inside the judgement, and a relaunch's, whose touched set and Ancestor
/// gate were judged when it was first admitted but whose checkout, tracker
/// and repository the request may change. Answers the checkout's common
/// git folder as [`bind`] read it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct CheckoutBinding {
    pub common: Option<PathBuf>,
    pub repo: Option<String>,
    own: Option<String>,
}

impl CheckoutBinding {
    pub(super) fn carries(&self, previous: &FileClaim) -> bool {
        same_repo(
            self.repo.as_deref(),
            previous.repo.as_deref(),
            self.own.as_deref(),
        )
    }
}

pub(super) fn bound(
    path: &Path,
    item: &str,
    tracker: Option<&str>,
    repo: Option<&str>,
    checkout: &Path,
    host: &Host,
) -> Result<CheckoutBinding> {
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
        launch: Launch::First(checkout),
        read_only: false,
    };
    bind(path, &a, checkout, reads, host.accounts)
}

/// A relaunch keeps its recorded scope and checks its entire set against
/// the destination. A missing set is read in the effective tracker.
#[allow(
    clippy::too_many_arguments,
    reason = "the relaunch judges the current fleet and destination"
)]
pub(super) fn relaunch_held(
    path: &Path,
    lanes: &[Lane],
    intents: &[Intent],
    lane: &Lane,
    tracker: Option<&str>,
    repo: Option<&str>,
    env: &Env,
    host: &Host,
) -> Result<Judged> {
    let paths = if tracker.is_none() && lane.touched.is_none() {
        Vec::new()
    } else {
        required_paths(lane, tracker, repo, host)?
    };
    judge_set(
        path,
        lanes,
        intents,
        lane,
        &paths,
        repo,
        Launch::Relaunch,
        env,
        host,
    )
}

#[allow(
    clippy::too_many_arguments,
    reason = "one judgement over the fleet and the record's set"
)]
fn judge_set(
    path: &Path,
    lanes: &[Lane],
    intents: &[Intent],
    lane: &Lane,
    paths: &[String],
    repo: Option<&str>,
    mode: Launch<'_>,
    env: &Env,
    host: &Host,
) -> Result<Judged> {
    judge(
        path,
        lanes,
        intents,
        &Admission {
            item: &lane.item,
            tracker: None,
            repo,
            brief_file: None,
            repo_dir: None,
            scope_range: None,
            in_scope: lane.in_scope.as_deref().unwrap_or_default(),
            paths,
            launch: mode,
            read_only: lane.read_only,
        },
        env,
        host,
    )
}

fn own_repo(path: &Path, host: &Host) -> Result<Option<String>> {
    let Some(reads) = &host.admission else {
        return Ok(None);
    };
    let dir = path.parent().unwrap_or(Path::new("/"));
    (reads.checkout)(&reads.clis, dir)
        .map(|checkout| checkout.and_then(|r| r.slug))
        .map_err(|_| unjudged("overseer-root", dir))
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
    let mut binding = match a.checkout() {
        Some(checkout) => bound(path, a.item, a.tracker, a.repo, checkout, host)?,
        None => CheckoutBinding {
            repo: a.repo.map(str::to_owned),
            ..CheckoutBinding::default()
        },
    };
    if a.checkout().is_none()
        && lanes.iter().any(|lane| {
            lane_repo(lane).is_some() != binding.repo.is_some() || lane.file_launch.is_some()
        })
    {
        binding.own = own_repo(path, host)?;
    }
    let repo = binding.repo.as_deref();
    let own = binding.own.as_deref();
    let joins = matches!(a.launch, Launch::First(_));
    let mut body = None;
    let mut blocked = None;
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
        // A read-only lane, a plan or a tracker-comment lane, ships nothing
        // the blockers' work must precede, so it starts beside them and
        // never joins their carrier, which would run its brief outside the
        // confinement it asked for.
        if tracker == "linear" && !a.read_only {
            // A first launch whose every blocker one lane carries ships
            // with that lane where it stands live before its review.
            match launch_blockers(a.item, &item, |parent| {
                (reads.item)(&reads.clis, tracker, parent, a.repo)
            }) {
                Err(Error::LaunchBlocked { item, blockers }) if joins => {
                    match carrier(lanes, &blockers, repo, own) {
                        Some(index) => blocked = Some((index, blockers)),
                        None => return Err(Error::LaunchBlocked { item, blockers }),
                    }
                }
                other => other?,
            }
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
    let classified = touched(
        a.checkout(),
        body.as_deref(),
        brief.as_deref(),
        &range_paths,
        a.paths,
    )
    .map_err(|c| unreadable("location", c.into()))?;
    let touched = if a.read_only {
        Vec::new()
    } else {
        classified.clone()
    };
    let in_scope: Vec<String> = a
        .in_scope
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let holder_unreadable =
        |holder: &str, read: &'static str, cause: String| Error::HolderUnreadable {
            item: a.item.to_owned(),
            holder: holder.to_owned(),
            read,
            cause,
        };
    let mut join = None;
    let mut blocker_claims = None;
    if let Some((index, blockers)) = blocked {
        let holder = &lanes[index];
        let claims = holding(path, holder, repo, own, intents, env, host)?;
        let mut tied = Join {
            holder: index,
            tie: Tie::Blockers(blockers),
            paths: Vec::new(),
        };
        let Some(writing) = claims.iter().find(|held| held.state == Holding::Writing) else {
            return Err(tied.refusal(a.item, &holder.item));
        };
        if !before_review(path, holder, a.item, &tied.tie)? {
            return Err(tied.refusal(a.item, &holder.item));
        }
        tied.paths = writing
            .paths
            .clone()
            .map_err(|(_, cause)| holder_unreadable(&holder.item, "touched", cause))?;
        join = Some(tied);
        blocker_claims = Some((index, claims));
    }
    let mut hold = FileHold::Exclusive;
    for (index, lane) in lanes.iter().enumerate().filter(|_| !touched.is_empty()) {
        if lane.item == a.item {
            continue;
        }
        let claims = if blocker_claims
            .as_ref()
            .is_some_and(|(holder, _)| *holder == index)
        {
            blocker_claims.take().expect("matching blocker carrier").1
        } else {
            holding(path, lane, repo, own, intents, env, host)?
        };
        for held in claims {
            let held_paths = held
                .paths
                .map_err(|(_, cause)| holder_unreadable(&lane.item, "touched", cause))?;
            let paths = shared(&touched, &held_paths, &union(&in_scope, &held.exceptions));
            let Some(file) = paths.first() else { continue };
            if let Holding::Unknown(cause) = held.state {
                return Err(holder_unreadable(&lane.item, "identity", cause));
            }
            let conflict = || Error::LaunchOverlap {
                item: a.item.to_owned(),
                file: file.clone(),
                holder: lane.item.clone(),
            };
            if held.state != Holding::Writing {
                return Err(conflict());
            }
            let tie = Tie::File(file.clone());
            if a.checkout().is_some()
                && let Some(route) = unreachable(lane)
            {
                branch_judged(lane, route, &tie, &touched, &in_scope, a.item, host)?;
            }
            let joinable = joins && join.as_ref().is_none_or(|j: &Join| j.holder == index);
            let direct = match a.launch {
                Launch::First(_) | Launch::Surface(_) => direct(host)?,
                Launch::Relaunch => unreachable(lane).is_none() && direct(host)?,
                Launch::Added => false,
            };
            let before = if joinable || direct {
                Some(before_review(path, lane, a.item, &tie)?)
            } else {
                None
            };
            match before {
                Some(true) if joinable => {
                    join.get_or_insert(Join {
                        holder: index,
                        tie,
                        paths: held_paths,
                    });
                }
                Some(false) if direct => hold = FileHold::Shared,
                _ => return Err(conflict()),
            }
        }
    }
    let check_unowned = a.checkout().is_some() && !touched.is_empty();
    if (join.is_some() || check_unowned) && (repo.is_some() || a.repo_dir.is_some()) {
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
        let read = (reads.pulls)(&reads.clis, repo, a.repo_dir).map_err(|failure| {
            Error::HoldersUnreadable {
                item: a.item.to_owned(),
                repo: failure.repo,
                read: failure.read,
                cause: failure.cause,
            }
        })?;
        if let Some(OpenPulls { repo, pulls }) = read {
            // A holder that owns an open pull request is in its review.
            if let Some(join) = &join {
                let holder = &lanes[join.holder];
                let branch = holder_branch(path, &holder.item)?;
                if pulls
                    .iter()
                    .any(|pull| names_pull(holder, branch.as_deref(), pull, &repo))
                {
                    return Err(join.refusal(a.item, &holder.item));
                }
            }
            if check_unowned && !pulls.is_empty() {
                let own_branch = holder_branch(path, a.item)?;
                let issue_number = if a.tracker == Some("github") {
                    super::accept::issue_number(a.item)
                } else {
                    None
                };
                let closes = issue_number.map_or_else(|| a.item.to_owned(), |n| format!("#{n}"));
                let named = lanes
                    .iter()
                    .filter(|lane| {
                        lane.status != LaneStatus::Done
                            && same_repo(lane_repo(lane), Some(&repo), own)
                    })
                    .map(|lane| Ok((lane, holder_branch(path, &lane.item)?)))
                    .collect::<Result<Vec<_>>>()?;
                for pull in pulls {
                    if own_branch.as_deref() == Some(pull.branch.as_str())
                        || pull.branch.eq_ignore_ascii_case(a.item)
                        || issue_number == Some(pull.number)
                        || crate::watch::github::body_closes(&pull.body, &closes)
                        || named
                            .iter()
                            .any(|(lane, branch)| names_pull(lane, branch.as_deref(), &pull, &repo))
                    {
                        continue;
                    }
                    let files = read_pull_files(&reads.clis, &repo, &pull).map_err(|cause| {
                        Error::HoldersUnreadable {
                            item: a.item.to_owned(),
                            repo: repo.clone(),
                            read: "files",
                            cause,
                        }
                    })?;
                    if let Some(file) = shared(&touched, &files, &in_scope).into_iter().next() {
                        return Err(Error::LaunchOverlap {
                            item: a.item.to_owned(),
                            file,
                            holder: format!("#{}", pull.number),
                        });
                    }
                }
            }
        }
    }
    if let (Some(join), Some(checkout)) = (&join, a.checkout()) {
        join_checkout(path, a.item, checkout, &lanes[join.holder], intents)?;
    }
    Ok(Judged {
        touched,
        classified,
        in_scope,
        join,
        binding,
        hold,
    })
}

/// A holder may carry work in its own checkout or outside it when its
/// launch ran unconfined. The launch effect reports its actual confinement
/// on the intent, including the linked-seat exception. The latest launch
/// alone can authorize the join: a relaunch can change the confinement,
/// and a still-opening or recovered launch may have no observation yet.
fn join_checkout(
    path: &Path,
    item: &str,
    checkout: &Path,
    holder: &Lane,
    intents: &[Intent],
) -> Result<()> {
    let launch = intents
        .iter()
        .rfind(|i| i.op == EffectOp::LaunchSession && i.target == holder.item);
    let confinement = match launch {
        Some(intent)
            if intent.reconciled.is_none()
                && LaneMembers::of(path, intent)?.lane_since == holder.session_since =>
        {
            intent
                .observation
                .as_ref()
                .and_then(|o| o.get("confinement"))
                .and_then(|value| serde_json::from_value::<Confinement>(value.clone()).ok())
        }
        // Before the fleet recorded launch intents, the platform can still
        // prove a harness whose launcher never confines it here.
        None if holder.status != LaneStatus::Preparing => holder
            .harness
            .as_deref()
            .and_then(|name| Harness::named(name).ok())
            .map(|harness| confine::answer(confine::Host::this(), harness))
            .filter(|answer| matches!(answer, Confinement::Unconfined { .. })),
        _ => None,
    };
    if matches!(confinement, Some(Confinement::Unconfined { .. })) {
        return Ok(());
    }
    if let Some(root) = holder.mail_root.as_deref()
        && let (Ok(held), Ok(candidate)) =
            (std::fs::canonicalize(root), std::fs::canonicalize(checkout))
        && held == candidate
    {
        return Ok(());
    }
    let cause = match confinement {
        Some(Confinement::Confined) => "worktree-outside-holder",
        _ => "confinement-unproved",
    };
    Err(Error::from(agent_runtime::Error::refused(
        "join-confined",
        &[("item", item), ("holder", &holder.item), ("cause", cause)],
    )))
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

/// `a` and `b` as one sorted set.
fn union(a: &[String], b: &[String]) -> Vec<String> {
    a.iter()
        .chain(b)
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Write a launch's judgement onto the lane record at `index`: the set it
/// opens with replaces whatever an earlier opening left,
/// [`state::UNBOUNDED`] included.
pub(super) fn record(
    path: &Path,
    doc: &mut Document,
    index: usize,
    judged: &Judged,
    relaunch: bool,
) -> Result<()> {
    let lane = lane_doc_mut(path, doc, index)?;
    if relaunch && lane.get("touched").is_none_or(Value::is_null) {
        record::set(lane, state::UNBOUNDED, true);
    }
    if !relaunch {
        record::delete(lane, state::UNBOUNDED);
    }
    record::set(lane, "touched", serde_json::to_value(&judged.touched)?);
    record::set(lane, "in_scope", serde_json::to_value(&judged.in_scope)?);
    record::set(lane, "file_hold", serde_json::to_value(judged.hold)?);
    match &judged.binding.repo {
        Some(repo) => record::set(lane, "file_repo", repo.as_str()),
        None => {
            record::delete(lane, "file_repo");
        }
    }

    Ok(())
}

/// Widen the standing lane record at `index` to `touched` and `in_scope`,
/// each already holding the record's own. A lane whose record renders no
/// admitted line runs unbounded, and the widening records that it stays so:
/// a set made of the added paths alone would bound its own item's work by
/// paths no judge read for it.
fn widen(
    path: &Path,
    doc: &mut Document,
    index: usize,
    standing: &Lane,
    touched: &[String],
    in_scope: &[String],
) -> Result<()> {
    let lane = lane_doc_mut(path, doc, index)?;
    record::set(lane, "touched", serde_json::to_value(touched)?);
    record::set(lane, "in_scope", serde_json::to_value(in_scope)?);
    if standing.admitted_line().is_none() {
        record::set(lane, state::UNBOUNDED, true);
    }
    Ok(())
}

/// The join's one writer, under the launch lock: the widened touched set is
/// judged first by the one tier function at the holder's recorded tier, a
/// set that needs a wider cycle refusing `join-tier-narrower`; then the
/// holder's record carries the candidate once, its touched set and scope
/// widened by the candidate's, and the candidate's brief reaches the
/// holder's own mailbox with the widened set where the holder held one
/// ([`tell`]). Answers the holder's record as written.
pub(super) fn join(
    path: &Path,
    doc: &mut Document,
    a: &Admission,
    judged: &Judged,
    index: usize,
    env: &Env,
    host: &Host,
) -> Result<Lane> {
    let holder = lane_at(path, doc, index)?;
    let rows = lanes(path, doc)?;
    let open = intents(path, doc)?;
    let standing = &judged
        .join
        .as_ref()
        .expect("a join carries its judged set")
        .paths;
    if holder.touched.is_none() {
        judge_set(
            path,
            &rows,
            &open,
            &holder,
            standing,
            lane_repo(&holder),
            Launch::Added,
            env,
            host,
        )?;
    }
    let touched = union(standing, &judged.touched);
    if let Some(tier) = holder.extra.get("tier").and_then(Value::as_str) {
        let dir = a.checkout().unwrap_or(Path::new(""));
        if let Some(needs) = wider_cycle(a.item, tier, &touched, dir, host)? {
            return Err(Error::from(agent_runtime::Error::refused(
                "join-tier-narrower",
                &[
                    ("item", a.item),
                    ("holder", &holder.item),
                    ("tier", tier),
                    ("needs", needs.cycle.word()),
                ],
            )));
        }
    }
    let mut carried = holder.carried.clone();
    if !carried.iter().any(|c| c.item == a.item) {
        carried.push(Carried {
            item: a.item.to_owned(),
            tracker: a.tracker.map(str::to_owned),
            repo: a.repo.map(str::to_owned),
            at: env.iso(),
        });
    }
    let in_scope = union(
        holder.in_scope.as_deref().unwrap_or_default(),
        &judged.in_scope,
    );
    widen(path, doc, index, &holder, &touched, &in_scope)?;
    let lane = lane_doc_mut(path, doc, index)?;
    record::set(lane, "carried", serde_json::to_value(&carried)?);
    if judged.hold == FileHold::Shared {
        record::set(lane, "file_hold", serde_json::to_value(FileHold::Shared)?);
    }
    let widened = lane_at(path, doc, index)?;
    tell(path, a, &widened, env, host)?;
    Ok(widened)
}

/// The candidate's brief written to the holder's own inbox through the
/// mailbox program its turn end reads, `lane-mail send --directive` on the
/// holder's recorded root, under the delivery `join-<item>`: a repeated join
/// lands once. The directive opens with `joined item=<item> holder=<holder>`,
/// then the holder's widened `Admitted paths:` line where it renders one,
/// which replaces the set its next dev round is delegated, so that round
/// asks for none of the paths the join already admitted.
/// A send that does not answer delivered refuses `join-unsent` with its
/// cause, and the launch lock's transition then writes nothing.
#[allow(
    clippy::disallowed_methods,
    reason = "the join's directive file, created exclusively under the fleet's state directory for the mailbox program to read and removed after its send"
)]
fn tell(path: &Path, a: &Admission, holder: &Lane, env: &Env, host: &Host) -> Result<()> {
    use std::io::Write;
    let unsent = |cause: String| {
        Error::from(agent_runtime::Error::refused(
            "join-unsent",
            &[
                ("item", a.item),
                ("holder", &holder.item),
                ("cause", &cause),
            ],
        ))
    };
    let settings = host
        .accounts
        .ok_or_else(|| unsent("settings-unavailable".to_owned()))?;
    let root = holder
        .mail_root
        .as_deref()
        .map(Path::new)
        .ok_or_else(|| unsent("mail-root-unrecorded".to_owned()))?;
    let brief = match a.brief_file {
        Some(file) => std::fs::read_to_string(file)
            .map_err(|e| unsent(format!("brief-unreadable:{:?}", e.kind())))?,
        None => String::new(),
    };
    let dir = path.parent().unwrap_or(Path::new("")).join("join");
    std::fs::create_dir_all(&dir).map_err(|e| unsent(format!("dir:{:?}", e.kind())))?;
    let file = dir.join(format!("{}.{}.directive", a.item, env.round_id()));
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&file)
        .and_then(|mut f| {
            writeln!(f, "joined item={} holder={}", a.item, holder.item)?;
            if let Some(line) = holder.admitted_line() {
                writeln!(f, "{line}")?;
            }
            writeln!(f, "\n{brief}")
        })
        .map_err(|e| unsent(format!("write:{:?}", e.kind())))?;
    let sent = crate::mailbox::Mailbox::new(crate::effects::fleet_mailbox(settings).mail_program)
        .bounded(crate::mailbox::BOUND)
        .send_directive(
            &holder.item,
            crate::mailbox::Route::Local { root: Some(root) },
            &file,
            Some(&format!("join-{}", a.item)),
            Some(root),
        );
    let _ = std::fs::remove_file(&file);
    sent.map(drop)
        .map_err(|refusal| unsent(refusal.to_string()))
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
    // A standing lane's paths are judged in its own repository, the one its
    // holders are compared in: a request naming none takes the lane's, and
    // one naming another is refused.
    let standing = position.map(|i| &lanes[i]);
    if let Some(lane) = standing
        && handoff(lane, &intents)
    {
        return Err(Error::from(agent_runtime::Error::refused(
            "lane-admission-pending",
            &[("item", &lane.item)],
        )));
    }
    let repo = match standing.map(lane_repo) {
        None => r.repo.as_deref(),
        Some(lane_repo) => match (r.repo.as_deref(), lane_repo) {
            (None, lane_repo) => lane_repo,
            (Some(asked), lane_repo)
                if same_repo(Some(asked), lane_repo, None)
                    || (lane_repo.is_none()
                        && same_repo(Some(asked), lane_repo, own_repo(path, host)?.as_deref())) =>
            {
                Some(asked)
            }
            (Some(asked), lane_repo) => {
                return Err(Error::from(agent_runtime::Error::refused(
                    "lane-repo-conflict",
                    &[
                        ("item", &r.item),
                        ("repo", asked),
                        ("lane_repo", lane_repo.unwrap_or("none")),
                    ],
                )));
            }
        },
    };
    let standing_scope = position
        .and_then(|i| lanes[i].in_scope.clone())
        .unwrap_or_default();
    let in_scope = union(&standing_scope, &r.in_scope);
    let standing_paths = standing
        .map(|lane| {
            if lane.touched.is_none() && lane.tracker.is_none() {
                // A record with no tracker or set has no Location to carry.
                Ok(Vec::new())
            } else {
                required_paths(lane, lane.tracker.as_deref(), lane.repo.as_deref(), host)
            }
        })
        .transpose()?
        .unwrap_or_default();
    let added = folders(
        standing.and_then(|l| l.mail_root.as_deref()).map(Path::new),
        &r.paths,
    );
    let check = if standing.is_some_and(|l| l.touched.is_none()) {
        union(&standing_paths, &added)
    } else {
        added
    };
    let judged = judge(
        path,
        &lanes,
        &intents,
        &Admission {
            item: &r.item,
            tracker: r.tracker.as_deref(),
            repo,
            brief_file: r.brief_file.as_deref(),
            repo_dir: r.repo_dir.as_deref(),
            scope_range: r.scope_range.as_ref(),
            in_scope: &in_scope,
            paths: &check,
            launch: Launch::Added,
            read_only: position.is_some_and(|i| lanes[i].read_only),
        },
        env,
        host,
    )?;
    let Some(index) = position else {
        return Ok(PathsAdmitted {
            lane: None,
            touched: judged.touched,
            in_scope: judged.in_scope,
            recorded: false,
        });
    };
    let standing = &lanes[index];
    // The paths added are recorded for the lane's checkout, as a first
    // launch's are for the one it runs in ([`folders`]).
    let added = folders(
        standing.mail_root.as_deref().map(Path::new),
        &judged.touched,
    );
    let touched = union(&standing_paths, &added);
    widen(path, doc, index, standing, &touched, &judged.in_scope)?;
    Ok(PathsAdmitted {
        lane: Some(Box::new(lane_at(path, doc, index)?)),
        touched,
        in_scope: judged.in_scope,
        recorded: true,
    })
}

/// How long one read may take: a tracker call, or `harness-only` over a
/// range.
const READ_TIMEOUT: Duration = Duration::from_secs(60);
/// The runner tag the admission's reads are counted under.
const TAG: &str = "admission";

/// The linear package's `issues get ID --format=safe`
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
            crate::provider::cause_line(&host::stderr_text(&output))
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
                &["issues", "get", item, "--format=safe"],
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
                        crate::provider::cause_line(&failed.stderr)
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
    scope_paths: &Path,
    repo_dir: &Path,
    range: &ScopeRange,
) -> std::result::Result<Vec<String>, ReadFailure> {
    let dir = repo_dir.display().to_string();
    let stdout = read_stdout(
        "harness-only",
        scope_paths,
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
            crate::provider::cause_line(&host::stderr_text(&output))
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
/// names ([`crate::repo::of`]), `None` where it names neither, through the
/// one `gh api` transport: the open list paged to a short page, each pull
/// request read by number for its state and head. A closed one, a fork's
/// and a deleted fork's are left out. A repository that cannot be named, a
/// failed call, a 404, a member the documented shapes do not decode or a
/// state outside the documented pair is the failure, named by read.
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
        let same_repo = match &pull.head.repo {
            Nullable::Present(head) => head.full_name.eq_ignore_ascii_case(&repo),
            Nullable::Absent | Nullable::Null => false,
        };
        match pull.state.as_str() {
            "open" if same_repo => {}
            "open" | "closed" => continue,
            other => return Err(failed("pull", format!("#{number}: state {other:?}"))),
        }
        out.push(OpenPull {
            number,
            branch: pull.head.branch,
            body: pull.body,
            changed_files: pull.changed_files.present().copied(),
        });
    }
    Ok(Some(OpenPulls {
        repo: slug,
        pulls: out,
    }))
}

/// Read both sides of a rename. The files endpoint can truncate the list,
/// so its count must match the pull request's detail before it clears a path.
fn read_pull_files(
    clis: &Clis,
    repo: &str,
    pull: &OpenPull,
) -> std::result::Result<Vec<String>, ReadFailure> {
    let number = pull.number;
    let changed = pull
        .changed_files
        .ok_or_else(|| format!("#{number}: changed_files absent"))?;
    let repo = repo.to_ascii_lowercase();
    let gh = crate::watch::github::handle(&clis.gh);
    let files: Vec<PullFile> = gh
        .list(PULLS_READ, &format!("repos/{repo}/pulls/{number}/files"))
        .map_err(|e| format!("#{number}: {e}"))?
        .ok_or_else(|| format!("#{number}: not-found"))?;
    if files.len() as u64 != changed {
        return Err(format!("#{number}: {} of {changed} files", files.len()));
    }
    Ok(both_sides(files))
}

/// Each file's path, and its earlier one where it was renamed.
fn both_sides(files: Vec<PullFile>) -> Vec<String> {
    let mut paths = Vec::with_capacity(files.len());
    for file in files {
        paths.extend(file.previous_filename.present().cloned());
        paths.push(file.filename);
    }
    paths
}

/// The label the branch reads carry in a `gh` refusal.
const BRANCH_READ: &str = "holder-branch";

/// The most changed files the compare endpoint lists, for the whole
/// comparison (repos, "Compare two commits"): a list this long may be cut.
const COMPARE_FILES_MAX: usize = 300;

/// `GET /repos/{owner}/{repo}` (repos, `full-repository`): its default
/// branch, required.
#[derive(Deserialize)]
struct RepoDefault {
    default_branch: String,
}

/// `GET /repos/{owner}/{repo}/compare/{base}...{head}` (repos,
/// `commit-comparison`): the changed files from the merge base to the head,
/// `files` optional.
#[derive(Deserialize)]
struct Comparison {
    #[serde(default)]
    files: Option<Vec<PullFile>>,
}

/// The production branch read: the hosted lane's head, read on its host
/// ([`crate::watch::hosted::worktree_head`]), then GitHub's comparison of
/// that commit with the repository's default branch. GitHub compares commit
/// SHAs it holds, so a 404 is a head the lane has not pushed, whose commits
/// may change any path. A lane's fresh worktree stands on its base commit,
/// which GitHub holds.
fn read_branch_change(clis: &Clis, lane: &Lane) -> std::result::Result<BranchChange, BranchUnread> {
    let unread = |branch: Option<&str>, cause: String| BranchUnread {
        branch: branch.map(str::to_owned),
        cause,
    };
    let root = lane
        .mail_root
        .as_deref()
        .filter(|root| !root.is_empty())
        .ok_or_else(|| unread(None, "worktree-unrecorded".to_owned()))?;
    let head = crate::watch::hosted::worktree_head(
        &clis.scripts,
        crate::watch::hosted::host_of(lane),
        &lane.item,
        root,
    )
    .map_err(|()| unread(None, "head-unread".to_owned()))?;
    let branch = Some(head.branch.as_str());
    let repo = lane
        .repo
        .as_deref()
        .ok_or_else(|| unread(branch, "repo-unnamed".to_owned()))?
        .to_ascii_lowercase();
    let gh = crate::watch::github::handle(&clis.gh);
    let base: RepoDefault = gh
        .object(BRANCH_READ, &format!("repos/{repo}"))
        .map_err(|e| unread(branch, format!("repo-unread {e}")))?
        .ok_or_else(|| unread(branch, "repo-absent".to_owned()))?;
    let compared: Comparison = gh
        .object(
            BRANCH_READ,
            &format!(
                "repos/{repo}/compare/{}...{}",
                base.default_branch, head.head
            ),
        )
        .map_err(|e| unread(branch, format!("compare-unread {e}")))?
        .ok_or_else(|| unread(branch, format!("head-unpushed head={}", head.head)))?;
    let files = compared
        .files
        .ok_or_else(|| unread(branch, "files-absent".to_owned()))?;
    if files.len() >= COMPARE_FILES_MAX {
        return Err(unread(
            branch,
            format!("files-capped files={}", files.len()),
        ));
    }
    Ok(BranchChange {
        files: both_sides(files),
        branch: head.branch,
        head: head.head,
    })
}

#[allow(
    clippy::disallowed_methods,
    reason = "the rows write the brief and fleet fixtures they judge"
)]
#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;

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
                    branch: unplanted_branch(),
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
            launch: Launch::Added,
            read_only: false,
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
        let rows: [(&str, std::result::Result<Vec<&str>, &str>); 12] = [
            ("**Location**: `src/a.sh`", Ok(vec!["src/a.sh"])),
            (
                "**Location**: `skills/x/a.rs` (`location_paths`, the `--overseer` flag)",
                Ok(vec!["skills/x/a.rs"]),
            ),
            (
                "**Location**: the `--overseer` branch of `location_paths`",
                Err("location"),
            ),
            (
                "**Location**: `Cargo.toml` (`[workspace.dependencies]`), `Cargo.lock`",
                Ok(vec!["Cargo.toml", "Cargo.lock"]),
            ),
            (
                "**Location**: `skills/a/SKILL.md` (Tests), `skills/b/x.md`, `src/c.rs`, \
                 with their `.agents/skills` renders.",
                Ok(vec![
                    "skills/a/SKILL.md",
                    "skills/b/x.md",
                    "src/c.rs",
                    ".agents/skills/a/SKILL.md",
                    ".agents/skills/b/x.md",
                ]),
            ),
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
    fn text_names_the_tokens_that_read_as_paths() {
        let rows: [(&str, &[&str]); 9] = [
            ("", &[]),
            (
                "Edit `src/a.sh` and `docs/`. Run `cargo test`, pass `--json`, see \
                 `https://x.y/z`, read `README.md`, line `src/b.rs:12`.",
                &["src/a.sh", "docs/", "README.md", "src/b.rs"],
            ),
            (
                "`.gitignore`, `pnpm-lock.yaml`, `kendex.settings.toml.example`",
                &[
                    ".gitignore",
                    "pnpm-lock.yaml",
                    "kendex.settings.toml.example",
                ],
            ),
            (
                "`ticks`, `Error::refused`, `classify()`, `0.4.1`, `-x/y`, `e.g.`, `rust-version`",
                &[],
            ),
            ("the `.agents/skills/` tree", &[".agents/skills/"]),
            (
                "`docs/x.md` and its `.agents/skills` render",
                &["docs/x.md", ".agents/skills/"],
            ),
            (
                "`kendex-local.toml` (`[skill-instructions]`) and the `.agents/skills/` renders it writes",
                &["kendex-local.toml", ".agents/skills/"],
            ),
            (
                "`crates/r.rs`, `skills/a/SKILL.md` and their `.agents/skills/` renders",
                &[
                    "crates/r.rs",
                    "skills/a/SKILL.md",
                    ".agents/skills/a/SKILL.md",
                ],
            ),
            (
                "`skills/` and its `.agents/skills/` render",
                &["skills/", ".agents/skills/"],
            ),
        ];
        for (text, expected) in rows {
            assert_eq!(
                named_paths(text, PathSource::Location),
                expected,
                "{text:?}"
            );
        }
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
            // A folder entry meets by its string, with or without its `/`:
            // a folder on a lane's host alone, a submodule's gitlink a pull
            // request names bare, a file a branch replaced with a folder.
            (s(&["src"]), s(&["src/a.sh"]), s(&[]), s(&["src/a.sh"])),
            (
                s(&["vendor/lib/"]),
                s(&["vendor/lib"]),
                s(&[]),
                s(&["vendor/lib/"]),
            ),
            // A name that only begins another is no folder of it.
            (s(&["src/a"]), s(&["src/ab.sh"]), s(&[]), s(&[])),
            (s(&["src/a.sh"]), s(&["src/a.sh"]), s(&["src"]), s(&[])),
            (s(&["changelog.d/"]), s(&["changelog.d"]), s(&[]), s(&[])),
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
            body: Nullable::Null,
            changed_files: None,
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
        );
        assert!(judged.is_ok(), "a done lane holds nothing: {judged:?}");
    }

    /// A live holder with no recorded set is read from its item, once, and
    /// one whose item cannot be read blocks; a holder of another repository
    /// is never read.
    #[test]
    fn a_holder_without_a_touched_set_is_read_from_its_item_or_blocks_unread() {
        let planted = Planted {
            items: [
                ("KEN-L".to_owned(), body("`src/a.sh`")),
                ("KEN-H".to_owned(), body("`src/b.sh`")),
                (
                    "KEN-U".to_owned(),
                    Err("issue-read exit 1: refused".to_owned()),
                ),
                ("KEN-T".to_owned(), body("src/a.sh (unticked)")),
            ]
            .into(),
            readings: [(
                12,
                Reading::Live(Identity {
                    pid: 12,
                    start: "ticks:1".into(),
                }),
            )]
            .into(),
            ranges: Vec::new(),
            reads: RefCell::new(Vec::new()),
        };
        let mut other = holder("KEN-O", "running", 12, None);
        other.repo = Some("o/other".into());
        let lanes = vec![holder("KEN-H", "running", 12, None), other];
        judge(
            &fleet_path(),
            &lanes,
            &[],
            &admission("KEN-L", &[]),
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap();
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
            readings: [(
                11,
                Reading::Live(Identity {
                    pid: 11,
                    start: "ticks:1".into(),
                }),
            )]
            .into(),
            ranges: vec![
                "src/c.sh".to_owned(),
                "changelog.d/orch/x.md".to_owned(),
                "changelog.d".to_owned(),
            ],
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
            let lanes = vec![holder("KEN-H", "running", 11, Some(vec![held]))];
            let err = judge(
                &fleet_path(),
                &lanes,
                &[],
                &full,
                &env(),
                &planted.host(&planted.still_runs()),
            )
            .unwrap_err();
            assert_eq!(err.key(), "launch-overlap", "{held} overlaps");
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

    fn judge_brief_against_holder(text: &str) -> Judged {
        let dir = tempfile::tempdir().unwrap();
        let brief = dir.path().join("brief.md");
        std::fs::write(&brief, text).unwrap();
        let identity = Identity {
            pid: 11,
            start: "ticks:1".into(),
        };
        let planted = Planted {
            items: [("KEN-L".to_owned(), body("`src/portal.sh`"))].into(),
            readings: [(identity.pid, Reading::Live(identity))].into(),
            ranges: Vec::new(),
            reads: RefCell::new(Vec::new()),
        };
        let mut held = holder(
            "KEN-H",
            "running",
            11,
            Some(vec!["scripts/sandbox-shots.sh"]),
        );
        held.mail_root = Some(dir.path().display().to_string());
        judge(
            &dir.path().join("workflow-state-oversee.json"),
            &[held],
            &[],
            &Admission {
                brief_file: Some(&brief),
                launch: Launch::First(dir.path()),
                ..admission("KEN-L", &[])
            },
            &env(),
            &planted.host(&planted.still_runs()),
        )
        .unwrap()
    }

    #[test]
    fn do_not_edit_brief_paths_leave_the_holder_alone() {
        // KEN-5910's reported brief and the same direction with the path as its object.
        for brief in [
            "KEN-H holds `scripts/sandbox-shots.sh`; ask for screenshot units, do not edit it.",
            "Do not edit `scripts/sandbox-shots.sh:14`. Do not edit `src/portal.sh`.",
        ] {
            let judged = judge_brief_against_holder(brief);
            assert_eq!(judged.join, None, "{brief}");
            assert_eq!(judged.touched, ["src/portal.sh"], "{brief}");
        }
    }

    #[test]
    fn edit_brief_paths_still_join_the_holder() {
        for brief in [
            "Edit `scripts/sandbox-shots.sh`.",
            "Edit `scripts/sandbox-shots.sh` for portal coverage. Do not edit `scripts/sandbox-shots.sh` for clock coverage.",
        ] {
            let judged = judge_brief_against_holder(brief);
            assert_eq!(
                judged.join,
                Some(Join {
                    holder: 0,
                    tie: Tie::File("scripts/sandbox-shots.sh".into()),
                    paths: vec!["scripts/sandbox-shots.sh".into()],
                }),
                "{brief}"
            );
        }
    }

    fn blank_fleet(at: &Path) -> PathBuf {
        let path = fleet_file(at);
        let mut doc = crate::ops::loaded(&path).unwrap().doc;
        doc.insert("lanes".into(), json!([]));
        doc.insert("intents".into(), json!([]));
        std::fs::write(&path, serde_json::to_vec(&doc).unwrap()).unwrap();
        path
    }

    fn call(path: &Path, request: &Value, host: &Host) -> Result<super::super::Applied> {
        let request = serde_json::from_value(request.clone()).unwrap();
        let env = Env {
            nonce: NONCES.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            ..env()
        };
        super::super::apply_on(path, &request, &env, LOCK, host)
    }

    fn launch_request(item: &str, root: &Path, repo: Option<&str>, brief: &Path) -> Value {
        json!({
            "op": "launch-lane", "item": item, "repo": repo, "mail_root": root, "brief_file": brief,
            "harness": "claude", "model": "claude-opus-5-5", "class": "standard", "class_reason": "test",
        })
    }

    fn keep_request(item: &str) -> Value {
        json!({
            "op": "close-owned-resources", "item": item,
            "no_landing": { "reason": "restart-recovery", "source": "test" },
        })
    }

    fn settle(path: &Path, id: &str, outcome: &str, host: &Host) {
        call(
            path,
            &json!({"op": "record-outcome", "intent_id": id, "outcome": outcome, "launch": {"pid": 6001, "start": "ticks:6001"}}),
            host,
        )
        .unwrap();
    }

    fn contenders(path: &Path, host: &Host, states: &[(Option<&str>, bool)]) {
        for &(repo, held) in states {
            let got = call(
                path,
                &json!({
                    "op": "admit-paths", "item": "KEN-C", "repo": repo, "paths": ["src/shared.rs"],
                }),
                host,
            );
            if held {
                assert!(
                    matches!(got, Err(Error::LaunchOverlap { .. })),
                    "{repo:?} {got:?}"
                );
            } else {
                assert!(got.is_ok(), "{repo:?} {got:?}");
            }
        }
    }

    #[test]
    fn confirmed_park_or_close_releases_but_failed_recovery_preserves_the_prior_authority() {
        for hosted in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let path = blank_fleet(dir.path());
            let brief = dir.path().join("brief");
            std::fs::write(&brief, "Edit `src/shared.rs`.").unwrap();
            let mut launch = launch_request("KEN-L", dir.path(), None, &brief);
            if hosted {
                launch["host"] = json!("example");
            }
            let host = host();
            let checks = |held| contenders(&path, &host, &[(None, held)]);
            let issue = |request: &Value| intent_id(&call(&path, request, &host).unwrap());
            let keep = keep_request("KEN-L");
            let full = json!({"op": "close-owned-resources", "item": "KEN-L",
                "ended": {"source": "test"}});
            let id = issue(&launch);
            checks(true);
            settle(&path, &id, "failed", &host);
            checks(false);
            let id = issue(&launch);
            settle(&path, &id, "confirmed", &host);
            checks(true);
            let id = issue(&keep);
            settle(&path, &id, "unconfirmed", &host);
            checks(true);
            settle(&path, &id, "failed", &host);
            checks(true);
            settle(&path, &issue(&keep), "confirmed", &host);
            checks(true);
            settle(&path, &issue(&launch), "failed", &host);
            checks(true);

            if hosted {
                let park = json!({"op":"park-lane", "item":"KEN-L", "repo":"o/r",
                    "head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "hold":true});
                let mut owed = park.clone();
                owed["owed"] = json!(true);
                call(&path, &owed, &host).unwrap();
                checks(true);
                call(&path, &park, &host).unwrap();
                checks(false);
                settle(&path, &issue(&launch), "failed", &host);
                checks(false);
            } else {
                settle(&path, &issue(&full), "failed", &host);
                checks(true);
                settle(&path, &issue(&full), "confirmed", &host);
                checks(false);
                settle(&path, &issue(&launch), "failed", &host);
                checks(false);
            }
        }
    }

    #[test]
    fn a_connected_move_has_two_claims_through_supersession_and_restores_the_retry_binding() {
        let dir = tempfile::tempdir().unwrap();
        let path = blank_fleet(dir.path());
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        let brief = dir.path().join("brief");
        std::fs::write(&brief, "Edit `src/shared.rs`.").unwrap();
        let settings = crate::settings::load(
            &agent_runtime::settings::Roots {
                project: a.clone(),
                common: a.clone(),
            },
            &[("ORCH_CONNECTED_REPOS".into(), "owner/b".into())],
            &crate::settings::Flags {
                state_dir: None,
                private_env: false,
            },
        )
        .unwrap();
        let mut host = host().judging(&settings);
        host.admission.as_mut().unwrap().checkout = Box::new(|_, root| {
            let is_b = root == b;
            Ok(Some(Repository {
                root: if is_b { b.clone() } else { a.clone() },
                slug: Some(if is_b { "owner/b" } else { "owner/a" }.into()),
            }))
        });
        let issue = |request: &Value| intent_id(&call(&path, request, &host).unwrap());
        let mut first = launch_request("KEN-L", &a, None, &brief);
        first["host"] = json!("source-host");
        let first_id = issue(&first);
        call(
            &path,
            &json!({"op": "record-outcome", "intent_id": first_id,
            "outcome": "confirmed", "mail_root": "/source-host/checkout"}),
            &host,
        )
        .unwrap();
        let keep = keep_request("KEN-L");
        settle(&path, &issue(&keep), "confirmed", &host);
        contenders(
            &path,
            &host,
            &[
                (Some("OWNER/A"), true),
                (Some("owner/b"), false),
                (Some("owner/c"), false),
            ],
        );

        let other = launch_request("KEN-B", &b, Some("owner/b"), &brief);
        let blocker = issue(&other);
        let before = std::fs::read(&path).unwrap();
        let destination = launch_request("KEN-L", &b, Some("OWNER/B"), &brief);
        assert!(matches!(
            call(&path, &destination, &host),
            Err(Error::LaunchOverlap { .. })
        ));
        assert_eq!(std::fs::read(&path).unwrap(), before);
        settle(&path, &blocker, "failed", &host);

        let both = [(None, true), (Some("owner/b"), true)];
        let id = issue(&destination);
        contenders(&path, &host, &both);
        settle(&path, &id, "failed", &host);
        let restored = lane(&path, "KEN-L");
        assert_eq!(restored.repo, None);
        assert_eq!(restored.host.as_deref(), Some("source-host"));
        assert_eq!(restored.mail_root.as_deref(), Some("/source-host/checkout"));
        assert_eq!(restored.extra["checkout"], json!(a));
        contenders(&path, &host, &[(None, true), (Some("owner/b"), false)]);

        for cloud in [false, true] {
            let mut destination = destination.clone();
            let mut observation = if cloud {
                destination["host"] = json!("claude-cloud");
                json!({"cloud_create":"pending"})
            } else {
                json!({"pane":"%1"})
            };
            let id = issue(&destination);
            observation["cause"] = json!(super::super::SUPERSEDED_LAUNCH);
            call(
                &path,
                &json!({"op":"record-outcome", "intent_id":id, "outcome":"failed",
                "observation": observation}),
                &host,
            )
            .unwrap();
            // After the superseding outcome and before a close exists, both
            // repositories still have a writer or an older recovery claim.
            contenders(&path, &host, &both);
            assert_eq!(
                call(&path, &destination, &host).unwrap_err().key(),
                "intent-open"
            );
            let mut observed_keep = keep.clone();
            if cloud {
                assert_eq!(
                    call(&path, &keep, &host).unwrap_err().key(),
                    "cloud-writer-unsettled"
                );
                contenders(&path, &host, &both);
                observed_keep["no_landing"]["source"] = json!("cloud-writer-absent");
            }
            let close = issue(&observed_keep);
            contenders(&path, &host, &both);
            settle(&path, &close, "confirmed", &host);
            contenders(&path, &host, &[(None, true), (Some("owner/b"), false)]);
        }

        let id = issue(&destination);
        settle(&path, &id, "confirmed", &host);
        contenders(&path, &host, &[(None, false), (Some("owner/b"), true)]);
    }

    #[test]
    fn legacy_location_survives_each_widening_and_open_close_refuses_writes() {
        for mode in ["paths", "file", "blocker"] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().canonicalize().unwrap();
            let path = blank_fleet(&root);
            let mut doc = crate::ops::loaded(&path).unwrap().doc;
            doc.insert(
                "lanes".into(),
                json!([{
                    "item":"KEN-L", "tracker":"linear", "status":"running",
                    "harness":"claude", "surface":"gui", "mail_root": root,
                }]),
            );
            std::fs::write(&path, serde_json::to_vec(&doc).unwrap()).unwrap();
            let mail = root.join("lane-mail");
            std::fs::write(
                &mail,
                "#!/bin/sh\nprintf 'lane-mail: sent item=KEN-L id=joined monitor=none\\n'\n",
            )
            .unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&mail, std::fs::Permissions::from_mode(0o700)).unwrap();
            }
            let settings = crate::settings::load(
                &agent_runtime::settings::Roots {
                    project: root.clone(),
                    common: root.clone(),
                },
                &[("LANE_MAIL_CLI".into(), mail.as_os_str().to_owned())],
                &crate::settings::Flags {
                    state_dir: None,
                    private_env: false,
                },
            )
            .unwrap();
            let mut candidate = body("`src/new.rs`").unwrap();
            if mode == "blocker" {
                candidate.blocked_by_launch = Some(vec!["KEN-L".into()]);
            }
            let planted = Planted {
                items: [
                    ("KEN-L".into(), body("`src/shared.rs`, `src/legacy/`")),
                    ("KEN-X".into(), Ok(candidate)),
                ]
                .into(),
                readings: BTreeMap::new(),
                ranges: Vec::new(),
                reads: RefCell::new(Vec::new()),
            };
            let still_runs = planted.still_runs();
            let host = planted.host(&still_runs).judging(&settings);
            let brief = root.join("brief");
            std::fs::write(
                &brief,
                if mode == "file" {
                    "Edit `src/legacy/deep.rs`."
                } else {
                    "Edit `src/new.rs`."
                },
            )
            .unwrap();
            let mut candidate = launch_request("KEN-X", &root, None, &brief);
            candidate["tracker"] = json!("linear");
            let widen = json!({"op":"admit-paths", "item":"KEN-L", "paths":["src/new.rs"]});

            // Stage the recovery via the native record adapter. Its close
            // carries the same fallback as a managed transition.
            let env = env();
            let native_close = super::super::records::Record::decode(&json!({
                "op":"record-surface-lane", "step":"close", "item":"KEN-L"
            }))
            .unwrap()
            .unwrap();
            let closing =
                super::super::records::apply_record(&path, &native_close, &settings, &env, LOCK)
                    .unwrap();
            let id = closing["intent"]["id"].as_str().unwrap();
            assert_eq!(
                call(&path, &widen, &host).unwrap_err().key(),
                "lane-admission-pending"
            );
            if mode != "paths" {
                assert_eq!(
                    call(&path, &candidate, &host).unwrap_err().key(),
                    if mode == "blocker" {
                        "launch-blocked"
                    } else {
                        "launch-overlap"
                    }
                );
            }
            let observed = root.join("observed");
            std::fs::write(
                &observed,
                json!({"intent_id":id, "outcome":"failed", "evidence":"no stop"}).to_string(),
            )
            .unwrap();
            let merge = super::super::records::Record::decode(&json!({
                "op":"record-surface-lane", "step":"merge", "item":"KEN-L", "file":observed
            }))
            .unwrap()
            .unwrap();
            super::super::records::apply_record(&path, &merge, &settings, &env, LOCK).unwrap();

            if mode == "paths" {
                call(&path, &widen, &host).unwrap();
            } else {
                let reply = call(&path, &candidate, &host).unwrap();
                assert!(matches!(reply.report, super::super::Report::Joined(_)));
            }
            assert!(lane(&path, "KEN-L").admitted_line().is_none());
            let touched = lane(&path, "KEN-L").touched.unwrap();
            assert!(touched.iter().any(|p| p == "src/legacy/"));
            contenders(&path, &host, &[(None, true)]);
        }
    }

    #[test]
    fn review_overlap_gives_the_earlier_writer_recovery_precedence() {
        for (stop, retry) in [
            (["KEN-A", "KEN-B"], ["KEN-B", "KEN-A"]),
            (["KEN-B", "KEN-A"], ["KEN-A", "KEN-B"]),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = blank_fleet(dir.path());
            let mut doc = crate::ops::loaded(&path).unwrap().doc;
            doc.insert(
                "lanes".into(),
                json!([{
                    "item":"KEN-A", "status":"running", "touched":["src/shared.rs"],
                    "file_hold":"exclusive", "pending_pr":{"pr":1,"head":"abc"},
                    "launch":{"pid":6000,"start":"ticks:6000"},
                }]),
            );
            std::fs::write(&path, serde_json::to_vec(&doc).unwrap()).unwrap();
            let settings = crate::settings::load(
                &agent_runtime::settings::Roots {
                    project: dir.path().into(),
                    common: dir.path().into(),
                },
                &[("ORCH_DELIVERY".into(), "push-base".into())],
                &crate::settings::Flags {
                    state_dir: None,
                    private_env: false,
                },
            )
            .unwrap();
            let a_live = std::cell::Cell::new(true);
            let reads = |identity: &Identity| {
                if identity.pid == 6000 && a_live.get() {
                    Reading::Live(identity.clone())
                } else {
                    Reading::Gone
                }
            };
            let mut host = host().judging(&settings);
            host.still_runs = &reads;
            let brief = dir.path().join("brief");
            std::fs::write(&brief, "Edit `src/shared.rs`.").unwrap();
            let issue = |request: &Value| intent_id(&call(&path, request, &host).unwrap());
            let b = launch_request("KEN-B", dir.path(), None, &brief);
            settle(&path, &issue(&b), "confirmed", &host);
            assert_eq!(lane(&path, "KEN-B").file_hold, Some(FileHold::Shared));
            for item in stop {
                settle(&path, &issue(&keep_request(item)), "confirmed", &host);
                if item == "KEN-A" {
                    a_live.set(false);
                }
            }
            for item in retry {
                let reply = call(
                    &path,
                    &launch_request(item, dir.path(), None, &brief),
                    &host,
                );
                if item == "KEN-A" {
                    // Leave A in preparation so B must meet it in either order.
                    assert!(reply.is_ok(), "{reply:?}");
                } else {
                    assert!(
                        matches!(reply, Err(Error::LaunchOverlap { .. })),
                        "{reply:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn append_only_permission_does_not_become_an_exclusive_recovery_hold() {
        let dir = tempfile::tempdir().unwrap();
        let path = blank_fleet(dir.path());
        let brief = dir.path().join("brief");
        std::fs::write(&brief, "Edit `src/shared.rs`.").unwrap();
        let host = host();
        let issue = |request: &Value| intent_id(&call(&path, request, &host).unwrap());
        let a = launch_request("KEN-A", dir.path(), None, &brief);
        let mut append = launch_request("KEN-B", dir.path(), None, &brief);
        append["in_scope"] = json!(["src/shared.rs"]);
        settle(&path, &issue(&a), "confirmed", &host);
        settle(&path, &issue(&append), "confirmed", &host);
        settle(&path, &issue(&keep_request("KEN-A")), "confirmed", &host);
        settle(&path, &issue(&keep_request("KEN-B")), "confirmed", &host);
        contenders(&path, &host, &[(None, true)]);
        settle(
            &path,
            &issue(&json!({
                "op":"close-owned-resources", "item":"KEN-A", "ended":{"source":"test"}
            })),
            "confirmed",
            &host,
        );
        contenders(&path, &host, &[(None, false)]);
    }

    #[test]
    fn a_yielding_legacy_stop_checks_its_full_location_before_acquiring_recovery() {
        for (body, error) in [
            (body("`src/shared.rs`"), "launch-overlap"),
            (Ok(ItemRead::default()), "touched-unreadable"),
            (Err("tracker-unavailable".into()), "touched-unreadable"),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let path = blank_fleet(dir.path());
            let mut doc = crate::ops::loaded(&path).unwrap().doc;
            doc.insert("lanes".into(), json!([
                {"item":"KEN-A", "status":"stopped", "touched":["src/shared.rs"], "file_hold":"retained"},
                {"item":"KEN-B", "status":"stopped", "tracker":"linear", "host":"example"},
            ]));
            std::fs::write(&path, serde_json::to_vec(&doc).unwrap()).unwrap();
            let planted = Planted {
                items: [("KEN-B".into(), body)].into(),
                readings: BTreeMap::new(),
                ranges: Vec::new(),
                reads: RefCell::new(Vec::new()),
            };
            let still_runs = planted.still_runs();
            let host = planted.host(&still_runs);
            for reason in ["restart-recovery", "keep-sandbox"] {
                let before = std::fs::read(&path).unwrap();
                let mut keep = keep_request("KEN-B");
                keep["no_landing"]["reason"] = json!(reason);
                let refusal = call(&path, &keep, &host).unwrap_err();
                assert_eq!(refusal.key(), error);
                assert_eq!(std::fs::read(&path).unwrap(), before);
            }
            let full =
                json!({"op":"close-owned-resources", "item":"KEN-B", "ended":{"source":"test"}});
            let id = intent_id(&call(&path, &full, &host).unwrap());
            settle(&path, &id, "confirmed", &host);
        }
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
