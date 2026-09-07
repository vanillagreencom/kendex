use super::{EffectiveAgent, GENERATED_BANNER, RenderedAgent, hooks_prose, skills_prose};
use crate::harness::models::resolve_model;
use crate::model::HarnessId;
use crate::render::permission::PermissionIntent;
use crate::render::vocab::{antigravity_tool_name, rewrite_prose};
use crate::render::{RenderWarning, yaml_quoted, yaml_scalar};

/// Antigravity custom agent: YAML frontmatter + markdown body, saved as
/// `<name>.md`. `name` and `description` are required; `model` is a tier
/// of the loader's own (`inherit`, `flash`, `pro`) and is written only
/// when a tier was asked for; `subagent: true` lets the primary agent
/// delegate to it; `tools` is an allowlist of Antigravity's own tool names,
/// and a name it has no word for is left out rather than written, since
/// the loader documents that an unknown name there can hang the subagent
/// (<https://antigravity.google/docs/subagents>). The file carries no
/// effort key, so an effort setting renders nothing here.
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
    let model = agent.overrides.model.as_deref().unwrap_or(&source.model);
    let resolved = resolve_model(HarnessId::Antigravity, model);
    warnings.extend(resolved.warning.map(RenderWarning::new));
    if let Some(id) = &resolved.id {
        push(format!("model: {}", yaml_scalar(id)));
    }
    push("subagent: true".to_owned());
    if let PermissionIntent::AllowOnly { allow, .. } = &agent.permissions {
        let (named, unknown): (Vec<&String>, Vec<&String>) = allow
            .iter()
            .partition(|tool| antigravity_tool_name(tool).is_some());
        if !unknown.is_empty() {
            warnings.push(RenderWarning::with_fix(
                format!(
                    "Antigravity has no tool named {}, and an unknown name in its allowlist can hang the subagent, so the agent installs without it",
                    unknown
                        .iter()
                        .map(|tool| format!("`{tool}`"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
                "name the tool as Antigravity does (`view_file`, `run_command`, `grep_search`), or drop it from the allowlist",
            ));
        }
        match named.is_empty() {
            true => push("tools: []".to_owned()),
            false => {
                push("tools:".to_owned());
                for tool in named {
                    let own = antigravity_tool_name(tool).unwrap_or_default();
                    push(format!("  - {}", yaml_scalar(own)));
                }
            }
        }
    }
    // The frontmatter carries an allowlist and no deny list, and completing
    // one from a deny list would take the agent's own tools away the moment
    // the loader grows a built-in it never named.
    if let PermissionIntent::DenyExtra(deny) = &agent.permissions {
        warnings.push(RenderWarning::with_fix(
            format!(
                "Antigravity agents take a tool allowlist and no deny list, so this agent keeps access to {}",
                deny.join(", ")
            ),
            "declare the agent's tools as an allowlist, or drop Antigravity from its harnesses",
        ));
    }

    let mut body = format!("---\n{fm}---\n\n{GENERATED_BANNER}\n\n");
    if let Some(launch) = &agent.launch_instructions {
        body.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    let (prose, reworded) = rewrite_prose(source.body.trim_end(), HarnessId::Antigravity);
    warnings.extend(reworded);
    body.push_str(&prose);
    body.push('\n');
    // The frontmatter's `skills:` list names paths under the customization
    // root; kendex does not yet write it, so skills and hooks travel as
    // prose the agent's own instructions carry.
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

#[cfg(test)]
mod tests {
    use super::super::{SourceAgent, parse_source_agent};
    use super::*;
    use crate::manifest::FrontmatterOverrides;
    use crate::model::Scope;

    fn source(model: &str) -> SourceAgent {
        parse_source_agent(&format!(
            "---\nname: rust\ndescription: Rust \"systems\" engineer\nmodel: {model}\nrole: engineer\neffort: high\n---\nUse the Bash tool.\n"
        ))
        .unwrap()
    }

    fn effective<'a>(source: &'a SourceAgent, scope: &'a Scope) -> EffectiveAgent<'a> {
        EffectiveAgent {
            source,
            harness: HarnessId::Antigravity,
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
    fn a_tier_is_the_loaders_own_and_inherit_leaves_the_key_out() {
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
        let pro = generate(&effective(&source("opus"), &scope)).text;
        assert!(pro.starts_with("---\nname: rust\ndescription: \"Rust \\\"systems\\\" engineer\"\nmodel: pro\nsubagent: true\n---\n"), "{pro}");
        assert!(!pro.contains("effort"), "{pro}");
        assert!(pro.contains("- dev: .agents/skills/dev/SKILL.md"));
        let inherited = generate(&effective(&source("inherit"), &scope)).text;
        assert!(!inherited.contains("model:"), "{inherited}");
        let flash = generate(&effective(&source("haiku"), &scope)).text;
        assert!(flash.contains("model: flash\n"), "{flash}");
    }

    /// The allowlist arrives in Claude's names and leaves in Antigravity's;
    /// a name Antigravity lacks is left out and said, never written.
    #[test]
    fn an_allowlist_renders_in_antigravitys_names_and_a_deny_list_warns() {
        let scope = Scope::Global;
        let source = source("inherit");
        let mut agent = effective(&source, &scope);
        agent.permissions =
            PermissionIntent::allow_only(vec!["Read".into(), "Bash".into(), "mcp__gh".into()]);
        let rendered = generate(&agent);
        assert!(
            rendered
                .text
                .contains("tools:\n  - view_file\n  - run_command\n---"),
            "{}",
            rendered.text
        );
        assert!(!rendered.text.contains("mcp__gh"), "{}", rendered.text);
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("`mcp__gh`")),
            "{:?}",
            rendered.warnings
        );
        agent.permissions = PermissionIntent::DenyExtra(vec!["run_command".into()]);
        let rendered = generate(&agent);
        assert!(!rendered.text.contains("tools:"));
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message.contains("no deny list"))
        );
    }
}
