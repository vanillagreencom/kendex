//! The types an engine pass hands back — drift rows, warnings, the report
//! itself — and the options a plan is asked with.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::apply::Plan;
use crate::model::{HarnessId, ItemKind, Scope};

use super::gate::ItemSafety;
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
/// `Both` are the causes that block writes: the user's bytes are on disk
/// and only an explicit choice may take them.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum DriftCause {
    UpstreamChanged,
    LocalEdit,
    Both,
}

/// What a drift row is about. A package's remedies live on its own page;
/// a file kendex writes beside the packages has no page to open, so a
/// surface that links every row would promise one that is not there.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub enum DriftSubject {
    Package,
    Scope,
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
    pub subject: DriftSubject,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cause: Option<DriftCause>,
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
    /// Blocked rows also appear as conflicts in `drift`; the rest install
    /// and are worth reading first.
    pub safety: Vec<ItemSafety>,
    /// What this plan writes a rendering for. A caller acting on one
    /// package asks here rather than reading the op list: a scope carries
    /// its own maintenance, so ops exist whether or not the package it
    /// named got one — and every reason a package is skipped, refused or
    /// held or unmeasured, leaves the same silence in that list.
    pub rendered: BTreeSet<(ItemKind, String)>,
    /// Everything a restricted plan is about: the packages named, and what
    /// those packages require. Empty where the plan is the whole scope's.
    ///
    /// A caller checking its own package rendered is asking half the
    /// question. A dependency the refreshed declaration pulls in can be
    /// refused on its own account — by the safety gate, or a revision it
    /// cannot settle — and the plan still runs, leaving the package there
    /// and the thing it needs absent. Reporting that as done tells someone
    /// their package is back when it cannot run.
    pub acting: BTreeSet<(ItemKind, String)>,
    /// Declarations this pass could not measure: their source did not
    /// resolve, could not be read, or no longer carries the item, so
    /// nothing was rendered to compare what is on disk against. They are
    /// missing from `drift` for that reason and not because they are
    /// clean — a reader that treats the silence as cleanliness reports an
    /// edited place as untouched.
    pub unmeasured: BTreeSet<(ItemKind, String)>,
}

impl EngineReport {
    /// What this plan is about that it did not render: the packages named,
    /// or anything they require, that nothing here could put back.
    ///
    /// The question a caller must ask before it executes and reports the
    /// package restored. Asking only whether the named package rendered
    /// answers half of it — a dependency the declaration pulls in can be
    /// refused on its own account, and the package comes back unable to
    /// run under a line saying it is fine. Empty for a whole-scope plan,
    /// which is about everything and promises nothing about one package.
    pub fn unrendered(&self) -> Vec<(ItemKind, String)> {
        self.acting.difference(&self.rendered).cloned().collect()
    }
}

#[derive(Debug, Clone, Default)]
pub struct PlanOptions {
    /// Remove orphaned (locked-but-undeclared) artifacts. Refresh keeps
    /// them (v1 semantics); reconcile and `remove` clean them up.
    pub remove_orphans: bool,
    /// Restrict orphan removal to these names (the `remove` verb).
    pub removal_filter: Option<Vec<String>>,
    /// Restrict orphan removal to these exact kind+name pairs (the unsubscribe
    /// closure). Preferred over `removal_filter` where set, so a same-named
    /// orphan of another kind is never swept along.
    pub removal_filter_typed: Option<Vec<(ItemKind, String)>>,
    /// Also remove installations nothing asked for that nothing needs
    /// anymore — a dependency whose last dependent went away, or one an
    /// upstream item stopped requiring.
    pub sweep_unneeded: bool,
    /// Bundles this plan uninstalls. Their members that survive are named in
    /// the preview with what keeps them, so an uninstall says both halves:
    /// what goes, and what stays.
    pub uninstalled_bundles: Vec<String>,
    /// Items whose safety findings the user has read and accepted. Each one
    /// is recorded in the manifest by the same plan that installs it, bound
    /// to the content, rule set and findings that were reviewed.
    pub allow_unsafe: Vec<String>,
    /// Overwrite installations the user edited by hand. Off, an edited
    /// artifact becomes a conflict and no write touches it; this is the
    /// explicit "discard my edits" everything destructive has to go
    /// through.
    pub overwrite_edited: bool,
    /// Discard edits for these items only, by kind and name — leaving
    /// every other edited item in the scope held. The per-package
    /// "discard" the app offers, which must never take a neighbour's
    /// edits with it, even one that shares a name across kinds.
    pub overwrite_edited_names: Option<Vec<(ItemKind, String)>>,
    /// Plan for these items only — them and everything they need, which
    /// `DesiredState` resolves against the expansion and every pass then
    /// asks through `DesiredState::acts_on`. Every other declared item is
    /// carried forward exactly as the lock records it: nothing written for
    /// it and nothing of its taken away, by any pass — the item writes, the
    /// sweep of a path an earlier install left, and the removal a safety
    /// refusal would make. A plan is always the scope's, so a command naming one
    /// package would otherwise install, update and re-render whatever else
    /// the scope had pending, and delete files belonging to packages it
    /// never mentioned. What runs regardless is what belongs to no item:
    /// the manifest kendex maintains for the scope.
    pub only_names: Option<Vec<(ItemKind, String)>>,
    /// The file a whole-manifest write is being made from — set by a caller
    /// writing a copy someone has been holding, so every op in this plan
    /// that writes this scope's manifest binds to it instead of to what the
    /// file was when the plan ran.
    ///
    /// Bound here, where the ops are built, because a plan is not a list of
    /// paths a caller can search afterwards: a scope still under the old
    /// product name has its writes retargeted to the new filename after
    /// planning, and a caller matching the path it knew would find nothing
    /// and leave the write bound to whatever the plan observed.
    pub manifest_base: Option<crate::manifest::Base>,
}

impl PlanOptions {
    /// What a write of this scope's manifest binds to: the file the copy
    /// being written came from, where the caller named one, and otherwise
    /// what the file was when this plan was computed.
    pub fn manifest_pre(&self, path: &std::path::Path) -> crate::error::Result<crate::apply::Pre> {
        match &self.manifest_base {
            Some(base) => Ok(crate::apply::Pre::from(base)),
            None => crate::apply::Pre::observed(path),
        }
    }
}

impl PlanOptions {
    /// Whether the caller named this exact installation for removal: an
    /// instruction about this item, never a judgement about what anything
    /// still wants. Every hold that a typed removal releases asks it here,
    /// so no two of them can disagree about what the person asked for.
    /// The typed pairs win where they are set, so a same-named item of
    /// another kind is never taken along.
    pub(crate) fn named_for_removal(&self, kind: ItemKind, name: &str) -> bool {
        match &self.removal_filter_typed {
            Some(pairs) => pairs.iter().any(|(k, n)| *k == kind && n == name),
            None => self
                .removal_filter
                .as_ref()
                .is_some_and(|names| names.iter().any(|n| n == name)),
        }
    }
}
