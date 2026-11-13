//! The acceptance's post-transition step. `accept` makes the
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
//! acceptance asks again. An unchanged result (`no-change`) on an item
//! keyed `issue-N` completes through the GitHub issue instead, through the
//! one GitHub module: the summary file, the comparison, is posted on the
//! issue once, and the issue is then closed as completed; the post's and
//! the close's outcomes are in the reply and the acceptance stands.
use agent_runtime::record::Locking;
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::item::{AcceptResult, ResultAccepted};
use super::{Applied, Report, Request, apply};
use crate::error::Result;
use crate::settings::Settings;
use crate::state::{self, Attachment, StageOutcome, SummaryComment};
use crate::verify::wire::{Issue as WireIssue, IssueComment, Nullable};
use crate::verify::{Answer as GhAnswer, Gh};
use crate::watch::tracker::{dropped, finished};
use agent_runtime::journal::Env;

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
/// naming a file posts, a repeat of a closed stage included. An unchanged
/// result on a GitHub issue reads the issue's repository before the close
/// ([`completed_issue`]) and ends the issue after it ([`end_issue`]), with
/// `issue` in the reply.
#[allow(
    clippy::disallowed_methods,
    reason = "the acceptance's first store entry through `ops::apply`: the close"
)]
pub fn accept(
    path: &Path,
    r: &AcceptResult,
    settings: &Settings,
    env: &Env,
    locking: Locking,
) -> Result<Applied> {
    let issue = completed_issue(path, r, settings)?;
    let mut applied = apply(path, &Request::AcceptResult(r.clone()), env, locking)?;
    let Report::AcceptResult(accepted) = &mut applied.report else {
        return Ok(applied);
    };
    if let Some(issue) = &issue {
        end_issue(path, r, issue, accepted, env, locking);
        return Ok(applied);
    }
    let Some(file) = &r.summary_file else {
        return Ok(applied);
    };
    let recorded = accepted.summary_comment.clone();
    let posted = match state::item_of(path) {
        Some(item) => post(
            &settings.reads.tracker_cli,
            item,
            recorded.as_ref(),
            file,
            &r.attachments,
        ),
        None => Err("the path names no item".to_owned()),
    };
    let summary = match posted {
        Err(cause) => SummaryPost::Failed { cause },
        Ok(posted) => record_comment(path, r, accepted, posted, env, locking),
    };
    accepted.summary = Some(summary);
    Ok(applied)
}

/// Record the comment `posted` earned as the item's `summary_comment`, by
/// the acceptance's own repeat of its request, and answer how the post
/// ended.
#[allow(
    clippy::disallowed_methods,
    reason = "the acceptance's second store entry through `ops::apply`: the comment id its post earned, the request's own repeat"
)]
fn record_comment(
    path: &Path,
    r: &AcceptResult,
    accepted: &mut ResultAccepted,
    posted: Posted,
    env: &Env,
    locking: Locking,
) -> SummaryPost {
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

// --- An unchanged result on a GitHub issue ----------------------------------------

/// The number an item keyed `issue-N` names, a GitHub issue's; `None` for
/// every other key.
pub(super) fn issue_number(item: &str) -> Option<u64> {
    item.strip_prefix("issue-")
        .filter(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        .and_then(|n| n.parse().ok())
}

/// The GitHub issue an unchanged result completes.
struct Issue {
    repo: String,
    number: u64,
}

/// How the acceptance ended the GitHub issue an unchanged result
/// completes, in the reply. The acceptance stands whichever it is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "closed", rename_all = "kebab-case")]
pub enum IssueClose {
    /// GitHub answered the issue closed as completed.
    Completed { repo: String, number: u64 },
    /// gh exited non-zero: GitHub refused the close or gh could not reach
    /// it, in gh's words.
    Refused {
        repo: String,
        number: u64,
        cause: String,
    },
    /// The close's answer is unknown: gh was killed, did not start or
    /// answered outside GitHub's documented shape.
    Unconfirmed {
        repo: String,
        number: u64,
        cause: String,
    },
    /// The comparison is not on the issue, so no close was sent.
    Held {
        repo: String,
        number: u64,
        cause: String,
    },
}

/// The issue an unchanged result on an item keyed `issue-N` completes,
/// read before any write: `None` for every other acceptance. The item key
/// carries no repository (the item alphabet admits no `/`), so the issue's
/// repository is the item's lane's, as the close and the park read it
/// (`repo::of_lane`), where the fleet holds a lane record for the item: a
/// hosted lane's checkout is not on this host. With no lane record it is
/// the one repository identity of the item's recorded checkout. A
/// repository neither names is refused `repo-unresolved`, with nothing
/// written.
#[allow(
    clippy::disallowed_methods,
    reason = "the acceptance's one read of the item record for its recorded checkout, before the close"
)]
fn completed_issue(path: &Path, r: &AcceptResult, settings: &Settings) -> Result<Option<Issue>> {
    let Some((item, number)) = state::item_of(path).and_then(|i| Some((i, issue_number(i)?)))
    else {
        return Ok(None);
    };
    if r.outcome != StageOutcome::NoChange || r.run_dir.is_some() {
        return Ok(None);
    }
    let unresolved = |cause: &str| -> crate::error::Error {
        agent_runtime::Error::refused("repo-unresolved", &[("item", item), ("cause", cause)]).into()
    };
    let project = &settings.roots.project;
    if let Some(lane) = crate::validate::run::lane_record(settings, item)? {
        let repo = crate::repo::of_lane(lane.repo.as_deref(), project)
            .map_err(|unread| unresolved(&unread.to_string()))?;
        return Ok(Some(Issue { repo, number }));
    }
    let worktree = state::load(path)?
        .and_then(|s| {
            s.doc
                .get("worktree")
                .and_then(Value::as_str)
                .filter(|w| !w.is_empty())
                .map(PathBuf::from)
        })
        .ok_or_else(|| unresolved("worktree-unrecorded"))?;
    let resolver = crate::repo::resolver(project);
    let repo =
        crate::repo::of(&resolver, &worktree).map_err(|unread| unresolved(&unread.to_string()))?;
    Ok(Some(Issue { repo, number }))
}

