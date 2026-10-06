//! The types an engine pass hands back — drift rows, warnings, the report
//! itself — and the options a plan is asked with.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::apply::Plan;
use crate::lock::Lock;
use crate::model::{HarnessId, ItemKind, Scope};

use super::compared::Comparison;
use super::scoring::ItemSafety;
use super::set_change::{KeptInstall, SetChange};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum DriftState {
    /// Declared but not on disk (or never recorded).
    Missing,
    /// On disk but not matching declaration + source.
    Stale,
    /// Recorded in the lock but not declared.
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
    /// What sits at the position could not be read for comparison — a
    /// permission, a device where a file goes. Nothing was judged, so no
    /// exit is on offer: the read is fixed first, and the detail says
    /// where.
    Uncompared,
    /// A copy its catalog retired, kept as recorded because no prune took
    /// it, whose files are gone or edited against that record. Nothing
    /// renders it again, so no refresh writes it and none fails on it: a
    /// prune takes the record, or removing it by name takes the copy.
    Retired,
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
    /// need an explicit choice first — or, for a position that would not
    /// read, a repair — so until one is made the tree on disk is the tree
    /// that was there. Named as the question rather than as a list,
    /// because a caller that lists them is a caller to revisit with every
    /// further cause.
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

    /// Whether this row's detail is a place on disk rather than a
    /// sentence: files where the install goes, or a link kendex will not
    /// follow. A position that would not read names itself and the read's
    /// error in its detail, and moving files settles nothing it says.
    pub fn at_a_position(self) -> bool {
        self.in_the_way() || matches!(self, DriftCause::ForeignLink)
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
    /// The verb that settles this row, where one does.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remedy: Option<RowRemedy>,
}

/// A verb that settles a drift row, acting on the row's own kind and name:
/// data a surface renders, never a command line (engine rule 18).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum RowRemedy {
    /// Removing the item by name takes it, as refresh's sweep does.
    Remove,
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

/// A fork whose installed bytes are its own — the person edited the copy
/// the fork made theirs, and that edit is the fork's content now. Not
/// drift and never a conflict: apply keeps the bytes and records them, so
/// nothing has to be decided. The Library reads it as the "edited" half of
/// a fork's state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForkEdit {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
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

/// Whether the pass could account for the full declared installation set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DeclarationStatus {
    #[default]
    Complete,
    Incomplete,
}

impl DeclarationStatus {
    pub(super) fn of(state: &super::desired::DesiredState) -> Self {
        if state.declaration_status == Self::Complete
            && state.refused.is_empty()
            && state.unreadable_catalogs.is_empty()
            && state.rev_conflicts.is_empty()
        {
            Self::Complete
        } else {
            Self::Incomplete
        }
    }
}

/// One installation this pass derived from the scope's declarations, by
/// kind, name and harness, and the positions it occupies. What the record
/// should hold an entry for, and where `verify` says each row sits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Installation {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub positions: Vec<super::desired::Position>,
}

/// A catalog hook the plan wrote nothing for on a tool its own harnesses
/// line leaves out, where the person's declaration of it does not name that
/// tool. Expected state rather than a finding: the hook's header says it
/// does not run there, and nothing the person wrote asked otherwise.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExcludedHook {
    pub name: String,
    pub harness: HarnessId,
}

/// A hook's `harnesses` pin in kendex.toml, on a declaration or a
/// `[[custom-hooks]]` entry, deciding one tool against what the hook would
/// get with no pin. Either way the remedy is
/// the pin's: drop it, or change the tool's place in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinnedHook {
    pub name: String,
    pub harness: HarnessId,
    pub pin: Pin,
}

/// What a hook's pin does on one tool.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pin {
    /// Leaves out a tool kendex would write the hook to with no pin. That
    /// says where the hook is written, not that the tool fires it.
    LeavesOut,
    /// Names a tool the hook's own harnesses line leaves out, where the
    /// hook is written nowhere whatever the pin says.
    NamesExcluded,
}

