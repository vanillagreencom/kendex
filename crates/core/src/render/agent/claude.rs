use super::{EffectiveAgent, GENERATED_BANNER, RenderedAgent, Role, default_pane};
use crate::harness::models::resolve_model;
use crate::model::HarnessId;
use crate::render::permission::{Access, PermissionIntent};
use crate::render::vocab::claude_tool_name;
use crate::render::{yaml_quoted as forced_quote, yaml_scalar};

/// Claude Code agent: YAML frontmatter + markdown body. An `AllowOnly`
/// intent renders as a native `tools:` allowlist; fleet policy denies
/// (`Agent`, `AskUserQuestion`) still apply on top. Every interpolated
/// value goes through `yaml_scalar` — source text must never mint
/// frontmatter lines of its own.
pub fn generate(agent: &EffectiveAgent) -> RenderedAgent {
    let source = agent.source;
    let o = &agent.overrides;
    let mut warnings = Vec::new();
    let mut fm = String::new();
    let mut push = |line: String| {
        fm.push_str(&line);
        fm.push('\n');
    };

    push(format!("name: {}", yaml_scalar(&source.name)));
    push(format!(
        "description: {}",
        forced_quote(&source.description)
    ));
    if !source.tags.is_empty() {
        push(format!("tags: {}", yaml_scalar(&source.tags.join(", "))));
    }
    let model = o.model.as_deref().unwrap_or(&source.model);
    let resolved = resolve_model(HarnessId::Claude, model);
    warnings.extend(resolved.warning.map(crate::render::RenderWarning::new));
    // Claude spells inherit-the-session-model literally.
    push(format!(
        "model: {}",
        yaml_scalar(resolved.id.as_deref().unwrap_or("inherit"))
    ));
    let effort = o.effort.as_deref().or(source.effort.as_deref());
    if let Some(effort) = effort.filter(|e| effort_is_real(e)) {
        push(format!("effort: {}", yaml_scalar(effort)));
    }
    let pane = o.pane.unwrap_or_else(|| default_pane(source));
    let background = o.background.unwrap_or(!pane);
    push(format!("background: {background}"));
    if let Some(isolation) = &o.isolation {
        push(format!("isolation: {}", yaml_scalar(isolation)));
    }
    if let Some(memory) = &o.memory {
        push(format!("memory: {}", yaml_scalar(memory)));
    }
    let access = access(agent);
    if let Some(allow) = &access.allow {
        match allow.is_empty() {
            true => push("tools: []".to_owned()),
            false => push(format!("tools: {}", yaml_scalar(&allow.join(", ")))),
        }
    }
    push(format!(
        "disallowedTools: {}",
        yaml_scalar(&access.deny.join(", "))
    ));
    if let Some(color) = o.color.as_deref().or(source.color.as_deref()) {
        push(format!("color: {}", yaml_scalar(color)));
    }
    if !agent.skills.is_empty() {
        push(format!("skills: {}", yaml_scalar(&agent.skills.join(", "))));
    }
    if !agent.custom_hooks.is_empty() {
        push("hooks:".to_owned());
        for hook in &agent.custom_hooks {
            push(format!("  {}:", yaml_scalar(&hook.event)));
            push(format!(
                "    {}:",
                forced_quote(hook.matcher.as_deref().unwrap_or("*"))
            ));
            push("      - type: command".to_owned());
            push(format!("        command: {}", forced_quote(&hook.command)));
        }
    }

    let mut body = format!("---\n{fm}---\n\n{GENERATED_BANNER}\n\n");
    if let Some(launch) = &agent.launch_instructions {
        body.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    body.push_str(source.body.trim_end());
    body.push('\n');
    if let Some(additional) = &agent.additional_instructions {
        body.push_str(&format!("\n## Additional Instructions\n\n{additional}\n"));
    }
    RenderedAgent {
        text: body,
        warnings,
    }
}

/// What Claude's own rules leave this agent able to use: the intent's
/// allowlist in Claude's tool names, and [`deny_list`]. The rendering
/// writes these two lines out of this, so nothing states the policy twice.
fn access(agent: &EffectiveAgent) -> Access {
    Access {
        allow: match &agent.permissions {
            PermissionIntent::AllowOnly { allow, .. } => {
                Some(allow.iter().map(|tool| claude_tool_name(tool)).collect())
            }
            _ => None,
        },
        deny: deny_list(agent),
    }
}

/// `Agent` is always denied to subagents; `AskUserQuestion` unless the
/// author declared `role: planner`; the intent's extra denies append after.
fn deny_list(agent: &EffectiveAgent) -> Vec<String> {
    let mut deny = vec!["Agent".to_owned()];
    if agent.source.role != Some(Role::Planner) {
        deny.push("AskUserQuestion".to_owned());
    }
    for tool in agent.permissions.denies() {
        let tool = claude_tool_name(tool);
        if !deny.contains(&tool) {
            deny.push(tool);
        }
    }
    deny
}

fn effort_is_real(effort: &str) -> bool {
    !matches!(effort, "" | "none" | "false" | "off" | "no")
}

#[cfg(test)]
mod tests {
    use super::super::{Role, SourceAgent, parse_source_agent};
    use super::*;
    use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents};
    use crate::model::{HarnessId, Scope};

    fn engineer() -> SourceAgent {
        parse_source_agent(
            "---\nname: rust\ndescription: Rust \"systems\" engineer\nmodel: opus\nrole: engineer\ncolor: orange\n---\nBody text.\n",
        )
        .unwrap()
    }

    /// A source's `tags:` line survives into the rendering — the header is
    /// where an item says what it is for (invariant 15), and a renderer
    /// that dropped it would silently untag every managed agent.
    #[test]
    fn tags_ride_from_source_into_the_rendering() {
        let source = parse_source_agent(
            "---\nname: rust\ndescription: Rust engineer\ntags: performance, refactoring\n---\nBody.\n",
        )
        .unwrap();
        assert_eq!(source.tags, vec!["performance", "refactoring"]);
        assert!(source.warnings.is_empty(), "{:?}", source.warnings);
        let scope = Scope::Global;
        let rendered = generate(&effective(&source, &scope, Vec::new()));
        assert!(
            rendered.text.contains("tags: performance, refactoring"),
            "{}",
            rendered.text
        );
    }

    fn effective<'a>(
        source: &'a SourceAgent,
        scope: &'a Scope,
        hooks: Vec<&'a CustomHook>,
    ) -> EffectiveAgent<'a> {
        EffectiveAgent {
            source,
            harness: HarnessId::Claude,
            scope,
            skills: vec!["dev".into(), "rust-perf".into()],
            overrides: FrontmatterOverrides::default(),
            permissions: PermissionIntent::Unspecified,
            launch_instructions: Some("start here".into()),
            additional_instructions: Some("end here".into()),
            custom_hooks: hooks,
        }
    }

    #[test]
    fn engineer_defaults_pane_true_background_false_and_opus_inherits() {
        let source = engineer();
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope, vec![])).text;
        assert!(text.contains("model: inherit"));
        assert!(text.contains("background: false"));
        assert!(text.contains("disallowedTools: Agent, AskUserQuestion"));
        assert!(text.contains("skills: dev, rust-perf"));
        assert!(text.contains("description: \"Rust \\\"systems\\\" engineer\""));
        assert!(text.contains("## Launch Instructions\n\nstart here"));
        assert!(text.trim_end().ends_with("end here"));
        assert!(text.contains("color: orange"));
    }

    #[test]
    fn planner_keeps_questions_and_custom_hooks_render_native() {
        let mut source = engineer();
        // Named for nothing in particular: `role:` is what keeps the
        // question, so a planner under any name keeps it.
        source.name = "strategist".into();
        source.role = Some(Role::Planner);
        let scope = Scope::Global;
        let hook = CustomHook {
            name: None,
            event: "PreToolUse".into(),
            matcher: Some("Bash".into()),
            command: "./guard.sh".into(),
            description: None,
            timeout: None,
            harnesses: None,
            enabled: true,
            agents: HookAgents::One("all".into()),
        };
        let text = generate(&effective(&source, &scope, vec![&hook])).text;
        assert!(text.contains("disallowedTools: Agent\n"));
        assert!(!text.contains("AskUserQuestion"));
        assert!(text.contains("hooks:\n  PreToolUse:\n    \"Bash\":"));
        assert!(text.contains("command: \"./guard.sh\""));
        // planner is not an engineer, but the planner pane default applies
        assert!(text.contains("background: false"));
    }

    #[test]
    fn overrides_beat_source_and_deny_tools_append() {
        let source = engineer();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope, vec![]);
        agent.overrides = FrontmatterOverrides {
            model: Some("sonnet".into()),
            pane: Some(false),
            color: Some("blue".into()),
            ..FrontmatterOverrides::default()
        };
        agent.permissions = PermissionIntent::DenyExtra(vec!["WebSearch".into()]);
        let text = generate(&agent).text;
        assert!(text.contains("model: sonnet"));
        assert!(text.contains("background: true"));
        assert!(text.contains("disallowedTools: Agent, AskUserQuestion, WebSearch"));
        assert!(text.contains("color: blue"));
    }

    #[test]
    fn an_allowlist_renders_as_a_native_tools_line() {
        let source = engineer();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope, vec![]);
        agent.permissions = PermissionIntent::allow_only(vec!["read".into(), "grep".into()]);
        let text = generate(&agent).text;
        assert!(text.contains("tools: Read, Grep\n"));
        assert!(text.contains("disallowedTools: Agent, AskUserQuestion"));

        agent.permissions = PermissionIntent::allow_only(vec![]);
        let text = generate(&agent).text;
        assert!(text.contains("tools: []\n"));
    }

    #[test]
    fn a_tool_name_cannot_inject_frontmatter_lines() {
        let source = engineer();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope, vec![]);
        agent.permissions =
            PermissionIntent::allow_only(vec!["Read".into(), "Bash\nmodel: opus".into()]);
        let text = generate(&agent).text;
        let model_lines = text.lines().filter(|l| l.starts_with("model:")).count();
        assert_eq!(model_lines, 1);
        assert!(text.contains("tools: \"Read, Bash\\nmodel: opus\"\n"));

        let mut description = engineer();
        description.description = "line one\ndisallowedTools: nothing".into();
        let agent = effective(&description, &scope, vec![]);
        let text = generate(&agent).text;
        let deny_lines = text
            .lines()
            .filter(|l| l.starts_with("disallowedTools:"))
            .count();
        assert_eq!(deny_lines, 1);
        assert!(!text.contains("\nline one\n"));
    }
}
