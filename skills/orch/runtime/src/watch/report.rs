//! The report cadence and owner report share one snapshot window. Files
//! advance cadence; only mailbox attachment receipts advance the owner window.

use std::collections::BTreeSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use agent_runtime::{clock, host};
use serde_json::{Value, json};

use crate::error::{Error, Result};
use crate::mailbox::Mailbox;
use crate::settings::Settings;
use crate::state::{self, Document, Lane, LaneStatus};
use crate::watch::{Body, Change, Event, Produced, Runner, Tick};

pub const DUE_ROW: &str = "report-due";
const FLEET: &str = "fleet";
const BOUND: Duration = Duration::from_secs(300);
const TAG: &str = "report";
const GITHUB_CLI_DEFAULT: &str = ".agents/skills/github/scripts/github.sh";
const LOOKBACK: u64 = 604800;

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
        let enabled = match get("ORCH_REPORT").as_deref().unwrap_or("on") {
            "on" => true,
            "off" => false,
            value => return Err(invalid("ORCH_REPORT", value)),
        };
        let hours = get("ORCH_REPORT_QUIET_HOURS").unwrap_or_else(|| "0-7".to_owned());
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
            Some(parse().ok_or_else(|| invalid("ORCH_REPORT_QUIET_HOURS", &hours))?)
        };
        let zone = get("ORCH_OWNER_TIME_ZONE").unwrap_or_else(|| "America/Los_Angeles".to_owned());
        jiff::tz::TimeZone::get(&zone).map_err(|_| invalid("ORCH_OWNER_TIME_ZONE", &zone))?;
        Ok(Self {
            enabled,
            minutes: whole("ORCH_REPORT_EVERY_MINUTES", "120", true)?,
            issues: whole("ORCH_REPORT_EVERY_ISSUES", "0", false)?,
            upcoming: whole("ORCH_REPORT_UPCOMING", "5", false)?,
            quiet,
            zone,
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

pub fn register(
    runner: &mut Runner<'_>,
    path: &Path,
    settings: &Settings,
    repos: Vec<String>,
    shared: super::tracker::Shared,
) {
    runner.register(
        crate::schedule::Duty::Report,
        body(Context {
            fleet: path.to_path_buf(),
            github: settings.roots.project.join(GITHUB_CLI_DEFAULT),
            settings: settings.clone(),
            repos,
            gh: PathBuf::from("gh"),
            shared,
        }),
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
        .ok_or_else(|| Error::RecordMissing {
            path: path.to_path_buf(),
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

fn report_name(name: &str) -> bool {
    let Some(stem) = name.strip_suffix(".md") else {
        return false;
    };
    let stem = stem.strip_suffix("-succession").unwrap_or(stem);
    let parts: Vec<_> = stem.split('-').collect();
    parts.len() == 4
        && parts
            .iter()
            .all(|s| s.len() == 2 && s.bytes().all(|c| c.is_ascii_digit()))
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
        if !report_name(&entry.file_name().to_string_lossy()) {
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
    let start = session_start.or_else(|| {
        doc.get("lanes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|l| field(l, "launched_at").and_then(clock::epoch_secs))
            .min()
    });
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
    let gh = super::github::Gh { cli: &ctx.gh };
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

/// A session's own due: its start is the cadence floor, and the fleet record
/// it names, if any, is the only one it reads; a session that names none
/// reads no fleet, so no fleet on its host counts toward it.
pub struct Session {
    pub start: u64,
    pub fleet: Option<PathBuf>,
}

pub fn due(ctx: &Context, now: u64, session: Option<&Session>) -> Result<Option<String>> {
    let policy = &ctx.settings.report;
    if !policy.enabled {
        return Ok(None);
    }
    let session_start = session.map(|s| s.start);
    let doc = match session {
        Some(Session { fleet: None, .. }) => Document::new(),
        Some(Session {
            fleet: Some(path), ..
        }) => match load_fleet(path) {
            Ok(doc) => doc,
            Err(Error::RecordMissing { .. }) => Document::new(),
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
        return Ok(None);
    };
    let quiet = policy.quiet_at(now)?;
    if session_start.is_some() && quiet {
        return Ok(None);
    }
    let active = policy.minutes > 0 || policy.issues > 0;
    if session_start.is_none()
        && !quiet
        && active
        && let (Some(latest), Some(owner)) = (window.latest, window.owner)
        && latest > owner
        && policy.quiet_at(latest)?
    {
        return Ok(Some(format!(
            "report-due reason=minutes since={}",
            clock::iso_utc(owner)
        )));
    }
    let since = clock::iso_utc(marker);
    if policy.minutes > 0 && now.saturating_sub(marker) >= policy.minutes.saturating_mul(60) {
        return Ok(Some(format!("report-due reason=minutes since={since}")));
    }
    if policy.issues == 0 || (session_start.is_some() && doc.is_empty()) {
        return Ok(None);
    }
    let floor = marker.max(now.saturating_sub(LOOKBACK));
    let rows = completions(ctx, &doc, floor, now)?;
    let count = rows.iter().map(|r| &r.item).collect::<BTreeSet<_>>().len() as u64;
    Ok((count >= policy.issues || (floor > marker && count > 0))
        .then(|| format!("report-due reason=issues since={since} landed={count}")))
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

fn cell(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace('|', "\\|")
}

pub fn render(ctx: &Context, now: u64) -> Result<String> {
    let doc = load_fleet(&ctx.fleet)?;
    let lanes = lanes(&doc)?;
    let window = window(ctx, &doc, None)?;
    let since = window.owner.unwrap_or(now);
    let floor = since.max(now.saturating_sub(LOOKBACK));
    let window_text = format!("{} to {}", clock::iso_utc(since), clock::iso_utc(now));
    let mut out = String::from(
        "> **Overall:** Work status follows from the fleet records.\n\n> **What's going well:** Completed work is listed below.\n\n> **What's not going well:** Unread figures need a reading before a conclusion.\n\n```\nNumbers\n```\n\n",
    );
    for name in [
        "Issues merged",
        "Issues created",
        "Issues verified",
        "Issues cancelled",
    ] {
        out.push_str(&format!(
            "- {name}: unread; source: Linear, all teams; window: {window_text}.\n"
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
    match tracker {
        Some(inventory) => {
            out.push_str(&format!(
                "\nPost-merge items waiting: {}; source: tracker duty; read at {}.\n",
                inventory.verifying.iter().filter(|i| !i.container).count(),
                clock::iso_utc(inventory.read_at)
            ));
            for item in inventory.verifying.iter().filter(|i| !i.container) {
                out.push_str(&format!(
                    "- {}: post-merge checks; issue stage age=unread; issue created {}.\n",
                    cell(&item.id),
                    cell(&item.created_at)
                ));
            }
        }
        None => out.push_str("\nPost-merge checks waiting: unread; source: tracker duty.\n"),
    }
    out.push_str("\nActive workers:\n");
    let scripts = ctx
        .settings
        .roots
        .project
        .join(".agents/skills/orch/scripts");
    let mut past = Vec::new();
    let mut lane_blockers = Vec::new();
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
            "- {}: {:?}; {identity}; job duration={} seconds; issue stage age=unread.\n",
            lane.item,
            lane.status,
            duration.map_or("unread".to_owned(), |n| n.to_string())
        );
        out.push_str(&row);
        if ctx.fleet == state::fleet_path(&ctx.settings.state_dir) {
            match super::lanes::status(&ctx.settings, &lane.item) {
                Ok(facts) => {
                    let word = |key| facts.get(key).and_then(Value::as_str).unwrap_or("unread");
                    out.push_str(&format!(
                        "  - Status: {}; stage: {}.\n",
                        cell(word("state")),
                        cell(word("stage"))
                    ));
                    out.push_str(&format!("  - Rounds: review_rounds={} fix_receipts={} validation_runs={} restacks={} repeated_class_rounds={}.\n",word("review_rounds"),word("fix_receipts"),word("validation_runs"),word("restacks"),word("repeated_class_rounds")));
                    if matches!(
                        facts.get("state").and_then(Value::as_str),
                        Some("walled" | "asking" | "rate-limit-switch")
                    ) {
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
                }
                Err(cause) => out.push_str(&format!(
                    "  - Lane facts: unread ({}).\n",
                    cell(&cause.to_string())
                )),
            }
        } else {
            out.push_str("  - Lane facts: unread; lane status reads the configured fleet path.\n");
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
                if number == 0 {
                    out.push_str(&format!("- {}: direct push.\n", cell(&item)));
                } else {
                    out.push_str(&format!(
                        "- {}: {} ([{repo}#{number}](https://github.com/{repo}/pull/{number})).\n",
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
        out.push_str(&format!("- {}: {:?}.\n", cell(&lane.item), lane.status));
    }
    let launched: BTreeSet<_> = lanes.iter().map(|l| l.item.as_str()).collect();
    let queue = doc
        .get("launch_queue")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|key| !launched.contains(key))
        .take(usize::try_from(ctx.settings.report.upcoming).unwrap_or(usize::MAX));
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
    if !blocked {
        out.push_str("- Unread; lane gate facts need the observation duty's reader.\n");
    }
    out.push_str("\n```\nIssues created\n```\n\n- Unread; source: Linear, all teams.\n\n```\nWaiting on you\n```\n\n");
    let mail = Mailbox::new(ctx.settings.lane_mail_cli.clone());
    let asks = mail.pending_owner_asks(&ctx.settings.roots.common)?;
    let events = mail.events(&ctx.settings.roots.common)?;
    let answered: BTreeSet<&str> = events
        .iter()
        .filter(|e| e.mail_class.as_deref() == Some("resolution"))
        .filter_map(|e| e.re.as_deref())
        .collect();
    if asks.is_empty() {
        out.push_str("- Nothing.\n");
    }
    for ask in asks {
        let status = if ask.reserved == Some(true) {
            if answered.contains(ask.id()) {
                "reserved, answered, awaiting close".to_owned()
            } else {
                let overdue = ask
                    .deadline
                    .as_deref()
                    .and_then(clock::epoch_secs)
                    .is_some_and(|at| at <= now);
                format!(
                    "reserved, no default; {} {}",
                    if overdue { "overdue since" } else { "due" },
                    ask.deadline.as_deref().unwrap_or("unread")
                )
            }
        } else {
            format!(
                "recommended {}; deadline {}",
                ask.recommend.as_deref().unwrap_or("none"),
                ask.deadline.as_deref().unwrap_or("none")
            )
        };
        let link = ask
            .issue
            .as_deref()
            .map(|i| format!("{i}: "))
            .unwrap_or_default();
        out.push_str(&format!(
            "- {link}{} ({status}).\n",
            cell(ask.text.as_deref().unwrap_or("unread"))
        ));
    }
    out.push_str("\n```\nHeadroom remaining\n```\n\n");
    match crate::ops::accounts::roster(&ctx.settings, None, now) {
        Ok(roster) => {
            for line in roster.lines(&crate::ops::accounts::today(now)) {
                out.push_str(&format!("- {}\n", cell(&line)));
            }
        }
        Err(cause) => out.push_str(&format!("- Unread: {}.\n", cell(&cause))),
    }
    out.push_str("\n```\nOverseer self-analysis\n```\n\n- Bad: unread report figures remain open; read the named sources before the next report.\n\n");
    let policy = &ctx.settings.report;
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

#[allow(
    clippy::disallowed_methods,
    reason = "report bytes and the delivery attempt are durable before the mailbox start; only its attachment confirms delivery"
)]
pub fn write(ctx: &Context, now: u64, summary: &Path, succession: bool) -> Result<Value> {
    let summary = summary.canonicalize().map_err(|e| {
        unjudged(&[
            ("summary", &summary.display().to_string()),
            ("cause", &e.to_string()),
        ])
    })?;
    let summary_text =
        std::fs::read_to_string(&summary).map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
    if summary_text.trim().is_empty() {
        return Err(unjudged(&[("cause", "summary-empty")]));
    }
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
    let quiet = ctx.settings.report.quiet_at(now)?;
    let (body, cutoff) = match std::fs::read_to_string(&attempt) {
        Ok(text) => {
            let record: Value =
                serde_json::from_str(&text).map_err(|e| unjudged(&[("cause", &e.to_string())]))?;
            if record.get("summary").and_then(Value::as_str) != Some(&summary_text) {
                return Err(unjudged(&[("cause", "report-exists")]));
            }
            let cutoff = record
                .get("at")
                .and_then(Value::as_u64)
                .ok_or_else(|| unjudged(&[("cause", "attempt-time-unread")]))?;
            (
                record
                    .get("body")
                    .and_then(Value::as_str)
                    .ok_or_else(|| unjudged(&[("cause", "attempt-unread")]))?
                    .to_owned(),
                cutoff,
            )
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            if target
                .try_exists()
                .map_err(|e| unjudged(&[("cause", &e.to_string())]))?
            {
                return Err(unjudged(&[("cause", "report-exists")]));
            }
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
        Err(e) => return Err(unjudged(&[("cause", &e.to_string())])),
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
        Some(
            Mailbox::new(ctx.settings.lane_mail_cli.clone()).report_notice(
                &ctx.settings.roots.common,
                &target,
                &summary,
            )?,
        )
    };
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
