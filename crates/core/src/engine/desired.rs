use serde::{Deserialize, Serialize};
use specta::Type;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::Result;
use crate::hash::{hash_bytes, hash_files};
use crate::lock::Lock;
use crate::manifest::{self, ItemDecl, Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::{SourceConfig, SourceState, list_items};
use crate::source_read::SealedSource;

use super::desired_item::{build, no_harness_note};
use super::desired_kinds;
use super::desired_source::{read_catalog, resolve_source};
use super::expansion::{Offer, OpenCatalog};

type RenderedFiles<'a> = (&'a Path, Vec<(PathBuf, Vec<u8>)>);

/// One installation as declaration says it should exist on disk.
#[derive(Debug, Clone, PartialEq)]
pub struct Desired {
    pub key: String,
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub enabled: bool,
    pub method: Method,
    pub source_name: String,
    pub provenance: String,
    /// The source commit this item's bytes came from, when the source is a
    /// remote — the item's own pin when it has one, the source resolution
    /// otherwise. The lock records it; the Updates page reads it back.
    pub source_commit: Option<String>,
    /// The manifest records this item as a fork: its rebind from a remote
    /// to the local source is the recorded outcome of forking, not a
    /// provenance clash.
    pub recorded_fork: bool,
    pub hash: String,
    /// The one clone-portable identity persisted as `renderedHash`.
    pub rendered_hash: Option<String>,
    /// The catalog file this rendering came from. `None` for an
    /// installation no catalog file backs: a plugin switch, a hook whose
    /// command the declaration itself carries.
    pub source: Option<CatalogSource>,
    pub upstream_skills: Option<Vec<String>>,
    /// Whole-file positions the artifact writes. The lock records them so
    /// ownership and removal use the written locations, not today's layout.
    pub emitted: Option<crate::lock::EmittedArtifact>,
    /// Every reason this installation is wanted, derived fresh each pass.
    pub reasons: BTreeSet<crate::lock::Reason>,
    pub artifact: Artifact,
}

/// Where a rendering's bytes came from in the catalog, and whether the
/// rendering is those bytes unchanged.
///
/// A plan scores what it would write, and writing is not always copying:
/// an agent is restated in each tool's own words, a skill can carry the
/// instructions the project adds to it. The path is worth citing either
/// way — it is a file the reader can open while the destination does not
/// exist yet, and `check --catalog` names the same one — but a line read
/// off the rendering is a line of that file only where the two are the
/// same bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CatalogSource {
    /// The item's path within the catalog, `/`-spelled.
    pub path: String,
    /// Whether the rendering is the catalog's bytes unchanged, which is
    /// what makes a line read off the rendering a line of `path`.
    pub verbatim: bool,
    /// Whether the catalog holds this item as a directory. A place inside
    /// a rendering maps back onto `path` only where the catalog has a
    /// tree to hold it: a single file rendered into a tree — a command a
    /// harness stores as a skill — has no `/SKILL.md` inside itself, and
    /// joining one on would name a path that does not exist.
    pub tree: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Artifact {
    /// A generated file (agents). Disabled installations keep the rendered
    /// content under the `.disabled` name — rename is lossless.
    File { path: PathBuf, bytes: Vec<u8> },
    /// A rendered tree plus the harness-native link to it. `link` is `None`
    /// where the native dir is the canonical location (codex/pi project) or
    /// the method is copy.
    Tree {
        canonical: PathBuf,
        files: Vec<(PathBuf, Vec<u8>)>,
        link: Option<PathBuf>,
        /// Whether `canonical` is the person's in-place source itself, so
        /// kendex writes its project-instructions block and its link there
        /// and no other byte, and records no rendered hash for it. Decided
        /// once where the artifact is built — an in-place declaration
        /// delivered by copy renders a tree of its own, which is not the
        /// source — and read everywhere the answer matters, so no pass can
        /// answer it differently.
        in_place: bool,
    },
    /// An entry inside shared harness config, optionally backed by a script
    /// or instruction file. Each edit is in sync exactly when re-applying it
    /// changes nothing — that idempotency is the drift check, and it is what
    /// keeps every unrelated key in those files intact (invariant 2).
    Registration {
        script: Option<(PathBuf, Vec<u8>)>,
        edits: Vec<(PathBuf, crate::configedit::ConfigEdit)>,
    },
}

/// One place an artifact occupies, and how much of it kendex owns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Position {
    pub path: PathBuf,
    pub owns: Owns,
}

/// How much of a position kendex owns: the whole file, the whole tree, or
/// keys inside a file whose other keys are the person's (invariant 2).
///
/// `verify` prints each position with this, and a reader owning changed
/// paths from those rows reads a `Keys` position as proved only where the
/// row also says the rest of the file did not move; the owner rule for the
/// harness registry files is stated here and nowhere else.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Owns {
    /// A file kendex writes end to end, or the link a tool reads a tree
    /// through.
    File,
    /// A directory tree kendex writes end to end.
    Tree,
    /// Keys inside a shared configuration file: a hook registry, a
    /// settings file, an MCP server list. kendex writes its own entries
    /// and never the file, so the position is partial.
    Keys,
}

