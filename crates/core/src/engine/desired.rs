use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::env::Env;
use crate::harness::{Surface, adapter};
use crate::lock::Lock;
use crate::manifest::{ItemDecl, Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::quality::author::AuthorReview;
use crate::source::SourceState;
use crate::source_read::SealedSource;

mod artifact;
mod compute;
mod rebuild;
pub use artifact::{artifact_disk_hash, artifact_paths};
pub use compute::desired_state;
pub use rebuild::desired_as_installed;

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
    pub upstream_skills: Option<Vec<String>>,
    /// Set when the artifact is not this kind's native form — the lock
    /// records it so removal targets what was written.
    pub emitted: Option<crate::lock::EmittedArtifact>,
    /// Every reason this installation is wanted, derived fresh each pass.
    pub reasons: BTreeSet<crate::lock::Reason>,
    /// What this item's publisher already settled about it, re-checked
    /// against the bytes this pass fetched. The gate stops counting those
    /// findings and the lock records the review; every one is still
    /// reported, named as the publisher's.
    pub author_review: Option<AuthorReview>,
    /// How much of this artifact its publisher wrote: where the project's
    /// block landed in it, or their own rendering of it beside the real
    /// one. Present only where a publisher's record needs measuring
    /// against it. The builder that rendered the artifact owes this beside
    /// it: a kind that can carry project text and does not answer settles
    /// nothing at all, which is the direction a mistake here has to fail
    /// in.
    pub authored: Option<crate::quality::Authored>,
    pub artifact: Artifact,
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

/// A declared installation a renderer refused to produce — expressing it on
/// this harness would widen access. The plan turns each into a conflict row
/// and a removal of whatever the old, wider rendering left installed.
#[derive(Debug, Clone, PartialEq)]
pub struct Refused {
    pub kind: ItemKind,
    pub name: String,
    pub harness: HarnessId,
    pub reason: String,
}

#[derive(Debug, Default)]
pub struct DesiredState {
    pub items: Vec<Desired>,
    /// Which items this plan acts on at all, where a caller restricted it
    /// to some packages (`PlanOptions::only_names`) — `None` when it did
    /// not. Resolved once against the expansion, so it is the named
    /// packages *and everything they need*: a command that restores a
    /// package and leaves the dependency that package requires uninstalled
    /// has not done what it said, and says it worked.
    pub(super) acting: Option<BTreeSet<(ItemKind, String)>>,
    /// Sources that could not be read (pending remotes, missing paths) and
    /// declared items the source no longer carries.
    pub notes: Vec<String>,
    pub warnings: Vec<super::ItemWarning>,
    pub refused: Vec<Refused>,
    /// Declarations whose source resolved and whose item was found. What
    /// these produced is the complete truth about them, so a lock entry
    /// they did not produce is stranded, not merely skipped this pass.
    pub processed: BTreeSet<(ItemKind, String)>,
    /// The other half: declarations this pass looked at and could not
    /// measure — the source did not resolve, could not be read, or no
    /// longer carries the item — so nothing was rendered to compare what
    /// is on disk against. They are absent from the drift for that reason
    /// and not because they are clean, and a reader that takes the silence
    /// for cleanliness reports an edited place as untouched.
    pub unmeasured: BTreeSet<(ItemKind, String)>,
    /// Manifest with upstream skill additions merged in — present only when
    /// the merge changed something and must be written back.
    pub manifest_update: Option<Manifest>,
    /// `[env]` defaults shipped by enabled skills
    /// (kendex.settings.toml.example), every declaration in order — each
    /// with the skill that ships it. Seeding writes the first declaration
    /// of a key; a refresh listens to the key's recorded owner.
    pub settings_env: Vec<crate::settings_seed::SeededEnv>,
    /// What each source an item names resolved to. One resolution per
    /// source per pass: resolving a remote reads its checkout to confirm
    /// nothing has altered it, which is worth doing once and wasteful to
    /// repeat for every item the source carries.
    pub sources: BTreeMap<String, SourceState>,
    /// Resolutions for item-level pins, keyed `(source, rev)` — kept apart
    /// from `sources` so the lock's per-source record never picks up a
    /// commit only one pinned item reads.
    pub pinned: BTreeMap<(String, String), SourceState>,
    /// Items wanted at two different revisions at once. One filesystem
    /// identity exists, so nothing is written for these: the plan reports
    /// the conflict and leaves what is installed alone.
    pub rev_conflicts: BTreeSet<(ItemKind, String)>,
}

impl DesiredState {
    /// Whether this plan writes or removes for this item at all. Every pass
    /// that touches disk asks here rather than reading `only_names`, so the
    /// closure is resolved in one place and they cannot disagree about what
    /// "one package" means.
    pub(super) fn acts_on(&self, kind: ItemKind, name: &str) -> bool {
        match &self.acting {
            Some(acting) => acting.contains(&(kind, name.to_owned())),
            None => true,
        }
    }

    /// A declaration whose source item cannot be parsed. Un-marking it keeps
    /// what it already installed out of the orphan sweep: a source file
    /// someone broke this morning must never uninstall a working artifact.
    pub(super) fn unreadable(&mut self, kind: ItemKind, name: &str, note: String) {
        self.notes.push(note);
        self.processed.remove(&(kind, name.to_owned()));
        self.unmeasured.insert((kind, name.to_owned()));
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

/// The dir a harness natively reads `kind` from at this scope, taken from
/// the same adapter surface declarations the scanner uses.
pub fn native_dir(env: &Env, scope: &Scope, harness: HarnessId, kind: ItemKind) -> Option<PathBuf> {
    let a = adapter(harness);
    let surfaces = match scope {
        Scope::Global => a.global_surfaces(kind, &a.default_global_root(env), env),
        Scope::Project { root } => a.project_surfaces(kind, root, env),
    };
    surfaces.into_iter().find_map(|surface| match surface {
        Surface::FileDir { dir, .. } | Surface::SubdirPerItem { dir, .. } => Some(dir),
        // A structured surface holds entries, not one file per item, so
        // there is no directory an item of this kind is written into.
        Surface::Structured { .. } | Surface::StructuredDir { .. } => None,
    })
}

/// The shared tree several tools read one skill from. Its name holds the
/// plugin a plugin-registry catalog put the skill in, joined the way the
/// directory itself spells it.
pub fn skill_canonical(env: &Env, scope: &Scope, name: &str) -> PathBuf {
    let name = crate::harness::canonical_name(name);
    match scope {
        Scope::Global => env.rendered_skills_dir().join(name),
        Scope::Project { root } => root.join(".agents/skills").join(name),
    }
}

pub(crate) fn target_harnesses(
    decl: &ItemDecl,
    manifest: &Manifest,
    kind: ItemKind,
    scope: &Scope,
) -> Vec<HarnessId> {
    harnesses_for(decl.harnesses.as_deref(), manifest, kind, scope)
}

/// The same from a declaration's `harnesses` list alone, so a reading with
/// no declaration to hand — nothing here has asked for this item yet — gets
/// its answer from this derivation rather than from a second spelling of
/// it.
pub(crate) fn harnesses_for(
    requested: Option<&[HarnessId]>,
    manifest: &Manifest,
    kind: ItemKind,
    scope: &Scope,
) -> Vec<HarnessId> {
    requested
        .map(<[HarnessId]>::to_vec)
        .unwrap_or_else(|| manifest.install.harnesses.clone())
        .into_iter()
        .filter(|harness| crate::harness::installs_here(*harness, kind, scope))
        .collect()
}

pub(super) struct ItemCtx<'a> {
    pub(super) env: &'a Env,
    pub(super) scope: &'a Scope,
    pub(super) manifest: &'a Manifest,
    pub(super) lock: &'a Lock,
    pub(super) config: &'a crate::source::SourceConfig,
    pub(super) sealed: &'a SealedSource,
    pub(super) name: &'a str,
    pub(super) decl: &'a ItemDecl,
    pub(super) item_path: &'a std::path::Path,
    pub(super) provenance: &'a str,
    pub(super) source_commit: Option<&'a str>,
    pub(super) harnesses: Vec<HarnessId>,
    reasons: &'a BTreeMap<HarnessId, BTreeSet<crate::lock::Reason>>,
    pub(super) author_review: Option<AuthorReview>,
    /// Whether this plan writes for this item at all — false for everything
    /// a restricted plan (`only_names`) leaves alone. What such an item
    /// would have contributed to the manifest is left out with it: a
    /// manifest recording what nothing installed describes a machine that
    /// does not exist.
    pub(super) planned: bool,
}

impl ItemCtx<'_> {
    pub(super) fn reasons_for(&self, harness: HarnessId) -> BTreeSet<crate::lock::Reason> {
        self.reasons.get(&harness).cloned().unwrap_or_default()
    }

    pub(super) fn recorded_fork(&self, kind: ItemKind) -> bool {
        self.manifest
            .forks
            .get(&kind)
            .is_some_and(|forks| forks.contains_key(self.name))
    }
}
