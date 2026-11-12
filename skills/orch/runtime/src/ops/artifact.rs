//! A delegation token binds a completion receipt to its round.
//! Validation belongs to the tree it proves, independent of delegation time.

use agent_runtime::record::{self, Locking};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host::{self, Place};
use clap::{Args, Subcommand};
use serde_json::{Value, json};

use super::{Env, proof};
use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::state::{self, ItemState, Stage, StageKind, ValidateMode};
use crate::validate::files::{self, RunFile};
use agent_runtime::clock::Clock;

#[derive(Debug, Subcommand)]
pub enum DevReturn {
    Write(Box<WriteReturn>),
    Check(CheckReturn),
}

#[derive(Debug, Subcommand)]
pub enum Round {
    Stamp(StampRound),
    Cut(StampRound),
    Recover(RecoverRound),
}

#[derive(Debug, Args)]
pub struct Identity {
    #[arg(long)]
    pub worktree: PathBuf,
    #[arg(long)]
    pub issue: String,
    #[arg(long)]
    pub round_id: String,
}

#[derive(Debug, Args)]
pub struct StampRound {
    #[command(flatten)]
    pub id: Identity,
    #[arg(long, num_args = 3, action = clap::ArgAction::Append, conflicts_with = "items_file", allow_hyphen_values = true)]
    pub item: Vec<String>,
    #[arg(long)]
    pub items_file: Option<PathBuf>,
    #[arg(long)]
    pub adds: Option<String>,
    #[arg(long)]
    pub cut: bool,
    #[arg(long)]
    pub source: Option<String>,
    #[arg(long, value_parser = ["true", "false"], default_value = "false")]
    pub pr_open: String,
    #[arg(long)]
    pub finding_occurrences_file: Option<PathBuf>,
}

#[derive(Debug, Args)]
#[command(
    after_help = "A foreground record has validate-mode=full|range, head=40-hex, started-at=UTC, ended-at=UTC, exit=0..999 and selection=all|subset|battery|unreported. A reported selection also has lanes=NAME,...; an unreported selection has none. verdict=no-verdict records a bounded run.\nThe Apple gate reads ORCH_APPLE_WORKFLOW (.github/workflows/mac-run.yml) on the base branch. Declare the item's labels with --label or --no-labels. ios/macOS paths, Xcode projects, Apple Package.swift platforms or labels ios/macos require a validate-note line: mac run test: pass run=ID.\n--validate not-run ends a round whose item permits ending with no change: --no-change TEXT quotes the item's sentence that permits it, and the round names a summary, no run and no record, at the HEAD it was delegated at with a clean tree."
)]
pub struct WriteReturn {
    #[command(flatten)]
    pub id: Identity,
    #[arg(long, value_parser = ["implement", "fix"])]
    pub kind: String,
    #[arg(long)]
    pub branch: String,
    #[arg(long)]
    pub commit: String,
    #[arg(long)]
    pub validate: String,
    #[arg(long, allow_hyphen_values = true)]
    pub validate_note: Option<String>,
    #[arg(long, conflicts_with = "validate_record")]
    pub validate_run_dir: Option<PathBuf>,
    #[arg(long)]
    pub validate_record: Option<PathBuf>,
    #[arg(long, conflicts_with_all = ["summary_file", "recovered_text"], allow_hyphen_values = true)]
    pub summary: Option<String>,
    #[arg(long, conflicts_with = "recovered_text")]
    pub summary_file: Option<PathBuf>,
    #[arg(long)]
    pub recovered_text: Option<PathBuf>,
    #[arg(long)]
    pub qa_label: Vec<String>,
    #[arg(long, conflicts_with = "no_labels")]
    pub label: Vec<String>,
    #[arg(long)]
    pub no_labels: bool,
    #[arg(long)]
    pub screenshot: Vec<PathBuf>,
    #[arg(long)]
    pub near_ceiling_base: Option<String>,
    #[arg(long)]
    pub bundled: bool,
    #[arg(long)]
    pub no_summary: bool,
    #[arg(long, num_args = 3, action = clap::ArgAction::Append, allow_hyphen_values = true)]
    pub item: Vec<String>,
    #[arg(long, allow_hyphen_values = true)]
    pub no_change: Option<String>,
}

#[derive(Debug, Args)]
pub struct CheckReturn {
    #[arg(long, conflicts_with_all = ["worktree", "issue", "expect_items_from_round"])]
    pub file: Option<PathBuf>,
    #[arg(long, required_unless_present = "file")]
    pub worktree: Option<PathBuf>,
    #[arg(long, required_unless_present = "file")]
    pub issue: Option<String>,
    #[arg(long, required_unless_present = "file")]
    pub round_id: Option<String>,
    #[arg(long)]
    pub expect_items: Option<String>,
    #[arg(long)]
    pub expect_items_from_round: bool,
    #[arg(long, default_value_t = 0)]
    pub wait: u64,
    #[arg(long, default_value_t = 5, value_parser = clap::value_parser!(u64).range(1..))]
    pub interval: u64,
}

#[derive(Debug, Args)]
pub struct RecoverRound {
    #[command(flatten)]
    pub id: Identity,
    #[arg(long, conflicts_with = "directive_unconfirmed")]
    pub transcript: Option<PathBuf>,
    #[arg(long)]
    pub directive_unconfirmed: bool,
}

pub struct Answer {
    pub value: Value,
    pub text: String,
    pub status: i32,
}

impl Answer {
    fn path(path: &Path) -> Self {
        Self {
            value: json!({"path": path}),
            text: path.display().to_string(),
            status: 0,
        }
    }
}

fn refuse(key: &'static str, cause: impl ToString) -> Error {
    Error::Artifact {
        key,
        cause: cause.to_string(),
    }
}

fn token(value: &str) -> Result<()> {
    if value.is_empty()
        || value.contains("..")
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return Err(refuse("invalid-id", value));
    }
    Ok(())
}

fn sha(value: &str) -> bool {
    value.len() == 40
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn nonempty(value: &str) -> bool {
    !value.trim().is_empty()
}

fn text(path: &Path, key: &'static str) -> Result<String> {
    fs::read_to_string(path).map_err(|e| refuse(key, format!("{}: {e}", path.display())))
}

fn optional_text(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(Some(s)),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
        Err(e) => Err(refuse(
            "artifact-unreadable",
            format!("{}: {e}", path.display()),
        )),
    }
}

fn json_file(path: &Path, key: &'static str) -> Result<Value> {
    serde_json::from_str(&text(path, key)?)
        .map_err(|e| refuse(key, format!("{}: {e}", path.display())))
}

fn fields(s: &str) -> BTreeMap<&str, &str> {
    s.lines().filter_map(|l| l.split_once('=')).collect()
}

#[allow(
    clippy::disallowed_methods,
    reason = "bounded read-only git and shared catalog measurements before the artifact's write"
)]
fn call(
    worktree: &Path,
    program: &Path,
    operation: &'static str,
    args: &[&str],
    env: &[(&str, &OsStr)],
) -> Result<std::process::Output> {
    host::run_tagged_in(
        "artifact",
        "artifact-read",
        program,
        operation,
        args,
        Place {
            cwd: Some(worktree),
            env,
        },
        Duration::from_secs(120),
    )
    .map_err(|e| refuse("artifact-read", e))
}

/// Git answers in C-locale text under the user's own configuration, as the
/// worktree's other git reads do: the clean check honours the user's
/// excludes file, which validation's snapshot honours, and a checkout another
/// account owns reads only under the user's `safe.directory`. No read here
/// prints a form that configuration changes: object names, porcelain status
/// and `-z` path lists.
const GIT_ENV: [(&str, &str); 1] = [("LC_ALL", "C")];

fn git_call(
    worktree: &Path,
    operation: &'static str,
    args: &[&str],
) -> Result<std::process::Output> {
    let env: Vec<(&str, &OsStr)> = GIT_ENV
        .iter()
        .map(|(name, value)| (*name, OsStr::new(*value)))
        .collect();
    call(worktree, Path::new("git"), operation, args, &env)
}

fn git(worktree: &Path, args: &[&str]) -> Result<String> {
    let out = git_call(worktree, "git", args)?;
    if !out.status.success() {
        return Err(refuse("git-failed", host::stderr_text(&out)));
    }
    Ok(host::stdout_text(&out).trim_end().to_owned())
}

fn ancestor(worktree: &Path, base: &str, head: &str) -> Result<bool> {
    let out = git_call(
        worktree,
        "ancestor",
        &["merge-base", "--is-ancestor", base, head],
    )?;
    match out.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => Err(refuse("ancestry-unreadable", host::stderr_text(&out))),
    }
}

fn committed_tree(worktree: &Path, head: &str) -> Result<String> {
    if !sha(head) {
        return Err(refuse("run-headless", head));
    }
    git(
        worktree,
        &["rev-parse", "--verify", &format!("{head}^{{tree}}")],
    )
}

fn script(settings: &Settings, name: &str) -> PathBuf {
    crate::watch::overseer::scripts_dir(&settings.roots.project).join(name)
}

fn shared_measure(
    settings: &Settings,
    worktree: &Path,
    command: &str,
    commit: &str,
) -> Result<String> {
    let lib = script(settings, "../../change-scope/scripts/lib/branch-growth.sh");
    let resolver = script(settings, "resolve-base-branch");
    let lib = lib.display().to_string();
    let resolver = resolver.display().to_string();
    let code = format!(
        "set -euo pipefail\n. \"$1\"\n[ \"${{BRANCH_GROWTH_CONTRACT:-0}}\" -ge 1 ] || exit 2\n{command} \"$2\" \"$3\" {commit} value\nprintf '%s\\n' \"$value\""
    );
    let wt = worktree.display().to_string();
    let out = call(
        worktree,
        Path::new("/bin/bash"),
        "branch-measure",
        &["-c", &code, "artifact", &lib, &wt, &resolver],
        &[],
    )?;
    if !out.status.success() {
        return Err(refuse("baseline-read", host::stderr_text(&out)));
    }
    Ok(host::stdout_text(&out).trim().to_owned())
}

fn base_ref(settings: &Settings, worktree: &Path) -> Result<String> {
    shared_measure(settings, worktree, "branch_growth_base_ref", "")
}

