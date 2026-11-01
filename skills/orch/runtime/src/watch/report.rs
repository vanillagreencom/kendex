//! The report duty (decision 121 Q8; step5-map § A6; decision 94): each
//! long cadence, `oversee-report due` through the one runner, as the legacy
//! `check_report` called it (`oversee-watch:5213-5233`); the cadence,
//! `ORCH_REPORT_EVERY_MINUTES`, `ORCH_REPORT_EVERY_ISSUES` and the quiet
//! hours, is judged inside that script and nowhere here. Its one
//! `report-due reason=` line is the event; nothing is "not due"; an exit
//! other than zero, a second line or a line of another shape is
//! `report-unjudged`, the body's failure, which the runner says as
//! `watch-step-failed step=report` with the cause, never silence.
//!
//! The line prints when its text is new or changed and the row holding it
//! clears when the report is no longer due (decisions 128 (5), 130: the
//! report file the overseer writes is what ends it, so a standing due
//! report is said once, not every 240 s). Under it, one line per lane with
//! its launch-to-first-commit span (decision 141 (6)): the lane's
//! `launched_at` against the `first_commit` stamp its `cycle` recorded, or,
//! for a lane with a pull request and no cycle yet, the stamp
//! `github.sh pr-timeline` reads; no timer and no gate.
//!
//! The duty reads nothing of the controller (Q8).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host;
use serde_json::Value;

use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::state::{self, Document};
use crate::watch::{Body, Change, Event, Produced, Runner, Tick};

/// The baseline row kind this duty owns: `report-due fleet <line>`, the
/// due line last announced.
pub const DUE_ROW: &str = "report-due";

/// The row identity the due line is held under.
const FLEET: &str = "fleet";

/// The bound on `oversee-report due`, which may read GitHub for the
/// completion count, and on one `pr-timeline` read.
const BOUND: Duration = Duration::from_secs(300);

/// The start-counter tag every call of this duty is counted under.
const TAG: &str = "report";

/// The word the due line opens with (`oversee-report --help`, due).
const DUE_PREFIX: &str = "report-due reason=";

/// The github package's program under the project's install, whose
/// `pr-timeline` reads the phase stamps; `oversee-cycle` reads them the
/// same way.
const GITHUB_CLI_DEFAULT: &str = ".agents/skills/github/scripts/github.sh";

/// What the duty runs with, fixed at registration.
pub struct Context {
    /// The fleet state file, the `--state` the report judges.
    pub fleet: PathBuf,
    pub settings: Settings,
    /// The github package's program (`pr-timeline`).
    pub github: PathBuf,
    /// The `--repo` names the report reads.
    pub repos: Vec<String>,
}

pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| run(&ctx, tick))
}

/// Register the duty on `runner` for the fleet at `path` (decision 153),
/// `repos` the watch's `--repo` names.
pub fn register(runner: &mut Runner<'_>, path: &Path, settings: &Settings, repos: Vec<String>) {
    runner.register(
        crate::schedule::Duty::Report,
        body(Context {
            fleet: path.to_path_buf(),
            github: settings.roots.project.join(GITHUB_CLI_DEFAULT),
            settings: settings.clone(),
            repos,
        }),
    );
}

fn unjudged(fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused("report-unjudged", fields).into()
}

/// `oversee-report due --state <fleet> --repo <r>...`: `Some(line)` where
/// the report is due, `None` where it printed nothing, else the refusal.
#[allow(
    clippy::disallowed_methods,
    reason = "the report duty's one call of the legacy report judge per pass through the one runner under its tag (decision 94)"
)]
fn due(ctx: &Context) -> Result<Option<String>> {
    let cli = ctx.settings.report_cli.display().to_string();
    let fleet = ctx.fleet.display().to_string();
    let mut args = vec!["due", "--state", fleet.as_str()];
    for repo in &ctx.repos {
        args.push("--repo");
        args.push(repo.as_str());
    }
    let out = host::run_tagged(
        TAG,
        "oversee-report",
        &ctx.settings.report_cli,
        "due",
        &args,
        BOUND,
    )
    .map_err(|e| unjudged(&[("path", &cli), ("cause", &e.to_string())]))?;
    if !out.status.success() {
        let exit = out
            .status
            .code()
            .map_or("none".to_owned(), |c| c.to_string());
        return Err(unjudged(&[
            ("exit", &exit),
            ("path", &cli),
            ("cause", host::stderr_text(&out).trim()),
        ]));
    }
    let text = host::stdout_text(&out);
    let text = text.trim_end_matches('\n');
    if text.is_empty() {
        return Ok(None);
    }
    if text.contains('\n') || !text.starts_with(DUE_PREFIX) {
        return Err(unjudged(&[("exit", "0"), ("path", &cli), ("answer", text)]));
    }
    Ok(Some(text.to_owned()))
}

/// The fleet record, read once per due line, as the file holds it: a lane
/// record of an old vintage is listed by its words, not refused by a type.
#[allow(
    clippy::disallowed_methods,
    reason = "the report duty's one read of the fleet record when a report comes due: the lanes whose spans the body lists, judged and never written"
)]
fn load_fleet(path: &Path) -> Result<Document> {
    Ok(state::load(path)?
        .ok_or_else(|| Error::RecordMissing {
            path: path.to_path_buf(),
        })?
        .doc)
}

fn field<'a>(record: &'a Value, key: &str) -> Option<&'a str> {
    record.get(key).and_then(Value::as_str)
}

/// `github.sh pr-timeline <n> --repo <repo>`: the `first_commit` stamp, or
/// the failure's words.
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

/// A lane's pull request and its repository, from the fields the launcher
/// and the parking close write (`pending_pr`, `parked`), else none.
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

/// The launch-to-first-commit line of one lane (decision 141 (6)):
/// `  first-commit <item> launched=<UTC|-> first_commit=<UTC|none|unread>
/// secs=<n|-> tier=<t|->`, indented as a body line under the due line.
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
            // Said once here, for the launcher's record of this run; the
            // line names the lane as unread.
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

fn run(ctx: &Context, tick: &Tick) -> Result<Produced> {
    let line = due(ctx)?;
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
            let default_repo = ctx.repos.first().map(String::as_str);
            let lanes = fleet.get("lanes").and_then(Value::as_array);
            for lane in lanes.into_iter().flatten() {
                produced.events.push(Event::Body {
                    line: span_line(&ctx.github, lane, default_repo),
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

/// The row kinds this duty keeps.
pub fn row_kinds() -> [&'static str; 1] {
    [DUE_ROW]
}
