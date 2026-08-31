use super::{
    EffectiveAgent, GENERATED_BANNER, RenderedAgent, Role, default_pane, hooks_prose, skills_prose,
};
use crate::model::{HarnessId, Scope};
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
    let (model, model_warning) = model(agent);
    warnings.extend(model_warning.map(|w| {
        crate::render::RenderWarning::with_fix(w, "use a provider/model id or a tier alias")
    }));
    if let Some(model) = model {
        out.push_str(&format!("model: {}\n", yaml_scalar(&model)));
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

/// Heavy tiers omit `model` so the child inherits the parent session;
/// everything else resolves through the shared alias table and carries the
/// `:effort` suffix.
fn model(agent: &EffectiveAgent) -> (Option<String>, Option<String>) {
    let effort = agent
        .overrides
        .model_reasoning_effort
        .as_deref()
        .or(agent.overrides.effort.as_deref())
        .or(agent.source.effort.as_deref())
        .filter(|effort| !is_none_value(effort));
    let model = agent
        .overrides
        .model
        .as_deref()
        .unwrap_or(&agent.source.model);
    let resolved = crate::harness::models::resolve_model(crate::model::HarnessId::Pi, model);
    let suffix = effort.map(|e| format!(":{e}")).unwrap_or_default();
    (
        resolved.id.map(|id| format!("{id}{suffix}")),
        resolved.warning,
    )
}

/// Engineers delegate reconnaissance to scout by default; every other role
/// stays a leaf.
fn allowed_subagents(agent: &EffectiveAgent) -> Vec<String> {
    let list = match &agent.overrides.allowed_subagents {
        Some(list) => list.clone(),
        None if agent.source.role == Some(Role::Engineer) => vec!["scout".to_owned()],
        None => Vec::new(),
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
    if agent.source.role != Some(Role::Planner) {
        tools.push("question".to_owned());
    }
    if agent.source.role == Some(Role::Reviewer) {
        tools.push("tasks_write".to_owned());
    }
    tools.extend(user.iter().cloned());

    let mut out: Vec<String> = Vec::new();
    for tool in tools {
        if tool.trim().is_empty() || out.iter().any(|kept| normalize(kept) == normalize(&tool)) {
            continue;
        }
        out.push(tool);
    }
    // A live allowlist needs the delegation tool, so the default deny goes —
    // unless the user asked for it, in which case their policy wins and the
    // allowlist stays inert.
    let user_denies_delegate = user
        .iter()
        .any(|tool| normalize(tool) == "delegate_subagent");
    if !allowed.is_empty() && !user_denies_delegate {
        out.retain(|tool| normalize(tool) != "delegate_subagent");
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
    let skill_root = match agent.scope {
        Scope::Global => "~/.pi/agent/skills",
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
    use crate::manifest::FrontmatterOverrides;
    use crate::model::HarnessId;

    fn source(name: &str, role: &str, model: &str) -> SourceAgent {
        parse_source_agent(&format!(
            "---\nname: {name}\ndescription: Pi agent\nmodel: {model}\nrole: {role}\ncolor: green\n---\nBody text.\n"
        ))
        .unwrap()
    }

    fn effective<'a>(source: &'a SourceAgent, scope: &'a Scope) -> EffectiveAgent<'a> {
        EffectiveAgent {
            source,
            harness: HarnessId::Pi,
            scope,
            skills: vec![],
            overrides: FrontmatterOverrides::default(),
            permissions: PermissionIntent::Unspecified,
            launch_instructions: None,
            additional_instructions: None,
            custom_hooks: vec![],
        }
    }

    fn deny_line(text: &str) -> String {
        text.lines()
            .find(|line| line.starts_with("deny-tools:"))
            .unwrap_or_default()
            .to_owned()
    }

    #[test]
    fn engineer_keeps_scout_delegation_and_inherits_the_opus_model() {
        let source = source("rust", "engineer", "opus");
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope)).unwrap().text;
        assert!(text.contains("allowed-subagents: scout\n"));
        assert!(text.contains("pane: true\n"));
        assert!(text.contains("color: green\n"));
        assert!(!text.lines().any(|line| line.starts_with("model:")));
        assert_eq!(
            deny_line(&text),
            "deny-tools: subagent, get_subagent_result, steer_subagent, stop_subagent, question"
        );
    }

    #[test]
    fn reviewer_loses_delegation_and_task_writes_and_pins_the_codex_model() {
        let mut source = source("reviewer-arch", "reviewer", "sonnet");
        source.effort = Some("high".into());
        let scope = Scope::Global;
        let text = generate(&effective(&source, &scope)).unwrap().text;
        assert!(text.contains("model: openai-codex/gpt-5.6-sol:high\n"));
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

    #[test]
    fn a_tool_allowlist_refuses_rather_than_widens() {
        let source = source("reviewer-arch", "reviewer", "sonnet");
        let scope = Scope::Global;
        let mut agent = effective(&source, &scope);
        agent.permissions = PermissionIntent::allow_only(vec!["read".into()]);
        let refusal = generate(&agent).unwrap_err();
        assert!(refusal.contains("widen"));
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
        agent.skills = vec!["dev".into()];
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
