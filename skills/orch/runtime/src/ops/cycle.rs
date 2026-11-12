//! A closed lane's merge cycle against its class target (`cycle`), the record
//! the close transition writes on the lane when it confirms, and the
//! fleet's per-class rollup of those records.
//!
//! The record reads the merged pull request's stamps from the github skill's
//! `pr-timeline`, or a direct push's commit and the push that reached the
//! base branch from GitHub's activity log; the merged diff's class from the
//! merge-group producer's evidence ([`ci_proof::merged`]), over the merge
//! commit's first parent to the merge commit, from the project checkout; and
//! the round counts and stages from the lane's own workflow state, live, the
//! copy the merge saved, or the archive its host close kept. An unread class
//! records null with its cause and the verdict `unclassified`; an unread
//! state records null rounds with `rounds-unread`. The cycle line is the
//! fleet log's `cycle` row, byte for byte, and the third counting miss on
//! one phase among the fleet's records adds the `repeat-miss` line.

use agent_runtime::record;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host;
use serde_json::{Map, Value, json};

use super::Delivery;
use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::state::{self, CycleRow, FleetState, Lane};
use crate::verify::{Answer, ci_proof};
use crate::watch::hosted::{self, Answer as HostAnswer};

/// The class bases, lane-controlled seconds; only the recorded waits, a
/// clean final-head CI run and the merge group are forgiven.
pub const TARGETS: [(&str, i64); 5] = [
    ("render", 300),
    ("trivial", 300),
    ("micro", 1200),
    ("small", 1800),
    ("standard", 5400),
];

/// The bound on one read the record makes.
const BOUND: Duration = Duration::from_secs(300);
const TAG: &str = "cycle";

fn target_of(class: &str) -> Option<i64> {
    TARGETS.iter().find(|(c, _)| *c == class).map(|(_, s)| *s)
}

fn refused(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

/// An ISO 8601 UTC stamp's epoch second, as jq's `fromdate` reads it.
fn epoch(value: &Value) -> Option<i64> {
    value
        .as_str()
        .and_then(clock::epoch_secs)
        .and_then(|e| i64::try_from(e).ok())
}

fn num(value: &Value) -> Option<i64> {
    value.as_i64()
}

/// A negative interval measures nothing.
fn interval(value: &Value) -> Value {
    match value.as_f64() {
        Some(n) if n < 0.0 => Value::Null,
        _ => value.clone(),
    }
}

/// The record a close writes for `delivery`, with the lines it prints, or the
/// refusal, which holds the close until a disposal gives the record up.
pub fn recorded(
    settings: &Settings,
    gh: &Path,
    fleet: &Path,
    lane: &Lane,
    delivery: &Delivery,
    now: u64,
) -> std::result::Result<CycleRow, String> {
    record(settings, gh, fleet, lane, delivery, now).map_err(|e| e.to_string())
}

/// The cycle of `lane` for `delivery`, its line and, where it makes the third
/// counting miss on its phase, the repeat-miss line.
pub fn record(
    settings: &Settings,
    gh: &Path,
    fleet: &Path,
    lane: &Lane,
    delivery: &Delivery,
    now: u64,
) -> Result<CycleRow> {
    let item = lane.item.as_str();
    let (tier, tier_note) = launch_tier(lane);
    let repo = match delivery {
        Delivery::Pr { repo: Some(r), .. } => Some(r.clone()),
        Delivery::Pr { repo: None, .. } | Delivery::Commit { .. } => lane.repo.clone(),
    };
    let checkout = settings.roots.project.clone();
    let state = item_state(settings, fleet, lane, pr_of(delivery));
    let (rounds, stages, mut notes) = match &state {
        Ok(Some(doc)) => (
            rounds_of(doc),
            doc.get("stages").cloned().unwrap_or(Value::Null),
            Vec::new(),
        ),
        Ok(None) => (Value::Null, Value::Null, Vec::new()),
        Err(tried) => (
            Value::Null,
            Value::Null,
            vec![
                format!("oversee-cycle: rounds-unread item={item}"),
                tried.clone(),
            ],
        ),
    };
    notes.extend(tier_note);
    let (timeline, merge) = match delivery {
        Delivery::Pr { pr, .. } => {
            let timeline = pr_timeline(settings, *pr, repo.as_deref())?;
            let merge = timeline
                .get("merge_commit")
                .and_then(Value::as_str)
                .filter(|m| !m.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| refused("not-merged", &[("pr", &pr.to_string())]))?;
            (timeline, merge)
        }
        Delivery::Commit { commit } => {
            let resolved = git(
                &checkout,
                &[
                    "rev-parse",
                    "--verify",
                    "--end-of-options",
                    &format!("{commit}^{{commit}}"),
                ],
            )
            .map_err(|_| refused("commit-unreadable", &[("commit", commit)]))?;
            let authored = git(&checkout, &["show", "-s", "--format=%at", &resolved, "--"])
                .map_err(|_| refused("commit-unreadable", &[("commit", &resolved)]))?;
            let authored: i64 = authored
                .trim()
                .parse()
                .map_err(|_| refused("commit-unreadable", &[("commit", &resolved)]))?;
            let merged = match push_time(
                settings,
                gh,
                lane,
                &checkout,
                repo.as_deref(),
                &resolved,
                now,
            ) {
                Ok(at) => Value::from(at),
                Err(cause) => {
                    notes.push(format!(
                        "oversee-cycle: merged-unread commit={resolved} cause={cause}"
                    ));
                    Value::Null
                }
            };
            let timeline = json!({
                "commit": resolved,
                "stamps": {"first_commit": iso(authored), "merged": merged},
            });
            (timeline, resolved)
        }
    };
    let class = classify(gh, lane, &checkout, repo.as_deref(), &merge);
    let escaped = match (class.class.as_deref(), tier.as_deref()) {
        (Some(merged), Some(launched)) => super::tier::escaped(
            &super::tier::arm_cli(&settings.scope_paths_cli),
            launched,
            merged,
            &checkout,
        ),
        _ => None,
    };
    let pauses = waits_of(lane, state.as_ref().ok().and_then(Option::as_ref))?;
    notes.extend(negative_notes(item, &timeline));
    let cycle = compute(&Inputs {
        lane,
        timeline: &timeline,
        rounds,
        stages,
        pauses: &pauses,
        class: &class,
        tier: tier.as_deref(),
        escaped,
    });
    let line = line_of(item, &cycle);
    let mut lines = vec![line];
    if let Some(cause) = &class.cause {
        notes.push(format!("oversee-cycle: class-unread cause={cause}"));
    }
    if let Some(repeat) = repeat_miss(fleet, lane, &cycle)? {
        lines.push(repeat);
    }
    Ok(CycleRow {
        cycle,
        lines,
        notes,
    })
}

/// The tier the launch recorded, and the warning a record carries that
/// was written before launches recorded one.
fn launch_tier(lane: &Lane) -> (Option<String>, Option<String>) {
    match lane.extra.get("tier") {
        Some(Value::String(t)) if !t.is_empty() => (Some(t.clone()), None),
        Some(_) => (None, None),
        None => (
            None,
            Some(format!(
                "oversee-cycle: launch-tier-missing item={}",
                lane.item
            )),
        ),
    }
}

/// A `negative-interval` line for each timeline round whose seconds read
/// negative, as pr-timeline gives a head whose first check suite postdates
/// its review; the cycle records those seconds null.
fn negative_notes(item: &str, timeline: &Value) -> Vec<String> {
    timeline
        .get("rounds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|round| {
            round
                .get("secs")
                .and_then(Value::as_f64)
                .is_some_and(|s| s < 0.0)
        })
        .map(|round| {
            format!(
                "oversee-cycle: negative-interval item={item} kind={} head={} secs={}",
                text(round.get("kind")),
                text(round.get("head")),
                text(round.get("secs"))
            )
        })
        .collect()
}

fn pr_of(delivery: &Delivery) -> Option<u64> {
    match delivery {
        Delivery::Pr { pr, .. } => Some(*pr),
        Delivery::Commit { .. } => None,
    }
}

fn iso(epoch: i64) -> String {
    clock::iso_utc(u64::try_from(epoch).unwrap_or_default())
}

/// A value as jq's `tostring` prints it: a string as is, anything else as
/// its JSON.
fn text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
        None => "null".to_owned(),
    }
}

/// `n`: null as `-`, anything else as `tostring`.
fn n(value: &Value) -> String {
    match value {
        Value::Null => "-".to_owned(),
        other => text(Some(other)),
    }
}

/// The local round counts of a lane's workflow state.
fn rounds_of(doc: &Map<String, Value>) -> Value {
    let int = |v: Option<&Value>| v.and_then(Value::as_i64).unwrap_or(0);
    let first_panel = doc
        .get("first_panel")
        .is_some_and(|v| !matches!(v, Value::Null | Value::Bool(false)));
    json!({
        "review": i64::from(first_panel) + int(doc.get("rereview_cycles")),
        "fix": int(doc.get("cycles")),
        "bot": int(doc.get("pr_comment_review").and_then(|o| o.get("iterations"))),
        "full_validations": doc
            .get("validate_rounds")
            .and_then(Value::as_array)
            .map_or(0, |rounds| rounds.iter().filter(|r| r.get("mode").and_then(Value::as_str) == Some("full")).count()),
    })
}

// --- the lane's state ---------------------------------------------------------

/// The lane's workflow state for the cycle: under its item key, then
/// `pr-N` for the merged pull request; after the live state's removal, the
/// copy the merge saved for that pull request alone
/// (`<clone>/tmp/cycle-state/workflow-state-pr-N.json`); for a hosted lane,
/// on its host in the state directory its own settings name, the copy in
/// the clone its `.git` names or, the worktree gone, in the clone the watch
/// kept ([`hosted::retained_clone`]), then the archive the fleet log's last
/// `kept=` row since its session began names ([`kept_state`]).
/// `Ok(None)` is a kind whose files nothing reads (a cloud session); `Err`
/// names the paths tried.
fn item_state(
    settings: &Settings,
    fleet: &Path,
    lane: &Lane,
    pr: Option<u64>,
) -> std::result::Result<Option<Map<String, Value>>, String> {
    let item = lane.item.as_str();
    let mut keys = vec![item.to_owned()];
    if let Some(pr) = pr {
        keys.push(format!("pr-{pr}"));
    }
    let mut tried = Vec::new();
    let parse = |text: &str| match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(doc)) => Some(doc),
        Ok(_) | Err(_) => None,
    };
    if lane.kind.as_deref() == Some(super::CLOUD_KIND) {
        return Ok(None);
    }
    let hosted = lane.host.as_deref().is_some_and(|h| !h.is_empty());
    if hosted {
        let scripts = crate::watch::overseer::scripts_dir(&settings.roots.project);
        let root = lane.mail_root.as_deref().unwrap_or("");
        let fetch = |path: &Path| match hosted::fetch(
            &scripts,
            hosted::host_of(lane),
            item,
            &path.display().to_string(),
        ) {
            HostAnswer::Live(text) => parse(&text),
            HostAnswer::Gone | HostAnswer::Unreadable { .. } => None,
        };
        let clone = match hosted::configured_state_dir(&scripts, lane, root) {
            Ok(Some((dir, clone))) => {
                for key in &keys {
                    let path = state::item_path(&dir, key);
                    tried.push(path.display().to_string());
                    if let Some(doc) = fetch(&path) {
                        return Ok(Some(doc));
                    }
                }
                Some(clone)
            }
            // The merge's close-out removes the worktree after it saves the
            // state in the clone, so the clone a pass read stands for it.
            Ok(None) => {
                tried.push(format!("{root}/.git"));
                hosted::retained_clone(fleet, item).unwrap_or_else(|cause| {
                    tried.push(format!("{} cause={cause}", hosted::CLONE_ROW));
                    None
                })
            }
            Err(cause) => {
                tried.push(format!("{root}/.git cause={cause}"));
                None
            }
        };
        if let (Some(pr), Some(clone)) = (pr, clone) {
            let saved = clone.join(format!("tmp/cycle-state/workflow-state-pr-{pr}.json"));
            tried.push(saved.display().to_string());
            if let Some(doc) = fetch(&saved) {
                return Ok(Some(doc));
            }
        }
        if let Some(doc) = kept_state(fleet, lane, pr, &mut tried) {
            return Ok(Some(doc));
        }
        return Err(tried_line(item, &tried));
    }
    for key in &keys {
        let path = state::item_path(&settings.state_dir, key);
        tried.push(path.display().to_string());
        if let Ok(text) = read_text(&path)
            && let Some(doc) = parse(&text)
        {
            return Ok(Some(doc));
        }
    }
    if let Some(pr) = pr {
        let clone = lane
            .mail_root
            .as_deref()
            // A root that does not read as a directory, absent or
            // unreadable, leaves the read to the project's own clone,
            // which holds every lane's refs.
            .filter(|r| std::fs::metadata(r).is_ok_and(|m| m.is_dir()))
            .and_then(|r| {
                git(
                    Path::new(r),
                    &["rev-parse", "--path-format=absolute", "--git-common-dir"],
                )
                .ok()
            })
            .and_then(|common| PathBuf::from(common.trim()).parent().map(Path::to_path_buf))
            .unwrap_or_else(|| settings.roots.common.clone());
        let saved = clone.join(format!("tmp/cycle-state/workflow-state-pr-{pr}.json"));
        tried.push(saved.display().to_string());
        if let Ok(text) = read_text(&saved)
            && let Some(doc) = parse(&text)
        {
            return Ok(Some(doc));
        }
    }
    Err(tried_line(item, &tried))
}