#[derive(Debug)]
pub struct EngineReport {
    pub declaration_status: DeclarationStatus,
    /// Declared installations withheld by the engine, with a typed reason.
    pub refused: Vec<super::desired::Refused>,
    pub drift: Vec<DriftRow>,
    pub plan: Plan,
    pub notes: Vec<String>,
    pub warnings: Vec<ItemWarning>,
    /// Catalog hooks left off a tool by their own harnesses line alone.
    /// A declaration that names the tool gets a `kendex-hook-excluded`
    /// note in `notes` instead, and a `pinned_hooks` row where the plan
    /// judges pins.
    pub excluded_hooks: Vec<ExcludedHook>,
    /// Each tool a hook's pin, on a declaration or a `[[custom-hooks]]`
    /// entry, decides against the hook's own reading; `verify` names every
    /// one. Empty unless the plan was asked to judge pins
    /// (`PlanOptions::judge_pins`).
    pub pinned_hooks: Vec<PinnedHook>,
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
    /// write consent that covers those lines does not cover it: the files
    /// land with the rest, and the effect stays pending until it is
    /// authorized on its own.
    pub repo_effects: Vec<crate::repo_effects::DeclaredEffects>,
    /// Packages this plan takes out of the scope that declared an effect
    /// on the repository. Trashing their files undoes none of it, so the
    /// declared uninstaller has to run before the plan does — while the
    /// script it names is still there to run.
    pub repo_effects_leaving: Vec<crate::repo_effects::DeclaredEffects>,
    /// Every instruction shim the scope owes and where it stands, in sync
    /// ones included. Drift rows carry only what is not in sync; `verify`
    /// reports each shim as a row of its own beside the lock rows.
    pub instruction_shims: Vec<super::ShimStanding>,
    /// The forks this pass found edited on disk. They are not in `drift`:
    /// there is nothing to fix and nothing to decide.
    pub fork_edits: Vec<ForkEdit>,
    /// The commit each declared revision resolved to this pass, by source
    /// name and the revision a declaration pins (`None` at the source's
    /// own), whether or not the plan writes a record — a pass that refuses
    /// every install writes none, and a line naming what a refused install
    /// was measured against still has to say which commit that was.
    pub resolved_sources: BTreeMap<(String, Option<String>), crate::lock::SourceRev>,
    /// The installations whose Missing row is a deletion of a rendering the
    /// record says stood there; the Updates read says it as `files_missing`.
    pub recorded_gone: Vec<RecordedGone>,
    /// The paths this pass renders into the scope, split into the files
    /// kendex owns whole and the shared configuration files it writes one
    /// key in. The inventory is written from it, and the commit offer
    /// covers the whole-file group and reads the rest as files it writes
    /// into — one collection, so the two cannot name different files.
    pub generated: super::GeneratedPaths,
    /// The settings edits each registration this pass plans is, by lock
    /// entry key, as the pass held them in place: a record write for an
    /// entry this pass proved holds them in place again before it writes.
    pub registrations: Registrations,
    /// Every installation the scope's declarations derive this pass, by
    /// lock entry key, with the positions the engine resolved for it: the
    /// items the plan built, and each declared Pi extension at the package
    /// directory the carrier installs it under. A recorded entry outside
    /// this set is one nothing declares; a key here with no entry is one
    /// the record does not hold.
    pub installations: BTreeMap<String, Installation>,
    /// The recorded sources and sets this pass could not hold to a
    /// resolution of its own. A proof over the record refuses each by name.
    pub stood_in: StoodInRecord,
    /// The record this pass computed, whether or not the plan writes it:
    /// what a proof holds the committed record to. Empty on a report
    /// observed rather than planned, which nothing proves a record by.
    pub record: Lock,
    /// The commits a held plan read declarations at in place of their
    /// sources' revisions, each taken from the record. Empty on a plan
    /// that holds nothing.
    pub held: Vec<HeldPin>,
    /// The paths each enabled agent this pass places on at least one
    /// harness names as tracked output in its own definition, by agent
    /// name. `verify` holds them against the project's ignore rules
    /// (`tracked_output`).
    pub tracked_outputs: BTreeMap<String, Vec<String>>,
    /// Items their catalog retired (`PlanOptions::prune_retired`): the plan
    /// writes nothing for them, so the record owes a declaration of one no
    /// entry.
    pub retired: BTreeSet<(ItemKind, String)>,
    /// Each hook the plan writes nowhere on a tool because a hook it runs
    /// with will not run there, and why (`DesiredState::withheld`).
    pub withheld: BTreeMap<(ItemKind, String, HarnessId), super::desired::Withholding>,
}

/// One declaration a held plan read at the commit the record names
/// rather than at its source's revision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldPin {
    pub held: Held,
    /// The declared source it reads from.
    pub source: String,
    /// The repository that source points at, spelled as the record's
    /// `sourceRepo` spells it.
    pub repo: String,
    pub commit: String,
}

/// One declaration in the manifest, an item's or a set's: what a held pin
/// holds, and what a targeted update brings current.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Held {
    Item { kind: ItemKind, name: String },
    Set { name: String },
}

