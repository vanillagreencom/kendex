//! The report cadence and owner report share one snapshot window. Files
//! advance cadence; only mailbox attachment receipts advance the owner window.

use agent_runtime::record::Document;
use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::{clock, host};
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::mailbox::{Envelope, Mailbox, Refusal};
use crate::settings::Settings;
use crate::state::{self, Lane, LaneStatus};
use crate::watch::{Body, Change, Event, Produced, Runner, Tick};

pub const DUE_ROW: &str = "report-due";
const FLEET: &str = "fleet";
const BOUND: Duration = Duration::from_secs(300);
const TAG: &str = "report";
const GITHUB_CLI_DEFAULT: &str = ".agents/skills/github/scripts/github.sh";
const LOOKBACK: u64 = 604800;

pub const ENABLED_KEY: &str = "ORCH_REPORT";
pub const MINUTES_KEY: &str = "ORCH_REPORT_EVERY_MINUTES";
pub const ISSUES_KEY: &str = "ORCH_REPORT_EVERY_ISSUES";
pub const UPCOMING_KEY: &str = "ORCH_REPORT_UPCOMING";
pub const QUIET_HOURS_KEY: &str = "ORCH_REPORT_QUIET_HOURS";
pub const ZONE_KEY: &str = "ORCH_OWNER_TIME_ZONE";
/// The report's settings, which the settings load carries as their text, an
/// empty value kept, for the report alone to judge.
pub const KEYS: [&str; 6] = [
    ENABLED_KEY,
    MINUTES_KEY,
    ISSUES_KEY,
    UPCOMING_KEY,
    QUIET_HOURS_KEY,
    ZONE_KEY,
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Policy {
    pub enabled: bool,
    pub minutes: u64,
    pub issues: u64,
    pub upcoming: u64,
    pub quiet: Option<(i8, i8)>,
    pub zone: String,
}

impl Policy {
    pub fn read(get: impl Fn(&str) -> Option<String>) -> Result<Self> {
        let invalid = |key: &str, value: &str| -> Error {
            agent_runtime::Error::refused("settings-invalid", &[("key", key), ("value", value)])
                .into()
        };
        let whole = |key: &str, default: &str, empty: bool| -> Result<u64> {
            let value = get(key).unwrap_or_else(|| default.to_owned());
            if empty && value.is_empty() {
                return Ok(0);
            }
            if value.is_empty()
                || !value.bytes().all(|c| c.is_ascii_digit())
                || (value != "0" && value.starts_with('0'))
            {
                return Err(invalid(key, &value));
            }
            value.parse().map_err(|_| invalid(key, &value))
        };
        let enabled = match get(ENABLED_KEY).as_deref().unwrap_or("on") {
            "on" => true,
            "off" => false,
            value => return Err(invalid(ENABLED_KEY, value)),
        };
        let hours = get(QUIET_HOURS_KEY).unwrap_or_else(|| "0-7".to_owned());
        let quiet = if hours.is_empty() {
            None
        } else {
            let parse = || -> Option<(i8, i8)> {
                let (a, b) = hours.split_once('-')?;
                if a.is_empty()
                    || b.is_empty()
                    || !a.bytes().all(|c| c.is_ascii_digit())
                    || !b.bytes().all(|c| c.is_ascii_digit())
                {
                    return None;
                }
                if (a.len() > 1 && a.starts_with('0')) || (b.len() > 1 && b.starts_with('0')) {
                    return None;
                }
                let (a, b): (i8, i8) = (a.parse().ok()?, b.parse().ok()?);
                (a != b && (0..24).contains(&a) && (0..24).contains(&b)).then_some((a, b))
            };
            Some(parse().ok_or_else(|| invalid(QUIET_HOURS_KEY, &hours))?)
        };
        let zone = get(ZONE_KEY).unwrap_or_else(|| "America/Los_Angeles".to_owned());
        jiff::tz::TimeZone::get(&zone).map_err(|_| invalid(ZONE_KEY, &zone))?;
        Ok(Self {
            enabled,
            minutes: whole(MINUTES_KEY, "120", true)?,
            issues: whole(ISSUES_KEY, "0", false)?,
            upcoming: whole(UPCOMING_KEY, "5", false)?,
            quiet,
            zone,
        })
    }

    /// The policy from the settings' text. A value outside its form refuses
    /// the report's verb and its duty's pass, and no other verb.
    pub fn of(settings: &Settings) -> Result<Self> {
        Self::read(|key| {
            settings
                .report
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
        })
    }

    pub fn quiet_at(&self, now: u64) -> Result<bool> {
        let Some((start, end)) = self.quiet else {
            return Ok(false);
        };
        let stamp: jiff::Timestamp = clock::iso_utc(now)
            .parse()
            .map_err(|_| unjudged(&[("cause", "clock")]))?;
        let zone =
            jiff::tz::TimeZone::get(&self.zone).map_err(|_| unjudged(&[("cause", "zone")]))?;
        let hour = stamp.to_zoned(zone).hour();
        Ok(if start < end {
            hour >= start && hour < end
        } else {
            hour >= start || hour < end
        })
    }
}

pub struct Context {
    pub fleet: PathBuf,
    pub settings: Settings,
    pub github: PathBuf,
    pub gh: PathBuf,
    pub repos: Vec<String>,
    pub shared: super::tracker::Shared,
}

pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| run(&ctx, tick))
}

