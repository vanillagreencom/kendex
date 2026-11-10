use std::collections::{BTreeMap, BTreeSet};

use crate::apply::{Op, PlannedOp};

use super::{Disowned, DroppedDeclaration, EngineReport, PlanOptions, plan_scope};
use crate::env::Env;
use crate::error::Result;
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
/// record. A rooted path in either keeps the removal. Otherwise an ancestor
/// the record holds no reasons for refuses, because the catalog cannot
/// prove it gone and guessing could make the removal return.
fn kept_removed(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    names: &[String],
    kind: Option<ItemKind>,
    options: &PlanOptions,
) -> Result<BTreeSet<(ItemKind, String)>> {
    let read = read_ancestry(env, scope, manifest);
    let roots = |facts| RemovalRoots {
        scope,
        manifest,
        lock,
        names,
        kind,
        options,
        facts,
    };
    let mut decisions = BTreeMap::new();
    roots(Facts::Recorded).decide(&mut decisions);
    roots(Facts::Read(&read)).decide(&mut decisions);
    let mut kept = BTreeSet::new();
    for (key, decision) in decisions {
        match decision {
            Reach::Rooted => {
                kept.insert(key);
            }
            Reach::Unrooted => {}
            Reach::Missing(Unread::Ancestor(by)) => {
                return Err(crate::error::CoreError::RemovalProvenanceMissing {
                    catalog: by.source,
                    kind: by.kind,
                    name: by.name,
                    harness: by.harness,
                });
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

/// Every installation the catalogs derive now from the edited manifest,
/// with its per-tool reasons, read under the identity each source is
/// declared at.
fn read_ancestry(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
) -> BTreeMap<InstallRef, RequirerProvenance> {
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
    expansion.requirer_provenance(&read)
}

enum Reach {
    Rooted,
    Unrooted,
    Missing(Unread),
}

/// The fact a refusal names: an ancestor the record holds no reasons for,
/// or a set whose reading the record does not bind to the member's edge.
enum Unread {
    Ancestor(InstallRef),
    Set(crate::lock::BundleRef),
}

impl Reach {
    fn or(self, other: Self) -> Self {
        match (self, other) {
            (Self::Rooted, _) | (_, Self::Rooted) => Self::Rooted,
            (missing @ Self::Missing(_), _) | (_, missing @ Self::Missing(_)) => missing,
            (Self::Unrooted, Self::Unrooted) => Self::Unrooted,
        }
    }
}

/// Where the walk reads an installation's reasons on one tool.
enum Facts<'a> {
    /// Installed entries, and the dependent's own captured snapshot for an
    /// ancestor with no entry. Snapshots of different dependents are never
    /// unioned: each was read with its own edges.
    Recorded,
    /// What the catalogs derive now ([`read_ancestry`]). An installation
    /// they do not derive has no carrier.
    Read(&'a BTreeMap<InstallRef, RequirerProvenance>),
}

/// What the facts hold for one installation.
enum Lookup<'f> {
    Found {
        repo: &'f str,
        reasons: &'f BTreeSet<Reason>,
    },
    /// No carrier derives it now.
    Absent,
    /// The record holds no reasons for it. The catalog identity it would
    /// be read under, where the record names one, still proves a
    /// declaration.
    Unknown(Option<&'f str>),
}

/// The single decision of whether a surviving declaration or set still
/// roots an installation once the selected items leave.
struct RemovalRoots<'a> {
    scope: &'a Scope,
    manifest: &'a Manifest,
    lock: &'a Lock,
    names: &'a [String],
    kind: Option<ItemKind>,
    options: &'a PlanOptions,
    facts: Facts<'a>,
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

    fn decide(&self, decisions: &mut BTreeMap<(ItemKind, String), Reach>) {
        let mut merge = |node: &InstallRef, reach: Reach| {
            let key = (node.kind, node.name.clone());
            let reach = match decisions.remove(&key) {
                Some(old) => old.or(reach),
                None => reach,
            };
            decisions.insert(key, reach);
        };
        match self.facts {
            Facts::Read(read) => {
                for row in read.values().filter(|row| self.selected(&row.installation)) {
                    merge(
                        &row.installation,
                        self.start(None, &row.installation, &row.source_repo, &row.reasons),
                    );
                }
            }
            Facts::Recorded => {
                for dependent in self.lock.entries.values() {
                    let node = InstallRef {
                        source: dependent.source.clone(),
                        kind: dependent.kind,
                        name: dependent.name.clone(),
                        harness: dependent.harness,
                    };
                    if self.selected(&node) {
                        merge(
                            &node,
                            self.start(
                                Some(dependent),
                                &node,
                                &dependent.source_repo,
                                &dependent.reasons,
                            ),
                        );
                    }
                    // A selected requirer withheld on the edge's tool has no
                    // entry there. The dependent's snapshot records what
                    // carries it; without that row the answer is unknown.
                    let edges = dependent.reasons.iter().chain(
                        dependent
                            .requirer_provenance
                            .iter()
                            .flatten()
                            .flat_map(|row| &row.reasons),
                    );
                    for reason in edges {
                        let Reason::RequiredBy { by } = reason else {
                            continue;
                        };
                        if !self.selected(by)
                            || self.lock.entries.contains_key(&crate::lock::entry_key(
                                by.kind, &by.name, by.harness,
                            ))
                        {
                            continue;
                        }
                        let reach = match captured(dependent, by) {
                            Some(row) => {
                                self.start(Some(dependent), by, &row.source_repo, &row.reasons)
                            }
                            None => Reach::Missing(Unread::Ancestor(by.clone())),
                        };
                        merge(by, reach);
                    }
                }
            }
        }
    }

    fn start(
        &self,
        dependent: Option<&LockEntry>,
        node: &InstallRef,
        repo: &str,
        reasons: &BTreeSet<Reason>,
    ) -> Reach {
        self.reasons(dependent, node, repo, reasons, &mut BTreeSet::new())
    }

    fn reasons(
        &self,
        dependent: Option<&LockEntry>,
        node: &InstallRef,
        repo: &str,
        reasons: &BTreeSet<Reason>,
        visited: &mut BTreeSet<InstallRef>,
    ) -> Reach {
        let mut found = Reach::Unrooted;
        for reason in reasons {
            let next = match reason {
                Reason::Requested => Reach::Unrooted,
                Reason::MemberOf { bundle } => self.member(node, repo, bundle),
                Reason::RequiredBy { by } => self.installation(dependent, by, visited),
            };
            found = found.or(next);
            if matches!(found, Reach::Rooted) {
                break;
            }
        }
        found
    }

    /// A set roots its member only while the manifest still installs it on
    /// the member's tool from the catalog it was read from.
    fn member(&self, node: &InstallRef, repo: &str, bundle: &crate::lock::BundleRef) -> Reach {
        let installs = self.manifest.bundles.get(&bundle.name).is_some_and(|decl| {
            decl.source == bundle.source
                && super::desired::target_harnesses(decl, self.manifest, node.kind, self.scope)
                    .contains(&node.harness)
        });
        if !installs {
            return Reach::Unrooted;
        }
        // The reading bound to this edge decides it. A member read from
        // the set's own source was read with the set, so its reading is the
        // edge's; a set record can be older, kept by an add that held
        // another member. A member declared from another catalog carries
        // no reading of the set, and only the set's record speaks for it.
        let read_under = match self.facts {
            Facts::Read(_) => crate::source::declared_provenance(self.manifest, &bundle.source),
            Facts::Recorded if node.source == bundle.source => Some(repo.to_owned()),
            Facts::Recorded => self
                .lock
                .bundles
                .get(&bundle.name)
                .filter(|set| set.source == bundle.source)
                .map(|set| set.source_repo.clone()),
        };
        match read_under {
            Some(read_under) if self.same_source(&bundle.source, &read_under) => Reach::Rooted,
            Some(_) => Reach::Unrooted,
            None => Reach::Missing(Unread::Set(bundle.clone())),
        }
    }

    fn installation(
        &self,
        dependent: Option<&LockEntry>,
        by: &InstallRef,
        visited: &mut BTreeSet<InstallRef>,
    ) -> Reach {
        if self.explicit(by) || !visited.insert(by.clone()) {
            return Reach::Unrooted;
        }
        let found = match self.lookup(dependent, by) {
            Lookup::Found { repo, .. } | Lookup::Unknown(Some(repo)) if self.declared(by, repo) => {
                Reach::Rooted
            }
            Lookup::Found { repo, reasons } => self.reasons(dependent, by, repo, reasons, visited),
            Lookup::Absent => Reach::Unrooted,
            Lookup::Unknown(_) => Reach::Missing(Unread::Ancestor(by.clone())),
        };
        visited.remove(by);
        found
    }

    fn lookup<'f>(&'f self, dependent: Option<&'f LockEntry>, by: &InstallRef) -> Lookup<'f> {
        let Facts::Read(read) = self.facts else {
            return self.recorded(dependent, by);
        };
        match read.get(by) {
            Some(row) => Lookup::Found {
                repo: &row.source_repo,
                reasons: &row.reasons,
            },
            None => Lookup::Absent,
        }
    }

    fn recorded<'f>(&'f self, dependent: Option<&'f LockEntry>, by: &InstallRef) -> Lookup<'f> {
        let captured = dependent.and_then(|dependent| captured(dependent, by));
        let installed = self
            .lock
            .entries
            .get(&crate::lock::entry_key(by.kind, &by.name, by.harness))
            .filter(|entry| entry.source == by.source)
            .filter(|entry| captured.is_none_or(|row| row.source_repo == entry.source_repo));
        if let Some(entry) = installed {
            return Lookup::Found {
                repo: &entry.source_repo,
                reasons: &entry.reasons,
            };
        }
        if let Some(row) = captured {
            return Lookup::Found {
                repo: &row.source_repo,
                reasons: &row.reasons,
            };
        }
        Lookup::Unknown(
            dependent
                .filter(|dependent| dependent.source == by.source)
                .map(|dependent| dependent.source_repo.as_str())
                .or_else(|| {
                    self.lock
                        .sources
                        .get(&by.source)
                        .map(|source| source.repo.as_str())
                }),
        )
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

/// The dependent's own snapshot row for one ancestor.
fn captured<'e>(dependent: &'e LockEntry, by: &InstallRef) -> Option<&'e RequirerProvenance> {
    dependent
        .requirer_provenance
        .iter()
        .flatten()
        .find(|row| row.installation == *by)
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
