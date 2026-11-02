//! U6c, U7e: the acceptance's post-transition step (step6-map § A8,
//! decisions 174 (3), 182 Q6, 188 (e), 192 Q10, Q11). `accept` makes the
//! round's close through `accept-result`, then posts the Completion Summary
//! the request names through the tracker CLI through the one runner, the
//! tracker duty's route, so the item carries one summary: the acceptance's
//! own, with the round's screenshots attached. With no `summary_comment`
//! recorded it lists the item's comments first: the newest headed
//! `## Completion Summary` is the acceptance's own after a crash between
//! its create and the record (no other writer posts one on an item that
//! has an acceptance), so it is recorded and updated in place; where the
//! list names none the acceptance creates the comment with one `--attach`
//! per attachment the request names, and updates that one in place by its
//! recorded id on every later acceptance, with no list. On Linear a
//! comment's attachments are the `![name](url)` links the CLI appended
//! under its body, which an update replaces whole, so the acceptance reads
//! them back from the create's answer (or the found comment's listed body),
//! records them beside the id, and renders them under the summary in the
//! body file of every update. The comment's id is recorded on the item as
//! `summary_comment` by the acceptance's own repeat of its request. A list
//! or post that fails, or an id the store refused to record, is reported in
//! the reply and the acceptance stands: the comment is advisory to
//! `container-close`, never the close's condition. A failed list creates
//! nothing: whether a comment exists is then not known, and the next
//! acceptance asks again.
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};

use super::item::AcceptResult;
use super::{Applied, Env, Report, Request, apply};
use crate::error::Result;
use crate::state::{self, Attachment, Locking, SummaryComment};

/// How long one tracker call may take.
const POST_TIMEOUT: Duration = Duration::from_secs(120);

/// The heading the item's one summary comment begins with: what the dev
/// workflow writes (`dev-implement.md` § Completion Summary) and what
/// `container-close` asks for where `has_summary` is false.
const SUMMARY_HEADING: &str = "## Completion Summary";

/// How the acceptance's summary post ended, in the reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "posted", rename_all = "kebab-case")]
pub enum SummaryPost {
    /// The item's first summary comment, created where the item's comment
    /// list named none, and recorded.
    Created { id: String, at: String },
    /// The item's comment, updated in place by its recorded id or by the
    /// id the list found, the stamp recorded.
    Updated { id: String, at: String },
    /// The tracker CLI refused, could not run, or answered no list or no
    /// comment id, or the update's body could not be written: whether a
    /// comment exists is not known, and nothing is recorded.
    Failed { cause: String },
    /// The comment was posted and the store refused the id's record: the
    /// id is in this reply alone, and the next acceptance reads it back
    /// from the item's comment list.
    Unrecorded { id: String, cause: String },
}

/// Accept the round's result and post its summary. The reply is the
/// close's report, with `summary` where a file was named; every request
/// naming a file posts, a repeat of a closed stage included.
#[allow(
    clippy::disallowed_methods,
    reason = "the acceptance's two store entries through `ops::apply`: the close, then the comment id its post earned, the request's own repeat"
)]
pub fn accept(
    path: &Path,
    r: &AcceptResult,
    tracker_cli: &Path,
    env: &Env,
    locking: Locking,
) -> Result<Applied> {
    let mut applied = apply(path, &Request::AcceptResult(r.clone()), env, locking)?;
    let Some(file) = &r.summary_file else {
        return Ok(applied);
    };
    let Report::AcceptResult(accepted) = &mut applied.report else {
        return Ok(applied);
    };
    let recorded = accepted.summary_comment.clone();
    let posted = match state::item_of(path) {
        Some(item) => post(tracker_cli, item, recorded.as_ref(), file, &r.attachments),
        None => Err("the path names no item".to_owned()),
    };
    let summary = match posted {
        Err(cause) => SummaryPost::Failed { cause },
        Ok(posted) => {
            let id = posted.id.clone();
            let comment = SummaryComment {
                id: id.clone(),
                at: env.iso(),
                attachments: posted.attachments.clone(),
            };
            let record = AcceptResult {
                summary_comment: Some(comment.clone()),
                ..r.clone()
            };
            // The close's report is the reply; the repeat lends it the
            // comment it recorded.
            match apply(path, &Request::AcceptResult(record), env, locking) {
                Ok(Applied {
                    report: Report::AcceptResult(again),
                    ..
                }) => {
                    accepted.summary_comment = again.summary_comment;
                    posted.reply(comment.at)
                }
                Ok(Applied { report, .. }) => SummaryPost::Unrecorded {
                    id,
                    cause: format!("the record answered a {} report", report_name(&report)),
                },
                Err(e) => SummaryPost::Unrecorded {
                    id,
                    cause: format!("{}: {e}", e.key()),
                },
            }
        }
    };
    accepted.summary = Some(summary);
    Ok(applied)
}

/// The `op` word a report carries, for a cause naming one.
fn report_name(report: &Report) -> String {
    serde_json::to_value(report)
        .ok()
        .and_then(|v| v.get("op").and_then(|o| o.as_str()).map(str::to_owned))
        .unwrap_or_default()
}

