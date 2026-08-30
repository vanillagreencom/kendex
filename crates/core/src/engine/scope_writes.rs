//! Everything a scope plan writes that is not one item's own artifact: the
//! shared config files edits land in, the install record, the manifest's
//! format line, and the settings a project's skills seed.

use std::collections::BTreeMap;
use std::path::Path;

use crate::apply::{Op, PlannedOp, Pre};
use crate::base::Base;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{BundleRev, Lock, SourceRev, lock_path};
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::SourceState;

use super::desired::DesiredState;
use super::{DriftRow, DriftState, config_edits};

/// Whether a plan already persists the manifest. A caller about to insert
/// its own save must know: a second write to the same file binds to bytes
/// the first one replaces and could never run.
pub fn persists_manifest(ops: &[PlannedOp]) -> bool {
    ops.iter()
        .any(|op| matches!(op.op, Op::WriteManifest { .. }))
}

/// The precondition the plan's one manifest write binds to: the base of
/// the editor copy when the manifest arrived whole from one, otherwise
/// the file as it is now. An editor copy's write must bind to the file
/// that copy was read from — observing the path here instead would accept
/// a writer that landed after the copy left the editor.
pub(super) fn manifest_pre(base: Option<&Base>, path: &Path) -> Result<Pre> {
    match base {
        Some(base) => Ok(base.into()),
        None => Pre::observed(path),
    }
}

/// The plan's one manifest write, when anything needs it: skills an agent
/// gained upstream. Nothing else rewrites the file — only the current
/// schema loads, so there is no upgrade to plan, and a pass that wrote the
/// manifest for its own sake would take the person's comments with it. One
/// write whatever put it there: a second manifest write could never run,
/// its precondition binds to the bytes the first one replaces.
pub(super) fn plan_manifest_write(
    env: &Env,
    scope: &Scope,
    base: Option<&Base>,
    state: &DesiredState,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Some(update) = &state.manifest_update else {
        return Ok(());
    };
    let path = crate::manifest::manifest_path(env, scope);
    // The schema is not set here: `manifest::save` stamps it, and one
    // place deciding it is the whole point of stamping at the write.
    let written = update.clone();
    ops.push(PlannedOp {
        description: "Add new catalog skills to kendex.toml".into(),
        op: Op::WriteManifest {
            pre: manifest_pre(base, &path)?,
            path,
            manifest: Box::new(written),
        },
    });
    Ok(())
}

/// One mutation per config file, whatever asked for it — a single
/// precondition can hold; per-edit preconditions against the same original
/// bytes cannot.
pub(super) fn plan_config_edits(
    env: &Env,
    scope: &Scope,
    config_edits: config_edits::ConfigEditPlan,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    for (path, (labels, edits)) in config_edits.by_file {
        // A settings file of somebody's own may be a link they made, and
        // kendex edits it in place, link kept and target updated. The
        // registries it writes for pi's carrier are not that: a link
        // there is refused when the plan is made, so the op binds that
        // proof along with the bytes rather than leaving the window
        // between the two open.
        let pre = match crate::harness::pi::is_hook_registry(env, scope, &path) {
            true => crate::apply::Pre::plain_observed(&path)?,
            false => crate::apply::Pre::observed(&path)?,
        };
        let file = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        ops.push(PlannedOp {
            description: format!("Update {file} ({})", labels.join(", ")).into(),
            op: Op::EditFile { pre, path, edits },
        });
    }
    Ok(())
}

/// Which commit each installed set was read at, for the lock to record.
/// Carried forward and dropped on the same terms as [`source_revisions`],
/// and read from the same resolutions: a set is read at its declaration's
/// revision, so what it came out as is what that resolution resolved to.
pub(super) fn bundle_revisions(
    manifest: &Manifest,
    lock: &Lock,
    state: &DesiredState,
) -> BTreeMap<String, BundleRev> {
    let mut revisions: BTreeMap<String, BundleRev> = lock
        .bundles
        .iter()
        .filter(|(name, _)| manifest.bundles.contains_key(*name))
        .map(|(name, revision)| (name.clone(), revision.clone()))
        .collect();
    for (name, decl) in &manifest.bundles {
        let resolution = match &decl.rev {
            Some(rev) => state.pinned.get(&(decl.source.clone(), rev.clone())),
            None => state.sources.get(&decl.source),
        };
        let Some(SourceState::Ready(ready)) = resolution else {
            continue;
        };
        let Some(commit) = ready.commit.clone() else {
            continue;
        };
        revisions.insert(
            name.clone(),
            BundleRev {
                source: decl.source.clone(),
                source_repo: ready.provenance.clone(),
                commit,
            },
        );
    }
    revisions
}

