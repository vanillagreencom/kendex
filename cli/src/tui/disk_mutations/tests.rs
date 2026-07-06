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
