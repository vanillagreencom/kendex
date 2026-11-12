//! Exact-head approvals as the overseer's GitHub App and their once-per-head
//! attempt records. With `hold_copilot`, Copilot's work in flight on the
//! head is waited out through the current-head wait before the review
//! replies are read and the attempt is claimed. A request's `comment_file`
//! is posted on the pull request as the app, once per head, before the
//! attempt is claimed: a comment that did not land approves nothing.
use agent_runtime::record::{self, Document, Locking};
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::copilot_wait::{self, CopilotWait};
use super::loaded;
use crate::error::{Error, Result};
use crate::settings::Settings;
use crate::verify::review::{self, Flight};
use crate::verify::wire::{IssueComment, Nullable};
use crate::verify::{Answer, Gh, Unreadable, Unrun};
use agent_runtime::clock::Clock;

const APPROVALS: &str = "head_approvals";
const BOUND: Duration = Duration::from_secs(60);

/// The approval's start-counter tag.
const TAG: &str = "approve";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproveHead {
    pub repo: String,
    pub pr: u64,
    pub head: String,
    pub body_file: PathBuf,
    #[serde(default)]
    pub hold_copilot: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment_file: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Status {
    Confirmed,
    Refused,
    Unknown,
    Finished,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovedHead {
    pub status: Status,
    pub head: String,
    pub reason: String,
    pub review: Option<Value>,
    /// gh's words for a POST GitHub refused, an answer lost or a read-back
    /// that failed; on a confirmation, the review's login where the
    /// configured one differs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    login: String,
    #[serde(default)]
    attempt: Option<Attempt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    comment: Option<Posting>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
enum Attempt {
    Attempted,
    Confirmed { review: Value },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
enum Posting {
    Attempted,
    Posted { id: u64 },
}

/// The refusal of an attempt a complete read-back found had not landed.
const NOT_LANDED: &str = "not-landed";

/// The answer while a comment's POST is unsettled: its claim stands.
const COMMENT_UNCONFIRMED: &str = "comment-unconfirmed";

fn refuse(key: &'static str, fields: &[(&str, &str)]) -> Error {
    agent_runtime::Error::refused(key, fields).into()
}

fn login_changed(recorded: &str, configured: &str) -> Error {
    refuse(
        "approval-login-changed",
        &[("recorded", recorded), ("configured", configured)],
    )
}

/// The confirmation's detail where the review's login is not the one the
/// setting names: the setting is what every read-back matches.
fn login_differs(review: &Value, login: &str) -> Option<String> {
    reviewer(review)
        .filter(|named| *named != login)
        .map(|named| format!("login-differs configured={login} review={named}"))
}

/// The remedy a `review-replies` refusal names.
const REPLIES_FIX: &str = "Restore the github reader if unavailable; address its findings and retry approval for the current head.";

fn valid_sha(head: &str, min: usize) -> bool {
    (min..=40).contains(&head.len())
        && head
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn slot(r: &ApproveHead) -> String {
    format!("{}#{}", r.repo.to_ascii_lowercase(), r.pr)
}

fn entries<'a>(
    doc: &'a mut Document,
    r: &ApproveHead,
) -> Result<&'a mut serde_json::Map<String, Value>> {
    let root = doc.entry(APPROVALS).or_insert_with(|| json!({}));
    let root = root
        .as_object_mut()
        .ok_or_else(|| refuse("approval-record", &[]))?;
    root.entry(slot(r))
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(|| refuse("approval-record", &[]))
}

#[allow(
    clippy::disallowed_methods,
    reason = "approval claims and their outcomes commit under the item's write check"
)]
fn update<T>(
    path: &Path,
    r: &ApproveHead,
    head: &str,
    login: &str,
    locking: Locking,
    f: impl Fn(&mut Entry) -> Result<T>,
) -> Result<T> {
    record::reread(
        || {
            let snapshot = loaded(path)?;
            let mut doc = snapshot.doc.clone();
            let records = entries(&mut doc, r)?;
            let mut entry: Entry = match records.get(head) {
                Some(value) => serde_json::from_value(value.clone())
                    .map_err(|_| refuse("approval-record", &[]))?,
                None => Entry {
                    login: login.into(),
                    attempt: None,
                    comment: None,
                },
            };
            // An entry that holds no act binds no login: the configured one
            // replaces it, so a login corrected after a refused POST approves. A
            // confirmed approval stands whoever the setting names; an act still
            // unsettled was read back under its own login alone.
            if entry.login != login {
                match (&entry.attempt, &entry.comment) {
                    (Some(Attempt::Confirmed { .. }), _) => {}
                    (None, None) => entry.login = login.into(),
                    (Some(Attempt::Attempted), _) | (None, Some(_)) => {
                        return Err(login_changed(&entry.login, login));
                    }
                }
            }
            let answer = f(&mut entry)?;
            records.insert(head.into(), serde_json::to_value(entry)?);
            record::store(path, &snapshot.doc, &doc, locking)?;
            Ok(answer)
        },
        Error::key,
    )
}

/// The app's file credential outranks any reader credential the caller's
/// environment holds, so GitHub sees the app on every approval call.
fn credential(settings: &Settings, token: &str) -> Vec<(String, OsString)> {
    settings
        .review
        .approval_reader_env
        .iter()
        .filter(|(key, _)| key == "GH_HOST")
        .map(|(key, value)| (key.clone(), OsString::from(value)))
        .chain([("GH_TOKEN".to_owned(), OsString::from(token))])
        .collect()
}

/// The approval reads and POST: gh under the fleet's file credential,
/// never a harness credential, in the project root.
fn app(settings: &Settings, token: &str) -> Gh<'static> {
    Gh::with_env(Path::new("gh"), credential(settings, token))
        .tagged(TAG)
        .in_dir(&settings.roots.project)
        .bounded(BOUND)
}

