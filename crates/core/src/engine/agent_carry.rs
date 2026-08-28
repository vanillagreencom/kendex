//! What a catalog contributes to one agent's rendering beyond the agent's
//! own file. Its skill assignment and its per-harness frontmatter defaults
//! live in the catalog's control file, not in the bytes anything copies,
//! so an agent that stops reading that catalog — detached, or forked into
//! the local source — renders differently at the very next apply unless
//! those values move into the manifest first.

use std::collections::BTreeMap;

use crate::manifest::{FrontmatterOverrides, HookAgents, Manifest};
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
    /// The skill assignment this agent rendered with. Read rather than
    /// recomputed, so the rendering a capture compares against cannot
    /// disagree with the list the manifest is about to hold.
    pub(crate) fn skills(&self) -> Vec<String> {
        self.skills.clone()
    }

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

/// Whether the name an agent's configuration is keyed under still exists
/// after the operation that moved it.
pub(crate) enum OldName {
    /// A fork beside the original: the original stays declared and keeps
    /// rendering, so taking its configuration away would widen it.
    Kept,
    /// A rename: nothing answers to the old name any more.
    Gone,
}

/// Move or copy an agent's whole configuration from `from` to `to`. Every
/// piece of it is keyed by the installed name, so a copy or a rename that
/// leaves it behind renders the agent without the project's tool denies,
/// without its instructions, and outside its own hooks — silently, and
/// more permissively than the agent it came from.
///
/// Which places those are is read off [`crate::engine::desired_agent`]'s
/// own `from_manifest`, the enumeration a rendering subtracts by: whatever
/// that reads for an agent is what has to travel with the agent's name.
/// Four of the five are maps keyed by the name; a custom hook is not a map
/// at all, naming the agents it applies to in its own selector, so it
/// travels by rewriting that selector. [`configured_as`] asks the same
/// list as a question and must gain every entry this gains.
///
/// Only an agent has this configuration. A skill forked beside its source
/// shares the manifest's namespace with agents and would otherwise copy a
/// same-named agent's settings onto an unrelated name.
pub(crate) fn rekey_agent_tables(
    manifest: &mut Manifest,
    kind: ItemKind,
    from: &str,
    to: &str,
    old: OldName,
) {
    if kind != ItemKind::Agent || from == to {
        return;
    }
    let gone = matches!(old, OldName::Gone);
    carry(&mut manifest.agent_launch_instructions, from, to, gone);
    carry(&mut manifest.agent_additional_instructions, from, to, gone);
    carry(&mut manifest.agent_skills, from, to, gone);
    for by_agent in manifest.agent_frontmatter.values_mut() {
        carry(by_agent, from, to, gone);
    }
    for hook in &mut manifest.custom_hooks {
        reselect(&mut hook.agents, from, to, gone);
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

/// Point one hook's agent selector at the new name. A selector naming the
/// agent reaches the copy only by saying so, and after a rename it points
/// at a name nothing answers to, which is how an agent-scoped `PreToolUse`
/// restriction disappears. `all` and role selectors match by what the
/// agent is rather than by its name, so they already reach the copy and
/// are left alone.
fn reselect(agents: &mut HookAgents, from: &str, to: &str, gone: bool) {
    let mut names = match agents {
        HookAgents::One(selector) => vec![selector.clone()],
        HookAgents::Many(list) => list.clone(),
    };
    if !names.iter().any(|selector| selector == from) {
        return;
    }
    match gone {
        true => names
            .iter_mut()
            .filter(|selector| *selector == from)
            .for_each(|selector| *selector = to.to_owned()),
        false => {
            if !names.iter().any(|selector| selector == to) {
                names.push(to.to_owned());
            }
        }
    }
    *agents = match names.len() {
        1 => HookAgents::One(names.remove(0)),
        _ => HookAgents::Many(names),
    };
}

/// Where this scope already configures an agent under `name`, named as the
/// person would find it in kendex.toml. A fork or a rename landing on a
/// name that carries configuration would replace what is there, so the
/// operation refuses instead: the same enumeration as [`rekey_agent_tables`],
/// asked as a question rather than moved.
pub(crate) fn configured_as(manifest: &Manifest, name: &str) -> Option<&'static str> {
    if manifest
        .agent_frontmatter
        .values()
        .any(|by_agent| by_agent.contains_key(name))
    {
        return Some("agent-frontmatter");
    }
    if manifest.agent_skills.contains_key(name) {
        return Some("agent-skills");
    }
    if manifest.agent_launch_instructions.contains_key(name) {
        return Some("agent-launch-instructions");
    }
    if manifest.agent_additional_instructions.contains_key(name) {
        return Some("agent-additional-instructions");
    }
    let named = |agents: &HookAgents| match agents {
        HookAgents::One(selector) => selector == name,
        HookAgents::Many(list) => list.iter().any(|selector| selector == name),
    };
    manifest
        .custom_hooks
        .iter()
        .any(|hook| named(&hook.agents))
        .then_some("custom-hooks")
}
