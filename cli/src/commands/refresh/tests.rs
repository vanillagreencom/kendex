use super::*;
use crate::config::{InstallMethod, LockEntry, LockFile};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn lock_hook(name: &str, harnesses: Vec<&str>) -> LockEntry {
    lock_hook_from_source(name, "source", harnesses)
}

fn lock_hook_from_source(name: &str, source: &str, harnesses: Vec<&str>) -> LockEntry {
    LockEntry {
        name: name.into(),
        kind: ItemKind::Hook,
        source: source.into(),
        source_repo: None,
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

/// Run a git command in `dir`, reporting only whether it succeeded. Tests that
/// need a real repository skip themselves when git is unavailable rather than
/// failing a host that simply has no git.
fn git_ok(dir: &Path, args: &[&str]) -> bool {
    std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

fn init_repo_with_commit(dir: &Path) -> bool {
    git_ok(dir, &["init", "-q", "-b", "main"])
        && git_ok(dir, &["config", "user.email", "test@example.com"])
        && git_ok(dir, &["config", "user.name", "Test"])
        && git_ok(dir, &["config", "commit.gpgsign", "false"])
        && std::fs::write(dir.join(".vstack-test-base"), "base\n").is_ok()
        && git_ok(dir, &["add", "-A"])
        && git_ok(dir, &["commit", "-q", "-m", "base"])
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
        source_repo: None,
        harnesses: harnesses.into_iter().map(String::from).collect(),
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    }
}

#[test]
fn source_repo_for_lock_entry_uses_resolved_source_record_identity() {
    let root = tmpdir("refresh-source-repo");
    let source = root.join("source");
    std::fs::create_dir_all(&source).unwrap();
    let entry = lock_entry(
        "rust",
        ItemKind::Agent,
        Path::new("/moved/source"),
        vec!["codex"],
    );
    let records = vec![crate::refresh_sources::ResolvedSource {
        root: source,
        aliases: vec!["/moved/source".to_string()],
        source_repo: Some("vanillagreencom/vstack".to_string()),
    }];

    assert_eq!(
        observed_source_repo_for_lock_entry(&records, &entry)
            .flatten()
            .as_deref(),
        Some("vanillagreencom/vstack")
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn sync_lock_entry_source_repo_clears_stale_identity_for_resolved_local_source_without_origin() {
    let root = tmpdir("refresh-source-repo-clear-stale");
    let source = make_source(&root, "local-source");
    let mut entry = lock_entry("rust", ItemKind::Agent, &source, vec!["codex"]);
    entry.source_repo = Some("vanillagreencom/vstack".to_string());

    sync_lock_entry_source_repo(&[], &mut entry);

    assert_eq!(entry.source_repo, None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn sync_lock_entry_source_repo_clears_stale_identity_for_resolved_record_without_identity() {
    let root = tmpdir("refresh-source-repo-clear-record");
    let source = make_source(&root, "local-source");
    let mut entry = lock_entry(
        "rust",
        ItemKind::Agent,
        Path::new("/moved/source"),
        vec!["codex"],
    );
    entry.source_repo = Some("vanillagreencom/vstack".to_string());
    let records = vec![crate::refresh_sources::ResolvedSource {
        root: source,
        aliases: vec!["/moved/source".to_string()],
        source_repo: None,
    }];

    sync_lock_entry_source_repo(&records, &mut entry);

    assert_eq!(entry.source_repo, None);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn sync_lock_entry_source_repo_preserves_identity_when_source_unavailable() {
    let root = tmpdir("refresh-source-repo-preserve-moved");
    let source = root.join("moved-source");
    let mut entry = lock_entry("rust", ItemKind::Agent, &source, vec!["codex"]);
    entry.source_repo = Some("vanillagreencom/vstack".to_string());

    sync_lock_entry_source_repo(&[], &mut entry);

    assert_eq!(entry.source_repo.as_deref(), Some("vanillagreencom/vstack"));
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
    assert!(err.to_string().contains("outside project root"), "{err:#}");
    assert_eq!(std::fs::read(&outside_skill).unwrap(), outside_bytes);
    assert!(!project.join(".vstack-lock.json").exists());

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn refresh_accepts_agents_symlink_into_a_sibling_worktree_of_the_same_repo() {
    use std::os::unix::fs::symlink;

    // vstack's own `worktree` skill provisions exactly this layout: an issue
    // worktree's `.agents` is a symlink into the main checkout, so a large
    // harness library is shared instead of copied per branch. The lexical
    // containment test refused it, which made refresh unusable from any
    // worktree (vstack#886).
    let root = tmpdir("project-owned-sibling-worktree");
    let main = root.join("main");
    let trees = root.join("trees");
    std::fs::create_dir_all(main.join(".agents/skills/benchmark")).unwrap();
    std::fs::create_dir_all(&trees).unwrap();
    if !init_repo_with_commit(&main) {
        let _ = std::fs::remove_dir_all(root);
        return;
    }
    let worktree = trees.join("issue-1");
    if !git_ok(&main, &["worktree", "add", "-q", "-b", "issue-1", worktree.to_str().unwrap()]) {
        let _ = std::fs::remove_dir_all(root);
        return;
    }
    // The worktree's `.agents` resolves into the main checkout — never a path
    // prefix of the worktree root.
    let _ = std::fs::remove_dir_all(worktree.join(".agents"));
    symlink(main.join(".agents"), worktree.join(".agents")).unwrap();
    std::fs::write(
        worktree.join("vstack.toml"),
        "[skill-instructions]\nbenchmark = \"Project instruction.\"\n",
    )
    .unwrap();
    std::fs::write(
        main.join(".agents/skills/benchmark/SKILL.md"),
        "---\nname: benchmark\ndescription: Project owned\n---\n\nBody.\n",
    )
    .unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig::load_strict(&worktree).unwrap();
    let stats =
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &worktree, None);

    assert!(
        stats.failures.is_empty(),
        "a same-repository worktree symlink must not fail refresh: {:?}",
        stats.failures
    );
    assert!(
        stats.project_owned_skills.contains("benchmark"),
        "the shared project-owned skill should be managed, got {:?}",
        stats.project_owned_skills
    );

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn refresh_still_rejects_agents_symlink_into_a_different_repository() {
    use std::os::unix::fs::symlink;

    // The same-repository escape hatch is proof of identity, not a blanket
    // "any git repo will do". A DIFFERENT repository has a different
    // --git-common-dir and must still fail closed, exactly as a bare directory
    // does (vstack#886).
    let root = tmpdir("project-owned-foreign-repo");
    let project = root.join("project");
    let foreign = root.join("foreign");
    let foreign_skill_dir = foreign.join(".agents/skills/benchmark");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&foreign_skill_dir).unwrap();
    if !init_repo_with_commit(&project) || !init_repo_with_commit(&foreign) {
        let _ = std::fs::remove_dir_all(root);
        return;
    }
    symlink(foreign.join(".agents"), project.join(".agents")).unwrap();
    std::fs::write(
        project.join("vstack.toml"),
        "[skill-instructions]\nbenchmark = \"Do not escape.\"\n",
    )
    .unwrap();
    let foreign_skill = foreign_skill_dir.join("SKILL.md");
    let foreign_bytes = b"---\nname: benchmark\ndescription: Foreign\n---\n\nUntouched.\n";
    std::fs::write(&foreign_skill, foreign_bytes).unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig::load_strict(&project).unwrap();
    let stats = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);

    assert_eq!(stats.failures.len(), 1);
    assert_eq!(stats.failures[0].item, ".agents/skills");
    assert!(stats.failures[0].error.contains("outside project root"));
    assert!(stats.project_owned_skills.is_empty());
    assert_eq!(std::fs::read(&foreign_skill).unwrap(), foreign_bytes);

    let _ = std::fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn refresh_preflight_keeps_populated_lock_and_outside_skill_byte_identical() {
    use std::os::unix::fs::symlink;

    let root = tmpdir("project-owned-populated-lock-escape");
    let project = root.join("project");
    let source = make_source(&root, "source");
    let outside_agents = root.join("outside-agents");
    let outside_skill_dir = outside_agents.join("skills/benchmark");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&outside_skill_dir).unwrap();
    symlink(&outside_agents, project.join(".agents")).unwrap();
    std::fs::write(project.join("vstack.toml"), "[skill-instructions]\n").unwrap();

    let outside_skill = outside_skill_dir.join("SKILL.md");
    let outside_bytes = b"---\nname: benchmark\ndescription: Outside\n---\n\nKeep outside bytes.\n";
    std::fs::write(&outside_skill, outside_bytes).unwrap();
    std::fs::create_dir_all(source.join("skills/benchmark")).unwrap();
    std::fs::write(
        source.join("skills/benchmark/SKILL.md"),
        "---\nname: benchmark\ndescription: Source\n---\n\nReplacement bytes.\n",
    )
    .unwrap();

    let mut lock = LockFile::default();
    lock.add(lock_entry(
        "benchmark",
        ItemKind::Skill,
        &source,
        vec!["codex"],
    ));
    let lock_path = project.join(".vstack-lock.json");
    lock.save(&lock_path).unwrap();
    let lock_bytes = std::fs::read(&lock_path).unwrap();

    let err = crate::test_util::with_project_root(&project, || {
        run(crate::scope::ScopeFilter::Project, false).unwrap_err()
    });

    assert!(err.to_string().contains("outside project root"), "{err:#}");
    assert_eq!(std::fs::read(&outside_skill).unwrap(), outside_bytes);
    assert_eq!(std::fs::read(&lock_path).unwrap(), lock_bytes);
    assert!(!project.join(".codex/config.toml").exists());

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

/// Anti-masking regression: an entry whose source no longer carries the asset
/// used to be skipped silently, after which the report echoed the stored hash
/// as `<hash> → <hash> (unchanged)` and refresh exited 0. Edits that never
/// propagated were indistinguishable from a genuinely up-to-date install.
#[test]
fn refresh_reports_items_missing_from_their_source_instead_of_skipping() {
    let root = tmpdir("missing-from-source");
    let project = root.join("project");
    let source = make_source(&root, "source");
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&source, "1", "PreToolUse", "source-model");

    let mut lock = LockFile::default();
    // Locked, but absent from the source: nothing to refresh from.
    lock.add(lock_entry(
        "gone",
        ItemKind::Skill,
        &source,
        vec!["claude-code"],
    ));
    lock.add(lock_entry(
        "vanished",
        ItemKind::Agent,
        &source,
        vec!["claude-code"],
    ));
    // Present in the source: must still refresh normally alongside them.
    lock.add(lock_entry(
        "shared",
        ItemKind::Skill,
        &source,
        vec!["claude-code"],
    ));
    let sources = vec![RefreshSource::from_root(&source)];

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None)
    });

    assert!(stats.has_missing());
    assert_eq!(
        stats.missing.keys().cloned().collect::<Vec<_>>(),
        vec!["gone".to_string(), "vanished".to_string()]
    );
    for name in ["gone", "vanished"] {
        assert!(
            stats.missing[name].contains(&source.display().to_string()),
            "missing reason must name the resolved source: {}",
            stats.missing[name]
        );
        assert!(
            !stats.successful_items.contains(name),
            "{name} must not count as refreshed"
        );
    }
    assert_eq!(stats.skills_refreshed, 1);
    assert!(stats.successful_items.contains("shared"));

    let _ = std::fs::remove_dir_all(root);
}

/// VST-134: an entry whose harness list yields no installable harness (empty,
/// or ids this binary does not recognize) used to fall through its refresh pass
/// silently — no success, no failure, no missing. `run_one` then echoed the
/// recorded source hash as both old and new and printed "(unchanged)" while the
/// installed bytes stayed stale after the source advanced. Field signature:
/// `review-gate c9df07f6 → c9df07f6 (unchanged)` in a fresh consumer worktree
/// whose copied lock carried such an entry, with the cache already fast-forwarded.
/// "Unchanged" must mean bytes-identical to the resolved source; an entry that
/// cannot be re-copied must fail loudly instead.
#[test]
fn refresh_fails_loud_when_a_lock_entry_yields_no_harness_install() {
    let root = tmpdir("no-installable-harness");
    let project = root.join("project");
    let source = make_source(&root, "source");
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&source, "2", "PreToolUse", "source-model");

    let mut lock = LockFile::default();
    // The repro shape: empty harness list on a skill (seen in the wild from the
    // pre-#1047 apply lock bug, carried into a fresh worktree by the lock copy).
    lock.add(lock_entry("shared", ItemKind::Skill, &source, vec![]));
    // Unrecognized harness ids are the same silent no-op for agents and hooks.
    lock.add(lock_entry(
        "rust",
        ItemKind::Agent,
        &source,
        vec!["not-a-harness"],
    ));
    lock.add(lock_entry(
        "guard",
        ItemKind::Hook,
        &source,
        vec!["not-a-harness"],
    ));
    let sources = vec![RefreshSource::from_root(&source)];

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None)
    });

    assert!(
        stats.has_failures(),
        "zero-install entries must fail loudly, not disappear from the report"
    );
    for name in ["shared", "rust", "guard"] {
        assert!(
            stats.failures.iter().any(|failure| failure.item == name),
            "{name} must be reported as a failure: {:?}",
            stats.failures
        );
        assert!(
            !stats.successful_items.contains(name),
            "{name} must not count as refreshed"
        );
    }
    assert_eq!(stats.skills_refreshed, 0);
    assert_eq!(stats.agents_refreshed, 0);
    assert_eq!(stats.hooks_refreshed, 0);

    let _ = std::fs::remove_dir_all(root);
}

