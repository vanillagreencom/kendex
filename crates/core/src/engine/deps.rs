//! Required and selected optional dependencies stay within one catalog: a
//! skill's from its SKILL.md, a hook's from its header. Derived install
//! reasons preserve the manifest as a record of user choices.

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
use super::desired::{DesiredState, Withheld, Withholding};
use super::desired_kinds::{NotWritten, not_written};
use super::expansion::{CatalogKey, Catalogs, Expansion, OpenCatalog};

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
                grew |= expansion.add(kind, dep, &decl, *harness, Reason::RequiredBy { by });
            }
            if grew {
                queue.push_back((kind, dep.clone()));
            }
        }
        wanted.insert((kind, parent.clone()), found);
    }
    // The revision each item is wanted at is known only now, once every
    // requirer has added its reason, and the walk must read it before
    // withholding spreads.
    expansion.report_rev_disagreements(state);
    settle_after_walk(catalogs.env, catalogs.scope, manifest, state, &mut wanted);
    withhold_requirers(&mut wanted, expansion);
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
                .map(|dep| (*kind, dep.name.clone()))
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
    record(wanted, state);
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
        state
            .withheld
            .extend(found.withheld.into_iter().map(|(harness, because)| {
                (
                    (kind, name.clone(), harness),
                    Withheld {
                        provenance: found.provenance.clone(),
                        because,
                    },
                )
            }));
    }
}

/// What one parent's declarations came to: the companions it derives, each
/// with the tools it lands on; the findings on the parent; and the tools
/// the parent itself is withheld from, with why, because a hook whose
/// companion will not be written there is not written there either.
struct Wanted {
    deps: Vec<Dep>,
    findings: Vec<ItemWarning>,
    withheld: BTreeMap<HarnessId, Withholding>,
    /// The provenance the parent's declaration is planned under, carried
    /// with a withholding for invariant 4's judgement of an installed copy.
    provenance: String,
    /// Whether the parent is switched on: only a hook that would run is
    /// withheld, since one that is off arms nothing beside a missing judge.
    armed: bool,
}

impl Wanted {
    /// Withhold the parent from `tools` for this reason. A missing
    /// companion outranks being orphaned: the first says the copy comes out
    /// whatever the options, and a tool already held for it stays so.
    fn withhold(&mut self, tools: impl IntoIterator<Item = HarnessId>, because: Withholding) {
        for tool in tools {
            match because {
                Withholding::Requires => {
                    self.withheld.insert(tool, because);
                }
                Withholding::Orphaned => {
                    self.withheld.entry(tool).or_insert(because);
                }
            }
        }
    }
}

/// One companion a parent derives: the tools it runs on beside the parent;
/// the catalog the plan writes it from, by the name a finding repairs it
/// under; and its header as that catalog holds it, for the question asked
/// again once the walk is complete ([`settle_after_walk`]).
struct Dep {
    name: String,
    on: Vec<HarnessId>,
    source: String,
    header: Option<HookSpec>,
}

/// One more withholding the loop found, and the finding that explains it.
enum Spread {
    /// A companion the hook requires, read from the catalog `source`, is
    /// withheld from these tools.
    Requires {
        dep: String,
        source: String,
        tools: Vec<HarnessId>,
    },
    /// Every hook that requires this derived companion is withheld from
    /// these tools, and nothing asks for it by name.
    Orphaned {
        requirers: BTreeSet<String>,
        tools: Vec<HarnessId>,
    },
}

