//! `record-push`: an item's push through the worktree skill's `push`, run by
//! the one runner in its own process group, with the commits the item
//! records reconciled from the worktree's `kendex-rebase-map` in one
//! transition per read of the map: the hops a restack left before the push,
//! then the hop the push itself wrote. The modes are the branch push, the
//! review checkpoint, the push-base delivery's preparation and publication,
//! the live-round question alone, and the post-push record of a restack run.
//!
//! The push's answer is read three-valued: a push that never started pushed
//! nothing; one that answered has its status; one whose answer was lost
//! (its bound passed, a signal ended it) may have landed, so its
//! `push_attempt`, written before the start, stays `attempted` and the next
//! call settles it from the remote before it pushes again.
use agent_runtime::record::{self, Document, Locking};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host::{self, Place};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::admission::ScopeRange;
use super::proof::{self, Hop};
use super::{findings, loaded, tier};
use crate::error::{Error, Result};
use crate::settings::{self, Settings};
use crate::state;
use crate::validate::files::RunFile;
use agent_runtime::journal::Env;

/// The bound on the push and on the publication's validation: a pre-push
/// hook may run the project's whole battery.
pub const BOUND: Duration = Duration::from_secs(2 * 60 * 60);
/// The bound on one git read.
const READ: Duration = Duration::from_secs(120);
const TAG: &str = "push";
/// The exit of a live round in check mode.
pub const LIVE_EXIT: i32 = 3;
/// The exit of a push whose answer was lost.
pub const UNKNOWN_EXIT: i32 = 75;
const MAP: &str = "kendex-rebase-map";
const PENDING: &str = "kendex-restack-validation";
const FOLD_MESSAGE: &str = "kendex-fold-message";
const RESTACK: &str = "restack-reconcile";
const PUSHED: &str = "sha-reconcile";

/// One mode of the push, tagged by `mode`. `args` are the worktree skill's
/// own push flags, forwarded verbatim and in order: its `push --help` is
/// their one vocabulary.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "kebab-case", deny_unknown_fields)]
pub enum RecordPush {
    Branch {
        worktree: PathBuf,
        #[serde(default)]
        args: Vec<String>,
    },
    Checkpoint {
        worktree: PathBuf,
        #[serde(default)]
        args: Vec<String>,
    },
    Prepare {
        worktree: PathBuf,
    },
    Publish {
        worktree: PathBuf,
        base: String,
        head: String,
    },
    CheckLiveRound {
        worktree: PathBuf,
    },
    RecordRestackValidation {
        worktree: PathBuf,
        run_dir: PathBuf,
    },
}

impl RecordPush {
    fn worktree(&self) -> &Path {
        match self {
            RecordPush::Branch { worktree, .. }
            | RecordPush::Checkpoint { worktree, .. }
            | RecordPush::Prepare { worktree }
            | RecordPush::Publish { worktree, .. }
            | RecordPush::CheckLiveRound { worktree }
            | RecordPush::RecordRestackValidation { worktree, .. } => worktree,
        }
    }

    fn word(&self) -> &'static str {
        match self {
            RecordPush::Branch { .. } => "branch",
            RecordPush::Checkpoint { .. } => "checkpoint",
            RecordPush::Prepare { .. } => "prepare",
            RecordPush::Publish { .. } => "publish",
            RecordPush::CheckLiveRound { .. } => "check-live-round",
            RecordPush::RecordRestackValidation { .. } => "record-restack-validation",
        }
    }
}

/// One hop's reconciliation: the key it reports under, the mappings it
/// carried and the recorded commits it moved.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Reconciled {
    pub key: &'static str,
    pub map_entries: usize,
    pub fixed_items: usize,
    pub pr_fixes: usize,
}

/// How the push answered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PushStatus {
    Confirmed,
    Failed,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PushRun {
    pub status: PushStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// The publication's receipts, as the worktree skill printed them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Receipt {
    pub base: String,
    pub before: String,
    pub commit: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<String>,
}

/// The reply: what each step did, and the exit the command answers with.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Pushed {
    pub mode: &'static str,
    pub exit: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub live_round: Option<String>,
    /// A push an earlier call left `attempted`, settled from the remote.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous: Option<String>,
    pub reconciled: Vec<Reconciled>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub push: Option<PushRun>,
    /// The restack run's stage: the run directory recorded, or
    /// `unrecorded` with its cause; the push's verdict stands either way.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stage: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prepared: Option<Receipt>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub validation: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivery: Option<Receipt>,
}

