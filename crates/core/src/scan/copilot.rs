use std::path::Path;

use serde_json::Value;

use super::RawEntry;
use super::hooks::Registration;
use super::readers::read_json;

/// `{version, disableAllHooks, hooks: {<event>: [entry]}}` — a Copilot hook
/// file, or the `hooks` key of one of its settings files
/// ([hooks reference](https://docs.github.com/en/copilot/reference/hooks-reference),
/// Each entry carries its own command and matcher
/// rather than nesting handlers under a matcher group, which is why the
/// shape claude and gemini share cannot read it: every entry would come back
/// with no command and no name (matrix §7).
///
/// `disableAllHooks` switches every entry in the file off, and that is what
/// the scan reports — a hook that will not run must not read as one that
/// will.
pub fn read(path: &Path) -> Result<Vec<RawEntry>, super::ScanProblem> {
    let value = read_json(path)?;
    let Some(events) = value.get("hooks").and_then(Value::as_object) else {
        return Ok(Vec::new());
    };
    let enabled = !switched_off(&value);
    let mut entries = Vec::new();
    for (event, list) in events {
        let Some(list) = list.as_array() else {
            continue;
        };
        for entry in list {
            let Some(action) = action(entry) else {
                continue;
            };
            let matcher = crate::configedit::spelled(entry.get("matcher").and_then(Value::as_str));
            entries.push(RawEntry {
                name: super::hooks::registration_name(event, matcher, &action),
                enabled: Some(enabled),
                summary: None,
                action: Some(action),
                source_path: None,
            });
        }
    }
    Ok(entries)
}

