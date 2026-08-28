//! Everything a scope plan writes that is not one item's own artifact: the
//! shared config files edits land in, the install record, the manifest's
//! format line, and the settings a project's skills seed.

use std::collections::BTreeMap;
use std::path::Path;

use crate::apply::{Op, PlannedOp, Pre};
use crate::base::Base;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, SourceRev, lock_path};
use crate::manifest::Manifest;
use crate::model::{HarnessId, ItemKind, Scope};
use crate::source::SourceState;

use super::desired::DesiredState;
use super::{DriftRow, DriftState, config_edits};

mod manifest_text;
pub(super) use manifest_text::plan_schema_upgrade;

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
/// gained upstream take the full serialized write — or, without that, the
/// schema upgrade lands as a surgical text edit that keeps the user's
/// comments and formatting. One write whatever put it there: a second
/// manifest write could never run, its precondition binds to the bytes the
/// first one replaces.
///
/// `declared` is the manifest as the person wrote it, never the pinned
/// copy a single-package update plans from: the surgical edit falls back
/// to serializing it, and a synthetic pin in the file reads as a hold the
/// person chose.
pub(super) fn plan_manifest_write(
    env: &Env,
    scope: &Scope,
    declared: &Manifest,
    base: Option<&Base>,
    state: &DesiredState,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Some(update) = &state.manifest_update else {
        if declared.schema < crate::manifest::MANIFEST_SCHEMA {
            plan_schema_upgrade(env, scope, declared, base, ops)?;
        }
        return Ok(());
    };
    let path = crate::manifest::manifest_path(env, scope);
    let mut updated = update.clone();
    updated.schema = crate::manifest::MANIFEST_SCHEMA;
    ops.push(PlannedOp {
        description: "Add new catalog skills to kendex.toml".into(),
        op: Op::WriteManifest {
            pre: manifest_pre(base, &path)?,
            path,
            manifest: Box::new(updated),
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
            description: format!("Update {file} ({})", labels.join(", ")),
            op: Op::EditFile { pre, path, edits },
        });
    }
    Ok(())
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

/// Skills may ship `[env]` defaults; missing keys merge into the project's
/// kendex.settings.toml write-if-absent (v1 semantics — a key the user set
/// anywhere in the file is never touched), and seeded comment blocks whose
/// template improved are refreshed while provably unedited — gated by the
/// lock's per-key ledger, which this plan carries forward on `new_lock`.
///
/// The notes go out before any of it: a shared key several packages give
/// different defaults is worth saying whether or not this pass has a write
/// to plan for it.
pub(super) fn plan_settings_seed(
    scope: &Scope,
    state: &DesiredState,
    new_lock: &mut crate::lock::Lock,
    ops: &mut Vec<PlannedOp>,
    drift: &mut Vec<DriftRow>,
) -> Result<Vec<String>> {
    let Scope::Project { root } = scope else {
        return Ok(Vec::new());
    };
    if state.settings_env.is_empty() {
        return Ok(Vec::new());
    }
    let notes = crate::settings_seed::conflict_notes(&state.settings_env);
    let path = crate::settings_seed::settings_file_path(root);
    let file = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| crate::settings_seed::SETTINGS_FILE.to_owned());
    if path.is_symlink() || (path.exists() && !path.is_file()) {
        drift.push(DriftRow {
            kind: ItemKind::Skill,
            name: file,
            harness: HarnessId::Claude,
            scope: scope.clone(),
            state: DriftState::Conflict,
            detail: format!("{} is not a regular file", path.display()),
            cause: None,
            compared: None,
            also_in_the_way: Vec::new(),
        });
        return Ok(notes);
    }
    let current = crate::fs::read_if_exists(&path)?;
    let (text, added, updated) = match current.as_deref() {
        None => match crate::settings_seed::merge(None, &state.settings_env) {
            Some((text, added)) => (text, added, Vec::new()),
            None => return Ok(notes),
        },
        Some(original) => {
            let (refreshed, updated) = crate::settings_seed::refresh_comments(
                original,
                &state.settings_env,
                &mut new_lock.settings_seeds,
            );
            match crate::settings_seed::merge(Some(&refreshed), &state.settings_env) {
                Some((text, added)) => (text, added, updated),
                None if !updated.is_empty() => (refreshed, Vec::new(), updated),
                None => return Ok(notes),
            }
        }
    };
    crate::settings_seed::record_seeds(&mut new_lock.settings_seeds, &state.settings_env, &added);
    let mut said = Vec::new();
    if !added.is_empty() {
        said.push(format!("seed {}", added.join(", ")));
    }
    if !updated.is_empty() {
        said.push(format!("refresh the comments on {}", updated.join(", ")));
    }
    ops.push(PlannedOp {
        description: format!("Update {file} ({})", said.join("; ")),
        op: Op::WriteFile {
            pre: crate::apply::Pre::observed(&path)?,
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok(notes)
}