fn refuse(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// A refusal after the push ran: the same key and fields, and the push's
/// own answer beside them.
fn after_push(error: Error, push: &PushRun) -> Error {
    let exit = push
        .exit
        .map_or_else(|| "unknown".to_owned(), |c| c.to_string());
    let mut fields: Vec<(String, String)> = error.fields();
    fields.push(("push-exit".into(), exit));
    let borrowed: Vec<(&str, &str)> = fields
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();
    refuse(error.key(), &borrowed)
}

/// An item key a state file path can carry.
fn valid_item(item: &str) -> bool {
    let mut bytes = item.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphanumeric())
        && bytes.all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        && !item.contains("..")
}

/// `git -C dir args` through the one runner: its stdout, or `Err` with the
/// first line of its stderr where it did not succeed.
#[allow(
    clippy::disallowed_methods,
    reason = "the push's reads of the worktree's repository through the one runner: they act on nothing"
)]
fn git(dir: &Path, operation: &'static str, args: &[&str]) -> std::result::Result<String, String> {
    let dir = dir.display().to_string();
    let mut argv = vec!["-C", dir.as_str()];
    argv.extend_from_slice(args);
    let out = host::run_tagged_in(
        TAG,
        "git",
        Path::new("git"),
        operation,
        &argv,
        Place::default(),
        READ,
    )
    .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(host::stderr_text(&out)
            .lines()
            .next()
            .unwrap_or("")
            .to_owned());
    }
    Ok(host::stdout_text(&out))
}

fn head(worktree: &Path) -> Result<String> {
    git(worktree, "rev-parse", &["rev-parse", "HEAD"]).map_err(|cause| {
        refuse(
            "not-worktree",
            &[("path", &worktree.display().to_string()), ("cause", &cause)],
        )
    })
}

/// The worktree the request names, resolved: a directory git reads as a
/// checkout.
fn resolve(worktree: &Path) -> Result<PathBuf> {
    let resolved = fs::canonicalize(worktree)
        .ok()
        .filter(|p| fs::metadata(p).is_ok_and(|m| m.is_dir()))
        .ok_or_else(|| {
            refuse(
                "not-directory",
                &[("path", &worktree.display().to_string())],
            )
        })?;
    git(
        &resolved,
        "absolute-git-dir",
        &["rev-parse", "--absolute-git-dir"],
    )
    .map_err(|cause| {
        refuse(
            "not-worktree",
            &[("path", &resolved.display().to_string()), ("cause", &cause)],
        )
    })?;
    Ok(resolved)
}

/// A record resolved for other arguments would have another item's commits
/// rewritten, so the record must name this item and this worktree before
/// anything runs; an empty recorded worktree is taken as it stands.
fn bind(doc: &Document, item: &str, worktree: &Path) -> Result<()> {
    let recorded = doc.get("issue_id").and_then(Value::as_str).unwrap_or("");
    if recorded != item {
        return Err(refuse(
            "issue-mismatch",
            &[("issue", item), ("recorded", recorded)],
        ));
    }
    let tree = doc.get("worktree").and_then(Value::as_str).unwrap_or("");
    if !tree.is_empty() {
        let resolved = fs::canonicalize(tree)
            .map_err(|_| refuse("state-worktree", &[("issue", item), ("path", tree)]))?;
        if resolved != worktree {
            return Err(refuse(
                "worktree-mismatch",
                &[
                    ("issue", item),
                    ("recorded", &resolved.display().to_string()),
                    ("worktree", &worktree.display().to_string()),
                ],
            ));
        }
    }
    Ok(())
}

/// Whether `path` stands, read three-valued: an unreadable path is no
/// answer.
fn stands(path: &Path) -> Result<bool> {
    match fs::metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(false),
        Err(e) => Err(refuse(
            "round-read",
            &[
                ("path", &path.display().to_string()),
                ("cause", &e.to_string()),
            ],
        )),
    }
}

/// The active fix round in flight: the record's `dev_round_id` whose round
/// record stands in the worktree with no receipt of the round beside it,
/// bare or keyed by its run. A rebase would move every commit out from
/// under it.
fn live_round(doc: &Document, item: &str, worktree: &Path) -> Result<Option<String>> {
    let round = doc
        .get("dev_round_id")
        .and_then(Value::as_str)
        .unwrap_or("");
    if round.is_empty() {
        return Ok(None);
    }
    let tmp = worktree.join("tmp");
    if !stands(&tmp.join(format!("dev-round-{item}-{round}.json")))? {
        return Ok(None);
    }
    if stands(&tmp.join(format!("dev-return-{item}-{round}.json")))? {
        return Ok(None);
    }
    let keyed = format!("dev-return-{item}-{round}-");
    let receipt = fs::read_dir(&tmp)
        .map_err(|e| refuse("round-read", &[("cause", &e.to_string())]))?
        .filter_map(std::result::Result::ok)
        .any(|entry| {
            entry
                .file_name()
                .to_str()
                .is_some_and(|n| n.starts_with(&keyed) && n.ends_with(".json"))
        });
    Ok((!receipt).then(|| round.to_owned()))
}

