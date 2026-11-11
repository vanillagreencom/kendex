use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::remote;
use kendex_core::source_ops;

use crate::scopes::{all as all_scopes, env};

/// What a source action leaves: the account of the write
/// (`crates/app/src/repo_effects.rs::execute`).
///
/// Nothing is read back behind the write. The window reads every
/// subscription again itself once the toggle answers, so a read here would
/// only be a way for a written toggle to be reported as refused.
#[derive(Debug, Clone, serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct SourcesAfter {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
}

/// Write a source action's report and answer with what it undid.
///
/// Through the one executor, like every report. Disabling a source takes
/// its packages with it, and a rendering the engine refuses drops that
/// package's lock entry whatever the planning options say — so this route
/// runs uninstallers without having asked for a removal, and does not
/// have to know that to report one.
fn run(env: &Env, report: kendex_core::engine::EngineReport) -> Result<SourcesAfter, String> {
    let undone = crate::repo_effects::write(env, &report)?;
    Ok(SourcesAfter { undone })
}

#[tauri::command(async)]
#[specta::specta]
pub fn source_toggle(scope: Scope, name: String, enabled: bool) -> Result<SourcesAfter, String> {
    let env = env()?;
    let report =
        source_ops::toggle_source(&env, &scope, &name, enabled).map_err(|e| e.to_string())?;
    run(&env, report)
}

/// Re-resolve every enabled remote across every scope. Returns warnings
/// (offline caches keep serving); hard failures surface as the error.
#[tauri::command(async)]
#[specta::specta]
pub fn sources_refresh() -> Result<Vec<String>, String> {
    let env = env()?;
    refresh(&env, &all_scopes(&env)?)
}

/// Every enabled remote source of the scopes given, fetched. A scope with
/// no manifest file yet is read as its first write would create it, so a
/// fresh machine's refresh reaches the default marketplace the pages
/// already list; a file this build cannot read is passed over here, the
/// way it was, and refused where it is next written. Separate from the
/// command so a test can reach it the way [`crate::marketplaces::rows`]
/// is reached.
pub fn refresh(env: &Env, scopes: &[Scope]) -> Result<Vec<String>, String> {
    let mut warnings = Vec::new();
    for scope in scopes {
        if let Ok(loaded) = kendex_core::engine::ops::manifest_for_reading(env, scope) {
            warnings.extend(
                remote::sync_sources(env, &loaded)
                    .map_err(|e| e.to_string())?
                    .notes,
            );
        }
    }
    Ok(warnings)
}
