//! Reading a registration back as a declaration.
//!
//! `[[custom-hooks]]` says: run this command, on this event, for this
//! matcher, with this timeout. An entry doing anything more than that would
//! come back a plain command hook and run differently after the next apply,
//! with nothing said — so it is refused here, naming what it carries; and
//! the units and event names each tool writes are translated rather than
//! stored as found.

use crate::engine::targets::HookFormat;
use crate::error::{CoreError, Result};
use crate::manifest::{CustomHook, HookAgents};
use crate::model::HarnessId;
use crate::scan::hooks::{ANY_MATCHER, Registration};

use super::Found;

/// The declaration these registrations become, or the refusal for an entry
/// carrying something a declaration cannot say. A hook adopted into a shape
/// that drops half of what it did would run differently after the next
/// apply, with nothing said — so it is refused, naming what it carries.
pub(super) fn declaration(name: &str, found: &[Found]) -> Result<CustomHook> {
    let first = &found[0];
    let unusable = |problem: String| CoreError::AdoptNameUnusable {
        name: crate::names::shown(name),
        problem,
    };
    if let Some(carried) = beyond_a_declaration(&first.registration, first.format) {
        return Err(unusable(format!(
            "its registration carries `{carried}`, which a kendex declaration cannot express"
        )));
    }
    let event = fleet_event(first.harness, &first.registration.event)
        .ok_or_else(|| {
            unusable(format!(
                "`{}` is not an event kendex declares hooks against",
                crate::names::shown(&first.registration.event)
            ))
        })?
        .to_owned();
    Ok(CustomHook {
        // Left to the deterministic derivation the manifest already uses
        // for a hand-written entry, so a plan over this file and the
        // editor's write-back agree on what it is called.
        name: None,
        event,
        matcher: match first.registration.matcher.as_str() {
            ANY_MATCHER => None,
            held => Some(held.to_owned()),
        },
        command: first.registration.command.clone(),
        description: Some(format!("adopted from {}", first.harness.display_name())),
        timeout: timeout_seconds(first),
        harnesses: Some(found.iter().map(|f| f.harness.name().to_owned()).collect()),
        enabled: true,
        agents: HookAgents::One("all".to_owned()),
    })
}

/// The fleet event a name read out of a tool's own registry answers to. Two
/// harnesses rename events on the way in; the rest write the vocabulary a
/// declaration is authored against, so the name comes back as it went.
fn fleet_event(harness: HarnessId, native: &str) -> Option<&'static str> {
    match harness {
        HarnessId::Gemini => crate::harness::gemini::fleet_event(native),
        HarnessId::Copilot => crate::harness::copilot::fleet_event(native),
        _ => crate::hook::EVENTS
            .iter()
            .map(|held| held.name)
            .find(|held| *held == native),
    }
}

/// The seconds a declaration would carry, read out of the entry in whatever
/// unit the registry keeps it: Gemini counts milliseconds, Copilot names its
/// field `timeoutSec`, everyone else writes seconds under `timeout`.
fn timeout_seconds(found: &Found) -> Option<u32> {
    let read = |key: &str| {
        found
            .registration
            .entry
            .get(key)
            .and_then(serde_json::Value::as_u64)
    };
    let seconds = match (found.format, found.harness) {
        (HookFormat::Copilot, _) => read("timeoutSec"),
        // Gemini's loader reads the same key in milliseconds. Nothing in the
        // entry says which unit it is, so it comes from the tool that wrote
        // it — the same table the render used on the way in.
        (HookFormat::Nested, HarnessId::Gemini) => read("timeout").map(|held| held / 1000),
        (HookFormat::Nested, _) => read("timeout"),
    };
    seconds
        .and_then(|value| u32::try_from(value).ok())
        .filter(|value| *value > 0)
}

/// What this entry does that a `[[custom-hooks]]` declaration has no field
/// for, or nothing where every key round-trips. An entry speaking HTTP,
/// naming an MCP tool, carrying an environment or running once would come
/// back as a plain command hook.
fn beyond_a_declaration(registration: &Registration, format: HookFormat) -> Option<String> {
    let known: &[&str] = match format {
        HookFormat::Copilot => &["type", "command", "matcher", "timeoutSec"],
        HookFormat::Nested => &["type", "command", "matcher", "timeout"],
    };
    let entry = registration.entry.as_object()?;
    if let Some(kind) = entry.get("type").and_then(serde_json::Value::as_str)
        && kind != "command"
    {
        return Some(kind.to_owned());
    }
    entry
        .keys()
        .find(|key| !known.contains(&key.as_str()))
        .cloned()
}
