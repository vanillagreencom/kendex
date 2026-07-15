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
    lock.add(lock_entry(
        "rust",
        ItemKind::Agent,
        &source,
        vec!["claude-code"],
    ));
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
    lock.add(lock_entry(
        "rust",
        ItemKind::Agent,
        &source,
        vec!["claude-code"],
    ));
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
fn refresh_manages_project_owned_skill_instructions_without_a_lock_entry() {
    let root = tmpdir("project-owned-skill-instructions");
    let project = root.join("project");
    let benchmark_dir = project.join(".agents/skills/benchmark");
    let unrelated_dir = project.join(".agents/skills/unrelated");
    std::fs::create_dir_all(&benchmark_dir).unwrap();
    std::fs::create_dir_all(&unrelated_dir).unwrap();
    std::fs::create_dir_all(project.join(".opencode")).unwrap();

    let original = "---\nname: benchmark\ndescription: Local benchmark\n---\n\n# Benchmark\n\nOriginal body.\n\n## Existing Section\n\nKeep this.\n";
    let unrelated = "---\nname: unrelated\ndescription: Local unrelated\n---\n\n# Unrelated\n\n## Project Instructions\n\nAuthored locally; do not rewrite.\n";
    let unrelated_config = "{\n  \"sentinel\": true\n}\n";
    let benchmark_path = benchmark_dir.join("SKILL.md");
    let unrelated_path = unrelated_dir.join("SKILL.md");
    let unrelated_config_path = project.join(".opencode/opencode.json");
    std::fs::write(&benchmark_path, original).unwrap();
    std::fs::write(&unrelated_path, unrelated).unwrap();
    std::fs::write(&unrelated_config_path, unrelated_config).unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig::default();
    project_config
        .skill_instructions
        .insert("benchmark".into(), "First project rule.".into());
    project_config
        .skill_instructions
        .insert("unrelated".into(), "   ".into());

    let first = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    let first_content = std::fs::read_to_string(&benchmark_path).unwrap();
    assert!(first.project_owned_skills.contains("benchmark"));
    assert!(first.content_changed.contains("benchmark"));
    assert!(first_content.contains("## Project Instructions\n\nFirst project rule."));
    assert!(first_content.contains("# Benchmark\n\nOriginal body."));
    assert_eq!(first_content.matches("## Project Instructions").count(), 1);
    assert_eq!(std::fs::read_to_string(&unrelated_path).unwrap(), unrelated);
    assert_eq!(
        std::fs::read_to_string(&unrelated_config_path).unwrap(),
        unrelated_config
    );

    let again = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(again.project_owned_skills.contains("benchmark"));
    let again_content = std::fs::read_to_string(&benchmark_path).unwrap();
    assert_eq!(again_content, first_content);
    assert!(
        again.content_changed.is_empty(),
        "idempotent project-owned refresh reported changes: {:?}",
        again.content_changed
    );

    project_config
        .skill_instructions
        .insert("benchmark".into(), "Updated project rule.".into());
    let updated =
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    let updated_content = std::fs::read_to_string(&benchmark_path).unwrap();
    assert!(updated.content_changed.contains("benchmark"));
    assert!(updated_content.contains("Updated project rule."));
    assert!(!updated_content.contains("First project rule."));
    assert!(updated_content.contains("## Existing Section\n\nKeep this."));
    assert_eq!(
        updated_content.matches("## Project Instructions").count(),
        1
    );

    project_config.skill_instructions.remove("benchmark");
    let removed =
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(removed.content_changed.contains("benchmark"));
    assert_eq!(std::fs::read_to_string(&benchmark_path).unwrap(), original);

    let removed_again =
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(removed_again.project_owned_skills.is_empty());
    assert!(removed_again.content_changed.is_empty());
    assert_eq!(std::fs::read_to_string(&unrelated_path).unwrap(), unrelated);
    assert_eq!(
        std::fs::read_to_string(&unrelated_config_path).unwrap(),
        unrelated_config
    );

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_command_applies_project_owned_skill_instructions_without_creating_a_lock() {
    let root = tmpdir("project-owned-command-no-lock");
    let project = root.join("project");
    let skill_dir = project.join(".agents/skills/benchmark");
    std::fs::create_dir_all(&skill_dir).unwrap();
    let skill_path = skill_dir.join("SKILL.md");
    let original = "---\nname: benchmark\ndescription: Local benchmark\n---\n\n# Benchmark\n\nOriginal body.\n";
    let project_config = "# Preserve this comment and formatting.\n\n[skill-instructions]\nbenchmark = \"Run only on the designated benchmark host.\"\n";
    std::fs::write(&skill_path, original).unwrap();
    std::fs::write(project.join("vstack.toml"), project_config).unwrap();

    crate::test_util::with_project_root(&project, || {
        run(crate::scope::ScopeFilter::Project, false).unwrap();
    });

    let refreshed = std::fs::read_to_string(&skill_path).unwrap();
    assert!(refreshed.contains("Run only on the designated benchmark host."));
    assert!(refreshed.contains("# Benchmark\n\nOriginal body."));
    assert_eq!(
        std::fs::read_to_string(project.join("vstack.toml")).unwrap(),
        project_config,
        "refresh must not normalize unrelated project config"
    );
    assert!(
        !project.join(".vstack-lock.json").exists(),
        "project-owned instruction refresh must not invent lock ownership"
    );

    let once = refreshed;
    crate::test_util::with_project_root(&project, || {
        run(crate::scope::ScopeFilter::Project, false).unwrap();
    });
    assert_eq!(std::fs::read_to_string(&skill_path).unwrap(), once);
    assert!(!project.join(".vstack-lock.json").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_command_rejects_malformed_config_without_modifying_project_owned_skill() {
    let root = tmpdir("project-owned-malformed-config");
    let project = root.join("project");
    let skill_dir = project.join(".agents/skills/benchmark");
    std::fs::create_dir_all(&skill_dir).unwrap();
    let skill_path = skill_dir.join("SKILL.md");
    let original = b"---\nname: benchmark\ndescription: Local benchmark\n---\n\n<!-- vstack:project-instructions:start -->\n## Project Instructions\n\nKeep this rule.\n<!-- vstack:project-instructions:end -->\n\n# Benchmark\n\nOriginal body.\n";
    std::fs::write(&skill_path, original).unwrap();
    std::fs::write(
        project.join("vstack.toml"),
        "[skill-instructions\nbenchmark = \"broken\"\n",
    )
    .unwrap();

    let err = crate::test_util::with_project_root(&project, || {
        run(crate::scope::ScopeFilter::Project, false).unwrap_err()
    });

    assert!(err.to_string().contains("parsing"), "{err:#}");
    assert_eq!(std::fs::read(&skill_path).unwrap(), original);
    assert!(!project.join(".vstack-lock.json").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn refresh_command_rejects_unreadable_config_without_modifying_project_owned_skill() {
    let root = tmpdir("project-owned-unreadable-config");
    let project = root.join("project");
    let skill_dir = project.join(".agents/skills/benchmark");
    std::fs::create_dir_all(&skill_dir).unwrap();
    std::fs::create_dir(project.join("vstack.toml")).unwrap();
    let skill_path = skill_dir.join("SKILL.md");
    let original = b"---\nname: benchmark\ndescription: Local benchmark\n---\n\n<!-- vstack:project-instructions:start -->\n## Project Instructions\n\nKeep this rule.\n<!-- vstack:project-instructions:end -->\n\n# Benchmark\n\nOriginal body.\n";
    std::fs::write(&skill_path, original).unwrap();

    let err = crate::test_util::with_project_root(&project, || {
        run(crate::scope::ScopeFilter::Project, false).unwrap_err()
    });

    assert!(err.to_string().contains("reading"), "{err:#}");
    assert_eq!(std::fs::read(&skill_path).unwrap(), original);
    assert!(!project.join(".vstack-lock.json").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn refresh_rejects_symlinked_agents_ancestor_before_reading_outside_skill() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("project-owned-symlinked-agents");
    let project = root.join("project");
    let outside_agents = root.join("outside-agents");
    let outside_skill_dir = outside_agents.join("skills/benchmark");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&outside_skill_dir).unwrap();
    symlink(&outside_agents, project.join(".agents")).unwrap();
    std::fs::write(
        project.join("vstack.toml"),
        "[skill-instructions]\nbenchmark = \"Do not escape.\"\n",
    )
    .unwrap();
    let outside_skill = outside_skill_dir.join("SKILL.md");
    let outside_bytes = [0xff, 0xfe, 0xfd, b'\n'];
    std::fs::write(&outside_skill, outside_bytes).unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig::load_strict(&project).unwrap();
    let stats = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);

    assert_eq!(stats.failures.len(), 1);
    assert_eq!(stats.failures[0].item, ".agents/skills");
    assert!(stats.failures[0].error.contains("outside project root"));
    assert!(stats.project_owned_skills.is_empty());
    assert_eq!(std::fs::read(&outside_skill).unwrap(), outside_bytes);

    let err = crate::test_util::with_project_root(&project, || {
        run(crate::scope::ScopeFilter::Project, false).unwrap_err()
    });
    assert!(err.to_string().contains("failed to refresh"), "{err:#}");
    assert_eq!(std::fs::read(&outside_skill).unwrap(), outside_bytes);
    assert!(!project.join(".vstack-lock.json").exists());

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
