//! Unsubscribe commands: the dialog's preview partition and the action that
//! removes a marketplace or keeps its packages as local forks.

use kendex_core::apply;
use kendex_core::engine::ItemWarning;
use kendex_core::env::Env;
use kendex_core::library::PackageRef;
use kendex_core::model::{ItemKind, Scope};
use serde::Serialize;
use specta::Type;

use crate::packages::LandingStopped;
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
    /// What keeping the packages and rendering them again warned about,
    /// each with its fix: a link the kept copy holds as written, say.
    pub warnings: Vec<ItemWarning>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
}

/// Unsubscribe, removing or keeping the packages that would leave. `keep`
/// converts them to local forks; otherwise they are uninstalled, and
/// `discard_edits` takes their hand edits along instead of refusing. A
/// refusal leaves the scope as it was; a keep that landed before the render
/// after it failed has kept the packages, and what keeping them reported
/// comes with the cause.
#[tauri::command(async)]
#[specta::specta]
pub fn marketplace_unsubscribe(
    scope: Scope,
    source: String,
    keep: bool,
    discard_edits: bool,
) -> Result<Unsubscribed, LandingStopped> {
    let env = env().map_err(|message| LandingStopped::Refused { message })?;
    unsubscribe(&env, &scope, &source, keep, discard_edits)
}

/// The unsubscribe itself, against the environment it is given.
pub fn unsubscribe(
    env: &Env,
    scope: &Scope,
    source: &str,
    keep: bool,
    discard_edits: bool,
) -> Result<Unsubscribed, LandingStopped> {
    use kendex_core::engine::detach;
    let refused = |message: String| LandingStopped::Refused { message };
    if !keep {
        // A plan that fails to apply rolls back: nothing left, a refusal.
        let report = detach::remove(env, scope, source, discard_edits)
            .map_err(|e| refused(e.to_string()))?;
        let undone = crate::repo_effects::write(env, &report).map_err(refused)?;
        return Ok(Unsubscribed {
            warnings: Vec::new(),
            undone,
        });
    }
    // The conversion has no report of its own beyond the links it kept.
    // The resync below supplies the report that repository effects need.
    let kept = detach::source(env, scope, source).map_err(|e| refused(e.to_string()))?;
    apply::execute(env, &kept).map_err(|e| refused(e.to_string()))?;
    // The packages are kept from here on, and what the keep reported is
    // read nowhere else: a failure after it carries the report with it.
    let mut warnings = kept.warnings;
    let resync = match detach::resync_kept(env, scope) {
        Ok(resync) => resync,
        Err(error) => {
            return Err(LandingStopped::Recorded {
                message: error.to_string(),
                written: warnings,
            });
        }
    };
    warnings.extend(resync.warnings.iter().cloned());
    match crate::repo_effects::write(env, &resync) {
        Ok(undone) => Ok(Unsubscribed { warnings, undone }),
        Err(message) => Err(LandingStopped::Recorded {
            message,
            written: warnings,
        }),
    }
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
                    "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n",
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

    /// Keeping a skill whose link leaves the project answers with that link
    /// as the keep reported it, its fix beside it, for the window to show:
    /// on a keep that finished, and on one whose render after it failed,
    /// where nothing else reads what the landed keep reported.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn unsubscribe_keep_answers_each_kept_link_with_its_fix() {
        // Whether a declared agent the render after the keep must write
        // lands in a folder that refuses the write.
        for render_fails in [false, true] {
            let tmp = tempfile::tempdir().unwrap();
            let home = crate::test_util::rooted(&tmp);
            let env = Env::host_rooted(&home);
            let root = home.join("dev/app");
            let catalog = home.join("catalog");
            skill(&catalog, "gh", "[m](../../memory/x.md)");
            std::fs::create_dir_all(catalog.join("memory")).unwrap();
            std::fs::write(catalog.join("memory/x.md"), "Memory.\n").unwrap();
            std::fs::create_dir_all(root.join(".claude")).unwrap();
            let manifest = format!(
                "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n[skills.gh]\nsource = \"cat\"\n",
                crate::test_util::source_path(&catalog)
            );
            std::fs::write(root.join("kendex.toml"), &manifest).unwrap();
            let scope = Scope::Project { root: root.clone() };
            let report = kendex_core::engine::audit(&env, &scope).unwrap();
            apply::execute(&env, &report.plan).unwrap();
            let unwritable = match render_fails {
                false => None,
                true => {
                    let local = root.join(kendex_core::source::LOCAL_SOURCE_DIR);
                    std::fs::create_dir_all(local.join("agents")).unwrap();
                    std::fs::write(
                        local.join("agents/extra.md"),
                        "---\nname: extra\ndescription: does extra\n---\nMine.\n",
                    )
                    .unwrap();
                    std::fs::write(
                        root.join("kendex.toml"),
                        format!("{manifest}[agents.extra]\nsource = \"local\"\n"),
                    )
                    .unwrap();
                    let agents = root.join(".claude/agents");
                    std::fs::create_dir_all(&agents).unwrap();
                    let Some(held) = crate::test_util::unwritable_dir(&agents) else {
                        return;
                    };
                    Some(held)
                }
            };
            let answer = unsubscribe(&env, &scope, "cat", true, false);
            drop(unwritable);
            let warnings = match (answer, render_fails) {
                (Ok(unsubscribed), false) => unsubscribed.warnings,
                (Err(LandingStopped::Recorded { written, .. }), true) => written,
                (Err(LandingStopped::Refused { message }), _) => {
                    panic!("render_fails={render_fails}: the keep was refused: {message}")
                }
                (Ok(_), true) => panic!("the render went through, so this row proves nothing"),
                (Err(LandingStopped::Recorded { message, .. }), false) => {
                    panic!("the render after the keep failed: {message}")
                }
            };
            let kept: Vec<&ItemWarning> = warnings
                .iter()
                .filter(|warning| warning.message.starts_with("skill-link-kept:"))
                .collect();
            assert_eq!(kept.len(), 1, "render_fails={render_fails}: {warnings:?}");
            assert_eq!(kept[0].name, "gh");
            assert!(kept[0].remediation.is_some(), "{:?}", kept[0]);
        }
    }
}
