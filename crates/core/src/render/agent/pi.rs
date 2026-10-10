use super::{
    EffectiveAgent, GENERATED_BANNER, RenderedAgent, default_pane, hooks_prose, skills_prose,
};
use crate::model::HarnessId;
use crate::render::permission::PermissionIntent;
use crate::render::vocab::rewrite_prose;
use crate::render::yaml_scalar;

/// Pi agent: YAML frontmatter + markdown body. Delegation is the whole story
/// here — `allowed-subagents` and `deny-tools` have to agree, so they are
/// resolved together. Pi's tool surface is deny-only over an open-ended
/// vocabulary: an allowlist cannot be expressed and cannot be complemented
/// without widening, so it refuses.
pub fn generate(agent: &EffectiveAgent) -> Result<RenderedAgent, String> {
    let deny = denied(agent)?;
    let source = agent.source;
    let o = &agent.overrides;
    let allowed = allowed_subagents(agent);
    let mut out = String::from("---\n");
    out.push_str(&format!("name: {}\n", yaml_scalar(&source.name)));
    out.push_str(&format!(
        "description: {}\n",
        crate::render::yaml_quoted(&source.description)
    ));
    if !source.tags.is_empty() {
        out.push_str(&format!("tags: {}\n", yaml_scalar(&source.tags.join(", "))));
    }
    if !deny.is_empty() {
        out.push_str(&format!("deny-tools: {}\n", yaml_scalar(&deny.join(", "))));
    }
    if !allowed.is_empty() {
        out.push_str(&format!(
            "allowed-subagents: {}\n",
            yaml_scalar(&allowed.join(", "))
        ));
    }
    let mut warnings = Vec::new();
    let effort = effort(agent);
    let (model, model_warning) = model(agent, effort);
    warnings.extend(model_warning.map(|w| {
        crate::render::RenderWarning::with_fix(w, "use a provider/model id or a tier alias")
    }));
    if let Some(model) = model {
        out.push_str(&format!("model: {}\n", yaml_scalar(&model)));
    }
    if let Some(effort) = effort {
        out.push_str(&format!("effort: {}\n", yaml_scalar(effort)));
    }
    if let Some(color) = o.color.as_deref().or(source.color.as_deref()) {
        out.push_str(&format!("color: {}\n", yaml_scalar(color)));
    }
    if o.pane.unwrap_or_else(|| default_pane(source)) {
        out.push_str("pane: true\n");
    }
    out.push_str("---\n\n");
    out.push_str(&body(agent, &mut warnings));
    Ok(RenderedAgent {
        text: out,
        warnings,
    })
}

/// The effort the child runs at, under either spelling of the override.
/// It is written as its own `effort:` key — the key the subagent extension
/// reads and turns into `--thinking` — because a suffix on the model id
/// has nowhere to sit when the model inherits.
fn effort<'b>(agent: &'b EffectiveAgent<'_>) -> Option<&'b str> {
    agent
        .overrides
        .model_reasoning_effort
        .as_deref()
        .or(agent.overrides.effort.as_deref())
        .or(agent.source.effort.as_deref())
        .filter(|effort| !is_none_value(effort))
}

/// Preserve class intent for the child dispatcher. The effort suffix uses
/// the same native field as exact ids, without selecting a version here.
fn model(agent: &EffectiveAgent, effort: Option<&str>) -> (Option<String>, Option<String>) {
    let model = agent.model_request();
    let resolved = crate::harness::models::render_model(
        crate::model::HarnessId::Pi,
        model,
        &agent.model_classes,
        &agent.model_bindings,
    );
    let suffix = effort.map(|e| format!(":{e}")).unwrap_or_default();
    (
        resolved.id.map(|id| format!("{id}{suffix}")),
        resolved.warning,
    )
}

/// The override's delegates, else the role policy's; an agent with
/// neither stays a leaf.
fn allowed_subagents(agent: &EffectiveAgent) -> Vec<String> {
    let list = match &agent.overrides.allowed_subagents {
        Some(list) => list.clone(),
        None => agent.role_rule().allowed_subagents,
    };
    let mut out: Vec<String> = Vec::new();
    for name in list {
        let name = name.trim().to_owned();
        if name.is_empty() || out.iter().any(|kept| kept.eq_ignore_ascii_case(&name)) {
            continue;
        }
        out.push(name);
    }
    out
}

/// The deny list Pi writes. `Err` is Pi refusing the intent, the refusal
/// [`generate`] returns: nothing is installed at all. Pi's surface is
/// deny-only over an open-ended vocabulary, so there is no allow side.
fn denied(agent: &EffectiveAgent) -> Result<Vec<String>, String> {
    if matches!(agent.permissions, PermissionIntent::AllowOnly { .. }) {
        return Err(
            "Pi cannot express a tool allowlist and denying by complement would widen access — set an explicit deny-tools override for Pi or exclude Pi from this agent's harnesses"
                .to_owned(),
        );
    }
    Ok(deny_tools(agent, &allowed_subagents(agent)))
}