impl Context {
    /// The report over the fleet record at `fleet`, reading GitHub through
    /// `gh` on `PATH` and the timeline through the project's github skill.
    pub fn new(
        fleet: PathBuf,
        settings: &Settings,
        repos: Vec<String>,
        shared: super::tracker::Shared,
    ) -> Context {
        Context {
            fleet,
            github: settings.roots.project.join(GITHUB_CLI_DEFAULT),
            settings: settings.clone(),
            repos,
            gh: PathBuf::from("gh"),
            shared,
        }
    }
}

pub fn register(
    runner: &mut Runner<'_>,
    path: &Path,
    settings: &Settings,
    repos: Vec<String>,
    shared: super::tracker::Shared,
) {
    runner.register(
        crate::schedule::Duty::Report,
        body(Context::new(path.to_path_buf(), settings, repos, shared)),
    );
}

fn unjudged(fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused("report-unjudged", fields).into()
}

#[allow(
    clippy::disallowed_methods,
    reason = "the report reads its fleet snapshot through the store"
)]
fn load_fleet(path: &Path) -> Result<Document> {
    Ok(state::load(path)?
        .ok_or_else(|| {
            Error::Runtime(agent_runtime::Error::RecordMissing {
                path: path.to_path_buf(),
            })
        })?
        .doc)
}

fn lanes(doc: &Document) -> Result<Vec<Lane>> {
    serde_json::from_value(doc.get("lanes").cloned().unwrap_or_else(|| json!([])))
        .map_err(|e| unjudged(&[("cause", &e.to_string())]))
}

struct Window {
    latest: Option<u64>,
    owner: Option<u64>,
}

#[allow(
    clippy::disallowed_methods,
    reason = "report windows compare report file times with actual mailbox attachment receipts"
)]
fn window(ctx: &Context, doc: &Document, session_start: Option<u64>) -> Result<Window> {
    let events =
        Mailbox::new(ctx.settings.lane_mail_cli.clone()).events(&ctx.settings.roots.common)?;
    let attachments: BTreeSet<PathBuf> = events
        .iter()
        .filter(|e| e.kind() == "notice" && e.to.as_deref() == Some("owner"))
        .filter_map(|e| e.attach.as_deref())
        .map(PathBuf::from)
        .collect();
    let mut latest = None;
    let mut owner = None;
    let dir = &ctx.settings.store.progress_report_dir;
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => Some(entries),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            return Err(unjudged(&[
                ("path", &dir.display().to_string()),
                ("cause", &e.to_string()),
            ]));
        }
    };
    for entry in entries.into_iter().flatten() {
        let entry = entry.map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
        if !super::retention::is_progress_report(&entry.file_name().to_string_lossy()) {
            continue;
        }
        let meta = entry
            .metadata()
            .map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
        if !meta.is_file() {
            continue;
        }
        let at = meta
            .modified()
            .and_then(|t| t.duration_since(UNIX_EPOCH).map_err(std::io::Error::other))
            .map_err(|e| unjudged(&[("cause", &e.to_string())]))?
            .as_secs();
        latest = Some(latest.unwrap_or(0).max(at));
        let path = entry
            .path()
            .canonicalize()
            .map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
        if attachments.contains(&path) {
            owner = Some(owner.unwrap_or(0).max(at));
        }
    }
    let start = match session_start {
        Some(start) => Some(start),
        None => {
            let mut start = None;
            for lane in doc
                .get("lanes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let Some(stamp) = field(lane, "launched_at") else {
                    continue;
                };
                // An unread launch is never passed over: the fleet start it
                // might be would move every window.
                let at = clock::epoch_secs(stamp).ok_or_else(|| {
                    unjudged(&[
                        ("cause", "launched-at"),
                        ("item", field(lane, "item").unwrap_or("-")),
                    ])
                })?;
                start = Some(start.map_or(at, |s: u64| s.min(at)));
            }
            start
        }
    };
    Ok(Window {
        latest: latest.or(start),
        owner: owner.or(start),
    })
}

fn repos(ctx: &Context) -> Vec<String> {
    let mut repos = Vec::new();
    for name in ctx.repos.iter().chain(&ctx.settings.reads.connected_repos) {
        let name = name.to_ascii_lowercase();
        if !repos.contains(&name) {
            repos.push(name);
        }
    }
    repos
}

fn completions(
    ctx: &Context,
    doc: &Document,
    since: u64,
    now: u64,
) -> Result<Vec<super::github::Completion>> {
    let gh = super::github::handle(&ctx.gh);
    let mut rows = super::github::report_merges(&gh, &repos(ctx), &lanes(doc)?, since, now)?;
    for row in doc
        .get("fleet_log")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if field(row, "kind") != Some("cycle") {
            continue;
        }
        let Some(at) = field(row, "at").and_then(clock::epoch_secs) else {
            return Err(unjudged(&[("cause", "cycle-time")]));
        };
        let Some(text) = field(row, "text") else {
            continue;
        };
        if at >= since && at < now && text.starts_with("cycle item=") && text.contains(" commit=") {
            rows.push(super::github::Completion {
                item: field(row, "item").unwrap_or("-").to_owned(),
                repo: String::new(),
                number: 0,
                at,
                title: "direct push".to_owned(),
            });
        }
    }
    rows.sort_by_key(|r| r.at);
    Ok(rows)
}

