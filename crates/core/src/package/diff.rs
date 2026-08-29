//! What changed between two versions of one package, file by file, shaped
//! for display: statuses, line counts, and unified hunks. One diff engine
//! covers both cached version trees and the installed files on disk —
//! which live in no repository, so git cannot see them.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::paths::slashed;
use crate::source_read::SealedSource;

/// One side of the comparison.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case", tag = "at", content = "commit")]
pub enum VersionSel {
    /// The package's source subtree at a commit.
    Commit(String),
    /// What is installed on disk right now.
    Installed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum FileStatus {
    Added,
    Removed,
    Modified,
    /// Holds a NUL byte on either side — compared, never rendered as text.
    Binary,
    /// Past the size or line budget — reported, not diffed.
    TooLarge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum LineKind {
    Context,
    Add,
    Remove,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub kind: LineKind,
    pub text: String,
    pub old_no: Option<u32>,
    pub new_no: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Hunk {
    pub header: String,
    pub lines: Vec<Line>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct FileDiff {
    /// Forward-slash relative path, whatever the platform.
    pub path: String,
    pub status: FileStatus,
    pub additions: u32,
    pub deletions: u32,
    /// One side was not valid UTF-8 and is shown lossily.
    pub lossy: bool,
    pub hunks: Vec<Hunk>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageDiff {
    pub files: Vec<FileDiff>,
    pub total_additions: u32,
    pub total_deletions: u32,
    /// The comparison hit a budget; what is shown is a prefix, not the whole.
    pub truncated: bool,
}

/// Compare two versions of one package. `Installed` reads what apply would
/// compare — the rendered files for skills and agents (the harness names
/// which rendering, agents render per tool) — so the fork question "what
/// did I change" is answered against real bytes, not source that never hit
/// disk in that form.
pub fn package_diff(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    from: &VersionSel,
    to: &VersionSel,
    harness: Option<HarnessId>,
) -> Result<PackageDiff> {
    let from_files = side(env, scope, kind, name, from, harness)?;
    let to_files = side(env, scope, kind, name, to, harness)?;
    Ok(diff_trees(&from_files, &to_files))
}

pub(super) type Tree = BTreeMap<String, Vec<u8>>;

mod render;
use render::diff_trees;

fn side(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    sel: &VersionSel,
    harness: Option<HarnessId>,
) -> Result<Tree> {
    match sel {
        VersionSel::Commit(commit) => commit_tree(env, scope, kind, name, commit),
        VersionSel::Installed => installed_tree(env, scope, kind, name, harness),
    }
}

/// The package's source subtree at one commit, read through the sealed
/// reader — a historical commit of a catalog is still a catalog, budgets
/// and symlink refusals included.
fn commit_tree(env: &Env, scope: &Scope, kind: ItemKind, name: &str, commit: &str) -> Result<Tree> {
    // A commit id from IPC is joined into cache paths; a value like
    // `../other-key/<sha>` would resolve to a different repository's
    // checkout. Only a real object id ever gets that far.
    if !crate::remote::store::is_pin(commit) {
        return Err(CoreError::PinUnavailable {
            repo: name.to_owned(),
            pin: commit.to_owned(),
            reason: "not a commit id".to_owned(),
        });
    }
    let manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    let Some(repo) = manifest
        .sources
        .get(&decl.source)
        .and_then(|s| s.repo.clone())
    else {
        return Err(CoreError::ItemRevUnsupported {
            source_name: decl.source.clone(),
        });
    };
    let key = crate::remote::cache_key(env, &repo);
    let root = match crate::remote::store::published(env, &key, commit) {
        Some(root) => root,
        None => {
            let mirror = crate::remote::store::mirror_dir(env, &key);
            if !crate::remote::store::has_commit(&mirror, commit) {
                return Err(CoreError::PinUnavailable {
                    repo,
                    pin: commit.to_owned(),
                    reason: "not in the local mirror — refresh the source first".to_owned(),
                });
            }
            let _guard = crate::remote::store::lock_repo(env, &key)?;
            crate::remote::store::publish(env, &key, &mirror, commit)?
        }
    };
    let sealed = SealedSource::open(&root)?;
    let config = crate::source::source_config(&sealed, crate::source::repo_leaf(&repo))?;
    let Some(item_path) = crate::source::find_item(&sealed, &config, kind, name) else {
        return Err(CoreError::ItemMissingAtRev {
            name: name.to_owned(),
            repo,
            commit: commit.to_owned(),
        });
    };
    let mut tree = Tree::new();
    if sealed.is_dir(&item_path) {
        for (rel, bytes) in sealed.collect_tree(&item_path, &[])? {
            tree.insert(slashed(&rel), bytes);
        }
    } else {
        let file = item_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| name.to_owned());
        tree.insert(file, sealed.read(&item_path)?);
    }
    Ok(tree)
}

/// What is installed on disk right now: the canonical tree for a skill,
/// the rendered file for an agent. Ours, so plain reads.
fn installed_tree(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: Option<HarnessId>,
) -> Result<Tree> {
    let harness = harness.unwrap_or(HarnessId::Claude);
    let path = match kind {
        ItemKind::Skill => crate::engine::fork::skill_content_path(env, scope, name, harness)
            .ok_or_else(|| CoreError::ItemNotFound {
                kind,
                name: name.to_owned(),
                harness,
            })?,
        ItemKind::Agent => {
            let Some(dir) =
                crate::engine::desired::native_dir(env, scope, harness, ItemKind::Agent)
            else {
                return Err(CoreError::ItemNotFound {
                    kind,
                    name: name.to_owned(),
                    harness,
                });
            };
            dir.join(crate::render::agent::file_name(harness, name))
        }
        other => {
            return Err(CoreError::ItemNotInSource {
                name: name.to_owned(),
                source_name: format!(
                    "diff against the install does not support {} yet",
                    other.name()
                ),
            });
        }
    };
    if path.is_symlink() || !path.exists() {
        return Err(CoreError::ItemNotFound {
            kind,
            name: name.to_owned(),
            harness,
        });
    }
    let mut tree = Tree::new();
    if path.is_dir() {
        for (rel, bytes) in crate::capture::read_tree(&path)? {
            tree.insert(slashed(&rel), bytes);
        }
    } else {
        let file = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| name.to_owned());
        tree.insert(
            file,
            std::fs::read(&path).map_err(|e| CoreError::io(&path, e))?,
        );
    }
    Ok(tree)
}
