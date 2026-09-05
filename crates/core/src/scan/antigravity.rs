use std::path::Path;

use serde_json::Value;

use super::RawEntry;
use super::hooks::{Registration, registrations_in};
use super::readers::read_json;

/// `{"<hook-name>": {enabled?, "<Event>": [group | handler]}}` — Antigravity's
/// `hooks.json`, one named hook per top-level key. `PreToolUse` and
/// `PostToolUse` nest handlers under a matcher group the way claude's
/// settings do; the other events hold handlers directly (the CLI's embedded
/// hooks guide, <https://antigravity.google/docs/hooks>). A name switched off
/// by `enabled: false` is read with every handler off — a hook that will not
/// run must not read as one that will.
pub fn read(path: &Path) -> Result<Vec<RawEntry>, String> {
    let value = read_json(path)?;
    let Some(named) = value.as_object() else {
        return Ok(Vec::new());
    };
    let mut entries = Vec::new();
    for (_, hook) in named {
        let Some(hook) = hook.as_object() else {
            continue;
        };
        let enabled = hook.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        for registration in registrations_in(hook) {
            entries.push(RawEntry {
                name: registration.name(),
                enabled: Some(enabled),
                description: Some(registration.command),
                source_path: None,
            });
        }
    }
    Ok(entries)
}

/// Every registration in one document, in its parts — the structured view
/// of the same reading, for anything asking which entry is which.
pub(crate) fn registrations_text(text: &str) -> Result<Vec<Registration>, String> {
    let value: Value =
        serde_json::from_str(&super::jsonc::to_json(text)).map_err(|e| e.to_string())?;
    let Some(named) = value.as_object() else {
        return Ok(Vec::new());
    };
    Ok(named
        .values()
        .filter_map(Value::as_object)
        .flat_map(registrations_in)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grouped_and_flat_events_read_under_their_hook_name() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("hooks.json");
        std::fs::write(
            &path,
            r#"{
              "lint": {"PostToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "./scripts/lint.sh", "timeout": 10}]}]},
              "gate": {"enabled": false, "PreToolUse": [{"matcher": "run_command", "hooks": [{"command": "./scripts/safety-check.sh"}]}]},
              "wrap": {"Stop": [{"type": "command", "command": "./scripts/wrap.sh"}]}
            }"#,
        )
        .unwrap();
        let entries = read(&path).unwrap();
        let rows: Vec<_> = entries
            .iter()
            .map(|e| (e.name.as_str(), e.enabled))
            .collect();
        assert_eq!(
            rows,
            [
                ("PostToolUse:run_command:lint", Some(true)),
                ("PreToolUse:run_command:safety-check", Some(false)),
                ("Stop:*:wrap", Some(true)),
            ]
        );
    }

    #[test]
    fn a_document_that_is_not_a_map_of_hooks_holds_none() {
        assert_eq!(registrations_text("[]").unwrap(), []);
        assert_eq!(registrations_text(r#"{"lint": 3}"#).unwrap(), []);
    }
}
