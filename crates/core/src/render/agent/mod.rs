use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents, Manifest};
use crate::model::{HarnessId, ItemKind, Scope};

use super::permission::PermissionIntent;

pub mod antigravity;
pub mod claude;
pub mod codex;
pub mod copilot;
pub mod cursor;
pub mod gemini;
pub mod opencode;
pub mod pi;
mod source;

pub use source::{Role, SourceAgent, default_pane, parse_source_agent};

/// Everything a per-harness generator needs, already merged. `permissions`
/// is the effective intent — source `tools:` narrowed by manifest overrides;
/// renderers read it, never `overrides.deny_tools` directly.
#[derive(Clone)]
pub struct EffectiveAgent<'a> {
    pub source: &'a SourceAgent,
    pub harness: HarnessId,
    pub scope: &'a Scope,
    pub skills: Vec<String>,
    pub overrides: FrontmatterOverrides,
    pub permissions: PermissionIntent,
    pub launch_instructions: Option<String>,
    pub additional_instructions: Option<String>,
    pub custom_hooks: Vec<&'a CustomHook>,
}

impl EffectiveAgent<'_> {
    /// The intent a rendering runs on: the source's own, narrowed by the
    /// overrides that reached it. Every caller composes the two here — a
    /// second composition is a second answer to what the agent may use.
    pub fn intent(source: &SourceAgent, overrides: &FrontmatterOverrides) -> PermissionIntent {
        PermissionIntent::effective(
            &source.permissions,
            overrides.allow_tools.as_deref(),
            overrides.deny_tools.as_deref(),
        )
    }
}

pub const SHARED_START: &str = "<!-- kendex:shared-instructions:start -->";
pub const SHARED_END: &str = "<!-- kendex:shared-instructions:end -->";

/// The keys an instructions table reads as everyone's rather than one
/// agent's, in the order the shared entry is looked for.
const SHARED_INSTRUCTIONS: [&str; 2] = [EVERY_AGENT, "*"];

/// Whether an instructions-table key names the entry every agent reads
/// rather than one agent's own. An agent may legally be called `all`, so
/// the key is a population before it is that agent's: moving it because
/// the agent moved would rewrite what every other agent renders.
pub fn shared_instructions_key(key: &str) -> bool {
    SHARED_INSTRUCTIONS.contains(&key)
}

/// Shared (`all`/`*`) text renders first inside strippable markers, then the
/// agent-specific text.
pub fn merged_instructions(
    table: &std::collections::BTreeMap<String, String>,
    agent_name: &str,
) -> Option<String> {
    let shared = SHARED_INSTRUCTIONS.iter().find_map(|key| table.get(*key));
    let specific = table.get(agent_name);
    match (shared, specific) {
        (None, None) => None,
        (None, Some(text)) => Some(text.clone()),
        (Some(shared), specific) => {
            let mut out = format!("{SHARED_START}\n{shared}\n{SHARED_END}");
            if let Some(text) = specific {
                out.push_str("\n\n");
                out.push_str(text);
            }
            Some(out)
        }
    }
}

/// Project overrides win per field over source-side defaults, except
/// deny-tools, which merge (v1 semantics).
pub fn merge_overrides(
    source_defaults: Option<&FrontmatterOverrides>,
    project: Option<&FrontmatterOverrides>,
) -> FrontmatterOverrides {
    let mut merged = source_defaults.cloned().unwrap_or_default();
    let Some(project) = project else {
        return merged;
    };
    macro_rules! take {
        ($field:ident) => {
            if project.$field.is_some() {
                merged.$field = project.$field.clone();
            }
        };
    }
    take!(color);
    take!(model);
    take!(allow_tools);
    take!(allowed_subagents);
    take!(pane);
    take!(background);
    take!(effort);
    take!(isolation);
    take!(memory);
    take!(mode);
    take!(sandbox_mode);
    take!(model_reasoning_effort);
    take!(nickname_candidates);
    match (&mut merged.deny_tools, &project.deny_tools) {
        (Some(base), Some(extra)) => {
            for tool in extra {
                if !base.contains(tool) {
                    base.push(tool.clone());
                }
            }
        }
        (None, Some(extra)) => merged.deny_tools = Some(extra.clone()),
        _ => {}
    }
    merged
}

/// The selector naming every agent there is.
pub const EVERY_AGENT: &str = "all";

/// What one custom-hook agent selector names. A hook reaches an agent by
/// any of these, but only the last belongs to one agent: the other two
/// describe a population, so they must not travel when one agent's name
/// travels.
#[derive(Debug, PartialEq, Eq)]
pub enum Selects {
    Everyone,
    Role(Role),
    Named,
}