/// A hook withheld from a tool is not written there, so a hook that
/// requires it is withheld there too, and so is a companion that exists
/// only for hooks withheld there — until nothing changes: the lane-mail
/// knot goes together whichever member's fault it is, and a one-way edge
/// leaves no companion armed beside a requirer that is gone. Skills are not
/// in this: a skill runs without what it lacks, and its finding is the
/// whole consequence.
fn withhold_requirers(wanted: &mut BTreeMap<Node, Wanted>, expansion: &Expansion) {
    loop {
        let mut spread: Vec<(Node, Spread)> = Vec::new();
        for ((kind, parent), found) in wanted.iter() {
            if *kind != ItemKind::Hook || !found.armed {
                continue;
            }
            for Dep {
                name: dep,
                on,
                source,
                ..
            } in &found.deps
            {
                let Some(theirs) = wanted.get(&(*kind, dep.clone())) else {
                    continue;
                };
                let tools: Vec<HarnessId> = on
                    .iter()
                    .copied()
                    .filter(|h| theirs.withheld.contains_key(h) && !found.withheld.contains_key(h))
                    .collect();
                if !tools.is_empty() {
                    spread.push((
                        (*kind, parent.clone()),
                        Spread::Requires {
                            dep: dep.clone(),
                            source: source.clone(),
                            tools,
                        },
                    ));
                }
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
                spread.push((
                    (*kind, parent.clone()),
                    Spread::Orphaned { requirers, tools },
                ));
            }
        }
        if spread.is_empty() {
            return;
        }
        for ((kind, parent), more) in spread {
            let Some(found) = wanted.get_mut(&(kind, parent.clone())) else {
                unreachable!("{parent} was read from this map a moment ago");
            };
            let warning = match more {
                Spread::Requires { dep, source, tools } => {
                    found.withhold(tools.iter().copied(), Withholding::Requires);
                    finding(&NotWritten::Withheld, kind, &parent, &dep, &tools, &source)
                }
                Spread::Orphaned { requirers, tools } => {
                    found.withhold(tools.iter().copied(), Withholding::Orphaned);
                    orphaned_finding(kind, &parent, &requirers, &tools)
                }
            };
            found.findings.push(warning);
        }
    }
}

/// Whether this hook is wanted on `harness` only by hooks withheld from it:
/// every reason for its installation there is a requirer that is withheld,
/// and none is the person asking for it or a set carrying it. The
/// requirers found are added to `requirers`, for the finding.
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
                && theirs.is_some_and(|theirs| theirs.withheld.contains_key(&by.harness));
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
    let OpenCatalog {
        sealed,
        config,
        offered,
        provenance,
    } = catalogs.get(&own.0, own.1.as_deref(), state)?;
    let mut wanted = Wanted {
        deps: Vec::new(),
        findings: Vec::new(),
        withheld: BTreeMap::new(),
        provenance: provenance.clone(),
        armed: parent_decl.enabled,
    };
    let Some(dir) = find_item(sealed, config, kind, parent) else {
        return Some(wanted);
    };
    let Ok(declared) = declared_dependencies(sealed, kind, &dir) else {
        return Some(wanted);
    };
    // A companion is needed where the parent runs, and nowhere else: a
    // tool the plan writes no parent on is a tool the companion is not
    // missing from, and one it would be derived on for a parent that is
    // not there. The same answer the planner takes, so the two agree on
    // where the parent runs. Off and wanted-at-two-revisions are the
    // exceptions the planner makes too: both still write the parent's
    // position, parked or held, and its companions follow it there.
    let harnesses: Vec<HarnessId> = match hook_header(sealed, kind, &dir) {
        Ok(Some(own)) => harnesses
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
                    Ok(Some(&own)),
                    *harness,
                );
                !matches!(
                    answer,
                    Some(
                        NotWritten::KeptRemoved
                            | NotWritten::OtherTools
                            | NotWritten::OwnHarnessesLine
                            | NotWritten::Undeliverable(_)
                    )
                )
            })
            .collect(),
        Ok(None) | Err(_) => harnesses.to_vec(),
    };
    let found = &mut wanted.findings;
    let chosen = chosen_extras(kind, parent, manifest, &declared, found);
    // Each name taken to the companion it names, and that companion to
    // the catalog the plan writes it from. A name that resolves to nothing
    // derives nothing, which withholds an armed hook everywhere.
    let mut companions: Vec<(String, CatalogKey)> = Vec::new();
    let mut unresolved = false;
    for name in declared
        .required
        .iter()
        .chain(declared.optional.iter().filter(|o| chosen.contains(o)))
    {
        match resolve(kind, name, parent, sealed, config, offered, &own.0, found) {
            Some(dep) => {
                let planned = expansion
                    .decl_of(kind, &dep)
                    .unwrap_or_else(|| derived_decl(parent_decl));
                companions.push((dep, (planned.source, planned.rev)));
            }
            None => unresolved = true,
        }
    }
    if unresolved && kind == ItemKind::Hook && wanted.armed {
        wanted.withhold(harnesses.iter().copied(), Withholding::Requires);
    }
    derive(
        kind,
        parent,
        &harnesses,
        companions,
        manifest,
        catalogs,
        state,
        &mut wanted,
    );
    Some(wanted)
}