/// Whether a hook document's own top-level `disableAllHooks` switches every
/// entry in it off.
fn switched_off(value: &Value) -> bool {
    value
        .get("disableAllHooks")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// Whether the hook document at `path` switches every entry in it off, read
/// as commented JSON as `registrations_text` reads one. A file that cannot be
/// read, is not there, or is no JSON once its comments are stripped is an
/// error naming it: the switch in it is then unknown, never off.
pub(crate) fn document_switched_off(path: &Path) -> crate::error::Result<bool> {
    let text = crate::fs::read_if_exists(path)?.ok_or_else(|| {
        crate::error::CoreError::io(path, std::io::Error::from(std::io::ErrorKind::NotFound))
    })?;
    let value: Value = serde_json::from_str(&super::jsonc::to_json(&text)).map_err(|e| {
        crate::error::CoreError::JsonParse {
            path: path.to_path_buf(),
            message: e.to_string(),
        }
    })?;
    Ok(switched_off(&value))
}

/// Every registration in one of these documents, in its parts — the
/// structured view of the same reading, for anything asking which entry
/// is which rather than what to display.
pub(crate) fn registrations_text(text: &str) -> Result<Vec<Registration>, String> {
    let value: Value =
        serde_json::from_str(&super::jsonc::to_json(text)).map_err(|e| e.to_string())?;
    let Some(events) = value.get("hooks").and_then(Value::as_object) else {
        return Ok(Vec::new());
    };
    let mut found = Vec::new();
    for (event, list) in events {
        let Some(list) = list.as_array() else {
            continue;
        };
        for entry in list {
            let Some(command) = action(entry) else {
                continue;
            };
            found.push(Registration {
                event: event.clone(),
                matcher: crate::configedit::spelled(entry.get("matcher").and_then(Value::as_str))
                    .to_owned(),
                command,
                entry: entry.clone(),
            });
        }
    }
    Ok(found)
}

/// What one entry does, in the words of whichever key it used. A `command`
/// entry names a shell for its command line, an `http` entry posts to a url,
/// and a `prompt` entry hands text to the model.
fn action(entry: &Value) -> Option<String> {
    for key in ["bash", "powershell", "command", "url", "prompt"] {
        if let Some(value) = entry.get(key).and_then(Value::as_str) {
            return Some(value.to_owned());
        }
    }
    None
}

/// `enabledPlugins` in a Copilot settings file — `{"<plugin>@<marketplace>":
/// bool}`, a clean boolean flip at either scope
/// ([CLI plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference),
/// matrix §2).
pub fn plugins(path: &Path) -> Result<Vec<RawEntry>, super::ScanProblem> {
    let value = read_json(path)?;
    let Some(plugins) = value.get("enabledPlugins").and_then(Value::as_object) else {
        return Ok(Vec::new());
    };
    Ok(plugins
        .iter()
        .map(|(key, enabled)| RawEntry {
            name: key.clone(),
            enabled: enabled.as_bool(),
            // The key already names the marketplace this plugin comes
            // from, and a plugin's own words are not in this file.
            summary: None,
            action: None,
            source_path: None,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_entry_type_is_named_by_what_it_runs() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("guard.json");
        std::fs::write(
            &path,
            r#"{"version": 1, "hooks": {
                "preToolUse": [
                  {"type": "command", "bash": "bash /h/.copilot/hooks/guard.sh", "matcher": "shell"},
                  {"type": "http", "url": "https://audit.example/hook"}
                ],
                "sessionStart": [{"type": "prompt", "prompt": "read the plan"}]
            }}"#,
        )
        .unwrap();
        let entries = read(&path).unwrap();
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "preToolUse:shell:guard",
                "preToolUse:*:hook",
                "sessionStart:*:read"
            ]
        );
        assert!(entries.iter().all(|entry| entry.enabled == Some(true)));
    }

    /// One switch turns off every hook in the file, whichever layer set it.
    #[test]
    fn a_file_that_switches_all_hooks_off_reports_them_off() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"disableAllHooks": true, "hooks": {"sessionStart": [{"type": "command", "bash": "./setup.sh"}]}}"#,
        )
        .unwrap();
        let entries = read(&path).unwrap();
        assert_eq!(entries[0].name, "sessionStart:*:setup");
        assert_eq!(entries[0].enabled, Some(false));
    }

    /// The document's own switch, read with its comments: true, false or
    /// absent, and a document that is no JSON or not there is an error naming
    /// it.
    #[test]
    fn a_hook_documents_own_switch_is_read_and_an_unreadable_one_is_an_error() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("lane-mail-check.json");
        let rows: [(&str, bool); 3] = [
            (
                "// written by kendex\n{\"version\": 1, \"disableAllHooks\": true,}",
                true,
            ),
            (r#"{"version": 1, "disableAllHooks": false}"#, false),
            (r#"{"version": 1, "hooks": {}}"#, false),
        ];
        for (text, off) in rows {
            std::fs::write(&path, text).unwrap();
            assert_eq!(document_switched_off(&path).unwrap(), off, "{text}");
        }
        std::fs::write(&path, "{\"disableAllHooks\": true").unwrap();
        match document_switched_off(&path) {
            Err(crate::error::CoreError::JsonParse { path: named, .. }) => assert_eq!(named, path),
            other => panic!("expected a JSON error naming the document, got {other:?}"),
        }
        let absent = tmp.path().join("absent.json");
        match document_switched_off(&absent) {
            Err(crate::error::CoreError::Io { path: named, .. }) => assert_eq!(named, absent),
            other => panic!("expected an IO error naming the document, got {other:?}"),
        }
    }

    #[test]
    fn plugins_read_as_the_map_copilot_keys_them_by() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"enabledPlugins": {"fmt@copilot-plugins": true, "lint@awesome-copilot": false}}"#,
        )
        .unwrap();
        let entries = plugins(&path).unwrap();
        assert_eq!(
            entries
                .iter()
                .map(|e| (e.name.as_str(), e.enabled, e.action.as_deref()))
                .collect::<Vec<_>>(),
            [
                ("fmt@copilot-plugins", Some(true), None),
                ("lint@awesome-copilot", Some(false), None),
            ]
        );
    }
}
