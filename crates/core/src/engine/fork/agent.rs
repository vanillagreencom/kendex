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

mod prose;

use super::ForkOf;
use super::stated::{carried_edits, dropped, stated, uncleared};
use crate::engine::agent_carry::{AgentCarry, agent_carry};
use prose::prose;

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

    let edited_text = std::fs::read_to_string(edited).map_err(|e| CoreError::io(edited, e))?;
    let refused = |problem: String| CoreError::ForkWidensAccess {
        name: crate::names::shown(name),
        problem,
    };
    let on_disk = stated(harness, &edited_text).map_err(|problem| {
        refused(format!(
            "the tool settings its {} file states: its frontmatter cannot be read ({problem})",
            harness.display_name()
        ))
    })?;
    let read = wrapper(scope, &publisher, harness, &around).map_err(|problem| {
        CoreError::ForkWidensAccess {
            name: crate::names::shown(name),
            problem: format!("its {} wrapper: {problem}", harness.display_name()),
        }
    })?;
    let bytes = source_form(&published, &edited_text, name, read.as_ref())?;
    let captured = parse_source_agent(&String::from_utf8_lossy(&bytes))
        .map_err(|problem| unreadable(name, &decl.source, problem))?;
    let named = SourceAgent {
        name: installed_as.to_owned(),
        ..captured.clone()
    };
    let Some(rendering) = render(scope, &named, harness, &around) else {
        return Ok(CapturedAgent {
            bytes,
            carry,
            read_at,
        });
    };
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
    let prose = prose(body, wrapper);
    Ok(format!("---\n{frontmatter}---\n\n{prose}").into_bytes())
}

struct Around<'a> {
    skills: Vec<String>,
    overrides: FrontmatterOverrides,
    launch: Option<String>,
    additional: Option<String>,
    hooks: Vec<&'a crate::manifest::CustomHook>,
}

#[derive(Debug)]
pub(super) struct Wrapper {
    pub(super) before: Vec<String>,
    pub(super) after: Vec<String>,
    pub(super) published: String,
}

#[derive(Clone, Copy)]
enum Wrote {
    Launch,
    Skills,
    Hook(usize),
    Additional,
}

fn wrapper(
    scope: &Scope,
    publisher: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> std::result::Result<Option<Wrapper>, String> {
    let (Some((bare_before, bare_after)), Some((before, after)), Some(bare_body)) = (
        ends(scope, publisher, harness, &bare(around)),
        ends(scope, publisher, harness, around),
        document(scope, publisher, harness, &bare(around)),
    ) else {
        return Ok(None);
    };
    let mut parts = Vec::new();
    for input in [Wrote::Launch, Wrote::Skills]
        .into_iter()
        .chain((0..around.hooks.len()).map(Wrote::Hook))
        .chain([Wrote::Additional])
    {
        let Some(part) = ends(scope, publisher, harness, &only(around, input)) else {
            return Ok(None);
        };
        parts.push(part);
    }
    decompose(bare_before, bare_after, before, after, bare_body, parts)
}

fn decompose(
    bare_before: String,
    bare_after: String,
    before: String,
    after: String,
    bare_body: String,
    parts: Vec<(String, String)>,
) -> std::result::Result<Option<Wrapper>, String> {
    let published = bare_body
        .strip_prefix(&bare_before)
        .and_then(|body| body.strip_suffix(&bare_after))
        .ok_or_else(|| "the published prose does not stand whole inside it".to_owned())?;
    let mut read = Wrapper {
        before: vec![bare_before.clone()],
        after: Vec::new(),
        published: published.to_owned(),
    };
    for (one_before, one_after) in parts {
        match (
            one_before.strip_prefix(&bare_before),
            one_after.strip_prefix(&bare_after),
        ) {
            (Some(""), Some("")) => {}
            (Some(section), Some("")) => read.before.push(section.to_owned()),
            (Some(""), Some(section)) => read.after.push(section.to_owned()),
            (Some(_), Some(_)) => {
                return Err("one generated section stands on both sides".to_owned());
            }
            _ => return Err("one generated section rewrites the document".to_owned()),
        }
    }
    if read.before.concat() != before || format!("{bare_after}{}", read.after.concat()) != after {
        return Err("the generated sections do not reconstruct the document".to_owned());
    }
    Ok(Some(read))
}

fn ends(
    scope: &Scope,
    publisher: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> Option<(String, String)> {
    const STAND_IN: &str = "kendexstandsinfortheagentsownprose";
    let source = SourceAgent {
        body: STAND_IN.to_owned(),
        ..publisher.clone()
    };
    let body = document(scope, &source, harness, around)?;
    let (before, after) = body.split_once(STAND_IN)?;
    Some((before.to_owned(), after.to_owned()))
}

fn document(
    scope: &Scope,
    source: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> Option<String> {
    let text = render(scope, source, harness, around)?;
    crate::frontmatter::split(&text)
        .ok()
        .map(|(_, body)| body.to_owned())
}

fn bare<'a>(around: &Around<'a>) -> Around<'a> {
    Around {
        skills: Vec::new(),
        overrides: around.overrides.clone(),
        launch: None,
        additional: None,
        hooks: Vec::new(),
    }
}

fn only<'a>(around: &Around<'a>, wrote: Wrote) -> Around<'a> {
    let mut one = bare(around);
    match wrote {
        Wrote::Launch => one.launch = around.launch.clone(),
        Wrote::Skills => one.skills = around.skills.clone(),
        Wrote::Hook(at) => one.hooks = around.hooks.get(at).copied().into_iter().collect(),
        Wrote::Additional => one.additional = around.additional.clone(),
    }
    one
}

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