/// Caller-level companion to the test above for the hook shape: production
/// callers (`run_one`, the TUI) run [`prune_hook_harnesses`] before the
/// refresh passes, and pruning used to DELETE a hook entry whose harness list
/// was already empty on arrival — silently unmanaging the bug-shaped entry
/// (VST-134) before the loud-failure guard could ever see it. Pruning must
/// only drop an entry it emptied itself (a completed allowlist self-heal);
/// an arrived-empty entry stays in the lock and fails the refresh pass.
#[test]
fn prune_preserves_arrived_empty_hook_entry_for_loud_refresh_failure() {
    let root = tmpdir("arrived-empty-hook");
    let project = root.join("project");
    let source = make_source(&root, "source");
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&source, "2", "PreToolUse", "source-model");

    let mut lock = LockFile::default();
    lock.add(lock_entry("guard", ItemKind::Hook, &source, vec![]));
    let sources = vec![RefreshSource::from_root(&source)];
    let source_hooks = all_source_hooks(&sources);

    // run_one ordering: prune first, then the refresh passes.
    assert!(
        !prune_hook_harnesses(false, &mut lock, &source_hooks, None),
        "an arrived-empty entry was not pruned by this run and must not count as pruned"
    );
    assert!(
        lock.entries.contains_key("guard"),
        "pruning must not silently unmanage an arrived-empty hook entry"
    );

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None)
    });
    assert!(
        stats.failures.iter().any(|failure| failure.item == "guard"),
        "the surviving entry must fail the refresh pass loudly: {:?}",
        stats.failures
    );
    assert_eq!(stats.hooks_refreshed, 0);

    let _ = std::fs::remove_dir_all(root);
}

