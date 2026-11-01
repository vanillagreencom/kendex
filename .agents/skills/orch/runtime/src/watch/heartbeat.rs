//! The heartbeat's body (decision 121 Q5, Q9; decisions 126 (1), 128 (5),
//! 130; step5-map § A1): the one periodic line, due every `max-loops ×
//! interval` seconds from the last heartbeat on the runner's own schedule,
//! and under it what the legacy `heartbeat` printed (`oversee-watch:5682-
//! 5735`): every `--repo`'s open pull requests, a Dependabot one marked by
//! the GitHub duty's `bot-fix` row; the account roster through the legacy
//! `lanes list --json` (Q9); the `verifying` lines of the verification
//! duty's last pass; the `owed` lines of the tracker duty's last pass with
//! their wall verdicts through `lanes pick` (Q9); the standing tracker
//! quota receipt; the reducer's standing attention; and one line naming
//! the open unblocked items no lane holds (126 (1)). The body reads no
//! inventory itself: the tracker, GitHub and verification duties' slots are
//! its inputs, and it hands back `next_due: None`, so nothing it does moves
//! its own due time.
//!
//! Where the legacy heartbeat died on a read it could not make (the open
//! list, the roster) and so printed nothing, this body prints the line
//! with `unread` in that place: the one periodic line is never dropped.
//! The owed list has the same word, `owed unread`, while the tracker duty
//! has read nothing, a line the legacy never printed, since its owed read
//! answered or killed the pass: a standing tracker failure never reads as
//! nothing owed.
//!
//! The roster read also carries the legacy `check_accounts`
//! (`oversee-watch:5190-5225`, decision 176 (1) (b)): each account's
//! status, verdict and binding reset compared with the reading the
//! baseline holds under the legacy's `account` row, an `account` event
//! ahead of the heartbeat line when one changed, the row advanced after
//! the line is durable. The legacy compared on every long pass; this body
//! runs on the heartbeat's cadence, the one duty that reads the roster. A
//! roster that could not be read is the pass's partial failure (decision
//! 156 (1)) and moves no row: the next readable pass compares against the
//! last reading, never against nothing.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host::{self, Place};
use serde::Deserialize;
use serde_json::Value;

use crate::settings::Settings;
use crate::watch::github::Gh;
use crate::watch::tracker::{OwedItem, Shared};
use crate::watch::verifying::Lines;
use crate::watch::{Body, Change, Event, Produced, Runner, Tick};

/// The bound on one `lanes` call, the legacy `READ_CEILING`
/// (`oversee-watch:275`).
const BOUND: Duration = Duration::from_secs(60);

/// The start-counter tag every call of this duty is counted under.
const TAG: &str = "heartbeat";

/// The host word of a lane record with no host (`oversee-watch:5409`).
const LOCAL: &str = "local";

/// What the duty runs with, fixed at registration.
pub struct Context {
    pub settings: Settings,
    /// The legacy `--max-loops`, `--interval` and `--since`, the line's
    /// own fields.
    pub max_loops: u32,
    pub interval: Duration,
    pub since: Option<String>,
    /// The `--repo` names whose open pull requests the body lists.
    pub repos: Vec<String>,
    /// The `gh` program the open list runs; `gh` on `PATH` in production.
    pub gh: PathBuf,
    pub shared: Shared,
    pub verifying: Lines,
}

pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| Ok(run(&ctx, tick)))
}

/// Register the body on `runner` (decision 153), replacing the runner's
/// placeholder: the three flags the line carries, `repos` the watch's
/// `--repo` names, `shared` the tracker and GitHub duties' slot,
/// `verifying` the verification duty's lines.
#[allow(
    clippy::too_many_arguments,
    reason = "the one registration line names each input the body has; a struct for them would be built on that line alone"
)]
pub fn register(
    runner: &mut Runner<'_>,
    settings: &Settings,
    interval: Duration,
    max_loops: u32,
    since: Option<String>,
    repos: Vec<String>,
    shared: Shared,
    verifying: Lines,
) {
    runner.register(
        crate::schedule::Duty::Heartbeat,
        body(Context {
            settings: settings.clone(),
            max_loops,
            interval,
            since,
            repos,
            gh: PathBuf::from("gh"),
            shared,
            verifying,
        }),
    );
}