fn round_path(id: &Identity) -> PathBuf {
    id.worktree
        .join(format!("tmp/dev-round-{}-{}.json", id.issue, id.round_id))
}

fn bare_path(id: &Identity) -> PathBuf {
    id.worktree
        .join(format!("tmp/dev-return-{}-{}.json", id.issue, id.round_id))
}

fn run_key(path: &Path) -> Result<&str> {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| refuse("invalid-id", path.display()))?;
    let key = name.strip_prefix("dev-validate-").unwrap_or(name);
    token(key)?;
    Ok(key)
}

fn keyed_path(id: &Identity, run: &Path) -> Result<PathBuf> {
    Ok(id.worktree.join(format!(
        "tmp/dev-return-{}-{}-{}.json",
        id.issue,
        id.round_id,
        run_key(run)?
    )))
}

fn identity(id: &Identity) -> Result<()> {
    token(&id.issue)?;
    token(&id.round_id)?;
    let _ = fs::read_dir(&id.worktree).map_err(|e| refuse("not-directory", e))?;
    Ok(())
}

fn relative(path: &str) -> bool {
    nonempty(path)
        && !path.starts_with(['/', '-'])
        && !path.bytes().any(|b| b.is_ascii_whitespace())
        && path
            .split('/')
            .all(|p| !p.is_empty() && p != "." && p != "..")
}

fn reach(value: &str) -> bool {
    let lower = value.to_lowercase();
    nonempty(value)
        && !lower.contains("prrt_")
        && ![
            "copilot thread",
            "the finding",
            "a name containing a quote",
            "an empty pi_coding_agent_dir",
        ]
        .contains(&lower.as_str())
}

fn unique_numbers(items: &Value, round: bool) -> bool {
    let Some(items) = items.as_array() else {
        return false;
    };
    let mut seen = BTreeSet::new();
    !items.is_empty()
        && items.iter().all(|i| {
            i["n"].as_u64().is_some_and(|n| seen.insert(n))
                && if round {
                    i["text"].as_str().is_some_and(nonempty)
                } else {
                    i["decision"]
                        .as_str()
                        .is_some_and(|s| ["Applied", "Skipped", "Blocked"].contains(&s))
                        && i["reasoning"].as_str().is_some_and(nonempty)
                }
        })
}

fn round_record(id: &Identity) -> Result<Value> {
    let path = round_path(id);
    if !fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_file()) {
        return Err(refuse("round-missing", path.display()));
    }
    let r = json_file(&path, "round-json")?;
    if r["round_id"] != id.round_id {
        return Err(refuse("round-mismatch", path.display()));
    }
    let adds = r["adds"].as_array();
    if r["schema_version"] != 2
        || r["issue"] != id.issue
        || !r["base_sha"].as_str().is_some_and(sha)
        || !unique_numbers(&r["items"], true)
        || !adds.is_some_and(|a| {
            a.iter().all(|p| p.as_str().is_some_and(relative))
                && a.iter()
                    .filter_map(Value::as_str)
                    .collect::<BTreeSet<_>>()
                    .len()
                    == a.len()
        })
        || !(r["cut"].is_null() || r["cut"].is_boolean())
        || r.get("pr_open").is_some_and(|v| !v.is_boolean())
    {
        return Err(refuse("round-schema", path.display()));
    }
    Ok(r)
}

#[allow(
    clippy::disallowed_methods,
    reason = "exclusive same-directory scratch and atomic artifact publication; immutable rounds use create-if-absent hard links"
)]
fn publish(path: &Path, value: &Value, immutable: bool) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| refuse("artifact-write", path.display()))?;
    fs::create_dir_all(parent).map_err(|e| refuse("artifact-write", e))?;
    let mut lock = agent_runtime::record::lock(path)?;
    lock.with(|| Ok(publish_locked(path, value, immutable)))?
}

#[allow(
    clippy::disallowed_methods,
    reason = "publication holds the artifact lock and owns its exclusive scratch file"
)]
fn publish_locked(path: &Path, value: &Value, immutable: bool) -> Result<()> {
    static SCRATCH: AtomicU64 = AtomicU64::new(0);
    let scratch = path.with_extension(format!(
        "json.{}-{}.tmp",
        std::process::id(),
        SCRATCH.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&scratch)
        .map_err(|e| refuse("artifact-write", e))?;
    let result = (|| {
        serde_json::to_writer_pretty(&mut file, value)?;
        file.write_all(b"\n")
            .map_err(|e| refuse("artifact-write", e))?;
        file.sync_all().map_err(|e| refuse("artifact-write", e))?;
        if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(refuse("record-symlink", path.display()));
        }
        if immutable {
            match fs::hard_link(&scratch, path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == ErrorKind::AlreadyExists => {
                    let mut old = json_file(path, "record-conflict")?;
                    let mut new = value.clone();
                    old.as_object_mut()
                        .ok_or_else(|| refuse("record-conflict", path.display()))?
                        .remove("delegated_at");
                    new.as_object_mut()
                        .expect("an artifact is an object")
                        .remove("delegated_at");
                    if old == new {
                        Ok(())
                    } else {
                        Err(refuse("record-conflict", path.display()))
                    }
                }
                Err(e) => Err(refuse("artifact-write", e)),
            }
        } else {
            if let Some(old) = optional_text(path)?
                && serde_json::from_str::<Value>(&old).is_ok_and(|v| {
                    v["validate"]
                        .as_str()
                        .is_some_and(|s| s.starts_with("FAILING:"))
                })
            {
                return Err(refuse("receipt-exists", path.display()));
            }
            fs::rename(&scratch, path).map_err(|e| refuse("artifact-write", e))
        }
    })();
    let removed = fs::remove_file(&scratch);
    match removed {
        Ok(()) => {}
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) if result.is_ok() => return Err(refuse("artifact-cleanup", e)),
        Err(_) => {}
    }
    result
}

pub fn stamp(r: &StampRound, cut: bool, env: &Env) -> Result<Answer> {
    identity(&r.id)?;
    let items = match &r.items_file {
        Some(path) => json_file(path, "invalid-json")?,
        None => Value::Array(
            r.item
                .chunks_exact(3)
                .map(|i| {
                    let n = i[0].parse::<u64>().ok().filter(|n| n.to_string() == i[0]);
                    json!({"n": n, "text": i[1], "reach": i[2]})
                })
                .collect(),
        ),
    };
    if !unique_numbers(&items, true) {
        return Err(refuse(
            "invalid-items",
            "unique item numbers and nonempty text required",
        ));
    }
    if !items
        .as_array()
        .expect("validated array")
        .iter()
        .all(|i| i["reach"].as_str().is_some_and(reach))
    {
        return Err(refuse(
            "reach-refused",
            "each item needs a shipped producer, user action or fixture",
        ));
    }
    let items: Vec<Value> = items
        .as_array()
        .expect("validated array")
        .iter()
        .map(|i| json!({"n": i["n"], "text": i["text"], "reach": i["reach"]}))
        .collect();
    let adds: Vec<&str> = r
        .adds
        .as_deref()
        .unwrap_or_default()
        .split_ascii_whitespace()
        .collect();
    if (r.adds.is_some() && adds.is_empty())
        || !adds.iter().all(|a| relative(a))
        || adds.iter().collect::<BTreeSet<_>>().len() != adds.len()
    {
        return Err(refuse(
            "invalid-adds",
            r.adds.as_deref().unwrap_or_default(),
        ));
    }
    if let Some(source) = &r.source {
        token(source)?;
    }
    let base = git(&r.id.worktree, &["rev-parse", "--verify", "HEAD^{commit}"])?;
    let mut record = json!({"schema_version": 2, "round_id": r.id.round_id, "issue": r.id.issue, "base_sha": base, "delegated_at": env.now_secs, "adds": adds, "cut": cut || r.cut, "source": r.source, "pr_open": r.pr_open == "true", "items": items});
    if let Some(path) = &r.finding_occurrences_file {
        let findings = json_file(path, "findings-input")?;
        if !["none", "unknown"].contains(&findings["prior"].as_str().unwrap_or_default())
            || !findings["classes"].is_array()
        {
            return Err(refuse("findings-input", path.display()));
        }
        record["finding_occurrences"] = findings;
    }
    let path = round_path(&r.id);
    publish(&path, &record, true)?;
    Ok(Answer::path(
        &fs::canonicalize(&path).map_err(|e| refuse("artifact-write", e))?,
    ))
}

#[derive(Default)]
struct Run {
    mode: String,
    head: String,
    tree: String,
    base: Option<String>,
    orphaned: Option<String>,
    start: u64,
    verdict: String,
    time: Value,
    lanes: Option<String>,
    selection: String,
}

/// A run directory read as the validation entry's `--record` reads it: the
/// run file's mode, selection and verdict, refused with the reader's own
/// diagnostic where that record could not be read.
fn run_record(path: &Path) -> Result<Run> {
    let unreadable = |e: Error| {
        let cause = match e {
            Error::ValidateUnreadable { read, cause } => format!("{read} cause={cause}"),
            other => other.to_string(),
        };
        refuse(
            "run-record-unreadable",
            format!("path={} cause={cause}", path.display()),
        )
    };
    let file = RunFile::read(path).map_err(unreadable)?;
    file.record().map_err(unreadable)?;
    let (lanes, selection) = file.selection().map_err(unreadable)?;
    let field = |key: &str| Some(file.get(key)).filter(|s| !s.is_empty());
    let mut run = Run {
        mode: file.get("validate-mode").to_owned(),
        head: file.get("head").to_owned(),
        tree: file.get("tree").to_owned(),
        base: field("class-base").map(str::to_owned),
        orphaned: field("validate-base-orphaned").map(str::to_owned),
        start: file.get("start").parse().unwrap_or_default(),
        verdict: file.verdict().map_err(unreadable)?.to_owned(),
        lanes,
        selection,
        ..Run::default()
    };
    if let Some(t) = file.timing().map_err(unreadable)? {
        if let (Some(b), Some(e)) = (
            clock::epoch_secs(&t.started_at),
            clock::epoch_secs(&t.ended_at),
        ) && e.checked_sub(b) == Some(t.seconds)
        {
            run.time =
                json!({"started_at": t.started_at, "ended_at": t.ended_at, "seconds": t.seconds});
        } else {
            return Err(refuse("timing-unreadable", path.display()));
        }
    }
    Ok(run)
}

