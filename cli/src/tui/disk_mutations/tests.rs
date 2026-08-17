use super::*;
use crate::agent::{Agent, AgentRole};
use crate::config::{InstallMethod, LockEntry, LockFile};
use crate::mapping::{HookTarget, MappingConfig};
use std::path::{Path, PathBuf};

fn agent_fixture(name: &str) -> Agent {
    Agent {
        name: name.to_string(),
        description: format!("{name} agent"),
        model: "sonnet".into(),
        role: AgentRole::Engineer,
        color: None,
        effort: None,
        body: String::new(),
        source_path: PathBuf::new(),
    }
}

fn hook_fixture(name: &str, harnesses: Option<Vec<&str>>) -> crate::hook::Hook {
    crate::hook::Hook {
        name: name.into(),
        event: "PreToolUse".into(),
        matcher: Some("Bash".into()),
        description: String::new(),
        safety: None,
        timeout: None,
        harnesses: harnesses.map(|items| items.into_iter().map(String::from).collect()),
        script: String::new(),
        source_path: PathBuf::new(),
    }
}

fn codex_fallback_hook(name: &str) -> crate::hook::Hook {
    crate::hook::Hook {
        name: name.into(),
        event: "TaskCompleted".into(),
        matcher: None,
        description: "Complete task safely".into(),
        safety: Some("Check completion state.".into()),
        timeout: None,
        harnesses: Some(vec!["codex".into()]),
        script: String::new(),
        source_path: PathBuf::new(),
    }
}

fn agent_frontmatter(content: &str) -> &str {
    content
        .strip_prefix("---\n")
        .and_then(|rest| rest.split_once("\n---\n"))
        .map(|(frontmatter, _)| frontmatter)
        .expect("frontmatter present")
}

fn tmpdir(label: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "vstack-disk-mutations-{label}-{}-{nanos}",
        std::process::id()
    ))
}

