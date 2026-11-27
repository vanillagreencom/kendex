//! The kind of a provider's stop, and the one action each kind takes.
//!
//! A harness states a failed turn in its own words: Claude Code's
//! StopFailure `error`, Pi's failed `stopReason`, Codex's `codex_error_info`
//! and Copilot's `session.error` type and status, each recorded from a real
//! or injected stop under the integration tests' `fixtures/stops/`. This
//! module holds the one table of those words. The row and record readers
//! (`crate::rows`) judge with it, and the fleet watch's continuation reads a
//! kept word's kind here.
//!
//! [`action`] turns a kind, the stop's age, the session's kind and what the
//! account walk found into the one thing to do next. The caller supplies the
//! age and the walk's reading and carries the action out.

pub mod reset;

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::accounts::ResetHolder;
use crate::harness::Harness;
use crate::observe::WallKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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

/// Each harness's words for a failed turn and the kind each names. A
/// Claude or Pi word absent here names no stop: the turn ended for a reason
/// the overseer reads from its idle line.
///
/// - Claude Code's StopFailure `error`: `server_error` for a 529, a broken
///   stream and a dropped connection alike, and `billing_error` for "Credit
///   balance is too low" (`claude-*.json`). Its safety refusal shares
///   `invalid_request` with deterministic refusals such as a prompt too
///   long, so the rows reader names it `refusal` by its message
///   ([`claude_refusal`]).
/// - Codex's `codex_error_info`: `server_overloaded`, `other` for a broken
///   stream or a dropped connection, `invalid_prompt` for a flagged prompt,
///   and `usage_limit_exceeded` for a limit and for an out-of-credit
///   workspace alike (`codex-*.jsonl`). The limit and sign-in words are the
///   variants Codex 0.172.0's binary names beside them.
/// - Copilot's `session.error` `errorType`: `query` for every failure but
///   a 429, which is `rate_limit` (`copilot-*.jsonl`). Its sign-in and quota
///   types are the categories Copilot CLI 1.0.116's SDK names
///   (`copilot-sdk/generated/session-events.d.ts`, `ErrorData.errorType`).
/// - [`API_ERROR`]: the watch's word for a Codex or Copilot turn whose pane
///   shows the provider's error (`crate::observe::IdleTurn::ApiError`).
/// - Pi's `error`: the carrier's StopFailure and a lane Stop row's
///   `stop_reason`. Pi's limit and sign-in are read from the message
///   instead (`crate::rows`).
const WORDS: &[(Harness, &str, Kind)] = &[
    (Harness::Claude, "rate_limit", Kind::Usage),
    (Harness::Claude, "billing_error", Kind::Usage),
    (Harness::Claude, "authentication_failed", Kind::Auth),
    (Harness::Claude, "oauth_org_not_allowed", Kind::Auth),
    (Harness::Claude, "account_on_hold", Kind::Auth),
    (Harness::Claude, "server_error", Kind::Provider),
    (Harness::Claude, REFUSAL, Kind::Provider),
    (Harness::Codex, "usage_limit_exceeded", Kind::Usage),
    (Harness::Codex, "session_budget_exceeded", Kind::Usage),
    (Harness::Codex, "rate_limit_exceeded", Kind::Usage),
    (Harness::Codex, "api_key_spend_limit_exceeded", Kind::Usage),
    (Harness::Codex, "project_spend_limit_exceeded", Kind::Usage),
    (
        Harness::Codex,
        "organization_spend_limit_exceeded",
        Kind::Usage,
    ),
    (Harness::Codex, "unauthorized", Kind::Auth),
    (Harness::Codex, "server_overloaded", Kind::Provider),
    (Harness::Codex, "other", Kind::Provider),
    (Harness::Codex, "invalid_prompt", Kind::Provider),
    (Harness::Codex, API_ERROR, Kind::Provider),
    (Harness::Copilot, "rate_limit", Kind::Usage),
    (Harness::Copilot, "quota", Kind::Usage),
    (Harness::Copilot, "session_limits", Kind::Usage),
    (Harness::Copilot, "authentication", Kind::Auth),
    (Harness::Copilot, "authorization", Kind::Auth),
    (Harness::Copilot, "query", Kind::Provider),
    (Harness::Copilot, API_ERROR, Kind::Provider),
    (Harness::Pi, "error", Kind::Provider),
];

