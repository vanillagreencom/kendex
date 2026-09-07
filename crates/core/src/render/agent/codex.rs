use super::{EffectiveAgent, GENERATED_BANNER, RenderedAgent, Role, hooks_prose, skills_prose};
use crate::harness::models::resolve_model;
use crate::model::HarnessId;
use crate::render::permission::PermissionIntent;
use crate::render::vocab::rewrite_prose;

const NICKNAME_SUFFIXES: [&str; 6] = ["Atlas", "Delta", "Echo", "Nova", "Orion", "Vector"];

/// Codex agent: TOML whose `developer_instructions` carries the whole prompt.
/// No native skills field and no hook wiring, so both render as prose.
/// Tags are left out: Codex denies unknown fields, and one costs the whole file.
pub fn generate(agent: &EffectiveAgent) -> RenderedAgent {
    let source = agent.source;
    let o = &agent.overrides;
    let mut warnings = Vec::new();
    let mut out = String::new();
    out.push_str(&format!("name = \"{}\"\n", escape(&source.name)));
    out.push_str(&format!(
        "nickname_candidates = [{}]\n",
        nicknames(agent)
            .iter()
            .map(|n| format!("\"{}\"", escape(n)))
            .collect::<Vec<_>>()
            .join(", ")
    ));
    out.push_str(&format!(
        "description = \"{}\"\n",
        escape(&source.description)
    ));
    let model = o.model.as_deref().unwrap_or(&source.model);
    let resolved = resolve_model(HarnessId::Codex, model);
    warnings.extend(resolved.warning.map(crate::render::RenderWarning::new));
    // No model key means Codex's own default — its dialect for inherit.
    if let Some(id) = &resolved.id {
        out.push_str(&format!("model = \"{}\"\n", escape(id)));
    }
    let effort = o
        .model_reasoning_effort
        .as_deref()
        .or(o.effort.as_deref())
        .or(source.effort.as_deref())
        .filter(|effort| !is_none_value(effort));
    if let Some(effort) = effort {
        out.push_str(&format!("model_reasoning_effort = \"{effort}\"\n"));
    }
    out.push_str(&format!(
        "sandbox_mode = \"{}\"\n",
        sandbox_mode(agent, &mut warnings)
    ));
    if matches!(agent.permissions, PermissionIntent::AllowOnly { .. }) {
        warnings.push(crate::render::RenderWarning::with_fix(
            "Codex has no tool allowlist; the sandbox is the closest enforceable restriction — the tool list itself is not enforced",
            "tighten sandbox-mode further with an override, or exclude Codex from this agent's harnesses",
        ));
    }
    out.push_str("developer_instructions = '''\n");
    out.push_str(&fence_safe(&instructions(agent, &mut warnings)));
    out.push_str("'''\n");
    RenderedAgent {
        text: out,
        warnings,
    }
}

/// The sandbox never exceeds the permission intent. A tool allowlist caps
/// it — read-only for read-only lists, workspace-write otherwise — even
/// when the role says Engineer: the narrower declaration wins, loudly. An
/// explicit `sandbox-mode` override is the user's own dial and is honored,
/// with a warning when it widens past a read-only intent. Without an
/// allowlist, only an explicit Engineer role earns full access — a missing
/// role never escalates.
fn sandbox_mode(
    agent: &EffectiveAgent,
    warnings: &mut Vec<crate::render::RenderWarning>,
) -> String {
    let allowlisted = matches!(agent.permissions, PermissionIntent::AllowOnly { .. });
    if let Some(mode) = &agent.overrides.sandbox_mode {
        if agent.permissions.is_read_only() && mode != "read-only" {
            warnings.push(crate::render::RenderWarning::with_fix(
                format!(
                    "sandbox-mode override '{mode}' widens beyond the read-only tool allowlist"
                ),
                "drop the sandbox-mode override or set it to read-only",
            ));
        }
        return mode.clone();
    }
    if allowlisted {
        let capped = match agent.permissions.is_read_only() {
            true => "read-only",
            false => "workspace-write",
        };
        if agent.source.role == Some(Role::Engineer) {
            warnings.push(crate::render::RenderWarning::new(format!(
                "role engineer's full access narrowed to {capped} by the tool allowlist"
            )));
        }
        return capped.to_owned();
    }
    match agent.source.role {
        Some(Role::Engineer) => "danger-full-access".to_owned(),
        _ => "workspace-write".to_owned(),
    }
}

