use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::Path;

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
pub struct MappingConfig {
    #[serde(rename = "agent-skills")]
    pub agent_skills: HashMap<String, Vec<String>>,
    #[serde(rename = "role-skills")]
    pub role_skills: HashMap<String, Vec<String>>,
    #[serde(rename = "hook-events")]
    pub hook_events: HashMap<String, HookTarget>,
    /// Source-level frontmatter overrides parsed from `[agent-frontmatter]`
    /// and `[agent-frontmatter.<harness>]` tables. Acts as defaults beneath
    /// any project `vstack.toml` overrides.
    #[serde(skip)]
    pub agent_frontmatter: HashMap<String, crate::agent::AgentFrontmatterOverrides>,
    #[serde(skip)]
    pub agent_frontmatter_by_harness:
        HashMap<String, HashMap<String, crate::agent::AgentFrontmatterOverrides>>,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(untagged)]
pub enum HookTarget {
    All(String),        // "all"
    Roles(Vec<String>), // ["engineer", "reviewer"]
}

impl MappingConfig {
    pub fn load(source_dir: &Path) -> Self {
        let path = source_dir.join("vstack.toml");
        if !path.exists() {
            return Self::default();
        }
        let Ok(content) = std::fs::read_to_string(&path) else {
            return Self::default();
        };
        let mut parsed: Self = toml::from_str(&content).unwrap_or_default();
        let (legacy, by_harness) = crate::project_config::parse_agent_frontmatter_tables(&content);
        parsed.agent_frontmatter = legacy;
        parsed.agent_frontmatter_by_harness = by_harness;
        parsed
    }

    pub fn skills_for_agent(
        &self,
        agent_name: &str,
        agent_role: &crate::agent::AgentRole,
        available: &[String],
    ) -> Vec<String> {
        let available_set: HashSet<&str> = available.iter().map(|skill| skill.as_str()).collect();
        let name = agent_name.to_lowercase();

        // Check if this agent has an explicit [agent-skills] entry (full name or
        // stripped reviewer- prefix).  When an explicit entry exists, it is
        // authoritative — prefix matching is skipped so that removing a skill
        // from the toml actually removes it from the agent's frontmatter.
        let has_explicit = self.agent_skills.contains_key(&name)
            || name
                .strip_prefix("reviewer-")
                .is_some_and(|suffix| self.agent_skills.contains_key(suffix));

        let mut matched: Vec<String> = if has_explicit {
            Vec::new()
        } else {
            crate::agent::prefixed_skill_matches(agent_name, available)
        };

        let mut matched_set: HashSet<String> = matched.iter().cloned().collect();
        let mut push_unique = |skill: &str| {
            if available_set.contains(skill) && matched_set.insert(skill.to_string()) {
                matched.push(skill.to_string());
            }
        };

        // 2. Explicit agent-skills from config
        if let Some(extras) = self.agent_skills.get(&name) {
            for s in extras {
                push_unique(s);
            }
        }
        // Also check without reviewer- prefix for reviewer agents
        if let Some(suffix) = name.strip_prefix("reviewer-")
            && let Some(extras) = self.agent_skills.get(suffix)
        {
            for s in extras {
                push_unique(s);
            }
        }

        // 3. Role-skills from config
        let role_key = agent_role.as_str();
        if let Some(role_skills) = self.role_skills.get(role_key) {
            for s in role_skills {
                push_unique(s);
            }
        }

        matched.sort();
        matched
    }

