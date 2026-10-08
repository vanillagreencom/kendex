//! What a plan installs, and why each installation exists.
//!
//! The manifest holds choices: the items asked for, the bundles installed,
//! which optional dependencies were taken, what stays removed. Here those
//! choices become the whole set — bundle members and skill dependencies
//! included — with a reason edge on every installation. None of it is written
//! back. An item that arrived as a member or a dependency must never read as
//! one the user asked for, or removing whatever brought it in could never
//! take it away again.

use std::collections::{BTreeMap, BTreeSet};

use crate::env::Env;
use crate::lock::Reason;
use crate::manifest::{ItemDecl, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::{SourceConfig, SourceState, find_item, source_config_for};
use crate::source_read::SealedSource;

use super::desired::{DesiredState, SelectorBasis, target_harnesses};

/// The kinds a plan installs, in the order it plans them.
pub(super) const PLANNED_KINDS: [ItemKind; 6] = [
    ItemKind::Skill,
    ItemKind::Agent,
    ItemKind::Hook,
    ItemKind::Command,
    ItemKind::McpServer,
    ItemKind::OutputStyle,
];

/// Whether a scope plan derives and writes this kind, and so whether one
/// package of it can be brought current on its own. A Pi extension
/// installs through its own path and a plugin is declared whole; a plan
/// asked for either comes back empty, and an empty plan reads as "already
/// current" on every surface that shows it.
///
/// The list behind the question never leaves this crate. A surface holding
/// its own copy of it is a second account of the same rule, and the offer
/// and its refusal would then come from two places: every caller asks this
/// function, or reads the [`NO_PER_PACKAGE_UPDATE`] an update row already
/// carries.
pub fn plans_per_package(kind: ItemKind) -> bool {
    PLANNED_KINDS.contains(&kind)
}

/// Why a kind [`plans_per_package`] rejects is refused, and where the work
/// that does move it lives. One sentence, said the same way wherever the
/// refusal surfaces — the app's error, and the note an update row carries
/// for a kind it names — so no surface invents its own account of it.
/// It stands alone, because a tooltip has nothing to append it to.
pub const NO_PER_PACKAGE_UPDATE: &str = "Not updated one package at a time — Pi extensions come current with kendex update-pi, plugins with their place's own apply";

/// One item a plan installs: the declaration to plan it under, and the tools
/// it lands on. A declared item keeps the declaration the user wrote; a
/// derived one gets its source from whatever brought it in.
#[derive(Clone)]
pub(super) struct Planned {
    pub(super) decl: ItemDecl,
    pub(super) harnesses: Vec<HarnessId>,
    /// The revision the person chose for this item, where `decl` reads a
    /// pin this pass invented to hold the scope still. What a set carries
    /// is weighed against this and never against the pin: two revisions
    /// nobody wrote read as agreement, and a warning that names one names
    /// a commit kendex made up.
    chosen_rev: Option<String>,
    /// The derivation that created this entry, and so supplied the `decl`
    /// every later one is weighed against — the reason that owns this
    /// item's revision. `None` for a declaration the person wrote.
    derived_from: Option<Reason>,
    /// The synthetic declaration that supplied this reading, inherited
    /// by dependencies when their parent owns the revision.
    held_by: Option<super::Held>,
}

#[derive(Default, Clone)]
pub(super) struct Expansion {
    items: BTreeMap<(ItemKind, String), Planned>,
    reasons: BTreeMap<(ItemKind, String, HarnessId), BTreeSet<Reason>>,
    /// Derivations that asked for the same item at different revisions.
    /// The first derivation wins deterministically — map order — and each
    /// loser is reported, never silently absorbed.
    rev_disagreements: Vec<Disagreement>,
    /// The revisions this pass pinned itself to hold the rest of the scope
    /// still, by source and commit: read revisions, never a person's
    /// choice.
    invented: BTreeSet<(String, String)>,
    held_owners: BTreeSet<(String, super::Held)>,
}

/// One derivation asking for an item at a revision other than the one the
/// item is already wanted at.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Disagreement {
    kind: ItemKind,
    name: String,
    source: String,
    kept: Option<String>,
    refused: Option<String>,
    /// A set weighed the revision the person chose, which can differ from
    /// the one the item is read at; only a derivation weighing the read
    /// revision can be settled by the commit both resolve to.
    by_a_set: bool,
}

