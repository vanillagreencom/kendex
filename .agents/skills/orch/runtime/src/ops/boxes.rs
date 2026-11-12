//! A merged item's branch-provable Done-when boxes completed by the close
//! where its lane can no longer: the merged pull request's `## Done-when
//! evidence` section, the `N: text` lines the lane wrote before merge,
//! ticks the item's open branch boxes through the linear package's
//! `issues complete`, whose own rule sets the item's state. The command
//! refuses any open branch box it is not given, so a box the section gives
//! no evidence for ticks nothing: one comment on the item names the boxes
//! with evidence and the boxes without. On a Done item, which no duty reads
//! again, one comment names any other completion left unsettled.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::Deserialize;

use crate::settings::Settings;
use crate::verify::wire::{Nullable, Pull};
use crate::watch::tracker::Quota;

/// The heading the lane writes its evidence under, in the pull request
/// body `submit-pr.md` § 2 step 3 builds.
pub const HEADING: &str = "## Done-when evidence";

const TAG: &str = "close-boxes";
const BOUND: Duration = Duration::from_secs(120);

/// Why the close completes the boxes rather than the lane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cause {
    /// The lane's worktree or sandbox is gone.
    SandboxGone,
    /// The lane ended with its item Done and its sandbox standing.
    LaneEnded,
}

impl Cause {
    fn word(self) -> &'static str {
        match self {
            Cause::SandboxGone => "sandbox-gone",
            Cause::LaneEnded => "lane-ended",
        }
    }
}

/// The merged pull request the item landed by.
pub struct Merged<'a> {
    pub repo: &'a str,
    pub pr: u64,
}

/// `issues get --format=raw`: the fields the completion reads.
#[derive(Deserialize)]
struct Got {
    issue: GotIssue,
}

#[derive(Deserialize)]
struct GotIssue {
    #[serde(default)]
    description: Option<String>,
    state: GotState,
}

#[derive(Deserialize)]
struct GotState {
    name: String,
    #[serde(rename = "type")]
    kind: String,
}

/// The evidence section's lines by box number, as `--evidence-file`
/// reads them: `Absent` where the body holds no heading, `Invalid` where a
/// line under it is neither blank nor `N: text`, or names a box twice.
#[derive(Debug, PartialEq, Eq)]
enum Evidence {
    Absent,
    Invalid,
    Lines(BTreeMap<u64, String>),
}

fn evidence_lines(body: &str) -> Evidence {
    let mut lines = body.lines().map(|l| l.trim_end_matches('\r'));
    if !lines.any(|l| l.trim_end() == HEADING) {
        return Evidence::Absent;
    }
    let mut found = BTreeMap::new();
    for line in lines.take_while(|l| !l.starts_with('#')) {
        if line.trim().is_empty() {
            continue;
        }
        let Some((number, text)) = line.split_once(':') else {
            return Evidence::Invalid;
        };
        let text = text.trim();
        let number = match number.parse::<u64>() {
            Ok(n) if n > 0 && !number.starts_with('0') && !text.is_empty() => n,
            Ok(_) | Err(_) => return Evidence::Invalid,
        };
        if found.insert(number, text.to_owned()).is_some() {
            return Evidence::Invalid;
        }
    }
    Evidence::Lines(found)
}

fn box_list(boxes: &[u64]) -> String {
    if boxes.is_empty() {
        return "none".to_owned();
    }
    boxes
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(",")
}

/// What a completion left: settled, with the close's note where one is
/// owed (`None` for an item already Verifying or Done with no open branch
/// box, the lane's own completion standing), or boxes left open, with the
/// one comment the item takes once the lane ends over them. The comment is
/// never posted here: a close refused over open boxes is asked again, and
/// a tracker write no repeat may make twice is made by the close that ends
/// the lane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Completion {
    Settled(Option<String>),
    Unsettled {
        note: String,
        comment: Option<String>,
    },
}

/// Complete `item`'s branch-provable boxes from `merged`'s evidence
/// section. A box the section gives no evidence for is named in the item's
/// comment; an item the tracker reads Done (`done`) is read by no duty
/// again, so any other completion it leaves open is named there too.
pub fn complete(
    settings: &Settings,
    gh: &Path,
    item: &str,
    merged: &Merged<'_>,
    cause: Cause,
    done: bool,
) -> Completion {
    match settle(settings, gh, item, merged, cause) {
        None => Completion::Settled(None),
        Some(Outcome::Ticked(note)) => Completion::Settled(Some(note)),
        Some(Outcome::Unevidenced { note, comment }) => Completion::Unsettled {
            note,
            comment: Some(comment),
        },
        Some(Outcome::Unsettled(note)) => {
            let comment = done.then(|| {
                format!(
                    "## Done-when boxes left open at close\n\n\
                     The close completed no box of this Done item from the merged pull request \
                     {}#{}: `{note}`. No duty reads a Done item again: complete its branch-provable \
                     boxes through merge-pr's completion step.\n\n\
                     ticked-by=close cause={}\n",
                    merged.repo,
                    merged.pr,
                    cause.word()
                )
            });
            Completion::Unsettled { note, comment }
        }
    }
}