/// The worktree-private map every rewrite records its hops in, where the
/// worktree skill asks git for it.
fn map_file(worktree: &Path) -> Result<PathBuf> {
    let path = git(worktree, "git-path", &["rev-parse", "--git-path", MAP])
        .ok()
        .filter(|p| !p.is_empty())
        .ok_or_else(|| {
            refuse(
                "restack-map-path",
                &[("worktree", &worktree.display().to_string())],
            )
        })?;
    let path = PathBuf::from(path);
    Ok(if path.is_absolute() {
        path
    } else {
        worktree.join(path)
    })
}

/// Apply `hops` in order to the recorded commits, the item's `rebase_map`
/// and, for a restack's hops, its restack count: each hop compares a record
/// against the value the previous hop left, and a hop the map already holds
/// whole is a kept file read again, which counts no second restack.
fn apply_hops(doc: &mut Document, hops: &[Hop], key: &'static str) -> Vec<Reconciled> {
    let mut reports = Vec::new();
    for hop in hops {
        let mut seen = match doc.get("rebase_map") {
            Some(Value::Object(map)) => map.clone(),
            _ => Map::new(),
        };
        if key == RESTACK
            && hop
                .iter()
                .any(|(old, new)| seen.get(old).and_then(Value::as_str) != Some(new.as_str()))
        {
            let count = doc.get("restacks").and_then(Value::as_u64).unwrap_or(0);
            record::set(doc, "restacks", count + 1);
        }
        for (old, new) in hop {
            seen.insert(old.clone(), json!(new));
        }
        record::set(doc, "rebase_map", Value::Object(seen));
        let (fixed_items, pr_fixes) = findings::remap_commits(doc, hop);
        reports.push(Reconciled {
            key,
            map_entries: hop.len(),
            fixed_items,
            pr_fixes,
        });
    }
    reports
}

/// One read of the map: every hop parsed before any is applied, all of
/// them applied in one transition, then the file removed. A map that does
/// not parse whole, an item with no record, a write that does not land or a
/// file that will not go each refuse with the file kept, since it holds the
/// mappings that repair the stale commits. `before` runs after the write
/// and before the removal. `None` where no map stands.
#[allow(
    clippy::disallowed_methods,
    reason = "the map's one consumer: the hops committed under the item's write check, then the reconciled map file removed"
)]
fn consume(
    path: &Path,
    item: &str,
    map: &Path,
    key: &'static str,
    locking: Locking,
    before: &mut dyn FnMut(),
) -> Result<Option<Vec<Reconciled>>> {
    let file = map.display().to_string();
    let text = match fs::read_to_string(map) {
        Ok(text) => text,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(refuse(
                "rebase-map-unreadable",
                &[
                    ("cause", "map-read"),
                    ("file", &file),
                    ("error", &e.to_string()),
                ],
            ));
        }
    };
    let hops = proof::hops(&text).map_err(|e| {
        refuse(
            "rebase-map-unreadable",
            &[
                ("cause", e.cause),
                ("line", &e.line.to_string()),
                ("file", &file),
            ],
        )
    })?;
    let state_file = path.display().to_string();
    let reports = record::reread(
        || {
            let Some(snapshot) = state::load(path)? else {
                return Err(refuse(
                    "restack-map-nostate",
                    &[("issue", item), ("state", &state_file), ("file", &file)],
                ));
            };
            let mut doc = snapshot.doc.clone();
            let reports = apply_hops(&mut doc, &hops, key);
            record::store(path, &snapshot.doc, &doc, locking).map_err(|e| {
                if e.key() == "record-changed" {
                    e.into()
                } else {
                    refuse(
                        "restack-map-write",
                        &[
                            ("issue", item),
                            ("state", &state_file),
                            ("file", &file),
                            ("cause", &e.to_string()),
                        ],
                    )
                }
            })?;
            Ok(reports)
        },
        Error::key,
    )?;
    before();
    fs::remove_file(map).map_err(|e| {
        refuse(
            "restack-map-clear",
            &[("file", &file), ("cause", &e.to_string())],
        )
    })?;
    Ok(Some(reports))
}

/// A restack run chosen for its stage: its directory, its files and its record's words.
type Chosen = (PathBuf, RunFile, Map<String, Value>);

