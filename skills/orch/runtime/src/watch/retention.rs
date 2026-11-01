//! The retention duty (decisions 128 (9), 141 (1), (2), 146; step5-map
//! § A11): each record judged by its own recorded end, never a directory
//! by its newest write, and nothing dropped that is unresolved or unread.
//!
//! What it judges. (1) The event log's rotated segments (`events`): a
//! segment whose last write is past `ORCH_RECORD_RETENTION_DAYS` goes,
//! except the newest, which fixes the live log's line numbering. (2) A
//! lane's own paths under the state directory, every entry whose name
//! carries the item as a whole token, as the legacy `prune` named them,
//! but `lane-mail/` never (unread mail is the mailbox's, decision 8): they
//! go only when the lane is ended, on any terminal word the legacy or this
//! runtime wrote or a confirmed close bound to the record's session (its
//! `lane_since` the record's `session_since`, so an earlier session's close
//! ends nothing a relaunch runs), never `done` alone (141 (1)), its
//! recorded end is past the retention, and its worktree is released or its
//! keep reason recorded (128 (9); U5j's `kept`). A kept
//! worktree is kept on purpose and never touched here; a standing worktree
//! with no reason recorded keeps everything, since the work in it is
//! unresolved. (3) The lane records and fleet log rows past the retention,
//! through [`crate::ops::prune::prune_records`], the fleet transition
//! applied after each pass through `ops::apply` under its `Request` variant
//! (decision 153 (3)); the store writes nothing when nothing leaves.
//!
//! The runner's own records (the claim, the argv, the live log, the
//! baseline, the stop request, the wake record) are never judged here.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use agent_runtime::clock;
use serde_json::Value;

use crate::error::{Error, Result};
use crate::ops::prune::PruneRecords;
use crate::ops::{Env, Request};
use crate::settings::Settings;
use crate::state::{self, Document, Locking, WORKTREE_KEPT};
use crate::watch::{Body, Paths, Produced, Runner, Tick, events};

/// Every word a lane record read as ended under (decision 141 (1), from
/// the round-6 reading): `done`, which the legacy `lane-close` and this
/// runtime's close write, and `closed`, the older vintage's. `stopped` and
/// `parked` are not ended: a relaunch resumes into their files, and the
/// terminal-lanes step closes them when the tracker shows the item ended.
pub const TERMINAL_WORDS: [&str; 2] = ["done", "closed"];

const SECS_PER_DAY: u64 = 86_400;

/// What the duty runs with, fixed at registration.
pub struct Context {
    /// The fleet state file.
    pub fleet: PathBuf,
    /// The runner's records beside it: the log whose segments are judged.
    pub paths: Paths,
    pub settings: Settings,
    pub locking: Locking,
}

pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| run(&ctx, tick))
}

/// Register the duty on `runner` for the fleet at `path` (decision 153).
pub fn register(
    runner: &mut Runner<'_>,
    path: &Path,
    settings: &Settings,
    locking: Locking,
) -> Result<()> {
    runner.register(
        crate::schedule::Duty::Retention,
        body(Context {
            fleet: path.to_path_buf(),
            paths: Paths::of(path)?,
            settings: settings.clone(),
            locking,
        }),
    );
    Ok(())
}

/// The moment before which a recorded end is past the retention.
pub fn cutoff(now: u64, days: u32) -> u64 {
    now.saturating_sub(u64::from(days) * SECS_PER_DAY)
}

// --- the judgement ---------------------------------------------------------------------

/// What retention does with one lane record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Judgement {
    /// Live, not past the retention, no recorded end, or a standing
    /// worktree with no reason recorded: nothing goes.
    Keep,
    /// Ended and past the retention, its worktree released or kept on
    /// purpose: the lane's paths and its record go, the `kept` word with
    /// the record (`kept` names the reason), and a kept worktree is never
    /// touched.
    Prune { kept: Option<String> },
}

fn field<'a>(record: &'a Value, key: &str) -> Option<&'a str> {
    record.get(key).and_then(Value::as_str)
}