fn init_git_origin(dir: &std::path::Path, origin: &str) {
    let status = std::process::Command::new("git")
        .args(["init", "-q"])
        .current_dir(dir)
        .status()
        .unwrap();
    assert!(status.success());
    let status = std::process::Command::new("git")
        .args(["remote", "add", "origin", origin])
        .current_dir(dir)
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn filter_harnesses_drops_cursor_when_moving_to_global() {
    // Regression: Cursor is project-only. A move-to-global plan must
    // not pretend it can land at global, otherwise the destination
    // lock entry would claim Cursor was installed there and the source
    // copy would be deleted with no working replacement on disk.
    let ids = vec!["cursor".to_string(), "claude-code".to_string()];

    let to_global = filter_harnesses_for_target(&ids, true);
    assert_eq!(to_global, vec![Harness::ClaudeCode]);

    let to_project = filter_harnesses_for_target(&ids, false);
    assert!(to_project.contains(&Harness::Cursor));
    assert!(to_project.contains(&Harness::ClaudeCode));
}

#[test]
fn filter_harnesses_returns_empty_for_global_only_cursor_entry() {
    // If the only harness on a plan is project-only, the move target
    // has no eligible harness — perform_move_plans skips the plan and
    // leaves the source intact.
    let ids = vec!["cursor".to_string()];
    assert!(filter_harnesses_for_target(&ids, true).is_empty());
    assert_eq!(
        filter_harnesses_for_target(&ids, false),
        vec![Harness::Cursor]
    );
}

#[test]
fn filter_harnesses_skips_unknown_ids() {
    let ids = vec!["claude-code".to_string(), "made-up-harness".to_string()];
    let result = filter_harnesses_for_target(&ids, true);
    assert_eq!(result, vec![Harness::ClaudeCode]);
}

#[test]
fn hook_move_target_filter_respects_current_hook_allowlist() {
    let hook = hook_fixture("guard", Some(vec!["codex"]));
    let target_harnesses = vec![Harness::ClaudeCode, Harness::Codex];

    assert_eq!(
        filter_harnesses_for_hook_target(&hook, &target_harnesses),
        vec![Harness::Codex]
    );
    assert!(filter_harnesses_for_hook_target(&hook, &[Harness::ClaudeCode]).is_empty());
}

#[test]
fn move_destination_hook_matching_uses_destination_harness_lock() {
    let mut dst_lock = LockFile::default();
    dst_lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    let items = DiscoveredItems {
        agents: Vec::new(),
        skills: Vec::new(),
        hooks: vec![hook_fixture("guard", None)],
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let mut mapping = MappingConfig::default();
    mapping
        .hook_events
        .insert("PreToolUse:Bash".into(), HookTarget::All("all".into()));
    let agent = agent_fixture("rust");

    assert_eq!(
        matched_hooks_for_move_destination(
            &dst_lock,
            &items,
            &mapping,
            &agent,
            Harness::ClaudeCode,
        )
        .len(),
        1
    );
    assert!(
        matched_hooks_for_move_destination(&dst_lock, &items, &mapping, &agent, Harness::Codex,)
            .is_empty()
    );
}

#[test]
fn codex_hooks_are_reinstalled_for_newly_moved_agents() {
    let root = tmpdir("codex-moved-agent-hooks");
    let codex_home = root.join("codex");
    let agents_dir = codex_home.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    std::fs::write(
        agents_dir.join("rust.toml"),
        "name = \"rust\"\ndeveloper_instructions = '''\nBody\n'''\n",
    )
    .unwrap();

    let mut dst_lock = LockFile::default();
    dst_lock.add(LockEntry {
        name: "finish-check".into(),
        kind: ItemKind::Hook,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["codex".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    let items = DiscoveredItems {
        agents: vec![agent_fixture("rust")],
        skills: Vec::new(),
        hooks: vec![codex_fallback_hook("finish-check")],
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };

    crate::test_util::with_codex_home(&codex_home, || {
        reinstall_codex_hooks_for_moved_agents(&items, &["rust".to_string()], true, &dst_lock)
            .unwrap();
    });

    let content = std::fs::read_to_string(agents_dir.join("rust.toml")).unwrap();
    assert!(content.contains("## Safety: finish-check"));
    assert!(content.contains("Check completion state."));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn generate_moved_agents_reports_when_no_harness_succeeds() {
    let mut dst_lock = LockFile::default();
    let entry = LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["cursor".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    };
    let intent = AgentMoveIntent {
        name: "rust".into(),
        entry,
        target_harnesses: vec![Harness::Cursor],
    };
    let items = DiscoveredItems {
        agents: vec![agent_fixture("rust")],
        skills: Vec::new(),
        hooks: Vec::new(),
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let mut report = DiskMutationReport::new(1);

    let moved = generate_moved_agents(
        &items,
        &[intent],
        true,
        &mut dst_lock,
        &MappingConfig::default(),
        &crate::project_config::ProjectConfig::default(),
        &mut report,
    );

    assert!(moved.is_empty());
    assert!(!dst_lock.entries.contains_key("rust"));
    assert_eq!(report.failed.len(), 1);
    assert!(report.failed[0].contains("rust"));
    assert!(report.failed[0].contains("Cursor"));
}

#[test]
fn generate_moved_agents_rejects_name_that_escapes_output_dir() {
    let root = tmpdir("move-agent-name-traversal");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();

    let mut dst_lock = LockFile::default();
    let entry = LockEntry {
        name: "../../pwned".into(),
        kind: ItemKind::Agent,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into(), "codex".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    };
    let intent = AgentMoveIntent {
        name: "../../pwned".into(),
        entry,
        target_harnesses: vec![Harness::ClaudeCode, Harness::Codex],
    };
    let items = DiscoveredItems {
        agents: vec![agent_fixture("../../pwned")],
        skills: Vec::new(),
        hooks: Vec::new(),
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let mut report = DiskMutationReport::new(1);

    let moved = crate::test_util::with_project_root(&project, || {
        generate_moved_agents(
            &items,
            &[intent],
            false,
            &mut dst_lock,
            &MappingConfig::default(),
            &crate::project_config::ProjectConfig::default(),
            &mut report,
        )
    });

    assert!(moved.is_empty());
    assert!(!dst_lock.entries.contains_key("../../pwned"));
    assert_eq!(report.failed.len(), 1);
    assert!(report.failed[0].contains("invalid agent name"));
    assert!(!project.join("pwned.md").exists());
    assert!(!project.join("pwned.toml").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn generate_moved_agents_reports_partial_failure_and_rolls_back_success() {
    let root = tmpdir("partial-agent-move");
    let project = root.join("project");
    std::fs::create_dir_all(project.join(".codex")).unwrap();
    std::fs::write(project.join(".codex/agents"), "not a directory").unwrap();

    let mut dst_lock = LockFile::default();
    let entry = LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into(), "codex".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    };
    let intent = AgentMoveIntent {
        name: "rust".into(),
        entry,
        target_harnesses: vec![Harness::ClaudeCode, Harness::Codex],
    };
    let items = DiscoveredItems {
        agents: vec![agent_fixture("rust")],
        skills: Vec::new(),
        hooks: Vec::new(),
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let mut report = DiskMutationReport::new(1);

    let moved = crate::test_util::with_project_root(&project, || {
        generate_moved_agents(
            &items,
            &[intent],
            false,
            &mut dst_lock,
            &MappingConfig::default(),
            &crate::project_config::ProjectConfig::default(),
            &mut report,
        )
    });

    assert!(moved.is_empty());
    assert!(!dst_lock.entries.contains_key("rust"));
    assert_eq!(report.failed.len(), 1);
    assert!(report.failed[0].contains("partial destination failure"));
    assert!(report.failed[0].contains("Codex"));
    assert!(
        !project.join(".claude/agents/rust.md").exists(),
        "successful Claude write should be rolled back on partial failure"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn perform_move_plans_aborts_when_destination_lock_is_unreadable() {
    let root = tmpdir("move-corrupt-dst-lock");
    let project = root.join("project");
    let source = root.join("source");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(config.join("vstack")).unwrap();
    std::fs::write(source.join("vstack.toml"), "").unwrap();
    std::fs::write(source.join("agents/rust.md"), "# Rust\n").unwrap();
    std::fs::write(config.join("vstack/.vstack-lock.json"), "{not-json").unwrap();

    let mut agent = agent_fixture("rust");
    agent.source_path = source.join("agents/rust.md");
    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();
    let items = DiscoveredItems {
        agents: vec![agent],
        skills: Vec::new(),
        hooks: Vec::new(),
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let plan = MovePlan {
        name: "rust".into(),
        kind_label: "agent".into(),
        from_global: false,
    };

    let report = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || perform_move_plans(&items, &[plan], true))
    });

    assert_eq!(report.completed, 0);
    assert_eq!(report.failed.len(), 1);
    assert!(report.failed[0].contains("failed to load destination lock"));
    assert!(!home.join(".claude/agents/rust.md").exists());
    assert!(project.join(".vstack-lock.json").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn perform_move_plans_moves_agent_and_cleans_source() {
    let root = tmpdir("move-agent-success");
    let project = root.join("project");
    let source = root.join("source");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(source.join("vstack.toml"), "").unwrap();
    std::fs::write(source.join("agents/rust.md"), "# Rust\n").unwrap();

    let mut agent = agent_fixture("rust");
    agent.body = "# Rust\n\nMoved body.\n".into();
    agent.source_path = source.join("agents/rust.md");
    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();
    let items = DiscoveredItems {
        agents: vec![agent.clone()],
        skills: Vec::new(),
        hooks: Vec::new(),
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let plan = MovePlan {
        name: "rust".into(),
        kind_label: "agent".into(),
        from_global: false,
    };

    let report = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            Harness::ClaudeCode
                .generate_agent(
                    &agent,
                    false,
                    &[],
                    &[],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap();
            perform_move_plans(&items, &[plan], true)
        })
    });

    assert_eq!(report.completed, 1, "report: {report:?}");
    assert!(report.failed.is_empty(), "report: {report:?}");
    assert!(home.join(".claude/agents/rust.md").exists());
    assert!(!project.join(".claude/agents/rust.md").exists());
    let dst_lock = LockFile::load(&config.join("vstack/.vstack-lock.json")).unwrap();
    assert!(dst_lock.entries.contains_key("rust"));
    let src_lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert!(!src_lock.entries.contains_key("rust"));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn perform_move_plans_moves_skill_and_cleans_source() {
    let root = tmpdir("move-skill-success");
    let project = root.join("project");
    let source = root.join("source");
    let home = root.join("home");
    let config = root.join("config");
    let skill_dir = source.join("skills/dev");
    std::fs::create_dir_all(&skill_dir).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: dev\ndescription: Dev skill\nlicense: MIT\n---\n# Dev\n",
    )
    .unwrap();
    let skill = crate::skill::Skill::from_file(&skill_dir.join("SKILL.md")).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "dev".into(),
        kind: ItemKind::Skill,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();
    let items = DiscoveredItems {
        agents: Vec::new(),
        skills: vec![skill.clone()],
        hooks: Vec::new(),
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let plan = MovePlan {
        name: "dev".into(),
        kind_label: "skill".into(),
        from_global: false,
    };

    let report = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            crate::installer::install_skill(
                &skill,
                Harness::ClaudeCode,
                false,
                InstallMethod::Copy,
                None,
            )
            .unwrap();
            perform_move_plans(&items, &[plan], true)
        })
    });

    assert_eq!(report.completed, 1, "report: {report:?}");
    assert!(report.failed.is_empty(), "report: {report:?}");
    assert!(home.join(".claude/skills/dev/SKILL.md").exists());
    assert!(!project.join(".claude/skills/dev").exists());
    let dst_lock = LockFile::load(&config.join("vstack/.vstack-lock.json")).unwrap();
    assert!(dst_lock.entries.contains_key("dev"));
    let src_lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert!(!src_lock.entries.contains_key("dev"));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn perform_move_plans_moves_hook_and_cleans_source() {
    let root = tmpdir("move-hook-success");
    let project = root.join("project");
    let source = root.join("source");
    let home = root.join("home");
    let config = root.join("config");
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    let mut hook = hook_fixture("guard", None);
    hook.source_path = source.join("hooks/guard.sh");
    hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
    std::fs::write(&hook.source_path, &hook.script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();
    let items = DiscoveredItems {
        agents: Vec::new(),
        skills: Vec::new(),
        hooks: vec![hook.clone()],
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };
    let plan = MovePlan {
        name: "guard".into(),
        kind_label: "hook".into(),
        from_global: false,
    };

    let report = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_project_root(&project, || {
            crate::installer::install_hook(&hook, Harness::ClaudeCode, false, &[]).unwrap();
            perform_move_plans(&items, &[plan], true)
        })
    });

    assert_eq!(report.completed, 1, "report: {report:?}");
    assert!(report.failed.is_empty(), "report: {report:?}");
    assert!(home.join(".claude/hooks/guard.sh").exists());
    assert!(!project.join(".claude/hooks/guard.sh").exists());
    let dst_lock = LockFile::load(&config.join("vstack/.vstack-lock.json")).unwrap();
    assert!(dst_lock.entries.contains_key("guard"));
    let src_lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert!(!src_lock.entries.contains_key("guard"));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn perform_move_plans_moves_pi_package_and_cleans_source() {
    let root = tmpdir("move-pi-success");
    let project = root.join("project");
    let source = root.join("source");
    let home = root.join("home");
    let config = root.join("config");
    let pi_global = root.join("pi-agent");
    let ext_dir = source.join("pi-extensions/pi-mini");
    std::fs::create_dir_all(ext_dir.join("extensions")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(ext_dir.join("extensions/mini.ts"), "// noop\n").unwrap();
    std::fs::write(
        ext_dir.join("package.json"),
        r#"{ "name": "pi-mini", "pi": { "extensions": ["./extensions/mini.ts"] } }"#,
    )
    .unwrap();
    let ext = crate::pi_extension::PiExtension::from_dir(&ext_dir).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "pi-mini".into(),
        kind: ItemKind::PiExtension,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["pi".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();
    let items = DiscoveredItems {
        agents: Vec::new(),
        skills: Vec::new(),
        hooks: Vec::new(),
        pi_extensions: vec![ext.clone()],
        extras: Vec::new(),
    };
    let plan = MovePlan {
        name: "pi-mini".into(),
        kind_label: "pi-package".into(),
        from_global: false,
    };

    let report = crate::test_util::with_home_and_config(&home, &config, || {
        crate::test_util::with_pi_dir(&pi_global, || {
            crate::test_util::with_project_root(&project, || {
                crate::pi_extension::install_pi_extension(&ext, false)
                    .unwrap()
                    .unwrap();
                perform_move_plans(&items, &[plan], true)
            })
        })
    });

    assert_eq!(report.completed, 1, "report: {report:?}");
    assert!(report.failed.is_empty(), "report: {report:?}");
    assert!(pi_global.join("packages/pi-mini/package.json").exists());
    assert!(!project.join(".pi/packages/pi-mini").exists());
    let dst_lock = LockFile::load(&config.join("vstack/.vstack-lock.json")).unwrap();
    assert!(dst_lock.entries.contains_key("pi-mini"));
    let src_lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert!(!src_lock.entries.contains_key("pi-mini"));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn perform_remove_plans_reports_corrupt_lock() {
    let root = tmpdir("remove-corrupt-lock");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join(".vstack-lock.json"), "{not-json").unwrap();
    let plan = RemovePlan {
        name: "rust".into(),
        kind_label: "agent".into(),
        from_project: true,
        from_global: false,
    };

    let report = crate::test_util::with_project_root(&project, || perform_remove_plans(&[plan]));

    assert_eq!(report.completed, 0);
    assert_eq!(report.failed.len(), 1);
    assert!(report.failed[0].contains("failed to load lock"));

    let _ = std::fs::remove_dir_all(root);
}

/// Write `hook` into `source/hooks/<name>.sh` in the on-disk hook format, so
/// the update path discovers it from the source the way `vstack refresh` does.
fn write_source_hook(source: &std::path::Path, hook: &crate::hook::Hook) {
    let matcher = hook
        .matcher
        .as_deref()
        .map(|m| format!("# matcher: {m}\n"))
        .unwrap_or_default();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::write(
        source.join("hooks").join(format!("{}.sh", hook.name)),
        format!(
            "#!/usr/bin/env bash\n# ---\n# name: {}\n# event: {}\n{matcher}# description: {} hook\n# ---\nexit 0\n",
            hook.name, hook.event, hook.name
        ),
    )
    .unwrap();
}

fn write_source_agent(source: &std::path::Path, agent: &Agent) {
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::write(
        source.join("agents").join(format!("{}.md", agent.name)),
        format!(
            "---\nname: {}\ndescription: {}\nmodel: {}\nrole: engineer\n---\n# {}\n",
            agent.name, agent.description, agent.model, agent.name
        ),
    )
    .unwrap();
}

fn hook_lock_entry(name: &str, source: &std::path::Path) -> LockEntry {
    LockEntry {
        name: name.into(),
        kind: ItemKind::Hook,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    }
}

#[test]
fn inline_update_refreshes_hook_config_and_agents() {
    let root = tmpdir("inline-update-hook");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    init_git_origin(&source, "git@github.com:vanillagreencom/vstack.git");
    std::fs::write(
        source.join("vstack.toml"),
        "[hook-events]\n\"PostCompact:\" = \"all\"\n",
    )
    .unwrap();

    let mut agent = agent_fixture("rust");
    agent.source_path = source.join("agents/rust.md");
    write_source_agent(&source, &agent);
    let mut old_hook = hook_fixture("guard", None);
    old_hook.source_path = source.join("hooks/guard.sh");
    old_hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
    let mut new_hook = old_hook.clone();
    new_hook.event = "PostCompact".into();
    new_hook.matcher = None;
    write_source_hook(&source, &new_hook);

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(hook_lock_entry("guard", &source));
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&old_hook, Harness::ClaudeCode, false, &[]).unwrap();
        Harness::ClaudeCode
            .generate_agent(
                &agent,
                false,
                &[],
                &[old_hook.clone()],
                &crate::agent::AgentExtras::default(),
            )
            .unwrap();

        let report = perform_inline_update(&["guard".to_string()]);
        assert_eq!(report.completed, 1, "report: {report:?}");
        assert!(report.failed.is_empty(), "report: {report:?}");
    });

    let settings = std::fs::read_to_string(project.join(".claude/settings.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&settings).unwrap();
    assert!(
        parsed.pointer("/hooks/PreToolUse").is_none(),
        "stale PreToolUse settings: {settings}"
    );
    assert!(
        parsed.pointer("/hooks/PostCompact").is_some(),
        "missing PostCompact settings: {settings}"
    );

    let agent_body = std::fs::read_to_string(project.join(".claude/agents/rust.md")).unwrap();
    let frontmatter: serde_json::Value = serde_yaml::from_str(agent_frontmatter(&agent_body))
        .expect("valid Claude frontmatter after inline update");
    assert!(frontmatter.pointer("/hooks/PreToolUse").is_none());
    assert!(frontmatter.pointer("/hooks/PostCompact").is_some());

    let lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert_eq!(
        lock.entries
            .get("guard")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("vanillagreencom/vstack")
    );
    assert_eq!(
        lock.entries
            .get("rust")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("vanillagreencom/vstack")
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn inline_update_clears_stale_source_repo_for_local_source_without_origin() {
    let root = tmpdir("inline-update-source-repo-clear");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&project).unwrap();

    let mut hook = hook_fixture("guard", None);
    hook.source_path = source.join("hooks/guard.sh");
    hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
    write_source_hook(&source, &hook);

    let mut lock = LockFile::default();
    let mut entry = hook_lock_entry("guard", &source);
    entry.source_repo = Some("vanillagreencom/vstack".to_string());
    lock.add(entry);
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&hook, Harness::ClaudeCode, false, &[]).unwrap();
        let report = perform_inline_update(&["guard".to_string()]);
        assert_eq!(report.completed, 1, "report: {report:?}");
        assert!(report.failed.is_empty(), "report: {report:?}");
    });

    let lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert_eq!(lock.entries.get("guard").unwrap().source_repo, None);

    let _ = std::fs::remove_dir_all(root);
}

/// Two stale installs recorded from two different sources, updated together:
/// each refreshes from its own source and records that source's identity —
/// whichever source the picker has selected.
#[test]
fn inline_update_refreshes_each_entry_from_its_own_source() {
    let root = tmpdir("inline-update-two-sources");
    let project = root.join("project");
    let source_a = root.join("source-a");
    let source_b = root.join("source-b");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&source_a).unwrap();
    std::fs::create_dir_all(&source_b).unwrap();
    init_git_origin(&source_a, "git@github.com:example/alpha.git");
    init_git_origin(&source_b, "git@github.com:example/beta.git");

    // Installed copies carry the old event; each source now publishes a new one.
    let mut old_a = hook_fixture("guard-a", None);
    old_a.script = "#!/usr/bin/env bash\nexit 0\n".into();
    old_a.source_path = source_a.join("hooks/guard-a.sh");
    let mut old_b = hook_fixture("guard-b", None);
    old_b.script = "#!/usr/bin/env bash\nexit 0\n".into();
    old_b.source_path = source_b.join("hooks/guard-b.sh");
    let mut new_a = old_a.clone();
    new_a.event = "PostCompact".into();
    new_a.matcher = None;
    let mut new_b = old_b.clone();
    new_b.event = "SessionStart".into();
    new_b.matcher = None;
    write_source_hook(&source_a, &new_a);
    write_source_hook(&source_b, &new_b);

    let mut lock = LockFile::default();
    lock.add(hook_lock_entry("guard-a", &source_a));
    lock.add(hook_lock_entry("guard-b", &source_b));
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&old_a, Harness::ClaudeCode, false, &[]).unwrap();
        crate::installer::install_hook(&old_b, Harness::ClaudeCode, false, &[]).unwrap();

        let names = vec!["guard-a".to_string(), "guard-b".to_string()];
        let report = perform_inline_update(&names);
        assert_eq!(report.completed, 2, "report: {report:?}");
        assert!(report.failed.is_empty(), "report: {report:?}");
    });

    let settings = std::fs::read_to_string(project.join(".claude/settings.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&settings).unwrap();
    assert!(
        parsed.pointer("/hooks/PreToolUse").is_none(),
        "stale PreToolUse settings: {settings}"
    );
    assert!(
        parsed.pointer("/hooks/PostCompact").is_some(),
        "guard-a not refreshed from source-a: {settings}"
    );
    assert!(
        parsed.pointer("/hooks/SessionStart").is_some(),
        "guard-b not refreshed from source-b: {settings}"
    );

    let lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert_eq!(
        lock.entries["guard-a"].source_repo.as_deref(),
        Some("example/alpha")
    );
    assert_eq!(
        lock.entries["guard-b"].source_repo.as_deref(),
        Some("example/beta")
    );
    assert!(
        !lock.entries["guard-a"].source_hash.is_empty()
            && !lock.entries["guard-b"].source_hash.is_empty(),
        "both entries re-hashed against their own source"
    );

    let _ = std::fs::remove_dir_all(root);
}

/// A stale entry whose source has vanished cannot refresh; the report must
/// say so instead of counting it as neither done nor failed.
#[test]
fn inline_update_reports_an_entry_whose_source_is_gone() {
    let root = tmpdir("inline-update-source-gone");
    let project = root.join("project");
    let live = root.join("live-source");
    let gone = root.join("gone-source");
    std::fs::create_dir_all(&project).unwrap();

    let mut live_hook = hook_fixture("guard-live", None);
    live_hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
    live_hook.source_path = live.join("hooks/guard-live.sh");
    write_source_hook(&live, &live_hook);
    let mut gone_hook = hook_fixture("guard-gone", None);
    gone_hook.script = "#!/usr/bin/env bash\nexit 0\n".into();

    let mut lock = LockFile::default();
    lock.add(hook_lock_entry("guard-live", &live));
    lock.add(hook_lock_entry("guard-gone", &gone));
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let report = crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&live_hook, Harness::ClaudeCode, false, &[]).unwrap();
        crate::installer::install_hook(&gone_hook, Harness::ClaudeCode, false, &[]).unwrap();
        perform_inline_update(&["guard-live".to_string(), "guard-gone".to_string()])
    });

    assert_eq!(report.completed, 1, "report: {report:?}");
    assert_eq!(
        report.failed,
        vec![format!(
            "guard-gone: not refreshed: source not found: {}",
            gone.display()
        )],
        "a requested item names its vanished source: {report:?}"
    );

    let _ = std::fs::remove_dir_all(root);
}

/// Extras are applied, not installed — the refresh pass has no branch for
/// them, so a stale extra picked from the Updates tab used to count as
/// neither done nor failed ("Updated 0 item(s)"). It is skipped with a
/// notice naming the command that re-applies it — a notice, not a failure,
/// so it cannot veto the CLI update batched behind the same "Update All" —
/// and the rest of the request still refreshes.
#[test]
fn inline_update_skips_extras_with_a_notice_and_refreshes_the_rest() {
    let root = tmpdir("inline-update-extra");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&project).unwrap();

    let mut hook = hook_fixture("guard", None);
    hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
    hook.source_path = source.join("hooks/guard.sh");
    write_source_hook(&source, &hook);

    let mut lock = LockFile::default();
    lock.add(hook_lock_entry("guard", &source));
    lock.add(LockEntry {
        name: "vanillagreen-themes".into(),
        kind: ItemKind::Extra,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: Vec::new(),
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: "stale".into(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let report = crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&hook, Harness::ClaudeCode, false, &[]).unwrap();
        perform_inline_update(&["guard".to_string(), "vanillagreen-themes".to_string()])
    });

    assert!(
        report.failed.is_empty(),
        "a skipped extra is not a failure (it must not veto the CLI update): {report:?}"
    );
    assert_eq!(
        report.notices,
        vec![
            "skipped vanillagreen-themes: extras are reapplied with `vstack apply vanillagreen-themes`"
                .to_string()
        ],
        "report: {report:?}"
    );
    assert_eq!(report.completed, 1, "the hook still refreshes: {report:?}");
    assert_eq!(
        report.attempted, 1,
        "a skipped extra was never attempted: {report:?}"
    );

    let _ = std::fs::remove_dir_all(root);
}

/// Updating a hook regenerates every installed agent so its hook payload
/// stays current. An agent that cannot be regenerated is a real outcome the
/// user must see, but it is not an item they asked to update — the message
/// says what happened instead of reading like a failed request.
#[test]
fn inline_update_names_agents_it_could_not_regenerate_after_a_hook_update() {
    let root = tmpdir("inline-update-expanded-agent-missing");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(source.join("agents")).unwrap();

    let mut old_hook = hook_fixture("guard", None);
    old_hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
    old_hook.source_path = source.join("hooks/guard.sh");
    let mut new_hook = old_hook.clone();
    new_hook.event = "PostCompact".into();
    new_hook.matcher = None;
    write_source_hook(&source, &new_hook);
    // `rust` is locked as installed from this source, but the source no
    // longer carries agents/rust.md.
    let agent = agent_fixture("rust");

    let mut lock = LockFile::default();
    lock.add(hook_lock_entry("guard", &source));
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let report = crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&old_hook, Harness::ClaudeCode, false, &[]).unwrap();
        Harness::ClaudeCode
            .generate_agent(
                &agent,
                false,
                &[],
                &[old_hook.clone()],
                &crate::agent::AgentExtras::default(),
            )
            .unwrap();
        perform_inline_update(&["guard".to_string()])
    });

    assert_eq!(
        report.completed, 1,
        "the requested hook updates: {report:?}"
    );
    assert_eq!(
        report.failed,
        vec![format!(
            "rust: agent not regenerated after hook update: not found in source {}",
            source.display()
        )],
        "report: {report:?}"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn tui_remove_hook_refreshes_claude_agent_frontmatter() {
    let root = tmpdir("remove-hook-agent-refresh");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        source.join("vstack.toml"),
        "[hook-events]\n\"PreToolUse:Bash\" = \"all\"\n",
    )
    .unwrap();
    std::fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: rust agent\nmodel: sonnet\nrole: engineer\n---\n# Rust\n",
    )
    .unwrap();
    std::fs::write(
            source.join("hooks/guard.sh"),
            "# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: guard\n# ---\n#!/usr/bin/env bash\nexit 0\n",
        )
        .unwrap();

    let mut agent = agent_fixture("rust");
    agent.source_path = source.join("agents/rust.md");
    let mut hook = hook_fixture("guard", None);
    hook.source_path = source.join("hooks/guard.sh");
    hook.script = "#!/usr/bin/env bash\nexit 0\n".into();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&hook, Harness::ClaudeCode, false, &[]).unwrap();
        Harness::ClaudeCode
            .generate_agent(
                &agent,
                false,
                &[],
                &[hook.clone()],
                &crate::agent::AgentExtras::default(),
            )
            .unwrap();

        assert!(remove_one("guard", false, &mut Vec::new()).unwrap());
    });

    let agent_body = std::fs::read_to_string(project.join(".claude/agents/rust.md")).unwrap();
    let frontmatter: serde_json::Value = serde_yaml::from_str(agent_frontmatter(&agent_body))
        .expect("valid Claude frontmatter after TUI remove");
    assert!(
        frontmatter.get("hooks").is_none(),
        "stale frontmatter: {agent_body}"
    );
    assert!(!agent_body.contains(".claude/hooks/guard.sh"));
    assert!(!project.join(".claude/hooks/guard.sh").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[derive(Clone, Copy)]
enum BrokenRemovalConfig {
    Malformed,
    Unreadable,
}

fn assert_tui_hook_removal_rejects_broken_config(kind: BrokenRemovalConfig) {
    let root = tmpdir(match kind {
        BrokenRemovalConfig::Malformed => "remove-hook-malformed-config",
        BrokenRemovalConfig::Unreadable => "remove-hook-unreadable-config",
    });
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        source.join("vstack.toml"),
        "[hook-events]\n\"PreToolUse:Bash\" = \"all\"\n",
    )
    .unwrap();
    std::fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: rust agent\nmodel: sonnet\nrole: engineer\n---\n# Rust\n",
    )
    .unwrap();
    std::fs::write(
        source.join("hooks/guard.sh"),
        "# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: guard\n# ---\n#!/usr/bin/env bash\nexit 0\n",
    )
    .unwrap();

    let mut agent = agent_fixture("rust");
    agent.source_path = source.join("agents/rust.md");
    let mut hook = hook_fixture("guard", None);
    hook.source_path = source.join("hooks/guard.sh");
    hook.script = "#!/usr/bin/env bash\nexit 0\n".into();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-15T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-15T00:00:00Z".into(),
        source_hash: String::new(),
    });
    let lock_path = project.join(".vstack-lock.json");
    lock.save(&lock_path).unwrap();

    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&hook, Harness::ClaudeCode, false, &[]).unwrap();
        Harness::ClaudeCode
            .generate_agent(
                &agent,
                false,
                &[],
                &[hook.clone()],
                &crate::agent::AgentExtras::default(),
            )
            .unwrap();
    });

    let hook_path = project.join(".claude/hooks/guard.sh");
    let settings_path = project.join(".claude/settings.json");
    let agent_path = project.join(".claude/agents/rust.md");
    let hook_bytes = std::fs::read(&hook_path).unwrap();
    let settings_bytes = std::fs::read(&settings_path).unwrap();
    let agent_bytes = std::fs::read(&agent_path).unwrap();
    let lock_bytes = std::fs::read(&lock_path).unwrap();

    match kind {
        BrokenRemovalConfig::Malformed => {
            std::fs::write(project.join("vstack.toml"), "[agent-skills\n").unwrap();
        }
        BrokenRemovalConfig::Unreadable => {
            std::fs::create_dir(project.join("vstack.toml")).unwrap();
        }
    }

    let plan = RemovePlan {
        name: "guard".into(),
        kind_label: "hook".into(),
        from_project: true,
        from_global: false,
    };
    let report = crate::test_util::with_project_root(&project, || perform_remove_plans(&[plan]));

    assert_eq!(report.completed, 0, "report: {report:?}");
    assert_eq!(report.failed.len(), 1, "report: {report:?}");
    let expected = match kind {
        BrokenRemovalConfig::Malformed => "parsing",
        BrokenRemovalConfig::Unreadable => "reading",
    };
    assert!(report.failed[0].contains(expected), "report: {report:?}");
    assert_eq!(std::fs::read(&hook_path).unwrap(), hook_bytes);
    assert_eq!(std::fs::read(&settings_path).unwrap(), settings_bytes);
    assert_eq!(std::fs::read(&agent_path).unwrap(), agent_bytes);
    assert_eq!(std::fs::read(&lock_path).unwrap(), lock_bytes);

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn tui_hook_removal_keeps_state_on_malformed_project_config() {
    assert_tui_hook_removal_rejects_broken_config(BrokenRemovalConfig::Malformed);
}

