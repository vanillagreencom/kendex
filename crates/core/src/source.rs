use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{LOCAL_SOURCE_NAME, Manifest, SourceDecl};
use crate::model::Scope;
mod about;
pub mod browse;
pub mod bundles;
mod catalog;
pub mod discover;
pub mod index;
mod layout;
mod meta;
mod plugin_registry;

pub use about::{AboutReport, RootCount, about};
pub use bundles::CatalogBundle;
pub use catalog::{CatalogGroup, CatalogItem, CatalogMetadata, metadata as catalog_metadata};
pub use discover::{CatalogMode, DISCOVERY_VERSION, DiscoveredSkill, Discovery};
pub use index::{INDEX_SCHEMA, MarketplaceIndex};
pub use meta::MarketplaceMeta;
pub use plugin_registry::{CatalogFinding, PluginEntry, Registry};

/// The last path segment of a provenance — `owner/repo`, a filesystem path,
/// or `local` — which is what names a one-skill repo whose SKILL.md does
/// not name itself.
pub fn repo_leaf(provenance: &str) -> &str {
    provenance
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(provenance)
}

/// A source the engine can read right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedSource {
    pub name: String,
    pub root: PathBuf,
    /// Durable provenance: `owner/repo`, a canonical path, or `local`.
    pub provenance: String,
    /// Remotes only: the commit this root holds. The root is that commit's
    /// own directory, so it cannot change while it is being read.
    pub commit: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceState {
    Ready(ResolvedSource),
    /// Declared remote the cache cannot serve yet — not an error until
    /// something needs its content. A refresh fetches it.
    Pending {
        name: String,
        repo: String,
    },
    Disabled {
        name: String,
    },
    Missing {
        name: String,
        path: PathBuf,
    },
}

/// Where adopted content lives for a scope — always catalog-shaped. New
/// content lands under the new name; a scope whose local source exists
/// only under the old name keeps reading it until the rename op moves it.
pub fn local_source_root(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => env.global_local_source_dir(),
        Scope::Project { root } => {
            let new = root.join(crate::rename::LOCAL_SOURCE_DIR);
            let old = root.join(crate::rename::LEGACY_LOCAL_SOURCE_DIR);
            if !new.is_dir() && old.is_dir() {
                return old;
            }
            new
        }
    }
}

/// Where a declared source's checkout sits on this machine, before asking
/// whether anything is there.
fn path_root(env: &Env, scope: &Scope, path: &str) -> PathBuf {
    if Path::new(path).is_absolute() {
        return PathBuf::from(path);
    }
    match scope {
        Scope::Global => env.home.join(path),
        Scope::Project { root } => root.join(path),
    }
}

/// Where one declared source's bytes come from, as the manifest alone says
/// it: `local`, a canonical path, or `owner/repo`. `None` where the
/// declaration names nothing, or names a path that is not there.
///
/// The same answer [`resolve`] arrives at, without opening anything.
/// `resolve` is for a pass that is about to read the source; this is for
/// one that must not take the lock's word for where a record came from —
/// the lock travels in the project repository, and it is the file under
/// suspicion.
pub fn declared_provenance(
    env: &Env,
    scope: &Scope,
    name: &str,
    manifest: &Manifest,
) -> Option<String> {
    if name == LOCAL_SOURCE_NAME {
        return Some(LOCAL_SOURCE_NAME.to_owned());
    }
    let decl = manifest.sources.get(name)?;
    let Some(path) = &decl.path else {
        return decl.repo.clone();
    };
    let root = path_root(env, scope, path).canonicalize().ok()?;
    root.is_dir().then(|| root.display().to_string())
}