impl Expansion {
    pub(super) fn selector_bases(
        &self,
        manifest: &Manifest,
    ) -> BTreeMap<(ItemKind, String), SelectorBasis> {
        self.items
            .iter()
            .map(|(key, planned)| {
                let basis = match &planned.held_by {
                    Some(_) => SelectorBasis::Held,
                    None => SelectorBasis::Declared(crate::lock::DeclaredSelector::of(
                        manifest,
                        &planned.decl.source,
                        planned.decl.rev.as_deref(),
                    )),
                };
                (key.clone(), basis)
            })
            .collect()
    }

    /// Everything of one kind this plan installs, in name order.
    pub(super) fn of(&self, kind: ItemKind) -> Vec<(&String, &Planned)> {
        self.items
            .iter()
            .filter(|((of_kind, _), _)| *of_kind == kind)
            .map(|((_, name), planned)| (name, planned))
            .collect()
    }

    pub(super) fn reasons(
        &self,
        kind: ItemKind,
        name: &str,
        harness: HarnessId,
    ) -> BTreeSet<Reason> {
        self.reasons
            .get(&(kind, name.to_owned(), harness))
            .cloned()
            .unwrap_or_default()
    }

    /// Why one package is wanted on any tool, every tool's reasons
    /// together.
    pub(super) fn package_reasons(&self, kind: ItemKind, name: &str) -> BTreeSet<Reason> {
        self.reasons
            .iter()
            .filter(|((of_kind, of_name, _), _)| *of_kind == kind && of_name == name)
            .flat_map(|(_, reasons)| reasons.iter().cloned())
            .collect()
    }

    pub(super) fn contains(&self, kind: ItemKind, name: &str) -> bool {
        self.items.contains_key(&(kind, name.to_owned()))
    }

    /// The declaration an item in this expansion installs under — the
    /// source it reads and the revision it is held at, if any.
    pub(super) fn decl_of(&self, kind: ItemKind, name: &str) -> Option<ItemDecl> {
        self.items
            .get(&(kind, name.to_owned()))
            .map(|planned| planned.decl.clone())
    }

    /// The derivation that owns this item's revision, per [`Planned`].
    pub(super) fn derived_from(&self, kind: ItemKind, name: &str) -> Option<&Reason> {
        self.items
            .get(&(kind, name.to_owned()))?
            .derived_from
            .as_ref()
    }

    pub(super) fn harnesses(&self, kind: ItemKind, name: &str) -> Vec<HarnessId> {
        self.items
            .get(&(kind, name.to_owned()))
            .map(|planned| planned.harnesses.clone())
            .unwrap_or_default()
    }

    /// A declaration the user wrote: it installs as written, and it is here
    /// even when no tool can hold it — the plan says so rather than going
    /// quiet about a declaration that produced nothing.
    fn declared(
        &mut self,
        kind: ItemKind,
        name: &str,
        decl: &ItemDecl,
        harnesses: Vec<HarnessId>,
        chosen_rev: Option<String>,
    ) {
        for harness in &harnesses {
            self.reasons
                .entry((kind, name.to_owned(), *harness))
                .or_default()
                .insert(Reason::Requested);
        }
        self.items.insert(
            (kind, name.to_owned()),
            Planned {
                decl: decl.clone(),
                harnesses,
                chosen_rev,
                derived_from: None,
                held_by: self.held_owner(
                    &decl.source,
                    super::Held::Item {
                        kind,
                        name: name.to_owned(),
                    },
                ),
            },
        );
    }

    /// A declaration already here, as it would stand had the person
    /// written `decl` instead: what the one they wrote asked for goes,
    /// what a set carries stays, and `decl` is asked for on `harnesses`.
    /// Read by the walk asked again with a hook's pin dropped
    /// (`deps::withheld_past_pin`).
    pub(super) fn redeclare(
        &mut self,
        kind: ItemKind,
        name: &str,
        decl: &ItemDecl,
        harnesses: Vec<HarnessId>,
    ) {
        let Some(planned) = self.items.get_mut(&(kind, name.to_owned())) else {
            unreachable!("{name} is redeclared only where it was declared");
        };
        let mut carried = Vec::new();
        for harness in &planned.harnesses {
            let key = (kind, name.to_owned(), *harness);
            let Some(reasons) = self.reasons.get_mut(&key) else {
                continue;
            };
            reasons.remove(&Reason::Requested);
            match reasons.is_empty() {
                true => {
                    self.reasons.remove(&key);
                }
                false => carried.push(*harness),
            }
        }
        for harness in &harnesses {
            self.reasons
                .entry((kind, name.to_owned(), *harness))
                .or_default()
                .insert(Reason::Requested);
        }
        planned.decl = decl.clone();
        planned.harnesses = harnesses;
        for harness in carried {
            if !planned.harnesses.contains(&harness) {
                planned.harnesses.push(harness);
            }
        }
    }