/// An entry emptied SOLELY by shedding unrecognized harness ids had no
/// uninstall run for it — deleting it from the lock would silently unmanage a
/// possibly-stale install with no cleanup ever attempted. It must survive
/// pruning (with an empty list) so the refresh pass fails it loudly; only a
/// completed self-heal (a recognized harness actually uninstalled) may drop
/// the entry.
#[test]
fn prune_keeps_hook_entry_emptied_only_by_unrecognized_ids() {
    let mut lock = LockFile::default();
    lock.add(lock_hook("guard", vec!["not-a-harness"]));
    let hooks = vec![source_hook("guard", Some(vec!["codex"]))];

    assert!(prune_hook_harnesses(false, &mut lock, &hooks, None));
    let entry = lock
        .entries
        .get("guard")
        .expect("entry emptied without any uninstall must stay in the lock");
    assert!(
        entry.harnesses.is_empty(),
        "the unrecognized id itself is still shed from the list"
    );
}

/// The single-source fallback must not silently reinstall an entry from a
/// source it was never installed from — it reports missing instead.
#[test]
fn refresh_reports_missing_when_the_recorded_source_is_not_loaded() {
    let root = tmpdir("unloaded-source");
    let project = root.join("project");
    let loaded = make_source(&root, "loaded");
    let alternate = root.join(".agents");
    std::fs::create_dir_all(alternate.join("skills/shared")).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    write_colliding_source(&loaded, "1", "PreToolUse", "source-model");

    let mut lock = LockFile::default();
    lock.add(lock_entry(
        "shared",
        ItemKind::Skill,
        &alternate,
        vec!["claude-code"],
    ));
    let sources = vec![RefreshSource::from_root(&loaded)];

    let stats = crate::test_util::with_project_root(&project, || {
        let mut project_config = ProjectConfig::default();
        refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None)
    });

    assert_eq!(stats.skills_refreshed, 0);
    assert_eq!(
        stats.missing.get("shared").map(String::as_str),
        Some("source not found")
    );
    assert!(
        !project.join(".claude/skills/shared/SKILL.md").exists(),
        "must not install from a source the entry was never installed from"
    );

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