/// The `key=value` words of a run's record line.
fn words(line: &str) -> Map<String, Value> {
    line.split(' ')
        .filter_map(|w| w.split_once('='))
        .map(|(k, v)| (k.to_owned(), json!(v)))
        .collect()
}

/// The finished, timed run for `head` among `dirs`, newest by its start:
/// a run for another head is no candidate. `Err` is a run directory whose
/// record cannot be read.
fn restack_run(dirs: &[PathBuf], head: &str) -> std::result::Result<Option<Chosen>, String> {
    let mut best: Option<(i64, PathBuf, RunFile, Map<String, Value>)> = None;
    for dir in dirs {
        if !fs::metadata(dir).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        let run = RunFile::read(dir).map_err(|e| e.to_string())?;
        let line = words(&run.record().map_err(|e| e.to_string())?);
        let word = |k: &str| line.get(k).and_then(Value::as_str).unwrap_or("");
        if word("verdict") == "unfinished" || word("seconds").is_empty() || word("head") != head {
            continue;
        }
        let start: i64 = word("start").parse().map_err(|_| "start".to_owned())?;
        if best.as_ref().is_none_or(|(s, ..)| start > *s) {
            best = Some((start, dir.clone(), run, line));
        }
    }
    Ok(best.map(|(_, dir, run, line)| (dir, run, line)))
}

/// The restack run's stage and validation row, once per run directory: the
/// run's identity and times with its proof and outcome, so the proof reader
/// reads a restack range run as it reads a round's. `Ok(None)` where the
/// item has no record or no run qualifies and none was named.
#[allow(
    clippy::disallowed_methods,
    reason = "the restack stage committed under the item's write check"
)]
fn record_stage(
    path: &Path,
    dirs: &[PathBuf],
    named: bool,
    head: &str,
    locking: Locking,
) -> std::result::Result<Option<String>, String> {
    if state::load(path).map_err(|e| e.to_string())?.is_none() {
        return Ok(None);
    }
    let Some((dir, run, line)) = restack_run(dirs, head)? else {
        return if named {
            Err("no-run".into())
        } else {
            Ok(None)
        };
    };
    let word = |k: &str| line.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    let epoch =
        |k: &str| agent_runtime::clock::epoch_secs(&word(k)).ok_or_else(|| format!("timing {k}"));
    let run_dir = dir.display().to_string();
    let id = dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .trim_start_matches("dev-validate-")
        .to_owned();
    let seconds: u64 = word("seconds").parse().map_err(|_| "seconds".to_owned())?;
    let proof = run.proof().map_err(|e| e.to_string())?;
    let stage = json!({
        "kind": "validate",
        "reason": "restack",
        "round_id": Value::Null,
        "run_dir": run_dir,
        "start": epoch("started-at")?,
        "end": epoch("ended-at")?,
        "outcome": run.outcome(),
        "proof": proof,
    });
    let mut row = json!({
        "round_id": format!("restack-{id}"),
        "kind": "restack",
        "mode": word("validate-mode"),
        "seconds": seconds,
    });
    if line.contains_key("lanes") {
        row["lanes"] = json!(word("lanes"));
    }
    if line.contains_key("selection") {
        row["selection"] = json!(word("selection"));
    }
    record::reread(
        || {
            let snapshot = loaded(path)?;
            let mut doc = snapshot.doc.clone();
            let stages = record::array_mut(path, &mut doc, "stages")?;
            if stages
                .iter()
                .any(|s| s.get("run_dir").and_then(Value::as_str) == Some(run_dir.as_str()))
            {
                return Ok(());
            }
            stages.push(stage.clone());
            record::array_mut(path, &mut doc, "validate_rounds")?.push(row.clone());
            Ok(record::store(path, &snapshot.doc, &doc, locking)?)
        },
        Error::key,
    )
    .map_err(|e| e.to_string())?;
    Ok(Some(run_dir))
}

/// The run directories a restack's stage chooses among: every run under the
/// worktree's `tmp/`.
fn run_dirs(worktree: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(worktree.join("tmp")) else {
        return Vec::new();
    };
    let mut dirs: Vec<PathBuf> = entries
        .filter_map(std::result::Result::ok)
        .filter(|e| {
            e.file_name()
                .to_str()
                .is_some_and(|n| n.starts_with("dev-validate-"))
        })
        .map(|e| e.path())
        .collect();
    dirs.sort();
    dirs
}