/// Which commit each source resolved to, for the lock to record. What
/// earlier passes resolved is carried forward — a source that is offline
/// today should not lose the commit it was reading yesterday — and a source
/// the manifest no longer declares drops out.
pub(super) fn source_revisions(
    manifest: &Manifest,
    lock: &Lock,
    state: &DesiredState,
) -> BTreeMap<String, SourceRev> {
    let mut revisions: BTreeMap<String, SourceRev> = lock
        .sources
        .iter()
        .filter(|(name, _)| manifest.sources.contains_key(*name))
        .map(|(name, revision)| (name.clone(), revision.clone()))
        .collect();
    for (name, resolution) in &state.sources {
        let SourceState::Ready(ready) = resolution else {
            continue;
        };
        let Some(commit) = ready.commit.clone() else {
            continue;
        };
        revisions.insert(
            name.clone(),
            SourceRev {
                repo: ready.provenance.clone(),
                rev: manifest.sources.get(name).and_then(|decl| decl.rev.clone()),
                commit,
            },
        );
    }
    revisions
}

/// An old-version lock rewrites even when its entries are unchanged — the
/// version bump is itself the change. So does a source that now resolves to
/// another commit, once there are installations to reproduce: with nothing
/// installed there is no record to keep, and no lock file is created for
/// one.
pub(super) fn plan_lock_write(
    env: &Env,
    scope: &Scope,
    lock: &Lock,
    new_lock: Lock,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    if new_lock.entries == lock.entries
        && (new_lock.sources == lock.sources || new_lock.entries.is_empty())
        && (new_lock.bundles == lock.bundles || new_lock.entries.is_empty())
        && new_lock.settings_seeds == lock.settings_seeds
        && (lock.version == crate::lock::LOCK_VERSION || lock.entries.is_empty())
    {
        return Ok(());
    }
    let path = lock_path(env, scope);
    ops.push(PlannedOp {
        description: "Update the install record".into(),
        op: Op::WriteLock {
            pre: crate::apply::Pre::observed(&path)?,
            path,
            lock: Box::new(new_lock),
        },
    });
    Ok(())
}

/// The row a plan carries for a settings file it cannot write.
///
/// Two shapes reach here and they end the same way: a path that is not a
/// regular file, and a document declaring env as an array of tables.
/// Neither is a place a setting can go, so seeding says so and leaves the
/// file alone — while an edit aimed at that same file refuses outright,
/// because the person asked for exactly it.
fn cannot_write(scope: &Scope, file: String, detail: String) -> DriftRow {
    DriftRow {
        kind: ItemKind::Skill,
        name: file,
        harness: HarnessId::Claude,
        scope: scope.clone(),
        state: DriftState::Conflict,
        detail,
        cause: None,
        compared: None,
        also_in_the_way: Vec::new(),
    }
}

