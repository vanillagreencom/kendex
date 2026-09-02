//! Which items are installed because another item requires them.
//!
//! Dependencies are declared in an item's own frontmatter, the way v1
//! declared them: a `dependencies` map holding `required` and `optional`
//! lists of bare names. Bare names are why the relation stays inside one
//! catalog and one kind — a catalog author cannot know what a consumer
//! calls their sources, so a name from somewhere else has no stable
//! identity to point at. Curation across catalogs and kinds is what bundles
//! are for.
//!
//! Nothing here is written to the manifest. The manifest records choices —
//! what was asked for, which optional dependencies were taken, what stays
//! removed — and this module derives the closure again on every plan, so an
//! item that arrived as a dependency never reads as one the user asked for.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::error::Result;
use crate::lock::{InstallRef, Reason};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{HarnessId, ItemKind};
use crate::source::{SourceConfig, find_item, list_items};
use crate::source_read::SealedSource;

use super::ItemWarning;
use super::desired::DesiredState;
use super::expansion::{Catalogs, Expansion};

/// One item's declared dependencies. Names are as the author wrote them.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Dependencies {
    pub(crate) required: Vec<String>,
    pub(crate) optional: Vec<String>,
}

/// What a skill's frontmatter declares it needs. Read through the bounded
/// parser every other frontmatter read goes through; there is no fallback to
/// scanning the body, because a dependency the author never declared is not
/// a dependency. A block that will not parse is left to the renderer, which
/// reads the same bytes and reports what is wrong with them.
pub(crate) fn declared_dependencies(
    sealed: &SealedSource,
    skill_dir: &std::path::Path,
) -> Result<Dependencies> {
    let Some(text) = sealed.read_if_exists(&skill_dir.join("SKILL.md"))? else {
        return Ok(Dependencies::default());
    };
    Ok(declared_in(&text))
}

/// [`declared_dependencies`] over bytes a caller already holds — a listing
/// reads each package's SKILL.md for its header anyway, and the sealed read
/// checks containment per path component, so reading it a second time here
/// costs the whole page.
pub(crate) fn declared_in(text: &str) -> Dependencies {
    let Ok((yaml, _)) = crate::frontmatter::split(text) else {
        return Dependencies::default();
    };
    let Ok(parsed) = crate::frontmatter::parse_tolerant(yaml) else {
        return Dependencies::default();
    };
    let Some(crate::frontmatter::Value::Map(map)) = parsed.map.get("dependencies") else {
        return Dependencies::default();
    };
    Dependencies {
        required: map.string_list("required").unwrap_or_default(),
        optional: map.string_list("optional").unwrap_or_default(),
    }
}

/// Everything the skills in this expansion require, walked until no
/// installation learns a new reason. Cycles are fine — v1's `orch` and `dev`
/// require each other on purpose — because an item is only walked again when
/// its reasons grow, and they cannot grow forever. Skills that came in as
/// bundle members are walked like any other: what a skill needs does not
/// depend on how it was chosen.
pub(super) fn expand(
    manifest: &Manifest,
    expansion: &mut Expansion,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
) {
    let mut queue: VecDeque<String> = expansion
        .of(ItemKind::Skill)
        .into_iter()
        .map(|(name, _)| name.clone())
        .collect();
    let mut edges: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    // An item is walked again whenever it gains a tool to install on, and
    // its findings are recomputed against that larger set each time. Keeping
    // only the last set per item is what stops a pair of skills that require
    // each other from reporting everything they find twice.
    let mut findings: BTreeMap<String, Vec<ItemWarning>> = BTreeMap::new();
    while let Some(parent) = queue.pop_front() {
        // A declaration no tool here can hold installs nothing, so it needs
        // nothing either; the declaration itself reports that.
        let Some(parent_decl) = expansion.decl_of(ItemKind::Skill, &parent) else {
            continue;
        };
        let source = parent_decl.source.clone();
        let harnesses = expansion.harnesses(ItemKind::Skill, &parent);
        let mut found = Vec::new();
        let wanted = wanted_by(
            &parent,
            &parent_decl,
            &harnesses,
            manifest,
            catalogs,
            state,
            &mut found,
        );
        findings.insert(parent.clone(), found);
        for (dep, harnesses) in wanted {
            // A reference filtered to no tool installs nothing, so it is
            // no edge: the finding beside it already says the dependency
            // is missing, and an edge here would have the cycle note
            // claim a co-install the graph rejected.
            if harnesses.is_empty() {
                continue;
            }
            edges.entry(parent.clone()).or_default().insert(dep.clone());
            let decl = ItemDecl {
                source: source.clone(),
                harnesses: None,
                // A derived installation takes the scope's own default
                // method: its parent's is a choice about the parent.
                method: None,
                // The revision is not: a pinned parent read its dependency
                // list from the pinned catalog, and the dependency's bytes
                // must come from the same place.
                rev: parent_decl.rev.clone(),
                enabled: true,
            };
            let mut grew = false;
            for harness in harnesses {
                let by = InstallRef {
                    source: decl.source.clone(),
                    kind: ItemKind::Skill,
                    name: parent.clone(),
                    harness,
                };
                grew |= expansion.add(
                    ItemKind::Skill,
                    &dep,
                    &decl,
                    harness,
                    Reason::RequiredBy { by },
                );
            }
            if grew {
                queue.push_back(dep);
            }
        }
    }
    state.warnings.extend(findings.into_values().flatten());
    for members in cycles(&edges) {
        if let Some(note) = co_install(&members, expansion) {
            state.notes.push(note);
        }
    }
}

