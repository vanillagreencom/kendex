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
    EffectiveAgent, GENERATED_BANNER, SourceAgent, merge_overrides, parse_source_agent,
};
use crate::render::permission::{PermissionIntent, normalize};

use super::ForkOf;
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
    let published = sealed.read(&path)?;
    let carry = agent_carry(manifest, &sealed, &config, name, &published);

    let edited_text = std::fs::read_to_string(edited).map_err(|e| CoreError::io(edited, e))?;
    let bytes = source_form(&published, &edited_text, name)?;
    let captured = parse_source_agent(&String::from_utf8_lossy(&bytes))
        .map_err(|problem| unreadable(name, &decl.source, problem))?;
    // The overrides the fork will hold, not the ones the manifest holds
    // now: the catalog's defaults are on their way into it with the carry,
    // and a fork beside the original writes them under the new name. Asking
    // the manifest here would read them as already lost and refuse a fork
    // that carries them perfectly well.
    let overrides = merge_overrides(
        config
            .frontmatter
            .get(harness.name())
            .and_then(|by_agent| by_agent.get(name)),
        manifest
            .agent_frontmatter
            .get(harness.name())
            .and_then(|by_agent| by_agent.get(name)),
    );
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
    let Some(rendering) = rendered_as(scope, &captured, installed_as, harness, overrides) else {
        return Ok(CapturedAgent { bytes, carry });
    };
    let after = stated(harness, &rendering)
        .map_err(|problem| refused(format!("its own rendering reads back as {problem}")))?;
    if let Some(problem) = dropped(&on_disk, &after, harness) {
        return Err(refused(problem));
    }
    let carry = carry
        .unwrap_or_default()
        .over(harness.name(), carried_edits(&on_disk, &after));
    Ok(CapturedAgent {
        bytes,
        carry: (!carry.is_empty()).then_some(carry),
    })
}

fn unreadable(name: &str, source_name: &str, problem: String) -> CoreError {
    CoreError::ItemNotInSource {
        name: name.to_owned(),
        source_name: format!("{source_name} has no readable agent file for it — {problem}"),
    }
}

/// The catalog's frontmatter over the person's body. The body is taken
/// verbatim but for the generated banner: captured with it, the next
/// render would write a second banner above the first.
fn source_form(published: &[u8], edited: &str, name: &str) -> Result<Vec<u8>> {
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
    Ok(format!("---\n{frontmatter}---\n\n{}", without_banner(body)).into_bytes())
}

fn without_banner(body: &str) -> String {
    let mut out = String::new();
    for line in body.lines().filter(|line| line.trim() != GENERATED_BANNER) {
        out.push_str(line);
        out.push('\n');
    }
    format!("{}\n", out.trim())
}

/// What the fork would give the agent back that the rendering on disk
/// keeps from it, said in the words the refusal prints. `None` is the
/// answer that lets the fork run.
///
/// Both sides are read out of a rendered file by the same reader: the
/// fork's side is generated here from what it will actually hold, so the
/// harness's own deny rules — Claude's fleet denies, Pi's delegation set —
/// count on both sides and never read as a difference.
fn dropped(on_disk: &Stated, after: &Stated, harness: HarnessId) -> Option<String> {
    let mut given_back: Vec<String> = on_disk
        .deny
        .iter()
        .filter(|tool| grants(after, tool))
        .cloned()
        .collect();
    match (&on_disk.allow, &after.allow) {
        (Some(kept), Some(allowed)) => {
            for tool in allowed {
                if !holds(kept, tool) && !holds(&given_back, tool) {
                    given_back.push(tool.clone());
                }
            }
        }
        // The file states an allowlist and the fork would state none, so
        // what comes back is every tool the harness offers — a set no
        // reading of either file can name.
        (Some(kept), None) => {
            return Some(format!(
                "the tool allowlist its {} file states: {}",
                harness.display_name(),
                kept.join(", ")
            ));
        }
        _ => {}
    }
    (!given_back.is_empty()).then(|| {
        format!(
            "the {} tool{} its {} file keeps from it: {}",
            given_back.len(),
            if given_back.len() == 1 { "" } else { "s" },
            harness.display_name(),
            given_back.join(", ")
        )
    })
}

/// The file this fork would render for this harness, or `None` where the
/// harness refuses the agent's permission intent. A refusal installs
/// nothing at all, so there is no wider artifact to compare against and
/// nothing for this check to decide.
fn rendered_as(
    scope: &Scope,
    captured: &SourceAgent,
    installed_as: &str,
    harness: HarnessId,
    overrides: FrontmatterOverrides,
) -> Option<String> {
    let named = SourceAgent {
        name: installed_as.to_owned(),
        ..captured.clone()
    };
    let permissions = PermissionIntent::effective(
        &named.permissions,
        overrides.allow_tools.as_deref(),
        overrides.deny_tools.as_deref(),
    );
    let effective = EffectiveAgent {
        source: &named,
        harness,
        scope,
        skills: Vec::new(),
        overrides,
        permissions,
        launch_instructions: None,
        additional_instructions: None,
        custom_hooks: Vec::new(),
    };
    crate::render::agent::generate(&effective)
        .ok()
        .map(|rendered| rendered.text)
}

