//! Rendering: budgets that count their own overflow lines, identifiers
//! validated at the command position, and foreign text scrubbed.

use super::tests::{
    env_in, manifest_with_remote, package, project_scope, snapshot_with, write_manifest,
};
use super::*;
use crate::drift::snapshot::PackageSnapshot;

#[test]
fn section_budget_counts_its_overflow_line_inside_itself() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    let packages: Vec<PackageSnapshot> = (0..14)
        .map(|i| PackageSnapshot {
            update_available: true,
            ..package(&format!("pkg-{i:02}"))
        })
        .collect();
    snapshot_with(&env, &scope, packages);

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    let section_lines: Vec<&str> = text
        .lines()
        .skip_while(|line| *line != "stale:")
        .skip(1)
        .take_while(|line| line.starts_with("  "))
        .collect();
    assert_eq!(section_lines.len(), SECTION_ITEMS, "{text}");
    assert_eq!(*section_lines.last().unwrap(), "  … and 5 more");
}

#[test]
fn report_budget_counts_its_truncation_line_and_never_cuts_a_line() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    // Every section overflowing plus long names pushes past both caps.
    let mut packages = Vec::new();
    for i in 0..14 {
        let long = format!("very-long-package-name-{i:02}-{}", "x".repeat(150));
        packages.push(PackageSnapshot {
            update_available: true,
            ..package(&long)
        });
        packages.push(PackageSnapshot {
            edited: true,
            ..package(&format!("edited-{long}"))
        });
        packages.push(PackageSnapshot {
            mixed: true,
            ..package(&format!("mixed-{long}"))
        });
    }
    snapshot_with(&env, &scope, packages);

    let text = render_plain(&check(&env, std::slice::from_ref(&scope)));
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines.len() <= REPORT_LINES, "{} lines", lines.len());
    assert!(text.len() <= REPORT_BYTES, "{} bytes", text.len());
    assert!(
        lines.last().unwrap().starts_with("… report truncated ("),
        "{text}"
    );
    // No line was cut mid-way: every remedy that rendered is complete.
    for line in &lines {
        if line.contains("fix: kendex fork") {
            assert!(
                line.trim_end()
                    .ends_with(|c: char| c == 'x' || c.is_ascii_digit()),
                "truncated command arguments in {line:?}"
            );
        }
    }
}

#[test]
fn an_unsafe_identifier_drops_the_remedy_not_the_line() {
    let remedy = Remedy::Remove {
        name: "evil; rm -rf /".into(),
        global: false,
    };
    assert_eq!(remedy.render(), None);
    let fine = Remedy::Remove {
        name: "gh".into(),
        global: true,
    };
    assert_eq!(fine.render().as_deref(), Some("kendex remove gh --global"));
    assert_eq!(
        Remedy::Add {
            kind: ItemKind::Skill,
            name: "-flag".into(),
            global: false
        }
        .render(),
        None,
        "a name shaped like an option never reaches a command position"
    );
}

#[test]
fn control_characters_and_secrets_never_reach_the_report() {
    let cleaned =
        shown("evil\x1b[2Jname with sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345 inside");
    assert!(!cleaned.contains('\x1b'), "{cleaned}");
    assert!(
        !cleaned.contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345"),
        "{cleaned}"
    );
}

#[test]
fn v1_manifest_reads_as_could_not_check() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let manifest_path = crate::manifest::manifest_path(&env, &scope);
    std::fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    // No schema key: the v1 shape.
    std::fs::write(&manifest_path, "[agents.orch]\nsource = \"kendex\"\n").unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    assert!(render_plain(&report).contains("v1 manifest"));
}
