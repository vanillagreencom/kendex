use crate::error::Result;
use crate::hash::installation_hash;
use crate::lock::entry_key;
use crate::manifest::{CustomHook, FrontmatterOverrides, HookAgents, Manifest, Method};
use crate::mapping::EffectiveSkills;
use crate::model::{HarnessId, ItemKind};
use crate::render::agent::{
    EffectiveAgent, RenderedAgent, Selects, SourceAgent, file_name, generate, hooks_for_agent,
    merge_overrides, merged_instructions, parse_source_agent, selects,
};
use crate::render::permission::PermissionIntent;
use crate::render::validate::validate_agent;

use super::agent_skills::declared_skills;
use super::desired::{Artifact, Desired, DesiredState, ItemCtx, native_dir};

/// The agent as this tool will know it, or `None` where that is the agent
/// the catalog already wrote. Each tool answers to the name the rendered
/// file gives, and a plugin-registry catalog names its agent inside its plugin
/// — a fact the catalog's own file knows nothing about. The rendering takes
/// the installed name; the catalog keeps the one it wrote.
fn installed_under(
    parsed: &crate::render::agent::SourceAgent,
    declared: &str,
    installed: &str,
) -> Option<crate::render::agent::SourceAgent> {
    (installed != declared).then(|| crate::render::agent::SourceAgent {
        name: installed.to_owned(),
        ..parsed.clone()
    })
}

/// What a tool will do with the agent beyond loading it: Gemini keeps
/// subagents behind a feature flag and lets a system settings layer outrank
/// the project, so a file about to be written may sit there inert, and a
/// repository can narrow the models Copilot will run, leaving an agent
/// pinned outside that list answering differently than the catalog asked.
fn harness_notices(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    harness: crate::model::HarnessId,
    source_agent: &crate::render::agent::SourceAgent,
    overrides: &crate::manifest::FrontmatterOverrides,
) {
    match harness {
        HarnessId::Gemini => super::gemini::agent_notices(ctx, state),
        crate::model::HarnessId::Copilot => {
            let model = overrides.model.as_deref().unwrap_or(&source_agent.model);
            let resolved = crate::harness::models::resolve_model(harness, model);
            super::copilot::agent_notices(ctx, state, resolved.id.as_deref());
        }
        _ => {}
    }
}

/// Whether the rendering may be installed, having said everything there is
/// to say about it — what the renderer noticed, and what the harness's own
/// loader makes of the result. Breakage is refused for the same reason a
/// permission refusal is: installing an agent the tool cannot read leaves
/// the user with one that is ignored in silence.
fn loadable(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    harness: crate::model::HarnessId,
    installed: &str,
    rendered: &RenderedAgent,
) -> bool {
    let findings = validate_agent(harness, installed, &rendered.text);
    // A refusal says everything: the rest is advice about a file that is
    // not being written.
    if let Some(reason) = super::desired::refusal_reason(&findings) {
        state.refused.push(super::desired::Refused {
            kind: ItemKind::Agent,
            name: ctx.name.to_owned(),
            harness,
            reason,
        });
        return false;
    }
    for warning in &rendered.warnings {
        state.warnings.push(super::ItemWarning {
            kind: ItemKind::Agent,
            name: ctx.name.to_owned(),
            harness: Some(harness),
            message: warning.message.clone(),
            remediation: warning.remediation.clone(),
        });
    }
    for finding in findings.iter().filter(|finding| !finding.is_breakage()) {
        state.warnings.push(super::ItemWarning {
            kind: ItemKind::Agent,
            name: ctx.name.to_owned(),
            harness: Some(harness),
            message: finding.message.clone(),
            remediation: Some(finding.remediation.clone()),
        });
    }
    true
}

/// Agents are generated, never linked: every harness gets its own rendering
/// of the same source agent, overwritten on each apply.
pub(super) fn desired_agent(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    updated_manifest: &mut Manifest,
    manifest_changed: &mut bool,
) -> Result<()> {
    let enabled = ctx.decl.enabled;
    let text = ctx.sealed.read_to_string(ctx.item_path)?;
    let parsed = match parse_source_agent(&text) {
        Ok(agent) => agent,
        Err(problem) => {
            state.unreadable(
                ItemKind::Agent,
                ctx.name,
                format!("{}: unreadable agent — {problem}", ctx.name),
            );
            return Ok(());
        }
    };
    for warning in &parsed.warnings {
        state.warnings.push(super::ItemWarning {
            kind: ItemKind::Agent,
            name: ctx.name.to_owned(),
            harness: None,
            message: warning.clone(),
            remediation: None,
        });
    }
    let skills =
        super::agent_skills::assigned_skills(ctx, parsed.role, updated_manifest, manifest_changed);
    for harness in ctx.harnesses.clone() {
        let Some(native) = native_dir(ctx.env, ctx.scope, harness, ItemKind::Agent) else {
            continue;
        };
        let installed = crate::harness::rendered_name(harness, ctx.name);
        let namespaced = installed_under(&parsed, ctx.name, &installed);
        let source_agent = namespaced.as_ref().unwrap_or(&parsed);
        notice_overrides(ctx, state, harness, source_agent, &parsed, &skills);
        let project = gathered(ctx, &parsed, harness, &skills.effective);
        let effective = effective_agent(ctx, source_agent, harness, &skills.upstream_now, project);
        let Some(rendered) = render_or_refuse(ctx, state, harness, &effective) else {
            continue;
        };
        if !loadable(ctx, state, harness, &installed, &rendered) {
            continue;
        }
        state.items.push(Desired {
            key: entry_key(ItemKind::Agent, ctx.name, harness),
            kind: ItemKind::Agent,
            name: ctx.name.to_owned(),
            harness,
            enabled,
            method: Method::Copy,
            source_name: ctx.decl.source.clone(),
            provenance: ctx.provenance.to_owned(),
            source_commit: ctx.source_commit.map(str::to_owned),
            recorded_fork: ctx.recorded_fork(ItemKind::Agent),
            hash: installation_hash(
                ctx.sealed,
                ctx.item_path,
                ctx.manifest,
                ItemKind::Agent,
                ctx.name,
                harness,
            )?,
            upstream_skills: Some(skills.upstream_now.clone()),
            emitted: None,
            reasons: ctx.reasons_for(harness),
            artifact: Artifact::File {
                path: written_at(&native, harness, ctx.name, enabled),
                bytes: rendered.text.into_bytes(),
            },
        });
    }
    Ok(())
}

