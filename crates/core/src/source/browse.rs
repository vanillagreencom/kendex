//! Browsing one catalog: every package it offers, its curated sets with
//! per-member installed state, and a package's preview before install.
//!
//! A [`Catalog`] is either a subscription or a bare GitHub repository nobody
//! has subscribed to yet — the Community tab opens the latter, and both read
//! through the same functions so the app has one detail surface. Everything
//! here is read-side. Installed state is a join over the scope's manifest
//! and lock, never stored — a bundle's partly-installed count is derived
//! from its members on every call. Every catalog byte comes through
//! [`SealedSource`], and a catalog's own words are shown, never acted on.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::lock::{Lock, LockFile};
use crate::manifest::{Manifest, ManifestFile};
use crate::model::{ItemKind, Scope};
use crate::names;
use crate::quality::Verdict;
use crate::source_read::SealedSource;
use crate::tags::Tag;

mod preview;
mod safety;
mod summary;
pub use preview::{PackagePreview, package_preview};
pub use safety::{PackageSafety, package_safety};
pub use summary::{CatalogSummary, SubscriptionRef, about, summary};

/// What a browse read addresses: a subscription, or a GitHub repository
/// browsed before anyone subscribes to it. The second fetches into the same
/// store a later subscription reads from, so subscribing never downloads
/// twice and the pages keep working across the switch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "by", rename_all = "camelCase")]
pub enum Catalog {
    Subscription {
        scope: Scope,
        source: String,
    },
    /// `owner/repo` on GitHub, as the directory spells it.
    Repo {
        repo: String,
    },
}

impl Catalog {
    /// How the catalog is named in an error or a title.
    pub fn label(&self) -> &str {
        match self {
            Catalog::Subscription { source, .. } => source,
            Catalog::Repo { repo } => repo,
        }
    }
}

/// Whether one offered package exists in this scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum InstallState {
    /// An installation from this subscription is recorded in the lock.
    Installed,
    /// Offered, nothing installed.
    Available,
    /// Asked for — declared, or carried by a declared bundle — but the
    /// safety gate refuses to install it.
    HeldBackBySafety,
    /// The bundle names a member the catalog no longer offers — renamed or
    /// removed upstream. A row saying so, never a dead page: the member list
    /// is catalog-authored text and one bad entry cannot break the read.
    NotOffered,
    /// The user removed this member and the removal is recorded, so nothing
    /// derives it back. The row says it was their choice and offers Restore —
    /// installing it again clears the record (invariant 2 stays intact).
    RemovedByYou,
}

/// One package a subscription offers, as the Packages table lists it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AvailablePackage {
    pub kind: ItemKind,
    pub name: String,
    pub description: Option<String>,
    pub tags: Vec<Tag>,
    /// The curated sets of this catalog that carry it.
    pub bundles: Vec<String>,
    pub state: InstallState,
    /// The source this name is already taken by, when that is a different
    /// one. Invariant 4's refusal stays in the engine — this only shows the
    /// collision before the click.
    pub collision: Option<String>,
}

/// One member of a curated set, with where it stands here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleMemberRow {
    pub kind: ItemKind,
    pub name: String,
    pub state: InstallState,
}

/// A curated set with per-member state. Partly-installed is the derived
/// pair below, computed from the members on every call and stored nowhere.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleDetail {
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    pub category: Option<String>,
    pub members: Vec<BundleMemberRow>,
    /// Members with an installation recorded in the lock, via any edge.
    pub installed_members: u32,
    pub total_members: u32,
    pub collision: Option<String>,
}