/// Post the comparison on the issue and close the issue as completed,
/// through the one GitHub module, after the close committed. The
/// comparison is the summary file the request names, posted once and
/// recorded as the item's `summary_comment`: a comment the item already
/// records is the comparison, and a repeat posts none. The issue is closed
/// only once the comparison is on it.
fn end_issue(
    path: &Path,
    r: &AcceptResult,
    issue: &Issue,
    accepted: &mut ResultAccepted,
    env: &Env,
    locking: Locking,
) {
    let gh = Gh::new(Path::new("gh")).tagged("accept");
    let held = |cause: &str| IssueClose::Held {
        repo: issue.repo.clone(),
        number: issue.number,
        cause: cause.to_owned(),
    };
    let on_issue = match (&accepted.summary_comment, &r.summary_file) {
        (Some(_), _) => true,
        (None, None) => {
            accepted.issue = Some(held("summary-unnamed"));
            return;
        }
        (None, Some(file)) => {
            let summary = match comment(&gh, issue, file) {
                Err(cause) => SummaryPost::Failed { cause },
                Ok(posted) => record_comment(path, r, accepted, posted, env, locking),
            };
            let posted = !matches!(summary, SummaryPost::Failed { .. });
            accepted.summary = Some(summary);
            posted
        }
    };
    accepted.issue = Some(if on_issue {
        close_issue(&gh, issue)
    } else {
        held("summary-unposted")
    });
}

/// The comparison as a comment on the issue (issues/comments, "Create an
/// issue comment"): the summary file's text as its body, the comment's id
/// as GitHub answered it, or the cause nothing is known by.
fn comment(gh: &Gh, issue: &Issue, file: &Path) -> std::result::Result<Posted, String> {
    let operation = "issue-comment";
    let body = std::fs::read_to_string(file)
        .map_err(|e| format!("{operation}: {}: {e}", file.display()))?;
    let payload = serde_json::to_vec(&serde_json::json!({ "body": body }))
        .map_err(|e| format!("{operation}: {e}"))?;
    let url = format!("repos/{}/issues/{}/comments", issue.repo, issue.number);
    match gh.run(
        operation,
        &["api", "--method", "POST", &url, "--input", "-"],
        Some(&payload),
    ) {
        Ok(GhAnswer::Printed { stdout, .. }) => serde_json::from_slice::<IssueComment>(&stdout)
            .map(|answer| Posted {
                id: answer.id.to_string(),
                attachments: Vec::new(),
                sent: Sent::Created,
            })
            .map_err(|e| format!("{operation}: answer: {e}")),
        Ok(GhAnswer::Failed(failed)) => Err(format!("{operation}: {}", failed.detail())),
        Err(unrun) => Err(format!("{operation}: {}", unrun.detail())),
    }
}

