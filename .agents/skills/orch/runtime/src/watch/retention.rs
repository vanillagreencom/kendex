//! The retention duty: each lane record judged by its own recorded end, and
//! the state directory pruned of a closed list of kinds ([`Unit`]), each
//! serialized by a lock the commit holds through its removal or written by
//! nothing once selected. Every other entry stays, whatever its age or
//! name: a lane's files, briefs, handoffs, mailboxes, receipts, notices and
//! operator scratch leave only through an item's close-out
//! (`archive::close_out`) or by hand.
//!
//! Beside the units, the event log's rotated segments past
//! `ORCH_RECORD_RETENTION_DAYS` go, the newest excepted, which fixes the
//! live log's line numbering; only the live log is written. The lane
//! records and fleet-log rows past the retention leave the fleet state
//! through [`crate::ops::prune::prune_records`], applied under its
//! `Request` variant; the store writes nothing when nothing leaves.
//!
//! Every unit is archived before it goes. Under the lock of each record
//! that leaves, a record that moved since the judgement abandons its item;
//! `prune-records` then drops an item's rows only while they equal the
//! judgement's and confirms it, and only a confirmed item's record goes.
//! An abandoned item is judged again next pass, and so is one whose record
//! lock cannot be taken within the wait, its cause the pass's failure. No
//! lock file ever leaves: a record's lock pathname stays while the shell
//! store, which locks it with no check of the inode, can take it.
//!
//! The overseer mailbox is compacted on the same pass by the mailbox
//! skill's own `lane-mail compact`; its refusal is the pass's failure, and
//! the prune still runs.

use agent_runtime::record::{self, Document, Locking};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use agent_runtime::clock;
use agent_runtime::host::tmux;
use agent_runtime::reading::Reading;
use serde_json::Value;

use crate::archive::{name_of, read_dir};
use crate::error::Result;
use crate::mailbox::Mailbox;
use crate::ops::WORKTREE_KEPT;
use crate::ops::prune::{Dropped, PlannedRows, PruneRecords};
use crate::ops::{Report, Request};
use crate::settings::Settings;
use crate::state;
use crate::watch::{Body, Paths, Produced, Runner, Tick, events};
use agent_runtime::journal::Env;

/// Every status word a lane record reads as ended under: `done`, which a
/// close writes, and `closed`, which records of an earlier vintage carry.
/// `stopped` and `parked` are not ended: a relaunch resumes into their
/// files, and the terminal-lanes step closes them when the tracker shows
/// the item ended.
pub const TERMINAL_WORDS: [&str; 2] = ["done", "closed"];

const SECS_PER_DAY: u64 = 86_400;

/// What the duty runs with, fixed at registration.
pub struct Context {
    pub fleet: PathBuf,
    /// The runner's records beside it: the log whose segments are judged.
    pub paths: Paths,
    pub settings: Settings,
    pub locking: Locking,
}

pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| run(&ctx, tick))
}

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Judgement {
    /// Live, not past the retention, no recorded end, or a standing
    /// worktree with no reason recorded: nothing goes.
    Keep,
    /// Ended and past the retention, its worktree released or kept on
    /// purpose: its rows and its item record go, the `kept` word with the
    /// record (`kept` names the reason), and a kept worktree is never
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
        field(i, "op") == Some(agent_runtime::intent::EffectOp::CloseResources.word())
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

enum Worktree {
    Released,
    Kept(String),
    Standing,
}

/// How the lane's worktree stands: `kept` on the record is a worktree kept
/// on purpose; else its session's confirmed close's set where it discharged a
/// `worktree` obligation (`released`, `released:mail-kept:`, `worktree-
/// gone`, `lane-moved` are released, `kept:<reason>` kept); else the disk:
/// a `mail_root` that is absent, or is the main checkout, owes no worktree;
/// one that stands keeps the lane; one that cannot be read keeps it too.
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

// --- the kinds -------------------------------------------------------------------------------

/// Remove one of the log's rotated segments: a path gone already is
/// removed, an unreadable one is the failure named.
#[allow(
    clippy::disallowed_methods,
    reason = "the retention duty's removal of the log's rotated segments, each judged by its own last write; every other path leaves through the archive module after its archive stands"
)]
fn remove_segment(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(agent_runtime::Error::io("remove", path, e).into()),
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "a file's modification time read as an epoch second, its own recorded end, beside the injected clock's cutoff"
)]
fn epoch_of(modified: SystemTime) -> u64 {
    modified
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A file as the judgement read it: a writer's replace moves its write or
/// its inode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Seen {
    written: SystemTime,
    inode: u64,
}

