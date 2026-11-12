//! The heartbeat's body: the one periodic line, due every `max-loops ×
//! interval` seconds from the last heartbeat on the runner's own schedule,
//! and under it every `--repo`'s open pull requests, a Dependabot one
//! marked by the GitHub duty's `bot-fix` row; the account roster through
//! the accounts judge; the `verifying` lines of the verification duty's
//! last pass; the `owed` lines of the tracker duty's last pass with their
//! wall verdicts through the accounts judge's chooser; the standing
//! tracker quota receipt; the reducer's standing attention; and one line
//! naming the open unblocked items no lane holds. The body reads no
//! inventory itself: the tracker, GitHub and verification duties' slots are
//! its inputs, and it hands back `next_due: None`, so nothing it does moves
//! its own due time.
//!
//! A read the body could not make (the open list, the roster) is its line
//! with `unread` in that place: the one periodic line is never dropped.
//! The owed list has the same word, `owed unread`, while the tracker duty
//! has read nothing: a standing tracker failure never reads as nothing
//! owed.
//!
//! The roster read also compares each account's status, verdict and
//! binding reset with the reading the baseline holds under its `account`
//! row: an `account` event ahead of the heartbeat line when one changed,
//! the row advanced after the line is durable. This body is the one duty
//! that reads the roster, so the comparison runs on the heartbeat's
//! cadence. A roster that could not be read is the pass's partial failure
//! and moves no row: the next readable pass compares against the last
//! reading, never against nothing.
//!
//! The roster is the listing under the machine's own retirement
//! statement, so a retired account keeps its figures in the roster and a
//! stated end its credential contradicts is a line under it.

use agent_runtime::intent::Owner;
use agent_runtime::record::Locking;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;

use crate::verify::wire::Pull;

use crate::ops::Host;
use crate::ops::accounts;
use crate::settings::Settings;
use crate::watch::tracker::{OwedItem, Shared};
use crate::watch::verifying::Lines;
use crate::watch::{Body, Change, Event, Produced, Runner, Tick};
use agent_runtime::accounts::{
    PickAnswer, PickRequest, Roster, pick_harness, pick_pool, text_or_dash,
};
use agent_runtime::journal::Env;

/// The host word of a lane record with no host.
const LOCAL: &str = "local";

/// What the duty runs with, fixed at registration.
pub struct Context {
    pub settings: Settings,
    /// The fleet state the owed verdicts' judge reads its seats and live
    /// charges from.
    pub path: PathBuf,
    /// The watch's `--max-loops`, `--interval` and `--since`, the line's
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
    /// The stamp inputs and the lock policy of the notice retry's marks.
    pub locking: Locking,
    pub nonce: u32,
    pub owner: Option<Owner>,
}

pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| Ok(run(&ctx, tick)))
}

/// Register the body on `runner`, replacing the runner's
/// placeholder: the three flags the line carries, `repos` the watch's
/// `--repo` names, `shared` the tracker and GitHub duties' slot,
/// `verifying` the verification duty's lines, `env` and `locking` the
/// notice retry's stamp and lock policy.
#[allow(
    clippy::too_many_arguments,
    reason = "the one registration line names each input the body has; a struct for them would be built on that line alone"
)]
pub fn register(
    runner: &mut Runner<'_>,
    path: &Path,
    settings: &Settings,
    interval: Duration,
    max_loops: u32,
    since: Option<String>,
    repos: Vec<String>,
    shared: Shared,
    verifying: Lines,
    env: &Env,
    locking: Locking,
) {
    runner.register(
        crate::schedule::Duty::Heartbeat,
        body(Context {
            settings: settings.clone(),
            path: path.to_path_buf(),
            max_loops,
            interval,
            since,
            repos,
            gh: PathBuf::from("gh"),
            shared,
            verifying,
            locking,
            nonce: env.nonce,
            owner: env.owner.clone(),
        }),
    );
}

/// A read that did not answer, said once on stderr for the launcher's
/// record of this run; the body's line names it `unread`.
fn note(what: &str, cause: &str) {
    let _ = writeln!(std::io::stderr(), "heartbeat-{what}-unread {cause}");
}

// --- the open pull requests ------------------------------------------------------------

