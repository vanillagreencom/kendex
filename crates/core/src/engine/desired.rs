use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::env::Env;
use crate::error::Result;
use crate::hash::{hash_bytes, hash_files};
use crate::lock::Lock;
use crate::manifest::{ItemDecl, Manifest, Method};
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::{SourceState, find_item};
use crate::source_read::SealedSource;

use super::desired_item::{build, no_harness_note};
use super::desired_kinds;
use super::desired_source::{read_catalog, resolve_source};

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
    /// Set where deriving the place again could name another one — a
    /// command stored as a skill, a skill's tree and link — so the lock
    /// records it and removal targets what was written.
    pub emitted: Option<crate::lock::EmittedArtifact>,
    /// Every reason this installation is wanted, derived fresh each pass.
    pub reasons: BTreeSet<crate::lock::Reason>,
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

impl Artifact {
    /// Every path the artifact occupies. Cursor keeps hook rules in the
    /// same dir as agents and codex shares skill trees with pi: without
    /// this, the scanner reports content we just wrote as someone else's.
    pub fn paths(&self) -> Vec<PathBuf> {
        match self {
            Artifact::File { path, .. } => vec![path.clone()],
            Artifact::Tree {
                canonical, link, ..
            } => {
                let mut paths = vec![canonical.clone()];
                paths.extend(link.clone());
                paths
            }
            Artifact::Registration { script, .. } => {
                script.iter().map(|(path, _)| path.clone()).collect()
            }
        }
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
            | crate::configedit::ConfigEdit::UpsertCopilotHook { command, .. } => {
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
    /// (kendex.settings.toml.example), every declaration in skill-name
    /// order — each with the skill that ships it, incomplete values
    /// included, because a key nothing can supply is reported by name.
    ///
    /// The one list everything that speaks about these keys reads: an
    /// arrival writes its marked keys from here, a save writes and
    /// resolves defaults from here, and the plan's notes are built from
    /// here. Where several skills declare one key, what lands is the
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

mod artifact;
mod places;
pub use artifact::{artifact_disk_hash, artifact_paths};
pub(crate) use places::{harnesses_for, target_harnesses};
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
pub(super) fn desired_state(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    hold_upstream_skills: bool,
    held: Option<&hold::HeldPins>,
) -> Result<DesiredState> {
    let first = compute(env, scope, manifest, lock, hold_upstream_skills, held)?;
    let Some(merged) = first.manifest_update else {
        return Ok(first);
    };
    let mut second = compute(env, scope, &merged, lock, hold_upstream_skills, held)?;
    second.manifest_update = Some(merged);
    Ok(second)
}

fn compute(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    hold_upstream_skills: bool,
    held: Option<&hold::HeldPins>,
) -> Result<DesiredState> {
    let mut state = DesiredState::default();
    let mut updated_manifest = manifest.clone();
    let mut manifest_changed = false;
    // Everything is planned from the closure — what was declared, what the
    // installed bundles carry, and what those skills require — while the
    // manifest keeps holding only what was chosen.
    let expansion = super::expansion::expand(env, scope, manifest, held, &mut state);
    let collisions = super::catalog::Collisions::find(&expansion, &mut state);
    // What this scope can supply, read once from the closure above: an
    // agent's skill assignment resolves against the whole scope, and
    // reading it per agent would open every catalog again for each one.
    let scope_skills =
        super::ScopeSkills::planned(env, scope, manifest, &expansion, &state.rev_conflicts, &[])?;

    for kind in super::expansion::PLANNED_KINDS {
        for (name, planned) in expansion.of(kind) {
            let decl = &planned.decl;
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
                hold_upstream_skills,
                config: &config,
                sealed: &sealed,
                scope_skills: &scope_skills,
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
    pub(super) hold_upstream_skills: bool,
    pub(super) config: &'a crate::source::SourceConfig,
    pub(super) sealed: &'a SealedSource,
    /// Every skill this scope can supply — what its sources offer, plus
    /// what the plan installs from a pinned revision. An agent's declared
    /// assignment resolves against this, so a fork keeps rendering skills
    /// its own source never held.
    pub(super) scope_skills: &'a super::ScopeSkills,
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

    pub(super) fn recorded_fork(&self, kind: ItemKind) -> bool {
        self.manifest
            .forks
            .get(&kind)
            .is_some_and(|forks| forks.contains_key(self.name))
    }
}
