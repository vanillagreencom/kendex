use std::path::Path;

use super::RawEntry;
use super::readers::read_json;
use crate::hook::command_stem;

/// How a registry spells "every operation": the matcher an entry with
/// none is named by, and the one spelling anything comparing a recorded
/// matcher with a read one has to use.
pub(crate) const ANY_MATCHER: &str = "*";

/// One registration as a hooks document keys it, with the parts kept
/// apart. The one-line name a scan displays is built from these; it is
/// never read back out of, because two of the three parts may hold the
/// character that joins them — a matcher is a regex, and a command stem
/// is a file name. Anything asking which registration is which asks for
/// these.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Registration {
    pub(crate) event: String,
    pub(crate) matcher: String,
    pub(crate) command: String,
}

impl Registration {
    /// How a scan names this entry. One rendering, in one place, from the
    /// parts — so nothing downstream has to take it apart again.
    fn name(&self) -> String {
        format!(
            "{}:{}:{}",
            self.event,
            self.matcher,
            command_stem(&self.command)
        )
    }
}

/// `{"hooks": {"<Event>": [{matcher?, hooks: [{command}]} | {command}]}}` —
/// claude settings.json and codex/cursor hooks.json share this shape; cursor
/// omits `matcher` and nests no handler array.
pub fn read(path: &Path) -> Result<Vec<RawEntry>, String> {
    Ok(rows(registrations(read_json(path)?)))
}

/// Every registration in one document, in its parts.
pub(crate) fn read_registrations(path: &Path) -> Result<Vec<Registration>, String> {
    Ok(registrations(read_json(path)?))
}

/// [`read_registrations`] for a document the caller already has in hand —
/// one it is about to write, say, and wants to read back before it does.
pub(crate) fn registrations_text(text: &str) -> Result<Vec<Registration>, String> {
    let value = serde_json::from_str(&super::jsonc::to_json(text)).map_err(|e| e.to_string())?;
    Ok(registrations(value))
}

fn rows(registrations: Vec<Registration>) -> Vec<RawEntry> {
    registrations
        .into_iter()
        .map(|registration| RawEntry {
            name: registration.name(),
            enabled: None,
            description: Some(registration.command),
            source_path: None,
        })
        .collect()
}

fn registrations(value: serde_json::Value) -> Vec<Registration> {
    let Some(events) = value.get("hooks").and_then(|h| h.as_object()) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for (event, groups) in events {
        let Some(groups) = groups.as_array() else {
            continue;
        };
        for group in groups {
            let matcher = group
                .get("matcher")
                .and_then(|m| m.as_str())
                .filter(|m| !m.is_empty())
                .unwrap_or(ANY_MATCHER);
            let handlers = match group.get("hooks").and_then(|h| h.as_array()) {
                Some(list) => list.iter().collect::<Vec<_>>(),
                None => vec![group],
            };
            for handler in handlers {
                let Some(command) = handler.get("command").and_then(|c| c.as_str()) else {
                    continue;
                };
                found.push(Registration {
                    event: event.clone(),
                    matcher: matcher.to_owned(),
                    command: command.to_owned(),
                });
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_and_cursor_shapes_both_parse() {
        let tmp = tempfile::tempdir().unwrap();
        let claude = tmp.path().join("settings.json");
        std::fs::write(
            &claude,
            r#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\""}]}]}}"#,
        )
        .unwrap();
        let entries = read(&claude).unwrap();
        assert_eq!(entries[0].name, "PreToolUse:Bash:guard");

        let cursor = tmp.path().join("hooks.json");
        std::fs::write(
            &cursor,
            r#"{"hooks":{"beforeShellExecution":[{"command":"./check.sh"}]}}"#,
        )
        .unwrap();
        let entries = read(&cursor).unwrap();
        assert_eq!(entries[0].name, "beforeShellExecution:*:check");
    }
}
