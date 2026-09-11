//! This repository's own catalog, read through the same reader every
//! consumer install reads it through.
//!
//! A set is only as real as what [`super::declared`] reads from it. A list
//! key that points nowhere reads back empty, so each declared set must read
//! back with its members.

use crate::model::ItemKind;
use crate::source::{SourceConfig, find_item, source_config};
use crate::source_read::SealedSource;

/// The set that is orchestration, code-review and commit-guards plus
/// deep-research and bot-instructions in one install. A partial set leans on dependency
/// expansion to complete itself; this one promises to carry what it
/// needs.
const WHOLE: &str = "workflow";

/// One member per kind these sets carry, each of which has to read back.
/// [`super::declared`] refuses a body key it does not know, so a `hooks`
/// list misspelt `hook` is reported — but a `hooks` list this catalog
/// offers nothing under is not, and it leaves the set carrying its other
/// kinds and nothing said. That is what naming one member per kind buys.
const A_MEMBER: [(&str, ItemKind, &str); 3] = [
    ("workflow", ItemKind::Agent, "reviewer-arch"),
    ("workflow", ItemKind::Skill, "bot-instructions"),
    ("commit-guards", ItemKind::Hook, "block-bare-cd"),
];

/// One requirement the walk below must observe. The read answers an
/// unreadable file with nothing rather than an error, so a renamed
/// frontmatter key would otherwise leave every closure assertion
/// unreached and the whole test green.
const A_REQUIREMENT: (&str, &str) = ("orch", "dev");

fn open() -> (SealedSource, SourceConfig) {
    let root = crate::test_util::checkout_root();
    let sealed = SealedSource::open(&root)
        .unwrap_or_else(|error| panic!("{} does not open as a catalog: {error}", root.display()));
    let config = source_config(&sealed, "kendex")
        .unwrap_or_else(|error| panic!("{}/kendex.toml does not read: {error}", root.display()));
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

/// Every set this catalog offers carries members, each member is an item
/// this same catalog offers, and [`A_MEMBER`] names one of every kind that
/// has to read back. A set whose body will not read is dropped by
/// [`super::declared`], and what catches that is the per-name lookup in
/// [`A_MEMBER`], which panics on it: a set it does not name — `research`
/// — is not covered here.
#[test]
fn every_bundle_carries_members_this_catalog_offers() {
    let (sealed, config) = open();
    let bundles = super::offered(&sealed, &config).expect("its sets read");
    assert!(!bundles.is_empty(), "kendex.toml declares no sets at all");

    for (name, kind, member) in A_MEMBER {
        assert!(
            carries(&set(&sealed, &config, name), kind, member),
            "the set '{name}' does not read back {} '{member}' — check that its \
             kendex.toml entry still lists that name, and that this catalog \
             still offers it under that kind",
            kind.name()
        );
    }

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