/// A post's outcome: the comment the record names, the attachments its
/// body carries, and what was sent for it.
struct Posted {
    id: String,
    attachments: Vec<Attachment>,
    sent: Sent,
}

/// What one post sent.
enum Sent {
    /// Created through the CLI where the list named none.
    Created,
    /// Updated in place, by the recorded id or the id the list found.
    Updated,
}

impl Posted {
    /// The reply's word, once the record took the comment at `at`.
    fn reply(self, at: String) -> SummaryPost {
        match self.sent {
            Sent::Created => SummaryPost::Created { id: self.id, at },
            Sent::Updated => SummaryPost::Updated { id: self.id, at },
        }
    }
}

/// One post through the tracker CLI: an update by the recorded id with its
/// recorded attachments, else by the id and links of the newest
/// summary-headed comment the item's list names, else a create with each
/// of `attachments` attached. The comment's id the CLI answered, or the
/// cause nothing is known by.
fn post(
    cli: &Path,
    item: &str,
    recorded: Option<&SummaryComment>,
    file: &Path,
    attachments: &[PathBuf],
) -> std::result::Result<Posted, String> {
    let (id, kept) = match recorded {
        Some(comment) => (Some(comment.id.clone()), comment.attachments.clone()),
        None => match summary_of(cli, item)? {
            Some(found) => (Some(found.id), found.attachments),
            None => (None, Vec::new()),
        },
    };
    match id {
        Some(id) => update(cli, &id, file, kept),
        None => create(cli, item, file, attachments),
    }
}

/// `comments create` with the summary file as the body and one `--attach`
/// per path; the links the CLI appended are read back from the answer's
/// body, at most one per path.
fn create(
    cli: &Path,
    item: &str,
    file: &Path,
    attachments: &[PathBuf],
) -> std::result::Result<Posted, String> {
    let operation = "summary-create";
    let file = file.display().to_string();
    let paths: Vec<String> = attachments
        .iter()
        .map(|p| p.display().to_string())
        .collect();
    let mut args = vec!["comments", "create", item, "--body-file", &file];
    for path in &paths {
        args.push("--attach");
        args.push(path);
    }
    let answer = mutate(cli, operation, &args)?;
    Ok(Posted {
        id: answer.id,
        attachments: attachment_links(&answer.body, Some(paths.len())),
        sent: Sent::Created,
    })
}

/// `comments update` by `id`: the body is the summary file where the
/// comment carries no attachment, else a file written beside it with the
/// recorded links rendered under the summary, since the update replaces
/// the body whole and the CLI's update takes no `--attach`.
#[allow(
    clippy::disallowed_methods,
    reason = "the update's body file beside the summary file, the acceptance's own scratch, written whole before the one post that reads it and overwritten by the next update"
)]
fn update(
    cli: &Path,
    id: &str,
    file: &Path,
    attachments: Vec<Attachment>,
) -> std::result::Result<Posted, String> {
    let operation = "summary-update";
    let body = if attachments.is_empty() {
        file.to_path_buf()
    } else {
        let summary = std::fs::read_to_string(file)
            .map_err(|e| format!("{operation}: {}: {e}", file.display()))?;
        let mut text = summary.trim_end().to_owned();
        for link in &attachments {
            text.push_str("\n\n");
            text.push_str(&link.render());
        }
        text.push('\n');
        let path = file.with_extension("linear.md");
        std::fs::write(&path, text).map_err(|e| format!("{operation}: {}: {e}", path.display()))?;
        path
    };
    let body = body.display().to_string();
    let answer = mutate(
        cli,
        operation,
        &["comments", "update", id, "--body-file", &body],
    )?;
    Ok(Posted {
        id: answer.id,
        attachments,
        sent: Sent::Updated,
    })
}

/// One comment mutation through the CLI: the comment it answered, by id,
/// with its body.
fn mutate(
    cli: &Path,
    operation: &'static str,
    args: &[&str],
) -> std::result::Result<AnswerComment, String> {
    let out = call(cli, operation, args)?;
    let answer: Answer =
        serde_json::from_slice(&out).map_err(|e| format!("{operation}: answer: {e}"))?;
    match answer.data.comment {
        Some(comment) if !comment.id.is_empty() => Ok(comment),
        _ => Err(format!("{operation}: the answer names no comment id")),
    }
}

/// A comment the list named as the item's summary: its id and the
/// attachment links its body ends with.
struct Found {
    id: String,
    attachments: Vec<Attachment>,
}

/// The newest comment on the item whose body begins with the summary
/// heading, read through `comments list` in the CLI's safe shape (every
/// page, merged by the CLI); `None` where the list names none. A list that
/// fails is the cause: whether a comment exists is then not known.
fn summary_of(cli: &Path, item: &str) -> std::result::Result<Option<Found>, String> {
    let operation = "summary-list";
    let out = call(cli, operation, &["comments", "list", item])?;
    let comments: Vec<ListedComment> =
        serde_json::from_slice(&out).map_err(|e| format!("{operation}: answer: {e}"))?;
    Ok(comments
        .into_iter()
        .filter(|c| !c.id.is_empty() && c.body.trim_start().starts_with(SUMMARY_HEADING))
        .max_by(|a, b| a.created_at.cmp(&b.created_at))
        .map(|c| Found {
            id: c.id,
            attachments: attachment_links(&c.body, None),
        }))
}