fn stamp(path: &Path) -> Result<Option<Seen>> {
    use std::os::unix::fs::MetadataExt;
    match std::fs::symlink_metadata(path) {
        Ok(meta) => Ok(Some(Seen {
            written: meta
                .modified()
                .map_err(|e| agent_runtime::Error::io("modified", path, e))?,
            inode: meta.ino(),
        })),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(agent_runtime::Error::io("modified", path, e).into()),
    }
}

/// A file's last write as an epoch second, `None` where it does not stand.
fn written(path: &Path) -> Result<Option<u64>> {
    Ok(stamp(path)?.map(|seen| epoch_of(seen.written)))
}

/// Remove the rotated segments of `log` whose last write is before
/// `cutoff`, the newest excepted; the paths removed.
fn prune_segments(log: &Path, cutoff: u64) -> Result<Vec<PathBuf>> {
    let segments = events::segments(log)?;
    let mut removed = Vec::new();
    let Some((_, older)) = segments.split_last() else {
        return Ok(removed);
    };
    for segment in older {
        if written(&segment.path)?.is_some_and(|at| at < cutoff) {
            remove_segment(&segment.path)?;
            removed.push(segment.path.clone());
        }
    }
    Ok(removed)
}

/// A record as the file holds it: one of an old vintage is judged by its
/// words, not refused by a type.
#[allow(
    clippy::disallowed_methods,
    reason = "the retention duty's reads of the fleet record and of an item state past the retention, each judged and never written"
)]
fn load(path: &Path) -> Result<Option<Document>> {
    Ok(state::load(path)?.map(|snapshot| snapshot.doc))
}

fn array<'a>(doc: &'a Document, key: &str) -> &'a [Value] {
    doc.get(key)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// Whether `name` is an owner progress report: `MM-DD-HH-MM.md`, with
/// `-succession` before the extension for the one a succession writes; the
/// report's window reads the same files this duty prunes.
pub(super) fn is_progress_report(name: &str) -> bool {
    let Some(stem) = name
        .strip_suffix(".md")
        .map(|s| s.strip_suffix("-succession").unwrap_or(s))
    else {
        return false;
    };
    let fields: Vec<&str> = stem.split('-').collect();
    fields.len() == 4
        && fields
            .iter()
            .all(|f| f.len() == 2 && f.bytes().all(|b| b.is_ascii_digit()))
}

/// The records of items no lane record judges whose state was last written
/// before `cutoff` and names no linked worktree that stands, by its
/// `worktree` path or by the branch a linked worktree has checked out: a
/// state naming one belongs to a lane still working there.
fn laneless_records(
    paths: &Paths,
    project: &Path,
    judged: &BTreeSet<&str>,
    cutoff: u64,
) -> Result<Vec<Unit>> {
    let fleet_name = name_of(&paths.state);
    let mut out = Vec::new();
    let mut linked: Option<Vec<crate::archive::Worktree>> = None;
    for path in read_dir(&paths.dir)? {
        if name_of(&path) == fleet_name {
            continue;
        }
        let Some(item) = state::item_of(&path).map(str::to_owned) else {
            continue;
        };
        if judged.contains(item.as_str()) {
            continue;
        }
        let Some(seen) = stamp(&path)? else {
            continue;
        };
        if epoch_of(seen.written) >= cutoff {
            continue;
        }
        let Some(doc) = load(&path)? else {
            continue;
        };
        let worktree = doc
            .get("worktree")
            .and_then(Value::as_str)
            .filter(|w| !w.is_empty());
        let branch = doc
            .get("branch")
            .and_then(Value::as_str)
            .filter(|b| !b.is_empty());
        if worktree.is_some() || branch.is_some() {
            let trees = match &linked {
                Some(trees) => trees,
                None => linked.insert(crate::archive::linked_worktrees(project)?),
            };
            let standing = |tree: &crate::archive::Worktree| std::fs::metadata(&tree.path).is_ok();
            let named = worktree
                .filter(|w| std::fs::metadata(w).is_ok())
                .map(|w| crate::archive::resolve(Path::new(w)));
            let by_path = named.is_some_and(|want| {
                trees
                    .iter()
                    .any(|tree| standing(tree) && crate::archive::resolve(&tree.path) == want)
            });
            let by_branch = branch.is_some_and(|want| {
                trees
                    .iter()
                    .any(|tree| standing(tree) && tree.branch.as_deref() == Some(want))
            });
            if by_path || by_branch {
                continue;
            }
        }
        out.push(Unit::Record { path, item, seen });
    }
    Ok(out)
}

