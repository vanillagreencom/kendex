//! The types an engine pass hands back — drift rows, warnings, the report
//! itself — and the options a plan is asked with.

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
    /// Blocked rows also appear as conflicts in `drift`; the rest install
    /// and are worth reading first.
    pub safety: Vec<ItemSafety>,
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
    /// Replace files kendex never wrote that sit where a declaration
    /// installs. Off, they are a conflict and no write touches them; on,
    /// each one moves to the trash and the declared render takes its
    /// place. The opposite direction from adopt, which keeps the files and
    /// rewrites the declaration around them.
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
