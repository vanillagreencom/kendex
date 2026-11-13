//! Process tests of a controller's own turn end: the overseer's and a
//! managed Jarvis session's context, marks and hand-over, the wake and the
//! overseer's mail. Every row runs the real `orch-runtime turn-end` in a
//! [`support::TurnWorld`].
#![allow(
    clippy::disallowed_methods,
    reason = "the rows plant records and read the answer of the binary they start"
)]

#[path = "support.rs"]
mod support;