/// One row of the tracker CLI's safe issue list: the fields the created
/// count and the linked section read.
#[derive(serde::Deserialize)]
struct Created {
    id: String,
    title: String,
    url: String,
    created_at: String,
    parent_id: String,
    blocks: Vec<String>,
    blocked_by: Vec<String>,
    related: Vec<String>,
}

/// The issues created in `[since, now)` across every team: one whole list
/// from the window's start with no team filter, so the count is never one
/// team's or one page's. `None` is a read that failed or did not parse;
/// the cell prints unread and the cause goes to stderr.
fn created(ctx: &Context, since: u64, now: u64) -> Option<Vec<Created>> {
    let from = clock::iso_utc(since);
    let read = escapes::command(
        &ctx.settings.roots.project,
        &ctx.settings.reads.tracker_cli,
        &[
            "issues",
            "list",
            "--created-since",
            &from,
            "--max",
            "--format=safe",
        ],
        120,
    )
    .map_err(|failure| match failure {
        escapes::Failure::NotStarted => "no-linear-cli",
        escapes::Failure::TimedOut => "linear-timed-out",
        escapes::Failure::Failed => "linear-failed",
    })
    .and_then(|text| {
        let rows: Vec<Created> = serde_json::from_str(&text).map_err(|_| "unparsed")?;
        let mut kept = Vec::new();
        for row in rows {
            let at = escapes::epoch(&row.created_at).map_err(|_| "unparsed")?;
            if at >= since && at < now {
                kept.push(row);
            }
        }
        Ok(kept)
    });
    match read {
        Ok(rows) => Some(rows),
        Err(cause) => {
            let _ = writeln!(std::io::stderr(), "report-created-unread cause={cause}");
            None
        }
    }
}

/// The section's line for `issue` where it links to a fleet item, naming
/// each link: its parent, an issue it blocks, one blocking it, a related one.
fn linked(issue: &Created, items: &BTreeSet<&str>) -> Option<String> {
    let links: Vec<String> = std::iter::once((issue.parent_id.as_str(), "parent"))
        .chain(issue.blocks.iter().map(|id| (id.as_str(), "blocks")))
        .chain(
            issue
                .blocked_by
                .iter()
                .map(|id| (id.as_str(), "blocked by")),
        )
        .chain(issue.related.iter().map(|id| (id.as_str(), "related")))
        .filter(|(id, _)| items.contains(id))
        .map(|(id, kind)| format!("{} ({kind})", cell(id)))
        .collect();
    (!links.is_empty()).then(|| {
        format!(
            "- **[\\[{}\\]]({})** {}; links {}.\n",
            cell(&issue.id),
            cell(&issue.url),
            cell(&issue.title),
            links.join(", ")
        )
    })
}

/// A session's own due: its start is the cadence floor, and the fleet record
/// it names, if any, is the only one it reads; a session that names none
/// reads no fleet, so no fleet on its host counts toward it.
pub struct Session {
    pub start: u64,
    pub fleet: Option<PathBuf>,
}

/// Where the cadence stands before any GitHub read: answered, or owed the
/// landed-item count, the one step that reads GitHub.
pub enum Cadence {
    Answered(Option<String>),
    Count(Count),
}

/// The landed-item count a cadence owes: the fleet it reads and its window.
pub struct Count {
    policy: Policy,
    doc: Document,
    marker: u64,
    floor: u64,
}

pub fn due(ctx: &Context, now: u64, session: Option<&Session>) -> Result<Option<String>> {
    match cadence(ctx, now, session)? {
        Cadence::Answered(line) => Ok(line),
        Cadence::Count(owed) => landed(ctx, now, owed),
    }
}

/// Every due answer that reads no GitHub: off, no marker, the session's
/// quiet hours, the morning catch-up, minutes, no issue trigger.
pub fn cadence(ctx: &Context, now: u64, session: Option<&Session>) -> Result<Cadence> {
    let answered = |line: Option<String>| Ok(Cadence::Answered(line));
    let policy = Policy::of(&ctx.settings)?;
    if !policy.enabled {
        return answered(None);
    }
    let session_start = session.map(|s| s.start);
    let doc = match session {
        Some(Session { fleet: None, .. }) => Document::new(),
        Some(Session {
            fleet: Some(path), ..
        }) => match load_fleet(path) {
            Ok(doc) => doc,
            Err(Error::Runtime(agent_runtime::Error::RecordMissing { .. })) => Document::new(),
            Err(e) => return Err(e),
        },
        None => load_fleet(&ctx.fleet)?,
    };
    let window = window(ctx, &doc, session_start)?;
    let Some(marker) = (if session_start.is_some() {
        window.owner
    } else {
        window.latest
    }) else {
        return answered(None);
    };
    let quiet = policy.quiet_at(now)?;
    if session_start.is_some() && quiet {
        return answered(None);
    }
    let active = policy.minutes > 0 || policy.issues > 0;
    if session_start.is_none()
        && !quiet
        && active
        && let (Some(latest), Some(owner)) = (window.latest, window.owner)
        && latest > owner
        && policy.quiet_at(latest)?
    {
        return answered(Some(format!(
            "report-due reason=minutes since={}",
            clock::iso_utc(owner)
        )));
    }
    if policy.minutes > 0 && now.saturating_sub(marker) >= policy.minutes.saturating_mul(60) {
        return answered(Some(format!(
            "report-due reason=minutes since={}",
            clock::iso_utc(marker)
        )));
    }
    if policy.issues == 0 || (session_start.is_some() && doc.is_empty()) {
        return answered(None);
    }
    Ok(Cadence::Count(Count {
        floor: marker.max(now.saturating_sub(LOOKBACK)),
        policy,
        doc,
        marker,
    }))
}