/// Skills may ship `[env]` defaults; missing keys merge into the project's
/// kendex.settings.toml write-if-absent (v1 semantics — a key the user set
/// anywhere in the file is never touched), and seeded comment blocks whose
/// template improved are refreshed while provably unedited — gated by the
/// lock's per-key ledger, which this plan carries forward on `new_lock`.
///
/// A person's own edits are the third thing that reaches this file, and
/// they compose here rather than following as a second write: a manifest
/// save re-plans the scope and may seed or refresh this same file, and a
/// second write would bind to bytes the first one replaced. Seeds,
/// refreshes and edits become one `WriteFile` with one precondition, and
/// the ledger they all move rides out on the one lock this pass writes.
///
/// The notes go out before any of it: a shared key several packages give
/// different defaults is worth saying whether or not this pass has a write
/// to plan for it.
pub(super) fn plan_settings_seed(
    scope: &Scope,
    state: &DesiredState,
    options: &crate::engine::PlanOptions,
    new_lock: &mut crate::lock::Lock,
    ops: &mut Vec<PlannedOp>,
    drift: &mut Vec<DriftRow>,
) -> Result<Vec<String>> {
    let draft = options.settings_draft.as_ref();
    let edits = draft.map_or(&[][..], |draft| draft.edits.as_slice());
    let Scope::Project { root } = scope else {
        // Nothing global ships settings, so an edit here names a key no
        // template at this place declares — which is what it is refused
        // for, in the same words a project would refuse it.
        if let Some(edit) = edits.first() {
            return Err(crate::settings_file::SettingsRefusal::Undeclared {
                skill: edit.skill.clone(),
                key: edit.key.clone(),
            }
            .into());
        }
        return Ok(Vec::new());
    };
    if state.settings_env.is_empty() && edits.is_empty() {
        return Ok(Vec::new());
    }
    let notes = crate::settings_seed::seed_notes(&state.settings_env);
    let path = crate::settings_seed::settings_file_path(root);
    let file = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| crate::settings_seed::SETTINGS_FILE.to_owned());
    if path.is_symlink() || (path.exists() && !path.is_file()) {
        // Seeding reports this and carries on with the rest of the scope.
        // An edit cannot: the person asked for exactly this file.
        if !edits.is_empty() {
            return Err(crate::settings_file::SettingsRefusal::NotRegularFile { path }.into());
        }
        drift.push(cannot_write(
            scope,
            file,
            format!("{} is not a regular file", path.display()),
        ));
        return Ok(notes);
    }
    let current = crate::fs::read_if_exists(&path)?;
    // A file that already declares env — as an array of tables, or in a
    // top-level assignment — has nowhere a setting can go, and writing
    // around it would leave a document that does not load. Said the way
    // the non-regular file is said: the plan reports it, and an edit
    // aimed at it refuses outright.
    if let Some(env) = current
        .as_deref()
        .and_then(crate::settings_seed::env_blocked)
    {
        if !edits.is_empty() {
            return Err(crate::settings_file::SettingsRefusal::EnvNotSeedable { path, env }.into());
        }
        drift.push(cannot_write(
            scope,
            file,
            format!(
                "{} {}, so no setting can be seeded",
                path.display(),
                env.problem()
            ),
        ));
        return Ok(notes);
    }
    let (seeded, added, updated) = match current.as_deref() {
        None => match crate::settings_seed::merge(None, &state.settings_env) {
            Some((text, added)) => (text, added, Vec::new()),
            None => (String::new(), Vec::new(), Vec::new()),
        },
        Some(original) => {
            let (refreshed, updated) = crate::settings_seed::refresh_comments(
                original,
                &state.settings_env,
                &mut new_lock.settings_seeds,
            );
            match crate::settings_seed::merge(Some(&refreshed), &state.settings_env) {
                Some((text, added)) => (text, added, updated),
                None => (refreshed, Vec::new(), updated),
            }
        }
    };
    // Edits land on the seeded text, never on the file as it was: a key
    // this pass just inserted is one the same pass can then set, and the
    // two are one write.
    let (text, edited) =
        crate::settings_file::apply_edits(&seeded, edits, &state.settings_env, &path)?;
    crate::settings_seed::record_seeds(&mut new_lock.settings_seeds, &state.settings_env, &added);
    // Nothing to write when the finished text is what the file already
    // holds — and, where there was no file, when there is nothing to make.
    match &current {
        Some(original) if *original == text => return Ok(notes),
        None if text.is_empty() => return Ok(notes),
        _ => {}
    }
    let mut said = Vec::new();
    if !added.is_empty() {
        said.push(format!("seed {}", added.join(", ")));
    }
    if !updated.is_empty() {
        said.push(format!("refresh the comments on {}", updated.join(", ")));
    }
    if !edited.is_empty() {
        said.push(format!("set {}", edited.join(", ")));
    }
    ops.push(PlannedOp {
        description: format!("Update {file} ({})", said.join("; ")).into(),
        op: Op::WriteFile {
            // Bound to the bytes AND to their being a plain file. This
            // path refuses a symlinked settings file above, and a check
            // before a write is a race: swapped for a link afterwards, a
            // following precondition passes on the target's bytes and the
            // write lands outside the project. The refusal travels with
            // the operation instead. An edited copy binds to the file it
            // was read from, the way the manifest's does, so a writer
            // landing after the caller's own check is refused too.
            pre: match draft {
                Some(draft) => draft.base.plain_pre(),
                None => Pre::plain_observed(&path)?,
            },
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok(notes)
}
