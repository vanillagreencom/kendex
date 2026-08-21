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

/// Which revision to rebuild each installation from, keyed by the
/// installation rather than by any declaration. Empty for an ordinary plan,
/// which reads whatever the declarations track now.
pub(super) type Pins = BTreeMap<(ItemKind, String), Option<String>>;

/// The kinds a plan installs, in the order it plans them.
pub(super) const PLANNED_KINDS: [ItemKind; 5] = [
    ItemKind::Skill,
    ItemKind::Agent,
    ItemKind::Hook,
    ItemKind::Command,
    ItemKind::McpServer,
];

/// One item a plan installs: the declaration to plan it under, and the tools
/// it lands on. A declared item keeps the declaration the user wrote; a
/// derived one gets its source from whatever brought it in.
pub(super) struct Planned {
    pub(super) decl: ItemDecl,
    pub(super) harnesses: Vec<HarnessId>,
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

    /// Rebuild each installation from the revision it is actually at,
    /// rather than from the one its declaration tracks now.
    ///
    /// Applied to the expansion and not to the manifest, because a derived
    /// installation has no declaration to pin: a bundle member and a
    /// dependency are here under a declaration written for something else,
    /// and pinning by name reaches neither. Every installation the lock
    /// records is in here under its own key, whatever put it here.
    ///
    /// A pin naming no revision — a path source has none — leaves the
    /// declaration's own, which is the same answer reading it now gives.
    pub(super) fn pin(&mut self, pins: &Pins) {
        for ((kind, name), planned) in &mut self.items {
            if let Some(rev) = pins.get(&(*kind, name.clone())) {
                planned.decl.rev = rev.clone().or_else(|| planned.decl.rev.clone());
            }
        }
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
    fn declared(&mut self, kind: ItemKind, name: &str, decl: &ItemDecl, harnesses: Vec<HarnessId>) {
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
            });
        // Two derivations pinning one item at different revisions cannot
        // both be honored — one filesystem identity exists. The kept one is
        // whichever got here first (deterministic: parents walk in map
        // order); the refused one is recorded so the plan can say so.
        if planned.decl.source == decl.source && planned.decl.rev != decl.rev {
            self.rev_disagreements.push((
                kind,
                name.to_owned(),
                planned.decl.rev.clone(),
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
/// A catalog open for reading: the sealed root and its layout tables.
type OpenCatalog = (SealedSource, SourceConfig);
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
        Some((sealed, config))
    }
}

/// The whole installed set this manifest asks for: what it declares, what the
/// bundles it installs carry, and what those skills require.
pub(super) fn expand(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &mut DesiredState,
) -> Expansion {
    let mut expansion = Expansion::default();
    for kind in PLANNED_KINDS {
        for (name, decl) in manifest.declared(kind) {
            // The drift hook under both its names is one hook declared
            // twice: the new declaration installs, and the legacy one is
            // reported as superseded rather than installing a second copy
            // of the same session-start report.
            if kind == ItemKind::Hook && crate::drift::hook::superseded(manifest, name) {
                state.warnings.push(super::ItemWarning {
                    kind,
                    name: name.clone(),
                    harness: None,
                    message: format!(
                        "`{}` and `{}` are the same drift hook — the declaration under `{}` installs, this one is superseded",
                        crate::drift::hook::LEGACY_HOOK_NAME,
                        crate::drift::hook::HOOK_NAME,
                        crate::drift::hook::HOOK_NAME,
                    ),
                    remediation: Some(format!(
                        "drop `[hooks.{}]` from kendex.toml",
                        crate::drift::hook::LEGACY_HOOK_NAME
                    )),
                });
                continue;
            }
            let harnesses = target_harnesses(decl, manifest, kind, scope);
            expansion.declared(kind, name, decl, harnesses);
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
    super::bundles::expand(scope, manifest, &mut expansion, &mut catalogs, state);
    super::deps::expand(scope, manifest, &mut expansion, &mut catalogs, state);
    expansion.report_rev_disagreements(state);
    expansion
}
