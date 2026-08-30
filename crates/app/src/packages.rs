//! The package page's commands: versions, diffs, files, provenance, holds,
//! and forks — thin shells over core, like every other command here. The
//! Updates page's standing is its own module, `update_check`.

use kendex_core::apply;
use kendex_core::engine;
use kendex_core::env::Env;
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::package::{self, detail, diff};
use serde::Serialize;
use specta::Type;

use crate::audit::{AuditView, view};

pub mod update;

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn package_versions(
    scope: Scope,
    kind: ItemKind,
    name: String,
) -> Result<Vec<package::VersionRow>, String> {
    let env = env()?;
    package::versions(&env, &scope, kind, &name).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn package_diff(
    scope: Scope,
    kind: ItemKind,
    name: String,
    from: diff::VersionSel,
    to: diff::VersionSel,
    harness: Option<HarnessId>,
) -> Result<diff::PackageDiff, String> {
    let env = env()?;
    diff::package_diff(&env, &scope, kind, &name, &from, &to, harness).map_err(|e| e.to_string())
}

/// Keep an edited install as a local fork, then render it in place.
#[tauri::command(async)]
#[specta::specta]
pub fn package_fork(
    scope: Scope,
    kind: ItemKind,
    name: String,
    harness: HarnessId,
) -> Result<AuditView, String> {
    let env = env()?;
    let plan = engine::fork::fork(&env, &scope, kind, &name, harness).map_err(|e| e.to_string())?;
    settle(&env, &scope, &plan)
}

/// Why installing beside did not finish, by phase: a refusal wrote
/// nothing, so another name may well go through; a fork the scope already
/// recorded but could not render needs an apply, not a different name.
#[derive(Debug, Serialize, Type)]
#[serde(tag = "phase", rename_all = "kebab-case")]
pub enum ForkBesideError {
    Refused { message: String },
    Recorded { message: String },
}

/// Keep an edited install as a local fork under a new name, leave the
/// original on its source, then render both.
#[tauri::command(async)]
#[specta::specta]
pub fn package_fork_beside(
    scope: Scope,
    kind: ItemKind,
    name: String,
    harness: HarnessId,
    new_name: String,
    rev: Option<String>,
) -> Result<AuditView, ForkBesideError> {
    let refused = |message: String| ForkBesideError::Refused { message };
    let env = env().map_err(refused)?;
    let plan = engine::fork::fork_beside(
        &env,
        &scope,
        kind,
        &name,
        harness,
        &new_name,
        rev.as_deref(),
    )
    .map_err(|e| refused(e.to_string()))?;
    // A plan that fails to apply rolls back: nothing recorded, a refusal.
    apply::execute(&env, &plan).map_err(|e| refused(e.to_string()))?;
    render_scope(&env, &scope).map_err(|message| ForkBesideError::Recorded { message })
}

/// Apply one plan, then render the scope it changed.
fn settle(env: &Env, scope: &Scope, plan: &apply::Plan) -> Result<AuditView, String> {
    apply::execute(env, plan).map_err(|e| e.to_string())?;
    render_scope(env, scope)
}

/// Bring a scope's installs in line with its manifest and answer with the
/// standing that leaves.
fn render_scope(env: &Env, scope: &Scope) -> Result<AuditView, String> {
    let report = engine::audit(env, scope).map_err(|e| e.to_string())?;
    apply::execute(env, &report.plan).map_err(|e| e.to_string())?;
    Ok(view(env, scope))
}

#[tauri::command(async)]
#[specta::specta]
pub fn fork_rename(
    scope: Scope,
    kind: ItemKind,
    old_name: String,
    new_name: String,
) -> Result<AuditView, String> {
    let env = env()?;
    let plan = engine::fork::rename_fork(&env, &scope, kind, &old_name, &new_name)
        .map_err(|e| e.to_string())?;
    apply::execute(&env, &plan).map_err(|e| e.to_string())?;
    // The old name's artifacts come off disk with the rename — the user
    // asked for this by name, which is what an explicit removal is.
    let report = kendex_core::engine::plan_scope(
        &env,
        &scope,
        &manifest::load_for_mutation(&manifest::manifest_path(&env, &scope))
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "no manifest".to_owned())?,
        &kendex_core::lock::load(&kendex_core::lock::lock_path(&env, &scope))
            .map_err(|e| e.to_string())?,
        &engine::PlanOptions {
            remove_orphans: true,
            removal_filter: Some(vec![old_name]),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    apply::execute(&env, &report.plan).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
}

/// Discard one package's edits and re-render it — the door back to "the
/// catalog's version wins". Scoped to the package the user named twice
/// over: a neighbour's edits are never taken along, and the scope's other
/// followers stay at their installed commits — bar one the lock cannot
/// place, which resolves fresh here as under a whole-scope apply.
#[tauri::command(async)]
#[specta::specta]
pub fn apply_discard_edits(
    scope: Scope,
    kind: ItemKind,
    name: String,
    rev: Option<String>,
) -> Result<AuditView, String> {
    let env = env()?;
    // A held package's "use new version" moves the hold and drops the
    // edits in one apply; planned from the old manifest, the discard would
    // only restore the version the edits were made on.
    if let Some(rev) = rev {
        let report = package::set_rev_with(
            &env,
            &scope,
            kind,
            &name,
            Some(&rev),
            &engine::PlanOptions::for_package_discarding_edits(kind, &name),
        )
        .map_err(|e| e.to_string())?;
        apply::execute(&env, &report.plan).map_err(|e| e.to_string())?;
        return Ok(view(&env, &scope));
    }
    let manifest = manifest::load_for_mutation(&manifest::manifest_path(&env, &scope))
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "no manifest".to_owned())?;
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&env, &scope))
        .map_err(|e| e.to_string())?;
    let report = kendex_core::engine::plan_scope(
        &env,
        &scope,
        &manifest,
        &lock,
        &engine::PlanOptions::for_package_discarding_edits(kind, name),
    )
    .map_err(|e| e.to_string())?;
    apply::execute(&env, &report.plan).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
}

#[tauri::command(async)]
#[specta::specta]
pub fn package_files(
    scope: Scope,
    kind: ItemKind,
    name: String,
) -> Result<Vec<detail::PackageFile>, String> {
    let env = env()?;
    detail::package_files(&env, &scope, kind, &name).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn package_file(
    scope: Scope,
    kind: ItemKind,
    name: String,
    path: String,
) -> Result<engine::ItemSource, String> {
    let env = env()?;
    detail::package_file(&env, &scope, kind, &name, &path).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn package_readme(
    scope: Scope,
    kind: ItemKind,
    name: String,
) -> Result<Option<engine::ItemSource>, String> {
    let env = env()?;
    detail::package_readme(&env, &scope, kind, &name).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn package_meta(
    scope: Scope,
    kind: ItemKind,
    name: String,
) -> Result<detail::PackageMeta, String> {
    let env = env()?;
    detail::package_meta(&env, &scope, kind, &name).map_err(|e| e.to_string())
}
