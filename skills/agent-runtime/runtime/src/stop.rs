//! The kind of a provider's stop, and the one action each kind takes.
//!
//! A harness states a failed turn in its own words: Claude Code's
//! StopFailure `error`, Pi's failed `stopReason`, Codex's `codex_error_info`
//! and Copilot's `session.error` type and status, each recorded from a real
//! or injected stop under the integration tests' `fixtures/stops/`. This
//! module holds the one table of those words. The row and record readers
//! (`crate::rows`) judge with it, and a caller that kept a stop's word reads
//! the word's kind here, never from a list of its own.
//!
//! [`action`] turns a kind, the stop's age, the session's kind and what the
//! account walk found into the one thing to do next. The caller supplies the
//! age and the walk's reading and carries the action out.

pub mod reset;

use std::time::Duration;

use serde::Serialize;

use crate::harness::Harness;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    /// The account's limit: a usage window, or credit or a pool the account
    /// has spent.
    Usage,
    /// The account's sign-in ended or was refused.
    Auth,
    /// The provider did not answer the turn: an overload or a server error,
    /// a broken stream, a dropped connection or a safety flag. Another
    /// account of the same provider changes nothing.
    Provider,
    /// The harness process is gone.
    Exited,
}

/// Each harness's words for a failed turn and the kind each names. A word
/// absent here names no stop: the turn ended for a reason the overseer
/// reads from its idle line.
///
/// - Claude Code's StopFailure `error`: `server_error` for a 529, a broken
///   stream and a dropped connection alike, `invalid_request` for a safety
///   refusal and `billing_error` for "Credit balance is too low"
///   (`claude-*.json`).
/// - Codex's `codex_error_info`: `server_overloaded`, `other` for a broken
///   stream or a dropped connection, `invalid_prompt` for a flagged prompt,
///   and `usage_limit_exceeded` for a limit and for an out-of-credit
///   workspace alike (`codex-*.jsonl`).
/// - Copilot's `session.error` `errorType`: `query` for every failure but
///   a 429, which is `rate_limit` (`copilot-*.jsonl`).
/// - `api-error`: the watch's word for a Codex or Copilot turn whose pane
///   shows the provider's error (`crate::observe::IdleTurn::ApiError`).
/// - Pi's `error`: the carrier's StopFailure and a lane Stop row's
///   `stop_reason`. Pi's limit and sign-in are read from the message
///   instead (`crate::rows::judge_session`).
const WORDS: &[(Harness, &str, Kind)] = &[
    (Harness::Claude, "rate_limit", Kind::Usage),
    (Harness::Claude, "billing_error", Kind::Usage),
    (Harness::Claude, "authentication_failed", Kind::Auth),
    (Harness::Claude, "oauth_org_not_allowed", Kind::Auth),
    (Harness::Claude, "account_on_hold", Kind::Auth),
    (Harness::Claude, "server_error", Kind::Provider),
    (Harness::Claude, "invalid_request", Kind::Provider),
    (Harness::Codex, "usage_limit_exceeded", Kind::Usage),
    (Harness::Codex, "server_overloaded", Kind::Provider),
    (Harness::Codex, "other", Kind::Provider),
    (Harness::Codex, "invalid_prompt", Kind::Provider),
    (Harness::Codex, "api-error", Kind::Provider),
    (Harness::Copilot, "rate_limit", Kind::Usage),
    (Harness::Copilot, "query", Kind::Provider),
    (Harness::Copilot, "api-error", Kind::Provider),
    (Harness::Pi, "error", Kind::Provider),
];

/// Copilot's HTTP status for a spent pool, which it types `query` like any
/// other failure (`copilot-quota.jsonl`).
const COPILOT_SPENT: u16 = 402;

/// The kind of stop the harness named with `cause`.
pub fn of_cause(harness: Harness, cause: &str) -> Option<Kind> {
    WORDS
        .iter()
        .find(|(h, word, _)| *h == harness && *word == cause)
        .map(|(_, _, kind)| *kind)
}

/// The kind of a failed turn that a record states with its word and its HTTP
/// status. Copilot types a spent pool as an ordinary failure and gives its
/// status. Every other harness's word settles the kind alone.
pub fn of_failure(harness: Harness, cause: Option<&str>, status: Option<u16>) -> Option<Kind> {
    if harness == Harness::Copilot && status == Some(COPILOT_SPENT) {
        return Some(Kind::Usage);
    }
    cause.and_then(|cause| of_cause(harness, cause))
}

