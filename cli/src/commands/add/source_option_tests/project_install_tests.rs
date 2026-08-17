//! What a project-scope `add` writes, and the roots it refuses to write
//! through: custom catalog discovery, and the symlinked `.agents` ancestor
//! every install path has to be stopped at.

use super::*;

#[test]
fn add_discovers_agent_and_auto_skill_from_custom_catalog() {
    let root = tmpdir("custom-catalog-add");
    let source = root.join("source");
    let project = root.join("project");
    let home = root.join("home");
    let config_home = root.join("config");
    std::fs::create_dir_all(source.join("pkgs/agents")).unwrap();
    std::fs::create_dir_all(source.join("pkgs/skills/demo")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();
    std::fs::write(
        source.join("vstack.toml"),
        "[catalog]\nagents = [\"pkgs/agents\"]\nskills = [\"pkgs/skills\"]\n\n[agent-skills]\nrust = [\"demo\"]\n",
    )
    .unwrap();
    std::fs::write(
        source.join("pkgs/agents/rust.md"),
        "---\nname: rust\ndescription: Rust\nmodel: sonnet\nrole: engineer\n---\n# Rust\n",
    )
    .unwrap();
    std::fs::write(
        source.join("pkgs/skills/demo/SKILL.md"),
        "---\nname: demo\ndescription: Demo\n---\n# Demo\n",
    )
    .unwrap();

    crate::test_util::with_home_and_config(&home, &config_home, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["codex".into()]),
                Some(vec!["rust".into()]),
                None,
                None,
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap();
        })
    });

    assert!(project.join(".codex/agents/rust.toml").exists());
    assert!(project.join(".agents/skills/demo/SKILL.md").exists());
    let lock = config::LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert!(lock.entries.contains_key("rust"));
    assert!(lock.entries.contains_key("demo"));
    assert!(
        !lock.entries.get("demo").unwrap().source_hash.is_empty(),
        "custom catalog skill should get a source hash"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn add_reports_invalid_pi_extension_catalog_path() {
    let root = tmpdir("custom-catalog-bad-pi");
    let source = root.join("source");
    let project = root.join("project");
    let home = root.join("home");
    let config_home = root.join("config");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();
    std::fs::write(
        source.join("vstack.toml"),
        "[catalog]\nagents = [\"agents\"]\npi_extensions = [\"*/pi-packages\"]\n",
    )
    .unwrap();
    std::fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: Rust\nmodel: sonnet\nrole: engineer\n---\n# Rust\n",
    )
    .unwrap();

    let err = crate::test_util::with_home_and_config(&home, &config_home, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["codex".into()]),
                Some(vec!["rust".into()]),
                None,
                None,
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap_err()
        })
    });

    assert!(
        err.to_string()
            .contains("catalog glob is only supported on the last path segment"),
        "unexpected error: {err:#}"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn same_path_matches_symlinked_project_root_to_canonical_source() {
    let root = tmpdir("same-path-symlink");
    let source = root.join("source");
    let alias = root.join("source-link");
    std::fs::create_dir_all(&source).unwrap();
    std::os::unix::fs::symlink(&source, &alias).unwrap();

    assert!(same_path(&alias, &source));

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn project_add_rejects_symlinked_agents_ancestor_before_skill_install() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("linked-agents-preflight");
    let source = root.join("source");
    let project = root.join("project");
    let outside_agents = root.join("main-checkout-agents");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&outside_agents).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    write_demo_skill(&source);
    symlink(&outside_agents, project.join(".agents")).unwrap();

    let err = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["codex".into()]),
                None,
                Some(vec!["demo".into()]),
                None,
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap_err()
        })
    });

    assert!(
        err.to_string()
            .contains("refusing .agents path outside project root"),
        "expected linked-.agents containment refusal, got: {err:#}"
    );
    assert!(
        !outside_agents.join("skills/demo/SKILL.md").exists(),
        "add must not copy project skills through a linked .agents directory"
    );
    assert!(!project.join("vstack.settings.toml").exists());
    assert!(!project.join("vstack.toml").exists());
    assert!(!project.join(".vstack-lock.json").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn project_add_allows_copy_skill_install_that_does_not_touch_linked_agents_root() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("linked-agents-copy-scope");
    let source = root.join("source");
    let project = root.join("project");
    let outside_agents = root.join("main-checkout-agents");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&outside_agents).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    write_demo_skill(&source);
    symlink(&outside_agents, project.join(".agents")).unwrap();

    crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["claude-code".into()]),
                None,
                Some(vec!["demo".into()]),
                None,
                None,
                true,
                true,
                false,
                false,
                false,
            )
            .unwrap()
        })
    });

    assert!(project.join(".claude/skills/demo/SKILL.md").exists());
    assert!(
        !outside_agents.join("skills/demo/SKILL.md").exists(),
        "copy-mode Claude install should not write through .agents"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn project_add_rejects_auto_included_skill_with_preserved_symlink_method() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("linked-agents-auto-symlink");
    let source = root.join("source");
    let project = root.join("project");
    let outside_agents = root.join("main-checkout-agents");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&outside_agents).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    write_demo_skill(&source);
    write_demo_agent_source(&source);
    write_project_skill_lock(&project, &source, InstallMethod::Symlink);
    symlink(&outside_agents, project.join(".agents")).unwrap();

    let err = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["claude-code".into()]),
                Some(vec!["rust".into()]),
                None,
                None,
                None,
                true,
                true,
                false,
                false,
                false,
            )
            .unwrap_err()
        })
    });

    assert!(
        err.to_string()
            .contains("refusing .agents path outside project root"),
        "expected linked-.agents containment refusal, got: {err:#}"
    );
    assert!(!outside_agents.join("skills/demo/SKILL.md").exists());
    assert!(!project.join(".claude/skills/demo/SKILL.md").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn project_add_rejects_auto_skill_recovered_through_linked_agents_root() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("linked-agents-auto-recovered");
    let source = root.join("source");
    let project = root.join("project");
    let outside_agents = root.join("main-checkout-agents");
    let installed_skill = outside_agents.join("skills/demo");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&installed_skill).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    write_demo_skill(&source);
    write_demo_agent_source(&source);
    std::fs::write(installed_skill.join(".vstack-refreshed"), "managed\n").unwrap();
    symlink(&outside_agents, project.join(".agents")).unwrap();

    let err = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["claude-code".into()]),
                Some(vec!["rust".into()]),
                None,
                None,
                None,
                true,
                true,
                false,
                false,
                false,
            )
            .unwrap_err()
        })
    });

    assert!(
        err.to_string()
            .contains("refusing .agents path outside project root"),
        "expected linked-.agents containment refusal, got: {err:#}"
    );
    assert!(!project.join(".vstack-lock.json").exists());
    assert!(!project.join("vstack.toml").exists());
    assert!(!project.join(".claude/skills/demo").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn project_add_allows_auto_included_skill_with_preserved_copy_method() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("linked-agents-auto-copy");
    let source = root.join("source");
    let project = root.join("project");
    let outside_agents = root.join("main-checkout-agents");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&outside_agents).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    write_demo_skill(&source);
    write_demo_agent_source(&source);
    write_project_skill_lock(&project, &source, InstallMethod::Copy);
    symlink(&outside_agents, project.join(".agents")).unwrap();

    crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["claude-code".into()]),
                Some(vec!["rust".into()]),
                None,
                None,
                None,
                true,
                true,
                false,
                false,
                false,
            )
            .unwrap()
        })
    });

    assert!(project.join(".claude/skills/demo/SKILL.md").exists());
    assert!(!outside_agents.join("skills/demo/SKILL.md").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn project_add_seeds_settings_but_not_config_when_source_is_same_checkout_via_symlink() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("source-alias");
    let source = root.join("source");
    let alias = root.join("source-link");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    write_demo_skill(&source);
    std::fs::write(source.join("vstack.toml"), "[role-skills]\n").unwrap();
    symlink(&source, &alias).unwrap();

    crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&alias, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["codex".into()]),
                None,
                Some(vec!["demo".into()]),
                None,
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap()
        })
    });

    assert_eq!(
        std::fs::read_to_string(source.join("vstack.toml")).unwrap(),
        "[role-skills]\n"
    );
    let settings = std::fs::read_to_string(source.join("vstack.settings.toml"))
        .expect("settings seeding runs for a repo that is its own source");
    assert!(
        settings.contains("DEMO_TIMEOUT"),
        "the installed skill's settings keys are seeded: {settings}"
    );

    let _ = std::fs::remove_dir_all(root);
}
