use std::collections::{BTreeMap, BTreeSet};

use crate::apply::{Op, PlannedOp};

use super::{Disowned, DroppedDeclaration, EngineReport, PlanOptions, plan_scope};
use crate::env::Env;
use crate::error::{ProvenanceStep, Result};
use crate::lock::{InstallRef, Lock, LockEntry, Reason, RequirerProvenance, lock_path};
use crate::manifest::{self, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

mod add;
pub use add::{AddRequest, add, add_seeded, manifest_for_request, requested_kinds, targets_for};
pub(crate) use add::{PreparedAddition, protect_installed, source_repo_label};

/// Every kind a manifest declares by name. Plugins are excluded: they carry
/// only an enabled flag, in their own table.
const DECLARED_KINDS: [ItemKind; 7] = [
    ItemKind::Agent,
    ItemKind::Skill,
    ItemKind::Hook,
    ItemKind::Command,
    ItemKind::McpServer,
    ItemKind::PiExtension,
    ItemKind::OutputStyle,
];

/// The tools on this machine a fresh manifest should install to — a tool
/// kendex can only read is detected and listed, never seeded as a target
/// whose every install would silently do nothing.
pub fn detected_harnesses(env: &Env) -> Vec<HarnessId> {
    crate::harness::all_adapters()
        .iter()
        .filter_map(|a| {
            a.detect(env, &a.default_global_root(env))
                .map(|found| found.harness)
        })
        .filter(|harness| crate::harness::installable(*harness))
        .collect()
}

/// The tools an install that leaves the choice to the scope lands on: the
/// scope's `[install].harnesses` as written, or the tools on this machine
/// where the scope declares none, which is what its next write records.
/// What the terminal picker and the app's picker check before anyone
/// touches them, so an untouched picker and `--yes` install to one set.
pub fn install_defaults(env: &Env, scope: &Scope) -> Result<Vec<HarnessId>> {
    let mut manifest = manifest_for_reading(env, scope)?;
    settle_defaults(env, scope, &mut manifest);
    Ok(manifest.install.harnesses)
}

/// Give a manifest that declares no tools the ones on this machine, and
/// name each tool on this machine a declared list leaves out.
///
/// A list the person wrote is never widened: a tool added to it would take
/// every package in the scope, which nobody asked for on this run. An
/// empty list declares nothing, the same as a manifest not written yet,
/// so it takes what [`manifest_for_mutation`] seeds an absent one with.
pub(crate) fn settle_defaults(env: &Env, scope: &Scope, manifest: &mut Manifest) -> Option<String> {
    let detected = detected_harnesses(env);
    if manifest.install.harnesses.is_empty() {
        manifest.install.harnesses = detected;
        return None;
    }
    let left_out: Vec<&str> = detected
        .iter()
        .filter(|harness| !manifest.install.harnesses.contains(harness))
        .map(|harness| harness.display_name())
        .collect();
    let (verb, them) = match left_out.len() {
        0 => return None,
        1 => ("is", "it"),
        _ => ("are", "them"),
    };
    Some(format!(
        "{} {verb} on this machine and not in [install].harnesses; name {them} with --harness or add {them} to {}",
        left_out.join(", "),
        manifest::manifest_file_name(env, scope),
    ))
}

/// The scope's manifest as a listing reads it: the file where there is
/// one, else what [`manifest_for_mutation`] would write first. One answer
/// to what an absent manifest holds, so a page can never offer a
/// subscription the next write already carries. Legacy files are a hard
/// error.
pub fn manifest_for_reading(env: &Env, scope: &Scope) -> Result<Manifest> {
    Ok(
        manifest::load_current(&manifest::manifest_path(env, scope))?
            .unwrap_or_else(|| absent(env, scope)),
    )
}

/// Load the scope's manifest for mutation, seeding a fresh one when none
/// exists. Legacy files are a hard error.
pub fn manifest_for_mutation(env: &Env, scope: &Scope) -> Result<Manifest> {
    Ok(
        manifest::load_for_mutation(&manifest::manifest_path(env, scope))?
            .unwrap_or_else(|| absent(env, scope)),
    )
}

/// What an absent manifest holds, for reading and for the first write
/// alike. The seed is applied to an absent file only: a default the
/// person removed from a file that exists is never put back.
fn absent(env: &Env, scope: &Scope) -> Manifest {
    manifest::seed(scope, &detected_harnesses(env))
}

/// Drop declarations and plan the removal of exactly those items. A removal
/// is durable: an item something else still requires is written down as
/// suppressed rather than re-derived on the next plan, and every item that
/// requires it says so in the audit instead of quietly getting it back.
/// `sweep` also removes what nothing needs anymore — the dependencies whose
/// last dependent is going away.
///
/// A name that is an installed bundle removes the set: its members go with
/// it, except the ones the user also asked for, that a surviving item needs,
/// or that another installed bundle carries too.
/// Remove by name. `kind` narrows the removal to one declaration — the
/// page that knows what it is looking at passes it, so a skill and an
/// agent sharing a name never go down together. `None` keeps the CLI's
/// bare-name semantics: the name goes wherever it is declared.
pub fn remove(
    env: &Env,
    scope: &Scope,
    names: &[String],
    kind: Option<ItemKind>,
    sweep: bool,
) -> Result<EngineReport> {
    prepare_remove(env, scope, names, kind, sweep)?.plan(env)
}

/// Take these items' installations away and keep their declarations. The
/// files come off disk and the record forgets them, exactly as `remove`
/// would, but kendex.toml is not touched — the next refresh installs them
/// again from their source. This is the remedy for an install that went
/// wrong, and what the manifest says is what makes it a remedy rather than
/// a removal. Never a sweep: what these items pull in is wanted again the
/// moment they are.
pub fn uninstall(env: &Env, scope: &Scope, names: &[String]) -> Result<EngineReport> {
    prepare_uninstall(env, scope, names)?.plan(env)
}

/// Prepare the same removal inputs both the compatibility pass and plan
/// consume. No rendering or installation write occurs during preparation.
pub fn prepare_remove(
    env: &Env,
    scope: &Scope,
    names: &[String],
    kind: Option<ItemKind>,
    sweep: bool,
) -> Result<PreparedRemoval> {
    prepare_removal(env, scope, names, kind, sweep, true)
}

/// Prepare an uninstall with its declarations omitted from the reading,
/// while retaining the original manifest for the next refresh.
pub fn prepare_uninstall(env: &Env, scope: &Scope, names: &[String]) -> Result<PreparedRemoval> {
    prepare_removal(env, scope, names, None, false, false)
}

/// One removal's post-change declaration, record and reading options.
/// Private fields prevent a caller from reconstructing another selection
/// between the command-wide compatibility pass and its plan.
pub struct PreparedRemoval {
    scope: Scope,
    manifest: Manifest,
    original: Manifest,
    lock: Lock,
    names: Vec<String>,
    options: PlanOptions,
    disown: bool,
}

impl PreparedRemoval {
    pub fn check_catalog_compatibility(&self, env: &Env) -> Result<()> {
        crate::source::check_catalog_compatibility(env, &self.scope, &self.manifest)?;
        super::desired::hold::held_planning(
            env,
            &self.scope,
            &self.manifest,
            &self.lock,
            &self.options,
        )?;
        Ok(())
    }

    pub fn plan(&self, env: &Env) -> Result<EngineReport> {
        self.plan_with_options(env, &self.options)
    }

    /// Answering the sweep prompt changes orphan removal only. The
    /// captured manifest and recorded readings remain the checked inputs.
    /// An uninstall keeps its dependencies for the next refresh.
    pub fn plan_sweeping(&self, env: &Env) -> Result<EngineReport> {
        let options = PlanOptions {
            sweep_unneeded: self.disown,
            ..self.options.clone()
        };
        self.plan_with_options(env, &options)
    }

    fn plan_with_options(&self, env: &Env, options: &PlanOptions) -> Result<EngineReport> {
        let mut report = plan_scope(env, &self.scope, &self.manifest, &self.lock, options)?;
        match self.disown {
            true => {
                report.notes.extend(unreadable_origins(
                    env,
                    &self.scope,
                    &self.manifest,
                    &self.lock,
                    &self.names,
                    options,
                ));
                // An unchanged manifest is no removal. Creating one in a
                // previously absent scope would declare a new install.
                if self.manifest != self.original {
                    ensure_manifest_persisted(env, &self.scope, &self.manifest, &mut report)?;
                    report.disowned = Some(disowned(&self.original, &self.manifest, &self.names));
                }
            }
            false => report
                .plan
                .ops
                .retain(|op| !matches!(op.op, Op::WriteManifest { .. })),
        }
        Ok(report)
    }
}

/// The declaration edit both verbs share. Their plans omit the same
/// declarations; `disown` decides whether the edited manifest is saved.
fn prepare_removal(
    env: &Env,
    scope: &Scope,
    names: &[String],
    kind: Option<ItemKind>,
    sweep: bool,
    disown: bool,
) -> Result<PreparedRemoval> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let held = manifest.clone();
    let lock = crate::lock::load(&lock_path(env, scope))?;
    let bundles: Vec<String> = names
        .iter()
        .filter(|name| kind.is_none() && manifest.bundles.contains_key(*name))
        .cloned()
        .collect();
    let mut removing: Vec<super::report_types::RemovalName> =
        names.iter().map(|name| (kind, name.clone())).collect();
    removing.extend(
        super::bundles::recorded_members(&lock, &bundles)
            .into_iter()
            .map(|name| (None, name)),
    );
    // Held at the record: a removal names what goes, and a package it does
    // not name re-rendered at a newer catalog commit is an update nobody
    // asked for.
    let options = PlanOptions {
        remove_orphans: true,
        removal_filter: Some(removing),
        sweep_unneeded: sweep,
        uninstalled_bundles: bundles,
        hold_upstream_skills: !disown,
        ..PlanOptions::locked()
    };
    for name in names {
        // Plugin has no declared-items table — it lives in `plugins` and
        // is removed there, never through `declared_mut` (which panics on
        // it). A bare-name removal reaches both.
        if matches!(kind, Some(ItemKind::Plugin)) {
            manifest.plugins.remove(name);
            continue;
        }
        let kinds: Vec<ItemKind> = match kind {
            Some(kind) => vec![kind],
            None => DECLARED_KINDS.to_vec(),
        };
        if kind.is_none() {
            manifest.bundles.remove(name);
            manifest.plugins.remove(name);
        }
        // An empty table goes only where this removal emptied it: one the
        // file already held empty is no change of the removal's.
        for kind in &kinds {
            manifest.declared_mut(*kind).remove(name);
            if let Some(forks) = manifest.forks.get_mut(kind)
                && forks.remove(name).is_some()
                && forks.is_empty()
            {
                manifest.forks.remove(kind);
            }
        }
        if kinds.contains(&ItemKind::Plugin) {
            manifest.plugins.remove(name);
        }
        // A reviewer agent reads its base agent's skill list by prefix, so
        // the entry outlives the agent while the declaration is kept:
        // surviving agents render from the file that stays.
        if disown && kinds.contains(&ItemKind::Agent) {
            manifest.agent_skills.remove(name);
        }
        if kinds.contains(&ItemKind::Skill) {
            manifest.skill_instructions.remove(name);
            manifest.optional_dependencies.remove(name);
            // Taking an item away also un-takes it wherever it was chosen
            // as an optional extra: that choice is the whole reason it
            // would return.
            manifest.optional_dependencies.retain(|_, taken| {
                let chose = taken.contains(name);
                taken.retain(|chosen| chosen != name);
                !(chose && taken.is_empty())
            });
        }
    }
    for (kind, name) in kept_removed(env, scope, &manifest, &lock, names, kind, &options)? {
        manifest.suppress(kind, &name);
    }
    Ok(PreparedRemoval {
        scope: scope.clone(),
        manifest,
        original: held,
        lock,
        names: names.to_vec(),
        options,
        disown,
    })
}