/// The item's one comment, `text`: `posted`, `failed` or `unknown`.
pub fn post(settings: &Settings, item: &str, text: &str) -> &'static str {
    match RunDir::create(&settings.state_dir) {
        Ok(run) => post_comment(settings, &run, item, text),
        Err(_) => "failed",
    }
}

/// What a completion read.
enum Outcome {
    /// The boxes ticked.
    Ticked(String),
    /// Open boxes the merged pull request gives no evidence for, ticked
    /// none, with the comment that names them.
    Unevidenced { note: String, comment: String },
    /// Boxes left unticked, held or unknown.
    Unsettled(String),
}

fn settle(
    settings: &Settings,
    gh: &Path,
    item: &str,
    merged: &Merged<'_>,
    cause: Cause,
) -> Option<Outcome> {
    let unsettled = |note: &str| Some(Outcome::Unsettled(note.to_owned()));
    let got = match run_linear(settings, "get", &["issues", "get", item, "--format=raw"]) {
        Ok(out) if out.status.success() => serde_json::from_slice::<Got>(&out.stdout).ok(),
        Ok(_) | Err(_) => None,
    };
    let Some(Got { issue }) = got else {
        return unsettled("boxes-unticked cause=item-unread");
    };
    let description = issue.description.unwrap_or_default();
    let open = match crate::watch::verifying::open_branch_boxes(settings, &description) {
        Ok(open) => open,
        Err(cause) => return unsettled(&format!("boxes-unticked cause={cause}")),
    };
    let completed = issue.state.name == "Verifying" || issue.state.kind == "completed";
    if open.is_empty() && completed {
        return None;
    }
    let path = format!("repos/{}/pulls/{}", merged.repo, merged.pr);
    let pull = match crate::watch::github::handle(gh).object::<Pull>(TAG, &path) {
        Ok(Some(pull)) => pull,
        Ok(None) => return unsettled("boxes-unticked cause=pr-missing"),
        Err(_) => return unsettled("boxes-unticked cause=pr-unread"),
    };
    let Nullable::Present(merged_at) = &pull.merged_at else {
        return unsettled("boxes-unticked cause=pr-unmerged");
    };
    let body = match &pull.body {
        Nullable::Present(body) => body.as_str(),
        Nullable::Absent | Nullable::Null => "",
    };
    let (word, lines) = match evidence_lines(body) {
        Evidence::Absent => ("evidence-absent", BTreeMap::new()),
        Evidence::Invalid => ("evidence-invalid", BTreeMap::new()),
        Evidence::Lines(lines) => ("evidence-partial", lines),
    };
    let (with, without): (Vec<u64>, Vec<u64>) = open.iter().partition(|b| lines.contains_key(b));
    if !without.is_empty() {
        let comment = format!(
            "## Done-when boxes left open at close\n\n\
             The merged pull request {}#{} gives no `{HEADING}` line for box {}, so the close ticked \
             no box: `issues complete` ticks every open branch-provable box or none.\n\n\
             - Boxes with evidence: {}\n\
             - Boxes without evidence: {}\n\n\
             ticked-by=close cause={}\n",
            merged.repo,
            merged.pr,
            box_list(&without),
            box_list(&with),
            box_list(&without),
            cause.word()
        );
        return Some(Outcome::Unevidenced {
            note: format!("boxes-unticked cause={word} boxes={}", box_list(&without)),
            comment,
        });
    }
    let run = match RunDir::create(&settings.state_dir) {
        Ok(run) => run,
        Err(e) => return unsettled(&format!("boxes-unticked cause=run-dir-failed error={e}")),
    };
    let merge = match &pull.merge_commit_sha {
        Nullable::Present(sha) => format!(" as {sha}"),
        Nullable::Absent | Nullable::Null => String::new(),
    };
    let proof: String = with
        .iter()
        .map(|b| {
            format!(
                "{b}: {} (merged{merge} in {}#{}; ticked-by=close cause={})\n",
                lines[b],
                merged.repo,
                merged.pr,
                cause.word()
            )
        })
        .collect();
    let mut args = vec![
        "issues".to_owned(),
        "complete".to_owned(),
        item.to_owned(),
        "--post-merge-at".to_owned(),
        merged_at.clone(),
    ];
    if !with.is_empty() {
        let file = run.dir.join("evidence");
        if let Err(e) = run.write(&file, &proof) {
            return unsettled(&format!(
                "boxes-unticked cause=evidence-unwritten error={e}"
            ));
        }
        args.extend([
            "--done-when-met".to_owned(),
            box_list(&with),
            "--evidence-file".to_owned(),
            file.display().to_string(),
        ]);
    }
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match run_linear(settings, "complete", &args) {
        Ok(out) if out.status.success() => Some(Outcome::Ticked(format!(
            "boxes-ticked by=close cause={} boxes={}",
            cause.word(),
            box_list(&with)
        ))),
        Ok(out) => {
            let stderr = host::stderr_text(&out);
            unsettled(&completion_note(&stderr, out.status.code()))
        }
        Err(agent_runtime::Error::NotStarted { .. }) => {
            unsettled("boxes-unticked cause=tracker-unstarted")
        }
        // Started with no answer: the item may have moved.
        Err(_) => unsettled("boxes-unknown cause=unanswered"),
    }
}

