use super::{EffectiveAgent, GENERATED_BANNER, RenderedAgent, Role, hooks_prose, skills_prose};
use crate::harness::models::resolve_model;
use crate::manifest::FrontmatterOverrides;
use crate::model::{HarnessId, Scope};
use crate::render::permission::PermissionIntent;
use crate::render::vocab::{opencode_permission, rewrite_prose};
use crate::render::yaml_scalar;

/// OpenCode agent: YAML frontmatter + markdown system prompt. Tools are
/// controlled by a `permission:` map keyed by permission name, not tool
/// name, so every entry is translated first. An allowlist synthesizes
/// denies over the known permission set — `skill` stays allowed (Claude
/// authors never list it) and unknown entries warn instead of enforcing.
pub fn generate(agent: &EffectiveAgent) -> RenderedAgent {
    let source = agent.source;
    let o = &agent.overrides;
    let mut warnings = Vec::new();
    let mut out = String::from("---\n");
    out.push_str(&format!(
        "description: {}\n",
        yaml_scalar(&source.description)
    ));
    if !source.tags.is_empty() {
        out.push_str(&format!("tags: {}\n", yaml_scalar(&source.tags.join(", "))));
    }
    let mode = mode(o);
    out.push_str(&format!("mode: {mode}\n"));
    let model = o.model.as_deref().unwrap_or(&source.model);
    let resolved = resolve_model(HarnessId::Opencode, model);
    warnings.extend(resolved.warning.map(|w| {
        crate::render::RenderWarning::with_fix(w, "use a provider/model id or a tier alias")
    }));
    // No model line means "inherit the default" — OpenCode has no literal
    // for it, and `openai/inherit` is exactly the invalid id this replaces.
    if let Some(id) = &resolved.id {
        out.push_str(&format!("model: {}\n", yaml_scalar(id)));
    }
    if let Some(color) = o
        .color
        .as_deref()
        .or(source.color.as_deref())
        .and_then(color_hex)
    {
        out.push_str(&format!("color: {}\n", yaml_scalar(&color)));
    }
    let effort = o
        .model_reasoning_effort
        .as_deref()
        .or(o.effort.as_deref())
        .or(source.effort.as_deref())
        .filter(|effort| !is_none_value(effort));
    if let Some(effort) = effort {
        out.push_str(&format!(
            "options:\n  reasoningEffort: {effort}\n  reasoningSummary: auto\n  textVerbosity: medium\n"
        ));
    }
    let denied = denied_permissions(agent, mode, &mut warnings);
    if !denied.is_empty() {
        out.push_str("permission:\n");
        for permission in denied {
            out.push_str(&format!("  {}: deny\n", yaml_scalar(&permission)));
        }
    }
    out.push_str("---\n\n");
    out.push_str(&body(agent, &mut warnings));
    RenderedAgent {
        text: out,
        warnings,
    }
}

/// `all` means "usable either way", which opencode spells `subagent`.
fn mode(o: &FrontmatterOverrides) -> &str {
    match o.mode.as_deref().map(str::trim) {
        Some(mode) if !mode.is_empty() && !mode.eq_ignore_ascii_case("all") => mode,
        _ => "subagent",
    }
}

/// Every permission OpenCode's loader knows; the deny set for an allowlist
/// is enumerated over exactly these.
const KNOWN_PERMISSIONS: [&str; 10] = [
    "read", "edit", "glob", "grep", "bash", "task", "skill", "lsp", "question", "webfetch",
];

