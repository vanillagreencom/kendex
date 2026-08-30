use kendex_core::engine::ops::{self as engine_ops, AddRequest};
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::source_ops::{self, BundleRow, SourceRow};
use kendex_core::{apply, manifest, remote};

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

/// Every declared source in every scope — the Sources page's one query.
#[tauri::command(async)]
#[specta::specta]
pub fn sources_overview() -> Result<Vec<SourceRow>, String> {
    let env = env()?;
    let mut rows = Vec::new();
    for scope in all_scopes(&env)? {
        rows.extend(source_ops::list_sources(&env, &scope).map_err(|e| e.to_string())?);
    }
    Ok(rows)
}

fn run_and_list(
    env: &Env,
    report: kendex_core::engine::EngineReport,
) -> Result<Vec<SourceRow>, String> {
    apply::execute(env, &report.plan).map_err(|e| e.to_string())?;
    sources_overview()
}

#[tauri::command(async)]
#[specta::specta]
pub fn source_add(scope: Scope, name: String, reference: String) -> Result<Vec<SourceRow>, String> {
    let env = env()?;
    let report =
        source_ops::add_source(&env, &scope, &name, &reference).map_err(|e| e.to_string())?;
    run_and_list(&env, report)
}

#[tauri::command(async)]
#[specta::specta]
pub fn source_remove(scope: Scope, name: String) -> Result<Vec<SourceRow>, String> {
    let env = env()?;
    let report = source_ops::remove_source(&env, &scope, &name).map_err(|e| e.to_string())?;
    run_and_list(&env, report)
}

#[tauri::command(async)]
#[specta::specta]
pub fn source_toggle(scope: Scope, name: String, enabled: bool) -> Result<Vec<SourceRow>, String> {
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

/// What a bundle install hands back: every set as it stands now, and the
/// repository effects its members brought for the window to ask about.
#[derive(Debug, Clone, serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct BundleInstalled {
    pub bundles: Vec<BundleRow>,
    pub repo_effects: kendex_core::repo_effects::Offers,
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
    apply::execute(env, &report.plan).map_err(|e| e.to_string())?;
    let repo_effects = kendex_core::repo_effects::offers_for(env, scope, &report.repo_effects)
        .map_err(|e| e.to_string())?;
    Ok(BundleInstalled {
        bundles: list_all_bundles(env)?,
        repo_effects,
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
