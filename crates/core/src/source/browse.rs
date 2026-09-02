//! Browsing one catalog: every package it offers, its curated sets with
//! per-member installed state, and a package's preview before install.
//!
//! A [`Catalog`] is either a subscription or a bare GitHub repository nobody
//! has subscribed to yet — the Community tab opens the latter, and both read
//! through the same functions so the app has one detail surface. Everything
//! here is read-side. Installed state is a join over the scope's manifest
//! and lock, never stored — a bundle's partly-installed count is derived
//! from its members on every call. Every catalog byte comes through
//! [`crate::source_read::SealedSource`], and a catalog's own words are
//! shown, never acted on.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::names;
use crate::tags::Tag;

mod catalog;
mod deps;
mod opened;
mod preview;
mod safety;
mod summary;
mod updated;
pub use catalog::Catalog;
use catalog::browsable;
pub use deps::{PackageDependencies, PackageDependency};
pub use opened::records_unreadable;
pub(crate) use opened::{Browsed, open, open_repo};
pub use preview::{PackagePreview, package_file, package_preview};
pub use safety::{PackageSafety, package_safety};
pub use summary::{CatalogAbout, CatalogSummary, SubscriptionRef, about, summary};

/// Whether one offered package exists in this scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum InstallState {
    /// An installation from this subscription is recorded in the lock.
    Installed,
    /// Offered, nothing installed.
    Available,
    /// The bundle names a member the catalog no longer offers — renamed or
    /// removed upstream. A row saying so, never a dead page: the member list
    /// is catalog-authored text and one bad entry cannot break the read.
    NotOffered,
    /// The user removed this member and the removal is recorded, so nothing
    /// derives it back. The row says it was their choice and offers Restore —
    /// installing it again clears the record (invariant 2 stays intact).
    RemovedByYou,
    /// A bare dependency name the catalog offers under more than one
    /// plugin. The engine refuses to guess between them and warns naming
    /// what it found, so nothing installs — but the catalog does carry the
    /// name, and saying it is not offered would be the opposite of true.
    OfferedMoreThanOnce,
    /// The scope this state answers for has a lock that could not be read,
    /// so whether the package is installed there is unknown. The catalog is
    /// still listed — what a source offers is a fact about the source — but
    /// every standing the lock alone could have given becomes this one,
    /// decided in `Browsed::state` and `Browsed::member_state` and nowhere
    /// else. Every surface offering an install for one package reads the
    /// state: the Packages row, a set's member row, and the
    /// available-package page (through [`PackagePreview::state`]) all say
    /// why instead, so none offers an install the engine would refuse for
    /// the same unreadable record. The scope is the one the install would
    /// land in — the browsed catalog's own, or the destination a page
    /// redirects into, which is the scope the engine mutates. The set
    /// page's Install all is about the set, not a package, and reads
    /// [`BundleDetail::records_unreadable`].
    Unknown,
}

/// One package a subscription offers, as the Packages table lists it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct AvailablePackage {
    pub kind: ItemKind,
    pub name: String,
    pub description: Option<String>,
    /// What the row shows and search reads: the header's `summary`, else
    /// its `description`.
    pub summary: Option<String>,
    pub tags: Vec<Tag>,
    /// The curated sets of this catalog that carry it.
    pub bundles: Vec<String>,
    /// What installing it takes along, and what it offers to take.
    pub dependencies: PackageDependencies,
    pub state: InstallState,
    /// The source this name is already taken by, when that is a different
    /// one. Invariant 4's refusal stays in the engine — this only shows the
    /// collision before the click.
    pub collision: Option<String>,
    /// ISO-8601 committer date of the newest commit that touched this
    /// package. `None` where the catalog keeps no history kendex can read,
    /// or where the package's own commit lies past the history bound.
    pub updated_at: Option<String>,
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
    /// The lock of the scope this read answers for — the destination where
    /// the install is redirected, the browsed scope otherwise — could not be
    /// read. The set page's Install all asks about the set rather than about
    /// a member, so it needs that scope's own answer: no member row can
    /// carry it, because a member the catalog no longer offers reads
    /// [`InstallState::NotOffered`] with or without a lock, and a set whose
    /// members were all dropped — or one declared with none — would leave the
    /// page deriving "readable" from rows that never consulted the record.
    pub records_unreadable: bool,
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
    // Each item's path is resolved once, here, and spent twice: on its
    // header and on its date. Resolving is a filesystem walk per item, not
    // a lookup.
    let items = updated::offered(&browsed);
    // The bare-name index every dependency row resolves against is built
    // from the listing this loop already holds rather than a second walk.
    let skills: Vec<String> = items
        .iter()
        .filter(|item| item.kind == ItemKind::Skill)
        .map(|item| item.name.clone())
        .collect();
    let offered = crate::engine::deps::OfferedSkills::from_listing(&skills);
    // One history walk for the whole list: a call per package would be one
    // process per row on every open of the tab.
    let mut dates = updated::package_dates(env, &browsed, &items);
    let mut out = Vec::new();
    for item in items {
        let updated::Offered { kind, name, found } = item;
        let text = item_text(&browsed, kind, found.as_deref());
        let header = header_of(kind, text.as_deref());
        let carried_bundles = carried.remove(&(kind, name.clone())).unwrap_or_default();
        // Catalog-authored bundle names are shown with control and
        // deceptive characters escaped rather than acted on.
        let bundles: Vec<String> = carried_bundles.iter().map(|b| names::shown(b)).collect();
        out.push(AvailablePackage {
            state: browsed.state(browsed.records(), kind, &name),
            collision: browsed.collision(browsed.records(), kind, &name),
            description: header.description.as_deref().map(names::shown),
            summary: header.summary_or_description().map(names::shown),
            tags: header.tags,
            updated_at: dates.remove(&(kind, name.clone())),
            bundles,
            dependencies: deps::dependencies(
                &browsed,
                &offered,
                browsed.records(),
                kind,
                &name,
                text.as_deref(),
            ),
            kind,
            name,
        });
    }
    Ok(out)
}

