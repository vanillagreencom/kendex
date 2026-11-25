//! The one box judge: an item's post-merge checklist judged on its merge
//! and its releases, each due box read through the reader its `Where:`
//! names, for the watch's verifying duty and for `reconcile-items`. Only
//! the duty writes: a met box completes, a failed or inconclusive one takes
//! one comment. A Linear item is written through the linear package; a
//! GitHub item, which no package completes, on its issue: a met box ticked
//! in its body, the issue closed at its last open post-merge box.

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
use crate::ops::boxes;
use crate::settings::Settings;
use crate::state::Lane;
use crate::verify::Answer;
use crate::verify::wire::{IssueComment, IssueText, Job, Nullable, Pull, RunConclusion, RunStatus};
use crate::watch::github::IssueItem;
use crate::watch::tracker::{Shared, VerifyingItem};
use crate::watch::{Body, Change, Event, Produced, Runner, Tick};

/// The trackerless lane keys reserved by verify.md's Reading lanes route.
pub(super) fn is_reading_lane(item: &str) -> bool {
    item.starts_with("verify-")
}

/// Read the original item's comments before a failed reader is woken.
/// The verification workflow owns the comment format and all completion.
pub(super) fn reading_lane_has_result(
    settings: &Settings,
    lane: &Lane,
) -> std::result::Result<bool, String> {
    let (item, number) = lane
        .item
        .strip_prefix("verify-")
        .and_then(|key| key.rsplit_once("-box-"))
        .ok_or("reading lane key has no box")?;
    let number: u64 = number.parse().map_err(|_| "invalid reading lane box")?;
    let bodies = if let Some(github) = item.strip_prefix("gh-") {
        let repo = lane
            .repo
            .as_deref()
            .ok_or("reading lane has no GitHub repository")?;
        let issue: u64 = github
            .rsplit_once('-')
            .ok_or("reading lane key has no GitHub issue")?
            .1
            .parse()
            .map_err(|_| "invalid reading lane GitHub issue")?;
        let endpoint = format!("repos/{repo}/issues/{issue}/comments");
        let app_login = super::github::fleet_app_login(&settings.roots.project)?;
        let comments = super::github::handle(Path::new("gh"))
            .tagged(TAG)
            .bounded(BOUND)
            .list::<IssueComment>("verification-comments", &endpoint)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("gh api {endpoint}: comments unavailable"))?;
        comments
            .into_iter()
            .filter(|comment| {
                matches!(&comment.user, Nullable::Present(user)
                    if user.kind == "Bot" && user.login == app_login)
            })
            .filter_map(|comment| match comment.body {
                crate::verify::wire::Optional::Present(body) => Some(body),
                crate::verify::wire::Optional::Absent => None,
            })
            .collect()
    } else {
        match super::tracker::Linear::comment_bodies(&settings.reads.tracker_cli, item)
            .map_err(|error| error.to_string())?
        {
            super::tracker::Answered::Value(bodies) => bodies,
            super::tracker::Answered::Quota(_) => return Err("tracker-quota".to_owned()),
        }
    };
    let box_heading = format!("### Box {number}");
    let marker = format!("Reading lane: {}", lane.item);
    Ok(bodies
        .iter()
        .any(|body| reading_result(body, &box_heading, &marker)))
}

/// Both the reading lane marker and a result must belong to the same box
/// of the verification comment.
fn reading_result(body: &str, box_heading: &str, marker: &str) -> bool {
    let mut verification = false;
    let mut in_box = false;
    let mut lane = false;
    let mut result = false;
    for line in body.lines().map(str::trim) {
        if line.starts_with("## ") || line.starts_with("# ") {
            verification = line == "## Verification";
            in_box = false;
        } else if line.starts_with("### ") {
            in_box = verification && line == box_heading;
            lane = false;
            result = false;
        } else if in_box {
            lane |= line.trim_start_matches("- ") == marker;
            result |= line.strip_prefix("- **Result**:").is_some_and(|value| {
                matches!(value.trim(), "pass" | "fail" | "unread" | "waiting")
            });
            if lane && result {
                return true;
            }
        }
    }
    false
}

/// The baseline row kind this duty owns: `verifying-deadline <id>`, the
/// due keys joined by `|`, `-` with none due, `boxes=0` with no open box,
/// [`INVALID_ROW`] for an item its checklist leaves unjudged.
pub const DEADLINE_ROW: &str = "verifying-deadline";

/// The row value of an item read invalid.
const INVALID_ROW: &str = "invalid";

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

/// The second line of the watch's `verifying-invalid` message.
const INVALID_TEXT: &str = "The Verifying item has invalid post-merge metadata or an open branch-provable box. Correct its checklist before verification.";

/// The watch's `verifying-invalid` message for an item it could not judge,
/// then the judgement's own words, on this process's stderr.
fn say_invalid(id: &str, words: &str) {
    let _ = writeln!(
        std::io::stderr(),
        "verifying-invalid issue={id}\n{INVALID_TEXT}\n{words}"
    );
}

// --- the parser's reply ----------------------------------------------------------

/// `linear done-when parse`'s checklist (`done_when_parse`): the fields the
/// judgement reads.
#[derive(Debug, Clone, Deserialize)]
struct Parsed {
    /// The description with the boxes `--met` names ticked.
    description: String,
    /// How many open boxes `--met` ticked.
    ticked: u64,
    boxes: Vec<ParsedBox>,
    errors: Vec<Value>,
    /// Every open box but the container's child box, which its closer
    /// ticks: on a container, an outcome still to move into a child.
    #[serde(default)]
    container_open_boxes: Vec<u64>,
    /// The boxes `issues complete` refuses while they stand: unchecked and
    /// not post-merge, and checked with no Evidence line.
    unmet_branch_boxes: Vec<u64>,
    missing_evidence_boxes: Vec<u64>,
}

impl Parsed {
    /// A post-merge box still owed its proof: open, or ticked with no
    /// Evidence line, which no completion takes as passed.
    fn post_merge_owed(&self, b: &ParsedBox) -> bool {
        b.post_merge && (!b.checked || self.missing_evidence_boxes.contains(&b.number))
    }
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
    #[serde(default)]
    numeric: Option<Numeric>,
}

/// The parse's reading of a numeric check, `FIGURE COMPARATOR VALUE UNIT`;
/// a reading with no comparator is an outcome check and has none.
#[derive(Debug, Clone, PartialEq, Deserialize)]
struct Numeric {
    comparator: String,
    value: f64,
    #[serde(default)]
    unit: Option<String>,
}