/// The issue closed as completed (issues, "Update an issue"), judged by
/// the state GitHub answered.
fn close_issue(gh: &Gh, issue: &Issue) -> IssueClose {
    let operation = "issue-close";
    let url = format!("repos/{}/issues/{}", issue.repo, issue.number);
    let payload = br#"{"state":"closed","state_reason":"completed"}"#;
    let (repo, number) = (issue.repo.clone(), issue.number);
    let unconfirmed = |cause: String| IssueClose::Unconfirmed {
        repo: repo.clone(),
        number,
        cause: format!("{operation}: {cause}"),
    };
    match gh.run(
        operation,
        &["api", "--method", "PATCH", &url, "--input", "-"],
        Some(payload),
    ) {
        Ok(GhAnswer::Printed { stdout, .. }) => {
            match serde_json::from_slice::<WireIssue>(&stdout) {
                Ok(answer)
                    if answer.state == "closed"
                        && answer.state_reason == Nullable::Present("completed".to_owned()) =>
                {
                    IssueClose::Completed {
                        repo: repo.clone(),
                        number,
                    }
                }
                Ok(answer) => unconfirmed(format!("the answer reads state={}", answer.state)),
                Err(e) => unconfirmed(format!("answer: {e}")),
            }
        }
        Ok(GhAnswer::Failed(failed)) if failed.exit.is_some() => IssueClose::Refused {
            repo: repo.clone(),
            number,
            cause: format!("{operation}: {}", failed.detail()),
        },
        Ok(GhAnswer::Failed(failed)) => unconfirmed(failed.detail()),
        Err(unrun) => unconfirmed(unrun.detail()),
    }
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

// --- the container close ----------------------------------------------------------------

/// What a container close answers its caller: the one stdout line merge-pr
/// § 6 and the overseer's Verification route read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContainerClosed {
    /// `closed ID`: the completion and its required work succeeded, or the
    /// parent already stood Done or Canceled.
    Closed { parent: String },
    /// `deferred` with the children still open; bare where the lock's
    /// wait passed.
    Deferred { pending: Vec<String> },
    /// `held ID RESET`: the tracker's quota hold stopped the completion,
    /// `RESET` its selected retry time or `unavailable`.
    Held { parent: String, reset: String },
}

impl ContainerClosed {
    pub fn line(&self) -> String {
        match self {
            ContainerClosed::Closed { parent } => format!("closed {parent}"),
            ContainerClosed::Deferred { pending } => std::iter::once("deferred")
                .chain(pending.iter().map(String::as_str))
                .collect::<Vec<_>>()
                .join(" "),
            ContainerClosed::Held { parent, reset } => format!("held {parent} {reset}"),
        }
    }
}

/// A container close's answer, with the diagnostics its caller keeps, each
/// one stderr line: the completion's own, `canceled`, `completion-held`.
#[derive(Debug)]
pub struct ContainerClose {
    pub answer: ContainerClosed,
    pub notes: Vec<String>,
}

/// A container close that refused: its key and fields, the lines before
/// it (each refused row with its remedy), and its exit status, 2 for a
/// usage refusal.
#[derive(Debug)]
pub struct ContainerRefused {
    pub key: &'static str,
    pub fields: Vec<(&'static str, String)>,
    pub notes: Vec<String>,
    pub exit: i32,
}

impl ContainerRefused {
    fn new(key: &'static str, fields: &[(&'static str, &str)]) -> ContainerRefused {
        ContainerRefused {
            key,
            fields: fields.iter().map(|(k, v)| (*k, (*v).to_owned())).collect(),
            notes: Vec::new(),
            exit: 1,
        }
    }

    /// `container-close: KEY field=value ...`, the line its caller greps.
    pub fn line(&self) -> String {
        let mut line = format!("container-close: {}", self.key);
        for (field, value) in &self.fields {
            line.push_str(&format!(" {field}={value}"));
        }
        line
    }
}

type Closing<T> = std::result::Result<T, ContainerRefused>;

/// How long a closer waits for another closer's lock before it answers
/// bare `deferred`.
const CONTAINER_LOCK_WAIT: Duration = Duration::from_secs(120);

/// The parent's read (`issues bulk-get ID --format=safe`, one row): its state
/// type and whether it is an in-PR bundle root, a work item its own PR
/// completes, by the linear package's one rule for that mark.
#[derive(Debug, Deserialize)]
struct ParentRead {
    state_type: String,
    in_pr_bundle: bool,
}

/// The parent's children to the three levels the package's items nest; the
/// read refuses an answer with a page left open, so the set is whole.
const CHILDREN: &str = "query Children($id: String!) { issue(id: $id) { children { \
    pageInfo { hasNextPage } nodes { identifier title state { type } children { \
    pageInfo { hasNextPage } nodes { identifier title state { type } children { \
    pageInfo { hasNextPage } nodes { identifier title state { type } } } } } } } } }";

#[derive(Debug, Deserialize)]
struct ChildrenAnswer {
    issue: ChildrenOf,
}

#[derive(Debug, Deserialize)]
struct ChildrenOf {
    children: ChildPage,
}

#[derive(Debug, Deserialize)]
struct ChildPage {
    nodes: Vec<ChildNode>,
}

#[derive(Debug, Deserialize)]
struct ChildNode {
    identifier: String,
    title: String,
    state: ChildState,
    children: Option<ChildPage>,
}

#[derive(Debug, Deserialize)]
struct ChildState {
    #[serde(rename = "type")]
    kind: String,
}

/// One child at any depth, each before its own children.
#[derive(Debug)]
struct ChildRead {
    id: String,
    title: String,
    state_type: String,
}

fn flatten_children(nodes: Vec<ChildNode>, into: &mut Vec<ChildRead>) {
    for node in nodes {
        into.push(ChildRead {
            id: node.identifier,
            title: node.title,
            state_type: node.state.kind,
        });
        if let Some(page) = node.children {
            flatten_children(page.nodes, into);
        }
    }
}