impl Artifact {
    /// Every place the artifact occupies, with how much of each kendex
    /// owns. The one answer to where an installation sits: `paths` is
    /// read off it, the inventory's whole-file and shared groups are read
    /// off it in `generated_paths.rs` with each tree spelled as its
    /// rendered files, and `verify` prints it per row.
    pub fn positions(&self) -> Vec<Position> {
        let whole = |path: &PathBuf, owns| Position {
            path: path.clone(),
            owns,
        };
        match self {
            Artifact::File { path, .. } => vec![whole(path, Owns::File)],
            Artifact::Tree {
                canonical, link, ..
            } => {
                let mut positions = vec![whole(canonical, Owns::Tree)];
                positions.extend(link.iter().map(|link| whole(link, Owns::File)));
                positions
            }
            Artifact::Registration { script, edits } => script
                .iter()
                .map(|(path, _)| whole(path, Owns::File))
                .chain(edits.iter().map(|(path, _)| whole(path, Owns::Keys)))
                .collect(),
        }
    }

    /// Every path the artifact occupies, the shared files a registration
    /// writes keys in included. Cursor keeps hook rules in the same dir as
    /// agents and codex shares skill trees with pi: without this, the
    /// scanner reports content we just wrote as someone else's.
    pub fn paths(&self) -> Vec<PathBuf> {
        self.positions()
            .into_iter()
            .map(|position| position.path)
            .collect()
    }

    /// Whole files written by this artifact, excluding shared config keys.
    /// Skill trees retain their separate in-place source exclusion.
    pub(super) fn emitted(
        &self,
        kind: ItemKind,
        name: &str,
    ) -> Option<crate::lock::EmittedArtifact> {
        let paths: Vec<_> = self
            .positions()
            .into_iter()
            .filter_map(|position| match position.owns {
                Owns::File | Owns::Tree => Some(position.path),
                Owns::Keys => None,
            })
            .collect();
        (!paths.is_empty()).then(|| crate::lock::EmittedArtifact {
            kind,
            name: name.to_owned(),
            paths,
        })
    }

    /// The command this artifact registers, if it registers one. What makes
    /// a hook entry ours is the command it runs — the registration edits
    /// own it by that exact string, so anything asking "did kendex write
    /// this entry" asks about the command.
    pub fn registered_command(&self) -> Option<String> {
        let Artifact::Registration { edits, .. } = self else {
            return None;
        };
        edits.iter().find_map(|(_, edit)| match edit {
            crate::configedit::ConfigEdit::UpsertHook { command, .. }
            | crate::configedit::ConfigEdit::UpsertCopilotHook { command, .. }
            | crate::configedit::ConfigEdit::UpsertAntigravityHook { command, .. } => {
                Some(command.clone())
            }
            _ => None,
        })
    }

    /// The on-disk hash the artifact will have — for clean/dirty
    /// comparison. A registration's config edits are compared by
    /// re-applying them, not by hash; only its backing file has one.
    pub fn disk_hash(&self) -> String {
        match self {
            Artifact::File { bytes, .. } => hash_bytes(bytes),
            Artifact::Tree { files, .. } => hash_files(files),
            Artifact::Registration { script, .. } => match script {
                Some((_, bytes)) => hash_bytes(bytes),
                None => hash_bytes(&[]),
            },
        }
    }

    /// Files whose bytes form the artifact's rendered identity. Shared
    /// registration documents are excluded; only a backing script is ours.
    fn rendered_files(&self) -> Option<RenderedFiles<'_>> {
        match self {
            Artifact::File { path, bytes } => Some((path, vec![(PathBuf::new(), bytes.clone())])),
            Artifact::Tree {
                canonical, files, ..
            } => Some((canonical, files.clone())),
            Artifact::Registration {
                script: Some((path, bytes)),
                ..
            } => Some((path, vec![(PathBuf::new(), bytes.clone())])),
            Artifact::Registration { script: None, .. } => None,
        }
    }

    pub(super) fn rendered_hash(&self) -> Option<String> {
        self.rendered_files().map(|(destination, files)| {
            crate::hash::RenderedIdentity::rendered(destination, &files)
                .persisted()
                .to_owned()
        })
    }
}

/// A declared installation the engine cannot deliver. The plan turns each
/// into a conflict row and removes the previous unedited installation.
#[derive(Debug, Clone, PartialEq)]
pub struct Refused {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub refusal: RefusalKind,
    pub reason: String,
}

/// The engine's reason for withholding a declared installation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalKind {
    /// The item's rendered content, configuration or name cannot load.
    Render,
    /// The declared harness cannot run the hook's event.
    UnsupportedHookEvent,
}