fn valid_lanes(s: &str) -> bool {
    !s.is_empty()
        && s.split(',').all(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
        })
}

fn foreground(path: &Path) -> Result<Run> {
    let record = text(path, "validate-record-unreadable")?;
    let rows: Vec<_> = record.lines().collect();
    let f = fields(&record);
    if rows.len() != f.len()
        || f.keys().any(|k| {
            ![
                "validate-mode",
                "head",
                "started-at",
                "ended-at",
                "exit",
                "selection",
                "lanes",
                "verdict",
            ]
            .contains(k)
        })
    {
        return Err(refuse("validate-record-line", path.display()));
    }
    for key in [
        "validate-mode",
        "head",
        "started-at",
        "ended-at",
        "exit",
        "selection",
    ] {
        if !f.contains_key(key) {
            return Err(refuse("validate-record-missing", key));
        }
    }
    let mode = f["validate-mode"];
    let selection = f["selection"];
    if !["full", "range"].contains(&mode)
        || !sha(f["head"])
        || !["all", "subset", "battery", "unreported"].contains(&selection)
    {
        return Err(refuse("validate-record-value", path.display()));
    }
    let lanes = f.get("lanes").copied();
    if (selection == "unreported") != lanes.is_none() || lanes.is_some_and(|s| !valid_lanes(s)) {
        return Err(refuse("validate-record-lanes", path.display()));
    }
    let start = clock::epoch_secs(f["started-at"])
        .ok_or_else(|| refuse("validate-record-value", path.display()))?;
    let end = clock::epoch_secs(f["ended-at"])
        .filter(|e| *e >= start)
        .ok_or_else(|| refuse("validate-record-time", path.display()))?;
    let status = f["exit"]
        .parse::<u16>()
        .ok()
        .filter(|n| *n <= 999)
        .ok_or_else(|| refuse("validate-record-value", path.display()))?;
    if f.get("verdict").is_some_and(|s| *s != "no-verdict") {
        return Err(refuse("validate-record-value", path.display()));
    }
    Ok(Run {
        mode: mode.into(),
        head: f["head"].into(),
        start,
        verdict: if f.contains_key("verdict") {
            "no-verdict"
        } else if status == 0 {
            "pass"
        } else {
            "FAILING"
        }
        .into(),
        time: json!({"started_at": f["started-at"], "ended_at": f["ended-at"], "seconds": end - start}),
        lanes: lanes.map(str::to_owned),
        selection: selection.into(),
        ..Run::default()
    })
}

fn stages(settings: &Settings, issue: &str) -> Result<Vec<Stage>> {
    let path = state::item_path(&settings.state_dir, issue);
    match crate::validate::load(&path)? {
        Some(s) => Ok(s.view::<ItemState>(&path)?.stages),
        None => Ok(Vec::new()),
    }
}

fn mode(word: &str) -> Result<ValidateMode> {
    files::mode(word).map_err(|_| refuse("mode-unresolved", word))
}

fn run_tree(id: &Identity, run: &Run) -> Result<String> {
    if sha(&run.tree) {
        return Ok(run.tree.clone());
    }
    let head = git(&id.worktree, &["rev-parse", "HEAD"])?;
    if head != run.head
        || !git(
            &id.worktree,
            &["status", "--porcelain", "--untracked-files=all"],
        )?
        .is_empty()
    {
        return Err(refuse(
            "run-off-round",
            "a run without a snapshot needs its clean recorded HEAD",
        ));
    }
    committed_tree(&id.worktree, &run.head)
}

fn bind_run(settings: &Settings, r: &WriteReturn, run: &Run) -> Result<()> {
    let round = round_record(&r.id)?;
    let base = round["base_sha"].as_str().expect("round schema");
    let target = committed_tree(
        &r.id.worktree,
        &git(
            &r.id.worktree,
            &["rev-parse", "--verify", &format!("{}^{{commit}}", r.commit)],
        )?,
    )?;
    let tree = run_tree(&r.id, run)?;
    if !ancestor(&r.id.worktree, base, &run.head)? {
        let equivalent = committed_tree(&r.id.worktree, base)? == tree;
        if !equivalent && run.orphaned.as_deref() != Some(base) {
            let mapped = projected_base(&r.id.worktree, base)?;
            let contains = match mapped {
                Some(mapped) => ancestor(&r.id.worktree, &mapped, &run.head)?,
                None => false,
            };
            if !contains {
                return Err(refuse(
                    "run-off-round",
                    "the run head does not contain the round base",
                ));
            }
        }
    }
    if tree != target {
        return Err(refuse(
            "run-off-round",
            "the run did not validate the receipt's tree",
        ));
    }
    // A failure is reported over its own tree and asks for no proof of it.
    if r.validate.starts_with("FAILING:") {
        return Ok(());
    }
    let declared = proof::Declaration::of(&settings.validate);
    let mut rows = stages(settings, &r.id.issue)?;
    let recorded = r
        .validate_run_dir
        .as_ref()
        .and_then(|dir| rows.iter().find(|s| s.run_dir.as_deref() == dir.to_str()))
        .is_some_and(|s| s.proof.is_some());
    if !recorded {
        let mut stage = match &r.validate_run_dir {
            // An unrecorded run directory is the proof row its run file
            // reads as, the row the validation entry's own proof reads.
            Some(dir) => RunFile::read(dir)
                .and_then(|file| file.stage())
                .map_err(|e| refuse("run-record-unreadable", e))?,
            None => {
                let cmd = match run.mode.as_str() {
                    "full" => settings.validate.cmd.clone(),
                    "range" => settings.validate.range_cmd.clone(),
                    _ => None,
                }
                .unwrap_or_default();
                let row = json!({"kind":"validate", "start":run.start, "end":run.start,
                    "outcome": if run.verdict == "pass" { "pass" } else if run.verdict == "no-verdict" { "no-verdict" } else { "fail" },
                    "run_dir":r.validate_record,
                    "proof":{"tree":"","head":run.head,"base":base,"mode":run.mode,"caller":"dev","cmd":cmd,"class":"standard","docs_only":false,"paths_hash":"","scoped":false,"selection":run.selection,"finding_prefix":declared.finding_prefix,"timeout_secs":0,"poll_secs":1,"cap_secs":0}});
                serde_json::from_value::<Stage>(row)?
            }
        };
        stage.round_id = Some(r.id.round_id.clone());
        if stage.end.is_none() && stage.outcome.is_some() {
            stage.end = Some(stage.start);
        }
        let Some(proof) = stage.proof.as_mut().filter(|p| !p.cmd.is_empty()) else {
            return Err(refuse(
                "run-off-round",
                "the run carries no declared command proof",
            ));
        };
        proof.tree = tree.clone();
        if proof.base.is_empty() {
            proof.base = base.to_owned();
        }
        rows.insert(0, stage);
    }
    let request = proof::ReadProof {
        need: proof::Need::Round,
        tree,
        head: Some(r.commit.clone()),
        base: Some(base.to_owned()),
        round: None,
    };
    let mut tree_of = |head: &str| committed_tree(&r.id.worktree, head).ok();
    let answer = proof::read(&rows, &[], &request, &declared, &mut tree_of);
    match (r.validate.as_str(), answer.proof) {
        ("pass", proof::Verdict::Complete | proof::Verdict::Pending) => Ok(()),
        ("no-verdict", _) if run.verdict == "no-verdict" => Ok(()),
        _ => Err(refuse(
            "run-off-round",
            "Need::Round has no applicable proof of the tree",
        )),
    }
}

/// A project file's lexical token: a quoted string whose escape the reader
/// cannot decode stays a token, and matters only where a member's name needs it.
enum Token {
    Punct(char),
    Text(String),
    Undecodable,
}

fn apple_names(manifest: &str) -> Option<BTreeSet<String>> {
    let mut tokens = Vec::new();
    let mut it = manifest.chars().peekable();
    while let Some(c) = it.next() {
        if c.is_whitespace() {
            continue;
        }
        if c == '/' && it.peek() == Some(&'*') {
            it.next();
            let mut prev = ' ';
            for c in it.by_ref() {
                if prev == '*' && c == '/' {
                    break;
                }
                prev = c;
            }
        } else if c == '/' && it.peek() == Some(&'/') {
            for c in it.by_ref() {
                if c == '\n' {
                    break;
                }
            }
        } else if c == '"' {
            let mut s = String::new();
            let mut decoded = true;
            let mut closed = false;
            while let Some(c) = it.next() {
                if c == '"' {
                    closed = true;
                    break;
                }
                if c == '\\' {
                    let e = it.next()?;
                    decoded &= e == '"' || e == '\\';
                    s.push(e);
                } else {
                    s.push(c);
                }
            }
            if !closed {
                return None;
            }
            tokens.push(if decoded {
                Token::Text(s)
            } else {
                Token::Undecodable
            });
        } else if "{}=;()".contains(c) {
            tokens.push(Token::Punct(c));
        } else {
            let mut s = c.to_string();
            while it
                .peek()
                .is_some_and(|c| !c.is_whitespace() && !"{}=;()".contains(*c))
            {
                s.push(it.next()?);
            }
            tokens.push(Token::Text(s));
        }
    }
    // A value is `None` where its quoted text could not be decoded.
    let mut stack: Vec<BTreeMap<String, Option<String>>> = Vec::new();
    let mut statement: Vec<Token> = Vec::new();
    let mut names = BTreeSet::new();
    for token in tokens {
        match token {
            Token::Punct('{') => {
                stack.push(BTreeMap::new());
                statement.clear();
            }
            Token::Punct('}') => {
                let object = stack.pop()?;
                if object.get("isa").is_some_and(|s| {
                    s.as_deref().is_some_and(|s| {
                        ["PBXFileReference", "PBXFileSystemSynchronizedRootGroup"].contains(&s)
                    })
                }) {
                    for k in ["path", "name"] {
                        if let Some(value) = object.get(k) {
                            names.extend(
                                value
                                    .as_deref()?
                                    .split('/')
                                    .filter(|s| !s.is_empty() && *s != "." && *s != "..")
                                    .map(str::to_owned),
                            );
                        }
                    }
                }
                statement.clear();
            }
            Token::Punct(';') => {
                if let [Token::Text(key), Token::Punct('='), value] = &statement[..]
                    && let Some(object) = stack.last_mut()
                {
                    let value = match value {
                        Token::Text(s) => Some(s.clone()),
                        Token::Punct(c) => Some(c.to_string()),
                        Token::Undecodable => None,
                    };
                    object.insert(key.clone(), value);
                }
                statement.clear();
            }
            token => statement.push(token),
        }
    }
    stack.is_empty().then_some(names)
}

