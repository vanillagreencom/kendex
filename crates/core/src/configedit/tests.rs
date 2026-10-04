use super::*;

/// A disabled catalog hook supplies a removal even before its registry exists.
/// Control: serializing an unchanged empty JSON object creates a registry.
#[test]
fn hook_removals_preserve_an_absent_registry() {
    let removals = [
        ConfigEdit::RemoveHook {
            event: Some("PreToolUse".into()),
            matcher: Some("Bash".into()),
            command: "guard".into(),
        },
        ConfigEdit::RemoveCopilotHook {
            event: Some("preToolUse".into()),
            matcher: Some("shell".into()),
            command: "guard".into(),
        },
        ConfigEdit::RemoveAntigravityHook {
            name: Some("guard".into()),
            event: Some("preToolUse".into()),
            matcher: Some("shell".into()),
            command: "guard".into(),
        },
    ];
    for edit in removals {
        assert_eq!(edit.apply(""), Ok(String::new()), "{edit:?}");
    }
}

#[test]
fn copilot_hook_commands_are_reconciled_by_script_path() {
    use crate::engine::targets::{HookTarget, hook_target};
    use crate::env::{Env, FakeOs};
    use crate::model::{HarnessId, Scope};
    let env = Env::fake("/h", FakeOs::Linux);
    let scope = Scope::Project { root: "/p".into() };
    let Some(HookTarget::Script { command, .. }) =
        hook_target(&env, &scope, HarnessId::Copilot, "guard", None)
    else {
        panic!("copilot hooks are script targets");
    };
    let old = "p='.github/hooks/guard.sh'; r=$(cd -P . && pwd); bash \"$r/$p\"";
    let stale = json!({"type": "command", "bash": old, "matcher": "shell"});
    let current = json!({"type": "command", "bash": command, "matcher": "shell", "timeoutSec": 10});
    let foreign = json!({"type": "command", "bash": "p='.github/hooks/mine.sh'; bash \"$r/$p\"", "matcher": "shell"});
    let other_matcher = json!({"type": "command", "bash": old, "matcher": "read"});
    for entries in [json!([stale]), json!([stale, current])] {
        let start = json!({"version": 1, "hooks": {
            "preToolUse": entries,
            "postToolUse": [stale]
        }});
        let start = start.to_string();
        let edit = ConfigEdit::UpsertCopilotHook {
            event: "preToolUse".into(),
            matcher: Some("shell".into()),
            command: command.clone(),
            timeout: Some(10),
        };
        let once = edit.apply(&start).unwrap();
        let value: Value = serde_json::from_str(&once).unwrap();
        assert_eq!(value["hooks"]["preToolUse"], json!([current]));
        assert_eq!(value["hooks"]["postToolUse"], json!([stale]));
        assert_eq!(edit.apply(&once).unwrap(), once);
        let control = json!({"hooks": {"preToolUse": [stale, foreign, other_matcher]}});
        let upserted: Value =
            serde_json::from_str(&edit.apply(&control.to_string()).unwrap()).unwrap();
        assert_eq!(
            upserted["hooks"]["preToolUse"],
            json!([current, foreign, other_matcher])
        );
        let removed = ConfigEdit::RemoveCopilotHook {
            event: Some("preToolUse".into()),
            matcher: Some("shell".into()),
            command: command.clone(),
        };
        let value: Value =
            serde_json::from_str(&removed.apply(&control.to_string()).unwrap()).unwrap();
        assert_eq!(
            value["hooks"]["preToolUse"],
            json!([foreign, other_matcher])
        );
    }
}

#[test]
fn json_array_member_is_lossless_idempotent_and_refuses_wrong_shapes() {
    let edit = |present| ConfigEdit::SetJsonArrayMember {
        key: "disabledMcpServers".into(),
        name: "githubiq".into(),
        present,
    };
    let before = json!({"theme": "dark", "disabledMcpServers": ["other"]});
    let text = format!("{before}\n");
    let off = edit(true).apply(&text).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&off).unwrap(),
        json!({"theme":"dark", "disabledMcpServers":["other", "githubiq"]})
    );
    assert_eq!(edit(true).apply(&off).unwrap(), off);
    let on = edit(false).apply(&off).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&on).unwrap(), before);
    assert_eq!(edit(false).apply(&on).unwrap(), on);
    // Copilot's settings reader accepts user comments and trailing commas,
    // but the shared JSON editor cannot preserve them.
    for text in [
        "// settings\n{\"disabledMcpServers\":[\"githubiq\"]}\n",
        "{\"disabledMcpServers\":[\"githubiq\"],}\n",
    ] {
        for present in [true, false] {
            assert!(
                edit(present).apply(text).is_err(),
                "non-strict JSON edit must refuse"
            );
            assert!(
                edit(present).in_sync(text).is_err(),
                "non-strict JSON sync must refuse"
            );
        }
    }
    for value in [json!(false), json!(["other", 7])] {
        for present in [true, false] {
            assert!(
                edit(present)
                    .apply(&json!({"disabledMcpServers":value}).to_string())
                    .is_err()
            );
        }
    }
}

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
        let Some(HookTarget::Script { command, .. }) =
            hook_target(&env, &scope, harness, "guard", None)
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

