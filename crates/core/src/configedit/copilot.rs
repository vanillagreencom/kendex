//! Copilot's own hook-file shape: a `{version, disableAllHooks, hooks}`
//! document whose entries carry their command, matcher and timeout
//! themselves rather than nesting handlers under a matcher group
//! ([hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference),
//! accessed 2026-08-13).

use serde_json::{Map, Value, json};

use super::ensure_object;

/// The schema version Copilot's hook loader expects a file to declare.
const COPILOT_HOOK_VERSION: u64 = 1;

/// Copilot's own hook shape: a flat list of entries per event, each with its
/// command, its matcher and its timeout in seconds.
pub(super) fn upsert_copilot_hook(
    root: &mut Map<String, Value>,
    event: &str,
    matcher: Option<&str>,
    command: &str,
    timeout: Option<u32>,
) -> Result<(), String> {
    root.insert("version".into(), json!(COPILOT_HOOK_VERSION));
    let entries = ensure_object(root, "hooks")?
        .entry(event)
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or("hook event is not an array")?;
    let mut entry = json!({"type": "command", "bash": command});
    if let Some(matcher) = matcher {
        entry["matcher"] = json!(matcher);
    }
    if let Some(timeout) = timeout {
        entry["timeoutSec"] = json!(timeout);
    }
    // Refreshed where it already stands, so a re-apply moves nothing.
    let ours = |candidate: &Value| candidate.get("bash").and_then(Value::as_str) == Some(command);
    let first = entries.iter().position(ours);
    let mut kept = false;
    entries.retain(|candidate| !ours(candidate) || !std::mem::replace(&mut kept, true));
    match first {
        Some(index) => entries[index] = entry,
        None => entries.push(entry),
    }
    Ok(())
}

/// Takes our entry back out, from every event when none is named. A file
/// left holding no hooks at all keeps its version line: it is still a hook
/// file, and Copilot's loader wants one.
pub(super) fn remove_copilot_hook(
    root: &mut Map<String, Value>,
    event: Option<&str>,
    matcher: Option<&str>,
    command: &str,
) {
    // A matcher names one entry; without one the command goes wherever it
    // is registered, which is what removing the whole installation means.
    let named = |entry: &Value| {
        matcher.is_none_or(|matcher| {
            entry
                .get("matcher")
                .and_then(Value::as_str)
                .filter(|entry| !entry.is_empty())
                .unwrap_or(crate::scan::hooks::ANY_MATCHER)
                == matcher
        })
    };
    let Some(events) = root.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };
    let names: Vec<String> = match event {
        Some(event) => vec![event.to_owned()],
        None => events.keys().cloned().collect(),
    };
    for name in names {
        if let Some(entries) = events.get_mut(&name).and_then(Value::as_array_mut) {
            entries.retain(|entry| {
                !named(entry) || entry.get("bash").and_then(Value::as_str) != Some(command)
            });
            if entries.is_empty() {
                events.shift_remove(&name);
            }
        }
    }
    if events.is_empty() {
        root.shift_remove("hooks");
    }
}

#[cfg(test)]
mod tests {
    use crate::configedit::ConfigEdit;

    fn upsert() -> ConfigEdit {
        ConfigEdit::UpsertCopilotHook {
            event: "preToolUse".to_owned(),
            matcher: Some("shell".to_owned()),
            command: "bash /h/.copilot/hooks/audit.sh".to_owned(),
            timeout: Some(10),
        }
    }

    /// Applying twice changes nothing the second time — that equality is how
    /// the plan tells a registered hook from one still to register.
    #[test]
    fn a_hook_lands_in_copilots_shape_and_re_applying_it_is_a_no_op() {
        let once = upsert().apply("").unwrap();
        let value: serde_json::Value = serde_json::from_str(&once).unwrap();
        assert_eq!(value["version"], 1);
        let entry = &value["hooks"]["preToolUse"][0];
        assert_eq!(entry["type"], "command");
        assert_eq!(entry["bash"], "bash /h/.copilot/hooks/audit.sh");
        assert_eq!(entry["matcher"], "shell");
        assert_eq!(entry["timeoutSec"], 10);
        assert_eq!(upsert().apply(&once).unwrap(), once);
    }

    /// Someone else's hook in the same file is not ours to touch, and a file
    /// we empty stays a hook file.
    #[test]
    fn removing_ours_leaves_every_other_entry_where_it_was() {
        let existing = r#"{"version": 1, "disableAllHooks": false, "hooks": {
            "preToolUse": [{"type": "command", "bash": "./theirs.sh"}],
            "sessionEnd": [{"type": "prompt", "prompt": "wrap up"}]
        }}"#;
        let registered = upsert().apply(existing).unwrap();
        let removed = ConfigEdit::RemoveCopilotHook {
            event: None,
            matcher: None,
            command: "bash /h/.copilot/hooks/audit.sh".to_owned(),
        }
        .apply(&registered)
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&removed).unwrap();
        assert_eq!(value["hooks"]["preToolUse"][0]["bash"], "./theirs.sh");
        assert_eq!(value["hooks"]["preToolUse"].as_array().unwrap().len(), 1);
        assert_eq!(value["hooks"]["sessionEnd"][0]["prompt"], "wrap up");
        assert_eq!(value["disableAllHooks"], false);
        assert_eq!(value["version"], 1);
    }

    #[test]
    fn the_last_hook_out_leaves_no_empty_event_behind() {
        let registered = upsert().apply("").unwrap();
        let removed = ConfigEdit::RemoveCopilotHook {
            event: Some("preToolUse".to_owned()),
            matcher: None,
            command: "bash /h/.copilot/hooks/audit.sh".to_owned(),
        }
        .apply(&registered)
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&removed).unwrap();
        assert!(value.get("hooks").is_none());
        assert_eq!(value["version"], 1);
    }
}