    pub fn hooks_for_agent<'a>(
        &self,
        agent_role: &crate::agent::AgentRole,
        hooks: &'a [crate::hook::Hook],
    ) -> Vec<&'a crate::hook::Hook> {
        let role_str = agent_role.as_str();

        if self.hook_events.is_empty() {
            // Fallback to old heuristic
            return crate::agent::match_hooks(agent_role, hooks);
        }

        hooks
            .iter()
            .filter(|h| {
                let matcher = h.matcher.as_deref().unwrap_or("");
                let key = format!("{}:{}", h.event, matcher);
                // Try exact key first, then event-only key
                let target = self
                    .hook_events
                    .get(&key)
                    .or_else(|| self.hook_events.get(&format!("{}:", h.event)));

                match target {
                    Some(HookTarget::All(s)) if s == "all" => true,
                    Some(HookTarget::Roles(roles)) => roles.iter().any(|r| r == role_str),
                    _ => false,
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::AgentRole;

    #[test]
    fn default_config_falls_back_to_prefix_matching() {
        let config = MappingConfig::default();
        let available = vec![
            "rust-tooling".into(),
            "rust-runtime".into(),
            "python-web".into(),
            "linear-dev".into(),
        ];
        let matched = config.skills_for_agent("rust", &AgentRole::Engineer, &available);
        assert!(matched.contains(&"rust-tooling".to_string()));
        assert!(matched.contains(&"rust-runtime".to_string()));
        assert!(!matched.contains(&"python-web".to_string()));
    }

    #[test]
    fn config_adds_explicit_agent_skills() {
        let mut config = MappingConfig::default();
        config.agent_skills.insert(
            "iced".into(),
            vec!["iced-rs".into(), "trading-design".into()],
        );
        let available = vec!["iced-rs".into(), "trading-design".into(), "other".into()];
        let matched = config.skills_for_agent("iced", &AgentRole::Engineer, &available);
        assert!(matched.contains(&"iced-rs".to_string()));
        assert!(matched.contains(&"trading-design".to_string()));
        assert!(!matched.contains(&"other".to_string()));
    }

    #[test]
    fn config_adds_role_skills() {
        let mut config = MappingConfig::default();
        config
            .role_skills
            .insert("engineer".into(), vec!["github".into(), "worktree".into()]);
        let available = vec!["github".into(), "worktree".into(), "linear".into()];
        let matched = config.skills_for_agent("rust", &AgentRole::Engineer, &available);
        assert!(matched.contains(&"github".to_string()));
        assert!(matched.contains(&"worktree".to_string()));
        assert!(!matched.contains(&"linear".to_string()));
    }

    #[test]
    fn analyst_role_skills_keep_planner_and_scout_context_narrow() {
        let mut config = MappingConfig::default();
        config
            .role_skills
            .insert("analyst".into(), vec!["linear".into(), "github".into()]);
        let available = vec![
            "linear".into(),
            "github".into(),
            "worktree".into(),
            "linear-dev".into(),
        ];

        let planner = config.skills_for_agent("planner", &AgentRole::Analyst, &available);
        assert_eq!(planner, vec!["github".to_string(), "linear".to_string()]);

        let scout = config.skills_for_agent("scout", &AgentRole::Analyst, &available);
        assert_eq!(scout, vec!["github".to_string(), "linear".to_string()]);
    }

    #[test]
    fn hook_target_all_matches_every_role() {
        let mut config = MappingConfig::default();
        config
            .hook_events
            .insert("PreToolUse:Bash".into(), HookTarget::All("all".into()));

        let hooks = vec![crate::hook::Hook {
            name: "h1".into(),
            event: "PreToolUse".into(),
            matcher: Some("Bash".into()),
            description: "".into(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: "".into(),
            source_path: std::path::PathBuf::new(),
        }];

        assert_eq!(
            config.hooks_for_agent(&AgentRole::Engineer, &hooks).len(),
            1
        );
        assert_eq!(
            config.hooks_for_agent(&AgentRole::Reviewer, &hooks).len(),
            1
        );
        assert_eq!(config.hooks_for_agent(&AgentRole::Manager, &hooks).len(), 1);
    }

    #[test]
    fn hook_target_roles_filters_correctly() {
        let mut config = MappingConfig::default();
        config.hook_events.insert(
            "PostToolUse:Edit|Write".into(),
            HookTarget::Roles(vec!["engineer".into()]),
        );

        let hooks = vec![crate::hook::Hook {
            name: "h2".into(),
            event: "PostToolUse".into(),
            matcher: Some("Edit|Write".into()),
            description: "".into(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: "".into(),
            source_path: std::path::PathBuf::new(),
        }];

        assert_eq!(
            config.hooks_for_agent(&AgentRole::Engineer, &hooks).len(),
            1
        );
        assert_eq!(
            config.hooks_for_agent(&AgentRole::Reviewer, &hooks).len(),
            0
        );
    }

    #[test]
    fn empty_hook_events_falls_back() {
        let config = MappingConfig::default();
        let hooks = vec![
            crate::hook::Hook {
                name: "h1".into(),
                event: "PreToolUse".into(),
                matcher: Some("Bash".into()),
                description: "".into(),
                safety: None,
                timeout: None,
                harnesses: None,
                script: "".into(),
                source_path: std::path::PathBuf::new(),
            },
            crate::hook::Hook {
                name: "h2".into(),
                event: "PostToolUse".into(),
                matcher: Some("Edit|Write".into()),
                description: "".into(),
                safety: None,
                timeout: None,
                harnesses: None,
                script: "".into(),
                source_path: std::path::PathBuf::new(),
            },
        ];
        // Engineer gets all hooks via the old heuristic
        assert_eq!(
            config.hooks_for_agent(&AgentRole::Engineer, &hooks).len(),
            2
        );
    }

    #[test]
    fn load_missing_file_returns_default() {
        let config = MappingConfig::load(std::path::Path::new("/nonexistent/path"));
        assert!(config.agent_skills.is_empty());
        assert!(config.role_skills.is_empty());
        assert!(config.hook_events.is_empty());
    }

    #[test]
    fn reviewer_agent_checks_stripped_prefix() {
        let mut config = MappingConfig::default();
        // When an explicit agent-skills entry exists, prefix matching is skipped.
        // The reviewer-iced agent inherits from the "iced" entry via prefix stripping.
        config.agent_skills.insert(
            "iced".into(),
            vec!["iced-rs".into(), "trading-design".into()],
        );
        let available = vec!["iced-rs".into(), "trading-design".into()];
        let matched = config.skills_for_agent("reviewer-iced", &AgentRole::Reviewer, &available);
        assert!(matched.contains(&"iced-rs".to_string()));
        assert!(matched.contains(&"trading-design".to_string()));
    }

    #[test]
    fn explicit_entry_skips_prefix_matching() {
        let mut config = MappingConfig::default();
        // Agent "rust" has explicit entry — prefix matching should NOT run.
        // Only the listed skills (plus role-skills) should be attached.
        config.agent_skills.insert(
            "rust".into(),
            vec!["rust-tooling".into(), "rust-runtime".into()],
        );
        let available = vec![
            "rust-tooling".into(),
            "rust-runtime".into(),
            "rust-build".into(), // available but not in explicit list
        ];
        let matched = config.skills_for_agent("rust", &AgentRole::Engineer, &available);
        assert!(matched.contains(&"rust-tooling".to_string()));
        assert!(matched.contains(&"rust-runtime".to_string()));
        // rust-build would be found by prefix matching, but explicit entry skips it
        assert!(!matched.contains(&"rust-build".to_string()));
    }
}
