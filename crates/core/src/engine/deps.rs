//! Required and selected optional dependencies stay within one catalog: a
//! skill's from its SKILL.md, a hook's from its header, and a required
//! agent's from its skill assignment. Derived install reasons preserve the
//! manifest as a record of user choices.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::env::Env;
use crate::error::Result;
use crate::hook::HookSpec;
use crate::lock::{InstallRef, Reason};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::{SourceConfig, find_item, list_items};
use crate::source_read::SealedSource;

use super::ItemWarning;
use super::desired::{DesiredState, Withholding};
use super::desired_kinds::{NotWritten, manifest_refusal, not_written, pin_answers};
use super::expansion::{CatalogKey, Catalogs, Expansion, Offer, OpenCatalog, shown_rev};

pub(crate) mod commands;

/// One item's declared dependencies. Names are as the author wrote them.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Dependencies {
    pub(crate) required: Vec<String>,
    pub(crate) optional: Vec<String>,
    pub(crate) required_skills: Vec<String>,
    pub(crate) required_agents: Vec<String>,
    pub(crate) requires_on: Option<Vec<String>>,
    pub(crate) commands: Vec<commands::CommandDependency>,
}

/// Each supported edge: the declaring kind and its dependency kind.
const DEPENDENT_KINDS: [(ItemKind, ItemKind); 5] = [
    (ItemKind::Skill, ItemKind::Skill),
    (ItemKind::Skill, ItemKind::Agent),
    (ItemKind::Agent, ItemKind::Skill),
    (ItemKind::Hook, ItemKind::Hook),
    (ItemKind::Hook, ItemKind::Skill),
];

/// The kinds every walk starts from. An agent is walked only once a skill
/// requires it: one the person declared alone took its skills at `add`
/// time or was told not to (`--no-auto-skills`, a set's agents). One a
/// skill requires brings its assignment whichever way it is declared, and
/// the consumer's `[agent-skills]` row is what changes it.
const DECLARING_KINDS: [ItemKind; 2] = [ItemKind::Skill, ItemKind::Hook];

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
        ItemKind::Hook => sealed.read_if_exists(found)?.map(|text| {
            crate::hook::parse_hook(&text)
                .map(|hook| Dependencies {
                    required: hook.requires,
                    optional: Vec::new(),
                    required_skills: hook.requires_skills,
                    required_agents: Vec::new(),
                    requires_on: hook.requires_on,
                    commands: Vec::new(),
                })
                .unwrap_or_default()
        }),
        // No other kind's frontmatter has a dependency field to read.
        ItemKind::Agent
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Plugin
        | ItemKind::PiExtension
        | ItemKind::OutputStyle => None,
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
        required_skills: Vec::new(),
        required_agents: map.string_list("agents").unwrap_or_default(),
        requires_on: None,
        commands: commands::declared(&parsed.map).unwrap_or_default(),
    }
}

/// One item the walk names: its kind and its name, since a skill and a hook
/// may share a name without being the same dependency.
type Node = (ItemKind, String);

/// Everything the skills and hooks in this expansion require, and the
/// skills the agents they require bring ([`select_assignments`]), walked
/// until no installation learns another reason. Cycles are fine — `orch`
/// and `dev` require each other on purpose, and so do the lane-mail hooks
/// — because an item is only walked again when its reasons grow, and they
/// cannot grow forever. Items that came in as bundle members are walked
/// like any other: what an item needs does not depend on how it was
/// chosen.
///
/// Where the pass judges pins (`DesiredState::judge_pins`), a hook whose
/// pin alone keeps it off a tool is asked about that tool again, by the
/// same walk with that one pin dropped ([`withheld_past_pin`]), so the pin
/// records never say a pin keeps a hook off a tool it could not run on
/// anyway.
pub(super) fn expand(
    manifest: &Manifest,
    expansion: &mut Expansion,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
) {
    let every_item = DECLARING_KINDS
        .into_iter()
        .flat_map(|kind| {
            expansion
                .of(kind)
                .into_iter()
                .map(move |(name, _)| (kind, name.clone()))
        })
        .collect();
    let left_out = walk(manifest, expansion, catalogs, state, every_item);
    for (hook, tools) in left_out {
        let withheld = withheld_past_pin(manifest, expansion, catalogs, state, &hook, &tools);
        state.withheld_past_pin.extend(
            withheld
                .into_iter()
                .map(|harness| (ItemKind::Hook, hook.clone(), harness)),
        );
    }
}

/// The walk [`expand`] describes, onto `expansion` and `state`, from the
/// items in `queue` and every one they require, each walked at least once
/// and again whenever it learns a reason. Returns each hook its pin alone
/// keeps off a tool, with those tools, where the hook requires a
/// companion; one that requires nothing is withheld nowhere, pinned or
/// not.
fn walk(
    manifest: &Manifest,
    expansion: &mut Expansion,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
    queue: VecDeque<Node>,
) -> BTreeMap<String, Vec<HarnessId>> {
    let mut wanted = closure(manifest, expansion, catalogs, state, queue);
    // The walk above read every agent's assignment as bringing nothing, so
    // every revision in it is a requirement's. Only now can what each
    // assignment brings be chosen without deciding one, and the agents are
    // walked again to bring it. A walk asked again past a hook's pin
    // starts from an expansion where that choice is made.
    if !expansion.selected() {
        let agents: VecDeque<Node> = wanted
            .keys()
            .filter(|(kind, _)| *kind == ItemKind::Agent)
            .cloned()
            .collect();
        let graph = assignment_graph(manifest, expansion, catalogs, &agents);
        let (brings, contested) = select_assignments(&graph, expansion, state);
        expansion.select(brings);
        state.warnings.extend(contested);
        wanted.extend(closure(manifest, expansion, catalogs, state, agents));
    }
    carry_kept_retired_edges(expansion, state);
    // The revision each item is wanted at is known only now, once every
    // requirer has added its reason, and the walk must read it before
    // withholding spreads.
    expansion.report_rev_disagreements(state);
    settle_after_walk(catalogs.env, catalogs.scope, manifest, state, &mut wanted);
    withhold_requirers(
        &crate::manifest::manifest_file_name(catalogs.env, catalogs.scope),
        &mut wanted,
        expansion,
        state,
    );
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
                .filter(|dep| !dep.on.is_empty())
                .map(|dep| (dep.kind, dep.name.clone()))
                .collect();
            ((*kind, parent.clone()), deps)
        })
        .collect();
    let withheld: BTreeMap<&Node, BTreeSet<HarnessId>> = wanted
        .iter()
        .filter(|(_, found)| !found.withheld.is_empty())
        .map(|(node, found)| (node, found.withheld.keys().copied().collect()))
        .collect();
    for members in cycles(&edges) {
        if let Some(note) = co_install(&members, expansion, &withheld, &state.rev_conflicts) {
            state.notes.push(note);
        }
    }
    let left_out = wanted
        .iter()
        .filter(|((kind, _), found)| *kind == ItemKind::Hook && !found.left_out.is_empty())
        .map(|((_, name), found)| (name.clone(), found.left_out.clone()))
        .collect();
    record(wanted, state);
    left_out
}