fn apple_gate(settings: &Settings, r: &WriteReturn) -> Result<()> {
    if r.validate.starts_with("FAILING:") || r.validate == "not-run" {
        return Ok(());
    }
    let base = base_ref(settings, &r.id.worktree)?;
    let workflow = &settings.apple_workflow;
    if git(
        &r.id.worktree,
        &[
            "ls-tree",
            "--full-tree",
            "--name-only",
            &base,
            "--",
            workflow,
        ],
    )?
    .is_empty()
    {
        return Ok(());
    }
    if !r.no_labels && r.label.is_empty() {
        return Err(refuse("labels-undeclared", &r.id.issue));
    }
    let changed = git(
        &r.id.worktree,
        &[
            "diff",
            "--name-only",
            "--no-renames",
            "-z",
            &format!("{base}...{}", r.commit),
            "--",
        ],
    )?;
    let paths: Vec<_> = changed.split('\0').filter(|p| !p.is_empty()).collect();
    let mut triggered = r.label.iter().any(|s| settings.apple_labels.contains(s));
    for path in &paths {
        let parts: Vec<_> = path.split('/').collect();
        triggered |= parts[..parts.len() - 1].iter().any(|p| {
            *p == "ios" || *p == "macos" || p.ends_with(".xcodeproj") || p.ends_with(".xcworkspace")
        });
        if path.ends_with("Package.swift") {
            let out = git_call(
                &r.id.worktree,
                "apple-manifest",
                &["cat-file", "blob", &format!("{}:{path}", r.commit)],
            )?;
            if out.status.success() {
                let t = host::stdout_text(&out);
                triggered |= t.contains(".iOS") || t.contains(".macOS");
            }
        }
    }
    if !triggered {
        let merge = git(&r.id.worktree, &["merge-base", &base, &r.commit])?;
        for revision in [&merge, &r.commit] {
            let projects = git(
                &r.id.worktree,
                &[
                    "ls-tree",
                    "-r",
                    "--full-tree",
                    "--name-only",
                    "-z",
                    revision,
                ],
            )?;
            for project in projects
                .split('\0')
                .filter(|p| p.ends_with(".xcodeproj/project.pbxproj"))
            {
                // A listed project that cannot be read cannot rule out Mac work.
                let manifest = git(
                    &r.id.worktree,
                    &["cat-file", "blob", &format!("{revision}:{project}")],
                );
                match manifest.ok().as_deref().and_then(apple_names) {
                    None => triggered = true,
                    Some(names) => {
                        triggered |= paths
                            .iter()
                            .any(|p| p.split('/').any(|part| names.contains(part)))
                    }
                }
            }
        }
    }
    let passed = r
        .validate_note
        .as_deref()
        .unwrap_or_default()
        .lines()
        .any(|l| {
            l.strip_prefix("mac run test: pass run=")
                .is_some_and(|s| !s.is_empty() && !s.contains(char::is_whitespace))
        });
    if triggered && !passed {
        return Err(refuse("mac-run-missing", &r.id.issue));
    }
    Ok(())
}

fn near_ceiling(r: &WriteReturn) -> (Value, Value) {
    let Some(base) = &r.near_ceiling_base else {
        return (
            Value::Null,
            json!("byte-ceiling not probed: no --near-ceiling-base"),
        );
    };
    let lane =
        r.id.worktree
            .join(".agents/skills/commit-guards/scripts/byte-ceiling");
    let mut ancestor = lane.parent();
    while let Some(path) = ancestor.filter(|p| *p != r.id.worktree) {
        if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink())
            && fs::metadata(path).is_err()
        {
            return (
                Value::Null,
                json!(format!("byte-ceiling broken link: {}", path.display())),
            );
        }
        ancestor = path.parent();
    }
    match fs::symlink_metadata(&lane) {
        Err(e) if e.kind() == ErrorKind::NotFound => (json!([]), Value::Null),
        Err(e) => (Value::Null, json!(e.to_string())),
        Ok(_) if !fs::metadata(&lane).is_ok_and(|m| m.permissions().mode() & 0o111 != 0) => (
            Value::Null,
            json!(format!("byte-ceiling not executable: {}", lane.display())),
        ),
        Ok(_) => match call(
            &r.id.worktree,
            &lane,
            "byte-ceiling",
            &["--base", base],
            &[],
        ) {
            Ok(out) if matches!(out.status.code(), Some(0 | 1)) => (
                json!(
                    host::stdout_text(&out)
                        .lines()
                        .filter(|l| l.starts_with("byte-ceiling: near-ceiling="))
                        .collect::<Vec<_>>()
                ),
                Value::Null,
            ),
            Ok(out) => (
                Value::Null,
                json!(format!(
                    "byte-ceiling exit {}: {}",
                    out.status.code().unwrap_or(-1),
                    host::stderr_text(&out).lines().next().unwrap_or_default()
                )),
            ),
            Err(e) => (Value::Null, json!(e.to_string())),
        },
    }
}

/// A round that made no change, admitted where the item's own text permits
/// that end: what the receipt records of it.
struct NoChange {
    clause: String,
    commit: String,
}

/// The worker quotes the item's sentence; the item's live description,
/// read as the launch gate reads it, proves the sentence is the item's.
/// Whether it permits the end is the acceptance's judgement, never the
/// worker's.
fn no_change(settings: &Settings, r: &WriteReturn) -> Result<Option<NoChange>> {
    let clause = match (r.validate.as_str(), r.no_change.as_deref()) {
        ("not-run", Some(clause)) if nonempty(clause) => clause,
        ("not-run", _) => return Err(refuse("required", "no-change")),
        (validate, Some(_)) => {
            return Err(refuse("no-change-run", format!("validate={validate}")));
        }
        (_, None) => return Ok(None),
    };
    if r.kind != "implement" || r.bundled || !r.item.is_empty() {
        return Err(refuse(
            "no-change-kind",
            format!(
                "kind={} bundled={}",
                r.kind,
                r.bundled || !r.item.is_empty()
            ),
        ));
    }
    if r.validate_run_dir.is_some() || r.validate_record.is_some() {
        return Err(refuse("no-change-run", "an evidence source names a run"));
    }
    let issue = r.id.issue.as_str();
    // The item key is the tracker's own: a Linear identifier, or `issue-N`
    // for a GitHub issue, whose end without a pull request has no owner.
    if issue
        .strip_prefix("issue-")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(refuse("no-change-tracker", "tracker=github"));
    }
    let linear = issue.split_once('-').is_some_and(|(team, n)| {
        team.bytes().next().is_some_and(|b| b.is_ascii_uppercase())
            && team
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
            && !n.is_empty()
            && n.bytes().all(|b| b.is_ascii_digit())
    });
    if !linear {
        return Err(refuse("no-change-unverifiable", format!("item={issue}")));
    }
    let worktree = &r.id.worktree;
    let head = git(worktree, &["rev-parse", "--verify", "HEAD^{commit}"])?;
    let commit = git(
        worktree,
        &["rev-parse", "--verify", &format!("{}^{{commit}}", r.commit)],
    )?;
    let path = state::item_path(&settings.state_dir, issue);
    let delegated = crate::validate::load(&path)?.and_then(|s| {
        s.doc
            .get("pre_delegate_sha")
            .and_then(Value::as_str)
            .map(str::to_owned)
    });
    let Some(delegated) = delegated else {
        return Err(refuse(
            "no-change-unverifiable",
            format!("item={issue} pre_delegate_sha=unrecorded"),
        ));
    };
    if commit != head || head != delegated {
        return Err(refuse(
            "no-change-moved",
            format!("commit={commit} head={head} delegated={delegated}"),
        ));
    }
    let status = git(worktree, &["status", "--porcelain"])?;
    if !status.is_empty() {
        return Err(refuse(
            "no-change-dirty",
            status.lines().next().unwrap_or_default(),
        ));
    }
    let clis = super::Clis {
        tracker: settings.reads.tracker_cli.clone(),
        gh: PathBuf::from("gh"),
        scope_paths: settings.scope_paths_cli.clone(),
    };
    let item = super::admission::read_item(&clis, "linear", issue, None)
        .map_err(|cause| refuse("item-unread", format!("cause={cause}")))?;
    let folded = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    if !folded(&item.body).contains(&folded(clause)) {
        return Err(refuse("no-change-unpermitted", format!("item={issue}")));
    }
    Ok(Some(NoChange {
        clause: clause.to_owned(),
        commit,
    }))
}

