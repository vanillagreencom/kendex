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

/// This repository's own catalog, read through the same reader every
/// consumer install reads it through.
///
/// The four sets this file's reader has always defined were declared with a
/// `members = ["skill/orch", ...]` list instead, which no reader has ever
/// looked at: `kendex add --bundle` recorded the set and installed nothing,
/// with every check green. A set is only ever as real as what [`declared`]
/// gets out of it, so that is what is asserted here.
#[cfg(test)]
mod own_catalog {
    use std::path::{Path, PathBuf};

    use crate::model::ItemKind;
    use crate::source::{find_item, source_config};
    use crate::source_read::SealedSource;

    /// The set that is the whole agent workflow in one install. A partial
    /// set leans on dependency expansion to complete itself; this one
    /// promises to carry what it needs.
    const WHOLE: &str = "workflow";

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("the repository root is two levels above crates/core")
    }

    fn open() -> (SealedSource, crate::source::SourceConfig) {
        let root = repo_root();
        let sealed = SealedSource::open(&root).expect("this repository opens as a catalog");
        let config = source_config(&sealed, "kendex").expect("its kendex.toml reads");
        (sealed, config)
    }

    /// Every set this catalog offers carries members, and each member is an
    /// item this same catalog offers.
    #[test]
    fn every_bundle_carries_members_this_catalog_offers() {
        let (sealed, config) = open();
        let bundles = super::offered(&sealed, &config).expect("its sets read");
        assert!(!bundles.is_empty(), "kendex.toml declares no sets at all");

        for bundle in &bundles {
            assert!(
                !bundle.members.is_empty(),
                "the set '{}' carries no members — list them under `agents`, `skills`, \
                 `commands`, `hooks` or `mcp-servers`, the keys the reader looks at",
                bundle.name
            );
            for member in &bundle.members {
                assert!(
                    find_item(&sealed, &config, member.kind, &member.name).is_some(),
                    "the set '{}' carries {} '{}', which this catalog does not offer",
                    bundle.name,
                    member.kind.name(),
                    member.name
                );
            }
        }
    }

    /// The whole-workflow set carries every skill its members require, so
    /// installing it alone is the whole workflow rather than a set plus
    /// whatever dependency expansion happened to drag along.
    #[test]
    fn the_whole_workflow_set_carries_what_its_members_require() {
        let (sealed, config) = open();
        let bundle = super::find(&sealed, &config, WHOLE)
            .expect("its sets read")
            .unwrap_or_else(|| panic!("kendex.toml offers no set called '{WHOLE}'"));

        let carried = |name: &str| {
            bundle
                .members
                .iter()
                .any(|member| member.kind == ItemKind::Skill && member.name == name)
        };
        for member in &bundle.members {
            if member.kind != ItemKind::Skill {
                continue;
            }
            let dir = find_item(&sealed, &config, member.kind, &member.name)
                .unwrap_or_else(|| panic!("the catalog offers skill '{}'", member.name));
            let declared = crate::engine::deps::declared_dependencies(&sealed, &dir)
                .expect("a member skill's frontmatter reads");
            for required in &declared.required {
                assert!(
                    carried(required),
                    "the set '{WHOLE}' carries skill '{}', which requires skill '{required}' \
                     — add '{required}' to the set",
                    member.name
                );
            }
        }
    }
}