/// Subagents never spawn further agents, and only an agent declared
/// `role: planner` may interrupt the user. Primary agents keep both. Policy
/// denies win even over an allowlist entry — restriction always beats
/// permission. An allowlist that
/// maps to no known permission still denies every built-in: `tools:
/// mcp__x` grants exactly the MCP tool, not the MCP tool plus everything.
fn denied_permissions(
    agent: &EffectiveAgent,
    mode: &str,
    warnings: &mut Vec<crate::render::RenderWarning>,
) -> Vec<String> {
    let mut tools: Vec<String> = Vec::new();
    if mode == "subagent" {
        tools.push("task".to_owned());
        if agent.source.role != Some(Role::Planner) {
            tools.push("question".to_owned());
        }
    }
    tools.extend(agent.permissions.denies().iter().cloned());
    let mut permissions: Vec<String> = Vec::new();
    for permission in tools.iter().filter_map(|tool| opencode_permission(tool)) {
        if !permissions.contains(&permission) {
            permissions.push(permission);
        }
    }
    if let PermissionIntent::AllowOnly { allow, .. } = &agent.permissions {
        let mut allowed: Vec<String> = Vec::new();
        for tool in allow {
            match opencode_permission(tool) {
                Some(known) if KNOWN_PERMISSIONS.contains(&known.as_str()) => allowed.push(known),
                _ => warnings.push(crate::render::RenderWarning::new(format!(
                    "tool `{tool}` has no OpenCode permission — it passes through unenforced"
                ))),
            }
        }
        for known in KNOWN_PERMISSIONS {
            if known != "skill"
                && !allowed.iter().any(|a| a == known)
                && !permissions.iter().any(|p| p == known)
            {
                permissions.push(known.to_owned());
            }
        }
    }
    permissions
}

fn color_hex(color: &str) -> Option<String> {
    let color = color.trim();
    if color.starts_with('#')
        && color.len() == 7
        && color.chars().skip(1).all(|ch| ch.is_ascii_hexdigit())
    {
        return Some(color.to_owned());
    }
    let hex = match color.to_lowercase().as_str() {
        "red" | "error" => "#ef4444",
        "green" | "success" => "#22c55e",
        "yellow" | "warning" => "#eab308",
        "orange" => "#f97316",
        "blue" | "primary" | "info" => "#3b82f6",
        "cyan" | "teal" => "#06b6d4",
        "purple" | "violet" | "magenta" | "accent" => "#a855f7",
        "pink" => "#ec4899",
        "secondary" => "#64748b",
        _ => return None,
    };
    Some(hex.to_owned())
}

