//! The package page's and Updates page's commands: versions, diffs, files,
//! provenance, holds, forks, and the update check — thin shells over core,
//! like every other command here.

use kendex_core::apply;
use kendex_core::engine;
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::package::{self, detail, diff, updates};
use kendex_core::{manifest, remote};
use serde::Serialize;
use specta::Type;

use crate::audit::{AuditView, view};

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

fn all_scopes(env: &Env) -> Result<Vec<Scope>, String> {
    let settings = kendex_core::settings::load(env).map_err(|e| e.to_string())?;
    let mut scopes = vec![Scope::Global];
    scopes.extend(
        settings
            .projects
            .into_iter()
            .map(|root| Scope::Project { root }),
    );
    Ok(scopes)
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

/// Every scope's update standing in one query — the sidebar badge, the
/// Updates page, and the Library's fork/edited flags all read this. Rows
/// carry the facts; warnings carry every package the standing could not be
/// computed for, which is never silently shown as current.
#[tauri::command(async)]
#[specta::specta]
pub fn updates_overview() -> Result<updates::UpdatesReport, String> {
    let env = env()?;
    let mut merged = updates::UpdatesReport {
        rows: Vec::new(),
        warnings: Vec::new(),
    };
    for scope in all_scopes(&env)? {
        let report = updates::updates(&env, &scope).map_err(|e| e.to_string())?;
        // The deep work just ran; the session-start check reads this. A
        // failure is a warning on the page, never silence — the CLI paths
        // say the same thing.
        if let Err(error) = kendex_core::drift::snapshot::record_with(&env, &scope, &report) {
            merged.warnings.push(kendex_core::engine::ItemWarning {
                kind: kendex_core::model::ItemKind::Skill,
                name: scope.label(),
                harness: None,
                message: format!("drift snapshot not derived: {error}"),
                remediation: None,
            });
        }
        merged.rows.extend(report.rows);
        merged.warnings.extend(report.warnings);
    }
    Ok(merged)
}

/// Fetch every source's mirror — pinned ones included, that is the point —
/// then answer with the fresh standing. Fetch problems degrade to
/// warnings; a check for updates is never worth an error dialog.
#[tauri::command(async)]
#[specta::specta]
pub fn updates_refresh() -> Result<updates::UpdatesReport, String> {
    let env = env()?;
    for scope in all_scopes(&env)? {
        let path = manifest::manifest_path(&env, &scope);
        if let Ok(Some(loaded)) = manifest::load_for_mutation(&path) {
            let _warnings = remote::fetch_all(&env, &loaded);
        }
    }
    updates_overview()
}

#[tauri::command(async)]
#[specta::specta]
pub fn update_set_ignored(
    scope: Scope,
    kind: ItemKind,
    name: String,
    repo: String,
    ignored: bool,
) -> Result<updates::UpdatesReport, String> {
    let env = env()?;
    updates::set_ignored(&env, &scope, kind, &name, &repo, ignored).map_err(|e| e.to_string())?;
    updates_overview()
}

/// What a single-package apply did to the package it named, beside the
/// scope's view afterwards. The plan holds a rendering back rather than
/// writing over a copy somebody changed, and the view alone cannot say
/// which of the two happened — a caller reading only the view says
/// "Updated" over a package that never moved.
#[derive(serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageUpdate {
    pub view: AuditView,
    /// Renderings the plan refused to write over. Empty when the package
    /// moved everywhere it is installed.
    pub held_back: Vec<engine::DriftRow>,
    /// Renderings this apply wrote. Non-empty beside `held_back` is the
    /// partial case: current in one tool, held in another.
    pub moved: Vec<engine::DriftRow>,
}

/// Bring one package current and apply — the Updates page's per-package
/// and per-place Update, and the package page's. The scope's other
/// followers stay at the commits their lock records, except one the lock
/// cannot place, which resolves fresh the way a whole-scope apply gives it
/// anyway. `kendex refresh` and the whole-scope apply are the plans that
/// bring a whole place current; `Update all` reaches the same end by
/// running this command once per row.
#[tauri::command(async)]
#[specta::specta]
pub fn package_update(scope: Scope, kind: ItemKind, name: String) -> Result<PackageUpdate, String> {
    // The same refusal the CLI verb makes, for the same reason: a kind the
    // engine never derives plans nothing, and an empty plan reads as
    // "already current" on the page that asked.
    if !engine::plans_per_package(kind) {
        return Err(format!(
            "{} '{name}' {}",
            kind.name(),
            engine::NO_PER_PACKAGE_UPDATE
        ));
    }
    let env = env()?;
    let report = package::update_one(&env, &scope, kind, &name).map_err(|e| e.to_string())?;
    let held_back = package::held_back(&report, kind, &name)
        .into_iter()
        .cloned()
        .collect();
    let moved = package::moving(&report, kind, &name)
        .into_iter()
        .cloned()
        .collect();
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(PackageUpdate {
        view: view(&env, &scope),
        held_back,
        moved,
    })
}

/// Hold a package at a version (or let it follow again) and apply the
/// change, scoped to the package: every other follower in the scope reads
/// the commit its lock records, so moving one hold does not bring the
/// neighbours current. The exception is a follower the lock cannot place
/// — never installed, or installations disagreeing — which resolves fresh
/// here as it would under a whole-scope apply.
#[tauri::command(async)]
#[specta::specta]
pub fn package_set_rev(
    scope: Scope,
    kind: ItemKind,
    name: String,
    rev: Option<String>,
) -> Result<AuditView, String> {
    let env = env()?;
    let report = package::set_rev_with(
        &env,
        &scope,
        kind,
        &name,
        rev.as_deref(),
        &engine::PlanOptions::for_package(kind, &name),
    )
    .map_err(|e| e.to_string())?;
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
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
    apply::execute(&env, &plan, None).map_err(|e| refused(e.to_string()))?;
    render_scope(&env, &scope).map_err(|message| ForkBesideError::Recorded { message })
}

/// Apply one plan, then render the scope it changed.
fn settle(env: &Env, scope: &Scope, plan: &apply::Plan) -> Result<AuditView, String> {
    apply::execute(env, plan, None).map_err(|e| e.to_string())?;
    render_scope(env, scope)
}

/// Bring a scope's installs in line with its manifest and answer with the
/// standing that leaves.
fn render_scope(env: &Env, scope: &Scope) -> Result<AuditView, String> {
    let report = engine::audit(env, scope).map_err(|e| e.to_string())?;
    apply::execute(env, &report.plan, None).map_err(|e| e.to_string())?;
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
    apply::execute(&env, &plan, None).map_err(|e| e.to_string())?;
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
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
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
        apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
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
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
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