/// A read that did not answer, said once on stderr for the launcher's
/// record of this run; the body's line names it `unread`.
fn note(what: &str, cause: &str) {
    let _ = writeln!(std::io::stderr(), "heartbeat-{what}-unread {cause}");
}

// --- the open pull requests ------------------------------------------------------------

/// One open pull request of `GET /repos/{owner}/{repo}/pulls?state=open`.
#[derive(Debug, Deserialize)]
struct OpenPull {
    number: u64,
    title: String,
    head: Head,
}

#[derive(Debug, Deserialize)]
struct Head {
    #[serde(rename = "ref")]
    name: String,
}

/// The repository's open pull requests as the legacy printed them
/// (`SECURITY_OPEN_JQ`, `security_mark_open`, `pw_prefix`): `<repo>\t<n>\t
/// <head>\t<title>`, or `<repo>\tbot-fix pr=<n> alert=<alerts>` for one the
/// GitHub duty's `bot-fix` row names. The list is read whole through the
/// one paging reader; a list that could not be read whole is one `unread`
/// line, never a shorter list.
fn open_lines(ctx: &Context, repo: &str, bot_fix: &BTreeMap<String, String>) -> Vec<String> {
    let gh = Gh { cli: &ctx.gh };
    let path = format!("repos/{repo}/pulls?state=open");
    let pulls: Vec<OpenPull> = match gh.list::<OpenPull>("open-pulls", &path) {
        Ok(Some(pulls)) => pulls,
        Ok(None) => {
            note("open-pulls", &format!("repo={repo} cause=not-found"));
            return vec![format!("{repo}\topen-prs unread")];
        }
        Err(e) => {
            note("open-pulls", &format!("repo={repo} cause={}", e.key()));
            return vec![format!("{repo}\topen-prs unread")];
        }
    };
    pulls
        .iter()
        .map(
            |pull| match bot_fix.get(&format!("{repo}#{}", pull.number)) {
                Some(alerts) => format!("{repo}\tbot-fix pr={} alert={alerts}", pull.number),
                None => format!(
                    "{repo}\t{}\t{}\t{}",
                    pull.number, pull.head.name, pull.title
                ),
            },
        )
        .collect()
}

// --- the roster -------------------------------------------------------------------------

/// One `lanes list --json` listing: the records as the CLI printed them.
struct Listing(Vec<Value>);

