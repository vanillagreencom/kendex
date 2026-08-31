//! One installed package: where it reads from, what a plan just did to it,
//! and the two verbs that move it — bring it current, or hold it at a
//! version. The manifest holds the choice (`ItemDecl.rev`), the mirror
//! holds the history, and [`timeline`] is the projection over the two.

use std::path::{Path, PathBuf};

use crate::engine::EngineReport;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};
use crate::source_read::SealedSource;

pub mod detail;
pub mod diff;
pub(crate) mod item_file;
mod outcome;
pub use outcome::{held_back, moving, removed};
mod timeline;
mod update;
pub use update::{UpdateTarget, update_many, update_one};
pub mod updates;
pub use timeline::{VersionRow, resolve_version, versions};

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
        let effective = SealedSource::open(&ready.root).ok()?;
        let config =
            crate::source::source_config(&effective, crate::source::repo_leaf(&ready.provenance))
                .ok()?;
        crate::source::find_item(&effective, &config, kind, name)
            .and_then(|path| {
                path.strip_prefix(effective.root())
                    .ok()
                    .map(Path::to_path_buf)
            })
            .map(|rel| sealed.root().join(rel))
    });
    let Some(item_path) = item_path else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name,
        });
    };
    // Both arms above speak the seal's canonical spelling, so the strip is
    // against `sealed.root()`, never the spelling `published` handed back —
    // under a symlinked checkout root (macOS's `/var` → `/private/var`) the
    // two differ, and a miss must refuse rather than hand git an absolute
    // pathspec it reads as outside the mirror.
    let subtree = item_path
        .strip_prefix(sealed.root())
        .map(Path::to_path_buf)
        .map_err(|_| {
            CoreError::io(
                &item_path,
                std::io::Error::other("item path is not under the sealed checkout root"),
            )
        })?;
    Ok(PackageRef {
        repo,
        mirror,
        source_name,
        subtree,
        tip,
    })
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
    set_revs_with(env, scope, &[(kind, name.to_owned(), rev)], options)
}

/// The same move for a set of packages at once, and the one definition
/// behind [`set_rev_with`].
///
/// Every selector resolves against the manifest as it stands before any of
/// them is written (invariant 11): a selector reads a declaration's source,
/// so a write that landed first would change what a later one resolves
/// against, and one package the source cannot place leaves the manifest
/// exactly as it was.
pub fn set_revs_with(
    env: &Env,
    scope: &Scope,
    holds: &[(ItemKind, String, Option<&str>)],
    options: &crate::engine::PlanOptions,
) -> Result<EngineReport> {
    let mut manifest = crate::engine::ops::manifest_for_mutation(env, scope)?;
    let resolved: Vec<(ItemKind, &String, Option<String>)> = holds
        .iter()
        .map(|(kind, name, rev)| {
            let normalized = rev
                .map(|selector| resolve_hold(env, &manifest, *kind, name, selector))
                .transpose()?;
            Ok((*kind, name, normalized))
        })
        .collect::<Result<_>>()?;
    for (kind, name, normalized) in resolved {
        let Some(entry) = manifest.declared_mut(kind).get_mut(name) else {
            return Err(CoreError::NotDeclared {
                kind,
                name: name.clone(),
            });
        };
        entry.rev = normalized;
    }
    crate::source_ops::persist_and_plan_with(env, scope, manifest, options)
}

/// Where an item's hold would move, proven before anything is written
/// (invariant 11). The selector — tag, branch, commit — resolves against
/// the item's source to the full commit id the manifest records, and the
/// item has to exist in that tree: a commit the repository holds is not
/// yet a version of this item.
pub fn resolve_hold(
    env: &Env,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
    selector: &str,
) -> Result<String> {
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
    let resolution = resolve_selector(env, &repo, selector)?;
    if !item_in_tree(
        &resolution.root,
        crate::source::repo_leaf(&repo),
        kind,
        name,
    )? {
        return Err(CoreError::ItemMissingAtRev {
            name: name.to_owned(),
            repo,
            commit: resolution.commit,
        });
    }
    Ok(resolution.commit)
}

/// Prove the item exists in the tree any apply would read — the item's own
/// hold, else the source's revision — before anything durable is written
/// (invariant 11). Nothing moves: the hold stays exactly as it is.
pub fn prove_present(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    kind: ItemKind,
    name: &str,
) -> Result<()> {
    let Some(decl) = manifest.declared(kind).get(name) else {
        return Err(CoreError::NotDeclared {
            kind,
            name: name.to_owned(),
        });
    };
    let state = crate::source::resolve_at(env, scope, &decl.source, manifest, decl.rev.as_deref())?;
    let crate::source::SourceState::Ready(ready) = state else {
        return Err(CoreError::SourcePending {
            name: decl.source.clone(),
        });
    };
    if !item_in_tree(
        &ready.root,
        crate::source::repo_leaf(&ready.provenance),
        kind,
        name,
    )? {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: decl.source.clone(),
        });
    }
    Ok(())
}

/// Whether one source tree offers the item — the shared reading behind
/// both proofs above.
fn item_in_tree(root: &Path, repo_leaf: &str, kind: ItemKind, name: &str) -> Result<bool> {
    let sealed = SealedSource::open(root)?;
    let config = crate::source::source_config(&sealed, repo_leaf)?;
    Ok(crate::source::find_item(&sealed, &config, kind, name).is_some())
}

/// The cache answers first — a version the mirror already holds needs no
/// network — and the network fills in what it cannot.
fn resolve_selector(env: &Env, repo: &str, selector: &str) -> Result<crate::remote::Resolution> {
    if let Some(resolution) = crate::remote::cached(env, repo, Some(selector))? {
        return Ok(resolution);
    }
    crate::remote::sync(env, repo, Some(selector))
}