/// The rows reader's word for Claude Code's safety refusal.
pub const REFUSAL: &str = "refusal";

/// The watch's word for a Codex or Copilot turn whose pane shows the
/// provider's error: the cause its resume row names.
pub const API_ERROR: &str = "api-error";

/// The marks of Claude Code 2.1.332's safety refusal, each a string its
/// bundle builds: the usage-policy link, under "can't help with this"
/// (`claude-safety.json`) and in "safeguards flagged this message (…)", and
/// that sentence's own words, which one form prints without the link. A
/// prompt too long and the other `invalid_request` refusals carry neither.
const REFUSAL_MARKS: [&str; 2] = [
    "https://www.anthropic.com/legal/aup",
    "safeguards flagged this message",
];

/// Whether a Claude Code StopFailure's message is its safety refusal.
pub fn claude_refusal(message: &str) -> bool {
    REFUSAL_MARKS.iter().any(|mark| message.contains(mark))
}

/// The word a Claude Code StopFailure's row carries: [`REFUSAL`] for its
/// safety refusal, which Claude Code types `invalid_request` like refusals no
/// continuation clears, else the harness's own `error`. The turn-end writer
/// writes it, so the lane row names the refusal without the message.
pub fn claude_failure_word<'a>(error: Option<&'a str>, message: &str) -> Option<&'a str> {
    if claude_refusal(message) {
        Some(REFUSAL)
    } else {
        error
    }
}

/// Copilot's HTTP status for a refused sign-in.
const COPILOT_SIGNED_OUT: u16 = 401;
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

/// The kind of a failed turn that a row states with its word and its HTTP
/// status. Copilot types a refused sign-in and a spent pool by status. A
/// Codex or Copilot failure row comes only from the turn its own record
/// shows failed, so a word the table does not list there is still a
/// provider stop. A Claude or Pi word settles the kind alone.
pub fn of_failure(harness: Harness, cause: Option<&str>, status: Option<u16>) -> Option<Kind> {
    match (harness, status) {
        (Harness::Copilot, Some(COPILOT_SIGNED_OUT)) => return Some(Kind::Auth),
        (Harness::Copilot, Some(COPILOT_SPENT)) => return Some(Kind::Usage),
        (Harness::Claude | Harness::Codex | Harness::Copilot | Harness::Pi, _) => {}
    }
    let named = cause.and_then(|cause| of_cause(harness, cause));
    match harness {
        Harness::Codex | Harness::Copilot => Some(named.unwrap_or(Kind::Provider)),
        Harness::Claude | Harness::Pi => named,
    }
}

impl From<WallKind> for Kind {
    fn from(wall: WallKind) -> Kind {
        match wall {
            WallKind::Usage => Kind::Usage,
            WallKind::Auth => Kind::Auth,
        }
    }
}

impl Kind {
    /// The wall this kind is: an account's limit or its sign-in.
    pub fn wall(self) -> Option<WallKind> {
        match self {
            Kind::Usage => Some(WallKind::Usage),
            Kind::Auth => Some(WallKind::Auth),
            Kind::Provider | Kind::Exited => None,
        }
    }
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

    /// Who is told of an unused limit reset: pressing one is Jarvis's step
    /// in the account's browser, so a worker's and an overseer's notice go
    /// to Jarvis, and Jarvis's own to the owner's channel.
    pub fn reset_owner(self) -> Owner {
        match self {
            Session::Worker | Session::Overseer => Owner::Jarvis,
            Session::Jarvis => Owner::Channel,
        }
    }
}

/// What the account walk found for a stop, as the caller read it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ground<'a> {
    /// The stopped session's own account has room.
    pub own_room: bool,
    /// Another entry in the walk has room: on another provider for a
    /// provider stop, on another account for every other kind.
    pub room: bool,
    /// No entry has room, and the soonest reset among them is known.
    pub reset: bool,
    /// The accounts holding an unused limit reset that the stopped
    /// session's pick could take: [`crate::accounts::Roster::reset_holders`]
    /// over the question its walk asks.
    pub resets: &'a [ResetHolder],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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
    /// No entry has room, but these accounts hold an unused limit reset,
    /// each named by its directory: tell whoever presses one once, then
    /// take `then`, the wait or the stop the decision takes without them.
    NotifyReset {
        to: Owner,
        accounts: Vec<ResetHolder>,
        then: Box<Action>,
    },
}

