//! A merged item's branch-provable Done-when boxes completed by the close
//! where its lane can no longer: the merged pull request's `## Done-when
//! evidence` section, the `N: text` lines the lane wrote before merge,
//! ticks the item's open branch boxes through the linear package's
//! `issues complete`, whose own rule sets the item's state. The command
//! refuses any open branch box it is not given, so a box the section gives
//! no evidence for ticks nothing: one comment on the item names the boxes
//! with evidence and the boxes without.

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

/// Complete `item`'s branch-provable boxes from `merged`'s evidence
/// section: the close's note, or `None` for an item already Verifying or
/// Done with no open branch box, the lane's own completion standing.
pub fn complete(
    settings: &Settings,
    gh: &Path,
    item: &str,
    merged: &Merged<'_>,
    cause: Cause,
) -> Option<String> {
    let got = match run_linear(settings, "get", &["issues", "get", item, "--format=raw"]) {
        Ok(out) if out.status.success() => serde_json::from_slice::<Got>(&out.stdout).ok(),
        Ok(_) | Err(_) => None,
    };
    let Some(Got { issue }) = got else {
        return Some("boxes-unticked cause=item-unread".to_owned());
    };
    let description = issue.description.unwrap_or_default();
    let open = match crate::watch::verifying::open_branch_boxes(settings, &description) {
        Ok(open) => open,
        Err(cause) => return Some(format!("boxes-unticked cause={cause}")),
    };
    let completed = issue.state.name == "Verifying" || issue.state.kind == "completed";
    if open.is_empty() && completed {
        return None;
    }
    let path = format!("repos/{}/pulls/{}", merged.repo, merged.pr);
    let pull = match crate::watch::github::handle(gh).object::<Pull>(TAG, &path) {
        Ok(Some(pull)) => pull,
        Ok(None) => return Some("boxes-unticked cause=pr-missing".to_owned()),
        Err(_) => return Some("boxes-unticked cause=pr-unread".to_owned()),
    };
    let Nullable::Present(merged_at) = &pull.merged_at else {
        return Some("boxes-unticked cause=pr-unmerged".to_owned());
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
    let run = match RunDir::create(&settings.state_dir) {
        Ok(run) => run,
        Err(e) => return Some(format!("boxes-unticked cause=run-dir-failed error={e}")),
    };
    if !without.is_empty() {
        let posted = post_open_boxes(settings, &run, item, merged, cause, &with, &without);
        return Some(format!(
            "boxes-unticked cause={word} boxes={} comment={posted}",
            box_list(&without)
        ));
    }
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
            return Some(format!("boxes-unticked cause=evidence-unwritten error={e}"));
        }
        args.extend([
            "--done-when-met".to_owned(),
            box_list(&with),
            "--evidence-file".to_owned(),
            file.display().to_string(),
        ]);
    }
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    Some(match run_linear(settings, "complete", &args) {
        Ok(out) if out.status.success() => format!(
            "boxes-ticked by=close cause={} boxes={}",
            cause.word(),
            box_list(&with)
        ),
        Ok(out) => {
            let stderr = host::stderr_text(&out);
            completion_note(&stderr, out.status.code())
        }
        Err(agent_runtime::Error::NotStarted { .. }) => {
            "boxes-unticked cause=tracker-unstarted".to_owned()
        }
        // Started with no answer: the item may have moved; the verifying
        // duty's next read of it settles what stands.
        Err(_) => "boxes-unknown cause=unanswered".to_owned(),
    })
}

/// The note a completion the tracker CLI refused leaves: the checklist's
/// own refusal with the boxes it names, a quota hold, or the exit.
fn completion_note(stderr: &str, code: Option<i32>) -> String {
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

/// The one comment naming the boxes the section gave evidence for and the
/// boxes it did not: `posted`, `failed`, or `unknown` where the call
/// started and gave no answer.
fn post_open_boxes(
    settings: &Settings,
    run: &RunDir,
    item: &str,
    merged: &Merged<'_>,
    cause: Cause,
    with: &[u64],
    without: &[u64],
) -> &'static str {
    let text = format!(
        "## Done-when boxes left open at close\n\n\
         The merged pull request {}#{} gives no `{HEADING}` line for box {}, so the close ticked \
         no box: `issues complete` ticks every open branch-provable box or none.\n\n\
         - Boxes with evidence: {}\n\
         - Boxes without evidence: {}\n\n\
         ticked-by=close cause={}\n",
        merged.repo,
        merged.pr,
        box_list(without),
        box_list(with),
        box_list(without),
        cause.word()
    );
    let file = run.dir.join("comment.md");
    if run.write(&file, &text).is_err() {
        return "failed";
    }
    let file = file.display().to_string();
    match run_linear(
        settings,
        "comment",
        &["comments", "create", item, "--body-file", &file],
    ) {
        Ok(out) if out.status.success() => "posted",
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
