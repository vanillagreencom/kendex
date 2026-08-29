//! Reading and writing a lock file: what sits at a path, the boundary a
//! project's record may claim, and the version shapes that still load.

use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};

use super::{LOCK_FILE, LOCK_VERSION, Lock, Reason};

/// The project root whose lock sits at `path`, or `None` where the path is
/// the global lock. The inverse of [`super::lock_path`]: a project scope's lock is
/// written at its root under [`LOCK_FILE`], and the global lock lives under
/// the app's own directory with a name of its own.
fn project_root_at(path: &Path) -> Option<&Path> {
    if path.file_name()? != LOCK_FILE {
        return None;
    }
    // A relatively named lock sits in the current directory, which is what
    // it has to answer as: the empty prefix `parent` gives back is one
    // every path starts with, and containment would wave anything through.
    match path.parent() {
        Some(root) if !root.as_os_str().is_empty() => Some(root),
        _ => Some(Path::new(".")),
    }
}

/// The first position a lock claims outside `root`, with the entry claiming
/// it.
///
/// One spelling meets one spelling (invariant 17): `emitted.paths` are
/// written off the canonical root, and the root here is the parent of a lock
/// path [`super::lock_path`] already canonicalized. Nothing re-canonicalizes.
fn outside_the_project(root: &Path, lock: &Lock) -> Option<(String, PathBuf)> {
    lock.entries.iter().find_map(|(key, entry)| {
        let outside = entry
            .emitted
            .as_ref()?
            .paths
            .iter()
            .find(|path| !path.starts_with(root))?;
        Some((key.clone(), outside.clone()))
    })
}

/// A project scope installs only inside its own root, so `emitted.paths`
/// reaching past it is not a record this project ever wrote — a lock carried
/// along with a copied checkout is one that does. Refresh and removal read
/// those paths as the positions this scope owns and take back the ones a new
/// render no longer produces, which in another tree is somebody else's
/// files. So the record is refused, naming the path, at both ends: no read
/// hands one out and no write puts one down.
///
/// The global lock has no single root — each harness owns a directory of its
/// own — so it has no boundary to check.
fn refuse_foreign_paths(path: &Path, lock: &Lock) -> Result<()> {
    let Some(root) = project_root_at(path) else {
        return Ok(());
    };
    match outside_the_project(root, lock) {
        None => Ok(()),
        Some((key, recorded)) => Err(CoreError::LockOutsideProject {
            path: path.to_path_buf(),
            key,
            recorded,
            root: root.to_path_buf(),
        }),
    }
}

/// What sits at a lock path. A v1 lock keys entries by bare name and carries
/// a `harnesses` array; v2 keys carry `kind:name:harness` with one `harness`
/// field. The shapes are incompatible — deserializing v1 text straight into
/// [`Lock`] surfaces a raw "missing field" error instead of naming what the
/// file actually is.
#[derive(Debug, Clone, PartialEq)]
pub enum LockFile {
    Absent,
    Legacy { raw: String },
    Current(Lock),
}

/// `"version": 1` alone cannot identify the old product generation: this
/// product's own v0.1 locks also say 1 and load compatibly (see
/// [`LOCK_VERSION`]). The key shape is the discriminator — bare-name keys
/// against v2's always-present `kind:name:harness` separator — and it only
/// applies to files not declaring a version above 1, so a current file with
/// odd keys is diagnosed as corrupt, never mislabeled v1. An empty map
/// matches both shapes and reads as current, the only reading a lost lock
/// or a fresh scope can mean.
fn is_v1(value: &serde_json::Value) -> bool {
    let version = value.get("version").and_then(serde_json::Value::as_i64);
    if version.is_some_and(|v| v > 1) {
        return false;
    }
    value
        .get("entries")
        .and_then(serde_json::Value::as_object)
        .is_some_and(|entries| !entries.is_empty() && entries.keys().all(|k| !k.contains(':')))
}

/// Text-taking wrapper for callers (the CLI's one-shot v1 importer) that
/// have not already parsed the JSON. Unparseable text is not v1 — it is
/// corrupt, and `load_file` names that distinctly.
pub fn is_v1_text(text: &str) -> bool {
    serde_json::from_str(text).is_ok_and(|value| is_v1(&value))
}

pub fn load_file(path: &Path) -> Result<LockFile> {
    let Some(text) = read_if_exists(path)? else {
        return Ok(LockFile::Absent);
    };
    parse_text(path, &text)
}

/// [`load_file`] for text the caller already read — the importer binds its
/// preconditions to the exact bytes it classified, so it must classify the
/// bytes it read rather than a later re-read.
pub fn parse_text(path: &Path, text: &str) -> Result<LockFile> {
    let value: serde_json::Value =
        serde_json::from_str(text).map_err(|e| CoreError::LockCorrupt {
            path: path.to_path_buf(),
            message: e.to_string(),
        })?;
    if let Some(version) = value.get("version").and_then(serde_json::Value::as_i64)
        && version > i64::from(LOCK_VERSION)
    {
        return Err(CoreError::SchemaTooNew {
            path: path.to_path_buf(),
            found: version,
        });
    }
    if is_v1(&value) {
        return Ok(LockFile::Legacy {
            raw: text.to_owned(),
        });
    }
    let mut lock: Lock = serde_json::from_value(value).map_err(|e| CoreError::LockCorrupt {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    backfill_requested_reason(&mut lock);
    refuse_foreign_paths(path, &lock)?;
    Ok(LockFile::Current(lock))
}

// A record written before installations carried their reasons: everything
// installed then was installed because it was asked for, which is the only
// reading that cannot invent a dependency nobody declared. The next write
// records it.
fn backfill_requested_reason(lock: &mut Lock) {
    for entry in lock.entries.values_mut() {
        if entry.reasons.is_empty() {
            entry.reasons.insert(Reason::Requested);
        }
    }
}

/// Load for mutation: a v1 lock is a hard error, never a write target — same
/// posture as [`crate::manifest::load_for_mutation`]. Callers that only
/// observe (the audit view) use [`load_file`] instead so a v1 lock degrades
/// to a note rather than blocking the read.
pub fn load(path: &Path) -> Result<Lock> {
    match load_file(path)? {
        LockFile::Absent => Ok(Lock {
            version: LOCK_VERSION,
            ..Lock::default()
        }),
        LockFile::Legacy { .. } => Err(CoreError::LegacyLock {
            path: path.to_path_buf(),
        }),
        LockFile::Current(lock) => Ok(lock),
    }
}

pub fn save(path: &Path, lock: &Lock) -> Result<()> {
    refuse_foreign_paths(path, lock)?;
    let mut text = serde_json::to_string_pretty(lock).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    text.push('\n');
    atomic_write(path, &text)
}