/// One pass of [`walk`] from `queue`: every item it reaches walked, and
/// what each came to.
fn closure(
    manifest: &Manifest,
    expansion: &mut Expansion,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
    mut queue: VecDeque<Node>,
) -> BTreeMap<Node, Wanted> {
    // A hook's withholding is read off the companions below it, so one the
    // queue did not start with is walked the first time it is required,
    // grown or not: the walk past a pin starts from an expansion the first
    // walk already filled, so every item below the hook's direct companions
    // learns no new reason, and would otherwise go unread.
    let mut seen: BTreeSet<Node> = queue.iter().cloned().collect();
    // An item is walked again whenever it learns a reason (another
    // requirer on a tool, or its switch turned on), and what it came to —
    // the companions it derives, its findings, the tools it is withheld
    // from — is recomputed each time. Keeping only the last answer per
    // item is what stops a pair of items that require each other from
    // reporting everything twice.
    let mut wanted: BTreeMap<Node, Wanted> = BTreeMap::new();
    while let Some((kind, parent)) = queue.pop_front() {
        // A declaration no tool here can hold installs nothing, so it needs
        // nothing either; the declaration itself reports that.
        let Some(parent_decl) = expansion.decl_of(kind, &parent) else {
            continue;
        };
        let harnesses = expansion.harnesses(kind, &parent);
        let Some(found) = wanted_by(
            kind,
            &parent,
            &parent_decl,
            &harnesses,
            manifest,
            expansion,
            catalogs,
            state,
        ) else {
            continue;
        };
        let decl = derived_decl(&parent_decl);
        for Dep {
            kind: dep_kind,
            name: dep,
            on: harnesses,
            ..
        } in &found.deps
        {
            let mut grew = false;
            for harness in harnesses {
                let by = InstallRef {
                    source: decl.source.clone(),
                    kind,
                    name: parent.clone(),
                    harness: *harness,
                };
                grew |= expansion.add(*dep_kind, dep, &decl, *harness, Reason::RequiredBy { by });
            }
            let node = (*dep_kind, dep.clone());
            if seen.insert(node.clone()) || grew {
                queue.push_back(node);
            }
        }
        wanted.insert((kind, parent.clone()), found);
    }
    wanted
}

/// Of `tools`, each one `hook`'s pin alone keeps it off, those the walk
/// withholds the hook from once that pin is dropped and the hook switched
/// on: the walk run again over what the first one settled (`walked`),
/// that one declaration taken without its list, from the hook down
/// through what it requires and no further, since a hook's withholding
/// is read off its companions alone. A companion that would not run
/// there is read as the walk reads it, at any depth, a revision
/// disagreement included. What that walk derives and finds is dropped;
/// only the hook's withholding is read off it.
fn withheld_past_pin(
    manifest: &Manifest,
    walked: &Expansion,
    catalogs: &mut Catalogs,
    state: &DesiredState,
    hook: &str,
    tools: &[HarnessId],
) -> Vec<HarnessId> {
    let mut unpinned = manifest.clone();
    let Some(decl) = unpinned.declared_mut(ItemKind::Hook).get_mut(hook) else {
        unreachable!("{hook}'s pin was read off its declaration in this manifest");
    };
    decl.harnesses = None;
    decl.enabled = true;
    let decl = decl.clone();
    let asked = super::desired::target_harnesses(&decl, &unpinned, ItemKind::Hook, catalogs.scope);
    let mut expansion = walked.clone();
    expansion.redeclare(ItemKind::Hook, hook, &decl, asked);
    // The resolutions already read are handed on, so the second walk
    // resolves no source the first one did. It judges no pin: only the
    // hook's withholding is read off it.
    let mut scratch = DesiredState {
        sources: state.sources.clone(),
        pinned: state.pinned.clone(),
        ..DesiredState::default()
    };
    let from_hook = VecDeque::from([(ItemKind::Hook, hook.to_owned())]);
    walk(&unpinned, &mut expansion, catalogs, &mut scratch, from_hook);
    tools
        .iter()
        .copied()
        .filter(|harness| {
            scratch
                .withheld
                .contains_key(&(ItemKind::Hook, hook.to_owned(), *harness))
        })
        .collect()
}

/// The declaration a companion is planned under when nothing else
/// declares it: derived from its parent's. The one rule for it, read by
/// the walk to know which catalog the plan will write the companion from
/// and by [`expand`] to add the derivation, so the two cannot read
/// different catalogs.
fn derived_decl(parent_decl: &ItemDecl) -> ItemDecl {
    ItemDecl {
        source: parent_decl.source.clone(),
        harnesses: None,
        // A derived installation takes the scope's own default method:
        // its parent's is a choice about the parent.
        method: None,
        // The revision is not: a pinned parent read its dependency list
        // from the pinned catalog, and the dependency's bytes must come
        // from the same place.
        rev: parent_decl.rev.clone(),
        // Nor is the switch: a companion that exists only because of its
        // parent goes off with it, or switching a hook off would leave the
        // wrappers it brought in armed beside a judge that no longer runs.
        // `Expansion::add` turns it back on for any other requirer that is
        // on.
        enabled: parent_decl.enabled,
        env: None,
    }
}

/// What the walk came to, on the state the planner reads: every finding,
/// and every withholding under the hook and tool it is asked about.
fn record(wanted: BTreeMap<Node, Wanted>, state: &mut DesiredState) {
    if wanted.values().any(|found| !found.findings.is_empty()) {
        state.mark_incomplete();
    }
    for ((kind, name), found) in wanted {
        state.warnings.extend(found.findings);
        state.warnings.extend(found.answered);
        state.withheld.extend(
            found
                .withheld
                .into_iter()
                .map(|(harness, because)| ((kind, name.clone(), harness), because)),
        );
        state.retired_companions.extend(
            found
                .retired_companions
                .into_iter()
                .map(|(harness, companions)| ((kind, name.clone(), harness), companions)),
        );
    }
}

/// What one parent's declarations came to: the companions it derives, each
/// with the tools it lands on; the findings on the parent; and the tools
/// the parent itself is withheld from, with why, because a hook whose
/// companion will not be written there is not written there either.
struct Wanted {
    deps: Vec<Dep>,
    findings: Vec<ItemWarning>,
    /// Findings that leave the declarations complete: a companion its
    /// catalog retired, the catalog's own answer; a withholding taken on
    /// from a companion, whose own finding says what is missing, a kept
    /// retired hook's included ([`withhold_kept_retired`]); and a
    /// companion orphaned by its requirers' withholding
    /// ([`withhold_orphans`]), whose findings say why they are gone.
    answered: Vec<ItemWarning>,
    withheld: BTreeMap<HarnessId, Withholding>,
    /// For each tool the parent is withheld from for a retirement, the
    /// companions whose standing it took that reason from
    /// ([`DesiredState::retired_companions`]).
    retired_companions: BTreeMap<HarnessId, BTreeSet<Node>>,
    /// Whether the parent is switched on: only a hook that would run is
    /// withheld, since one that is off arms nothing beside a missing judge.
    armed: bool,
    /// The tools a hook's pin alone keeps it off, where it requires a
    /// companion and the pass judges pins: each asked again with the pin
    /// dropped ([`withheld_past_pin`]).
    left_out: Vec<HarnessId>,
}

impl Wanted {
    /// Withhold the parent from `tools` for this reason, which keeps the
    /// reason that outranks where one is already held ([`Withholding`]).
    fn withhold(&mut self, tools: impl IntoIterator<Item = HarnessId>, because: Withholding) {
        for tool in tools {
            self.withheld
                .entry(tool)
                .and_modify(|held| *held = (*held).max(because))
                .or_insert(because);
        }
    }

    /// [`Wanted::withhold`], for a reason taken from `companion`'s
    /// standing: a retirement records the companion, whose own verdict
    /// says whether the parent still has it (`removal::settle_lacking`).
    fn withhold_for(
        &mut self,
        tools: impl IntoIterator<Item = HarnessId>,
        because: Withholding,
        companion: &Node,
    ) {
        for tool in tools {
            self.withhold([tool], because);
            if because == Withholding::Retired {
                self.retired_companions
                    .entry(tool)
                    .or_default()
                    .insert(companion.clone());
            }
        }
    }
}

/// One companion a parent derives: the tools it runs on beside the parent;
/// the catalog the plan writes it from, by the name a finding repairs it
/// under; and its header as that catalog holds it, for the question asked
/// again once the walk is complete ([`settle_after_walk`]).
struct Dep {
    kind: ItemKind,
    name: String,
    on: Vec<HarnessId>,
    source: String,
    header: Option<HookSpec>,
}

