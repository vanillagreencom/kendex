use kendex_core::engine::ops::{self as engine_ops, AddRequest};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::source_ops::{self, BundleRow, SourceRow};
use kendex_core::{manifest, remote};

use crate::scopes::{all as all_scopes, env};

/// Every declared source in every scope — the Sources page's one query.
#[tauri::command(async)]
#[specta::specta]
pub fn sources_overview() -> Result<Vec<SourceRow>, String> {
    list_all_sources(&env()?)
}

/// The same listing against the environment it is given, for a caller that
/// already holds one.
fn list_all_sources(env: &Env) -> Result<Vec<SourceRow>, String> {
    let mut rows = Vec::new();
    for scope in all_scopes(env)? {
        rows.extend(source_ops::list_sources(env, &scope).map_err(|e| e.to_string())?);
    }
    Ok(rows)
}

/// What a source action leaves: every declared source across every scope,
/// and what the removal did about the repository effects of any package
/// that left with it — the same account the terminal prints, so the window
/// says what ran rather than leaving a repository armed against scripts
/// that are gone.
#[derive(Debug, Clone, serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct SourcesAfter {
    pub sources: Vec<SourceRow>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
}

/// Write a source action's report and answer with what stands after it.
///
/// Through the one executor, like every report. Removing or disabling a
/// source takes its packages with it, and adding one can too — a rendering
/// the engine refuses drops that package's lock entry whatever the
/// planning options say. No command here has to know which it is, and that
/// is the point of there being one door.
fn run_and_list(
    env: &Env,
    report: kendex_core::engine::EngineReport,
) -> Result<SourcesAfter, String> {
    let undone = crate::repo_effects::write(env, &report)?;
    // Everything past the write is enrichment, and the account rides on
    // its failure rather than through it.
    let sources = crate::repo_effects::after_writing(&undone, list_all_sources(env))?;
    Ok(SourcesAfter { sources, undone })
}

#[tauri::command(async)]
#[specta::specta]
pub fn source_add(scope: Scope, name: String, reference: String) -> Result<SourcesAfter, String> {
    let env = env()?;
    let report =
        source_ops::add_source(&env, &scope, &name, &reference).map_err(|e| e.to_string())?;
    run_and_list(&env, report)
}

#[tauri::command(async)]
#[specta::specta]
pub fn source_remove(scope: Scope, name: String) -> Result<SourcesAfter, String> {
    let env = env()?;
    let report = source_ops::remove_source(&env, &scope, &name).map_err(|e| e.to_string())?;
    run_and_list(&env, report)
}

#[tauri::command(async)]
#[specta::specta]
pub fn source_toggle(scope: Scope, name: String, enabled: bool) -> Result<SourcesAfter, String> {
    let env = env()?;
    let report =
        source_ops::toggle_source(&env, &scope, &name, enabled).map_err(|e| e.to_string())?;
    run_and_list(&env, report)
}

/// Every curated set every catalog offers, across every scope.
fn list_all_bundles(env: &Env) -> Result<Vec<BundleRow>, String> {
    let mut rows = Vec::new();
    for scope in all_scopes(env)? {
        rows.extend(source_ops::list_bundles(env, &scope).map_err(|e| e.to_string())?);
    }
    Ok(rows)
}

/// What the Catalogs page lists under each source — one query.
#[tauri::command(async)]
#[specta::specta]
pub fn bundles_overview() -> Result<Vec<BundleRow>, String> {
    list_all_bundles(&env()?)
}

/// What a bundle install hands back: every set as it stands now, the
/// repository effects its members brought for the window to ask about, and
/// what any package the plan took away had undone.
#[derive(Debug, Clone, serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleInstalled {
    pub bundles: Vec<BundleRow>,
    pub repo_effects: kendex_core::repo_effects::Offers,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
}

/// Install a set whole. Its members derive from the catalog, so this declares
/// one name and applies the plan that follows from it.
#[tauri::command(async)]
#[specta::specta]
pub fn bundle_install(
    scope: Scope,
    source: String,
    name: String,
    hold: bool,
) -> Result<BundleInstalled, String> {
    let env = env()?;
    install_bundle(&env, &scope, source, name, hold)
}

/// The bundle install itself, against the environment it is given.
pub fn install_bundle(
    env: &Env,
    scope: &Scope,
    source: String,
    name: String,
    hold: bool,
) -> Result<BundleInstalled, String> {
    let request = AddRequest {
        source: Some(source),
        bundles: vec![name],
        no_auto_skills: true,
        hold,
        ..AddRequest::default()
    };
    let report = engine_ops::add(env, scope, &request).map_err(|e| e.to_string())?;
    // The one executor, as everywhere. A set install is an add, which is
    // not the same as taking nothing away: a refused rendering removes the
    // package it refused, and nothing here is written to depend otherwise.
    let undone = crate::repo_effects::write(env, &report)?;
    // Both reads are enrichment past the write, so both carry the account
    // on their failure rather than through it.
    let repo_effects = crate::repo_effects::after_writing(
        &undone,
        kendex_core::repo_effects::offers_for(env, scope, &report.repo_effects)
            .map_err(|e| e.to_string()),
    )?;
    let bundles = crate::repo_effects::after_writing(&undone, list_all_bundles(env))?;
    Ok(BundleInstalled {
        bundles,
        repo_effects,
        undone,
    })
}

/// Re-resolve every enabled remote across every scope. Returns warnings
/// (offline caches keep serving); hard failures surface as the error.
#[tauri::command(async)]
#[specta::specta]
pub fn sources_refresh() -> Result<Vec<String>, String> {
    let env = env()?;
    let mut warnings = Vec::new();
    for scope in all_scopes(&env)? {
        let path = manifest::manifest_path(&env, &scope);
        if let Ok(Some(loaded)) = manifest::load_for_mutation(&path) {
            warnings.extend(remote::sync_sources(&env, &loaded).map_err(|e| e.to_string())?);
        }
    }
    Ok(warnings)
}