/// The landed-item count: distinct items landed in the window, one recent
/// item enough where the lookback cut an older window.
pub fn landed(ctx: &Context, now: u64, owed: Count) -> Result<Option<String>> {
    let Count {
        policy,
        doc,
        marker,
        floor,
    } = owed;
    let rows = completions(ctx, &doc, floor, now)?;
    let count = rows.iter().map(|r| &r.item).collect::<BTreeSet<_>>().len() as u64;
    Ok(
        (count >= policy.issues || (floor > marker && count > 0)).then(|| {
            format!(
                "report-due reason=issues since={} landed={count}",
                clock::iso_utc(marker)
            )
        }),
    )
}

fn field<'a>(record: &'a Value, key: &str) -> Option<&'a str> {
    record.get(key).and_then(Value::as_str)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the report duty's phase-stamp read per lane with a pull request and no recorded cycle, through the one runner under its tag"
)]
fn first_commit_of(
    github: &Path,
    number: u64,
    repo: &str,
) -> std::result::Result<Option<String>, String> {
    let number = number.to_string();
    let out = host::run_tagged(
        TAG,
        "github.sh",
        github,
        "pr-timeline",
        &["pr-timeline", &number, "--repo", repo],
        BOUND,
    )
    .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "pr-timeline exit={}: {}",
            out.status.code().unwrap_or(-1),
            host::stderr_text(&out).trim()
        ));
    }
    let value: Value =
        serde_json::from_str(&host::stdout_text(&out)).map_err(|e| format!("pr-timeline: {e}"))?;
    match value.pointer("/stamps/first_commit") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(stamp)) => Ok(Some(stamp.clone())),
        Some(other) => Err(format!("pr-timeline: first_commit {other}")),
    }
}

fn pull_request(lane: &Value, default_repo: Option<&str>) -> Option<(u64, String)> {
    for key in ["pending_pr", "parked"] {
        let Some(record) = lane.get(key) else {
            continue;
        };
        let Some(number) = record.get("pr").and_then(Value::as_u64) else {
            continue;
        };
        let repo = record
            .get("repo")
            .and_then(Value::as_str)
            .or(field(lane, "repo"))
            .or(default_repo)?;
        return Some((number, repo.to_owned()));
    }
    None
}

fn span_line(github: &Path, lane: &Value, default_repo: Option<&str>) -> String {
    let item = field(lane, "item").unwrap_or("-");
    let launched = field(lane, "launched_at");
    let recorded = lane
        .pointer("/cycle/stamps/first_commit")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let first = match recorded {
        Some(stamp) => Ok(Some(stamp)),
        None => match pull_request(lane, default_repo) {
            Some((number, repo)) => first_commit_of(github, number, &repo),
            None => Ok(None),
        },
    };
    let (first_word, secs) = match &first {
        Ok(Some(stamp)) => {
            let secs = launched
                .and_then(clock::epoch_secs)
                .zip(clock::epoch_secs(stamp))
                .map(|(l, f)| f.saturating_sub(l).to_string());
            (stamp.clone(), secs)
        }
        Ok(None) => ("none".to_owned(), None),
        Err(cause) => {
            let _ = writeln!(std::io::stderr(), "report-span-unread item={item} {cause}");
            ("unread".to_owned(), None)
        }
    };
    let tier = field(lane, "tier").unwrap_or("-");
    format!(
        "  first-commit {item} launched={} first_commit={first_word} secs={} tier={tier}",
        launched.unwrap_or("-"),
        secs.as_deref().unwrap_or("-")
    )
}

/// A `lane-mail` refusal's keyed line naming the lane's own host or mailbox,
/// `(host-unreachable|mail-read-failed)=ITEM( |$)`: the lane is marked and
/// the report goes on; any other refusal stops it.
fn names_lane(keyed: &str, item: &str) -> bool {
    let Some((key, rest)) = keyed.split_once('=') else {
        return false;
    };
    matches!(key, "host-unreachable" | "mail-read-failed") && rest.split(' ').next() == Some(item)
}

fn cell(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace('|', "\\|")
}

