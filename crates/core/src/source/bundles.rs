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
/// the `kendex init` marker, the marketplace scaffold — and
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

/// The table a catalog's own `kendex.toml` declares its sets under.
const BUNDLES: &str = "bundles";

/// The one key beside the member lists a set's body may carry.
const DESCRIPTION: &str = "description";

/// The key the manifest requires of every `[bundles.<name>]` it declares,
/// and one no set on offer can carry: members are bare names inside the
/// catalog that offers them, so a set names no source of its own.
const INSTALL_DECLARATION: &str = "source";

/// What a catalog's `[bundles]` table declares, read.
#[derive(Default)]
pub(super) struct DeclaredBundles {
    /// The sets on offer, by name.
    pub offered: BTreeMap<String, CatalogBundle>,
    /// The sets declared in a shape this reader will not read, by name.
    pub unreadable: BTreeMap<String, UnreadableBundle>,
    /// The `[bundles]` table itself written in a shape this reader will not
    /// read. No set name is known then, so it is the catalog's breakage
    /// rather than any one set's, and every lookup refuses on it.
    pub table: Option<UnreadableBundle>,
}

/// The `[bundles]` table of a catalog's own `kendex.toml`: the sets it
/// offers, and the ones this reader will not read.
///
/// A set is only ever as real as what comes out of this, so no body and no
/// body KEY is skipped — a key skipped is a member the set silently loses,
/// which is how `members = [...]` shipped as four sets that installed
/// nothing, and a body skipped is the whole set gone. A member list holding
/// anything but names is that set's breakage, never the names it has.
/// One unreadable body costs the other sets and every item nothing to
/// install; what it costs a removal is [`SourceConfig::hides_content`].
pub(super) fn declared(table: &toml::Table) -> DeclaredBundles {
    let mut bundles = BTreeMap::new();
    let mut unreadable = BTreeMap::new();
    let Some(value) = table.get(BUNDLES) else {
        return DeclaredBundles::default();
    };
    let Some(declared) = value.as_table() else {
        // `[[bundles]]` lands here too: the array-of-tables spelling other
        // tools use declares no set this reader can name, so there is no
        // body to hang the problem on and the catalog owns it.
        return DeclaredBundles {
            table: Some(UnreadableBundle {
                problem: format!("`{BUNDLES}` is not a table, so this catalog offers no sets"),
                fix: format!(
                    "write each set as `[{BUNDLES}.<name>]`, with a description and its members under one of: {}",
                    member_list_keys()
                ),
            }),
            ..DeclaredBundles::default()
        };
    };
    for (name, body) in declared {
        let Some(body) = body.as_table() else {
            unreadable.insert(
                name.clone(),
                UnreadableBundle {
                    problem: format!("{} is not a table", at(name)),
                    fix: format!(
                        "write it as a table, with a description and its members under one of: {}",
                        member_list_keys()
                    ),
                },
            );
            continue;
        };
        // One file is both when a project offers what it installs: the
        // manifest records an installed set under this same table name. Only
        // a body that records an install and nothing else is the manifest
        // reader's, since a record carries no members.
        if body.contains_key(INSTALL_DECLARATION)
            && !MEMBER_LISTS
                .iter()
                .any(|(list, _)| body.contains_key(*list))
        {
            continue;
        }
        match read_set(name, body) {
            Ok(set) => {
                bundles.insert(name.clone(), set);
            }
            Err(problem) => {
                unreadable.insert(name.clone(), problem);
            }
        }
    }
    DeclaredBundles {
        offered: bundles,
        unreadable,
        table: None,
    }
}

/// How a set is named back to the author who wrote it, in every problem
/// this reader reports about its body.
fn at(name: &str) -> String {
    format!("`[bundles.{}]`", crate::names::shown(name))
}

/// One `[bundles.<name>]` body as the set it declares: its keys first, so a
/// body naming a list this reader does not have is reported rather than read
/// for the lists it does have.
fn read_set(
    name: &str,
    body: &toml::Table,
) -> std::result::Result<CatalogBundle, UnreadableBundle> {
    let at = at(name);
    for key in body.keys() {
        if key == DESCRIPTION || MEMBER_LISTS.iter().any(|(list, _)| list == key) {
            continue;
        }
        return Err(match key.as_str() {
            INSTALL_DECLARATION => UnreadableBundle {
                problem: format!("{at} carries both `{INSTALL_DECLARATION}` and a member list"),
                fix: "a record of an installed set carries no members and a set on offer names no source — write one or the other".to_owned(),
            },
            _ => UnreadableBundle {
                problem: format!(
                    "{at} carries `{}`, which is not one of the lists a set's members are read from",
                    crate::names::shown(key)
                ),
                fix: format!(
                    "remove it, or write the members under one of: {}",
                    member_list_keys()
                ),
            },
        });
    }
    let mut members = Vec::new();
    for (list, kind) in MEMBER_LISTS {
        let Some(value) = body.get(list) else {
            continue;
        };
        // All-or-nothing, the rule `[catalog] skills` already gets: a value
        // that is not an array of names read for the names it happens to
        // hold is a set that installs fewer members than it was written
        // with, and says nothing about the ones it dropped.
        let Some(names) = super::config::string_list(Some(value)) else {
            return Err(UnreadableBundle {
                problem: format!("{at} writes `{list}` as something other than a list of names"),
                fix: format!("write `{list}` as an array of strings, or remove the key"),
            });
        };
        for member in names {
            members.push(BundleMember { kind, name: member });
        }
    }
    let description = match body.get(DESCRIPTION) {
        None => None,
        // The one key beside the member lists gets their rule: read for
        // whatever it happens to be is a set that ships with no description
        // and says nothing about the one that was written.
        Some(value) => match value.as_str() {
            Some(text) => Some(crate::names::shown(text)),
            None => {
                return Err(UnreadableBundle {
                    problem: format!("{at} writes `{DESCRIPTION}` as something other than text"),
                    fix: format!("write `{DESCRIPTION}` as a string, or remove the key"),
                });
            }
        },
    };
    Ok(CatalogBundle {
        name: name.to_owned(),
        description,
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
        // The table is every set's declaration, so a table that will not
        // read refuses whatever name was asked for.
        let problem = config
            .unreadable_bundle_table
            .as_ref()
            .or_else(|| config.unreadable_bundles.get(name));
        if let Some(problem) = problem {
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
