use crate::error::Result;
use crate::hash::installation_hash;
use crate::lock::entry_key;
use crate::manifest::{Manifest, Method};
use crate::mapping::{EffectiveSkills, effective_skills};
use crate::model::ItemKind;
use crate::render::agent::{
    EffectiveAgent, RenderedAgent, Role, file_name, generate, hooks_for_agent, merge_overrides,
    merged_instructions, parse_source_agent,
};
use crate::render::permission::PermissionIntent;
use crate::render::validate::validate_agent;
use crate::source::list_items;

use super::desired::{Artifact, Desired, DesiredState, ItemCtx, native_dir};

/// The agent's skill list, merging anything upstream added since the last
/// sync back into the manifest so the declaration keeps saying what the
/// agent actually renders with.
fn assigned_skills(
    ctx: &ItemCtx,
    role: Option<Role>,
    updated_manifest: &mut Manifest,
    manifest_changed: &mut bool,
) -> EffectiveSkills {
    let available = list_items(ctx.sealed, ctx.config, ItemKind::Skill);
    let recorded = ctx.harnesses.iter().find_map(|h| {
        ctx.lock
            .entries
            .get(&entry_key(ItemKind::Agent, ctx.name, *h))
            .and_then(|entry| entry.upstream_skills.clone())
    });
    let skills = effective_skills(
        ctx.name,
        role,
        ctx.manifest,
        ctx.config,
        &available,
        recorded.as_deref(),
    );
    if skills.manifest_additions.is_empty() {
        return skills;
    }
    let entry = updated_manifest
        .agent_skills
        .entry(merge_key(ctx.manifest, ctx.name))
        .or_default();
    for skill in &skills.manifest_additions {
        if !entry.contains(skill) {
            entry.push(skill.clone());
        }
    }
    *manifest_changed = true;
    skills
}

/// The `agent_skills` key the effective list was read from. Writing
/// additions anywhere else creates an entry that shadows the one being read,
/// and the shadowed skills silently vanish from the next rendering.
fn merge_key(manifest: &Manifest, name: &str) -> String {
    if manifest.agent_skills.contains_key(name) {
        return name.to_owned();
    }
    let stripped = crate::mapping::skill_match_prefix(name);
    match manifest.agent_skills.contains_key(stripped) {
        true => stripped.to_owned(),
        false => name.to_owned(),
    }
}

