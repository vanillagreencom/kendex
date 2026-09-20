use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{INPLACE_SOURCE_NAME, LOCAL_SOURCE_NAME, Manifest, SourceDecl};
use crate::model::Scope;
mod about;
pub mod browse;
pub mod bundles;
mod catalog;
pub mod discover;
pub(crate) mod header;
pub mod index;
mod layout;
mod meta;
mod plugin_registry;
mod slot;

pub use about::{AboutReport, RootCount, about};
pub use bundles::CatalogBundle;
pub use catalog::{CatalogGroup, CatalogItem, CatalogMetadata, metadata as catalog_metadata};
pub use discover::{CatalogMode, DISCOVERY_VERSION, DiscoveredSkill, Discovery};
pub use index::{INDEX_SCHEMA, MarketplaceIndex};
pub use meta::MarketplaceMeta;
pub use plugin_registry::{CatalogFinding, PluginEntry, Registry};
pub(crate) use slot::{local_slot, slot_escapes, slot_free, slot_unreachable};

/// The directory a project scope adopts content into — catalog-shaped,
/// and the source `local` reads from.
pub const LOCAL_SOURCE_DIR: &str = ".kendex-local";

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
    /// Durable provenance: the remote reference as the declaration spelled
    /// it — `owner/repo` only where it was written that way, a full URL
    /// where it was not — a path source's identity from
    /// [`declared_path_identity`], or `local`. Opaque, and recorded
    /// verbatim as a lock entry's `source_repo`, so anything matching on it
    /// compares the whole string rather than a fold of it.
    ///
    /// A path source's provenance is its declaration and never the
    /// directory it resolves to on this machine: the lock is committed and
    /// read in every clone, and the declaration is the one spelling of a
    /// path source that every clone shares. Resolved, the same declaration
    /// names a different directory on every machine, and every clone would
    /// read its own installs as rebound. It is one identity within the
    /// declaring scope only; a surface spanning scopes keys on
    /// [`machine_identity`].
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

/// Where adopted content lives for a scope — always catalog-shaped.
pub fn local_source_root(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Global => env.global_local_source_dir(),
        Scope::Project { root } => root.join(LOCAL_SOURCE_DIR),
    }
}

/// Where a declared folder sits on this machine, before asking whether
/// anything is there: an absolute path as written, a relative one under the
/// declaring scope's own root. Rootedness is the platform's answer
/// (`Path::is_absolute`), so on Windows a POSIX-rooted `/srv/catalog` is
/// root-relative and joins onto the scope's drive — two scopes on two
/// drives name two directories, and a surface folding declarations into one
/// marketplace has to key on this, never on the spelling.
///
/// Read through [`declared`]: a `.` segment and a trailing separator
/// drop, so `./catalog`, `catalog` and `catalog/` are one directory, and
/// a `..` stays as written.
pub fn path_root(env: &Env, scope: &Scope, path: &str) -> PathBuf {
    let read = declared(path);
    if read.is_absolute() {
        return read;
    }
    match scope {
        Scope::Global => env.home.join(read),
        Scope::Project { root } => root.join(read),
    }
}

/// The one reading of a path declaration, which [`path_root`] opens and
/// [`declared_path_identity`] records: `Path::components` with every `.`
/// segment dropped, so a `.` segment and a trailing separator say
/// nothing, and a `..` stays as written for the reason
/// [`crate::paths::as_written`] gives — folded by spelling, it names
/// another directory wherever the segment before it is a link. The
/// declaring root itself reads as the empty path.
fn declared(path: &str) -> PathBuf {
    Path::new(path)
        .components()
        .filter(|part| *part != std::path::Component::CurDir)
        .collect()
}

/// The identity a path declaration has in every clone of the scope
/// declaring it, and what a lock records as a path source's provenance in
/// place of the directory the declaration resolves to here: the record is
/// committed and read in every clone, and the declaration is the one
/// spelling every clone shares.
///
/// Spelled so that it can never be read as anything else. Every path
/// identity starts with `.` or is rooted: `.` for the declaring root,
/// `./<remainder>` for a declaration under it, `../<remainder>` and an
/// absolute declaration as typed. A repository reference is
/// `owner/repo` or a URL and a reserved source is `local` or `in-place`,
/// none of which starts with a dot or a separator, so a declaration
/// `path = "owner/repo"` records `./owner/repo` and a declaration
/// `path = "local"` records `./local`: the rebind refusal (invariant 4)
/// and the reserved-name exemptions compare against a namespace a path
/// cannot enter. [`is_path_identity`] is the reading of that mark.
///
/// One identity within the declaring scope only: two scopes declaring
/// `catalog` name two directories and record one string. A surface that
/// spans scopes keys on [`machine_identity`], never on this.
pub fn declared_path_identity(path: &str) -> String {
    let read = declared(path);
    if read.has_root() || read.starts_with("..") {
        return crate::paths::slashed(&read);
    }
    if read.as_os_str().is_empty() {
        return ".".to_owned();
    }
    format!("./{}", crate::paths::slashed(&read))
}

