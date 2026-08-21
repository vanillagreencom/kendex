//! Everything a project contributes to how an agent renders, in one place.
//!
//! The rendering that folds it in and the preview that warns it was not
//! previewed both read this, so neither can miss an entry the other has —
//! two lists of one thing is how both ended up missing the same entries.

use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents, Manifest};
use crate::model::HarnessId;
use crate::render::agent::{
    EffectiveAgent, Role, SourceAgent, hooks_for_agent, merge_overrides, merged_instructions,
};
use crate::render::permission::PermissionIntent;

use super::super::desired::ItemCtx;

/// Everything this project contributes to one agent's rendering, gathered
/// in one place.
///
/// The publisher's own rendering is this, defaulted — `Project::default()`
/// — never the effective agent minus a list of fields. A list is a
/// blocklist: whatever is not on it is trusted as the publisher's, so the
/// next project-supplied input inherits the bug in silence. Here the
/// failure runs the other way. An input added to this struct is cleared
/// with the rest and cannot be forgotten; an input that is not in it is
/// not the project's, and saying so is a deliberate act with a place to
/// write it down.
///
/// `is_empty` destructures rather than testing fields by name, so a field
/// added without an answer does not compile.
#[derive(Default)]
pub(super) struct Project<'a> {
    pub(super) launch_instructions: Option<String>,
    pub(super) additional_instructions: Option<String>,
    /// The manifest's half of the frontmatter overrides. Free strings —
    /// tool names, nicknames — that reach the rendered document verbatim
    /// and are read by every rule, so they are the project's text as much
    /// as its prose is, and the permission narrowing derives from them.
    pub(super) frontmatter: Option<&'a FrontmatterOverrides>,
    /// `[agent-skills]`, which replaces the source's own assignment.
    pub(super) skills: Option<Vec<String>>,
    pub(super) custom_hooks: Vec<&'a CustomHook>,
}

impl Project<'_> {
    /// Whether this project contributes nothing to the rendering.
    fn is_empty(&self) -> bool {
        let Project {
            launch_instructions,
            additional_instructions,
            frontmatter,
            skills,
            custom_hooks,
        } = self;
        launch_instructions.is_none()
            && additional_instructions.is_none()
            && frontmatter.is_none()
            && skills.is_none()
            && custom_hooks.is_empty()
    }
}

/// Whether this project contributes anything to how this agent renders —
/// the question a pre-install preview asks, since it reads catalog bytes
/// and none of this is in them. The same enumeration the rendering
/// subtracts by, so the two cannot disagree about what is the project's.
pub(crate) fn contributes_to_agent(manifest: &Manifest, harness: HarnessId, name: &str) -> bool {
    !from_manifest(manifest, harness, name).is_empty()
}

/// What the manifest alone says this project contributes. Custom hooks are
/// taken by target here; which of them a harness actually delivers is
/// [`gathered`]'s narrower question.
fn from_manifest<'a>(manifest: &'a Manifest, harness: HarnessId, name: &str) -> Project<'a> {
    Project {
        launch_instructions: merged_instructions(&manifest.agent_launch_instructions, name),
        additional_instructions: merged_instructions(&manifest.agent_additional_instructions, name),
        frontmatter: manifest
            .agent_frontmatter
            .get(harness.name())
            .and_then(|by_agent| by_agent.get(name)),
        skills: manifest.agent_skills.get(name).cloned(),
        custom_hooks: manifest
            .custom_hooks
            .iter()
            .filter(|hook| hook.enabled && targets(&hook.agents, name))
            .collect(),
    }
}

/// Whether a custom hook's agent selector could reach this agent. `all` and
/// a role name are resolved by the render path, which has the parsed agent
/// and its role; here — where the question is whether this project touches
/// this agent at all — they count as reaching it, since a reading that has
/// to guess guesses toward saying so.
fn targets(agents: &HookAgents, name: &str) -> bool {
    let reaches = |sel: &String| sel == "all" || sel == name || Role::parse(sel).is_some();
    match agents {
        HookAgents::One(sel) => reaches(sel),
        HookAgents::Many(list) => list.iter().any(reaches),
    }
}

/// The same, with the hooks narrowed to what this harness will actually
/// deliver to this agent.
pub(super) fn gathered<'a>(
    ctx: &'a ItemCtx,
    parsed: &SourceAgent,
    harness: HarnessId,
) -> Project<'a> {
    Project {
        custom_hooks: hooks_for_agent(ctx.env, ctx.scope, harness, ctx.manifest, parsed),
        ..from_manifest(ctx.manifest, harness, ctx.name)
    }
}

/// One agent's effective intent for one harness: what the source asks for,
/// with whatever this project contributes folded in. Pass
/// `Project::default()` and what comes out is the publisher's own.
pub(super) fn effective_agent<'a>(
    ctx: &'a ItemCtx,
    source: &'a SourceAgent,
    harness: HarnessId,
    upstream_skills: &[String],
    project: Project<'a>,
) -> EffectiveAgent<'a> {
    let overrides = merge_overrides(
        ctx.config
            .frontmatter
            .get(harness.name())
            .and_then(|by_agent| by_agent.get(ctx.name)),
        project.frontmatter,
    );
    let permissions = PermissionIntent::effective(
        &source.permissions,
        overrides.allow_tools.as_deref(),
        overrides.deny_tools.as_deref(),
    );
    EffectiveAgent {
        source,
        harness,
        scope: ctx.scope,
        skills: project.skills.unwrap_or_else(|| upstream_skills.to_vec()),
        overrides,
        permissions,
        launch_instructions: project.launch_instructions,
        additional_instructions: project.additional_instructions,
        custom_hooks: project.custom_hooks,
    }
}
