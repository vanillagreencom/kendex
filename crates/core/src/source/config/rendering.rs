//! What a catalog contributes to an item's rendering, beyond the item.
//!
//! Split out of `config.rs` to stay under the file's line cap. One
//! question, and it has one caller of consequence: a publisher's record
//! binds to this alongside the item's bytes, so editing either stales the
//! record rather than leaving it live over content nobody read.

use crate::model::ItemKind;
use crate::source_read::SealedSource;

use super::SourceConfig;

impl SourceConfig {
    /// Everything this catalog contributes to one item's rendering from
    /// somewhere other than the item's own file, spelled the same way every
    /// time so a publisher's record can bind to it.
    ///
    /// Only what a rendering actually reads. An agent takes its frontmatter
    /// overrides from the control file and its skill list from the catalog
    /// as a whole; every other kind renders from its own bytes alone and
    /// gets an empty string, so the hash for one is unchanged and no record
    /// for one goes stale.
    ///
    /// The skill list goes in *resolved* rather than as the tables it comes
    /// from. Those tables are only half of it: an agent with no explicit
    /// mapping renders with whatever prefix-matching skills the catalog
    /// carries and with its role's defaults, so adding a matching skill
    /// changes the bytes without touching any table. Folding the answer
    /// covers both halves and is narrower than folding either — a skill the
    /// agent does not render with stales nothing.
    ///
    /// The inputs the agent rendering reads and this does *not* fold, each
    /// because it cannot change what the publisher wrote: the harness and
    /// the scope, which no catalog edit moves; everything in
    /// `desired_agent::Project`, which is the project's own text and is
    /// subtracted from the rendering a record is measured against; and the
    /// agent's own bytes, which are hashed beside this.
    pub fn rendering_inputs(&self, sealed: &SealedSource, kind: ItemKind, name: &str) -> String {
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
        spelled.push_str(&format!(
            "skills={}\n",
            self.assigns(sealed, name).join(",")
        ));
        spelled
    }

    /// The skills this catalog's own inputs give one agent — the list its
    /// publisher-only rendering carries, through the same derivation the
    /// plan uses rather than a second reading of the same tables.
    ///
    /// An agent this catalog does not carry, or one whose file will not
    /// parse, assigns nothing: there is no rendering to bind to, and the
    /// item's own bytes answer for that either way.
    fn assigns(&self, sealed: &SealedSource, name: &str) -> Vec<String> {
        let Some(path) = super::find_item(sealed, self, ItemKind::Agent, name) else {
            return Vec::new();
        };
        let Ok(text) = sealed.read_to_string(&path) else {
            return Vec::new();
        };
        let role = crate::render::agent::parse_source_agent(&text)
            .ok()
            .and_then(|agent| agent.role);
        let available = crate::source::list_items(sealed, self, ItemKind::Skill);
        crate::mapping::upstream_skills(name, role, self, &available)
    }
}
