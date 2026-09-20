//! What a publish does about the older snapshots of the same repository.
//!
//! A snapshot is one commit's checkout, its receipt and its safety cache,
//! and a repository that is refreshed often grows one per fetch. The keep
//! set is every commit a registered scope's lock still names plus the
//! newest few by publish time; everything else is removed under the
//! repository's cache lock, which every publisher holds. Nothing is lost
//! either way: the mirror keeps every object, so a removed snapshot is
//! rebuilt from it the next time something reads that commit.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::time::SystemTime;

use crate::env::Env;
use crate::lock::LockFile;

/// The variable naming how many of its newest snapshots a repository
/// keeps past the ones a lock references, the one just published among
/// them. A count of zero keeps only the referenced ones and that one.
pub const KEEP_VAR: &str = "KENDEX_SOURCE_CACHE_KEEP";

/// Snapshots kept per repository when [`KEEP_VAR`] is unset.
pub const DEFAULT_KEEP: usize = 3;

/// What a publish did about the older snapshots beside the new one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Retention {
    /// No snapshot was written, so none was judged.
    Untouched,
    /// Every snapshot outside the keep set is gone.
    Pruned { removed: usize },
    /// Removal did not finish: what is left stays until the next publish.
    /// The keep set could not be established, or one removal failed.
    Stopped { removed: usize, reason: String },
}

/// One snapshot as the commits directory holds it.
struct Snapshot {
    commit: String,
    /// When the receipt landed; the epoch where there is no receipt, so a
    /// tree nothing vouches for is the first to go.
    published_at: SystemTime,
}

/// Remove the snapshots of `key` outside the keep set, `published` being
/// the one that just landed and is never removed.
pub(super) fn retain(env: &Env, key: &str, published: &str) -> Retention {
    let judged = keep_count(env).and_then(|keep| {
        let referenced = referenced_commits(env, key)?;
        let snapshots = snapshots(&super::checkout_dir(env, key, published))?;
        Ok((keep, referenced, snapshots))
    });
    let (keep, referenced, mut snapshots) = match judged {
        Ok(judged) => judged,
        Err(reason) => return Retention::Stopped { removed: 0, reason },
    };
    // Newest publish first; two receipts in one clock tick order by commit
    // id so the same directory reads the same way on every pass.
    snapshots.sort_by(|a, b| {
        b.published_at
            .cmp(&a.published_at)
            .then_with(|| b.commit.cmp(&a.commit))
    });
    let mut removed = 0;
    for (rank, snapshot) in snapshots.iter().enumerate() {
        if rank < keep || snapshot.commit == published || referenced.contains(&snapshot.commit) {
            continue;
        }
        if let Err(reason) = remove(env, key, &snapshot.commit) {
            return Retention::Stopped { removed, reason };
        }
        removed += 1;
    }
    Retention::Pruned { removed }
}

fn keep_count(env: &Env) -> Result<usize, String> {
    match env.var(KEEP_VAR) {
        None => Ok(DEFAULT_KEEP),
        Some(text) => text
            .trim()
            .parse()
            .map_err(|_| format!("{KEEP_VAR}={text:?} is not a count")),
    }
}

/// Every commit of `key` some registered scope's lock names: a source's
/// resolution, a set's, or an installation's provenance. A registry or a
/// lock this build cannot read is the whole answer: nothing can say what
/// it references, so nothing is removed. A registered project whose lock
/// is not there references nothing; a pin it comes back with is rebuilt
/// from the mirror.
fn referenced_commits(env: &Env, key: &str) -> Result<BTreeSet<String>, String> {
    let settings = crate::settings::load(env).map_err(|e| e.to_string())?;
    let keyed = |repo: &str| crate::remote::cache_key(env, repo) == key;
    let mut commits = BTreeSet::new();
    for scope in settings.scopes() {
        let lock = match crate::lock::load_file(&crate::lock::lock_path(env, &scope)) {
            Ok(LockFile::Absent) => continue,
            Ok(LockFile::Current(lock)) => lock,
            Err(error) => return Err(error.to_string()),
        };
        commits.extend(
            lock.sources
                .values()
                .filter(|rev| keyed(&rev.repo))
                .map(|rev| rev.commit.clone()),
        );
        commits.extend(
            lock.bundles
                .values()
                .filter(|rev| keyed(&rev.source_repo))
                .map(|rev| rev.commit.clone()),
        );
        commits.extend(
            lock.entries
                .values()
                .filter(|entry| keyed(&entry.source_repo))
                .filter_map(|entry| entry.source_commit.clone()),
        );
    }
    Ok(commits)
}

/// The snapshots beside `checkout`: every sibling directory named by a
/// full commit id. Staging and replaced directories carry a dot and are
/// the publisher's own.
fn snapshots(checkout: &Path) -> Result<Vec<Snapshot>, String> {
    let parent = checkout
        .parent()
        .ok_or_else(|| format!("{}: no commits directory", checkout.display()))?;
    let entries = fs::read_dir(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    let mut found = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", parent.display()))?;
        let name = entry.file_name();
        let Some(commit) = name.to_str().filter(|name| super::is_pin(name)) else {
            continue;
        };
        if !entry.path().is_dir() {
            continue;
        }
        let published_at = fs::metadata(parent.join(format!("{commit}.published")))
            .and_then(|meta| meta.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH);
        found.push(Snapshot {
            commit: commit.to_owned(),
            published_at,
        });
    }
    Ok(found)
}

/// Remove one snapshot whole. The receipt goes first: a reader that finds
/// the tree with no receipt reads a miss, never a tree that is half gone.
fn remove(env: &Env, key: &str, commit: &str) -> Result<(), String> {
    let receipt = super::receipt_path(env, key, commit);
    absent(fs::remove_file(&receipt)).map_err(|e| format!("{}: {e}", receipt.display()))?;
    let safety = super::safety_cache_dir(env, key, commit);
    absent(fs::remove_dir_all(&safety)).map_err(|e| format!("{}: {e}", safety.display()))?;
    let dir = super::checkout_dir(env, key, commit);
    fs::remove_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))
}

/// A removal of what is already gone has nothing left to do.
fn absent(result: std::io::Result<()>) -> std::io::Result<()> {
    match result {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}
