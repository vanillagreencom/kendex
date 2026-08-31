//! Capturing an agent a fork keeps. The rendering on disk is a generated
//! document: it states a name a harness loader wants, a deny list the
//! renderer computed, defaults the source never wrote, and a banner saying
//! not to edit it. Read back as source form it loses the person's tool
//! denies, flips defaults, and carries the banner into the body, so the
//! next render writes a second one above it.
//!
//! What is captured instead is the catalog's own file for the agent at the
//! commit the installation came from, carrying the person's edited body.
//! The frontmatter is the publisher's; the prose is the person's, which is
//! the edit a fork exists to keep. Whatever the catalog contributed from
//! outside that file — skill assignment, per-harness frontmatter defaults
//! — moves into the manifest, because the fork stops reading the catalog.

use std::path::Path;

use crate::error::{CoreError, Result};
use crate::manifest::FrontmatterOverrides;
use crate::model::{HarnessId, ItemKind, Scope};

use crate::render::agent::{
    EffectiveAgent, SourceAgent, hooks_for_agent, merge_overrides, merged_instructions,
    parse_source_agent,
};

mod prose;
mod wrapper;

use super::ForkOf;
use crate::engine::agent_carry::{AgentCarry, agent_carry};
use prose::prose;
use wrapper::{Wrapper, wrapper};

/// One captured agent: the source-form bytes for the local source, and the
/// catalog values that have to reach the manifest with them.
pub(super) struct CapturedAgent {
    pub bytes: Vec<u8>,
    pub carry: Option<AgentCarry>,
}

/// The agent as the local source should hold it. `installed_as` is the
/// name the fork will render under — the original's for a fork in place,
/// the person's choice for one beside it — because a harness's own deny
/// rules read the name, and the wrapper that finds the person's prose is
/// read under the name the file was written with.
pub(super) fn capture_agent(of: &ForkOf, edited: &Path) -> Result<CapturedAgent> {
    let ForkOf {
        env,
        scope,
        manifest,
        decl,
        name,
        harness,
        ..
    } = *of;
    let Published {
        bytes: published,
        agent: publisher,
        carry,
        overrides,
    } = published(of)?;
    // What the project and the catalog put around this agent's own prose,
    // as the file on disk was written with it, and as the fork will write
    // it again. Everything in it is keyed by the agent's name and travels
    // whole — the skill assignment included, because it resolves against
    // the scope and not against the source the fork rebinds to.
    let around = Around {
        skills: carry.as_ref().map(AgentCarry::skills).unwrap_or_default(),
        overrides,
        launch: merged_instructions(&manifest.agent_launch_instructions, name),
        additional: merged_instructions(&manifest.agent_additional_instructions, name),
        hooks: hooks_for_agent(env, scope, harness, manifest, &publisher),
    };

    let edited_text = std::fs::read_to_string(edited).map_err(|e| CoreError::io(edited, e))?;
    // A rendering this reader cannot account for is a refusal, never a
    // capture taken anyway: the wrapper says which words are the person's,
    // and one read wrongly cuts their own out of their prose.
    let read = wrapper(scope, &publisher, harness, &around).map_err(|problem| {
        CoreError::ForkWrapperUnreadable {
            name: crate::names::shown(name),
            harness: harness.display_name().to_owned(),
            problem,
        }
    })?;
    let bytes = source_form(&published, &edited_text, name, read.as_ref())?;
    // Parsed for its diagnostics alone: source form the parser refuses is
    // source form the next apply refuses too, and saying so now beats
    // writing it into the local source and failing there.
    parse_source_agent(&String::from_utf8_lossy(&bytes))
        .map_err(|problem| unreadable(name, &decl.source, problem))?;
    Ok(CapturedAgent { bytes, carry })
}

