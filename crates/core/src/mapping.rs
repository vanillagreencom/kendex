use crate::manifest::Manifest;
use crate::render::agent::Role;
use crate::source::SourceConfig;

/// v1's built-in role fallbacks, used when a source declares no
/// `[role-skills]` table. A role-less agent gets none — fleet defaults are
/// for fleet roles, not for foreign agents that never declared one.
fn default_role_skills(role: Option<Role>) -> &'static [&'static str] {
    match role {
        Some(Role::Reviewer) => &["dev"],
        Some(Role::Analyst) => &["linear", "github"],
        Some(Role::Engineer) => &["dev", "github", "worktree"],
        Some(Role::Manager) => &["project-management", "linear", "dev", "github", "worktree"],
        None => &[],
    }
}

/// Reviewer agents share their base agent's skill assignment: `agent_skills`
/// lookups fall back to this name when the full one has no entry.
pub(crate) fn skill_match_prefix(agent_name: &str) -> &str {
    agent_name.strip_prefix("reviewer-").unwrap_or(agent_name)
}

/// The `[agent-skills]` entry this agent reads and the name it is written
/// under. A reviewer agent with no entry of its own reads its base
/// agent's, so the two names differ exactly when the entry is inherited.
///
/// The one place the lookup lives. Asking for the exact name alone calls a
/// real assignment absent and renders the upstream list over the top of
/// it, which is the removal the person made coming back.
pub fn declared_skills<'a>(
    manifest: &'a Manifest,
    agent_name: &'a str,
) -> Option<(&'a Vec<String>, &'a str)> {
    if let Some(own) = manifest.agent_skills.get(agent_name) {
        return Some((own, agent_name));
    }
    let base = skill_match_prefix(agent_name);
    manifest.agent_skills.get(base).map(|list| (list, base))
}

fn prefixed_matches(agent_name: &str, available: &[String]) -> Vec<String> {
    let name = agent_name.to_lowercase();
    let prefix = skill_match_prefix(&name);
    available
        .iter()
        .filter(|skill| *skill == prefix || skill.starts_with(&format!("{prefix}-")))
        .cloned()
        .collect()
}

/// What the source alone assigns to this agent — v1 ordering: prefix
/// matches (suppressed by an explicit source entry), the source's
/// `[agent-skills]` (with the `reviewer-` fallback), then role skills.
/// Filtered to available, sorted, deduplicated.
pub fn upstream_skills(
    agent_name: &str,
    role: Option<Role>,
    source: &SourceConfig,
    available: &[String],
) -> Vec<String> {
    let stripped = skill_match_prefix(agent_name);
    let explicit = source
        .agent_skills
        .get(agent_name)
        .or_else(|| source.agent_skills.get(stripped));
    let mut skills: Vec<String> = if explicit.is_some() {
        Vec::new()
    } else {
        prefixed_matches(agent_name, available)
    };
    let mut push = |name: &str| {
        if available.iter().any(|s| s == name) && !skills.iter().any(|s| s == name) {
            skills.push(name.to_owned());
        }
    };
    if let Some(list) = explicit {
        for skill in list {
            push(skill);
        }
    }
    match role.and_then(|role| source.role_skills.get(role.name())) {
        Some(list) => {
            for skill in list {
                push(skill);
            }
        }
        None => {
            for skill in default_role_skills(role) {
                push(skill);
            }
        }
    }
    skills.sort();
    skills
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectiveSkills {
    pub effective: Vec<String>,
    /// The full upstream assignment right now — recorded into the lock so
    /// the next sync can tell upstream additions from user removals.
    pub upstream_now: Vec<String>,
    /// Upstream additions that must be merged into the manifest entry.
    pub manifest_additions: Vec<String>,
}

/// v2's durable-removal semantics: a project `[agent-skills]` entry is
/// authoritative; skills the source *newly* lists (vs. the recorded
/// upstream set) merge in; anything the user removed stays removed. With no
/// recorded set (cache loss, pre-v2 lock) nothing auto-merges — the
/// conservative reading that can never resurrect a removal.
pub fn effective_skills(
    agent_name: &str,
    role: Option<Role>,
    manifest: &Manifest,
    source: &SourceConfig,
    available: &[String],
    recorded_upstream: Option<&[String]>,
) -> EffectiveSkills {
    let upstream_now = upstream_skills(agent_name, role, source, available);
    let Some((declared, _)) = declared_skills(manifest, agent_name) else {
        return EffectiveSkills {
            effective: upstream_now.clone(),
            upstream_now,
            manifest_additions: Vec::new(),
        };
    };
    let additions: Vec<String> = match recorded_upstream {
        Some(recorded) => upstream_now
            .iter()
            .filter(|skill| !recorded.contains(skill) && !declared.contains(skill))
            .cloned()
            .collect(),
        None => Vec::new(),
    };
    let mut effective: Vec<String> = declared
        .iter()
        .filter(|skill| available.iter().any(|s| &s == skill))
        .cloned()
        .collect();
    effective.extend(additions.iter().cloned());
    EffectiveSkills {
        effective,
        upstream_now,
        manifest_additions: additions,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::MANIFEST_SCHEMA;

    fn available() -> Vec<String> {
        ["dev", "github", "worktree", "rust-perf", "rust", "linear"]
            .map(str::to_owned)
            .to_vec()
    }

    #[test]
    fn upstream_combines_prefix_and_role_skills() {
        let source = SourceConfig::default();
        let skills = upstream_skills("rust", Some(Role::Engineer), &source, &available());
        assert_eq!(skills, ["dev", "github", "rust", "rust-perf", "worktree"]);

        let reviewer =
            upstream_skills("reviewer-rust", Some(Role::Reviewer), &source, &available());
        assert_eq!(reviewer, ["dev", "rust", "rust-perf"]);
    }

    #[test]
    fn explicit_source_entry_suppresses_prefix_matching() {
        let mut source = SourceConfig::default();
        source
            .agent_skills
            .insert("rust".into(), vec!["github".into()]);
        source.role_skills.insert("engineer".into(), vec![]);
        let skills = upstream_skills("rust", Some(Role::Engineer), &source, &available());
        assert_eq!(skills, ["github"]);
    }

    #[test]
    fn user_removals_stay_removed_while_upstream_additions_merge() {
        let mut manifest = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        // The user removed "worktree" from the upstream assignment.
        manifest
            .agent_skills
            .insert("rust".into(), vec!["dev".into(), "github".into()]);
        let source = SourceConfig::default();

        // Upstream later gains "rust-perf" (recorded set predates it).
        let recorded = ["dev", "github", "rust", "worktree"].map(str::to_owned);
        let result = effective_skills(
            "rust",
            Some(Role::Engineer),
            &manifest,
            &source,
            &available(),
            Some(&recorded),
        );
        assert_eq!(result.manifest_additions, ["rust-perf"]);
        assert_eq!(result.effective, ["dev", "github", "rust-perf"]);
        assert!(!result.effective.contains(&"worktree".to_owned()));
    }

    #[test]
    fn cache_loss_never_resurrects_removals() {
        let mut manifest = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        manifest
            .agent_skills
            .insert("rust".into(), vec!["dev".into()]);
        let result = effective_skills(
            "rust",
            Some(Role::Engineer),
            &manifest,
            &SourceConfig::default(),
            &available(),
            None,
        );
        assert_eq!(result.effective, ["dev"]);
        assert!(result.manifest_additions.is_empty());
    }
}
