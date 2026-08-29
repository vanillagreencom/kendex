//! The plan an apply runs: the ops in order, and the scope they belong
//! to.

use crate::error::Result;
use crate::model::Scope;

use super::{Op, landing};

#[derive(Debug, Clone, PartialEq)]
pub struct PlannedOp {
    pub description: String,
    pub op: Op,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub scope: Scope,
    pub ops: Vec<PlannedOp>,
}

impl Plan {
    /// A plan whose write targets are the places they land: the
    /// directories between the scope root and each target followed, and a
    /// target landing outside the scope refused by name. Every builder
    /// makes its plan here, so a preview names the position the bytes
    /// reach rather than the spelling the derivation joined.
    pub fn landed(scope: Scope, mut ops: Vec<PlannedOp>) -> Result<Plan> {
        landing::land(&scope, &mut ops)?;
        Ok(Plan { scope, ops })
    }

    pub fn is_empty(&self) -> bool {
        self.ops.is_empty()
    }
}
