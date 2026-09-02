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
///
/// Public because the texts that teach catalog authors this shape are
/// written elsewhere — the `kendex marketplace new` scaffold, the
/// `kendex init` marker — and each has to be held against this list rather
/// than against a copy of it. A copy is how the shape shipped wrong.
pub const MEMBER_LISTS: [(&str, ItemKind); 5] = [
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
/// with every check green. A set is only ever as real as what
/// [`super::declared`] gets out of it, so that is what is asserted here.
///
/// A set also has to carry what its members load, because installing one
/// switches the agent-to-skill expansion off (`engine::ops::add`, gated by
/// `request.no_auto_skills`). Whatever an agent member's mapping names
/// arrives only if the set names it too.
#[cfg(test)]
mod own_catalog {
    use std::path::{Path, PathBuf};

    use crate::model::ItemKind;
    use crate::source::{SourceConfig, find_item, list_items, source_config};
    use crate::source_read::SealedSource;

    /// The set that is orchestration, code-review and commit-guards in one
    /// install. A partial set leans on dependency expansion to complete
    /// itself; this one promises to carry what it needs.
    const WHOLE: &str = "workflow";

    /// The sets [`WHOLE`] is the union of. `research` is deliberately not
    /// among them: it is the partial install that sits beside it.
    const DRAWN_FROM: [&str; 3] = ["orchestration", "code-review", "commit-guards"];

    /// One requirement and one mapping each walk below must observe. Both
    /// reads answer an unreadable file with nothing rather than an error, so
    /// a renamed frontmatter key would otherwise leave every closure
    /// assertion unreached and the whole test green.
    const A_REQUIREMENT: (&str, &str) = ("orch", "dev");
    /// Named through `[agent-skills]` rather than by prefix: `reviewer-arch`
    /// would still reach `reviewer` with the whole mapping table gone.
    const A_MAPPING: (&str, &str) = ("researcher", "deep-research");

    fn repo_root() -> PathBuf {
        let guess = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        guess.canonicalize().unwrap_or_else(|error| {
            panic!(
                "{} is not a readable directory, so this crate is not sitting in the \
                 kendex checkout: {error}",
                guess.display()
            )
        })
    }

    fn open() -> (SealedSource, SourceConfig) {
        let root = repo_root();
        let sealed = SealedSource::open(&root).unwrap_or_else(|error| {
            panic!("{} does not open as a catalog: {error}", root.display())
        });
        let config = source_config(&sealed, "kendex").unwrap_or_else(|error| {
            panic!("{}/kendex.toml does not read: {error}", root.display())
        });
        (sealed, config)
    }

    fn set(sealed: &SealedSource, config: &SourceConfig, name: &str) -> super::CatalogBundle {
        super::find(sealed, config, name)
            .expect("its sets read")
            .unwrap_or_else(|| panic!("kendex.toml offers no set called '{name}'"))
    }

    fn carries(bundle: &super::CatalogBundle, kind: ItemKind, name: &str) -> bool {
        bundle
            .members
            .iter()
            .any(|member| member.kind == kind && member.name == name)
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

    /// Every set carries the skills its agent members load. The mapping is
    /// resolved the way an install resolves it, so a set whose agent points
    /// at a skill it does not carry installs an agent that reads a file
    /// nothing wrote.
    #[test]
    fn every_bundle_carries_the_skills_its_agent_members_load() {
        let (sealed, config) = open();
        let available = list_items(&sealed, &config, ItemKind::Skill);
        let bundles = super::offered(&sealed, &config).expect("its sets read");
        let mut seen: Vec<(String, String)> = Vec::new();

        for bundle in &bundles {
            for member in &bundle.members {
                if member.kind != ItemKind::Agent {
                    continue;
                }
                let path = find_item(&sealed, &config, member.kind, &member.name)
                    .unwrap_or_else(|| panic!("the catalog offers agent '{}'", member.name));
                let text = sealed
                    .read_if_exists(&path)
                    .unwrap_or_else(|error| panic!("agent '{}' reads: {error}", member.name))
                    .unwrap_or_else(|| panic!("agent '{}' is a file", member.name));
                let parsed = crate::render::agent::parse_source_agent(&text)
                    .unwrap_or_else(|error| panic!("agent '{}' parses: {error}", member.name));
                for skill in
                    crate::mapping::upstream_skills(&member.name, parsed.role, &config, &available)
                {
                    seen.push((member.name.clone(), skill.clone()));
                    assert!(
                        carries(bundle, ItemKind::Skill, &skill),
                        "the set '{}' carries agent '{}', which loads skill '{skill}' — \
                         installing a set skips agent-to-skill expansion, so add '{skill}' \
                         to the set",
                        bundle.name,
                        member.name
                    );
                }
            }
        }

        let anchor = (A_MAPPING.0.to_owned(), A_MAPPING.1.to_owned());
        assert!(
            seen.contains(&anchor),
            "the walk never saw agent '{}' load skill '{}', so the mapping read is \
             answering with nothing and the assertions above were never reached",
            A_MAPPING.0,
            A_MAPPING.1
        );
    }

    /// The whole-workflow set carries every skill its skill members require,
    /// so installing it alone is the whole loop rather than a set plus
    /// whatever dependency expansion happened to drag along.
    #[test]
    fn the_whole_workflow_set_carries_what_its_members_require() {
        let (sealed, config) = open();
        let bundle = set(&sealed, &config, WHOLE);
        let mut seen: Vec<(String, String)> = Vec::new();

        for member in &bundle.members {
            if member.kind != ItemKind::Skill {
                continue;
            }
            let dir = find_item(&sealed, &config, member.kind, &member.name)
                .unwrap_or_else(|| panic!("the catalog offers skill '{}'", member.name));
            let declared = crate::engine::deps::declared_dependencies(&sealed, &dir)
                .expect("a member skill's frontmatter reads");
            for required in &declared.required {
                seen.push((member.name.clone(), required.clone()));
                assert!(
                    carries(&bundle, ItemKind::Skill, required),
                    "the set '{WHOLE}' carries skill '{}', which requires skill \
                     '{required}' — add '{required}' to the set",
                    member.name
                );
            }
        }

        let anchor = (A_REQUIREMENT.0.to_owned(), A_REQUIREMENT.1.to_owned());
        assert!(
            seen.contains(&anchor),
            "the walk never saw skill '{}' require skill '{}', so the frontmatter read \
             is answering with nothing and the assertions above were never reached",
            A_REQUIREMENT.0,
            A_REQUIREMENT.1
        );
    }

    /// The whole-workflow set is the union of the three it is drawn from.
    /// Nothing else holds that: a member added to one of them later would
    /// otherwise leave `workflow` silently short.
    #[test]
    fn the_whole_workflow_set_contains_the_sets_it_is_drawn_from() {
        let (sealed, config) = open();
        let whole = set(&sealed, &config, WHOLE);

        for name in DRAWN_FROM {
            let part = set(&sealed, &config, name);
            for member in &part.members {
                assert!(
                    carries(&whole, member.kind, &member.name),
                    "the set '{name}' carries {} '{}' and '{WHOLE}' does not — '{WHOLE}' \
                     is the union of {DRAWN_FROM:?}",
                    member.kind.name(),
                    member.name
                );
            }
        }
    }
}