/// A hook withheld from a tool is not written there, so a hook that
/// requires it is withheld there too, and so is a companion that exists
/// only for hooks gone from there: the lane-mail knot goes together
/// whichever member's fault it is, and a one-way edge leaves no companion
/// armed beside a requirer that is gone. A retired hook the walk derives
/// nothing for, and a copy kept as recorded stays until a prune, except
/// where what its record requires is gone ([`withhold_kept_retired`]).
/// Three phases, each run until nothing changes, and in this order: first
/// the requirers take on their companions' reasons, up every chain; then
/// the kept retired hooks take on theirs; only then, off the withholdings
/// that leaves, are companions orphaned. Whether a requirer's withholding
/// lets its copy go can change as the upward spread climbs a chain, so an
/// orphaning read off an earlier answer would be read off the wrong one.
/// Skills are not in this: a skill runs without what it lacks, and its
/// finding is the whole consequence.
fn withhold_requirers(
    manifest_file: &str,
    wanted: &mut BTreeMap<Node, Wanted>,
    expansion: &Expansion,
    state: &DesiredState,
) {
    spread_upward(manifest_file, wanted, state);
    withhold_kept_retired(manifest_file, wanted, state);
    withhold_orphans(wanted, expansion);
}

/// A retired hook kept as recorded derives nothing, so a companion the
/// plan writes for another reason would be recorded without the edge the
/// kept copy still runs with, and the next pass could take the companion
/// and leave the copy alone ([`withhold_kept_retired`]). Each recorded
/// edge is carried onto a companion planned on that tool; one planned
/// nowhere there gains nothing, and stays only as the record that requires
/// it keeps it (`removal::keep_what_kept_records_require`).
fn carry_kept_retired_edges(expansion: &mut Expansion, state: &DesiredState) {
    for ((kind, name), retirement) in &state.retired {
        for harness in HarnessId::ALL {
            if !state.kept_as_recorded(*kind, name, harness) {
                continue;
            }
            let requires = state.recorded_requires.get(&(*kind, name.clone(), harness));
            for (dep_kind, dep) in requires.into_iter().flatten() {
                let by = InstallRef {
                    source: retirement.by.source.clone(),
                    kind: *kind,
                    name: name.clone(),
                    harness,
                };
                expansion.add_to_planned(*dep_kind, dep, harness, Reason::RequiredBy { by });
            }
        }
    }
}

/// A retired hook kept as recorded runs with what its record required
/// when it was written ([`DesiredState::recorded_requires`]), not with
/// what the walk derives, which is nothing. Where one of those is withheld
/// from a tool for a reason that takes its copy, the kept copy would run
/// there beside none, so it is withheld there too, for the retirement
/// ([`Withholding::Retired`]): the knot of a retired hook and its
/// requirer goes together. A requirement orphaned or unanswered keeps its
/// copy, the orphan kept by the record that requires it
/// (`removal::keep_what_kept_records_require`), and withholds nothing.
/// Retired hooks that require each other are read until nothing changes.
fn withhold_kept_retired(
    manifest_file: &str,
    wanted: &mut BTreeMap<Node, Wanted>,
    state: &DesiredState,
) {
    loop {
        let mut spread: Vec<(Node, HarnessId, Node, String)> = Vec::new();
        for ((kind, name), retirement) in &state.retired {
            if *kind != ItemKind::Hook {
                continue;
            }
            for harness in HarnessId::ALL {
                let held = wanted
                    .get(&(*kind, name.clone()))
                    .is_some_and(|found| found.withheld.contains_key(&harness));
                if held || !state.kept_as_recorded(*kind, name, harness) {
                    continue;
                }
                let requires = state.recorded_requires.get(&(*kind, name.clone(), harness));
                let gone = requires.into_iter().flatten().find(|companion| {
                    wanted
                        .get(*companion)
                        .and_then(|theirs| theirs.withheld.get(&harness))
                        .is_some_and(|because| match because {
                            Withholding::Retired | Withholding::Requires => true,
                            Withholding::Orphaned
                            | Withholding::Unanswered
                            | Withholding::RevConflict => false,
                        })
                });
                if let Some(companion) = gone {
                    let node = (*kind, name.clone());
                    spread.push((
                        node,
                        harness,
                        companion.clone(),
                        retirement.by.source.clone(),
                    ));
                }
            }
        }
        if spread.is_empty() {
            return;
        }
        let mut tools: BTreeMap<(Node, Node, String), Vec<HarnessId>> = BTreeMap::new();
        for (node, harness, companion, source) in spread {
            tools
                .entry((node, companion, source))
                .or_default()
                .push(harness);
        }
        for (((kind, name), (dep_kind, dep), source), tools) in tools {
            let found = wanted
                .entry((kind, name.clone()))
                .or_insert_with(|| Wanted {
                    deps: Vec::new(),
                    findings: Vec::new(),
                    answered: Vec::new(),
                    withheld: BTreeMap::new(),
                    retired_companions: BTreeMap::new(),
                    armed: true,
                    left_out: Vec::new(),
                });
            let companion = (dep_kind, dep.clone());
            found.withhold_for(tools.iter().copied(), Withholding::Retired, &companion);
            found.answered.push(finding(
                manifest_file,
                &NotWritten::Withheld,
                kind,
                dep_kind,
                &name,
                &dep,
                &tools,
                &source,
            ));
        }
    }
}

/// A companion the hook requires, read from the catalog `source`, is
/// withheld from these tools for a reason the hook takes on.
struct Companion {
    kind: ItemKind,
    dep: String,
    source: String,
    tools: Vec<HarnessId>,
    because: Withholding,
}

/// A requirer takes on its companion's reason — missing, or from a catalog
/// that says nothing — whenever the spread reaches it, a chain one step
/// per pass, and a reason outranking the one already held for the tool
/// replaces it ([`Withholding`]). A companion orphaned by its requirers'
/// withholding spreads nothing back.
fn spread_upward(manifest_file: &str, wanted: &mut BTreeMap<Node, Wanted>, state: &DesiredState) {
    loop {
        let mut spread: Vec<(Node, Companion)> = Vec::new();
        for ((kind, parent), found) in wanted.iter() {
            if *kind != ItemKind::Hook || !found.armed {
                continue;
            }
            for Dep {
                kind: dep_kind,
                name: dep,
                on,
                source,
                ..
            } in &found.deps
            {
                let Some(theirs) = wanted.get(&(*dep_kind, dep.clone())) else {
                    continue;
                };
                let mut taken: BTreeMap<Withholding, Vec<HarnessId>> = BTreeMap::new();
                for harness in on {
                    let because = match theirs.withheld.get(harness) {
                        Some(Withholding::Requires) => Withholding::Requires,
                        Some(Withholding::Retired) => Withholding::Retired,
                        Some(Withholding::Unanswered) => Withholding::Unanswered,
                        Some(Withholding::RevConflict) => NotWritten::HeldRevConflict
                            .for_requirer(state, *kind, parent, *harness)
                            .withholding(),
                        Some(Withholding::Orphaned) | None => continue,
                    };
                    if found.withheld.get(harness) < Some(&because) {
                        taken.entry(because).or_default().push(*harness);
                    }
                }
                for (because, tools) in taken {
                    spread.push((
                        (*kind, parent.clone()),
                        Companion {
                            kind: *dep_kind,
                            dep: dep.clone(),
                            source: source.clone(),
                            tools,
                            because,
                        },
                    ));
                }
            }
        }
        if spread.is_empty() {
            return;
        }
        for ((kind, parent), companion) in spread {
            let Some(found) = wanted.get_mut(&(kind, parent.clone())) else {
                unreachable!("{parent} was read from this map a moment ago");
            };
            let Companion {
                kind: dep_kind,
                dep,
                source,
                tools,
                because,
            } = companion;
            found.withhold_for(tools.iter().copied(), because, &(dep_kind, dep.clone()));
            found.answered.push(finding(
                manifest_file,
                &match because {
                    Withholding::RevConflict => NotWritten::HeldRevConflict,
                    Withholding::Orphaned
                    | Withholding::Unanswered
                    | Withholding::Retired
                    | Withholding::Requires => NotWritten::Withheld,
                },
                kind,
                dep_kind,
                &parent,
                &dep,
                &tools,
                &source,
            ));
        }
    }
}

