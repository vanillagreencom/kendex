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

/// A `[bundles.<name>]` body written in a shape this reader will not read,
/// as the problem and fix that set is reported with.
pub(super) struct UnreadableBundle {
    pub problem: String,
    pub fix: String,
}

/// The one key beside the member lists a set's body may carry.
const DESCRIPTION: &str = "description";

/// The key the manifest requires of every `[bundles.<name>]` it declares.
/// One file is both when a project offers what it installs, so this reader
/// passes over it rather than reading it as a set's own breakage.
const INSTALL_DECLARATION: &str = "source";

/// The `[bundles]` table of a catalog's own `kendex.toml`: the sets it
/// offers, and the ones this reader will not read.
///
/// A set is only ever as real as what comes out of this, so the only body
/// KEY passed over is the manifest's own — a key skipped is a member the set
/// silently loses, which is how `members = [...]` shipped as four sets that
/// installed nothing. A list holding something else still reads as the names
/// it has.
/// One unreadable body costs the other sets and every item nothing to
/// install; what it costs a removal is [`SourceConfig::hides_content`].
pub(super) fn declared(
    table: &toml::Table,
) -> (
    BTreeMap<String, CatalogBundle>,
    BTreeMap<String, UnreadableBundle>,
) {
    let mut bundles = BTreeMap::new();
    let mut unreadable = BTreeMap::new();
    let Some(declared) = table.get("bundles").and_then(toml::Value::as_table) else {
        return (bundles, unreadable);
    };
    for (name, body) in declared {
        let Some(body) = body.as_table() else {
            continue;
        };
        match read_set(name, body) {
            Ok(set) => {
                bundles.insert(name.clone(), set);
            }
            Err(problem) => {
                unreadable.insert(name.clone(), problem);
            }
        }
    }
    (bundles, unreadable)
}

/// One `[bundles.<name>]` body as the set it declares: its keys first, so a
/// body naming a list this reader does not have is reported rather than read
/// for the lists it does have.
fn read_set(
    name: &str,
    body: &toml::Table,
) -> std::result::Result<CatalogBundle, UnreadableBundle> {
    for key in body.keys() {
        if key == DESCRIPTION
            || key == INSTALL_DECLARATION
            || MEMBER_LISTS.iter().any(|(list, _)| list == key)
        {
            continue;
        }
        return Err(UnreadableBundle {
            problem: format!(
                "`[bundles.{}]` carries `{}`, which is not one of the lists a set's members are read from",
                crate::names::shown(name),
                crate::names::shown(key)
            ),
            fix: format!(
                "remove it, or write the members under one of: {}",
                member_list_keys()
            ),
        });
    }
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
    Ok(CatalogBundle {
        name: name.to_owned(),
        description: body
            .get(DESCRIPTION)
            .and_then(toml::Value::as_str)
            .map(crate::names::shown),
        version: None,
        category: None,
        members,
    })
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
/// A set the catalog declares in a shape this reader will not read is
/// neither: answering `None` would send the person to fix the name they
/// typed, and the catalog is where the problem is.
pub fn find(
    sealed: &SealedSource,
    config: &SourceConfig,
    name: &str,
) -> Result<Option<CatalogBundle>> {
    let Some(registry) = &config.plugin_registry else {
        if let Some(problem) = config.unreadable_bundles.get(name) {
            return Err(crate::error::CoreError::UnreadableBundle {
                name: name.to_owned(),
                problem: problem.clone(),
            });
        }
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