/// Source-catalog defaults merged with project overrides for one harness,
/// and the permission intent that merge produces.
fn harness_overrides(
    ctx: &ItemCtx,
    source_agent: &crate::render::agent::SourceAgent,
    harness: crate::model::HarnessId,
    inputs: Inputs,
) -> (crate::manifest::FrontmatterOverrides, PermissionIntent) {
    let overrides = merge_overrides(
        ctx.config
            .frontmatter
            .get(harness.name())
            .and_then(|by_agent| by_agent.get(ctx.name)),
        match inputs {
            Inputs::Everything => ctx
                .manifest
                .agent_frontmatter
                .get(harness.name())
                .and_then(|by_agent| by_agent.get(ctx.name)),
            Inputs::PublisherOnly => None,
        },
    );
    let permissions = PermissionIntent::effective(
        &source_agent.permissions,
        overrides.allow_tools.as_deref(),
        overrides.deny_tools.as_deref(),
    );
    (overrides, permissions)
}

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
        crate::model::HarnessId::Gemini => super::gemini::agent_notices(ctx, state),
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
    let skills = assigned_skills(ctx, parsed.role, updated_manifest, manifest_changed);
    for harness in ctx.harnesses.clone() {
        let Some(native) = native_dir(ctx.env, ctx.scope, harness, ItemKind::Agent) else {
            continue;
        };
        let installed = crate::harness::rendered_name(harness, ctx.name);
        let namespaced = installed_under(&parsed, ctx.name, &installed);
        let source_agent = namespaced.as_ref().unwrap_or(&parsed);
        notice_overrides(ctx, state, harness, source_agent);
        let effective = effective_agent(
            ctx,
            source_agent,
            &parsed,
            harness,
            &skills,
            Inputs::Everything,
        );
        let authored = ctx.author_review.as_ref().and_then(|_| {
            authored_agent(&effective_agent(
                ctx,
                source_agent,
                &parsed,
                harness,
                &skills,
                Inputs::PublisherOnly,
            ))
        });
        let rendered = match generate(&effective) {
            Ok(rendered) => rendered,
            // A refusal produces no artifact for this harness; the plan
            // turns it into a conflict row plus removal of any previous,
            // wider rendering — never a silent widen, never a leftover.
            Err(refusal) => {
                state.refused.push(super::desired::Refused {
                    kind: ItemKind::Agent,
                    name: ctx.name.to_owned(),
                    harness,
                    reason: refusal,
                });
                continue;
            }
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
            author_review: ctx.author_review.clone(),
            authored,
            earned: Default::default(),
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
fn written_at(
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
) {
    let (overrides, _) = harness_overrides(ctx, source_agent, harness, Inputs::Everything);
    harness_notices(ctx, state, harness, source_agent, &overrides);
}

/// Whose inputs a rendering is built from.
///
/// Every input a project can contribute to is answered here, in one place,
/// and every arm of every match below is written out: a new project-supplied
/// input has to say what the publisher's own rendering does with it, or a
/// publisher's review would silently cover text the project wrote. The
/// fields with no arm — `source`, `harness`, `scope` — carry no project
/// text at all: the first two are the catalog's own bytes and the tool
/// being rendered for, and the third is a path.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Inputs {
    Everything,
    PublisherOnly,
}

/// One agent's effective intent for one harness: what the source asks for,
/// narrowed by this project's overrides, and this project's own text
/// spliced in beside it — or, under `PublisherOnly`, the source's alone.
fn effective_agent<'a>(
    ctx: &'a ItemCtx,
    source: &'a crate::render::agent::SourceAgent,
    parsed: &crate::render::agent::SourceAgent,
    harness: crate::model::HarnessId,
    skills: &EffectiveSkills,
    inputs: Inputs,
) -> EffectiveAgent<'a> {
    let (overrides, permissions) = harness_overrides(ctx, source, harness, inputs);
    EffectiveAgent {
        source,
        harness,
        scope: ctx.scope,
        // A project's `[agent-skills]` decides the effective list; the
        // source's own assignment is what it asked for.
        skills: match inputs {
            Inputs::Everything => skills.effective.clone(),
            Inputs::PublisherOnly => skills.upstream_now.clone(),
        },
        // `[agent-frontmatter]` writes free strings — tool names, nicknames
        // — that reach the rendered document verbatim and are read by every
        // rule, so they are the project's text as much as its prose is.
        // Permissions derive from those same overrides.
        overrides,
        permissions,
        launch_instructions: match inputs {
            Inputs::Everything => {
                merged_instructions(&ctx.manifest.agent_launch_instructions, ctx.name)
            }
            Inputs::PublisherOnly => None,
        },
        additional_instructions: match inputs {
            Inputs::Everything => {
                merged_instructions(&ctx.manifest.agent_additional_instructions, ctx.name)
            }
            Inputs::PublisherOnly => None,
        },
        custom_hooks: match inputs {
            Inputs::Everything => {
                hooks_for_agent(ctx.env, ctx.scope, harness, ctx.manifest, parsed)
            }
            Inputs::PublisherOnly => Vec::new(),
        },
    }
}

/// The publisher's own agent, rendered. What it is built from is
/// [`Inputs::PublisherOnly`]'s answer, so this only asks the renderer;
/// subtracting from the rendered text instead would be reading a document
/// backwards for text a project could have written to look like anything.
/// `None` where the publisher's own inputs render to nothing this harness
/// can hold, which settles nothing.
fn authored_agent(publishers: &EffectiveAgent) -> Option<crate::quality::Content> {
    generate(publishers)
        .ok()
        .map(|rendered| crate::quality::Content::Document {
            text: rendered.text,
        })
}
