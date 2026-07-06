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
