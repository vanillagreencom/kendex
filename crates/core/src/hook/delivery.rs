//! How one hook reaches one harness at one scope. A hook's delivery is
//! decided here by capability, never by which author wrote it, and every
//! surface — the engine, the agent renderer, the editor preview — reads the
//! same decision (docs/architecture/harnesses.md § Boundaries).

use crate::env::Env;
use crate::harness::Enforcement;
use crate::model::{HarnessId, ItemKind, Scope};

use super::spec::{HookBody, HookSpec};

#[derive(Debug, Clone, PartialEq)]
pub enum Delivery {
    /// Script or command in the harness's own hook registry — enforced.
    Registered,
    /// Claude's per-agent `hooks:` block — enforced, for scoped hooks.
    InAgentFile,
    /// Prose in the agent file, matcher restated in the harness's words. A
    /// model may follow it; nothing enforces it.
    Advisory,
    /// This harness × scope has no surface for this hook at all. Carries
    /// the reason; installs nothing, silently nowhere.
    NotInstallable(String),
}

/// When a harness runs a config-level hook, can the hook tell which agent
/// triggered it? The one capability that decides whether a scoped hook can
/// be enforced off Claude.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum AgentScoping {
    /// Hooks live inside the agent's own file (Claude Code).
    PerAgentFile,
    /// Every hook invocation names the agent, so one registration can gate
    /// itself; `field` is the JSON pointer into the payload. No harness has
    /// earned this yet — a harness moves here only when its own payload
    /// reference says the agent is named.
    Payload { field: &'static str },
    /// Nothing identifies the agent: only `agents = "all"` can be enforced.
    None,
}

pub fn agent_scoping(harness: HarnessId) -> AgentScoping {
    match harness {
        HarnessId::Claude => AgentScoping::PerAgentFile,
        _ => AgentScoping::None,
    }
}

/// Whether this harness fires the spec's event at all, in the shared
/// vocabulary. Claude fires everything in `EVENTS`; the rest answer through
/// their own maps.
fn event_fires(harness: HarnessId, event: &str) -> bool {
    match harness {
        HarnessId::Claude => super::known_event(event),
        HarnessId::Codex => super::codex_event(event).is_some(),
        HarnessId::Pi => crate::harness::pi_listener(event).is_some(),
        HarnessId::Gemini => crate::harness::gemini::event(event).is_some(),
        HarnessId::Copilot => crate::harness::copilot::event(event).is_some(),
        // Advisory harnesses never fire anything; enforcement answers first.
        HarnessId::Opencode | HarnessId::Cursor | HarnessId::Antigravity => true,
    }
}