/// What `manifest` changes from `held` that names an item: the
/// declarations of these names it no longer makes, and the suppressions it
/// adds.
fn disowned(held: &Manifest, manifest: &Manifest, names: &[String]) -> Disowned {
    let mut dropped = Vec::new();
    for name in names {
        if held.bundles.contains_key(name) && !manifest.bundles.contains_key(name) {
            dropped.push(DroppedDeclaration::Bundle { name: name.clone() });
        }
        if held.plugins.contains_key(name) && !manifest.plugins.contains_key(name) {
            dropped.push(DroppedDeclaration::Item {
                kind: ItemKind::Plugin,
                name: name.clone(),
            });
        }
        for kind in DECLARED_KINDS {
            if held.declared(kind).contains_key(name) && !manifest.declared(kind).contains_key(name)
            {
                dropped.push(DroppedDeclaration::Item {
                    kind,
                    name: name.clone(),
                });
            }
        }
    }
    let suppressed = manifest
        .suppressed
        .iter()
        .flat_map(|(kind, names)| names.iter().map(|name| (*kind, name.clone())))
        .filter(|(kind, name)| !held.is_suppressed(*kind, name))
        .collect();
    Disowned {
        dropped,
        suppressed,
    }
}

/// Which of these names something that stays would pull straight back in,
/// and as what: a dependency of a skill that stays, or a member of a bundle
/// that is still installed. Those are the removals that have to be written
/// down, or the next plan would simply undo them.
///
/// One walk answers it over two sets of facts: the record, which costs no
/// catalog, and the catalogs read now over the edited manifest, which see a
/// carrier or an edge added since the last install and survive a deleted
/// record. A rooted path in any reading keeps the removal: an older reading
/// can cost a suppression the next add clears, but never drops one.
/// Otherwise an ancestor no recorded reading holds reasons for refuses,
/// because the catalog cannot prove it gone and guessing could make the
/// removal return. So does an installation a local edit holds, or whose
/// every reading sits in a record marked held, and no reading roots,
/// unless the read now accounted for every declaration: its reasons may
/// predate a carrier the catalog gained, which only that read sees. That
/// refusal names what the read could not account for, since the read is
/// of each catalog where it sits now, which an apply at the recorded
/// revisions does not see. Where no reading roots an installation and the
/// read was short, the name test [`recorded_edges`] decides, since that
/// read cannot see a carrier the record does not hold.
fn kept_removed(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    names: &[String],
    kind: Option<ItemKind>,
    options: &PlanOptions,
) -> Result<BTreeSet<(ItemKind, String)>> {
    let ReadAncestry {
        installations,
        bundles,
        unread,
    } = read_ancestry(env, scope, manifest);
    let captured = captured_rows(lock);
    let roots = |facts| RemovalRoots {
        env,
        scope,
        manifest,
        lock,
        names,
        kind,
        options,
        facts,
        read_bundles: &bundles,
    };
    let mut decisions = BTreeMap::new();
    roots(Facts::Recorded(&captured)).decide(&mut decisions);
    roots(Facts::Read(&installations)).decide(&mut decisions);
    let named = unread
        .is_some()
        .then(|| recorded_edges(lock, names, options));
    let mut kept = BTreeSet::new();
    for (key, decision) in decisions {
        match decision {
            Reach::Rooted => {
                kept.insert(key);
            }
            Reach::Unrooted => {
                if named.as_ref().is_some_and(|named| named.contains(&key)) {
                    kept.insert(key);
                }
            }
            // Read whole, the catalogs decide: had they rooted it, the
            // root would have won.
            Reach::Missing(Unread::Held(_)) if unread.is_none() => {}
            Reach::Missing(Unread::Held(by)) => {
                let unread = unread.unwrap_or_default();
                return Err(provenance_missing(
                    by,
                    ProvenanceStep::RetryReadable { unread },
                ));
            }
            Reach::Missing(Unread::Ancestor { ancestor, held }) => {
                let step = match held {
                    Some(held) => ProvenanceStep::ResolveEdit(held),
                    None => ProvenanceStep::Apply,
                };
                return Err(provenance_missing(ancestor, step));
            }
            Reach::Missing(Unread::Set(set)) => {
                return Err(crate::error::CoreError::RemovalSetReadingMissing {
                    catalog: set.source,
                    set: set.name,
                });
            }
        }
    }
    Ok(kept)
}