/// What a read that exited zero printed, with its stderr; any other answer
/// is the read's refusal under `key`, gh's words its detail.
fn answered(
    answer: std::result::Result<Answer, Unrun>,
    key: &'static str,
) -> Result<(Vec<u8>, String)> {
    match answer {
        Ok(Answer::Printed { stdout, stderr }) => Ok((stdout, stderr)),
        Ok(Answer::Failed(failed)) => Err(refuse(key, &[("detail", &failed.stderr)])),
        Err(unrun) => Err(refuse(key, &[("detail", &unrun.detail())])),
    }
}

/// What a read that exited zero printed; any other answer is `None`.
fn printed(answer: std::result::Result<Answer, Unrun>) -> Option<Vec<u8>> {
    match answer {
        Ok(Answer::Printed { stdout, .. }) => Some(stdout),
        Ok(Answer::Failed(_)) | Err(_) => None,
    }
}

fn owned(env: &[(&str, &OsStr)]) -> Vec<(String, OsString)> {
    env.iter()
        .map(|(key, value)| ((*key).to_owned(), value.to_os_string()))
        .collect()
}

fn live_head(settings: &Settings, r: &ApproveHead, token: &str) -> Result<String> {
    let url = format!("repos/{}/pulls/{}", r.repo, r.pr);
    let (stdout, stderr) = answered(
        app(settings, token).run("api", &["api", &url, "--jq", ".head.sha"], None),
        "head-read-failed",
    )?;
    let head = String::from_utf8_lossy(&stdout).trim().to_owned();
    if !valid_sha(&head, 40) {
        return Err(refuse("head-read-failed", &[("detail", &stderr)]));
    }
    Ok(head)
}

fn approves(value: &Value, head: &str) -> bool {
    value.get("state").and_then(Value::as_str) == Some("APPROVED")
        && value.get("commit_id").and_then(Value::as_str) == Some(head)
}

fn reviewer(value: &Value) -> Option<&str> {
    value.pointer("/user/login").and_then(Value::as_str)
}

fn confirms(value: &Value, login: &str, head: &str) -> bool {
    approves(value, head) && reviewer(value) == Some(login)
}

fn read_back(
    settings: &Settings,
    r: &ApproveHead,
    head: &str,
    login: &str,
    token: &str,
) -> Result<Option<Value>> {
    let url = format!("repos/{}/pulls/{}/reviews", r.repo, r.pr);
    let (stdout, _) = answered(
        app(settings, token).run("api", &["api", &url, "--paginate", "--slurp"], None),
        "approval-read-back",
    )?;
    let pages: Vec<Vec<Value>> = serde_json::from_slice(&stdout)
        .map_err(|e| refuse("approval-read-back", &[("detail", &e.to_string())]))?;
    if pages.is_empty() {
        return Err(refuse(
            "approval-read-back",
            &[("detail", "no reviews page")],
        ));
    }
    Ok(pages
        .into_iter()
        .flatten()
        .rfind(|v| confirms(v, login, head)))
}

