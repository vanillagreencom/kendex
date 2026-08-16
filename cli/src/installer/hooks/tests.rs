use super::codex::{
    CodexNativeGap, codex_hooks_feature_enabled, enable_codex_hooks_feature,
    merge_codex_hooks_json, migrate_codex_hooks_feature,
};
use super::opencode::{install_hook_opencode_at_path, remove_hook_from_opencode_json_at_path};
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
fn install_hook_claude_places_timeout_on_handler_not_group() {
    let dir = tmpdir("claude_timeout_handler");
    let mut hook = hook_fixture("probe", "SessionStart", None);
    hook.timeout = Some(15);
    crate::test_util::with_project_root(&dir, || {
        install_hook_claude(&hook, false).unwrap();
    });

    let settings_path = dir.join(".claude").join("settings.json");
    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
    let arr = doc
        .pointer("/hooks/SessionStart")
        .and_then(|v| v.as_array())
        .expect("SessionStart array present");
    assert_eq!(arr.len(), 1);
    assert!(
        arr[0].pointer("/timeout").is_none(),
        "timeout must not sit on the matcher group, got: {doc}"
    );
    assert_eq!(
        arr[0].pointer("/hooks/0/timeout").and_then(|v| v.as_u64()),
        Some(15)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn install_hook_claude_migrates_legacy_group_level_timeout() {
    let dir = tmpdir("claude_timeout_migrate");
    let claude_dir = dir.join(".claude");
    std::fs::create_dir_all(&claude_dir).unwrap();
    // Legacy install put timeout on the matcher group; a user-authored entry
    // with the same shape must survive untouched.
    std::fs::write(
        claude_dir.join("settings.json"),
        r#"{
  "hooks": {
    "SessionStart": [
      {
        "timeout": 15,
        "hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/probe.sh\""}]
      },
      {
        "timeout": 99,
        "hooks": [{"type": "command", "command": "bash /usr/local/bin/user-own.sh"}]
      }
    ]
  }
}"#,
    )
    .unwrap();

    let mut hook = hook_fixture("probe", "SessionStart", None);
    hook.timeout = Some(15);
    crate::test_util::with_project_root(&dir, || {
        install_hook_claude(&hook, false).unwrap();
    });

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(claude_dir.join("settings.json")).unwrap())
            .unwrap();
    let arr = doc
        .pointer("/hooks/SessionStart")
        .and_then(|v| v.as_array())
        .expect("SessionStart array present");
    assert_eq!(arr.len(), 2);
    let user = &arr[0];
    assert_eq!(
        user.pointer("/hooks/0/command").and_then(|v| v.as_str()),
        Some("bash /usr/local/bin/user-own.sh")
    );
    assert_eq!(
        user.pointer("/timeout").and_then(|v| v.as_u64()),
        Some(99),
        "user-authored entry must not be rewritten"
    );
    let owned = &arr[1];
    assert!(
        owned.pointer("/timeout").is_none(),
        "stale group-level timeout must be removed on reinstall, got: {doc}"
    );
    assert_eq!(
        owned.pointer("/hooks/0/timeout").and_then(|v| v.as_u64()),
        Some(15)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn install_hook_claude_without_timeout_emits_no_timeout_key() {
    let dir = tmpdir("claude_timeout_absent");
    let mut hook = hook_fixture("probe", "SessionStart", None);
    hook.timeout = None;
    crate::test_util::with_project_root(&dir, || {
        install_hook_claude(&hook, false).unwrap();
    });

    let body = std::fs::read_to_string(dir.join(".claude").join("settings.json")).unwrap();
    assert!(
        !body.contains("timeout"),
        "no timeout key should be emitted, got: {body}"
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

fn agent_fixture(name: &str) -> Agent {
    Agent {
        name: name.into(),
        description: format!("{name} agent"),
        model: "sonnet".into(),
        role: crate::agent::AgentRole::Engineer,
        color: None,
        effort: None,
        body: "Body\n".into(),
        source_path: PathBuf::new(),
    }
}

/// Fallback prose is installed for EVERY Codex agent or not claimed at all.
/// Accumulating success across agents let one agent that already carried the
/// marker report the whole install done while a newly added agent whose TOML
/// has no `developer_instructions` block silently got no safety prose.
#[test]
fn codex_prose_install_fails_on_an_agent_it_cannot_write_and_names_it() {
    let dir = tmpdir("codex_prose_partial");
    let agents_dir = dir.join("agents");
    std::fs::create_dir_all(&agents_dir).unwrap();
    let well_formed =
        |name: &str| format!("name = \"{name}\"\ndeveloper_instructions = '''\nBody\n'''\n");
    std::fs::write(agents_dir.join("first.toml"), well_formed("first")).unwrap();
    // Second agent's TOML has no closing ''' — nowhere to put the block.
    std::fs::write(
        agents_dir.join("second.toml"),
        "name = \"second\"\ndescription = \"no instructions block\"\n",
    )
    .unwrap();
    let hook = hook_fixture("post-edit-lint", "TaskCompleted", None);
    let agents = [agent_fixture("first"), agent_fixture("second")];

    let err = crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .expect_err("an agent that cannot receive the block must not report success")
    });
    let message = format!("{err:#}");
    assert!(message.contains("second"), "names the agent: {message}");
    assert!(
        message.contains(&agents_dir.join("second.toml").display().to_string()),
        "names the file: {message}"
    );

    // Control: both well-formed → success, and both files carry the block.
    std::fs::write(agents_dir.join("second.toml"), well_formed("second")).unwrap();
    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    let marker = "## Safety: post-edit-lint";
    for name in ["first", "second"] {
        let body = std::fs::read_to_string(agents_dir.join(format!("{name}.toml"))).unwrap();
        assert!(body.contains(marker), "{name} must carry the block: {body}");
    }

    // Control: a rerun over agents that already carry it is still success and
    // writes no second copy.
    crate::test_util::with_codex_home(&dir, || {
        install_codex_fallback_hooks_for_agents(std::slice::from_ref(&hook), true, &agents)
            .unwrap();
    });
    for name in ["first", "second"] {
        let body = std::fs::read_to_string(agents_dir.join(format!("{name}.toml"))).unwrap();
        assert_eq!(
            body.matches(marker).count(),
            1,
            "no duplicate block: {body}"
        );
    }
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
        "# user comment\nmodel = \"gpt-5.6-sol\"\n\n[other]\nfoo = 1\n",
    )
    .unwrap();
    enable_codex_hooks_feature(&config).unwrap();
    let body = std::fs::read_to_string(&config).unwrap();
    assert!(body.contains("# user comment"));
    assert!(body.contains("model = \"gpt-5.6-sol\""));
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
    assert!(result.ends_with('\n'));
    assert!(!result.ends_with("\n\n"));

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
fn install_hook_opencode_normalizes_trailing_newlines_and_is_idempotent() {
    for (label, trailing) in [("none", ""), ("one", "\n"), ("multiple", "\n\n\n")] {
        let base = tmpdir(&format!("opencode_newline_{label}"));
        let config_path = base.join("opencode.json");
        let instruction_path = base.join("instructions").join("vstack-hook-guard.md");
        let instruction_ref = "instructions/vstack-hook-guard.md";
        let hook = hook_fixture("guard", "PreToolUse", Some("Bash"));
        std::fs::write(&config_path, format!("{{\"custom\":true}}{trailing}")).unwrap();

        install_hook_opencode_at_path(&hook, &config_path, &instruction_path, instruction_ref)
            .unwrap();

        let first = std::fs::read(&config_path).unwrap();
        assert!(first.ends_with(b"\n"), "{label}: missing trailing newline");
        assert!(
            !first.ends_with(b"\n\n"),
            "{label}: emitted multiple trailing newlines"
        );
        let parsed: serde_json::Value = serde_json::from_slice(&first).unwrap();
        assert_eq!(parsed.get("custom"), Some(&serde_json::json!(true)));

        install_hook_opencode_at_path(&hook, &config_path, &instruction_path, instruction_ref)
            .unwrap();

        assert_eq!(
            std::fs::read(&config_path).unwrap(),
            first,
            "{label}: second install changed the rendered config"
        );
        let _ = std::fs::remove_dir_all(&base);
    }
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

/// A global codex scope carrying `hooks/foo.sh` (plus a same-named decoy
/// `hooks/pre-foo.sh`), the hooks feature on, and one `PreToolUse` handler
/// running `command`. Returns the scope dir and the gaps reported for `foo`.
fn codex_gaps_for_registered_command(
    label: &str,
    command: impl FnOnce(&Path) -> String,
) -> (PathBuf, Vec<CodexNativeGap>) {
    let dir = tmpdir(label);
    let hooks_dir = dir.join("hooks");
    std::fs::create_dir_all(&hooks_dir).unwrap();
    std::fs::write(hooks_dir.join("foo.sh"), "#!/usr/bin/env bash\n").unwrap();
    std::fs::write(hooks_dir.join("pre-foo.sh"), "#!/usr/bin/env bash\n").unwrap();
    std::fs::write(dir.join("config.toml"), "[features]\nhooks = true\n").unwrap();
    let doc = serde_json::json!({
        "hooks": {
            "PreToolUse": [{
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": command(&dir)}]
            }]
        }
    });
    std::fs::write(
        dir.join("hooks.json"),
        serde_json::to_string_pretty(&doc).unwrap(),
    )
    .unwrap();

    let gaps = crate::test_util::with_codex_home(&dir, || {
        codex_native_hook_gaps(true, "foo", "PreToolUse")
    });
    (dir, gaps)
}

#[test]
fn codex_registration_requires_the_managed_script_path() {
    // Control: exactly what vstack renders.
    let (dir, gaps) = codex_gaps_for_registered_command("codex_reg_owned", |dir| {
        format!("bash {}", dir.join("hooks").join("foo.sh").display())
    });
    assert!(
        gaps.is_empty(),
        "vstack's own command must register: {gaps:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);

    // A command reshaped by hand around OUR script still counts.
    let (dir, gaps) = codex_gaps_for_registered_command("codex_reg_reshaped", |dir| {
        format!(
            "env VSTACK=1 bash \"{}\" --verbose",
            dir.join("hooks").join("foo.sh").display()
        )
    });
    assert!(
        !gaps.contains(&CodexNativeGap::NotRegistered),
        "a reshaped command on the managed script must register: {gaps:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);

    // Somebody else's same-named script must not answer for ours.
    let (dir, gaps) = codex_gaps_for_registered_command("codex_reg_foreign", |_| {
        "bash /somewhere/else/foo.sh".to_string()
    });
    assert!(
        gaps.contains(&CodexNativeGap::NotRegistered),
        "a same-named script elsewhere must not mask a deleted entry: {gaps:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);

    // Existing control: a differently named neighbour never answers.
    let (dir, gaps) = codex_gaps_for_registered_command("codex_reg_prefixed", |dir| {
        format!("bash {}", dir.join("hooks").join("pre-foo.sh").display())
    });
    assert!(
        gaps.contains(&CodexNativeGap::NotRegistered),
        "pre-foo.sh must not answer for foo.sh: {gaps:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn codex_hooks_feature_reads_the_parsed_table() {
    let dir = tmpdir("codex_feature_read");
    let config = dir.join("config.toml");

    std::fs::write(&config, "[features]\nhooks = true\n").unwrap();
    assert!(
        codex_hooks_feature_enabled(&config),
        "control: the boolean true is enabled"
    );

    // A multiline string whose CONTENT spells the table must not answer for it.
    std::fs::write(
        &config,
        "notes = '''\n[features]\nhooks = true\n'''\n\n[features]\nhooks = false\n",
    )
    .unwrap();
    assert!(
        !codex_hooks_feature_enabled(&config),
        "the real table says false"
    );

    // Codex reads a boolean; the string is not one.
    std::fs::write(&config, "[features]\nhooks = \"true\"\n").unwrap();
    assert!(
        !codex_hooks_feature_enabled(&config),
        "a string is not true"
    );

    std::fs::write(&config, "[features\nhooks = true\n").unwrap();
    assert!(
        !codex_hooks_feature_enabled(&config),
        "an unparseable config enables nothing"
    );

    assert!(!codex_hooks_feature_enabled(&dir.join("missing.toml")));
    let _ = std::fs::remove_dir_all(&dir);
}