/// A derived companion is withheld from a tool where every hook that
/// requires it there is gone from it ([`orphaned`]), and its own derived
/// companions follow, until nothing changes. Read off the withholdings the
/// upward spread settled on, and never before it has.
fn withhold_orphans(wanted: &mut BTreeMap<Node, Wanted>, expansion: &Expansion) {
    loop {
        let mut spread: Vec<(Node, BTreeSet<String>, Vec<HarnessId>)> = Vec::new();
        for ((kind, parent), found) in wanted.iter() {
            if *kind != ItemKind::Hook || !found.armed {
                continue;
            }
            let mut requirers = BTreeSet::new();
            let tools: Vec<HarnessId> = expansion
                .harnesses(*kind, parent)
                .into_iter()
                .filter(|harness| {
                    !found.withheld.contains_key(harness)
                        && orphaned(wanted, *kind, parent, *harness, expansion, &mut requirers)
                })
                .collect();
            if !tools.is_empty() {
                spread.push(((*kind, parent.clone()), requirers, tools));
            }
        }
        if spread.is_empty() {
            return;
        }
        for ((kind, parent), requirers, tools) in spread {
            let Some(found) = wanted.get_mut(&(kind, parent.clone())) else {
                unreachable!("{parent} was read from this map a moment ago");
            };
            found.withhold(tools.iter().copied(), Withholding::Orphaned);
            found
                .answered
                .push(orphaned_finding(kind, &parent, &requirers, &tools));
        }
    }
}

/// Whether this hook is wanted on `harness` only by hooks gone from it:
/// every reason for its installation there is a requirer whose withholding
/// takes its copy ([`Withholding::takes`]), and none is the person asking
/// for it or a set carrying it. The requirers found are added to
/// `requirers`, for the finding.
fn orphaned(
    wanted: &BTreeMap<Node, Wanted>,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
    expansion: &Expansion,
    requirers: &mut BTreeSet<String>,
) -> bool {
    let reasons = expansion.reasons(kind, name, harness);
    if reasons.is_empty() {
        return false;
    }
    let mut withheld_by = BTreeSet::new();
    let only_withheld = reasons.iter().all(|reason| match reason {
        Reason::RequiredBy { by } => {
            let theirs = wanted.get(&(by.kind, by.name.clone()));
            let held = by.kind == kind
                && theirs.is_some_and(|theirs| {
                    theirs
                        .withheld
                        .get(&by.harness)
                        .is_some_and(|because| because.takes())
                });
            if held {
                withheld_by.insert(by.name.clone());
            }
            held
        }
        Reason::Requested | Reason::MemberOf { .. } => false,
    });
    if only_withheld {
        requirers.append(&mut withheld_by);
    }
    only_withheld
}

