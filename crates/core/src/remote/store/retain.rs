//! What a publish does about the older snapshots of the same repository.
//!
//! A snapshot is one commit's checkout, its receipt and its safety cache,
//! and a repository that is refreshed often grows one per fetch. The keep
//! set is the newest few by publish time, every commit a lock names in a
//! registered scope or in one this invocation stands in, and every
//! checkout this invocation was handed; everything else is removed under
//! the repository's cache lock, which every publisher holds. A removed
//! snapshot is materialized again from the mirror the next time something
//! reads that commit, for as long as the mirror holds it.
//!
//! Standing in a scope is not a publisher's job: `manifest::manifest_path`
//! records it whenever a scope's manifest is named, and a source is
//! published for a scope only from its declarations, so every publish
//! path, present and future, has stood in its scope before it gets here.
//! Holding a checkout is the store's: `published` and `publish` record
//! every root they hand out.

use std::collections::BTreeSet;
use std::fs;
use std::time::SystemTime;

use crate::env::Env;
use crate::lock::LockFile;
use crate::model::Scope;

/// The variable naming how many of its newest snapshots a repository
/// keeps, the one just published among them. Snapshots past that count
/// stay when a lock names them or this invocation holds them. Unset or
/// empty, the count is [`DEFAULT_KEEP`]; zero keeps only what is named or
/// held, and the one just published.
pub const KEEP_VAR: &str = "KENDEX_SOURCE_CACHE_KEEP";

/// Snapshots kept per repository when [`KEEP_VAR`] names no count.
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

/// Remove the snapshots of `key` outside the keep set. The caller has
/// just published one and holds it, so that one is never removed.
pub(super) fn retain(env: &Env, key: &str) -> Retention {
    let held = env.held();
    let judged = keep_count(env).and_then(|keep| {
        let referenced = referenced_commits(env, key, &held.scopes)?;
        let snapshots = snapshots(env, key)?;
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
        let handed_out = held
            .checkouts
            .contains(&(key.to_owned(), snapshot.commit.clone()));
        if rank < keep || handed_out || referenced.contains(&snapshot.commit) {
            continue;
        }
        if let Err(reason) = remove(env, key, &snapshot.commit) {
            return Retention::Stopped { removed, reason };
        }
        removed += 1;
    }
    Retention::Pruned { removed }
}

/// The count [`KEEP_VAR`] names. A variable exported empty is how a shell
/// profile or a job neutralises one, so it reads as unset; anything else
/// that is not a count stops the pass.
fn keep_count(env: &Env) -> Result<usize, String> {
    match env.var(KEEP_VAR).map(str::trim) {
        None | Some("") => Ok(DEFAULT_KEEP),
        Some(text) => text
            .parse()
            .map_err(|_| format!("{KEEP_VAR}={text:?} is not a count")),
    }
}

/// Every commit of `key` a lock names, in a registered scope or one of
/// `standing`, the scopes this invocation stands in: a source's
/// resolution, a set's, or an installation's provenance. A registry or a lock this build cannot read is the whole
/// answer: nothing can say what it references, so nothing is removed. A
/// scope whose lock is not there references nothing; a pin it comes back
/// with is rebuilt from the mirror.
fn referenced_commits(
    env: &Env,
    key: &str,
    standing: &BTreeSet<Scope>,
) -> Result<BTreeSet<String>, String> {
    let settings = crate::settings::load(env).map_err(|e| e.to_string())?;
    let keyed = |repo: &str| crate::remote::cache_key(env, repo) == key;
    let mut commits = BTreeSet::new();
    let scopes: BTreeSet<Scope> = settings
        .scopes()
        .into_iter()
        .chain(standing.iter().cloned())
        .collect();
    for scope in scopes {
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

/// The snapshots of `key`: every directory named by a full commit id.
/// Staging and replaced directories carry a dot and are the publisher's
/// own.
fn snapshots(env: &Env, key: &str) -> Result<Vec<Snapshot>, String> {
    let commits = super::commits_dir(env, key);
    let entries = fs::read_dir(&commits).map_err(|e| format!("{}: {e}", commits.display()))?;
    let mut found = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", commits.display()))?;
        let name = entry.file_name();
        let Some(commit) = name.to_str().filter(|name| super::is_pin(name)) else {
            continue;
        };
        if !entry.path().is_dir() {
            continue;
        }
        let published_at = fs::metadata(super::receipt_path(env, key, commit))
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
