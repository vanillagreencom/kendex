use std::path::PathBuf;

use super::{Finding, validate_agent, validate_skill_tree};
use crate::model::HarnessId;

const CODEX_AGENT: &str = "name = \"rust\"\ndescription = \"Rust engineer\"\nsandbox_mode = \"workspace-write\"\ndeveloper_instructions = '''\nBody.\n'''\n";
const OPENCODE_AGENT: &str = "---\ndescription: Rust engineer\nmode: subagent\nmodel: anthropic/claude\npermission:\n  bash: deny\n---\n\nBody.\n";
const CLAUDE_AGENT: &str = "---\nname: rust\ndescription: Rust engineer\n---\n\nBody.\n";
const CURSOR_RULE: &str =
    "---\ndescription: \"rust — Rust engineer\"\nalwaysApply: false\n---\n\nBody.\n";

fn skill_tree(skill_md: &str) -> Vec<(PathBuf, Vec<u8>)> {
    vec![(PathBuf::from("SKILL.md"), skill_md.as_bytes().to_vec())]
}

fn blocking(findings: &[Finding]) -> Vec<&Finding> {
    findings.iter().filter(|f| f.is_breakage()).collect()
}

/// Findings are joined for `contains` assertions on message and fix alike.
fn spoken(findings: &[Finding]) -> String {
    findings
        .iter()
        .map(|f| format!("{} — {}", f.message, f.remediation))
        .collect::<Vec<_>>()
        .join(" | ")
}

#[test]
fn a_sound_rendering_of_every_kind_has_nothing_to_say() {
    assert_eq!(
        validate_agent(HarnessId::Codex, "rust", CODEX_AGENT),
        Vec::new()
    );
    assert_eq!(
        validate_agent(HarnessId::Opencode, "rust", OPENCODE_AGENT),
        Vec::new()
    );
    assert_eq!(
        validate_agent(HarnessId::Claude, "rust", CLAUDE_AGENT),
        Vec::new()
    );
    assert_eq!(
        validate_agent(HarnessId::Cursor, "rust", CURSOR_RULE),
        Vec::new()
    );
    assert_eq!(
        validate_skill_tree(
            HarnessId::Codex,
            "gh",
            "gh",
            &skill_tree("---\nname: gh\ndescription: GitHub\n---\nBody.\n")
        ),
        Vec::new()
    );
}

#[test]
fn every_finding_carries_a_fix() {
    let all = [
        validate_agent(HarnessId::Codex, "rust", "name = broken"),
        validate_agent(HarnessId::Opencode, "My_Agent", "no frontmatter\n"),
        validate_agent(HarnessId::Claude, "rust", "---\nname: other\n---\n"),
        validate_skill_tree(HarnessId::Codex, "gh", "gh", &[]),
    ];
    for findings in all {
        assert!(!findings.is_empty());
        for finding in findings {
            assert!(!finding.remediation.trim().is_empty(), "{finding:?}");
        }
    }
}

#[test]
fn codex_agents_must_parse_as_toml_and_carry_their_keys() {
    let broken = validate_agent(HarnessId::Codex, "rust", "name = \"rust\ndescription = 1\n");
    assert_eq!(blocking(&broken).len(), 1);
    assert!(spoken(&broken).contains("does not parse"), "{broken:?}");

    let bare = validate_agent(HarnessId::Codex, "rust", "name = \"\"\nother = \"x\"\n");
    let said = spoken(&bare);
    assert_eq!(blocking(&bare).len(), 3, "{said}");
    for key in ["`name`", "`description`", "`developer_instructions`"] {
        assert!(said.contains(key), "{said}");
    }
}

#[test]
fn an_unknown_codex_sandbox_is_refused_and_the_fix_lists_the_real_ones() {
    let text = CODEX_AGENT.replace("workspace-write", "yolo");
    let findings = validate_agent(HarnessId::Codex, "rust", &text);
    assert_eq!(blocking(&findings).len(), 1);
    let said = spoken(&findings);
    assert!(said.contains("not a sandbox Codex knows"), "{said}");
    assert!(said.contains("danger-full-access"), "{said}");
}

#[test]
fn opencode_agents_must_declare_a_mode_and_permissions_it_can_read() {
    let text = OPENCODE_AGENT.replace("mode: subagent", "mode: helper");
    let findings = validate_agent(HarnessId::Opencode, "rust", &text);
    assert_eq!(blocking(&findings).len(), 1);
    assert!(spoken(&findings).contains("`mode: helper`"), "{findings:?}");

    let text = OPENCODE_AGENT.replace("bash: deny", "bash: maybe");
    let findings = validate_agent(HarnessId::Opencode, "rust", &text);
    let said = spoken(&findings);
    assert_eq!(blocking(&findings).len(), 1, "{said}");
    assert!(said.contains("permission `bash`"), "{said}");
    assert!(said.contains("allow, ask, deny"), "{said}");

    let findings = validate_agent(HarnessId::Opencode, "rust", "no frontmatter here\n");
    assert_eq!(blocking(&findings).len(), 1);
    assert!(spoken(&findings).contains("there is none"), "{findings:?}");
}

