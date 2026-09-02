use std::fs;

use super::*;
use crate::env::FakeOs;

use crate::test_util::source_path;

fn fixture() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    let source = tmp.path().join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(source.join("skills/gh")).unwrap();
    fs::write(source.join("skills/gh/SKILL.md"), "---\nname: gh\n---\nx\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\n[skills.gh]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();
    let scope = Scope::Project { root: project };
    (tmp, env, scope)
}

/// A reference can name the revision to read. A path that happens to
/// contain an `@` is still a path — the split only counts where what
/// precedes it is repository-shaped.
#[test]
fn a_reference_can_carry_the_revision_it_reads() {
    let (_tmp, env, scope) = fixture();
    for (name, reference) in [
        ("pinned", "owner/repo@v1.2.0"),
        ("tracked", "owner/other"),
        ("here", "../my@catalog"),
    ] {
        let report = add_source(&env, &scope, name, reference).unwrap();
        crate::apply::execute(&env, &report.plan).unwrap();
    }
    let manifest = crate::manifest::load_current(&crate::manifest::manifest_path(&env, &scope))
        .unwrap()
        .unwrap();

    let pinned = &manifest.sources["pinned"];
    assert_eq!(pinned.repo.as_deref(), Some("owner/repo"));
    assert_eq!(pinned.rev.as_deref(), Some("v1.2.0"));
    assert_eq!(manifest.sources["tracked"].rev, None);
    assert_eq!(
        manifest.sources["tracked"].repo.as_deref(),
        Some("owner/other")
    );
    let here = &manifest.sources["here"];
    assert_eq!(here.path.as_deref(), Some("../my@catalog"));
    assert_eq!(here.rev, None);
}

#[test]
fn removal_is_blocked_while_referenced_then_allowed() {
    let (_tmp, env, scope) = fixture();
    let error = remove_source(&env, &scope, "cat").unwrap_err();
    assert!(error.to_string().contains("skills.gh"));
    assert!(error.to_string().contains("disable the source"));

    let report = crate::engine::ops::remove(&env, &scope, &["gh".to_owned()], None, false).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    let report = remove_source(&env, &scope, "cat").unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    assert!(list_sources(&env, &scope).unwrap().is_empty());
}

#[test]
fn disable_deactivates_without_drift_and_reenable_restores() {
    let (_tmp, env, scope) = fixture();
    let report = crate::engine::audit(&env, &scope).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    let link = match &scope {
        Scope::Project { root } => root.join(".claude/skills/gh"),
        Scope::Global => unreachable!("fixture scope is a project"),
    };
    assert!(link.is_symlink());

    let report = toggle_source(&env, &scope, "cat", false).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    // Declared but inactive: the artifact stays (nothing to render it
    // away against), and audit reports no drift for it.
    let after = crate::engine::audit(&env, &scope).unwrap();
    assert!(after.notes.iter().any(|n| n.contains("disabled")));
    assert!(!after.drift.iter().any(|r| r.name == "gh"));

    let report = toggle_source(&env, &scope, "cat", true).unwrap();
    crate::apply::execute(&env, &report.plan).unwrap();
    let clean = crate::engine::audit(&env, &scope).unwrap();
    assert_eq!(clean.drift, vec![]);
    assert!(link.is_symlink());
}

#[test]
fn rows_show_reference_enablement_and_referents() {
    let (_tmp, env, scope) = fixture();
    let rows = list_sources(&env, &scope).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].name, "cat");
    assert!(!rows[0].is_remote);
    assert!(rows[0].enabled);
    assert_eq!(rows[0].declared_items, ["skills.gh"]);
}