#[derive(Debug, Default)]
pub struct DesiredState {
    pub(super) agent_names: crate::source::agent_names::Uses,
    pub declaration_status: super::DeclarationStatus,
    pub items: Vec<Desired>,
    /// Sources that could not be read (pending remotes, missing paths) and
    /// declared items the source does not carry.
    pub notes: Vec<String>,
    pub warnings: Vec<super::ItemWarning>,
    /// Catalog hooks their own harnesses line keeps off a tool nothing the
    /// person wrote asks them onto; `EngineReport::excluded_hooks`.
    pub excluded_hooks: Vec<super::ExcludedHook>,
    /// Each tool a declared hook's pin or a `[[custom-hooks]]` entry's
    /// `harnesses` list decides, where `judge_pins` asks;
    /// `EngineReport::pinned_hooks`.
    pub pinned_hooks: Vec<super::PinnedHook>,
    /// Whether this pass judges hook pins (`PlanOptions::judge_pins`):
    /// fills `pinned_hooks`, and has the walk ask each pinned hook again
    /// with its pin dropped (`withheld_past_pin`).
    pub judge_pins: bool,
    pub refused: Vec<Refused>,
    /// Why each package this pass rendered, or tried to, is wanted, by
    /// kind and name, as the closure derived it on every tool it planned.
    /// A package refused everywhere has no item to carry its reasons, so
    /// they live here; `EngineReport::wanted`.
    pub(super) derived: BTreeMap<(ItemKind, String), BTreeSet<crate::lock::Reason>>,
    /// Declarations whose source resolved and whose item was found and
    /// read, each with the provenance it is planned under. What these
    /// produced is the complete truth about them, so a lock entry they did
    /// not produce is stranded, not merely skipped this pass — or, where
    /// another catalog installed it, invariant 4's conflict
    /// (`plan_pass::plan_rebound`).
    pub processed: BTreeMap<(ItemKind, String), String>,
    /// Items their catalog retired that this pass met, declared or derived
    /// ([`DesiredState::retire`]); `EngineReport::retired`.
    pub retired: BTreeMap<(ItemKind, String), Retirement>,
    /// Whether this pass prunes retired items (`PlanOptions::prune_retired`).
    pub prune_retired: bool,
    /// What this pass removes by name (`PlanOptions::removal_filter`): a
    /// retired item named there is not kept ([`DesiredState::kept_as_recorded`]).
    pub(super) removal_filter: Option<Vec<super::report_types::RemovalName>>,
    /// Declared sets this pass could not expand whose installed members it
    /// keeps as recorded, each with why.
    pub(super) kept_bundles: BTreeMap<crate::lock::BundleRef, KeptBundle>,
    /// The records a set in `kept_bundles` keeps, its members and what
    /// they require, by entry key, each with the edges tying it to them it
    /// was recorded under (`bundles::kept_members`). The item pass adds
    /// those edges to what it writes for one of them, `plan_pass::plan_kept_members` keeps
    /// every other one before anything is taken, `removal::orphans` takes
    /// a hook among them whose companion goes, and the inventory keeps the
    /// rows of what stays (`generated_paths::Unrendered`).
    pub(super) kept_members: BTreeMap<String, BTreeSet<crate::lock::Reason>>,
    /// Declared sets their catalog retired, under a prune:
    /// `settle_retired` drops each declaration.
    pub(super) pruned_bundles: BTreeSet<String>,
    /// The entry keys of the record this pass read: where a retired item
    /// is kept ([`Retirement::kept`]).
    pub(super) recorded: BTreeSet<String>,
    /// What each switched-on installation in that record required on its
    /// tool when it was written, read off its companions' `RequiredBy`
    /// reasons: what a retired hook kept as recorded still runs with,
    /// which the walk derives none of (`deps::withhold_kept_retired`).
    pub(super) recorded_requires:
        BTreeMap<(ItemKind, String, HarnessId), BTreeSet<(ItemKind, String)>>,
    /// Manifest with upstream skill additions merged in — present only when
    /// the merge changed something and must be written back.
    pub manifest_update: Option<Manifest>,
    /// `[env]` defaults shipped by enabled skills
    /// (kendex.settings.toml.example), every declaration in skill-name
    /// order — each with the skill that ships it, incomplete values
    /// included, because a key nothing can supply is reported by name.
    ///
    /// The one list every write of these keys and every note about them
    /// reads. Where several skills declare one key, what lands is the
    /// first declaration the pass admits, which is not always the first
    /// declaration.
    pub settings_env: Vec<crate::settings_seed::SeededEnv>,
    /// Where each planned skill's settings template stands: read, absent,
    /// or out of reach. `settings_env` is this same text run through the
    /// lenient reader seeding needs; the settings view reads the text
    /// itself, strictly, and needs to tell a skill that ships nothing
    /// apart from one nothing could be read for. Project scope only — a
    /// global install seeds nothing.
    pub settings_templates: BTreeMap<String, crate::settings_template::TemplateSource>,
    /// What each source an item names resolved to. One resolution per
    /// source per pass: resolving a remote reads its checkout to confirm
    /// nothing has altered it, which is worth doing once and wasteful to
    /// repeat for every item the source carries.
    pub sources: BTreeMap<String, SourceState>,
    /// Sources whose catalog resolved and then answered with less than it
    /// offers — an unusable control file, a set whose body will not read.
    /// What one derived this pass is short through no choice of the
    /// person's, so no removal is decided on it.
    pub unreadable_catalogs: BTreeSet<String>,
    /// Resolutions for item-level pins, keyed `(source, rev)` — kept apart
    /// from `sources` so the lock's per-source record never picks up a
    /// commit only one pinned item reads.
    pub pinned: BTreeMap<(String, String), SourceState>,
    /// Items wanted at two different revisions at once. One filesystem
    /// identity exists, so nothing is written for these: the plan reports
    /// the conflict and leaves what is installed alone.
    pub rev_conflicts: BTreeSet<(ItemKind, String)>,
    /// Hooks not written on a tool because a hook they run with will not
    /// run there, for any reason `desired_kinds::not_written` names: a
    /// companion the hook requires, or every requirer a derived companion
    /// exists for, or a companion whose catalog does not answer. The walk
    /// decides each about the declaration the plan writes
    /// (`deps::wanted_by`), so the planner leaves the hook out on that tool
    /// and the finding the walk pushed says why. What becomes of a copy
    /// already installed there is the reason's ([`Withholding`]), behind
    /// invariant 4's conflict where the record is another catalog's
    /// (`plan_pass::plan_rebound`).
    pub withheld: BTreeMap<(ItemKind, String, HarnessId), Withholding>,
    /// For each hook and tool withheld for a retirement
    /// ([`Withholding::Retired`]), the companions it runs with there whose
    /// standing it took that reason from: a retired hook, a requirer
    /// withheld for one, or what a kept retired hook's record requires.
    /// The removal pass reads each one's own verdict to say whether the
    /// hook still has it (`removal::settle_lacking`).
    pub(super) retired_companions:
        BTreeMap<(ItemKind, String, HarnessId), BTreeSet<(ItemKind, String)>>,
    /// Hooks whose pin keeps them off a tool where the walk, asked again
    /// with that pin dropped, withholds them (`deps::withheld_past_pin`);
    /// empty unless `judge_pins` is set.
    /// It plans nothing: read only by the pin records
    /// (`desired_kinds::pin_records`), so a pin is never said to keep a
    /// hook off a tool it could not run on anyway.
    pub withheld_past_pin: BTreeSet<(ItemKind, String, HarnessId)>,
    /// The paths each enabled agent this pass places on at least one
    /// harness declares as tracked output, by agent name;
    /// `EngineReport::tracked_outputs`.
    pub tracked_outputs: BTreeMap<String, Vec<String>>,
}