/// One catalog opened for reading, with the scope records the
/// installed-state join needs.
pub(crate) struct Browsed {
    pub(crate) manifest: Manifest,
    pub(crate) lock: Lock,
    pub(crate) source: super::ResolvedSource,
    pub(crate) sealed: SealedSource,
    pub(crate) config: super::SourceConfig,
    /// The subscription's name when there is one. A bare repository is
    /// subscribed as nothing, so nothing is installed "from here" and every
    /// declared name is a collision.
    subscription: Option<String>,
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
    let (manifest, lock, source, subscription) = match catalog {
        Catalog::Subscription { scope, source } => {
            let (manifest, lock) = records(env, scope)?;
            let resolved = super::require_ready(env, scope, source, &manifest)?;
            (manifest, lock, resolved, Some(source.clone()))
        }
        Catalog::Repo { repo } => {
            // Collisions are judged against the personal scope: that is
            // where Subscribe lands by default, so the warning shown here
            // is the refusal an install there would meet.
            let (manifest, lock) = records(env, &Scope::Global)?;
            (manifest, lock, resolve_repo(env, repo)?, None)
        }
    };
    let sealed = SealedSource::open(&source.root)?;
    let config = super::source_config_for(&sealed, &source.provenance)?;
    Ok(Browsed {
        manifest,
        lock,
        source,
        sealed,
        config,
        subscription,
    })
}

/// The checked-out head of a repository nobody subscribes to. The store
/// answers without the network when it already holds the repository;
/// otherwise this is the one fetch, into the store a subscription would
/// use. Only GitHub's `owner/repo` is browsable this way — that is what the
/// directory and skills.sh hand over, and anything else is a reference to
/// subscribe to, not to open blind.
fn resolve_repo(env: &Env, repo: &str) -> Result<super::ResolvedSource> {
    if crate::repo_move::owner_repo(repo).is_none() {
        return Err(CoreError::NotBrowsable {
            reference: repo.to_owned(),
        });
    }
    // Kept in the directory's spelling: the store keys by it, and Subscribe
    // is prefilled with the same string, so the two share one download.
    let repo = repo.trim();
    let resolution = match crate::remote::cached(env, repo, None)? {
        Some(resolution) => resolution,
        None => crate::remote::sync(env, repo, None)?,
    };
    Ok(super::ResolvedSource {
        name: repo.to_owned(),
        root: resolution.root,
        provenance: repo.to_owned(),
        commit: Some(resolution.commit),
    })
}

impl Browsed {
    fn locked_here(&self, kind: ItemKind, name: &str) -> bool {
        self.lock.entries.values().any(|entry| {
            entry.kind == kind
                && entry.name == name
                && Some(&entry.source) == self.subscription.as_ref()
        })
    }

    fn declared_here(&self, kind: ItemKind, name: &str) -> bool {
        self.manifest
            .declared(kind)
            .get(name)
            .is_some_and(|decl| Some(&decl.source) == self.subscription.as_ref())
    }

    fn bundle_declared(&self, name: &str) -> bool {
        self.manifest
            .bundles
            .get(name)
            .is_some_and(|decl| Some(&decl.source) == self.subscription.as_ref())
    }

