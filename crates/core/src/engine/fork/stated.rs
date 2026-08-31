//! What one rendered agent file states about itself, and what a fork can
//! carry of it.
//!
//! A person tightening a generated file states the edit in the harness's
//! own keys — `disallowedTools:`, `deny-tools:`, `tools:`,
//! `allowed-subagents:`, and the scalars beside them. The source form has
//! no spelling for any of those, so a capture that took the publisher's
//! frontmatter and nothing else would hand every one of them back. The
//! `[agent-frontmatter.<harness>]` table is where they live once the fork
//! stops rendering from the catalog, and [`carried_edits`] is what puts
//! them there.
//!
//! Both sides are read by the same reader: the file on disk, and the
//! rendering the fork would write in its place. Reading them the same way
//! is what keeps each harness's own rules — Claude's fleet denies, Pi's
//! delegation set — counting on both sides rather than reading as an edit
//! the person never made.
//!
//! One rule decides the rest. [`unreproduced`] renders the agent again
//! with the carry folded in and asks which keys the file on disk still
//! spells differently. Every key in that answer is one no override could
//! reproduce, and the fork refuses naming them. Nothing is dropped, and
//! no hand-kept list decides which keys are even looked at — a key a
//! renderer grows, or one this module has never heard of, lands in the
//! difference like any other.

use crate::manifest::FrontmatterOverrides;
use crate::model::HarnessId;
use crate::render::permission::{Access, same_tool};

/// The one value an override can state that means "no effort at all": the
/// renderers filter it out rather than writing it, which is what makes a
/// deleted effort key the single clearing this table can carry.
const NO_EFFORT: &str = "none";

/// What one rendered agent file states in the keys a fork has to answer
/// for: its tool access, and the settings a fork can hand back as an
/// override. `allow` is `None` where the file names no allowlist, which
/// every harness reads as its own default rather than as nothing allowed.
#[derive(Default)]
pub(super) struct Stated {
    /// Whether this file is still the harness's own rendering rather than
    /// a document the person wrote over the top of it.
    rendering: bool,
    /// The tool policy the file states, read into the type a derived
    /// policy uses, so one comparison answers both.
    access: Access,
    /// Pi's delegation list: which child agents this one may invoke. An
    /// allowlist like `tools`, in a key only Pi writes.
    subagents: Option<Vec<String>>,
    color: Option<String>,
    effort: Option<String>,
    model: Option<String>,
    isolation: Option<String>,
    memory: Option<String>,
    background: Option<bool>,
}