/// The pre-push restack run's identity, kept in the worktree's git dir
/// beside the map, so a transport that fails after the map's removal leaves
/// the run a successful retry of the same head records.
#[allow(
    clippy::disallowed_methods,
    reason = "the push's private timing record beside the map, written whole and renamed into place"
)]
fn save_pending(pending: &Path, item: &str, head: &str, run_dir: &str) -> std::io::Result<()> {
    let tmp = pending.with_extension(format!("{}", std::process::id()));
    fs::write(
        &tmp,
        json!({"issue": item, "head": head, "run_dir": run_dir}).to_string() + "\n",
    )?;
    fs::rename(&tmp, pending)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the push's private timing record removed once its stage is written"
)]
fn clear_pending(pending: &Path) -> std::io::Result<()> {
    match fs::remove_file(pending) {
        Err(e) if e.kind() != ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// The pending identity where it names this item and this head.
fn pending_run(pending: &Path, item: &str, head: &str) -> Option<PathBuf> {
    let value: Value = serde_json::from_str(&fs::read_to_string(pending).ok()?).ok()?;
    (value["issue"] == item && value["head"] == head)
        .then(|| value["run_dir"].as_str().map(PathBuf::from))
        .flatten()
}

/// `worktree push` in the worktree through the one runner, in its own
/// process group so the bound ends whatever it started. A push that never
/// started pushed nothing and refuses.
#[allow(
    clippy::disallowed_methods,
    reason = "the item's one push through the worktree skill, in its own group, its attempt written first"
)]
fn push_once(cli: &Path, worktree: &Path, args: &[String]) -> Result<PushRun> {
    let wt = worktree.display().to_string();
    let mut argv = vec!["push", wt.as_str()];
    argv.extend(args.iter().map(String::as_str));
    let place = Place {
        cwd: Some(worktree),
        env: &[],
    };
    match host::run_tagged_in_own_group(TAG, "worktree", cli, "push", &argv, place, BOUND) {
        Ok(out) => Ok(PushRun {
            status: match out.status.code() {
                Some(0) => PushStatus::Confirmed,
                Some(_) => PushStatus::Failed,
                None => PushStatus::Unknown,
            },
            exit: out.status.code(),
            stdout: host::stdout_text(&out),
            stderr: host::stderr_text(&out),
        }),
        Err(agent_runtime::Error::NotStarted { .. }) => Err(refuse(
            "push-not-started",
            &[("path", &cli.display().to_string())],
        )),
        Err(e) => Ok(PushRun {
            status: PushStatus::Unknown,
            exit: None,
            stdout: String::new(),
            stderr: e.to_string(),
        }),
    }
}

/// The message the preparation folds the item's commits under, where it
/// folds more than one: the item's own header, then every folded commit's
/// subject, oldest first; one commit keeps its own message and takes none.
/// The folded commits are the ones no branch of origin holds but the item's
/// own: its base is on origin's base branch, a checkpoint on its own branch.
/// The item's own header is the first folded one whose scope names the item
/// by the lane-own rule: the implementation round commits the item's change
/// under it and each later round refines it, while a bundled child's header
/// names one part. With no such header the item's change has no name here,
/// and the preparation refuses before it folds.
fn fold_message(worktree: &Path, item: &str) -> Result<Option<String>> {
    let unread = |cause: String| refuse("delivery-message", &[("item", item), ("cause", &cause)]);
    let branch = git(worktree, "branch", &["branch", "--show-current"]).map_err(unread)?;
    let own = format!("--exclude=origin/{branch}");
    let log = git(
        worktree,
        "log",
        &[
            "log",
            "--reverse",
            "--format=%H %s",
            "HEAD",
            "--not",
            &own,
            "--remotes=origin",
            "--",
        ],
    )
    .map_err(unread)?;
    let subjects: Vec<&str> = log
        .lines()
        .map(|line| line.split_once(' ').map_or("", |(_, subject)| subject))
        .collect();
    if subjects.len() < 2 {
        return Ok(None);
    }
    let key = item.to_ascii_lowercase();
    let header = subjects
        .iter()
        .find(|subject| crate::watch::github::scope_names(&subject.to_ascii_lowercase(), &key))
        .ok_or_else(|| {
            refuse(
                "delivery-message",
                &[
                    ("item", item),
                    ("cause", "no-item-header"),
                    ("commits", &subjects.len().to_string()),
                ],
            )
        })?;
    let mut message = format!("{header}\n\n");
    for subject in &subjects {
        message.push_str("- ");
        message.push_str(subject);
        message.push('\n');
    }
    Ok(Some(message))
}

