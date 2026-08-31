use serde::{Deserialize, Serialize};

use crate::render::permission::PermissionIntent;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Reviewer,
    Engineer,
    Analyst,
    Manager,
    Planner,
}

impl Role {
    pub fn parse(value: &str) -> Option<Role> {
        match value {
            "reviewer" => Some(Role::Reviewer),
            "engineer" => Some(Role::Engineer),
            "analyst" => Some(Role::Analyst),
            "manager" => Some(Role::Manager),
            "planner" => Some(Role::Planner),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Role::Reviewer => "reviewer",
            Role::Engineer => "engineer",
            Role::Analyst => "analyst",
            Role::Manager => "manager",
            Role::Planner => "planner",
        }
    }
}

/// A source agent file: YAML frontmatter + markdown body. `role` is `None`
/// when the author declared none — a missing role must never default to a
/// privileged one. `permissions` carries the `tools:` intent losslessly.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SourceAgent {
    pub name: String,
    pub description: String,
    pub model: String,
    pub role: Option<Role>,
    pub color: Option<String>,
    pub effort: Option<String>,
    pub permissions: PermissionIntent,
    /// What jobs this agent helps with, carried verbatim into renderings
    /// whose loaders tolerate extra keys. The words are the author's own —
    /// the scan checks them against the closed vocabulary (invariant 15),
    /// so dropping or rewriting them here would hide a warning the author
    /// should see.
    pub tags: Vec<String>,
    pub body: String,
    /// Parse-time findings worth surfacing (unknown keys, odd shapes) that
    /// do not make the agent unusable.
    pub warnings: Vec<String>,
}

pub fn parse_source_agent(text: &str) -> Result<SourceAgent, String> {
    use crate::frontmatter::Value;
    let (yaml, body) = crate::frontmatter::split(text)?;
    let parsed = crate::frontmatter::parse_tolerant(yaml)?;
    let mut agent = SourceAgent {
        model: "sonnet".to_owned(),
        warnings: parsed.warnings,
        ..SourceAgent::default()
    };
    let scalar = |value: &Value| value.as_str().map(|text| text.trim().to_owned());
    for (key, value) in parsed.map.entries() {
        match key {
            "name" => agent.name = scalar(value).unwrap_or_default(),
            "description" => agent.description = scalar(value).unwrap_or_default(),
            "model" => {
                if let Some(model) = scalar(value).filter(|m| !m.is_empty()) {
                    agent.model = model;
                }
            }
            "role" => match scalar(value) {
                Some(role) => {
                    agent.role = Some(Role::parse(&role).ok_or_else(|| {
                        format!("unknown role '{role}' (reviewer|engineer|analyst|manager|planner)")
                    })?);
                }
                None => agent.warnings.push("empty `role:` ignored".to_owned()),
            },
            "color" => agent.color = scalar(value),
            "tags" => match parsed.map.string_list(key) {
                Some(list) => agent.tags = list,
                None => agent
                    .warnings
                    .push("`tags:` is not a list — ignored".to_owned()),
            },
            "effort" => agent.effort = scalar(value),
            "tools" => match parsed.map.string_list(key) {
                Some(list) => {
                    if let Some(Value::List(items)) = parsed.map.get(key)
                        && items.iter().any(|item| item.as_str().is_none())
                    {
                        agent
                            .warnings
                            .push("`tools:` holds non-text entries — they were ignored".to_owned());
                    }
                    agent.permissions = PermissionIntent::allow_only(list);
                }
                None => agent
                    .warnings
                    .push("`tools:` is not a list — ignored".to_owned()),
            },
            other => agent
                .warnings
                .push(format!("unknown frontmatter key `{other}` — ignored")),
        }
    }
    agent.body = body.trim_start_matches('\n').to_owned();
    if agent.name.is_empty() {
        return Err("agent frontmatter has no name".to_owned());
    }
    Ok(agent)
}

/// v1's pane default: Engineer and Planner agents run in a visible pane.
pub fn default_pane(agent: &SourceAgent) -> bool {
    matches!(agent.role, Some(Role::Engineer | Role::Planner))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_v1_shaped_agent_frontmatter() {
        let agent = parse_source_agent(
            "---\nname: rust\ndescription: Rust engineer\nmodel: opus\nrole: engineer\neffort: xhigh\ncolor: orange\n---\n\n# Body\n",
        )
        .unwrap();
        assert_eq!(agent.name, "rust");
        assert_eq!(agent.role, Some(Role::Engineer));
        assert_eq!(agent.effort.as_deref(), Some("xhigh"));
        assert!(agent.body.starts_with("# Body"));
        assert!(default_pane(&agent));
        assert_eq!(agent.permissions, PermissionIntent::Unspecified);
        assert!(agent.warnings.is_empty());
    }

    #[test]
    fn foreign_agents_keep_their_restrictions_and_lose_no_intent() {
        let agent = parse_source_agent(
            "---\nname: reviewer\ndescription: >\n  Reads code,\n  never writes.\ntools: Read, Grep\ncategory: review\n---\nBody.\n",
        )
        .unwrap();
        assert_eq!(agent.role, None);
        assert_eq!(
            agent.permissions,
            PermissionIntent::allow_only(vec!["Read".into(), "Grep".into()])
        );
        assert!(agent.description.starts_with("Reads code"));
        assert!(!default_pane(&agent));
        assert!(agent.warnings.iter().any(|w| w.contains("category")));

        let empty = parse_source_agent("---\nname: a\ntools:\n---\nB.\n").unwrap();
        assert_eq!(empty.permissions, PermissionIntent::allow_only(vec![]));
        let none = parse_source_agent("---\nname: a\n---\nB.\n").unwrap();
        assert_eq!(none.permissions, PermissionIntent::Unspecified);
    }

    #[test]
    fn a_description_with_a_colon_still_parses() {
        let agent =
            parse_source_agent("---\nname: r\ndescription: Use when: reviewing\n---\nBody.\n")
                .unwrap();
        assert!(agent.description.starts_with("Use when"));
    }
}
