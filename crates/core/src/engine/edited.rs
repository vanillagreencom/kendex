//! Whether a place's copy of a package still matches what declaration
//! says it should be. A question about the disk rather than a step in
//! planning: commands ask it before deciding what they may do, and the
//! answer has three values because "we could not look" is not "we looked
//! and found nothing".

use crate::env::Env;
use crate::error::Result;
use crate::model::{ItemKind, Scope};

use super::{DriftCause, DriftState, audit};

/// Whether this place's copy of one package was edited by hand — the fact
/// behind the edited notice, the drift report's line, and a row's
/// `can_discard`. Discarding is planned as a scope plan carrying a
/// permission for one package, so a caller that does not ask this first
/// applies whatever else the scope had pending under a line about this
/// package.
///
/// Three answers, not two. A pass that could not render the declaration —
/// its source unresolved, unreadable, or no longer carrying the item —
/// emits no edit drift for it, and reading that silence as "clean" is how
/// a command tells someone there is nothing to discard while their edited
/// bytes sit on disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditedHere {
    Yes,
    No,
    /// Nothing was rendered to compare against, so nobody can say.
    Unmeasured,
}

pub fn edited_here(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<EditedHere> {
    let report = audit(env, scope)?;
    if report.drift.iter().any(|row| {
        row.kind == kind
            && row.name == name
            && row.state == DriftState::Conflict
            && matches!(row.cause, Some(DriftCause::LocalEdit | DriftCause::Both))
    }) {
        return Ok(EditedHere::Yes);
    }
    if report.unmeasured.contains(&(kind, name.to_owned())) {
        return Ok(EditedHere::Unmeasured);
    }
    Ok(EditedHere::No)
}