/// The session whose stop is judged, which names who is told.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Session {
    Worker,
    Overseer,
    Jarvis,
}

/// Who a notice goes to: a worker's overseer, an overseer's Jarvis, and the
/// owner's own channel for Jarvis.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Owner {
    Overseer,
    Jarvis,
    Channel,
}

impl Session {
    pub fn owner(self) -> Owner {
        match self {
            Session::Worker => Owner::Overseer,
            Session::Overseer => Owner::Jarvis,
            Session::Jarvis => Owner::Channel,
        }
    }
}

/// What the account walk found for a stop, as the caller read it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ground {
    /// The stopped session's own account has room.
    pub own_room: bool,
    /// Another entry in the walk has room: on another provider for a
    /// provider stop, on another account for every other kind.
    pub room: bool,
    /// No entry has room, and the soonest reset among them is known.
    pub reset: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "action", rename_all = "kebab-case")]
pub enum Action {
    /// Resume the session on its own account.
    Resume,
    /// Move the session to the walk's first account with room. `tell` is
    /// the owner who is told once, for an ended sign-in.
    MoveAccount { tell: Option<Owner> },
    /// Move the session to the walk's first entry on another provider.
    MoveProvider,
    /// Wait for the soonest reset the walk knows, then judge the stop again.
    WaitForReset,
    /// Nothing can recover the session: tell its owner once.
    Notify { to: Owner },
}

/// How long a provider that is not answering is resumed on its own account
/// before the session moves to another provider: the owner's 30 minutes,
/// about seven resumes at one per watch pass.
pub const PROVIDER_PATIENCE: Duration = Duration::from_secs(30 * 60);

/// The action for a stop of `kind` first read `age` ago on a `session`,
/// over the walk's `ground`. A session stops for good, and its owner is
/// told, only when no entry in the walk has room and none has a known
/// reset. A provider stop never ends so: its own account still has room.
pub fn action(kind: Kind, age: Duration, session: Session, ground: Ground) -> Action {
    let move_or_wait = |tell: Option<Owner>| {
        if ground.room {
            Action::MoveAccount { tell }
        } else if ground.reset {
            Action::WaitForReset
        } else {
            Action::Notify {
                to: session.owner(),
            }
        }
    };
    match kind {
        Kind::Usage => move_or_wait(None),
        Kind::Auth => move_or_wait(Some(session.owner())),
        Kind::Provider if age < PROVIDER_PATIENCE || !ground.room => Action::Resume,
        Kind::Provider => Action::MoveProvider,
        Kind::Exited if ground.own_room => Action::Resume,
        Kind::Exited => move_or_wait(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One row per action, each from the design's case that takes it.
    #[test]
    fn each_kind_age_and_ground_takes_one_action() {
        const MINUTE: Duration = Duration::from_secs(60);
        let ground = |own_room, room, reset| Ground {
            own_room,
            room,
            reset,
        };
        let rows = [
            // A provider not answering is resumed for its first 30 minutes.
            (
                Kind::Provider,
                5 * MINUTE,
                Session::Worker,
                ground(true, true, false),
                Action::Resume,
            ),
            (
                Kind::Provider,
                31 * MINUTE,
                Session::Overseer,
                ground(true, true, false),
                Action::MoveProvider,
            ),
            (
                Kind::Usage,
                MINUTE,
                Session::Worker,
                ground(false, true, false),
                Action::MoveAccount { tell: None },
            ),
            (
                Kind::Auth,
                MINUTE,
                Session::Overseer,
                ground(false, true, false),
                Action::MoveAccount {
                    tell: Some(Owner::Jarvis),
                },
            ),
            (
                Kind::Usage,
                MINUTE,
                Session::Worker,
                ground(false, false, true),
                Action::WaitForReset,
            ),
            (
                Kind::Usage,
                MINUTE,
                Session::Jarvis,
                ground(false, false, false),
                Action::Notify { to: Owner::Channel },
            ),
            // An exited harness starts again on its own account with room.
            (
                Kind::Exited,
                MINUTE,
                Session::Jarvis,
                ground(true, false, false),
                Action::Resume,
            ),
        ];
        for (kind, age, session, ground, want) in rows {
            assert_eq!(
                action(kind, age, session, ground),
                want,
                "{kind:?} {age:?} {session:?} {ground:?}"
            );
        }
    }
}