/// The files of an intent's effect that leave with it: the pane's receipt,
/// a job's request and its job-unit record. The owner notice is not among
/// them: a reconcile writes it again for a closed intent that still owes
/// it.
const INTENT_FILES: &[fn(&Path, &str) -> PathBuf] = &[
    record::receipt_path,
    record::job_request_path,
    record::job_record_path,
];

/// The [`INTENT_FILES`] of every closed intent whose recorded end and the
/// file's own last write are both before `cutoff`: a receipt a pane writes
/// after a close by hand is as young as its write. An intent in a shape
/// this runtime cannot read keeps its files, and a file no intent in the
/// record names is no unit.
fn intent_files(dir: &Path, intents: &[Value], cutoff: u64) -> Result<Vec<Unit>> {
    let mut out = Vec::new();
    for row in intents {
        let Ok(intent) = serde_json::from_value::<agent_runtime::intent::Intent>(row.clone())
        else {
            continue;
        };
        if intent.open() {
            continue;
        }
        let end = intent.completed_at.as_deref().and_then(clock::epoch_secs);
        for file in INTENT_FILES.iter().map(|path| path(dir, &intent.id)) {
            if written(&file)?.is_some_and(|at| end.map_or(at, |end| end.max(at)) < cutoff) {
                out.push(Unit::IntentFile(file));
            }
        }
    }
    Ok(out)
}

/// The owner progress reports under `dir` last written before `cutoff`.
fn progress_reports(dir: &Path, cutoff: u64) -> Result<Vec<Unit>> {
    let mut out = Vec::new();
    for file in read_dir(dir)? {
        if is_progress_report(&name_of(&file)) && written(&file)?.is_some_and(|at| at < cutoff) {
            out.push(Unit::ProgressReport(file));
        }
    }
    Ok(out)
}

/// The overseer mailbox's session rows files, `session-<server pid>-<pane
/// number>.jsonl` under `overseer`, whose pane is gone: the server answering
/// at `server` is that pid and holds no such pane. A file the
/// fleet record names (`overseer.session_rows`, `overseer.pending.
/// session_rows`, `pending.session_rows`), a link, a server that does not
/// answer there and a pane that cannot be read each keep the file.
#[allow(
    clippy::disallowed_methods,
    reason = "the retention duty's pane read, the answering server's exact pane by id, judged beside the record and never acted on"
)]
fn dead_session_rows(
    overseer: &Path,
    server: Option<&Path>,
    record: &Document,
) -> Result<Vec<PathBuf>> {
    let named: Vec<PathBuf> = [
        "/overseer/session_rows",
        "/overseer/pending/session_rows",
        "/pending/session_rows",
    ]
    .iter()
    .filter_map(|pointer| {
        Value::Object(record.clone())
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(|p| crate::archive::resolve(Path::new(p)))
    })
    .collect();
    let mut dead = Vec::new();
    let mut answered: Option<Option<tmux::Server>> = None;
    for file in read_dir(overseer)? {
        let Some((pid, pane)) = name_of(&file)
            .strip_prefix("session-")
            .and_then(|n| n.strip_suffix(".jsonl"))
            .and_then(|n| n.split_once('-'))
            .filter(|(s, p)| {
                [s, p]
                    .iter()
                    .all(|f| !f.is_empty() && f.bytes().all(|b| b.is_ascii_digit()))
            })
            .and_then(|(s, p)| Some((s.parse::<u32>().ok()?, p.to_owned())))
        else {
            continue;
        };
        if !std::fs::symlink_metadata(&file).is_ok_and(|m| m.is_file())
            || named.contains(&crate::archive::resolve(&file))
        {
            continue;
        }
        let answering =
            answered.get_or_insert_with(|| server.and_then(|socket| tmux::server(socket).ok()));
        let Some(live) = answering.as_ref().filter(|live| live.pid == pid) else {
            continue;
        };
        if matches!(tmux::pane_fields(live, &format!("%{pane}")), Reading::Gone) {
            dead.push(file);
        }
    }
    Ok(dead)
}