/// What one rendered agent file states in the keys a fork has to answer
/// for: its tool access, and the settings a fork can hand back as an
/// override. `allow` is `None` where the file names no allowlist, which
/// every harness reads as its own default rather than as nothing allowed.
#[derive(Default)]
struct Stated {
    allow: Option<Vec<String>>,
    deny: Vec<String>,
    color: Option<String>,
    effort: Option<String>,
    model: Option<String>,
    isolation: Option<String>,
    memory: Option<String>,
    background: Option<bool>,
}

/// What the file states, or why it could not be read. A file with no
/// frontmatter at all states nothing and is no failure: a person who
/// replaced the whole rendering with prose took no tools away.
fn stated(harness: HarnessId, text: &str) -> std::result::Result<Stated, String> {
    let (allow_key, deny_key) = permission_keys(harness);
    let Ok((yaml, _)) = crate::frontmatter::split(text) else {
        return Ok(Stated::default());
    };
    let parsed = crate::frontmatter::parse_tolerant(yaml)?;
    let scalar = |key: &str| {
        if !carries(harness, key) {
            return None;
        }
        parsed
            .map
            .get(key)
            .and_then(crate::frontmatter::Value::as_str)
            .map(|text| text.trim().to_owned())
    };
    Ok(Stated {
        allow: allow_key.and_then(|key| parsed.map.string_list(key)),
        deny: deny_key
            .and_then(|key| parsed.map.string_list(key))
            .unwrap_or_default(),
        color: scalar("color"),
        effort: scalar("effort"),
        model: scalar("model"),
        isolation: scalar("isolation"),
        memory: scalar("memory"),
        background: scalar("background").and_then(|value| value.parse().ok()),
    })
}

/// Whether this harness writes the setting in the person's own word, so
/// handing the same word back as an `[agent-frontmatter]` override renders
/// the same file again. Gemini writes neither colour nor effort. Pi writes
/// no effort key of its own — its renderer appends the effort to the model
/// as a suffix, so reading that model back would append a second one — and
/// its `pane` is absent rather than false, so a removal cannot be read.
fn carries(harness: HarnessId, key: &str) -> bool {
    matches!(
        (harness, key),
        (
            HarnessId::Claude,
            "color" | "effort" | "model" | "isolation" | "memory" | "background"
        ) | (HarnessId::Gemini, "model")
            | (HarnessId::Pi, "color")
    )
}

/// The person's own edits to those settings, as overrides for this
/// harness. A value the fork already renders is not an edit and gets no
/// entry: an override written on every fork would bury the ones that mean
/// something.
fn carried_edits(on_disk: &Stated, after: &Stated) -> FrontmatterOverrides {
    let kept = |stated: &Option<String>, rendered: &Option<String>| {
        stated.clone().filter(|_| stated != rendered)
    };
    FrontmatterOverrides {
        color: kept(&on_disk.color, &after.color),
        effort: kept(&on_disk.effort, &after.effort),
        model: kept(&on_disk.model, &after.model),
        isolation: kept(&on_disk.isolation, &after.isolation),
        memory: kept(&on_disk.memory, &after.memory),
        background: on_disk
            .background
            .filter(|_| on_disk.background != after.background),
        ..FrontmatterOverrides::default()
    }
}

/// The frontmatter keys a harness states tool access in: an allowlist, a
/// deny list, or both. The four that state neither are the four a fork
/// cannot capture from, turned away by `forkable_harness` before this.
fn permission_keys(harness: HarnessId) -> (Option<&'static str>, Option<&'static str>) {
    match harness {
        HarnessId::Claude => (Some("tools"), Some("disallowedTools")),
        HarnessId::Gemini => (Some("tools"), None),
        HarnessId::Pi => (None, Some("deny-tools")),
        HarnessId::Codex | HarnessId::Copilot | HarnessId::Cursor | HarnessId::Opencode => {
            (None, None)
        }
    }
}

/// Whether a rendering hands this tool to the agent: it neither denies it
/// nor keeps an allowlist that leaves it out.
fn grants(rendering: &Stated, tool: &str) -> bool {
    if holds(&rendering.deny, tool) {
        return false;
    }
    match &rendering.allow {
        Some(allow) => holds(allow, tool),
        None => true,
    }
}

fn holds(tools: &[String], tool: &str) -> bool {
    tools.iter().any(|kept| normalize(kept) == normalize(tool))
}