fn tried_line(item: &str, tried: &[String]) -> String {
    tried
        .iter()
        .map(|p| format!("lane-gitfile: state-tried item={item} path={p}"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[allow(
    clippy::disallowed_methods,
    reason = "the cycle record's read of the lane's own state file, a read it acts on nothing by"
)]
fn read_text(path: &Path) -> std::io::Result<String> {
    std::fs::read_to_string(path)
}

/// The state member of the archive the fleet log's last `kept=PATH` row for
/// the item since its session began names: the member its `lane-host-state`
/// member names; where that is the empty line a close writes once no live
/// state remained, the copy the merge `pr` saved, never another merge's;
/// where the archive holds no such member, as a close writes it from a clone
/// whose state cannot be resolved, the member named for the item, then the
/// one named for the merge. Among several copies the clone's comes before
/// the worktree's, then name order, and the first that reads as an object
/// answers: a file archived twice is a hard-link entry the second time,
/// which `tar -O` prints empty, so a marker naming one reads its link's
/// target.
#[allow(
    clippy::disallowed_methods,
    reason = "the cycle record's reads of a kept archive through tar and the one runner, streamed"
)]
fn kept_state(
    fleet: &Path,
    lane: &Lane,
    pr: Option<u64>,
    tried: &mut Vec<String>,
) -> Option<Map<String, Value>> {
    let since = lane
        .session_since
        .clone()
        .or_else(|| lane.launched_at.clone())
        .unwrap_or_default();
    let snapshot = state::load(fleet).ok().flatten()?;
    let kept = snapshot
        .doc
        .get("fleet_log")
        .and_then(Value::as_array)?
        .iter()
        .filter(|row| row.get("item").and_then(Value::as_str) == Some(lane.item.as_str()))
        .filter(|row| row.get("at").and_then(Value::as_str).unwrap_or("") >= since.as_str())
        .filter_map(|row| row.get("text").and_then(Value::as_str))
        .filter_map(|t| {
            let at = t.find("kept=/")?;
            let before_ok = at == 0 || t[..at].ends_with(char::is_whitespace);
            before_ok.then(|| t[at + 5..].trim_end().to_owned())
        })
        .next_back()?;
    tried.push(kept.clone());
    let tar = |args: &[&str]| -> Option<String> {
        let out = host::run_tagged(TAG, "tar", Path::new("tar"), "kept", args, BOUND).ok()?;
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let member = |name: &str| tar(&["-xzOf", &kept, name]);
    let doc = |text: &str| match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(map)) => Some(map),
        Ok(_) | Err(_) => None,
    };
    let object = |name: &str| doc(&member(name)?);
    // The marker holds the member's raw name, which no listing need match.
    let marker = member("lane-host-state");
    if let Some(name) = marker.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        let text = member(name)?;
        if !text.is_empty() {
            return doc(&text);
        }
        // A file archived under two paths is a hard-link entry the second
        // time, which `tar -O` prints empty; its listing line names the
        // member that holds the bytes.
        let line = listed_name(tar(&["-tvzf", &kept, name])?.lines().next()?);
        let (_, target) = line.split_once(&format!(" {name} link to "))?;
        return object(target);
    }
    let listing = tar(&["-tzf", &kept])?;
    let names: Vec<String> = listing.lines().map(listed_name).collect();
    let worktree = format!(
        "{}/",
        lane.mail_root
            .as_deref()
            .unwrap_or("")
            .trim_start_matches('/')
    );
    let copies = |matches: &dyn Fn(&str) -> bool| {
        let mut found: Vec<&str> = names
            .iter()
            .map(String::as_str)
            .filter(|name| matches(name))
            .collect();
        found.sort_by_key(|name| (name.starts_with(&worktree), *name));
        found
    };
    let candidates: Vec<&str> = if names.iter().any(|name| name == "lane-host-state") {
        // Listed and not read: the archive answers nothing for it.
        marker.as_ref()?;
        let suffix = format!("/tmp/cycle-state/workflow-state-pr-{}.json", pr?);
        copies(&|name| name.ends_with(&suffix))
    } else {
        let mut keyed = vec![format!("workflow-state-{}.json", lane.item)];
        keyed.extend(pr.map(|pr| format!("workflow-state-pr-{pr}.json")));
        keyed
            .iter()
            .flat_map(|file| copies(&|name| name.rsplit('/').next() == Some(file.as_str())))
            .collect()
    };
    candidates.into_iter().find_map(object)
}

/// A member's raw name from a `tar -t` line. GNU tar's listing under the C
/// locale escapes a backslash and every byte it cannot print (`\\`,
/// `\303\251`, `\n`), where bsdtar lists the name raw; decoding the escapes
/// reads both, a raw name changing only where it holds a backslash.
fn listed_name(line: &str) -> String {
    let bytes = line.as_bytes();
    let mut raw = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let escape = (bytes[i] == b'\\')
            .then(|| bytes.get(i + 1).copied())
            .flatten();
        let octal = bytes.get(i + 1..i + 4).filter(|digits| {
            (b'0'..=b'3').contains(&digits[0]) && digits.iter().all(|d| (b'0'..=b'7').contains(d))
        });
        match (escape, octal) {
            (Some(_), Some(digits)) => {
                let value = digits.iter().fold(0u32, |n, d| n * 8 + u32::from(d - b'0'));
                raw.push(u8::try_from(value).unwrap_or(u8::MAX));
                i += 4;
            }
            (Some(letter), None) => {
                match letter {
                    b'\\' => raw.push(b'\\'),
                    b'a' => raw.push(0x07),
                    b'b' => raw.push(0x08),
                    b'f' => raw.push(0x0c),
                    b'n' => raw.push(b'\n'),
                    b'r' => raw.push(b'\r'),
                    b't' => raw.push(b'\t'),
                    b'v' => raw.push(0x0b),
                    other => raw.extend([b'\\', other]),
                }
                i += 2;
            }
            (None, _) => {
                raw.push(bytes[i]);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&raw).into_owned()
}

// --- the reads --------------------------------------------------------------------

/// A read's git: the C locale under the user's own configuration, which
/// holds the `safe.directory` and URL rewrites a lane's checkout reads under,
/// with the one setting that changes a read's answer pinned off:
/// `log.showSignature` prints a signed commit's verification ahead of the
/// `show --format=%at` line the authored time is parsed from.
const GIT_READ_ENV: [(&str, &str); 4] = [
    ("LC_ALL", "C"),
    ("GIT_CONFIG_COUNT", "1"),
    ("GIT_CONFIG_KEY_0", "log.showSignature"),
    ("GIT_CONFIG_VALUE_0", "false"),
];

fn git(cwd: &Path, args: &[&str]) -> std::result::Result<String, String> {
    let env: Vec<(&str, &std::ffi::OsStr)> = GIT_READ_ENV
        .iter()
        .map(|(name, value)| (*name, std::ffi::OsStr::new(*value)))
        .collect();
    git_in(cwd, args, &env)
}

/// The merge commit fetched from origin under the operator's configuration,
/// which holds the credentials a fetch needs.
fn git_fetch(cwd: &Path, merge: &str) -> std::result::Result<String, String> {
    git_in(cwd, &["fetch", "-q", "origin", merge], &[])
}

#[allow(
    clippy::disallowed_methods,
    reason = "the cycle record's git reads of the project checkout and its one fetch through the one runner"
)]
fn git_in(
    cwd: &Path,
    args: &[&str],
    env: &[(&str, &std::ffi::OsStr)],
) -> std::result::Result<String, String> {
    let out = host::run_tagged_in(
        TAG,
        "git",
        Path::new("git"),
        "git",
        args,
        host::Place {
            cwd: Some(cwd),
            env,
        },
        BOUND,
    )
    .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(host::stdout_text(&out))
    } else {
        Err(host::stderr_text(&out))
    }
}

/// The github skill's `pr-timeline PR [--repo R]`, its JSON.
#[allow(
    clippy::disallowed_methods,
    reason = "the cycle record's one run of the github skill's timeline reader through the one runner"
)]
fn pr_timeline(settings: &Settings, pr: u64, repo: Option<&str>) -> Result<Value> {
    let cli = settings
        .roots
        .project
        .join(".agents/skills/github/scripts/github.sh");
    let number = pr.to_string();
    let mut args = vec!["pr-timeline", number.as_str()];
    if let Some(repo) = repo {
        args.extend(["--repo", repo]);
    }
    let failed = |cause: &str| refused("timeline-failed", &[("pr", &number), ("cause", cause)]);
    // The router selects from the token it inherits first: the watch's
    // renewed sign-in where one stands.
    let credential = crate::watch::github::renewed_credential();
    let env = crate::watch::github::credential_env(&credential);
    let out = host::run_tagged_in(
        TAG,
        "github",
        &cli,
        "pr-timeline",
        &args,
        host::Place {
            cwd: Some(&settings.roots.project),
            env: &env,
        },
        BOUND,
    )
    .map_err(|e| failed(&e.to_string()))?;
    if !out.status.success() {
        return Err(failed(host::stderr_text(&out).lines().next().unwrap_or("")));
    }
    serde_json::from_slice(&out.stdout).map_err(|e| failed(&e.to_string()))
}

/// The class the classifier's merged reader gives, or the cause it is
/// unread by, with the reader's reason word and evidence.
struct Class {
    class: Option<String>,
    cause: Option<String>,
    reason: Option<String>,
    evidence: String,
}

impl Class {
    fn unread(cause: &str) -> Class {
        Class {
            class: None,
            cause: Some(cause.to_owned()),
            reason: None,
            evidence: String::new(),
        }
    }
}

/// The checkout's repository: gh's answer for the checkout, else its origin
/// remote's github.com slug.
fn checkout_repo(gh: &Path, checkout: &Path) -> Option<String> {
    let gh = crate::watch::github::handle(gh).in_dir(checkout);
    if let Ok(Answer::Printed { stdout, .. }) = gh.run(
        "cycle-repo",
        &[
            "repo",
            "view",
            "--json",
            "nameWithOwner",
            "-q",
            ".nameWithOwner",
        ],
        None,
    ) {
        let repo = String::from_utf8_lossy(&stdout).trim().to_owned();
        if !repo.is_empty() {
            return Some(repo);
        }
    }
    git(checkout, &["remote", "get-url", "origin"])
        .ok()
        .and_then(|url| super::origin_slug(&url))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the cycle record's read of whether a local lane's recorded root stands as a directory, which decides whose origin the checkout is judged against"
)]
fn classify(gh: &Path, lane: &Lane, checkout: &Path, repo: Option<&str>, merge: &str) -> Class {
    if git(checkout, &["rev-parse", "--show-toplevel"]).is_err() {
        return Class::unread("checkout-absent");
    }
    // A checkout provably not of the lane's repository: a local lane's
    // worktree names another origin, or the repository the timeline was
    // read from is not the checkout's.
    let local_root = lane
        .mail_root
        .as_deref()
        .filter(|r| lane.host.as_deref().is_none_or(str::is_empty) && Path::new(r).is_dir());
    let other = match local_root {
        Some(root) => match (
            git(checkout, &["config", "--get", "remote.origin.url"]),
            git(Path::new(root), &["config", "--get", "remote.origin.url"]),
        ) {
            (Ok(mine), Ok(theirs)) => mine.trim() != theirs.trim(),
            _ => false,
        },
        None => match (repo, checkout_repo(gh, checkout)) {
            (Some(repo), Some(mine)) => !mine.eq_ignore_ascii_case(repo),
            _ => false,
        },
    };
    if other {
        return Class::unread("checkout-other-repo");
    }
    let parent = format!("{merge}^1^{{commit}}");
    let base = match git(checkout, &["rev-parse", "--verify", "-q", &parent]) {
        Ok(base) => base,
        Err(_) => match git_fetch(checkout, merge)
            .and_then(|_| git(checkout, &["rev-parse", "--verify", "-q", &parent]))
        {
            Ok(base) => base,
            Err(_) => return Class::unread("merge-commit-absent"),
        },
    };
    let Some(evidence_repo) = checkout_repo(gh, checkout) else {
        return Class::unread("repo-unresolved");
    };
    class_of(ci_proof::merged_class(
        gh,
        checkout,
        base.trim(),
        merge,
        &evidence_repo,
    ))
}

/// The merged evidence as a class: the reader's refusal kept as the cycle's
/// cause, never overridden; a measured class with its reason word, the
/// cause the producer named, and its evidence.
fn class_of(read: std::result::Result<ci_proof::Measured, ci_proof::Refusal>) -> Class {
    match read {
        Ok(measured) => Class {
            class: Some(measured.class),
            cause: None,
            reason: Some(measured.cause),
            evidence: measured.evidence,
        },
        Err(refusal) => Class::unread(refusal.cause()),
    }
}

/// When a direct push's commit reached the base branch, from GitHub's own
/// record of the push: the push whose `after` is the commit, else the
/// earliest push from the lane's launch on whose `after` contains it, read
/// over the shortest period GitHub filters by that holds the launch, an
/// hour of clock skew spared. `Err` is the cause word.
#[allow(
    clippy::disallowed_methods,
    reason = "the cycle record's one run of the base-branch resolver through the one runner"
)]
fn push_time(
    settings: &Settings,
    gh: &Path,
    lane: &Lane,
    checkout: &Path,
    repo: Option<&str>,
    commit: &str,
    now: u64,
) -> std::result::Result<String, &'static str> {
    let repo = match repo {
        Some(repo) => repo.to_owned(),
        None => checkout_repo(gh, checkout).ok_or("repo-unresolved")?,
    };
    let resolver =
        crate::watch::overseer::scripts_dir(&settings.roots.project).join("resolve-base-branch");
    let checkout_arg = checkout.display().to_string();
    let base = host::run_tagged(
        TAG,
        "resolve-base-branch",
        &resolver,
        "base",
        &[&checkout_arg],
        BOUND,
    )
    .ok()
    .filter(|out| out.status.success())
    .map(|out| host::stdout_text(&out))
    .filter(|b| !b.is_empty())
    .ok_or("base-unresolved")?;
    let launched = match &lane.launched_at {
        Some(at) => Some(epoch(&Value::from(at.as_str())).ok_or("launch-unreadable")?),
        None => None,
    };
    let now = i64::try_from(now).unwrap_or(i64::MAX);
    let mut query = format!(
        "ref={}&activity_type=push&per_page=100",
        encode(&format!("refs/heads/{base}"))
    );
    if let Some(launched) = launched {
        for (name, span) in [
            ("day", 86_400),
            ("week", 604_800),
            ("month", 2_419_200),
            ("quarter", 7_689_600),
            ("year", 31_536_000),
        ] {
            if now - launched + 3600 < span {
                query.push_str(&format!("&time_period={name}"));
                break;
            }
        }
    }
    let gh = crate::watch::github::handle(gh);
    let pushes: Vec<Value> = gh
        .list("activity", &format!("repos/{repo}/activity?{query}"))
        .map_err(|_| "activity-unread")?
        .ok_or("activity-unread")?;
    let mut rows: Vec<(String, String)> = pushes
        .iter()
        .filter_map(|p| {
            Some((
                p.get("timestamp")?.as_str()?.to_owned(),
                p.get("after")?.as_str()?.to_owned(),
            ))
        })
        .collect();
    rows.sort_by(|a, b| a.0.cmp(&b.0));
    if let Some((at, _)) = rows.iter().find(|(_, after)| after == commit) {
        return Ok(at.clone());
    }
    for (at, after) in &rows {
        if epoch(&Value::from(at.as_str())).unwrap_or(i64::MIN) < launched.unwrap_or(0) {
            continue;
        }
        let compare: Option<Value> = gh
            .object(
                "compare",
                &format!("repos/{repo}/compare/{commit}...{after}"),
            )
            .map_err(|_| "compare-failed")?;
        if compare
            .as_ref()
            .and_then(|c| c.get("status"))
            .and_then(Value::as_str)
            == Some("ahead")
        {
            return Ok(at.clone());
        }
    }
    Err("no-push")
}

