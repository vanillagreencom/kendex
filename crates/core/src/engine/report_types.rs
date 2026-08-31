//! The types an engine pass hands back — drift rows, warnings, the report
//! itself — and the options a plan is asked with.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::apply::Plan;
use crate::model::{HarnessId, ItemKind, Scope};

use super::compared::Comparison;
use super::scoring::ItemSafety;
use super::set_change::{KeptInstall, SetChange};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum DriftState {
    /// Declared but not on disk (or never recorded).
    Missing,
    /// On disk but no longer matching declaration + source.
    Stale,
    /// Recorded in the lock but no longer declared.
    Orphaned,
    /// On disk in a managed surface, but not ours.
    Unmanaged,
    /// Needs a human: foreign symlink, occupied target, or provenance clash.
    Conflict,
}

/// Why an installation diverged, when the plan can tell. `LocalEdit` and
/// `Both`, and the three that say files kendex did not write are on disk,
/// block writes: only an explicit choice may take them. Which choices are
/// on offer differs by cause, which is what `can_keep` and `can_replace`
/// answer — a surface that guesses ends up offering a way out that errors.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum DriftCause {
    UpstreamChanged,
    LocalEdit,
    Both,
    /// Files are already where a declaration installs, and no lock entry
    /// says kendex put them there. The two ways out are opposite
    /// directions: adopt keeps the files, `replace_unmanaged` keeps the
    /// declaration.
    UnmanagedContent,
    /// The same, in a shape adoption cannot take as it stands: a folder
    /// where one file goes, or a file where a folder goes. Only the
    /// replacement is on offer — keeping these means moving them.
    UnmanagedWrongShape,
    /// A link somebody set up, pointing at a real folder that several
    /// tools read. Only keeping is on offer: the files are not at this
    /// position to replace, and writing over the link breaks the sharing.
    /// The detail is the folder the link points at, which is the one a
    /// reader needs to see.
    SharedLink,
    /// A link somebody set up that adoption cannot follow and the
    /// replacement must not write over. Neither exit settles it, so an
    /// item with one of these anywhere has no exit at all — the files move
    /// out of the way by hand or nothing does.
    ForeignLink,
}

impl DriftCause {
    /// Whether this conflict is a decision of its own. The person's own
    /// edits are: they are settled by keeping them as a fork or discarding
    /// them, and they never take the item's other exits away.
    pub fn is_own_decision(self) -> bool {
        matches!(self, DriftCause::LocalEdit | DriftCause::Both)
    }

    /// Whether the plan leaves the files where they are because of this.
    ///
    /// Every cause but one does. `UpstreamChanged` is the plain "newer
    /// content is available" case, which a plan simply writes; all the rest
    /// need an explicit choice first, so until one is made the tree on disk
    /// is the tree that was there. Named as the question rather than as a
    /// list, because a caller that lists them is a caller to revisit the day
    /// a cause is added.
    pub fn holds_the_write(self) -> bool {
        !matches!(self, DriftCause::UpstreamChanged)
    }

    /// Whether files kendex did not write are what this row is about — the
    /// causes every surface offers a way out of.
    pub fn in_the_way(self) -> bool {
        matches!(
            self,
            DriftCause::UnmanagedContent | DriftCause::UnmanagedWrongShape | DriftCause::SharedLink
        )
    }

    /// Whether adoption can take what is at this position.
    pub fn can_keep(self) -> bool {
        matches!(self, DriftCause::UnmanagedContent | DriftCause::SharedLink)
    }

