//! `marketplace browse`: the listing across subscriptions, human lines
//! or the versioned JSON rows.

use kendex_core::env::Env;
use kendex_core::source_ops;

use super::{CliResult, out, resolve_scopes};
use crate::scope::ScopeFilter;

type BrowseRow = (
    kendex_core::model::Scope,
    String,
    kendex_core::source::browse::AvailablePackage,
);

pub fn run_browse(
    env: &Env,
    marketplace: Option<String>,
    json: bool,
    global: bool,
    scope: Option<String>,
    community: bool,
) -> CliResult {
    if community {
        return Err(
            "the community directory is not available yet — it arrives with the kendex.ai platform; browse a subscription by name for now"
                .into(),
        );
    }
    let filter = ScopeFilter::resolve(scope.as_deref(), global, ScopeFilter::All)?;
    let mut rows: Vec<BrowseRow> = Vec::new();
    for scope in resolve_scopes(env, filter)? {
        let names: Vec<String> = match &marketplace {
            Some(name) => vec![name.clone()],
            None => source_ops::list_subscriptions(env, &scope)?
                .into_iter()
                .map(|row| row.name)
                .collect(),
        };
        for name in names {
            // A subscription that will not open costs its own rows, not the
            // whole listing — the same tolerance the app's overview shows.
            let catalog = kendex_core::source::browse::Catalog::Subscription {
                scope: scope.clone(),
                source: name.clone(),
            };
            let Ok(packages) = kendex_core::source::browse::packages(env, &catalog) else {
                continue;
            };
            for package in packages {
                rows.push((scope.clone(), name.clone(), package));
            }
        }
    }
    if json {
        let items: Vec<_> = rows
            .iter()
            .map(|(scope, marketplace, package)| {
                serde_json::json!({
                    "scope": scope.label(),
                    "marketplace": marketplace,
                    "package": package,
                })
            })
            .collect();
        out(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": 1,
            "packages": items,
        }))?);
        return Ok(());
    }
    for (scope, marketplace, package) in rows {
        let description = package
            .description
            .map(|d| format!("  — {d}"))
            .unwrap_or_default();
        out(&format!(
            "{}  {marketplace}::{}  ({}) [{}]{description}",
            scope.label(),
            package.name,
            package.kind.name(),
            install_state(&package.state),
        ));
    }
    Ok(())
}

fn install_state(state: &kendex_core::source::browse::InstallState) -> &'static str {
    use kendex_core::source::browse::InstallState;
    match state {
        InstallState::Installed => "installed",
        InstallState::Available => "available",
        InstallState::HeldBackBySafety => "held back by safety",
        InstallState::NotOffered => "no longer offered",
        InstallState::RemovedByYou => "removed by you",
    }
}
