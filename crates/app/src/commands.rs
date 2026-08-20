use kendex_core::env::Env;
use kendex_core::harness::{KindCaps, capabilities};
use kendex_core::model::{HarnessId, ItemKind};
use kendex_core::scan::ScanResult;
use kendex_core::settings::{self, AppSettings};
use kendex_core::{discover, scan};
use serde::Serialize;
use specta::Type;

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

#[tauri::command]
#[specta::specta]
pub fn app_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[tauri::command(async)]
#[specta::specta]
pub fn scan_machine() -> Result<ScanResult, String> {
    let env = env()?;
    let app_settings = settings::load(&env).map_err(|e| e.to_string())?;
    Ok(scan::scan(&env, &app_settings))
}

#[tauri::command(async)]
#[specta::specta]
pub fn get_settings() -> Result<AppSettings, String> {
    settings::load(&env()?).map_err(|e| e.to_string())
}

fn update_settings_at(env: &Env, mut settings: AppSettings) -> Result<AppSettings, String> {
    for root in settings.harness_roots.values_mut() {
        *root = crate::paths::expand_tilde(&env.home, &root.to_string_lossy());
    }
    settings.zoom = settings::clamp_zoom(settings.zoom);
    settings::save(env, &settings).map_err(|e| e.to_string())?;
    Ok(settings)
}

#[tauri::command(async)]
#[specta::specta]
pub fn update_settings(settings: AppSettings) -> Result<AppSettings, String> {
    update_settings_at(&env()?, settings)
}

fn register_project_at(env: &Env, path: &str) -> Result<AppSettings, String> {
    let expanded = crate::paths::expand_tilde(&env.home, path);
    settings::register_project(env, &expanded).map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn register_project(path: String) -> Result<AppSettings, String> {
    register_project_at(&env()?, &path)
}

#[tauri::command(async)]
#[specta::specta]
pub fn unregister_project(path: String) -> Result<AppSettings, String> {
    settings::unregister_project(&env()?, path.as_ref()).map_err(|e| e.to_string())
}

/// Install the session-start drift report hook for a scope: script into the
/// scope's local source, declaration into its manifest, then the ordinary
/// apply renders it. The offer surface (project registration) calls this
/// after the user says yes — the declared, user-approved install per scope.
/// Returns whether the hook was fully rendered. The user approved the hook
/// and nothing else, so the rendering apply runs only when the scope had no
/// other pending work; otherwise the declaration lands and `false` says the
/// Review page's ordinary preview-and-apply finishes the job.
#[tauri::command(async)]
#[specta::specta]
pub fn install_drift_hook(scope: kendex_core::model::Scope) -> Result<bool, String> {
    let env = env()?;
    let options = kendex_core::engine::PlanOptions::default();
    let pending = kendex_core::engine::plan_apply(&env, &scope, &options)
        .map_err(|e| e.to_string())?
        .plan;
    let plan = kendex_core::drift::hook::install_plan(&env, &scope).map_err(|e| e.to_string())?;
    kendex_core::apply::execute(&env, &plan, None).map_err(|e| e.to_string())?;
    if !pending.is_empty() {
        return Ok(false);
    }
    let report =
        kendex_core::engine::plan_apply(&env, &scope, &options).map_err(|e| e.to_string())?;
    kendex_core::apply::execute(&env, &report.plan, None).map_err(|e| e.to_string())?;
    Ok(true)
}

fn discover_projects_at(env: &Env, root: &str) -> Result<Vec<String>, String> {
    let expanded = crate::paths::expand_tilde(&env.home, root);
    Ok(discover::discover_projects(&expanded)
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|p| p.display().to_string())
        .collect())
}

#[tauri::command(async)]
#[specta::specta]
pub fn discover_projects(root: String) -> Result<Vec<String>, String> {
    discover_projects_at(&env()?, &root)
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
#[tauri::command]
#[specta::specta]
pub fn capability_table() -> Vec<CapabilityRow> {
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
    rows
}

#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ReportRouteView {
    pub kendex_owned: bool,
    pub repo: Option<String>,
    pub label: Option<String>,
    /// Prefilled new-issue page — only when the report belongs upstream.
    pub issue_url: Option<String>,
}

fn urlencode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                char::from(b).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
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
    let env = env()?;
    // Read-only lookup: a v1 lock degrades to "no provenance" like the rest
    // of the read surface, instead of blocking the report dialog outright.
    let lock = match kendex_core::lock::load_file(&kendex_core::lock::lock_path(&env, &scope))
        .map_err(|e| e.to_string())?
    {
        kendex_core::lock::LockFile::Current(lock) => lock,
        kendex_core::lock::LockFile::Absent | kendex_core::lock::LockFile::Legacy { .. } => {
            kendex_core::lock::Lock::default()
        }
    };
    let route = kendex_core::report::route(
        &env,
        &scope,
        &lock,
        &name,
        kind,
        kendex_core::report::DEFAULT_UPSTREAM,
    );
    let issue_url = route.repo.as_ref().map(|repo| {
        let mut url = format!(
            "https://github.com/{repo}/issues/new?title={}",
            urlencode(&format!("{name}: "))
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
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::env::FakeOs;

    fn env_in(dir: &std::path::Path) -> Env {
        Env::fake(dir, FakeOs::Linux)
    }

    #[test]
    fn register_project_expands_a_typed_tilde_path() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        std::fs::create_dir_all(tmp.path().join("dev/hyprtrade")).unwrap();

        let settings = register_project_at(&env, "~/dev/hyprtrade").unwrap();
        assert_eq!(
            settings.projects,
            [tmp.path().join("dev/hyprtrade").canonicalize().unwrap()]
        );
    }

    #[test]
    fn discover_projects_expands_a_typed_tilde_root() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        std::fs::create_dir_all(tmp.path().join("dev/app/.claude")).unwrap();

        let found = discover_projects_at(&env, "~/dev").unwrap();
        assert_eq!(
            found,
            [tmp.path()
                .join("dev/app")
                .canonicalize()
                .unwrap()
                .display()
                .to_string()]
        );
    }

    #[test]
    fn harness_root_overrides_expand_a_typed_tilde() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let mut settings = AppSettings::default();
        settings
            .harness_roots
            .insert("claude".into(), "~/elsewhere/.claude".into());

        let saved = update_settings_at(&env, settings).unwrap();
        assert_eq!(
            saved.harness_roots.get("claude"),
            Some(&tmp.path().join("elsewhere/.claude"))
        );
    }
}