/// The finding on a derived companion withheld because every hook that
/// requires it is.
fn orphaned_finding(
    kind: ItemKind,
    name: &str,
    requirers: &BTreeSet<String>,
    tools: &[HarnessId],
) -> ItemWarning {
    let by: Vec<&str> = requirers.iter().map(String::as_str).collect();
    let by = by.join(" and ");
    let verb = match requirers.len() {
        1 => "is",
        _ => "are",
    };
    warn(
        kind,
        name,
        format!(
            "{name} is wanted only by {by}, which {verb} withheld from {}",
            named(tools)
        ),
        format!("settle the finding on {by}"),
    )
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
    withheld: &BTreeMap<&Node, BTreeSet<HarnessId>>,
    rev_conflicts: &BTreeSet<Node>,
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
    // on. Where a member does not reach all of them, is withheld from one,
    // or is wanted at two revisions and so written on none, the sentence is
    // false for the rest, and the finding says so instead.
    let asked_on = expansion.harnesses(asked.0, &asked.1);
    let reaches = |node: &Node| {
        let theirs = expansion.harnesses(node.0, &node.1);
        let kept_out = withheld.get(node);
        !rev_conflicts.contains(node)
            && asked_on.iter().all(|harness| {
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
///
/// A name is resolved in the parent's catalog, where its author wrote it.
/// Which copy of the companion the plan writes is the expansion's to say:
/// the declaration it already holds for that name — the person's, a set's,
/// or the first requirer's — and [`derived_decl`] of the parent's own for
/// a companion nothing else declares. The companion is read from that
/// catalog, so the walk decides on the copy the planner writes.
///
/// `None` where the parent's own catalog will not open: it derives
/// nothing, and the declaration naming that catalog reports why.
#[allow(clippy::too_many_arguments)]
fn wanted_by(
    kind: ItemKind,
    parent: &str,
    parent_decl: &ItemDecl,
    harnesses: &[HarnessId],
    manifest: &Manifest,
    expansion: &Expansion,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
) -> Option<Wanted> {
    let own: CatalogKey = (parent_decl.source.clone(), parent_decl.rev.clone());
    let (env, scope) = (catalogs.env, catalogs.scope);
    let catalog = catalogs.get(&own.0, own.1.as_deref(), state)?;
    let sealed = &catalog.sealed;
    let mut wanted = Wanted {
        deps: Vec::new(),
        findings: Vec::new(),
        answered: Vec::new(),
        withheld: BTreeMap::new(),
        retired_companions: BTreeMap::new(),
        armed: parent_decl.enabled,
        left_out: Vec::new(),
    };
    let dir = match catalog.offer(kind, parent) {
        Offer::Item(_, dir) => dir,
        // A retired item installs nothing, so it derives nothing either;
        // what a copy kept as recorded runs with is its record's
        // ([`withhold_kept_retired`]).
        Offer::Retired(migration) => {
            state.retire_planned(expansion, kind, parent, &parent_decl.source, migration);
            return None;
        }
        Offer::NotOffered | Offer::Silent => return Some(wanted),
    };
    let Some(declared) = declared_by(catalog, manifest, expansion, kind, parent, &dir) else {
        return Some(wanted);
    };
    let header = hook_header(sealed, kind, &dir);
    if let Ok(Some(own)) = &header
        && state.judge_pins
        && !(declared.required.is_empty() && declared.required_skills.is_empty())
    {
        wanted.left_out = pin_answers(env, scope, manifest, state, expansion, parent, own)
            .into_iter()
            .filter_map(|(harness, answer)| {
                (answer == Some(NotWritten::OtherTools)).then_some(harness)
            })
            .collect();
    }
    // A companion is needed where the parent runs, and nowhere else: a
    // tool the plan writes no parent on is a tool the companion is not
    // missing from, and one it would be derived on for a parent that is
    // not there. The same answer the planner takes, so the two agree on
    // where the parent runs. Off and wanted-at-two-revisions are the
    // exceptions the planner makes too: both still write the parent's
    // position, parked or held, and its companions follow it there.
    let harnesses: Vec<HarnessId> = match &header {
        Ok(Some(own)) => written_on(env, scope, manifest, state, (kind, parent), own, harnesses),
        Ok(None) | Err(_) => harnesses.to_vec(),
    };
    let found = &mut wanted.findings;
    let chosen = chosen_extras(
        &crate::manifest::manifest_file_name(env, scope),
        kind,
        parent,
        manifest,
        &declared,
        found,
    );
    // Each name taken to the companion it names, and that companion to
    // the catalog the plan writes it from. A name that resolves to nothing
    // derives nothing, which withholds an armed hook where it is required.
    let mut companions: Vec<(ItemKind, String, CatalogKey)> = Vec::new();
    let mut unresolved = Vec::new();
    for (_, dep_kind) in DEPENDENT_KINDS
        .iter()
        .filter(|(parent_kind, _)| *parent_kind == kind)
    {
        let on = dependency_harnesses(*dep_kind, &harnesses, declared.requires_on.as_deref());
        if on.is_empty() {
            continue;
        }
        for name in names_required(&declared, &chosen, kind, *dep_kind) {
            let Some(dep) = resolve(kind, *dep_kind, name, parent, catalog, &own.0, found) else {
                unresolved.extend(on.iter().copied());
                continue;
            };
            let planned = expansion
                .decl_of(*dep_kind, &dep)
                .unwrap_or_else(|| derived_decl(parent_decl));
            companions.push((*dep_kind, dep, (planned.source, planned.rev)));
        }
    }
    if kind == ItemKind::Hook && wanted.armed {
        wanted.withhold(unresolved, Withholding::Requires);
    }
    let resolved = wanted.findings.len();
    derive(
        kind,
        parent,
        &harnesses,
        declared.requires_on.as_deref(),
        companions,
        manifest,
        catalogs,
        state,
        &mut wanted,
    );
    // An agent's assignment edge is soft ([`agent_assignment`]): a skill
    // it brings that will not install, kept removed or out of reach of
    // the tool, leaves the declarations complete, and the agent pass
    // warns for it (`agent_skills::warn_uninstalled`). Its names are this
    // catalog's own, so `resolve` misses none of them.
    if kind == ItemKind::Agent {
        wanted.findings.truncate(resolved);
    }
    Some(wanted)
}

/// What `parent`, offered at `dir`, declares it needs: for an agent, the
/// skills of its assignment ([`agent_assignment`]) it brings
/// ([`select_assignments`]), none before that is chosen; for every other
/// kind, its own frontmatter. `None` where that frontmatter will not read,
/// which the renderer reports.
fn declared_by(
    catalog: &OpenCatalog,
    manifest: &Manifest,
    expansion: &Expansion,
    kind: ItemKind,
    parent: &str,
    dir: &std::path::Path,
) -> Option<Dependencies> {
    match kind {
        ItemKind::Agent => Some(Dependencies {
            required_skills: agent_assignment(catalog, manifest, parent, dir)
                .into_iter()
                .filter(|skill| expansion.brings(parent, skill))
                .collect(),
            ..Dependencies::default()
        }),
        ItemKind::Skill
        | ItemKind::Hook
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Plugin
        | ItemKind::PiExtension
        | ItemKind::OutputStyle => declared_dependencies(&catalog.sealed, kind, dir).ok(),
    }
}

/// The names `declared` requires of `dep_kind`, a `kind` parent's: its
/// required ones, and the optional ones the manifest chose (`chosen`).
fn names_required<'a>(
    declared: &'a Dependencies,
    chosen: &'a [String],
    kind: ItemKind,
    dep_kind: ItemKind,
) -> impl Iterator<Item = &'a String> {
    let (required, optional) = if dep_kind == ItemKind::Agent {
        (declared.required_agents.as_slice(), [].as_slice())
    } else if dep_kind == kind {
        (declared.required.as_slice(), declared.optional.as_slice())
    } else {
        (declared.required_skills.as_slice(), [].as_slice())
    };
    required
        .iter()
        .chain(optional.iter().filter(|name| chosen.contains(name)))
}

/// The skills an agent loads: the consumer's `[agent-skills]` row where
/// it has one, which replaces the catalog's assignment for the rendering
/// too, and the catalog's own (`mapping::upstream_skills`) otherwise.
/// Only names this catalog offers: a row may name a skill another source
/// carries, and one nothing installs is the agent pass's warning
/// (`agent_skills::warn_uninstalled`). An agent that will not read or
/// parse loads nothing; the renderer reports it.
///
/// The assignment is what the agent loads, not what it needs to install,
/// so its edge is soft: it never decides a skill's revision and never
/// keeps a skill from installing. Which of these skills it brings is
/// [`select_assignments`]'s choice, and [`wanted_by`] drops the findings
/// on those it does bring.
fn agent_assignment(
    catalog: &OpenCatalog,
    manifest: &Manifest,
    agent: &str,
    path: &std::path::Path,
) -> Vec<String> {
    let offered = list_items(&catalog.sealed, &catalog.config, ItemKind::Skill);
    match crate::mapping::declared_skills(manifest, agent) {
        Some((declared, _)) => declared
            .iter()
            .filter(|skill| offered.contains(skill))
            .cloned()
            .collect(),
        None => {
            let Ok(Some(text)) = catalog.sealed.read_if_exists(path) else {
                return Vec::new();
            };
            let Ok(parsed) = crate::render::agent::parse_source_agent(&text) else {
                return Vec::new();
            };
            crate::mapping::upstream_skills(agent, parsed.role, &catalog.config, &offered)
        }
    }
}

/// One item [`assignment_graph`] reads: its kind and name, and the
/// catalog it would be read from.
type Placed = (ItemKind, String, CatalogKey);

/// One edge of [`AssignmentGraph`], from the first item to the second.
type Edge = (Placed, Placed);

/// What the agents a requirement reached could bring through their
/// assignments, and everything that would bring with it.
#[derive(Default)]
struct AssignmentGraph {
    /// The agents a requirement reached, each where the scope holds it.
    roots: Vec<Placed>,
    /// Each assignment edge: an agent to a skill it loads.
    soft: BTreeSet<Edge>,
    /// Each requirement edge: a skill to a skill or an agent it requires.
    hard: BTreeSet<Edge>,
    /// Each requirement of an item the scope already holds, which keeps
    /// its own revision: the requirer, and the item it requires.
    crossings: BTreeSet<(Placed, Node)>,
}

/// From each of `agents`, which a requirement reached, the skills its
/// assignment names, what those require, and the assignments of the
/// agents they require, every item read where it would be read if it
/// were brought: at the catalog of whatever reaches it. An item the scope
/// already holds is not entered, since what it requires is already
/// walked; a requirement of one is recorded as a crossing. Reads only
/// catalogs the walk opened, since every item here is read at an agent's
/// catalog, and decides nothing.
fn assignment_graph(
    manifest: &Manifest,
    expansion: &Expansion,
    catalogs: &Catalogs,
    agents: &VecDeque<Node>,
) -> AssignmentGraph {
    let roots: Vec<Placed> = agents
        .iter()
        .filter_map(|(kind, name)| {
            let decl = expansion.decl_of(*kind, name)?;
            Some((*kind, name.clone(), (decl.source, decl.rev)))
        })
        .collect();
    let manifest_file = crate::manifest::manifest_file_name(catalogs.env, catalogs.scope);
    let mut graph = AssignmentGraph {
        roots: roots.clone(),
        ..AssignmentGraph::default()
    };
    let mut seen: BTreeSet<Placed> = roots.iter().cloned().collect();
    let mut queue: VecDeque<Placed> = roots.into();
    while let Some(node) = queue.pop_front() {
        let (kind, name, key) = &node;
        let Offer::Item(catalog, path) = catalogs.offer(key, *kind, name) else {
            continue;
        };
        // What the walk reports of these names, it reports once it walks
        // them.
        let mut said = Vec::new();
        let (soft, targets): (bool, Vec<(ItemKind, String)>) = match kind {
            ItemKind::Agent => (
                true,
                agent_assignment(catalog, manifest, name, &path)
                    .into_iter()
                    .map(|skill| (ItemKind::Skill, skill))
                    .collect(),
            ),
            ItemKind::Skill => {
                let Ok(declared) = declared_dependencies(&catalog.sealed, *kind, &path) else {
                    continue;
                };
                let chosen =
                    chosen_extras(&manifest_file, *kind, name, manifest, &declared, &mut said);
                let targets = DEPENDENT_KINDS
                    .iter()
                    .filter(|(parent_kind, _)| parent_kind == kind)
                    .flat_map(|(_, dep_kind)| {
                        names_required(&declared, &chosen, *kind, *dep_kind)
                            .map(|dep| (*dep_kind, dep.clone()))
                            .collect::<Vec<_>>()
                    })
                    .filter_map(|(dep_kind, dep)| {
                        resolve(*kind, dep_kind, &dep, name, catalog, &key.0, &mut said)
                            .map(|dep| (dep_kind, dep))
                    })
                    .collect();
                (false, targets)
            }
            ItemKind::Hook
            | ItemKind::Command
            | ItemKind::McpServer
            | ItemKind::Plugin
            | ItemKind::PiExtension
            | ItemKind::OutputStyle => {
                unreachable!("only agents and the skills they bring enter the assignment graph")
            }
        };
        for (dep_kind, dep) in targets {
            if expansion.contains(dep_kind, &dep) {
                if !soft {
                    graph.crossings.insert((node.clone(), (dep_kind, dep)));
                }
                continue;
            }
            let target: Placed = (dep_kind, dep, key.clone());
            let edges = match soft {
                true => &mut graph.soft,
                false => &mut graph.hard,
            };
            edges.insert((node.clone(), target.clone()));
            if seen.insert(target.clone()) {
                queue.push_back(target);
            }
        }
    }
    graph
}

/// Of the assignment edges in `graph`, those kept, as the skills each
/// agent brings, and a warning for each item two assignments want at two
/// revisions with no requirement deciding which.
///
/// A soft edge never decides a revision and never keeps a skill from
/// installing. Each round drops the edges that would break that, with
/// everything only they bring, under the first of three rules that finds
/// any:
///
/// 1. An item an edge brings requires a held item at another revision.
///    The requirements alone decided that revision, and the agent warns
///    that it lacks the skill.
/// 2. An edge brings an item only assignments reach, and a requirement
///    brings the same item at another revision.
/// 3. Two revisions of one item are left and nothing settles which. Every
///    edge bringing either goes, with the warning.
///
/// Selection ends at a round that drops nothing, and every round before
/// it drops an edge, so it ends.
fn select_assignments(
    graph: &AssignmentGraph,
    expansion: &Expansion,
    state: &DesiredState,
) -> (BTreeMap<String, BTreeSet<String>>, Vec<ItemWarning>) {
    let mut kept: BTreeSet<&Edge> = graph.soft.iter().collect();
    let mut warnings = Vec::new();
    loop {
        let live = Live::of(graph, &kept);
        let dropped = live
            .held_elsewhere(graph, expansion, state)
            .or_else(|| live.outranked(state))
            .or_else(|| live.contested(state, &mut warnings));
        let Some(dropped) = dropped else {
            break;
        };
        kept.retain(|edge| !dropped.contains(edge));
    }
    let live = Live::of(graph, &kept);
    let mut brings: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for ((_, agent, _), (_, skill, _)) in kept.iter().filter(|(from, _)| live.nodes.contains(from))
    {
        brings
            .entry(agent.clone())
            .or_default()
            .insert(skill.clone());
    }
    (brings, warnings)
}

/// What one round of [`select_assignments`] reads: the items the kept
/// assignment edges and every requirement reach from the agents.
struct Live<'g> {
    nodes: BTreeSet<&'g Placed>,
    kept: Vec<&'g Edge>,
    hard: Vec<&'g Edge>,
}

impl<'g> Live<'g> {
    fn of(graph: &'g AssignmentGraph, kept: &BTreeSet<&'g Edge>) -> Self {
        let mut nodes: BTreeSet<&Placed> = graph.roots.iter().collect();
        let mut queue: VecDeque<&Placed> = graph.roots.iter().collect();
        while let Some(node) = queue.pop_front() {
            let next = kept
                .iter()
                .copied()
                .chain(&graph.hard)
                .filter(|(from, _)| from == node)
                .map(|(_, to)| to);
            for to in next {
                if nodes.insert(to) {
                    queue.push_back(to);
                }
            }
        }
        let reached = |edges: Vec<&'g Edge>| -> Vec<&'g Edge> {
            edges
                .into_iter()
                .filter(|(from, _)| nodes.contains(from))
                .collect()
        };
        Self {
            kept: reached(kept.iter().copied().collect()),
            hard: reached(graph.hard.iter().collect()),
            nodes,
        }
    }

    /// Every item `from` reaches over live edges, itself included.
    fn reach(&self, from: &'g Placed) -> BTreeSet<&'g Placed> {
        let mut seen = BTreeSet::from([from]);
        let mut queue = VecDeque::from([from]);
        while let Some(node) = queue.pop_front() {
            for (_, to) in self
                .kept
                .iter()
                .chain(&self.hard)
                .filter(|(at, _)| at == node)
            {
                if seen.insert(to) {
                    queue.push_back(to);
                }
            }
        }
        seen
    }

    /// Whether a requirement brings `node`: one enters the knot of items
    /// that reach each other `node` sits in from outside it. Inside the
    /// knot every requirement goes round to an assignment that brought
    /// the knot, so it decides nothing.
    fn required(&self, node: &'g Placed) -> bool {
        let reach = self.reach(node);
        let knot: BTreeSet<&Placed> = reach
            .iter()
            .copied()
            .filter(|other| self.reach(other).contains(node))
            .collect();
        self.hard
            .iter()
            .any(|(from, to)| knot.contains(to) && !knot.contains(from))
    }

    /// The kept assignment edges that bring `node`: those whose skill
    /// requires it, at any depth, or is it.
    fn bringing(&self, node: &'g Placed) -> BTreeSet<&'g Edge> {
        let mut below = BTreeSet::from([node]);
        let mut queue = VecDeque::from([node]);
        while let Some(at) = queue.pop_front() {
            for (from, _) in self.hard.iter().filter(|(_, to)| to == at) {
                if below.insert(from) {
                    queue.push_back(from);
                }
            }
        }
        self.kept
            .iter()
            .copied()
            .filter(|(_, to)| below.contains(to))
            .collect()
    }

    /// The live items by kind, name and source: each group the items one
    /// name could install as.
    fn by_name(&self) -> BTreeMap<(ItemKind, &'g str, &'g str), Vec<&'g Placed>> {
        let mut named: BTreeMap<_, Vec<&Placed>> = BTreeMap::new();
        for node in &self.nodes {
            let (kind, name, (source, _)) = node;
            named
                .entry((*kind, name.as_str(), source.as_str()))
                .or_default()
                .push(*node);
        }
        named
    }

    /// The edges bringing an item that requires a held item at another
    /// revision than the scope holds it at.
    fn held_elsewhere(
        &self,
        graph: &AssignmentGraph,
        expansion: &Expansion,
        state: &DesiredState,
    ) -> Option<BTreeSet<&'g Edge>> {
        let mut dropped = BTreeSet::new();
        for (node, (kind, name)) in &graph.crossings {
            let Some(node) = self.nodes.get(node).copied() else {
                continue;
            };
            let Some(held) = expansion.decl_of(*kind, name) else {
                unreachable!("{name} is a crossing because the scope holds it");
            };
            let (source, rev) = &node.2;
            if held.source == *source
                && Expansion::revisions_differ(state, source, held.rev.as_deref(), rev.as_deref())
            {
                dropped.extend(self.bringing(node));
            }
        }
        (!dropped.is_empty()).then_some(dropped)
    }

    /// The edges bringing an item only assignments reach, where a
    /// requirement brings the same item at another revision and every
    /// requirement agrees on it.
    fn outranked(&self, state: &DesiredState) -> Option<BTreeSet<&'g Edge>> {
        let mut dropped = BTreeSet::new();
        for ((_, _, source), nodes) in self.by_name() {
            let (required, assigned): (Vec<&Placed>, Vec<&Placed>) =
                nodes.into_iter().partition(|node| self.required(node));
            let rev = |node: &Placed| node.2.1.clone();
            let Some(decided) = required.first() else {
                continue;
            };
            let differ = |one: &Placed, other: &Placed| {
                Expansion::revisions_differ(
                    state,
                    source,
                    rev(one).as_deref(),
                    rev(other).as_deref(),
                )
            };
            if required.iter().any(|other| differ(decided, other)) {
                continue;
            }
            for node in assigned.into_iter().filter(|node| differ(decided, node)) {
                dropped.extend(self.bringing(node));
            }
        }
        (!dropped.is_empty()).then_some(dropped)
    }

    /// The edges bringing any revision of an item wanted at two with
    /// nothing settling which, each such item warned on.
    fn contested(
        &self,
        state: &DesiredState,
        warnings: &mut Vec<ItemWarning>,
    ) -> Option<BTreeSet<&'g Edge>> {
        let mut dropped = BTreeSet::new();
        for ((kind, name, source), nodes) in self.by_name() {
            let revs: BTreeSet<Option<&str>> = nodes
                .iter()
                .map(|(_, _, (_, rev))| rev.as_deref())
                .collect();
            let first = revs.first().copied().flatten();
            if !revs
                .iter()
                .any(|rev| Expansion::revisions_differ(state, source, first, *rev))
            {
                continue;
            }
            for node in nodes {
                dropped.extend(self.bringing(node));
            }
            let shown: Vec<String> = revs.into_iter().map(shown_rev).collect();
            warnings.push(ItemWarning {
                kind,
                name: name.to_owned(),
                harness: None,
                message: format!(
                    "kendex-agent-skill-contested: {}={}\nAgents' assignments want it at {}, and no requirement settles which, so none of them brings it.",
                    kind.name(),
                    crate::names::shown(name),
                    shown.join(" and "),
                ),
                remediation: Some(format!(
                    "pin the items that bring those agents in to the same revision, or declare {}",
                    crate::names::shown(name),
                )),
                detail: None,
            });
        }
        (!dropped.is_empty()).then_some(dropped)
    }
}

