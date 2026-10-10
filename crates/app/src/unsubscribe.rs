//! Unsubscribe commands: the dialog's preview partition and the action that
//! removes a marketplace or keeps its packages as local forks.

use kendex_core::apply;
use kendex_core::env::Env;
use kendex_core::library::PackageRef;
use kendex_core::model::{ItemKind, Scope};
use serde::Serialize;
use specta::Type;

use crate::scopes::env;

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
/// The UI reads `undone` by name, so this response must remain an object rather
/// than a bare list.
#[derive(Debug, Clone, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Unsubscribed {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
}

/// Unsubscribe, removing or keeping the packages that would leave. `keep`
/// converts them to local forks; otherwise they are uninstalled, and
/// `discard_edits` takes their hand edits along instead of refusing.
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
    let mut undone = if keep {
        // The conversion has no report. The resync below supplies the report
        // that repository effects need.
        let plan = detach::source(env, scope, source).map_err(|e| e.to_string())?;
        apply::execute(env, &plan).map_err(|e| e.to_string())?;
        Vec::new()
    } else {
        let report =
            detach::remove(env, scope, source, discard_edits).map_err(|e| e.to_string())?;
        crate::repo_effects::write(env, &report)?
    };
    if keep {
        let resync = detach::resync_kept(env, scope).map_err(|e| e.to_string())?;
        undone.extend(crate::repo_effects::write(env, &resync)?);
    }
    Ok(Unsubscribed { undone })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::test_util::unsubscribe::{Gained, assert_kept_source, installed_then_gained, skill};

    /// Both desktop decisions transfer a member when the surviving catalog
    /// gained every leaving member through a rewritten commit.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn unsubscribe_transfers_every_surviving_member() {
        for keep in [false, true] {
            let (_tmp, env, scope) = installed_then_gained(Gained::RewrittenHistory);
            let manifest = kendex_core::engine::ops::manifest_for_mutation(&env, &scope).unwrap();
            assert!(
                kendex_core::engine::detach::closure(&env, &scope, "cat", &manifest)
                    .unwrap()
                    .items
                    .is_empty()
            );
            unsubscribe(&env, &scope, "cat", keep, false).unwrap();
            let lock =
                kendex_core::lock::load(&kendex_core::lock::lock_path(&env, &scope)).unwrap();
            assert_kept_source(&env, &scope, &lock, &format!("app keep={keep}"));
        }
    }

    /// Keeping an empty subscription creates no local packages. Removing it
    /// also drops only the subscription.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn unsubscribe_drops_an_empty_subscription() {
        for keep in [false, true] {
            let tmp = tempfile::tempdir().unwrap();
            let home = crate::test_util::rooted(&tmp);
            let env = Env::host_rooted(&home);
            let root = home.join("dev/app");
            let catalog = home.join("catalog");
            skill(&catalog, "gh", "available");
            std::fs::create_dir_all(root.join(".claude")).unwrap();
            std::fs::write(
                root.join("kendex.toml"),
                format!(
                    "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n",
                    crate::test_util::source_path(&catalog)
                ),
            )
            .unwrap();
            let scope = Scope::Project { root };
            unsubscribe(&env, &scope, "cat", keep, false).unwrap();
            let manifest = kendex_core::engine::ops::manifest_for_mutation(&env, &scope).unwrap();
            assert!(!manifest.sources.contains_key("cat"));
            assert!(manifest.skills.is_empty());
        }
    }
}