impl ChildRead {
    fn pending(&self) -> bool {
        !finished(&self.state_type)
    }
}

/// The one decision a close makes from its reads, first match wins; a row
/// whose input is not read yet asks for that read, so an in-PR bundle root
/// reads no child and an open child defers before the validation's
/// per-child reads.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Decision {
    Refuse(&'static str),
    ReadChildren,
    Keep,
    ReadValidation,
    Noop { canceled: bool },
    CloseCanceled,
    CloseDone { summary: bool },
}

fn decide(
    id: &str,
    parent: &ParentRead,
    children: Option<&[ChildRead]>,
    validation: Option<&[Value]>,
) -> Decision {
    if parent.in_pr_bundle {
        return Decision::Refuse("in-pr-bundle");
    }
    let Some(children) = children else {
        return Decision::ReadChildren;
    };
    if children.is_empty() {
        return Decision::Refuse("no-children");
    }
    if children.iter().any(ChildRead::pending) {
        return Decision::Keep;
    }
    let Some(results) = validation else {
        return Decision::ReadValidation;
    };
    let own = results.iter().find(|r| r["id"] == id);
    let listed = |key: &str| {
        own.and_then(|r| r[key].as_array())
            .is_some_and(|a| !a.is_empty())
    };
    if listed("container_open_boxes") {
        return Decision::Refuse("open-box");
    }
    if listed("errors") {
        return Decision::Refuse("checklist-invalid");
    }
    if results.iter().any(|r| refused_child(r, id)) {
        return Decision::Refuse("child-not-ok");
    }
    let state = parent.state_type.as_str();
    if children.iter().all(|c| dropped(&c.state_type)) {
        return match state {
            ended if finished(ended) => Decision::Noop {
                canceled: dropped(ended),
            },
            _ => Decision::CloseCanceled,
        };
    }
    if dropped(state) {
        return Decision::Refuse("parent-canceled");
    }
    let summarized = own.is_some_and(|r| r["has_summary"] == true);
    Decision::CloseDone {
        summary: state != "completed" && !summarized,
    }
}

fn refused_child(row: &Value, id: &str) -> bool {
    row["id"] != id && row["ok"] == false
}

/// The boxes a remedy names: each as text, sorted, unique.
fn boxes<'a>(values: impl Iterator<Item = &'a Value>) -> String {
    let mut names: Vec<String> = values
        .map(|v| match v {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .collect();
    names.sort();
    names.dedup();
    names.join(", ")
}

/// The fix a refused row's cause names.
fn remedy(row: &Value, cause: &str, id: &str) -> String {
    let empty = Vec::new();
    let array = |key: &str| row[key].as_array().unwrap_or(&empty);
    match cause {
        "open-box" => format!(
            "Move each open box of {id} ({}) into its own child item, then rerun container-close.",
            boxes(array("container_open_boxes").iter())
        ),
        "checklist-invalid" => format!(
            "Correct the Post-merge fields of each box of {id} that errors names ({}), then rerun container-close.",
            boxes(array("errors").iter().map(|e| &e["box"]))
        ),
        "child-not-ok" => {
            let child = row["id"].as_str().unwrap_or("");
            let mut fixes = Vec::new();
            if row["state_ok"] != true {
                fixes.push("set it Done".to_owned());
            }
            if row["has_summary"] != true {
                fixes.push(format!(
                    "post a comment headed {SUMMARY_HEADING} with comments create {child} --body-file SUMMARY_FILE"
                ));
            }
            format!(
                "On {child}: {}, then rerun container-close.",
                fixes.join("; ")
            )
        }
        _ => format!("Move {id} to a live state so it closes Done, then rerun container-close."),
    }
}

/// The validation's rows, typed as the decision reads them: one row for the
/// parent with its summary, its open boxes, its errors and its child box,
/// and every other row's ok, state and summary.
fn validation_rows(answer: &Value, id: &str) -> Option<Vec<Value>> {
    let rows = answer.get("results")?.as_array()?;
    if rows.iter().filter(|r| r["id"] == id).count() != 1 {
        return None;
    }
    let typed = rows.iter().all(|r| {
        if r["id"] == id {
            r["has_summary"].is_boolean()
                && r["container_open_boxes"].is_array()
                && r["errors"].is_array()
                && (r["child_box"].is_null() || r["child_box"].is_number())
        } else {
            r["ok"].is_boolean() && r["state_ok"].is_boolean() && r["has_summary"].is_boolean()
        }
    });
    typed.then(|| rows.clone())
}

/// The shared main checkout `checkout` is a linked worktree of, or itself.
fn main_root(checkout: &Path) -> Closing<PathBuf> {
    let checkout = std::fs::canonicalize(checkout).map_err(|_| {
        ContainerRefused::new(
            "checkout-invalid",
            &[("arg1", &checkout.display().to_string())],
        )
    })?;
    let roots = agent_runtime::settings::roots(&checkout).map_err(|_| {
        ContainerRefused::new(
            "root-unresolved",
            &[("repository-checkout", &checkout.display().to_string())],
        )
    })?;
    let root = std::fs::canonicalize(&roots.common).map_err(|_| {
        ContainerRefused::new(
            "root-invalid",
            &[("main-repo-root", &roots.common.display().to_string())],
        )
    })?;
    let inside = container_git(&root, &["rev-parse", "--is-inside-work-tree"])
        .is_ok_and(|out| out.trim() == "true");
    if !inside {
        return Err(ContainerRefused::new(
            "not-worktree",
            &[("main-repo-root", &root.display().to_string())],
        ));
    }
    Ok(root)
}

#[allow(
    clippy::disallowed_methods,
    reason = "the container close's one git read of the shared checkout through the one runner"
)]
fn container_git(cwd: &Path, args: &[&str]) -> std::result::Result<String, String> {
    let out = host::run_tagged_in(
        "container-close",
        "git",
        Path::new("git"),
        "git",
        args,
        host::Place {
            cwd: Some(cwd),
            env: &[],
        },
        POST_TIMEOUT,
    )
    .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(host::stdout_text(&out))
    } else {
        Err(host::stderr_text(&out))
    }
}

