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
//! What no override can state is not carried and not refused either:
//! [`uncarried`] names it, and the caller says so on the plan.

use crate::manifest::FrontmatterOverrides;
use crate::model::HarnessId;
use crate::render::permission::{Access, normalize};

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
    /// Every gate the file's own hook block sets. Claude gates tool use on
    /// these from inside the agent file, and no override table holds one,
    /// so a gate stated here and not in the fork's rendering is named
    /// rather than carried.
    hooks: Vec<Gate>,
    color: Option<String>,
    effort: Option<String>,
    model: Option<String>,
    isolation: Option<String>,
    memory: Option<String>,
    background: Option<bool>,
}

/// What the file states, or why it could not be read. The one reading
/// that is no failure is a file opening no frontmatter block at all: it
/// states nothing, and a person who replaced the whole rendering with
/// prose stated no settings to carry. A block that opens and never ends is
/// the other answer [`crate::frontmatter::split`] reports the same error
/// for, and it is frontmatter that will not read — whatever it states
/// cannot be carried, so the caller names it instead.
pub(super) fn stated(harness: HarnessId, text: &str) -> std::result::Result<Stated, String> {
    let (allow_key, deny_key) = permission_keys(harness);
    let yaml = match crate::frontmatter::split(text) {
        Ok((yaml, _)) => yaml,
        Err(problem) => match crate::frontmatter::opens(text) {
            true => return Err(problem),
            false => return Ok(Stated::default()),
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
    Ok(Stated {
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
        hooks: match parsed.map.get("hooks") {
            Some(block) => gates(block),
            None => Vec::new(),
        },
        color: scalar("color"),
        effort: scalar("effort"),
        model: scalar("model"),
        isolation: scalar("isolation"),
        memory: scalar("memory"),
        background: scalar("background").and_then(|value| value.parse().ok()),
    })
}

/// One gate a hook block sets: the scope it applies to and the command it
/// runs there. All three parts identify it. A matcher widened from `Bash`
/// to `*`, or an event moved from `PostToolUse` to `PreToolUse`, is a
/// different gate under the same command, and reading only the command
/// calls the two the same.
#[derive(PartialEq)]
struct Gate {
    event: String,
    matcher: String,
    command: String,
}

impl Gate {
    /// How the plan names it.
    fn shown(&self) -> String {
        format!(
            "{} on {} running {}",
            self.event, self.matcher, self.command
        )
    }
}

/// The gates a hook block sets, read as the block's own shape: an event,
/// the matchers under it, and the commands under each.
fn gates(value: &crate::frontmatter::Value) -> Vec<Gate> {
    use crate::frontmatter::Value;
    let Value::Map(events) = value else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (event, by_matcher) in events.entries() {
        let Value::Map(matchers) = by_matcher else {
            continue;
        };
        for (matcher, entries) in matchers.entries() {
            out.extend(commands(entries).into_iter().map(|command| Gate {
                event: event.to_owned(),
                matcher: matcher.to_owned(),
                command,
            }));
        }
    }
    out
}

/// Every `command:` under one matcher, at whatever depth the entries nest
/// them. Read by key rather than by shape: what matters is which commands
/// would run, not how the harness spells the list.
fn commands(value: &crate::frontmatter::Value) -> Vec<String> {
    use crate::frontmatter::Value;
    match value {
        Value::Map(map) => map
            .entries()
            .flat_map(|(key, value)| match (key, value.as_str()) {
                ("command", Some(command)) => vec![command.trim().to_owned()],
                _ => commands(value),
            })
            .collect(),
        Value::List(items) => items.iter().flat_map(commands).collect(),
        _ => Vec::new(),
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
        effort: match (&on_disk.effort, &after.effort) {
            (None, Some(_)) => Some(NO_EFFORT.to_owned()),
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
        // at all, so a deleted key rides as one.
        allowed_subagents: match (&on_disk.subagents, &after.subagents) {
            (None, Some(_)) => Some(Vec::new()),
            (Some(stated), rendered) => (Some(stated) != rendered.as_ref()).then(|| stated.clone()),
            (None, None) => None,
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
        .filter(|tool| {
            !rendered
                .iter()
                .any(|kept| normalize(kept) == normalize(tool))
        })
        .cloned()
        .collect();
    (!extra.is_empty()).then_some(extra)
}

/// What the person's file states that no override can hold, named so the
/// plan says what the fork will not reproduce. A deletion is the
/// restrictive direction of the very edit a fork exists to keep, and a
/// hook is a `[[custom-hooks]]` entry with a selector rather than a field,
/// so neither has a spelling in the override table.
pub(super) fn uncarried(on_disk: &Stated, after: &Stated, harness: HarnessId) -> Vec<String> {
    let harness = harness.display_name();
    let mut lost: Vec<String> = on_disk
        .hooks
        .iter()
        .filter(|gate| !after.hooks.contains(gate))
        .map(|gate| format!("the {harness} gate it sets on tool use, {}", gate.shown()))
        .collect();
    // An allowlist the person deleted from a rendering that stated one.
    // The fork writes the publisher's back, and no override says "none".
    if on_disk.rendering && on_disk.access.allow.is_none() && after.access.allow.is_some() {
        lost.push(format!(
            "the tool allowlist deleted from its {harness} file"
        ));
    }
    // Nothing was deleted from a file the person wrote themselves: there
    // was never a rendered value in it to remove.
    if !on_disk.rendering {
        return lost;
    }
    let deleted =
        |stated: &Option<String>, rendered: &Option<String>| stated.is_none() && rendered.is_some();
    for (key, gone) in [
        ("color", deleted(&on_disk.color, &after.color)),
        ("model", deleted(&on_disk.model, &after.model)),
        ("isolation", deleted(&on_disk.isolation, &after.isolation)),
        ("memory", deleted(&on_disk.memory, &after.memory)),
        (
            "background",
            on_disk.background.is_none() && after.background.is_some(),
        ),
    ] {
        if gone {
            lost.push(format!("the `{key}:` deleted from its {harness} file"));
        }
    }
    lost
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
