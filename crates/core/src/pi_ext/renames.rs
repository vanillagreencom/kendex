//! Package renames shipped by kendex's catalog, and the cross-scope guard
//! built on them. Pi loads the global and project scopes together and
//! de-duplicates packages by identity, not by the resources they register —
//! the same package under two names or at two scopes registers twice and
//! crashes Pi at startup.

use std::path::{Path, PathBuf};

/// The 1.0.0 release moved every package under the `@vanillagreen/` npm
/// scope; installs and locks predating the move still use the old names.
const RENAMES: &[(&str, &[&str])] = &[
    (
        "@vanillagreen/pi-agents-tmux",
        &["pi-agents-tmux", "pi-subagents-tmux", "pi-subagents"],
    ),
    (
        "@vanillagreen/pi-background-tasks",
        &["pi-background-tasks"],
    ),
    ("@vanillagreen/pi-caveman", &["pi-caveman"]),
    ("@vanillagreen/pi-claude-bridge", &["pi-claude-bridge"]),
    (
        "@vanillagreen/pi-codex-minimal-tools",
        &["pi-codex-minimal-tools"],
    ),
    (
        "@vanillagreen/pi-extension-manager",
        &["pi-extension-manager"],
    ),
    ("@vanillagreen/pi-hooks", &["pi-hooks"]),
    ("@vanillagreen/pi-output-policy", &["pi-output-policy"]),
    (
        "@vanillagreen/pi-prompt-stash",
        &["pi-prompt-stash", "prompt-stash"],
    ),
    ("@vanillagreen/pi-qol", &["pi-qol"]),
    ("@vanillagreen/pi-questions", &["pi-questions"]),
    ("@vanillagreen/pi-session-bridge", &["pi-session-bridge"]),
    ("@vanillagreen/pi-session-manager", &["pi-session-manager"]),
    ("@vanillagreen/pi-skills-manager", &["pi-skills-manager"]),
    ("@vanillagreen/pi-task-panel", &["pi-task-panel"]),
    ("@vanillagreen/pi-tool-renderer", &["pi-tool-renderer"]),
    ("@vanillagreen/pi-web-tools", &["pi-web-tools"]),
];

/// Earlier names this package shipped under.
pub fn legacy_names(name: &str) -> &'static [&'static str] {
    RENAMES
        .iter()
        .find_map(|(current, legacy)| (*current == name).then_some(*legacy))
        .unwrap_or(&[])
}

/// The name (or legacy name) already installed at another scope that makes
/// installing `name` here unsafe, with the scope root carrying it.
pub fn duplicate_elsewhere(name: &str, other_roots: &[PathBuf]) -> Option<(String, PathBuf)> {
    let mut candidates = vec![name];
    candidates.extend(legacy_names(name));
    for root in other_roots {
        for candidate in &candidates {
            if installed_at(root, candidate) {
                return Some(((*candidate).to_owned(), root.clone()));
            }
        }
    }
    None
}

fn installed_at(scope_root: &Path, name: &str) -> bool {
    let Ok(path) = super::files::package_path(scope_root, name) else {
        return false;
    };
    if path.symlink_metadata().is_ok() {
        return true;
    }
    super::registered(scope_root, name).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_names_cover_the_scope_move_and_deeper_renames() {
        assert_eq!(legacy_names("@vanillagreen/pi-hooks"), ["pi-hooks"]);
        assert_eq!(
            legacy_names("@vanillagreen/pi-agents-tmux"),
            ["pi-agents-tmux", "pi-subagents-tmux", "pi-subagents"]
        );
        assert!(legacy_names("pi-widgets").is_empty());
    }

    #[test]
    #[allow(clippy::unwrap_used)]
    fn duplicates_are_found_by_dir_or_settings_under_any_name() {
        let tmp = tempfile::tempdir().unwrap();
        let other = tmp.path().to_path_buf();

        assert_eq!(
            duplicate_elsewhere("pi-widgets", std::slice::from_ref(&other)),
            None
        );

        // A package directory alone counts.
        std::fs::create_dir_all(other.join("packages/pi-hooks")).unwrap();
        let hit =
            duplicate_elsewhere("@vanillagreen/pi-hooks", std::slice::from_ref(&other)).unwrap();
        assert_eq!(hit.0, "pi-hooks");

        // A settings registration alone counts too.
        let tmp2 = tempfile::tempdir().unwrap();
        let other2 = tmp2.path().to_path_buf();
        std::fs::write(
            other2.join("settings.json"),
            r#"{"packages": ["./packages/pi-widgets"]}"#,
        )
        .unwrap();
        let hit = duplicate_elsewhere("pi-widgets", &[other2]).unwrap();
        assert_eq!(hit.0, "pi-widgets");
    }
}
