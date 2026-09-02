use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::source_ops::{self, SourceRow};
use kendex_core::{manifest, remote};

use crate::scopes::{all as all_scopes, env};

/// Every declared source in every scope, against the environment it is
/// given.
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
/// Through the one executor, like every report. Disabling a source takes
/// its packages with it, and a rendering the engine refuses drops that
/// package's lock entry whatever the planning options say — so this route
/// runs uninstallers without having asked for a removal, and does not
/// have to know that to report one.
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
pub fn source_toggle(scope: Scope, name: String, enabled: bool) -> Result<SourcesAfter, String> {
    let env = env()?;
    let report =
        source_ops::toggle_source(&env, &scope, &name, enabled).map_err(|e| e.to_string())?;
    run_and_list(&env, report)
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