/// Where this agent's file lands. A disabled installation keeps the
/// rendered content under the `.disabled` name — the rename is lossless.
pub(super) fn written_at(
    native: &std::path::Path,
    harness: crate::model::HarnessId,
    name: &str,
    enabled: bool,
) -> std::path::PathBuf {
    let base = file_name(harness, name);
    match enabled {
        true => native.join(&base),
        false => native.join(format!("{base}.disabled")),
    }
}

/// The advisories this harness's own overrides raise, said once per
/// installation before anything is rendered from them.
fn notice_overrides(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    harness: crate::model::HarnessId,
    source_agent: &crate::render::agent::SourceAgent,
    parsed: &crate::render::agent::SourceAgent,
    skills: &EffectiveSkills,
) {
    let effective = effective_agent(
        ctx,
        source_agent,
        harness,
        &skills.upstream_now,
        gathered(ctx, parsed, harness, &skills.effective),
    );
    harness_notices(ctx, state, harness, source_agent, &effective.overrides);
}

/// This agent for this harness, or `None` where the harness cannot express
/// its permission intent. A refusal produces no artifact: the plan turns it
/// into a conflict row plus removal of any previous, wider rendering —
/// never a silent widen, never a leftover.
fn render_or_refuse(
    ctx: &ItemCtx,
    state: &mut DesiredState,
    harness: crate::model::HarnessId,
    effective: &EffectiveAgent,
) -> Option<RenderedAgent> {
    match generate(effective) {
        Ok(rendered) => Some(rendered),
        Err(refusal) => {
            state.refused.push(super::desired::Refused {
                kind: ItemKind::Agent,
                name: ctx.name.to_owned(),
                harness,
                reason: refusal,
            });
            None
        }
    }
}

// Everything a project contributes to how an agent renders, in one place.
//
// The rendering that folds it in and the preview that warns it was not
// previewed both read this, so neither can miss an entry the other has —
// two lists of one thing is how both ended up missing the same entries.

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
struct Project<'a> {
    launch_instructions: Option<String>,
    additional_instructions: Option<String>,
    /// The manifest's half of the frontmatter overrides. Free strings —
    /// tool names, nicknames — that reach the rendered document verbatim
    /// and are read by every rule, so they are the project's text as much
    /// as its prose is, and the permission narrowing derives from them.
    frontmatter: Option<&'a FrontmatterOverrides>,
    /// `[agent-skills]`, which replaces the source's own assignment.
    skills: Option<Vec<String>>,
    custom_hooks: Vec<&'a CustomHook>,
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
        skills: crate::mapping::declared_skills(manifest, name).map(|(list, _)| list.clone()),
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
    let reaches = |sel: &String| !matches!(selects(sel), Selects::Named) || sel == name;
    match agents {
        HookAgents::One(sel) => reaches(sel),
        HookAgents::Many(list) => list.iter().any(reaches),
    }
}

/// The same, with the hooks narrowed to what this harness will actually
/// deliver to this agent and the skill assignment taken from the list the
/// pass already resolved.
///
/// `effective` is [`crate::mapping::EffectiveSkills::effective`]: the
/// declaration filtered to what is installed, with the upstream additions
/// this pass merged into the manifest folded in. Reading the manifest again
/// here would render the list the pass has already moved past — an upstream
/// skill discovered this run would need a second apply to appear, and a
/// declaration held under the base agent's name would read as no
/// declaration at all and bring back the skills the person removed.
fn gathered<'a>(
    ctx: &'a ItemCtx,
    parsed: &SourceAgent,
    harness: HarnessId,
    effective: &[String],
) -> Project<'a> {
    Project {
        custom_hooks: hooks_for_agent(ctx.env, ctx.scope, harness, ctx.manifest, parsed),
        // Still the project's contribution or nothing: with no declaration
        // to read, the source's own assignment is the publisher's and is
        // not folded in here.
        skills: crate::mapping::declared_skills(ctx.manifest, ctx.name).map(|_| effective.to_vec()),
        ..from_manifest(ctx.manifest, harness, ctx.name)
    }
}

/// One agent's effective intent for one harness: what the source asks for,
/// with whatever this project contributes folded in. Pass
/// `Project::default()` and what comes out is the publisher's own.
fn effective_agent<'a>(
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