/// The one place a selector's kind is decided. A role name is a role
/// before it is anything else, so an agent named for a role never owns a
/// selector spelling that role — reading it the other way would let one
/// agent's rename take a restriction off every agent sharing the role.
pub fn selects(selector: &str) -> Selects {
    if selector == EVERY_AGENT {
        return Selects::Everyone;
    }
    match Role::parse(selector) {
        Some(role) => Selects::Role(role),
        None => Selects::Named,
    }
}

/// Whether this hook's selector reaches this agent. `all` names every
/// agent and is only honoured as the whole selector, never as one entry
/// in a list.
///
/// Reaching is decided generously and ownership strictly, and the two
/// answers differ on purpose. A selector spelling a role reaches every
/// agent holding that role AND an agent that goes by that name, because a
/// gate that might apply should apply. Only [`selects`] decides which
/// selector one agent owns, and there a role never counts: a gate over a
/// population must not travel when one member is renamed.
fn reaches(agents: &HookAgents, agent: &SourceAgent) -> bool {
    let picks = |selector: &String| match selects(selector) {
        Selects::Role(role) => agent.role == Some(role) || selector == &agent.name,
        Selects::Everyone | Selects::Named => selector == &agent.name,
    };
    match agents {
        HookAgents::One(selector) => selects(selector) == Selects::Everyone || picks(selector),
        HookAgents::Many(list) => list.iter().any(picks),
    }
}

/// The custom hooks one agent file carries on one harness: the ones whose
/// selector matches this agent, minus every hook `delivery()` sends through
/// a real registration instead — writing those here too would keep a second,
/// weaker copy of the same rule.
pub fn hooks_for_agent<'a>(
    env: &crate::env::Env,
    scope: &Scope,
    harness: HarnessId,
    manifest: &'a Manifest,
    agent: &SourceAgent,
) -> Vec<&'a CustomHook> {
    use crate::hook::{Delivery, HookSpec, delivery};
    let names = crate::hook::custom_hook_names(manifest);
    manifest
        .custom_hooks
        .iter()
        .zip(names)
        .filter(|(hook, _)| hook.enabled && reaches(&hook.agents, agent))
        .filter(|(hook, name)| {
            let spec = HookSpec::custom(hook, name.clone());
            spec.applies_to(harness)
                && matches!(
                    delivery(env, scope, harness, &spec),
                    Delivery::InAgentFile | Delivery::Advisory
                )
        })
        .map(|(hook, _)| hook)
        .collect()
}

/// The generated-file banner every harness variant includes.
pub const GENERATED_BANNER: &str = "> Generated by kendex — do not edit; regenerated on every refresh. Intent lives in kendex.toml.";

/// One harness's rendering plus everything the user should hear about it.
#[derive(Debug)]
pub struct RenderedAgent {
    pub text: String,
    pub warnings: Vec<crate::render::RenderWarning>,
}

/// `Err` is a refusal: the harness cannot express the agent's permission
/// intent and rendering anyway would widen access. The caller surfaces the
/// reason and produces no artifact for that harness.
pub fn generate(agent: &EffectiveAgent) -> Result<RenderedAgent, String> {
    match agent.harness {
        HarnessId::Claude => Ok(claude::generate(agent)),
        HarnessId::Codex => Ok(codex::generate(agent)),
        HarnessId::Opencode => Ok(opencode::generate(agent)),
        HarnessId::Cursor => Ok(cursor::generate(agent)),
        HarnessId::Pi => pi::generate(agent),
        HarnessId::Gemini => Ok(gemini::generate(agent)),
        HarnessId::Copilot => Ok(copilot::generate(agent)),
        HarnessId::Antigravity => Ok(antigravity::generate(agent)),
    }
}

/// The filename a generated agent gets in the harness's native dir, under
/// the spelling that harness lists the agent by — an agent from a
/// plugin-registry catalog carries its plugin into the name.
pub fn file_name(harness: HarnessId, agent_name: &str) -> String {
    let agent_name = &crate::harness::rendered_name(harness, agent_name);
    match harness {
        HarnessId::Codex => format!("{agent_name}.toml"),
        HarnessId::Cursor => format!("{agent_name}.mdc"),
        // Copilot loads `<name>.agent.md`; the double extension is part of
        // what its loader looks for, not decoration (matrix §2).
        HarnessId::Copilot => format!("{agent_name}.agent.md"),
        _ => format!("{agent_name}.md"),
    }
}

