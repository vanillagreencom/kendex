//! A session's own event rows: a session with no lane item, a Pi lane's
//! turn and a managed Jarvis session, each written through agent-runtime's
//! rows writer.

use super::identity::Lane;
use super::payload::Payload;
use super::{Flow, Turn, Vars};

/// Where a session with no lane writes its own event row; it writes none.
/// The row arm and the overseer's turn end both write through here.
pub(super) fn session_row(
    _turn: &mut Turn,
    _vars: &Vars,
    _lane: &Lane,
    _payload: &Payload,
) -> Flow {
    Ok(())
}

/// Where a Pi lane's turn row is written; it writes none.
pub(super) fn lane_row(_turn: &mut Turn, _vars: &Vars, _lane: &Lane, _payload: &Payload) -> Flow {
    Ok(())
}

/// Where a managed Jarvis session's row is written; it writes none.
pub(super) fn jarvis_row(_turn: &mut Turn, _vars: &Vars, _lane: &Lane, _payload: &Payload) -> Flow {
    Ok(())
}
