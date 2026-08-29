//! The plan an apply runs: the ops in order, the scope they belong to,
//! and the line a preview draws for each.

use std::path::PathBuf;

use crate::error::Result;
use crate::model::Scope;

use super::{Op, landing};

#[derive(Debug, Clone, PartialEq)]
pub struct PlannedOp {
    /// What this op does, said for a preview.
    ///
    /// A description that names a position writes `{}` where the position
    /// goes and never the position itself; [`PlannedOp::line`] fills it in
    /// from the op. Written in, it would say where the plan first joined
    /// the path rather than where the bytes go, and the two are not the
    /// same once the landing has followed a directory somebody pointed
    /// elsewhere.
    pub description: String,
    pub op: Op,
}

impl PlannedOp {
    /// The line a preview draws for this op, with the position it acts on
    /// filled in. That position comes from the op, which is the landed
    /// one, so a confirmation and the write it asks about can only ever
    /// name one place.
    pub fn line(&self) -> String {
        let Some(path) = self.op.touched().into_iter().next() else {
            // Every op names at least one path. Without one there is no
            // position to fill in and the prose stands as written.
            return self.description.clone();
        };
        let shown = crate::names::shown(&path.display().to_string());
        self.description.replacen("{}", &shown, 1)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub scope: Scope,
    /// The canonical scope root this plan's targets were landed against,
    /// read once when the plan was made. `None` at global scope, which
    /// nothing encloses.
    ///
    /// Kept rather than derived again, because deriving it again is
    /// reading it after somebody could have moved it: a project directory
    /// renamed with a link left in its place answers `canonicalize` with
    /// the link's target, and an op landed against that would be landed
    /// against wherever the link went.
    root: Option<PathBuf>,
    pub ops: Vec<PlannedOp>,
}

impl Plan {
    /// A plan whose write targets are the places they land: the
    /// directories between the scope root and each target followed, and a
    /// target landing outside the scope refused by name. Every builder
    /// makes its plan here, so a preview names the position the bytes
    /// reach rather than the spelling the derivation joined.
    pub fn landed(scope: Scope, mut ops: Vec<PlannedOp>) -> Result<Plan> {
        let root = match scope.canonical() {
            Scope::Project { root } => Some(root),
            Scope::Global => None,
        };
        landing::land(root.as_deref(), &mut ops)?;
        Ok(Plan { scope, root, ops })
    }

    /// Take on one more op at `index`, landed against the root this plan
    /// fixed.
    ///
    /// The way to add to a plan: an op appended straight to `ops` carries
    /// whatever path its caller derived, and a caller deriving one now is
    /// deriving it from a scope it reads now. Held to this plan's root
    /// instead, and to it strictly — a target outside it is refused,
    /// where one arriving with the plan itself would not be.
    pub fn insert(&mut self, index: usize, planned: PlannedOp) -> Result<()> {
        let mut joining = [planned];
        landing::land_inside(self.root.as_deref(), &mut joining)?;
        let [planned] = joining;
        self.ops.insert(index, planned);
        Ok(())
    }

    pub fn is_empty(&self) -> bool {
        self.ops.is_empty()
    }
}
