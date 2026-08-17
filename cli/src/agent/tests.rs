//! Agent parsing, frontmatter, and the user sections a generated file
//! preserves.

use super::*;

#[test]
fn model_id_for_maps_canonical_tiers_per_provider() {
    assert_eq!(model_id_for("claude-code", "sonnet"), "sonnet");
    assert_eq!(model_id_for("claude-code", "opus"), "inherit");
    assert_eq!(model_id_for("openai", "sonnet"), "openai/gpt-5.6-sol");
    assert_eq!(
        model_id_for("anthropic", "sonnet"),
        "anthropic/claude-sonnet-5"
    );
    // Exact ids and slash-qualified ids always pass through unchanged.
    assert_eq!(
        model_id_for("anthropic", "claude-sonnet-4-6"),
        "claude-sonnet-4-6"
    );
    assert_eq!(
        model_id_for("openai", "openai-codex/gpt-5.6-sol"),
        "openai-codex/gpt-5.6-sol"
    );
}

#[test]
#[cfg(unix)]
fn reference_freshness_rejects_symlink_even_with_matching_target() {
    let dir = std::env::temp_dir().join(format!(
        "vstack_test_ref_symlink_{}_{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let target = dir.join("external.md");
    std::fs::write(&target, FAILURE_REPORTING_DOC).unwrap();

    let regular = dir.join("regular.md");
    std::fs::write(&regular, FAILURE_REPORTING_DOC).unwrap();
    assert!(reference_is_fresh(&regular));

    let link = dir.join("link.md");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    // A symlink is never fresh, even when its target matches: accepting it
    // would leave the reference externally mutable after generation.
    assert!(!reference_is_fresh(&link));

    std::fs::write(&regular, "tampered").unwrap();
    assert!(!reference_is_fresh(&regular));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn extract_section_skips_header_occurrence_inside_marked_region() {
    use crate::project_config::ProjectConfig;
    // Shared launch text contains the literal header of a LATER section.
    let shared = "Read this.\n\n## Additional Instructions\n\nShared tail.";
    let launch = ProjectConfig::merge_marked_shared_and_specific(Some(shared), None).unwrap();
    let content = format!(
        "# Agent\n\n## Launch Instructions\n\n{launch}\n\n## Additional Instructions\n\nReal specific text.\n"
    );
    // The nested occurrence inside the marked region must not be selected
    // as the section header — the real appended section is.
    assert_eq!(
        extract_section(&content, "## Additional Instructions").as_deref(),
        Some("Real specific text.")
    );
    // And the launch section keeps its full marked region.
    let launch_extracted = extract_section(&content, "## Launch Instructions").unwrap();
    assert!(launch_extracted.contains("Shared tail."));
    assert!(
        ProjectConfig::strip_shared_block(Some(shared), &launch_extracted).is_none(),
        "extracted launch section is shared-only; stripping must leave nothing"
    );
}

#[test]
fn extract_section_keeps_marked_shared_region_with_nested_headings() {
    use crate::project_config::ProjectConfig;
    let shared = "Fleet rules.\n\n## Escalation\n\nPing the owner.";
    let body =
        ProjectConfig::merge_marked_shared_and_specific(Some(shared), Some("Own text.")).unwrap();
    let content =
        format!("# Agent\n\n## Additional Instructions\n\n{body}\n\n## Hook Rules\n\nSome hook.\n");
    let extracted = extract_section(&content, "## Additional Instructions").unwrap();
    // The `## Escalation` heading inside the marked region must not
    // terminate extraction: both markers and the specific text survive.
    assert!(extracted.contains(crate::project_config::SHARED_INSTRUCTIONS_END));
    assert!(extracted.contains("Own text."));
    assert!(!extracted.contains("Some hook."));
    // Round trip: stripping the marked region leaves only the specific text.
    assert_eq!(
        ProjectConfig::strip_shared_block(Some(shared), &extracted).as_deref(),
        Some("Own text.")
    );
}

#[test]
fn parse_agent() {
    let content = r#"---
name: test-agent
description: A test agent
model: opus
role: reviewer
color: red
---

# Test Agent

Does testing things.
"#;
    let agent = Agent::parse(content).unwrap();
    assert_eq!(agent.name, "test-agent");
    assert_eq!(agent.role, AgentRole::Reviewer);
    assert!(agent.body.contains("# Test Agent"));
}

#[test]
fn match_skills_by_prefix() {
    let available = vec![
        "rust-tooling".into(),
        "rust-runtime".into(),
        "python-web".into(),
        "dev".into(),
        "github".into(),
        "worktree".into(),
    ];
    let matched = match_skills("rust", &AgentRole::Engineer, &available);
    assert!(matched.contains(&"rust-tooling".to_string()));
    assert!(matched.contains(&"rust-runtime".to_string()));
    assert!(!matched.contains(&"python-web".to_string()));
    // Engineer gets workflow skills
    assert!(matched.contains(&"dev".to_string()));
    assert!(matched.contains(&"github".to_string()));
    assert!(matched.contains(&"worktree".to_string()));
}

#[test]
fn match_skills_reviewer_prefix_strip() {
    let available = vec!["rust-tooling".into(), "rust-runtime".into(), "dev".into()];
    let matched = match_skills("reviewer-rust", &AgentRole::Reviewer, &available);
    assert!(matched.contains(&"rust-tooling".to_string()));
    assert!(matched.contains(&"rust-runtime".to_string()));
    assert!(matched.contains(&"dev".to_string()));
}

#[test]
fn match_hooks_engineer_gets_all() {
    let hooks = vec![
        crate::hook::Hook {
            name: "h1".into(),
            event: "PreToolUse".into(),
            matcher: Some("Bash".into()),
            description: "".into(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: "".into(),
            source_path: std::path::PathBuf::new(),
        },
        crate::hook::Hook {
            name: "h2".into(),
            event: "PostToolUse".into(),
            matcher: Some("Edit|Write".into()),
            description: "".into(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: "".into(),
            source_path: std::path::PathBuf::new(),
        },
    ];
    let matched = match_hooks(&AgentRole::Engineer, &hooks);
    assert_eq!(matched.len(), 2);
}

#[test]
fn match_hooks_reviewer_filters() {
    let hooks = vec![
        crate::hook::Hook {
            name: "h1".into(),
            event: "PreToolUse".into(),
            matcher: Some("Bash".into()),
            description: "".into(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: "".into(),
            source_path: std::path::PathBuf::new(),
        },
        crate::hook::Hook {
            name: "h2".into(),
            event: "PostToolUse".into(),
            matcher: Some("Edit|Write".into()),
            description: "".into(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: "".into(),
            source_path: std::path::PathBuf::new(),
        },
        crate::hook::Hook {
            name: "h3".into(),
            event: "PostCompact".into(),
            matcher: None,
            description: "".into(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: "".into(),
            source_path: std::path::PathBuf::new(),
        },
    ];
    let matched = match_hooks(&AgentRole::Reviewer, &hooks);
    // Should get h1 (Bash PreToolUse) and h3 (PostCompact), but not h2 (Edit|Write)
    assert_eq!(matched.len(), 2);
    assert!(matched.iter().any(|h| h.name == "h1"));
    assert!(matched.iter().any(|h| h.name == "h3"));
}

#[test]
fn load_skills_section_emits_directive_only() {
    // The preamble is emitted unconditionally because the harness
    // injects available skill name+description into the agent's context
    // (pi `<available_skills>`, codex initial list, opencode `skill`
    // tool description, claude Skill tool description). The body just
    // needs the one-line directive to load by description match.
    let section = load_skills_section();
    assert!(section.contains("## Skills"));
    assert!(section.contains("Load any skill whose name or description matches"));
    assert!(section.contains("Skill descriptions are listed by the harness"));
}

#[test]
fn guidance_section_renders() {
    let section = guidance_section(Some("Read the open issues and start working."));
    assert!(section.contains("## Launch Instructions"));
    assert!(section.contains("Read the open issues and start working."));
}

#[test]
fn guidance_section_empty_on_none() {
    assert_eq!(guidance_section(None), String::new());
    assert_eq!(guidance_section(Some("")), String::new());
}

#[test]
fn instructions_section_renders() {
    let section = instructions_section(Some("Always run clippy."));
    assert!(section.contains("## Additional Instructions"));
    assert!(section.contains("Always run clippy."));
}

#[test]
fn instructions_section_empty_on_none() {
    assert_eq!(instructions_section(None), String::new());
    assert_eq!(instructions_section(Some("")), String::new());
}

#[test]
fn append_section_adds_to_end() {
    let body = "# Title\n\nSome content.\n";
    let section = "## Extra\n\nMore stuff.\n";
    let result = append_section(body, section);
    assert!(result.ends_with("More stuff.\n"));
    assert!(result.contains("Some content."));
}

#[test]
fn append_section_noop_when_empty() {
    let body = "# Title\n\nContent.\n";
    assert_eq!(append_section(body, ""), body.to_string());
}

#[test]
fn extract_user_sections_both() {
    let content = r#"# Agent

Some intro.

## When to Use

Use for backend services.

## Load These Skills

- **Skill** → `skill-name`

## Capabilities

Does stuff.

## Additional Instructions

Always run clippy.
"#;
    let extras = extract_user_sections(content);
    assert_eq!(
        extras.guidance.as_deref(),
        Some("Use for backend services.")
    );
    assert_eq!(extras.instructions.as_deref(), Some("Always run clippy."));
}

#[test]
fn extract_user_sections_none() {
    let content = "# Agent\n\nJust an intro.\n\n## Capabilities\n\nDoes stuff.\n";
    let extras = extract_user_sections(content);
    assert!(extras.guidance.is_none());
    assert!(extras.instructions.is_none());
}

#[test]
fn frontmatter_overrides_merge_allowed_subagents_with_harness_winning() {
    let base = AgentFrontmatterOverrides {
        allowed_subagents: Some(vec!["base-target".into()]),
        ..Default::default()
    };
    let harness = AgentFrontmatterOverrides {
        allowed_subagents: Some(vec!["harness-target".into()]),
        ..Default::default()
    };
    let merged = base.merge(&harness);
    assert_eq!(
        merged.allowed_subagents,
        Some(vec!["harness-target".to_string()]),
        "harness override should win, including its full list"
    );
}

#[test]
fn frontmatter_overrides_merge_preserves_explicit_empty_allowed_subagents() {
    // An explicit empty list at either layer must survive — that's how
    // users opt out of engineer-role defaults.
    let base = AgentFrontmatterOverrides::default();
    let harness = AgentFrontmatterOverrides {
        allowed_subagents: Some(Vec::new()),
        ..Default::default()
    };
    let merged = base.merge(&harness);
    assert_eq!(
        merged.allowed_subagents,
        Some(Vec::new()),
        "explicit empty list must override unset/default state"
    );
}

#[test]
fn frontmatter_overrides_merge_falls_through_when_harness_unset() {
    let base = AgentFrontmatterOverrides {
        allowed_subagents: Some(vec!["scout".into()]),
        ..Default::default()
    };
    let harness = AgentFrontmatterOverrides::default();
    let merged = base.merge(&harness);
    assert_eq!(merged.allowed_subagents, Some(vec!["scout".to_string()]));
}

#[test]
fn frontmatter_overrides_parses_allowed_subagents_aliases() {
    let canonical: AgentFrontmatterOverrides =
        serde_yaml::from_str("allowed-subagents: scout, researcher").unwrap();
    assert_eq!(
        canonical.allowed_subagents,
        Some(vec!["scout".to_string(), "researcher".to_string()])
    );

    let camel: AgentFrontmatterOverrides =
        serde_yaml::from_str("allowedSubagents:\n  - scout\n  - researcher").unwrap();
    assert_eq!(
        camel.allowed_subagents,
        Some(vec!["scout".to_string(), "researcher".to_string()])
    );

    let snake: AgentFrontmatterOverrides = serde_yaml::from_str("subagent_agents: scout").unwrap();
    assert_eq!(snake.allowed_subagents, Some(vec!["scout".to_string()]));

    let dashed: AgentFrontmatterOverrides = serde_yaml::from_str("subagent-agents: scout").unwrap();
    assert_eq!(dashed.allowed_subagents, Some(vec!["scout".to_string()]));
}

#[test]
fn extract_body_from_codex() {
    let content = r#"name = "rust"
developer_instructions = '''
# Rust Agent

## Additional Instructions

Use zero-copy APIs.
'''
"#;
    let body = extract_body_from_codex_toml(content).unwrap();
    let extras = extract_user_sections(&body);
    assert_eq!(extras.instructions.as_deref(), Some("Use zero-copy APIs."));
}

/// The body is the value of the ROOT `developer_instructions`, which only a
/// TOML parse can identify. The substring search this replaced took the first
/// occurrence of the assignment text anywhere in the file, so a decoy inside a
/// comment or another field's own string became the agent's instructions —
/// and every reader built on it (the installed-skill inventory `check` reads,
/// the body `refresh` preserves) worked from the wrong text.
#[test]
fn the_codex_body_is_the_parsed_root_value_not_the_first_matching_text() {
    let real = "developer_instructions = '''\n## Additional Instructions\n\nReal.\n'''\n";
    let decoy = "developer_instructions = '''\n## Additional Instructions\n\nDecoy.\n'''";
    for content in [
        // The assignment's own opening line, in a comment ahead of the real
        // one: the search anchored there and ran to the real opening `'''`.
        format!("# developer_instructions = '''\nname = \"rust\"\n{real}"),
        // The whole block, inside another field's own multi-line string.
        format!("name = \"rust\"\nnotes = \"\"\"\n{decoy}\n\"\"\"\n{real}"),
    ] {
        let body = extract_body_from_codex_toml(&content)
            .unwrap_or_else(|| panic!("the root value must be found: {content}"));
        assert_eq!(
            extract_user_sections(&body).instructions.as_deref(),
            Some("Real."),
            "{content}"
        );
    }

    // A `developer_instructions` belonging to another table is not the
    // agent's, and neither is a file that is not TOML at all.
    for content in [
        "name = \"rust\"\n\n[experimental]\ndeveloper_instructions = '''\nDecoy.\n'''\n",
        "name = \"rust\ndeveloper_instructions = '''\nDecoy.\n'''\n",
    ] {
        assert_eq!(extract_body_from_codex_toml(content), None, "{content}");
    }
}
