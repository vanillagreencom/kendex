//! What a catalog contributes to one agent's rendering beyond the agent's
//! own file. Its skill assignment and its per-harness frontmatter defaults
//! live in the catalog's control file, not in the bytes anything copies,
//! so an agent that stops reading that catalog — detached, or forked into
//! the local source — renders differently at the very next apply unless
//! those values move into the manifest first.

use std::collections::BTreeMap;

use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents, Manifest};
use crate::model::ItemKind;
use crate::render::agent::Selects;
use crate::source::SourceConfig;
use crate::source_read::SealedSource;

/// The catalog-level values one kept agent rendered with: the effective
/// skill list and the merged per-harness frontmatter.
#[derive(Clone, Default)]
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
    /// entry already governs; frontmatter folds in over what is there,
    /// carried value winning per field.
    ///
    /// Folding rather than replacing, because a carry holds a record only
    /// for a harness the catalog configured this agent under: where the
    /// catalog configured none and the project did, the carry's whole
    /// record is the person's edit alone, and writing that over the
    /// project's entry drops the denies it held. `uncleared` refuses a
    /// deliberate deletion before anything reaches here, so nothing folded
    /// back in is a value the person took away.
    pub(crate) fn apply(self, manifest: &mut Manifest, name: &str) {
        if !self.skills.is_empty() && !manifest.agent_skills.contains_key(name) {
            manifest.agent_skills.insert(name.to_owned(), self.skills);
        }
        for (harness, carried) in self.frontmatter {
            let by_agent = manifest.agent_frontmatter.entry(harness).or_default();
            let held = by_agent.get(name).cloned().unwrap_or_default();
            by_agent.insert(
                name.to_owned(),
                crate::render::agent::merge_overrides(Some(&held), Some(&carried)),
            );
        }
    }
}

/// What the catalog contributed to this agent's rendering, or `None` when
/// it contributed nothing. `bytes` is the agent's own source file, read
/// for the role its skill assignment keys on.
///
/// The assignment resolves against the whole scope here, exactly as the
/// rendering resolved it. Read against this catalog alone, the carry would
/// report fewer skills than the file on disk holds, and the capture would
/// keep a section the next render writes again.
///
/// `in_scope` is the scope the operation leaves behind, so an assignment
/// nothing there can answer refuses now — the same rule the renderer
/// applies to a recorded fork, at the moment the copy is made rather than
/// the moment it is next rendered. Left to the renderer alone it arrives
/// too late: the copy is already written, its next audit fails, and the
/// section it kept as prose becomes a second copy the day the source
/// comes back.
pub(crate) fn agent_carry(
    manifest: &Manifest,
    sealed: &SealedSource,
    config: &SourceConfig,
    name: &str,
    bytes: &[u8],
    in_scope: &super::ScopeSkills,
) -> crate::error::Result<Option<AgentCarry>> {
    let text = String::from_utf8_lossy(bytes);
    let role = crate::render::agent::parse_source_agent(&text)
        .ok()
        .and_then(|agent| agent.role);
    let available = crate::source::list_items(sealed, config, ItemKind::Skill);
    let skills = crate::mapping::effective_skills(
        name,
        role,
        manifest,
        config,
        &available,
        in_scope.names(),
        None,
    );
    if let Some(refusal) = skills.refusal(name, in_scope.names()) {
        return Err(refusal);
    }
    let skills = skills.effective;
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
        return Ok(None);
    }
    Ok(Some(AgentCarry {
        skills,
        frontmatter,
    }))
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
    // An entry under a shared key belongs to every agent that reads it,
    // not to the agent whose name spells it. Moving one because that agent
    // moved would rewrite what every other agent renders.
    if !crate::render::agent::shared_instructions_key(from) {
        carry(&mut manifest.agent_launch_instructions, from, to, gone);
        carry(&mut manifest.agent_additional_instructions, from, to, gone);
    }
    carry_skills(manifest, from, to, gone);
    for by_agent in manifest.agent_frontmatter.values_mut() {
        carry(by_agent, from, to, gone);
    }
    for hook in &mut manifest.custom_hooks {
        reselect(&mut hook.agents, from, to, gone);
    }
}