/// Why a declared set's installed members stay as recorded, each with
/// what `EngineReport::kept_bundles` carries to verify.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeptBundle {
    /// Its catalog no longer offers it, which fails the refresh and
    /// verify: the refusal, naming the sets the catalog does offer.
    NotOffered { detail: String },
    /// Its catalog retired it, short of a prune: the one notice keyed by
    /// the set.
    Retired { notice: String },
}

/// Why a hook is withheld from a tool, and so what becomes of a copy
/// already installed there. Where two reasons reach one hook on one tool,
/// the later variant outranks the earlier (`Ord`): a retirement is the
/// catalog's answer, which outranks a catalog that gives none, and a
/// wrapper that lacks a judge comes out whatever else is true of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Withholding {
    /// Every hook that requires it is withheld there, and nothing asks for
    /// it by name. It lacks nothing itself, so an installed copy is an
    /// orphan like any other, disposed of by `removal::orphans` under the
    /// plan's options: kept, taken, or held for the person's edits.
    Orphaned,
    /// A hook it requires is set to come from a catalog that says nothing
    /// of it this pass (`expansion::Offer::Silent`), and the manifest alone
    /// does not refuse it. Whether that hook would run cannot be told, so
    /// nothing is written and nothing is taken: an installed copy keeps its
    /// record, as an orphan whose declaration's source is unreachable does,
    /// and a companion this hook alone derives is not orphaned by it.
    Unanswered,
    /// A hook it requires was retired by its catalog, or a hook it
    /// requires is withheld for that, or, for a retired hook kept as
    /// recorded, a hook its record requires is withheld there and its copy
    /// goes: the knot of hooks that require each other goes together, for
    /// the retirement. An installed copy is an orphan disposed of under the
    /// plan's options, the person's edits held, by `removal::orphans`,
    /// while every companion it took the reason from stays installed there
    /// (`DesiredState::retired_companions`); once one goes, it lacks that
    /// companion and goes as [`Withholding::Requires`] does.
    Retired,
    /// A hook it requires will not run there. A wrapper beside no judge
    /// refuses every call it guards, so an installed copy comes out
    /// whatever the plan's options, the person's edits with it
    /// (`removal::verdicts`), unless a record kept by an answer requires
    /// it (`removal::keep_what_kept_records_require`).
    Requires,
}

impl Withholding {
    /// Whether this withholding lets a copy installed under it go, to the
    /// orphan pass that disposes of it. False where the copy stays, record
    /// and all. The one answer for the pass that keeps the copy
    /// (`plan_pass::plan_withheld`) and for the walk, which counts a
    /// requirer as gone from a tool only where its withholding lets its
    /// copy go (`deps::orphaned`).
    pub fn takes(self) -> bool {
        match self {
            Withholding::Orphaned | Withholding::Retired | Withholding::Requires => true,
            Withholding::Unanswered => false,
        }
    }

    /// What a row or a set change says of a copy this withholding takes,
    /// in place of the words for an orphan; `None` where those words are
    /// true of it. The detail of each is the hook's own warning.
    pub fn said(self) -> Option<&'static str> {
        match self {
            Withholding::Requires => Some("withheld: a hook it requires will not run here"),
            Withholding::Retired => {
                Some("withheld: a retirement leaves it without a hook it requires")
            }
            Withholding::Orphaned | Withholding::Unanswered => None,
        }
    }
}

impl DesiredState {
    pub(super) fn mark_incomplete(&mut self) {
        self.declaration_status = super::DeclarationStatus::Incomplete;
    }

    /// Records a declaration whose item was found and read: the provenance
    /// it is planned under, and why the closure wants it.
    fn record_read(
        &mut self,
        kind: ItemKind,
        name: &str,
        provenance: &str,
        expansion: &super::expansion::Expansion,
    ) {
        let key = (kind, name.to_owned());
        self.processed.insert(key.clone(), provenance.to_owned());
        let wanted = expansion.package_reasons(kind, name);
        self.derived.insert(key, wanted);
    }

    /// Records an item the declared `source`'s catalog retired, kept on
    /// the tools the record holds it on unless this pass prunes. The
    /// person's own declaration outranks a derivation naming the same item.
    pub(super) fn retire(
        &mut self,
        kind: ItemKind,
        name: &str,
        source: &str,
        migration: &str,
        declared: bool,
    ) {
        let kept = HarnessId::ALL
            .into_iter()
            .filter(|harness| self.kept_as_recorded(kind, name, *harness))
            .collect();
        let by = RetiredBy {
            source: source.to_owned(),
            migration: migration.to_owned(),
        };
        let key = (kind, name.to_owned());
        if declared || !self.retired.contains_key(&key) {
            let retirement = Retirement { by, declared, kept };
            self.retired.insert(key, retirement);
        }
    }