/// What the watch read for a due or overdue box through the reader its
/// `Where:` names.
#[derive(Debug, Clone, PartialEq)]
enum Reading {
    /// The observed figure holds the pass condition.
    Met(u64),
    /// The observed figure breaks it.
    Failed(u64),
    /// The source has not produced the figure yet.
    Missing,
    /// The source ended with no figure to judge: its conclusion word.
    Inconclusive(&'static str),
    /// No reader the check names reaches it: the cause word.
    Unread(&'static str),
}

impl Reading {
    fn kind(&self) -> &'static str {
        match self {
            Reading::Met(_) => "met",
            Reading::Failed(_) => "failed",
            Reading::Missing => "missing",
            Reading::Inconclusive(_) => "inconclusive",
            Reading::Unread(_) => "unread",
        }
    }

    /// The line's fields: ` read=<kind>`, then ` observed=<figure>` where a
    /// figure was read or ` cause=<word>` where none was.
    fn fields(&self) -> String {
        match self {
            Reading::Met(figure) | Reading::Failed(figure) => {
                format!(" read={} observed={figure}", self.kind())
            }
            Reading::Missing => " read=missing".to_owned(),
            Reading::Inconclusive(word) | Reading::Unread(word) => {
                format!(" read={} cause={word}", self.kind())
            }
        }
    }
}

/// The tracker write a box's reading owes, made once when its due key is
/// new: a met box completes with its Evidence line, a failed or
/// inconclusive one takes one comment.
pub(super) enum Owed {
    Complete {
        number: u64,
        evidence: String,
        /// The merge the boxes count from, where the item's boxes read it.
        merged_at: Option<String>,
    },
    Comment {
        text: String,
    },
}

/// One box under judgement.
#[derive(Debug, Clone, PartialEq)]
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
    numeric: Option<Numeric>,
    /// A due or overdue box's reading.
    read: Option<Reading>,
}

impl Judged {
    fn needs_merge(&self) -> bool {
        self.trigger_kind == "release"
            || (self.trigger_kind == "merge" && self.deadline_hours.is_some())
    }

    /// The `verifying` line a reader of the watch log and of
    /// `reconcile-items`' `result.lines` parses, its fields in this order.
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
            "verifying {id} box={} trigger={} status={} deadline={}{merged} blocked_by={blocked} reading={} where={} why={}{}",
            self.number,
            json_text(&self.trigger),
            self.status,
            self.deadline.as_deref().unwrap_or("-"),
            json_text(&self.reading),
            json_text(&self.where_),
            json_text(&self.why),
            self.read.as_ref().map(Reading::fields).unwrap_or_default()
        )
    }

    fn due_key(&self) -> String {
        format!(
            "box={} trigger={} status={} deadline={}{}",
            self.number,
            json_text(&self.trigger),
            self.status,
            self.deadline.as_deref().unwrap_or("null"),
            self.read
                .as_ref()
                .map(|r| format!(" read={}", r.kind()))
                .unwrap_or_default()
        )
    }

    /// The write this box's reading owes, observed at `at` (UTC).
    fn owed(&self, at: &str, merged: Option<&Merge>) -> Option<Owed> {
        let numeric = self.numeric.as_ref()?;
        let unit = numeric.unit.as_deref().unwrap_or_default();
        let pass = format!("{} {} {unit}", numeric.comparator, numeric.value);
        let source = format!("from {} at {at}", self.where_);
        match self.read.as_ref()? {
            Reading::Met(figure) => Some(Owed::Complete {
                number: self.number,
                evidence: format!("{figure} {unit} {pass} {source}"),
                merged_at: merged.map(|m| clock::iso_utc(m.at)),
            }),
            Reading::Failed(figure) => {
                let observed = format!("{figure} {unit}");
                let observed = observed.trim_end();
                let needs = pass.trim_end();
                Some(self.verification_comment(
                    at,
                    &format!("it read {observed}, and it needs {needs}"),
                    "fail",
                    &format!("observed {observed} against {needs}"),
                    "the reading breaks the pass condition",
                ))
            }
            Reading::Inconclusive(word) => Some(self.verification_comment(
                at,
                &format!("its source ended `{word}` with no figure to judge"),
                "unread",
                &format!("the source ended `{word}` with no figure"),
                "there is no figure to judge",
            )),
            Reading::Missing | Reading::Unread(_) => None,
        }
    }

    /// The one comment a failed or inconclusive reading takes, in the
    /// overseer's verification comment form (`oversee-events.md`
    /// § Verification comment): the result for the person first, then the
    /// reading as record fields, then the `read-by=watch` marker.
    fn verification_comment(
        &self,
        at: &str,
        outcome: &str,
        result: &str,
        evidence: &str,
        kept: &str,
    ) -> Owed {
        let deadline = self
            .deadline
            .as_deref()
            .map(|d| format!(", deadline {d}"))
            .unwrap_or_default();
        Owed::Comment {
            text: format!(
                "The post-merge check `{check}` did not pass: {outcome}. The box stays open, and the item with it.\n\n\
                 ## Verification\n\n\
                 **Reader**: the watch\n\n\
                 **Observed at**: {at}\n\n\
                 ### Box {number}\n\n\
                 - **Result**: {result}\n\
                 - **Evidence**: {evidence}, from {where_}\n\
                 - **Decision**: kept open, since {kept}\n\
                 - **Next**: the overseer takes the box through its verify workflow{deadline}\n\n\
                 read-by=watch\n",
                check = self.reading,
                number = self.number,
                where_ = self.where_,
            ),
        }
    }
}

/// jq's `tojson` of a string.
fn json_text(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_owned())
}

/// The boxes the item is judged on, or `None` for an
/// item the parser cannot read as Verifying (branch work open, a malformed
/// box). Where `merge_proves_branch`, a GitHub item's, an open branch box
/// is no branch work open: no completion ticks it in the issue's body,
/// and the merged pull request's evidence proves it. Its ticked post-merge
/// box with no Evidence line is invalid, since the watch closes the issue
/// on its boxes itself.
fn judged_boxes(
    parsed: &Parsed,
    container: bool,
    merge_proves_branch: bool,
) -> Option<Vec<Judged>> {
    let rows: Vec<&ParsedBox> = if container {
        parsed
            .boxes
            .iter()
            .filter(|b| parsed.container_open_boxes.contains(&b.number))
            .collect()
    } else {
        let branch_open = !parsed.boxes.iter().all(|b| b.checked || b.post_merge);
        let unproved = parsed
            .boxes
            .iter()
            .any(|b| b.checked && parsed.post_merge_owed(b));
        if !parsed.errors.is_empty()
            || (branch_open && !merge_proves_branch)
            || (unproved && merge_proves_branch)
        {
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
                        numeric: None,
                        read: None,
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
                        numeric: b.numeric.clone(),
                        read: None,
                    }
                }
            })
            .collect(),
    )
}

// --- the reads -------------------------------------------------------------------------