/// The selected installations whose record names an edge from something
/// not going away: a requirer not named for removal, or a set not being
/// uninstalled. A short read cannot see a carrier declared since the last
/// readable apply, or a hold that kept a record whose installation went
/// unread, so where no reading roots an installation this name test keeps
/// the removal rather than lose it.
fn recorded_edges(
    lock: &Lock,
    names: &[String],
    options: &PlanOptions,
) -> BTreeSet<(ItemKind, String)> {
    lock.entries
        .values()
        .filter(|entry| {
            names.contains(&entry.name) && options.named_for_removal(entry.kind, &entry.name)
        })
        .filter(|entry| {
            entry.reasons.iter().any(|reason| match reason {
                Reason::Requested => false,
                Reason::RequiredBy { by } => !options.named_for_removal(by.kind, &by.name),
                Reason::MemberOf { bundle } => !options.uninstalled_bundles.contains(&bundle.name),
            })
        })
        .map(|entry| (entry.kind, entry.name.clone()))
        .collect()
}

fn provenance_missing(by: InstallRef, step: ProvenanceStep) -> crate::error::CoreError {
    crate::error::CoreError::RemovalProvenanceMissing {
        catalog: by.source,
        kind: by.kind,
        name: by.name,
        harness: by.harness,
        step,
    }
}

