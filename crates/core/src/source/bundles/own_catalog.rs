//! This repository's own catalog, read through the same reader every
//! consumer install reads it through.
//!
//! The four sets this catalog then offered were declared with a
//! `members = ["skill/orch", ...]` list, which the reader beside this file
//! never looked at: `kendex add --bundle` recorded the set and installed
//! nothing, with every check green. That key is now the set's own breakage,
//! but a set is still only ever as real as what [`super::declared`] gets out
//! of it — a list key spelt right and pointing nowhere reads back empty —
//! so that is what is asserted here.
//!
//! A set also has to carry what its agent members load. The agent-to-skill
//! expansion in `engine::ops::add` walks `request.agents` — the agents asked
//! for by name — and a set's members never join that list: they derive at
//! plan time in `engine::bundles::installable`, after the expansion has run.
//! So whatever an agent member's mapping names arrives only if the set names
//! it too, on every path. (Skill-to-skill dependency expansion is a separate
//! pass and does reach a set's members, which is why the requirement walk
//! below is about completeness rather than about anything breaking.)

use std::path::{Path, PathBuf};

use crate::model::ItemKind;
use crate::source::{SourceConfig, find_item, list_items, source_config};
use crate::source_read::SealedSource;

/// The set that is orchestration, code-review and commit-guards plus
/// deep-research in one install. A partial set leans on dependency
/// expansion to complete itself; this one promises to carry what it
/// needs.
const WHOLE: &str = "workflow";

/// The sets [`WHOLE`] contains. `research` is deliberately not among
/// them: it is the partial install that sits beside it.
const DRAWN_FROM: [&str; 3] = ["orchestration", "code-review", "commit-guards"];

/// What [`WHOLE`] carries beyond those three. Written down so the
/// containment check runs both ways: a member added to `workflow` and to
/// nothing else has to be a deliberate entry here rather than a quiet
/// one, which is how deep-research came to be undescribed.
const BEYOND: [(ItemKind, &str); 1] = [(ItemKind::Skill, "deep-research")];

/// One member per kind these sets carry, each of which has to read back.
/// [`super::declared`] refuses a body key it does not know, so a `hooks`
/// list misspelt `hook` is reported — but a `hooks` list this catalog
/// offers nothing under is not, and it leaves the set carrying its other
/// kinds and nothing said. That is what naming one member per kind buys.
const A_MEMBER: [(&str, ItemKind, &str); 3] = [
    ("workflow", ItemKind::Agent, "reviewer-arch"),
    ("workflow", ItemKind::Skill, "orch"),
    ("commit-guards", ItemKind::Hook, "block-bare-cd"),
];

/// One requirement and one mapping each walk below must observe. Both
/// reads answer an unreadable file with nothing rather than an error, so
/// a renamed frontmatter key would otherwise leave every closure
/// assertion unreached and the whole test green.
const A_REQUIREMENT: (&str, &str) = ("orch", "dev");
/// Named through `[agent-skills]` and reachable no other way, so it
/// anchors a read of that table. `reviewer-arch` could not: it carries
/// `role: reviewer`, which `[role-skills]` maps to `reviewer` with the
/// whole `[agent-skills]` table gone.
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
/// [`A_MEMBER`] and [`DRAWN_FROM`], which panics on it: a set named in
/// neither — `research` — is not covered here.
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

            // `upstream_skills` drops a mapped name the catalog does not
            // offer, so a typo in either table resolves to silence rather
            // than to a name the loop below could fail on. Both tables are
            // read here, where the two sides are already in hand.
            let mapped = config
                .agent_skills
                .get(&member.name)
                .or_else(|| {
                    config
                        .agent_skills
                        .get(crate::mapping::skill_match_prefix(&member.name))
                })
                .into_iter()
                .flatten()
                .map(|skill| ("[agent-skills]", skill))
                .chain(
                    parsed
                        .role
                        .and_then(|role| config.role_skills.get(role.name()))
                        .into_iter()
                        .flatten()
                        .map(|skill| ("[role-skills]", skill)),
                );
            for (table, skill) in mapped {
                assert!(
                    available.contains(skill),
                    "{table} maps agent '{}' to skill '{skill}', which this catalog \
                     does not offer — the mapping resolves it to nothing, so the agent \
                     installs with that skill unmapped and no set can carry it",
                    member.name
                );
            }

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

/// The whole-workflow set is the three sets it is drawn from plus
/// [`BEYOND`], read both ways. A member added to one of the three would
/// otherwise leave `workflow` silently short, and a member added to
/// `workflow` alone would leave every description of it silently wrong —
/// which is how deep-research came to be a member nothing mentioned.
#[test]
fn the_whole_workflow_set_is_the_sets_it_is_drawn_from_plus_what_is_written_down() {
    let (sealed, config) = open();
    let whole = set(&sealed, &config, WHOLE);
    let parts: Vec<super::CatalogBundle> = DRAWN_FROM
        .iter()
        .map(|name| set(&sealed, &config, name))
        .collect();

    for (name, part) in DRAWN_FROM.iter().zip(&parts) {
        for member in &part.members {
            assert!(
                carries(&whole, member.kind, &member.name),
                "the set '{name}' carries {} '{}' and '{WHOLE}' does not — '{WHOLE}' \
                 is {DRAWN_FROM:?} plus {BEYOND:?}",
                member.kind.name(),
                member.name
            );
        }
    }

    for member in &whole.members {
        let drawn = parts
            .iter()
            .any(|part| carries(part, member.kind, &member.name));
        let written = BEYOND
            .iter()
            .any(|(kind, name)| *kind == member.kind && *name == member.name);
        assert!(
            drawn || written,
            "'{WHOLE}' carries {} '{}', which none of {DRAWN_FROM:?} carries — add it \
             to BEYOND and to what kendex.toml and the changelog say the set is",
            member.kind.name(),
            member.name
        );
    }
}