#[test]
fn tui_hook_removal_keeps_state_on_unreadable_project_config() {
    assert_tui_hook_removal_rejects_broken_config(BrokenRemovalConfig::Unreadable);
}

/// The wizard's completed count is a claim about the items the user selected.
/// An entry whose source has nothing to refresh from is not a failed install
/// attempt, but reporting it as neither left the count short with no reason —
/// and each cause has its own remedy, so each is named.
#[test]
fn inline_update_reports_items_that_had_no_source_to_refresh_from() {
    let root = tmpdir("inline-update-missing");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: rust agent\nmodel: sonnet\nrole: engineer\n---\n# Rust\n",
    )
    .unwrap();

    let mut lock = LockFile::default();
    for (name, entry_source) in [
        ("dev", source.to_string_lossy().into_owned()),
        ("scout", "owner/repo".to_string()),
    ] {
        lock.add(LockEntry {
            name: name.into(),
            kind: ItemKind::Skill,
            source: entry_source,
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
    }
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let home = root.join("home");
    crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        crate::test_util::with_project_root(&project, || {
            let report = perform_inline_update(&["dev".to_string(), "scout".to_string()]);
            assert_eq!(report.completed, 0, "report: {report:?}");
            assert_eq!(report.attempted, 2, "report: {report:?}");
            assert!(
                report.failed.iter().any(|line| line.starts_with("dev:")),
                "an item with no asset in the source must be named: {report:?}"
            );
            let scout = report
                .failed
                .iter()
                .find(|line| line.starts_with("scout:"))
                .unwrap_or_else(|| panic!("scout not reported: {report:?}"));
            // This path resolves each entry's own source from the lock, so a
            // remote whose clone is not on this machine is named as exactly
            // that, with the command that fetches it.
            assert!(
                scout.contains("remote cache not present — run `vstack add owner/repo`"),
                "wrong cause reported: {scout}"
            );
        });
    });

    let _ = std::fs::remove_dir_all(root);
}