/// The preparation's one push, its fold given the item's message in `file`
/// where `fold_message` composes one.
#[allow(
    clippy::disallowed_methods,
    reason = "the fold's private message file beside the map, written whole before the fold and removed after it"
)]
fn prepare_once(cli: &Path, worktree: &Path, item: &str, file: &Path) -> Result<PushRun> {
    let mut args = vec!["--prepare-base".to_owned()];
    if let Some(message) = fold_message(worktree, item)? {
        fs::write(file, message).map_err(|e| {
            refuse(
                "delivery-message",
                &[
                    ("item", item),
                    ("path", &file.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            )
        })?;
        args.extend(["--message-file".to_owned(), file.display().to_string()]);
    }
    let push = push_once(cli, worktree, &args);
    // Every fold that reads the file has it written whole first, so one left
    // behind is never read.
    let _ = fs::remove_file(file);
    push
}

/// Write the item's `push_attempt` in one transition, or remove it where
/// `value` is `None`. An item with no record has nothing to hold it.
#[allow(
    clippy::disallowed_methods,
    reason = "the push's attempt record committed under the item's write check, before the push and after its answer"
)]
fn mark_attempt(path: &Path, value: Option<Value>, locking: Locking) -> Result<()> {
    if state::load(path)?.is_none() {
        return Ok(());
    }
    record::reread(
        || {
            let snapshot = loaded(path)?;
            let mut doc = snapshot.doc.clone();
            match &value {
                Some(v) => record::set(&mut doc, "push_attempt", v.clone()),
                None => {
                    record::delete(&mut doc, "push_attempt");
                }
            }
            Ok(record::store(path, &snapshot.doc, &doc, locking)?)
        },
        Error::key,
    )
}

/// A push an earlier call left `attempted` is settled before a second one:
/// it landed where the remote holds the commit it would have published.
#[allow(
    clippy::disallowed_methods,
    reason = "the settle's read of the item's attempt record before its transition"
)]
fn settle(
    path: &Path,
    worktree: &Path,
    published: &str,
    locking: Locking,
) -> Result<Option<String>> {
    let Some(snapshot) = state::load(path)? else {
        return Ok(None);
    };
    let Some(attempt) = snapshot.doc.get("push_attempt") else {
        return Ok(None);
    };
    if attempt["state"] != "attempted" {
        return Ok(None);
    }
    let remote = git(
        worktree,
        "ls-remote",
        &["ls-remote", "origin", "refs/heads/*"],
    )
    .map_err(|cause| refuse("push-attempt-unsettled", &[("cause", &cause)]))?;
    let landed = remote
        .lines()
        .any(|l| l.split('\t').next() == Some(published));
    let word = if landed { "confirmed" } else { "not-landed" };
    let mut settled = attempt.clone();
    settled["state"] = json!(word);
    settled["settled_from"] = json!("remote");
    mark_attempt(path, Some(settled), locking)?;
    Ok(Some(word.to_owned()))
}

/// The `prefix` receipt line of `stdout`, as `base= before= commit= [at=]`.
fn receipt(stdout: &str, prefix: &str) -> Option<Receipt> {
    let line = stdout.lines().find_map(|l| l.strip_prefix(prefix))?;
    let fields = words(line);
    let get = |k: &str| fields.get(k).and_then(Value::as_str).map(str::to_owned);
    let full = |s: &str| s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit());
    let r = Receipt {
        base: get("base").filter(|b| !b.is_empty())?,
        before: get("before").filter(|s| full(s))?,
        commit: get("commit").filter(|s| full(s))?,
        at: get("at"),
    };
    Some(r)
}

/// The micro cycle's own check over the prepared range; anything but micro
/// publishes nothing.
fn micro_tier(settings: &Settings, worktree: &Path, base: &str, head: &str) -> Result<()> {
    let request = tier::Request {
        range: Some(ScopeRange {
            base: base.to_owned(),
            head: head.to_owned(),
        }),
        repo: worktree.to_path_buf(),
        ..tier::Request::default()
    };
    let answer = tier::tier(&tier::arm_cli(&settings.scope_paths_cli), &request)
        .map_err(|refused| refuse("delivery-tier", &[("result", &refused.line())]))?;
    if answer.classified.cycle != tier::Cycle::Micro {
        return Err(refuse("delivery-tier", &[("result", &answer.line())]));
    }
    Ok(())
}