pub fn write(settings: &Settings, r: &WriteReturn) -> Result<Answer> {
    identity(&r.id)?;
    if !nonempty(&r.branch)
        || r.commit.is_empty()
        || !r.commit.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(refuse("required", "branch and commit"));
    }
    if !["pass", "no-verdict", "not-run"].contains(&r.validate.as_str())
        && !r.validate.starts_with("FAILING:")
    {
        return Err(refuse("invalid-validate", &r.validate));
    }
    if r.validate_note.as_deref().is_some_and(|s| !nonempty(s))
        || r.summary.as_deref().is_some_and(|s| !nonempty(s))
    {
        return Err(refuse("empty-text", "summary or validate-note"));
    }
    if r.validate == "no-verdict" && r.validate_note.is_none() {
        return Err(refuse("required", "validate-note"));
    }
    if r.near_ceiling_base.as_deref() == Some("") {
        return Err(refuse("required", "near-ceiling-base"));
    }
    let no_change = no_change(settings, r)?;
    let run = match (&r.validate_run_dir, &r.validate_record) {
        (Some(dir), None) => Some(run_record(dir)?),
        (None, Some(file)) => Some(foreground(file)?),
        (None, None) if r.validate.starts_with("FAILING:") || no_change.is_some() => None,
        _ => return Err(refuse("required", "one validation evidence source")),
    };
    let mut commit = no_change
        .as_ref()
        .map_or_else(|| r.commit.clone(), |n| n.commit.clone());
    if let Some(run) = &run {
        if !r.validate.starts_with("FAILING:")
            && r.validate != run.verdict
            && !(r.validate == "pass" && run.mode == "ci" && run.verdict == "pending")
        {
            return Err(refuse(
                "validate-disagrees",
                format!("validate={} run={}", r.validate, run.verdict),
            ));
        }
        // A ci receipt is checked against the exact current HEAD, so it
        // records the full commit its pending contents were compared with.
        if run.mode == "ci" && r.validate == "pass" {
            let mismatch = |_| refuse("ci-contents-mismatch", &r.commit);
            commit = git(
                &r.id.worktree,
                &["rev-parse", "--verify", &format!("{}^{{commit}}", r.commit)],
            )
            .map_err(mismatch)?;
            if run.tree != committed_tree(&r.id.worktree, &commit).map_err(mismatch)? {
                return Err(refuse("ci-contents-mismatch", &r.commit));
            }
        }
    }
    let items: Value = Value::Array(
        r.item
            .chunks_exact(3)
            .map(|i| json!({"n":i[0].parse::<u64>().ok(), "decision":i[1], "reasoning":i[2]}))
            .collect(),
    );
    if (r.kind == "fix" || r.bundled || !r.item.is_empty()) && !unique_numbers(&items, false) {
        return Err(refuse(
            "missing-items",
            "unique item decisions and reasoning required",
        ));
    }
    if r.kind == "fix"
        && let Some(run) = &run
    {
        bind_run(settings, r, run)?;
    }
    let summary = match (&r.summary, &r.summary_file, &r.recovered_text) {
        (Some(s), None, None) => json!(s),
        (None, Some(file), None) | (None, None, Some(file)) => json!(text(file, "missing-file")?),
        (None, None, None) => Value::Null,
        _ => return Err(refuse("summary-conflict", "one summary source")),
    };
    if no_change.is_some() && !summary.as_str().is_some_and(nonempty) {
        return Err(refuse("required", "summary"));
    }
    let mut screenshots = Vec::new();
    for path in &r.screenshot {
        let _ = fs::File::open(path).map_err(|e| refuse("screenshot-unreadable", e))?;
        if !fs::metadata(path).is_ok_and(|m| m.is_file()) {
            return Err(refuse("screenshot-unreadable", path.display()));
        }
        screenshots.push(fs::canonicalize(path).map_err(|e| refuse("screenshot-unreadable", e))?);
    }
    apple_gate(settings, r)?;
    let (near, near_error) = near_ceiling(r);
    let mut record = json!({"schema_version":1,"round_id":r.id.round_id,"kind":r.kind,"issue":r.id.issue,"branch":r.branch,"commit":commit,
        "validate":r.validate,"validate_mode":run.as_ref().map(|r| &r.mode),"validate_time":run.as_ref().map(|r| &r.time),"validate_note":r.validate_note,
        "qa_labels":r.qa_label,"near_ceiling":near,"near_ceiling_error":near_error,"summary_posted":!r.no_summary,"summary":summary,
        "recovered_from":r.recovered_text.as_ref().map(|_| "transcript"),"bundled":r.bundled,"items":items});
    if let Some(run) = &run {
        record["validate_selection"] = json!(run.selection);
        if let Some(lanes) = &run.lanes {
            record["validate_lanes"] = json!(lanes);
        }
        if let Some(base) = &run.base {
            record["validate_class_base"] = json!(base);
        }
    }
    if !screenshots.is_empty() {
        record["screenshots"] = json!(screenshots);
    }
    if let Some(no_change) = &no_change {
        record["no_change"] = json!(no_change.clause);
    }
    if r.kind == "implement" {
        let measured = shared_measure(
            settings,
            &r.id.worktree,
            "branch_baseline_lines",
            &format!("'{}'", commit.replace('\'', "'\\''")),
        )?;
        let n = measured
            .parse::<u64>()
            .map_err(|e| refuse("baseline-read", e))?
            .max(1);
        record["baseline_lines"] = json!(n);
    }
    let path = match &r.validate_run_dir {
        Some(dir) => keyed_path(&r.id, dir)?,
        None => bare_path(&r.id),
    };
    publish(&path, &record, false)?;
    Ok(Answer::path(
        &fs::canonicalize(&path).map_err(|e| refuse("artifact-write", e))?,
    ))
}

fn scalars(v: &Value) -> bool {
    let kind = v["kind"].as_str().unwrap_or_default();
    let validate = v["validate"].as_str().unwrap_or_default();
    let failing = validate.starts_with("FAILING:");
    let not_run = validate == "not-run";
    let unrun = failing || not_run;
    let timing = &v["validate_time"];
    let time_ok = if timing.is_null() {
        unrun && v.get("validate_time").is_some()
    } else {
        let start = timing["started_at"].as_str().and_then(clock::epoch_secs);
        let end = timing["ended_at"].as_str().and_then(clock::epoch_secs);
        matches!((start, end, timing["seconds"].as_u64()), (Some(s), Some(e), Some(n)) if e.checked_sub(s) == Some(n))
            && !v["validate_mode"].is_null()
    };
    v["issue"].as_str().is_some_and(|s| token(s).is_ok())
        && ["implement", "fix"].contains(&kind)
        && ["issue", "branch", "round_id", "commit", "validate"]
            .iter()
            .all(|k| v[*k].as_str().is_some_and(nonempty))
        && v["schema_version"].is_number()
        && time_ok
        && (v["validate_mode"]
            .as_str()
            .is_some_and(|s| files::mode(s).is_ok())
            || (unrun && v.get("validate_mode") == Some(&Value::Null)))
        && (v["validate_note"].is_null() || v["validate_note"].as_str().is_some_and(nonempty))
        && (validate != "no-verdict" || v["validate_note"].as_str().is_some_and(nonempty))
        && (!not_run
            || (kind == "implement"
                && v["validate_mode"].is_null()
                && v["no_change"].as_str().is_some_and(nonempty)
                && v["summary"].as_str().is_some_and(nonempty)))
        && if kind == "implement" {
            v["baseline_lines"].as_u64().is_some_and(|n| n > 0)
        } else {
            v.get("baseline_lines").is_none()
        }
}

fn protected(path: &str) -> bool {
    if ["test-helper", "test_helper", "test-util", "test_util"]
        .iter()
        .any(|p| path.contains(p))
    {
        return true;
    }
    let components: Vec<_> = path.split('/').collect();
    if path.starts_with("crates/")
        || path.starts_with("tools/")
        || (path.starts_with("skills/") || path.starts_with(".agents/skills/"))
            && components.contains(&"scripts")
    {
        return true;
    }
    if components.windows(2).any(|p| p == ["src", "test"])
        || components[..components.len().saturating_sub(1)]
            .iter()
            .any(|p| ["helper", "helpers"].contains(p))
    {
        return true;
    }
    let mut in_tests = false;
    for part in &components[..components.len().saturating_sub(1)] {
        if in_tests && ["support", "lib", "util", "utils"].contains(part) {
            return true;
        }
        in_tests |= ["test", "tests", "__tests__"].contains(part);
    }
    let stem = components
        .last()
        .unwrap_or(&"")
        .trim_start_matches('.')
        .split('.')
        .next()
        .unwrap_or_default();
    in_tests
        && (stem.contains("helper") || stem.contains("test-util") || stem.contains("test_util"))
}

fn projected_base(worktree: &Path, base: &str) -> Result<Option<String>> {
    if ancestor(worktree, base, "HEAD")? {
        return Ok(Some(base.to_owned()));
    }
    let map = git(worktree, &["rev-parse", "--git-path", "kendex-rebase-map"])?;
    let map = PathBuf::from(map);
    let map = if map.is_absolute() {
        map
    } else {
        worktree.join(map)
    };
    let Some(text) = optional_text(&map).map_err(|e| refuse("rebase-map-unreadable", e))? else {
        return Ok(None);
    };
    // An unmapped rewrite or a map outside the grammar projects nothing.
    let Ok(mapped) = proof::project_rebase(&text, base) else {
        return Ok(None);
    };
    if sha(&mapped) && ancestor(worktree, &mapped, "HEAD")? {
        Ok(Some(mapped))
    } else {
        Ok(None)
    }
}

fn additions(
    id: &Identity,
    round: &Value,
) -> Result<std::result::Result<Vec<String>, &'static str>> {
    let base = round["base_sha"].as_str().expect("round schema");
    if git(&id.worktree, &["cat-file", "-t", base]).ok().as_deref() != Some("commit") {
        return Ok(Err("comparison_failed"));
    }
    let base = match projected_base(&id.worktree, base) {
        Ok(Some(base)) => base,
        Ok(None) => return Ok(Err("additions_unattributable")),
        Err(_) => return Ok(Err("comparison_failed")),
    };
    let changed = match git(
        &id.worktree,
        &[
            "diff",
            "--find-renames",
            "--diff-filter=A",
            "--name-only",
            "-z",
            &base,
            "HEAD",
        ],
    ) {
        Ok(p) => p,
        Err(_) => return Ok(Err("comparison_failed")),
    };
    let authorized: BTreeSet<_> = round["adds"]
        .as_array()
        .expect("round schema")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    Ok(Ok(changed
        .split('\0')
        .filter(|p| !p.is_empty() && protected(p) && !authorized.contains(p))
        .map(str::to_owned)
        .collect()))
}

fn check_answer(
    file: Option<&Path>,
    v: &Value,
    reason: &str,
    warning: Option<&str>,
    hint: Option<String>,
    files: &[String],
) -> Answer {
    let ok = reason == "valid";
    let verdict = if ok && (v["validate"] == "pass" || v["validate"] == "no-verdict") {
        "accept"
    } else if ok && v["validate"] == "not-run" {
        "no-change"
    } else if reason == "missing" {
        "wait"
    } else {
        "retry"
    };
    let mut value = json!({"ok":ok,"verdict":verdict,"path":file,"reason":reason,"warning":warning,"hint":hint,"files":files});
    for k in [
        "validate",
        "validate_mode",
        "validate_time",
        "validate_note",
        "validate_lanes",
        "validate_selection",
        "validate_class_base",
        "near_ceiling",
        "near_ceiling_error",
        "screenshots",
        "no_change",
    ] {
        let raw = &v[k];
        value[k] = match k {
            "near_ceiling" if raw.is_null() && v.get(k).is_some() => Value::Null,
            "near_ceiling" | "screenshots" => json!(
                raw.as_array()
                    .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>())
                    .unwrap_or_default()
            ),
            "validate" | "validate_mode" | "validate_note" | "near_ceiling_error" | "no_change" => {
                raw.as_str().map(|s| json!(s)).unwrap_or(Value::Null)
            }
            "validate_time" => {
                if raw.is_object() {
                    raw.clone()
                } else {
                    Value::Null
                }
            }
            _ => raw.clone(),
        };
    }
    Answer {
        text: value.to_string(),
        value,
        status: i32::from(!ok),
    }
}

