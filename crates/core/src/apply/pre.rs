//! What a mutation binds to: the state its plan was computed from.
//!
//! Every op revalidates its precondition immediately before running, so a
//! plan that went stale between the preview and the apply fails instead of
//! acting on a world it never looked at (invariant 7).

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::error::{CoreError, Result};
use crate::hash::{hash_tree, hash_tree_as_is};

/// A precondition every mutation revalidates immediately before running —
/// plans bind to the observed state they were computed from (invariant 7).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(tag = "pre", rename_all = "kebab-case")]
pub enum Pre {
    Absent,
    /// The bytes reachable at the path — through a link, if one sits there —
    /// still hash to this. Whether a link may sit there at all is decided at
    /// plan time (a foreign one is a conflict); a user's own symlinked
    /// settings file is edited in place, link kept, target updated.
    HashIs {
        hash: String,
    },
    SymlinkTo {
        target: PathBuf,
    },
    /// The entries at and beneath the path, as they sit: files by bytes,
    /// links by target, directories by presence, no link followed. What
    /// every rename source binds to, a single file included — a file
    /// swapped for a link to the same bytes is not the file the plan
    /// looked at. What a directory move binds to
    /// — a rename carries the entries themselves, so a dangling link is
    /// part of what the plan proved it may move, never a reason to refuse
    /// the scope. A pipe, socket or device is refused at planning, named:
    /// the journal could not snapshot the move.
    TreeIs {
        hash: String,
    },
    Any,
}

impl Pre {
    /// What a plan that rewrites `path` wholesale binds to: the bytes seen
    /// at plan time, or the absence seen at plan time.
    pub fn observed(path: &Path) -> Result<Pre> {
        match path.is_file() {
            true => Ok(Pre::HashIs {
                hash: hash_tree(path)?,
            }),
            false => Ok(Pre::Absent),
        }
    }

    /// What a plan that moves `path` whole binds to: the entries as they
    /// sit now. The one pairing of `TreeIs` with the hash that checks it.
    pub fn tree_as_is(path: &Path) -> Result<Pre> {
        Ok(Pre::TreeIs {
            hash: hash_tree_as_is(path)?,
        })
    }

    /// Whether this precondition binds to there being nothing, rather
    /// than to content.
    ///
    /// Asked, never matched: a caller matching the variant itself stops
    /// seeing the question the day a second spelling of "nothing is here"
    /// appears.
    pub fn binds_nothing(&self) -> bool {
        matches!(self, Pre::Absent)
    }

    /// [`Pre::check`] for tests outside the apply module — the same
    /// judgment, so a test cannot pass against a check the apply does not
    /// make.
    #[cfg(test)]
    pub fn check_for_test(&self, path: &Path) -> Result<()> {
        self.check(path)
    }

    pub(super) fn check(&self, path: &Path) -> Result<()> {
        let ok = match self {
            Pre::Any => true,
            Pre::Absent => !path.exists() && !path.is_symlink(),
            Pre::HashIs { hash } => {
                path.exists() && hash_tree(path).map(|h| h == *hash).unwrap_or(false)
            }
            Pre::SymlinkTo { target } => {
                path.is_symlink() && fs::read_link(path).ok().as_deref() == Some(target)
            }
            Pre::TreeIs { hash } => hash_tree_as_is(path).map(|h| h == *hash).unwrap_or(false),
        };
        if ok {
            Ok(())
        } else {
            Err(CoreError::PlanStale {
                path: path.to_path_buf(),
            })
        }
    }
}