/// Of `harnesses`, the tools the plan writes the hook's position on
/// ([`not_written`]), parked or held included, which is where its
/// companions are needed ([`wanted_by`]).
fn written_on(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &DesiredState,
    (kind, parent): (ItemKind, &str),
    own: &HookSpec,
    harnesses: &[HarnessId],
) -> Vec<HarnessId> {
    harnesses
        .iter()
        .copied()
        .filter(|harness| {
            let answer = not_written(
                env,
                scope,
                manifest,
                state,
                kind,
                parent,
                Ok(Some(own)),
                *harness,
            );
            !matches!(
                answer,
                Some(
                    NotWritten::KeptRemoved
                        | NotWritten::OtherTools
                        | NotWritten::OwnHarnessesLine { .. }
                        | NotWritten::Undeliverable(_)
                )
            )
        })
        .collect()
}

/// Hook companions use the requirement's harnesses; skill edges use all of them.
fn dependency_harnesses(
    kind: ItemKind,
    harnesses: &[HarnessId],
    requires_on: Option<&[String]>,
) -> Vec<HarnessId> {
    harnesses
        .iter()
        .copied()
        .filter(|harness| {
            kind != ItemKind::Hook
                || requires_on.is_none_or(|names| {
                    names
                        .iter()
                        .any(|name| HarnessId::parse(name) == Some(*harness))
                })
        })
        .collect()
}

