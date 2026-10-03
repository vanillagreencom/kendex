//! The plan an apply runs: the ops in order, the scope they belong to,
//! and the line a preview draws for each.

use std::path::PathBuf;

use crate::error::Result;
use crate::model::Scope;

use super::{Op, Pre, landing};

/// Read-only evidence a record write must still match at execution.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ReadCheck {
    File {
        path: PathBuf,
        pre: Pre,
    },
    PiPackage {
        path: PathBuf,
        hash: String,
    },
    /// A directory the plan may only write inside of. The one judge of
    /// "the project folder is still there": every write creates the
    /// directories above it, so a plan aimed at a registered project whose
    /// folder went away would rebuild that folder rather than refuse, and
    /// the folder can go away between the plan and the confirmation that
    /// runs it.
    Directory {
        path: PathBuf,
    },
}

impl ReadCheck {
    pub(crate) fn check(&self) -> Result<()> {
        match self {
            Self::File { path, pre } => pre.check(path),
            Self::Directory { path } => match path.is_dir() {
                true => Ok(()),
                false => Err(crate::error::CoreError::ProjectRootMissing { path: path.clone() }),
            },
            Self::PiPackage { path, hash } => {
                if matches!(crate::pi_ext::owned_package_exact_hash(path), Ok(Some(actual)) if &actual == hash)
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
/// position written into it. [`PlannedOp::description_parts`] takes the
/// position from the op, which is the landed one, so a preview and the write it
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

/// One part of an op's preview, retaining a landed path's boundary.
#[derive(Debug)]
pub enum DescriptionPart<'a> {
    Text(&'a str),
    /// The escaped display spelling of the position the op acts on.
    Path(String),
}

impl PlannedOp {
    /// The description and its landed position, kept separate so a
    /// presenter can preserve the path when it wraps the surrounding text.
    pub fn description_parts(&self) -> Vec<DescriptionPart<'_>> {
        let Description { opening, closing } = &self.description;
        let mut parts = vec![DescriptionPart::Text(opening)];
        if let Some(closing) = closing {
            if let Some(at) = self.op.touched().into_iter().next() {
                parts.push(DescriptionPart::Path(crate::names::shown(
                    &at.display().to_string(),
                )));
            }
            parts.push(DescriptionPart::Text(closing));
        }
        parts
    }

    /// The flat preview and approval-comparison spelling of the same parts.
    pub fn line(&self) -> String {
        self.description_parts()
            .iter()
            .map(|part| match part {
                DescriptionPart::Text(text) => *text,
                DescriptionPart::Path(path) => path.as_str(),
            })
            .collect()
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
        // A project plan binds to its root being there. Every write makes
        // the directories above it, so a plan landed inside a root that
        // went away between the plan and the apply would rebuild that root
        // rather than refuse — and the gap is human-scale wherever a
        // confirmation sits in it. Seeded at the one constructor every
        // builder goes through, so no plan can be the one that forgot.
        let reads = root
            .iter()
            .map(|root| ReadCheck::Directory { path: root.clone() })
            .collect();
        Ok(Plan {
            scope,
            root,
            ops,
            reads,
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

    /// Remove the directories this plan's removals left empty, from each
    /// removed path's parent up to the project root, which stays. An
    /// empty harness directory is what detection reads as that tool set
    /// up here, so a tool this project dropped would otherwise keep
    /// reading as present. `remove_dir` takes only an empty directory, so
    /// one holding anything at the moment it is asked stays, and the walk
    /// up from it stops there. Run once the writes are final: a rollback
    /// restores into the directories it would otherwise find gone.
    pub(super) fn prune_emptied(&self) {
        let Some(root) = &self.root else {
            return;
        };
        for planned in &self.ops {
            let removed = match &planned.op {
                Op::Trash { path, .. } => path,
                Op::PiRemove { package, .. } => package,
                Op::WriteFile { .. }
                | Op::WriteTree { .. }
                | Op::Symlink { .. }
                | Op::Rename { .. }
                | Op::EditFile { .. }
                | Op::WriteLock { .. }
                | Op::WriteManifest { .. }
                | Op::WriteExecutable { .. }
                | Op::WritePrivateFile { .. }
                | Op::GitConfigSwap { .. } => continue,
            };
            let mut dir = removed.parent();
            while let Some(at) = dir {
                if at == root || !at.starts_with(root) {
                    break;
                }
                match std::fs::remove_dir(at) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(_) => break,
                }
                dir = at.parent();
            }
        }
    }
}