    /// Record one more reason for an item already planned on `harness`,
    /// and nothing for one that is not: the reason asks for no
    /// installation of its own (`deps::carry_kept_retired_edges`).
    pub(super) fn add_to_planned(
        &mut self,
        kind: ItemKind,
        name: &str,
        harness: HarnessId,
        reason: Reason,
    ) {
        if self.harnesses(kind, name).contains(&harness) {
            self.reasons
                .entry((kind, name.to_owned(), harness))
                .or_default()
                .insert(reason);
        }
    }

    /// Record one derived reason, returning whether this taught the expansion
    /// something — which is what keeps a cycle from walking forever.
    pub(super) fn add(
        &mut self,
        kind: ItemKind,
        name: &str,
        decl: &ItemDecl,
        harness: HarnessId,
        reason: Reason,
    ) -> bool {
        let held_by = match &reason {
            Reason::Requested => unreachable!("a requested item is declared, never derived"),
            Reason::MemberOf { bundle } => self.held_owner(
                &bundle.source,
                super::Held::Set {
                    name: bundle.name.clone(),
                },
            ),
            Reason::RequiredBy { by } => {
                let Some(parent) = self.items.get(&(by.kind, by.name.clone())) else {
                    unreachable!("a dependency's parent is already expanded");
                };
                parent.held_by.clone()
            }
        };
        // A set weighs its revision against the one the person chose for
        // the item; every other derivation weighs it against the revision
        // the item actually reads.
        // A dependency uses its parent's commit, including a pin synthesized
        // for the plan.
        let carried_by_a_set = matches!(reason, Reason::MemberOf { .. });
        let reason_owning = reason.clone();
        let fresh = self
            .reasons
            .entry((kind, name.to_owned(), harness))
            .or_default()
            .insert(reason);
        let planned = self
            .items
            .entry((kind, name.to_owned()))
            .or_insert_with(|| Planned {
                decl: decl.clone(),
                harnesses: Vec::new(),
                chosen_rev: decl.rev.clone(),
                derived_from: Some(reason_owning.clone()),
                held_by,
            });
        // A derived item is on while any requirer that brings it in is on:
        // the first requirer walked wrote its switch, and a later one that
        // is on must not be left armed beside a companion the first parked.
        // A declaration the person wrote is theirs and is never turned on
        // here. The item is walked again so its own companions follow.
        let turned_on = planned.derived_from.is_some() && decl.enabled && !planned.decl.enabled;
        if turned_on {
            planned.decl.enabled = true;
        }
        let wanted_at = match carried_by_a_set {
            true => &planned.chosen_rev,
            false => &planned.decl.rev,
        };
        // Two derivations pinning one item at different revisions cannot
        // both be honored — one filesystem identity exists. The kept one is
        // whichever got here first (deterministic: parents walk in map
        // order); the refused one is recorded so the plan can say so.
        if planned.decl.source == decl.source && *wanted_at != decl.rev {
            self.rev_disagreements.push(Disagreement {
                kind,
                name: name.to_owned(),
                source: decl.source.clone(),
                kept: wanted_at.clone(),
                refused: decl.rev.clone(),
                by_a_set: carried_by_a_set,
            });
        }
        if !planned.harnesses.contains(&harness) {
            planned.harnesses.push(harness);
        }
        fresh || turned_on
    }

    fn held_owner(&self, source: &str, owner: super::Held) -> Option<super::Held> {
        self.held_owners
            .contains(&(source.to_owned(), owner.clone()))
            .then_some(owner)
    }

