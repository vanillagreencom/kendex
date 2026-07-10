use super::*;
use crate::config::{InstallMethod, LockEntry, LockFile};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn lock_hook(name: &str, harnesses: Vec<&str>) -> LockEntry {
    lock_hook_from_source(name, "source", harnesses)
}

fn lock_hook_from_source(name: &str, source: &str, harnesses: Vec<&str>) -> LockEntry {
    LockEntry {
        name: name.into(),
        kind: ItemKind::Hook,
        source: source.into(),
        harnesses: harnesses.into_iter().map(String::from).collect(),
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    }
}

fn source_hook(name: &str, harnesses: Option<Vec<&str>>) -> Hook {
    source_hook_from_path(name, harnesses, PathBuf::new())
}

fn source_hook_from_path(name: &str, harnesses: Option<Vec<&str>>, source_path: PathBuf) -> Hook {
    Hook {
        name: name.into(),
        event: "PreToolUse".into(),
        matcher: Some("Bash".into()),
        description: String::new(),
        safety: None,
        timeout: None,
        harnesses: harnesses.map(|items| items.into_iter().map(String::from).collect()),
        script: String::new(),
        source_path,
    }
}

fn tmpdir(label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "vstack-refresh-{label}-{}-{nanos}",
        std::process::id()
    ))
}

fn make_source(root: &Path, name: &str) -> PathBuf {
    let source = root.join(name);
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("skills/shared")).unwrap();
    std::fs::create_dir_all(source.join("hooks")).unwrap();
    std::fs::create_dir_all(source.join("pi-extensions/shared")).unwrap();
    source
}

fn write_colliding_source(source: &Path, marker: &str, hook_event: &str, model: &str) {
    std::fs::write(
            source.join("vstack.toml"),
            format!(
                "[agent-skills]\nrust = [\"shared\"]\n\n[hook-events]\n\"{hook_event}:Bash\" = \"all\"\n\n[agent-frontmatter.claude]\nrust = {{ model = \"{model}\" }}\n"
            ),
        )
        .unwrap();
    std::fs::write(
            source.join("agents/rust.md"),
            format!(
                "---\nname: rust\ndescription: Rust {marker}\nmodel: sonnet\nrole: engineer\n---\n# Rust\n\nAgent body {marker}.\n"
            ),
        )
        .unwrap();
    std::fs::write(
            source.join("skills/shared/SKILL.md"),
            format!(
                "---\nname: shared\ndescription: Shared {marker}\nlicense: MIT\n---\n# Shared\n\nSkill body {marker}.\n"
            ),
        )
        .unwrap();
    std::fs::write(
            source.join("hooks/guard.sh"),
            format!(
                "# ---\n# name: guard\n# event: {hook_event}\n# matcher: Bash\n# description: Guard {marker}\n# ---\n#!/usr/bin/env bash\necho {marker}\n"
            ),
        )
        .unwrap();
    std::fs::write(
            source.join("pi-extensions/shared/package.json"),
            format!(
                "{{\n  \"name\": \"@example/shared\",\n  \"description\": \"Pi {marker}\",\n  \"version\": \"{marker}.0.0\",\n  \"keywords\": [\"pi-package\"],\n  \"pi\": {{ \"extensions\": [] }}\n}}\n"
            ),
        )
        .unwrap();
}

fn lock_entry(name: &str, kind: ItemKind, source: &Path, harnesses: Vec<&str>) -> LockEntry {
    LockEntry {
        name: name.into(),
        kind,
        source: source.to_string_lossy().into_owned(),
        harnesses: harnesses.into_iter().map(String::from).collect(),
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    }
}