/// The publication's validation of the exact prepared head: the runtime's
/// own validation entry over the range from the prepared base, attached,
/// through the one runner. A run that does not pass publishes nothing.
#[allow(
    clippy::disallowed_methods,
    reason = "the publication's validation through this executable's own validation entry, the one runner, before any transport"
)]
fn validate_range(worktree: &Path, base: &str, commit: &str) -> Result<Value> {
    let exe = std::env::current_exe()
        .map_err(|e| refuse("delivery-validate", &[("cause", &e.to_string())]))?;
    let wt = worktree.display().to_string();
    let argv = [
        "validate",
        "entry",
        "--worktree",
        &wt,
        "--validate-mode",
        "range",
        "--base",
        base,
        "--attached",
    ];
    let out = host::run_tagged_in(
        TAG,
        "orch-runtime",
        &exe,
        "validate",
        &argv,
        Place {
            cwd: Some(worktree),
            env: &[],
        },
        BOUND,
    )
    .map_err(|e| {
        refuse(
            "delivery-validate",
            &[("commit", commit), ("cause", &e.to_string())],
        )
    })?;
    let answer = json!({
        "exit": out.status.code(),
        "stdout": host::stdout_text(&out),
        "stderr": host::stderr_text(&out),
    });
    if !out.status.success() {
        return Err(refuse(
            "delivery-validate",
            &[("commit", commit), ("stdout", &host::stdout_text(&out))],
        ));
    }
    Ok(answer)
}

