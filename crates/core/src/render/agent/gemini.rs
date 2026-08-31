use super::{EffectiveAgent, GENERATED_BANNER, RenderedAgent, hooks_prose, skills_prose};
use crate::harness::models::resolve_model;
use crate::model::{HarnessId, Scope};
use crate::render::permission::PermissionIntent;
use crate::render::vocab::{gemini_tool_name, rewrite_prose};
use crate::render::{RenderWarning, yaml_quoted, yaml_scalar};

/// Gemini CLI subagent: YAML frontmatter + markdown body, where the body is
/// the system prompt. `name` and `description` are the only required keys;
/// `tools` is a real allowlist, so an `AllowOnly` intent renders natively
/// and nothing has to be complemented (matrix §1, §D4).
///
/// `kind: local` is written out because it is the only kind kendex manages —
/// a remote subagent runs off this machine, and kendex neither installs nor
/// claims one (§R3).
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
    if !source.tags.is_empty() {
        push(format!("tags: {}", yaml_scalar(&source.tags.join(", "))));
    }
    push("kind: local".to_owned());
    let model = agent.overrides.model.as_deref().unwrap_or(&source.model);
    let resolved = resolve_model(HarnessId::Gemini, model);
    warnings.extend(resolved.warning.map(RenderWarning::new));
    // Gemini spells inherit-the-session-model literally, in agent
    // frontmatter only (matrix §4).
    push(format!(
        "model: {}",
        yaml_scalar(resolved.id.as_deref().unwrap_or("inherit"))
    ));
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
    // Gemini's agent frontmatter carries an allowlist and nothing else, and
    // completing one from a deny list would take the agent's own tools away
    // the moment Gemini grows a built-in it never named.
    if let PermissionIntent::DenyExtra(deny) = &agent.permissions {
        warnings.push(RenderWarning::with_fix(
            format!("Gemini subagents take a tool allowlist and no deny list, so this agent keeps access to {}", deny.join(", ")),
            "declare the agent's tools as an allowlist, or drop Gemini from its harnesses",
        ));
    }

    let mut body = format!("---\n{fm}---\n\n{GENERATED_BANNER}\n\n");
    if let Some(launch) = &agent.launch_instructions {
        body.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    let (prose, reworded) = rewrite_prose(source.body.trim_end(), HarnessId::Gemini);
    warnings.extend(reworded);
    body.push_str(&prose);
    body.push('\n');
    // Neither skills nor per-agent hooks are subagent frontmatter fields, so
    // both travel as prose the system prompt carries (matrix §1).
    let skill_root = match agent.scope {
        Scope::Global => "~/.gemini/skills",
        Scope::Project { .. } => ".agents/skills",
    };
    if let Some(skills) = skills_prose(agent, skill_root) {
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

/// The tool allowlist Gemini writes, or `None` where the author stated no
/// allowlist. Gemini's frontmatter carries an allowlist and no deny list,
/// so a deny intent restricts nothing here — the rendering warns about
/// exactly that.
fn allowed(agent: &EffectiveAgent) -> Option<Vec<String>> {
    match &agent.permissions {
        PermissionIntent::AllowOnly { allow, .. } => {
            Some(allow.iter().map(|tool| gemini_tool_name(tool)).collect())
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::super::{SourceAgent, parse_source_agent};
    use super::*;
    use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents};

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
            source,
            harness: HarnessId::Gemini,
            scope,
            skills: vec!["dev".into()],
            overrides: FrontmatterOverrides::default(),
            permissions: PermissionIntent::Unspecified,
            launch_instructions: None,
            additional_instructions: None,
            custom_hooks: hooks,
        }
    }

    #[test]
    fn frontmatter_names_the_agent_and_pins_the_gemini_tier() {
        let source = engineer();
        let scope = Scope::Project { root: "/p".into() };
        let rendered = generate(&effective(&source, &scope, vec![]));
        assert!(rendered.text.starts_with(
            "---\nname: rust\ndescription: \"Rust \\\"systems\\\" engineer\"\nkind: local\nmodel: gemini-3-pro-preview\n---\n"
        ));
        assert!(rendered.text.contains("Use the grep_search tool."));
        assert!(rendered.text.contains("- dev: .agents/skills/dev/SKILL.md"));
        assert!(rendered.warnings.iter().any(|w| w.message.contains("Grep")));
    }

    #[test]
    fn an_allowlist_renders_as_gemini_s_own_tool_identifiers() {
        let source = engineer();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope, vec![]);
        agent.permissions =
            PermissionIntent::allow_only(vec!["read".into(), "bash".into(), "websearch".into()]);
        let text = generate(&agent).text;
        assert!(text.contains(
            "tools:\n  - read_file\n  - run_shell_command\n  - google_web_search\n---\n"
        ));
        assert!(text.contains("- dev: ~/.gemini/skills/dev/SKILL.md"));

        agent.permissions = PermissionIntent::allow_only(vec![]);
        assert!(generate(&agent).text.contains("tools: []\n"));
    }

    /// Nothing Gemini reads can express "everything except these", so the
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
        assert_eq!(text.lines().filter(|l| l.starts_with("model:")).count(), 1);
        assert!(text.contains("description: \"line one\\nmodel: opus\""));
        // The matcher is said in this harness's own tool name, not
        // Claude's — the model has never heard of `Bash`.
        let matcher = crate::render::vocab::hook_matcher("Bash", HarnessId::Gemini).0;
        assert!(
            text.contains(&format!("## Safety: PreToolUse on {matcher}")),
            "{text}"
        );
    }
}
