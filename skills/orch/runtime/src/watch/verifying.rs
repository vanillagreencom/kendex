//! The verification duty (decision 121 Q5, Q8; step5-map § A5): the
//! Verifying items the tracker duty read, each judged box by box as the
//! legacy `verifying_read` judged them (`oversee-watch:5492-5623` over
//! `lib/verifying.sh`): the Done-when boxes through the linear CLI's own
//! parser (decision 9's `done-when parse`), the merge the release and
//! `+Nh` boxes count from, read per merged key of the GitHub duty's merged
//! index, the release publications a release box waits on, and each box's
//! status on this pass's clock. The `verifying` lines are handed to the
//! heartbeat through [`Lines`]; the `verifying-deadline` rows and their
//! event lines are the duty's own, the event handed back before the row
//! that settles it (the runner's `commit` keeps that order), so a crash
//! between the two reprints the deadline once and never loses it.
//!
//! The duty reads nothing of the controller (Q8): a dead, walled or absent
//! overseer changes nothing it does. It makes no second tracker read: the
//! items are the tracker duty's last pass's, so an inventory the tracker
//! has not read yet is nothing to judge, not an empty one.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use agent_runtime::clock;
use agent_runtime::host;
use serde::Deserialize;
use serde_json::Value;

use crate::error::Result;
use crate::settings::Settings;
use crate::verify::wire::Nullable;
use crate::watch::tracker::{Shared, VerifyingItem};
use crate::watch::{Body, Change, Event, Produced, Runner, Tick};

/// The baseline row kind this duty owns: `verifying-deadline <id>`, the
/// due keys joined by `|`, `-` with none due, `boxes=0` with no open box.
pub const DEADLINE_ROW: &str = "verifying-deadline";

/// The bound on one call: the parser reads nothing, a `gh api` call one
/// page.
const BOUND: Duration = Duration::from_secs(60);

/// The start-counter tag every call of this duty is counted under.
const TAG: &str = "verifying";

/// GitHub's page size for the release list.
const RELEASE_PAGE: usize = 100;

/// The `verifying` lines of the last pass, for the heartbeat's body.
pub type Lines = Arc<Mutex<Vec<String>>>;

/// What the duty runs with, fixed at registration.
pub struct Context {
    pub settings: Settings,
    /// The `gh` program the merge and release reads run; `gh` on `PATH`
    /// in production.
    pub gh: PathBuf,
    /// The tracker and GitHub duties' slot: the Verifying items and the
    /// merged index.
    pub shared: Shared,
    pub lines: Lines,
}

pub fn body<'a>(ctx: Context) -> Body<'a> {
    Box::new(move |tick: &Tick| run(&ctx, tick))
}

/// Register the duty on `runner` (decision 153), reading the tracker and
/// GitHub duties' slot `shared`; the lines slot the heartbeat reads is
/// returned.
pub fn register(runner: &mut Runner<'_>, settings: &Settings, shared: Shared) -> Lines {
    let lines = Lines::default();
    runner.register(
        crate::schedule::Duty::Verification,
        body(Context {
            settings: settings.clone(),
            gh: PathBuf::from("gh"),
            shared,
            lines: lines.clone(),
        }),
    );
    lines
}

/// A note the legacy wrote on stderr beside a pass that went on: the
/// item's judgement is unread or invalid, the other items proceed.
fn note(key: &str, id: &str, cause: &str) {
    let _ = writeln!(std::io::stderr(), "{key} issue={id}\n{cause}");
}

// --- the parser's reply ----------------------------------------------------------

/// `linear done-when parse`'s checklist (`done_when_parse`): the fields the
/// judgement reads.
#[derive(Debug, Clone, Deserialize)]
struct Parsed {
    boxes: Vec<ParsedBox>,
    errors: Vec<Value>,
    /// Every open box but the container's child box, which its closer
    /// ticks: on a container, an outcome still to move into a child.
    #[serde(default)]
    container_open_boxes: Vec<u64>,
}