pub fn delivery(env: &Env, scope: &Scope, harness: HarnessId, spec: &HookSpec) -> Delivery {
    let support = crate::harness::capabilities(harness, ItemKind::Hook).install;
    let here = match scope {
        Scope::Global => support.global,
        Scope::Project { .. } => support.project,
    };
    if !here {
        return Delivery::NotInstallable(format!(
            "{} holds no hooks at this scope",
            harness.display_name()
        ));
    }
    match crate::harness::hook_enforcement(env, scope, harness) {
        Enforcement::NotApplicable => {
            return Delivery::NotInstallable(format!("{} takes no hooks", harness.display_name()));
        }
        Enforcement::Advisory => return Delivery::Advisory,
        Enforcement::Enforced => {}
    }
    if !event_fires(harness, &spec.event) {
        // A catalog hook has no agent file to fall back into; a custom hook
        // keeps its advisory prose there.
        return match &spec.body {
            HookBody::Command(_) => Delivery::Advisory,
            HookBody::Script(_) => Delivery::NotInstallable(format!(
                "{} never fires {}",
                harness.display_name(),
                spec.event
            )),
        };
    }
    if !spec.every_agent() {
        return match agent_scoping(harness) {
            AgentScoping::PerAgentFile => Delivery::InAgentFile,
            AgentScoping::Payload { .. } => Delivery::Registered,
            AgentScoping::None => Delivery::Advisory,
        };
    }
    match crate::engine::hook_target(env, scope, harness, &spec.name) {
        Some(_) => Delivery::Registered,
        None => Delivery::NotInstallable(format!(
            "{} has nowhere to register a hook at this scope",
            harness.display_name()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::HookAgents;

    fn spec(event: &str, agents: &str, body: HookBody) -> HookSpec {
        HookSpec {
            name: "guard".to_owned(),
            event: event.to_owned(),
            matcher: None,
            description: String::new(),
            safety: None,
            timeout: None,
            harnesses: None,
            agents: HookAgents::One(agents.to_owned()),
            body,
        }
    }

    fn command(event: &str, agents: &str) -> HookSpec {
        spec(event, agents, HookBody::Command("./guard.sh".to_owned()))
    }

    fn script(event: &str) -> HookSpec {
        spec(event, "all", HookBody::Script("exit 0".to_owned()))
    }

    /// The single place this design can rot: what each (harness × scope ×
    /// selector × event) combination gets. Pi carries no carrier in this
    /// world, so its enforced rows read Advisory — the live answer.
    #[test]
    #[allow(clippy::unwrap_used)]
    fn the_delivery_table() {
        use Delivery::*;
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().canonicalize().unwrap();
        let env = crate::env::Env::fake(&home, crate::env::FakeOs::Linux);
        let project = Scope::Project { root: home.clone() };
        let global = Scope::Global;
        let h = HarnessId::parse;

        let table: &[(&str, &Scope, HookSpec, Delivery)] = &[
            // agents = "all", a widely fired event: registered wherever
            // hooks are enforced.
            ("claude", &project, command("PreToolUse", "all"), Registered),
            ("codex", &project, command("PreToolUse", "all"), Registered),
            ("gemini", &project, command("PreToolUse", "all"), Registered),
            (
                "copilot",
                &project,
                command("PreToolUse", "all"),
                Registered,
            ),
            ("claude", &global, command("PreToolUse", "all"), Registered),
            // Advisory harnesses stay advisory whatever the spec asks.
            ("opencode", &project, command("PreToolUse", "all"), Advisory),
            ("cursor", &project, command("PreToolUse", "all"), Advisory),
            // Pi with no carrier anywhere: enforced on paper, prose in fact.
            ("pi", &project, command("PreToolUse", "all"), Advisory),
            // Cursor has no global hook surface at all.
            (
                "cursor",
                &global,
                command("PreToolUse", "all"),
                NotInstallable("Cursor holds no hooks at this scope".to_owned()),
            ),
            // An event this harness never fires: a custom hook keeps its
            // prose, a catalog script installs nothing.
            ("codex", &project, command("SubagentStop", "all"), Advisory),
            (
                "codex",
                &project,
                script("SubagentStop"),
                NotInstallable("Codex never fires SubagentStop".to_owned()),
            ),
            // Scoped agents: enforced in Claude's own agent file, honest
            // prose everywhere nothing identifies the agent at runtime.
            (
                "claude",
                &project,
                command("PreToolUse", "reviewer"),
                InAgentFile,
            ),
            (
                "codex",
                &project,
                command("PreToolUse", "reviewer"),
                Advisory,
            ),
            (
                "gemini",
                &project,
                command("PreToolUse", "reviewer"),
                Advisory,
            ),
        ];
        for (harness, scope, spec, want) in table {
            let got = delivery(&env, scope, h(harness).unwrap(), spec);
            assert_eq!(&got, want, "{harness} × {scope:?} × {}", spec.event);
        }
    }

    #[test]
    fn only_claude_scopes_hooks_per_agent_today() {
        for harness in crate::model::HarnessId::ALL {
            let scoping = agent_scoping(harness);
            match harness {
                HarnessId::Claude => assert_eq!(scoping, AgentScoping::PerAgentFile),
                _ => assert_eq!(scoping, AgentScoping::None, "{harness:?}"),
            }
        }
    }
}