/// Whether a recorded provenance is a path source's, by the mark
/// [`declared_path_identity`] gives every one: a leading `.`, or a rooted
/// spelling — `/srv/catalog`, which is rooted on POSIX and root-relative
/// on Windows, where it joins onto the scope's drive, and `C:/catalog`.
/// A repository reference and a reserved name carry neither.
pub fn is_path_identity(provenance: &str) -> bool {
    provenance.starts_with('.') || Path::new(provenance).has_root()
}

/// The identity a source has on this machine, for a surface that spans
/// scopes: a repository reference or a reserved name as it is, and a path
/// source as the directory its identity resolves to from the scope that
/// recorded it — canonical where the directory exists, so it is the same
/// string [`resolve`] puts in `root`, and the lexical join where it does
/// not. Two scopes declaring `catalog` record one
/// [`declared_path_identity`] and two of these.
///
/// What the marketplace rows and the library's provenance rows carry, so
/// the join between them credits a marketplace only with installations
/// from its own directory.
pub fn machine_identity(env: &Env, scope: &Scope, provenance: &str) -> String {
    if !is_path_identity(provenance) {
        return provenance.to_owned();
    }
    let joined = path_root(env, scope, provenance);
    crate::paths::slashed(&crate::paths::canonical(&joined).unwrap_or(joined))
}

/// Where the in-place source reads, or nothing at a scope that has no
/// shared tree of its own. Global installs keep a private store, so there
/// is no project `.agents` for an item to be its own source in.
pub fn inplace_source_root(scope: &Scope) -> Option<PathBuf> {
    match scope {
        Scope::Project { root } => Some(root.join(crate::manifest::INPLACE_SOURCE_DIR)),
        Scope::Global => None,
    }
}

pub fn resolve(env: &Env, scope: &Scope, name: &str, manifest: &Manifest) -> Result<SourceState> {
    if name == INPLACE_SOURCE_NAME {
        // Adoption creates this tree; a scope that has none yet reads as
        // missing rather than as an empty catalog everything resolves from.
        // A scope with no shared tree at all — global — has no root to
        // report, and an empty path would resolve against the working
        // directory, so it reports the one it would have had.
        let Some(root) = inplace_source_root(scope) else {
            return Ok(SourceState::Missing {
                name: name.to_owned(),
                path: PathBuf::from(crate::manifest::INPLACE_SOURCE_DIR),
            });
        };
        if !root.is_dir() {
            return Ok(SourceState::Missing {
                name: name.to_owned(),
                path: root,
            });
        }
        return Ok(SourceState::Ready(ResolvedSource {
            name: name.to_owned(),
            root,
            provenance: INPLACE_SOURCE_NAME.to_owned(),
            commit: None,
        }));
    }
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
        return match crate::paths::canonical(&joined) {
            Ok(root) if root.is_dir() => Ok(SourceState::Ready(ResolvedSource {
                name: name.to_owned(),
                provenance: declared_path_identity(path),
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
/// be served the previous one under the current one's name.
fn last_resolved(
    env: &Env,
    scope: &Scope,
    name: &str,
    repo: &str,
    decl: &SourceDecl,
) -> Option<(PathBuf, String)> {
    let lock = crate::lock::load(&crate::lock::lock_path(env, scope)).ok()?;
    let recorded = lock.sources.get(name)?;
    // Exact strings: the record counts only for the repository it was
    // written against, spelled the way the declaration spells it.
    if recorded.repo != repo || recorded.rev != decl.rev {
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
    if name == LOCAL_SOURCE_NAME || name == INPLACE_SOURCE_NAME {
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
    require_resolved(resolve(env, scope, name, manifest)?)
}

/// A source's ready root at an item-level revision, or the error that
/// explains why those bytes are unreachable.
pub fn require_ready_at(
    env: &Env,
    scope: &Scope,
    name: &str,
    manifest: &Manifest,
    rev: Option<&str>,
) -> Result<ResolvedSource> {
    require_resolved(resolve_at(env, scope, name, manifest, rev)?)
}

fn require_resolved(state: SourceState) -> Result<ResolvedSource> {
    match state {
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