#[derive(Debug, Clone, Deserialize)]
struct ParsedBox {
    number: u64,
    checked: bool,
    post_merge: bool,
    text: String,
    #[serde(default)]
    trigger: Option<String>,
    #[serde(default)]
    trigger_kind: Option<String>,
    #[serde(default)]
    trigger_epoch: Option<u64>,
    #[serde(default)]
    deadline_epoch: Option<u64>,
    #[serde(default)]
    deadline_hours: Option<u64>,
    #[serde(default)]
    deadline: Option<String>,
    #[serde(default)]
    reading: Option<String>,
    #[serde(default, rename = "where")]
    where_: Option<String>,
    #[serde(default)]
    why: Option<String>,
    #[serde(default)]
    release_repo: Option<String>,
    #[serde(default)]
    release_glob: Option<String>,
}

/// One box under judgement (`verifying_parse`'s output row).
#[derive(Debug, Clone, PartialEq, Eq)]
struct Judged {
    number: u64,
    trigger: String,
    trigger_kind: String,
    trigger_epoch: Option<u64>,
    deadline_epoch: Option<u64>,
    deadline_hours: Option<u64>,
    deadline: Option<String>,
    reading: String,
    where_: String,
    why: String,
    release: Option<(String, String)>,
    /// `merged=<UTC>` on a release box, whether its publication resolved.
    merged: Option<String>,
    status: &'static str,
}

impl Judged {
    fn needs_merge(&self) -> bool {
        self.trigger_kind == "release"
            || (self.trigger_kind == "merge" && self.deadline_hours.is_some())
    }

    /// `VERIFYING_LINE_JQ`'s line.
    fn line(&self, id: &str, blocked: &[String]) -> String {
        let blocked = if blocked.is_empty() {
            "-".to_owned()
        } else {
            blocked.join(",")
        };
        let merged = self
            .merged
            .as_deref()
            .map(|m| format!(" merged={m}"))
            .unwrap_or_default();
        format!(
            "verifying {id} box={} trigger={} status={} deadline={}{merged} blocked_by={blocked} reading={} where={} why={}",
            self.number,
            json_text(&self.trigger),
            self.status,
            self.deadline.as_deref().unwrap_or("-"),
            json_text(&self.reading),
            json_text(&self.where_),
            json_text(&self.why)
        )
    }

    /// The due key the row holds and the event carries (`:5574`).
    fn due_key(&self) -> String {
        format!(
            "box={} trigger={} status={} deadline={}",
            self.number,
            json_text(&self.trigger),
            self.status,
            self.deadline.as_deref().unwrap_or("null")
        )
    }
}

/// jq's `tojson` of a string.
fn json_text(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_owned())
}

/// `verifying_parse`: the boxes the item is judged on, or `None` for an
/// item the parser cannot read as Verifying (branch work open, a malformed
/// box).
fn judged_boxes(parsed: &Parsed, container: bool) -> Option<Vec<Judged>> {
    let rows: Vec<&ParsedBox> = if container {
        parsed
            .boxes
            .iter()
            .filter(|b| parsed.container_open_boxes.contains(&b.number))
            .collect()
    } else {
        if !parsed.errors.is_empty() || !parsed.boxes.iter().all(|b| b.checked || b.post_merge) {
            return None;
        }
        parsed
            .boxes
            .iter()
            .filter(|b| b.post_merge && !b.checked)
            .collect()
    };
    Some(
        rows.into_iter()
            .map(|b| {
                if container {
                    Judged {
                        number: b.number,
                        trigger: "outcome".to_owned(),
                        trigger_kind: "outcome".to_owned(),
                        trigger_epoch: None,
                        deadline_epoch: None,
                        deadline_hours: None,
                        deadline: None,
                        reading: b.text.clone(),
                        where_: "-".to_owned(),
                        why: "-".to_owned(),
                        release: None,
                        merged: None,
                        status: "due",
                    }
                } else {
                    Judged {
                        number: b.number,
                        trigger: b.trigger.clone().unwrap_or_else(|| "merge".to_owned()),
                        trigger_kind: b.trigger_kind.clone().unwrap_or_else(|| "merge".to_owned()),
                        trigger_epoch: b.trigger_epoch,
                        deadline_epoch: b.deadline_epoch,
                        deadline_hours: b.deadline_hours,
                        deadline: b.deadline.clone(),
                        reading: b.reading.clone().unwrap_or_default(),
                        where_: b.where_.clone().unwrap_or_default(),
                        why: b.why.clone().unwrap_or_default(),
                        release: b.release_repo.clone().zip(b.release_glob.clone()),
                        merged: None,
                        status: "due",
                    }
                }
            })
            .collect(),
    )
}