#[test]
fn a_bare_opencode_model_alias_is_said_out_loud_but_still_installs() {
    let text = OPENCODE_AGENT.replace("anthropic/claude", "opus");
    let findings = validate_agent(HarnessId::Opencode, "rust", &text);
    assert!(blocking(&findings).is_empty(), "{findings:?}");
    let said = spoken(&findings);
    assert!(said.contains("names no provider"), "{said}");
    assert!(said.contains("provider/model"), "{said}");
}

/// One control per harness with an effort key: a level outside the
/// harness's own set is refused under that harness's key, and a level
/// inside it passes.
#[test]
fn an_effort_level_the_harness_does_not_accept_is_refused() {
    let cases = [
        (
            HarnessId::Claude,
            "---\nname: rust\ndescription: r\neffort: {}\n---\nBody.\n",
            "max",
            "ultra",
        ),
        (
            HarnessId::Codex,
            "name = \"rust\"\ndescription = \"r\"\nmodel_reasoning_effort = \"{}\"\ndeveloper_instructions = '''\nBody.\n'''\n",
            "xhigh",
            "max",
        ),
        (
            HarnessId::Opencode,
            "---\ndescription: r\nmode: subagent\noptions:\n  reasoningEffort: {}\n---\nBody.\n",
            "high",
            "ultra",
        ),
        (
            HarnessId::Pi,
            "---\nname: rust\ndescription: r\neffort: {}\n---\nBody.\n",
            "max",
            "ultra",
        ),
    ];
    for (harness, shape, good, bad) in cases {
        let accepted = validate_agent(harness, "rust", &shape.replace("{}", good));
        assert!(
            accepted.is_empty(),
            "{}: {}",
            harness.name(),
            spoken(&accepted)
        );
        let refused = validate_agent(harness, "rust", &shape.replace("{}", bad));
        assert_eq!(
            blocking(&refused).len(),
            1,
            "{}: {}",
            harness.name(),
            spoken(&refused)
        );
        assert!(spoken(&refused).contains(bad), "{}", harness.name());
    }
}

/// A `provider/model` id is refused wherever the harness reaches one
/// vendor, and a bare id is refused where the loader needs the provider
/// named; `inherit` and a bare id pass where they belong.
#[test]
fn a_model_of_the_wrong_shape_for_the_harness_is_refused() {
    let md = |model: &str| format!("---\nname: rust\ndescription: r\nmodel: {model}\n---\nBody.\n");
    let toml = |model: &str| {
        format!(
            "name = \"rust\"\ndescription = \"r\"\nmodel = \"{model}\"\ndeveloper_instructions = '''\nBody.\n'''\n"
        )
    };
    let opencode =
        |model: &str| format!("---\ndescription: r\nmode: subagent\nmodel: {model}\n---\nBody.\n");
    for (harness, text) in [
        (HarnessId::Claude, md("anthropic/claude-opus-5")),
        (HarnessId::Codex, toml("openai/gpt-6-astra")),
        (HarnessId::Gemini, md("google/gemini-3-pro-preview")),
        (HarnessId::Copilot, md("anthropic/claude-sonnet-4.6")),
        (HarnessId::Pi, md("claude-opus-5")),
        (HarnessId::Pi, md("claude-opus-5:high")),
    ] {
        let findings = validate_agent(harness, "rust", &text);
        assert_eq!(
            blocking(&findings).len(),
            1,
            "{}: {}",
            harness.name(),
            spoken(&findings)
        );
    }
    for (harness, text) in [
        (HarnessId::Claude, md("opus")),
        (HarnessId::Claude, md("inherit")),
        (HarnessId::Codex, toml("gpt-6-astra")),
        (HarnessId::Gemini, md("gemini-3-pro-preview")),
        (HarnessId::Copilot, md("claude-sonnet-4.6")),
        (HarnessId::Pi, md("anthropic/claude-opus-5:high")),
        (HarnessId::Opencode, opencode("anthropic/claude-opus-5")),
    ] {
        let findings = validate_agent(harness, "rust", &text);
        assert!(
            blocking(&findings).is_empty(),
            "{}: {}",
            harness.name(),
            spoken(&findings)
        );
    }
}

#[test]
fn claude_agents_must_answer_to_the_name_they_install_under() {
    let findings = validate_agent(HarnessId::Claude, "rust", CLAUDE_AGENT);
    assert!(findings.is_empty());

    let text = CLAUDE_AGENT.replace("name: rust", "name: rustacean");
    let findings = validate_agent(HarnessId::Claude, "rust", &text);
    let said = spoken(&findings);
    assert_eq!(blocking(&findings).len(), 1, "{said}");
    assert!(said.contains("calls itself `rustacean`"), "{said}");
    assert!(said.contains("declare the agent as `rustacean`"), "{said}");

    let text = CLAUDE_AGENT.replace("name: rust\n", "");
    let findings = validate_agent(HarnessId::Claude, "rust", &text);
    assert_eq!(blocking(&findings).len(), 1);
    assert!(spoken(&findings).contains("has no name"), "{findings:?}");
}

