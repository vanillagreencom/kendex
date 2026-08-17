//! OpenCode's config: what counts as vstack's own registration in it, and
//! what a write to it is allowed to change. OpenCode parses every spelling
//! of the file as JSONC, so the user's comments are content vstack carries
//! across an install or a removal — never content it serializes away.

use super::super::tests::{hook_fixture, tmpdir};
use super::{install_hook_opencode_at_path, remove_hook_from_opencode_json_at_path};

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

/// `opencode.json` gets the same rule as the hook registrations: a container
/// vstack merges into, holding a value of the wrong shape, is UNREADABLE.
/// Both writers used to reach straight through it — `permission` and
/// `instructions` were unwrapped as an object and an array whatever they held
/// — so a config a user had reshaped crashed the install outright instead of
/// refusing it.
#[test]
fn install_and_remove_refuse_an_opencode_config_shape_they_cannot_merge_into() {
    let hook = hook_fixture("guard", "PreToolUse", Some("Bash"));
    for (case, malformed) in [
        (
            "instructions is a string",
            r#"{"instructions": "AGENTS.md"}"#,
        ),
        ("permission is a string", r#"{"permission": "ask"}"#),
        ("root is an array", r#"["AGENTS.md"]"#),
    ] {
        let base = tmpdir("opencode_shape");
        let config_path = base.join("opencode.json");
        let instruction_path = base.join("instructions").join("vstack-hook-guard.md");
        let instruction_ref = "instructions/vstack-hook-guard.md";
        std::fs::write(&config_path, malformed).unwrap();

        let err =
            install_hook_opencode_at_path(&hook, &config_path, &instruction_path, instruction_ref)
                .expect_err("install must refuse a config shape it cannot merge into");
        assert!(
            format!("{err:#}").contains(&config_path.display().to_string()),
            "{case}: the refusal names the file: {err:#}"
        );
        assert_eq!(
            std::fs::read_to_string(&config_path).unwrap(),
            malformed,
            "{case}: the config must be byte-identical after a refusal"
        );

        remove_hook_from_opencode_json_at_path(
            &config_path,
            &instruction_path,
            instruction_ref,
            "guard",
        )
        .expect_err("removal must refuse it too");
        assert_eq!(
            std::fs::read_to_string(&config_path).unwrap(),
            malformed,
            "{case}: removal must not rewrite it either"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    // Control: the same containers in their real shapes are merged into, and
    // what the user already had in them survives.
    let base = tmpdir("opencode_shape_control");
    let config_path = base.join("opencode.json");
    let instruction_path = base.join("instructions").join("vstack-hook-guard.md");
    let instruction_ref = "instructions/vstack-hook-guard.md";
    std::fs::write(
        &config_path,
        r#"{"instructions": ["AGENTS.md"], "permission": {"edit": "deny"}}"#,
    )
    .unwrap();
    install_hook_opencode_at_path(&hook, &config_path, &instruction_path, instruction_ref).unwrap();
    let written: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&config_path).unwrap()).unwrap();
    assert_eq!(
        written["instructions"],
        serde_json::json!(["AGENTS.md", instruction_ref]),
        "the user's instruction survives: {written}"
    );
    assert_eq!(
        written["permission"]["edit"],
        serde_json::json!("deny"),
        "and so does their permission: {written}"
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

/// Removal deletes the reference vstack WROTE, decided by the file an entry
/// resolves to — the same predicate `opencode_hook_registration` reads it
/// back with. It used to split the hook's name on `-` and drop any entry whose
/// text held every fragment, so removing `block-bare-cd` also deleted the
/// user's own instruction files, and a `vstack-hook-` substring anywhere in a
/// path counted as vstack's own.
#[test]
fn remove_hook_from_opencode_matches_the_path_not_the_words_in_it() {
    let base = tmpdir("opencode_wordmatch");
    let config_path = base.join("opencode.json");
    let instruction_path = base
        .join("instructions")
        .join("vstack-hook-block-bare-cd.md");
    std::fs::create_dir_all(instruction_path.parent().unwrap()).unwrap();
    std::fs::write(&instruction_path, "# Safety").unwrap();
    let instruction_ref = "instructions/vstack-hook-block-bare-cd.md";

    // The user's own instructions, each carrying every fragment of the hook's
    // name, plus one that merely mentions vstack hooks in its file name.
    let mine = "docs/block-a-bare-cdn.md";
    let also_mine = "docs/cd-blocks-and-bare-metal.md";
    let named_like_ours = "docs/why-i-dropped-vstack-hook-support.md";
    std::fs::write(
        &config_path,
        serde_json::to_string_pretty(&serde_json::json!({
            "instructions": [mine, instruction_ref, also_mine, named_like_ours],
            "permission": { "bash": { "*": "ask" } },
        }))
        .unwrap(),
    )
    .unwrap();

    remove_hook_from_opencode_json_at_path(
        &config_path,
        &instruction_path,
        instruction_ref,
        "block-bare-cd",
    )
    .unwrap();

    let written: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&config_path).unwrap()).unwrap();
    assert_eq!(
        written["instructions"],
        serde_json::json!([mine, also_mine, named_like_ours]),
        "only vstack's own reference may go: {written}"
    );
    // No vstack hook instruction is left, so the bash restriction goes with
    // it — the lookalike file name must not have held it in place.
    assert!(
        written.get("permission").is_none(),
        "a lookalike path kept the bash restriction alive: {written}"
    );
    let _ = std::fs::remove_dir_all(&base);
}

/// A hand-spelled but still-correct path is vstack's registration — the reader
/// accepts it, so the remover must delete it.
#[test]
fn remove_hook_from_opencode_removes_an_equivalent_spelling_of_its_own_entry() {
    let base = tmpdir("opencode_equivalent");
    let config_path = base.join("opencode.json");
    let instruction_path = base.join("instructions").join("vstack-hook-guard.md");
    std::fs::create_dir_all(instruction_path.parent().unwrap()).unwrap();
    std::fs::write(&instruction_path, "# Safety").unwrap();
    std::fs::write(
        &config_path,
        serde_json::to_string_pretty(&serde_json::json!({
            "instructions": ["./instructions/./vstack-hook-guard.md"],
        }))
        .unwrap(),
    )
    .unwrap();

    remove_hook_from_opencode_json_at_path(
        &config_path,
        &instruction_path,
        "instructions/vstack-hook-guard.md",
        "guard",
    )
    .unwrap();

    let written: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&config_path).unwrap()).unwrap();
    assert!(
        written.get("instructions").is_none(),
        "an equivalent spelling of our own entry must go: {written}"
    );
    let _ = std::fs::remove_dir_all(&base);
}