/// What a knot of skills that require each other means for the reader: one
/// of them was asked for, and taking it takes the rest. Said from the
/// declared member where there is one — that is the name the reader typed —
/// and from the first member otherwise, which is equally true: every member
/// of a cycle reaches every other.
fn co_install(members: &[String], expansion: &Expansion) -> Option<String> {
    let declared = |name: &String| {
        expansion
            .harnesses(ItemKind::Skill, name)
            .into_iter()
            .any(|harness| {
                expansion
                    .reasons(ItemKind::Skill, name, harness)
                    .contains(&Reason::Requested)
            })
    };
    let asked = members
        .iter()
        .find(|name| declared(name))
        .or_else(|| members.first())?;
    // "also installs" is a claim about every tool the asked-for item lands
    // on. Where a member does not reach all of them the sentence is false
    // for the rest, and the missing-dependency finding says so instead.
    let asked_on = expansion.harnesses(ItemKind::Skill, asked);
    let reaches = |name: &String| {
        let theirs = expansion.harnesses(ItemKind::Skill, name);
        asked_on.iter().all(|harness| theirs.contains(harness))
    };
    if !members.iter().all(reaches) {
        return None;
    }
    let rest: Vec<&str> = members
        .iter()
        .filter(|name| *name != asked)
        .map(String::as_str)
        .collect();
    match rest.is_empty() {
        // A skill that lists itself: the reference resolves to the item
        // that wrote it. Said out loud rather than dropped — the reader
        // owns the catalog line that put it there.
        true => Some(format!(
            "{asked} lists itself as required — that line installs nothing"
        )),
        false => Some(format!(
            "installing {asked} also installs {} (required)",
            rest.join(", ")
        )),
    }
}

/// One item's dependencies, resolved against its own catalog: the required
/// ones, plus the optional ones this manifest chose. Everything that cannot
/// be resolved goes into `found` as a finding on the item that asked for it —
/// a dependency is never dropped in silence.
#[allow(clippy::too_many_arguments)]
fn wanted_by(
    parent: &str,
    parent_decl: &crate::manifest::ItemDecl,
    harnesses: &[HarnessId],
    manifest: &Manifest,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
    found: &mut Vec<ItemWarning>,
) -> Vec<(String, Vec<HarnessId>)> {
    let source = parent_decl.source.as_str();
    let Some((sealed, config, offered)) = catalogs.get(source, parent_decl.rev.as_deref(), state)
    else {
        return Vec::new();
    };
    let Some(dir) = find_item(sealed, config, ItemKind::Skill, parent) else {
        return Vec::new();
    };
    let Ok(declared) = declared_dependencies(sealed, &dir) else {
        return Vec::new();
    };
    let chosen = manifest
        .optional_dependencies
        .get(parent)
        .cloned()
        .unwrap_or_default();
    for name in chosen.iter().filter(|c| !declared.optional.contains(c)) {
        found.push(warn(
            parent,
            format!("{name} was chosen as an optional dependency, and {parent} does not offer one by that name"),
            format!("remove {name} from optional-dependencies.{parent} in kendex.toml"),
        ));
    }
    let mut wanted = Vec::new();
    for name in declared
        .required
        .iter()
        .chain(declared.optional.iter().filter(|o| chosen.contains(o)))
    {
        let Some(dep) = resolve(name, parent, sealed, config, offered, source, found) else {
            continue;
        };
        if manifest.is_held_back(ItemKind::Skill, &dep) {
            found.push(warn(
                parent,
                format!("missing required dependency: {parent} requires {dep}, which is kept removed"),
                format!("add the skill {dep} again to restore it, or drop it from {parent}'s dependencies"),
            ));
            continue;
        }
        wanted.push((
            dep.clone(),
            for_harnesses(&dep, parent, harnesses, manifest, found),
        ));
    }
    wanted
}

/// Where a bare dependency name points inside its own catalog, as a
/// finding on the parent when it points nowhere usable. The lookup itself
/// is [`OfferedSkills::resolve`] — the one account of how a bare name is
/// disambiguated, shared with the catalog pages so what a page promises
/// and what an install takes cannot drift apart.
fn resolve(
    name: &str,
    parent: &str,
    sealed: &SealedSource,
    config: &SourceConfig,
    offered: &OfferedSkills,
    source: &str,
    found: &mut Vec<ItemWarning>,
) -> Option<String> {
    match offered.resolve(sealed, config, name) {
        Ok(resolved) => Some(resolved),
        Err(candidates) if candidates.is_empty() => {
            found.push(warn(
                parent,
                format!("{parent} requires {name}, which the catalog '{source}' does not offer"),
                format!("add {name} to that catalog, or drop it from {parent}'s dependencies"),
            ));
            None
        }
        Err(candidates) => {
            found.push(warn(
                parent,
                format!(
                    "{parent} requires {name}, and the catalog '{source}' offers {}",
                    candidates.join(" and ")
                ),
                format!("name one of them in full in {parent}'s dependencies"),
            ));
            None
        }
    }
}