    /// [`DesiredState::retire`] for an item this pass plans, declared where
    /// the expansion holds the person's own declaration of it.
    pub(super) fn retire_planned(
        &mut self,
        expansion: &super::expansion::Expansion,
        kind: ItemKind,
        name: &str,
        source: &str,
        migration: &str,
    ) {
        let derived_from = expansion.derived_from(kind, name);
        let declared = matches!(derived_from, None | Some(crate::lock::Reason::Requested));
        self.retire(kind, name, source, migration, declared);
    }

    /// Whether a retired item stays on `harness` as recorded, before the
    /// walk withholds anything: the record holds it there, this pass does
    /// not prune, and the person does not name it for removal.
    pub(super) fn kept_as_recorded(&self, kind: ItemKind, name: &str, harness: HarnessId) -> bool {
        let key = crate::lock::entry_key(kind, name, harness);
        let named = super::report_types::named_in(self.removal_filter.as_deref(), kind, name);
        !self.prune_retired && !named && self.recorded.contains(&key)
    }

    /// Whether an item its catalog retired is kept nowhere this pass:
    /// pruned, or never recorded. Such an item is owed no installation.
    pub(super) fn retired_unkept(&self, kind: ItemKind, name: &str) -> bool {
        self.retired
            .get(&(kind, name.to_owned()))
            .is_some_and(|retirement| retirement.kept.is_empty())
    }

    /// Whether a set its catalog retired keeps the record under `key`
    /// (`kept_members`): as its member, or as what a record it keeps
    /// requires.
    pub(super) fn kept_by_retired_bundle(&self, key: &str) -> bool {
        let mut seen = BTreeSet::new();
        let mut next = vec![key.to_owned()];
        while let Some(key) = next.pop() {
            if !seen.insert(key.clone()) {
                continue;
            }
            for edge in self.kept_members.get(&key).into_iter().flatten() {
                match edge {
                    crate::lock::Reason::MemberOf { bundle } => {
                        if let Some(KeptBundle::Retired { .. }) = self.kept_bundles.get(bundle) {
                            return true;
                        }
                    }
                    crate::lock::Reason::RequiredBy { by } => {
                        next.push(crate::lock::entry_key(by.kind, &by.name, by.harness));
                    }
                    crate::lock::Reason::Requested => {}
                }
            }
        }
        false
    }

    /// Each declared set whose members this pass keeps, and why, by name.
    pub(super) fn kept_bundles_by_name(&self) -> BTreeMap<String, KeptBundle> {
        self.kept_bundles
            .iter()
            .map(|(bundle, kept)| (bundle.name.clone(), kept.clone()))
            .collect()
    }

    /// A declaration whose source item cannot be parsed. Un-marking it keeps
    /// what it already installed out of the orphan sweep: a source file
    /// someone broke this morning must never uninstall a working artifact.
    pub(super) fn unreadable(&mut self, kind: ItemKind, name: &str, note: String) {
        self.mark_incomplete();
        self.notes.push(note);
        self.processed.remove(&(kind, name.to_owned()));
    }
}

/// Why the plan must refuse a rendering: the structural findings saying the
/// harness's own loader would reject it, each with its fix. Advisory
/// findings never appear here — they install, and warn.
pub(super) fn refusal_reason(findings: &[crate::render::validate::Finding]) -> Option<String> {
    let blocking: Vec<String> = findings
        .iter()
        .filter(|finding| finding.is_breakage())
        .map(|finding| format!("{} — {}", finding.message, finding.remediation))
        .collect();
    match blocking.is_empty() {
        true => None,
        false => Some(blocking.join("; ")),
    }
}

mod artifact;
mod places;
pub use artifact::artifact_disk_hash;
pub(crate) use places::{IN_PLACE_DISABLED, effective_method, in_place_source, skill_dir};
pub(crate) use places::{harnesses_for, names_the_default, requested_or_default, target_harnesses};
pub use places::{native_dir, own_dir, read_dirs, skill_canonical};
pub(super) mod hold;

/// The desired world, computed against the manifest that will be on disk
/// once this plan applies. An upstream skill merge rewrites the manifest,
/// and hashes and renderings must reflect that rewrite — otherwise the very
/// next audit reads the merged manifest and calls a clean install stale. The
/// merge is idempotent, so recomputing against it converges in one repeat.
///
/// `held` names the declarations a single-package update pinned itself, so
/// the closure can tell them from the holds the person chose.
///
/// A prune takes a retired item's own declaration out of the manifest, so
/// the repeat no longer meets it: what the first pass retired carries over.
#[allow(clippy::too_many_arguments)]
pub(super) fn desired_state(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    hold_upstream_skills: bool,
    held: Option<&hold::HeldPins>,
    judge_pins: bool,
    prune_retired: bool,
    removal_filter: Option<&[super::report_types::RemovalName]>,
) -> Result<DesiredState> {
    let first = compute(
        env,
        scope,
        manifest,
        lock,
        hold_upstream_skills,
        held,
        judge_pins,
        prune_retired,
        removal_filter,
    )?;
    let Some(merged) = first.manifest_update else {
        return Ok(first);
    };
    let mut second = compute(
        env,
        scope,
        &merged,
        lock,
        hold_upstream_skills,
        held,
        judge_pins,
        prune_retired,
        removal_filter,
    )?;
    second.manifest_update = Some(merged);
    for (key, retirement) in first.retired {
        second.retired.entry(key).or_insert(retirement);
    }
    Ok(second)
}