/// The line the linear package prints for a write Linear may have applied:
/// a 5xx or a lost answer (`lib/common.sh` `linear_retry_wait`).
const WRITE_UNCONFIRMED: &str = "linear-http: write=unconfirmed";

/// The note a completion the tracker CLI refused leaves: a write Linear
/// may have applied, the checklist's own refusal with the boxes it names, a
/// quota hold, or the exit.
fn completion_note(stderr: &str, code: Option<i32>) -> String {
    if stderr.lines().any(|l| l.starts_with(WRITE_UNCONFIRMED)) {
        return "boxes-unknown cause=unconfirmed".to_owned();
    }
    if let Some((_, reset)) = Quota::receipt_resets(stderr) {
        return format!("boxes-held cause=quota reset={reset}");
    }
    let checklist = stderr
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .find(|v| v["error"] == "post-merge-checklist");
    if let Some(refusal) = checklist {
        let mut boxes: Vec<u64> = ["unmet_branch_boxes", "missing_evidence_boxes"]
            .iter()
            .filter_map(|key| refusal[*key].as_array())
            .flatten()
            .filter_map(serde_json::Value::as_u64)
            .collect();
        boxes.sort_unstable();
        boxes.dedup();
        return format!(
            "boxes-unticked cause=post-merge-checklist boxes={}",
            box_list(&boxes)
        );
    }
    format!(
        "boxes-unticked cause=completion-failed exit={}",
        code.map_or_else(|| "signal".to_owned(), |c| c.to_string())
    )
}

/// The one comment on the item: `posted`, `failed`, or `unknown` where the
/// call started and gave no answer or the package reads the write as one
/// Linear may have applied.
fn post_comment(settings: &Settings, run: &RunDir, item: &str, text: &str) -> &'static str {
    let file = run.dir.join("comment.md");
    if run.write(&file, text).is_err() {
        return "failed";
    }
    let file = file.display().to_string();
    match run_linear(
        settings,
        "comment",
        &["comments", "create", item, "--body-file", &file],
    ) {
        Ok(out) if out.status.success() => "posted",
        Ok(out)
            if host::stderr_text(&out)
                .lines()
                .any(|l| l.starts_with(WRITE_UNCONFIRMED)) =>
        {
            "unknown"
        }
        Ok(_) | Err(agent_runtime::Error::NotStarted { .. }) => "failed",
        Err(_) => "unknown",
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the close's tracker calls for a merged item's boxes through the one runner: the item read, its one completion and its one comment"
)]
fn run_linear(
    settings: &Settings,
    operation: &'static str,
    args: &[&str],
) -> agent_runtime::Result<std::process::Output> {
    host::run_tagged(
        TAG,
        "linear",
        &settings.reads.tracker_cli,
        operation,
        args,
        BOUND,
    )
}

/// The completion's own input files under the state directory, removed
/// when it ends.
struct RunDir {
    dir: PathBuf,
}

impl RunDir {
    #[allow(
        clippy::disallowed_methods,
        reason = "the close's own run directory for the completion's inputs, created exclusively under the state directory"
    )]
    fn create(state_dir: &Path) -> std::io::Result<RunDir> {
        let dir = state_dir.join(format!("close-boxes.{}", std::process::id()));
        std::fs::create_dir(&dir)?;
        Ok(RunDir { dir })
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the close's own input file in its run directory"
    )]
    fn write(&self, path: &Path, text: &str) -> std::io::Result<()> {
        std::fs::write(path, text)
    }
}

impl Drop for RunDir {
    #[allow(
        clippy::disallowed_methods,
        reason = "the close's own run directory, removed when the completion ends"
    )]
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The section's lines as `--evidence-file` takes them, read to the
    /// next heading.
    #[test]
    fn the_evidence_section_reads_as_the_evidence_file_form() {
        let lines = |pairs: &[(u64, &str)]| {
            Evidence::Lines(pairs.iter().map(|(n, t)| (*n, (*t).to_owned())).collect())
        };
        let rows = [
            ("## Summary\n- x\n", Evidence::Absent),
            (
                "## Summary\n\n## Done-when evidence\n1: a test\n\n2:  b test \n## Test Plan\n3: not this\n",
                lines(&[(1, "a test"), (2, "b test")]),
            ),
            ("## Done-when evidence\r\n1: a\r\n", lines(&[(1, "a")])),
            ("## Done-when evidence\n", lines(&[])),
            ("## Done-when evidence\n- 1: a\n", Evidence::Invalid),
            ("## Done-when evidence\n1:\n", Evidence::Invalid),
            ("## Done-when evidence\n0: a\n", Evidence::Invalid),
            ("## Done-when evidence\n01: a\n", Evidence::Invalid),
            ("## Done-when evidence\n1: a\n1: b\n", Evidence::Invalid),
        ];
        for (body, want) in rows {
            assert_eq!(evidence_lines(body), want, "{body:?}");
        }
    }
}
