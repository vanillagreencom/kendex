//! Recovering hook lock entries from what is installed on disk.
//!
//! Which harness a hook is recorded for is decided by the artifact each
//! harness actually installs — a script, a rule, an instruction file, or the
//! Codex prose block inside an agent's `developer_instructions` — so these
//! tests own the per-harness evidence rules.

use super::*;
use std::fs;

#[test]
fn recover_hook_lock_entries_sets_empty_hash_for_refresh_summary() {
    let dir = sandbox("hook_recover_lock");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let script = test_hook_script("my-hook", "echo source");
    fs::write(source.join("hooks").join("my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    let modified = recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    );

    assert!(modified);
    let entry = lock.entries.get("my-hook").unwrap();
    assert_eq!(entry.kind, ItemKind::Hook);
    assert_eq!(entry.harnesses, vec!["claude-code".to_string()]);
    assert_eq!(entry.method, InstallMethod::Copy);
    assert!(
        entry.source_hash.is_empty(),
        "refresh should count recovered hooks as updated after reinstall"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_uses_lock_entry_source_identity_not_reconciliation_hint() {
    let dir = sandbox("hook_recover_existing_source_identity");
    let selected_source = dir.join("selected-source");
    let recorded_source = dir.join("recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    fs::create_dir_all(&recorded_source).unwrap();
    init_git_origin(
        &selected_source,
        "git@github.com:vanillagreencom/vstack.git",
    );
    init_git_origin(
        &recorded_source,
        "https://github.com/example/project-assets.git",
    );
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: recorded_source.display().to_string(),
        source_repo: None,
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(
        lock.entries
            .get("my-hook")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("example/project-assets")
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_replaces_stale_source_identity_from_live_source() {
    let dir = sandbox("hook_recover_replaces_stale_identity");
    let selected_source = dir.join("selected-source");
    let recorded_source = dir.join("recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    fs::create_dir_all(&recorded_source).unwrap();
    init_git_origin(
        &recorded_source,
        "https://github.com/example/project-assets.git",
    );
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: recorded_source.display().to_string(),
        source_repo: Some("vanillagreencom/vstack".to_string()),
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(
        lock.entries
            .get("my-hook")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("example/project-assets")
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_clears_stale_identity_for_live_source_without_origin() {
    let dir = sandbox("hook_recover_clears_stale_identity");
    let selected_source = dir.join("selected-source");
    let recorded_source = dir.join("recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    fs::create_dir_all(&recorded_source).unwrap();
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: recorded_source.display().to_string(),
        source_repo: Some("vanillagreencom/vstack".to_string()),
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(lock.entries.get("my-hook").unwrap().source_repo, None);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_preserves_identity_when_recorded_source_is_unavailable() {
    let dir = sandbox("hook_recover_preserves_unavailable_identity");
    let selected_source = dir.join("selected-source");
    let missing_recorded_source = dir.join("missing-recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: missing_recorded_source.display().to_string(),
        source_repo: Some("vanillagreencom/vstack".to_string()),
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(!recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(
        lock.entries
            .get("my-hook")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("vanillagreencom/vstack")
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_stale_script_after_source_change() {
    let dir = sandbox("hook_recover_stale_script");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(
        source.join("hooks").join("my-hook.sh"),
        test_hook_script("my-hook", "echo current source"),
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
    fs::write(
        project.join(".claude/hooks/my-hook.sh"),
        test_hook_script("my-hook", "echo previously installed source"),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let entry = lock.entries.get("my-hook").unwrap();
    assert_eq!(entry.harnesses, vec!["claude-code".to_string()]);
    assert!(entry.source_hash.is_empty());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_skips_same_named_foreign_script() {
    let dir = sandbox("hook_recover_foreign");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(
        source.join("hooks").join("my-hook.sh"),
        test_hook_script("my-hook", "echo source"),
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
    fs::write(
        project.join(".claude/hooks/my-hook.sh"),
        "#!/usr/bin/env bash
echo foreign
",
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    let modified = recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    );

    assert!(!modified);
    assert!(!lock.entries.contains_key("my-hook"));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_cursor_rule_only() {
    let dir = sandbox("hook_recover_cursor");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let source_hook_path = source.join("hooks").join("cursor-hook.sh");
    fs::write(
        &source_hook_path,
        test_hook_script("cursor-hook", "echo source"),
    )
    .unwrap();
    let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
    fs::create_dir_all(project.join(".cursor").join("rules")).unwrap();
    fs::write(
        project.join(".cursor/rules/safety-cursor-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&hook),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let entry = lock.entries.get("cursor-hook").unwrap();
    assert_eq!(entry.harnesses, vec!["cursor".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_ignores_cursor_rule_for_global_scope() {
    let dir = sandbox("hook_recover_cursor_global");
    let source = dir.join("source");
    let project = dir.join("project");
    let cursor_global_rules_dir = dir.join("global-cursor").join("rules");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let source_hook_path = source.join("hooks").join("cursor-hook.sh");
    fs::write(
        &source_hook_path,
        test_hook_script("cursor-hook", "echo source"),
    )
    .unwrap();
    let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
    fs::create_dir_all(&cursor_global_rules_dir).unwrap();
    fs::write(
        cursor_global_rules_dir.join("safety-cursor-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&hook),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    let modified = recover_hook_lock_entries_at_with_cursor_global_rules(
        &mut lock,
        &project,
        true,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
        &cursor_global_rules_dir,
    );

    assert!(
        !modified,
        "global recovery must not record project-only Cursor hooks"
    );
    assert!(
        !lock.entries.contains_key("cursor-hook"),
        "Cursor must be absent from global hook lock recovery"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_codex_prose_fallback_only() {
    let dir = sandbox("hook_recover_codex_prose");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let source_hook_path = source.join("hooks").join("prose-hook.sh");
    fs::write(
        &source_hook_path,
        test_hook_script_with_event("prose-hook", "TaskCompleted", "echo source"),
    )
    .unwrap();
    let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
    fs::create_dir_all(project.join(".codex").join("agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&hook)
        ),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let entry = lock.entries.get("prose-hook").unwrap();
    assert_eq!(entry.harnesses, vec!["codex".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_stale_generated_text_after_source_change() {
    let dir = sandbox("hook_recover_stale_text");
    let source = dir.join("source");
    let project = dir.join("project");
    let hooks_dir = source.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();

    fs::write(
        hooks_dir.join("text-hook.sh"),
        test_hook_script_with_meta(
            "text-hook",
            "PreToolUse",
            "Bash",
            "current description",
            "echo current",
        ),
    )
    .unwrap();
    let old_text_hook_path = dir.join("old-text-hook.sh");
    fs::write(
        &old_text_hook_path,
        test_hook_script_with_meta(
            "text-hook",
            "PreToolUse",
            "Bash",
            "previous description",
            "echo previous",
        ),
    )
    .unwrap();
    let old_text_hook = crate::hook::Hook::from_file(&old_text_hook_path).unwrap();

    fs::write(
        hooks_dir.join("prose-hook.sh"),
        test_hook_script_with_meta(
            "prose-hook",
            "TaskCompleted",
            "Bash",
            "current description",
            "echo current",
        ),
    )
    .unwrap();
    let old_prose_hook_path = dir.join("old-prose-hook.sh");
    fs::write(
        &old_prose_hook_path,
        test_hook_script_with_meta(
            "prose-hook",
            "TaskCompleted",
            "Bash",
            "previous description",
            "echo previous",
        ),
    )
    .unwrap();
    let old_prose_hook = crate::hook::Hook::from_file(&old_prose_hook_path).unwrap();

    fs::create_dir_all(project.join(".cursor/rules")).unwrap();
    fs::write(
        project.join(".cursor/rules/safety-text-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&old_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".opencode/instructions")).unwrap();
    fs::write(
        project.join(".opencode/instructions/vstack-hook-text-hook.md"),
        crate::installer::opencode_hook_instruction_contents(&old_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".codex/agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&old_prose_hook)
        ),
    )
    .unwrap();

    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let text_entry = lock.entries.get("text-hook").unwrap();
    assert_eq!(
        text_entry.harnesses,
        vec!["cursor".to_string(), "opencode".to_string()]
    );
    let prose_entry = lock.entries.get("prose-hook").unwrap();
    assert_eq!(prose_entry.harnesses, vec!["codex".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_rejects_same_named_foreign_generated_text() {
    let dir = sandbox("hook_recover_foreign_text");
    let source = dir.join("source");
    let project = dir.join("project");
    let hooks_dir = source.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();

    fs::write(
        hooks_dir.join("text-hook.sh"),
        test_hook_script_with_meta(
            "text-hook",
            "PreToolUse",
            "Bash",
            "source description",
            "echo source",
        ),
    )
    .unwrap();
    let foreign_text_hook_path = dir.join("foreign-text-hook.sh");
    fs::write(
        &foreign_text_hook_path,
        test_hook_script_with_meta(
            "text-hook",
            "PostToolUse",
            "Edit|Write",
            "source description",
            "echo foreign",
        ),
    )
    .unwrap();
    let foreign_text_hook = crate::hook::Hook::from_file(&foreign_text_hook_path).unwrap();

    fs::write(
        hooks_dir.join("prose-hook.sh"),
        test_hook_script_with_meta(
            "prose-hook",
            "TaskCompleted",
            "Bash",
            "source description",
            "echo source",
        ),
    )
    .unwrap();
    let foreign_prose_hook_path = dir.join("foreign-prose-hook.sh");
    fs::write(
        &foreign_prose_hook_path,
        test_hook_script_with_meta(
            "prose-hook",
            "PreToolUse",
            "Bash",
            "source description",
            "echo foreign",
        ),
    )
    .unwrap();
    let foreign_prose_hook = crate::hook::Hook::from_file(&foreign_prose_hook_path).unwrap();

    fs::create_dir_all(project.join(".cursor/rules")).unwrap();
    fs::write(
        project.join(".cursor/rules/safety-text-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&foreign_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".opencode/instructions")).unwrap();
    fs::write(
        project.join(".opencode/instructions/vstack-hook-text-hook.md"),
        crate::installer::opencode_hook_instruction_contents(&foreign_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".codex/agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&foreign_prose_hook)
        ),
    )
    .unwrap();

    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    assert!(!recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));
    assert!(lock.entries.is_empty());
    let _ = fs::remove_dir_all(&dir);
}

/// Lock recovery reads the prose fallback from the same block the install
/// writes it into. A marker sitting in a comment or an unrelated field is not
/// the fallback, and recovering `codex` from one records a harness whose
/// artifact was never written.
#[test]
fn recover_hook_lock_entries_ignores_marker_text_outside_developer_instructions() {
    let dir = sandbox("hook_recover_codex_decoy");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let hook_path = source.join("hooks").join("prose-hook.sh");
    fs::write(
        &hook_path,
        test_hook_script_with_event("prose-hook", "TaskCompleted", "echo source"),
    )
    .unwrap();
    let hook = crate::hook::Hook::from_file(&hook_path).unwrap();
    let block = crate::installer::codex_hook_safety_block(&hook);
    fs::create_dir_all(project.join(".codex").join("agents")).unwrap();
    // The whole block, verbatim — heading line, action line and all — sitting
    // in a field that is not the one Codex hands the agent.
    let decoy = format!("notes = '''\n{block}\n'''\n");
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!("{decoy}developer_instructions = '''\nBody\n'''\n"),
    )
    .unwrap();

    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    assert!(!recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));
    assert!(lock.entries.is_empty(), "{lock:?}");

    // Control: the same block INSIDE developer_instructions is the fallback.
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!("{decoy}developer_instructions = '''\n{block}\n'''\n"),
    )
    .unwrap();
    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));
    assert_eq!(
        lock.entries.get("prose-hook").unwrap().harnesses,
        vec!["codex".to_string()]
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_codex_prose_requires_exact_header_line() {
    let dir = sandbox("hook_recover_codex_prefix");
    let source = dir.join("source");
    let project = dir.join("project");
    let hooks_dir = source.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    fs::write(
        hooks_dir.join("foo.sh"),
        test_hook_script_with_event("foo", "TaskCompleted", "echo foo"),
    )
    .unwrap();
    let foo_bar_path = hooks_dir.join("foo-bar.sh");
    fs::write(
        &foo_bar_path,
        test_hook_script_with_event("foo-bar", "TaskCompleted", "echo foo-bar"),
    )
    .unwrap();
    let foo_bar_hook = crate::hook::Hook::from_file(&foo_bar_path).unwrap();

    fs::create_dir_all(project.join(".codex/agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&foo_bar_hook)
        ),
    )
    .unwrap();

    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    assert!(!lock.entries.contains_key("foo"));
    assert_eq!(
        lock.entries.get("foo-bar").unwrap().harnesses,
        vec!["codex".to_string()]
    );
    let _ = fs::remove_dir_all(&dir);
}