/// Close the Linear container `parent` once its last child is Done or
/// Canceled: it ticks the parent's "Every child Done or cancelled" box with
/// an Evidence line naming each child's state and sets Done with the bundle
/// summary, or sets Canceled when every child was canceled. One lock under
/// the shared main checkout, `tmp/container-close.lock`, serializes every
/// container's close across its linked checkouts. The close decides its own
/// parent alone: whether a container's own parent closes after it is the
/// workflow's to ask.
pub fn container_close(
    tracker_cli: &Path,
    checkout: &Path,
    parent: &str,
) -> Closing<ContainerClose> {
    let root = main_root(checkout)?;
    let shaped = parent
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric())
        && parent
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        && !parent.contains("..");
    if !shaped {
        let mut refused = ContainerRefused::new("invalid-parent", &[("parent-id", parent)]);
        refused.exit = 2;
        return Err(refused);
    }
    let tmp = root.join("tmp");
    create_dir(&tmp).map_err(|_| ContainerRefused::new("temp-failed", &[("parent", parent)]))?;
    locked_close(&tmp.join("container-close"), || {
        close_held(tracker_cli, &root, parent)
    })
}

/// `f` under the lock every closer of this checkout takes, waiting up to
/// [`CONTAINER_LOCK_WAIT`] for it: a wait that passes answers bare
/// `deferred`; a lock that cannot be taken refuses `lock-failed`.
#[allow(
    clippy::disallowed_methods,
    reason = "the container close's own lock beside the shared checkout's tmp/, the file every closer, the released flock(1) ones among them, locks; no record is behind it"
)]
fn locked_close(
    lock: &Path,
    f: impl FnOnce() -> Closing<ContainerClose>,
) -> Closing<ContainerClose> {
    let parent_lock = |cause: String| ContainerRefused::new("lock-failed", &[("lock-rc", &cause)]);
    let mut guard = agent_runtime::record::lock(lock).map_err(|e| parent_lock(e.to_string()))?;
    let wait = agent_runtime::record::Wait {
        limit: CONTAINER_LOCK_WAIT,
        ..agent_runtime::record::Wait::DEFAULT
    };
    let mut held = None;
    let ran = guard.with_wait(&wait.start(), || {
        held = Some(f());
        Ok(())
    });
    match (ran, held) {
        (Ok(()), Some(answer)) => answer,
        (Err(e), None) if e.key() == "lock-timeout" => Ok(ContainerClose {
            answer: ContainerClosed::Deferred {
                pending: Vec::new(),
            },
            notes: Vec::new(),
        }),
        (Err(e), _) => Err(parent_lock(e.to_string())),
        (Ok(()), None) => unreachable!("the lock ran its body"),
    }
}