fn select_receipt(settings: &Settings, id: &Identity) -> Result<(PathBuf, Option<ValidateMode>)> {
    let bare = bare_path(id);
    let rows = stages(settings, &id.issue)?;
    if let Some((_, row)) = rows
        .iter()
        .enumerate()
        .filter(|(_, s)| {
            s.kind == StageKind::Validate
                && s.round_id.as_deref() == Some(&id.round_id)
                && s.run_dir.is_some()
        })
        .max_by_key(|(index, s)| (s.start, *index))
    {
        let keyed = keyed_path(id, Path::new(row.run_dir.as_deref().expect("selected run")))?;
        let mode = row.proof.as_ref().map(|p| p.mode);
        if mode.is_some()
            || fs::symlink_metadata(&keyed).is_ok()
            || fs::symlink_metadata(&bare).is_err()
        {
            return Ok((keyed, mode));
        }
        return Ok((bare, None));
    }
    let prefix = format!("dev-return-{}-{}-", id.issue, id.round_id);
    let mut candidates = Vec::new();
    if fs::symlink_metadata(&bare).is_ok() {
        candidates.push(bare.clone());
    }
    match fs::read_dir(id.worktree.join("tmp")) {
        Ok(entries) => {
            for e in entries {
                let e = e.map_err(|e| refuse("artifact-unreadable", e))?;
                let name = e.file_name();
                let name = name.to_string_lossy();
                if name.starts_with(&prefix) && name.ends_with(".json") {
                    candidates.push(e.path());
                }
            }
        }
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(refuse("artifact-unreadable", e)),
    }
    // A recovery companion must bind its failed parent before selection.
    let recovery = bare.with_file_name(format!(
        "dev-return-{}-{}-recovery.json",
        id.issue, id.round_id
    ));
    if candidates.len() == 2 && candidates.contains(&bare) && candidates.contains(&recovery) {
        let parent = json_file(&bare, "recovery-invalid")?;
        let child = json_file(&recovery, "recovery-invalid")?;
        if !scalars(&parent)
            || !parent["validate"]
                .as_str()
                .is_some_and(|s| s.starts_with("FAILING:"))
            || child["recovery_of"]
                != bare
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or_default()
            || ["issue", "round_id", "kind", "branch"]
                .iter()
                .any(|k| parent[*k] != child[*k])
        {
            return Err(refuse("recovery-invalid", recovery.display()));
        }
        return Ok((recovery, None));
    }
    match candidates.len() {
        0 => Ok((bare, None)),
        1 => Ok((candidates.remove(0), None)),
        _ => Err(refuse("receipt-ambiguous", format!("{candidates:?}"))),
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "receipt cost and finding rows are one advisory item update behind the store's compare-and-write lock"
)]
fn record_check(
    settings: &Settings,
    id: &Identity,
    file: &Path,
    receipt: &Value,
    answer: &Answer,
) -> Result<()> {
    let path = state::item_path(&settings.state_dir, &id.issue);
    record::reread(
        || {
            let Some(snapshot) = crate::validate::load(&path)? else {
                return Ok(());
            };
            let mut doc = snapshot.doc.clone();
            if let Some(rows) = doc.get_mut("stages").and_then(Value::as_array_mut) {
                for row in rows {
                    if row["round_id"] == id.round_id && row["kind"] != "validate" {
                        row["kind"] = receipt["kind"].clone();
                    }
                }
            }
            let name = file
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(|| refuse("artifact-unreadable", file.display()))?;
            let mut batch = json!({"records":[]});
            if let Some(failed) = receipt["validate"]
                .as_str()
                .and_then(|s| s.strip_prefix("FAILING:"))
            {
                let checks: BTreeSet<_> = failed.split(',').map(str::trim).collect();
                if checks.contains("") {
                    batch["unknown"] = json!(true);
                } else {
                    batch["records"] = json!(checks.iter().map(|check| json!({"kind":"validation","check":check,"source":{"round_id":id.round_id,"receipt":name,"identity":["receipt",id.round_id,name,check]}})).collect::<Vec<_>>());
                }
            }
            super::store::findings_record_batch(&mut doc, batch, file)?;
            if !answer.value["validate_time"].is_null() {
                let mut rows = doc
                    .get("validate_rounds")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let original = format!("dev-return-{}-{}.json", id.issue, id.round_id);
                rows.retain(|r| {
                    r["round_id"] != id.round_id
                        || r["receipt"].as_str().unwrap_or(&original) != name
                });
                let mut row = json!({"round_id":id.round_id,"receipt":name,"kind":receipt["kind"],"mode":receipt["validate_mode"],"seconds":receipt["validate_time"]["seconds"]});
                for (key, field) in [
                    ("lanes", "validate_lanes"),
                    ("selection", "validate_selection"),
                ] {
                    if let Some(value) = receipt.get(field) {
                        row[key] = value.clone();
                    }
                }
                rows.push(row);
                doc.insert("validate_rounds".into(), json!(rows));
            }
            Ok(record::store(&path, &snapshot.doc, &doc, Locking::FLOCK)?)
        },
        Error::key,
    )
}

fn check_evaluate(settings: &Settings, r: &CheckReturn) -> Result<Answer> {
    let id = r.worktree.as_ref().map(|w| Identity {
        worktree: w.clone(),
        issue: r.issue.clone().unwrap_or_default(),
        round_id: r.round_id.clone().unwrap_or_default(),
    });
    if let Some(id) = &id {
        identity(id)?;
    }
    if r.expect_items.is_some() && r.file.is_none() {
        return Err(refuse("file-mode-required", "--expect-items"));
    }
    if let Some(round) = &r.round_id {
        token(round)?;
    }
    let round = if r.expect_items_from_round {
        Some(round_record(id.as_ref().expect("round arguments"))?)
    } else {
        None
    };
    let expected = match (&r.expect_items, &round) {
        (Some(s), None) => Some(
            s.split(',')
                .map(|s| {
                    s.parse::<u64>()
                        .map_err(|_| refuse("invalid-item-numbers", s))
                })
                .collect::<Result<Vec<_>>>()?,
        ),
        (None, Some(round)) => Some(
            round["items"]
                .as_array()
                .expect("round schema")
                .iter()
                .map(|i| i["n"].as_u64().expect("round schema"))
                .collect(),
        ),
        _ => None,
    };
    let (file, stage_mode) = match (&r.file, &id) {
        (Some(file), _) => (file.clone(), None),
        (None, Some(id)) => select_receipt(settings, id)?,
        _ => return Err(refuse("required", "file or round")),
    };
    let Some(raw) = optional_text(&file)? else {
        return Ok(check_answer(None, &Value::Null, "missing", None, None, &[]));
    };
    let v = serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null);
    let emit = |reason, warning, hint, files: &[String]| {
        check_answer(Some(&file), &v, reason, warning, hint, files)
    };
    if r.round_id.as_ref().is_some_and(|rid| v["round_id"] != *rid)
        || id.as_ref().is_some_and(|id| v["issue"] != id.issue)
        || !scalars(&v)
    {
        return Ok(emit("invalid", None, None, &[]));
    }
    if id.is_some() && v["kind"] == "fix" && round.is_none() {
        return Err(refuse("expected-round-required", file.display()));
    }
    if let (Some(round), Some(id)) = (&round, &id)
        && v["kind"] == "fix"
        && !v["validate_mode"].is_null()
    {
        let recorded = mode(v["validate_mode"].as_str().expect("receipt schema"))?;
        // A round no stage admitted defers to CI only where the pull request
        // runs CI: open at the stamp, or published first.
        let admitted = match stage_mode {
            Some(wanted) => recorded == wanted,
            None => {
                recorded != ValidateMode::Ci
                    || round["pr_open"] == true
                    || crate::validate::pr_order(settings, &id.worktree, &mut String::new())
                        == "push-first"
            }
        };
        if !admitted {
            return Ok(emit("mode_mismatch", None, None, &[]));
        }
    }
    let repo = id.as_ref().map(|id| id.worktree.clone()).or_else(|| {
        file.parent()
            .filter(|p| p.file_name().is_some_and(|n| n == "tmp"))
            .and_then(Path::parent)
            .map(Path::to_path_buf)
    });
    let Some(repo) = repo else {
        return Ok(emit("commit_unverifiable", None, None, &[]));
    };
    if git(&repo, &["rev-parse", "--show-toplevel"])
        .ok()
        .and_then(|p| fs::canonicalize(p).ok())
        != fs::canonicalize(&repo).ok()
    {
        return Ok(emit("commit_unverifiable", None, None, &[]));
    }
    let commit = v["commit"].as_str().expect("receipt schema");
    if !commit.bytes().all(|b| b.is_ascii_hexdigit())
        || git(&repo, &["cat-file", "-t", commit]).ok().as_deref() != Some("commit")
    {
        return Ok(emit("commit_unresolvable", None, None, &[]));
    }
    if v["validate_mode"] == "ci" && commit != git(&repo, &["rev-parse", "HEAD"])? {
        return Ok(emit("ci_head_mismatch", None, None, &[]));
    }
    // A no-change answer ends the item, so it holds only at the HEAD the
    // round left unmoved.
    if v["validate"] == "not-run" && commit != git(&repo, &["rev-parse", "HEAD"])? {
        return Ok(emit("head_moved", None, None, &[]));
    }
    let warning = if ancestor(&repo, commit, "HEAD")? {
        None
    } else {
        Some("commit_unreachable")
    };
    if let Some(round) = &round {
        match additions(id.as_ref().expect("round arguments"), round)? {
            Err(reason) => return Ok(emit(reason, None, None, &[])),
            Ok(files) if !files.is_empty() => {
                return Ok(emit("unapproved_additions", None, None, &files));
            }
            Ok(_) => {}
        }
    }
    let needs_items = expected.is_some() || v["kind"] == "fix" || v["bundled"] == true;
    let actual = v["items"]
        .as_array()
        .map(|i| {
            i.iter()
                .filter_map(|i| i["n"].as_u64())
                .collect::<BTreeSet<_>>()
        })
        .unwrap_or_default();
    if needs_items
        && (!unique_numbers(&v["items"], false)
            || expected
                .as_ref()
                .is_some_and(|e| actual != e.iter().copied().collect()))
    {
        let hint = expected
            .as_ref()
            .filter(|e| {
                round.is_none() && e.len() == 1 && e[0] > 1 && actual == (1..=e[0]).collect()
            })
            .map(|_| "--expect-items takes item numbers, not a count".to_owned());
        return Ok(emit("incomplete", None, hint, &[]));
    }
    Ok(emit("valid", warning, None, &[]))
}