pub fn resolve(env: &Env, scope: &Scope, name: &str, manifest: &Manifest) -> Result<SourceState> {
    if name == LOCAL_SOURCE_NAME {
        // Adopt creates this root; until then the reserved source has no
        // content and reads as missing, never as an open-able Ready root.
        let root = local_source_root(env, scope);
        if !root.is_dir() {
            return Ok(SourceState::Missing {
                name: name.to_owned(),
                path: root,
            });
        }
        return Ok(SourceState::Ready(ResolvedSource {
            name: name.to_owned(),
            root,
            provenance: LOCAL_SOURCE_NAME.to_owned(),
            commit: None,
        }));
    }
    let Some(decl) = manifest.sources.get(name) else {
        return Err(CoreError::UnknownSource {
            name: name.to_owned(),
        });
    };
    if !decl.enabled {
        return Ok(SourceState::Disabled {
            name: name.to_owned(),
        });
    }
    if let Some(path) = &decl.path {
        let joined = path_root(env, scope, path);
        return match joined.canonicalize() {
            Ok(root) if root.is_dir() => Ok(SourceState::Ready(ResolvedSource {
                name: name.to_owned(),
                provenance: root.display().to_string(),
                root,
                commit: None,
            })),
            _ => Ok(SourceState::Missing {
                name: name.to_owned(),
                path: joined,
            }),
        };
    }
    if let Some(repo) = &decl.repo {
        if let Some(resolution) = crate::remote::cached(env, repo, decl.rev.as_deref())? {
            return Ok(SourceState::Ready(ResolvedSource {
                name: name.to_owned(),
                root: resolution.root,
                provenance: repo.clone(),
                commit: Some(resolution.commit),
            }));
        }
        // Last resort: the commit this scope last resolved to. A tag that
        // has since been deleted upstream, or a mirror that was cleaned
        // away, still leaves the installed commit readable here — and the
        // record knows which commit that is, so the answer carries it
        // rather than letting a later lock write erase an honest one.
        if let Some((root, commit)) = last_resolved(env, scope, name, repo, decl) {
            return Ok(SourceState::Ready(ResolvedSource {
                name: name.to_owned(),
                root,
                provenance: repo.clone(),
                commit: Some(commit),
            }));
        }
        return Ok(SourceState::Pending {
            name: name.to_owned(),
            repo: repo.clone(),
        });
    }
    Err(CoreError::UnknownSource {
        name: name.to_owned(),
    })
}

/// The checkout for the commit this scope's lock recorded, if the cache
/// still holds it unmodified. Only for the declaration that produced it: a
/// manifest that now names another repository or another revision must not
/// be served the previous one under the new one's name.
fn last_resolved(
    env: &Env,
    scope: &Scope,
    name: &str,
    repo: &str,
    decl: &SourceDecl,
) -> Option<(PathBuf, String)> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope)).ok()?;
    let recorded = lock.sources.get(name)?;
    // The lock read here is the on-disk one: during the repository move it
    // still spells the old repository while the manifest being planned
    // spells the new — the same repository, so the record still counts.
    if !crate::repo_move::same_repo(&recorded.repo, repo) || recorded.rev != decl.rev {
        return None;
    }
    let key = crate::remote::cache_key(env, &recorded.repo);
    let root = crate::remote::store::published(env, &key, &recorded.commit)?;
    Some((root, recorded.commit.clone()))
}

/// Like [`resolve`], but honoring an item-level revision override: the
/// item's `rev` outranks the source's. Only a repo source has revisions —
/// a rev naming a path or local source is refused with the fix in hand.
/// The lock's last-resolved fallback is deliberately skipped: it records
/// what the *source declaration* produced, which says nothing about an
/// item pinned somewhere else in history.
pub fn resolve_at(
    env: &Env,
    scope: &Scope,
    name: &str,
    manifest: &Manifest,
    rev: Option<&str>,
) -> Result<SourceState> {
    let Some(rev) = rev else {
        return resolve(env, scope, name, manifest);
    };
    if name == LOCAL_SOURCE_NAME {
        return Err(CoreError::ItemRevUnsupported {
            source_name: name.to_owned(),
        });
    }
    let Some(decl) = manifest.sources.get(name) else {
        return Err(CoreError::UnknownSource {
            name: name.to_owned(),
        });
    };
    if !decl.enabled {
        return Ok(SourceState::Disabled {
            name: name.to_owned(),
        });
    }
    let Some(repo) = &decl.repo else {
        return Err(CoreError::ItemRevUnsupported {
            source_name: name.to_owned(),
        });
    };
    match crate::remote::cached(env, repo, Some(rev))? {
        Some(resolution) => Ok(SourceState::Ready(ResolvedSource {
            name: name.to_owned(),
            root: resolution.root,
            provenance: repo.clone(),
            commit: Some(resolution.commit),
        })),
        None => Ok(SourceState::Pending {
            name: name.to_owned(),
            repo: repo.clone(),
        }),
    }
}

/// A source's ready root, or the error that explains why content is
/// unreachable — for operations that need bytes now.
pub fn require_ready(
    env: &Env,
    scope: &Scope,
    name: &str,
    manifest: &Manifest,
) -> Result<ResolvedSource> {
    match resolve(env, scope, name, manifest)? {
        SourceState::Ready(source) => Ok(source),
        SourceState::Pending { name, .. } => Err(CoreError::SourcePending { name }),
        SourceState::Disabled { name } => Err(CoreError::SourceDisabled { name }),
        SourceState::Missing { name, path } => Err(CoreError::SourceMissing { name, path }),
    }
}

mod config;
pub use config::{SourceConfig, find_item, list_items, source_config, source_config_for};

#[cfg(test)]
mod tests;