struct ReadAncestry {
    installations: BTreeMap<InstallRef, RequirerProvenance>,
    bundles: BTreeSet<crate::lock::BundleRef>,
    unread: Option<Vec<String>>,
}

/// Every installation the catalogs derive now from the edited manifest,
/// with its per-tool reasons, read under the identity each source is
/// declared at, and, where the read did not account for every
/// declaration, each cause it met.
fn read_ancestry(env: &Env, scope: &Scope, manifest: &Manifest) -> ReadAncestry {
    let mut state = crate::engine::desired::DesiredState::default();
    let expansion = super::expansion::expand(env, scope, manifest, None, &mut state);
    let read = super::expansion::PLANNED_KINDS
        .into_iter()
        .flat_map(|kind| {
            expansion
                .of(kind)
                .into_iter()
                .filter_map(move |(name, planned)| {
                    let repo = crate::source::declared_provenance(manifest, &planned.decl.source)?;
                    Some(((kind, name.clone()), repo))
                })
        })
        .collect();
    // A read that cannot account for every declaration, a catalog, item or
    // set it could not read or a dependency it could not satisfy, says
    // nothing of what would root an installation once it can. Each cause
    // is named where the expansion meets it, those the declaration status
    // counts among them; the expansion refuses no declaration, which only
    // the item passes do.
    let complete = super::DeclarationStatus::of(&state) == super::DeclarationStatus::Complete;
    debug_assert!(
        complete || !state.short_reads.is_empty(),
        "an incomplete removal read names no cause"
    );
    let unread = (!complete || !state.short_reads.is_empty())
        .then(|| state.short_reads.into_iter().collect());
    ReadAncestry {
        installations: expansion.requirer_provenance(&read),
        bundles: state.read_bundles,
        unread,
    }
}

enum Reach {
    Rooted,
    Unrooted,
    Missing(Unread),
}

