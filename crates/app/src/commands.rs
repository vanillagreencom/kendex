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
    route_for(&env()?, &scope, &name, kind)
}

/// [`report_route`] against a given environment, which is what makes it
/// reachable from a test. The command above only finds the environment.
fn route_for(
    env: &Env,
    scope: &kendex_core::model::Scope,
    name: &str,
    kind: Option<ItemKind>,
) -> Result<ReportRouteView, String> {
    // Read-only: a lock this build cannot read answers as no provenance,
    // which routes to the upstream default, rather than failing the dialog.
    let lock = kendex_core::lock::observed(&kendex_core::lock::lock_path(env, scope))
        .map_err(|e| e.to_string())?;
    let route =
        kendex_core::report::route(&lock, name, kind, kendex_core::report::DEFAULT_UPSTREAM);
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
    use super::route_for;
    use kendex_core::env::{Env, FakeOs};
    use kendex_core::model::Scope;

    /// One installation recorded from the upstream, in the shape this
    /// build writes, at whichever version the caller names.
    #[allow(clippy::unwrap_used)]
    fn lock_at(project: &std::path::Path, version: u32) {
        std::fs::write(
            project.join(".kendex-lock.json"),
            format!(
                r#"{{"version":{version},"root":{},"entries":{{"skill:gh:claude":{{"name":"gh","kind":"skill","harness":"claude","source":"kendex","sourceRepo":"{}","method":"symlink","installedAt":"2026-01-01T00:00:00Z","sourceHash":"abc","enabled":true,"reasons":[{{"reason":"requested"}}]}}}}}}"#,
                serde_json::to_string(&project.display().to_string()).unwrap(),
                kendex_core::report::DEFAULT_UPSTREAM
            ),
        )
        .unwrap();
    }

    /// The report dialog is read-only. A lock this build cannot read costs
    /// the provenance the route reads, so the report falls back to the
    /// person's own repo the way an absent lock does — it does not fail the
    /// dialog and leave them with no way to file at all.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn a_lock_this_build_cannot_read_costs_provenance_not_the_dialog() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), FakeOs::Linux);
        let project = tmp.path().join("dev/app");
        std::fs::create_dir_all(&project).unwrap();
        let scope = Scope::Project {
            root: project.clone(),
        };

        lock_at(&project, kendex_core::lock::LOCK_VERSION);
        let route = route_for(&env, &scope, "gh", None).unwrap();
        assert!(
            route.kendex_owned && route.issue_url.is_some(),
            "the fixture must give the dialog provenance to lose"
        );

        // The record a released kendex left: this build's shape, one
        // version back, so nothing but the number is wrong with it.
        lock_at(&project, kendex_core::lock::LOCK_VERSION - 1);
        let refused =
            kendex_core::lock::load_file(&kendex_core::lock::lock_path(&env, &scope)).unwrap_err();
        assert!(refused.is_unreadable_record(), "{refused}");

        let route = route_for(&env, &scope, "gh", None).expect("the dialog must still answer");
        assert!(
            !route.kendex_owned,
            "with no provenance to read, the report stays with the person's own repo"
        );
    }
}