fn nicknames(agent: &EffectiveAgent) -> Vec<String> {
    let custom: Vec<String> = agent
        .overrides
        .nickname_candidates
        .iter()
        .flatten()
        .map(|candidate| candidate.trim().to_owned())
        .filter(|candidate| !candidate.is_empty())
        .collect();
    if !custom.is_empty() {
        return custom;
    }
    let prefix = display_name(&agent.source.name);
    NICKNAME_SUFFIXES
        .iter()
        .map(|suffix| format!("{prefix}-{suffix}"))
        .collect()
}

fn display_name(name: &str) -> String {
    let parts: Vec<String> = name
        .trim()
        .split(|ch: char| ch == '-' || ch == '_' || ch.is_whitespace())
        .filter(|part| !part.is_empty())
        .map(capitalize)
        .collect();
    if parts.is_empty() {
        return "Agent".to_owned();
    }
    parts.join("-")
}

fn capitalize(part: &str) -> String {
    if part.eq_ignore_ascii_case("tpm") {
        return "TPM".to_owned();
    }
    let mut chars = part.chars();
    match chars.next() {
        Some(first) => first
            .to_uppercase()
            .chain(chars.flat_map(char::to_lowercase))
            .collect(),
        None => String::new(),
    }
}

fn instructions(
    agent: &EffectiveAgent,
    warnings: &mut Vec<crate::render::RenderWarning>,
) -> String {
    let mut out = format!("{GENERATED_BANNER}\n\n");
    if let Some(launch) = &agent.launch_instructions {
        out.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    let (prose, reworded) = rewrite_prose(agent.source.body.trim_end(), HarnessId::Codex);
    warnings.extend(reworded);
    out.push_str(&prose);
    out.push('\n');
    let skill_root = super::skill_root(HarnessId::Codex, agent.scope);
    if let Some(skills) = skills_prose(agent, skill_root) {
        out.push_str(&format!("\n{skills}"));
    }
    if let Some(hooks) = hooks_prose(agent) {
        out.push_str(&format!("\n{hooks}\n"));
    }
    if let Some(additional) = &agent.additional_instructions {
        out.push_str(&format!("\n## Additional Instructions\n\n{additional}\n"));
    }
    out
}

/// TOML literal strings have no escape mechanism, so an apostrophe run in the
/// prompt would close the block early. Break every run down to two.
fn fence_safe(text: &str) -> String {
    if text.contains("'''") {
        return text.replace("''", "' '");
    }
    text.to_owned()
}

/// TOML basic-string escaping. Newlines and control characters must become
/// escapes — a literal newline in a basic string is invalid TOML, and raw
/// foreign text must never mint TOML lines of its own.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04X}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out
}

fn is_none_value(value: &str) -> bool {
    matches!(
        value.trim().to_lowercase().as_str(),
        "" | "none" | "false" | "off" | "no"
    )
}

#[cfg(test)]
mod tests {
    use super::super::{SourceAgent, parse_source_agent};
    use super::*;
    use crate::manifest::FrontmatterOverrides;
    use crate::model::{HarnessId, Scope};

    fn source(name: &str, role: &str) -> SourceAgent {
        parse_source_agent(&format!(
            "---\nname: {name}\ndescription: Codex agent\nmodel: sonnet\nrole: {role}\ntags: performance\n---\nBody text.\n"
        ))
        .unwrap()
    }

    fn effective<'a>(source: &'a SourceAgent, scope: &'a Scope) -> EffectiveAgent<'a> {
        EffectiveAgent {
            source,
            harness: HarnessId::Codex,
            scope,
            skills: vec!["dev".into()],
            overrides: FrontmatterOverrides::default(),
            permissions: PermissionIntent::Unspecified,
            launch_instructions: None,
            additional_instructions: None,
            custom_hooks: vec![],
        }
    }

    #[test]
    fn engineer_gets_full_access_and_others_workspace_write() {
        let engineer = source("rust", "engineer");
        let manager = source("tpm", "manager");
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
        let engineer = generate(&effective(&engineer, &scope)).text;
        let manager = generate(&effective(&manager, &scope)).text;
        assert!(engineer.contains("sandbox_mode = \"danger-full-access\""));
        assert!(manager.contains("sandbox_mode = \"workspace-write\""));
        assert!(engineer.contains("model = \"gpt-6-astra\""));
        assert!(!engineer.contains("model_reasoning_effort"));
        assert!(engineer.contains("- dev: .agents/skills/dev/SKILL.md"));
    }

    /// One unknown field costs Codex the whole agent file.
    #[test]
    fn a_tagged_source_renders_no_tags_key() {
        let source = source("rust", "engineer");
        assert_eq!(source.tags, vec!["performance"]);
        let text = generate(&effective(&source, &Scope::Global)).text;
        let (keys, _) = text.split_once("developer_instructions").unwrap();
        assert!(!keys.contains("tags"), "{keys}");
    }