/// A field's text as jq's string interpolation printed it: a string as
/// is, any other value as its JSON, an absent one as `null`.
fn text(record: &Value, key: &str) -> String {
    match record.get(key) {
        None | Some(Value::Null) => "null".to_owned(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

/// A field with jq's `// "-"` default.
fn text_or_dash(record: &Value, key: &str) -> String {
    match record.get(key) {
        None | Some(Value::Null) => "-".to_owned(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

/// The field text both the roster line and the `account` event print
/// (`account_roster_read`'s third column, `:5157`).
fn fields(record: &Value) -> String {
    format!(
        "{} config_dir={} harness={} through={} status={} verdict={} headroom_pct={} binding_bucket={} binding_resets_at={}",
        text(record, "alias"),
        text(record, "config_dir"),
        text(record, "harness"),
        text(record, "measured_through"),
        text(record, "status"),
        text(record, "verdict"),
        text_or_dash(record, "headroom_pct"),
        text_or_dash(record, "binding_bucket"),
        text_or_dash(record, "binding_resets_at")
    )
}

/// The baseline row kind the legacy kept each account's reading under.
const ACCOUNT_ROW: &str = "account";

/// The row's identity, the legacy's first column (`:5155`): two accounts
/// sharing an alias are told apart by `config_dir`.
fn account_key(record: &Value) -> String {
    format!(
        "{}|{}|{}",
        text(record, "harness"),
        text(record, "measured_through"),
        text(record, "config_dir")
    )
}

/// `check_accounts` (`oversee-watch:5190-5225`) over one listing: per
/// record the `status|verdict|resets` reading beside the row's
/// `status|verdict|resets|unmeasured`, an `account` event where the
/// status, the verdict or a passed reset changed from the row's, the row
/// advanced on every reading that differs. The first sighting is the
/// baseline and says nothing. An `unmeasured` verdict leaves the row on
/// the reading before it unless its status is `expired` or `retired`,
/// which need the operator, so each such status after a measured reading
/// is news. A reset is news once the reset the row holds has passed
/// (`to_epoch` against the pass's wall, `lanes` writing every reset as one
/// whole-second UTC stamp, `:5150`) and the reading moved off it; one that
/// moved while still ahead is a different binding, not a reset; one no
/// date can read settles no reset and is noted. An account the listing
/// stops naming keeps its row.
fn check_accounts(listing: &Listing, tick: &Tick) -> (Vec<Event>, Vec<Change>) {
    let mut events = Vec::new();
    let mut changes = Vec::new();
    for record in &listing.0 {
        let key = account_key(record);
        let prior = tick
            .baseline
            .get(ACCOUNT_ROW, &key)
            .map(str::to_owned)
            .unwrap_or_default();
        let mut was = prior.splitn(4, '|');
        let was_status = was.next().unwrap_or_default();
        let was_verdict = was.next().unwrap_or_default();
        let was_resets = was.next().unwrap_or_default();
        let was_unmeasured = was.next().unwrap_or_default();
        let status = text(record, "status");
        let verdict = text(record, "verdict");
        let resets = text_or_dash(record, "binding_resets_at");
        let mut unmeasured = if was_unmeasured.is_empty() {
            "-"
        } else {
            was_unmeasured
        };
        if verdict == "unmeasured" {
            if status != "expired" && status != "retired" {
                continue;
            }
            unmeasured = status.as_str();
        }
        let row = format!("{status}|{verdict}|{resets}|{unmeasured}");
        if prior == row {
            continue;
        }
        changes.push(Change::Set {
            kind: ACCOUNT_ROW.to_owned(),
            identity: key.clone(),
            value: row,
        });
        if prior.is_empty() {
            continue;
        }
        let mut change = Vec::new();
        if was_status != status {
            change.push("status");
        }
        if was_verdict != verdict {
            change.push("headroom");
        }
        if was_resets != "-" && was_resets != resets {
            match clock::epoch_secs(was_resets) {
                Some(reset_epoch) => {
                    if reset_epoch <= tick.wall {
                        change.push("reset");
                    }
                }
                None => {
                    let _ = writeln!(
                        std::io::stderr(),
                        "account-reset-unparsed account={key} binding_resets_at={was_resets}"
                    );
                }
            }
        }
        if change.is_empty() {
            continue;
        }
        events.push(Event::Account {
            fields: fields(record),
            change: change.join(","),
            was_status: was_status.to_owned(),
            was_verdict: was_verdict.to_owned(),
        });
    }
    (events, changes)
}

impl Listing {
    /// The listing read as one JSON array of records each carrying `status`
    /// and `verdict` (`account_roster_read`'s jq), or none: an answer of
    /// another shape is a listing that failed to render, never a fleet with
    /// no accounts.
    fn parse(stdout: &str) -> Option<Listing> {
        let rows: Vec<Value> = serde_json::from_str(stdout).ok()?;
        for row in &rows {
            if row.get("status").is_none_or(Value::is_null)
                || row.get("verdict").is_none_or(Value::is_null)
            {
                return None;
            }
        }
        Some(Listing(rows))
    }

    /// The `account <fields>` line of each record (`:5155-5157`).
    fn lines(&self) -> Vec<String> {
        self.0
            .iter()
            .map(|r| format!("account {}", fields(r)))
            .collect()
    }

    /// Whether an account bills the harness and pool a pick would judge
    /// (`owed_wall`'s roster check).
    fn bills(&self, billed: &str, pool: &str) -> bool {
        self.0.iter().any(|r| {
            r.get("harness").and_then(Value::as_str) == Some(billed)
                && ((r.get("pool").and_then(Value::as_str) == Some("api-credit"))
                    == (pool == "api-credit"))
        })
    }
}

/// `lanes` through the one runner, under `ORCH_LANE_HOST=<host>` where a
/// host is named, as the legacy `bounded_account_read` ran it: the answer,
/// or the call's own failure.
#[allow(
    clippy::disallowed_methods,
    reason = "the heartbeat's legacy account reads, `lanes list --json` and `lanes pick` (decision 121 Q9), through the one runner under its tag with the lane host named"
)]
fn lanes(
    settings: &Settings,
    host: Option<&str>,
    args: &[&str],
) -> std::result::Result<std::process::Output, String> {
    let env: Vec<(&str, &OsStr)> = host
        .map(|h| vec![("ORCH_LANE_HOST", OsStr::new(h))])
        .unwrap_or_default();
    host::run_tagged_in(
        TAG,
        "lanes",
        &settings.lanes_cli,
        "list",
        args,
        Place {
            cwd: None,
            env: &env,
        },
        BOUND,
    )
    .map_err(|e| e.to_string())
}

/// `lanes list --json`, for `host` where one is named: the listing, or
/// the cause where the call failed or its answer did not read, for the
/// caller to say in its place (`account-unread`'s fields, `:5165`).
fn listing(settings: &Settings, host: Option<&str>) -> std::result::Result<Listing, String> {
    let host_word = host.unwrap_or(LOCAL);
    let out = lanes(settings, host, &["list", "--json"])
        .map_err(|cause| format!("host={host_word} {cause}"))?;
    if !out.status.success() {
        return Err(format!(
            "host={host_word} exit={} {}",
            out.status.code().unwrap_or(-1),
            host::stderr_text(&out).trim()
        ));
    }
    Listing::parse(&host::stdout_text(&out)).ok_or_else(|| format!("host={host_word} parse=failed"))
}

// --- the owed verdict ------------------------------------------------------------------------

/// `lane_pick_harness` (`lib/lane-launch.sh:128`): the harness an
/// account is billed under for a launch of `harness` on `model`.
fn pick_harness(harness: &str, model: &str) -> &'static str {
    match harness {
        "claude" => "claude",
        "codex" => "codex",
        "copilot" => "copilot",
        "pi" => {
            if model.starts_with("pi-claude/") {
                "claude"
            } else if model.starts_with("github-copilot/") || model.starts_with("anthropic/") {
                "pi"
            } else {
                "unmeasured"
            }
        }
        _ => "unmeasured",
    }
}

/// `lane_pick_pool` (`lib/lane-launch.sh:143`) with the plan pool: the
/// spending pool a launch of `harness` on `model` names.
fn pick_pool(harness: &str, model: &str) -> &'static str {
    match harness {
        "pi" if model.starts_with("anthropic/") => "api-credit",
        "copilot" => "copilot",
        "pi" if model.starts_with("github-copilot/") => "copilot",
        _ => "plan",
    }
}

/// `owed_wall` (`oversee-watch:5641`): the verdict of one host, harness and
/// model, judged on that host's listing and `lanes pick`.
fn wall_verdict(
    settings: &Settings,
    listings: &mut BTreeMap<String, Option<Listing>>,
    owed: &OwedItem,
) -> String {
    let unjudged = format!("verdict=unjudged harness={}", owed.harness);
    let host = (owed.host != LOCAL).then_some(owed.host.as_str());
    let listing = listings.entry(owed.host.clone()).or_insert_with(|| {
        listing(settings, host)
            .map_err(|cause| note("accounts", &cause))
            .ok()
    });
    let Some(listing) = listing else {
        return unjudged;
    };
    if !listing.bills(
        pick_harness(&owed.harness, &owed.model),
        pick_pool(&owed.harness, &owed.model),
    ) {
        return "verdict=queue".to_owned();
    }
    let mut args = vec!["pick", "--harness", owed.harness.as_str(), "--json"];
    if owed.model != "-" {
        args.push("--native-model");
        args.push(owed.model.as_str());
    }
    let out = match lanes(settings, host, &args) {
        Ok(out) => out,
        Err(cause) => {
            note(
                "pick",
                &format!("host={} harness={} {cause}", owed.host, owed.harness),
            );
            return unjudged;
        }
    };
    match out.status.code() {
        Some(0) => "verdict=queue".to_owned(),
        Some(3) => {
            let Ok(answer) = serde_json::from_str::<Value>(&host::stdout_text(&out)) else {
                return unjudged;
            };
            match answer.get("walled").and_then(Value::as_u64) {
                Some(walled) if walled > 0 => {
                    let until = match answer.get("walled_resets_at") {
                        None | Some(Value::Null) => "-".to_owned(),
                        Some(Value::String(s)) => s.clone(),
                        Some(_) => return unjudged,
                    };
                    format!("verdict=dated harness={} until={until}", owed.harness)
                }
                Some(_) | None => unjudged,
            }
        }
        _ => unjudged,
    }
}

/// The `owed` line (`:5455-5470`): the record's fields, then the verdict,
/// a merged delivery or a queue verdict needing no account read.
fn owed_line(
    settings: &Settings,
    listings: &mut BTreeMap<String, Option<Listing>>,
    owed: &OwedItem,
) -> String {
    let verdict = match &owed.delivery {
        Some(delivery) => format!("verdict=merged {delivery}"),
        None if owed.harness == "-" => "verdict=queue".to_owned(),
        None => wall_verdict(settings, listings, owed),
    };
    format!(
        "owed {} state={} priority={} lane={} {verdict}",
        owed.id,
        owed.state.word(),
        owed.priority,
        owed.lane
    )
}

// --- the body ----------------------------------------------------------------------------------

fn run(ctx: &Context, tick: &Tick) -> Produced {
    let (owed, quota, open, github) = {
        let latest = ctx.shared.lock().unwrap_or_else(|p| p.into_inner());
        (
            latest.tracker.as_ref().map(|t| t.owed.clone()),
            latest.quota.as_ref().map(|q| q.line(tick.wall)),
            latest.tracker.as_ref().map(|t| t.open_unblocked.clone()),
            latest.github.clone(),
        )
    };
    // The roster, the local host's listing, read once: the account events
    // ahead of the heartbeat line, as the legacy's pass printed them, then
    // the roster lines under it; the owed verdicts of local records reuse
    // it. A roster that could not be read is the pass's partial failure
    // with the legacy's `account-unread` fields, said by the runner.
    let roster = listing(&ctx.settings, None);
    let (mut events, changes, failed) = match &roster {
        Ok(listing) => {
            let (events, changes) = check_accounts(listing, tick);
            (events, changes, None)
        }
        Err(cause) => (
            Vec::new(),
            Vec::new(),
            Some(format!(
                "account-unread path={} {cause}",
                ctx.settings.lanes_cli.display()
            )),
        ),
    };
    events.push(Event::Heartbeat {
        loops: ctx.max_loops,
        interval: ctx.interval,
        since: ctx.since.clone(),
    });
    let mut body = |line: String| events.push(Event::Body { line });
    let bot_fix = github
        .as_ref()
        .map(|g| g.bot_fix.clone())
        .unwrap_or_default();
    for repo in &ctx.repos {
        for line in open_lines(ctx, repo, &bot_fix) {
            body(line);
        }
    }
    match &roster {
        Err(_) => body("account-roster unread".to_owned()),
        Ok(listing) => {
            body(format!("account-roster accounts={}", listing.0.len()));
            for line in listing.lines() {
                body(line);
            }
        }
    }
    let mut listings: BTreeMap<String, Option<Listing>> = BTreeMap::new();
    listings.insert(LOCAL.to_owned(), roster.ok());
    for line in ctx
        .verifying
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .iter()
    {
        body(line.clone());
    }
    // The owed list, or `owed unread` while the tracker duty has read
    // nothing (the legacy printed no owed line then: its heartbeat died
    // with the failed read), so a standing tracker failure never reads
    // as nothing owed.
    match &owed {
        None => body("owed unread".to_owned()),
        Some(items) => {
            for item in items {
                body(owed_line(&ctx.settings, &mut listings, item));
            }
        }
    }
    if let Some(quota) = quota {
        body(quota);
    }
    // `pr_watch_context` (`lib/pr-watch-pass.sh:96`): the reducer's standing
    // attention, as the GitHub duty's last pass left it.
    if let Some(context) = github.as_ref().and_then(|g| g.pr_watch.as_ref()) {
        body(format!("pr-watch rc={}", context.rc));
        for line in context.out.lines().chain(context.err.lines()) {
            body(line.to_owned());
        }
    }
    // Decision 126 (1): the one capacity line, every open unblocked item
    // no lane holds, from the tracker duty's inventory; `unread` until it
    // has read one.
    match open {
        None => body("open-unblocked count=unread items=-".to_owned()),
        Some(items) => body(format!(
            "open-unblocked count={} items={}",
            items.len(),
            if items.is_empty() {
                "-".to_owned()
            } else {
                items.join(",")
            }
        )),
    }
    Produced {
        events,
        changes,
        failed,
        ..Produced::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `lane_pick_harness` and `lane_pick_pool` on the launcher's own
    /// cases (`lib/lane-launch.sh:128-150`).
    #[test]
    fn the_billed_harness_and_pool_follow_the_launchers_tables() {
        let rows = [
            ("claude", "claude-sonnet-5", "claude", "plan"),
            ("codex", "-", "codex", "plan"),
            ("copilot", "-", "copilot", "copilot"),
            ("pi", "pi-claude/opus", "claude", "plan"),
            ("pi", "github-copilot/gpt", "pi", "copilot"),
            ("pi", "anthropic/claude", "pi", "api-credit"),
            ("pi", "other/model", "unmeasured", "plan"),
        ];
        for (harness, model, billed, pool) in rows {
            assert_eq!(pick_harness(harness, model), billed, "{harness} {model}");
            assert_eq!(pick_pool(harness, model), pool, "{harness} {model}");
        }
    }

    /// A listing is one array of records each carrying `status` and
    /// `verdict`; anything else is unread, never an empty roster.
    #[test]
    fn a_listing_reads_whole_or_not_at_all() {
        assert!(Listing::parse("[]").is_some_and(|l| l.0.is_empty()));
        assert!(Listing::parse("").is_none());
        assert!(Listing::parse("{}").is_none());
        assert!(Listing::parse(r#"[{"alias":"a","status":"ok"}]"#).is_none());
        let listing = Listing::parse(
            r#"[{"alias":"a","harness":"claude","config_dir":"/h/.a","measured_through":"local","status":"ok","verdict":"room","headroom_pct":0,"binding_bucket":"weekly","binding_resets_at":"2026-10-01T00:00:00Z"}]"#,
        )
        .unwrap();
        assert_eq!(
            listing.lines(),
            vec![
                "account a config_dir=/h/.a harness=claude through=local status=ok verdict=room headroom_pct=0 binding_bucket=weekly binding_resets_at=2026-10-01T00:00:00Z"
            ]
        );
        assert!(listing.bills("claude", "plan"));
        assert!(!listing.bills("codex", "plan"));
        assert!(!listing.bills("claude", "api-credit"));
    }
}
