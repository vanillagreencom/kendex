use super::opencode::remove_hook_from_opencode_json_at_path;
use super::*;

fn hook_fixture(name: &str, event: &str, matcher: Option<&str>) -> Hook {
    Hook {
        name: name.into(),
        event: event.into(),
        matcher: matcher.map(|m| m.into()),
        description: format!("{name} test hook"),
        safety: None,
        timeout: Some(30),
        harnesses: None,
        script: format!("#!/usr/bin/env bash\n# {name}\nexit 0\n"),
        source_path: PathBuf::new(),
    }
}

fn tmpdir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "vstack_{label}_{}_{}",
        std::process::id(),
        crate::config::now_iso().replace([':', '-'], "")
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn codex_event_for_known_events() {
    assert_eq!(codex_event_for("PreToolUse"), Some("PreToolUse"));
    assert_eq!(codex_event_for("PostToolUse"), Some("PostToolUse"));
    assert_eq!(codex_event_for("Stop"), Some("Stop"));
    assert_eq!(codex_event_for("SessionStart"), Some("SessionStart"));
}

#[test]
fn codex_event_for_taskcompleted_is_unmapped() {
    // TaskCompleted has no clean codex equivalent — routes to prose fallback.
    assert_eq!(codex_event_for("TaskCompleted"), None);
}

#[test]
fn merge_codex_hooks_json_creates_new_file() {
    let dir = tmpdir("codex_merge_new");
    let hooks_json = dir.join("hooks.json");
    let hook = hook_fixture("block-bare-cd", "PreToolUse", Some("Bash"));
    let command = "bash /tmp/block-bare-cd.sh";
    merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, command).unwrap();

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
    let arr = doc
        .pointer("/hooks/PreToolUse")
        .and_then(|v| v.as_array())
        .expect("PreToolUse array present");
    assert_eq!(arr.len(), 1);
    assert_eq!(
        arr[0].pointer("/matcher").and_then(|v| v.as_str()),
        Some("Bash")
    );
    assert_eq!(
        arr[0].pointer("/hooks/0/command").and_then(|v| v.as_str()),
        Some(command)
    );
    assert_eq!(
        arr[0].pointer("/hooks/0/timeout").and_then(|v| v.as_u64()),
        Some(30)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn merge_codex_hooks_json_is_idempotent() {
    let dir = tmpdir("codex_merge_idempotent");
    let hooks_json = dir.join("hooks.json");
    let hook = hook_fixture("block-bare-cd", "PreToolUse", Some("Bash"));
    let command = "bash /tmp/block-bare-cd.sh";
    merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, command).unwrap();
    merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, command).unwrap();
    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
    assert_eq!(
        doc.pointer("/hooks/PreToolUse")
            .and_then(|v| v.as_array())
            .map(|a| a.len()),
        Some(1)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn merge_codex_hooks_json_replaces_existing_hook_registration() {
    let dir = tmpdir("codex_merge_replace");
    let hooks_json = dir.join("hooks.json");
    std::fs::write(
        &hooks_json,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/guard.sh", "timeout": 30}]
      }
    ]
  }
}"#,
    )
    .unwrap();
    let mut hook = hook_fixture("guard", "PostCompact", None);
    hook.timeout = Some(5);
    merge_codex_hooks_json(
        &hooks_json,
        "PostCompact",
        &hook,
        "bash /home/.codex/hooks/guard.sh",
    )
    .unwrap();

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
    assert!(doc.pointer("/hooks/PreToolUse").is_none());
    let arr = doc
        .pointer("/hooks/PostCompact")
        .and_then(|v| v.as_array())
        .expect("PostCompact array present");
    assert_eq!(arr.len(), 1);
    assert!(arr[0].pointer("/matcher").is_none());
    assert_eq!(
        arr[0].pointer("/hooks/0/timeout").and_then(|v| v.as_u64()),
        Some(5)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn hook_prune_preserves_user_handlers_with_same_basename() {
    let mut hooks_obj = serde_json::json!({
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "bash ./scripts/guard.sh"}]
                },
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "bash /usr/local/bin/guard.sh"}]
                },
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\""}]
                }
            ]
        })
        .as_object()
        .unwrap()
        .clone();
    let owned = vec!["bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\"".to_string()];

    assert!(remove_hook_entries_from_hooks_object(
        &mut hooks_obj,
        &owned
    ));
    let arr = hooks_obj
        .get("PreToolUse")
        .and_then(|v| v.as_array())
        .unwrap();
    assert_eq!(arr.len(), 2, "only vstack-owned command should be pruned");
    let body = serde_json::to_string(&hooks_obj).unwrap();
    assert!(body.contains("./scripts/guard.sh"));
    assert!(body.contains("/usr/local/bin/guard.sh"));
    assert!(!body.contains(".claude/hooks/guard.sh"));
}