/// jq's `@uri`: every byte outside the unreserved set percent-encoded.
fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// The lane's waits as epoch spans: the lane record's pauses (parks, walls
/// and relaunches held for capacity) with a standing one, and the merge holds its workflow
/// state records (`record-pr-progress`'s `merge-asked` to `merge-answered`).
/// A span with no end runs on past the gap, so it ends where the cycle
/// does; a pause that does not read refuses. A state that does not read
/// holds no hold.
fn waits_of(lane: &Lane, state: Option<&Map<String, Value>>) -> Result<Vec<(i64, Option<i64>)>> {
    let mut spans = pauses_of(lane)?;
    spans.extend(spans_of(lane, state.and_then(|s| s.get("pauses")))?);
    Ok(spans)
}

/// The `{from, to}` spans of a `pauses` array.
fn spans_of(lane: &Lane, pauses: Option<&Value>) -> Result<Vec<(i64, Option<i64>)>> {
    let unreadable = || refused("pauses-unreadable", &[("item", &lane.item)]);
    let mut spans = Vec::new();
    match pauses {
        None | Some(Value::Null) => {}
        Some(Value::Array(pauses)) => {
            for pause in pauses {
                let from =
                    epoch(pause.get("from").unwrap_or(&Value::Null)).ok_or_else(unreadable)?;
                let to = match pause.get("to") {
                    None | Some(Value::Null) => None,
                    Some(v) => Some(epoch(v).ok_or_else(unreadable)?),
                };
                spans.push((from, to));
            }
        }
        Some(_) => return Err(unreadable()),
    }
    Ok(spans)
}

/// The lane record's pauses and a standing park, wall or wait for a slot
/// (`capacity_wait`, stamped by a relaunch refused for capacity).
fn pauses_of(lane: &Lane) -> Result<Vec<(i64, Option<i64>)>> {
    let unreadable = || refused("pauses-unreadable", &[("item", &lane.item)]);
    let mut spans = spans_of(lane, lane.extra.get("pauses"))?;
    for key in ["parked", "walled", "capacity_wait"] {
        if let Some(at) = lane
            .extra
            .get(key)
            .and_then(|v| v.get("at"))
            .filter(|v| !v.is_null())
        {
            spans.push((epoch(at).ok_or_else(unreadable)?, None));
        }
    }
    Ok(spans)
}

// --- the computation -------------------------------------------------------------

struct Inputs<'a> {
    lane: &'a Lane,
    timeline: &'a Value,
    rounds: Value,
    stages: Value,
    pauses: &'a [(i64, Option<i64>)],
    class: &'a Class,
    tier: Option<&'a str>,
    /// Whether the class is wider than the tier, as change-scope's arm
    /// answers it (`tier::escaped`); `None` where either is unread.
    escaped: Option<bool>,
}

/// The seconds of `[from, to]` the spans cover, overlaps counted once.
fn covered(spans: &[(i64, Option<i64>)], from: i64, to: i64) -> i64 {
    let mut clipped: Vec<(i64, i64)> = spans
        .iter()
        .map(|(a, b)| (*a.max(&from), b.unwrap_or(to).min(to)))
        .filter(|(a, b)| b > a)
        .collect();
    clipped.sort_by_key(|(a, _)| *a);
    let mut union: Vec<(i64, i64)> = Vec::new();
    for (a, b) in clipped {
        match union.last_mut() {
            Some(last) if a <= last.1 => last.1 = last.1.max(b),
            Some(_) | None => union.push((a, b)),
        }
    }
    union.iter().map(|(a, b)| b - a).sum()
}

/// The gate waits of the gap `from..to`: an instant a pause covers is
/// paused; before ready, any other is draft; after ready, the latest push
/// or bot review sets the wait, bot_wait where neither came yet. A push
/// and a bot review in one second read the push first.
fn gate_waits(t: &Value, pauses: &[(i64, Option<i64>)], from: i64, to: i64) -> Value {
    let ready = t
        .get("ready_times")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(epoch)
        .filter(|r| *r <= to)
        .max();
    let times = |key: &str| -> Vec<i64> {
        t.get(key)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(epoch)
            .collect()
    };
    let mut events: Vec<(i64, &str)> = times("push_times")
        .into_iter()
        .map(|at| (at, "bot_wait"))
        .chain(
            times("bot_review_times")
                .into_iter()
                .map(|at| (at, "thread_fix")),
        )
        .chain(ready.map(|r| (r, "bot_wait")))
        .collect();
    events.sort();
    let first = events
        .iter()
        .rfind(|(at, _)| *at <= from)
        .map_or("bot_wait", |(_, w)| *w);
    let mut points: Vec<(i64, &str)> = vec![(from, first)];
    points.extend(
        events
            .iter()
            .filter(|(at, _)| *at > from && *at < to)
            .copied(),
    );
    points.push((to, ""));
    let mut sums: BTreeMap<&str, i64> = BTreeMap::new();
    for pair in points.windows(2) {
        let (start, wait) = pair[0];
        let (end, _) = pair[1];
        let wait = match ready {
            Some(r) if start < r => "draft",
            Some(_) | None => wait,
        };
        *sums.entry(wait).or_default() += (end - start) - covered(pauses, start, end);
    }
    json!({
        "bot_wait": sums.get("bot_wait").copied().unwrap_or(0),
        "draft": sums.get("draft").copied().unwrap_or(0),
        "thread_fix": sums.get("thread_fix").copied().unwrap_or(0),
        "paused": covered(pauses, from, to),
    })
}

fn compute(input: &Inputs) -> Value {
    let t = input.timeline;
    let s = t.get("stamps").cloned().unwrap_or(Value::Null);
    let stamp = |key: &str| s.get(key).cloned().unwrap_or(Value::Null);
    let launched = input
        .lane
        .launched_at
        .clone()
        .map_or(Value::Null, Value::from);
    let armed = match stamp("armed") {
        Value::Null => stamp("queued"),
        armed => armed,
    };
    let stamps: Vec<(&str, Value)> = vec![
        ("launched", launched),
        ("first_commit", stamp("first_commit")),
        ("pr_opened", stamp("created")),
        ("gate_green", stamp("gate_met")),
        ("ci_green", stamp("ci_green")),
        ("armed", armed),
        ("merged", stamp("merged")),
    ];
    let get = |key: &str| t.get(key).cloned().unwrap_or(Value::Null);
    let merge_group = get("ci_merge_group_secs");
    let ci_head = get("ci_head_secs");
    let ci_clean = get("ci_head_clean_secs");
    let mg = num(&merge_group).unwrap_or(0);
    let cc = num(&ci_clean).unwrap_or(0);
    let stamp_at = |key: &str| {
        stamps
            .iter()
            .find(|(k, _)| *k == key)
            .and_then(|(_, v)| epoch(v))
    };
    let window = stamp_at("launched").zip(stamp_at("merged"));
    let actual = window.map(|(l, m)| m - l);
    // A recorded wait is no lane time: it comes off the lane's time and
    // widens the target as the forgiven CI does, so neither it nor a miss
    // it explains counts toward the repeat bar.
    let waited = window.map(|(l, m)| covered(input.pauses, l, m));
    let wt = waited.unwrap_or(0);
    let class = input.class.class.as_deref();
    let base = class.and_then(target_of);
    let target = base.map(|b| b + mg + cc + wt);
    let lane_secs = actual.map(|a| a - mg - cc - wt);
    let missing: Vec<&str> = stamps
        .iter()
        .filter(|(_, v)| v.is_null())
        .map(|(k, _)| *k)
        .collect();
    let seq: Option<Vec<(&str, i64)>> = if missing.iter().any(|m| *m != "armed") {
        None
    } else {
        let o = stamp_at("launched").unwrap_or_default();
        let m = stamp_at("merged").unwrap_or_default();
        let within: Vec<(&str, i64)> = stamps
            .iter()
            .filter_map(|(k, v)| epoch(v).map(|at| (*k, at)))
            .filter(|(_, at)| *at >= o && *at <= m)
            .collect();
        let green = within
            .iter()
            .filter(|(k, _)| *k == "ci_green" || *k == "gate_green")
            .map(|(_, at)| *at)
            .max();
        let mut kept: Vec<(&str, i64)> = within
            .into_iter()
            .filter(|(k, at)| *k != "armed" || green.is_none_or(|g| *at > g))
            .collect();
        kept.sort_by_key(|(_, at)| *at);
        Some(kept)
    };
    let dominant = seq.as_ref().and_then(|seq| {
        let mut gaps: Vec<(&str, i64)> = seq
            .windows(2)
            .map(|w| {
                let mut secs = w[1].1 - w[0].1 - covered(input.pauses, w[0].1, w[1].1);
                match w[1].0 {
                    "merged" => secs = (secs - mg).max(0),
                    "ci_green" => secs = (secs - cc).max(0),
                    _ => {}
                }
                (w[1].0, secs)
            })
            .collect();
        gaps.sort_by_key(|(_, secs)| -secs);
        gaps.first().copied()
    });
    let position = |name: &str| {
        seq.as_ref()
            .and_then(|seq| seq.iter().position(|(k, _)| *k == name))
    };
    let waits = match (position("gate_green"), t.get("push_times")) {
        (Some(gate), Some(push)) if gate > 0 && !push.is_null() => {
            let seq = seq
                .as_ref()
                .unwrap_or_else(|| unreachable!("a position is in the sequence"));
            gate_waits(t, input.pauses, seq[gate - 1].1, seq[gate].1)
        }
        _ => Value::Null,
    };
    let ci_cause = match (
        position("ci_green"),
        epoch(&stamp("last_push")),
        t.get("ci_head_spans"),
    ) {
        (Some(ci), Some(push), Some(spans)) if ci > 0 && !spans.is_null() => {
            let seq = seq
                .as_ref()
                .unwrap_or_else(|| unreachable!("a position is in the sequence"));
            let (from, to) = (seq[ci - 1].1, seq[ci].1);
            if push > to {
                Value::Null
            } else {
                let last = push.max(from);
                let spans: Vec<(i64, Option<i64>)> = spans
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|span| {
                        Some((epoch(span.get("start")?)?, Some(epoch(span.get("end")?)?)))
                    })
                    .collect();
                let running = covered(&spans, last, to);
                let work = (push - from).max(0);
                let checks = (running - cc).max(0);
                let wait = to - last - running;
                json!(if work >= checks && work >= wait {
                    "work"
                } else if checks > wait {
                    "ci"
                } else {
                    "wait"
                })
            }
        }
        _ => Value::Null,
    };
    let phase = dominant.map(|(p, _)| p);
    let miss = matches!((lane_secs, base), (Some(secs), Some(base)) if secs > base);
    let cause = match phase {
        Some("gate_green") if !waits.is_null() => {
            let order = ["bot_wait", "draft", "thread_fix", "paused"];
            let mut best = (order[0], i64::MIN);
            for key in order {
                let value = waits.get(key).and_then(Value::as_i64).unwrap_or(0);
                if value > best.1 {
                    best = (key, value);
                }
            }
            json!(best.0)
        }
        Some("ci_green") => ci_cause,
        Some("merged") if miss => {
            let seq = seq
                .as_ref()
                .unwrap_or_else(|| unreachable!("a phase is in the sequence"));
            let (from, to) = (seq[seq.len() - 2].1, seq[seq.len() - 1].1);
            let paused = covered(input.pauses, from, to);
            let rest = (to - from - paused - mg).max(0);
            if paused > 0 && paused >= mg && paused >= rest {
                json!("paused")
            } else if mg > 0 && mg >= rest {
                json!("merge_group")
            } else {
                t.pointer("/merge_decision/route")
                    .cloned()
                    .unwrap_or(Value::Null)
            }
        }
        Some(_) | None => Value::Null,
    };
    let verdict = match (class, lane_secs) {
        (None, _) => "unclassified",
        (Some(_), None) => "unmeasured",
        (Some(_), Some(_)) if miss => "miss",
        (Some(_), Some(_)) => "met",
    };
    let cause = if verdict == "miss" {
        match (&cause, phase) {
            (Value::Null, Some(p)) => json!(p),
            (Value::Null, None) => json!("unread"),
            (cause, _) => cause.clone(),
        }
    } else {
        cause
    };
    let escaped = input.escaped.map_or(Value::Null, Value::Bool);
    let reason = input.class.reason.clone().unwrap_or_default();
    let escape_cause = if escaped != json!(true) {
        Value::Null
    } else if reason == "several-subsystems"
        || input.class.evidence.starts_with("path=")
        || input.class.evidence.contains(" path=")
    {
        json!("path-miss")
    } else if reason.starts_with("production-") {
        json!("estimate-miss")
    } else {
        Value::Null
    };
    let refixed = match (
        stamp("first_gate_met").as_str(),
        stamp("last_push").as_str(),
    ) {
        (Some(gate), Some(push)) => json!(push > gate),
        _ => Value::Null,
    };
    let ready = t
        .get("ready_times")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|r| !r.is_null())
        .filter_map(|r| r.as_str().map(str::to_owned))
        .min()
        .map_or(Value::Null, Value::from);
    let mut stamp_map = Map::new();
    for (k, v) in &stamps {
        stamp_map.insert((*k).to_owned(), v.clone());
    }
    stamp_map.insert("ready".to_owned(), ready);
    let mut cycle = Map::new();
    match t.get("commit") {
        Some(commit) if !commit.is_null() => cycle.insert("commit".to_owned(), commit.clone()),
        Some(_) | None => cycle.insert("pr".to_owned(), get("pr")),
    };
    let opt = |v: Option<String>| v.map_or(Value::Null, Value::from);
    let lane = |key: &str| input.lane.extra.get(key).cloned().unwrap_or(Value::Null);
    cycle.insert("class".to_owned(), opt(class.map(str::to_owned)));
    cycle.insert("class_cause".to_owned(), opt(input.class.cause.clone()));
    cycle.insert(
        "class_reason".to_owned(),
        opt(input.class.reason.clone().filter(|r| !r.is_empty())),
    );
    cycle.insert("tier_inputs".to_owned(), lane("tier_inputs"));
    cycle.insert("tier".to_owned(), opt(input.tier.map(str::to_owned)));
    cycle.insert("stamps".to_owned(), Value::Object(stamp_map));
    cycle.insert("target".to_owned(), target.map_or(Value::Null, Value::from));
    cycle.insert("merge_group".to_owned(), merge_group);
    cycle.insert("ci_head".to_owned(), ci_head);
    cycle.insert("ci_clean".to_owned(), ci_clean);
    cycle.insert("waited".to_owned(), waited.map_or(Value::Null, Value::from));
    cycle.insert(
        "lane_secs".to_owned(),
        lane_secs.map_or(Value::Null, Value::from),
    );
    cycle.insert("actual".to_owned(), actual.map_or(Value::Null, Value::from));
    cycle.insert("open".to_owned(), get("open_secs"));
    cycle.insert("verdict".to_owned(), json!(verdict));
    cycle.insert("phase".to_owned(), opt(phase.map(str::to_owned)));
    cycle.insert(
        "phase_secs".to_owned(),
        dominant.map_or(Value::Null, |(_, s)| Value::from(s)),
    );
    cycle.insert("gate_waits".to_owned(), waits);
    cycle.insert("cause".to_owned(), cause);
    cycle.insert("missing".to_owned(), json!(missing));
    cycle.insert("rounds".to_owned(), input.rounds.clone());
    cycle.insert("stages".to_owned(), input.stages.clone());
    cycle.insert("obligation".to_owned(), lane("obligation"));
    cycle.insert(
        "pr_rounds".to_owned(),
        match t.get("rounds") {
            Some(Value::Array(rounds)) => Value::Array(
                rounds
                    .iter()
                    .map(|r| {
                        let mut r = r.clone();
                        if let Some(secs) = r.get("secs").cloned() {
                            r["secs"] = interval(&secs);
                        }
                        r
                    })
                    .collect(),
            ),
            Some(_) | None => Value::Null,
        },
    );
    cycle.insert("escaped".to_owned(), escaped);
    cycle.insert("refixed".to_owned(), refixed);
    cycle.insert("escape_cause".to_owned(), escape_cause);
    Value::Object(cycle)
}

