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
use crate::source::{SourceConfig, SourceState, source_config};
use crate::source_read::SealedSource;

use super::desired::{DesiredState, target_harnesses};

/// The kinds a plan installs, in the order it plans them.
pub(super) const PLANNED_KINDS: [ItemKind; 5] = [
    ItemKind::Skill,
    ItemKind::Agent,
    ItemKind::Hook,
    ItemKind::Command,
    ItemKind::McpServer,
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
}

#[derive(Default)]
pub(super) struct Expansion {
    items: BTreeMap<(ItemKind, String), Planned>,
    reasons: BTreeMap<(ItemKind, String, HarnessId), BTreeSet<Reason>>,
    /// Derivations that asked for the same item at different revisions:
    /// (kind, name, kept rev, refused rev). The first derivation wins
    /// deterministically — map order — and each loser is reported, never
    /// silently absorbed.
    rev_disagreements: Vec<(ItemKind, String, Option<String>, Option<String>)>,
}

impl Expansion {
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
            },
        );
    }

    /// Record one derived reason, returning whether this taught the expansion
    /// something new — which is what keeps a cycle from walking forever.
    pub(super) fn add(
        &mut self,
        kind: ItemKind,
        name: &str,
        decl: &ItemDecl,
        harness: HarnessId,
        reason: Reason,
    ) -> bool {
        // A set weighs its revision against the one the person chose for
        // the item; every other derivation weighs it against the revision
        // the item actually reads. What a dependency reads is its parent's
        // own commit, invented pin included — KEN-765 is where that edge
        // learns the difference.
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
            });
        let wanted_at = match carried_by_a_set {
            true => &planned.chosen_rev,
            false => &planned.decl.rev,
        };
        // Two derivations pinning one item at different revisions cannot
        // both be honored — one filesystem identity exists. The kept one is
        // whichever got here first (deterministic: parents walk in map
        // order); the refused one is recorded so the plan can say so.
        if planned.decl.source == decl.source && *wanted_at != decl.rev {
            self.rev_disagreements.push((
                kind,
                name.to_owned(),
                wanted_at.clone(),
                decl.rev.clone(),
            ));
        }
        if !planned.harnesses.contains(&harness) {
            planned.harnesses.push(harness);
        }
        fresh
    }

    /// Report every revision disagreement as a warning on the item, once
    /// per distinct pair, and mark the item so the plan writes nothing for
    /// it: two revisions were asked for, one filesystem identity exists,
    /// and picking one silently would install content somebody pinned away
    /// from.
    fn report_rev_disagreements(&mut self, state: &mut DesiredState) {
        self.rev_disagreements.sort();
        self.rev_disagreements.dedup();
        for (kind, name, kept, refused) in &self.rev_disagreements {
            let show = |rev: &Option<String>| match rev {
                Some(rev) => format!("revision {}", rev.chars().take(7).collect::<String>()),
                None => "the source's own revision".to_owned(),
            };
            state.rev_conflicts.insert((*kind, name.clone()));
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
            });
        }
    }
}

/// Every catalog read this pass, opened once. Sources that cannot be read
/// carry nothing to derive; the declaration that names one reports that on
/// its own, where it can say which declaration it cost.
/// A catalog open for reading: the sealed root, its layout tables, and the
/// bare-name index its dependency lookups share, built once per catalog.
type OpenCatalog = (SealedSource, SourceConfig, super::deps::OfferedSkills);
/// Which catalog: the source name and the revision it is read at.
type CatalogKey = (String, Option<String>);

pub(super) struct Catalogs<'a> {
    env: &'a Env,
    scope: &'a Scope,
    manifest: &'a Manifest,
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

    fn read(
        &self,
        source: &str,
        rev: Option<&str>,
        state: &mut DesiredState,
    ) -> Option<OpenCatalog> {
        let resolution = match rev {
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
                        crate::source::resolve(self.env, self.scope, source, self.manifest).ok()?;
                    state.sources.insert(source.to_owned(), resolution.clone());
                    resolution
                }
            },
        };
        let SourceState::Ready(ready) = resolution else {
            return None;
        };
        let sealed = SealedSource::open(&ready.root).ok()?;
        let config = source_config(&sealed, crate::source::repo_leaf(&ready.provenance)).ok()?;
        Some((sealed, config, super::deps::OfferedSkills::default()))
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
    let mut expansion = Expansion::default();
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
                    "{} {name} is declared and also kept removed — the declaration wins and it installs; drop it from [suppressed] in kendex.toml to settle it",
                    kind.name()
                ));
            }
        }
    }
    let mut catalogs = Catalogs {
        env,
        scope,
        manifest,
        open: BTreeMap::new(),
    };
    super::bundles::expand(scope, manifest, held, &mut expansion, &mut catalogs, state);
    super::deps::expand(manifest, &mut expansion, &mut catalogs, state);
    expansion.report_rev_disagreements(state);
    expansion
}

#[cfg(test)]
mod tests {
    use super::{ItemKind, plans_per_package};

    /// The rule stated as a fact about the product, not as a copy of the
    /// list behind it. The match below is exhaustive over `ItemKind`, so
    /// it cannot be satisfied by the list [`plans_per_package`] reads: a
    /// kind moved into `PLANNED_KINDS` turns this red, and a variant added
    /// to the enum stops this test compiling until it is classified here.
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
                | ItemKind::McpServer => false,
            };
            assert_eq!(plans_per_package(kind), !refused, "{kind:?}");
        }
    }
}