/// Run `r` against the item record at `path`.
#[allow(
    clippy::disallowed_methods,
    reason = "the push's one read of the item record before its effects, binding the request to it"
)]
pub fn run(
    path: &Path,
    r: &RecordPush,
    settings: &Settings,
    flags: &settings::Flags,
    env: &Env,
    locking: Locking,
) -> Result<Pushed> {
    let item = state::item_of(path).unwrap_or_default().to_owned();
    if !valid_item(&item) {
        return Err(refuse("invalid-issue", &[("issue", &item)]));
    }
    let worktree = resolve(r.worktree())?;
    let mut reply = Pushed {
        mode: r.word(),
        exit: 0,
        live_round: None,
        previous: None,
        reconciled: Vec::new(),
        push: None,
        stage: None,
        prepared: None,
        validation: None,
        delivery: None,
    };
    let record = state::load(path)?.map(|s| s.doc);
    if let Some(doc) = &record {
        bind(doc, &item, &worktree)?;
        if let Some(round) = live_round(doc, &item, &worktree)? {
            if let RecordPush::CheckLiveRound { .. } = r {
                reply.exit = LIVE_EXIT;
                reply.live_round = Some(round);
                return Ok(reply);
            }
            return Err(refuse(
                "live-round",
                &[
                    ("round", &round),
                    ("worktree", &worktree.display().to_string()),
                ],
            ));
        }
    }
    match r {
        RecordPush::CheckLiveRound { .. } => return Ok(reply),
        RecordPush::RecordRestackValidation { run_dir, .. } => {
            let at = head(&worktree)?;
            reply.stage = Some(
                match record_stage(path, std::slice::from_ref(run_dir), true, &at, locking) {
                    Ok(Some(dir)) => dir,
                    Ok(None) => "none".into(),
                    Err(cause) => format!("unrecorded cause={cause}"),
                },
            );
            return Ok(reply);
        }
        _ => {}
    }
    if let RecordPush::Publish { base, head, .. } = r {
        let full = |s: &str| {
            s.len() == 40
                && s.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        if !full(base) || !full(head) {
            return Err(refuse("delivery-phase", &[("mode", "publish")]));
        }
    }
    let map = map_file(&worktree)?;
    let pending = map.with_file_name(PENDING);
    // The hops a restack left are reconciled before the push, where nothing
    // new is stale yet; the run that validated the restacked head is kept
    // for the stage the push records once it lands.
    let keep_pending = |worktree: &Path| {
        let Ok(at) = head(worktree) else {
            return;
        };
        if let Ok(Some((dir, ..))) = restack_run(&run_dirs(worktree), &at) {
            let _ = save_pending(&pending, &item, &at, &dir.display().to_string());
        }
    };
    let restacked = match consume(path, &item, &map, RESTACK, locking, &mut || {
        keep_pending(&worktree)
    })? {
        Some(reports) => {
            reply.reconciled.extend(reports);
            true
        }
        None => false,
    };
    let mut bound: Option<(String, Option<PathBuf>)> = None;
    if restacked {
        bound = Some((head(&worktree)?, None));
    }
    let current = head(&worktree)?;
    if let Some(dir) = pending_run(&pending, &item, &current) {
        bound = Some((current.clone(), Some(dir)));
    }
    let at_worktree = crate::validate::entry::resolve_at(&worktree, flags)?;
    let delivery = at_worktree
        .validate
        .delivery
        .clone()
        .unwrap_or_else(|| "pr".into());
    let base_delivery = delivery == "push-base";
    match r {
        RecordPush::Branch { .. } if base_delivery => {
            return Err(refuse("delivery-phase", &[("phase", "missing")]));
        }
        RecordPush::Prepare { .. } | RecordPush::Publish { .. } if !base_delivery => {
            return Err(refuse("delivery-phase", &[("delivery", &delivery)]));
        }
        _ => {}
    }
    let cli = &settings.worktree_cli;
    if let RecordPush::Prepare { .. } = r {
        let push = prepare_once(cli, &worktree, &item, &map.with_file_name(FOLD_MESSAGE))?;
        if let Some(reports) = consume(path, &item, &map, RESTACK, locking, &mut || {
            keep_pending(&worktree)
        })
        .map_err(|e| after_push(e, &push))?
        {
            reply.reconciled.extend(reports);
        }
        let status = push.status.clone();
        let exit = push.exit;
        let stdout = push.stdout.clone();
        reply.push = Some(push);
        match status {
            PushStatus::Unknown => reply.exit = UNKNOWN_EXIT,
            PushStatus::Failed => reply.exit = exit.unwrap_or(1),
            PushStatus::Confirmed => {
                reply.prepared = Some(receipt(&stdout, "prepared-base: ").ok_or_else(|| {
                    refuse(
                        "delivery-prepare",
                        &[("worktree", &worktree.display().to_string())],
                    )
                })?);
            }
        }
        return Ok(reply);
    }
    let mut args: Vec<String> = Vec::new();
    let published = match r {
        RecordPush::Branch { args: given, .. } | RecordPush::Checkpoint { args: given, .. } => {
            args.clone_from(given);
            current.clone()
        }
        RecordPush::Publish {
            base,
            head: prepared,
            ..
        } => {
            let at = head(&worktree)?;
            if at != *prepared {
                return Err(refuse(
                    "delivery-validate",
                    &[("commit", prepared), ("head", &at)],
                ));
            }
            let tier = record
                .as_ref()
                .and_then(|d| d.get("tier"))
                .and_then(Value::as_str)
                .unwrap_or("standard");
            if tier == "micro" {
                micro_tier(settings, &worktree, base, prepared)?;
            } else {
                reply.validation = Some(validate_range(&worktree, base, prepared)?);
            }
            let after = head(&worktree)?;
            if after != *prepared {
                return Err(refuse(
                    "delivery-validate",
                    &[("commit", prepared), ("head", &after)],
                ));
            }
            args = vec!["--to-base".to_owned(), base.clone()];
            prepared.clone()
        }
        _ => unreachable!("the read-only modes answered above"),
    };
    reply.previous = settle(path, &worktree, &published, locking)?;
    mark_attempt(
        path,
        Some(
            json!({"state": "attempted", "mode": r.word(), "head": published, "at": env.now_secs}),
        ),
        locking,
    )?;
    let push = match push_once(cli, &worktree, &args) {
        Ok(push) => push,
        Err(e) => {
            mark_attempt(path, None, locking)?;
            return Err(e);
        }
    };
    // The push rebases before it publishes, so its own hop is in the map
    // whatever its answer.
    if let Some(reports) =
        consume(path, &item, &map, PUSHED, locking, &mut || {}).map_err(|e| after_push(e, &push))?
    {
        reply.reconciled.extend(reports);
    }
    match &push.status {
        PushStatus::Unknown => {}
        PushStatus::Confirmed => mark_attempt(
            path,
            Some(
                json!({"state": "confirmed", "mode": r.word(), "head": head(&worktree)?, "at": env.now_secs}),
            ),
            locking,
        )?,
        PushStatus::Failed => mark_attempt(
            path,
            Some(
                json!({"state": "failed", "mode": r.word(), "exit": push.exit, "at": env.now_secs}),
            ),
            locking,
        )?,
    }
    reply.exit = match push.status {
        PushStatus::Confirmed => 0,
        PushStatus::Failed => push.exit.unwrap_or(1),
        PushStatus::Unknown => UNKNOWN_EXIT,
    };
    if reply.exit == 0
        && let Some((at, dir)) = bound
    {
        let (dirs, named) = match dir {
            Some(dir) => (vec![dir], true),
            None => (run_dirs(&worktree), false),
        };
        reply.stage = Some(match record_stage(path, &dirs, named, &at, locking) {
            Ok(recorded) => match clear_pending(&pending) {
                Ok(()) => recorded.unwrap_or_else(|| "none".into()),
                Err(e) => format!("unrecorded cause={e}"),
            },
            Err(cause) => format!("unrecorded cause={cause}"),
        });
    }
    if reply.exit == 0
        && let RecordPush::Publish { .. } = r
    {
        reply.delivery = Some(
            receipt(&push.stdout, "pushed-base: ")
                .filter(|d| d.at.is_some())
                .ok_or_else(|| after_push(refuse("delivery-read", &[]), &push))?,
        );
    }
    reply.push = Some(push);
    Ok(reply)
}
