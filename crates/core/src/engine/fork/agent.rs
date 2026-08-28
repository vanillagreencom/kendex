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
    EffectiveAgent, GENERATED_BANNER, SourceAgent, hooks_for_agent, merge_overrides,
    merged_instructions, parse_source_agent,
};
use crate::render::permission::PermissionIntent;

use super::ForkOf;
use super::stated::{carried_edits, dropped, stated, uncleared};
use crate::engine::agent_carry::{AgentCarry, agent_carry};

/// One captured agent: the source-form bytes for the local source, and the
/// catalog values that have to reach the manifest with them.
pub(super) struct CapturedAgent {
    pub bytes: Vec<u8>,
    pub carry: Option<AgentCarry>,
}

/// The agent as the local source should hold it. `installed_as` is the
/// name the fork will render under — the original's for a fork in place,
/// the person's choice for one beside it — because a harness's own deny
/// rules read the name, and a fork that lands under a different one has
/// to be compared under that name or the comparison proves nothing.
///
/// Refuses before returning anything where the rendering on disk keeps
/// tools from the agent that the fork would hand back.
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
    } = published(of)?;
    // What the project and the catalog put around this agent's own prose,
    // as the file on disk was written with it.
    let assigned = carry.as_ref().map(AgentCarry::skills).unwrap_or_default();
    let around = Around {
        skills: assigned.clone(),
        overrides,
        launch: merged_instructions(&manifest.agent_launch_instructions, name),
        additional: merged_instructions(&manifest.agent_additional_instructions, name),
        hooks: hooks_for_agent(env, scope, harness, manifest, &publisher),
    };
    // The same, as the fork itself will write it. Only the skill list
    // differs: the assignment travels into the manifest, but the next
    // apply filters it to what the LOCAL source offers, and a catalog
    // skill is not in there. Everything else around the prose is keyed by
    // the agent's name and travels whole.
    let forked = Around {
        skills: local_skills(env, scope, &assigned)?,
        ..around.clone()
    };

    let edited_text = std::fs::read_to_string(edited).map_err(|e| CoreError::io(edited, e))?;
    let bytes = source_form(
        &published,
        &edited_text,
        name,
        wrapper(scope, &publisher, harness, &around).as_ref(),
        wrapper(scope, &publisher, harness, &forked).as_ref(),
    )?;
    let captured = parse_source_agent(&String::from_utf8_lossy(&bytes))
        .map_err(|problem| unreadable(name, &decl.source, problem))?;
    let refused = |problem: String| CoreError::ForkWidensAccess {
        name: crate::names::shown(name),
        problem,
    };
    let on_disk = stated(harness, &edited_text).map_err(|problem| {
        // Frontmatter that will not parse is not the same answer as
        // frontmatter stating nothing: what the person restricted cannot be
        // read, so it cannot be proven carried either.
        refused(format!(
            "the tool settings its {} file states: its frontmatter cannot be read ({problem})",
            harness.display_name()
        ))
    })?;
    // The harness may refuse this agent's permission intent, in which case
    // the fork installs no file for it at all: no wider artifact to compare
    // against, and no rendering to read the person's edits back off.
    let named = SourceAgent {
        name: installed_as.to_owned(),
        ..captured
    };
    let Some(rendering) = render(scope, &named, harness, &forked) else {
        return Ok(CapturedAgent { bytes, carry });
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
    })
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
    Ok(Published {
        agent: parse_source_agent(&String::from_utf8_lossy(&bytes))
            .map_err(|problem| unreadable(name, &decl.source, problem))?,
        carry: agent_carry(manifest, &sealed, &config, name, &bytes),
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
    was: Option<&(String, String)>,
    will_be: Option<&(String, String)>,
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
    Ok(format!("---\n{frontmatter}---\n\n{}", prose(body, was, will_be)).into_bytes())
}

/// The person's own prose: the edited body with the generated wrapper
/// taken off. Everything in that wrapper is written again by the next
/// render, out of the manifest entries this fork carries, so prose keeping
/// a copy of it would render twice — the banner duplication one layer out.
///
/// The banner comes off separately as well, because a person who deleted
/// that one line leaves a body the wrapper no longer matches, and that is
/// no reason to keep the rest of it.
fn prose(body: &str, was: Option<&(String, String)>, will_be: Option<&(String, String)>) -> String {
    let mut kept = body;
    let mut orphaned = String::new();
    if let Some((before, after)) = was {
        kept = kept.strip_prefix(before.as_str()).unwrap_or(kept);
        kept = kept.strip_suffix(after.as_str()).unwrap_or(kept);
        // A stripper that takes more than the regenerator puts back
        // deletes the person's content. Where the fork writes a shorter
        // wrapper than the file was given, the difference is theirs to
        // keep, so it comes back as prose.
        if let Some((_, coming)) = will_be {
            orphaned = dropped_section(after, coming);
        }
    }
    let mut out = String::new();
    for line in kept.lines().filter(|line| line.trim() != GENERATED_BANNER) {
        out.push_str(line);
        out.push('\n');
    }
    out.push_str(&orphaned);
    // Only the blank separators go. A first line indented into a code
    // block is the person's own content, and trimming it would render
    // their block as ordinary prose.
    format!("{}\n", out.trim_start_matches('\n').trim_end())
}

/// The part of the wrapper a file was given that the fork will not write
/// again. The two differ only where a section stops being generated, so
/// the difference is what is left after taking off the head and the tail
/// they share — found that way rather than by naming sections here, which
/// is a list that goes stale the moment a renderer grows one.
fn dropped_section(was: &str, will_be: &str) -> String {
    // By line, not by character: two sections under the same heading level
    // share their opening `## `, and a character-wise reading hands that
    // back as common ground and returns a heading with its marker eaten.
    let was: Vec<&str> = was.lines().collect();
    let coming: Vec<&str> = will_be.lines().collect();
    let head = was
        .iter()
        .zip(coming.iter())
        .take_while(|(a, b)| a == b)
        .count();
    let tail = was
        .iter()
        .rev()
        .zip(coming.iter().rev())
        .take_while(|(a, b)| a == b)
        .count()
        .min(was.len().saturating_sub(head));
    let dropped = was[head..was.len() - tail].join("\n");
    match dropped.trim().is_empty() {
        true => String::new(),
        false => format!("\n{}\n", dropped.trim_matches('\n')),
    }
}

/// What the project and the catalog put around one agent's prose.
#[derive(Clone)]
struct Around<'a> {
    skills: Vec<String>,
    overrides: FrontmatterOverrides,
    launch: Option<String>,
    additional: Option<String>,
    hooks: Vec<&'a crate::manifest::CustomHook>,
}