    /// Whether installing what kendex.toml asks for over it is an answer.
    pub fn can_replace(self) -> bool {
        matches!(
            self,
            DriftCause::UnmanagedContent | DriftCause::UnmanagedWrongShape
        )
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct DriftRow {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub scope: Scope,
    pub state: DriftState,
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<DriftCause>,
    /// How the content in the way compares with the install this row
    /// refused — absent where the position holds nothing comparable, or
    /// where the row is not about content in the way at all.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compared: Option<Comparison>,
    /// Every other position holding the person's own files that a
    /// take-over of this row moves to the trash. `detail` is one path, the
    /// row's identity, and the plan refuses at the first position it
    /// reads; a tree read through a harness-native link has a second
    /// position of its own, so an offer built on `detail` alone would move
    /// directories it never named.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub also_in_the_way: Vec<String>,
}

impl DriftRow {
    /// Whether this row stops every exit the item has. Both exits act on
    /// the whole item, so one place nothing can settle — a link kendex
    /// will not follow, a revision clash, a source rebind — takes the
    /// offers off every other place too. The person's own edits are the
    /// exception: they are a decision of their own.
    pub fn dead_stop(&self) -> bool {
        self.state == DriftState::Conflict && !self.cause.is_some_and(DriftCause::is_own_decision)
    }
}

/// A per-item render or parse warning, with the fix when there is one —
/// shown in plan previews, the CLI, and the Audit page.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ItemWarning {
    pub kind: ItemKind,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harness: Option<HarnessId>,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remediation: Option<String>,
}

#[derive(Debug)]
pub struct EngineReport {
    pub drift: Vec<DriftRow>,
    pub plan: Plan,
    pub notes: Vec<String>,
    pub warnings: Vec<ItemWarning>,
    /// What this plan would add to or drop from the installed set.
    pub set_changes: Vec<SetChange>,
    /// Installations this plan leaves alone that nothing needs anymore —
    /// what a removal offers to take with it.
    pub sweepable: Vec<SetChange>,
    /// Members of an uninstalled bundle that stay, and what still accounts
    /// for them — the other half of the preview a bundle removal shows.
    pub kept: Vec<KeptInstall>,
    /// What the safety rules found in the content this plan would write.
    /// Advisory: everything installs, and the rows are worth reading.
    pub safety: Vec<ItemSafety>,
    /// Packages in this plan that change the repository outside the folders
    /// kendex manages. The plan's own lines describe none of this, and the
    /// `apply? [y/N]` that covers those lines does not cover it: the files
    /// land with the rest, and the effect stays pending until it is
    /// authorized on its own.
    pub repo_effects: Vec<crate::repo_effects::DeclaredEffects>,
    /// Packages this plan takes out of the scope that declared an effect
    /// on the repository. Trashing their files undoes none of it, so the
    /// declared uninstaller has to run before the plan does — while the
    /// script it names is still there to run.
    pub repo_effects_leaving: Vec<crate::repo_effects::DeclaredEffects>,
}

/// One name a removal was asked for, with the kind it must be when the
/// caller knew one. `None` names the name alone, which is what the `remove`
/// verb has to go on; a caller that knew the kind never sweeps a same-named
/// item of another kind along with it.
pub type RemovalName = (Option<ItemKind>, String);

#[derive(Debug, Clone, Default)]
pub struct PlanOptions {
    /// Render each agent with the skills its declaration holds and keep the
    /// lock's upstream record as it is, leaving what upstream added since
    /// for the next refresh to merge into kendex.toml. The removal that
    /// keeps declarations sets this: its plan writes no manifest, so a merge
    /// rendered and recorded here would never reach the file.
    pub hold_upstream_skills: bool,
    /// Remove orphaned (locked-but-undeclared) artifacts. Refresh keeps
    /// them (v1 semantics); reconcile and `remove` clean them up.
    pub remove_orphans: bool,
    /// Restrict orphan removal to these names. One list rather than a
    /// typed one beside an untyped one: a caller that set both would have
    /// had one of them silently ignored, and which one won was a rule the
    /// call sites could not see.
    pub removal_filter: Option<Vec<RemovalName>>,
    /// Also remove installations nothing asked for that nothing needs
    /// anymore — a dependency whose last dependent went away, or one an
    /// upstream item stopped requiring.
    pub sweep_unneeded: bool,
    /// Bundles this plan uninstalls. Their members that survive are named in
    /// the preview with what keeps them, so an uninstall says both halves:
    /// what goes, and what stays.
    pub uninstalled_bundles: Vec<String>,
    /// Overwrite installations the user edited by hand. Off, an edited
    /// artifact becomes a conflict and no write touches it; this is the
    /// explicit "discard my edits" everything destructive has to go
    /// through.
    pub overwrite_edited: bool,
    /// Replace files kendex never wrote that sit where a declaration
    /// installs. Off, they are a conflict and no write touches them; on,
    /// each one moves to the trash and the declared render takes its
    /// place. The opposite direction from adopt, which keeps the files and
    /// rewrites the declaration around them. An item with a place the
    /// replacement cannot settle — a foreign link, a source clash —
    /// refuses the whole run, naming each blocked item with the place that
    /// blocks it: half a take-over would leave the rest in the way with
    /// the item no longer its tool's.
    pub replace_unmanaged: bool,
    /// Replace them for these items only, by kind and name — leaving every
    /// other blocked declaration in the scope exactly as it is. The
    /// per-item choice the app offers on the row a person is reading,
    /// which must never reach past the item it names.
    pub replace_unmanaged_names: Option<Vec<(ItemKind, String)>>,
    /// Discard edits for these items only, by kind and name — leaving
    /// every other edited item in the scope held. The per-package
    /// "discard" the app offers, which must never take a neighbour's
    /// edits with it, even one that shares a name across kinds.
    pub overwrite_edited_names: Option<Vec<(ItemKind, String)>>,
    /// Bring these packages current and hold everything else where it is
    /// installed. Each named package — and, for a derived one, every
    /// declaration that accounts for it, since the owner is what carries
    /// its revision — resolves at the source's tip; every other unpinned
    /// remote declaration and bundle is read at the commit its lock
    /// entries record, so a sibling follower does not move as a side
    /// effect. A package the lock cannot place (never installed, or
    /// installations disagreeing on their commit) resolves fresh, which
    /// is what a whole-scope apply does for it anyway. Refresh and the
    /// whole-scope apply never set this.
    ///
    /// A set of them is one pass, not several: `Update all` over a place
    /// with five followers reconciles the scope once instead of planning,
    /// journalling and applying it five times. What the extra targets
    /// change is only which declarations go unpinned — every other
    /// reading is stated per declaration against the pins this pass
    /// invented, so it reads the same whether one package is exempt or
    /// five.
    pub update_only: Option<BTreeSet<(ItemKind, String)>>,
    /// The base of the manifest copy this plan reconciles to, where the
    /// manifest arrived whole from an editor rather than being read here.
    /// The plan's manifest write binds its precondition to it, so a file
    /// that moved after the copy was read is refused by the apply rather
    /// than overwritten. Binding by path after planning cannot do this: a
    /// scope still under the old product name retargets its writes to the
    /// renamed file, and the path the caller knew no longer names them.
    pub manifest_base: Option<crate::base::Base>,
    /// Settings values a person edited, and the base of the settings-file
    /// copy they were read from. A manifest save re-plans the scope and
    /// may seed kendex.settings.toml itself, so these are an input to that
    /// plan rather than a second write after it: one `WriteFile` carries
    /// the seeds and these edits together, under one precondition.
    pub settings_draft: Option<crate::settings_file::SettingsDraft>,
    /// Skills whose settings template this plan applies, by name.
    ///
    /// A template is applied once, when its skill arrives, and arrival is
    /// the manifest gaining the declaration — committed state, in the
    /// consumer's own `kendex.toml`. Only `add` puts a name here, because
    /// only `add` declares one; every other pass leaves this empty and
    /// writes nothing into the consumer's settings file, so a refresh in a
    /// fresh clone re-arrives nothing and a key they deleted stays
    /// deleted.
    pub arriving_skills: BTreeSet<String>,
}

impl PlanOptions {
    /// A plan scoped to one package: it resolves at its source's tip while
    /// every other follower in the scope holds at the commit its lock
    /// records. What every single-package surface asks for — the Updates
    /// page, the package page, a hold move from the app or the CLI.
    pub fn for_package(kind: ItemKind, name: impl Into<String>) -> Self {
        PlanOptions::for_packages([(kind, name.into())])
    }