#[test]
fn prune_hook_harnesses_respects_name_filter_and_removes_empty_hook_entry() {
    let mut lock = LockFile::default();
    lock.add(lock_hook("guard", vec!["pi"]));
    lock.add(lock_hook("other", vec!["pi"]));
    let hooks = vec![
        source_hook("guard", Some(vec!["codex"])),
        source_hook("other", Some(vec!["codex"])),
    ];

    assert!(prune_hook_harnesses(
        false,
        &mut lock,
        &hooks,
        Some(&["guard".to_string()]),
    ));
    assert!(!lock.entries.contains_key("guard"));
    assert_eq!(
        lock.entries
            .get("other")
            .map(|entry| entry.harnesses.as_slice()),
        Some(&["pi".to_string()][..])
    );
}

#[test]
fn prune_hook_harnesses_uses_lock_entry_source_when_names_collide() {
    let root = tmpdir("source-attribution");
    let source_a = make_source(&root, "source-a");
    let source_b = make_source(&root, "source-b");
    let mut lock = LockFile::default();
    lock.add(lock_hook_from_source(
        "guard",
        &source_b.to_string_lossy(),
        vec!["claude-code"],
    ));
    let hooks = vec![
        source_hook_from_path(
            "guard",
            Some(vec!["codex"]),
            source_a.join("hooks/guard.sh"),
        ),
        source_hook_from_path(
            "guard",
            Some(vec!["claude-code"]),
            source_b.join("hooks/guard.sh"),
        ),
    ];

    assert!(!prune_hook_harnesses(false, &mut lock, &hooks, None));
    assert_eq!(
        lock.entries
            .get("guard")
            .map(|entry| entry.harnesses.as_slice()),
        Some(&["claude-code".to_string()][..])
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn prune_hook_harnesses_keeps_codex_lock_when_cleanup_fails() {
    let root = tmpdir("codex-cleanup-failure");
    let codex_home = root.join("codex");
    std::fs::create_dir_all(codex_home.join("hooks")).unwrap();
    std::fs::write(codex_home.join("hooks/guard.sh"), "#!/usr/bin/env bash\n").unwrap();
    std::fs::write(codex_home.join("hooks.json"), "{not-json").unwrap();
    let mut lock = LockFile::default();
    lock.add(lock_hook("guard", vec!["codex"]));
    let hooks = vec![source_hook("guard", Some(vec!["pi"]))];

    crate::test_util::with_codex_home(&codex_home, || {
        assert!(!prune_hook_harnesses(true, &mut lock, &hooks, None));
    });
    assert_eq!(
        lock.entries
            .get("guard")
            .map(|entry| entry.harnesses.as_slice()),
        Some(&["codex".to_string()][..])
    );
    assert!(codex_home.join("hooks.json").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn prune_hook_harnesses_keeps_lock_when_hook_name_is_unsafe() {
    let mut lock = LockFile::default();
    lock.add(lock_hook("../victim", vec!["codex"]));
    let hooks = vec![source_hook("../victim", Some(vec!["pi"]))];

    assert!(!prune_hook_harnesses(true, &mut lock, &hooks, None));
    assert_eq!(
        lock.entries
            .get("../victim")
            .map(|entry| entry.harnesses.as_slice()),
        Some(&["codex".to_string()][..])
    );
}

#[test]
fn refresh_items_use_lock_source_for_colliding_names_and_mapping() {
    let root = tmpdir("multi-source-refresh");
    let project = root.join("project");
    let source_a = make_source(&root, "source-a");
    let source_b = make_source(&root, "source-b");
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&source_a, "1", "PreToolUse", "source-a-model");
    write_colliding_source(&source_b, "2", "PostCompact", "source-b-model");

    let mut lock = LockFile::default();
    lock.add(lock_entry(
        "rust",
        ItemKind::Agent,
        &source_b,
        vec!["claude-code"],
    ));
    lock.add(lock_entry(
        "shared",
        ItemKind::Skill,
        &source_b,
        vec!["claude-code"],
    ));
    lock.add(lock_entry(
        "guard",
        ItemKind::Hook,
        &source_b,
        vec!["claude-code"],
    ));
    lock.add(lock_entry(
        "@example/shared",
        ItemKind::PiExtension,
        &source_b,
        vec!["pi"],
    ));

    let sources = vec![
        RefreshSource::from_root(&source_a),
        RefreshSource::from_root(&source_b),
    ];

    crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        let stats =
            refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
        assert_eq!(stats.agents_refreshed, 1);
        assert_eq!(stats.skills_refreshed, 1);
        assert_eq!(stats.hooks_refreshed, 1);
        assert_eq!(stats.pi_refreshed, 1);
    });

    let agent = std::fs::read_to_string(project.join(".claude/agents/rust.md")).unwrap();
    assert!(
        agent.contains("model: source-b-model"),
        "wrong mapping: {agent}"
    );
    assert!(
        agent.contains("Agent body 2."),
        "wrong agent source: {agent}"
    );
    assert!(
        agent.contains("skills: shared"),
        "missing source skill mapping: {agent}"
    );
    assert!(
        agent.contains("PostCompact") && !agent.contains("PreToolUse"),
        "wrong hook mapping/source: {agent}"
    );

    let skill = std::fs::read_to_string(project.join(".claude/skills/shared/SKILL.md")).unwrap();
    assert!(
        skill.contains("Skill body 2."),
        "wrong skill source: {skill}"
    );

    let settings = std::fs::read_to_string(project.join(".claude/settings.json")).unwrap();
    assert!(
        settings.contains("PostCompact") && !settings.contains("PreToolUse"),
        "wrong hook settings: {settings}"
    );

    let package =
        std::fs::read_to_string(project.join(".pi/packages/@example/shared/package.json")).unwrap();
    assert!(package.contains("Pi 2"), "wrong Pi source: {package}");

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_counts_content_changes_when_source_hashes_are_unchanged() {
    // Regression for the "0 updated" summary bug: a refresh that re-renders
    // agent and skill output (via injected project instructions) must be
    // counted as updated even though neither item's SOURCE hash changed.
    let root = tmpdir("content-change-count");
    let project = root.join("project");
    let source = make_source(&root, "source");
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&source, "1", "PreToolUse", "model-x");

    let mut lock = LockFile::default();
    lock.add(lock_entry("rust", ItemKind::Agent, &source, vec!["claude-code"]));
    lock.add(lock_entry(
        "shared",
        ItemKind::Skill,
        &source,
        vec!["claude-code"],
    ));
    let sources = vec![RefreshSource::from_root(&source)];

    let agent_path = project.join(".claude/agents/rust.md");
    let skill_path = project.join(".claude/skills/shared/SKILL.md");

    crate::test_util::with_project_root(&project, || {
        // First refresh: baseline install, no project instructions.
        let mut project_config = ProjectConfig::default();
        let first =
            refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
        assert_eq!(first.agents_refreshed, 1);
        assert_eq!(first.skills_refreshed, 1);

        let agent_before = std::fs::read_to_string(&agent_path).unwrap();
        let skill_before = std::fs::read_to_string(&skill_path).unwrap();

        // Source hashes as recorded after the baseline install. These must NOT
        // change across the second refresh — that is the whole point: the old
        // summary derived "updated" from these alone and reported 0.
        let agent_hash_before = crate::config::compute_source_hash(&lock.entries["rust"]);
        let skill_hash_before = crate::config::compute_source_hash(&lock.entries["shared"]);

        // Inject project-level instructions in memory only (never written to
        // the on-disk vstack.toml that source hashing reads). This re-renders
        // both the agent file and the skill's SKILL.md.
        project_config
            .agent_instructions
            .insert("rust".into(), "Extra project guidance for rust.".into());
        project_config
            .skill_instructions
            .insert("shared".into(), "Project-specific skill note.".into());

        let second =
            refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);

        // The generated artifacts actually changed on disk.
        let agent_after = std::fs::read_to_string(&agent_path).unwrap();
        let skill_after = std::fs::read_to_string(&skill_path).unwrap();
        assert_ne!(agent_before, agent_after, "agent file should have changed");
        assert_ne!(skill_before, skill_after, "skill file should have changed");

        // Source hashes are unchanged, so the old (source-hash-only) counting
        // would have reported 0 updated for both kinds.
        let agent_hash_after = crate::config::compute_source_hash(&lock.entries["rust"]);
        let skill_hash_after = crate::config::compute_source_hash(&lock.entries["shared"]);
        assert_eq!(
            agent_hash_before, agent_hash_after,
            "agent source hash must be unchanged"
        );
        assert_eq!(
            skill_hash_before, skill_hash_after,
            "skill source hash must be unchanged"
        );

        // The content-change signal that now feeds the "N updated" counters
        // reflects the real on-disk writes.
        assert!(
            second.content_changed.contains("rust"),
            "agent content change not tracked: {:?}",
            second.content_changed
        );
        assert!(
            second.content_changed.contains("shared"),
            "skill content change not tracked: {:?}",
            second.content_changed
        );
        assert_eq!(second.agents_refreshed, 1);
        assert_eq!(second.skills_refreshed, 1);
    });

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_reports_no_content_change_on_idempotent_refresh() {
    // The inverse guarantee: refreshing twice with no source or config change
    // must report nothing updated (empty content_changed set).
    let root = tmpdir("content-change-idempotent");
    let project = root.join("project");
    let source = make_source(&root, "source");
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&source, "1", "PreToolUse", "model-x");

    let mut lock = LockFile::default();
    lock.add(lock_entry("rust", ItemKind::Agent, &source, vec!["claude-code"]));
    lock.add(lock_entry(
        "shared",
        ItemKind::Skill,
        &source,
        vec!["claude-code"],
    ));
    let sources = vec![RefreshSource::from_root(&source)];

    crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        // Prime the install once.
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
        // Second refresh with identical inputs must detect no content change.
        let again =
            refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
        assert!(
            again.content_changed.is_empty(),
            "idempotent refresh reported content changes: {:?}",
            again.content_changed
        );
    });

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_items_reports_agent_write_failure_without_success() {
    let root = tmpdir("agent-write-failure");
    let project = root.join("project");
    let source = make_source(&root, "source");
    std::fs::create_dir_all(project.join(".codex")).unwrap();
    std::fs::write(project.join(".codex/agents"), "not a directory").unwrap();
    write_colliding_source(&source, "1", "PreToolUse", "source-model");

    let mut lock = LockFile::default();
    lock.add(lock_entry("rust", ItemKind::Agent, &source, vec!["codex"]));
    let sources = vec![RefreshSource::from_root(&source)];

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None)
    });

    assert_eq!(stats.agents_refreshed, 0);
    assert!(!stats.successful_items.contains("rust"));
    assert_eq!(stats.failures.len(), 1);
    assert_eq!(stats.failures[0].item, "rust");
    assert_eq!(stats.failures[0].harness.as_deref(), Some("Codex"));

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_rejects_agent_name_that_escapes_output_dir() {
    let root = tmpdir("agent-name-traversal");
    let project = root.join("project");
    let source = make_source(&root, "source");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(
        source.join("agents/evil.md"),
        "---\nname: \"../../pwned\"\ndescription: Evil\nmodel: sonnet\nrole: engineer\n---\n# Evil\n",
    )
    .unwrap();

    let mut lock = LockFile::default();
    lock.add(lock_entry(
        "../../pwned",
        ItemKind::Agent,
        &source,
        vec!["claude-code", "codex"],
    ));
    let sources = vec![RefreshSource::from_root(&source)];

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None)
    });

    assert_eq!(stats.agents_refreshed, 0);
    assert!(!stats.successful_items.contains("../../pwned"));
    assert_eq!(stats.failures.len(), 1);
    assert_eq!(stats.failures[0].item, "../../pwned");
    assert!(stats.failures[0].error.contains("invalid agent name"));
    assert!(!project.join("pwned.md").exists());
    assert!(!project.join("pwned.toml").exists());
    assert!(!project.join(".claude/pwned.md").exists());
    assert!(!project.join(".codex/config.toml").exists());

    let _ = std::fs::remove_dir_all(root);
}
