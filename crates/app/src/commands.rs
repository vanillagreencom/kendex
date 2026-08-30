use kendex_core::env::Env;
use kendex_core::harness::{KindCaps, capabilities};
use kendex_core::model::{HarnessId, ItemKind};
use kendex_core::scan;
use kendex_core::scan::ScanResult;
use kendex_core::settings;
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
    kendex_core::apply::execute(&env, &report.plan).map_err(|e| e.to_string())?;
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
    let route =
        kendex_core::report::route(&lock, &name, kind, kendex_core::report::DEFAULT_UPSTREAM);
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