// --- the reads -------------------------------------------------------------------------

/// `GET /repos/{owner}/{repo}/pulls/{n}`: the merge a box counts from.
#[derive(Debug, Deserialize)]
struct MergedPull {
    merged_at: Nullable<String>,
    merge_commit_sha: Nullable<String>,
}

/// One release of `GET /repos/{owner}/{repo}/releases`.
#[derive(Debug, Deserialize)]
struct Release {
    #[serde(default)]
    tag_name: Nullable<String>,
    #[serde(default)]
    published_at: Nullable<String>,
    draft: Nullable<bool>,
}

/// `gh api <path>` through the one runner; the parsed JSON, or the
/// failure's words. The pass's reads are kept in `read`, so one merge or
/// release page is read once per pass.
#[allow(
    clippy::disallowed_methods,
    reason = "the verification duty's GitHub reads (a merged pull request, a release page, a comparison) through the one runner under its tag"
)]
fn gh_json(
    gh: &Path,
    path: &str,
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<Value, String> {
    if let Some(value) = read.get(path) {
        return Ok(value.clone());
    }
    let out =
        host::run_tagged(TAG, "gh", gh, "api", &["api", path], BOUND).map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!("gh api {path}: {}", host::stderr_text(&out).trim()));
    }
    let value: Value = serde_json::from_str(&host::stdout_text(&out))
        .map_err(|e| format!("gh api {path}: {e}"))?;
    read.insert(path.to_owned(), value.clone());
    Ok(value)
}

/// The linear CLI's parser on `description`: the parse, the parser's own
/// refusal (an item that is not Verifying), or the call's failure.
#[allow(
    clippy::disallowed_methods,
    reason = "the verification duty's one call of the linear CLI's own Done-when parser per item through the one runner under its tag; it reads nothing (decision 9)"
)]
fn parse(settings: &Settings, description: &str) -> Result<std::result::Result<Parsed, String>> {
    let out = host::run_tagged(
        TAG,
        "linear",
        &settings.reads.tracker_cli,
        "done-when",
        &["done-when", "parse", "--description", description],
        BOUND,
    )?;
    if !out.status.success() {
        return Ok(Err(format!(
            "done-when parse exit={}: {}",
            out.status.code().unwrap_or(-1),
            host::stderr_text(&out).trim()
        )));
    }
    Ok(serde_json::from_str::<Parsed>(&host::stdout_text(&out))
        .map_err(|e| format!("done-when parse: {e}")))
}

/// The merge an item's boxes count from: its epoch second and, per
/// repository (lowercased), the merge commit where the pull request names
/// one that is a full object name.
struct Merge {
    at: u64,
    oids: BTreeMap<String, Option<String>>,
}