/// One release of `GET /repos/{owner}/{repo}/releases`.
#[derive(Debug, Deserialize)]
struct Release {
    #[serde(default)]
    tag_name: Nullable<String>,
    #[serde(default)]
    published_at: Nullable<String>,
    draft: Nullable<bool>,
}

/// `gh api <path>` through the one handle under the duty's tag; the
/// parsed JSON, or the failure's words. The pass's reads are kept in
/// `read`, so one merge or release page is read once per pass.
fn gh_json(
    gh: &Path,
    path: &str,
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<Value, String> {
    if let Some(value) = read.get(path) {
        return Ok(value.clone());
    }
    let answer = super::github::handle(gh)
        .tagged(TAG)
        .bounded(BOUND)
        .run("api", &["api", path], None)
        .map_err(|unrun| unrun.detail())?;
    let stdout = match answer {
        Answer::Printed { stdout, .. } => stdout,
        Answer::Failed(failed) => return Err(format!("gh api {path}: {}", failed.stderr.trim())),
    };
    let value: Value =
        serde_json::from_slice(&stdout).map_err(|e| format!("gh api {path}: {e}"))?;
    read.insert(path.to_owned(), value.clone());
    Ok(value)
}

/// The linear CLI's parser on `description`, `tick` its `--met` options
/// where a box is ticked: the parse with the parser's own words, or the
/// call's failure. A parser that never starts refuses `missing-linear`.
#[allow(
    clippy::disallowed_methods,
    reason = "the verification duty's calls of the linear CLI's own Done-when parser through the one runner under its tag, one per item and one per GitHub item's box it ticks; it reads nothing"
)]
fn parse(
    settings: &Settings,
    description: &str,
    tick: &[&str],
) -> Result<std::result::Result<(Parsed, String), String>> {
    let cli = &settings.reads.tracker_cli;
    let mut args = vec!["done-when", "parse", "--description", description];
    args.extend(tick);
    let out = match host::run_tagged(TAG, "linear", cli, "done-when", &args, BOUND) {
        Ok(out) => out,
        Err(agent_runtime::Error::NotStarted { cause, .. }) => {
            return Err(agent_runtime::Error::refused(
                "missing-linear",
                &[("path", &cli.display().to_string()), ("cause", &cause)],
            )
            .into());
        }
        Err(e) => return Err(e.into()),
    };
    if !out.status.success() {
        return Ok(Err(format!(
            "done-when parse exit={}: {}",
            out.status.code().unwrap_or(-1),
            host::stderr_text(&out).trim()
        )));
    }
    let text = host::stdout_text(&out).trim_end().to_owned();
    Ok(serde_json::from_str::<Parsed>(&text)
        .map(|parsed| (parsed, text))
        .map_err(|e| format!("done-when parse: {e}")))
}

/// The boxes of `description`'s checklist the completion command refuses
/// on, by its own parser, for the close's completion of a merged item; `Err`
/// is the cause word of a parse that failed or a checklist it read errors
/// in.
pub(crate) fn open_branch_boxes(
    settings: &Settings,
    description: &str,
) -> std::result::Result<Vec<u64>, &'static str> {
    match parse(settings, description, &[]) {
        Ok(Ok((parsed, _))) if parsed.errors.is_empty() => {
            let mut boxes: Vec<u64> = parsed
                .unmet_branch_boxes
                .into_iter()
                .chain(parsed.missing_evidence_boxes)
                .collect();
            boxes.sort_unstable();
            boxes.dedup();
            Ok(boxes)
        }
        Ok(Ok(_)) => Err("checklist-invalid"),
        Ok(Err(_)) | Err(_) => Err("checklist-unparsed"),
    }
}

/// The merge an item's boxes count from: its epoch second and, per
/// repository (lowercased), the merge commit where the pull request names
/// one that is a full object name.
struct Merge {
    at: u64,
    oids: BTreeMap<String, Option<String>>,
}