#[allow(clippy::too_many_arguments)]
fn compute(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    hold_upstream_skills: bool,
    held: Option<&hold::HeldPins>,
    judge_pins: bool,
    prune_retired: bool,
    removal_filter: Option<&[super::report_types::RemovalName]>,
) -> Result<DesiredState> {
    if manifest.sources.contains_key(manifest::BUILTIN_SOURCE_NAME) {
        manifest::check_source_alias(manifest::BUILTIN_SOURCE_NAME)?;
    }
    let mut state = DesiredState {
        agent_names: crate::source::agent_names::Uses::new(manifest),
        judge_pins,
        prune_retired,
        removal_filter: removal_filter.map(<[_]>::to_vec),
        recorded: lock.entries.keys().cloned().collect(),
        recorded_requires: recorded_requires(lock),
        ..DesiredState::default()
    };
    let mut updated_manifest = manifest.clone();
    let mut manifest_changed = false;
    // Everything is planned from the closure — what was declared, what the
    // installed bundles carry, and what those skills require — while the
    // manifest keeps holding only what was chosen.
    let expansion = super::expansion::expand(env, scope, manifest, held, &mut state);
    state.kept_members =
        super::bundles::kept_members(lock, manifest, &state.kept_bundles, &expansion);
    let model_classes = if expansion.of(ItemKind::Agent).is_empty() {
        BTreeMap::new()
    } else {
        crate::manifest::model_class_overrides(env, scope, manifest)?
    };
    let collisions = super::catalog::Collisions::find(&expansion, &mut state);
    // What the sources' current checkouts offer, read once. Item-level pins
    // do not widen this inventory.
    let scope_skills = super::ScopeSkills::of(env, scope, manifest)?;

    for kind in super::expansion::PLANNED_KINDS {
        for (name, planned) in expansion.of(kind) {
            let decl = &planned.decl;
            if decl.source == crate::manifest::BUILTIN_SOURCE_NAME {
                super::desired_mcp::desired_builtin(env, scope, kind, name, decl, &mut state)?;
                continue;
            }
            // Before anything can fail: a skill starts out of reach and
            // the pass overwrites that the moment it can say better, so
            // every way of not getting there lands on one answer rather
            // than on silence.
            if kind == ItemKind::Skill {
                super::settings_scan::out_of_reach(scope, name, &mut state.settings_templates);
            }
            let Some((root, provenance, source_commit)) =
                resolve_source(env, scope, name, decl, manifest, &mut state)?
            else {
                continue;
            };
            let Some(catalog) = read_catalog(&root, &provenance, name, &decl.source, &mut state)?
            else {
                continue;
            };
            super::catalog::notes(&catalog.config, &decl.source, &mut state);
            let Some(item_path) = item_path(
                &catalog,
                kind,
                name,
                decl,
                &provenance,
                &expansion,
                &mut state,
            ) else {
                continue;
            };
            let OpenCatalog { sealed, config, .. } = catalog;
            state.record_read(kind, name, &provenance, &expansion);
            let mut harnesses = planned.harnesses.clone();
            if harnesses.is_empty() {
                no_harness_note(kind, name, decl, manifest, &mut state);
            }
            harnesses.retain(|harness| collisions.allows(kind, name, *harness));
            let reasons = reasons_for(kind, name, &harnesses, &expansion, &state.kept_members);
            let ctx = ItemCtx {
                model_classes: &model_classes,
                env,
                scope,
                manifest,
                lock,
                hold_upstream_skills,
                config: &config,
                sealed: &sealed,
                scope_skills: &scope_skills,
                expansion: &expansion,
                name,
                decl,
                item_path: &item_path,
                provenance: &provenance,
                source_commit: source_commit.as_deref(),
                harnesses,
                reasons: &reasons,
            };
            build(
                kind,
                &ctx,
                &mut state,
                &mut updated_manifest,
                &mut manifest_changed,
            )?;
        }
    }
    manifest_changed |= settle_retired(env, scope, manifest, &mut state, &mut updated_manifest);
    desired_kinds::desired_plugins(env, scope, manifest, &mut state);
    super::desired_custom_hooks::desired_custom_hooks(env, scope, manifest, &mut state);

    if manifest_changed {
        state.manifest_update = Some(updated_manifest);
    }
    Ok(state)
}

/// [`DesiredState::recorded_requires`] from `lock`: each companion's
/// `RequiredBy` reason, under its requirer where the record holds that
/// requirer switched on.
fn recorded_requires(
    lock: &Lock,
) -> BTreeMap<(ItemKind, String, HarnessId), BTreeSet<(ItemKind, String)>> {
    let mut requires: BTreeMap<_, BTreeSet<_>> = BTreeMap::new();
    for entry in lock.entries.values() {
        for reason in &entry.reasons {
            let crate::lock::Reason::RequiredBy { by } = reason else {
                continue;
            };
            let key = crate::lock::entry_key(by.kind, &by.name, by.harness);
            if lock
                .entries
                .get(&key)
                .is_some_and(|requirer| requirer.enabled)
            {
                requires
                    .entry((by.kind, by.name.clone(), by.harness))
                    .or_default()
                    .insert((entry.kind, entry.name.clone()));
            }
        }
    }
    requires
}

