use super::{EffectiveAgent, GENERATED_BANNER, RenderedAgent, hooks_prose, skills_prose};
use crate::harness::models::render_model;
use crate::model::HarnessId;
use crate::render::permission::PermissionIntent;
use crate::render::vocab::{copilot_tool_name, rewrite_prose};
use crate::render::{RenderWarning, yaml_quoted, yaml_scalar};

/// GitHub Copilot custom agent: YAML frontmatter + markdown body, saved as
/// `<name>.agent.md`. `description` is the only required key; `tools` is a
/// real allowlist of tool names, so an `AllowOnly` intent renders natively
/// ([custom agents configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration),
/// matrix §2).
///
/// Explicit ids and consumer-bound classes write their native model selector.
/// The agent file's model outranks the launch's `--model`, so unbound classes
/// and `inherit` leave the key out and use the session's model (D008).
/// Every agent carries `include-custom-instructions: true`, because a
/// custom agent Copilot starts as a subagent reads no AGENTS.md or CLAUDE.md
/// without it. Every kendex agent works under its repository's rules.
pub fn generate(agent: &EffectiveAgent) -> RenderedAgent {
    let source = agent.source;
    let mut warnings = Vec::new();
    let mut fm = String::new();
    let mut push = |line: String| {
        fm.push_str(&line);
        fm.push('\n');
    };

    push(format!("name: {}", yaml_scalar(&source.name)));
    push(format!("description: {}", yaml_quoted(&source.description)));
    push("include-custom-instructions: true".to_owned());
    let model = agent.model_request();
    let resolved = render_model(
        HarnessId::Copilot,
        model,
        &agent.model_classes,
        &agent.model_bindings,
    );
    warnings.extend(resolved.warning.map(RenderWarning::new));
    if let Some(id) = &resolved.id {
        push(format!("model: {}", yaml_scalar(id)));
    }
    if let Some(allow) = allowed(agent) {
        match allow.is_empty() {
            true => push("tools: []".to_owned()),
            false => {
                push("tools:".to_owned());
                for tool in allow {
                    push(format!("  - {}", yaml_scalar(&tool)));
                }
            }
        }
    }
    // Copilot's agent frontmatter carries an allowlist and nothing else, and
    // completing one from a deny list would take the agent's own tools away
    // the moment Copilot grows a built-in it never named.
    if let PermissionIntent::DenyExtra(deny) = &agent.permissions {
        warnings.push(RenderWarning::with_fix(
            format!("Copilot agents take a tool allowlist and no deny list, so this agent keeps access to {}", deny.join(", ")),
            "declare the agent's tools as an allowlist, or drop Copilot from its harnesses",
        ));
    }

    let mut body = format!("---\n{fm}---\n\n{GENERATED_BANNER}\n\n");
    if let Some(launch) = &agent.launch_instructions {
        body.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    let (prose, reworded) = rewrite_prose(source.body.trim_end(), HarnessId::Copilot);
    warnings.extend(reworded);
    body.push_str(&prose);
    body.push('\n');
    // Neither skills nor hooks are agent frontmatter fields, so both travel
    // as prose the agent's own instructions carry (matrix §2).
    if let Some(skills) = skills_prose(agent) {
        body.push_str(&format!("\n{skills}"));
    }
    if let Some(hooks) = hooks_prose(agent) {
        body.push_str(&format!("\n{hooks}\n"));
    }
    if let Some(additional) = &agent.additional_instructions {
        body.push_str(&format!("\n## Additional Instructions\n\n{additional}\n"));
    }
    RenderedAgent {
        text: body,
        warnings,
    }
}

/// The tool allowlist Copilot writes, or `None` where the author stated
/// no allowlist. Copilot's frontmatter carries an allowlist and no deny
/// list, so a deny intent restricts nothing here — the rendering warns
/// about exactly that.
fn allowed(agent: &EffectiveAgent) -> Option<Vec<String>> {
    match &agent.permissions {
        PermissionIntent::AllowOnly { allow, .. } => {
            Some(allow.iter().map(|tool| copilot_tool_name(tool)).collect())
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::super::{SourceAgent, parse_source_agent};
    use super::*;
    use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents};
    use crate::model::Scope;

    fn engineer() -> SourceAgent {
        parse_source_agent(
            "---\nname: rust\ndescription: Rust \"systems\" engineer\nmodel: opus\nrole: engineer\n---\nUse the Grep tool.\n",
        )
        .unwrap()
    }

    fn effective<'a>(
        source: &'a SourceAgent,
        scope: &'a Scope,
        hooks: Vec<&'a CustomHook>,
    ) -> EffectiveAgent<'a> {
        EffectiveAgent {
            model_classes: Default::default(),
            model_bindings: Default::default(),
            source,
            harness: HarnessId::Copilot,
            scope,
            skills: vec![crate::render::agent::linked_skill(
                "dev",
                HarnessId::Copilot,
                scope,
            )],
            overrides: FrontmatterOverrides::default(),
            permissions: PermissionIntent::Unspecified,
            launch_instructions: None,
            additional_instructions: None,
            custom_hooks: hooks,
            role_policy: None,
        }
    }

    /// A tier writes no model: the agent file's model would outrank the one
    /// the launch chose. The repository's rules reach the agent as a
    /// subagent only through `include-custom-instructions`.
    #[test]
    fn frontmatter_names_the_agent_and_leaves_the_model_to_the_session() {
        let source = engineer();
        let scope = Scope::Project { root: "/p".into() };
        let rendered = generate(&effective(&source, &scope, vec![]));
        assert!(
            rendered.text.starts_with(
                "---\nname: rust\ndescription: \"Rust \\\"systems\\\" engineer\"\ninclude-custom-instructions: true\n---\n"
            ),
            "{}",
            rendered.text
        );
        assert!(
            rendered.text.contains("Use the grep tool."),
            "{}",
            rendered.text
        );
        assert!(rendered.text.contains("- dev: .agents/skills/dev/SKILL.md"));
    }

    #[test]
    fn an_inherited_model_leaves_the_key_out_and_an_explicit_id_is_written() {
        let mut source = engineer();
        source.model = "inherit".into();
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope, vec![])).text;
        assert!(!text.contains("model:"), "{text}");
        source.model = "claude-sonnet-5".into();
        let pinned = generate(&effective(&source, &scope, vec![])).text;
        assert!(pinned.contains("\nmodel: claude-sonnet-5\n"), "{pinned}");
        assert!(text.contains("- dev: ~/.agents/skills/dev/SKILL.md"));
    }

    #[test]
    fn an_allowlist_renders_as_copilots_own_tool_names() {
        let source = engineer();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope, vec![]);
        agent.permissions =
            PermissionIntent::allow_only(vec!["read".into(), "bash".into(), "websearch".into()]);
        let text = generate(&agent).text;
        assert!(
            text.contains("tools:\n  - read\n  - bash\n  - websearch\n---\n"),
            "{text}"
        );

        agent.permissions = PermissionIntent::allow_only(vec![]);
        assert!(generate(&agent).text.contains("tools: []\n"));
    }

    /// Nothing Copilot reads can express "everything except these", so the
    /// rendering says plainly that the restriction did not travel.
    #[test]
    fn a_deny_list_warns_instead_of_being_completed_into_an_allowlist() {
        let source = engineer();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope, vec![]);
        agent.permissions = PermissionIntent::DenyExtra(vec!["WebSearch".into()]);
        let rendered = generate(&agent);
        assert!(!rendered.text.contains("tools:"));
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("keeps access to WebSearch"))
        );
    }

    #[test]
    fn custom_hooks_travel_as_prose_and_a_name_cannot_mint_frontmatter() {
        let mut source = engineer();
        source.description = "line one\nmodel: opus".into();
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
        // A tier writes no model line, so any line here came from the name.
        assert_eq!(text.lines().filter(|l| l.starts_with("model:")).count(), 0);
        assert!(text.contains("description: \"line one\\nmodel: opus\""));
        // The matcher is said in this harness's own tool name, not
        // Claude's — the model has never heard of `Bash`.
        let matcher = crate::render::vocab::hook_matcher("Bash", HarnessId::Copilot).0;
        assert!(
            text.contains(&format!("## Safety: PreToolUse on {matcher}")),
            "{text}"
        );
    }
}