/// The attachment links under a comment's body, as the CLI appended them
/// (`commands/comments.sh` `create`: each upload's `![name](assetUrl)` or
/// `[name](assetUrl)` as its own paragraph after the body): the run of
/// whole-line links the body ends with, in body order, at most `limit` of
/// them where the create's `--attach` count is known. A summary whose own
/// last lines are such links is read with them on a found comment, so an
/// update renders those lines twice: a repeated line, never a lost upload.
fn attachment_links(body: &str, limit: Option<usize>) -> Vec<Attachment> {
    let mut links = Vec::new();
    for line in body.lines().rev() {
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        match Attachment::parse(line) {
            Some(link) => links.push(link),
            None => break,
        }
    }
    if let Some(limit) = limit {
        links.truncate(limit);
    }
    links.reverse();
    links
}

impl Attachment {
    /// One link line as the CLI wrote it: `![name](url)` for an image,
    /// `[name](url)` otherwise, the name as the CLI escaped it.
    fn parse(line: &str) -> Option<Attachment> {
        let (image, rest) = match line.strip_prefix('!') {
            Some(rest) => (true, rest),
            None => (false, line),
        };
        let inner = rest.strip_prefix('[')?.strip_suffix(')')?;
        let (name, url) = inner.rsplit_once("](")?;
        if url.is_empty() || url.contains(char::is_whitespace) {
            return None;
        }
        Some(Attachment {
            name: name.to_owned(),
            url: url.to_owned(),
            image,
        })
    }

    /// The link line, byte for byte as [`Attachment::parse`] read it.
    fn render(&self) -> String {
        let bang = if self.image { "!" } else { "" };
        format!("{bang}[{}]({})", self.name, self.url)
    }
}

/// One tracker CLI call through the one runner: its stdout on success, or
/// the cause (the runner's refusal, or the exit and the first line said).
#[allow(
    clippy::disallowed_methods,
    reason = "the acceptance's calls of the tracker CLI through the one runner, after the close committed: the item's comment list, then the one post of the round's summary"
)]
fn call(
    cli: &Path,
    operation: &'static str,
    args: &[&str],
) -> std::result::Result<Vec<u8>, String> {
    let out = host::run_tagged("accept", "linear", cli, operation, args, POST_TIMEOUT)
        .map_err(|e| format!("{operation}: {e}"))?;
    if !out.status.success() {
        let line = host::stderr_text(&out)
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("")
            .trim()
            .to_owned();
        return Err(format!(
            "{operation}: exit {}: {line}",
            out.status.code().unwrap_or(-1)
        ));
    }
    Ok(out.stdout)
}

/// The CLI's answer to a comment mutation (`commands/comments.sh`,
/// `normalize_mutation_response`): `data` is the mutation's payload, whose
/// `comment` carries the id and the body as the tracker stored it.
#[derive(Deserialize)]
struct Answer {
    #[serde(default)]
    data: AnswerData,
}

#[derive(Default, Deserialize)]
struct AnswerData {
    #[serde(default)]
    comment: Option<AnswerComment>,
}

#[derive(Deserialize)]
struct AnswerComment {
    #[serde(default)]
    id: String,
    #[serde(default)]
    body: String,
}

/// One comment of the CLI's list answer (`commands/comments.sh` `list`, the
/// safe shape `format_comments_list` prints): the id, the body the heading
/// and the links are read from and the creation stamp the newest is chosen
/// by.
#[derive(Deserialize)]
struct ListedComment {
    #[serde(default)]
    id: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    created_at: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The links the CLI appends are read back whole and in order, bounded
    /// by the create's count where known; a body line that is not a link
    /// ends the run. The defect: a link lost or a body line taken for one.
    #[test]
    fn the_links_under_a_body_are_the_trailing_run_of_link_lines() {
        let body = "## Completion Summary\n\n- `a` - done\n\n![a.png](https://u/a)\n\n[notes.pdf](https://u/n)\n";
        let links = attachment_links(body, None);
        assert_eq!(
            links.iter().map(Attachment::render).collect::<Vec<_>>(),
            ["![a.png](https://u/a)", "[notes.pdf](https://u/n)"]
        );
        assert!(links[0].image);
        assert!(!links[1].image);
        assert_eq!(attachment_links(body, Some(1)).len(), 1);
        assert_eq!(attachment_links(body, Some(1))[0].name, "notes.pdf");
        assert!(attachment_links(body, Some(0)).is_empty());
        assert!(attachment_links("## Completion Summary\n\n[x](u) and more\n", None).is_empty());
        assert_eq!(attachment_links("[](https://u/a)\n", None).len(), 1);
        assert!(attachment_links("[a]()\n", None).is_empty());
        assert!(attachment_links("[a](u v)\n", None).is_empty());
        assert_eq!(
            attachment_links("![re\\]port.png](https://u/r)\n", None)[0].name,
            "re\\]port.png"
        );
    }
}
