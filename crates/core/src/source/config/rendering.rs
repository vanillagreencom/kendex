//! What a catalog's own control file contributes to an item's rendering.
//!
//! Split out of `config.rs` to stay under the file's line cap. One
//! question, and it has one caller of consequence: a publisher's record
//! binds to this alongside the item's bytes, so editing either stales the
//! record rather than leaving it live over content nobody read.

use crate::model::ItemKind;

use super::SourceConfig;

impl SourceConfig {
    /// What this catalog's own control file contributes to one item's
    /// rendering, spelled the same way every time so a publisher's record
    /// can bind to it.
    ///
    /// Only what a rendering actually reads. An agent takes its frontmatter
    /// overrides and its skill assignment from these tables; every other
    /// kind renders from its own bytes alone and gets an empty string, so
    /// the hash for one is unchanged and no record for one goes stale.
    ///
    /// `role_skills` goes in whole rather than by the agent's own role: the
    /// role is in the agent's bytes, which are hashed beside this, and
    /// reading them again here to narrow the table would be a second
    /// parse that has to agree with the first. Editing one role's list
    /// therefore stales every agent's record, which is the safe direction.
    pub fn rendering_inputs(&self, kind: ItemKind, name: &str) -> String {
        if kind != ItemKind::Agent {
            return String::new();
        }
        let stripped = crate::mapping::skill_match_prefix(name);
        let mut spelled = String::new();
        for (harness, by_agent) in &self.frontmatter {
            for agent in [name, stripped] {
                if let Some(overrides) = by_agent.get(agent) {
                    let written = serde_json::to_string(overrides).unwrap_or_default();
                    spelled.push_str(&format!("frontmatter/{harness}/{agent}={written}\n"));
                }
            }
        }
        for agent in [name, stripped] {
            if let Some(skills) = self.agent_skills.get(agent) {
                spelled.push_str(&format!("agent-skills/{agent}={}\n", skills.join(",")));
            }
        }
        for (role, skills) in &self.role_skills {
            spelled.push_str(&format!("role-skills/{role}={}\n", skills.join(",")));
        }
        spelled
    }
}