/// The skills one catalog offers, indexed by the last segment of each name.
///
/// The index is built the first time a bare name misses an exact offer and
/// kept for the rest of that catalog's read: the listing walks every plugin
/// directory in the catalog, and walking it once per dependency name is
/// quadratic in catalog size — KEN-1132 measured an 82.5x listing
/// regression before this existed.
#[derive(Default)]
pub(crate) struct OfferedSkills {
    by_leaf: std::cell::OnceCell<BTreeMap<String, Vec<String>>>,
}

impl OfferedSkills {
    /// The index built up front from a listing the caller already has, so a
    /// reader that lists the catalog anyway pays for no second walk.
    pub(crate) fn from_listing(names: &[String]) -> Self {
        let index = Self::default();
        let _ = index.by_leaf.set(indexed(names));
        index
    }

    /// Where a bare dependency name points inside this catalog: the exact
    /// offer, else the single entry whose last path segment matches. `Err`
    /// carries the candidates — none where the catalog does not offer the
    /// name at all, several where it offers more than one and there is
    /// nothing here to choose between them.
    pub(crate) fn resolve(
        &self,
        sealed: &SealedSource,
        config: &SourceConfig,
        name: &str,
    ) -> std::result::Result<String, Vec<String>> {
        if find_item(sealed, config, ItemKind::Skill, name).is_some() {
            return Ok(name.to_owned());
        }
        let by_leaf = self
            .by_leaf
            .get_or_init(|| indexed(&list_items(sealed, config, ItemKind::Skill)));
        match by_leaf.get(name).map(Vec::as_slice) {
            Some([only]) => Ok(only.clone()),
            Some(several) => Err(several.to_vec()),
            None => Err(Vec::new()),
        }
    }
}

/// Every offered name under the last segment it ends with.
fn indexed(names: &[String]) -> BTreeMap<String, Vec<String>> {
    let mut index: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for offered in names {
        let leaf = offered.rsplit('/').next().unwrap_or(offered);
        index
            .entry(leaf.to_owned())
            .or_default()
            .push(offered.clone());
    }
    index
}

/// The tools a dependency installs for: the ones its parent needs it on,
/// narrowed by what the dependency's own declaration allows and by the tools
/// that can hold a skill here. A tool left out is a warning on the parent —
/// it will run without something it says it needs — never a block.
fn for_harnesses(
    dep: &str,
    parent: &str,
    parent_harnesses: &[HarnessId],
    manifest: &Manifest,
    found: &mut Vec<ItemWarning>,
) -> Vec<HarnessId> {
    let own = manifest.skills.get(dep).and_then(|d| d.harnesses.clone());
    let installs: Vec<HarnessId> = parent_harnesses
        .iter()
        .copied()
        .filter(|harness| own.as_ref().is_none_or(|list| list.contains(harness)))
        .collect();
    let missing: Vec<&str> = parent_harnesses
        .iter()
        .filter(|harness| !installs.contains(harness))
        .map(|harness| harness.display_name())
        .collect();
    if !missing.is_empty() {
        found.push(warn(
            parent,
            format!(
                "missing required dependency: {} {} {parent} without {dep}, which it requires",
                missing.join(" and "),
                match missing.len() {
                    1 => "runs",
                    _ => "run",
                }
            ),
            format!("declare {dep} for {} too", missing.join(" and ")),
        ));
    }
    installs
}

fn warn(name: &str, message: String, remediation: String) -> ItemWarning {
    ItemWarning {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        harness: None,
        message,
        remediation: Some(remediation),
    }
}

/// Every set of skills that require each other, each reported once. A cycle
/// is information, not a fault: two items that need one another are a
/// co-install their authors meant.
fn cycles(edges: &BTreeMap<String, BTreeSet<String>>) -> Vec<Vec<String>> {
    let mut found: Vec<Vec<String>> = Vec::new();
    for start in edges.keys() {
        let forward = reachable(edges, start);
        if !forward.contains(start) {
            continue;
        }
        // Everything that reaches back is in the same knot as the start.
        let members: Vec<String> = forward
            .into_iter()
            .filter(|name| reachable(edges, name).contains(start))
            .collect();
        if !found.contains(&members) {
            found.push(members);
        }
    }
    found
}

/// Every skill reachable from this one in one or more steps.
fn reachable(edges: &BTreeMap<String, BTreeSet<String>>, start: &String) -> BTreeSet<String> {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut queue: VecDeque<&String> = VecDeque::from([start]);
    while let Some(name) = queue.pop_front() {
        for next in edges.get(name).into_iter().flatten() {
            if seen.insert(next.clone()) {
                queue.push_back(next);
            }
        }
    }
    seen
}
