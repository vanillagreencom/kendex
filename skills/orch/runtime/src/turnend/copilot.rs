//! A Copilot session's compaction and context reading, which its hooks hand
//! to the turn end beside the turn end itself.

use super::identity::Lane;
use super::payload::Payload;
use super::{Flow, Turn, Vars};

/// Where a Copilot lead's automatic compaction is flagged; it flags none.
pub(super) fn compaction_mark(
    _turn: &mut Turn,
    _vars: &Vars,
    _lane: &Lane,
    _payload: &Payload,
) -> Flow {
    Ok(())
}

/// Where a Copilot session's context reading is recorded; it records none.
pub(super) fn usage_read(_turn: &mut Turn, _vars: &Vars, _lane: &Lane, _payload: &Payload) -> Flow {
    Ok(())
}