/// The confirmed closes bound to `lane`'s session: a `close-owned-
/// resources` of `item` whose `lane_since` is the record's `session_since`,
/// the binding `ops::lane::close_owned_resources` writes on the intent and
/// `ops::lane::lane_moved` judges a moved lane by. A relaunch writes a new
/// `session_since` and keeps the earlier close among the intents, so that
/// close counts for nothing the new session runs.
fn confirmed_closes<'a>(
    lane: &Value,
    item: &str,
    intents: &'a [Value],
) -> impl Iterator<Item = &'a Value> {
    let since = field(lane, "session_since");
    intents.iter().filter(move |i| {
        field(i, "op") == Some("close-owned-resources")
            && field(i, "target") == Some(item)
            && field(i, "outcome") == Some("confirmed")
            && field(i, "lane_since") == since
    })
}

/// The lane's recorded end: the latest `completed_at` among the confirmed
/// closes bound to its session, else the latest `close` fleet-log row's
/// `at` for the item, else its `launched_at`, the one stamp every vintage
/// carries. `None` where no stamp parses: a record with no recorded end is
/// never pruned.
fn recorded_end(lane: &Value, item: &str, intents: &[Value], fleet_log: &[Value]) -> Option<u64> {
    let closes = confirmed_closes(lane, item, intents)
        .filter_map(|i| field(i, "completed_at"))
        .filter_map(clock::epoch_secs)
        .max();
    if closes.is_some() {
        return closes;
    }
    let rows = fleet_log
        .iter()
        .filter(|r| field(r, "kind") == Some("close") && field(r, "item") == Some(item))
        .filter_map(|r| field(r, "at"))
        .filter_map(clock::epoch_secs)
        .max();
    if rows.is_some() {
        return rows;
    }
    field(lane, "launched_at").and_then(clock::epoch_secs)
}

/// How the worktree stands for retention.
enum Worktree {
    Released,
    Kept(String),
    Standing,
}

/// How the lane's worktree stands: `kept` on the record is a worktree kept
/// on purpose; else its session's confirmed close's set where it discharged a
/// `worktree` obligation (`released`, `released:mail-kept:`, `worktree-
/// gone`, `lane-moved` are released, `kept:<reason>` kept); else the disk
/// as the legacy `prune` read it: a `mail_root` that is absent, or is the
/// main checkout, owes no worktree; one that stands keeps the lane; one
/// that cannot be read keeps it too.
fn worktree(lane: &Value, item: &str, intents: &[Value], project: &Path) -> Worktree {
    if let Some(reason) = field(lane, "kept") {
        return Worktree::Kept(reason.to_owned());
    }
    for close in confirmed_closes(lane, item, intents) {
        let Some(discharged) = close
            .pointer("/obligations/discharged")
            .and_then(Value::as_array)
        else {
            continue;
        };
        for d in discharged {
            if d.pointer("/obligation/kind").and_then(Value::as_str) != Some("worktree") {
                continue;
            }
            let by = field(d, "by").unwrap_or("");
            return match by.strip_prefix(WORKTREE_KEPT) {
                Some(reason) => Worktree::Kept(reason.to_owned()),
                None => Worktree::Released,
            };
        }
    }
    match field(lane, "mail_root") {
        None | Some("") => Worktree::Released,
        Some(root) if Path::new(root) == project => Worktree::Released,
        Some(root) => match std::fs::metadata(root) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Worktree::Released,
            Ok(_) | Err(_) => Worktree::Standing,
        },
    }
}

/// Judge one lane record against `cutoff` (141 (1), (2); 128 (9)).
pub fn judge(
    lane: &Value,
    intents: &[Value],
    fleet_log: &[Value],
    project: &Path,
    cutoff: u64,
) -> Judgement {
    let Some(item) = field(lane, "item") else {
        return Judgement::Keep;
    };
    // Ended by its own status, or by a confirmed close of this session: a
    // record relaunched since its last close reads `running` with that
    // close still among the intents, and is live.
    let ended = field(lane, "status").is_some_and(|s| TERMINAL_WORDS.contains(&s))
        || confirmed_closes(lane, item, intents).next().is_some();
    if !ended {
        return Judgement::Keep;
    }
    match recorded_end(lane, item, intents, fleet_log) {
        Some(end) if end < cutoff => {}
        Some(_) | None => return Judgement::Keep,
    }
    match worktree(lane, item, intents, project) {
        Worktree::Released => Judgement::Prune { kept: None },
        Worktree::Kept(reason) => Judgement::Prune { kept: Some(reason) },
        Worktree::Standing => Judgement::Keep,
    }
}

