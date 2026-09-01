//! Compare the access and settings stated by an installed agent with its fork.

use crate::manifest::FrontmatterOverrides;
use crate::model::HarnessId;
use crate::render::permission::{Access, Widened};

const NO_EFFORT: &str = "none";

/// Describe access the fork would give back, or `None` when it widens nothing.
pub(super) fn dropped(on_disk: &Stated, after: &Stated, harness: HarnessId) -> Option<String> {
    let given_back = match after.access.widened_over(&on_disk.access) {
        Widened::PastAnAllowlist(kept) => {
            return Some(format!(
                "the tool allowlist its {} file states: {}",
                harness.display_name(),
                kept.join(", ")
            ));
        }
        Widened::Tools(tools) => tools,
        Widened::No => Vec::new(),
    };
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

/// Access restrictions and settings read from one rendered agent.
#[derive(Default)]
pub(super) struct Stated {
    rendering: bool,
    access: Access,
    subagents: Option<Vec<String>>,
    hooks: Vec<Gate>,
    color: Option<String>,
    effort: Option<String>,
    model: Option<String>,
    isolation: Option<String>,
    memory: Option<String>,
    background: Option<bool>,
}

/// Read a rendered file. Plain prose states no restrictions; broken frontmatter fails.
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

#[derive(PartialEq)]
struct Gate {
    event: String,
    matcher: String,
    command: String,
}

impl Gate {
    fn shown(&self) -> String {
        format!(
            "{} on {} running {}",
            self.event, self.matcher, self.command
        )
    }
}

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

fn is_rendering(harness: HarnessId, map: &crate::frontmatter::Map) -> bool {
    let marks: &[&str] = match harness {
        HarnessId::Claude => &["disallowedTools", "background"],
        HarnessId::Gemini => &["kind"],
        HarnessId::Pi => &["deny-tools"],
        HarnessId::Codex | HarnessId::Copilot | HarnessId::Cursor | HarnessId::Opencode => &[],
    };
    marks.iter().any(|key| map.get(key).is_some())
}

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

/// Settings changed in the installed rendering, expressed as overrides.
pub(super) fn carried_edits(on_disk: &Stated, after: &Stated) -> FrontmatterOverrides {
    let kept = |stated: &Option<String>, rendered: &Option<String>| {
        stated.clone().filter(|_| stated != rendered)
    };
    FrontmatterOverrides {
        color: kept(&on_disk.color, &after.color),
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
        allowed_subagents: match (&on_disk.subagents, &after.subagents) {
            (None, Some(_)) => Some(Vec::new()),
            (Some(stated), rendered) => (Some(stated) != rendered.as_ref()).then(|| stated.clone()),
            (None, None) => None,
        },
        ..FrontmatterOverrides::default()
    }
}

/// Deleted settings no override can represent.
pub(super) fn uncleared(on_disk: &Stated, after: &Stated) -> Vec<&'static str> {
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