/// What a pass removes, the closed list of kinds: nothing else leaves.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Unit {
    /// `workflow-state-<ITEM>.json` of an item every lane record of which
    /// ended past the retention, or of an item no lane record judges (see
    /// [`laneless_records`]). Every writer takes `<record>.lock`, which the
    /// commit holds from the re-read against `seen` through the removal.
    Record {
        path: PathBuf,
        item: String,
        seen: Seen,
    },
    /// One of a closed intent's [`INTENT_FILES`], its own last write past
    /// the retention too. The pane's launch line creates the receipt once, by
    /// a rename, as its last write, even after a close by hand; the request
    /// is an exclusive create, rewritten only by a repeat of an intent still
    /// `unconfirmed`; the job unit writes its record within its launch
    /// bound. A closed intent never reopens.
    IntentFile(PathBuf),
    /// An owner progress report: written once, at the minute its name
    /// carries.
    ProgressReport(PathBuf),
    /// A session rows file of the overseer mailbox (see
    /// [`dead_session_rows`]): only its pane's own session writes it, and
    /// that pane is gone.
    SessionRows(PathBuf),
}

impl Unit {
    fn path(&self) -> &Path {
        match self {
            Unit::Record { path, .. }
            | Unit::IntentFile(path)
            | Unit::ProgressReport(path)
            | Unit::SessionRows(path) => path,
        }
    }

    fn item(&self) -> Option<&str> {
        match self {
            Unit::Record { item, .. } => Some(item),
            Unit::IntentFile(_) | Unit::ProgressReport(_) | Unit::SessionRows(_) => None,
        }
    }
}

/// What one pass judged, before anything but the log's rotated segments
/// has gone.
#[derive(Debug)]
struct Plan {
    segments: Vec<PathBuf>,
    units: Vec<Unit>,
    /// Every item whose record is a unit or whose lane ended, with its lane
    /// rows as the judgement read them, and whether its rows past the first
    /// leave.
    rows: Vec<PlannedRows>,
    /// The records of those items whose file or lock stands: the locks the
    /// commit takes.
    records: Vec<PathBuf>,
    fleet: Option<Document>,
    cutoff: u64,
}

/// The places a pass reads beside the state directory, and the tmux server
/// a session rows file's pane is judged on.
struct Places {
    progress: PathBuf,
    overseer: PathBuf,
    server: Option<PathBuf>,
}

/// The judgement: the records at `fleet`, the directory beside it and the
/// [`Places`], at `now`. The fleet is read once, before every selection
/// read, and a record's stamp is taken before the read that selects it.
fn plan(
    fleet: &Path,
    paths: &Paths,
    project: &Path,
    places: &Places,
    days: u32,
    now: u64,
) -> Result<Plan> {
    let cutoff = cutoff(now, days);
    let segments = prune_segments(&paths.log, cutoff)?;
    let doc = load(fleet)?;
    let empty = Document::new();
    let record = doc.as_ref().unwrap_or(&empty);
    let intents = array(record, "intents");
    let fleet_log = array(record, "fleet_log");
    let lanes = array(record, "lanes");
    let mut kept: BTreeSet<&str> = BTreeSet::new();
    let mut ended: BTreeSet<&str> = BTreeSet::new();
    for lane in lanes {
        let Some(item) = field(lane, "item") else {
            continue;
        };
        match judge(lane, intents, fleet_log, project, cutoff) {
            Judgement::Prune { .. } => ended.insert(item),
            Judgement::Keep => kept.insert(item),
        };
    }
    let judged: BTreeSet<&str> = kept.union(&ended).copied().collect();
    // Every record of the item must be past its end: a relaunch's live
    // record keeps the item record an earlier one shares.
    let ended: BTreeSet<&str> = ended.difference(&kept).copied().collect();
    let mut units = Vec::new();
    for item in &ended {
        let path = state::item_path(&paths.dir, item);
        if let Some(seen) = stamp(&path)? {
            units.push(Unit::Record {
                path,
                item: (*item).to_owned(),
                seen,
            });
        }
    }
    units.extend(laneless_records(paths, project, &judged, cutoff)?);
    units.extend(intent_files(&paths.dir, intents, cutoff)?);
    units.extend(progress_reports(&places.progress, cutoff)?);
    units.extend(
        dead_session_rows(&places.overseer, places.server.as_deref(), record)?
            .into_iter()
            .map(Unit::SessionRows),
    );
    let named: BTreeSet<String> = units
        .iter()
        .filter_map(Unit::item)
        .chain(ended.iter().copied())
        .map(str::to_owned)
        .collect();
    let rows: Vec<PlannedRows> = named
        .iter()
        .map(|item| {
            let rows: Vec<Value> = lanes
                .iter()
                .filter(|lane| field(lane, "item") == Some(item.as_str()))
                .cloned()
                .collect();
            let first = lanes.first().and_then(|lane| field(lane, "item")) == Some(item.as_str());
            let drop = ended.contains(item.as_str()) && rows.len() > usize::from(first);
            PlannedRows {
                item: item.clone(),
                rows,
                drop,
            }
        })
        .collect();
    let mut records = Vec::new();
    for item in &named {
        let record = state::item_path(&paths.dir, item);
        let lock = agent_runtime::record::lock_path(&record);
        if stamp(&record)?.is_some() || stamp(&lock)?.is_some() {
            records.push(record);
        }
    }
    Ok(Plan {
        segments,
        units,
        rows,
        records,
        fleet: doc,
        cutoff,
    })
}

