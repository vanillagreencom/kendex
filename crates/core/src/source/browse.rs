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
pub use catalog::Catalog;
use catalog::browsable;
pub use deps::{PackageDependencies, PackageDependency};
pub(crate) use opened::{Browsed, open, open_repo};
pub use preview::{PackagePreview, package_file, package_preview};
pub use safety::{PackageSafety, package_safety};
pub use summary::{CatalogSummary, SubscriptionRef, about, summary};

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
    // The catalog is listed once per kind here anyway, so the bare-name
    // index every dependency row resolves against is built from the
    // listing this loop already holds rather than from a second walk.
    let listed: Vec<(ItemKind, Vec<String>)> = ItemKind::ALL
        .iter()
        .map(|kind| {
            (
                *kind,
                super::list_items(&browsed.sealed, &browsed.config, *kind),
            )
        })
        .collect();
    let offered = crate::engine::deps::OfferedSkills::from_listing(
        listed
            .iter()
            .find(|(kind, _)| *kind == ItemKind::Skill)
            .map(|(_, names)| names.as_slice())
            .unwrap_or_default(),
    );
    let mut out = Vec::new();
    for (kind, names) in listed {
        for name in names {
            let text = item_text(&browsed, kind, &name);
            let header = header_of(kind, text.as_deref());
            let carried_bundles = carried.remove(&(kind, name.clone())).unwrap_or_default();
            // Catalog-authored bundle names are shown with control and
            // deceptive characters escaped rather than acted on.
            let bundles: Vec<String> = carried_bundles.iter().map(|b| names::shown(b)).collect();
            out.push(AvailablePackage {
                state: browsed.state(kind, &name),
                collision: browsed.collision(kind, &name),
                description: header.description.as_deref().map(names::shown),
                summary: header.summary_or_description().map(names::shown),
                tags: header.tags,
                bundles,
                dependencies: deps::dependencies(
                    &browsed,
                    &offered,
                    &deps::Where {
                        manifest: &browsed.manifest,
                        lock: &browsed.lock,
                        subscription: browsed.subscription(),
                    },
                    kind,
                    &name,
                    text.as_deref(),
                ),
                kind,
                name,
            });
        }
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
        .map(|found| detail(&browsed, found))
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
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
    Ok(detail(&browsed, &found))
}

/// A declared set joined against this scope: every member's state, and the
/// installed/total pair derived from them.
fn detail(browsed: &Browsed, found: &super::bundles::CatalogBundle) -> BundleDetail {
    let mut members = Vec::new();
    for member in &found.members {
        // A member the catalog names but no longer carries is a row, not a
        // hard error: one bad entry must not sink the whole page.
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
            InstallState::Available
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
    BundleDetail {
        name: names::shown(&found.name),
        description: found.description.as_deref().map(names::shown),
        version: found.version.clone(),
        category: found.category.clone(),
        installed_members: installed.min(u32::MAX as usize) as u32,
        total_members: members.len().min(u32::MAX as usize) as u32,
        members,
        collision: browsed.bundle_collision(&found.name),
    }
}

/// The bytes an item's header and its dependency declaration are both read
/// from — read once where a caller needs both, because the sealed read
/// checks containment per path component and a whole listing pays for the
/// second read of every package.
fn item_text(browsed: &Browsed, kind: ItemKind, name: &str) -> Option<String> {
    let path = super::find_item(&browsed.sealed, &browsed.config, kind, name)?;
    match kind {
        ItemKind::Skill => browsed.sealed.read_to_string(&path.join("SKILL.md")),
        _ => browsed.sealed.read_to_string(&path),
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
