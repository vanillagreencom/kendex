//! Required and selected optional dependencies stay within one catalog: a
//! skill's from its SKILL.md, a hook's from its header. Derived install
//! reasons preserve the manifest as a record of user choices.

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

/// The kinds whose frontmatter declares dependencies, and so the kinds
/// [`expand`] walks. A skill names skills, a hook names hooks; no kind
/// names another.
const DEPENDENT_KINDS: [ItemKind; 2] = [ItemKind::Skill, ItemKind::Hook];

/// What an item's frontmatter declares it needs, `found` being what
/// [`find_item`] returned for it: a skill's directory, whose SKILL.md is
/// read, or a hook's script. Read through the bounded parser every other
/// frontmatter read of that kind goes through; there is no fallback to
/// scanning the body, because a dependency the author never declared is not
/// a dependency. A block that will not parse is left to the renderer, which
/// reads the same bytes and reports what is wrong with them.
pub(crate) fn declared_dependencies(
    sealed: &SealedSource,
    kind: ItemKind,
    found: &std::path::Path,
) -> Result<Dependencies> {
    let declared = match kind {
        ItemKind::Skill => sealed
            .read_if_exists(&found.join("SKILL.md"))?
            .map(|text| declared_in(&text)),
        ItemKind::Hook => sealed.read_if_exists(found)?.map(|text| Dependencies {
            required: crate::hook::parse_hook(&text)
                .map(|hook| hook.requires)
                .unwrap_or_default(),
            optional: Vec::new(),
        }),
        // No other kind's frontmatter has a dependency field to read.
        ItemKind::Agent
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Plugin
        | ItemKind::PiExtension => None,
    };
    Ok(declared.unwrap_or_default())
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

/// One item the walk names: its kind and its name, since a skill and a hook
/// may share a name and never a dependency.
type Node = (ItemKind, String);

/// Everything the skills and hooks in this expansion require, walked until
/// no installation learns another reason. Cycles are fine — `orch` and `dev`
/// require each other on purpose, and so do the lane-mail hooks — because an
/// item is only walked again when its reasons grow, and they cannot grow
/// forever. Items that came in as bundle members are walked like any other:
/// what an item needs does not depend on how it was chosen.
pub(super) fn expand(
    manifest: &Manifest,
    expansion: &mut Expansion,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
) {
    let mut queue: VecDeque<Node> = DEPENDENT_KINDS
        .into_iter()
        .flat_map(|kind| {
            expansion
                .of(kind)
                .into_iter()
                .map(move |(name, _)| (kind, name.clone()))
        })
        .collect();
    let mut edges: BTreeMap<Node, BTreeSet<Node>> = BTreeMap::new();
    // An item is walked again whenever it gains a tool to install on, and
    // its findings are recomputed against that larger set each time. Keeping
    // only the last set per item is what stops a pair of items that require
    // each other from reporting everything they find twice.
    let mut findings: BTreeMap<Node, Vec<ItemWarning>> = BTreeMap::new();
    while let Some((kind, parent)) = queue.pop_front() {
        // A declaration no tool here can hold installs nothing, so it needs
        // nothing either; the declaration itself reports that.
        let Some(parent_decl) = expansion.decl_of(kind, &parent) else {
            continue;
        };
        let source = parent_decl.source.clone();
        let harnesses = expansion.harnesses(kind, &parent);
        let mut found = Vec::new();
        let wanted = wanted_by(
            kind,
            &parent,
            &parent_decl,
            &harnesses,
            manifest,
            catalogs,
            state,
            &mut found,
        );
        findings.insert((kind, parent.clone()), found);
        for (dep, harnesses) in wanted {
            // A reference filtered to no tool installs nothing, so it is
            // no edge: the finding beside it already says the dependency
            // is missing, and an edge here would have the cycle note
            // claim a co-install the graph rejected.
            if harnesses.is_empty() {
                continue;
            }
            edges
                .entry((kind, parent.clone()))
                .or_default()
                .insert((kind, dep.clone()));
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
                env: None,
            };
            let mut grew = false;
            for harness in harnesses {
                let by = InstallRef {
                    source: decl.source.clone(),
                    kind,
                    name: parent.clone(),
                    harness,
                };
                grew |= expansion.add(kind, &dep, &decl, harness, Reason::RequiredBy { by });
            }
            if grew {
                queue.push_back((kind, dep));
            }
        }
    }
    if findings.values().any(|warnings| !warnings.is_empty()) {
        state.mark_incomplete();
    }
    state.warnings.extend(findings.into_values().flatten());
    for members in cycles(&edges) {
        if let Some(note) = co_install(&members, expansion) {
            state.notes.push(note);
        }
    }
}