#[allow(
    clippy::disallowed_methods,
    reason = "the approval calls the installed github reply checker; its selected reader identity determines whose dispositions count"
)]
fn replies(settings: &Settings, r: &ApproveHead, head: &str, token: &str) -> Result<()> {
    let reader = settings
        .roots
        .project
        .join(".agents/skills/github/scripts/github.sh");
    let pr = r.pr.to_string();
    // The router owns reader credential selection. Supply the fleet token only
    // when neither an environment credential nor keyring can identify a reader;
    // a credential line only a shell reads is the router's, which sources the
    // private file itself.
    let has_env = settings
        .review
        .approval_reader_env
        .iter()
        .any(|(key, value)| key != "GH_HOST" && !value.is_empty())
        || !settings.review.approval_unread.is_empty();
    let mut env: Vec<_> = settings
        .review
        .approval_reader_env
        .iter()
        .map(|(key, value)| (key.as_str(), OsStr::new(value)))
        .collect();
    let keyring = !has_env
        && printed(
            Gh::with_env(Path::new("gh"), owned(&env))
                .tagged(TAG)
                .in_dir(&settings.roots.project)
                .bounded(BOUND)
                .run("auth", &["auth", "status"], None),
        )
        .is_some();
    env.push(("GH_REPO", OsStr::new(&r.repo)));
    if !has_env && !keyring {
        env.push(("GH_TOKEN", OsStr::new(token)));
    }
    let output = host::run_tagged_in(
        "approve",
        "github",
        &reader,
        "check-review-replies",
        &[
            "-C",
            &settings.roots.project.to_string_lossy(),
            "check-review-replies",
            &pr,
        ],
        host::Place {
            cwd: Some(&settings.roots.project),
            env: &env,
        },
        BOUND,
    )
    .map_err(|e| {
        refuse(
            "review-replies",
            &[
                ("exit", "127"),
                ("result", "unavailable"),
                ("detail", &e.to_string()),
                ("fix", REPLIES_FIX),
            ],
        )
    })?;
    let expected = format!("review-replies: pass head={head}");
    let result = host::stdout_text(&output);
    if !output.status.success() || result != expected {
        let exit = output
            .status
            .code()
            .map_or_else(|| "signal".to_owned(), |code| code.to_string());
        // The checker answers on stdout and by its exit; its stderr is the
        // refusal's detail only beside a failed exit.
        let detail = if output.status.success() {
            String::new()
        } else {
            host::stderr_text(&output)
        };
        return Err(refuse(
            "review-replies",
            &[
                ("exit", &exit),
                ("result", &result),
                ("detail", &detail),
                ("fix", REPLIES_FIX),
            ],
        ));
    }
    Ok(())
}

/// Copilot's work in flight on the bound head, waited out by the
/// current-head wait under the file credential. Work that ends inside the
/// bound approves nothing, so the next call reads the review replies
/// Copilot's review left; work still running at the bound permits the
/// approval while the live head is still the bound one. No work in flight,
/// or a running check Copilot's review of the head already answered, holds
/// nothing.
fn hold(
    settings: &Settings,
    r: &ApproveHead,
    head: &str,
    token: &str,
    clock: &dyn Clock,
) -> Result<Option<ApprovedHead>> {
    let bound = copilot_wait::bound(&settings.review).map_err(|_| {
        refuse(
            "copilot-hold-setting",
            &[("value", &settings.review.copilot_hold)],
        )
    })?;
    let gh = app(settings, token);
    match review::copilot_flight(&gh, &r.repo, r.pr, head) {
        Ok(Flight::Work(_)) => {}
        Ok(Flight::Settled { .. } | Flight::None) => return Ok(None),
        Err(cause) => {
            let unread = Unreadable::from(cause);
            return Err(refuse(
                "copilot-read-failed",
                &[
                    ("reason", &unread.reason),
                    ("detail", unread.detail.as_deref().unwrap_or_default()),
                ],
            ));
        }
    }
    let request = CopilotWait {
        repo: r.repo.clone(),
        pr: r.pr,
        bound,
    };
    let waited = copilot_wait::run_with(&request, &gh, clock)?;
    if waited.status != "complete" {
        return Err(refuse(
            "copilot-read-failed",
            &[
                ("reason", waited.reason.as_deref().unwrap_or_default()),
                ("detail", waited.detail.as_deref().unwrap_or_default()),
            ],
        ));
    }
    if waited.head.as_deref() != Some(head) {
        return Err(refuse(
            "head-moved",
            &[
                ("given", head),
                ("live", waited.head.as_deref().unwrap_or_default()),
            ],
        ));
    }
    if waited.state != Some("expired") {
        return Ok(Some(reply(
            Status::Finished,
            head,
            "copilot-finished",
            None,
        )));
    }
    let live = live_head(settings, r, token)?;
    if live != head {
        return Err(refuse("head-moved", &[("given", head), ("live", &live)]));
    }
    Ok(None)
}