/// Skills prose section for harnesses without a native skills field.
/// Where an agent is told to read its required skills: the directory the
/// install writes for this harness at this scope.
///
/// One owner, because five renderers each spelling it is five chances to
/// name a place the install stopped writing. Every tool but Claude Code
/// and Antigravity reads the shared tree, so that is where their skills
/// are; those two read only their own directory and are linked into it.
/// A `method = "copy"` delivery writes each tool's own directory instead,
/// which this does not distinguish — the prose has never said so, at
/// either scope.
pub fn skill_root(harness: HarnessId, scope: &Scope) -> &'static str {
    match scope {
        Scope::Project { .. } => ".agents/skills",
        Scope::Global => match harness {
            HarnessId::Claude => "~/.claude/skills",
            HarnessId::Antigravity => "~/.gemini/config/skills",
            _ => "~/.agents/skills",
        },
    }
}

pub fn skills_prose(agent: &EffectiveAgent, skill_root_hint: &str) -> Option<String> {
    if agent.skills.is_empty() {
        return None;
    }
    let mut out = String::from("## Required Skills\n\nRead each before acting:\n\n");
    for skill in &agent.skills {
        out.push_str(&format!("- {skill}: {skill_root_hint}/{skill}/SKILL.md\n"));
    }
    Some(out)
}

/// Custom hooks rendered as prose, for every harness that does not run
/// hooks out of an agent's own file — which is all of them but Claude Code.
/// The matcher is said in this harness's own tool names: a hook written
/// against `Bash` means the same thing here, and printing Claude's word for
/// it in another harness's file asks the model to match on a name it has
/// never seen.
pub fn hooks_prose(agent: &EffectiveAgent) -> Option<String> {
    if agent.custom_hooks.is_empty() {
        return None;
    }
    let mut out = String::new();
    for hook in &agent.custom_hooks {
        let matcher = hook
            .matcher
            .as_deref()
            .map(|matcher| crate::render::vocab::hook_matcher(matcher, agent.harness).0)
            .unwrap_or_else(|| "every match".to_owned());
        out.push_str(&format!(
            "## Safety: {} on {}\n\n{}Run: `{}`\n\n",
            hook.event,
            matcher,
            hook.description
                .as_ref()
                .map(|d| format!("{d}\n\n"))
                .unwrap_or_default(),
            hook.command
        ));
    }
    Some(out.trim_end().to_owned())
}

