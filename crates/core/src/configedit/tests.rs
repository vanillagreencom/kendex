use super::*;
#[test]
fn hook_upsert_is_idempotent_and_preserves_unrelated_keys() {
    let start = r#"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other"}]}]}}"#;
    let edit = ConfigEdit::UpsertHook {
        event: "PreToolUse".into(),
        matcher: Some("Bash".into()),
        command: "bash guard.sh".into(),
        timeout: Some(10),
    };
    let once = edit.apply(start).unwrap();
    assert_eq!(edit.apply(&once).unwrap(), once);
    let value: Value = serde_json::from_str(&once).unwrap();
    assert_eq!(value["model"], "opus");
    assert_eq!(value["hooks"]["Stop"][0]["hooks"][0]["command"], "other");
    assert_eq!(
        value["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
        "bash guard.sh"
    );
    assert_eq!(value["hooks"]["PreToolUse"][0]["matcher"], "Bash");

    let removed = ConfigEdit::RemoveHook {
        event: None,
        matcher: None,
        command: "bash guard.sh".into(),
    }
    .apply(&once)
    .unwrap();
    let value: Value = serde_json::from_str(&removed).unwrap();
    assert!(value["hooks"].get("PreToolUse").is_none());
    assert_eq!(value["hooks"]["Stop"][0]["hooks"][0]["command"], "other");
}

#[test]
fn mcp_and_plugin_edits_round_trip() {
    let edit = ConfigEdit::UpsertMcpServer {
        name: "gh".into(),
        value: json!({"command": "gh-mcp", "args": ["--stdio"]}),
    };
    let once = edit
        .apply(r#"{"mcpServers": {"other": {"command": "x"}}}"#)
        .unwrap();
    assert_eq!(edit.apply(&once).unwrap(), once);
    let removed = ConfigEdit::RemoveMcpServer { name: "gh".into() }
        .apply(&once)
        .unwrap();
    let value: Value = serde_json::from_str(&removed).unwrap();
    assert_eq!(value["mcpServers"]["other"]["command"], "x");
    assert!(value["mcpServers"].get("gh").is_none());

    let toggled = ConfigEdit::SetPluginEnabled {
        key: "fmt@main".into(),
        enabled: Some(false),
    }
    .apply("")
    .unwrap();
    let value: Value = serde_json::from_str(&toggled).unwrap();
    assert_eq!(value["enabledPlugins"]["fmt@main"], false);
}

#[test]
fn opencode_instruction_and_codex_feature_edits() {
    let edit = ConfigEdit::OpencodeAddInstruction {
        reference: ".opencode/instructions/kendex-hook-guard.md".into(),
        bash_permission: true,
    };
    let once = edit.apply(r#"{"mcp": {"db": {"type": "local"}}}"#).unwrap();
    assert_eq!(edit.apply(&once).unwrap(), once);
    let value: Value = serde_json::from_str(&once).unwrap();
    assert_eq!(value["mcp"]["db"]["type"], "local");
    assert_eq!(value["permission"]["bash"]["*"], "ask");

    let toml = "# my config\nmodel = \"gpt\"\n\n[features]\nexperimental = true\n";
    let enabled = ConfigEdit::CodexEnableHooksFeature.apply(toml).unwrap();
    assert!(enabled.contains("# my config"));
    assert!(enabled.contains("[features]\nhooks = true\nexperimental = true"));
    assert_eq!(
        ConfigEdit::CodexEnableHooksFeature.apply(&enabled).unwrap(),
        enabled
    );
}

#[test]
fn marker_blocks_upsert_and_strip_cleanly() {
    let base = "# My notes\n";
    let once = upsert_marker_block(base, "pi-hooks", "hook system text");
    assert!(once.starts_with("# My notes\n\n<!-- kendex:append-system pi-hooks begin -->"));
    let twice = upsert_marker_block(&once, "pi-hooks", "hook system text");
    assert_eq!(once, twice);
    assert_eq!(remove_marker_block(&once, "pi-hooks"), base);
}

/// A block written before the product rename is replaced under the new
/// markers, never left to stack beside a second copy — and removal finds it.
#[test]
fn an_old_generation_marker_block_upserts_and_removes_cleanly() {
    let base = "# My notes\n";
    let old = format!(
        "{base}\n<!-- vstack:append-system pi-hooks begin -->\nold text\n<!-- vstack:append-system pi-hooks end -->\n"
    );
    let refreshed = upsert_marker_block(&old, "pi-hooks", "new text");
    assert!(!refreshed.contains("vstack:append-system"), "{refreshed}");
    assert!(!refreshed.contains("old text"), "{refreshed}");
    assert_eq!(
        refreshed
            .matches("kendex:append-system pi-hooks begin")
            .count(),
        1,
        "{refreshed}"
    );
    assert_eq!(remove_marker_block(&old, "pi-hooks"), base);
}

/// A document quoting the markers inside a code fence keeps every byte of
/// the quote and its surroundings: only the real block — a marker alone on
/// its line, outside any fence — is replaced or removed.
#[test]
fn a_marker_quoted_in_a_code_fence_is_prose_not_a_block() {
    for (open, close) in [("```markdown", "```"), ("~~~", "~~~")] {
        let user = format!(
            "# Notes\n\nAn example of what kendex writes:\n\n{open}\n<!-- kendex:append-system pi-hooks begin -->\nexample body\n<!-- kendex:append-system pi-hooks end -->\n<!-- vstack:append-system pi-hooks begin -->\nold example\n<!-- vstack:append-system pi-hooks end -->\n{close}\n\nA paragraph the user wrote after the example.\n"
        );
        let with_block = format!(
            "{user}\n<!-- kendex:append-system pi-hooks begin -->\nreal body\n<!-- kendex:append-system pi-hooks end -->\n"
        );
        assert_eq!(
            remove_marker_block(&with_block, "pi-hooks"),
            user,
            "removal takes the real block and nothing else"
        );
        let refreshed = upsert_marker_block(&with_block, "pi-hooks", "new body");
        assert!(refreshed.starts_with(&user), "{refreshed}");
        assert!(refreshed.contains("new body"));
        assert!(!refreshed.contains("real body"));
        assert_eq!(
            remove_marker_block(&user, "pi-hooks"),
            user,
            "a file holding only the quoted example is untouched"
        );
    }
}

/// A marker sharing its line with other text is that text's, not a block
/// boundary; a real begin with no end is user damage and stays untouched.
#[test]
fn only_a_marker_alone_on_its_line_bounds_a_block() {
    let inline = "See `<!-- kendex:append-system pi-hooks begin -->` and later\n<!-- kendex:append-system pi-hooks end -->\n";
    assert_eq!(remove_marker_block(inline, "pi-hooks"), inline);
    let unterminated = "# Notes\n\n<!-- kendex:append-system pi-hooks begin -->\ndangling\n";
    assert_eq!(remove_marker_block(unterminated, "pi-hooks"), unterminated);
}

/// Another tool wrote keys after ours and a handler after ours: a re-apply
/// touches neither position, and removing a key never reorders the rest.
#[test]
fn hook_upsert_refreshes_in_place_and_removal_keeps_key_order() {
    let file = "{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"Bash\",\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"bash guard.sh\",\n            \"timeout\": 10\n          },\n          {\n            \"type\": \"command\",\n            \"command\": \"theirs\"\n          }\n        ]\n      }\n    ]\n  },\n  \"model\": \"opus\",\n  \"mcpServers\": {\n    \"gh\": {}\n  },\n  \"alwaysThinkingEnabled\": true\n}\n";
    let edit = ConfigEdit::UpsertHook {
        event: "PreToolUse".into(),
        matcher: Some("Bash".into()),
        command: "bash guard.sh".into(),
        timeout: Some(10),
    };
    assert_eq!(edit.apply(file).unwrap(), file);

    let removed = ConfigEdit::RemoveMcpServer { name: "gh".into() }
        .apply(file)
        .unwrap();
    let value: Value = serde_json::from_str(&removed).unwrap();
    let keys: Vec<&String> = value.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["hooks", "model", "alwaysThinkingEnabled"]);
}
