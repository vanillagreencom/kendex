use super::*;
use crate::agent::{Agent, AgentRole};
use crate::config::{InstallMethod, LockEntry, LockFile};
use crate::mapping::{HookTarget, MappingConfig};
use std::path::PathBuf;

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

#[test]
fn inline_update_refreshes_hook_config_and_agents() {
    let root = tmpdir("inline-update-hook");
    let project = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        source.join("vstack.toml"),
        "[hook-events]\n\"PostCompact:\" = \"all\"\n",
    )
    .unwrap();

    let mut agent = agent_fixture("rust");
    agent.source_path = source.join("agents/rust.md");
    let mut old_hook = hook_fixture("guard", None);
    old_hook.source_path = source.join("hooks/guard.sh");
    old_hook.script = "#!/usr/bin/env bash\nexit 0\n".into();
    let mut new_hook = old_hook.clone();
    new_hook.event = "PostCompact".into();
    new_hook.matcher = None;

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "rust".into(),
        kind: ItemKind::Agent,
        source: source.to_string_lossy().into_owned(),
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: source.to_string_lossy().into_owned(),
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let items = DiscoveredItems {
        agents: vec![agent.clone()],
        skills: Vec::new(),
        hooks: vec![new_hook],
        pi_extensions: Vec::new(),
        extras: Vec::new(),
    };

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

        let report = perform_inline_update(&["guard".to_string()], &items);
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
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: source.to_string_lossy().into_owned(),
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

        assert!(remove_one("guard", false).unwrap());
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
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-15T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.add(LockEntry {
        name: "guard".into(),
        kind: ItemKind::Hook,
        source: source.to_string_lossy().into_owned(),
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