#[test]
fn cursor_rule_keys_outside_the_three_are_folklore() {
    let text = CURSOR_RULE.replace("alwaysApply: false", "agentRequested: true\nmode: auto");
    let findings = validate_agent(HarnessId::Cursor, "rust", &text);
    assert!(blocking(&findings).is_empty(), "{findings:?}");
    let said = spoken(&findings);
    assert!(said.contains("`agentRequested:`"), "{said}");
    assert!(said.contains("`mode:`"), "{said}");
    assert!(said.contains("folklore"), "{said}");
}

#[test]
fn opencode_names_must_be_lowercase_kebab_and_the_fix_spells_one() {
    let findings = validate_agent(HarnessId::Opencode, "My_Skill", OPENCODE_AGENT);
    let said = spoken(&findings);
    assert_eq!(blocking(&findings).len(), 1, "{said}");
    assert!(said.contains("will not load `My_Skill`"), "{said}");
    assert!(said.contains("declare it as `my-skill`"), "{said}");

    let long = "a".repeat(65);
    let findings = validate_agent(HarnessId::Opencode, &long, OPENCODE_AGENT);
    let said = spoken(&findings);
    assert_eq!(blocking(&findings).len(), 1, "{said}");
    assert!(said.contains("65 characters"), "{said}");

    assert!(validate_agent(HarnessId::Opencode, "code-review-2", OPENCODE_AGENT).is_empty());
}

#[test]
fn other_harnesses_refuse_names_that_leave_their_own_directory() {
    let legal = validate_agent(
        HarnessId::Claude,
        "My_Agent",
        &CLAUDE_AGENT.replace("rust", "My_Agent"),
    );
    assert!(legal.is_empty(), "{legal:?}");

    for name in ["../elsewhere", "sub/agent"] {
        let findings = validate_skill_tree(
            HarnessId::Claude,
            name,
            name,
            &skill_tree(&format!("---\nname: {name}\ndescription: d\n---\n")),
        );
        assert!(
            spoken(&findings).contains("points out of the directory"),
            "{name}: {findings:?}"
        );
    }
}

#[test]
fn a_skill_tree_must_carry_a_skill_md_that_names_its_own_directory() {
    let missing = validate_skill_tree(HarnessId::Claude, "gh", "gh", &[]);
    assert_eq!(blocking(&missing).len(), 1);
    assert!(spoken(&missing).contains("no SKILL.md"), "{missing:?}");

    let mismatch = validate_skill_tree(
        HarnessId::Claude,
        "gh",
        "gh",
        &skill_tree("---\nname: github\ndescription: d\n---\n"),
    );
    let said = spoken(&mismatch);
    assert_eq!(blocking(&mismatch).len(), 1, "{said}");
    assert!(said.contains("calls the skill `github`"), "{said}");
    assert!(said.contains("set `name: gh`"), "{said}");

    // An item that carries its plugin installs under a name no catalog file
    // knows and no declaration can spell, so the fix has to be about the
    // file kendex rewrites — never about renaming what nobody controls.
    let derived = validate_skill_tree(
        HarnessId::Claude,
        "data-science/eda",
        "data-science__eda",
        &skill_tree("---\nname: eda\ndescription: d\n---\n"),
    );
    let said = spoken(&derived);
    assert!(!said.contains("declare the skill as"), "{said}");
    assert!(said.contains("frontmatter"), "{said}");

    let no_description = validate_skill_tree(
        HarnessId::Claude,
        "gh",
        "gh",
        &skill_tree("---\nname: gh\n---\nBody.\n"),
    );
    assert!(blocking(&no_description).is_empty(), "{no_description:?}");
    assert!(spoken(&no_description).contains("no description"));

    // A disabled tree parks the same content under `.disabled`.
    let disabled = vec![(
        PathBuf::from("SKILL.md.disabled"),
        b"---\nname: gh\ndescription: d\n---\n".to_vec(),
    )];
    assert!(validate_skill_tree(HarnessId::Claude, "gh", "gh", &disabled).is_empty());
}

#[test]
fn a_skill_whose_description_runs_past_codexs_limit_is_refused_there_and_installs_on_claude() {
    let body = format!(
        "---\nname: gh\ndescription: {}\n---\nBody.\n",
        "é".repeat(1025)
    );
    let files = skill_tree(&body);
    let codex = validate_skill_tree(HarnessId::Codex, "gh", "gh", &files);
    let said = spoken(&codex);
    assert_eq!(blocking(&codex).len(), 1, "{said}");
    assert!(
        said.contains("`gh`'s description is 1025 characters"),
        "{said}"
    );
    assert!(said.contains("past 1024"), "{said}");
    assert!(validate_skill_tree(HarnessId::Claude, "gh", "gh", &files).is_empty());

    // Exactly at the limit is fine, and the body's length is nobody's
    // concern: Codex reads the whole file.
    let long = format!(
        "---\nname: gh\ndescription: {}\n---\n{}",
        "d".repeat(1024),
        "prose ".repeat(4000)
    );
    assert!(validate_skill_tree(HarnessId::Codex, "gh", "gh", &skill_tree(&long)).is_empty());
}