/// The optional dependencies the manifest chose for this parent, each
/// checked against what the parent offers. `[optional-dependencies.<skill>]`
/// is the manifest's one table of chosen extras, so a hook has nothing to
/// choose from.
fn chosen_extras(
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
    chosen
}

/// Each resolved companion derived from the catalog the plan writes it
/// from, onto `wanted`: the companions that land, and for an armed hook the
/// tools it is withheld from, which are every tool a companion misses. A
/// companion whose catalog will not open this pass is a finding and
/// nothing more: a catalog that cannot be read never uninstalls a working
/// artifact, as one that carries both hooks does not.
#[allow(clippy::too_many_arguments)]
fn derive(
    kind: ItemKind,
    parent: &str,
    harnesses: &[HarnessId],
    companions: Vec<(String, CatalogKey)>,
    manifest: &Manifest,
    catalogs: &mut Catalogs,
    state: &mut DesiredState,
    wanted: &mut Wanted,
) {
    let (env, scope) = (catalogs.env, catalogs.scope);
    let withholds = kind == ItemKind::Hook && wanted.armed;
    // Every companion's catalog is opened before any is read, since an
    // open may move what is already open.
    for (_, key) in &companions {
        catalogs.get(&key.0, key.1.as_deref(), state);
    }
    for (dep, key) in companions {
        let Some(catalog) = catalogs.opened(&key) else {
            // The declaration naming that catalog has reported why.
            wanted.findings.push(warn(
                kind,
                parent,
                format!(
                    "{parent} requires {dep}, which is set to come from the catalog '{}', and that catalog cannot be read",
                    key.0
                ),
                format!(
                    "settle the note on the catalog '{}', or declare {dep} from a catalog that reads",
                    key.0
                ),
            ));
            continue;
        };
        let lands = companion(
            env,
            scope,
            kind,
            dep,
            parent,
            harnesses,
            wanted.armed,
            manifest,
            state,
            catalog,
            &key.0,
            &mut wanted.findings,
        );
        if withholds {
            let on = lands.as_ref().map(|dep| dep.on.as_slice()).unwrap_or(&[]);
            wanted.withhold(
                harnesses.iter().copied().filter(|h| !on.contains(h)),
                Withholding::Requires,
            );
        }
        if let Some(landed) = lands {
            wanted.deps.push(landed);
        }
    }
}