/// The fact a refusal names.
enum Unread {
    /// An ancestor the record holds no reasons for, and the record whose
    /// edge named it where a local edit holds that record, so no apply
    /// writes the missing row into it.
    Ancestor {
        ancestor: InstallRef,
        held: Option<InstallRef>,
    },
    /// A set whose reading the record does not bind to the member's edge.
    Set(crate::lock::BundleRef),
    /// An installation no reading roots, resting on a record a hold keeps,
    /// which this names: its own entry while a local edit holds it, or one
    /// of the records holding its readings where each is marked held. The
    /// catalogs read whole decide it.
    Held(InstallRef),
}

impl Reach {
    /// Rooted, then a refusal no read lifts, then one a whole read does.
    fn rank(&self) -> u8 {
        match self {
            Self::Unrooted => 0,
            Self::Missing(Unread::Held(_)) => 1,
            Self::Missing(Unread::Ancestor { .. } | Unread::Set(_)) => 2,
            Self::Rooted => 3,
        }
    }

    /// The higher-ranked answer; on a tie, `self`.
    fn or(self, other: Self) -> Self {
        if other.rank() > self.rank() {
            other
        } else {
            self
        }
    }
}

/// Where the walk reads an installation's reasons on one tool.
enum Facts<'a> {
    /// Every recorded reading of an installation: its own entry and each
    /// dependent's captured row. Each reading's reasons come from its own
    /// snapshot, and every step reads every recorded reading of the next
    /// ancestor, wherever the walk arrived from. Nothing in the lock says
    /// which of two readings is newer, so each is walked once and a root in
    /// any of them counts; none vetoes another. An entry a local edit holds
    /// keeps its reasons from before the hold, and a row beside it may be
    /// as old, so such an installation roots or refuses and is never
    /// proved free; so does one whose every reading sits in a record
    /// marked held, the edit perhaps since undone by hand.
    Recorded(&'a Captured<'a>),
    /// What the catalogs derive now ([`read_ancestry`]). An installation
    /// they do not derive has no carrier.
    Read(&'a BTreeMap<InstallRef, RequirerProvenance>),
}

/// Every dependent's captured row, by the installation it reads.
type Captured<'l> = BTreeMap<&'l InstallRef, Vec<(&'l LockEntry, &'l RequirerProvenance)>>;

fn captured_rows(lock: &Lock) -> Captured<'_> {
    let mut rows = Captured::new();
    for dependent in lock.entries.values() {
        for row in dependent.requirer_rows() {
            rows.entry(&row.installation)
                .or_default()
                .push((dependent, row));
        }
    }
    rows
}

/// One reading of an installation, and who recorded it.
struct Reading<'f> {
    recorder: Recorder<'f>,
    repo: &'f str,
    reasons: &'f BTreeSet<Reason>,
}

/// Who recorded a reading. An entry's own reading and a row its own
/// snapshot captures for it, in a cycle, are two readings with the same
/// entry behind them, and either can root it.
#[derive(Clone, Copy)]
enum Recorder<'f> {
    /// The catalogs read now.
    Read,
    /// The installation's own entry.
    Entry(&'f LockEntry),
    /// A dependent's snapshot.
    Row(&'f LockEntry),
}

impl<'f> Recorder<'f> {
    /// The snapshot an ancestor no reading holds falls back to for the
    /// identity it would be read under.
    fn context(self) -> Option<&'f LockEntry> {
        match self {
            Self::Read => None,
            Self::Entry(entry) | Self::Row(entry) => Some(entry),
        }
    }

    /// The record behind this reading where a hold kept it as it was
    /// ([`crate::lock::RequirerAncestry::held`]).
    fn kept_as_was(self) -> Option<&'f LockEntry> {
        match self {
            Self::Read => None,
            Self::Entry(entry) | Self::Row(entry) => entry.held_reading().then_some(entry),
        }
    }

    /// With the installation read, names exactly one reading: an
    /// installation has one entry and a snapshot one row per ancestor.
    fn visit(self) -> Visit {
        match self {
            Self::Read => Visit::Read,
            Self::Entry(_) => Visit::Entry,
            Self::Row(dependent) => Visit::Row(install_ref(dependent)),
        }
    }
}

/// What the facts hold for an installation.
enum Readings<'f> {
    /// Each walked once, on its own reasons. Read now, an installation the
    /// catalogs do not derive has none, and so no carrier.
    Of(Vec<Reading<'f>>),
    /// No recorded reading holds a row for it, so only a declaration under
    /// the identity the record would read it at can still root it.
    Unrecorded { identity: Option<&'f str> },
}

/// [`Recorder`], owned, for the visited set.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
enum Visit {
    Read,
    Entry,
    Row(InstallRef),
}

/// The readings already walked, each by its recorder and the installation
/// it reads.
type Visited = BTreeSet<(Visit, InstallRef)>;

/// The single decision of whether a surviving declaration or set still
/// roots an installation once the selected items leave.
struct RemovalRoots<'a> {
    env: &'a Env,
    scope: &'a Scope,
    manifest: &'a Manifest,
    lock: &'a Lock,
    names: &'a [String],
    kind: Option<ItemKind>,
    options: &'a PlanOptions,
    facts: Facts<'a>,
    read_bundles: &'a BTreeSet<crate::lock::BundleRef>,
}

