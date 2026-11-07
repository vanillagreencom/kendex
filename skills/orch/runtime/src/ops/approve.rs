//! Exact-head approvals as the overseer's GitHub App and their once-per-head
//! attempt records. With `hold_copilot`, Copilot's work in flight on the
//! head is waited out through the current-head wait before the review
//! replies are read and the attempt is claimed.
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::copilot_wait::{self, CopilotWait};
use super::{loaded, reread};
use crate::error::{Error, Result};
use crate::schedule::Clock;
use crate::settings::Settings;
use crate::state::{self, Document, Locking};
use crate::verify::Gh;
use crate::verify::review::{self, Flight};

const APPROVALS: &str = "head_approvals";
const BOUND: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApproveHead {
    pub repo: String,
    pub pr: u64,
    pub head: String,
    pub body_file: PathBuf,
    #[serde(default)]
    pub hold_copilot: bool,
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
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    login: String,
    #[serde(default)]
    attempt: Option<Attempt>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
enum Attempt {
    Attempted,
    Confirmed { review: Value },
}

/// The refusal of an attempt a complete read-back found had not landed.
const NOT_LANDED: &str = "not-landed";

fn refuse(key: &'static str) -> Error {
    agent_runtime::Error::refused(key, &[]).into()
}

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
        .ok_or_else(|| refuse("approval-record"))?;
    root.entry(slot(r))
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(|| refuse("approval-record"))
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
    reread(|| {
        let snapshot = loaded(path)?;
        let mut doc = snapshot.doc.clone();
        let records = entries(&mut doc, r)?;
        let mut entry: Entry = match records.get(head) {
            Some(value) => {
                serde_json::from_value(value.clone()).map_err(|_| refuse("approval-record"))?
            }
            None => Entry {
                login: login.into(),
                attempt: None,
            },
        };
        if entry.login != login {
            return Err(refuse("approval-login-changed"));
        }
        let answer = f(&mut entry)?;
        records.insert(head.into(), serde_json::to_value(entry)?);
        state::store(path, &snapshot, &doc, locking)?;
        Ok(answer)
    })
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

#[allow(
    clippy::disallowed_methods,
    reason = "the approval reads and POST use gh under the fleet's file credential, never a harness credential"
)]
fn gh(
    settings: &Settings,
    token: &str,
    args: &[&str],
    input: Option<&[u8]>,
) -> std::result::Result<std::process::Output, agent_runtime::Error> {
    let credential = credential(settings, token);
    let env: Vec<_> = credential
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_os_str()))
        .collect();
    let place = host::Place {
        cwd: Some(&settings.roots.project),
        env: &env,
    };
    match input {
        Some(bytes) => host::run_tagged_fed(
            "approve",
            "gh",
            Path::new("gh"),
            "api",
            args,
            place,
            bytes,
            BOUND,
        ),
        None => host::run_tagged_in("approve", "gh", Path::new("gh"), "api", args, place, BOUND),
    }
}

fn live_head(settings: &Settings, r: &ApproveHead, token: &str) -> Result<String> {
    let url = format!("repos/{}/pulls/{}", r.repo, r.pr);
    let output = gh(settings, token, &["api", &url, "--jq", ".head.sha"], None)
        .map_err(|_| refuse("head-read-failed"))?;
    let head = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !output.status.success() || !valid_sha(&head, 40) {
        return Err(refuse("head-read-failed"));
    }
    Ok(head)
}

fn confirms(value: &Value, login: &str, head: &str) -> bool {
    value.get("state").and_then(Value::as_str) == Some("APPROVED")
        && value.pointer("/user/login").and_then(Value::as_str) == Some(login)
        && value.get("commit_id").and_then(Value::as_str) == Some(head)
}

