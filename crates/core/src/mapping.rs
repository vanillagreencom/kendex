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

/// The `[agent-skills]` entry this agent reads, and the key it is written
/// under. A reviewer agent with no entry of its own reads its base
/// agent's, so the key differs from the name exactly when the entry is
/// inherited.
///
/// Both halves from one answer, and the only place the rule is spelled.
/// Asking for the exact name alone calls a real assignment absent and
/// renders the upstream list over the top of it, which is the removal the
/// person made coming back. Asking for the key alone loses the difference
/// between a row an agent owns and one it only reaches — which is the
/// difference between moving the agent's own assignment and shadowing
/// somebody else's.
pub fn declared_skills<'a>(
    manifest: &'a Manifest,
    agent_name: &str,
) -> Option<(&'a Vec<String>, &'a str)> {
    let base = skill_match_prefix(agent_name);
    manifest
        .agent_skills
        .get_key_value(agent_name)
        .or_else(|| manifest.agent_skills.get_key_value(base))
        .map(|(key, list)| (list, key.as_str()))
}

/// The key alone, for a caller that only has to place a write.
pub fn skills_key<'a>(manifest: &'a Manifest, agent_name: &str) -> Option<&'a str> {
    declared_skills(manifest, agent_name).map(|(_, key)| key)
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
    /// Declared skills no source in reach offers: neither the item's own
    /// catalog nor any other source this scope has. Rendering them would
    /// name instructions nothing can load, and dropping them takes a
    /// section away without a word, so the caller refuses on them.
    pub unresolved: Vec<String>,
}

/// v2's durable-removal semantics: a project `[agent-skills]` entry is
/// authoritative; skills the source *newly* lists (vs. the recorded
/// upstream set) merge in; anything the user removed stays removed. With no
/// recorded set (cache loss, pre-v2 lock) nothing auto-merges — the
/// conservative reading that can never resurrect a removal.
///
/// `available` is what this item's own source offers and governs what the
/// source can assign. The declaration resolves wider, against `in_scope`
/// as well: an assignment is made across every source the scope has, and
/// a fork rebound to the local source keeps rendering the skills it was
/// rendered with instead of losing them to a catalog it stopped reading.
pub fn effective_skills(
    agent_name: &str,
    role: Option<Role>,
    manifest: &Manifest,
    source: &SourceConfig,
    available: &[String],
    in_scope: &[String],
    recorded_upstream: Option<&[String]>,
) -> EffectiveSkills {
    let upstream_now = upstream_skills(agent_name, role, source, available);
    let Some((declared, _)) = declared_skills(manifest, agent_name) else {
        return EffectiveSkills {
            effective: upstream_now.clone(),
            upstream_now,
            manifest_additions: Vec::new(),
            unresolved: Vec::new(),
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
    let reachable = |skill: &String| {
        available.iter().any(|s| s == skill) || in_scope.iter().any(|s| s == skill)
    };
    let (mut effective, unresolved): (Vec<String>, Vec<String>) =
        declared.iter().cloned().partition(reachable);
    effective.extend(additions.iter().cloned());
    EffectiveSkills {
        effective,
        upstream_now,
        manifest_additions: additions,
        unresolved,
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

    fn declaring(rows: &[(&str, &[&str])]) -> Manifest {
        let mut manifest = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        for (agent, skills) in rows {
            manifest.agent_skills.insert(
                (*agent).to_owned(),
                skills.iter().map(|s| (*s).to_owned()).collect(),
            );
        }
        manifest
    }

    // One answer carries both halves. A caller that had only the list
    // could not tell a row an agent owns from one it reaches, and a
    // caller that had only the key would look the list up again — which
    // is how the same rule came to be spelled in three places.
    #[test]
    fn one_lookup_answers_with_the_entry_and_the_key_it_is_under() {
        let manifest = declaring(&[("rust", &["dev"]), ("orch", &["github"])]);

        let (skills, key) = declared_skills(&manifest, "reviewer-rust").unwrap();
        assert_eq!(skills, &["dev".to_owned()]);
        assert_eq!(key, "rust");

        let (_, own) = declared_skills(&manifest, "orch").unwrap();
        assert_eq!(own, "orch");

        // Only `reviewer-` reaches a base agent, and a name nothing
        // declares for reaches nothing.
        assert!(declared_skills(&manifest, "planner-rust").is_none());
        assert!(declared_skills(&manifest, "scout").is_none());
    }

    // The key alone drops a half off the same answer rather than asking
    // the question a second way.
    #[test]
    fn the_key_is_the_same_answer_without_its_list() {
        let manifest = declaring(&[("rust", &["dev"])]);
        for name in ["rust", "reviewer-rust", "scout"] {
            assert_eq!(
                skills_key(&manifest, name),
                declared_skills(&manifest, name).map(|(_, key)| key),
            );
        }
    }

    // An agent that reaches its base agent's row renders from that row:
    // the exact-name question would call it undeclared and put the
    // upstream list back over the person's removals.
    #[test]
    fn a_reviewer_agent_renders_from_the_row_it_reaches() {
        let manifest = declaring(&[("rust", &["dev"])]);
        let result = effective_skills(
            "reviewer-rust",
            Some(Role::Reviewer),
            &manifest,
            &SourceConfig::default(),
            &available(),
            &[],
            None,
        );
        assert_eq!(result.effective, ["dev"]);
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
            &[],
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
            &[],
            None,
        );
        assert_eq!(result.effective, ["dev"]);
        assert!(result.manifest_additions.is_empty());
    }

    /// A fork rebinds the agent to the local source, which holds the agent
    /// and none of the catalog skills it was assigned. The declaration
    /// resolves against the scope, so what the agent rendered with before
    /// the fork is what it renders with after.
    #[test]
    fn a_declaration_resolves_against_the_scope_its_own_source_never_held() {
        let manifest = declaring(&[("rust", &["dev", "github"])]);
        let local: Vec<String> = Vec::new();
        let result = effective_skills(
            "rust",
            Some(Role::Engineer),
            &manifest,
            &SourceConfig::default(),
            &local,
            &available(),
            None,
        );
        assert_eq!(result.effective, ["dev", "github"]);
        assert!(result.unresolved.is_empty());
    }

    /// A skill nothing in reach offers is reported, never dropped: the
    /// caller refuses on it rather than rendering an agent short a section.
    #[test]
    fn a_skill_no_source_offers_comes_back_unresolved() {
        let manifest = declaring(&[("rust", &["dev", "gone"])]);
        let local: Vec<String> = Vec::new();
        let result = effective_skills(
            "rust",
            Some(Role::Engineer),
            &manifest,
            &SourceConfig::default(),
            &local,
            &available(),
            None,
        );
        assert_eq!(result.effective, ["dev"]);
        assert_eq!(result.unresolved, ["gone"]);
    }
}
