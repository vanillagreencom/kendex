//! Unsubscribe commands: the dialog's preview partition and the action that
//! removes a marketplace or keeps its packages as local forks.

use kendex_core::apply;
use kendex_core::engine::ops as engine_ops;
use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source_ops;
use serde::Serialize;
use specta::Type;

fn env() -> Result<Env, String> {
    Env::detect().map_err(|e| e.to_string())
}

/// One package named in an unsubscribe preview.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PackageRef {
    pub kind: ItemKind,
    pub name: String,
}

/// What unsubscribing from a marketplace would do: the packages that can be
/// removed or kept as-is, the ones the user edited (which must be forked or
/// discarded first), and the curated sets that leave with the source.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct UnsubscribePreview {
    pub removable: Vec<PackageRef>,
    pub edited: Vec<PackageRef>,
    pub bundles: Vec<String>,
}

/// The dialog's preview: the closure partitioned into removable, edited, and
/// the bundles that go. Refuses (as an error) while the source cannot be read.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_unsubscribe_preview(
    scope: Scope,
    source: String,
) -> Result<UnsubscribePreview, String> {
    let env = env()?;
    let preview =
        kendex_core::engine::detach::preview(&env, &scope, &source).map_err(|e| e.to_string())?;
    let map = |rows: Vec<(ItemKind, String)>| {
        rows.into_iter()
            .map(|(kind, name)| PackageRef { kind, name })
            .collect()
    };
    Ok(UnsubscribePreview {
        removable: map(preview.removable),
        edited: map(preview.edited),
        bundles: preview.bundles,
    })
}

/// Unsubscribe, removing or keeping the packages. `keep` converts each
/// installation to a local fork; otherwise they are uninstalled, and
/// `discard_edits` takes hand edits along instead of refusing.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_unsubscribe(
    scope: Scope,
    source: String,
    keep: bool,
    discard_edits: bool,
) -> Result<(), String> {
    use kendex_core::engine::detach;
    let env = env()?;
    let manifest = engine_ops::manifest_for_mutation(&env, &scope).map_err(|e| e.to_string())?;
    let closure = detach::closure(&env, &scope, &source, &manifest).map_err(|e| e.to_string())?;

    let plan = if closure.items.is_empty() {
        source_ops::remove_source(&env, &scope, &source)
            .map_err(|e| e.to_string())?
            .plan
    } else if keep {
        detach::source(&env, &scope, &source).map_err(|e| e.to_string())?
    } else {
        detach::remove(&env, &scope, &source, discard_edits)
            .map_err(|e| e.to_string())?
            .plan
    };
    apply::execute(&env, &plan).map_err(|e| e.to_string())?;
    if keep {
        // Keeping moved the catalog's mapping tables into the manifest, so
        // the install records are re-synced here — otherwise every kept
        // agent would read as drifted until the next refresh.
        let resync = kendex_core::engine::plan_apply(
            &env,
            &scope,
            &kendex_core::engine::PlanOptions::default(),
        )
        .map_err(|e| e.to_string())?;
        apply::execute(&env, &resync.plan).map_err(|e| e.to_string())?;
    }
    Ok(())
}