/// The file OpenCode actually loads, written back with everything OpenCode
/// lets the user put in it.
///
/// OpenCode parses its config as JSONC, so comments and a trailing comma are
/// a working config, not a broken one — and reading it with a strict parser
/// reported a live install as unverifiable and then refused every write to it.
/// Reading it right is only half: a writer that serializes a
/// `serde_json::Value` back over the file deletes every comment on the first
/// `vstack add`. Both halves are asserted here, on both spellings, because
/// OpenCode reads `opencode.json` and `opencode.jsonc` through the same
/// parser and so must vstack.
#[test]
fn opencode_writes_keep_every_comment_the_harness_reads_past() {
    for spelling in ["opencode.jsonc", "opencode.json"] {
        let base = tmpdir(&format!("opencode_jsonc_{}", spelling.replace('.', "_")));
        let config_path = base.join(spelling);
        let instruction_path = base.join("instructions").join("vstack-hook-guard.md");
        let instruction_ref = "instructions/vstack-hook-guard.md";
        let hook = hook_fixture("guard", "PreToolUse", Some("Bash"));

        // A comment on its own line, a trailing comment, a blank line, and a
        // trailing comma — every JSONC affordance OpenCode honors.
        let original = concat!(
            "{\n",
            "  // why we pin the model\n",
            "  \"model\": \"anthropic/claude\", // and not the other one\n",
            "\n",
            "  /* the agents block is generated */\n",
            "  \"agent\": {},\n",
            "}\n",
        );
        std::fs::write(&config_path, original).unwrap();

        install_hook_opencode_at_path(&hook, &config_path, &instruction_path, instruction_ref)
            .unwrap();

        let installed = std::fs::read_to_string(&config_path).unwrap();
        for comment in [
            "// why we pin the model",
            "// and not the other one",
            "/* the agents block is generated */",
        ] {
            assert!(
                installed.contains(comment),
                "{spelling}: install destroyed {comment:?}: {installed}"
            );
        }
        assert!(
            installed.contains(instruction_ref),
            "{spelling}: install must register the instruction file: {installed}"
        );
        assert!(
            installed.ends_with("\n") && !installed.ends_with("\n\n"),
            "{spelling}: exactly one trailing newline: {installed:?}"
        );

        // The registration reads back off the same file, which is what
        // `check` and `verify` ask.
        let parsed = crate::json_config::read(&config_path, &crate::json_config::OPENCODE_CONFIG)
            .unwrap_or_else(|err| panic!("{spelling}: must stay readable: {err:#}"))
            .unwrap_or_else(|| panic!("{spelling}: must read as a document"));
        assert_eq!(
            parsed.get("model").and_then(|m| m.as_str()),
            Some("anthropic/claude"),
            "{spelling}: the user's own keys survive: {parsed}"
        );

        // A second install changes nothing at all — not one byte of the
        // user's formatting drifts per run.
        install_hook_opencode_at_path(&hook, &config_path, &instruction_path, instruction_ref)
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(&config_path).unwrap(),
            installed,
            "{spelling}: a second install rewrote the file"
        );

        remove_hook_from_opencode_json_at_path(
            &config_path,
            &instruction_path,
            instruction_ref,
            "guard",
        )
        .unwrap();

        let removed = std::fs::read_to_string(&config_path).unwrap();
        for comment in [
            "// why we pin the model",
            "// and not the other one",
            "/* the agents block is generated */",
        ] {
            assert!(
                removed.contains(comment),
                "{spelling}: removal destroyed {comment:?}: {removed}"
            );
        }
        assert!(
            !removed.contains(instruction_ref),
            "{spelling}: removal must drop the registration: {removed}"
        );
        assert!(
            !removed.contains("\"permission\""),
            "{spelling}: removal must drop the bash rule it added: {removed}"
        );
        let _ = std::fs::remove_dir_all(&base);
    }
}