fn reply(status: Status, head: &str, reason: &str, review: Option<Value>) -> ApprovedHead {
    ApprovedHead {
        status,
        head: head.into(),
        reason: reason.into(),
        review,
        detail: None,
    }
}

fn http_refusal(exit: Option<i32>, stderr: &str) -> bool {
    // gh exits 4 holding no credential; GitHub's 4xx answer exits 1 as a
    // transport failure does, so only gh's own status line tells them apart.
    exit == Some(4) || crate::verify::refused_by_github(stderr)
}

pub fn run(
    path: &Path,
    r: &ApproveHead,
    settings: &Settings,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<ApprovedHead> {
    if r.pr == 0 || !valid_sha(&r.head, 7) || crate::verify::validate_repo(&r.repo).is_err() {
        return Err(refuse("approval-request", &[]));
    }
    let body = std::fs::read_to_string(&r.body_file).map_err(|_| refuse("body-file", &[]))?;
    // An empty comment explains nothing, so it is refused before any call.
    let comment = match &r.comment_file {
        None => None,
        Some(file) => Some(
            std::fs::read_to_string(file)
                .ok()
                .filter(|text| !text.trim().is_empty())
                .ok_or_else(|| refuse("comment-file", &[]))?,
        ),
    };
    // The credential, the app's login and the host must be read values; a
    // reader credential only a shell reads stays the router's.
    if settings
        .review
        .approval_unread
        .iter()
        .any(|key| !matches!(key.as_str(), "GH_TOKEN" | "GITHUB_TOKEN" | "GH_BOT_TOKEN"))
    {
        return Err(refuse("approval-setting-unread", &[]));
    }
    let token = crate::watch::security::read_token(settings.review.approval_token_file.as_deref())
        .map_err(|(file, cause)| refuse("credential", &[("file", &file), ("cause", &cause)]))?;
    let login = settings
        .review
        .approval_login
        .as_deref()
        .ok_or_else(|| refuse("approval-login", &[]))?;
    let mut doc = loaded(path)?.doc;
    let matching: Vec<_> = entries(&mut doc, r)?
        .iter()
        .filter(|(head, _)| head.starts_with(&r.head))
        .map(|(head, value)| {
            serde_json::from_value::<Entry>(value.clone())
                .map(|entry| (head.clone(), entry))
                .map_err(|_| refuse("approval-record", &[]))
        })
        .collect::<Result<_>>()?;
    if let [(head, entry)] = matching.as_slice()
        && let Some(attempt) = &entry.attempt
    {
        if entry.login != login && *attempt == Attempt::Attempted {
            return Err(login_changed(&entry.login, login));
        }
        return standing_answer(path, r, head, login, &token, settings, locking, attempt);
    }
    let head = live_head(settings, r, &token)?;
    if !head.starts_with(&r.head) {
        return Err(refuse("head-moved", &[("given", &r.head), ("live", &head)]));
    }
    let attempt = update(path, r, &head, login, locking, |entry| {
        Ok(entry.attempt.clone())
    })?;
    if let Some(attempt) = &attempt {
        return standing_answer(path, r, &head, login, &token, settings, locking, attempt);
    }
    if r.hold_copilot
        && let Some(finished) = hold(settings, r, &head, &token, clock)?
    {
        return Ok(finished);
    }
    replies(settings, r, &head, &token)?;
    if let Some(text) = &comment
        && let Some(unposted) =
            post_comment(path, r, &head, login, &token, settings, locking, text)?
    {
        return Ok(unposted);
    }
    let claimed = update(path, r, &head, login, locking, |entry| {
        if entry.attempt.is_some() {
            return Ok(false);
        }
        entry.attempt = Some(Attempt::Attempted);
        Ok(true)
    })?;
    if !claimed {
        return settle(path, r, &head, login, &token, settings, locking, NOT_LANDED);
    }
    let payload = serde_json::to_vec(&json!({"commit_id":head,"event":"APPROVE","body":body}))?;
    let url = format!("repos/{}/pulls/{}/reviews", r.repo, r.pr);
    let posted = app(settings, &token).run(
        "api",
        &["api", "--method", "POST", &url, "--input", "-"],
        Some(&payload),
    );
    let (exit, stderr) = match posted {
        // The token chose the reviewer, so the POST's own answer confirms on
        // its state and head; a login the setting spells otherwise is named.
        Ok(Answer::Printed { stdout, stderr }) => {
            if let Ok(value) = serde_json::from_slice::<Value>(&stdout)
                && approves(&value, &head)
            {
                let differs = login_differs(&value, login);
                let mut confirmed = confirm(path, r, &head, login, locking, value)?;
                confirmed.detail = differs;
                return Ok(confirmed);
            }
            (Some(0), stderr)
        }
        Ok(Answer::Failed(failed)) => (failed.exit, failed.stderr),
        Err(Unrun::Runner(agent_runtime::Error::NotStarted { .. })) => {
            update(path, r, &head, login, locking, |entry| {
                entry.attempt = None;
                Ok(())
            })?;
            return Ok(reply(Status::Refused, &head, "not-started", None));
        }
        Err(_) => return settle(path, r, &head, login, &token, settings, locking, NOT_LANDED),
    };
    let refusal = if http_refusal(exit, &stderr) {
        "post-failed"
    } else {
        NOT_LANDED
    };
    let mut settled = settle(path, r, &head, login, &token, settings, locking, refusal)?;
    if settled.status == Status::Refused {
        settled.detail = Some(stderr);
    }
    Ok(settled)
}

#[allow(clippy::too_many_arguments)]
fn standing_answer(
    path: &Path,
    r: &ApproveHead,
    head: &str,
    login: &str,
    token: &str,
    settings: &Settings,
    locking: Locking,
    attempt: &Attempt,
) -> Result<ApprovedHead> {
    match attempt {
        Attempt::Confirmed { review } => {
            let mut confirmed = reply(Status::Confirmed, head, "approved", Some(review.clone()));
            confirmed.detail = login_differs(review, login);
            Ok(confirmed)
        }
        Attempt::Attempted => settle(path, r, head, login, token, settings, locking, NOT_LANDED),
    }
}

/// An attempt whose POST did not confirm itself is settled by the reviews
/// alone. Only a complete read showing no approval from the app at the
/// head proves the POST did not land: the claim then clears, so the next
/// request posts again, and `refusal` names why. An unread or partial
/// read proves nothing and keeps the claim, so no route posts twice on it.
#[allow(clippy::too_many_arguments)]
fn settle(
    path: &Path,
    r: &ApproveHead,
    head: &str,
    login: &str,
    token: &str,
    settings: &Settings,
    locking: Locking,
    refusal: &str,
) -> Result<ApprovedHead> {
    match read_back(settings, r, head, login, token) {
        Ok(Some(value)) => confirm(path, r, head, login, locking, value),
        Ok(None) => {
            update(path, r, head, login, locking, |entry| {
                if entry.attempt == Some(Attempt::Attempted) {
                    entry.attempt = None;
                }
                Ok(())
            })?;
            Ok(reply(Status::Refused, head, refusal, None))
        }
        Err(e) => Ok(unconfirmed(head, "approval-unconfirmed", &e)),
    }
}

/// An act whose answer is still lost, named by `reason`, with the failed
/// read's words.
fn unconfirmed(head: &str, reason: &str, e: &Error) -> ApprovedHead {
    let mut unknown = reply(Status::Unknown, head, reason, None);
    unknown.detail = e
        .fields()
        .into_iter()
        .find_map(|(key, value)| (key == "detail").then_some(value));
    unknown
}

/// The comment a request names, posted once at the head as the app before
/// the approval is claimed: `None` once it stands on the pull request, else
/// the answer that approves nothing. The claim is written before the POST
/// and stands while its answer is unknown, so a repeat reads the comments
/// back before it posts again.
#[allow(clippy::too_many_arguments)]
fn post_comment(
    path: &Path,
    r: &ApproveHead,
    head: &str,
    login: &str,
    token: &str,
    settings: &Settings,
    locking: Locking,
    text: &str,
) -> Result<Option<ApprovedHead>> {
    let observed = update(path, r, head, login, locking, |entry| {
        Ok(entry.comment.clone())
    })?;
    match &observed {
        Some(Posting::Posted { .. }) => return Ok(None),
        Some(Posting::Attempted) => match comment_landed(settings, r, login, token, text) {
            Ok(Some(id)) => {
                mark_comment(path, r, head, login, locking, Some(Posting::Posted { id }))?;
                return Ok(None);
            }
            Ok(None) => {}
            Err(e) => return Ok(Some(unconfirmed(head, COMMENT_UNCONFIRMED, &e))),
        },
        None => {}
    }
    let before = update(path, r, head, login, locking, |entry| {
        let before = entry.comment.clone();
        if before == observed {
            entry.comment = Some(Posting::Attempted);
        }
        Ok(before)
    })?;
    if before != observed {
        // Another call moved the claim between the two reads: its answer
        // settles the comment, and this call posts nothing.
        return Ok(match before {
            Some(Posting::Posted { .. }) => None,
            Some(Posting::Attempted) | None => {
                Some(reply(Status::Unknown, head, COMMENT_UNCONFIRMED, None))
            }
        });
    }
    let payload = serde_json::to_vec(&json!({ "body": text }))?;
    let url = format!("repos/{}/issues/{}/comments", r.repo, r.pr);
    let posted = app(settings, token).run(
        "api",
        &["api", "--method", "POST", &url, "--input", "-"],
        Some(&payload),
    );
    let detail = match posted {
        Ok(Answer::Printed { stdout, stderr }) => {
            if let Ok(comment) = serde_json::from_slice::<IssueComment>(&stdout) {
                mark_comment(
                    path,
                    r,
                    head,
                    login,
                    locking,
                    Some(Posting::Posted { id: comment.id }),
                )?;
                return Ok(None);
            }
            stderr
        }
        Ok(Answer::Failed(failed)) => {
            if http_refusal(failed.exit, &failed.stderr) {
                mark_comment(path, r, head, login, locking, None)?;
                let mut refused = reply(Status::Refused, head, "comment-failed", None);
                refused.detail = Some(failed.stderr);
                return Ok(Some(refused));
            }
            failed.detail()
        }
        Err(Unrun::Runner(agent_runtime::Error::NotStarted { .. })) => {
            mark_comment(path, r, head, login, locking, None)?;
            return Ok(Some(reply(
                Status::Refused,
                head,
                "comment-not-started",
                None,
            )));
        }
        Err(unrun) => unrun.detail(),
    };
    let mut unknown = reply(Status::Unknown, head, COMMENT_UNCONFIRMED, None);
    unknown.detail = Some(detail).filter(|text| !text.trim().is_empty());
    Ok(Some(unknown))
}

/// Records the comment `posting`; a cleared claim clears only an attempt.
fn mark_comment(
    path: &Path,
    r: &ApproveHead,
    head: &str,
    login: &str,
    locking: Locking,
    posting: Option<Posting>,
) -> Result<()> {
    update(path, r, head, login, locking, |entry| {
        if posting.is_some() || entry.comment == Some(Posting::Attempted) {
            entry.comment = posting.clone();
        }
        Ok(())
    })
}

/// The app's comment with `text` in a complete read of the pull request's
/// comments: its id, `None` where the read holds none, and the read's
/// refusal where any page is unread. The bodies are compared trimmed, so
/// the match does not rest on how GitHub stores a body's surrounding
/// whitespace.
fn comment_landed(
    settings: &Settings,
    r: &ApproveHead,
    login: &str,
    token: &str,
    text: &str,
) -> Result<Option<u64>> {
    let gh = app(settings, token);
    let comments = crate::verify::list(
        &format!("repos/{}/issues/{}/comments", r.repo, r.pr),
        |page| {
            let (stdout, _) = answered(gh.run("api", &["api", page], None), "comment-read-back")?;
            serde_json::from_slice::<Vec<IssueComment>>(&stdout)
                .map_err(|e| refuse("comment-read-back", &[("detail", &e.to_string())]))
        },
        || refuse("comment-read-back", &[("detail", "comments-capped")]),
    )?;
    Ok(comments
        .into_iter()
        .find(|comment| {
            matches!(&comment.user, Nullable::Present(user) if user.login == login)
                && comment
                    .body
                    .present()
                    .is_some_and(|body| body.trim() == text.trim())
        })
        .map(|comment| comment.id))
}

fn confirm(
    path: &Path,
    r: &ApproveHead,
    head: &str,
    login: &str,
    locking: Locking,
    value: Value,
) -> Result<ApprovedHead> {
    update(path, r, head, login, locking, |entry| {
        entry.attempt = Some(Attempt::Confirmed {
            review: value.clone(),
        });
        Ok(())
    })?;
    Ok(reply(Status::Confirmed, head, "approved", Some(value)))
}
