//! The hook shape claude, codex, cursor and gemini share: handlers nested
//! under a matcher group, under an event.
//!
//! Copilot's own shape is next door; what both editors agree on — which
//! group or entry a matcher names — is in the module above, so neither
//! can decide it differently.

use serde_json::{Map, Value, json};

use super::{ensure_object, names, one};

pub(super) fn upsert_hook(
    root: &mut Map<String, Value>,
    event: &str,
    matcher: Option<&str>,
    command: &str,
    timeout: Option<u32>,
) -> Result<(), String> {
    upsert_in(
        ensure_object(root, "hooks")?,
        event,
        matcher,
        command,
        timeout,
    )
}

/// One handler as every nested registry spells it.
pub(super) fn handler(command: &str, timeout: Option<u32>) -> Value {
    let mut handler = json!({"type": "command", "command": command});
    if let Some(timeout) = timeout {
        handler["timeout"] = json!(timeout);
    }
    handler
}

/// The upsert against the map of event name to groups itself, for a
/// registry that keeps that map somewhere other than under `hooks`.
pub(super) fn upsert_in(
    events: &mut Map<String, Value>,
    event: &str,
    matcher: Option<&str>,
    command: &str,
    timeout: Option<u32>,
) -> Result<(), String> {
    let handler = handler(command, timeout);
    let ours = |h: &Value| h.get("command").and_then(Value::as_str) == Some(command);
    let groups = events
        .entry(event)
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or("hook event is not an array")?;
    // Refreshed where it already stands — the file is another tool's too,
    // and a handler that moves on every apply reads as drift there.
    //
    // Only the group this registration belongs to is rewritten. The same
    // command under a matcher somebody else chose is their registration,
    // not a copy of this one: what a previous pass of kendex's left
    // elsewhere is retired by the record that named it, and nothing else
    // in the file is claimed by carrying a command.
    let mut placed = false;
    for group in groups.iter_mut() {
        if !names(group, one(matcher)) {
            continue;
        }
        let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
            continue;
        };
        for h in handlers.iter_mut().filter(|h| ours(h)) {
            *h = match placed {
                false => handler.clone(),
                true => Value::Null,
            };
            placed = true;
        }
        handlers.retain(|h| !h.is_null());
    }
    if !placed {
        let group = groups
            .iter_mut()
            .find(|group| names(group, one(matcher)))
            .and_then(|group| group.get_mut("hooks"))
            .and_then(Value::as_array_mut);
        match group {
            Some(handlers) => handlers.push(handler),
            None => {
                let mut group = Map::new();
                if let Some(matcher) = matcher {
                    group.insert("matcher".into(), Value::String(matcher.to_owned()));
                }
                group.insert("hooks".into(), Value::Array(vec![handler]));
                groups.push(Value::Object(group));
            }
        }
    }
    groups.retain(|g| {
        g.get("hooks")
            .and_then(Value::as_array)
            .is_none_or(|handlers| !handlers.is_empty())
    });
    Ok(())
}

/// Takes our handler out, from every event when none is named.
pub(super) fn remove_hook(
    root: &mut Map<String, Value>,
    event: Option<&str>,
    matcher: Option<&str>,
    command: &str,
) {
    let Some(events) = root.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };
    let named: Vec<String> = match event {
        Some(event) => vec![event.to_owned()],
        None => events.keys().cloned().collect(),
    };
    for event in named {
        remove_in(events, &event, matcher, command);
    }
    if events.is_empty() {
        root.shift_remove("hooks");
    }
}

/// The removal against the map of event name to groups itself; an event
/// left holding no groups is pruned, the map is the caller's to prune.
pub(super) fn remove_in(
    events: &mut Map<String, Value>,
    event: &str,
    matcher: Option<&str>,
    command: &str,
) {
    if let Some(groups) = events.get_mut(event).and_then(Value::as_array_mut) {
        for group in groups.iter_mut() {
            // A matcher names one group. Without one every group in the
            // event gives the command up, which is what a removal of the
            // whole installation means.
            if !names(group, matcher) {
                continue;
            }
            if let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) {
                handlers.retain(|h| h.get("command").and_then(Value::as_str) != Some(command));
            }
        }
        groups.retain(|group| {
            group
                .get("hooks")
                .and_then(Value::as_array)
                .is_none_or(|handlers| !handlers.is_empty())
        });
        if groups.is_empty() {
            events.shift_remove(event);
        }
    }
}