// --- the paths -------------------------------------------------------------------------------

/// Whether `name` carries `item` as a whole token (`unit_names_item`):
/// `(^|[-_.])ITEM([-_.]|$)`, so no file of an item whose key extends it.
pub fn names_item(name: &str, item: &str) -> bool {
    let boundary = |c: Option<char>| c.is_none_or(|c| matches!(c, '-' | '_' | '.'));
    name.match_indices(item).any(|(at, _)| {
        boundary(name[..at].chars().next_back()) && boundary(name[at + item.len()..].chars().next())
    })
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn read_dir(dir: &Path) -> Result<Vec<PathBuf>> {
    match std::fs::read_dir(dir) {
        Ok(entries) => entries
            .map(|e| e.map(|e| e.path()))
            .collect::<std::io::Result<Vec<_>>>()
            .map_err(|e| agent_runtime::Error::io("read-dir", dir, e).into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(agent_runtime::Error::io("read-dir", dir, e).into()),
    }
}

/// The entries under the state directory the lane `item` owns: every
/// direct entry named for it but the mailbox (`lane-mail/`, never) and the
/// fleet's and the runner's own records, and under `handoffs/` every file
/// named for it; the legacy `state_units` per item. Each is one record
/// judged by the lane's end, never by its own or its directory's write.
pub fn lane_paths(paths: &Paths, item: &str) -> Result<Vec<PathBuf>> {
    let fleet_name = name_of(&paths.state);
    let fleet_lock = format!("{fleet_name}.lock");
    // The runner's own records share the log's stem: `oversee-watch.pid`,
    // `.argv`, `.log` and its segments, the baseline, the stop request,
    // the wake record.
    let runner = format!(
        "{}.",
        paths
            .log
            .file_stem()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    );
    let mut out = Vec::new();
    for entry in read_dir(&paths.dir)? {
        let name = name_of(&entry);
        if name == fleet_name
            || name == fleet_lock
            || name.starts_with(&runner)
            || name == "lane-mail"
        {
            continue;
        }
        if name == "handoffs" {
            for file in read_dir(&entry)? {
                if names_item(&name_of(&file), item) {
                    out.push(file);
                }
            }
            continue;
        }
        if names_item(&name, item) {
            out.push(entry);
        }
    }
    out.sort();
    Ok(out)
}

/// Remove one record's path, a file or a tree: a path gone already is
/// removed, an unreadable one is the failure named.
#[allow(
    clippy::disallowed_methods,
    reason = "the retention duty's one removal of a lane's own paths under the state directory and the log's rotated segments, each judged by its own recorded end"
)]
fn remove_path(path: &Path) -> Result<()> {
    let outcome = match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => std::fs::remove_dir_all(path),
        Ok(_) => std::fs::remove_file(path),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => Err(e),
    };
    outcome.map_err(|e| agent_runtime::Error::io("remove", path, e).into())
}

/// A file's last write as an epoch second: a rotated segment's own
/// recorded end, which is its last line's.
#[allow(
    clippy::disallowed_methods,
    reason = "a rotated log segment's modification time read as an epoch second, the segment's own recorded end, beside the injected clock's cutoff"
)]
fn last_write(path: &Path) -> Result<u64> {
    let modified = std::fs::metadata(path)
        .and_then(|m| m.modified())
        .map_err(|e| agent_runtime::Error::io("modified", path, e))?;
    Ok(modified
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0))
}

/// Remove the rotated segments of `log` whose last write is before
/// `cutoff`, the newest excepted; the paths removed.
pub fn prune_segments(log: &Path, cutoff: u64) -> Result<Vec<PathBuf>> {
    let segments = events::segments(log)?;
    let mut removed = Vec::new();
    let Some((_, older)) = segments.split_last() else {
        return Ok(removed);
    };
    for segment in older {
        if last_write(&segment.path)? < cutoff {
            remove_path(&segment.path)?;
            removed.push(segment.path.clone());
        }
    }
    Ok(removed)
}

