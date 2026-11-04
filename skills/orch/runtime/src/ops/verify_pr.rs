//! The `verify-pr` operation, the runtime's owner of a pull request's CI
//! verdict.
//! One `gh pr view` names the pull request by its number and answers its
//! current head, base and state (`verify::pull_request`); a pull request
//! that is closed or merged refuses before any verdict read; the head is
//! then judged exactly as `verify-head` judges a pinned head (`verify::run`)
//! and a final verdict is recorded as `.verification` with `source:
//! verify-pr`. The head is read afresh on every call, so a pull request
//! whose head moved between two calls is judged on the newer head and the
//! older record replaced. `pending` and an unreadable read are results the
//! caller repeats under its own budget, never verdicts, as `verify-head`
//! answers them. The poll, its budget and the wait itself stay with the
//! workflow's waiter launch; no mail nap is here, since the lane's mail
//! reaches it through the wake duty.
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::{Applied, Env, VerifyHead};
use crate::error::{Error, Result};
use crate::state::{self, Locking};
use crate::verify::wire::PullRequestState;
use crate::verify::{self, Caller, CheckReport, Status};

/// Verify a pull request's current head where it stands and record the
/// verdict. `repo` is `owner/name` and `pr` the pull request's number;
/// `required_only` is handed to the verification as `verify-head` takes it.
/// The read comes before the transition, so `apply` refuses this request as
/// `op-not-transition`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerifyPr {
    pub repo: String,
    pub pr: u64,
    #[serde(default)]
    pub required_only: bool,
}

/// The reply of one `verify-pr` call: `verify::Verified`'s fields over the
/// head the pull request answered, with the pull request's number and base
/// beside them. `head` and `base` are absent where the pull request itself
/// could not be read; `status` is then `unreadable` with that read's cause.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PrVerified {
    pub pr: u64,
    pub repo: String,
    pub status: Status,
    /// On `complete`, what was read, as the record's `reason`; on `pending`
    /// or `unreadable`, the stable cause key and the values it acted on.
    pub reason: String,
    /// What the failed program said, on an `unreadable` read failure.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    /// The schema's word on `complete`, absent otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verdict: Option<String>,
    pub checks: Vec<CheckReport>,
    /// The `record-verification` transition that committed, on `complete`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded: Option<Applied>,
}

/// Read the pull request, refuse one that is not open, verify its head and
/// record the verdict on the item at `path`. The request's forms refuse
/// before any read; a missing record refuses before any network read, as
/// `verify-head` refuses it.
#[allow(
    clippy::disallowed_methods,
    reason = "the verify-pr operation's one record read before GitHub and its one call of the verification, over the head the pull request answered"
)]
pub fn run(
    path: &Path,
    r: &VerifyPr,
    gh: &Path,
    env: &Env,
    locking: Locking,
) -> Result<PrVerified> {
    verify::validate_repo(&r.repo)?;
    if r.pr == 0 {
        return Err(Error::VerifyRequestInvalid {
            field: "pr",
            value: r.pr.to_string(),
        });
    }
    state::load(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    let pull = match verify::pull_request(gh, &r.repo, r.pr) {
        Ok(pull) => pull,
        Err(unreadable) => {
            return Ok(PrVerified {
                pr: r.pr,
                repo: r.repo.clone(),
                status: Status::Unreadable,
                reason: unreadable.reason,
                detail: unreadable.detail,
                head: None,
                base: None,
                verdict: None,
                checks: Vec::new(),
                recorded: None,
            });
        }
    };
    match pull.state {
        PullRequestState::Open => {}
        PullRequestState::Closed | PullRequestState::Merged => {
            return Err(Error::PullRequestNotOpen {
                pr: r.pr,
                state: pull.state.word(),
            });
        }
    }
    let head = VerifyHead {
        repo: r.repo.clone(),
        base: pull.base,
        head: pull.head,
        required_only: r.required_only,
    };
    let verified = verify::run(path, &head, gh, env, locking, Caller::VerifyPr)?;
    Ok(PrVerified {
        pr: r.pr,
        repo: verified.repo,
        status: verified.status,
        reason: verified.reason,
        detail: verified.detail,
        head: Some(verified.head),
        base: Some(head.base),
        verdict: verified.verdict,
        checks: verified.checks,
        recorded: verified.recorded,
    })
}