/// How long a provider that is not answering is resumed on its own account
/// before the session moves to another provider: the owner's 30 minutes,
/// about seven resumes at one per watch pass.
pub const PROVIDER_PATIENCE: Duration = Duration::from_secs(30 * 60);

/// A stop's episode as its caller recorded it: the epoch seconds its first
/// failed turn was read at and its latest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Episode {
    pub since: u64,
    pub last: u64,
}

/// The start of the `recorded` episode where a failure read at `now`
/// continues it, else `None`, and that failure opens a new episode. The
/// episode stands while each failure follows the last one read within
/// [`PROVIDER_PATIENCE`]. A pane read busy on every pass hides the turn
/// that returned between them, and a resumed turn that failed again moves
/// the row position as a returned one does, so a failure read after a whole
/// patience with none read opens a new episode.
pub fn standing(recorded: Option<Episode>, now: u64) -> Option<u64> {
    recorded
        .filter(|episode| now.saturating_sub(episode.last) <= PROVIDER_PATIENCE.as_secs())
        .map(|episode| episode.since)
}

/// The action for a stop of `kind` first read `age` ago on a `session`,
/// over the walk's `ground`. A session stops for good, and its owner is
/// told, only when no entry in the walk has room and, for a limit or an
/// exited harness, none has a known reset. Where an account lists an
/// unused limit reset, that wait or stop comes as [`Action::NotifyReset`]:
/// the caller tells its `to` once, then takes its `then`, a final
/// [`Action::Notify`] included. An ended sign-in never waits for a reset.
/// A provider stop never ends so: its own account still has room.
pub fn action(kind: Kind, age: Duration, session: Session, ground: Ground) -> Action {
    let press_or = |otherwise: Action| {
        if ground.resets.is_empty() {
            otherwise
        } else {
            Action::NotifyReset {
                to: session.reset_owner(),
                accounts: ground.resets.to_vec(),
                then: Box::new(otherwise),
            }
        }
    };
    let stop = Action::Notify {
        to: session.owner(),
    };
    let move_or_wait = |tell: Option<Owner>| {
        if ground.room {
            Action::MoveAccount { tell }
        } else if ground.reset {
            press_or(Action::WaitForReset)
        } else {
            press_or(stop.clone())
        }
    };
    match kind {
        Kind::Usage => move_or_wait(None),
        // A reset does not repair a sign-in.
        Kind::Auth if ground.room => Action::MoveAccount {
            tell: Some(session.owner()),
        },
        Kind::Auth => press_or(stop.clone()),
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
        let held = [ResetHolder {
            config_dir: "/h/.1codex".to_owned(),
            alias: "1codex".to_owned(),
        }];
        let ground = |own_room, room, reset| Ground {
            own_room,
            room,
            reset,
            resets: &[],
        };
        let holding = |reset| Ground {
            resets: &held,
            ..ground(false, false, reset)
        };
        let press = |to, then| Action::NotifyReset {
            to,
            accounts: held.to_vec(),
            then: Box::new(then),
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
            // A reset does not repair a sign-in: no other account notifies.
            (
                Kind::Auth,
                MINUTE,
                Session::Worker,
                ground(false, false, true),
                Action::Notify {
                    to: Owner::Overseer,
                },
            ),
            // An exited harness starts again on its own account with room.
            (
                Kind::Exited,
                MINUTE,
                Session::Jarvis,
                ground(true, false, false),
                Action::Resume,
            ),
            // An unused reset is named before a wait, before a stop, and
            // before a stop for an ended sign-in.
            (
                Kind::Usage,
                MINUTE,
                Session::Worker,
                holding(true),
                press(Owner::Jarvis, Action::WaitForReset),
            ),
            (
                Kind::Exited,
                MINUTE,
                Session::Jarvis,
                holding(false),
                press(Owner::Channel, Action::Notify { to: Owner::Channel }),
            ),
            (
                Kind::Auth,
                MINUTE,
                Session::Overseer,
                holding(false),
                press(Owner::Jarvis, Action::Notify { to: Owner::Jarvis }),
            ),
            // An account with room is taken over a reset someone must press.
            (
                Kind::Usage,
                MINUTE,
                Session::Worker,
                Ground {
                    resets: &held,
                    ..ground(false, true, true)
                },
                Action::MoveAccount { tell: None },
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