    /// Report every revision disagreement as a warning on the item, once
    /// per distinct pair, and mark the item so the plan writes nothing for
    /// it: two revisions were asked for, one filesystem identity exists,
    /// and picking one silently would install content somebody pinned away
    /// from.
    ///
    /// Two revisions this pass read at one commit are no disagreement: a
    /// package held at the commit its source still resolves to and one
    /// following that source want the same bytes. A revision this pass
    /// holds no resolution for is weighed as written, and so is a set's,
    /// which weighs the revision the person chose rather than the one read
    /// — unless either side is a pin this pass invented, which is a read
    /// revision and no choice of anyone's.
    pub(super) fn report_rev_disagreements(&mut self, state: &mut DesiredState) {
        self.rev_disagreements.sort();
        self.rev_disagreements.dedup();
        let commit_of = |source: &str, rev: &Option<String>| {
            let resolved = match rev {
                None => state.sources.get(source),
                Some(rev) => state.pinned.get(&(source.to_owned(), rev.clone())),
            };
            match resolved {
                Some(SourceState::Ready(ready)) => ready.commit.clone(),
                _ => None,
            }
        };
        let invented = &self.invented;
        let invented = |source: &str, rev: &Option<String>| {
            rev.as_ref()
                .is_some_and(|rev| invented.contains(&(source.to_owned(), rev.clone())))
        };
        self.rev_disagreements.retain(|one| {
            let kept = commit_of(&one.source, &one.kept);
            let chosen = one.by_a_set
                && !invented(&one.source, &one.kept)
                && !invented(&one.source, &one.refused);
            chosen || kept.is_none() || kept != commit_of(&one.source, &one.refused)
        });
        for Disagreement {
            kind,
            name,
            kept,
            refused,
            source,
            ..
        } in &self.rev_disagreements
        {
            let show = |rev: &Option<String>| match rev {
                Some(rev) => format!("revision {}", rev.chars().take(7).collect::<String>()),
                None => "the source's own revision".to_owned(),
            };
            let resolved = |rev: &Option<String>| {
                commit_of(source, rev)
                    .or_else(|| rev.clone())
                    .unwrap_or_else(|| "the source's own revision".to_owned())
            };
            let disagreement = (*kind, name.clone(), resolved(kept), resolved(refused));
            state.rev_conflicts.insert((*kind, name.clone()));
            state.rev_disagreements.push(disagreement);
            state.warnings.push(super::ItemWarning {
                kind: *kind,
                name: name.clone(),
                harness: None,
                message: format!(
                    "wanted at {} and also at {} — nothing was changed",
                    show(kept),
                    show(refused),
                ),
                remediation: Some(
                    "pin the items that bring it in to the same revision, or unpin them".into(),
                ),
                detail: None,
            });
        }
    }
}

/// A catalog open for reading: the sealed root, its layout tables, and the
/// bare-name index its dependency lookups share, built once per catalog.
pub(super) struct OpenCatalog {
    pub(super) sealed: SealedSource,
    pub(super) config: SourceConfig,
    pub(super) offered: super::deps::OfferedSkills,
}

impl OpenCatalog {
    /// What this catalog says about one item: the one lookup for a
    /// declared item, a set's member and a requirement alike. `[retired]`
    /// answers before any file is asked for, so a catalog that retired an
    /// item and deleted it answers as one still carrying it.
    pub(super) fn offer(&self, kind: ItemKind, name: &str) -> Offer<'_> {
        if let Some(migration) = self.config.retired(kind, name) {
            return Offer::Retired(migration);
        }
        match find_item(&self.sealed, &self.config, kind, name) {
            Some(path) => Offer::Item(self, path),
            // A catalog answering with less than it offers cannot say the
            // item is not there: `SourceConfig::hides_content` is what
            // keeps a removal from reading it as the whole truth.
            None if self.config.hides_content() => Offer::Silent,
            None => Offer::NotOffered,
        }
    }
}

/// Which catalog: the source name and the revision it is read at.
pub(super) type CatalogKey = (String, Option<String>);

/// What a catalog says about one item ([`Catalogs::offer`]): the item and
/// the catalog it is read from, which is what the planner writes; that the
/// catalog reads whole and does not offer it, which is what the planner
/// writes nothing for; or nothing at all — the catalog never opened, would
/// not resolve or read, or read with its content hidden and the item not
/// found. Silence leaves the planner writing nothing from it too, but says
/// nothing about whether the item would run. A catalog that retired the
/// item offers it no more than one that dropped it, carried or not, and
/// names the migration.
pub(super) enum Offer<'a> {
    Item(&'a OpenCatalog, std::path::PathBuf),
    Retired(&'a str),
    NotOffered,
    Silent,
}

/// Every catalog read this pass, opened once. Sources that cannot be read
/// carry nothing to derive; the declaration that names one reports that on
/// its own, where it can say which declaration it cost.
pub(super) struct Catalogs<'a> {
    pub(super) env: &'a Env,
    pub(super) scope: &'a Scope,
    manifest: &'a Manifest,
    /// Native callbacks read installed sources without publishing or fetching.
    installed: Option<&'a crate::lock::Lock>,
    /// Keyed by (source, rev): a pinned declaration derives its members and
    /// dependencies from the pinned commit's catalog, not from wherever the
    /// source has moved since.
    open: BTreeMap<CatalogKey, Option<OpenCatalog>>,
}

