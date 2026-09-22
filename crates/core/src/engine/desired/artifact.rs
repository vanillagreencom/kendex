//! What one desired artifact is on disk: where it lands, and what it
//! hashes to.
//!
//! Split out of `desired.rs`. Both answers are per artifact shape and
//! neither depends on anything the plan around it decided.

use std::path::PathBuf;

use crate::hash::{hash_bytes, hash_files};

use super::Artifact;

/// Every path an artifact occupies. Cursor keeps hook rules in the same dir
/// as agents and codex shares skill trees with pi: without this, the scanner
/// reports content we just wrote as someone else's.
pub fn artifact_paths(artifact: &Artifact) -> Vec<PathBuf> {
    artifact.paths()
}

/// The on-disk hash the artifact will have — for clean/dirty comparison.
/// A registration's config edits are compared by re-applying them, not by
/// hash; only its backing file has one.
pub fn artifact_disk_hash(artifact: &Artifact) -> String {
    match artifact {
        Artifact::File { bytes, .. } => hash_bytes(bytes),
        Artifact::Tree { files, .. } => hash_files(files),
        Artifact::Registration { script, .. } => match script {
            Some((_, bytes)) => hash_bytes(bytes),
            None => hash_bytes(&[]),
        },
    }
}