    /// The lock+manifest join behind every state column. `asked_for` says a
    /// declared bundle carries the item even where it is not declared by
    /// name — either way, asked-for content with no installation is either
    /// waiting for an apply or held back, and the same verdict the gate
    /// derives says which.
    fn state(
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
    fn collision(&self, kind: ItemKind, name: &str) -> Option<String> {
        if let Some(decl) = self.manifest.declared(kind).get(name)
            && Some(&decl.source) != self.subscription.as_ref()
        {
            return Some(decl.source.clone());
        }
        self.lock
            .entries
            .values()
            .find(|entry| {
                entry.kind == kind
                    && entry.name == name
                    && Some(&entry.source) != self.subscription.as_ref()
            })
            .map(|entry| entry.source.clone())
    }

    fn bundle_collision(&self, name: &str) -> Option<String> {
        self.manifest
            .bundles
            .get(name)
            .filter(|decl| Some(&decl.source) != self.subscription.as_ref())
            .map(|decl| decl.source.clone())
    }
}

/// Every package one catalog offers, across kinds.
pub fn packages(env: &Env, catalog: &Catalog) -> Result<Vec<AvailablePackage>> {
    let browsed = open(env, catalog)?;
    let mut carried: BTreeMap<(ItemKind, String), Vec<String>> = BTreeMap::new();
    for bundle in super::bundles::offered(&browsed.sealed, &browsed.config)? {
        for member in &bundle.members {
            carried
                .entry((member.kind, member.name.clone()))
                .or_default()
                .push(bundle.name.clone());
        }
    }
    let mut out = Vec::new();
    for kind in ItemKind::ALL {
        for name in super::list_items(&browsed.sealed, &browsed.config, kind) {
            let header = item_header(&browsed, kind, &name);
            let carried_bundles = carried.remove(&(kind, name.clone())).unwrap_or_default();
            let in_declared_bundle = carried_bundles
                .iter()
                .any(|bundle| browsed.bundle_declared(bundle));
            // Catalog-authored bundle names are shown with control and
            // deceptive characters escaped rather than acted on.
            let bundles: Vec<String> = carried_bundles.iter().map(|b| names::shown(b)).collect();
            out.push(AvailablePackage {
                state: browsed.state(env, kind, &name, in_declared_bundle)?,
                collision: browsed.collision(kind, &name),
                description: header.description.as_deref().map(names::shown),
                tags: header.tags,
                bundles,
                kind,
                name,
            });
        }
    }
    Ok(out)
}

/// One curated set with per-member installed state.
pub fn bundle(env: &Env, catalog: &Catalog, bundle_name: &str) -> Result<BundleDetail> {
    let browsed = open(env, catalog)?;
    let Some(found) = super::bundles::find(&browsed.sealed, &browsed.config, bundle_name)? else {
        return Err(CoreError::NoSuchBundle {
            name: bundle_name.to_owned(),
            source_name: catalog.label().to_owned(),
        });
    };
    let declared = browsed.bundle_declared(bundle_name);
    let mut members = Vec::new();
    for member in &found.members {
        // A member the catalog names but no longer carries is a row, not a
        // hard error: state() reaches the safety scan for a declared member
        // and returns ItemNotInSource, which must not sink the whole page.
        let state = if browsed.locked_here(member.kind, &member.name) {
            InstallState::Installed
        } else if browsed.manifest.is_suppressed(member.kind, &member.name) {
            // Removed by the user, and recorded so the bundle cannot derive
            // it back — their choice, shown as such with a way to reverse it.
            InstallState::RemovedByYou
        } else if super::find_item(&browsed.sealed, &browsed.config, member.kind, &member.name)
            .is_none()
        {
            InstallState::NotOffered
        } else {
            browsed.state(env, member.kind, &member.name, declared)?
        };
        members.push(BundleMemberRow {
            kind: member.kind,
            // Catalog-authored, so shown with any control or deceptive
            // character escaped rather than acted on.
            name: names::shown(&member.name),
            state,
        });
    }
    let installed = members
        .iter()
        .filter(|member| member.state == InstallState::Installed)
        .count();
    Ok(BundleDetail {
        name: names::shown(&found.name),
        description: found.description.as_deref().map(names::shown),
        version: found.version,
        category: found.category,
        installed_members: installed.min(u32::MAX as usize) as u32,
        total_members: members.len().min(u32::MAX as usize) as u32,
        members,
        collision: browsed.bundle_collision(bundle_name),
    })
}

/// The description and tags an item writes in its own header, read through
/// the sealed source with the same vocabulary reading the scanner uses.
fn item_header(browsed: &Browsed, kind: ItemKind, name: &str) -> crate::scan::metadata::Metadata {
    let Some(path) = super::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return Default::default();
    };
    let text = match kind {
        ItemKind::Skill => browsed.sealed.read_to_string(&path.join("SKILL.md")),
        _ => browsed.sealed.read_to_string(&path),
    };
    let Ok(text) = text else {
        return Default::default();
    };
    match kind {
        ItemKind::Skill | ItemKind::Agent | ItemKind::Command => {
            crate::scan::metadata::from_markdown(&text)
        }
        ItemKind::McpServer => crate::scan::metadata::from_toml(&text),
        // A hook script carries no header to read.
        _ => Default::default(),
    }
}

#[cfg(test)]
mod tests;
