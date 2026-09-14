use super::*;
#[test]
fn owned_hook_templates_are_reconciled_by_script_path() {
    use crate::engine::targets::{HookTarget, hook_target};
    use crate::env::{Env, FakeOs};
    use crate::model::{HarnessId, Scope};
    let env = Env::fake("/h", FakeOs::Linux);
    let scope = Scope::Project { root: "/p".into() };
    for (harness, dir) in [
        (HarnessId::Codex, ".codex/hooks"),
        (HarnessId::Pi, ".pi/kendex/hooks"),
    ] {
        let Some(HookTarget::Script { command, .. }) = hook_target(&env, &scope, harness, "guard")
        else {
            panic!("hook must have a script target");
        };
        // engine::targets::project_command emitted this walker into committed registries.
        let old = format!(
            "p='{dir}/guard.sh'; r=$(cd -P . && pwd); case $r in /*) ;; *) r=;; esac; while [ -n \"$r\" ] && ! [ -f \"$r/$p\" ]; do [ \"$r\" = / ] && r= || {{ r=${{r%/*}}; [ -n \"$r\" ] || r=/; }}; done; [ -n \"$r\" ] || {{ echo \"kendex: no directory above $PWD holds $p; run kendex refresh in the project\" >&2; exit 1; }}; bash \"$r/$p\""
        );
        let user = json!({"command": "bash tools/guard.sh"});
        let stale = json!({"type": "command", "command": old});
        let current = json!({"type": "command", "command": command, "timeout": 10});
        for (handlers, expected) in [
            (json!([stale, user]), json!([current, user])),
            (json!([stale, user, current]), json!([current, user])),
            (json!([user]), json!([user, current])),
        ] {
            let mut events = json!({"PreToolUse": [{"matcher": "Bash", "hooks": handlers}]});
            let mut removed = events.clone();
            let events = events.as_object_mut().unwrap();
            nested::upsert_in(events, "PreToolUse", Some("Bash"), &command, Some(10)).unwrap();
            assert_eq!(events["PreToolUse"][0]["hooks"], expected);
            let removed = removed.as_object_mut().unwrap();
            nested::remove_in(removed, "PreToolUse", Some("Bash"), &command);
            assert_eq!(removed["PreToolUse"][0]["hooks"], json!([user]));
        }
    }
}

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

    let prune = ConfigEdit::OpencodePruneInstructions {
        prefix: ".opencode/instructions/kendex-hook-".into(),
        keep: [(".opencode/instructions/kendex-hook-guard.md".into(), true)].into(),
    };
    let doc = r#"{"instructions": [".opencode/instructions/kendex-hook-guard.md", ".opencode/instructions/kendex-hook-old.md", ".opencode/instructions/my-notes.md", "AGENTS.md"]}"#;
    let pruned = prune.apply(doc).unwrap();
    assert_eq!(prune.apply(&pruned).unwrap(), pruned);
    let value: Value = serde_json::from_str(&pruned).unwrap();
    assert_eq!(
        value["instructions"],
        serde_json::json!([
            ".opencode/instructions/kendex-hook-guard.md",
            ".opencode/instructions/my-notes.md",
            "AGENTS.md"
        ]),
        "marker-named rows are cut to the render set; everything else stays"
    );
    let emptied = ConfigEdit::OpencodePruneInstructions {
        prefix: ".opencode/instructions/kendex-hook-".into(),
        keep: Default::default(),
    }
    .apply(r#"{"instructions": [".opencode/instructions/kendex-hook-old.md"]}"#)
    .unwrap();
    let value: Value = serde_json::from_str(&emptied).unwrap();
    assert!(
        value.get("instructions").is_none(),
        "an emptied array is a key the user never wrote"
    );

    let toml = "# my config\nmodel = \"gpt\"\n\n[features]\nexperimental = true\n";
    let enabled = ConfigEdit::CodexEnableHooksFeature.apply(toml).unwrap();
    assert!(enabled.contains("# my config"));
    assert!(enabled.contains("[features]\nhooks = true\nexperimental = true"));
    assert_eq!(
        ConfigEdit::CodexEnableHooksFeature.apply(&enabled).unwrap(),
        enabled
    );
}

