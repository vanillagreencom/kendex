//! The plan an apply runs: the ops in order, the scope they belong to,
//! and the line a preview draws for each.

use std::path::PathBuf;

use crate::error::Result;
use crate::model::Scope;

use super::{Op, Pre, landing};

/// Read-only evidence a record write must still match at execution.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ReadCheck {
    File { path: PathBuf, pre: Pre },
    PiPackage { path: PathBuf, hash: String },
}

impl ReadCheck {
    pub(super) fn check(&self) -> Result<()> {
        match self {
            Self::File { path, pre } => pre.check(path),
            Self::PiPackage { path, hash } => {
                if matches!(crate::pi_ext::package_hash(path), Ok(Some(actual)) if &actual == hash)
                {
                    Ok(())
                } else {
                    Err(crate::error::CoreError::PlanStale { path: path.clone() })
                }
            }
        }
    }
}

/// What one op does, said for a preview.
///
/// A description that names the position its op acts on is kept as the two
/// halves that position sits between, never as a sentence with the
/// position written into it. [`PlannedOp::line`] takes the position from
/// the op, which is the landed one, so a preview and the write it
/// describes can only ever name one place.
///
/// Two halves rather than a marker inside the sentence: a marker is text,
/// and text a search looks for is text some name is allowed to be. A skill
/// called `{}` is a legal name ([`crate::names::segment_problem`]), and
/// the sentence that carries it must survive being drawn.
#[derive(Debug, Clone, PartialEq)]
pub struct Description {
    opening: String,
    /// What follows the position. `None` where this description names no
    /// position at all, which is most of them.
    closing: Option<String>,
}

impl Description {
    /// A description naming the position its op acts on, between these two
    /// halves. Either may be empty; neither holds the position.
    pub fn around(opening: impl Into<String>, closing: impl Into<String>) -> Description {
        Description {
            opening: opening.into(),
            closing: Some(closing.into()),
        }
    }
}

impl From<String> for Description {
    fn from(said: String) -> Description {
        Description {
            opening: said,
            closing: None,
        }
    }
}

impl From<&str> for Description {
    fn from(said: &str) -> Description {
        said.to_owned().into()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlannedOp {
    pub description: Description,
    pub op: Op,
}

impl PlannedOp {
    /// The line a preview draws for this op, with the position it acts on
    /// filled in.
    pub fn line(&self) -> String {
        let Description { opening, closing } = &self.description;
        let Some(closing) = closing else {
            return opening.clone();
        };
        let Some(at) = self.op.touched().into_iter().next() else {
            // Every op names at least one path. Without one there is no
            // position to draw and the halves close over nothing.
            return format!("{opening}{closing}");
        };
        let at = crate::names::shown(&at.display().to_string());
        format!("{opening}{at}{closing}")
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
    pub(crate) reads: Vec<ReadCheck>,
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
        Ok(Plan {
            scope,
            root,
            ops,
            reads: Vec::new(),
        })
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
