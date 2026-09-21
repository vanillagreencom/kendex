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
    // An item is walked again whenever it gains a tool to install on, and
    // what it came to — the companions it derives, its findings, the tools
    // it is withheld from — is recomputed against that larger set each
    // time. Keeping only the last answer per item is what stops a pair of
    // items that require each other from reporting everything twice.
    let mut wanted: BTreeMap<Node, Wanted> = BTreeMap::new();
    while let Some((kind, parent)) = queue.pop_front() {
        // A declaration no tool here can hold installs nothing, so it needs
        // nothing either; the declaration itself reports that.
        let Some(parent_decl) = expansion.decl_of(kind, &parent) else {
            continue;
        };
        let source = parent_decl.source.clone();
        let harnesses = expansion.harnesses(kind, &parent);
        let found = wanted_by(
            kind,
            &parent,
            &parent_decl,
            &harnesses,
            manifest,
            catalogs,
            state,
        );
        for (dep, harnesses) in &found.deps {
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
                // Nor is the switch: a companion that exists only because
                // of its parent goes off with it, or switching a hook off
                // would leave the wrappers it brought in armed beside a
                // judge that no longer runs.
                enabled: parent_decl.enabled,
                env: None,
            };
            let mut grew = false;
            for harness in harnesses {
                let by = InstallRef {
                    source: decl.source.clone(),
                    kind,
                    name: parent.clone(),
                    harness: *harness,
                };
                grew |= expansion.add(kind, dep, &decl, *harness, Reason::RequiredBy { by });
            }
            if grew {
                queue.push_back((kind, dep.clone()));
            }
        }
        wanted.insert((kind, parent.clone()), found);
    }
    withhold_requirers(&mut wanted);
    // A reference filtered to no tool installs nothing, so it is no edge:
    // the finding beside it already says the dependency is missing, and an
    // edge here would have the cycle note claim a co-install the graph
    // rejected.
    let edges: BTreeMap<Node, BTreeSet<Node>> = wanted
        .iter()
        .map(|((kind, parent), found)| {
            let deps = found
                .deps
                .iter()
                .filter(|(_, on)| !on.is_empty())
                .map(|(dep, _)| (*kind, dep.clone()))
                .collect();
            ((*kind, parent.clone()), deps)
        })
        .collect();
    let withheld: BTreeMap<&Node, &BTreeSet<HarnessId>> = wanted
        .iter()
        .filter(|(_, found)| !found.withheld.is_empty())
        .map(|(node, found)| (node, &found.withheld))
        .collect();
    for members in cycles(&edges) {
        if let Some(note) = co_install(&members, expansion, &withheld) {
            state.notes.push(note);
        }
    }
    if wanted.values().any(|found| !found.findings.is_empty()) {
        state.mark_incomplete();
    }
    for ((kind, name), found) in wanted {
        state.warnings.extend(found.findings);
        state
            .withheld
            .extend(found.withheld.into_iter().map(|h| (kind, name.clone(), h)));
    }
}

/// What one parent's declarations came to: the companions it derives, each
/// with the tools it lands on; the findings on the parent; and the tools
/// the parent itself is withheld from, because a hook whose companion will
/// not be written there is not written there either.
#[derive(Default)]
struct Wanted {
    deps: Vec<(String, Vec<HarnessId>)>,
    findings: Vec<ItemWarning>,
    withheld: BTreeSet<HarnessId>,
    /// Whether the parent is switched on: only a hook that would run is
    /// withheld, since one that is off arms nothing beside a missing judge.
    armed: bool,
}

/// A hook withheld from a tool is not written there, so a hook that
/// requires it is withheld there too, until nothing changes: the lane-mail
/// knot goes together whichever member's fault it is. Skills are not in
/// this: a skill runs without what it lacks, and its finding is the whole
/// consequence.
fn withhold_requirers(wanted: &mut BTreeMap<Node, Wanted>) {
    loop {
        let mut spread: Vec<(Node, String, Vec<HarnessId>)> = Vec::new();
        for ((kind, parent), found) in wanted.iter() {
            if *kind != ItemKind::Hook || !found.armed {
                continue;
            }
            for (dep, on) in &found.deps {
                let Some(theirs) = wanted.get(&(*kind, dep.clone())) else {
                    continue;
                };
                let tools: Vec<HarnessId> = on
                    .iter()
                    .copied()
                    .filter(|h| theirs.withheld.contains(h) && !found.withheld.contains(h))
                    .collect();
                if !tools.is_empty() {
                    spread.push(((*kind, parent.clone()), dep.clone(), tools));
                }
            }
        }
        if spread.is_empty() {
            return;
        }
        for ((kind, parent), dep, tools) in spread {
            let Some(found) = wanted.get_mut(&(kind, parent.clone())) else {
                unreachable!("{parent} was read from this map a moment ago");
            };
            found.withheld.extend(tools.iter().copied());
            found.findings.push(warn(
                kind,
                &parent,
                format!(
                    "missing required dependency: {parent} requires {dep}, which is not installed for {}",
                    named(&tools)
                ),
                format!("settle the finding on {dep}"),
            ));
        }
    }
}

