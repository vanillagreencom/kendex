//! What a catalog contributes to one agent's rendering beyond the agent's
//! own file. Its skill assignment and its per-harness frontmatter defaults
//! live in the catalog's control file, not in the bytes anything copies,
//! so an agent that stops reading that catalog — detached, or forked into
//! the local source — renders differently at the very next apply unless
//! those values move into the manifest first.

use std::collections::BTreeMap;

use crate::manifest::{FrontmatterOverrides, Manifest};
use crate::model::ItemKind;
use crate::source::SourceConfig;
use crate::source_read::SealedSource;

/// The catalog-level values one kept agent rendered with: the effective
/// skill list and the merged per-harness frontmatter.
#[derive(Default)]
pub(crate) struct AgentCarry {
    skills: Vec<String>,
    frontmatter: Vec<(String, FrontmatterOverrides)>,
}

impl AgentCarry {
    /// Whether this carries nothing, so nothing has to reach the manifest.
    pub(crate) fn is_empty(&self) -> bool {
        self.skills.is_empty() && self.frontmatter.is_empty()
    }

    /// Fold one harness's overrides in above whatever is already carried
    /// for it. `extra` wins per field, the way the project's own entry
    /// wins over the catalog's default when both are read from disk.
    pub(crate) fn over(mut self, harness: &str, extra: FrontmatterOverrides) -> AgentCarry {
        if extra == FrontmatterOverrides::default() {
            return self;
        }
        match self
            .frontmatter
            .iter_mut()
            .find(|(name, _)| name == harness)
        {
            Some((_, carried)) => {
                *carried = crate::render::agent::merge_overrides(Some(carried), Some(&extra));
            }
            None => self.frontmatter.push((harness.to_owned(), extra)),
        }
        self
    }

    /// Write the carried values into the manifest under `name`. Skills
    /// land only where the manifest has nothing of its own, since an
    /// entry already governs; frontmatter is written over, because the
    /// value carried is the catalog-beneath-project merge and already
    /// holds whatever the project said.
    pub(crate) fn apply(self, manifest: &mut Manifest, name: &str) {
        if !self.skills.is_empty() && !manifest.agent_skills.contains_key(name) {
            manifest.agent_skills.insert(name.to_owned(), self.skills);
        }
        for (harness, merged) in self.frontmatter {
            manifest
                .agent_frontmatter
                .entry(harness)
                .or_default()
                .insert(name.to_owned(), merged);
        }
    }
}

/// What the catalog contributed to this agent's rendering, or `None` when
/// it contributed nothing. `bytes` is the agent's own source file, read
/// for the role its skill assignment keys on.
pub(crate) fn agent_carry(
    manifest: &Manifest,
    sealed: &SealedSource,
    config: &SourceConfig,
    name: &str,
    bytes: &[u8],
) -> Option<AgentCarry> {
    let text = String::from_utf8_lossy(bytes);
    let role = crate::render::agent::parse_source_agent(&text)
        .ok()
        .and_then(|agent| agent.role);
    let available = crate::source::list_items(sealed, config, ItemKind::Skill);
    let skills =
        crate::mapping::effective_skills(name, role, manifest, config, &available, None).effective;
    let mut frontmatter = Vec::new();
    for (harness, by_agent) in &config.frontmatter {
        let Some(defaults) = by_agent.get(name) else {
            continue;
        };
        let merged = crate::render::agent::merge_overrides(
            Some(defaults),
            manifest
                .agent_frontmatter
                .get(harness)
                .and_then(|agents| agents.get(name)),
        );
        frontmatter.push((harness.clone(), merged));
    }
    if skills.is_empty() && frontmatter.is_empty() {
        return None;
    }
    Some(AgentCarry {
        skills,
        frontmatter,
    })
}

/// Whether the name an agent's tables are keyed under still exists after
/// the operation that moved them.
pub(crate) enum OldName {
    /// A fork beside the original: the original stays declared and keeps
    /// rendering, so taking its overrides away would widen it.
    Kept,
    /// A rename: nothing answers to the old name any more.
    Gone,
}

/// Carry every manifest table an agent answers to by name from `from` to
/// `to`. Each is keyed by the installed name, so a copy or a rename that
/// leaves them behind renders the agent without the project's tool denies
/// and without its instructions — silently, and more permissively than
/// the agent it came from.
pub(crate) fn rekey_agent_tables(manifest: &mut Manifest, from: &str, to: &str, old: OldName) {
    if from == to {
        return;
    }
    let gone = matches!(old, OldName::Gone);
    carry(&mut manifest.agent_launch_instructions, from, to, gone);
    carry(&mut manifest.agent_additional_instructions, from, to, gone);
    carry(&mut manifest.agent_skills, from, to, gone);
    for by_agent in manifest.agent_frontmatter.values_mut() {
        carry(by_agent, from, to, gone);
    }
}

fn carry<T: Clone>(table: &mut BTreeMap<String, T>, from: &str, to: &str, gone: bool) {
    let taken = match gone {
        true => table.remove(from),
        false => table.get(from).cloned(),
    };
    if let Some(value) = taken {
        table.insert(to.to_owned(), value);
    }
}
