//! `kendex remove` on a name with nothing installed under it: a declaration
//! refresh never installed is dropped from kendex.toml, and a name nothing
//! declares leaves every file as it was, a scope with no kendex.toml of its
//! own included.
#![cfg(unix)]

use super::deps_cli::{kendex, project, tree};
use crate::test_util::rooted;
use std::fs;

#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_drops_a_declaration_with_nothing_installed_and_writes_nothing_for_an_unknown_name() {
    // (name removed, declared by hand before the removal)
    let rows = [("linear", true), ("nothing-declares-this", false)];
    for (name, declared) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = project(&tmp);
        let before = tree(&home);
        if declared {
            let manifest = project.join("kendex.toml");
            let mut text = fs::read_to_string(&manifest).unwrap();
            text.push_str(&format!(
                "\n[skills.{name}]\nsource = \"catalog\"\nharnesses = [\"claude\"]\n"
            ));
            fs::write(&manifest, text).unwrap();
        }

        let removed = kendex(&home, &project, &["remove", name, "--scope", "all"]);
        let said = String::from_utf8_lossy(&removed.stderr);

        assert!(removed.status.success(), "{name}: {said}");
        let after = tree(&home);
        let changed: Vec<&String> = before
            .iter()
            .chain(&after)
            .filter(|entry| !(before.contains(entry) && after.contains(entry)))
            .map(|(path, _)| path)
            .collect();
        assert!(changed.is_empty(), "{name}: wrote {changed:?}: {said}");
    }
}