/// The repository's open pull requests: `<repo>\t<n>\t
/// <head>\t<title>`, or `<repo>\tbot-fix pr=<n> alert=<alerts>` for one the
/// GitHub duty's `bot-fix` row names. The list is read whole through the
/// one paging reader; a list that could not be read whole is one `unread`
/// line, never a shorter list.
fn open_lines(ctx: &Context, repo: &str, bot_fix: &BTreeMap<String, String>) -> Vec<String> {
    let gh = crate::watch::github::handle(&ctx.gh);
    let path = format!("repos/{repo}/pulls?state=open");
    let pulls: Vec<Pull> = match gh.list::<Pull>("open-pulls", &path) {
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
                    pull.number, pull.head.branch, pull.title
                ),
            },
        )
        .collect()
}

// --- the roster -------------------------------------------------------------------------

/// The baseline row kind each account's reading is kept under.
const ACCOUNT_ROW: &str = "account";

/// The account comparison over one listing: per
/// record the `status|verdict|resets` reading beside the row's
/// `status|verdict|resets|unmeasured`, an `account` event where the
/// status, the verdict or a passed reset changed from the row's, the row
/// advanced on every reading that differs. The first sighting is the
/// baseline and says nothing. An `unmeasured` verdict leaves the row on
/// the reading before it unless its status is `expired` or `retired`,
/// which need the operator, so each such status after a measured reading
/// is news. A reset is news once the reset the row holds has passed
/// (against the pass's wall, every reset written as one whole-second UTC
/// stamp) and the reading moved off it; one that
/// moved while still ahead is a different binding, not a reset; one no
/// date can read settles no reset and is noted. An account the listing
/// stops naming keeps its row.
fn check_accounts(listing: &Roster, tick: &Tick) -> (Vec<Event>, Vec<Change>) {
    let mut events = Vec::new();
    let mut changes = Vec::new();
    for record in &listing.rows {
        let key = record.key();
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
        let status = record.status.clone();
        let verdict = record.verdict.clone();
        let resets = text_or_dash(&record.raw, "binding_resets_at");
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
            fields: record.fields(),
            change: change.join(","),
            was_status: was_status.to_owned(),
            was_verdict: was_verdict.to_owned(),
        });
    }
    (events, changes)
}

// --- the owed verdict ------------------------------------------------------------------------

