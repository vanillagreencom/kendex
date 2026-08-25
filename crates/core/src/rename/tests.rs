use super::*;
use crate::env::{Env, FakeOs};

/// The local-source dir rename binds to the tree as it was when the
/// plan was made. An edit landing inside it after planning refuses
/// the move, the edit survives, and the renames before it roll back.
#[test]
fn a_local_source_edit_after_planning_refuses_the_dir_rename() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("app");
    let skill = root.join(".vstack-local/skills/x/SKILL.md");
    std::fs::create_dir_all(skill.parent().unwrap()).unwrap();
    std::fs::write(&skill, "v1").unwrap();
    std::fs::write(root.join("vstack.toml"), "schema = 5\n").unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Project { root: root.clone() };

    let ops = rename_ops(&env, &scope).unwrap();
    std::fs::write(&skill, "edited after planning").unwrap();

    let error = crate::apply::execute(&env, &Plan { scope, ops }, None).unwrap_err();
    assert!(
        matches!(&error, CoreError::RolledBack { cause, .. }
            if matches!(**cause, CoreError::PlanStale { .. })),
        "{error:?}"
    );
    assert_eq!(
        std::fs::read_to_string(&skill).unwrap(),
        "edited after planning"
    );
    assert!(!root.join(".kendex-local").exists());
    // The manifest rename ahead of it rolled back to the old name.
    assert!(root.join("vstack.toml").is_file());
    assert!(!root.join("kendex.toml").exists());
}

/// A dangling link under the old local-source dir is kendex's to carry,
/// not a reason to refuse the scope: the dir moves whole, and the link
/// arrives at the new name still pointing where it pointed. Bound to the
/// bytes a link resolves to, this rename would fail planning — and with
/// it every audit, apply and save for the scope.
#[cfg(unix)]
#[test]
fn a_dangling_link_in_the_local_source_dir_moves_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("app");
    let old_local = root.join(".vstack-local");
    std::fs::create_dir_all(old_local.join("skills/x")).unwrap();
    std::fs::write(old_local.join("skills/x/SKILL.md"), "v1").unwrap();
    std::os::unix::fs::symlink("nowhere", old_local.join("skills/x/gone")).unwrap();
    std::fs::write(root.join("vstack.toml"), "schema = 5\n").unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Project { root: root.clone() };

    let ops = rename_ops(&env, &scope).unwrap();
    crate::apply::execute(&env, &Plan { scope, ops }, None).unwrap();

    let moved = root.join(".kendex-local/skills/x/gone");
    assert!(moved.is_symlink(), "{moved:?}");
    assert_eq!(std::fs::read_link(&moved).unwrap().as_os_str(), "nowhere");
    assert!(!old_local.exists());
}

/// A pipe under the old local-source dir refuses the scope at planning,
/// naming the pipe: the journal snapshots a moved directory by copying
/// it, and a copy of a reader-less pipe never returns — under the scope
/// lock. Refused here, the person learns which entry to remove.
#[cfg(target_os = "linux")]
#[test]
fn a_pipe_in_the_local_source_dir_refuses_planning_by_name() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("app");
    let old_local = root.join(".vstack-local");
    std::fs::create_dir_all(old_local.join("skills/x")).unwrap();
    std::fs::write(old_local.join("skills/x/SKILL.md"), "v1").unwrap();
    let pipe = old_local.join("skills/x/pipe");
    rustix::fs::mknodat(
        rustix::fs::CWD,
        &pipe,
        rustix::fs::FileType::Fifo,
        rustix::fs::Mode::RWXU,
        0,
    )
    .unwrap();
    std::fs::write(root.join("vstack.toml"), "schema = 5\n").unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let scope = Scope::Project { root };

    let error = rename_ops(&env, &scope).unwrap_err();
    assert!(
        matches!(&error, CoreError::Io { path, .. } if *path == pipe),
        "{error:?}"
    );
}

#[test]
fn source_catalog_migration_renames_both_definition_and_install_state() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("vstack.toml"), "is_source_catalog = true\n").unwrap();
    std::fs::write(root.join("vstack-local.toml"), "schema = 5\n").unwrap();
    let env = Env::fake(root, FakeOs::Linux);
    let scope = Scope::Project {
        root: root.to_path_buf(),
    };

    let ops = rename_ops(&env, &scope).unwrap();
    let said: Vec<&str> = ops.iter().map(|o| o.description.as_str()).collect();
    assert!(
        said.iter()
            .any(|d| d.contains("vstack-local.toml becomes kendex-local.toml")),
        "install state must move: {said:?}",
    );
    assert!(
        said.iter()
            .any(|d| d.contains("vstack.toml becomes kendex.toml")),
        "the catalog definition must move too: {said:?}",
    );
}