impl RemovalRoots<'_> {
    /// Selected for removal, and so a name a kept removal is written for.
    fn selected(&self, node: &InstallRef) -> bool {
        self.names.contains(&node.name) && self.options.named_for_removal(node.kind, &node.name)
    }

    /// Named outright, so it keeps nothing it requires. Bundle members in
    /// `removal_filter` were selected through their set; an independent
    /// declaration or another set can still root them.
    fn explicit(&self, node: &InstallRef) -> bool {
        self.names.contains(&node.name) && self.kind.is_none_or(|kind| kind == node.kind)
    }

    fn same_source(&self, source: &str, repo: &str) -> bool {
        crate::source::declared_provenance(self.manifest, source).as_deref() == Some(repo)
    }

    /// The entry recorded for exactly this installation, source included.
    fn entry(&self, by: &InstallRef) -> Option<&LockEntry> {
        self.lock
            .entries
            .get(&crate::lock::entry_key(by.kind, &by.name, by.harness))
            .filter(|entry| entry.source == by.source)
    }

    fn decide(&self, decisions: &mut BTreeMap<(ItemKind, String), Reach>) {
        let nodes: BTreeSet<InstallRef> = match self.facts {
            Facts::Read(read) => read.keys().cloned().collect(),
            // Every installation the record names: entries, captured rows,
            // and the ancestors their edges name, which may have neither.
            Facts::Recorded(captured) => captured
                .keys()
                .map(|node| (*node).clone())
                .chain(self.lock.entries.values().flat_map(|entry| {
                    let edges = entry
                        .reasons
                        .iter()
                        .chain(entry.requirer_rows().iter().flat_map(|row| &row.reasons));
                    std::iter::once(install_ref(entry)).chain(edges.filter_map(
                        |reason| match reason {
                            Reason::RequiredBy { by } => Some(by.clone()),
                            Reason::Requested | Reason::MemberOf { .. } => None,
                        },
                    ))
                }))
                .collect(),
        };
        // A selected node is walked as any ancestor is, but never cut as
        // explicit; its declaration has already left the edited manifest.
        for node in nodes.iter().filter(|node| self.selected(node)) {
            let reach = self.walk(None, node, &mut Visited::new());
            let key = (node.kind, node.name.clone());
            let reach = match decisions.remove(&key) {
                Some(old) => old.or(reach),
                None => reach,
            };
            decisions.insert(key, reach);
        }
    }

    fn reasons(
        &self,
        context: Option<&LockEntry>,
        node: &InstallRef,
        repo: &str,
        reasons: &BTreeSet<Reason>,
        visited: &mut Visited,
    ) -> Reach {
        let mut found = Reach::Unrooted;
        for reason in reasons {
            let next = match reason {
                Reason::Requested => Reach::Unrooted,
                Reason::MemberOf { bundle } => self.member(node, repo, bundle),
                Reason::RequiredBy { by } => self.installation(context, by, visited),
            };
            found = found.or(next);
            if matches!(found, Reach::Rooted) {
                break;
            }
        }
        found
    }

    /// A set roots its member only while the manifest still installs it on
    /// the member's tool from the catalog it was read from. Two readings
    /// bind the set's catalog to this edge: the member's own, when it was
    /// read from the set's source, and the set's record. Either one that
    /// matches roots it. With neither, a successful live set read lets the
    /// live ancestry decide; without that read, its membership is unknown.
    fn member(&self, node: &InstallRef, repo: &str, bundle: &crate::lock::BundleRef) -> Reach {
        let installs = self.manifest.bundles.get(&bundle.name).is_some_and(|decl| {
            decl.source == bundle.source
                && super::desired::target_harnesses(decl, self.manifest, node.kind, self.scope)
                    .contains(&node.harness)
        });
        if !installs {
            return Reach::Unrooted;
        }
        let readings = match self.facts {
            Facts::Read(_) => crate::source::declared_provenance(self.manifest, &bundle.source)
                .into_iter()
                .collect::<Vec<_>>(),
            Facts::Recorded(_) => (node.source == bundle.source)
                .then(|| repo.to_owned())
                .into_iter()
                .chain(
                    self.lock
                        .bundles
                        .get(&bundle.name)
                        .filter(|set| set.source == bundle.source)
                        .map(|set| set.source_repo.clone()),
                )
                .collect(),
        };
        if readings.is_empty() {
            if self.read_bundles.contains(bundle) {
                Reach::Unrooted
            } else {
                Reach::Missing(Unread::Set(bundle.clone()))
            }
        } else if readings
            .iter()
            .any(|read_under| self.same_source(&bundle.source, read_under))
        {
            Reach::Rooted
        } else {
            Reach::Unrooted
        }
    }

    fn installation(
        &self,
        context: Option<&LockEntry>,
        by: &InstallRef,
        visited: &mut Visited,
    ) -> Reach {
        if self.explicit(by) {
            return Reach::Unrooted;
        }
        self.walk(context, by, visited)
    }

    /// Whether any reading of `by` roots it, each walked once. `context`
    /// is the snapshot whose edge led here, which only an unrecorded `by`
    /// reads.
    fn walk(&self, context: Option<&LockEntry>, by: &InstallRef, visited: &mut Visited) -> Reach {
        let readings = match self.readings(context, by) {
            Readings::Of(readings) => readings,
            Readings::Unrecorded { identity } => {
                return if identity.is_some_and(|repo| self.declared(by, repo)) {
                    Reach::Rooted
                } else {
                    Reach::Missing(Unread::Ancestor {
                        ancestor: by.clone(),
                        held: context
                            .filter(|record| {
                                super::removal::edit_holds(self.env, self.scope, record)
                            })
                            .map(install_ref),
                    })
                };
            }
        };
        let entry = readings.iter().find_map(|reading| match reading.recorder {
            Recorder::Entry(entry) => Some(entry),
            Recorder::Read | Recorder::Row(_) => None,
        });
        // A hold kept every reading as it was, so none can say what the
        // catalogs' newer reading would root.
        let kept = readings
            .iter()
            .map(|reading| reading.recorder.kept_as_was())
            .collect::<Option<Vec<_>>>()
            .and_then(|kept| kept.first().copied());
        let mut found = Reach::Unrooted;
        for reading in readings {
            let next = if self.declared(by, reading.repo) {
                Reach::Rooted
            } else if visited.insert((reading.recorder.visit(), by.clone())) {
                self.reasons(
                    reading.recorder.context(),
                    by,
                    reading.repo,
                    reading.reasons,
                    visited,
                )
            } else {
                Reach::Unrooted
            };
            found = found.or(next);
            if matches!(found, Reach::Rooted) {
                break;
            }
        }
        if !matches!(found, Reach::Unrooted) {
            return found;
        }
        // An edit on disk holds the entry even before an apply marks it.
        let edited = entry.filter(|entry| super::removal::edit_holds(self.env, self.scope, entry));
        match edited.or(kept) {
            Some(held) => Reach::Missing(Unread::Held(install_ref(held))),
            None => found,
        }
    }

    /// The one answer to which readings speak for an installation: read
    /// now, the catalogs' row; recorded, its own entry and every captured
    /// row for it, wherever the walk arrived from. A snapshot without a row
    /// gives no evidence while another holds one.
    fn readings<'f>(&'f self, context: Option<&'f LockEntry>, by: &InstallRef) -> Readings<'f> {
        let captured = match self.facts {
            Facts::Read(read) => {
                return Readings::Of(
                    read.get(by)
                        .map(|row| Reading {
                            recorder: Recorder::Read,
                            repo: &row.source_repo,
                            reasons: &row.reasons,
                        })
                        .into_iter()
                        .collect(),
                );
            }
            Facts::Recorded(captured) => captured,
        };
        let installed = self.entry(by).map(|entry| Reading {
            recorder: Recorder::Entry(entry),
            repo: &entry.source_repo,
            reasons: &entry.reasons,
        });
        let rows = captured
            .get(by)
            .into_iter()
            .flatten()
            .map(|(dependent, row)| Reading {
                recorder: Recorder::Row(dependent),
                repo: &row.source_repo,
                reasons: &row.reasons,
            });
        let readings: Vec<_> = installed.into_iter().chain(rows).collect();
        if !readings.is_empty() {
            return Readings::Of(readings);
        }
        // The identity it would be read under still proves a declaration.
        let identity = context
            .filter(|context| context.source == by.source)
            .map(|context| context.source_repo.as_str())
            .or_else(|| {
                self.lock
                    .sources
                    .get(&by.source)
                    .map(|source| source.repo.as_str())
            });
        Readings::Unrecorded { identity }
    }

    fn declared(&self, by: &InstallRef, repo: &str) -> bool {
        self.manifest
            .declared(by.kind)
            .get(&by.name)
            .is_some_and(|decl| {
                decl.source == by.source
                    && self.same_source(&by.source, repo)
                    && super::desired::target_harnesses(decl, self.manifest, by.kind, self.scope)
                        .contains(&by.harness)
            })
    }
}

