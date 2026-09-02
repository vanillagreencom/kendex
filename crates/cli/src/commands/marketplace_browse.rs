//! `marketplace browse`: the listing across subscriptions, human lines
//! or the versioned JSON rows.
//!
//! `--json` stays at `"schema": 1`. A lock this build refuses widened
//! `package.state` by one value, `"unknown"` — every key a schema-1
//! consumer reads is still there and still means what it did, so the change
//! is additive rather than a bump. Two things did change for a script: a
//! scope whose lock will not read now contributes rows instead of none, and
//! the command exits 0 where that scope used to fail it. What a marketplace
//! offers is a fact about the source, and the lock has no say in it; a
//! consumer that matches `state` exhaustively needs an arm for `"unknown"`,
//! which means the installed state alone could not be settled.

use kendex_core::env::Env;
use kendex_core::source_ops;

use super::{CliResult, answer, out, resolve_scopes};
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
) -> CliResult {
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
        answer(&serde_json::to_string_pretty(&serde_json::json!({
            "schema": 1,
            "packages": items,
        }))?);
        return Ok(());
    }
    for (scope, marketplace, package) in rows {
        let summary = package
            .summary
            .map(|text| format!("  — {text}"))
            .unwrap_or_default();
        out(&format!(
            "{}  {marketplace}::{}  ({}) [{}]{summary}",
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
        InstallState::NotOffered => "no longer offered",
        InstallState::RemovedByYou => "removed by you",
        InstallState::Unknown => "unknown (this project's lock can't be read)",
    }
}
