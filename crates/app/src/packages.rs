//! The package page's commands: versions, diffs, files, provenance, holds,
//! and forks — thin shells over core, like every other command here. The
//! Updates page's standing is its own module, `update_check`.

use kendex_core::apply;
use kendex_core::engine;
use kendex_core::env::Env;
use kendex_core::error::CoreError;
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::package::{self, detail, diff};
use serde::Serialize;
use specta::Type;

use crate::audit::{AuditView, settle_report};

pub mod update;

use crate::scopes::env;

/// Whether core is saying there is no managed package here for the page to
/// describe, rather than that a read went wrong: nothing is declared under
/// this name — a derived bundle member or dependency, an unmanaged or vendor
/// copy — or the declaration binds to a source with no repository, which is
/// every fork, path and local install.
///
/// Both are answers about the manifest, and asking again over the same
/// manifest answers the same. The page draws what it has and says nothing;
/// only a read that could have gone otherwise is worth a note and a retry
/// there, so the two shells below hand those back as an absent value rather
/// than as an error the page would have to tell apart from a real one.
fn no_managed_package(error: &CoreError) -> bool {
    matches!(
        error,
        CoreError::NotDeclared { .. } | CoreError::ItemRevUnsupported { .. }
    )
}

#[tauri::command(async)]
#[specta::specta]
pub fn package_versions(
    scope: Scope,
    kind: ItemKind,
    name: String,
) -> Result<Vec<package::VersionRow>, String> {
    let env = env()?;
    match package::versions(&env, &scope, kind, &name) {
        Ok(rows) => Ok(rows),
        // No timeline to draw, which an empty log already says.
        Err(error) if no_managed_package(&error) => Ok(Vec::new()),
        Err(error) => Err(error.to_string()),
    }
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
    settle_report(env, scope, &report)
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
        return settle_report(&env, &scope, &report);
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
    settle_report(&env, &scope, &report)
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

/// `None` where nothing is declared under this name — a derived bundle member
/// or dependency, an unmanaged or vendor copy. That is this command's whole
/// half of [`no_managed_package`]: `detail::package_meta` reads a source's
/// repository off the manifest rather than binding to one, so the other
/// variant cannot escape it; that half is [`package_versions`]'s, which does
/// bind. The CLI's own `show` keeps core's refusal either way: it was asked
/// about one package and has nothing else to draw.
#[tauri::command(async)]
#[specta::specta]
pub fn package_meta(
    scope: Scope,
    kind: ItemKind,
    name: String,
) -> Result<Option<detail::PackageMeta>, String> {
    let env = env()?;
    match detail::package_meta(&env, &scope, kind, &name) {
        Ok(meta) => Ok(Some(meta)),
        Err(error) if no_managed_package(&error) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::model::ItemKind;

    // The two the page draws nothing for and reports nothing about. Both are
    // answers about the manifest: a derived member or an unmanaged copy is in
    // no declared map, and a fork, path or local install has no repository to
    // take revisions from.
    #[test]
    fn no_managed_package_covers_the_manifest_answers() {
        assert!(no_managed_package(&CoreError::NotDeclared {
            kind: ItemKind::Skill,
            name: "gh".to_owned(),
        }));
        assert!(no_managed_package(&CoreError::ItemRevUnsupported {
            source_name: "local".to_owned(),
        }));
    }

    // Everything else is a read that went wrong, and the page says so with a
    // way to run it again. A lock this build refuses is the case that must
    // not be swallowed: it is the same shape as the two above and a real
    // failure.
    #[test]
    fn a_read_that_failed_is_not_one_of_them() {
        assert!(!no_managed_package(&CoreError::LockCorrupt {
            path: "lock".into(),
            message: "unparsable".to_owned(),
        }));
    }
}
