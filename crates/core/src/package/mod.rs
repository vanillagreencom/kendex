//! One installed package, seen through its versions: which revision it is
//! held at, what its source's history offers, and what has changed. The
//! manifest holds the choice (`ItemDecl.rev`), the mirror holds the history,
//! and everything here is a projection over the two.

use std::path::{Path, PathBuf};

use serde::Serialize;
use specta::Type;

use crate::engine::EngineReport;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};
use crate::remote::history;
use crate::source_read::SealedSource;

pub mod detail;
pub mod diff;
pub(crate) mod item_file;
pub mod updates;

/// One declared package bound to its repository coordinates: where its
/// mirror lives and which directory inside the tree is the package.
pub(crate) struct PackageRef {
    pub repo: String,
    pub mirror: PathBuf,
    pub source_name: String,
    /// The item's directory (or file) relative to the checkout root, taken
    /// from the source's tracked tip so the timeline follows the package
    /// where it lives now.
    pub subtree: PathBuf,
    /// The commit the source's own selector names right now.
    pub tip: String,
}

/// Bind a declared item to its repository. The tip comes from the source's
/// selector, never the item's hold — a held package's timeline must still
/// show what it is being held back from.
pub(crate) fn package_ref(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
) -> Result<PackageRef> {
    let Some(decl) = manifest.declared(kind).get(name) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    package_ref_for(env, scope, manifest, kind, name, decl)
}

/// [`package_ref`] for a declaration the caller already holds — a derived
/// bundle member or dependency has no entry in the manifest's declared map,
/// but its effective declaration binds to a repository the same way.
pub(crate) fn package_ref_for(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    decl: &crate::manifest::ItemDecl,
) -> Result<PackageRef> {
    let source_name = decl.source.clone();
    let Some(repo) = manifest
        .sources
        .get(&source_name)
        .and_then(|s| s.repo.clone())
    else {
        return Err(CoreError::ItemRevUnsupported {
            source_name: source_name.clone(),
        });
    };
    let key = crate::remote::cache_key(env, &repo);
    let mirror = crate::remote::store::mirror_dir(env, &key);
    let selector = manifest
        .sources
        .get(&source_name)
        .and_then(|s| s.rev.clone())
        .unwrap_or_else(|| "HEAD".to_owned());
    // A tracking selector's tip is what it names right now. A pinned
    // source still gets a timeline rooted at the repository's own head:
    // the pin says what installs, not what exists, and an updates page
    // that cannot see past a pin would never have anything to say about
    // one.
    let tip = match crate::remote::store::is_pin(&selector) {
        true => crate::remote::store::resolve_ref(&mirror, "HEAD").unwrap_or(selector),
        false => crate::remote::store::resolve_ref(&mirror, &selector).ok_or_else(|| {
            CoreError::SourcePending {
                name: source_name.clone(),
            }
        })?,
    };
    let root = match crate::remote::store::published(env, &key, &tip) {
        Some(root) => root,
        None => {
            let _guard = crate::remote::store::lock_repo(env, &key)?;
            crate::remote::store::publish(env, &key, &mirror, &tip)?
        }
    };
    let sealed = SealedSource::open(&root)?;
    let config = crate::source::source_config(&sealed, crate::source::repo_leaf(&repo))?;
    // The tip may no longer offer the item (moved, deleted); the effective
    // revision the declaration reads is the fallback that keeps the page
    // and the diff working for what is actually installed.
    let item_path = crate::source::find_item(&sealed, &config, kind, name).or_else(|| {
        let state =
            crate::source::resolve_at(env, scope, &source_name, manifest, decl.rev.as_deref())
                .ok()?;
        let crate::source::SourceState::Ready(ready) = state else {
            return None;
        };
        let sealed = SealedSource::open(&ready.root).ok()?;
        let config =
            crate::source::source_config(&sealed, crate::source::repo_leaf(&ready.provenance))
                .ok()?;
        crate::source::find_item(&sealed, &config, kind, name)
            .and_then(|path| path.strip_prefix(&ready.root).ok().map(Path::to_path_buf))
            .map(|rel| root.join(rel))
    });
    let Some(item_path) = item_path else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name,
        });
    };
    let subtree = item_path
        .strip_prefix(&root)
        .map(Path::to_path_buf)
        .unwrap_or_else(|_| item_path.clone());
    Ok(PackageRef {
        repo,
        mirror,
        source_name,
        subtree,
        tip,
    })
}

/// One version of a package: a commit that changed its files, wearing any
/// tag names that point at it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct VersionRow {
    /// Full commit id.
    pub id: String,
    /// The release name, when a tag points at this commit.
    pub label: Option<String>,
    /// ISO-8601 committer date.
    pub date: String,
    pub summary: String,
    /// This is the content revision the installed package holds.
    pub installed: bool,
    pub newer_than_installed: bool,
}