/// #859: project-owned skills relocated OUT of `.agents` and linked back in.
///
/// The convention exists to keep `.agents` free of tracked content: a project
/// that commits skills inside it makes the directory a hybrid tracked/untracked
/// tree, and a rebase then materializes the symlink into a real directory
/// holding only the tracked subset (#856).
#[test]
fn refresh_links_relocated_project_skills_into_agents() {
    let root = tmpdir("relocated-project-skills-link");
    let project = root.join("project");
    let source_dir = project.join("project-skills/benchmark");
    std::fs::create_dir_all(&source_dir).unwrap();
    std::fs::create_dir_all(project.join(".agents/skills")).unwrap();
    let source_md = source_dir.join("SKILL.md");
    std::fs::write(
        &source_md,
        "---\nname: benchmark\ndescription: Local benchmark\n---\n\n# Benchmark\n\nBody.\n",
    )
    .unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig {
        project_skills_dir: Some("project-skills".into()),
        ..ProjectConfig::default()
    };
    project_config
        .skill_instructions
        .insert("benchmark".into(), "Project rule.".into());

    let link = project.join(".agents/skills/benchmark");
    let stats = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(
        stats.failures.is_empty(),
        "relocate-and-link refresh failed: {:?}",
        stats.failures
    );
    assert_eq!(
        std::fs::read_link(&link).unwrap(),
        std::path::Path::new("../../project-skills/benchmark"),
        "refresh must link .agents/skills/<name> at the relocated source"
    );
    // Instructions belong in the TRACKED source file, not in a copy under .agents.
    assert!(
        std::fs::read_to_string(&source_md)
            .unwrap()
            .contains("## Project Instructions\n\nProject rule.")
    );
    assert!(stats.project_owned_skills.contains("benchmark"));

    // Idempotent: an already-correct link is left exactly as it is.
    let again = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(again.failures.is_empty());
    assert_eq!(
        std::fs::read_link(&link).unwrap(),
        std::path::Path::new("../../project-skills/benchmark")
    );

    let _ = std::fs::remove_dir_all(root);
}

