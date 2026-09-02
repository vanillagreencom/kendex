//! What a package declares it needs, read before anything installs.
//!
//! The engine's own lists, resolved through the engine's own lookup —
//! bare names inside one catalog and one kind — so the page and the
//! install picker name what the install would take, down to a dependency
//! the person has kept removed, which reads as removed here and installs
//! nowhere. Only skills declare dependencies; every other kind reads as
//! none.
//!
//! A name the catalog cannot place is still a row: the reader owns the
//! catalog line that put it there, and the row is how they learn the
//! declaration is broken.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::engine::deps::OfferedSkills;
use crate::model::ItemKind;
use crate::names;

use super::InstallState;
use super::opened::{Browsed, Records};

/// One declared dependency, with where it stands in this scope.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageDependency {
    /// The bare name its parent declares, unescaped: the spelling an
    /// install's optional choice is matched with, because
    /// [`crate::engine::ops`] matches a choice against the declared list.
    /// Never rendered — `shown` is the value a surface displays.
    pub name: String,
    /// `name` with any control or deceptive character escaped, for
    /// display. Catalog-authored text is shown, never acted on.
    pub shown: String,
    pub state: InstallState,
}

/// A package's declared dependencies: what installs with it, and what it
/// offers to take along.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageDependencies {
    /// Installed with this package, whether or not anyone asks.
    pub required: Vec<PackageDependency>,
    /// Offered; taken only where the install says so.
    pub optional: Vec<PackageDependency>,
}

impl PackageDependencies {
    pub fn is_empty(&self) -> bool {
        self.required.is_empty() && self.optional.is_empty()
    }
}

/// What this package declares it needs, against this catalog and the scope
/// the install would land in — `landing`, which is the destination where a
/// page redirects the install and the browsed scope otherwise. `offered` is
/// the catalog's bare-name index, shared across every package in one read;
/// `text` is the package's own SKILL.md, already read by the caller that
/// also wants its header.
pub(super) fn dependencies(
    browsed: &Browsed,
    offered: &OfferedSkills,
    landing: &Records,
    kind: ItemKind,
    name: &str,
    text: Option<&str>,
) -> PackageDependencies {
    if kind != ItemKind::Skill {
        return PackageDependencies::default();
    }
    let Some(text) = text else {
        return PackageDependencies::default();
    };
    let declared = crate::engine::deps::declared_in(text);
    let rows = |names: &[String]| {
        names
            .iter()
            .filter_map(|dep| row(browsed, offered, landing, name, dep))
            .collect()
    };
    PackageDependencies {
        required: rows(&declared.required),
        optional: rows(&declared.optional),
    }
}

/// One dependency row: the declared name, and this scope's state for
/// whatever that name resolves to.
///
/// `None` for a skill that lists its own name — the engine treats that line
/// as installing nothing (`co_install` says so out loud), so a row for it
/// would present as a dependency something no install acts on.
fn row(
    browsed: &Browsed,
    offered: &OfferedSkills,
    landing: &Records,
    package: &str,
    declared: &str,
) -> Option<PackageDependency> {
    let kind = ItemKind::Skill;
    let resolved = offered.resolve(&browsed.sealed, &browsed.config, declared);
    if resolved.as_deref().ok() == Some(package) {
        return None;
    }
    Some(PackageDependency {
        state: match &resolved {
            // A removal the person recorded keeps the dependency out of
            // every plan (`Manifest::is_held_back`), so the row says it was
            // their choice rather than offering to install it. The same
            // ladder a bundle member's row climbs, and the same predicate
            // `engine::deps::wanted_by` refuses on.
            Ok(name) if landing.manifest.is_held_back(kind, name) => InstallState::RemovedByYou,
            Ok(name) => browsed.state(landing, kind, name),
            // The two ways a name resolves to nothing are not one state:
            // the catalog carrying it twice under different plugins is
            // what `engine::deps::resolve` warns about by name at install
            // time, and calling that "not offered" says the opposite of
            // what the catalog holds.
            Err(candidates) if candidates.is_empty() => InstallState::NotOffered,
            Err(_) => InstallState::OfferedMoreThanOnce,
        },
        shown: names::shown(declared),
        name: declared.to_owned(),
    })
}
