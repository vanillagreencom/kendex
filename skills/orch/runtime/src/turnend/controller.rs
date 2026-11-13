//! A controller's own turn end: the overseer's and a managed Jarvis
//! session's context, marks and hand-over, judged on the role `role` reads.

use super::identity::Lane;
use super::payload::Payload;
use super::{Flow, Turn, Vars};

/// Where a Copilot overseer's start is told it has no context reader; it
/// tells nothing.
pub(super) fn context_reader_check(
    _turn: &mut Turn,
    _vars: &Vars,
    _lane: &Lane,
    _payload: &Payload,
) -> Flow {
    Ok(())
}

/// Where the overseer's context is judged at its tool call; it judges
/// nothing.
pub(super) fn overseer_tool_check(
    _turn: &mut Turn,
    _vars: &Vars,
    _lane: &Lane,
    _payload: &Payload,
) -> Flow {
    Ok(())
}
