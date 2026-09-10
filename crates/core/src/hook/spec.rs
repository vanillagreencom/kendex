//! One hook model, two authors. A catalog item and a manifest
//! `[[custom-hooks]]` entry describe the same thing in different words;
//! everything downstream — registration, scoring, locking, rendering —
//! speaks this type and never asks which author produced it.

use crate::manifest::{CustomHook, HookAgents};
use crate::model::HarnessId;

use super::HookSource;

#[derive(Debug, Clone, PartialEq)]
pub struct HookSpec {
    /// Stable identity: the registry key, the lock key, the script name.
    pub name: String,
    /// Always the shared vocabulary (`EVENTS`), until a harness restates it.
    pub event: String,
    /// Always in Claude's tool names, until a harness restates it.
    pub matcher: Option<String>,
    pub description: String,
    /// Advisory prose, catalog hooks only.
    pub safety: Option<String>,
    /// Seconds; harnesses that count milliseconds convert on render.
    pub timeout: Option<u32>,
    /// Harness allowlist; `None` = every declared harness.
    pub harnesses: Option<Vec<String>>,
    pub agents: HookAgents,
    pub body: HookBody,
}

#[derive(Debug, Clone, PartialEq)]
pub enum HookBody {
    /// kendex owns the file and writes it (catalog hooks).
    Script(String),
    /// The person's own command, registered verbatim (custom hooks).
    Command(String),
}

impl From<HookSource> for HookSpec {
    fn from(source: HookSource) -> HookSpec {
        HookSpec {
            name: source.name,
            event: source.event,
            matcher: source.matcher,
            description: source.description,
            safety: source.safety,
            timeout: source.timeout,
            harnesses: source.harnesses,
            agents: HookAgents::One("all".to_owned()),
            body: HookBody::Script(source.script),
        }
    }
}

impl HookSpec {
    /// The manifest author. The name is resolved by the caller
    /// (`custom_hook_names`), because de-duplication needs the whole list.
    pub fn custom(hook: &CustomHook, name: String) -> HookSpec {
        HookSpec {
            name,
            event: hook.event.clone(),
            matcher: hook.matcher.clone(),
            description: hook.description.clone().unwrap_or_default(),
            safety: None,
            timeout: hook.timeout,
            harnesses: hook.harnesses.clone(),
            agents: hook.agents.clone(),
            body: HookBody::Command(hook.command.clone()),
        }
    }

    pub fn applies_to(&self, harness: HarnessId) -> bool {
        match &self.harnesses {
            None => true,
            Some(list) => list.iter().any(|h| HarnessId::parse(h) == Some(harness)),
        }
    }

    /// Whether this hook asks to run for every agent, or only for some.
    pub fn every_agent(&self) -> bool {
        matches!(&self.agents, HookAgents::One(selector)
            if crate::render::agent::selects(selector) == crate::render::agent::Selects::Everyone)
    }

    /// Advisory prose for harnesses without native hook support (codex
    /// unmapped events, cursor rules).
    pub fn safety_prose(&self) -> String {
        // One paragraph per line with a blank line between paragraphs, the
        // shape the markdown format lane holds every rendered file to.
        let mut prose = format!("**Safety: {}**\n\n", self.description);
        if let Some(safety) = &self.safety {
            prose.push_str(safety);
            prose.push_str("\n\n");
        }
        let action = match self.event.as_str() {
            "PreToolUse" => "Before executing",
            "PostToolUse" => "After executing",
            "PermissionRequest" => "When requesting permission for",
            "PostCompact" => "After context compaction",
            "TaskCompleted" => "Before marking a task complete",
            _ => "When handling",
        };
        let target = self.matcher.as_deref().unwrap_or("any tool");
        prose.push_str(&format!(
            "{action} {target} operations, the agent must verify this constraint is met.\n"
        ));
        prose
    }
}

/// One hook as a harness registers it: the harness's own event name, and the
/// matcher in the harness's own tool names.
#[derive(Debug, Clone, PartialEq)]
pub struct Registration {
    pub hook: HookSpec,
    /// The matcher carries regex syntax around a tool name, so it is
    /// registered exactly as authored and may match nothing here.
    pub matcher_as_authored: bool,
}

impl Registration {
    pub fn new(spec: &HookSpec, harness: HarnessId, event: &str) -> Registration {
        let said = spec
            .matcher
            .as_deref()
            .map(|matcher| crate::render::vocab::hook_matcher(matcher, harness));
        Registration {
            hook: HookSpec {
                event: event.to_owned(),
                matcher: said.as_ref().map(|(pattern, _)| pattern.clone()),
                ..spec.clone()
            },
            matcher_as_authored: said.is_some_and(|(_, said)| !said),
        }
    }
}