/// One resolved companion, taken to the tools it runs on beside its
/// parent, read from `catalog`, the one the plan writes it from. `None`
/// where nothing is derived: that catalog does not offer the name, or the
/// name is an item the manifest keeps removed or switched off, or a hook
/// whose header will not read — each a finding on the parent, except that
/// a parent switched off itself misses nothing in a companion switched off
/// too. Every tool the companion will not run on is a finding on the
/// parent as well, in the words of the one answer the planner gives
/// (`desired_kinds::not_written`); what the finding then costs the parent
/// is [`wanted_by`]'s to decide.
#[allow(clippy::too_many_arguments)]
fn companion(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    dep: String,
    parent: &str,
    harnesses: &[HarnessId],
    armed: bool,
    manifest: &Manifest,
    state: &DesiredState,
    catalog: &OpenCatalog,
    source: &str,
    found: &mut Vec<ItemWarning>,
) -> Option<Dep> {
    let Some(path) = find_item(&catalog.sealed, &catalog.config, kind, &dep) else {
        found.push(warn(
            kind,
            parent,
            format!(
                "{parent} requires {dep}, which is set to come from the catalog '{source}', and that catalog does not offer it"
            ),
            format!("add {dep} to that catalog, or declare {dep} from a catalog that offers it"),
        ));
        return None;
    };
    let header = hook_header(&catalog.sealed, kind, &path);
    let mut on = Vec::new();
    let mut refused: BTreeMap<NotWritten, Vec<HarnessId>> = BTreeMap::new();
    for harness in harnesses {
        let answer = not_written(
            env,
            scope,
            manifest,
            state,
            kind,
            &dep,
            header.as_ref().map(Option::as_ref).map_err(String::as_str),
            *harness,
        );
        match answer {
            None => on.push(*harness),
            Some(reason) => refused.entry(reason).or_default().push(*harness),
        }
    }
    // The reasons that hold on every tool decide whether the companion is
    // derived at all; the rest name the tools it misses.
    for (reason, tools) in refused {
        let whole = matches!(
            reason,
            NotWritten::KeptRemoved | NotWritten::SwitchedOff | NotWritten::UnreadableHeader(_)
        );
        // A parent that is off arms nothing, so a companion switched off
        // beside it is missing nowhere and says nothing.
        let quiet = reason == NotWritten::SwitchedOff && !armed;
        if !quiet {
            found.push(finding(&reason, kind, parent, &dep, &tools, source));
        }
        if whole {
            return None;
        }
    }
    Some(Dep {
        name: dep,
        on,
        source: source.to_owned(),
        header: header.ok().flatten(),
    })
}

/// The finding on a parent for a companion that will not run on `tools`,
/// one sentence per reason `not_written` gives, and the remedy beside it.
fn finding(
    reason: &NotWritten,
    kind: ItemKind,
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
                kind.name()
            ),
        ),
        NotWritten::SwitchedOff => (
            format!("missing required dependency: {parent} requires {dep}, which is switched off"),
            format!(
                "set enabled = true on {dep}'s declaration in kendex.toml, or drop it from {parent}'s dependencies"
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
        NotWritten::OwnHarnessesLine => (
            format!(
                "missing required dependency: {tools} {} {parent} without {dep}, whose own harnesses line leaves {tools} out",
                verb
            ),
            format!(
                "add {tools} to {dep}'s harnesses line in the catalog, or list {parent}'s harnesses in kendex.toml without {tools}"
            ),
        ),
        NotWritten::Undeliverable(reason) => (
            format!(
                "missing required dependency: {tools} {} {parent} without {dep}, which cannot be delivered there: {reason}",
                verb
            ),
            format!(
                "make {dep} deliverable on {tools}, or list {parent}'s harnesses in kendex.toml without {tools}"
            ),
        ),
        NotWritten::RevConflict => (
            format!(
                "missing required dependency: {parent} requires {dep}, which is wanted at two revisions"
            ),
            format!("pin the items that bring {dep} in to the same revision, or unpin them"),
        ),
    };
    warn(kind, parent, message, remediation)
}

/// Every requirer has been walked, so what the loop could not know yet is
/// settled: the revision each companion is wanted at, and so which one is
/// wanted at two and written at neither. Asked once more of the one answer,
/// for every tool a companion was counted on.
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
        let mut settled: Vec<(BTreeMap<NotWritten, Vec<HarnessId>>, String, String)> = Vec::new();
        for dep in &found.deps {
            let mut refused: BTreeMap<NotWritten, Vec<HarnessId>> = BTreeMap::new();
            for harness in &dep.on {
                let answer = not_written(
                    env,
                    scope,
                    manifest,
                    state,
                    *kind,
                    &dep.name,
                    Ok(dep.header.as_ref()),
                    *harness,
                );
                if let Some(reason) = answer {
                    refused.entry(reason).or_default().push(*harness);
                }
            }
            settled.push((refused, dep.name.clone(), dep.source.clone()));
        }
        for (refused, dep, source) in settled {
            for (reason, tools) in refused {
                found.withhold(tools.iter().copied(), Withholding::Requires);
                found
                    .findings
                    .push(finding(&reason, *kind, parent, &dep, &tools, &source));
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
