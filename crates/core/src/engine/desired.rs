use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::env::Env;
use crate::error::Result;
use crate::harness::{Surface, adapter};
use crate::lock::Lock;
use crate::manifest::{ItemDecl, Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::quality::author::AuthorReview;
use crate::source::{SourceState, find_item};
use crate::source_read::SealedSource;

use super::desired_item::{build, no_harness_note};
use super::desired_kinds;
use super::desired_source::{published_review, read_catalog, resolve_source};

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
    /// Sources that could not be read (pending remotes, missing paths) and
    /// declared items the source no longer carries.
    pub notes: Vec<String>,
    pub warnings: Vec<super::ItemWarning>,
    pub refused: Vec<Refused>,
    /// Declarations whose source resolved and whose item was found. What
    /// these produced is the complete truth about them, so a lock entry
    /// they did not produce is stranded, not merely skipped this pass.
    pub processed: BTreeSet<(ItemKind, String)>,
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
    /// A declaration whose source item cannot be parsed. Un-marking it keeps
    /// what it already installed out of the orphan sweep: a source file
    /// someone broke this morning must never uninstall a working artifact.
    pub(super) fn unreadable(&mut self, kind: ItemKind, name: &str, note: String) {
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

/// The desired world, computed against the manifest that will be on disk
/// once this plan applies. An upstream skill merge rewrites the manifest,
/// and hashes and renderings must reflect that rewrite — otherwise the very
/// next audit reads the merged manifest and calls a clean install stale. The
/// merge is idempotent, so recomputing against it converges in one repeat.
mod artifact;
mod rebuild;
pub use artifact::{artifact_disk_hash, artifact_paths};
pub use rebuild::desired_as_installed;

pub fn desired_state(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
) -> Result<DesiredState> {
    let first = compute(env, scope, manifest, lock)?;
    let Some(merged) = first.manifest_update else {
        return Ok(first);
    };
    let mut second = compute(env, scope, &merged, lock)?;
    second.manifest_update = Some(merged);
    Ok(second)
}

fn compute(env: &Env, scope: &Scope, manifest: &Manifest, lock: &Lock) -> Result<DesiredState> {
    let mut state = DesiredState::default();
    let mut updated_manifest = manifest.clone();
    let mut manifest_changed = false;
    // Everything is planned from the closure — what was declared, what the
    // installed bundles carry, and what those skills require — while the
    // manifest keeps holding only what was chosen.
    let expansion = super::expansion::expand(env, scope, manifest, &mut state);
    // One parse of each catalog root's reviews file per pass: it is one
    // file, and every item that root carries would otherwise re-read it.
    // Keyed by root, since one declared source resolves to several when
    // its items pin different revisions.
    let mut reviews: BTreeMap<PathBuf, BTreeMap<String, crate::quality::reviews::SafetyReview>> =
        BTreeMap::new();
    let collisions = super::catalog::Collisions::find(&expansion, &mut state);

    for kind in super::expansion::PLANNED_KINDS {
        for (name, planned) in expansion.of(kind) {
            let decl = &planned.decl;
            let Some((root, provenance, source_commit)) =
                resolve_source(env, scope, name, decl, manifest, &mut state)?
            else {
                continue;
            };
            let Some((sealed, config)) =
                read_catalog(&root, &provenance, name, &decl.source, &mut state)?
            else {
                continue;
            };
            super::catalog::notes(&config, &decl.source, &mut state);
            let Some(item_path) = find_item(&sealed, &config, kind, name) else {
                state
                    .notes
                    .push(format!("{name}: not found in source '{}'", decl.source));
                continue;
            };
            state.processed.insert((kind, name.clone()));
            let author_review = published_review(
                &sealed,
                &decl.source,
                &provenance,
                &config,
                kind,
                name,
                &item_path,
                &mut reviews,
                &mut state,
            )?;
            let mut harnesses = planned.harnesses.clone();
            if harnesses.is_empty() {
                no_harness_note(kind, name, decl, manifest, &mut state);
            }
            harnesses.retain(|harness| collisions.allows(kind, name, *harness));
            let reasons = reasons_for(kind, name, &harnesses, &expansion);
            let ctx = ItemCtx {
                env,
                scope,
                manifest,
                lock,
                config: &config,
                sealed: &sealed,
                name,
                decl,
                item_path: &item_path,
                provenance: &provenance,
                source_commit: source_commit.as_deref(),
                harnesses,
                reasons: &reasons,
                author_review,
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
    desired_kinds::desired_plugins(env, scope, manifest, &mut state);
    super::desired_custom_hooks::desired_custom_hooks(env, scope, manifest, &mut state);

    if manifest_changed {
        state.manifest_update = Some(updated_manifest);
    }
    Ok(state)
}

/// Why each of an item's installations is wanted, as the closure derived it.
fn reasons_for(
    kind: ItemKind,
    name: &str,
    harnesses: &[HarnessId],
    expansion: &super::expansion::Expansion,
) -> BTreeMap<HarnessId, BTreeSet<crate::lock::Reason>> {
    harnesses
        .iter()
        .map(|harness| (*harness, expansion.reasons(kind, name, *harness)))
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
