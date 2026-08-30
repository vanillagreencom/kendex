//! One catalog opened for reading, and what it knows about this scope.
//!
//! Split out of `browse.rs`. Opening a catalog is one question — which
//! bytes, at which revision, joined against whose records — and the pages
//! above read the answer rather than each assembling it.

use crate::env::Env;
use crate::error::Result;
use crate::lock::Lock;
use crate::manifest::Manifest;
use crate::model::{ItemKind, Scope};
use crate::source_read::SealedSource;

use super::super::{ResolvedSource, SourceConfig, require_ready, source_config_for};
use super::catalog::browsable;
use super::{Catalog, InstallState};

/// One catalog opened for reading, with the scope records the
/// installed-state join needs.
pub(crate) struct Browsed {
    pub(crate) manifest: Manifest,
    pub(crate) lock: Lock,
    pub(crate) source: ResolvedSource,
    pub(crate) sealed: SealedSource,
    pub(crate) config: SourceConfig,
    /// The subscription's name when there is one — see [`Browsed::owned_here`].
    subscription: Option<String>,
}

/// The scope records the join reads. Browsing observes: a scope whose
/// manifest or lock this build cannot read answers for none of its own
/// rows rather than blanking the page — the records only feed the
/// installed-state join.
fn records(env: &Env, scope: &Scope) -> Result<(Manifest, Lock)> {
    Ok((
        crate::manifest::observed(&crate::manifest::manifest_path(env, scope))?,
        crate::lock::observed(&crate::lock::lock_path(env, scope))?,
    ))
}

pub(crate) fn open(env: &Env, catalog: &Catalog) -> Result<Browsed> {
    match catalog {
        Catalog::Subscription { scope, source } => {
            let (manifest, lock) = records(env, scope)?;
            let resolved = require_ready(env, scope, source, &manifest)?;
            browsed(manifest, lock, resolved, Some(source.clone()))
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
    browsed(manifest, lock, source, None)
}

fn browsed(
    manifest: Manifest,
    lock: Lock,
    source: ResolvedSource,
    subscription: Option<String>,
) -> Result<Browsed> {
    let sealed = SealedSource::open(&source.root)?;
    let config = source_config_for(&sealed, &source.provenance)?;
    Ok(Browsed {
        manifest,
        lock,
        source,
        sealed,
        config,
        subscription,
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

    /// The lock+manifest join behind every state column: an installation
    /// recorded from here, or the package on offer.
    pub(super) fn state(&self, kind: ItemKind, name: &str) -> InstallState {
        match self.locked_here(kind, name) {
            true => InstallState::Installed,
            false => InstallState::Available,
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