/// The tools a finding names, in display order.
fn named(tools: &[HarnessId]) -> String {
    tools
        .iter()
        .map(|harness| harness.display_name())
        .collect::<Vec<_>>()
        .join(" and ")
}

/// What a knot of items that require each other means for the reader: one
/// of them was asked for, and taking it takes the rest. Said from the
/// declared member where there is one — that is the name the reader typed —
/// and from the first member otherwise, which is equally true: every member
/// of a cycle reaches every other.
fn co_install(
    members: &[Node],
    expansion: &Expansion,
    withheld: &BTreeMap<&Node, &BTreeSet<HarnessId>>,
) -> Option<String> {
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
    // on. Where a member does not reach all of them, or is withheld from
    // one, the sentence is false for the rest, and the missing-dependency
    // finding says so instead.
    let asked_on = expansion.harnesses(asked.0, &asked.1);
    let reaches = |node: &Node| {
        let theirs = expansion.harnesses(node.0, &node.1);
        let kept_out = withheld.get(node);
        asked_on.iter().all(|harness| {
            theirs.contains(harness) && !kept_out.is_some_and(|out| out.contains(harness))
        })
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
/// be resolved is a finding on the item that asked for it — a dependency is
/// never dropped in silence. For a hook the finding has a consequence too:
/// a wrapper run beside no judge refuses every call it guards, so a hook
/// whose required companion will not be written on a tool is withheld from
/// that tool, unless the hook is itself switched off and arms nothing.
#[allow(clippy::too_many_arguments)]
fn wanted_by(
    kind: ItemKind,
    parent: &str,
    parent_decl: &crate::manifest::ItemDecl,
    harnesses: &[HarnessId],
    manifest: &Manifest,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
) -> Wanted {
    let mut wanted = Wanted {
        armed: parent_decl.enabled,
        ..Wanted::default()
    };
    let found = &mut wanted.findings;
    let source = parent_decl.source.as_str();
    let Some((sealed, config, offered)) = catalogs.get(source, parent_decl.rev.as_deref(), state)
    else {
        return wanted;
    };
    let Some(dir) = find_item(sealed, config, kind, parent) else {
        return wanted;
    };
    let Ok(declared) = declared_dependencies(sealed, kind, &dir) else {
        return wanted;
    };
    // A companion is needed where the parent runs: a hook's own harnesses
    // line keeps it off the rest, so nothing is missing there.
    let harnesses: Vec<HarnessId> = match hook_header(sealed, kind, &dir) {
        Ok(Some(own)) => harnesses
            .iter()
            .copied()
            .filter(|harness| own.applies_to(*harness))
            .collect(),
        Ok(None) | Err(_) => harnesses.to_vec(),
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
    for name in declared
        .required
        .iter()
        .chain(declared.optional.iter().filter(|o| chosen.contains(o)))
    {
        let lands = companion(
            kind,
            name,
            parent,
            &harnesses,
            wanted.armed,
            manifest,
            sealed,
            config,
            offered,
            source,
            found,
        );
        if kind == ItemKind::Hook && wanted.armed {
            let on = lands.as_ref().map(|(_, on)| on.as_slice()).unwrap_or(&[]);
            wanted
                .withheld
                .extend(harnesses.iter().filter(|h| !on.contains(h)));
        }
        if let Some(landed) = lands {
            wanted.deps.push(landed);
        }
    }
    wanted
}

/// One required or chosen name, taken to the companion it names and the
/// tools that companion is written on beside its parent. `None` where
/// nothing is derived: the name resolves to nothing usable, or to an item
/// the manifest keeps removed or switched off, or to a hook whose header
/// will not read — each a finding on the parent, except that a parent
/// switched off itself misses nothing in a companion switched off too.
#[allow(clippy::too_many_arguments)]
fn companion(
    kind: ItemKind,
    name: &str,
    parent: &str,
    harnesses: &[HarnessId],
    armed: bool,
    manifest: &Manifest,
    sealed: &SealedSource,
    config: &SourceConfig,
    offered: &OfferedSkills,
    source: &str,
    found: &mut Vec<ItemWarning>,
) -> Option<(String, Vec<HarnessId>)> {
    let dep = resolve(kind, name, parent, sealed, config, offered, source, found)?;
    if manifest.is_held_back(kind, &dep) {
        found.push(warn(
            kind,
            parent,
            format!("missing required dependency: {parent} requires {dep}, which is kept removed"),
            format!(
                "add the {} {dep} again to restore it, or drop it from {parent}'s dependencies",
                kind.name()
            ),
        ));
        return None;
    }
    let declared = manifest.declared(kind).get(&dep);
    if declared.is_some_and(|decl| !decl.enabled) {
        if armed {
            found.push(warn(
                kind,
                parent,
                format!(
                    "missing required dependency: {parent} requires {dep}, which is switched off"
                ),
                format!(
                    "set enabled = true on {dep}'s declaration in kendex.toml, or drop it from {parent}'s dependencies"
                ),
            ));
        }
        return None;
    }
    // A hook the plan cannot read is dropped there under its own note; the
    // parent that needs it learns that here, where its consequence is
    // decided.
    let own = match find_item(sealed, config, kind, &dep) {
        Some(path) => hook_header(sealed, kind, &path),
        None => Ok(None),
    };
    let own = match own {
        Ok(own) => own,
        Err(problem) => {
            found.push(warn(
                kind,
                parent,
                format!(
                    "missing required dependency: {parent} requires {dep}, whose header cannot be read: {problem}"
                ),
                format!(
                    "repair {dep}'s header in the catalog '{source}', or drop it from {parent}'s dependencies"
                ),
            ));
            return None;
        }
    };
    let on = for_harnesses(
        kind,
        &dep,
        parent,
        harnesses,
        declared.and_then(|decl| decl.harnesses.as_deref()),
        own.as_ref(),
        found,
    );
    Some((dep, on))
}

/// A hook's header as the plan will read it, from the path [`find_item`]
/// returned. `Ok(None)` for every other kind, which has no header here;
/// `Err` for a hook whose file or header will not read, in the words the
/// plan's own note will use.
fn hook_header(
    sealed: &SealedSource,
    kind: ItemKind,
    path: &std::path::Path,
) -> std::result::Result<Option<crate::hook::HookSpec>, String> {
    if kind != ItemKind::Hook {
        return Ok(None);
    }
    let text = sealed
        .read_to_string(path)
        .map_err(|problem| problem.to_string())?;
    crate::hook::parse_hook(&text)
        .map(crate::hook::HookSpec::from)
        .map(Some)
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
/// narrowed by what the dependency's own declaration allows and, for a
/// hook, by its own harnesses line. A tool left out is a finding on the
/// parent, which will run there without something it says it needs; what
/// the finding then costs the parent is [`wanted_by`]'s to decide.
fn for_harnesses(
    kind: ItemKind,
    dep: &str,
    parent: &str,
    parent_harnesses: &[HarnessId],
    declared_for: Option<&[HarnessId]>,
    own_header: Option<&crate::hook::HookSpec>,
    found: &mut Vec<ItemWarning>,
) -> Vec<HarnessId> {
    let declared: Vec<HarnessId> = parent_harnesses
        .iter()
        .copied()
        .filter(|harness| declared_for.is_none_or(|list| list.contains(harness)))
        .collect();
    let installs: Vec<HarnessId> = declared
        .iter()
        .copied()
        .filter(|harness| own_header.is_none_or(|own| own.applies_to(*harness)))
        .collect();
    let undeclared: Vec<HarnessId> = parent_harnesses
        .iter()
        .copied()
        .filter(|harness| !declared.contains(harness))
        .collect();
    if !undeclared.is_empty() {
        found.push(warn(
            kind,
            parent,
            format!(
                "missing required dependency: {} {} {parent} without {dep}, which it requires",
                named(&undeclared),
                runs(&undeclared)
            ),
            format!("declare {dep} for {} too", named(&undeclared)),
        ));
    }
    let kept_off: Vec<HarnessId> = declared
        .iter()
        .copied()
        .filter(|harness| !installs.contains(harness))
        .collect();
    if !kept_off.is_empty() {
        found.push(warn(
            kind,
            parent,
            format!(
                "missing required dependency: {} {} {parent} without {dep}, whose own harnesses line leaves {} out",
                named(&kept_off),
                runs(&kept_off),
                named(&kept_off)
            ),
            format!(
                "add {} to {dep}'s harnesses line in the catalog, or list {parent}'s harnesses in kendex.toml without {}",
                named(&kept_off),
                named(&kept_off)
            ),
        ));
    }
    installs
}

/// The verb for the tools a finding names.
fn runs(tools: &[HarnessId]) -> &'static str {
    match tools.len() {
        1 => "runs",
        _ => "run",
    }
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