/// The close under the lock: the reads the decision asks for, then its one
/// mutation.
fn close_held(tracker_cli: &Path, root: &Path, id: &str) -> Closing<ContainerClose> {
    let refuse = |key: &'static str| ContainerRefused::new(key, &[("parent-id", id)]);
    let linear = |operation: &'static str, args: &[&str], failed: &'static str| {
        read_tracker(tracker_cli, operation, args).map_err(|read| match read {
            TrackerRead::Missing => ContainerRefused::new(
                "linear-missing",
                &[("linear", &tracker_cli.display().to_string())],
            ),
            TrackerRead::Failed => refuse(failed),
        })
    };
    let bytes = linear(
        "parent",
        &["issues", "bulk-get", id, "--format=safe"],
        "parent-unreadable",
    )?;
    let [parent]: [ParentRead; 1] = serde_json::from_slice::<Vec<ParentRead>>(&bytes)
        .ok()
        .and_then(|rows| rows.try_into().ok())
        .ok_or_else(|| refuse("parent-response"))?;
    let mut children: Option<Vec<ChildRead>> = None;
    let mut validation: Option<Vec<Value>> = None;
    let decision = loop {
        match decide(id, &parent, children.as_deref(), validation.as_deref()) {
            Decision::ReadChildren => {
                let variables = serde_json::json!({ "id": id }).to_string();
                let bytes = linear(
                    "children",
                    &["graphql", "--query", CHILDREN, "--variables", &variables],
                    "children-unreadable",
                )?;
                let answer: ChildrenAnswer =
                    serde_json::from_slice(&bytes).map_err(|_| refuse("children-response"))?;
                let mut read = Vec::new();
                flatten_children(answer.issue.children.nodes, &mut read);
                if read.iter().any(|c| c.id.is_empty()) {
                    return Err(refuse("children-response"));
                }
                children = Some(read);
            }
            Decision::ReadValidation => {
                let bytes = linear(
                    "validation",
                    &[
                        "issues",
                        "validate-completion",
                        id,
                        "--include-children-of",
                        id,
                        "--container",
                    ],
                    "validation-failed",
                )?;
                let answer: Value =
                    serde_json::from_slice(&bytes).map_err(|_| refuse("validation-result"))?;
                validation =
                    Some(validation_rows(&answer, id).ok_or_else(|| refuse("validation-result"))?);
            }
            other => break other,
        }
    };
    let children = children.unwrap_or_default();
    let results = validation.unwrap_or_default();
    let mut notes = Vec::new();
    let canceled_note = format!("container-close: canceled parent-id={id}");
    let mutation: Vec<String> = match &decision {
        Decision::ReadChildren | Decision::ReadValidation => {
            unreachable!("the loop reads until the decision acts")
        }
        Decision::Refuse(cause) => {
            let mut refused = ContainerRefused::new("completion-refused", &[("parent-id", id)]);
            if matches!(*cause, "in-pr-bundle" | "no-children") {
                refused.key = *cause;
                return Err(refused);
            }
            refused.fields.push(("cause", (*cause).to_owned()));
            for row in results.iter().filter(|r| {
                if *cause == "child-not-ok" {
                    refused_child(r, id)
                } else {
                    r["id"] == id
                }
            }) {
                let mut row = row.clone();
                row["remedy"] = Value::from(remedy(&row, cause, id));
                refused.notes.push(row.to_string());
            }
            return Err(refused);
        }
        Decision::Keep => {
            return Ok(ContainerClose {
                answer: ContainerClosed::Deferred {
                    pending: children
                        .iter()
                        .filter(|c| c.pending())
                        .map(|c| c.id.clone())
                        .collect(),
                },
                notes,
            });
        }
        Decision::Noop { canceled } => {
            if *canceled {
                notes.push(canceled_note);
            }
            return Ok(closed(root, id, notes));
        }
        Decision::CloseCanceled => {
            vec![
                "issues".into(),
                "update".into(),
                id.into(),
                "--state".into(),
                "Canceled".into(),
            ]
        }
        Decision::CloseDone { .. } => vec!["issues".into(), "complete".into(), id.into()],
    };
    let run = RunDir::create(root, id)
        .map_err(|_| ContainerRefused::new("temp-failed", &[("parent", id)]))?;
    let held = HeldDir::of(root, id);
    let mut mutation = mutation;
    let mut summary_built = false;
    if let Decision::CloseDone { summary: true } = decision {
        let rows: String = children
            .iter()
            .filter(|c| !dropped(&c.state_type))
            .map(|c| format!("{}\t{}\t{}\n", c.id, c.title, c.state_type))
            .collect();
        let summary = match held.summary_for(&rows) {
            Some(summary) => summary,
            None => {
                let mut summary = "## Bundle Complete\n\n".to_owned();
                for child in children.iter().filter(|c| !dropped(&c.state_type)) {
                    if child.state_type != "completed" {
                        return Err(ContainerRefused::new(
                            "summary-state",
                            &[("id", &child.id), ("state-type", &child.state_type)],
                        ));
                    }
                    let reference = child_pr(root, &child.id, &mut notes)?;
                    summary.push_str(&format!(
                        "- {} ✓ {} — PR {reference}\n",
                        child.id, child.title
                    ));
                }
                summary
            }
        };
        run.write("children.tsv", &rows)
            .map_err(|_| refuse("summary-rows"))?;
        run.write("summary.md", &summary)
            .map_err(|_| refuse("summary-rows"))?;
        mutation.extend(["--summary-file".to_owned(), run.path("summary.md")]);
        summary_built = true;
    }
    if let Decision::CloseDone { .. } = decision
        && let Some(child_box) = results
            .iter()
            .find(|r| r["id"] == id)
            .and_then(|r| r["child_box"].as_u64())
            .filter(|b| {
                let own = results.iter().find(|r| r["id"] == id);
                ["unmet_branch_boxes", "missing_evidence_boxes"]
                    .iter()
                    .any(|key| {
                        own.and_then(|r| r[*key].as_array())
                            .is_some_and(|a| a.iter().any(|v| v.as_u64() == Some(*b)))
                    })
            })
    {
        let states: Vec<String> = children
            .iter()
            .map(|c| {
                let word = if dropped(&c.state_type) {
                    "Canceled"
                } else {
                    "Done"
                };
                format!("{} {word}", c.id)
            })
            .collect();
        let evidence = format!(
            "{child_box}: container-close read every child Done or Canceled: {}\n",
            states.join(", ")
        );
        run.write("evidence", &evidence)
            .map_err(|_| refuse("evidence-failed"))?;
        mutation.extend([
            "--done-when-met".to_owned(),
            child_box.to_string(),
            "--evidence-file".to_owned(),
            run.path("evidence"),
        ]);
    }
    let args: Vec<&str> = mutation.iter().map(String::as_str).collect();
    let out = mutate_tracker(tracker_cli, &args).map_err(|_| refuse("completion-failed"))?;
    let stderr = host::stderr_text(&out);
    notes.extend(stderr.lines().filter(|l| !l.is_empty()).map(str::to_owned));
    if !out.status.success() {
        let Some((requests_reset, reset)) = crate::watch::tracker::Quota::receipt_resets(&stderr)
        else {
            let mut refused = refuse("completion-failed");
            refused.notes = notes;
            return Err(refused);
        };
        let kept = if summary_built {
            held.keep(&run)
                .map_or_else(|_| "unkept".to_owned(), |p| p.display().to_string())
        } else {
            "none".to_owned()
        };
        notes.push(format!(
            "container-close: completion-held parent-id={id} requests-reset={requests_reset} hold-reset={reset} summary={kept}"
        ));
        return Ok(ContainerClose {
            answer: ContainerClosed::Held {
                parent: id.to_owned(),
                reset,
            },
            notes,
        });
    }
    if decision == Decision::CloseCanceled {
        notes.push(canceled_note);
    }
    Ok(closed(root, id, notes))
}