/// The optional dependencies the manifest chose for this parent, each
/// checked against what the parent offers. `[optional-dependencies.<skill>]`
/// is the manifest's one table of chosen extras, so a hook has nothing to
/// choose from.
fn chosen_extras(
    manifest_file: &str,
    kind: ItemKind,
    parent: &str,
    manifest: &Manifest,
    declared: &Dependencies,
    found: &mut Vec<ItemWarning>,
) -> Vec<String> {
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
        | ItemKind::PiExtension
        | ItemKind::OutputStyle => Vec::new(),
    };
    for name in chosen.iter().filter(|c| !declared.optional.contains(c)) {
        found.push(warn(
            kind,
            parent,
            format!("{name} was chosen as an optional dependency, and {parent} does not offer one by that name"),
            format!("remove {name} from optional-dependencies.{parent} in {manifest_file}"),
        ));
    }
    chosen
}

/// Each resolved companion derived from the catalog the plan writes it
/// from ([`Catalogs::offer`]), onto `wanted`: the companions that land,
/// and for an armed hook the tools it is withheld from — every tool a
/// companion misses, or every tool where the companion's catalog says
/// nothing of it ([`silent`]).
#[allow(clippy::too_many_arguments)]
fn derive(
    kind: ItemKind,
    parent: &str,
    harnesses: &[HarnessId],
    requires_on: Option<&[String]>,
    companions: Vec<(ItemKind, String, CatalogKey)>,
    manifest: &Manifest,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
    wanted: &mut Wanted,
) {
    let (env, scope) = (catalogs.env, catalogs.scope);
    let manifest_file = crate::manifest::manifest_file_name(env, scope);
    let withholds = kind == ItemKind::Hook && wanted.armed;
    // Every companion's catalog is opened before any is read, since an
    // open may move what is already open.
    for (_, _, key) in &companions {
        catalogs.get(&key.0, key.1.as_deref(), state);
    }
    for (dep_kind, dep, key) in companions {
        let harnesses = dependency_harnesses(dep_kind, harnesses, requires_on);
        let source = key.0.as_str();
        let found = &mut wanted.findings;
        let because = match catalogs.offer(&key, dep_kind, &dep) {
            Offer::Item(catalog, path) => {
                let landed = companion(
                    env,
                    scope,
                    kind,
                    dep_kind,
                    dep,
                    parent,
                    &harnesses,
                    wanted.armed,
                    manifest,
                    state,
                    catalog,
                    &path,
                    source,
                    wanted,
                );
                wanted.deps.push(landed);
                continue;
            }
            // Retired, the companion is never written again, so an armed
            // hook is withheld on these `harnesses` rather than armed beside
            // a copy kept only until the next prune; the rule is
            // docs/authoring/README.md's `[retired]` paragraph. The fix is
            // the consumer's: the catalog's own is to drop the line. Whether
            // the retired copy is still there for the hook is its own
            // verdict's to say (`removal::settle_lacking`).
            Offer::Retired(migration) => {
                state.retire(dep_kind, &dep, source, migration, false);
                // Named as data, not a command line (engine.md rule 18):
                // the remove verb drops a declaration nothing installed.
                let fix = match manifest.declared(kind).contains_key(parent) {
                    true => {
                        let place = match scope {
                            Scope::Global => ", global scope",
                            Scope::Project { .. } => "",
                        };
                        format!(
                            "drop {parent} with the remove verb, kind {}{place}",
                            kind.name()
                        )
                    }
                    false => format!("drop what brings {parent} in from {manifest_file}"),
                };
                wanted.answered.push(warn(
                    kind,
                    parent,
                    format!("{parent} requires {dep}, which the catalog '{source}' retired"),
                    match migration.is_empty() {
                        true => format!(
                            "{fix}, or wait for the catalog '{source}' to drop {dep} from what {parent} requires"
                        ),
                        false => migration.to_owned(),
                    },
                ));
                if withholds {
                    let companion = (dep_kind, dep.clone());
                    wanted.withhold_for(harnesses, Withholding::Retired, &companion);
                }
                continue;
            }
            Offer::NotOffered => {
                found.push(warn(
                    kind,
                    parent,
                    format!(
                        "{parent} requires {dep}, which is set to come from the catalog '{source}', and that catalog does not offer it"
                    ),
                    format!(
                        "add {dep} to that catalog, or declare {dep} from a catalog that offers it"
                    ),
                ));
                Withholding::Requires
            }
            Offer::Silent => silent(
                &manifest_file,
                kind,
                dep_kind,
                &dep,
                parent,
                &harnesses,
                wanted.armed,
                manifest,
                source,
                found,
            ),
        };
        if withholds {
            wanted.withhold(harnesses.iter().copied(), because);
        }
    }
}

/// A companion whose catalog says nothing of it this pass. What the
/// manifest alone says holds without a catalog: kept removed or switched
/// off (`desired_kinds::manifest_refusal`, the answers the one answer
/// gives before anything a catalog decides), the companion is missing, as
/// a finding on the parent, except that a parent switched off itself
/// misses nothing in a companion switched off too. Otherwise nothing says
/// whether the companion would run: the finding names the catalog's
/// silence, and the parent is withheld for it and nothing of it taken.
#[allow(clippy::too_many_arguments)]
fn silent(
    manifest_file: &str,
    kind: ItemKind,
    dep_kind: ItemKind,
    dep: &str,
    parent: &str,
    harnesses: &[HarnessId],
    armed: bool,
    manifest: &Manifest,
    source: &str,
    found: &mut Vec<ItemWarning>,
) -> Withholding {
    match manifest_refusal(manifest, dep_kind, dep) {
        Some(reason) => {
            let quiet = reason == NotWritten::SwitchedOff && !armed;
            if !quiet {
                found.push(finding(
                    manifest_file,
                    &reason,
                    kind,
                    dep_kind,
                    parent,
                    dep,
                    harnesses,
                    source,
                ));
            }
            Withholding::Requires
        }
        None => {
            found.push(warn(
                kind,
                parent,
                format!(
                    "{parent} requires {dep}, which is set to come from the catalog '{source}', and that catalog cannot be read"
                ),
                format!(
                    "settle the note on the catalog '{source}', or declare {dep} from a catalog that reads"
                ),
            ));
            Withholding::Unanswered
        }
    }
}