/// The block takes the file's own terminator, so a CRLF file that already
/// holds it comes back byte-identical.
#[test]
fn marker_blocks_upsert_and_strip_cleanly() {
    for newline in ["\n", "\r\n"] {
        let base = format!("# My notes{newline}");
        let once = upsert_marker_block(&base, "pi-hooks", "hook system text");
        let opened = format!(
            "# My notes{newline}{newline}<!-- kendex:append-system pi-hooks begin -->{newline}"
        );
        assert!(once.starts_with(&opened), "{once:?}");
        let twice = upsert_marker_block(&once, "pi-hooks", "hook system text");
        assert_eq!(once, twice);
        assert_eq!(remove_marker_block(&once, "pi-hooks"), base);
    }
}

/// A document quoting the markers inside a code fence keeps every byte of
/// the quote and its surroundings: only the real block — a marker alone on
/// its line, outside any fence — is replaced or removed.
#[test]
fn a_marker_quoted_in_a_code_fence_is_prose_not_a_block() {
    for (open, close) in [("```markdown", "```"), ("~~~", "~~~")] {
        let user = format!(
            "# Notes\n\nAn example of what kendex writes:\n\n{open}\n<!-- kendex:append-system pi-hooks begin -->\nexample body\n<!-- kendex:append-system pi-hooks end -->\n{close}\n\nA paragraph the user wrote after the example.\n"
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

/// Gemini's context list gains `AGENTS.md` in whatever shape it already
/// has, and never loses what it named: an absent key means Gemini's own
/// default, which stays in front.
#[test]
fn gemini_context_file_is_added_beside_what_is_already_named() {
    let edit = ConfigEdit::GeminiAddContextFile {
        name: "AGENTS.md".into(),
    };
    let named = |text: &str| -> Value {
        let value: Value = serde_json::from_str(&edit.apply(text).unwrap()).unwrap();
        value["context"]["fileName"].clone()
    };
    assert_eq!(named("{}"), json!(["GEMINI.md", "AGENTS.md"]));
    assert_eq!(named(""), json!(["GEMINI.md", "AGENTS.md"]));
    assert_eq!(
        named(r#"{"context": {"fileName": "TEAM.md"}}"#),
        json!(["TEAM.md", "AGENTS.md"])
    );
    assert_eq!(
        named(r#"{"context": {"fileName": ["GEMINI.md", "TEAM.md"]}}"#),
        json!(["GEMINI.md", "TEAM.md", "AGENTS.md"])
    );
    // Already named, as a string or in a list: nothing moves, and the
    // idempotency is what the drift check reads as "in sync".
    let listed = r#"{
  "context": {
    "fileName": [
      "AGENTS.md"
    ]
  }
}
"#;
    assert_eq!(edit.apply(listed).unwrap(), listed);
    let string = r#"{
  "context": {
    "fileName": "AGENTS.md"
  }
}
"#;
    assert_eq!(edit.apply(string).unwrap(), string);
}

/// Every key around the edited one survives, in order, and a key that is
/// neither a string nor a list is refused rather than replaced.
#[test]
fn gemini_context_file_keeps_unrelated_keys_and_refuses_another_shape() {
    let edit = ConfigEdit::GeminiAddContextFile {
        name: "AGENTS.md".into(),
    };
    let start = r#"{
  "theme": "Dark",
  "context": {
    "loadMemoryFromIncludeDirectories": true
  },
  "mcpServers": {
    "gh": {
      "command": "gh-mcp"
    }
  }
}
"#;
    let once = edit.apply(start).unwrap();
    assert_eq!(
        once,
        "{\n  \"theme\": \"Dark\",\n  \"context\": {\n    \"loadMemoryFromIncludeDirectories\": true,\n    \"fileName\": [\n      \"GEMINI.md\",\n      \"AGENTS.md\"\n    ]\n  },\n  \"mcpServers\": {\n    \"gh\": {\n      \"command\": \"gh-mcp\"\n    }\n  }\n}\n"
    );
    assert_eq!(edit.apply(&once).unwrap(), once);

    let refused = edit.apply(r#"{"context": {"fileName": 3}}"#).unwrap_err();
    assert_eq!(refused, "context.fileName is neither a string nor a list");
    // A file that is not JSON is refused in the reader's own words,
    // passed through whole: nothing here wraps or rewrites them.
    let unparseable = edit.apply("{ not json").unwrap_err();
    let readers = serde_json::from_str::<serde_json::Value>("{ not json").unwrap_err();
    assert_eq!(unparseable, readers.to_string());
}
