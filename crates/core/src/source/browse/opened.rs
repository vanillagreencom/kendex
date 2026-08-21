//! One catalog opened for reading, and what it knows about this scope.
//!
//! Split out of `browse.rs`. Opening a catalog is one question — which
//! bytes, at which revision, joined against whose records — and the pages
//! above read the answer rather than each assembling it.

use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile};
use crate::manifest::{Manifest, ManifestFile};
use crate::model::{ItemKind, Scope};
use crate::source_read::SealedSource;

use super::super::{ResolvedSource, SourceConfig, require_ready, source_config_for};
use super::catalog::browsable;
use super::{Catalog, InstallState, safety};
use crate::quality::Verdict;

/// One catalog opened for reading, with the scope records the
/// installed-state join needs.
pub(crate) struct Browsed {
    /// The scope this reading is against — the subscription's own, or the
    /// personal scope for a repository nobody subscribes to, since that is
    /// where subscribing lands by default. What installs where depends on
    /// it, so a preview that models an install has to know it.
    pub(crate) scope: Scope,
    pub(crate) manifest: Manifest,
    pub(crate) lock: Lock,
    pub(crate) source: ResolvedSource,
    pub(crate) sealed: SealedSource,
    pub(crate) config: SourceConfig,
    /// The subscription's name when there is one — see [`Browsed::owned_here`].
    subscription: Option<String>,
    /// The source's committed reviews, parsed once for this browse. A file
    /// that will not parse settles nothing and says so through
    /// `reviews_unreadable` — browsing a catalog whose review file is
    /// broken still shows the catalog.
    pub(crate) reviews: std::collections::BTreeMap<String, crate::quality::reviews::SafetyReview>,
    pub(crate) reviews_unreadable: Option<String>,
}

/// The scope records the join reads. Browsing observes: a scope whose
/// manifest or lock is still the old generation reads as empty rather than
/// blocking the page — the records only feed the installed-state join.
fn records(env: &Env, scope: &Scope) -> Result<(Manifest, Lock)> {
    let manifest = match crate::manifest::load(&crate::manifest::manifest_path(env, scope))? {
        ManifestFile::Current(manifest) => *manifest,
        _ => Manifest::default(),
    };
    let lock = match crate::lock::load_file(&crate::lock::lock_path(env, scope))? {
        LockFile::Current(lock) => lock,
        _ => Lock::default(),
    };
    Ok((manifest, lock))
}

pub(crate) fn open(env: &Env, catalog: &Catalog) -> Result<Browsed> {
    match catalog {
        Catalog::Subscription { scope, source } => {
            let (manifest, lock) = records(env, scope)?;
            let resolved = require_ready(env, scope, source, &manifest)?;
            browsed(
                scope.clone(),
                manifest,
                lock,
                resolved,
                Some(source.clone()),
            )
        }
        Catalog::Repo { repo } => {
            let key = browsable(repo)?;
            // The store answers without the network when it already holds
            // the repository; otherwise this is the one fetch.
            let resolution = match crate::remote::cached(env, &key, None)? {
                Some(resolution) => resolution,
                None => crate::remote::sync(env, &key, None)?,
            };
            open_repo(env, key, resolution)
        }
    }
}

/// A repository nobody subscribes to, at the resolution the caller already
/// holds — `summary` refreshes first and reads what it fetched.
pub(crate) fn open_repo(
    env: &Env,
    key: String,
    resolution: crate::remote::Resolution,
) -> Result<Browsed> {
    // Collisions are judged against the personal scope: that is where
    // Subscribe lands by default, so the warning shown here is the refusal
    // an install there would meet.
    let (manifest, lock) = records(env, &Scope::Global)?;
    let source = ResolvedSource {
        name: key.clone(),
        root: resolution.root,
        provenance: key,
        commit: Some(resolution.commit),
    };
    browsed(Scope::Global, manifest, lock, source, None)
}

fn browsed(
    scope: Scope,
    manifest: Manifest,
    lock: Lock,
    source: ResolvedSource,
    subscription: Option<String>,
) -> Result<Browsed> {
    let sealed = SealedSource::open(&source.root)?;
    let config = source_config_for(&sealed, &source.provenance)?;
    let (reviews, reviews_unreadable) = match crate::check_catalog::dismissals::load(&sealed) {
        Ok(reviews) => (reviews, None),
        // The parse error quotes the offending line of a downloaded file;
        // it is captured escaped so every reader of it is safe, rather than
        // each of them remembering.
        Err(error) => (
            Default::default(),
            Some(crate::names::shown(&error.to_string())),
        ),
    };
    Ok(Browsed {
        scope,
        manifest,
        lock,
        source,
        sealed,
        config,
        subscription,
        reviews,
        reviews_unreadable,
    })
}

impl Browsed {
    /// Whether an installation or declaration belongs to this catalog. A
    /// bare repository is subscribed as nothing, so nothing is installed
    /// "from here" and every declared name is a collision.
    pub(super) fn owned_here(&self, source: &str) -> bool {
        self.subscription.as_deref() == Some(source)
    }

    pub(super) fn locked_here(&self, kind: ItemKind, name: &str) -> bool {
        self.lock
            .entries
            .values()
            .any(|entry| entry.kind == kind && entry.name == name && self.owned_here(&entry.source))
    }

    fn declared_here(&self, kind: ItemKind, name: &str) -> bool {
        self.manifest
            .declared(kind)
            .get(name)
            .is_some_and(|decl| self.owned_here(&decl.source))
    }

    pub(super) fn bundle_declared(&self, name: &str) -> bool {
        self.manifest
            .bundles
            .get(name)
            .is_some_and(|decl| self.owned_here(&decl.source))
    }

    /// The lock+manifest join behind every state column. `asked_for` says a
    /// declared bundle carries the item even where it is not declared by
    /// name — either way, asked-for content with no installation is either
    /// waiting for an apply or held back, and the same verdict the gate
    /// derives says which.
    pub(super) fn state(
        &self,
        env: &Env,
        kind: ItemKind,
        name: &str,
        carried_by_declared_bundle: bool,
    ) -> Result<InstallState> {
        if self.locked_here(kind, name) {
            return Ok(InstallState::Installed);
        }
        if !self.declared_here(kind, name) && !carried_by_declared_bundle {
            return Ok(InstallState::Available);
        }
        match safety::verdict_for(env, self, kind, name)? {
            Verdict::Block => Ok(InstallState::HeldBackBySafety),
            _ => Ok(InstallState::Available),
        }
    }

    /// The source a name is already taken by, when it is not this one. A
    /// fork counts too — `local` is a source like any other here.
    pub(super) fn collision(&self, kind: ItemKind, name: &str) -> Option<String> {
        if let Some(decl) = self.manifest.declared(kind).get(name)
            && !self.owned_here(&decl.source)
        {
            return Some(decl.source.clone());
        }
        self.lock
            .entries
            .values()
            .find(|entry| {
                entry.kind == kind && entry.name == name && !self.owned_here(&entry.source)
            })
            .map(|entry| entry.source.clone())
    }

    pub(super) fn bundle_collision(&self, name: &str) -> Option<String> {
        self.manifest
            .bundles
            .get(name)
            .filter(|decl| !self.owned_here(&decl.source))
            .map(|decl| decl.source.clone())
    }
}