fn read_back(
    settings: &Settings,
    r: &ApproveHead,
    head: &str,
    login: &str,
    token: &str,
) -> Result<Option<Value>> {
    let url = format!("repos/{}/pulls/{}/reviews", r.repo, r.pr);
    let output = gh(
        settings,
        token,
        &["api", &url, "--paginate", "--slurp"],
        None,
    )
    .map_err(|_| refuse("approval-read-back"))?;
    if !output.status.success() {
        return Err(refuse("approval-read-back"));
    }
    let pages: Vec<Vec<Value>> =
        serde_json::from_slice(&output.stdout).map_err(|_| refuse("approval-read-back"))?;
    if pages.is_empty() {
        return Err(refuse("approval-read-back"));
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
    let keyring = if has_env {
        false
    } else {
        host::run_tagged_in(
            "approve",
            "gh",
            Path::new("gh"),
            "auth",
            &["auth", "status"],
            host::Place {
                cwd: Some(&settings.roots.project),
                env: &env,
            },
            BOUND,
        )
        .is_ok_and(|out| out.status.success())
    };
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
    .map_err(|_| refuse("review-replies"))?;
    let expected = format!("review-replies: pass head={head}");
    if !output.status.success() || String::from_utf8_lossy(&output.stdout).trim() != expected {
        return Err(refuse("review-replies"));
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
    let bound =
        copilot_wait::bound(&settings.review).map_err(|_| refuse("copilot-hold-setting"))?;
    let gh = Gh::with_env(Path::new("gh"), credential(settings, token));
    match review::copilot_flight(&gh, &r.repo, r.pr, head) {
        Ok(Flight::Work(_)) => {}
        Ok(Flight::Settled { .. } | Flight::None) => return Ok(None),
        Err(_) => return Err(refuse("copilot-read-failed")),
    }
    let request = CopilotWait {
        repo: r.repo.clone(),
        pr: r.pr,
        bound,
    };
    let waited = copilot_wait::run_with(&request, &gh, clock)?;
    if waited.status != "complete" {
        return Err(refuse("copilot-read-failed"));
    }
    if waited.head.as_deref() != Some(head) {
        return Err(refuse("head-moved"));
    }
    if waited.state != Some("expired") {
        return Ok(Some(reply(
            Status::Finished,
            head,
            "copilot-finished",
            None,
        )));
    }
    if live_head(settings, r, token)? != head {
        return Err(refuse("head-moved"));
    }
    Ok(None)
}

fn reply(status: Status, head: &str, reason: &str, review: Option<Value>) -> ApprovedHead {
    ApprovedHead {
        status,
        head: head.into(),
        reason: reason.into(),
        review,
    }
}

fn http_refusal(output: &std::process::Output) -> bool {
    // gh exits 4 holding no credential; GitHub's 4xx answer exits 1 as a
    // transport failure does, so only gh's own status line tells them apart.
    output.status.code() == Some(4) || review::refused_by_github(&host::stderr_text(output))
}

pub fn run(
    path: &Path,
    r: &ApproveHead,
    settings: &Settings,
    locking: Locking,
    clock: &dyn Clock,
) -> Result<ApprovedHead> {
    if r.pr == 0 || !valid_sha(&r.head, 7) || crate::verify::validate_repo(&r.repo).is_err() {
        return Err(refuse("approval-request"));
    }
    let body = std::fs::read_to_string(&r.body_file).map_err(|_| refuse("body-file"))?;
    // The credential, the app's login and the host must be read values; a
    // reader credential only a shell reads stays the router's.
    if settings
        .review
        .approval_unread
        .iter()
        .any(|key| !matches!(key.as_str(), "GH_TOKEN" | "GITHUB_TOKEN" | "GH_BOT_TOKEN"))
    {
        return Err(refuse("approval-setting-unread"));
    }
    let token = crate::watch::security::read_token(settings.review.approval_token_file.as_deref())
        .map_err(|_| refuse("credential"))?;
    let login = settings
        .review
        .approval_login
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| refuse("approval-login"))?;
    let mut doc = loaded(path)?.doc;
    let matching: Vec<_> = entries(&mut doc, r)?
        .iter()
        .filter(|(head, _)| head.starts_with(&r.head))
        .map(|(head, value)| {
            serde_json::from_value::<Entry>(value.clone())
                .map(|entry| (head.clone(), entry))
                .map_err(|_| refuse("approval-record"))
        })
        .collect::<Result<_>>()?;
    if let [(head, entry)] = matching.as_slice()
        && let Some(attempt) = &entry.attempt
    {
        if entry.login != login {
            return Err(refuse("approval-login-changed"));
        }
        return standing_answer(path, r, head, login, &token, settings, locking, attempt);
    }
    let head = live_head(settings, r, &token)?;
    if !head.starts_with(&r.head) {
        return Err(refuse("head-moved"));
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
    let posted = gh(
        settings,
        &token,
        &["api", "--method", "POST", &url, "--input", "-"],
        Some(&payload),
    );
    match posted {
        Ok(output) => {
            if output.status.success()
                && let Ok(value) = serde_json::from_slice::<Value>(&output.stdout)
                && confirms(&value, login, &head)
            {
                confirm(path, r, &head, login, locking, value)
            } else {
                let refusal = if http_refusal(&output) {
                    "post-failed"
                } else {
                    NOT_LANDED
                };
                settle(path, r, &head, login, &token, settings, locking, refusal)
            }
        }
        Err(agent_runtime::Error::NotStarted { .. }) => {
            update(path, r, &head, login, locking, |entry| {
                entry.attempt = None;
                Ok(())
            })?;
            Ok(reply(Status::Refused, &head, "not-started", None))
        }
        Err(_) => settle(path, r, &head, login, &token, settings, locking, NOT_LANDED),
    }
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
        Attempt::Confirmed { review } => Ok(reply(
            Status::Confirmed,
            head,
            "approved",
            Some(review.clone()),
        )),
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
        Err(_) => Ok(reply(Status::Unknown, head, "approval-unconfirmed", None)),
    }
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