/// The verdict of one host, harness and model, judged on that host's
/// listing and the accounts judge's chooser (`ops::accounts::pick_fleet`):
/// an account to spend is `queue`; no account, some walled, is `dated`
/// until the earliest reset the judge names; anything else, an unjudged
/// pick among it, is `unjudged`, never a verdict.
fn wall_verdict(
    ctx: &Context,
    host: &Host,
    listings: &mut BTreeMap<String, Option<Roster>>,
    owed: &OwedItem,
    now: u64,
) -> String {
    let unjudged = format!("verdict=unjudged harness={}", owed.harness);
    // The item's host as recorded, `local` included: the judge reads a
    // local item on this machine's listing whatever provider is set.
    let listing = listings.entry(owed.host.clone()).or_insert_with(|| {
        accounts::roster(&ctx.settings, Some(&owed.host), now)
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
    let request = PickRequest {
        harness: owed.harness.clone(),
        model: (owed.model != "-").then(|| owed.model.clone()),
        ..PickRequest::default()
    };
    match accounts::pick_fleet(
        &ctx.settings,
        &ctx.path,
        host,
        Some(&owed.host),
        None,
        &request,
        now,
    ) {
        PickAnswer::Lane(_) => "verdict=queue".to_owned(),
        PickAnswer::None {
            walled,
            walled_resets_at,
            ..
        } if walled > 0 => format!(
            "verdict=dated harness={} until={}",
            owed.harness,
            walled_resets_at.unwrap_or_else(|| "-".to_owned())
        ),
        PickAnswer::None { .. } => unjudged,
        PickAnswer::Unjudged { cause } => {
            note(
                "pick",
                &format!("host={} harness={} {cause}", owed.host, owed.harness),
            );
            unjudged
        }
        // A grant pool nobody measured is no verdict; a named-lane answer
        // never reaches a chooser's request.
        PickAnswer::ProviderUnmeasured { .. }
        | PickAnswer::Unbilled { .. }
        | PickAnswer::Walled(_)
        | PickAnswer::Reserved(_)
        | PickAnswer::Retired { .. }
        | PickAnswer::Excluded(_)
        | PickAnswer::Unmeasured(_)
        | PickAnswer::CloudRepoUnset(_)
        | PickAnswer::NoRecord => unjudged,
    }
}

/// The `owed` line: the record's fields, then the verdict,
/// a merged delivery or a queue verdict needing no account read.
fn owed_line(
    ctx: &Context,
    host: &Host,
    listings: &mut BTreeMap<String, Option<Roster>>,
    owed: &OwedItem,
    now: u64,
) -> String {
    let verdict = match &owed.delivery {
        Some(delivery) => format!("verdict=merged {delivery}"),
        None if owed.harness == "-" => "verdict=queue".to_owned(),
        None => wall_verdict(ctx, host, listings, owed, now),
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

#[allow(
    clippy::disallowed_methods,
    reason = "the heartbeat's one construction of the kernel host for the owed verdicts' occupancy read; the judge acts on nothing"
)]
fn run(ctx: &Context, tick: &Tick) -> Produced {
    // The occupancy reader the owed verdicts' judge charges live lanes
    // through, as the overseer duty's walk and the `accounts pick` verb
    // build it.
    let host = Host::kernel();
    let (owed, quota, open, github) = {
        let latest = ctx.shared.lock().unwrap_or_else(|p| p.into_inner());
        (
            latest.tracker.as_ref().map(|t| t.owed.clone()),
            latest.quota.as_ref().map(|q| q.line(tick.wall)),
            latest.tracker.as_ref().map(|t| t.open_unblocked.clone()),
            latest.github.clone(),
        )
    };
    // The roster, the listing under the fleet's own host (the provider
    // `ORCH_LANE_HOST` names, else this machine), read once through the
    // accounts judge: the account events ahead of the heartbeat line, then
    // the roster lines under it; the owed verdicts of records on that same
    // host reuse it. A roster that could not be read is the pass's partial
    // failure with the `account-unread` fields, said by the runner.
    let roster = accounts::roster(&ctx.settings, None, tick.wall);
    let (mut events, changes, mut failed) = match &roster {
        Ok(listing) => {
            let (events, changes) = check_accounts(listing, tick);
            (events, changes, None)
        }
        Err(cause) => (
            Vec::new(),
            Vec::new(),
            Some(format!(
                "account-unread path={} {cause}",
                crate::watch::overseer::scripts_dir(&ctx.settings.roots.project).display()
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
            body(format!("account-roster accounts={}", listing.rows.len()));
            for line in listing.lines(&agent_runtime::accounts::today(tick.wall)) {
                body(line);
            }
        }
    }
    let mut listings: BTreeMap<String, Option<Roster>> = BTreeMap::new();
    // A refused account setting left the roster unread above, with its
    // cause; the fleet's own host then names that unread entry.
    let roster_host = ctx
        .settings
        .provider
        .get()
        .ok()
        .and_then(|provider| provider.host)
        .unwrap_or_else(|| LOCAL.to_owned());
    listings.insert(roster_host, roster.ok());
    for line in ctx
        .verifying
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .iter()
    {
        body(line.clone());
    }
    // The owed list, or `owed unread` while the tracker duty has read
    // nothing, so a standing tracker failure never reads as nothing owed.
    match &owed {
        None => body("owed unread".to_owned()),
        Some(items) => {
            for item in items {
                body(owed_line(ctx, &host, &mut listings, item, tick.wall));
            }
        }
    }
    if let Some(quota) = quota {
        body(quota);
    }
    // `pr_watch_context`: the reducer's standing attention, as the GitHub
    // duty's last pass left it.
    if let Some(context) = github.as_ref().and_then(|g| g.pr_watch.as_ref()) {
        body(format!("pr-watch rc={}", context.rc));
        for line in context.out.lines().chain(context.err.lines()) {
            body(line.to_owned());
        }
    }
    // The one capacity line, every open unblocked item no lane holds, from
    // the tracker duty's inventory; `unread` until it has read one.
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
    // The notices whose send got no answer, sent once more here and never
    // on every request: a mark the store refused is its line, a retry that
    // could not run the pass's partial failure.
    let env = Env {
        now_secs: tick.wall,
        now_nanos: u128::from(tick.wall) * 1_000_000_000,
        nonce: ctx.nonce,
        owner: ctx.owner.clone(),
    };
    match crate::effects::send_unanswered_notices(
        &ctx.path,
        &ctx.settings,
        &env,
        ctx.locking,
        tick.clock,
    ) {
        Ok(unmarked) => events.extend(unmarked.into_iter().map(|n| Event::NoticeUnmarked {
            intent: n.intent,
            cause: n.refusal,
        })),
        Err(e) => {
            failed.get_or_insert(format!("notice-retry-failed cause={e}"));
        }
    }
    Produced {
        events,
        changes,
        failed,
        ..Produced::default()
    }
}
