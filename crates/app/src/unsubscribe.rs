//! Unsubscribe commands: the dialog's preview partition and the action that
//! removes a marketplace or keeps its packages as local forks.

use kendex_core::apply;
use kendex_core::engine::ops as engine_ops;
use kendex_core::env::Env;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::source_ops;
use serde::Serialize;
use specta::Type;

use crate::scopes::env;

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

/// What unsubscribing did about the repository effects of the packages
/// that left with the source — the same account the terminal prints.
///
/// A struct rather than the bare list it used to be, spelling the account
/// `undone` like every other command that can make one. The window reads
/// the account off an answer by that name, so a bare list is a shape it
/// can only be told about by hand, and the day this write goes through
/// the shared one it would fall silent with nothing going red.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Unsubscribed {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
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
) -> Result<Unsubscribed, String> {
    unsubscribe(&env()?, &scope, &source, keep, discard_edits)
}

/// The unsubscribe itself, against the environment it is given.
pub fn unsubscribe(
    env: &Env,
    scope: &Scope,
    source: &str,
    keep: bool,
    discard_edits: bool,
) -> Result<Unsubscribed, String> {
    use kendex_core::engine::detach;
    let manifest = engine_ops::manifest_for_mutation(env, scope).map_err(|e| e.to_string())?;
    let closure = detach::closure(env, scope, source, &manifest).map_err(|e| e.to_string())?;

    let mut undone = if closure.items.is_empty() {
        let report = source_ops::remove_source(env, scope, source).map_err(|e| e.to_string())?;
        crate::repo_effects::write(env, &report)?
    } else if keep {
        // A conversion, not a removal: every package stays, under `local`
        // instead of the source that is going. A bare plan with no report
        // behind it drops nothing, and the resync below is what carries a
        // report.
        let plan = detach::source(env, scope, source).map_err(|e| e.to_string())?;
        apply::execute(env, &plan).map_err(|e| e.to_string())?;
        Vec::new()
    } else {
        let report =
            detach::remove(env, scope, source, discard_edits).map_err(|e| e.to_string())?;
        crate::repo_effects::write(env, &report)?
    };
    if keep {
        // Keeping moved the catalog's mapping tables into the manifest, so
        // the install records are re-synced here — otherwise every kept
        // agent would read as drifted until the next refresh.
        let resync = kendex_core::engine::plan_apply(
            env,
            scope,
            &kendex_core::engine::PlanOptions::default(),
        )
        .map_err(|e| e.to_string())?;
        undone.extend(crate::repo_effects::write(env, &resync)?);
    }
    Ok(Unsubscribed { undone })
}
