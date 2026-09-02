//! What a package declares it needs, read before anything installs.
//!
//! The engine's own lists, resolved the way the engine resolves them —
//! bare names inside one catalog and one kind — so the page and the
//! install picker name exactly what the install would take. Only skills
//! declare dependencies; every other kind reads as none.
//!
//! A name the catalog cannot place is still a row: the reader owns the
//! catalog line that put it there, and a dependency dropped in silence
//! would have the page promise less than the install takes.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::model::ItemKind;
use crate::names;

use super::InstallState;
use super::opened::Browsed;

/// One declared dependency, with where it stands in this scope.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageDependency {
    /// The bare name its parent declares, which is also the name an
    /// install's optional choice is spelled with — [`crate::engine::ops`]
    /// matches a choice against the declared list, not against what the
    /// name resolves to.
    pub name: String,
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

/// What this package declares it needs, against this catalog and scope.
pub(super) fn dependencies(browsed: &Browsed, kind: ItemKind, name: &str) -> PackageDependencies {
    if kind != ItemKind::Skill {
        return PackageDependencies::default();
    }
    let Some(dir) = crate::source::find_item(&browsed.sealed, &browsed.config, kind, name) else {
        return PackageDependencies::default();
    };
    let Ok(declared) = crate::engine::deps::declared_dependencies(&browsed.sealed, &dir) else {
        return PackageDependencies::default();
    };
    PackageDependencies {
        required: declared
            .required
            .iter()
            .map(|dep| row(browsed, dep))
            .collect(),
        optional: declared
            .optional
            .iter()
            .map(|dep| row(browsed, dep))
            .collect(),
    }
}

/// One dependency row: the declared name, and this scope's state for
/// whatever that name resolves to. A name the catalog does not carry — or
/// carries twice under different plugins, which the engine refuses to
/// guess between — reads as no longer offered, the same row a bundle
/// member with a dead name gets.
fn row(browsed: &Browsed, declared: &str) -> PackageDependency {
    let kind = ItemKind::Skill;
    PackageDependency {
        state: match resolve(browsed, declared) {
            Some(name) => browsed.state(kind, &name),
            None => InstallState::NotOffered,
        },
        // Catalog-authored, so shown with any control or deceptive
        // character escaped rather than acted on.
        name: names::shown(declared),
    }
}

/// Where a bare dependency name points inside its own catalog: the exact
/// offer, else the single plugin-qualified one ending in that name.
/// [`crate::engine::deps`] resolves the same two ways, and a name it would
/// refuse to guess between resolves to nothing here too.
fn resolve(browsed: &Browsed, declared: &str) -> Option<String> {
    let kind = ItemKind::Skill;
    if crate::source::find_item(&browsed.sealed, &browsed.config, kind, declared).is_some() {
        return Some(declared.to_owned());
    }
    let mut candidates = crate::source::list_items(&browsed.sealed, &browsed.config, kind)
        .into_iter()
        .filter(|offered| offered.rsplit('/').next() == Some(declared));
    let only = candidates.next()?;
    candidates.next().is_none().then_some(only)
}
