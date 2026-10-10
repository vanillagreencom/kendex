//! Disabled catalog hooks keep the same registration record after apply.
//! Control: the unfixed planner drops removal edits for an absent registry;
//! both declared-companion rows then fail strict verification after apply.
#![cfg(unix)]

use std::fs;

use super::verify_records::{kendex, said, write};
use crate::test_util::{rooted, source_path};

#[test]
#[allow(clippy::unwrap_used)]
fn a_disabled_hook_and_its_companions_verify_after_apply() {
    // Catalog hook authors produce these edges. The consumer declares the
    // enabled companion either directly or at the end of a derived chain.
    let cases = [
        ("declared judge", "", "[hooks.judge]\nsource = \"cat\"\n"),
        (
            "derived judge with declared inner",
            "# requires: [inner]\n",
            "[hooks.inner]\nsource = \"cat\"\nenabled = true\n",
        ),
        ("derived judge and inner", "# requires: [inner]\n", ""),
    ];
    let mut failures = Vec::new();
    for (name, judge_requires, declarations) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let catalog = home.join("catalog");
        let project = home.join("consumer");
        write(&catalog.join("kendex.toml"), "is_source_catalog = true\n");
        for (hook, requires) in [
            ("guard", "# requires: [judge]\n"),
            ("judge", judge_requires),
            ("inner", ""),
        ] {
            write(
                &catalog.join(format!("hooks/{hook}.sh")),
                &format!(
                    "#!/usr/bin/env bash\n# ---\n# name: {hook}\n# event: PreToolUse\n# matcher: Bash\n# description: checks\n{requires}# ---\nexit 0\n"
                ),
            );
        }
        write(
            &project.join("kendex.toml"),
            &format!(
                "schema = 7\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[hooks.guard]\nsource = \"cat\"\nenabled = false\n{declarations}",
                source_path(&catalog),
            ),
        );
        fs::create_dir_all(project.join(".claude")).unwrap();
        let applied = kendex(&home, &project, &["apply", "-y", "--leave"]);
        assert!(applied.status.success(), "{name}: {}", said(&applied));
        assert!(
            project.join(".claude/hooks/guard.sh.disabled").is_file(),
            "{name}"
        );
        assert!(!project.join(".claude/hooks/guard.sh").exists(), "{name}");
        assert_eq!(
            project.join(".claude/settings.json").exists(),
            !declarations.is_empty(),
            "{name}: only an enabled declared companion creates the registry"
        );
        let verified = kendex(
            &home,
            &project,
            &["verify", "--scope", "project", "--strict", "--json"],
        );
        if !verified.status.success() {
            failures.push(format!("{name}: {}", said(&verified)));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
