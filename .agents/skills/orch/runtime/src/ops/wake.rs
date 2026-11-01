//! The wake duty's record types (step5-map § A9; decisions 118 (2), 121 Q6,
//! 135a): the shapes U5g fills. A wake is a duty action with no intent,
//! phases or obligations: it delivers to a positively idle lead, confirms
//! by a new user turn in the bound session file, and records one
//! `delivered` mark before it pastes, read on a repeat so a crash never
//! repeats a nudge. Defined here so the duty's unit touches no shared file;
//! nothing reads them yet.

use serde::{Deserialize, Serialize};

/// The mark a wake writes before it pastes: the pane it typed into, by its
/// exact key on the proven server (decision 99), and the session file's
/// user-turn count it will confirm against.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WakeMark {
    pub item: String,
    pub pane: String,
    pub server: u64,
    pub server_start: u64,
    pub turns_before: u64,
    pub at: String,
}

/// What a wake answered: confirmed by the session file, or the harness's
/// capability limit, named, where no positively idle delivery exists.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "wake", rename_all = "kebab-case")]
pub enum WakeOutcome {
    Delivered { turns_after: u64 },
    Limit { harness: String, cause: String },
}