/// The hook artifact and its lock entry are gone by the time the agents are
/// regenerated, so a regeneration that cannot run must be an error: reporting
/// success left every agent carrying the removed hook.
///
/// Here one source resolves and the agent's own does not.
#[test]
fn tui_remove_hook_fails_when_the_agent_source_cannot_be_resolved() {
    let root = tmpdir("remove-hook-unresolved-source");
    let err = remove_hook_with_unresolved_sources(&root, false);
    assert!(err.contains("regenerate agents"), "{err}");
    assert!(err.contains("rust"), "{err}");
    assert!(err.contains("not regenerated"), "{err}");
    let _ = std::fs::remove_dir_all(root);
}

/// The same removal where NO source resolves at all. Source resolution falls
/// back to walking up from the process's working directory, which inside this
/// repository's own test runner finds the vstack checkout — so the empty-source
/// arm is only reachable from a process started elsewhere.
#[test]
fn tui_remove_hook_fails_when_no_source_resolves_at_all() {
    let root = tmpdir("remove-hook-no-source");
    let neutral = root.join("neutral");
    std::fs::create_dir_all(&neutral).unwrap();
    crate::test_util::run_test_helper(
        "tui::disk_mutations::tests::remove_hook_no_source_helper",
        &[("VSTACK_TEST_ROOT", root.as_os_str())],
        Some(&neutral),
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
#[ignore = "driven by tui_remove_hook_fails_when_no_source_resolves_at_all, which supplies a working directory outside any vstack source"]
fn remove_hook_no_source_helper() {
    let Some(root) = crate::test_util::helper_fixture("VSTACK_TEST_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    // Control: nothing above this process's working directory is a vstack
    // source, so resolution has nothing to fall back to.
    assert!(
        !std::env::current_dir()
            .unwrap()
            .ancestors()
            .any(crate::resolve::is_vstack_source),
        "the working directory must sit outside any vstack source"
    );
    let err = remove_hook_with_unresolved_sources(&root, true);
    assert!(
        err.contains("no source resolved for rust"),
        "the empty-source arm must name what it could not regenerate: {err}"
    );
}

/// Build a project whose agent `rust` and hook `guard` are installed, point the
/// agent's recorded source at a remote with no clone (and the hook's too when
/// `hook_source_is_remote`), then remove the hook. Returns the error.
fn remove_hook_with_unresolved_sources(root: &Path, hook_source_is_remote: bool) -> String {
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        source.join("vstack.toml"),
        "[hook-events]\n\"PreToolUse:Bash\" = \"all\"\n",
    )
    .unwrap();
    std::fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: rust agent\nmodel: sonnet\nrole: engineer\n---\n# Rust\n",
    )
    .unwrap();
    std::fs::write(
        source.join("hooks/guard.sh"),
        "# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: guard\n# ---\n#!/usr/bin/env bash\nexit 0\n",
    )
    .unwrap();

    let mut agent = agent_fixture("rust");
    agent.source_path = source.join("agents/rust.md");
    let mut hook = hook_fixture("guard", None);
    hook.source_path = source.join("hooks/guard.sh");
    hook.script = "#!/usr/bin/env bash\nexit 0\n".into();

    let hook_source = if hook_source_is_remote {
        "owner/repo".to_string()
    } else {
        source.to_string_lossy().into_owned()
    };
    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: "owner/repo".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: hook_source,
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let home = root.join("home");
    let err = crate::test_util::with_home_and_config(&home, &home.join(".config"), || {
        crate::test_util::with_project_root(&project, || {
            crate::installer::install_hook(&hook, Harness::ClaudeCode, false, &[]).unwrap();
            Harness::ClaudeCode
                .generate_agent(
                    &agent,
                    false,
                    &[],
                    &[hook.clone()],
                    &crate::agent::AgentExtras::default(),
                )
                .unwrap();

            let err = remove_one("guard", false, &mut Vec::new())
                .expect_err("removal must not report success with agents left stale");
            format!("{err:#}")
        })
    });

    // The stale frontmatter the error is about.
    let agent_body = std::fs::read_to_string(project.join(".claude/agents/rust.md")).unwrap();
    assert!(
        agent_body.contains(".claude/hooks/guard.sh"),
        "{agent_body}"
    );
    err
}

#[test]
fn inline_update_refuses_an_uncovered_event_before_pruning() {
    let root = tmpdir("inline-update-uncovered-event");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&project).unwrap();

    // The source simultaneously leaves the contract and narrows harnesses:
    // nothing — prune included — may act on a definition install refuses.
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::write(
        source.join("hooks/guard.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: Notification\n# matcher: Bash\n# harnesses: [claude-code]\n# description: guard hook\n# ---\nexit 0\n",
    )
    .unwrap();

    let mut lock = LockFile::default();
    let mut entry = hook_lock_entry("guard", &source);
    entry.harnesses = vec!["claude-code".into(), "cursor".into()];
    lock.add(entry);
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let installed = hook_fixture("guard", None);
    let rule = project.join(".cursor/rules/safety-guard.mdc");
    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&installed, Harness::ClaudeCode, false, &[]).unwrap();
        crate::installer::install_hook(&installed, Harness::Cursor, false, &[]).unwrap();
        assert!(rule.is_file(), "cursor rule was not installed");

        let report = perform_inline_update(&["guard".to_string()]);
        assert_eq!(report.completed, 0, "report: {report:?}");
        assert!(!report.failed.is_empty(), "report: {report:?}");
    });

    assert!(
        rule.is_file(),
        "the prune pass removed artifacts before the uncovered event was refused"
    );
    let lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert_eq!(
        lock.entries
            .get("guard")
            .map(|entry| entry.harnesses.clone()),
        Some(vec!["claude-code".to_string(), "cursor".to_string()]),
        "the prune pass rewrote the lock before the uncovered event was refused"
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn inline_update_of_an_agent_refuses_an_unselected_uncovered_hook() {
    let root = tmpdir("inline-update-unselected-uncovered");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&project).unwrap();

    // Regenerating an agent consumes EVERY locked hook: an unselected hook
    // whose source left the contract must refuse the update, filter or not.
    std::fs::write(
        source.join("agents").join("rust.md"),
        {
            std::fs::create_dir_all(source.join("agents")).unwrap();
            "---\nname: rust\ndescription: Rust agent\nmodel: sonnet\nrole: engineer\n---\n# Rust\n\nBody.\n"
        },
    )
    .unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::write(
        source.join("hooks/rogue.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: rogue\n# event: Notification\n# matcher: Bash\n# description: rogue hook\n# ---\nexit 0\n",
    )
    .unwrap();

    let agent = agent_fixture("rust");
    let installed_rogue = hook_fixture("rogue", None);

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(hook_lock_entry("rogue", &source));
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let agent_path = project.join(".claude/agents/rust.md");
    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&installed_rogue, Harness::ClaudeCode, false, &[]).unwrap();
        Harness::ClaudeCode
            .generate_agent(
                &agent,
                false,
                &[],
                &[installed_rogue.clone()],
                &crate::agent::AgentExtras::default(),
            )
            .unwrap();
        let before = std::fs::read_to_string(&agent_path).unwrap();

        let report = perform_inline_update(&["rust".to_string()]);
        assert!(!report.failed.is_empty(), "report: {report:?}");

        let after = std::fs::read_to_string(&agent_path).unwrap();
        assert_eq!(
            before, after,
            "the update consumed an unselected uncovered hook into the agent"
        );
    });

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn inline_update_of_a_hook_refuses_an_unselected_uncovered_hook_before_pruning() {
    let root = tmpdir("inline-update-hook-batch-uncovered");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&project).unwrap();

    // A hook batch regenerates every locked agent, which consumes every
    // locked hook — and the refusal must come before the prune pass saves
    // anything, so the selected hook's narrowed harnesses stay in the lock.
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::write(
        source.join("agents/rust.md"),
        "---\nname: rust\ndescription: Rust agent\nmodel: sonnet\nrole: engineer\n---\n# Rust\n\nBody.\n",
    )
    .unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::write(
        source.join("hooks/guard.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# harnesses: [claude-code]\n# description: guard hook\n# ---\nexit 0\n",
    )
    .unwrap();
    std::fs::write(
        source.join("hooks/rogue.sh"),
        "#!/usr/bin/env bash\n# ---\n# name: rogue\n# event: Notification\n# matcher: Bash\n# description: rogue hook\n# ---\nexit 0\n",
    )
    .unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    let mut guard_entry = hook_lock_entry("guard", &source);
    guard_entry.harnesses = vec!["claude-code".into(), "cursor".into()];
    lock.add(guard_entry);
    lock.add(hook_lock_entry("rogue", &source));
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let installed_guard = hook_fixture("guard", None);
    crate::test_util::with_project_root(&project, || {
        crate::installer::install_hook(&installed_guard, Harness::ClaudeCode, false, &[]).unwrap();
        crate::installer::install_hook(&installed_guard, Harness::Cursor, false, &[]).unwrap();

        let report = perform_inline_update(&["guard".to_string()]);
        assert!(!report.failed.is_empty(), "report: {report:?}");
    });

    let lock = LockFile::load(&project.join(".vstack-lock.json")).unwrap();
    assert_eq!(
        lock.entries
            .get("guard")
            .map(|entry| entry.harnesses.clone()),
        Some(vec!["claude-code".to_string(), "cursor".to_string()]),
        "the prune pass rewrote the lock before the unselected uncovered hook was refused"
    );

    let _ = std::fs::remove_dir_all(root);
}