/// One resolved companion, offered at `path` by `catalog`, the one the
/// plan writes it from, taken to the tools it runs on beside its parent.
/// These tools already respect the requiring hook's `requires-on` line.
/// A companion's own harness exclusions also limit where it is needed.
/// Every other refusal is a
/// finding and withholds an armed requiring hook on the affected tools.
#[allow(clippy::too_many_arguments)]
fn companion(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    dep_kind: ItemKind,
    dep: String,
    parent: &str,
    harnesses: &[HarnessId],
    armed: bool,
    manifest: &Manifest,
    state: &DesiredState,
    catalog: &OpenCatalog,
    path: &std::path::Path,
    source: &str,
    wanted: &mut Wanted,
) -> Dep {
    let header = hook_header(&catalog.sealed, dep_kind, path);
    let mut on = Vec::new();
    let mut refused: BTreeMap<NotWritten, Vec<HarnessId>> = BTreeMap::new();
    for harness in harnesses {
        // A companion excluded by its own header has no job here.
        // User opt-outs still reach the planner's refusal below.
        if header
            .as_ref()
            .ok()
            .and_then(Option::as_ref)
            .is_some_and(|own| !own.applies_to(*harness))
        {
            continue;
        }
        let answer = not_written(
            env,
            scope,
            manifest,
            state,
            dep_kind,
            &dep,
            header.as_ref().map(Option::as_ref).map_err(String::as_str),
            *harness,
        );
        match answer {
            None => on.push(*harness),
            Some(reason) => refused
                .entry(reason.for_requirer(state, kind, parent, *harness))
                .or_default()
                .push(*harness),
        }
    }
    for (reason, tools) in refused {
        // A parent that is off arms nothing, so a companion switched off
        // beside it is missing nowhere and says nothing.
        let quiet = reason == NotWritten::SwitchedOff && !armed;
        if !quiet {
            wanted.findings.push(finding(
                &crate::manifest::manifest_file_name(env, scope),
                &reason,
                kind,
                dep_kind,
                parent,
                &dep,
                &tools,
                source,
            ));
        }
        if kind == ItemKind::Hook && armed {
            wanted.withhold(tools, reason.withholding());
        }
    }
    Dep {
        kind: dep_kind,
        name: dep,
        on,
        source: source.to_owned(),
        header: header.ok().flatten(),
    }
}

/// The finding on a parent for a companion that will not run on `tools`,
/// one sentence per reason `not_written` gives, and the remedy beside it.
#[allow(clippy::too_many_arguments)]
fn finding(
    manifest_file: &str,
    reason: &NotWritten,
    kind: ItemKind,
    dep_kind: ItemKind,
    parent: &str,
    dep: &str,
    tools: &[HarnessId],
    source: &str,
) -> ItemWarning {
    let verb = runs(tools);
    let tools = named(tools);
    let (message, remediation) = match reason {
        NotWritten::KeptRemoved => (
            format!("missing required dependency: {parent} requires {dep}, which is kept removed"),
            format!(
                "add the {} {dep} again to restore it, or drop it from {parent}'s dependencies",
                dep_kind.name()
            ),
        ),
        NotWritten::SwitchedOff => (
            format!("missing required dependency: {parent} requires {dep}, which is switched off"),
            format!(
                "set enabled = true on {dep}'s declaration in {manifest_file}, or drop it from {parent}'s dependencies"
            ),
        ),
        NotWritten::UnreadableHeader(problem) => (
            format!(
                "missing required dependency: {parent} requires {dep}, whose header cannot be read: {problem}"
            ),
            format!(
                "repair {dep}'s header in the catalog '{source}', or drop it from {parent}'s dependencies"
            ),
        ),
        NotWritten::OtherTools => (
            format!(
                "missing required dependency: {tools} {} {parent} without {dep}, which it requires",
                verb
            ),
            format!("declare {dep} for {tools} too"),
        ),
        NotWritten::Withheld => (
            format!(
                "missing required dependency: {parent} requires {dep}, which is withheld from {tools}"
            ),
            format!("settle the finding on {dep}"),
        ),
        NotWritten::OwnHarnessesLine { .. } => (
            format!(
                "missing required dependency: {tools} {} {parent} without {dep}, whose own harnesses line leaves {tools} out",
                verb
            ),
            format!(
                "add {tools} to {dep}'s harnesses line in the catalog, or list {parent}'s harnesses in {manifest_file} without {tools}"
            ),
        ),
        NotWritten::Undeliverable(reason) => (
            format!(
                "missing required dependency: {tools} {} {parent} without {dep}, which cannot be delivered there: {reason}",
                verb
            ),
            format!(
                "make {dep} deliverable on {tools}, or list {parent}'s harnesses in {manifest_file} without {tools}"
            ),
        ),
        NotWritten::RevConflict => (
            format!(
                "missing required dependency: {parent} requires {dep}, which is wanted at two revisions"
            ),
            format!("pin the items that bring {dep} in to the same revision, or unpin them"),
        ),
        NotWritten::HeldRevConflict => (
            format!(
                "{parent} is held with its required companion {dep}, which stays installed on {tools} under a revision conflict"
            ),
            format!("pin the items that bring {dep} in to the same revision, or unpin them"),
        ),
    };
    warn(kind, parent, message, remediation)
}

/// Every requirer has been walked, so what the loop could not know yet is
/// settled: the revision each companion is wanted at, and so which one is
/// wanted at two and written at neither. A recorded companion still runs;
/// its requirers stay beside it. Asked once more of the one answer, for
/// every tool a companion was counted on.
fn settle_after_walk(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &DesiredState,
    wanted: &mut BTreeMap<Node, Wanted>,
) {
    for ((kind, parent), found) in wanted.iter_mut() {
        if *kind != ItemKind::Hook || !found.armed {
            continue;
        }
        let mut settled = Vec::new();
        for dep in &found.deps {
            let mut refused: BTreeMap<NotWritten, Vec<HarnessId>> = BTreeMap::new();
            for harness in &dep.on {
                let answer = not_written(
                    env,
                    scope,
                    manifest,
                    state,
                    dep.kind,
                    &dep.name,
                    Ok(dep.header.as_ref()),
                    *harness,
                );
                if let Some(reason) = answer {
                    refused
                        .entry(reason.for_requirer(state, *kind, parent, *harness))
                        .or_default()
                        .push(*harness);
                }
            }
            settled.push((refused, dep.kind, dep.name.clone(), dep.source.clone()));
        }
        for (refused, dep_kind, dep, source) in settled {
            for (reason, tools) in refused {
                found.withhold(tools.iter().copied(), reason.withholding());
                found.findings.push(finding(
                    &crate::manifest::manifest_file_name(env, scope),
                    &reason,
                    *kind,
                    dep_kind,
                    parent,
                    &dep,
                    &tools,
                    &source,
                ));
            }
        }
    }
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
fn resolve(
    kind: ItemKind,
    dep_kind: ItemKind,
    name: &str,
    parent: &str,
    catalog: &OpenCatalog,
    source: &str,
    found: &mut Vec<ItemWarning>,
) -> Option<String> {
    let resolved = match catalog.offer(dep_kind, name) {
        // A retired name is the catalog's own answer, carried or not.
        Offer::Item(..) | Offer::Retired(_) => Ok(name.to_owned()),
        Offer::NotOffered | Offer::Silent if dep_kind == ItemKind::Skill => {
            (catalog.offered).resolve(&catalog.sealed, &catalog.config, name)
        }
        Offer::NotOffered | Offer::Silent => Err(Vec::new()),
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
        detail: None,
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
