//! U6c: the acceptance's post-transition step (step6-map § A8, decisions
//! 174 (3), 182 Q6, 188 (e), 190). `accept` makes the round's close through
//! `accept-result`, then posts the Completion Summary the request names
//! through the tracker CLI through the one runner, the tracker duty's
//! route, so the item carries one summary. The acceptance rewrites only a
//! comment it created. With no `summary_comment` recorded it lists the
//! item's comments first: the newest headed `## Completion Summary` (the
//! dev agent's own post until step 7 retires it, or a comment an earlier
//! acceptance created and then ended before recording) is recorded `found`
//! and left as its writer posted it, since on Linear a comment's
//! attachments are links in its body that an update would replace and the
//! summary file never carries; where the list names none the acceptance
//! creates the comment, recorded `created`, and updates that one in place
//! by its recorded id on every later acceptance, with no list. A later
//! acceptance whose record is `found` sends nothing and says so: the dev
//! agent's post carries each round's summary. The comment's id is recorded
//! on the item as `summary_comment` by the acceptance's own repeat of its
//! request. A list or post that fails, or an id the store refused to
//! record, is reported in the reply and the acceptance stands: the comment
//! is advisory to `container-close`, never the close's condition. A failed
//! list creates nothing: whether a comment exists is then not known, and
//! the next acceptance asks again.
use std::path::Path;
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};

use super::item::AcceptResult;
use super::{Applied, Env, Report, Request, apply};
use crate::error::Result;
use crate::state::{self, Locking, SummaryComment, SummaryOrigin};

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
    /// Another writer's summary comment, the newest headed one the list
    /// named, recorded `found` and not rewritten; `at` is the record's
    /// stamp.
    Found { id: String, at: String },
    /// The comment the acceptance created, updated in place by its
    /// recorded id, the stamp recorded.
    Updated { id: String, at: String },
    /// Nothing was sent: the recorded comment is not the acceptance's to
    /// rewrite.
    Kept { id: String, cause: KeptCause },
    /// The tracker CLI refused, could not run, or answered no list or no
    /// comment id: whether a comment exists is not known, and nothing is
    /// recorded.
    Failed { cause: String },
    /// The comment was posted or found and the store refused the id's
    /// record: the id is in this reply alone, and the next acceptance
    /// reads it back from the item's comment list.
    Unrecorded { id: String, cause: String },
}

/// Why an acceptance kept the recorded comment as it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum KeptCause {
    /// The record names a comment another writer posted, which an earlier
    /// acceptance's list found: its body is that writer's, attachments
    /// included, and the dev agent's own post carries this round's summary.
    FoundComment,
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
    if let Some(SummaryComment {
        id,
        origin: SummaryOrigin::Found,
        ..
    }) = recorded
    {
        accepted.summary = Some(SummaryPost::Kept {
            id,
            cause: KeptCause::FoundComment,
        });
        return Ok(applied);
    }
    let posted = match state::item_of(path) {
        Some(item) => post(
            tracker_cli,
            item,
            recorded.as_ref().map(|c| c.id.as_str()),
            file,
        ),
        None => Err("the path names no item".to_owned()),
    };
    let summary = match posted {
        Err(cause) => SummaryPost::Failed { cause },
        Ok(posted) => {
            let id = posted.id().to_owned();
            let comment = SummaryComment {
                id: id.clone(),
                at: env.iso(),
                origin: posted.origin(),
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

/// A post's outcome: the comment the record names, and what was sent for
/// it.
enum Posted {
    /// Created through the CLI where the list named none.
    Created(String),
    /// Updated in place by the recorded id.
    Updated(String),
    /// Another writer's, named by the list: nothing sent.
    Found(String),
}

impl Posted {
    fn id(&self) -> &str {
        match self {
            Posted::Created(id) | Posted::Updated(id) | Posted::Found(id) => id,
        }
    }

    /// Whose comment the record says it is.
    fn origin(&self) -> SummaryOrigin {
        match self {
            Posted::Created(_) | Posted::Updated(_) => SummaryOrigin::Created,
            Posted::Found(_) => SummaryOrigin::Found,
        }
    }

    /// The reply's word, once the record took the comment at `at`.
    fn reply(self, at: String) -> SummaryPost {
        match self {
            Posted::Created(id) => SummaryPost::Created { id, at },
            Posted::Updated(id) => SummaryPost::Updated { id, at },
            Posted::Found(id) => SummaryPost::Found { id, at },
        }
    }
}

/// One post through the tracker CLI: an update by the recorded id, else
/// the newest summary-headed comment the item's list names taken as found
/// with nothing sent, else a create. The comment's id the CLI answered,
/// or the cause nothing is known by.
fn post(
    cli: &Path,
    item: &str,
    recorded: Option<&str>,
    file: &Path,
) -> std::result::Result<Posted, String> {
    let file = file.display().to_string();
    let (operation, args): (&'static str, Vec<&str>) = match recorded {
        Some(id) => (
            "summary-update",
            vec!["comments", "update", id, "--body-file", &file],
        ),
        None => match summary_of(cli, item)? {
            Some(id) => return Ok(Posted::Found(id)),
            None => (
                "summary-create",
                vec!["comments", "create", item, "--body-file", &file],
            ),
        },
    };
    let out = call(cli, operation, &args)?;
    let answer: Answer =
        serde_json::from_slice(&out).map_err(|e| format!("{operation}: answer: {e}"))?;
    match answer.data.comment {
        Some(comment) if !comment.id.is_empty() => Ok(if recorded.is_some() {
            Posted::Updated(comment.id)
        } else {
            Posted::Created(comment.id)
        }),
        _ => Err(format!("{operation}: the answer names no comment id")),
    }
}

/// The newest comment on the item whose body begins with the summary
/// heading, read through `comments list` in the CLI's safe shape (the one
/// page it answers); `None` where the list names none. A list that fails
/// is the cause: whether a comment exists is then not known.
fn summary_of(cli: &Path, item: &str) -> std::result::Result<Option<String>, String> {
    let operation = "summary-list";
    let out = call(cli, operation, &["comments", "list", item])?;
    let comments: Vec<ListedComment> =
        serde_json::from_slice(&out).map_err(|e| format!("{operation}: answer: {e}"))?;
    Ok(comments
        .into_iter()
        .filter(|c| !c.id.is_empty() && c.body.trim_start().starts_with(SUMMARY_HEADING))
        .max_by(|a, b| a.created_at.cmp(&b.created_at))
        .map(|c| c.id))
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
/// `comment` carries the id.
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
}

/// One comment of the CLI's list answer (`commands/comments.sh` `list`, the
/// safe shape `format_comments_list` prints): the id, the body the heading
/// is read from and the creation stamp the newest is chosen by.
#[derive(Deserialize)]
struct ListedComment {
    #[serde(default)]
    id: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    created_at: String,
}