/// The package's timeline, newest first: every commit that changed its
/// files up to the source's tracked tip. Tags decorate the timeline, they
/// never replace it — a repository's tags may live far from this package.
/// The installed marker lands on the newest content commit at-or-before
/// the locked source commit, because an installed commit that changed
/// other files is not itself on this package's timeline.
pub fn versions(env: &Env, scope: &Scope, kind: ItemKind, name: &str) -> Result<Vec<VersionRow>> {
    let manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let package = package_ref(env, scope, &manifest, kind, name)?;
    let log = history::subtree_log(&package.mirror, &package.tip, &package.subtree)?;
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope))?;
    // The mirror just proved readable; a lock commit that still cannot be
    // mapped (v1-imported, hand-edited) costs the installed marker, never
    // the timeline the mirror can perfectly well render.
    let installed_commit = installed_commit(&lock, kind, name).and_then(|commit| {
        history::last_content_commit(&package.mirror, &commit, &package.subtree)
            .ok()
            .flatten()
    });
    let installed_at = log
        .iter()
        .position(|row| Some(&row.commit) == installed_commit.as_ref());
    Ok(log
        .into_iter()
        .enumerate()
        .map(|(index, row)| VersionRow {
            installed: Some(index) == installed_at,
            newer_than_installed: installed_at.is_some_and(|installed| index < installed),
            id: row.commit,
            label: row.tags.first().cloned(),
            date: row.date,
            summary: row.summary,
        })
        .collect())
}

/// The source commit this package's installations were produced from —
/// `None` when no harness has it installed yet or the lock predates the
/// record. Installations that disagree (mid-apply, or a partial refresh)
/// answer with the newest record's value, and the updates projection flags
/// the disagreement separately.
fn installed_commit(lock: &crate::lock::Lock, kind: ItemKind, name: &str) -> Option<String> {
    lock.entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == name)
        .filter(|entry| entry.source_commit.is_some())
        .max_by(|a, b| a.installed_at.cmp(&b.installed_at))
        .and_then(|entry| entry.source_commit.clone())
}

/// A version selector as a commit id: whatever the repository can name —
/// tag, branch, commit — resolved against this item's source. The cache
/// answers first; the network fills in what it cannot.
pub fn resolve_version(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    selector: &str,
) -> Result<String> {
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
    Ok(resolve_selector(env, &repo, selector)?.commit)
}

/// Hold an item at a version, or let it follow its source again.
///
/// The selector may be anything the repository can name — a tag, a branch,
/// a commit — but what the manifest records is always the full commit id it
/// resolves to right now: a name someone can move upstream must never be
/// able to move an item the user chose to hold. Everything is checked
/// before the manifest is touched (invariant 11): the selector must resolve,
/// and the item must actually exist at that commit.
pub fn set_rev(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    rev: Option<&str>,
) -> Result<EngineReport> {
    set_rev_with(
        env,
        scope,
        kind,
        name,
        rev,
        &crate::engine::PlanOptions::default(),
    )
}

/// `set_rev` whose plan takes the caller's options, so moving a hold and
/// discarding the held copy's edits can be one apply: planning the new
/// revision from the old manifest first would restore the old version.
pub fn set_rev_with(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    rev: Option<&str>,
    options: &crate::engine::PlanOptions,
) -> Result<EngineReport> {
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let Some(decl) = manifest.declared(kind).get(name).cloned() else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    let normalized = match rev {
        None => None,
        Some(selector) => {
            let source_decl = manifest.sources.get(&decl.source);
            let Some(repo) = source_decl.and_then(|s| s.repo.clone()) else {
                return Err(CoreError::ItemRevUnsupported {
                    source_name: decl.source.clone(),
                });
            };
            let resolution = resolve_selector(env, &repo, selector)?;
            // A commit the repository holds is not yet a version of this
            // item — the item has to exist in that tree.
            let sealed = SealedSource::open(&resolution.root)?;
            let config = crate::source::source_config(&sealed, crate::source::repo_leaf(&repo))?;
            if crate::source::find_item(&sealed, &config, kind, name).is_none() {
                return Err(CoreError::ItemMissingAtRev {
                    name: name.to_owned(),
                    repo,
                    commit: resolution.commit,
                });
            }
            Some(resolution.commit)
        }
    };
    let Some(entry) = manifest.declared_mut(kind).get_mut(name) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    entry.rev = normalized;
    crate::source_ops::persist_and_plan_with(env, scope, manifest, options)
}

/// The cache answers first — a version the mirror already holds needs no
/// network — and the network fills in what it cannot.
fn resolve_selector(env: &Env, repo: &str, selector: &str) -> Result<crate::remote::Resolution> {
    if let Some(resolution) = crate::remote::cached(env, repo, Some(selector))? {
        return Ok(resolution);
    }
    crate::remote::sync(env, repo, Some(selector))
}