/// A Claude Code entry written before its command opened with the Copilot
/// skip is the same registration: a refresh replaces it where it stands and a
/// removal takes it, so it never runs beside the entry that replaced it. The
/// person's own command naming another script is not claimed.
#[test]
fn a_claude_hook_entry_without_the_copilot_skip_is_the_same_registration() {
    use crate::engine::targets::{CLAUDE_OUTSIDE_COPILOT, HookTarget, hook_target};
    use crate::env::{Env, FakeOs};
    use crate::model::{HarnessId, Scope};
    let env = Env::fake("/h", FakeOs::Linux);
    for scope in [Scope::Project { root: "/p".into() }, Scope::Global] {
        let Some(HookTarget::Script { command, .. }) =
            hook_target(&env, &scope, HarnessId::Claude, "guard", None)
        else {
            panic!("claude hooks are script targets");
        };
        let old = command.strip_prefix(CLAUDE_OUTSIDE_COPILOT).unwrap();
        let user = json!({"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/mine.sh\""});
        let stale = json!({"type": "command", "command": old});
        let current = json!({"type": "command", "command": command, "timeout": 10});
        for (handlers, expected) in [
            (json!([stale, user]), json!([current, user])),
            (json!([stale, user, current]), json!([current, user])),
        ] {
            let mut events = json!({"PreToolUse": [{"matcher": "Bash", "hooks": handlers}]});
            let mut removed = events.clone();
            let events = events.as_object_mut().unwrap();
            nested::upsert_in(events, "PreToolUse", Some("Bash"), &command, Some(10)).unwrap();
            assert_eq!(events["PreToolUse"][0]["hooks"], expected, "{scope:?}");
            let removed = removed.as_object_mut().unwrap();
            nested::remove_in(removed, "PreToolUse", Some("Bash"), &command);
            assert_eq!(
                removed["PreToolUse"][0]["hooks"],
                json!([user]),
                "{scope:?}"
            );
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
fn an_empty_matcher_is_registered_as_the_absent_key() {
    let ours = json!({"type": "command", "command": "bash halt.sh"});
    let theirs = json!({"type": "command", "command": "other"});
    for (matcher, start, expected) in [
        (Some(""), json!({}), json!([{"hooks": [ours]}])),
        (None, json!({}), json!([{"hooks": [ours]}])),
        (
            Some(""),
            json!({"PreToolUse": [{"matcher": "", "hooks": [ours]}]}),
            json!([{"hooks": [ours]}]),
        ),
        (
            None,
            json!({"PreToolUse": [{"matcher": "", "hooks": [theirs, ours]}]}),
            json!([{"hooks": [theirs, ours]}]),
        ),
        (
            None,
            json!({"PreToolUse": [{"matcher": "", "hooks": [theirs]}]}),
            json!([{"hooks": [theirs, ours]}]),
        ),
        (
            Some("Bash"),
            json!({"PreToolUse": [{"matcher": "", "hooks": [ours]}]}),
            json!([{"matcher": "", "hooks": [ours]}, {"matcher": "Bash", "hooks": [ours]}]),
        ),
    ] {
        let mut events = start.clone();
        let events = events.as_object_mut().unwrap();
        nested::upsert_in(events, "PreToolUse", matcher, "bash halt.sh", None).unwrap();
        assert_eq!(events["PreToolUse"], expected, "{matcher:?} over {start}");
    }
    let untouched = json!({"Stop": [{"matcher": "", "hooks": [theirs]}]});
    let mut events = untouched.clone();
    let events = events.as_object_mut().unwrap();
    nested::upsert_in(events, "PreToolUse", Some(""), "bash halt.sh", None).unwrap();
    assert_eq!(events["Stop"], untouched["Stop"]);
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

/// A block that already stands keeps its place: refreshing it rewrites only
/// its own lines, and keeping it unchanged returns every byte, so a style
/// block after it stays where it was.
#[test]
fn an_existing_marker_block_is_replaced_where_it_stands() {
    let style = "<!-- kendex:append-system output-style-STE begin -->\nStyle.\n<!-- kendex:append-system output-style-STE end -->\n";
    let package = "<!-- kendex:append-system pi-hooks begin -->\nold body\n<!-- kendex:append-system pi-hooks end -->\n";
    let file = format!("# Notes\n\n{package}\n{style}");
    assert_eq!(upsert_marker_block(&file, "pi-hooks", "old body"), file);
    assert_eq!(
        upsert_marker_block(&file, "pi-hooks", "new body"),
        file.replace("old body", "new body")
    );
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

/// The removal takes back exactly what the add writes over an absent key,
/// and `context` with it where nothing else is left there. A value the add
/// cannot have written alone may hold the person's own choices and stays.
#[test]
fn gemini_context_file_removal_takes_back_only_what_the_add_wrote() {
    let edit = ConfigEdit::GeminiRemoveContextFile {
        name: "AGENTS.md".into(),
    };
    let after = |text: &str| -> Value { serde_json::from_str(&edit.apply(text).unwrap()).unwrap() };
    let rows: [(&str, Value); 5] = [
        (
            r#"{"context": {"fileName": ["GEMINI.md", "AGENTS.md"]}}"#,
            json!({}),
        ),
        (
            r#"{"ui": {"theme": "Dark"}, "context": {"fileName": ["GEMINI.md", "AGENTS.md"], "loadMemoryFromIncludeDirectories": true}}"#,
            json!({"ui": {"theme": "Dark"}, "context": {"loadMemoryFromIncludeDirectories": true}}),
        ),
        (
            r#"{"context": {"fileName": ["GEMINI.md", "TEAM.md", "AGENTS.md"]}}"#,
            json!({"context": {"fileName": ["GEMINI.md", "TEAM.md", "AGENTS.md"]}}),
        ),
        (
            r#"{"context": {"fileName": "AGENTS.md"}}"#,
            json!({"context": {"fileName": "AGENTS.md"}}),
        ),
        (r#"{"context": 3}"#, json!({"context": 3})),
    ];
    for (start, left) in rows {
        assert_eq!(after(start), left, "{start}");
    }
}

/// A JSON document a removal empties is retired rather than written, in a
/// project; a document the person left empty, one an upsert writes, one
/// holding a key of theirs and a file that is not JSON are not. The
/// OpenCode cleanup retires a lone schema whatever it held before. A text
/// file a marker block sits in is a Pi append file and follows its rule:
/// it goes once nothing of the person's is left in it.
#[test]
fn a_document_a_removal_empties_is_retired() {
    let gemini = ConfigEdit::GeminiRemoveContextFile {
        name: "AGENTS.md".into(),
    };
    let ours = r#"{"context": {"fileName": ["GEMINI.md", "AGENTS.md"]}}"#;
    let prune = ConfigEdit::OpencodePruneInstructions {
        prefix: ".agents/".into(),
        keep: Default::default(),
    };
    let block = upsert_marker_block("", "x", "kendex's block");
    let beside = upsert_marker_block("The person's line.\n", "x", "kendex's block");
    let rows: [(&str, Vec<ConfigEdit>, &str, bool, bool); 8] = [
        (
            "emptied in a project",
            vec![gemini.clone()],
            ours,
            true,
            true,
        ),
        (
            "emptied, personal",
            vec![gemini.clone()],
            ours,
            false,
            false,
        ),
        (
            "left empty by the person",
            vec![gemini.clone()],
            "{}",
            true,
            false,
        ),
        (
            "a key of theirs",
            vec![gemini.clone()],
            r#"{"ui": {}, "context": {"fileName": ["GEMINI.md", "AGENTS.md"]}}"#,
            true,
            false,
        ),
        (
            "an upsert",
            vec![ConfigEdit::UpsertMcpServer {
                name: "gh".into(),
                value: json!({"command": "gh"}),
            }],
            "{}",
            true,
            false,
        ),
        (
            "a lone schema under the OpenCode cleanup",
            vec![prune],
            r#"{"$schema": "https://opencode.ai/config.json"}"#,
            false,
            true,
        ),
        (
            "a text file a removal leaves blank",
            vec![ConfigEdit::RemoveMarkerBlock { name: "x".into() }],
            &block,
            false,
            true,
        ),
        (
            "a text file holding the person's line",
            vec![ConfigEdit::RemoveMarkerBlock { name: "x".into() }],
            &beside,
            true,
            false,
        ),
    ];
    for (what, edits, current, emptied, retired) in rows {
        assert_eq!(
            ConfigEdit::removes_empty_document(&edits, Some(current), emptied).unwrap(),
            retired,
            "{what}"
        );
    }
}

/// The same retirement for a TOML document: Codex's config left with no
/// key or table. The `[features] hooks = true` kendex turns on stays, since
/// nothing tells it from the person's own setting, and so does a file left
/// holding the person's comments, which the table does not show.
#[test]
fn a_toml_document_a_removal_empties_is_retired() {
    let codex = ConfigEdit::RemoveCodexMcpServer { name: "gh".into() };
    let codex_ours = "[mcp_servers.gh]\ncommand = \"gh\"\n";
    let codex_mine = "model = \"o3\"\n\n[mcp_servers.gh]\ncommand = \"gh\"\n";
    let codex_hooks = "[features]\nhooks = true\n\n[mcp_servers.gh]\ncommand = \"gh\"\n";
    let codex_notes = "[mcp_servers.gh]\ncommand = \"gh\"\n\n# my notes\n";
    assert_eq!(codex.apply(codex_notes).unwrap().trim(), "# my notes");
    let rows: [(&str, Vec<ConfigEdit>, &str, bool, bool); 6] = [
        (
            "TOML emptied in a project",
            vec![codex.clone()],
            codex_ours,
            true,
            true,
        ),
        (
            "TOML emptied, personal",
            vec![codex.clone()],
            codex_ours,
            false,
            false,
        ),
        (
            "TOML holding the person's key",
            vec![codex.clone()],
            codex_mine,
            true,
            false,
        ),
        (
            "TOML keeping the hooks feature",
            vec![codex.clone()],
            codex_hooks,
            true,
            false,
        ),
        (
            "TOML keeping the person's comment",
            vec![codex.clone()],
            codex_notes,
            true,
            false,
        ),
        (
            "TOML left empty by the person",
            vec![codex],
            "",
            true,
            false,
        ),
    ];
    for (what, edits, current, emptied, retired) in rows {
        assert_eq!(
            ConfigEdit::removes_empty_document(&edits, Some(current), emptied).unwrap(),
            retired,
            "{what}"
        );
    }
}

#[test]
fn output_style_selection_is_absent_only_and_removal_is_owned() {
    let insert = ConfigEdit::ClaudeOutputStyle { name: "STE".into() };
    let remove = ConfigEdit::RemoveClaudeOutputStyle { name: "STE".into() };
    for current in [
        "{\"outputStyle\":\"Learning\"}\n",
        "{\"outputStyle\":null}\n",
        "{\"outputStyle\":\"\"}\n",
    ] {
        assert_eq!(insert.apply(current).unwrap(), current);
        assert_eq!(remove.apply(current).unwrap(), current);
    }
    let created = insert.apply("{\"model\":\"opus\"}\n").unwrap();
    let value: Value = serde_json::from_str(&created).unwrap();
    assert_eq!(value["outputStyle"], "STE");
    assert_eq!(value["model"], "opus");
    assert_eq!(insert.apply(&created).unwrap(), created);
    let removed: Value = serde_json::from_str(&remove.apply(&created).unwrap()).unwrap();
    assert!(removed.get("outputStyle").is_none());
    assert_eq!(removed["model"], "opus");
    assert!(insert.apply("[]").is_err());
}

#[test]
fn style_block_observation_uses_the_editors_fence_boundaries() {
    let marker = "output-style-STE";
    let example = "```md\n<!-- kendex:append-system output-style-STE begin -->\nExample.\n<!-- kendex:append-system output-style-STE end -->\n```\n";
    assert!(style_blocks(example).is_empty());
    let actual = upsert_marker_block(example, marker, "Real instructions.");
    assert_eq!(style_blocks(&actual), vec!["STE"]);
    assert_eq!(
        marker_block(&actual, marker),
        Some(
            "<!-- kendex:append-system output-style-STE begin -->\nReal instructions.\n<!-- kendex:append-system output-style-STE end -->\n"
        )
    );
    assert_eq!(remove_marker_block(&actual, marker), example);
}