/// The archive of `paths` and of the rows `rows` drops from the fleet
/// version `plan` read, written under `root` before anything goes; `None`
/// where nothing leaves.
fn archive(
    plan: &Plan,
    fleet: &Path,
    rows: &[PlannedRows],
    paths: &[PathBuf],
    settings: &Settings,
    dir: &Path,
    now: u64,
) -> Result<Option<PathBuf>> {
    let dropped = match &plan.fleet {
        Some(doc) => crate::ops::prune::dropped(
            fleet,
            doc,
            &PruneRecords {
                lanes: rows.to_vec(),
                cutoff: plan.cutoff,
            },
        )?,
        None => Dropped::default(),
    };
    if paths.is_empty() && dropped.is_empty() {
        return Ok(None);
    }
    crate::archive::write(
        &settings.archive_root,
        &settings.roots.project,
        dir,
        &format!("prune-{now}"),
        Some(&dropped.records()),
        paths,
    )
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Pruned {
    pub segments: Vec<PathBuf>,
    pub paths: Vec<PathBuf>,
    /// The items whose lane rows left (the duty), or would leave (a pass
    /// with no transition).
    pub records: Vec<String>,
    /// The rows the commit judged against, for the items it went on with.
    pub rows: Vec<PlannedRows>,
    pub archive: Option<PathBuf>,
    /// Each item record whose lock could not be taken, as
    /// `record=<path> <cause>`: its item stays for the next pass.
    pub unlocked: Vec<String>,
}

/// What the fleet transition confirmed: the items whose rows still equal
/// the plan's, and the items whose rows left.
struct Confirmed {
    items: BTreeSet<String>,
    dropped: Vec<String>,
}

/// Abandon every item whose record moved since the judgement read it.
fn revalidate(plan: &Plan, abandoned: &mut BTreeSet<String>) -> Result<()> {
    for unit in &plan.units {
        if let Unit::Record { path, item, seen } = unit
            && stamp(path)? != Some(*seen)
        {
            abandoned.insert(item.clone());
        }
    }
    Ok(())
}

/// The units that still go: none of their items abandoned.
fn going(plan: &Plan, abandoned: &BTreeSet<String>) -> Vec<PathBuf> {
    plan.units
        .iter()
        .filter(|unit| unit.item().is_none_or(|item| !abandoned.contains(item)))
        .map(|unit| unit.path().to_path_buf())
        .collect()
}

/// The judgement under `settings` at `now`, then its commit under the lock
/// of each item record it removes: a record that moved since the judgement
/// abandons its item, the archive is written, `commit` drops the rows of
/// the items left while they equal the plan's and names those confirmed,
/// and only their records and the units naming no item go.
fn judged_pass(
    fleet: &Path,
    paths: &Paths,
    settings: &Settings,
    locking: Locking,
    now: u64,
    commit: impl FnOnce(&[PlannedRows], u64) -> Result<Confirmed>,
) -> Result<Pruned> {
    let reach = crate::effects::fleet_reach(settings)?;
    let plan = plan(
        fleet,
        paths,
        &settings.roots.project,
        &Places {
            progress: settings.store.progress_report_dir.clone(),
            overseer: crate::watch::mail::overseer_dir(&reach.mail_root),
            server: reach.socket,
        },
        settings.retention_days.get()?,
        now,
    )?;
    crate::archive::records_locked(&plan.records, locking, |unlocked| {
        let mut abandoned: BTreeSet<String> = unlocked
            .iter()
            .filter_map(|(record, _)| state::item_of(record).map(str::to_owned))
            .collect();
        let causes: Vec<String> = unlocked
            .iter()
            .map(|(record, cause)| format!("record={} {cause}", record.display()))
            .collect();
        revalidate(&plan, &mut abandoned)?;
        let live_rows = |abandoned: &BTreeSet<String>| -> Vec<PlannedRows> {
            plan.rows
                .iter()
                .filter(|r| !abandoned.contains(&r.item))
                .cloned()
                .collect()
        };
        let rows = live_rows(&abandoned);
        let archive = archive(
            &plan,
            fleet,
            &rows,
            &going(&plan, &abandoned),
            settings,
            &paths.dir,
            now,
        )?;
        let confirmed = commit(&rows, plan.cutoff)?;
        abandoned.extend(
            rows.iter()
                .filter(|r| !confirmed.items.contains(&r.item))
                .map(|r| r.item.clone()),
        );
        let removal = going(&plan, &abandoned);
        crate::archive::remove(&removal)?;
        Ok(Pruned {
            segments: plan.segments.clone(),
            paths: removal,
            records: confirmed.dropped,
            rows: live_rows(&abandoned),
            archive,
            unlocked: causes,
        })
    })
}

/// One pass with no record transition: the judgement, the archive, then the
/// units go. The duty applies the transition between the archive and the
/// removal; a checkout with no fleet state has no transition to apply, and
/// every planned item stands confirmed.
pub fn pass(
    fleet: &Path,
    paths: &Paths,
    settings: &Settings,
    locking: Locking,
    now: u64,
) -> Result<Pruned> {
    judged_pass(fleet, paths, settings, locking, now, |rows, _| {
        Ok(Confirmed {
            items: rows.iter().map(|r| r.item.clone()).collect(),
            dropped: rows
                .iter()
                .filter(|r| r.drop)
                .map(|r| r.item.clone())
                .collect(),
        })
    })
}

/// The judgement, the archive, then the judged records and the fleet-log
/// rows past the cutoff leave the fleet state through the one dispatcher,
/// each item's rows only while they equal the judgement's, then the units
/// of the confirmed items and those naming no item go: a removal that
/// fails leaves the archive holding everything the pass selected and the
/// record already moved. The store writes nothing when nothing leaves.
#[allow(
    clippy::disallowed_methods,
    reason = "the retention duty's one fleet write per pass, `prune-records` through `ops::apply`, from the judgement its pass made on the disk"
)]
fn prune(ctx: &Context, tick: &Tick) -> Result<Pruned> {
    judged_pass(
        &ctx.fleet,
        &ctx.paths,
        &ctx.settings,
        ctx.locking,
        tick.wall,
        |rows, cutoff| {
            let request = Request::PruneRecords(PruneRecords {
                lanes: rows.to_vec(),
                cutoff,
            });
            let env = Env {
                now_secs: tick.wall,
                now_nanos: u128::from(tick.wall) * 1_000_000_000,
                nonce: 0,
                owner: None,
            };
            let applied = crate::ops::apply(&ctx.fleet, &request, &env, ctx.locking)?;
            match applied.report {
                Report::PruneRecords(pruned) => Ok(Confirmed {
                    items: pruned.confirmed.into_iter().collect(),
                    dropped: pruned.lanes,
                }),
                other => Err(agent_runtime::Error::refused(
                    "report-unexpected",
                    &[("op", "prune-records"), ("report", &format!("{other:?}"))],
                )
                .into()),
            }
        },
    )
}