fn check_once(settings: &Settings, r: &CheckReturn) -> Result<Answer> {
    let mut answer = check_evaluate(settings, r)?;
    if answer.value["reason"] != "missing"
        && answer.value["reason"] != "invalid"
        && let (Some(worktree), Some(issue), Some(round), Some(path)) = (
            &r.worktree,
            &r.issue,
            &r.round_id,
            answer.value["path"].as_str(),
        )
    {
        let id = Identity {
            worktree: worktree.clone(),
            issue: issue.clone(),
            round_id: round.clone(),
        };
        let path = PathBuf::from(path);
        let value = json_file(&path, "artifact-unreadable")?;
        if let Err(error) = record_check(settings, &id, &path, &value, &answer) {
            answer.value["record_warning"] = json!(error.to_string());
            answer.text = answer.value.to_string();
        }
    }
    Ok(answer)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the receipt wait owns its one injected deadline and bounded polls"
)]
pub fn check(settings: &Settings, r: &CheckReturn, clock: &dyn Clock) -> Result<Answer> {
    let began = clock.now();
    loop {
        let answer = check_once(settings, r)?;
        let elapsed = clock.now().duration_since(began).as_secs();
        if answer.value["verdict"] != "wait" || elapsed >= r.wait {
            return Ok(answer);
        }
        clock.sleep(Duration::from_secs(r.interval.min(r.wait - elapsed)));
    }
}

fn transcript_report(raw: &str, round: &str) -> Option<String> {
    let marker = format!("Round ID: {round}");
    let mut entered = false;
    let mut sent = None;
    let mut said = None;
    for line in raw.lines() {
        let Ok(line) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let turn = line
            .get("message")
            .or_else(|| line.get("payload"))
            .unwrap_or(&Value::Null);
        let content = |v: &Value| -> String {
            if let Some(s) = v.as_str() {
                return s.to_owned();
            }
            v.as_array()
                .map(|a| {
                    a.iter()
                        .filter(|v| {
                            ["text", "input_text", "output_text"]
                                .iter()
                                .any(|t| v["type"] == *t)
                        })
                        .filter_map(|v| v["text"].as_str())
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default()
        };
        let user = if turn["role"] == "user" {
            Some(content(&turn["content"]))
        } else if turn["type"] == "user_message" {
            Some(content(&turn["message"]))
        } else {
            None
        };
        if let Some(user) = user
            && user.match_indices(&marker).any(|(i, _)| {
                user[i + marker.len()..]
                    .chars()
                    .next()
                    .is_none_or(|c| !c.is_ascii_alphanumeric() && !"._-".contains(c))
            })
        {
            entered = true;
            sent = None;
            said = None;
        }
        if !entered {
            continue;
        }
        if turn["role"] == "assistant" {
            if let Some(parts) = turn["content"].as_array() {
                for part in parts {
                    if part["type"] == "tool_use" && part["name"] == "SendMessage" {
                        if let Some(s) = part["input"]["message"].as_str().filter(|s| nonempty(s)) {
                            sent = Some(s.to_owned());
                        }
                    } else if ["text", "output_text"].iter().any(|t| part["type"] == *t)
                        && let Some(s) = part["text"].as_str().filter(|s| nonempty(s))
                    {
                        said = Some(s.to_owned());
                    }
                }
            }
        } else if turn["type"] == "function_call"
            && turn["name"] == "send_input"
            && let Some(args) = turn["arguments"]
                .as_str()
                .and_then(|s| serde_json::from_str::<Value>(s).ok())
            && let Some(s) = args["message"].as_str().filter(|s| nonempty(s))
        {
            sent = Some(s.to_owned());
        }
    }
    sent.or(said)
}

fn report_field<'a>(report: &'a str, key: &str) -> Option<&'a str> {
    report
        .lines()
        .filter_map(|line| {
            line.trim_start()
                .strip_prefix(key)
                .and_then(|s| s.strip_prefix(':'))
                .map(str::trim)
        })
        .next_back()
}

fn recovery_answer(state: &str, round: &str, from: &str, reason: &str) -> Answer {
    let text = match state {
        "exhausted" => format!("round-recover: exhausted round-id={round} reason={reason}"),
        "redelegate" => {
            format!("round-recover: redelegate round-id={round} from={from} reason={reason}")
        }
        _ => unreachable!("a replacement is redelegated or exhausted"),
    };
    Answer {
        value: json!({"state":state,"round_id":round,"from":from,"reason":reason}),
        text,
        status: if state == "exhausted" { 1 } else { 3 },
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the replacement token, its stage and its recovery allowance are one locked item update"
)]
fn redelegate(settings: &Settings, r: &RecoverRound, reason: &str, env: &Env) -> Result<Answer> {
    let path = state::item_path(&settings.state_dir, &r.id.issue);
    record::reread(
        || {
            let snapshot = crate::validate::load(&path)?.ok_or_else(|| {
                Error::Runtime(agent_runtime::Error::RecordMissing { path: path.clone() })
            })?;
            let mut doc = snapshot.doc.clone();
            if let Some(previous) = doc.get("round_recovery")
                && previous["from"] == r.id.round_id
            {
                return Ok(recovery_answer(
                    "redelegate",
                    previous["to"]
                        .as_str()
                        .ok_or_else(|| refuse("state-failed", "round_recovery.to"))?,
                    &r.id.round_id,
                    previous["reason"].as_str().unwrap_or(reason),
                ));
            }
            if !r.directive_unconfirmed
                && doc
                    .get("recovery_round_id")
                    .is_some_and(|v| *v == r.id.round_id)
            {
                return Ok(recovery_answer(
                    "exhausted",
                    &r.id.round_id,
                    &r.id.round_id,
                    reason,
                ));
            }
            if doc.get("dev_round_id").is_some_and(|v| *v != r.id.round_id) {
                return Err(refuse("round-superseded", &r.id.round_id));
            }
            let begun = super::item::begin_round(
                &path,
                &mut doc,
                &super::BeginRound {
                    kind: super::RoundKind::Dev,
                    body_revision: None,
                },
                env,
            )?;
            if !r.directive_unconfirmed {
                doc.insert("recovery_round_id".into(), json!(begun.round_id));
            }
            doc.insert(
                "round_recovery".into(),
                json!({"from":r.id.round_id,"to":begun.round_id,"reason":reason}),
            );
            record::store(&path, &snapshot.doc, &doc, Locking::FLOCK)?;
            Ok(recovery_answer(
                "redelegate",
                &begun.round_id,
                &r.id.round_id,
                reason,
            ))
        },
        Error::key,
    )
}

#[allow(
    clippy::disallowed_methods,
    reason = "recovery asks the validation owner to reconcile or stop the round's recorded runs before replacing it"
)]
fn reconcile_recovery(settings: &Settings, r: &RecoverRound, env: &Env) -> Result<Option<Answer>> {
    let path = state::item_path(&settings.state_dir, &r.id.issue);
    let rows = stages(settings, &r.id.issue)?;
    if r.directive_unconfirmed {
        stop_worktree_runs(settings, &r.id.issue, &r.id.worktree, env)?;
        for row in rows
            .iter()
            .filter(|s| s.kind == StageKind::Validate && s.end.is_none() && s.job.is_some())
        {
            let dir = row
                .run_dir
                .as_deref()
                .ok_or_else(|| refuse("stop-failed", "started run has no directory"))?;
            let stopped =
                crate::validate::run::stop(settings, Some(&r.id.issue), dir, env, Locking::FLOCK)?;
            if stopped.job != crate::validate::run::JobState::Gone {
                return Err(refuse("stop-failed", dir));
            }
        }
        return Ok(None);
    }
    if rows
        .iter()
        .any(|s| s.kind != StageKind::Validate && s.round_id.as_deref() == Some(&r.id.round_id))
    {
        let result = super::apply(
            &path,
            &super::Request::ReconcileRound(super::ReconcileRound {
                round_id: r.id.round_id.clone(),
            }),
            env,
            Locking::FLOCK,
        )?;
        if let super::Report::ReconcileRound(result) = result.report {
            for run in result.runs {
                match run.state {
                    super::RunState::Live { .. } | super::RunState::LiveUnit { .. } => {
                        return Ok(Some(Answer {
                            value: json!({"state":"round-live","run_dir":run.run_dir}),
                            text: format!("round-recover: round-live run-dir={}", run.run_dir),
                            status: 4,
                        }));
                    }
                    super::RunState::Unreadable { cause } => {
                        return Err(refuse("run-unreadable", cause));
                    }
                    super::RunState::Closed { .. } => {}
                }
            }
        }
    }
    Ok(None)
}