/// `closed ID`, the held inputs released once the required work succeeded
/// (`held-release` on stderr where they could not be removed).
fn closed(root: &Path, id: &str, mut notes: Vec<String>) -> ContainerClose {
    let held = HeldDir::of(root, id);
    if held.release().is_err() {
        notes.push(format!(
            "container-close: held-release held-dir={}",
            held.dir.display()
        ));
    }
    ContainerClose {
        answer: ContainerClosed::Closed {
            parent: id.to_owned(),
        },
        notes,
    }
}

/// A child's merged pull request for the summary line, `#N`, or
/// `unavailable` where a valid lookup matched none; `lookup failed`, with
/// `gh-missing` on stderr, where no `gh` runs, since no rerun can produce
/// the reference there. A lookup that failed or would not parse refuses,
/// leaving the parent open and the summary unwritten. The caller's
/// `GH_REPO` and `GITHUB_REPOSITORY` are set empty, so a value the caller
/// carries never names another repository than the shared checkout's.
fn child_pr(root: &Path, child: &str, notes: &mut Vec<String>) -> Closing<String> {
    let gh = crate::watch::github::handle(Path::new("gh"))
        .tagged("container-close")
        .in_dir(root)
        .adding_env(vec![
            ("GH_REPO".to_owned(), std::ffi::OsString::new()),
            ("GITHUB_REPOSITORY".to_owned(), std::ffi::OsString::new()),
        ]);
    let args = [
        "pr",
        "list",
        "--state",
        "merged",
        "--search",
        child,
        "--limit",
        "100",
        "--json",
        "number,headRefName,mergedAt,isCrossRepository",
    ];
    let unresolved = || ContainerRefused::new("pr-unresolved", &[("child-id", child)]);
    let stdout = match gh.run("child-pr", &args, None) {
        Ok(crate::verify::Answer::Printed { stdout, .. }) => stdout,
        Ok(crate::verify::Answer::Failed(_)) => return Err(unresolved()),
        Err(crate::verify::Unrun::Runner(agent_runtime::Error::NotStarted { .. })) => {
            notes.push(format!("container-close: gh-missing child-id={child}"));
            return Ok("lookup failed".to_owned());
        }
        Err(_) => return Err(unresolved()),
    };
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Merged {
        number: u64,
        head_ref_name: String,
        merged_at: String,
        #[serde(default)]
        is_cross_repository: bool,
    }
    let rows: Vec<Merged> = serde_json::from_slice(&stdout)
        .map_err(|_| ContainerRefused::new("pr-response", &[("child-id", child)]))?;
    let needle = child.to_ascii_lowercase();
    let own = rows
        .iter()
        .filter(|r| !r.is_cross_repository)
        .filter(|r| {
            let branch = r.head_ref_name.to_ascii_lowercase();
            let branch = branch.rsplit('/').next().unwrap_or("");
            branch == needle
                || branch.starts_with(&format!("{needle}-"))
                || branch.starts_with(&format!("{needle}_"))
        })
        .max_by(|a, b| a.merged_at.cmp(&b.merged_at));
    Ok(own.map_or_else(|| "unavailable".to_owned(), |r| format!("#{}", r.number)))
}