fn install_ref(entry: &LockEntry) -> InstallRef {
    InstallRef {
        source: entry.source.clone(),
        kind: entry.kind,
        name: entry.name.clone(),
        harness: entry.harness,
    }
}

/// The catalogs behind what is going away that cannot be read right now.
/// What else still wants an item is written in its catalog, so an unreadable
/// one means the preview cannot show the whole consequence of the removal.
/// The removal itself stands either way — the record already says what has
/// to stay removed.
fn unreadable_origins(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    names: &[String],
    options: &PlanOptions,
) -> Vec<String> {
    let mut sources: Vec<String> = lock
        .entries
        .values()
        .filter(|entry| {
            names.contains(&entry.name) && options.named_for_removal(entry.kind, &entry.name)
        })
        .map(|entry| entry.source.clone())
        .collect();
    sources.sort();
    sources.dedup();
    sources
        .into_iter()
        .filter(|source| {
            !matches!(
                crate::source::resolve(env, scope, source, manifest),
                Ok(crate::source::SourceState::Ready(_))
            )
        })
        .map(|source| {
            format!(
                "the catalog '{source}' cannot be read right now, so this preview cannot show everything that still wants what is going — the removal stands, and what has to stay removed is recorded"
            )
        })
        .collect()
}

/// Flip declarations; disabling is non-destructive (invariant 5).
/// Toggle by name; `kind` narrows to one declaration, the same way and
/// for the same reason as [`remove`]. The app carries `observed` for native
/// rows so they cannot switch a same-named item from another source.
pub fn toggle(
    env: &Env,
    scope: &Scope,
    names: &[String],
    kind: Option<ItemKind>,
    enabled: bool,
    observed: Option<&crate::model::FileState>,
) -> Result<EngineReport> {
    let mut manifest = manifest_for_mutation(env, scope)?;
    let lock = crate::lock::load(&lock_path(env, scope))?;
    for name in names {
        let kinds: Vec<ItemKind> = match kind {
            Some(kind) => vec![kind],
            None => DECLARED_KINDS.to_vec(),
        };
        for kind in kinds {
            if kind == ItemKind::Plugin {
                if let Some(plugin) = manifest.plugins.get_mut(name) {
                    plugin.enabled = enabled;
                }
                continue;
            }
            if kind == ItemKind::McpServer && observed == Some(&crate::model::FileState::Builtin) {
                add::ensure_item_source(
                    env,
                    scope,
                    &manifest,
                    &lock,
                    kind,
                    name,
                    manifest::BUILTIN_SOURCE_NAME,
                )?;
            }
            if kind == ItemKind::McpServer
                && !manifest.mcp_servers.contains_key(name)
                && crate::harness::COPILOT_BUILTIN_MCPS.contains(&name.as_str())
                && (!enabled
                    || crate::harness::copilot::settings::disabled_mcps(env, scope)?
                        .iter()
                        .any(|off| off == name))
            {
                add::ensure_item_source(
                    env,
                    scope,
                    &manifest,
                    &lock,
                    kind,
                    name,
                    manifest::BUILTIN_SOURCE_NAME,
                )?;
                manifest.mcp_servers.entry(name.clone()).or_insert_with(|| {
                    let mut decl = manifest::ItemDecl::from_source(manifest::BUILTIN_SOURCE_NAME);
                    decl.harnesses = Some(vec![HarnessId::Copilot]);
                    decl
                });
            }
            if kind == ItemKind::PiExtension && manifest.pi_extensions.contains_key(name) {
                crate::pi_ext::ensure_toggle_ready(env, scope, &manifest, &lock, name)?;
            }
            if let Some(decl) = manifest.declared_mut(kind).get_mut(name) {
                decl.enabled = enabled;
            }
        }
        if kind.is_none()
            && let Some(plugin) = manifest.plugins.get_mut(name)
        {
            plugin.enabled = enabled;
        }
    }
    // Held at the record, as a removal is: a toggle names what switches,
    // and a package it does not name re-rendered at a newer catalog commit
    // is an update nobody asked for.
    let mut report = plan_scope(env, scope, &manifest, &lock, &PlanOptions::locked())?;
    ensure_manifest_persisted(env, scope, &manifest, &mut report)?;
    Ok(report)
}

/// The plan must persist the mutated manifest exactly once; plan_scope adds
/// its own write only when upstream skill merges changed it further.
pub(crate) fn ensure_manifest_persisted(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    report: &mut EngineReport,
) -> Result<()> {
    let already = crate::engine::persists_manifest(&report.plan.ops);
    if already {
        return Ok(());
    }
    insert_manifest_save(env, scope, &mut report.plan, manifest.clone(), None)
}

/// Insert the missing manifest write, bound to the caller's read when it
/// supplies a base, otherwise to the file now. It leads the plan: later
/// ops were planned against the manifest this write makes durable.
pub(crate) fn insert_manifest_save(
    env: &Env,
    scope: &Scope,
    plan: &mut crate::apply::Plan,
    manifest: Manifest,
    base: Option<&crate::base::Base>,
) -> Result<()> {
    let path = crate::manifest::manifest_path(env, scope);
    let file = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string());
    plan.insert(
        0,
        PlannedOp {
            description: format!("Save {file}").into(),
            op: Op::WriteManifest {
                pre: super::scope_writes::manifest_pre(base, &path)?,
                path,
                manifest: Box::new(manifest),
            },
        },
    )
}