/// The generated wrapper this harness writes around an agent's own prose:
/// everything before it, and everything after. Asked of the renderer with
/// a stand-in body rather than assembled from a list of headings here, so
/// a renderer that grows a section cannot leave this reader behind.
fn wrapper(
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
    let text = render(scope, &source, harness, around)?;
    let (_, body) = crate::frontmatter::split(&text).ok()?;
    let (before, after) = body.split_once(STAND_IN)?;
    Some((before.to_owned(), after.to_owned()))
}

/// The skills a forked agent will actually render with: its assignment,
/// filtered to what the local source offers. The next apply runs that
/// same filter, so a catalog skill drops out of the rendering and the
/// capture must not take its instructions away on the strength of a
/// section that is not coming back (KEN-777).
fn local_skills(env: &crate::env::Env, scope: &Scope, assigned: &[String]) -> Result<Vec<String>> {
    let root = crate::source::local_source_root(env, scope);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let sealed = crate::source_read::SealedSource::open(&root)?;
    let config = crate::source::source_config_for(&sealed, crate::manifest::LOCAL_SOURCE_NAME)?;
    let offered = crate::source::list_items(&sealed, &config, ItemKind::Skill);
    Ok(assigned
        .iter()
        .filter(|skill| offered.contains(skill))
        .cloned()
        .collect())
}

/// One rendering of this agent for this harness, or `None` where the
/// harness refuses its permission intent. A refusal installs nothing at
/// all, so there is no wider artifact to compare against and no wrapper to
/// read a body out of.
fn render(
    scope: &Scope,
    source: &SourceAgent,
    harness: HarnessId,
    around: &Around,
) -> Option<String> {
    let permissions = PermissionIntent::effective(
        &source.permissions,
        around.overrides.allow_tools.as_deref(),
        around.overrides.deny_tools.as_deref(),
    );
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