impl std::fmt::Display for Held {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Held::Item { kind, name } => write!(f, "{} {name}", kind.name()),
            Held::Set { name } => write!(f, "set {name}"),
        }
    }
}

/// Each source and set the record carries that a pass could not hold to a
/// resolution of its own, by name, and why. Every declared source is read
/// once a pass, the ones no item names included, and each set at its own
/// pin where it has one, so an entry is measured against that reading and
/// never against itself carried forward; one read to no fresh commit is
/// named here.
#[derive(Debug, Default)]
pub struct StoodInRecord {
    pub sources: BTreeMap<String, StoodIn>,
    pub sets: BTreeMap<String, StoodIn>,
}

/// Why a recorded source's or set's entry was not held to a fresh
/// resolution this pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoodIn {
    /// The mirror could not serve the declared revision, and the root was
    /// reached through the commit the record last resolved: everything
    /// rendered from it was measured against a commit the record chose.
    RecordedCommit,
    /// The mirror could not serve the declared revision, or nothing is
    /// fetched for it, so the pass resolved nothing and the record's entry
    /// was carried forward unread.
    Unserved,
}

impl EngineReport {
    /// Hook deliveries that fail because a declared harness cannot run
    /// their event. Render refusals, exclusions and advisory notices are
    /// not incomplete hook deliveries.
    pub fn failed_hook_deliveries(&self) -> impl Iterator<Item = &super::desired::Refused> {
        self.refused.iter().filter(|refused| match refused.refusal {
            super::desired::RefusalKind::UnsupportedHookEvent => true,
            super::desired::RefusalKind::Render => false,
        })
    }

    /// A report carrying `plan` and nothing else: no drift, no
    /// derivation, every declaration complete. What a caller that planned
    /// its ops outside the engine, or read a scope back after a write,
    /// hands to the readers that take a report. `Plan` is built fallibly
    /// through [`Plan::landed`], which is why the plan is the one argument
    /// rather than a default.
    pub fn observed(plan: Plan) -> EngineReport {
        EngineReport {
            declaration_status: DeclarationStatus::Complete,
            refused: Vec::new(),
            drift: Vec::new(),
            plan,
            notes: Vec::new(),
            warnings: Vec::new(),
            excluded_hooks: Vec::new(),
            pinned_hooks: Vec::new(),
            set_changes: Vec::new(),
            sweepable: Vec::new(),
            kept: Vec::new(),
            safety: Vec::new(),
            repo_effects: Vec::new(),
            repo_effects_leaving: Vec::new(),
            instruction_shims: Vec::new(),
            fork_edits: Vec::new(),
            resolved_sources: BTreeMap::new(),
            recorded_gone: Vec::new(),
            generated: super::GeneratedPaths::default(),
            registrations: Registrations::default(),
            installations: BTreeMap::new(),
            stood_in: StoodInRecord::default(),
            record: Lock::default(),
            held: Vec::new(),
            tracked_outputs: BTreeMap::new(),
            retired: BTreeSet::new(),
            withheld: BTreeMap::new(),
        }
    }

    /// What the plan says of an item it withholds from every one of
    /// `harnesses` for a reason that takes its copy
    /// ([`super::desired::Withholding::said`]), the reason that outranks
    /// the rest where tools differ. `None` where any of them is not so
    /// withheld, since the plan still writes the item there, and for no
    /// tools at all.
    pub fn withheld_said(
        &self,
        kind: ItemKind,
        name: &str,
        harnesses: &[HarnessId],
    ) -> Option<&'static str> {
        let mut strongest = None;
        for harness in harnesses {
            let because = *self.withheld.get(&(kind, name.to_owned(), *harness))?;
            because.said()?;
            strongest = strongest.max(Some(because));
        }
        strongest.and_then(super::desired::Withholding::said)
    }

    /// Whether the plan writes this package on none of the tools it is
    /// planned for, each one left out by the hook's own harnesses line
    /// alone ([`ExcludedHook`]). Nothing is recorded for such a package,
    /// so a reader holding the record to the declarations passes it over.
    ///
    /// A package planned for no tool at all is not left out by its own
    /// line, and answers `false`: that is a declaration nothing can hold,
    /// which the plan reports on its own.
    pub fn left_out_by_own_line(
        &self,
        kind: ItemKind,
        name: &str,
        harnesses: &[HarnessId],
    ) -> bool {
        let hook = match kind {
            ItemKind::Hook => true,
            ItemKind::Agent
            | ItemKind::Skill
            | ItemKind::Command
            | ItemKind::McpServer
            | ItemKind::PiExtension
            | ItemKind::Plugin
            | ItemKind::OutputStyle => false,
        };
        hook && !harnesses.is_empty()
            && harnesses.iter().all(|harness| {
                self.excluded_hooks
                    .iter()
                    .any(|excluded| excluded.name == name && excluded.harness == *harness)
            })
    }
}