/// Move the skill assignment. Alone among these tables it is not read by
/// exact name: a `reviewer-` agent with no row of its own reads the base
/// agent's, so a name whose list came through that fallback has no row for
/// [`carry`] to find and renders with the source's list instead of the
/// project's.
///
/// What it reaches is asked of the reader that resolves it, so the
/// fallback rule has one spelling. The resolved row is copied and never
/// moved, even for a rename: it is the base agent's own row, shared with
/// every other `reviewer-` agent, and taking it away would strip them all.
fn carry_skills(manifest: &mut Manifest, from: &str, to: &str, gone: bool) {
    if manifest.agent_skills.contains_key(from) {
        carry(&mut manifest.agent_skills, from, to, gone);
        return;
    }
    let inherited = crate::mapping::declared_skills(manifest, from).map(|(list, _)| list.clone());
    if let Some(skills) = inherited {
        manifest.agent_skills.insert(to.to_owned(), skills);
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
/// restriction disappears.
///
/// Only a selector whose kind is an agent name moves. `all` and a role
/// name describe a population rather than one agent: they already reach
/// the copy, and rewriting one because a single agent happens to be named
/// for it would take the restriction off every other agent the population
/// holds — an operation that never mentioned them.
fn reselect(agents: &mut HookAgents, from: &str, to: &str, gone: bool) {
    let mine = |selector: &String| names_agent(selector, from);
    let mut names = match agents {
        HookAgents::One(selector) => vec![selector.clone()],
        HookAgents::Many(list) => list.clone(),
    };
    if !names.iter().any(mine) {
        return;
    }
    match gone {
        true => names
            .iter_mut()
            .filter(|selector| mine(selector))
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

/// Why an agent's configuration cannot travel from `from` to `to`: this
/// scope already configures an agent under the new name, or the new name
/// is a spelling some reader takes for a population and cannot hold one
/// agent's. One question, because a caller asking half of it writes a key
/// that means something wider than it meant to.
pub(crate) fn cannot_carry(manifest: &Manifest, from: &str, to: &str) -> Option<String> {
    if let Some(entry) = configured_as(manifest, from, to) {
        return Some(format!(
            "this scope already configures that agent in {entry} — pick another name, or clear that entry first"
        ));
    }
    unwritable_under(manifest, from, to)
}

/// Where this scope already configures an agent under `to`, said as the
/// person would find it in kendex.toml. A fork or a rename landing on a
/// name that carries configuration would replace what is there, so the
/// operation refuses instead: the same enumeration as [`rekey_agent_tables`],
/// asked as a question rather than moved.
///
/// `from` is the name being left, which the one table read by fallback
/// needs: a destination reaching the source agent's own row shadows
/// nothing, since that row is what [`carry_skills`] moves. Only a row some
/// other agent's name resolves to is in the way — the same distinction
/// [`unwritable_under`] draws between owning a spelling and reaching it.
fn configured_as(manifest: &Manifest, from: &str, to: &str) -> Option<&'static str> {
    if manifest
        .agent_frontmatter
        .values()
        .any(|by_agent| by_agent.contains_key(to))
    {
        return Some("[agent-frontmatter]");
    }
    // Asked of the reader that resolves it, for the reason [`carry_skills`]
    // moves what it moves: a name with no row of its own reads the base
    // agent's, and a row written here would shadow the person's — the
    // exact-key question would call that name vacant.
    let reached = crate::mapping::skills_key(manifest, to);
    if reached.is_some() && reached != crate::mapping::skills_key(manifest, from) {
        return Some(match manifest.agent_skills.contains_key(to) {
            true => "[agent-skills]",
            false => "[agent-skills], under the base name this one reads",
        });
    }
    // An instructions entry under a shared key is every agent's, so it is
    // not this name's to be replaced — the same reading [`rekey_agent_tables`]
    // refuses to move.
    let its_own = !crate::render::agent::shared_instructions_key(to);
    if its_own && manifest.agent_launch_instructions.contains_key(to) {
        return Some("[agent-launch-instructions]");
    }
    if its_own && manifest.agent_additional_instructions.contains_key(to) {
        return Some("[agent-additional-instructions]");
    }
    gated_by_name(manifest, to).map(|_| "[custom-hooks]")
}

/// Whether this selector is this agent's own name — the one kind a rename
/// or a copy moves. `all` and a role name describe a population, so an
/// agent that happens to be called one never owns the selector spelling
/// it, and one agent's move must not rewrite it.
fn names_agent(selector: &str, agent: &str) -> bool {
    selector == agent && crate::render::agent::selects(selector) == Selects::Named
}

/// The first hook that gates this agent by its own name, so the selector
/// has to travel when the name does.
fn gated_by_name<'a>(manifest: &'a Manifest, name: &str) -> Option<&'a CustomHook> {
    let named = |agents: &HookAgents| match agents {
        HookAgents::One(selector) => names_agent(selector, name),
        HookAgents::Many(list) => list.iter().any(|selector| names_agent(selector, name)),
    };
    manifest
        .custom_hooks
        .iter()
        .find(|hook| named(&hook.agents))
}

/// Why one agent's configuration cannot be keyed under `to`, or `None`
/// where it can. Every piece of that configuration answers to the
/// installed name, but two readers give some spellings a meaning of their
/// own: [`crate::render::agent::selects`] reads `all` and a role name as a
/// population, and an instructions entry under a shared key is the one
/// every agent reads. Neither can be written as one agent's, so a move
/// onto such a name is refused rather than made — the representation has
/// no way to say "this one agent, despite the spelling".
///
/// Only where there is something to move. A population spelling is an
/// ordinary name for an agent nothing gates and nothing instructs, and
/// refusing it there would invent a naming rule the operation never
/// needed.
fn unwritable_under(manifest: &Manifest, from: &str, to: &str) -> Option<String> {
    // What the new spelling would gate, said as the refusal says it, or
    // `None` where it names one agent and the selector can simply move.
    let population = match crate::render::agent::selects(to) {
        Selects::Named => None,
        Selects::Everyone => Some("every agent".to_owned()),
        Selects::Role(role) => Some(format!("the {} role", role.name())),
    };
    if let Some(population) = population
        && let Some(hook) = gated_by_name(manifest, from)
    {
        return Some(format!(
            "a custom hook gates {from} by name, running {}, and that selector travels with the name — but a selector spelling this one reads as {population}, so the gate would move onto every agent it names; pick a name no role uses, or take {from} out of the hook's selector first",
            hook.command,
        ));
    }
    if crate::render::agent::shared_instructions_key(to)
        && (manifest.agent_launch_instructions.contains_key(from)
            || manifest.agent_additional_instructions.contains_key(from))
    {
        return Some(format!(
            "{from} has instructions of its own, and an entry under this name is the one every agent reads — pick another name, or clear those instructions first"
        ));
    }
    None
}
