//! Whether a controller's fleet watch runs at its turn end, and the start
//! command it is told where none does.

use super::identity::Lane;
use super::payload::Payload;
use super::{Flow, Turn, Vars};

/// Where the overseer's turn end checks its watch; it checks nothing.
#[allow(dead_code, reason = "called from the overseer's turn end")]
pub(super) fn check(_turn: &mut Turn, _vars: &Vars, _lane: &Lane, _payload: &Payload) -> Flow {
    Ok(())
}