/// A real directory at the destination is somebody's committed skill or a
/// materialized harness dir. Deleting either to make room for a link would be
/// the very bug this feature exists to prevent.
#[test]
fn refresh_refuses_to_replace_a_real_directory_with_a_project_skills_link() {
    let root = tmpdir("relocated-project-skills-clobber");
    let project = root.join("project");
    std::fs::create_dir_all(project.join("project-skills/benchmark")).unwrap();
    std::fs::write(
        project.join("project-skills/benchmark/SKILL.md"),
        "---\nname: benchmark\ndescription: relocated\n---\n\n# Benchmark\n",
    )
    .unwrap();
    let squatter = project.join(".agents/skills/benchmark");
    std::fs::create_dir_all(&squatter).unwrap();
    let squatter_md = squatter.join("SKILL.md");
    let squatter_body = "---\nname: benchmark\ndescription: committed in place\n---\n\n# Committed\n";
    std::fs::write(&squatter_md, squatter_body).unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig {
        project_skills_dir: Some("project-skills".into()),
        ..ProjectConfig::default()
    };

    let stats = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(
        stats
            .failures
            .iter()
            .any(|f| f.error.contains("refusing to replace existing non-symlink path")),
        "expected a refusal, got: {:?}",
        stats.failures
    );
    assert!(!squatter.is_symlink(), "the real directory must survive");
    assert_eq!(std::fs::read_to_string(&squatter_md).unwrap(), squatter_body);

    let _ = std::fs::remove_dir_all(root);
}