/// The fleet record, read once per pass, as the file holds it: a record of
/// an old vintage is judged by its words, not refused by a type.
#[allow(
    clippy::disallowed_methods,
    reason = "the retention duty's one read of the fleet record per pass, which it judges and never writes"
)]
fn load_fleet(path: &Path) -> Result<Document> {
    Ok(state::load(path)?
        .ok_or_else(|| Error::RecordMissing {
            path: path.to_path_buf(),
        })?
        .doc)
}

fn array<'a>(doc: &'a Document, key: &str) -> &'a [Value] {
    doc.get(key)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// What one pass removed, and the records it judged past the retention.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Pruned {
    pub segments: Vec<PathBuf>,
    pub paths: Vec<PathBuf>,
    /// The items whose lane records are past the retention, in record
    /// order, the first record left out: what `prune-records` drops.
    pub records: Vec<String>,
}

/// One pass over the records at `fleet` beside `paths`, at `now`.
pub fn pass(fleet: &Path, paths: &Paths, project: &Path, days: u32, now: u64) -> Result<Pruned> {
    let cutoff = cutoff(now, days);
    let mut pruned = Pruned {
        segments: prune_segments(&paths.log, cutoff)?,
        ..Pruned::default()
    };
    let doc = load_fleet(fleet)?;
    let intents = array(&doc, "intents");
    let fleet_log = array(&doc, "fleet_log");
    let lanes = array(&doc, "lanes");
    let judged: Vec<(Option<&str>, Judgement)> = lanes
        .iter()
        .map(|lane| {
            (
                field(lane, "item"),
                judge(lane, intents, fleet_log, project, cutoff),
            )
        })
        .collect();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for (index, (item, judgement)) in judged.iter().enumerate() {
        let Some(item) = item else { continue };
        if index > 0 && matches!(judgement, Judgement::Prune { .. }) {
            pruned.records.push((*item).to_owned());
        }
        if !seen.insert(item) {
            continue;
        }
        // Every record of the item must be past its end: a relaunch's live
        // record keeps the paths an earlier record of the same item shares.
        if judged
            .iter()
            .any(|(other, j)| *other == Some(item) && *j == Judgement::Keep)
        {
            continue;
        }
        for path in lane_paths(paths, item)? {
            remove_path(&path)?;
            pruned.paths.push(path);
        }
    }
    Ok(pruned)
}

/// The pass, then the judged records and the fleet-log rows past the
/// cutoff leave the fleet state through the one dispatcher; the store
/// writes nothing when nothing leaves.
#[allow(
    clippy::disallowed_methods,
    reason = "the retention duty's one fleet write per pass, `prune-records` through `ops::apply`, from the judgement its pass made on the disk"
)]
fn run(ctx: &Context, tick: &Tick) -> Result<Produced> {
    let pruned = pass(
        &ctx.fleet,
        &ctx.paths,
        &ctx.settings.roots.project,
        ctx.settings.retention_days,
        tick.wall,
    )?;
    let request = Request::PruneRecords(PruneRecords {
        lanes: pruned.records,
        cutoff: cutoff(tick.wall, ctx.settings.retention_days),
    });
    let env = Env {
        now_secs: tick.wall,
        now_nanos: u128::from(tick.wall) * 1_000_000_000,
        nonce: 0,
        owner: None,
    };
    crate::ops::apply(&ctx.fleet, &request, &env, ctx.locking)?;
    Ok(Produced::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `unit_names_item`'s token rule: the item whole, never a key that
    /// extends it.
    #[test]
    fn a_name_carries_an_item_as_a_whole_token_only() {
        let rows = [
            ("workflow-state-KEN-1.json", "KEN-1", true),
            ("workflow-state-KEN-1.json.lock", "KEN-1", true),
            ("lane-status-KEN-1.md", "KEN-1", true),
            ("KEN-1", "KEN-1", true),
            ("workflow-state-KEN-10.json", "KEN-1", false),
            ("workflow-state-KEN-1a.json", "KEN-1", false),
            ("xKEN-1.json", "KEN-1", false),
            ("KEN-1-handoff.md", "KEN-1", true),
            ("issue-7.run", "issue-7", true),
            ("issue-77.run", "issue-7", false),
        ];
        for (name, item, want) in rows {
            assert_eq!(names_item(name, item), want, "{name} {item}");
        }
    }
}