/// The merge an item's boxes count from (`merged_item_read`): the latest
/// `merged_at` among the merged index's keys for it, and the merge commit
/// per repository. `None` where the index names no key: unread for a box
/// that needs it.
fn merge_of(
    gh: &Path,
    keys: &[String],
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<Option<Merge>, String> {
    let mut merged: Option<u64> = None;
    let mut oids: BTreeMap<String, Option<String>> = BTreeMap::new();
    for key in keys {
        let Some((repo, number)) = key.split_once('#') else {
            return Err(format!("merged key {key}: no number"));
        };
        let path = format!("repos/{repo}/pulls/{number}");
        let value = gh_json(gh, &path, read)?;
        let pull: MergedPull = serde_json::from_value(value).map_err(|e| format!("{path}: {e}"))?;
        let at = match &pull.merged_at {
            Nullable::Present(stamp) => {
                clock::epoch_secs(stamp).ok_or_else(|| format!("{path}: merged_at {stamp}"))?
            }
            Nullable::Absent | Nullable::Null => continue,
        };
        if merged.is_none_or(|m| at > m) {
            merged = Some(at);
        }
        let oid = match &pull.merge_commit_sha {
            Nullable::Present(oid)
                if oid.len() == 40 && oid.bytes().all(|b| b.is_ascii_hexdigit()) =>
            {
                Some(oid.clone())
            }
            Nullable::Present(_) | Nullable::Absent | Nullable::Null => None,
        };
        oids.insert(repo.to_ascii_lowercase(), oid);
    }
    Ok(merged.map(|at| Merge { at, oids }))
}

/// A bash pattern (`[[ $tag == $glob ]]`) over `*` and `?`; a bracket
/// class is matched as its literal characters.
fn glob_matches(glob: &str, text: &str) -> bool {
    fn go(g: &[char], t: &[char]) -> bool {
        match g.split_first() {
            None => t.is_empty(),
            Some(('*', rest)) => (0..=t.len()).any(|i| go(rest, &t[i..])),
            Some(('?', rest)) => !t.is_empty() && go(rest, &t[1..]),
            Some((c, rest)) => t.first() == Some(c) && go(rest, &t[1..]),
        }
    }
    let g: Vec<char> = glob.chars().collect();
    let t: Vec<char> = text.chars().collect();
    go(&g, &t)
}

/// The releases of `repo`, every page, as `(published epoch, tag)` for the
/// published ones (`verifying_judge`'s release read).
fn releases(
    gh: &Path,
    repo: &str,
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<Vec<(u64, String)>, String> {
    let mut out = Vec::new();
    let mut page = 1;
    loop {
        let path = format!("repos/{repo}/releases?per_page={RELEASE_PAGE}&page={page}");
        let value = gh_json(gh, &path, read)?;
        let rows: Vec<Release> =
            serde_json::from_value(value).map_err(|_| format!("{path}: release-fields"))?;
        let short = rows.len() < RELEASE_PAGE;
        for row in rows {
            let draft = match row.draft {
                Nullable::Present(d) => d,
                Nullable::Absent | Nullable::Null => return Err(format!("{path}: release-fields")),
            };
            if draft {
                continue;
            }
            let (tag, stamp) = match (&row.tag_name, &row.published_at) {
                (Nullable::Present(tag), Nullable::Present(stamp)) => (tag.clone(), stamp.clone()),
                _ => return Err(format!("{path}: release-fields")),
            };
            let at = clock::epoch_secs(&stamp).ok_or_else(|| format!("{path}: release-fields"))?;
            out.push((at, tag));
        }
        if short {
            break;
        }
        page += 1;
    }
    out.sort();
    Ok(out)
}

/// `verifying_judge`: the release boxes resolved, the `+Nh` deadlines
/// counted and each box's status at `now`. `Err` is the legacy's rc 2
/// (unread) with its key and cause.
fn judge(
    gh: &Path,
    boxes: &mut [Judged],
    merged: Option<&Merge>,
    blocked: bool,
    now: u64,
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<(), (&'static str, String)> {
    if boxes.iter().any(Judged::needs_merge) && merged.is_none() {
        return Err(("verifying-merge-unread", String::new()));
    }
    for b in boxes.iter_mut() {
        let Some((repo, glob)) = b.release.clone() else {
            continue;
        };
        let Some(Merge {
            at: merge_epoch,
            oids,
        }) = merged
        else {
            return Err(("verifying-merge-unread", String::new()));
        };
        let oid = match oids.get(&repo.to_ascii_lowercase()) {
            None => None,
            Some(Some(oid)) => Some(oid.clone()),
            Some(None) => return Err(("verifying-release-unread", format!("repo={repo}"))),
        };
        let listed = releases(gh, &repo, read)
            .map_err(|cause| ("verifying-release-unread", format!("repo={repo} {cause}")))?;
        let mut resolved = None;
        for (at, tag) in listed.into_iter().filter(|(at, _)| *at > *merge_epoch) {
            if !glob_matches(&glob, &tag) {
                continue;
            }
            if let Some(oid) = &oid {
                let path = format!(
                    "repos/{repo}/compare/{oid}...{}",
                    crate::watch::github::encoded(&tag)
                );
                let comparison = gh_json(gh, &path, read).map_err(|cause| {
                    (
                        "verifying-release-unread",
                        format!("repo={repo} tag={tag} {cause}"),
                    )
                })?;
                match comparison.get("status").and_then(Value::as_str) {
                    Some("ahead" | "identical") => {}
                    Some("behind" | "diverged") => continue,
                    other => {
                        return Err((
                            "verifying-release-unread",
                            format!("repo={repo} tag={tag} status={}", other.unwrap_or("")),
                        ));
                    }
                }
            }
            resolved = Some(at);
            break;
        }
        b.trigger_epoch = resolved;
        b.merged = Some(clock::iso_utc(*merge_epoch));
    }
    for b in boxes.iter_mut() {
        if b.deadline_hours.is_some() {
            let fired = if b.trigger_kind == "merge" {
                merged.map(|m| m.at)
            } else {
                b.trigger_epoch
            };
            b.deadline_epoch = fired.zip(b.deadline_hours).map(|(f, h)| f + h * 3600);
            b.deadline = b.deadline_epoch.map(clock::iso_utc);
        }
        b.status = if b.deadline_epoch.is_some_and(|d| d <= now) {
            "overdue"
        } else if blocked {
            "blocked"
        } else if b.trigger_kind != "merge"
            && b.trigger_kind != "outcome"
            && b.trigger_epoch.is_none_or(|t| t > now)
        {
            "waiting"
        } else {
            "due"
        };
    }
    Ok(())
}

// --- the pass ------------------------------------------------------------------------------

/// What one item's judgement settled.
enum Item {
    /// The lines and the row key, with the due keys the event lines carry.
    Read {
        lines: Vec<String>,
        key: String,
        due: Vec<String>,
    },
    /// Unread this pass: the prior row stands.
    Unread,
    /// Invalid: no row, the pass goes on.
    Invalid,
}

fn judge_item(
    ctx: &Context,
    item: &VerifyingItem,
    merged_keys: Option<&[String]>,
    now: u64,
    read: &mut BTreeMap<String, Value>,
) -> Result<Item> {
    let parsed = match parse(&ctx.settings, &item.description)? {
        Ok(parsed) => parsed,
        Err(cause) => {
            note("verifying-invalid", &item.id, &cause);
            return Ok(Item::Invalid);
        }
    };
    let Some(mut boxes) = judged_boxes(&parsed, item.container) else {
        note(
            "verifying-invalid",
            &item.id,
            "branch work open or a box the parser refused",
        );
        return Ok(Item::Invalid);
    };
    let merged = if boxes.iter().any(Judged::needs_merge) {
        match merge_of(&ctx.gh, merged_keys.unwrap_or(&[]), read) {
            Ok(merged) => merged,
            Err(cause) => {
                note("verifying-merge-unread", &item.id, &cause);
                return Ok(Item::Unread);
            }
        }
    } else {
        None
    };
    // The item's open blockers, from the tracker's read: `blocked` after
    // `overdue` and before `waiting` (`lib/verifying.sh:141`, `:152`).
    let blocked = &item.blocked_by_open;
    if let Err((key, cause)) = judge(
        &ctx.gh,
        &mut boxes,
        merged.as_ref(),
        !blocked.is_empty(),
        now,
        read,
    ) {
        note(key, &item.id, &cause);
        return Ok(Item::Unread);
    }
    let mut lines: Vec<String> = boxes.iter().map(|b| b.line(&item.id, blocked)).collect();
    let due: Vec<String> = boxes
        .iter()
        .filter(|b| b.status == "due" || b.status == "overdue")
        .map(Judged::due_key)
        .collect();
    let key = if lines.is_empty() {
        lines.push(format!("verifying {} boxes=0", item.id));
        "boxes=0".to_owned()
    } else if due.is_empty() {
        "-".to_owned()
    } else {
        due.join("|")
    };
    Ok(Item::Read { lines, key, due })
}

fn run(ctx: &Context, tick: &Tick) -> Result<Produced> {
    let (items, merged_index) = {
        let latest = ctx.shared.lock().unwrap_or_else(|p| p.into_inner());
        let Some(tracker) = latest.tracker.as_ref() else {
            // Nothing read yet: nothing to judge.
            return Ok(Produced::default());
        };
        let mut items = tracker.verifying.clone();
        // The legacy's `group_by(.id)` sorted the items by id.
        items.sort_by(|a, b| a.id.cmp(&b.id));
        let index = latest
            .github
            .as_ref()
            .map(|g| g.merged.clone())
            .unwrap_or_default();
        (items, index)
    };
    let mut produced = Produced::default();
    // The legacy printed every deadline's `EVENT` line, then the `verifying`
    // lines of the boxes those named (`VERIFYING_EVENT_LINES`, at the pass's
    // end), so the block is the same two runs of lines here.
    let mut event_lines: Vec<String> = Vec::new();
    let mut all_lines = Vec::new();
    let mut held: BTreeSet<String> = BTreeSet::new();
    let mut read: BTreeMap<String, Value> = BTreeMap::new();
    for item in &items {
        let judged = judge_item(
            ctx,
            item,
            merged_index.get(&item.id).map(Vec::as_slice),
            tick.wall,
            &mut read,
        )?;
        let prior = tick.baseline.get(DEADLINE_ROW, &item.id);
        match judged {
            Item::Invalid => {}
            Item::Unread => {
                // An unread item cannot clear a previously reported deadline.
                if prior.is_some() {
                    held.insert(item.id.clone());
                }
            }
            Item::Read { lines, key, due } => {
                held.insert(item.id.clone());
                all_lines.extend(lines.iter().cloned());
                if prior != Some(key.as_str()) {
                    if key == "boxes=0" {
                        produced.events.push(Event::VerifyingDeadline {
                            id: item.id.clone(),
                            row: "boxes=0".to_owned(),
                        });
                        event_lines.extend(lines.iter().cloned());
                    }
                    let prior_keys: Vec<&str> =
                        prior.map(|p| p.split('|').collect()).unwrap_or_default();
                    for row in &due {
                        // The saved row already holds each due box key: a
                        // changed sibling repeats no box's instructions.
                        if prior_keys.contains(&row.as_str()) {
                            continue;
                        }
                        let box_word = row.split(' ').next().unwrap_or_default();
                        let prefix = format!("verifying {} {box_word} ", item.id);
                        event_lines
                            .extend(lines.iter().filter(|l| l.starts_with(&prefix)).cloned());
                        produced.events.push(Event::VerifyingDeadline {
                            id: item.id.clone(),
                            row: row.clone(),
                        });
                    }
                    produced.changes.push(Change::Set {
                        kind: DEADLINE_ROW.to_owned(),
                        identity: item.id.clone(),
                        value: key,
                    });
                }
            }
        }
    }
    produced
        .events
        .extend(event_lines.into_iter().map(|line| Event::Body { line }));
    // The due set is rebuilt after the complete inventory: a row of an item
    // no longer Verifying goes.
    for identity in tick.baseline.identities(DEADLINE_ROW) {
        if !held.contains(&identity) {
            produced.changes.push(Change::Clear {
                kind: DEADLINE_ROW.to_owned(),
                identity,
            });
        }
    }
    *ctx.lines.lock().unwrap_or_else(|p| p.into_inner()) = all_lines;
    Ok(produced)
}

/// The row kinds this duty keeps.
pub fn row_kinds() -> [&'static str; 1] {
    [DEADLINE_ROW]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bash pattern the tracker supplies as a release tag glob.
    #[test]
    fn a_release_glob_matches_as_bash_matches_it() {
        let rows = [
            ("v*", "v1.2.3", true),
            ("v*", "w1", false),
            ("v?.?", "v1.2", true),
            ("v?.?", "v1.22", false),
            ("app-*-release", "app-2026.10-release", true),
            ("exact", "exact", true),
            ("exact", "exact1", false),
        ];
        for (glob, tag, want) in rows {
            assert_eq!(glob_matches(glob, tag), want, "{glob} {tag}");
        }
    }

    /// The legacy status order (`oversee-events.md` § Verification):
    /// overdue past the deadline whatever else holds, blocked on an open
    /// blocker, waiting on an unfired trigger, else due; a `+Nh` merge box
    /// counts from the merge and is unread without it.
    #[test]
    fn a_box_takes_its_status_in_the_legacy_order() {
        let gh = PathBuf::from("gh");
        let mut read = BTreeMap::new();
        let make = |kind: &str, trigger_epoch: Option<u64>, deadline_epoch: Option<u64>| Judged {
            number: 1,
            trigger: kind.to_owned(),
            trigger_kind: kind.to_owned(),
            trigger_epoch,
            deadline_epoch,
            deadline_hours: None,
            deadline: None,
            reading: String::new(),
            where_: String::new(),
            why: String::new(),
            release: None,
            merged: None,
            status: "due",
        };
        let rows: Vec<(Judged, bool, &str)> = vec![
            (make("merge", None, Some(100)), true, "overdue"),
            (make("merge", None, Some(101)), true, "blocked"),
            (make("time", Some(200), Some(101)), false, "waiting"),
            (make("time", None, None), false, "waiting"),
            (make("time", Some(100), None), false, "due"),
            (make("merge", None, None), false, "due"),
            (make("outcome", None, None), false, "due"),
        ];
        for (judged, blocked, want) in rows {
            let mut boxes = vec![judged];
            judge(
                &gh,
                &mut boxes,
                Some(&Merge {
                    at: 50,
                    oids: BTreeMap::new(),
                }),
                blocked,
                100,
                &mut read,
            )
            .unwrap();
            assert_eq!(boxes[0].status, want, "{:?}", boxes[0]);
        }
        let mut plus = vec![Judged {
            deadline_hours: Some(2),
            ..make("merge", None, None)
        }];
        assert_eq!(
            judge(&gh, &mut plus, None, false, 100, &mut read),
            Err(("verifying-merge-unread", String::new()))
        );
        judge(
            &gh,
            &mut plus,
            Some(&Merge {
                at: 50,
                oids: BTreeMap::new(),
            }),
            false,
            100,
            &mut read,
        )
        .unwrap();
        assert_eq!(plus[0].deadline_epoch, Some(50 + 7200));
        assert_eq!(plus[0].deadline.as_deref(), Some("1970-01-01T02:00:50Z"));
        assert_eq!(plus[0].status, "due");
    }
}