pub fn render(ctx: &Context, now: u64) -> Result<String> {
    let policy = Policy::of(&ctx.settings)?;
    let doc = load_fleet(&ctx.fleet)?;
    let lanes = lanes(&doc)?;
    let window = window(ctx, &doc, None)?;
    let since = window.owner.unwrap_or(now);
    let floor = since.max(now.saturating_sub(LOOKBACK));
    let window_text = format!("{} to {}", clock::iso_utc(since), clock::iso_utc(now));
    let mut out = String::from(
        "> **Overall:** Work status follows from the fleet records.\n\n> **What's going well:** Completed work is listed below.\n\n> **What's not going well:** Unread figures need a reading before a conclusion.\n\n```\nNumbers\n```\n\n",
    );
    let created = created(ctx, since, now);
    for (name, count) in [
        ("Issues merged", None),
        ("Issues created", created.as_ref().map(Vec::len)),
        ("Issues verified", None),
        ("Issues cancelled", None),
    ] {
        let count = count.map_or("unread".to_owned(), |n| n.to_string());
        out.push_str(&format!(
            "- {name}: {count}; source: Linear, all teams; window: {window_text}.\n"
        ));
    }
    let known = ["approved-on-rerequest", "fallback", "declined-unchanged"];
    let mut counts = [0_u64; 4];
    for row in doc
        .get("fleet_log")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|row| field(row, "kind") == Some("use1"))
    {
        let at = field(row, "at")
            .and_then(clock::epoch_secs)
            .ok_or_else(|| unjudged(&[("cause", "use1-time")]))?;
        if at >= since && at < now {
            let index = known
                .iter()
                .position(|outcome| Some(*outcome) == field(row, "outcome"))
                .unwrap_or(3);
            counts[index] += 1;
        }
    }
    if counts.iter().all(|n| *n == 0) {
        out.push_str("\nUse 1: none\n");
    } else {
        out.push_str(&format!(
            "\nUse 1: approved-on-rerequest={} fallback={} declined-unchanged={}",
            counts[0], counts[1], counts[2]
        ));
        if counts[3] > 0 {
            out.push_str(&format!(" unrecognized={}", counts[3]));
        }
        out.push('\n');
    }
    let tracker = ctx
        .shared
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .tracker
        .clone();
    let verifying: BTreeSet<String> = tracker
        .iter()
        .flat_map(|inventory| inventory.verifying.iter().map(|item| item.id.clone()))
        .collect();
    match tracker {
        Some(inventory) => {
            out.push_str(&format!(
                "\nPost-merge items waiting: {}; source: tracker duty; read at {}.\n",
                inventory.verifying.iter().filter(|i| !i.container).count(),
                clock::iso_utc(inventory.read_at)
            ));
            for item in inventory.verifying.iter().filter(|i| !i.container) {
                out.push_str(&format!(
                    "- {}: post-merge checks; issue stage age=unread (no stage-entry reader, as of {}); issue created {}.\n",
                    cell(&item.id),
                    clock::iso_utc(now),
                    cell(&item.created_at)
                ));
            }
        }
        None => out.push_str(&format!(
            "\nPost-merge checks waiting: unread; source: the tracker duty's verifying read, which this process has not made; as of {}.\n",
            clock::iso_utc(now)
        )),
    }
    out.push_str("\nActive workers:\n");
    let scripts = ctx
        .settings
        .roots
        .project
        .join(".agents/skills/orch/scripts");
    let mut past = Vec::new();
    let mut lane_blockers = Vec::new();
    let mut unread = BTreeMap::new();
    for lane in lanes
        .iter()
        .filter(|l| matches!(l.status, LaneStatus::Running | LaneStatus::Preparing))
    {
        let duration = lane
            .launched_at
            .as_deref()
            .and_then(clock::epoch_secs)
            .map(|t| now.saturating_sub(t));
        let identity = format!(
            "{} account={} host={} session={}",
            lane.harness.as_deref().unwrap_or("unread"),
            lane.account.as_deref().unwrap_or("unread"),
            super::hosted::host_of(lane),
            lane.session_id.as_deref().unwrap_or("unread")
        );
        let row = format!(
            "- {}: {:?}; {identity}; job duration={} seconds; issue stage age=unread (no stage-entry reader, as of {}).\n",
            lane.item,
            lane.status,
            duration.map_or("unread".to_owned(), |n| n.to_string()),
            clock::iso_utc(now)
        );
        out.push_str(&row);
        match super::lanes::status(&ctx.settings, &ctx.fleet, &lane.item) {
            Ok(facts) => {
                let word = |key| facts.get(key).and_then(Value::as_str).unwrap_or("unread");
                out.push_str(&format!(
                    "  - Status: {}; stage: {}.\n",
                    cell(word("state")),
                    cell(word("stage"))
                ));
                out.push_str(&format!("  - Rounds: review_rounds={} fix_receipts={} validation_runs={} restacks={} repeated_class_rounds={}.\n",word("review_rounds"),word("fix_receipts"),word("validation_runs"),word("restacks"),word("repeated_class_rounds")));
                match facts.get("state").and_then(Value::as_str) {
                    Some("walled" | "asking" | "rate-limit-switch") => {
                        lane_blockers.push(format!(
                            "- {}: {}; {}.\n",
                            cell(&lane.item),
                            word("state"),
                            cell(
                                facts
                                    .get("banner")
                                    .and_then(Value::as_str)
                                    .unwrap_or("lane status requires attention")
                            )
                        ));
                    }
                    // A read that failed or settles nothing leaves open
                    // whether the lane is blocked.
                    Some(state @ ("unreadable" | "unjudged")) => {
                        unread.insert(&lane.item, format!("{state} ({})", word("cause")));
                    }
                    _ => {}
                }
            }
            Err(cause) => {
                out.push_str(&format!(
                    "  - Lane facts: unread ({}).\n",
                    cell(&cause.to_string())
                ));
                unread.insert(&lane.item, cause.to_string());
            }
        }
        if duration.is_some_and(|n| n > 12600) {
            past.push(row);
        }
        if lane.status == LaneStatus::Running {
            let context = super::hosted::capabilities(&scripts, super::hosted::host_of(lane))
                .map(|caps| super::context::lane(lane, caps.files, &scripts, now));
            let reading = match context {
                Ok(super::context::LaneContext::Own { record, standing }) => format!(
                    "tokens={} window={} standing={standing:?}",
                    record.tokens.map_or("unread".to_owned(), |n| n.to_string()),
                    record.window.map_or("unread".to_owned(), |n| n.to_string())
                ),
                Ok(super::context::LaneContext::Unrecorded) => "unrecorded".to_owned(),
                Ok(super::context::LaneContext::Other) => "other session".to_owned(),
                Ok(super::context::LaneContext::Unreadable { cause }) | Err(cause) => {
                    format!("unread ({cause})")
                }
            };
            out.push_str(&format!("  - Context: {}.\n", cell(&reading)));
        }
    }
    if !lanes
        .iter()
        .any(|l| matches!(l.status, LaneStatus::Running | LaneStatus::Preparing))
    {
        out.push_str("- None recorded.\n");
    }
    out.push_str("\nWorkers past 3.5 hours:\n");
    if past.is_empty() {
        out.push_str("- None.\n");
    } else {
        for line in past {
            out.push_str(&line);
        }
    }
    out.push_str("\n```\nCompleted\n```\n\n");
    match completions(ctx, &doc, floor, now) {
        Ok(rows) => {
            if floor > since {
                out.push_str(&format!(
                    "Earlier merges not listed; GitHub window starts {}.\n\n",
                    clock::iso_utc(floor)
                ));
            }
            if rows.is_empty() {
                out.push_str("- None recorded in the window.\n");
            }
            for super::github::Completion {
                item,
                repo,
                number,
                title,
                ..
            } in rows
            {
                let state = if verifying.contains(&item) {
                    "; Verifying"
                } else {
                    ""
                };
                if number == 0 {
                    out.push_str(&format!("- {}: direct push{state}.\n", cell(&item)));
                } else {
                    out.push_str(&format!(
                        "- {}: {} ([{repo}#{number}](https://github.com/{repo}/pull/{number})){state}.\n",
                        cell(&item),
                        cell(&title)
                    ));
                }
            }
        }
        Err(e) => out.push_str(&format!(
            "- Unread; source: GitHub; cause: {}.\n",
            cell(&e.to_string())
        )),
    }
    out.push_str(&format!("\n{}\n", escapes::line(ctx, now)));
    out.push_str("\n```\nIn progress\n```\n\n");
    for lane in lanes.iter().filter(|l| {
        matches!(
            l.status,
            LaneStatus::Running | LaneStatus::Preparing | LaneStatus::Parked
        )
    }) {
        // The pull request the lane record names: its open one, else the
        // one its park judged.
        let pull = ["pending_pr", "parked"]
            .iter()
            .find_map(|key| lane.extra.get(*key)?.get("pr")?.as_u64());
        match pull {
            Some(number) => out.push_str(&format!(
                "- {}: {:?}, #{number}.\n",
                cell(&lane.item),
                lane.status
            )),
            None => out.push_str(&format!(
                "- {}: {:?}, no pull request.\n",
                cell(&lane.item),
                lane.status
            )),
        }
    }
    let launched: BTreeSet<_> = lanes.iter().map(|l| l.item.as_str()).collect();
    let queue = doc
        .get("launch_queue")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|key| !launched.contains(key))
        .take(usize::try_from(policy.upcoming).unwrap_or(usize::MAX));
    for item in queue {
        out.push_str(&format!(
            "- Queued {}: launch admission pending.\n",
            cell(item)
        ));
    }
    out.push_str("\n```\nBlocked\n```\n\n");
    let mut blocked = !lane_blockers.is_empty();
    for line in lane_blockers {
        out.push_str(&line);
    }
    for lane in &lanes {
        if let Some(stop) = lane.extra.get("post_pr_stop") {
            blocked = true;
            out.push_str(&format!(
                "- {}: {}.\n",
                cell(&lane.item),
                cell(&stop.to_string())
            ));
        }
    }
    for (item, cause) in &unread {
        out.push_str(&format!(
            "- Unread for {}: {}; source: lane status; as of {}.\n",
            cell(item),
            cell(cause),
            clock::iso_utc(now)
        ));
    }
    if !blocked && unread.is_empty() {
        out.push_str(&format!(
            "- None; source: lane status of every active lane and each lane's post-PR stop; as of {}.\n",
            clock::iso_utc(now)
        ));
    }
    out.push_str("\n```\nLinked issues created\n```\n\n");
    match &created {
        Some(rows) => {
            let lines: Vec<String> = rows.iter().filter_map(|i| linked(i, &launched)).collect();
            if lines.is_empty() {
                out.push_str(&format!(
                    "- None; source: Linear, all teams; window: {window_text}.\n"
                ));
            }
            for line in lines {
                out.push_str(&line);
            }
        }
        None => out.push_str(&format!(
            "- Unread; source: Linear, all teams; window: {window_text}.\n"
        )),
    }
    out.push_str("\n```\nWaiting on you\n```\n\n");
    let mail = Mailbox::new(ctx.settings.lane_mail_cli.clone());
    let asks = mail.pending_owner_asks(&ctx.settings.roots.common)?;
    let events = mail.events(&ctx.settings.roots.common)?;
    let answered: BTreeSet<&str> = events
        .iter()
        .filter(|e| e.mail_class.as_deref() == Some("resolution"))
        .filter_map(|e| e.re.as_deref())
        .collect();
    let mut waiting = Vec::new();
    let posted: Vec<&Envelope> = asks
        .iter()
        .filter(|ask| ask.tracker_posted == Some(true))
        .collect();
    if !posted.is_empty() {
        let issues: Vec<&str> = posted
            .iter()
            .filter_map(|ask| ask.issue.as_deref())
            .collect();
        waiting.push(format!(
            "- {} on the tracker: {}.\n",
            posted.len(),
            cell(&issues.join(", "))
        ));
    }
    for ask in asks.iter().filter(|ask| ask.tracker_posted != Some(true)) {
        let status = if ask.reserved == Some(true) {
            if answered.contains(ask.id()) {
                " (reserved, answered, awaiting close)".to_owned()
            } else {
                let overdue = ask
                    .deadline
                    .as_deref()
                    .and_then(clock::epoch_secs)
                    .is_some_and(|at| at <= now);
                format!(
                    " (reserved, no default; {} {})",
                    if overdue { "overdue since" } else { "due" },
                    ask.deadline.as_deref().unwrap_or("unread")
                )
            }
        } else if let Some(recommend) = ask.recommend.as_deref() {
            match ask.deadline.as_deref() {
                Some(deadline) => {
                    format!(" (recommended {recommend}; defaults to it after {deadline})")
                }
                None => format!(" (recommended {recommend}; no deadline)"),
            }
        } else {
            String::new()
        };
        let link = ask
            .issue
            .as_deref()
            .map(|i| format!("{i}: "))
            .unwrap_or_default();
        waiting.push(format!(
            "- {link}{}{status}.\n",
            cell(ask.text.as_deref().unwrap_or("unread"))
        ));
    }
    for lane in lanes
        .iter()
        .filter(|l| l.status == LaneStatus::Running && !l.session_channel())
    {
        let root = lane
            .mail_root
            .as_deref()
            .filter(|r| !r.is_empty())
            .ok_or_else(|| unjudged(&[("cause", "mail-root-missing"), ("item", &lane.item)]))?;
        let host = lane.host.as_deref().filter(|h| !h.is_empty());
        match mail.pending(&lane.item, Path::new(root), host) {
            Ok(envelopes) => {
                for ask in envelopes.iter().filter(|e| e.kind() == "ask") {
                    waiting.push(format!(
                        "- {} waits on the overseer to answer: {}.\n",
                        cell(&lane.item),
                        cell(ask.text.as_deref().unwrap_or(""))
                    ));
                }
            }
            Err(Refusal::Exit {
                status: Some(2),
                keyed: Some(line),
                ..
            }) if names_lane(&line, &lane.item) => waiting.push(format!(
                "- {item} mailbox unreadable (mail-read={item}): lane-mail: {}.\n",
                cell(&line),
                item = cell(&lane.item)
            )),
            Err(refusal) => return Err(refusal.into()),
        }
    }
    if waiting.is_empty() {
        out.push_str("- Nothing.\n");
    }
    for line in waiting {
        out.push_str(&line);
    }
    out.push_str("\n```\nHeadroom remaining\n```\n\n");
    match crate::ops::accounts::roster(&ctx.settings, None, now) {
        Ok(roster) => {
            for line in roster.lines(&agent_runtime::accounts::today(now)) {
                out.push_str(&format!("- {}\n", cell(&line)));
            }
        }
        Err(cause) => out.push_str(&format!("- Unread: {}.\n", cell(&cause))),
    }
    out.push_str("\n```\nOverseer self-analysis\n```\n\n- Bad: unread report figures remain open; read the named sources before the next report.\n\n");
    let next = if !policy.enabled || (policy.minutes == 0 && policy.issues == 0) {
        "cadence disabled".to_owned()
    } else {
        let mut triggers = Vec::new();
        if policy.minutes > 0 {
            triggers.push(clock::iso_utc(
                now.saturating_add(policy.minutes.saturating_mul(60)),
            ));
        }
        if policy.issues > 0 {
            triggers.push(format!("after {} distinct landed items", policy.issues));
        }
        triggers.join(" or ")
    };
    out.push_str(&format!("`Next report: {next}`\n"));
    Ok(out)
}

