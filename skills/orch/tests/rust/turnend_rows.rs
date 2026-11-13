//! Process tests of a session's own event rows written at its turn end: a
//! session with no lane item, a Pi lane's turn and a managed Jarvis
//! session. Every row runs the real `orch-runtime turn-end` in a
//! [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;