fn recovery_run(settings: &Settings, id: &Identity) -> Result<Option<(PathBuf, Run)>> {
    let rows = stages(settings, &id.issue)?;
    let mut runs: Vec<_> = rows
        .iter()
        .enumerate()
        .filter(|(_, s)| {
            s.kind == StageKind::Validate && s.round_id.as_deref() == Some(&id.round_id)
        })
        .filter_map(|(i, s)| {
            s.run_dir
                .as_ref()
                .map(|dir| (s.start, i, PathBuf::from(dir)))
        })
        .collect();
    if runs.is_empty() {
        match fs::read_dir(id.worktree.join("tmp")) {
            Ok(entries) => {
                for entry in entries {
                    let entry = entry.map_err(|e| refuse("run-unreadable", e))?;
                    if entry
                        .file_name()
                        .to_str()
                        .is_some_and(|s| s.starts_with("dev-validate-"))
                        && entry
                            .file_type()
                            .map_err(|e| refuse("run-unreadable", e))?
                            .is_dir()
                    {
                        let run = run_record(&entry.path())?;
                        let target = git(&id.worktree, &["rev-parse", "HEAD^{tree}"])?;
                        if run_tree(id, &run).is_ok_and(|tree| tree == target) {
                            runs.push((run.start, 0, entry.path()));
                        }
                    }
                }
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(refuse("run-unreadable", e)),
        }
    }
    runs.sort();
    runs.pop()
        .map(|(_, _, dir)| run_record(&dir).map(|run| (dir, run)))
        .transpose()
}

/// The round's own run, as the receipt would select it, where the
/// validation start's liveness reader answers it live. A start refuses to
/// run beside a live run, so the worktree holds at most one.
fn released_live_run(settings: &Settings, r: &RecoverRound) -> Result<Option<PathBuf>> {
    let Some((own, _)) = recovery_run(settings, &r.id)? else {
        return Ok(None);
    };
    Ok(files::live(&r.id.worktree)
        .map_err(|e| refuse("run-unreadable", e))?
        .map(|(dir, _)| dir)
        .filter(|dir| dir.file_name() == own.file_name()))
}

/// The worktree's unfinished runs ended by the validation entry's
/// `--stop --worktree` stop, before a replacement round is minted. The
/// started jobs of the item's own open stages are its stage loop's.
fn stop_worktree_runs(settings: &Settings, issue: &str, worktree: &Path, env: &Env) -> Result<()> {
    crate::validate::run::stop_worktree(settings, worktree, Some(issue), env, Locking::FLOCK)
        .map(|_| ())
        .map_err(|e| refuse("stop-failed", e))
}

pub fn recover(settings: &Settings, r: &RecoverRound, env: &Env) -> Result<Answer> {
    identity(&r.id)?;
    if let Some(file) = &r.transcript {
        let _ = text(file, "transcript-unreadable")?;
    }
    if let Some(answer) = reconcile_recovery(settings, r, env)? {
        return Ok(answer);
    }
    if r.directive_unconfirmed {
        return redelegate(settings, r, "directive-unconfirmed", env);
    }
    if let Some(dir) = released_live_run(settings, r)? {
        return Ok(Answer {
            value: json!({"state":"round-live","run_dir":dir}),
            text: format!("round-recover: round-live run-dir={}", dir.display()),
            status: 4,
        });
    }
    let Some(file) = &r.transcript else {
        return redelegate(settings, r, "no-transcript", env);
    };
    let Some(mut report) = transcript_report(&text(file, "transcript-unreadable")?, &r.id.round_id)
    else {
        return redelegate(settings, r, "no-report", env);
    };
    let validate = report_field(&report, "Validate").unwrap_or_default();
    let (validate, note) = if let Some(note) = validate
        .strip_prefix("no-verdict:")
        .map(str::trim)
        .filter(|s| nonempty(s))
    {
        ("no-verdict".to_owned(), Some(note.to_owned()))
    } else if validate == "pass" || validate.starts_with("FAILING:") {
        (validate.to_owned(), None)
    } else {
        return redelegate(
            settings,
            r,
            if validate.starts_with("no-verdict") {
                "validate-unproven"
            } else {
                "unparsed"
            },
            env,
        );
    };
    let head = git(&r.id.worktree, &["rev-parse", "HEAD"])?;
    let fix = fs::symlink_metadata(round_path(&r.id)).is_ok();
    let mut items = Vec::new();
    let mut qa = Vec::new();
    let branch;
    if fix {
        let round = round_record(&r.id)?;
        branch = git(&r.id.worktree, &["branch", "--show-current"])?;
        for line in report.lines() {
            let columns: Vec<_> = line.trim().split('|').map(str::trim).collect();
            if columns.len() == 5
                && columns[0].is_empty()
                && columns[4].is_empty()
                && columns[1].parse::<u64>().is_ok()
                && ["Applied", "Skipped", "Blocked"].contains(&columns[2])
                && nonempty(columns[3])
            {
                items.extend(columns[1..4].iter().map(|s| (*s).to_owned()));
            }
        }
        if items.is_empty() {
            return redelegate(settings, r, "unparsed", env);
        }
        let base = round["base_sha"].as_str().expect("round schema");
        let Some(commits) = report_field(&report, "Commits").filter(|s| nonempty(s)) else {
            return redelegate(settings, r, "unparsed", env);
        };
        let mut at_head = false;
        if commits == "none" {
            at_head = head == base;
        } else {
            for commit in commits
                .split([',', ' ', '\t'])
                .filter(|s| !s.is_empty())
                .map(|s| s.trim_matches('`'))
            {
                if !commit.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return redelegate(settings, r, "commit-mismatch", env);
                }
                let resolved = match git(
                    &r.id.worktree,
                    &[
                        "rev-parse",
                        "--verify",
                        "--quiet",
                        &format!("{commit}^{{commit}}"),
                    ],
                ) {
                    Ok(s) => s,
                    Err(_) => return redelegate(settings, r, "commit-mismatch", env),
                };
                if resolved == base
                    || !ancestor(&r.id.worktree, base, &resolved)?
                    || !ancestor(&r.id.worktree, &resolved, &head)?
                {
                    return redelegate(settings, r, "commit-mismatch", env);
                }
                at_head |= resolved == head;
            }
        }
        if !at_head {
            return redelegate(settings, r, "commit-mismatch", env);
        }
    } else {
        branch = report_field(&report, "Branch")
            .unwrap_or_default()
            .to_owned();
        let commit = report_field(&report, "Commit")
            .unwrap_or_default()
            .trim_matches('`');
        let Some(labels) = report_field(&report, "QA").filter(|s| nonempty(s)) else {
            return redelegate(settings, r, "unparsed", env);
        };
        if branch.is_empty() || commit.is_empty() {
            return redelegate(settings, r, "unparsed", env);
        }
        if !commit.bytes().all(|b| b.is_ascii_hexdigit())
            || git(
                &r.id.worktree,
                &[
                    "rev-parse",
                    "--verify",
                    "--quiet",
                    &format!("{commit}^{{commit}}"),
                ],
            )
            .ok()
            .as_deref()
                != Some(head.as_str())
        {
            return redelegate(settings, r, "commit-mismatch", env);
        }
        if labels != "none" {
            qa = labels
                .split([',', ' ', '\t'])
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect();
        }
    }
    let run = recovery_run(settings, &r.id)?;
    if !validate.starts_with("FAILING:")
        && run.as_ref().is_none_or(|(_, r)| {
            r.verdict != validate
                && !(r.mode == "ci" && r.verdict == "pending" && validate == "pass")
        })
    {
        return redelegate(settings, r, "validate-unproven", env);
    }
    if let Some(rule) =
        report_field(&report, "Proposed rule").filter(|s| nonempty(s) && *s != "none")
    {
        let suffix = format!("\n\n### Proposed Rules\n\n- {rule}\n");
        report.push_str(&suffix);
    }
    let report_path = r.id.worktree.join(format!(
        "tmp/round-recovered-{}-{}.md",
        r.id.issue, r.id.round_id
    ));
    write_report(&report_path, &report)?;
    let receipt = WriteReturn {
        id: Identity {
            worktree: r.id.worktree.clone(),
            issue: r.id.issue.clone(),
            round_id: r.id.round_id.clone(),
        },
        kind: if fix { "fix" } else { "implement" }.into(),
        branch,
        commit: head,
        validate,
        validate_note: note,
        validate_run_dir: run.map(|(dir, _)| dir),
        validate_record: None,
        summary: None,
        summary_file: None,
        recovered_text: Some(report_path),
        qa_label: qa,
        label: Vec::new(),
        no_labels: false,
        screenshot: Vec::new(),
        near_ceiling_base: None,
        bundled: false,
        no_summary: true,
        item: items,
        no_change: None,
    };
    let artifact = match write(settings, &receipt) {
        Ok(answer) => PathBuf::from(answer.text),
        Err(Error::Artifact {
            key: "labels-undeclared" | "mac-run-missing",
            ..
        }) => return redelegate(settings, r, "mac-run-unproven", env),
        Err(Error::Artifact {
            key: "missing-items" | "invalid-items",
            ..
        }) => return redelegate(settings, r, "unparsed", env),
        Err(error) => return Err(error),
    };
    let answer = check_once(
        settings,
        &CheckReturn {
            file: None,
            worktree: Some(r.id.worktree.clone()),
            issue: Some(r.id.issue.clone()),
            round_id: Some(r.id.round_id.clone()),
            expect_items: None,
            expect_items_from_round: fix,
            wait: 0,
            interval: 1,
        },
    )?;
    if answer.value["reason"] == "invalid" || answer.value["reason"] == "incomplete" {
        remove_unparsed(&artifact)?;
        return redelegate(settings, r, "unparsed", env);
    }
    Ok(Answer {
        value: json!({"state":"recovered","artifact":artifact}),
        text: format!("round-recover: recovered artifact={}", artifact.display()),
        status: 0,
    })
}

#[allow(
    clippy::disallowed_methods,
    reason = "the extracted report is an atomic artifact beside the receipt that consumes it"
)]
fn write_report(path: &Path, report: &str) -> Result<()> {
    fs::create_dir_all(
        path.parent()
            .ok_or_else(|| refuse("artifact-write", path.display()))?,
    )
    .map_err(|e| refuse("artifact-write", e))?;
    let scratch = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&scratch)
        .map_err(|e| refuse("artifact-write", e))?;
    let result = file
        .write_all(report.as_bytes())
        .and_then(|()| file.sync_all())
        .and_then(|()| fs::rename(&scratch, path));
    if let Err(e) = fs::remove_file(&scratch)
        && e.kind() != ErrorKind::NotFound
    {
        return Err(refuse("artifact-cleanup", e));
    }
    result.map_err(|e| refuse("artifact-write", e))
}

#[allow(
    clippy::disallowed_methods,
    reason = "recovery removes only the receipt its own write produced when its report cannot close the delegated items"
)]
fn remove_unparsed(path: &Path) -> Result<()> {
    fs::remove_file(path).map_err(|e| refuse("artifact-write", e))
}
