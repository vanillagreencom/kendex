//! The package page's and Updates page's commands: versions, diffs, files,
//! provenance, holds, forks, and the update check — thin shells over core,
//! like every other command here.

use kendex_core::apply;
use kendex_core::engine;
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::package::{self, detail, diff, updates};
use kendex_core::{manifest, remote};

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

/// Hold a package at a version (or let it follow again) and apply the
/// change. The plan is whole-scope, like every apply: packages that follow
/// their source come current in the same pass, which is what following
/// means.
#[tauri::command(async)]
#[specta::specta]
pub fn package_set_rev(
    scope: Scope,
    kind: ItemKind,
    name: String,
    rev: Option<String>,
) -> Result<AuditView, String> {
    let env = env()?;
    let report =
        package::set_rev(&env, &scope, kind, &name, rev.as_deref()).map_err(|e| e.to_string())?;
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
    apply::execute(&env, &plan, None).map_err(|e| e.to_string())?;
    let report = engine::audit(&env, &scope).map_err(|e| e.to_string())?;
    apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(view(&env, &scope))
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

/// Apply a scope with one package's edits discarded — the door back to
/// "the catalog's version wins", scoped to the package the user named so
/// a neighbour's edits are never taken along.
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
            &engine::PlanOptions {
                overwrite_edited_names: Some(vec![(kind, name.clone())]),
                only_names: Some(vec![(kind, name.clone())]),
                ..Default::default()
            },
        )
        .map_err(|e| e.to_string())?;
        // The same question the path below asks: a plan can carry the
        // revision change and no rendering for the package — the new
        // version can be held back by the safety gate — and applying that
        // would move the record while the edited files stayed, under a
        // line saying the content was replaced.
        let missing = report.unrendered();
        if missing.iter().any(|(k, n)| *k == kind && n == &name) {
            return Err(format!(
                "{name} was edited, and nothing here rendered the version you chose to put in its place — Review reports what is holding it"
            ));
        }
        // And what that version needs, which can be refused on its own
        // account: applied anyway, the package comes back unable to run.
        if let Some((needed, needs)) = missing.first() {
            return Err(format!(
                "{name} needs {} '{needs}', and nothing here rendered it — Review reports what is holding it",
                needed.name()
            ));
        }
        apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
        return Ok(view(&env, &scope));
    }
    // The plan below is the scope's, and the permission it carries is this
    // package's alone: with no edit to overwrite, executing it would apply
    // whatever else the scope had pending under an action about this one.
    match engine::edited_here(&env, &scope, kind, &name).map_err(|e| e.to_string())? {
        engine::EditedHere::Yes => {}
        engine::EditedHere::No => return Ok(view(&env, &scope)),
        // Nothing was rendered to compare against, so there is nothing to
        // put the files back to. Returning the view would report the
        // discard as done with the edited bytes still there.
        engine::EditedHere::Unmeasured => {
            return Err(format!(
                "{name} could not be read from its source, so its files cannot be put back"
            ));
        }
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
        &engine::PlanOptions {
            overwrite_edited_names: Some(vec![(kind, name.clone())]),
            only_names: Some(vec![(kind, name.clone())]),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    // Whether this package got a rendering, asked of the plan rather than
    // read off its op list: a scope carries its own maintenance, so ops
    // exist whether or not the package named got one.
    let missing = report.unrendered();
    if missing.iter().any(|(k, n)| *k == kind && n == &name) {
        return Err(format!(
            "{name} was edited, and nothing here rendered its declared content to put back — Review reports what is holding it"
        ));
    }
    if let Some((needed, needs)) = missing.first() {
        return Err(format!(
            "{name} needs {} '{needs}', and nothing here rendered it — Review reports what is holding it",
            needed.name()
        ));
    }
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