/// Every curated set this catalog declares, each with per-member installed
/// state. What the marketplace page's Bundles tab lists: the catalog's own
/// declaration, so a set none of whose members are offered still appears.
///
/// Sorted by name here rather than by each caller. A plain catalog holds its
/// sets in a `BTreeMap` and is alphabetical already, but a plugin registry's
/// are a list in `marketplace.json` file order, and one order for every
/// consumer is the point of sorting in the read.
pub fn bundles(env: &Env, catalog: &Catalog) -> Result<Vec<BundleDetail>> {
    let browsed = open(env, catalog)?;
    let mut out: Vec<BundleDetail> = super::bundles::offered(&browsed.sealed, &browsed.config)?
        .iter()
        .map(|found| detail(&browsed, browsed.records(), found))
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// One curated set with per-member installed state. `destination` redirects
/// the install into a project: the members come from the catalog, and every
/// answer about records — each member's state and the set's own
/// [`BundleDetail::records_unreadable`] — is about the scope the install
/// would land in.
pub fn bundle(
    env: &Env,
    catalog: &Catalog,
    bundle_name: &str,
    destination: Option<&crate::model::Scope>,
) -> Result<BundleDetail> {
    let browsed = open(env, catalog)?;
    let landing = opened::landing(env, &browsed, destination)?;
    let Some(found) = super::bundles::find(&browsed.sealed, &browsed.config, bundle_name)? else {
        return Err(CoreError::NoSuchBundle {
            name: bundle_name.to_owned(),
            source_name: catalog.label().to_owned(),
        });
    };
    Ok(detail(&browsed, &landing, &found))
}

/// A declared set joined against `landing`: every member's state, and the
/// installed/total pair derived from them.
fn detail(
    browsed: &Browsed,
    landing: &opened::Records,
    found: &super::bundles::CatalogBundle,
) -> BundleDetail {
    let mut members = Vec::new();
    for member in &found.members {
        let state = browsed.member_state(landing, member.kind, &member.name);
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
    BundleDetail {
        name: names::shown(&found.name),
        description: found.description.as_deref().map(names::shown),
        version: found.version.clone(),
        category: found.category.clone(),
        installed_members: installed.min(u32::MAX as usize) as u32,
        total_members: members.len().min(u32::MAX as usize) as u32,
        members,
        collision: browsed.bundle_collision(landing, &found.name),
        records_unreadable: landing.lock_unreadable(),
    }
}

/// The bytes an item's header and its dependency declaration are both read
/// from — read once where a caller needs both, because the sealed read
/// checks containment per path component and a whole listing pays for the
/// second read of every package. `path` is the item's already-resolved
/// location: resolving is that same walk, and this is not the only caller
/// that needs it.
fn item_text(browsed: &Browsed, kind: ItemKind, path: Option<&Path>) -> Option<String> {
    let path = path?;
    match kind {
        ItemKind::Skill => browsed.sealed.read_to_string(&path.join("SKILL.md")),
        _ => browsed.sealed.read_to_string(path),
    }
    .ok()
}

/// The description, summary and tags an item writes in its own header,
/// read with the same vocabulary the scanner reads.
fn header_of(kind: ItemKind, text: Option<&str>) -> crate::scan::metadata::Metadata {
    let Some(text) = text else {
        return Default::default();
    };
    match kind {
        ItemKind::Skill | ItemKind::Agent | ItemKind::Command => {
            crate::scan::metadata::from_markdown(text)
        }
        ItemKind::McpServer => crate::scan::metadata::from_toml(text),
        // A hook script carries no header to read.
        _ => Default::default(),
    }
}

#[cfg(test)]
mod tests;