/// The owner asks the summary names, read at the write: one named by its id
/// that is no longer pending has closed, so the summary would ask the owner
/// for a choice that no longer stands, and the caller summarizes again
/// before the report's one delivery. An id of any other envelope names no
/// ask.
fn refuse_stale_ask(ctx: &Context, summary: &str) -> Result<()> {
    let mail = Mailbox::new(ctx.settings.lane_mail_cli.clone());
    let root = &ctx.settings.roots.common;
    let pending: BTreeSet<String> = mail
        .pending_owner_asks(root)?
        .iter()
        .map(|ask| ask.id().to_owned())
        .collect();
    let asks: BTreeSet<String> = mail
        .events(root)?
        .iter()
        .filter(|e| e.kind() == "ask" && e.to.as_deref() == Some("owner"))
        .map(|e| e.id().to_owned())
        .collect();
    let named = summary
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
        .find(|word| asks.contains(*word) && !pending.contains(*word));
    match named {
        Some(ask) => Err(unjudged(&[("cause", "summary-stale"), ("ask", ask)])),
        None => Ok(()),
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "report bytes and the delivery attempt are durable before the mailbox start; only its attachment confirms delivery"
)]
pub fn write(ctx: &Context, now: u64, summary: &Path, succession: bool) -> Result<Value> {
    let summary_text = std::fs::read_to_string(summary).map_err(|e| {
        unjudged(&[
            ("summary", &summary.display().to_string()),
            ("cause", &e.to_string()),
        ])
    })?;
    // The notice's text is the summary less its trailing blank lines.
    let lines: Vec<&str> = summary_text.lines().collect();
    let Some(last) = lines.iter().rposition(|l| !l.trim().is_empty()) else {
        return Err(unjudged(&[("cause", "summary-empty")]));
    };
    let notice_text = format!("{}\n", lines[..=last].join("\n"));
    let target = crate::ops::store::progress_report_path(
        &ctx.settings.store.progress_report_dir,
        now,
        succession,
    )?;
    let target = target
        .parent()
        .expect("a report path has a directory")
        .canonicalize()
        .map_err(|e| unjudged(&[("cause", &e.to_string())]))?
        .join(target.file_name().expect("a report path has a name"));
    let attempt = target.with_extension("notice.json");
    let quiet = Policy::of(&ctx.settings)?.quiet_at(now)?;
    let stored = match std::fs::read_to_string(&attempt) {
        Ok(text) => {
            let record: Value =
                serde_json::from_str(&text).map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
            let at = record
                .get("at")
                .and_then(Value::as_u64)
                .ok_or_else(|| unjudged(&[("cause", "attempt-time-unread")]))?;
            // The name keys on month to minute: an attempt stamped outside
            // this minute is another year's report, never this one's retry.
            if at <= now && now - at < 60 {
                Some((record, at))
            } else {
                std::fs::remove_file(&attempt)
                    .map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
                None
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(unjudged(&[("cause", &e.to_string())])),
    };
    let (body, cutoff) = match stored {
        Some((record, cutoff)) => {
            if record.get("summary").and_then(Value::as_str) != Some(&summary_text) {
                return Err(unjudged(&[("cause", "report-exists")]));
            }
            (
                record
                    .get("body")
                    .and_then(Value::as_str)
                    .ok_or_else(|| unjudged(&[("cause", "attempt-unread")]))?
                    .to_owned(),
                cutoff,
            )
        }
        None => {
            if target
                .try_exists()
                .map_err(|e| unjudged(&[("cause", &e.to_string())]))?
            {
                return Err(unjudged(&[("cause", "report-exists")]));
            }
            refuse_stale_ask(ctx, &summary_text)?;
            let body = render(ctx, now)?;
            let mut record = std::fs::File::create_new(&attempt)
                .map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
            record
                .write_all(
                    json!({"summary":summary_text,"body":body,"state":"attempted","at":now})
                        .to_string()
                        .as_bytes(),
                )
                .and_then(|()| record.sync_all())
                .map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
            (body, now)
        }
    };
    match std::fs::read_to_string(&target) {
        Ok(existing) if existing == body => {}
        Ok(_) => return Err(unjudged(&[("cause", "report-exists")])),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let scratch = target.with_extension("writing");
            let mut file = std::fs::File::create_new(&scratch)
                .map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
            let publish = (|| -> std::io::Result<()> {
                file.write_all(body.as_bytes())?;
                file.set_times(
                    std::fs::FileTimes::new()
                        .set_modified(UNIX_EPOCH + Duration::from_secs(cutoff)),
                )?;
                file.sync_all()?;
                std::fs::hard_link(&scratch, &target)
            })();
            let cleanup = std::fs::remove_file(&scratch);
            publish
                .and(cleanup)
                .map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
        }
        Err(e) => return Err(unjudged(&[("cause", &e.to_string())])),
    }
    let notice = if quiet {
        None
    } else {
        // The text the notice carries, beside the report and gone with the
        // send: the mailbox runs in the main checkout, so the file it reads
        // is named by an absolute path.
        let text = target.with_extension("notice.txt");
        std::fs::write(&text, &notice_text).map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
        let sent = Mailbox::new(ctx.settings.lane_mail_cli.clone()).report_notice(
            &ctx.settings.roots.common,
            &target,
            &text,
        );
        let _ = std::fs::remove_file(&text);
        Some(sent?)
    };
    // Delivered, or quiet with nothing owed: the attempt has served. One left
    // behind is harmless: a retry in this minute reconciles by the box, and a
    // later year's write at this minute replaces it.
    let _ = std::fs::remove_file(&attempt);
    Ok(json!({"event":"report-written","path":target,"notice_id":notice,"body":body}))
}

fn run(ctx: &Context, tick: &Tick) -> Result<Produced> {
    let line = due(ctx, tick.wall, None)?;
    let prior = tick.baseline.get(DUE_ROW, FLEET);
    let mut produced = Produced::default();
    match line {
        None => {
            if prior.is_some() {
                produced.changes.push(Change::Clear {
                    kind: DUE_ROW.to_owned(),
                    identity: FLEET.to_owned(),
                });
            }
        }
        Some(line) if prior == Some(line.as_str()) => {}
        Some(line) => {
            produced
                .events
                .push(Event::ReportDue { line: line.clone() });
            let fleet = load_fleet(&ctx.fleet)?;
            for lane in fleet
                .get("lanes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                produced.events.push(Event::Body {
                    line: span_line(&ctx.github, lane, ctx.repos.first().map(String::as_str)),
                });
            }
            produced.changes.push(Change::Set {
                kind: DUE_ROW.to_owned(),
                identity: FLEET.to_owned(),
                value: line,
            });
        }
    }
    Ok(produced)
}

pub fn row_kinds() -> [&'static str; 1] {
    [DUE_ROW]
}

mod escapes;
