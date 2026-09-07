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

/// Whether some finding's message carries the fragment: the clause the
/// check emits, read apart from the fix beside it.
fn said(findings: &[Finding], fragment: &str) -> bool {
    findings.iter().any(|f| f.message.contains(fragment))
}

/// Whether some finding's fix carries the value: read only where a fix
/// spells something computed, never for its wording.
fn fixed(findings: &[Finding], value: &str) -> bool {
    findings.iter().any(|f| f.remediation.contains(value))
}

/// Findings joined for a failure's diagnostic.
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

/// One row per rendering a harness would refuse or query, and what the
/// findings say: one message fragment per breakage finding in order, one
/// per advisory finding in order, and the values the remediations carry
/// where a fix spells something computed (a name, the accepted set). The
/// `Finding` carries no rule code, so the message fragment a row pins is
/// the clause only that check emits; a remedy's wording is not pinned. A
/// Codex agent must parse as TOML and carry its keys, and name a sandbox
/// Codex knows. An OpenCode agent must declare a mode and permissions it
/// can read, a `provider/model` id, and a lowercase-kebab name of at most
/// 64 characters, which the fix spells. A Claude agent must answer to the
/// name it installs under. Cursor rule keys outside the three are
/// folklore, and only advice.
#[test]
#[allow(clippy::too_many_lines)]
fn a_rendering_a_harness_would_refuse_is_named_with_what_it_got_wrong() {
    struct Row {
        harness: HarnessId,
        name: &'static str,
        text: String,
        breakage: &'static [&'static str],
        advice: &'static [&'static str],
        remedy: &'static [&'static str],
    }
    let rows = [
        Row {
            harness: HarnessId::Codex,
            name: "rust",
            text: "name = \"rust\ndescription = 1\n".to_owned(),
            breakage: &["does not parse"],
            advice: &[],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Codex,
            name: "rust",
            text: "name = \"\"\nother = \"x\"\n".to_owned(),
            breakage: &["`name`", "`description`", "`developer_instructions`"],
            advice: &[],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Codex,
            name: "rust",
            text: CODEX_AGENT.replace("workspace-write", "yolo"),
            breakage: &["not a sandbox Codex knows"],
            advice: &[],
            remedy: &["danger-full-access"],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: OPENCODE_AGENT.replace("mode: subagent", "mode: helper"),
            breakage: &["`mode: helper`"],
            advice: &[],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: OPENCODE_AGENT.replace("bash: deny", "bash: maybe"),
            breakage: &["permission `bash`"],
            advice: &[],
            remedy: &["allow, ask, deny"],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: "no frontmatter here\n".to_owned(),
            breakage: &["there is none"],
            advice: &[],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: OPENCODE_AGENT.replace("anthropic/claude", "opus"),
            breakage: &["provider/model"],
            advice: &[],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Claude,
            name: "rust",
            text: CLAUDE_AGENT.replace("name: rust", "name: rustacean"),
            breakage: &["calls itself `rustacean`"],
            advice: &[],
            remedy: &["`rustacean`"],
        },
        Row {
            harness: HarnessId::Claude,
            name: "rust",
            text: CLAUDE_AGENT.replace("name: rust\n", ""),
            breakage: &["has no name"],
            advice: &[],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Cursor,
            name: "rust",
            text: CURSOR_RULE.replace("alwaysApply: false", "agentRequested: true\nmode: auto"),
            breakage: &[],
            advice: &["`agentRequested:`", "`mode:`"],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "My_Skill",
            text: OPENCODE_AGENT.to_owned(),
            breakage: &["will not load `My_Skill`"],
            advice: &[],
            remedy: &["`my-skill`"],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            text: OPENCODE_AGENT.to_owned(),
            breakage: &["65 characters"],
            advice: &[],
            remedy: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "code-review-2",
            text: OPENCODE_AGENT.to_owned(),
            breakage: &[],
            advice: &[],
            remedy: &[],
        },
    ];
    for row in rows {
        let label = format!("{} {}", row.harness.name(), row.name);
        let findings = validate_agent(row.harness, row.name, &row.text);
        let (breakage, advice): (Vec<_>, Vec<_>) =
            findings.iter().partition(|finding| finding.is_breakage());
        assert_eq!(breakage.len(), row.breakage.len(), "{label}: {findings:?}");
        for (finding, fragment) in breakage.iter().zip(row.breakage) {
            assert!(finding.message.contains(fragment), "{label}: {finding:?}");
        }
        assert_eq!(advice.len(), row.advice.len(), "{label}: {findings:?}");
        for (finding, fragment) in advice.iter().zip(row.advice) {
            assert!(finding.message.contains(fragment), "{label}: {finding:?}");
        }
        let remedies: Vec<&str> = findings.iter().map(|f| f.remediation.as_str()).collect();
        for value in row.remedy {
            assert!(
                remedies.iter().any(|r| r.contains(value)),
                "{label}: {remedies:?}"
            );
        }
    }
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
        assert!(
            said(&refused, bad),
            "{}: {}",
            harness.name(),
            spoken(&refused)
        );
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
        (HarnessId::Pi, md("/claude-opus-5")),
        (HarnessId::Pi, md("anthropic/")),
        (HarnessId::Pi, md("anthropic/claude-opus-5:ultra")),
        (HarnessId::Opencode, opencode("openai/")),
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
            said(&findings, "points out of the directory"),
            "{name}: {findings:?}"
        );
    }
}

#[test]
fn a_skill_tree_must_carry_a_skill_md_that_names_its_own_directory() {
    let missing = validate_skill_tree(HarnessId::Claude, "gh", "gh", &[]);
    assert_eq!(blocking(&missing).len(), 1);
    assert!(said(&missing, "no SKILL.md"), "{missing:?}");

    let mismatch = validate_skill_tree(
        HarnessId::Claude,
        "gh",
        "gh",
        &skill_tree("---\nname: github\ndescription: d\n---\n"),
    );
    assert_eq!(blocking(&mismatch).len(), 1, "{mismatch:?}");
    assert!(said(&mismatch, "calls the skill `github`"), "{mismatch:?}");
    assert!(fixed(&mismatch, "`name: gh`"), "{mismatch:?}");

    // An item that carries its plugin installs under a name no catalog file
    // knows and no declaration can spell, so the fix has to be about the
    // file kendex rewrites — never about renaming what nobody controls.
    let derived = validate_skill_tree(
        HarnessId::Claude,
        "data-science/eda",
        "data-science__eda",
        &skill_tree("---\nname: eda\ndescription: d\n---\n"),
    );
    assert!(!fixed(&derived, "declare the skill as"), "{derived:?}");
    assert!(fixed(&derived, "frontmatter"), "{derived:?}");

    let no_description = validate_skill_tree(
        HarnessId::Claude,
        "gh",
        "gh",
        &skill_tree("---\nname: gh\n---\nBody.\n"),
    );
    assert!(blocking(&no_description).is_empty(), "{no_description:?}");
    assert!(
        said(&no_description, "no description"),
        "{no_description:?}"
    );

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
    assert_eq!(blocking(&codex).len(), 1, "{codex:?}");
    assert!(
        said(&codex, "`gh`'s description is 1025 characters"),
        "{codex:?}"
    );
    assert!(said(&codex, "past 1024"), "{codex:?}");
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