fn deny_tools(agent: &EffectiveAgent, allowed: &[String]) -> Vec<String> {
    let user = agent.permissions.denies();
    let mut tools: Vec<String> = [
        "subagent",
        "get_subagent_result",
        "steer_subagent",
        "stop_subagent",
    ]
    .iter()
    .map(|tool| (*tool).to_owned())
    .collect();
    if allowed.is_empty() {
        tools.push("delegate_subagent".to_owned());
    }
    tools.extend(agent.role_rule().deny_tools);
    tools.extend(user.iter().cloned());

    let mut out: Vec<String> = Vec::new();
    for tool in tools {
        if tool.trim().is_empty() || out.iter().any(|kept| normalize(kept) == normalize(&tool)) {
            continue;
        }
        out.push(tool);
    }
    out
}

fn normalize(tool: &str) -> String {
    tool.trim().to_lowercase().replace('-', "_")
}

fn body(agent: &EffectiveAgent, warnings: &mut Vec<crate::render::RenderWarning>) -> String {
    let mut out = format!("{GENERATED_BANNER}\n\n");
    if let Some(launch) = &agent.launch_instructions {
        out.push_str(&format!("## Launch Instructions\n\n{launch}\n\n"));
    }
    let (prose, reworded) = rewrite_prose(agent.source.body.trim_end(), HarnessId::Pi);
    warnings.extend(reworded);
    out.push_str(&prose);
    out.push('\n');
    if let Some(skills) = skills_prose(agent) {
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
    use crate::manifest::FrontmatterOverrides;
    use crate::model::{HarnessId, Scope};

    fn source(name: &str, role: &str, model: &str) -> SourceAgent {
        parse_source_agent(&format!(
            "---\nname: {name}\ndescription: Pi agent\nmodel: {model}\nrole: {role}\ncolor: green\n---\nBody text.\n"
        ))
        .unwrap()
    }

    fn effective<'a>(source: &'a SourceAgent, scope: &'a Scope) -> EffectiveAgent<'a> {
        EffectiveAgent {
            model_classes: Default::default(),
            model_bindings: Default::default(),
            source,
            harness: HarnessId::Pi,
            scope,
            skills: vec![],
            overrides: FrontmatterOverrides::default(),
            permissions: PermissionIntent::Unspecified,
            launch_instructions: None,
            additional_instructions: None,
            custom_hooks: vec![],
            role_policy: None,
        }
    }

    fn deny_line(text: &str) -> String {
        text.lines()
            .find(|line| line.starts_with("deny-tools:"))
            .unwrap_or_default()
            .to_owned()
    }

    #[test]
    fn engineer_keeps_scout_delegation_and_standard_class_intent() {
        let mut source = source("rust", "engineer", "opus");
        source.effort = Some("high".into());
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope)).unwrap().text;
        assert!(text.contains("allowed-subagents: scout\n"));
        assert!(text.contains("pane: true\n"));
        assert!(text.contains("color: green\n"));
        assert!(text.contains("model: standard:high\n"));
        assert!(text.contains("effort: high\n"));
        assert_eq!(
            deny_line(&text),
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question"
        );
    }

    #[test]
    fn reviewer_loses_delegation_and_task_writes_and_keeps_light_intent() {
        let mut source = source("reviewer-arch", "reviewer", "sonnet");
        source.effort = Some("high".into());
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope)).unwrap().text;
        assert!(text.contains("model: light:high\n"));
        assert!(text.contains("effort: high\n"));
        assert!(!text.contains("allowed-subagents:"));
        assert!(!text.contains("pane: true"));
        assert_eq!(
            deny_line(&text),
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, delegate_subagent, question, tasks_write"
        );
    }

    #[test]
    fn an_explicit_delegate_deny_survives_a_live_allowlist() {
        let source = source("rust", "engineer", "opus");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.permissions = PermissionIntent::DenyExtra(vec!["delegate-subagent".into()]);
        let text = generate(&agent).unwrap().text;
        assert!(deny_line(&text).contains("delegate-subagent"));
        assert!(text.contains("allowed-subagents: scout\n"));

        agent.permissions = PermissionIntent::Unspecified;
        agent.overrides = FrontmatterOverrides {
            allowed_subagents: Some(vec![]),
            ..FrontmatterOverrides::default()
        };
        let text = generate(&agent).unwrap().text;
        assert!(!text.contains("allowed-subagents:"));
        assert!(deny_line(&text).contains("delegate_subagent"));
    }

    /// A catalog's declared policy replaces the fleet default: an engineer
    /// it names nothing for delegates to no `scout` and keeps `question`,
    /// and a role it names gets exactly its delegates and denies.
    #[test]
    fn a_declared_role_policy_replaces_scout_and_the_role_denies() {
        let table: toml::Table =
            "[role-policy.pi.reviewer]\ndeny-tools = [\"bash\"]\nallowed-subagents = [\"probe\"]\n"
                .parse()
                .unwrap();
        let policy = crate::render::agent::RolePolicy::parse(&table["role-policy"]).unwrap();
        let scope = Scope::Global;
        let engineer = source("rust", "engineer", "opus");
        let mut agent = effective(&engineer, &scope);
        agent.role_policy = Some(&policy);
        let text = generate(&agent).unwrap().text;
        assert!(!text.contains("allowed-subagents:"), "{text}");
        assert_eq!(
            deny_line(&text),
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, delegate_subagent"
        );

        let reviewer = source("reviewer-arch", "reviewer", "sonnet");
        let mut agent = effective(&reviewer, &scope);
        agent.role_policy = Some(&policy);
        let text = generate(&agent).unwrap().text;
        assert!(text.contains("allowed-subagents: probe\n"), "{text}");
        assert_eq!(
            deny_line(&text),
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, bash"
        );

        // The allowlist refusal holds under a declared policy too.
        agent.permissions = PermissionIntent::allow_only(vec!["read".into()]);
        assert!(generate(&agent).is_err());
    }

    #[test]
    fn a_tool_allowlist_refuses_rather_than_widens() {
        let source = source("reviewer-arch", "reviewer", "sonnet");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.permissions = PermissionIntent::allow_only(vec!["read".into()]);
        let refusal = generate(&agent).unwrap_err();
        assert!(refusal.contains("widen"));
    }

    /// Delegates do not remove denies declared by the catalog, a carried
    /// role rule, or the agent's permission intent.
    #[test]
    fn an_explicit_delegation_deny_survives_a_delegate_list() {
        let table: toml::Table =
            "[role-policy.pi.engineer]\ndeny-tools = [\"delegate-subagent\"]\nallowed-subagents = [\"probe\"]\n"
                .parse()
                .unwrap();
        let policy = crate::render::agent::RolePolicy::parse(&table["role-policy"]).unwrap();
        let source = source("rust", "engineer", "opus");
        let scope = Scope::Global;
        for origin in ["catalog", "carried", "permissions"] {
            let mut agent = effective(&source, &scope);
            match origin {
                "catalog" => agent.role_policy = Some(&policy),
                "carried" => {
                    agent.overrides.role_deny_tools = Some(vec!["delegate-subagent".into()]);
                }
                "permissions" => {
                    agent.permissions =
                        PermissionIntent::DenyExtra(vec!["delegate-subagent".into()]);
                }
                _ => unreachable!(),
            }
            agent.overrides.allowed_subagents = Some(vec!["probe".into()]);
            let text = generate(&agent).unwrap().text;
            assert!(
                text.contains("allowed-subagents: probe\n"),
                "{origin}: {text}"
            );
            assert!(
                deny_line(&text).contains("delegate-subagent"),
                "{origin}: {text}"
            );
        }
    }

    #[test]
    fn the_body_speaks_pi_vocabulary_and_project_instructions_do_not() {
        let mut source = source("rust", "engineer", "opus");
        source.body = "Use the Grep tool.".into();
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.additional_instructions = Some("Use the Grep tool.".into());
        let rendered = generate(&agent).unwrap();
        assert!(rendered.text.contains("Use the grep tool.\n"));
        assert!(
            rendered
                .text
                .contains("## Additional Instructions\n\nUse the Grep tool.\n")
        );
        assert!(
            rendered
                .warnings
                .iter()
                .any(|w| w.message == "tool references reworded for Pi: Grep")
        );
    }

    #[test]
    fn planner_keeps_questions_and_overrides_win_over_source() {
        // Named for nothing in particular: `role:` is what keeps the
        // question, so a planner under any name keeps it.
        let source = source("strategist", "planner", "opus");
        let scope = Scope::Project {
            root: "/tmp/proj".into(),
        };
        let mut agent = effective(&source, &scope);
        agent.skills = vec![crate::render::agent::linked_skill(
            "dev",
            HarnessId::Pi,
            &scope,
        )];
        agent.overrides = FrontmatterOverrides {
            model: Some("inherit".into()),
            allowed_subagents: Some(vec!["scout".into(), " Scout ".into(), "researcher".into()]),
            color: Some("magenta".into()),
            pane: Some(false),
            ..FrontmatterOverrides::default()
        };
        let text = generate(&agent).unwrap().text;
        assert!(!deny_line(&text).contains("question"));
        assert!(text.contains("allowed-subagents: scout, researcher\n"));
        assert!(text.contains("color: magenta\n"));
        assert!(!text.contains("pane: true"));
        assert!(!text.lines().any(|line| line.starts_with("model:")));
        assert!(text.contains("- dev: .agents/skills/dev/SKILL.md"));
    }
}