impl Catalogs<'_> {
    pub(super) fn get(
        &mut self,
        source: &str,
        rev: Option<&str>,
        state: &mut DesiredState,
    ) -> Option<&OpenCatalog> {
        let key: CatalogKey = (source.to_owned(), rev.map(str::to_owned));
        if !self.open.contains_key(&key) {
            let opened = self.read(source, rev, state);
            self.open.insert(key.clone(), opened);
        }
        self.open.get(&key).and_then(Option::as_ref)
    }

    /// What the catalog under `key`, opened ahead by [`Catalogs::get`],
    /// says about one item this pass. The one question for an item derived
    /// from a catalog, asked after every catalog a walk step needs is open,
    /// since it borrows nothing mutably and two answers can be read side
    /// by side.
    pub(super) fn offer(&self, key: &CatalogKey, kind: ItemKind, name: &str) -> Offer<'_> {
        let Some(catalog) = self.open.get(key).and_then(Option::as_ref) else {
            return Offer::Silent;
        };
        catalog.offer(kind, name)
    }

    fn read(
        &self,
        source: &str,
        rev: Option<&str>,
        state: &mut DesiredState,
    ) -> Option<OpenCatalog> {
        let resolution = if let Some(lock) = self.installed {
            let recorded = lock.sources.get(source);
            let commit = rev.or_else(|| recorded.map(|recorded| recorded.commit.as_str()));
            match crate::source::read_installed(
                self.env,
                self.scope,
                source,
                self.manifest,
                commit,
                recorded.map(|recorded| recorded.repo.as_str()),
            ) {
                Ok(resolution) => resolution,
                Err(problem) => {
                    state.unreadable_catalogs.insert(source.into());
                    state.mark_incomplete();
                    state.notes.push(problem.to_string());
                    return None;
                }
            }
        } else {
            match rev {
                Some(rev) => {
                    let key = (source.to_owned(), rev.to_owned());
                    match state.pinned.get(&key) {
                        Some(resolution) => resolution.clone(),
                        None => {
                            let resolution = crate::source::resolve_at(
                                self.env,
                                self.scope,
                                source,
                                self.manifest,
                                Some(rev),
                            )
                            .ok()?;
                            state.pinned.insert(key, resolution.clone());
                            resolution
                        }
                    }
                }
                None => match state.sources.get(source) {
                    Some(resolution) => resolution.clone(),
                    None => {
                        let resolution =
                            crate::source::resolve(self.env, self.scope, source, self.manifest)
                                .ok()?;
                        state.sources.insert(source.to_owned(), resolution.clone());
                        resolution
                    }
                },
            }
        };
        let SourceState::Ready(ready) = resolution else {
            return None;
        };
        // Everything derived — a set's members, a skill's dependencies —
        // reaches its catalog through here, so this is where the removal pass
        // learns that a catalog answered with less than it offers. A read that
        // failed — a symlinked control file, bytes that are not text, a file
        // past the cap — answered with nothing, and dropping that error would
        // make the silence look like a catalog that offers nothing.
        //
        // This is the narrower of the two readings, on purpose: what a set
        // holds is read per declaration below, which reports its own
        // failures. `origin::origin` is the wider one, and a failure shape
        // added here has to be added there too or a sweep keeps answering
        // that a catalog reads.
        let opened = SealedSource::open(&ready.root)
            .and_then(|sealed| Ok((source_config_for(&sealed, &ready.provenance)?, sealed)));
        let (config, sealed) = match opened {
            Ok(opened) => opened,
            // The removal pass reads the mark and stays quiet, because this
            // is the one place holding the error: the callers below get a
            // `None` that says only that nothing was derived, and a plan
            // that keeps a broken catalog's files while saying nothing is
            // the silence this whole read exists to end.
            Err(problem) => {
                state.unreadable_catalogs.insert(source.to_owned());
                state.notes.push(format!(
                    "the catalog '{source}' could not be read — {}",
                    super::origin::said(problem)
                ));
                return None;
            }
        };
        if config.hides_content() {
            state.unreadable_catalogs.insert(source.to_owned());
        }
        Some(OpenCatalog {
            sealed,
            config,
            offered: super::deps::OfferedSkills::default(),
        })
    }
}

