//! The curated sets a catalog offers.
//!
//! A plain catalog declares them in its own `kendex.toml`: `[bundles.<name>]`
//! with a description and one member list per kind. A plugin-registry-shaped
//! catalog declares them by existing — each plugin it ships is a set already,
//! under the name, version and category its registry carries.
//!
//! Members are bare names inside the catalog that offers them, for the same
//! reason a dependency is: a catalog author cannot know what a consumer calls
//! their other sources, so a name from somewhere else has nothing stable to
//! point at. A set therefore never reaches beyond the catalog it comes from.

use std::collections::BTreeMap;

use crate::error::Result;
use crate::model::ItemKind;
use crate::source_read::SealedSource;

use super::SourceConfig;

/// The kinds a set may carry, under the list name a catalog writes for each.
const MEMBER_LISTS: [(&str, ItemKind); 5] = [
    ("agents", ItemKind::Agent),
    ("skills", ItemKind::Skill),
    ("commands", ItemKind::Command),
    ("hooks", ItemKind::Hook),
    ("mcp-servers", ItemKind::McpServer),
];

/// The list keys a set's members are written under, in reading order.
///
/// The texts that teach catalog authors this shape are written elsewhere —
/// the `kendex init` marker, the `kendex marketplace new` scaffold — and
/// they build their sentence from this rather than spelling the keys again.
/// A hand-written copy is how the shape shipped wrong, and a copy cannot be
/// held to the original by searching it for words.
pub fn member_list_keys() -> String {
    MEMBER_LISTS
        .iter()
        .map(|(key, _)| *key)
        .collect::<Vec<_>>()
        .join(", ")
}

/// A set's member lists, one kind per line with a placeholder name, as the
/// TOML a scaffold writes commented out. Generated for the same reason the
/// sentence is, and it carries every kind so the round trip back through
/// [`declared`] covers all of them.
pub fn member_list_example() -> String {
    MEMBER_LISTS
        .iter()
        .map(|(key, kind)| format!("{key} = [\"my-{}\"]\n", kind.name()))
        .collect()
}

/// One item a set carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleMember {
    pub kind: ItemKind,
    pub name: String,
}

/// A curated set a catalog offers under one name.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogBundle {
    pub name: String,
    pub description: Option<String>,
    pub version: Option<String>,
    pub category: Option<String>,
    pub members: Vec<BundleMember>,
}

/// The `[bundles]` table of a catalog's own `kendex.toml`, read leniently the
/// way every other catalog-side table is: a member list that is not a list of
/// names carries no members, and the declaration that installs the set is
/// where a name nothing backs gets reported.
pub(super) fn declared(table: &toml::Table) -> BTreeMap<String, CatalogBundle> {
    let mut bundles = BTreeMap::new();
    let Some(declared) = table.get("bundles").and_then(toml::Value::as_table) else {
        return bundles;
    };
    for (name, body) in declared {
        let Some(body) = body.as_table() else {
            continue;
        };
        let mut members = Vec::new();
        for (list, kind) in MEMBER_LISTS {
            let Some(names) = body.get(list).and_then(toml::Value::as_array) else {
                continue;
            };
            for member in names.iter().filter_map(toml::Value::as_str) {
                members.push(BundleMember {
                    kind,
                    name: member.to_owned(),
                });
            }
        }
        bundles.insert(
            name.clone(),
            CatalogBundle {
                name: name.clone(),
                description: body
                    .get("description")
                    .and_then(toml::Value::as_str)
                    .map(crate::names::shown),
                version: None,
                category: None,
                members,
            },
        );
    }
    bundles
}

/// Every set this catalog offers.
pub fn offered(sealed: &SealedSource, config: &SourceConfig) -> Result<Vec<CatalogBundle>> {
    let Some(registry) = &config.plugin_registry else {
        return Ok(config.bundles.values().cloned().collect());
    };
    registry
        .plugins
        .iter()
        .map(|entry| from_plugin(sealed, entry))
        .collect()
}

/// The set this catalog offers under one name, or `None` when it offers none.
pub fn find(
    sealed: &SealedSource,
    config: &SourceConfig,
    name: &str,
) -> Result<Option<CatalogBundle>> {
    let Some(registry) = &config.plugin_registry else {
        return Ok(config.bundles.get(name).cloned());
    };
    match registry.entry(name) {
        Some(entry) => Ok(Some(from_plugin(sealed, entry)?)),
        None => Ok(None),
    }
}

/// A plugin read as the set it already is: what it ships, named the way those
/// items install from here.
fn from_plugin(sealed: &SealedSource, entry: &super::PluginEntry) -> Result<CatalogBundle> {
    Ok(CatalogBundle {
        name: entry.name.clone(),
        description: entry.description.clone(),
        version: entry.version.clone(),
        category: entry.category.clone(),
        members: super::catalog::plugin_members(sealed, entry)?
            .into_iter()
            .map(|item| BundleMember {
                kind: item.kind,
                name: item.name,
            })
            .collect(),
    })
}

/// What this catalog says about itself, held to what this reader gets
/// out of it. Its own file: the assertions outgrew this one.
#[cfg(test)]
mod own_catalog;