    /// [`PlanOptions::for_package`] over several packages at once: they
    /// all resolve at their sources' tips and the rest of the scope holds,
    /// in one reconcile and one apply. What `Update all` asks a place for,
    /// having grouped its rows by the scope they live in.
    pub fn for_packages(targets: impl IntoIterator<Item = (ItemKind, String)>) -> Self {
        PlanOptions {
            update_only: Some(targets.into_iter().collect()),
            ..PlanOptions::default()
        }
    }

    /// [`PlanOptions::for_package`] that also discards that package's own
    /// edits. Both fields are set from one pair, so the package whose
    /// edits go and the package that moves can never be different ones.
    pub fn for_package_discarding_edits(kind: ItemKind, name: impl Into<String>) -> Self {
        let target = (kind, name.into());
        PlanOptions {
            overwrite_edited_names: Some(vec![target.clone()]),
            ..PlanOptions::for_packages([target])
        }
    }

    /// Whether the caller named this exact installation for removal: an
    /// instruction about this item, never a judgement about what anything
    /// still wants. Every hold that a removal releases asks it here, so no
    /// two of them can disagree about what the person asked for.
    pub(crate) fn named_for_removal(&self, kind: ItemKind, name: &str) -> bool {
        self.removal_filter.as_ref().is_some_and(|named| {
            named
                .iter()
                .any(|(wanted, n)| n == name && wanted.is_none_or(|wanted| wanted == kind))
        })
    }
}