/// The overseer mailbox's compaction, rooted at the main checkout where
/// the mailbox lives whatever the state directory: the refusal where the
/// mailbox refused.
fn compact(settings: &Settings) -> Option<String> {
    let reach = match crate::effects::fleet_reach(settings) {
        Ok(reach) => reach,
        Err(e) => return Some(format!("lane-mail compact item=overseer {e}")),
    };
    Mailbox::new(reach.mail_program)
        .compact(&reach.mail_root)
        .err()
        .map(|refusal| format!("lane-mail compact item=overseer {refusal}"))
}

/// One pass of the duty: the overseer mailbox's compaction, then the prune.
/// A prune that fails fails the pass; a refused compaction and each record
/// left for want of its lock are the causes of a pass that otherwise ran.
fn run(ctx: &Context, tick: &Tick) -> Result<Produced> {
    let refused = compact(&ctx.settings);
    let pruned = prune(ctx, tick)?;
    let causes: Vec<String> = refused.into_iter().chain(pruned.unlocked).collect();
    Ok(Produced {
        failed: (!causes.is_empty()).then(|| causes.join("\n")),
        ..Produced::default()
    })
}

#[cfg(test)]
#[allow(
    clippy::disallowed_methods,
    reason = "the rows plant the fleet and the files, and commit the fleet transition through the one dispatcher"
)]
mod tests {
    use std::time::{Duration, Instant, UNIX_EPOCH};