/// What the file states, in three answers this type keeps apart. `Some`
/// is a frontmatter block that reads. `None` is a file opening no block at
/// all: it states nothing, and a person who replaced the whole rendering
/// with prose took no setting away. `Err` is the third — a block that
/// opens and never ends, the other reading [`crate::frontmatter::split`]
/// reports the same error for. What it states cannot be read, so it cannot
/// be shown carried either, and the caller refuses rather than reading an
/// absent value as a deliberate clearing.
pub(super) fn stated(
    harness: HarnessId,
    text: &str,
) -> std::result::Result<Option<Stated>, String> {
    let (allow_key, deny_key) = permission_keys(harness);
    let yaml = match crate::frontmatter::split(text) {
        Ok((yaml, _)) => yaml,
        Err(problem) => match crate::frontmatter::opens(text) {
            true => return Err(problem),
            false => return Ok(None),
        },
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
    Ok(Some(Stated {
        rendering: is_rendering(harness, &parsed.map),
        access: Access {
            allow: allow_key.and_then(|key| parsed.map.string_list(key)),
            deny: deny_key
                .and_then(|key| parsed.map.string_list(key))
                .unwrap_or_default(),
        },
        subagents: (harness == HarnessId::Pi)
            .then(|| parsed.map.string_list("allowed-subagents"))
            .flatten(),
        color: scalar("color"),
        effort: scalar("effort"),
        model: scalar("model"),
        isolation: scalar("isolation"),
        memory: scalar("memory"),
        background: scalar("background").and_then(|value| value.parse().ok()),
    }))
}

/// Whether the file this states is the harness's own rendering rather than
/// a document the person wrote over the top of it. Only a rendering has
/// keys the fork has to reproduce: in one somebody authored, there was
/// never a rendered value to change or take away.
impl Stated {
    pub(super) fn is_rendering(&self) -> bool {
        self.rendering
    }
}

/// Whether this file is still the harness's own rendering. A rendering
/// states keys only its renderer writes, and every one of them is written
/// on every render, so their absence together means the person replaced
/// the document rather than edited it. That distinction is what makes a
/// missing key readable as a deletion: in a rendering there was something
/// there to delete, and in a document somebody wrote there never was.
fn is_rendering(harness: HarnessId, map: &crate::frontmatter::Map) -> bool {
    let marks: &[&str] = match harness {
        HarnessId::Claude => &["disallowedTools", "background"],
        HarnessId::Gemini => &["kind"],
        HarnessId::Pi => &["deny-tools"],
        HarnessId::Codex | HarnessId::Copilot | HarnessId::Cursor | HarnessId::Opencode => &[],
    };
    marks.iter().any(|key| map.get(key).is_some())
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

/// The person's own edits to this file, as overrides for this harness. A
/// value the fork already renders is not an edit and gets no entry: an
/// override written on every fork would bury the ones that mean something.
pub(super) fn carried_edits(on_disk: &Stated, after: &Stated) -> FrontmatterOverrides {
    let kept = |stated: &Option<String>, rendered: &Option<String>| {
        stated.clone().filter(|_| stated != rendered)
    };
    FrontmatterOverrides {
        color: kept(&on_disk.color, &after.color),
        // Deleting the key is an edit like changing it. An override says
        // what a value is and never that there is none, so this is the one
        // deletion it can state: every renderer reads `none` as no effort.
        //
        // Only in a rendering, where there was a value to delete. In a
        // document somebody wrote there never was one, and reading its
        // absence as a clearing writes an override the person never asked
        // for and strips the effort the publisher set.
        effort: match (&on_disk.effort, &after.effort) {
            (None, Some(_)) if on_disk.rendering => Some(NO_EFFORT.to_owned()),
            (stated, rendered) => kept(stated, rendered),
        },
        model: kept(&on_disk.model, &after.model),
        isolation: kept(&on_disk.isolation, &after.isolation),
        memory: kept(&on_disk.memory, &after.memory),
        background: on_disk
            .background
            .filter(|_| on_disk.background != after.background),
        // Every tool the file denies that the fork's own rendering does
        // not. The difference rather than the whole list, because
        // `deny-tools` is unioned into what the renderer computes: writing
        // the generated denies back as overrides would state as the
        // person's what the renderer produces on its own.
        deny_tools: added(&on_disk.access.deny, &after.access.deny),
        // An allowlist replaces the source's outright, so the file's own
        // list reproduces the file. Only the file naming one is an edit:
        // an override states what the allowlist is and never that there is
        // none, so a deleted one is named by `uncarried` instead.
        allow_tools: match (&on_disk.access.allow, &after.access.allow) {
            (Some(stated), rendered) => (Some(stated) != rendered.as_ref()).then(|| stated.clone()),
            (None, _) => None,
        },
        // Narrowing the delegation list is the same edit as narrowing the
        // tool list, and unlike a scalar its clearing is representable:
        // an empty allowlist is what the renderer reads as no delegation
        // at all, so a deleted key rides as one — again only where there
        // was a rendered list to delete.
        allowed_subagents: match (&on_disk.subagents, &after.subagents) {
            (None, Some(_)) if on_disk.rendering => Some(Vec::new()),
            (Some(stated), rendered) => (Some(stated) != rendered.as_ref()).then(|| stated.clone()),
            (None, _) => None,
        },
        ..FrontmatterOverrides::default()
    }
}

/// The tools `stated` names that `rendered` does not, under either side's
/// spelling. `None` where it names none, which is what leaves the override
/// unwritten.
fn added(stated: &[String], rendered: &[String]) -> Option<Vec<String>> {
    let extra: Vec<String> = stated
        .iter()
        .filter(|tool| !rendered.iter().any(|kept| same_tool(kept, tool)))
        .cloned()
        .collect();
    (!extra.is_empty()).then_some(extra)
}

/// Every key the person changed in the generated file that the carry does
/// not reproduce.
///
/// Three renderings answer it, all read as whole frontmatter maps so that
/// nothing here decides which keys are worth looking at. `rendered` is
/// what the fork writes carrying nothing, so what `on_disk` spells
/// differently from it is exactly what the person changed. `reproduced` is
/// the same rendering with the carry folded in, so a key they changed that
/// still does not read back as their own is one no override could hold.
///
/// A key they did not change is not asked about, because the copy may
/// differ there for a reason they asked for: clearing Pi's delegation list
/// puts `delegate_subagent` back in the deny list, which is the edit
/// landing rather than a second edit going missing.
///
/// A key no override has a field for — `description:`, a hook block, one
/// a renderer grows tomorrow — reaches the answer without this being
/// taught about it, which is the whole point of asking the renderings.
pub(super) fn unreproduced(
    on_disk: &str,
    rendered: &str,
    reproduced: &str,
) -> std::result::Result<Vec<String>, String> {
    let map = |text: &str| -> std::result::Result<crate::frontmatter::Map, String> {
        let (yaml, _) = crate::frontmatter::split(text)?;
        Ok(crate::frontmatter::parse_tolerant(yaml)?.map)
    };
    let (mine, bare, mended) = (map(on_disk)?, map(rendered)?, map(reproduced)?);
    let mut keys: Vec<String> = differing(&mine, &bare)
        .into_iter()
        .filter(|key| !alike(mine.get(key), mended.get(key)))
        .collect();
    keys.sort();
    keys.dedup();
    Ok(keys)
}

/// Every key the two maps spell differently, in either direction. A key
/// one states and the other does not is a difference like any other: an
/// added key and a deleted one are both edits.
fn differing(mine: &crate::frontmatter::Map, theirs: &crate::frontmatter::Map) -> Vec<String> {
    let mut keys: Vec<String> = mine
        .entries()
        .filter(|(key, value)| !alike(Some(value), theirs.get(key)))
        .map(|(key, _)| key.to_owned())
        .collect();
    keys.extend(
        theirs
            .entries()
            .filter(|(key, _)| mine.get(key).is_none())
            .map(|(key, _)| key.to_owned()),
    );
    keys
}

/// Whether two readings of one key state the same thing, absence included.
/// A renderer writes a list as one comma-separated scalar and a person
/// editing it by hand spaces and orders it their own way, so a scalar is
/// compared as the set of what it names rather than as its text. A value
/// holding no comma names one thing, which makes this the plain comparison
/// for every other key.
fn alike(a: Option<&crate::frontmatter::Value>, b: Option<&crate::frontmatter::Value>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => match (a.as_str(), b.as_str()) {
            (Some(a), Some(b)) => named(a) == named(b),
            _ => a == b,
        },
        (None, None) => true,
        _ => false,
    }
}

fn named(value: &str) -> Vec<&str> {
    let mut names: Vec<&str> = value.split(',').map(str::trim).collect();
    names.sort_unstable();
    names
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