/// Why a tracker read gave no answer: the CLI never started, or it failed.
enum TrackerRead {
    Missing,
    Failed,
}

/// One tracker read through the CLI, its stdout on exit 0.
#[allow(
    clippy::disallowed_methods,
    reason = "the container close's tracker reads through the one runner"
)]
fn read_tracker(
    cli: &Path,
    operation: &'static str,
    args: &[&str],
) -> std::result::Result<Vec<u8>, TrackerRead> {
    let out = host::run_tagged(
        "container-close",
        "linear",
        cli,
        operation,
        args,
        POST_TIMEOUT,
    )
    .map_err(|e| match e {
        agent_runtime::Error::NotStarted { .. } => TrackerRead::Missing,
        _ => TrackerRead::Failed,
    })?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        Err(TrackerRead::Failed)
    }
}

/// The completion's one mutation through the tracker CLI, its output read
/// whole: its stderr is the caller's to keep, and a quota line on it holds.
#[allow(
    clippy::disallowed_methods,
    reason = "the container close's one tracker mutation through the one runner"
)]
fn mutate_tracker(cli: &Path, args: &[&str]) -> std::result::Result<std::process::Output, String> {
    host::run_tagged(
        "container-close",
        "linear",
        cli,
        "complete",
        args,
        POST_TIMEOUT,
    )
    .map_err(|e| e.to_string())
}

/// This run's own inputs under the shared checkout's `tmp/`, removed when
/// the run ends.
struct RunDir {
    dir: PathBuf,
}

impl RunDir {
    #[allow(
        clippy::disallowed_methods,
        reason = "the container close's own run directory, created exclusively under the shared checkout's tmp/"
    )]
    fn create(root: &Path, id: &str) -> std::io::Result<RunDir> {
        let dir = root
            .join("tmp")
            .join(format!("container-close-{id}.{}", std::process::id()));
        std::fs::create_dir(&dir)?;
        Ok(RunDir { dir })
    }

    fn path(&self, name: &str) -> String {
        self.dir.join(name).display().to_string()
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the container close's own input file in its run directory"
    )]
    fn write(&self, name: &str, text: &str) -> std::io::Result<()> {
        std::fs::write(self.dir.join(name), text)
    }
}

impl Drop for RunDir {
    #[allow(
        clippy::disallowed_methods,
        reason = "the container close's own run directory, removed when the run ends"
    )]
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A rate-limited completion's inputs, kept under the shared checkout as
/// `tmp/container-close-held/ID/` for the next run; the lock every closer
/// holds owns the path, so no closer sees it half-written.
struct HeldDir {
    dir: PathBuf,
}

impl HeldDir {
    fn of(root: &Path, id: &str) -> HeldDir {
        HeldDir {
            dir: root.join("tmp").join("container-close-held").join(id),
        }
    }

    /// The held summary where its rows are exactly `rows`, the children it
    /// was built from; rows that differ or cannot be read rebuild it.
    #[allow(
        clippy::disallowed_methods,
        reason = "the container close's read of its own held inputs, under its lock"
    )]
    fn summary_for(&self, rows: &str) -> Option<String> {
        let held_rows = std::fs::read_to_string(self.dir.join("children.tsv")).ok()?;
        (held_rows == rows)
            .then(|| std::fs::read_to_string(self.dir.join("summary.md")).ok())
            .flatten()
    }

    /// Keep this run's summary and rows, the previous summary removed first, so a
    /// move that fails part way leaves no summary beside rows it was not
    /// built from.
    #[allow(
        clippy::disallowed_methods,
        reason = "the container close's own held inputs, moved under its lock"
    )]
    fn keep(&self, run: &RunDir) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(&self.dir)?;
        match std::fs::remove_file(self.dir.join("summary.md")) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        std::fs::rename(run.dir.join("children.tsv"), self.dir.join("children.tsv"))?;
        std::fs::rename(run.dir.join("summary.md"), self.dir.join("summary.md"))?;
        Ok(self.dir.join("summary.md"))
    }

    #[allow(
        clippy::disallowed_methods,
        reason = "the container close's own held inputs, released once the completion succeeded"
    )]
    fn release(&self) -> std::io::Result<()> {
        for name in ["summary.md", "children.tsv"] {
            match std::fs::remove_file(self.dir.join(name)) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
        }
        match std::fs::remove_dir(&self.dir) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }
}

#[allow(
    clippy::disallowed_methods,
    reason = "the shared checkout's tmp/ the container close's lock and inputs live in"
)]
fn create_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)
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