/// The cycle line, the fleet log's `cycle` row as printed.
pub fn line_of(item: &str, c: &Value) -> String {
    let g = |key: &str| c.get(key).cloned().unwrap_or(Value::Null);
    let w = |key: &str| {
        c.pointer(&format!("/gate_waits/{key}"))
            .cloned()
            .unwrap_or(Value::Null)
    };
    let r = |key: &str| {
        c.pointer(&format!("/rounds/{key}"))
            .cloned()
            .unwrap_or(Value::Null)
    };
    let delivery = match c.get("commit") {
        Some(commit) if !commit.is_null() => format!("commit={}", text(Some(commit))),
        Some(_) | None => format!("pr={}", text(c.get("pr"))),
    };
    let missing = match c.get("missing").and_then(Value::as_array) {
        Some(m) if !m.is_empty() => m
            .iter()
            .map(|v| text(Some(v)))
            .collect::<Vec<_>>()
            .join(","),
        Some(_) | None => "-".to_owned(),
    };
    let pr_rounds = match c.get("pr_rounds").and_then(Value::as_array) {
        Some(rounds) => rounds
            .iter()
            .filter(|r| r.get("kind").and_then(Value::as_str) == Some("review"))
            .count()
            .to_string(),
        None => "-".to_owned(),
    };
    format!(
        "cycle item={item} {delivery} class={} tier={} target={} merge_group={} ci_head={} ci_clean={} waited={} lane={} actual={} open={} verdict={} phase={} phase_secs={} cause={} bot_wait={} draft={} thread_fix={} paused={} missing={missing} review={} fix={} bot={} full_validations={} pr_rounds={pr_rounds} escaped={} tier_inputs={} class_reason={} escape_cause={} refixed={}",
        n(&g("class")),
        n(&g("tier")),
        n(&g("target")),
        n(&g("merge_group")),
        n(&g("ci_head")),
        n(&g("ci_clean")),
        n(&g("waited")),
        n(&g("lane_secs")),
        n(&g("actual")),
        n(&g("open")),
        text(c.get("verdict")),
        n(&g("phase")),
        n(&g("phase_secs")),
        n(&g("cause")),
        n(&w("bot_wait")),
        n(&w("draft")),
        n(&w("thread_fix")),
        n(&w("paused")),
        n(&r("review")),
        n(&r("fix")),
        n(&r("bot")),
        n(&r("full_validations")),
        n(&g("escaped")),
        n(&g("tier_inputs")),
        n(&g("class_reason")),
        n(&g("escape_cause")),
        n(&g("refixed")),
    )
}

/// A miss that counts toward the repeat bar: a ci_green miss only where its
/// cause is ci.
fn counts(cycle: &Value) -> bool {
    cycle.get("verdict").and_then(Value::as_str) == Some("miss")
        && (cycle.get("phase").and_then(Value::as_str) != Some("ci_green")
            || cycle.get("cause").and_then(Value::as_str) == Some("ci"))
}

/// A miss's cause, falling back to its phase, then `unread`.
fn miss_cause(cycle: &Value) -> String {
    [cycle.get("cause"), cycle.get("phase")]
        .into_iter()
        .flatten()
        .find_map(|v| v.as_str().map(str::to_owned))
        .unwrap_or_else(|| "unread".to_owned())
}

/// The bar fires on the record that makes the third counting miss on one
/// phase: one that already counted on that phase, recorded again, makes
/// nothing new.
fn repeat_miss(fleet: &Path, lane: &Lane, cycle: &Value) -> Result<Option<String>> {
    let Some(phase) = cycle.get("phase").and_then(Value::as_str) else {
        return Ok(None);
    };
    let prior = lane.extra.get("cycle").cloned().unwrap_or(Value::Null);
    if !counts(cycle)
        || (counts(&prior) && prior.get("phase").and_then(Value::as_str) == Some(phase))
    {
        return Ok(None);
    }
    let lanes = load_lanes(fleet)?;
    let misses: Vec<(String, Value)> = lanes
        .iter()
        .map(|l| {
            let c = if l.item == lane.item {
                cycle.clone()
            } else {
                l.extra.get("cycle").cloned().unwrap_or(Value::Null)
            };
            (l.item.clone(), c)
        })
        .filter(|(_, c)| counts(c) && c.get("phase").and_then(Value::as_str) == Some(phase))
        .collect();
    if misses.len() != 3 {
        return Ok(None);
    }
    Ok(Some(format!(
        "repeat-miss phase={phase} items={} causes={}",
        misses
            .iter()
            .map(|(i, _)| i.as_str())
            .collect::<Vec<_>>()
            .join(","),
        misses
            .iter()
            .map(|(_, c)| miss_cause(c))
            .collect::<Vec<_>>()
            .join(",")
    )))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the cycle's read of the fleet's records, a snapshot the repeat bar and the rollup judge"
)]
fn load_lanes(fleet: &Path) -> Result<Vec<Lane>> {
    Ok(state::load(fleet)?
        .map(|snapshot| snapshot.view::<FleetState>(fleet))
        .transpose()?
        .map(|f| f.lanes)
        .unwrap_or_default())
}

// --- the stages ------------------------------------------------------------------------

/// `cycle stages ITEM`: a running lane's stages without a cycle, from the
/// item key, then the pull request its record waits on, then that pull
/// request's saved copy; each `stage item= kind= round_id= start= end=|-`
/// line sorted by start, `superseded=1` and `reason=` where the stage
/// carries them.
pub fn stages(settings: &Settings, fleet: &Path, item: &str) -> Result<Vec<String>> {
    let lanes = load_lanes(fleet)?;
    let lane = lanes
        .iter()
        .find(|l| l.item == item)
        .ok_or_else(|| refused("record-missing", &[("item", item)]))?;
    let pr = ["pending_pr", "parked"].iter().find_map(|k| {
        lane.extra
            .get(*k)
            .and_then(|v| v.get("pr"))
            .and_then(Value::as_u64)
    });
    let doc = match item_state(settings, fleet, lane, pr) {
        Ok(Some(doc)) => doc,
        Ok(None) | Err(_) => {
            return Err(refused(
                "stages-unread",
                &[("item", item), ("cause", "no-state")],
            ));
        }
    };
    let mut rows: Vec<Value> = doc
        .get("stages")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    rows.sort_by_key(|r| r.get("start").and_then(Value::as_i64).unwrap_or(i64::MIN));
    Ok(rows.iter().map(|r| stage_line(item, r, true)).collect())
}

fn stage_line(item: &str, r: &Value, extras: bool) -> String {
    let end = match r.get("end") {
        None | Some(Value::Null) => "-".to_owned(),
        Some(e) => text(Some(e)),
    };
    let mut line = format!(
        "stage item={item} kind={} round_id={} start={} end={end}",
        text(r.get("kind")),
        text(r.get("round_id")),
        text(r.get("start"))
    );
    if extras {
        if r.get("superseded") == Some(&Value::Bool(true)) {
            line.push_str(" superseded=1");
        }
        if let Some(reason) = r.get("reason").filter(|v| !v.is_null()) {
            line.push_str(&format!(" reason={}", text(Some(reason))));
        }
    }
    line
}

// --- the rollup -----------------------------------------------------------------------

/// The fleet's per-class rollup rows, one per class with a record, in the
/// target table's order, then `unclassified`; `report` adds each recorded
/// stage's row. No fleet state prints nothing.
pub fn rollup(fleet: &Path, with_stages: bool) -> Result<Vec<String>> {
    let lanes = load_lanes(fleet)?;
    let cycles: Vec<(&str, &Value)> = lanes
        .iter()
        .filter_map(|l| {
            l.extra
                .get("cycle")
                .filter(|c| !c.is_null())
                .map(|c| (l.item.as_str(), c))
        })
        .collect();
    let mut rows = Vec::new();
    let classes = TARGETS.iter().map(|(c, _)| *c).chain(["unclassified"]);
    for class in classes {
        let c: Vec<&Value> = cycles
            .iter()
            .map(|(_, c)| *c)
            .filter(|c| {
                c.get("class")
                    .and_then(Value::as_str)
                    .unwrap_or("unclassified")
                    == class
            })
            .collect();
        if c.is_empty() {
            continue;
        }
        rows.push(rollup_row(class, &c));
    }
    if with_stages {
        for (item, cycle) in &cycles {
            for stage in cycle
                .get("stages")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                rows.push(stage_line(item, stage, false));
            }
        }
    }
    Ok(rows)
}

/// `cycle rollup`: the rollup rows, each appended to the fleet log as a
/// `cycle` row under its class through the store's one log route, which
/// stamps it and holds it to the row cap; the route reads its row from a
/// file, written beside the fleet record and removed after the write.
#[allow(
    clippy::disallowed_methods,
    reason = "the rollup row's file beside the fleet record, the store's log route input, removed after its write"
)]
pub fn rollup_logged(
    fleet: &Path,
    locking: record::Locking,
    store: &crate::settings::StoreSettings,
    env: &agent_runtime::journal::Env,
) -> Result<Vec<String>> {
    let lines = rollup(fleet, false)?;
    let file = fleet.with_file_name(format!(".cycle-rollup.{}.json", std::process::id()));
    for line in &lines {
        let class = line
            .strip_prefix("rollup class=")
            .and_then(|rest| rest.split(' ').next())
            .unwrap_or("unclassified");
        let row = json!({"kind": "cycle", "item": class, "text": line});
        std::fs::write(&file, row.to_string()).map_err(|e| {
            refused(
                "fleet-log-failed",
                &[
                    ("file", &file.display().to_string()),
                    ("cause", &e.to_string()),
                ],
            )
        })?;
        let written = super::store::run_write(
            fleet,
            locking,
            store,
            env,
            &super::store::Write::LogAppend { file: file.clone() },
        );
        let _ = std::fs::remove_file(&file);
        written?;
    }
    Ok(lines)
}

/// Nearest rank of the sorted values at fraction `p`, `-` for none.
fn nearest(mut values: Vec<f64>, p: f64) -> String {
    if values.is_empty() {
        return "-".to_owned();
    }
    values.sort_by(f64::total_cmp);
    let rank = (values.len() as f64 * p).ceil() as usize;
    let v = values[rank.saturating_sub(1)];
    text(Some(&json!(v))).trim_end_matches(".0").to_owned()
}

