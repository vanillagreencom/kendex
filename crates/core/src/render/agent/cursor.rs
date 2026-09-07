use super::{EffectiveAgent, GENERATED_BANNER, RenderedAgent, hooks_prose};
use crate::model::HarnessId;
use crate::render::permission::PermissionIntent;
use crate::render::vocab::rewrite_prose;

/// Cursor has no agents — an agent installs as a rule file. Rules carry no
/// model, tool, skill or hook fields, so only the prompt survives. A rule
/// grants no tools, so permission intent is advisory here, not widened —
/// but the user should hear that nothing enforces it.
pub fn generate(agent: &EffectiveAgent) -> RenderedAgent {
    let mut warnings = Vec::new();
    if !matches!(agent.permissions, PermissionIntent::Unspecified) {
        warnings.push(crate::render::RenderWarning::with_fix(
            "Cursor rules carry no tool permissions — this agent's tool restrictions are advisory text only",
            "exclude Cursor from this agent's harnesses if the restriction must be enforced",
        ));
    }
    let source = agent.source;
    let mut out = String::from("---\n");
    out.push_str(&format!(
        "description: {}\n",
        crate::render::yaml_quoted(&format!("{} — {}", source.name, source.description))
    ));
    out.push_str("alwaysApply: false\n---\n\n");
    out.push_str(&format!("{GENERATED_BANNER}\n\n"));
    if let Some(launch) = &agent.launch_instructions {
        out.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    let (prose, reworded) = rewrite_prose(source.body.trim_end(), HarnessId::Cursor);
    warnings.extend(reworded);
    out.push_str(&prose);
    out.push('\n');
    // A rule carries no hook field, so a custom hook can only be written
    // here as words. Dropping it silently was the worse answer: the person
    // who wrote the hook would have no way to learn Cursor never got it.
    if let Some(hooks) = hooks_prose(agent) {
        out.push_str(&format!("\n{hooks}\n"));
        warnings.push(crate::render::RenderWarning::with_fix(
            "Cursor cannot run hooks — this agent's custom hooks are written into the rule as instructions only",
            "exclude Cursor from this agent's harnesses if the hook must be enforced",
        ));
    }
    if let Some(additional) = &agent.additional_instructions {
        out.push_str(&format!("\n## Additional Instructions\n\n{additional}\n"));
    }
    RenderedAgent {
        text: out,
        warnings,
    }
}

#[cfg(test)]
mod tests {
    use super::super::{SourceAgent, parse_source_agent};
    use super::*;
    use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents};
    use crate::model::{HarnessId, Scope};

    fn source() -> SourceAgent {
        parse_source_agent(
            "---\nname: rust\ndescription: Rust engineer\nmodel: opus\nrole: engineer\ncolor: orange\n---\nBody text.\n",
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
            harness: HarnessId::Cursor,
            scope,
            skills: vec![crate::render::agent::linked_skill(
                "dev",
                HarnessId::Cursor,
                scope,
            )],
            overrides: FrontmatterOverrides {
                model: Some("sonnet".into()),
                color: Some("blue".into()),
                ..FrontmatterOverrides::default()
            },
            permissions: PermissionIntent::Unspecified,
            launch_instructions: Some("start here".into()),
            additional_instructions: Some("end here".into()),
            custom_hooks: hooks,
        }
    }

    #[test]
    fn frontmatter_is_only_a_description_and_always_apply_false() {
        let source = source();
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
        let text = generate(&effective(&source, &scope, vec![])).text;
        assert!(
            text.starts_with(
                "---\ndescription: \"rust — Rust engineer\"\nalwaysApply: false\n---\n"
            )
        );
        assert!(!text.contains("model:"));
        assert!(!text.contains("color:"));
    }

    #[test]
    fn skills_are_dropped_but_hooks_are_said_and_instructions_survive() {
        let source = source();
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
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
        let rendered = generate(&effective(&source, &scope, vec![&hook]));
        let text = rendered.text;
        assert!(!text.contains("Required Skills"));
        // A rule cannot run a hook, but dropping it left the author with no
        // way to find that out — it lands as words, and the warning says so.
        assert!(text.contains("guard.sh"), "{text}");
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("cannot run hooks")),
            "{:?}",
            rendered.warnings
        );
        assert!(text.contains("## Launch Instructions\n\nstart here"));
        assert!(text.contains("Body text."));
        assert!(text.contains("end here"));
    }

    #[test]
    fn the_rule_speaks_cursor_vocabulary_and_project_instructions_do_not() {
        let mut source = source();
        source.body = "Use the Bash tool.".into();
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
        let rendered = generate(&effective(&source, &scope, vec![]));
        assert!(rendered.text.contains("Use the bash tool.\n"));
        assert!(
            rendered
                .text
                .contains("## Additional Instructions\n\nend here\n")
        );
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message == "tool references reworded for Cursor: Bash")
        );
    }

    #[test]
    fn permission_intent_warns_that_cursor_cannot_enforce_it() {
        let source = source();
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
        let mut agent = effective(&source, &scope, vec![]);
        agent.permissions = PermissionIntent::allow_only(vec!["Read".into()]);
        let rendered = generate(&agent);
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("advisory"))
        );
    }
}