/// The settings edits registrations are, by the lock entry key of the
/// installation that registers them, in the order the pass walks its
/// items. A list rather than a map because that order is the order the
/// edits land in a shared file: the writer collects each file's edits
/// item by item, and a reader rebuilding the file from a revision that
/// never held it has to apply them the same way round, or two keys
/// created by two registrations come out swapped.
pub type Registrations = Vec<(
    String,
    Vec<(std::path::PathBuf, crate::configedit::ConfigEdit)>,
)>;

/// An installation `EngineReport::recorded_gone` names, by kind and name.
pub type RecordedGone = (ItemKind, String);

/// One name a removal was asked for, with the kind it must be when the
/// caller knew one. `None` names the name alone, which is what the `remove`
/// verb has to go on; a caller that knew the kind never sweeps a same-named
/// item of another kind along with it.
pub type RemovalName = (Option<ItemKind>, String);

#[derive(Debug, Clone, Default)]
pub struct PlanOptions {
    /// Render each agent with the skills its declaration holds and keep the
    /// lock's upstream record as it is, leaving what upstream gained since
    /// for the next refresh to merge into kendex.toml. The removal that
    /// keeps declarations sets this: its plan writes no manifest, so a merge
    /// rendered and recorded here would never reach the file.
    pub hold_upstream_skills: bool,
    /// Remove orphaned (locked-but-undeclared) artifacts, limited by
    /// `removal_filter` when present. Apply selects all orphans and
    /// `remove` selects the names requested.
    pub remove_orphans: bool,
    /// Restrict orphan removal to these names. One list rather than a
    /// typed one beside an untyped one: a caller that set both would have
    /// had one of them silently ignored, and which one won was a rule the
    /// call sites could not see.
    pub removal_filter: Option<Vec<RemovalName>>,
    /// Also remove installations nothing asked for that nothing needs
    /// anymore — a dependency whose last dependent went away, or one an
    /// upstream item stopped requiring. An unfiltered sweep, refresh's,
    /// also takes every record of any kind nothing declares or derives
    /// anymore, an edited copy held as the edit conflict. An item its
    /// catalog retired is not among them unless `prune_retired` says so.
    pub sweep_unneeded: bool,
    /// Remove every item its catalog retired (`[retired]`), of every kind:
    /// its files, its records and its own manifest table, an edited copy
    /// held as the edit conflict. Off, a retired item stays exactly where
    /// the record holds it, except a hook withheld beside a hook its record
    /// requires, with one notice saying how to remove it, and is
    /// owed nothing where it holds none; either way it is never rendered
    /// again, and an armed hook requiring it is withheld where it requires
    /// it, by the rule in docs/authoring/README.md's `[retired]` paragraph.
    /// `refresh --prune` sets it.
    pub prune_retired: bool,
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
    /// the item not its tool's any more.
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
    /// is what a whole-scope apply does for it anyway. The whole-scope
    /// apply never sets this, and refresh sets it only as
    /// [`PlanOptions::locked`].
    ///
    /// A set of them is one pass, not several: `Update all` over a place
    /// with five followers reconciles the scope once instead of planning,
    /// journalling and applying it five times. What the extra targets
    /// change is only which declarations go unpinned — every other
    /// reading is stated per declaration against the pins this pass
    /// invented, so it reads the same whether one package is exempt or
    /// five.
    ///
    /// A set named here comes current itself, its members with it, where an
    /// add names a set the scope already installs. How far a named item's
    /// exemption reaches is [`Targets::reach`].
    pub update_only: Option<Targets>,
    /// Keep the record's commit for each source the plan's own reads did
    /// not resolve at the source's own revision, rather than recording
    /// what its mirror resolves to now. Under a hold naming no package,
    /// only a declaration the record cannot place reads there, and its
    /// source's record moves to what the plan read; every other source
    /// keeps the record's account of where it sits, unless it is now
    /// declared at another repository or revision than that account was
    /// written for. The Pi settle resolves outside the plan, so a Pi
    /// package the record cannot place installs and records its own entry
    /// at the source's tip while its source's entry is kept. Only
    /// [`PlanOptions::locked`] sets this: `verify --at-record` weighs the
    /// record against where each source resolves now, and reads that off
    /// the record this pass would write. A write also reads fresh a
    /// declaration held at a commit this machine cannot read, where
    /// `verify --at-record` keeps it held: skipped, the write would de-list
    /// its renders.
    pub keep_source_records: bool,
    /// The base of the manifest copy this plan reconciles to, where the
    /// manifest arrived whole from an editor rather than being read here.
    /// The plan's manifest write binds its precondition to it, so a file
    /// that moved after the copy was read is refused by the apply rather
    /// than overwritten. Binding by path after planning cannot do this: a
    /// scope still under the old product name retargets its writes to the
    /// renamed file, and the path the caller knew does not name them.
    pub manifest_base: Option<crate::base::Base>,
    /// Settings values a person edited, and the base of the settings-file
    /// copy they were read from. A manifest save re-plans the scope and
    /// may seed kendex.settings.toml itself, so these are an input to that
    /// plan rather than a second write after it: one `WriteFile` carries
    /// the seeds and these edits together, under one precondition.
    pub settings_draft: Option<crate::settings_file::SettingsDraft>,
    /// Values an install supplies for declared keys, by key. Planned with
    /// the seeds and edits as the same one write, and only for a key the
    /// file assigns nowhere: an assigned value is the consumer's.
    pub supplied_settings: Vec<crate::settings_file::SuppliedSetting>,
    /// Credentials a person typed, the private file they are destined
    /// for, and the base of the copy that file was read as. A separate
    /// draft from the settings one because the two write different files
    /// under different rules: a secret never reaches the tracked settings
    /// file, and the private file is never seeded.
    pub secrets_draft: Option<crate::settings_secret::SecretsDraft>,
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
    /// Judge each hook's `harnesses` pin against what the hook would get
    /// with no pin, into `EngineReport::pinned_hooks`. Off, that list is
    /// empty. Only verify reads it, and judging a pin walks the pinned
    /// hook's requirements again, so every other plan leaves this off.
    pub judge_pins: bool,
}