/// What a knot of items that require each other means for the reader: one
/// of them was asked for, and taking it takes the rest. Said from the
/// declared member where there is one — that is the name the reader typed —
/// and from the first member otherwise, which is equally true: every member
/// of a cycle reaches every other.
fn co_install(members: &[Node], expansion: &Expansion) -> Option<String> {
    let declared = |(kind, name): &Node| {
        expansion.harnesses(*kind, name).into_iter().any(|harness| {
            expansion
                .reasons(*kind, name, harness)
                .contains(&Reason::Requested)
        })
    };
    let asked = members
        .iter()
        .find(|node| declared(node))
        .or_else(|| members.first())?;
    // "also installs" is a claim about every tool the asked-for item lands
    // on. Where a member does not reach all of them the sentence is false
    // for the rest, and the missing-dependency finding says so instead.
    let asked_on = expansion.harnesses(asked.0, &asked.1);
    let reaches = |(kind, name): &Node| {
        let theirs = expansion.harnesses(*kind, name);
        asked_on.iter().all(|harness| theirs.contains(harness))
    };
    if !members.iter().all(reaches) {
        return None;
    }
    let asked = &asked.1;
    let rest: Vec<&str> = members
        .iter()
        .filter(|(_, name)| name != asked)
        .map(|(_, name)| name.as_str())
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
    kind: ItemKind,
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
    let Some(dir) = find_item(sealed, config, kind, parent) else {
        return Vec::new();
    };
    let Ok(declared) = declared_dependencies(sealed, kind, &dir) else {
        return Vec::new();
    };
    // `[optional-dependencies.<skill>]` is the manifest's one table of
    // chosen extras, so a hook has nothing to choose from.
    let chosen = match kind {
        ItemKind::Skill => manifest
            .optional_dependencies
            .get(parent)
            .cloned()
            .unwrap_or_default(),
        ItemKind::Hook
        | ItemKind::Agent
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Plugin
        | ItemKind::PiExtension => Vec::new(),
    };
    for name in chosen.iter().filter(|c| !declared.optional.contains(c)) {
        found.push(warn(
            kind,
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
        let Some(dep) = resolve(kind, name, parent, sealed, config, offered, source, found) else {
            continue;
        };
        if manifest.is_held_back(kind, &dep) {
            found.push(warn(
                kind,
                parent,
                format!(
                    "missing required dependency: {parent} requires {dep}, which is kept removed"
                ),
                format!(
                    "add the {} {dep} again to restore it, or drop it from {parent}'s dependencies",
                    kind.name()
                ),
            ));
            continue;
        }
        wanted.push((
            dep.clone(),
            for_harnesses(kind, &dep, parent, harnesses, manifest, found),
        ));
    }
    wanted
}

/// Where a bare dependency name points inside its own catalog, as a
/// finding on the parent when it points nowhere usable. For a skill the
/// lookup is [`OfferedSkills::resolve`] — the one account of how a bare name
/// is disambiguated, shared with the catalog pages so what a page promises
/// and what an install takes cannot drift apart. A hook is one file in one
/// directory, so its name is its whole path and there is nothing to
/// disambiguate: the catalog offers it or does not.
#[allow(clippy::too_many_arguments)]
fn resolve(
    kind: ItemKind,
    name: &str,
    parent: &str,
    sealed: &SealedSource,
    config: &SourceConfig,
    offered: &OfferedSkills,
    source: &str,
    found: &mut Vec<ItemWarning>,
) -> Option<String> {
    let resolved = match kind {
        ItemKind::Skill => offered.resolve(sealed, config, name),
        ItemKind::Hook
        | ItemKind::Agent
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Plugin
        | ItemKind::PiExtension => find_item(sealed, config, kind, name)
            .map(|_| name.to_owned())
            .ok_or_else(Vec::new),
    };
    match resolved {
        Ok(resolved) => Some(resolved),
        Err(candidates) if candidates.is_empty() => {
            found.push(warn(
                kind,
                parent,
                format!("{parent} requires {name}, which the catalog '{source}' does not offer"),
                format!("add {name} to that catalog, or drop it from {parent}'s dependencies"),
            ));
            None
        }
        Err(candidates) => {
            found.push(warn(
                kind,
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
/// quadratic in catalog size. The shared index keeps the cost to one catalog
/// walk.
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
    kind: ItemKind,
    dep: &str,
    parent: &str,
    parent_harnesses: &[HarnessId],
    manifest: &Manifest,
    found: &mut Vec<ItemWarning>,
) -> Vec<HarnessId> {
    let own = manifest
        .declared(kind)
        .get(dep)
        .and_then(|d| d.harnesses.clone());
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
            kind,
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

fn warn(kind: ItemKind, name: &str, message: String, remediation: String) -> ItemWarning {
    ItemWarning {
        kind,
        name: name.to_owned(),
        harness: None,
        message,
        remediation: Some(remediation),
    }
}

/// Every set of items that require each other, each reported once. A cycle
/// is information, not a fault: two items that need one another are a
/// co-install their authors meant.
fn cycles(edges: &BTreeMap<Node, BTreeSet<Node>>) -> Vec<Vec<Node>> {
    let mut found: Vec<Vec<Node>> = Vec::new();
    for start in edges.keys() {
        let forward = reachable(edges, start);
        if !forward.contains(start) {
            continue;
        }
        // Everything that reaches back is in the same knot as the start.
        let members: Vec<Node> = forward
            .into_iter()
            .filter(|node| reachable(edges, node).contains(start))
            .collect();
        if !found.contains(&members) {
            found.push(members);
        }
    }
    found
}

/// Every item reachable from this one in one or more steps.
fn reachable(edges: &BTreeMap<Node, BTreeSet<Node>>, start: &Node) -> BTreeSet<Node> {
    let mut seen: BTreeSet<Node> = BTreeSet::new();
    let mut queue: VecDeque<&Node> = VecDeque::from([start]);
    while let Some(name) = queue.pop_front() {
        for next in edges.get(name).into_iter().flatten() {
            if seen.insert(next.clone()) {
                queue.push_back(next);
            }
        }
    }
    seen
}