/// Where the catalog keeps one planned item, by the one lookup
/// ([`OpenCatalog::offer`]); `None` where it renders nothing. A retired
/// one is recorded for `settle_retired`, its provenance read as any
/// resolved item's is, for invariant 4 (`plan_pass::plan_rebound`).
fn item_path(
    catalog: &OpenCatalog,
    kind: ItemKind,
    name: &str,
    decl: &ItemDecl,
    provenance: &str,
    expansion: &super::expansion::Expansion,
    state: &mut DesiredState,
) -> Option<PathBuf> {
    match catalog.offer(kind, name) {
        Offer::Item(_, path) => Some(path),
        Offer::Retired(migration) => {
            let key = (kind, name.to_owned());
            state.processed.insert(key, provenance.to_owned());
            state.retire_planned(expansion, kind, name, &decl.source, migration);
            None
        }
        Offer::NotOffered | Offer::Silent => {
            state.mark_incomplete();
            let (sealed, config) = (&catalog.sealed, &catalog.config);
            let note = not_offered_note(sealed, config, kind, name, &decl.source);
            state.notes.push(note);
            None
        }
    }
}

/// Why each of an item's installations is wanted, as the closure derived
/// it, with each edge to a set kept as recorded that the record holds: a
/// member another set also carries keeps the kept set's edge, so it stays
/// once the other set lets it go.
fn reasons_for(
    kind: ItemKind,
    name: &str,
    harnesses: &[HarnessId],
    expansion: &super::expansion::Expansion,
    kept_members: &BTreeMap<String, BTreeSet<crate::lock::Reason>>,
) -> BTreeMap<HarnessId, BTreeSet<crate::lock::Reason>> {
    harnesses
        .iter()
        .map(|harness| {
            let mut reasons = expansion.reasons(kind, name, *harness);
            let key = crate::lock::entry_key(kind, name, *harness);
            reasons.extend(kept_members.get(&key).into_iter().flatten().cloned());
            (*harness, reasons)
        })
        .collect()
}

pub(super) struct ItemCtx<'a> {
    pub(super) model_classes: &'a BTreeMap<String, String>,
    pub(super) env: &'a Env,
    pub(super) scope: &'a Scope,
    pub(super) manifest: &'a Manifest,
    pub(super) lock: &'a Lock,
    pub(super) hold_upstream_skills: bool,
    pub(super) config: &'a crate::source::SourceConfig,
    pub(super) sealed: &'a SealedSource,
    /// Skills offered by the current checkout of each source. Item-level
    /// pins do not widen this inventory.
    pub(super) scope_skills: &'a super::ScopeSkills,
    /// The plan this pass is installing, which holds a declaration for
    /// every derived item — a set's members included — where the manifest
    /// holds only what the person wrote.
    pub(super) expansion: &'a super::expansion::Expansion,
    pub(super) name: &'a str,
    pub(super) decl: &'a ItemDecl,
    pub(super) item_path: &'a std::path::Path,
    pub(super) provenance: &'a str,
    pub(super) source_commit: Option<&'a str>,
    pub(super) harnesses: Vec<HarnessId>,
    reasons: &'a BTreeMap<HarnessId, BTreeSet<crate::lock::Reason>>,
}

impl ItemCtx<'_> {
    pub(super) fn reasons_for(&self, harness: HarnessId) -> BTreeSet<crate::lock::Reason> {
        self.reasons.get(&harness).cloned().unwrap_or_default()
    }

    /// The catalog file this item's renderings come from, and whether
    /// `artifact` is that file's own bytes. The comparison is by hash
    /// against the shape the catalog holds — a tree for a directory, a
    /// file otherwise — so a rendering that changes the shape (a command
    /// wrapped into a skill tree) reads as changed, which it is.
    pub(super) fn source(&self, kind: ItemKind, artifact: &Artifact) -> Result<CatalogSource> {
        Ok(CatalogSource {
            path: self.sealed.catalog_path(self.item_path),
            verbatim: self.sealed.catalog_hash(kind, self.item_path)? == artifact.disk_hash(),
            tree: self.sealed.is_dir(self.item_path),
        })
    }
}

/// The catalog that retired an item (`[retired]`), and what it says to
/// do instead; displayed as a removal preview's reason
/// (`SetChange::dropped`).
#[derive(Debug, Clone)]
pub(super) struct RetiredBy {
    /// The declared source whose catalog retired it.
    pub(super) source: String,
    /// The catalog's one-line migration, empty where it gave none.
    migration: String,
}

impl std::fmt::Display for RetiredBy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "retired by {}", self.source)?;
        match self.migration.is_empty() {
            true => Ok(()),
            false => write!(f, "; {}", self.migration),
        }
    }
}

/// An item its catalog retired (`[retired]`), as this pass met it; what a
/// pass does with one is `PlanOptions::prune_retired`'s.
#[derive(Debug, Clone)]
pub struct Retirement {
    pub(super) by: RetiredBy,
    /// The person's own declaration brought it in, the one a manifest edit
    /// drops; false for a bundle member or a requirement.
    declared: bool,
    /// The tools it stays on as recorded: each the record this pass read
    /// holds it on, none under a prune or a removal by name. Where the walk
    /// withholds it, or a companion it requires goes, the removal pass
    /// takes it all the same (`removal::settle_lacking`).
    pub(super) kept: Vec<HarnessId>,
}