fn body(agent: &EffectiveAgent, warnings: &mut Vec<crate::render::RenderWarning>) -> String {
    let mut out = format!("{GENERATED_BANNER}\n\n");
    if let Some(launch) = &agent.launch_instructions {
        out.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    let (prose, reworded) = rewrite_prose(agent.source.body.trim_end(), HarnessId::Opencode);
    warnings.extend(reworded);
    out.push_str(&prose);
    out.push('\n');
    let skill_root = match agent.scope {
        Scope::Global => "~/.config/opencode/skills",
        Scope::Project { .. } => ".agents/skills",
    };
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
    use crate::model::HarnessId;

    fn source(name: &str) -> SourceAgent {
        parse_source_agent(&format!(
            "---\nname: {name}\ndescription: OpenCode agent\nmodel: opus\nrole: engineer\ncolor: green\neffort: high\n---\nBody text.\n"
        ))
        .unwrap()
    }

    fn effective<'a>(source: &'a SourceAgent, scope: &'a Scope) -> EffectiveAgent<'a> {
        EffectiveAgent {
            source,
            harness: HarnessId::Opencode,
            scope,
            skills: vec![],
            overrides: FrontmatterOverrides::default(),
            permissions: PermissionIntent::Unspecified,
            launch_instructions: None,
            additional_instructions: None,
            custom_hooks: vec![],
        }
    }

    #[test]
    fn subagents_deny_task_and_questions_with_named_color_mapped_to_hex() {
        let source = source("reviewer");
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope)).text;
        assert!(text.contains("mode: subagent\n"));
        assert!(text.contains("model: openai/gpt-5.6-sol\n"));
        assert!(text.contains("color: \"#22c55e\"\n"));
        assert!(text.contains("options:\n  reasoningEffort: high\n"));
        assert!(text.contains("permission:\n  task: deny\n  question: deny\n"));
    }

    #[test]
    fn planner_keeps_questions_and_hex_color_passes_through() {
        // Named for nothing in particular: `role:` is what keeps the
        // question, so a planner under any name keeps it.
        let source = parse_source_agent(
            "---\nname: strategist\ndescription: OpenCode agent\nmodel: opus\nrole: planner\ncolor: green\neffort: high\n---\nBody text.\n",
        )
        .unwrap();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.overrides = FrontmatterOverrides {
            color: Some("#336699".into()),
            ..FrontmatterOverrides::default()
        };
        let text = generate(&agent).text;
        assert!(text.contains("color: \"#336699\"\n"));
        assert!(text.contains("  task: deny\n"));
        assert!(!text.contains("question: deny"));
    }

    #[test]
    fn deny_tools_collapse_onto_permission_names() {
        let source = source("rust");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.permissions = PermissionIntent::DenyExtra(vec![
            "write".into(),
            "apply_patch".into(),
            "subagent".into(),
            "WebSearch".into(),
            "mcp__custom".into(),
        ]);
        let text = generate(&agent).text;
        assert_eq!(text.matches("  edit: deny\n").count(), 1);
        assert_eq!(text.matches("  task: deny\n").count(), 1);
        assert!(text.contains("  webfetch: deny\n"));
        assert!(text.contains("  mcp__custom: deny\n"));
    }

    #[test]
    fn an_allowlist_denies_every_uncovered_permission_but_never_skill() {
        let source = source("reviewer");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.permissions =
            PermissionIntent::allow_only(vec!["Read".into(), "Grep".into(), "mcp__gh".into()]);
        let rendered = generate(&agent);
        for denied in [
            "edit", "glob", "bash", "lsp", "webfetch", "task", "question",
        ] {
            assert!(
                rendered.text.contains(&format!("  {denied}: deny\n")),
                "{denied} should be denied"
            );
        }
        for kept in ["read", "grep", "skill"] {
            assert!(!rendered.text.contains(&format!("  {kept}: deny\n")));
        }
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("mcp__gh"))
        );
    }

    #[test]
    fn an_mcp_only_allowlist_still_restricts_the_builtins() {
        let source = source("reviewer");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.permissions = PermissionIntent::allow_only(vec!["mcp__github__search".into()]);
        let rendered = generate(&agent);
        for denied in ["read", "edit", "glob", "grep", "bash", "lsp", "webfetch"] {
            assert!(
                rendered.text.contains(&format!("  {denied}: deny\n")),
                "{denied} is not in the allowlist and must be denied"
            );
        }
        assert!(!rendered.text.contains("  skill: deny\n"));
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("mcp__github__search"))
        );
    }

    #[test]
    fn inherit_omits_the_model_line_instead_of_minting_an_invalid_id() {
        let source = source("rust");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.overrides = FrontmatterOverrides {
            model: Some("inherit".into()),
            ..FrontmatterOverrides::default()
        };
        let rendered = generate(&agent);
        assert!(!rendered.text.contains("model:"));
        assert!(!rendered.text.contains("openai/inherit"));
        assert!(rendered.warnings.is_empty());

        agent.overrides.model = Some("mystery".into());
        let rendered = generate(&agent);
        assert!(rendered.text.contains("model: openai/mystery\n"));
        assert!(
            !rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("mystery"))
        );
    }

    #[test]
    fn a_denied_mcp_tool_stays_denied_under_an_allowlist() {
        let source = source("rust");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.permissions = PermissionIntent::effective(
            &PermissionIntent::allow_only(vec!["Read".into(), "mcp__github".into()]),
            None,
            Some(&["mcp__github".to_owned()]),
        );
        assert!(generate(&agent).text.contains("  mcp__github: deny\n"));
    }

    #[test]
    fn the_body_speaks_opencode_vocabulary_and_project_instructions_do_not() {
        let mut source = source("rust");
        source.body = "Use the Read tool.".into();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.additional_instructions = Some("Use the Read tool.".into());
        let rendered = generate(&agent);
        assert!(rendered.text.contains("Use the read tool.\n"));
        assert!(
            rendered
                .text
                .contains("## Additional Instructions\n\nUse the Read tool.\n")
        );
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message == "tool references reworded for OpenCode: Read")
        );
    }

    #[test]
    fn skills_and_hooks_render_as_prose_under_the_scope_root() {
        let source = source("rust");
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
        let mut agent = effective(&source, &scope);
        agent.skills = vec!["dev".into()];
        agent.additional_instructions = Some("end here".into());
        let text = generate(&agent).text;
        assert!(text.contains("- dev: .agents/skills/dev/SKILL.md"));
        assert!(text.trim_end().ends_with("end here"));
    }
}