    use serde_json::json;

    use super::*;

    const NOW: u64 = 1_769_700_000;

    fn aged(path: &Path) {
        std::fs::File::open(path)
            .unwrap()
            .set_modified(UNIX_EPOCH + Duration::from_secs(NOW - 10 * SECS_PER_DAY))
            .unwrap();
    }

    fn plant(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
        aged(path);
    }

    fn settings(root: &Path) -> Settings {
        settings_with(root, &[])
    }

    fn settings_with(root: &Path, extra: &[(&str, &str)]) -> Settings {
        let environment: Vec<(std::ffi::OsString, std::ffi::OsString)> = extra
            .iter()
            .map(|(k, v)| ((*k).into(), (*v).into()))
            .collect();
        crate::settings::load(
            &agent_runtime::settings::Roots {
                project: root.to_path_buf(),
                common: root.to_path_buf(),
            },
            &environment,
            &crate::settings::Flags {
                state_dir: Some(root.to_path_buf()),
                private_env: false,
            },
        )
        .unwrap()
    }

    fn env() -> Env {
        Env {
            now_secs: NOW,
            now_nanos: u128::from(NOW) * 1_000_000_000,
            nonce: 0,
            owner: None,
        }
    }

    /// The duty's own commit: `prune-records` through the one dispatcher.
    fn prune_records(fleet: &Path, rows: &[PlannedRows], cutoff: u64) -> Result<Confirmed> {
        let applied = crate::ops::apply(
            fleet,
            &Request::PruneRecords(PruneRecords {
                lanes: rows.to_vec(),
                cutoff,
            }),
            &env(),
            Locking::FLOCK,
        )?;
        let Report::PruneRecords(report) = applied.report else {
            unreachable!("prune-records reports itself")
        };
        Ok(Confirmed {
            items: report.confirmed.into_iter().collect(),
            dropped: report.lanes,
        })
    }

    #[test]
    fn a_directive_receipt_and_a_wall_relaunch_log_written_after_the_fleet_commit_stand() {
        let world = tempfile::tempdir().unwrap();
        let root = world.path().canonicalize().unwrap();
        let fleet = root.join(record::FLEET_FILE_NAME);
        let old = clock::iso_utc(NOW - 10 * SECS_PER_DAY);
        std::fs::write(
            &fleet,
            serde_json::to_vec(&json!({
                "issue_id": "oversee", "launch_queue": [], "fleet_log": [], "intents": [],
                "lanes": [{"item": "KEN-0", "status": "running", "launched_at": old},
                          {"item": "KEN-9", "status": "done", "launched_at": old}]
            }))
            .unwrap(),
        )
        .unwrap();
        let record = state::item_path(&root, "KEN-9");
        plant(&record, "{}\n");
        let kept = crate::send::receipt_path(&root, "KEN-2", "r0");
        plant(&kept, "{}\n");
        aged(kept.parent().unwrap());
        let log = root.join("wall-relaunch-KEN-9.log");
        plant(&log, "relaunched\n");
        let late = crate::send::receipt_path(&root, "KEN-2", "r1");
        let pruned = judged_pass(
            &fleet,
            &Paths::of(&fleet).unwrap(),
            &settings(&root),
            Locking::FLOCK,
            NOW,
            |rows, cutoff| {
                let confirmed = prune_records(&fleet, rows, cutoff)?;
                std::fs::write(&late, "{}\n").unwrap();
                std::fs::write(&log, "relaunched\nagain\n").unwrap();
                Ok(confirmed)
            },
        )
        .unwrap();
        assert_eq!(pruned.paths, vec![record.clone()]);
        assert!(!record.exists());
        for path in [&kept, &late, &log] {
            assert!(path.exists(), "{} stands", path.display());
        }
        // A retention of none fails the pass by key and value before it
        // plans or removes anything.
        plant(&record, "{}\n");
        let failed = pass(
            &fleet,
            &Paths::of(&fleet).unwrap(),
            &settings_with(&root, &[("ORCH_RECORD_RETENTION_DAYS", "0")]),
            Locking::FLOCK,
            NOW,
        )
        .map(|p| p.paths)
        .unwrap_err();
        assert_eq!(failed.key(), "setting-invalid", "{failed}");
        assert!(record.exists(), "nothing removed");
    }

