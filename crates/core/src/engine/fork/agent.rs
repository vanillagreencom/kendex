//! Capture an edited agent as publisher frontmatter plus the rendered body.
//! Catalog settings outside the file move into the manifest with the fork.

use std::path::Path;

use crate::error::{CoreError, Result};
use crate::manifest::FrontmatterOverrides;
use crate::model::{HarnessId, ItemKind, Scope};

use crate::render::agent::{
    EffectiveAgent, SourceAgent, hooks_for_agent, merge_overrides, merged_instructions,
    parse_source_agent,
};

use super::ForkOf;
use super::stated::{carried_edits, dropped, stated, uncleared};
use crate::engine::agent_carry::{AgentCarry, agent_carry};

/// The local source bytes and catalog values a captured agent needs.
pub(super) struct CapturedAgent {
    pub bytes: Vec<u8>,
    pub carry: Option<AgentCarry>,
    /// The catalog revision those bytes came from.
    pub read_at: Option<String>,
}

/// Capture the edited agent, refusing a fork that would widen its access.
pub(super) fn capture_agent(of: &ForkOf, edited: &Path) -> Result<CapturedAgent> {
    let ForkOf {
        env,
        scope,
        manifest,
        decl,
        name,
        installed_as,
        harness,
        ..
    } = *of;
    let Published {
        bytes: published,
        agent: publisher,
        carry,
        overrides,
        read_at,
    } = published(of)?;
    let around = Around {
        skills: carry.as_ref().map(AgentCarry::skills).unwrap_or_default(),
        overrides,
        launch: merged_instructions(&manifest.agent_launch_instructions, name),
        additional: merged_instructions(&manifest.agent_additional_instructions, name),
        hooks: hooks_for_agent(env, scope, harness, manifest, &publisher),
    };

    let refused = |problem: String| CoreError::ForkWidensAccess {
        name: crate::names::shown(name),
        problem,
    };
    let render_refused = |problem: String| {
        refused(format!(
            "the access settings its {} renderer rejected: {problem}",
            harness.display_name()
        ))
    };
    let edited_text = std::fs::read_to_string(edited).map_err(|e| CoreError::io(edited, e))?;
    let read = wrapper(scope, &publisher, harness, &around).map_err(&render_refused)?;
    let bytes = source_form(&published, &edited_text, name, read.as_ref())?;
    let captured = parse_source_agent(&String::from_utf8_lossy(&bytes))
        .map_err(|problem| unreadable(name, &decl.source, problem))?;
    let on_disk = stated(harness, &edited_text).map_err(|problem| {
        refused(format!(
            "the tool settings its {} file states: its frontmatter cannot be read ({problem})",
            harness.display_name()
        ))
    })?;
    let named = SourceAgent {
        name: installed_as.to_owned(),
        ..captured.clone()
    };
    let rendering = render(scope, &named, harness, &around).map_err(render_refused)?;
    let after = stated(harness, &rendering)
        .map_err(|problem| refused(format!("its own rendering reads back as {problem}")))?;
    if let Some(problem) = dropped(&on_disk, &after, harness) {
        return Err(refused(problem));
    }
    let cleared = uncleared(&on_disk, &after);
    if !cleared.is_empty() {
        return Err(refused(format!(
            "the {} setting{} deleted from its {} file: {}",
            cleared.len(),
            if cleared.len() == 1 { "" } else { "s" },
            harness.display_name(),
            cleared.join(", ")
        )));
    }
    let carry = carry
        .unwrap_or_default()
        .over(harness.name(), carried_edits(&on_disk, &after));
    Ok(CapturedAgent {
        bytes,
        carry: (!carry.is_empty()).then_some(carry),
        read_at,
    })
}

struct Published {
    bytes: Vec<u8>,
    agent: SourceAgent,
    carry: Option<AgentCarry>,
    overrides: FrontmatterOverrides,
    read_at: Option<String>,
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
        read_at: commit,
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

fn source_form(
    published: &[u8],
    edited: &str,
    name: &str,
    wrapper: Option<&(String, String)>,
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
    let prose = prose(body, wrapper);
    Ok(format!("---\n{frontmatter}---\n\n{prose}").into_bytes())
}

/// The edited body with the generated wrapper removed. A wrapper only
/// comes off when it still stands whole at that edge, and the generated
/// banner comes off inside it, being the first thing the rendered prefix
/// holds. Everything else is the person's text and stays byte-for-byte as
/// the rendered harness said it, including that harness's vocabulary and
/// any line of theirs that reads like a banner.
fn prose(body: &str, wrapper: Option<&(String, String)>) -> String {
    let mut kept = body;
    if let Some((before, after)) = wrapper {
        // The renderer always writes LF and the file is whatever the
        // person's editor saved, so each edge is compared in the
        // document's own convention. The slice still comes off the
        // original text, which is what keeps their endings.
        let as_saved = |edge: &String| match crlf(body) {
            true => edge.replace('\n', "\r\n"),
            false => edge.clone(),
        };
        let (before, after) = (as_saved(before), as_saved(after));
        kept = kept.strip_prefix(before.as_str()).unwrap_or(kept);
        kept = kept.strip_suffix(after.as_str()).unwrap_or(kept);
    }
    format!("{}\n", kept.trim_start_matches('\n').trim_end())
}

/// Whether this document ends its lines CRLF, read off the first line
/// terminator in it. A file an editor rewrote ends every line the one
/// way; one that mixes them matches no edge and nothing comes off, which
/// is the same answer a document nobody can read whole gets.
fn crlf(body: &str) -> bool {
    body.find('\n')
        .is_some_and(|at| body.as_bytes()[..at].last() == Some(&b'\r'))
}

struct Around<'a> {
    skills: Vec<String>,
    overrides: FrontmatterOverrides,
    launch: Option<String>,
    additional: Option<String>,
    hooks: Vec<&'a crate::manifest::CustomHook>,
}

/// What this rendering puts before and after an agent's own body. Asking
/// the renderer with a stand-in keeps section spelling in the renderer.
fn wrapper(
    scope: &Scope,
    publisher: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> std::result::Result<Option<(String, String)>, String> {
    const STAND_IN: &str = "kendexstandsinfortheagentsownprose";
    let source = SourceAgent {
        body: STAND_IN.to_owned(),
        ..publisher.clone()
    };
    let text = render(scope, &source, harness, around)?;
    let Some((_, body)) = crate::frontmatter::split(&text).ok() else {
        return Ok(None);
    };
    let Some((before, after)) = body.split_once(STAND_IN) else {
        return Ok(None);
    };
    Ok(Some((before.to_owned(), after.to_owned())))
}

fn render(
    scope: &Scope,
    source: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> std::result::Result<String, String> {
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
    crate::render::agent::generate(&effective).map(|rendered| rendered.text)
}