/// The whole installed set this manifest asks for: what it declares, what the
/// bundles it installs carry, and what those skills require.
///
/// `held` names the declarations this pass pinned itself, where the
/// manifest is a single-package update's pinned copy: a set's members read
/// it to tell a hold the person chose from one invented to keep the rest
/// of the scope still.
pub(super) fn expand(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    held: Option<&super::desired::hold::HeldPins>,
    state: &mut DesiredState,
) -> Expansion {
    expand_read(env, scope, manifest, held, state, None)
}

/// Same declaration walk, restricted to installed read-only catalog evidence.
pub(super) fn expand_installed(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &crate::lock::Lock,
    state: &mut DesiredState,
) -> Expansion {
    let installed = super::desired::hold::installed_manifest(manifest, lock);
    expand_read(env, scope, &installed, None, state, Some(lock))
}

fn expand_read<'a>(
    env: &'a Env,
    scope: &'a Scope,
    manifest: &'a Manifest,
    held: Option<&super::desired::hold::HeldPins>,
    state: &mut DesiredState,
    installed: Option<&'a crate::lock::Lock>,
) -> Expansion {
    let mut expansion = Expansion {
        held_owners: held
            .map(|pins| {
                pins.pins()
                    .iter()
                    .map(|pin| (pin.source.clone(), pin.held.clone()))
                    .collect()
            })
            .unwrap_or_default(),
        invented: held
            .map(|pins| {
                pins.pins()
                    .iter()
                    .map(|pin| (pin.source.clone(), pin.commit.clone()))
                    .collect()
            })
            .unwrap_or_default(),
        ..Expansion::default()
    };
    for kind in PLANNED_KINDS {
        for (name, decl) in manifest.declared(kind) {
            let harnesses = target_harnesses(decl, manifest, kind, scope);
            let chosen_rev = match held {
                Some(pins) if pins.invented_item(kind, name) => None,
                _ => decl.rev.clone(),
            };
            expansion.declared(kind, name, decl, harnesses, chosen_rev);
            // A removal is recorded so that nothing derives the item back on
            // its own. Declaring it by name is the plainest statement that it
            // is wanted, so it installs and the record sits there doing
            // nothing — one of the two has to go, and the user picks which.
            if manifest.is_suppressed(kind, name) {
                state.notes.push(format!(
                    "{} {name} is declared and also kept removed — the declaration wins and it installs; drop it from [suppressed] in {} to settle it",
                    kind.name(),
                    crate::manifest::manifest_file_name(env, scope),
                ));
            }
        }
    }
    let mut catalogs = Catalogs {
        env,
        scope,
        manifest,
        installed,
        open: BTreeMap::new(),
    };
    super::bundles::expand(scope, manifest, held, &mut expansion, &mut catalogs, state);
    // The walk reports the revision disagreements itself, once every
    // requirer has added its reason and before withholding spreads.
    super::deps::expand(manifest, &mut expansion, &mut catalogs, state);
    expansion
}

#[cfg(test)]
mod tests {
    use super::{ItemKind, plans_per_package};

    /// The rule stated as a fact about the product, not as a copy of the
    /// list behind it. The match below is exhaustive over `ItemKind`, so
    /// it cannot be satisfied by the list [`plans_per_package`] reads: a
    /// kind moved into `PLANNED_KINDS` turns this red, and a variant joining
    /// the enum stops this test compiling until it is classified here.
    /// What this does not hold: the loop walks `ItemKind::ALL`, so a kind
    /// missing from that list is one it never visits, its arm here
    /// satisfied and unexercised. `ALL`'s declared `[ItemKind; 7]` reds a
    /// kind removed outright and `replace_unmanaged.rs` pins Agent, Skill
    /// and Hook in that relative order; nothing else about `ALL` is held.
    #[test]
    fn only_the_kinds_a_plan_derives_have_a_per_package_update() {
        for kind in ItemKind::ALL {
            let refused = match kind {
                // A Pi extension installs through its own path and a
                // plugin is declared whole: a single-package plan for
                // either is empty, which every surface reads as already
                // current.
                ItemKind::PiExtension | ItemKind::Plugin => true,
                ItemKind::Skill
                | ItemKind::Agent
                | ItemKind::Hook
                | ItemKind::Command
                | ItemKind::McpServer
                | ItemKind::OutputStyle => false,
            };
            assert_eq!(plans_per_package(kind), !refused, "{kind:?}");
        }
    }
}