/// The relaxation is scoped to the CONFIGURED directory. Without the opt-in a
/// link pointing out of `.agents/skills` is still refused, which is the guard
/// that keeps an arbitrary escape from being followed.
#[test]
fn refresh_still_refuses_an_unconfigured_link_out_of_the_skills_root() {
    let root = tmpdir("relocated-project-skills-unconfigured");
    let project = root.join("project");
    std::fs::create_dir_all(project.join("elsewhere/benchmark")).unwrap();
    std::fs::create_dir_all(project.join(".agents/skills")).unwrap();
    std::fs::write(
        project.join("elsewhere/benchmark/SKILL.md"),
        "---\nname: benchmark\ndescription: unconfigured\n---\n\n# Benchmark\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(
        "../../elsewhere/benchmark",
        project.join(".agents/skills/benchmark"),
    )
    .unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig::default(); // no project-skills-dir

    let stats = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(
        stats
            .failures
            .iter()
            .any(|f| f.error.contains("outside skills root")),
        "expected the escape guard to still fire, got: {:?}",
        stats.failures
    );

    let _ = std::fs::remove_dir_all(root);
}

/// `project-skills-dir` must stay inside the project and outside `.agents`.
#[test]
fn refresh_rejects_project_skills_dir_inside_agents() {
    let root = tmpdir("relocated-project-skills-inside-agents");
    let project = root.join("project");
    std::fs::create_dir_all(project.join(".agents/mine/benchmark")).unwrap();
    std::fs::create_dir_all(project.join(".agents/skills")).unwrap();

    let lock = LockFile::default();
    let sources = Vec::new();
    let mut project_config = ProjectConfig {
        project_skills_dir: Some(".agents/mine".into()),
        ..ProjectConfig::default()
    };

    let stats = refresh_items_in_scope(false, &lock, &sources, &mut project_config, &project, None);
    assert!(
        stats
            .failures
            .iter()
            .any(|f| f.error.contains("must live outside .agents")),
        "expected rejection, got: {:?}",
        stats.failures
    );

    let _ = std::fs::remove_dir_all(root);
}