/// The declarations a plan scoped to some packages brings current, and how
/// far that reaches past them: [`PlanOptions::update_only`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Targets {
    pub declarations: BTreeSet<Held>,
    pub reach: Reach,
}

/// What reads fresh with a named item beside its own declaration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// A targeted update: whatever carries the item's revision too, the
    /// declaration that required it and the sets that carry it, since a
    /// dependency cannot move while what it reads its bytes through holds.
    Carriers,
    /// An add: the declarations it writes and nothing else. A package that
    /// required the item before the add is not what the person named, and
    /// stays at the commit its record names.
    Declared,
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
            update_only: Some(Targets {
                declarations: targets
                    .into_iter()
                    .map(|(kind, name)| Held::Item { kind, name })
                    .collect(),
                reach: Reach::Carriers,
            }),
            ..PlanOptions::default()
        }
    }

    /// A plan that names no package: every follower the record can place
    /// holds at the commit its lock entries record, so a re-render reads
    /// what is installed; one it cannot place resolves fresh, as
    /// [`PlanOptions::update_only`] says. What `verify --at-record` checks
    /// against.
    pub fn at_record() -> Self {
        PlanOptions::for_packages([])
    }

    /// [`PlanOptions::at_record`] for a write: the record also keeps where
    /// it says each source sits, so a re-render of a project-side change
    /// moves no catalog the record places. What `refresh --locked` writes.
    pub fn locked() -> Self {
        PlanOptions {
            keep_source_records: true,
            ..PlanOptions::at_record()
        }
    }

    /// The plan an add makes: the items and the sets it declares come
    /// current, and nothing else moves ([`Reach::Declared`]).
    pub fn for_additions(declarations: impl IntoIterator<Item = Held>) -> Self {
        PlanOptions {
            update_only: Some(Targets {
                declarations: declarations.into_iter().collect(),
                reach: Reach::Declared,
            }),
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
        named_in(self.removal_filter.as_deref(), kind, name)
    }
}

/// [`PlanOptions::named_for_removal`] over the filter alone, for the pass
/// that holds the filter without the options (`DesiredState`).
pub(crate) fn named_in(filter: Option<&[RemovalName]>, kind: ItemKind, name: &str) -> bool {
    filter.is_some_and(|named| {
        named
            .iter()
            .any(|(wanted, n)| n == name && wanted.is_none_or(|wanted| wanted == kind))
    })
}