/// The agent as its catalog published it, at the commit this installation
/// came from: its bytes, its parsed form, and everything that catalog
/// contributed to its rendering from outside the file itself.
struct Published {
    bytes: Vec<u8>,
    agent: SourceAgent,
    carry: Option<AgentCarry>,
    /// The overrides the fork will hold, not the ones the manifest holds
    /// now: the catalog's defaults are on their way into it with the
    /// carry, and a fork beside the original writes them under the new
    /// name. Reading the manifest alone would call them already lost and
    /// refuse a fork that carries them perfectly well.
    overrides: FrontmatterOverrides,
}

fn published(of: &ForkOf) -> Result<Published> {
    let ForkOf {
        env,
        scope,
        manifest,
        decl,
        name,
        harness,
        ..
    } = *of;
    let commit = super::installed_commit(env, scope, ItemKind::Agent, name, harness, decl)?;
    let resolved =
        match crate::source::resolve_at(env, scope, &decl.source, manifest, commit.as_deref())? {
            crate::source::SourceState::Ready(ready) => ready,
            _ => {
                return Err(CoreError::SourcePending {
                    name: decl.source.clone(),
                });
            }
        };
    let sealed = crate::source_read::SealedSource::open(&resolved.root)?;
    let config = crate::source::source_config_for(&sealed, &resolved.provenance)?;
    let Some(path) = crate::source::find_item(&sealed, &config, ItemKind::Agent, name) else {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: decl.source.clone(),
        });
    };
    let bytes = sealed.read(&path)?;
    let in_scope = crate::engine::ScopeSkills::of(env, scope, manifest)?;
    Ok(Published {
        agent: parse_source_agent(&String::from_utf8_lossy(&bytes))
            .map_err(|problem| unreadable(name, &decl.source, problem))?,
        carry: agent_carry(manifest, &sealed, &config, name, &bytes, &in_scope)?,
        overrides: merge_overrides(
            config
                .frontmatter
                .get(harness.name())
                .and_then(|by_agent| by_agent.get(name)),
            manifest
                .agent_frontmatter
                .get(harness.name())
                .and_then(|by_agent| by_agent.get(name)),
        ),
        bytes,
    })
}

fn unreadable(name: &str, source_name: &str, problem: String) -> CoreError {
    CoreError::ItemNotInSource {
        name: name.to_owned(),
        source_name: format!("{source_name} has no readable agent file for it — {problem}"),
    }
}

/// The catalog's frontmatter over the person's own prose.
fn source_form(
    published: &[u8],
    edited: &str,
    name: &str,
    wrapper: Option<&Wrapper>,
) -> Result<Vec<u8>> {
    let refused = |problem: String| CoreError::ForkNameUnusable {
        name: crate::names::shown(name),
        problem,
    };
    let published = std::str::from_utf8(published)
        .map_err(|_| refused("the catalog's file for it is not text".to_owned()))?;
    let (frontmatter, _) = crate::frontmatter::split(published).map_err(refused)?;
    let body = crate::frontmatter::split(edited)
        .map(|(_, body)| body)
        .unwrap_or(edited);
    Ok(format!("---\n{frontmatter}---\n\n{}", prose(body, wrapper)).into_bytes())
}

/// What the project and the catalog put around one agent's prose.
struct Around<'a> {
    skills: Vec<String>,
    overrides: FrontmatterOverrides,
    launch: Option<String>,
    additional: Option<String>,
    hooks: Vec<&'a crate::manifest::CustomHook>,
}

/// One rendering of this agent for this harness, or `None` where the
/// harness refuses its permission intent. A refusal installs nothing at
/// all, so there is no wrapper to read a body out of.
fn render(
    scope: &Scope,
    source: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> Option<String> {
    let permissions = EffectiveAgent::intent(source, &around.overrides);
    let effective = EffectiveAgent {
        source,
        harness,
        scope,
        skills: around.skills.clone(),
        overrides: around.overrides.clone(),
        permissions,
        launch_instructions: around.launch.clone(),
        additional_instructions: around.additional.clone(),
        custom_hooks: around.hooks.clone(),
    };
    crate::render::agent::generate(&effective)
        .ok()
        .map(|rendered| rendered.text)
}