/// The other direction of the same rule: JSONC is what OPENCODE accepts, not
/// a blanket relaxation. A syntax error OpenCode drops the whole file on is
/// still a file vstack refuses to rewrite.
#[test]
fn an_opencode_config_opencode_itself_rejects_is_still_unreadable() {
    for (label, body) in [
        ("truncated", "{\"instructions\": [\n"),
        // JSON5-ward shapes OpenCode's parser does not take. Accepting them
        // would read a config OpenCode silently ignores as live.
        ("single quotes", "{'instructions': []}\n"),
        ("unquoted key", "{instructions: []}\n"),
        ("hex number", "{\"timeout\": 0xFF}\n"),
    ] {
        let base = tmpdir(&format!("opencode_reject_{}", label.replace(' ', "_")));
        let config_path = base.join("opencode.jsonc");
        std::fs::write(&config_path, body).unwrap();

        let err = crate::json_config::read(&config_path, &crate::json_config::OPENCODE_CONFIG)
            .expect_err("a config opencode drops must not read as a document");
        assert!(
            format!("{err:#}").contains("opencode.jsonc"),
            "{label}: the refusal names the file: {err:#}"
        );

        let hook = hook_fixture("guard", "PreToolUse", Some("Bash"));
        let instruction_path = base.join("instructions").join("vstack-hook-guard.md");
        assert!(
            install_hook_opencode_at_path(
                &hook,
                &config_path,
                &instruction_path,
                "instructions/vstack-hook-guard.md"
            )
            .is_err(),
            "{label}: install must refuse a config it cannot parse"
        );
        assert_eq!(
            std::fs::read_to_string(&config_path).unwrap(),
            body,
            "{label}: the refused file is byte-identical"
        );
        let _ = std::fs::remove_dir_all(&base);
    }
}
