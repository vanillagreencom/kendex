//! `kendex remove` on a name with nothing installed under it: a declaration
//! refresh never installed is dropped from kendex.toml, and a name nothing
//! declares leaves every file as it was, a scope with no kendex.toml of its
//! own included. The manifest save the planner makes of its own accord (an
//! agent setting under a retired name, renamed on any pass that reads it)
//! is no removal, and a removal that keeps declarations never writes
//! kendex.toml. A removal whose only change is to kendex.toml, a
//! suppression or an optional choice taken back, writes it, and the next
//! refresh leaves the item out.
#![cfg(unix)]

use super::deps_cli::{kendex, project, skill, tree};
use crate::test_util::rooted;
use std::fs;

/// A skill declared by hand, which no refresh has installed.
const LINEAR: &str = "\n[skills.linear]\nsource = \"catalog\"\nharnesses = [\"claude\"]\n";
/// A setting under the retired agent name `engineer`: every plan of the
/// scope renames it and plans a manifest save for it.
const LEGACY: &str = "\n[agent-additional-instructions]\nengineer = \"Prefer small commits.\"\n";
/// An optional-dependency entry that chooses nothing, which no removal
/// touches.
const NO_CHOICE: &str = "\n[optional-dependencies]\ndev = []\n";

/// Append `text` to the project's kendex.toml.
#[allow(clippy::unwrap_used)]
fn plant(project: &std::path::Path, text: &str) {
    let manifest = project.join("kendex.toml");
    let mut held = fs::read_to_string(&manifest).unwrap();
    held.push_str(text);
    fs::write(&manifest, held).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_drops_a_declaration_with_nothing_installed_and_writes_nothing_for_an_unknown_name() {
    // (name removed, flags, planted in kendex.toml, whether the removal
    // takes the planted text back out)
    let rows: [(&str, &[&str], &str, bool); 5] = [
        ("linear", &[], LINEAR, true),
        ("nothing-declares-this", &[], "", false),
        ("nothing-declares-this", &[], LEGACY, false),
        ("nothing-declares-this", &[], NO_CHOICE, false),
        (
            "nothing-declares-this",
            &["--keep-declaration"],
            LEGACY,
            false,
        ),
    ];
    for (name, flags, planted, dropped) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let unplanted = tree(&home);
        plant(&project, planted);
        let before = match dropped {
            true => unplanted,
            false => tree(&home),
        };

        let mut args = vec!["remove", name, "--scope", "all"];
        args.extend_from_slice(flags);
        let removed = kendex(&home, &project, &args);
        let said = String::from_utf8_lossy(&removed.stderr);

        assert!(removed.status.success(), "{name} {flags:?}: {said}");
        let after = tree(&home);
        let changed: Vec<&String> = before
            .iter()
            .chain(&after)
            .filter(|entry| !(before.contains(entry) && after.contains(entry)))
            .map(|(path, _)| path)
            .collect();
        assert!(
            changed.is_empty(),
            "{name} {flags:?}: wrote {changed:?}: {said}"
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_that_keeps_declarations_leaves_kendex_toml_byte_identical() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = project(&tmp);
    plant(&project, LEGACY);
    let before = fs::read(project.join("kendex.toml")).unwrap();

    let removed = kendex(
        &home,
        &project,
        &["remove", "dev", "--keep-declaration", "--scope", "project"],
    );
    let said = String::from_utf8_lossy(&removed.stderr);

    assert!(removed.status.success(), "{said}");
    assert!(
        !project.join(".claude/skills/dev").exists(),
        "the files stayed: {said}"
    );
    assert_eq!(
        fs::read(project.join("kendex.toml")).unwrap(),
        before,
        "{said}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_that_only_rewrites_kendex_toml_stays_removed_across_a_refresh() {
    // (planted in kendex.toml, what the person ran before the refresh,
    // the item that stays out)
    let rows: [(&str, &[&[&str]], &str); 2] = [
        // github is installed only as dev's dependency: taken off disk
        // with the declaration kept, then removed for good, which only
        // writes the suppression.
        (
            "",
            &[
                &[
                    "remove",
                    "github",
                    "--keep-declaration",
                    "--scope",
                    "project",
                ],
                &["remove", "github", "--scope", "project"],
            ],
            "github",
        ),
        // linear chosen as dev's optional extra by hand, never installed.
        (
            "\n[optional-dependencies]\ndev = [\"linear\"]\n",
            &[&["remove", "linear", "--scope", "project"]],
            "linear",
        ),
    ];
    for (planted, runs, gone) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        skill(
            &home,
            "dev",
            "dependencies:\n  required: [github]\n  optional: [linear]\n",
        );
        // dev's new body is installed before the run, so no removal
        // writes it.
        let settled = kendex(&home, &project, &["refresh", "-y"]);
        assert!(settled.status.success(), "{gone}");
        plant(&project, planted);

        for args in runs {
            let removed = kendex(&home, &project, args);
            let said = String::from_utf8_lossy(&removed.stderr);
            assert!(removed.status.success(), "{args:?}: {said}");
        }
        let refreshed = kendex(&home, &project, &["refresh", "-y"]);
        let said = String::from_utf8_lossy(&refreshed.stderr);

        assert!(refreshed.status.success(), "{gone}: {said}");
        assert!(
            project.join(".claude/skills/dev").exists(),
            "{gone}: {said}"
        );
        assert!(
            !project.join(".claude/skills").join(gone).exists(),
            "{gone} came back: {said}"
        );
    }
}
