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

/// Earlier names this package shipped under, keyed on the current name.
/// Private: a caller holding an arbitrary spelling wants [`family`],
/// which folds the spelling to its current name first.
fn legacy_names(name: &str) -> &'static [&'static str] {
    RENAMES
        .iter()
        .find_map(|(current, legacy)| (*current == name).then_some(*legacy))
        .unwrap_or(&[])
}

/// The current name of the package a spelling belongs to: the `RENAMES`
/// key whose earlier names carry it, else the spelling itself. Every
/// question about package identity folds both sides through this, because
/// two earlier names of one package carry no membership of each other and
/// a pairwise test reads them as different packages.
fn canonical(name: &str) -> &str {
    RENAMES
        .iter()
        .find_map(|(current, legacy)| legacy.contains(&name).then_some(*current))
        .unwrap_or(name)
}

/// Every name the package a spelling belongs to may be installed or
/// declared under: its current name first, then each earlier one. The
/// one owner of package identity as a set — a caller that builds its own
/// candidates off a raw spelling gets a one-element set for a package
/// declared under an earlier name and misses every copy carrying another.
pub fn family(name: &str) -> Vec<&str> {
    let current = canonical(name);
    let mut names = vec![current];
    names.extend(legacy_names(current));
    names
}

/// Whether two spellings name one package. Pi de-duplicates by package
/// identity, so two declarations that fold to one current name are one
/// registration to it whichever names they were written under.
pub fn same_package(one: &str, other: &str) -> bool {
    canonical(one) == canonical(other)
}

/// Whether this exact spelling is installed at `scope_root`, as a package
/// directory or a settings registration. The one-spelling question: a
/// caller asking whether the same PACKAGE sits at another scope wants
/// [`duplicate_elsewhere`], and one asking which spellings to try wants
/// [`family`]; both fold renames.
pub fn installed_under(scope_root: &Path, name: &str) -> bool {
    installed_at(scope_root, name)
}

/// The name (or legacy name) already installed at another scope that makes
/// installing `name` here unsafe, with the scope root carrying it. The
/// candidate set is the whole rename [`family`], so a copy installed
/// under an earlier name is found when the declaration uses the current
/// one and equally the other way round.
pub fn duplicate_elsewhere(name: &str, other_roots: &[PathBuf]) -> Option<(String, PathBuf)> {
    let candidates = family(name);
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

    /// The family is the same set whichever member names it, so a caller
    /// holding an earlier spelling gets the current name too.
    #[test]
    fn the_family_of_any_spelling_is_the_whole_package() {
        let rows = [
            (
                "@vanillagreen/pi-agents-tmux",
                vec![
                    "@vanillagreen/pi-agents-tmux",
                    "pi-agents-tmux",
                    "pi-subagents-tmux",
                    "pi-subagents",
                ],
            ),
            (
                "pi-subagents",
                vec![
                    "@vanillagreen/pi-agents-tmux",
                    "pi-agents-tmux",
                    "pi-subagents-tmux",
                    "pi-subagents",
                ],
            ),
            ("pi-hooks", vec!["@vanillagreen/pi-hooks", "pi-hooks"]),
            ("pi-widgets", vec!["pi-widgets"]),
        ];
        for (spelling, expected) in rows {
            assert_eq!(family(spelling), expected, "{spelling}");
        }
    }

    #[test]
    fn one_package_is_recognized_across_its_renames_in_either_direction() {
        let rows = [
            ("@vanillagreen/pi-hooks", "@vanillagreen/pi-hooks", true),
            ("@vanillagreen/pi-hooks", "pi-hooks", true),
            ("pi-hooks", "@vanillagreen/pi-hooks", true),
            ("pi-subagents", "@vanillagreen/pi-agents-tmux", true),
            ("pi-subagents", "pi-agents-tmux", true),
            ("pi-prompt-stash", "prompt-stash", true),
            ("@vanillagreen/pi-hooks", "@vanillagreen/pi-qol", false),
            ("pi-hooks", "pi-qol", false),
            ("pi-subagents", "prompt-stash", false),
        ];
        for (one, other, expected) in rows {
            assert_eq!(same_package(one, other), expected, "{one} vs {other}");
        }
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

    /// The rename family is reached through the current name, so the
    /// declaration's spelling and the installed copy's may be any two
    /// members of it. Asked under an earlier name against a copy installed
    /// under the current one, the direction a raw-spelling lookup misses.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn an_earlier_name_finds_a_current_name_copy_at_another_root() {
        let tmp = tempfile::tempdir().unwrap();
        let other = tmp.path().to_path_buf();
        std::fs::create_dir_all(other.join("packages/@vanillagreen/pi-hooks")).unwrap();

        let hit = duplicate_elsewhere("pi-hooks", std::slice::from_ref(&other)).unwrap();
        assert_eq!(hit.0, "@vanillagreen/pi-hooks");
    }

    /// One spelling, asked exactly: the probe `settleable` uses for a
    /// rename left-over at a scope's own root must not fold the family,
    /// or every correctly installed package answers it.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn installed_under_answers_for_the_spelling_it_was_given_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        std::fs::create_dir_all(root.join("packages/@vanillagreen/pi-hooks")).unwrap();

        assert!(installed_under(root, "@vanillagreen/pi-hooks"));
        assert!(!installed_under(root, "pi-hooks"));
    }
}
