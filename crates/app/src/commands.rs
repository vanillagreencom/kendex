use kendex_core::env::Env;
use kendex_core::harness::{KindCaps, capabilities};
use kendex_core::model::{HarnessId, ItemKind};
use kendex_core::scan;
use kendex_core::scan::ScanResult;
use kendex_core::settings;
use serde::Serialize;
use specta::Type;

use crate::scopes::env;

// A `Result` for the transport fold, not for a refusal: `specta_builder`.
#[tauri::command]
#[specta::specta]
pub fn app_version() -> Result<String, String> {
    Ok(env!("CARGO_PKG_VERSION").to_owned())
}

#[tauri::command(async)]
#[specta::specta]
pub fn scan_machine() -> Result<ScanResult, String> {
    let env = env()?;
    let app_settings = settings::load(&env).map_err(|e| e.to_string())?;
    Ok(scan::scan(&env, &app_settings))
}

/// Install the session-start drift report hook for a scope: script into the
/// scope's local source, declaration into its manifest, then the ordinary
/// apply renders it. The offer surface (project registration) calls this
/// after the user says yes — the declared, user-approved install per scope.
/// Returns whether the hook was fully rendered. The user approved the hook
/// and nothing else, so the rendering apply runs only when the scope had no
/// other pending work; otherwise the declaration lands and `false` says the
/// scope's next apply finishes the job.
#[tauri::command(async)]
#[specta::specta]
pub fn install_drift_hook(scope: kendex_core::model::Scope) -> Result<bool, String> {
    let env = env()?;
    let options = kendex_core::engine::PlanOptions::default();
    let pending = kendex_core::engine::plan_apply(&env, &scope, &options)
        .map_err(|e| e.to_string())?
        .plan;
    let plan = kendex_core::drift::hook::install_plan(&env, &scope).map_err(|e| e.to_string())?;
    kendex_core::apply::execute(&env, &plan).map_err(|e| e.to_string())?;
    if !pending.is_empty() {
        return Ok(false);
    }
    let report =
        kendex_core::engine::plan_apply(&env, &scope, &options).map_err(|e| e.to_string())?;
    // Through the one executor, like every other report. Nothing was
    // pending when this started, so the lock this plan writes is the one
    // the scope already carries and no package leaves with it — which is
    // what makes it safe to run a whole-scope plan off a yes given about a
    // drift report. Checked rather than claimed: this command answers a
    // bool and has nowhere to say what an uninstaller did.
    crate::repo_effects::write_nothing_leaving(&env, &report)?;
    Ok(true)
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityRow {
    pub harness: HarnessId,
    pub kind: ItemKind,
    pub caps: KindCaps,
}

/// The full harness × kind capability matrix — the UI gates every action on
/// this, never on its own assumptions.
// A `Result` for the transport fold, not for a refusal: `specta_builder`.
#[tauri::command]
#[specta::specta]
pub fn capability_table() -> Result<Vec<CapabilityRow>, String> {
    let mut rows = Vec::new();
    for harness in HarnessId::ALL {
        for kind in ItemKind::ALL {
            rows.push(CapabilityRow {
                harness,
                kind,
                caps: capabilities(harness, kind),
            });
        }
    }
    Ok(rows)
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ReportRouteView {
    pub kendex_owned: bool,
    pub repo: Option<String>,
    pub label: Option<String>,
    /// Prefilled issue page — only when the report belongs upstream.
    pub issue_url: Option<String>,
    /// Install-record and scan failures kept beside fallback routing.
    pub warnings: Vec<String>,
}

/// Where a problem report about this item belongs: the kendex upstream
/// (with a prefilled issue link) or the user's own repo.
#[tauri::command(async)]
#[specta::specta]
pub fn report_route(
    scope: kendex_core::model::Scope,
    name: String,
    kind: Option<ItemKind>,
) -> Result<ReportRouteView, String> {
    route_for(&env()?, &scope, &name, kind)
}

fn route_for(
    env: &Env,
    scope: &kendex_core::model::Scope,
    name: &str,
    kind: Option<ItemKind>,
) -> Result<ReportRouteView, String> {
    let resolved = kendex_core::report::resolve(
        env,
        scope,
        name,
        kind,
        kendex_core::report::DEFAULT_UPSTREAM,
    );
    let route = resolved.route;
    let issue_url = route.repo.as_ref().map(|repo| {
        let mut url = format!(
            "https://github.com/{repo}/issues/new?title={}",
            kendex_core::names::urlencoded(&format!("{name}: "))
        );
        if let Some(label) = &route.label {
            url.push_str(&format!("&labels={label}"));
        }
        url
    });
    Ok(ReportRouteView {
        kendex_owned: route.kendex_owned,
        repo: route.repo,
        label: route.label,
        issue_url,
        warnings: resolved.warnings,
    })
}

#[cfg(test)]
mod tests {
    use super::route_for;
    use kendex_core::env::{Env, FakeOs};
    use kendex_core::model::Scope;

    #[test]
    fn old_and_malformed_locks_keep_the_warning_beside_fallback_routing() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("dev/app");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(
            project.join("kendex.toml"),
            "schema = 6\n[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n[skills.gh]\nsource = \"kendex\"\n",
        )
        .unwrap();
        let scope = Scope::Project {
            root: project.clone(),
        };

        for record in [
            "{\"version\":5}\n".to_owned(),
            format!(r#"{{"version":{}"#, kendex_core::lock::LOCK_VERSION),
        ] {
            std::fs::write(project.join(".kendex-lock.json"), record).unwrap();
            let route = route_for(&env, &scope, "gh", None).unwrap();
            assert!(route.kendex_owned);
            assert_eq!(route.repo.as_deref(), Some("vanillagreencom/kendex"));
            assert_eq!(route.warnings.len(), 1);
            assert!(route.warnings[0].contains("install record unreadable"));
        }
    }
}
