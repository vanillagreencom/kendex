//! Process tests of a Copilot session's compaction and context reading
//! handed to the turn end. Every row runs the real `orch-runtime turn-end`
//! in a [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;
