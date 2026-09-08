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

/// Stable refusal record, apart from the English explanation.
fn said(findings: &[Finding], record: &str) -> bool {
    findings
        .iter()
        .any(|f| f.message.lines().next() == Some(record))
}

#[test]
fn a_sound_rendering_of_every_kind_has_nothing_to_say() {
    for (harness, text) in [
        (HarnessId::Codex, CODEX_AGENT),
        (HarnessId::Opencode, OPENCODE_AGENT),
        (HarnessId::Claude, CLAUDE_AGENT),
        (HarnessId::Cursor, CURSOR_RULE),
    ] {
        assert_eq!(
            validate_agent(harness, "rust", text),
            Vec::new(),
            "{harness:?}"
        );
    }
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

/// Each invalid rendering has its own stable refusal record and severity.
/// Accepted alternatives and computed replacement names belong to that record.
#[test]
#[allow(clippy::too_many_lines)]
fn a_rendering_a_harness_would_refuse_is_named_with_what_it_got_wrong() {
    struct Row {
        harness: HarnessId,
        name: &'static str,
        text: String,
        breakage: &'static [&'static str],
        advice: &'static [&'static str],
    }
    let rows = [
        Row {
            harness: HarnessId::Codex,
            name: "rust",
            text: "name = \"rust\ndescription = 1\n".to_owned(),
            breakage: &["kendex-agent-invalid: harness=codex format=toml"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Codex,
            name: "rust",
            text: "name = \"\"\nother = \"x\"\n".to_owned(),
            breakage: &[
                "kendex-agent-key-missing: harness=codex key=name",
                "kendex-agent-key-missing: harness=codex key=description",
                "kendex-agent-key-missing: harness=codex key=developer_instructions",
            ],
            advice: &[],
        },
        Row {
            harness: HarnessId::Codex,
            name: "rust",
            text: CODEX_AGENT.replace("workspace-write", "yolo"),
            breakage: &[
                "kendex-sandbox-rejected: harness=codex value=yolo allowed=read-only,workspace-write,danger-full-access",
            ],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: OPENCODE_AGENT.replace("mode: subagent", "mode: helper"),
            breakage: &[
                "kendex-agent-mode-rejected: harness=opencode value=helper allowed=primary,subagent,all",
            ],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: OPENCODE_AGENT.replace("bash: deny", "bash: maybe"),
            breakage: &[
                "kendex-permission-rejected: harness=opencode key=bash value=maybe allowed=allow,ask,deny",
            ],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: "no frontmatter here\n".to_owned(),
            breakage: &["kendex-frontmatter-missing: harness=opencode"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: OPENCODE_AGENT.replace("anthropic/claude", "opus"),
            breakage: &["kendex-model-shape: harness=opencode model=opus expected=provider/model"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Claude,
            name: "rust",
            text: CLAUDE_AGENT.replace("name: rust", "name: rustacean"),
            breakage: &[
                "kendex-agent-name-mismatch: harness=claude installed=rust declared=rustacean",
            ],
            advice: &[],
        },
        Row {
            harness: HarnessId::Claude,
            name: "rust",
            text: CLAUDE_AGENT.replace("name: rust\n", ""),
            breakage: &["kendex-agent-key-missing: harness=claude name=rust key=name"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Cursor,
            name: "rust",
            text: CURSOR_RULE.replace("alwaysApply: false", "agentRequested: true\nmode: auto"),
            breakage: &[],
            advice: &[
                "kendex-rule-key-ignored: harness=cursor key=agentRequested",
                "kendex-rule-key-ignored: harness=cursor key=mode",
            ],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "My_Skill",
            text: OPENCODE_AGENT.to_owned(),
            breakage: &["kendex-name-rejected: harness=opencode name=My_Skill suggested=my-skill"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            text: OPENCODE_AGENT.to_owned(),
            breakage: &[
                "kendex-name-too-long: harness=opencode name=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa length=65 limit=64",
            ],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "code-review-2",
            text: OPENCODE_AGENT.to_owned(),
            breakage: &[],
            advice: &[],
        },
        Row {
            harness: HarnessId::Gemini,
            name: "rust",
            text: "---\ndescription: Rust engineer\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-key-missing: harness=gemini name=rust key=name"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Gemini,
            name: "rust",
            text: "---\nname: other\ndescription: Rust engineer\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-name-mismatch: harness=gemini installed=rust declared=other"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Gemini,
            name: "rust",
            text: "---\nname: rust\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-key-missing: harness=gemini name=rust key=description"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Antigravity,
            name: "rust",
            text: "---\ndescription: Rust engineer\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-key-missing: harness=antigravity name=rust key=name"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Antigravity,
            name: "rust",
            text: "---\nname: other\ndescription: Rust engineer\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-name-mismatch: harness=antigravity installed=rust declared=other"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Antigravity,
            name: "rust",
            text: "---\nname: rust\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-key-missing: harness=antigravity name=rust key=description"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Copilot,
            name: "rust",
            text: "---\nname: other\ndescription: Rust engineer\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-name-mismatch: harness=copilot installed=rust declared=other"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Copilot,
            name: "rust",
            text: "---\nname: rust\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-key-missing: harness=copilot name=rust key=description"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: "---\ndescription: Rust engineer\nmode: subagent\npermission: deny\n---\nBody.\n".to_owned(),
            breakage: &["kendex-permission-invalid: harness=opencode key=permission"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Gemini,
            name: "rust",
            text: "---\nname: rust\ndescription: Rust engineer\nmodel: other\n---\nBody.\n".to_owned(),
            breakage: &[],
            advice: &["kendex-agent-model-fallback: harness=gemini model=other"],
        },
        Row {
            harness: HarnessId::Antigravity,
            name: "rust",
            text: "---\nname: rust\ndescription: Rust engineer\nmodel: other\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-model-rejected: harness=antigravity model=other allowed=inherit,flash,pro"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Opencode,
            name: "rust",
            text: "---\ndescription: Rust engineer\nmodel: \"bad\\nmodel\"\n---\nBody.\n".to_owned(),
            breakage: &["kendex-model-shape: harness=opencode model=bad\\nmodel expected=provider/model"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Codex,
            name: "rust",
            text: "name = \"rust\"\ndescription = \"Rust engineer\"\ndeveloper_instructions = \"Body.\"\nmodel = \"openai/bad\\nmodel\"\n".to_owned(),
            breakage: &["kendex-model-shape: harness=codex model=openai/bad\\nmodel expected=bare"],
            advice: &[],
        },
        Row {
            harness: HarnessId::Claude,
            name: "rust",
            text: "---\nname: \"other\\nagent\"\ndescription: Rust engineer\n---\nBody.\n".to_owned(),
            breakage: &["kendex-agent-name-mismatch: harness=claude installed=rust declared=other\\nagent"],
            advice: &[],
        },
    ];
    for row in rows {
        let label = format!("{} {}", row.harness.name(), row.name);
        let findings = validate_agent(row.harness, row.name, &row.text);
        let (breakage, advice): (Vec<_>, Vec<_>) =
            findings.iter().partition(|finding| finding.is_breakage());
        assert_eq!(breakage.len(), row.breakage.len(), "{label}: {findings:?}");
        for (finding, fragment) in breakage.iter().zip(row.breakage) {
            assert!(
                finding.message.lines().next() == Some(*fragment),
                "{label}: {finding:?}"
            );
        }
        assert_eq!(advice.len(), row.advice.len(), "{label}: {findings:?}");
        for (finding, fragment) in advice.iter().zip(row.advice) {
            assert!(
                finding.message.lines().next() == Some(*fragment),
                "{label}: {finding:?}"
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
            "kendex-effort-rejected: harness=claude key=effort value=ultra allowed=low,medium,high,xhigh,max",
        ),
        (
            HarnessId::Codex,
            "name = \"rust\"\ndescription = \"r\"\nmodel_reasoning_effort = \"{}\"\ndeveloper_instructions = '''\nBody.\n'''\n",
            "xhigh",
            "max",
            "kendex-effort-rejected: harness=codex key=model_reasoning_effort value=max allowed=minimal,low,medium,high,xhigh",
        ),
        (
            HarnessId::Opencode,
            "---\ndescription: r\nmode: subagent\noptions:\n  reasoningEffort: {}\n---\nBody.\n",
            "high",
            "ultra",
            "kendex-effort-rejected: harness=opencode key=reasoningEffort value=ultra allowed=minimal,low,medium,high,xhigh",
        ),
        (
            HarnessId::Pi,
            "---\nname: rust\ndescription: r\neffort: {}\n---\nBody.\n",
            "max",
            "ultra",
            "kendex-effort-rejected: harness=pi key=effort value=ultra allowed=minimal,low,medium,high,xhigh,max",
        ),
    ];
    for (harness, shape, good, bad, refusal) in cases {
        for (value, expected) in [(good, None), (bad, Some((true, refusal)))] {
            let findings = validate_agent(harness, "rust", &shape.replace("{}", value));
            let records: Vec<_> = findings
                .iter()
                .map(|finding| {
                    (
                        finding.is_breakage(),
                        finding.message.lines().next().unwrap_or_default(),
                    )
                })
                .collect();
            assert_eq!(
                records,
                expected.into_iter().collect::<Vec<_>>(),
                "{harness:?} {value}: {findings:?}"
            );
        }
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
    for (harness, text, expected) in [
        (
            HarnessId::Claude,
            md("anthropic/claude-opus-5"),
            Some("kendex-model-shape: harness=claude model=anthropic/claude-opus-5 expected=bare"),
        ),
        (
            HarnessId::Codex,
            toml("openai/gpt-6-astra"),
            Some("kendex-model-shape: harness=codex model=openai/gpt-6-astra expected=bare"),
        ),
        (
            HarnessId::Gemini,
            md("google/gemini-3-pro-preview"),
            Some(
                "kendex-model-shape: harness=gemini model=google/gemini-3-pro-preview expected=bare",
            ),
        ),
        (
            HarnessId::Copilot,
            md("anthropic/claude-sonnet-4.6"),
            Some(
                "kendex-model-shape: harness=copilot model=anthropic/claude-sonnet-4.6 expected=bare",
            ),
        ),
        (
            HarnessId::Pi,
            md("claude-opus-5"),
            Some("kendex-model-shape: harness=pi model=claude-opus-5 expected=provider/model"),
        ),
        (
            HarnessId::Pi,
            md("claude-opus-5:high"),
            Some("kendex-model-shape: harness=pi model=claude-opus-5 expected=provider/model"),
        ),
        (
            HarnessId::Pi,
            md("/claude-opus-5"),
            Some("kendex-model-shape: harness=pi model=/claude-opus-5 expected=provider/model"),
        ),
        (
            HarnessId::Pi,
            md("anthropic/"),
            Some("kendex-model-shape: harness=pi model=anthropic/ expected=provider/model"),
        ),
        (
            HarnessId::Pi,
            md("anthropic/claude-opus-5:ultra"),
            Some(
                "kendex-effort-rejected: harness=pi key=model :suffix value=ultra allowed=minimal,low,medium,high,xhigh,max",
            ),
        ),
        (
            HarnessId::Opencode,
            opencode("openai/"),
            Some("kendex-model-shape: harness=opencode model=openai/ expected=provider/model"),
        ),
        (HarnessId::Claude, md("opus"), None),
        (HarnessId::Claude, md("inherit"), None),
        (HarnessId::Codex, toml("gpt-6-astra"), None),
        (HarnessId::Gemini, md("gemini-3-pro-preview"), None),
        (HarnessId::Copilot, md("claude-sonnet-4.6"), None),
        (HarnessId::Pi, md("anthropic/claude-opus-5:high"), None),
        (
            HarnessId::Opencode,
            opencode("anthropic/claude-opus-5"),
            None,
        ),
    ] {
        let findings = validate_agent(harness, "rust", &text);
        let records: Vec<_> = blocking(&findings)
            .into_iter()
            .map(|finding| finding.message.lines().next().unwrap_or_default())
            .collect();
        assert_eq!(
            records,
            expected.into_iter().collect::<Vec<_>>(),
            "{harness:?}: {findings:?}"
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
            said(
                &findings,
                &format!("kendex-name-outside-directory: harness=claude name={name}")
            ),
            "{name}: {findings:?}"
        );
    }
}

#[test]
fn a_skill_tree_must_carry_a_skill_md_that_names_its_own_directory() {
    let cases = [
        (
            "gh",
            "gh",
            skill_tree("---\ndescription: d\n---\n"),
            Some((true, "kendex-skill-name-missing: harness=claude name=gh")),
        ),
        (
            "gh",
            "gh",
            skill_tree("---\nname: \"git\\nhub\"\ndescription: d\n---\n"),
            Some((
                true,
                "kendex-skill-name-mismatch: harness=claude installed=gh declared=gh in-file=git\\nhub fix=name",
            )),
        ),
        (
            "gh",
            "gh",
            vec![],
            Some((
                true,
                "kendex-skill-file-missing: harness=claude name=gh path=SKILL.md",
            )),
        ),
        (
            "gh",
            "gh",
            skill_tree("---\nname: github\ndescription: d\n---\n"),
            Some((
                true,
                "kendex-skill-name-mismatch: harness=claude installed=gh declared=gh in-file=github fix=name",
            )),
        ),
        // A plugin-derived name needs frontmatter repair in the generated file.
        (
            "data-science/eda",
            "data-science__eda",
            skill_tree("---\nname: eda\ndescription: d\n---\n"),
            Some((
                true,
                "kendex-skill-name-mismatch: harness=claude installed=data-science__eda declared=data-science/eda in-file=eda fix=frontmatter",
            )),
        ),
        (
            "gh",
            "gh",
            skill_tree("---\nname: gh\n---\nBody.\n"),
            Some((
                false,
                "kendex-skill-description-missing: harness=claude name=gh",
            )),
        ),
        (
            "gh",
            "gh",
            vec![(
                PathBuf::from("SKILL.md.disabled"),
                b"---\nname: gh\ndescription: d\n---\n".to_vec(),
            )],
            None,
        ),
    ];
    for (declared, installed, files, expected) in cases {
        let findings = validate_skill_tree(HarnessId::Claude, declared, installed, &files);
        let records: Vec<_> = findings
            .iter()
            .map(|finding| {
                (
                    finding.is_breakage(),
                    finding.message.lines().next().unwrap_or_default(),
                )
            })
            .collect();
        assert_eq!(
            records,
            expected.into_iter().collect::<Vec<_>>(),
            "{declared}: {findings:?}"
        );
    }
}

#[test]
fn a_skill_whose_description_runs_past_codexs_limit_is_refused_there_and_installs_on_claude() {
    for (harness, length, body, expected) in [
        (
            HarnessId::Codex,
            1025,
            "Body.".to_owned(),
            Some("kendex-skill-description-too-long: harness=codex name=gh length=1025 limit=1024"),
        ),
        (HarnessId::Claude, 1025, "Body.".to_owned(), None),
        (HarnessId::Codex, 1024, "prose ".repeat(4000), None),
    ] {
        let text = format!(
            "---\nname: gh\ndescription: {}\n---\n{body}\n",
            "é".repeat(length)
        );
        let findings = validate_skill_tree(harness, "gh", "gh", &skill_tree(&text));
        let records: Vec<_> = findings
            .iter()
            .map(|finding| {
                (
                    finding.is_breakage(),
                    finding.message.lines().next().unwrap_or_default(),
                )
            })
            .collect();
        assert_eq!(
            records,
            expected
                .map(|record| (true, record))
                .into_iter()
                .collect::<Vec<_>>(),
            "{harness:?} {length}: {findings:?}"
        );
    }
}

/// Command-file findings carry the same record and severity contract.
#[test]
fn command_refusals_and_notices_identify_the_rejected_field() {
    for (harness, text, expected) in [
        (
            HarnessId::Gemini,
            "prompt = broken",
            vec![(true, "kendex-command-invalid: harness=gemini format=toml")],
        ),
        (
            HarnessId::Gemini,
            "description = \"Run it\"",
            vec![(
                true,
                "kendex-command-key-missing: harness=gemini key=prompt",
            )],
        ),
        (
            HarnessId::Gemini,
            "prompt = \"Run it\"",
            vec![(
                false,
                "kendex-command-key-missing: harness=gemini key=description",
            )],
        ),
        (
            HarnessId::Gemini,
            "prompt = \"Run it\"\ndescription = \"Command\"",
            vec![],
        ),
        (
            HarnessId::Pi,
            "Report !`git status`",
            vec![(
                false,
                "kendex-command-inline-unsupported: harness=pi syntax=!`command`",
            )],
        ),
        (HarnessId::Pi, "Report the current status", vec![]),
    ] {
        let findings = super::validate_command(harness, text);
        let records: Vec<_> = findings
            .iter()
            .map(|finding| {
                (
                    finding.is_breakage(),
                    finding.message.lines().next().unwrap_or_default(),
                )
            })
            .collect();
        assert_eq!(records, expected, "{harness:?} {text}: {findings:?}");
    }
}