/// The notice a retired item gets in place of the not-found refusal, so a
/// refresh at a consumer still wanting it runs: one line keyed by the
/// item's name and the catalog that retired it, saying where the plan
/// leaves it and the removal that takes what stays, ending with the
/// catalog's migration. A pruned line speaks of the plan, which a refused
/// run never applies. A derived one installed nowhere gets none: a
/// requirer's warning names it, and a bundle member is silent. The
/// commands in the line are the owner's ruled exception to engine rule 18;
/// `kendex remove` is the drift report's own spelling
/// ([`Remedy::Remove`](crate::drift::report::Remedy::Remove)), which names
/// the kind, since a bare name also removes a live item of another kind
/// sharing it. `recorded` is whether the record this pass read holds it.
fn retired(
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    retirement: &Retirement,
    standing: super::RetiredStanding,
    recorded: bool,
) -> Option<super::ItemWarning> {
    use super::RetiredStanding;
    let source = &retirement.by.source;
    let removal = || {
        let remedy = crate::drift::report::Remedy::Remove {
            kind,
            name: name.to_owned(),
            global: matches!(scope, Scope::Global),
        };
        // Rendered for no named project, the command runs where the
        // notice is read.
        remedy.render(None).map(|fix| match fix {
            crate::drift::report::Fix::Here(command)
            | crate::drift::report::Fix::Elsewhere(command) => command,
        })
    };
    let line = match (standing, retirement.declared, recorded) {
        (RetiredStanding::Uninstalled, false, _) | (RetiredStanding::Pruned, false, false) => {
            return None;
        }
        (RetiredStanding::Kept, true, _) => match removal() {
            Some(command) => format!(
                "{name}: retired by {source}; kept; remove it with kendex refresh --prune (or {command})"
            ),
            None => {
                format!("{name}: retired by {source}; kept; remove it with kendex refresh --prune")
            }
        },
        (RetiredStanding::Uninstalled, true, _) => format!(
            "{name}: retired by {source}; not installed; drop its declaration with kendex refresh --prune"
        ),
        (RetiredStanding::Kept, false, _) => {
            format!("{name}: retired by {source}; kept; remove it with kendex refresh --prune")
        }
        (RetiredStanding::Pruned, true, false) => {
            format!("{name}: retired by {source}; this prune drops its declaration")
        }
        (RetiredStanding::Pruned, _, true) => {
            format!("{name}: retired by {source}; this prune removes it")
        }
        (RetiredStanding::Held, _, _) => match removal() {
            Some(command) => format!(
                "{name}: retired by {source}; this prune holds its edited files; remove them with {command}"
            ),
            None => format!("{name}: retired by {source}; this prune holds its edited files"),
        },
        (RetiredStanding::Stays, _, _) => format!(
            "{name}: retired by {source}; this prune leaves a copy installed, as its row says"
        ),
    };
    let message = match retirement.by.migration.is_empty() {
        true => line,
        false => format!("{line}; {}", retirement.by.migration),
    };
    Some(super::ItemWarning {
        kind,
        name: name.to_owned(),
        harness: None,
        message,
        remediation: None,
        detail: None,
    })
}

/// Each retired item's notice ([`retired`]), said once both desired passes
/// and the removal pass are in, so a prune that rewrites the manifest keeps
/// it: from `standings`, where the removal pass leaves each one.
pub(super) fn retired_notices(
    scope: &Scope,
    state: &DesiredState,
    standings: &super::removal::Retired,
) -> Vec<super::ItemWarning> {
    state
        .retired
        .iter()
        .filter_map(|(key, retirement)| {
            let (kind, name) = key;
            let standing = standings.get(key)?;
            let recorded = HarnessId::ALL.into_iter().any(|harness| {
                let key = crate::lock::entry_key(*kind, name, harness);
                state.recorded.contains(&key)
            });
            retired(scope, *kind, name, retirement, *standing, recorded)
        })
        .collect()
}

/// What this pass does with the retired items it met, the Pi declarations
/// among them read here, through the one lookup every Pi pass makes
/// (`pi_ext::resolve_declared`); a retired item, carried or not, never
/// renders. Each gets its notice from where the plan leaves it, once
/// removal is settled ([`retired_notices`]). Pruned, the person's own
/// declaration of one leaves `updated`; returns whether it did.
fn settle_retired(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    state: &mut DesiredState,
    updated: &mut Manifest,
) -> bool {
    for (name, decl) in &manifest.pi_extensions {
        let resolved = crate::pi_ext::resolve_declared(env, scope, manifest, name, decl);
        if let Ok(crate::pi_ext::Resolved::Retired {
            migration,
            source_repo,
        }) = resolved
        {
            let key = (ItemKind::PiExtension, name.clone());
            state.processed.insert(key, source_repo);
            state.retire(ItemKind::PiExtension, name, &decl.source, &migration, true);
        }
    }
    if !state.prune_retired {
        return false;
    }
    let mut changed = false;
    for ((kind, name), retirement) in &state.retired {
        let declared = retirement.declared && manifest.declared(*kind).contains_key(name);
        if declared {
            updated.declared_mut(*kind).remove(name);
            changed = true;
        }
    }
    for name in &state.pruned_bundles {
        changed |= updated.bundles.remove(name).is_some();
    }
    changed
}

/// The note for a declaration the catalog does not carry.
fn not_offered_note(
    sealed: &SealedSource,
    config: &SourceConfig,
    kind: ItemKind,
    name: &str,
    source: &str,
) -> String {
    let offered = list_items(sealed, config, kind);
    format!("{name}: {}", not_offered(source, kind.name(), offered))
}

/// Why a declaration of a `noun` its catalog does not carry is refused,
/// for a note keyed by the declaration. It names what the source does
/// offer of that noun, so a declaration left on a name the catalog renamed
/// reads its remedy in the line that refuses it. `kendex refresh` fails on
/// its "not found in source" (`refresh_failures` in the CLI's
/// `engine_common.rs`).
pub(super) fn not_offered(source: &str, noun: &str, mut offered: Vec<String>) -> String {
    offered.sort();
    offered.dedup();
    if offered.is_empty() {
        return format!("not found in source '{source}', which offers no {noun}");
    }
    format!(
        "not found in source '{source}' — its {noun}s are {}; declare one of those",
        offered.join(", ")
    )
}