/// The merge an item's boxes count from: the latest
/// `merged_at` among the merged index's keys for it, and the merge commit
/// of each repository's latest merge. `None` where the index names no key:
/// unread for a box that needs it.
fn merge_of(
    gh: &Path,
    keys: &[String],
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<Option<Merge>, String> {
    // Each repository's commit is its latest merge's, whatever order the
    // keys arrive in: a search answers best match first.
    let mut latest: BTreeMap<String, (u64, Option<String>)> = BTreeMap::new();
    for key in keys {
        let Some((repo, number)) = key.split_once('#') else {
            return Err(format!("merged key {key}: no number"));
        };
        let path = format!("repos/{repo}/pulls/{number}");
        let value = gh_json(gh, &path, read)?;
        let pull: Pull = serde_json::from_value(value).map_err(|e| format!("{path}: {e}"))?;
        let at = match &pull.merged_at {
            Nullable::Present(stamp) => {
                clock::epoch_secs(stamp).ok_or_else(|| format!("{path}: merged_at {stamp}"))?
            }
            Nullable::Absent | Nullable::Null => continue,
        };
        let repo = repo.to_ascii_lowercase();
        if latest.get(&repo).is_some_and(|(stored, _)| *stored >= at) {
            continue;
        }
        let oid = match &pull.merge_commit_sha {
            Nullable::Present(oid)
                if oid.len() == 40 && oid.bytes().all(|b| b.is_ascii_hexdigit()) =>
            {
                Some(oid.clone())
            }
            Nullable::Present(_) | Nullable::Absent | Nullable::Null => None,
        };
        latest.insert(repo, (at, oid));
    }
    let at = latest.values().map(|(at, _)| *at).max();
    let oids = latest
        .into_iter()
        .map(|(repo, (_, oid))| (repo, oid))
        .collect();
    Ok(at.map(|at| Merge { at, oids }))
}

/// A bash pattern (`[[ $tag == $glob ]]`): `*`, `?`, a bracket expression
/// and a backslash quoting the next character. Extended patterns are not
/// read: bash reads them there on some hosts and not on others.
fn glob_matches(glob: &str, text: &str) -> bool {
    fn go(g: &[char], t: &[char]) -> bool {
        match g.split_first() {
            None => t.is_empty(),
            Some(('*', rest)) => (0..=t.len()).any(|i| go(rest, &t[i..])),
            Some(('?', rest)) => !t.is_empty() && go(rest, &t[1..]),
            Some(('[', rest)) => match t.first().map(|c| (c, bracket(rest, *c))) {
                Some((_, Some((hit, len)))) => hit && go(&rest[len..], &t[1..]),
                Some((c, None)) => *c == '[' && go(rest, &t[1..]),
                None => false,
            },
            Some(('\\', [quoted, rest @ ..])) => t.first() == Some(quoted) && go(rest, &t[1..]),
            Some((c, rest)) => t.first() == Some(c) && go(rest, &t[1..]),
        }
    }
    let g: Vec<char> = glob.chars().collect();
    let t: Vec<char> = text.chars().collect();
    go(&g, &t)
}

/// The bracket expression `g` opens, past its `[`, against `c`: whether it
/// holds `c` and how many characters it spans with its `]`; `None` where no
/// `]` closes it, so the `[` is itself. A leading `!` or `^` negates it, a
/// `]` first in it is itself, as is a `-` that ends a range nowhere.
fn bracket(g: &[char], c: char) -> Option<(bool, usize)> {
    let negated = matches!(g.first(), Some('!' | '^'));
    let mut i = usize::from(negated);
    let start = i;
    let mut hit = false;
    loop {
        let x = *g.get(i)?;
        if x == ']' && i > start {
            return Some((hit != negated, i + 1));
        }
        if x == '[' && g.get(i + 1) == Some(&':') {
            let name_end =
                (i + 2..g.len().saturating_sub(1)).find(|&j| g[j] == ':' && g[j + 1] == ']');
            if let Some(end) = name_end {
                let name: String = g[i + 2..end].iter().collect();
                hit |= class_holds(&name, c);
                i = end + 2;
                continue;
            }
        }
        let (low, next) = match x {
            '\\' => (*g.get(i + 1)?, i + 2),
            _ => (x, i + 1),
        };
        match (g.get(next), g.get(next + 1)) {
            (Some('-'), Some(&high)) if high != ']' => {
                let (high, after) = match high {
                    '\\' => (*g.get(next + 2)?, next + 3),
                    _ => (high, next + 2),
                };
                hit |= (low..=high).contains(&c);
                i = after;
            }
            _ => {
                hit |= low == c;
                i = next;
            }
        }
    }
}

/// A `[:name:]` class of a bracket expression; a name bash has no class
/// for holds nothing.
fn class_holds(name: &str, c: char) -> bool {
    match name {
        "alnum" => c.is_alphanumeric(),
        "alpha" => c.is_alphabetic(),
        "ascii" => c.is_ascii(),
        "blank" => c == ' ' || c == '\t',
        "cntrl" => c.is_control(),
        "digit" => c.is_ascii_digit(),
        "graph" => !c.is_control() && !c.is_whitespace(),
        "lower" => c.is_lowercase(),
        "print" => !c.is_control(),
        "punct" => c.is_ascii_punctuation(),
        "space" => c.is_whitespace(),
        "upper" => c.is_uppercase(),
        "word" => c.is_alphanumeric() || c == '_',
        "xdigit" => c.is_ascii_hexdigit(),
        _ => false,
    }
}

/// The releases of `repo`, every page, as `(published epoch, tag)` for the
/// published ones.
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

/// The publication epoch of the first published release of `repo` after
/// `merge` whose tag `glob` matches and, where the merge names its commit
/// in `repo`, that contains it.
fn release_after(
    gh: &Path,
    repo: &str,
    glob: &str,
    merge: &Merge,
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<Option<u64>, (&'static str, String)> {
    let oid = match merge.oids.get(&repo.to_ascii_lowercase()) {
        None => None,
        Some(Some(oid)) => Some(oid.clone()),
        Some(None) => return Err(("verifying-release-unread", format!("repo={repo}"))),
    };
    let listed = releases(gh, repo, read)
        .map_err(|cause| ("verifying-release-unread", format!("repo={repo} {cause}")))?;
    for (at, tag) in listed.into_iter().filter(|(at, _)| *at > merge.at) {
        if !glob_matches(glob, &tag) {
            continue;
        }
        if let Some(oid) = &oid {
            let path = format!(
                "repos/{repo}/compare/{oid}...{}",
                crate::verify::segment(&tag)
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
        return Ok(Some(at));
    }
    Ok(None)
}

/// The repository a `Where:` of exactly `https://github.com/O/R/<rest>`
/// names, with `<rest>` split on `/`.
fn github_locator(locator: &str) -> Option<(String, Vec<&str>)> {
    let path = locator.strip_prefix("https://github.com/")?;
    let mut parts = path.split('/');
    let repo = format!("{}/{}", parts.next()?, parts.next()?);
    crate::verify::validate_repo(&repo).ok()?;
    Some((repo, parts.collect()))
}

/// A box's reading through the reader its `Where:` names: a GitHub job
/// URL (the job's elapsed seconds) or a repository's releases page (1
/// where a release after the merge holds it, else 0). Any other source, a
/// check with no comparator and a unit the reader does not give answer
/// unread: no reader is invented for them.
fn read_box(
    gh: &Path,
    b: &Judged,
    merged: Option<&Merge>,
    read: &mut BTreeMap<String, Value>,
) -> Reading {
    let Some(numeric) = &b.numeric else {
        return Reading::Unread("no-reader");
    };
    let Some((repo, rest)) = github_locator(&b.where_) else {
        return Reading::Unread("no-reader");
    };
    let number = |word: &str| !word.is_empty() && word.bytes().all(|b| b.is_ascii_digit());
    let figure = match rest.as_slice() {
        ["actions", "runs", run, "job", job] if number(run) && number(job) => {
            if numeric.unit.as_deref() != Some("s") {
                return Reading::Unread("unit");
            }
            match job_seconds(gh, &repo, job, read) {
                Ok(seconds) => seconds,
                Err(reading) => return reading,
            }
        }
        ["releases"] => {
            let Some(merge) = merged else {
                return Reading::Unread("merge");
            };
            let glob = match &b.release {
                Some((named, glob)) if named.eq_ignore_ascii_case(&repo) => glob.as_str(),
                Some(_) | None => "*",
            };
            // No release yet is missing until the deadline, then compared.
            match release_after(gh, &repo, glob, merge, read) {
                Ok(Some(_)) => 1,
                Ok(None) if b.status == "due" => return Reading::Missing,
                Ok(None) => 0,
                Err(_) => return Reading::Unread("read-failed"),
            }
        }
        _ => return Reading::Unread("no-reader"),
    };
    #[allow(
        clippy::cast_precision_loss,
        reason = "a job's seconds and a release count are far below 2^53"
    )]
    let observed = figure as f64;
    let holds = match numeric.comparator.as_str() {
        "<=" => observed <= numeric.value,
        ">=" => observed >= numeric.value,
        "<" => observed < numeric.value,
        ">" => observed > numeric.value,
        "=" => (observed - numeric.value).abs() < f64::EPSILON,
        _ => return Reading::Unread("comparator"),
    };
    if holds {
        Reading::Met(figure)
    } else {
        Reading::Failed(figure)
    }
}

/// A completed, successful job's elapsed whole seconds, or the reading its
/// state answers.
fn job_seconds(
    gh: &Path,
    repo: &str,
    job: &str,
    read: &mut BTreeMap<String, Value>,
) -> std::result::Result<u64, Reading> {
    let path = format!("repos/{repo}/actions/jobs/{job}");
    let value = gh_json(gh, &path, read).map_err(|_| Reading::Unread("read-failed"))?;
    let job: Job = serde_json::from_value(value).map_err(|_| Reading::Unread("job-fields"))?;
    if job.status != RunStatus::Completed {
        return Err(Reading::Missing);
    }
    match job.conclusion {
        Nullable::Present(RunConclusion::Success) => {}
        Nullable::Present(other) => return Err(Reading::Inconclusive(other.word())),
        Nullable::Absent | Nullable::Null => return Err(Reading::Inconclusive("none")),
    }
    let Nullable::Present(completed) = &job.completed_at else {
        return Err(Reading::Unread("job-fields"));
    };
    match (
        clock::epoch_secs(&job.started_at),
        clock::epoch_secs(completed),
    ) {
        (Some(started), Some(completed)) if completed >= started => Ok(completed - started),
        _ => Err(Reading::Unread("job-fields")),
    }
}

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
        let Some(merge) = merged else {
            return Err(("verifying-merge-unread", String::new()));
        };
        b.trigger_epoch = release_after(gh, &repo, &glob, merge, read)?;
        b.merged = Some(clock::iso_utc(merge.at));
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
        // A recorded open blocker holds the box past its deadline too: the
        // check waits on the blocker, not on a date.
        b.status = if blocked {
            "blocked"
        } else if b.deadline_epoch.is_some_and(|d| d <= now) {
            "overdue"
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

#[derive(Debug, Default, serde::Serialize)]
pub(super) struct Counts {
    pub due: u64,
    pub overdue: u64,
    pub blocked: u64,
    pub waiting: u64,
    pub met: u64,
    pub failed: u64,
    pub inconclusive: u64,
    pub missing: u64,
    pub unread: u64,
}

pub(super) enum Item {
    /// The lines and the row key, with the due keys the event lines carry
    /// and the write each due key's reading owes.
    Read {
        lines: Vec<String>,
        key: String,
        due: Vec<(String, bool)>,
        counts: Counts,
        owed: BTreeMap<String, Owed>,
    },
    /// Unread this pass: the prior row stands.
    Unread { key: &'static str, cause: String },
    /// Invalid: no row, the pass goes on; `evidence` is the parser's reply.
    Invalid { evidence: String },
    /// The parser gave no checklist (it failed, or its reply did not
    /// decode): an invalid item to the watch, whose pass goes on; a
    /// refusal to the reconciliation verb, whose required input is unread.
    Unparsed { cause: String },
}

/// The one site of a GitHub item's repository rule: its boxes' readings
/// are published on the issue in `issue_repo`, so no other repository is
/// read under the watch's credential. A box whose `Where:` names another
/// reads `unread`, and comes due for a reading by hand. A release trigger
/// naming another could never fire, so it is the checklist's refusal, the
/// cause words of a `verifying-invalid` item. A Linear item's boxes
/// (`None`) read any repository.
fn own_repository_only(
    boxes: &mut [Judged],
    issue_repo: Option<&str>,
) -> std::result::Result<(), String> {
    let Some(own) = issue_repo else {
        return Ok(());
    };
    let other = |repo: &str| !repo.eq_ignore_ascii_case(own);
    for b in boxes.iter_mut() {
        if let Some((repo, _)) = b.release.as_ref().filter(|(repo, _)| other(repo)) {
            return Err(format!(
                "box={} rule=release-trigger-repository repo={repo} own={own}",
                b.number
            ));
        }
        if github_locator(&b.where_).is_some_and(|(repo, _)| other(&repo)) {
            b.read = Some(Reading::Unread("no-reader"));
        }
    }
    Ok(())
}

/// `issue_repo` is a GitHub item's repository: its merge proves its
/// branch boxes ([`judged_boxes`]) and its boxes read it alone
/// ([`own_repository_only`]).
pub(super) fn judge_item(
    ctx: &Context,
    item: &VerifyingItem,
    issue_repo: Option<&str>,
    merged_keys: Option<&[String]>,
    now: u64,
    read: &mut BTreeMap<String, Value>,
) -> Result<Item> {
    let (parsed, evidence) = match parse(&ctx.settings, &item.description, &[])? {
        Ok(parsed) => parsed,
        Err(cause) => return Ok(Item::Unparsed { cause }),
    };
    let Some(mut boxes) = judged_boxes(&parsed, item.container, issue_repo.is_some()) else {
        return Ok(Item::Invalid { evidence });
    };
    if let Err(evidence) = own_repository_only(&mut boxes, issue_repo) {
        return Ok(Item::Invalid { evidence });
    }
    let reads_releases = |b: &Judged| {
        github_locator(&b.where_).is_some_and(|(_, rest)| rest.as_slice() == ["releases"])
    };
    let merged = if boxes.iter().any(|b| b.needs_merge() || reads_releases(b)) {
        match merge_of(&ctx.gh, merged_keys.unwrap_or(&[]), read) {
            Ok(merged) => merged,
            Err(cause) => {
                return Ok(Item::Unread {
                    key: "verifying-merge-unread",
                    cause,
                });
            }
        }
    } else {
        None
    };
    let blocked = &item.blocked_by_open;
    if let Err((key, cause)) = judge(
        &ctx.gh,
        &mut boxes,
        merged.as_ref(),
        !blocked.is_empty(),
        now,
        read,
    ) {
        return Ok(Item::Unread { key, cause });
    }
    let at = clock::iso_utc(now);
    let mut owed = BTreeMap::new();
    let mut due = Vec::new();
    for b in boxes
        .iter_mut()
        .filter(|b| b.status == "due" || b.status == "overdue")
    {
        if b.read.is_none() {
            b.read = Some(read_box(&ctx.gh, b, merged.as_ref(), read));
        }
        let key = b.due_key();
        if let Some(write) = b.owed(&at, merged.as_ref()) {
            owed.insert(key.clone(), write);
        }
        let read_failed = matches!(b.read, Some(Reading::Unread("read-failed" | "job-fields")));
        due.push((key, read_failed));
    }
    let mut lines: Vec<String> = boxes.iter().map(|b| b.line(&item.id, blocked)).collect();
    let key = if lines.is_empty() {
        lines.push(format!("verifying {} boxes=0", item.id));
        "boxes=0".to_owned()
    } else {
        "-".to_owned()
    };
    let mut counts = Counts::default();
    for b in &boxes {
        match b.status {
            "due" => counts.due += 1,
            "overdue" => counts.overdue += 1,
            "blocked" => counts.blocked += 1,
            "waiting" => counts.waiting += 1,
            _ => unreachable!("the box judge assigns one status"),
        }
        match &b.read {
            Some(Reading::Met(_)) => counts.met += 1,
            Some(Reading::Failed(_)) => counts.failed += 1,
            Some(Reading::Inconclusive(_)) => counts.inconclusive += 1,
            Some(Reading::Missing) => counts.missing += 1,
            Some(Reading::Unread(_)) => counts.unread += 1,
            None => {}
        }
    }
    Ok(Item::Read {
        lines,
        key,
        due,
        counts,
        owed,
    })
}

/// Make the write a new due key's reading owes, on `issue` for a GitHub
/// item, `judged` the body its boxes were judged on; its note goes to
/// stderr. A refused Linear write is not retried: the key stands in the
/// row, and the due event hands the box to the verify pass. A GitHub
/// item's met box is written again on each pass that reads it met, since
/// its ticked body is the only record of it. Return the settlement for
/// that GitHub tick so the caller can retain or update its mark.
fn write_owed(
    ctx: &Context,
    id: &str,
    issue: Option<&IssueItem>,
    judged: &str,
    owed: &Owed,
) -> Option<IssueSettlement> {
    let (settled, note) = match (owed, issue) {
        (
            Owed::Complete {
                number,
                evidence,
                merged_at,
            },
            None,
        ) => (
            None,
            format!(
                "box={number} {}",
                boxes::complete_reading(&ctx.settings, id, merged_at.as_deref(), *number, evidence)
            ),
        ),
        (Owed::Comment { text }, None) => (
            None,
            format!("comment={}", boxes::post(&ctx.settings, id, text)),
        ),
        (
            Owed::Complete {
                number,
                evidence,
                merged_at,
            },
            Some(issue),
        ) => {
            let met = Met {
                number: *number,
                evidence,
                merged_at: merged_at.as_deref(),
            };
            let (settled, note) = settle_issue(ctx, issue, judged, Some(&met));
            (Some(settled), format!("box={number} {note}"))
        }
        (Owed::Comment { text }, Some(issue)) => {
            let path = format!("repos/{}/issues/{}/comments", issue.repo, issue.number);
            let (_, note) =
                issue_write(&ctx.gh, "POST", &path, &serde_json::json!({ "body": text }));
            (None, format!("comment={note}"))
        }
    };
    let _ = writeln!(std::io::stderr(), "verifying-write issue={id} {note}");
    settled
}

/// A met box's tick: its number, its Evidence line and the merge its
/// deadline counts from.
struct Met<'a> {
    number: u64,
    evidence: &'a str,
    merged_at: Option<&'a str>,
}

enum IssueSettlement {
    BodyUnconfirmed,
    LeftOpen,
    Close(IssueWrite),
}

/// A GitHub item's issue settled on the body read now, and only while it
/// is the open body `judged` was: a body edited since may number its boxes
/// otherwise, and the next pass judges it again. `met`'s box is ticked by
/// the box parser, which writes its Evidence line; the issue closes as
/// completed once no post-merge box stays open. A changed or unreadable
/// body leaves a prior close possible.
fn settle_issue(
    ctx: &Context,
    issue: &IssueItem,
    judged: &str,
    met: Option<&Met<'_>>,
) -> (IssueSettlement, String) {
    let unwritten = |state, cause: &str| (state, format!("issue-unwritten cause={cause}"));
    let path = format!("repos/{}/issues/{}", issue.repo, issue.number);
    let live = gh_json(&ctx.gh, &path, &mut BTreeMap::new())
        .and_then(|v| serde_json::from_value::<IssueText>(v).map_err(|e| e.to_string()));
    let body = match live {
        Ok(IssueText {
            state,
            body: Nullable::Present(body),
            ..
        }) if state == "open" && body == judged => body,
        Ok(_) => return unwritten(IssueSettlement::BodyUnconfirmed, "moved"),
        Err(e) => {
            return unwritten(
                IssueSettlement::BodyUnconfirmed,
                &format!("read-failed error={}", one_line(&e)),
            );
        }
    };
    let left_open = |cause: &str| unwritten(IssueSettlement::LeftOpen, cause);
    let mut patch = serde_json::Map::new();
    let open_left = match met {
        None => false,
        Some(met) => {
            let number = met.number.to_string();
            let mut tick = vec!["--met", number.as_str(), "--evidence", met.evidence];
            if let Some(at) = met.merged_at {
                tick.extend(["--merged-at", at]);
            }
            let ticked = match parse(&ctx.settings, &body, &tick) {
                Ok(Ok((parsed, _))) if parsed.ticked == 1 && parsed.errors.is_empty() => parsed,
                Ok(Ok((parsed, _))) if parsed.ticked != 1 => return left_open("box-not-open"),
                Ok(Ok(_)) => return left_open("checklist-invalid"),
                Ok(Err(e)) => return left_open(&format!("tick-unparsed error={}", one_line(&e))),
                Err(e) => {
                    return left_open(&format!("tick-unrun error={}", one_line(&e.to_string())));
                }
            };
            let open_left = ticked.boxes.iter().any(|b| ticked.post_merge_owed(b));
            patch.insert("body".to_owned(), ticked.description.into());
            open_left
        }
    };
    if !open_left {
        patch.insert("state".to_owned(), "closed".into());
        patch.insert("state_reason".to_owned(), "completed".into());
    }
    let (write, note) = issue_write(&ctx.gh, "PATCH", &path, &Value::Object(patch));
    let settled = if open_left {
        IssueSettlement::LeftOpen
    } else {
        IssueSettlement::Close(write)
    };
    (settled, format!("closed={} issue={note}", !open_left))
}

enum IssueWrite {
    Written,
    Refused,
    Unknown,
}

/// One GitHub write of `input` on `path`: `written`; `failed` where gh
/// confirmed rejection or never ran, `unknown` where the write could have landed,
/// each with what gh or the runner said.
fn issue_write(gh: &Path, method: &'static str, path: &str, input: &Value) -> (IssueWrite, String) {
    let input = input.to_string();
    let args = ["api", path, "--method", method, "--input", "-"];
    match super::github::handle(gh).tagged(TAG).bounded(BOUND).run(
        "issue-write",
        &args,
        Some(input.as_bytes()),
    ) {
        Ok(Answer::Printed { .. }) => (IssueWrite::Written, "written".to_owned()),
        Ok(Answer::Failed(failed))
            if failed.sign_in_refused() || crate::verify::refused_by_github(&failed.stderr) =>
        {
            (
                IssueWrite::Refused,
                format!("failed error={}", one_line(&failed.detail())),
            )
        }
        Ok(Answer::Failed(failed)) => (
            IssueWrite::Unknown,
            format!("unknown error={}", one_line(&failed.detail())),
        ),
        Err(crate::verify::Unrun::Runner(e @ agent_runtime::Error::NotStarted { .. })) => (
            IssueWrite::Refused,
            format!("failed error={}", one_line(&e.to_string())),
        ),
        Err(unrun) => (
            IssueWrite::Unknown,
            format!("unknown error={}", one_line(&unrun.detail())),
        ),
    }
}

/// `text` on one line, as a note's last field carries it.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn reading_of(row: &str) -> (&str, &str) {
    row.rsplit_once(" read=").unwrap_or((row, ""))
}

fn prior_owes_issue_close(row: &str) -> bool {
    // The watch can tick and close in one PATCH when just one box is open.
    // Its lone met row can outlive that close if the issue is reopened.
    let (deadline, reading) = reading_of(row);
    row != "boxes=0" && (reading != "met" || deadline.contains(" read="))
}

fn box_deadline(row: &str) -> Option<(&str, &str)> {
    let (trigger, tail) = reading_of(row).0.rsplit_once(" status=")?;
    Some((trigger, tail.split_once(" deadline=")?.1))
}

/// Whether a row's item is a GitHub item, keyed `<repo>#<n>`
/// ([`IssueItem`]): no Linear identifier holds a `#`.
fn issue_key(identity: &str) -> bool {
    identity.contains('#')
}

fn run(ctx: &Context, tick: &Tick) -> Result<Produced> {
    let (items, merged_index, tracker_read, github_read) = {
        let latest = ctx.shared.lock().unwrap_or_else(|p| p.into_inner());
        let mut items: Vec<(VerifyingItem, Option<IssueItem>)> = latest
            .tracker
            .iter()
            .flat_map(|t| t.verifying.iter().map(|item| (item.clone(), None)))
            .chain(latest.github.iter().flat_map(|g| {
                g.verifying
                    .iter()
                    .map(|i| (i.item.clone(), Some(i.clone())))
            }))
            .collect();
        items.sort_by(|a, b| a.0.id.cmp(&b.0.id));
        let index = latest
            .github
            .as_ref()
            .map(|g| g.merged.clone())
            .unwrap_or_default();
        (
            items,
            index,
            latest.tracker.is_some(),
            latest.github.is_some(),
        )
    };
    if !tracker_read && !github_read {
        // Nothing read yet: nothing to judge.
        return Ok(Produced::default());
    }
    let mut produced = Produced::default();
    let mut event_lines: Vec<String> = Vec::new();
    let mut all_lines = Vec::new();
    let mut held: BTreeSet<String> = BTreeSet::new();
    let mut read: BTreeMap<String, Value> = BTreeMap::new();
    for (item, issue) in &items {
        let judged = judge_item(
            ctx,
            item,
            issue.as_ref().map(|i| i.repo.as_str()),
            merged_index.get(&item.id).map(Vec::as_slice),
            tick.wall,
            &mut read,
        )?;
        let prior = tick.baseline.get(DEADLINE_ROW, &item.id);
        match judged {
            Item::Invalid { evidence } => {
                say_invalid(
                    &item.id,
                    &format!("verifying-invalid issue={}\n{evidence}", item.id),
                );
                // The row stands while the item reads invalid, so a stuck
                // item is named once, not on every pass.
                held.insert(item.id.clone());
                if prior != Some(INVALID_ROW) {
                    produced.events.push(Event::VerifyingInvalid {
                        id: item.id.clone(),
                    });
                    produced.changes.push(Change::Set {
                        kind: DEADLINE_ROW.to_owned(),
                        identity: item.id.clone(),
                        value: INVALID_ROW.to_owned(),
                    });
                }
            }
            Item::Unparsed { cause } => {
                say_invalid(&item.id, &cause);
                if prior.is_some_and(|row| row.starts_with("box=")) {
                    held.insert(item.id.clone());
                }
            }
            Item::Unread { key, cause } => {
                let words = format!("{key} issue={} {cause}", item.id);
                say_invalid(&item.id, words.trim_end());
                // An unread item cannot clear a previously reported deadline.
                if prior.is_some() {
                    held.insert(item.id.clone());
                }
            }
            Item::Read {
                lines,
                key,
                due,
                owed,
                ..
            } => {
                held.insert(item.id.clone());
                all_lines.extend(lines.iter().cloned());
                // A GitHub item closes on the pass that reads its last open
                // post-merge box gone if its prior row still calls for
                // closure. Keep that row on refusal so the close is retried.
                if let Some(issue) = issue
                    && key == "boxes=0"
                    && prior.is_some_and(prior_owes_issue_close)
                {
                    let (close, note) = settle_issue(ctx, issue, &item.description, None);
                    let _ = writeln!(
                        std::io::stderr(),
                        "verifying-write issue={} {note}",
                        item.id
                    );
                    if !matches!(close, IssueSettlement::Close(IssueWrite::Written)) {
                        continue;
                    }
                }
                if !due.is_empty() || prior != Some(key.as_str()) {
                    // The watch settles a GitHub item itself.
                    if key == "boxes=0" && issue.is_none() {
                        produced.events.push(Event::VerifyingDeadline {
                            id: item.id.clone(),
                            row: "boxes=0".to_owned(),
                        });
                        event_lines.extend(lines.iter().cloned());
                    }
                    let prior_keys = prior.unwrap_or_default().split('|');
                    let mut saved = Vec::new();
                    for (row, read_failed) in &due {
                        let box_word = row.split(' ').next().unwrap_or_default();
                        let old = prior_keys.clone().find(|key| {
                            if *read_failed {
                                key.split(' ').next() == Some(box_word)
                            } else {
                                box_deadline(key) == box_deadline(row)
                            }
                        });
                        if *read_failed {
                            saved.extend(old.map(str::to_owned));
                            continue;
                        }
                        let (previous, marked) = reading_of(old.unwrap_or_default());
                        let (deadline, reading) = reading_of(row);
                        if previous != deadline {
                            let prefix = format!("verifying {} {box_word} ", item.id);
                            event_lines
                                .extend(lines.iter().filter(|l| l.starts_with(&prefix)).cloned());
                            produced.events.push(Event::VerifyingDeadline {
                                id: item.id.clone(),
                                row: row.clone(),
                            });
                        }
                        let written = matches!(marked, "failed" | "inconclusive" | "met");
                        let mut mark = if written { marked } else { reading };
                        if let Some(write) = owed.get(row).filter(|write| match write {
                            Owed::Complete { .. } => marked != "met" || issue.is_some(),
                            Owed::Comment { .. } => !written,
                        }) {
                            mark = match write_owed(
                                ctx,
                                &item.id,
                                issue.as_ref(),
                                &item.description,
                                write,
                            ) {
                                Some(IssueSettlement::BodyUnconfirmed) => marked,
                                Some(
                                    IssueSettlement::LeftOpen
                                    | IssueSettlement::Close(IssueWrite::Refused),
                                ) => {
                                    if marked == "met" {
                                        ""
                                    } else {
                                        marked
                                    }
                                }
                                Some(IssueSettlement::Close(
                                    IssueWrite::Written | IssueWrite::Unknown,
                                ))
                                | None => reading,
                            };
                        }
                        saved.push(format!("{deadline} read={mark}"));
                    }
                    let key = if due.is_empty() { key } else { saved.join("|") };
                    if key.is_empty() || prior == Some(key.as_str()) {
                        continue;
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
    // no longer Verifying goes, once its own source has been read.
    for identity in tick.baseline.identities(DEADLINE_ROW) {
        let read = if issue_key(&identity) {
            github_read
        } else {
            tracker_read
        };
        if read && !held.contains(&identity) {
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
            ("v[0-9]", "v1", true),
            ("v[0-9]", "va", false),
            ("v[0-9]", "v[0-9]", false),
            ("v[!0-9]", "vb", true),
            ("v[!0-9]", "v1", false),
            ("v[^0-9]", "vb", true),
            ("v[a-]", "v-", true),
            ("v[]]", "v]", true),
            ("v[", "v[", true),
            ("v[1", "v[1", true),
            ("v[1", "v1", false),
            ("v[ab", "vab", false),
            ("v\\*", "v*", true),
            ("v\\*", "vx", false),
            ("v[[:alpha:]]", "va", true),
            ("v[[:alpha:]]", "v1", false),
        ];
        for (glob, tag, want) in rows {
            assert_eq!(glob_matches(glob, tag), want, "{glob} {tag}");
        }
    }

    /// Two merges in one repository, in either key order: a release is
    /// judged from the later merge, its time and its commit, so a tag that
    /// holds the earlier delivery alone contains nothing.
    #[test]
    fn a_release_is_judged_from_the_latest_merge_in_either_key_order() {
        let gh = PathBuf::from("gh-never-run");
        let pull = |number: u64, at: &str, sha: &str| {
            serde_json::json!({"number": number, "state": "closed", "title": "t", "body": null,
                "merged_at": at, "merge_commit_sha": sha, "author_association": "OWNER",
                "base": {"ref": "main", "sha": "0123456789abcdef0123456789abcdef01234567"}, "user": null,
                "head": {"sha": "0000000000000000000000000000000000000000", "ref": "issue-7", "repo": null}})
        };
        let (older, newer) = ("a".repeat(40), "b".repeat(40));
        let answers = BTreeMap::from([
            (
                "repos/o/r/pulls/1".to_owned(),
                pull(1, "2026-10-01T00:00:00Z", &older),
            ),
            (
                "repos/o/r/pulls/2".to_owned(),
                pull(2, "2026-10-02T00:00:00Z", &newer),
            ),
            (
                "repos/o/r/releases?per_page=100&page=1".to_owned(),
                serde_json::json!([{"tag_name": "v2", "published_at": "2026-10-03T00:00:00Z", "draft": false}]),
            ),
            (
                format!("repos/o/r/compare/{older}...v2"),
                serde_json::json!({"status": "ahead"}),
            ),
            (
                format!("repos/o/r/compare/{newer}...v2"),
                serde_json::json!({"status": "behind"}),
            ),
        ]);
        for keys in [["o/r#1", "o/r#2"], ["o/r#2", "o/r#1"]] {
            let mut read = answers.clone();
            let keys = keys.map(str::to_owned);
            let merge = merge_of(&gh, &keys, &mut read).unwrap().unwrap();
            assert_eq!(
                merge.at,
                clock::epoch_secs("2026-10-02T00:00:00Z").unwrap(),
                "{keys:?}"
            );
            assert_eq!(
                release_after(&gh, "o/r", "v*", &merge, &mut read),
                Ok(None),
                "{keys:?}"
            );
        }
    }

    /// A GitHub item's box whose `Where:` names another repository reads
    /// `unread`, is read nowhere and owes no write; one whose release
    /// trigger does refuses the checklist, naming the box and the
    /// repository. The judge runs on a gh that cannot start, so any read
    /// would refuse the item. A Linear item's box keeps its trigger's
    /// repository.
    #[test]
    fn a_github_items_box_reads_its_own_repository_alone() {
        let gh = PathBuf::from("gh-never-run");
        let judged = |where_: &str, release: Option<&str>| Judged {
            number: 1,
            trigger: "release".to_owned(),
            trigger_kind: if release.is_some() {
                "release"
            } else {
                "merge"
            }
            .to_owned(),
            trigger_epoch: None,
            deadline_epoch: None,
            deadline_hours: None,
            deadline: None,
            reading: String::new(),
            where_: where_.to_owned(),
            why: String::new(),
            release: release.map(|repo| (repo.to_owned(), "v*".to_owned())),
            merged: None,
            status: "due",
            numeric: Some(Numeric {
                comparator: ">=".to_owned(),
                value: 1.0,
                unit: Some("release".to_owned()),
            }),
            read: None,
        };
        let merge = Merge {
            at: 50,
            oids: BTreeMap::new(),
        };
        let mut boxes = vec![judged("https://github.com/other/private/releases", None)];
        assert_eq!(own_repository_only(&mut boxes, Some("owner/repo")), Ok(()));
        let mut read = BTreeMap::new();
        assert_eq!(
            judge(&gh, &mut boxes, Some(&merge), false, 100, &mut read),
            Ok(())
        );
        assert_eq!(
            (boxes[0].status, &boxes[0].read),
            ("due", &Some(Reading::Unread("no-reader")))
        );
        assert!(
            read.is_empty()
                && boxes[0]
                    .owed("2026-10-02T00:00:00Z", Some(&merge))
                    .is_none()
        );
        let mut trigger = vec![judged(
            "https://github.com/Owner/Repo/releases",
            Some("other/private"),
        )];
        assert_eq!(
            own_repository_only(&mut trigger, Some("owner/repo")),
            Err(
                "box=1 rule=release-trigger-repository repo=other/private own=owner/repo"
                    .to_owned()
            )
        );
        own_repository_only(&mut trigger, None).unwrap();
        assert_eq!(
            (
                trigger[0].release.as_ref().map(|r| r.0.as_str()),
                &trigger[0].read
            ),
            (Some("other/private"), &None)
        );
    }

    #[test]
    fn a_blocker_precedes_a_past_deadline_and_overdue_precedes_unfired_triggers() {
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
            numeric: None,
            read: None,
        };
        let rows: Vec<(Judged, bool, &str)> = vec![
            (make("merge", None, Some(100)), true, "blocked"),
            (make("merge", None, Some(100)), false, "overdue"),
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