#[test]
fn merge_codex_hooks_json_does_not_dedupe_substring_collisions() {
    // A hook named `foo` must not be considered already-present when the
    // event already has `notfoo.sh`; only exact vstack-owned commands are
    // pruned.
    let dir = tmpdir("codex_merge_substring");
    let hooks_json = dir.join("hooks.json");
    std::fs::write(
        &hooks_json,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/notfoo.sh"}]
      }
    ]
  }
}"#,
    )
    .unwrap();
    let hook = hook_fixture("foo", "PreToolUse", Some("Bash"));
    merge_codex_hooks_json(
        &hooks_json,
        "PreToolUse",
        &hook,
        "bash /home/.codex/hooks/foo.sh",
    )
    .unwrap();

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
    let arr = doc
        .pointer("/hooks/PreToolUse")
        .and_then(|v| v.as_array())
        .unwrap();
    assert_eq!(
        arr.len(),
        2,
        "`foo.sh` must not collide with existing `notfoo.sh`"
    );
}

#[test]
fn merge_codex_hooks_json_preserves_existing_entries() {
    let dir = tmpdir("codex_merge_preserve");
    let hooks_json = dir.join("hooks.json");
    std::fs::write(
        &hooks_json,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /user/own.sh"}]
      }
    ]
  }
}"#,
    )
    .unwrap();

    let hook = hook_fixture("new-one", "PreToolUse", Some("Bash"));
    merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, "bash /tmp/new-one.sh").unwrap();

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
    let arr = doc
        .pointer("/hooks/PreToolUse")
        .and_then(|v| v.as_array())
        .unwrap();
    assert_eq!(arr.len(), 2, "user entry should be preserved");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn merge_codex_hooks_json_preserves_user_handler_with_same_basename() {
    let dir = tmpdir("codex_merge_preserve_same_basename");
    let hooks_json = dir.join("hooks.json");
    std::fs::write(
        &hooks_json,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /usr/local/bin/guard.sh"}]
      }
    ]
  }
}"#,
    )
    .unwrap();

    let hook = hook_fixture("guard", "PreToolUse", Some("Bash"));
    merge_codex_hooks_json(&hooks_json, "PreToolUse", &hook, "bash /tmp/guard.sh").unwrap();

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
    let arr = doc
        .pointer("/hooks/PreToolUse")
        .and_then(|v| v.as_array())
        .unwrap();
    assert_eq!(arr.len(), 2, "user entry with same basename should remain");
    let body = serde_json::to_string(&doc).unwrap();
    assert!(body.contains("/usr/local/bin/guard.sh"));
    assert!(body.contains("/tmp/guard.sh"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn remove_hook_install_codex_strips_script_json_and_legacy_prose() {
    let dir = tmpdir("codex_remove_strip");
    let hooks_dir = dir.join("hooks");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&hooks_dir).unwrap();
    std::fs::create_dir_all(&agents_dir).unwrap();
    std::fs::write(hooks_dir.join("post-edit-lint.sh"), "#!/usr/bin/env bash\n").unwrap();
    std::fs::write(hooks_dir.join("block-bare-cd.sh"), "#!/usr/bin/env bash\n").unwrap();
    let post_edit_command = format!("bash {}", hooks_dir.join("post-edit-lint.sh").display());
    let block_bare_command = format!("bash {}", hooks_dir.join("block-bare-cd.sh").display());

    let hooks_json = dir.join("hooks.json");
    let hooks_doc = serde_json::json!({
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": block_bare_command}]
                },
                {
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": "bash /home/.codex/hooks/user-own.sh"}]
                }
            ],
            "PostToolUse": [
                {
                    "matcher": "Edit|Write",
                    "hooks": [{"type": "command", "command": post_edit_command}]
                }
            ]
        }
    });
    std::fs::write(
        &hooks_json,
        serde_json::to_string_pretty(&hooks_doc).unwrap(),
    )
    .unwrap();
    let agent_toml = agents_dir.join("rust.toml");
    std::fs::write(
        &agent_toml,
        r#"name = "rust"
developer_instructions = '''
Body

## Safety: post-edit-lint

Remove me.

## Keep

Keep me.
'''
"#,
    )
    .unwrap();

    crate::test_util::with_codex_home(&dir, || {
        remove_hook_install("post-edit-lint", Harness::Codex, true).unwrap();
    });

    let result: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&hooks_json).unwrap()).unwrap();
    assert!(!hooks_dir.join("post-edit-lint.sh").exists());
    assert!(hooks_dir.join("block-bare-cd.sh").exists());
    assert!(
        result.pointer("/hooks/PostToolUse").is_none(),
        "empty PostToolUse should be pruned"
    );
    let pre = result
        .pointer("/hooks/PreToolUse")
        .unwrap()
        .as_array()
        .unwrap();
    assert_eq!(pre.len(), 2, "unrelated PreToolUse entries preserved");
    let agent = std::fs::read_to_string(agent_toml).unwrap();
    assert!(!agent.contains("Safety: post-edit-lint"));
    assert!(agent.contains("## Keep"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enable_codex_hooks_feature_creates_section() {
    let dir = tmpdir("codex_features_new");
    let config = dir.join("config.toml");
    enable_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    assert!(body.contains("[features]"));
    assert!(body.contains("hooks = true"));
    assert!(!body.contains("codex_hooks"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enable_codex_hooks_feature_is_idempotent() {
    let dir = tmpdir("codex_features_idempotent");
    let config = dir.join("config.toml");
    enable_codex_hooks_feature(&config).unwrap();
    let body1 = std::fs::read_to_string(&config).unwrap();
    enable_codex_hooks_feature(&config).unwrap();
    let body2 = std::fs::read_to_string(&config).unwrap();
    assert_eq!(body1, body2);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enable_codex_hooks_feature_preserves_user_content() {
    let dir = tmpdir("codex_features_preserve");
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "# user comment\nmodel = \"gpt-5.5\"\n\n[other]\nfoo = 1\n",
    )
    .unwrap();
    enable_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    assert!(body.contains("# user comment"));
    assert!(body.contains("model = \"gpt-5.5\""));
    assert!(body.contains("[other]"));
    assert!(body.contains("hooks = true"));
    assert!(!body.contains("codex_hooks"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enable_codex_hooks_feature_inserts_under_existing_features() {
    let dir = tmpdir("codex_features_existing");
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "[features]\nother_flag = true\n\n[unrelated]\nx = 1\n",
    )
    .unwrap();
    enable_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    let features_pos = body.find("[features]").unwrap();
    let unrelated_pos = body.find("[unrelated]").unwrap();
    let hooks_pos = body.find("hooks = true").unwrap();
    assert!(features_pos < hooks_pos && hooks_pos < unrelated_pos);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enable_codex_hooks_feature_migrates_deprecated_flag() {
    let dir = tmpdir("codex_features_migrate");
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "[features]\ncodex_hooks = true\nother_flag = true\n\n[unrelated]\nx = 1\n",
    )
    .unwrap();
    enable_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    assert!(body.contains("hooks = true"));
    assert!(body.contains("other_flag = true"));
    assert!(!body.contains("codex_hooks"));
    let hooks_pos = body.find("hooks = true").unwrap();
    let unrelated_pos = body.find("[unrelated]").unwrap();
    assert!(hooks_pos < unrelated_pos);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn migrate_codex_hooks_feature_does_not_create_config() {
    let dir = tmpdir("codex_features_migrate_no_config");
    let config = dir.join("config.toml");
    migrate_codex_hooks_feature(&config).unwrap();
    assert!(!config.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn migrate_codex_hooks_feature_preserves_deprecated_value() {
    let dir = tmpdir("codex_features_migrate_only");
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "[features]\ncodex_hooks = false\nother_flag = true\n\n[unrelated]\nx = 1\n",
    )
    .unwrap();
    migrate_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    assert!(body.contains("hooks = false"));
    assert!(body.contains("other_flag = true"));
    assert!(!body.contains("codex_hooks"));
    let hooks_pos = body.find("hooks = false").unwrap();
    let unrelated_pos = body.find("[unrelated]").unwrap();
    assert!(hooks_pos < unrelated_pos);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn migrate_codex_hooks_feature_prefers_existing_hooks_value() {
    let dir = tmpdir("codex_features_migrate_existing_hooks");
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "[features]\nhooks = false\ncodex_hooks = true\nother_flag = true\n",
    )
    .unwrap();
    migrate_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    assert!(body.contains("hooks = false"));
    assert!(!body.contains("hooks = true"));
    assert!(!body.contains("codex_hooks"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn enable_codex_hooks_feature_replaces_disabled_hooks_flag() {
    let dir = tmpdir("codex_features_disabled");
    let config = dir.join("config.toml");
    std::fs::write(&config, "[features]\nhooks = false\ncodex_hooks = true\n").unwrap();
    enable_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    assert!(body.contains("hooks = true"));
    assert!(!body.contains("hooks = false"));
    assert!(!body.contains("codex_hooks"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn remove_hook_from_opencode_removes_instruction() {
    let base = std::env::temp_dir().join("vstack_test_opencode");
    let _ = std::fs::create_dir_all(&base);
    let config_path = base.join("opencode.json");
    let instruction_path = base
        .join(".opencode")
        .join("instructions")
        .join("vstack-hook-block-bare-cd.md");
    std::fs::create_dir_all(instruction_path.parent().unwrap()).unwrap();
    std::fs::write(&instruction_path, "# Safety").unwrap();

    let content = r#"{
  "$schema": "https://opencode.ai/config.json",
  "instructions": [
    ".opencode/instructions/vstack-hook-block-bare-cd.md"
  ],
  "permission": {
    "bash": {
      "*": "ask"
    }
  }
}"#;
    std::fs::write(&config_path, content).unwrap();

    remove_hook_from_opencode_json_at_path(
        &config_path,
        &instruction_path,
        ".opencode/instructions/vstack-hook-block-bare-cd.md",
        "block-bare-cd",
    )
    .unwrap();

    let result = std::fs::read_to_string(&config_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();

    // instructions and permission should be gone
    assert!(
        parsed.get("instructions").is_none(),
        "instructions should be removed, got: {result}"
    );
    assert!(
        parsed.get("permission").is_none(),
        "permission should be removed, got: {result}"
    );
    assert!(
        !instruction_path.exists(),
        "instruction file should be removed"
    );

    // Cleanup
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn remove_hook_from_opencode_keeps_instruction_when_config_parse_fails() {
    let base = std::env::temp_dir().join("vstack_test_opencode_invalid_config");
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).unwrap();
    let config_path = base.join("opencode.json");
    let instruction_path = base.join("instructions").join("vstack-hook-guard.md");
    std::fs::create_dir_all(instruction_path.parent().unwrap()).unwrap();
    std::fs::write(&instruction_path, "# Safety").unwrap();
    std::fs::write(&config_path, "{not-json").unwrap();

    let result = remove_hook_from_opencode_json_at_path(
        &config_path,
        &instruction_path,
        "instructions/vstack-hook-guard.md",
        "guard",
    );

    assert!(result.is_err());
    assert!(
        instruction_path.exists(),
        "instruction file should remain when config cleanup fails"
    );
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn remove_hook_from_opencode_preserves_unrelated_permissions() {
    let base = std::env::temp_dir().join("vstack_test_opencode_permissions");
    let _ = std::fs::create_dir_all(&base);
    let config_path = base.join("opencode.json");
    let instruction_path = base.join("instructions").join("vstack-hook-review-bash.md");
    std::fs::create_dir_all(instruction_path.parent().unwrap()).unwrap();
    std::fs::write(&instruction_path, "# Safety").unwrap();

    let content = r#"{
  "$schema": "https://opencode.ai/config.json",
  "instructions": [
    "instructions/vstack-hook-review-bash.md"
  ],
  "permission": {
    "edit": "deny",
    "bash": {
      "*": "ask"
    }
  }
}"#;
    std::fs::write(&config_path, content).unwrap();

    remove_hook_from_opencode_json_at_path(
        &config_path,
        &instruction_path,
        "instructions/vstack-hook-review-bash.md",
        "review-bash",
    )
    .unwrap();

    let result = std::fs::read_to_string(&config_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();

    assert_eq!(
        parsed.get("permission").and_then(|p| p.get("edit")),
        Some(&serde_json::Value::String("deny".into()))
    );
    assert!(
        parsed
            .get("permission")
            .and_then(|p| p.get("bash"))
            .is_none(),
        "vstack-added bash permission should be removed, got: {result}"
    );

    let _ = std::fs::remove_dir_all(&base);
}
