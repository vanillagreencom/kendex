//! What one desired artifact hashes to on disk.
//!
//! Split out of `desired.rs`. The answer is per artifact shape and does
//! not depend on anything the plan around it decided.

use crate::hash::{hash_bytes, hash_files};

use super::Artifact;

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