    #[test]
    fn a_closed_intents_notice_written_after_the_fleet_commit_reaches_its_owner() {
        let world = tempfile::tempdir().unwrap();
        let root = world.path().canonicalize().unwrap();
        let fleet = root.join(record::FLEET_FILE_NAME);
        let old = clock::iso_utc(NOW - 10 * SECS_PER_DAY);
        let id = "request-transfer:overseer:3:1-1";
        std::fs::write(
            &fleet,
            serde_json::to_vec(&json!({
                "issue_id": "oversee", "lanes": [], "launch_queue": [], "fleet_log": [],
                "intents": [{
                    "id": id, "op": "request-transfer", "target": "overseer:3",
                    "created_at": old, "completed_at": old, "outcome": "failed",
                    "notice": {"key": "job-launch-failed", "text": "the owner reads this", "owner": "owed"}
                }]
            }))
            .unwrap(),
        )
        .unwrap();
        plant(
            &root.join("intents").join(format!("{id}.notice")),
            "an earlier, interrupted delivery\n",
        );
        let ready = root.join("mail-ready");
        let release = root.join("mail-release");
        let received = root.join("mail-received");
        let mail = root.join("lane-mail");
        crate::write_executable(
            &mail,
            format!(
                "#!/bin/sh\nwhile [ \"$1\" != --file ]; do shift; done\n: > '{}'\nn=0\nwhile [ ! -e '{}' ]; do n=$((n + 1)); [ \"$n\" -lt 3000 ] || exit 98; sleep 0.01; done\ncat -- \"$2\" > '{}'\n",
                ready.display(),
                release.display(),
                received.display()
            ),
        );
        let mut settings = settings(&root);
        settings.lane_mail_cli = mail;
        std::thread::scope(|scope| {
            let mut sender = None;
            judged_pass(
                &fleet,
                &Paths::of(&fleet).unwrap(),
                &settings,
                Locking::FLOCK,
                NOW,
                |rows, cutoff| {
                    let confirmed = prune_records(&fleet, rows, cutoff)?;
                    sender = Some(scope.spawn(|| {
                        crate::effects::reconcile(
                            &fleet,
                            &settings,
                            &env(),
                            Locking::FLOCK,
                            &agent_runtime::clock::SystemClock,
                        )
                    }));
                    let deadline = Instant::now() + Duration::from_secs(30);
                    while !ready.exists() {
                        assert!(Instant::now() < deadline, "the mailbox was asked");
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Ok(confirmed)
                },
            )
            .unwrap();
            std::fs::write(&release, "").unwrap();
            sender.expect("the reconcile ran").join().unwrap().unwrap();
        });
        let doc = state::load(&fleet).unwrap().unwrap().doc;
        assert_eq!(doc["intents"][0]["notice"]["owner"], json!("sent"));
        assert_eq!(
            std::fs::read_to_string(&received).unwrap(),
            "the owner reads this\n"
        );
    }

    #[test]
    fn a_progress_report_is_known_by_its_stamped_name() {
        for (name, want) in [
            ("01-01-00-00.md", true),
            ("12-31-23-59-succession.md", true),
            ("notes.md", false),
            ("1-01-00-00.md", false),
            ("01-01-00-00.txt", false),
            ("01-01-00-00-x.md", false),
        ] {
            assert_eq!(is_progress_report(name), want, "{name}");
        }
    }
}