    #[test]
    fn a_missing_role_never_escalates_the_sandbox() {
        let reviewer = parse_source_agent(
            "---\nname: sec-reviewer\ndescription: reads only\ntools: Read, Grep\n---\nBody.\n",
        )
        .unwrap();
        let scope = Scope::Global;
        let mut agent = effective(&reviewer, &scope);
        agent.permissions = reviewer.permissions.clone();
        let rendered = generate(&agent);
        assert!(rendered.text.contains("sandbox_mode = \"read-only\""));
        assert!(!rendered.text.contains("danger-full-access"));
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("allowlist"))
        );

        let plain = parse_source_agent("---\nname: helper\ndescription: d\n---\nBody.\n").unwrap();
        let agent = effective(&plain, &scope);
        assert!(
            generate(&agent)
                .text
                .contains("sandbox_mode = \"workspace-write\"")
        );
    }

    #[test]
    fn a_read_only_allowlist_narrows_the_sandbox_even_for_an_engineer() {
        let src = parse_source_agent(
            "---\nname: rust\ndescription: reads only\nrole: engineer\ntools: Read, Grep\n---\nBody.\n",
        )
        .unwrap();
        let scope = Scope::Global;
        let mut agent = effective(&src, &scope);
        agent.permissions = src.permissions.clone();
        let rendered = generate(&agent);
        assert!(rendered.text.contains("sandbox_mode = \"read-only\""));
        assert!(!rendered.text.contains("danger-full-access"));
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("narrowed"))
        );

        agent.permissions = PermissionIntent::allow_only(vec!["Read".into(), "Bash".into()]);
        let rendered = generate(&agent);
        assert!(rendered.text.contains("sandbox_mode = \"workspace-write\""));

        agent.overrides.sandbox_mode = Some("danger-full-access".into());
        agent.permissions = src.permissions.clone();
        let rendered = generate(&agent);
        assert!(
            rendered
                .text
                .contains("sandbox_mode = \"danger-full-access\"")
        );
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("widens"))
        );
    }

    #[test]
    fn nicknames_capitalize_each_part_and_keep_known_acronyms() {
        let reviewer = source("reviewer-arch", "reviewer");
        let tpm = source("tpm", "manager");
        let scope = Scope::Global;
        let reviewer = generate(&effective(&reviewer, &scope)).text;
        let tpm = generate(&effective(&tpm, &scope)).text;
        assert!(reviewer.contains(
            "nickname_candidates = [\"Reviewer-Arch-Atlas\", \"Reviewer-Arch-Delta\", \"Reviewer-Arch-Echo\", \"Reviewer-Arch-Nova\", \"Reviewer-Arch-Orion\", \"Reviewer-Arch-Vector\"]"
        ));
        assert!(tpm.contains("\"TPM-Atlas\""));
        assert!(tpm.contains("- dev: ~/.agents/skills/dev/SKILL.md"));
    }

    #[test]
    fn overrides_replace_sandbox_model_effort_and_nicknames() {
        let source = source("rust", "engineer");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.overrides = FrontmatterOverrides {
            sandbox_mode: Some("read-only".into()),
            model: Some("o9-preview".into()),
            effort: Some("xhigh".into()),
            nickname_candidates: Some(vec!["Rust-One".into(), " ".into()]),
            ..FrontmatterOverrides::default()
        };
        let text = generate(&agent).text;
        assert!(text.contains("sandbox_mode = \"read-only\""));
        assert!(text.contains("model = \"o9-preview\""));
        assert!(text.contains("model_reasoning_effort = \"xhigh\""));
        assert!(text.contains("nickname_candidates = [\"Rust-One\"]"));
    }

    #[test]
    fn the_body_speaks_codex_vocabulary_and_project_instructions_do_not() {
        let mut source = source("rust", "engineer");
        source.body = "Use the Read tool.".into();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.additional_instructions = Some("Use the Read tool.".into());
        let rendered = generate(&agent);
        assert!(rendered.text.contains("Open the file.\n"));
        assert!(
            rendered
                .text
                .contains("## Additional Instructions\n\nUse the Read tool.\n")
        );
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message == "tool references reworded for Codex: Read")
        );
    }

    #[test]
    fn apostrophe_runs_never_close_the_instruction_block() {
        let mut source = source("rust", "engineer");
        source.body = "Use ''' fences sparingly.".into();
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope)).text;
        assert_eq!(text.matches("'''").count(), 2);
        assert!(text.ends_with("'''\n"));
    }
}
