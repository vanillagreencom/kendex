//! What a rendered agent file says about itself, and what a fork would
//! change about it. Every harness writes tool access and the agent's
//! settings in its own keys, so both the file on disk and the file the
//! fork would render are read here, by one reader, and compared. Reading
//! them the same way is what makes each harness's own rules — Claude's
//! fleet denies, Pi's delegation set — count on both sides rather than
//! read as a difference.

use crate::manifest::FrontmatterOverrides;
use crate::model::HarnessId;
use crate::render::permission::normalize;

/// The one value an override can state that means "no effort at all": the
/// renderers filter it out rather than writing it, which is what makes a
/// deleted effort key the single clearing this table can carry.
const NO_EFFORT: &str = "none";

/// What the fork would give the agent back that the rendering on disk
/// keeps from it, said in the words the refusal prints. `None` is the
/// answer that lets the fork run.
///
/// Both sides are read out of a rendered file by the same reader: the
/// fork's side is generated here from what it will actually hold, so the
/// harness's own deny rules — Claude's fleet denies, Pi's delegation set —
/// count on both sides and never read as a difference.
pub(super) fn dropped(on_disk: &Stated, after: &Stated, harness: HarnessId) -> Option<String> {
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
    // A hook the person put in the file gates tool use from inside it, and
    // no override table holds one — a hook is a `[[custom-hooks]]` entry
    // with a selector, not a field. One the fork would not run again is a
    // restriction it cannot carry.
    let ungated: Vec<String> = on_disk
        .hooks
        .iter()
        .filter(|gate| !after.hooks.contains(gate))
        .map(Gate::shown)
        .collect();
    if !ungated.is_empty() {
        return Some(format!(
            "the {} gate{} its {} file sets on tool use: {}",
            ungated.len(),
            if ungated.len() == 1 { "" } else { "s" },
            harness.display_name(),
            ungated.join(", ")
        ));
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

/// What one rendered agent file states in the keys a fork has to answer
/// for: its tool access, and the settings a fork can hand back as an
/// override. `allow` is `None` where the file names no allowlist, which
/// every harness reads as its own default rather than as nothing allowed.
#[derive(Default)]
pub(super) struct Stated {
    /// Whether this file is still the harness's own rendering rather than
    /// a document the person wrote over the top of it.
    rendering: bool,
    allow: Option<Vec<String>>,
    deny: Vec<String>,
    /// Pi's delegation list: which child agents this one may invoke. An
    /// allowlist like `tools`, in a key only Pi writes.
    subagents: Option<Vec<String>>,
    /// Every gate the file's own hook block sets. Claude gates tool use on
    /// these from inside the agent file, so one stated here and not in the
    /// fork's rendering is a gate the fork drops.
    hooks: Vec<Gate>,
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
pub(super) fn stated(harness: HarnessId, text: &str) -> std::result::Result<Stated, String> {
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
        rendering: is_rendering(harness, &parsed.map),
        allow: allow_key.and_then(|key| parsed.map.string_list(key)),
        deny: deny_key
            .and_then(|key| parsed.map.string_list(key))
            .unwrap_or_default(),
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
/// calls the two the same and lets the stricter one be discarded.
#[derive(PartialEq)]
struct Gate {
    event: String,
    matcher: String,
    command: String,
}

impl Gate {
    /// How the refusal names it.
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

/// The person's own edits to those settings, as overrides for this
/// harness. A value the fork already renders is not an edit and gets no
/// entry: an override written on every fork would bury the ones that mean
/// something.
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

/// The settings the person deleted from the generated file that no
/// override can state as deleted, so the fork would put the publisher's
/// value back. Naming them is a refusal, the same as a tool restriction
/// the fork cannot carry: a deletion is the restrictive direction of the
/// very edit a fork exists to keep.
pub(super) fn uncleared(on_disk: &Stated, after: &Stated) -> Vec<&'static str> {
    // Nothing was deleted from a file the person wrote themselves: there
    // was never a rendered value in it to remove.
    if !on_disk.rendering {
        return Vec::new();
    }
    let deleted =
        |stated: &Option<String>, rendered: &Option<String>| stated.is_none() && rendered.is_some();
    let mut lost = Vec::new();
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
            lost.push(key);
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