pub fn kind() -> ItemKind {
    ItemKind::Agent
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn shared_instructions_render_first_inside_markers() {
        let mut table = BTreeMap::new();
        table.insert("all".to_owned(), "fleet rule".to_owned());
        table.insert("rust".to_owned(), "rust rule".to_owned());
        let merged = merged_instructions(&table, "rust").unwrap();
        assert!(merged.starts_with(SHARED_START));
        assert!(merged.contains("fleet rule"));
        assert!(merged.ends_with("rust rule"));
        let solo = merged_instructions(&table, "other").unwrap();
        assert!(solo.contains(SHARED_START) && !solo.contains("rust rule"));
    }

    /// One control per harness: a custom effort reaches the rendered file
    /// under that harness's own key, and a harness with no per-agent effort
    /// carries nothing rather than a key its loader will not read.
    #[test]
    fn a_custom_effort_round_trips_under_each_harness_key() {
        use crate::model::{HarnessId, Scope};
        let source = parse_source_agent(
            "---\nname: rust\ndescription: Rust engineer\nmodel: inherit\nrole: engineer\neffort: high\n---\nBody.\n",
        )
        .unwrap();
        let scope = Scope::Global;
        let overrides = FrontmatterOverrides {
            effort: Some("low".into()),
            ..FrontmatterOverrides::default()
        };
        let spelled = |harness: HarnessId| -> String {
            let agent = EffectiveAgent {
                source: &source,
                harness,
                scope: &scope,
                skills: vec![],
                permissions: EffectiveAgent::intent(&source, &overrides),
                overrides: overrides.clone(),
                launch_instructions: None,
                additional_instructions: None,
                custom_hooks: vec![],
            };
            generate(&agent).unwrap().text
        };
        let keyed = [
            (HarnessId::Claude, "effort: low\n"),
            (HarnessId::Codex, "model_reasoning_effort = \"low\"\n"),
            (HarnessId::Opencode, "reasoningEffort: low\n"),
            (HarnessId::Pi, "effort: low\n"),
        ];
        for (harness, line) in keyed {
            let text = spelled(harness);
            assert!(text.contains(line), "{}: {text}", harness.name());
            let source_line = line.replace("low", "high");
            assert!(!text.contains(&source_line), "{}: {text}", harness.name());
        }
        for harness in [HarnessId::Cursor, HarnessId::Gemini, HarnessId::Copilot] {
            let text = spelled(harness);
            assert!(
                !text.to_lowercase().contains("effort"),
                "{}: {text}",
                harness.name()
            );
        }
    }

    /// One control per harness: a provider-qualified model override reaches
    /// the file where the harness loads models by provider, and is refused
    /// at validation where the harness reaches one vendor.
    #[test]
    fn a_provider_qualified_model_lands_only_where_a_provider_is_named() {
        use crate::model::{HarnessId, Scope};
        use crate::render::validate::validate_agent;
        let source = parse_source_agent(
            "---\nname: rust\ndescription: Rust engineer\nmodel: inherit\nrole: engineer\n---\nBody.\n",
        )
        .unwrap();
        let scope = Scope::Global;
        let overrides = FrontmatterOverrides {
            model: Some("anthropic/claude-opus-5".into()),
            ..FrontmatterOverrides::default()
        };
        let rendered = |harness: HarnessId| -> String {
            let agent = EffectiveAgent {
                source: &source,
                harness,
                scope: &scope,
                skills: vec![],
                permissions: EffectiveAgent::intent(&source, &overrides),
                overrides: overrides.clone(),
                launch_instructions: None,
                additional_instructions: None,
                custom_hooks: vec![],
            };
            generate(&agent).unwrap().text
        };
        for harness in [HarnessId::Pi, HarnessId::Opencode] {
            let text = rendered(harness);
            assert!(
                text.contains("model: anthropic/claude-opus-5\n"),
                "{}: {text}",
                harness.name()
            );
            let findings = validate_agent(harness, "rust", &text);
            assert!(
                findings.iter().all(|f| !f.is_breakage()),
                "{}: {findings:?}",
                harness.name()
            );
        }
        for harness in [
            HarnessId::Claude,
            HarnessId::Codex,
            HarnessId::Gemini,
            HarnessId::Copilot,
        ] {
            let text = rendered(harness);
            assert!(
                text.contains("anthropic/claude-opus-5"),
                "{}: {text}",
                harness.name()
            );
            let findings = validate_agent(harness, "rust", &text);
            assert!(
                findings.iter().any(|f| f.is_breakage()),
                "{}: {text}",
                harness.name()
            );
        }
    }

    #[test]
    fn deny_tools_merge_while_other_fields_prefer_project() {
        let source = FrontmatterOverrides {
            model: Some("sonnet".into()),
            deny_tools: Some(vec!["WebSearch".into()]),
            ..FrontmatterOverrides::default()
        };
        let project = FrontmatterOverrides {
            model: Some("opus".into()),
            deny_tools: Some(vec!["WebFetch".into(), "WebSearch".into()]),
            ..FrontmatterOverrides::default()
        };
        let merged = merge_overrides(Some(&source), Some(&project));
        assert_eq!(merged.model.as_deref(), Some("opus"));
        assert_eq!(
            merged.deny_tools,
            Some(vec!["WebSearch".into(), "WebFetch".into()])
        );
    }

    /// The path an agent is told to read a skill from is the one the
    /// install writes. Globally that is the shared tree for every tool
    /// that reads it, and its own directory for the two that do not; a
    /// project's is the shared tree for all of them. A renderer naming a
    /// tool's own global directory would send the agent to a path the
    /// default delivery no longer creates.
    #[test]
    fn an_agent_reads_its_skills_from_the_place_the_install_writes() {
        let project = Scope::Project {
            root: std::path::PathBuf::from("/p"),
        };
        for harness in HarnessId::ALL {
            assert_eq!(
                skill_root(harness, &project),
                ".agents/skills",
                "{harness:?} in a project"
            );
        }
        for harness in [
            HarnessId::Codex,
            HarnessId::Pi,
            HarnessId::Opencode,
            HarnessId::Gemini,
            HarnessId::Copilot,
        ] {
            assert_eq!(
                skill_root(harness, &Scope::Global),
                "~/.agents/skills",
                "{harness:?} reads the shared global tree"
            );
        }
        assert_eq!(
            skill_root(HarnessId::Claude, &Scope::Global),
            "~/.claude/skills"
        );
        assert_eq!(
            skill_root(HarnessId::Antigravity, &Scope::Global),
            "~/.gemini/config/skills"
        );
    }
}