fn rollup_row(class: &str, c: &[&Value]) -> String {
    let measured = |key: &str| -> Vec<f64> {
        c.iter()
            .filter_map(|r| r.get(key))
            .map(interval)
            .filter_map(|v| v.as_f64())
            .collect()
    };
    let target = target_of(class);
    let lane = measured("lane_secs");
    let miss_share = match target {
        Some(t) if !lane.is_empty() => format!(
            "{}/{}",
            lane.iter().filter(|s| **s > t as f64).count(),
            lane.len()
        ),
        Some(_) | None => "-".to_owned(),
    };
    let count = |f: &dyn Fn(&Value) -> bool| c.iter().filter(|r| f(r)).count();
    let drafts: Vec<i64> = c
        .iter()
        .filter_map(|r| r.pointer("/gate_waits/draft").and_then(Value::as_i64))
        .collect();
    let draft = if drafts.is_empty() {
        "-".to_owned()
    } else {
        drafts.iter().sum::<i64>().to_string()
    };
    let with_rounds: Vec<&Value> = c
        .iter()
        .filter_map(|r| r.get("rounds").filter(|v| !v.is_null()))
        .collect();
    let sum = |key: &str| -> String {
        if with_rounds.is_empty() {
            return "-".to_owned();
        }
        with_rounds
            .iter()
            .filter_map(|r| r.get(key).and_then(Value::as_i64))
            .sum::<i64>()
            .to_string()
    };
    let pr_rounds: Vec<&Vec<Value>> = c
        .iter()
        .filter_map(|r| r.get("pr_rounds").and_then(Value::as_array))
        .collect();
    let review_counts: Vec<f64> = pr_rounds
        .iter()
        .map(|rounds| {
            rounds
                .iter()
                .filter(|r| r.get("kind").and_then(Value::as_str) == Some("review"))
                .count() as f64
        })
        .collect();
    let secs_of = |kind: &str| -> Vec<f64> {
        pr_rounds
            .iter()
            .flat_map(|rounds| rounds.iter())
            .filter(|r| r.get("kind").and_then(Value::as_str) == Some(kind))
            .filter_map(|r| r.get("secs").map(interval))
            .filter_map(|v| v.as_f64())
            .collect()
    };
    let untimed = pr_rounds
        .iter()
        .flat_map(|rounds| rounds.iter())
        .filter(|r| r.get("secs").map(interval).is_none_or(|v| v.is_null()))
        .count();
    format!(
        "rollup class={class} items={} median={} p90={} lane_median={} open_median={} miss_share={miss_share} misses={} draft={draft} review={} fix={} bot={} full_validations={} rounds_unread={} escaped={} estimate_miss={} path_miss={} refixed={} pr_rounds={} pr_rounds_unread={} round_median={} fix_median={} rounds_untimed={untimed}",
        c.len(),
        nearest(measured("actual"), 0.5),
        nearest(measured("actual"), 0.9),
        nearest(lane, 0.5),
        nearest(measured("open"), 0.5),
        count(&|r| r.get("verdict").and_then(Value::as_str) == Some("miss")),
        sum("review"),
        sum("fix"),
        sum("bot"),
        sum("full_validations"),
        count(&|r| r.get("rounds").is_none_or(Value::is_null)),
        count(&|r| r.get("escaped") == Some(&Value::Bool(true))),
        count(&|r| r.get("escape_cause").and_then(Value::as_str) == Some("estimate-miss")),
        count(&|r| r.get("escape_cause").and_then(Value::as_str) == Some("path-miss")),
        count(&|r| r.get("refixed") == Some(&Value::Bool(true))),
        nearest(review_counts, 0.5),
        count(&|r| r.get("pr_rounds").is_none_or(Value::is_null)),
        nearest(secs_of("review"), 0.5),
        nearest(secs_of("fix"), 0.5),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The lane's launch, every stamp below seconds past it.
    const T0: i64 = 1_790_000_000;

    fn at(secs: i64) -> Value {
        Value::from(clock::iso_utc(u64::try_from(T0 + secs).unwrap()))
    }

    fn times(secs: &[i64]) -> Value {
        Value::Array(secs.iter().map(|s| at(*s)).collect())
    }

    /// pr-timeline's answer for PR 7: first commit 60, opened 120, the gate
    /// at 300, CI 360, armed 420, merged at `merged`, the first gate pass
    /// at `first_gate` and the one push at `push`.
    fn timeline(merged: i64, first_gate: i64, push: i64) -> Value {
        json!({"pr": 7, "merge_commit": "m1", "head": "h",
            "stamps": {"first_commit": at(60), "created": at(120), "last_push": at(push), "first_bot_review": null,
                "first_gate_met": at(first_gate), "gate_met": at(300), "ci_green": at(360), "armed": at(420),
                "queued": null, "merged": at(merged)},
            "ci_head_secs": 60, "ci_merge_group_secs": null, "open_secs": merged - 120, "bot_reviews": 0,
            "push_times": [at(push)], "bot_review_times": [], "rounds": []})
    }

    /// A gate_green gap from the opening at 120 to the gate at 3000, CI at
    /// 3060, armed at 3100; `pushes` None is a timeline whose push times are
    /// null.
    fn gate_timeline(pushes: Option<&[i64]>, reviews: &[i64], merged: i64) -> Value {
        json!({"pr": 7, "merge_commit": "m1", "open_secs": merged - 120,
            "stamps": {"first_commit": at(60), "created": at(120), "last_push": at(120), "first_gate_met": at(3000),
                "gate_met": at(3000), "ci_green": at(3060), "armed": at(3100), "queued": null, "merged": at(merged)},
            "push_times": pushes.map_or(Value::Null, times), "bot_review_times": times(reviews)})
    }

    /// A ci_green gap from the gate at 300 to CI green at 4000, armed 4100,
    /// merged 4200: the last push at `push`, the final head's check runs
    /// `spans`, its clean CI seconds `clean`.
    fn ci_timeline(push: Option<i64>, spans: Option<&[(i64, i64)]>, clean: Option<i64>) -> Value {
        let mut t = timeline(4200, 300, 110);
        t["ci_head_clean_secs"] = clean.map_or(Value::Null, Value::from);
        t["stamps"]["ci_green"] = at(4000);
        t["stamps"]["armed"] = at(4100);
        t["stamps"]["last_push"] = push.map_or(Value::Null, at);
        t["ci_head_spans"] = spans.map_or(Value::Null, |spans| {
            spans
                .iter()
                .map(|(a, b)| json!({"start": at(*a), "end": at(*b)}))
                .collect()
        });
        t
    }

    fn lane(item: &str, extra: Value) -> Lane {
        let mut record = json!({"item": item, "status": "done", "launched_at": at(0)});
        for (key, value) in extra.as_object().unwrap() {
            record[key] = value.clone();
        }
        serde_json::from_value(record).unwrap()
    }

    /// The lane record's walls as `pauses`, and a park standing since
    /// `parked`.
    fn paused(spans: &[(i64, i64)], parked: Option<i64>) -> Value {
        let mut extra = json!({"pauses": spans.iter()
            .map(|(a, b)| json!({"from": at(*a), "to": at(*b), "cause": "walled"}))
            .collect::<Vec<_>>()});
        if let Some(parked) = parked {
            extra["parked"] = json!({"at": at(parked)});
        }
        extra
    }

    /// The class the merged reader measured, its reason the evidence's
    /// first word.
    fn class(name: &str, evidence: &str) -> Class {
        Class {
            class: Some(name.to_owned()),
            cause: None,
            reason: evidence.split(' ').next().map(str::to_owned),
            evidence: evidence.to_owned(),
        }
    }

    /// The cycle, its escape read through the catalog's own launch arm.
    fn cycle(lane: &Lane, timeline: &Value, class: &Class, tier: Option<&str>) -> Value {
        let pauses = pauses_of(lane).unwrap();
        let arm = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../change-scope/scripts/change-scope");
        let escaped = match (class.class.as_deref(), tier) {
            (Some(merged), Some(launched)) => {
                super::super::tier::escaped(&arm, launched, merged, Path::new("."))
            }
            _ => None,
        };
        compute(&Inputs {
            lane,
            timeline,
            rounds: Value::Null,
            stages: Value::Null,
            pauses: &pauses,
            class,
            tier,
            escaped,
        })
    }

    /// The `NAME=value` words of the cycle line, in the order asked.
    fn fields(line: &str, names: &[&str]) -> String {
        names
            .iter()
            .map(|name| {
                let word = line
                    .split(' ')
                    .find(|w| w.starts_with(&format!("{name}=")))
                    .unwrap_or_else(|| panic!("{name} in {line}"));
                word.to_owned()
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn line(lane: &Lane, timeline: &Value, class: &Class, tier: Option<&str>) -> String {
        line_of(&lane.item, &cycle(lane, timeline, class, tier))
    }

    #[test]
    fn each_class_is_judged_against_its_own_target() {
        for (name, merged, tier, target, verdict, escaped) in [
            ("render", 301, "standard", 300, "miss", false),
            ("render", 300, "standard", 300, "met", false),
            ("trivial", 301, "standard", 300, "miss", false),
            ("trivial", 300, "standard", 300, "met", false),
            ("micro", 1201, "standard", 1200, "miss", false),
            ("micro", 1200, "micro", 1200, "met", false),
            ("small", 1801, "standard", 1800, "miss", false),
            ("small", 1800, "micro", 1800, "met", true),
            ("small", 1800, "small", 1800, "met", false),
            ("standard", 5401, "standard", 5400, "miss", false),
            ("standard", 5400, "micro", 5400, "met", true),
            ("standard", 5400, "small", 5400, "met", true),
        ] {
            let got = line(
                &lane("KEN-1", json!({})),
                &timeline(merged, 300, 110),
                &class(name, "stub"),
                Some(tier),
            );
            let head = got.split(" phase=").next().unwrap();
            assert_eq!(
                format!("{head} {}", fields(&got, &["escaped"])),
                format!(
                    "cycle item=KEN-1 pr=7 class={name} tier={tier} target={target} merge_group=- ci_head=60 ci_clean=- waited=0 lane={merged} actual={merged} open={} verdict={verdict} escaped={escaped}",
                    merged - 120
                ),
                "{name} at {merged} s, tier {tier}"
            );
        }
    }

    #[test]
    fn merge_group_ci_widens_the_target_and_comes_off_only_the_merged_gap() {
        for (name, merged, want, record) in [
            (
                "shipped target",
                1480,
                "target=1480 merge_group=280 verdict=met phase=merged phase_secs=580",
                json!([1480, 280, 1480, 1360, "merged", 580, {"bot_wait": 380, "draft": 0, "thread_fix": 0, "paused": 0}]),
            ),
            (
                "floor",
                200,
                "target=1480 merge_group=280 verdict=met phase=first_commit phase_secs=60",
                json!([1480, 280, 200, 80, "first_commit", 60, null]),
            ),
        ] {
            let mut t = timeline(merged, 300, 110);
            t["ci_merge_group_secs"] = json!(280);
            t["stamps"]["gate_met"] = at(500);
            t["stamps"]["ci_green"] = at(560);
            t["stamps"]["armed"] = at(620);
            let c = cycle(
                &lane("KEN-1", json!({})),
                &t,
                &class("micro", "stub"),
                Some("micro"),
            );
            let got = line_of("KEN-1", &c);
            assert_eq!(
                fields(
                    &got,
                    &["target", "merge_group", "verdict", "phase", "phase_secs"]
                ),
                want,
                "{name}"
            );
            assert_eq!(
                json!([
                    c["target"],
                    c["merge_group"],
                    c["actual"],
                    c["open"],
                    c["phase"],
                    c["phase_secs"],
                    c["gate_waits"]
                ]),
                record,
                "{name}"
            );
        }
    }

    #[test]
    fn the_cycle_line_carries_its_stamps_rounds_and_a_refix() {
        let pr_rounds = json!([{"kind": "review", "head": "a", "start": "s1", "end": "e1", "secs": 600},
            {"kind": "fix", "head": "a", "start": "e1", "end": "s2", "secs": 1200},
            {"kind": "review", "head": "b", "start": "s2", "end": "e2", "secs": 300}]);
        let state = json!({"first_panel": {"agents": ["a"]}, "rereview_cycles": 2, "cycles": 5,
            "pr_comment_review": {"iterations": 4},
            "validate_rounds": [{"mode": "full"}, {"mode": "range"}, {"mode": "full"}]});
        let mut t = timeline(1500, 300, 500);
        t["rounds"] = pr_rounds.clone();
        let lane = lane("KEN-2", json!({}));
        let c = compute(&Inputs {
            lane: &lane,
            timeline: &t,
            rounds: rounds_of(state.as_object().unwrap()),
            stages: Value::Null,
            pauses: &[],
            class: &class("micro", "stub"),
            tier: Some("micro"),
            escaped: Some(false),
        });
        assert_eq!(
            line_of("KEN-2", &c),
            "cycle item=KEN-2 pr=7 class=micro tier=micro target=1200 merge_group=- ci_head=60 ci_clean=- waited=0 lane=1500 actual=1500 open=1380 verdict=miss phase=merged phase_secs=1080 cause=merged bot_wait=180 draft=0 thread_fix=0 paused=0 missing=- review=3 fix=5 bot=4 full_validations=2 pr_rounds=2 escaped=false tier_inputs=- class_reason=stub escape_cause=- refixed=true"
        );
        assert_eq!(
            c["stamps"],
            json!({"launched": at(0), "first_commit": at(60), "pr_opened": at(120), "gate_green": at(300),
                "ci_green": at(360), "armed": at(420), "merged": at(1500), "ready": null})
        );
        assert_eq!(c["pr_rounds"], pr_rounds);
    }

    #[test]
    fn the_longest_gap_from_the_launch_names_the_phase_and_queued_stands_in_for_armed() {
        let t = json!({"pr": 7, "merge_commit": "m1",
            "stamps": {"first_commit": at(900), "created": at(960), "last_push": at(960), "first_gate_met": null,
                "gate_met": at(1000), "ci_green": at(1010), "armed": null, "queued": at(1000), "merged": at(1100)},
            "open_secs": 140, "push_times": [], "bot_review_times": []});
        assert_eq!(
            line(
                &lane("KEN-3", json!({})),
                &t,
                &class("small", "stub"),
                Some("micro")
            ),
            "cycle item=KEN-3 pr=7 class=small tier=micro target=1800 merge_group=- ci_head=- ci_clean=- waited=0 lane=1100 actual=1100 open=140 verdict=met phase=first_commit phase_secs=900 cause=- bot_wait=40 draft=0 thread_fix=0 paused=0 missing=- review=- fix=- bot=- full_validations=- pr_rounds=- escaped=true tier_inputs=- class_reason=stub escape_cause=- refixed=-"
        );
    }

    #[test]
    fn armed_time_starts_after_both_ci_and_the_gate_are_green() {
        for (name, ci, gate, armed, queued, phase, secs) in [
            (
                "arm before both",
                1700,
                1600,
                Some(1500),
                None,
                "gate_green",
                1480,
            ),
            (
                "arm before CI",
                1700,
                300,
                Some(1500),
                None,
                "ci_green",
                1400,
            ),
            (
                "arm before gate",
                300,
                1700,
                Some(1500),
                None,
                "gate_green",
                1400,
            ),
            (
                "arm at last green",
                1700,
                300,
                Some(1700),
                None,
                "ci_green",
                1400,
            ),
            ("arm after both", 300, 360, Some(1700), None, "armed", 1340),
            (
                "queue before CI",
                1700,
                300,
                None,
                Some(1500),
                "ci_green",
                1400,
            ),
            (
                "CI after merge",
                10000,
                300,
                Some(1500),
                None,
                "armed",
                1200,
            ),
            (
                "gate after merge",
                300,
                10000,
                Some(1500),
                None,
                "armed",
                1200,
            ),
            (
                "both green after merge",
                10000,
                11000,
                Some(1500),
                None,
                "armed",
                1380,
            ),
            ("CI before open", 100, 300, Some(1500), None, "armed", 1200),
            (
                "gate before open",
                300,
                100,
                Some(1500),
                None,
                "armed",
                1200,
            ),
            (
                "queue with CI after merge",
                10000,
                300,
                None,
                Some(1500),
                "armed",
                1200,
            ),
        ] {
            let mut t = timeline(1800, 300, 110);
            t["stamps"]["ci_green"] = at(ci);
            t["stamps"]["gate_met"] = at(gate);
            t["stamps"]["armed"] = armed.map_or(Value::Null, at);
            t["stamps"]["queued"] = queued.map_or(Value::Null, at);
            let c = cycle(
                &lane("KEN-1", json!({})),
                &t,
                &class("micro", "stub"),
                Some("micro"),
            );
            assert_eq!(
                json!([
                    c["phase"],
                    c["phase_secs"],
                    c["stamps"]["ci_green"],
                    c["stamps"]["gate_green"],
                    c["stamps"]["armed"]
                ]),
                json!([phase, secs, at(ci), at(gate), at(armed.or(queued).unwrap())]),
                "{name}"
            );
        }
    }

    #[test]
    fn a_missing_stamp_names_no_phase() {
        let mut gone_ci = timeline(1100, 300, 110);
        gone_ci["stamps"]["ci_green"] = Value::Null;
        gone_ci["stamps"]["armed"] = at(1010);
        let mut no_first = timeline(1100, 300, 110);
        no_first["stamps"]["first_commit"] = Value::Null;
        let mut no_open = timeline(1100, 300, 110);
        no_open["stamps"]["created"] = Value::Null;
        no_open["open_secs"] = Value::Null;
        for (name, extra, t, names, want) in [
            (
                "no CI green",
                json!({}),
                gone_ci,
                &["verdict", "phase", "phase_secs", "bot_wait", "missing"][..],
                "verdict=met phase=- phase_secs=- bot_wait=- missing=ci_green",
            ),
            (
                "no launch stamp",
                json!({"launched_at": null}),
                no_first,
                &["verdict", "actual", "open", "phase", "missing"][..],
                "verdict=unmeasured actual=- open=980 phase=- missing=launched,first_commit",
            ),
            (
                "no open stamp",
                json!({}),
                no_open,
                &["verdict", "open", "missing"][..],
                "verdict=met open=- missing=pr_opened",
            ),
        ] {
            let got = line(
                &lane("KEN-1", extra),
                &t,
                &class("small", "stub"),
                Some("standard"),
            );
            assert_eq!(fields(&got, names), want, "{name}");
        }
    }

    #[test]
    fn the_gate_green_phase_is_split_into_the_waits_it_holds() {
        let reviews: &[i64] = &[400, 1500, 2000];
        for (name, pushes, reviews, pauses, parked, merged, want) in [
            (
                "a push waits on a bot, a review on the lane, and a wall comes out of the wait it fell in",
                Some(&[100, 1400][..]),
                reviews,
                &[(600, 1000)][..],
                None,
                3200,
                "phase=gate_green cause=thread_fix bot_wait=380 draft=0 thread_fix=2100 paused=400",
            ),
            (
                "a wall over most of the gap is the cause",
                Some(&[100, 1400][..]),
                reviews,
                &[(400, 2900)][..],
                None,
                3200,
                "phase=gate_green cause=paused bot_wait=280 draft=0 thread_fix=100 paused=2500",
            ),
            (
                "overlapping pauses count once and a standing park runs to the gate",
                Some(&[100, 1400][..]),
                reviews,
                &[(2400, 2600)][..],
                Some(2500),
                3200,
                "phase=gate_green cause=thread_fix bot_wait=380 draft=0 thread_fix=1900 paused=600",
            ),
            (
                "a review before the gap opens it on the lane",
                Some(&[1400][..]),
                &[110, 1500][..],
                &[][..],
                None,
                3200,
                "phase=gate_green cause=thread_fix bot_wait=100 draft=0 thread_fix=2780 paused=0",
            ),
            (
                "no push and no review is all bot wait",
                Some(&[][..]),
                &[][..],
                &[][..],
                None,
                3200,
                "phase=gate_green cause=bot_wait bot_wait=2880 draft=0 thread_fix=0 paused=0",
            ),
            (
                "a fix pushed between two reviews and a rebase pushed after them are both bot waits",
                Some(&[900, 2500][..]),
                &[400, 2000][..],
                &[][..],
                None,
                3200,
                "phase=gate_green cause=bot_wait bot_wait=1880 draft=0 thread_fix=1000 paused=0",
            ),
            (
                "another phase is the miss's cause and keeps the split",
                Some(&[100, 1400][..]),
                reviews,
                &[][..],
                None,
                9000,
                "phase=merged cause=merged bot_wait=380 draft=0 thread_fix=2500 paused=0",
            ),
            (
                "null push times split nothing and leave the miss its phase",
                None,
                reviews,
                &[][..],
                None,
                3200,
                "phase=gate_green cause=gate_green bot_wait=- draft=- thread_fix=- paused=-",
            ),
        ] {
            let got = line(
                &lane("KEN-1", paused(pauses, parked)),
                &gate_timeline(pushes, reviews, merged),
                &class("micro", "stub"),
                Some("standard"),
            );
            assert_eq!(
                fields(
                    &got,
                    &[
                        "phase",
                        "cause",
                        "bot_wait",
                        "draft",
                        "thread_fix",
                        "paused"
                    ]
                ),
                want,
                "{name}"
            );
        }
        let mut admin = gate_timeline(Some(&[100, 1400]), reviews, 3200);
        admin["stamps"]["armed"] = Value::Null;
        assert_eq!(
            fields(
                &line(
                    &lane("KEN-1", json!({})),
                    &admin,
                    &class("micro", "stub"),
                    Some("standard")
                ),
                &[
                    "phase",
                    "cause",
                    "bot_wait",
                    "draft",
                    "thread_fix",
                    "missing"
                ]
            ),
            "phase=gate_green cause=thread_fix bot_wait=380 draft=0 thread_fix=2500 missing=armed",
            "an admin-route merge, never armed or queued, reads its waits from the stamps it has"
        );
    }

    #[test]
    fn a_wall_standing_at_the_merge_is_paused_time() {
        for (name, walled, pauses) in [
            ("open at merge", true, &[][..]),
            ("completed after merge", false, &[(400, 3600)][..]),
            ("completed overlapping open", true, &[(400, 3600)][..]),
        ] {
            let mut extra = paused(pauses, None);
            if walled {
                extra["walled"] = json!({"at": at(400)});
            }
            let c = cycle(
                &lane("KEN-1", extra),
                &gate_timeline(Some(&[]), &[], 3200),
                &class("micro", "stub"),
                Some("standard"),
            );
            assert_eq!(
                format!(
                    "{}|{}",
                    fields(&line_of("KEN-1", &c), &["bot_wait", "thread_fix", "paused"]),
                    c["gate_waits"]["paused"]
                ),
                "bot_wait=280 thread_fix=0 paused=2600|2600",
                "{name}"
            );
        }
    }

    #[test]
    fn a_draft_period_before_the_last_ready_is_draft_time() {
        let mut last = Value::Null;
        for (name, ready, pushes, reviews, want) in [
            (
                "fleet-1305",
                &[3317][..],
                &[100][..],
                &[3483][..],
                "draft=3197 bot_wait=166 thread_fix=0",
            ),
            (
                "never-draft",
                &[][..],
                &[100][..],
                &[3483][..],
                "draft=0 bot_wait=3363 thread_fix=0",
            ),
            (
                "last-ready-before-gate",
                &[200, 3317, 4000][..],
                &[100][..],
                &[3483][..],
                "draft=3197 bot_wait=166 thread_fix=0",
            ),
            (
                "push-after-ready",
                &[3317][..],
                &[100, 3400][..],
                &[3317, 3483][..],
                "draft=3197 bot_wait=83 thread_fix=83",
            ),
        ] {
            let mut t = gate_timeline(Some(pushes), reviews, 3683);
            t["ready_times"] = times(ready);
            t["stamps"]["gate_met"] = at(3483);
            t["stamps"]["ci_green"] = at(3543);
            t["stamps"]["armed"] = at(3583);
            let c = cycle(
                &lane("KEN-1", json!({})),
                &t,
                &class("micro", "stub"),
                Some("micro"),
            );
            assert_eq!(
                fields(&line_of("KEN-1", &c), &["draft", "bot_wait", "thread_fix"]),
                want,
                "{name}"
            );
            last = c;
        }
        assert_eq!(last["cause"], "draft", "draft work can cause the miss");
        assert!(
            rollup_row("micro", &[&last]).contains(" draft=3197 "),
            "the rollup counts draft seconds"
        );
    }

    #[test]
    fn the_first_ready_is_recorded_without_changing_the_phase() {
        for (name, ready, want, draft) in [
            ("draft-then-ready", json!([at(240)]), at(240), 120),
            (
                "repeated-ready-with-nulls",
                json!([null, at(240), at(180), null]),
                at(180),
                120,
            ),
            ("no-ready", json!([]), Value::Null, 0),
            ("only-null", json!([null]), Value::Null, 0),
        ] {
            let mut t = timeline(600, 300, 110);
            t["ready_times"] = ready;
            let c = cycle(
                &lane("KEN-1", json!({})),
                &t,
                &class("micro", "stub"),
                Some("micro"),
            );
            assert_eq!(c["stamps"]["ready"], want, "{name}");
            assert_eq!(
                json!([
                    c["stamps"]["pr_opened"],
                    c["phase"],
                    c["phase_secs"],
                    c["gate_waits"],
                    c["missing"]
                ]),
                json!([at(120), "gate_green", 180,
                    {"bot_wait": 180 - draft, "draft": draft, "thread_fix": 0, "paused": 0}, []]),
                "{name}"
            );
        }
    }

    #[test]
    fn the_ci_green_phase_names_the_larger_part_of_its_gap_as_its_cause() {
        for (name, push, spans, clean, cause) in [
            (
                "rounds pushed after the PR opened are work",
                Some(3500),
                Some(&[(3500, 4000)][..]),
                None,
                "work",
            ),
            (
                "one check run filling the gap after an early final push is ci",
                Some(400),
                Some(&[(400, 4000)][..]),
                None,
                "ci",
            ),
            (
                "a final push before the gap opened leaves the gap to the checks",
                Some(110),
                Some(&[(110, 4000)][..]),
                None,
                "ci",
            ),
            (
                "work wins a tie",
                Some(2150),
                Some(&[(2150, 4000)][..]),
                None,
                "work",
            ),
            (
                "two short runs with a long idle gap between them are wait",
                Some(400),
                Some(&[(400, 546), (3864, 4000)][..]),
                Some(136),
                "wait",
            ),
            (
                "ci and wait tie to wait",
                Some(300),
                Some(&[(300, 2150)][..]),
                None,
                "wait",
            ),
            (
                "a push after ci_green splits nothing and leaves the miss its phase",
                Some(4050),
                Some(&[(4050, 4100)][..]),
                None,
                "ci_green",
            ),
            (
                "no last push splits nothing",
                None,
                Some(&[(300, 4000)][..]),
                None,
                "ci_green",
            ),
            (
                "no check spans read splits nothing",
                Some(400),
                None,
                None,
                "ci_green",
            ),
        ] {
            let got = line(
                &lane("KEN-1", json!({})),
                &ci_timeline(push, spans, clean),
                &class("micro", "stub"),
                Some("micro"),
            );
            assert_eq!(
                fields(&got, &["verdict", "phase", "cause"]),
                format!("verdict=miss phase=ci_green cause={cause}"),
                "{name}"
            );
        }
        let mut forgiven = timeline(3500, 300, 110);
        forgiven["ci_head_clean_secs"] = json!(1800);
        forgiven["stamps"]["ci_green"] = at(2100);
        forgiven["stamps"]["armed"] = at(2200);
        assert_eq!(
            fields(
                &line(
                    &lane("KEN-1", json!({})),
                    &forgiven,
                    &class("micro", "stub"),
                    Some("micro")
                ),
                &["lane", "verdict", "phase", "phase_secs", "cause"]
            ),
            "lane=1700 verdict=miss phase=merged phase_secs=1300 cause=merged",
            "forgiven CI cannot set the phase"
        );
        assert_eq!(
            fields(
                &line(
                    &lane("KEN-1", json!({})),
                    &ci_timeline(Some(1400), Some(&[(1400, 4000)]), Some(1800)),
                    &class("micro", "stub"),
                    Some("micro")
                ),
                &["lane", "phase", "phase_secs", "cause"]
            ),
            "lane=2400 phase=ci_green phase_secs=1900 cause=work",
            "work exceeds the unforgiven final-head checks"
        );
    }

    /// A wait comes off the lane's time, so each pause case misses on the
    /// lane time the rest of its merge gap holds; the pause still names
    /// the gap it fills most of.
    #[test]
    fn a_merged_miss_names_the_pause_the_merge_group_or_the_route() {
        let admin = json!({"route": "admin", "cause": "queue-bypass-safe"});
        let queue = json!({"route": "queue", "cause": "queue-required"});
        let hold: &[(i64, i64)] = &[(500, 6700)];
        let clipped: &[(i64, i64)] = &[(0, 300), (400, 2000), (1500, 6700)];
        for (name, tier, group, pauses, parked, route, merged, phase_secs, want, gate_paused) in [
            (
                "standard CI",
                "standard",
                7000,
                &[][..],
                None,
                admin.clone(),
                12420,
                5000,
                "merge_group",
                0,
            ),
            (
                "small CI",
                "small",
                7000,
                &[][..],
                None,
                Value::Null,
                12420,
                5000,
                "merge_group",
                0,
            ),
            (
                "micro CI",
                "micro",
                7000,
                &[][..],
                None,
                Value::Null,
                12420,
                5000,
                "merge_group",
                0,
            ),
            (
                "standard hold",
                "standard",
                0,
                hold,
                None,
                queue.clone(),
                12420,
                5800,
                "paused",
                0,
            ),
            (
                "small hold",
                "small",
                0,
                hold,
                None,
                Value::Null,
                12420,
                5800,
                "paused",
                0,
            ),
            (
                "micro hold",
                "micro",
                0,
                hold,
                None,
                Value::Null,
                12420,
                5800,
                "paused",
                0,
            ),
            (
                "overlapping clipped holds",
                "standard",
                0,
                clipped,
                None,
                Value::Null,
                12420,
                5720,
                "paused",
                180,
            ),
            (
                "standing park",
                "standard",
                0,
                &[][..],
                Some(6220),
                Value::Null,
                12420,
                5800,
                "paused",
                0,
            ),
            (
                "CI ties remaining wait",
                "standard",
                6000,
                &[][..],
                None,
                Value::Null,
                12420,
                6000,
                "merge_group",
                0,
            ),
            (
                "pause ties CI",
                "standard",
                6000,
                &[(420, 6420)][..],
                None,
                Value::Null,
                17420,
                5000,
                "paused",
                0,
            ),
            (
                "queue decision",
                "standard",
                0,
                &[][..],
                None,
                queue.clone(),
                12420,
                12000,
                "queue",
                0,
            ),
            (
                "admin decision",
                "standard",
                0,
                &[][..],
                None,
                admin.clone(),
                12420,
                12000,
                "admin",
                0,
            ),
            (
                "missing decision",
                "standard",
                0,
                &[][..],
                None,
                Value::Null,
                12420,
                12000,
                "merged",
                0,
            ),
        ] {
            let mut t = timeline(merged, 300, 110);
            t["ci_merge_group_secs"] = json!(group);
            t["merge_decision"] = route;
            let c = cycle(
                &lane("KEN-1", paused(pauses, parked)),
                &t,
                &class("standard", "stub"),
                Some(tier),
            );
            assert_eq!(
                format!(
                    "{}|{}",
                    fields(
                        &line_of("KEN-1", &c),
                        &["verdict", "phase", "phase_secs", "cause", "paused"]
                    ),
                    c["cause"]
                ),
                format!(
                    "verdict=miss phase=merged phase_secs={phase_secs} cause={want} paused={gate_paused}|\"{want}\""
                ),
                "{name}"
            );
        }
    }

    #[test]
    fn a_miss_always_records_a_cause() {
        for (name, merged, ci, armed, want, stored) in [
            (
                "a miss with a stamp missing reads no phase and records unread",
                5000,
                false,
                true,
                "verdict=miss phase=- cause=unread",
                json!("unread"),
            ),
            (
                "a miss on the admin route, never armed or queued, reads its phase",
                5000,
                true,
                false,
                "verdict=miss phase=merged cause=merged",
                json!("merged"),
            ),
            (
                "a miss on merged records its phase",
                5000,
                true,
                true,
                "verdict=miss phase=merged cause=merged",
                json!("merged"),
            ),
            (
                "a met record names no cause",
                800,
                true,
                true,
                "verdict=met phase=merged cause=-",
                Value::Null,
            ),
        ] {
            let mut t = timeline(merged, 300, 110);
            if !ci {
                t["stamps"]["ci_green"] = Value::Null;
            }
            if !armed {
                t["stamps"]["armed"] = Value::Null;
            }
            let c = cycle(
                &lane("KEN-1", json!({})),
                &t,
                &class("micro", "stub"),
                Some("micro"),
            );
            assert_eq!(
                fields(&line_of("KEN-1", &c), &["verdict", "phase", "cause"]),
                want,
                "{name}"
            );
            assert_eq!(c["cause"], stored, "{name}");
        }
    }

    #[test]
    fn clean_final_head_ci_comes_off_the_lane_time() {
        for (name, head, clean, group, merged, launched, want, record) in [
            (
                "clean",
                Some(1394),
                Some(1394),
                Some(963),
                3557,
                true,
                "target=3557 ci_head=1394 ci_clean=1394 lane=1200 verdict=met",
                json!([3557, 1394, 1394, 1200, 3437]),
            ),
            (
                "rerun",
                Some(6736),
                Some(1400),
                Some(963),
                8899,
                true,
                "target=3563 ci_head=6736 ci_clean=1400 lane=6536 verdict=miss",
                json!([3563, 6736, 1400, 6536, 8779]),
            ),
            (
                "no-green",
                Some(1394),
                None,
                Some(963),
                3557,
                true,
                "target=2163 ci_head=1394 ci_clean=- lane=2594 verdict=miss",
                json!([2163, 1394, null, 2594, 3437]),
            ),
            (
                "no-group",
                Some(1394),
                Some(1394),
                None,
                2594,
                true,
                "target=2594 ci_head=1394 ci_clean=1394 lane=1200 verdict=met",
                json!([2594, 1394, 1394, 1200, 2474]),
            ),
            (
                "no-ci",
                None,
                None,
                None,
                1200,
                true,
                "target=1200 ci_head=- ci_clean=- lane=1200 verdict=met",
                json!([1200, null, null, 1200, 1080]),
            ),
            (
                "missing-launch",
                Some(1394),
                Some(1394),
                Some(963),
                3557,
                false,
                "target=3557 ci_head=1394 ci_clean=1394 lane=- verdict=unmeasured",
                json!([3557, 1394, 1394, null, 3437]),
            ),
        ] {
            let mut t = timeline(merged, 300, 110);
            t["ci_head_secs"] = head.map_or(Value::Null, Value::from);
            t["ci_head_clean_secs"] = clean.map_or(Value::Null, Value::from);
            t["ci_merge_group_secs"] = group.map_or(Value::Null, Value::from);
            let extra = if launched {
                json!({"tier": "micro"})
            } else {
                json!({"tier": "micro", "launched_at": null})
            };
            let lane = lane("KEN-1", extra);
            let (tier, _) = launch_tier(&lane);
            let c = cycle(&lane, &t, &class("micro", "stub"), tier.as_deref());
            assert_eq!(
                fields(
                    &line_of("KEN-1", &c),
                    &["target", "ci_head", "ci_clean", "lane", "verdict"]
                ),
                want,
                "{name}"
            );
            assert_eq!(
                json!([
                    c["target"],
                    c["ci_head"],
                    c["ci_clean"],
                    c["lane_secs"],
                    c["open"]
                ]),
                record,
                "{name}"
            );
        }
    }

    #[test]
    fn the_launch_tier_and_the_class_evidence_explain_an_escape() {
        for (evidence, want) in [
            ("production-past-small production=328", "estimate-miss"),
            (
                "excluded-path path=.github/workflows/build.yml glob=.github/workflows/*",
                "path-miss",
            ),
            (
                "instruction-file path=AGENTS.md measured-class=micro",
                "path-miss",
            ),
            ("several-subsystems production=40", "path-miss"),
        ] {
            let lane = lane(
                "KEN-1",
                json!({"tier": "small", "tier_inputs": {"estimate": 12, "delta": 40, "paths": 3}}),
            );
            let (tier, note) = launch_tier(&lane);
            assert_eq!((tier.as_deref(), note), (Some("small"), None));
            let c = cycle(
                &lane,
                &timeline(5520, 300, 110),
                &class("standard", evidence),
                tier.as_deref(),
            );
            assert_eq!(
                fields(&line_of("KEN-1", &c), &["escape_cause"]),
                format!("escape_cause={want}"),
                "{evidence}"
            );
            assert!(
                rollup_row("standard", &[&c]).contains(&format!(" {}=1 ", want.replace('-', "_"))),
                "the rollup counts the missed input: {evidence}"
            );
            if want == "estimate-miss" {
                assert_eq!(
                    fields(
                        &line_of("KEN-1", &c),
                        &["tier", "class_reason", "escape_cause"]
                    ),
                    "tier=small class_reason=production-past-small escape_cause=estimate-miss"
                );
                assert_eq!(
                    json!([
                        c["tier_inputs"],
                        c["class_cause"],
                        c["class_reason"],
                        c["escape_cause"]
                    ]),
                    json!([{"estimate": 12, "delta": 40, "paths": 3}, null, "production-past-small", "estimate-miss"])
                );
            }
        }
        let untiered = lane("KEN-1", json!({}));
        assert_eq!(
            launch_tier(&untiered),
            (
                None,
                Some("oversee-cycle: launch-tier-missing item=KEN-1".to_owned())
            ),
            "a record written before launches recorded a tier warns"
        );
        assert_eq!(
            launch_tier(&lane("KEN-1", json!({"tier": null}))),
            (None, None)
        );
    }

    #[test]
    fn an_unread_class_keeps_its_cause_and_its_durations() {
        let refused = class_of(Err(ci_proof::Refusal::OriginUntrusted));
        assert_eq!(
            (refused.class.as_deref(), refused.cause.as_deref()),
            (None, Some("origin-untrusted"))
        );
        let measured = class_of(Ok(ci_proof::Measured {
            class: "small".to_owned(),
            cause: "production-past-micro".to_owned(),
            evidence: "production-past-micro production=90".to_owned(),
        }));
        assert_eq!(
            (
                measured.class.as_deref(),
                measured.cause.as_deref(),
                measured.reason.as_deref()
            ),
            (Some("small"), None, Some("production-past-micro"))
        );
        let brokered = Class::unread("origin-untrusted");
        let c = cycle(
            &lane("KEN-1", json!({})),
            &timeline(1500, 300, 110),
            &brokered,
            Some("standard"),
        );
        assert_eq!(
            json!([
                c["class"],
                c["class_cause"],
                c["verdict"],
                c["actual"],
                c["lane_secs"]
            ]),
            json!([null, "origin-untrusted", "unclassified", 1500, 1500]),
            "no trust override; the durations stand"
        );
        assert!(
            rollup_row("unclassified", &[&c])
                .starts_with("rollup class=unclassified items=1 median=1500 ")
        );
    }

    #[test]
    fn a_negative_round_interval_is_recorded_null_and_said() {
        let mut t = timeline(1000, 300, 110);
        t["rounds"] = json!([{"kind": "review", "head": "h1", "secs": -40}, {"kind": "fix", "head": "h1", "secs": 30}]);
        assert_eq!(
            negative_notes("KEN-1", &t),
            vec![
                "oversee-cycle: negative-interval item=KEN-1 kind=review head=h1 secs=-40"
                    .to_owned()
            ]
        );
        let c = cycle(
            &lane("KEN-1", json!({})),
            &t,
            &class("micro", "stub"),
            Some("micro"),
        );
        assert_eq!(c["pr_rounds"][0]["secs"], Value::Null);
        assert_eq!(c["pr_rounds"][1]["secs"], 30);
    }

    #[test]
    fn a_direct_push_records_its_commit_and_no_class_target() {
        let t = json!({"commit": "SHA", "stamps": {"first_commit": at(60), "merged": at(900)}});
        let c = cycle(
            &lane("KEN-1", json!({})),
            &t,
            &Class::unread("ci-proof-missing"),
            Some("micro"),
        );
        let got = line_of("KEN-1", &c);
        assert_eq!(
            got.split(" phase=").next().unwrap(),
            "cycle item=KEN-1 commit=SHA class=- tier=micro target=- merge_group=- ci_head=- ci_clean=- waited=0 lane=900 actual=900 open=- verdict=unclassified"
        );
        assert_eq!((c.get("commit"), c.get("pr")), (Some(&json!("SHA")), None));
    }

    #[test]
    fn a_pause_that_does_not_read_refuses_the_cycle() {
        for pauses in [json!("walled"), json!([{"from": "soon", "to": null}])] {
            let refused = pauses_of(&lane("KEN-1", json!({"pauses": pauses}))).unwrap_err();
            assert!(
                refused.to_string().contains("pauses-unreadable"),
                "{refused}"
            );
        }
    }

    /// A merge hold the answer never closed runs to the merge and no
    /// further, one answered stops at its answer, and one asked after the
    /// merge takes nothing off.
    #[test]
    fn a_hold_never_answered_runs_to_the_merge_and_no_further() {
        for (name, from, to, want) in [
            (
                "never answered",
                500,
                None,
                "waited=4500 lane=500 verdict=met",
            ),
            (
                "answered",
                500,
                Some(900),
                "waited=400 lane=4600 verdict=miss",
            ),
            (
                "asked after the merge",
                6000,
                None,
                "waited=0 lane=5000 verdict=miss",
            ),
        ] {
            let state = json!({"pauses": [{"from": at(from), "to": to.map_or(Value::Null, at), "cause": "merge-hold"}]});
            let lane = lane("KEN-1", json!({}));
            let pauses = waits_of(&lane, state.as_object()).unwrap();
            let c = compute(&Inputs {
                lane: &lane,
                timeline: &timeline(5000, 300, 110),
                rounds: Value::Null,
                stages: Value::Null,
                pauses: &pauses,
                class: &class("micro", "stub"),
                tier: Some("micro"),
                escaped: Some(false),
            });
            assert_eq!(
                fields(&line_of("KEN-1", &c), &["waited", "lane", "verdict"]),
                want,
                "{name}"
            );
        }
    }

    /// A fleet record of KEN-1..KEN-6 launched at T0, as the recorder's
    /// repeat bar and the rollup read it, and the workflow states the
    /// record reads beside it.
    struct Fleet {
        dir: tempfile::TempDir,
        lanes: Vec<Value>,
        states: BTreeMap<String, Value>,
    }

    impl Fleet {
        fn new() -> Fleet {
            let lanes = (1..=6)
                .map(|n| json!({"item": format!("KEN-{n}"), "repo": null, "launched_at": at(0), "status": "done"}))
                .collect();
            Fleet {
                dir: tempfile::tempdir().unwrap(),
                lanes,
                states: BTreeMap::new(),
            }
        }

        fn path(&self) -> PathBuf {
            self.dir.path().join("workflow-state-oversee.json")
        }

        #[allow(
            clippy::disallowed_methods,
            reason = "the row's own fleet record, planted as the close leaves one"
        )]
        fn write(&self) {
            let doc = json!({"issue_id": "oversee", "triaged": [], "launch_queue": [], "fleet_log": [], "lanes": self.lanes});
            std::fs::write(self.path(), doc.to_string()).unwrap();
        }

        fn lane(&self, item: &str) -> Lane {
            let record = self.lanes.iter().find(|l| l["item"] == item).unwrap();
            serde_json::from_value(record.clone()).unwrap()
        }

        /// Record `item`'s cycle over `timeline`, as the close writes it,
        /// and answer the bar line it makes.
        fn record(&mut self, item: &str, timeline: &Value) -> Option<String> {
            self.write();
            let lane = self.lane(item);
            let state = self.states.get(item).and_then(Value::as_object);
            let pauses = waits_of(&lane, state).unwrap();
            let c = compute(&Inputs {
                lane: &lane,
                timeline,
                rounds: Value::Null,
                stages: Value::Null,
                pauses: &pauses,
                class: &class("micro", "stub"),
                tier: Some("micro"),
                escaped: Some(false),
            });
            let bar = repeat_miss(&self.path(), &lane, &c).unwrap();
            let record = self.lanes.iter_mut().find(|l| l["item"] == item).unwrap();
            record["cycle"] = c;
            bar
        }
    }

    #[test]
    fn the_third_counting_miss_on_one_phase_is_a_repeat_miss() {
        let step = |kind: &str| -> Value {
            match kind {
                "m" => timeline(5000, 300, 110),
                "p" => {
                    let mut t = timeline(4360, 300, 110);
                    t["stamps"]["first_commit"] = at(600);
                    t["stamps"]["ci_green"] = at(700);
                    t["stamps"]["created"] = at(2460);
                    t["stamps"]["gate_met"] = at(3400);
                    t["stamps"]["armed"] = at(3800);
                    t["open_secs"] = json!(1900);
                    t
                }
                "cf" => {
                    let mut t = timeline(3500, 300, 110);
                    t["ci_head_clean_secs"] = json!(1800);
                    t["stamps"]["ci_green"] = at(2100);
                    t["stamps"]["armed"] = at(2200);
                    t
                }
                "a" => {
                    let mut t = timeline(5000, 300, 110);
                    t["stamps"]["ci_green"] = at(10000);
                    t["ci_head_spans"] = json!([{"start": at(110), "end": at(10000)}]);
                    t
                }
                "n" => {
                    let mut t = timeline(5000, 300, 110);
                    t["stamps"]["ci_green"] = Value::Null;
                    t
                }
                "ok" => timeline(800, 300, 110),
                "h" | "c" | "q" | "qs" => timeline(5000, 300, 110),
                "g" | "w" => gate_timeline(Some(&[100, 1400]), &[400, 1500, 2000], 3200),
                "cw" => ci_timeline(Some(3500), Some(&[(3500, 4000)]), None),
                "cc" | "hc" => ci_timeline(Some(400), Some(&[(400, 4000)]), None),
                "cv" => ci_timeline(Some(400), Some(&[(400, 546), (3864, 4000)]), Some(136)),
                other => panic!("no step {other}"),
            }
        };
        for (name, sequence, want) in [
            (
                "third",
                "m:1 m:2 m:3",
                Some(
                    "repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged",
                ),
            ),
            ("met-record", "m:1 m:2 m:3 ok:4", None),
            ("met-not-counted", "ok:1 m:2 m:3", None),
            ("other-phase", "m:1 m:2 p:3", None),
            (
                "pre-open",
                "p:1 p:2 p:3",
                Some(
                    "repeat-miss phase=pr_opened items=KEN-1,KEN-2,KEN-3 causes=pr_opened,pr_opened,pr_opened",
                ),
            ),
            (
                "forgiven-ci",
                "cf:1 cf:2 cf:3",
                Some(
                    "repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged",
                ),
            ),
            (
                "post-merge",
                "a:1 a:2 a:3",
                Some(
                    "repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged",
                ),
            ),
            ("unnamed-phase", "n:1 n:2 n:3", None),
            ("recorded-again", "m:1 m:2 m:3 m:3", None),
            ("fourth", "m:1 m:2 m:3 m:4", None),
            // A wall over most of a gate gap is a wait: it explains that
            // lane's overrun, so the lane meets its target and the bar
            // waits for a third lane missing on its own time.
            ("a-wall-is-a-wait", "g:1 w:2 g:3", None),
            (
                "own-time-beside-a-wait",
                "g:1 w:2 g:3 g:4",
                Some(
                    "repeat-miss phase=gate_green items=KEN-1,KEN-3,KEN-4 causes=thread_fix,thread_fix,thread_fix",
                ),
            ),
            ("merge-holds", "h:1 h:2 h:3", None),
            ("walls-with-no-account-to-move-to", "c:1 c:2 c:3", None),
            ("relaunches-held-for-capacity", "q:1 q:2 q:3", None),
            (
                "a-capacity-wait-standing-to-the-merge",
                "qs:1 qs:2 qs:3",
                None,
            ),
            (
                "ci-under-a-hold",
                "hc:1 hc:2 hc:3",
                Some("repeat-miss phase=ci_green items=KEN-1,KEN-2,KEN-3 causes=ci,ci,ci"),
            ),
            ("ci-work", "cw:1 cw:2 cw:3", None),
            (
                "ci-slow",
                "cw:1 cc:2 cc:3 cc:4",
                Some("repeat-miss phase=ci_green items=KEN-2,KEN-3,KEN-4 causes=ci,ci,ci"),
            ),
            ("ci-work-after", "cc:1 cc:2 cc:3 cw:4", None),
            ("ci-wait", "cv:1 cv:2 cv:3", None),
            (
                "ci-recounted",
                "cc:1 cc:2 cw:3 cc:3",
                Some("repeat-miss phase=ci_green items=KEN-1,KEN-2,KEN-3 causes=ci,ci,ci"),
            ),
        ] {
            let mut fleet = Fleet::new();
            let mut bar = None;
            for step_word in sequence.split(' ') {
                let (kind, n) = step_word.split_once(':').unwrap();
                let item = format!("KEN-{n}");
                let record = fleet
                    .lanes
                    .iter_mut()
                    .find(|l| l["item"] == item.as_str())
                    .unwrap();
                match kind {
                    "w" => record["pauses"] = paused(&[(400, 2900)], None)["pauses"].clone(),
                    // The wall stands to the merge: no account had room
                    // to move the lane onto.
                    "c" => record["walled"] = json!({"at": at(500)}),
                    // The relaunch refused for capacity from 500 and
                    // admitted at 4900, as the admission closes the wait;
                    // and one whose pull request merged while it stood.
                    "q" => {
                        record["pauses"] =
                            json!([{"from": at(500), "to": at(4900), "cause": "capacity"}]);
                    }
                    "qs" => record["capacity_wait"] = json!({"at": at(500)}),
                    "h" | "hc" => {
                        let (from, to) = if kind == "h" {
                            (500, 4900)
                        } else {
                            (4100, 4200)
                        };
                        fleet.states.insert(
                            item.clone(),
                            json!({"pauses": [{"from": at(from), "to": at(to), "cause": "merge-hold"}]}),
                        );
                    }
                    _ => {}
                }
                bar = fleet.record(&item, &step(kind));
            }
            assert_eq!(bar.as_deref(), want, "{name}: {sequence}");
        }
        let mut fleet = Fleet::new();
        fleet.record("KEN-1", &step("m"));
        fleet.record("KEN-2", &step("m"));
        fleet.lanes[0]["cycle"]["cause"] = Value::Null;
        assert_eq!(
            fleet.record("KEN-3", &step("m")).as_deref(),
            Some("repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged"),
            "a miss written with no cause reads its phase on the bar"
        );
    }

    fn rollup_of(cycles: Vec<Value>) -> Vec<String> {
        let mut fleet = Fleet::new();
        fleet.lanes = cycles
            .into_iter()
            .enumerate()
            .map(|(n, c)| json!({"item": format!("KEN-{n}"), "status": "done", "cycle": c}))
            .chain([json!({"item": "KEN-99", "status": "running"})])
            .collect();
        fleet.write();
        rollup(&fleet.path(), false).unwrap()
    }

    #[test]
    fn the_rollup_counts_each_class_its_median_and_p90() {
        let rounds = json!({"review": 1, "fix": 2, "bot": 1, "full_validations": 1});
        let record = |class: Value,
                      actual: i64,
                      verdict: &str,
                      rounds: &Value,
                      escaped: Value,
                      refixed: bool,
                      pr_rounds: Value| {
            json!({"class": class, "actual": actual, "verdict": verdict, "rounds": rounds, "escaped": escaped,
                "refixed": refixed, "pr_rounds": pr_rounds})
        };
        let round = |kind: &str, secs: Value| json!({"kind": kind, "secs": secs});
        let p1 = json!([
            round("review", json!(300)),
            round("fix", json!(900)),
            round("review", json!(500)),
            round("review", Value::Null)
        ]);
        let p2 = json!([round("review", json!(700))]);
        let ps = json!([
            round("review", json!(1200)),
            round("fix", json!(60)),
            round("review", json!(900))
        ]);
        let rows = rollup_of(vec![
            record(json!("micro"), 100, "met", &rounds, json!(false), false, p1),
            record(json!("micro"), 400, "met", &rounds, json!(true), true, p2),
            record(
                json!("micro"),
                1000,
                "miss",
                &Value::Null,
                json!(false),
                false,
                json!([]),
            ),
            record(
                json!("micro"),
                200,
                "met",
                &rounds,
                json!(false),
                false,
                Value::Null,
            ),
            record(
                json!("render"),
                30,
                "met",
                &rounds,
                json!(false),
                false,
                Value::Null,
            ),
            record(
                json!("standard"),
                6000,
                "miss",
                &rounds,
                json!(false),
                true,
                ps,
            ),
            record(
                Value::Null,
                50,
                "unclassified",
                &Value::Null,
                Value::Null,
                false,
                Value::Null,
            ),
        ]);
        assert_eq!(
            rows.join("\n"),
            "rollup class=render items=1 median=30 p90=30 lane_median=- open_median=- miss_share=- misses=0 draft=- review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0
rollup class=micro items=4 median=200 p90=1000 lane_median=- open_median=- miss_share=- misses=1 draft=- review=3 fix=6 bot=3 full_validations=3 rounds_unread=1 escaped=1 estimate_miss=0 path_miss=0 refixed=1 pr_rounds=1 pr_rounds_unread=1 round_median=500 fix_median=900 rounds_untimed=1
rollup class=standard items=1 median=6000 p90=6000 lane_median=- open_median=- miss_share=- misses=1 draft=- review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 estimate_miss=0 path_miss=0 refixed=1 pr_rounds=2 pr_rounds_unread=0 round_median=900 fix_median=60 rounds_untimed=0
rollup class=unclassified items=1 median=50 p90=50 lane_median=- open_median=- miss_share=- misses=0 draft=- review=- fix=- bot=- full_validations=- rounds_unread=1 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0"
        );
        let medians = rollup_of(vec![
            json!({"class": "micro", "actual": 3557, "lane_secs": 1200, "open": 3437, "verdict": "miss"}),
            json!({"class": "micro", "actual": 8899, "lane_secs": 6536, "open": 8779, "verdict": "met"}),
            json!({"class": "micro", "actual": 2500, "lane_secs": 900, "open": 2380, "verdict": "miss"}),
        ]);
        assert_eq!(
            fields(&medians[0], &["lane_median", "open_median", "miss_share"]),
            "lane_median=1200 open_median=3437 miss_share=1/3",
            "both medians and the lane miss share come from the records, never their stale verdicts"
        );
        let negative = json!([
            round("review", json!(300)),
            round("review", json!(-40)),
            round("fix", json!(-10)),
            round("fix", json!(200))
        ]);
        let rows = rollup_of(vec![
            record(
                json!("micro"),
                100,
                "met",
                &Value::Null,
                json!(false),
                false,
                negative,
            ),
            record(
                json!("micro"),
                -50,
                "met",
                &Value::Null,
                json!(false),
                false,
                Value::Null,
            ),
        ]);
        assert_eq!(
            fields(
                &rows[0],
                &[
                    "median",
                    "p90",
                    "round_median",
                    "fix_median",
                    "rounds_untimed"
                ]
            ),
            "median=100 p90=100 round_median=300 fix_median=200 rounds_untimed=2",
            "negative seconds enter no aggregate, and a negative round is untimed"
        );
        let none = Fleet::new();
        assert_eq!(
            rollup(&none.path(), true).unwrap(),
            Vec::<String>::new(),
            "no fleet state prints nothing"
        );
    }
}
